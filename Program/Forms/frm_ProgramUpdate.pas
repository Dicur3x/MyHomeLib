unit frm_ProgramUpdate;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Controls,
  Winapi.Windows, Winapi.Messages, unit_ProgramUpdates, unit_ComponentUpdates, unit_UpdateNotes, unit_MHLTheme;

type
{$IFDEF MHL_RELEASE_PERFORMANCE}
  TProgramUpdateProfile = record
    Selections, SelectionMS, NotesMS, RowsMS, LayoutMS, ChangesMS, ReleaseMS: UInt64;
  end;
{$ENDIF}
  TfrmProgramUpdate = class(TForm)
  private
    FStatus, FVersion, FBytes: TLabel;
    FNotes: TUpdateNotesView;
    FProgress: TProgressBar;
    FPrimary, FLater, FPage: TButton;
    FZoomOut, FZoomReset, FZoomIn: TButton;
    FUIUpdateCount, FNormalWidth, FNormalHeight, FSelectionDepth: Integer;
    FUIRedraw, FPresentPending: Boolean;
    FThread: TProgramDownloadThread;
    FComponentThread: TComponentUpdateThread;
    FMessageWindow: HWND;
    procedure EnsureMessageWindow;
    procedure MessageWindowProc(var Message: TMessage);
  private
    FComponents: TComponentReleases;
    FComponentWaiting: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of Boolean;
    procedure ComponentProgress(var Message: TMessage);
  private
    FComponentsView: TListView;
    FTabs: TTabControl;
    FHistorySelector: TComboBox;
    FSelectedRow: Integer;
    FRefreshingComponents: Boolean;
    FComponentCheck: TButton;
    FNotifyOptional: TCheckBox;
    FChangingNotification: Boolean;
    FRequestedComponent, FRequestReason: string;
    FRequestedComponents: TArray<string>;
    FRequestedCheckPending: Boolean;
    FReaderOnly: Boolean;
    FOperationComponent: string;
    FCompactForm: TForm;
    FCompactStatus: TMemo;
    FCompactHeader, FCompactBytes: TLabel;
    FCompactProgress: TProgressBar;
    FCompactPrimary, FCompactLater: TButton;
    FRowIDs: TArray<Integer>;
    function RequestedReleases: TArray<TProgramRelease>;
    procedure ShowRequestedComponents;
    procedure CreateCompactPrompt;
    procedure SyncCompactPrompt;
    procedure CompactLater(Sender: TObject);
    procedure CompactClose(Sender: TObject; var Action: TCloseAction);
    function ComponentAllowed(Index: Integer): Boolean;
    function RowVisible(Value: Integer): Boolean;
    function ViewIndex(Value: Integer): Integer;
  private
    FComponentAutomatic: Boolean;
    FComponentExplicit: Boolean;
    FComponentError, FComponentErrorDetails: string;
    FComponentNotified: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of string;
    FApplicationRelease: TProgramRelease;
    FInstalledVersions: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of string;
    FRepairComponents: string;
    FApplicationStatus, FApplicationHistory: string;
    FApplicationVerified, FApplicationFailed: Boolean;
    FCheckingCycle, FAppPending, FComponentsPending, FCycleAutomatic: Boolean;
    FQueue: TArray<TProgramRelease>;
    FQueueJobs: TArray<string>;
    FQueueIndex: Integer;
    FQueueBytes, FQueueTotal: Int64;
    FRelease: TProgramRelease;
    FJob, FCache: string;
    FReady, FPendingInstall, FNeedsCheck, FRecovery: Boolean;
    FRestart, FCheck: TNotifyEvent;
    procedure NotificationChanged(Sender: TObject);
    function MayNotifyComponent(Index: Integer): Boolean;
    procedure AppThemeChanged(var Message: TMessage); message WM_MHL_APP_THEME;
    procedure CMFontChanged(var Message: TMessage); message CM_FONTCHANGED;
    procedure PrimaryClick(Sender: TObject);
    procedure LaterClick(Sender: TObject);
    procedure PageClick(Sender: TObject);
    procedure UpdateReleasePage;
    procedure DownloadCompleted(var Message: TMessage); message WM_PROGRAM_UPDATE_DOWNLOADED;
    procedure DownloadProgress(var Message: TMessage); message WM_PROGRAM_UPDATE_PROGRESS;
    procedure SaveReady;
    procedure DiscardJob;
    procedure DisplayNotes(const Notes: string);
    procedure ComponentSelected(Sender: TObject);
    procedure ComponentRowSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure ViewTabChanged(Sender: TObject);
    procedure OpenChanges(Sender: TObject);
    procedure HistoryComponentSelected(Sender: TObject);
    procedure SelectRow(Value: Integer);
    procedure ComponentKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure CopyComponents(Sender: TObject);
    procedure ComponentMenuPopup(Sender: TObject);
    procedure ComponentCheckClick(Sender: TObject);
    procedure ComponentsChecked(var Message: TMessage); message WM_COMPONENT_UPDATE_CHECKED;
    procedure UpdateComponentList;
    function ReleaseTitle: string;
    procedure BeginUIUpdate;
    procedure EndUIUpdate;
    procedure Present;
    procedure LayoutWindow;
    procedure LayoutShown(Sender: TObject);
    procedure ZoomClick(Sender: TObject);
    procedure ZoomChanged(Sender: TObject);
    procedure LoadViewPreferences;
    procedure SaveViewPreferences;
    function HasApplicationDownload: Boolean;
    function AvailableUpdates: TArray<TProgramRelease>;
    function AvailableSummary: string;
    function ComponentCheckSummary: string;
    procedure UpdateSummary;
    procedure FinishCheckCycle;
    procedure RefreshInstalledComponents;
    function InstalledVersion(const ID: string): string;
    procedure StartQueuedDownload;
    procedure ClearQueueJobs;
  protected
    function InstallationHelperSource: string;
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    function CreateComponentWorker(Window: HWND): TComponentUpdateThread; virtual;
    function CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
      const Job: string): TProgramDownloadThread; virtual;
    procedure OpenReleasePage(const URL: string); virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetRelease(const ReleaseInfo: TProgramRelease);
    procedure BeginCheck;
    procedure SetCurrent(const ReleaseInfo: TProgramRelease);
    procedure CheckFailed(const Error: string);
    procedure RememberHistory(const ReleaseInfo: TProgramRelease);
    procedure CheckComponents(Automatic: Boolean);
    procedure UseReaderComponents;
    procedure RequestComponent(const ID, Reason: string; Compact: Boolean = False);
    procedure RequestComponents(const IDs: TArray<string>; const Reason: string; Compact: Boolean = True);
    function InstallComponentForOperation(const ID, Reason: string): Boolean;
    procedure UseFullWindow;
    function StartCheckCycle(Automatic: Boolean): Boolean;
    procedure ApplicationChecked(const ReleaseInfo: TProgramRelease; Successful: Boolean; const Error: string);
    procedure ComponentsReceived(const Releases: TComponentReleases; Successful: Boolean; const Error: string);
    function RestoreReady: Boolean;
    function LaunchInstallation: Boolean;
    function WillInstallComponent(const ID: string): Boolean;
    procedure CancelInstallation;
    property PendingInstall: Boolean read FPendingInstall;
    property OnCheck: TNotifyEvent read FCheck write FCheck;
    property OnRestart: TNotifyEvent read FRestart write FRestart;
  end;

{$IFDEF MHL_RELEASE_PERFORMANCE}
var ProgramUpdateProfile: TProgramUpdateProfile;
{$ENDIF}

implementation

uses System.SysUtils, System.StrUtils, System.IOUtils, System.JSON, System.RegularExpressions, System.Math,
  System.Types, Winapi.ShellAPI,
  Vcl.Graphics, Vcl.Menus, Vcl.Clipbrd, dm_user, unit_Settings, unit_Globals,
  unit_ProgramUpdateInstaller, unit_MHLHttpClient, unit_UpdateTextCache, unit_BookSaveContinuation,
  unit_MHLExternalTools;

function ComponentDownloadSize(Bytes: Int64): string;
begin
  if Bytes>=1048576 then Result:=Format('%.1f МБ',[Bytes/1048576])
  else if Bytes>=1024 then Result:=Format('%.1f КБ',[Bytes/1024])
  else Result:=IntToStr(Bytes)+' Б';
end;

type
  TOperationComponentPrompt = class(TForm)
  private
    FStandaloneReader: Boolean;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor CreatePrompt(AOwner: TComponent; StandaloneReader: Boolean);
  end;

  TUpdateComponentsView = class(TListView)
  protected
    procedure WndProc(var Message: TMessage); override;
  end;

constructor TOperationComponentPrompt.CreatePrompt(AOwner: TComponent; StandaloneReader: Boolean);
begin
  FStandaloneReader:=StandaloneReader;
  inherited CreateNew(AOwner);
  if FStandaloneReader then
  begin
    PopupMode:=pmNone;
  end;
end;

procedure TOperationComponentPrompt.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Direct book opening keeps the Reader launcher hidden. Its required-module
  // prompt must remain an independent, discoverable taskbar window.
  if FStandaloneReader then
  begin
    Params.WndParent:=0;
    Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
  end;
end;

procedure TUpdateComponentsView.WndProc(var Message: TMessage);
var Locked, BlockInput: Boolean;
begin
  Locked:=(Owner is TfrmProgramUpdate) and
    (Assigned(TfrmProgramUpdate(Owner).FThread) or TfrmProgramUpdate(Owner).FReady);
  // Keep theme painting, scrolling and Copy available while the chosen job is
  // fixed. Do not start native mouse tracking: its final deselection can occur
  // after both an OnSelectItem callback and a posted restoration message.
  BlockInput:=False;
  if Locked then
    case Message.Msg of
      WM_LBUTTONDOWN,WM_LBUTTONDBLCLK,WM_RBUTTONDOWN,WM_RBUTTONDBLCLK,WM_CHAR:
        BlockInput:=True;
      WM_KEYDOWN: BlockInput:=Message.WParam in
        [VK_LEFT,VK_RIGHT,VK_UP,VK_DOWN,VK_HOME,VK_END,VK_PRIOR,VK_NEXT,VK_SPACE];
    end;
  if BlockInput then
  begin
    if CanFocus then SetFocus;
    Message.Result:=0;
    Exit;
  end;
  inherited;
end;

constructor TfrmProgramUpdate.Create(AOwner: TComponent);
var HistoryFile: string; Menu: TPopupMenu; Entry: TMenuItem;
begin
  inherited CreateNew(AOwner);
  Caption := 'Обновление HomeLibre'; BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Position := poMainFormCenter; ClientWidth := 960; ClientHeight := 760;
  Constraints.MinWidth := 760; Constraints.MinHeight := 560;
  DoubleBuffered := True;
  OnShow:=LayoutShown;
  Font.Assign(Screen.MessageFont);
  FVersion := TLabel.Create(Self); FVersion.Parent := Self;
  FVersion.AutoSize:=False; FVersion.EllipsisPosition:=epEndEllipsis; FVersion.ShowHint:=True;
  FVersion.SetBounds(20, 16, 700, 20); FVersion.Font.Style := [fsBold];
  FVersion.Caption := 'Текущая версия: ' + ReleaseDisplayVersion(PROGRAM_RELEASE_VERSION);
  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.Name := 'UpdateStatus';
  FTabs:=TTabControl.Create(Self); FTabs.Parent:=Self; FTabs.Name:='UpdateTabs';
  FTabs.Tabs.Add('Обновления'); FTabs.Tabs.Add('Список изменений'); FTabs.TabIndex:=0;
  FTabs.OnChange:=ViewTabChanged;
  FHistorySelector:=TComboBox.Create(Self); FHistorySelector.Parent:=Self;
  FHistorySelector.Name:='UpdateHistoryComponent'; FHistorySelector.Style:=csDropDownList;
  FHistorySelector.Items.Add('HomeLibre');
  for var ComponentIndex:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
    FHistorySelector.Items.Add(ComponentTitle(ComponentIndex));
  FHistorySelector.ItemIndex:=0; FHistorySelector.Visible:=False;
  FHistorySelector.OnChange:=HistoryComponentSelected;
  FComponentsView:=TUpdateComponentsView.Create(Self); FComponentsView.Parent:=Self;
  FComponentsView.Name:='UpdateComponents'; FComponentsView.ViewStyle:=vsReport;
  FComponentsView.ReadOnly:=True; FComponentsView.RowSelect:=True;
  FComponentsView.HideSelection:=False; FComponentsView.MultiSelect:=False;
  FComponentsView.DoubleBuffered:=True;
  FComponentsView.Columns.Add.Caption:='Компонент';
  FComponentsView.Columns.Add.Caption:='Установлено';
  FComponentsView.Columns.Add.Caption:='Доступно';
  FComponentsView.Columns.Add.Caption:='Состояние';
  FComponentsView.OnSelectItem:=ComponentRowSelected;
  FComponentsView.OnKeyDown:=ComponentKeyDown;
  FComponentsView.OnDblClick:=OpenChanges;
  Menu:=TPopupMenu.Create(Self); FComponentsView.PopupMenu:=Menu; Menu.OnPopup:=ComponentMenuPopup;
  Entry:=TMenuItem.Create(Menu); Entry.Caption:='Копировать строку'; Entry.OnClick:=CopyComponents; Menu.Items.Add(Entry);
  Entry:=TMenuItem.Create(Menu); Entry.Caption:='Копировать список'; Entry.Tag:=1; Entry.OnClick:=CopyComponents; Menu.Items.Add(Entry);
  Entry:=TMenuItem.Create(Menu); Entry.Caption:='Копировать сведения об ошибке'; Entry.Tag:=2; Entry.OnClick:=CopyComponents; Menu.Items.Add(Entry);
  HistoryFile := Settings.SystemFileName[sfComponentHistory];
  try
    if FileExists(HistoryFile) then
      ParseComponentFeed(TFile.ReadAllText(HistoryFile, TEncoding.UTF8), PROGRAM_RELEASE_VERSION, '[]', FComponents, False);
  except end;
  FComponentCheck := TButton.Create(Self); FComponentCheck.Parent := Self; FComponentCheck.Name:='UpdateCheckComponents';
  FComponentCheck.SetBounds(500, 47, 220, 27); FComponentCheck.Caption := 'Проверить всё';
  FComponentCheck.OnClick := ComponentCheckClick;
  FNotifyOptional:=TCheckBox.Create(Self); FNotifyOptional.Parent:=Self;
  FNotifyOptional.Name:='NotifyOptionalComponent';
  FNotifyOptional.Caption:='Сообщать об обновлениях этого компонента'; FNotifyOptional.OnClick:=NotificationChanged;
  RefreshInstalledComponents; UpdateComponentList; SelectRow(0);
  FStatus.SetBounds(20, 88, 700, 60); FStatus.AutoSize := False; FStatus.WordWrap := True;
  FNotes := TUpdateNotesView.Create(Self); FNotes.Parent := Self;
  FNotes.SetBounds(20, 155, 700, 238);
  FBytes := TLabel.Create(Self); FBytes.Parent := Self;
  FBytes.Name:='UpdateBytes';
  FBytes.Caption:=''; FBytes.AutoSize:=False; FBytes.ShowHint:=True;
  FBytes.SetBounds(20, 430, 700, 18);
  FProgress := TProgressBar.Create(Self); FProgress.Parent := Self;
  FProgress.SetBounds(20, 404, 700, 18); FProgress.Max := 100;
  FPrimary := TButton.Create(Self); FPrimary.Parent := Self; FPrimary.Name:='UpdatePrimary';
  FPrimary.SetBounds(20, 473, 420, 30); FPrimary.OnClick := PrimaryClick; FPrimary.Default := True;
  FPage := TButton.Create(Self); FPage.Parent := Self; FPage.Name := 'UpdateReleasePage';
  FPage.SetBounds(460, 473, 125, 30); FPage.Caption := 'Открыть GitHub'; FPage.OnClick := PageClick;
  FLater := TButton.Create(Self); FLater.Parent := Self;
  FLater.SetBounds(605, 473, 115, 30); FLater.Caption := 'Позже'; FLater.OnClick := LaterClick;
  FCache := ProgramUpdateCache(Settings.AppPath);
  LoadComponentHistory(FCache, FComponents);
  UpdateComponentList;
  FZoomOut := TButton.Create(Self); FZoomOut.Parent := Self;
  FZoomOut.Caption := 'A−'; FZoomOut.Tag := -10; FZoomOut.OnClick := ZoomClick;
  FZoomOut.Hint := 'Уменьшить текст (Ctrl + колёсико)'; FZoomOut.ShowHint := True;
  FZoomReset := TButton.Create(Self); FZoomReset.Parent := Self;
  FZoomReset.Caption := '100%'; FZoomReset.OnClick := ZoomClick;
  FZoomReset.Hint := 'Обычный размер текста'; FZoomReset.ShowHint := True;
  FZoomIn := TButton.Create(Self); FZoomIn.Parent := Self;
  FZoomIn.Caption := 'A+'; FZoomIn.Tag := 10; FZoomIn.OnClick := ZoomClick;
  FZoomIn.Hint := 'Увеличить текст (Ctrl + колёсико)'; FZoomIn.ShowHint := True;
  FNotes.OnZoomChanged := ZoomChanged;
  FPrimary.Caption := 'Проверить обновления';
  FNeedsCheck := True;
  FStatus.Caption := 'История последних выпусков';
  FApplicationStatus := FStatus.Caption;
  try
    HistoryFile := ReadUpdateHistory(IncludeTrailingPathDelimiter(FCache) + 'notes.txt');
    if HistoryFile.Trim <> '' then
      DisplayNotes(Copy(HistoryFile, 1, 324000))
    else if FileExists(Settings.SystemFileName[sfProgramChanges]) then
      DisplayNotes(Copy(TFile.ReadAllText(Settings.SystemFileName[sfProgramChanges], TEncoding.UTF8), 1, 324000))
    else DisplayNotes('');
  except end;
  LoadViewPreferences;
  ScaleForPPI(Screen.PixelsPerInch);
  ApplyMHLControlTheme(Self); FNotes.ApplyTheme;
  FComponentsView.StyleElements:=FComponentsView.StyleElements-[seFont,seClient];
  if MHLThemeDark then FComponentsView.Color:=RGB(30,31,34) else FComponentsView.Color:=clWindow;
  LayoutWindow;
end;

destructor TfrmProgramUpdate.Destroy;
var Message: TMsg;
begin
  Inc(FUIUpdateCount); // Child destruction must not run layout on released controls.
  if Assigned(FComponentsView) then FComponentsView.OnSelectItem:=nil;
  if Assigned(FTabs) then FTabs.OnChange:=nil;
  if Assigned(FHistorySelector) then FHistorySelector.OnChange:=nil;
  SaveViewPreferences;
  if Assigned(FComponentThread) then
  // TThread.Destroy joins and also resumes a canceled Create(True) thread
  // after a pre-Start UI failure; an explicit WaitFor would deadlock there.
  begin FComponentThread.Terminate; FreeAndNil(FComponentThread); end;
  if Assigned(FThread) then
  begin FThread.Terminate; FreeAndNil(FThread); end;
  // Producers finish before their stable delivery window or UI state disappears.
  if FMessageWindow <> 0 then
  begin
    while PeekMessage(Message, FMessageWindow, WM_PROGRAM_UPDATE_DOWNLOADED,
      WM_COMPONENT_UPDATE_PROGRESS, PM_REMOVE) do ;
    DeallocateHWnd(FMessageWindow); FMessageWindow := 0;
  end;
  // Keep a verified ready update when installation is postponed or the app exits.
  if not FReady then DiscardJob;
  ClearQueueJobs;
  inherited;
end;

procedure TfrmProgramUpdate.AppThemeChanged(var Message: TMessage);
begin
  if csDestroying in ComponentState then Exit;
  if Assigned(FCompactForm) then ApplyMHLControlTheme(FCompactForm);
  if Assigned(FNotes) then FNotes.ApplyTheme;
  if Assigned(FComponentsView) then
  begin
    FComponentsView.StyleElements:=FComponentsView.StyleElements-[seFont,seClient];
    FComponentsView.Font.Color:=MHLThemeText;
    if MHLThemeDark then FComponentsView.Color:=RGB(30,31,34) else FComponentsView.Color:=clWindow;
  end;
end;

procedure TfrmProgramUpdate.BeginUIUpdate;
begin
  if FUIUpdateCount = 0 then
  begin
    DisableAlign;
    FUIRedraw := HandleAllocated and IsWindowVisible(Handle);
    if FUIRedraw then SendMessage(Handle, WM_SETREDRAW, 0, 0);
  end;
  Inc(FUIUpdateCount);
end;

procedure TfrmProgramUpdate.EndUIUpdate;
begin
  Dec(FUIUpdateCount);
  if FUIUpdateCount <> 0 then Exit;
  EnableAlign; LayoutWindow;
  if FUIRedraw then
  begin
    SendMessage(Handle, WM_SETREDRAW, 1, 0);
    RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_ALLCHILDREN);
  end;
  FUIRedraw := False;
  if FPresentPending then begin FPresentPending := False; Present; end;
end;

procedure TfrmProgramUpdate.Present;
begin
  // Row selection already belongs to this window. Repeated activation can
  // wait on foreground restrictions and disrupt a newly focused child.
  if FSelectionDepth>0 then Exit;
  if FUIUpdateCount > 0 then begin FPresentPending := True; Exit; end;
  if Assigned(FCompactForm) then
  begin
    SyncCompactPrompt;
    if not FCompactForm.Visible then FCompactForm.Show;
    FCompactForm.BringToFront; Exit;
  end;
  if not Visible then Show;
  BringToFront;
end;

procedure TfrmProgramUpdate.Resize;
begin
  inherited;
  if Assigned(FZoomIn) and (FUIUpdateCount = 0) then LayoutWindow;
end;

procedure TfrmProgramUpdate.LayoutShown(Sender: TObject);
begin LayoutWindow; end;

procedure TfrmProgramUpdate.CMFontChanged(var Message: TMessage);
begin
  inherited;
  if Assigned(FZoomIn) and (FUIUpdateCount=0) then LayoutWindow;
end;

procedure TfrmProgramUpdate.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  if Assigned(FZoomIn) and (FUIUpdateCount=0) then LayoutWindow;
end;

procedure TfrmProgramUpdate.LayoutWindow;
var Margin, Gap, Width, ButtonTop, NotesTop, NotesBottom, StatusHeight, TableHeight: Integer;
  TextHeight, ButtonHeight, TopHeight, TabsTop, TableTop, PageWidth, LaterWidth, FooterHeight,
  BytesHeight, TransferHeight, OptionalHeight: Integer;
  Bounds: TRect;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted: UInt64;{$ENDIF}
  function S(Value: Integer): Integer;
  begin Result := MulDiv(Value, CurrentPPI, 96); end;
begin
  if not Assigned(FZoomIn) then Exit;
  if Assigned(FCompactForm) then begin SyncCompactPrompt; Exit; end;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
  DisableAlign;
  try
    Margin := S(12); Gap := S(8); Width := ClientWidth - 2 * Margin;
    Canvas.Font.Assign(Font); TextHeight:=Canvas.TextHeight('Mg');
    ButtonHeight:=Max(S(30),TextHeight+S(12)); TopHeight:=Max(S(26),TextHeight+S(8));
    TabsTop:=S(8)+TopHeight+Gap; TableTop:=TabsTop+ButtonHeight+Gap;
    OptionalHeight:=0;
    if Assigned(FNotifyOptional) then
    begin
      FNotifyOptional.Visible:=(FSelectedRow>0) and IsOptionalComponent(UPDATE_COMPONENTS[FSelectedRow-1].ID);
      if FNotifyOptional.Visible then
      begin
        OptionalHeight:=Max(S(24),TextHeight+S(4))+Gap;
        FChangingNotification:=True;
        try FNotifyOptional.Checked:=ComponentNotificationEnabled(UPDATE_COMPONENTS[FSelectedRow-1].ID,Settings.OptionalComponentUpdates);
        finally FChangingNotification:=False; end;
      end;
      FNotifyOptional.Enabled:=not Assigned(FThread) and not FReady;
    end;
    FVersion.Hint:=FVersion.Caption;
    FVersion.SetBounds(Margin,S(10),Max(S(80),Width-S(160)),TopHeight);
    FZoomOut.SetBounds(ClientWidth-Margin-S(150),S(8),S(40),TopHeight);
    FZoomReset.SetBounds(ClientWidth-Margin-S(105),S(8),S(60),TopHeight);
    FZoomIn.SetBounds(ClientWidth-Margin-S(40),S(8),S(40),TopHeight);
    FComponentCheck.SetBounds(ClientWidth-Margin-S(220),TabsTop,S(220),ButtonHeight);
    FTabs.SetBounds(Margin,TabsTop,Width-S(220)-Gap,ButtonHeight);
    FComponentsView.Visible:=FTabs.TabIndex=0;
    FHistorySelector.Visible:=FTabs.TabIndex=1;
    FHistorySelector.SetBounds(Margin,TableTop,Width,ButtonHeight);
    FHistorySelector.Enabled:=not (Assigned(FThread) or FReady);
    Canvas.Font.Assign(Font); Bounds := Rect(0, 0, Width, 0);
    DrawText(Canvas.Handle, PChar(FStatus.Caption), Length(FStatus.Caption), Bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    StatusHeight := Max(TextHeight+S(4),Min(Bounds.Height+S(4),3*TextHeight+S(4)));
    FStatus.ShowHint:=True; FStatus.Hint:=FStatus.Caption;
    PageWidth:=Max(S(125),Canvas.TextWidth(FPage.Caption)+S(24));
    LaterWidth:=Max(S(115),Canvas.TextWidth(FLater.Caption)+S(24));
    FooterHeight:=ButtonHeight;
    if Width-PageWidth-LaterWidth-2*Gap<Max(S(160),Canvas.TextWidth(FPrimary.Caption)+S(24)) then
      FooterHeight:=2*ButtonHeight+Gap;
    ButtonTop := ClientHeight - Margin - FooterHeight;
    BytesHeight:=Max(S(20),TextHeight+S(4));
    TransferHeight:=S(18)+2*Gap+BytesHeight;
    FProgress.Visible := Assigned(FThread) or FReady or (FBytes.Caption <> '');
    NotesBottom:=ButtonTop-Gap;
    if FProgress.Visible then Dec(NotesBottom,TransferHeight);
    TableHeight:=S(204);
    if FComponentsView.HandleAllocated and (FComponentsView.Items.Count>0) then
    begin
      Bounds:=FComponentsView.Items[0].DisplayRect(drBounds);
      TableHeight:=Max(TableHeight,Bounds.Top+Bounds.Height*Min(FComponentsView.Items.Count,Length(UPDATE_COMPONENTS)+1)+S(8));
    end;
    // When a small window also shows transfer progress, let the component
    // list scroll rather than painting details over the footer controls.
    TableHeight:=Min(TableHeight,Max(S(100),NotesBottom-TableTop-2*Gap-StatusHeight-OptionalHeight-S(100)));
    FComponentsView.SetBounds(Margin,TableTop,Width,TableHeight);
    FComponentsView.Columns[0].Width:=Width*42 div 100;
    FComponentsView.Columns[1].Width:=Width*16 div 100;
    FComponentsView.Columns[2].Width:=Width*16 div 100;
    FComponentsView.Columns[3].Width:=Width-FComponentsView.Columns[0].Width-
      FComponentsView.Columns[1].Width-FComponentsView.Columns[2].Width-S(22);
    FStatus.SetBounds(Margin, FComponentsView.Top+FComponentsView.Height+Gap, Width, StatusHeight);
    if FTabs.TabIndex=1 then
      FStatus.SetBounds(Margin,FHistorySelector.Top+FHistorySelector.Height+Gap,Width,StatusHeight);
    if FooterHeight=ButtonHeight then
    begin
      FPrimary.SetBounds(Margin,ButtonTop,Width-PageWidth-LaterWidth-2*Gap,ButtonHeight);
      FPage.SetBounds(ClientWidth-Margin-PageWidth-LaterWidth-Gap,ButtonTop,PageWidth,ButtonHeight);
      FLater.SetBounds(ClientWidth-Margin-LaterWidth,ButtonTop,LaterWidth,ButtonHeight);
    end
    else
    begin
      FPrimary.SetBounds(Margin,ButtonTop,Width,ButtonHeight);
      FPage.SetBounds(Margin,ButtonTop+ButtonHeight+Gap,Max(PageWidth,(Width-Gap) div 2),ButtonHeight);
      FLater.SetBounds(FPage.Left+FPage.Width+Gap,FPage.Top,Width-FPage.Width-Gap,ButtonHeight);
    end;
    FBytes.Visible := FProgress.Visible;
    FProgress.SetBounds(Margin, ButtonTop - TransferHeight, Width, S(18));
    FBytes.SetBounds(Margin, ButtonTop - Gap - BytesHeight, Width, BytesHeight);
    FBytes.Hint:=FBytes.Caption;
    NotesTop := FStatus.Top + StatusHeight + Gap;
    if OptionalHeight>0 then FNotifyOptional.SetBounds(Margin,NotesTop,Width,OptionalHeight-Gap);
    Inc(NotesTop,OptionalHeight);
    NotesBottom := ButtonTop - Gap;
    if FProgress.Visible then NotesBottom := FProgress.Top - Gap;
    FNotes.SetBounds(Margin, NotesTop, Width, Max(0, NotesBottom - NotesTop));
    if WindowState = wsNormal then
    begin
      FNormalWidth := MulDiv(ClientWidth, 96, CurrentPPI);
      FNormalHeight := MulDiv(ClientHeight, 96, CurrentPPI);
    end;
  finally
    EnableAlign;
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(ProgramUpdateProfile.LayoutMS,GetTickCount64-ProfileStarted);{$ENDIF}
  end;
end;

procedure TfrmProgramUpdate.ViewTabChanged(Sender: TObject);
begin
  LayoutWindow;
end;

procedure TfrmProgramUpdate.OpenChanges(Sender: TObject);
begin
  FTabs.TabIndex:=1; ViewTabChanged(nil);
end;

procedure TfrmProgramUpdate.HistoryComponentSelected(Sender: TObject);
begin
  if FRefreshingComponents or (FHistorySelector.ItemIndex<0) then Exit;
  FRequestedComponent:=''; FRequestedComponents:=nil; FRequestReason:='';
  SelectRow(FRowIDs[FHistorySelector.ItemIndex]); ComponentSelected(nil);
end;

procedure TfrmProgramUpdate.ZoomClick(Sender: TObject);
begin
  if Sender = FZoomReset then FNotes.ZoomPercent := 100
  else FNotes.ZoomPercent := FNotes.ZoomPercent + TButton(Sender).Tag;
end;

procedure TfrmProgramUpdate.ZoomChanged(Sender: TObject);
begin
  FZoomReset.Caption := IntToStr(FNotes.ZoomPercent) + '%';
end;

procedure TfrmProgramUpdate.LoadViewPreferences;
var Root: TJSONValue; Width, Height, Zoom, Tab: Integer; Maximized: Boolean;
begin
  Root := TJSONObject.ParseJSONValue(ReadUpdateHistory(IncludeTrailingPathDelimiter(FCache) + 'view.json', 4096));
  try
    if not (Root is TJSONObject) then Exit;
    if TJSONObject(Root).TryGetValue<Integer>('width', Width) then
      ClientWidth := EnsureRange(Width, 760, Max(760, MulDiv(Screen.WorkAreaWidth - 40, 96, Screen.PixelsPerInch)));
    if TJSONObject(Root).TryGetValue<Integer>('height', Height) then
      ClientHeight := EnsureRange(Height, 560, Max(560, MulDiv(Screen.WorkAreaHeight - 70, 96, Screen.PixelsPerInch)));
    if TJSONObject(Root).TryGetValue<Integer>('zoom', Zoom) then FNotes.ZoomPercent := Zoom;
    if TJSONObject(Root).TryGetValue<Integer>('tab',Tab) then FTabs.TabIndex:=EnsureRange(Tab,0,1);
    if TJSONObject(Root).TryGetValue<Boolean>('maximized', Maximized) and Maximized then WindowState := wsMaximized;
  finally Root.Free; end;
end;

procedure TfrmProgramUpdate.SaveViewPreferences;
var Root: TJSONObject;
begin
  if not Assigned(FNotes) or (FNormalWidth = 0) then Exit;
  Root := TJSONObject.Create;
  try
    Root.AddPair('width', TJSONNumber.Create(FNormalWidth));
    Root.AddPair('height', TJSONNumber.Create(FNormalHeight));
    Root.AddPair('zoom', TJSONNumber.Create(FNotes.ZoomPercent));
    Root.AddPair('tab',TJSONNumber.Create(FTabs.TabIndex));
    Root.AddPair('maximized', TJSONBool.Create(WindowState = wsMaximized));
    WriteUpdateHistory(IncludeTrailingPathDelimiter(FCache) + 'view.json', Root.ToJSON);
  finally Root.Free; end;
end;

procedure TfrmProgramUpdate.DiscardJob;
begin
  if FJob = '' then Exit;
  try CleanProgramUpdate(FJob); except end;
  FJob := '';
end;

procedure TfrmProgramUpdate.SetRelease(const ReleaseInfo: TProgramRelease);
{$IFDEF MHL_RELEASE_PERFORMANCE}var ProfileStarted: UInt64;{$ENDIF}
begin
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
  BeginUIUpdate;
  try
  if ReleaseInfo.ComponentID = '' then
  begin FApplicationRelease:=ReleaseInfo; FApplicationVerified:=True; FApplicationFailed:=False; end;
  if FRecovery or Assigned(FThread) or FReady then
  begin Present; Exit; end;
  if ReleaseInfo.ComponentID = '' then
  begin SelectRow(0); FVersion.Caption := 'Текущая версия: ' + ReleaseDisplayVersion(PROGRAM_RELEASE_VERSION); end;
  FReady := False; FNeedsCheck := False; FRecovery := False; DiscardJob; FRelease := ReleaseInfo;
  UpdateReleasePage;
  FLater.Caption := 'Позже'; FLater.Enabled := True;
  if FRelease.History.Trim <> '' then DisplayNotes(FRelease.History)
  else DisplayNotes(FRelease.Changelog);
  FStatus.Caption := 'Доступно обновление ' + ReleaseTitle + '.' + sLineBreak +
    'Настройки, коллекции и история чтения сохранятся.';
  FProgress.Position := 0; FBytes.Caption := '';
  FPrimary.Caption := 'Скачать обновление'; FPrimary.Enabled := True;
  if FRelease.DownloadURL = '' then FPrimary.Caption := 'Скачать со страницы выпуска';
  if FRelease.CheckOnly then
  begin
    FPrimary.Caption:='Проверить у автора';
    FStatus.Caption:='У автора доступна версия '+ComponentDisplayVersion(FRelease.ComponentID,FRelease.ComponentVersion)+'. Официальный Windows-архив пока не удалось подтвердить.';
  end;
  // A cached row selection updates its summary once in ComponentSelected.
  if FSelectionDepth=0 then UpdateSummary;
  Present;
  finally
    EndUIUpdate;
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(ProgramUpdateProfile.ReleaseMS,GetTickCount64-ProfileStarted);{$ENDIF}
  end;
end;

function TfrmProgramUpdate.ReleaseTitle: string;
begin
  if FRelease.ComponentID = 'batch' then Exit('компонентов HomeLibre');
  if FRelease.ComponentID = '' then Result := ReleaseNotesHeading('HomeLibre ' + ReleaseDisplayVersion(FRelease.Tag), FRelease.PublishedAt)
  else Result := ReleaseNotesHeading(FRelease.ComponentID + ' ' + ComponentDisplayVersion(FRelease.ComponentID,FRelease.ComponentVersion), FRelease.PublishedAt);
end;

procedure TfrmProgramUpdate.NotificationChanged(Sender: TObject);
var Previous: string;
begin
  if FChangingNotification or (FSelectedRow<1) then Exit;
  Previous:=Settings.OptionalComponentUpdates;
  Settings.OptionalComponentUpdates:=SetComponentNotification(UPDATE_COMPONENTS[FSelectedRow-1].ID,
    Previous,FNotifyOptional.Checked);
  try Settings.SaveSettings;
  except Settings.OptionalComponentUpdates:=Previous; LayoutWindow; raise; end;
end;

function TfrmProgramUpdate.MayNotifyComponent(Index: Integer): Boolean;
begin
  Result:=ComponentAllowed(Index) and (not IsOptionalComponent(UPDATE_COMPONENTS[Index].ID) or
    ((InstalledVersion(UPDATE_COMPONENTS[Index].ID)<>'') and
     ComponentNotificationEnabled(UPDATE_COMPONENTS[Index].ID,Settings.OptionalComponentUpdates)));
end;

procedure TfrmProgramUpdate.RefreshInstalledComponents;
begin
  FRepairComponents:='';
  for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
  begin
    FInstalledVersions[I]:=ComponentInstalledVersion(Settings.AppPath,UPDATE_COMPONENTS[I].ID);
    if ComponentNeedsRepair(Settings.AppPath,UPDATE_COMPONENTS[I].ID) then
    begin
      FInstalledVersions[I]:='';
      // An intentionally absent optional reader/library is not a damaged
      // application installation and must not trigger a full repair download.
      if not IsOptionalComponent(UPDATE_COMPONENTS[I].ID) then
      begin
        if FRepairComponents<>'' then FRepairComponents:=FRepairComponents+', ';
        FRepairComponents:=FRepairComponents+UPDATE_COMPONENTS[I].ID;
      end;
    end;
  end;
  if not FReaderOnly and (UpdateFileVersion(Settings.AppPath+'HomeLibRuUpdater.exe')='') then
  begin
    if FRepairComponents<>'' then FRepairComponents:=FRepairComponents+', ';
    FRepairComponents:=FRepairComponents+'механизм обновления';
  end;
end;

function TfrmProgramUpdate.InstalledVersion(const ID: string): string;
begin
  Result:='';
  for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
    if UPDATE_COMPONENTS[I].ID=ID then Exit(FInstalledVersions[I]);
end;

function TfrmProgramUpdate.ComponentAllowed(Index: Integer): Boolean;
begin
  Result:=(Index>=Low(UPDATE_COMPONENTS)) and (Index<=High(UPDATE_COMPONENTS));
  if Result and FReaderOnly then
    Result:=(UPDATE_COMPONENTS[Index].ID<>'SQLite') and (UPDATE_COMPONENTS[Index].ID<>'AlReader') and
      (UPDATE_COMPONENTS[Index].ID<>'SumatraPDF') and (UPDATE_COMPONENTS[Index].ID<>'MHLMcpServer') and
      (UPDATE_COMPONENTS[Index].ID<>'Zstandard');
end;

function TfrmProgramUpdate.RowVisible(Value: Integer): Boolean;
begin
  if Value=0 then Exit(not FReaderOnly);
  if not ComponentAllowed(Value-1) then Exit(False);
  // External readers are user-selectable applications, not hidden decoders.
  if not FReaderOnly and ((UPDATE_COMPONENTS[Value-1].ID='AlReader') or
    (UPDATE_COMPONENTS[Value-1].ID='SumatraPDF')) then Exit(True);
  if FReaderOnly and (UPDATE_COMPONENTS[Value-1].ID='HomeLibReader') then Exit(True);
  Result:=True;
  // Format modules appear after installation or an explicit first-use
  // request, regardless of whether the optional reader itself is installed.
  if FReaderOnly or IsOptionalComponent(UPDATE_COMPONENTS[Value-1].ID) then
    Result:=(InstalledVersion(UPDATE_COMPONENTS[Value-1].ID)<>'') or
      (IndexText(UPDATE_COMPONENTS[Value-1].ID,FRequestedComponents)>=0);
end;

function TfrmProgramUpdate.ViewIndex(Value: Integer): Integer;
begin
  Result:=-1;
  for var I:=0 to High(FRowIDs) do if FRowIDs[I]=Value then Exit(I);
end;

procedure TfrmProgramUpdate.UseReaderComponents;
begin
  if Assigned(FComponentThread) or Assigned(FThread) then
    raise Exception.Create('Нельзя менять список компонентов во время загрузки.');
  FReaderOnly:=True; Caption:='Компоненты HomeLibre Reader';
  RefreshInstalledComponents; UpdateComponentList; ComponentSelected(nil);
end;

procedure TfrmProgramUpdate.UpdateComponentList;
var I, Comparison: Integer; Rows: TArray<Integer>; Changed: Boolean;
  Version, Available, State: string; Item: TListItem; Updating: Boolean;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted: UInt64;{$ENDIF}
  procedure BeginRows;
  begin
    if not Updating then begin FComponentsView.Items.BeginUpdate; Updating:=True; end;
  end;
  procedure Cell(Index: Integer; const Text: string);
  begin
    if Item.SubItems[Index]<>Text then begin BeginRows; Item.SubItems[Index]:=Text; end;
  end;
  procedure Row(Index: Integer; const Caption, Installed, Latest, Status: string);
  begin
    var VisibleIndex:=ViewIndex(Index); if VisibleIndex<0 then Exit;
    Item:=FComponentsView.Items[VisibleIndex];
    if Item.Caption<>Caption then begin BeginRows; Item.Caption:=Caption; end;
    while Item.SubItems.Count<3 do begin BeginRows; Item.SubItems.Add(''); end;
    Cell(0,Installed); Cell(1,Latest); Cell(2,Status);
  end;
begin
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
  FRefreshingComponents:=True; Updating:=False;
  try
    // Keep row objects alive while their native selection notification is
    // being handled. Refreshing versions must not recreate the selected item.
    Rows:=nil;
    if RowVisible(0) then Rows:=Rows+[0];
    // Logical IDs stay unchanged; only catalogue presentation order changes.
    if not FReaderOnly then
      for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
        if (UPDATE_COMPONENTS[I].ID='AlReader') or (UPDATE_COMPONENTS[I].ID='SumatraPDF') then
          if RowVisible(I+1) then Rows:=Rows+[I+1];
    for I:=1 to Length(UPDATE_COMPONENTS) do
      if RowVisible(I) and (FReaderOnly or
        ((UPDATE_COMPONENTS[I-1].ID<>'AlReader') and (UPDATE_COMPONENTS[I-1].ID<>'SumatraPDF'))) then Rows:=Rows+[I];
    Changed:=Length(Rows)<>Length(FRowIDs);
    if not Changed then for I:=0 to High(Rows) do if Rows[I]<>FRowIDs[I] then Changed:=True;
    if Changed then
    begin
      BeginRows; FComponentsView.Items.Clear; FHistorySelector.Items.Clear; FRowIDs:=Rows;
      for var Logical in FRowIDs do
      begin
        FComponentsView.Items.Add;
        if Logical=0 then FHistorySelector.Items.Add('HomeLibre')
        else FHistorySelector.Items.Add(ComponentTitle(Logical-1));
      end;
    end;
    Available:=FApplicationRelease.Tag; State:='Не проверено';
    if Available<>'' then
      if not HasApplicationDownload then State:='Нет проверенного архива'
      else if FRepairComponents<>'' then State:='Восстановление компонентов' else State:='Есть обновление'
    else if FApplicationVerified then
    begin Available:=PROGRAM_RELEASE_VERSION; State:='Актуально'; end
    else if FApplicationFailed then State:='Не удалось проверить';
    if FAppPending then State:='Проверяется…';
    if Available='' then Available:='—';
    Row(0,'HomeLibre',ReleaseDisplayVersion(PROGRAM_RELEASE_VERSION),ReleaseDisplayVersion(Available),State);
    for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
    begin
      Version := InstalledVersion(UPDATE_COMPONENTS[I].ID);
      if Version = '' then Version := 'не установлен';
      State:='Не проверено'; Available:='—';
      if (FComponents[I].ComponentError<>'') or (FComponentError<>'') then State:='Не удалось проверить'
      else if (FComponents[I].ComponentWarning<>'') and (FComponents[I].DownloadURL='') then State:='Версия не подтверждена'
      else if FComponents[I].DownloadURL<>'' then
      begin
        Available:=FComponents[I].ComponentVersion;
        if FComponents[I].ComponentWarning<>'' then State:='Запасная копия'
        else if ComponentNewer(FComponents[I],InstalledVersion(UPDATE_COMPONENTS[I].ID)) then
          if FComponents[I].CheckOnly then State:='Нет Windows-архива'
          else if (Version='') and IsOptionalComponent(UPDATE_COMPONENTS[I].ID) then State:='Можно установить'
          else State:='Есть обновление'
        else State:='Актуально';
      end;
      if FComponents[I].AuthorVersion<>'' then
      begin
        Available:=FComponents[I].AuthorVersion;
        if (State='Актуально') and CompareComponentVersions(Available,Version,Comparison) and
          (Comparison>0) then State:='Нет Windows-архива';
      end;
      if FComponentWaiting[I] then
        State:='Проверяется…';
      Row(I+1,ComponentTitle(I),ComponentDisplayVersion(UPDATE_COMPONENTS[I].ID,Version),
        ComponentDisplayVersion(UPDATE_COMPONENTS[I].ID,Available),State);
    end;
    SelectRow(FSelectedRow);
  finally
    if Updating then FComponentsView.Items.EndUpdate;
    FRefreshingComponents:=False;
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(ProgramUpdateProfile.RowsMS,GetTickCount64-ProfileStarted);{$ENDIF}
  end;
end;

procedure TfrmProgramUpdate.SelectRow(Value: Integer);
var Refreshing: Boolean; Position: Integer;
begin
  if Length(FRowIDs)=0 then begin FSelectedRow:=0; Exit; end;
  Position:=ViewIndex(Value); if Position<0 then Position:=0;
  FSelectedRow:=FRowIDs[Position];
  if FHistorySelector.ItemIndex<>Position then FHistorySelector.ItemIndex:=Position;
  Refreshing:=FRefreshingComponents; FRefreshingComponents:=True;
  try
    if not FComponentsView.Items[Position].Selected then FComponentsView.Items[Position].Selected:=True;
    if not FComponentsView.Items[Position].Focused then FComponentsView.Items[Position].Focused:=True;
  finally FRefreshingComponents:=Refreshing; end;
end;

procedure TfrmProgramUpdate.ComponentRowSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if not Selected or FRefreshingComponents then Exit;
  // Keep the native list enabled so VCL does not replace its theme colours.
  // Restore the existing selection while downloading/ready, without changing
  // the release, notes or install action. Copying the list remains available.
  if Assigned(FThread) or FReady then
  begin
    SelectRow(FSelectedRow);
    Exit;
  end;
  if (Item.Index<0) or (Item.Index>High(FRowIDs)) then Exit;
  if FSelectedRow=FRowIDs[Item.Index] then Exit;
  FRequestedComponent:=''; FRequestedComponents:=nil; FRequestReason:='';
  FSelectedRow:=FRowIDs[Item.Index]; ComponentSelected(nil);
end;

procedure TfrmProgramUpdate.ComponentKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key=Ord('C')) and (ssCtrl in Shift) then
  begin CopyComponents(nil); Key:=0; end;
end;

procedure TfrmProgramUpdate.ComponentMenuPopup(Sender: TObject);
begin
  for var Entry in FComponentsView.PopupMenu.Items do
    if Entry.Tag=2 then
      Entry.Enabled:=(FSelectedRow>0) and
        ((FComponents[FSelectedRow-1].ComponentError<>'') or (FComponentError<>''));
end;

procedure TfrmProgramUpdate.CopyComponents(Sender: TObject);
var Text: string; I, First, Last, Attempt: Integer;
begin
  Text:=''; First:=ViewIndex(FSelectedRow); Last:=First;
  if (Sender is TMenuItem) and (TMenuItem(Sender).Tag=2) then
  begin
    if FSelectedRow<=0 then Exit;
    Text:=ComponentTitle(FSelectedRow-1)+sLineBreak;
    if FComponents[FSelectedRow-1].ComponentError<>'' then
      Text:=Text+FComponents[FSelectedRow-1].ComponentError+sLineBreak+
        Copy(FComponents[FSelectedRow-1].ComponentErrorDetails,1,4096)
    else if FComponentError<>'' then
      Text:=Text+FComponentError+sLineBreak+Copy(FComponentErrorDetails,1,4096)
    else Exit;
    Last:=First-1;
  end
  else if (Sender is TMenuItem) and (TMenuItem(Sender).Tag=1) then
  begin
    First:=0; Last:=FComponentsView.Items.Count-1;
    for I:=0 to FComponentsView.Columns.Count-1 do
    begin if I>0 then Text:=Text+#9; Text:=Text+FComponentsView.Columns[I].Caption; end;
    Text:=Text+sLineBreak;
  end;
  for I:=First to Last do
  begin
    if I>First then Text:=Text+sLineBreak;
    Text:=Text+FComponentsView.Items[I].Caption+#9+
      FComponentsView.Items[I].SubItems[0]+#9+FComponentsView.Items[I].SubItems[1]+#9+
      FComponentsView.Items[I].SubItems[2];
  end;
  // Clipboard managers sometimes hold the Windows clipboard briefly. A copy
  // command must not leave the form through an unhandled access-denied error.
  for Attempt:=0 to 9 do
    try Clipboard.AsText:=Text; Exit;
    except
      on E: EClipboardException do
        if Attempt=9 then
        begin FStatus.Caption:='Буфер обмена занят. Повторите копирование.'; LayoutWindow; end
        else Sleep(10);
    end;
end;

procedure TfrmProgramUpdate.ComponentSelected(Sender: TObject);
var I: Integer; Version: string;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted, ChangesStarted: UInt64;{$ENDIF}
begin
  if Assigned(FThread) or FReady then Exit;
  if Length(FRequestedComponents)>1 then begin ShowRequestedComponents; Exit; end;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
  Inc(FSelectionDepth); BeginUIUpdate;
  try
  I := FSelectedRow - 1;
  if I < 0 then
  begin
    FPage.Caption := 'Открыть GitHub';
    FVersion.Caption := 'Текущая версия: ' + ReleaseDisplayVersion(PROGRAM_RELEASE_VERSION);
    if FApplicationRelease.Tag <> '' then SetRelease(FApplicationRelease)
    else
    begin
      FRelease := Default(TProgramRelease); FNeedsCheck := True;
      FStatus.Caption := FApplicationStatus; DisplayNotes(FApplicationHistory);
      FPrimary.Caption := 'Проверить обновления'; FPrimary.Enabled := True;
    end;
    UpdateSummary;
    Exit;
  end;
  Version := InstalledVersion(UPDATE_COMPONENTS[I].ID);
  FPage.Caption:=UpdateReleasePageCaption(UPDATE_COMPONENTS[I].ID,FComponents[I].URL);
  FVersion.Caption := ComponentTitle(I) + ': ' + ComponentDisplayVersion(UPDATE_COMPONENTS[I].ID,Version);
  if Version = '' then FVersion.Caption := ComponentTitle(I) + ': не установлен';
  if ComponentNewer(FComponents[I], Version) then
  begin
    {$IFDEF MHL_RELEASE_PERFORMANCE}ChangesStarted:=GetTickCount64;{$ENDIF}
    FComponents[I].Changelog := ComponentChanges(FComponents[I], Version);
    {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(ProgramUpdateProfile.ChangesMS,GetTickCount64-ChangesStarted);{$ENDIF}
    SetRelease(FComponents[I]);
    if (Version='') and IsOptionalComponent(UPDATE_COMPONENTS[I].ID) and not FComponents[I].CheckOnly then
    begin
      FPrimary.Caption:='Скачать компонент';
      FStatus.Caption:=Format('Для установки «%s» нужно скачать %s.',
        [UPDATE_COMPONENTS[I].Title,ComponentDownloadSize(FComponents[I].Size)]);
      if FRequestedComponent=UPDATE_COMPONENTS[I].ID then
        FStatus.Caption:=FRequestReason+sLineBreak+FStatus.Caption+sLineBreak+
          IfThen(FOperationComponent<>'','После установки продолжится выбранная операция.',
            IfThen(FReaderOnly,'После установки читалка перезапустится и откроет эту книгу.',
              'После установки программа перезапустится.'));
    end;
  end
  else
  begin
    FRelease := Default(TProgramRelease); FNeedsCheck := True;
    FProgress.Position := 0; FBytes.Caption := ''; FPrimary.Enabled := not FComponentWaiting[I];
    FPrimary.Caption := 'Проверить всё';
    DisplayNotes(FComponents[I].History);
    if (UPDATE_COMPONENTS[I].CheckKind=ccPublished) or
      FComponents[I].URL.StartsWith(
      'https://github.com/Dicur3x/MyHomeLib/releases/tag/') then
      FStatus.Caption:='Источник: проверенный пакет HomeLibre на GitHub.'+sLineBreak
    else FStatus.Caption := 'Источник: официальный сайт автора компонента.' + sLineBreak;
    if FComponents[I].ComponentError <> '' then FStatus.Caption := FStatus.Caption + FComponents[I].ComponentError
    else if FComponentError <> '' then FStatus.Caption := FStatus.Caption + FComponentError
    else if FComponents[I].ComponentWarning<>'' then FStatus.Caption:=FStatus.Caption+FComponents[I].ComponentWarning
    else if FComponents[I].DownloadURL <> '' then
      FStatus.Caption := FStatus.Caption + 'Обновлений нет. Установлена актуальная версия.'
    else FStatus.Caption := FStatus.Caption + 'Нажмите «Проверить всё», чтобы узнать о новой версии.';
    if FRequestedComponent=UPDATE_COMPONENTS[I].ID then
      FStatus.Caption:=FRequestReason+sLineBreak+FStatus.Caption;
    if (FComponents[I].ComponentError<>'') or (FComponentError<>'') or
      (FComponents[I].ComponentWarning<>'') then FPrimary.Caption:='Повторить проверку';
    if FComponents[I].CheckOnly then
      FStatus.Caption:=FStatus.Caption+sLineBreak+'Проверяется официальный Windows-выпуск автора.';
  end;
  if (FComponents[I].ComponentWarning<>'') and not string(FStatus.Caption).Contains(FComponents[I].ComponentWarning) then
    FStatus.Caption:=FStatus.Caption+sLineBreak+FComponents[I].ComponentWarning;
  if FComponentWaiting[I] then
  begin FPrimary.Enabled:=False; FStatus.Caption:='Проверяется '+UPDATE_COMPONENTS[I].ID+'…'; end;
  UpdateSummary;
  finally
    try EndUIUpdate; finally Dec(FSelectionDepth); end;
    {$IFDEF MHL_RELEASE_PERFORMANCE}
    Inc(ProgramUpdateProfile.Selections); Inc(ProgramUpdateProfile.SelectionMS,GetTickCount64-ProfileStarted);
    {$ENDIF}
  end;
end;

function TfrmProgramUpdate.HasApplicationDownload: Boolean;
begin
  Result:=(FApplicationRelease.Tag<>'') and (FApplicationRelease.DownloadURL<>'') and
    IsUpdateSHA256(FApplicationRelease.SHA256) and
    (FApplicationRelease.Size>0) and (FApplicationRelease.Size<=UPDATE_MAX_ARCHIVE);
end;

function TfrmProgramUpdate.AvailableUpdates: TArray<TProgramRelease>;
var I, Count: Integer;
begin
  Result := nil;
  // An unavailable application archive must not cancel independent packages.
  if not FReaderOnly and HasApplicationDownload then
  begin SetLength(Result, 1); Result[0] := FApplicationRelease; end;
  for I in CheckedComponentIndices do
    if ComponentAllowed(I) and RowVisible(I+1) and not FComponents[I].CheckOnly and
      (not IsOptionalComponent(ComponentIDs[I]) or
       ((InstalledVersion(ComponentIDs[I])<>'') and (not FCycleAutomatic or MayNotifyComponent(I)))) and
      ComponentNewer(FComponents[I], InstalledVersion(ComponentIDs[I])) then
    begin
      Count := Length(Result); SetLength(Result, Count + 1); Result[Count] := FComponents[I];
    end;
end;

function TfrmProgramUpdate.AvailableSummary: string;
var Releases: TArray<TProgramRelease>; I: Integer; Name: string;
begin
  Releases := AvailableUpdates; Result := '';
  for I := 0 to High(Releases) do
  begin
    Name := Releases[I].ComponentID; if Name = '' then Name := 'HomeLibre';
    if I > 0 then
      if I = High(Releases) then Result := Result + ' и ' else Result := Result + ', ';
    Result := Result + Name;
  end;
  if Result <> '' then Result := 'Есть обновления для ' + Result;
  if HasApplicationDownload and (FRepairComponents<>'') then
    Result:='Будут восстановлены отсутствующие файлы: '+FRepairComponents+'.';
end;

function TfrmProgramUpdate.ComponentCheckSummary: string;
var Failed, Unverified: string;
begin
  Failed:=''; Unverified:=''; Result:='';
  for var I in CheckedComponentIndices do
  begin
    if FComponents[I].ComponentError<>'' then
    begin
      if Failed<>'' then Failed:=Failed+', ';
      Failed:=Failed+ComponentIDs[I];
    end
    else if FComponents[I].ComponentWarning<>'' then
    begin
      if Unverified<>'' then Unverified:=Unverified+', ';
      Unverified:=Unverified+ComponentIDs[I];
    end;
  end;
  if FComponentError<>'' then Result:=FComponentError
  else if Failed<>'' then Result:='Не удалось проверить: '+Failed+'.';
  if Unverified<>'' then
  begin
    if Result<>'' then Result:=Result+' ';
    Result:=Result+'Версия не подтверждена: '+Unverified+'.';
  end;
  if Result<>'' then Result:=Result+' Выберите строку для подробностей или повторите проверку.';
end;

procedure TfrmProgramUpdate.UpdateSummary;
var Summary: string;
begin
  // Selecting a cached row changes no installed/available versions or states.
  // Check/download callbacks still refresh the inventory outside this scope.
  if FSelectionDepth=0 then UpdateComponentList;
  if FReady or Assigned(FThread) or ((FSelectedRow > 0) and FRelease.CheckOnly) then Exit;
  // A healthy installed component keeps its failed-source Retry action.
  // Missing local files can instead be restored from a verified app package;
  // the source failure remains visible in the summary and component table.
  if (FSelectedRow>0) and ((FComponents[FSelectedRow-1].ComponentError<>'') or
    (FComponents[FSelectedRow-1].ComponentWarning<>'') or (FComponentError<>'')) and
    not (HasApplicationDownload and
      (InstalledVersion(UPDATE_COMPONENTS[FSelectedRow-1].ID)='')) then Exit;
  if (FSelectedRow>0) and IsOptionalComponent(UPDATE_COMPONENTS[FSelectedRow-1].ID) then Exit;
  Summary := AvailableSummary;
  if Summary <> '' then
  begin
    FStatus.Caption := Summary;
    if ComponentCheckSummary<>'' then FStatus.Caption:=FStatus.Caption+sLineBreak+ComponentCheckSummary;
    if FApplicationFailed then FStatus.Caption:=FStatus.Caption+sLineBreak+'HomeLibre не удалось проверить. Повторите проверку.';
    FNeedsCheck := False;
    if Length(AvailableUpdates) > 1 then FPrimary.Caption := 'Скачать все обновления'
    else FPrimary.Caption := 'Скачать обновление';
    if HasApplicationDownload and (FRepairComponents<>'') then FPrimary.Caption:='Скачать и восстановить';
    FPrimary.Enabled := not FCheckingCycle;
  end;
end;

function TfrmProgramUpdate.StartCheckCycle(Automatic: Boolean): Boolean;
var I: Integer;
begin
  Result := False;
  if FCheckingCycle or Assigned(FThread) or Assigned(FComponentThread) then Exit;
  if FReady then begin if not Automatic then Present; Exit; end;
  FRequestedComponent:=''; FRequestedComponents:=nil; FRequestReason:='';
  RefreshInstalledComponents;
  FCycleAutomatic := Automatic; FCheckingCycle := True; FAppPending := True; FComponentsPending := True;
  FApplicationRelease := Default(TProgramRelease);
  FApplicationVerified:=False; FApplicationFailed:=False;
  for I in CheckedComponentIndices do FComponents[I].DownloadURL := '';
  if not Automatic then BeginCheck;
  UpdateComponentList; FComponentCheck.Enabled:=False;
  Result := True;
end;

procedure TfrmProgramUpdate.ApplicationChecked(const ReleaseInfo: TProgramRelease;
  Successful: Boolean; const Error: string);
var Comparison: Integer;
begin
  if not FCheckingCycle then Exit;
  FAppPending := False;
  FApplicationVerified:=Successful; FApplicationFailed:=not Successful;
  if Successful then
  begin
    RememberHistory(ReleaseInfo);
    FApplicationStatus := 'Обновлений нет. У вас установлена последняя версия HomeLibre.';
    if CompareReleaseTags(ReleaseInfo.Tag, PROGRAM_RELEASE_VERSION, Comparison) and
      ((Comparison>0) or ((Comparison=0) and (FRepairComponents<>'') and
      (ReleaseInfo.DownloadURL<>'') and IsUpdateSHA256(ReleaseInfo.SHA256) and (ReleaseInfo.Size>0))) then
      FApplicationRelease := ReleaseInfo;
  end
  else FApplicationStatus := Error;
  UpdateComponentList;
  FinishCheckCycle;
end;

procedure TfrmProgramUpdate.FinishCheckCycle;
var J: Integer; HasComponentUpdate: Boolean;
begin
  if not FCheckingCycle or FAppPending or FComponentsPending then Exit;
  FCheckingCycle := False;
  FComponentCheck.Enabled:=True;
  if FRequestedCheckPending then
  begin FRequestedCheckPending:=False; CheckComponents(False); Exit; end;
  if Assigned(FThread) or FReady then begin UpdateComponentList; Exit; end;
  UpdateComponentList;
  HasComponentUpdate := False;
  for J in CheckedComponentIndices do
    if (not FCycleAutomatic or MayNotifyComponent(J)) and
      (not IsOptionalComponent(ComponentIDs[J]) or (InstalledVersion(ComponentIDs[J])<>'')) and
      ComponentNewer(FComponents[J], InstalledVersion(ComponentIDs[J])) then HasComponentUpdate := True;
  if (FApplicationRelease.Tag <> '') or (Length(AvailableUpdates) > 0) or HasComponentUpdate then
  begin
    SelectRow(0);
    if FApplicationRelease.Tag = '' then
      for J := 0 to High(CheckedComponentIndices) do
        if (not FCycleAutomatic or MayNotifyComponent(CheckedComponentIndices[J])) and
          (not IsOptionalComponent(ComponentIDs[CheckedComponentIndices[J]]) or
            (InstalledVersion(ComponentIDs[CheckedComponentIndices[J]])<>'')) and
          ComponentNewer(FComponents[CheckedComponentIndices[J]],
          InstalledVersion(ComponentIDs[CheckedComponentIndices[J]])) then
        begin SelectRow(CheckedComponentIndices[J] + 1); Break; end;
    ComponentSelected(nil); UpdateSummary; Present;
  end
  else
  begin
    if not FCycleAutomatic then SelectRow(0);
    ComponentSelected(nil);
    if FSelectedRow=0 then
    begin
      FStatus.Caption := FApplicationStatus;
      if ComponentCheckSummary<>'' then FStatus.Caption:=FStatus.Caption+sLineBreak+ComponentCheckSummary;
      FPrimary.Caption := 'Проверить ещё раз';
    end;
    FPrimary.Enabled := True; LayoutWindow;
    if not FCycleAutomatic then Present;
  end;
end;

procedure TfrmProgramUpdate.ComponentCheckClick(Sender: TObject);
begin
  if Assigned(FThread) or FReady or FCheckingCycle then Exit;
  if Sender<>nil then begin FRequestedComponent:=''; FRequestedComponents:=nil; FRequestReason:=''; end;
  if FRequestedComponent<>'' then begin FComponentExplicit:=True; CheckComponents(False); Exit; end;
  if Assigned(FCheck) then FCheck(Self)
  else begin FComponentExplicit:=True; CheckComponents(False); end;
end;

procedure TfrmProgramUpdate.EnsureMessageWindow;
begin
  // VCL style/DPI changes can recreate this form's visible HWND while a
  // worker runs. Its notifier stays owned and stable until both workers join.
  if FMessageWindow = 0 then FMessageWindow := AllocateHWnd(MessageWindowProc);
end;

procedure TfrmProgramUpdate.MessageWindowProc(var Message: TMessage);
begin
  case Message.Msg of
    WM_COMPONENT_UPDATE_CHECKED: ComponentsChecked(Message);
    WM_COMPONENT_UPDATE_PROGRESS: ComponentProgress(Message);
    WM_PROGRAM_UPDATE_DOWNLOADED: DownloadCompleted(Message);
    WM_PROGRAM_UPDATE_PROGRESS: DownloadProgress(Message);
  else Message.Result := DefWindowProc(FMessageWindow, Message.Msg, Message.WParam, Message.LParam);
  end;
end;

function TfrmProgramUpdate.CreateComponentWorker(Window: HWND): TComponentUpdateThread;
begin
  Result := TComponentUpdateThread.Create(Window, CreateHTTPClientGlobal, PROGRAM_RELEASES_API, FCache);
  Result.PreferReadyDjvu:=(IndexText('DjVuLibre',FRequestedComponents)>=0) and
    ComponentNeedsRepair(Settings.AppPath,'DjVuLibre') and (FindFullSevenZip(Settings.AppPath)='');
end;

function TfrmProgramUpdate.CreateDownloadWorker(Window: HWND; const ReleaseInfo: TProgramRelease;
  const Job: string): TProgramDownloadThread;
begin
  Result := TProgramDownloadThread.Create(Window, CreateHTTPClientGlobal, ReleaseInfo, Job);
end;

procedure TfrmProgramUpdate.CreateCompactPrompt;
begin
  if Assigned(FCompactForm) then Exit;
  Hide;
  FCompactForm:=TOperationComponentPrompt.CreatePrompt(Self,FReaderOnly);
  FCompactForm.Name:='OptionalComponentPrompt';
  FCompactForm.Caption:='Установка компонента'; FCompactForm.Position:=poMainFormCenter;
  FCompactForm.Font.Name:='Segoe UI'; FCompactForm.Font.Size:=9;
  FCompactForm.ClientWidth:=560; FCompactForm.ClientHeight:=306;
  FCompactForm.BorderStyle:=bsSizeable;
  FCompactForm.Constraints.MinWidth:=480+FCompactForm.Width-FCompactForm.ClientWidth;
  FCompactForm.Constraints.MinHeight:=280+FCompactForm.Height-FCompactForm.ClientHeight;
  FCompactForm.OnClose:=CompactClose;
  FCompactHeader:=TLabel.Create(FCompactForm); FCompactHeader.Parent:=FCompactForm;
  FCompactHeader.Name:='ComponentPromptTitle'; FCompactHeader.AutoSize:=False;
  FCompactHeader.WordWrap:=True; FCompactHeader.ShowAccelChar:=False;
  FCompactHeader.SetBounds(16,12,528,38); FCompactHeader.Anchors:=[akLeft,akTop,akRight];
  FCompactStatus:=TMemo.Create(FCompactForm); FCompactStatus.Parent:=FCompactForm;
  FCompactStatus.Name:='ComponentPromptReason'; FCompactStatus.ReadOnly:=True;
  FCompactStatus.BorderStyle:=bsNone; FCompactStatus.ScrollBars:=ssVertical;
  FCompactStatus.SetBounds(16,56,528,146); FCompactStatus.Anchors:=[akLeft,akTop,akRight,akBottom];
  FCompactProgress:=TProgressBar.Create(FCompactForm); FCompactProgress.Parent:=FCompactForm;
  FCompactProgress.Name:='ComponentPromptProgress';
  FCompactProgress.SetBounds(16,212,528,18); FCompactProgress.Anchors:=[akLeft,akRight,akBottom];
  FCompactBytes:=TLabel.Create(FCompactForm); FCompactBytes.Parent:=FCompactForm;
  FCompactBytes.Name:='ComponentPromptBytes';
  FCompactBytes.AutoSize:=False; FCompactBytes.ShowAccelChar:=False;
  FCompactBytes.SetBounds(16,234,528,18); FCompactBytes.Anchors:=[akLeft,akRight,akBottom];
  FCompactPrimary:=TButton.Create(FCompactForm); FCompactPrimary.Parent:=FCompactForm;
  FCompactPrimary.Name:='ComponentPromptDownload'; FCompactPrimary.Default:=True;
  FCompactPrimary.SetBounds(16,266,386,28); FCompactPrimary.Anchors:=[akLeft,akRight,akBottom];
  FCompactPrimary.OnClick:=PrimaryClick;
  FCompactLater:=TButton.Create(FCompactForm); FCompactLater.Parent:=FCompactForm;
  FCompactLater.Name:='ComponentPromptCancel'; FCompactLater.Cancel:=True;
  FCompactLater.SetBounds(416,266,128,28); FCompactLater.Anchors:=[akRight,akBottom];
  FCompactLater.OnClick:=CompactLater;
  FCompactForm.ScaleForPPI(CurrentPPI); ApplyMHLControlTheme(FCompactForm);
end;

procedure TfrmProgramUpdate.SyncCompactPrompt;
var Text: string;
begin
  if not Assigned(FCompactForm) then Exit;
  FCompactHeader.Caption:=FVersion.Caption;
  Text:=FStatus.Caption;
  if (FRequestReason<>'') and (Pos(FRequestReason,Text)=0) then Text:=FRequestReason+sLineBreak+Text;
  if Trim(FCompactStatus.Text)<>Trim(Text) then FCompactStatus.Text:=Text;
  FCompactBytes.Caption:=FBytes.Caption;
  if FCompactBytes.Caption='' then
    if (FRelease.Size>0) and (FRelease.DownloadURL<>'') then
    begin
      FCompactBytes.Caption:='Нужно скачать: '+ComponentDownloadSize(FRelease.Size);
    end
    else FCompactBytes.Caption:='Размер загрузки пока неизвестен.';
  FCompactProgress.Visible:=Assigned(FThread) or FReady or (FBytes.Caption<>'');
  FCompactProgress.Position:=FProgress.Position;
  FCompactPrimary.Caption:=FPrimary.Caption; FCompactPrimary.Enabled:=FPrimary.Enabled;
  FCompactLater.Caption:='Отмена'; FCompactLater.Enabled:=FLater.Enabled;
end;

procedure TfrmProgramUpdate.CompactLater(Sender: TObject);
begin
  if FOperationComponent<>'' then
  begin
    if Assigned(FThread) then FThread.Terminate;
    FCompactForm.ModalResult:=mrCancel; Exit;
  end;
  LaterClick(Sender);
  if Assigned(FThread) then SyncCompactPrompt else FCompactForm.Hide;
end;

procedure TfrmProgramUpdate.CompactClose(Sender: TObject; var Action: TCloseAction);
begin
  if FOperationComponent<>'' then
  begin
    if FCompactForm.ModalResult<>mrOk then CompactLater(Sender);
    Action:=caHide; Exit;
  end;
  LaterClick(Sender); Action:=caHide;
end;

function TfrmProgramUpdate.InstallComponentForOperation(const ID, Reason: string): Boolean;
begin
  // Only the catalogue decoder is installed in a running process. Executables
  // and already loaded libraries keep the normal restart transaction.
  if (ID<>'Zstandard') or (GetModuleHandle(PChar(Settings.AppPath+'libzstd.dll'))<>0) then
    raise Exception.Create('Для установки этого компонента требуется перезапуск программы.');
  if Assigned(FThread) or Assigned(FComponentThread) or FReady then
    raise Exception.Create('Дождитесь завершения предыдущей операции обновления.');
  Result:=False; FOperationComponent:=ID;
  try
    RequestComponent(ID,Reason,True);
    FCompactForm.Hide;
    Result:=FCompactForm.ShowModal=mrOk;
  finally
    if Assigned(FThread) then begin FThread.Terminate; FreeAndNil(FThread); end;
    // This operation never writes the ordinary updater's ready.json and cannot
    // replace or discard a separately prepared application update.
    FReady:=False; DiscardJob; ClearQueueJobs; FOperationComponent:='';
  end;
end;

procedure TfrmProgramUpdate.UseFullWindow;
begin
  FreeAndNil(FCompactForm);
  FCompactStatus:=nil; FCompactHeader:=nil; FCompactBytes:=nil;
  FCompactProgress:=nil; FCompactPrimary:=nil; FCompactLater:=nil;
  LayoutWindow;
end;

function TfrmProgramUpdate.RequestedReleases: TArray<TProgramRelease>;
begin
  Result:=nil;
  for var ID in FRequestedComponents do
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID=ID then
      begin
        if FComponentWaiting[I] or (FComponents[I].ComponentError<>'') or
          (FComponents[I].DownloadURL='') or FComponents[I].CheckOnly or
          (FComponents[I].Size<=0) then Exit(nil);
        Result:=Result+TArray<TProgramRelease>.Create(FComponents[I]);
        Break;
      end;
end;

procedure TfrmProgramUpdate.ShowRequestedComponents;
var Releases: TArray<TProgramRelease>; Total: Int64; Text: string;
begin
  FVersion.Caption:=Format('Компоненты для выбранной операции: %d',[Length(FRequestedComponents)]);
  Text:=''; Total:=0;
  for var ID in FRequestedComponents do
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID=ID then
      begin
        if Text<>'' then Text:=Text+sLineBreak;
        Text:=Text+UPDATE_COMPONENTS[I].Title+' — ';
        if FComponentWaiting[I] then Text:=Text+'проверяется…'
        else if FComponents[I].ComponentError<>'' then Text:=Text+FComponents[I].ComponentError
        else if FComponents[I].DownloadURL='' then Text:=Text+'пакет пока недоступен'
        else Text:=Text+ComponentDownloadSize(FComponents[I].Size);
        Inc(Total,FComponents[I].Size); Break;
      end;
  Releases:=RequestedReleases; FNeedsCheck:=Length(Releases)<>Length(FRequestedComponents);
  FRelease:=Default(TProgramRelease); FBytes.Caption:='';
  FPrimary.Caption:='Повторить проверку'; FPrimary.Enabled:=not Assigned(FComponentThread);
  if not FNeedsCheck then
  begin
    FRelease:=Releases[0]; FBytes.Caption:='Нужно скачать: '+ComponentDownloadSize(Total);
    FPrimary.Caption:='Скачать компоненты'; FPrimary.Enabled:=True;
    Text:=Text+sLineBreak+sLineBreak+'Компоненты установятся вместе. Потребуется один перезапуск; параметры сохранения останутся.';
  end;
  FStatus.Caption:=FRequestReason+sLineBreak+sLineBreak+Text;
  LayoutWindow;
end;

procedure TfrmProgramUpdate.RequestComponent(const ID, Reason: string; Compact: Boolean);
begin RequestComponents(TArray<string>.Create(ID),Reason,Compact); end;

procedure TfrmProgramUpdate.RequestComponents(const IDs: TArray<string>; const Reason: string; Compact: Boolean);
var Index: Integer; Purpose, ID: string; Requested: TArray<string>;
begin
  Requested:=nil; Index:=-1;
  for var Value in IDs do
  begin
    ID:=Value; if ID='BookConverter' then ID:='BookProcessing';
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if (UPDATE_COMPONENTS[I].ID=ID) and ComponentAllowed(I) and IsOptionalComponent(ID) and
        (IndexText(ID,Requested)<0) then
      begin Requested:=Requested+TArray<string>.Create(ID); if Index<0 then Index:=I; Break; end;
  end;
  if Length(Requested)=0 then Exit;
  if Compact then CreateCompactPrompt else UseFullWindow;
  if Assigned(FThread) or FReady then begin Present; Exit; end;
  FRequestedComponents:=Requested; FRequestedComponent:=Requested[0]; FRequestReason:=Trim(Reason);
  for ID in Requested do
  begin
    Purpose:=ComponentPurpose(ID);
    if (Purpose<>'') and not FRequestReason.Replace(#13,'').Contains(Purpose.Replace(#13,'')) then
    begin
      if FRequestReason<>'' then FRequestReason:=FRequestReason+sLineBreak+Purpose
      else FRequestReason:=Purpose;
    end;
  end;
  UpdateComponentList;
  if FCheckingCycle or Assigned(FComponentThread) then
  begin
    FRequestedCheckPending:=True; SelectRow(Index+1); ComponentSelected(nil); Present; Exit;
  end;
  FCycleAutomatic:=False; FApplicationRelease:=Default(TProgramRelease);
  FNeedsCheck:=True; FComponentExplicit:=True;
  SelectRow(Index+1); CheckComponents(False);
  FStatus.Caption:=FRequestReason+sLineBreak+'Проверяем доступность и размер загрузки…'; LayoutWindow; Present;
end;

procedure TfrmProgramUpdate.CheckComponents(Automatic: Boolean);
var IDs: TArray<string>;
begin
  if Assigned(FComponentThread) then Exit;
  if not FCheckingCycle then RefreshInstalledComponents;
  FComponentAutomatic := Automatic; FComponentError := ''; FComponentErrorDetails:='';
  EnsureMessageWindow;
  FComponentThread := CreateComponentWorker(FMessageWindow);
  if FRequestedComponent<>'' then FComponentThread.OnlyIDs:=Copy(FRequestedComponents)
  else
  begin
    IDs:=nil;
    for var I in CheckedComponentIndices do
      if ComponentAllowed(I) and RowVisible(I+1) and (not Automatic or MayNotifyComponent(I)) then
        IDs:=IDs+TArray<string>.Create(UPDATE_COMPONENTS[I].ID);
    if Length(IDs)=0 then IDs:=TArray<string>.Create('#none');
    FComponentThread.OnlyIDs:=IDs;
  end;
  for var I:=Low(FComponentWaiting) to High(FComponentWaiting) do
    FComponentWaiting[I]:=(Length(FComponentThread.OnlyIDs)=0) or
      (System.StrUtils.IndexText(UPDATE_COMPONENTS[I].ID,FComponentThread.OnlyIDs)>=0);
  FComponentCheck.Enabled := False;
  UpdateComponentList;
  if (FSelectedRow > 0) and not Assigned(FThread) and not FReady then
  begin
    FStatus.Caption := 'Проверка обновлений компонентов у авторов…'; FPrimary.Enabled := False;
  end;
  FComponentThread.Start;
end;

procedure TfrmProgramUpdate.ComponentProgress(var Message: TMessage);
var I: Integer; Updated: TComponentReleases; Info: TProgramRelease;
begin
  Message.Result:=0;
  if not Assigned(FComponentThread) or (Message.WParam<>WPARAM(FComponentThread)) then Exit;
  I:=Message.LParam;
  if not FComponentThread.TryGetRelease(I,Info) then Exit;
  Updated:=FComponents; Updated[I]:=Info;
  PreserveComponentHistory(Updated,FComponents); FComponents[I]:=Updated[I];
  FComponentWaiting[I]:=False;
  BeginUIUpdate;
  try
    UpdateComponentList;
    if (FSelectedRow=I+1) or (Length(FRequestedComponents)>1) then ComponentSelected(nil);
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.ComponentsChecked(var Message: TMessage);
var Successful: Boolean; Releases: TComponentReleases; Error: string; Info: TProgramRelease;
begin
  Message.Result:=0;
  if not Assigned(FComponentThread) or (Message.WParam<>WPARAM(FComponentThread)) then Exit;
  FComponentThread.WaitFor; Successful:=FComponentThread.Successful;
  Releases:=FComponents;
  for var I:=Low(Releases) to High(Releases) do
  begin
    if FComponentThread.TryGetRelease(I,Info) then Releases[I]:=Info;
    FComponentWaiting[I]:=False;
  end;
  Error:=FComponentThread.ErrorText;
  FreeAndNil(FComponentThread);
  ComponentsReceived(Releases,Successful,Error);
end;

procedure TfrmProgramUpdate.ComponentsReceived(const Releases: TComponentReleases;
  Successful: Boolean; const Error: string);
var I, J, Errors: Integer; Updated: TComponentReleases;
begin
  BeginUIUpdate;
  try
  if Successful then
  begin
    FComponentError:='';
    Updated := Releases;
    PreserveComponentHistory(Updated, FComponents);
    FComponents := Updated;
    SaveComponentHistory(FCache, FComponents);
  end
  else
  begin
    FComponentError := 'Проверка компонентов не завершена. Повторите проверку.';
    FComponentErrorDetails := Copy(Error,1,4096);
  end;
  if not Successful then
    for I in CheckedComponentIndices do
    begin
      FComponents[I].DownloadURL:=''; FComponents[I].ComponentWarning:='';
      FComponents[I].ComponentError:=FComponentError;
      FComponents[I].ComponentErrorDetails:=FComponentErrorDetails;
    end;
  FComponentCheck.Enabled := True; UpdateComponentList;
  if FRequestedCheckPending and not FCheckingCycle then
  begin FRequestedCheckPending:=False; CheckComponents(False); Exit; end;
  if FCheckingCycle then
  begin FComponentsPending := False; FinishCheckCycle; Exit; end;
  if Assigned(FThread) or FReady then
  begin FComponentExplicit := False; Exit; end;
  if FRequestedComponent<>'' then
  begin
    for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID=FRequestedComponent then begin SelectRow(I+1); Break; end;
    ComponentSelected(nil); Present; FComponentExplicit:=False; Exit;
  end;
  if FComponentExplicit and not FComponentAutomatic and (FSelectedRow = 0) then
  begin
    Errors := 0; for I := 0 to High(FComponents) do
      if (FComponents[I].ComponentError <> '') or (FComponents[I].ComponentWarning<>'') then Inc(Errors);
    if Successful and (Errors > 0) then
      FStatus.Caption := ComponentCheckSummary
    else if Successful then FStatus.Caption := 'Компоненты проверены. Выберите компонент в списке, чтобы увидеть версию и изменения.'
    else FStatus.Caption := FComponentError;
    Present;
  end;
  FComponentExplicit := False;
  if (FSelectedRow > 0) and not FComponentAutomatic then
  begin ComponentSelected(nil); if not FComponentAutomatic then Present; end
  else if Successful and FComponentAutomatic and (FApplicationRelease.Tag = '') then
    for J := 0 to High(CheckedComponentIndices) do
    begin
      I := CheckedComponentIndices[J];
      if MayNotifyComponent(I) and ComponentNewer(FComponents[I], InstalledVersion(ComponentIDs[I])) and
         (FComponentNotified[I] <> FComponents[I].ComponentVersion) then
      begin
        FComponentNotified[I] := FComponents[I].ComponentVersion;
        SelectRow(I + 1); ComponentSelected(nil); Present; Break;
      end;
    end;
  UpdateSummary;
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.DisplayNotes(const Notes: string);
var Text: string;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted: UInt64;{$ENDIF}
begin
  Text := Notes;
  if FSelectedRow = 0 then
  begin
    if Text.Trim = '' then Text := FApplicationHistory;
    if Text.Trim <> '' then FApplicationHistory := Text;
  end;
  {$IFDEF MHL_RELEASE_PERFORMANCE}ProfileStarted:=GetTickCount64;{$ENDIF}
  FNotes.Load(Text);
  {$IFDEF MHL_RELEASE_PERFORMANCE}Inc(ProgramUpdateProfile.NotesMS,GetTickCount64-ProfileStarted);{$ENDIF}
end;

procedure TfrmProgramUpdate.RememberHistory(const ReleaseInfo: TProgramRelease);
begin
  if ReleaseInfo.History.Trim = '' then Exit;
  FApplicationHistory := ReleaseInfo.History;
  try
    AssertUpdatePath(FCache);
    WriteUpdateHistory(IncludeTrailingPathDelimiter(FCache) + 'notes.txt', Copy(ReleaseInfo.History, 1, 324000));
  except end;
end;

procedure TfrmProgramUpdate.BeginCheck;
begin
  BeginUIUpdate;
  try
  if (FSelectedRow > 0) and not FReady and not Assigned(FThread) then
  begin SelectRow(0); ComponentSelected(nil); end;
  if FSelectedRow > 0 then Exit;
  FStatus.Caption := 'Проверка обновлений на GitHub…';
  if not FReady then FNeedsCheck := True;
  if not Assigned(FThread) and not FReady then FPrimary.Enabled := False;
  Present;
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.SetCurrent(const ReleaseInfo: TProgramRelease);
begin
  BeginUIUpdate;
  try
  FApplicationRelease := Default(TProgramRelease);
  if ReleaseInfo.History.Trim <> '' then FApplicationHistory := ReleaseInfo.History;
  FApplicationStatus := 'Обновлений нет. У вас установлена последняя версия HomeLibre.';
  FApplicationVerified:=True; FApplicationFailed:=False;
  UpdateComponentList;
  if FSelectedRow > 0 then Exit;
  if Assigned(FThread) or FReady then Exit;
  FRelease := Default(TProgramRelease);
  FNeedsCheck := True;
  DisplayNotes(ReleaseInfo.History);
  FStatus.Caption := 'Обновлений нет. У вас установлена последняя версия HomeLibre.';
  FPrimary.Caption := 'Проверить ещё раз'; FPrimary.Enabled := True; FLater.Caption := 'Закрыть';
  Present;
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.CheckFailed(const Error: string);
begin
  FApplicationStatus := Error;
  FApplicationVerified:=False; FApplicationFailed:=True;
  UpdateComponentList;
  if FSelectedRow > 0 then Exit;
  FStatus.Caption := Error;
  if not Assigned(FThread) and not FReady then
  begin FNeedsCheck := True; FPrimary.Caption := 'Повторить проверку'; FPrimary.Enabled := True; end;
  LayoutWindow; Present;
end;

procedure TfrmProgramUpdate.PrimaryClick(Sender: TObject);
var ReleaseInfo: TProgramRelease; PreviousRepair: string;
begin
  if FReady then
  begin
    if FOperationComponent<>'' then
    begin
      try
        if (FRelease.ComponentID<>FOperationComponent) or FRecovery then
          raise Exception.Create('Подготовлен другой компонент. Повторите загрузку.');
        VerifyPreparedProgramUpdate(FJob,FRelease.Tag,ProgramUpdatePlatform);
        InstallProgramUpdate(FJob,Settings.AppPath);
        if ComponentNeedsRepair(Settings.AppPath,FOperationComponent) then
          raise Exception.Create('Не удалось подтвердить установленную библиотеку.');
        FReady:=False; DiscardJob; RefreshInstalledComponents;
        FCompactForm.ModalResult:=mrOk;
      except on E: Exception do
      begin FStatus.Caption:='Не удалось установить библиотеку: '+E.Message; LayoutWindow; end; end;
      Exit;
    end;
    if not FRecovery and (FRelease.ComponentID <> '') and
      (UpdateFileVersion(Settings.AppPath + 'HomeLibRuUpdater.exe') = '') then
    begin
      // The helper can disappear after a component was downloaded, or before
      // reopening its ready cache. Recheck for the verified application bundle
      // while the main process is still running; no installation has started.
      FReady := False; FNeedsCheck := True; FPendingInstall := False;
      DiscardJob; ClearQueueJobs; FRelease := Default(TProgramRelease);
      try TFile.Delete(IncludeTrailingPathDelimiter(FCache) + 'ready.json'); except end;
      FComponentCheck.Enabled := True; FBytes.Caption := '';
      ComponentCheckClick(nil);
      Exit;
    end;
    FPendingInstall := True;
    if Assigned(FRestart) then FRestart(Self);
    Exit;
  end;
  if Assigned(FThread) then Exit;
  if FCheckingCycle and ((FSelectedRow=0) or FNeedsCheck or
    FComponentWaiting[FSelectedRow-1]) then Exit;
  if FNeedsCheck then begin ComponentCheckClick(nil); Exit; end;
  if FRelease.CheckOnly and not FNeedsCheck then begin ComponentCheckClick(nil); Exit; end;
  PreviousRepair:=FRepairComponents; RefreshInstalledComponents;
  if (FRepairComponents<>'') and (FRepairComponents<>PreviousRepair) and
    (FApplicationRelease.Tag='') then
  begin FNeedsCheck:=True; ComponentCheckClick(nil); Exit; end;
  if Length(FRequestedComponents)>1 then FQueue:=RequestedReleases
  else if (FSelectedRow>0) and IsOptionalComponent(UPDATE_COMPONENTS[FSelectedRow-1].ID) and
    (FRelease.ComponentID=UPDATE_COMPONENTS[FSelectedRow-1].ID) then
    FQueue:=TArray<TProgramRelease>.Create(FRelease)
  else FQueue := AvailableUpdates;
  if (Length(FQueue) = 0) and not FNeedsCheck and (FRelease.Tag <> '') then
  begin SetLength(FQueue, 1); FQueue[0] := FRelease; end;
  if Length(FQueue) = 0 then
  begin
    ComponentCheckClick(nil);
    Exit;
  end;
  for ReleaseInfo in FQueue do
    if ReleaseInfo.DownloadURL = '' then begin PageClick(nil); Exit; end;
  FRequestedCheckPending:=False; // The requested component is already verified and chosen.
  DiscardJob; ClearQueueJobs; FQueueIndex := 0; FQueueBytes := 0; FQueueTotal := 0;
  for ReleaseInfo in FQueue do Inc(FQueueTotal, ReleaseInfo.Size);
  StartQueuedDownload;
end;

procedure TfrmProgramUpdate.StartQueuedDownload;
var ID: TGUID; Name: string;
begin
  CreateGUID(ID);
  FJob := IncludeTrailingPathDelimiter(FCache) + 'HomeLibRu-update-' +
    StringReplace(StringReplace(GUIDToString(ID), '{', '', []), '}', '', []);
  EnsureMessageWindow;
  FThread := CreateDownloadWorker(FMessageWindow, FQueue[FQueueIndex], FJob);
  // A verified application payload supplies missing unpackers, wrappers and
  // licences before any files in the installed application are changed.
  if (FQueueIndex>0) and (Length(FQueueJobs)>0) and (FQueue[0].ComponentID='') then
    FThread.RuntimePath:=IncludeTrailingPathDelimiter(FQueueJobs[0])+'payload';
  FComponentCheck.Enabled:=False;
  FPrimary.Enabled := False; FPrimary.Caption := 'Загрузка…';
  Name := FQueue[FQueueIndex].ComponentID; if Name = '' then Name := 'HomeLibre';
  FLater.Caption := 'Отменить'; FStatus.Caption := 'Загрузка ' + Name + '…';
  if FQueueTotal > 0 then FProgress.Position := Integer(FQueueBytes * 100 div FQueueTotal);
  FBytes.Caption := Format('Скачано: %s / %s', [ComponentDownloadSize(FQueueBytes),ComponentDownloadSize(FQueueTotal)]);
  LayoutWindow;
  FThread.Start;
end;

procedure TfrmProgramUpdate.ClearQueueJobs;
var Job: string;
begin
  for Job in FQueueJobs do try CleanProgramUpdate(Job); except end;
  FQueueJobs := nil;
end;

procedure TfrmProgramUpdate.LaterClick(Sender: TObject);
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate; FLater.Enabled := False;
    FStatus.Caption := 'Отмена загрузки…';
  end
  else Hide;
end;

procedure TfrmProgramUpdate.UpdateReleasePage;
begin
  FRelease.URL := UpdateReleasePageURL(FRelease.ComponentID, FRelease.Tag, FRelease.URL);
  FPage.Caption := UpdateReleasePageCaption(FRelease.ComponentID, FRelease.URL);
end;

procedure TfrmProgramUpdate.OpenReleasePage(const URL: string);
begin
  ShellExecute(Handle, 'open', PChar(URL), nil, nil, SW_SHOWNORMAL);
end;

procedure TfrmProgramUpdate.PageClick(Sender: TObject);
var Component, URL: string;
begin
  Component := FRelease.ComponentID; URL := FRelease.URL;
  // The selected component still has an author page when it has no update.
  if (FSelectedRow > 0) and (Component <> 'batch') then
  begin
    Component := UPDATE_COMPONENTS[FSelectedRow - 1].ID;
    if FRelease.ComponentID <> Component then URL := '';
  end;
  OpenReleasePage(UpdateReleasePageURL(Component, FRelease.Tag, URL));
end;

procedure TfrmProgramUpdate.DownloadProgress(var Message: TMessage);
var Name: string; Downloaded: Int64;
begin
  Message.Result := 0;
  if not Assigned(FThread) then Exit;
  Downloaded := FQueueBytes + Message.LParam;
  if FQueueTotal > 0 then FProgress.Position := Min(99, Integer(Downloaded * 100 div FQueueTotal));
  if Message.WParam >= 95 then FStatus.Caption := 'Проверка и подготовка обновления…'
  else
  begin
    Name := FQueue[FQueueIndex].ComponentID; if Name = '' then Name := 'HomeLibre';
    FStatus.Caption := 'Загрузка ' + Name + '…';
  end;
  FBytes.Caption := Format('Скачано: %s / %s', [ComponentDownloadSize(Downloaded),ComponentDownloadSize(FQueueTotal)]);
  SyncCompactPrompt;
end;

procedure TfrmProgramUpdate.DownloadCompleted(var Message: TMessage);
var Error, CombinedJob: string; ID: TGUID; Count: Integer;
begin
  Message.Result := 0;
  if not Assigned(FThread) then Exit;
  FThread.WaitFor; FReady := FThread.Successful; Error := FThread.ErrorText;
  if FReady then FQueue[FQueueIndex] := FThread.ReleaseInfo;
  FreeAndNil(FThread); FLater.Enabled := True; FLater.Caption := 'Позже';
  FComponentCheck.Enabled:=not FReady;
  FPrimary.Enabled := True;
  if FReady then
  begin
    Inc(FQueueBytes, FQueue[FQueueIndex].Size);
    Count := Length(FQueueJobs); SetLength(FQueueJobs, Count + 1); FQueueJobs[Count] := FJob;
    FJob := ''; Inc(FQueueIndex);
    if FQueueIndex < Length(FQueue) then
    begin FReady := False; StartQueuedDownload; Exit; end;
    FRelease := FQueue[0]; FRelease.Size := FQueueBytes;
    try
      if Length(FQueueJobs) = 1 then
      begin FJob := FQueueJobs[0]; FQueueJobs := nil; end
      else
      begin
        CreateGUID(ID); CombinedJob := IncludeTrailingPathDelimiter(FCache) + 'HomeLibRu-update-' +
          StringReplace(StringReplace(GUIDToString(ID), '{', '', []), '}', '', []);
        FJob := CombinedJob;
        FRelease.SHA256 := CombinePreparedProgramUpdates(FQueueJobs, FRelease.Tag, ProgramUpdatePlatform, CombinedJob);
        if FRelease.ComponentID <> '' then
        begin FRelease.ComponentID := 'batch'; FRelease.ComponentVersion := ''; end;
        ClearQueueJobs;
      end;
    except on E: Exception do begin FReady := False; Error := E.Message; end; end;
  end;
  if FReady and (FOperationComponent='') then
  begin
    try SaveReady;
    except on E: Exception do begin FReady := False; Error := E.Message; end; end;
  end;
  if FReady then
  begin
    UpdateReleasePage;
    FProgress.Position := 100; FPrimary.Caption := 'Установить и перезапустить';
    FBytes.Caption := Format('Скачано: %s / %s', [ComponentDownloadSize(FRelease.Size),ComponentDownloadSize(FRelease.Size)]);
    FStatus.Caption := 'Обновление скачано и проверено.' + sLineBreak +
      'Для установки HomeLibre закроется и запустится снова.';
    if FOperationComponent<>'' then
    begin
      FPrimary.Caption:='Установить библиотеку';
      FStatus.Caption:='Библиотека скачана и проверена. После установки выбранная операция продолжится без перезапуска.';
    end;
    Present;
  end
  else
  begin
    FComponentCheck.Enabled:=True;
    FPrimary.Caption := 'Повторить загрузку'; FStatus.Caption := Error;
    DiscardJob; ClearQueueJobs;
  end;
  LayoutWindow;
end;

procedure TfrmProgramUpdate.SaveReady;
var Root: TJSONObject;
begin
  ForceDirectories(FCache); Root := TJSONObject.Create;
  try
    Root.AddPair('job', FJob); Root.AddPair('tag', FRelease.Tag);
    Root.AddPair('sha256', FRelease.SHA256); Root.AddPair('url', FRelease.URL);
    if FRelease.History.Trim <> '' then Root.AddPair('notes', FRelease.History)
    else Root.AddPair('notes', FRelease.Changelog);
    Root.AddPair('component', FRelease.ComponentID); Root.AddPair('version', FRelease.ComponentVersion);
    Root.AddPair('size', TJSONNumber.Create(FRelease.Size));
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FCache) + 'ready.json', Root.ToJSON, TEncoding.UTF8);
  finally Root.Free; end;
end;

function TfrmProgramUpdate.RestoreReady: Boolean;
var Root, Journal: TJSONValue; FileName, Job, Tag, Digest, State, Notes, Component, Version, SavedURL: string; Comparison, I: Integer;
begin
  Result := False; FileName := IncludeTrailingPathDelimiter(FCache) + 'ready.json';
  if not FileExists(FileName) then Exit;
  Root := nil; Journal := nil;
  try
  try
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName, TEncoding.UTF8));
    if not (Root is TJSONObject) or
       not TJSONObject(Root).TryGetValue<string>('job', Job) or
       not TPath.GetFullPath(Job).StartsWith(IncludeTrailingPathDelimiter(FCache), True) or
       not ExtractFileName(Job).StartsWith('HomeLibRu-update-') or
       not TJSONObject(Root).TryGetValue<string>('tag', Tag) or
       not TJSONObject(Root).TryGetValue<string>('sha256', Digest) or not IsUpdateSHA256(Digest) then Exit;
    Component := ''; TJSONObject(Root).TryGetValue<string>('component', Component);
    Version := ''; TJSONObject(Root).TryGetValue<string>('version', Version);
    if Component = 'batch' then
    begin
      if not TRegEx.IsMatch(Tag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
      Comparison := 0; if PreparedComponentsNewer(Job, Settings.AppPath) then Comparison := 1;
    end
    else if Component = '' then
    begin
      if not CompareReleaseTags(Tag, PROGRAM_RELEASE_VERSION, Comparison) then Exit;
      RefreshInstalledComponents;
      if (Comparison=0) and (FRepairComponents<>'') then Comparison:=1;
    end
    else
    begin
      if (ComponentFileName(Component) = '') or not CompareComponentVersions(Version, Version, Comparison) or
         not TRegEx.IsMatch(Tag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
      if InstalledVersion(Component) = '' then Comparison := 1
      else if not CompareComponentVersions(Version, InstalledVersion(Component), Comparison) then Exit;
    end;
    AssertUpdatePath(Job);
    if (Component = '') and (Comparison <= 0) and PreparedComponentsNewer(Job, Settings.AppPath) then
      Comparison := 1;
    // Preserve interrupted transactions and offer to restore them explicitly.
    if FileExists(IncludeTrailingPathDelimiter(Job) + 'journal.json') then
    begin
      Journal := TJSONObject.ParseJSONValue(TFile.ReadAllText(IncludeTrailingPathDelimiter(Job) + 'journal.json', TEncoding.UTF8));
      if not (Journal is TJSONObject) or not TJSONObject(Journal).TryGetValue<string>('state', State) then Exit;
      if (State = 'installed') or (State = 'rolled-back') then
      begin CleanProgramUpdate(Job); TFile.Delete(FileName); Exit; end;
      FRecovery := True;
    end;
    if (Comparison <= 0) and not FRecovery then
    begin CleanProgramUpdate(Job); TFile.Delete(FileName); Exit; end;
    if not FRecovery and (not FileExists(IncludeTrailingPathDelimiter(Job) + 'manifest.json') or
       not SameText(UpdateSHA256(IncludeTrailingPathDelimiter(Job) + 'release.zip'), Digest)) then Exit;
    FJob := Job; FRelease.Tag := Tag; FRelease.SHA256 := Digest;
    FRelease.ComponentID := Component; FRelease.ComponentVersion := Version;
    SelectRow(0);
    for I := 0 to High(CheckedComponentIndices) do
      if Component = ComponentIDs[CheckedComponentIndices[I]] then SelectRow(CheckedComponentIndices[I] + 1);
    if Component = 'batch' then FVersion.Caption := 'Обновления компонентов HomeLibre'
    else if Component <> '' then
    begin
      FPage.Caption := 'Сайт автора';
      FVersion.Caption := 'Текущая версия ' + Component + ': ' +
        ComponentDisplayVersion(Component,InstalledVersion(Component));
    end;
    FComponentCheck.Enabled:=False;
    TJSONObject(Root).TryGetValue<Int64>('size', FRelease.Size);
    if FRelease.Size > 0 then
      FBytes.Caption := Format('Скачано: %s / %s', [ComponentDownloadSize(FRelease.Size),ComponentDownloadSize(FRelease.Size)]);
    SavedURL := ''; TJSONObject(Root).TryGetValue<string>('url', SavedURL);
    FRelease.URL := UpdateReleasePageURL(Component, Tag, SavedURL);
    UpdateReleasePage;
    FReady := True; FNeedsCheck := False; FProgress.Position := 100;
    if TJSONObject(Root).TryGetValue<string>('notes', Notes) then DisplayNotes(Notes);
    FStatus.Caption := 'Обновление ' + ReleaseTitle + ' готово к установке.' + sLineBreak +
      'Можно установить сейчас или продолжить работу.';
    FPrimary.Caption := 'Установить и перезапустить'; Result := True;
    if FRecovery then
    begin
      FStatus.Caption := 'Установка была прервана. Можно восстановить предыдущую версию и перезапустить HomeLibre.';
      FPrimary.Caption := 'Восстановить и перезапустить';
    end;
  except
    // Automatic startup remains quiet if a cached download was removed.
  end;
  finally Journal.Free; Root.Free; end;
  LayoutWindow;
end;

function TfrmProgramUpdate.InstallationHelperSource: string;
begin
  // Application packages carry the matching installer implementation. An older
  // installed helper must not retain the bug that this application fixes.
  if FRelease.ComponentID = '' then
    Exit(PreparedProgramUpdateHelper(FJob,FRelease.Tag,ProgramUpdatePlatform,FRelease.SHA256));
  Result := Settings.AppPath + 'HomeLibRuUpdater.exe';
  if UpdateFileVersion(Result) = '' then
    raise Exception.Create('Не найден механизм обновления. Выполните проверку и восстановление HomeLibre.');
end;

function TfrmProgramUpdate.LaunchInstallation: Boolean;
var Root: TJSONObject; Helper, Parameters, SourceHelper: string; Code: HINST;
  I: Integer; Args: TJSONArray;
begin
  Result := False;
  try
    if not IsProgramUpdateApplicationName(ExtractFileName(ParamStr(0))) then
      raise Exception.Create('Файл программы переименован: '+ExtractFileName(ParamStr(0))+'. '+
        'Для встроенного обновления верните имя HomeLibRu.exe или HomeLibReader.exe.');
    AssertUpdatePath(FJob); AssertUpdatePath(Settings.AppPath);
    Helper := IncludeTrailingPathDelimiter(FJob) + 'HomeLibRuUpdater.exe';
    if not FRecovery or not FileExists(Helper) then
    begin
      SourceHelper := InstallationHelperSource;
      if not Winapi.Windows.CopyFile(PChar(SourceHelper),PChar(Helper),False) then RaiseLastOSError;
    end;
    Root := TJSONObject.Create;
    try
      Root.AddPair('target', ExcludeTrailingPathDelimiter(Settings.AppPath));
      Root.AddPair('application', ExtractFileName(ParamStr(0)));
      Root.AddPair('pid', TJSONNumber.Create(GetCurrentProcessId));
      Root.AddPair('tag', FRelease.Tag); Root.AddPair('sha256', FRelease.SHA256);
      Root.AddPair('commandLine', string(GetCommandLine));
      Root.AddPair('recover', TJSONBool.Create(FRecovery));
      Args := TJSONArray.Create;
      for I := 1 to ParamCount do Args.Add(ParamStr(I));
      Root.AddPair('args', Args);
      TFile.WriteAllText(IncludeTrailingPathDelimiter(FJob) + 'request.json', Root.ToJSON, TEncoding.UTF8);
    finally Root.Free; end;
    Parameters := '--job "' + FJob + '"';
    ArmBookSaveContinuation(Settings.SettingsFileName,FRequestedComponent);
    Code := ShellExecute(Handle, 'open', PChar(Helper), PChar(Parameters), PChar(FJob), SW_HIDE);
    if NativeInt(Code) <= 32 then raise Exception.Create('Не удалось запустить механизм обновления.');
    Result := True;
  except
    on E: Exception do
    begin
      FStatus.Caption := 'Не удалось начать установку: ' + E.Message;
      DisarmBookSaveContinuation(Settings.SettingsFileName);
      FPendingInstall := False; Present;
    end;
  end;
end;

function TfrmProgramUpdate.WillInstallComponent(const ID: string): Boolean;
begin
  Result:=FPendingInstall and FReady and not FRecovery and
    (PreparedIncludesComponent(FJob,ID) or ((ID='BookConverter') and PreparedIncludesComponent(FJob,'BookProcessing')));
end;

procedure TfrmProgramUpdate.CancelInstallation;
begin FPendingInstall := False; end;

end.
