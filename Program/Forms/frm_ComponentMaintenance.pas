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
    FRemove, FResolve, FClose: TButton;
    FOffer: TCheckBox;
    FProgress: TProgressBar;
    FTimer: TTimer;
    FPlan, FResult: TComponentRemovalPlan;
    FWorker: TThread;
    FError, FLeftover, FJob: string;
    FDownloads: TProgramDownloadThread;
    FAvailable: TComponentReleases;
    FFactory: TInventoryDownloadFactory;
    FManifests, FJobs: TArray<string>;
    procedure ListChanged(Sender: TObject; Item: TListItem; Change: TItemChange);
    procedure RemoveClick(Sender: TObject);
    procedure ResolveClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    procedure Tick(Sender: TObject);
    procedure LayoutControls;
    procedure StartPlan;
    procedure PlanText;
    procedure FillRows(const Initial: TArray<string>);
    function CheckedIDs: TArray<string>;
    function IsCancelled: Boolean;
    procedure SaveOfferChoice;
  protected
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

implementation

uses System.IOUtils, System.Math, System.StrUtils, System.DateUtils, System.JSON, System.Zip, Winapi.Windows,
  Vcl.Graphics, Vcl.Dialogs, unit_ProgramUpdateInstaller, unit_ComponentUsage,
  unit_MHLTheme, unit_Diagnostics, unit_Globals, unit_Errors;

function InstalledOptionalComponents(const AppPath: string; ReaderOnly: Boolean): TArray<string>;
begin
  Result:=nil;
  for var Component in UPDATE_COMPONENTS do
    if IsOptionalComponent(Component.ID) and not (ReaderOnly and (Component.ID='HomeLibReader')) and
      (FileExists(CheckedUpdateChildPath(AppPath,ComponentFileName(Component.ID))) or
       FileExists(CheckedUpdateChildPath(AppPath,ComponentReceiptName(Component.ID)))) then
      Result:=Result+TArray<string>.Create(Component.ID);
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
  for var Title in ['Модуль','Размер','Использовался'] do FList.Columns.Add.Caption:=Title;
  FList.OnChange:=ListChanged;
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
  FClose:=TButton.Create(Self); FClose.Parent:=Self; FClose.Caption:='Закрыть';
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
var Item: TListItem; Size: Int64; Known: Boolean; Last: TDateTime;
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
      Known:=False; Size:=0;
      try for var Info in InstalledComponentFiles(FAppPath,ID) do
        begin Known:=True; if FileExists(CheckedUpdateChildPath(FAppPath,Info.Name)) then Inc(Size,Info.Size); end;
      except end;
      if Known then Item.SubItems.Add(ModuleSize(Size)) else Item.SubItems.Add('Нужна проверка');
      Last:=0; try Last:=ComponentLastUse(FAppPath,ID); except end;
      if Last=0 then Item.SubItems.Add('Нет данных') else Item.SubItems.Add(FormatDateTime('dd.mm.yyyy',TTimeZone.Local.ToLocalTime(Last)));
      Item.Checked:=not FMonthly and (IndexStr(ID,Initial)>=0);
    end;
  finally FList.Items.EndUpdate; FBuilding:=False; end;
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

procedure TfrmComponentMaintenance.ListChanged(Sender: TObject; Item: TListItem; Change: TItemChange);
begin if not FBuilding and (Change=ctState) then RefreshPlan; end;

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
    FResolve.Enabled:=(Length(CheckedIDs)=1) and not Assigned(FWorker) and not Assigned(FDownloads);
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

procedure TfrmComponentMaintenance.ResolveClick(Sender: TObject);
var IDs: TArray<string>; Info: TProgramRelease; ID, Installed: string; Dialog: TOpenDialog;
  Archive, Tag, Version: string;
begin
  if Assigned(FWorker) or Assigned(FDownloads) then Exit;
  IDs:=CheckedIDs; if Length(IDs)<>1 then Exit; ID:=IDs[0];
  Info:=Default(TProgramRelease); Installed:=InstalledComponentVersion(FAppPath,ID);
  for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do if UPDATE_COMPONENTS[I].ID=ID then Info:=FAvailable[I];
  FJob:=CheckedUpdateChildPath(FAppPath,'tools/component-state/HomeLibRu-update-inventory-'+TGUID.NewGuid.ToString);
  FJobs:=FJobs+TArray<string>.Create(FJob);
  if Assigned(FFactory) and (Info.ComponentID=ID) and (Info.ComponentVersion=Installed) and (Installed<>'') and
    (Info.Size>0) and (Info.DownloadURL<>'') then
  begin
    if MHLShowInfo('Для проверки состава нужно скачать архив установленного модуля: '+ModuleSize(Info.Size)+'.'+sLineBreak+
      'Архив будет использован только для списка файлов. Переустановка не требуется.'+sLineBreak+'Скачать?',mbYesNo)<>mrYes then Exit;
    FError:=''; FDownloads:=FFactory(Info,FJob); FDownloads.RuntimePath:=FAppPath;
    FSummary.Caption:='Загрузка и проверка списка файлов…'; FProgress.Visible:=True; FResolve.Enabled:=False;
    FRemove.Enabled:=False; FList.Enabled:=False;
    FDownloads.Start; Exit;
  end;
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите сохранённый архив модуля HomeLibre'; Dialog.Filter:='Архив модуля HomeLibre (*.zip)|*.zip';
    Dialog.Options:=[ofFileMustExist,ofEnableSizing]; if not Dialog.Execute then Exit; Archive:=Dialog.FileName;
  finally Dialog.Free; end;
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
        AdoptComponentFileInventory(FAppPath,ID,TPath.Combine(FJob,'manifest.json'));
      except on E: EAbort do FCancelled:=True; on E: Exception do FError:=E.Message; end;
    end);
  FWorker.FreeOnTerminate:=False; FWorker.Start;
end;

procedure TfrmComponentMaintenance.Tick(Sender: TObject);
begin
  if Assigned(FDownloads) then
  begin
    if WaitForSingleObject(FDownloads.Handle,0)<>WAIT_OBJECT_0 then Exit;
    FDownloads.WaitFor;
    if FDownloads.Successful then
    begin
      try
        AdoptComponentFileInventory(FAppPath,FDownloads.ReleaseInfo.ComponentID,TPath.Combine(FJob,'manifest.json'));
        FManifests:=FManifests+TArray<string>.Create(TPath.Combine(FJob,'manifest.json'));
      except on E: Exception do FError:=E.Message; end;
    end
    else FError:=FDownloads.ErrorText;
    FDownloads.Free; FDownloads:=nil; FProgress.Visible:=False; FList.Enabled:=True;
    if FClosing then begin SaveOfferChoice; ModalResult:=mrCancel; Exit; end;
    if FError<>'' then
    begin
      FSummary.Caption:='Не удалось проверить состав'; FDetails.Text:=FError;
      FResolve.Enabled:=Length(CheckedIDs)=1; Exit;
    end;
    RefreshPlan;
  end;
  if Assigned(FWorker) then
  begin
    if WaitForSingleObject(FWorker.Handle,0)<>WAIT_OBJECT_0 then Exit;
    FWorker.WaitFor; FreeAndNil(FWorker); FProgress.Visible:=False; FList.Enabled:=True;
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
    FResolve.Enabled:=Length(CheckedIDs)=1;
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
  FList.Columns[0].Width:=W*50 div 100; FList.Columns[1].Width:=W*20 div 100;
  FList.Columns[2].Width:=W-FList.Columns[0].Width-FList.Columns[1].Width-MulDiv(24,S,96);
  Bottom:=ClientHeight-Gap-ButtonH;
  FClose.SetBounds(ClientWidth-Gap-MulDiv(100,S,96),Bottom,MulDiv(100,S,96),ButtonH);
  FRemove.SetBounds(FClose.Left-Gap-MulDiv(180,S,96),Bottom,MulDiv(180,S,96),ButtonH);
  FResolve.SetBounds(Gap,Bottom,MulDiv(180,S,96),ButtonH);
  FOffer.SetBounds(Gap,Bottom-Gap-H-8,W,H+8);
  FSummary.SetBounds(Gap,FList.Top+FList.Height+Gap,W,2*H+Gap);
  FDetails.SetBounds(Gap,FSummary.Top+FSummary.Height,W,Max(0,FOffer.Top-Gap-FSummary.Top-FSummary.Height));
  FProgress.SetBounds(Gap,FSummary.Top+FSummary.Height-5,W,4);
end;

procedure TfrmComponentMaintenance.Resize;
begin inherited; LayoutControls; end;

procedure TfrmComponentMaintenance.ChangeScale(M,D: Integer; isDpiChange: Boolean);
begin inherited; LayoutControls; end;

end.
