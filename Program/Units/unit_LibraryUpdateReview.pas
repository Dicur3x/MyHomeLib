unit unit_LibraryUpdateReview;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Interfaces, unit_Globals,
  unit_CatalogSources, unit_LibraryUpdateSources, unit_LibraryUpdateFetch,
  unit_CollectionWorkerThread, unit_CollectionMerge, unit_LibraryUpdateInventory;

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
    FPreviousIndex, FReady: Boolean;
    FDelta: IBookCollection;
    FDeltaFile, FApplySummary, FCacheInput, FPreviousFile, FOperationID: string;
    FPlan: TCollectionMergePlan;
    FActionDB: TSQLiteDatabase;
    FRevisionDB: TSQLiteDatabase;
    FActionLookup: TSQLiteQuery;
    FInventory: TLibraryUpdateInventory;
    FPublishedSource: TCatalogSource;
    FCacheOwned, FCachePublished, FApplicationReady, FApplied, FIssuesReady: Boolean;
    FRemovedCount, FMissingCount, FNewCards, FUpdateCards, FPreviousLastID, FUnlistedCount: Integer;
    FLastSpaceCheck: UInt64;
    procedure Analyze(const Target, Previous: IBookCollection; const Check: TProc;
      const Progress: TLibraryReviewProgress);
    procedure PrepareApplication(const Target: IBookCollection; const SystemData: ISystemData;
      PreferNewRoot: Boolean; const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure PrepareCache(const Check: TProc; const Progress: TLibraryReviewProgress);
    procedure StoreAppliedState(const Target: IBookCollection);
    procedure RestoreCopySizes(const Collection: IBookCollection; const Check: TProc);
    procedure Apply(const Target: IBookCollection; const SystemData: ISystemData;
      const Check: TProc; const Progress: TLibraryReviewProgress; out Committed: Boolean);
    procedure CleanCache;
    procedure CheckTargetRevision(const Target: IBookCollection);
  public
    constructor Create(const Source: TLibraryUpdateSource; Prepared: TStagedLibraryIndex);
    destructor Destroy; override;
    procedure CheckSpace;
    procedure SetSourceProfiles(const Profiles: TLibraryUpdateSources);
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
    property OperationID: string read FOperationID;
    property MissingReportReady: Boolean read FIssuesReady;
    property MissingBooks: Integer read FMissingCount;
  end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;
function CreateLibraryApplyWorker(CollectionID: Integer; Review: TLibraryUpdateReview;
  PreferNewRoot: Boolean): TCollectionWorker;

{$IFDEF MHL_COMPRESSION_TEST}
var LibraryUpdateTestPoint: TProc<string>;
{$ENDIF}

implementation

uses Winapi.Windows, Vcl.ComCtrls, System.IOUtils, System.Hash, System.Variants, System.JSON, System.StrUtils, System.Math,
  unit_Consts, unit_Database_SQLite, unit_LibrarySourceID, unit_UserData,
  unit_ImportInpxThread, unit_ImportMetabibThread, unit_MetabibReader,
  unit_MHLArchiveHelpers, unit_Settings, unit_LibraryUpdateHistory, unit_CollectionPacking, dm_user;

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
  FNeeded:=TStringList.Create; FHistorical:=TStringList.Create;
  FFound:=TStringList.Create; FAmbiguous:=TStringList.Create;
end;

procedure TLibraryUpdateReview.SetSourceProfiles(const Profiles: TLibraryUpdateSources);
begin WriteLibraryUpdateSources(Profiles); FProfiles:=Copy(Profiles); end;

destructor TLibraryUpdateReview.Destroy;
begin
  FPlan.Free; FActionLookup.Free; FActionDB.Free; FInventory.Free; FRevisionDB.Free;
  FDelta:=nil; FSnapshot:=nil; CleanCache;
  // Only files explicitly created by this review; never recursive cleanup.
  for var Name in TArray<string>.Create(FDatabaseFile,FAnalysisFile,FDeltaFile) do
    if Name<>'' then
      for var Suffix in TArray<string>.Create('','-wal','-shm','-journal') do
        if FileExists(Name+Suffix) then
          try TFile.Delete(Name+Suffix); except end;
  FNeeded.Free; FHistorical.Free; FFound.Free; FAmbiguous.Free;
  inherited;
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
  FreeAndNil(FRevisionDB); FRevisionDB:=TSQLiteDatabase.CreateReadOnly(FTargetFile);
  FTargetRevision:=IntToStr(FRevisionDB.QuerySingleInt('PRAGMA data_version'));
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
  if not DirectoryExists(FSourceInfo.Root) then
    raise EDirectoryNotFoundException.Create('Исходная папка книг недоступна: '+FSourceInfo.Root);
  if (FSource.BooksRoot<>'') and not DirectoryExists(FSource.BooksRoot) then
    raise EDirectoryNotFoundException.Create('Папка докачанных архивов недоступна: '+FSource.BooksRoot);
  Previous:=Target; FPreviousIndex:=False;
  if LoadLibraryUpdateHistory(Target,FSource,PreviousInfo) and FileExists(PreviousInfo.CacheFile) then
  begin Previous:=OpenCatalogSnapshot(PreviousInfo,PreviousInfo.CacheFile,SystemData); FPreviousIndex:=True; end
  else if (FSource.CatalogSourceID<>'') and FSourceInfo.IsINPX and FileExists(FSourceInfo.CacheFile) then
  begin Previous:=OpenCatalogSource(FSourceInfo,SystemData); FPreviousIndex:=True; end;
  if (FSource.CatalogSourceID<>'') and not FSourceInfo.IsINPX then
  begin Previous:=OpenCatalogSource(FSourceInfo,SystemData); FPreviousIndex:=True; end;
  if FPreviousIndex then FPreviousFile:=VarToStr(Previous.GetProperty(PROP_DATAFILE));
  SnapshotFile:=TPath.Combine(FPrepared.Folder,'review-'+TGUID.NewGuid.ToString+'.hlc2');
  if FileExists(SnapshotFile) then raise EWriteError.Create('Рабочий файл проверки уже существует.');
  FDatabaseFile:=SnapshotFile;
  TBookCollection_SQLite.CreateCollection(SystemData,FDatabaseFile,CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  FSnapshot:=OpenCatalogSnapshot(FSourceInfo,FDatabaseFile,SystemData);
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
  Analyze(Target,Previous,Check,Progress);
  Check;
  CheckTargetRevision(Target);
  FReady:=True;
end;

function ReviewBookKey(const Book: TBookRecord; const Namespace, Root: string): string;
var ID, Source, Original, Folder: string; P: Integer; Numeric: Boolean;
begin
  ID:=Book.LibID; Source:=LowerCase(Trim(Namespace));
  if ID.StartsWith('merged:',True) then
  begin Delete(ID,1,7); P:=Pos(':',ID); if P>0 then Delete(ID,1,P); end;
  if TryParseLibrarySourceID(ID,Source,Original) then ID:=Original
  else
  begin
    Source:=LowerCase(Trim(Namespace)); Numeric:=ID<>'';
    for var C in ID do Numeric:=Numeric and CharInSet(C,['0'..'9']);
    if not Numeric or ((Source<>'flibusta') and (Source<>'librusec')) then Source:='';
  end;
  if Source<>'' then Folder:='id:'+Source+#1+ID
  else if ID<>'' then Folder:='source-id:'+ID
  else
  begin
    Folder:=Book.Folder;
    if TPath.IsPathRooted(Folder) then
      Folder:=ExtractRelativePath(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),TPath.GetFullPath(Folder));
    Folder:='file:'+LowerCase(Folder.Replace('/','\'))+#1+ID;
  end;
  // Preserve separate artifacts sharing a library ID; unknown libraries match
  // only their physical relative locator, never a guessed display-name identity.
  Result:=THashSHA2.GetHashString(Folder+#1+LowerCase(Book.FileName)+#1+LowerCase(Book.FileExt));
end;

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

procedure TLibraryUpdateReview.Analyze(const Target, Previous: IBookCollection;
  const Check: TProc; const Progress: TLibraryReviewProgress);
var DB: TSQLiteDatabase; Insert, Query: TSQLiteQuery; Iterator: IPublisherSeriesIndexIterator;
  Book, Candidate: TBookRecord; Stamp, Namespace, Key, Name, OldPath, NewPath, Path, Version, SourceKey: string;
  Count, Total, NewCount, ChangedCount: Integer; Existing, CandidateExists: Boolean;
  MergeSource: TMergeSource; Containers: TDictionary<string,string>;
  StateDB: TSQLiteDatabase; StateQuery, SourceKeyQuery: TSQLiteQuery; State, Container, Comparison: string;
  procedure Load(const Collection: IBookCollection; IsPrevious: Boolean);
  begin
    Namespace:=VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    if IsPrevious and (Namespace='') then Namespace:=FSourceInfo.LibraryNamespace;
    Iterator:=Collection.GetPublisherSeriesIndexIterator; Count:=0; Total:=Iterator.RecordCount;
    while Iterator.Next(Book,Stamp) do
    begin
      Check; CheckSpace;
      Key:=ReviewBookKey(Book,Namespace,FSourceInfo.Root);
      Insert.Reset; Insert.SetParam(0,Key); Insert.SetParam(1,ReviewStamp(Book));
      if IsPrevious then
      begin
        MergeSource.ID:=FSourceInfo.ID; MergeSource.Root:=Collection.CollectionRoot;
        SourceKey:=MergeSourceKeyAtLocation(MergeSource,Book,TPath.Combine(Book.CollectionRoot,Book.Folder));
        if Assigned(SourceKeyQuery) then
        begin
          SourceKeyQuery.Reset; SourceKeyQuery.SetParam(0,Book.BookKey.BookID); SourceKeyQuery.Open;
          if not SourceKeyQuery.Eof then SourceKey:=SourceKeyQuery.FieldAsString(0);
        end;
        Insert.SetParam(2,ReviewLocation(Book)); Insert.SetParam(3,SourceKey);
        Container:=ReviewContainer(Book,'',Containers);
        Insert.SetParam(4,BookPhysicalIdentityAtLocation(Book,Container));
        State:='known';
        if Assigned(StateQuery) then
        begin
          StateQuery.Reset; StateQuery.SetParam(0,Book.BookKey.BookID); StateQuery.Open;
          if not StateQuery.Eof then State:=StateQuery.FieldAsString(0);
        end;
        Insert.SetParam(5,State); Insert.SetParam(6,Book.BookKey.BookID);
        Insert.SetParam(7,Container); Insert.SetParam(8,Book.InsideNo);
      end
      else
      begin
        Insert.SetParam(2,Book.BookKey.BookID);
        Insert.SetParam(3,ReviewLocation(Book));
        Insert.SetParam(4,not (bpIsDeleted in Book.BookProps));
        Container:=ReviewContainer(Book,FSource.BooksRoot,Containers);
        Insert.SetParam(5,BookPhysicalIdentityAtLocation(Book,Container));
      end;
      Insert.ExecSQL; Inc(Count);
      if Assigned(Progress) and ((Count mod 1000=0) or (Count=Total)) then
        if IsPrevious then Progress('Сопоставление с прежними книгами',Count,Total)
        else Progress('Проверка нового списка книг',Count,Total);
    end;
    Iterator:=nil;
  end;
begin
  Comparison:=TPath.Combine(FPrepared.Folder,'comparison-'+TGUID.NewGuid.ToString+'.sqlite');
  if FileExists(Comparison) then raise EWriteError.Create('Рабочее сравнение уже существует.');
  FAnalysisFile:=Comparison;
  DB:=TSQLiteDatabase.Create(FAnalysisFile); Insert:=nil; Query:=nil;
  Containers:=TDictionary<string,string>.Create; StateDB:=nil; StateQuery:=nil; SourceKeyQuery:=nil;
  try
    if FPreviousIndex then
    begin
      StateDB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Previous.GetProperty(PROP_DATAFILE)));
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateAvailability'' AND type=''table''')>0 then
        if StateDB.QuerySingleInt('SELECT count(*) FROM LibraryUpdateAvailability')>0 then
          StateQuery:=StateDB.NewQuery('SELECT State FROM LibraryUpdateAvailability WHERE BookID=?');
      if StateDB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''LibraryUpdateSourceKeys'' AND type=''table''')>0 then
        if StateDB.QuerySingleInt('SELECT count(*) FROM LibraryUpdateSourceKeys')>0 then
          SourceKeyQuery:=StateDB.NewQuery('SELECT SourceKey FROM LibraryUpdateSourceKeys WHERE BookID=?');
    end;
    DB.ExecSQL('CREATE TABLE ReviewPrevious(Key TEXT PRIMARY KEY,Stamp TEXT,Location TEXT,SourceKey TEXT,Physical TEXT,State TEXT,BookID INTEGER,Container TEXT,InsideNo INTEGER,Copies INTEGER NOT NULL DEFAULT 1) WITHOUT ROWID');
    DB.ExecSQL('CREATE TABLE ReviewRows(Key TEXT,Stamp TEXT,BookID INTEGER,Location TEXT,Active INTEGER,Physical TEXT)');
    DB.ExecSQL('CREATE TABLE ReviewExcluded(Key TEXT PRIMARY KEY) WITHOUT ROWID');
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
    end;
    // Build the empty index before streaming rows. GROUP BY/ORDER BY can walk
    // it without a large sort spilling to Windows TEMP on the system drive.
    DB.ExecSQL('CREATE INDEX ReviewRowsLocation ON ReviewRows(Location)');
    DB.Start;
    try
      Insert:=DB.NewQuery('INSERT INTO ReviewPrevious(Key,Stamp,Location,SourceKey,Physical,State,BookID,Container,InsideNo) VALUES(?,?,?,?,?,?,?,?,?) '+
        'ON CONFLICT(Key) DO UPDATE SET Copies=Copies+1'); Load(Previous,True); FreeAndNil(Insert);
      Insert:=DB.NewQuery('INSERT INTO ReviewRows VALUES(?,?,?,?,?,?)'); Load(FSnapshot,False); FreeAndNil(Insert);
      DB.Commit;
    except DB.Rollback; raise; end;
    FTotal:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows');
    FDeleted:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows WHERE Active=0');
    FNewBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key WHERE r.Active<>0 AND p.Key IS NULL');
    FChangedBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r JOIN ReviewPrevious p ON p.Key=r.Key WHERE r.Active<>0 AND (p.Stamp<>r.Stamp OR p.Physical<>r.Physical)');
    Query:=DB.NewQuery('SELECT r.Location,min(r.BookID),sum(r.Active<>0 AND p.Key IS NULL),sum(r.Active<>0 AND p.Key IS NOT NULL AND (p.Stamp<>r.Stamp OR p.Physical<>r.Physical)) '+
      'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key GROUP BY r.Location HAVING sum(r.Active)>0 ORDER BY r.Location');
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
    FSummary:=Format('В индексе: %d записей, в том числе помеченных удалёнными: %d.%sНовых книг: %d. С изменёнными сведениями: %d.%s'+
      'Версия индекса: %s.%sФайлов найдено: %d. Для новых/изменённых записей отсутствует: %d.%s'+
      'Отсутствующих файлов только с прежними записями: %d. Одноимённых файлов в обеих папках: %d.',
      [FTotal,FDeleted,sLineBreak,FNewBooks,FChangedBooks,sLineBreak,Version,sLineBreak,FFound.Count,FNeeded.Count,sLineBreak,FHistorical.Count,FAmbiguous.Count]);
    if FSkipped>0 then FSummary:=FSummary+sLineBreak+
      Format('Внимание: пропущено ошибочных записей или записей без файла: %d. Список неполный.',[FSkipped]);
    if FPreviousIndex then FSummary:=FSummary+sLineBreak+'Сравнение с сохранённым индексом этого источника.'
    else FSummary:=FSummary+sLineBreak+'Сравнение с текущим каталогом. Прежний полный индекс неизвестен: удалённые ранее записи могут выглядеть новыми.';
    FSummary:=FSummary+sLineBreak+'Сверяются ID, имена и форматы файлов; изменения — по названию, языку, размеру, дате и отметке удаления. '+
      'Старые отсутствующие файлы не включены в список докачки: среди них могут быть удалённые дубли. '+
      'Изменение содержимого архива с прежним именем без изменения индекса таким сравнением не определяется. '+
      'Наличие файла проверено без чтения всех книг внутри него. Книги и текущий каталог не изменены.';
    if FNeeded.Count>0 then
    begin
      FSummary:=FSummary+sLineBreak+sLineBreak+'Нужные файлы по новому индексу:';
      for var I:=0 to FNeeded.Count-1 do
      begin
        if I>=24 then begin FSummary:=FSummary+sLineBreak+'Остальные имена доступны через «Копировать список».'; Break; end;
        FSummary:=FSummary+sLineBreak+FNeeded[I];
      end;
    end;
  finally Iterator:=nil; SourceKeyQuery.Free; StateQuery.Free; StateDB.Free; Containers.Free; Query.Free; Insert.Free; DB.Free; end;
end;

function CopyReviewBook(const Source, Destination: IBookCollection; Book: TBookRecord;
  Cache: TImportCache; Genres: TDictionary<string,TGenreData>; CheckName: Boolean = False): Integer;
var OriginalKey: TBookKey; Key: string; Genre: TGenreData;
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
  Result:=Destination.InsertBook(Book,CheckName,False,Cache);
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

procedure TLibraryUpdateReview.PrepareApplication(const Target: IBookCollection;
  const SystemData: ISystemData; PreferNewRoot: Boolean; const Check: TProc;
  const Progress: TLibraryReviewProgress);
var DB, CopyDB: TSQLiteDatabase; Rows, Put, Lookup, Copies, CurrentLocation: TSQLiteQuery;
  Iterator: IPublisherSeriesIndexIterator; Item, Current, Resolved, CopyBook: TBookRecord;
  Key, Stamp, Namespace, Identity, Physical, Reason, State, Name, ExpectedKey, CheckedFile: string;
  Bound, Known, Changed, Eligible, KeepMetadata, OwnsFile, Verified: Boolean;
  ID, Matches, Done, DeltaID: Integer; Sources: TMergeSources;
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
  if IsPackedCollectionCatalog(FTargetFile) then
    raise ENotSupportedException.Create('Для упакованного каталога пока используйте обновление из INPX в меню коллекции.');
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
  FActionDB:=TSQLiteDatabase.Create(FAnalysisFile); DB:=FActionDB;
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyActions'); DB.ExecSQL('DROP TABLE IF EXISTS ApplyLive');
  DB.ExecSQL('DROP TABLE IF EXISTS ApplyDeltaInput');
  DB.ExecSQL('CREATE TABLE ApplyLive(Key TEXT,BookID INTEGER,Identity TEXT,Physical TEXT)');
  DB.ExecSQL('CREATE INDEX ApplyLiveKey ON ApplyLive(Key)');
  DB.ExecSQL('CREATE INDEX ApplyLiveIdentity ON ApplyLive(Identity)');
  DB.ExecSQL('CREATE INDEX ApplyLivePhysical ON ApplyLive(Physical)');
  Put:=DB.NewQuery('INSERT INTO ApplyLive VALUES(?,?,?,?)');
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
        Put.SetParam(2,BookLibraryIdentity(Item,Namespace)); Put.SetParam(3,BookPhysicalIdentity(Item)); Put.ExecSQL;
        Inc(Done);
        if Assigned(Progress) and (Done mod 1000=0) then Progress('Проверка текущих карточек',Done,Iterator.RecordCount);
      end;
      DB.Commit;
    except DB.Rollback; raise; end;
  finally Iterator:=nil; Put.Free; end;
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
    '(p.Key IS NULL OR p.Stamp<>r.Stamp OR p.Physical<>r.Physical OR p.State=''missing''),'+
    'coalesce(p.SourceKey,''''),coalesce(p.Physical,''''),coalesce(p.Copies,1),coalesce(p.Container,''''),coalesce(p.InsideNo,0),'+
    'EXISTS(SELECT 1 FROM ApplyExcluded e WHERE e.Key=r.Key) '+
    'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key ORDER BY r.Location,r.BookID');
  Put:=DB.NewQuery('INSERT INTO ApplyActions VALUES(?,?,?,?,?,?,?,?,?,?)');
  Copies:=nil; CopyDB:=nil; CurrentLocation:=nil;
  try
    CopyDB:=TSQLiteDatabase.CreateReadOnly(FTargetFile);
    CurrentLocation:=CopyDB.NewQuery('SELECT Folder,InsideNo FROM Books WHERE BookID=?');
    if Bound then
    begin
      Copies:=CopyDB.NewQuery('SELECT Root,Folder,FileName,Ext,InsideNo FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?');
    end;
    Rows.Open; Done:=0; DB.Start;
    try
      while not Rows.Eof do
      begin
        Check; CheckSpace; ID:=0; Known:=Rows.FieldAsBoolean(2); State:=Rows.FieldAsString(3);
        Changed:=Rows.FieldAsBoolean(4); Eligible:=True; KeepMetadata:=False; Reason:=''; CheckedFile:='';
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
          OwnsFile:=not Bound or (BookPhysicalIdentity(Current)=Rows.FieldAsString(6)) or
            (BookPhysicalIdentity(Current)=BookPhysicalIdentity(Resolved)) or
            not FileExists(Current.GetBookFileName);
          if Bound and not OwnsFile then
          begin
            Copies.Reset; Copies.SetParam(0,Stamp); Copies.SetParam(1,ID); Copies.Open;
            if not Copies.Eof then
            begin
              CopyBook:=Default(TBookRecord); CopyBook.CollectionRoot:=Copies.FieldAsString(0);
              CopyBook.Folder:=Copies.FieldAsString(1); CopyBook.FileName:=Copies.FieldAsString(2);
              CopyBook.FileExt:=Copies.FieldAsString(3); CopyBook.InsideNo:=Copies.FieldAsInt(4);
              OwnsFile:=BookPhysicalIdentity(CopyBook)=BookPhysicalIdentity(Current);
            end;
          end;
          KeepMetadata:=not OwnsFile;
        end;
        if Eligible and Changed and not (bpIsDeleted in Item.BookProps) then
        begin
          Verified:=False;
          try Verified:=FInventory.Resolve(Resolved,FSource.BooksRoot,PreferNewRoot,Reason,CheckedFile);
          except on E:EAbort do raise; on E:Exception do Reason:=E.Message; end;
          Check;
          if not Verified then
          begin
            State:='missing'; Inc(FMissingCount);
            Name:=Item.FileName;
            if not SameText(ExtractFileExt(Name),Item.FileExt) then Name:=Name+Item.FileExt;
            if CheckedFile='' then CheckedFile:=Resolved.GetBookFileName;
            Reason:=CheckedFile+' | '+Name+' | '+Reason;
            if ID=0 then Eligible:=False
            else if not KeepMetadata then begin KeepMetadata:=True; Changed:=False; end;
          end
          else State:='known';
        end;
        if not FSource.Full and Known and (Rows.FieldAsString(3)<>'missing') then Changed:=False;
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
        if not Known or (Eligible and Changed) then
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
  TBookCollection_SQLite.CreateCollection(SystemData,FDeltaFile,CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  FDelta:=OpenCatalogSnapshot(FSourceInfo,FDeltaFile,SystemData);
  Cache:=TImportCache.Create; Genres:=TDictionary<string,TGenreData>.Create;
  Lookup:=DB.NewQuery('SELECT TargetID,KeepMetadata,Folder,InsideNo FROM ApplyActions WHERE BookID=?');
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
          DeltaID:=CopyReviewBook(FSnapshot,FDelta,Item,Cache,Genres);
        end;
        DB.ExecSQL('INSERT INTO ApplyDeltaInput VALUES(?,?)',[DeltaID,Rows.FieldAsInt(0)]); Rows.Next;
      end;
      FDelta.AfterBatchUpdate; FDelta.EndBulkOperation(True);
    except if FDelta.InBulkOperation then FDelta.EndBulkOperation(False); raise; end;
  finally FDelta.FinishBatchUpdate; Rows.Free; Lookup.Free; Genres.Free; Cache.Free; end;
  if Bound then
  begin
    SetLength(Sources,1); Sources[0].ID:=FSourceInfo.ID; Sources[0].Name:=FSourceInfo.Name;
    Sources[0].Root:=FSourceInfo.Root; Sources[0].LibraryNamespace:=FSourceInfo.LibraryNamespace;
    Sources[0].Collection:=FDelta; Sources[0].DatabaseFile:=FDeltaFile;
    FPlan:=TCollectionMergePlan.Create(Target,Sources,SystemData,mpSourcePriority);
    FActionLookup:=DB.NewQuery('SELECT a.TargetID,a.KeepMetadata FROM ApplyDeltaInput d JOIN ApplyActions a ON a.BookID=d.InputID WHERE d.DeltaID=?');
    FPlan.BookLookup:=function(const Source:TMergeSource; const Book:TBookRecord):Integer begin
      FActionLookup.Reset; FActionLookup.SetParam(0,Book.BookKey.BookID); FActionLookup.Open;
      Result:=FActionLookup.FieldAsInt(0);
    end;
    FPlan.BookChoice:=procedure(const Source:TMergeSource; const Incoming,Existing:TBookRecord; var KeepFile,KeepMetadata:Boolean) begin
      FActionLookup.Reset; FActionLookup.SetParam(0,Incoming.BookKey.BookID); FActionLookup.Open;
      KeepMetadata:=FActionLookup.FieldAsBoolean(1); KeepFile:=KeepMetadata;
    end;
    FPlan.Preview(nil,function:Boolean begin Check; Result:=False; end);
    FNewCards:=FPlan.NewBooks;
  end;
  Check;
  CheckTargetRevision(Target);
  FApplySummary:=Format('Применить обновление «%s»?%sНовых карточек: %d. Обновляемых записей/копий: %d.%s'+
    'Ранее удалённых записей не возвращаем: %d. Файлов пока нет или книга в архиве не найдена: %d.%s'+
    'Сохраняются личные данные и прежние папки. Сами книги и архивы не изменяются. Недокачанные книги можно добавить при следующей проверке.',
    [FSource.Name,sLineBreak,FNewCards,FUpdateCards,sLineBreak,FRemovedCount,FMissingCount,sLineBreak]);
  if FUnlistedCount>0 then FApplySummary:=FApplySummary+sLineBreak+
    Format('Прежних записей, которых нет в полном новом индексе: %d. Они исчезнут из каталога; файлы останутся на месте.',[FUnlistedCount]);
  FApplicationReady:=True;
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

procedure TLibraryUpdateReview.PrepareCache(const Check: TProc; const Progress: TLibraryReviewProgress);
var Folder, Base: string; SourceDB, Output: TSQLiteDatabase; Cached: IBookCollection;
  Rows: TSQLiteQuery; Book: TBookRecord; ID: Integer;
  Cache: TImportCache; Genres: TDictionary<string,TGenreData>; Writer: IBookImportedLocationWriter;
  MergeSource: TMergeSource; Expected, Generated: string;
begin
  Check; CheckSpace; CleanCache;
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
  SourceDB:=TSQLiteDatabase.CreateReadOnly(Base);
  try
    SourceDB.BackupTo(FPublishedSource.CacheFile,procedure(Done,Total:Integer) begin
      Check; CheckReviewOutputSpace(Folder,0);
      if Assigned(Progress) then Progress('Сохранение состояния источника',Done,Total);
    end);
  finally SourceDB.Free; end;
  TFile.Copy(FPrepared.FileName,FCacheInput,False);
  if not SameText(THashSHA2.GetHashStringFromFile(FCacheInput),FPrepared.SHA256) then
    raise EReadError.Create('Не совпала контрольная сумма сохранённого индекса.');
  FPublishedSource.INPXFile:=FCacheInput;
  Output:=TSQLiteDatabase.Create(FPublishedSource.CacheFile);
  try Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateAvailability(BookID INTEGER PRIMARY KEY,State TEXT NOT NULL)');
  finally Output.Free; end;
  if FSource.Full then
  begin
    Cached:=OpenCatalogSnapshot(FPublishedSource,FPublishedSource.CacheFile,DMUser.GetSystemDBConnection);
    if not Supports(Cached,IBookImportedLocationWriter,Writer) then
      raise ENotSupportedException.Create('Не поддержано сохранение путей импортированных книг.');
    Rows:=FActionDB.NewQuery('SELECT BookID,Folder,InsideNo FROM ApplyActions WHERE State=''known'' ORDER BY BookID');
    try
      Cached.BeginBulkOperation;
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          Check; Writer.SetImportedBookLocation(Rows.FieldAsInt(0),Rows.FieldAsString(1),Rows.FieldAsInt(2)); Rows.Next;
        end;
        Cached.EndBulkOperation(True);
      except if Cached.InBulkOperation then Cached.EndBulkOperation(False); raise; end;
    finally Rows.Free; Writer:=nil; Cached:=nil; end;
    Output:=TSQLiteDatabase.Create(FPublishedSource.CacheFile);
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
    Cached:=OpenCatalogSnapshot(FPublishedSource,FPublishedSource.CacheFile,DMUser.GetSystemDBConnection);
    if not Supports(Cached,IBookImportedLocationWriter,Writer) then
      raise ENotSupportedException.Create('Не поддержано сохранение путей импортированных книг.');
    Cache:=TImportCache.Create; Genres:=TDictionary<string,TGenreData>.Create;
    Rows:=FActionDB.NewQuery('SELECT r.BookID,p.BookID,a.Folder,a.InsideNo,a.State FROM ReviewRows r '+
      'LEFT JOIN ReviewPrevious p ON p.Key=r.Key JOIN ApplyActions a ON a.BookID=r.BookID ORDER BY r.BookID');
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
          else if Rows.FieldAsString(4)='known' then
            Writer.SetImportedBookLocation(ID,Rows.FieldAsString(2),Rows.FieldAsInt(3));
          FActionDB.ExecSQL('INSERT INTO ApplyCachedInput VALUES(?,?)',[Book.BookKey.BookID,ID]);
          Rows.Next;
        end;
        Cached.SetProperty(PROP_DATAVERSION,FVersion); Cached.AfterBatchUpdate; Cached.EndBulkOperation(True);
      except if Cached.InBulkOperation then Cached.EndBulkOperation(False); raise; end;
    finally Cached.FinishBatchUpdate; Writer:=nil; Rows.Free; Genres.Free; Cache.Free; Cached:=nil; end;
    // Availability is keyed by the raw record identity, which survives a
    // native cache append even when its numeric IDs differ from the package.
    Output:=TSQLiteDatabase.Create(FPublishedSource.CacheFile);
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
  Output:=TSQLiteDatabase.Create(FPublishedSource.CacheFile);
  try
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateSourceKeys(BookID INTEGER PRIMARY KEY,SourceKey TEXT NOT NULL)');
    Output.ExecSQL('CREATE TABLE IF NOT EXISTS LibraryUpdateExclusions(Key TEXT PRIMARY KEY) WITHOUT ROWID');
    Output.ExecSQL('ATTACH DATABASE ? AS review',[FAnalysisFile]);
    Output.ExecSQL('INSERT OR IGNORE INTO LibraryUpdateExclusions SELECT Key FROM review.ApplyExcluded');
    if FSource.Full then
      Rows:=Output.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.LibID,a.SourceKey '+
        'FROM Books b JOIN review.ApplyActions a ON a.BookID=b.BookID ORDER BY b.BookID')
    else
      Rows:=Output.NewQuery('SELECT b.BookID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.LibID,a.SourceKey '+
        'FROM Books b JOIN review.ApplyCachedInput m ON m.CacheID=b.BookID '+
        'JOIN review.ApplyActions a ON a.BookID=m.InputID ORDER BY b.BookID');
    try
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

procedure TLibraryUpdateReview.RestoreCopySizes(const Collection: IBookCollection; const Check: TProc);
  var Iterator: IBookIterator; CopyBook, Preferred: TBookRecord; Source: TMergeSource; Key: string; ID: Integer;
  begin
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
      end;
    end;
  end;

procedure TLibraryUpdateReview.Apply(const Target: IBookCollection; const SystemData: ISystemData;
  const Check: TProc; const Progress: TLibraryReviewProgress; out Committed: Boolean);
var Backup, Folder: string; Books: IBookIterator; Book, Prepared: TBookRecord;
  Rows: TSQLiteQuery; Cache: TImportCache; Genres: TDictionary<string,TGenreData>;
  LocalBooks: TArray<TLocalCatalogBook>; Done: Integer;
  SavedSQL: TSQLiteCancelCallback;
  Witness: ISystemCatalogCommitWitness; SystemStarted: Boolean;
begin
  Committed:=False;
  if not FApplicationReady then raise EInvalidOperation.Create('Обновление ещё не подготовлено.');
  if not Supports(SystemData,ISystemCatalogCommitWitness,Witness) then
    raise ENotSupportedException.Create('Хранилище личных данных не поддерживает согласованное обновление.');
  Check;
  CheckTargetRevision(Target);
  PrepareCache(Check,Progress);
  CheckTargetRevision(Target);
  if Assigned(FPlan) then
  begin
    FPlan.AfterBegin:=procedure(const Collection:IBookCollection) begin
      Collection.SetProperty(PROP_DATAVERSION,Collection.GetProperty(PROP_DATAVERSION));
      CheckTargetRevision(Collection);
      FPreviousLastID:=Collection.StartCatalogUpdateTracking(True);
    end;
    FPlan.BeforeCommit:=procedure(const Collection:IBookCollection) begin
      Check; Collection.FinishCatalogUpdateTracking(True,FPreviousLastID); RestoreCopySizes(Collection,Check); StoreAppliedState(Collection);
      Witness.SetCatalogCommitWitness(Collection.CollectionID,FOperationID);
    end;
    Folder:=TPath.Combine(Settings.DataPath,'LibraryUpdateBackups'); ForceDirectories(Folder);
    Backup:=TPath.Combine(Folder,TGUID.NewGuid.ToString);
    FPlan.StageProgress:=procedure(const Stage:string; Done,Total:Integer) begin
      if Assigned(Progress) then Progress(Stage,Done,Total);
    end;
    try FPlan.Apply(Backup,procedure(Done,Total:Integer) begin
      if Assigned(Progress) then Progress('Обновление источника',Done,Total);
    end,function:Boolean begin Check; Result:=False; end);
    finally
      FPlan.StageProgress:=nil;
      Committed:=FPlan.CatalogCommitted; FCachePublished:=Committed; FApplied:=Committed;
    end;
    if Committed then
    begin
      SavedSQL:=SQLiteCancelCallback; SQLiteCancelCallback:=nil;
      try SystemData.RemapCollectionBookIDs(Target.CollectionID,False);
      finally SQLiteCancelCallback:=SavedSQL; end;
    end;
    Exit;
  end;
  Folder:=TPath.Combine(Settings.DataPath,'LibraryUpdateBackups'); ForceDirectories(Folder);
  Backup:=TPath.Combine(Folder,TGUID.NewGuid.ToString+'.hlc2');
  CheckReviewOutputSpace(Folder,UInt64(TFile.GetSize(FTargetFile)));
  var BackupDB:=TSQLiteDatabase.CreateReadOnly(FTargetFile);
  try
    BackupDB.BackupTo(Backup,procedure(Done,Total:Integer) begin
      Check; CheckReviewOutputSpace(Folder,0);
      if Assigned(Progress) then Progress('Резервная копия каталога',Done,Total);
    end);
  finally BackupDB.Free; end;
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
      begin LocalBooks:=Target.CaptureLocalBooks; Target.TruncateTablesBeforeImport; end;
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
            if Rows.FieldAsInt(3)>0 then CopyReviewBook(FDelta,Target,Book,Cache,Genres)
            else CopyReviewBook(FSnapshot,Target,Book,Cache,Genres);
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
        Target.RestoreLocalBooks(LocalBooks);
      Check;
      SystemData.BeginDataUpdate; SystemStarted:=True;
      StoreAppliedState(Target); Witness.SetCatalogCommitWitness(Target.CollectionID,FOperationID);
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
    NotifyLibraryUpdateTestPoint('stores-committed');
  finally
    SQLiteCancelCallback:=nil;
    try if SystemStarted then SystemData.EndDataUpdate(False);
    finally SQLiteCancelCallback:=SavedSQL; Books:=nil; Rows.Free; Genres.Free; Cache.Free; end;
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
  private FReview: TLibraryUpdateReview; FPreferNew: Boolean;
  protected procedure WorkFunction; override;
  public constructor Create(CollectionID: Integer; Review: TLibraryUpdateReview; PreferNew: Boolean);
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

constructor TReviewedApplyWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview; PreferNew: Boolean);
begin inherited Create(CollectionID); FReview:=Review; FPreferNew:=PreferNew; end;

procedure TReviewedApplyWorker.WorkFunction;
var Control: TLibraryUpdateControl; Check: TProc; Progress: TLibraryReviewProgress;
begin
  Control:=TLibraryUpdateControl.Create(FReview,Self);
  try
    Check:=procedure begin Control.Check; end;
    Progress:=procedure(const Stage:string; Done,Total:Integer) begin
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end;
      SetComment(Stage);
    end;
    try
      FReview.PrepareApplication(FCollection,FSystemData,FPreferNew,Check,Progress);
      if ShowMessage(FReview.ApplySummary,MB_YESNO or MB_ICONQUESTION or MB_DEFBUTTON2)<>IDYES then Exit;
      FReview.Apply(FCollection,FSystemData,Check,Progress,FChangesCommitted);
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
begin inherited Create(CollectionID); FReview:=Review; FGenresType:=gtFb2; FKeepCollectionProps:=True; end;

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
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end;
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
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end;
      SetComment(Stage);
    end);
  FOperationSuccess:=True;
  finally FImportCheck:=nil; Control.Free; end;
end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;
begin
  if TMetabibReader.IsDatasetFile(Review.FPrepared.FileName) then Result:=TMetabibReviewWorker.Create(CollectionID,Review)
  else Result:=TInpxReviewWorker.Create(CollectionID,Review);
end;

function CreateLibraryApplyWorker(CollectionID: Integer; Review: TLibraryUpdateReview;
  PreferNewRoot: Boolean): TCollectionWorker;
begin Result:=TReviewedApplyWorker.Create(CollectionID,Review,PreferNewRoot); end;

end.
