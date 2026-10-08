unit unit_CollectionMerge;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections,
  unit_Interfaces, unit_Globals;

type
  TMergeSource = record
    ID, Name, DatabaseFile, Root: string;
    Collection: IBookCollection;
  end;
  TMergeSources = TArray<TMergeSource>;
  TMergeProgress = reference to procedure(Current, Total: Integer);
  TMergeStageProgress = reference to procedure(const Stage: string; Current, Total: Integer);
  TMergeCanceled = reference to function: Boolean;

  TCollectionMergePlan = class
  private
    FTarget: IBookCollection;
    FSystem: ISystemData;
    FSources: TMergeSources;
    FLocations: TDictionary<string, Integer>;
    FReport: TStringList;
    FStamps: TDictionary<string, string>;
    FReportWriter: TStreamWriter;
    FFullReportFile: string;
    FNewBooks, FDuplicates, FTotal, FConflicts: Integer;
    FReady: Boolean;
    FStageProgress: TMergeStageProgress;
    procedure LoadTarget(const Canceled: TMergeCanceled = nil);
    procedure AddReport(const Text: string);
    procedure CaptureStamps;
    procedure CheckStamps;
  public
    constructor Create(const Target: IBookCollection; const Sources: TMergeSources;
      const SystemData: ISystemData = nil);
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
    property StageProgress: TMergeStageProgress read FStageProgress write FStageProgress;
  end;

function BookPhysicalIdentity(const Book: TBookRecord): string;
function MergeSourceKey(const Source: TMergeSource; const Book: TBookRecord): string;
procedure BackupCollectionFile(const SourceFile, BackupFile: string);

implementation

uses System.IOUtils, System.Hash, System.Variants, System.Math, System.DateUtils,
  unit_Consts, unit_Settings, unit_UserData, SQLiteWrap, dm_user;

function BookPhysicalIdentity(const Book: TBookRecord): string;
var Container, Name: string;
begin
  Container := TPath.GetFullPath(Book.GetBookContainer);
  if Book.GetBookFormat in [bfFb2Archive, bfRawArchive] then
  begin
    Name := Book.FileName;
    if not SameText(ExtractFileExt(Name), Book.FileExt) then Name := Name + Book.FileExt;
    // An archive index may change between INPX revisions; the member name is stable.
    Result := LowerCase(Container + #1 + StringReplace(Name, '/', '\', [rfReplaceAll]));
  end
  else Result := LowerCase(TPath.GetFullPath(Book.GetBookFileName));
  Result := THashSHA2.GetHashString(Result);
end;

function MergeSourceKey(const Source: TMergeSource; const Book: TBookRecord): string;
begin
  if Book.LibID <> '' then Result := Source.ID + ':' + Book.LibID
  else Result := Source.ID + ':file:' + BookPhysicalIdentity(Book);
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
  const SystemData: ISystemData);
var Source: TMergeSource; IDs: TDictionary<string, Boolean>; TargetFile: string;
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
  if not Assigned(FSystem) then FSystem := SystemDB;
  FLocations := TDictionary<string, Integer>.Create; FReport := TStringList.Create;
  FStamps := TDictionary<string, string>.Create;
end;

destructor TCollectionMergePlan.Destroy;
begin
  FReportWriter.Free;
  try
    if (FFullReportFile <> '') and FileExists(FFullReportFile) then TFile.Delete(FFullReportFile);
  except
    // A locked temporary report must not prevent release of catalog connections.
  end;
  FStamps.Free; FReport.Free; FLocations.Free; inherited;
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
var Iterator: IPublisherSeriesIndexIterator; Book: TBookRecord; Stamp: string;
  Count, Total: Integer;
begin
  FLocations.Clear; Iterator := FTarget.GetPublisherSeriesIndexIterator;
  Count := 0; Total := Iterator.RecordCount;
  if Assigned(FStageProgress) then FStageProgress('Указатель файлов текущей коллекции', 0, Total);
  while Iterator.Next(Book, Stamp) do
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Операция отменена.');
    FLocations.AddOrSetValue(BookPhysicalIdentity(Book), Book.BookKey.BookID);
    Inc(Count);
    if Assigned(FStageProgress) and ((Count mod 1000 = 0) or (Count = Total)) then
      FStageProgress('Указатель файлов текущей коллекции', Count, Total);
  end;
end;

procedure TCollectionMergePlan.Preview(const Progress: TMergeProgress; const Canceled: TMergeCanceled);
type TUserValues = record Rate, Progress: Integer; end;
var Source: TMergeSource; Iterator: IPublisherSeriesIndexIterator; Book: TBookRecord;
  Key, CompareKey: string; ID, Count, SourceNew, SourceLinked, SourcePhysical: Integer;
  AlreadyLinked: Boolean; Seen: TDictionary<string, TUserValues>;
  Values: TUserValues; ReportID: TGUID; Stamp, TargetFile: string;
  DB: TSQLiteDatabase; Lookup, UserValues: TSQLiteQuery; Summaries: TStringList;
begin
  FReady := False; FNewBooks := 0; FDuplicates := 0; FConflicts := 0; FTotal := 0; Count := 0;
  FReport.Clear; CaptureStamps; LoadTarget(Canceled);
  if (FFullReportFile <> '') and FileExists(FFullReportFile) then TFile.Delete(FFullReportFile);
  CreateGUID(ReportID); ForceDirectories(Settings.TempPath);
  FFullReportFile := TPath.Combine(Settings.TempPath, 'merge-preview-' + GUIDToString(ReportID) + '.txt');
  FReportWriter := TStreamWriter.Create(FFullReportFile,False,TEncoding.UTF8,65536);
  Seen := TDictionary<string, TUserValues>.Create;
  DB := nil; Lookup := nil; UserValues := nil; Summaries := TStringList.Create;
  try
    TargetFile := Settings.ExpandCollectionFileName(VarToStr(FTarget.GetProperty(PROP_DATAFILE)));
    DB := TSQLiteDatabase.CreateReadOnly(TargetFile);
    Lookup := DB.NewQuery('SELECT l.BookID FROM CatalogSourceBooks l JOIN Books b ON b.BookID=l.BookID WHERE l.SourceKey=?');
    UserValues := DB.NewQuery('SELECT Rate,Progress FROM Books WHERE BookID=?');
    for Source in FSources do
    begin Iterator := Source.Collection.GetPublisherSeriesIndexIterator; Inc(FTotal, Iterator.RecordCount); end;
    AddReport('Приоритет: источники сверху вниз. Совпадение — один файл или член одного архива.');
    AddReport('Одинаковые числовые LIBID разных источников не объединяются.');
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
        Key := BookPhysicalIdentity(Book);
        Lookup.Reset; Lookup.SetParam(0, MergeSourceKey(Source, Book)); Lookup.Open;
        ID := 0; if not Lookup.Eof then ID := Lookup.FieldAsInt(0);
        Lookup.Reset; AlreadyLinked := ID <> 0;
        if ID = 0 then FLocations.TryGetValue(Key, ID);
        CompareKey := Key;
        if ID <> 0 then CompareKey := 'book:' + IntToStr(ID);
        if not Seen.TryGetValue(CompareKey, Values) then
        begin
          Values.Rate := 0; Values.Progress := 0;
          if ID <> 0 then
          begin
            UserValues.Reset; UserValues.SetParam(0, ID); UserValues.Open;
            if not UserValues.Eof then
            begin Values.Rate := UserValues.FieldAsInt(0); Values.Progress := UserValues.FieldAsInt(1); end;
            UserValues.Reset;
          end;
        end;
        if (ID <> 0) or Seen.ContainsKey(CompareKey) then
        begin
          Inc(FDuplicates);
          if AlreadyLinked then Inc(SourceLinked) else Inc(SourcePhysical);
          AddReport(Format('Совпадение: %s | %s | %s', [Source.Name, Book.Title, Book.GetBookFileName]));
          if ((Book.Rate <> 0) and (Values.Rate <> 0) and (Book.Rate <> Values.Rate)) or
            ((Book.Progress <> 0) and (Values.Progress <> 0) and (Book.Progress <> Values.Progress)) then
          begin
            Inc(FConflicts);
            AddReport(Format('  Сохраняемая оценка %d / источник %d; прогресс: %d / %d.',
              [Values.Rate, Book.Rate, Values.Progress, Book.Progress]));
          end;
        end
        else begin Inc(FNewBooks); Inc(SourceNew); end;
        if Values.Rate = 0 then Values.Rate := Book.Rate;
        if Values.Progress = 0 then Values.Progress := Book.Progress;
        Seen.AddOrSetValue(CompareKey, Values); Inc(Count);
        if Assigned(Progress) and ((Count mod 100 = 0) or (Count = FTotal)) then Progress(Count, FTotal);
        if Assigned(FStageProgress) and ((Count mod 1000 = 0) or (Count = FTotal)) then
          FStageProgress('Сопоставление: ' + Source.Name, Count, FTotal);
      end;
      Summaries.Add(Format('Источник %s: новых записей %d; уже подключено %d; одинаковых файлов %d.',
        [Source.Name, SourceNew, SourceLinked, SourcePhysical]));
      FReportWriter.WriteLine(Summaries[Summaries.Count-1]);
    end;
    for ID := Summaries.Count-1 downto 0 do FReport.Insert(0, Summaries[ID]);
    FReport.Insert(0, Format('Новых книг: %d. Совпадений: %d. Конфликтов пользовательских значений: %d.',
      [FNewBooks, FDuplicates, FConflicts]));
    FReportWriter.WriteLine(FReport[0]); CheckStamps; FReady := True;
  finally Summaries.Free; UserValues.Free; Lookup.Free; DB.Free; Seen.Free; FreeAndNil(FReportWriter); end;
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
  ID, I, Count, OriginalID: Integer; Physical, SourceKey: string; DestinationKey: TBookKey;
  Seen: TDictionary<Integer, Boolean>; Remap: TDictionary<string, Integer>;
  Series, Publishers, OldSeries: TBookSeries; Sequence: TBookSeriesData; Genre: TGenreData;
  UserData, Mapped: TUserData; Group, NewGroup: TBookGroup; GroupBook: TGroupBook;
  SavedHide, SavedLocal, TargetCommitted, SystemStarted: Boolean; TargetFile: string; Manifest: TStringList;
  AuthorCache: TDictionary<Integer, TAuthorData>;
  GenreCache: TDictionary<string, TGenreData>; Author: TAuthorData;
  ImportCache: TImportCache;
  procedure Backup(const FileName, BackupName, Description: string);
  var DB: TSQLiteDatabase;
  begin
    if Assigned(FStageProgress) then FStageProgress(Description, 0, 0);
    DB := TSQLiteDatabase.CreateReadOnly(FileName);
    try
      DB.BackupTo(TPath.Combine(BackupFolder, BackupName),
        procedure(Current, Total: Integer)
        begin
          if Assigned(Canceled) and Canceled() then raise EAbort.Create('Резервное копирование отменено.');
          if Assigned(FStageProgress) then FStageProgress(Description, Current, Total);
        end);
    finally DB.Free; end;
  end;
begin
  if not FReady then raise Exception.Create('Сначала выполните предпросмотр объединения.');
  CheckStamps;
  if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
  if DirectoryExists(BackupFolder) then raise Exception.Create('Для резервной копии требуется новая папка.');
  ForceDirectories(BackupFolder);
  TargetFile := Settings.ExpandCollectionFileName(VarToStr(FTarget.GetProperty(PROP_DATAFILE)));
  Backup(TargetFile, 'destination.hlc2', 'Резервная копия текущей коллекции');
  Backup(Settings.SystemFileName[sfSystemDB], 'system.hlc2', 'Резервная копия групп и настроек');
  for I := 0 to High(FSources) do
    Backup(FSources[I].DatabaseFile, Format('source-%d.hlc2', [I+1]), 'Резервная копия: ' + FSources[I].Name);
  TFile.Copy(FFullReportFile,TPath.Combine(BackupFolder, 'preview.txt'),False);
  Manifest := TStringList.Create;
  try
    Manifest.Add('Назначение: ' + TargetFile);
    Manifest.Add('Группы и настройки: ' + Settings.SystemFileName[sfSystemDB]);
    for I := 0 to High(FSources) do Manifest.Add(Format('source-%d.hlc2: %s | %s',
      [I+1, FSources[I].Name, FSources[I].DatabaseFile]));
    Manifest.Add('Исходные книги не изменяются. Копии SQLite включают данные из WAL.');
    Manifest.SaveToFile(TPath.Combine(BackupFolder, 'restore-paths.txt'), TEncoding.UTF8);
  finally Manifest.Free; end;
  CheckStamps;
  TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Подготовлено', TEncoding.UTF8);
  // The validated preview already contains this index. CheckStamps above keeps
  // it valid until the write transaction; rebuilding it was a second full scan.
  Seen := TDictionary<Integer, Boolean>.Create; Remap := TDictionary<string, Integer>.Create;
  AuthorCache := TDictionary<Integer, TAuthorData>.Create;
  GenreCache := TDictionary<string, TGenreData>.Create;
  ImportCache := TImportCache.Create;
  Mapped := TUserData.Create; Count := 0; TargetCommitted := False; SystemStarted := False;
  SavedHide := FTarget.GetHideDeleted; SavedLocal := FTarget.GetShowLocalOnly;
  FTarget.SetHideDeleted(False); FTarget.SetShowLocalOnly(False);
  try
    FTarget.BeginBulkOperation;
    try
      FSystem.BeginDataUpdate; SystemStarted := True;
      for Source in FSources do
      begin
        AuthorCache.Clear;
        Iterator := AllBooks(Source.Collection, True);
        while Iterator.Next(Book) do
        begin
          if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
          OriginalID := Book.BookKey.BookID;
          Physical := BookPhysicalIdentity(Book); SourceKey := MergeSourceKey(Source, Book);
          ID := FTarget.GetCatalogBookID(SourceKey);
          if ID = 0 then FLocations.TryGetValue(Physical, ID);
          Series := Source.Collection.GetBookSeries(Book.BookKey);
          Publishers := Book.PublisherSeries;
          Book.Folder := TPath.GetFullPath(Book.GetBookContainer);
          if not (Book.GetBookFormat in [bfFb2Archive, bfRawArchive]) then
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
          if ID = 0 then
          begin
            Book.LibID := 'merged:' + SourceKey;
            ID := FTarget.InsertBook(Book, False, False, ImportCache);
            if ID = 0 then raise Exception.Create('Не удалось добавить книгу: ' + Book.Title);
          end
          else
          begin
            FTarget.GetBookRecord(CreateBookKey(ID, FTarget.CollectionID), Existing, True);
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
            if not Seen.ContainsKey(ID) then
            begin
              // UpdateBook replaces the author-series primary mirror; restore all relationships afterwards.
              OldSeries := FTarget.GetBookSeries(Existing.BookKey);
              Series := UnionSeries(Series, OldSeries);
              Publishers := UnionSeries(Publishers, FTarget.GetBookPublisherSeries(Existing.BookKey));
              FTarget.SetBookAuthors(ID, Book.Authors, False); FTarget.SetBookGenres(ID, Book.Genres, False);
              DestinationKey := Existing.BookKey;
              FTarget.GetBookRecord(DestinationKey, Existing, True);
              Book.Authors := Existing.Authors; Book.Genres := Existing.Genres;
              Book.PublisherSeriesKnown := False; FTarget.UpdateBook(Book);
            end
            else
            begin
              FTarget.SetBookAuthors(ID, Book.Authors, False); FTarget.SetBookGenres(ID, Book.Genres, False);
              FTarget.SetRate(Book.BookKey, Book.Rate); FTarget.SetProgress(Book.BookKey, Book.Progress);
              FTarget.SetReview(Book.BookKey, Book.Review);
              Series := UnionSeries(FTarget.GetBookSeries(Book.BookKey), Series);
              Publishers := UnionSeries(FTarget.GetBookPublisherSeries(Book.BookKey), Publishers);
            end;
          end;
          DestinationKey := CreateBookKey(ID, FTarget.CollectionID);
          for Sequence in Series do FTarget.AddBookSeries(ID, Sequence.SeriesTitle, Sequence.SeqNumber, ImportCache);
          FTarget.SetBookPublisherSeries(DestinationKey, Publishers);
          FTarget.GetBookRecord(DestinationKey, Existing, True);
          FSystem.UpdateBook(Existing);
          FTarget.SetCatalogBookID(SourceKey, ID); FLocations.AddOrSetValue(Physical, ID); Seen.AddOrSetValue(ID, True);
          Remap.AddOrSetValue(Source.ID + ':' + IntToStr(OriginalID), ID);
          Inc(Count); if Assigned(Progress) and (Count mod 100 = 0) then Progress(Count, FTotal);
        end;
      end;
      FTarget.AfterBatchUpdate;
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
    FTarget.ImportUserData(Mapped, nil);
      if Assigned(Canceled) and Canceled() then raise EAbort.Create('Объединение отменено.');
      TFile.WriteAllText(TPath.Combine(BackupFolder, 'status.txt'), 'Сохранение: при аварийном завершении проверьте обе резервные копии.', TEncoding.UTF8);
      FTarget.EndBulkOperation(True); TargetCommitted := True;
      FSystem.EndDataUpdate(True); SystemStarted := False;
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
    ImportCache.Free; GenreCache.Free; AuthorCache.Free;
    Mapped.Free; Remap.Free; Seen.Free;
  end;
end;

end.
