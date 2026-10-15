// Actual settings actions against the wrapper-owned profile. No script is launched.
// Include after FilterCaptionTests.inc for TFCTModalProbe.
procedure TestSettingsWorkflowAudit;
var Form: TfrmSettings; Probe: TFCTModalProbe; SavedScripts: TScripts;
  SavedDefault, SavedMinutes, Value, Parsed, ExpectedDefault: Integer; SavedChecks, SavedTheme: Boolean;
  ScriptPath: string;

  procedure DeleteRow(Index: Integer);
  begin
    Form.lvScripts.Items[Index].Selected := True;
    Form.btnDeleteScriptClick(nil);
  end;

begin
  RequireIsolatedRegression;
  SavedScripts := TScripts.Create; SavedScripts.Assign(Settings.Scripts);
  SavedDefault := Settings.DefaultScript; SavedMinutes := Settings.ProgramUpdateMinutes;
  SavedChecks := Settings.CheckUpdate; SavedTheme := MHLThemeDark;
  Form := nil; Probe := nil;
  try
    // Reopen an interval large enough for Windows to insert a thousands
    // separator, then save through the actual validated button handler.
    for var CaseIndex := 0 to 2 do
    begin
      Value := TArray<Integer>.Create(1000,1020,525600)[CaseIndex];
      Settings.CheckUpdate := True; Settings.ProgramUpdateMinutes := Value;
      SetMHLTheme(CaseIndex = 1);
      Form := TfrmSettings.Create(nil);
      try
        Form.LoadSetting; Form.ScaleForPPI(96 + CaseIndex * 48);
        Form.Show; Form.tvSections.Select(Form.tvSections.Items[Form.tsInternet.PageIndex]);
        Application.ProcessMessages;
        Require((Form.cbProgramInterval.ItemIndex = 8) and
          not Form.udProgramInterval.Thousands and
          TryStrToInt(Form.edProgramInterval.Text,Parsed) and (Parsed = Value),
          'Reopened custom update interval is not a valid plain integer: ' + Form.edProgramInterval.Text);
        Form.SaveSettingsClick(nil);
        Require(Settings.CheckUpdate and (Settings.ProgramUpdateMinutes = Value),
          'Saving other settings changed a custom update interval');
        Settings.SaveSettings; Settings.LoadSettings;
        Require(Settings.CheckUpdate and (Settings.ProgramUpdateMinutes = Value),
          'Custom update interval did not survive profile save/reload');
        Writeln('PASS settings custom update interval ',Value,
          ' survives actual load/save/reload at ',Form.CurrentPPI,' DPI dark=',Ord(MHLThemeDark));
      finally FreeAndNil(Form); end;
    end;

    Settings.Scripts.Clear;
    ScriptPath := Settings.AppPath + 'unused-tool-fixture.cmd';
    Settings.Scripts.Add('First export',ScriptPath,'first');
    Settings.Scripts.Add('Second export',ScriptPath,'second');
    Settings.Scripts.Add('Selected export',ScriptPath,'third');
    Settings.DefaultScript := 3;
    SetMHLTheme(False); Form := TfrmSettings.Create(nil); Form.LoadSetting;
    Form.Show; Form.tvSections.Select(Form.tvSections.Items[Form.tsScripts.PageIndex]);
    Application.ProcessMessages;
    Probe := TFCTModalProbe.Create('TfrmEditScript','Добавление скрипта',
      procedure(Popup: TForm)
      var Editor: TfrmEditScript;
      begin
        Editor := TfrmEditScript(Popup);
        Require((Editor.Title = '') and (Editor.Path = ''),'New script inherited another editor value');
        Editor.Title := 'Инструмент ё 中文'; Editor.Path := ScriptPath;
        Editor.Params := '--literal "путь с пробелами"'; Editor.Standalone := True;
        Editor.btnSaveClick(nil);
      end);
    try
      Form.btnAddScriptClick(nil);
      Require(Probe.Completed and (Form.lvScripts.Items.Count = 4) and
        (Form.lvScripts.Items[3].Caption = 'Инструмент ё 中文') and
        (NativeInt(Form.lvScripts.Items[3].Data) = 1) and (Form.cbDefaultAction.ItemIndex = 3),
        'Actual Add script action failed or changed the selected default');
    finally FreeAndNil(Probe); end;
    Writeln('PASS settings Add script opens the actual editor with its own caption and preserves Unicode, mode and default');

    SetMHLTheme(True); Form.ScaleForPPI(192);
    Form.lvScripts.Items[2].Selected := True;
    Probe := TFCTModalProbe.Create('TfrmEditScript','Изменение параметров скрипта',
      procedure(Popup: TForm)
      var Editor: TfrmEditScript;
      begin
        Editor := TfrmEditScript(Popup); Editor.ScaleForPPI(192);
        Require((Editor.Title = 'Selected export') and (Editor.Params = 'third') and
          not Editor.Standalone,'Actual script editor loaded another row');
        Editor.Title := 'Выбранный экспорт ё'; Editor.Params := 'changed';
        Editor.btnSaveClick(nil);
      end);
    try
      Form.btnEditScriptClick(nil);
      Require(Probe.Completed and (Form.lvScripts.Items.Count = 4) and
        (Form.lvScripts.Items[2].Caption = 'Выбранный экспорт ё') and
        (Form.lvScripts.Items[2].SubItems[1] = 'changed') and
        (Form.cbDefaultAction.Items[3] = 'Выбранный экспорт ё') and (Form.cbDefaultAction.ItemIndex = 3),
        'Actual Edit script action lost its default or failed to save the selected row');
    finally FreeAndNil(Probe); end;
    Writeln('PASS settings Edit script opens the selected row, saves Unicode and keeps the renamed default at 192 DPI in dark theme');

    Probe := TFCTModalProbe.Create('TfrmEditScript','Изменение параметров скрипта',
      procedure(Popup: TForm)
      var Editor: TfrmEditScript;
      begin
        Editor := TfrmEditScript(Popup); Editor.Title := 'Discarded';
        Editor.Params := 'discarded'; Editor.Standalone := True;
        Editor.ModalResult := mrCancel;
      end);
    try
      Form.btnEditScriptClick(nil);
      Require(Probe.Completed and (Form.lvScripts.Items[2].Caption = 'Выбранный экспорт ё') and
        (Form.lvScripts.Items[2].SubItems[1] = 'changed') and
        (NativeInt(Form.lvScripts.Items[2].Data) = 0) and (Form.cbDefaultAction.ItemIndex = 3),
        'Canceling script editing changed saved values');
    finally FreeAndNil(Probe); end;
    Writeln('PASS settings Cancel script editing leaves title, arguments, mode and default unchanged');

    DeleteRow(0);
    Require((Form.cbDefaultAction.ItemIndex = 2) and
      (Form.cbDefaultAction.Text = 'Выбранный экспорт ё'),
      'Deleting an earlier script reset the unrelated default');
    DeleteRow(2);
    Require((Form.cbDefaultAction.ItemIndex = 2) and
      (Form.cbDefaultAction.Text = 'Выбранный экспорт ё'),
      'Deleting a later script reset the unrelated default');
    Form.SaveSettingsClick(nil); Settings.SaveSettings; Settings.LoadSettings;
    Require((Settings.Scripts.Count = 2) and (Settings.DefaultScript = 2) and
      (Settings.Scripts[1].Title = 'Выбранный экспорт ё'),
      'The preserved default did not survive profile save/reload');
    Form.LoadSetting; DeleteRow(1);
    Require((Form.cbDefaultAction.ItemIndex = 0) and (Form.lvScripts.Items.Count = 1),
      'Deleting the selected default did not fall back to the standard action');
    Writeln('PASS settings deleting other scripts preserves the default by identity; deleting that default restores Standard');

    for var DefaultChoice := 0 to 4 do
      for var Removed := 0 to 3 do
      begin
        Settings.Scripts.Clear;
        for var Index := 0 to 3 do
          Settings.Scripts.Add('Script ' + IntToStr(Index),ScriptPath,'unused');
        Settings.DefaultScript := DefaultChoice; Form.LoadSetting;
        Form.lvScripts.Selected := nil; Form.btnDeleteScriptClick(nil);
        Require((Form.lvScripts.Items.Count = 4) and (Form.cbDefaultAction.ItemIndex = DefaultChoice),
          'Delete without a selected script changed the list or default');
        ExpectedDefault := DefaultChoice;
        if ExpectedDefault = Removed + 1 then ExpectedDefault := 0
        else if ExpectedDefault > Removed + 1 then Dec(ExpectedDefault);
        DeleteRow(Removed);
        Require((Form.lvScripts.Items.Count = 3) and (Form.cbDefaultAction.ItemIndex = ExpectedDefault),
          Format('Incorrect default after deleting row %d with default %d',[Removed,DefaultChoice]));
        if ExpectedDefault > 0 then
          Require(Form.cbDefaultAction.Text = 'Script ' + IntToStr(DefaultChoice - 1),
            'The surviving default now names a different command');
        Form.SaveSettingsClick(nil); Settings.SaveSettings; Settings.LoadSettings;
        Require(Settings.DefaultScript = ExpectedDefault,'Deleting a script persisted an incorrect ScriptIndex');
        if ExpectedDefault > 0 then
          Require(Settings.Scripts[ExpectedDefault - 1].Title = 'Script ' + IntToStr(DefaultChoice - 1),
            'Profile reload changed the default command identity');
      end;
    Writeln('PASS settings delete boundaries cover no selection, Standard, first/middle/last default and every removed row with profile reload (20 combinations)');
  finally
    Probe.Free; Form.Free;
    Settings.Scripts.Assign(SavedScripts); SavedScripts.Free;
    Settings.DefaultScript := SavedDefault; Settings.ProgramUpdateMinutes := SavedMinutes;
    Settings.CheckUpdate := SavedChecks; Settings.SaveSettings;
    SetMHLTheme(SavedTheme);
  end;
end;
