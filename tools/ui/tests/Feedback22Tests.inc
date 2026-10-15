// Owned temporary fixtures only. The external command is this same test EXE,
// which records literal arguments and exits before loading any user profile.
procedure RunExternalToolProbe;
var Data: TJSONObject; Args: TJSONArray; Target: string;
begin
  Target := ParamStr(2);
  Require(SameFileName(ExtractFilePath(Target), ExtractFilePath(ParamStr(0))),
    'External probe output escaped its isolated runtime');
  Data := TJSONObject.Create; Args := TJSONArray.Create;
  try
    Data.AddPair('cwd', GetCurrentDir); Data.AddPair('args', Args);
    for var I := 3 to ParamCount do Args.Add(ParamStr(I));
    TFile.WriteAllText(Target + '.pending', Data.ToJSON, TEncoding.UTF8);
    TFile.Move(Target + '.pending', Target);
  finally Data.Free; end;
end;

procedure PrepareFeedback22Scripts;
var ToolExe, ToolResult: string;
begin
  Settings.Scripts.Clear;
  Settings.Scripts.Add('Legacy export', '%COPY%', '%FILENAME%');
  ToolExe := Settings.AppPath + 'Инструмент ё.exe'; ToolResult := Settings.AppPath + 'tool-result.json';
  // Launching another unsigned PE is opt-in; the normal regression batch
  // verifies settings, routing and UI without invoking reputation checks.
  if ParamStr(2) = 'probe' then TFile.Copy(ParamStr(0), ToolExe);
  Settings.Scripts.Add('Создать online INPX', ToolExe,
    'external-tool-probe "' + ToolResult + '" "сложный аргумент ё" alpha beta', True);
  Settings.SaveSettings; Settings.LoadSettings;
end;

procedure TestFeedback22(const One: IBookCollection; OneID: Integer);
var Store, Other: TAuthorFavorites; Descriptor: TAuthorFavoriteCollection;
  RealFolder, AliasFolder, Catalogue, BeforeHash: string;
  Toggle, FavoriteToggle, ToolsMenu: TMenuItem; Node: PVirtualNode; Author: PAuthorData;
  FullName, Display: string; ID: Integer; OriginalStyle: Boolean;
  SettingsForm: TfrmSettings; Editor: TfrmEditScript; ToolResult, ToolExe: string;
  Probe: TJSONObject; ProbeArgs: TJSONArray; Deadline: TStopwatch; Script: TScriptDesc;
  Presets, Reopened: TSearchPresets; PresetFile, RawValue: string;
begin
  Presets := TSearchPresets.Create; Reopened := TSearchPresets.Create;
  try
    RawValue := '  & <граница> ]]> 中文 ' + #$D83D + #$DE00 + #10 + 'вторая строка  ';
    Presets.GetPreset('Читаемый XML ё').AddOrSetValue(SF_AUTHORS, '="Alpha Alex" OR ="Кинг Стивен"');
    Presets[0].AddOrSetValue(SF_TITLE, RawValue);
    for var Extension in TArray<string>.Create('.xml', '.cxml2', '.cxml') do
    begin
      PresetFile := Settings.AppPath + 'readable-preset' + Extension;
      Presets.Save(PresetFile); Reopened.Clear; Reopened.Load(PresetFile);
      Require((Reopened.Count = 1) and (Reopened[0].DisplayName = 'Читаемый XML ё') and
        (Reopened[0].Count = 2) and (Reopened[0].Items[SF_TITLE] = RawValue) and
        (Reopened[0].Items[SF_AUTHORS] = '="Alpha Alex" OR ="Кинг Стивен"'),
        'Readable preset serialization lost a field, whitespace, CDATA marker or Unicode');
      if Extension = '.xml' then
        Require(TFile.ReadAllText(PresetFile, TEncoding.UTF8).Contains('</Field>'+#13#10),
          'Editable XML has no line break after a field');
    end;
  finally Reopened.Free; Presets.Free; end;
  Writeln('PASS feedback22 readable XML preserves field values, CDATA, Unicode and legacy compressed import');

  RealFolder := Settings.AppPath + 'favorite-real' + PathDelim;
  AliasFolder := Settings.AppPath + 'favorite-alias' + PathDelim;
  Require(GetFileAttributes(PChar(ExcludeTrailingPathDelimiter(AliasFolder))) and
    FILE_ATTRIBUTE_REPARSE_POINT <> 0, 'Favorite regression requires an actual junction');
  Catalogue := RealFolder + 'catalogue.sqlite'; AFRCreateCatalogue(Catalogue);
  BeforeHash := THashSHA2.GetHashStringFromFile(Catalogue);
  Store := TAuthorFavorites.Create(AliasFolder + AUTHOR_FAVORITES_FILE_NAME);
  try
    Store.SetFavorite('Кинг', 'Стивен', '', True);
    Descriptor := Default(TAuthorFavoriteCollection); Descriptor.ID := OneID;
    Descriptor.DatabaseFile := AliasFolder + 'catalogue.sqlite'; Descriptor.RootFolder := AliasFolder;
    Descriptor.LibraryNamespace := 'flibusta'; Descriptor.Revision := 'junction test';
    Store.RefreshCollection(Descriptor);
    Require(Store.State(OneID, AuthorFavoriteKey('Кинг', 'Стивен', '')).BookCount = 2,
      'Favorite refresh cannot read a catalogue below a junction');
    Other := TAuthorFavorites.Create(RealFolder + AUTHOR_FAVORITES_FILE_NAME);
    try
      Require(Other.IsFavorite('Кинг', 'Стивен', ''), 'Real profile lost the author added through a junction');
      Other.SetFavorite('Мартин', 'Джордж', 'Р.Р.', True); Store.Reload;
      Require(Store.IsFavorite('Мартин', 'Джордж', 'Р.Р.'), 'Junction alias does not see the same profile');
    finally Other.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Catalogue) = BeforeHash, 'Favorite refresh modified the source catalogue');
  finally Store.Free; end;
  Writeln('PASS feedback22 favorite profile and readonly catalogue work below a real directory junction');

  ShowPage(PAGE_AUTHORS); Node := frmMain.tvAuthors.FocusedNode;
  Require(Assigned(Node), 'Author display fixture has no selected author');
  Author := frmMain.tvAuthors.GetNodeData(Node); FullName := Author^.GetFullName; ID := Author^.AuthorID;
  Toggle := frmMain.FindComponent('miAuthorInitials') as TMenuItem;
  FavoriteToggle := frmMain.FindComponent('miAuthorInitialsFavorite') as TMenuItem;
  Require(Assigned(Toggle) and Assigned(FavoriteToggle), 'Author display setting is absent');
  OriginalStyle := Settings.AuthorInitials;
  try
    if not Settings.AuthorInitials then Toggle.OnClick(Toggle);
    Display := ''; frmMain.tvAuthors.OnGetText(frmMain.tvAuthors, Node, 0, ttNormal, Display);
    Require((Display = 'Alpha A.') and Toggle.Checked and FavoriteToggle.Checked,
      'Author initials do not match the card or the two setting menus');
    Require((Author^.GetFullName = FullName) and (Author^.AuthorID = ID), 'Display setting changed author identity');
    frmMain.edFFullName.Text := ''; frmMain.miAddToSearchClick(nil);
    Require(frmMain.edFFullName.Text = '="' + FullName + '"', 'Add to Search copied initials instead of the full author');
    frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
    Settings.LoadSettings; Require(Settings.AuthorInitials, 'Author display setting was not saved');
  finally
    if Settings.AuthorInitials <> OriginalStyle then Toggle.OnClick(Toggle);
    frmMain.DoClearFilter(True);
  end;
  Writeln('PASS feedback22 author initials preserve raw names, IDs, exact search and persisted setting');

  ToolExe := Settings.AppPath + 'Инструмент ё.exe'; ToolResult := Settings.AppPath + 'tool-result.json';
  Require((Settings.Scripts.Count = 2) and not Settings.Scripts[0].Standalone and Settings.Scripts[1].Standalone,
    'Script save/reload changed legacy export or lost the standalone mode');
  Script := TScriptDesc.Create(nil);
  try Script.Assign(Settings.Scripts[1]); Require(Script.Standalone, 'Script assignment lost standalone mode');
  finally Script.Free; end;
  SettingsForm := TfrmSettings.Create(nil);
  try
    SettingsForm.LoadSetting;
    Require((NativeInt(SettingsForm.lvScripts.Items[1].Data) = 1) and
      (SettingsForm.lvScripts.Items[1].SubItems[2] = 'Инструмент'), 'Settings list lost tool mode');
  finally SettingsForm.Free; end;
  Editor := TfrmEditScript.Create(nil);
  try
    Editor.Standalone := True; Require(Editor.cbStandalone.Checked, 'Script editor lost tool mode');
    for var PPI in TArray<Integer>.Create(96, 144, 192) do
    begin
      Editor.ScaleForPPI(PPI);
      Require(Editor.cbStandalone.BoundsRect.Bottom <= Editor.lblStandalone.Top, 'Script editor checkbox overlaps description');
      Require(Editor.lblStandalone.BoundsRect.Bottom <= Editor.pnButtons.Top, 'Script editor description overlaps buttons');
    end;
    if ParamStr(2) = 'visual' then
    begin
      SetMHLTheme(True); Application.ProcessMessages;
      Editor.Title := 'Создать online INPX'; Editor.Path := ToolExe; Editor.Params := '--пример "путь с пробелами"';
      Writeln('VISUAL standalone script editor at 200% DPI'); Flush(Output);
      Editor.ShowModal;
    end;
  finally Editor.Free; end;
  // The real form builds its menus from the script configuration prepared
  // before construction; this mode never opens a settings modal.
  ToolsMenu := frmMain.FindComponent('miExternalTools') as TMenuItem;
  Require(Assigned(ToolsMenu) and (ToolsMenu.Count = 2) and
    (ToolsMenu.Items[0].Caption = 'Создать online INPX'), 'Actual standalone tool menu is absent');
  Require((frmMain.FindComponent('btnExternalTools') as TToolButton).Visible, 'Configured tool has no toolbar button');
  Require(not frmMain.pmiScripts.Items[frmMain.pmiScripts.Count - 1].Caption.Contains('online INPX'),
    'Standalone tool leaked into book export');
  Writeln('PASS feedback22 standalone tools preserve old scripts, settings, menus and editor DPI layout');
  if ParamStr(2) <> 'probe' then Exit;
  frmMain.tvBooksA.Clear; // No selected book and no export destination are needed.
  ToolsMenu.Items[0].OnClick(ToolsMenu.Items[0]); Deadline := TStopwatch.StartNew;
  while not FileExists(ToolResult) and (Deadline.ElapsedMilliseconds < 10000) do
  begin Application.ProcessMessages; Sleep(10); end;
  Require(FileExists(ToolResult), 'Standalone tool did not run without a selected book');
  Probe := TJSONObject.ParseJSONValue(TFile.ReadAllText(ToolResult, TEncoding.UTF8)) as TJSONObject;
  try
    Require(Assigned(Probe), 'Standalone probe output is malformed');
    Require(SameFileName(IncludeTrailingPathDelimiter(Probe.GetValue<string>('cwd')), Settings.AppPath),
      'Standalone tool has the wrong working directory');
    ProbeArgs := Probe.GetValue<TJSONArray>('args');
    Require((ProbeArgs.Count = 3) and (ProbeArgs.Items[0].Value = 'сложный аргумент ё') and
      (ProbeArgs.Items[1].Value = 'alpha') and (ProbeArgs.Items[2].Value = 'beta'),
      'Standalone launch changed argument quoting, spaces or Unicode');
  finally Probe.Free; end;
  Writeln('PASS feedback22 actual standalone launch preserves Unicode arguments and working directory without book export');
end;
