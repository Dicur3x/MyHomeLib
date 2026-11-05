unit unit_SevenZipDeletionPlan;

interface

uses System.SysUtils, System.Classes;

type
  TSevenZipRetainedRange = record
    Source, Target: Int64;
    Bytes: Integer;
    SHA256: string;
  end;
  TSevenZipDeletionLayout = record
    Header, Tail: TBytes;
    TailOffset, FinalSize: Int64;
    Ranges: TArray<TSevenZipRetainedRange>;
    Remaining: TArray<string>;
  end;

// Ask the installed 7-Zip SDK to serialize a deletion into a virtual output.
// This never writes the source or a complete output archive. Only unchanged
// compressed blocks may be borrowed; re-encoding a partial solid block fails
// closed. The caller owns Source and keeps it exclusively open throughout.
function PlanSevenZipDeletion(Source: TStream; const Remove: TArray<string>;
  const Cancel: TFunc<Boolean> = nil): TSevenZipDeletionLayout;
procedure VerifySevenZipInventory(Source: TStream; const Names: TArray<string>);

implementation

uses Winapi.Windows, System.IOUtils, System.Variants, System.Math, System.Hash,
  System.Generics.Collections, unit_MHLExternalTools;

type
  ISzSeqIn = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000300010000}']
    function Read(Data:Pointer; Size:Cardinal; Processed:PCardinal):HRESULT; stdcall;
  end;
  ISzIn = interface(ISzSeqIn)
    ['{23170F69-40C1-278A-0000-000300030000}']
    function Seek(Offset:Int64; Origin:Cardinal; Position:PUInt64):HRESULT; stdcall;
  end;
  ISzSeqOut = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000300020000}']
    function Write(Data:Pointer; Size:Cardinal; Processed:PCardinal):HRESULT; stdcall;
  end;
  ISzOut = interface(ISzSeqOut)
    ['{23170F69-40C1-278A-0000-000300040000}']
    function Seek(Offset:Int64; Origin:Cardinal; Position:PUInt64):HRESULT; stdcall;
    function SetSize(Size:UInt64):HRESULT; stdcall;
  end;
  ISzProgress = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000000050000}']
    function SetTotal(Total:UInt64):HRESULT; stdcall;
    function SetCompleted(Value:PUInt64):HRESULT; stdcall;
  end;
  ISzUpdate = interface(ISzProgress)
    ['{23170F69-40C1-278A-0000-000600800000}']
    function GetUpdateItemInfo(Index:Cardinal; NewData,NewProps:PInteger; OldIndex:PCardinal):HRESULT; stdcall;
    function GetProperty(Index,PropID:Cardinal; var Value:OleVariant):HRESULT; stdcall;
    function GetStream(Index:Cardinal; out Stream:ISzSeqIn):HRESULT; stdcall;
    function SetOperationResult(Value:Integer):HRESULT; stdcall;
  end;
  ISzUpdateFile = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000600830000}']
    function GetStream2(Index:Cardinal; out Stream:ISzSeqIn; Operation:Cardinal):HRESULT; stdcall;
    function ReportOperation(IndexType,Index,Operation:Cardinal):HRESULT; stdcall;
  end;
  ISzArchive = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000600600000}']
    function Open(const Stream:ISzIn; MaxCheck:PUInt64; Callback:IUnknown):HRESULT; stdcall;
    function Close:HRESULT; stdcall;
    function GetNumberOfItems(out Count:Cardinal):HRESULT; stdcall;
    function GetProperty(Index,PropID:Cardinal; var Value:OleVariant):HRESULT; stdcall;
    function Extract(Indices:PCardinal; Count:Cardinal; TestMode:Integer; Callback:IUnknown):HRESULT; stdcall;
    function GetArchiveProperty(PropID:Cardinal; var Value:OleVariant):HRESULT; stdcall;
    function GetNumberOfProperties(out Count:Cardinal):HRESULT; stdcall;
    function GetPropertyInfo(Index:Cardinal; out Name:WideString; out PropID:Cardinal; out VarType:Word):HRESULT; stdcall;
    function GetNumberOfArchiveProperties(out Count:Cardinal):HRESULT; stdcall;
    function GetArchivePropertyInfo(Index:Cardinal; out Name:WideString; out PropID:Cardinal; out VarType:Word):HRESULT; stdcall;
  end;
  ISzWriter = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000600A00000}']
    function UpdateItems(const Stream:ISzSeqOut; Count:Cardinal; const Callback:ISzUpdate):HRESULT; stdcall;
    function GetFileTimeType(out Value:Cardinal):HRESULT; stdcall;
  end;
  TSzFactory = function(const ClassID,IID:TGUID; out Obj):HRESULT; stdcall;

  TSzBorrowedInput = class(TInterfacedObject,ISzSeqIn,ISzIn)
  public
    Source:TStream;
    Cancel:TFunc<Boolean>;
    LastPointer:NativeUInt;
    LastOffset:Int64;
    LastBytes:TBytes;
    Error:string;
    function Read(Data:Pointer; Size:Cardinal; Processed:PCardinal):HRESULT; stdcall;
    function Seek(Offset:Int64; Origin:Cardinal; Position:PUInt64):HRESULT; stdcall;
  end;
  TSzPlannedOutput = class(TInterfacedObject,ISzSeqOut,ISzOut)
  public
    Input:TSzBorrowedInput;
    Position, Size, TailStart:Int64;
    Header,Tail:TMemoryStream;
    Ranges:TList<TSevenZipRetainedRange>;
    Error:string;
    constructor Create(Borrowed:TSzBorrowedInput);
    destructor Destroy; override;
    function Write(Data:Pointer; Count:Cardinal; Processed:PCardinal):HRESULT; stdcall;
    function Seek(Offset:Int64; Origin:Cardinal; NewPosition:PUInt64):HRESULT; stdcall;
    function SetSize(NewSize:UInt64):HRESULT; stdcall;
  end;
  TSzKeepCallback = class(TInterfacedObject,ISzProgress,ISzUpdate,ISzUpdateFile)
  public
    Keep:TArray<Cardinal>;
    Cancel:TFunc<Boolean>;
    RepackRequested:Boolean;
    function SetTotal(Total:UInt64):HRESULT; stdcall;
    function SetCompleted(Value:PUInt64):HRESULT; stdcall;
    function GetUpdateItemInfo(Index:Cardinal; NewData,NewProps:PInteger; OldIndex:PCardinal):HRESULT; stdcall;
    function GetProperty(Index,PropID:Cardinal; var Value:OleVariant):HRESULT; stdcall;
    function GetStream(Index:Cardinal; out Stream:ISzSeqIn):HRESULT; stdcall;
    function SetOperationResult(Value:Integer):HRESULT; stdcall;
    function GetStream2(Index:Cardinal; out Stream:ISzSeqIn; Operation:Cardinal):HRESULT; stdcall;
    function ReportOperation(IndexType,Index,Operation:Cardinal):HRESULT; stdcall;
  end;

procedure Check(Code:HRESULT; const Stage:string);
begin if Code<>S_OK then raise EReadError.CreateFmt('7-Zip: %s (0x%s).',[Stage,IntToHex(Cardinal(Code),8)]); end;

function TSzBorrowedInput.Read(Data:Pointer; Size:Cardinal; Processed:PCardinal):HRESULT;
begin
  if Assigned(Processed) then Processed^:=0;
  if Assigned(Cancel) and Cancel() then Exit(E_ABORT);
  try
    LastOffset:=Source.Position; LastPointer:=NativeUInt(Data);
    var N:=Source.Read(Data^,Integer(Min(Size,Cardinal(4*1024*1024))));
    SetLength(LastBytes,N); if N>0 then Move(Data^,LastBytes[0],N);
    if Assigned(Processed) then Processed^:=N;
    Result:=S_OK;
  except on E:Exception do begin Error:=E.Message; Result:=E_FAIL; end; end;
end;

function TSzBorrowedInput.Seek(Offset:Int64; Origin:Cardinal; Position:PUInt64):HRESULT;
begin
  if Origin>2 then Exit(E_INVALIDARG);
  try
    var At:=Source.Seek(Offset,TSeekOrigin(Origin));
    if At<0 then Exit(E_INVALIDARG);
    if Assigned(Position) then Position^:=At; Result:=S_OK;
  except on E:Exception do begin Error:=E.Message; Result:=E_FAIL; end; end;
end;

constructor TSzPlannedOutput.Create(Borrowed:TSzBorrowedInput);
begin
  inherited Create; Input:=Borrowed; TailStart:=-1;
  Header:=TMemoryStream.Create; Tail:=TMemoryStream.Create;
  Ranges:=TList<TSevenZipRetainedRange>.Create;
end;
destructor TSzPlannedOutput.Destroy;
begin Ranges.Free; Header.Free; Tail.Free; inherited; end;

function TSzPlannedOutput.Write(Data:Pointer; Count:Cardinal; Processed:PCardinal):HRESULT;
var Delta:NativeUInt; Borrow:Boolean; Range:TSevenZipRetainedRange; Hash:THashSHA2;
begin
  if Assigned(Processed) then Processed^:=0;
  if Count=0 then Exit(S_OK);
  try
    if (Position<0) or (Count>4*1024*1024) then
      raise EWriteError.Create('Неподдерживаемая порция данных 7z.');
    if Position<32 then
    begin
      if Position+Count>32 then raise EWriteError.Create('Неверный заголовок 7z.');
      Header.Position:=Position; Header.WriteBuffer(Data^,Count);
    end
    else
    begin
      Borrow:=False; Delta:=0;
      if NativeUInt(Data)>=Input.LastPointer then
      begin
        Delta:=NativeUInt(Data)-Input.LastPointer;
        if (Delta<NativeUInt(Length(Input.LastBytes))) and
          (Count<=NativeUInt(Length(Input.LastBytes))-Delta) then
          Borrow:=CompareMem(Data,@Input.LastBytes[Integer(Delta)],Count);
      end;
      if Borrow then
      begin
        if TailStart>=0 then raise EWriteError.Create('7-Zip переставил данные после заголовка.');
        Range.Source:=Input.LastOffset+Int64(Delta); Range.Target:=Position; Range.Bytes:=Count;
        if (Range.Source<Range.Target) or (Range.Source<32) or
          (Range.Source>Input.Source.Size-Int64(Count)) then
          raise EWriteError.Create('Требуется неподдерживаемое перемещение блока 7z.');
        if Ranges.Count>0 then
        begin
          var Previous:=Ranges[Ranges.Count-1];
          if (Range.Target<>Previous.Target+Previous.Bytes) or
            (Range.Source<Previous.Source+Previous.Bytes) then
            raise EWriteError.Create('7-Zip изменил физический порядок блоков.');
        end else if Range.Target<>32 then raise EWriteError.Create('Пропущено начало данных 7z.');
        Hash:=THashSHA2.Create; Hash.Update(Data^,Count); Range.SHA256:=Hash.HashAsString;
        Ranges.Add(Range);
      end
      else
      begin
        if TailStart<0 then TailStart:=Position;
        if (Position<>TailStart+Tail.Size) or (Tail.Size+Count>64*1024*1024) then
          raise EWriteError.Create('Слишком большой или непоследовательный заголовок 7z.');
        Tail.WriteBuffer(Data^,Count);
      end;
    end;
    Inc(Position,Count); Size:=Max(Size,Position);
    if Assigned(Processed) then Processed^:=Count; Result:=S_OK;
  except on E:Exception do begin Error:=E.Message; Result:=E_FAIL; end; end;
end;

function TSzPlannedOutput.Seek(Offset:Int64; Origin:Cardinal; NewPosition:PUInt64):HRESULT;
var Value:Int64;
begin
  case Origin of
    0:Value:=Offset; 1:Value:=Position+Offset; 2:Value:=Size+Offset;
    else Exit(E_INVALIDARG);
  end;
  if Value<0 then Exit(E_INVALIDARG);
  Position:=Value; if Assigned(NewPosition) then NewPosition^:=Value; Result:=S_OK;
end;
function TSzPlannedOutput.SetSize(NewSize:UInt64):HRESULT;
begin
  if NewSize>UInt64(High(Int64)) then Exit(E_INVALIDARG);
  Size:=Int64(NewSize); Result:=S_OK;
end;

function TSzKeepCallback.SetTotal(Total:UInt64):HRESULT;
begin if Assigned(Cancel) and Cancel() then Result:=E_ABORT else Result:=S_OK; end;
function TSzKeepCallback.SetCompleted(Value:PUInt64):HRESULT;
begin Result:=SetTotal(0); end;
function TSzKeepCallback.GetUpdateItemInfo(Index:Cardinal; NewData,NewProps:PInteger; OldIndex:PCardinal):HRESULT;
begin
  if Index>=Cardinal(Length(Keep)) then Exit(E_INVALIDARG);
  NewData^:=0; NewProps^:=0; OldIndex^:=Keep[Index]; Result:=S_OK;
end;
function TSzKeepCallback.GetProperty(Index,PropID:Cardinal; var Value:OleVariant):HRESULT;
begin Value:=Unassigned; Result:=E_NOTIMPL; end;
function TSzKeepCallback.GetStream(Index:Cardinal; out Stream:ISzSeqIn):HRESULT;
begin Stream:=nil; Result:=E_NOTIMPL; end;
function TSzKeepCallback.SetOperationResult(Value:Integer):HRESULT;
begin if Value=0 then Result:=S_OK else Result:=E_FAIL; end;
function TSzKeepCallback.GetStream2(Index:Cardinal; out Stream:ISzSeqIn; Operation:Cardinal):HRESULT;
begin Stream:=nil; Result:=E_NOTIMPL; end;
function TSzKeepCallback.ReportOperation(IndexType,Index,Operation:Cardinal):HRESULT;
begin
  // SDK NUpdateNotifyOp::kRepack = 4. Never silently re-encode a solid block.
  if Operation=4 then begin RepackRequested:=True; Exit(E_NOTIMPL); end;
  Result:=SetTotal(0);
end;

function OpenSevenZip(Source:TStream; out Module:HMODULE; out Input:ISzIn;
  out Archive:ISzArchive; const Cancel:TFunc<Boolean>):TSzBorrowedInput;
const ClassID:TGUID='{23170F69-40C1-278A-1000-000110070000}';
var DLL:string; Factory:TSzFactory; MaxCheck:UInt64;
begin
  DLL:=FindExternalTool('7z.dll','7zip');
  if DLL='' then raise EMHLComponentRequired.Create('7-Zip','Для удаления книги из 7z нужен модуль 7-Zip.');
  Module:=LoadLibraryEx(PChar(TPath.GetFullPath(DLL)),0,$100 or $800);
  if Module=0 then RaiseLastOSError;
  @Factory:=GetProcAddress(Module,'CreateObject');
  if not Assigned(Factory) then raise ENotSupportedException.Create('Нет интерфейса 7-Zip.');
  Check(Factory(ClassID,ISzArchive,Archive),'создание читателя 7z');
  Result:=TSzBorrowedInput.Create; Result.Source:=Source; Result.Cancel:=Cancel; Input:=Result;
  MaxCheck:=0; Source.Position:=0; Check(Archive.Open(Input,@MaxCheck,nil),'чтение каталога 7z');
end;

function NamesIn(const Archive:ISzArchive):TArray<string>;
var Count:Cardinal; Value:OleVariant; Characters:Int64;
begin
  Check(Archive.GetNumberOfItems(Count),'список файлов');
  if Count>200000 then raise EReadError.Create('В архиве более 200 000 файлов.');
  SetLength(Result,Count); Characters:=0;
  for var I:=0 to Integer(Count)-1 do
  begin
    Value:=Unassigned; Check(Archive.GetProperty(I,3,Value),'имя файла');
    Result[I]:=VarToStr(Value); Inc(Characters,Length(Result[I]));
    if (Result[I]='') or (Characters>8*1024*1024) then raise EReadError.Create('Неверный список имён 7z.');
  end;
end;

function PlanSevenZipDeletion(Source:TStream; const Remove:TArray<string>;
  const Cancel:TFunc<Boolean>):TSevenZipDeletionLayout;
var Module:HMODULE; Input:ISzIn; Archive:ISzArchive; Writer:ISzWriter;
  InputObject:TSzBorrowedInput; OutputObject:TSzPlannedOutput;
  Output:ISzOut; CallbackObject:TSzKeepCallback; Callback:ISzUpdate;
  Names:TArray<string>; Index:TDictionary<string,Integer>; Deleted:TArray<Boolean>;
  Keep:TList<Cardinal>; Remaining:TList<string>; Value:OleVariant; Code:HRESULT;
begin
  Result:=Default(TSevenZipDeletionLayout); Module:=0; OutputObject:=nil; CallbackObject:=nil;
  Index:=TDictionary<string,Integer>.Create; Keep:=TList<Cardinal>.Create; Remaining:=TList<string>.Create;
  try
    if Length(Remove)=0 then raise EArgumentException.Create('Не выбраны файлы внутри 7z.');
    InputObject:=OpenSevenZip(Source,Module,Input,Archive,Cancel);
    Value:=Unassigned; Check(Archive.GetArchiveProperty(71,Value),'проверка ошибок 7z');
    if not VarIsEmpty(Value) and (Value<>0) then raise EReadError.Create('7z содержит ошибки заголовка.');
    Names:=NamesIn(Archive); SetLength(Deleted,Length(Names));
    for var I:=0 to High(Names) do
    begin
      var Name:=Names[I].Replace('\','/');
      if Index.ContainsKey(Name) then
        raise EReadError.Create('Неоднозначные имена внутри 7z: '+Name);
      Index.Add(Name,I);
    end;
    for var Requested in Remove do
    begin
      var I:Integer;
      if not Index.TryGetValue(Requested.Replace('\','/'),I) or (I<0) then
        raise EReadError.Create('Файл внутри 7z не найден однозначно: '+Requested);
      Value:=Unassigned; Check(Archive.GetProperty(I,6,Value),'тип файла');
      if not VarIsEmpty(Value) and Boolean(Value) then raise EReadError.Create('Вместо книги выбрана папка 7z.');
      Deleted[I]:=True;
    end;
    for var I:=0 to High(Names) do if not Deleted[I] then begin Keep.Add(I); Remaining.Add(Names[I]); end;
    if not Supports(Archive,ISzWriter,Writer) then raise ENotSupportedException.Create('Модуль 7-Zip не поддерживает изменение архива.');
    CallbackObject:=TSzKeepCallback.Create; Callback:=CallbackObject;
    CallbackObject.Keep:=Keep.ToArray; CallbackObject.Cancel:=Cancel;
    OutputObject:=TSzPlannedOutput.Create(InputObject); Output:=OutputObject;
    Code:=Writer.UpdateItems(Output,Keep.Count,Callback);
    if Assigned(Cancel) and Cancel() then Abort;
    if CallbackObject.RepackRequested then
      raise ENotSupportedException.Create('Эти книги находятся в общем solid-блоке 7z. Без перепаковки блока удалить их данные нельзя. Архив не изменён.');
    if OutputObject.Error<>'' then raise EWriteError.Create(OutputObject.Error);
    if InputObject.Error<>'' then raise EReadError.Create(InputObject.Error);
    Check(Code,'подготовка удаления из 7z');
    if (OutputObject.TailStart<0) and (OutputObject.Size=32) and (OutputObject.Ranges.Count=0) then
      OutputObject.TailStart:=32;
    if (OutputObject.Header.Size<>32) or (OutputObject.TailStart<32) or
      (OutputObject.Size<>OutputObject.TailStart+OutputObject.Tail.Size) or
      (OutputObject.Size>Source.Size) then raise EReadError.Create('Неподдерживаемое размещение 7z.');
    if OutputObject.Ranges.Count=0 then
    begin
      if OutputObject.TailStart<>32 then raise EReadError.Create('Пропущены данные 7z.');
    end
    else
    begin
      var Last:=OutputObject.Ranges[OutputObject.Ranges.Count-1];
      if Last.Target+Last.Bytes<>OutputObject.TailStart then raise EReadError.Create('Пропущен конец данных 7z.');
    end;
    SetLength(Result.Header,32); OutputObject.Header.Position:=0;
    OutputObject.Header.ReadBuffer(Result.Header[0],32);
    SetLength(Result.Tail,Integer(OutputObject.Tail.Size)); OutputObject.Tail.Position:=0;
    if Length(Result.Tail)>0 then OutputObject.Tail.ReadBuffer(Result.Tail[0],Length(Result.Tail));
    Result.Ranges:=OutputObject.Ranges.ToArray; Result.Remaining:=Remaining.ToArray;
    Result.TailOffset:=OutputObject.TailStart; Result.FinalSize:=OutputObject.Size;
  finally
    Index.Free; Keep.Free; Remaining.Free;
    Callback:=nil; Output:=nil; Writer:=nil;
    if Assigned(Archive) then Archive.Close;
    Archive:=nil; Input:=nil;
    if Module<>0 then FreeLibrary(Module);
  end;
end;

procedure VerifySevenZipInventory(Source:TStream; const Names:TArray<string>);
var Module:HMODULE; Input:ISzIn; Archive:ISzArchive; Seen:TDictionary<string,Byte>;
begin
  Module:=0; Seen:=TDictionary<string,Byte>.Create;
  try
    OpenSevenZip(Source,Module,Input,Archive,nil);
    for var Name in Names do
    begin
      if Seen.ContainsKey(Name) then raise EReadError.Create('Повторяющееся имя в плане 7z.');
      Seen.Add(Name,0);
    end;
    var Actual:=NamesIn(Archive);
    if Length(Actual)<>Length(Names) then raise EReadError.Create('Изменилось число файлов 7z.');
    for var Name in Actual do
      if not Seen.ContainsKey(Name) or (Seen[Name]<>0) then raise EReadError.Create('Изменился список файлов 7z.')
      else Seen[Name]:=1;
  finally
    Seen.Free;
    if Assigned(Archive) then Archive.Close;
    Archive:=nil; Input:=nil;
    if Module<>0 then FreeLibrary(Module);
  end;
end;

end.
