function FACState(Tree: TBookTree): string;
var Node: PVirtualNode;
begin
  Result:=''; Node:=Tree.GetFirst;
  while Assigned(Node) do
  begin
    Result:=Result+IntToStr(Node.Index)+':'+IntToStr(Ord(Tree.IsFiltered[Node]))+':'+
      IntToStr(Ord(Tree.Selected[Node]))+':'+IntToStr(Ord(Node.CheckState))+';';
    Node:=Tree.GetNext(Node);
  end;
end;

procedure FACCheckboxBounds(Popup: TForm; Check: TCheckBox; DPI: Integer);
var Bounds: TRect;
begin
  FCTCheckFilterControls(Popup,DPI); Popup.Canvas.Font.Assign(Check.Font);
  Bounds:=Rect(0,0,0,0);
  DrawText(Popup.Canvas.Handle,PChar(Check.Caption),Length(Check.Caption),Bounds,DT_CALCRECT or DT_NOPREFIX);
  Require((Bounds.Width+MulDiv(24,DPI,96)<=Check.Width) and (Bounds.Height<=Check.Height) and
    (Check.Top+Check.Height<=Check.Parent.ClientHeight),'Favorite checkbox is clipped after DPI/font/resize');
end;

procedure TestFavoriteAuthorColumnFilters;
var Tree: TBookTree; Filters: TBookColumnFilters; Probe: TFCTModalProbe;
  Nodes: TArray<PVirtualNode>; Saved: TArray<TBookRecord>; SavedChecks: TArray<TCheckState>; SavedSelected: TArray<Boolean>; SavedFocus: PVirtualNode;
  Node: PVirtualNode; Book: PBookRecord; Names: TStringList;
  Index: Integer; KeyA, KeyB, BeforeModal, ProfilePath: string; OldAuthors: TBookAuthors; SavedDark: Boolean;
begin
  RequireIsolatedRegression;
  Tree := frmMain.tvBooksA; Filters := TBookColumnFilters.ForTree(Tree);
  Nodes := nil; Saved := nil; SavedChecks:=nil; SavedSelected:=nil; SavedFocus:=Tree.FocusedNode;
  Node := Tree.GetFirst;
  while Assigned(Node) do
  begin
    Book := Tree.GetNodeData(Node);
    if Book.NodeType = ntBookInfo then
    begin
      Nodes := Nodes + [Node]; Saved := Saved + [Book^];
      SavedChecks:=SavedChecks+[Node.CheckState]; SavedSelected:=SavedSelected+[Tree.Selected[Node]];
    end;
    Node := Tree.GetNext(Node);
  end;
  Require(Length(Nodes) = 3, 'Favorite column fixture requires three loaded rows');
  Names := TStringList.Create; SavedDark:=MHLThemeDark;
  KeyA:=AuthorFavoriteKey('Иванов','Антон','Ильич'); KeyB:=AuthorFavoriteKey('Иванов','Ирина','Ильинична');
  try
    for Index := 0 to 2 do
    begin
      Book := Tree.GetNodeData(Nodes[Index]); Book.Authors := nil;
      if Index = 0 then
      begin TAuthorsHelper.Add(Book.Authors, 'Иванов', 'Антон', 'Ильич'); Book.Lang := 'ru'; end
      else if Index = 1 then
      begin TAuthorsHelper.Add(Book.Authors, 'Иванов', 'Ирина', 'Ильинична'); Book.Lang := 'en'; end
      else
      begin
        TAuthorsHelper.Add(Book.Authors, 'Другой', 'Соавтор', '');
        TAuthorsHelper.Add(Book.Authors, 'ИВАНОВ', 'АНТОН', 'ИЛЬИЧ'); Book.Lang := 'uk';
      end;
    end;
    Filters.Clear; SetFavoriteAuthorFilterKeys(nil);
    Filters.FavoriteAuthorsOnly := True;
    Require((Filters.Count = 1) and (Filters.Apply(False) = 0), 'Empty favorite filter broadened the list');
    Require(SetFavoriteAuthorFilterKeys([KeyA]),'Actual favorite-key addition was ignored');
    Require(not SetFavoriteAuthorFilterKeys([KeyA]),'Identical favorite set invalidates caches');
    Require(SetFavoriteAuthorFilterKeys([KeyA,KeyB]),'Second favorite was ignored');
    Require(not SetFavoriteAuthorFilterKeys([KeyB,KeyA,KeyA]),'Reordered/duplicate favorite set invalidates caches');
    Require(SetFavoriteAuthorFilterKeys([KeyA]),'Actual favorite removal was ignored');
    Book:=Tree.GetNodeData(Nodes[2]); Book.BookKey.DatabaseID:=Saved[2].BookKey.DatabaseID+1000;
    Require(Filters.Apply(False) = 2, 'Favorite filter lost Unicode aliases or coauthored books');
    Book:=Tree.GetNodeData(Nodes[2]); OldAuthors:=Book.Authors; Book.Authors:=nil;
    TAuthorsHelper.Add(Book.Authors,StringOfChar('X',2049),'','');
    TAuthorsHelper.Add(Book.Authors,'bad'+#0+'name','','');
    TAuthorsHelper.Add(Book.Authors,'Иванов','Антон','Ильич');
    Filters.FavoriteAuthorsOnly:=False; Filters.FavoriteAuthorsOnly:=True;
    Require(Filters.Apply(False)=2,'Malformed first author suppressed a valid favorite coauthor');
    Book.Authors:=OldAuthors;
    Book:=Tree.GetNodeData(Nodes[0]); OldAuthors:=Book.Authors; Book.Authors:=nil; SetLength(Book.Authors,8194);
    for var N:=0 to 8192 do Book.Authors[N].LastName:='Noise '+IntToStr(N);
    Book.Authors[8193].LastName:='Иванов'; Book.Authors[8193].FirstName:='Антон'; Book.Authors[8193].MiddleName:='Ильич';
    Filters.FavoriteAuthorsOnly:=False; Filters.FavoriteAuthorsOnly:=True;
{$IFDEF MHL_SQL_PROFILE}
    ProfilePath:=TPath.Combine(Settings.AppPath,'favorite-column-hotpath.tsv'); StartSQLiteProfile;
{$ENDIF}
    try Require(Filters.Apply(False)=2,'Bounded name-cache rollover lost a valid favorite match');
    finally
{$IFDEF MHL_SQL_PROFILE}
      SaveSQLiteProfile(ProfilePath); StopSQLiteProfile;
{$ENDIF}
    end;
{$IFDEF MHL_SQL_PROFILE}
    Names.LoadFromFile(ProfilePath,TEncoding.UTF8);
    Require(Names.Count=1,'Favorite hot-path filtering executed SQL');
{$ENDIF}
    Book.Authors:=OldAuthors; Filters.FavoriteAuthorsOnly:=False; Filters.FavoriteAuthorsOnly:=True; Filters.Apply(False);
    Filters.GetOptions(COL_LANG, Names);
    Require((Names.Count = 2) and (Names.IndexOf('ru') >= 0) and (Names.IndexOf('uk') >= 0),
      'Column options ignore the favorite restriction');
    Filters.SetValue(COL_LANG, '=uk');
    Require(Filters.Apply(False) = 1, 'Favorite authors do not combine with language');
    SetFavoriteAuthorFilterKeys([AuthorFavoriteKey('Иванов', 'Ирина', 'Ильинична')]);
    Require(Filters.Apply(False) = 0, 'Favorite-set changes reused stale matches/options');
    Filters.SetValue(COL_LANG, '');
    Require(Filters.Apply(False) = 1, 'Same surname matched the wrong favorite author');
    Filters.FavoriteAuthorsOnly := False; Filters.RestoreApplied;
    Require(Filters.FavoriteAuthorsOnly and (Filters.Apply(False) = 1), 'Restore applied forgot the favorite condition');
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark);
      Probe:=TFCTModalProbe.Create('TListFilterEditor','Фильтр: Автор',
        procedure(Popup: TForm)
        var Check: TCheckBox; FontSize: Integer;
        begin
          Check:=Popup.FindComponent('FavoriteAuthorsOnlyCheck') as TCheckBox;
          Writeln('PROFILE favorite author modal dark=',Ord(Dark),
            ' live_favorite=',Ord(Filters.FavoriteAuthorsOnly),' checkbox_present=',Ord(Assigned(Check))); Flush(Output);
          Require(Assigned(Check) and Check.Checked,'Author filter lacks its independent favorite checkbox');
          for var DPI in TArray<Integer>.Create(96,144,192) do
          begin
            Popup.ScaleForPPI(DPI); Popup.ClientWidth:=MulDiv(420,DPI,96); FACCheckboxBounds(Popup,Check,DPI);
            FontSize:=Popup.Font.Size; Popup.Font.Size:=FontSize+2; Popup.ClientWidth:=Popup.ClientWidth+1;
            FACCheckboxBounds(Popup,Check,DPI); Popup.Width:=Popup.Constraints.MinWidth; FACCheckboxBounds(Popup,Check,DPI);
            Popup.Font.Size:=FontSize; Popup.ClientWidth:=MulDiv(420,DPI,96); FACCheckboxBounds(Popup,Check,DPI);
          end;
          Check.Checked:=False; Popup.ModalResult:=mrCancel;
        end);
      try
        Require(not EditBookColumnFilter(Tree,COL_AUTHOR) and Filters.FavoriteAuthorsOnly,
          'Cancel changed the favorite column condition');
        Require(Probe.Completed,'Author modal closed before its strict checkbox/layout checks ran');
      finally Probe.Free; end;
    end;
    Filters.Clear; Require(Filters.Apply(False)=3,'Modal draft setup failed');
    for var Item in Nodes do Item.CheckState:=csCheckedNormal;
    BeforeModal:=FACState(Tree);
    Probe:=TFCTModalProbe.Create('TAllFiltersEditor','Фильтры столбцов',
      procedure(Outer: TForm)
      var Check: TCheckBox; AuthorButton: TButton; NestedProbe: TFCTModalProbe;
      begin
        Check:=Outer.FindComponent('FavoriteAuthorsOnlyCheck') as TCheckBox;
        Require(Assigned(Check) and not Check.Checked,'All-filters checkbox state incorrect'); Check.Checked:=True;
        AuthorButton:=nil;
        for var Component in Outer do
          if (Component is TButton) and (TButton(Component).Tag=COL_AUTHOR) then AuthorButton:=TButton(Component);
        Require(Assigned(AuthorButton),'All-filters author action missing');
        NestedProbe:=TFCTModalProbe.Create('TListFilterEditor','Фильтр: Автор',
          procedure(Inner: TForm)
          var InnerCheck: TCheckBox;
          begin
            Require(string(Inner.Caption)='Фильтр: Автор','Expected nested author modal');
            InnerCheck:=Inner.FindComponent('FavoriteAuthorsOnlyCheck') as TCheckBox;
            Require(Assigned(InnerCheck) and InnerCheck.Checked,'Nested dialog did not receive its draft favorite state');
            Require(TBookColumnFilters.ForTree(Tree)=Filters,'ForTree exposed the temporary draft to background work');
            Require(not Filters.FavoriteAuthorsOnly,'Nested draft leaked into live favorite conditions');
            // Simulate the real background publication while both modals run.
            Require(SetFavoriteAuthorFilterKeys([KeyA]),'Interleaving did not change the global favorite set');
            if Filters.FavoriteAuthorsOnly then Filters.Apply(False);
            Require(FACState(Tree)=BeforeModal,'Background publish applied unconfirmed draft or lost checks');
            Inner.ModalResult:=mrCancel;
          end);
        try
          AuthorButton.Click;
          Require(NestedProbe.Completed,'Nested author modal closed before cancellation/interleaving checks ran');
        finally NestedProbe.Free; end;
        Require(not Filters.FavoriteAuthorsOnly and (Filters.Count=0),'Nested cancel changed committed conditions');
        Require(FACState(Tree)=BeforeModal,'Nested cancel changed visible/checked books'); Outer.ModalResult:=mrCancel;
      end);
    try
      Require(not EditBookColumnFilters(Tree),'Outer draft cancel unexpectedly committed');
      Require(Probe.Completed,'All-filters modal closed before its cancellation/interleaving checks ran');
    finally Probe.Free; end;
    Require(not Filters.FavoriteAuthorsOnly and (Filters.Count=0) and (FACState(Tree)=BeforeModal),
      'Outer cancel after background publication changed conditions/visibility/checks');
    // Committing the separate draft must still transfer nested list choices.
    Probe:=TFCTModalProbe.Create('TAllFiltersEditor','Фильтры столбцов',
      procedure(Outer: TForm)
      var Button: TButton; Check: TCheckBox; NestedProbe: TFCTModalProbe;
      begin
        Check:=Outer.FindComponent('FavoriteAuthorsOnlyCheck') as TCheckBox;
        Require(Assigned(Check) and not Check.Checked,'Draft Apply checkbox state incorrect'); Check.Checked:=True;
        Button:=nil;
        for var Component in Outer do
          if (Component is TButton) and (TButton(Component).Tag=COL_LANG) then Button:=TButton(Component);
        Require(Assigned(Button),'Draft language action missing');
        NestedProbe:=TFCTModalProbe.Create('TListFilterEditor','Фильтр: Язык',
          procedure(Inner: TForm)
          var Values: TVirtualStringTree; Item: PVirtualNode;
          begin
            Values:=Inner.FindComponent('FilterOptionList') as TVirtualStringTree;
            Require(Assigned(Values) and (Values.TotalCount>0),'Nested draft language list missing');
            Item:=Values.GetFirst; Values.ValidateNode(Item,False); Values.CheckState[Item]:=csCheckedNormal;
            Inner.ModalResult:=mrOk;
          end);
        try
          Button.Click;
          Require(NestedProbe.Completed,'Nested language modal closed before its strict Apply checks ran');
        finally NestedProbe.Free; end;
        Require(not Filters.FavoriteAuthorsOnly and (Filters.Value(COL_LANG)=''),'Nested OK prematurely committed live conditions');
        Require(FACState(Tree)=BeforeModal,'Nested OK mutated book visibility/checks before outer Apply'); Outer.ModalResult:=mrOk;
      end);
    try
      Require(EditBookColumnFilters(Tree) and Filters.FavoriteAuthorsOnly and (Filters.Value(COL_LANG)<>''),
        'Outer Apply did not commit its independent nested draft');
      Require(Probe.Completed,'All-filters modal closed before its strict Apply checks ran');
    finally Probe.Free; end;
    Require(FACState(Tree)=BeforeModal,'Editing committed conditions wrote tree state before the explicit evaluator');
    Filters.Clear;
    Require(Filters.Apply(False) = 3, 'Clear failed to restore loaded books');
    Writeln('PASS favorite column checkbox combines filters, distinguishes complete names and coauthors, follows DPI and preserves cancellation without SQL');
  finally
    for Index := 0 to High(Nodes) do begin Book := Tree.GetNodeData(Nodes[Index]); Book^ := Saved[Index]; end;
    SetFavoriteAuthorFilterKeys(nil); Filters.Clear; Filters.Apply(False);
    Tree.BeginUpdate;
    try
      for Index:=0 to High(Nodes) do begin Nodes[Index].CheckState:=SavedChecks[Index]; Tree.Selected[Nodes[Index]]:=SavedSelected[Index]; end;
      Tree.FocusedNode:=SavedFocus;
    finally Tree.EndUpdate; end;
    SetMHLTheme(SavedDark); Names.Free;
  end;
end;
