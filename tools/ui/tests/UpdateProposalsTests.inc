// Include after Require / TFCTModalProbe; existing DPR uses cover VCL, Indy and HTTP.
{$I ..\..\..\Program\Tests\ComponentCheckFixture.inc}

function UpdateProposalAccessibleObjectFromWindow(Window: HWND; ObjectID: DWORD;
  const IID: TGUID; out Accessible: IDispatch): HRESULT; stdcall;
  external 'oleacc.dll' name 'AccessibleObjectFromWindow';

function UpdateProposalGetDpiForWindow(Window: HWND): UINT; stdcall;
  external 'user32.dll' name 'GetDpiForWindow';

type
  TUpdateProposalServer = class
  private
    FHTTP: TIdHTTPServer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  public
    HeadURL: string;
    Requests: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TUpdateProposalForm = class(TfrmProgramUpdate)
  private
    FHeadURL: string;
    procedure CheckRequested(Sender: TObject);
  protected
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
      const Job: string): TProgramDownloadThread; override;
  public
    FailureID: string;
    WorkerCalls: Integer;
    constructor CreateForHead(const HeadURL: string);
  end;

  TUpdateRestorePageForm = class(TfrmProgramUpdate)
  protected
    procedure OpenReleasePage(const URL: string); override;
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; override;
    function CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
      const Job: string): TProgramDownloadThread; override;
  public
    OpenedURL: string;
    PageCalls: Integer;
  end;

  TUpdateKeyboardProbe = class
  public
    PrimaryCalls: Integer;
    procedure PrimaryClicked(Sender: TObject);
  end;

  TUpdateKeyboardHost = class(TForm)
  private
    procedure AppThemeChanged(var Message: TMessage); message WM_MHL_APP_THEME;
  public
    ThemeCallback: TProc;
  end;

constructor TUpdateProposalServer.Create;
begin
  inherited;
  FHTTP:=TIdHTTPServer.Create(nil); FHTTP.KeepAlive:=False;
  FHTTP.OnCommandGet:=Command; FHTTP.OnCommandOther:=Command;
  FHTTP.Bindings.Clear;
  with FHTTP.Bindings.Add do begin IP:='127.0.0.1'; Port:=0; end;
  FHTTP.Active:=True;
  HeadURL:=Format('http://127.0.0.1:%d/head',[FHTTP.Bindings[0].Port]);
end;

destructor TUpdateProposalServer.Destroy;
begin
  if Assigned(FHTTP) then begin FHTTP.Active:=False; FHTTP.Free; end;
  inherited;
end;

procedure TUpdateProposalServer.Command(Context: TIdContext;
  Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
begin
  InterlockedIncrement(Requests);
  if (Request.Command<>'HEAD') or (Request.Document<>'/head') then
  begin Response.ResponseNo:=404; Exit; end;
  Response.ContentType:='application/octet-stream';
  Response.ContentText:=StringOfChar('x',128); Response.ContentLength:=128;
end;

constructor TUpdateProposalForm.CreateForHead(const HeadURL: string);
begin
  inherited Create(nil); FHeadURL:=HeadURL; OnCheck:=CheckRequested;
end;

procedure TUpdateProposalForm.CheckRequested(Sender: TObject);
var Current: TProgramRelease;
begin
  if not StartCheckCycle(False) then Exit;
  Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
  ApplicationChecked(Current,True,''); CheckComponents(False);
end;

function TUpdateProposalForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin
  Inc(WorkerCalls); Result:=TComponentCheckFixtureWorker.Create(Window,FHeadURL,FailureID);
end;

function TUpdateProposalForm.CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
  const Job: string): TProgramDownloadThread;
begin
  raise Exception.Create('Controlled source fixture prohibits package downloads');
end;

procedure TUpdateRestorePageForm.OpenReleasePage(const URL: string);
begin Inc(PageCalls); OpenedURL:=URL; end;

function TUpdateRestorePageForm.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin raise Exception.Create('Restore-page fixture prohibits source checks'); end;

function TUpdateRestorePageForm.CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
  const Job: string): TProgramDownloadThread;
begin raise Exception.Create('Restore-page fixture prohibits downloads'); end;

procedure TUpdateKeyboardProbe.PrimaryClicked(Sender: TObject);
begin Inc(PrimaryCalls); end;

procedure TUpdateKeyboardHost.AppThemeChanged(var Message: TMessage);
var Callback: TProc;
begin
  Callback:=ThemeCallback; ThemeCallback:=nil;
  if Assigned(Callback) then Callback();
end;

procedure UpdateProposalAssertNotesFormat(View: TUpdateNotesView; VCLPPI: Integer; const Phase: string);
var Body: TRichEdit; Format: TCharFormat2; Start, Selection, Numerator, Denominator, ExpectedTwips: Integer;
  WindowDPI: UINT; ZoomSupported: Boolean;
begin
  for var I:=0 to View.SectionCount-1 do
  begin
    Body:=View.SectionNotes(I); Start:=Body.SelStart; Selection:=Body.SelLength;
    try
      Body.SelStart:=0; Body.SelLength:=1;
      FillChar(Format,SizeOf(Format),0); Format.cbSize:=SizeOf(Format);
      Body.Perform(EM_GETCHARFORMAT,SCF_SELECTION,LPARAM(@Format));
      Numerator:=0; Denominator:=0;
      ZoomSupported:=Body.Perform(EM_GETZOOM,WPARAM(@Numerator),LPARAM(@Denominator))<>0;
      WindowDPI:=UpdateProposalGetDpiForWindow(Body.Handle);
      Writeln('TRACE update notes phase=',Phase,' theme=',Ord(MHLThemeDark),' section=',I,
        ' VCLPPI=',VCLPPI,' FontPPI=',Body.Font.PixelsPerInch,' HWND_DPI=',WindowDPI,
        ' yHeight_twips=',Format.yHeight,' ZoomPercent=',View.ZoomPercent,
        ' EM_GETZOOM=',Ord(ZoomSupported),' numerator=',Numerator,' denominator=',Denominator); Flush(Output);
      Require(WindowDPI>0,'Release notes have no valid native window DPI');
      // RTF stores points, not simulated VCL pixels: 10 pt = 200 twips.
      // The formatter rounds its half-point value before converting to twips.
      ExpectedTwips:=MulDiv(20,View.ZoomPercent,100)*10;
      Require(((Format.dwMask and CFM_SIZE)<>0) and (Format.yHeight=ExpectedTwips),
        'Release notes lost their logical 10-point font and explicit text zoom');
      Require(ZoomSupported and (((Numerator=0) and (Denominator=0)) or
        ((Numerator>0) and (Denominator>0) and (Int64(Numerator)<64*Int64(Denominator)) and
        (Int64(Denominator)<64*Int64(Numerator)))), 'Release notes expose an invalid native zoom ratio');
    finally Body.SelStart:=Start; Body.SelLength:=Selection; end;
  end;
end;

procedure TestUpdateKeyboardAccessibility;
var Host: TForm; View: TUpdateNotesView; Primary: TButton; Probe: TUpdateKeyboardProbe;
  SavedTheme, SavedAppCheck, SavedCatalogCheck, SavedMainVisible: Boolean; Header: TButton; Location: TPoint; Notes: string;
  Accessible: OleVariant; Dispatch: IDispatch; AccessibleID: TGUID;
  FirstActivation: Boolean; ForegroundDeadline: UInt64; RemovedFocus: TButton;
  ActiveFormName: string;
  NewInput: TForm; NewInputButton: TButton;
begin
  RequireIsolatedRegression; SavedTheme:=MHLThemeDark;
  SavedAppCheck:=Settings.CheckUpdate; SavedCatalogCheck:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  SavedMainVisible:=frmMain.Visible; frmMain.Show; Application.ProcessMessages;
  Probe:=TUpdateKeyboardProbe.Create; Host:=nil; FirstActivation:=True;
  Accessible:=Unassigned; Dispatch:=nil;
  AccessibleID:=StringToGUID('{618736E0-3C3D-11CF-810C-00AA00389B71}');
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
      for var PPI in TArray<Integer>.Create(96,144,192) do
      begin
        SetMHLTheme(Dark); Host:=TUpdateKeyboardHost.CreateNew(nil);
        try
          Host.Caption:='HomeLib Ru update keyboard fixture PID '+IntToStr(GetCurrentProcessId)+
            ' theme='+IntToStr(Ord(Dark))+' PPI='+IntToStr(PPI);
          Host.ClientWidth:=620; Host.ClientHeight:=420;
          Primary:=TButton.Create(Host); Primary.Parent:=Host; Primary.Align:=alBottom;
          Primary.Caption:='Do not activate while a release header has focus';
          Primary.Default:=True; Primary.OnClick:=Probe.PrimaryClicked;
          View:=TUpdateNotesView.Create(Host); View.Parent:=Host; View.Align:=alClient;
          Notes:='2.7.0_pre5.99'+sLineBreak+StringOfChar('x',100)+sLineBreak;
          for var I:=1 to 25 do Notes:=Notes+'Long owned history line '+IntToStr(I)+sLineBreak;
          Notes:=Notes+'2.7.0_pre5.98'+sLineBreak+'Older owned release.'+sLineBreak+
            '2.7.0_pre5.97'+sLineBreak+'Third owned release.'+sLineBreak+
            '2.7.0_pre5.96'+sLineBreak+'Fourth owned release.'+sLineBreak+
            '2.7.0_pre5.95'+sLineBreak+'Fifth owned release.'+sLineBreak+
            '2.7.0_pre5.94'+sLineBreak+'Sixth owned release.'+sLineBreak+
            '2.7.0_pre5.93'+sLineBreak+'Final owned release.';
          View.Load(Notes); Host.Show; Application.ProcessMessages; Host.ScaleForPPI(PPI);
          Require((Host.Font.PixelsPerInch=PPI) and (View.SectionHeader(0).Font.PixelsPerInch=PPI),
            'Release headers did not adopt simulated VCL DPI');
          UpdateProposalAssertNotesFormat(View,PPI,'scaled');
          Header:=View.SectionHeader(0);
          // Show/SetFocus alone can leave the VCL ActiveControl in a background
          // window (for example while the IDE owns a modal dialog). MSAA reports
          // actual system focus, so activate this owned fixture before querying it.
          Host.BringToFront;
          Winapi.Windows.SetForegroundWindow(Host.Handle);
          Winapi.Windows.SetActiveWindow(Host.Handle);
          if FirstActivation then
          begin
            // A background wrapper cannot bypass the Windows foreground lock.
            // Give the operator time to activate only this named test window.
            Writeln('READY update keyboard fixture: ',Host.Caption,
              '; activate this window within 45 seconds; keep it foreground until PASS');
            Flush(Output); ForegroundDeadline:=GetTickCount64+45000;
            repeat
              Application.ProcessMessages; CheckSynchronize(0);
              if (GetForegroundWindow=Host.Handle) and (GetActiveWindow=Host.Handle) then Break;
              TThread.Sleep(10);
            until GetTickCount64>=ForegroundDeadline;
            FirstActivation:=False;
          end;
          Header.SetFocus; Application.ProcessMessages;
          Require((GetForegroundWindow=Host.Handle) and (GetActiveWindow=Host.Handle),
            'Keyboard fixture could not become the foreground active window');
          Require(Header.Focused and (Winapi.Windows.GetFocus=Header.Handle),
            'Release header did not receive actual Windows keyboard focus');
          Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(Header.Handle,DWORD($FFFFFFFC),AccessibleID,Dispatch)),
            'Release header exposes no native accessibility object');
          Accessible:=Dispatch;
          Require((Integer(Accessible.accRole[0])=$2B) and Header.TabStop and
            string(Accessible.accName[0]).Contains('2.7.0_pre5.99') and
            string(Accessible.accName[0]).Contains('развёрнуто'),
            'Release header lacks its native button role, accessible name, state or Tab stop');
          Require((ColorToRGB(Header.Font.Color)=ColorToRGB(MHLThemeText)) and
            (fsBold in Header.Font.Style),'Release header lost readable theme font');
          Require((Integer(Accessible.accState[0]) and 4)<>0,'Release header exposes no focused accessibility state');
          Accessible:=Unassigned; Dispatch:=nil;
          Host.Perform(CM_DIALOGKEY,VK_TAB,0);
          Require(View.SectionNotes(0).Focused,'Tab does not reach the expanded release text');
          Host.Perform(CM_DIALOGKEY,VK_TAB,0);
          Require(View.SectionHeader(1).Focused,'Tab does not reach the next collapsed release');
          Header:=View.SectionHeader(1);
          Location:=View.ScreenToClient(Header.ClientToScreen(Point(0,0)));
          Require((Location.Y>=0) and (Location.Y+Header.Height<=View.ClientHeight),
            'Tab focus left its collapsed release header outside the viewport');
          Host.Perform(CM_DIALOGKEY,VK_RETURN,0);
          Require(View.IsExpanded(1) and Header.Focused and string(Header.Caption).Contains('развёрнуто'),
            'Enter failed to expand once or lost header focus');
          Header.Perform(WM_KEYDOWN,VK_SPACE,0); Header.Perform(WM_KEYUP,VK_SPACE,0);
          Require(not View.IsExpanded(1) and Header.Focused and string(Header.Caption).Contains('свёрнуто'),
            'Space failed to collapse once or lost header focus');
          Host.Perform(CM_DIALOGKEY,VK_TAB,0);
          Require(View.SectionHeader(2).Focused,'Tab entered the invisible collapsed release body');
          Require(Probe.PrimaryCalls=0,'Enter on a release header activated the download/default action');
          // Programmatic collapse while reading must leave a visible keyboard target.
          View.SetExpanded(1,True); View.SectionNotes(1).SetFocus; View.SetExpanded(1,False);
          Require(View.SectionHeader(1).Focused,'Collapsing a focused release body lost keyboard focus');
          View.SetExpanded(1,True);
          View.Load(Notes+sLineBreak+'Updated notes.');
          Require(View.SectionHeader(1).Focused and View.IsExpanded(1),
            'Reloading notes lost the focused release identity or its expanded state');
          UpdateProposalAssertNotesFormat(View,PPI,'reloaded');
          View.ZoomPercent:=200;
          Require(View.SectionHeader(1).Focused and
            (View.SectionHeader(1).Height>MulDiv(30,PPI,96)),
            'Text zoom lost focus or clipped its release button');
          UpdateProposalAssertNotesFormat(View,PPI,'text-zoom');
          ActiveFormName:='<nil>';
          if Assigned(Screen.ActiveCustomForm) then ActiveFormName:=Screen.ActiveCustomForm.ClassName+':'+Screen.ActiveCustomForm.Name;
          Writeln('TRACE update theme before theme=',Ord(MHLThemeDark),' expanded=',Ord(View.IsExpanded(1)),
            ' focused=',Ord(View.SectionHeader(1).Focused),' native_focus=',Winapi.Windows.GetFocus,
            ' header=',View.SectionHeader(1).Handle,' foreground=',GetForegroundWindow,' host=',Host.Handle,
            ' active_form=',ActiveFormName,' host_visible=',Ord(Host.Visible),' can_focus=',Ord(View.SectionHeader(1).CanFocus)); Flush(Output);
          SetMHLTheme(not Dark); Application.ProcessMessages;
          ActiveFormName:='<nil>';
          if Assigned(Screen.ActiveCustomForm) then ActiveFormName:=Screen.ActiveCustomForm.ClassName+':'+Screen.ActiveCustomForm.Name;
          Writeln('TRACE update theme after theme=',Ord(MHLThemeDark),' expanded=',Ord(View.IsExpanded(1)),
            ' focused=',Ord(View.SectionHeader(1).Focused),' native_focus=',Winapi.Windows.GetFocus,
            ' header=',View.SectionHeader(1).Handle,' foreground=',GetForegroundWindow,' host=',Host.Handle,
            ' active_form=',ActiveFormName,' host_visible=',Ord(Host.Visible),' can_focus=',Ord(View.SectionHeader(1).CanFocus)); Flush(Output);
          Require(View.IsExpanded(1),'Switching theme changed the expanded release state');
          Require(View.SectionHeader(1).Focused and (Winapi.Windows.GetFocus=View.SectionHeader(1).Handle),
            'Switching theme lost the actual Windows focus of the release header');
          Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(View.SectionHeader(1).Handle,
            DWORD($FFFFFFFC),AccessibleID,Dispatch)),'The themed release header lost its accessibility object');
          Accessible:=Dispatch;
          Require((Integer(Accessible.accState[0]) and 4)<>0,
            'The themed release header lost its focused accessibility state');
          UpdateProposalAssertNotesFormat(View,PPI,'themed');
          Accessible:=Unassigned; Dispatch:=nil;
          SetMHLTheme(Dark); Host.ScaleForPPI(96); Host.ScaleForPPI(PPI); Application.ProcessMessages;
          Require(View.SectionHeader(1).Focused and View.IsExpanded(1),
            'Changing VCL scale lost the focused/expanded release');
          UpdateProposalAssertNotesFormat(View,PPI,'scale-roundtrip');
          if not Dark and (PPI=96) then
          begin
            // A real theme callback can replace the focused control. The
            // production focus snapshot must observe its deletion, not retain
            // a dangling component pointer across that callback.
            RemovedFocus:=TButton.Create(Host); RemovedFocus.Parent:=Host;
            RemovedFocus.SetBounds(0,0,120,28); RemovedFocus.Caption:='Temporary focused control';
            RemovedFocus.SetFocus;
            Require(Winapi.Windows.GetFocus=RemovedFocus.Handle,'Focused-control lifetime fixture did not receive focus');
            TUpdateKeyboardHost(Host).ThemeCallback:=procedure begin FreeAndNil(RemovedFocus); end;
            SetMHLTheme(not Dark); Application.ProcessMessages;
            Require(not Assigned(RemovedFocus),'Theme callback did not remove its focused control');
            SetMHLTheme(Dark); Application.ProcessMessages;
            SetForegroundWindow(Host.Handle); SetActiveWindow(Host.Handle); View.SectionHeader(1).SetFocus;
            Require(View.SectionHeader(1).Focused,'Theme callback removal left release navigation unusable');
            Writeln('PASS update theme tolerates deletion of its formerly focused control in a real form callback'); Flush(Output);
            // A callback intentionally showing an existing hidden form must
            // keep that new input target instead of returning to this header.
            NewInput:=TForm.CreateNew(nil);
            try
              NewInput.Caption:='Owned theme callback input fixture';
              NewInputButton:=TButton.Create(NewInput); NewInputButton.Parent:=NewInput;
              NewInputButton.Caption:='New input target';
              TUpdateKeyboardHost(Host).ThemeCallback:=procedure
                begin
                  NewInput.Show; NewInputButton.SetFocus;
                  Require((GetForegroundWindow=NewInput.Handle) and NewInputButton.Focused and
                    (Winapi.Windows.GetFocus=NewInputButton.Handle),
                    'Theme callback did not establish its intended native input target');
                  Writeln('TRACE callback input selected form=',NewInput.Handle,' control=',NewInputButton.Handle); Flush(Output);
                end;
              SetMHLTheme(not Dark); Application.ProcessMessages;
              Require((GetForegroundWindow=NewInput.Handle) and NewInputButton.Focused and
                (Winapi.Windows.GetFocus=NewInputButton.Handle),
                'Theme focus restoration stole a newly shown callback input form');
              Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(NewInputButton.Handle,
                DWORD($FFFFFFFC),AccessibleID,Dispatch)),'New callback input lost native accessibility');
              Accessible:=Dispatch; Require((Integer(Accessible.accState[0]) and 4)<>0,
                'Deferred callback input lost its focused accessibility state');
              Accessible:=Unassigned; Dispatch:=nil;
            finally Accessible:=Unassigned; Dispatch:=nil; NewInput.Free; end;
            SetForegroundWindow(Host.Handle); SetActiveWindow(Host.Handle); View.SectionHeader(1).SetFocus;
            SetMHLTheme(Dark); Application.ProcessMessages;
            Require(View.SectionHeader(1).Focused,'Callback input fixture did not return to release navigation');
            Writeln('PASS update theme preserves a newly shown callback input form without restoring the old header'); Flush(Output);
            // Two theme changes before the queue is pumped must retire the
            // first snapshot and restore only the most recent input target.
            View.SectionHeader(1).SetFocus; SetMHLTheme(not Dark);
            View.SectionHeader(2).SetFocus; SetMHLTheme(Dark); Application.ProcessMessages;
            Require((GetForegroundWindow=Host.Handle) and View.SectionHeader(2).Focused and
              (Winapi.Windows.GetFocus=View.SectionHeader(2).Handle),
              'An older queued theme snapshot overrode the latest focused release');
            Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(View.SectionHeader(2).Handle,
              DWORD($FFFFFFFC),AccessibleID,Dispatch)),'Latest deferred release lost native accessibility');
            Accessible:=Dispatch; Require((Integer(Accessible.accState[0]) and 4)<>0,
              'Latest deferred release has no focused accessibility state');
            Accessible:=Unassigned; Dispatch:=nil;
            Writeln('PASS update theme coalesces rapid changes and preserves the latest native Windows and accessibility focus'); Flush(Output);
            // Destruction after Queue, before its first barrier, must remove
            // the weak control reference just as destruction inside callbacks.
            RemovedFocus:=TButton.Create(Host); RemovedFocus.Parent:=Host;
            RemovedFocus.Caption:='Pending snapshot deletion'; RemovedFocus.SetFocus;
            SetMHLTheme(not Dark); FreeAndNil(RemovedFocus); Application.ProcessMessages;
            SetMHLTheme(Dark); Application.ProcessMessages;
            SetForegroundWindow(Host.Handle); SetActiveWindow(Host.Handle); View.SectionHeader(1).SetFocus;
            Require((GetForegroundWindow=Host.Handle) and View.SectionHeader(1).Focused and
              (Winapi.Windows.GetFocus=View.SectionHeader(1).Handle),
              'Deleting a queued focus target broke later release navigation');
            Writeln('PASS update theme tolerates deletion of a queued focus target before deferred delivery'); Flush(Output);
          end;
          var More:=View.FindComponent('UpdateNotesMore') as TButton;
          Require((View.SectionCount=3) and More.Visible,'Keyboard history eagerly loaded older releases');
          View.SetExpanded(2,False); View.SectionHeader(2).SetFocus;
          Host.Perform(CM_DIALOGKEY,VK_TAB,0);
          Require(More.Focused and (Winapi.Windows.GetFocus=More.Handle),'Tab cannot reach history paging');
          Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(More.Handle,DWORD($FFFFFFFC),AccessibleID,Dispatch)),
            'History paging exposes no native accessibility object');
          Accessible:=Dispatch;
          Require((Integer(Accessible.accRole[0])=$2B) and string(Accessible.accName[0]).Contains('Показать ещё 3'),
            'History paging lacks an accessible button name or role');
          Accessible:=Unassigned; Dispatch:=nil;
          Host.Perform(CM_DIALOGKEY,VK_RETURN,0);
          Require((View.SectionCount=6) and View.SectionHeader(3).Focused and (Probe.PrimaryCalls=0),
            'Enter on history paging failed to append three, lost focus or triggered the primary action');
          More.SetFocus; More.Perform(WM_KEYDOWN,VK_SPACE,0); More.Perform(WM_KEYUP,VK_SPACE,0);
          Require((View.SectionCount=7) and not More.Visible and View.SectionHeader(6).Focused and (Probe.PrimaryCalls=0),
            'Space on final history paging left a hidden focus target or triggered the primary action');
          Writeln('PASS update history paging native Tab Enter Space MSAA and final-batch focus');
          Writeln('PASS update history native Tab Enter Space name state focus scroll reload theme=',Ord(Dark),' VCL_DPI=',PPI);
          Flush(Output);
        finally Accessible:=Unassigned; Dispatch:=nil; FreeAndNil(Host); end;
      end;
  finally
    FreeAndNil(Host); FreeAndNil(Probe); SetMHLTheme(SavedTheme); Application.ProcessMessages;
    Settings.CheckUpdate:=SavedAppCheck; Settings.CheckExternalLibUpdate:=SavedCatalogCheck;
    if not SavedMainVisible then frmMain.Hide;
  end;
end;

procedure TestUpdateReadyReleasePages;
const ReleasesPage = 'https://github.com/Dicur3x/MyHomeLib/releases';
  BatchTag = '9999.1.0';
var Dialog: TUpdateRestorePageForm; Page, Primary: TButton; List: TListView; Version: TLabel;
  CacheRoot, Cache, Job, Archive, Digest, ReadyFile, SavedLocal, AppHash, SQLiteHash: string;
  Manifest, Entry, Ready: TJSONObject; Files, Bundle: TJSONArray; Zip: TZipFile;
  HadLocal, Restored, SavedAppCheck, SavedCatalogCheck: Boolean; EmptyValue: Char;
  LengthBefore: DWORD; OriginalForms, Cases: Integer;

  function PayloadPath(const Name: string): string;
  begin
    Result:=TPath.Combine(TPath.Combine(Job,'payload'),StringReplace(Name,'/',PathDelim,[rfReplaceAll]));
  end;

  procedure Payload(const Name: string);
  var FileName, ParentFolder: string;
  begin
    FileName:=PayloadPath(Name); ParentFolder:=ExtractFileDir(FileName); ForceDirectories(ParentFolder);
    Require(DirectoryExists(ParentFolder),'Owned restore payload parent was not created: '+ParentFolder);
    Writeln('TRACE restored payload path=',FileName); Flush(Output);
    // Restore reads metadata and verifies the archive hash. Installation, PE
    // verification and process launch are deliberately outside this fixture.
    TFile.WriteAllText(FileName,'Restore-only fixture bytes: '+Name,TEncoding.UTF8);
    Entry:=TJSONObject.Create; Entry.AddPair('path',Name);
    Entry.AddPair('sha256',UpdateSHA256(FileName)); Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(FileName)));
    Files.AddElement(Entry);
  end;

  procedure RestorePage(const SourceURL, ExpectedURL, ExpectedCaption: string; IncludeURL: Boolean = True);
  var ReadyHash: string;
  begin
    Ready:=TJSONObject.Create;
    try
      Ready.AddPair('job',Job); Ready.AddPair('tag',BatchTag); Ready.AddPair('sha256',Digest);
      Ready.AddPair('component','batch'); Ready.AddPair('version','');
      Ready.AddPair('size',TJSONNumber.Create(TFile.GetSize(Archive)));
      Ready.AddPair('notes','Component-only restoration, no installation.');
      if IncludeURL then Ready.AddPair('url',SourceURL);
      TFile.WriteAllText(ReadyFile,Ready.ToJSON,TEncoding.UTF8);
    finally Ready.Free; end;
    ReadyHash:=THashSHA2.GetHashStringFromFile(ReadyFile);
    Writeln('TRACE restored update page case=',Cases+1,' expected=',ExpectedURL); Flush(Output);
    Dialog:=TUpdateRestorePageForm.Create(nil);
    try
      Require(Dialog.RestoreReady,'Component-only batch did not restore: '+SourceURL);
      Page:=Dialog.FindComponent('UpdateReleasePage') as TButton;
      Primary:=nil; List:=nil; Version:=nil;
      for var Control in Dialog do
      begin
        if (Control is TButton) and TButton(Control).Default then Primary:=TButton(Control);
        if Control is TListView then List:=TListView(Control);
        if (Control is TLabel) and (TLabel(Control).Caption='Обновления компонентов HomeLib Ru') then Version:=TLabel(Control);
      end;
      Require(Assigned(Page) and Assigned(Primary) and Assigned(List) and Assigned(Version),
        'Restored component batch lost its real page, ready action, list or batch title');
      Require((Page.Caption=ExpectedCaption) and (Primary.Caption='Установить и перезапустить') and
        Assigned(List.Selected) and (List.Selected.Index=0) and List.Enabled,
        'Restored batch has an ambiguous page caption, wrong selected row or non-ready action');
      List.Items[1].Selected:=True;
      Require(Assigned(List.Selected) and (List.Selected.Index=0) and (Primary.Caption='Установить и перезапустить'),
        'Ready table changed its selected component or installation action');
      // A real mouse click requires the native parent to be visible/focusable.
      Dialog.Show; Dialog.BringToFront; Application.ProcessMessages;
      var RowBounds:=List.Items[1].DisplayRect(drBounds);
      var MousePoint:=MakeLParam(RowBounds.Left+8,(RowBounds.Top+RowBounds.Bottom) div 2);
      PostMessage(List.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MousePoint);
      PostMessage(List.Handle,WM_LBUTTONUP,0,MousePoint);
      Application.ProcessMessages;
      Require(Assigned(List.Selected) and (List.Selected.Index=0),
        'Native mouse completion changed a ready component selection');
      // Blank-space clicks can clear selection without a Selected=True event.
      MousePoint:=MakeLParam(8,List.ClientHeight-8);
      PostMessage(List.Handle,WM_LBUTTONDOWN,MK_LBUTTON,MousePoint);
      PostMessage(List.Handle,WM_LBUTTONUP,0,MousePoint);
      Application.ProcessMessages;
      Require(Assigned(List.Selected) and (List.Selected.Index=0),
        'Blank native click cleared a ready component selection');
      List.Perform(WM_KEYDOWN,VK_DOWN,0);
      List.Perform(WM_CHAR,Ord('S'),0);
      List.Perform(WM_KEYUP,VK_DOWN,0);
      Require(Assigned(List.Selected) and (List.Selected.Index=0),
        'Keyboard navigation changed a ready component selection');
      if Cases=0 then
      begin
        var SavedTheme:=MHLThemeDark;
        try
          for var Dark in TArray<Boolean>.Create(False,True) do
          begin
            SetMHLTheme(Dark);
            for var PPI in TArray<Integer>.Create(96,144,192) do
            begin
              Dialog.ScaleForPPI(PPI); Dialog.ClientWidth:=MulDiv(760,PPI,96);
              Dialog.ClientHeight:=MulDiv(720,PPI,96);
              Require(Dialog.Font.PixelsPerInch=PPI,'Ready updater font did not adopt requested DPI');
              for var Zoom in TArray<Integer>.Create(90,100,130) do
              begin
                for var Component in Dialog do
                  if Component is TUpdateNotesView then TUpdateNotesView(Component).ZoomPercent:=Zoom;
                CheckUpdateComponentTable(Dialog,Format('restored-ready-ppi-%d-zoom-%d',[PPI,Zoom]));
              end;
              List.Items[1].Selected:=True;
              Require(Assigned(List.Selected) and (List.Selected.Index=0) and not Dialog.PendingInstall,
                'Theme/DPI change unlocked a ready download');
              if (ParamStr(1)='release23-ready-visual') and (PPI=96) then
              begin
                Dialog.Caption:='Готовое обновление — изолированная проверка';
                Primary.Enabled:=False; Page.Enabled:=False;
                for var Control in Dialog do
                  if (Control is TButton) and (TButton(Control).Caption='Позже') then
                  begin
                    TButton(Control).OnClick:=nil; TButton(Control).ModalResult:=mrCancel;
                  end;
                Dialog.Hide; Dialog.ModalResult:=mrNone; Dialog.ShowInTaskBar:=True; Dialog.ShowModal;
                Primary.Enabled:=True; Page.Enabled:=True;
              end;
            end;
          end;
        finally Dialog.Hide; SetMHLTheme(SavedTheme); end;
        Writeln('PASS ready updater native row colours and selection lock in both themes at 96 144 192 DPI');
      end;
      Page.Click;
      Require((Dialog.PageCalls=1) and (Dialog.OpenedURL=ExpectedURL),
        'Restored batch page click used the component version as a HomeLib release or accepted an unsafe URL: '+SourceURL);
      Require(not Dialog.PendingInstall and not FileExists(TPath.Combine(Job,'request.json')) and
        (THashSHA2.GetHashStringFromFile(ReadyFile)=ReadyHash),
        'Restored page action requested installation or changed ready state');
      Inc(Cases);
    finally FreeAndNil(Dialog); end;
  end;

begin
  RequireIsolatedRegression; OriginalForms:=Screen.FormCount; Cases:=0; Dialog:=nil;
  AppHash:=THashSHA2.GetHashStringFromFile(ParamStr(0));
  SQLiteHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll');
  SavedLocal:=GetEnvironmentVariable('LOCALAPPDATA'); SetLastError(ERROR_SUCCESS);
  LengthBefore:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
  HadLocal:=(LengthBefore<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND);
  CacheRoot:=TPath.Combine(Settings.AppPath,'rup-'+TGUID.NewGuid.ToString); ForceDirectories(CacheRoot);
  if not SetEnvironmentVariableW('LOCALAPPDATA',PChar(CacheRoot)) then RaiseLastOSError;
  SavedAppCheck:=Settings.CheckUpdate; SavedCatalogCheck:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  try
    Cache:=ProgramUpdateCache(Settings.AppPath); ForceDirectories(Cache);
    Job:=TPath.Combine(Cache,'HomeLibRu-update-'+TGUID.NewGuid.ToString); ForceDirectories(Job);
    Archive:=TPath.Combine(Job,'release.zip'); ReadyFile:=TPath.Combine(Cache,'ready.json');
    Manifest:=TJSONObject.Create;
    try
      Manifest.AddPair('format',TJSONNumber.Create(1)); Manifest.AddPair('release',BatchTag);
      Manifest.AddPair('platform',ProgramUpdatePlatform); Manifest.AddPair('component','batch');
      Bundle:=TJSONArray.Create; Manifest.AddPair('bundle',Bundle);
      for var ID in TArray<string>.Create('SQLite','AlReader') do
      begin
        Entry:=TJSONObject.Create; Entry.AddPair('component',ID); Entry.AddPair('version',BatchTag);
        Entry.AddPair('official',TJSONBool.Create(False)); Bundle.AddElement(Entry);
      end;
      Files:=TJSONArray.Create; Manifest.AddPair('files',Files);
      Payload('sqlite3.dll'); Payload('Readers/AlReader/AlReader2.exe');
      TFile.WriteAllText(TPath.Combine(Job,'manifest.json'),Manifest.ToJSON,TEncoding.UTF8);
    finally Manifest.Free; end;
    Zip:=TZipFile.Create;
    try
      Zip.Open(Archive,zmWrite); Zip.Add(TPath.Combine(Job,'manifest.json'),UPDATE_MANIFEST);
      Zip.Add(PayloadPath('sqlite3.dll'),'sqlite3.dll');
      Zip.Add(PayloadPath('Readers/AlReader/AlReader2.exe'),'Readers/AlReader/AlReader2.exe');
      Zip.Close;
    finally Zip.Free; end;
    Digest:=UpdateSHA256(Archive);
    Require(PreparedComponentsNewer(Job,Settings.AppPath),'Component-only batch fixture is not newer than the installed copies');
    for var Info in UPDATE_COMPONENTS do
    begin
      Require((UpdateReleasePageURL(Info.ID,BatchTag,'')=Info.URL) and
        (UpdateReleasePageURL(Info.ID,BatchTag,'javascript:invalid')=Info.URL),
        'Legacy or unsafe component page fallback is missing for '+Info.ID);
      RestorePage(Info.URL,Info.URL,'Сайт автора: '+Info.ID);
    end;
    RestorePage(ReleasesPage+'/tag/2.7.0_pre5.99',ReleasesPage+'/tag/2.7.0_pre5.99','Выпуски HomeLib Ru');
    RestorePage('',ReleasesPage,'Выпуски HomeLib Ru',False);
    for var UnsafeURL in TArray<string>.Create('javascript:alert(1)','file:///C:/invalid.html',
      'https://www.sqlite.org.evil.invalid/changes.html','https://www.sqlite.org@evil.invalid/changes.html',
      'https://example.invalid/update','https://github.com/Dicur3x/MyHomeLib/releases/tag/../../invalid',
      ReleasesPage+'/tag/2.7.0_pre5.99?redirect=invalid',ReleasesPage+'/tag/2.7.0_pre5.99'+#10,
      'https://www.sqlite.org/changes.html'+#13#10) do
      RestorePage(UnsafeURL,ReleasesPage,'Выпуски HomeLib Ru');
    Require((UpdateReleasePageURL('','2.7.0_pre5.99','')=ReleasesPage+'/tag/2.7.0_pre5.99') and
      (UpdateReleasePageURL('','../invalid','')=ReleasesPage),
      'Old application page fallback lost a valid release or accepted an unsafe tag');
    Require((UpdateSHA256(Archive)=Digest) and
      (THashSHA2.GetHashStringFromFile(ParamStr(0))=AppHash) and
      (THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll')=SQLiteHash),
      'Restoring a component page changed staged or installed bytes');
    Writeln('PASS restored component-only batch page uses saved canonical sources for all six components and safe legacy-invalid URL fallbacks without network or installation cases=',Cases);
    Flush(Output);
  finally
    try FreeAndNil(Dialog);
    finally
      EmptyValue:=#0;
      if not HadLocal then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',nil)
      else if SavedLocal='' then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',@EmptyValue)
      else Restored:=SetEnvironmentVariableW('LOCALAPPDATA',PChar(SavedLocal));
      Settings.CheckUpdate:=SavedAppCheck; Settings.CheckExternalLibUpdate:=SavedCatalogCheck;
      Require(Restored and (Screen.FormCount=OriginalForms),'Restored-page fixture leaked a form or cache environment');
    end;
  end;
end;

procedure TestUpdateSourceFailures;
var Dialog: TUpdateProposalForm; Server: TUpdateProposalServer;
  CheckButton, Primary: TButton; View: TListView; Status: TLabel; Notes: TUpdateNotesView;
  Deadline: UInt64; Current: TProgramRelease; CacheRoot, SavedLocal: string;
  HadLocal, Restored, SavedAppCheck, SavedCatalogCheck: Boolean; EmptyValue: Char; LengthBefore: DWORD;
  SourceHash: string; OriginalForms, Calls: Integer;

  procedure Controls;
  begin
    CheckButton:=nil; Primary:=nil; View:=nil; Status:=nil; Notes:=nil;
    for var Component in Dialog do
    begin
      if Component is TButton then
      begin
        if TButton(Component).Caption='Проверить всё' then CheckButton:=TButton(Component);
        if TButton(Component).Default then Primary:=TButton(Component);
      end;
      if Component is TListView then View:=TListView(Component);
      if (Component is TLabel) and (Component.Name='UpdateStatus') then Status:=TLabel(Component);
      if Component is TUpdateNotesView then Notes:=TUpdateNotesView(Component);
    end;
    Require(Assigned(CheckButton) and Assigned(Primary) and Assigned(View) and Assigned(Status) and Assigned(Notes),
      'Updater source fixture lacks actual form controls');
  end;

  procedure WaitCheck;
  begin
    Deadline:=GetTickCount64+10000;
    repeat
      Application.ProcessMessages; CheckSynchronize(0); TThread.Sleep(1);
      Require(GetTickCount64<Deadline,'Controlled source check did not leave its pending state');
    until CheckButton.Enabled;
  end;

  procedure SelectRow(Index: Integer);
  begin
    View.Items[Index].Selected:=True;
    View.OnSelectItem(View,View.Items[Index],True);
  end;

  procedure SafeStatus;
  begin
    Require(not string(Status.Caption).Contains('<html>') and not string(Status.Caption).Contains('secret') and
      not string(Status.Caption).Contains('C:\proxy') and (Length(Status.Caption)<1200),
      'Ordinary update UI exposed raw or unbounded transport details');
  end;

begin
  RequireIsolatedRegression; TestUpdateReadyReleasePages; OriginalForms:=Screen.FormCount;
  SavedAppCheck:=Settings.CheckUpdate; SavedCatalogCheck:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  SourceHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll');
  SavedLocal:=GetEnvironmentVariable('LOCALAPPDATA'); SetLastError(ERROR_SUCCESS);
  LengthBefore:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
  HadLocal:=(LengthBefore<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND);
  CacheRoot:=TPath.Combine(Settings.AppPath,'controlled-update-source-cache'); ForceDirectories(CacheRoot);
  if not SetEnvironmentVariableW('LOCALAPPDATA',PChar(CacheRoot)) then RaiseLastOSError;
  Server:=nil; Dialog:=nil;
  try
    Server:=TUpdateProposalServer.Create; Dialog:=TUpdateProposalForm.CreateForHead(Server.HeadURL); Controls;
    Dialog.FailureID:='all'; CheckButton.Click; WaitCheck;
    Require(Dialog.Visible and Primary.Enabled and string(Status.Caption).Contains('Не удалось проверить'),
      'Manual unavailable sources were silent or left Retry disabled');
    for var I in CheckedComponentIndices do
      Require(View.Items[I+1].SubItems[2]='Не удалось проверить','Unavailable source is falsely current');
    SafeStatus;
    Writeln('PASS update sources unavailable manual check names failures keeps Retry available and hides raw server details');

    Dialog.FailureID:='SumatraPDF'; CheckButton.Click; WaitCheck;
    Require((View.Items[1].SubItems[2]='Есть обновление') and
      (View.Items[2].SubItems[2]='Версия не подтверждена') and
      (View.Items[3].SubItems[2]='Не удалось проверить') and
      string(Status.Caption).Contains('SumatraPDF') and string(Status.Caption).Contains('AlReader'),
      'Partial source failure hid independent updates or misreported unverified AlReader');
    SafeStatus; SelectRow(3);
    Require((Primary.Caption='Повторить проверку') and string(Status.Caption).Contains('SumatraPDF'),
      'Selecting a failed source lost its explanation or its Retry action');
    View.PopupMenu.OnPopup(View.PopupMenu);
    Require(View.PopupMenu.Items[2].Enabled,'Failed source has no explicit diagnostic copy action');
    View.PopupMenu.Items[2].Click;
    Require(string(Clipboard.AsText).Contains('Fixture HTTP 503') and (Length(Clipboard.AsText)<4600),
      'Explicit Copy error omitted bounded diagnostics');
    Writeln('PASS update sources partial failure retains independent direct updates and selected error diagnostics without changing installed files');

    Calls:=Dialog.WorkerCalls; Dialog.FailureID:=''; Primary.Click; WaitCheck;
    Require((Dialog.WorkerCalls=Calls+1) and (View.Items[3].SubItems[2]='Есть обновление') and
      not Dialog.PendingInstall,'Retry downloaded stale packages instead of rechecking the selected source');
    SelectRow(3);
    Require(string(Status.Caption).Contains('SumatraPDF') and not string(Status.Caption).Contains('Не удалось проверить'),
      'Recovered source retained the preceding error');
    Require(string(Notes.PrimaryNotes.Text).Contains('Owned Sumatra changes.'),'Recovered source lost author changes');
    SelectRow(2);
    Require((Primary.Caption='Повторить проверку') and
      (string(Status.Caption).Contains('Установленная') or string(Status.Caption).Contains('установленная')),'AlReader notice does not explain the existing reader');
    Writeln('PASS update sources Retry performs a new production check clears recovered errors and retains AlReader verification');

    Dialog.Hide; Dialog.FailureID:='all';
    Require(Dialog.StartCheckCycle(True),'Automatic failure cycle did not start');
    Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
    Dialog.ApplicationChecked(Current,True,''); Dialog.CheckComponents(True); WaitCheck;
    Require(not Dialog.Visible and Primary.Enabled,'Automatic unavailable sources interrupted the user or disabled Retry');
    Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'sqlite3.dll')=SourceHash,
      'Metadata-only source checks changed an installed component');
    Writeln('PASS update sources automatic failures stay quiet and preserve installed component bytes');
    Flush(Output);
  finally
    Dialog.Free; Server.Free;
    EmptyValue:=#0;
    if not HadLocal then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',nil)
    else if SavedLocal='' then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',@EmptyValue)
    else Restored:=SetEnvironmentVariableW('LOCALAPPDATA',PChar(SavedLocal));
    Settings.CheckUpdate:=SavedAppCheck; Settings.CheckExternalLibUpdate:=SavedCatalogCheck;
    Require(Restored and (Screen.FormCount=OriginalForms),'Controlled source fixture leaked a form or cache environment');
  end;
end;


type
  TUpdateProposalVisualClose = class
    Dialog: TForm;
    procedure Close(Sender: TObject);
  end;

procedure TUpdateProposalVisualClose.Close(Sender: TObject);
begin Dialog.ModalResult:=mrCancel; end;

procedure TestUpdateProposalsVisual;
var Server: TUpdateProposalServer; Worker: TComponentCheckFixtureWorker;
  Dialog: TUpdateProposalForm; CloseProbe: TUpdateProposalVisualClose;
  Releases: TComponentReleases; Current: TProgramRelease; LongNotes: string;
  SavedTheme, SavedAppCheck, SavedCatalogCheck, HadLocal: Boolean;
  SavedLocal, CacheRoot: string; LengthBefore: DWORD; EmptyValue: Char;
  Restored: Boolean;
begin
  RequireIsolatedRegression;
  SavedTheme:=MHLThemeDark; SavedAppCheck:=Settings.CheckUpdate;
  SavedCatalogCheck:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  SavedLocal:=GetEnvironmentVariable('LOCALAPPDATA'); SetLastError(ERROR_SUCCESS);
  LengthBefore:=Winapi.Windows.GetEnvironmentVariableW('LOCALAPPDATA',nil,0);
  HadLocal:=(LengthBefore<>0) or (GetLastError<>ERROR_ENVVAR_NOT_FOUND);
  CacheRoot:=TPath.Combine(Settings.AppPath,'visual-update-proposals-cache'); ForceDirectories(CacheRoot);
  if not SetEnvironmentVariableW('LOCALAPPDATA',PChar(CacheRoot)) then RaiseLastOSError;
  Server:=nil; Worker:=nil; Dialog:=nil; CloseProbe:=nil;
  try
    Server:=TUpdateProposalServer.Create;
    Worker:=TComponentCheckFixtureWorker.Create(0,Server.HeadURL,'SumatraPDF');
    Worker.Start; Worker.WaitFor;
    Require(Worker.Successful,'Visual metadata fixture failed');
    Releases:=Worker.Releases; FreeAndNil(Worker);
    LongNotes:='3.99.0 — 16.10.2026'+sLineBreak;
    for var I:=1 to 30 do
      LongNotes:=LongNotes+'- Проверка длинной истории: строка '+IntToStr(I)+'. Unicode ё 中文.'+sLineBreak;
    LongNotes:=LongNotes+'3.98.0 — 15.10.2026'+sLineBreak+
      'Этот выпуск можно раскрыть клавишей Enter или пробелом.'+sLineBreak+
      '3.97.0 — 14.10.2026'+sLineBreak+'Предыдущие изменения автора.';
    Releases[0].History:=LongNotes; Releases[0].Changelog:=LongNotes; Releases[0].Notes:='';
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark); Dialog:=TUpdateProposalForm.CreateForHead(Server.HeadURL);
      CloseProbe:=TUpdateProposalVisualClose.Create; CloseProbe.Dialog:=Dialog;
      try
        Dialog.Caption:='История обновлений — изолированный ручной стенд';
        Dialog.ShowInTaskBar:=True;
        Require(Dialog.StartCheckCycle(True),'Visual fixture cycle did not start');
        Current:=Default(TProgramRelease); Current.Tag:=PROGRAM_RELEASE_VERSION;
        Dialog.ApplicationChecked(Current,True,''); Dialog.ComponentsReceived(Releases,True,'');
        for var Component in Dialog do
          if Component is TButton then
          begin
            // No control in this fixture may download a package or open a site.
            if TButton(Component).Default then TButton(Component).Enabled:=False;
            if (TButton(Component).Caption='Открыть GitHub') or
              (TButton(Component).Caption='Сайт автора') then TButton(Component).Enabled:=False;
            if TButton(Component).Caption='Позже' then
            begin TButton(Component).Cancel:=True; TButton(Component).OnClick:=CloseProbe.Close; end;
          end;
        Dialog.Hide; Dialog.ScaleForPPI(192);
        Dialog.Constraints.MinWidth:=0; Dialog.Constraints.MinHeight:=0;
        Dialog.ClientWidth:=Min(1800,Screen.WorkAreaWidth-80);
        Dialog.ClientHeight:=Min(1000,Screen.WorkAreaHeight-80);
        Dialog.Position:=poScreenCenter;
        Writeln('VISUAL update proposals theme=',Ord(Dark),' VCL_PPI=',Dialog.Font.PixelsPerInch,
          ' Tab Enter Space; Esc or Позже closes this fixture; next theme follows'); Flush(Output);
        Dialog.ShowModal;
      finally FreeAndNil(Dialog); FreeAndNil(CloseProbe); end;
    end;
    Writeln('PASS update proposals visual fixtures closed explicitly in both themes without downloads'); Flush(Output);
  finally
    Worker.Free; Dialog.Free; CloseProbe.Free; Server.Free;
    EmptyValue:=#0;
    if not HadLocal then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',nil)
    else if SavedLocal='' then Restored:=SetEnvironmentVariableW('LOCALAPPDATA',@EmptyValue)
    else Restored:=SetEnvironmentVariableW('LOCALAPPDATA',PChar(SavedLocal));
    SetMHLTheme(SavedTheme);
    Settings.CheckUpdate:=SavedAppCheck; Settings.CheckExternalLibUpdate:=SavedCatalogCheck;
    Require(Restored,'Visual update fixture did not restore its cache environment');
  end;
end;
