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
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetRelease(const ReleaseInfo: TProgramRelease);
    procedure BeginCheck;
    procedure SetCurrent(const ReleaseInfo: TProgramRelease);
    procedure CheckFailed(const Error: string);
    procedure RememberHistory(const ReleaseInfo: TProgramRelease);
    procedure CheckComponents(Automatic: Boolean);
    function RestoreReady: Boolean;
    function LaunchInstallation: Boolean;
    procedure CancelInstallation;
    property PendingInstall: Boolean read FPendingInstall;
    property OnCheck: TNotifyEvent read FCheck write FCheck;
    property OnRestart: TNotifyEvent read FRestart write FRestart;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.JSON, System.RegularExpressions, Winapi.ShellAPI,
  Vcl.Controls, Vcl.Graphics, dm_user, unit_Settings, unit_Globals,
  unit_ProgramUpdateInstaller, unit_MHLHttpClient;

constructor TfrmProgramUpdate.Create(AOwner: TComponent);
var HistoryFile: string;
begin
  inherited CreateNew(AOwner);
  Caption := 'Обновление HomeLib Ru'; BorderStyle := bsDialog;
  Position := poMainFormCenter; ClientWidth := 740; ClientHeight := 520;
  Font.Name := 'Segoe UI'; Font.Size := 9;
  FVersion := TLabel.Create(Self); FVersion.Parent := Self;
  FVersion.SetBounds(20, 16, 700, 20); FVersion.Font.Style := [fsBold];
  FVersion.Caption := 'Текущая версия: ' + PROGRAM_RELEASE_VERSION;
  FStatus := TLabel.Create(Self); FStatus.Parent := Self;
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
  FPrimary.Caption := 'Проверить обновления';
  FNeedsCheck := True;
  FStatus.Caption := 'История последних выпусков';
  FApplicationStatus := FStatus.Caption;
  try
    if FileExists(IncludeTrailingPathDelimiter(FCache) + 'notes.txt') then
      DisplayNotes(Copy(TFile.ReadAllText(IncludeTrailingPathDelimiter(FCache) + 'notes.txt', TEncoding.UTF8), 1, 324000))
    else if FileExists(Settings.AppPath + 'CHANGES.txt') then
      DisplayNotes(Copy(TFile.ReadAllText(Settings.AppPath + 'CHANGES.txt', TEncoding.UTF8), 1, 324000))
    else DisplayNotes('');
  except end;
  ScaleForPPI(Screen.PixelsPerInch);
end;

destructor TfrmProgramUpdate.Destroy;
begin
  if Assigned(FComponentThread) then
  begin FComponentThread.Terminate; FreeAndNil(FComponentThread); end;
  if Assigned(FThread) then
  begin FThread.Terminate; FreeAndNil(FThread); end;
  // Keep a verified ready update when installation is postponed or the app exits.
  if not FReady then DiscardJob;
  inherited;
end;

procedure TfrmProgramUpdate.DiscardJob;
begin
  if FJob = '' then Exit;
  try CleanProgramUpdate(FJob); except end;
  FJob := '';
end;

procedure TfrmProgramUpdate.SetRelease(const ReleaseInfo: TProgramRelease);
begin
  if ReleaseInfo.ComponentID = '' then FApplicationRelease := ReleaseInfo;
  if FRecovery or Assigned(FThread) or FReady then
  begin Show; BringToFront; Exit; end;
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
  Show;
end;

function TfrmProgramUpdate.ReleaseTitle: string;
begin
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
end;

procedure TfrmProgramUpdate.ComponentCheckClick(Sender: TObject);
begin FComponentExplicit := True; CheckComponents(False); end;

procedure TfrmProgramUpdate.CheckComponents(Automatic: Boolean);
begin
  if Assigned(FComponentThread) then Exit;
  FComponentAutomatic := Automatic; FComponentError := '';
  FComponentThread := TComponentUpdateThread.Create(Handle, CreateHTTPClientGlobal);
  FComponentCheck.Enabled := False;
  if (FSelector.ItemIndex > 0) and not Assigned(FThread) and not FReady then
  begin
    FStatus.Caption := 'Проверка обновлений компонентов у авторов…'; FPrimary.Enabled := False;
  end;
  FComponentThread.Start;
end;

procedure TfrmProgramUpdate.ComponentsChecked(var Message: TMessage);
var I, J, Errors: Integer; Successful: Boolean;
begin
  Message.Result := 0; if not Assigned(FComponentThread) then Exit;
  FComponentThread.WaitFor; Successful := FComponentThread.Successful;
  if Successful then FComponents := FComponentThread.Releases
  else FComponentError := FComponentThread.ErrorText;
  FreeAndNil(FComponentThread); FComponentCheck.Enabled := True; UpdateComponentList;
  if Assigned(FThread) or FReady then
  begin FComponentExplicit := False; Exit; end;
  if FComponentExplicit and not FComponentAutomatic and (FSelector.ItemIndex = 0) then
  begin
    Errors := 0; for I := 0 to 2 do if FComponents[I].ComponentError <> '' then Inc(Errors);
    if Successful and (Errors > 0) then
      FStatus.Caption := 'Некоторые компоненты не удалось проверить. Выберите их в списке, чтобы увидеть подробности.'
    else if Successful then FStatus.Caption := 'Компоненты проверены. Выберите компонент в списке, чтобы увидеть версию и изменения.'
    else FStatus.Caption := FComponentError;
    Show; BringToFront;
  end;
  FComponentExplicit := False;
  if (FSelector.ItemIndex > 0) and not FComponentAutomatic then
  begin ComponentSelected(nil); if not FComponentAutomatic then begin Show; BringToFront; end; end
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
end;

procedure TfrmProgramUpdate.DisplayNotes(const Notes: string);
begin
  FNotes.Load(Notes);
  if FSelector.ItemIndex = 0 then FApplicationHistory := Notes;
end;

procedure TfrmProgramUpdate.RememberHistory(const ReleaseInfo: TProgramRelease);
begin
  try
    AssertUpdatePath(FCache);
    ForceDirectories(FCache);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FCache) + 'notes.txt', ReleaseInfo.History, TEncoding.UTF8);
  except end;
end;

procedure TfrmProgramUpdate.BeginCheck;
begin
  if (FSelector.ItemIndex > 0) and not FReady and not Assigned(FThread) then
  begin FSelector.ItemIndex := 0; ComponentSelected(nil); end;
  if FSelector.ItemIndex > 0 then Exit;
  FStatus.Caption := 'Проверка обновлений на GitHub…';
  if not FReady then FNeedsCheck := True;
  if not Assigned(FThread) and not FReady then FPrimary.Enabled := False;
  Show; BringToFront;
end;

procedure TfrmProgramUpdate.SetCurrent(const ReleaseInfo: TProgramRelease);
begin
  FApplicationRelease := Default(TProgramRelease);
  FApplicationHistory := ReleaseInfo.History;
  FApplicationStatus := 'Обновлений нет. У вас установлена последняя версия HomeLib Ru.';
  if FSelector.ItemIndex > 0 then Exit;
  if Assigned(FThread) or FReady then Exit;
  FRelease := Default(TProgramRelease);
  FNeedsCheck := True;
  DisplayNotes(ReleaseInfo.History);
  FStatus.Caption := 'Обновлений нет. У вас установлена последняя версия HomeLib Ru.';
  FPrimary.Caption := 'Проверить ещё раз'; FPrimary.Enabled := True; FLater.Caption := 'Закрыть';
  Show;
end;

procedure TfrmProgramUpdate.CheckFailed(const Error: string);
begin
  FApplicationStatus := Error;
  if FSelector.ItemIndex > 0 then Exit;
  FStatus.Caption := Error;
  if not Assigned(FThread) and not FReady then
  begin FNeedsCheck := True; FPrimary.Caption := 'Повторить проверку'; FPrimary.Enabled := True; end;
  Show;
end;

procedure TfrmProgramUpdate.PrimaryClick(Sender: TObject);
var ID: TGUID;
begin
  if FReady then
  begin
    FPendingInstall := True;
    if Assigned(FRestart) then FRestart(Self);
    Exit;
  end;
  if Assigned(FThread) then Exit;
  if FNeedsCheck or (FRelease.Tag = '') then
  begin
    if FSelector.ItemIndex > 0 then CheckComponents(False)
    else if Assigned(FCheck) then FCheck(Self);
    Exit;
  end;
  if FRelease.DownloadURL = '' then
  begin PageClick(nil); Exit; end;
  DiscardJob; CreateGUID(ID);
  FJob := IncludeTrailingPathDelimiter(FCache) + 'HomeLibRu-update-' +
    StringReplace(StringReplace(GUIDToString(ID), '{', '', []), '}', '', []);
  FThread := TProgramDownloadThread.Create(Handle, CreateHTTPClientGlobal, FRelease, FJob);
  FSelector.Enabled := False;
  FPrimary.Enabled := False; FPrimary.Caption := 'Загрузка…';
  FLater.Caption := 'Отменить'; FStatus.Caption := 'Загрузка ' + ReleaseTitle + '…';
  FProgress.Position := 0;
  FBytes.Caption := Format('Скачано: 0,0 / %.1f МБ', [FRelease.Size / 1048576]);
  FThread.Start;
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
  if FSelector.ItemIndex = 2 then FRelease.URL := 'https://www.alreader.com/downloads.php?lang=ru';
  if FSelector.ItemIndex = 3 then FRelease.URL := 'https://www.sumatrapdfreader.org/docs/Version-history';
  if FRelease.URL = '' then FRelease.URL := 'https://github.com/Dicur3x/MyHomeLib/releases';
  ShellExecute(Handle, 'open', PChar(FRelease.URL), nil, nil, SW_SHOWNORMAL);
end;

procedure TfrmProgramUpdate.DownloadProgress(var Message: TMessage);
begin
  Message.Result := 0;
  if not Assigned(FThread) then Exit;
  FProgress.Position := Message.WParam;
  if Message.WParam >= 95 then FStatus.Caption := 'Проверка и подготовка обновления…'
  else FStatus.Caption := 'Загрузка ' + ReleaseTitle + '…';
  FBytes.Caption := Format('Скачано: %.1f / %.1f МБ', [Message.LParam / 1048576, FRelease.Size / 1048576]);
end;

procedure TfrmProgramUpdate.DownloadCompleted(var Message: TMessage);
var Error: string;
begin
  Message.Result := 0;
  if not Assigned(FThread) then Exit;
  FThread.WaitFor; FReady := FThread.Successful; Error := FThread.ErrorText;
  if FReady then FRelease := FThread.ReleaseInfo;
  FreeAndNil(FThread); FLater.Enabled := True; FLater.Caption := 'Позже';
  FPrimary.Enabled := True;
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
    Show;
  end
  else
  begin
    FSelector.Enabled := True;
    FPrimary.Caption := 'Повторить загрузку'; FStatus.Caption := Error;
    DiscardJob;
  end;
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
    if Component = '' then
    begin if not CompareReleaseTags(Tag, PROGRAM_RELEASE_VERSION, Comparison) then Exit; end
    else
    begin
      if (ComponentFileName(Component) = '') or not CompareComponentVersions(Version, Version, Comparison) or
         not TRegEx.IsMatch(Tag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
      if ComponentInstalledVersion(Settings.AppPath, Component) = '' then Comparison := 1
      else if not CompareComponentVersions(Version, ComponentInstalledVersion(Settings.AppPath, Component), Comparison) then Exit;
    end;
    AssertUpdatePath(Job);
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
    if Component <> '' then
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
