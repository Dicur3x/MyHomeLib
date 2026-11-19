unit unit_LibraryUpdateReview;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Interfaces, unit_Globals,
  unit_CatalogSources, unit_LibraryUpdateSources, unit_LibraryUpdateFetch,
  unit_CollectionWorkerThread, unit_CollectionMerge, unit_LibraryUpdateInventory,
  unit_CollectionPacking, unit_LibraryUpdateContinuation;

type
  TLibraryReviewProgress = reference to procedure(const Stage: string; Done, Total: Integer);
  TLibraryUpdateReview = class
  private
    FSource: TLibraryUpdateSource;
    FProfiles: TLibraryUpdateSources;
    FPrepared: TStagedLibraryIndex; // Borrowed; the window releases the review first.
    FSnapshot: IBookCollection;
    FSourceInfo: TCatalogSource;
    FDatabaseFile, FAnalysisFile, FTargetRevision, FTargetFile, FOriginalTargetRoot, FSummary: string;
    FNeeded, FHistorical, FFound, FAmbiguous: TStringList;
    FNewBooks, FChangedBooks, FTotal, FVersion, FDeleted, FSkipped: Integer;
    FPreviousIndex, FReady, FOriginalRootOffline, FIsMetabib: Boolean;
    FDelta: IBookCollection;
    FDeltaFile, FApplySummary, FCacheInput, FPreviousFile, FOperationID: string;
    FPreviousInput, FPreviousInputSHA, FPublisherFile, FSelectedPreviousFile: string;
    FSelectedPreviousIndex:TStagedLibraryIndex;
    FPreviousRevisionDB:TSQLiteDatabase;
    FPreviousRevision:Integer;
    FRestartProof:TLibraryUpdateRestartRequest;
    FPendingRestart:ILibraryUpdateRestart;
    FMissingComponents:TArray<string>;
    FPlan: TCollectionMergePlan;
    FActionDB: TSQLiteDatabase;
    FRevisionDB: TSQLiteDatabase;
    FActionLookup: TSQLiteQuery;
    FInventory: TLibraryUpdateInventory;
    FPublishedSource: TCatalogSource;
    FCacheOwned, FCachePublished, FApplicationReady, FApplied, FIssuesReady, FRecoveryPending: Boolean;
    FRecoveryError: string;
    FRemovedCount, FMissingCount, FNewCards, FUpdateCards, FPreviousLastID, FUnlistedCount: Integer;
    FLastSpaceCheck: UInt64;
    FPacked, FLegacyPackedBaseline: Boolean;
    FPreviousRoot: string;
    FPublishedCollectionID: Integer;
    function ImportSelectedPreviousIndex(const OriginalRoot: string; const Target: IBookCollection;
      const SystemData: ISystemData; const Check: TProc; const Progress: TLibraryReviewProgress): IBookCollection;
    function PackedOptions(const Target:IBookCollection):TCollectionPackingOptions;
    procedure PrepareModuleRestart(const Target:IBookCollection; PreferNewRoot:Boolean;
      const Check:TProc; const Progress:TLibraryReviewProgress);
    procedure PreparePackedApplication(PreferNewRoot: Boolean; const Check: TProc;
      const Progress: TLibraryReviewProgress);
    procedure ApplyPacked(const Target: IBookCollection; const SystemData: ISystemData;
      const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure EditPackedSnapshot(const CatalogFile, PersonalFile: string; Info: TCollectionInfo;
      const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure SeedPackedCache(const SystemData: ISystemData; const Check: TProc);
    function OpenWorkDatabase(const FileName:string; ReadOnly:Boolean=False):TSQLiteDatabase;
    procedure Analyze(const Target, Previous: IBookCollection; const SystemData:ISystemData; const Check: TProc;
      const Progress: TLibraryReviewProgress);
    procedure PrepareApplication(const Target: IBookCollection; const SystemData: ISystemData;
      PreferNewRoot: Boolean; const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure PrepareCache(const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure StoreAppliedState(const Target: IBookCollection);
    procedure RestoreCopySizes(const Collection: IBookCollection; const SystemData:ISystemData; const Check: TProc);
    function BuildBoundPlan(const Target: IBookCollection; const SystemData: ISystemData): TCollectionMergePlan;
    procedure Apply(const Target: IBookCollection; const SystemData: ISystemData;
      const Check: TProc; const Progress: TLibraryReviewProgress; out Committed: Boolean);
    procedure CleanCache;
    procedure CheckTargetRevision(const Target: IBookCollection);
  public
    constructor Create(const Source: TLibraryUpdateSource; Prepared: TStagedLibraryIndex);
    destructor Destroy; override;
    procedure CheckSpace;
    procedure SetSourceProfiles(const Profiles: TLibraryUpdateSources);
    procedure RestoreRestartProof(const Proof:TLibraryUpdateRestartRequest; var Previous:TStagedLibraryIndex);
    function MissingDetails(Maximum: Integer = 5): string;
    procedure SaveMissingReport(const FileName: string);
    procedure Build(const Target: IBookCollection; const SystemData: ISystemData;
      const Import: TProc<IBookCollection>; const Check: TProc;
      const Progress: TLibraryReviewProgress);
    property Summary: string read FSummary;
    property NeededArchives: TStringList read FNeeded;
    property HistoricalMissing: TStringList read FHistorical;
    property FoundArchives: TStringList read FFound;
    property AmbiguousArchives: TStringList read FAmbiguous;
    property NewBooks: Integer read FNewBooks;
    property ChangedBooks: Integer read FChangedBooks;
    property Total: Integer read FTotal;
    property DeletedRecords: Integer read FDeleted;
    property SkippedRecords: Integer read FSkipped;
    property Ready: Boolean read FReady;
    property PreviousIndex: Boolean read FPreviousIndex;
    property Snapshot: IBookCollection read FSnapshot;
    property ApplySummary: string read FApplySummary;
    property Applied: Boolean read FApplied;
    property PublishedCollectionID: Integer read FPublishedCollectionID;
    property OperationID: string read FOperationID;
    property RecoveryPending: Boolean read FRecoveryPending;
    property RecoveryError: string read FRecoveryError;
    property MissingReportReady: Boolean read FIssuesReady;
    property MissingBooks: Integer read FMissingCount;
    property PendingRestart:ILibraryUpdateRestart read FPendingRestart;
    property MissingComponents:TArray<string> read FMissingComponents;
  end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;
function CreateLibraryApplyWorker(CollectionID: Integer; Review: TLibraryUpdateReview;
  PreferNewRoot: Boolean; AllowModuleRestart:Boolean=False): TCollectionWorker;

{$IFDEF MHL_COMPRESSION_TEST}
var LibraryUpdateTestPoint: TProc<string>;
var LibraryUpdateTestDatabase: TProc<TSQLiteDatabase>;
{$ENDIF}

implementation

uses Winapi.Windows, Vcl.ComCtrls, System.IOUtils, System.Hash, System.Variants, System.JSON, System.StrUtils, System.Math,
  unit_Consts, unit_Database_SQLite, unit_LibrarySourceID, unit_UserData,
  unit_ImportInpxThread, unit_ImportMetabibThread, unit_MetabibReader, unit_LibraryUpdateIdentity,
  unit_MHLArchiveHelpers, unit_Settings, unit_LibraryUpdateHistory,
  unit_CollectionPackingPublisher, unit_LibraryUpdateJournal, unit_SystemDatabase_SQLite,
  unit_CatalogContentDigest, dm_user;

procedure NotifyLibraryUpdateTestPoint(const Stage: string); inline;
begin
{$IFDEF MHL_COMPRESSION_TEST}
  if Assigned(LibraryUpdateTestPoint) then LibraryUpdateTestPoint(Stage);
{$ENDIF}
end;

constructor TLibraryUpdateReview.Create(const Source: TLibraryUpdateSource; Prepared: TStagedLibraryIndex);
begin
  inherited Create; Source.Validate;
  if not Assigned(Prepared) then raise EArgumentNilException.Create('Prepared');
  FSource:=Source; FPrepared:=Prepared;
  FIsMetabib:=TMetabibReader.IsDatasetFile(FPrepared.FileName);
  if FIsMetabib then FSource.Full:=True;
  FNeeded:=TStringList.Create; FHistorical:=TStringList.Create;
  FFound:=TStringList.Create; FAmbiguous:=TStringList.Create;
end;

function TLibraryUpdateReview.OpenWorkDatabase(const FileName:string; ReadOnly:Boolean):TSQLiteDatabase;
begin
  if ReadOnly then Result:=TSQLiteDatabase.CreateReadOnly(FileName,FPrepared.Folder)
  else Result:=TSQLiteDatabase.Create(FileName,True,False,FPrepared.Folder);
  try
    Result.ExecSQL('PRAGMA temp_store=FILE');
{$IFDEF MHL_COMPRESSION_TEST}
    if Assigned(LibraryUpdateTestDatabase) then LibraryUpdateTestDatabase(Result);
{$ENDIF}
  except Result.Free; raise; end;
end;

procedure TLibraryUpdateReview.SetSourceProfiles(const Profiles: TLibraryUpdateSources);
begin WriteLibraryUpdateSources(Profiles); FProfiles:=Copy(Profiles); end;

destructor TLibraryUpdateReview.Destroy;
begin
  FPlan.Free; FActionLookup.Free; FActionDB.Free; FInventory.Free; FRevisionDB.Free;
  FPreviousRevisionDB.Free; FSelectedPreviousIndex.Free;
  FDelta:=nil; FSnapshot:=nil; CleanCache;
  // Only files explicitly created by this review; never recursive cleanup.
  for var Name in TArray<string>.Create(FDatabaseFile,FAnalysisFile,FDeltaFile,FPublisherFile,FSelectedPreviousFile) do
    if Name<>'' then
      for var Suffix in TArray<string>.Create('','-wal','-shm','-journal') do
        if FileExists(Name+Suffix) then
          try TFile.Delete(Name+Suffix); except end;
  FNeeded.Free; FHistorical.Free; FFound.Free; FAmbiguous.Free;
  inherited;
end;

procedure TLibraryUpdateReview.RestoreRestartProof(const Proof:TLibraryUpdateRestartRequest;
  var Previous:TStagedLibraryIndex);
begin
  FRestartProof:=Proof;
  FSelectedPreviousIndex:=Previous;
  Previous:=nil;
end;

procedure TLibraryUpdateReview.CheckSpace;
var Available, Capacity: UInt64;
begin
  if (FLastSpaceCheck<>0) and (GetTickCount64-FLastSpaceCheck<1000) then Exit;
  if not GetDiskFreeSpaceEx(PChar(GetEnvironmentVariable('SystemDrive')+'\'),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then
    raise EWriteError.Create('На системном диске осталось меньше 8 ГБ. Проверка обновления остановлена.');
  if not GetDiskFreeSpaceEx(PChar(FPrepared.Folder),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(512)*1024*1024 then
    raise EWriteError.Create('Недостаточно места для проверки индекса. Текущая коллекция не изменена.');
  if FTargetFile<>'' then
  begin
    if not GetDiskFreeSpaceEx(PChar(TPath.GetDirectoryName(FTargetFile)),Available,Capacity,nil) then RaiseLastOSError;
    if Available<UInt64(512)*1024*1024 then raise EWriteError.Create('Недостаточно места на диске каталога. Обновление остановлено.');
  end;
  FLastSpaceCheck:=GetTickCount64;
end;

procedure TLibraryUpdateReview.CheckTargetRevision(const Target: IBookCollection);
begin
  if not SameFileName(Settings.ExpandCollectionFileName(VarToStr(Target.GetProperty(PROP_DATAFILE))),FTargetFile) or
    not SameFileName(IncludeTrailingPathDelimiter(TPath.GetFullPath(Target.CollectionRoot)),
      IncludeTrailingPathDelimiter(TPath.GetFullPath(FOriginalTargetRoot))) then
    raise EReadError.Create('Файл или папка коллекции изменились. Проверьте обновление заново.');
  // SQLite data_version is connection-local. Keep one read-only observer
  // across the separate review/apply workers rather than compare two handles.
  if not Assigned(FRevisionDB) or
    (IntToStr(FRevisionDB.QuerySingleInt('PRAGMA data_version'))<>FTargetRevision) then
    raise EReadError.Create('Коллекция изменилась после проверки. Проверьте обновление заново.');
end;

procedure TLibraryUpdateReview.Build(const Target: IBookCollection; const SystemData: ISystemData;
  const Import: TProc<IBookCollection>; const Check: TProc; const Progress: TLibraryReviewProgress);
var Previous: IBookCollection; PreviousInfo: TCatalogSource; Found: Boolean; Namespace, SnapshotFile: string;
begin
  FReady:=False; CheckSpace; Check;
  FTargetFile:=Settings.ExpandCollectionFileName(VarToStr(Target.GetProperty(PROP_DATAFILE)));
  FOriginalTargetRoot:=Target.CollectionRoot;
  FPacked:=IsPackedCollectionCatalog(FTargetFile);
  FreeAndNil(FRevisionDB); FRevisionDB:=OpenWorkDatabase(FTargetFile,True);
  FTargetRevision:=IntToStr(FRevisionDB.QuerySingleInt('PRAGMA data_version'));
  if FRestartProof.CatalogDigest<>'' then
  begin
    FRestartProof.Identity.CheckIdentity(FTargetFile,FOriginalTargetRoot,Target.CollectionID);
    if Assigned(Progress) then Progress('Сверка каталога после установки',0,0);
    if not FPacked or not SameText(CatalogContentDigest(FRevisionDB,Check),FRestartProof.CatalogDigest) then
      raise EReadError.Create('После перезапуска каталог изменился. Проверьте обновление заново.');
  end;
  FSourceInfo.ID:=FSource.ID; FSourceInfo.Name:=FSource.Name;
  FSourceInfo.Root:=Target.CollectionRoot;
  FSourceInfo.LibraryNamespace:=VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY));
  if FSource.CatalogSourceID<>'' then
  begin
    Found:=False;
    for var Item in LoadCatalogSources(Target) do
      if SameText(Item.ID,FSource.CatalogSourceID) then
      begin FSourceInfo:=Item; Found:=True; Break; end;
    if not Found then raise EArgumentException.Create('Привязанный источник больше не подключён к этой коллекции.');
  end;
  if (FSource.BooksRoot<>'') and not DirectoryExists(FSource.BooksRoot) then
    raise EDirectoryNotFoundException.Create('Папка докачанных архивов недоступна: '+FSource.BooksRoot);
  FOriginalRootOffline:=not DirectoryExists(FSourceInfo.Root);
  if FOriginalRootOffline and (FSource.BooksRoot='') then
    raise EDirectoryNotFoundException.Create('Исходная папка книг недоступна: '+FSourceInfo.Root+
      '. Укажите доступную папку докачанных архивов в настройке источника.');
  Previous:=Target; FPreviousIndex:=False; FPreviousInput:=''; FPreviousInputSHA:='';
  if LoadLibraryUpdateHistory(Target,FSource,PreviousInfo,FPreviousInputSHA) then
  begin
    // Losing the authoritative baseline also loses exclusions and append
    // history. Falling back silently could resurrect deliberately removed books.
    if not FileExists(PreviousInfo.CacheFile) then
      raise EReadError.Create('Сохранённый индекс обновления недоступен: '+PreviousInfo.CacheFile+
        '. Восстановите служебный каталог источника перед повторной проверкой.');
    Previous:=OpenCatalogSnapshot(PreviousInfo,PreviousInfo.CacheFile,SystemData,FPrepared.Folder); FPreviousIndex:=True;
    FPreviousInput:=PreviousInfo.INPXFile;
  end
  else if (FSource.CatalogSourceID<>'') and FSourceInfo.IsINPX and FileExists(FSourceInfo.CacheFile) then
  begin Previous:=OpenCatalogSnapshot(FSourceInfo,FSourceInfo.CacheFile,SystemData,FPrepared.Folder); FPreviousIndex:=True; end;
  if (FSource.CatalogSourceID<>'') and not FSourceInfo.IsINPX then
  begin Previous:=OpenCatalogSource(FSourceInfo,SystemData); FPreviousIndex:=True; end;
  if not FPreviousIndex and FPacked and (FSource.CatalogSourceID='') and (FSource.PreviousIndexFile<>'') then
  begin
    var OriginalRoot:=LegacyPackingSourceRoot(FRevisionDB);
    if OriginalRoot<>'' then
    begin
      Previous:=ImportSelectedPreviousIndex(OriginalRoot,Target,SystemData,Check,Progress);
      FPreviousIndex:=True;
    end;
  end;
  if FPreviousIndex then
  begin
    FPreviousFile:=VarToStr(Previous.GetProperty(PROP_DATAFILE));
    FPreviousRoot:=Previous.CollectionRoot;
    if FPacked and not Assigned(FSelectedPreviousIndex) then
    begin
      FreeAndNil(FPreviousRevisionDB);
      FPreviousRevisionDB:=OpenWorkDatabase(FPreviousFile,True);
      FPreviousRevision:=FPreviousRevisionDB.QuerySingleInt('PRAGMA data_version');
    end;
  end;
  if FRestartProof.PreviousDigest<>'' then
  begin
    if Assigned(Progress) then Progress('Сверка прежнего индекса после установки',0,0);
    if not Assigned(FPreviousRevisionDB) or
      not SameText(CatalogContentDigest(FPreviousRevisionDB,Check),FRestartProof.PreviousDigest) then
      raise EReadError.Create('После перезапуска прежний индекс изменился. Проверьте обновление заново.');
  end;
  SnapshotFile:=TPath.Combine(FPrepared.Folder,'review-'+TGUID.NewGuid.ToString+'.hlc2');
  if FileExists(SnapshotFile) then raise EWriteError.Create('Рабочий файл проверки уже существует.');
  FDatabaseFile:=SnapshotFile;
  TBookCollection_SQLite.CreateCollection(SystemData,FDatabaseFile,CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2],FPrepared.Folder);
  FSnapshot:=OpenCatalogSnapshot(FSourceInfo,FDatabaseFile,SystemData,FPrepared.Folder);
  FSnapshot.BeginBulkOperation;
  try
    Namespace:=FSourceInfo.LibraryNamespace;
    if Namespace<>'' then FSnapshot.SetProperty(PROP_SOURCE_LIBRARY,Namespace);
    if FSource.CatalogSourceID='' then
      FSnapshot.SetProperty(PROP_MIXED_LIBRARY_IDS,Target.GetProperty(PROP_MIXED_LIBRARY_IDS));
    Import(FSnapshot); Check;
    FSnapshot.EndBulkOperation(True);
  except
    if FSnapshot.InBulkOperation then FSnapshot.EndBulkOperation(False);
    raise;
  end;
  FVersion:=StrToIntDef(VarToStr(FSnapshot.GetProperty(PROP_DATAVERSION)),0);
  if FSourceInfo.LibraryNamespace='' then
    FSourceInfo.LibraryNamespace:=VarToStr(FSnapshot.GetProperty(PROP_SOURCE_LIBRARY));
  Analyze(Target,Previous,SystemData,Check,Progress);
  Check;
  CheckTargetRevision(Target);
  FReady:=True;
end;

function ReviewBookKey(const Book:TBookRecord; const Namespace,Root:string):string;
begin Result:=LibraryUpdateBookKey(Book,Namespace,Root); end;

function ReviewStamp(const Book: TBookRecord): string;
begin
  Result:=THashSHA2.GetHashString(Book.Title+#1+Book.Lang+#1+IntToStr(Book.Size)+#1+
    FloatToStr(Book.Date,TFormatSettings.Invariant)+#1+IntToStr(Ord(bpIsDeleted in Book.BookProps)));
end;

function ReviewLocation(const Book: TBookRecord): string;
begin
  if IsArchiveExt(Book.Folder) then Result:=Book.Folder
  else Result:=TPath.Combine(Book.Folder,Book.FileName)+Book.FileExt;
end;

function PublisherLocation(const Book:TBookRecord):string;
begin Result:=LibraryPublisherLocation(Book); end;

function LegacyPublisherLocation(const Book:TBookRecord):string;
begin Result:=LibraryLegacyPublisherLocation(Book); end;

function ReviewContainer(const Book: TBookRecord; const DownloadRoot: string;
  Cache: TDictionary<string,string>): string;
var Key, Candidate: string; Item: TBookRecord; Archived: Boolean;
begin
  Archived:=IsArchiveExt(Book.Folder);
  Key:=LowerCase(Book.CollectionRoot+#1+Book.Folder+#1+DownloadRoot);
  if Archived and Cache.TryGetValue(Key,Result) then Exit;
  Result:=Book.GetBookContainer;
  if (DownloadRoot<>'') and not TPath.IsPathRooted(Book.Folder) and not FileExists(Book.GetBookFileName(Result)) then
  begin
    Item:=Book; Item.CollectionRoot:=IncludeTrailingPathDelimiter(DownloadRoot);
    Candidate:=Item.GetBookContainer;
    if FileExists(Item.GetBookFileName(Candidate)) then Result:=Candidate;
  end;
  if Archived then Cache.AddOrSetValue(Key,Result);
end;

type
  TPreviousInpxWorker=class(TImportInpxThreadBase)
    Input:string; Scratch:IBookCollection; Check:TProc;
    Cancellation:TSQLiteCancelCallback;
    procedure WorkFunction; override;
  end;
  TPreviousMetabibWorker=class(TImportMetabibThreadBase)
    Input:string; Scratch:IBookCollection; Check:TProc;
    Cancellation:TSQLiteCancelCallback;
    procedure WorkFunction; override;
  end;

procedure TPreviousInpxWorker.WorkFunction;
var Saved:TSQLiteCancelCallback;
begin
  Saved:=SQLiteCancelCallback; SQLiteCancelCallback:=Cancellation;
  try
  FGenresType:=gtFb2; FKeepCollectionProps:=True; FKeepIndexArchiveNames:=True; FImportCheck:=Check;
  Scratch.BeginBulkOperation;
  try Import(Input,False,Scratch); Check; Scratch.EndBulkOperation(True);
  except SQLiteCancelCallback:=nil; if Scratch.InBulkOperation then Scratch.EndBulkOperation(False); raise; end;
  FOperationSuccess:=True;
  finally SQLiteCancelCallback:=Saved; end;
end;

function TLibraryUpdateReview.ImportSelectedPreviousIndex(const OriginalRoot: string;
  const Target: IBookCollection; const SystemData: ISystemData; const Check: TProc;
  const Progress: TLibraryReviewProgress): IBookCollection;
var LocalSource:TLibraryUpdateSource; Info:TCatalogSource;
  Worker:TPreviousInpxWorker; ExpectedVersion,ActualVersion:Integer; LastUpdate:UInt64;
begin
  LocalSource:=TLibraryUpdateSource.NewSource;
  LocalSource.Name:='Прежний INPX';
  LocalSource.Location:=TPath.GetDirectoryName(FSource.PreviousIndexFile);
  LocalSource.IndexFile:=TPath.GetFileName(FSource.PreviousIndexFile);
  LastUpdate:=0;
  if not Assigned(FSelectedPreviousIndex) then
    FSelectedPreviousIndex:=TStagedLibraryIndex.Fetch(LocalSource,FPrepared.Folder,nil,Check,
    procedure(Done,Total:Int64)
    begin
      if Assigned(Progress) and ((GetTickCount64-LastUpdate>=200) or (Done=Total)) then
      begin
        LastUpdate:=GetTickCount64;
        Progress('Копирование прежнего INPX',Integer(Done),Integer(Total));
      end;
    end);
  FSelectedPreviousFile:=TPath.Combine(FPrepared.Folder,'previous-'+TGUID.NewGuid.ToString+'.hlc2');
  TBookCollection_SQLite.CreateCollection(SystemData,FSelectedPreviousFile,CT_EXTERNAL_LOCAL_FB,
    Settings.SystemFileName[sfGenresFB2],FPrepared.Folder);
  Info:=FSourceInfo;
  Info.Root:=OriginalRoot;
  Result:=OpenCatalogSnapshot(Info,FSelectedPreviousFile,SystemData,FPrepared.Folder);
  if Info.LibraryNamespace<>'' then Result.SetProperty(PROP_SOURCE_LIBRARY,Info.LibraryNamespace);
  Result.SetProperty(PROP_MIXED_LIBRARY_IDS,Target.GetProperty(PROP_MIXED_LIBRARY_IDS));
  if Assigned(Progress) then Progress('Чтение прежнего INPX',0,0);
  Worker:=TPreviousInpxWorker.Create(MHL_INVALID_ID);
  try
    Worker.Input:=FSelectedPreviousIndex.FileName;
    Worker.Scratch:=Result;
    Worker.Check:=procedure begin Check; CheckSpace; end;
    Worker.Cancellation:=SQLiteCancelCallback;
    Worker.Start;
    Worker.WaitFor;
    if Worker.FatalException is EAbort then
      raise EAbort.Create(Exception(Worker.FatalException).Message);
    if Assigned(Worker.FatalException) then
      raise EReadError.Create('Не удалось прочитать прежний INPX: '+Exception(Worker.FatalException).Message);
    if not Worker.Success then raise EReadError.Create('Не удалось прочитать прежний INPX.');
  finally Worker.Free; end;
  ExpectedVersion:=StrToIntDef(VarToStr(Target.GetProperty(PROP_DATAVERSION)),0);
  ActualVersion:=StrToIntDef(VarToStr(Result.GetProperty(PROP_DATAVERSION)),0);
  if (ExpectedVersion>0) and (ActualVersion<>ExpectedVersion) then
    raise EReadError.CreateFmt('Версия прежнего INPX (%d) не совпадает с версией сжатой коллекции (%d).',
      [ActualVersion,ExpectedVersion]);
end;

procedure TPreviousMetabibWorker.WorkFunction;
var Saved:TSQLiteCancelCallback;
begin
  Saved:=SQLiteCancelCallback; SQLiteCancelCallback:=Cancellation;
  try
  FGenresType:=gtFb2; FImportCheck:=Check;
  Scratch.BeginBulkOperation;
  try Import(Input,False,Scratch); Check; Scratch.EndBulkOperation(True);
  except SQLiteCancelCallback:=nil; if Scratch.InBulkOperation then Scratch.EndBulkOperation(False); raise; end;
  FOperationSuccess:=True;
  finally SQLiteCancelCallback:=Saved; end;
end;

function PublisherRecoveryKey(Book:TBookRecord; const Namespace,Root:string):string;
begin
  // Missing library IDs can still be recovered when the complete input has
  // one unique artifact. Duplicate locators are explicitly marked ambiguous.
  Book.Folder:=''; Result:=ReviewBookKey(Book,Namespace,Root);
end;

function ExternalPublisherLocator(const Folder,Root:string):Boolean;
var Relative:string;
begin
  Result:=False;
  if not IsArchiveExt(Folder) or not TPath.IsPathRooted(Folder) then Exit;
  Relative:=ExtractRelativePath(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),TPath.GetFullPath(Folder));
  Result:=TPath.IsPathRooted(Relative) or (Relative='..') or Relative.StartsWith('..\');
end;

procedure TLibraryUpdateReview.Analyze(const Target, Previous: IBookCollection; const SystemData:ISystemData;
  const Check: TProc; const Progress: TLibraryReviewProgress);
var DB: TSQLiteDatabase; Insert, Query: TSQLiteQuery; Iterator: IPublisherSeriesIndexIterator;
  Book, Candidate: TBookRecord; Stamp, Namespace, Key, Name, OldPath, NewPath, Path, Version, SourceKey: string;
  Count, Total, NewCount, ChangedCount: Integer; Existing, CandidateExists: Boolean;
  MergeSource: TMergeSource; Containers: TDictionary<string,string>;
  StateDB, PackedDB: TSQLiteDatabase; StateQuery, SourceKeyQuery, PublisherQuery, RecoveredQuery, ReviewKeyQuery: TSQLiteQuery;
  State, Container, Comparison, Alternate, AlternateKey, RawLocation: string;
  Availability: TDictionary<string,Boolean>;
  PackedProjected,PackedMapped:Integer;
  PackedBatch,ProjectPackedPrevious,StandalonePacked:Boolean;
  BoundPackedCopy,LegacyInput,PriorArtifact,ExcludedAlias,UnresolvedExclusion:TSQLiteQuery;
  procedure RememberExcludedAlias(const OldKey,ArtifactKey:string);
  begin
    if (OldKey=ArtifactKey) or not Assigned(ExcludedAlias) then Exit;
    ExcludedAlias.Reset;
    ExcludedAlias.SetParam(0,OldKey); ExcludedAlias.SetParam(1,ArtifactKey);
    ExcludedAlias.SetParam(2,OldKey); ExcludedAlias.ExecSQL;
  end;
  function PackedPublisherKey(const Item:TBookRecord; const SpaceNamespace,Root:string;
    out Location:string):string;
  begin
    Location:=LegacyPublisherLocation(Item);
    if not LibraryPackedIdentityNeedsLocation(Item.LibID) then
      Exit(ReviewBookKey(Item,SpaceNamespace,Root));
    var ExactLocation:=LibraryLegacyPublisherLocation(Item,False);
    if ExactLocation<>Location then
    begin
      // A conventional INPX can advertise ZIP when the initial local import
      // recorded 7z. A saved publisher locator has priority over this convention.
      var ExactKey:=LibraryPackedArtifactKey(Item,ExactLocation);
      if FPreviousIndex then
      begin
        PriorArtifact.Reset; PriorArtifact.SetParam(0,ExactKey); PriorArtifact.Open;
        if not PriorArtifact.Eof then begin Location:=ExactLocation; Exit(ExactKey); end;
        PriorArtifact.Reset;
        PriorArtifact.SetParam(0,LibraryPackedArtifactKey(Item,Location)); PriorArtifact.Open;
        if not PriorArtifact.Eof then Exit(PriorArtifact.FieldAsString(0));
      end;
      if FIsMetabib then Location:=ExactLocation;
    end;
    Result:=LibraryPackedArtifactKey(Item,Location);
  end;
  function LegacyArtifact(const Path, Name: string; const Item: TBookRecord): string;
  begin
    Result:=THashSHA2.GetHashString(TPath.GetFullPath(Path)+#1+Name+#1+Item.FileExt+#1+
      Item.LibID+#1+FloatToStr(Item.Date,TFormatSettings.Invariant));
  end;
  procedure RecoverPublisherLocations;
  var Missing:TSQLiteQuery; Needed:Boolean; Lease:TFileStream;
    Hash:THashSHA2; Bytes:TBytes; Count:Integer;
    procedure BuildPublisherMap;
    var Put:TSQLiteQuery; Item:TBookRecord; Unused,SpaceNamespace:string;
      Scratch:IBookCollection; Source:TCatalogSource; Helper:TCollectionWorker;
      RecoveredIterator:IPublisherSeriesIndexIterator;
    begin
      TBookCollection_SQLite.CreateCollection(SystemData,FPublisherFile,CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2],FPrepared.Folder);
      Source:=FSourceInfo; Source.Root:=Previous.CollectionRoot; Scratch:=OpenCatalogSnapshot(Source,FPublisherFile,SystemData,FPrepared.Folder);
      SpaceNamespace:=VarToStr(Previous.GetProperty(PROP_SOURCE_LIBRARY)); if SpaceNamespace='' then SpaceNamespace:=FSourceInfo.LibraryNamespace;
      if SpaceNamespace<>'' then Scratch.SetProperty(PROP_SOURCE_LIBRARY,SpaceNamespace);
      var Mixed:=Previous.GetProperty(PROP_MIXED_LIBRARY_IDS); if not VarIsEmpty(Mixed) and not VarIsNull(Mixed) then Scratch.SetProperty(PROP_MIXED_LIBRARY_IDS,Mixed);
      if TMetabibReader.IsDatasetFile(FPreviousInput) then
      begin
        var Reader:=TPreviousMetabibWorker.Create(MHL_INVALID_ID); Reader.Input:=FPreviousInput; Reader.Scratch:=Scratch;
        Reader.Check:=procedure begin Check; NotifyLibraryUpdateTestPoint('publisher-recovery-row'); end;
        Reader.Cancellation:=SQLiteCancelCallback; Helper:=Reader;
      end
      else
      begin
        var Reader:=TPreviousInpxWorker.Create(MHL_INVALID_ID); Reader.Input:=FPreviousInput; Reader.Scratch:=Scratch;
        Reader.Check:=procedure begin Check; NotifyLibraryUpdateTestPoint('publisher-recovery-row'); end;
        Reader.Cancellation:=SQLiteCancelCallback; Helper:=Reader;
      end;
      try
        Helper.Start; Helper.WaitFor;
        if Assigned(Helper.FatalException) then
          if Helper.FatalException is EAbort then raise EAbort.Create(Exception(Helper.FatalException).Message)
          else raise EReadError.Create('Не удалось прочитать прежний исходный индекс: '+Exception(Helper.FatalException).Message);
        if not Helper.Success then raise EReadError.Create('Не завершено восстановление исходных имён.');
      finally Helper.Free; end;
      DB.ExecSQL('CREATE TABLE ReviewRecoveredPublishers(Key TEXT PRIMARY KEY,Stamp TEXT,Location TEXT,Ambiguous INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID');
      Put:=DB.NewQuery('INSERT INTO ReviewRecoveredPublishers(Key,Stamp,Location) VALUES(?,?,?) '+
        'ON CONFLICT(Key) DO UPDATE SET Ambiguous=Ambiguous OR Stamp<>excluded.Stamp OR Location<>excluded.Location');
      try
        RecoveredIterator:=Scratch.GetPublisherSeriesIndexIterator; DB.Start;
        try while RecoveredIterator.Next(Item,Unused) do
          begin Check; CheckSpace; Put.Reset; Put.SetParam(0,PublisherRecoveryKey(Item,SpaceNamespace,Previous.CollectionRoot));
            Put.SetParam(1,ReviewStamp(Item)); Put.SetParam(2,PublisherLocation(Item)); Put.ExecSQL; end;
          DB.Commit;
        except DB.Rollback; raise; end;
      finally RecoveredIterator:=nil; Put.Free; Scratch:=nil; end;
    end;
  begin
    if not Assigned(StateDB) or ((FPreviousInput='') and (FPreviousInputSHA='')) then Exit;
    if Assigned(PublisherQuery) then
      Missing:=StateDB.NewQuery('SELECT b.Folder FROM Books b WHERE NOT EXISTS(SELECT 1 FROM LibraryUpdatePublisherLocations p WHERE p.BookID=b.BookID)')
    else Missing:=StateDB.NewQuery('SELECT Folder FROM Books');
    Needed:=False;
    try Missing.Open; while not Missing.Eof do
      begin Check; if ExternalPublisherLocator(Missing.FieldAsString(0),Previous.CollectionRoot) then begin Needed:=True; Break; end; Missing.Next; end;
    finally Missing.Free; end;
    if not Needed then Exit;
    if (FPreviousInput='') or (Length(FPreviousInputSHA)<>64) or not FileExists(FPreviousInput) or
      not SameFileName(TPath.GetDirectoryName(TPath.GetFullPath(FPreviousInput)),TPath.GetDirectoryName(TPath.GetFullPath(FPreviousFile))) then
      raise EReadError.Create('Для прежних путей вне папки источника нужен сохранённый исходный индекс с контрольной суммой. Служебный каталог не изменён.');
    if Assigned(Progress) then Progress('Восстановление исходных имён из сохранённого индекса',0,0);
    Lease:=TFileStream.Create(FPreviousInput,fmOpenRead or fmShareDenyWrite);
    try
      Hash:=THashSHA2.Create; SetLength(Bytes,1024*1024);
      repeat Check; CheckSpace; Count:=Lease.Read(Bytes[0],Length(Bytes)); if Count>0 then Hash.Update(Bytes,Count); until Count=0;
      if not SameText(Hash.HashAsString,FPreviousInputSHA) then raise EReadError.Create('Не совпала контрольная сумма прежнего исходного индекса. Восстановление имён остановлено.');
      var PublisherFile:=TPath.Combine(FPrepared.Folder,'publisher-'+TGUID.NewGuid.ToString+'.hlc2');
      if FileExists(PublisherFile) then raise EWriteError.Create('Временный каталог восстановления уже существует.');
      FPublisherFile:=PublisherFile;
      try BuildPublisherMap;
      finally
        // All interface temporaries belong to BuildPublisherMap and are now finalized.
        for var Suffix in TArray<string>.Create('','-wal','-shm','-journal') do
          if FileExists(FPublisherFile+Suffix) then try TFile.Delete(FPublisherFile+Suffix); except end;
      end;
      RecoveredQuery:=DB.NewQuery('SELECT Location FROM ReviewRecoveredPublishers WHERE Key=? AND Stamp=? AND Ambiguous=0');
    finally Lease.Free; end;
  end;
  function Available(const Item:TBookRecord; const Resolved:string):Boolean;
  var FileName:string;
  begin
    FileName:=Item.GetBookFileName(Resolved);
    if IsArchiveExt(Item.Folder) then
    begin
      if Availability.TryGetValue(FileName,Result) then Exit;
      Result:=FileExists(FileName);
      if Availability.Count>=65536 then Availability.Clear;
      Availability.AddOrSetValue(FileName,Result);
    end
    else Result:=FileExists(FileName);
  end;
  procedure Load(const Collection: IBookCollection; IsPrevious: Boolean);
  var Publisher:TPackingPublisherState; Projected,UseArtifact:Boolean;
    PublisherRoot,OriginalKey,CachedKey:string; IdentityBook:TBookRecord;
  begin
    Namespace:=VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    if IsPrevious and (Namespace='') then Namespace:=FSourceInfo.LibraryNamespace;
    Iterator:=Collection.GetPublisherSeriesIndexIterator; Count:=0; Total:=Iterator.RecordCount;
    while Iterator.Next(Book,Stamp) do
    begin
      Check; CheckSpace;
      IdentityBook:=Book;
      PublisherRoot:=FSourceInfo.Root;
      Projected:=False;
      if IsPrevious and ProjectPackedPrevious then
        Projected:=ReadPackingPublisher(PackedDB,Book.BookKey.BookID,Publisher);
      if Projected then
      begin
        if Publisher.Book.LibID<>Book.LibID then
          raise EReadError.Create('Исходные сведения упакованной книги больше не соответствуют её идентификатору: '+Book.Title);
        PublisherRoot:=Publisher.Root; if PublisherRoot='' then PublisherRoot:=FSourceInfo.Root;
        IdentityBook:=Publisher.Book;
        Inc(PackedProjected);
      end;
      UseArtifact:=StandalonePacked and LibraryPackedIdentityNeedsLocation(IdentityBook.LibID);
      OriginalKey:=ReviewBookKey(IdentityBook,Namespace,PublisherRoot);
      CachedKey:=OriginalKey;
      if IsPrevious and Assigned(ReviewKeyQuery) then
      begin
        ReviewKeyQuery.Reset; ReviewKeyQuery.SetParam(0,Book.BookKey.BookID); ReviewKeyQuery.Open;
        if not ReviewKeyQuery.Eof then CachedKey:=ReviewKeyQuery.FieldAsString(0);
      end;
      Key:=CachedKey;
      Insert.Reset;
      if Projected then Insert.SetParam(1,ReviewStamp(Publisher.Book)) else Insert.SetParam(1,ReviewStamp(Book));
      if IsPrevious then
      begin
        MergeSource.ID:=FSourceInfo.ID; MergeSource.Root:=Collection.CollectionRoot;
        Container:=ReviewContainer(Book,'',Containers);
        SourceKey:=MergeSourceKeyAtLocation(MergeSource,Book,Container);
        // A legacy raw cache can still name ZIP while its merged live link
        // names the actual 7z. The live link is evidence even with the root off.
        if (FSource.CatalogSourceID<>'') and FOriginalRootOffline and
          SameText(ExtractFileExt(Container),ZIP_EXTENSION) and (Target.GetCatalogBookID(SourceKey)=0) then
        begin
          Alternate:=ChangeFileExt(Container,SEVENZIP_EXTENSION);
          AlternateKey:=MergeSourceKeyAtLocation(MergeSource,Book,Alternate);
          if Target.GetCatalogBookID(AlternateKey)>0 then begin Container:=Alternate; SourceKey:=AlternateKey; end;
        end;
        if Assigned(SourceKeyQuery) then
        begin
          SourceKeyQuery.Reset; SourceKeyQuery.SetParam(0,Book.BookKey.BookID); SourceKeyQuery.Open;
          if not SourceKeyQuery.Eof then SourceKey:=SourceKeyQuery.FieldAsString(0);
        end;
        RawLocation:=LegacyPublisherLocation(IdentityBook);
        if UseArtifact and FIsMetabib then
          RawLocation:=LibraryLegacyPublisherLocation(IdentityBook,False);
        if Assigned(PublisherQuery) then
        begin
          PublisherQuery.Reset; PublisherQuery.SetParam(0,Book.BookKey.BookID); PublisherQuery.Open;
          if not PublisherQuery.Eof then RawLocation:=PublisherQuery.FieldAsString(0);
        end;
        if ((FPreviousInput<>'') or (FPreviousInputSHA<>'')) and ExternalPublisherLocator(Book.Folder,Collection.CollectionRoot) and
          (not Assigned(PublisherQuery) or PublisherQuery.Eof) then
        begin
          if not Assigned(RecoveredQuery) then raise EReadError.Create('Не восстановлено исходное имя прежнего архива: '+Book.Folder);
          RecoveredQuery.Reset; RecoveredQuery.SetParam(0,PublisherRecoveryKey(Book,Namespace,Collection.CollectionRoot));
          RecoveredQuery.SetParam(1,ReviewStamp(Book)); RecoveredQuery.Open;
          if RecoveredQuery.Eof then raise EReadError.Create('В сохранённом исходном индексе нет однозначной записи для прежнего архива: '+Book.Folder+' | '+Book.FileName);
          RawLocation:=RecoveredQuery.FieldAsString(0);
        end;
        if UseArtifact then
        begin
          Key:=LibraryPackedArtifactKey(IdentityBook,RawLocation);
          RememberExcludedAlias(OriginalKey,Key);
          if CachedKey<>OriginalKey then RememberExcludedAlias(CachedKey,Key);
        end;
        Insert.SetParam(2,RawLocation); Insert.SetParam(3,SourceKey);
        Insert.SetParam(4,BookPhysicalIdentityAtLocation(Book,Container));
        State:='known';
        if Assigned(StateQuery) then
        begin
          StateQuery.Reset; StateQuery.SetParam(0,Book.BookKey.BookID); StateQuery.Open;
          if not StateQuery.Eof then State:=StateQuery.FieldAsString(0);
        end;
        Insert.SetParam(5,State); Insert.SetParam(6,Book.BookKey.BookID);
        Insert.SetParam(7,Container); Insert.SetParam(8,Book.InsideNo); Insert.SetParam(9,Book.LibID);
        Insert.SetParam(12,False);
        if Assigned(BoundPackedCopy) then
        begin
          BoundPackedCopy.Reset;
          BoundPackedCopy.SetParam(0,SourceKey);
          BoundPackedCopy.Open;
          Insert.SetParam(12,not BoundPackedCopy.Eof);
        end;
        if Projected then Insert.SetParam(10,Publisher.PendingPayload)
        else Insert.SetParam(10,Assigned(BoundPackedCopy) and ((State='missing') or (State='missing-retained')));
        if Projected then
          Insert.SetParam(11,IntToStr(Publisher.Book.Size)+#1+FloatToStr(Publisher.Book.Date,TFormatSettings.Invariant))
        else
          Insert.SetParam(11,IntToStr(Book.Size)+#1+FloatToStr(Book.Date,TFormatSettings.Invariant));
        if Assigned(LegacyInput) then
        begin
          LegacyInput.Reset;
          LegacyInput.SetParam(0,LegacyArtifact(Book.GetBookFileName(Container),Book.FileName,Book));
          LegacyInput.SetParam(1,Book.BookKey.BookID);
          LegacyInput.SetParam(2,Key);
          LegacyInput.SetParam(3,Book.Folder); LegacyInput.SetParam(4,Book.FileName);
          LegacyInput.SetParam(5,Book.FileExt); LegacyInput.SetParam(6,Book.InsideNo);
          LegacyInput.SetParam(7,Book.Size); LegacyInput.SetParam(8,Book.Date);
          LegacyInput.SetParam(9,Book.Title); LegacyInput.SetParam(10,Book.Lang);
          LegacyInput.SetParam(11,bpIsDeleted in Book.BookProps); LegacyInput.SetParam(12,Book.LibID);
          LegacyInput.ExecSQL;
        end;
      end
      else
      begin
        RawLocation:=PublisherLocation(Book);
        if UseArtifact then
        begin
          Key:=LibraryPackedArtifactKey(Book,RawLocation);
          if Assigned(UnresolvedExclusion) then
          begin
            UnresolvedExclusion.Reset; UnresolvedExclusion.SetParam(0,OriginalKey); UnresolvedExclusion.Open;
            if not UnresolvedExclusion.Eof then
              raise EReadError.Create('Не удалось определить исходный архив ранее исключённой книги: '+
                RawLocation+' | '+Book.FileName+Book.FileExt);
          end;
        end;
        Insert.SetParam(2,Book.BookKey.BookID);
        Insert.SetParam(3,ReviewLocation(Book));
        Insert.SetParam(4,not (bpIsDeleted in Book.BookProps));
        Container:=ReviewContainer(Book,FSource.BooksRoot,Containers);
        Insert.SetParam(5,BookPhysicalIdentityAtLocation(Book,Container));
        Insert.SetParam(6,Available(Book,Container)); Insert.SetParam(7,RawLocation);
        Insert.SetParam(8,IntToStr(Book.Size)+#1+FloatToStr(Book.Date,TFormatSettings.Invariant));
      end;
      Insert.SetParam(0,Key);
      Insert.ExecSQL; Inc(Count);
      if Assigned(Progress) and ((Count mod 1000=0) or (Count=Total)) then
        if IsPrevious then Progress('Сопоставление с прежними книгами',Count,Total)
        else Progress('Проверка нового списка книг',Count,Total);
    end;
    Iterator:=nil;
  end;
  procedure MapPackedLocations;
  var Live:IPublisherSeriesIndexIterator; Item:TBookRecord; Publisher:TPackingPublisherState;
    Put,Origin,Matched:TSQLiteQuery; Unused,PublisherRoot,SpaceNamespace,PhysicalContainer,Key,Location:string;
  begin
    if not Assigned(PackedDB) then Exit;
    SpaceNamespace:=VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY));
    if SpaceNamespace='' then SpaceNamespace:=FSourceInfo.LibraryNamespace;
    Put:=DB.NewQuery('INSERT INTO ReviewPackedLocations VALUES(?,?,?,?,?,?,?,?,?,?,?)');
    Origin:=nil; Matched:=nil;
    try
      if FLegacyPackedBaseline then
      begin
        Origin:=PackedDB.NewQuery('SELECT Source,OriginalFileName FROM HomeLibPackingOrigins '+
          'WHERE Folder=? AND FileName=? AND Ext=?');
        Matched:=DB.NewQuery('SELECT p.Key,p.State,p.Copies FROM ReviewLegacyArtifacts a JOIN ReviewPrevious p '+
          'ON p.Key=a.Key WHERE a.Artifact=? LIMIT 2');
      end;
      Live:=Target.GetPublisherSeriesIndexIterator;
      while Live.Next(Item,Unused) do
      begin
        Check; CheckSpace;
        if IsLocalBookID(Item.LibID) then Continue;
        if Assigned(Origin) then
        begin
          Origin.Reset; Origin.SetParam(0,Item.Folder); Origin.SetParam(1,Item.FileName);
          Origin.SetParam(2,Item.FileExt); Origin.Open;
          if Origin.Eof then
            raise EReadError.Create('Нет исходного пути упакованной книги: '+Item.Title);
          Matched.Reset;
          var OriginalPath:=Origin.FieldAsString(0);
          var OriginalName:=Origin.FieldAsString(1);
          Matched.SetParam(0,LegacyArtifact(OriginalPath,OriginalName,Item)); Matched.Open;
          // INPX can still name a ZIP when the recorded original is a 7z archive.
          if Matched.Eof and SameText(ExtractFileExt(OriginalPath),SEVENZIP_EXTENSION) then
          begin
            Matched.Reset;
            Matched.SetParam(0,LegacyArtifact(ChangeFileExt(OriginalPath,ZIP_EXTENSION),OriginalName,Item)); Matched.Open;
          end;
          if Matched.Eof or (Matched.FieldAsInt(2)<>1) then
            raise EReadError.Create('Сохранённый прежний индекс не подтверждает исходный файл упакованной книги: '+Item.Title);
          Key:=Matched.FieldAsString(0);
          Publisher.PendingPayload:=(Matched.FieldAsString(1)='missing') or (Matched.FieldAsString(1)='missing-retained');
          Matched.Next;
          if not Matched.Eof then
            raise EReadError.Create('Несколько записей прежнего индекса соответствуют упакованной книге: '+Item.Title);
        end
        else
        begin
          if not ReadPackingPublisher(PackedDB,Item.BookKey.BookID,Publisher) then Continue;
          if Publisher.Book.LibID<>Item.LibID then
            raise EReadError.Create('Исходные сведения упакованной книги больше не соответствуют её идентификатору: '+Item.Title);
          PublisherRoot:=Publisher.Root; if PublisherRoot='' then PublisherRoot:=FSourceInfo.Root;
          Key:=PackedPublisherKey(Publisher.Book,SpaceNamespace,PublisherRoot,Location);
        end;
        PhysicalContainer:=ReviewContainer(Item,'',Containers);
        Put.Reset; Put.SetParam(0,Key);
        Put.SetParam(1,Item.BookKey.BookID); Put.SetParam(2,Item.CollectionRoot);
        Put.SetParam(3,Item.Folder); Put.SetParam(4,Item.FileName); Put.SetParam(5,Item.FileExt);
        Put.SetParam(6,Item.InsideNo); Put.SetParam(7,Item.Size);
        Put.SetParam(8,BookPhysicalIdentityAtLocation(Item,PhysicalContainer));
        Put.SetParam(9,Publisher.PendingPayload); Put.SetParam(10,PhysicalContainer); Put.ExecSQL;
        Inc(PackedMapped);
        if Assigned(Progress) and ((PackedMapped mod 1000=0) or (PackedMapped=Live.RecordCount)) then
          Progress('Сопоставление готовых упакованных файлов',PackedMapped,Live.RecordCount);
      end;
    finally Live:=nil; Matched.Free; Origin.Free; Put.Free; end;
  end;
  procedure LoadPackedExclusions;
  var Removed,Save:TSQLiteQuery; Publisher:TPackingPublisherState; PublisherRoot,Key,Location:string;
  begin
    if not Assigned(PackedDB) then Exit;
    Removed:=PackedDB.NewQuery('SELECT p.BookID FROM HomeLibrePackingPublishers p '+
      'LEFT JOIN Books b ON b.BookID=p.BookID WHERE b.BookID IS NULL');
    Save:=nil;
    try
      Save:=DB.NewQuery('INSERT OR IGNORE INTO ReviewPrevious(Key,Stamp,Location,State,BookID,LibID) VALUES(?,?,?,''excluded'',?,?)');
      Removed.Open;
      while not Removed.Eof do
      begin
        Check; CheckSpace;
        if not ReadPackingPublisher(PackedDB,Removed.FieldAsInt(0),Publisher) then
          raise EReadError.Create('Не найдены исходные сведения удалённой упакованной книги.');
        PublisherRoot:=Publisher.Root; if PublisherRoot='' then PublisherRoot:=FSourceInfo.Root;
        Key:=PackedPublisherKey(Publisher.Book,Namespace,PublisherRoot,Location);
        if LibraryPackedIdentityNeedsLocation(Publisher.Book.LibID) then
          RememberExcludedAlias(ReviewBookKey(Publisher.Book,Namespace,PublisherRoot),Key);
        Save.Reset; Save.SetParam(0,Key);
        Save.SetParam(1,ReviewStamp(Publisher.Book)); Save.SetParam(2,Location);
        Save.SetParam(3,Publisher.Book.BookKey.BookID); Save.SetParam(4,Publisher.Book.LibID); Save.ExecSQL;
        // A retained raw cache can already have this key in ReviewPrevious.
        // Record the proven post-packing deletion independently of that row.
        DB.ExecSQL('INSERT OR IGNORE INTO ReviewExcluded VALUES(?)',[Key]);
        Removed.Next;
      end;
      DB.ExecSQL('INSERT OR IGNORE INTO ReviewExcluded SELECT Key FROM ReviewPrevious WHERE State=''excluded''');
    finally Save.Free; Removed.Free; end;
  end;
begin
  Comparison:=TPath.Combine(FPrepared.Folder,'comparison-'+TGUID.NewGuid.ToString+'.sqlite');
  if FileExists(Comparison) then raise EWriteError.Create('Рабочее сравнение уже существует.');
  FAnalysisFile:=Comparison;
  DB:=OpenWorkDatabase(FAnalysisFile); Insert:=nil; Query:=nil;
  Containers:=TDictionary<string,string>.Create; Availability:=TDictionary<string,Boolean>.Create;
  StateDB:=nil; PackedDB:=nil; PackedProjected:=0; PackedMapped:=0; PackedBatch:=False; ProjectPackedPrevious:=False;
  StateQuery:=nil; SourceKeyQuery:=nil; PublisherQuery:=nil; RecoveredQuery:=nil; ReviewKeyQuery:=nil;
  BoundPackedCopy:=nil; LegacyInput:=nil; FLegacyPackedBaseline:=False;
  StandalonePacked:=FPacked and (FSource.CatalogSourceID='');
  PriorArtifact:=nil; ExcludedAlias:=nil; UnresolvedExclusion:=nil;
  try
    if FPreviousIndex then
    begin
      StateDB:=OpenWorkDatabase(VarToStr(Previous.GetProperty(PROP_DATAFILE)),True);
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateAvailability'' AND type=''table''')>0 then
        if StateDB.QuerySingleInt('SELECT count(*) FROM LibraryUpdateAvailability')>0 then
          StateQuery:=StateDB.NewQuery('SELECT State FROM LibraryUpdateAvailability WHERE BookID=?');
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateSourceKeys'' AND type=''table''')>0 then
        if StateDB.QuerySingleInt('SELECT count(*) FROM LibraryUpdateSourceKeys')>0 then
          SourceKeyQuery:=StateDB.NewQuery('SELECT SourceKey FROM LibraryUpdateSourceKeys WHERE BookID=?');
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdatePublisherLocations'' AND type=''table''')>0 then
        PublisherQuery:=StateDB.NewQuery('SELECT Location FROM LibraryUpdatePublisherLocations WHERE BookID=?');
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateReviewKeys'' AND type=''table''')>0 then
        ReviewKeyQuery:=StateDB.NewQuery('SELECT Key FROM LibraryUpdateReviewKeys WHERE BookID=?');
    end;
    // Saved source caches remain authoritative for publisher metadata and
    // exclusions. Their numeric IDs are not the live packed catalogue IDs.
    // Keep a separate logical-key map to the actual current packed payload.
    if FPacked and (FSource.CatalogSourceID<>'') then
    begin
      PackedDB:=OpenWorkDatabase(FTargetFile,True);
      BoundPackedCopy:=PackedDB.NewQuery('SELECT c.BookID FROM CatalogBookCopies c '+
        'JOIN CatalogSourceBooks l ON l.SourceKey=c.SourceKey AND l.BookID=c.BookID '+
        'JOIN Books b ON b.BookID=l.BookID WHERE c.SourceKey=?');
    end
    else if FPacked then
    begin
      PackedDB:=OpenWorkDatabase(FTargetFile,True);
      if PackedDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibrePackingPublishers''')=0 then
      begin
        if not FPreviousIndex or
          (PackedDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibPackingOrigins''')=0) then
          raise EReadError.Create('Для сравнения этой упакованной коллекции нужны исходные пути книг и прежний индекс. '+
            'Если есть прежний полный INPX, выберите его в настройке источника.');
        FLegacyPackedBaseline:=True;
        DB.ExecSQL('CREATE TABLE ReviewLegacyArtifacts(Artifact TEXT NOT NULL,BookID INTEGER PRIMARY KEY,Key TEXT NOT NULL,'+
          'Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER,UpdateDate TEXT,Title TEXT,Lang TEXT,'+
          'IsDeleted INTEGER,LibID TEXT)');
        DB.ExecSQL('CREATE INDEX ReviewLegacyArtifact ON ReviewLegacyArtifacts(Artifact)');
        LegacyInput:=DB.NewQuery('INSERT INTO ReviewLegacyArtifacts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)');
      end
      else
      begin
        PackedDB.BeginQueryBatch; PackedBatch:=True;
        ProjectPackedPrevious:=not Assigned(ReviewKeyQuery) and
          SameFileName(FTargetFile,Settings.ExpandCollectionFileName(VarToStr(Previous.GetProperty(PROP_DATAFILE))));
      end;
    end;
    DB.ExecSQL('CREATE TABLE ReviewPrevious(Key TEXT PRIMARY KEY,Stamp TEXT,Location TEXT,SourceKey TEXT,Physical TEXT,State TEXT,BookID INTEGER,Container TEXT,InsideNo INTEGER,Copies INTEGER NOT NULL DEFAULT 1,LibID TEXT,PackedPending INTEGER NOT NULL DEFAULT 0,PayloadStamp TEXT NOT NULL DEFAULT '''',PackedCopy INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID');
    DB.ExecSQL('CREATE TABLE ReviewRows(Key TEXT,Stamp TEXT,BookID INTEGER,Location TEXT,Active INTEGER,Physical TEXT,Available INTEGER,PublisherLocation TEXT,PayloadStamp TEXT)');
    DB.ExecSQL('CREATE TABLE ReviewExcluded(Key TEXT PRIMARY KEY) WITHOUT ROWID');
    DB.ExecSQL('CREATE TABLE ReviewPackedLocations(Key TEXT NOT NULL,BookID INTEGER PRIMARY KEY,Root TEXT,Folder TEXT,'+
      'FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER,Physical TEXT,PendingPayload INTEGER,Container TEXT)');
    DB.ExecSQL('CREATE INDEX ReviewPackedLocationKey ON ReviewPackedLocations(Key)');
    if StandalonePacked then PriorArtifact:=DB.NewQuery('SELECT Key FROM ReviewPrevious WHERE Key=?');
    RecoverPublisherLocations;
    if Assigned(StateDB) and (StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateExclusions'' AND type=''table''')>0) then
    begin
      var Excluded:=StateDB.NewQuery('SELECT Key FROM LibraryUpdateExclusions');
      var SaveExcluded:=DB.NewQuery('INSERT OR IGNORE INTO ReviewExcluded VALUES(?)');
      try
        DB.Start;
        try
          Excluded.Open;
          while not Excluded.Eof do
          begin
            Check; SaveExcluded.Reset; SaveExcluded.SetParam(0,Excluded.FieldAsString(0)); SaveExcluded.ExecSQL; Excluded.Next;
          end;
          DB.Commit;
        except DB.Rollback; raise; end;
      finally SaveExcluded.Free; Excluded.Free; end;
      if StandalonePacked and (DB.QuerySingleInt('SELECT count(*) FROM ReviewExcluded')>0) then
      begin
        DB.ExecSQL('CREATE TABLE ReviewExcludedAliases(OldKey TEXT,ArtifactKey TEXT,'+
          'PRIMARY KEY(OldKey,ArtifactKey)) WITHOUT ROWID');
        ExcludedAlias:=DB.NewQuery('INSERT OR IGNORE INTO ReviewExcludedAliases SELECT ?,? '+
          'WHERE EXISTS(SELECT 1 FROM ReviewExcluded WHERE Key=?)');
        UnresolvedExclusion:=DB.NewQuery('SELECT Key FROM ReviewExcluded WHERE Key=?');
      end;
    end;
    // Build the empty index before streaming rows. GROUP BY/ORDER BY can walk
    // it without a large sort spilling to Windows TEMP on the system drive.
    DB.ExecSQL('CREATE INDEX ReviewRowsLocation ON ReviewRows(Location)');
    // Full updates test every live key for absence from the new index.
    // Keep duplicate keys valid while avoiding a correlated full-table scan.
    DB.ExecSQL('CREATE INDEX ReviewRowsKey ON ReviewRows(Key)');
    DB.Start;
    try
      Insert:=DB.NewQuery('INSERT INTO ReviewPrevious(Key,Stamp,Location,SourceKey,Physical,State,BookID,Container,InsideNo,LibID,PackedPending,PayloadStamp,PackedCopy) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) '+
        'ON CONFLICT(Key) DO UPDATE SET Copies=Copies+1'); Load(Previous,True); FreeAndNil(Insert);
      if not Assigned(BoundPackedCopy) then
      begin
        MapPackedLocations;
        if FLegacyPackedBaseline then
          DB.ExecSQL('INSERT OR IGNORE INTO ReviewExcluded SELECT p.Key FROM ReviewPrevious p '+
            'WHERE p.State=''excluded'' OR (p.State<>''missing'' AND NOT EXISTS '+
            '(SELECT 1 FROM ReviewPackedLocations l WHERE l.Key=p.Key))')
        else LoadPackedExclusions;
      end;
      if Assigned(ExcludedAlias) then
      begin
        if DB.QuerySingleInt('SELECT count(*) FROM (SELECT OldKey FROM ReviewExcludedAliases '+
          'GROUP BY OldKey HAVING count(*)>1)')>0 then
          raise EReadError.Create('Прежнее исключение соответствует нескольким архивам. '+
            'Не удалось однозначно определить исключённую книгу. Обновление остановлено.');
        DB.ExecSQL('INSERT OR IGNORE INTO ReviewExcluded SELECT ArtifactKey FROM ReviewExcludedAliases');
        DB.ExecSQL('DELETE FROM ReviewExcluded WHERE Key IN (SELECT OldKey FROM ReviewExcludedAliases)');
      end;
      Insert:=DB.NewQuery('INSERT INTO ReviewRows VALUES(?,?,?,?,?,?,?,?,?)'); Load(FSnapshot,False); FreeAndNil(Insert);
      if Assigned(BoundPackedCopy) then
        DB.ExecSQL('UPDATE ReviewRows AS r SET Physical=(SELECT p.Physical FROM ReviewPrevious p WHERE p.Key=r.Key) '+
          'WHERE EXISTS(SELECT 1 FROM ReviewPrevious p WHERE p.Key=r.Key AND p.PackedCopy<>0 '+
          'AND p.PayloadStamp=r.PayloadStamp AND p.Location=r.PublisherLocation)')
      else if Assigned(PackedDB) then
      begin
        DB.ExecSQL('UPDATE ReviewPrevious AS p SET PackedPending=EXISTS '+
          '(SELECT 1 FROM ReviewPackedLocations l WHERE l.Key=p.Key AND l.PendingPayload<>0)');
        // The same published artifact can have a different physical name and
        // size after packing. A delivered original archive is not a change to
        // that artifact by itself. Retain the raw baseline and physical map.
        DB.ExecSQL('UPDATE ReviewRows AS r SET Physical=(SELECT p.Physical FROM ReviewPrevious p WHERE p.Key=r.Key) '+
          'WHERE EXISTS(SELECT 1 FROM ReviewPrevious p WHERE p.Key=r.Key AND p.Stamp=r.Stamp '+
          'AND p.Location=r.PublisherLocation AND EXISTS(SELECT 1 FROM ReviewPackedLocations l WHERE l.Key=p.Key))');
      end;
      // Missing files cannot prove a new physical container. Compare the raw
      // publisher locator, retaining the last resolved identity only when both
      // that locator and metadata agree and the source root was not rebound.
      if SameFileName(TPath.GetFullPath(Previous.CollectionRoot),TPath.GetFullPath(FSnapshot.CollectionRoot)) then
        DB.ExecSQL('UPDATE ReviewRows AS r SET Physical=(SELECT p.Physical FROM ReviewPrevious p WHERE p.Key=r.Key) '+
          'WHERE r.Available=0 AND EXISTS(SELECT 1 FROM ReviewPrevious p WHERE p.Key=r.Key AND p.Stamp=r.Stamp AND p.Location=r.PublisherLocation)');
      DB.Commit;
    except DB.Rollback; raise; end;
    FTotal:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows');
    FDeleted:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows WHERE Active=0');
    FNewBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key LEFT JOIN ReviewExcluded e ON e.Key=r.Key '+
      'WHERE r.Active<>0 AND p.Key IS NULL AND e.Key IS NULL');
    FChangedBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r JOIN ReviewPrevious p ON p.Key=r.Key LEFT JOIN ReviewExcluded e ON e.Key=r.Key '+
      'WHERE r.Active<>0 AND p.State<>''excluded'' AND e.Key IS NULL AND (p.Stamp<>r.Stamp OR p.Physical<>r.Physical OR p.PackedPending<>0)');
    var NeedBody:='(p.State IN (''missing'',''missing-retained'') OR p.Stamp<>r.Stamp OR p.Physical<>r.Physical OR p.PackedPending<>0)';
    if Assigned(BoundPackedCopy) then
      NeedBody:='(p.State IN (''missing'',''missing-retained'') OR p.PayloadStamp<>r.PayloadStamp '+
        'OR p.Location<>r.PublisherLocation OR (p.PackedCopy=0 AND p.Physical<>r.Physical))';
    Query:=DB.NewQuery('SELECT r.Location,min(r.BookID),sum(r.Active<>0 AND p.Key IS NULL),'+
      'sum(r.Active<>0 AND p.Key IS NOT NULL AND '+NeedBody+') '+
      'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key LEFT JOIN ReviewExcluded e ON e.Key=r.Key '+
      'WHERE e.Key IS NULL AND coalesce(p.State,''known'')<>''excluded'' GROUP BY r.Location HAVING sum(r.Active)>0 ORDER BY r.Location');
    Query.Open;
    while not Query.Eof do
    begin
      Check; CheckSpace;
      Name:=Query.FieldAsString(0); NewCount:=Query.FieldAsInt(2); ChangedCount:=Query.FieldAsInt(3);
      FSnapshot.GetBookRecord(CreateBookKey(Query.FieldAsInt(1),FSnapshot.CollectionID),Book,False);
      OldPath:=Book.GetBookFileName; Path:=OldPath; Existing:=FileExists(OldPath);
      CandidateExists:=False; NewPath:='';
      if (FSource.BooksRoot<>'') and not TPath.IsPathRooted(Book.Folder) then
      begin
        Candidate:=Book; Candidate.CollectionRoot:=IncludeTrailingPathDelimiter(FSource.BooksRoot);
        NewPath:=Candidate.GetBookFileName; CandidateExists:=FileExists(NewPath);
        if CandidateExists and not Existing then Path:=NewPath;
        if CandidateExists and Existing and not SameFileName(TPath.GetFullPath(OldPath),TPath.GetFullPath(NewPath)) then
          FAmbiguous.Add(Name+' | '+OldPath+' | '+NewPath);
      end;
      if Existing or CandidateExists then FFound.Add(Name+' | '+Path)
      else if (NewCount>0) or (ChangedCount>0) then FNeeded.Add(Name)
      else FHistorical.Add(Name);
      Query.Next;
    end;
    if FVersion=0 then Version:='не указана' else Version:=IntToStr(FVersion);
    FSummary := Format('Проверен источник «%s».', [FSource.Name]) + sLineBreak;
    if FNeeded.Count > 0 then
    begin
      FSummary := FSummary + Format('Архивов для докачки — %d', [FNeeded.Count]) + sLineBreak;
      for var I := 0 to Min(FNeeded.Count - 1, 5) do
        FSummary := FSummary + FNeeded[I] + sLineBreak;
      if FNeeded.Count > 6 then
        FSummary := FSummary + 'Полный список доступен по кнопке «Копировать имена архивов».' + sLineBreak;
      FSummary := FSummary + sLineBreak;
    end;
    FSummary := FSummary + Format('В индексе: %d записей, в том числе помеченных удалёнными: %d.%sНовых книг: %d. С изменёнными сведениями: %d.%s'+
      'Версия индекса: %s.%sФайлов найдено: %d. Для новых, изменённых и ранее пропущенных книг требуется докачать: %d.%s'+
      'Отсутствующих файлов только с прежними записями: %d. Одноимённых файлов в обеих папках: %d.',
      [FTotal,FDeleted,sLineBreak,FNewBooks,FChangedBooks,sLineBreak,Version,sLineBreak,FFound.Count,FNeeded.Count,sLineBreak,FHistorical.Count,FAmbiguous.Count]);
    if FIsMetabib then FSummary:=FSummary+sLineBreak+'Metabib используется как полный снимок каталога.';
    if FSkipped>0 then FSummary:=FSummary+sLineBreak+
      Format('Внимание: пропущено ошибочных записей или записей без файла: %d. Список неполный.',[FSkipped]);
    if FOriginalRootOffline then FSummary:=FSummary+sLineBreak+
      'Исходная папка книг сейчас недоступна: '+FSourceInfo.Root+'. Проверяем доступные архивы в папке докачки: '+
      FSource.BooksRoot+'. Само отсутствие прежнего диска не делает старые записи новыми.';
    if Assigned(BoundPackedCopy) then FSummary:=FSummary+sLineBreak+
      'Прежние файлы проверяются по сохранённым связям выбранного источника.'
    else if FLegacyPackedBaseline then FSummary:=FSummary+sLineBreak+
      Format('В упакованной копии сопоставлено с прежним индексом: %d записей.',[PackedMapped])
    else if Assigned(PackedDB) then FSummary:=FSummary+sLineBreak+
      Format('Сопоставлено с текущими файлами упакованной копии: %d записей. '+
        'Исходные сведения самой копии использованы для %d записей. '+
        'Удаления после сохранения этих сведений учитываются; для более ранних удалений нужен прежний индекс.',[PackedMapped,PackedProjected])
    else if FPreviousIndex then FSummary:=FSummary+sLineBreak+'Сравнение с сохранённым индексом этого источника.'
    else FSummary:=FSummary+sLineBreak+'Сравнение с текущим каталогом. Прежний полный индекс неизвестен: удалённые ранее записи могут выглядеть новыми.';
    FSummary:=FSummary+sLineBreak+'Сверяются ID, имена и форматы файлов; изменения — по названию, языку, размеру, дате и отметке удаления. '+
      'В список докачки входят и файлы для книг, пропущенных при прошлом обновлении. '+
      'Изменение содержимого архива с прежним именем без изменения индекса таким сравнением не определяется. '+
      'Наличие файла проверено без чтения всех книг внутри него. Книги и текущий каталог не изменены.';
  finally Iterator:=nil; UnresolvedExclusion.Free; ExcludedAlias.Free; PriorArtifact.Free;
    ReviewKeyQuery.Free; RecoveredQuery.Free; PublisherQuery.Free; SourceKeyQuery.Free; StateQuery.Free; StateDB.Free;
    BoundPackedCopy.Free; LegacyInput.Free;
    if PackedBatch then PackedDB.EndQueryBatch; PackedDB.Free;
    Availability.Free; Containers.Free; Query.Free; Insert.Free; DB.Free; end;
end;

function CopyReviewBook(const Source, Destination: IBookCollection; Book: TBookRecord;
  Cache: TImportCache; Genres: TDictionary<string,TGenreData>; CheckName: Boolean = False; PreferredID:Integer=0): Integer;
var Writer:IReviewedBookIDWriter; OriginalKey: TBookKey; Key: string; Genre: TGenreData;
begin
  OriginalKey:=Book.BookKey; Book.Authors:=Copy(Book.Authors); Book.Genres:=Copy(Book.Genres);
  for var I:=0 to High(Book.Genres) do
  begin
    Genre:=Book.Genres[I]; Key:=Genre.FB2GenreCode;
    if Key='' then Key:=Genre.GenreCode;
    if not Genres.TryGetValue(Key,Book.Genres[I]) then
    begin
      Book.Genres[I]:=Destination.EnsureGenre(Key,Genre.GenreAlias,Book.RootGenre.GenreAlias);
      Genres.Add(Key,Book.Genres[I]);
    end;
  end;
  if PreferredID>0 then
  begin
    if not Supports(Destination,IReviewedBookIDWriter,Writer) then
      raise ENotSupportedException.Create('Каталог не поддерживает сохранение проверенных номеров книг.');
    Result:=Writer.InsertReviewedBook(Book,PreferredID,Cache);
  end
  else Result:=Destination.InsertBook(Book,CheckName,False,Cache);
  if Result<>0 then
    for var Series in Source.GetBookSeries(OriginalKey) do
      Destination.AddBookSeries(Result,Series.SeriesTitle,Series.SeqNumber,Cache);
end;

function ReviewAllBooks(const Collection: IBookCollection): IBookIterator;
var Hide, Local: Boolean;
begin
  Hide:=Collection.GetHideDeleted; Local:=Collection.GetShowLocalOnly;
  Collection.SetHideDeleted(False); Collection.SetShowLocalOnly(False);
  try Result:=Collection.GetBookIterator(bmAll,True);
  finally Collection.SetHideDeleted(Hide); Collection.SetShowLocalOnly(Local); end;
end;

procedure UpdateReviewedMetadata(const Source, Destination: IBookCollection;
  const Incoming, Before: TBookRecord; const Folder: string; InsideNo: Integer;
  ReplacePayload: Boolean; Cache: TImportCache);
var Book: TBookRecord; Writer: IBookMergeMetadataDeltaUpdater;
begin
  if not Supports(Destination,IBookMergeMetadataDeltaUpdater,Writer) then
    raise ENotSupportedException.Create('Каталог не поддерживает обновление карточки.');
  Book:=Before;
  Book.Title:=Incoming.Title; Book.Lang:=Incoming.Lang; Book.Date:=Incoming.Date;
  Book.LibRate:=Incoming.LibRate; Book.KeyWords:=Incoming.KeyWords;
  Book.Series:=Incoming.Series; Book.SeqNumber:=Incoming.SeqNumber;
  Book.Translators:=Incoming.Translators; Book.Publisher:=Incoming.Publisher;
  Book.City:=Incoming.City; Book.PubYear:=Incoming.PubYear; Book.ISBN:=Incoming.ISBN;
  Book.PublisherSeries:=Incoming.PublisherSeries;
  Book.PublisherSeriesKnown:=Incoming.PublisherSeriesKnown;
  if bpIsDeleted in Incoming.BookProps then Include(Book.BookProps,bpIsDeleted)
  else Exclude(Book.BookProps,bpIsDeleted);
  if ReplacePayload then
  begin
    Book.Folder:=Folder; Book.FileName:=Incoming.FileName; Book.FileExt:=Incoming.FileExt;
    Book.InsideNo:=InsideNo; Book.Size:=Incoming.Size;
    Include(Book.BookProps,bpIsLocal);
  end;
  Book.Authors:=Copy(Incoming.Authors);
  for var I:=0 to High(Book.Authors) do
    Book.Authors[I]:=Destination.EnsureAuthor(Book.Authors[I]);
  Book.Genres:=Copy(Incoming.Genres);
  for var I:=0 to High(Book.Genres) do
  begin
    var Genre:=Book.Genres[I];
    var Code:=Genre.FB2GenreCode;
    if Code='' then Code:=Genre.GenreCode;
    Book.Genres[I]:=Destination.EnsureGenre(Code,Genre.GenreAlias,Incoming.RootGenre.GenreAlias);
  end;
  Writer.UpdateBookMetadataDelta(Before,Book,False);
  Destination.SetBookAuthors(Book.BookKey.BookID,Book.Authors,True);
  Destination.SetBookGenres(Book.BookKey.BookID,Book.Genres,True);
  for var Series in Source.GetBookSeries(Incoming.BookKey) do
    Destination.AddBookSeries(Book.BookKey.BookID,Series.SeriesTitle,Series.SeqNumber,Cache);
end;

procedure TLibraryUpdateReview.PreparePackedApplication(PreferNewRoot: Boolean;
  const Check: TProc; const Progress: TLibraryReviewProgress);
var
  Rows, Put: TSQLiteQuery;
  Book, Resolved: TBookRecord;
  ID, Done: Integer;
  Eligible, NeedPayload, PackPayload: Boolean;
  State, Reason, CheckedFile: string;
begin
  if FActionDB.QuerySingleInt('SELECT count(*) FROM (SELECT Key FROM ReviewPackedLocations GROUP BY Key HAVING count(*)>1)')>0 then
    raise EReadError.Create('Несколько упакованных карточек соответствуют одной записи издателя.');
  if FActionDB.QuerySingleInt('SELECT count(*) FROM (SELECT Key FROM ReviewRows GROUP BY Key HAVING count(*)>1)')>0 then
    raise EReadError.Create('В новом индексе есть повторяющиеся записи. Не удалось однозначно сопоставить книги.');

  FActionDB.ExecSQL('DROP TABLE IF EXISTS ApplyExcluded');
  FActionDB.ExecSQL('CREATE TABLE ApplyExcluded AS SELECT Key FROM ReviewExcluded');
  FActionDB.ExecSQL('CREATE UNIQUE INDEX ApplyExcludedKey ON ApplyExcluded(Key)');
  FActionDB.ExecSQL('INSERT OR IGNORE INTO ApplyExcluded SELECT p.Key FROM ReviewPrevious p '+
    'WHERE p.State=''excluded'' OR (p.State<>''missing'' AND NOT EXISTS '+
    '(SELECT 1 FROM ReviewPackedLocations l WHERE l.Key=p.Key))');
  FActionDB.ExecSQL('CREATE TABLE ApplyActions(BookID INTEGER PRIMARY KEY,TargetID INTEGER,Eligible INTEGER,'+
    'PackPayload INTEGER,State TEXT,Folder TEXT,InsideNo INTEGER,SourceKey TEXT,MissingReason TEXT)');
  Rows:=FActionDB.NewQuery('SELECT r.BookID,coalesce(l.BookID,0),e.Key IS NOT NULL,'+
    '(l.BookID IS NULL OR p.Key IS NULL OR p.PayloadStamp<>r.PayloadStamp OR p.Location<>r.PublisherLocation '+
    'OR p.State IN (''missing'',''missing-retained'') OR l.PendingPayload<>0),coalesce(p.SourceKey,'''') '+
    'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key LEFT JOIN ReviewPackedLocations l ON l.Key=r.Key '+
    'LEFT JOIN ApplyExcluded e ON e.Key=r.Key ORDER BY r.Location,r.BookID');
  Put:=nil;
  try
    Put:=FActionDB.NewQuery('INSERT INTO ApplyActions VALUES(?,?,?,?,?,?,?,?,?)');
    FActionDB.Start;
    try
      Rows.Open; Done:=0;
      while not Rows.Eof do
      begin
        Check;
        ID:=Rows.FieldAsInt(1);
        FSnapshot.GetBookRecord(CreateBookKey(Rows.FieldAsInt(0),FSnapshot.CollectionID),Book,True);
        Resolved:=Book; Eligible:=not Rows.FieldAsBoolean(2);
        State:='known'; Reason:=''; PackPayload:=False;
        NeedPayload:=Eligible and Rows.FieldAsBoolean(3) and not (bpIsDeleted in Book.BookProps);
        if not Eligible then
        begin
          State:='excluded'; Inc(FRemovedCount);
        end
        else if NeedPayload then
        begin
          try PackPayload:=FInventory.Resolve(Resolved,FSource.BooksRoot,PreferNewRoot,Reason,CheckedFile);
          except on E:EAbort do raise; on E:Exception do Reason:=E.Message; end;
          Check;
          if not PackPayload then
          begin
            if ID>0 then State:='missing-retained' else State:='missing';
            Eligible:=ID>0;
            if CheckedFile='' then CheckedFile:=Resolved.GetBookFileName;
            Reason:=CheckedFile+' | '+Book.FileName+Book.FileExt+' | '+Reason;
            Inc(FMissingCount);
          end;
        end;
        if Eligible and (ID=0) and not PackPayload then
        begin
          Eligible:=False;
          State:='missing';
        end;
        if Eligible and (ID=0) then Inc(FNewCards)
        else if Eligible and PackPayload then Inc(FUpdateCards);
        Put.Reset;
        Put.SetParam(0,Book.BookKey.BookID); Put.SetParam(1,ID);
        Put.SetParam(2,Eligible); Put.SetParam(3,PackPayload); Put.SetParam(4,State);
        Put.SetParam(5,Resolved.Folder); Put.SetParam(6,Resolved.InsideNo);
        Put.SetParam(7,Rows.FieldAsString(4)); Put.SetParam(8,Reason); Put.ExecSQL;
        Inc(Done);
        if Assigned(Progress) and ((Done mod 100=0) or (Done=FTotal)) then
          Progress('Проверка книг в архивах',Done,FTotal);
        Rows.Next;
      end;
      FActionDB.Commit;
    except
      FActionDB.Rollback;
      raise;
    end;
  finally
    Put.Free; Rows.Free;
  end;
  FIssuesReady:=True;
  FActionDB.ExecSQL('DROP TABLE IF EXISTS PackedOmitted');
  FActionDB.ExecSQL('CREATE TABLE PackedOmitted(BookID INTEGER PRIMARY KEY)');
  if FSource.Full then
  begin
    FActionDB.ExecSQL('INSERT INTO PackedOmitted SELECT l.BookID FROM ReviewPackedLocations l '+
      'JOIN ReviewPrevious p ON p.Key=l.Key WHERE NOT EXISTS (SELECT 1 FROM ReviewRows r WHERE r.Key=l.Key)');
    FUnlistedCount:=FActionDB.QuerySingleInt('SELECT count(*) FROM PackedOmitted');
  end;
  FApplySummary:=Format('Применить обновление «%s» и создать новую копию коллекции?%s'+
    'Новых книг: %d. Новых файлов для существующих книг: %d.%s'+
    'Исключённых записей: %d. Недостающих файлов: %d.%s'+
    'Прежняя коллекция останется доступна. Новые файлы упакуются по сохранённым настройкам.',
    [FSource.Name,sLineBreak,FNewCards,FUpdateCards,sLineBreak,FRemovedCount,FMissingCount,sLineBreak]);
  if FUnlistedCount>0 then
    FApplySummary:=FApplySummary+sLineBreak+Format('Записей, отсутствующих в полном индексе: %d. '+
      'Они останутся в прежней коллекции.',[FUnlistedCount]);
  FApplicationReady:=True;
end;

procedure TLibraryUpdateReview.PrepareApplication(const Target: IBookCollection;
  const SystemData: ISystemData; PreferNewRoot: Boolean; const Check: TProc;
  const Progress: TLibraryReviewProgress);
var DB, CopyDB: TSQLiteDatabase; Rows, Put, Lookup, Copies, CurrentLocation: TSQLiteQuery;
  Iterator: IPublisherSeriesIndexIterator; Item, Current, Resolved, CopyBook: TBookRecord;
  Key, Stamp, Namespace, Identity, Physical, Reason, State, Name, ExpectedKey, CheckedFile: string;
  Bound, Known, Changed, Eligible, KeepMetadata, OwnsFile, Verified, HadSourceCard, RetainPackedCopy: Boolean;
  ID, Matches, Done, DeltaID: Integer;
  Cache: TImportCache; Genres: TDictionary<string,TGenreData>;
  function MatchLive(const Column, Value: string): Integer;
  var Q: TSQLiteQuery;
  begin
    Result:=0; if Value='' then Exit;
    Q:=DB.NewQuery('SELECT min(BookID),count(*) FROM ApplyLive WHERE '+Column+'=?',[Value]);
    try Q.Open; Matches:=Q.FieldAsInt(1);
      if Matches>1 then raise EReadError.Create('Для записи найдено несколько разных карточек. Нужна проверка совпадений.');
      if Matches=1 then Result:=Q.FieldAsInt(0);
    finally Q.Free; end;
  end;
begin
  if not FReady or FApplied then raise EInvalidOperation.Create('Сначала проверьте новый индекс.');
  if FSkipped<>0 then raise EReadError.Create('В индексе пропущены ошибочные записи. Исправьте файл перед применением.');
  if FSource.Full and (FTotal=0) then raise EReadError.Create('Полный индекс пуст. Существующую коллекцию не изменяем.');
  if isOnlineCollection(Target.CollectionCode) then
    raise ENotSupportedException.Create('Применение через это окно пока рассчитано на локальные коллекции.');
  Bound:=FSource.CatalogSourceID<>'';
  if not Bound and (Length(LoadCatalogSources(Target))<>0) then
    raise EArgumentException.Create('Для объединённой коллекции выберите конкретный источник через «Изменить».');
  CheckTargetRevision(Target);
  FreeAndNil(FPlan); FreeAndNil(FActionLookup); FreeAndNil(FActionDB); FreeAndNil(FInventory);
  FDelta:=nil;
  if (FDeltaFile<>'') and FileExists(FDeltaFile) then TFile.Delete(FDeltaFile);
  FDeltaFile:=''; FApplicationReady:=False; FIssuesReady:=False;
  FOperationID:=GUIDToString(TGUID.NewGuid);
  FNewCards:=0; FUpdateCards:=0; FRemovedCount:=0; FMissingCount:=0; FUnlistedCount:=0;
  FInventory:=TLibraryUpdateInventory.Create(Check);
  FActionDB:=OpenWorkDatabase(FAnalysisFile); DB:=FActionDB;
  if FPacked and not Bound then
  begin
    PreparePackedApplication(PreferNewRoot,Check,Progress);
    Exit;
  end;
  if FPacked and not FPreviousIndex then
    raise EReadError.Create('Для упакованной копии источника нужен прежний индекс. Восстановите его и проверьте обновление заново.');
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyRetainedCopy');
  if FPacked then
    DB.ExecSQL('CREATE TABLE ApplyRetainedCopy(BookID INTEGER PRIMARY KEY,Folder TEXT,FileName TEXT,Ext TEXT,InsideNo INTEGER,BookSize INTEGER)');
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyActions'); DB.ExecSQL('DROP TABLE IF EXISTS ApplyLive');
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyDeltaInput');
  DB.ExecSQL('CREATE TABLE ApplyLive(Key TEXT,BookID INTEGER,Identity TEXT,Physical TEXT,LibID TEXT)');
  DB.ExecSQL('CREATE INDEX ApplyLiveKey ON ApplyLive(Key)');
  DB.ExecSQL('CREATE INDEX ApplyLiveIdentity ON ApplyLive(Identity)');
  DB.ExecSQL('CREATE INDEX ApplyLivePhysical ON ApplyLive(Physical)');
  Put:=DB.NewQuery('INSERT INTO ApplyLive VALUES(?,?,?,?,?)');
  try
    Namespace:=VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY));
    if Namespace='' then Namespace:=FSourceInfo.LibraryNamespace;
    Iterator:=Target.GetPublisherSeriesIndexIterator; Done:=0;
    DB.Start;
    try
      while Iterator.Next(Item,Stamp) do
      begin
        Check; Key:=ReviewBookKey(Item,Namespace,Target.CollectionRoot);
        Put.Reset; Put.SetParam(0,Key); Put.SetParam(1,Item.BookKey.BookID);
        Put.SetParam(2,BookLibraryIdentity(Item,Namespace)); Put.SetParam(3,BookPhysicalIdentity(Item)); Put.SetParam(4,Item.LibID); Put.ExecSQL;
        Inc(Done);
        if Assigned(Progress) and (Done mod 1000=0) then Progress('Проверка текущих карточек',Done,Iterator.RecordCount);
      end;
      DB.Commit;
    except DB.Rollback; raise; end;
  finally Iterator:=nil; Put.Free; end;
  if not Bound and FPreviousIndex then
  begin
    // A published empty-ID book can live in an independent download folder.
    // Match its saved publisher key only through a unique exact old physical
    // locator and the same empty raw ID. Missing/deleted rows gain no match.
    DB.ExecSQL('CREATE INDEX ApplyLiveEmptyPhysical ON ApplyLive(Physical) WHERE LibID=''''');
    DB.ExecSQL('CREATE INDEX ReviewPreviousEmptyPhysical ON ReviewPrevious(Physical) WHERE LibID=''''');
    var EmptyMatch:='p.LibID='''' AND l.LibID='''' AND p.Physical<>'''' AND p.Physical=l.Physical '+
      'AND p.State IN (''known'',''missing-retained'') AND '+
      'NOT EXISTS(SELECT 1 FROM ApplyLive exact WHERE exact.Key=p.Key) AND '+
      'NOT EXISTS(SELECT 1 FROM ReviewPrevious exact WHERE exact.Key=l.Key)';
    if DB.QuerySingleInt('SELECT count(*) FROM ReviewPrevious p JOIN ApplyLive l ON '+EmptyMatch+
      ' WHERE p.Copies<>1 OR (SELECT count(*) FROM ReviewPrevious x WHERE x.LibID='''' AND x.Physical=p.Physical)<>1 '+
      'OR (SELECT count(*) FROM ApplyLive x WHERE x.LibID='''' AND x.Physical=l.Physical)<>1')<>0 then
      raise EReadError.Create('Для прежнего файла без LIBID найдено несколько карточек. Обновление неоднозначно.');
    DB.ExecSQL('UPDATE ApplyLive AS l SET Key=(SELECT p.Key FROM ReviewPrevious p WHERE '+EmptyMatch+') '+
      'WHERE EXISTS(SELECT 1 FROM ReviewPrevious p WHERE '+EmptyMatch+')');
  end;
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyExcluded');
  DB.ExecSQL('CREATE TABLE ApplyExcluded(Key TEXT PRIMARY KEY) WITHOUT ROWID');
  DB.ExecSQL('INSERT OR IGNORE INTO ApplyExcluded SELECT Key FROM ReviewExcluded');
  if Bound then
  begin
    DB.ExecSQL('ATTACH DATABASE ? AS previousLinks',[FTargetFile]);
    try
      DB.ExecSQL('INSERT OR IGNORE INTO ApplyExcluded SELECT p.Key FROM ReviewPrevious p '+
        'WHERE p.State=''excluded'' OR (p.State<>''missing'' AND NOT EXISTS '+
        '(SELECT 1 FROM previousLinks.CatalogSourceBooks l JOIN previousLinks.Books b ON b.BookID=l.BookID WHERE l.SourceKey=p.SourceKey))');
    finally DB.ExecSQL('DETACH DATABASE previousLinks'); end;
  end
  else
    DB.ExecSQL('INSERT OR IGNORE INTO ApplyExcluded SELECT p.Key FROM ReviewPrevious p '+
      'WHERE p.State=''excluded'' OR (p.State<>''missing'' AND NOT EXISTS (SELECT 1 FROM ApplyLive l WHERE l.Key=p.Key))');
  DB.ExecSQL('CREATE TABLE ApplyActions(BookID INTEGER PRIMARY KEY,TargetID INTEGER,Eligible INTEGER,Changed INTEGER,'+
    'KeepMetadata INTEGER,State TEXT,Folder TEXT,InsideNo INTEGER,SourceKey TEXT,MissingReason TEXT)');
  DB.ExecSQL('CREATE TABLE ApplyDeltaInput(DeltaID INTEGER PRIMARY KEY,InputID INTEGER)');
  Rows:=DB.NewQuery('SELECT r.BookID,r.Key,p.Key IS NOT NULL,coalesce(p.State,''known''),'+
    '(p.Key IS NULL OR p.Stamp<>r.Stamp OR p.Physical<>r.Physical OR p.State IN (''missing'',''missing-retained'')),'+
    'coalesce(p.SourceKey,''''),coalesce(p.Physical,''''),coalesce(p.Copies,1),coalesce(p.Container,''''),coalesce(p.InsideNo,0),'+
    'EXISTS(SELECT 1 FROM ApplyExcluded e WHERE e.Key=r.Key),'+
    '(p.PackedCopy<>0 AND p.PayloadStamp=r.PayloadStamp AND p.Location=r.PublisherLocation AND p.State=''known'') '+
    'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key ORDER BY r.Location,r.BookID');
  Put:=DB.NewQuery('INSERT INTO ApplyActions VALUES(?,?,?,?,?,?,?,?,?,?)');
  Copies:=nil; CopyDB:=nil; CurrentLocation:=nil;
  try
    CopyDB:=OpenWorkDatabase(FTargetFile,True);
    CurrentLocation:=CopyDB.NewQuery('SELECT Folder,InsideNo FROM Books WHERE BookID=?');
    if Bound then
    begin
      Copies:=CopyDB.NewQuery('SELECT Root,Folder,FileName,Ext,InsideNo,BookSize FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?');
    end;
    Rows.Open; Done:=0; DB.Start;
    try
      while not Rows.Eof do
      begin
        Check; CheckSpace; ID:=0; Known:=Rows.FieldAsBoolean(2); State:=Rows.FieldAsString(3);
        Changed:=Rows.FieldAsBoolean(4); Eligible:=True; KeepMetadata:=False; Reason:=''; CheckedFile:='';
        RetainPackedCopy:=False;
        if Rows.FieldAsInt(7)>1 then raise EReadError.Create('В прежнем индексе повторяются идентификаторы файлов. Обновление неоднозначно.');
        FSnapshot.GetBookRecord(CreateBookKey(Rows.FieldAsInt(0),FSnapshot.CollectionID),Item,True);
        if Bound then
        begin
          if Known then Stamp:=Rows.FieldAsString(5)
          else
          begin
            var EntrySource:=Default(TMergeSource); EntrySource.ID:=FSourceInfo.ID; EntrySource.Root:=FSourceInfo.Root;
            Stamp:=MergeSourceKeyAtLocation(EntrySource,Item,TPath.Combine(Item.CollectionRoot,Item.Folder));
          end;
          ID:=Target.GetCatalogBookID(Stamp);
        end
        else ID:=MatchLive('Key',Rows.FieldAsString(1));
        // A matching card owned by another source is not an existing copy
        // of this source. Remember ownership before identity fallback.
        HadSourceCard:=ID>0;
        if (ID=0) and ((Known and (State<>'missing')) or Rows.FieldAsBoolean(10)) then
        begin Eligible:=False; State:='excluded'; Inc(FRemovedCount); end;
        Resolved:=Item;
        if Eligible and Changed and (ID=0) and Bound then
        begin
          ID:=MatchLive('Identity',BookLibraryIdentity(Item,FSourceInfo.LibraryNamespace));
          if ID=0 then ID:=MatchLive('Physical',BookPhysicalIdentity(Item));
        end;
        OwnsFile:=True;
        if Eligible and Changed and (ID>0) then
        begin
          Target.GetBookRecord(CreateBookKey(ID,Target.CollectionID),Current,True);
          Resolved:=Item;
          if (FSource.BooksRoot<>'') and not TPath.IsPathRooted(Item.Folder) then
          begin
            var Candidate:=Item; Candidate.CollectionRoot:=IncludeTrailingPathDelimiter(FSource.BooksRoot);
            if FileExists(Candidate.GetBookFileName) and (PreferNewRoot or not FileExists(Item.GetBookFileName)) then Resolved:=Candidate;
          end;
          OwnsFile:=not Bound or (not FPacked and ((BookPhysicalIdentity(Current)=Rows.FieldAsString(6)) or
            (BookPhysicalIdentity(Current)=BookPhysicalIdentity(Resolved)) or
            not FileExists(Current.GetBookFileName)));
          if Bound and not OwnsFile then
          begin
            Copies.Reset; Copies.SetParam(0,Stamp); Copies.SetParam(1,ID); Copies.Open;
            if not Copies.Eof then
            begin
              CopyBook:=Default(TBookRecord); CopyBook.CollectionRoot:=Copies.FieldAsString(0);
              CopyBook.Folder:=Copies.FieldAsString(1); CopyBook.FileName:=Copies.FieldAsString(2);
              CopyBook.FileExt:=Copies.FieldAsString(3); CopyBook.InsideNo:=Copies.FieldAsInt(4);
              OwnsFile:=BookPhysicalIdentity(CopyBook)=BookPhysicalIdentity(Current);
              RetainPackedCopy:=FPacked and Rows.FieldAsBoolean(11) and FileExists(CopyBook.GetBookFileName);
              if RetainPackedCopy then
              begin
                var Folder:=TPath.Combine(CopyBook.CollectionRoot,CopyBook.Folder);
                if CopyBook.Folder.EndsWith(PathDelim) then Folder:=IncludeTrailingPathDelimiter(Folder);
                DB.ExecSQL('INSERT INTO ApplyRetainedCopy VALUES(?,?,?,?,?,?)',
                  [Item.BookKey.BookID,Folder,CopyBook.FileName,CopyBook.FileExt,CopyBook.InsideNo,Copies.FieldAsInt(5)]);
              end;
            end;
          end;
          KeepMetadata:=not OwnsFile;
        end;
        if Eligible and Changed and not RetainPackedCopy and not (bpIsDeleted in Item.BookProps) then
        begin
          Verified:=False;
          try Verified:=FInventory.Resolve(Resolved,FSource.BooksRoot,PreferNewRoot,Reason,CheckedFile);
          except on E:EAbort do raise; on E:Exception do Reason:=E.Message; end;
          Check;
          if not Verified then
          begin
            if HadSourceCard then State:='missing-retained' else State:='missing';
            Inc(FMissingCount);
            Name:=Item.FileName;
            if not SameText(ExtractFileExt(Name),Item.FileExt) then Name:=Name+Item.FileExt;
            if CheckedFile='' then CheckedFile:=Resolved.GetBookFileName;
            Reason:=CheckedFile+' | '+Name+' | '+Reason;
            if not HadSourceCard then Eligible:=False
            else begin KeepMetadata:=True; Changed:=False; end;
          end
          else State:='known';
        end;
        if not FPacked and not FSource.Full and Known and (Rows.FieldAsString(3)<>'missing') and
          (Rows.FieldAsString(3)<>'missing-retained') then Changed:=False;
        if FPacked and Changed and (bpIsDeleted in Item.BookProps) then
        begin
          // The bound route retains installed copies of the other sources.
          // A tombstone does not supply a new payload for this source.
          Changed:=False;
          if not HadSourceCard then State:='missing';
        end;
        if Eligible and not Changed and (ID>0) then
        begin
          if Bound then
          begin Resolved.Folder:=Rows.FieldAsString(8); Resolved.InsideNo:=Rows.FieldAsInt(9); end
          else
          begin
            CurrentLocation.Reset; CurrentLocation.SetParam(0,ID); CurrentLocation.Open;
            Resolved.Folder:=CurrentLocation.FieldAsString(0); Resolved.InsideNo:=CurrentLocation.FieldAsInt(1);
          end;
        end;
        if Eligible and (ID>0) and KeepMetadata and not Bound then Resolved:=Current;
        ExpectedKey:=Rows.FieldAsString(5);
        if FPacked and HadSourceCard then ExpectedKey:=Stamp
        else if not Known or (Eligible and Changed) then
        begin
          var EntrySource:=Default(TMergeSource); EntrySource.ID:=FSourceInfo.ID; EntrySource.Root:=FSourceInfo.Root;
          ExpectedKey:=MergeSourceKeyAtLocation(EntrySource,Resolved,TPath.Combine(Resolved.CollectionRoot,Resolved.Folder));
        end;
        Put.Reset; Put.SetParam(0,Item.BookKey.BookID); Put.SetParam(1,ID); Put.SetParam(2,Eligible);
        Put.SetParam(3,Changed); Put.SetParam(4,KeepMetadata); Put.SetParam(5,State);
        Put.SetParam(6,Resolved.Folder); Put.SetParam(7,Resolved.InsideNo); Put.SetParam(8,ExpectedKey);
        Put.SetParam(9,Reason); Put.ExecSQL;
        if Eligible and Changed then
          if ID=0 then Inc(FNewCards) else Inc(FUpdateCards);
        Inc(Done); if Assigned(Progress) and (Done mod 100=0) then Progress('Проверка книг в архивах',Done,FTotal);
        Rows.Next;
      end;
      DB.Commit; FIssuesReady:=True;
    except DB.Rollback; raise; end;
  finally Rows.Free; Put.Free; Copies.Free; CurrentLocation.Free; CopyDB.Free; end;
  DB.ExecSQL('INSERT OR IGNORE INTO ApplyExcluded SELECT r.Key FROM ReviewRows r JOIN ApplyActions a ON a.BookID=r.BookID WHERE a.State=''excluded''');
  // Retain personal fields by the reviewed artifact mapping before a full
  // rebuild. Legacy extras omit annotations and match only the first LibID.
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyPersonal');
  DB.ExecSQL('ATTACH DATABASE ? AS personalSource',[FTargetFile]);
  try
    if FSource.Full and not Bound then
      FUnlistedCount:=DB.QuerySingleInt('SELECT count(*) FROM ApplyLive l JOIN personalSource.Books b ON b.BookID=l.BookID '+
        'WHERE coalesce(b.IsLocal,0)=0 AND NOT EXISTS(SELECT 1 FROM ReviewRows r WHERE r.Key=l.Key)');
    DB.ExecSQL('CREATE TABLE ApplyPersonal AS SELECT a.BookID,b.Rate,b.Progress,b.Review,b.Annotation '+
      'FROM ApplyActions a JOIN personalSource.Books b ON b.BookID=a.TargetID WHERE a.Eligible<>0');
    DB.ExecSQL('CREATE UNIQUE INDEX ApplyPersonalBook ON ApplyPersonal(BookID)');
  finally DB.ExecSQL('DETACH DATABASE personalSource'); end;
  Name:=TPath.Combine(FPrepared.Folder,'apply-'+TGUID.NewGuid.ToString+'.hlc2');
  if FileExists(Name) then raise EWriteError.Create('Файл подготовки уже существует.');
  FDeltaFile:=Name;
  TBookCollection_SQLite.CreateCollection(SystemData,FDeltaFile,CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2],FPrepared.Folder);
  FDelta:=OpenCatalogSnapshot(FSourceInfo,FDeltaFile,SystemData,FPrepared.Folder);
  Cache:=TImportCache.Create; Genres:=TDictionary<string,TGenreData>.Create;
  Lookup:=DB.NewQuery('SELECT a.TargetID,a.KeepMetadata,a.Folder,a.InsideNo'+
    IfThen(FPacked,',c.BookID,c.Folder,c.FileName,c.Ext,c.InsideNo,c.BookSize','')+
    ' FROM ApplyActions a'+IfThen(FPacked,' LEFT JOIN ApplyRetainedCopy c ON c.BookID=a.BookID','')+' WHERE a.BookID=?');
  Rows:=DB.NewQuery('SELECT BookID FROM ApplyActions WHERE Eligible<>0'+
    IfThen(Bound or not FSource.Full,' AND Changed<>0',' AND KeepMetadata<>0 AND TargetID>0')+' ORDER BY BookID');
  try
    FDelta.BeginBulkOperation; FDelta.StartBatchUpdate;
    try
      Rows.Open;
      while not Rows.Eof do
      begin
        Check; FSnapshot.GetBookRecord(CreateBookKey(Rows.FieldAsInt(0),FSnapshot.CollectionID),Item,True);
        Lookup.Reset; Lookup.SetParam(0,Item.BookKey.BookID); Lookup.Open;
        if not Bound and Lookup.FieldAsBoolean(1) and (Lookup.FieldAsInt(0)>0) then
        begin
          Target.GetBookRecord(CreateBookKey(Lookup.FieldAsInt(0),Target.CollectionID),Resolved,True);
          // Keep personal metadata from the existing card, with its series.
          DeltaID:=CopyReviewBook(Target,FDelta,Resolved,Cache,Genres);
        end
        else
        begin
          Item.Folder:=Lookup.FieldAsString(2); Item.InsideNo:=Lookup.FieldAsInt(3);
          if FPacked and not Lookup.FieldIsNull(4) then
          begin
            Item.Folder:=Lookup.FieldAsString(5); Item.FileName:=Lookup.FieldAsString(6);
            Item.FileExt:=Lookup.FieldAsString(7); Item.InsideNo:=Lookup.FieldAsInt(8);
            Item.Size:=Lookup.FieldAsInt(9);
          end;
          DeltaID:=CopyReviewBook(FSnapshot,FDelta,Item,Cache,Genres);
        end;
        DB.ExecSQL('INSERT INTO ApplyDeltaInput VALUES(?,?)',[DeltaID,Rows.FieldAsInt(0)]); Rows.Next;
      end;
      FDelta.AfterBatchUpdate; FDelta.EndBulkOperation(True);
    except if FDelta.InBulkOperation then FDelta.EndBulkOperation(False); raise; end;
  finally FDelta.FinishBatchUpdate; Rows.Free; Lookup.Free; Genres.Free; Cache.Free; end;
  if Bound then
  begin
    if FPacked then
    begin
      if DB.QuerySingleInt('SELECT count(*) FROM (SELECT a.SourceKey FROM ApplyDeltaInput d '+
        'JOIN ApplyActions a ON a.BookID=d.InputID GROUP BY a.SourceKey HAVING count(*)>1)')>0 then
        raise EReadError.Create('Несколько файлов обновления относятся к одной копии источника.');
      // Merge reads stable source keys from its delta, rather than deriving
      // a second identity from the selected download or packed folder.
      FDelta:=nil;
      var DeltaDB:=OpenWorkDatabase(FDeltaFile);
      try
        DeltaDB.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
        DeltaDB.ExecSQL('CREATE TABLE LibraryUpdateSourceKeys(BookID INTEGER PRIMARY KEY,SourceKey TEXT NOT NULL)');
        DeltaDB.ExecSQL('INSERT INTO LibraryUpdateSourceKeys SELECT d.DeltaID,a.SourceKey '+
          'FROM review.ApplyDeltaInput d JOIN review.ApplyActions a ON a.BookID=d.InputID');
      finally DeltaDB.Free; end;
      FDelta:=OpenCatalogSnapshot(FSourceInfo,FDeltaFile,SystemData,FPrepared.Folder);
    end;
    FActionLookup:=DB.NewQuery('SELECT a.TargetID,a.KeepMetadata'+
      IfThen(FPacked,',EXISTS(SELECT 1 FROM ApplyRetainedCopy c WHERE c.BookID=a.BookID)','')+
      ' FROM ApplyDeltaInput d JOIN ApplyActions a ON a.BookID=d.InputID WHERE d.DeltaID=?');
    FPlan:=BuildBoundPlan(Target,SystemData);
    FPlan.Preview(nil,function:Boolean begin Check; Result:=False; end);
    FNewCards:=FPlan.NewBooks;
  end;
  Check;
  CheckTargetRevision(Target);
  FApplySummary:=Format('Применить обновление «%s»?%sНовых карточек: %d. Обновляемых записей/копий: %d.%s'+
    'Ранее удалённых записей не возвращаем: %d. Файлов пока нет или книга в архиве не найдена: %d.%s'+
    'Сохраняются личные данные и прежние папки. Сами книги и архивы не изменяются. Недокачанные книги можно добавить при следующей проверке.',
    [FSource.Name,sLineBreak,FNewCards,FUpdateCards,sLineBreak,FRemovedCount,FMissingCount,sLineBreak]);
  if FPacked then FApplySummary:=Format('Применить обновление источника «%s» в отдельной упакованной копии?%s'+
    'Новых карточек: %d. Обновляемых копий: %d. Недостающих файлов: %d.%s'+
    'Прежняя коллекция останется доступна. Новые файлы упакуются по сохранённым настройкам.',
    [FSource.Name,sLineBreak,FNewCards,FUpdateCards,FMissingCount,sLineBreak]);
  if FUnlistedCount>0 then FApplySummary:=FApplySummary+sLineBreak+
    Format('Прежних записей, которых нет в полном новом индексе: %d. Они исчезнут из каталога; файлы останутся на месте.',[FUnlistedCount]);
  if FOriginalRootOffline then
    if FPacked then FApplySummary:=FApplySummary+sLineBreak+
      'Прежняя папка книг недоступна. Упакованные файлы остаются доступны, новые файлы берутся из папки докачки.'
    else FApplySummary:=FApplySummary+sLineBreak+
      'Прежняя папка книг недоступна. Новые книги добавляются из указанной папки докачки. Для чтения прежних файлов потребуется снова подключить их диск или папку.';
  FApplicationReady:=True;
end;

function TLibraryUpdateReview.BuildBoundPlan(const Target: IBookCollection;
  const SystemData: ISystemData): TCollectionMergePlan;
var Sources: TMergeSources;
begin
  SetLength(Sources,1);
  Sources[0].ID:=FSourceInfo.ID; Sources[0].Name:=FSourceInfo.Name;
  Sources[0].Root:=FSourceInfo.Root; Sources[0].LibraryNamespace:=FSourceInfo.LibraryNamespace;
  Sources[0].Collection:=FDelta; Sources[0].DatabaseFile:=FDeltaFile;
  Result:=TCollectionMergePlan.Create(Target,Sources,SystemData,mpSourcePriority);
  Result.BookLookup:=function(const Source:TMergeSource; const Book:TBookRecord):Integer
  begin
    FActionLookup.Reset; FActionLookup.SetParam(0,Book.BookKey.BookID); FActionLookup.Open;
    Result:=FActionLookup.FieldAsInt(0);
  end;
  Result.BookChoice:=procedure(const Source:TMergeSource; const Incoming,Existing:TBookRecord; var KeepFile,KeepMetadata:Boolean)
  begin
    FActionLookup.Reset; FActionLookup.SetParam(0,Incoming.BookKey.BookID); FActionLookup.Open;
    KeepMetadata:=FActionLookup.FieldAsBoolean(1);
    KeepFile:=KeepMetadata;
    if FPacked and FActionLookup.FieldAsBoolean(2) then KeepFile:=True;
  end;
end;

procedure CheckReviewOutputSpace(const Folder: string; Needed: UInt64); forward;

function TLibraryUpdateReview.MissingDetails(Maximum: Integer): string;
var Rows: TSQLiteQuery; Count: Integer;
begin
  Result:='';
  if not FIssuesReady or (FMissingCount=0) or not Assigned(FActionDB) then Exit;
  Maximum:=System.Math.EnsureRange(Maximum,1,20);
  Result:=Format('Не удалось добавить или обновить книг: %d. Архив | книга | причина:',[FMissingCount]);
  Rows:=FActionDB.NewQuery('SELECT MissingReason FROM ApplyActions WHERE MissingReason<>'''' ORDER BY BookID LIMIT ?',[Maximum]);
  try
    Rows.Open; Count:=0;
    while not Rows.Eof do
    begin Result:=Result+sLineBreak+Rows.FieldAsString(0); Inc(Count); Rows.Next; end;
    if Count<FMissingCount then Result:=Result+sLineBreak+Format('Ещё: %d. Нажмите «Сохранить пропуски…» для полного списка.',[FMissingCount-Count]);
  finally Rows.Free; end;
end;

procedure TLibraryUpdateReview.SaveMissingReport(const FileName: string);
var Rows: TSQLiteQuery; Writer: TStreamWriter; Count: Integer;
begin
  if not FIssuesReady or (FMissingCount=0) or not Assigned(FActionDB) then
    raise EInvalidOperation.Create('Нет подготовленного списка пропущенных книг.');
  CheckSpace;
  var OutputFolder:=TPath.GetDirectoryName(TPath.GetFullPath(FileName));
  CheckReviewOutputSpace(OutputFolder,0);
  Rows:=FActionDB.NewQuery('SELECT MissingReason FROM ApplyActions WHERE MissingReason<>'''' ORDER BY BookID');
  try
    Rows.Open; Writer:=TStreamWriter.Create(FileName,False,TEncoding.UTF8);
    try
      Writer.WriteLine('Пропущенные книги при проверке обновления «'+FSource.Name+'».');
      Writer.WriteLine('Архив | книга | причина. В этом списке нет намеренно исключённых записей.');
      Writer.WriteLine(Format('Всего: %d.',[FMissingCount])); Count:=0;
      while not Rows.Eof do
      begin
        if Count mod 1000=0 then begin CheckSpace; CheckReviewOutputSpace(OutputFolder,0); end;
        Writer.WriteLine(Rows.FieldAsString(0)); Inc(Count); Rows.Next;
      end;
      Writer.WriteLine(Format('Конец списка. Записей: %d.',[Count]));
    finally Writer.Free; end;
  finally Rows.Free; end;
end;

procedure CheckReviewOutputSpace(const Folder: string; Needed: UInt64);
var Parent: string; Free, Total: UInt64;
begin
  Parent:=Folder;
  while not DirectoryExists(Parent) do
  begin
    var Next:=TPath.GetDirectoryName(Parent);
    if (Next='') or SameFileName(Next,Parent) then raise EDirectoryNotFoundException.Create(Folder);
    Parent:=Next;
  end;
  if not GetDiskFreeSpaceEx(PChar(Parent),Free,Total,nil) then RaiseLastOSError;
  if Free<Needed then raise EWriteError.Create('Недостаточно места для сохранения состояния обновления.');
  if Free-Needed<UInt64(512)*1024*1024 then raise EWriteError.Create('Не хватает резерва места для обновления.');
end;

procedure TLibraryUpdateReview.CleanCache;
var Folder: string;
begin
  if not FCacheOwned or FCachePublished then Exit;
  Folder:=TPath.GetDirectoryName(FPublishedSource.CacheFile);
  for var Name in TArray<string>.Create(FPublishedSource.CacheFile,FCacheInput) do
    if Name<>'' then
      for var Suffix in TArray<string>.Create('','-wal','-shm','-journal') do
        if FileExists(Name+Suffix) then try TFile.Delete(Name+Suffix); except end;
  try TDirectory.Delete(Folder,False); except end;
  FCacheOwned:=False;
end;

procedure TLibraryUpdateReview.SeedPackedCache(const SystemData: ISystemData; const Check: TProc);
var
  Source, Cached: IBookCollection;
  Rows: TSQLiteQuery;
  Publisher: TPackingPublisherState;
  Book: TBookRecord;
  Cache: TImportCache;
  Genres: TDictionary<string,TGenreData>;
  Data: TSQLiteDatabase;
begin
  // The first incremental delivery needs a raw baseline for books outside
  // that delivery. Their cached IDs deliberately match ReviewPrevious.BookID.
  TBookCollection_SQLite.CreateCollection(SystemData,FPublishedSource.CacheFile,CT_EXTERNAL_LOCAL_FB,
    Settings.SystemFileName[sfGenresFB2],FPrepared.Folder);
  Source:=OpenCatalogSnapshot(FSourceInfo,FTargetFile,SystemData,FPrepared.Folder);
  Cached:=OpenCatalogSnapshot(FPublishedSource,FPublishedSource.CacheFile,SystemData,FPrepared.Folder);
  Rows:=FActionDB.NewQuery('SELECT DISTINCT l.BookID FROM ReviewPackedLocations l JOIN ReviewPrevious p ON p.Key=l.Key '+
    'WHERE p.BookID=l.BookID ORDER BY l.BookID');
  Cache:=nil; Genres:=nil;
  try
    Cache:=TImportCache.Create;
    Genres:=TDictionary<string,TGenreData>.Create;
    Cached.BeginBulkOperation;
    try
      Cached.StartBatchUpdate;
      Rows.Open;
      while not Rows.Eof do
      begin
        Check;
        var ID:=Rows.FieldAsInt(0);
        if not ReadPackingPublisher(FRevisionDB,ID,Publisher) then
          raise EReadError.Create('Исходные сведения упакованной книги больше недоступны.');
        Source.GetBookRecord(CreateBookKey(ID,Source.CollectionID),Book,True);
        Book.Folder:=Publisher.Book.Folder; Book.FileName:=Publisher.Book.FileName;
        Book.FileExt:=Publisher.Book.FileExt; Book.InsideNo:=Publisher.Book.InsideNo;
        Book.Size:=Publisher.Book.Size; Book.Date:=Publisher.Book.Date;
        Book.Title:=Publisher.Book.Title; Book.Lang:=Publisher.Book.Lang;
        if bpIsDeleted in Publisher.Book.BookProps then Include(Book.BookProps,bpIsDeleted)
        else Exclude(Book.BookProps,bpIsDeleted);
        Book.Rate:=0; Book.Progress:=0; Book.Review:=''; Book.Annotation:='';
        if CopyReviewBook(Source,Cached,Book,Cache,Genres,False,ID)<>ID then
          raise EWriteError.Create('Не удалось сохранить исходную запись упакованной книги.');
        Rows.Next;
      end;
      Cached.AfterBatchUpdate;
      Cached.EndBulkOperation(True);
    except
      if Cached.InBulkOperation then Cached.EndBulkOperation(False);
      raise;
    end;
  finally
    Cached.FinishBatchUpdate;
    Rows.Free; Genres.Free; Cache.Free;
    Cached:=nil; Source:=nil;
  end;
  // Keep the publisher locator for entries outside the first incremental
  // package as well. That package cannot reconstruct their external paths.
  Data:=OpenWorkDatabase(FPublishedSource.CacheFile);
  try
    Data.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
    Data.ExecSQL('CREATE TABLE LibraryUpdatePublisherLocations(BookID INTEGER PRIMARY KEY,Location TEXT NOT NULL)');
    Data.ExecSQL('CREATE TABLE LibraryUpdateReviewKeys(BookID INTEGER PRIMARY KEY,Key TEXT NOT NULL)');
    Data.ExecSQL('INSERT INTO LibraryUpdatePublisherLocations SELECT DISTINCT p.BookID,p.Location '+
      'FROM review.ReviewPrevious p JOIN review.ReviewPackedLocations l ON l.Key=p.Key AND l.BookID=p.BookID');
    Data.ExecSQL('INSERT INTO LibraryUpdateReviewKeys SELECT DISTINCT p.BookID,p.Key '+
      'FROM review.ReviewPrevious p JOIN review.ReviewPackedLocations l ON l.Key=p.Key AND l.BookID=p.BookID');
  finally Data.Free; end;
end;

procedure TLibraryUpdateReview.PrepareCache(const Check: TProc; const Progress: TLibraryReviewProgress);
var Folder, Base: string; SourceDB, Output: TSQLiteDatabase; Cached: IBookCollection;
  Rows: TSQLiteQuery; Book: TBookRecord; ID, Done, Total: Integer;
  Cache: TImportCache; Genres: TDictionary<string,TGenreData>; Writer: IBookImportedLocationWriter;
  MergeSource: TMergeSource; Expected, Generated: string;
begin
  Check; CheckSpace; CleanCache;
  if Assigned(Progress) then Progress('Подготовка состояния источника',0,0);
  FPublishedSource:=FSourceInfo; FPublishedSource.CacheVersion:=TCatalogSource.NewID;
  FPublishedSource.UpdateProfileID:=FSource.ID;
  FPublishedSource.LibraryNamespace:=VarToStr(FSnapshot.GetProperty(PROP_SOURCE_LIBRARY));
  Folder:=TPath.GetDirectoryName(FPublishedSource.CacheFile);
  Base:=FDatabaseFile;
  if not FSource.Full then
    if FPreviousIndex then Base:=FPreviousFile else Base:=FTargetFile;
  CheckReviewOutputSpace(Folder,UInt64(TFile.GetSize(Base))+UInt64(TFile.GetSize(FPrepared.FileName)));
  ForceDirectories(TPath.GetDirectoryName(Folder));
  if not CreateDirectory(PChar(Folder),nil) then RaiseLastOSError;
  FCacheOwned:=True;
  FCacheInput:=TPath.Combine(Folder,'source-'+TPath.GetFileName(FPrepared.FileName));
  if FPacked and not FSource.Full and not FPreviousIndex then
    SeedPackedCache(DMUser.GetSystemDBConnection,Check)
  else
  begin
    SourceDB:=OpenWorkDatabase(Base,True);
    try
      SourceDB.BackupTo(FPublishedSource.CacheFile,procedure(Done,Total:Integer) begin
        Check; CheckReviewOutputSpace(Folder,0);
        if Assigned(Progress) then Progress('Сохранение состояния источника',Done,Total);
      end);
    finally SourceDB.Free; end;
  end;
  TFile.Copy(FPrepared.FileName,FCacheInput,False);
  if not SameText(THashSHA2.GetHashStringFromFile(FCacheInput),FPrepared.SHA256) then
    raise EReadError.Create('Не совпала контрольная сумма сохранённого индекса.');
  FPublishedSource.INPXFile:=FCacheInput;
  Output:=OpenWorkDatabase(FPublishedSource.CacheFile);
  try Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateAvailability(BookID INTEGER PRIMARY KEY,State TEXT NOT NULL)');
  finally Output.Free; end;
  if FSource.Full then
  begin
    Cached:=OpenCatalogSnapshot(FPublishedSource,FPublishedSource.CacheFile,DMUser.GetSystemDBConnection,FPrepared.Folder);
    if not Supports(Cached,IBookImportedLocationWriter,Writer) then
      raise ENotSupportedException.Create('Не поддержано сохранение путей импортированных книг.');
    Rows:=FActionDB.NewQuery('SELECT BookID,Folder,InsideNo FROM ApplyActions WHERE State IN (''known'',''missing-retained'') ORDER BY BookID');
    try
      Total:=FActionDB.QuerySingleInt('SELECT count(*) FROM ApplyActions WHERE State IN (''known'',''missing-retained'')');
      Done:=0;
      if Assigned(Progress) then Progress('Сохранение путей источника',0,Total);
      Cached.BeginBulkOperation;
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          Check; Writer.SetImportedBookLocation(Rows.FieldAsInt(0),Rows.FieldAsString(1),Rows.FieldAsInt(2));
          Inc(Done);
          if Assigned(Progress) and ((Done mod 1000=0) or (Done=Total)) then
            Progress('Сохранение путей источника',Done,Total);
          Rows.Next;
        end;
        Cached.EndBulkOperation(True);
      except if Cached.InBulkOperation then Cached.EndBulkOperation(False); raise; end;
    finally Rows.Free; Writer:=nil; Cached:=nil; end;
    Output:=OpenWorkDatabase(FPublishedSource.CacheFile);
    try
      Output.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]); Output.Start;
      try
        Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdateAvailability SELECT BookID,State FROM review.ApplyActions WHERE State<>''known''');
        Output.Commit;
      except Output.Rollback; raise; end;
    finally Output.Free; end;
  end
  else
  begin
    Cached:=OpenCatalogSnapshot(FPublishedSource,FPublishedSource.CacheFile,DMUser.GetSystemDBConnection,FPrepared.Folder);
    if not Supports(Cached,IBookImportedLocationWriter,Writer) then
      raise ENotSupportedException.Create('Не поддержано сохранение путей импортированных книг.');
    Cache:=TImportCache.Create; Genres:=TDictionary<string,TGenreData>.Create;
    Rows:=FActionDB.NewQuery('SELECT r.BookID,p.BookID,a.Folder,a.InsideNo,a.State FROM ReviewRows r '+
      'LEFT JOIN ReviewPrevious p ON p.Key=r.Key'+IfThen(FPacked and not FPreviousIndex,
        ' AND EXISTS(SELECT 1 FROM ReviewPackedLocations l WHERE l.Key=p.Key AND l.BookID=p.BookID)','')+
      ' JOIN ApplyActions a ON a.BookID=r.BookID ORDER BY r.BookID');
    FActionDB.ExecSQL('DROP TABLE IF EXISTS ApplyCachedInput');
    FActionDB.ExecSQL('CREATE TABLE ApplyCachedInput(InputID INTEGER PRIMARY KEY,CacheID INTEGER)');
    try
      Cached.BeginBulkOperation; Cached.StartBatchUpdate;
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          Check; FSnapshot.GetBookRecord(CreateBookKey(Rows.FieldAsInt(0),FSnapshot.CollectionID),Book,True);
          ID:=Rows.FieldAsInt(1);
          if ID=0 then
          begin
            Book.Folder:=Rows.FieldAsString(2); Book.InsideNo:=Rows.FieldAsInt(3);
            ID:=CopyReviewBook(FSnapshot,Cached,Book,Cache,Genres);
          end
          else if FPacked then
          begin
            var Prior: TBookRecord;
            Cached.GetBookRecord(CreateBookKey(ID,Cached.CollectionID),Prior,True);
            UpdateReviewedMetadata(FSnapshot,Cached,Book,Prior,Rows.FieldAsString(2),Rows.FieldAsInt(3),True,Cache);
          end
          else if (Rows.FieldAsString(4)='known') or (Rows.FieldAsString(4)='missing-retained') then
            Writer.SetImportedBookLocation(ID,Rows.FieldAsString(2),Rows.FieldAsInt(3));
          FActionDB.ExecSQL('INSERT INTO ApplyCachedInput VALUES(?,?)',[Book.BookKey.BookID,ID]);
          Rows.Next;
        end;
        Cached.SetProperty(PROP_DATAVERSION,FVersion); Cached.AfterBatchUpdate; Cached.EndBulkOperation(True);
      except if Cached.InBulkOperation then Cached.EndBulkOperation(False); raise; end;
    finally Cached.FinishBatchUpdate; Writer:=nil; Rows.Free; Genres.Free; Cache.Free; Cached:=nil; end;
    // Availability is keyed by the raw record identity, which survives a
    // native cache append even when its numeric IDs differ from the package.
    Output:=OpenWorkDatabase(FPublishedSource.CacheFile);
    try
      Output.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
      Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdateAvailability '+
        'SELECT m.CacheID,a.State FROM review.ApplyActions a JOIN review.ApplyCachedInput m ON m.InputID=a.BookID '+
        'WHERE a.State<>''known''');
      Output.ExecSQL('DELETE FROM LibraryUpdateAvailability WHERE BookID IN '+
        '(SELECT m.CacheID FROM review.ApplyActions a JOIN review.ApplyCachedInput m ON m.InputID=a.BookID '+
        'WHERE a.State=''known'')');
    finally Output.Free; end;
  end;
  Output:=OpenWorkDatabase(FPublishedSource.CacheFile);
  try
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateSourceKeys(BookID INTEGER PRIMARY KEY,SourceKey TEXT NOT NULL)');
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateReviewKeys(BookID INTEGER PRIMARY KEY,Key TEXT NOT NULL)');
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateExclusions(Key TEXT PRIMARY KEY) WITHOUT ROWID');
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdatePublisherLocations(BookID INTEGER PRIMARY KEY,Location TEXT NOT NULL)');
    Output.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
    Output.Start;
    try
      if FPacked and (FSource.CatalogSourceID='') then
        Output.ExecSQL('DELETE FROM LibraryUpdateExclusions');
      Output.ExecSQL('INSERT OR IGNORE INTO LibraryUpdateExclusions SELECT Key FROM review.ApplyExcluded');
      Output.Commit;
    except Output.Rollback; raise; end;
    if FSource.Full then
      Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdatePublisherLocations SELECT BookID,PublisherLocation FROM review.ReviewRows')
    else
      Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdatePublisherLocations SELECT m.CacheID,r.PublisherLocation '+
        'FROM review.ReviewRows r JOIN review.ApplyCachedInput m ON m.InputID=r.BookID');
    if FSource.Full then
      Rows:=Output.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.LibID,a.SourceKey,r.Key '+
        'FROM Books b JOIN review.ApplyActions a ON a.BookID=b.BookID '+
        'JOIN review.ReviewRows r ON r.BookID=a.BookID ORDER BY b.BookID')
    else
      Rows:=Output.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.LibID,a.SourceKey,r.Key '+
        'FROM Books b JOIN review.ApplyCachedInput m ON m.CacheID=b.BookID '+
        'JOIN review.ApplyActions a ON a.BookID=m.InputID '+
        'JOIN review.ReviewRows r ON r.BookID=a.BookID ORDER BY b.BookID');
    try
      Done:=0;
      if Assigned(Progress) then Progress('Сохранение ключей источника',0,FTotal);
      Output.Start; Rows.Open;
      try
        MergeSource.ID:=FPublishedSource.ID; MergeSource.Root:=FPublishedSource.Root;
        while not Rows.Eof do
        begin
          Check; Book:=Default(TBookRecord); Book.CollectionRoot:=FPublishedSource.Root;
          Book.Folder:=Rows.FieldAsString(1); Book.FileName:=Rows.FieldAsString(2);
          Book.FileExt:=Rows.FieldAsString(3); Book.InsideNo:=Rows.FieldAsInt(4); Book.LibID:=Rows.FieldAsString(5);
          Expected:=Rows.FieldAsString(6);
          Generated:=MergeSourceKeyAtLocation(MergeSource,Book,TPath.Combine(Book.CollectionRoot,Book.Folder));
          if (Expected<>'') and (Generated<>Expected) then
            Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdateSourceKeys VALUES(?,?)',[Rows.FieldAsInt(0),Expected])
          else Output.ExecSQL('DELETE FROM LibraryUpdateSourceKeys WHERE BookID=?',[Rows.FieldAsInt(0)]);
          Expected:=Rows.FieldAsString(7);
          Generated:=ReviewBookKey(Book,FPublishedSource.LibraryNamespace,FPublishedSource.Root);
          if (Expected<>'') and (Generated<>Expected) then
            Output.ExecSQL('INSERT OR REPLACE INTO LibraryUpdateReviewKeys VALUES(?,?)',[Rows.FieldAsInt(0),Expected])
          else Output.ExecSQL('DELETE FROM LibraryUpdateReviewKeys WHERE BookID=?',[Rows.FieldAsInt(0)]);
          Inc(Done);
          if Assigned(Progress) and ((Done mod 1000=0) or (Done=FTotal)) then
            Progress('Сохранение ключей источника',Done,FTotal);
          Rows.Next;
        end;
        Output.Commit;
      except Output.Rollback; raise; end;
    finally Rows.Free; end;
  finally Output.Free; end;
end;

procedure TLibraryUpdateReview.StoreAppliedState(const Target: IBookCollection);
var Sources: TCatalogSources; Found: Boolean; Profiles: TLibraryUpdateSources;
begin
  if Length(FProfiles)>0 then Profiles:=Copy(FProfiles)
  else
  begin
    Profiles:=ReadLibraryUpdateSources(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
    Found:=False;
    for var I:=0 to High(Profiles) do if SameText(Profiles[I].ID,FSource.ID) then begin Profiles[I]:=FSource; Found:=True; end;
    if not Found then Profiles:=Profiles+[FSource];
  end;
  Target.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(Profiles));
  Target.SetProperty(PROP_LIBRARY_UPDATE_TRANSACTION,FOperationID);
  SaveLibraryUpdateHistory(Target,FSource,FPublishedSource,FPrepared.SHA256);
  if FSource.CatalogSourceID<>'' then
  begin
    Sources:=LoadCatalogSources(Target); Found:=False;
    for var I:=0 to High(Sources) do
      if SameText(Sources[I].ID,FSource.CatalogSourceID) then
      begin Sources[I]:=FPublishedSource; Found:=True; Break; end;
    if not Found then raise EReadError.Create('Источник коллекции больше не подключён.');
    SaveCatalogSources(Target,Sources);
  end;
end;

procedure TLibraryUpdateReview.RestoreCopySizes(const Collection: IBookCollection; const SystemData:ISystemData; const Check: TProc);
  var Iterator: IBookIterator; CopyBook, Preferred: TBookRecord; Source: TMergeSource; Key: string; ID: Integer;
    SizeWriter:ISystemStoredBookSizeWriter;
  begin
    Supports(SystemData,ISystemStoredBookSizeWriter,SizeWriter);
    Source.ID:=FSourceInfo.ID; Source.Root:=FSourceInfo.Root; Iterator:=ReviewAllBooks(FDelta);
    while Iterator.Next(CopyBook) do
    begin
      Check; Key:=MergeSourceKey(Source,CopyBook); ID:=Collection.GetCatalogBookID(Key);
      if ID=0 then Continue;
      Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Preferred,False);
      if BookPhysicalIdentity(CopyBook)=BookPhysicalIdentity(Preferred) then
      begin
        CopyBook.BookKey:=Preferred.BookKey; CopyBook.Size:=Preferred.Size;
        Collection.SetCatalogBookCopy(Key,FSourceInfo.Name,CopyBook);
        // A merge wrote publisher metadata to the existing personal card before
        // the measured physical size was restored. Keep both stores consistent
        // in their current shared operation, without adding unused user cards.
        if Preferred.Size>0 then
          if Assigned(SizeWriter) then SizeWriter.SetStoredBookSize(Preferred.BookKey,Preferred.Size)
          else
          begin Collection.GetBookRecord(Preferred.BookKey,Preferred,True); SystemData.UpdateBook(Preferred); end;
      end;
    end;
  end;

procedure TLibraryUpdateReview.EditPackedSnapshot(const CatalogFile, PersonalFile: string;
  Info: TCollectionInfo; const Check: TProc; const Progress: TLibraryReviewProgress);
var
  PrivateSystem: ISystemData;
  Catalog: IBookCollection;
  Plan: TCollectionMergePlan;
  NormalizedPersonal: TSQLiteDatabase;
  Publisher: IPackingPublisherWriter;
  IDWriter: IReviewedBookIDWriter;
  Personal, Data: TSQLiteDatabase;
  Rows: TSQLiteQuery;
  Cache: TImportCache;
  Genres: TDictionary<string,TGenreData>;
  Book, Before, Incoming: TBookRecord;
  ID, PreviousLastID, Done: Integer;
  ReservedID: Int64;
  procedure SeedLegacyPublishers;
  var Archived:TSQLiteQuery; Prior:TBookRecord;
  begin
    Archived:=FActionDB.NewQuery('SELECT l.BookID,a.Folder,a.FileName,a.Ext,a.InsideNo,a.BookSize,'+
      'a.UpdateDate,a.Title,a.Lang,a.IsDeleted,a.LibID,l.PendingPayload FROM ReviewPackedLocations l '+
      'JOIN ReviewPrevious p ON p.Key=l.Key JOIN ReviewLegacyArtifacts a ON a.BookID=p.BookID ORDER BY l.BookID');
    try
      Archived.Open;
      while not Archived.Eof do
      begin
        Check;
        Prior:=Default(TBookRecord);
        Prior.BookKey:=CreateBookKey(Archived.FieldAsInt(0),Info.ID);
        Prior.Folder:=Archived.FieldAsString(1); Prior.FileName:=Archived.FieldAsString(2);
        Prior.FileExt:=Archived.FieldAsString(3); Prior.InsideNo:=Archived.FieldAsInt(4);
        Prior.Size:=Archived.FieldAsInt(5); Prior.Date:=Archived.FieldAsDateTime(6);
        Prior.Title:=Archived.FieldAsString(7); Prior.Lang:=Archived.FieldAsString(8);
        if Archived.FieldAsBoolean(9) then Include(Prior.BookProps,bpIsDeleted);
        Prior.LibID:=Archived.FieldAsString(10); Prior.CollectionRoot:=FPreviousRoot;
        Publisher.StorePackingPublisherMetadata(Prior,FPreviousRoot,not Archived.FieldAsBoolean(11));
        Archived.Next;
      end;
    finally Archived.Free; end;
  end;
begin
  // Collection methods that also touch user cards receive only the private
  // personal database. They cannot remove cards or groups from the original.
  // Some personal operations reopen the catalogue through Bases. Point this
  // private database at the private catalogue before giving it to the merge.
  NormalizedPersonal:=OpenWorkDatabase(PersonalFile);
  try
    NormalizedPersonal.ExecSQL('UPDATE Bases SET DBFileName=? WHERE DatabaseID=?',[CatalogFile,Info.ID]);
  finally NormalizedPersonal.Free; end;
  PrivateSystem:=TSystemData_SQLite.Create(PersonalFile);
  Info.DBFileName:=CatalogFile;
  Catalog:=TBookCollection_SQLite.Create(Info,PrivateSystem,FPrepared.Folder);
  if FSource.CatalogSourceID<>'' then
  begin
    Plan:=BuildBoundPlan(Catalog,PrivateSystem);
    try
      Plan.AfterBegin:=procedure(const Collection:IBookCollection)
      begin
        FPreviousLastID:=Collection.StartCatalogUpdateTracking(False);
      end;
      Plan.BeforeCommit:=procedure(const Collection:IBookCollection)
      begin
        Check;
        Collection.FinishCatalogUpdateTracking(False,FPreviousLastID);
        RestoreCopySizes(Collection,PrivateSystem,Check);
        StoreAppliedState(Collection);
      end;
      Plan.StageProgress:=procedure(const Stage:string; Done,Total:Integer)
      begin
        if Assigned(Progress) then Progress(Stage,Done,Total);
      end;
      Plan.Preview(nil,function:Boolean begin Check; Result:=False; end);
      Plan.ApplyToSnapshot(
        procedure(Done,Total:Integer)
        begin
          if Assigned(Progress) then Progress('Обновление источника в копии',Done,Total);
        end,
        function:Boolean begin Check; Result:=False; end);
    finally Plan.Free; end;
    Exit;
  end;
  if not Supports(Catalog,IPackingPublisherWriter,Publisher) or
    not Supports(Catalog,IReviewedBookIDWriter,IDWriter) then
    raise ENotSupportedException.Create('Каталог не поддерживает обновление упакованной копии.');
  Personal:=OpenWorkDatabase(PersonalFile);
  Cache:=nil; Genres:=nil; Rows:=nil;
  try
    Cache:=TImportCache.Create;
    Genres:=TDictionary<string,TGenreData>.Create;
    ReservedID:=Personal.QuerySingleInt('SELECT max(id) FROM ('+
      'SELECT coalesce(max(BookID),0) AS id FROM Books WHERE DatabaseID=? UNION ALL '+
      'SELECT coalesce(max(BookID),0) FROM BookGroups WHERE DatabaseID=?)',[Info.ID,Info.ID]);
    if (ReservedID<0) or (ReservedID>High(Integer)) then
      raise EReadError.Create('Нет допустимых номеров для новых книг.');
    Catalog.BeginBulkOperation;
    try
      PreviousLastID:=Catalog.StartCatalogUpdateTracking(False);
      IDWriter.ReserveReviewedBookIDs(Integer(ReservedID));
      Catalog.StartBatchUpdate;
      if FLegacyPackedBaseline then SeedLegacyPublishers;
      Rows:=FActionDB.NewQuery('SELECT BookID,TargetID,PackPayload,State,Folder,InsideNo FROM ApplyActions '+
        'WHERE Eligible<>0 ORDER BY BookID');
      Rows.Open; Done:=0;
      while not Rows.Eof do
      begin
        Check;
        FSnapshot.GetBookRecord(CreateBookKey(Rows.FieldAsInt(0),FSnapshot.CollectionID),Book,True);
        ID:=Rows.FieldAsInt(1);
        if ID=0 then
        begin
          Incoming:=Book;
          Incoming.Folder:=Rows.FieldAsString(4); Incoming.InsideNo:=Rows.FieldAsInt(5);
          Include(Incoming.BookProps,bpIsLocal);
          ID:=CopyReviewBook(FSnapshot,Catalog,Incoming,Cache,Genres);
          if ID<=0 then raise EWriteError.Create('Не удалось добавить книгу: '+Book.Title);
        end
        else
        begin
          Catalog.GetBookRecord(CreateBookKey(ID,Info.ID),Before,True);
          UpdateReviewedMetadata(FSnapshot,Catalog,Book,Before,Rows.FieldAsString(4),Rows.FieldAsInt(5),
            Rows.FieldAsBoolean(2),Cache);
          if Rows.FieldAsBoolean(2) then
            Personal.ExecSQL('UPDATE Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,BookSize=?,IsLocal=1 '+
              'WHERE DatabaseID=? AND BookID=? AND LibID=? AND (Folder=? OR Folder=?) AND FileName=? AND Ext=? AND InsideNo=?',
              [Rows.FieldAsString(4),Book.FileName,Book.FileExt,Rows.FieldAsInt(5),Book.Size,
               Info.ID,ID,Before.LibID,Before.Folder,TPath.Combine(Info.RootFolder,Before.Folder),
               Before.FileName,Before.FileExt,Before.InsideNo]);
          if LibraryPackedIdentityNeedsLocation(Book.LibID) then Book.LibID:=Before.LibID;
        end;
        Book.BookKey:=CreateBookKey(ID,Info.ID);
        Publisher.StorePackingPublisherMetadata(Book,FSourceInfo.Root,Rows.FieldAsString(3)<>'missing-retained');
        Inc(Done);
        if Assigned(Progress) and (Done mod 100=0) then Progress('Обновление копии каталога',Done,FTotal);
        Rows.Next;
      end;
      FreeAndNil(Rows);
      Rows:=FActionDB.NewQuery('SELECT BookID FROM PackedOmitted ORDER BY BookID');
      Rows.Open;
      while not Rows.Eof do
      begin
        Check;
        Catalog.DeleteBook(CreateBookKey(Rows.FieldAsInt(0),Info.ID));
        Rows.Next;
      end;
      Catalog.SetProperty(PROP_DATAVERSION,FVersion);
      StoreAppliedState(Catalog);
      Catalog.FinishCatalogUpdateTracking(False,PreviousLastID);
      Catalog.AfterBatchUpdate;
      Catalog.EndBulkOperation(True);
    except
      if Catalog.InBulkOperation then Catalog.EndBulkOperation(False);
      raise;
    end;
  finally
    Catalog.FinishBatchUpdate;
    Rows.Free; Genres.Free; Cache.Free; Personal.Free;
    IDWriter:=nil; Publisher:=nil; Catalog:=nil; PrivateSystem:=nil;
  end;
  // An omitted publisher row may return in a later full edition. Remove its
  // raw record from this private copy so its absence is not a user exclusion.
  if FUnlistedCount>0 then
  begin
    Data:=OpenWorkDatabase(CatalogFile);
    try
      Data.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
      Data.ExecSQL('DELETE FROM HomeLibrePackingPublishers WHERE BookID IN (SELECT BookID FROM review.PackedOmitted)');
    finally Data.Free; end;
  end;
end;

function TLibraryUpdateReview.PackedOptions(const Target:IBookCollection):TCollectionPackingOptions;
begin
  CheckTargetRevision(Target);
  if TLibraryUpdateJournal.HasPendingForCollection(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),Target.CollectionID) then
    raise EInvalidOperation.Create('Сначала завершите восстановление прежнего обновления.');
  Result:=Default(TCollectionPackingOptions);
  Result.SourceID:=Target.CollectionID;
  Result.CatalogFile:=FTargetFile;
  Result.PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Result.SourceRoot:=FOriginalTargetRoot;
  Result.OutputRoot:=FOriginalTargetRoot;
  if not TryReadPackingImageProfile(Result.OutputRoot,Result.ImageProfile,Result.ImageGrayscale) then
    raise EReadError.Create('В папке коллекции отсутствует описание упакованной копии.');
  if (FRestartProof.CatalogDigest<>'') and
    ((Result.ImageProfile<>FRestartProof.Identity.ImageProfile) or
     (Result.ImageGrayscale<>FRestartProof.Identity.ImageGrayscale)) then
    raise EReadError.Create('После перезапуска изменились настройки сжатой копии. Проверьте обновление заново.');
end;

procedure TLibraryUpdateReview.PrepareModuleRestart(const Target:IBookCollection; PreferNewRoot:Boolean;
  const Check:TProc; const Progress:TLibraryReviewProgress);
var Options:TCollectionPackingOptions; Request:TLibraryUpdateRestartRequest; LastUpdate:UInt64;
begin
  Options:=PackedOptions(Target);
  FMissingComponents:=ResolvePackingTools(Settings.AppPath,Options);
  if Length(FMissingComponents)=0 then Exit;
  Request:=Default(TLibraryUpdateRestartRequest);
  Request.Identity.SourceID:=Target.CollectionID;
  Request.Identity.CatalogFile:=FTargetFile;
  Request.Identity.SourceRoot:=FOriginalTargetRoot;
  Request.Identity.ImageProfile:=Options.ImageProfile;
  Request.Identity.ImageGrayscale:=Options.ImageGrayscale;
  Request.Identity.CaptureIdentity;
  Request.SourceID:=FSource.ID;
  Request.Profiles:=FProfiles;
  if Length(Request.Profiles)=0 then Request.Profiles:=TArray<TLibraryUpdateSource>.Create(FSource);
  Request.PreferNewRoot:=PreferNewRoot;
  if Assigned(Progress) then Progress('Сохранение проверенного обновления',0,0);
  Request.CatalogDigest:=CatalogContentDigest(FRevisionDB,Check);
  if Assigned(FPreviousRevisionDB) then
  begin
    Request.PreviousDigest:=CatalogContentDigest(FPreviousRevisionDB,Check);
    if FPreviousRevisionDB.QuerySingleInt('PRAGMA data_version')<>FPreviousRevision then
      raise EReadError.Create('Прежний индекс изменился. Проверьте обновление заново.');
  end;
  Check;
  CheckTargetRevision(Target);
  LastUpdate:=0;
  FPendingRestart:=PrepareLibraryUpdateRestart(Settings.LibraryUpdateWorkPath,Request,FPrepared,FSelectedPreviousIndex,
    Check,procedure(Done,Total:Int64)
    begin
      if not Assigned(Progress) or ((Done<>Total) and (GetTickCount64-LastUpdate<200)) then Exit;
      LastUpdate:=GetTickCount64;
      Progress('Сохранение проверенных индексов',Integer(Done),Integer(Total));
    end);
end;

procedure TLibraryUpdateReview.ApplyPacked(const Target: IBookCollection; const SystemData: ISystemData;
  const Check: TProc; const Progress: TLibraryReviewProgress);
var
  Options: TCollectionPackingOptions;
  Packing: TCollectionPackingSnapshot;
  Required: TArray<string>;
  Info: TCollectionInfo;
  Name: string;
  Suffix: Integer;
begin
  Options:=PackedOptions(Target);
  Info:=SystemData.GetCollectionInfo(Target.CollectionID);
  Required:=ResolvePackingTools(Settings.AppPath,Options);
  if Length(Required)>0 then
    raise EFileNotFoundException.Create('Установите модули сжатия и повторите обновление: '+string.Join(', ',Required));
  Name:=Info.DisplayName+' (обновление)';
  Options.DisplayName:=Name; Suffix:=1;
  while SystemData.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName) do
  begin
    Inc(Suffix);
    Options.DisplayName:=Name+' '+IntToStr(Suffix);
  end;
  PrepareCache(Check,Progress);
  Check;
  Packing:=TCollectionPackingSnapshot.Create(Options);
  try
    Packing.Prepare(function: Boolean
      begin
        try Check; Result:=False; except on E:EAbort do Result:=True; end;
      end,
      procedure(const Stage: string; Done, Total: Int64)
      begin
        Check;
        if Assigned(Progress) then
          if (Total>0) and (Total<=High(Integer)) and (Done>=0) and (Done<=Total) then
            Progress(Stage,Integer(Done),Integer(Total))
          else Progress(Stage,0,0);
      end,
      procedure(const CatalogFile, PersonalFile: string)
      begin
        CheckTargetRevision(Target);
        EditPackedSnapshot(CatalogFile,PersonalFile,Info,Check,Progress);
      end);
    Packing.Pack;
    Packing.ApplyPrepared;
    NotifyLibraryUpdateTestPoint('packed-before-registration');
    CheckTargetRevision(Target);
    FPublishedCollectionID:=Packing.RegisterNew(SystemData);
    FCachePublished:=True;
    FApplied:=True;
  finally Packing.Free; end;
end;

procedure TLibraryUpdateReview.Apply(const Target: IBookCollection; const SystemData: ISystemData;
  const Check: TProc; const Progress: TLibraryReviewProgress; out Committed: Boolean);
var Backup, Folder: string; Books: IBookIterator; Book, Prepared: TBookRecord;
  Rows: TSQLiteQuery; Cache: TImportCache; Genres: TDictionary<string,TGenreData>;
  LocalBooks: TArray<TLocalCatalogBook>; Done: Integer;
  SavedSQL: TSQLiteCancelCallback;
  Witness: ISystemCatalogCommitWitness; SystemStarted: Boolean;
  IDWriter:IReviewedBookIDWriter; NextID:Int64; PreferredID:Integer;
  Journal: TLibraryUpdateJournal; Failed, RemapComplete: Boolean; FinalCancel: TSQLiteCancelCallback;
begin
  Committed:=False;
  if not FApplicationReady then raise EInvalidOperation.Create('Обновление ещё не подготовлено.');
  if TLibraryUpdateJournal.HasPendingForCollection(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),Target.CollectionID) then
    raise EInvalidOperation.Create('Сначала завершите восстановление прежнего обновления. Перезапустите программу и проверьте отчёт восстановления.');
  if not Supports(SystemData,ISystemCatalogCommitWitness,Witness) then
    raise ENotSupportedException.Create('Хранилище личных данных не поддерживает согласованное обновление.');
  Journal:=nil; Failed:=False; RemapComplete:=False; FRecoveryPending:=False; FRecoveryError:='';
  try
  try
  Check;
  CheckTargetRevision(Target);
  PrepareCache(Check,Progress);
  CheckTargetRevision(Target);
  if Assigned(FPlan) then
  begin
    FPlan.BeforeBegin:=procedure(const Collection:IBookCollection) begin
      Journal:=TLibraryUpdateJournal.CreatePrepared(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),
        Folder,Settings.SystemFileName[sfSystemDB],TPath.Combine(Backup,'destination.hlc2'),
        Collection,SystemData,FOperationID,True,Check);
      NotifyLibraryUpdateTestPoint('journal-published');
    end;
    FPlan.AfterBegin:=procedure(const Collection:IBookCollection) begin
      Collection.SetProperty(PROP_DATAVERSION,Collection.GetProperty(PROP_DATAVERSION));
      CheckTargetRevision(Collection);
      FPreviousLastID:=Collection.StartCatalogUpdateTracking(True);
    end;
    FPlan.BeforeCommit:=procedure(const Collection:IBookCollection) begin
      Check; Collection.FinishCatalogUpdateTracking(True,FPreviousLastID); RestoreCopySizes(Collection,SystemData,Check); StoreAppliedState(Collection);
      Witness.SetCatalogCommitWitness(Collection.CollectionID,FOperationID);
      if Assigned(Progress) then Progress('Проверка подготовленного каталога',0,0);
      Journal.Seal(Collection,Check);
    end;
    Folder:=TPath.Combine(Settings.DataPath,'LibraryUpdateBackups'); ForceDirectories(Folder);
    Backup:=TPath.Combine(Folder,FOperationID);
    FPlan.StageProgress:=procedure(const Stage:string; Done,Total:Integer) begin
      if Assigned(Progress) then Progress(Stage,Done,Total);
    end;
    try FPlan.Apply(Backup,procedure(Done,Total:Integer) begin
      if Assigned(Progress) then Progress('Обновление источника',Done,Total);
    end,function:Boolean begin Check; Result:=False; end);
    finally
      FPlan.StageProgress:=nil; FPlan.BeforeBegin:=nil; FPlan.BeforeCommit:=nil; FPlan.AfterBegin:=nil;
      Committed:=FPlan.CatalogCommitted; FCachePublished:=Committed; FApplied:=Committed;
    end;
    Exit;
  end;
  Folder:=TPath.Combine(Settings.DataPath,'LibraryUpdateBackups'); ForceDirectories(Folder);
  Backup:=TPath.Combine(Folder,FOperationID+'.hlc2');
  CheckReviewOutputSpace(Folder,UInt64(TFile.GetSize(FTargetFile)));
  var BackupDB:=OpenWorkDatabase(FTargetFile,True);
  NextID:=0;
  try
    if FSource.Full then
    begin
      NextID:=BackupDB.QuerySingleInt('SELECT coalesce(max(BookID),0) FROM Books');
      if BackupDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''sqlite_sequence''')>0 then
        NextID:=Max(NextID,BackupDB.QuerySingleInt('SELECT coalesce(max(seq),0) FROM sqlite_sequence WHERE name=''Books'''));
    end;
    BackupDB.BackupTo(Backup,procedure(Done,Total:Integer) begin
      Check; CheckReviewOutputSpace(Folder,0);
      if Assigned(Progress) then Progress('Резервная копия каталога',Done,Total);
    end);
  finally BackupDB.Free; end;
  Journal:=TLibraryUpdateJournal.CreatePrepared(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),
    Folder,Settings.SystemFileName[sfSystemDB],Backup,Target,SystemData,FOperationID,False,Check);
  NotifyLibraryUpdateTestPoint('journal-published');
  Cache:=TImportCache.Create; Genres:=TDictionary<string,TGenreData>.Create; Rows:=nil;
  SavedSQL:=SQLiteCancelCallback;
  SystemStarted:=False;
  try
    Target.BeginBulkOperation;
    try
      // Acquire the catalogue writer before validating the retained observer.
      // The value is unchanged; it also closes the check-to-write race.
      Target.SetProperty(PROP_DATAVERSION,Target.GetProperty(PROP_DATAVERSION));
      CheckTargetRevision(Target);
      FPreviousLastID:=Target.StartCatalogUpdateTracking(FSource.Full);
      if FSource.Full then
      begin
        if not Supports(Target,IReviewedBookIDWriter,IDWriter) then
          raise ENotSupportedException.Create('Каталог не поддерживает сохранение проверенных номеров книг.');
        // Reserve the personal writer before allocating new catalogue IDs.
        SystemData.BeginDataUpdate; SystemStarted:=True;
        Witness.SetCatalogCommitWitness(Target.CollectionID,FOperationID);
        var PersonalBounds:=OpenWorkDatabase(Settings.SystemFileName[sfSystemDB],True);
        try
          NextID:=Max(NextID,PersonalBounds.QuerySingleInt('SELECT coalesce(max(BookID),0) FROM Books WHERE DatabaseID=?',[Target.CollectionID]));
          NextID:=Max(NextID,PersonalBounds.QuerySingleInt('SELECT coalesce(max(BookID),0) FROM BookGroups WHERE DatabaseID=?',[Target.CollectionID]));
        finally PersonalBounds.Free; end;
        if (NextID<0) or (NextID>High(Integer)) then raise EReadError.Create('Нет допустимых свободных номеров для новых книг.');
        LocalBooks:=Target.CaptureLocalBooks; Target.TruncateTablesBeforeImport;
        IDWriter.ReserveReviewedBookIDs(Integer(NextID));
      end;
      Target.StartBatchUpdate;
      try
        if FSource.Full then Books:=ReviewAllBooks(FSnapshot) else Books:=ReviewAllBooks(FDelta);
        Rows:=FActionDB.NewQuery('SELECT a.Eligible,a.Folder,a.InsideNo,d.DeltaID,a.TargetID,'+
          'p.Rate,p.Progress,p.Review,p.Annotation FROM ApplyActions a '+
          'LEFT JOIN ApplyDeltaInput d ON d.InputID=a.BookID LEFT JOIN ApplyPersonal p ON p.BookID=a.BookID '+
          'WHERE a.BookID=?'); Done:=0;
        while Books.Next(Book) do
        begin
          Check;
          if FSource.Full then
          begin
            Rows.Reset; Rows.SetParam(0,Book.BookKey.BookID); Rows.Open;
            if not Rows.FieldAsBoolean(0) then Continue;
            if Rows.FieldAsInt(3)>0 then
            begin
              FDelta.GetBookRecord(CreateBookKey(Rows.FieldAsInt(3),FDelta.CollectionID),Prepared,True);
              Book:=Prepared;
            end
            else
            begin
              Book.Folder:=Rows.FieldAsString(1); Book.InsideNo:=Rows.FieldAsInt(2);
            end;
            if Rows.FieldAsInt(4)>0 then
            begin
              Book.Rate:=Rows.FieldAsInt(5); Book.Progress:=Rows.FieldAsInt(6);
              Book.Review:=Rows.FieldAsBlobString(7); Book.Annotation:=Rows.FieldAsString(8);
            end;
            PreferredID:=Rows.FieldAsInt(4);
            if PreferredID<=0 then
            begin
              if NextID>=High(Integer) then raise EReadError.Create('Исчерпаны допустимые номера новых книг.');
              Inc(NextID); PreferredID:=Integer(NextID);
            end;
            if Rows.FieldAsInt(3)>0 then CopyReviewBook(FDelta,Target,Book,Cache,Genres,False,PreferredID)
            else CopyReviewBook(FSnapshot,Target,Book,Cache,Genres,False,PreferredID);
          end
          else CopyReviewBook(FDelta,Target,Book,Cache,Genres,True);
          Inc(Done); NotifyLibraryUpdateTestPoint('rows-written');
          if Assigned(Progress) and (Done mod 100=0) then Progress('Обновление каталога',Done,FTotal);
        end;
        Books:=nil; Target.AfterBatchUpdate;
      finally Target.FinishBatchUpdate; end;
      Target.SetProperty(PROP_DATAVERSION,FVersion);
      if VarToStr(FSnapshot.GetProperty(PROP_SOURCE_LIBRARY))<>'' then
        Target.SetProperty(PROP_SOURCE_LIBRARY,FSnapshot.GetProperty(PROP_SOURCE_LIBRARY));
      Target.FinishCatalogUpdateTracking(FSource.Full,FPreviousLastID);
      if FSource.Full then
        IDWriter.RestoreReviewedLocalBooks(LocalBooks);
      Check;
      if not SystemStarted then begin SystemData.BeginDataUpdate; SystemStarted:=True; end;
      StoreAppliedState(Target); Witness.SetCatalogCommitWitness(Target.CollectionID,FOperationID);
      if Assigned(Progress) then Progress('Проверка подготовленного каталога',0,0);
      Journal.Seal(Target,Check);
      NotifyLibraryUpdateTestPoint('before-commit'); Check;
      SQLiteCancelCallback:=nil;
      if Assigned(Progress) then Progress('Сохранение каталога',Done,FTotal);
      NotifyLibraryUpdateTestPoint('commit-start');
      Target.EndBulkOperation(True);
      Committed:=True; FCachePublished:=True; FApplied:=True;
      NotifyLibraryUpdateTestPoint('catalogue-committed');
    except
      SQLiteCancelCallback:=nil;
      if Target.InBulkOperation then Target.EndBulkOperation(False); raise;
    end;
    SQLiteCancelCallback:=nil;
    SystemData.RemapCollectionBookIDs(Target.CollectionID,FSource.Full);
    SystemData.EndDataUpdate(True); SystemStarted:=False;
    RemapComplete:=True;
    NotifyLibraryUpdateTestPoint('stores-committed');
  finally
    SQLiteCancelCallback:=nil;
    try if SystemStarted then SystemData.EndDataUpdate(False);
    finally SQLiteCancelCallback:=SavedSQL; Books:=nil; Rows.Free; Genres.Free; Cache.Free; end;
  end;
  except Failed:=True; raise; end;
  finally
    FinalCancel:=SQLiteCancelCallback; SQLiteCancelCallback:=nil;
    try
      if Assigned(Journal) then
      begin
        try
          Committed:=Committed or Journal.CatalogueCommitted(Target);
          FCachePublished:=FCachePublished or Committed; FApplied:=FApplied or Committed;
          FRecoveryPending:=not Journal.CompleteAttempt(Target,SystemData,RemapComplete);
          if FRecoveryPending then
          begin
            FCachePublished:=True;
            raise EReadError.Create('Сохранение обновления требует восстановления. Перезапустите программу.');
          end;
        except on E:Exception do
          begin FRecoveryPending:=True; FCachePublished:=True; FRecoveryError:=E.Message; if not Failed then raise; end;
        end;
      end;
    finally Journal.Free; SQLiteCancelCallback:=FinalCancel; end;
  end;
end;

type
  TLibraryUpdateControl = class
  private
    FReview: TLibraryUpdateReview;
    FWorker: TCollectionWorker;
    FPrevious: TSQLiteCancelCallback;
    FError: string;
    function CancelSQL: Boolean;
  public
    constructor Create(Review: TLibraryUpdateReview; Worker: TCollectionWorker);
    destructor Destroy; override;
    procedure Check;
    property Error: string read FError;
  end;

  TReviewedApplyWorker = class(TCollectionWorker)
  private FReview: TLibraryUpdateReview; FPreferNew,FAllowModuleRestart: Boolean;
  protected procedure WorkFunction; override;
  public constructor Create(CollectionID: Integer; Review: TLibraryUpdateReview; PreferNew,AllowModuleRestart: Boolean);
  end;

  TInpxReviewWorker = class(TImportInpxThreadBase)
  private FReview: TLibraryUpdateReview;
  protected procedure WorkFunction; override;
  public constructor Create(CollectionID: Integer; Review: TLibraryUpdateReview);
  end;
  TMetabibReviewWorker = class(TImportMetabibThreadBase)
  private FReview: TLibraryUpdateReview;
  protected procedure WorkFunction; override;
  public constructor Create(CollectionID: Integer; Review: TLibraryUpdateReview);
  end;

constructor TLibraryUpdateControl.Create(Review: TLibraryUpdateReview; Worker: TCollectionWorker);
begin
  inherited Create; FReview:=Review; FWorker:=Worker;
  FPrevious:=SQLiteCancelCallback; SQLiteCancelCallback:=CancelSQL;
end;

destructor TLibraryUpdateControl.Destroy;
begin SQLiteCancelCallback:=FPrevious; inherited; end;

function TLibraryUpdateControl.CancelSQL: Boolean;
begin
  Result:=FWorker.Canceled;
  if Result then Exit;
  try
    FReview.CheckSpace;
    if Assigned(FPrevious) then Result:=FPrevious();
  except on E:Exception do begin FError:=E.Message; Result:=True; end; end;
end;

procedure TLibraryUpdateControl.Check;
begin
  if FError<>'' then raise EWriteError.Create(FError);
  if FWorker.Canceled then raise EAbort.Create('Обновление отменено.');
  FReview.CheckSpace;
end;

constructor TReviewedApplyWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview; PreferNew,AllowModuleRestart: Boolean);
begin
  inherited Create(CollectionID);
  FReview:=Review;
  FPreferNew:=PreferNew;
  FAllowModuleRestart:=AllowModuleRestart;
end;

procedure TReviewedApplyWorker.WorkFunction;
var Control: TLibraryUpdateControl; Check: TProc; Progress: TLibraryReviewProgress;
begin
  Control:=TLibraryUpdateControl.Create(FReview,Self);
  try
    Check:=procedure begin Control.Check; end;
    Progress:=procedure(const Stage:string; Done,Total:Integer) begin
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end
      else SetProgressHint(pbstMarquee);
      SetComment(Stage);
    end;
    try
      if FAllowModuleRestart and FReview.FPacked then
      begin
        FReview.PrepareModuleRestart(FCollection,FPreferNew,Check,Progress);
        if Assigned(FReview.PendingRestart) then Exit;
      end;
      FReview.PrepareApplication(FCollection,FSystemData,FPreferNew,Check,Progress);
      if ShowMessage(FReview.ApplySummary,MB_YESNO or MB_ICONQUESTION or MB_DEFBUTTON2)<>IDYES then Exit;
      if FReview.FPacked then
      begin
        try
          FReview.ApplyPacked(FCollection,FSystemData,Check,Progress);
        except
          on E:EAbort do
          begin
            if Control.Error<>'' then raise EWriteError.Create(Control.Error);
            Exit;
          end;
        end;
        FChangesCommitted:=FReview.PublishedCollectionID>0;
      end
      else FReview.Apply(FCollection,FSystemData,Check,Progress,FChangesCommitted);
      FOperationSuccess:=FChangesCommitted;
    except
      if Control.Error<>'' then raise EWriteError.Create(Control.Error);
      raise;
    end;
  finally
    FReview.FApplicationReady:=False; FreeAndNil(FReview.FInventory); FReview.CleanCache; Control.Free;
  end;
end;

constructor TInpxReviewWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview);
begin inherited Create(CollectionID); FReview:=Review; FGenresType:=gtFb2; FKeepCollectionProps:=True; FKeepIndexArchiveNames:=True; end;

procedure TInpxReviewWorker.WorkFunction;
var Zip: TMHLZip; HasEntries: Boolean; Control: TLibraryUpdateControl;
begin
  Control:=TLibraryUpdateControl.Create(FReview,Self);
  try
  FImportCheck:=procedure begin Control.Check; end;
  Zip:=TMHLZip.Create(FReview.FPrepared.FileName,True); HasEntries:=False;
  try
    for var I:=0 to Zip.FileCount-1 do
      if SameText(ExtractFileExt(Zip.FileNames[I]),'.inp') then HasEntries:=True;
  finally Zip.Free; end;
  if not HasEntries then raise EReadError.Create('В файле не найден список книг INPX.');
  FReview.Build(FCollection,FSystemData,
    procedure(Collection: IBookCollection) begin
      Import(FReview.FPrepared.FileName,False,Collection); FReview.FSkipped:=FInvalidRows;
    end,
    FImportCheck,procedure(const Stage:string; Done,Total:Integer) begin
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end
      else SetProgressHint(pbstMarquee);
      SetComment(Stage);
    end);
  FOperationSuccess:=True;
  finally FImportCheck:=nil; Control.Free; end;
end;

constructor TMetabibReviewWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview);
begin inherited Create(CollectionID); FReview:=Review; FGenresType:=gtFb2; end;

procedure TMetabibReviewWorker.WorkFunction;
var Control: TLibraryUpdateControl;
begin
  Control:=TLibraryUpdateControl.Create(FReview,Self);
  try
  FImportCheck:=procedure begin Control.Check; end;
  FReview.Build(FCollection,FSystemData,
    procedure(Collection: IBookCollection) begin
      Import(FReview.FPrepared.FileName,False,Collection); FReview.FSkipped:=FInvalidRows;
    end,
    FImportCheck,procedure(const Stage:string; Done,Total:Integer) begin
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end
      else SetProgressHint(pbstMarquee);
      SetComment(Stage);
    end);
  FOperationSuccess:=True;
  finally FImportCheck:=nil; Control.Free; end;
end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;
begin
  if Review.FIsMetabib then Result:=TMetabibReviewWorker.Create(CollectionID,Review)
  else Result:=TInpxReviewWorker.Create(CollectionID,Review);
end;

function CreateLibraryApplyWorker(CollectionID: Integer; Review: TLibraryUpdateReview;
  PreferNewRoot,AllowModuleRestart: Boolean): TCollectionWorker;
begin Result:=TReviewedApplyWorker.Create(CollectionID,Review,PreferNewRoot,AllowModuleRestart); end;

end.
