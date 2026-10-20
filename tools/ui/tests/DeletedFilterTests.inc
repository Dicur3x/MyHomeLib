// Unified deleted-book mode regression; isolated main form required.
// Uses already in CollectionViewsTest: SQLiteWrap, SQLiteProfile, unit_SearchPresets.

procedure TestUnifiedDeletedFilter(const One: IBookCollection; OneID, TwoID: Integer);
var
  IDs: array[0..19] of Integer;
  GroupID, I: Integer;
  Group: TGroupData;
  Groups: IGroupIterator;
  BeforeCollection, BeforeSystem, BeforeOther, PresetHash: string;
  ProtectedBook, ProtectedHistory, BookHash, HistoryHash: string;
  PresetFile: string;
  Reopened: TSearchPresets;

  procedure CheckMode(Expected: Boolean);
  begin
    frmMain.HideDeletedBooksUpdate(nil);
    Require((Settings.HideDeletedBooks = Expected) and
      (frmMain.cbDeleted.Checked = Expected) and
      (frmMain.acViewHideDeletedBooks.Checked = Expected),
      'Toolbar, search checkbox and persisted deletion mode diverged');
  end;

  procedure CheckboxMode(Value: Boolean);
  begin
    Require(Assigned(frmMain.cbDeleted.OnClick), 'Search deletion checkbox has no immediate action');
    frmMain.cbDeleted.Checked := Value;
    // Also exercise the normal click callback; a repeated notification is harmless.
    frmMain.cbDeleted.OnClick(frmMain.cbDeleted);
    CheckMode(Value);
  end;

  function CountBooks(Tree: TBookTree): Integer;
  var Node: PVirtualNode; Data: PBookRecord;
  begin
    Result := 0;
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Data := Tree.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType = ntBookInfo) then Inc(Result);
      Node := Tree.GetNext(Node);
    end;
  end;

  procedure ExpectCount(Tree: TBookTree; Expected: Integer);
  begin
    Require(CountBooks(Tree) = Expected,
      Format('Wrong book count: expected %d, actual %d', [Expected, CountBooks(Tree)]));
  end;

  function DumpTables(const FileName: string; const Tables: array of string): string;
  var DB: TSQLiteDatabase; Columns, Rows: TSQLiteQuery; Projection, Name, Value: string;
  begin
    Result := '';
    DB := TSQLiteDatabase.CreateReadOnly(FileName);
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
        Require(Projection <> '', 'Missing protected table: ' + Name);
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
            Result := Result + #10;
            Rows.Next;
          end;
        finally Rows.Free; end;
      end;
    finally DB.Free; end;
  end;

  function CollectionData(ID: Integer): string;
  begin
    Result := DumpTables(SystemDB.GetCollectionInfo(ID).DBFileName,
      ['Books', 'Authors', 'Author_List', 'Series', 'Series_List', 'Genre_List']);
  end;

  procedure CheckProtected;
  begin
    Require(CollectionData(OneID) = BeforeCollection,
      'Deletion display mode changed source books, personal data or series links');
    Require(CollectionData(TwoID) = BeforeOther, 'Deletion mode changed the other collection');
    Require(DumpTables(Settings.SystemFileName[sfSystemDB], ['Books', 'BookGroups', 'Groups']) = BeforeSystem,
      'Deletion display mode changed saved books, reviews or group membership');
    Require((THashSHA2.GetHashStringFromFile(ProtectedBook) = BookHash) and
      (THashSHA2.GetHashStringFromFile(ProtectedHistory) = HistoryHash),
      'Deletion display mode changed original book or reading history bytes');
    Require(One.GetReview(CreateBookKey(IDs[0], OneID)) = 'Личная мысль — ё, ї, ў 😀',
      'Deletion display mode lost the personal review');
  end;

  procedure CheckGroupIterator(DatabaseID, Expected: Integer);
  var Iterator: IBookIterator; Book: TBookRecord; Seen: Integer;
  begin
    Iterator := SystemDB.GetBookIterator(GroupID, DatabaseID);
    Require(Iterator.RecordCount = Expected, 'Deleted-group count query does not match the mode');
    Seen := 0;
    while Iterator.Next(Book) do
    begin
      Inc(Seen);
      Require(not Settings.HideDeletedBooks or not (bpIsDeleted in Book.BookProps),
        'Deleted-group row query returned a hidden book');
      if DatabaseID <> INVALID_COLLECTION_ID then
        Require(Book.BookKey.DatabaseID = DatabaseID, 'Group collection parameter returned another collection');
    end;
    Require(Seen = Expected, 'Deleted-group row query disagrees with its count');
  end;

  procedure CheckNoSearchQuery(const Phase: string);
  var ProfileFile: string;
  begin
    ProfileFile := Settings.AppPath + 'deleted-filter-' + Phase + '.tsv';
    SaveSQLiteProfile(ProfileFile);
    StopSQLiteProfile;
    {$IFDEF MHL_SQL_PROFILE}
    Require(FileExists(ProfileFile), 'Search no-query proof requires its SQLite profile');
    Require(not TFile.ReadAllText(ProfileFile).Contains('MHLGenreMatches'),
      'Unapplied search unexpectedly queried the catalog: ' + Phase);
    {$ENDIF}
    ExpectCount(frmMain.tvBooksSR, 0);
  end;

  procedure SelectPreset(const Name: string; ExpectedMode: Boolean);
  begin
    StartSQLiteProfile;
    frmMain.cbPresetName.Text := Name;
    frmMain.cbPresetNameSelect(nil);
    CheckMode(ExpectedMode);
    CheckNoSearchQuery('preset-' + IntToStr(Ord(ExpectedMode)));
  end;

begin
  RequireIsolatedRegression;
  Require((One.CollectionID = OneID) and (OneID <> TwoID), 'Deletion regression requires distinct isolated collections');
  ShowPage(PAGE_SEARCH);
  CheckboxMode(False);
  frmMain.DoClearFilter(False);
  for I := Low(IDs) to High(IDs) do
  begin
    var Title := 'Delta oracle beta ' + Format('%.2d', [I + 1]);
    if I < 3 then Title := 'Delta oracle alpha ' + Format('%.2d', [I + 1]);
    IDs[I] := AddBook(One, Title, 'Delta oracle', 'ru', 'Protected cycle', '0.1', (I + 1) mod 3 = 0);
  end;
  One.SetReview(CreateBookKey(IDs[0], OneID), 'Личная мысль — ё, ї, ў 😀');
  One.SetRate(CreateBookKey(IDs[0], OneID), 4);
  One.SetProgress(CreateBookKey(IDs[0], OneID), 37);
  Require(SystemDB.AddGroup('Deleted filter oracle'), 'Isolated deletion group was not created');
  GroupID := MHL_INVALID_ID;
  Groups := SystemDB.GetGroupIterator;
  while Groups.Next(Group) do
    if Group.Text = 'Deleted filter oracle' then GroupID := Group.GroupID;
  Groups := nil;
  Require(GroupID <> MHL_INVALID_ID, 'Isolated deletion group is absent');
  for I in IDs do One.AddBookToGroup(CreateBookKey(I, OneID), GroupID);

  ProtectedBook := Settings.AppPath + 'deleted-protected-book.fb2';
  ProtectedHistory := Settings.AppPath + 'deleted-protected-reader-history.ini';
  TFile.WriteAllText(ProtectedBook, '<FictionBook>Сохранённая книга ё</FictionBook>', TEncoding.UTF8);
  TFile.WriteAllText(ProtectedHistory, '[reader]' + sLineBreak + 'position=9876', TEncoding.UTF8);
  BookHash := THashSHA2.GetHashStringFromFile(ProtectedBook);
  HistoryHash := THashSHA2.GetHashStringFromFile(ProtectedHistory);
  // Warm the existing stable-ID remap once; the protected data starts afterwards.
  CheckGroupIterator(OneID, 20);
  BeforeCollection := CollectionData(OneID);
  BeforeOther := CollectionData(TwoID);
  BeforeSystem := DumpTables(Settings.SystemFileName[sfSystemDB], ['Books', 'BookGroups', 'Groups']);

  StartSQLiteProfile;
  frmMain.HideDeletedBooksExecute(nil);
  CheckMode(True);
  frmMain.btnSwitchTreeModeClick(nil);
  CheckNoSearchQuery('fresh');
  Writeln('PASS fresh search and tree-mode changes never load the whole catalog');

  CheckboxMode(False);
  frmMain.edFTitle.Text := 'Delta oracle';
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 20);
  frmMain.HideDeletedBooksExecute(nil);
  CheckMode(True);
  ExpectCount(frmMain.tvBooksSR, 14);
  StartSQLiteProfile;
  frmMain.DoApplyFilter(nil);
  SaveSQLiteProfile(Settings.AppPath + 'deleted-filter-immediate-apply.tsv'); StopSQLiteProfile;
  {$IFDEF MHL_SQL_PROFILE}
  Require(not TFile.ReadAllText(Settings.AppPath + 'deleted-filter-immediate-apply.tsv').Contains('MHLGenreMatches'),
    'Apply repeated the complete search already refreshed by the deletion checkbox');
  {$ENDIF}
  ExpectCount(frmMain.tvBooksSR, 14);
  // A later Apply remains an explicit refresh, even with identical conditions.
  StartSQLiteProfile;
  frmMain.DoApplyFilter(nil);
  SaveSQLiteProfile(Settings.AppPath + 'deleted-filter-later-apply.tsv'); StopSQLiteProfile;
  {$IFDEF MHL_SQL_PROFILE}
  Require(TFile.ReadAllText(Settings.AppPath + 'deleted-filter-later-apply.tsv').Contains('MHLGenreMatches'),
    'A later Apply no longer refreshes matching catalog data');
  {$ENDIF}
  ExpectCount(frmMain.tvBooksSR, 14);
  CheckGroupIterator(INVALID_COLLECTION_ID, 14);
  CheckGroupIterator(OneID, 14);
  CheckGroupIterator(TwoID, 0);
  frmMain.HideDeletedBooksExecute(nil);
  CheckMode(False);
  ExpectCount(frmMain.tvBooksSR, 20);
  CheckGroupIterator(INVALID_COLLECTION_ID, 20);
  CheckGroupIterator(OneID, 20);
  CheckProtected;
  Writeln('PASS search and group count/rows hide six deleted books and restore all twenty without data writes');

  frmMain.edFTitle.Text := 'Delta oracle alpha';
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 3);
  frmMain.edFTitle.Text := 'No matching draft';
  frmMain.edFFullName.Text := 'Unapplied author';
  CheckboxMode(True);
  ExpectCount(frmMain.tvBooksSR, 2);
  Require((frmMain.edFTitle.Text = 'No matching draft') and
    (frmMain.edFFullName.Text = 'Unapplied author'), 'Toggle applied or erased unfinished text');
  CheckboxMode(False);
  ExpectCount(frmMain.tvBooksSR, 3);
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 0);
  CheckboxMode(True);
  ExpectCount(frmMain.tvBooksSR, 0);
  CheckboxMode(False);
  ExpectCount(frmMain.tvBooksSR, 0);
  Writeln('PASS deletion toggle uses only the applied snapshot, preserves drafts and keeps an applied empty result empty');

  frmMain.DoClearFilter(False);
  StartSQLiteProfile;
  CheckboxMode(True);
  frmMain.btnSwitchTreeModeClick(nil);
  CheckNoSearchQuery('cleared');
  CheckMode(True);
  frmMain.edFTitle.Text := 'Delta oracle alpha';
  frmMain.cbPresetName.Text := 'Deleted hidden';
  frmMain.SaveSearchPreset(nil);
  CheckboxMode(False);
  frmMain.cbPresetName.Text := 'Deleted shown';
  frmMain.SaveSearchPreset(nil);
  PresetFile := Settings.SystemFileName[sfPresets];
  PresetHash := THashSHA2.GetHashStringFromFile(PresetFile);
  SelectPreset('Deleted hidden', True);
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 2);
  SelectPreset('Deleted shown', False);
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 3);
  CheckboxMode(True);
  Require(THashSHA2.GetHashStringFromFile(PresetFile) = PresetHash,
    'Mode toggle rewrote saved preset conditions');
  Writeln('PASS saved true/false deletion conditions synchronize the shared mode without autoapplying presets');

  // Hidden search lazily reuses its snapshot when opened; language selection stays local.
  frmMain.edFTitle.Text := 'Preserved draft';
  ShowPage(PAGE_AUTHORS);
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  frmMain.HideDeletedBooksExecute(nil);
  CheckMode(False);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Mode toggle reset the author language');
  ShowPage(PAGE_SEARCH);
  ExpectCount(frmMain.tvBooksSR, 3);
  Require(frmMain.edFTitle.Text = 'Preserved draft', 'Lazy search refreshed from the draft instead of its snapshot');
  ShowPage(PAGE_FAVORITES);
  FillGroupsList(frmMain.tvGroups, SystemDB.GetGroupIterator, GroupID);
  frmMain.tvGroupsChange(frmMain.tvGroups, frmMain.tvGroups.GetFirstSelected);
  ExpectCount(frmMain.tvBooksF, 20);
  frmMain.HideDeletedBooksExecute(nil);
  CheckMode(True);
  ExpectCount(frmMain.tvBooksF, 14);
  frmMain.HideDeletedBooksExecute(nil);
  ExpectCount(frmMain.tvBooksF, 20);
  Require(frmMain.cbLangSelectF.Text = 'ru', 'Group refresh reset its saved language');
  CheckProtected;
  Writeln('PASS visible groups refresh immediately and hidden search refreshes lazily without losing draft or language');

  ShowPage(PAGE_SEARCH);
  ChangeCollection(TwoID);
  StartSQLiteProfile;
  CheckboxMode(True);
  frmMain.btnSwitchTreeModeClick(nil);
  CheckNoSearchQuery('collection-switch');
  ChangeCollection(OneID);
  StartSQLiteProfile;
  CheckboxMode(False);
  CheckNoSearchQuery('collection-return');
  CheckProtected;
  Writeln('PASS collection changes discard prior applied searches while retaining the shared deletion mode');

  // Reopen a legacy preset with no deletion key: inherit the visible global mode.
  Reopened := TSearchPresets.Create;
  try
    Reopened.Load(PresetFile);
    Reopened.GetPreset('Legacy no deletion').AddOrSetValue(SF_TITLE, 'Delta oracle alpha');
    Reopened.Save(PresetFile);
  finally Reopened.Free; end;
  PresetHash := THashSHA2.GetHashStringFromFile(PresetFile);
  frmMain.Free;
  frmMain := nil;
  Settings.ActiveCollection := OneID;
  Settings.ActivePage := PAGE_SEARCH;
  Application.CreateForm(TfrmMain, frmMain);
  CheckboxMode(True);
  SelectPreset('Legacy no deletion', True);
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 2);
  CheckboxMode(False);
  SelectPreset('Legacy no deletion', False);
  frmMain.DoApplyFilter(nil);
  ExpectCount(frmMain.tvBooksSR, 3);
  Require(THashSHA2.GetHashStringFromFile(PresetFile) = PresetHash,
    'Legacy preset selection modified saved bytes');
  CheckProtected;
  Writeln('PASS legacy presets inherit the shared mode after reopen, and original books, user data, groups and history survive every mode change');
end;
