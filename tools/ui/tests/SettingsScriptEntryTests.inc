type
  TScriptSettingsEntryProbe = class
    Timer:TTimer;
    DPI, Visits:Integer;
    ExpectExpanded:Boolean;
    Deadline:UInt64;
    procedure Tick(Sender:TObject);
  end;

procedure TScriptSettingsEntryProbe.Tick(Sender:TObject);
var Dialog:TfrmSettings; Guide:TFirstUseGuide; Details:TLabel;
  Bitmap:TBitmap; Bounds:TRect; Snapshot:TBitmap; Png:TPngImage;
begin
  if GetTickCount64>=Deadline then
  begin
    for var I:=0 to Screen.FormCount-1 do
      Writeln(Format('TRACE settings form %s visible=%d modal=%d caption=%s',
        [Screen.Forms[I].ClassName,Ord(Screen.Forms[I].Visible),
         Ord(fsModal in Screen.Forms[I].FormState),Screen.Forms[I].Caption]));
    if Assigned(Screen.ActiveCustomForm) then
      Writeln('TRACE settings active=',Screen.ActiveCustomForm.ClassName,':',Screen.ActiveCustomForm.Caption);
    Require(False,'Script settings entry did not open its dialog');
  end;
  Dialog:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmSettings) and Screen.Forms[I].Visible and
      (fsModal in Screen.Forms[I].FormState) then Dialog:=TfrmSettings(Screen.Forms[I]);
  if not Assigned(Dialog) then Exit;
  Timer.Enabled:=False;
  Require(GetActiveWindow=Dialog.Handle,Format('Scripts dialog lost native activation: active=%d dialog=%d',
    [GetActiveWindow,Dialog.Handle]));
  Require(Dialog.pcSetPages.ActivePage=Dialog.tsScripts,'External-tools command opened the wrong settings page');
  Require(Assigned(Dialog.tvSections.Selected) and (Dialog.tvSections.Selected.Index=Dialog.tsScripts.PageIndex),
    'Settings page and navigation selection disagree');
  Dialog.ScaleForPPI(DPI);
  Guide:=Dialog.FindComponent('ScriptsFirstUseGuide') as TFirstUseGuide;
  Require(Assigned(Guide) and Guide.Visible,'Script explanation is missing from the real settings dialog');
  Require(Guide.Expanded=ExpectExpanded,'Script explanation did not remember acknowledgement');
  Require(not Dialog.lvScripts.GridLines,'Empty scripts still appear as a spreadsheet');
  Require(Dialog.lvScripts.Top>=Guide.Top+Guide.Height,'Scripts table overlaps the inline explanation');
  Require(Dialog.lvScripts.Height>=MulDiv(60,DPI,96),'Explanation leaves no room for the scripts table');
  Bitmap:=TBitmap.Create;
  try
    if Guide.Expanded then
    begin
      if DPI in [96,144,216] then
      begin
        Dialog.Update; Snapshot:=Dialog.GetFormImage; Png:=TPngImage.Create;
        try
          Png.Assign(Snapshot);
          Png.SaveToFile(Settings.AppPath+Format('scripts-dpi-%d-dark-%d.png',[DPI,Ord(MHLThemeDark)]));
        finally Png.Free; Snapshot.Free; end;
      end;
      Details:=Guide.FindComponent('GuideDetails') as TLabel;
      Bitmap.Canvas.Font.PixelsPerInch:=Details.Font.PixelsPerInch;
      Bitmap.Canvas.Font.Assign(Details.Font);
      Bounds:=Rect(0,0,Details.Width,0);
      DrawText(Bitmap.Canvas.Handle,PChar(Details.Caption),Length(Details.Caption),Bounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require(Details.Height>=Bounds.Height,Format('Scripts explanation text is clipped: DPI=%d width=%d height=%d needed=%d font=%d fontPPI=%d',
        [DPI,Details.Width,Details.Height,Bounds.Height,Details.Font.Height,Details.Font.PixelsPerInch]));
      TButton(Guide.FindComponent('GuideToggle')).Click;
      Require(not Guide.Expanded,'Acknowledging script explanation did not collapse it');
    end
    else
    begin
      TButton(Guide.FindComponent('GuideContextHelp')).Click;
      Require(Guide.Expanded,'Script explanation cannot be reopened in the real dialog');
      TButton(Guide.FindComponent('GuideToggle')).Click;
    end;
    Require(Dialog.lvScripts.Height>=MulDiv(100,DPI,96),'Collapsed explanation did not return room to the scripts');
  finally Bitmap.Free; end;
  Inc(Visits); Dialog.ModalResult:=mrCancel;
end;

procedure TestSettingsScriptEntry;
var Probe:TScriptSettingsEntryProbe; ParentMenu,Menu:TMenuItem; SavedDark:Boolean;
  Ini:TMemIniFile; ScriptCount:Integer;
begin
  RequireIsolatedRegression;
  SavedDark:=MHLThemeDark; ScriptCount:=Settings.Scripts.Count;
  frmMain.Show; Application.ProcessMessages;
  Probe:=TScriptSettingsEntryProbe.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
  Probe.Timer.Interval:=30; Probe.Timer.OnTimer:=Probe.Tick;
  try
    for var Dark in [False,True] do
      for var DPI in [96,144,192,216,240,288] do
      begin
        SetMHLTheme(Dark); RefreshMHLTheme;
        // A user opens the next menu on a later message-loop turn. Let VCL's
        // queued style HWND rebuilds finish before that separate input action.
        Application.ProcessMessages; CheckSynchronize(0);
        Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
        try
          Ini.DeleteKey('ToolGuidesSeen','external-scripts');
          Ini.DeleteKey('ToolGuidesDisabled','external-scripts');
          Ini.WriteString('GuideSentinel','Keep','Оставить ё'); SaveMemIniFileAtomically(Ini);
        finally Ini.Free; end;
        Probe.DPI:=DPI;
        for var Pass:=0 to 1 do
        begin
          Probe.ExpectExpanded:=Pass=0; Probe.Deadline:=GetTickCount64+25000;
          ParentMenu:=frmMain.FindComponent('miExternalTools') as TMenuItem;
          Require(Assigned(ParentMenu),'Actual external-tools menu is missing');
          Menu:=ParentMenu.FindComponent('miExternalToolsSetup') as TMenuItem;
          Require(Assigned(Menu) and Assigned(Menu.OnClick),'Actual external-tools settings menu is missing');
          Probe.Timer.Enabled:=True; Menu.Click;
          Require(not Probe.Timer.Enabled,'External-tools menu did not visit the settings dialog');
          Require(Settings.Scripts.Count=ScriptCount,'Opening or canceling script settings changed configured commands');
        end;
        Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
        try Require(Ini.ReadString('GuideSentinel','Keep','')='Оставить ё','Guide acknowledgement overwrote unrelated settings');
        finally Ini.Free; end;
        Writeln(Format('PASS actual script-settings menu DPI=%d dark=%d opens Scripts and remembers inline help',
          [DPI,Ord(Dark)])); Flush(Output);
      end;
    Require(Probe.Visits=24,'Script settings entry cases were incomplete');
  finally Probe.Timer.Free; Probe.Free; SetMHLTheme(SavedDark); RefreshMHLTheme; end;
end;
