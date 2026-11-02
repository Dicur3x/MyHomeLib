type
  TReaderDiagnosticsProbe = class
    ParentForm: TForm;
    Timer: TTimer;
    Deadline: UInt64;
    Shown: Boolean;
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

procedure CheckReaderDiagnosticsMenu(ParentForm: TForm);
var Probe: TReaderDiagnosticsProbe; Item: TMenuItem; Report: string; Zip: TZipFile;
begin
  Require(Assigned(ParentForm.Menu),'Reader has no main menu');
  Item:=nil;
  for var I:=0 to ParentForm.Menu.ComponentCount-1 do
    if ParentForm.Menu.Components[I].Name='ReaderDiagnostics' then Item:=TMenuItem(ParentForm.Menu.Components[I]);
  Require(Assigned(Item) and Assigned(Item.OnClick) and Assigned(Item.Parent) and
    (StripHotkey(Item.Parent.Caption)='Помощь'),'Reader help has no diagnostic menu entry');
  Probe:=TReaderDiagnosticsProbe.Create; Probe.ParentForm:=ParentForm;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False; Probe.Timer.Interval:=50;
  Probe.Timer.OnTimer:=Probe.Tick; Probe.Deadline:=GetTickCount64+60000;
  try
    Probe.Timer.Enabled:=True; Item.Click;
    Require(Probe.Shown and (Probe.Failure=''),'Reader diagnostics: '+Probe.Failure);
    Report:=Settings.AppPath+'reader-diagnostics-'+TGUID.NewGuid.ToString+'.zip';
    SaveDiagnosticReport(Report);
    Zip:=TZipFile.Create;
    try
      Zip.Open(Report,zmRead);
      Require((Zip.IndexOf('HomeLibRu-info.txt')>=0) and (Zip.IndexOf('HomeLibRu-components.txt')>=0) and
        (Zip.IndexOf(ExtractFileName(DiagnosticLogFile))>=0),'Reader report omitted versions or current log');
    finally Zip.Free; end;
  finally Probe.Timer.Free; Probe.Free; end;
  Writeln('PASS Reader help diagnostic menu current log copyable folder ZIP owner palette resize and 96/144/192 DPI'); Flush(Output);
end;
