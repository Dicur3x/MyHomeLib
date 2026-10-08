unit frm_ProgramUpdate;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls,
  Winapi.Windows, Winapi.Messages, unit_ProgramUpdates, unit_ComponentUpdates, unit_UpdateNotes;

type
  TfrmProgramUpdate = class(TForm)
  private
    FStatus, FVersion, FBytes: TLabel;
    FNotes: TUpdateNotesView;
    FProgress: TProgressBar;
    FPrimary, FLater, FPage: TButton;
    FZoomOut, FZoomReset, FZoomIn: TButton;
    FUIUpdateCount, FNormalWidth, FNormalHeight: Integer;
    FUIRedraw, FPresentPending: Boolean;
    FThread: TProgramDownloadThread;
    FComponentThread: TComponentUpdateThread;
    FComponents: TComponentReleases;
    FSelector: TComboBox;
    FComponentCheck: TButton;
    FComponentAutomatic: Boolean;
    FComponentExplicit: Boolean;
    FComponentError: string;
    FComponentNotified: array[0..2] of string;
    FApplicationRelease: TProgramRelease;
    FApplicationStatus, FApplicationHistory: string;
    FCheckingCycle, FAppPending, FComponentsPending, FCycleAutomatic: Boolean;
    FQueue: TArray<TProgramRelease>;
    FQueueJobs: TArray<string>;
    FQueueIndex: Integer;
    FQueueBytes, FQueueTotal: Int64;
    FRelease: TProgramRelease;
    FJob, FCache: string;
    FReady, FPendingInstall, FNeedsCheck, FRecovery: Boolean;
    FRestart, FCheck: TNotifyEvent;
    procedure PrimaryClick(Sender: TObject);
    procedure LaterClick(Sender: TObject);
    procedure PageClick(Sender: TObject);
    procedure DownloadCompleted(var Message: TMessage); message WM_PROGRAM_UPDATE_DOWNLOADED;
    procedure DownloadProgress(var Message: TMessage); message WM_PROGRAM_UPDATE_PROGRESS;
    procedure SaveReady;
    procedure DiscardJob;
    procedure DisplayNotes(const Notes: string);
    procedure ComponentSelected(Sender: TObject);
    procedure ComponentCheckClick(Sender: TObject);
    procedure ComponentsChecked(var Message: TMessage); message WM_COMPONENT_UPDATE_CHECKED;
    procedure UpdateComponentList;
    function ReleaseTitle: string;
    procedure BeginUIUpdate;
    procedure EndUIUpdate;
    procedure Present;
    procedure LayoutWindow;
    procedure ZoomClick(Sender: TObject);
    procedure ZoomChanged(Sender: TObject);
    procedure LoadViewPreferences;
    procedure SaveViewPreferences;
    function AvailableUpdates: TArray<TProgramRelease>;
    function AvailableSummary: string;
    procedure UpdateSummary;
    procedure FinishCheckCycle;
    procedure StartQueuedDownload;
    procedure ClearQueueJobs;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetRelease(const ReleaseInfo: TProgramRelease);
    procedure BeginCheck;
    procedure SetCurrent(const ReleaseInfo: TProgramRelease);
    procedure CheckFailed(const Error: string);
    procedure RememberHistory(const ReleaseInfo: TProgramRelease);
    procedure CheckComponents(Automatic: Boolean);
    function StartCheckCycle(Automatic: Boolean): Boolean;
    procedure ApplicationChecked(const ReleaseInfo: TProgramRelease; Successful: Boolean; const Error: string);
    procedure ComponentsReceived(const Releases: TComponentReleases; Successful: Boolean; const Error: string);
    function RestoreReady: Boolean;
    function LaunchInstallation: Boolean;
    procedure CancelInstallation;
    property PendingInstall: Boolean read FPendingInstall;
    property OnCheck: TNotifyEvent read FCheck write FCheck;
    property OnRestart: TNotifyEvent read FRestart write FRestart;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.JSON, System.RegularExpressions, System.Math,
  System.Types, Winapi.ShellAPI,
  Vcl.Controls, Vcl.Graphics, dm_user, unit_Settings, unit_Globals,
  unit_ProgramUpdateInstaller, unit_MHLHttpClient, unit_UpdateTextCache;

constructor TfrmProgramUpdate.Create(AOwner: TComponent);
var HistoryFile: string;
begin
  inherited CreateNew(AOwner);
  Caption := 'Обновление HomeLib Ru'; BorderStyle := bsSizeable;
  BorderIcons := [biSystemMenu, biMinimize, biMaximize];
  Position := poMainFormCenter; ClientWidth := 860; ClientHeight := 640;
  Constraints.MinWidth := 660; Constraints.MinHeight := 440;
  DoubleBuffered := True;
  Font.Name := 'Segoe UI'; Font.Size := 9;
  FVersion := TLabel.Create(Self); FVersion.Parent := Self;
  FVersion.SetBounds(20, 16, 700, 20); FVersion.Font.Style := [fsBold];
  FVersion.Caption := 'Текущая версия: ' + PROGRAM_RELEASE_VERSION;
  FStatus := TLabel.Create(Self); FStatus.Parent := Self; FStatus.Name := 'UpdateStatus';
  FSelector := TComboBox.Create(Self); FSelector.Parent := Self;
  FSelector.Style := csDropDownList; FSelector.SetBounds(20, 48, 465, 25);
  FSelector.OnChange := ComponentSelected;
  HistoryFile := Settings.AppPath + 'COMPONENTS.json';
  try
    if FileExists(HistoryFile) then
      ParseComponentFeed(TFile.ReadAllText(HistoryFile, TEncoding.UTF8), PROGRAM_RELEASE_VERSION, '[]', FComponents, False);
  except end;
  FComponentCheck := TButton.Create(Self); FComponentCheck.Parent := Self;
  FComponentCheck.SetBounds(500, 47, 220, 27); FComponentCheck.Caption := 'Проверить компоненты';
  FComponentCheck.OnClick := ComponentCheckClick;
  UpdateComponentList; FSelector.ItemIndex := 0;
  FStatus.SetBounds(20, 88, 700, 60); FStatus.AutoSize := False; FStatus.WordWrap := True;
  FNotes := TUpdateNotesView.Create(Self); FNotes.Parent := Self;
  FNotes.SetBounds(20, 155, 700, 238);
  FBytes := TLabel.Create(Self); FBytes.Parent := Self;
  FBytes.SetBounds(20, 430, 700, 18);
  FProgress := TProgressBar.Create(Self); FProgress.Parent := Self;
  FProgress.SetBounds(20, 404, 700, 18); FProgress.Max := 100;
  FPrimary := TButton.Create(Self); FPrimary.Parent := Self;
  FPrimary.SetBounds(20, 473, 420, 30); FPrimary.OnClick := PrimaryClick; FPrimary.Default := True;
  FPage := TButton.Create(Self); FPage.Parent := Self;
  FPage.SetBounds(460, 473, 125, 30); FPage.Caption := 'Открыть GitHub'; FPage.OnClick := PageClick;
  FLater := TButton.Create(Self); FLater.Parent := Self;
  FLater.SetBounds(605, 473, 115, 30); FLater.Caption := 'Позже'; FLater.OnClick := LaterClick;
  FCache := ProgramUpdateCache(Settings.AppPath);
  LoadComponentHistory(FCache, FComponents);
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
    else if FileExists(Settings.AppPath + 'CHANGES.txt') then
      DisplayNotes(Copy(TFile.ReadAllText(Settings.AppPath + 'CHANGES.txt', TEncoding.UTF8), 1, 324000))
    else DisplayNotes('');
  except end;
  LoadViewPreferences;
  ScaleForPPI(Screen.PixelsPerInch);
  LayoutWindow;
end;

destructor TfrmProgramUpdate.Destroy;
begin
  SaveViewPreferences;
  if Assigned(FComponentThread) then
  begin FComponentThread.Terminate; FreeAndNil(FComponentThread); end;
  if Assigned(FThread) then
  begin FThread.Terminate; FreeAndNil(FThread); end;
  // Keep a verified ready update when installation is postponed or the app exits.
  if not FReady then DiscardJob;
  ClearQueueJobs;
  inherited;
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
  if FUIUpdateCount > 0 then begin FPresentPending := True; Exit; end;
  if not Visible then Show;
  BringToFront;
end;

procedure TfrmProgramUpdate.Resize;
begin
  inherited;
  if Assigned(FZoomIn) and (FUIUpdateCount = 0) then LayoutWindow;
end;

procedure TfrmProgramUpdate.LayoutWindow;
var Margin, Gap, Width, ButtonTop, NotesTop, NotesBottom, StatusHeight: Integer;
  Bounds: TRect;
  function S(Value: Integer): Integer;
  begin Result := MulDiv(Value, CurrentPPI, 96); end;
begin
  if not Assigned(FZoomIn) then Exit;
  DisableAlign;
  try
    Margin := S(12); Gap := S(8); Width := ClientWidth - 2 * Margin;
    FVersion.SetBounds(Margin, S(12), Width - S(160), S(22));
    FZoomOut.SetBounds(ClientWidth - Margin - S(150), S(8), S(40), S(26));
    FZoomReset.SetBounds(ClientWidth - Margin - S(105), S(8), S(60), S(26));
    FZoomIn.SetBounds(ClientWidth - Margin - S(40), S(8), S(40), S(26));
    FSelector.SetBounds(Margin, S(42), Width - S(220) - Gap, S(25));
    FComponentCheck.SetBounds(ClientWidth - Margin - S(220), S(41), S(220), S(27));
    Canvas.Font.Assign(Font); Bounds := Rect(0, 0, Width, 0);
    DrawText(Canvas.Handle, PChar(FStatus.Caption), Length(FStatus.Caption), Bounds,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    StatusHeight := EnsureRange(Bounds.Height + S(4), S(22), S(70));
    FStatus.SetBounds(Margin, S(76), Width, StatusHeight);
    ButtonTop := ClientHeight - Margin - S(30);
    FPrimary.SetBounds(Margin, ButtonTop, Width - S(125 + 115) - 2 * Gap, S(30));
    FPage.SetBounds(ClientWidth - Margin - S(125 + 115) - Gap, ButtonTop, S(125), S(30));
    FLater.SetBounds(ClientWidth - Margin - S(115), ButtonTop, S(115), S(30));
    FProgress.Visible := Assigned(FThread) or FReady or (FBytes.Caption <> '');
    FBytes.Visible := FProgress.Visible;
    FProgress.SetBounds(Margin, ButtonTop - S(52), Width, S(18));
    FBytes.SetBounds(Margin, ButtonTop - S(28), Width, S(20));
    NotesTop := FStatus.Top + StatusHeight + Gap;
    NotesBottom := ButtonTop - Gap;
    if FProgress.Visible then NotesBottom := FProgress.Top - Gap;
    FNotes.SetBounds(Margin, NotesTop, Width, Max(S(100), NotesBottom - NotesTop));
    if WindowState = wsNormal then
    begin
      FNormalWidth := MulDiv(ClientWidth, 96, CurrentPPI);
      FNormalHeight := MulDiv(ClientHeight, 96, CurrentPPI);
    end;
  finally EnableAlign; end;
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
var Root: TJSONValue; Width, Height, Zoom: Integer; Maximized: Boolean;
begin
  Root := TJSONObject.ParseJSONValue(ReadUpdateHistory(IncludeTrailingPathDelimiter(FCache) + 'view.json', 4096));
  try
    if not (Root is TJSONObject) then Exit;
    if TJSONObject(Root).TryGetValue<Integer>('width', Width) then
      ClientWidth := EnsureRange(Width, 660, Max(660, MulDiv(Screen.WorkAreaWidth - 40, 96, Screen.PixelsPerInch)));
    if TJSONObject(Root).TryGetValue<Integer>('height', Height) then
      ClientHeight := EnsureRange(Height, 400, Max(400, MulDiv(Screen.WorkAreaHeight - 70, 96, Screen.PixelsPerInch)));
    if TJSONObject(Root).TryGetValue<Integer>('zoom', Zoom) then FNotes.ZoomPercent := Zoom;
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
begin
  BeginUIUpdate;
  try
  if ReleaseInfo.ComponentID = '' then FApplicationRelease := ReleaseInfo;
  if FRecovery or Assigned(FThread) or FReady then
  begin Present; Exit; end;
  if ReleaseInfo.ComponentID = '' then
  begin FSelector.ItemIndex := 0; FVersion.Caption := 'Текущая версия: ' + PROGRAM_RELEASE_VERSION; end;
  FReady := False; FNeedsCheck := False; FRecovery := False; DiscardJob; FRelease := ReleaseInfo;
  FLater.Caption := 'Позже'; FLater.Enabled := True;
  if FRelease.History.Trim <> '' then DisplayNotes(FRelease.History)
  else DisplayNotes(FRelease.Changelog);
  FStatus.Caption := 'Доступно обновление ' + ReleaseTitle + '.' + sLineBreak +
    'Настройки, коллекции и история чтения сохранятся.';
  FProgress.Position := 0; FBytes.Caption := '';
  FPrimary.Caption := 'Скачать обновление'; FPrimary.Enabled := True;
  if FRelease.DownloadURL = '' then FPrimary.Caption := 'Скачать со страницы выпуска';
  UpdateSummary;
  Present;
  finally EndUIUpdate; end;
end;

function TfrmProgramUpdate.ReleaseTitle: string;
begin
  if FRelease.ComponentID = 'batch' then Exit('компонентов HomeLib Ru');
  if FRelease.ComponentID = '' then Result := ReleaseNotesHeading('HomeLib Ru ' + FRelease.Tag, FRelease.PublishedAt)
  else Result := ReleaseNotesHeading(FRelease.ComponentID + ' ' + FRelease.ComponentVersion, FRelease.PublishedAt);
end;

procedure TfrmProgramUpdate.UpdateComponentList;
var I, Index: Integer; Text, Version: string;
begin
  Index := FSelector.ItemIndex;
  FSelector.Items.BeginUpdate;
  try
    FSelector.Items.Clear; FSelector.Items.Add('HomeLib Ru');
    for I in CHECKED_COMPONENT_INDICES do
    begin
      Version := ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[I]);
      if Version = '' then Version := 'не установлен';
      Text := COMPONENT_IDS[I] + ': ' + Version;
      if FComponents[I].ComponentError <> '' then Text := Text + ' — проверка не удалась'
      else if (FComponents[I].DownloadURL <> '') and (FComponents[I].ComponentVersion <> '') then
        if ComponentNewer(FComponents[I], ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[I])) then
          Text := Text + ' → ' + FComponents[I].ComponentVersion
        else Text := Text + ' — обновлений нет';
      FSelector.Items.Add(Text);
    end;
    if Index < 0 then Index := 0; FSelector.ItemIndex := Index;
  finally FSelector.Items.EndUpdate; end;
end;

procedure TfrmProgramUpdate.ComponentSelected(Sender: TObject);
var I: Integer; Version: string;
begin
  if Assigned(FThread) or FReady then Exit;
  BeginUIUpdate;
  try
  I := FSelector.ItemIndex - 1;
  if I < 0 then
  begin
    FPage.Caption := 'Открыть GitHub';
    FVersion.Caption := 'Текущая версия: ' + PROGRAM_RELEASE_VERSION;
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
  I := CHECKED_COMPONENT_INDICES[I];
  Version := ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[I]);
  FPage.Caption := 'Сайт автора';
  FVersion.Caption := 'Текущая версия ' + COMPONENT_IDS[I] + ': ' + Version;
  if Version = '' then FVersion.Caption := 'Компонент ' + COMPONENT_IDS[I] + ' не установлен';
  if ComponentNewer(FComponents[I], Version) then
  begin
    FComponents[I].Changelog := ComponentChanges(FComponents[I], Version);
    SetRelease(FComponents[I]);
  end
  else
  begin
    FRelease := Default(TProgramRelease); FNeedsCheck := True;
    FProgress.Position := 0; FBytes.Caption := ''; FPrimary.Enabled := not Assigned(FComponentThread);
    FPrimary.Caption := 'Проверить компонент';
    DisplayNotes(FComponents[I].History);
    FStatus.Caption := 'Источник: официальный сайт автора компонента.' + sLineBreak;
    if FComponents[I].ComponentError <> '' then FStatus.Caption := FStatus.Caption + FComponents[I].ComponentError
    else if FComponentError <> '' then FStatus.Caption := FStatus.Caption + FComponentError
    else if FComponents[I].DownloadURL <> '' then
      FStatus.Caption := FStatus.Caption + 'Обновлений нет. Установлена актуальная версия.'
    else FStatus.Caption := FStatus.Caption + 'Нажмите «Проверить компонент», чтобы узнать о новой версии.';
  end;
  UpdateSummary;
  finally EndUIUpdate; end;
end;

function TfrmProgramUpdate.AvailableUpdates: TArray<TProgramRelease>;
var I, Count: Integer;
begin
  Result := nil;
  if FApplicationRelease.Tag <> '' then
  begin SetLength(Result, 1); Result[0] := FApplicationRelease; end;
  for I in CHECKED_COMPONENT_INDICES do
    if ComponentNewer(FComponents[I], ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[I])) then
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
    Name := Releases[I].ComponentID; if Name = '' then Name := 'HomeLib Ru';
    if I > 0 then
      if I = High(Releases) then Result := Result + ' и ' else Result := Result + ', ';
    Result := Result + Name;
  end;
  if Result <> '' then Result := 'Есть обновления для ' + Result;
end;

procedure TfrmProgramUpdate.UpdateSummary;
var Summary: string;
begin
  if FReady or Assigned(FThread) then Exit;
  Summary := AvailableSummary;
  if Summary <> '' then
  begin
    FStatus.Caption := Summary; FNeedsCheck := False;
    if Length(AvailableUpdates) > 1 then FPrimary.Caption := 'Скачать все обновления'
    else FPrimary.Caption := 'Скачать обновление';
    FPrimary.Enabled := not FCheckingCycle;
  end;
end;

function TfrmProgramUpdate.StartCheckCycle(Automatic: Boolean): Boolean;
var I: Integer;
begin
  Result := False;
  if FCheckingCycle or Assigned(FThread) then Exit;
  if FReady then begin if not Automatic then Present; Exit; end;
  FCycleAutomatic := Automatic; FCheckingCycle := True; FAppPending := True; FComponentsPending := True;
  FApplicationRelease := Default(TProgramRelease);
  for I in CHECKED_COMPONENT_INDICES do FComponents[I].DownloadURL := '';
  if not Automatic then BeginCheck;
  Result := True;
end;

procedure TfrmProgramUpdate.ApplicationChecked(const ReleaseInfo: TProgramRelease;
  Successful: Boolean; const Error: string);
var Comparison: Integer;
begin
  if not FCheckingCycle then Exit;
  FAppPending := False;
  if Successful then
  begin
    RememberHistory(ReleaseInfo);
    FApplicationStatus := 'Обновлений нет. У вас установлена последняя версия HomeLib Ru.';
    if CompareReleaseTags(ReleaseInfo.Tag, PROGRAM_RELEASE_VERSION, Comparison) and (Comparison > 0) then
      FApplicationRelease := ReleaseInfo;
  end
  else FApplicationStatus := Error;
  FinishCheckCycle;
end;

procedure TfrmProgramUpdate.FinishCheckCycle;
var J: Integer;
begin
  if not FCheckingCycle or FAppPending or FComponentsPending then Exit;
  FCheckingCycle := False;
  UpdateComponentList;
  if Length(AvailableUpdates) > 0 then
  begin
    FSelector.ItemIndex := 0;
    if FApplicationRelease.Tag = '' then
      for J := 0 to High(CHECKED_COMPONENT_INDICES) do
        if ComponentNewer(FComponents[CHECKED_COMPONENT_INDICES[J]],
          ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[CHECKED_COMPONENT_INDICES[J]])) then
        begin FSelector.ItemIndex := J + 1; Break; end;
    ComponentSelected(nil); UpdateSummary; Present;
  end
  else if not FCycleAutomatic then
  begin
    FSelector.ItemIndex := 0; ComponentSelected(nil); FStatus.Caption := FApplicationStatus;
    if FComponentError <> '' then FStatus.Caption := FStatus.Caption + ' ' + FComponentError
    else for J in CHECKED_COMPONENT_INDICES do
      if FComponents[J].ComponentError <> '' then
        FStatus.Caption := FStatus.Caption + ' Не удалось проверить ' + COMPONENT_IDS[J] + '.';
    FPrimary.Enabled := True; FPrimary.Caption := 'Проверить ещё раз'; Present;
  end;
end;

procedure TfrmProgramUpdate.ComponentCheckClick(Sender: TObject);
begin FComponentExplicit := True; CheckComponents(False); end;

procedure TfrmProgramUpdate.CheckComponents(Automatic: Boolean);
begin
  if Assigned(FComponentThread) then Exit;
  FComponentAutomatic := Automatic; FComponentError := '';
  FComponentThread := TComponentUpdateThread.Create(Handle, CreateHTTPClientGlobal,
    PROGRAM_RELEASES_API, FCache);
  FComponentCheck.Enabled := False;
  if (FSelector.ItemIndex > 0) and not Assigned(FThread) and not FReady then
  begin
    FStatus.Caption := 'Проверка обновлений компонентов у авторов…'; FPrimary.Enabled := False;
  end;
  FComponentThread.Start;
end;

procedure TfrmProgramUpdate.ComponentsChecked(var Message: TMessage);
var Successful: Boolean; Releases: TComponentReleases; Error: string;
begin
  Message.Result := 0; if not Assigned(FComponentThread) then Exit;
  FComponentThread.WaitFor; Successful := FComponentThread.Successful;
  Releases := FComponentThread.Releases; Error := FComponentThread.ErrorText;
  FreeAndNil(FComponentThread);
  ComponentsReceived(Releases, Successful, Error);
end;

procedure TfrmProgramUpdate.ComponentsReceived(const Releases: TComponentReleases;
  Successful: Boolean; const Error: string);
var I, J, Errors: Integer; Updated: TComponentReleases;
begin
  BeginUIUpdate;
  try
  if Successful then
  begin
    Updated := Releases;
    PreserveComponentHistory(Updated, FComponents);
    FComponents := Updated;
    SaveComponentHistory(FCache, FComponents);
  end
  else FComponentError := Error;
  FComponentCheck.Enabled := True; UpdateComponentList;
  if FCheckingCycle then
  begin FComponentsPending := False; FinishCheckCycle; Exit; end;
  if Assigned(FThread) or FReady then
  begin FComponentExplicit := False; Exit; end;
  if FComponentExplicit and not FComponentAutomatic and (FSelector.ItemIndex = 0) then
  begin
    Errors := 0; for I := 0 to 2 do if FComponents[I].ComponentError <> '' then Inc(Errors);
    if Successful and (Errors > 0) then
      FStatus.Caption := 'Некоторые компоненты не удалось проверить. Выберите их в списке, чтобы увидеть подробности.'
    else if Successful then FStatus.Caption := 'Компоненты проверены. Выберите компонент в списке, чтобы увидеть версию и изменения.'
    else FStatus.Caption := FComponentError;
    Present;
  end;
  FComponentExplicit := False;
  if (FSelector.ItemIndex > 0) and not FComponentAutomatic then
  begin ComponentSelected(nil); if not FComponentAutomatic then Present; end
  else if Successful and FComponentAutomatic and (FApplicationRelease.Tag = '') then
    for J := 0 to High(CHECKED_COMPONENT_INDICES) do
    begin
      I := CHECKED_COMPONENT_INDICES[J];
      if ComponentNewer(FComponents[I], ComponentInstalledVersion(Settings.AppPath, COMPONENT_IDS[I])) and
         (FComponentNotified[I] <> FComponents[I].ComponentVersion) then
      begin
        FComponentNotified[I] := FComponents[I].ComponentVersion;
        FSelector.ItemIndex := J + 1; ComponentSelected(nil); Break;
      end;
    end;
  UpdateSummary;
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.DisplayNotes(const Notes: string);
var Text: string;
begin
  Text := Notes;
  if FSelector.ItemIndex = 0 then
  begin
    if Text.Trim = '' then Text := FApplicationHistory;
    if Text.Trim <> '' then FApplicationHistory := Text;
  end;
  FNotes.Load(Text);
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
  if (FSelector.ItemIndex > 0) and not FReady and not Assigned(FThread) then
  begin FSelector.ItemIndex := 0; ComponentSelected(nil); end;
  if FSelector.ItemIndex > 0 then Exit;
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
  FApplicationStatus := 'Обновлений нет. У вас установлена последняя версия HomeLib Ru.';
  if FSelector.ItemIndex > 0 then Exit;
  if Assigned(FThread) or FReady then Exit;
  FRelease := Default(TProgramRelease);
  FNeedsCheck := True;
  DisplayNotes(ReleaseInfo.History);
  FStatus.Caption := 'Обновлений нет. У вас установлена последняя версия HomeLib Ru.';
  FPrimary.Caption := 'Проверить ещё раз'; FPrimary.Enabled := True; FLater.Caption := 'Закрыть';
  Present;
  finally EndUIUpdate; end;
end;

procedure TfrmProgramUpdate.CheckFailed(const Error: string);
begin
  FApplicationStatus := Error;
  if FSelector.ItemIndex > 0 then Exit;
  FStatus.Caption := Error;
  if not Assigned(FThread) and not FReady then
  begin FNeedsCheck := True; FPrimary.Caption := 'Повторить проверку'; FPrimary.Enabled := True; end;
  LayoutWindow; Present;
end;

procedure TfrmProgramUpdate.PrimaryClick(Sender: TObject);
var ReleaseInfo: TProgramRelease;
begin
  if FReady then
  begin
    FPendingInstall := True;
    if Assigned(FRestart) then FRestart(Self);
    Exit;
  end;
  if Assigned(FThread) then Exit;
  if FCheckingCycle then Exit;
  FQueue := AvailableUpdates;
  if (Length(FQueue) = 0) and not FNeedsCheck and (FRelease.Tag <> '') then
  begin SetLength(FQueue, 1); FQueue[0] := FRelease; end;
  if Length(FQueue) = 0 then
  begin
    if FSelector.ItemIndex > 0 then CheckComponents(False)
    else if Assigned(FCheck) then FCheck(Self);
    Exit;
  end;
  for ReleaseInfo in FQueue do
    if ReleaseInfo.DownloadURL = '' then begin PageClick(nil); Exit; end;
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
  FThread := TProgramDownloadThread.Create(Handle, CreateHTTPClientGlobal, FQueue[FQueueIndex], FJob);
  FSelector.Enabled := False;
  FPrimary.Enabled := False; FPrimary.Caption := 'Загрузка…';
  Name := FQueue[FQueueIndex].ComponentID; if Name = '' then Name := 'HomeLib Ru';
  FLater.Caption := 'Отменить'; FStatus.Caption := 'Загрузка ' + Name + '…';
  if FQueueTotal > 0 then FProgress.Position := Integer(FQueueBytes * 100 div FQueueTotal);
  FBytes.Caption := Format('Скачано: %.1f / %.1f МБ', [FQueueBytes / 1048576, FQueueTotal / 1048576]);
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

procedure TfrmProgramUpdate.PageClick(Sender: TObject);
begin
  if FSelector.ItemIndex = 1 then FRelease.URL := 'https://www.sqlite.org/changes.html';
  if FSelector.ItemIndex = 2 then FRelease.URL := 'https://www.sumatrapdfreader.org/docs/Version-history';
  if FRelease.URL = '' then FRelease.URL := 'https://github.com/Dicur3x/MyHomeLib/releases';
  ShellExecute(Handle, 'open', PChar(FRelease.URL), nil, nil, SW_SHOWNORMAL);
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
    Name := FQueue[FQueueIndex].ComponentID; if Name = '' then Name := 'HomeLib Ru';
    FStatus.Caption := 'Загрузка ' + Name + '…';
  end;
  FBytes.Caption := Format('Скачано: %.1f / %.1f МБ', [Downloaded / 1048576, FQueueTotal / 1048576]);
end;

procedure TfrmProgramUpdate.DownloadCompleted(var Message: TMessage);
var Error, CombinedJob: string; ID: TGUID; Count: Integer;
begin
  Message.Result := 0;
  if not Assigned(FThread) then Exit;
  FThread.WaitFor; FReady := FThread.Successful; Error := FThread.ErrorText;
  if FReady then FQueue[FQueueIndex] := FThread.ReleaseInfo;
  FreeAndNil(FThread); FLater.Enabled := True; FLater.Caption := 'Позже';
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
  if FReady then
  begin
    try SaveReady;
    except on E: Exception do begin FReady := False; Error := E.Message; end; end;
  end;
  if FReady then
  begin
    FProgress.Position := 100; FPrimary.Caption := 'Установить и перезапустить';
    FBytes.Caption := Format('Скачано: %.1f / %.1f МБ', [FRelease.Size / 1048576, FRelease.Size / 1048576]);
    FStatus.Caption := 'Обновление скачано и проверено.' + sLineBreak +
      'Для установки HomeLib Ru закроется и запустится снова.';
    Present;
  end
  else
  begin
    FSelector.Enabled := True;
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
var Root, Journal: TJSONValue; FileName, Job, Tag, Digest, State, Notes, Component, Version: string; Comparison, I: Integer;
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
    begin if not CompareReleaseTags(Tag, PROGRAM_RELEASE_VERSION, Comparison) then Exit; end
    else
    begin
      if (ComponentFileName(Component) = '') or not CompareComponentVersions(Version, Version, Comparison) or
         not TRegEx.IsMatch(Tag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
      if ComponentInstalledVersion(Settings.AppPath, Component) = '' then Comparison := 1
      else if not CompareComponentVersions(Version, ComponentInstalledVersion(Settings.AppPath, Component), Comparison) then Exit;
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
    FSelector.ItemIndex := 0;
    for I := 0 to High(CHECKED_COMPONENT_INDICES) do
      if Component = COMPONENT_IDS[CHECKED_COMPONENT_INDICES[I]] then FSelector.ItemIndex := I + 1;
    if Component = 'batch' then FVersion.Caption := 'Обновления компонентов HomeLib Ru'
    else if Component <> '' then
    begin
      FPage.Caption := 'Сайт автора';
      FVersion.Caption := 'Текущая версия ' + Component + ': ' +
        ComponentInstalledVersion(Settings.AppPath, Component);
    end;
    FSelector.Enabled := False;
    TJSONObject(Root).TryGetValue<Int64>('size', FRelease.Size);
    if FRelease.Size > 0 then
      FBytes.Caption := Format('Скачано: %.1f / %.1f МБ', [FRelease.Size / 1048576, FRelease.Size / 1048576]);
    FRelease.URL := 'https://github.com/Dicur3x/MyHomeLib/releases/tag/' + Tag;
    if Component = 'SQLite' then FRelease.URL := 'https://www.sqlite.org/changes.html';
    if Component = 'SumatraPDF' then FRelease.URL := 'https://www.sumatrapdfreader.org/docs/Version-history';
    FReady := True; FNeedsCheck := False; FProgress.Position := 100;
    if TJSONObject(Root).TryGetValue<string>('notes', Notes) then DisplayNotes(Notes);
    FStatus.Caption := 'Обновление ' + ReleaseTitle + ' готово к установке.' + sLineBreak +
      'Можно установить сейчас или продолжить работу.';
    FPrimary.Caption := 'Установить и перезапустить'; Result := True;
    if FRecovery then
    begin
      FStatus.Caption := 'Установка была прервана. Можно восстановить предыдущую версию и перезапустить HomeLib Ru.';
      FPrimary.Caption := 'Восстановить и перезапустить';
    end;
  except
    // Automatic startup remains quiet if a cached download was removed.
  end;
  finally Journal.Free; Root.Free; end;
  LayoutWindow;
end;

function TfrmProgramUpdate.LaunchInstallation: Boolean;
var Root: TJSONObject; Helper, Parameters: string; Code: HINST;
  I: Integer; Args: TJSONArray;
begin
  Result := False;
  try
    AssertUpdatePath(FJob); AssertUpdatePath(Settings.AppPath);
    Helper := IncludeTrailingPathDelimiter(FJob) + 'HomeLibRuUpdater.exe';
    if not FRecovery or not FileExists(Helper) then
      if not Winapi.Windows.CopyFile(PChar(Settings.AppPath + 'HomeLibRuUpdater.exe'), PChar(Helper), False) then RaiseLastOSError;
    Root := TJSONObject.Create;
    try
      Root.AddPair('target', ExcludeTrailingPathDelimiter(Settings.AppPath));
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
    Code := ShellExecute(Handle, 'open', PChar(Helper), PChar(Parameters), PChar(FJob), SW_HIDE);
    if NativeInt(Code) <= 32 then raise Exception.Create('Не удалось запустить механизм обновления.');
    Result := True;
  except
    on E: Exception do
    begin
      FStatus.Caption := 'Не удалось начать установку: ' + E.Message;
      FPendingInstall := False; Show; BringToFront;
    end;
  end;
end;

procedure TfrmProgramUpdate.CancelInstallation;
begin FPendingInstall := False; end;

end.
