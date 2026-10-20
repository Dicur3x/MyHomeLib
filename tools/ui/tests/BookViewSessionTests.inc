function SessionTrees: TArray<TBookTree>;
begin
  Result := TArray<TBookTree>.Create(frmMain.tvBooksA, frmMain.tvBooksS,
    frmMain.tvBooksG, frmMain.tvBooksSR, frmMain.tvBooksF, PublisherView.Books);
end;

procedure CheckViewSessionState(Restored: Boolean);
var Filters: TBookColumnFilters; Names: TStringList;
begin
  Names := TStringList.Create;
  try
    for var Tree in SessionTrees do
    begin
      Filters := TBookColumnFilters.ForTree(Tree);
      if not Restored then
      begin
        Require((Length(Tree.SortKeys) = 0) and (Filters.Count = 0),
          'Declined/disabled restore retained another session or collection state');
        Continue;
      end;
      Require((Length(Tree.SortKeys) = 3) and
        (Tree.SortKeys[0].Tag = COL_TITLE) and (Tree.SortKeys[0].Direction = sdDescending) and
        (Tree.SortKeys[1].Tag = COL_DATE) and (Tree.SortKeys[1].Direction = sdAscending) and
        (Tree.SortKeys[2].Tag = COL_SIZE) and (Tree.SortKeys[2].Direction = sdDescending),
        'Session lost column IDs/order/direction, view=' + IntToStr(Tree.Tag) + ' count=' + IntToStr(Length(Tree.SortKeys)));
      Require((Tree.Header.SortColumn >= 0) and
        (Tree.Header.Columns[Tree.Header.SortColumn].Tag = COL_TITLE), 'Sort arrow has a stale column index');
      Require((Filters.Value(COL_TITLE) = 'Alpha') and Filters.CaseSensitive(COL_TITLE),
        'Session lost text filter or case matching');
      Require(Filters.Value(COL_CITY) = 'Город ё ' + IntToStr(Tree.Tag),
        'Filters leaked between tabs or lost Unicode');
      Require(Filters.FavoriteAuthorsOnly = (Tree.Tag = PAGE_FAVORITES),
        'Favorite-author condition leaked between tabs');
      Filters.GetSelectedValues(COL_SERIES, Names);
      Require((Names.Count = 2) and (Names[0] = 'Alpha series') and
        (Names[1] = 'Серия ё' + sLineBreak + '=значение'), 'Exact selections lost multiline Unicode');
      Require(Filters.Value(COL_SIZE) = 'num;1;0;100000', 'Session lost a numeric range');
      Require(Filters.Value(COL_DATE) = 'date;3;2020-01-01;2026-10-20', 'Session lost a date range');
    end;
  finally Names.Free; end;
end;

procedure SeedViewSessionState;
var Keys: TArray<TBookSortKey>; Names: TStringList; Filters: TBookColumnFilters;
begin
  SetLength(Keys, 3);
  Keys[0].Tag := COL_TITLE; Keys[0].Direction := sdDescending;
  Keys[1].Tag := COL_DATE; Keys[1].Direction := sdAscending;
  Keys[2].Tag := COL_SIZE; Keys[2].Direction := sdDescending;
  Names := TStringList.Create;
  try
    Names.Add('Alpha series'); Names.Add('Серия ё' + sLineBreak + '=значение');
    for var Tree in SessionTrees do
    begin
      Tree.SortKeys := Copy(Keys); frmMain.SortLoadedBooks(Tree);
      Filters := TBookColumnFilters.ForTree(Tree);
      Filters.Clear; Filters.SetValue(COL_TITLE, 'Alpha');
      Filters.SetCaseSensitive(COL_TITLE, True); Filters.SetSelectedValues(COL_SERIES, Names);
      Filters.FavoriteAuthorsOnly := Tree.Tag = PAGE_FAVORITES;
      Filters.SetValue(COL_CITY, 'Город ё ' + IntToStr(Tree.Tag));
      Filters.SetValue(COL_SIZE, 'num;1;0;100000');
      Filters.SetValue(COL_DATE, 'date;3;2020-01-01;2026-10-20');
      frmMain.ApplyBookColumnFilters(Tree);
    end;
  finally Names.Free; end;
end;

procedure ViewSessionChild;
var Choice: string; Probe: TFCTModalProbe; Expected: Boolean; Locked: THandle; Started: UInt64;
begin
  Choice := ParamStr(2); Probe := nil;

  try
    Application.CreateForm(TdmImages, dmImages); dmImages.ApplyThemeIcons;
    TfrmMain.DeferInitialCollection := True;
    Locked := CreateFile(PChar(Settings.WorkPath + 'book-views.ini'), GENERIC_READ,
      0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    Require(Locked <> INVALID_HANDLE_VALUE, 'Cannot lock session configuration before first paint');
    Started := GetTickCount64;
    try
      Application.CreateForm(TfrmMain, frmMain);
      Require(frmMain.Visible and (frmMain.tvBooksA.TotalCount = 0),
        'Session restoration eagerly loaded books before showing Main');
      Writeln('PROFILE session main_visible_ms=', GetTickCount64 - Started, ' mode=', Choice);
    finally CloseHandle(Locked); end;
    if Choice.StartsWith('ask-') then
      Probe := TFCTModalProbe.Create('TMessageForm', 'Сортировки и фильтры',
        procedure(Dialog: TForm)
        begin
          Require(frmMain.Visible and (frmMain.tvBooksA.TotalCount = 0),
            'Restore prompt blocked the first visible window or arrived after rows');
          var Bounds := frmMain.Monitor.WorkareaRect;
          Writeln('PROFILE restore dialog ', Dialog.Left, ',', Dialog.Top, ' ', Dialog.Width, 'x', Dialog.Height,
            ' workarea=', Bounds.Left, ',', Bounds.Top, ' ', Bounds.Width, 'x', Bounds.Height);
          Require((Abs(Dialog.Left + Dialog.Width div 2 - (Bounds.Left + Bounds.Width div 2)) <= 24) and
            (Abs(Dialog.Top + Dialog.Height div 2 - (Bounds.Top + Bounds.Height div 2)) <= 24),
            'Restore prompt is not centered on its monitor');
          var Remember := Dialog.FindComponent('cbRememberBookViews') as TCheckBox;
          Require(Assigned(Remember) and Remember.Visible and not Remember.Checked,
            'Restore prompt lacks an unchecked remember-choice checkbox');
          Remember.Checked := Choice.Contains('remember');
          Require((Remember.Left >= 0) and (Remember.Left + Remember.Width <= Dialog.ClientWidth),
            'Remember checkbox exceeds the restore prompt');
          for var Component in Dialog do
            if Component is TButton then Require(TButton(Component).Top >= Remember.Top + Remember.Height,
              'Remember checkbox overlaps the restore buttons');
          for var Component in Dialog do
            if Component is TButton then Require(TButton(Component).Top + TButton(Component).Height <= Dialog.ClientHeight,
              'Restore button exceeds the prompt');
          if Choice.EndsWith('yes') then Dialog.ModalResult := mrYes else Dialog.ModalResult := mrNo;
        end);
    CompleteDeferredStartup;
    Expected := (Choice = 'auto') or (Choice.StartsWith('ask-') and Choice.EndsWith('yes'));
    Settings.LoadSettings;
    if Choice.Contains('remember') then
    begin
      if Expected then Require(Settings.RestoreBookViews = rbvAutomatic, 'Remembered Yes did not persist automatic restore')
      else Require(Settings.RestoreBookViews = rbvNever, 'Remembered No did not persist disabled restore');
    end
    else if Choice.StartsWith('ask-') then Require(Settings.RestoreBookViews = rbvAsk,
      'An unchecked remember choice silently changed the preference');
    CheckViewSessionState(Expected);
    if Choice.StartsWith('ask-') then Require(Probe.Completed, 'Restore choice was not requested');
    if Expected then
    begin
      Require(frmMain.tvBooksSR.TotalCount = 0, 'Restore eagerly loaded inactive Search');
      Require(string(frmMain.lblBooksTotalA.Caption).Contains('фильтр'), 'Restored filters have no visible indicator');
      Require(frmMain.tvBooksA.FocusedNode = nil, 'An invisible book remained selected');
      if Choice = 'auto' then
      begin
        frmMain.ResetColumnFiltersClick(nil);
        Require((TBookColumnFilters.ForTree(frmMain.tvBooksA).Count = 0) and
          (frmMain.tvBooksA.FocusedNode <> nil), 'Reset did not reveal and select books');
        frmMain.ClearBookSorting(nil);
        Require(Length(frmMain.tvBooksA.SortKeys) = 0, 'Clear sorting retained keys');
      end;
    end;
    FreeAndNil(frmMain);
    Writeln('PASS view session child ', Choice); Flush(Output);
  finally Probe.Free; end;
end;

procedure RunViewSessionChild(const Choice: string);
var SI: TStartupInfo; PI: TProcessInformation; Command: string; ExitCode: DWORD;
begin
  SI := Default(TStartupInfo); SI.cb := SizeOf(SI); SI.dwFlags := STARTF_USESTDHANDLES;
  SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := GetStdHandle(STD_OUTPUT_HANDLE); SI.hStdError := GetStdHandle(STD_ERROR_HANDLE);
  Command := '"' + ParamStr(0) + '" view-session-reopen ' + Choice; UniqueString(Command);
  Require(CreateProcess(nil, PChar(Command), nil, nil, True, CREATE_NO_WINDOW,
    nil, PChar(Settings.AppPath), SI, PI), 'Could not start isolated session reopen');
  try
    if WaitForSingleObject(PI.hProcess, 60000) <> WAIT_OBJECT_0 then
    begin TerminateProcess(PI.hProcess, 124); Require(False, 'Session reopen timed out'); end;
    Require(GetExitCodeProcess(PI.hProcess, ExitCode) and (ExitCode = 0), 'Session reopen child failed: ' + Choice);
  finally CloseHandle(PI.hThread); CloseHandle(PI.hProcess); end;
end;

procedure TestBookViewSessions(OneID, TwoID: Integer);
var Form: TfrmSettings; Combo: TComboBox; Snapshot: TBytes; Ini: TMemIniFile;
begin
  SeedViewSessionState; CheckViewSessionState(True);
  ChangeCollection(TwoID); CheckViewSessionState(False);
  ChangeCollection(OneID); CheckViewSessionState(True);
  Writeln('PASS view sessions isolate all six tabs and collections');
  ShowPage(PAGE_AUTHORS); frmMain.btnSwitchTreeModeClick(nil);
  Require(Length(frmMain.tvBooksA.SortKeys) = 3, 'Grouping discarded remembered sorting');
  Require(frmMain.tvBooksA.Header.SortColumn = NoColumn, 'Tree mode displays an inapplicable arrow');
  frmMain.btnSwitchTreeModeClick(nil); CheckViewSessionState(True);
  FreeAndNil(frmMain);
  Snapshot := TFile.ReadAllBytes(Settings.WorkPath + 'book-views.ini');
  for var Choice in TArray<string>.Create('auto', 'ask-yes', 'ask-no', 'never',
    'ask-remember-yes', 'ask-remember-no') do
  begin
    TFile.WriteAllBytes(Settings.WorkPath + 'book-views.ini', Snapshot);
    Settings.RestoreBookViews := rbvAutomatic;
    if Choice.StartsWith('ask-') then Settings.RestoreBookViews := rbvAsk;
    if Choice = 'never' then Settings.RestoreBookViews := rbvNever;
    Settings.SaveSettings; RunViewSessionChild(Choice);
    if Choice.Contains('remember') then
    begin
      if Choice.EndsWith('yes') then RunViewSessionChild('auto') else RunViewSessionChild('never');
    end;
    if Choice = 'auto' then
    begin
      Ini := TMemIniFile.Create(Settings.WorkPath + 'book-views.ini', TEncoding.UTF8);
      try
        Require(Ini.ReadInteger('Collection.' + IntToStr(OneID) + '.View.0', 'SortCount', -1) = 0,
          'Reset sorting was not written to disk');
        Require(not Ini.ReadBool('Collection.' + IntToStr(OneID) + '.View.0', 'Active', True),
          'Reset filters were not written to disk');
      finally Ini.Free; end;
    end;
  end;
  Writeln('PASS actual process restart restores automatically, asks yes/no after paint, disables restore and persists reset');
  Writeln('PASS restore prompt remembers affirmative and negative choices across another process restart');
  Settings.RestoreBookViews := rbvAutomatic;
  TFile.WriteAllText(Settings.WorkPath + 'book-views.ini',
    '[Format]' + sLineBreak + 'Version=1' + sLineBreak +
    '[Collection.' + IntToStr(OneID) + '.View.0]' + sLineBreak +
    'SortCount=-2147483648' + sLineBreak + 'SortTag0=99999' + sLineBreak +
    'SortDirection0=42' + sLineBreak + 'Filters={broken', TEncoding.UTF8);
  TfrmMain.DeferInitialCollection := True;
  Application.CreateForm(TfrmMain, frmMain); CompleteDeferredStartup;
  CheckViewSessionState(False);
  Writeln('PASS malformed view configuration is ignored without eager book loading');
  Form := TfrmSettings.Create(nil);
  try
    Form.LoadSetting; Combo := Form.FindComponent('cbRestoreBookViews') as TComboBox;
    Require(Assigned(Combo) and (Combo.Items.Count = 3) and (Combo.ItemIndex = 0), 'Settings lacks three restore choices');
    Form.Show; Form.tvSections.Select(Form.tvSections.Items[TTabSheet(Combo.Parent).PageIndex]);
    for var Mode := 0 to 2 do
    begin
      Combo.ItemIndex := Mode; Form.SaveSettings; Settings.SaveSettings; Settings.LoadSettings;
      Require(Ord(Settings.RestoreBookViews) = Mode, 'Restore preference did not persist');
    end;
  finally Form.Free; end;
  Ini := TMemIniFile.Create(Settings.SettingsFileName, TEncoding.UTF8);
  try Ini.WriteInteger('INTERFACE', 'RestoreBookViews', 999); Ini.UpdateFile;
  finally Ini.Free; end;
  Settings.LoadSettings;
  Require(Settings.RestoreBookViews = rbvAsk, 'Invalid preference should fall back to asking');
  Writeln('PASS view session settings persist all choices and reject invalid preference');
end;
