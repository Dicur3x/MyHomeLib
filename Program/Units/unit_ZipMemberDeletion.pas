unit unit_ZipMemberDeletion;

interface

uses System.Classes, System.SysUtils, System.JSON;

const
  ArchiveDeletionWriteStage = 'Удаление из архива';
  ArchiveDeletionRepackStage = 'Перепаковываем архив без удалённых книг';

type
  TZipDeleteProgress = reference to procedure(const Stage: string; Done, Total: Int64);
  TZipDeleteFault = reference to procedure(const Stage: string; Chunk: Integer);

  // Confirmed deletions recover forwards. The journal contains metadata,
  // hashes and one bounded in-flight block, never a copy of the archive.
  TZipMemberDeletion = class
  private
    FSource: TFileStream;
    FReplacement: TFileStream;
    FReplacementSize: Int64;
    FPlan: TJSONObject;
    FArchive, FJob, FPlanHash: string;
    FMetadata, FHeader: TBytes;
    FNext: Integer;
    FPending, FFinished: Boolean;
    FWholeIdentity: string;
    FWholeHandle: THandle;
    FStagingDirectory: string;
    FStagingGuard: THandle;
    function Chunks: TJSONArray;
    function ReadAt(Offset: Int64; Count: Integer): TBytes;
    function ReadChunkSource(Source: TJSONValue; Count: Integer): TBytes;
    procedure CheckIdentity;
    procedure CheckPlan;
    procedure SaveCheckpoint(const Directory: string = '');
    procedure VerifyFinished;
    procedure PrepareSevenZip(const Names:TArray<string>; const Cancelled:TFunc<Boolean>;
      AllowRepack:Boolean; const JournalParent:string; const Progress:TZipDeleteProgress);
    procedure DiscardStaging;
    procedure OpenReplacement(const Directory:string);
    function GetContextHash: string;
    function GetFileKey: string;
    function GetWholeSourceMissing: Boolean;
    function CanRemoveWhole: Boolean;
    procedure OpenWholeSource(AllowMissing: Boolean);
    function ChunkHash(Index: Integer): string;
    function ChunkReplacement(Index: Integer): TBytes;
    function ChunkNumber(Index, Field: Integer): Int64;
  protected
    function JournalSpaceAvailable(const Directory: string): UInt64; virtual;
  public
    constructor Prepare(const Archive: string; const Names: TArray<string>;
      const Progress: TZipDeleteProgress = nil; const Cancelled: TFunc<Boolean> = nil;
      const ExpectedSourceIdentity: string = ''; AllowSevenZipRepack: Boolean = False;
      const JournalParent: string = '');
    constructor PrepareWholeArchive(const Archive, ExpectedSourceIdentity: string);
    constructor Recover(const Archive, Job: string);
    destructor Destroy; override;
    procedure Execute(const JournalParent: string; const Progress: TZipDeleteProgress = nil;
      const Fault: TZipDeleteFault = nil);
    // The caller acknowledges only after its catalogue changes are durable.
    procedure Acknowledge(const BeforeForget: TProc = nil);
    procedure RemoveEmptyArchive;
    procedure RequirePrivateSource;
    // Use only for a queue that commits the matching catalogue changes
    // before acknowledging and removing the original archive.
    procedure EnableWholeRemoval;
    // Bind the catalogue receipt before the first destructive write. The
    // persisted plan/checkpoint then protects this association on recovery.
    procedure BindContext(const SHA256: string);
    property ContextHash: string read GetContextHash;
    property FileKey: string read GetFileKey;
    property WholeSourceIdentity: string read FWholeIdentity;
    property WholeSourceMissing: Boolean read GetWholeSourceMissing;
    function BytesToProcess: Int64;
    function JournalBytes: Int64;
    property JobDirectory: string read FJob;
    property Finished: Boolean read FFinished;
  end;

// Adjacent atomic-save names are longer than their short JSON target. Keep
// journal I/O independent of MAX_PATH even in a deep portable profile.
function DeletionNativePath(const FileName: string): string;
function ArchiveDeletionSourceIdentity(const FileName: string): string;
function IsPrivateArchiveDeletionSource(const FileName: string): Boolean;
function DiscardUnpublishedDeletionStages(const Parent: string): Boolean;

implementation

uses Winapi.Windows, System.IOUtils, System.Zip, System.Hash, System.NetEncoding,
  System.Math, System.Generics.Collections, System.Generics.Defaults,
  unit_AtomicIniFile, unit_SevenZipDeletionPlan;

const
  BlockBytes = 4 * 1024 * 1024;
  MaxChunkRanges = 512;
  ZipGroupedRangesSchema = 5;
  SevenZipGroupedRangesSchema = 6;
  MaxMetadataBytes = 64 * 1024 * 1024;
  MaxPlanBytes = 192 * 1024 * 1024;
  PlanName = 'plan.json';
  CheckpointName = 'checkpoint.json';
  PendingName = 'pending.bin';
  ReplacementName = 'replacement.bin';
  StagePrefix = 'zip-stage-';
  DeleteAccess = $00010000;
  FileDispositionInfoClass = 4;

function SetArchiveFileInformation(Handle: THandle; InformationClass: Integer;
  Information: Pointer; Size: DWORD): BOOL; stdcall;
  external kernel32 name 'SetFileInformationByHandle';

type
  // Capture the original directory position and raw comment from System.Zip
  // without writing to the archive. Execute alone moves the payload.
  TZipDirectoryPlanStream = class(TStream)
  private
    FInput: TStream;
    FPosition, FSize: Int64;
  protected
    function GetSize: Int64; override;
    procedure SetSize(const NewSize: Int64); override;
  public
    Capturing: Boolean;
    Metadata: TMemoryStream;
    MetadataOffset: Int64;
    constructor Create(Input: TStream);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function DeletionNativePath(const FileName: string): string;
begin
  Result:=ExpandFileName(FileName);
  if Result.StartsWith('\\?\') then Exit;
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Result.Substring(2)
  else Result:='\\?\'+Result;
end;

function RemoveStagingDirectory(const Directory:string):Boolean;
begin
  var Attributes:=GetFileAttributes(PChar(DeletionNativePath(Directory)));
  if (Attributes=INVALID_FILE_ATTRIBUTES) or (Attributes and FILE_ATTRIBUTE_DIRECTORY=0) or
    (Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then Exit(False);
  for var Name in [ReplacementName,CheckpointName,PlanName] do
  begin
    var FileName:=DeletionNativePath(TPath.Combine(Directory,Name));
    Attributes:=GetFileAttributes(PChar(FileName));
    if Attributes=INVALID_FILE_ATTRIBUTES then Continue;
    if (Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
      not System.SysUtils.DeleteFile(FileName) then Exit(False);
  end;
  Result:=RemoveDirectory(PChar(DeletionNativePath(Directory)));
end;

function DiscardUnpublishedDeletionStages(const Parent:string):Boolean;
var ID:TGUID;
begin
  Result:=False;
  for var Directory in TDirectory.GetDirectories(DeletionNativePath(Parent),StagePrefix+'*') do
  begin
    var Name:=ExtractFileName(Directory);
    if Length(Name)<>Length(StagePrefix)+38 then Continue;
    try ID:=StringToGUID(Name.Substring(Length(StagePrefix)));
    except on E:EConvertError do Continue; end;
    if not SameText(Name,StagePrefix+ID.ToString) then Continue;
    if GetFileAttributes(PChar(Directory+'.lock'))<>INVALID_FILE_ATTRIBUTES then Continue;
    // A sharing error also means another process may still own the stage.
    if GetLastError<>ERROR_FILE_NOT_FOUND then Continue;
    Result:=RemoveStagingDirectory(Directory) or Result;
  end;
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
  try SaveStreamAtomically(Stream, DeletionNativePath(Name)); finally Stream.Free; end;
end;

procedure SaveObject(Obj: TJSONObject; const Name: string);
begin SaveBytes(TEncoding.UTF8.GetBytes(Obj.ToJSON), Name); end;

procedure WriteStagedBytes(const Bytes:TBytes; const Name:string);
var Stream:TFileStream;
begin
  // The enclosing directory is still private to the planner and will be
  // published as a unit. No extra temporary file is needed inside it.
  Stream:=TFileStream.Create(DeletionNativePath(Name),fmCreate);
  try
    if Length(Bytes)>0 then Stream.WriteBuffer(Bytes[0],Length(Bytes));
    if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError;
  finally Stream.Free; end;
end;

function LoadObject(const Name: string): TJSONObject;
var Stream: TFileStream; Data: TBytes; Value: TJSONValue;
begin
  Stream := TFileStream.Create(DeletionNativePath(Name), fmOpenRead or fmShareDenyWrite);
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

function SourceIdentity(Handle:THandle):string;
var Info:TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  Result:=ArchiveKey(Handle)+':'+IntToHex(Info.nFileSizeHigh,8)+IntToHex(Info.nFileSizeLow,8)+':'+
    IntToHex(Info.ftLastWriteTime.dwHighDateTime,8)+IntToHex(Info.ftLastWriteTime.dwLowDateTime,8);
end;

function ArchiveDeletionSourceIdentity(const FileName:string):string;
var Handle:THandle;
begin
  Handle:=CreateFile(PChar(DeletionNativePath(FileName)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try Result:=SourceIdentity(Handle); finally CloseHandle(Handle); end;
end;

function IsPrivateArchiveDeletionSource(const FileName:string):Boolean;
var Handle:THandle; Info:TByHandleFileInformation;
begin
  Handle:=CreateFile(PChar(DeletionNativePath(FileName)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then Exit(False);
  try
    Result:=GetFileInformationByHandle(Handle,Info) and (Info.nNumberOfLinks=1) and
      (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)=0);
  finally CloseHandle(Handle); end;
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
  FInput.Position := FPosition; Result := FInput.Read(Buffer, Count);
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
  end;
  Inc(FPosition, Count); FSize := Max(FSize, FPosition); Result := Count;
end;

function Zip64ExtraPosition(const Extra: TBytes; out FieldSize: Word): Integer;
const Zip64Field = 1;
var FieldID: Word;
begin
  Result:=0;
  while Result+4<=Length(Extra) do
  begin
    Move(Extra[Result],FieldID,SizeOf(FieldID));
    Move(Extra[Result+2],FieldSize,SizeOf(FieldSize));
    if Result+4+FieldSize>Length(Extra) then Break;
    if FieldID=Zip64Field then Exit;
    Inc(Result,4+FieldSize);
  end;
  raise EReadError.Create('Повреждено дополнительное поле ZIP64.');
end;

procedure SetZipHeaderOffset(var Header: TZipHeader; Offset: UInt64);
var OriginalOffset: UInt64; FieldSize: Word; Pos, Skip: Integer;
begin
  OriginalOffset:=Header.LocalHeaderOffset64;
  if Offset=OriginalOffset then Exit;
  if Offset>OriginalOffset then raise EReadError.Create('Неверное смещение сохранённого файла ZIP.');
  if Header.LocalHeaderOffset<>High(Cardinal) then
    Header.LocalHeaderOffset:=Cardinal(Offset)
  else
  begin
    // A central ZIP64 extra field can contain just its offset. Keep its
    // original layout and update only the bytes occupied by the offset.
    Pos:=Zip64ExtraPosition(Header.ExtraField,FieldSize)+4;
    Skip:=0;
    if Header.UncompressedSize=High(Cardinal) then Inc(Skip,SizeOf(UInt64));
    if Header.CompressedSize=High(Cardinal) then Inc(Skip,SizeOf(UInt64));
    if Skip+SizeOf(Offset)>FieldSize then raise EReadError.Create('Повреждено смещение ZIP64.');
    Header.ExtraField:=Copy(Header.ExtraField);
    Move(Offset,Header.ExtraField[Pos+Skip],SizeOf(Offset));
  end;
end;

function NeedsZip64Directory(Count: Integer; Offset: Int64): Boolean;
begin
  Result:=(Count>=High(Word)) or (Offset>=ZIP64_MAXINT);
end;

function CapturedZipComment(const Capture: TZipDirectoryPlanStream;
  const Headers: TArray<TZipHeader>): TBytes;
var CommentOffset, Count: Int64;
begin
  CommentOffset:=SizeOf(UInt32)+SizeOf(TZipEndOfCentralHeader);
  if NeedsZip64Directory(Length(Headers),Capture.MetadataOffset) then
    Inc(CommentOffset,SizeOf(TZip64Header)+SizeOf(TZip64EndOfCentralHeader));
  for var Header in Headers do
    Inc(CommentOffset,SizeOf(UInt32)+CENTRALHEADERSIZE+Header.FileNameLength+
      Header.ExtraFieldLength+Header.FileCommentLength);
  Count:=Capture.Metadata.Size-CommentOffset;
  if (Count<0) or (Count>High(Word)) then raise EReadError.Create('Неверный комментарий архива ZIP.');
  SetLength(Result,Integer(Count));
  if Count>0 then
  begin
    Capture.Metadata.Position:=CommentOffset;
    Capture.Metadata.ReadBuffer(Result[0],Length(Result));
  end;
end;

procedure WriteZipDirectoryEnd(Stream: TStream; Count: Integer; Offset: Int64; const Comment: TBytes);
var Ending: TZipEndOfCentralHeader; Header: TZip64Header; Locator: TZip64EndOfCentralHeader;
  Signature: UInt32;
begin
  Ending:=Default(TZipEndOfCentralHeader);
  if NeedsZip64Directory(Count,Offset) then
  begin
    Header:=Default(TZip64Header);
    Header.Signature:=SIGNATURE_ZIP64CENTRALHEADER;
    Header.HeaderSize:=SizeOf(TZip64Header)-SizeOf(UInt32)-SizeOf(Int64);
    Header.MadeByVersion:=45; Header.RequiredVersion:=45;
    Header.NumEntriesThisDisk:=Count; Header.CentralDirEntries:=Count;
    Header.CentralDirSize:=Stream.Size; Header.CentralDirOffset:=Offset;
    Locator:=Default(TZip64EndOfCentralHeader);
    Locator.Signature:=SIGNATURE_ZIP64ENDOFHEADER;
    Locator.Zip64CentralDirOffset:=UInt64(Offset)+UInt64(Stream.Size);
    Locator.TotalNumberOfDisks:=1;
    Stream.WriteBuffer(Header,SizeOf(Header));
    Stream.WriteBuffer(Locator,SizeOf(Locator));
    Ending.NumEntriesThisDisk:=High(Word); Ending.CentralDirEntries:=High(Word);
    Ending.CentralDirSize:=ZIP64_MAXINT; Ending.CentralDirOffset:=ZIP64_MAXINT;
  end
  else
  begin
    Ending.NumEntriesThisDisk:=Count; Ending.CentralDirEntries:=Count;
    Ending.CentralDirSize:=Stream.Size; Ending.CentralDirOffset:=Offset;
  end;
  Ending.CommentLength:=Length(Comment);
  Signature:=SIGNATURE_ZIPENDOFHEADER;
  Stream.WriteBuffer(Signature,SizeOf(Signature));
  Stream.WriteBuffer(Ending,SizeOf(Ending));
  if Length(Comment)>0 then Stream.WriteBuffer(Comment[0],Length(Comment));
end;

function TZipMemberDeletion.ReadAt(Offset: Int64; Count: Integer): TBytes;
begin
  if (Offset < 0) or (Count < 0) or (Count > BlockBytes) or
    (Offset > FSource.Size) or (Count > FSource.Size-Offset) then
    raise EReadError.Create('Недоступен блок архива ZIP.');
  SetLength(Result, Count); FSource.Position := Offset;
  if Count > 0 then FSource.ReadBuffer(Result[0], Count);
end;

function TZipMemberDeletion.ReadChunkSource(Source: TJSONValue; Count: Integer): TBytes;
var Position, PartSize: Integer;
begin
  if not (Source is TJSONArray) then Exit(ReadAt(Number(Source),Count));
  SetLength(Result,Count);
  Position:=0;
  // Read the full group before writing. Some original bytes can overlap
  // the compacted destination of this same group.
  for var Value in TJSONArray(Source) do
  begin
    var Part:=Value as TJSONArray;
    PartSize:=Integer(Number(Part.Items[1]));
    FSource.Position:=Number(Part.Items[0]);
    FSource.ReadBuffer(Result[Position],PartSize);
    Inc(Position,PartSize);
  end;
end;

function TZipMemberDeletion.Chunks: TJSONArray;
begin Result := FPlan.GetValue('chunks') as TJSONArray; end;

function TZipMemberDeletion.ChunkNumber(Index, Field: Integer): Int64;
begin Result := Number((Chunks.Items[Index] as TJSONArray).Items[Field]); end;

function TZipMemberDeletion.ChunkHash(Index: Integer): string;
begin Result := (Chunks.Items[Index] as TJSONArray).Items[3].Value; end;

function TZipMemberDeletion.ChunkReplacement(Index: Integer): TBytes;
begin
  var Chunk:=Chunks.Items[Index] as TJSONArray;
  if Chunk.Items[4] is TJSONString then
    Exit(TNetEncoding.Base64.DecodeStringToBytes(Chunk.Items[4].Value));
  if not Assigned(FReplacement) then raise EReadError.Create('Отсутствуют пересжатые данные журнала 7z.');
  FReplacement.Position:=Number(Chunk.Items[4]);
  SetLength(Result,Integer(ChunkNumber(Index,2)));
  FReplacement.ReadBuffer(Result[0],Length(Result));
end;

procedure TZipMemberDeletion.OpenReplacement(const Directory:string);
begin
  var Path:=DeletionNativePath(TPath.Combine(Directory,ReplacementName));
  var Attributes:=GetFileAttributes(PChar(Path));
  if (Attributes=INVALID_FILE_ATTRIBUTES) or
    (Attributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) then
    raise EReadError.Create('Пересжатые данные журнала 7z отсутствуют или недоступны.');
  FReplacement:=TFileStream.Create(Path,fmOpenRead or fmShareExclusive);
end;

function TZipMemberDeletion.GetContextHash: string;
begin
  var Value:=FPlan.GetValue('contextHash');
  if not Assigned(Value) then Exit('');
  if not (Value is TJSONString) then raise EReadError.Create('Повреждена привязка каталога в журнале удаления.');
  Result:=Value.Value;
end;

procedure TZipMemberDeletion.BindContext(const SHA256: string);
begin
  if (FJob<>'') or (ContextHash<>'') then
    raise EInvalidOperation.Create('Привязку каталога нельзя менять после начала удаления.');
  if Length(SHA256)<>64 then raise EArgumentException.Create('Неверная контрольная сумма привязки каталога.');
  for var C in SHA256 do if not CharInSet(C,['0'..'9','a'..'f']) then
    raise EArgumentException.Create('Неверная контрольная сумма привязки каталога.');
  FPlan.AddPair('contextHash',SHA256);
end;

procedure TZipMemberDeletion.CheckIdentity;
begin
  if TextField(FPlan,'archive')<>FArchive then
    raise EReadError.Create('Архив был заменён. Журнал удаления не применён к другому файлу.');
  if FWholeIdentity<>'' then
  begin
    if (Length(FWholeIdentity)<>59) or (Copy(FWholeIdentity,1,25)<>FileKey) or
      ((FWholeHandle<>0) and (SourceIdentity(FWholeHandle)<>FWholeIdentity)) then
      raise EReadError.Create('Архив изменился. Удаление целого архива остановлено.');
  end
  else if FileKey<>ArchiveKey(FSource.Handle) then
    raise EReadError.Create('Архив был заменён. Журнал удаления не применён к другому файлу.');
end;

function TZipMemberDeletion.GetFileKey:string;
begin Result:=TextField(FPlan,'fileId'); end;

function TZipMemberDeletion.GetWholeSourceMissing:Boolean;
begin Result:=(FWholeIdentity<>'') and (FWholeHandle=0); end;

function TZipMemberDeletion.CanRemoveWhole:Boolean;
begin
  Result:=((FPlan.GetValue('remaining') as TJSONArray).Count=0) and
    (FieldNumber(FPlan,'metadataOffset')=Length(FHeader)) and (Chunks.Count=0);
end;

procedure TZipMemberDeletion.OpenWholeSource(AllowMissing:Boolean);
var Handle:THandle; Info:TByHandleFileInformation;
begin
  Handle:=CreateFile(PChar(DeletionNativePath(FArchive)),GENERIC_READ or DeleteAccess,
    0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    var Error:=GetLastError;
    if AllowMissing and (Error=ERROR_FILE_NOT_FOUND) then Exit;
    RaiseLastOSError(Error);
  end;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.nNumberOfLinks<>1) or
      ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0) or
      (SourceIdentity(Handle)<>FWholeIdentity) then
      raise EReadError.Create('Путь или файл архива изменился. Архив не удалён.');
    FWholeHandle:=Handle;
  except
    CloseHandle(Handle);
    raise;
  end;
end;

procedure TZipMemberDeletion.EnableWholeRemoval;
var Info:TByHandleFileInformation;
begin
  if (FJob<>'') or (FWholeIdentity<>'') or not CanRemoveWhole then Exit;
  if not GetFileInformationByHandle(FSource.Handle,Info) then RaiseLastOSError;
  // Multiple hard links must keep their names. Continue with member removal.
  if Info.nNumberOfLinks<>1 then Exit;
  FWholeIdentity:=SourceIdentity(FSource.Handle);
  FreeAndNil(FSource);
  OpenWholeSource(False);
  FPlan.AddPair('wholeIdentity',FWholeIdentity);
end;

procedure TZipMemberDeletion.CheckPlan;
var ArrayItem: TJSONValue; Item: TJSONArray; Target, Count, EndSource, EndTarget: Int64;
  Hash: string; Schema, ReplacementBytes, OriginalSize, MetadataOffset: Int64;

  procedure CheckSourceRange(Source, Destination, Size: Int64);
  begin
    if (((Schema<3) or (Schema=ZipGroupedRangesSchema)) and (Source<EndSource)) or
      (Source<Destination) or (Source>OriginalSize-Size) then
      raise EReadError.Create('Некорректный исходный диапазон архива.');
    EndSource:=Source+Size;
  end;

begin
  CheckIdentity;
  Schema:=FieldNumber(FPlan,'schema');
  ReplacementBytes:=0;
  if not (Schema in [1,2,3,4,ZipGroupedRangesSchema,SevenZipGroupedRangesSchema]) or
    not (FPlan.GetValue('chunks') is TJSONArray) or
    not (FPlan.GetValue('remaining') is TJSONArray) or
    (Chunks.Count > 1048576) then raise EReadError.Create('Неподдерживаемый журнал удаления ZIP.');
  FMetadata := TNetEncoding.Base64.DecodeStringToBytes(TextField(FPlan,'metadata'));
  FHeader:=nil;
  if Schema in [2,3,4,SevenZipGroupedRangesSchema] then
  begin
    if TextField(FPlan,'format')<>'7z' then raise EReadError.Create('Неизвестный формат журнала удаления.');
    FHeader:=TNetEncoding.Base64.DecodeStringToBytes(TextField(FPlan,'header'));
    if Length(FHeader)<>32 then raise EReadError.Create('Повреждён заголовок плана 7z.');
  end;
  OriginalSize:=FieldNumber(FPlan,'originalSize');
  MetadataOffset:=FieldNumber(FPlan,'metadataOffset');
  if ((Length(FMetadata)=0) and (Length(FHeader)=0) and
      ((FWholeIdentity='') or not CanRemoveWhole or (FieldNumber(FPlan,'finalSize')<>0))) or
    (Length(FMetadata) > MaxMetadataBytes) or
    (OriginalSize < FieldNumber(FPlan,'finalSize')) or (MetadataOffset < 0) or
    (FieldNumber(FPlan,'finalSize')-Length(FMetadata) <> MetadataOffset) then
    raise EReadError.Create('Повреждён план удаления ZIP.');
  EndTarget := FieldNumber(FPlan,'untouchedEnd'); EndSource := EndTarget;
  if (EndTarget<0) or (EndTarget>MetadataOffset) then
    raise EReadError.Create('Неверная граница неизменяемого участка ZIP.');
  for ArrayItem in Chunks do
  begin
    if not (ArrayItem is TJSONArray) or not (TJSONArray(ArrayItem).Count in [4,5]) then
      raise EReadError.Create('Повреждён блок плана ZIP.');
    Item := TJSONArray(ArrayItem);
    Target := Number(Item.Items[1]); Count := Number(Item.Items[2]);
    Hash := Item.Items[3].Value;
    if (Target <> EndTarget) or (Count <= 0) or (Count > BlockBytes) or
      (Target > MetadataOffset-Count) or
      (Length(Hash) <> 64) then raise EReadError.Create('Некорректные границы перемещения в ZIP.');
    if Item.Count=5 then
    begin
      if not (Schema in [3,4,SevenZipGroupedRangesSchema]) or (Number(Item.Items[0])<>-1) then
        raise EReadError.Create('Некорректный пересжатый блок 7z.');
      if Schema=3 then
      begin
        if not (Item.Items[4] is TJSONString) or (ReplacementBytes+Count>MaxSevenZipInlineReplacementBytes) then
          raise EReadError.Create('Некорректный встроенный блок журнала 7z.');
        var Payload:=TNetEncoding.Base64.DecodeStringToBytes(Item.Items[4].Value);
        if (Length(Payload)<>Count) or (Digest(Payload)<>Hash) then
          raise EReadError.Create('Пересжатый блок 7z не совпадает с журналом.');
      end
      else if Number(Item.Items[4])<>ReplacementBytes then
        raise EReadError.Create('Неверное смещение пересжатого блока журнала 7z.');
      Inc(ReplacementBytes,Count);
    end
    else if Item.Items[0] is TJSONArray then
    begin
      var Ranges:=TJSONArray(Item.Items[0]);
      if not (Schema in [ZipGroupedRangesSchema,SevenZipGroupedRangesSchema]) or
        (Ranges.Count<2) or (Ranges.Count>MaxChunkRanges) then
        raise EReadError.Create('Некорректная группа исходных диапазонов ZIP.');
      var Used:Int64:=0;
      for var Range in Ranges do
      begin
        if not (Range is TJSONArray) or (TJSONArray(Range).Count<>2) then
          raise EReadError.Create('Повреждён исходный диапазон ZIP.');
        var Part:=TJSONArray(Range);
        var Size:=Number(Part.Items[1]);
        if (Size<=0) or (Size>Count-Used) then raise EReadError.Create('Некорректный размер диапазона ZIP.');
        CheckSourceRange(Number(Part.Items[0]),Target+Used,Size);
        Inc(Used,Size);
      end;
      if Used<>Count then raise EReadError.Create('Группа исходных диапазонов ZIP неполная.');
    end
    else CheckSourceRange(Number(Item.Items[0]),Target,Count);
    for var Ch in Hash do if not CharInSet(Ch,['0'..'9','a'..'f']) then
      raise EReadError.Create('Повреждена контрольная сумма блока ZIP.');
    EndTarget := Target+Count;
  end;
  if EndTarget <> MetadataOffset then
    raise EReadError.Create('План ZIP оставляет непроверенный участок.');
  if Schema in [4,SevenZipGroupedRangesSchema] then
  begin
    if ((Schema=4) and (ReplacementBytes=0)) or
      ((Schema=SevenZipGroupedRangesSchema) and
        (ReplacementBytes<>FieldNumber(FPlan,'replacementBytes'))) or
      ((ReplacementBytes>0) and not FFinished and
        ((not Assigned(FReplacement)) or (FReplacement.Size<>ReplacementBytes))) then
      raise EReadError.Create('Неверный размер пересжатых данных журнала 7z.');
    FReplacementSize:=ReplacementBytes;
  end;
end;

procedure TZipMemberDeletion.PrepareSevenZip(const Names:TArray<string>;
  const Cancelled:TFunc<Boolean>; AllowRepack:Boolean; const JournalParent:string; const Progress:TZipDeleteProgress);
var Layout:TSevenZipDeletionLayout; List, Parts:TJSONArray; Untouched, SourceEnd, ReplacementBytes:Int64;
  Schema, GroupBytes, GroupLimit:Integer; FirstRange:TSevenZipRetainedRange; HasGroups:Boolean;
  Report:TProc<Int64,Int64>;

  procedure AddChunk(const Range:TSevenZipRetainedRange; var Sources:TJSONArray; Size:Integer);
  begin
    var Item:=TJSONArray.Create;
    try
      if Assigned(Sources) and (Sources.Count>1) then
      begin
        Item.AddElement(Sources);
        Sources:=nil;
        HasGroups:=True;
      end
      else Item.AddElement(TJSONNumber.Create(Range.Source));
      Item.AddElement(TJSONNumber.Create(Range.Target));
      Item.AddElement(TJSONNumber.Create(Size));
      if Item.Items[0] is TJSONArray then Item.Add(Digest(ReadChunkSource(Item.Items[0],Size)))
      else Item.Add(Range.SHA256);
      if Length(Range.Replacement)>0 then Item.Add(TNetEncoding.Base64.EncodeBytesToString(Range.Replacement));
      if (Schema=4) and (Range.Source=-1) then Item.AddElement(TJSONNumber.Create(Range.ReplacementOffset));
      Chunks.AddElement(Item);
      Item:=nil;
    finally Item.Free; end;
  end;

  procedure FinishGroup;
  begin
    if not Assigned(Parts) then Exit;
    AddChunk(FirstRange,Parts,GroupBytes);
    FreeAndNil(Parts);
    GroupBytes:=0;
  end;

begin
  if AllowRepack and (JournalParent<>'') then
  begin
    ForceDirectories(DeletionNativePath(JournalParent));
    var Stage:=TPath.Combine(ExpandFileName(JournalParent),StagePrefix+TGUID.NewGuid.ToString);
    FStagingGuard:=CreateFile(PChar(DeletionNativePath(Stage+'.lock')),DeleteAccess,
      0,nil,CREATE_NEW,FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE,0);
    if FStagingGuard=INVALID_HANDLE_VALUE then
    begin FStagingGuard:=0; RaiseLastOSError; end;
    if not CreateDirectory(PChar(DeletionNativePath(Stage)),nil) then RaiseLastOSError;
    FStagingDirectory:=Stage;
    FReplacement:=TFileStream.Create(DeletionNativePath(TPath.Combine(Stage,ReplacementName)),fmCreate);
  end;
  if Assigned(Progress) then
    Report:=procedure(Done,Total:Int64) begin Progress(ArchiveDeletionRepackStage,Done,Total); end;
  Layout:=PlanSevenZipDeletion(FSource,Names,Cancelled,AllowRepack,FReplacement,Report);
  if Assigned(FReplacement) and (FReplacement.Size=0) then DiscardStaging;
  Schema:=2; SourceEnd:=32;
  for var Range in Layout.Ranges do
  begin
    if (Range.Source<SourceEnd) then Schema:=3;
    SourceEnd:=Range.Source+Range.Bytes;
  end;
  if Assigned(FReplacement) then Schema:=4;
  FPlan:=TJSONObject.Create;
  FPlan.AddPair('format','7z');
  FPlan.AddPair('archive',FArchive); FPlan.AddPair('fileId',ArchiveKey(FSource.Handle));
  FPlan.AddPair('originalSize',TJSONNumber.Create(FSource.Size));
  FPlan.AddPair('finalSize',TJSONNumber.Create(Layout.FinalSize));
  FPlan.AddPair('metadataOffset',TJSONNumber.Create(Layout.TailOffset));
  FPlan.AddPair('metadata',TNetEncoding.Base64.EncodeBytesToString(Layout.Tail));
  FPlan.AddPair('header',TNetEncoding.Base64.EncodeBytesToString(Layout.Header));
  FPlan.AddPair('chunks',TJSONArray.Create); Untouched:=32;
  Parts:=nil; GroupBytes:=0; GroupLimit:=SevenZipRecoveryBlockBytes(FSource.Size); HasGroups:=False;
  try
    for var Range in Layout.Ranges do
    begin
      if Assigned(Cancelled) and Cancelled() then Abort;
      if (Range.Source=Range.Target) and (Range.Target=Untouched) then
      begin
        Inc(Untouched,Range.Bytes);
        Continue;
      end;
      if (Range.Source<0) or (Schema=3) then
      begin
        FinishGroup;
        AddChunk(Range,Parts,Range.Bytes);
        Continue;
      end;
      // The complete borrowed group is read before its destination changes.
      // Keep generated bytes separate so the journal stores them only once.
      if (GroupBytes+Range.Bytes>GroupLimit) or
        (Assigned(Parts) and (Parts.Count=MaxChunkRanges)) then FinishGroup;
      if not Assigned(Parts) then
      begin
        FirstRange:=Range;
        Parts:=TJSONArray.Create;
      end;
      var Part:=TJSONArray.Create;
      Parts.AddElement(Part);
      Part.AddElement(TJSONNumber.Create(Range.Source));
      Part.AddElement(TJSONNumber.Create(Range.Bytes));
      Inc(GroupBytes,Range.Bytes);
    end;
    FinishGroup;
  finally Parts.Free; end;
  if HasGroups then
  begin
    ReplacementBytes:=0;
    if Assigned(FReplacement) then ReplacementBytes:=FReplacement.Size;
    FPlan.AddPair('replacementBytes',TJSONNumber.Create(ReplacementBytes));
    Schema:=SevenZipGroupedRangesSchema;
  end;
  FPlan.AddPair('schema',TJSONNumber.Create(Schema));
  FPlan.AddPair('untouchedEnd',TJSONNumber.Create(Untouched));
  List:=TJSONArray.Create; FPlan.AddPair('remaining',List);
  for var Name in Layout.Remaining do List.Add(Name);
  CheckPlan;
end;

constructor TZipMemberDeletion.Prepare(const Archive: string; const Names: TArray<string>;
  const Progress: TZipDeleteProgress; const Cancelled: TFunc<Boolean>;
  const ExpectedSourceIdentity: string; AllowSevenZipRepack: Boolean; const JournalParent:string);
var Zip: TZipFile; Virtual: TZipDirectoryPlanStream; Headers: TArray<TZipHeader>;
  OriginalNames: TArray<string>; Remove: TArray<Boolean>; Order: TArray<Integer>;
  OriginalOffsets, FinalOffsets: TArray<Int64>; RangeSource, RangeTarget, RangeLength: Int64;
  OriginalEnd, CurrentEnd, Offset, Destination, Remaining, Total, Done, UntouchedEnd: Int64;
  Indices: TDictionary<string,Integer>; OriginalEndByIndex: TArray<Int64>;
  Metadata, Comment: TBytes; Requested, Key: string; Index, RetainedCount: Integer;
  HeaderSignature: UInt32;
  Ranges, Keep: TJSONArray;
  BlockTarget: Int64;
  BlockLength: Integer;
  HasGroupedRanges: Boolean;

  procedure CancelCheck;
  begin if Assigned(Cancelled) and Cancelled() then Abort; end;

  procedure FinishBlock;
  begin
    if BlockLength=0 then Exit;
    var Chunk:=TJSONArray.Create;
    try
      if Ranges.Count=1 then
        Chunk.AddElement(TJSONNumber.Create(Number((Ranges.Items[0] as TJSONArray).Items[0])))
      else
      begin
        Chunk.AddElement(Ranges);
        Ranges:=nil;
        HasGroupedRanges:=True;
      end;
      Chunk.AddElement(TJSONNumber.Create(BlockTarget));
      Chunk.AddElement(TJSONNumber.Create(BlockLength));
      Chunk.Add(Digest(ReadChunkSource(Chunk.Items[0],BlockLength)));
      Chunks.AddElement(Chunk);
      Chunk:=nil;
      Inc(Done,BlockLength);
      BlockLength:=0;
      FreeAndNil(Ranges);
      if Assigned(Progress) then Progress('Проверка архива',Done,Total-UntouchedEnd);
    finally Chunk.Free; end;
  end;

  procedure AddRange(Source, Target, Length: Int64);
  begin
    if Source=Target then
    begin
      if Source<>UntouchedEnd then raise EReadError.Create('Неверная последовательность диапазонов ZIP.');
      Inc(UntouchedEnd,Length); Exit;
    end;
    while Length > 0 do
    begin
      CancelCheck;
      if BlockLength=0 then
      begin
        BlockTarget:=Target;
        Ranges:=TJSONArray.Create;
      end;
      var Count:=Integer(Min(Int64(BlockBytes-BlockLength),Length));
      var Part:=TJSONArray.Create;
      Ranges.AddElement(Part);
      Part.AddElement(TJSONNumber.Create(Source));
      Part.AddElement(TJSONNumber.Create(Count));
      Inc(BlockLength,Count);
      Inc(Source,Count); Inc(Target,Count); Dec(Length,Count);
      if (BlockLength=BlockBytes) or (Ranges.Count=MaxChunkRanges) then FinishBlock;
    end;
  end;
begin
  inherited Create;
  if Length(Names)=0 then raise EArgumentException.Create('Не выбраны файлы внутри ZIP.');
  FArchive := ExpandFileName(Archive);
  FSource := TFileStream.Create(DeletionNativePath(FArchive),fmOpenReadWrite or fmShareExclusive);
  if (ExpectedSourceIdentity<>'') and (ExpectedSourceIdentity<>SourceIdentity(FSource.Handle)) then
    raise EReadError.Create('Архив изменился после выбора книг. Повторите выбор; файлы не удалены.');
  if FSource.Size>=6 then
  begin
    var Signature:=ReadAt(0,6);
    if (Signature[0]=$37) and (Signature[1]=$7A) and (Signature[2]=$BC) and
      (Signature[3]=$AF) and (Signature[4]=$27) and (Signature[5]=$1C) then
    begin PrepareSevenZip(Names,Cancelled,AllowSevenZipRepack,JournalParent,Progress); Exit; end;
  end;
  Zip := TZipFile.Create; Virtual := TZipDirectoryPlanStream.Create(FSource);
  Indices := TDictionary<string,Integer>.Create;
  Ranges:=nil; BlockLength:=0; HasGroupedRanges:=False;
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
    Comment:=CapturedZipComment(Virtual,Headers);

    SetLength(Order,Length(Headers)); SetLength(OriginalEndByIndex,Length(Headers));
    SetLength(OriginalOffsets,Length(Headers)); SetLength(FinalOffsets,Length(Headers));
    for var I := 0 to High(Order) do
    begin
      CancelCheck;
      var Position:=Headers[I].LocalHeaderOffset64;
      if (Position>UInt64(High(Int64))) or (Headers[I].DiskNumberStart<>0) then
        raise EReadError.Create('Неподдерживаемое размещение ZIP.');
      OriginalOffsets[I]:=Int64(Position); Order[I]:=I;
    end;
    TArray.Sort<Integer>(Order,TComparer<Integer>.Construct(
      function(const Left,Right: Integer): Integer
      begin
        if OriginalOffsets[Left] < OriginalOffsets[Right] then Result := -1
        else if OriginalOffsets[Left] > OriginalOffsets[Right] then Result := 1
        else Result := 0;
      end));
    CurrentEnd := OriginalEnd;
    for var I := High(Order) downto 0 do
    begin
      CancelCheck;
      Index := Order[I];
      Offset := OriginalOffsets[Index];
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
    for Index in Order do if not Remove[Index] then
    begin
      FinalOffsets[Index]:=Total;
      Inc(Total,OriginalEndByIndex[Index]-OriginalOffsets[Index]);
    end;
    FPlan := TJSONObject.Create;
    FPlan.AddPair('archive',FArchive);
    FPlan.AddPair('fileId',ArchiveKey(FSource.Handle));
    FPlan.AddPair('originalSize',TJSONNumber.Create(FSource.Size));
    FPlan.AddPair('chunks',TJSONArray.Create); Keep := TJSONArray.Create; FPlan.AddPair('remaining',Keep);
    // Payload ranges follow physical offsets. Central headers keep the
    // source's directory order and are serialized once for the whole batch.
    Virtual.Metadata.Size:=0; Virtual.Metadata.Position:=0;
    HeaderSignature:=SIGNATURE_CENTRALHEADER; RetainedCount:=0;
    for var I:=0 to High(Headers) do if not Remove[I] then
    begin
      CancelCheck;
      var Header:=Headers[I];
      SetZipHeaderOffset(Header,UInt64(FinalOffsets[I]));
      Virtual.Metadata.WriteBuffer(HeaderSignature,SizeOf(HeaderSignature));
      Virtual.Metadata.WriteBuffer(Header.MadeByVersion,CENTRALHEADERSIZE);
      if Header.FileNameLength>0 then Virtual.Metadata.WriteBuffer(Header.FileName[0],Header.FileNameLength);
      if Header.ExtraFieldLength>0 then Virtual.Metadata.WriteBuffer(Header.ExtraField[0],Header.ExtraFieldLength);
      if Header.FileCommentLength>0 then Virtual.Metadata.WriteBuffer(Header.FileComment[0],Header.FileCommentLength);
      Keep.Add(OriginalNames[I]); Inc(RetainedCount);
    end;
    WriteZipDirectoryEnd(Virtual.Metadata,RetainedCount,Total,Comment);
    if Virtual.Metadata.Size>MaxMetadataBytes then raise EWriteError.Create('Слишком большой каталог ZIP.');
    SetLength(Metadata,Integer(Virtual.Metadata.Size)); Virtual.Metadata.Position:=0;
    Virtual.Metadata.ReadBuffer(Metadata[0],Length(Metadata));
    FPlan.AddPair('finalSize',TJSONNumber.Create(Total+Length(Metadata)));
    FPlan.AddPair('metadataOffset',TJSONNumber.Create(Total));
    FPlan.AddPair('metadata',TNetEncoding.Base64.EncodeBytesToString(Metadata));
    Done := 0; UntouchedEnd := 0; Destination := CurrentEnd; RangeSource := 0; RangeTarget := 0; RangeLength := CurrentEnd;
    for Index in Order do if not Remove[Index] then
    begin
      Offset := OriginalOffsets[Index]; Remaining := OriginalEndByIndex[Index]-Offset;
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
    FinishBlock;
    FPlan.AddPair('schema',TJSONNumber.Create(IfThen(HasGroupedRanges,ZipGroupedRangesSchema,1)));
    FPlan.AddPair('untouchedEnd',TJSONNumber.Create(UntouchedEnd));
    CheckPlan;
  finally
    Ranges.Free;
    Indices.Free;
    Virtual.Capturing := False;
    Zip.Free; Virtual.Free;
  end;
end;

constructor TZipMemberDeletion.PrepareWholeArchive(const Archive, ExpectedSourceIdentity: string);
var Size: Int64;
begin
  inherited Create;
  if Length(ExpectedSourceIdentity)<>59 then
    raise EArgumentException.Create('Не определён исходный файл для удаления целого архива.');
  FArchive:=ExpandFileName(Archive);
  FWholeIdentity:=ExpectedSourceIdentity;
  OpenWholeSource(False);
  if not GetFileSizeEx(FWholeHandle,Size) then RaiseLastOSError;
  // The archive is itself the book. The receipt holds only its identity.
  // The existing whole-source path unlinks it after the catalogue commits.
  FPlan:=TJSONObject.Create;
  FPlan.AddPair('schema',TJSONNumber.Create(1));
  FPlan.AddPair('archive',FArchive);
  FPlan.AddPair('fileId',Copy(FWholeIdentity,1,25));
  FPlan.AddPair('wholeIdentity',FWholeIdentity);
  FPlan.AddPair('originalSize',TJSONNumber.Create(Size));
  FPlan.AddPair('finalSize',TJSONNumber.Create(0));
  FPlan.AddPair('metadataOffset',TJSONNumber.Create(0));
  FPlan.AddPair('untouchedEnd',TJSONNumber.Create(0));
  FPlan.AddPair('metadata','');
  FPlan.AddPair('chunks',TJSONArray.Create);
  FPlan.AddPair('remaining',TJSONArray.Create);
  CheckPlan;
end;

constructor TZipMemberDeletion.Recover(const Archive, Job: string);
var State: TJSONObject; Bytes: TBytes;
begin
  inherited Create;
  FArchive := ExpandFileName(Archive); FJob := ExpandFileName(Job);
  FPlan := LoadObject(TPath.Combine(FJob,PlanName));
  Bytes := TEncoding.UTF8.GetBytes(FPlan.ToJSON); FPlanHash := Digest(Bytes);
  if Assigned(FPlan.GetValue('wholeIdentity')) then
  begin
    FWholeIdentity:=TextField(FPlan,'wholeIdentity');
    if FWholeIdentity='' then raise EReadError.Create('Отсутствует идентификатор целого архива.');
    CheckPlan;
    if not CanRemoveWhole then raise EReadError.Create('Журнал удаления целого архива содержит сохраняемые файлы.');
    OpenWholeSource(True);
    FFinished:=True;
    Exit;
  end;
  FSource := TFileStream.Create(DeletionNativePath(FArchive),fmOpenReadWrite or fmShareExclusive);
  if not (FPlan.GetValue('chunks') is TJSONArray) then
    raise EReadError.Create('Повреждён список блоков журнала удаления.');
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
  var Schema:=FieldNumber(FPlan,'schema');
  if not FFinished and ((Schema=4) or
    ((Schema=SevenZipGroupedRangesSchema) and (FieldNumber(FPlan,'replacementBytes')>0))) then
    OpenReplacement(FJob);
  CheckPlan;
  if (FSource.Size<>FieldNumber(FPlan,'originalSize')) and
    ((FNext<>Chunks.Count) or (FSource.Size<>FieldNumber(FPlan,'finalSize'))) then
    raise EReadError.Create('Размер архива изменился вне операции удаления.');
end;

procedure TZipMemberDeletion.DiscardStaging;
begin
  FreeAndNil(FReplacement);
  if FStagingDirectory<>'' then
  begin
    RemoveStagingDirectory(FStagingDirectory);
    FStagingDirectory:='';
  end;
  if FStagingGuard<>0 then
  begin
    CloseHandle(FStagingGuard);
    FStagingGuard:=0;
  end;
end;

destructor TZipMemberDeletion.Destroy;
begin
  DiscardStaging;
  if FWholeHandle<>0 then CloseHandle(FWholeHandle);
  FPlan.Free; FSource.Free;
  inherited;
end;

procedure TZipMemberDeletion.SaveCheckpoint(const Directory:string);
var State: TJSONObject;
begin
  State := TJSONObject.Create;
  try
    State.AddPair('planHash',FPlanHash); State.AddPair('next',TJSONNumber.Create(FNext));
    State.AddPair('pending',TJSONBool.Create(FPending)); State.AddPair('finished',TJSONBool.Create(FFinished));
    if Directory='' then SaveObject(State,TPath.Combine(FJob,CheckpointName))
    else WriteStagedBytes(TEncoding.UTF8.GetBytes(State.ToJSON),TPath.Combine(Directory,CheckpointName));
  finally State.Free; end;
end;

function TZipMemberDeletion.BytesToProcess: Int64;
begin Result := FieldNumber(FPlan,'metadataOffset')-FieldNumber(FPlan,'untouchedEnd'); end;

function TZipMemberDeletion.JournalBytes: Int64;
var Pending: Int64;
begin
  Pending := 0;
  for var I := 0 to Chunks.Count-1 do Pending := Max(Pending,ChunkNumber(I,2));
  Result := FReplacementSize+Length(TEncoding.UTF8.GetBytes(FPlan.ToJSON))+2*Pending+65536;
end;

procedure TZipMemberDeletion.VerifyFinished;
var Zip: TZipFile; Names: TJSONArray; Actual: TBytes; FileNames: TArray<string>;
begin
  if FSource.Size<>FieldNumber(FPlan,'finalSize') then raise EReadError.Create('Неверный итоговый размер ZIP.');
  FSource.Position := FieldNumber(FPlan,'metadataOffset');
  SetLength(Actual,Length(FMetadata));
  if Length(Actual)>0 then FSource.ReadBuffer(Actual[0],Length(Actual));
  if Digest(Actual) <> Digest(FMetadata) then raise EReadError.Create('Каталог ZIP не прошёл проверку записи.');
  if Length(FHeader)>0 then
  begin
    Actual:=ReadAt(0,Length(FHeader));
    if Digest(Actual)<>Digest(FHeader) then raise EReadError.Create('Заголовок 7z не прошёл проверку записи.');
    Names:=FPlan.GetValue('remaining') as TJSONArray;
    SetLength(FileNames,Names.Count);
    for var I:=0 to Names.Count-1 do FileNames[I]:=Names.Items[I].Value;
    VerifySevenZipInventory(FSource,FileNames); Exit;
  end;
  Zip := TZipFile.Create;
  try
    Zip.Open(FSource,zmRead); Names := FPlan.GetValue('remaining') as TJSONArray;
    if Zip.FileCount<>Names.Count then raise EReadError.Create('Изменился список сохранённых файлов ZIP.');
    FileNames := Zip.FileNames;
    for var I := 0 to Names.Count-1 do
      if FileNames[I]<>Names.Items[I].Value then raise EReadError.Create('Подменён файл в каталоге ZIP.');
  finally Zip.Free; end;
end;

function TZipMemberDeletion.JournalSpaceAvailable(const Directory: string): UInt64;
var Capacity: UInt64;
begin
  if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Directory)),Result,Capacity,nil) then RaiseLastOSError;
end;

procedure TZipMemberDeletion.Execute(const JournalParent: string; const Progress: TZipDeleteProgress;
  const Fault: TZipDeleteFault);
var Bytes, Actual: TBytes; Target, Done: Int64; Count: Integer; Pending: TFileStream;
  procedure Signal(const Stage: string);
  begin if Assigned(Fault) then Fault(Stage,FNext); end;
  procedure Flush;
  begin if not FlushFileBuffers(FSource.Handle) then RaiseLastOSError; end;
begin
  CheckPlan;
  if (FJob<>'') and not FFinished and Assigned(FReplacement) then
    for var I:=FNext to Chunks.Count-1 do
      if ((Chunks.Items[I] as TJSONArray).Count=5) and
        (Digest(ChunkReplacement(I))<>ChunkHash(I)) then
        raise EReadError.Create('Пересжатый блок 7z не совпадает с журналом.');
  if FJob='' then
  begin
    ForceDirectories(DeletionNativePath(JournalParent));
    if JournalSpaceAvailable(JournalParent)<UInt64(JournalBytes-FReplacementSize) then
      raise EWriteError.Create('Недостаточно места для журнала удаления. Архив не изменён.');
    Bytes := TEncoding.UTF8.GetBytes(FPlan.ToJSON);
    if Length(Bytes)>MaxPlanBytes then raise EWriteError.Create('Слишком большой журнал ZIP.');
    FPlanHash := Digest(Bytes);
    var Job:=TPath.Combine(ExpandFileName(JournalParent),'zip-delete-'+TGUID.NewGuid.ToString);
    if FStagingDirectory<>'' then
    begin
      if not SameFileName(ExtractFileDir(FStagingDirectory),ExpandFileName(JournalParent)) then
        raise EWriteError.Create('Папка журнала 7z изменилась после подготовки.');
      if not FlushFileBuffers(FReplacement.Handle) then RaiseLastOSError;
      WriteStagedBytes(Bytes,TPath.Combine(FStagingDirectory,PlanName));
      SaveCheckpoint(FStagingDirectory);
      FreeAndNil(FReplacement);
      // Recovery only sees the directory after all staged data is durable.
      if not MoveFileEx(PChar(DeletionNativePath(FStagingDirectory)),PChar(DeletionNativePath(Job)),
        MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
      FJob:=Job;
      FStagingDirectory:='';
      DiscardStaging;
      OpenReplacement(FJob);
    end
    else
    begin
      if not CreateDirectory(PChar(DeletionNativePath(Job)),nil) then RaiseLastOSError;
      FJob:=Job;
      SaveBytes(Bytes,TPath.Combine(FJob,PlanName));
      if FWholeIdentity='' then SaveCheckpoint;
    end;
  end;
  if FWholeIdentity<>'' then
  begin
    // The complete, immutable plan is the receipt. The source remains intact
    // under its exclusive handle until the catalogue has committed.
    FFinished:=True;
    Exit;
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
    var Source:=(Chunks.Items[FNext] as TJSONArray).Items[0];
    if FPending then
    begin
      Pending := TFileStream.Create(DeletionNativePath(TPath.Combine(FJob,PendingName)),fmOpenRead or fmShareDenyWrite);
      try
        if Pending.Size<>Count then raise EReadError.Create('Неверный размер ожидающего блока ZIP.');
        SetLength(Bytes,Count); Pending.ReadBuffer(Bytes[0],Count);
      finally Pending.Free; end;
    end
    else if (Source is TJSONNumber) and (Number(Source)=-1) then Bytes:=ChunkReplacement(FNext)
    else Bytes:=ReadChunkSource(Source,Count);
    if (Length(Bytes)<>Count) or (Digest(Bytes)<>ChunkHash(FNext)) then
      raise EReadError.Create('Исходный блок ZIP не совпадает с планом. Удаление не продолжено.');
    if (Source is TJSONArray) or (Number(Source)<>Target) then
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
    if Assigned(Progress) then Progress(ArchiveDeletionWriteStage,Done,BytesToProcess);
  end;
  if Assigned(Fault) and (Length(FMetadata)>0) then
  begin
    FSource.Position := FieldNumber(FPlan,'metadataOffset');
    FSource.WriteBuffer(FMetadata[0],Length(FMetadata) div 2); Flush; Signal('half-metadata');
  end;
  Target := FieldNumber(FPlan,'metadataOffset'); FSource.Position := Target;
  if Length(FMetadata)>0 then FSource.WriteBuffer(FMetadata[0],Length(FMetadata));
  // An empty ZIP without a prefix has no remaining payload to protect. Its
  // journal can replay the entire footer at either the old or final size, so
  // persist the footer and truncation together before recording completion.
  if (Length(FHeader)>0) or (Target<>0) or
    ((FPlan.GetValue('remaining') as TJSONArray).Count<>0) then Flush;
  Signal('metadata');
  if Length(FHeader)>0 then
  begin
    if Assigned(Fault) then
    begin FSource.Position:=0; FSource.WriteBuffer(FHeader[0],Length(FHeader) div 2); Flush; Signal('half-prefix'); end;
    FSource.Position:=0; FSource.WriteBuffer(FHeader[0],Length(FHeader)); Flush; Signal('prefix');
  end;
  FSource.Size := FieldNumber(FPlan,'finalSize'); Flush; Signal('truncated');
  VerifyFinished; FFinished := True; SaveCheckpoint; Signal('finished');
end;

procedure TZipMemberDeletion.RequirePrivateSource;
begin
  if not IsPrivateArchiveDeletionSource(FArchive) then
    raise EReadError.Create('У архива изображений есть другая ссылка или он недоступен: '+FArchive);
end;

procedure TZipMemberDeletion.Acknowledge(const BeforeForget:TProc);
var Path: string; Disposition: Byte;
begin
  if not FFinished or (FJob='') then raise EInvalidOperation.Create('Удаление ZIP ещё не завершено.');
  CheckIdentity;
  if Digest(TFile.ReadAllBytes(DeletionNativePath(TPath.Combine(FJob,PlanName))))<>FPlanHash then
    raise EReadError.Create('Журнал ZIP изменён и сохранён для проверки.');
  if FWholeIdentity='' then VerifyFinished
  else if FWholeHandle<>0 then
  begin
    var Info:TByHandleFileInformation;
    if not GetFileInformationByHandle(FWholeHandle,Info) then RaiseLastOSError;
    if Info.nNumberOfLinks<>1 then raise EReadError.Create('Появилась другая ссылка на архив. Архив сохранён.');
    Disposition:=1;
    if not SetArchiveFileInformation(FWholeHandle,FileDispositionInfoClass,@Disposition,SizeOf(Disposition)) then
      RaiseLastOSError;
    CloseHandle(FWholeHandle); FWholeHandle:=0;
  end
  else if (GetFileAttributes(PChar(DeletionNativePath(FArchive)))<>INVALID_FILE_ATTRIBUTES) or
    (GetLastError<>ERROR_FILE_NOT_FOUND) then
    raise EReadError.Create('Путь архива изменился после удаления. Журнал сохранён.');
  if Assigned(BeforeForget) then BeforeForget();
  FreeAndNil(FReplacement);
  for var Name in [PendingName,ReplacementName,CheckpointName,PlanName] do
  begin
    Path := DeletionNativePath(TPath.Combine(FJob,Name));
    if FileExists(Path) and not System.SysUtils.DeleteFile(Path) then RaiseLastOSError;
  end;
  if not RemoveDirectory(PChar(DeletionNativePath(FJob))) then RaiseLastOSError;
  FJob := '';
end;

procedure TZipMemberDeletion.RemoveEmptyArchive;
var Handle: THandle; Info: TByHandleFileInformation; Key: string;
  Expected, Actual: TBytes; ReadCount: DWORD; Disposition: Byte;
begin
  if FWholeIdentity<>'' then Exit;
  if not FFinished or (FJob <> '') or not Assigned(FSource) then
    raise EInvalidOperation.Create('Сначала завершите обновление каталога и журнала удаления.');
  // No entries, including companion files and directories, may remain.
  // An executable or other prefix outside the ZIP entries also stays intact.
  if ((FPlan.GetValue('remaining') as TJSONArray).Count <> 0) or
    (FieldNumber(FPlan,'metadataOffset') <> Length(FHeader)) then Exit;

  CheckIdentity;
  VerifyFinished;
  if not GetFileInformationByHandle(FSource.Handle,Info) then RaiseLastOSError;
  if Info.nNumberOfLinks <> 1 then Exit;
  Key := ArchiveKey(FSource.Handle);
  Expected := ReadAt(0,Length(FHeader)+Length(FMetadata));

  // The writer handle has no DELETE access. Reopen exclusively and verify
  // both the physical file and the complete empty container before unlinking.
  FreeAndNil(FSource);
  Handle := CreateFile(PChar(DeletionNativePath(FArchive)),GENERIC_READ or DeleteAccess,
    0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.nNumberOfLinks <> 1) or
      ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)) <> 0) or
      (ArchiveKey(Handle) <> Key) or (Info.nFileSizeHigh <> 0) or
      (Info.nFileSizeLow <> DWORD(Length(Expected))) then
      raise EReadError.Create('Путь или файл архива изменился после удаления книг.');

    SetLength(Actual,Length(Expected));
    if not ReadFile(Handle,Actual[0],DWORD(Length(Actual)),ReadCount,nil) then RaiseLastOSError;
    if (ReadCount <> DWORD(Length(Actual))) or
      not CompareMem(@Actual[0],@Expected[0],Length(Expected)) then
      raise EReadError.Create('Содержимое архива изменилось после удаления книг.');

    Disposition := 1;
    if not SetArchiveFileInformation(Handle,FileDispositionInfoClass,@Disposition,SizeOf(Disposition)) then
      RaiseLastOSError;
  finally
    CloseHandle(Handle);
  end;
end;

end.
