// Include after Require / TFCTModalProbe; existing DPR uses cover VCL, Indy and HTTP.
{$I ..\..\..\Program\Tests\ComponentCheckFixture.inc}

function UpdateProposalAccessibleObjectFromWindow(Window: HWND; ObjectID: DWORD;
  const IID: TGUID; out Accessible: IDispatch): HRESULT; stdcall;
  external 'oleacc.dll' name 'AccessibleObjectFromWindow';

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

  TUpdateKeyboardProbe = class
  public
    PrimaryCalls: Integer;
    procedure PrimaryClicked(Sender: TObject);
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

procedure TUpdateKeyboardProbe.PrimaryClicked(Sender: TObject);
begin Inc(PrimaryCalls); end;

procedure TestUpdateKeyboardAccessibility;
var Host: TForm; View: TUpdateNotesView; Primary: TButton; Probe: TUpdateKeyboardProbe;
  SavedTheme, SavedAppCheck, SavedCatalogCheck: Boolean; Header: TButton; Location: TPoint; Notes: string;
  Accessible: OleVariant; Dispatch: IDispatch; AccessibleID: TGUID;
  FirstActivation: Boolean; ForegroundDeadline: UInt64;
begin
  RequireIsolatedRegression; SavedTheme:=MHLThemeDark;
  SavedAppCheck:=Settings.CheckUpdate; SavedCatalogCheck:=Settings.CheckExternalLibUpdate;
  Settings.CheckUpdate:=False; Settings.CheckExternalLibUpdate:=False;
  Probe:=TUpdateKeyboardProbe.Create; Host:=nil; FirstActivation:=True;
  Accessible:=Unassigned; Dispatch:=nil;
  AccessibleID:=StringToGUID('{618736E0-3C3D-11CF-810C-00AA00389B71}');
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
      for var PPI in TArray<Integer>.Create(96,144,192) do
      begin
        SetMHLTheme(Dark); Host:=TForm.CreateNew(nil);
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
            '2.7.0_pre5.97'+sLineBreak+'Oldest owned release.';
          View.Load(Notes); Host.Show; Application.ProcessMessages; Host.ScaleForPPI(PPI);
          Require((Host.Font.PixelsPerInch=PPI) and (View.SectionHeader(0).Font.PixelsPerInch=PPI),
            'Release headers did not adopt simulated VCL DPI');
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
          View.ZoomPercent:=200;
          Require(View.SectionHeader(1).Focused and
            (View.SectionHeader(1).Height>MulDiv(30,PPI,96)),
            'Text zoom lost focus or clipped its release button');
          Writeln('TRACE update theme before theme=',Ord(MHLThemeDark),' expanded=',Ord(View.IsExpanded(1)),
            ' focused=',Ord(View.SectionHeader(1).Focused),' native_focus=',Winapi.Windows.GetFocus,
            ' header=',View.SectionHeader(1).Handle,' foreground=',GetForegroundWindow,' host=',Host.Handle); Flush(Output);
          SetMHLTheme(not Dark); Application.ProcessMessages;
          Writeln('TRACE update theme after theme=',Ord(MHLThemeDark),' expanded=',Ord(View.IsExpanded(1)),
            ' focused=',Ord(View.SectionHeader(1).Focused),' native_focus=',Winapi.Windows.GetFocus,
            ' header=',View.SectionHeader(1).Handle,' foreground=',GetForegroundWindow,' host=',Host.Handle); Flush(Output);
          Require(View.IsExpanded(1),'Switching theme changed the expanded release state');
          Require(View.SectionHeader(1).Focused and (Winapi.Windows.GetFocus=View.SectionHeader(1).Handle),
            'Switching theme lost the actual Windows focus of the release header');
          Require(Succeeded(UpdateProposalAccessibleObjectFromWindow(View.SectionHeader(1).Handle,
            DWORD($FFFFFFFC),AccessibleID,Dispatch)),'The themed release header lost its accessibility object');
          Accessible:=Dispatch;
          Require((Integer(Accessible.accState[0]) and 4)<>0,
            'The themed release header lost its focused accessibility state');
          Accessible:=Unassigned; Dispatch:=nil;
          SetMHLTheme(Dark); Host.ScaleForPPI(96); Host.ScaleForPPI(PPI);
          Require(View.SectionHeader(1).Focused and View.IsExpanded(1),
            'Changing VCL scale lost the focused/expanded release');
          Writeln('PASS update history native Tab Enter Space name state focus scroll reload theme=',Ord(Dark),' VCL_DPI=',PPI);
          Flush(Output);
        finally Accessible:=Unassigned; Dispatch:=nil; FreeAndNil(Host); end;
      end;
  finally
    FreeAndNil(Host); FreeAndNil(Probe); SetMHLTheme(SavedTheme);
    Settings.CheckUpdate:=SavedAppCheck; Settings.CheckExternalLibUpdate:=SavedCatalogCheck;
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
  RequireIsolatedRegression; OriginalForms:=Screen.FormCount;
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
