program CollectionViewsTest;

{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses
  NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows,
  Vcl.Forms, Vcl.Menus, Vcl.ComCtrls, Vcl.ExtCtrls,
  VirtualTrees, BookTreeView,
  unit_Globals, unit_Consts, unit_Interfaces, unit_Localization, unit_TreeUtils,
  unit_MHLArchiveHelpers, unit_ExportToDeviceThread,
  dm_user, dm_Images, frm_splash, frm_main, frm_genre_tree, unit_PublisherSeriesView;

type
  TRegressionExceptionHandler = class
    procedure HandleException(Sender: TObject; E: Exception);
  end;

procedure TRegressionExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  // VCL otherwise displays a modal dialog inside form/event construction,
  // hiding the cause from a console runner until its timeout.
  Writeln('FAIL VCL ', E.ClassName, ': ', E.Message);
  Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
  Flush(Output);
  Halt(1);
end;

procedure Require(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(Message);
end;

var
  CleanupExitTemp, CleanupExitPersistent, CleanupExitSource: string;

procedure TestHeaderMenuTags;
const
  Expected: array[0..12] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE, COL_COLLECTION,
    COL_LANG, COL_LIBRATE, COL_LIBID);
var
  I: Integer;
  ColumnHandler: TMethod;
begin
  Require(frmMain.pmHeaders.Items.Count = Length(Expected) + 2,
    'Wrong header menu structure');
  ColumnHandler := TMethod(frmMain.pmHeaders.Items[0].OnClick);
  for I := Low(Expected) to High(Expected) do
  begin
    Require(frmMain.pmHeaders.Items[I].Tag = Expected[I],
      'Header column identity changed at index ' + IntToStr(I));
    Require(TMethod(frmMain.pmHeaders.Items[I].OnClick).Code = ColumnHandler.Code,
      'A column lost its header action');
  end;
  Require((frmMain.pmHeaders.Items[13] = frmMain.N25) and
    (frmMain.N25.Caption = '-') and (frmMain.N25.Tag = 0) and
    not Assigned(frmMain.N25.OnClick),
    'Header separator must never be treated as a column');
  Require((frmMain.pmHeaders.Items[14] = frmMain.N27) and
    (frmMain.N27.Tag = 0) and Assigned(frmMain.N27.OnClick) and
    (TMethod(frmMain.N27.OnClick).Code <> ColumnHandler.Code),
    'Default header action must never be treated as a column');
  Writeln('PASS header menu keeps column IDs separate from separator and default action');
end;

procedure Trace(const Stage: string);
begin
  Writeln('TRACE ', Stage);
  Flush(Output);
end;

procedure HandleReaderProbe;
var
  Root, FileName: string;
begin
  if (ParamCount <> 1) or not SameText(ExtractFileExt(ParamStr(1)), '.fb2') then Exit;
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0))));
  FileName := ExpandFileName(ParamStr(1));
  Require(SameText(Copy(FileName, 1, Length(Root)), Root) and FileExists(FileName),
    'Reader probe must remain inside its isolated runtime');
  TFile.WriteAllText(Root + 'reader-probe-path.txt.tmp', FileName, TEncoding.UTF8);
  TFile.Move(Root + 'reader-probe-path.txt.tmp', Root + 'reader-probe-path.txt');
  Halt(0);
end;

procedure TestReaderCompatibility;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  PLAIN = '<?xml version="1.0" encoding="utf-8"?><FictionBook><body><section><p>Plain book</p></section></body></FictionBook>';
var
  Book: PBookRecord;
  Original, Probe, Converted, WithWebP, Captured: string;
  Started: UInt64;

  function ReadSelected: string;
  begin
    if FileExists(Probe) then TFile.Delete(Probe);
    frmMain.ReadBookExecute(nil);
    Started := GetTickCount64;
    while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do Sleep(20);
    Require(FileExists(Probe), 'The isolated reader probe did not receive a book');
    Result := TFile.ReadAllText(Probe, TEncoding.UTF8);
  end;

begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Book.GetBookFormat = bfFb2), 'Reader fixture is not a plain FB2');
  Original := Book.GetBookFileName;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  TFile.WriteAllText(Original, PLAIN, TEncoding.UTF8);
  Captured := ReadSelected;
  Require(SameFileName(Captured, Original), 'An ordinary FB2 lost its stable reader path');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = PLAIN, 'An ordinary source book changed');
  WithWebP := '<FictionBook><body><section><p>WebP book</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
  TFile.WriteAllText(Original, WithWebP, TEncoding.UTF8);
  Converted := ReadSelected;
  Require(not SameFileName(Converted, Original) and
    (Pos('webp-png', LowerCase(Converted)) > 0), 'A WebP book was not read from its converted cache');
  Captured := TFile.ReadAllText(Converted, TEncoding.UTF8);
  Require((Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0),
    'The reader received no converted PNG');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'The WebP source book changed');
  Settings.ConvertWebPToPNG := False;
  Require(SameFileName(ReadSelected, Original), 'Original mode reused the converted reader cache');
  Settings.ConvertWebPToPNG := True;
  Require(SameFileName(ReadSelected, Converted), 'PNG mode lost its separate reader cache');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'Reader policy changes wrote to the source');
  Writeln('PASS plain FB2 reader preserves ordinary paths, converts WebP, separates policy cache and leaves source unchanged');
end;

procedure MakeCleanupFixture(const Folder: string);
begin
  TDirectory.CreateDirectory(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER));
  TFile.WriteAllText(TPath.Combine(Folder, 'ordinary.tmp'), 'temporary root file');
  TFile.WriteAllText(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER + '\copy.fb2'), 'converted copy');
end;

procedure TestReadFolderCleanup;
var
  Root, Converted, Persistent, Unrelated, JunctionRoot, Outside: string;
  Busy: TFileStream;
begin
  TestReaderCompatibility;
  Root := Settings.TempDir;
  Converted := TFile.ReadAllText(Settings.AppPath + 'reader-probe-path.txt', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(Root, 'ordinary.tmp'), 'root cleanup probe');
  Unrelated := TPath.Combine(Root, 'unrelated\keep.txt');
  TDirectory.CreateDirectory(ExtractFilePath(Unrelated));
  TFile.WriteAllText(Unrelated, 'unrelated directory must survive');
  Busy := TFileStream.Create(Converted, fmOpenRead or fmShareExclusive);
  try
    frmMain.ClearReadFolderExecute(nil);
    Require(FileExists(Converted), 'A reader-locked book was deleted');
    Require(not FileExists(TPath.Combine(Root, 'ordinary.tmp')), 'Other temporary files were not cleaned');
  finally
    Busy.Free;
  end;
  frmMain.ClearReadFolderExecute(nil);
  Require(not FileExists(Converted), 'Converted reader copy survived explicit cleanup');
  Require(not DirectoryExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER)), 'Empty converted reader folder survived cleanup');
  Require(FileExists(Unrelated), 'Cleanup recursed into an unrelated directory');
  frmMain.ClearReadFolderExecute(nil);
  Writeln('PASS manual reader cleanup removes converted copies, preserves unrelated folders and retries busy files');

  Persistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(Persistent);
  MakeCleanupFixture(Root);
  Settings.ReadDir := Persistent;
  frmMain.ClearReadFolderExecute(nil);
  Require(not FileExists(TPath.Combine(Persistent, 'ordinary.tmp')) and
    not DirectoryExists(TPath.Combine(Persistent, WEBP_READER_CACHE_FOLDER)), 'Explicit custom reader folder cleanup failed');
  Require(FileExists(TPath.Combine(Root, 'ordinary.tmp')) and
    FileExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Custom reader cleanup changed the default temp folder');
  Writeln('PASS custom reading folder is cleared only when explicitly selected');

  // The Node wrapper creates this junction entirely inside its owned runtime.
  JunctionRoot := TPath.Combine(Settings.AppPath, 'junction-reading');
  Outside := TPath.Combine(Settings.AppPath, 'junction-target\keep.fb2');
  Require(FileExists(Outside) and DirectoryExists(TPath.Combine(JunctionRoot, WEBP_READER_CACHE_FOLDER)), 'Junction fixture is absent');
  Settings.ReadDir := JunctionRoot;
  frmMain.ClearReadFolderExecute(nil);
  Require(FileExists(Outside), 'Cleanup followed the cache junction into another folder');
  Require(not FileExists(TPath.Combine(JunctionRoot, 'ordinary.tmp')), 'Junction protection prevented ordinary file cleanup');
  Settings.ReadDir := '';
  Writeln('PASS reader cleanup does not follow a converted-cache junction');
end;

procedure TestExitReaderCleanup;
var
  Book: PBookRecord;
begin
  TestReaderCompatibility;
  CleanupExitTemp := Settings.TempDir;
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  CleanupExitSource := Book.GetBookFileName;
  MakeCleanupFixture(CleanupExitTemp);
  CleanupExitPersistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(CleanupExitPersistent);
  Settings.ReadDir := CleanupExitPersistent;
end;

procedure CheckExitReaderCleanup;
begin
  Require(not FileExists(TPath.Combine(CleanupExitTemp, 'ordinary.tmp')) and
    not DirectoryExists(TPath.Combine(CleanupExitTemp, WEBP_READER_CACHE_FOLDER)), 'Main-form destruction left temporary reader copies');
  Require(FileExists(TPath.Combine(CleanupExitPersistent, 'ordinary.tmp')) and
    FileExists(TPath.Combine(CleanupExitPersistent, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Exit removed persistent custom reading files');
  Require(FileExists(CleanupExitSource), 'Exit removed the original library book');
  Writeln('PASS real main-form exit removes temporary converted copies and preserves custom reading files and originals');
end;

function AddBook(const Collection: IBookCollection; const Title, Author,
  Lang, Series, Genre: string; Deleted: Boolean = False): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := Title;
  Book.FileExt := '.fb2';
  Book.LibID := Title;
  Book.Lang := Lang;
  Book.Series := Series;
  Book.Date := EncodeDate(2020, 1, 1);
  TAuthorsHelper.Add(Book.Authors, Author, 'Alex', '');
  if Genre <> '' then
    if Pos('0.', Genre) = 1 then
      TGenresHelper.Add(Book.Genres, Genre, '', '')
    else
      TGenresHelper.Add(Book.Genres, '', '', Genre);
  Include(Book.BookProps, bpIsLocal);
  if Deleted then
    Include(Book.BookProps, bpIsDeleted);
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Fixture book was not inserted');
end;

procedure ExpectTitles(Tree: TBookTree; const Expected: array of string);
var
  Actual, Wanted: TStringList;
  Node: PVirtualNode;
  Book: PBookRecord;
  Title: string;
begin
  Actual := TStringList.Create;
  Wanted := TStringList.Create;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book := Tree.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) then
        Actual.Add(Book.Title);
      Node := Tree.GetNext(Node);
    end;
    for Title in Expected do
      Wanted.Add(Title);
    Actual.Sort;
    Wanted.Sort;
    Require(Actual.Text = Wanted.Text,
      'Wrong visible books. Expected: ' + Wanted.CommaText + '; actual: ' + Actual.CommaText);
  finally
    Wanted.Free;
    Actual.Free;
  end;
end;

procedure ChangeCollection(ID: Integer);
var
  Item: TMenuItem;
begin
  for Item in frmMain.miCollSelect do
    if Item.Tag = ID then
    begin
      frmMain.miActiveCollectionClick(Item);
      Exit;
    end;
  raise Exception.Create('Fixture collection is absent from the collection menu');
end;

procedure ShowPage(Index: Integer);
begin
  // HomeLib Ru inserts Publisher Series between the physical tab pages.
  // PAGE_* values identify views, not PageIndex after that insertion.
  case Index of
    PAGE_AUTHORS: frmMain.pgControl.ActivePage := frmMain.tsByAuthor;
    PAGE_SERIES: frmMain.pgControl.ActivePage := frmMain.tsBySerie;
    PAGE_GENRES: frmMain.pgControl.ActivePage := frmMain.tsByGenre;
    PAGE_SEARCH: frmMain.pgControl.ActivePage := frmMain.tsSearch;
    PAGE_FAVORITES: frmMain.pgControl.ActivePage := frmMain.tsByGroup;
  else
    raise Exception.Create('Unsupported test view');
  end;
  frmMain.pgControlChange(nil);
end;

procedure RequestRootGenreBooks;
begin
  if frmMain.btnShowGenreBooks.Visible then
    frmMain.btnShowGenreBooksClick(nil);
end;

procedure TestOnlineDownload(const Collection: IBookCollection;
  DirectBookID, QueueBookID, RestartBookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured, SourceFile, ExportDir: string;
  Started: UInt64;
  SourceBytes: TBytes;
  Keys: TBookIdList;
  Worker: TExportToDeviceThread;
  Component: TComponent;
  HasCover: Boolean;

  procedure RequireUnchangedZip;
  var
    Actual: TBytes;
  begin
    Actual := TFile.ReadAllBytes(SourceFile);
    Require((Length(Actual) = Length(SourceBytes)) and
      CompareMem(Pointer(SourceBytes), Pointer(Actual), Length(SourceBytes)),
      'Reading, preview or export rewrote the downloaded ZIP');
  end;

  procedure Pump;
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;

  procedure SelectBook(const BookID: Integer);
  begin
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Book := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) and
        (Book.BookKey.BookID = BookID) then Break;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Assigned(Node), 'Online book is absent from the visible author list');
    frmMain.tvBooksA.ClearSelection;
    frmMain.tvBooksA.Selected[Node] := True;
    frmMain.tvBooksA.FocusedNode := Node;
    frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  end;

  procedure ReadSelected;
  begin
    if FileExists(Probe) then TFile.Delete(Probe);
    frmMain.ReadBookExecute(nil);
    Started := GetTickCount64;
    while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do Pump;
    Require(FileExists(Probe), 'Online download did not hand a book to the reader');
    Captured := TFile.ReadAllText(Probe, TEncoding.UTF8);
    Require(FileExists(Captured), 'The reader received an absent file');
    Captured := TFile.ReadAllText(Captured, TEncoding.UTF8);
    Require((Pos('Online fixture text', Captured) > 0) and
      (Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0) and
      (Pos('UklGR', Captured) = 0),
      'Online reader received the wrong book or unconverted WebP');
  end;

begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.DwnldInterval := 0;
  Settings.AutoStartDwnld := False;
  Settings.SelectedIsChecked := True;
  Settings.ErrorLog := True;
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  Settings.ShowBookCover := True;
  Settings.ShowBookAnnotation := True;
  Settings.ShowInfoPanel := True;
  frmMain.ipnlAuthors.ShowCover := True;
  frmMain.ipnlAuthors.ShowAnnotation := True;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  SelectBook(DirectBookID);
  Require((Book.GetBookFormat = bfFb2Archive) and
    not (bpIsLocal in Book.BookProps), 'Online fixture must start as a remote FB2 ZIP');
  Trace('online direct reader download');
  ReadSelected;
  Collection.GetBookRecord(CreateBookKey(DirectBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Online direct download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  Require(FileExists(SourceFile), 'Downloaded ZIP is absent');
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  HasCover := False;
  for Component in frmMain.ipnlAuthors do
    if (Component is TImage) and Assigned(TImage(Component).Picture.Graphic) then
      HasCover := not TImage(Component).Picture.Graphic.Empty;
  Require(HasCover, 'Downloaded WebP cover is absent from the real main info panel');
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main reader downloads ZIP, updates local status, previews cover and reads converted FB2');

  SelectBook(QueueBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Queue fixture is already local');
  Trace('online download queue');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Online book was not added to the real download queue');
  frmMain.btnStartDownloadClick(nil);
  Trace('online queue manager started');
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'Online download queue did not complete successfully');
  Collection.GetBookRecord(CreateBookKey(QueueBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Queue download did not update database and main tree local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  Trace('online queued book downloaded');
  ReadSelected;
  Settings.FileNameTemplate := '%t';
  Settings.FolderTemplate := '';
  ExportDir := TPath.Combine(Settings.AppPath, 'online-export');
  ForceDirectories(ExportDir);
  SetLength(Keys, 1);
  Keys[0].BookKey := Stored.BookKey;
  Worker := TExportToDeviceThread.Create;
  Trace('online export worker created');
  try
    Worker.BookIdList := Keys;
    Worker.ExtractOnly := False;
    Worker.ExportMode := emFB2;
    Worker.DeviceDir := ExportDir;
    Worker.Start;
    Worker.WaitFor;
    Require(not Assigned(Worker.FatalException), 'Online downloaded book export failed');
  finally
    Worker.Free;
  end;
  Captured := TFile.ReadAllText(TPath.Combine(ExportDir, Stored.Title + '.fb2'), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Export of the queued online book lost its text or conversion policy');
  RequireUnchangedZip;
  Writeln('PASS online main queue downloads ZIP and its local book remains readable and exportable');

  SelectBook(RestartBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Restart fixture is already local');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Restart book was not added to the real queue');
  frmMain.btnStartDownloadClick(nil);
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'The completed download manager could not be restarted');
  Collection.GetBookRecord(CreateBookKey(RestartBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Restart download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main queue restarts for another remote book and preserves its downloaded ZIP');
end;

procedure CreateOnlineResponse;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  XML = '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ' +
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>' +
    '<author><first-name>Alex</first-name><last-name>Online</last-name></author>' +
    '<book-title>Online payload</book-title><annotation><p>Online fixture annotation</p></annotation>' +
    '<coverpage><image l:href="#cover.jpg"/></coverpage><lang>ru</lang>' +
    '</title-info></description><body><section><p>Online fixture text</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
var
  Zip: TMHLZip;
  Stream: TBytesStream;
begin
  TFile.WriteAllBytes(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8.GetBytes(XML));
  Zip := TMHLZip.Create(Settings.AppPath + 'download-response.zip', False);
  try
    Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML));
    try
      // Real servers need not use the INPX display filename for their ZIP member.
      Zip.AddFromStream('server-member-name.fb2', Stream);
    finally
      Stream.Free;
    end;
  finally
    Zip.Free;
  end;
end;

function AddOnlineBook(const Collection: IBookCollection;
  const Title, LibID: string; const AsArchive: Boolean = True): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := LibID;
  Book.FileExt := '.fb2';
  Book.LibID := LibID;
  Book.Lang := 'ru';
  Book.Date := EncodeDate(2026, 10, 6);
  TAuthorsHelper.Add(Book.Authors, 'Online', 'Alex', '');
  TGenresHelper.Add(Book.Genres, '', '', 'prose_contemporary');
  if AsArchive then
    Book.Folder := Book.GenerateLocation + FB2ZIP_EXTENSION
  else
    Book.Folder := 'online-plain' + PathDelim;
  Book.InsideNo := 0;
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Online fixture book was not inserted');
end;

procedure TestOnlinePlain(const Collection: IBookCollection; BookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured: string;
  Started: UInt64;
begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.Readers.Clear;
  Settings.ErrorLog := True;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  Node := frmMain.tvBooksA.GetFirst;
  Require(Assigned(Node), 'Plain online fixture is absent');
  Book := frmMain.tvBooksA.GetNodeData(Node);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID) and
    (Book.GetBookFormat = bfFb2) and not (bpIsLocal in Book.BookProps),
    'Plain online fixture must start remote without a ZIP container');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  frmMain.ReadBookExecute(nil);
  Started := GetTickCount64;
  while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;
  Require(FileExists(Probe), 'Plain remote FB2 was opened before downloading');
  Captured := TFile.ReadAllText(TFile.ReadAllText(Probe, TEncoding.UTF8), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Plain online reader received the wrong book or unconverted WebP');
  Collection.GetBookRecord(CreateBookKey(BookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Plain online download did not update local status');
  Require(TFile.ReadAllText(Stored.GetBookFileName, TEncoding.UTF8) =
    TFile.ReadAllText(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8),
    'Plain online reader modified the downloaded source');
  Writeln('PASS plain online FB2 is downloaded before compatibility conversion and reader handoff');
end;

procedure TestLanguageIsolation;
begin
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  ShowPage(PAGE_GENRES);
  ShowPage(PAGE_AUTHORS);
  frmMain.btnSwitchTreeModeClick(nil);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Another view reset the selected author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  frmMain.btnSwitchTreeModeClick(nil);
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  Writeln('PASS language choice survives another view first load and repeated refreshes');
end;

procedure TestAddBeforeFirstGroupVisit;
var
  Node: PVirtualNode;
  Book: PBookRecord;
begin
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if (Book.NodeType = ntBookInfo) and (Book.Title = 'Alpha extra uk') then
      Break;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Require(Assigned(Node), 'The book to add is absent');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  Require(frmMain.acBookAdd2Favorites.Execute, 'Add to Favorites action was disabled');
  ShowPage(PAGE_FAVORITES);
  Require(frmMain.cbLangSelectF.Text = 'ru', 'Adding a book lost the unopened group language filter');
  ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
  Writeln('PASS adding a book before first group visit preserves its language filter');
end;

procedure TestGenreLink;
var
  Book: PBookRecord;
  BookID: Integer;
  GenreCode: string;
begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Length(Book.Genres) = 1), 'The linked book has no genre');
  BookID := Book.BookKey.BookID;
  GenreCode := Book.Genres[0].GenreCode;
  frmMain.ipnlAuthors.OnGenreLinkClicked(frmMain.ipnlAuthors, GenreCode, Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsByGenre, 'Genre link did not activate its page');
  Require(frmMain.lblGenreTitle.Caption = Book.Genres[0].GenreAlias,
    'Genre link left the previous genre title visible');
  ExpectTitles(frmMain.tvBooksG, ['Alpha ru']);
  Book := frmMain.tvBooksG.GetNodeData(frmMain.tvBooksG.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Genre link did not retain the requested book');
  Writeln('PASS genre link restores the requested genre, language and book');
end;

procedure TestGenreOrder(const Collection: IBookCollection; UnknownBook: Integer);
var
  Node: PVirtualNode;
  Genre: PGenreData;
  Filter: TFilterValue;
begin
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = '0.1'), 'First classified genre was not selected');
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(frmMain.tvGenres.GetNextSibling(Node)) do
    Node := frmMain.tvGenres.GetNextSibling(Node);
  Genre := frmMain.tvGenres.GetNodeData(Node);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Unsorted is not the last tree category');
  ShowPage(PAGE_GENRES);
  ExpectTitles(frmMain.tvBooksG, []);
  Require(frmMain.btnShowGenreBooks.Visible, 'Root genre has no explicit Show action');
  RequestRootGenreBooks;
  Require(frmMain.cbLangSelectG.Text = 'ru', 'Root Show lost the deferred saved language');
  ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmAll), False, UNKNOWN_GENRE_CODE);
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Explicit Unsorted selection was lost');
  ExpectTitles(frmMain.tvBooksG, ['Unknown']);
  Filter.ValueInt := UnknownBook;
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmByBook, @Filter));
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Only-Unsorted tree has no selection');
  Writeln('PASS Unsorted is last, first genre is default, explicit selection and fallback work');
end;

procedure TestSourceGenrePreservation(const Expected: TGenreData);
var
  Node: PVirtualNode;
  Genre: PGenreData;
begin
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(Node) do
  begin
    Genre := frmMain.tvGenres.GetNodeData(Node);
    if Genre.GenreCode = Expected.GenreCode then
    begin
      Require((Genre.GenreAlias = Expected.GenreAlias) and
        (Genre.ParentCode = Expected.ParentCode), 'Locale update changed imported genre metadata');
      Writeln('PASS imported source genre survives locale synchronization');
      Exit;
    end;
    Node := frmMain.tvGenres.GetNext(Node);
  end;
  raise Exception.Create('Locale synchronization removed an imported genre');
end;

function PublisherView: TPublisherSeriesView;
var
  Component: TComponent;
begin
  for Component in frmMain do
    if Component is TPublisherSeriesView then
      Exit(TPublisherSeriesView(Component));
  raise Exception.Create('Publisher view was not created');
end;

procedure TestPublisherSelection(OneID, TwoID, SavedBook: Integer);
var
  View: TPublisherSeriesView;
  Book: PBookRecord;
begin
  View := PublisherView;
  Require(View.SeriesTree.GetFirst = nil, 'Hidden publisher list was eagerly built');
  ExpectTitles(View.Books, []);
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'First publisher visit lost its saved language');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'First publisher visit lost its saved book');
  ShowPage(PAGE_AUTHORS);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Publisher filtering reset author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  ChangeCollection(TwoID);
  ChangeCollection(OneID);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'Publisher language was lost across collections');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'Publisher book was lost across collections');
  Writeln('PASS deferred publisher view restores its language and book without changing author selection');
end;

var
  One, Two, Online: IBookCollection;
  OneID, TwoID, FirstBook, LastBook, UnknownBook, I: Integer;
  OnlineID, DirectBookID, QueueBookID, RestartBookID, Port: Integer;
  Book: PBookRecord;
  ImportedGenre: TGenreData;
  PublisherSeries: TBookSeries;
  PublisherIterator: ISeriesIterator;
  Publisher: TSeriesData;
  ExceptionHandler: TRegressionExceptionHandler;
begin
  try
    RequireIsolatedRegression;
    HandleReaderProbe;
    DirectBookID := 0;
    QueueBookID := 0;
    RestartBookID := 0;
    Trace('application bootstrap');
    Application.Initialize;
    ExceptionHandler := TRegressionExceptionHandler.Create;
    Application.OnException := ExceptionHandler.HandleException;
    Trace('localization');
    InitLocalization;
    Trace('splash construction');
    frmSplash := TfrmSplash.Create(Application);
    try
      Trace('isolated user module');
      Application.CreateForm(TDMUser, DMUser);
      DMUser.Init;
      Trace('tiny fixtures');
      OneID := SystemDB.CreateCollection('One', Settings.AppPath,
        'one.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      TwoID := SystemDB.CreateCollection('Two', Settings.AppPath,
        'two.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      One := SystemDB.GetCollection(OneID);
      Two := SystemDB.GetCollection(TwoID);
      FirstBook := AddBook(One, 'Alpha uk', 'Alpha', 'uk', 'Alpha series', 'prose_contemporary');
      LastBook := AddBook(One, 'Alpha ru', 'Alpha', 'ru', 'Alpha series', 'prose_contemporary');
      One.AddBookToGroup(CreateBookKey(FirstBook, OneID), FAVORITES_GROUP_ID);
      One.AddBookToGroup(CreateBookKey(LastBook, OneID), FAVORITES_GROUP_ID);
      AddBook(One, 'Alpha extra uk', 'Alpha', 'uk', '', 'prose_contemporary');
      AddBook(One, 'Genre uk', 'Beta', 'uk', '', '0.1');
      AddBook(One, 'Genre ru', 'Beta', 'ru', '', '0.1');
      AddBook(One, 'Genre deleted', 'Beta', 'ru', '', '0.1', True);
      UnknownBook := AddBook(One, 'Unknown', 'Gamma', 'ru', '', '');
      AddBook(Two, 'Other uk', 'Other', 'uk', '', '0.1');
      AddBook(Two, 'Other ru', 'Other', 'ru', '', '0.1');
      if (ParamStr(1) = 'online-download') or (ParamStr(1) = 'online-plain') then
      begin
        Port := StrToIntDef(ParamStr(2), 0);
        Require((Port > 0) and (Port <= 65535), 'Online regression requires its loopback server port');
        CreateOnlineResponse;
        OnlineID := SystemDB.CreateCollection('Online regression', Settings.AppPath,
          'online.hlc2', CT_EXTERNAL_ONLINE_FB, Settings.AppPath + 'genres_fb2.glst');
        Online := SystemDB.GetCollection(OnlineID);
        Online.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
        Online.SetProperty(PROP_CONNECTIONSCRIPT, 'GET %URL%b/%LIBID%/get' + sLineBreak + 'CHECK');
        if ParamStr(1) = 'online-plain' then
          DirectBookID := AddOnlineBook(Online, 'Online plain', '900003', False)
        else
        begin
          DirectBookID := AddOnlineBook(Online, 'Online reader', '900001');
          QueueBookID := AddOnlineBook(Online, 'Online queue', '900002');
          RestartBookID := AddOnlineBook(Online, 'Online restart', '900004');
        end;
      end;
      if ParamStr(1) = 'publisher-selection' then
      begin
        TSeriesHelper.Add(PublisherSeries, 0, 'Fixture publisher', 1, False);
        One.SetBookPublisherSeries(CreateBookKey(FirstBook, OneID), PublisherSeries);
        PublisherSeries[0].SeqNumber := 2;
        One.SetBookPublisherSeries(CreateBookKey(LastBook, OneID), PublisherSeries);
        PublisherIterator := One.GetPublisherSeriesIterator;
        Require(PublisherIterator.Next(Publisher), 'Publisher fixture was not registered');
        One.SetProperty(PROP_LAST_PUBLISHER_SERIES, Publisher.SeriesID);
        One.SetProperty(PROP_LAST_PUBLISHER_BOOK, LastBook);
        One.SetProperty(PROP_PUBLISHER_LANG_FILTER, 2);
        PublisherIterator := nil;
      end;
      if ParamStr(1) = 'source-genres' then
      begin
        ImportedGenre := One.EnsureGenre('popadancy', 'Imported genre', 'Imported category');
        One.SetProperty(PROP_GENRE_FILE, 'genres_fb2_uk.glst');
      end;
      One.SetProperty(PROP_LAST_AUTHOR_BOOK, LastBook);
      if ParamStr(1) = 'language-isolation' then
        One.SetProperty(PROP_GENRES_LANG_FILTER, 0)
      else
        One.SetProperty(PROP_GENRES_LANG_FILTER, 2);
      One.SetProperty(PROP_SERIES_LANG_FILTER, 1);
      One.SetProperty(PROP_GROUPS_LANG_FILTER, 2);
      Two.SetProperty(PROP_GENRES_LANG_FILTER, 1);
      Settings.ActiveCollection := OneID;
      Settings.ActivePage := PAGE_AUTHORS;
      Trace('image module');
      Application.CreateForm(TdmImages, dmImages);
      dmImages.ApplyThemeIcons;
      Require(SystemDB.FindFirstExistingCollectionID(OneID) = OneID,
        'The registered fixture collection file is absent');
      Trace('main form');
      Application.CreateForm(TfrmMain, frmMain);
      TestHeaderMenuTags;
      Trace('genre form');
      Application.CreateForm(TfrmGenreTree, frmGenreTree);
      Trace('initial selection checks');
      ExpectTitles(frmMain.tvBooksA, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
      Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
      Require(Assigned(Book) and (Book.BookKey.BookID = LastBook),
        'The saved author book was not restored');
      Writeln('PASS default author selection and saved book');
      if ParamStr(1) = 'language-isolation' then
        TestLanguageIsolation
      else if ParamStr(1) = 'favorites-add' then
        TestAddBeforeFirstGroupVisit
      else if ParamStr(1) = 'genre-link' then
        TestGenreLink
      else if ParamStr(1) = 'genre-order' then
        TestGenreOrder(One, UnknownBook)
      else if ParamStr(1) = 'publisher-selection' then
        TestPublisherSelection(OneID, TwoID, LastBook)
      else if ParamStr(1) = 'reader-compatibility' then
        TestReaderCompatibility
      else if ParamStr(1) = 'read-folder-cleanup' then
        TestReadFolderCleanup
      else if ParamStr(1) = 'temp-exit-cleanup' then
        TestExitReaderCleanup
      else if ParamStr(1) = 'online-download' then
        TestOnlineDownload(Online, DirectBookID, QueueBookID, RestartBookID)
      else if ParamStr(1) = 'online-plain' then
        TestOnlinePlain(Online, DirectBookID)
      else if ParamStr(1) = 'source-genres' then
      begin
        TestSourceGenrePreservation(ImportedGenre);
        ChangeCollection(TwoID);
        ChangeCollection(OneID);
        TestSourceGenrePreservation(ImportedGenre);
      end
      else
      begin
        ChangeCollection(TwoID);
        Require(One.GetProperty(PROP_GENRES_LANG_FILTER) = 2,
          'Switching collections overwrote an unopened genre language filter');
        ChangeCollection(OneID);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
        Require(frmMain.cbLangSelectG.Text = 'ru', 'Saved genre language was not restored');
        Writeln('PASS unopened genre filter survives collection switches');
        ShowPage(PAGE_SERIES);
        ExpectTitles(frmMain.tvBooksS, ['Alpha uk']);
        Require(frmMain.cbLangSelectS.Text = 'uk', 'Saved series language was not restored');
        Writeln('PASS first series visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        frmMain.HideDeletedBooksExecute(nil);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS changed deletion filter refreshes previously visited views');
        ChangeCollection(TwoID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Other uk']);
        ChangeCollection(OneID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS visible genre view refreshes across collections');
        ShowPage(PAGE_FAVORITES);
        ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
        Require(frmMain.cbLangSelectF.Text = 'ru', 'Saved group language was not restored');
        Writeln('PASS first group visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        for I := 0 to frmMain.tbarAuthorsEng.ButtonCount - 1 do
          if frmMain.tbarAuthorsEng.Buttons[I].Caption = 'Z' then
            frmMain.tbarAuthorsEng.Buttons[I].OnClick(frmMain.tbarAuthorsEng.Buttons[I]);
        ExpectTitles(frmMain.tvBooksA, []);
        frmMain.HideDeletedBooksExecute(nil);
        ExpectTitles(frmMain.tvBooksA, []);
        Writeln('PASS empty author selection stays empty after a global refresh');
      end;
      frmGenreTree.Free;
      frmGenreTree := nil;
      frmMain.Free;
      frmMain := nil;
      if ParamStr(1) = 'temp-exit-cleanup' then CheckExitReaderCleanup;
      One := nil;
      Two := nil;
      Online := nil;
      dmImages.Free;
      dmImages := nil;
      DMUser.Free;
      DMUser := nil;
    finally
      frmSplash.Free;
      frmSplash := nil;
    end;
    Application.OnException := nil;
    ExceptionHandler.Free;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
      Halt(1);
    end;
  end;
end.
