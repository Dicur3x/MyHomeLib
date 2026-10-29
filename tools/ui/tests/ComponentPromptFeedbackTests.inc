type
  TReaderFormatsHelpProbe = class
    Seen: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderFormatsHelpProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I].Name='ReaderFormatsDialog') and Screen.Forms[I].Visible then
    begin
      TTimer(Sender).Enabled:=False; Seen:=True;
      var Dialog:=TForm(Screen.Forms[I]);
      var Text:=TMemo(Dialog.FindComponent('ReaderFormatsText'));
      Require(Assigned(Text) and Text.ReadOnly and (Text.ScrollBars=ssVertical),
        'Reader format help is not readable and scrollable');
      var Contents:string:=Text.Text;
      Require(Contents.Contains('DOCX, ODT') and Contents.Contains('вместе с читалкой') and
        Contents.Contains('PDFium, DjVuLibre и DocSharp'), 'Reader help lost native formats or update ownership');
      for var PPI in [96,144,192] do
      begin
        Dialog.ScaleForPPI(PPI);
        for var Control in Dialog do
          if Control is TControl then
            Require((TControl(Control).Left>=0) and (TControl(Control).Top>=0) and
              (TControl(Control).Left+TControl(Control).Width<=Dialog.ClientWidth) and
              (TControl(Control).Top+TControl(Control).Height<=Dialog.ClientHeight), 'Reader format help is clipped');
      end;
      Dialog.ModalResult:=mrOk; Exit;
    end;
end;

procedure TestComponentPromptFeedback;
var Dialog: TReaderModuleForm; Prompt: TForm; Memo: TMemo; Started: UInt64;
  Purpose, Reason, Displayed: string; Host: TfrmReaderHost; Probe: TReaderFormatsHelpProbe;
  Timer: TTimer; SavedDark: Boolean;
begin
  RequireIsolatedRegression;
  for var ID in ['BookProcessing','ImageProcessing'] do
    for var Context in [False,True] do
    begin
      Dialog:=TReaderModuleForm.Create(nil); Dialog.RequestedID:=ID;
      try
        Purpose:=ComponentPurpose(ID); Reason:=Purpose;
        if Context then Reason:='Для выбранной книги нужен этот модуль.'+sLineBreak+Purpose.Replace(#13,'');
        Dialog.RequestComponent(ID,Reason,True); Started:=GetTickCount64;
        repeat
          Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
          Prompt:=TForm(Dialog.FindComponent('OptionalComponentPrompt'));
        until (Assigned(Prompt) and TButton(Prompt.FindComponent('ComponentPromptDownload')).Enabled) or
          (GetTickCount64-Started>5000);
        Require(Assigned(Prompt),'Compact module prompt absent');
        Memo:=TMemo(Prompt.FindComponent('ComponentPromptReason'));
        Displayed:=string(Memo.Text).Replace(#13,''); Purpose:=Purpose.Replace(#13,'');
        var Start:=Pos(Purpose,Displayed);
        Require((Start>0) and (PosEx(Purpose,Displayed,Start+Length(Purpose))=0),
          'Module description is absent or repeated: '+ID);
        if Context then Require(Displayed.Contains('Для выбранной книги'),'Description removed operation context');
        var Size:=string(TLabel(Prompt.FindComponent('ComponentPromptBytes')).Caption);
        Require(Size='Нужно скачать: 128 Б','Small download size rounded to zero: '+Size);
        Require(Displayed.Contains('128 Б') and not Displayed.Contains('0.0 МБ') and not Displayed.Contains('0,0 МБ'),
          'Description disagrees with the download size');
        Require((Dialog.Requests.Count=2) and (Dialog.DownloadID=''),
          'Prompt checked unrelated modules or downloaded without consent');
        TButton(Prompt.FindComponent('ComponentPromptCancel')).Click;
      finally Dialog.Free; end;
    end;
  Writeln('PASS component prompts show purpose once preserve context and agree on small download sizes');
  Host:=TfrmReaderHost.Create(nil); Probe:=TReaderFormatsHelpProbe.Create; Timer:=TTimer.Create(nil);
  SavedDark:=MHLThemeDark;
  try
    Timer.Enabled:=False; Timer.Interval:=80; Timer.OnTimer:=Probe.Tick;
    var Item:=TMenuItem(Host.Menu.FindComponent('ReaderFormatsHelp'));
    Require(Assigned(Item) and Assigned(Item.OnClick),'Reader lacks discoverable formats help');
    for var Dark in [False,True] do
    begin
      SetMHLTheme(Dark); Probe.Seen:=False; Timer.Enabled:=True; Item.Click;
      Require(Probe.Seen,'Reader formats help did not open');
    end;
  finally SetMHLTheme(SavedDark); Timer.Free; Probe.Free; Host.Free; end;
  Writeln('PASS reader formats help names native handlers and external updates with scrollable light dark 96 144 192 DPI dialog');
end;
