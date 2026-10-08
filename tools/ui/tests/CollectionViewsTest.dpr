program CollectionViewsTest;

{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses
  NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils, System.IniFiles, Winapi.Windows, Winapi.Messages, Winapi.RichEdit,
  Vcl.Forms, Vcl.Graphics, Vcl.Menus, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Controls, Vcl.StdCtrls,
  VirtualTrees, BookTreeView, BookInfoPanel, unit_UpdateNotes,
  unit_Globals, unit_Consts, unit_Interfaces, unit_Localization, unit_TreeUtils, unit_Settings,
  unit_MHLArchiveHelpers, unit_ExportToDeviceThread,
  dm_user, dm_Images, frm_splash, frm_main, frm_genre_tree, unit_PublisherSeriesView,
  frm_ProgramUpdate, frm_settings, unit_ProgramUpdates, unit_ComponentUpdates, unit_ProgramUpdateInstaller,
  frm_ImportProgressFormEx, unit_IndexPublisherSeriesThread;

type
  TRegressionExceptionHandler = class
    procedure HandleException(Sender: TObject; E: Exception);
  end;

procedure TRegressionExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  // VCL otherwise displays a modal dialog inside form/event construction,
  // hiding the cause from a console runner until its timeout.
  Writeln('FAIL VCL ', E.ClassName, ': ', E.Message);
  Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
  Flush(Output);
  Halt(1);
end;

procedure Require(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(Message);
end;

var
  CleanupExitTemp, CleanupExitPersistent, CleanupExitSource: string;

procedure TestUpdateDefaults;
var Ini: TMemIniFile; Loaded: TMHLSettings;
begin
  Ini := TMemIniFile.Create(Settings.SettingsFileName, TEncoding.UTF8);
  try
    Ini.DeleteKey('SYSTEM', 'CheckUpdates');
    Ini.DeleteKey('SYSTEM', 'ProgramUpdateMinutes');
    Ini.UpdateFile;
    Loaded := TMHLSettings.Create;
    try
      Loaded.LoadSettings;
      Require(Loaded.CheckUpdate and (Loaded.ProgramUpdateMinutes = 4320),
        'Fresh profile must check every three days');
    finally Loaded.Free; end;
    Ini.WriteBool('SYSTEM', 'CheckUpdates', False);
    Ini.WriteInteger('SYSTEM', 'ProgramUpdateMinutes', 60);
    Ini.UpdateFile;
    Loaded := TMHLSettings.Create;
    try
      Loaded.LoadSettings;
      Require(not Loaded.CheckUpdate and (Loaded.ProgramUpdateMinutes = 60),
        'Explicit Never and interval must survive defaults');
    finally Loaded.Free; end;
  finally Ini.Free; end;
  Writeln('PASS new update default is three days and preserves explicit choices');
end;

procedure TestProgramUpdateUI;
var Popup: TfrmProgramUpdate; Configuration: TfrmSettings; ReleaseInfo, Parsed: TProgramRelease;
  ComponentID, SQLiteArch: string; NotesView: TUpdateNotesView;
  I, HeightBefore, BodyBefore, SavedWidth, SavedHeight: Integer; Notes, PreviousEditor: TRichEdit;
  Primary: TButton; Version, Bytes: TLabel; Selector, ReloadedSelector: TComboBox;
  Previous, Failed: TComponentReleases; Cache: string; Reloaded: TfrmProgramUpdate;
  ReloadedView: TUpdateNotesView; EndPoint: TPoint;
begin
  TestUpdateDefaults;
  Configuration := TfrmSettings.Create(nil);
  try
    Require(Configuration.cbProgramInterval.Items[0] = 'Никогда', 'Never option missing');
    Configuration.cbProgramInterval.ItemIndex := 8; Configuration.ProgramIntervalChanged(nil);
    Require(Configuration.edProgramInterval.Visible and Configuration.cbProgramIntervalUnit.Visible,
      'Custom interval controls missing');
    Configuration.edProgramInterval.Text := '17'; Configuration.cbProgramIntervalUnit.ItemIndex := 1;
    Configuration.SaveSettingsClick(nil);
    Require(Settings.CheckUpdate and (Settings.ProgramUpdateMinutes = 1020), 'Custom hours not saved');
    Configuration.cbProgramInterval.ItemIndex := 0; Configuration.SaveSettingsClick(nil);
    Require(not Settings.CheckUpdate, 'Never does not disable checking');
    Settings.SaveSettings;
  finally Configuration.Free; end;
  Writeln('PASS update settings preserve never and custom hours');
  Popup := TfrmProgramUpdate.Create(nil);
  try
    NotesView := nil; Notes := nil; Primary := nil; Version := nil; Bytes := nil; Selector := nil;
    for I := 0 to Popup.ControlCount - 1 do
    begin
      if Popup.Controls[I] is TUpdateNotesView then
      begin NotesView := TUpdateNotesView(Popup.Controls[I]); Notes := NotesView.PrimaryNotes; end;
      if Popup.Controls[I] is TComboBox then Selector := TComboBox(Popup.Controls[I]);
      if (Popup.Controls[I] is TButton) and TButton(Popup.Controls[I]).Default then Primary := TButton(Popup.Controls[I]);
      if (Popup.Controls[I] is TLabel) and (Pos('Текущая', TLabel(Popup.Controls[I]).Caption) = 1) then Version := TLabel(Popup.Controls[I]);
      if (Popup.Controls[I] is TLabel) and (Popup.Controls[I].Top > 400) then Bytes := TLabel(Popup.Controls[I]);
    end;
    Require(Assigned(Notes) and Assigned(Primary) and Assigned(Version) and Assigned(Bytes), 'Popup controls incomplete');
    Require(Pos(PROGRAM_RELEASE_VERSION, Version.Caption) > 0, 'Installed version missing');
    Require(Assigned(Selector) and (Selector.Items.Count = 3), 'Separate component choices missing');
    Require(Selector.Items[1].StartsWith('SQLite:') and Selector.Items[2].StartsWith('SumatraPDF:'),
      'Component selection must skip AlReader and retain SumatraPDF');
    Selector.ItemIndex := 1; Selector.OnChange(Selector);
    Require((Pos('3.53.4', NotesView.SectionHeader(0).Caption) > 0) and
      (Pos('Исправлены', Notes.Text) > 0), 'Installed component changelog missing');
    Require(Primary.Caption = 'Проверить компонент', 'Component check missing');
    Selector.ItemIndex := 0; Selector.OnChange(Selector);
    ReleaseInfo := Default(TProgramRelease); ReleaseInfo.Tag := '2.7.0_pre5.12';
    // GitHub and bundled Markdown may use Unix line breaks; the Windows memo
    // must retain separate heading and bullet lines when displaying them.
    ReleaseInfo.Changelog := '2.7.0_pre5.12' + #10 + 'Новые изменения' + #10#10 + '- Первый пункт';
    ReleaseInfo.History := ReleaseInfo.Changelog + sLineBreak + PROGRAM_RELEASE_VERSION;
    ReleaseInfo.DownloadURL := 'https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.12/HomeLibRu.zip';
    Popup.SetRelease(ReleaseInfo);
    Require(Primary.Enabled and (Primary.Caption = 'Скачать обновление'), 'New release download button missing');
    Require(Pos('Новые изменения', Notes.Text) > 0, 'Changelog missing');
    Require((Notes.Lines.Count >= 3) and (Pos('2.7.0_pre5.12', NotesView.SectionHeader(0).Caption) > 0) and
      (Notes.Lines[0] = 'Новые изменения') and (Pos('Первый пункт', Notes.Lines[2]) > 0),
      'Unix changelog line breaks collapsed in Windows memo');
    Require((NotesView.SectionCount = 2) and not NotesView.IsExpanded(1) and
      (Pos(PROGRAM_RELEASE_VERSION, NotesView.SectionHeader(1).Caption) > 0),
      'New update hides installed-version history');
    ReleaseInfo.History := '';
    ReleaseInfo.Changelog := '2.7.0_pre5.12' + #10 + '## Исправления' + #10 +
      '- **Переходы** по ссылкам' + #10 + '  - Дочерний пункт' + #10#10 +
      '2.7.0_pre5.11' + #10 + 'Текст {\rtf1} и кириллица ← ↔';
    Popup.SetRelease(ReleaseInfo);
    Require((fsBold in NotesView.SectionHeader(0).Font.Style) and
      (NotesView.SectionHeader(0).Font.Size > Notes.Font.Size),
      'Release heading is not emphasized');
    Notes.SelStart := Pos('Исправления', Notes.Text) - 1; Notes.SelLength := Length('Исправления');
    Require(fsBold in Notes.SelAttributes.Style, 'Markdown section heading is not bold');
    Notes.SelStart := Pos('Дочерний пункт', Notes.Text) - 1; Notes.SelLength := 1;
    Require(Notes.Paragraph.LeftIndent > 0, 'Nested list lost its indentation');
    Require((Pos('**', Notes.Text) = 0) and (Pos('{\rtf1}', NotesView.SectionNotes(1).Text) > 0) and
      (Pos('кириллица ← ↔', NotesView.SectionNotes(1).Text) > 0), 'Markdown or Unicode/RTF escaping is broken');
    Require((NotesView.SectionCount = 2) and
      (Pos('2.7.0_pre5.11', NotesView.SectionHeader(1).Caption) > 0), 'Second release was lost');
    Require(NotesView.IsExpanded(0) and not NotesView.IsExpanded(1) and
      not NotesView.SectionNotes(1).Visible, 'Previous changelog is not collapsed initially');
    NotesView.SectionHeader(1).OnClick(NotesView.SectionHeader(1));
    Require(NotesView.IsExpanded(0) and NotesView.IsExpanded(1) and
      NotesView.SectionNotes(1).Visible, 'Previous changelog cannot be expanded independently');
    NotesView.SectionHeader(1).OnClick(NotesView.SectionHeader(1));
    Require(not NotesView.IsExpanded(1), 'Previous changelog cannot be collapsed again');
    Writeln('PASS previous changelogs start collapsed and can be expanded independently');
    ReleaseInfo.Changelog := SQLiteNotesToMarkdown('<ol><li>Fix the bug.' + #10 +
      '<li>New SQL language features:<ol><li>Nested   item' + #10 +
      ' continuation &amp; &harr;</ol></ol><p><b>Hashes:</b><ol><li>SHA3: abc</ol>');
    Require((Pos('  - Nested item continuation & ↔', ReleaseInfo.Changelog) > 0) and
      (Pos('## Hashes:', ReleaseInfo.Changelog) > 0), 'SQLite HTML hierarchy or whitespace lost');
    Popup.SetRelease(ReleaseInfo);
    Notes.SelStart := Pos('New SQL language features:', Notes.Text) - 1;
    Notes.SelLength := Length('New SQL language features:');
    Require(fsBold in Notes.SelAttributes.Style, 'SQLite subsection is not emphasized');
    Writeln('PASS update notes retain nested SQLite lists, headings and safe Unicode text');
    Require(ReleaseNotesHeading('3.53.0', '2026-04-09T00:00:00Z') =
      '3.53.0 — 09.04.2026', 'Release date missing');
    Require((ReleaseNotesHeading('3.53.0', '') = '3.53.0') and
      (ReleaseNotesHeading('3.53.0', '2026-02-30') = '3.53.0'), 'Unknown or invalid date was invented');
    Require(ParseProgramReleases('[{"tag_name":"2.7.0_pre9.99","draft":false,' +
      '"published_at":"2026-10-07T12:00:00Z","body":"## Изменения\n- Первый пункт",' +
      '"assets":[{"name":"HomeLibRu.zip"}]}]', Parsed), 'Application date fixture failed');
    Require((Pos('2.7.0_pre9.99 — 07.10.2026', Parsed.Changelog) > 0) and
      (Pos('2.7.0_pre9.99 — 07.10.2026', Parsed.History) > 0), 'Application history omitted its date');
{$IFDEF WIN64}
    SQLiteArch := 'x64';
{$ELSE}
    SQLiteArch := 'x86';
{$ENDIF}
    Require(ParseSQLiteDownload('PRODUCT,3.53.0,2026/sqlite-dll-win-' + SQLiteArch +
      '-3530000.zip,2000000,' + StringOfChar('a', 64),
      '<h3>2026-04-09 (3.53.0)</h3><ol><li>New SQL language features:' +
      '<ol><li>Nested feature</ol></ol><h3>2026-03-06 (3.52.0)</h3><ol><li>Old feature</ol>', Parsed),
      'SQLite dated changelog fixture failed');
    Require((Pos('3.53.0 — 09.04.2026', ComponentChanges(Parsed, '3.52.0')) > 0) and
      (Pos('Old feature', ComponentChanges(Parsed, '3.52.0')) = 0), 'SQLite missed releases or dates are wrong');
    Require(ParseSumatraReleases('[{"tag_name":"3.6.1rel","published_at":"2026-01-15T12:00:00Z",' +
      '"body":"## Bugfixes\n- First fix\n  - Nested detail"}]', Parsed), 'Sumatra dated changelog fixture failed');
    Require(Pos('3.6.1 — 15.01.2026', ComponentChanges(Parsed, '3.6.0')) > 0,
      'Sumatra changelog omitted its date');
    for ComponentID in COMPONENT_IDS do
    begin
      ReleaseInfo.ComponentID := ComponentID; ReleaseInfo.ComponentVersion := '3.53.0';
      ReleaseInfo.PublishedAt := '2026-04-09';
      ReleaseInfo.Changelog := ReleaseNotesHeading('3.53.0', ReleaseInfo.PublishedAt) + #10 +
        '## Изменения' + #10 + '- **Исправление**' + #10 + '  - Дочерний пункт' + #10#10 +
        ReleaseNotesHeading('3.52.0', '2026-03-06') + #10 + '- Прежний выпуск';
      Popup.SetRelease(ReleaseInfo);
      Require((Pos('3.53.0 — 09.04.2026', NotesView.SectionHeader(0).Caption) > 0) and
        (fsBold in NotesView.SectionHeader(0).Font.Style) and
        (NotesView.SectionHeader(0).Font.Size > Notes.Font.Size),
        ComponentID + ' dated heading is not emphasized');
      Notes.SelStart := Pos('Дочерний пункт', Notes.Text) - 1; Notes.SelLength := 1;
      Require(Notes.Paragraph.LeftIndent > 0, ComponentID + ' nested list is flat');
    end;
    ReleaseInfo.ComponentID := ''; ReleaseInfo.PublishedAt := '';
    Writeln('PASS dates and shared formatting cover application and every component');

    ReleaseInfo.History := '2.7.0_pre5.12' + sLineBreak;
    for I := 1 to 100 do ReleaseInfo.History := ReleaseInfo.History +
      '- Строка ' + IntToStr(I) + ' длинного журнала изменений' + sLineBreak;
    ReleaseInfo.History := ReleaseInfo.History + '2.7.0_pre5.11' + sLineBreak + '- Старый выпуск';
    Popup.SetRelease(ReleaseInfo);
    Require((Popup.BorderStyle = bsSizeable) and (biMaximize in Popup.BorderIcons), 'Update window cannot resize/maximize');
    HeightBefore := NotesView.Height; Popup.ClientHeight := Popup.ClientHeight + 80;
    Require((NotesView.Height > HeightBefore + 60) and (NotesView.Height > Popup.ClientHeight div 2),
      'Reading area does not use the available window space');
    Require(Notes.ScrollBars = ssNone, 'Individual release traps scrolling');
    Require(Notes.Height > NotesView.ClientHeight, 'Long release text is clipped instead of fully laid out');
    Notes.Perform(WM_MOUSEWHEEL, WPARAM($FF880000), 0);
    Require(NotesView.VertScrollBar.Position > 0, 'Wheel over text cannot scroll across release history');
    NotesView.SetExpanded(1, True); PreviousEditor := NotesView.SectionNotes(1);
    PreviousEditor.Perform(WM_MOUSEWHEEL, WPARAM($00780000), 0);
    Require(NotesView.VertScrollBar.Position = 0, 'Wheel over a previous release does not reach the common scrollbar');
    BodyBefore := Notes.Height;
    Notes.Perform(WM_MOUSEWHEEL, WPARAM($00780008), 0);
    Require((NotesView.ZoomPercent = 110) and (Notes.Height > BodyBefore), 'Ctrl-wheel does not enlarge/reflow text');
    NotesView.Load(ReleaseInfo.History);
    Require((NotesView.SectionNotes(1) = PreviousEditor) and NotesView.IsExpanded(1),
      'Unchanged history is recreated, losing expansion and causing flicker');
    NotesView.ZoomPercent := 100;
    Writeln('PASS update window expands reading space, reflows zoom and scrolls continuously across releases');

    Popup.Show; Application.ProcessMessages;
    NotesView.VertScrollBar.Position := 1000;
    NotesView.SetExpanded(1, False); NotesView.SetExpanded(1, True);
    Require(NotesView.SectionNotes(1).Height < MulDiv(70, Notes.CurrentPPI, 96),
      'Scrolled short release has blank height: ' + IntToStr(NotesView.SectionNotes(1).Height));
    // Short releases must shrink after a long document and remain compact
    // across repeated layout, expansion and zoom changes.
    NotesView.Load('3.51.1 — 28.11.2025' + sLineBreak +
      '- First fix' + sLineBreak + '- Second fix' + sLineBreak +
      '## Hashes:' + sLineBreak + '- SQLITE_SOURCE_ID: abc' + sLineBreak +
      '- SHA3: def' + sLineBreak + '3.51.0 — 04.11.2025' + sLineBreak +
      '- Another short release');
    Require(Notes.Height < MulDiv(180, Notes.CurrentPPI, 96),
      'Short release retains blank height from previous long text: ' + IntToStr(Notes.Height));
    BodyBefore := Notes.Height;
    for I := 1 to 20 do
    begin
      Popup.ClientHeight := Popup.ClientHeight + 8;
      Popup.ClientHeight := Popup.ClientHeight - 8;
      NotesView.SetExpanded(1, True); NotesView.SetExpanded(1, False);
    end;
    Require(Abs(Notes.Height - BodyBefore) <= 1,
      'Repeated layout accumulates blank space: ' + IntToStr(BodyBefore) + ' -> ' + IntToStr(Notes.Height));
    NotesView.SetExpanded(1, True);
    Require(NotesView.SectionNotes(1).Height < MulDiv(70, Notes.CurrentPPI, 96),
      'Previous short release has excessive blank space');
    NotesView.ZoomPercent := 200; NotesView.ZoomPercent := 80; NotesView.ZoomPercent := 100;
    Require(Abs(Notes.Height - BodyBefore) <= 1, 'Zoom down does not shrink the document');
    Popup.ClientWidth := Popup.ClientWidth - 180; Popup.ClientWidth := Popup.ClientWidth + 180;
    Require(Abs(Notes.Height - BodyBefore) <= 1, 'Width reflow retains blank space');
    NotesView.Load('3.51.1 — 28.11.2025' + sLineBreak + '- Short release' + sLineBreak +
      '3.51.0 — 04.11.2025' + sLineBreak + Copy(ReleaseInfo.History,
      Pos(sLineBreak, ReleaseInfo.History) + Length(sLineBreak), MaxInt));
    NotesView.SetExpanded(1, True); PreviousEditor := NotesView.SectionNotes(1);
    Application.ProcessMessages;
    EndPoint := Point(0, 0);
    PreviousEditor.Perform(WM_USER + 38, WPARAM(@EndPoint), PreviousEditor.GetTextLen - 1);
    Writeln('TRACE expanded old release height ', PreviousEditor.Height, ' last line ', EndPoint.Y);
    Require((EndPoint.Y > 0) and (PreviousEditor.Height - EndPoint.Y < MulDiv(60, Notes.CurrentPPI, 96)),
      'Expanded previous release has blank space after its last line');
    Writeln('PASS expanded old release ends directly after its text');
    Writeln('PASS short release height stays compact after long text, resize, expansion and zoom');
    Popup.Hide;
    NotesView.Load(ReleaseInfo.History);

    Cache := ProgramUpdateCache(Settings.AppPath);
    Previous := Default(TComponentReleases);
    Previous[0].History := '3.53.4' + sLineBreak + '- Сохранённое описание SQLite';
    Previous[2].History := '3.6.1' + sLineBreak + '- Сохранённое описание SumatraPDF';
    Failed := Default(TComponentReleases); Failed[0].ComponentError := 'Проверка не удалась';
    PreserveComponentHistory(Failed, Previous);
    Require((Failed[0].History = Previous[0].History) and (Failed[0].DownloadURL = '') and
      (Failed[0].ComponentError <> ''), 'Failed check erases history or revives stale download metadata');
    SaveComponentHistory(Cache, Failed);
    Failed := Default(TComponentReleases); LoadComponentHistory(Cache, Failed);
    Require(Failed[2].History = Previous[2].History, 'Saved component history not reloaded');
    Popup.RememberHistory(ReleaseInfo);
    Reloaded := TfrmProgramUpdate.Create(nil);
    try
      ReloadedView := nil; ReloadedSelector := nil;
      for I := 0 to Reloaded.ControlCount - 1 do
      begin
        if Reloaded.Controls[I] is TUpdateNotesView then ReloadedView := TUpdateNotesView(Reloaded.Controls[I]);
        if Reloaded.Controls[I] is TComboBox then ReloadedSelector := TComboBox(Reloaded.Controls[I]);
      end;
      Require(Pos('длинного журнала', ReloadedView.PrimaryNotes.Text) > 0, 'Application history missing before network check');
      ReloadedSelector.ItemIndex := 2; ReloadedSelector.OnChange(ReloadedSelector);
      Require(Pos('Сохранённое описание SumatraPDF', ReloadedView.PrimaryNotes.Text) > 0,
        'Cached component history missing before network check');
      Reloaded.CheckFailed('Сеть недоступна');
      Require(Pos('Сохранённое описание', ReloadedView.PrimaryNotes.Text) > 0, 'Manual failure clears cached text');
      Reloaded.ClientWidth := MulDiv(1000, Reloaded.CurrentPPI, 96);
      Reloaded.ClientHeight := MulDiv(760, Reloaded.CurrentPPI, 96);
      ReloadedView.ZoomPercent := 140;
      SavedWidth := MulDiv(Reloaded.ClientWidth, 96, Reloaded.CurrentPPI);
      SavedHeight := MulDiv(Reloaded.ClientHeight, 96, Reloaded.CurrentPPI);
    finally Reloaded.Free; end;
    Reloaded := TfrmProgramUpdate.Create(nil);
    try
      ReloadedView := nil;
      for I := 0 to Reloaded.ControlCount - 1 do
        if Reloaded.Controls[I] is TUpdateNotesView then ReloadedView := TUpdateNotesView(Reloaded.Controls[I]);
      Require((Abs(MulDiv(Reloaded.ClientWidth, 96, Reloaded.CurrentPPI) - SavedWidth) <= 1) and
        (Abs(MulDiv(Reloaded.ClientHeight, 96, Reloaded.CurrentPPI) - SavedHeight) <= 1),
        'Resized update window was not restored from disk');
      Require(Assigned(ReloadedView) and (ReloadedView.ZoomPercent = 140), 'Text zoom was not restored from disk');
    finally Reloaded.Free; end;
    Writeln('PASS resized update window and text zoom survive reopening from disk');
    Require(ParseProgramReleases('[{"tag_name":"2.7.0_pre5.11","draft":false,"body":"",' +
      '"assets":[{"name":"HomeLibRu.zip"}]}]', Parsed) and
      (Pos('Автор не опубликовал', Parsed.History) > 0), 'Empty author release mistaken for unloaded history');
    Writeln('PASS saved histories survive reopening and network failure; empty author notes are explained');

    Require(Bytes.Caption = '', 'No download must happen before the click');
    Popup.BeginCheck; Popup.SetCurrent(ReleaseInfo);
    Require(Primary.Enabled and (Primary.Caption = 'Проверить ещё раз'), 'No-update check is not retryable');
    Popup.CheckFailed('Не удалось проверить');
    Require(Primary.Enabled and (Primary.Caption = 'Повторить проверку'), 'Manual failure is not retryable');
    // Optional local preview for Computer Use, only inside the guarded fixture runtime.
    if FileExists(Settings.AppPath + 'notes-preview.html') then
    begin
      ReleaseInfo.History := '';
      ReleaseInfo.Changelog := ReleaseNotesHeading('3.53.0', '2026-04-09') + sLineBreak + SQLiteNotesToMarkdown(
        TFile.ReadAllText(Settings.AppPath + 'notes-preview.html', TEncoding.UTF8)) +
        sLineBreak + sLineBreak + ReleaseNotesHeading('3.52.0', '2026-03-06') + sLineBreak + '## Предыдущий выпуск' +
        sLineBreak + '- Пример отдельного выпуска';
      if FileExists(Settings.AppPath + 'notes-preview-history.txt') then
        ReleaseInfo.Changelog := TFile.ReadAllText(Settings.AppPath + 'notes-preview-history.txt', TEncoding.UTF8);
      Popup.SetRelease(ReleaseInfo); Popup.Hide; Popup.ShowModal;
    end;
  finally Popup.Free; end;
  Writeln('PASS update popup shows installed version and changelog without automatic download');
end;

procedure TestProgramUpdateDownload;
var Popup, OwnedPopup: TfrmProgramUpdate; Info: TProgramRelease;
  Primary, Later: TButton; Notes: TRichEdit; Bytes: TLabel; Bar: TProgressBar;
  I: Integer; Deadline: UInt64; ReadyFile: string;
  procedure Controls;
  var J: Integer;
  begin
    Primary := nil; Later := nil; Notes := nil; Bytes := nil; Bar := nil;
    for J := 0 to Popup.ControlCount - 1 do
    begin
      if Popup.Controls[J] is TUpdateNotesView then Notes := TUpdateNotesView(Popup.Controls[J]).PrimaryNotes;
      if Popup.Controls[J] is TProgressBar then Bar := TProgressBar(Popup.Controls[J]);
      if (Popup.Controls[J] is TLabel) and (Popup.Controls[J].Top > 400) then Bytes := TLabel(Popup.Controls[J]);
      if Popup.Controls[J] is TButton then
      begin
        if TButton(Popup.Controls[J]).Default then Primary := TButton(Popup.Controls[J]);
        if TButton(Popup.Controls[J]).Caption = 'Позже' then Later := TButton(Popup.Controls[J]);
      end;
    end;
    Require(Assigned(Primary) and Assigned(Later) and Assigned(Notes) and Assigned(Bytes) and Assigned(Bar), 'Update controls missing');
  end;
begin
  Require(ParamCount = 4, 'Update test requires loopback URL, size and checksum');
  Require(ParamStr(2).StartsWith('http://127.0.0.1:'), 'Update test must use loopback');
  Popup := TfrmProgramUpdate.Create(nil);
  try
    Controls;
    Info := Default(TProgramRelease); Info.Tag := '2.7.0_pre5.13';
    Info.DownloadURL := ParamStr(2); Info.Size := StrToInt64(ParamStr(3)); Info.SHA256 := ParamStr(4);
    Info.Changelog := 'Новые изменения тестового выпуска'; Popup.SetRelease(Info);
    Require(Bytes.Caption = '', 'Unexpected automatic download');
    Primary.Click;
    Require(not Primary.Enabled and (Later.Caption = 'Отменить'), 'Download did not enter cancellable state');
    Deadline := GetTickCount64 + 30000;
    repeat Application.ProcessMessages; Sleep(10);
    until Primary.Enabled or (GetTickCount64 > Deadline);
    Require(Primary.Caption = 'Установить и перезапустить', 'Download failed: ' + Popup.Caption + ' / ' + Primary.Caption);
    Require((Bar.Position = 100) and (Pos('Скачано:', Bytes.Caption) = 1) and (Pos(' / ', Bytes.Caption) > 0), 'Download size or progress missing');
    Require(Pos('Новые изменения', Notes.Text) > 0, 'Download discarded changelog');
    Later.Click; Require(not Popup.Visible, 'Later did not hide ready update');
  finally Popup.Free; end;
  Writeln('PASS update popup downloads only on click, displays bytes, retains changelog and postpones installation');
  OwnedPopup := nil;
  for I := 0 to frmMain.ComponentCount - 1 do
    if frmMain.Components[I] is TfrmProgramUpdate then OwnedPopup := TfrmProgramUpdate(frmMain.Components[I]);
  Require(Assigned(OwnedPopup), 'Main form update popup missing');
  Popup := OwnedPopup;
  Require(Popup.RestoreReady, 'Ready update did not survive reopening'); Controls;
  Require(Primary.Caption = 'Установить и перезапустить', 'Restored update cannot install');
  ReadyFile := IncludeTrailingPathDelimiter(ProgramUpdateCache(Settings.AppPath)) + 'ready.json';
  Require(FileExists(ReadyFile), 'Ready download was lost');
  Primary.Click;
  Writeln('PASS ready update restores and real main close launches native replacement and restart');
end;

procedure TestHeaderMenuTags;
const
  Expected: array[0..12] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE, COL_COLLECTION,
    COL_LANG, COL_LIBRATE, COL_LIBID);
var
  I: Integer;
  ColumnHandler: TMethod;
begin
  Require(frmMain.pmHeaders.Items.Count = Length(Expected) + 2,
    'Wrong header menu structure');
  ColumnHandler := TMethod(frmMain.pmHeaders.Items[0].OnClick);
  for I := Low(Expected) to High(Expected) do
  begin
    Require(frmMain.pmHeaders.Items[I].Tag = Expected[I],
      'Header column identity changed at index ' + IntToStr(I));
    Require(TMethod(frmMain.pmHeaders.Items[I].OnClick).Code = ColumnHandler.Code,
      'A column lost its header action');
  end;
  Require((frmMain.pmHeaders.Items[13] = frmMain.N25) and
    (frmMain.N25.Caption = '-') and (frmMain.N25.Tag = 0) and
    not Assigned(frmMain.N25.OnClick),
    'Header separator must never be treated as a column');
  Require((frmMain.pmHeaders.Items[14] = frmMain.N27) and
    (frmMain.N27.Tag = 0) and Assigned(frmMain.N27.OnClick) and
    (TMethod(frmMain.N27.OnClick).Code <> ColumnHandler.Code),
    'Default header action must never be treated as a column');
  Writeln('PASS header menu keeps column IDs separate from separator and default action');
end;

procedure Trace(const Stage: string);
begin
  Writeln('TRACE ', Stage);
  Flush(Output);
end;

procedure HandleReaderProbe;
var
  Root, FileName: string;
begin
  if (ParamCount <> 1) or not SameText(ExtractFileExt(ParamStr(1)), '.fb2') then Exit;
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0))));
  FileName := ExpandFileName(ParamStr(1));
  Require(SameText(Copy(FileName, 1, Length(Root)), Root) and FileExists(FileName),
    'Reader probe must remain inside its isolated runtime');
  TFile.WriteAllText(Root + 'reader-probe-path.txt.tmp', FileName, TEncoding.UTF8);
  TFile.Move(Root + 'reader-probe-path.txt.tmp', Root + 'reader-probe-path.txt');
  Halt(0);
end;

procedure TestReaderCompatibility;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  PLAIN = '<?xml version="1.0" encoding="utf-8"?><FictionBook><body><section><p>Plain book</p></section></body></FictionBook>';
var
  Book: PBookRecord;
  Original, Probe, Converted, WithWebP, Captured: string;
  Started: UInt64;

  function ReadSelected: string;
  begin
    if FileExists(Probe) then TFile.Delete(Probe);
    frmMain.ReadBookExecute(nil);
    Started := GetTickCount64;
    while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do Sleep(20);
    Require(FileExists(Probe), 'The isolated reader probe did not receive a book');
    Result := TFile.ReadAllText(Probe, TEncoding.UTF8);
  end;

begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Book.GetBookFormat = bfFb2), 'Reader fixture is not a plain FB2');
  Original := Book.GetBookFileName;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  TFile.WriteAllText(Original, PLAIN, TEncoding.UTF8);
  Captured := ReadSelected;
  Require(SameFileName(Captured, Original), 'An ordinary FB2 lost its stable reader path');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = PLAIN, 'An ordinary source book changed');
  WithWebP := '<FictionBook><body><section><p>WebP book</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
  TFile.WriteAllText(Original, WithWebP, TEncoding.UTF8);
  Converted := ReadSelected;
  Require(not SameFileName(Converted, Original) and
    (Pos('webp-png', LowerCase(Converted)) > 0), 'A WebP book was not read from its converted cache');
  Captured := TFile.ReadAllText(Converted, TEncoding.UTF8);
  Require((Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0),
    'The reader received no converted PNG');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'The WebP source book changed');
  Settings.ConvertWebPToPNG := False;
  Require(SameFileName(ReadSelected, Original), 'Original mode reused the converted reader cache');
  Settings.ConvertWebPToPNG := True;
  Require(SameFileName(ReadSelected, Converted), 'PNG mode lost its separate reader cache');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'Reader policy changes wrote to the source');
  Writeln('PASS plain FB2 reader preserves ordinary paths, converts WebP, separates policy cache and leaves source unchanged');
end;

procedure MakeCleanupFixture(const Folder: string);
begin
  TDirectory.CreateDirectory(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER));
  TFile.WriteAllText(TPath.Combine(Folder, 'ordinary.tmp'), 'temporary root file');
  TFile.WriteAllText(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER + '\copy.fb2'), 'converted copy');
end;

procedure TestReadFolderCleanup;
var
  Root, Converted, Persistent, Unrelated, JunctionRoot, Outside: string;
  Busy: TFileStream;
begin
  TestReaderCompatibility;
  Root := Settings.TempDir;
  Converted := TFile.ReadAllText(Settings.AppPath + 'reader-probe-path.txt', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(Root, 'ordinary.tmp'), 'root cleanup probe');
  Unrelated := TPath.Combine(Root, 'unrelated\keep.txt');
  TDirectory.CreateDirectory(ExtractFilePath(Unrelated));
  TFile.WriteAllText(Unrelated, 'unrelated directory must survive');
  Busy := TFileStream.Create(Converted, fmOpenRead or fmShareExclusive);
  try
    frmMain.ClearReadFolderExecute(nil);
    Require(FileExists(Converted), 'A reader-locked book was deleted');
    Require(not FileExists(TPath.Combine(Root, 'ordinary.tmp')), 'Other temporary files were not cleaned');
  finally
    Busy.Free;
  end;
  frmMain.ClearReadFolderExecute(nil);
  Require(not FileExists(Converted), 'Converted reader copy survived explicit cleanup');
  Require(not DirectoryExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER)), 'Empty converted reader folder survived cleanup');
  Require(FileExists(Unrelated), 'Cleanup recursed into an unrelated directory');
  frmMain.ClearReadFolderExecute(nil);
  Writeln('PASS manual reader cleanup removes converted copies, preserves unrelated folders and retries busy files');

  Persistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(Persistent);
  MakeCleanupFixture(Root);
  Settings.ReadDir := Persistent;
  frmMain.ClearReadFolderExecute(nil);
  Require(not FileExists(TPath.Combine(Persistent, 'ordinary.tmp')) and
    not DirectoryExists(TPath.Combine(Persistent, WEBP_READER_CACHE_FOLDER)), 'Explicit custom reader folder cleanup failed');
  Require(FileExists(TPath.Combine(Root, 'ordinary.tmp')) and
    FileExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Custom reader cleanup changed the default temp folder');
  Writeln('PASS custom reading folder is cleared only when explicitly selected');

  // The Node wrapper creates this junction entirely inside its owned runtime.
  JunctionRoot := TPath.Combine(Settings.AppPath, 'junction-reading');
  Outside := TPath.Combine(Settings.AppPath, 'junction-target\keep.fb2');
  Require(FileExists(Outside) and DirectoryExists(TPath.Combine(JunctionRoot, WEBP_READER_CACHE_FOLDER)), 'Junction fixture is absent');
  Settings.ReadDir := JunctionRoot;
  frmMain.ClearReadFolderExecute(nil);
  Require(FileExists(Outside), 'Cleanup followed the cache junction into another folder');
  Require(not FileExists(TPath.Combine(JunctionRoot, 'ordinary.tmp')), 'Junction protection prevented ordinary file cleanup');
  Settings.ReadDir := '';
  Writeln('PASS reader cleanup does not follow a converted-cache junction');
end;

procedure TestExitReaderCleanup;
var
  Book: PBookRecord;
begin
  TestReaderCompatibility;
  CleanupExitTemp := Settings.TempDir;
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  CleanupExitSource := Book.GetBookFileName;
  MakeCleanupFixture(CleanupExitTemp);
  CleanupExitPersistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(CleanupExitPersistent);
  Settings.ReadDir := CleanupExitPersistent;
end;

procedure CheckExitReaderCleanup;
begin
  Require(not FileExists(TPath.Combine(CleanupExitTemp, 'ordinary.tmp')) and
    not DirectoryExists(TPath.Combine(CleanupExitTemp, WEBP_READER_CACHE_FOLDER)), 'Main-form destruction left temporary reader copies');
  Require(FileExists(TPath.Combine(CleanupExitPersistent, 'ordinary.tmp')) and
    FileExists(TPath.Combine(CleanupExitPersistent, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Exit removed persistent custom reading files');
  Require(FileExists(CleanupExitSource), 'Exit removed the original library book');
  Writeln('PASS real main-form exit removes temporary converted copies and preserves custom reading files and originals');
end;

function AddBook(const Collection: IBookCollection; const Title, Author,
  Lang, Series, Genre: string; Deleted: Boolean = False): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := Title;
  Book.FileExt := '.fb2';
  Book.LibID := Title;
  Book.Lang := Lang;
  Book.Series := Series;
  Book.Date := EncodeDate(2020, 1, 1);
  Book.Size := 100; // Ordinary fixture books are not deleted zero-size placeholders.
  TAuthorsHelper.Add(Book.Authors, Author, 'Alex', '');
  if Genre <> '' then
    if Pos('0.', Genre) = 1 then
      TGenresHelper.Add(Book.Genres, Genre, '', '')
    else
      TGenresHelper.Add(Book.Genres, '', '', Genre);
  Include(Book.BookProps, bpIsLocal);
  if Deleted then
    Include(Book.BookProps, bpIsDeleted);
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Fixture book was not inserted');
end;

procedure ExpectTitles(Tree: TBookTree; const Expected: array of string);
var
  Actual, Wanted: TStringList;
  Node: PVirtualNode;
  Book: PBookRecord;
  Title: string;
begin
  Actual := TStringList.Create;
  Wanted := TStringList.Create;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book := Tree.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) then
        Actual.Add(Book.Title);
      Node := Tree.GetNext(Node);
    end;
    for Title in Expected do
      Wanted.Add(Title);
    Actual.Sort;
    Wanted.Sort;
    Require(Actual.Text = Wanted.Text,
      'Wrong visible books. Expected: ' + Wanted.CommaText + '; actual: ' + Actual.CommaText);
  finally
    Wanted.Free;
    Actual.Free;
  end;
end;

procedure ChangeCollection(ID: Integer);
var
  Item: TMenuItem;
begin
  for Item in frmMain.miCollSelect do
    if Item.Tag = ID then
    begin
      frmMain.miActiveCollectionClick(Item);
      Exit;
    end;
  raise Exception.Create('Fixture collection is absent from the collection menu');
end;

procedure ShowPage(Index: Integer);
begin
  // HomeLib Ru inserts Publisher Series between the physical tab pages.
  // PAGE_* values identify views, not PageIndex after that insertion.
  case Index of
    PAGE_AUTHORS: frmMain.pgControl.ActivePage := frmMain.tsByAuthor;
    PAGE_SERIES: frmMain.pgControl.ActivePage := frmMain.tsBySerie;
    PAGE_GENRES: frmMain.pgControl.ActivePage := frmMain.tsByGenre;
    PAGE_SEARCH: frmMain.pgControl.ActivePage := frmMain.tsSearch;
    PAGE_FAVORITES: frmMain.pgControl.ActivePage := frmMain.tsByGroup;
  else
    raise Exception.Create('Unsupported test view');
  end;
  frmMain.pgControlChange(nil);
end;

procedure RequestRootGenreBooks;
begin
  if frmMain.btnShowGenreBooks.Visible then
    frmMain.btnShowGenreBooksClick(nil);
end;

procedure TestOnlineDownload(const Collection: IBookCollection;
  DirectBookID, QueueBookID, RestartBookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured, SourceFile, ExportDir: string;
  Started: UInt64;
  SourceBytes: TBytes;
  Keys: TBookIdList;
  Worker: TExportToDeviceThread;
  Component: TComponent;
  HasCover: Boolean;

  procedure RequireUnchangedZip;
  var
    Actual: TBytes;
  begin
    Actual := TFile.ReadAllBytes(SourceFile);
    Require((Length(Actual) = Length(SourceBytes)) and
      CompareMem(Pointer(SourceBytes), Pointer(Actual), Length(SourceBytes)),
      'Reading, preview or export rewrote the downloaded ZIP');
  end;

  procedure Pump;
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;

  procedure SelectBook(const BookID: Integer);
  begin
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Book := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) and
        (Book.BookKey.BookID = BookID) then Break;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Assigned(Node), 'Online book is absent from the visible author list');
    frmMain.tvBooksA.ClearSelection;
    frmMain.tvBooksA.Selected[Node] := True;
    frmMain.tvBooksA.FocusedNode := Node;
    frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  end;

  procedure ReadSelected;
  begin
    if FileExists(Probe) then TFile.Delete(Probe);
    frmMain.ReadBookExecute(nil);
    Started := GetTickCount64;
    while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do Pump;
    Require(FileExists(Probe), 'Online download did not hand a book to the reader');
    Captured := TFile.ReadAllText(Probe, TEncoding.UTF8);
    Require(FileExists(Captured), 'The reader received an absent file');
    Captured := TFile.ReadAllText(Captured, TEncoding.UTF8);
    Require((Pos('Online fixture text', Captured) > 0) and
      (Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0) and
      (Pos('UklGR', Captured) = 0),
      'Online reader received the wrong book or unconverted WebP');
  end;

begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.DwnldInterval := 0;
  Settings.AutoStartDwnld := False;
  Settings.SelectedIsChecked := True;
  Settings.ErrorLog := True;
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  Settings.ShowBookCover := True;
  Settings.ShowBookAnnotation := True;
  Settings.ShowInfoPanel := True;
  frmMain.ipnlAuthors.ShowCover := True;
  frmMain.ipnlAuthors.ShowAnnotation := True;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  SelectBook(DirectBookID);
  Require((Book.GetBookFormat = bfFb2Archive) and
    not (bpIsLocal in Book.BookProps), 'Online fixture must start as a remote FB2 ZIP');
  Trace('online direct reader download');
  ReadSelected;
  Collection.GetBookRecord(CreateBookKey(DirectBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Online direct download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  Require(FileExists(SourceFile), 'Downloaded ZIP is absent');
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  HasCover := False;
  for Component in frmMain.ipnlAuthors do
    if (Component is TImage) and Assigned(TImage(Component).Picture.Graphic) then
      HasCover := not TImage(Component).Picture.Graphic.Empty;
  Require(HasCover, 'Downloaded WebP cover is absent from the real main info panel');
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main reader downloads ZIP, updates local status, previews cover and reads converted FB2');

  SelectBook(QueueBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Queue fixture is already local');
  Trace('online download queue');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Online book was not added to the real download queue');
  frmMain.btnStartDownloadClick(nil);
  Trace('online queue manager started');
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'Online download queue did not complete successfully');
  Collection.GetBookRecord(CreateBookKey(QueueBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Queue download did not update database and main tree local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  Trace('online queued book downloaded');
  ReadSelected;
  Settings.FileNameTemplate := '%t';
  Settings.FolderTemplate := '';
  ExportDir := TPath.Combine(Settings.AppPath, 'online-export');
  ForceDirectories(ExportDir);
  SetLength(Keys, 1);
  Keys[0].BookKey := Stored.BookKey;
  Worker := TExportToDeviceThread.Create;
  Trace('online export worker created');
  try
    Worker.BookIdList := Keys;
    Worker.ExtractOnly := False;
    Worker.ExportMode := emFB2;
    Worker.DeviceDir := ExportDir;
    Worker.Start;
    Worker.WaitFor;
    Require(not Assigned(Worker.FatalException), 'Online downloaded book export failed');
  finally
    Worker.Free;
  end;
  Captured := TFile.ReadAllText(TPath.Combine(ExportDir, Stored.Title + '.fb2'), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Export of the queued online book lost its text or conversion policy');
  RequireUnchangedZip;
  Writeln('PASS online main queue downloads ZIP and its local book remains readable and exportable');

  SelectBook(RestartBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Restart fixture is already local');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Restart book was not added to the real queue');
  frmMain.btnStartDownloadClick(nil);
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'The completed download manager could not be restarted');
  Collection.GetBookRecord(CreateBookKey(RestartBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Restart download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main queue restarts for another remote book and preserves its downloaded ZIP');
end;

procedure CreateOnlineResponse;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  XML = '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ' +
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>' +
    '<author><first-name>Alex</first-name><last-name>Online</last-name></author>' +
    '<book-title>Online payload</book-title><annotation><p>Online fixture annotation</p></annotation>' +
    '<coverpage><image l:href="#cover.jpg"/></coverpage><lang>ru</lang>' +
    '</title-info></description><body><section><p>Online fixture text</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
var
  Zip: TMHLZip;
  Stream: TBytesStream;
begin
  TFile.WriteAllBytes(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8.GetBytes(XML));
  Zip := TMHLZip.Create(Settings.AppPath + 'download-response.zip', False);
  try
    Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML));
    try
      // Real servers need not use the INPX display filename for their ZIP member.
      Zip.AddFromStream('server-member-name.fb2', Stream);
    finally
      Stream.Free;
    end;
  finally
    Zip.Free;
  end;
end;

function AddOnlineBook(const Collection: IBookCollection;
  const Title, LibID: string; const AsArchive: Boolean = True): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := LibID;
  Book.FileExt := '.fb2';
  Book.LibID := LibID;
  Book.Lang := 'ru';
  Book.Date := EncodeDate(2026, 10, 6);
  TAuthorsHelper.Add(Book.Authors, 'Online', 'Alex', '');
  TGenresHelper.Add(Book.Genres, '', '', 'prose_contemporary');
  if AsArchive then
    Book.Folder := Book.GenerateLocation + FB2ZIP_EXTENSION
  else
    Book.Folder := 'online-plain' + PathDelim;
  Book.InsideNo := 0;
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Online fixture book was not inserted');
end;

procedure TestOnlinePlain(const Collection: IBookCollection; BookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured: string;
  Started: UInt64;
begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.Readers.Clear;
  Settings.ErrorLog := True;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  Node := frmMain.tvBooksA.GetFirst;
  Require(Assigned(Node), 'Plain online fixture is absent');
  Book := frmMain.tvBooksA.GetNodeData(Node);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID) and
    (Book.GetBookFormat = bfFb2) and not (bpIsLocal in Book.BookProps),
    'Plain online fixture must start remote without a ZIP container');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  frmMain.ReadBookExecute(nil);
  Started := GetTickCount64;
  while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;
  Require(FileExists(Probe), 'Plain remote FB2 was opened before downloading');
  Captured := TFile.ReadAllText(TFile.ReadAllText(Probe, TEncoding.UTF8), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Plain online reader received the wrong book or unconverted WebP');
  Collection.GetBookRecord(CreateBookKey(BookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Plain online download did not update local status');
  Require(TFile.ReadAllText(Stored.GetBookFileName, TEncoding.UTF8) =
    TFile.ReadAllText(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8),
    'Plain online reader modified the downloaded source');
  Writeln('PASS plain online FB2 is downloaded before compatibility conversion and reader handoff');
end;

procedure TestLanguageIsolation;
begin
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  ShowPage(PAGE_GENRES);
  ShowPage(PAGE_AUTHORS);
  frmMain.btnSwitchTreeModeClick(nil);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Another view reset the selected author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  frmMain.btnSwitchTreeModeClick(nil);
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  Writeln('PASS language choice survives another view first load and repeated refreshes');
end;

procedure TestAddBeforeFirstGroupVisit;
var
  Node: PVirtualNode;
  Book: PBookRecord;
begin
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if (Book.NodeType = ntBookInfo) and (Book.Title = 'Alpha extra uk') then
      Break;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Require(Assigned(Node), 'The book to add is absent');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  Require(frmMain.acBookAdd2Favorites.Execute, 'Add to Favorites action was disabled');
  ShowPage(PAGE_FAVORITES);
  Require(frmMain.cbLangSelectF.Text = 'ru', 'Adding a book lost the unopened group language filter');
  ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
  Writeln('PASS adding a book before first group visit preserves its language filter');
end;

procedure TestGenreLink;
var
  Book: PBookRecord;
  BookID: Integer;
  GenreCode: string;
begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Length(Book.Genres) = 1), 'The linked book has no genre');
  BookID := Book.BookKey.BookID;
  GenreCode := Book.Genres[0].GenreCode;
  frmMain.ipnlAuthors.OnGenreLinkClicked(frmMain.ipnlAuthors, GenreCode, Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsByGenre, 'Genre link did not activate its page');
  Require(frmMain.lblGenreTitle.Caption = Book.Genres[0].GenreAlias,
    'Genre link left the previous genre title visible');
  ExpectTitles(frmMain.tvBooksG, ['Alpha ru']);
  Book := frmMain.tvBooksG.GetNodeData(frmMain.tvBooksG.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Genre link did not retain the requested book');
  Writeln('PASS genre link restores the requested genre, language and book');
end;

procedure TestGenreOrder(const Collection: IBookCollection; UnknownBook: Integer);
var
  Node: PVirtualNode;
  Genre: PGenreData;
  Filter: TFilterValue;
begin
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = '0.1'), 'First classified genre was not selected');
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(frmMain.tvGenres.GetNextSibling(Node)) do
    Node := frmMain.tvGenres.GetNextSibling(Node);
  Genre := frmMain.tvGenres.GetNodeData(Node);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Unsorted is not the last tree category');
  ShowPage(PAGE_GENRES);
  ExpectTitles(frmMain.tvBooksG, []);
  Require(frmMain.btnShowGenreBooks.Visible, 'Root genre has no explicit Show action');
  RequestRootGenreBooks;
  Require(frmMain.cbLangSelectG.Text = 'ru', 'Root Show lost the deferred saved language');
  ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmAll), False, UNKNOWN_GENRE_CODE);
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Explicit Unsorted selection was lost');
  ExpectTitles(frmMain.tvBooksG, ['Unknown']);
  Filter.ValueInt := UnknownBook;
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmByBook, @Filter));
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Only-Unsorted tree has no selection');
  Writeln('PASS Unsorted is last, first genre is default, explicit selection and fallback work');
end;

procedure TestSourceGenrePreservation(const Expected: TGenreData);
var
  Node: PVirtualNode;
  Genre: PGenreData;
begin
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(Node) do
  begin
    Genre := frmMain.tvGenres.GetNodeData(Node);
    if Genre.GenreCode = Expected.GenreCode then
    begin
      Require((Genre.GenreAlias = Expected.GenreAlias) and
        (Genre.ParentCode = Expected.ParentCode), 'Locale update changed imported genre metadata');
      Writeln('PASS imported source genre survives locale synchronization');
      Exit;
    end;
    Node := frmMain.tvGenres.GetNext(Node);
  end;
  raise Exception.Create('Locale synchronization removed an imported genre');
end;

function PublisherView: TPublisherSeriesView;
var
  Component: TComponent;
begin
  for Component in frmMain do
    if Component is TPublisherSeriesView then
      Exit(TPublisherSeriesView(Component));
  raise Exception.Create('Publisher view was not created');
end;

procedure TestPublisherSelection(OneID, TwoID, SavedBook: Integer);
var
  View: TPublisherSeriesView;
  Book: PBookRecord;
begin
  View := PublisherView;
  Require(View.SeriesTree.GetFirst = nil, 'Hidden publisher list was eagerly built');
  ExpectTitles(View.Books, []);
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'First publisher visit lost its saved language');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'First publisher visit lost its saved book');
  ShowPage(PAGE_AUTHORS);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Publisher filtering reset author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  ChangeCollection(TwoID);
  ChangeCollection(OneID);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'Publisher language was lost across collections');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'Publisher book was lost across collections');
  Writeln('PASS deferred publisher view restores its language and book without changing author selection');
end;

procedure TestPublisherLinks(const One: IBookCollection; OneID, TwoID: Integer);
var View: TPublisherSeriesView; Series: TBookSeries; Item: TSeriesData;
  Iter: ISeriesIterator; Book: PBookRecord; Node: PVirtualNode;
  BookID, OtherBook, SeriesID, CycleID: Integer; GenreCode: string;
  Annotation: TMemo; I: Integer; Viewport: TScrollBox; Content: TWinControl;
begin
  View := PublisherView;
  BookID := AddBook(One, 'Audit prose', 'Audit', 'ru', 'Audit cycle', 'prose_contemporary');
  OtherBook := AddBook(One, 'Audit science', 'Audit', 'ru', 'Audit cycle', 'sci_physics');
  TSeriesHelper.Add(Series, 0, 'Audit common', 7, False);
  One.SetBookPublisherSeries(CreateBookKey(BookID, OneID), Series);
  One.SetBookPublisherSeries(CreateBookKey(OtherBook, OneID), Series);
  Iter := One.GetPublisherSeriesIterator('Audit'); Require(Iter.Next(Item), 'Publisher fixture absent');
  SeriesID := Item.SeriesID; Iter := nil;
  // A previously saved grouping must not hide books after returning to a flat list.
  One.SetProperty(PROP_PUBLISHER_BY_GENRE, True); One.SetProperty(PROP_PUBLISHER_GENRE, 'missing-genre');
  One.SetProperty(PROP_LAST_PUBLISHER_SERIES, SeriesID);
  One.SetProperty(PROP_LAST_PUBLISHER_BOOK, BookID); One.SetProperty(PROP_PUBLISHER_LANG_FILTER, 0);
  ChangeCollection(TwoID); ChangeCollection(OneID);
  frmMain.pgControl.ActivePage := View.Tab; frmMain.pgControlChange(nil);
  Require(View.SeriesTree.RootNodeCount = 1, 'Flat view duplicated or hid a mixed-genre series');
  ExpectTitles(View.Books, ['Audit prose', 'Audit science']);
  Node := View.Books.FocusedNode; Book := View.Books.GetNodeData(Node);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Publisher selection lost');
  CycleID := Book.SeriesID; GenreCode := Book.Genres[0].GenreCode;
  Annotation := nil; Viewport := nil;
  for I := 0 to View.Info.ControlCount - 1 do
    if View.Info.Controls[I] is TScrollBox then Viewport := TScrollBox(View.Info.Controls[I]);
  Require(Assigned(Viewport), 'Card viewport missing'); Content := TWinControl(Viewport.Controls[0]);
  for I := 0 to Content.ControlCount - 1 do
    if Content.Controls[I] is TMemo then Annotation := TMemo(Content.Controls[I]);
  Require(Assigned(Annotation), 'Annotation missing'); Annotation.Text := 'Keep the current card';
  View.Info.OnPublisherSeriesLinkClicked(View.Info, IntToStr(SeriesID), Low(TSysLinkType));
  Require((View.Books.FocusedNode = Node) and (Annotation.Text = 'Keep the current card'),
    'Same publisher link rebuilt its book tree or cleared its card');
  View.Info.OnSeriesLinkClicked(View.Info, IntToStr(CycleID), Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsBySerie, 'Cycle link did not switch tabs');
  Book := frmMain.tvBooksS.GetNodeData(frmMain.tvBooksS.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Cycle link lost the book');
  frmMain.ipnlSeries.OnPublisherSeriesLinkClicked(frmMain.ipnlSeries, IntToStr(SeriesID), Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = View.Tab, 'Publisher link did not return');
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Return link lost the book');
  View.Info.OnGenreLinkClicked(View.Info, GenreCode, Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsByGenre, 'Genre link did not switch tabs');
  Book := frmMain.tvBooksG.GetNodeData(frmMain.tvBooksG.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Genre link lost the book');
  Require(One.GetBookPublisherSeries(CreateBookKey(BookID, OneID))[0].SeqNumber = 7,
    'Navigation changed a publisher number');
  Writeln('PASS flat publisher list ignores old grouping and retains mixed genres without duplicates');
  Writeln('PASS publisher links keep current card and select the same book across cycle and genre tabs');
end;

type
  TPublisherLogDriver = class
    Timer: TTimer;
    SavedLog, SourceLog: string;
    PreviewCount: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure TPublisherLogDriver.Tick(Sender: TObject);
var
  I: Integer;
  Progress: TImportProgressFormEx;
begin
  for I := Screen.FormCount - 1 downto 0 do
    if (Screen.Forms[I] is TImportProgressFormEx) and Screen.Forms[I].Visible then
    begin
      Progress := TImportProgressFormEx(Screen.Forms[I]);
      if (Progress.WorkerThread is TIndexPublisherSeriesThread) and
        Progress.WorkerThread.Finished and (Progress.btnCancel.Caption = 'Закрыть') then
      begin
        SourceLog := Progress.FullErrorLogFileName;
        PreviewCount := Progress.errorLog.Items.Count;
        Require(Progress.btnSaveLog.Visible, 'Full journal save button is hidden');
        Progress.SaveErrorLog(SavedLog);
        Progress.btnCancel.Click;
      end;
    end;
end;

procedure TestPublisherErrorLog(const Collection: IBookCollection);
var
  R: TBookRecord;
  Series: TBookSeries;
  IDs: TArray<Integer>;
  I, ErrorCount, PlaceholderID, NoDescriptionID, RepairedID, DeletedValidID: Integer;
  Driver: TPublisherLogDriver;
  Log: TStringList;
  Line: string;

  function AddFixture(const Name, XML: string; Deleted: Boolean; Size: Integer): Integer;
  var Book: TBookRecord;
  begin
    Book.Clear;
    Book.Title := Name; Book.LibID := Name; Book.FileName := Name;
    Book.FileExt := '.fb2'; Book.Size := Size;
    Include(Book.BookProps, bpIsLocal);
    if Deleted then Include(Book.BookProps, bpIsDeleted);
    Result := Collection.InsertBook(Book, False, False);
    Collection.SetBookPublisherSeries(CreateBookKey(Result, Collection.CollectionID), Series);
    if XML = '' then
      TFile.WriteAllBytes(TPath.Combine(Collection.CollectionRoot, Name + '.fb2'), nil)
    else
      TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, Name + '.fb2'), XML, TEncoding.UTF8);
  end;
begin
  SetLength(IDs, 25);
  TSeriesHelper.Add(Series, 0, 'Keep existing publisher', 7, False);
  for I := 0 to High(IDs) do
  begin
    R.Clear;
    R.Title := 'Broken series fixture ' + IntToStr(I);
    R.LibID := 'broken-' + IntToStr(I);
    R.FileName := 'broken-' + IntToStr(I);
    R.FileExt := '.fb2';
    Include(R.BookProps, bpIsLocal);
    IDs[I] := Collection.InsertBook(R, False, False);
    Collection.SetBookPublisherSeries(CreateBookKey(IDs[I], Collection.CollectionID), Series);
    TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, R.FileName + '.fb2'),
      '<NotFictionBook/>', TEncoding.UTF8);
  end;
  R.Clear;
  R.Title := 'Valid reset namespace'; R.LibID := 'valid-reset';
  R.FileName := 'valid-reset'; R.FileExt := '.fb2';
  Include(R.BookProps, bpIsLocal);
  I := Collection.InsertBook(R, False, False);
  TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, R.FileName + '.fb2'),
    '<?xml version="1.0" encoding="UTF8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.1">' +
    '<description xmlns=""><title-info/><publish-info><sequence name="Recovered" number="5"/>' +
    '</publish-info></description><body/></FictionBook>', TEncoding.UTF8);
  PlaceholderID := AddFixture('empty-deleted-placeholder', '', True, 0);
  NoDescriptionID := AddFixture('no-description', '<FictionBook><body/></FictionBook>', False, 40);
  RepairedID := AddFixture('repair-annotation', '<FictionBook><description><title-info>' +
    '<annotation><p>text</annotation></title-info><publish-info>' +
    '<sequence name="Recovered & exact" number="26"/></publish-info></description>', False, 250);
  DeletedValidID := AddFixture('deleted-valid', '<FictionBook><description><title-info/>' +
    '<publish-info><sequence name="Deleted readable" number="8"/></publish-info></description>', True, 200);
  Driver := TPublisherLogDriver.Create;
  try
    Driver.SavedLog := Settings.AppPath + 'saved-publisher-errors.log';
    Driver.Timer := TTimer.Create(nil);
    Driver.Timer.Interval := 25;
    Driver.Timer.OnTimer := Driver.Tick;
    PublisherView.IndexButton.Click;
    Require(FileExists(Driver.SavedLog), 'Actual main command did not save its full error log');
    Require(Driver.PreviewCount <= 24, 'Preview grows without a bound');
    Require(TFile.ReadAllText(Driver.SourceLog, TEncoding.UTF8) =
      TFile.ReadAllText(Driver.SavedLog, TEncoding.UTF8), 'Save journal copied only the visible errors');
    Log := TStringList.Create;
    try
      Log.LoadFromFile(Driver.SavedLog, TEncoding.UTF8);
      ErrorCount := 0;
      for Line in Log do
        if Line.StartsWith('Книга ') then Inc(ErrorCount);
      Require(ErrorCount = 32, Format('Full journal has %d errors; expected 32 broken/missing books', [ErrorCount]));
      Require(Log.Text.Contains('broken-24.fb2'), 'Error beyond the first twenty is missing');
      Require(not Log.Text.Contains('empty-deleted-placeholder'), 'Deleted empty placeholder was logged as error');
      Require(not Log.Text.Contains('no-description'), 'Missing optional metadata was logged as error');
      Require(Log.Text.Contains('Восстановлено при чтении:'), 'Recovery was not recorded in the full journal');
    finally
      Log.Free;
    end;
    for ErrorCount in IDs do
    begin
      Series := Collection.GetBookPublisherSeries(CreateBookKey(ErrorCount, Collection.CollectionID));
      Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Keep existing publisher'),
        'Malformed book erased existing publisher metadata');
    end;
    Series := Collection.GetBookPublisherSeries(CreateBookKey(I, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Recovered') and
      (Series[0].SeqNumber = 5), 'Actual command failed to recover converter metadata');
    for ErrorCount in TArray<Integer>.Create(PlaceholderID, NoDescriptionID) do
    begin
      Series := Collection.GetBookPublisherSeries(CreateBookKey(ErrorCount, Collection.CollectionID));
      Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Keep existing publisher'),
        'Skipped book erased existing publisher metadata');
    end;
    Series := Collection.GetBookPublisherSeries(CreateBookKey(RepairedID, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Recovered & exact') and
      (Series[0].SeqNumber = 26), 'Recovered metadata lost exact title or number');
    Series := Collection.GetBookPublisherSeries(CreateBookKey(DeletedValidID, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Deleted readable'),
      'Nonempty deleted book was incorrectly skipped');
    Require(TFile.ReadAllText(TPath.Combine(Collection.CollectionRoot, 'repair-annotation.fb2'),
      TEncoding.UTF8).Contains('<p>text</annotation>'), 'Recovery modified the original book');
    Writeln('PASS actual publisher indexing saves all errors, bounds preview and preserves metadata');
  finally
    Driver.Timer.Free;
    if FileExists(Driver.SourceLog) then TFile.Delete(Driver.SourceLog);
    Driver.Free;
  end;
end;

var
  One, Two, Online: IBookCollection;
  OneID, TwoID, FirstBook, LastBook, UnknownBook, I: Integer;
  OnlineID, DirectBookID, QueueBookID, RestartBookID, Port: Integer;
  Book: PBookRecord;
  ImportedGenre: TGenreData;
  PublisherSeries: TBookSeries;
  PublisherIterator: ISeriesIterator;
  Publisher: TSeriesData;
  ExceptionHandler: TRegressionExceptionHandler;
begin
  try
    RequireIsolatedRegression;
    HandleReaderProbe;
    DirectBookID := 0;
    QueueBookID := 0;
    RestartBookID := 0;
    Trace('application bootstrap');
    Application.Initialize;
    if ParamStr(1) = 'publisher-startup' then
      Application.MainFormOnTaskbar := True;
    ExceptionHandler := TRegressionExceptionHandler.Create;
    Application.OnException := ExceptionHandler.HandleException;
    Trace('localization');
    InitLocalization;
    Trace('splash construction');
    frmSplash := TfrmSplash.Create(Application);
    try
      Trace('isolated user module');
      Application.CreateForm(TDMUser, DMUser);
      DMUser.Init;
      Trace('tiny fixtures');
      OneID := SystemDB.CreateCollection('One', Settings.AppPath,
        'one.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      TwoID := SystemDB.CreateCollection('Two', Settings.AppPath,
        'two.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      One := SystemDB.GetCollection(OneID);
      Two := SystemDB.GetCollection(TwoID);
      FirstBook := AddBook(One, 'Alpha uk', 'Alpha', 'uk', 'Alpha series', 'prose_contemporary');
      LastBook := AddBook(One, 'Alpha ru', 'Alpha', 'ru', 'Alpha series', 'prose_contemporary');
      One.AddBookToGroup(CreateBookKey(FirstBook, OneID), FAVORITES_GROUP_ID);
      One.AddBookToGroup(CreateBookKey(LastBook, OneID), FAVORITES_GROUP_ID);
      AddBook(One, 'Alpha extra uk', 'Alpha', 'uk', '', 'prose_contemporary');
      AddBook(One, 'Genre uk', 'Beta', 'uk', '', '0.1');
      AddBook(One, 'Genre ru', 'Beta', 'ru', '', '0.1');
      AddBook(One, 'Genre deleted', 'Beta', 'ru', '', '0.1', True);
      UnknownBook := AddBook(One, 'Unknown', 'Gamma', 'ru', '', '');
      AddBook(Two, 'Other uk', 'Other', 'uk', '', '0.1');
      AddBook(Two, 'Other ru', 'Other', 'ru', '', '0.1');
      if (ParamStr(1) = 'online-download') or (ParamStr(1) = 'online-plain') then
      begin
        Port := StrToIntDef(ParamStr(2), 0);
        Require((Port > 0) and (Port <= 65535), 'Online regression requires its loopback server port');
        CreateOnlineResponse;
        OnlineID := SystemDB.CreateCollection('Online regression', Settings.AppPath,
          'online.hlc2', CT_EXTERNAL_ONLINE_FB, Settings.AppPath + 'genres_fb2.glst');
        Online := SystemDB.GetCollection(OnlineID);
        Online.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
        Online.SetProperty(PROP_CONNECTIONSCRIPT, 'GET %URL%b/%LIBID%/get' + sLineBreak + 'CHECK');
        if ParamStr(1) = 'online-plain' then
          DirectBookID := AddOnlineBook(Online, 'Online plain', '900003', False)
        else
        begin
          DirectBookID := AddOnlineBook(Online, 'Online reader', '900001');
          QueueBookID := AddOnlineBook(Online, 'Online queue', '900002');
          RestartBookID := AddOnlineBook(Online, 'Online restart', '900004');
        end;
      end;
      if (ParamStr(1) = 'publisher-selection') or (ParamStr(1) = 'publisher-startup') then
      begin
        TSeriesHelper.Add(PublisherSeries, 0, 'Fixture publisher', 1, False);
        One.SetBookPublisherSeries(CreateBookKey(FirstBook, OneID), PublisherSeries);
        PublisherSeries[0].SeqNumber := 2;
        One.SetBookPublisherSeries(CreateBookKey(LastBook, OneID), PublisherSeries);
        PublisherIterator := One.GetPublisherSeriesIterator;
        Require(PublisherIterator.Next(Publisher), 'Publisher fixture was not registered');
        One.SetProperty(PROP_LAST_PUBLISHER_SERIES, Publisher.SeriesID);
        One.SetProperty(PROP_LAST_PUBLISHER_BOOK, LastBook);
        One.SetProperty(PROP_PUBLISHER_LANG_FILTER, 2);
        PublisherIterator := nil;
      end;
      if ParamStr(1) = 'source-genres' then
      begin
        ImportedGenre := One.EnsureGenre('popadancy', 'Imported genre', 'Imported category');
        One.SetProperty(PROP_GENRE_FILE, 'genres_fb2_uk.glst');
      end;
      One.SetProperty(PROP_LAST_AUTHOR_BOOK, LastBook);
      if ParamStr(1) = 'language-isolation' then
        One.SetProperty(PROP_GENRES_LANG_FILTER, 0)
      else
        One.SetProperty(PROP_GENRES_LANG_FILTER, 2);
      One.SetProperty(PROP_SERIES_LANG_FILTER, 1);
      One.SetProperty(PROP_GROUPS_LANG_FILTER, 2);
      Two.SetProperty(PROP_GENRES_LANG_FILTER, 1);
      Settings.ActiveCollection := OneID;
      Settings.ActivePage := PAGE_AUTHORS;
      if ParamStr(1) = 'publisher-startup' then
      begin
        Settings.ActivePage := PAGE_PUBLISHER_SERIES;
        Settings.ShowInfoPanel := True;
        Settings.ShowBookCover := True;
        Settings.ShowBookAnnotation := True;
        Settings.InfoPanelHeight := 310;
        Settings.FormWidth := 1173;
        Settings.FormHeight := 1073;
        Settings.Splitters[5] := 434;
      end;
      Trace('image module');
      Application.CreateForm(TdmImages, dmImages);
      dmImages.ApplyThemeIcons;
      Require(SystemDB.FindFirstExistingCollectionID(OneID) = OneID,
        'The registered fixture collection file is absent');
      Trace('main form');
      Application.CreateForm(TfrmMain, frmMain);
      TestHeaderMenuTags;
      Trace('genre form');
      Application.CreateForm(TfrmGenreTree, frmGenreTree);
      Trace('initial selection checks');
      if ParamStr(1) = 'publisher-startup' then
      begin
        Require(frmMain.pgControl.ActivePage = PublisherView.Tab, 'Saved publisher page was not restored');
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        Require(PublisherView.Info.Visible and PublisherView.Info.HandleAllocated,
          'Publisher information panel was not created');
        Application.ProcessMessages;
        Writeln('PASS saved publisher page starts with visible cover and information panel');
        ShowPage(PAGE_AUTHORS);
      end;
      ExpectTitles(frmMain.tvBooksA, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
      Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
      Require(Assigned(Book) and (Book.BookKey.BookID = LastBook),
        'The saved author book was not restored');
      Writeln('PASS default author selection and saved book');
      if ParamStr(1) = 'language-isolation' then
        TestLanguageIsolation
      else if ParamStr(1) = 'favorites-add' then
        TestAddBeforeFirstGroupVisit
      else if ParamStr(1) = 'genre-link' then
        TestGenreLink
      else if ParamStr(1) = 'genre-order' then
        TestGenreOrder(One, UnknownBook)
      else if ParamStr(1) = 'publisher-selection' then
        TestPublisherSelection(OneID, TwoID, LastBook)
      else if ParamStr(1) = 'publisher-links' then
        TestPublisherLinks(One, OneID, TwoID)
      else if ParamStr(1) = 'publisher-startup' then
      begin
        frmMain.pgControl.ActivePage := PublisherView.Tab;
        frmMain.pgControlChange(nil);
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        ChangeCollection(TwoID);
        ChangeCollection(OneID);
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        Writeln('PASS startup publisher view survives collection switches');
      end
      else if ParamStr(1) = 'publisher-error-log' then
        TestPublisherErrorLog(One)
      else if ParamStr(1) = 'reader-compatibility' then
        TestReaderCompatibility
      else if ParamStr(1) = 'read-folder-cleanup' then
        TestReadFolderCleanup
      else if ParamStr(1) = 'temp-exit-cleanup' then
        TestExitReaderCleanup
      else if ParamStr(1) = 'program-update-ui' then
        TestProgramUpdateUI
      else if ParamStr(1) = 'program-update-download' then
        TestProgramUpdateDownload
      else if ParamStr(1) = 'online-download' then
        TestOnlineDownload(Online, DirectBookID, QueueBookID, RestartBookID)
      else if ParamStr(1) = 'online-plain' then
        TestOnlinePlain(Online, DirectBookID)
      else if ParamStr(1) = 'source-genres' then
      begin
        TestSourceGenrePreservation(ImportedGenre);
        ChangeCollection(TwoID);
        ChangeCollection(OneID);
        TestSourceGenrePreservation(ImportedGenre);
      end
      else
      begin
        ChangeCollection(TwoID);
        Require(One.GetProperty(PROP_GENRES_LANG_FILTER) = 2,
          'Switching collections overwrote an unopened genre language filter');
        ChangeCollection(OneID);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
        Require(frmMain.cbLangSelectG.Text = 'ru', 'Saved genre language was not restored');
        Writeln('PASS unopened genre filter survives collection switches');
        ShowPage(PAGE_SERIES);
        ExpectTitles(frmMain.tvBooksS, ['Alpha uk']);
        Require(frmMain.cbLangSelectS.Text = 'uk', 'Saved series language was not restored');
        Writeln('PASS first series visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        frmMain.HideDeletedBooksExecute(nil);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS changed deletion filter refreshes previously visited views');
        ChangeCollection(TwoID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Other uk']);
        ChangeCollection(OneID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS visible genre view refreshes across collections');
        ShowPage(PAGE_FAVORITES);
        ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
        Require(frmMain.cbLangSelectF.Text = 'ru', 'Saved group language was not restored');
        Writeln('PASS first group visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        for I := 0 to frmMain.tbarAuthorsEng.ButtonCount - 1 do
          if frmMain.tbarAuthorsEng.Buttons[I].Caption = 'Z' then
            frmMain.tbarAuthorsEng.Buttons[I].OnClick(frmMain.tbarAuthorsEng.Buttons[I]);
        ExpectTitles(frmMain.tvBooksA, []);
        frmMain.HideDeletedBooksExecute(nil);
        ExpectTitles(frmMain.tvBooksA, []);
        Writeln('PASS empty author selection stays empty after a global refresh');
      end;
      frmGenreTree.Free;
      frmGenreTree := nil;
      frmMain.Free;
      frmMain := nil;
      if ParamStr(1) = 'temp-exit-cleanup' then CheckExitReaderCleanup;
      One := nil;
      Two := nil;
      Online := nil;
      dmImages.Free;
      dmImages := nil;
      DMUser.Free;
      DMUser := nil;
    finally
      frmSplash.Free;
      frmSplash := nil;
    end;
    Application.OnException := nil;
    ExceptionHandler.Free;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
      Halt(1);
    end;
  end;
end.
