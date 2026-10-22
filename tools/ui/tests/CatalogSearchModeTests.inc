// DPR uses: unit_SearchQueryModeControl. Run after the ordinary tiny fixture setup.
procedure TestCatalogSearchModes(const One: IBookCollection);
var
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  Book: TBookRecord;
  Presets, Reloaded: TSearchPresets;
  Control: TSearchQueryModeControl;
  FileName, BeforeHash: string;
  CountBefore, A, B, C, Books, Authors, Series: Integer;
  procedure AddModeBook(const Title: string; Year: Integer);
  var ID: Integer; Value: TBookRecord;
  begin
    ID := AddBook(One, Title, 'Query modes', 'ru', '', '0.1');
    One.GetBookRecord(CreateBookKey(ID, One.CollectionID), Value, True);
    Value.PubYear := Year;
    Value.LibRate := 4;
    if Year = 2024 then
    begin Value.FileName := 'путь ЁЛКА *? [abc] 100% _ O''Reilly 😀'; Value.FileExt := '.fb2'; end
    else if Year = 2023 then
    begin Value.FileName := 'ordinary_file'; Value.FileExt := '.pdf'; end
    else
    begin Value.FileName := Copy(Title, 10, MaxInt); Value.FileExt := '.epub'; end;
    One.UpdateBook(Value);
  end;
  function CountFile(const Name, Ext: string; Mode: TSearchQueryMode): Integer;
  begin
    Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
    if Mode = sqmText then Criteria.Title := 'Proposal'
    else Criteria.Title := 'LIKE "%Proposal%"';
    Criteria.FileName := Name; Criteria.FileExt := Ext;
    Criteria.QueryMode := Mode; Criteria.CollapseMultiSeriesResults := True;
    Iterator := One.Search(Criteria, False);
    Result := Iterator.RecordCount;
    while Iterator.Next(Book) do Require(Book.BookKey.DatabaseID = One.CollectionID,
      'File filter crossed a collection boundary');
    Iterator := nil;
  end;
  function Count(const Query: string; Mode: TSearchQueryMode): Integer;
  begin
    Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
    Criteria.Title := Query; Criteria.QueryMode := Mode;
    Criteria.CollapseMultiSeriesResults := True;
    Iterator := One.Search(Criteria, False);
    Result := Iterator.RecordCount;
    while Iterator.Next(Book) do Require(Book.BookKey.DatabaseID = One.CollectionID,
      'Query mode crossed a collection boundary');
    Iterator := nil;
  end;
begin
  RequireIsolatedRegression;
  Control := TSearchQueryModeControl(frmMain.FindComponent('SearchQueryModeControl'));
  Require(Assigned(Control) and (Control.Mode = sqmText), 'Fresh Main search must use ordinary text');
  One.GetStatistics(Authors, CountBefore, Series);
  AddModeBook('Proposal I LIKE SQL 100% _ "quotes" O''Reilly != ё *? [abc] ] ^ titlematch. 😀', 2024);
  AddModeBook('Proposal ordinary title', 2023);
  AddModeBook('Proposal ёлка', 0);
  AddModeBook('Proposal елка', 0);
  Require(Count('I LIKE SQL', sqmText) = 1, 'Ordinary LIKE text became syntax');
  Require(Count('%', sqmText) = 1, 'Ordinary percent became a wildcard');
  Require(Count('_', sqmText) = 1, 'Ordinary underscore became a wildcard');
  Require(Count('"quotes"', sqmText) = 1, 'Ordinary quotes became SQL syntax');
  Require(Count('O''Reilly !=', sqmText) = 1, 'Ordinary apostrophe or equality text became SQL');
  Require(Count('foo'' OR 1=1 --', sqmText) = 0, 'Ordinary text changed SQL meaning');
  Require(Count('  proposal ЕЛКА  ', sqmText) = 2, 'Ordinary Unicode e/yo or trim matching changed');
  Require(Count('Proposal ёлка', sqmText) = 2, 'Ordinary yo query lost plain-e spelling');
  Require(Count('*?', sqmText) = 1, 'Ordinary glob star/question became wildcards');
  Require(Count('[abc]', sqmText) = 1, 'Ordinary brackets became a character class');
  Require(Count('[other]', sqmText) = 0, 'Ordinary bracket expression matched unrelated titles');
  Require(Count(']', sqmText) = 1, 'Closing bracket lost its literal meaning');
  Require(Count('^', sqmText) = 1, 'Caret lost its literal meaning');
  Require(Count('titlematch.', sqmText) = 1, 'Title-only optimization rewrote text resembling an alias');
  Require(Count('😀', sqmText) = 1, 'Title pattern split a Unicode surrogate pair');
  Require(CountFile('елка', '', sqmText) = 3, 'File-name index lost e/yo equivalence');
  Require(CountFile('  ЁЛКА  ', '.FB2', sqmText) = 1, 'Combined ordinary file filters lost trim/case/e-yo matching');
  Require(CountFile('*?', '', sqmText) = 1, 'File-name glob symbols became wildcards');
  Require(CountFile('[abc]', '', sqmText) = 1, 'File-name brackets became a character class');
  Require(CountFile('[other]', '', sqmText) = 0, 'File-name bracket pattern matched unrelated names');
  Require(CountFile('100% _ O''Reilly', '', sqmText) = 1, 'File-name SQL metacharacters lost literal meaning');
  Require(CountFile('😀', '', sqmText) = 1, 'File-name pattern split a Unicode surrogate pair');
  Require(CountFile('foo'' OR 1=1 --', '', sqmText) = 0, 'File-name text changed SQL meaning');
  Require(CountFile('', '.pDf', sqmText) = 1, 'Extension filter lost case-insensitive matching');
  Require(CountFile('', '*', sqmText) = 0, 'Ordinary extension wildcard became syntax');
  Require(CountFile('', '%', sqmText) = 0, 'Ordinary extension percent became a wildcard');
  Require(CountFile('', '=".pdf" OR =".epub"', sqmExpression) = 3, 'Expression extension OR changed');
  Require(CountFile('', '=".pdf" OR =".epub"', sqmLegacy) = 3, 'Legacy extension OR changed');
  Require(Count('="Proposal ordinary title" OR ="Proposal ёлка"', sqmExpression) = 3,
    'Explicit expression mode lost OR/exact conditions');
  Require(Count('="Proposal ordinary title" OR ="Proposal ёлка"', sqmLegacy) = 3,
    'Default legacy mode changed old expression meaning');
  Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
  Criteria.Title := 'Proposal'; Criteria.QueryMode := sqmText;
  Criteria.Lang := '="ru"'; Criteria.LibRate := '>= 4'; Criteria.PubYear := '>= 2020';
  Iterator := One.Search(Criteria, False); A := Iterator.RecordCount; Iterator := nil;
  Criteria.Title := 'LIKE "%Proposal%"'; Criteria.QueryMode := sqmExpression;
  Iterator := One.Search(Criteria, False); B := Iterator.RecordCount; Iterator := nil;
  Criteria.QueryMode := sqmLegacy;
  Iterator := One.Search(Criteria, False); C := Iterator.RecordCount; Iterator := nil;
  // An unknown publication year is SQL NULL, not zero; only the two books
  // with explicit years satisfy this condition in every mode.
  Require((A = 2) and (A = B) and (B = C), Format(
    'Query mode unexpectedly changed numeric/year/language rules: text=%d expression=%d legacy=%d', [A, B, C]));
  One.GetStatistics(Authors, Books, Series);
  Require(Books = CountBefore + 4, 'Read-only query modes changed the catalog');

  FileName := Settings.AppPath + 'proposal-search-modes.xml';
  Presets := TSearchPresets.Create; Reloaded := TSearchPresets.Create;
  try
    Presets.GetPreset('старый').AddOrSetValue(SF_TITLE, '="Proposal ordinary title"');
    Presets.GetPreset('обычный').QueryMode := sqmText;
    Presets.GetPreset('обычный').AddOrSetValue(SF_TITLE, '100% _ O''Reilly');
    Presets.GetPreset('условия').QueryMode := sqmExpression;
    Presets.GetPreset('условия').AddOrSetValue(SF_TITLE, '="one" OR ="two"');
    Presets.Save(FileName); BeforeHash := THashSHA2.GetHashStringFromFile(FileName);
    Reloaded.GetPreset('старый').QueryMode := sqmText;
    Reloaded.Load(FileName);
    Require((Reloaded.GetPreset('старый').QueryMode = sqmLegacy) and
      (Reloaded.GetPreset('обычный').QueryMode = sqmText) and
      (Reloaded.GetPreset('условия').QueryMode = sqmExpression), 'Preset load inherited or lost mode');
    Require(THashSHA2.GetHashStringFromFile(FileName) = BeforeHash, 'Loading search modes rewrote source presets');
    Control.LoadPreset(Reloaded.GetPreset('старый'));
    Require((Control.Mode = sqmLegacy) and (Control.Combo.Items.Count = 3), 'Old preset mode is not visible');
    Control.SavePreset(Reloaded.GetPreset('старый'));
    Reloaded.Save(Settings.AppPath + 'proposal-search-roundtrip.cxml2');
    Presets.Clear; Presets.Load(Settings.AppPath + 'proposal-search-roundtrip.cxml2');
    Require((Presets.GetPreset('старый').QueryMode = sqmLegacy) and
      (Presets.GetPreset('обычный').QueryMode = sqmText) and
      (Presets.GetPreset('условия').QueryMode = sqmExpression), 'Round-trip preset mode changed meaning');
    Control.Reset;
    Require((Control.Mode = sqmText) and (Control.Combo.Items.Count = 2), 'Clear did not restore ordinary text');
    Control.Mode := sqmExpression; Control.ApplyTo(Criteria);
    Require(Criteria.QueryMode = sqmExpression, 'Mode control did not write the applied criteria');
    Control.Reset;
  finally Reloaded.Free; Presets.Free; end;
  Writeln('PASS proposal search modes literal SQL metacharacters, Unicode, explicit OR, numeric invariants and old/new preset round-trips');
  Writeln('PASS indexed ordinary file-name and extension filters preserve literals, combined criteria and legacy expressions');
end;
