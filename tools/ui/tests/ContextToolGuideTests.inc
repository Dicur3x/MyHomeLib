procedure TestContextToolGuides(CID:Integer);
const Topics:array[0..2] of string=('book-compression','book-duplicates','book-metadata-fill');
  Names:array[0..2] of string=('CompressionContextGuide','DuplicatesContextGuide','MetadataContextGuide');
  Inputs:array[0..2] of string=('CompressionProfile','btnFindBookDuplicates','cbMetadataField0');
  Intros:array[0..2] of string=('CompressionOptionsIntro','DuplicateIntro','lblMetadataFillScope');
var OriginalTheme:Boolean; Host,Popup:TForm; Tool:TContextToolGuide; Guide:TFirstUseGuide;
  Collection:IBookCollection; BeforeData,PreferencesSHA:string; Ini:TMemIniFile;
  FocusBefore:TWinControl; ActiveBefore,ForegroundBefore:HWND; FocusChecks:Integer; FocusFailure:string;

  procedure Pump;
  begin
    var UntilTick:=GetTickCount64+60;
    repeat Application.ProcessMessages; CheckSynchronize(1); Sleep(1); until GetTickCount64>=UntilTick;
  end;
  procedure Preferences(Topic:Integer; Seen:string; Disabled:Boolean);
  begin
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try
      Ini.WriteString('ToolGuidesSeen',Topics[Topic],Seen);
      Ini.WriteBool('ToolGuidesDisabled',Topics[Topic],Disabled);
      Ini.WriteString('ContextGuideSentinel','Keep','unchanged');
      Ini.UpdateFile;
    finally Ini.Free; end;
  end;
  procedure OpenHost(Kind,PPI:Integer);
  begin
    case Kind of
      0: begin
        var Options:=Default(TBookCompressionOperationOptions);
        Options.Profile:='balanced'; Options.WorkRoot:=Settings.WorkPath;
        Host:=TfrmBookCompressionOptions.CreateOptions(frmMain,1,Options);
      end;
      1: Host:=TfrmBookDuplicates.CreateForCollection(frmMain,Collection);
      2: Host:=TfrmBookMetadataFill.CreateForCollection(frmMain,CID);
    end;
    Host.ScaleForPPI(PPI);
    Tool:=Host.FindComponent(Names[Kind]) as TContextToolGuide;
    Require(Assigned(Tool) and Assigned(Tool.HelpButton.OnClick),'Tool-local help button is absent');
    var Intro:=Host.FindComponent(Intros[Kind]) as TControl;
    Require((Tool.HelpButton.Parent=Intro.Parent) and
      (Intro.BoundsRect.Right<=Tool.HelpButton.Left) and
      (Tool.HelpButton.BoundsRect.Right<=Tool.HelpButton.Parent.ClientWidth),
      'Help button overlaps the tool introduction');
    Host.Show;
    var Input:=Host.FindComponent(Inputs[Kind]) as TWinControl;
    Input.SetFocus; var BeforeChecks:=FocusChecks;
    Pump;
    Popup:=Tool.FindComponent('ToolGuidePopup'+Topics[Kind].Replace('-','')) as TForm;
    Require(Assigned(Popup),'First-use controller did not initialize its guide');
    Guide:=Popup.FindComponent('ToolFirstUseGuide') as TFirstUseGuide;
    Require(FocusChecks>BeforeChecks,'Automatic first-use path was not observed');
    Require(FocusFailure='',FocusFailure);
  end;
  procedure CheckGuide;
  begin
    var Work:=Host.Monitor.WorkareaRect;
    Require(Popup.Visible and Guide.Expanded,'Context guide is not visible/expanded');
    Require((Popup.Left>=Work.Left) and (Popup.Top>=Work.Top) and
      (Popup.BoundsRect.Right<=Work.Right) and (Popup.BoundsRect.Bottom<=Work.Bottom),
      'Context guide is outside the work area');
    for var Name in ['GuideSummary','GuideDetails'] do
    begin
      var LabelControl:=Guide.FindComponent(Name) as TLabel;
      Popup.Canvas.Font.Assign(LabelControl.Font); var Bounds:=Rect(0,0,LabelControl.Width,0);
      DrawTextW(Popup.Canvas.Handle,PChar(LabelControl.Caption),Length(LabelControl.Caption),Bounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require((Bounds.Height<=LabelControl.Height) and
        (LabelControl.BoundsRect.Bottom<=Guide.ClientHeight),'Guide text is clipped');
    end;
    for var Name in ['GuideContextHelp','GuideToggle','GuideMore','GuideNever'] do
    begin
      var Control:=Guide.FindComponent(Name) as TControl;
      Require(Control.Visible and (Control.Left>=0) and
        (Control.BoundsRect.Right<=Guide.ClientWidth) and
        (Control.BoundsRect.Bottom<=Guide.ClientHeight),Format('Guide action is clipped: %s %d,%d %dx%d parent %dx%d',
          [Name,Control.Left,Control.Top,Control.Width,Control.Height,Guide.ClientWidth,Guide.ClientHeight]));
    end;
    var More:=Guide.FindComponent('GuideMore') as TButton;
    Require(Assigned(More.OnClick),'Context guide has no direct-help action');
  end;
  procedure CheckIdle(Kind:Integer);
  begin
    Require(Host.ModalResult=mrNone,'Help accepted/closed its tool');
    case Kind of
      0: Require(TfrmBookCompressionOptions(Host).SelectedOptions.Profile='balanced',
        'Help changed compression settings');
      1: Require(not TfrmBookDuplicates(Host).Plan.Ready and
        not TfrmBookDuplicates(Host).CatalogChanged,'Help scanned or changed duplicates');
      2: Require(not TfrmBookMetadataFill(Host).Busy and
        not TfrmBookMetadataFill(Host).CommittedChanges,'Help started metadata processing');
    end;
  end;
begin
  RequireIsolatedRegression; OriginalTheme:=MHLThemeDark; Host:=nil;
  Collection:=SystemDB.GetCollection(CID); BeforeData:=MLIReadCatalogData(CID);
  FocusChecks:=0;
  ContextGuideShowProbe:=procedure(After:Boolean)
    begin
      if not After then
      begin
        FocusBefore:=FindControl(GetFocus); ActiveBefore:=GetActiveWindow; ForegroundBefore:=GetForegroundWindow;
      end
      else
      begin
        if FindControl(GetFocus)<>FocusBefore then FocusFailure:='Automatic guide changed the input component';
        if GetActiveWindow<>ActiveBefore then FocusFailure:='Automatic guide activated another window';
        if GetForegroundWindow<>ForegroundBefore then FocusFailure:='Automatic guide changed foreground application';
        Inc(FocusChecks);
      end;
    end;
  try
    for var Dark in [False,True] do
      for var PPI in [96,216] do
        for var Kind:=0 to 2 do
        begin
          SetMHLTheme(Dark); Pump; Preferences(Kind,'earlier-release',False);
          PreferencesSHA:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
          try
            OpenHost(Kind,PPI); CheckGuide; CheckIdle(Kind);
            if Dark and (PPI=216) and (Kind=0) and
              FileExists(Settings.AppPath+'context-guide-preview.marker') then
            begin
              TFile.WriteAllText(Settings.AppPath+'context-guide-preview.ready','ready',TEncoding.UTF8);
              var Deadline:=GetTickCount64+300000;
              while not FileExists(Settings.AppPath+'context-guide-preview.done') do
              begin Require(GetTickCount64<Deadline,'Context guide preview timed out'); Pump; end;
            end;
            Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=PreferencesSHA,
              'Opening context help persisted preferences before acknowledgement');
            TButton(Guide.FindComponent('GuideToggle')).Click; Pump;
            Require(not Popup.Visible,'Acknowledged context guide remains in front');
            Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
            try Require((Ini.ReadString('ToolGuidesSeen',Topics[Kind],'')=PROGRAM_RELEASE_VERSION) and
              (Ini.ReadString('ContextGuideSentinel','Keep','')='unchanged'),
              'Acknowledgement lost the topic version or another preference');
            finally Ini.Free; end;
          finally FreeAndNil(Host); end;
          try
            OpenHost(Kind,PPI);
            Require(not Popup.Visible,'Same beta repeated an acknowledged guide');
            Tool.HelpButton.Click; Pump; CheckGuide; CheckIdle(Kind);
            var NarrowWidth:=Popup.Width-MulDiv(80,PPI,96);
            Popup.Width:=NarrowWidth; Pump;
            Require(Popup.Width=NarrowWidth,'Context guide overwrote a user resize');
            CheckGuide;
            TCheckBox(Guide.FindComponent('GuideNever')).Checked:=True;
            Popup.Close; Pump; Require(not Popup.Visible,'Closing the guide did not hide it');
          finally FreeAndNil(Host); end;
          Preferences(Kind,'earlier-release',True);
          try
            OpenHost(Kind,PPI); Require(not Popup.Visible,'Disabled guide reopened for another beta');
            Tool.HelpButton.Click; Pump; CheckGuide;
            PreferencesSHA:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
            var Hold:=TFileStream.Create(Settings.SettingsFileName,fmOpenRead or fmShareDenyWrite);
            try TButton(Guide.FindComponent('GuideToggle')).Click; Pump;
            finally Hold.Free; end;
            Require(not Popup.Visible and (THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=PreferencesSHA),
              'Unavailable preference storage blocked the tool or rewrote preferences');
            CheckIdle(Kind);
          finally FreeAndNil(Host); end;
          Require(MLIReadCatalogData(CID)=BeforeData,'Guide-only interaction changed catalogue data');
          Writeln('PASS contextual tool guide ',Topics[Kind],' ppi=',PPI,' dark=',Dark,
            ' automatic focus layout acknowledgement repeat suppression manual and readonly preferences');
        end;
  finally ContextGuideShowProbe:=nil; Host.Free; SetMHLTheme(OriginalTheme); end;
end;
