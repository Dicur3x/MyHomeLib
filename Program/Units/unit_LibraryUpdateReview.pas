unit unit_LibraryUpdateReview;

interface

uses System.SysUtils, System.Classes, unit_Interfaces, unit_Globals,
  unit_CatalogSources, unit_LibraryUpdateSources, unit_LibraryUpdateFetch,
  unit_CollectionWorkerThread;

type
  TLibraryReviewProgress = reference to procedure(const Stage: string; Done, Total: Integer);
  TLibraryUpdateReview = class
  private
    FSource: TLibraryUpdateSource;
    FPrepared: TStagedLibraryIndex; // Borrowed; the window releases the review first.
    FSnapshot: IBookCollection;
    FSourceInfo: TCatalogSource;
    FDatabaseFile, FTargetRevision, FTargetFile, FSummary: string;
    FNeeded, FHistorical, FFound, FAmbiguous: TStringList;
    FNewBooks, FChangedBooks, FTotal, FVersion, FDeleted, FSkipped: Integer;
    FPreviousIndex, FReady: Boolean;
    FLastSpaceCheck: UInt64;
    procedure Analyze(const Target, Previous: IBookCollection; const Check: TProc;
      const Progress: TLibraryReviewProgress);
  public
    constructor Create(const Source: TLibraryUpdateSource; Prepared: TStagedLibraryIndex);
    destructor Destroy; override;
    procedure CheckSpace;
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
  end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;

implementation

uses Winapi.Windows, Vcl.ComCtrls, System.IOUtils, System.Hash, System.Variants,
  unit_Consts, unit_Database_SQLite, SQLiteWrap, unit_LibrarySourceID,
  unit_ImportInpxThread, unit_ImportMetabibThread, unit_MetabibReader,
  unit_MHLArchiveHelpers, unit_Settings, dm_user;

constructor TLibraryUpdateReview.Create(const Source: TLibraryUpdateSource; Prepared: TStagedLibraryIndex);
begin
  inherited Create; Source.Validate;
  if not Assigned(Prepared) then raise EArgumentNilException.Create('Prepared');
  FSource:=Source; FPrepared:=Prepared;
  FNeeded:=TStringList.Create; FHistorical:=TStringList.Create;
  FFound:=TStringList.Create; FAmbiguous:=TStringList.Create;
end;

destructor TLibraryUpdateReview.Destroy;
begin
  FSnapshot:=nil;
  // Only files explicitly created by this review; never recursive cleanup.
  if FDatabaseFile<>'' then
    for var Suffix in TArray<string>.Create('','-wal','-shm','-journal') do
      if FileExists(FDatabaseFile+Suffix) then
        try TFile.Delete(FDatabaseFile+Suffix); except end;
  FNeeded.Free; FHistorical.Free; FFound.Free; FAmbiguous.Free;
  inherited;
end;

procedure TLibraryUpdateReview.CheckSpace;
var Available, Capacity: UInt64;
begin
  if (FLastSpaceCheck<>0) and (GetTickCount64-FLastSpaceCheck<1000) then Exit;
  FLastSpaceCheck:=GetTickCount64;
  if not GetDiskFreeSpaceEx(PChar(GetEnvironmentVariable('SystemDrive')+'\'),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then
    raise EWriteError.Create('На системном диске осталось меньше 8 ГБ. Проверка обновления остановлена.');
  if not GetDiskFreeSpaceEx(PChar(FPrepared.Folder),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(512)*1024*1024 then
    raise EWriteError.Create('Недостаточно места для проверки индекса. Текущая коллекция не изменена.');
end;

procedure TLibraryUpdateReview.Build(const Target: IBookCollection; const SystemData: ISystemData;
  const Import: TProc<IBookCollection>; const Check: TProc; const Progress: TLibraryReviewProgress);
var Previous: IBookCollection; Found: Boolean; Namespace, SnapshotFile: string;
begin
  FReady:=False; CheckSpace; Check;
  FTargetRevision:=Target.GetCatalogRevision;
  FTargetFile:=Settings.ExpandCollectionFileName(VarToStr(Target.GetProperty(PROP_DATAFILE)));
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
  if (FSource.CatalogSourceID<>'') and FSourceInfo.IsINPX and FileExists(FSourceInfo.CacheFile) then
  begin Previous:=OpenCatalogSource(FSourceInfo,SystemData); FPreviousIndex:=True; end;
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
  Analyze(Target,Previous,Check,Progress);
  Check;
  if FTargetRevision<>Target.GetCatalogRevision then
    raise EReadError.Create('Коллекция изменилась во время проверки. Проверьте обновление заново.');
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

procedure TLibraryUpdateReview.Analyze(const Target, Previous: IBookCollection;
  const Check: TProc; const Progress: TLibraryReviewProgress);
var DB: TSQLiteDatabase; Insert, Query: TSQLiteQuery; Iterator: IPublisherSeriesIndexIterator;
  Book, Candidate: TBookRecord; Stamp, Namespace, Key, Name, OldPath, NewPath, Path, Version: string;
  Count, Total, NewCount, ChangedCount: Integer; Existing, CandidateExists: Boolean;
  procedure Load(const Collection: IBookCollection; IsPrevious: Boolean);
  begin
    Namespace:=VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY));
    if IsPrevious and FPreviousIndex and (FSourceInfo.LibraryNamespace<>'') then Namespace:=FSourceInfo.LibraryNamespace;
    Iterator:=Collection.GetPublisherSeriesIndexIterator; Count:=0; Total:=Iterator.RecordCount;
    while Iterator.Next(Book,Stamp) do
    begin
      Check; CheckSpace;
      Key:=ReviewBookKey(Book,Namespace,FSourceInfo.Root);
      Insert.Reset; Insert.SetParam(0,Key); Insert.SetParam(1,ReviewStamp(Book));
      if not IsPrevious then
      begin
        Insert.SetParam(2,Book.BookKey.BookID);
        if Book.GetBookFormat in [bfFb2Archive,bfRawArchive] then Name:=Book.Folder
        else Name:=TPath.Combine(Book.Folder,Book.FileName)+Book.FileExt;
        Insert.SetParam(3,Name);
        Insert.SetParam(4,not (bpIsDeleted in Book.BookProps));
      end;
      Insert.ExecSQL; Inc(Count);
      if Assigned(Progress) and ((Count mod 1000=0) or (Count=Total)) then
        if IsPrevious then Progress('Сопоставление с прежними книгами',Count,Total)
        else Progress('Проверка нового списка книг',Count,Total);
    end;
    Iterator:=nil;
  end;
begin
  DB:=TSQLiteDatabase.Create(FDatabaseFile); Insert:=nil; Query:=nil;
  try
    DB.ExecSQL('CREATE TABLE ReviewPrevious(Key TEXT PRIMARY KEY, Stamp TEXT) WITHOUT ROWID');
    DB.ExecSQL('CREATE TABLE ReviewRows(Key TEXT,Stamp TEXT,BookID INTEGER,Location TEXT,Active INTEGER)');
    // Build the empty index before streaming rows. GROUP BY/ORDER BY can walk
    // it without a large sort spilling to Windows TEMP on the system drive.
    DB.ExecSQL('CREATE INDEX ReviewRowsLocation ON ReviewRows(Location)');
    DB.Start;
    try
      Insert:=DB.NewQuery('INSERT OR IGNORE INTO ReviewPrevious VALUES(?,?)'); Load(Previous,True); FreeAndNil(Insert);
      Insert:=DB.NewQuery('INSERT INTO ReviewRows VALUES(?,?,?,?,?)'); Load(FSnapshot,False); FreeAndNil(Insert);
      DB.Commit;
    except DB.Rollback; raise; end;
    FTotal:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows');
    FDeleted:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows WHERE Active=0');
    FNewBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key WHERE r.Active<>0 AND p.Key IS NULL');
    FChangedBooks:=DB.QuerySingleInt('SELECT count(*) FROM ReviewRows r JOIN ReviewPrevious p ON p.Key=r.Key WHERE r.Active<>0 AND p.Stamp<>r.Stamp');
    Query:=DB.NewQuery('SELECT r.Location,min(r.BookID),sum(r.Active<>0 AND p.Key IS NULL),sum(r.Active<>0 AND p.Key IS NOT NULL AND p.Stamp<>r.Stamp) '+
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
  finally Iterator:=nil; Query.Free; Insert.Free; DB.Free; end;
end;

type
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

constructor TInpxReviewWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview);
begin inherited Create(CollectionID); FReview:=Review; FGenresType:=gtFb2; FKeepCollectionProps:=True; end;

procedure TInpxReviewWorker.WorkFunction;
var Zip: TMHLZip; HasEntries: Boolean;
begin
  FImportCheck:=procedure begin
    if Canceled then raise EAbort.Create('Проверка обновления отменена.'); FReview.CheckSpace;
  end;
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
  FOperationSuccess:=True; FImportCheck:=nil;
end;

constructor TMetabibReviewWorker.Create(CollectionID: Integer; Review: TLibraryUpdateReview);
begin inherited Create(CollectionID); FReview:=Review; FGenresType:=gtFb2; end;

procedure TMetabibReviewWorker.WorkFunction;
begin
  FImportCheck:=procedure begin
    if Canceled then raise EAbort.Create('Проверка обновления отменена.'); FReview.CheckSpace;
  end;
  FReview.Build(FCollection,FSystemData,
    procedure(Collection: IBookCollection) begin
      Import(FReview.FPrepared.FileName,False,Collection); FReview.FSkipped:=FInvalidRows;
    end,
    FImportCheck,procedure(const Stage:string; Done,Total:Integer) begin
      if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end;
      SetComment(Stage);
    end);
  FOperationSuccess:=True; FImportCheck:=nil;
end;

function CreateLibraryReviewWorker(CollectionID: Integer; Review: TLibraryUpdateReview): TCollectionWorker;
begin
  if TMetabibReader.IsDatasetFile(Review.FPrepared.FileName) then Result:=TMetabibReviewWorker.Create(CollectionID,Review)
  else Result:=TInpxReviewWorker.Create(CollectionID,Review);
end;

end.
