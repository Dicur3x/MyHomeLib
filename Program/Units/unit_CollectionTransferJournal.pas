unit unit_CollectionTransferJournal;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, Winapi.Windows,
  SQLiteWrap, unit_CollectionTransferPlan, unit_CollectionTransferCatalogue,
  unit_CollectionTransferCopy;

type
  TTransferJournalGroup = record
    ID, Files, Bytes: Int64;
    State: string;
  end;
  TTransferJournalGroupVisitor = reference to procedure(const Group: TTransferJournalGroup);
  TTransferJournalProgress = reference to procedure(const Stage, Source: string; Done, Total: Int64);

  TPreparedTransferGroup = class
  private
    FID: Int64;
    FFiles: TList<Int64>;
    FCopies: TObjectList<TTransferPreparedCopy>;
  public
    constructor Create(ID: Int64);
    destructor Destroy; override;
    function Count: Integer;
    function FileID(Index: Integer): Int64;
    function CopyAt(Index: Integer): TTransferPreparedCopy;
    property ID: Int64 read FID;
  end;

  // Durable copy preparation for connected archive/sidecar groups. A trusted
  // external review digest is required to resume. No catalogue publication,
  // original removal or "operation complete" transition is implemented here.
  TCollectionTransferJournal = class
  private
    FWorkRoot, FDestination, FDirectory, FCopiesRoot, FReviewSHA: string;
    FReview, FState: TSQLiteDatabase;
    FReviewLease: TFileStream;
    FStateLease: IInterface;
    FLease: THandle;
    FGuards: TList<THandle>;
    FCancelled: TFunc<Boolean>;
    FProgress: TTransferJournalProgress;
    FNextReserveCheck: UInt64;
    procedure CheckStop;
    function PinDirectory(const Path: string): string;
    procedure OpenReview(const Expected: string; const ExpectedFileKey: string = '');
    procedure OpenState;
    function Meta(const Name: string): string;
    procedure SaveMeta(const Name, Value: string);
    function FindComponent(ID: Int64): Int64;
    procedure BuildReview(Catalogue: TCollectionTransferCatalogue; Plan: TCollectionTransferPlan);
    procedure CheckRoots;
    procedure CheckNegativePaths;
    procedure CheckGroupImages(GroupID: Int64);
    procedure CheckGroupBindings(GroupID: Int64);
    constructor OpenExisting(const WorkRoot, Destination, Directory, ReviewSHA: string);
  public
    constructor Create(const WorkRoot: string; Catalogue: TCollectionTransferCatalogue;
      Plan: TCollectionTransferPlan; const Cancelled: TFunc<Boolean> = nil);
    class function Resume(const WorkRoot, Destination, Directory, ReviewSHA: string): TCollectionTransferJournal; static;
    destructor Destroy; override;
    procedure ForEachGroup(const Visit: TTransferJournalGroupVisitor);
    function PrepareGroup(GroupID: Int64; const Cancelled: TFunc<Boolean> = nil;
      const Progress: TTransferJournalProgress = nil): TPreparedTransferGroup;
    function PendingGroup: Int64;
    function GroupCount: Int64;
    function FileCount: Int64;
    property Directory: string read FDirectory;
    property ReviewSHA256: string read FReviewSHA;
    property Review: TSQLiteDatabase read FReview;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferJournalTestPoint: TProc<string,string,Int64,Int64>;
{$ENDIF}

implementation

uses System.IOUtils, System.JSON, System.Hash, unit_Globals, unit_Consts,
  unit_Settings, dm_user, unit_BookCompressionReceipt, unit_ZipMemberDeletion,
  unit_CollectionTransferReferences;

const JournalKind='HomeLibre collection transfer preparation v1';
  Prefix='collection-transfer-';

procedure Point(const Stage,Directory:string; GroupID,FileID:Int64);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferJournalTestPoint) then TransferJournalTestPoint(Stage,Directory,GroupID,FileID);
{$ENDIF}
end;

function FileEntry(Q:TSQLiteQuery; Offset:Integer=0):TCollectionTransferFile;
begin
  Result.Source:=Q.FieldAsString(Offset); Result.Destination:=Q.FieldAsString(Offset+1);
  Result.Identity:=Q.FieldAsString(Offset+2); Result.Bytes:=StrToInt64(Q.FieldAsString(Offset+3));
  Result.KeepInPlace:=Q.FieldAsInt(Offset+4)<>0; Result.ExternalImages:=Q.FieldAsInt(Offset+5)<>0;
end;

procedure CreateEmptyFile(const Path:string);
begin
  var Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  CloseHandle(Handle);
end;

constructor TPreparedTransferGroup.Create(ID:Int64);
begin
  inherited Create; FID:=ID; FFiles:=TList<Int64>.Create;
  FCopies:=TObjectList<TTransferPreparedCopy>.Create;
end;

destructor TPreparedTransferGroup.Destroy;
begin FCopies.Free; FFiles.Free; inherited; end;

function TPreparedTransferGroup.Count:Integer;
begin Result:=FCopies.Count; end;

function TPreparedTransferGroup.FileID(Index:Integer):Int64;
begin Result:=FFiles[Index]; end;

function TPreparedTransferGroup.CopyAt(Index:Integer):TTransferPreparedCopy;
begin Result:=FCopies[Index]; end;

procedure TCollectionTransferJournal.CheckStop;
var Available,Capacity:UInt64;
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Подготовка переноса остановлена. Исходники и журнал сохранены.');
  if GetTickCount64<FNextReserveCheck then Exit;
  FNextReserveCheck:=GetTickCount64+1000;
  var SystemDrive:=TPath.GetPathRoot(GetEnvironmentVariable('SystemRoot'));
  if not GetDiskFreeSpaceEx(PChar(SystemDrive),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then
    raise EWriteError.Create('Перенос остановлен: на системном диске нужно сохранить 8 ГБ свободного места.');
  for var Path in TArray<string>.Create(FWorkRoot,FDestination) do
  begin
    if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Path)),Available,Capacity,nil) then RaiseLastOSError;
    if Available<UInt64(512)*1024*1024 then
      raise EWriteError.Create('Для журнала и копий нужно сохранить резерв 512 МБ.');
  end;
end;

function TCollectionTransferJournal.PinDirectory(const Path:string):string;
var Info:TByHandleFileInformation;
begin
  var Handle:=CreateFile(PChar(DeletionNativePath(Path)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
      (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
      not SameFileName(TransferCanonicalDirectory(Path),IncludeTrailingPathDelimiter(ExpandFileName(Path))) then
      raise EReadError.Create('Папка журнала или назначения изменилась. Исходники сохранены.');
    Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
    FGuards.Add(Handle);
  except CloseHandle(Handle); raise; end;
end;

procedure TCollectionTransferJournal.SaveMeta(const Name,Value:string);
begin FReview.ExecSQL('INSERT INTO Context VALUES(?,?)',[Name,Value]); end;

function TCollectionTransferJournal.Meta(const Name:string):string;
begin Result:=FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;

procedure TCollectionTransferJournal.OpenReview(const Expected:string; const ExpectedFileKey:string);
var Buffer:TBytes; Hash:THashSHA2; N:Integer; Canonical,Identity:string; Bytes:Int64;
begin
  if ((Expected='') and (ExpectedFileKey='')) or ((Expected<>'') and (Length(Expected)<>64)) then
    raise EReadError.Create('Не сохранена проверочная сумма плана переноса.');
  for var C in Expected do
    if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then raise EReadError.Create('Неверная проверочная сумма плана переноса.');
  var Path:=TPath.Combine(FDirectory,'review.sqlite');
  TransferReadFileState(Path,Canonical,Identity,Bytes);
  if not SameFileName(Canonical,Path) or
    ((ExpectedFileKey<>'') and (Copy(Identity,1,25)<>ExpectedFileKey)) then
    raise EReadError.Create('План переноса заменён или перенаправлен.');
  FReviewLease:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  try
    if CompressionFileKey(Path)<>Copy(Identity,1,25) then raise EReadError.Create('План переноса заменён.');
    Hash:=THashSHA2.Create; SetLength(Buffer,1024*1024);
    repeat
      CheckStop; N:=FReviewLease.Read(Buffer[0],Length(Buffer)); if N>0 then Hash.Update(Buffer,N);
    until N=0;
    FReviewSHA:=Hash.HashAsString;
    if (Expected<>'') and not SameText(Expected,FReviewSHA) then raise EReadError.Create('План переноса повреждён или изменён. Исходники сохранены.');
    FReview:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Path));
  except FreeAndNil(FReviewLease); raise; end;
end;

procedure TCollectionTransferJournal.OpenState;
begin
  var Path:=TPath.Combine(FDirectory,'state.sqlite');
  FStateLease:=AcquireCompressionDatabaseLease(Path,Meta('state_key'));
  FState:=TSQLiteDatabase.Create(DeletionNativePath(Path));
  if FState.QuerySingleString('PRAGMA integrity_check')<>'ok' then
    raise EReadError.Create('Журнал переноса повреждён. Исходники сохранены.');
  FState.QuerySingleString('PRAGMA journal_mode=DELETE'); FState.ExecSQL('PRAGMA synchronous=FULL');
  FState.ExecSQL('PRAGMA cache_size=-4096');
  if (FState.QuerySingleInt('SELECT count(*) FROM FileState')<>FileCount) or
    (FState.QuerySingleInt('SELECT count(*) FROM GroupState')<>GroupCount) then
    raise EReadError.Create('Состав журнала переноса не совпал с проверенным планом.');
end;

function TCollectionTransferJournal.FindComponent(ID:Int64):Int64;
  var Current,Parent,Steps:Int64;
  begin
    Current:=ID; Steps:=0;
    repeat
      CheckStop; Parent:=FReview.QuerySingleInt('SELECT ParentID FROM Parents WHERE FileID=?',[Current]);
      if Parent<=0 then raise EReadError.Create('Неполная группа файлов переноса.');
      if Parent=Current then Break;
      Current:=Parent; Inc(Steps);
      if Steps>FReview.QuerySingleInt('SELECT count(*) FROM Files') then raise EReadError.Create('Повреждён граф файлов переноса.');
    until False;
    Result:=Current;
    Current:=ID;
    while Current<>Result do
    begin
      Parent:=FReview.QuerySingleInt('SELECT ParentID FROM Parents WHERE FileID=?',[Current]);
      FReview.ExecSQL('UPDATE Parents SET ParentID=? WHERE FileID=?',[Result,Current]); Current:=Parent;
    end;
  end;

procedure TCollectionTransferJournal.BuildReview(Catalogue:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan);
var Info:TCollectionInfo;
begin
  Catalogue.CheckUnchanged; Plan.CheckUnchanged; Info:=Catalogue.CollectionInfo;
  FReview.ExecSQL('CREATE TABLE Context(Name TEXT PRIMARY KEY,Value TEXT NOT NULL) WITHOUT ROWID');
  FReview.ExecSQL('CREATE TABLE Roots(ID TEXT PRIMARY KEY,InputPath TEXT NOT NULL,CanonicalPath TEXT,Destination TEXT) WITHOUT ROWID');
  FReview.ExecSQL('CREATE TABLE Files(ID INTEGER PRIMARY KEY,Source TEXT NOT NULL UNIQUE,Destination TEXT NOT NULL UNIQUE,'+
    'Identity TEXT NOT NULL,Bytes INTEGER NOT NULL,KeepInPlace INTEGER NOT NULL,ExternalImages INTEGER NOT NULL,GroupID INTEGER)');
  FReview.ExecSQL('CREATE TABLE ImageSets(OwnerID INTEGER PRIMARY KEY,PathsJSON TEXT NOT NULL)');
  FReview.ExecSQL('CREATE TABLE Edges(OwnerID INTEGER NOT NULL,FileID INTEGER NOT NULL,PRIMARY KEY(OwnerID,FileID)) WITHOUT ROWID');
  FReview.ExecSQL('CREATE TABLE Bindings(ID INTEGER PRIMARY KEY,Kind INTEGER NOT NULL,BookID INTEGER NOT NULL,LibID TEXT,'+
    'Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER,Root TEXT,SourceKey TEXT,Source TEXT,'+
    'CanonicalSource TEXT,RootID TEXT,Identity TEXT,State INTEGER NOT NULL,Reason TEXT,FileID INTEGER)');
  FReview.ExecSQL('CREATE INDEX Bindings_File ON Bindings(FileID)');
  FReview.ExecSQL('CREATE TABLE NegativePaths(Path TEXT NOT NULL PRIMARY KEY) WITHOUT ROWID');
  FReview.ExecSQL('CREATE TABLE Parents(FileID INTEGER PRIMARY KEY,ParentID INTEGER NOT NULL)');
  FReview.ExecSQL('BEGIN');
  SaveMeta('kind',JournalKind); SaveMeta('directory',ExtractFileName(FDirectory));
  SaveMeta('work_root',FWorkRoot); SaveMeta('destination',FDestination); SaveMeta('content_root',Plan.ContentRoot);
  SaveMeta('work_key',PinDirectory(FWorkRoot)); SaveMeta('destination_key',PinDirectory(FDestination));
  SaveMeta('state_key',CompressionFileKey(TPath.Combine(FDirectory,'state.sqlite')));
  SaveMeta('collection',IntToStr(Info.ID)); SaveMeta('catalogue',Info.DBFileName);
  SaveMeta('personal',Catalogue.PersonalFile); SaveMeta('catalogue_key',Catalogue.CatalogueKey);
  SaveMeta('personal_key',Catalogue.PersonalKey); SaveMeta('collection_root',Info.RootFolder);
  SaveMeta('base_root',Catalogue.BaseRoot); SaveMeta('base_catalogue',Catalogue.BaseCatalogue);
  SaveMeta('sources_json',Catalogue.SourcesJSON);
  Catalogue.ForEachRoot(
    procedure(Root:TCollectionTransferRoot)
    begin CheckStop; FReview.ExecSQL('INSERT INTO Roots(ID,InputPath) VALUES(?,?)',[Root.ID,Root.Path]); end);
  Plan.ForEachRoot(
    procedure(const Root:TCollectionTransferRootMap)
    begin
      CheckStop;
      if not SameFileName(FReview.QuerySingleString('SELECT InputPath FROM Roots WHERE ID=?',[Root.ID]),Root.InputPath) then
        raise EReadError.Create('План файлов относится к другому источнику коллекции.');
      FReview.ExecSQL('UPDATE Roots SET CanonicalPath=?,Destination=? WHERE ID=?',[Root.CanonicalPath,Root.Destination,Root.ID]);
    end);
  Plan.ForEachFile(
    procedure(const Entry:TCollectionTransferFile)
    begin
      CheckStop;
      FReview.ExecSQL('INSERT INTO Files(Source,Destination,Identity,Bytes,KeepInPlace,ExternalImages) VALUES(?,?,?,?,?,?)',
        [Entry.Source,Entry.Destination,Entry.Identity,Entry.Bytes,Ord(Entry.KeepInPlace),Ord(Entry.ExternalImages)]);
    end);
  FReview.ExecSQL('INSERT INTO Parents SELECT ID,ID FROM Files');
  Catalogue.ForEachBinding(
    procedure(const Binding:TTransferCatalogueBinding)
    var FileID:Int64;
    begin
      CheckStop; FileID:=0;
      if Binding.State=tbsAvailable then
      begin
        FileID:=FReview.QuerySingleInt('SELECT ID FROM Files WHERE Source=?',[Binding.CanonicalSource]);
        if FileID=0 then raise EReadError.Create('В плане переноса пропущен файл книги.');
      end;
      FReview.ExecSQL('INSERT INTO Bindings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,nullif(?,0))',
        [Binding.ID,Binding.Locator.Kind,Binding.Locator.BookID,Binding.Locator.LibID,Binding.Locator.Folder,
         Binding.Locator.FileName,Binding.Locator.Extension,Binding.Locator.InsideNo,Binding.Locator.OldSize,
         Binding.Locator.Root,Binding.Locator.SourceKey,Binding.Source,Binding.CanonicalSource,Binding.RootID,
         Binding.Identity,Ord(Binding.State),Binding.Reason,FileID]);
      if (Binding.State=tbsMissing) and (Binding.Source<>'') then
        FReview.ExecSQL('INSERT OR IGNORE INTO NegativePaths VALUES(?)',[Binding.Source]);
    end);
  Catalogue.ForEachMissingContainer(
    procedure(Path:string)
    begin CheckStop; FReview.ExecSQL('INSERT OR IGNORE INTO NegativePaths VALUES(?)',[Path]); end);
  Plan.ForEachImageSet(
    procedure(const Source,PathsJSON:string)
    var Values:TJSONValue; OwnerID,ImageID:Int64;
    begin
      CheckStop; OwnerID:=FReview.QuerySingleInt('SELECT ID FROM Files WHERE Source=?',[Source]);
      if OwnerID=0 then raise EReadError.Create('Нет архива для внешних картинок.');
      FReview.ExecSQL('INSERT INTO ImageSets VALUES(?,?)',[OwnerID,PathsJSON]);
      Values:=TJSONObject.ParseJSONValue(PathsJSON);
      try
        if not (Values is TJSONArray) then raise EReadError.Create('Повреждён список внешних картинок.');
        for var Value in TJSONArray(Values) do
          if Value.Value<>'' then
          begin
            ImageID:=FReview.QuerySingleInt('SELECT ID FROM Files WHERE Source=?',[Value.Value]);
            if ImageID=0 then raise EReadError.Create('В плане пропущен архив внешних картинок.');
            FReview.ExecSQL('INSERT OR IGNORE INTO Edges VALUES(?,?)',[OwnerID,ImageID]);
            var A:=FindComponent(OwnerID); var B:=FindComponent(ImageID);
            if A<>B then
            begin
              if A>B then begin var Swap:=A; A:=B; B:=Swap; end;
              FReview.ExecSQL('UPDATE Parents SET ParentID=? WHERE FileID=?',[A,B]);
            end;
          end;
      finally Values.Free; end;
    end);
  if FReview.QuerySingleInt('SELECT count(*) FROM Files f WHERE NOT EXISTS(SELECT 1 FROM Bindings b WHERE b.FileID=f.ID) '+
    'AND NOT EXISTS(SELECT 1 FROM Edges e WHERE e.FileID=f.ID)')<>0 then
    raise EReadError.Create('План содержит файл, не связанный с книгами коллекции.');
  var Q:=FReview.NewQuery('SELECT ID FROM Files ORDER BY ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      var ID:=StrToInt64(Q.FieldAsString(0)); var GroupID:=FindComponent(ID);
      FReview.ExecSQL('UPDATE Files SET GroupID=? WHERE ID=?',[GroupID,ID]); Q.Next;
    end;
  finally Q.Free; end;
  FReview.ExecSQL('DROP TABLE Parents');
  FReview.ExecSQL('CREATE INDEX Files_Group ON Files(GroupID,ID)');
  FReview.ExecSQL('CREATE TABLE Groups AS SELECT GroupID AS ID,count(*) AS Files,sum(Bytes) AS Bytes FROM Files GROUP BY GroupID');
  FReview.ExecSQL('CREATE UNIQUE INDEX Groups_ID ON Groups(ID)');
  CaptureTransferReferences(FReview,Catalogue.PersonalFile,
    function:Boolean begin CheckStop; Result:=False; end);
  Catalogue.CheckUnchanged; Plan.CheckUnchanged;
  FReview.ExecSQL('COMMIT');
end;

constructor TCollectionTransferJournal.Create(const WorkRoot:string; Catalogue:TCollectionTransferCatalogue;
  Plan:TCollectionTransferPlan; const Cancelled:TFunc<Boolean>);
begin
  inherited Create;
  if (Catalogue=nil) or (Plan=nil) then raise EArgumentException.Create('Нужен проверенный план коллекции.');
  FCancelled:=Cancelled; FGuards:=TList<THandle>.Create;
  FWorkRoot:=TransferCanonicalDirectory(WorkRoot); FDestination:=Plan.Destination; CheckStop;
  PinDirectory(FWorkRoot);
  FDirectory:=TPath.Combine(FWorkRoot,Prefix+GUIDToString(TGUID.NewGuid));
  if not CreateDirectory(PChar(DeletionNativePath(FDirectory)),nil) then RaiseLastOSError;
  PinDirectory(FDirectory);
  FCopiesRoot:=TPath.Combine(FDirectory,'copies');
  if not CreateDirectory(PChar(DeletionNativePath(FCopiesRoot)),nil) then RaiseLastOSError;
  PinDirectory(FCopiesRoot);
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'lease'))),GENERIC_READ or GENERIC_WRITE,
    0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  var ReviewFile:=TPath.Combine(FDirectory,'review.sqlite'); var StateFile:=TPath.Combine(FDirectory,'state.sqlite');
  CreateEmptyFile(ReviewFile); CreateEmptyFile(StateFile);
  FReview:=TSQLiteDatabase.Create(DeletionNativePath(ReviewFile));
  FReview.QuerySingleString('PRAGMA journal_mode=DELETE'); FReview.ExecSQL('PRAGMA synchronous=FULL');
  FReview.ExecSQL('PRAGMA cache_size=-4096'); FReview.ExecSQL('PRAGMA temp_store=FILE');
  BuildReview(Catalogue,Plan);
  FStateLease:=AcquireCompressionDatabaseLease(StateFile,Meta('state_key'));
  FState:=TSQLiteDatabase.Create(DeletionNativePath(StateFile));
  FState.QuerySingleString('PRAGMA journal_mode=DELETE'); FState.ExecSQL('PRAGMA synchronous=FULL');
  FState.ExecSQL('CREATE TABLE FileState(FileID INTEGER PRIMARY KEY,Child TEXT NOT NULL DEFAULT '''','+
    'State TEXT NOT NULL DEFAULT ''planned'' CHECK(State IN (''planned'',''prepared'')),'+
    'Identity TEXT NOT NULL DEFAULT '''',SHA256 TEXT NOT NULL DEFAULT '''',StreamsJSON TEXT NOT NULL DEFAULT '''')');
  FState.ExecSQL('CREATE TABLE GroupState(GroupID INTEGER PRIMARY KEY,State TEXT NOT NULL '+
    'CHECK(State IN (''planned'',''copying'',''prepared'')))');
  FState.ExecSQL('BEGIN');
  var Q:=FReview.NewQuery('SELECT ID FROM Files');
  try Q.Open; while not Q.Eof do begin FState.ExecSQL('INSERT INTO FileState(FileID) VALUES(?)',[StrToInt64(Q.FieldAsString(0))]); Q.Next; end;
  finally Q.Free; end;
  Q:=FReview.NewQuery('SELECT ID FROM Groups');
  try Q.Open; while not Q.Eof do begin FState.ExecSQL('INSERT INTO GroupState VALUES(?,''planned'')',[StrToInt64(Q.FieldAsString(0))]); Q.Next; end;
  finally Q.Free; end;
  FState.ExecSQL('COMMIT');
  var ReviewKey:=CompressionFileKey(ReviewFile); FreeAndNil(FReview);
  // The newly created file is sealed under a read lease and hashed in bounded,
  // cancellable chunks. Its digest must be stored independently by the caller.
  OpenReview('',ReviewKey); FCancelled:=nil;
end;

constructor TCollectionTransferJournal.OpenExisting(const WorkRoot,Destination,Directory,ReviewSHA:string);
begin
  inherited Create; FGuards:=TList<THandle>.Create;
  if ReviewSHA='' then raise EReadError.Create('Не сохранена проверочная сумма плана переноса.');
  FWorkRoot:=TransferCanonicalDirectory(WorkRoot); FDestination:=TransferCanonicalDirectory(Destination); CheckStop;
  FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory));
  var Leaf:=ExtractFileName(FDirectory);
  if not SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(FDirectory)),FWorkRoot) or not Leaf.StartsWith(Prefix) then
    raise EReadError.Create('Журнал находится вне выбранной рабочей папки.');
  var ID:=StringToGUID(Copy(Leaf,Length(Prefix)+1,MaxInt));
  if Leaf<>Prefix+GUIDToString(ID) then raise EReadError.Create('Неверное имя папки журнала.');
  var WorkKey:=PinDirectory(FWorkRoot); var DestinationKey:=PinDirectory(FDestination);
  PinDirectory(FDirectory); FCopiesRoot:=TPath.Combine(FDirectory,'copies'); PinDirectory(FCopiesRoot);
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'lease'))),GENERIC_READ or GENERIC_WRITE,
    0,nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  CompressionFileKey(TPath.Combine(FDirectory,'lease'));
  OpenReview(ReviewSHA);
  if (Meta('kind')<>JournalKind) or (Meta('directory')<>Leaf) or
    (Meta('work_root')<>FWorkRoot) or (Meta('destination')<>FDestination) or
    (Meta('work_key')<>WorkKey) or (Meta('destination_key')<>DestinationKey) then
    raise EReadError.Create('Журнал относится к другому месту переноса. Исходники сохранены.');
  OpenState;
end;

class function TCollectionTransferJournal.Resume(const WorkRoot,Destination,Directory,ReviewSHA:string):TCollectionTransferJournal;
begin Result:=TCollectionTransferJournal.OpenExisting(WorkRoot,Destination,Directory,ReviewSHA); end;

destructor TCollectionTransferJournal.Destroy;
begin
  FState.Free; FReview.Free; FReviewLease.Free; FStateLease:=nil;
  if FLease<>0 then CloseHandle(FLease);
  if FGuards<>nil then begin for var Handle in FGuards do CloseHandle(Handle); FGuards.Free; end;
  inherited;
end;

procedure TCollectionTransferJournal.CheckRoots;
begin
  var Q:=FReview.NewQuery('SELECT InputPath,CanonicalPath FROM Roots WHERE CanonicalPath IS NOT NULL');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop;
      if TransferCanonicalDirectory(Q.FieldAsString(0))<>Q.FieldAsString(1) then
        raise EReadError.Create('Папка источника изменилась. Повторите проверку переноса.');
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure TCollectionTransferJournal.CheckNegativePaths;
begin
  var Q:=FReview.NewQuery('SELECT Path FROM NegativePaths');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop;
      if GetFileAttributes(PChar(DeletionNativePath(Q.FieldAsString(0))))<>INVALID_FILE_ATTRIBUTES then
        raise EReadError.Create('Появился ранее отсутствовавший архив. Повторите проверку переноса.');
      var Code:=GetLastError;
      if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure TCollectionTransferJournal.CheckGroupImages(GroupID:Int64);
begin
  var Q:=FReview.NewQuery('SELECT f.Source,i.PathsJSON FROM ImageSets i JOIN Files f ON f.ID=i.OwnerID WHERE f.GroupID=?',[GroupID]);
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop;
      if TransferImageSourcesSnapshot(Q.FieldAsString(0))<>Q.FieldAsString(1) then
        raise EReadError.Create('Изменился набор внешних картинок. Копии сохранены, пути в каталоге не изменены.');
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure TCollectionTransferJournal.CheckGroupBindings(GroupID:Int64);
var Catalogue,Personal:TSQLiteDatabase; CatalogueLease,PersonalLease:IInterface; Q,Live:TSQLiteQuery;
begin
  CheckStop; Catalogue:=nil; Personal:=nil; Q:=nil; Live:=nil;
  try
    CatalogueLease:=AcquireCompressionDatabaseLease(Meta('catalogue'),Meta('catalogue_key'));
    PersonalLease:=AcquireCompressionDatabaseLease(Meta('personal'),Meta('personal_key'));
    Catalogue:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Meta('catalogue')));
    Personal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Meta('personal')));
    Catalogue.ExecSQL('BEGIN'); Personal.ExecSQL('BEGIN');
    var CollectionID:=StrToInt(Meta('collection'));
    Q:=Personal.NewQuery('SELECT RootFolder,DBFileName FROM Bases WHERE DatabaseID=?',[CollectionID]);
    Q.Open;
    if Q.Eof or (Q.FieldAsString(0)<>Meta('base_root')) or (Q.FieldAsString(1)<>Meta('base_catalogue')) or
      not SameFileName(IncludeTrailingPathDelimiter(Settings.ExpandCollectionRoot(Q.FieldAsString(0))),Meta('collection_root')) or
      not SameFileName(Settings.ExpandCollectionFileName(Q.FieldAsString(1)),Meta('catalogue')) then
      raise EReadError.Create('Подключение коллекции изменилось. Перенос не продолжен.');
    FreeAndNil(Q);
    var CurrentSources:='';
    if Catalogue.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''Settings''')<>0 then
      CurrentSources:=Catalogue.QuerySingleString('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_CATALOG_SOURCES]);
    if CurrentSources<>Meta('sources_json') then raise EReadError.Create('Изменился список источников коллекции.');
    Q:=FReview.NewQuery('SELECT b.Kind,b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.Root,b.SourceKey '+
      'FROM Bindings b JOIN Files f ON f.ID=b.FileID WHERE f.GroupID=? ORDER BY b.ID',[GroupID]);
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var Kind:=Q.FieldAsInt(0); var BookID:=Q.FieldAsInt(1);
      if Kind=2 then
        Live:=Catalogue.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,BookID FROM CatalogBookCopies WHERE SourceKey=?',[Q.FieldAsString(8)])
      else if Kind=1 then
        Live:=Personal.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=? AND DatabaseID=?',[BookID,CollectionID])
      else Live:=Catalogue.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?',[BookID]);
      Live.Open;
      if Live.Eof then
      begin
        if Kind<>1 then raise EReadError.Create('Запись книги изменилась после проверки переноса.');
      end
      else
      begin
        for var I:=0 to 4 do
          if Live.FieldAsString(I)<>Q.FieldAsString(I+2) then
            raise EReadError.Create('Расположение или номер книги изменились после проверки переноса.');
        if (Kind=2) and ((Live.FieldAsString(5)<>Q.FieldAsString(7)) or (Live.FieldAsInt(6)<>BookID)) then
          raise EReadError.Create('Дополнительная копия книги изменилась после проверки переноса.');
      end;
      FreeAndNil(Live); Q.Next;
    end;
  finally Live.Free; Q.Free; Personal.Free; Catalogue.Free; end;
end;

function TCollectionTransferJournal.PrepareGroup(GroupID:Int64; const Cancelled:TFunc<Boolean>;
  const Progress:TTransferJournalProgress):TPreparedTransferGroup;
var Q,State:TSQLiteQuery; Job:TCollectionTransferCopy; Prepared:TTransferPreparedCopy;
    Entry:TCollectionTransferFile; FileID:Int64; Child,FilePhase,OldIdentity,OldSHA,OldStreams:string;
begin
  Result:=nil; FCancelled:=Cancelled; FProgress:=Progress; Q:=nil; State:=nil; Job:=nil; Prepared:=nil;
  try
    try
    CheckStop;
    if FReview.QuerySingleInt('SELECT count(*) FROM Groups WHERE ID=?',[GroupID])<>1 then
      raise EArgumentException.Create('Неизвестная группа переноса.');
    var Phase:=FState.QuerySingleString('SELECT State FROM GroupState WHERE GroupID=?',[GroupID]);
    if not ((Phase='planned') or (Phase='copying') or (Phase='prepared')) then raise EReadError.Create('Повреждено состояние группы переноса.');
    CheckRoots; CheckNegativePaths; CheckGroupBindings(GroupID); CheckGroupImages(GroupID);
    FState.ExecSQL('UPDATE GroupState SET State=''copying'' WHERE GroupID=?',[GroupID]);
    Point('group-copying',FDirectory,GroupID,0);
    Result:=TPreparedTransferGroup.Create(GroupID);
    Q:=FReview.NewQuery('SELECT ID,Source,Destination,Identity,Bytes,KeepInPlace,ExternalImages FROM Files WHERE GroupID=? ORDER BY ID',[GroupID]);
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; FileID:=StrToInt64(Q.FieldAsString(0)); Entry:=FileEntry(Q,1);
      State:=FState.NewQuery('SELECT Child,State,Identity,SHA256,StreamsJSON FROM FileState WHERE FileID=?',[FileID]);
      State.Open; if State.Eof then raise EReadError.Create('В журнале нет файла группы.');
      Child:=State.FieldAsString(0); FilePhase:=State.FieldAsString(1);
      OldIdentity:=State.FieldAsString(2); OldSHA:=State.FieldAsString(3); OldStreams:=State.FieldAsString(4);
      FreeAndNil(State);
      if not ((FilePhase='planned') or (FilePhase='prepared')) then raise EReadError.Create('Неизвестное состояние файла в журнале.');
      if Child='' then
      begin
        if FilePhase<>'planned' then raise EReadError.Create('Нет исходного журнала готовой копии.');
        Job:=TCollectionTransferCopy.CreateNew(FCopiesRoot,FDestination,Entry);
        Point('child-created',FDirectory,GroupID,FileID);
        Child:=ExtractFileName(Job.Directory);
        FState.ExecSQL('UPDATE FileState SET Child=? WHERE FileID=?',[Child,FileID]);
        Point('child-linked',FDirectory,GroupID,FileID);
      end
      else
      begin
        if not Child.StartsWith('transfer-copy-') then raise EReadError.Create('Неверная ссылка на журнал копии.');
        var Token:=StringToGUID(Copy(Child,Length('transfer-copy-')+1,MaxInt));
        if Child<>'transfer-copy-'+GUIDToString(Token) then raise EReadError.Create('Неверная ссылка на журнал копии.');
        Job:=TCollectionTransferCopy.Resume(FCopiesRoot,FDestination,TPath.Combine(FCopiesRoot,Child),Entry);
      end;
      Prepared:=Job.Prepare(Cancelled,
        procedure(const Stage:string; Done,Total:Int64)
        begin if Assigned(FProgress) then FProgress(Stage,Entry.Source,Done,Total); end);
      Point('child-prepared',FDirectory,GroupID,FileID);
      if (FilePhase='prepared') and
        ((OldIdentity<>Prepared.Identity) or (OldSHA<>Prepared.SHA256) or (OldStreams<>Prepared.StreamsJSON)) then
        raise EReadError.Create('Проверочная запись готовой копии изменилась. Исходники сохранены.');
      FState.ExecSQL('BEGIN');
      try
        FState.ExecSQL('UPDATE FileState SET State=''prepared'',Identity=?,SHA256=?,StreamsJSON=? WHERE FileID=?',
          [Prepared.Identity,Prepared.SHA256,Prepared.StreamsJSON,FileID]);
        Point('file-receipt-uncommitted',FDirectory,GroupID,FileID);
        FState.ExecSQL('COMMIT');
      except FState.Rollback; raise; end;
      Point('file-receipt',FDirectory,GroupID,FileID);
      Result.FFiles.Add(FileID); Result.FCopies.Add(Prepared); Prepared:=nil; FreeAndNil(Job);
      Q.Next;
    end;
    CheckStop; CheckNegativePaths; CheckGroupImages(GroupID); CheckGroupBindings(GroupID);
    FState.ExecSQL('UPDATE GroupState SET State=''prepared'' WHERE GroupID=?',[GroupID]);
    Point('group-prepared',FDirectory,GroupID,0);
    except Result.Free; Result:=nil; raise; end;
  finally
    Prepared.Free; Job.Free; State.Free; Q.Free; FCancelled:=nil; FProgress:=nil;
  end;
end;

procedure TCollectionTransferJournal.ForEachGroup(const Visit:TTransferJournalGroupVisitor);
begin
  if not Assigned(Visit) then Exit;
  var Q:=FReview.NewQuery('SELECT ID,Files,Bytes FROM Groups ORDER BY ID');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var Group:TTransferJournalGroup; Group.ID:=StrToInt64(Q.FieldAsString(0));
      Group.Files:=StrToInt64(Q.FieldAsString(1)); Group.Bytes:=StrToInt64(Q.FieldAsString(2));
      Group.State:=FState.QuerySingleString('SELECT State FROM GroupState WHERE GroupID=?',[Group.ID]);
      Visit(Group); Q.Next;
    end;
  finally Q.Free; end;
end;

function TCollectionTransferJournal.PendingGroup:Int64;
begin Result:=FState.QuerySingleInt('SELECT coalesce(min(GroupID),0) FROM GroupState'); end;

function TCollectionTransferJournal.GroupCount:Int64;
begin Result:=FReview.QuerySingleInt('SELECT count(*) FROM Groups'); end;

function TCollectionTransferJournal.FileCount:Int64;
begin Result:=FReview.QuerySingleInt('SELECT count(*) FROM Files'); end;

end.
