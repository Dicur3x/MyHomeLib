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
  One, Two: IBookCollection;
  OneID, TwoID, FirstBook, LastBook, UnknownBook, I: Integer;
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
      One := nil;
      Two := nil;
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
      Halt(1);
    end;
  end;
end.
