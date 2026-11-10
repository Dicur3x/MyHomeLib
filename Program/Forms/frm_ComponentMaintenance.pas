unit frm_ComponentMaintenance;

interface

uses System.Classes, System.SysUtils, Vcl.Forms, Vcl.Controls, Vcl.ComCtrls,
  Vcl.StdCtrls, Vcl.ExtCtrls, unit_ComponentUpdates, unit_ComponentRemoval, unit_ProgramUpdates;

type
  TInventoryDownloadFactory = reference to function(const Info: TProgramRelease; const Job: string): TProgramDownloadThread;
  TfrmComponentMaintenance = class(TForm)
  private
    FAppPath: string;
    FReaderOnly, FMonthly, FBuilding, FClosing, FPlanReady, FCancelled: Boolean;
    FVersion, FWorkerVersion, FStop: Integer;
    FAction: Integer;
    FHeader, FSummary: TLabel;
    FList: TListView;
    FDetails: TMemo;
    FRemove, FResolve, FClose, FSelectAll: TButton;
    FOffer: TCheckBox;
    FProgress: TProgressBar;
    FTimer: TTimer;
    FPlan, FResult: TComponentRemovalPlan;
    FWorker: TThread;
    FError, FLeftover, FJob, FInventoryID: string;
    FDownloads: TProgramDownloadThread;
    FAvailable: TComponentReleases;
    FFactory: TInventoryDownloadFactory;
    FManifests, FJobs: TArray<string>;
    procedure ModuleChecked(Sender: TObject; Item: TListItem);
    procedure ModuleSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure SelectAllClick(Sender: TObject);
    procedure UpdateSelectionControls;
    function InventorySelection: string;
    procedure RemoveClick(Sender: TObject);
    procedure ResolveClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    procedure Tick(Sender: TObject);
    procedure LayoutControls;
    procedure StartPlan;
    procedure PlanText;
    procedure FillRows(const Initial: TArray<string>);
    procedure RefreshRowInventory(const ID: string; Item: TListItem);
    function CheckedIDs: TArray<string>;
    function IsCancelled: Boolean;
    procedure SaveOfferChoice;
  protected
    function ConfirmInventoryDownload(Size: Int64): Boolean; virtual;
    function ChooseInventoryArchive(out Archive: string): Boolean; virtual;
    procedure Resize; override;
    procedure ChangeScale(M,D: Integer; isDpiChange: Boolean); override;
  public
    constructor CreateManager(AOwner: TComponent; const AppPath: string; ReaderOnly, Monthly: Boolean;
      const Initial: TArray<string>; const Available: TComponentReleases; const Factory: TInventoryDownloadFactory);
    destructor Destroy; override;
    procedure RefreshPlan;
    property PlanReady: Boolean read FPlanReady;
  end;

function InstalledOptionalComponents(const AppPath: string; ReaderOnly: Boolean): TArray<string>;
procedure ObserveInstalledOptionalComponents(const AppPath: string; ReaderOnly: Boolean;
  NowUTC: TDateTime = 0);
function ComponentCleanupWindowReady(Form: TCustomForm; Busy: Boolean): Boolean;
function OfferUnusedComponents(Owner: TCustomForm; const AppPath: string; ReaderOnly: Boolean;
  NowUTC: TDateTime = 0; const ApplyPalette: TProc<TCustomForm> = nil): Boolean;

implementation

uses System.IOUtils, System.Math, System.StrUtils, System.DateUtils, System.JSON, System.Zip, Winapi.Windows,
  Vcl.Graphics, Vcl.Dialogs, unit_ProgramUpdateInstaller, unit_ComponentUsage,
  unit_MHLTheme, unit_Diagnostics, unit_Globals, unit_Errors;

function InstalledOptionalComponents(const AppPath: string; ReaderOnly: Boolean): TArray<string>;
begin
  Result:=nil;
  for var Component in UPDATE_COMPONENTS do
    if IsOptionalComponent(Component.ID) and not (ReaderOnly and
      (IndexText(Component.ID,['HomeLibReader','AlReader','SumatraPDF','MHLMcpServer','Zstandard',JPEG_XL_ENCODER_COMPONENT])>=0)) and
      (FileExists(CheckedUpdateChildPath(AppPath,ComponentFileName(Component.ID))) or
       FileExists(CheckedUpdateChildPath(AppPath,ComponentReceiptName(Component.ID)))) then
      Result:=Result+TArray<string>.Create(Component.ID);
end;

procedure ObserveInstalledOptionalComponents(const AppPath: string; ReaderOnly: Boolean;
  NowUTC: TDateTime);
begin
  try
    var IDs:=InstalledOptionalComponents(AppPath,ReaderOnly);
    if Length(IDs)>0 then ObserveInstalledComponents(AppPath,IDs,NowUTC);
  except on E: Exception do LogDiagnosticError('module-usage-discovery',E); end;
end;

function ComponentCleanupWindowReady(Form: TCustomForm; Busy: Boolean): Boolean;
var Input: TLastInputInfo;
begin
  Result:=False;
  if Busy or not Assigned(Form) or Application.Terminated or not Application.Active or
    (Application.ModalLevel<>0) or not Form.Visible or (Form.WindowState=wsMinimized) or
    (Screen.ActiveCustomForm<>Form) or (GetSystemMetrics(SM_SHUTTINGDOWN)<>0) then Exit;
  Input.cbSize:=SizeOf(Input);
  if GetLastInputInfo(Input) then
    Result:=(UInt64(GetTickCount)+$100000000-Input.dwTime) mod $100000000>=30000;
end;

function OfferUnusedComponents(Owner: TCustomForm; const AppPath: string; ReaderOnly: Boolean;
  NowUTC: TDateTime; const ApplyPalette: TProc<TCustomForm>): Boolean;
var Unused: TArray<string>; Dialog: TfrmComponentMaintenance;
begin
  Result:=False;
  try
    if not ReserveUnusedComponentOffer(AppPath,InstalledOptionalComponents(AppPath,ReaderOnly),Unused,NowUTC) then Exit;
    Dialog:=TfrmComponentMaintenance.CreateManager(Owner,AppPath,ReaderOnly,True,Unused,
      Default(TComponentReleases),nil);
    try
      if Assigned(ApplyPalette) then ApplyPalette(Dialog);
      Dialog.ShowModal; Result:=True;
    finally Dialog.Free; end;
  except on E: Exception do LogDiagnosticError('module-cleanup-offer',E); end;
end;

function ModuleSize(Size: Int64): string;
begin
  if Size>=1024*1024 then Result:=Format('%.1f МБ',[Size/1024/1024])
  else if Size>=1024 then Result:=Format('%.1f КБ',[Size/1024]) else Result:=Size.ToString+' Б';
end;

constructor TfrmComponentMaintenance.CreateManager(AOwner: TComponent; const AppPath: string;
  ReaderOnly, Monthly: Boolean; const Initial: TArray<string>; const Available: TComponentReleases;
  const Factory: TInventoryDownloadFactory);
begin
  inherited CreateNew(AOwner); Name:='ComponentMaintenance'; Caption:='Управление модулями — HomeLibre';
  FAppPath:=AppPath; FReaderOnly:=ReaderOnly; FMonthly:=Monthly; FAvailable:=Available; FFactory:=Factory;
  Position:=poOwnerFormCenter; Font.Assign(Screen.MessageFont); BorderStyle:=bsSizeable;
  ClientWidth:=760; ClientHeight:=560; Constraints.MinWidth:=600; Constraints.MinHeight:=440;
  FHeader:=TLabel.Create(Self); FHeader.Parent:=Self; FHeader.AutoSize:=False; FHeader.WordWrap:=True;
  if Monthly then FHeader.Caption:='Эти модули не использовались не меньше месяца. Выберите, какие удалить.'
  else FHeader.Caption:='Выберите ненужные модули. При следующей необходимости программа предложит установить их снова.';
  FList:=TListView.Create(Self); FList.Parent:=Self; FList.Name:='MaintenanceModules';
  FList.ViewStyle:=vsReport; FList.ReadOnly:=True; FList.RowSelect:=True; FList.Checkboxes:=True;
  FList.HideSelection:=False; FList.DoubleBuffered:=True;
  for var Title in ['Модуль','Размер','Состояние','Использовался'] do FList.Columns.Add.Caption:=Title;
  FList.OnItemChecked:=ModuleChecked; FList.OnSelectItem:=ModuleSelected;
  FSelectAll:=TButton.Create(Self); FSelectAll.Parent:=Self; FSelectAll.Name:='MaintenanceSelectAll';
  FSelectAll.OnClick:=SelectAllClick;
  FSummary:=TLabel.Create(Self); FSummary.Parent:=Self; FSummary.Name:='MaintenanceSummary';
  FSummary.AutoSize:=False; FSummary.WordWrap:=True; FSummary.Caption:='Отметьте модули для удаления.';
  FDetails:=TMemo.Create(Self); FDetails.Parent:=Self; FDetails.Name:='MaintenanceDetails';
  FDetails.ReadOnly:=True; FDetails.ScrollBars:=ssVertical; FDetails.TabStop:=True;
  FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Self; FProgress.Style:=pbstMarquee; FProgress.Visible:=False;
  FOffer:=TCheckBox.Create(Self); FOffer.Parent:=Self; FOffer.Name:='MaintenanceOffers';
  if Monthly then FOffer.Caption:='Больше не предлагать очистку' else FOffer.Caption:='Предлагать очистку неиспользуемых модулей раз в месяц';
  try FOffer.Checked:=not Monthly and not ComponentCleanupSuppressed(FAppPath);
  except FOffer.Checked:=not Monthly; end;
  FRemove:=TButton.Create(Self); FRemove.Parent:=Self; FRemove.Name:='MaintenanceRemove';
  FRemove.Caption:='Удалить выбранные'; FRemove.OnClick:=RemoveClick; FRemove.Enabled:=False;
  FResolve:=TButton.Create(Self); FResolve.Parent:=Self; FResolve.Name:='MaintenanceInventory';
  FResolve.Caption:='Проверить состав…'; FResolve.OnClick:=ResolveClick;
  FClose:=TButton.Create(Self); FClose.Parent:=Self; FClose.Name:='MaintenanceClose'; FClose.Caption:='Закрыть';
  if Monthly then FClose.Caption:='Не сейчас'; FClose.Cancel:=True; FClose.OnClick:=CloseClick;
  FTimer:=TTimer.Create(Self); FTimer.Interval:=150; FTimer.OnTimer:=Tick;
  OnCloseQuery:=CloseQueryHandler; FillRows(Initial); LayoutControls; ApplyMHLControlTheme(Self);
  RefreshPlan;
end;

destructor TfrmComponentMaintenance.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  InterlockedExchange(FStop,1);
  if Assigned(FWorker) then begin FWorker.WaitFor; FWorker.Free; end;
  if Assigned(FDownloads) then begin FDownloads.Terminate; FDownloads.WaitFor; FDownloads.Free; end;
  for var Job in FJobs do try CleanProgramUpdate(Job); except on E: Exception do LogDiagnosticError('module-inventory-cleanup',E); end;
  inherited;
end;

procedure TfrmComponentMaintenance.FillRows(const Initial: TArray<string>);
var Item: TListItem; Last: TDateTime;
begin
  FBuilding:=True; FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for var ID in InstalledOptionalComponents(FAppPath,FReaderOnly) do
    begin
      if FMonthly and (IndexStr(ID,Initial)<0) then Continue;
      Item:=FList.Items.Add;
      for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
        if UPDATE_COMPONENTS[I].ID=ID then begin Item.Caption:=ComponentTitle(I); Item.Data:=Pointer(NativeInt(I)); Break; end;
      Item.SubItems.Add('');
      Item.SubItems.Add('');
      RefreshRowInventory(ID, Item);
      Last:=0; try Last:=ComponentLastUse(FAppPath,ID); except end;
      if Last=0 then Item.SubItems.Add('Нет данных') else Item.SubItems.Add(FormatDateTime('dd.mm.yyyy',TTimeZone.Local.ToLocalTime(Last)));
      Item.Checked:=not FMonthly and (IndexStr(ID,Initial)>=0);
    end;
  finally FList.Items.EndUpdate; FBuilding:=False; end;
  UpdateSelectionControls;
end;

procedure TfrmComponentMaintenance.RefreshRowInventory(const ID: string; Item: TListItem);
var Size: Int64; Known, HasFiles: Boolean;
begin
  if Item = nil then
    for var Row in FList.Items do
      if UPDATE_COMPONENTS[NativeInt(Row.Data)].ID = ID then
      begin
        Item := Row;
        Break;
      end;
  if Item = nil then Exit;
  Known := False;
  HasFiles := False;
  Size := 0;
  try
    for var Info in InstalledComponentFiles(FAppPath, ID) do
    begin
      Known := True;
      if FileExists(CheckedUpdateChildPath(FAppPath, Info.Name)) then
      begin
        HasFiles := True;
        Inc(Size, Info.Size);
      end;
    end;
  except end;
  if Known then Item.SubItems[0] := ModuleSize(Size) else Item.SubItems[0] := '—';
  if not Known then Item.SubItems[1] := 'Сверить состав'
  else if FileExists(CheckedUpdateChildPath(FAppPath, ComponentFileName(ID))) then
    Item.SubItems[1] := 'Состав учтён'
  else if HasFiles then Item.SubItems[1] := 'Остались файлы'
  else Item.SubItems[1] := 'Нет файлов';
end;

function TfrmComponentMaintenance.CheckedIDs: TArray<string>;
begin
  Result:=nil;
  for var Item in FList.Items do if Item.Checked then
    Result:=Result+TArray<string>.Create(UPDATE_COMPONENTS[NativeInt(Item.Data)].ID);
end;

function TfrmComponentMaintenance.IsCancelled: Boolean;
begin Result:=InterlockedCompareExchange(FStop,0,0)<>0; end;

procedure TfrmComponentMaintenance.RefreshPlan;
begin
  Inc(FVersion); FPlanReady:=False; FRemove.Enabled:=False;
  if Assigned(FWorker) then InterlockedExchange(FStop,1);
end;

procedure TfrmComponentMaintenance.ModuleChecked(Sender: TObject; Item: TListItem);
begin
  if FBuilding then Exit;
  RefreshPlan;
  UpdateSelectionControls;
end;

procedure TfrmComponentMaintenance.ModuleSelected(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if not FBuilding then UpdateSelectionControls;
end;

function TfrmComponentMaintenance.InventorySelection: string;
var IDs: TArray<string>;
begin
  IDs := CheckedIDs;
  if Length(IDs) = 1 then Exit(IDs[0]);
  Result := '';
  if Assigned(FList.Selected) then
    Result := UPDATE_COMPONENTS[NativeInt(FList.Selected.Data)].ID;
end;

procedure TfrmComponentMaintenance.UpdateSelectionControls;
var AllChecked: Boolean;
begin
  AllChecked := (FList.Items.Count > 0) and (Length(CheckedIDs) = FList.Items.Count);
  FSelectAll.Enabled := FList.Enabled and (FList.Items.Count > 0);
  if AllChecked then FSelectAll.Caption := 'Снять все отметки'
  else FSelectAll.Caption := 'Отметить все';
  FResolve.Enabled := FList.Enabled and (InventorySelection <> '') and
    not Assigned(FWorker) and not Assigned(FDownloads);
end;

procedure TfrmComponentMaintenance.SelectAllClick(Sender: TObject);
var Check: Boolean;
begin
  if not FList.Enabled or (FList.Items.Count = 0) then Exit;
  Check := Length(CheckedIDs) <> FList.Items.Count;
  FBuilding := True;
  FList.Items.BeginUpdate;
  try
    for var Item in FList.Items do Item.Checked := Check;
  finally
    FList.Items.EndUpdate;
    FBuilding := False;
  end;
  RefreshPlan;
  UpdateSelectionControls;
end;

procedure TfrmComponentMaintenance.StartPlan;
var IDs, Sources: TArray<string>;
begin
  IDs:=CheckedIDs; Sources:=Copy(FManifests); FWorkerVersion:=FVersion;
  if Length(IDs)=0 then
  begin
    FPlan:=Default(TComponentRemovalPlan); FPlanReady:=True; PlanText; Exit;
  end;
  FError:=''; FCancelled:=False; FAction:=0; InterlockedExchange(FStop,0);
  FSummary.Caption:='Проверка файлов…'; FProgress.Visible:=True; FResolve.Enabled:=False;
  FWorker:=TThread.CreateAnonymousThread(procedure
    begin
      try FResult:=BuildComponentRemovalPlan(FAppPath,IDs,Sources,IsCancelled);
      except on E: EAbort do FCancelled:=True; on E: Exception do FError:=E.Message; end;
    end);
  FWorker.FreeOnTerminate:=False; FWorker.Start;
end;

procedure TfrmComponentMaintenance.PlanText;
var Preserved: Integer;
begin
  FDetails.Lines.BeginUpdate;
  try
    FDetails.Clear; Preserved:=0;
    if Length(FPlan.IDs)=0 then FSummary.Caption:='Отметьте модули для удаления.'
    else
    begin
      for var Item in FPlan.Files do
        if Item.Disposition in [crKeepCore,crKeepSettings,crKeepShared,crKeepChanged] then Inc(Preserved);
      FSummary.Caption:=Format('Выбрано модулей: %d · Освободится: %s · Сохранятся файлы: %d',
        [Length(FPlan.IDs),ModuleSize(FPlan.Bytes),Preserved]);
      for var Text in FPlan.Blockers do FDetails.Lines.Add(Text);
      for var Text in FPlan.Warnings do FDetails.Lines.Add(Text);
      FDetails.Lines.Add('Книги, коллекции, закладки и настройки сохранятся.');
      for var Item in FPlan.Files do if Item.Disposition in [crKeepCore,crKeepSettings,crKeepShared,crKeepChanged] then
        FDetails.Lines.Add('Сохранить: '+Item.FileInfo.Name+' — '+Item.Reason);
    end;
    FRemove.Enabled:=FPlanReady and FPlan.CanRemove and not Assigned(FWorker) and not Assigned(FDownloads);
    UpdateSelectionControls;
  finally FDetails.Lines.EndUpdate; end;
end;

procedure TfrmComponentMaintenance.RemoveClick(Sender: TObject);
var Plan: TComponentRemovalPlan;
begin
  if not FPlanReady or not FPlan.CanRemove or Assigned(FWorker) or Assigned(FDownloads) then Exit;
  Plan:=FPlan; FError:=''; FLeftover:=''; FCancelled:=False; FAction:=1; FPlanReady:=False;
  FRemove.Enabled:=False; FResolve.Enabled:=False; FList.Enabled:=False; FProgress.Visible:=True;
  FSummary.Caption:='Удаление выбранных модулей…'; InterlockedExchange(FStop,0);
  FWorker:=TThread.CreateAnonymousThread(procedure
    begin
      try FLeftover:=ExecuteComponentRemovalPlan(Plan,-1,IsCancelled);
      except on E: EAbort do FCancelled:=True; on E: Exception do FError:=E.Message; end;
    end);
  FWorker.FreeOnTerminate:=False; FWorker.Start;
end;

function TfrmComponentMaintenance.ConfirmInventoryDownload(Size: Int64): Boolean;
begin
  Result:=MHLShowInfo('Для проверки состава нужно скачать архив установленного модуля: '+ModuleSize(Size)+'.'+sLineBreak+
    'Архив будет использован только для списка файлов. Переустановка не требуется.'+sLineBreak+'Скачать?',mbYesNo)=mrYes;
end;

function TfrmComponentMaintenance.ChooseInventoryArchive(out Archive: string): Boolean;
var Dialog: TOpenDialog;
begin
  Archive:=''; Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите сохранённый архив модуля HomeLibre'; Dialog.Filter:='Архив модуля HomeLibre (*.zip)|*.zip';
    Dialog.Options:=[ofFileMustExist,ofEnableSizing]; Result:=Dialog.Execute;
    if Result then Archive:=Dialog.FileName;
  finally Dialog.Free; end;
end;

procedure TfrmComponentMaintenance.ResolveClick(Sender: TObject);
var Info: TProgramRelease; ID, Installed: string;
  Archive, Tag, Version: string;
begin
  if Assigned(FWorker) or Assigned(FDownloads) then Exit;
  ID := InventorySelection; if ID = '' then Exit;
  Info:=Default(TProgramRelease); Installed:=InstalledComponentVersion(FAppPath,ID);
  for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do if UPDATE_COMPONENTS[I].ID=ID then Info:=FAvailable[I];
  FJob:=CheckedUpdateChildPath(FAppPath,'tools/component-state/HomeLibRu-update-inventory-'+TGUID.NewGuid.ToString);
  FJobs:=FJobs+TArray<string>.Create(FJob);
  if Assigned(FFactory) and (Info.ComponentID=ID) and (Info.ComponentVersion=Installed) and (Installed<>'') and
    (Info.Size>0) and (Info.DownloadURL<>'') then
  begin
    if not ConfirmInventoryDownload(Info.Size) then Exit;
    try
      FError:=''; FDownloads:=FFactory(Info,FJob); FDownloads.RuntimePath:=FAppPath;
      FSummary.Caption:='Загрузка и проверка списка файлов…'; FProgress.Visible:=True; FResolve.Enabled:=False;
      FRemove.Enabled:=False; FList.Enabled:=False;
      FDownloads.Start;
    except on E: Exception do
      begin
        // TThread.Destroy resumes and joins a cancelled Create(True) worker.
        // Waiting explicitly before Start would leave the dialog stuck forever.
        if Assigned(FDownloads) then begin FDownloads.Terminate; FreeAndNil(FDownloads); end;
        FError:=E.Message; LogDiagnosticError('module-inventory-download',E);
        FProgress.Visible:=False; FList.Enabled:=True;
        UpdateSelectionControls;
        FRemove.Enabled:=FPlanReady and FPlan.CanRemove;
        FSummary.Caption:='Не удалось начать проверку состава'; FDetails.Text:=FError;
      end;
    end;
    Exit;
  end;
  if not ChooseInventoryArchive(Archive) then Exit;
  FInventoryID:=ID;
  FError:=''; FCancelled:=False; FAction:=2; FProgress.Visible:=True;
  FRemove.Enabled:=False; FResolve.Enabled:=False; FList.Enabled:=False; InterlockedExchange(FStop,0);
  FWorker:=TThread.CreateAnonymousThread(procedure
    var Zip: TZipFile; Root: TJSONValue; Bytes: TBytes; Index: Integer;
    begin
      try
        Zip:=TZipFile.Create; Root:=nil;
        try
          if TFile.GetSize(Archive)>UPDATE_MAX_ARCHIVE then raise Exception.Create('Архив слишком велик для пакета модуля.');
          Zip.Open(Archive,zmRead); Index:=Zip.IndexOf(UPDATE_MANIFEST);
          if (Index<0) or (Zip.FileInfo[Index].UncompressedSize64>1024*1024) then
            raise Exception.Create('В архиве нет подходящего списка файлов модуля.');
          Zip.Read(UPDATE_MANIFEST,Bytes); Root:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
          if not Assigned(Root) or (Root.GetValue<string>('component','')<>ID) then raise Exception.Create('Архив относится к другому модулю.');
          Tag:=Root.GetValue<string>('release'); Version:=Root.GetValue<string>('version');
        finally Root.Free; Zip.Free; end;
        PrepareProgramUpdate(Archive,UpdateSHA256(Archive),Tag,ProgramUpdatePlatform,FJob,True,ID,Version);
      except on E: EAbort do FCancelled:=True; on E: Exception do FError:=E.Message; end;
    end);
  FWorker.FreeOnTerminate:=False; FWorker.Start;
end;

procedure TfrmComponentMaintenance.Tick(Sender: TObject);
begin
  if FSelectAll.Enabled <> (FList.Enabled and (FList.Items.Count > 0)) then UpdateSelectionControls;
  if Assigned(FDownloads) then
  begin
    if WaitForSingleObject(FDownloads.Handle,0)<>WAIT_OBJECT_0 then Exit;
    FDownloads.WaitFor;
    if not FClosing and FDownloads.Successful then
    begin
      try
        AdoptComponentFileInventory(FAppPath,FDownloads.ReleaseInfo.ComponentID,TPath.Combine(FJob,'manifest.json'));
        RefreshRowInventory(FDownloads.ReleaseInfo.ComponentID, nil);
        FManifests:=FManifests+TArray<string>.Create(TPath.Combine(FJob,'manifest.json'));
      except on E: Exception do FError:=E.Message; end;
    end
    else FError:=FDownloads.ErrorText;
    FDownloads.Free; FDownloads:=nil; FProgress.Visible:=False; FList.Enabled:=True;
    if FClosing then begin SaveOfferChoice; ModalResult:=mrCancel; Exit; end;
    if FError<>'' then
    begin
      FSummary.Caption:='Не удалось проверить состав'; FDetails.Text:=FError;
      UpdateSelectionControls; Exit;
    end;
    RefreshPlan;
  end;
  if Assigned(FWorker) then
  begin
    if WaitForSingleObject(FWorker.Handle,0)<>WAIT_OBJECT_0 then Exit;
    FWorker.WaitFor; FreeAndNil(FWorker); FProgress.Visible:=False; FList.Enabled:=True;
    if (FAction=2) and FClosing then FCancelled:=True;
    if (FAction=2) and not FCancelled and (FError='') then
    try
      AdoptComponentFileInventory(FAppPath,FInventoryID,TPath.Combine(FJob,'manifest.json'));
      RefreshRowInventory(FInventoryID, nil);
    except on E: Exception do FError:=E.Message; end;
    if FError<>'' then
    begin FPlanReady:=True; FPlan:=Default(TComponentRemovalPlan); FSummary.Caption:='Операция не выполнена'; FDetails.Text:=FError; end
    else if FAction=1 then
    begin
      if FCancelled then FSummary.Caption:='Удаление отменено. Файлы восстановлены.'
      else if FLeftover<>'' then FSummary.Caption:='Модули удалены. Сохранённые временные файлы: '+FLeftover
      else FSummary.Caption:='Выбранные модули удалены.';
      FillRows(nil); FPlan:=Default(TComponentRemovalPlan); FPlanReady:=True;
    end
    else if (FAction=2) and not FCancelled then
    begin FManifests:=FManifests+TArray<string>.Create(TPath.Combine(FJob,'manifest.json')); RefreshPlan; end
    else if not FCancelled and (FWorkerVersion=FVersion) then
    begin FPlan:=FResult; FPlanReady:=True; PlanText; end;
    UpdateSelectionControls;
    if FError<>'' then Exit;
  end;
  if FClosing then begin SaveOfferChoice; ModalResult:=mrCancel; Exit; end;
  if not FPlanReady then StartPlan;
end;

procedure TfrmComponentMaintenance.SaveOfferChoice;
begin
  try
    if FMonthly then SetComponentCleanupSuppressed(FAppPath,FOffer.Checked)
    else SetComponentCleanupSuppressed(FAppPath,not FOffer.Checked);
  except on E: Exception do LogDiagnosticError('module-cleanup-preference',E); end;
end;

procedure TfrmComponentMaintenance.CloseClick(Sender: TObject);
begin Close; end;

procedure TfrmComponentMaintenance.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=not Assigned(FWorker) and not Assigned(FDownloads);
  if CanClose then SaveOfferChoice
  else
  begin
    FClosing:=True; InterlockedExchange(FStop,1); if Assigned(FDownloads) then FDownloads.Terminate;
    FSummary.Caption:='Отмена операции…'; FClose.Enabled:=False;
  end;
end;

procedure TfrmComponentMaintenance.LayoutControls;
var S, Gap, W, H, ButtonH, Bottom: Integer;
begin
  if not Assigned(FClose) then Exit;
  S:=CurrentPPI; Gap:=MulDiv(12,S,96); W:=ClientWidth-2*Gap;
  Canvas.Font.Assign(Font); H:=Canvas.TextHeight('Mg'); ButtonH:=Max(MulDiv(32,S,96),H+MulDiv(12,S,96));
  FHeader.SetBounds(Gap,Gap,W,2*H+Gap); FList.SetBounds(Gap,FHeader.Top+FHeader.Height+Gap,W,Max(MulDiv(130,S,96),ClientHeight div 3));
  FList.Columns[1].Width:=MulDiv(77,S,96);
  FList.Columns[2].Width:=MulDiv(114,S,96);
  FList.Columns[3].Width:=MulDiv(103,S,96);
  FList.Columns[0].Width:=W-FList.Columns[1].Width-FList.Columns[2].Width-FList.Columns[3].Width-MulDiv(24,S,96);
  FSelectAll.SetBounds(Gap,FList.Top+FList.Height+Gap div 2,MulDiv(140,S,96),ButtonH);
  Bottom:=ClientHeight-Gap-ButtonH;
  FClose.SetBounds(ClientWidth-Gap-MulDiv(100,S,96),Bottom,MulDiv(100,S,96),ButtonH);
  FRemove.SetBounds(FClose.Left-Gap-MulDiv(180,S,96),Bottom,MulDiv(180,S,96),ButtonH);
  FResolve.SetBounds(Gap,Bottom,MulDiv(180,S,96),ButtonH);
  FOffer.SetBounds(Gap,Bottom-Gap-H-8,W,H+8);
  FSummary.SetBounds(Gap,FSelectAll.Top+FSelectAll.Height+Gap div 2,W,2*H+Gap);
  FDetails.SetBounds(Gap,FSummary.Top+FSummary.Height,W,Max(0,FOffer.Top-Gap-FSummary.Top-FSummary.Height));
  FProgress.SetBounds(Gap,FSummary.Top+FSummary.Height-5,W,4);
end;

procedure TfrmComponentMaintenance.Resize;
begin inherited; LayoutControls; end;

procedure TfrmComponentMaintenance.ChangeScale(M,D: Integer; isDpiChange: Boolean);
begin inherited; LayoutControls; end;

end.
