program MetabibImportTest;
{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Utils\MHLMcpServer\MHLMcpServer_SQL.res'}
uses
  NativeRegressionGuard,
  System.SysUtils, System.Classes, System.IOUtils, System.Variants,
  System.Zip, System.NetEncoding, System.RegularExpressions, Vcl.Forms,
  dm_user, unit_Consts, unit_Globals, unit_Interfaces, unit_ImportMetabibThread,
  unit_ImportInpxThread, unit_libupdateThread, unit_ExportToDeviceThread, SQLiteWrap;
procedure RunImport(ID: Integer; const Filename: string);
var
  Thread: TImportMetabibThread;
begin
  Thread := TImportMetabibThread.Create(ID, Filename, gtFb2);
  try
    Thread.Start;
    Thread.WaitFor;
    if Assigned(Thread.FatalException) then
      raise Exception.Create(Exception(Thread.FatalException).Message);
  finally
    Thread.Free;
  end;
end;
procedure ExpectImportFailure(ID: Integer; const Filename, ExpectedMessage: string);
var
  Failed: Boolean;
begin
  Failed := False;
  try
    RunImport(ID, Filename);
  except
    on E: Exception do
    begin
      Failed := True;
      if Pos(ExpectedMessage, E.Message) = 0 then
        raise Exception.Create('Unexpected import failure: ' + E.Message);
    end;
  end;
  if not Failed then
    raise Exception.Create('Unsafe import unexpectedly completed without an error');
end;

procedure RunInpx(ID: Integer; const Filename: string; FullUpdate: Boolean);
var
  ImportThread: TImportInpxThread;
  UpdateThread: TManualUpdateThread;
begin
  if FullUpdate then
  begin
    UpdateThread := TManualUpdateThread.Create(ID, Filename, True, gtFb2);
    try
      UpdateThread.DisplayName := 'Isolated INPX fixture';
      UpdateThread.Start;
      UpdateThread.WaitFor;
      if Assigned(UpdateThread.FatalException) then
        raise Exception.Create(Exception(UpdateThread.FatalException).Message);
    finally
      UpdateThread.Free;
    end;
  end
  else
  begin
    ImportThread := TImportInpxThread.Create(ID, Filename, gtFb2);
    try
      ImportThread.Start;
      ImportThread.WaitFor;
      if Assigned(ImportThread.FatalException) then
        raise Exception.Create(Exception(ImportThread.FatalException).Message);
    finally
      ImportThread.Free;
    end;
  end;
end;

procedure MakeZip(const Filename: string; const Sources, Members: array of string);
var
  Zip: TZipFile;
  I: Integer;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(Filename, zmWrite);
    for I := 0 to High(Sources) do
      Zip.Add(Sources[I], Members[I], zcStored);
    Zip.Close;
  finally
    Zip.Free;
  end;
end;

function InpRow(const Title, Series, Numbers: string): string;
begin
  Result := 'Fixture,Author,:' + #4 + 'prose_contemporary' + #4 +
    Title + #4 + Series + #4 + Numbers + #4 + '42' + #4 + '123' + #4 +
    '42' + #4 + '0' + #4 + 'fb2' + #4 + '2026-10-05' + #4 + 'ru' + #4 +
    '0' + #4 + '' + #4 + '91234' + sLineBreak;
end;

function StreamBytes(Stream: TStream): TBytes;
begin
  Stream.Position := 0;
  SetLength(Result, Stream.Size);
  if Length(Result) > 0 then
    Stream.ReadBuffer(Result[0], Length(Result));
end;

function RunExportList(const Keys: TBookIdList; ExtractOnly: Boolean; const Target: string): string;
var
  Worker: TExportToDeviceThread;
begin
  Worker := TExportToDeviceThread.Create;
  try
    Worker.BookIdList := Keys;
    Worker.ExtractOnly := ExtractOnly;
    Worker.ExportMode := emFB2;
    Worker.DeviceDir := Target;
    Worker.Start;
    Worker.WaitFor;
    if Assigned(Worker.FatalException) then
      raise Exception.Create(Exception(Worker.FatalException).Message);
    Result := Worker.ProcessedFiles;
    if (Result = '') or not FileExists(Result) then
      raise Exception.Create('Production export returned no readable file');
  finally
    Worker.Free;
  end;
end;

function RunExport(const Key: TBookKey; ExtractOnly: Boolean; const Target: string): string;
var
  Keys: TBookIdList;
begin
  SetLength(Keys, 1);
  Keys[0].BookKey := Key;
  Result := RunExportList(Keys, ExtractOnly, Target);
end;

procedure TestExportPaths(const ArchiveKey: TBookKey; const ArchiveFilename: string;
  const OriginalWebP: TBytes);
const
  PLAIN = '<FictionBook><body><section><p>Plain source</p></section></body></FictionBook>';
var
  Collection: IBookCollection;
  Book: TBookRecord;
  ID, BookID, SecondBookID: Integer;
  Keys: TBookIdList;
  OriginalFilename, SecondFilename, Extracted, Target, Exported, Text: string;
  ArchiveBefore, ArchiveAfter, Bytes: TBytes;

  procedure ExpectBytes(const Filename: string; const Expected: TBytes);
  begin
    Bytes := TFile.ReadAllBytes(Filename);
    if (Length(Bytes) <> Length(Expected)) or
      ((Length(Bytes) > 0) and not CompareMem(@Bytes[0], @Expected[0], Length(Bytes))) then
      raise Exception.Create('Export modified original bytes: ' + Filename);
  end;

  procedure ExpectPNG(const Filename: string);
  begin
    Text := TFile.ReadAllText(Filename, TEncoding.UTF8);
    if (Pos('image/png', Text) = 0) or (Pos('iVBOR', Text) = 0) or
      (Pos('Original text', Text) = 0) then
      raise Exception.Create('Production export did not materialize converted PNG and book text');
  end;

begin
  Settings.FileNameTemplate := '%t';
  Settings.FolderTemplate := '';
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  ArchiveBefore := TFile.ReadAllBytes(ArchiveFilename);
  Extracted := RunExport(ArchiveKey, True, Settings.TempPath);
  if SameFileName(Extracted, ArchiveFilename) then
    raise Exception.Create('ExtractOnly returned the archive instead of a book');
  ExpectPNG(Extracted);
  Settings.ConvertWebPToPNG := False;
  Extracted := RunExport(ArchiveKey, True, Settings.TempPath);
  ExpectBytes(Extracted, OriginalWebP);
  ArchiveAfter := TFile.ReadAllBytes(ArchiveFilename);
  if (Length(ArchiveBefore) <> Length(ArchiveAfter)) or
    not CompareMem(@ArchiveBefore[0], @ArchiveAfter[0], Length(ArchiveBefore)) then
    raise Exception.Create('ExtractOnly wrote to the source archive');
  Writeln('PASS production script extraction materializes the chosen WebP policy without changing the archive');

  ID := SystemDB.CreateCollection('Plain export test', Settings.AppPath,
    'plain-export-test.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(ID);
  Book.Clear;
  Book.Title := 'Uppercase fixture';
  Book.FileName := 'uppercase-source';
  Book.FileExt := '.FB2';
  Book.LibID := 'uppercase-source';
  Book.Lang := 'ru';
  Book.Date := EncodeDate(2026, 10, 5);
  Include(Book.BookProps, bpIsLocal);
  BookID := Collection.InsertBook(Book, False, False);
  if BookID <= 0 then raise Exception.Create('Uppercase fixture insertion failed');
  Collection.GetBookRecord(CreateBookKey(BookID, ID), Book, False);
  if Book.GetBookFormat <> bfFb2 then
    raise Exception.Create('Uppercase FB2 was classified as a raw file');
  OriginalFilename := Book.GetBookFileName;
  TFile.WriteAllBytes(OriginalFilename, OriginalWebP);
  Settings.ConvertWebPToPNG := True;
  Extracted := RunExport(Book.BookKey, True, Settings.TempPath);
  if SameFileName(Extracted, OriginalFilename) then
    raise Exception.Create('Uppercase WebP extraction reused the original file');
  ExpectPNG(Extracted);
  ExpectBytes(OriginalFilename, OriginalWebP);
  Target := Settings.AppPath + 'uppercase-export';
  ForceDirectories(Target);
  RunExport(Book.BookKey, False, Target);
  Exported := TPath.Combine(Target, Book.Title + Book.FileExt);
  if not FileExists(Exported) then raise Exception.Create('Direct uppercase FB2 export was not written');
  ExpectPNG(Exported);
  ExpectBytes(OriginalFilename, OriginalWebP);
  Settings.ConvertWebPToPNG := False;
  Extracted := RunExport(Book.BookKey, True, Settings.TempPath);
  if not SameFileName(Extracted, OriginalFilename) then
    raise Exception.Create('Original plain FB2 extraction lost the original path');
  ExpectBytes(Extracted, OriginalWebP);
  TFile.WriteAllBytes(OriginalFilename, TEncoding.UTF8.GetBytes(PLAIN));
  Settings.ConvertWebPToPNG := True;
  Extracted := RunExport(Book.BookKey, True, Settings.TempPath);
  if not SameFileName(Extracted, OriginalFilename) then
    raise Exception.Create('Ordinary plain FB2 extraction lost its stable path');
  ExpectBytes(OriginalFilename, TEncoding.UTF8.GetBytes(PLAIN));
  Writeln('PASS production uppercase FB2 export and extraction honor conversion while ordinary files keep stable paths');
  TFile.WriteAllBytes(OriginalFilename, OriginalWebP);
  Book.Clear;
  Book.Title := 'Uppercase fixture';
  Book.FileName := 'second-uppercase-source';
  Book.FileExt := '.FB2';
  Book.LibID := 'second-uppercase-source';
  Book.Lang := 'ru';
  Book.Date := EncodeDate(2026, 10, 5);
  Include(Book.BookProps, bpIsLocal);
  SecondBookID := Collection.InsertBook(Book, False, False);
  if SecondBookID <= 0 then raise Exception.Create('Second same-title fixture insertion failed');
  Collection.GetBookRecord(CreateBookKey(SecondBookID, ID), Book, False);
  SecondFilename := Book.GetBookFileName;
  Text := StringReplace(TEncoding.UTF8.GetString(OriginalWebP), 'Original text', 'Second payload', []);
  TFile.WriteAllBytes(SecondFilename, TEncoding.UTF8.GetBytes(Text));
  SetLength(Keys, 2);
  Keys[0].BookKey := CreateBookKey(BookID, ID);
  Keys[1].BookKey := CreateBookKey(SecondBookID, ID);
  Extracted := RunExportList(Keys, True, Settings.TempPath);
  ExpectPNG(Extracted);
  if Pos('Second payload', TFile.ReadAllText(Extracted, TEncoding.UTF8)) > 0 then
    raise Exception.Create('Same-title extraction replaced the first processed book with the second');
  ExpectBytes(OriginalFilename, OriginalWebP);
  ExpectBytes(SecondFilename, TEncoding.UTF8.GetBytes(StringReplace(
    TEncoding.UTF8.GetString(OriginalWebP), 'Original text', 'Second payload', [])));
  Collection := nil;
  Writeln('PASS production same-title batch extraction keeps the first processed book intact');
end;

procedure TestCombinedInpx;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
var
  Collection: IBookCollection;
  DB: TSQLiteDatabase;
  CollectionID, LibrusecBook, FlibustaBook, A, B, S: Integer;
  Root, BookFile, LibrusecInp, FlibustaInp, Dataset, BookText, Text: string;
  Original, Bytes, Picture: TBytes;
  Book: TBookRecord;
  Stream: TStream;
  Match: TMatch;
  Iterator: IBookIterator;
begin
  Root := Settings.AppPath;
  BookFile := Root + 'source42.fb2';
  BookText := '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ' +
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>' +
    '<book-title>Flibusta payload</book-title><coverpage><image l:href="#cover.jpg"/>' +
    '</coverpage></title-info></description><body><section><p>Original text</p>' +
    '</section></body><binary content-type="image/jpeg" id="cover.jpg">' +
    WEBP + '</binary></FictionBook>';
  Original := TEncoding.UTF8.GetBytes(BookText);
  TFile.WriteAllBytes(BookFile, Original);
  MakeZip(Root + 'f.fb2-1-100.zip', [BookFile], ['42.fb2']);
  TFile.WriteAllText(BookFile, '<FictionBook><body>Librusec payload</body></FictionBook>', TEncoding.UTF8);
  MakeZip(Root + 'fb2-1-100.zip', [BookFile], ['42.fb2']);
  LibrusecInp := Root + 'librusec.inp';
  FlibustaInp := Root + 'flibusta.inp';
  TFile.WriteAllText(LibrusecInp, InpRow('Librusec forty two', 'A\B\C', '2:0:7'), TEncoding.UTF8);
  TFile.WriteAllText(FlibustaInp, InpRow('Flibusta forty two', '', ''), TEncoding.UTF8);
  Dataset := Root + 'combined.inpx';
  MakeZip(Dataset, [LibrusecInp, FlibustaInp], ['fb2-1-100.inp', 'f.fb2-1-100.inp']);
  CollectionID := SystemDB.CreateCollection('Combined INPX test', Root,
    'combined-test.hlc2', CT_EXTERNAL_LOCAL_FB, Root + 'genres_fb2.glst');
  RunInpx(CollectionID, Dataset, False);
  SystemDB.ClearCollectionCache;
  Collection := SystemDB.GetCollection(CollectionID);
  Collection.GetStatistics(A, B, S);
  if B <> 2 then raise Exception.Create('Combined INPX lost books with colliding numeric IDs');
  if not Boolean(Collection.GetProperty(PROP_MIXED_LIBRARY_IDS)) then
    raise Exception.Create('Combined INPX did not preserve its namespace marker');
  DB := TSQLiteDatabase.Create(string(Collection.GetProperty(PROP_DATAFILE)));
  try
    LibrusecBook := DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID = ''librusec:42''');
    FlibustaBook := DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID = ''flibusta:42''');
    if (LibrusecBook <= 0) or (FlibustaBook <= 0) or (LibrusecBook = FlibustaBook) then
      raise Exception.Create('Combined INPX identities are not separated');
    if DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE BookID = ?', [LibrusecBook]) <> 3 then
      raise Exception.Create('Combined INPX dropped secondary series');
    if DB.QuerySingleInt('SELECT sl.SeqNumber FROM Series_List sl INNER JOIN Series s ON s.SeriesID=sl.SeriesID WHERE sl.BookID=? AND s.SeriesTitle=''C''', [LibrusecBook]) <> 7 then
      raise Exception.Create('Combined INPX mismatched parallel sequence numbers');
    if DB.QuerySingleInt('SELECT InsideNo FROM Books WHERE BookID=?', [FlibustaBook]) <> 0 then
      raise Exception.Create('Legacy INPX index replaced the actual archive entry position');
  finally
    DB.Free;
  end;
  Writeln('PASS production INPX import separates sources and registers all parallel series');

  Collection.GetBookRecord(CreateBookKey(FlibustaBook, CollectionID), Book, False);
  if not Settings.ConvertWebPToPNG then raise Exception.Create('WebP compatibility default is disabled');
  Stream := Book.GetBookStream;
  if not Assigned(Stream) then raise Exception.Create('INPX book stream was not opened');
  try
    Text := TEncoding.UTF8.GetString(StreamBytes(Stream));
    if (Pos('Flibusta payload', Text) = 0) or (Pos('Original text', Text) = 0) or
      (Pos('l:href="#cover.jpg"', Text) = 0) or
      (Pos('content-type="image/png" id="cover.jpg"', Text) = 0) then
      raise Exception.Create('Production stream changed book identity/text or failed WebP normalization');
    Match := TRegEx.Match(Text, 'id="cover.jpg">([^<]+)</binary>');
    if not Match.Success then raise Exception.Create('Normalized binary was not found');
    Picture := TNetEncoding.Base64.DecodeStringToBytes(Match.Groups[1].Value);
    if (Length(Picture) < 8) or (Picture[0] <> $89) or (Picture[1] <> Ord('P')) then
      raise Exception.Create('Production stream declared PNG without PNG bytes');
  finally
    Stream.Free;
  end;
  Settings.ConvertWebPToPNG := False;
  try
    Stream := Book.GetBookStream;
    if not Assigned(Stream) then raise Exception.Create('Original WebP stream was not opened');
    try
      Bytes := StreamBytes(Stream);
      if (Length(Bytes) <> Length(Original)) or
        not CompareMem(@Bytes[0], @Original[0], Length(Original)) then
        raise Exception.Create('Keep-original option changed source FB2 bytes');
    finally
      Stream.Free;
    end;
  finally
    Settings.ConvertWebPToPNG := True;
  end;
  Writeln('PASS production book stream converts WebP by default and preserves exact original on request');
  TestExportPaths(CreateBookKey(FlibustaBook, CollectionID), Root + 'f.fb2-1-100.zip', Original);

  Collection.SetRate(CreateBookKey(LibrusecBook, CollectionID), 3);
  Collection.SetProgress(CreateBookKey(LibrusecBook, CollectionID), 99);
  Collection.SetRate(CreateBookKey(FlibustaBook, CollectionID), 5);
  Collection.SetProgress(CreateBookKey(FlibustaBook, CollectionID), 64);
  Collection.AddBookToGroup(CreateBookKey(LibrusecBook, CollectionID), FAVORITES_GROUP_ID);
  Collection.AddBookToGroup(CreateBookKey(FlibustaBook, CollectionID), FAVORITES_GROUP_ID);
  Collection := nil;
  TFile.WriteAllText(FlibustaInp, InpRow('Flibusta updated', '', ''), TEncoding.UTF8);
  Dataset := Root + 'flibusta-original.inpx';
  MakeZip(Dataset, [FlibustaInp], ['f.fb2-1-100.inp']);
  RunInpx(CollectionID, Dataset, True);
  SystemDB.ClearCollectionCache;
  Collection := SystemDB.GetCollection(CollectionID);
  Collection.GetStatistics(A, B, S);
  if (B <> 1) or not Boolean(Collection.GetProperty(PROP_MIXED_LIBRARY_IDS)) then
    raise Exception.Create('Single-source full update lost the namespace marker or retained obsolete rows');
  DB := TSQLiteDatabase.Create(string(Collection.GetProperty(PROP_DATAFILE)));
  try
    FlibustaBook := DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=''flibusta:42''');
    if (FlibustaBook <= 0) or
      (DB.QuerySingleInt('SELECT Rate FROM Books WHERE BookID=?', [FlibustaBook]) <> 5) or
      (DB.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=?', [FlibustaBook]) <> 64) or
      (DB.QuerySingleString('SELECT Title FROM Books WHERE BookID=?', [FlibustaBook]) <> 'Flibusta updated') then
      raise Exception.Create('Full original update restored state onto the wrong source book');
  finally
    DB.Free;
  end;
  Iterator := SystemDB.GetBookIterator(FAVORITES_GROUP_ID);
  if not Iterator.Next(Book) or (Book.BookKey.DatabaseID <> CollectionID) or
    (Book.LibID <> 'flibusta:42') or Iterator.Next(Book) then
    raise Exception.Create('Full original update did not preserve the correct source in Favorites');
  Iterator := nil;
  Collection := nil;
  Writeln('PASS single-source full INPX update preserves namespace, rating, progress and Favorites');
end;
var
  Collection: IBookCollection;
  CollectionID, A, B, S: Integer;
  Filter: TFilterValue;
  Iterator: IGenreIterator;
  Genre, First: TGenreData;
  Dataset: string;
  DB: TSQLiteDatabase;
  Payload: string;
begin
  try
    RequireIsolatedRegression;
    Application.Initialize;
    DMUser := TDMUser.Create(nil);
    try
      DMUser.Init;
      CollectionID := SystemDB.CreateCollection('Import test', Settings.AppPath,
        'import-test.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      Dataset := Settings.AppPath + 'import.jsonl';
      System.IOUtils.TFile.WriteAllText(Dataset,
        '{"schema":"metabib.dataset/1","record_schema":"metabib.dataset_record/1","library":"flibusta","records":2,"archives":[{"id":"arc","name":"fixture.zip"}]}' + sLineBreak +
        '{"schema":"metabib.dataset_record/1","record":{"library":"flibusta","locator":{"kind":"archive_entry","source":"arc","index":0,"book_id":101}},"artifacts":[{"occurrences":[{"archive":"arc","entry":"101.fb2","index":0,"uncompressed_size":100}]}],"claims":{"bibliographic":{"title":[{"value":"First"}],"genres":[{"observation":"db","value":[{"code":"popadancy","description":"Source genre","meta":"Source category"}]},{"observation":"fb2","value":[{"code":"untrusted_tag"}]}]}}}' + sLineBreak +
        '{"schema":"metabib.dataset_record/1","record":{"library":"flibusta","locator":{"kind":"archive_entry","source":"arc","index":1,"book_id":102}},"artifacts":[{"occurrences":[{"archive":"arc","entry":"102.fb2","index":1,"uncompressed_size":100}]}],"claims":{"bibliographic":{"title":[{"value":"Second"}],"genres":[{"observation":"db","value":[{"code":"popadancy","description":"Source genre","meta":"Source category"}]}]}}}' + sLineBreak,
        TEncoding.UTF8);
      RunImport(CollectionID, Dataset);
      SystemDB.ClearCollectionCache;
      Collection := SystemDB.GetCollection(CollectionID);
      Collection.GetStatistics(A, B, S);
      if B <> 2 then raise Exception.Create('Import did not preserve both books');
      if not Boolean(Collection.GetProperty(PROP_SOURCE_GENRES)) then
        raise Exception.Create('Source taxonomy provenance was not saved');
      if string(Collection.GetProperty(PROP_SOURCE_LIBRARY)) <> 'flibusta' then
        raise Exception.Create('Source library identity was not saved');
      Filter.ValueInt := 1;
      Iterator := Collection.GetGenreIterator(gmByBook, @Filter);
      if not Iterator.Next(First) then raise Exception.Create('First book has no genre');
      if (First.FB2GenreCode <> 'popadancy') or (First.GenreAlias <> 'Source genre') then
        raise Exception.Create('Curated genre was not mapped');
      if Iterator.Next(Genre) then raise Exception.Create('Untrusted FB2 genre was merged');
      Filter.ValueInt := 2;
      Iterator := Collection.GetGenreIterator(gmByBook, @Filter);
      if not Iterator.Next(Genre) or (Genre.GenreCode <> First.GenreCode) then
        raise Exception.Create('Repeated source genre was duplicated');
      Writeln('PASS production import registers curated definitions and preserves source identity');
      Iterator := nil;
      Collection := nil;
      CollectionID := SystemDB.CreateCollection('Wrong source', Settings.AppPath,
        'wrong-source.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      Collection := SystemDB.GetCollection(CollectionID);
      Collection.SetProperty(PROP_SOURCE_LIBRARY, 'other-library');
      ExpectImportFailure(CollectionID, Dataset, 'Каталог другой библиотеки');
      Collection.GetStatistics(A, B, S);
      if (B <> 0) or (string(Collection.GetProperty(PROP_SOURCE_LIBRARY)) <> 'other-library') then
        raise Exception.Create('Conflicting source import changed the collection');
      Writeln('PASS conflicting source import leaves data unchanged');
      Collection := nil;
      CollectionID := SystemDB.CreateCollection('Lost transaction', Settings.AppPath,
        'lost-transaction.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      Collection := SystemDB.GetCollection(CollectionID);
      DB := TSQLiteDatabase.Create(string(Collection.GetProperty(PROP_DATAFILE)));
      try
        DB.ExecSQL('CREATE TRIGGER stop_import BEFORE INSERT ON Genres WHEN NEW.FB2Code = ''boom'' BEGIN SELECT RAISE(ROLLBACK, ''Lost transaction''); END');
        Payload := StringReplace(System.IOUtils.TFile.ReadAllText(Dataset),
          '"code":"popadancy"', '"code":"boom"', []);
        System.IOUtils.TFile.WriteAllText(Dataset, Payload, TEncoding.UTF8);
        ExpectImportFailure(CollectionID, Dataset, 'Транзакция импорта была прервана');
        if DB.QuerySingleInt('SELECT COUNT(*) FROM Books') <> 0 then
          raise Exception.Create('Importer continued writing after losing its transaction');
        if DB.QuerySingleInt('SELECT COUNT(*) FROM Genres WHERE FB2Code IN (''boom'', ''popadancy'')') <> 0 then
          raise Exception.Create('Lost import transaction left source genres behind');
      finally
        DB.Free;
      end;
      Writeln('PASS production importer stops after losing the outer transaction');
      Collection := nil;
      TestCombinedInpx;
    finally
      DMUser.Free;
      DMUser := nil;
    end;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
