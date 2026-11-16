unit unit_CollectionTransferCopy;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Winapi.Windows, unit_CollectionTransferPlan;

type
  TTransferCopyProgress = reference to procedure(const Stage: string; Done, Total: Int64);
  TTransferDestinationProof = record
    Identity,SHA256,StreamsJSON:string;
  end;

  // Retain through catalogue publication. Native readers can open the output,
  // but ordinary writers/replacement cannot change its verified streams.
  TTransferPreparedCopy = class
  private
    FSourceLease, FOutputLease: TObject;
    FOutputGuard: THandle;
    FDirectoryGuards: TArray<THandle>;
    FSource, FDestination, FIdentity, FSHA256, FStreamsJSON: string;
    procedure CheckSnapshot(const Path,Expected:string; Lease:TObject; const Cancelled:TFunc<Boolean>);
    function HasSourceLease:Boolean;
  public
    destructor Destroy; override;
    procedure CheckUnchanged(const ExpectedSourceIdentity:string; const Cancelled:TFunc<Boolean> = nil);
    procedure CheckDestinationUnchanged(const Cancelled:TFunc<Boolean> = nil);
    property SourceHeld:Boolean read HasSourceLease;
    property Source: string read FSource;
    property Destination: string read FDestination;
    property Identity: string read FIdentity;
    property SHA256: string read FSHA256;
    property StreamsJSON: string read FStreamsJSON;
  end;

  // One active file journal. The collection's disk-backed ledger will retain
  // this reference until the entire dependency group is published. This class
  // never changes a catalogue or deletes an original source.
  TCollectionTransferCopy = class
  private
    FEntry: TCollectionTransferFile;
    FWorkRoot, FAllowedRoot, FDirectory, FBinding: string;
    FState: TJSONObject;
    FSequence: Integer;
    FLease: THandle;
    FDirectories: TList<THandle>;
    FCancelled: TFunc<Boolean>;
    FProgress: TTransferCopyProgress;
    FCallbackError: string;
    FCallbackAborted: Boolean;
    FCallbackGuard: THandle;
    function PinDirectory(const Path: string; CreateMissing: Boolean): THandle;
    procedure PinDestination(CreateMissing:Boolean=True);
    procedure CheckStop;
    procedure Space(Remaining: Int64);
    procedure Notify(const Stage: string; Done, Total: Int64);
    procedure SaveState;
    procedure LoadState;
    function Text(const Name: string): string;
    procedure Put(const Name, Value: string);
    function Temporary: string;
    procedure ValidateEntry;
    constructor OpenExisting(const WorkRoot, AllowedRoot, Directory: string;
      const Entry: TCollectionTransferFile);
    function CopyProgress(Done, Total: Int64; Reason: DWORD): DWORD;
  public
    constructor CreateNew(const WorkRoot, AllowedRoot: string; const Entry: TCollectionTransferFile);
    destructor Destroy; override;
    class function Resume(const WorkRoot, AllowedRoot, Directory: string;
      const Entry: TCollectionTransferFile): TCollectionTransferCopy; static;
    function Prepare(const Cancelled: TFunc<Boolean> = nil;
      const Progress: TTransferCopyProgress = nil): TTransferPreparedCopy;
    // Proof must come from the parent's bound durable record, independently of
    // this child's mutable state. Does not inspect/remove/recreate the source,
    // publish locators, or acknowledge completion/removal of any original.
    function VerifyDestination(const Expected:TTransferDestinationProof;
      const Cancelled:TFunc<Boolean> = nil; const Progress:TTransferCopyProgress = nil):TTransferPreparedCopy;
    property Directory: string read FDirectory;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferCopyTestPoint: TProc<string,string>;
{$ENDIF}

implementation

uses System.IOUtils, System.Hash, System.StrUtils, System.Math, System.Generics.Defaults,
  unit_ZipMemberDeletion;

const CopyKind='HomeLibre physical transfer copy v1';
  JobPrefix='transfer-copy-'; MaxJSONBytes=16*1024*1024;

type
  TTransferReadStream = class(THandleStream)
    constructor Create(const Path:string; Share:DWORD);
    destructor Destroy; override;
  end;
  TStreamData = record
    Size: Int64;
    Name: array[0..295] of WideChar;
  end;
  TStreamItem = record
    Name: string;
    Size: Int64;
    Stream: TTransferReadStream;
    SHA256: string;
  end;
  TTransferStreamSnapshot = class
    Items: TArray<TStreamItem>;
    Identity, Description, MainSHA: string;
    Total: Int64;
    RenameAllowed:Boolean;
    constructor Create(const Path, ExpectedIdentity, ExpectedKey: string;
      Owner: TCollectionTransferCopy; const Stage: string; AllowRename:Boolean=False);
    destructor Destroy; override;
    procedure PinPublishedStreams(const Path:string; Owner:TCollectionTransferCopy);
  end;
  TTransferRenameInfo = record
    ReplaceIfExists: Byte;
    RootDirectory: THandle;
    FileNameLength: DWORD;
    FileName: array[0..0] of WideChar;
  end;

function TransferFindFirstStream(Name:PWideChar; Level:DWORD; Data:Pointer; Flags:DWORD):THandle;
  stdcall; external kernel32 name 'FindFirstStreamW';
function TransferFindNextStream(Handle:THandle; Data:Pointer):BOOL;
  stdcall; external kernel32 name 'FindNextStreamW';
function TransferSetFileInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'SetFileInformationByHandle';

procedure Point(const Name, Directory: string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferCopyTestPoint) then TransferCopyTestPoint(Name,Directory);
{$ENDIF}
end;

constructor TTransferReadStream.Create(const Path:string; Share:DWORD);
var Handle:THandle;
begin
  Handle:=CreateFile(PChar(Path),GENERIC_READ,Share,nil,OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT or FILE_FLAG_SEQUENTIAL_SCAN,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  inherited Create(Handle);
end;

destructor TTransferReadStream.Destroy;
begin if (Handle<>0) and (Handle<>INVALID_HANDLE_VALUE) then CloseHandle(Handle); inherited; end;

function FileKey(Handle:THandle):string;
var Info:TByHandleFileInformation;
begin
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or
    (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
    ((Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0)) then
    raise EReadError.Create('Файл переноса заменён ссылкой или не имеет однозначного номера.');
  Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
end;

function Present(const Path:string):Boolean;
begin
  if GetFileAttributes(PChar(DeletionNativePath(Path)))<>INVALID_FILE_ATTRIBUTES then Exit(True);
  var Code:=GetLastError;
  if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
  Result:=False;
end;

function ReadJSON(const Path:string):TJSONObject;
var FileIn:TFileStream; Raw:TBytes; Value:TJSONValue;
begin
  FileIn:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  try
    FileKey(FileIn.Handle);
    if (FileIn.Size<=0) or (FileIn.Size>MaxJSONBytes) then raise EReadError.Create('Неверный размер журнала переноса.');
    SetLength(Raw,Integer(FileIn.Size)); FileIn.ReadBuffer(Raw[0],Length(Raw));
  finally FileIn.Free; end;
  Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Raw));
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждён журнал переноса.'); end;
  Result:=TJSONObject(Value);
end;

procedure WriteNewJSON(const Path:string; Data:TJSONObject);
var Handle:THandle; Raw:TBytes; Stream:THandleStream;
begin
  Raw:=TEncoding.UTF8.GetBytes(Data.ToJSON);
  Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Stream:=THandleStream.Create(Handle);
    try if Length(Raw)>0 then Stream.WriteBuffer(Raw[0],Length(Raw)); finally Stream.Free; end;
    if not FlushFileBuffers(Handle) then RaiseLastOSError;
  finally CloseHandle(Handle); end;
end;

function Binding(const Root:string; const Entry:TCollectionTransferFile):string;
var Data:TJSONObject;
begin
  Data:=TJSONObject.Create;
  try
    Data.AddPair('kind',CopyKind); Data.AddPair('root',Root);
    Data.AddPair('source',Entry.Source); Data.AddPair('destination',Entry.Destination);
    Data.AddPair('identity',Entry.Identity); Data.AddPair('bytes',TJSONNumber.Create(Entry.Bytes));
    Data.AddPair('keep',TJSONBool.Create(Entry.KeepInPlace));
    Result:=THashSHA2.GetHashString(Data.ToJSON);
  finally Data.Free; end;
end;

function StreamPath(const Path, Name:string):string;
begin
  if Name='::$DATA' then Exit(DeletionNativePath(Path));
  if not Name.StartsWith(':') or not Name.EndsWith(':$DATA') or
    Name.Contains('\') or Name.Contains('/') then raise EReadError.Create('Некорректное имя потока файла.');
  Result:=DeletionNativePath(Path)+Name;
end;

function StreamNames(const Path:string):TArray<TStreamItem>;
var Handle:THandle; Data:TStreamData; Count:Integer;
begin
  Result:=nil; Count:=0;
  Handle:=TransferFindFirstStream(PChar(DeletionNativePath(Path)),0,@Data,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    var Code:=GetLastError;
    if not (Code in [ERROR_HANDLE_EOF,ERROR_INVALID_FUNCTION,ERROR_NOT_SUPPORTED]) then RaiseLastOSError(Code);
    SetLength(Result,1); Result[0].Name:='::$DATA'; Result[0].Size:=TFile.GetSize(DeletionNativePath(Path)); Exit;
  end;
  try
    repeat
      if (Count>=4096) or (Data.Size<0) then raise EReadError.Create('Слишком много потоков или неверный размер файла.');
      SetLength(Result,Count+1); Result[Count].Name:=PChar(@Data.Name[0]); Result[Count].Size:=Data.Size; Inc(Count);
      if not TransferFindNextStream(Handle,@Data) then
      begin if GetLastError<>ERROR_HANDLE_EOF then RaiseLastOSError; Break; end;
    until False;
  finally Winapi.Windows.FindClose(Handle); end;
  TArray.Sort<TStreamItem>(Result,TComparer<TStreamItem>.Construct(
    function(const A,B:TStreamItem):Integer
    begin Result:=CompareStr(A.Name,B.Name); end));
end;

constructor TTransferStreamSnapshot.Create(const Path, ExpectedIdentity, ExpectedKey:string;
  Owner:TCollectionTransferCopy; const Stage:string; AllowRename:Boolean);
var Canonical,Stamp:string; Bytes,Done:Int64; Buffer:TBytes; Count:Integer; Hash:THashSHA2; Data:TJSONArray;
begin
  inherited Create; RenameAllowed:=AllowRename;
  TransferReadFileState(Path,Canonical,Stamp,Bytes);
  if not SameFileName(Canonical,Path) or
    ((ExpectedIdentity<>'') and (Stamp<>ExpectedIdentity)) or
    ((ExpectedKey<>'') and (Copy(Stamp,1,25)<>ExpectedKey)) then
    raise EReadError.Create('Файл изменился или заменён после проверки: '+Path);
  Items:=StreamNames(Path); Total:=0;
  for var I:=0 to High(Items) do
  begin
    Owner.CheckStop;
    var Share:=DWORD(FILE_SHARE_READ); if AllowRename then Share:=Share or FILE_SHARE_DELETE;
    Items[I].Stream:=TTransferReadStream.Create(StreamPath(Path,Items[I].Name),Share);
    if (FileKey(Items[I].Stream.Handle)<>Copy(Stamp,1,25)) or (Items[I].Stream.Size<>Items[I].Size) then
      raise EReadError.Create('Поток файла изменился: '+Path);
    if Total>High(Int64)-Items[I].Size then raise EReadError.Create('Размер потоков файла слишком велик.');
    Inc(Total,Items[I].Size);
  end;
  TransferReadFileState(Path,Canonical,Identity,Bytes);
  if Identity<>Stamp then raise EReadError.Create('Файл изменился при открытии: '+Path);
  SetLength(Buffer,1024*1024); Done:=0; Data:=TJSONArray.Create;
  try
    for var I:=0 to High(Items) do
    begin
      Hash:=THashSHA2.Create;
      repeat
        Owner.CheckStop; Count:=Items[I].Stream.Read(Buffer[0],Length(Buffer));
        if Count>0 then begin Hash.Update(Buffer,Count); Inc(Done,Count); Owner.Notify(Stage,Done,Total); end;
      until Count=0;
      Items[I].SHA256:=Hash.HashAsString; Items[I].Stream.Position:=0;
      if Items[I].Name='::$DATA' then MainSHA:=Items[I].SHA256;
      var Row:=TJSONObject.Create; Data.AddElement(Row); Row.AddPair('name',Items[I].Name);
      Row.AddPair('bytes',TJSONNumber.Create(Items[I].Size)); Row.AddPair('sha256',Items[I].SHA256);
    end;
    if MainSHA='' then raise EReadError.Create('Не найден основной поток файла.');
    Description:=Data.ToJSON;
  finally Data.Free; end;
  // Adding/removing a named stream cannot be mistaken for a complete copy.
  var Current:=StreamNames(Path);
  if Length(Current)<>Length(Items) then raise EReadError.Create('Набор потоков файла изменился.');
  for var I:=0 to High(Items) do
    if (Current[I].Name<>Items[I].Name) or (Current[I].Size<>Items[I].Size) then
      raise EReadError.Create('Набор потоков файла изменился.');
end;

destructor TTransferStreamSnapshot.Destroy;
begin
  for var Item in Items do Item.Stream.Free;
  inherited;
end;

procedure TTransferStreamSnapshot.PinPublishedStreams(const Path:string; Owner:TCollectionTransferCopy);
var Stream:TTransferReadStream; Hash:THashSHA2; Buffer:TBytes; N:Integer;
begin
  if not RenameAllowed then Exit;
  SetLength(Buffer,1024*1024);
  for var I:=0 to High(Items) do
  begin
    Owner.CheckStop;
    Stream:=TTransferReadStream.Create(StreamPath(Path,Items[I].Name),FILE_SHARE_READ);
    try
      if (FileKey(Stream.Handle)<>Copy(Identity,1,25)) or (Stream.Size<>Items[I].Size) then
        raise EReadError.Create('Поток результата изменился при удержании готового файла.');
      // The default-stream replacement guard pins the published file. Named
      // streams had to share DELETE while the whole temporary was renamed;
      // lock their current names and rehash them before trusting old hashes.
      if Items[I].Name<>'::$DATA' then
      begin
        Hash:=THashSHA2.Create;
        repeat
          Owner.CheckStop; N:=Stream.Read(Buffer[0],Length(Buffer));
          if N>0 then Hash.Update(Buffer,N);
        until N=0;
        if Hash.HashAsString<>Items[I].SHA256 then raise EReadError.Create('Дополнительный поток результата изменился.');
        Stream.Position:=0;
      end;
      Items[I].Stream.Free; Items[I].Stream:=Stream; Stream:=nil;
    finally Stream.Free; end;
  end;
  RenameAllowed:=False;
end;

destructor TTransferPreparedCopy.Destroy;
begin
  if FOutputGuard<>0 then CloseHandle(FOutputGuard);
  FOutputLease.Free; FSourceLease.Free;
  for var Handle in FDirectoryGuards do if Handle<>0 then CloseHandle(Handle);
  inherited;
end;

procedure TTransferPreparedCopy.CheckSnapshot(const Path,Expected:string; Lease:TObject; const Cancelled:TFunc<Boolean>);
  var Canonical,Identity:string; Bytes:Int64;
  begin
    var Snapshot:=TTransferStreamSnapshot(Lease);
    if Assigned(Cancelled) and Cancelled() then raise EAbort.Create('Проверка файлов остановлена. Готовая копия не изменена.');
    if Snapshot=nil then raise EReadError.Create('Нет удерживаемой проверки потоков файла.');
    TransferReadFileState(Path,Canonical,Identity,Bytes);
    if (Canonical<>Path) or (Identity<>Expected) or (Snapshot.Identity<>Expected) or
      (Snapshot.Description<>FStreamsJSON) or (Snapshot.MainSHA<>FSHA256) then
      raise EReadError.Create('Проверенный файл или его привязка изменились.');
    var Current:=StreamNames(Path);
    if Length(Current)<>Length(Snapshot.Items) then raise EReadError.Create('Набор потоков файла изменился.');
    for var I:=0 to High(Current) do
      if (Current[I].Name<>Snapshot.Items[I].Name) or (Current[I].Size<>Snapshot.Items[I].Size) or
        (Snapshot.Items[I].Stream=nil) or (Snapshot.Items[I].Stream.Size<>Current[I].Size) or
        (FileKey(Snapshot.Items[I].Stream.Handle)<>Copy(Expected,1,25)) then
        raise EReadError.Create('Потоки проверенного файла изменились.');
    // Existing streams retain their write-denying leases and replacement
    // guards. Reuse their verified hashes rather than reading terabytes again.
  end;

function TTransferPreparedCopy.HasSourceLease:Boolean;
begin Result:=FSourceLease<>nil; end;

procedure TTransferPreparedCopy.CheckDestinationUnchanged(const Cancelled:TFunc<Boolean>);
begin CheckSnapshot(FDestination,FIdentity,FOutputLease,Cancelled); end;

procedure TTransferPreparedCopy.CheckUnchanged(const ExpectedSourceIdentity:string; const Cancelled:TFunc<Boolean>);
begin
  CheckSnapshot(FSource,ExpectedSourceIdentity,FSourceLease,Cancelled);
  CheckDestinationUnchanged(Cancelled);
end;

function TCollectionTransferCopy.PinDirectory(const Path:string; CreateMissing:Boolean):THandle;
var Info:TByHandleFileInformation; Wanted:string;
begin
  Wanted:=IncludeTrailingPathDelimiter(ExpandFileName(Path));
  if CreateMissing and not Present(Wanted) then
    if not CreateDirectory(PChar(DeletionNativePath(Wanted)),nil) then RaiseLastOSError;
  Result:=CreateFile(PChar(DeletionNativePath(Wanted)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Result,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
      (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
      not SameFileName(TransferCanonicalDirectory(Wanted),Wanted) then
      raise EReadError.Create('Папка переноса заменена ссылкой: '+Path);
    FDirectories.Add(Result);
  except CloseHandle(Result); raise; end;
end;

procedure TCollectionTransferCopy.PinDestination(CreateMissing:Boolean);
var Parent,Current,Relative:string;
begin
  PinDirectory(FAllowedRoot,False);
  Parent:=IncludeTrailingPathDelimiter(ExtractFilePath(FEntry.Destination));
  if not Parent.StartsWith(FAllowedRoot,True) then raise EReadError.Create('Назначение вне общей папки.');
  Relative:=Copy(Parent,Length(FAllowedRoot)+1,MaxInt); Current:=FAllowedRoot;
  for var Part in Relative.Split(['\'],TStringSplitOptions.ExcludeEmpty) do
  begin Current:=TPath.Combine(Current,Part); PinDirectory(Current,CreateMissing); end;
end;

procedure TCollectionTransferCopy.CheckStop;
begin
  if Assigned(FCancelled) and FCancelled() then raise EAbort.Create('Операция остановлена. Файлы не удалялись.');
  var SystemRoot:=TPath.GetPathRoot(ExpandFileName(GetEnvironmentVariable('SystemRoot')));
  var Available,Capacity:UInt64;
  if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then raise EWriteError.Create('Сохраните 8 ГБ свободного места на системном диске.');
end;

procedure TCollectionTransferCopy.Space(Remaining:Int64);
var Available,Capacity:UInt64;
begin
  CheckStop;
  if (Remaining<0) or not GetDiskFreeSpaceEx(PChar(DeletionNativePath(ExtractFilePath(FEntry.Destination))),Available,Capacity,nil) then RaiseLastOSError;
  if (Available<UInt64(Remaining)) or (Available-UInt64(Remaining)<UInt64(512)*1024*1024) then
    raise EWriteError.Create('Недостаточно места для проверенной копии и резерва 512 МБ.');
end;

procedure TCollectionTransferCopy.Notify(const Stage:string; Done,Total:Int64);
begin if Assigned(FProgress) then FProgress(Stage,Done,Total); end;

procedure TCollectionTransferCopy.ValidateEntry;
begin
  if (FEntry.Bytes<0) or (Length(FEntry.Identity)<>59) or
    not TPath.IsPathRooted(FEntry.Source) or not TPath.IsPathRooted(FEntry.Destination) or
    (ExpandFileName(FEntry.Source)<>FEntry.Source) or (ExpandFileName(FEntry.Destination)<>FEntry.Destination) or
    not FEntry.Destination.StartsWith(FAllowedRoot,True) or
    (FEntry.KeepInPlace<>SameFileName(FEntry.Source,FEntry.Destination)) then
    raise EReadError.Create('Некорректная привязка файла переноса.');
end;

function TCollectionTransferCopy.Text(const Name:string):string;
begin Result:=FState.GetValue<string>(Name,''); end;

procedure TCollectionTransferCopy.Put(const Name,Value:string);
begin FState.RemovePair(Name).Free; FState.AddPair(Name,Value); end;

function TCollectionTransferCopy.Temporary:string;
var Name:string; ID:TGUID;
begin
  Name:=Text('temporary');
  if not Name.StartsWith('.homelib-transfer-') or not Name.EndsWith('.tmp') then
    raise EReadError.Create('Некорректное имя временной копии.');
  var Token:=Copy(Name,Length('.homelib-transfer-')+1,Length(Name)-Length('.homelib-transfer-')-4);
  ID:=StringToGUID(Token);
  if Name<>'.homelib-transfer-'+GUIDToString(ID)+'.tmp' then raise EReadError.Create('Некорректное имя временной копии.');
  Result:=TPath.Combine(ExtractFilePath(FEntry.Destination),Name);
end;

procedure TCollectionTransferCopy.SaveState;
var Wrapped:TJSONObject; TemporaryState,FinalState,Payload:string;
begin
  CheckStop;
  Inc(FSequence); Payload:=FState.ToJSON; Wrapped:=TJSONObject.Create;
  try
    Wrapped.AddPair('binding',FBinding); Wrapped.AddPair('sequence',TJSONNumber.Create(FSequence));
    Wrapped.AddPair('payload',Payload); Wrapped.AddPair('sha256',THashSHA2.GetHashString(Payload));
    TemporaryState:=TPath.Combine(FDirectory,'.state-'+GUIDToString(TGUID.NewGuid)+'.tmp');
    FinalState:=TPath.Combine(FDirectory,Format('state-%.8d.json',[FSequence]));
    WriteNewJSON(TemporaryState,Wrapped);
    if not MoveFileEx(PChar(DeletionNativePath(TemporaryState)),PChar(DeletionNativePath(FinalState)),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  finally Wrapped.Free; end;
end;

procedure TCollectionTransferCopy.LoadState;
var Search:TSearchRec; Latest,Number:Integer; Name:string; Wrapped:TJSONObject; Value:TJSONValue;
begin
  Latest:=0;
  if FindFirst(DeletionNativePath(TPath.Combine(FDirectory,'state-*.json')),faAnyFile,Search)=0 then
  try
    repeat
      Name:=Search.Name;
      if (Length(Name)=19) and TryStrToInt(Copy(Name,7,8),Number) and
        (Name=Format('state-%.8d.json',[Number])) then Latest:=Max(Latest,Number);
    until FindNext(Search)<>0;
  finally System.SysUtils.FindClose(Search); end;
  if Latest=0 then raise EReadError.Create('Не найдено завершённое состояние копирования.');
  Wrapped:=ReadJSON(TPath.Combine(FDirectory,Format('state-%.8d.json',[Latest])));
  try
    var Payload:=Wrapped.GetValue<string>('payload');
    if (Wrapped.GetValue<string>('binding')<>FBinding) or
      (Wrapped.GetValue<Integer>('sequence')<>Latest) or
      (Wrapped.GetValue<string>('sha256')<>THashSHA2.GetHashString(Payload)) then
      raise EReadError.Create('Состояние копирования повреждено или относится к другому файлу.');
    Value:=TJSONObject.ParseJSONValue(Payload);
    if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждено состояние копирования.'); end;
    FState:=TJSONObject(Value); FSequence:=Latest;
  finally Wrapped.Free; end;
end;

constructor TCollectionTransferCopy.CreateNew(const WorkRoot, AllowedRoot:string; const Entry:TCollectionTransferFile);
var Manifest:TJSONObject;
begin
  inherited Create;
  FDirectories:=TList<THandle>.Create; FWorkRoot:=TransferCanonicalDirectory(WorkRoot);
  FAllowedRoot:=TransferCanonicalDirectory(AllowedRoot); FEntry:=Entry; ValidateEntry; CheckStop;
  FBinding:=Binding(FAllowedRoot,FEntry); PinDirectory(FWorkRoot,False);
  FDirectory:=TPath.Combine(FWorkRoot,JobPrefix+GUIDToString(TGUID.NewGuid));
  if not CreateDirectory(PChar(DeletionNativePath(FDirectory)),nil) then RaiseLastOSError;
  PinDirectory(FDirectory,False); Manifest:=TJSONObject.Create;
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'lease'))),GENERIC_READ or GENERIC_WRITE,
    0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; Manifest.Free; RaiseLastOSError; end;
  try
    Manifest.AddPair('kind',CopyKind); Manifest.AddPair('binding',FBinding);
    Manifest.AddPair('directory',ExtractFileName(FDirectory));
    WriteNewJSON(TPath.Combine(FDirectory,'manifest.json'),Manifest);
  finally Manifest.Free; end;
  FState:=TJSONObject.Create; Put('phase','planned'); SaveState;
end;

constructor TCollectionTransferCopy.OpenExisting(const WorkRoot, AllowedRoot, Directory:string; const Entry:TCollectionTransferFile);
var Leaf:string; ID:TGUID; Manifest:TJSONObject;
begin
  inherited Create;
  FDirectories:=TList<THandle>.Create; FWorkRoot:=TransferCanonicalDirectory(WorkRoot);
  FAllowedRoot:=TransferCanonicalDirectory(AllowedRoot); FEntry:=Entry; ValidateEntry;
  FBinding:=Binding(FAllowedRoot,FEntry); FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory));
  Leaf:=ExtractFileName(FDirectory);
  if not SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(FDirectory)),FWorkRoot) or not Leaf.StartsWith(JobPrefix) then
    raise EReadError.Create('Журнал находится вне рабочей папки переноса.');
  ID:=StringToGUID(Copy(Leaf,Length(JobPrefix)+1,MaxInt));
  if Leaf<>JobPrefix+GUIDToString(ID) then raise EReadError.Create('Неверное имя журнала переноса.');
  PinDirectory(FWorkRoot,False); PinDirectory(FDirectory,False);
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'lease'))),GENERIC_READ or GENERIC_WRITE,
    0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  FileKey(FLease);
  Manifest:=ReadJSON(TPath.Combine(FDirectory,'manifest.json'));
  try
    if (Manifest.GetValue<string>('kind')<>CopyKind) or
      (Manifest.GetValue<string>('binding')<>FBinding) or (Manifest.GetValue<string>('directory')<>Leaf) then
      raise EReadError.Create('Журнал относится к другому файлу или папке.');
  finally Manifest.Free; end;
  LoadState;
end;

class function TCollectionTransferCopy.Resume(const WorkRoot, AllowedRoot, Directory:string;
  const Entry:TCollectionTransferFile):TCollectionTransferCopy;
begin Result:=TCollectionTransferCopy.OpenExisting(WorkRoot,AllowedRoot,Directory,Entry); end;

destructor TCollectionTransferCopy.Destroy;
begin
  FState.Free;
  if FLease<>0 then CloseHandle(FLease);
  if Assigned(FDirectories) then
  begin for var Handle in FDirectories do CloseHandle(Handle); FDirectories.Free; end;
  inherited;
end;

function TCollectionTransferCopy.CopyProgress(Done,Total:Int64; Reason:DWORD):DWORD;
begin
  Result:=PROGRESS_STOP;
  try
    // CopyFileEx may supply a write-only stream handle. Our pre-existing
    // metadata lease has READ_ATTRIBUTES and pins the same reserved file ID.
    if (FCallbackGuard=0) or (FileKey(FCallbackGuard)<>Text('key')) then
      raise EReadError.Create('Временная копия была заменена.');
    Space(Max(Int64(0),Total-Done)); Notify('Копирование',Done,Total);
    if Reason=CALLBACK_STREAM_SWITCH then Point('copy-stream-start',FDirectory)
    else if Done>0 then Point('copy-chunk',FDirectory);
    Result:=PROGRESS_CONTINUE;
  except
    on E:Exception do begin FCallbackError:=E.Message; FCallbackAborted:=E is EAbort; end;
  end;
end;

function TransferProgress(TotalFileSize,TotalBytesTransferred,StreamSize,StreamBytesTransferred:Int64;
  StreamNumber,Reason:DWORD; SourceHandle,DestinationHandle:THandle; Context:Pointer):DWORD; stdcall;
begin Result:=TCollectionTransferCopy(Context).CopyProgress(TotalBytesTransferred,TotalFileSize,Reason); end;

function TCollectionTransferCopy.Prepare(const Cancelled:TFunc<Boolean>;
  const Progress:TTransferCopyProgress):TTransferPreparedCopy;
var Source,Output:TTransferStreamSnapshot; Guard,Handle,FinalGuard:THandle;
    Attributes:DWORD; Copied:Boolean; Buffer:TBytes; Rename:^TTransferRenameInfo;
    OldKey,Canonical,Stamp:string; Bytes:Int64;

  function OpenHandle(const Path:string; Access,Share:DWORD):THandle;
  begin
    Result:=CreateFile(PChar(DeletionNativePath(Path)),Access,Share,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
    if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      if FileKey(Result)<>Text('key') then raise EReadError.Create('Временная или готовая копия была заменена.');
    except CloseHandle(Result); raise; end;
  end;

  procedure MakeResult;
  begin
    Output.PinPublishedStreams(FEntry.Destination,Self);
    Result:=TTransferPreparedCopy.Create;
    try
      Result.FSource:=FEntry.Source; Result.FDestination:=FEntry.Destination;
      Result.FIdentity:=Output.Identity; Result.FSHA256:=Output.MainSHA;
      Result.FStreamsJSON:=Output.Description;
      Result.FSourceLease:=Source; Source:=nil; Result.FOutputLease:=Output; Output:=nil;
      Result.FOutputGuard:=FinalGuard; FinalGuard:=0;
      SetLength(Result.FDirectoryGuards,FDirectories.Count);
      for var I:=0 to FDirectories.Count-1 do
        if not DuplicateHandle(GetCurrentProcess,FDirectories[I],GetCurrentProcess,
          @Result.FDirectoryGuards[I],0,False,DUPLICATE_SAME_ACCESS) then RaiseLastOSError;
      Result.CheckUnchanged(FEntry.Identity,FCancelled);
    except Result.Free; Result:=nil; raise; end;
  end;

begin
  Result:=nil; FCancelled:=Cancelled; FProgress:=Progress;
  Source:=nil; Output:=nil; Guard:=0; Handle:=0; FinalGuard:=0;
  try
    CheckStop;
    Source:=TTransferStreamSnapshot.Create(FEntry.Source,FEntry.Identity,'',Self,'Проверка источника');
    if (Text('streams')<>'') and (Text('streams')<>Source.Description) then
      raise EReadError.Create('Содержимое исходника изменилось после подготовки копии.');
    Put('streams',Source.Description);
    PinDirectory(ExtractFilePath(FEntry.Source),False); PinDestination;
    if FEntry.KeepInPlace then
    begin
      Output:=TTransferStreamSnapshot.Create(FEntry.Destination,FEntry.Identity,'',Self,'Проверка готового файла');
      Put('key',Copy(FEntry.Identity,1,25)); Put('identity',Output.Identity); Put('phase','ready'); SaveState;
      MakeResult; Exit;
    end;
    if not MatchText(Text('phase'),['planned','allocated','copying','verified','ready']) then
      raise EReadError.Create('Неизвестное состояние копирования.');

    // A crash after the rename but before the ready record is proved by the
    // reserved file ID and every source stream checksum, never just a name.
    if Present(FEntry.Destination) then
    begin
      if not MatchText(Text('phase'),['verified','ready']) or (Text('key')='') then
        raise EReadError.Create('Путь результата уже занят; существующий файл сохранён.');
      if Text('phase')='verified' then
      begin
        Guard:=OpenHandle(FEntry.Destination,FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE);
        var OriginalAttributes:=GetFileAttributes(PChar(DeletionNativePath(FEntry.Source)));
        var TargetAttributes:=GetFileAttributes(PChar(DeletionNativePath(FEntry.Destination)));
        if (OriginalAttributes=INVALID_FILE_ATTRIBUTES) or (TargetAttributes=INVALID_FILE_ATTRIBUTES) then RaiseLastOSError;
        var Restored:=(TargetAttributes and not FILE_ATTRIBUTE_READONLY) or (OriginalAttributes and FILE_ATTRIBUTE_READONLY);
        if Restored<>TargetAttributes then
          if not SetFileAttributes(PChar(DeletionNativePath(FEntry.Destination)),Restored) then RaiseLastOSError;
        CloseHandle(Guard); Guard:=0;
      end;
      Output:=TTransferStreamSnapshot.Create(FEntry.Destination,'',Text('key'),Self,'Проверка готового файла');
      if Output.Description<>Source.Description then raise EReadError.Create('Готовая копия повреждена или изменена.');
      Point('after-resume-verified',FDirectory);
      Put('identity',Output.Identity); Put('phase','ready'); SaveState;
      MakeResult; Exit;
    end;
    if Text('phase')='ready' then raise EReadError.Create('Готовая копия исчезла после завершённой записи.');

    // Some CopyFileEx stop/error paths remove their incomplete output. There
    // is no published result yet; recreate a reserved attempt from the same
    // guarded, checksum-matched source rather than requiring a missing temp.
    if (Text('key')<>'') and MatchText(Text('phase'),['allocated','copying']) and not Present(Temporary) then
    begin Put('key',''); Put('phase','planned'); SaveState; end;

    if Text('key')='' then
    begin
      // A crash between CREATE_NEW and recording its ID can leave an unknown
      // empty temporary. Do not adopt/delete it: a fresh name resumes safely.
      Put('temporary','.homelib-transfer-'+GUIDToString(TGUID.NewGuid)+'.tmp');
      Put('phase','planned'); SaveState; Point('after-attempt-intent',FDirectory);
      Space(Source.Total);
      Guard:=CreateFile(PChar(DeletionNativePath(Temporary)),GENERIC_READ or GENERIC_WRITE,
        FILE_SHARE_READ,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
      if Guard=INVALID_HANDLE_VALUE then begin Guard:=0; RaiseLastOSError; end;
      Point('after-temp-created',FDirectory);
      Put('key',FileKey(Guard)); Put('phase','allocated'); SaveState;
      Point('after-temp-identity',FDirectory); CloseHandle(Guard); Guard:=0;
    end;
    OldKey:=Text('key');
    if Length(OldKey)<>25 then raise EReadError.Create('Нет проверенного номера временной копии.');
    Guard:=OpenHandle(Temporary,FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE);
    Attributes:=GetFileAttributes(PChar(DeletionNativePath(FEntry.Source)));
    if Attributes=INVALID_FILE_ATTRIBUTES then RaiseLastOSError;
    var TemporaryAttributes:=GetFileAttributes(PChar(DeletionNativePath(Temporary)));
    if TemporaryAttributes=INVALID_FILE_ATTRIBUTES then RaiseLastOSError;
    if TemporaryAttributes and FILE_ATTRIBUTE_READONLY<>0 then
      if not SetFileAttributes(PChar(DeletionNativePath(Temporary)),TemporaryAttributes and not FILE_ATTRIBUTE_READONLY) then RaiseLastOSError;
    if Text('phase')<>'verified' then
    begin
      Put('phase','copying'); SaveState;
    FCallbackError:=''; FCallbackAborted:=False; Space(Source.Total);
    FCallbackGuard:=Guard;
    // The target is exclusively reserved by this journal. A metadata handle
    // allows writes to this same file ID while denying replacement/deletion.
    Copied:=CopyFileExW(PChar(DeletionNativePath(FEntry.Source)),PChar(DeletionNativePath(Temporary)),
      TFNProgressRoutine(@TransferProgress),Self,nil,0);
    if not Copied then
    begin
      var Code:=GetLastError;
      if FCallbackError<>'' then
      begin
        if FCallbackAborted then raise EAbort.Create(FCallbackError);
        raise EWriteError.Create(FCallbackError);
      end;
      RaiseLastOSError(Code);
    end;
    Point('after-copy',FDirectory);
    if FileKey(Guard)<>OldKey then raise EReadError.Create('Номер временной копии изменился.');
    TemporaryAttributes:=GetFileAttributes(PChar(DeletionNativePath(Temporary)));
    if TemporaryAttributes=INVALID_FILE_ATTRIBUTES then RaiseLastOSError;
    if TemporaryAttributes and FILE_ATTRIBUTE_READONLY<>0 then
      if not SetFileAttributes(PChar(DeletionNativePath(Temporary)),TemporaryAttributes and not FILE_ATTRIBUTE_READONLY) then RaiseLastOSError;
    Handle:=OpenHandle(Temporary,GENERIC_WRITE,FILE_SHARE_READ or FILE_SHARE_WRITE);
    if not FlushFileBuffers(Handle) then RaiseLastOSError;
    CloseHandle(Handle); Handle:=0;
    end;
    // Acquire a data read lease before releasing the metadata guard. Checksums
    // stay protected from writes through verification, rename and final handoff.
    Output:=TTransferStreamSnapshot.Create(Temporary,'',OldKey,Self,'Проверка копии',True);
    if Output.Description<>Source.Description then raise EReadError.Create('Контрольные суммы потоков копии не совпали.');
    CloseHandle(Guard); Guard:=0;
    Handle:=OpenHandle(Temporary,Winapi.Windows._DELETE or FILE_READ_ATTRIBUTES,FILE_SHARE_READ);
    Put('phase','verified'); SaveState; Point('after-verified',FDirectory);
    var FullName:=DeletionNativePath(FEntry.Destination);
    SetLength(Buffer,SizeOf(TTransferRenameInfo)+Length(FullName)*SizeOf(WideChar));
    FillChar(Buffer[0],Length(Buffer),0); Rename:=Pointer(@Buffer[0]);
    Rename.FileNameLength:=Length(FullName)*SizeOf(WideChar);
    Move(PChar(FullName)^,Rename.FileName[0],Rename.FileNameLength);
    // FileRenameInfo targets this exact handle, without replacement. Parent
    // handles pin the canonical destination path for the entire operation.
    if not TransferSetFileInformation(Handle,3,Rename,Length(Buffer)) then RaiseLastOSError;
    Point('after-publish',FDirectory);
    if Attributes and FILE_ATTRIBUTE_READONLY<>0 then
      if not SetFileAttributes(PChar(DeletionNativePath(FEntry.Destination)),
        GetFileAttributes(PChar(DeletionNativePath(FEntry.Destination))) or FILE_ATTRIBUTE_READONLY) then RaiseLastOSError;
    TransferReadFileState(FEntry.Destination,Canonical,Stamp,Bytes);
    if (Copy(Stamp,1,25)<>OldKey) or (Bytes<>FEntry.Bytes) then raise EReadError.Create('Готовая копия заменена.');
    Put('identity',Stamp); Put('phase','ready'); SaveState; Point('after-ready',FDirectory);
    CloseHandle(Handle); Handle:=0;
    // The old stream leases deny writes during this transition. A fresh read
    // handle then also denies deletion; the same held file ID proves handoff.
    FinalGuard:=OpenHandle(FEntry.Destination,GENERIC_READ,FILE_SHARE_READ);
    Output.Identity:=Stamp;
    MakeResult;
  finally
    if FinalGuard<>0 then CloseHandle(FinalGuard);
    if Handle<>0 then CloseHandle(Handle);
    if Guard<>0 then CloseHandle(Guard);
    Output.Free; Source.Free; FCancelled:=nil; FProgress:=nil; FCallbackGuard:=0;
  end;
end;

function TCollectionTransferCopy.VerifyDestination(const Expected:TTransferDestinationProof;
  const Cancelled:TFunc<Boolean>; const Progress:TTransferCopyProgress):TTransferPreparedCopy;
var Snapshot:TTransferStreamSnapshot; Canonical,Identity:string; Bytes:Int64;
begin
  Result:=nil; Snapshot:=nil; FCancelled:=Cancelled; FProgress:=Progress;
  try
    CheckStop;
    if FEntry.KeepInPlace or (Length(Expected.Identity)<>59) or (Length(Expected.SHA256)<>64) or
      (Expected.StreamsJSON='') or (Length(Expected.StreamsJSON)>MaxJSONBytes) then
      raise EArgumentException.Create('Нужен сохранённый результат отдельной проверенной копии.');
    for var C in Expected.SHA256 do
      if not CharInSet(C,['0'..'9','a'..'f']) then raise EArgumentException.Create('Неверная контрольная сумма результата.');
    if (Text('phase')<>'ready') or (Text('identity')<>Expected.Identity) or
      (Text('key')<>Copy(Expected.Identity,1,25)) or (Text('streams')<>Expected.StreamsJSON) then
      raise EReadError.Create('Журнал копирования не совпал с сохранённым результатом переноса.');
    PinDestination(False);
    TransferReadFileState(FEntry.Destination,Canonical,Identity,Bytes);
    if (Canonical<>FEntry.Destination) or (Identity<>Expected.Identity) or (Bytes<>FEntry.Bytes) then
      raise EReadError.Create('Готовая копия отсутствует, заменена или изменилась.');
    Snapshot:=TTransferStreamSnapshot.Create(FEntry.Destination,Expected.Identity,'',Self,'Проверка сохранённой копии');
    if (Snapshot.Description<>Expected.StreamsJSON) or (Snapshot.MainSHA<>Expected.SHA256) then
      raise EReadError.Create('Контрольные суммы готовой копии не совпали с сохранённым результатом.');
    Point('destination-verified',FDirectory); CheckStop;
    Result:=TTransferPreparedCopy.Create;
    try
      Result.FSource:=FEntry.Source; Result.FDestination:=FEntry.Destination;
      Result.FIdentity:=Snapshot.Identity; Result.FSHA256:=Snapshot.MainSHA; Result.FStreamsJSON:=Snapshot.Description;
      Result.FOutputLease:=Snapshot; Snapshot:=nil;
      SetLength(Result.FDirectoryGuards,FDirectories.Count);
      for var I:=0 to FDirectories.Count-1 do
        if not DuplicateHandle(GetCurrentProcess,FDirectories[I],GetCurrentProcess,
          @Result.FDirectoryGuards[I],0,False,DUPLICATE_SAME_ACCESS) then RaiseLastOSError;
      Result.CheckDestinationUnchanged(Cancelled);
    except Result.Free; Result:=nil; raise; end;
  finally Snapshot.Free; FCancelled:=nil; FProgress:=nil; end;
end;

end.
