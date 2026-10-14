// Exercise publisher filtering on loaded metadata, without changing the catalog.
procedure TestPublisherColumnFilters;
var
  Tree: TBookTree;
  Filters: TBookColumnFilters;
  Nodes: TArray<PVirtualNode>;
  Node: PVirtualNode;
  Book: PBookRecord;
  Names, Chosen: TStringList;
  PublisherMenu: TMenuItem;
  ColumnIndex, CompareResult: Integer;
  Text, LayoutFile: string;
  Columns, Reloaded: TColumns;
  Found: Boolean;
begin
  RequireIsolatedRegression;
  Tree := frmMain.tvBooksA;
  Filters := TBookColumnFilters.ForTree(Tree);
  Nodes := nil;
  Names := TStringList.Create;
  Chosen := TStringList.Create;
  Columns := nil;
  Reloaded := nil;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book := Tree.GetNodeData(Node);
      if Book.NodeType = ntBookInfo then
      begin
        Nodes := Nodes + [Node];
        if Book.Title = 'Alpha ru' then Book.Publisher := 'Ёлка Пресс'
        else if Book.Title = 'Alpha uk' then Book.Publisher := 'елка пресс'
        else Book.Publisher := '';
      end;
      Node := Tree.GetNext(Node);
    end;
    Require(Length(Nodes) = 3, 'Publisher column fixture requires three loaded books');
    Filters.Clear;
    Filters.SetValue(COL_PUBLISHER, 'ЕЛКА');
    Require(Filters.Apply(False) = 2, 'Publisher contains filter lost case or е/ё variants');
    Filters.SetCaseSensitive(COL_PUBLISHER, True);
    Require(Filters.Apply(False) = 0, 'Publisher case-sensitive filter ignored case');
    Filters.SetValue(COL_PUBLISHER, '=Ёлка Пресс');
    Require(Filters.Apply(False) = 1, 'Exact publisher filter included another spelling');
    Filters.Clear;
    Filters.SetValue(COL_PUBLISHER, '=');
    Require(Filters.Apply(False) = 1, 'Missing publisher metadata cannot be filtered');
    Filters.Clear;
    Filters.SetValue(COL_LANG, 'uk');
    Filters.GetOptions(COL_PUBLISHER, Names);
    Require((Names.Count = 1) and (Names[0] = 'елка пресс'),
      'Publisher options ignore the other loaded column filters');
    Chosen.Add('ЕЛКА ПРЕСС');
    Filters.SetSelectedValues(COL_PUBLISHER, Chosen);
    Require(Filters.Apply(False) = 1, 'Publisher selected-values and language do not combine');
    Filters.Clear;
    Require(Filters.Apply(False) = 3, 'Clearing publisher filters failed to restore loaded rows');

    PublisherMenu := frmMain.FindComponent('miColumnPublisher') as TMenuItem;
    PublisherMenu.OnClick(PublisherMenu);
    ColumnIndex := -1;
    for var I := 0 to Tree.Header.Columns.Count - 1 do
      if Tree.Header.Columns[I].Tag = COL_PUBLISHER then ColumnIndex := I;
    Require(ColumnIndex >= 0, 'Publisher header menu does not add its column');
    Text := '';
    Tree.OnGetText(Tree, Nodes[0], ColumnIndex, ttNormal, Text);
    Book := Tree.GetNodeData(Nodes[0]);
    Require(Text = Book.Publisher, 'Publisher column displays other metadata');
    CompareResult := 0;
    Tree.OnCompareNodes(Tree, Nodes[0], Nodes[1], ColumnIndex, CompareResult);
    var FirstBook: PBookRecord := Tree.GetNodeData(Nodes[0]);
    var SecondBook: PBookRecord := Tree.GetNodeData(Nodes[1]);
    Require(Sign(CompareResult) = Sign(CompareStr(FirstBook.Publisher, SecondBook.Publisher)),
      'Publisher column sorting compares another field');
    LayoutFile := Settings.AppPath + 'publisher-column-layout.ini';
    Columns := TColumns.Create(LayoutFile);
    Columns.Mode := tmFlat;
    Columns.GetColumns(Tree.Header.Columns);
    Columns.Save('PublisherFixture');
    Reloaded := TColumns.Create(LayoutFile);
    Reloaded.Load('PublisherFixture', tmFlat);
    Found := False;
    for var I := 0 to Reloaded.Count - 1 do
      if Reloaded[I].Tag = COL_PUBLISHER then
      begin
        Found := True;
        Require(Reloaded[I].Caption = 'Издательство', 'Saved publisher column lost its caption');
        Require(Reloaded[I].Width = Tree.Header.Columns[ColumnIndex].Width,
          'Saved publisher column lost its width');
      end;
    Require(Found, 'Reload discarded the newly appended publisher column ID');
    Writeln('PASS publisher column uses loaded metadata for display, sorting, case/ё/empty/combined filters and preserved saved layouts');
  finally
    Reloaded.Free;
    Columns.Free;
    Chosen.Free;
    Names.Free;
  end;
end;
