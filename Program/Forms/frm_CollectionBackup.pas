unit frm_CollectionBackup;

interface

uses System.Classes, System.Generics.Collections, Vcl.Forms, Vcl.StdCtrls, unit_CollectionBackup, frm_CatalogSources;

type
  TfrmCollectionBackup = class(TSourceDialogForm)
  private
    FPlan: TCollectionBackupPlan;
    FList: TListBox;
    FFolderPaths: TStringList;
    FFolderDates: TList<TDateTime>;
    FReport: TMemo;
    FName, FRoot: TEdit;
    FBrowse, FCheck, FRestore, FRefresh, FDelete: TButton;
    FBusy, FRefreshing: Boolean;
    FNewID: Integer;
    function SelectedFolderIndex: Integer;
    procedure Selected(Sender: TObject);
    procedure Browse(Sender: TObject);
    procedure Preview(Sender: TObject);
    procedure Restore(Sender: TObject);
    procedure RefreshFolders(Sender: TObject);
    procedure RemoveFolders(Sender: TObject);
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddFolder(const Folder: string);
    property NewCollectionID: Integer read FNewID;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Math, Winapi.Windows, Vcl.Controls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Dialogs, unit_Settings, unit_Consts, unit_WorkerThread, unit_CollectionWorkerThread,
  frm_ImportProgressFormEx, dm_user;

type
  TSnapshotWorker = class(TCollectionWorker)
  private
    FPlan: TCollectionBackupPlan;
    FDestination, FTitle, FError: string;
    FApply: Boolean;
    FNewID: Integer;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TCollectionBackupPlan; const Destination, Title: string; Apply: Boolean);
  end;
  TBackupRemovalWorker = class(TCollectionWorker)
  private
    FPlan: TCollectionBackupRemovalPlan;
    FError: string;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TCollectionBackupRemovalPlan);
  end;

constructor TBackupRemovalWorker.Create(Plan: TCollectionBackupRemovalPlan);
begin inherited Create(INVALID_COLLECTION_ID); FPlan:=Plan; end;

procedure TBackupRemovalWorker.WorkFunction;
begin
  SetProgressHint(pbstMarquee); SetComment('Удаление выбранных резервных копий…');
  try FPlan.Execute; except on E: Exception do FError:=E.Message; end;
end;

constructor TSnapshotWorker.Create(Plan: TCollectionBackupPlan; const Destination, Title: string; Apply: Boolean);
begin
  inherited Create(INVALID_COLLECTION_ID); FPlan:=Plan; FDestination:=Destination;
  FTitle:=Title; FApply:=Apply; FNewID:=INVALID_COLLECTION_ID;
end;

procedure TSnapshotWorker.WorkFunction;
begin
  try
    SetProgressHint(pbstMarquee);
    if not FApply then
    begin
      SetComment('Проверка резервной копии…');
      FPlan.Preview(function: Boolean begin Result:=Canceled; end);
    end
    else
    begin
      SetComment('Создание отдельной восстановленной коллекции…');
      FNewID:=FPlan.RestoreAsNew(FSystemData,FDestination,FTitle,
        function: Boolean begin Result:=Canceled; end,
        procedure(Done,Total: Integer)
        begin
          if Total>0 then
          begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Done)*100 div Total)); end;
        end);
    end;
  except
    on E: EAbort do FError:='Отменено. Текущие коллекции не изменены.';
    on E: Exception do
      if Canceled then FError:='Отменено. Текущие коллекции не изменены.' else FError:=E.Message;
  end;
end;

procedure RunSnapshotWorker(Owner: TCustomForm; Worker: TSnapshotWorker);
var Progress: TImportProgressFormEx;
begin
  Progress:=TImportProgressFormEx.Create(Owner);
  try
    Progress.Caption:='Восстановление коллекции'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Owner;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
  finally Progress.Free; end;
end;

constructor TfrmCollectionBackup.Create(AOwner: TComponent);
var Top, Bottom: TPanel; LabelText: TLabel; B: TButton;
  procedure LabelAt(const Caption: string; Y: Integer);
  begin
    LabelText:=TLabel.Create(Self); LabelText.Parent:=Bottom;
    LabelText.SetBounds(12,Y,140,20); LabelText.Caption:=Caption;
  end;
begin
  inherited CreateNew(AOwner); Name:='CollectionBackupForm';
  Caption:='Восстановить коллекцию из резервной копии'; Position:=poOwnerFormCenter;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  BorderStyle:=bsSizeable; ClientWidth:=760; ClientHeight:=570;
  Constraints.MinWidth:=700; Constraints.MinHeight:=520; FNewID:=INVALID_COLLECTION_ID;
  FFolderPaths:=TStringList.Create; FFolderDates:=TList<TDateTime>.Create;
  Top:=TPanel.Create(Self); Top.Parent:=Self; Top.Height:=242; Top.Align:=alTop; Top.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False;
  LabelText.SetBounds(12,10,736,42); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='Копия будет восстановлена в этой программе и открыта. Исходная коллекция останется в меню «Коллекция», чтобы к ней можно было вернуться.';
  FList:=TListBox.Create(Self); FList.Parent:=Top; FList.Name:='lbCollectionBackups';
  FList.MultiSelect:=True; FList.ExtendedSelect:=True;
  FList.SetBounds(12,58,736,108); FList.Anchors:=[akLeft,akTop,akRight]; FList.OnClick:=Selected;
  FBrowse:=TButton.Create(Self); FBrowse.Parent:=Top; FBrowse.SetBounds(12,174,210,28);
  FBrowse.Caption:='Другая папка…'; FBrowse.OnClick:=Browse;
  FCheck:=TButton.Create(Self); FCheck.Parent:=Top; FCheck.SetBounds(236,174,230,28);
  FCheck.Name:='btnCheckBackup'; FCheck.Caption:='Проверить копию'; FCheck.OnClick:=Preview;
  FRefresh:=TButton.Create(Self); FRefresh.Parent:=Top; FRefresh.SetBounds(480,174,128,28);
  FRefresh.Name:='btnRefreshBackups'; FRefresh.Caption:='Обновить список'; FRefresh.OnClick:=RefreshFolders;
  FDelete:=TButton.Create(Self); FDelete.Parent:=Top; FDelete.SetBounds(620,174,128,28);
  FDelete.Name:='btnDeleteBackups'; FDelete.Caption:='Удалить выбранные…'; FDelete.OnClick:=RemoveFolders;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.SetBounds(12,208,736,28);
  LabelText.AutoSize:=False; LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='Ctrl или Shift — выбрать несколько копий для удаления. Удаление освобождает место на диске.';
  Bottom:=TPanel.Create(Self); Bottom.Parent:=Self; Bottom.Height:=140; Bottom.Align:=alBottom; Bottom.BevelOuter:=bvNone;
  LabelAt('Новое название:',12);
  FName:=TEdit.Create(Self); FName.Parent:=Bottom; FName.Name:='edRestoredCollectionName';
  FName.SetBounds(156,8,592,26); FName.Anchors:=[akLeft,akTop,akRight]; FName.MaxLength:=64;
  LabelAt('Папка книг:',48);
  FRoot:=TEdit.Create(Self); FRoot.Parent:=Bottom; FRoot.Name:='edRestoredBooksRoot';
  FRoot.SetBounds(156,44,592,26); FRoot.Anchors:=[akLeft,akTop,akRight];
  FRestore:=TButton.Create(Self); FRestore.Parent:=Bottom; FRestore.Name:='btnRestoreBackup';
  FRestore.SetBounds(12,96,440,30); FRestore.Caption:='Восстановить и открыть в HomeLibre'; FRestore.OnClick:=Restore;
  B:=TButton.Create(Self); B.Parent:=Bottom; B.SetBounds(638,96,110,30);
  B.Anchors:=[akTop,akRight]; B.Caption:='Закрыть'; B.Cancel:=True; B.ModalResult:=mrCancel;
  FReport:=TMemo.Create(Self); FReport.Parent:=Self; FReport.Align:=alClient;
  FReport.Name:='mmBackupPreview'; FReport.ReadOnly:=True; FReport.WordWrap:=True; FReport.ScrollBars:=ssVertical;
  FReport.AlignWithMargins:=True; FReport.Margins.Left:=12; FReport.Margins.Right:=12;
  FReport.Lines.Text:='Проверка и копирование выполняются по вашей команде, с возможностью отмены. Для отдельного каталога потребуется дополнительное место на диске.';
  RefreshFolders(nil); OnActivate:=RefreshFolders; ScaleForPPI(Screen.PixelsPerInch); Resize;
end;

procedure TfrmCollectionBackup.Resize;
var Buttons: array[0..3] of TButton; Gap, Margin, Width, Top, Height: Integer;
begin
  inherited;
  if not Assigned(FDelete) then Exit;
  Gap:=MulDiv(8,Font.PixelsPerInch,96); Margin:=MulDiv(12,Font.PixelsPerInch,96);
  Width:=(ClientWidth-2*Margin-3*Gap) div 4; Top:=FCheck.Top; Height:=FCheck.Height;
  Buttons[0]:=FBrowse; Buttons[1]:=FCheck; Buttons[2]:=FRefresh; Buttons[3]:=FDelete;
  for var I:=0 to High(Buttons) do Buttons[I].SetBounds(Margin+I*(Width+Gap),Top,Width,Height);
end;

destructor TfrmCollectionBackup.Destroy;
begin FPlan.Free; FFolderPaths.Free; FFolderDates.Free; inherited; end;

function TfrmCollectionBackup.SelectedFolderIndex: Integer;
begin
  Result:=-1; if FList.SelCount<>1 then Exit;
  for var I:=0 to FList.Items.Count-1 do if FList.Selected[I] then Exit(I);
end;

procedure TfrmCollectionBackup.Selected(Sender: TObject);
var Info: TCollectionBackupInfo; Index: Integer;
begin
  if FRefreshing then Exit;
  FreeAndNil(FPlan); FRestore.Enabled:=False; FName.Enabled:=False; FRoot.Enabled:=False;
  FName.Clear; FRoot.Clear;
  Index:=SelectedFolderIndex; FCheck.Enabled:=Index>=0;
  FDelete.Enabled:=FList.SelCount>0;
  if FList.SelCount>1 then
    FReport.Lines.Text:=Format('Выбрано копий: %d. Для удаления нажмите «Удалить…». Размер и полный список будут показаны перед подтверждением.',[FList.SelCount])
  else if Index>=0 then
  begin
    Info:=ReadCollectionBackupInfo(FFolderPaths[Index]);
    FReport.Lines.Text:='Дата и время: '+CollectionBackupDateText(Info)+sLineBreak+
      'Операция: '+CollectionBackupOperationText(Info.Operation)+sLineBreak+
      'Выбрана копия: '+FFolderPaths[Index]+sLineBreak+
      'Нажмите «Проверить резервную копию», чтобы увидеть её содержимое и условия восстановления.';
  end
  else if FList.Items.Count>0 then FReport.Lines.Text:='Выберите резервную копию для проверки или несколько копий для удаления.'
  else FReport.Lines.Text:='В стандартной папке нет резервных копий. Можно выбрать restore-paths.txt в другой папке.';
end;

procedure TfrmCollectionBackup.AddFolder(const Folder: string);
var I: Integer; Info: TCollectionBackupInfo; Date: TDateTime;
begin
  if not CollectionBackupFolderAvailable(Folder) then Exit;
  I:=FFolderPaths.IndexOf(TPath.GetFullPath(Folder));
  if I<0 then
  begin
    Info:=ReadCollectionBackupInfo(Folder); Date:=0;
    if Info.HasCreatedAt then Date:=Info.CreatedAt;
    I:=0;
    while (I<FFolderDates.Count) and (FFolderDates[I]>=Date) do Inc(I);
    FFolderPaths.Insert(I,TPath.GetFullPath(Folder)); FFolderDates.Insert(I,Date);
    var Text:=CollectionBackupDateText(Info,False)+' — '+CollectionBackupOperationText(Info.Operation);
    if not (FileExists(TPath.Combine(Folder,'destination.hlc2')) and FileExists(TPath.Combine(Folder,'system.hlc2')) and
      FileExists(TPath.Combine(Folder,'restore-paths.txt'))) then Text:=Text+' — неполный набор файлов';
    FList.Items.Insert(I,Text);
  end;
  if not FRefreshing then begin FList.ClearSelection; FList.Selected[I]:=True; end;
  FList.ItemIndex:=I; Selected(nil);
end;

procedure TfrmCollectionBackup.RefreshFolders(Sender: TObject);
var Folders, Selection: TStringList; Folder, Current: string; Focus: Integer;
begin
  if FBusy or FRefreshing then Exit;
  Folders:=TStringList.Create; Selection:=TStringList.Create;
  FRefreshing:=True; Focus:=FList.ItemIndex; Current:='';
  if Focus>=0 then Current:=FFolderPaths[Focus];
  FList.Items.BeginUpdate;
  try
    for var I:=0 to FFolderPaths.Count-1 do
    begin
      Folder:=FFolderPaths[I];
      if FList.Selected[I] then Selection.Add(Folder);
      if CollectionBackupFolderAvailable(Folder) then Folders.Add(Folder);
    end;
    if DirectoryExists(TPath.Combine(Settings.DataPath,'Backups')) then
      for Folder in TDirectory.GetDirectories(TPath.Combine(Settings.DataPath,'Backups')) do
        if CollectionBackupFolderAvailable(Folder) and (Folders.IndexOf(Folder)<0) then Folders.Add(Folder);
    FreeAndNil(FPlan); FFolderPaths.Clear; FFolderDates.Clear; FList.Clear;
    for Folder in Folders do AddFolder(Folder);
    FList.ClearSelection;
    for var I:=0 to FFolderPaths.Count-1 do FList.Selected[I]:=Selection.IndexOf(FFolderPaths[I])>=0;
    Focus:=FFolderPaths.IndexOf(Current);
    if Focus<0 then Focus:=Min(Max(0,FList.ItemIndex),FList.Items.Count-1);
    FList.ItemIndex:=Focus;
    if (FList.SelCount=0) and (Focus>=0) then FList.Selected[Focus]:=True;
  finally
    FList.Items.EndUpdate; FRefreshing:=False; Folders.Free; Selection.Free;
  end;
  Selected(nil);
end;

function ConfirmBackupRemoval(Owner: TSourceDialogForm; const Details: string): Boolean;
var Dialog: TSourceDialogForm; Header: TLabel; Memo: TMemo; Footer: TPanel; Yes, No: TButton;
begin
  Dialog:=TSourceDialogForm.CreateNew(Owner);
  try
    Dialog.Name:='ConfirmBackupRemoval'; Dialog.Caption:='Удаление резервных копий';
    Dialog.Position:=poOwnerFormCenter; Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Owner;
    Dialog.PixelsPerInch:=96; Dialog.Font.PixelsPerInch:=96; Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.BorderStyle:=bsSizeable; Dialog.ClientWidth:=700; Dialog.ClientHeight:=430;
    Dialog.Constraints.MinWidth:=620; Dialog.Constraints.MinHeight:=340;
    Header:=TLabel.Create(Dialog); Header.Parent:=Dialog; Header.Align:=alTop;
    Header.AutoSize:=False; Header.Height:=76; Header.WordWrap:=True; Header.AlignWithMargins:=True;
    Header.Margins.Left:=12; Header.Margins.Right:=12; Header.Margins.Top:=12;
    Header.Caption:='Удалить перечисленные резервные копии безвозвратно?'+sLineBreak+
      'Файлы книг и текущие коллекции сохранятся. Вернуться к состоянию удалённых копий будет нельзя.';
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom; Footer.Height:=60; Footer.BevelOuter:=bvNone;
    Yes:=TButton.Create(Dialog); Yes.Parent:=Footer; Yes.Name:='btnConfirmBackupRemoval';
    Yes.SetBounds(346,14,190,32); Yes.Anchors:=[akRight,akTop]; Yes.Caption:='Удалить безвозвратно'; Yes.ModalResult:=mrYes;
    No:=TButton.Create(Dialog); No.Parent:=Footer; No.Name:='btnCancelBackupRemoval';
    No.SetBounds(546,14,142,32); No.Anchors:=[akRight,akTop]; No.Caption:='Отмена';
    No.ModalResult:=mrCancel; No.Cancel:=True; No.Default:=True;
    Memo:=TMemo.Create(Dialog); Memo.Parent:=Dialog; Memo.Align:=alClient; Memo.AlignWithMargins:=True;
    Memo.Margins.Left:=12; Memo.Margins.Right:=12; Memo.ReadOnly:=True; Memo.WordWrap:=True;
    Memo.ScrollBars:=ssVertical; Memo.Text:=Details;
    Dialog.ScaleForPPI(Owner.Font.PixelsPerInch); Dialog.ActiveControl:=No;
    Result:=Dialog.ShowModal=mrYes;
  finally Dialog.Free; end;
end;

procedure TfrmCollectionBackup.RemoveFolders(Sender: TObject);
var Folders: TArray<string>; Plan: TCollectionBackupRemovalPlan; Worker: TBackupRemovalWorker;
  Progress: TImportProgressFormEx; Status: string; Info: TCollectionBackupInfo;
begin
  if FBusy then Exit;
  Folders:=nil;
  for var I:=0 to FFolderPaths.Count-1 do if FList.Selected[I] then Folders:=Folders+TArray<string>.Create(FFolderPaths[I]);
  if Length(Folders)=0 then Exit;
  Selected(nil); FBusy:=True; Plan:=nil; Worker:=nil; Progress:=nil; Status:='';
  try
    try
      Plan:=TCollectionBackupRemovalPlan.Create(Folders);
      FReport.Lines.Text:=Format('Выбрано: %d. Размер файлов: %.2f ГиБ.',[Length(Folders),Plan.Bytes/1073741824.0]);
      for var I:=0 to High(Folders) do
      begin
        Info:=ReadCollectionBackupInfo(Folders[I]);
        FReport.Lines.Add(CollectionBackupDateText(Info,False)+' — '+CollectionBackupOperationText(Info.Operation));
        FReport.Lines.Add(Folders[I]);
      end;
      if not ConfirmBackupRemoval(Self,FReport.Text) then Exit;
      Worker:=TBackupRemovalWorker.Create(Plan); Progress:=TImportProgressFormEx.Create(Self);
      Progress.Caption:='Удаление резервных копий'; Progress.WorkerThread:=Worker;
      Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.btnCancel.Enabled:=False;
      Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self; Progress.ShowModal; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
      if Worker.FError<>'' then Status:='Удаление прервано: '+Worker.FError+sLineBreak+'Проверьте обновлённый список: часть файлов могла быть удалена.'
      else Status:=Format('Удалено резервных копий: %d. Размер файлов: %.2f ГиБ.',[Length(Folders),Plan.Bytes/1073741824.0]);
    except on E: Exception do Status:='Не удалось удалить резервные копии: '+E.Message; end;
  finally
    Progress.Free; Worker.Free; Plan.Free; FBusy:=False; RefreshFolders(nil);
    if Status<>'' then FReport.Lines.Add(Status);
  end;
end;

procedure TfrmCollectionBackup.Browse(Sender: TObject);
var Dialog: TOpenDialog;
begin
  if FBusy then Exit;
  Dialog:=TOpenDialog.Create(Self);
  FBusy:=True;
  try
    Dialog.Title:='Выберите restore-paths.txt в папке резервной копии';
    Dialog.Filter:='Описание резервной копии|restore-paths.txt'; Dialog.Options:=[ofFileMustExist,ofPathMustExist];
    Dialog.InitialDir:=TPath.Combine(Settings.DataPath,'Backups');
    if Dialog.Execute then AddFolder(ExtractFileDir(Dialog.FileName));
  finally Dialog.Free; FBusy:=False; end;
end;

procedure TfrmCollectionBackup.Preview(Sender: TObject);
var Worker: TSnapshotWorker; Title: string; N, Index: Integer;
begin
  Index:=SelectedFolderIndex; if FBusy or (Index<0) then Exit;
  Selected(nil); FPlan:=TCollectionBackupPlan.Create(FFolderPaths[Index]);
  Worker:=TSnapshotWorker.Create(FPlan,'','',False);
  FBusy:=True;
  try
    RunSnapshotWorker(Self,Worker);
    if Worker.FError<>'' then FReport.Lines.Add(Worker.FError)
    else if FPlan.Ready then
    begin
      FReport.Lines.Assign(FPlan.Report); FRoot.Text:=FPlan.Root; N:=0;
      repeat
        Inc(N); Title:=Copy(FPlan.Title,1,40)+' (восстановлено '+IntToStr(N)+')';
      until not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Title);
      FName.Text:=Title; FName.Enabled:=True; FRoot.Enabled:=True; FRestore.Enabled:=True;
    end;
  finally Worker.Free; FBusy:=False; end;
end;

procedure TfrmCollectionBackup.Restore(Sender: TObject);
var Worker: TSnapshotWorker; Destination: string;
begin
  if FBusy or not Assigned(FPlan) or not FPlan.Ready then Exit;
  if Trim(FName.Text)='' then begin FName.SetFocus; Exit; end;
  if Trim(FRoot.Text)='' then begin FRoot.SetFocus; Exit; end;
  FPlan.Root:=Trim(FRoot.Text);
  Destination:=TPath.Combine(Settings.DataPath,'restored-'+TGUID.NewGuid.ToString+'.hlc2');
  Worker:=TSnapshotWorker.Create(FPlan,Destination,Trim(FName.Text),True);
  FBusy:=True;
  try
    RunSnapshotWorker(Self,Worker);
    if Worker.FNewID>0 then begin FNewID:=Worker.FNewID; ModalResult:=mrOk; end
    else if Worker.FError<>'' then FReport.Lines.Add(Worker.FError);
  finally Worker.Free; FBusy:=False; end;
end;
end.
