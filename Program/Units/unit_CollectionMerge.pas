unit unit_CollectionMerge;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections,
  unit_Interfaces, unit_Globals;

type
  TCollectionMergePolicy = (mpKeepAll, mpSourcePriority, mpSmallestFile);
  TMergeSource = record
    ID, Name, DatabaseFile, Root, LibraryNamespace: string;
    Collection: IBookCollection;
  end;
  TMergeSources = TArray<TMergeSource>;
  TMergeProgress = reference to procedure(Current, Total: Integer);
  TMergeStageProgress = reference to procedure(const Stage: string; Current, Total: Integer);
  TMergeCanceled = reference to function: Boolean;
  TMergeUserValues = record Rate, Progress: Integer; end;

  TCollectionMergePlan = class
  private
    FTarget: IBookCollection;
    FSystem: ISystemData;
    FSources: TMergeSources;
    FLocations: TDictionary<string, Integer>;
    FResolvedContainers: TDictionary<string,string>;
    FIdentities: TDictionary<string, Integer>;
    FTargetUserValues: TDictionary<Integer, TMergeUserValues>;
    FPolicy: TCollectionMergePolicy;
    FTargetNamespace: string;
    FReport: TStringList;
    FStamps: TDictionary<string, string>;
    FReportWriter: TStreamWriter;
    FFullReportFile: string;
    FNewBooks, FDuplicates, FTotal, FConflicts: Integer;
    FReady: Boolean;
    FReadCacheHits, FReadCacheBooks, FSourceLookupCount: Integer;
    FHasStableSourceLinks: Boolean;
    FStageProgress: TMergeStageProgress;
    function ResolvedContainer(const Book: TBookRecord): string;
    procedure LoadTarget(const Canceled: TMergeCanceled = nil);
    procedure AddReport(const Text: string);
    procedure CaptureStamps;
    procedure CheckResolvedContainers;
    procedure CheckStamps;
  public
    constructor Create(const Target: IBookCollection; const Sources: TMergeSources;
      const SystemData: ISystemData = nil; Policy: TCollectionMergePolicy = mpKeepAll);
    destructor Destroy; override;
    procedure Preview(const Progress: TMergeProgress = nil; const Canceled: TMergeCanceled = nil);
    procedure Apply(const BackupFolder: string; const Progress: TMergeProgress = nil;
      const Canceled: TMergeCanceled = nil);
    property Report: TStringList read FReport;
    property FullReportFile: string read FFullReportFile;
    property NewBooks: Integer read FNewBooks;
    property Duplicates: Integer read FDuplicates;
    property Conflicts: Integer read FConflicts;
    property Total: Integer read FTotal;
    property ReadCacheHits: Integer read FReadCacheHits;
    property ReadCacheBooks: Integer read FReadCacheBooks;
    property SourceLookupCount: Integer read FSourceLookupCount;
    property StageProgress: TMergeStageProgress read FStageProgress write FStageProgress;
  end;

function BookPhysicalIdentity(const Book: TBookRecord): string;
function MergeSourceKey(const Source: TMergeSource; const Book: TBookRecord): string;
function BookLibraryIdentity(const Book: TBookRecord; const LibraryNamespace: string): string;
procedure BackupCollectionFile(const SourceFile, BackupFile: string);

implementation

uses Winapi.Windows, System.IOUtils, System.Hash, System.Variants, System.Math, System.DateUtils,
  unit_Consts, unit_Settings, unit_UserData, SQLiteWrap, dm_user, unit_LibrarySourceID, SQLiteProfile;

function BookLibraryIdentity(const Book: TBookRecord; const LibraryNamespace: string): string;
var ID, Namespace, OriginalID: string; C: Char; P: Integer;
begin
  Result := '';
  // Deleted/empty entries are placeholders, not evidence of equal content.
  if (bpIsDeleted in Book.BookProps) or (Book.Size <= 0) or (Trim(Book.Title) = '') then Exit;
  ID := Book.LibID;
  if ID.StartsWith('merged:', True) then
  begin
    Delete(ID, 1, Length('merged:')); P := Pos(':', ID);
    if P = 0 then Exit;
    Delete(ID, 1, P);
  end;
  Namespace := LowerCase(Trim(LibraryNamespace));
  if TryParseLibrarySourceID(ID, Namespace, OriginalID) then ID := OriginalID
  else
  begin
    Namespace := LowerCase(Trim(LibraryNamespace));
    if (Namespace <> 'flibusta') and (Namespace <> 'librusec') then Exit;
    if ID = '' then Exit;
    for C in ID do if not CharInSet(C, ['0'..'9']) then Exit;
  end;
  // IDs from different libraries can collide. A changed title/language/format
  // is kept apart even when the numeric ID matches; file size is not identity.
  Result := THashSHA2.GetHashString(Namespace + #1 + ID + #1 +
    LowerCase(Trim(Book.Title)) + #1 + LowerCase(Trim(Book.Lang)) + #1 + LowerCase(Book.FileExt));
end;

function PhysicalIdentityAt(const Book: TBookRecord; const Resolved: string): string;
var Container, Name: string;
begin
  Container := Resolved;
  if Book.GetBookFormat(Container) in [bfFb2Archive, bfRawArchive] then
  begin
    Name := Book.FileName;
    if not SameText(ExtractFileExt(Name), Book.FileExt) then Name := Name + Book.FileExt;
    // An archive index may change between INPX revisions; the member name is stable.
    Result := LowerCase(Container + #1 + StringReplace(Name, '/', '\', [rfReplaceAll]));
  end
  else Result := LowerCase(TPath.GetFullPath(Book.GetBookFileName(Container)));
  Result := THashSHA2.GetHashString(Result);
end;

function SourceKeyAt(const Source: TMergeSource; const Book: TBookRecord; const Resolved: string): string;
var Root, Path, Name: string;
begin
  // An INPX may repeat LIBID for different files, formats or placeholder rows.
  // Use the actual member, relative to the source root so moving it is stable.
  Root := Source.Root;
  if Root = '' then Root := Book.CollectionRoot;
  if Book.GetBookFormat(Resolved) in [bfFb2Archive, bfRawArchive] then
  begin
    Path := Resolved;
    Name := Book.FileName;
    if not SameText(ExtractFileExt(Name), Book.FileExt) then Name := Name + Book.FileExt;
  end
  else begin Path := TPath.GetFullPath(Book.GetBookFileName(Resolved)); Name := ''; end;
  if Root <> '' then Path := ExtractRelativePath(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)), Path);
  Result := Source.ID + ':file:' + THashSHA2.GetHashString(LowerCase(
    StringReplace(Path + #1 + Name, '/', '\', [rfReplaceAll])));
end;

function BookPhysicalIdentity(const Book: TBookRecord): string;
begin Result:=PhysicalIdentityAt(Book,TPath.GetFullPath(Book.GetBookContainer)); end;

function MergeSourceKey(const Source: TMergeSource; const Book: TBookRecord): string;
begin Result:=SourceKeyAt(Source,Book,TPath.GetFullPath(Book.GetBookContainer)); end;

function TCollectionMergePlan.ResolvedContainer(const Book: TBookRecord): string;
var Key: string;
begin
  Key:=LowerCase(TPath.Combine(Book.CollectionRoot,Book.Folder));
  if FResolvedContainers.TryGetValue(Key,Result) then Exit;
  Result:=TPath.GetFullPath(Book.GetBookContainer);
  // Container count is small for archive libraries, but bound loose-file catalogs too.
  if FResolvedContainers.Count>=65536 then FResolvedContainers.Clear;
  FResolvedContainers.Add(Key,Result);
end;

procedure TCollectionMergePlan.CheckResolvedContainers;
var Pair: TPair<string,string>; Current, Fallback: string;
begin
  // A newly appearing ZIP or a move to 7z changes physical book identities.
  // Reject the old preview rather than linking to a stale archive path.
  for Pair in FResolvedContainers do
  begin
    Current:=Pair.Key;
    if SameText(ExtractFileExt(Current),ZIP_EXTENSION) and not FileExists(Current) then
    begin
      Fallback:=ChangeFileExt(Current,SEVENZIP_EXTENSION);
      if FileExists(Fallback) then Current:=Fallback;
    end;
    if not SameFileName(TPath.GetFullPath(Current),Pair.Value) then
      raise Exception.Create('Расположение архивов изменилось. Повторите проверку объединения.');
  end;
end;

procedure BackupCollectionFile(const SourceFile, BackupFile: string);
var DB: TSQLiteDatabase;
begin
  if SameText(TPath.GetFullPath(SourceFile), TPath.GetFullPath(BackupFile)) then
    raise Exception.Create('Резервная копия не может заменять исходный каталог.');
  DB := TSQLiteDatabase.CreateReadOnly(SourceFile);
  try DB.BackupTo(BackupFile); finally DB.Free; end;
end;

constructor TCollectionMergePlan.Create(const Target: IBookCollection; const Sources: TMergeSources;
  const SystemData: ISystemData; Policy: TCollectionMergePolicy);
var Source: TMergeSource; IDs: TDictionary<string, Boolean>; TargetFile: string; I: Integer;
begin
  inherited Create;
  if not Assigned(Target) or isOnlineCollection(Target.CollectionCode) then
    raise Exception.Create('Объединение поддерживается только в локальной коллекции.');
  TargetFile := Settings.ExpandCollectionFileName(VarToStr(Target.GetProperty(PROP_DATAFILE)));
  IDs := TDictionary<string, Boolean>.Create;
  try
  for Source in Sources do
  begin
    if SameFileName(TPath.GetFullPath(Source.DatabaseFile), TPath.GetFullPath(TargetFile)) then
      raise Exception.Create('Источник и назначение указывают на один каталог.');
    if IDs.ContainsKey(Source.ID) then raise Exception.Create('Источник добавлен дважды.');
    IDs.Add(Source.ID, True);
    if not Assigned(Source.Collection) or isOnlineCollection(Source.Collection.CollectionCode) then
      raise Exception.Create('Источник объединения должен быть локальной коллекцией.');
    if Source.Collection.CollectionID = Target.CollectionID then
      raise Exception.Create('Нельзя объединить коллекцию с самой собой.');
    if Source.ID = '' then raise Exception.Create('У источника отсутствует постоянный идентификатор.');
  end;
  finally IDs.Free; end;
  FTarget := Target; FSources := Copy(Sources); FSystem := SystemData;
  FPolicy := Policy;
  FTargetNamespace := VarToStr(Target.GetProperty(PROP_SOURCE_LIBRARY));
  for I := 0 to High(FSources) do
    if FSources[I].LibraryNamespace = '' then
      FSources[I].LibraryNamespace := VarToStr(FSources[I].Collection.GetProperty(PROP_SOURCE_LIBRARY));
  if not Assigned(FSystem) then FSystem := SystemDB;
  FResolvedContainers:=TDictionary<string,string>.Create;
  FLocations := TDictionary<string, Integer>.Create; FReport := TStringList.Create;
  FIdentities := TDictionary<string, Integer>.Create;
  FTargetUserValues:=TDictionary<Integer,TMergeUserValues>.Create;
  FStamps := TDictionary<string, string>.Create;
end;

destructor TCollectionMergePlan.Destroy;
begin
  FResolvedContainers.Free; FReportWriter.Free;
  try
    if (FFullReportFile <> '') and FileExists(FFullReportFile) then TFile.Delete(FFullReportFile);
  except
    // A locked temporary report must not prevent release of catalog connections.
  end;
  FStamps.Free; FReport.Free; FTargetUserValues.Free; FIdentities.Free; FLocations.Free; inherited;
end;

procedure TCollectionMergePlan.AddReport(const Text: string);
begin
  if Assigned(FReportWriter) then FReportWriter.WriteLine(Text);
  if FReport.Count < 2048 then FReport.Add(Text)
  else if FReport.Count = 2048 then
    FReport.Add('Остальные строки включены в полный отчёт. Нажмите «Сохранить отчёт...».');
end;

procedure TCollectionMergePlan.CaptureStamps;
var I: Integer;
begin
  FStamps.Clear;
  FStamps.Add('target', FTarget.GetCatalogRevision);
  FStamps.Add('system', FSystem.GetDataRevision);
  for I := 0 to High(FSources) do FStamps.Add(IntToStr(I), FSources[I].Collection.GetCatalogRevision);
end;

procedure TCollectionMergePlan.CheckStamps;
var I: Integer;
  procedure Check(const Key, Revision: string);
  begin
    if FStamps[Key] <> Revision then
    begin
      FReady := False;
      raise Exception.Create('После начала предпросмотра каталог изменился. Выполните предпросмотр заново.');
    end;
  end;
begin
  Check('target', FTarget.GetCatalogRevision); Check('system', FSystem.GetDataRevision);
  for I := 0 to High(FSources) do Check(IntToStr(I), FSources[I].Collection.GetCatalogRevision);
end;

function AllBooks(const Collection: IBookCollection; LoadMemos: Boolean): IBookIterator;
var Hide, Local: Boolean;
begin
  Hide := Collection.GetHideDeleted; Local := Collection.GetShowLocalOnly;
  Collection.SetHideDeleted(False); Collection.SetShowLocalOnly(False);
  try Result := Collection.GetBookIterator(bmAll, LoadMemos);
  finally Collection.SetHideDeleted(Hide); Collection.SetShowLocalOnly(Local); end;
end;

procedure TCollectionMergePlan.LoadTarget(const Canceled: TMergeCanceled);
var Iterator: IPublisherSeriesIndexIterator; Book: TBookRecord; Stamp, Identity: string;
  Count, Total: Integer; Values: TMergeUserValues;
begin
  FResolvedContainers.Clear; FLocations.Clear; FIdentities.Clear; FTargetUserValues.Clear;
  Iterator := FTarget.GetPublisherSeriesIndexIterator;
  Count := 0; Total := Iterator.RecordCount;
  if Assigned(FStageProgress) then FStageProgress('Указатель файлов текущей коллекции', 0, Total);
  while Iterator.Next(Book, Stamp) do
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Операция отменена.');
    FLocations.AddOrSetValue(PhysicalIdentityAt(Book,ResolvedContainer(Book)), Book.BookKey.BookID);
    // These fields are already in the lightweight snapshot. Store only personal
    // values, avoiding a second random database read for every matched book.
    if (Book.Rate<>0) or (Book.Progress<>0) then
    begin
      Values.Rate:=Book.Rate; Values.Progress:=Book.Progress;
      FTargetUserValues.Add(Book.BookKey.BookID,Values);
    end;
    if FPolicy <> mpKeepAll then
    begin
      Identity := BookLibraryIdentity(Book, FTargetNamespace);
      if (Identity <> '') and not FIdentities.ContainsKey(Identity) then
        FIdentities.Add(Identity, Book.BookKey.BookID);
    end;
    Inc(Count);
    if Assigned(FStageProgress) and ((Count mod 1000 = 0) or (Count = Total)) then
      FStageProgress('Указатель файлов текущей коллекции', Count, Total);
  end;
end;

procedure TCollectionMergePlan.Preview(const Progress: TMergeProgress; const Canceled: TMergeCanceled);
var Source: TMergeSource; Iterator: IPublisherSeriesIndexIterator; Book: TBookRecord;
  Key, CompareKey, Identity: string; ID, Count, SourceNew, SourceLinked, SourcePhysical: Integer;
  AlreadyLinked: Boolean; Seen: TDictionary<string, TMergeUserValues>;
  Locations, Identities: TDictionary<string, Integer>;
  Values: TMergeUserValues; ReportID: TGUID; Stamp, TargetFile: string;
  DB: TSQLiteDatabase; Lookup: TSQLiteQuery; Summaries: TStringList;
begin
  FReady := False; FNewBooks := 0; FDuplicates := 0; FConflicts := 0; FTotal := 0; Count := 0;
  FReport.Clear; FSourceLookupCount:=0; CaptureStamps; LoadTarget(Canceled);
  if (FFullReportFile <> '') and FileExists(FFullReportFile) then TFile.Delete(FFullReportFile);
  CreateGUID(ReportID); ForceDirectories(Settings.TempPath);
  FFullReportFile := TPath.Combine(Settings.TempPath, 'merge-preview-' + GUIDToString(ReportID) + '.txt');
  FReportWriter := TStreamWriter.Create(FFullReportFile,False,TEncoding.UTF8,65536);
  Seen := TDictionary<string, TMergeUserValues>.Create;
  Locations := TDictionary<string, Integer>.Create;
  Identities := TDictionary<string, Integer>.Create;
  DB := nil; Lookup := nil; Summaries := TStringList.Create;
  try
    TargetFile := Settings.ExpandCollectionFileName(VarToStr(FTarget.GetProperty(PROP_DATAFILE)));
    DB := TSQLiteDatabase.CreateReadOnly(TargetFile);
    // Legacy numeric links cannot match the stable file keys. When there are
    // no stable links at preview time, physical identities cover all matches
    // created during this operation. CheckStamps protects this snapshot.
    FHasStableSourceLinks:=False;
    // The primary-key prefix range avoids scanning millions of legacy keys.
    // Only links belonging to a participating source can affect this plan.
    for Source in FSources do
      if DB.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM CatalogSourceBooks WHERE SourceKey>=? AND SourceKey<?)',
        [Source.ID+':file:',Source.ID+':file;'])<>0 then
      begin FHasStableSourceLinks:=True; Break; end;
    Lookup := DB.NewQuery('SELECT l.BookID FROM CatalogSourceBooks l JOIN Books b ON b.BookID=l.BookID WHERE l.SourceKey=?');
    for Source in FSources do
    begin Iterator := Source.Collection.GetPublisherSeriesIndexIterator; Inc(FTotal, Iterator.RecordCount); end;
    AddReport('Приоритет: источники сверху вниз. Совпадение — один файл или член одного архива.');
    case FPolicy of
      mpKeepAll: AddReport('Режим: сохранить все разные копии. Одинаковые числовые LIBID разных источников не объединяются.');
      mpSourcePriority: AddReport('Режим: объединить проверенные ID одной библиотеки; файл выбирается по порядку источников сверху вниз.');
      mpSmallestFile: AddReport('Режим: объединить проверенные ID одной библиотеки; предпочитать меньший файл. Размер не определяет качество.');
    end;
    if FPolicy <> mpKeepAll then
      AddReport('Нужны одинаковые исходная библиотека, ID, название, язык и формат. Все пути к копиям сохраняются; исходные файлы не удаляются.');
    AddReport('Названия серий не исправляются. Авторы, жанры, все серии и группы дополняются.');
    AddReport('Оценка и прогресс назначения сохраняются; при пустом значении берётся источник.');
    AddReport('Разные отзывы сохраняются вместе с названием источника. Книги и источники не удаляются.');
    AddReport('');
    for Source in FSources do
    begin
      Iterator := Source.Collection.GetPublisherSeriesIndexIterator;
      SourceNew := 0; SourceLinked := 0; SourcePhysical := 0;
      if Assigned(FStageProgress) then FStageProgress('Сопоставление: ' + Source.Name, Count, FTotal);
      while Iterator.Next(Book, Stamp) do
      begin
        if Assigned(Canceled) and Canceled() then raise EAbort.Create('Предпросмотр отменён.');
        Key := PhysicalIdentityAt(Book,ResolvedContainer(Book));
        ID:=0;
        if FHasStableSourceLinks then
        begin
          Inc(FSourceLookupCount);
          Lookup.Reset; Lookup.SetParam(0,SourceKeyAt(Source,Book,ResolvedContainer(Book))); Lookup.Open;
          if not Lookup.Eof then ID:=Lookup.FieldAsInt(0);
          Lookup.Reset;
        end;
        AlreadyLinked := ID <> 0;
        if ID = 0 then Locations.TryGetValue(Key, ID);
        if ID = 0 then FLocations.TryGetValue(Key, ID);
        Identity := '';
        if FPolicy <> mpKeepAll then
        begin
          Identity := BookLibraryIdentity(Book, Source.LibraryNamespace);
          if (ID = 0) and (Identity <> '') then Identities.TryGetValue(Identity, ID);
          if (ID = 0) and (Identity <> '') then FIdentities.TryGetValue(Identity, ID);
        end;
        CompareKey := Key;
        if Identity <> '' then CompareKey := 'identity:' + Identity;
        if ID <> 0 then CompareKey := 'book:' + IntToStr(ID);
        if not Seen.TryGetValue(CompareKey, Values) then
        begin
          if not FTargetUserValues.TryGetValue(ID,Values) then Values:=Default(TMergeUserValues);
        end;
        if (ID <> 0) or Seen.ContainsKey(CompareKey) then
        begin
          Inc(FDuplicates);
          if AlreadyLinked then Inc(SourceLinked) else Inc(SourcePhysical);
          AddReport(Format('Совпадение: %s | %s | %s', [Source.Name, Book.Title, Book.GetBookFileName(ResolvedContainer(Book))]));
          if ((Book.Rate <> 0) and (Values.Rate <> 0) and (Book.Rate <> Values.Rate)) or
            ((Book.Progress <> 0) and (Values.Progress <> 0) and (Book.Progress <> Values.Progress)) then
          begin
            Inc(FConflicts);
            AddReport(Format('  Сохраняемая оценка %d / источник %d; прогресс: %d / %d.',
              [Values.Rate, Book.Rate, Values.Progress, Book.Progress]));
          end;
        end
        else begin Inc(FNewBooks); Inc(SourceNew); ID := -FNewBooks; CompareKey := 'book:' + IntToStr(ID); end;
        if Values.Rate = 0 then Values.Rate := Book.Rate;
        if Values.Progress = 0 then Values.Progress := Book.Progress;
        Seen.AddOrSetValue(CompareKey, Values);
        Locations.AddOrSetValue(Key, ID);
        if Identity <> '' then Identities.AddOrSetValue(Identity, ID);
        Inc(Count);
        if Assigned(Progress) and ((Count mod 100 = 0) or (Count = FTotal)) then Progress(Count, FTotal);
        if Assigned(FStageProgress) and ((Count mod 1000 = 0) or (Count = FTotal)) then
          FStageProgress('Сопоставление: ' + Source.Name, Count, FTotal);
      end;
      Summaries.Add(Format('Источник %s: новых записей %d; уже подключено %d; сопоставленных копий %d.',
        [Source.Name, SourceNew, SourceLinked, SourcePhysical]));
      FReportWriter.WriteLine(Summaries[Summaries.Count-1]);
    end;
    for ID := Summaries.Count-1 downto 0 do FReport.Insert(0, Summaries[ID]);
    FReport.Insert(0, Format('Новых книг: %d. Совпадений: %d. Конфликтов пользовательских значений: %d.',
      [FNewBooks, FDuplicates, FConflicts]));
    FReportWriter.WriteLine(FReport[0]); CheckStamps; FReady := True;
  finally Summaries.Free; Lookup.Free; DB.Free;
    Identities.Free; Locations.Free; Seen.Free; FreeAndNil(FReportWriter); end;
end;

function JoinReviews(const Existing, Incoming, SourceName: string): string;
begin
  Result := Existing;
  if (Incoming = '') or (Existing = Incoming) then Exit;
  if Existing = '' then Exit(Incoming);
  if Pos(#13#10 + '[' + SourceName + ']' + #13#10 + Incoming, Existing) = 0 then
    Result := Existing + #13#10#13#10 + '[' + SourceName + ']' + #13#10 + Incoming;
end;

function UnionSeries(const Preferred, Additional: TBookSeries): TBookSeries;
var Item, Existing: TBookSeriesData; Found: Boolean;
begin
  Result := Copy(Preferred);
  for Item in Additional do
  begin
    Found := False;
    for Existing in Result do if SameText(Existing.SeriesTitle, Item.SeriesTitle) then
    begin Found := True; Break; end;
    if not Found then TSeriesHelper.Add(Result, Item.SeriesID, Item.SeriesTitle, Item.SeqNumber, Item.IsPrimary);
  end;
end;

procedure TCollectionMergePlan.Apply(const BackupFolder: string; const Progress: TMergeProgress;
  const Canceled: TMergeCanceled);
var Source: TMergeSource; Iterator: IBookIterator; Book, Existing: TBookRecord;
  ID, I, Count, OriginalID: Integer; Physical, SourceKey, Identity: string; DestinationKey: TBookKey;
  IncomingCopy, UserFields: TBookRecord; KeepExistingFile, Changed, AuthorsChanged, GenresChanged: Boolean;
  Seen: TDictionary<Integer, Boolean>; Remap: TDictionary<string, Integer>;
  Series, Publishers, OldSeries, OldPublishers: TBookSeries; Sequence: TBookSeriesData; Genre: TGenreData;
  UserData, Mapped: TUserData; Group, NewGroup: TBookGroup; GroupBook: TGroupBook;
  SavedHide, SavedLocal, TargetCommitted, SystemStarted: Boolean; TargetFile: string; Manifest: TStringList;
  AuthorCache: TDictionary<Integer, TAuthorData>;
  GenreCache: TDictionary<string, TGenreData>; Author: TAuthorData;
  ImportCache: TImportCache;
  PhaseStarted: Int64; HasNext: Boolean;
  BookPresence: ISystemBookPresence; StoredBooks: TDictionary<Integer,Boolean>; StoredID: Integer;
  CachedBooks: TDictionary<Integer,TBookRecord>;
  CachedSeries: TDictionary<Integer,TBookSeries>;
  MergeUpdater: IBookMergeMetadataUpdater; DeltaUpdater: IBookMergeMetadataDeltaUpdater;
  OriginalCopyRecorder: IBookMergeOriginalCopyRecorder;
  SourceSeriesProvider: IBookSeriesStreamProvider; SourceSeriesStream: IBookSeriesReadStream;
  procedure PrepareReadSnapshot;
  {$IFDEF WIN64}
  var Memory: TMemoryStatusEx; Budget, Used, EntryBytes: UInt64;
    Snapshot: IBookIterator; Item: TBookRecord; Total: Integer;
    SeriesProvider: IBookSeriesStreamProvider; SeriesStream: IBookSeriesReadStream; ItemSeries: TBookSeries;
  {$ENDIF}
  begin
    {$IFDEF WIN64}
    FillChar(Memory,SizeOf(Memory),0); Memory.dwLength:=SizeOf(Memory);
    if not GlobalMemoryStatusEx(Memory) or (Memory.ullAvailPhys<UInt64(4)*1024*1024*1024) then Exit;
    // Bounded temporary acceleration for this merge only. A 32-bit process and
    // machines with little free RAM retain ordinary on-demand reads.
    Budget:=Min(UInt64(2)*1024*1024*1024,Memory.ullAvailPhys div 6);
    Snapshot:=AllBooks(FTarget,True); Total:=Snapshot.RecordCount; Used:=0;
    CachedBooks:=TDictionary<Integer,TBookRecord>.Create;
    if Supports(FTarget,IBookSeriesStreamProvider,SeriesProvider) then
    begin SeriesStream:=SeriesProvider.OpenBookSeriesReadStream; CachedSeries:=TDictionary<Integer,TBookSeries>.Create; end;
    try
      while Snapshot.Next(Item) do
      begin
        if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
        // Conservative accounting includes dictionary slots, managed-string
        // headers and relation arrays; check available RAM while filling it.
        EntryBytes:=SizeOf(TBookRecord)+512+UInt64(2)*(Length(Item.Title)+Length(Item.Series)+
          Length(Item.FileName)+Length(Item.Folder)+Length(Item.FileExt)+Length(Item.LibID)+
          Length(Item.KeyWords)+Length(Item.Review)+Length(Item.Annotation)+Length(Item.Translators)+
          Length(Item.Publisher)+Length(Item.City)+Length(Item.ISBN))+
          UInt64(Length(Item.Authors))*160+UInt64(Length(Item.Genres))*160+
          UInt64(Length(Item.PublisherSeries))*128;
        ItemSeries:=nil;
        if Assigned(SeriesStream) then
        begin
          ItemSeries:=SeriesStream.ReadBook(Item.BookKey.BookID); Inc(EntryBytes,96+UInt64(Length(ItemSeries))*160);
          for var Sequence in ItemSeries do Inc(EntryBytes,UInt64(Length(Sequence.SeriesTitle))*2);
        end;
        if EntryBytes>Budget-Used then Break;
        Item.NodeType:=ntBookInfo;
        CachedBooks.AddOrSetValue(Item.BookKey.BookID,Item);
        if Assigned(CachedSeries) then CachedSeries.AddOrSetValue(Item.BookKey.BookID,ItemSeries);
        Inc(Used,EntryBytes);
        FReadCacheBooks:=CachedBooks.Count;
        if CachedBooks.Count mod 10000=0 then
        begin
          if Assigned(FStageProgress) then FStageProgress('Подготовка карточек целевой коллекции',CachedBooks.Count,Total);
          if not GlobalMemoryStatusEx(Memory) or (Memory.ullAvailPhys<UInt64(2)*1024*1024*1024) then Break;
        end;
      end;
    except
      on E: EOutOfMemory do begin FreeAndNil(CachedBooks); FreeAndNil(CachedSeries); FReadCacheBooks:=0; end;
    end;
    SeriesStream:=nil; Snapshot:=nil;
    {$ENDIF}
  end;
  procedure ReadExisting(BookID: Integer; out RecordValue: TBookRecord);
  begin
    if Assigned(CachedBooks) and CachedBooks.TryGetValue(BookID,RecordValue) then Inc(FReadCacheHits)
    else FTarget.GetBookRecord(CreateBookKey(BookID,FTarget.CollectionID),RecordValue,True);
  end;
  function ReadExistingSeries(BookID: Integer): TBookSeries;
  begin
    if Assigned(CachedSeries) and CachedSeries.TryGetValue(BookID,Result) then Exit;
    Result:=FTarget.GetBookSeries(CreateBookKey(BookID,FTarget.CollectionID));
  end;
  function HasAuthors(const Current, Incoming: TBookAuthors): Boolean;
  var Item, Present: TAuthorData; Found: Boolean;
  begin
    for Item in Incoming do
    begin
      Found := False;
      for Present in Current do if Present.AuthorID = Item.AuthorID then
      begin Found := True; Break; end;
      if not Found then Exit(False);
    end;
    Result := True;
  end;
  function HasGenres(const Current, Incoming: TBookGenres): Boolean;
  var Item, Present: TGenreData; Found: Boolean;
  begin
    for Item in Incoming do
    begin
      Found := False;
      for Present in Current do if Present.GenreCode = Item.GenreCode then
      begin Found := True; Break; end;
      if not Found then Exit(False);
    end;
    Result := True;
  end;
  function SameMetadata(const A, B: TBookRecord): Boolean;
  begin
    Result := (A.Title = B.Title) and (A.Folder = B.Folder) and
      (A.FileName = B.FileName) and (A.FileExt = B.FileExt) and
      (A.InsideNo = B.InsideNo) and (A.Series = B.Series) and
      (A.SeqNumber = B.SeqNumber) and (A.Size = B.Size) and
      (A.LibID = B.LibID) and
      ((bpIsDeleted in A.BookProps) = (bpIsDeleted in B.BookProps)) and
      ((bpIsLocal in A.BookProps) = (bpIsLocal in B.BookProps)) and
      (A.Date = B.Date) and (A.Lang = B.Lang) and (A.LibRate = B.LibRate) and
      (A.KeyWords = B.KeyWords) and (A.Rate = B.Rate) and
      (A.Progress = B.Progress) and (A.Review = B.Review) and
      (A.Annotation = B.Annotation) and (A.Translators = B.Translators) and
      (A.Publisher = B.Publisher) and (A.City = B.City) and
      (A.PubYear = B.PubYear) and (A.ISBN = B.ISBN);
  end;
  function SameSeries(const A, B: TBookSeries): Boolean;
  var J: Integer;
  begin
    if Length(A) <> Length(B) then Exit(False);
    for J := 0 to High(A) do
      if not SameText(A[J].SeriesTitle, B[J].SeriesTitle) or
        (A[J].SeqNumber <> B[J].SeqNumber) then Exit(False);
    Result := True;
  end;
  function MissingSeries(const Incoming, Current: TBookSeries): TBookSeries;
  var Item, Present: TBookSeriesData; Found: Boolean;
  begin
    Result := nil;
    for Item in Incoming do
    begin
      Found := False;
      for Present in Current do if SameText(Item.SeriesTitle, Present.SeriesTitle) then
      begin Found := True; Break; end;
      if not Found then TSeriesHelper.Add(Result, Item.SeriesID, Item.SeriesTitle,
        Item.SeqNumber, Item.IsPrimary);
    end;
  end;
  procedure Backup(const FileName, BackupName, Description: string);
  var DB: TSQLiteDatabase; Started: Int64;
  begin
    Started := SQLiteProfileClock;
    if Assigned(FStageProgress) then FStageProgress(Description, 0, 0);
    DB := TSQLiteDatabase.CreateReadOnly(FileName);
    try
      DB.BackupTo(TPath.Combine(BackupFolder, BackupName),
        procedure(Current, Total: Integer)
        begin
          if Assigned(Canceled) and Canceled() then raise EAbort.Create('Резервное копирование отменено.');
          if Assigned(FStageProgress) then FStageProgress(Description, Current, Total);
        end);
    finally
      DB.Free; RecordSQLiteProfile('merge','phase','backups',Started);
    end;
  end;
begin
  if not FReady then raise Exception.Create('Сначала выполните предпросмотр объединения.');
  CheckStamps; CheckResolvedContainers;
  if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
  if DirectoryExists(BackupFolder) then raise Exception.Create('Для резервной копии требуется новая папка.');
  ForceDirectories(BackupFolder);
  TargetFile := Settings.ExpandCollectionFileName(VarToStr(FTarget.GetProperty(PROP_DATAFILE)));
  Backup(TargetFile, 'destination.hlc2', 'Резервная копия текущей коллекции');
  Backup(Settings.SystemFileName[sfSystemDB], 'system.hlc2', 'Резервная копия групп и настроек');
  // Sources are read-only inputs to this operation. Copying every source DB
  // again wastes gigabytes and cannot help roll back the two stores we change.
  TFile.Copy(FFullReportFile,TPath.Combine(BackupFolder, 'preview.txt'),False);
  Manifest := TStringList.Create;
  try
    Manifest.Add('Назначение: ' + TargetFile);
    Manifest.Add('Группы и настройки: ' + Settings.SystemFileName[sfSystemDB]);
    Manifest.Add('Папка книг: ' + Settings.ExpandCollectionRoot(VarToStr(FTarget.GetProperty(PROP_ROOTFOLDER))));
    for I := 0 to High(FSources) do Manifest.Add(Format('Источник %d (не изменяется): %s | %s',
      [I+1, FSources[I].Name, FSources[I].DatabaseFile]));
    Manifest.Add('Исходные книги не изменяются. Копии SQLite включают данные из WAL.');
    Manifest.SaveToFile(TPath.Combine(BackupFolder, 'restore-paths.txt'), TEncoding.UTF8);
  finally Manifest.Free; end;
  CheckStamps; CheckResolvedContainers; FResolvedContainers.Clear;
  TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Подготовлено', TEncoding.UTF8);
  // The validated preview already contains this index. CheckStamps above keeps
  // it valid until the write transaction; rebuilding it was a second full scan.
  Seen := TDictionary<Integer, Boolean>.Create; Remap := TDictionary<string, Integer>.Create;
  AuthorCache := TDictionary<Integer, TAuthorData>.Create;
  GenreCache := TDictionary<string, TGenreData>.Create;
  ImportCache := TImportCache.Create;
  Mapped := TUserData.Create; StoredBooks := nil; CachedBooks := nil; CachedSeries:=nil;
  FReadCacheHits:=0; FReadCacheBooks:=0; Count := 0; TargetCommitted := False; SystemStarted := False;
  Supports(FTarget,IBookMergeOriginalCopyRecorder,OriginalCopyRecorder);
  SavedHide := FTarget.GetHideDeleted; SavedLocal := FTarget.GetShowLocalOnly;
  FTarget.SetHideDeleted(False); FTarget.SetShowLocalOnly(False);
  try
    FTarget.BeginBulkOperation;
    try
      FSystem.BeginDataUpdate; SystemStarted := True;
      PhaseStarted:=SQLiteProfileClock; PrepareReadSnapshot;
      RecordSQLiteProfile('merge','phase','prepare-target-read-snapshot',PhaseStarted);
      if Supports(FSystem, ISystemBookPresence, BookPresence) then
      begin
        StoredBooks := TDictionary<Integer,Boolean>.Create;
        for StoredID in BookPresence.StoredBookIDs(FTarget.CollectionID) do
          StoredBooks.AddOrSetValue(StoredID, True);
      end;
      for Source in FSources do
      begin
        AuthorCache.Clear;
        Iterator := AllBooks(Source.Collection, True);
        SourceSeriesStream:=nil;
        if Supports(Source.Collection,IBookSeriesStreamProvider,SourceSeriesProvider) then
          SourceSeriesStream:=SourceSeriesProvider.OpenBookSeriesReadStream;
        while True do
        begin
          PhaseStarted := SQLiteProfileClock;
          HasNext := Iterator.Next(Book);
          RecordSQLiteProfile('merge','phase','read-source',PhaseStarted);
          if not HasNext then Break;
          if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
          PhaseStarted := SQLiteProfileClock;
          OriginalID := Book.BookKey.BookID;
          Physical := PhysicalIdentityAt(Book,ResolvedContainer(Book)); SourceKey := SourceKeyAt(Source,Book,ResolvedContainer(Book));
          ID:=0;
          if FHasStableSourceLinks then
          begin Inc(FSourceLookupCount); ID:=FTarget.GetCatalogBookID(SourceKey); end;
          if ID = 0 then FLocations.TryGetValue(Physical, ID);
          Identity := '';
          if FPolicy <> mpKeepAll then
          begin
            Identity := BookLibraryIdentity(Book, Source.LibraryNamespace);
            if (ID = 0) and (Identity <> '') then FIdentities.TryGetValue(Identity, ID);
          end;
          RecordSQLiteProfile('merge','phase','identify-and-lookup',PhaseStarted);
          IncomingCopy := Book;
          KeepExistingFile := False;
          Changed := ID = 0;
          OldPublishers := nil;
          PhaseStarted := SQLiteProfileClock;
          if Assigned(SourceSeriesStream) then Series:=SourceSeriesStream.ReadBook(Book.BookKey.BookID)
          else Series := Source.Collection.GetBookSeries(Book.BookKey);
          Publishers := Book.PublisherSeries;
          RecordSQLiteProfile('merge','phase','read-source-series',PhaseStarted);
          PhaseStarted := SQLiteProfileClock;
          Book.Folder := ResolvedContainer(Book);
          if not (Book.GetBookFormat(Book.Folder) in [bfFb2Archive, bfRawArchive]) then
            Book.Folder := IncludeTrailingPathDelimiter(Book.Folder);
          Book.CollectionRoot := FTarget.CollectionRoot;
          for I := 0 to High(Book.Genres) do
          begin
            Genre := Book.Genres[I];
            if not GenreCache.TryGetValue(Genre.FB2GenreCode, Book.Genres[I]) then
            begin
              Book.Genres[I] := FTarget.EnsureGenre(Genre.FB2GenreCode, Genre.GenreAlias, Book.RootGenre.GenreAlias);
              GenreCache.Add(Genre.FB2GenreCode, Book.Genres[I]);
            end;
          end;
          for I := 0 to High(Book.Authors) do
          begin
            Author := Book.Authors[I];
            if not AuthorCache.TryGetValue(Author.AuthorID, Book.Authors[I]) then
            begin
              Book.Authors[I] := FTarget.EnsureAuthor(Author);
              AuthorCache.Add(Author.AuthorID, Book.Authors[I]);
            end;
          end;
          RecordSQLiteProfile('merge','phase','resolve-authors-and-genres',PhaseStarted);
          if ID = 0 then
          begin
            PhaseStarted := SQLiteProfileClock;
            if (Identity <> '') and (Pos(':', Book.LibID) = 0) and
              (SameText(Source.LibraryNamespace, 'flibusta') or SameText(Source.LibraryNamespace, 'librusec')) then
              Book.LibID := LowerCase(Source.LibraryNamespace) + ':' + Book.LibID;
            if Book.LibID <> '' then Book.LibID := 'merged:' + Source.ID + ':' + Book.LibID
            else Book.LibID := 'merged:' + Source.ID + ':file:' + Physical;
            ID := FTarget.InsertBook(Book, False, False, ImportCache);
            if ID = 0 then raise Exception.Create('Не удалось добавить книгу: ' + Book.Title);
            // InsertBook already establishes the primary membership. Compare
            // with its actual graph: title caches and collection implementations
            // may resolve source series IDs differently from the destination.
            if Length(Series) <> 0 then
              Series := MissingSeries(Series, FTarget.GetBookSeries(CreateBookKey(ID, FTarget.CollectionID)));
            RecordSQLiteProfile('merge','phase','insert-new-book',PhaseStarted);
          end
          else
          begin
            PhaseStarted := SQLiteProfileClock;
            ReadExisting(ID,Existing);
            RecordSQLiteProfile('merge','phase','read-existing-book',PhaseStarted);
            PhaseStarted := SQLiteProfileClock;
            if (FPolicy <> mpKeepAll) and not Seen.ContainsKey(ID) then
            begin
              if Assigned(OriginalCopyRecorder) then
                OriginalCopyRecorder.CaptureOriginalCopyIfMissing('base:' +
                  PhysicalIdentityAt(Existing,ResolvedContainer(Existing)),Existing.CollectionName,Existing)
              else if Length(FTarget.GetCatalogBookCopies(Existing.BookKey))=0 then
                FTarget.SetCatalogBookCopy('base:' + PhysicalIdentityAt(Existing,ResolvedContainer(Existing)),Existing.CollectionName,Existing);
            end;
            KeepExistingFile := ((FPolicy = mpSourcePriority) and Seen.ContainsKey(ID)) or
              ((FPolicy = mpSmallestFile) and (Existing.Size > 0) and
                ((Book.Size <= 0) or (Book.Size >= Existing.Size)));
            if KeepExistingFile then
            begin
              Book.Folder := Existing.Folder; Book.FileName := Existing.FileName;
              Book.FileExt := Existing.FileExt; Book.InsideNo := Existing.InsideNo;
              Book.Size := Existing.Size; Book.CollectionRoot := Existing.CollectionRoot;
              Book.BookProps := Existing.BookProps;
            end;
            Book.LibID := Existing.LibID; Book.BookKey := Existing.BookKey;
            if Existing.Rate <> 0 then Book.Rate := Existing.Rate;
            if Existing.Progress <> 0 then Book.Progress := Existing.Progress;
            Book.Review := JoinReviews(Existing.Review, Book.Review, Source.Name);
            if Existing.Annotation <> '' then Book.Annotation := Existing.Annotation;
            if Book.Translators = '' then Book.Translators := Existing.Translators;
            if Book.Publisher = '' then Book.Publisher := Existing.Publisher;
            if Book.City = '' then Book.City := Existing.City;
            if Book.PubYear = 0 then Book.PubYear := Existing.PubYear;
            if Book.ISBN = '' then Book.ISBN := Existing.ISBN;
            OldSeries := ReadExistingSeries(ID);
            OldPublishers := Existing.PublisherSeries;
            AuthorsChanged := not HasAuthors(Existing.Authors, Book.Authors);
            GenresChanged := not HasGenres(Existing.Genres, Book.Genres);
            if AuthorsChanged then FTarget.SetBookAuthors(ID, Book.Authors, False);
            if GenresChanged then FTarget.SetBookGenres(ID, Book.Genres, False);
            Changed := AuthorsChanged or GenresChanged;
            if not Seen.ContainsKey(ID) or ((FPolicy = mpSmallestFile) and not KeepExistingFile) then
            begin
              // UpdateBook replaces the author-series primary mirror; restore all relationships afterwards.
              Series := UnionSeries(Series, OldSeries);
              Publishers := UnionSeries(Publishers, OldPublishers);
              // Keep an equivalent relative path: changing only its spelling
              // rewrites hundreds of thousands of otherwise unchanged books.
              if Physical = PhysicalIdentityAt(Existing,ResolvedContainer(Existing)) then
              begin Book.Folder := Existing.Folder; Book.CollectionRoot := Existing.CollectionRoot; end;
              if Changed then
              begin
                DestinationKey := Existing.BookKey;
                FTarget.GetBookRecord(DestinationKey, Existing, True);
              end;
              Book.Authors := Existing.Authors; Book.Genres := Existing.Genres;
              if not SameMetadata(Book, Existing) then
              begin
                Book.PublisherSeriesKnown := False;
                if Supports(FTarget,IBookMergeMetadataDeltaUpdater,DeltaUpdater) then
                begin
                  DeltaUpdater.UpdateBookMetadataDelta(Existing,Book,False);
                  // Scalar deltas retain the existing series graph. A primary
                  // change can add or promote a membership, so use the result
                  // of that update rather than the pre-update snapshot.
                  if Book.Series = Existing.Series then Series := MissingSeries(Series, OldSeries)
                  else Series := MissingSeries(Series, FTarget.GetBookSeries(Existing.BookKey));
                end
                else
                begin
                  if Supports(FTarget,IBookMergeMetadataUpdater,MergeUpdater) then MergeUpdater.UpdateBookPreservingSeries(Book)
                  else FTarget.UpdateBook(Book);
                  Series := MissingSeries(Series, FTarget.GetBookSeries(Existing.BookKey));
                end;
                Changed := True;
              end
              else Series := MissingSeries(Series, OldSeries);
            end
            else
            begin
              if (Book.Rate<>Existing.Rate) or (Book.Progress<>Existing.Progress) or (Book.Review<>Existing.Review) then
              begin
                if Supports(FTarget,IBookMergeMetadataDeltaUpdater,DeltaUpdater) then
                begin
                  UserFields:=Existing; UserFields.PublisherSeriesKnown:=False;
                  UserFields.Rate:=Book.Rate; UserFields.Progress:=Book.Progress; UserFields.Review:=Book.Review;
                  DeltaUpdater.UpdateBookMetadataDelta(Existing,UserFields,False);
                end
                else
                begin
                  if Book.Rate<>Existing.Rate then FTarget.SetRate(Book.BookKey,Book.Rate);
                  if Book.Progress<>Existing.Progress then FTarget.SetProgress(Book.BookKey,Book.Progress);
                  if Book.Review<>Existing.Review then FTarget.SetReview(Book.BookKey,Book.Review);
                end;
                Changed:=True;
              end;
              Series := MissingSeries(Series, OldSeries);
              Publishers := UnionSeries(OldPublishers, Publishers);
            end;
            RecordSQLiteProfile('merge','phase','update-existing-book',PhaseStarted);
          end;
          PhaseStarted := SQLiteProfileClock;
          DestinationKey := CreateBookKey(ID, FTarget.CollectionID);
          if FPolicy <> mpKeepAll then
          begin
            IncomingCopy.BookKey := DestinationKey;
            FTarget.SetCatalogBookCopy(SourceKey, Source.Name, IncomingCopy);
            if not KeepExistingFile then FTarget.SetCatalogBookPreferredSource(DestinationKey, Source.Name);
            if Identity <> '' then FIdentities.AddOrSetValue(Identity, ID);
          end;
          for Sequence in Series do FTarget.AddBookSeries(ID, Sequence.SeriesTitle, Sequence.SeqNumber, ImportCache);
          if Length(Series) <> 0 then Changed := True;
          if not SameSeries(Publishers, OldPublishers) then
          begin FTarget.SetBookPublisherSeries(DestinationKey, Publishers); Changed := True; end;
          RecordSQLiteProfile('merge','phase','copies-and-series',PhaseStarted);
          PhaseStarted := SQLiteProfileClock;
          if Changed and ((StoredBooks = nil) or StoredBooks.ContainsKey(ID)) then
          begin
            FTarget.GetBookRecord(DestinationKey, Existing, True);
            FSystem.UpdateBook(Existing);
          end;
          // Any mutation invalidates this record. Later sources see fresh data;
          // arrays in immutable snapshots are never edited in place.
          if Changed and Assigned(CachedBooks) then CachedBooks.Remove(ID);
          if Changed and Assigned(CachedSeries) then CachedSeries.Remove(ID);
          RecordSQLiteProfile('merge','phase','system-card-update',PhaseStarted);
          PhaseStarted := SQLiteProfileClock;
          FTarget.SetCatalogBookID(SourceKey, ID); FLocations.AddOrSetValue(Physical, ID); Seen.AddOrSetValue(ID, True);
          Remap.AddOrSetValue(Source.ID + ':' + IntToStr(OriginalID), ID);
          Inc(Count); if Assigned(Progress) and (Count mod 100 = 0) then Progress(Count, FTotal);
          RecordSQLiteProfile('merge','phase','source-map-and-progress',PhaseStarted);
        end;
      end;
      PhaseStarted := SQLiteProfileClock;
      FTarget.AfterBatchUpdate;
      RecordSQLiteProfile('merge','phase','finalize-search-indexes',PhaseStarted);
      PhaseStarted := SQLiteProfileClock;
    // Group cards use the same system connection and roll back with this operation.
    for Source in FSources do
    begin
      UserData := TUserData.Create;
      try
        Source.Collection.ExportUserData(UserData);
        for Group in UserData.Groups do
        begin
          NewGroup := Mapped.Groups.AddGroup(Group.GroupID, Group.GroupName);
          for GroupBook in Group do
            if Remap.TryGetValue(Source.ID + ':' + IntToStr(GroupBook.BookID), ID) then
            begin
              FTarget.GetBookRecord(CreateBookKey(ID, FTarget.CollectionID), Existing, False);
              NewGroup.AddBook(ID, Existing.LibID);
            end;
        end;
      finally UserData.Free; end;
    end;
    Mapped.Save(TPath.Combine(BackupFolder, 'merged-groups.cxml2'));
    // This operation already owns the catalog/system transactions. Mapped
    // contains only groups with resolved target BookIDs; the legacy file
    // importer would try to start a second cross-database transaction here.
    FSystem.ImportUserData(Mapped);
    for Group in Mapped.Groups do
      for GroupBook in Group do
        FTarget.AddBookToGroup(CreateBookKey(GroupBook.BookID,FTarget.CollectionID),Group.GroupID);
      if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
      TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Сохранение: при аварийном завершении проверьте обе резервные копии.', TEncoding.UTF8);
      RecordSQLiteProfile('merge','phase','merge-groups',PhaseStarted);
      PhaseStarted := SQLiteProfileClock;
      FTarget.EndBulkOperation(True); TargetCommitted := True;
      FSystem.EndDataUpdate(True); SystemStarted := False;
      RecordSQLiteProfile('merge','phase','commit',PhaseStarted);
      FReady := False;
    except
      if FTarget.InBulkOperation then FTarget.EndBulkOperation(False);
      if SystemStarted then FSystem.EndDataUpdate(False);
      if TargetCommitted then FTarget.RestoreCollectionBackup(TPath.Combine(BackupFolder, 'destination.hlc2'));
      TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Отменено: изменения отменены.', TEncoding.UTF8);
      FReady := False;
      raise;
    end;
    TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Завершено', TEncoding.UTF8);
    if Assigned(Progress) then Progress(FTotal, FTotal);
  finally
    FTarget.SetHideDeleted(SavedHide); FTarget.SetShowLocalOnly(SavedLocal);
    SourceSeriesStream:=nil; SourceSeriesProvider:=nil;
    CachedSeries.Free; CachedBooks.Free; StoredBooks.Free; ImportCache.Free; GenreCache.Free; AuthorCache.Free;
    Mapped.Free; Remap.Free; Seen.Free;
  end;
end;

end.
