unit unit_CollectionTransferPlan;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections,
  unit_BookCompressionPlanStore;

type
  TCollectionTransferRoot = record
    ID, Path: string;
  end;

  TCollectionTransferInput = record
    RootID, FileName: string;
  end;

  TCollectionTransferFile = record
    Source, Destination, Identity: string;
    Bytes: Int64;
    KeepInPlace, ExternalImages: Boolean;
  end;

  TCollectionTransferVisitor = reference to procedure(const Input: TCollectionTransferInput);
  TCollectionTransferFileVisitor = reference to procedure(const Entry: TCollectionTransferFile);
  TCollectionTransferEnumerator = reference to procedure(const Visit: TCollectionTransferVisitor);

  // A read-only inventory of the payloads. Only bounded scratch metadata is
  // written; creating a plan never creates a destination or changes a book.
  // The subsequent transfer journal and catalogue switch are separate gates.
  TCollectionTransferPlan = class
  private
    FStore: TCompressionPlanStore;
    FDestinationInput, FDestination, FContentRoot: string;
    FRoots: TArray<TCollectionTransferRoot>;
    FInputRoots, FCanonicalRoots, FMappedRoots: TDictionary<string,string>;
    FCancelled: TFunc<Boolean>;
    FExamined: Int64;
    procedure CheckCancelled;
    procedure AddInput(const Input: TCollectionTransferInput);
    function AddFile(const RootID, FileName: string; ExternalImages: Boolean): string;
  public
    constructor Create(const Destination, WorkRoot: string;
      const Roots: TArray<TCollectionTransferRoot>; const Enumerate: TCollectionTransferEnumerator;
      const OperationID: TGUID; const Cancelled: TFunc<Boolean> = nil);
    destructor Destroy; override;
    function RootDestination(const RootID: string): string;
    procedure ForEachFile(const Visit: TCollectionTransferFileVisitor);
    procedure CheckUnchanged;
    function FileCount: Int64;
    function CopyBytes: Int64;
    function CopyFileCount: Int64;
    property Examined: Int64 read FExamined;
    property Destination: string read FDestination;
    property ContentRoot: string read FContentRoot;
  end;

// Shared metadata primitives; readers still take their own data leases.
function TransferCanonicalDirectory(const Path: string): string;
procedure TransferReadFileState(const Path: string; out Canonical, Identity: string; out Bytes: Int64);

implementation

uses Winapi.Windows, System.IOUtils, System.Hash, System.JSON, System.Generics.Defaults,
  SQLiteWrap, unit_ZipMemberDeletion, unit_MHLArchiveHelpers, unit_FLibraryCompat;

function OrdinaryPath(const Path: string): string;
begin
  Result:=Path;
  if Result.StartsWith('\\?\UNC\',True) then Result:='\\'+Copy(Result,9,MaxInt)
  else if Result.StartsWith('\\?\') then Delete(Result,1,4);
end;

function OrdinaryFinalPath(Handle: THandle): string;
var Buffer: TArray<Char>; Count: DWORD;
begin
  SetLength(Buffer,32768);
  Count:=GetFinalPathNameByHandle(Handle,@Buffer[0],Length(Buffer),0);
  if (Count=0) or (Count>=DWORD(Length(Buffer))) then RaiseLastOSError;
  SetString(Result,PChar(@Buffer[0]),Count);
  Result:=OrdinaryPath(Result);
end;

function ImageSources(const Source: string): TArray<string>;
begin
  Result:=FLibraryImageSourceFiles(DeletionNativePath(Source));
  for var I:=0 to High(Result) do Result[I]:=OrdinaryPath(Result[I]);
end;

function ImageSourcesJSON(const Paths: TArray<string>): string;
var Data:TJSONArray;
begin
  Data:=TJSONArray.Create;
  try
    for var Path in Paths do Data.Add(Path);
    Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function CanonicalDirectory(const Path: string): string;
var Handle: THandle; Info: TByHandleFileInformation;
begin
  if (Path='') or not TPath.IsPathRooted(Path) then
    raise EArgumentException.Create('Для переноса нужен полный путь к папке.');
  Handle:=CreateFile(PChar(DeletionNativePath(ExpandFileName(Path))),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0 then
      raise EReadError.Create('Ожидалась папка коллекции: '+Path);
    Result:=IncludeTrailingPathDelimiter(OrdinaryFinalPath(Handle));
  finally CloseHandle(Handle); end;
end;

procedure ReadFileState(const Path: string; out Canonical, Identity: string; out Bytes: Int64);
var Handle: THandle; Info: TByHandleFileInformation;
begin
  if (Path='') or not TPath.IsPathRooted(Path) then
    raise EArgumentException.Create('В плане переноса нужен полный путь к файлу.');
  Handle:=CreateFile(PChar(DeletionNativePath(ExpandFileName(Path))),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
      (Info.nNumberOfLinks<>1) or ((Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0)) then
      raise EReadError.Create('Файл переноса является ссылкой или не имеет однозначного номера: '+Path);
    Canonical:=OrdinaryFinalPath(Handle);
    Identity:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+
      IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8)+':'+
      IntToHex(Info.nFileSizeHigh,8)+IntToHex(Info.nFileSizeLow,8)+':'+
      IntToHex(Info.ftLastWriteTime.dwHighDateTime,8)+IntToHex(Info.ftLastWriteTime.dwLowDateTime,8);
    Bytes:=(Int64(Info.nFileSizeHigh) shl 32) or Info.nFileSizeLow;
  finally CloseHandle(Handle); end;
end;

function UnderRoot(const Path, Root: string): Boolean;
begin Result:=Path.StartsWith(Root,True); end;

procedure CheckDestinationParent(const Destination, ContentRoot: string);
var Parent: string; Attributes: DWORD;
begin
  // This is the sole shared ancestor created by the future writer. A link
  // here would silently redirect otherwise lexically-contained paths.
  Parent:=TPath.Combine(Destination,'HomeLibre-sources');
  Attributes:=GetFileAttributes(PChar(DeletionNativePath(Parent)));
  if (Attributes<>INVALID_FILE_ATTRIBUTES) and
    ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or (Attributes and FILE_ATTRIBUTE_DIRECTORY=0)) then
    raise EReadError.Create('Папка назначения является ссылкой или занята файлом: '+Parent);
  if GetFileAttributes(PChar(DeletionNativePath(ExcludeTrailingPathDelimiter(ContentRoot))))<>INVALID_FILE_ATTRIBUTES then
    raise EReadError.Create('Папка этой операции уже занята; существующие данные не перезаписываются.');
end;

function ReadTransferFile(Query: TSQLiteQuery): TCollectionTransferFile;
begin
  Result.Source:=Query.FieldAsString(0); Result.Destination:=Query.FieldAsString(1);
  Result.Identity:=Query.FieldAsString(2); Result.Bytes:=StrToInt64(Query.FieldAsString(3));
  Result.KeepInPlace:=Query.FieldAsInt(4)<>0; Result.ExternalImages:=Query.FieldAsInt(5)<>0;
end;

procedure TCollectionTransferPlan.CheckCancelled;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Проверка переноса остановлена. Файлы коллекции не изменены.');
end;

constructor TCollectionTransferPlan.Create(const Destination, WorkRoot: string;
  const Roots: TArray<TCollectionTransferRoot>; const Enumerate: TCollectionTransferEnumerator;
  const OperationID: TGUID; const Cancelled: TFunc<Boolean>);
var Sorted: TArray<TCollectionTransferRoot>;
begin
  inherited Create;
  if (Length(Roots)=0) or not Assigned(Enumerate) or IsEqualGUID(OperationID,TGUID.Empty) then
    raise EArgumentException.Create('Для переноса нужны источники и номер операции.');
  FCancelled:=Cancelled; CheckCancelled;
  FDestinationInput:=Destination; FDestination:=CanonicalDirectory(Destination);
  FContentRoot:=IncludeTrailingPathDelimiter(TPath.Combine(FDestination,
    'HomeLibre-sources\'+GUIDToString(OperationID)));
  CheckDestinationParent(FDestination,FContentRoot);
  FInputRoots:=TDictionary<string,string>.Create(TStringComparer.Ordinal);
  FCanonicalRoots:=TDictionary<string,string>.Create(TStringComparer.Ordinal);
  FMappedRoots:=TDictionary<string,string>.Create(TStringComparer.Ordinal);
  FRoots:=Copy(Roots); Sorted:=Copy(Roots);
  for var Root in Roots do
  begin
    if (Root.ID='') or FCanonicalRoots.ContainsKey(Root.ID) then
      raise EArgumentException.Create('Идентификаторы источников должны быть непустыми и разными.');
    FCanonicalRoots.Add(Root.ID,CanonicalDirectory(Root.Path));
    FInputRoots.Add(Root.ID,IncludeTrailingPathDelimiter(ExpandFileName(OrdinaryPath(Root.Path))));
  end;
  // A child root keeps its relative layout within its outer source. Root
  // aliases resolve to the same folder; neither duplicates a physical file.
  TArray.Sort<TCollectionTransferRoot>(Sorted,TComparer<TCollectionTransferRoot>.Construct(
    function(const A,B:TCollectionTransferRoot):Integer
    begin
      Result:=Length(FCanonicalRoots[A.ID])-Length(FCanonicalRoots[B.ID]);
      if Result=0 then Result:=CompareText(FCanonicalRoots[A.ID],FCanonicalRoots[B.ID]);
    end));
  for var I:=0 to High(Sorted) do
  begin
    CheckCancelled;
    var Root:=FCanonicalRoots[Sorted[I].ID]; var Mapped:='';
    for var J:=0 to I-1 do
      if UnderRoot(Root,FCanonicalRoots[Sorted[J].ID]) then
      begin
        Mapped:=FMappedRoots[Sorted[J].ID]+Copy(Root,Length(FCanonicalRoots[Sorted[J].ID])+1,MaxInt);
        Break;
      end;
    if Mapped='' then
    begin
      if UnderRoot(Root,FDestination) then Mapped:=Root
      else Mapped:=FContentRoot+LowerCase(THashSHA2.GetHashString(LowerCase(Root)))+'\';
    end;
    FMappedRoots.Add(Sorted[I].ID,Mapped);
  end;
  FStore:=TCompressionPlanStore.Create(WorkRoot);
  FStore.DB.ExecSQL('CREATE TABLE TransferFiles(Source TEXT NOT NULL PRIMARY KEY,'+
    'Destination TEXT NOT NULL UNIQUE,Identity TEXT NOT NULL,Bytes INTEGER NOT NULL,'+
    'KeepInPlace INTEGER NOT NULL,ExternalImages INTEGER NOT NULL,DestinationKey TEXT NOT NULL UNIQUE)');
  FStore.DB.ExecSQL('CREATE TABLE TransferBindings(RootID TEXT NOT NULL,Source TEXT NOT NULL,'+
    'PRIMARY KEY(RootID,Source)) WITHOUT ROWID');
  FStore.DB.ExecSQL('CREATE TABLE TransferImageSets(Source TEXT NOT NULL PRIMARY KEY,PathsJSON TEXT NOT NULL)');
  FStore.DB.ExecSQL('BEGIN');
  try
    Enumerate(
      procedure(const Input:TCollectionTransferInput)
      begin
        CheckCancelled; AddInput(Input); Inc(FExamined);
        if FExamined mod 1024=0 then
        begin FStore.DB.ExecSQL('COMMIT'); FStore.DB.ExecSQL('BEGIN'); end;
      end);
    CheckCancelled; FStore.DB.ExecSQL('COMMIT');
  except
    FStore.DB.Rollback;
    raise;
  end;
  FStore.Seal;
end;

destructor TCollectionTransferPlan.Destroy;
begin
  FStore.Free; FInputRoots.Free; FCanonicalRoots.Free; FMappedRoots.Free;
  inherited;
end;

function TCollectionTransferPlan.RootDestination(const RootID: string): string;
begin
  if not FMappedRoots.TryGetValue(RootID,Result) then
    raise EArgumentException.Create('Неизвестный источник переноса: '+RootID);
end;

function TCollectionTransferPlan.AddFile(const RootID, FileName: string; ExternalImages: Boolean): string;
var Source, Identity, Destination, Root, Requested, Logical: string; Bytes: Int64; Query:TSQLiteQuery; Keep:Boolean;
begin
  CheckCancelled;
  if not FCanonicalRoots.TryGetValue(RootID,Root) then
    raise EArgumentException.Create('Неизвестный источник переноса: '+RootID);
  ReadFileState(FileName,Source,Identity,Bytes);
  if not UnderRoot(Source,Root) then
    raise EReadError.Create('Файл выходит за пределы папки источника: '+Source);
  Requested:=ExpandFileName(OrdinaryPath(FileName)); Logical:=Requested;
  if UnderRoot(Requested,FInputRoots[RootID]) then
    Logical:=Root+Copy(Requested,Length(FInputRoots[RootID])+1,MaxInt);
  if not SameFileName(Logical,Source) then
    raise EReadError.Create('Внутренняя ссылка меняет относительное размещение файла: '+FileName);
  Destination:=RootDestination(RootID)+Copy(Source,Length(Root)+1,MaxInt);
  Keep:=SameFileName(Source,Destination);
  if not UnderRoot(Destination,FDestination) then
    raise EReadError.Create('Назначение выходит за пределы общей папки.');
  if not Keep and (GetFileAttributes(PChar(DeletionNativePath(Destination)))<>INVALID_FILE_ATTRIBUTES) then
    raise EReadError.Create('Назначение уже занято. Существующий файл не перезаписывается: '+Destination);
  Query:=FStore.DB.NewQuery('SELECT Destination,Identity FROM TransferFiles WHERE Source=?',[Source]);
  try
    Query.Open;
    if not Query.Eof then
    begin
      if (Query.FieldAsString(0)<>Destination) or (Query.FieldAsString(1)<>Identity) then
        raise EReadError.Create('Один файл получил разные пути или изменился во время проверки: '+Source);
      if ExternalImages then FStore.DB.ExecSQL('UPDATE TransferFiles SET ExternalImages=1 WHERE Source=?',[Source]);
    end
    else
      FStore.DB.ExecSQL('INSERT INTO TransferFiles VALUES(?,?,?,?,?,?,?)',
        [Source,Destination,Identity,Bytes,Ord(Keep),Ord(ExternalImages),LowerCase(Destination)]);
  finally Query.Free; end;
  FStore.DB.ExecSQL('INSERT OR IGNORE INTO TransferBindings VALUES(?,?)',[RootID,Source]);
  Result:=Source;
end;

procedure TCollectionTransferPlan.AddInput(const Input: TCollectionTransferInput);
begin
  var Source:=AddFile(Input.RootID,Input.FileName,False);
  // Use the same discovery rule as native reading. Sidecar archives are
  // indivisible files too, even if only a few of their books are catalogued.
  if IsSevenZipArchive(DeletionNativePath(Source)) then
  begin
    var Images:=ImageSources(Source); var Snapshot:=ImageSourcesJSON(Images);
    var Previous:=FStore.DB.QuerySingleString('SELECT PathsJSON FROM TransferImageSets WHERE Source=?',[Source]);
    if (Previous<>'') and (Previous<>Snapshot) then
      raise EReadError.Create('Набор внешних картинок изменился во время проверки: '+Source);
    FStore.DB.ExecSQL('INSERT OR IGNORE INTO TransferImageSets VALUES(?,?)',[Source,Snapshot]);
    for var ImageFile in Images do
      if ImageFile<>'' then AddFile(Input.RootID,ImageFile,True);
  end;
end;

procedure TCollectionTransferPlan.ForEachFile(const Visit: TCollectionTransferFileVisitor);
var Query:TSQLiteQuery;
begin
  if not Assigned(Visit) then raise EArgumentNilException.Create('Visit');
  Query:=FStore.DB.NewQuery('SELECT Source,Destination,Identity,Bytes,KeepInPlace,ExternalImages '+
    'FROM TransferFiles ORDER BY Source');
  try
    Query.Open;
    while not Query.Eof do
    begin CheckCancelled; Visit(ReadTransferFile(Query)); Query.Next; end;
  finally Query.Free; end;
end;

procedure TCollectionTransferPlan.CheckUnchanged;
var Query:TSQLiteQuery;
begin
  CheckCancelled;
  if CanonicalDirectory(FDestinationInput)<>FDestination then
    raise EReadError.Create('Общая папка изменилась после проверки.');
  CheckDestinationParent(FDestination,FContentRoot);
  for var Root in FRoots do
    if CanonicalDirectory(Root.Path)<>FCanonicalRoots[Root.ID] then
      raise EReadError.Create('Папка источника изменилась после проверки: '+Root.Path);
  ForEachFile(
    procedure(const Entry:TCollectionTransferFile)
    var Canonical,Identity:string; Bytes:Int64;
    begin
      ReadFileState(Entry.Source,Canonical,Identity,Bytes);
      if (Canonical<>Entry.Source) or (Identity<>Entry.Identity) or (Bytes<>Entry.Bytes) then
        raise EReadError.Create('Файл изменился после проверки переноса: '+Entry.Source);
      if not Entry.KeepInPlace and
        (GetFileAttributes(PChar(DeletionNativePath(Entry.Destination)))<>INVALID_FILE_ATTRIBUTES) then
        raise EReadError.Create('Назначение занято после проверки переноса: '+Entry.Destination);
    end);
  // Missing sidecars are witnesses as well: a new cover/image archive cannot
  // silently stay behind when the final source root is changed.
  Query:=FStore.DB.NewQuery('SELECT Source,PathsJSON FROM TransferImageSets');
  try
    Query.Open;
    while not Query.Eof do
    begin
      CheckCancelled;
      if ImageSourcesJSON(ImageSources(Query.FieldAsString(0)))<>Query.FieldAsString(1) then
        raise EReadError.Create('Набор внешних картинок изменился после проверки: '+Query.FieldAsString(0));
      Query.Next;
    end;
  finally Query.Free; end;
end;

function TCollectionTransferPlan.FileCount: Int64;
begin Result:=FStore.DB.QuerySingleInt('SELECT count(*) FROM TransferFiles'); end;

function TCollectionTransferPlan.CopyBytes: Int64;
begin Result:=FStore.DB.QuerySingleInt('SELECT coalesce(sum(Bytes),0) FROM TransferFiles WHERE KeepInPlace=0'); end;

function TCollectionTransferPlan.CopyFileCount: Int64;
begin Result:=FStore.DB.QuerySingleInt('SELECT count(*) FROM TransferFiles WHERE KeepInPlace=0'); end;

function TransferCanonicalDirectory(const Path: string): string;
begin Result:=CanonicalDirectory(Path); end;

procedure TransferReadFileState(const Path: string; out Canonical, Identity: string; out Bytes: Int64);
begin ReadFileState(Path,Canonical,Identity,Bytes); end;

end.
