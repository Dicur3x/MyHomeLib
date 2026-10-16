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
  AddBook(One, 'Proposal I LIKE SQL 100% _ "quotes" O''Reilly != ё', 'Query modes', 'ru', '', '0.1');
  AddBook(One, 'Proposal ordinary title', 'Query modes', 'ru', '', '0.1');
  AddBook(One, 'Proposal ёлка', 'Query modes', 'ru', '', '0.1');
  Require(Count('I LIKE SQL', sqmText) = 1, 'Ordinary LIKE text became syntax');
  Require(Count('%', sqmText) = 1, 'Ordinary percent became a wildcard');
  Require(Count('_', sqmText) = 1, 'Ordinary underscore became a wildcard');
  Require(Count('"quotes"', sqmText) = 1, 'Ordinary quotes became SQL syntax');
  Require(Count('O''Reilly !=', sqmText) = 1, 'Ordinary apostrophe or equality text became SQL');
  Require(Count('foo'' OR 1=1 --', sqmText) = 0, 'Ordinary text changed SQL meaning');
  Require(Count('Proposal елка', sqmText) = 1, 'Ordinary Unicode e/yo matching changed');
  Require(Count('="Proposal ordinary title" OR ="Proposal ёлка"', sqmExpression) = 2,
    'Explicit expression mode lost OR/exact conditions');
  Require(Count('="Proposal ordinary title" OR ="Proposal ёлка"', sqmLegacy) = 2,
    'Default legacy mode changed old expression meaning');
  Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
  Criteria.Title := 'Proposal'; Criteria.QueryMode := sqmText;
  Criteria.Lang := '="ru"'; Criteria.LibRate := '>= 0'; Criteria.PubYear := '>= 0';
  Iterator := One.Search(Criteria, False); A := Iterator.RecordCount; Iterator := nil;
  Criteria.Title := 'LIKE "%Proposal%"'; Criteria.QueryMode := sqmExpression;
  Iterator := One.Search(Criteria, False); B := Iterator.RecordCount; Iterator := nil;
  Criteria.QueryMode := sqmLegacy;
  Iterator := One.Search(Criteria, False); C := Iterator.RecordCount; Iterator := nil;
  Require((A = 3) and (A = B) and (B = C), 'Query mode unexpectedly changed numeric/year/language rules');
  One.GetStatistics(Authors, Books, Series);
  Require(Books = CountBefore + 3, 'Read-only query modes changed the catalog');

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
end;
