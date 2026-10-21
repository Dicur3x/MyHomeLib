unit frm_CollectionBackup;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, unit_CollectionBackup, frm_CatalogSources;

type
  TfrmCollectionBackup = class(TSourceDialogForm)
  private
    FPlan: TCollectionBackupPlan;
    FList: TListBox;
    FFolderPaths: TStringList;
    FReport: TMemo;
    FName, FRoot: TEdit;
    FCheck, FRestore: TButton;
    FNewID: Integer;
    procedure Selected(Sender: TObject);
    procedure Browse(Sender: TObject);
    procedure Preview(Sender: TObject);
    procedure Restore(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddFolder(const Folder: string);
    property NewCollectionID: Integer read FNewID;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Math, Vcl.Controls, Vcl.ExtCtrls, Vcl.ComCtrls,
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
var Top, Bottom: TPanel; LabelText: TLabel; B: TButton; Folders: TStringList; Folder: string;
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
  FFolderPaths:=TStringList.Create;
  Top:=TPanel.Create(Self); Top.Parent:=Self; Top.Height:=210; Top.Align:=alTop; Top.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False;
  LabelText.SetBounds(12,10,736,42); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='Выберите резервную копию объединения книг или названий серий. Будет создана отдельная коллекция; текущее состояние сохранится.';
  FList:=TListBox.Create(Self); FList.Parent:=Top; FList.Name:='lbCollectionBackups';
  FList.SetBounds(12,58,736,108); FList.Anchors:=[akLeft,akTop,akRight]; FList.OnClick:=Selected;
  B:=TButton.Create(Self); B.Parent:=Top; B.SetBounds(12,174,210,28);
  B.Caption:='Выбрать другую папку…'; B.OnClick:=Browse;
  FCheck:=TButton.Create(Self); FCheck.Parent:=Top; FCheck.SetBounds(236,174,230,28);
  FCheck.Name:='btnCheckBackup'; FCheck.Caption:='Проверить резервную копию'; FCheck.OnClick:=Preview;
  Bottom:=TPanel.Create(Self); Bottom.Parent:=Self; Bottom.Height:=140; Bottom.Align:=alBottom; Bottom.BevelOuter:=bvNone;
  LabelAt('Новое название:',12);
  FName:=TEdit.Create(Self); FName.Parent:=Bottom; FName.Name:='edRestoredCollectionName';
  FName.SetBounds(156,8,592,26); FName.Anchors:=[akLeft,akTop,akRight]; FName.MaxLength:=64;
  LabelAt('Папка книг:',48);
  FRoot:=TEdit.Create(Self); FRoot.Parent:=Bottom; FRoot.Name:='edRestoredBooksRoot';
  FRoot.SetBounds(156,44,592,26); FRoot.Anchors:=[akLeft,akTop,akRight];
  FRestore:=TButton.Create(Self); FRestore.Parent:=Bottom; FRestore.Name:='btnRestoreBackup';
  FRestore.SetBounds(12,96,440,30); FRestore.Caption:='Восстановить отдельной коллекцией'; FRestore.OnClick:=Restore;
  B:=TButton.Create(Self); B.Parent:=Bottom; B.SetBounds(638,96,110,30);
  B.Anchors:=[akTop,akRight]; B.Caption:='Закрыть'; B.Cancel:=True; B.ModalResult:=mrCancel;
  FReport:=TMemo.Create(Self); FReport.Parent:=Self; FReport.Align:=alClient;
  FReport.Name:='mmBackupPreview'; FReport.ReadOnly:=True; FReport.WordWrap:=True; FReport.ScrollBars:=ssVertical;
  FReport.AlignWithMargins:=True; FReport.Margins.Left:=12; FReport.Margins.Right:=12;
  FReport.Lines.Text:='Проверка и копирование выполняются по вашей команде, с возможностью отмены. Для отдельного каталога потребуется дополнительное место на диске.';
  Folders:=TStringList.Create;
  try
    if DirectoryExists(TPath.Combine(Settings.DataPath,'Backups')) then
      for Folder in TDirectory.GetDirectories(TPath.Combine(Settings.DataPath,'Backups')) do
        if FileExists(TPath.Combine(Folder,'destination.hlc2')) and FileExists(TPath.Combine(Folder,'system.hlc2')) then Folders.Add(Folder);
    Folders.Sort;
    for var I:=Folders.Count-1 downto 0 do
    begin FFolderPaths.Add(Folders[I]); FList.Items.Add(ExtractFileName(Folders[I])); end;
  finally Folders.Free; end;
  if FList.Items.Count>0 then FList.ItemIndex:=0;
  Selected(nil); ScaleForPPI(Screen.PixelsPerInch);
end;

destructor TfrmCollectionBackup.Destroy;
begin FPlan.Free; FFolderPaths.Free; inherited; end;

procedure TfrmCollectionBackup.Selected(Sender: TObject);
begin
  FreeAndNil(FPlan); FRestore.Enabled:=False; FName.Enabled:=False; FRoot.Enabled:=False;
  FName.Clear; FRoot.Clear;
  FCheck.Enabled:=FList.ItemIndex>=0;
  if FList.ItemIndex>=0 then FReport.Lines.Text:='Выбрана копия: '+FFolderPaths[FList.ItemIndex]+sLineBreak+
    'Нажмите «Проверить резервную копию», чтобы увидеть её содержимое и условия восстановления.'
  else FReport.Lines.Text:='В стандартной папке нет резервных копий. Можно выбрать restore-paths.txt в другой папке.';
end;

procedure TfrmCollectionBackup.AddFolder(const Folder: string);
var I: Integer;
begin
  I:=FFolderPaths.IndexOf(TPath.GetFullPath(Folder));
  if I<0 then
  begin I:=FFolderPaths.Add(TPath.GetFullPath(Folder)); FList.Items.Add(ExtractFileName(FFolderPaths[I])); end;
  FList.ItemIndex:=I; Selected(nil);
end;

procedure TfrmCollectionBackup.Browse(Sender: TObject);
var Dialog: TOpenDialog;
begin
  Dialog:=TOpenDialog.Create(Self);
  try
    Dialog.Title:='Выберите restore-paths.txt в папке резервной копии';
    Dialog.Filter:='Описание резервной копии|restore-paths.txt'; Dialog.Options:=[ofFileMustExist,ofPathMustExist];
    Dialog.InitialDir:=TPath.Combine(Settings.DataPath,'Backups');
    if Dialog.Execute then AddFolder(ExtractFileDir(Dialog.FileName));
  finally Dialog.Free; end;
end;

procedure TfrmCollectionBackup.Preview(Sender: TObject);
var Worker: TSnapshotWorker; Title: string; N: Integer;
begin
  if FList.ItemIndex<0 then Exit;
  Selected(nil); FPlan:=TCollectionBackupPlan.Create(FFolderPaths[FList.ItemIndex]);
  Worker:=TSnapshotWorker.Create(FPlan,'','',False);
  try
    RunSnapshotWorker(Self,Worker);
    if Worker.FError<>'' then FReport.Lines.Text:=Worker.FError
    else if FPlan.Ready then
    begin
      FReport.Lines.Assign(FPlan.Report); FRoot.Text:=FPlan.Root; N:=0;
      repeat
        Inc(N); Title:=Copy(FPlan.Title,1,40)+' (восстановлено '+IntToStr(N)+')';
      until not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Title);
      FName.Text:=Title; FName.Enabled:=True; FRoot.Enabled:=True; FRestore.Enabled:=True;
    end;
  finally Worker.Free; end;
end;

procedure TfrmCollectionBackup.Restore(Sender: TObject);
var Worker: TSnapshotWorker; Destination: string;
begin
  if not Assigned(FPlan) or not FPlan.Ready then Exit;
  if Trim(FName.Text)='' then begin FName.SetFocus; Exit; end;
  if Trim(FRoot.Text)='' then begin FRoot.SetFocus; Exit; end;
  FPlan.Root:=Trim(FRoot.Text);
  Destination:=TPath.Combine(Settings.DataPath,'restored-'+TGUID.NewGuid.ToString+'.hlc2');
  Worker:=TSnapshotWorker.Create(FPlan,Destination,Trim(FName.Text),True);
  try
    RunSnapshotWorker(Self,Worker);
    if Worker.FNewID>0 then begin FNewID:=Worker.FNewID; ModalResult:=mrOk; end
    else if Worker.FError<>'' then FReport.Lines.Add(Worker.FError);
  finally Worker.Free; end;
end;
end.
