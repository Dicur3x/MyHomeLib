// Existing AuthorInitials option, actual Main menus/selection/search and raw DAO.
// Include after AddBook/ShowPage; no additional units beyond the native harness.
procedure TestAuthorDisplaySetting;
type
  TNameCase = record LastName, FirstName, MiddleName, FullName, Initials: string; end;
const
  Names: array[0..10] of TNameCase = (
    (LastName:'Ёлкин'; FirstName:'Семён'; MiddleName:'Фёдорович'; FullName:'Ёлкин Семён Фёдорович'; Initials:'Ёлкин С. Ф.'),
    (LastName:'Салтыков-Щедрин'; FirstName:'Михаил'; MiddleName:'Евграфович'; FullName:'Салтыков-Щедрин Михаил Евграфович'; Initials:'Салтыков-Щедрин М. Е.'),
    (LastName:'де Сент-Экзюпери'; FirstName:'Антуан'; MiddleName:''; FullName:'де Сент-Экзюпери Антуан'; Initials:'де Сент-Экзюпери А.'),
    (LastName:'ван дер Ваальс'; FirstName:'Йоханнес Дидерик'; MiddleName:''; FullName:'ван дер Ваальс Йоханнес Дидерик'; Initials:'ван дер Ваальс Й.'),
    (LastName:'O''Коннор'; FirstName:'Анна-Мария'; MiddleName:'Жанна Луиза'; FullName:'O''Коннор Анна-Мария Жанна Луиза'; Initials:'O''Коннор А. Ж.'),
    (LastName:'Платон'; FirstName:''; MiddleName:''; FullName:'Платон'; Initials:'Платон'),
    (LastName:'Неполный'; FirstName:''; MiddleName:'Ильич'; FullName:'Неполный Ильич'; Initials:'Неполный И.'),
    (LastName:''; FirstName:'Иван'; MiddleName:''; FullName:'Неизвестный Иван'; Initials:'Неизвестный И.'),
    (LastName:'ТОЛСТОЙ'; FirstName:'ЛЕВ'; MiddleName:'НИКОЛАЕВИЧ'; FullName:'ТОЛСТОЙ ЛЕВ НИКОЛАЕВИЧ'; Initials:'ТОЛСТОЙ Л. Н.'),
    (LastName:'Литератор "Ёж"'; FirstName:'Пётр'; MiddleName:''; FullName:'Литератор "Ёж" Пётр'; Initials:'Литератор "Ёж" П.'),
    (LastName:'Каталог %_! LIKE "Ёж" O''Connor'; FirstName:'Имя'; MiddleName:''; FullName:'Каталог %_! LIKE "Ёж" O''Connor Имя'; Initials:'Каталог %_! LIKE "Ёж" O''Connor И.'));
var
  Collection: IBookCollection;
  CID, SavedCID: Integer;
  BookIDs, AuthorIDs: TArray<Integer>;
  Book: TBookRecord;
  Node: PVirtualNode;
  Author: PAuthorData;
  Menu, Toggle, FavoriteToggle: TMenuItem;
  Control: TSearchQueryModeControl;
  SavedInitials: Boolean;
  SavedMode: TSearchQueryMode;
  BeforeRows, BeforeOrder, Display, Wanted, Expression: string;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;

  function BookTitle(Index: Integer): string;
  begin Result := 'Author display case ' + IntToStr(Index); end;

  function RawAuthorRows: string;
  var DB: TSQLiteDatabase; Query: TSQLiteQuery;
  begin
    Result := '';
    DB := TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(CID).DBFileName);
    try
      Query := DB.NewQuery('SELECT AuthorID,quote(LastName),quote(FirstName),quote(MiddleName),quote(SearchName) FROM Authors ORDER BY AuthorID');
      try
        Query.Open;
        while not Query.Eof do
        begin
          for var I := 0 to Query.ColCount - 1 do Result := Result + Query.FieldAsString(I) + #1;
          Result := Result + #10; Query.Next;
        end;
      finally Query.Free; end;
    finally DB.Free; end;
  end;

  procedure AllAuthors;
  begin
    ShowPage(PAGE_AUTHORS);
    for var I := 0 to frmMain.tbarAuthorsRus.ButtonCount - 1 do
      if frmMain.tbarAuthorsRus.Buttons[I].Caption = '*' then
      begin
        frmMain.tbarAuthorsRus.Buttons[I].OnClick(frmMain.tbarAuthorsRus.Buttons[I]);
        Exit;
      end;
    Require(False, 'All-authors toolbar action is missing');
  end;

  function Order: string;
  var Item: PVirtualNode; Value: PAuthorData;
  begin
    Result := ''; Item := frmMain.tvAuthors.GetFirst;
    while Assigned(Item) do
    begin
      Value := frmMain.tvAuthors.GetNodeData(Item);
      Result := Result + IntToStr(Value^.AuthorID) + ':' + Value^.GetFullName + #10;
      Item := frmMain.tvAuthors.GetNext(Item);
    end;
  end;

  procedure SelectAuthor(Index: Integer);
  begin
    AllAuthors;
    Node := frmMain.tvAuthors.GetFirst;
    while Assigned(Node) do
    begin
      Author := frmMain.tvAuthors.GetNodeData(Node);
      if Author^.AuthorID = AuthorIDs[Index] then Break;
      Node := frmMain.tvAuthors.GetNext(Node);
    end;
    Require(Assigned(Node), 'Author display fixture lost its raw ID');
    frmMain.tvAuthors.ClearSelection;
    frmMain.tvAuthors.Selected[Node] := True; frmMain.tvAuthors.FocusedNode := Node;
    frmMain.tvAuthorsChange(frmMain.tvAuthors, Node);
    Require((Author^.GetFullName = Names[Index].FullName) and
      (frmMain.lblAuthor.Caption = Names[Index].FullName), 'Selection changed the source full name');
    ExpectTitles(frmMain.tvBooksA, [BookTitle(Index)]);
  end;

  procedure ApplyAndExpect(const Expected: array of string);
  begin
    ShowPage(PAGE_SEARCH); frmMain.DoApplyFilter(nil);
    ExpectTitles(frmMain.tvBooksSR, Expected);
  end;

begin
  RequireIsolatedRegression;
  SavedCID := Settings.ActiveCollection; SavedInitials := Settings.AuthorInitials;
  Control := frmMain.FindComponent('SearchQueryModeControl') as TSearchQueryModeControl;
  Require(Assigned(Control), 'Author workflow requires the actual search mode control');
  SavedMode := Control.Mode;
  CID := SystemDB.CreateCollection('Author display independent fixture', Settings.AppPath,
    'author-display-fixture.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  SetLength(BookIDs, Length(Names)); SetLength(AuthorIDs, Length(Names));
  for var I := 0 to High(Names) do
  begin
    Book.Clear; Book.Title := BookTitle(I); Book.FileName := 'author-case-' + IntToStr(I);
    Book.FileExt := '.fb2'; Book.LibID := 'author-display-' + IntToStr(I);
    Book.Lang := 'ru'; Book.Size := 100; Book.Date := EncodeDate(2020, 1, 1);
    Include(Book.BookProps, bpIsLocal);
    TAuthorsHelper.Add(Book.Authors, Names[I].LastName, Names[I].FirstName, Names[I].MiddleName);
    BookIDs[I] := Collection.InsertBook(Book, False, False);
    Collection.GetBookRecord(CreateBookKey(BookIDs[I], CID), Book, True);
    Require((Length(Book.Authors) = 1) and (Book.Authors[0].GetFullName = Names[I].FullName),
      'Independent author fixture normalized unexpectedly');
    AuthorIDs[I] := Book.Authors[0].AuthorID;
    Require(TAuthorsHelper.GetLinkList(Book.Authors).Contains('>' + Names[I].Initials + '</a>'),
      'Expected initials disagree with the existing information-card formatter');
  end;
  BeforeRows := RawAuthorRows;
  Menu := TMenuItem.Create(nil);
  try
    Menu.Tag := CID; frmMain.miActiveCollectionClick(Menu);
    Toggle := frmMain.FindComponent('miAuthorInitials') as TMenuItem;
    FavoriteToggle := frmMain.FindComponent('miAuthorInitialsFavorite') as TMenuItem;
    Require(Assigned(Toggle) and Assigned(FavoriteToggle), 'Existing author display menus are missing');
    for var Initials in TArray<Boolean>.Create(False, True) do
    begin
      AllAuthors; BeforeOrder := Order;
      if Settings.AuthorInitials <> Initials then Toggle.OnClick(Toggle);
      Require((Toggle.Checked = Initials) and (FavoriteToggle.Checked = Initials) and
        (Order = BeforeOrder), 'Display toggle changed author ordering or the paired menu state');
      Settings.SaveSettings; Settings.LoadSettings;
      Require(Settings.AuthorInitials = Initials, 'Author display choice did not survive profile reload');
      for var I := 0 to High(Names) do
      begin
        SelectAuthor(I);
        Display := ''; frmMain.tvAuthors.OnGetText(frmMain.tvAuthors, Node, 0, ttNormal, Display);
        if Initials then Wanted := Names[I].Initials else Wanted := Names[I].FullName;
        Require((Display = Wanted) and (Author^.AuthorID = AuthorIDs[I]) and
          (Author^.GetFullName = Names[I].FullName), 'Display setting changed initials, raw fields or selected ID');
        frmMain.edLocateAuthor.Text := Names[I].FullName; frmMain.tmrSearchATimer(nil);
        Author := frmMain.tvAuthors.GetNodeData(frmMain.tvAuthors.FocusedNode);
        Require(Assigned(Author) and (Author^.AuthorID = AuthorIDs[I]), 'Initials prevented locating the original full author');
        frmMain.DoClearFilter(False); Control.Reset;
        frmMain.miAddToSearchClick(nil);
        Expression := '="' + StringReplace(Names[I].FullName, '"', '""', [rfReplaceAll]) + '"';
        Require((frmMain.edFFullName.Text = Expression) and (Control.Mode = sqmExpression),
          'Actual Add to Search copied initials, unescaped quotes or left ordinary-text mode');
        ApplyAndExpect([BookTitle(I)]);
      end;
      Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
      Criteria.QueryMode := sqmExpression; Criteria.FullName := '="Елкин Семен Федорович"';
      Iterator := Collection.Search(Criteria, False);
      Require((Iterator.RecordCount = 1) and Iterator.Next(Book) and (Book.BookKey.BookID = BookIDs[0]),
        'Author display mode changed Cyrillic e/yo catalog search');
      Iterator := nil;
      Require(RawAuthorRows = BeforeRows, 'Display/search changed original author fields, IDs or search index');
    end;

    SelectAuthor(0); frmMain.DoClearFilter(False); Control.Mode := sqmText;
    frmMain.edFFullName.Text := Names[10].LastName;
    frmMain.miAddToSearchClick(nil);
    Require(Control.Mode = sqmExpression, 'Literal draft did not switch to a valid generated condition');
    ApplyAndExpect([BookTitle(0), BookTitle(10)]);
    SelectAuthor(4); frmMain.DoClearFilter(False); Control.Mode := sqmLegacy;
    frmMain.edFFullName.Text := 'Ёлкин'; frmMain.miAddToSearchClick(nil);
    ApplyAndExpect([BookTitle(0), BookTitle(4)]);
    SelectAuthor(9); frmMain.DoClearFilter(False); Control.Mode := sqmExpression;
    frmMain.edFFullName.Text := '="Ёлкин Семён Фёдорович" AND NOT LIKE "%ненужное%"';
    frmMain.miAddToSearchClick(nil);
    ApplyAndExpect([BookTitle(0), BookTitle(9)]);
    Require(RawAuthorRows = BeforeRows, 'Generated OR conditions changed source author data');
  finally
    Iterator := nil;
    if Settings.AuthorInitials <> SavedInitials then
    begin
      Toggle := frmMain.FindComponent('miAuthorInitials') as TMenuItem;
      if Assigned(Toggle) then Toggle.OnClick(Toggle);
    end;
    Menu.Tag := SavedCID; frmMain.miActiveCollectionClick(Menu); Menu.Free;
    frmMain.DoClearFilter(False); Control.Mode := SavedMode;
    Settings.SaveSettings;
    Collection := nil;
  end;
  Writeln('PASS existing author initials/full-name menus preserve eleven Unicode/compound/incomplete names, card formatting, IDs, raw locate/search and profile choice');
  Writeln('PASS actual Add to Search preserves literal, legacy and expression drafts, escaped author quotes/apostrophes and generated OR mode');
end;
