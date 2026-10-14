// Native main-form favorite authors regression. Extra uses: unit_ReaderAnnotations.
// All catalogs, profile files and books must be an isolated G: fixture.
procedure TestFavoriteAuthorUI(const One: IBookCollection; OneID, TwoID: Integer);
var
  SearchCheck, ListCheck: TCheckBox;
  Heart, NewButton: TButton;
  StopItem, ViewedItem: TMenuItem;
  Store: TAuthorFavorites;
  ProfileFile, ReaderFile, NotesFile, BookFile, Key: string;
  BookHash, ReaderHash, NotesHash, CatalogBefore, OtherBefore, UserBefore: string;
  NewID, ExistingID, OriginalPPI, SearchHeight, SearchWidth: Integer;
  OriginalInfo: Boolean;

  function DumpTables(const FileName: string; const Tables: array of string): string;
  var DB: TSQLiteDatabase; Columns, Rows: TSQLiteQuery; Projection, Name, Value: string;
  begin
    Result := ''; DB := TSQLiteDatabase.CreateReadOnly(FileName);
    try
      for Name in Tables do
      begin
        Projection := '';
        Columns := DB.NewQuery('PRAGMA table_info("' + Name + '")');
        try
          Columns.Open;
          while not Columns.Eof do
          begin
            if Projection <> '' then Projection := Projection + ',';
            Projection := Projection + 'quote("' + Columns.FieldAsString(1) + '")';
            Columns.Next;
          end;
        finally Columns.Free; end;
        Require(Projection <> '', 'Favorite UI data oracle has no table: ' + Name);
        Result := Result + Name + #10;
        Rows := DB.NewQuery('SELECT ' + Projection + ' FROM "' + Name + '" ORDER BY rowid');
        try
          Rows.Open;
          while not Rows.Eof do
          begin
            for var Column := 0 to Rows.ColCount - 1 do
            begin
              Value := Rows.FieldAsString(Column);
              Result := Result + IntToStr(Length(Value)) + ':' + Value;
            end;
            Result := Result + #10; Rows.Next;
          end;
        finally Rows.Free; end;
      end;
    finally DB.Free; end;
  end;

  function CatalogData(CID: Integer): string;
  begin
    Result := DumpTables(SystemDB.GetCollectionInfo(CID).DBFileName,
      ['Books', 'Authors', 'Author_List', 'Series', 'Series_List', 'Genre_List']);
  end;

  procedure CheckProtected;
  begin
    Require(CatalogData(OneID) = CatalogBefore, 'Favorite UI changed source books, metadata, personal fields or relations');
    Require(CatalogData(TwoID) = OtherBefore, 'Favorite UI changed the other catalog');
    Require(DumpTables(Settings.SystemFileName[sfSystemDB], ['Books', 'BookGroups', 'Groups']) = UserBefore,
      'Favorite authors changed saved book cards or book-group membership');
    Require((THashSHA2.GetHashStringFromFile(BookFile) = BookHash) and
      (THashSHA2.GetHashStringFromFile(ReaderFile) = ReaderHash) and
      (THashSHA2.GetHashStringFromFile(NotesFile) = NotesHash),
      'Favorite UI changed book contents, reading positions/bookmarks or notes');
    Require(One.GetReview(CreateBookKey(ExistingID, OneID)) = 'Моя мысль — ё, ї, ў 😀',
      'Favorite UI lost a personal review');
  end;

  procedure WaitForRefresh;
  var Started: UInt64;
  begin
    Started := GetTickCount64;
    repeat
      Application.ProcessMessages;
      Require(GetTickCount64 - Started < 10000, 'Favorite background refresh did not finish');
      if not StopItem.Enabled then Break;
      TThread.Sleep(1);
    until False;
    Application.ProcessMessages;
  end;

  procedure ToggleList(Value: Boolean);
  begin
    ListCheck.Checked := Value;
    Require(Assigned(ListCheck.OnClick), 'Favorite list mode has no handler');
    ListCheck.OnClick(ListCheck);
  end;

  procedure SelectAuthor(const LastName: string);
  var Node: PVirtualNode; Data: PAuthorData;
  begin
    Node := frmMain.tvAuthors.GetFirst;
    while Assigned(Node) do
    begin
      Data := frmMain.tvAuthors.GetNodeData(Node);
      if Assigned(Data) and (Data^.LastName = LastName) then
      begin
        frmMain.tvAuthors.ClearSelection;
        frmMain.tvAuthors.Selected[Node] := True;
        frmMain.tvAuthors.FocusedNode := Node;
        frmMain.tvAuthorsChange(frmMain.tvAuthors, Node);
        Exit;
      end;
      Node := frmMain.tvAuthors.GetNext(Node);
    end;
    Require(False, 'Favorite UI author selector lost ' + LastName);
  end;

  procedure SelectAllAuthorNames;
  begin
    for var I := 0 to frmMain.tbarAuthorsRus.ButtonCount - 1 do
    begin
      var Button := frmMain.tbarAuthorsRus.Buttons[I];
      if Button.Caption = ALPHA_FILTER_ALL then
      begin
        Require(Assigned(Button.OnClick), 'All-author alphabet button has no handler');
        Button.OnClick(Button);
        Exit;
      end;
    end;
    Require(False, 'All-author alphabet button is absent');
  end;

  procedure ExpectAuthors(const Names: array of string);
  var Actual, Expected: TStringList; Node: PVirtualNode; Data: PAuthorData;
  begin
    Actual := TStringList.Create; Expected := TStringList.Create;
    try
      Node := frmMain.tvAuthors.GetFirst;
      while Assigned(Node) do
      begin
        Data := frmMain.tvAuthors.GetNodeData(Node);
        if Assigned(Data) then Actual.Add(Data^.LastName);
        Node := frmMain.tvAuthors.GetNext(Node);
      end;
      for var Name in Names do Expected.Add(Name);
      Actual.Sort; Expected.Sort;
      Require(Actual.Text = Expected.Text, 'Favorite author selector does not match complete cached author IDs');
    finally Expected.Free; Actual.Free; end;
  end;

  function ProfileState: TAuthorFavoriteState;
  begin
    Store.Reload; Result := Store.State(OneID, Key);
  end;

  procedure CheckInlineLayout;
  var Child: TControl; PPI, Margins: Integer;
  begin
    PPI := frmMain.edFFullName.Font.PixelsPerInch;
    Require((SearchCheck.Parent = frmMain.edFFullName) and
      (SearchCheck.Left >= 0) and (SearchCheck.Top >= 0) and
      (SearchCheck.Left + SearchCheck.Width <= frmMain.edFFullName.ClientWidth) and
      (SearchCheck.Top + SearchCheck.Height <= frmMain.edFFullName.ClientHeight),
      'Inline favorite checkbox escapes the author input at its actual DPI');
    Require(SearchCheck.Width >= MulDiv(16, PPI, 96), 'Favorite checkbox is not scaled with the actual input font DPI');
    for var I := 0 to frmMain.edFFullName.ControlCount - 1 do
    begin
      Child := frmMain.edFFullName.Controls[I];
      if (Child <> SearchCheck) and Child.Visible then
        Require(Child.Left + Child.Width <= SearchCheck.Left,
          'Favorite checkbox overlaps the existing expression button');
    end;
    Margins := SendMessage(frmMain.edFFullName.Handle, EM_GETMARGINS, 0, 0);
    Require(HiWord(Margins) >= SearchCheck.Width, 'Text can extend underneath the favorite checkbox');
  end;

begin
  RequireIsolatedRegression;
  Require((One.CollectionID = OneID) and (OneID <> TwoID), 'Favorite UI requires two isolated catalogs');
  SearchCheck := frmMain.FindComponent('cbSearchFavoriteAuthorsOnly') as TCheckBox;
  ListCheck := frmMain.FindComponent('cbFavoriteAuthorsList') as TCheckBox;
  Heart := frmMain.FindComponent('btnFavoriteSelectedAuthor') as TButton;
  NewButton := frmMain.FindComponent('btnFavoriteAuthorNew') as TButton;
  StopItem := frmMain.FindComponent('miFavoriteAuthorStop') as TMenuItem;
  ViewedItem := frmMain.FindComponent('miFavoriteAuthorViewed') as TMenuItem;
  Require(Assigned(SearchCheck) and Assigned(ListCheck) and Assigned(Heart) and Assigned(NewButton) and
    Assigned(StopItem) and Assigned(ViewedItem), 'Favorite author controls are missing');
  ProfileFile := TPath.Combine(Settings.DataPath, AUTHOR_FAVORITES_FILE_NAME);
  Require(not FileExists(ProfileFile), 'Fresh unused profile already contains favorite-author data');
  OriginalInfo := Settings.ShowInfoPanel; Settings.ShowInfoPanel := False;
  Store := nil;
  try
    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    SearchHeight := frmMain.ctpBook.Height; SearchWidth := frmMain.ctpBook.Width;
    StartSQLiteProfile;
    SearchCheck.Checked := True; Application.ProcessMessages;
    SearchCheck.Checked := False; Application.ProcessMessages;
    SaveSQLiteProfile(Settings.AppPath + 'favorite-checkbox-draft.tsv'); StopSQLiteProfile;
    {$IFDEF MHL_SQL_PROFILE}
    Require(not TFile.ReadAllText(Settings.AppPath + 'favorite-checkbox-draft.tsv').Contains('MHLGenreMatches'),
      'Draft favorite checkbox unexpectedly queried books before Apply');
    {$ENDIF}
    Require((frmMain.ctpBook.Height = SearchHeight) and (frmMain.ctpBook.Width = SearchWidth),
      'Favorite search control enlarged the search category');
    Require(not FileExists(ProfileFile), 'Draft favorite checkbox created a profile file');
    ExpectTitles(frmMain.tvBooksSR, []); CheckInlineLayout;
    SearchCheck.Checked := True; frmMain.DoApplyFilter(nil); WaitForRefresh;
    ExpectTitles(frmMain.tvBooksSR, []);
    Require(not FileExists(ProfileFile), 'Applying an empty favorite set created profile data or broadened the query');
    frmMain.DoClearFilter(False);

    ShowPage(PAGE_AUTHORS); SelectAuthor('Alpha');
    var Book: PBookRecord := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.GetFirstSelected);
    Require(Assigned(Book), 'Favorite UI fixture has no selected book'); ExistingID := Book^.BookKey.BookID;
    One.SetReview(CreateBookKey(ExistingID, OneID), 'Моя мысль — ё, ї, ў 😀');
    One.SetRate(CreateBookKey(ExistingID, OneID), 4); One.SetProgress(CreateBookKey(ExistingID, OneID), 37);
    BookFile := TPath.Combine(Settings.AppPath, 'favorite-source-protected.fb2');
    TFile.WriteAllText(BookFile, '<FictionBook>Исходная книга ё, ї, ў 😀</FictionBook>', TEncoding.UTF8);
    ReaderFile := TPath.Combine(Settings.DataPath, 'reader.ini');
    TFile.WriteAllText(ReaderFile, '[reader]' + sLineBreak + 'position=9876' + sLineBreak + 'bookmark=443', TEncoding.UTF8);
    var Notes := TReaderAnnotations.Create(ReaderFile);
    try
      var Note := Default(TReaderAnnotation);
      Note.BookID := 'favorite-ui-book'; Note.BookTitle := 'Исходная книга'; Note.Position := 9876;
      Note.Title := 'Сохранённая мысль'; Note.Text := 'Мои заметки — ё, ї, ў 😀'; Note.Quote := 'Исходный фрагмент';
      Notes.Put(Note);
    finally Notes.Free; end;
    NotesFile := TPath.Combine(Settings.DataPath, 'reader-notes.json');
    BookHash := THashSHA2.GetHashStringFromFile(BookFile); ReaderHash := THashSHA2.GetHashStringFromFile(ReaderFile);
    NotesHash := THashSHA2.GetHashStringFromFile(NotesFile);
    CatalogBefore := CatalogData(OneID); OtherBefore := CatalogData(TwoID);
    UserBefore := DumpTables(Settings.SystemFileName[sfSystemDB], ['Books', 'BookGroups', 'Groups']);

    Heart.Click; WaitForRefresh;
    Store := TAuthorFavorites.Create(ProfileFile); Key := AuthorFavoriteKey('Alpha', 'Alex', '');
    var State := ProfileState;
    Require(Store.IsFavorite('Alpha', 'Alex', '') and State.HasBaseline and
      (State.BookCount = 3) and (State.NewCount = 0), 'Adding a favorite failed to establish the existing-book baseline');
    ToggleList(True); WaitForRefresh; ExpectAuthors(['Alpha']); SelectAuthor('Alpha');
    Require(not SearchCheck.Checked, 'Authors favorite mode changed the independent search condition');
    ExpectTitles(frmMain.tvBooksA, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']); CheckProtected;
    Writeln('PASS favorite baseline, independent author selector and unchanged books, groups, positions and notes');

    ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
    SearchCheck.Checked := True; frmMain.edFTitle.Text := ''; frmMain.DoApplyFilter(nil); WaitForRefresh;
    ExpectTitles(frmMain.tvBooksSR, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
    frmMain.edFTitle.Text := '="Alpha ru"'; frmMain.DoApplyFilter(nil); WaitForRefresh;
    ExpectTitles(frmMain.tvBooksSR, ['Alpha ru']);
    frmMain.edFTitle.Text := ''; frmMain.DoApplyFilter(nil); WaitForRefresh;
    ExpectTitles(frmMain.tvBooksSR, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
    frmMain.edFTitle.Text := 'This draft must not be searched'; SearchCheck.Checked := False;
    frmMain.HideDeletedBooksExecute(nil);
    ExpectTitles(frmMain.tvBooksSR, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
    Require(frmMain.edFTitle.Text = 'This draft must not be searched', 'Favorite search reload consumed a draft title');
    SearchCheck.Checked := True; frmMain.edFTitle.Text := 'Alpha';
    frmMain.cbPresetName.Text := 'Любимые авторы — пресет'; frmMain.SaveSearchPreset(nil);
    var Presets := TSearchPresets.Create;
    try
      Presets.Load(Settings.SystemFileName[sfPresets]);
      Require(StrToBoolDef(Presets.GetPreset('Любимые авторы — пресет').Items[SF_FAVORITE_AUTHORS], False),
        'Favorite search preset did not survive compressed XML reopen');
    finally Presets.Free; end;
    frmMain.DoClearFilter(False); Require(not SearchCheck.Checked, 'Clear kept the favorite search draft');
    frmMain.cbPresetName.Text := 'Любимые авторы — пресет'; frmMain.cbPresetNameSelect(nil);
    Require(SearchCheck.Checked, 'Preset selection lost the favorite condition'); ExpectTitles(frmMain.tvBooksSR, []);
    frmMain.DoApplyFilter(nil); WaitForRefresh;
    ExpectTitles(frmMain.tvBooksSR, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']); CheckProtected;
    Writeln('PASS favorite search intersects explicit criteria, preserves drafts and reopens presets without automatic queries');

    NewID := AddBook(One, 'Alpha newest ru', 'Alpha', 'ru', '', 'prose_contemporary');
    Require(NewID > 0, 'New favorite fixture book was not committed'); CatalogBefore := CatalogData(OneID);
    frmMain.NotifyFavoriteCatalogChanged(TArray<Integer>.Create(OneID, OneID, TwoID));
    ChangeCollection(TwoID); ShowPage(PAGE_AUTHORS); WaitForRefresh;
    ExpectAuthors([]); ExpectTitles(frmMain.tvBooksA, []);
    ChangeCollection(OneID); ShowPage(PAGE_AUTHORS); WaitForRefresh; SelectAuthor('Alpha');
    State := ProfileState; Require((State.BookCount = 4) and (State.NewCount = 1), 'Committed new book was not counted after switching collections');
    Require(NewButton.Enabled and (NewButton.Caption = '+1'), 'Cached new-book badge is missing');
    var SameRevision := Store.CollectionRevision(OneID);
    frmMain.NotifyFavoriteCatalogChanged(TArray<Integer>.Create(OneID));
    Require(StopItem.Enabled, 'A known commit with an unchanged file stamp was not scheduled');
    WaitForRefresh; Store.Reload;
    Require((Store.CollectionRevision(OneID) = SameRevision) and (ProfileState.NewCount = 1),
      'Repeated file revision skipped the known commit or changed the new-book baseline');
    NewButton.Click; ExpectTitles(frmMain.tvBooksA, ['Alpha newest ru']);
    Require(ProfileState.NewCount = 1, 'Selecting a new book silently marked it viewed');
    Require(ViewedItem.Enabled, 'Explicit mark-viewed action is unavailable'); ViewedItem.Click;
    Require(ProfileState.NewCount = 0, 'Explicit mark-viewed action failed'); ExpectTitles(frmMain.tvBooksA, []);
    NewButton.Click; ExpectTitles(frmMain.tvBooksA, ['Alpha uk', 'Alpha ru', 'Alpha extra uk', 'Alpha newest ru']);
    // Collection switching restores the ordinary saved A/Alpha alphabet
    // scope. Turning off favorites must retain that scope; explicitly choose
    // all names before asking the selector for Beta.
    ToggleList(False); SelectAllAuthorNames; ExpectAuthors(['Alpha', 'Beta', 'Gamma']);
    SelectAuthor('Alpha'); NewButton.Click; ExpectTitles(frmMain.tvBooksA, []);
    SelectAuthor('Beta');
    if Settings.HideDeletedBooks then ExpectTitles(frmMain.tvBooksA, ['Genre uk', 'Genre ru'])
    else ExpectTitles(frmMain.tvBooksA, ['Genre uk', 'Genre ru', 'Genre deleted']);
    Require(not NewButton.Enabled, 'Nonfavorite author inherited a stale only-new mode');
    SelectAuthor('Alpha'); ToggleList(True); WaitForRefresh; CheckProtected;
    Writeln('PASS known commits refresh cached new-book IDs across collection switches and only explicit action marks them viewed');

    ShowPage(PAGE_AUTHORS); SelectAuthor('Alpha');
    var Filters := TBookColumnFilters.ForTree(frmMain.tvBooksA);
    Filters.FavoriteAuthorsOnly := True; Require(Filters.Apply(False) = 4, 'Loaded favorite column filter has stale keys');
    Heart.Click; WaitForRefresh;
    Store.Reload; Require(not Store.IsFavorite('Alpha', 'Alex', ''), 'Removing the favorite failed');
    Require(Filters.Apply(False) = 0, 'Favorite removal did not refresh the already-loaded column filter');
    ToggleList(False); Filters.Clear; Filters.Apply(False); SelectAuthor('Alpha'); Heart.Click; WaitForRefresh;
    Store.Reload; Require(Store.IsFavorite('Alpha', 'Alex', ''), 'Favorite re-add failed');
    Require(ProfileState.NewCount = 0, 'Re-add mislabeled the existing book baseline as new'); CheckProtected;
    frmMain.NotifyFavoriteCatalogChanged(TArray<Integer>.Create(OneID, TwoID));
    Require(StopItem.Enabled, 'Queued refresh has no visible cancellation action'); StopItem.Click;
    Require(not StopItem.Enabled, 'Cancellation left a stale worker action');
    Store.Reload; Require(Store.IsFavorite('Alpha', 'Alex', '') and ProfileState.HasBaseline,
      'Cancellation damaged the last complete favorite profile');
    CheckProtected;
    Writeln('PASS favorite removal refreshes loaded filters, re-add preserves baseline, cancellation retains complete profile data');

    // Corrupt catalog names must not escape favorite lookups during painting
    // or selection. This mutates only an in-memory row and restores it.
    ShowPage(PAGE_AUTHORS); SelectAuthor('Alpha');
    var AuthorNode := frmMain.tvAuthors.GetFirstSelected;
    var AuthorData: PAuthorData := frmMain.tvAuthors.GetNodeData(AuthorNode);
    Require(Assigned(AuthorData), 'Malformed author fixture has no row');
    var SavedAuthor := AuthorData^;
    try
      for var BadName in TArray<string>.Create(StringOfChar('x', 2049), 'Alpha' + #0 + 'bad') do
      begin
        AuthorData^.LastName := BadName;
        var Text := '';
        frmMain.tvAuthors.OnGetText(frmMain.tvAuthors, AuthorNode, 0, ttNormal, Text);
        frmMain.tvAuthorsChange(frmMain.tvAuthors, AuthorNode);
        Require(not Heart.Enabled, 'Malformed author remains eligible for favorite mutation');
      end;
    finally
      AuthorData^ := SavedAuthor;
      frmMain.tvAuthorsChange(frmMain.tvAuthors, AuthorNode);
    end;
    CheckProtected;
    Writeln('PASS malformed long/NUL author names keep ordinary rendering and selection usable without changing profile or catalogs');

    ShowPage(PAGE_SEARCH); OriginalPPI := frmMain.CurrentPPI;
    for var DPI in TArray<Integer>.Create(96, 144, 192) do
    begin
      frmMain.ScaleForPPI(DPI); frmMain.FormAfterMonitorDpiChanged(nil, OriginalPPI, DPI);
      Application.ProcessMessages; CheckInlineLayout;
      SearchHeight := frmMain.ctpBook.Height; SearchWidth := frmMain.ctpBook.Width;
      SearchCheck.Checked := not SearchCheck.Checked; Application.ProcessMessages;
      Require((frmMain.ctpBook.Height = SearchHeight) and (frmMain.ctpBook.Width = SearchWidth),
        'Favorite checkbox enlarged search at DPI ' + IntToStr(DPI));
    end;
    frmMain.ScaleForPPI(96); frmMain.FormAfterMonitorDpiChanged(nil, OriginalPPI, 96); Application.ProcessMessages;
    CheckProtected;
    Writeln('PASS inline favorite condition fits actual 100%, 150%, 200% DPI without covering expression controls or expanding search');
    Flush(Output);
  finally
    Store.Free; Settings.ShowInfoPanel := OriginalInfo;
  end;
end;
