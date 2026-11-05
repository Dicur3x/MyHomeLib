unit unit_ZipMemberDeletion;

interface

uses System.Classes, System.SysUtils, System.JSON;

type
  TZipDeleteProgress = reference to procedure(const Stage: string; Done, Total: Int64);
  TZipDeleteFault = reference to procedure(const Stage: string; Chunk: Integer);

  // Confirmed deletions recover forwards. The journal contains metadata,
  // hashes and one bounded in-flight block, never a copy of the archive.
  TZipMemberDeletion = class
  private
    FSource: TFileStream;
    FPlan: TJSONObject;
    FArchive, FJob, FPlanHash: string;
    FMetadata: TBytes;
    FNext: Integer;
    FPending, FFinished: Boolean;
    function Chunks: TJSONArray;
    function ReadAt(Offset: Int64; Count: Integer): TBytes;
    procedure CheckIdentity;
    procedure CheckPlan;
    procedure SaveCheckpoint;
    procedure VerifyFinished;
    function ChunkHash(Index: Integer): string;
    function ChunkNumber(Index, Field: Integer): Int64;
  public
    constructor Prepare(const Archive: string; const Names: TArray<string>;
      const Progress: TZipDeleteProgress = nil; const Cancelled: TFunc<Boolean> = nil);
    constructor Recover(const Archive, Job: string);
    destructor Destroy; override;
    procedure Execute(const JournalParent: string; const Progress: TZipDeleteProgress = nil;
      const Fault: TZipDeleteFault = nil);
    // The caller acknowledges only after its catalogue changes are durable.
    procedure Acknowledge;
    function BytesToProcess: Int64;
    function JournalBytes: Int64;
    property JobDirectory: string read FJob;
    property Finished: Boolean read FFinished;
  end;

implementation

uses Winapi.Windows, System.IOUtils, System.Zip, System.Hash, System.NetEncoding,
  System.Math, System.Generics.Collections, System.Generics.Defaults,
  unit_AtomicIniFile;

const
  BlockBytes = 4 * 1024 * 1024;
  MaxMetadataBytes = 64 * 1024 * 1024;
  MaxPlanBytes = 192 * 1024 * 1024;
  PlanName = 'plan.json';
  CheckpointName = 'checkpoint.json';
  PendingName = 'pending.bin';

type
  // System.Zip serializes the final central directory against a virtual
  // stream. Delete's payload moves are simulated, not read or written here.
  // Actual source ranges are copied once, in physical order, by Execute.
  TZipDirectoryPlanStream = class(TStream)
  private
    FInput: TStream;
    FPosition, FSize: Int64;
  protected
    function GetSize: Int64; override;
    procedure SetSize(const NewSize: Int64); override;
  public
    Simulating, Capturing: Boolean;
    Metadata: TMemoryStream;
    MetadataOffset: Int64;
    constructor Create(Input: TStream);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function Number(Value: TJSONValue): Int64;
begin
  if not (Value is TJSONNumber) or not TryStrToInt64(Value.Value, Result) then
    raise EReadError.Create('Повреждён журнал удаления ZIP: неверное число.');
end;

function FieldNumber(Obj: TJSONObject; const Name: string): Int64;
begin Result := Number(Obj.GetValue(Name)); end;

function TextField(Obj: TJSONObject; const Name: string): string;
var Value: TJSONValue;
begin
  Value := Obj.GetValue(Name);
  if not (Value is TJSONString) then raise EReadError.Create('Повреждён журнал удаления ZIP.');
  Result := Value.Value;
end;

function Digest(const Bytes: TBytes): string;
var Hash: THashSHA2;
begin Hash := THashSHA2.Create; Hash.Update(Bytes); Result := Hash.HashAsString; end;

procedure SaveBytes(const Bytes: TBytes; const Name: string);
var Stream: TBytesStream;
begin
  Stream := TBytesStream.Create(Bytes);
  try SaveStreamAtomically(Stream, Name); finally Stream.Free; end;
end;

procedure SaveObject(Obj: TJSONObject; const Name: string);
begin SaveBytes(TEncoding.UTF8.GetBytes(Obj.ToJSON), Name); end;

function LoadObject(const Name: string): TJSONObject;
var Stream: TFileStream; Data: TBytes; Value: TJSONValue;
begin
  Stream := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size <= 0) or (Stream.Size > MaxPlanBytes) then
      raise EReadError.Create('Неверный размер журнала удаления ZIP.');
    SetLength(Data, Integer(Stream.Size)); Stream.ReadBuffer(Data[0], Length(Data));
  finally Stream.Free; end;
  Value := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
  if not (Value is TJSONObject) then
  begin Value.Free; raise EReadError.Create('Не удалось прочитать журнал удаления ZIP.'); end;
  Result := TJSONObject(Value);
end;

function ArchiveKey(Handle: THandle): string;
var Info: TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle, Info) then RaiseLastOSError;
  if (Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0) then
    raise EReadError.Create('Файловая система не предоставляет устойчивый номер архива.');
  Result := IntToHex(Info.dwVolumeSerialNumber, 8)+':'+
    IntToHex(Info.nFileIndexHigh, 8)+IntToHex(Info.nFileIndexLow, 8);
end;

function NormalName(const Name: string): string;
begin Result := StringReplace(Name, '\', '/', [rfReplaceAll]); end;

constructor TZipDirectoryPlanStream.Create(Input: TStream);
begin
  inherited Create; FInput := Input; FSize := Input.Size;
  Metadata := TMemoryStream.Create; MetadataOffset := -1;
end;

destructor TZipDirectoryPlanStream.Destroy;
begin Metadata.Free; inherited; end;

function TZipDirectoryPlanStream.GetSize: Int64;
begin Result := FSize; end;

procedure TZipDirectoryPlanStream.SetSize(const NewSize: Int64);
begin
  if NewSize < 0 then raise EStreamError.Create('Invalid virtual ZIP size');
  FSize := NewSize;
end;

function TZipDirectoryPlanStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning: Result := Offset;
    soCurrent: Result := FPosition+Offset;
    soEnd: Result := FSize+Offset;
    else raise EStreamError.Create('Invalid ZIP seek');
  end;
  if Result < 0 then raise EStreamError.Create('Negative ZIP position');
  FPosition := Result;
end;

function TZipDirectoryPlanStream.Read(var Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (FPosition > FSize) or (Count > FSize-FPosition) then
    raise EReadError.Create('Invalid ZIP planning read');
  if Simulating then Result := Count
  else
  begin FInput.Position := FPosition; Result := FInput.Read(Buffer, Count); end;
  Inc(FPosition, Result);
end;

function TZipDirectoryPlanStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count < 0 then raise EWriteError.Create('Invalid ZIP planning write');
  if Capturing then
  begin
    if MetadataOffset < 0 then MetadataOffset := FPosition;
    if (FPosition <> MetadataOffset+Metadata.Size) or
      (Metadata.Size+Count > MaxMetadataBytes) then
      raise EWriteError.Create('Слишком большой или неподдерживаемый каталог ZIP.');
    Metadata.WriteBuffer(Buffer, Count);
  end
  else if not Simulating then raise EWriteError.Create('Unexpected ZIP planning write');
  Inc(FPosition, Count); FSize := Max(FSize, FPosition); Result := Count;
end;

function TZipMemberDeletion.ReadAt(Offset: Int64; Count: Integer): TBytes;
begin
  if (Offset < 0) or (Count < 0) or (Count > BlockBytes) or
    (Offset > FSource.Size) or (Count > FSource.Size-Offset) then
    raise EReadError.Create('Недоступен блок архива ZIP.');
  SetLength(Result, Count); FSource.Position := Offset;
  if Count > 0 then FSource.ReadBuffer(Result[0], Count);
end;

function TZipMemberDeletion.Chunks: TJSONArray;
begin Result := FPlan.GetValue('chunks') as TJSONArray; end;

function TZipMemberDeletion.ChunkNumber(Index, Field: Integer): Int64;
begin Result := Number((Chunks.Items[Index] as TJSONArray).Items[Field]); end;

function TZipMemberDeletion.ChunkHash(Index: Integer): string;
begin Result := (Chunks.Items[Index] as TJSONArray).Items[3].Value; end;

procedure TZipMemberDeletion.CheckIdentity;
begin
  if (TextField(FPlan,'archive') <> FArchive) or
    (TextField(FPlan,'fileId') <> ArchiveKey(FSource.Handle)) then
    raise EReadError.Create('Архив был заменён. Журнал удаления не применён к другому файлу.');
end;

procedure TZipMemberDeletion.CheckPlan;
var ArrayItem: TJSONValue; Item: TJSONArray; Source, Target, Count, EndSource, EndTarget: Int64;
  Hash: string;
begin
  CheckIdentity;
  if (FieldNumber(FPlan,'schema') <> 1) or
    not (FPlan.GetValue('chunks') is TJSONArray) or
    not (FPlan.GetValue('remaining') is TJSONArray) or
    (Chunks.Count > 1048576) then raise EReadError.Create('Неподдерживаемый журнал удаления ZIP.');
  FMetadata := TNetEncoding.Base64.DecodeStringToBytes(TextField(FPlan,'metadata'));
  if (Length(FMetadata) = 0) or (Length(FMetadata) > MaxMetadataBytes) or
    (FieldNumber(FPlan,'originalSize') < FieldNumber(FPlan,'finalSize')) or
    (FieldNumber(FPlan,'metadataOffset') < 0) or
    (FieldNumber(FPlan,'finalSize')-Length(FMetadata) <> FieldNumber(FPlan,'metadataOffset')) then
    raise EReadError.Create('Повреждён план удаления ZIP.');
  EndTarget := FieldNumber(FPlan,'untouchedEnd'); EndSource := EndTarget;
  if (EndTarget<0) or (EndTarget>FieldNumber(FPlan,'metadataOffset')) then
    raise EReadError.Create('Неверная граница неизменяемого участка ZIP.');
  for ArrayItem in Chunks do
  begin
    if not (ArrayItem is TJSONArray) or (TJSONArray(ArrayItem).Count <> 4) then
      raise EReadError.Create('Повреждён блок плана ZIP.');
    Item := TJSONArray(ArrayItem);
    Source := Number(Item.Items[0]); Target := Number(Item.Items[1]); Count := Number(Item.Items[2]);
    Hash := Item.Items[3].Value;
    if (Source < EndSource) or (Target <> EndTarget) or (Source < Target) or
      (Count <= 0) or (Count > BlockBytes) or
      (Source > FieldNumber(FPlan,'originalSize')-Count) or
      (Target > FieldNumber(FPlan,'metadataOffset')-Count) or
      (Length(Hash) <> 64) then raise EReadError.Create('Некорректные границы перемещения в ZIP.');
    for var Ch in Hash do if not CharInSet(Ch,['0'..'9','a'..'f']) then
      raise EReadError.Create('Повреждена контрольная сумма блока ZIP.');
    EndSource := Source+Count; EndTarget := Target+Count;
  end;
  if EndTarget <> FieldNumber(FPlan,'metadataOffset') then
    raise EReadError.Create('План ZIP оставляет непроверенный участок.');
end;

constructor TZipMemberDeletion.Prepare(const Archive: string; const Names: TArray<string>;
  const Progress: TZipDeleteProgress; const Cancelled: TFunc<Boolean>);
var Zip: TZipFile; Virtual: TZipDirectoryPlanStream; Headers, FinalHeaders: TArray<TZipHeader>;
  OriginalNames, FinalNames: TArray<string>; Remove: TArray<Boolean>; Order: TArray<Integer>;
  FinalOffsets: TArray<Int64>; RangeSource, RangeTarget, RangeLength: Int64;
  OriginalEnd, FinalEnd, CurrentEnd, Offset, Destination, Remaining, Total, Done, UntouchedEnd: Int64;
  Indices: TDictionary<string,Integer>; OriginalEndByIndex: TArray<Int64>;
  Metadata: TBytes; Requested, Key: string; Index, Count, FinalIndex: Integer;
  Chunk: TJSONArray; Keep: TJSONArray;
  procedure CancelCheck;
  begin if Assigned(Cancelled) and Cancelled() then Abort; end;
  procedure AddRange(Source, Target, Length: Int64);
  begin
    if Source=Target then
    begin
      if Source<>UntouchedEnd then raise EReadError.Create('Неверная последовательность диапазонов ZIP.');
      Inc(UntouchedEnd,Length); Exit;
    end;
    while Length > 0 do
    begin
      CancelCheck; Count := Integer(Min(Int64(BlockBytes),Length));
      Chunk := TJSONArray.Create;
      Chunk.AddElement(TJSONNumber.Create(Source)); Chunk.AddElement(TJSONNumber.Create(Target));
      Chunk.AddElement(TJSONNumber.Create(Count)); Chunk.Add(Digest(ReadAt(Source,Count)));
      Chunks.AddElement(Chunk); Inc(Source,Count); Inc(Target,Count); Dec(Length,Count);
      Inc(Done,Count);
      if Assigned(Progress) then Progress('Проверка архива',Done,Total-UntouchedEnd);
    end;
  end;
begin
  inherited Create;
  if Length(Names)=0 then raise EArgumentException.Create('Не выбраны файлы внутри ZIP.');
  FArchive := ExpandFileName(Archive);
  FSource := TFileStream.Create(FArchive,fmOpenReadWrite or fmShareExclusive);
  Zip := TZipFile.Create; Virtual := TZipDirectoryPlanStream.Create(FSource);
  Indices := TDictionary<string,Integer>.Create;
  try
    Zip.Open(Virtual,zmReadWrite);
    Headers := Copy(Zip.FileInfos); OriginalNames := Zip.FileNames;
    SetLength(Remove,Length(Headers));
    for var I := 0 to High(Headers) do
    begin
      Key := NormalName(OriginalNames[I]);
      if Indices.ContainsKey(Key) then Indices[Key] := -1 else Indices.Add(Key,I);
    end;
    for Requested in Names do
    begin
      CancelCheck;
      if not Indices.TryGetValue(NormalName(Requested),Index) or (Index < 0) then
        raise EReadError.Create('Файл внутри ZIP не найден однозначно: '+Requested);
      if NormalName(OriginalNames[Index]).EndsWith('/') then
        raise EReadError.Create('Вместо книги внутри ZIP выбрана папка.');
      Remove[Index] := True;
    end;
    Virtual.Capturing := True; Zip.Close;
    OriginalEnd := Virtual.MetadataOffset;
    if (OriginalEnd < 0) or (OriginalEnd > FSource.Size) then
      raise EReadError.Create('Неверные границы каталога ZIP.');
    Virtual.Free; Virtual := TZipDirectoryPlanStream.Create(FSource);
    Zip.Open(Virtual,zmReadWrite); Virtual.Simulating := True;
    for var I := High(Remove) downto 0 do if Remove[I] then
    begin CancelCheck; Zip.Delete(I); end;
    FinalHeaders := Copy(Zip.FileInfos); FinalNames := Zip.FileNames;
    Virtual.Simulating := False; Virtual.Capturing := True; Zip.Close;
    FinalEnd := Virtual.MetadataOffset;
    SetLength(Metadata,Integer(Virtual.Metadata.Size)); Virtual.Metadata.Position := 0;
    if Length(Metadata)>0 then Virtual.Metadata.ReadBuffer(Metadata[0],Length(Metadata));

    SetLength(Order,Length(Headers)); SetLength(OriginalEndByIndex,Length(Headers));
    for var I := 0 to High(Order) do Order[I] := I;
    TArray.Sort<Integer>(Order,TComparer<Integer>.Construct(
      function(const Left,Right: Integer): Integer
      begin
        if Headers[Left].LocalHeaderOffset64 < Headers[Right].LocalHeaderOffset64 then Result := -1
        else if Headers[Left].LocalHeaderOffset64 > Headers[Right].LocalHeaderOffset64 then Result := 1
        else Result := 0;
      end));
    CurrentEnd := OriginalEnd;
    for var I := High(Order) downto 0 do
    begin
      Index := Order[I];
      if (Headers[Index].LocalHeaderOffset64 > UInt64(High(Int64))) or
        (Headers[Index].DiskNumberStart <> 0) then raise EReadError.Create('Неподдерживаемое размещение ZIP.');
      Offset := Int64(Headers[Index].LocalHeaderOffset64);
      if (Offset < 0) or (Offset >= CurrentEnd) or
        (Headers[Index].CompressedSize64 > UInt64(CurrentEnd-Offset)) then
        raise EReadError.Create('Перекрывающиеся или повреждённые файлы ZIP.');
      var Prefix := ReadAt(Offset,Integer(Min(Int64(30),CurrentEnd-Offset)));
      if (Length(Prefix)<>30) or (Prefix[0]<>$50) or (Prefix[1]<>$4B) or
        (Prefix[2]<>$03) or (Prefix[3]<>$04) or
        (Int64(30+Word(Prefix[26])+Word(Prefix[27])*256+Word(Prefix[28])+Word(Prefix[29])*256)+
          Int64(Headers[Index].CompressedSize64)>CurrentEnd-Offset) then
        raise EReadError.Create('Повреждён локальный заголовок ZIP.');
      OriginalEndByIndex[Index] := CurrentEnd; CurrentEnd := Offset;
    end;
    Total := CurrentEnd;
    for var I := 0 to High(Headers) do if not Remove[I] then
      Inc(Total,OriginalEndByIndex[I]-Int64(Headers[I].LocalHeaderOffset64));
    if Total<>FinalEnd then raise EReadError.Create('План ZIP не сохраняет границы оставшихся файлов.');
    FPlan := TJSONObject.Create;
    FPlan.AddPair('schema',TJSONNumber.Create(1)); FPlan.AddPair('archive',FArchive);
    FPlan.AddPair('fileId',ArchiveKey(FSource.Handle));
    FPlan.AddPair('originalSize',TJSONNumber.Create(FSource.Size));
    FPlan.AddPair('finalSize',TJSONNumber.Create(Virtual.Size));
    FPlan.AddPair('metadataOffset',TJSONNumber.Create(FinalEnd));
    FPlan.AddPair('metadata',TNetEncoding.Base64.EncodeBytesToString(Metadata));
    FPlan.AddPair('chunks',TJSONArray.Create); Keep := TJSONArray.Create; FPlan.AddPair('remaining',Keep);
    for Key in FinalNames do Keep.Add(Key);
    SetLength(FinalOffsets,Length(Headers)); FinalIndex := 0;
    for var I := 0 to High(Headers) do if not Remove[I] then
    begin
      if (FinalIndex>=Length(FinalHeaders)) or (FinalNames[FinalIndex]<>OriginalNames[I]) then
        raise EReadError.Create('Изменён порядок сохранённых файлов ZIP.');
      FinalOffsets[I] := Int64(FinalHeaders[FinalIndex].LocalHeaderOffset64); Inc(FinalIndex);
    end;
    Done := 0; UntouchedEnd := 0; Destination := CurrentEnd; RangeSource := 0; RangeTarget := 0; RangeLength := CurrentEnd;
    for Index in Order do if not Remove[Index] then
    begin
      Offset := Int64(Headers[Index].LocalHeaderOffset64); Remaining := OriginalEndByIndex[Index]-Offset;
      if FinalOffsets[Index]<>Destination then
        raise EReadError.Create('Неверное смещение сохранённого файла ZIP.');
      if (RangeSource+RangeLength=Offset) and (RangeTarget+RangeLength=Destination) then Inc(RangeLength,Remaining)
      else
      begin
        AddRange(RangeSource,RangeTarget,RangeLength);
        RangeSource := Offset; RangeTarget := Destination; RangeLength := Remaining;
      end;
      Inc(Destination,Remaining);
    end;
    AddRange(RangeSource,RangeTarget,RangeLength);
    FPlan.AddPair('untouchedEnd',TJSONNumber.Create(UntouchedEnd));
    CheckPlan;
  finally
    Indices.Free;
    Virtual.Capturing := False; Virtual.Simulating := True;
    Zip.Free; Virtual.Free;
  end;
end;

constructor TZipMemberDeletion.Recover(const Archive, Job: string);
var State: TJSONObject; Bytes: TBytes;
begin
  inherited Create;
  FArchive := ExpandFileName(Archive); FJob := ExpandFileName(Job);
  FPlan := LoadObject(TPath.Combine(FJob,PlanName));
  Bytes := TEncoding.UTF8.GetBytes(FPlan.ToJSON); FPlanHash := Digest(Bytes);
  FSource := TFileStream.Create(FArchive,fmOpenReadWrite or fmShareExclusive);
  CheckPlan;
  State := LoadObject(TPath.Combine(FJob,CheckpointName));
  try
    if TextField(State,'planHash') <> FPlanHash then raise EReadError.Create('Журнал ZIP изменён.');
    var Next := FieldNumber(State,'next');
    if (Next<0) or (Next>Chunks.Count) or not (State.GetValue('pending') is TJSONBool) or
      not (State.GetValue('finished') is TJSONBool) then raise EReadError.Create('Повреждён ход удаления ZIP.');
    FNext := Integer(Next); FPending := TJSONBool(State.GetValue('pending')).AsBoolean;
    FFinished := TJSONBool(State.GetValue('finished')).AsBoolean;
    if FPending and (FNext>=Chunks.Count) then raise EReadError.Create('Неверный ожидающий блок ZIP.');
    if FFinished and (FNext<>Chunks.Count) then raise EReadError.Create('Незавершённый журнал ZIP.');
  finally State.Free; end;
  if (FSource.Size<>FieldNumber(FPlan,'originalSize')) and
    ((FNext<>Chunks.Count) or (FSource.Size<>FieldNumber(FPlan,'finalSize'))) then
    raise EReadError.Create('Размер архива изменился вне операции удаления.');
end;

destructor TZipMemberDeletion.Destroy;
begin FPlan.Free; FSource.Free; inherited; end;

procedure TZipMemberDeletion.SaveCheckpoint;
var State: TJSONObject;
begin
  State := TJSONObject.Create;
  try
    State.AddPair('planHash',FPlanHash); State.AddPair('next',TJSONNumber.Create(FNext));
    State.AddPair('pending',TJSONBool.Create(FPending)); State.AddPair('finished',TJSONBool.Create(FFinished));
    SaveObject(State,TPath.Combine(FJob,CheckpointName));
  finally State.Free; end;
end;

function TZipMemberDeletion.BytesToProcess: Int64;
begin Result := FieldNumber(FPlan,'metadataOffset')-FieldNumber(FPlan,'untouchedEnd'); end;

function TZipMemberDeletion.JournalBytes: Int64;
var Pending: Int64;
begin
  Pending := 0;
  for var I := 0 to Chunks.Count-1 do Pending := Max(Pending,ChunkNumber(I,2));
  Result := Length(TEncoding.UTF8.GetBytes(FPlan.ToJSON))+2*Pending+65536;
end;

procedure TZipMemberDeletion.VerifyFinished;
var Zip: TZipFile; Names: TJSONArray; Actual: TBytes; FileNames: TArray<string>;
begin
  if FSource.Size<>FieldNumber(FPlan,'finalSize') then raise EReadError.Create('Неверный итоговый размер ZIP.');
  FSource.Position := FieldNumber(FPlan,'metadataOffset');
  SetLength(Actual,Length(FMetadata)); FSource.ReadBuffer(Actual[0],Length(Actual));
  if Digest(Actual) <> Digest(FMetadata) then raise EReadError.Create('Каталог ZIP не прошёл проверку записи.');
  Zip := TZipFile.Create;
  try
    Zip.Open(FSource,zmRead); Names := FPlan.GetValue('remaining') as TJSONArray;
    if Zip.FileCount<>Names.Count then raise EReadError.Create('Изменился список сохранённых файлов ZIP.');
    FileNames := Zip.FileNames;
    for var I := 0 to Names.Count-1 do
      if FileNames[I]<>Names.Items[I].Value then raise EReadError.Create('Подменён файл в каталоге ZIP.');
  finally Zip.Free; end;
end;

procedure TZipMemberDeletion.Execute(const JournalParent: string; const Progress: TZipDeleteProgress;
  const Fault: TZipDeleteFault);
var Bytes, Actual: TBytes; Target, Done: Int64; Count: Integer; Pending: TFileStream;
  FreeSpace, Capacity, TotalFree: UInt64;
  procedure Signal(const Stage: string);
  begin if Assigned(Fault) then Fault(Stage,FNext); end;
  procedure Flush;
  begin if not FlushFileBuffers(FSource.Handle) then RaiseLastOSError; end;
begin
  CheckPlan;
  if FJob='' then
  begin
    ForceDirectories(JournalParent);
    if not GetDiskFreeSpaceEx(PChar(ExpandFileName(JournalParent)),FreeSpace,Capacity,@TotalFree) then RaiseLastOSError;
    if FreeSpace<UInt64(JournalBytes) then
      raise EWriteError.Create('Недостаточно места для небольшого журнала удаления ZIP. Архив не изменён.');
    FJob := TPath.Combine(ExpandFileName(JournalParent),'zip-delete-'+TGUID.NewGuid.ToString);
    if not CreateDirectory(PChar(FJob),nil) then RaiseLastOSError;
    Bytes := TEncoding.UTF8.GetBytes(FPlan.ToJSON);
    if Length(Bytes)>MaxPlanBytes then raise EWriteError.Create('Слишком большой журнал ZIP.');
    FPlanHash := Digest(Bytes); SaveBytes(Bytes,TPath.Combine(FJob,PlanName)); SaveCheckpoint;
  end;
  Done := 0;
  // Recheck blocks already completed before an interruption; no external
  // replacement or post-crash edit may silently enter a resumed operation.
  for var I := 0 to FNext-1 do
  begin
    Actual := ReadAt(ChunkNumber(I,1),Integer(ChunkNumber(I,2)));
    if Digest(Actual)<>ChunkHash(I) then raise EReadError.Create('Сохранённый блок ZIP изменён после прерывания.');
    Inc(Done,Length(Actual));
  end;
  if FFinished then begin VerifyFinished; Exit; end;
  while FNext<Chunks.Count do
  begin
    Target := ChunkNumber(FNext,1); Count := Integer(ChunkNumber(FNext,2));
    if FPending then
    begin
      Pending := TFileStream.Create(TPath.Combine(FJob,PendingName),fmOpenRead or fmShareDenyWrite);
      try
        if Pending.Size<>Count then raise EReadError.Create('Неверный размер ожидающего блока ZIP.');
        SetLength(Bytes,Count); Pending.ReadBuffer(Bytes[0],Count);
      finally Pending.Free; end;
    end
    else Bytes := ReadAt(ChunkNumber(FNext,0),Count);
    if (Length(Bytes)<>Count) or (Digest(Bytes)<>ChunkHash(FNext)) then
      raise EReadError.Create('Исходный блок ZIP не совпадает с планом. Удаление не продолжено.');
    if ChunkNumber(FNext,0)<>Target then
    begin
      if not FPending then
      begin SaveBytes(Bytes,TPath.Combine(FJob,PendingName)); FPending := True; SaveCheckpoint; end;
      Signal('pending');
      // The pending block can safely redo even a partially completed write.
      if Assigned(Fault) then
      begin FSource.Position := Target; FSource.WriteBuffer(Bytes[0],Count div 2); Flush; Signal('half-written'); end;
      FSource.Position := Target; FSource.WriteBuffer(Bytes[0],Count); Flush; Signal('written');
      Actual := ReadAt(Target,Count);
      if Digest(Actual)<>ChunkHash(FNext) then raise EWriteError.Create('Записанный блок ZIP повреждён. Журнал сохранён.');
    end;
    Inc(Done,Count); Inc(FNext); FPending := False; SaveCheckpoint; Signal('checkpoint');
    if Assigned(Progress) then Progress('Удаление из архива',Done,BytesToProcess);
  end;
  if Assigned(Fault) then
  begin
    FSource.Position := FieldNumber(FPlan,'metadataOffset');
    FSource.WriteBuffer(FMetadata[0],Length(FMetadata) div 2); Flush; Signal('half-metadata');
  end;
  FSource.Position := FieldNumber(FPlan,'metadataOffset');
  FSource.WriteBuffer(FMetadata[0],Length(FMetadata)); Flush; Signal('metadata');
  FSource.Size := FieldNumber(FPlan,'finalSize'); Flush; Signal('truncated');
  VerifyFinished; FFinished := True; SaveCheckpoint; Signal('finished');
end;

procedure TZipMemberDeletion.Acknowledge;
var Path: string;
begin
  if not FFinished or (FJob='') then raise EInvalidOperation.Create('Удаление ZIP ещё не завершено.');
  CheckIdentity; VerifyFinished;
  if Digest(TFile.ReadAllBytes(TPath.Combine(FJob,PlanName)))<>FPlanHash then
    raise EReadError.Create('Журнал ZIP изменён и сохранён для проверки.');
  for var Name in [PendingName,CheckpointName,PlanName] do
  begin
    Path := TPath.Combine(FJob,Name);
    if FileExists(Path) and not System.SysUtils.DeleteFile(Path) then RaiseLastOSError;
  end;
  if not RemoveDirectory(PChar(FJob)) then RaiseLastOSError;
  FJob := '';
end;

end.
