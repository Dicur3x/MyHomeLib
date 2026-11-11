type
  TReaderDiagnosticsProbe = class
    ParentForm: TForm;
    Timer: TTimer;
    Deadline: UInt64;
    Shown, CheckReadable: Boolean;
    Failure: string;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderDiagnosticsProbe.Tick(Sender: TObject);
var Dialog: TForm; Folder: TEdit; Memo: TMemo; Detailed: TCheckBox;
  Save, Close: TButton; ExpectedBackground, ExpectedText: TColor;
begin
  try
    Require(GetTickCount64<Deadline,'Reader diagnostic menu did not return');
    Dialog:=nil;
    for var I:=Screen.FormCount-1 downto 0 do
      if (Screen.Forms[I].Name='DiagnosticsDialog') and Screen.Forms[I].Visible then
        begin Dialog:=Screen.Forms[I]; Break; end;
    if not Assigned(Dialog) then Exit;
    if not Shown then
    begin
      Shown:=True;
      Require((Dialog.Owner=ParentForm) and (Dialog.PopupParent=ParentForm),
        'Reader diagnostic window has the wrong modal parent');
      Require(ColorToRGB(Dialog.Color)=ColorToRGB(ParentForm.Color),
        'Diagnostic window replaced the owning reader palette');
      Folder:=Dialog.FindComponent('DiagnosticsFolder') as TEdit;
      Memo:=Dialog.FindComponent('DiagnosticsText') as TMemo;
      Detailed:=Dialog.FindComponent('DiagnosticsDetailed') as TCheckBox;
      Save:=Dialog.FindComponent('DiagnosticsSave') as TButton;
      Close:=Dialog.FindComponent('DiagnosticsClose') as TButton;
      Require(Folder.ReadOnly and Folder.Enabled and Folder.TabStop and
        SameFileName(Folder.Text,DiagnosticLogDirectory),'Actual diagnostic folder cannot be selected and copied');
      Folder.SelectAll;
      Require(Folder.SelLength=Length(Folder.Text),'Readonly diagnostic folder cannot be selected');
      Require(Memo.ReadOnly and string(Memo.Text).Contains('reader-diagnostics-fixture'),
        'Diagnostic window did not show the current actual log');
      if CheckReadable then
      begin
        var LogText:=string(Memo.Text);
        Require(LogText.Contains('Первая строка — ё '+#$D83D+#$DE42+sLineBreak+'Вторая строка') and
          LogText.Contains('Заключительная запись'),
          'Diagnostic display did not decode the Russian log text or continue after a malformed row');
        Require(Memo.WordWrap and (Memo.ScrollBars=ssVertical) and LogText.Contains('Ошибка') and
          LogText.Contains('Буквальный код: \u041F') and
          LogText.Contains('Пропущено повреждённых записей: 1') and
          not LogText.Contains('{"message":'),
          'Diagnostic display lost a literal escape or exposed raw JSON');
      end;
      ExpectedBackground:=ParentForm.Color; ExpectedText:=ParentForm.Font.Color;
      if not (ParentForm is TfrmBuiltinReader) then
      begin
        // Catalogue-style inputs intentionally differ from the surrounding panel.
        if MHLThemeDark then ExpectedBackground:=RGB(30,31,34) else ExpectedBackground:=clWindow;
        ExpectedText:=MHLThemeText;
      end;
      Require((ColorToRGB(Memo.Color)=ColorToRGB(ExpectedBackground)) and
        (ColorToRGB(Memo.Font.Color)=ColorToRGB(ExpectedText)),
        'Diagnostic text uses an unrelated background or unreadable text colour');
      Require(Assigned(Save.OnClick) and Assigned(TButton(Dialog.FindComponent('DiagnosticsOpenFolder')).OnClick) and
        Close.Cancel and (Close.ModalResult=mrClose),'Diagnostic report/folder/close actions are missing');
      Require(string((Dialog.FindComponent('DiagnosticsInstructions') as TLabel).Caption).Contains('7 дней'),
        'Diagnostic retention/report instructions are missing');
      Require(Detailed.Checked=DetailedDiagnosticLogging,'Diagnostic window changed detailed logging without consent');
      for var PPI in [96,144,192] do
      begin
        Dialog.ScaleForPPI(PPI);
        for var Small in [False,True] do
        begin
          if Small then begin Dialog.ClientWidth:=MulDiv(640,PPI,96); Dialog.ClientHeight:=MulDiv(320,PPI,96); end
          else begin Dialog.ClientWidth:=MulDiv(720,PPI,96); Dialog.ClientHeight:=MulDiv(450,PPI,96); end;
          for var I:=0 to Dialog.ControlCount-1 do
          begin
            var Control:=Dialog.Controls[I]; if not Control.Visible then Continue;
            Require((Control.Left>=0) and (Control.Top>=0) and
              (Control.Left+Control.Width<=Dialog.ClientWidth) and
              (Control.Top+Control.Height<=Dialog.ClientHeight),'Diagnostic control clipped after resize/DPI');
          end;
          Require((Folder.Top+Folder.Height<=Detailed.Top) and
            (Detailed.Top+Detailed.Height<=Memo.Top) and (Memo.Top+Memo.Height<=Save.Top),
            'Diagnostic path, logging option or report button overlaps the log');
        end;
      end;
      Dialog.ScaleForPPI(96); Dialog.ClientWidth:=680; Dialog.ClientHeight:=420;
    end;
    Timer.Enabled:=False; Dialog.ModalResult:=mrClose;
  except
    on E:Exception do
    begin
      Failure:=E.Message; Timer.Enabled:=False;
      for var I:=Screen.FormCount-1 downto 0 do
        if Screen.Forms[I].Name='DiagnosticsDialog' then Screen.Forms[I].ModalResult:=mrCancel;
    end;
  end;
end;

procedure CheckDiagnosticsDialog(ParentForm: TForm; Item: TMenuItem; CheckReadable: Boolean = False);
var Probe: TReaderDiagnosticsProbe;
begin
  Require(Assigned(Item) and Assigned(Item.OnClick),'Diagnostic menu command is missing');
  Probe:=TReaderDiagnosticsProbe.Create; Probe.ParentForm:=ParentForm; Probe.CheckReadable:=CheckReadable;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=50;
  Probe.Timer.OnTimer:=Probe.Tick; Probe.Deadline:=GetTickCount64+60000;
  try
    Probe.Timer.Enabled:=True; Item.Click;
    Require(Probe.Shown and (Probe.Failure=''),'Diagnostics: '+Probe.Failure);
  finally Probe.Timer.Free; Probe.Free; end;
end;

procedure CheckReaderDiagnosticsMenu(ParentForm: TForm; CheckReadable: Boolean = False);
var Item: TMenuItem; Report: string; Zip: TZipFile;
begin
  Require(Assigned(ParentForm.Menu),'Reader has no main menu');
  Item:=nil;
  for var I:=0 to ParentForm.Menu.ComponentCount-1 do
    if ParentForm.Menu.Components[I].Name='ReaderDiagnostics' then Item:=TMenuItem(ParentForm.Menu.Components[I]);
  Require(Assigned(Item) and Assigned(Item.OnClick) and Assigned(Item.Parent) and
    (StripHotkey(Item.Parent.Caption)='Помощь'),'Reader help has no diagnostic menu entry');
  CheckDiagnosticsDialog(ParentForm,Item,CheckReadable);
  Report:=Settings.AppPath+'reader-diagnostics-'+TGUID.NewGuid.ToString+'.zip';
  SaveDiagnosticReport(Report);
  Zip:=TZipFile.Create;
  try
    Zip.Open(Report,zmRead);
    Require((Zip.IndexOf('HomeLibRu-info.txt')>=0) and (Zip.IndexOf('HomeLibRu-components.txt')>=0) and
      (Zip.IndexOf(ExtractFileName(DiagnosticLogFile))>=0),'Reader report omitted versions or current log');
  finally Zip.Free; end;
  Writeln('PASS Reader help diagnostic menu current log copyable folder ZIP owner palette resize and 96/144/192 DPI'); Flush(Output);
end;

procedure TestReadableDiagnostics;
var Host: TfrmReaderHost; Zip: TZipFile; Root, OldTemp, OldTmp, Log, Report, OriginalHash: string;
  Original, Archived: TBytes;
begin
  RequireIsolatedRegression;
  OldTemp:=GetEnvironmentVariable('TEMP'); OldTmp:=GetEnvironmentVariable('TMP');
  Root:=Settings.AppPath+'diagnostic-display-temp'; ForceDirectories(Root);
  SetEnvironmentVariable('TEMP',PChar(Root)); SetEnvironmentVariable('TMP',PChar(Root));
  try
    Require(SameFileName(DiagnosticLogDirectory,TPath.Combine(Root,'HomeLibRu-Logs')),
      'Diagnostic viewer fixture escaped its temporary profile');
    ForceDirectories(DiagnosticLogDirectory);
    Log:=DiagnosticLogFile;
    TFile.WriteAllText(Log,
      '{"time":"2026-11-10T13:14:15Z","level":"error","operation":"reader-diagnostics-fixture",'+
      '"message":"Первая строка \u2014 \u0451 \ud83d\ude42\nВторая строка\nБуквальный код: \\u041F"}'+sLineBreak+
      '{"message":'+sLineBreak,TEncoding.UTF8);
    LogDiagnosticMessage('catalogue-test','Заключительная запись');
    Original:=TFile.ReadAllBytes(Log); OriginalHash:=THashSHA2.GetHashStringFromFile(Log);
    CheckDiagnosticsDialog(frmMain,TMenuItem(frmMain.FindComponent('miDiagnostics')),True);
    Host:=TfrmReaderHost.Create(nil);
    try CheckReaderDiagnosticsMenu(Host,True); finally Host.Free; end;
    Report:=Root+'\original-log.zip';
    SaveDiagnosticReport(Report);
    Zip:=TZipFile.Create;
    try
      Zip.Open(Report,zmRead); Zip.Read(ExtractFileName(Log),Archived);
      Require((Length(Archived)=Length(Original)) and CompareMem(@Archived[0],@Original[0],Length(Original)),
        'Technical report did not preserve the original JSON bytes');
    finally Zip.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Log)=OriginalHash,
      'Viewing a diagnostic file rewrote its JSON bytes');
    Writeln('PASS catalogue and Reader show readable Unicode logs and export the unchanged technical ZIP');
  finally
    SetEnvironmentVariable('TEMP',PChar(OldTemp)); SetEnvironmentVariable('TMP',PChar(OldTmp));
  end;
end;
