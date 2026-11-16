unit unit_CollectionTransferJournal;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, Winapi.Windows,
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
  // external review digest is required to resume. Per-database locator/history
  // publication is implemented; original removal and completion remain separate.
  TCollectionTransferJournal = class
  private
    FWorkRoot, FDestination, FDirectory, FCopiesRoot, FReviewSHA: string;
    FReview, FState: TSQLiteDatabase;
    FPublicationSession:TObject;
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
    function ReadPreparedGroupProof(GroupID:Int64; const SHA:string):System.JSON.TJSONObject;
    procedure OpenPublicationSession;
    procedure SaveMeta(const Name, Value: string);
    function FindComponent(ID: Int64): Int64;
    procedure BuildReview(Catalogue: TCollectionTransferCatalogue; Plan: TCollectionTransferPlan);
    procedure CheckRoots;
    procedure CheckNegativePaths;
    procedure CheckGroupImages(GroupID: Int64);
    procedure CheckGroupBindings(GroupID: Int64);
    procedure CheckPublishedFork(ForkID:Int64);
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
    function PublicationScanCount:Integer;
    function ResourceValidationCount:Integer;
    procedure VerifyGroupResources(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean> = nil);
    function SealPreparedGroup(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean> = nil):string;
    function RecoverPreparedGroup(GroupID:Int64; const ExpectedProofSHA:string;
      const Cancelled:TFunc<Boolean> = nil):TPreparedTransferGroup;
    procedure CheckPreparedGroupProof(Prepared:TPreparedTransferGroup; const SHA:string;
      const Cancelled:TFunc<Boolean> = nil);
    function HoldPreparedGroupProof(GroupID:Int64; const SHA:string):TStream;
    function VerifyPublishedGroup(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean> = nil):Int64;
    procedure RemovePublishedGroup(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>;
      const RegistryCheck:TProc<TSQLiteDatabase>; const SaveIntent,RemoveSources:TProc<TSQLiteDatabase,TArray<Int64>>);
    procedure PublishCatalogueForks(const Cancelled:TFunc<Boolean> = nil);
    procedure PublishCatalogueFork(ForkID:Int64; const Cancelled:TFunc<Boolean> = nil);
    function EffectiveCatalogue(RegistrationID:Integer):string;
    procedure PublishGroupLocations(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean> = nil;
      const PersonalChanges:TProc<TSQLiteDatabase> = nil);
    procedure ReconcileGroupLocations(Prepared:TPreparedTransferGroup; const ProofSHA:string;
      const Cancelled:TFunc<Boolean>; const PersonalCheck:TProc<TSQLiteDatabase>);
    procedure CheckSpace;
    procedure EnsureFinalRootDirectory;
    function HasRootFinalization:Boolean;
    function FinalizeRoots(const Cancelled:TFunc<Boolean> = nil):Boolean;
    function HasCachePreparation:Boolean;
    function PrepareSourceCaches(const Cancelled:TFunc<Boolean> = nil):Int64;
    function InstallSourceCacheVersions(const Cancelled:TFunc<Boolean> = nil):Int64;
    property Directory: string read FDirectory;
    property ReviewSHA256: string read FReviewSHA;
    property Review: TSQLiteDatabase read FReview;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferJournalTestPoint: TProc<string,string,Int64,Int64>;
{$ENDIF}

implementation

uses System.IOUtils, System.Hash, unit_Globals, unit_Consts,
  unit_Settings, dm_user, unit_BookCompressionReceipt, unit_ZipMemberDeletion,
  unit_CollectionTransferReferences, unit_CollectionTransferForks, unit_CollectionTransferLocations,
  unit_CollectionTransferPublication, unit_CollectionTransferResources, unit_CollectionTransferLayout,
  unit_CollectionTransferFinalization, unit_CollectionTransferCachePreparation;

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
begin
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Подготовка переноса остановлена. Исходники и журнал сохранены.');
  CheckSpace;
end;

procedure TCollectionTransferJournal.CheckSpace;
var Available,Capacity:UInt64;
begin
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
  FState:=TSQLiteDatabase.Create(DeletionNativePath(Path),False);
  if FState.QuerySingleString('PRAGMA integrity_check')<>'ok' then
    raise EReadError.Create('Журнал переноса повреждён. Исходники сохранены.');
  FState.QuerySingleString('PRAGMA journal_mode=DELETE'); FState.ExecSQL('PRAGMA synchronous=FULL');
  FState.ExecSQL('PRAGMA cache_size=-4096');
  if (FState.QuerySingleInt('SELECT count(*) FROM FileState')<>FileCount) or
    (FState.QuerySingleInt('SELECT count(*) FROM GroupState')<>GroupCount) then
    raise EReadError.Create('Состав журнала переноса не совпал с проверенным планом.');
  if FReview.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''CatalogueForks''')<>0 then
    if (FState.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''ForkState''')<>1) or
      (FState.QuerySingleInt('SELECT count(*) FROM ForkState')<>FReview.QuerySingleInt('SELECT count(*) FROM CatalogueForks')) then
      raise EReadError.Create('Состав копий общих каталогов не совпал с планом.');
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
  CaptureTransferCatalogueForks(FReview,function:Boolean begin CheckStop; Result:=False; end);
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
  FState.ExecSQL('CREATE TABLE ForkState(ForkID INTEGER PRIMARY KEY,Child TEXT NOT NULL DEFAULT '''','+
    'State TEXT NOT NULL DEFAULT ''planned'' CHECK(State IN (''planned'',''prepared'',''published'')),'+
    'Identity TEXT NOT NULL DEFAULT '''',SHA256 TEXT NOT NULL DEFAULT '''',StreamsJSON TEXT NOT NULL DEFAULT '''')');
  FState.ExecSQL('BEGIN');
  var Q:=FReview.NewQuery('SELECT ID FROM Files');
  try Q.Open; while not Q.Eof do begin FState.ExecSQL('INSERT INTO FileState(FileID) VALUES(?)',[StrToInt64(Q.FieldAsString(0))]); Q.Next; end;
  finally Q.Free; end;
  Q:=FReview.NewQuery('SELECT ID FROM Groups');
  try Q.Open; while not Q.Eof do begin FState.ExecSQL('INSERT INTO GroupState VALUES(?,''planned'')',[StrToInt64(Q.FieldAsString(0))]); Q.Next; end;
  finally Q.Free; end;
  Q:=FReview.NewQuery('SELECT ID FROM CatalogueForks');
  try Q.Open; while not Q.Eof do begin FState.ExecSQL('INSERT INTO ForkState(ForkID) VALUES(?)',[Q.FieldAsInt(0)]); Q.Next; end;
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
  FPublicationSession.Free; FState.Free; FReview.Free; FReviewLease.Free; FStateLease:=nil;
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
  CataloguePublished,PersonalPublished:Boolean;
  function Published(DB:TSQLiteDatabase):Boolean;
  begin
    Result:=False;
    if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreTransferLocations''')<>0 then
      Result:=DB.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferLocations WHERE Operation=? AND GroupID=? AND ReviewSHA256=? '+
        'AND length(BindingSHA256)=64',[Meta('directory'),GroupID,FReviewSHA])=1;
  end;
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
    CataloguePublished:=Published(Catalogue); PersonalPublished:=Published(Personal);
    Q:=FReview.NewQuery('SELECT b.Kind,b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.Root,b.SourceKey '+
      'FROM Bindings b JOIN Files f ON f.ID=b.FileID WHERE f.GroupID=? ORDER BY b.ID',[GroupID]);
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var Kind:=Q.FieldAsInt(0); var BookID:=Q.FieldAsInt(1);
      if ((Kind=1) and PersonalPublished) or ((Kind<>1) and CataloguePublished) then
      begin Q.Next; Continue; end; // The locator transaction validates old/new rows on replay.
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

procedure TCollectionTransferJournal.CheckPublishedFork(ForkID:Int64);
var Personal:TSQLiteDatabase; PersonalLease:IInterface; Q,Live,Marker:TSQLiteQuery;
begin
  PersonalLease:=AcquireCompressionDatabaseLease(Meta('personal'),Meta('personal_key'));
  Personal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Meta('personal'))); Q:=nil; Live:=nil; Marker:=nil;
  try
    Personal.ExecSQL('BEGIN');
    if Personal.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreTransferForkReceipts''')=0 then
      raise EReadError.Create('Нет квитанции переключения общего каталога.');
    var Expected:=FReview.QuerySingleInt('SELECT count(*) FROM ForkMembers WHERE ForkID=?',[ForkID]);
    if (Expected=0) or (Personal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferForkReceipts WHERE Operation=? AND ForkID=?',
      [Meta('directory'),ForkID])<>Expected) then raise EReadError.Create('Неполная квитанция переключения общего каталога.');
    Q:=FReview.NewQuery('SELECT r.RegistrationID,r.RawCatalogue,r.RawRoot,r.Code,f.Destination,s.SHA256 '+
      'FROM ForkMembers m JOIN ReferenceRegistrations r ON r.RegistrationID=m.RegistrationID '+
      'JOIN CatalogueForks f ON f.ID=m.ForkID JOIN ForkSources s ON s.ID=f.SourceID WHERE m.ForkID=?',[ForkID]);
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop;
      Live:=Personal.NewQuery('SELECT DBFileName,RootFolder,Code FROM Bases WHERE DatabaseID=?',[Q.FieldAsInt(0)]); Live.Open;
      if Live.Eof or (Live.FieldAsString(0)<>Q.FieldAsString(4)) or (Live.FieldAsString(1)<>Q.FieldAsString(2)) or
        (Live.FieldAsInt(2)<>Q.FieldAsInt(3)) then raise EReadError.Create('Подключение копии общего каталога изменилось.');
      Marker:=Personal.NewQuery('SELECT ReviewSHA256,Target,TargetKey,SnapshotSHA256,OldCatalogue,OldRoot '+
        'FROM HomeLibreTransferForkReceipts WHERE Operation=? AND ForkID=? AND RegistrationID=?',
        [Meta('directory'),ForkID,Q.FieldAsInt(0)]); Marker.Open;
      if Marker.Eof or (Marker.FieldAsString(0)<>FReviewSHA) or (Marker.FieldAsString(1)<>Q.FieldAsString(4)) or
        (Marker.FieldAsString(3)<>Q.FieldAsString(5)) or (Marker.FieldAsString(4)<>Q.FieldAsString(1)) or
        (Marker.FieldAsString(5)<>Q.FieldAsString(2)) or
        (CompressionFileKey(Q.FieldAsString(4))<>Marker.FieldAsString(2)) then
        raise EReadError.Create('Квитанция или файл копии общего каталога изменились.');
      FreeAndNil(Marker); FreeAndNil(Live); Q.Next;
    end;
  finally Marker.Free; Live.Free; Q.Free; Personal.Free; end;
end;

procedure TCollectionTransferJournal.PublishCatalogueFork(ForkID:Int64; const Cancelled:TFunc<Boolean>);
var State,Q,Live:TSQLiteQuery; Personal:TSQLiteDatabase; Job:TCollectionTransferCopy; Prepared:TTransferPreparedCopy;
  PersonalLease,SourceLease:IInterface; Entry:TCollectionTransferFile; Child,Phase,OldIdentity,OldSHA,OldStreams,SnapshotSHA:string;
begin
  FCancelled:=Cancelled; State:=nil; Q:=nil; Live:=nil; Personal:=nil; Job:=nil; Prepared:=nil;
  try
    CheckStop; Entry:=TransferForkEntry(FReview,ForkID);
    State:=FState.NewQuery('SELECT Child,State,Identity,SHA256,StreamsJSON FROM ForkState WHERE ForkID=?',[ForkID]); State.Open;
    if State.Eof then raise EReadError.Create('В журнале нет копии общего каталога.');
    Child:=State.FieldAsString(0); Phase:=State.FieldAsString(1); OldIdentity:=State.FieldAsString(2);
    OldSHA:=State.FieldAsString(3); OldStreams:=State.FieldAsString(4); FreeAndNil(State);
    PersonalLease:=AcquireCompressionDatabaseLease(Meta('personal'),Meta('personal_key'));
    Personal:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Meta('personal')));
    var HasMarker:=False;
    if Personal.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibreTransferForkReceipts''')<>0 then
      HasMarker:=Personal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferForkReceipts WHERE Operation=? AND ForkID=?',
        [Meta('directory'),ForkID])<>0;
    FreeAndNil(Personal);
    if HasMarker or (Phase='published') then
    begin
      // Personal commit is authoritative even if the process died before the
      // parent receipt. Published catalogues may already contain newer edits.
      CheckPublishedFork(ForkID);
      Point('fork-recovered',FDirectory,ForkID,0);
      FState.ExecSQL('UPDATE ForkState SET State=''published'' WHERE ForkID=?',[ForkID]); Exit;
    end;
    if not ((Phase='planned') or (Phase='prepared')) then raise EReadError.Create('Неизвестное состояние копии каталога.');
    if Child='' then
    begin
      if Phase<>'planned' then raise EReadError.Create('Нет журнала готовой копии каталога.');
      Job:=TCollectionTransferCopy.CreateNew(FCopiesRoot,FDestination,Entry);
      Point('fork-child-created',FDirectory,ForkID,0);
      Child:=ExtractFileName(Job.Directory); FState.ExecSQL('UPDATE ForkState SET Child=? WHERE ForkID=?',[Child,ForkID]);
      Point('fork-child-linked',FDirectory,ForkID,0);
    end
    else
    begin
      if not Child.StartsWith('transfer-copy-') then raise EReadError.Create('Неверная ссылка на журнал копии каталога.');
      var Token:=StringToGUID(Copy(Child,Length('transfer-copy-')+1,MaxInt));
      if Child<>'transfer-copy-'+GUIDToString(Token) then raise EReadError.Create('Неверная ссылка на журнал копии каталога.');
      Job:=TCollectionTransferCopy.Resume(FCopiesRoot,FDestination,TPath.Combine(FCopiesRoot,Child),Entry);
    end;
    Prepared:=Job.Prepare(Cancelled); FreeAndNil(Job);
    SnapshotSHA:=FReview.QuerySingleString('SELECT s.SHA256 FROM ForkSources s JOIN CatalogueForks f ON f.SourceID=s.ID WHERE f.ID=?',[ForkID]);
    if (Prepared.SHA256<>SnapshotSHA) or ((Phase='prepared') and
      ((Prepared.Identity<>OldIdentity) or (Prepared.SHA256<>OldSHA) or (Prepared.StreamsJSON<>OldStreams))) then
      raise EReadError.Create('Проверочная запись копии общего каталога изменилась.');
    FState.ExecSQL('UPDATE ForkState SET State=''prepared'',Identity=?,SHA256=?,StreamsJSON=? WHERE ForkID=?',
      [Prepared.Identity,Prepared.SHA256,Prepared.StreamsJSON,ForkID]);
    Point('fork-copy-prepared',FDirectory,ForkID,0);
    var SourceID:=FReview.QuerySingleInt('SELECT SourceID FROM CatalogueForks WHERE ID=?',[ForkID]);
    SourceLease:=AcquireTransferForkSource(FReview,SourceID,function:Boolean begin CheckStop; Result:=False; end);
    CheckStop;
    Personal:=TSQLiteDatabase.Create(DeletionNativePath(Meta('personal'))); Personal.ExecSQL('PRAGMA synchronous=FULL');
    Personal.ExecSQL('BEGIN IMMEDIATE');
    try
      Personal.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibreTransferForkReceipts(Operation TEXT,ForkID INTEGER,RegistrationID INTEGER,'+
        'ReviewSHA256 TEXT,Target TEXT,TargetKey TEXT,SnapshotSHA256 TEXT,OldCatalogue TEXT,OldRoot TEXT,'+
        'PRIMARY KEY(Operation,ForkID,RegistrationID)) WITHOUT ROWID');
      if Personal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferForkReceipts WHERE Operation=? AND ForkID=?',
        [Meta('directory'),ForkID])<>0 then raise EReadError.Create('Переключение каталога уже выполняет другой владелец.');
      Q:=FReview.NewQuery('SELECT r.RegistrationID,r.RawCatalogue,r.RawRoot,r.Code,r.CatalogueKey,m.RootToken '+
        'FROM ForkMembers m JOIN ReferenceRegistrations r ON r.RegistrationID=m.RegistrationID WHERE m.ForkID=?',[ForkID]); Q.Open;
      if Q.Eof then raise EReadError.Create('Нет подключений для копии каталога.');
      while not Q.Eof do
      begin
        CheckStop; Live:=Personal.NewQuery('SELECT DBFileName,RootFolder,Code FROM Bases WHERE DatabaseID=?',[Q.FieldAsInt(0)]); Live.Open;
        if Live.Eof or (Live.FieldAsString(0)<>Q.FieldAsString(1)) or (Live.FieldAsString(1)<>Q.FieldAsString(2)) or
          (Live.FieldAsInt(2)<>Q.FieldAsInt(3)) or
          (CompressionFileKey(Settings.ExpandCollectionFileName(Live.FieldAsString(0)))<>Q.FieldAsString(4)) or
          (TransferForkRootToken(Settings.ExpandCollectionRoot(Live.FieldAsString(1)))<>Q.FieldAsString(5)) then
          raise EReadError.Create('Подключение общего каталога изменилось до переключения.');
        FreeAndNil(Live);
        Personal.ExecSQL('UPDATE Bases SET DBFileName=? WHERE DatabaseID=?',[Entry.Destination,Q.FieldAsInt(0)]);
        if Personal.LastChangedRows<>1 then raise EWriteError.Create('Не удалось переключить подключение общего каталога.');
        Personal.ExecSQL('INSERT INTO HomeLibreTransferForkReceipts VALUES(?,?,?,?,?,?,?,?,?)',
          [Meta('directory'),ForkID,Q.FieldAsInt(0),FReviewSHA,Entry.Destination,Copy(Prepared.Identity,1,25),SnapshotSHA,
           Q.FieldAsString(1),Q.FieldAsString(2)]);
        Q.Next;
      end;
      FreeAndNil(Q); Point('fork-before-personal-commit',FDirectory,ForkID,0); CheckStop;
      Personal.ExecSQL('COMMIT'); Point('fork-after-personal-commit',FDirectory,ForkID,0);
    except if Personal.InTransaction then Personal.Rollback; raise; end;
    FreeAndNil(Personal); CheckPublishedFork(ForkID);
    FState.ExecSQL('UPDATE ForkState SET State=''published'' WHERE ForkID=?',[ForkID]);
    Point('fork-published',FDirectory,ForkID,0);
  finally
    Prepared.Free; Job.Free; Live.Free; Q.Free; State.Free; Personal.Free;
    FCancelled:=nil;
  end;
end;

procedure TCollectionTransferJournal.PublishCatalogueForks(const Cancelled:TFunc<Boolean>);
begin
  var Q:=FReview.NewQuery('SELECT ID FROM CatalogueForks ORDER BY ID');
  try Q.Open; while not Q.Eof do begin PublishCatalogueFork(Q.FieldAsInt(0),Cancelled); Q.Next; end;
  finally Q.Free; end;
end;

function TCollectionTransferJournal.EffectiveCatalogue(RegistrationID:Integer):string;
begin
  var ForkID:=FReview.QuerySingleInt('SELECT ForkID FROM ForkMembers WHERE RegistrationID=?',[RegistrationID]);
  if ForkID=0 then
    Result:=FReview.QuerySingleString('SELECT Catalogue FROM ReferenceRegistrations WHERE RegistrationID=?',[RegistrationID])
  else
  begin
    CheckPublishedFork(ForkID);
    Result:=FReview.QuerySingleString('SELECT Destination FROM CatalogueForks WHERE ID=?',[ForkID]);
  end;
  if Result='' then raise EArgumentException.Create('Неизвестное подключение коллекции.');
end;

function TCollectionTransferJournal.PublicationScanCount:Integer;
begin
  Result:=0;
  if FPublicationSession<>nil then Result:=TTransferPublicationSession(FPublicationSession).Scans;
end;

function ReadGroupProof(const Path,ExpectedSHA:string; out Key:string):TJSONObject;
var Raw:TBytes; Canonical,Identity:string; Bytes:Int64;
begin
  Result:=nil;
  var Stream:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  try
    TransferReadFileState(Path,Canonical,Identity,Bytes);
    if (Canonical<>Path) or (Stream.Size<>Bytes) or (Bytes<=0) or (Bytes>64*1024*1024) then
      raise EReadError.Create('Неверный файл подтверждения группы переноса.');
    if not SameText(THashSHA2.GetHashString(Stream),ExpectedSHA) then
      raise EReadError.Create('Подтверждение группы не совпало с независимо сохранённой контрольной суммой.');
    Key:=Copy(Identity,1,25); Stream.Position:=0; SetLength(Raw,Integer(Bytes)); Stream.ReadBuffer(Raw[0],Length(Raw));
  finally Stream.Free; end;
  var Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Raw));
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждено подтверждение группы переноса.'); end;
  Result:=TJSONObject(Value);
end;

function CheckedProofChild(const Child:string):string;
begin
  if not Child.StartsWith('transfer-copy-') then raise EReadError.Create('Неверный журнал файла в подтверждении группы.');
  var ID:=StringToGUID(Copy(Child,Length('transfer-copy-')+1,MaxInt));
  if Child<>'transfer-copy-'+GUIDToString(ID) then raise EReadError.Create('Неверный журнал файла в подтверждении группы.');
  Result:=Child;
end;

function TCollectionTransferJournal.SealPreparedGroup(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>):string;
var Previous:TFunc<Boolean>; Data:TJSONObject; Files:TJSONArray; Q,State:TSQLiteQuery;
  Copies:TDictionary<Int64,TTransferPreparedCopy>; Key:string;
begin
  Previous:=FCancelled; FCancelled:=Cancelled; Data:=nil; Q:=nil; State:=nil;
  Copies:=TDictionary<Int64,TTransferPreparedCopy>.Create;
  try
    CheckStop;
    var Verified:=ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end);
    for var I:=0 to Prepared.Count-1 do Copies.Add(Prepared.FileID(I),Prepared.CopyAt(I));
    Data:=TJSONObject.Create; Data.AddPair('kind','HomeLibre prepared transfer group v1');
    Data.AddPair('operation',Meta('directory')); Data.AddPair('review_sha256',FReviewSHA);
    Data.AddPair('group',TJSONNumber.Create(Prepared.ID)); Data.AddPair('resources_sha256',Verified.SHA256);
    Files:=TJSONArray.Create; Data.AddPair('files',Files);
    Q:=FReview.NewQuery('SELECT ID,Source,Destination,Identity,Bytes,KeepInPlace,ExternalImages FROM Files WHERE GroupID=? ORDER BY ID',[Prepared.ID]); Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var Item:=Copies[Q.FieldAsInt(0)]; var Entry:=FileEntry(Q,1);
      State:=FState.NewQuery('SELECT Child,State,Identity,SHA256,StreamsJSON FROM FileState WHERE FileID=?',[Q.FieldAsInt(0)]); State.Open;
      if State.Eof or (State.FieldAsString(1)<>'prepared') or (State.FieldAsString(2)<>Item.Identity) or
        (State.FieldAsString(3)<>Item.SHA256) or (State.FieldAsString(4)<>Item.StreamsJSON) then
        raise EReadError.Create('Данные подготовленного файла изменились перед сохранением группы.');
      var Child:=CheckedProofChild(State.FieldAsString(0)); FreeAndNil(State);
      var Job:=TCollectionTransferCopy.Resume(FCopiesRoot,FDestination,TPath.Combine(FCopiesRoot,Child),Entry);
      Job.Free;
      var Row:=TJSONObject.Create; Files.AddElement(Row); Row.AddPair('id',TJSONNumber.Create(Q.FieldAsInt(0)));
      Row.AddPair('child',Child); Row.AddPair('identity',Item.Identity); Row.AddPair('sha256',Item.SHA256); Row.AddPair('streams',Item.StreamsJSON);
      Q.Next;
    end;
    FreeAndNil(Q);
    var Raw:=TEncoding.UTF8.GetBytes(Data.ToJSON);
    if Length(Raw)>64*1024*1024 then raise EWriteError.Create('Слишком большое подтверждение одной группы.');
    Result:=THashSHA2.GetHashString(Data.ToJSON);
    var Path:=TPath.Combine(FDirectory,'prepared-group-'+IntToStr(Prepared.ID)+'.json');
    var Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
    if Attr=INVALID_FILE_ATTRIBUTES then
    begin
      var Code:=GetLastError; if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
      var Temporary:=TPath.Combine(FDirectory,'.group-proof-'+GUIDToString(TGUID.NewGuid)+'.tmp');
      var Handle:=CreateFile(PChar(DeletionNativePath(Temporary)),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
      if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
      try
        var Stream:=THandleStream.Create(Handle);
        try Stream.WriteBuffer(Raw[0],Length(Raw)); finally Stream.Free; end;
        if not FlushFileBuffers(Handle) then RaiseLastOSError;
      finally CloseHandle(Handle); end;
      Point('group-proof-written',FDirectory,Prepared.ID,0); CheckStop;
      if not MoveFileEx(PChar(DeletionNativePath(Temporary)),PChar(DeletionNativePath(Path)),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
      Point('group-proof-published',FDirectory,Prepared.ID,0);
    end;
    var Existing:=ReadGroupProof(Path,Result,Key); Existing.Free;
    FState.ExecSQL('CREATE TABLE IF NOT EXISTS GroupProof(GroupID INTEGER PRIMARY KEY,FileKey TEXT NOT NULL,SHA256 TEXT NOT NULL)');
    FState.ExecSQL('BEGIN');
    try
      State:=FState.NewQuery('SELECT FileKey,SHA256 FROM GroupProof WHERE GroupID=?',[Prepared.ID]); State.Open;
      if not State.Eof and ((State.FieldAsString(0)<>Key) or (State.FieldAsString(1)<>Result)) then
        raise EReadError.Create('Сохранённое подтверждение группы изменилось.');
      FreeAndNil(State);
      FState.ExecSQL('INSERT OR IGNORE INTO GroupProof VALUES(?,?,?)',[Prepared.ID,Key,Result]);
      Point('group-proof-before-commit',FDirectory,Prepared.ID,0); CheckStop;
      FState.ExecSQL('COMMIT'); Point('group-proof-after-commit',FDirectory,Prepared.ID,0);
    except if FState.InTransaction then FState.Rollback; raise; end;
  finally State.Free; Q.Free; Data.Free; Copies.Free; FCancelled:=Previous; end;
end;

function TCollectionTransferJournal.ReadPreparedGroupProof(GroupID:Int64; const SHA:string):TJSONObject;
var Q:TSQLiteQuery; Key:string;
begin
  Result:=nil; Q:=nil;
  try
    if (Length(SHA)<>64) or (FReview.QuerySingleInt('SELECT count(*) FROM Groups WHERE ID=?',[GroupID])<>1) then
      raise EArgumentException.Create('Нужно независимо сохранённое подтверждение этой группы.');
    for var C in SHA do
      if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then raise EArgumentException.Create('Неверная контрольная сумма подтверждения группы.');
    if FState.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''GroupProof''')<>1 then
      raise EReadError.Create('Нет сохранённого подтверждения подготовленной группы.');
    Q:=FState.NewQuery('SELECT FileKey,SHA256 FROM GroupProof WHERE GroupID=?',[GroupID]); Q.Open;
    if Q.Eof or not SameText(Q.FieldAsString(1),SHA) then raise EReadError.Create('Состояние группы не совпало с независимым подтверждением.');
    var ExpectedKey:=Q.FieldAsString(0); FreeAndNil(Q);
    Result:=ReadGroupProof(TPath.Combine(FDirectory,'prepared-group-'+IntToStr(GroupID)+'.json'),SHA,Key);
    if (Key<>ExpectedKey) or (Result.GetValue<string>('kind')<>'HomeLibre prepared transfer group v1') or
      (Result.GetValue<string>('operation')<>Meta('directory')) or (Result.GetValue<string>('review_sha256')<>FReviewSHA) or
      (Result.GetValue<Int64>('group')<>GroupID) then raise EReadError.Create('Подтверждение относится к другой группе или заменено.');
  except Q.Free; Result.Free; raise; end;
  Q.Free;
end;

function TCollectionTransferJournal.HoldPreparedGroupProof(GroupID:Int64; const SHA:string):TStream;
var Canonical,Identity:string; Bytes:Int64;
begin
  Result:=nil;
  var Data:=ReadPreparedGroupProof(GroupID,SHA); Data.Free;
  var Path:=TPath.Combine(FDirectory,'prepared-group-'+IntToStr(GroupID)+'.json');
  var Stream:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  try
    TransferReadFileState(Path,Canonical,Identity,Bytes);
    if (Canonical<>Path) or (Bytes<=0) or (Bytes>64*1024*1024) or
      (Stream.Size<>Bytes) or (THashSHA2.GetHashString(Stream)<>SHA) or
      (Copy(Identity,1,25)<>FState.QuerySingleString('SELECT FileKey FROM GroupProof WHERE GroupID=?',[GroupID])) then
      raise EReadError.Create('Подтверждение группы изменилось перед освобождением исходников.');
    Result:=Stream; Stream:=nil;
  finally Stream.Free; end;
end;

function TCollectionTransferJournal.RecoverPreparedGroup(GroupID:Int64; const ExpectedProofSHA:string;
  const Cancelled:TFunc<Boolean>):TPreparedTransferGroup;
var Previous:TFunc<Boolean>; Data:TJSONObject; Q:TSQLiteQuery; Job:TCollectionTransferCopy;
  Prepared:TTransferPreparedCopy; IDs:TDictionary<Int64,Boolean>;
begin
  Result:=nil; Previous:=FCancelled; FCancelled:=Cancelled; Data:=nil; Q:=nil; Job:=nil; Prepared:=nil;
  IDs:=TDictionary<Int64,Boolean>.Create;
  try
    CheckStop;
    Data:=ReadPreparedGroupProof(GroupID,ExpectedProofSHA);
    var Files:=Data.GetValue<TJSONArray>('files');
    if (Files=nil) or (Files.Count<>FReview.QuerySingleInt('SELECT count(*) FROM Files WHERE GroupID=?',[GroupID])) then
      raise EReadError.Create('В подтверждении неполная группа файлов.');
    Result:=TPreparedTransferGroup.Create(GroupID);
    try
      for var Value in Files do
      begin
        CheckStop;
        if not (Value is TJSONObject) then raise EReadError.Create('Повреждена запись файла в подтверждении группы.');
        var Row:=TJSONObject(Value); var ID:=Row.GetValue<Int64>('id');
        if IDs.ContainsKey(ID) then raise EReadError.Create('Файл повторяется в подтверждении группы.'); IDs.Add(ID,True);
        Q:=FReview.NewQuery('SELECT Source,Destination,Identity,Bytes,KeepInPlace,ExternalImages FROM Files WHERE ID=? AND GroupID=?',[ID,GroupID]); Q.Open;
        if Q.Eof then raise EReadError.Create('В подтверждении файл другой группы.');
        var Entry:=FileEntry(Q); FreeAndNil(Q);
        var Child:=CheckedProofChild(Row.GetValue<string>('child'));
        Job:=TCollectionTransferCopy.Resume(FCopiesRoot,FDestination,TPath.Combine(FCopiesRoot,Child),Entry);
        var Proof:TTransferDestinationProof;
        Proof.Identity:=Row.GetValue<string>('identity'); Proof.SHA256:=Row.GetValue<string>('sha256'); Proof.StreamsJSON:=Row.GetValue<string>('streams');
        Prepared:=Job.VerifyDestination(Proof,function:Boolean begin CheckStop; Result:=False; end);
        Result.FFiles.Add(ID); Result.FCopies.Add(Prepared); Prepared:=nil; FreeAndNil(Job);
        Point('group-destination-verified',FDirectory,GroupID,ID);
      end;
      var Verified:=ValidateTransferResources(FReview,Result,function:Boolean begin CheckStop; Result:=False; end,False);
      if Verified.SHA256<>Data.GetValue<string>('resources_sha256') then raise EReadError.Create('Восстановленный набор картинок отличается от сохранённого.');
      Point('group-destinations-verified',FDirectory,GroupID,0); CheckStop;
    except Result.Free; Result:=nil; raise; end;
  finally Prepared.Free; Job.Free; Q.Free; Data.Free; IDs.Free; FCancelled:=Previous; end;
end;

procedure TCollectionTransferJournal.CheckPreparedGroupProof(Prepared:TPreparedTransferGroup;
  const SHA:string; const Cancelled:TFunc<Boolean>);
var Previous:TFunc<Boolean>; Data:TJSONObject; Copies:TDictionary<Int64,TTransferPreparedCopy>;
begin
  if Prepared=nil then raise EArgumentException.Create('Не указана проверенная группа.');
  Previous:=FCancelled; FCancelled:=Cancelled; Data:=nil;
  Copies:=TDictionary<Int64,TTransferPreparedCopy>.Create;
  try
    CheckStop; Data:=ReadPreparedGroupProof(Prepared.ID,SHA);
    var Files:=Data.GetValue<TJSONArray>('files');
    if (Files=nil) or (Files.Count<>Prepared.Count) or
      (Files.Count<>FReview.QuerySingleInt('SELECT count(*) FROM Files WHERE GroupID=?',[Prepared.ID])) then
      raise EReadError.Create('Неполная группа в независимом подтверждении.');
    for var I:=0 to Prepared.Count-1 do Copies.Add(Prepared.FileID(I),Prepared.CopyAt(I));
    for var Value in Files do
    begin
      CheckStop;
      if not (Value is TJSONObject) then raise EReadError.Create('Повреждено подтверждение файла группы.');
      var Row:=TJSONObject(Value); var ID:=Row.GetValue<Int64>('id'); var Item:TTransferPreparedCopy;
      if not Copies.TryGetValue(ID,Item) or (Item.Identity<>Row.GetValue<string>('identity')) or
        (Item.SHA256<>Row.GetValue<string>('sha256')) or (Item.StreamsJSON<>Row.GetValue<string>('streams')) then
        raise EReadError.Create('Группа не совпала с независимо сохранёнными файлами.');
      Copies.Remove(ID);
    end;
    if Copies.Count<>0 then raise EReadError.Create('В подтверждении повторяются файлы группы.');
    var Verified:=ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end,False);
    if Verified.SHA256<>Data.GetValue<string>('resources_sha256') then raise EReadError.Create('Внешние картинки не совпали с подтверждением группы.');
  finally Copies.Free; Data.Free; FCancelled:=Previous; end;
end;

function TCollectionTransferJournal.VerifyPublishedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>):Int64;
var Previous:TFunc<Boolean>;
begin
  if (Prepared=nil) or (Prepared.Count=0) then raise EArgumentException.Create('Не указана полная группа переноса.');
  Previous:=FCancelled; FCancelled:=Cancelled;
  try
    try
    ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end,False);
    OpenPublicationSession;
    Result:=TTransferPublicationSession(FPublicationSession).VerifyPublished(Prepared,
      function:Boolean begin CheckStop; Result:=False; end,
      procedure(Stage:string) begin Point(Stage,FDirectory,Prepared.ID,0); end);
    except FreeAndNil(FPublicationSession); raise; end;
  finally FCancelled:=Previous; end;
end;

procedure TCollectionTransferJournal.RemovePublishedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const RegistryCheck:TProc<TSQLiteDatabase>;
  const SaveIntent,RemoveSources:TProc<TSQLiteDatabase,TArray<Int64>>);
var Previous:TFunc<Boolean>;
begin
  if (Prepared=nil) or (Prepared.Count=0) then raise EArgumentException.Create('Нужна полная группа освобождения исходников.');
  Previous:=FCancelled; FCancelled:=Cancelled;
  try
    try
      ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end,False);
      OpenPublicationSession;
      TTransferPublicationSession(FPublicationSession).RemovePublished(Prepared,
        function:Boolean begin CheckStop; Result:=False; end,
        procedure(Stage:string) begin Point(Stage,FDirectory,Prepared.ID,0); end,
        RegistryCheck,SaveIntent,RemoveSources);
    except FreeAndNil(FPublicationSession); raise; end;
  finally FCancelled:=Previous; end;
end;

function TCollectionTransferJournal.ResourceValidationCount:Integer;
begin
  Result:=0;
  if FState.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''ResourceValidation''')<>0 then
    Result:=FState.QuerySingleInt('SELECT count(*) FROM ResourceValidation WHERE ReviewSHA256=?',[FReviewSHA]);
end;

procedure TCollectionTransferJournal.VerifyGroupResources(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>);
var Previous:TFunc<Boolean>; Q:TSQLiteQuery;
begin
  if Prepared=nil then raise EArgumentException.Create('Не указана группа проверки ресурсов.');
  Previous:=FCancelled; FCancelled:=Cancelled; Q:=nil;
  try
    CheckStop; Point('resources-before-validation',FDirectory,Prepared.ID,0); CheckStop;
    CheckRoots; CheckNegativePaths; CheckGroupImages(Prepared.ID);
    var Verified:=ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end);
    FState.ExecSQL('CREATE TABLE IF NOT EXISTS ResourceValidation(GroupID INTEGER PRIMARY KEY,Kind TEXT NOT NULL,'+
      'ReviewSHA256 TEXT NOT NULL,ResourcesSHA256 TEXT NOT NULL,Files INTEGER NOT NULL,ImageSets INTEGER NOT NULL,Resources INTEGER NOT NULL)');
    FState.ExecSQL('BEGIN');
    try
      Q:=FState.NewQuery('SELECT Kind,ReviewSHA256,ResourcesSHA256,Files,ImageSets,Resources FROM ResourceValidation WHERE GroupID=?',[Prepared.ID]); Q.Open;
      if not Q.Eof and ((Q.FieldAsString(0)<>'resources v1') or (Q.FieldAsString(1)<>FReviewSHA) or
        (Q.FieldAsString(2)<>Verified.SHA256) or (Q.FieldAsInt(3)<>Verified.Files) or
        (Q.FieldAsInt(4)<>Verified.ImageSets) or (Q.FieldAsInt(5)<>Verified.Resources)) then
        raise EReadError.Create('Квитанция проверки ресурсов изменилась. Исходники сохранены.');
      FreeAndNil(Q);
      FState.ExecSQL('INSERT OR IGNORE INTO ResourceValidation VALUES(?,''resources v1'',?,?,?,?,?)',
        [Prepared.ID,FReviewSHA,Verified.SHA256,Verified.Files,Verified.ImageSets,Verified.Resources]);
      Point('resources-before-commit',FDirectory,Prepared.ID,0); CheckStop;
      FState.ExecSQL('COMMIT'); Point('resources-after-commit',FDirectory,Prepared.ID,0);
    except if FState.InTransaction then FState.Rollback; raise; end;
  finally Q.Free; FCancelled:=Previous; end;
end;

procedure TCollectionTransferJournal.OpenPublicationSession;
begin
    if FPublicationSession=nil then
      FPublicationSession:=TTransferPublicationSession.Create(FReview,Meta('personal'),FWorkRoot,Meta('directory'),FReviewSHA,
        function(CID:Integer):string begin Result:=EffectiveCatalogue(CID); end,
        procedure(Targets:TSQLiteDatabase)
        begin
          // Saved identities are used only to discover already-published rows.
          // Each group still requires its complete verified prepared leases and
          // exact native old/new row projection before a location can commit.
          var Q:=FState.NewQuery('SELECT FileID,Identity FROM FileState WHERE State=''prepared'' AND length(Identity)=59');
          try
            Q.Open;
            while not Q.Eof do
            begin
              CheckStop;
              Targets.ExecSQL('INSERT OR IGNORE INTO ReferenceTargets VALUES(?,?)',[Copy(Q.FieldAsString(1),1,25),Q.FieldAsInt(0)]);
              Q.Next;
            end;
          finally Q.Free; end;
        end);
end;

procedure TCollectionTransferJournal.PublishGroupLocations(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>;
  const PersonalChanges:TProc<TSQLiteDatabase>);
begin
  if (Prepared=nil) or (Prepared.Count=0) or
    (FReview.QuerySingleInt('SELECT count(*) FROM Files WHERE GroupID=?',[Prepared.ID])<>Prepared.Count) then
    raise EArgumentException.Create('Для адресов нужна полная проверенная группа.');
  PublishCatalogueForks(Cancelled); FCancelled:=Cancelled;
  try
    CheckStop; CheckRoots; CheckNegativePaths; CheckGroupImages(Prepared.ID);
    VerifyGroupResources(Prepared,Cancelled);
    OpenPublicationSession;
    try
      TTransferPublicationSession(FPublicationSession).Publish(Prepared,
        function:Boolean begin CheckStop; Result:=False; end,
        procedure(Stage:string) begin Point(Stage,FDirectory,Prepared.ID,0); end,PersonalChanges);
    except FreeAndNil(FPublicationSession); raise; end;
  finally FCancelled:=nil; end;
end;

procedure TCollectionTransferJournal.ReconcileGroupLocations(Prepared:TPreparedTransferGroup; const ProofSHA:string;
  const Cancelled:TFunc<Boolean>; const PersonalCheck:TProc<TSQLiteDatabase>);
var Previous:TFunc<Boolean>; Proof:TStream;
begin
  if not Assigned(PersonalCheck) then raise EArgumentException.Create('Нужна проверка независимого подтверждения публикации.');
  CheckPreparedGroupProof(Prepared,ProofSHA,Cancelled);
  Proof:=HoldPreparedGroupProof(Prepared.ID,ProofSHA); Previous:=FCancelled; FCancelled:=Cancelled;
  try
    CheckStop; ValidateTransferResources(FReview,Prepared,function:Boolean begin CheckStop; Result:=False; end,False);
    OpenPublicationSession;
    try
      TTransferPublicationSession(FPublicationSession).Publish(Prepared,
        function:Boolean begin CheckStop; Result:=False; end,
        procedure(Stage:string) begin Point(Stage,FDirectory,Prepared.ID,0); end,PersonalCheck,True);
    except FreeAndNil(FPublicationSession); raise; end;
  finally FCancelled:=Previous; Proof.Free; end;
end;

procedure TCollectionTransferJournal.EnsureFinalRootDirectory;
begin
  CheckStop;
  var Layout:=TCollectionTransferLayout.Create(FReview);
  try
    var Root:=IncludeTrailingPathDelimiter(FDestination);
    var Target:=Layout.RootDestination('collection');
    if not Target.StartsWith(Root,True) then raise EReadError.Create('Итоговый корень выходит из папки назначения.');
    var Relative:=Copy(Target,Length(Root)+1,MaxInt); var Current:=Root;
    PinDirectory(Current);
    for var Part in Relative.Split(['\'],TStringSplitOptions.ExcludeEmpty) do
    begin
      CheckStop;
      if (Part='.') or (Part='..') then raise EReadError.Create('Неверная часть итогового корня.');
      Current:=TPath.Combine(Current,Part);
      if GetFileAttributes(PChar(DeletionNativePath(Current)))=INVALID_FILE_ATTRIBUTES then
      begin
        var Code:=GetLastError;
        if not (Code in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Code);
        if not CreateDirectory(PChar(DeletionNativePath(Current)),nil) then RaiseLastOSError;
      end;
      PinDirectory(Current);
    end;
  finally Layout.Free; end;
end;

function TCollectionTransferJournal.HasCachePreparation:Boolean;
begin Result:=TCollectionTransferCachePreparation.HasIntent(Self); end;

function TCollectionTransferJournal.PrepareSourceCaches(const Cancelled:TFunc<Boolean>):Int64;
begin
  var RootsApplied:=False;
  if HasRootFinalization then RootsApplied:=FinalizeRoots(Cancelled);
  OpenPublicationSession;
  var Handler:=TCollectionTransferCachePreparation.Create(Self,TTransferPublicationSession(FPublicationSession),RootsApplied);
  try Result:=Handler.Prepare(Cancelled); finally Handler.Free; end;
end;

function TCollectionTransferJournal.InstallSourceCacheVersions(const Cancelled:TFunc<Boolean>):Int64;
begin
  if not HasRootFinalization or not HasCachePreparation then raise EReadError.Create('Нет подготовленного завершения для установки кэша.');
  var RootsApplied:=FinalizeRoots(Cancelled); OpenPublicationSession;
  var Handler:=TCollectionTransferCachePreparation.Create(Self,TTransferPublicationSession(FPublicationSession),RootsApplied);
  try Result:=Handler.Prepare(Cancelled,True); finally Handler.Free; end;
end;

function TCollectionTransferJournal.HasRootFinalization:Boolean;
begin Result:=TCollectionTransferFinalization.HasIntent(Self); end;

function TCollectionTransferJournal.FinalizeRoots(const Cancelled:TFunc<Boolean>):Boolean;
begin
  OpenPublicationSession;
  var Handler:=TCollectionTransferFinalization.Create(Self,TTransferPublicationSession(FPublicationSession));
  try Result:=Handler.ApplyRoots(Cancelled);
  finally Handler.Free; end;
end;

end.
