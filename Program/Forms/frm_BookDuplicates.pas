unit frm_BookDuplicates;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_Interfaces,
  unit_BookDuplicates, unit_BookDeletionBinding, unit_Globals, frm_CatalogSources;

type
  TfrmBookDuplicates = class(TSourceDialogForm)
  private
    FPlan: TBookDuplicatePlan;
    FGroups, FCopies: TListView;
    FDetails: TMemo;
    FSearch, FPrevious, FNext, FKeep, FApply, FDelete, FSelectSource, FClearSelection: TButton;
    FCollectionInfo: TCollectionInfo;
    FFileDeletion: TDuplicateFileDeletion;
    FSource: TComboBox;
    FUseGroup: TCheckBox;
    FStatus: TLabel;
    FPage: TArray<TDuplicateGroup>;
    FBooks: TArray<TDuplicateBook>;
    FOffset: Integer;
    FUpdating, FChanged: Boolean;
    FBeforeApply: TNotifyEvent;
    procedure Scan(Sender: TObject);
    procedure ChangePage(Sender: TObject);
    procedure SelectGroup(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure SelectCopy(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure KeepCopy(Sender: TObject);
    procedure MarkGroup(Sender: TObject);
    procedure ApplySelected(Sender: TObject);
    procedure DeleteSelectedFiles(Sender: TObject);
    procedure UpdateStatus;
    procedure SelectSource(Sender: TObject);
    procedure ClearSelection(Sender: TObject);
    procedure LoadSources;
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    procedure RenderPage;
    property Plan: TBookDuplicatePlan read FPlan;
    property CatalogChanged: Boolean read FChanged;
    property FileDeletion: TDuplicateFileDeletion read FFileDeletion;
    property OnBeforeApply: TNotifyEvent read FBeforeApply write FBeforeApply;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Variants, System.StrUtils, System.Math, Vcl.Controls,
  Vcl.ExtCtrls, Vcl.Dialogs, unit_Settings, unit_Consts, unit_CollectionWorkerThread,
  frm_ImportProgressFormEx, frm_BuiltinReader, dm_user;

type
  TDuplicateScanWorker = class(TCollectionWorker)
  private
    FPlan: TBookDuplicatePlan;
    FError: string;
    FApply, FPrepareDeletion: Boolean;
    FCollectionInfo: TCollectionInfo;
    FFileDeletion: TDuplicateFileDeletion;
    FBackup: string;
    FSourceName: string;
    FSelected: Integer;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TBookDuplicatePlan);
  end;

constructor TDuplicateScanWorker.Create(Plan: TBookDuplicatePlan);
begin inherited Create(INVALID_COLLECTION_ID); FPlan:=Plan; end;

procedure TDuplicateScanWorker.WorkFunction;
begin
  try
    SetProgressHint(pbstMarquee); SetComment('Поиск повторных записей книг…');
    if FSourceName<>'' then
    begin
      SetComment('Выбор повторов по предпочтительному источнику…');
      FSelected:=FPlan.SelectSource(FSourceName,function: Boolean begin Result:=Canceled; end);
    end
    else if FPrepareDeletion then
    begin
      SetComment('Проверка выбранных дублей и личных данных…');
      FFileDeletion:=FPlan.PrepareFileDeletion(FCollectionInfo,function:Boolean begin Result:=Canceled; end);
    end
    else if FApply then
      FPlan.Apply(FBackup,function: Boolean begin Result:=Canceled; end,
        procedure(const Stage: string; Current,Total: Integer)
        begin
          SetComment(Stage);
          if Total>0 then begin SetProgressHint(pbstNormal); SetProgress(Integer(Int64(Current)*100 div Total)); end
          else SetProgressHint(pbstMarquee);
        end)
    else
      FPlan.Preview(function: Boolean begin Result:=Canceled; end,
        procedure(Current,Total: Integer)
        begin SetComment(Format('Проверено записей: %d',[Current])); end);
  except
    on E: Exception do
      if Canceled then FError:='Операция отменена. Изменения не сохранены.' else FError:=E.Message;
  end;
end;

constructor TfrmBookDuplicates.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var Top, Bottom, LeftPanel, RightPanel, CopyActions: TPanel; Splitter: TSplitter;
  LabelText: TLabel; CloseButton: TButton;
begin
  inherited CreateNew(AOwner); Name:='BookDuplicatesForm'; Caption:='Повторные записи книг';
  Position:=poOwnerFormCenter; PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  BorderStyle:=bsSizeable; ClientWidth:=1040; ClientHeight:=640;
  Constraints.MinWidth:=900; Constraints.MinHeight:=580;
  FCollectionInfo:=SystemDB.GetCollectionInfo(Collection.CollectionID);
  FPlan:=TBookDuplicatePlan.Create(Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE))),
    Settings.ExpandCollectionRoot(VarToStr(Collection.GetProperty(PROP_ROOTFOLDER))),
    VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)),Settings.SystemFileName[sfSystemDB],
    ResolveReaderSettingsFile(Settings.DataDir),Collection.CollectionID,Settings.WorkPath);
  Top:=TPanel.Create(Self); Top.Parent:=Self; Top.Align:=alTop; Top.Height:=198; Top.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False;
  LabelText.SetBounds(12,10,1016,54); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='1. Найдите повторы. 2. Сравните копии и выберите основную. 3. Отметьте группы и выберите действие внизу.'+#13#10+
    'Совпадение ID, языка и формата помогает найти кандидатов. Издания могут различаться.';
  FSearch:=TButton.Create(Self); FSearch.Parent:=Top; FSearch.Name:='btnFindBookDuplicates';
  FSearch.SetBounds(12,76,220,30); FSearch.Caption:='1. Найти повторы'; FSearch.OnClick:=Scan;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Top; FStatus.AutoSize:=False;
  FStatus.SetBounds(248,78,780,34); FStatus.Anchors:=[akLeft,akTop,akRight]; FStatus.WordWrap:=True;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top;
  LabelText.SetBounds(12,122,180,20); LabelText.Caption:='Предпочтительный источник:';
  FSource:=TComboBox.Create(Self); FSource.Parent:=Top; FSource.Name:='cbDuplicatePreferredSource';
  FSource.Style:=csDropDownList; FSource.SetBounds(204,118,400,26); FSource.Anchors:=[akLeft,akTop,akRight];
  FSelectSource:=TButton.Create(Self); FSelectSource.Parent:=Top; FSelectSource.Name:='btnSelectDuplicateSource';
  FSelectSource.Caption:='Отметить по источнику'; FSelectSource.SetBounds(616,116,220,30);
  FSelectSource.Anchors:=[akTop,akRight]; FSelectSource.OnClick:=SelectSource;
  FClearSelection:=TButton.Create(Self); FClearSelection.Parent:=Top; FClearSelection.Name:='btnClearDuplicateSelection';
  FClearSelection.Caption:='Снять все отметки'; FClearSelection.SetBounds(848,116,180,30);
  FClearSelection.Anchors:=[akTop,akRight]; FClearSelection.OnClick:=ClearSelection;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False; LabelText.WordWrap:=True;
  LabelText.SetBounds(12,154,1016,40); LabelText.Anchors:=[akLeft,akTop,akRight];
  LabelText.Caption:='Массовый выбор отмечает группы из двух известных источников с одной копией из выбранного источника. Группы с тремя источниками и конфликтами личных данных проверьте вручную. Прежние отметки сохраняются.';
  Bottom:=TPanel.Create(Self); Bottom.Parent:=Self; Bottom.Align:=alBottom; Bottom.Height:=52; Bottom.BevelOuter:=bvNone;
  FPrevious:=TButton.Create(Self); FPrevious.Parent:=Bottom; FPrevious.Name:='btnPreviousDuplicatePage';
  FPrevious.SetBounds(12,10,140,30); FPrevious.Caption:='Предыдущие 50'; FPrevious.OnClick:=ChangePage;
  FNext:=TButton.Create(Self); FNext.Parent:=Bottom; FNext.Name:='btnNextDuplicatePage';
  FNext.SetBounds(164,10,140,30); FNext.Caption:='Следующие 50'; FNext.OnClick:=ChangePage;
  FApply:=TButton.Create(Self); FApply.Parent:=Bottom; FApply.Name:='btnApplyBookDuplicates';
  FApply.SetBounds(316,10,211,30); FApply.Caption:='Объединить записи…'; FApply.OnClick:=ApplySelected;
  FDelete:=TButton.Create(Self); FDelete.Parent:=Bottom; FDelete.Name:='btnDeleteDuplicateFiles';
  FDelete.SetBounds(539,10,201,30); FDelete.Caption:='Удалить дубли с диска…'; FDelete.OnClick:=DeleteSelectedFiles;
  CloseButton:=TButton.Create(Self); CloseButton.Parent:=Bottom;
  CloseButton.SetBounds(908,10,120,30); CloseButton.Anchors:=[akTop,akRight];
  CloseButton.Caption:='Закрыть'; CloseButton.Cancel:=True; CloseButton.ModalResult:=mrCancel;
  LeftPanel:=TPanel.Create(Self); LeftPanel.Parent:=Self; LeftPanel.Width:=370; LeftPanel.Align:=alLeft; LeftPanel.BevelOuter:=bvNone;
  FGroups:=TListView.Create(Self); FGroups.Parent:=LeftPanel; FGroups.Align:=alClient;
  FGroups.Name:='lvDuplicateGroups'; FGroups.ViewStyle:=vsReport; FGroups.ReadOnly:=True;
  FGroups.RowSelect:=True; FGroups.HideSelection:=False; FGroups.OnSelectItem:=SelectGroup;
  with FGroups.Columns.Add do begin Caption:='Книга'; Width:=226; end;
  with FGroups.Columns.Add do begin Caption:='Копий'; Width:=52; end;
  with FGroups.Columns.Add do begin Caption:='Отмечено'; Width:=86; end;
  Splitter:=TSplitter.Create(Self); Splitter.Parent:=Self; Splitter.Left:=370; Splitter.Align:=alLeft;
  RightPanel:=TPanel.Create(Self); RightPanel.Parent:=Self; RightPanel.Align:=alClient; RightPanel.BevelOuter:=bvNone;
  CopyActions:=TPanel.Create(Self); CopyActions.Parent:=RightPanel; CopyActions.Align:=alBottom;
  CopyActions.Height:=118; CopyActions.BevelOuter:=bvNone;
  FKeep:=TButton.Create(Self); FKeep.Parent:=CopyActions; FKeep.Name:='btnPreferDuplicateCopy';
  FKeep.SetBounds(12,6,310,30); FKeep.Caption:='2. Оставить выбранную запись основной'; FKeep.OnClick:=KeepCopy;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=CopyActions; LabelText.AutoSize:=False;
  LabelText.SetBounds(12,40,634,42); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='★ — основная копия, которая останется в каталоге. Поставьте галочку, чтобы включить группу в выбранное действие.';
  FUseGroup:=TCheckBox.Create(Self); FUseGroup.Parent:=CopyActions; FUseGroup.Name:='cbSelectDuplicateGroup';
  FUseGroup.SetBounds(12,88,600,22); FUseGroup.Anchors:=[akLeft,akTop,akRight];
  FUseGroup.Caption:='3. Отметить эту группу'; FUseGroup.OnClick:=MarkGroup;
  FDetails:=TMemo.Create(Self); FDetails.Parent:=RightPanel; FDetails.Name:='mmDuplicateCopyDetails';
  FDetails.Align:=alBottom; FDetails.Height:=155; FDetails.ReadOnly:=True; FDetails.WordWrap:=True; FDetails.ScrollBars:=ssVertical;
  FCopies:=TListView.Create(Self); FCopies.Parent:=RightPanel; FCopies.Align:=alClient;
  FCopies.Name:='lvDuplicateCopies'; FCopies.ViewStyle:=vsReport; FCopies.ReadOnly:=True;
  FCopies.RowSelect:=True; FCopies.HideSelection:=False; FCopies.OnSelectItem:=SelectCopy;
  with FCopies.Columns.Add do begin Caption:='ID · ★ основная'; Width:=125; end;
  with FCopies.Columns.Add do begin Caption:='Название'; Width:=250; end;
  with FCopies.Columns.Add do begin Caption:='Размер'; Width:=80; end;
  with FCopies.Columns.Add do begin Caption:='Личные данные'; Width:=110; end;
  with FCopies.Columns.Add do begin Caption:='Источник'; Width:=164; end;
  with FCopies.Columns.Add do begin Caption:='Файл / архив'; Width:=260; end;
  with FCopies.Columns.Add do begin Caption:='Автор'; Width:=190; end;
  FDetails.Lines.Text:='Поиск запускается только по кнопке. Выбор групп и предпочтительных записей сам по себе ничего не удаляет.';
  UpdateStatus; ScaleForPPI(Screen.PixelsPerInch);
end;

destructor TfrmBookDuplicates.Destroy;
begin FPlan.Free; inherited; end;

procedure TfrmBookDuplicates.UpdateStatus;
begin
  FPrevious.Enabled:=FPlan.Ready and (FOffset>0);
  FNext.Enabled:=FPlan.Ready and (FOffset+50<FPlan.GroupCount);
  FKeep.Enabled:=Assigned(FCopies.Selected) and Assigned(FGroups.Selected);
  FUseGroup.Enabled:=Assigned(FGroups.Selected);
  FApply.Enabled:=FPlan.Ready and (FPlan.SelectedCount>0);
  FDelete.Enabled:=FApply.Enabled;
  FSource.Enabled:=FPlan.Ready and (FSource.Items.Count>0);
  FSelectSource.Enabled:=FSource.Enabled and (FSource.ItemIndex>=0);
  FClearSelection.Enabled:=FApply.Enabled;
  if FPlan.Ready then FStatus.Caption:=Format('Найдено книг с повторами: %d · Показаны %d–%d'+#13#10+'Отмечено групп: %d.',
    [FPlan.GroupCount,Ord(FPlan.GroupCount>0)*(FOffset+1),FOffset+Length(FPage),FPlan.SelectedCount])
  else FStatus.Caption:='Поиск ещё не выполнен';
end;

procedure TfrmBookDuplicates.ApplySelected(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx; BackupFolder: string;
begin
  if not FPlan.Ready or (FPlan.SelectedCount=0) then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  BackupFolder:=TPath.Combine(TPath.Combine(Settings.DataPath,'Backups'),
    'books-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+TGUID.NewGuid.ToString);
  if MessageDlg(Format('Объединить групп: %d; убрать повторных записей: %d?'+#13#10+#13#10+
    'Останутся выбранные предпочтительные записи. Пути ко всем копиям, связи с источниками и сериями сохранятся. Файлы книг не удаляются.'+#13#10+#13#10+
    'Записи с личными данными и историей чтения защищены. Перед изменениями будет создана резервная копия:'+#13#10+'%s',
    [FPlan.SelectedCount,FPlan.SelectedRemovedCount,BackupFolder]),mtConfirmation,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  Worker:=TDuplicateScanWorker.Create(FPlan); Worker.FApply:=True; Worker.FBackup:=BackupFolder;
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Объединение повторных записей книг'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    FChanged:=FChanged or FPlan.Committed;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    FOffset:=0; LoadSources; RenderPage;
    if FPlan.Committed then
      FDetails.Lines.Text:=Format('Объединение сохранено. Убрано повторных записей: %d.'+#13#10+
        'Файлы книг и личные данные сохранены.'+#13#10+'Резервная копия: %s'+#13#10+
        'Доступ к ней: Коллекция → Восстановить из резервной копии.',[FPlan.Removed,BackupFolder])
    else
    begin
      FDetails.Lines.Text:=Worker.FError+#13#10+'Чтобы продолжить, выполните поиск повторов заново.';
      if DirectoryExists(BackupFolder) then FDetails.Lines.Add('Папка резервной копии: '+BackupFolder);
    end;
  finally Progress.Free; Worker.Free; UpdateStatus; end;
end;

procedure TfrmBookDuplicates.DeleteSelectedFiles(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
begin
  if not FPlan.Ready or (FPlan.SelectedCount=0) then Exit;
  if FPlan.SelectedRemovedCount>MAX_BOOK_DELETION_BINDING then
  begin
    MessageDlg(Format('Удаление не началось. Отмечено больше %d копий. Снимите часть отметок и повторите попытку.',
      [MAX_BOOK_DELETION_BINDING]),mtInformation,[mbOK],0);
    Exit;
  end;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  if MessageDlg(Format('Удалить %d повторных копий из %d групп вместе с файлами?'+sLineBreak+sLineBreak+
    'Останется основная копия со звёздочкой. Остальные копии в каждой отмеченной группе будут удалены независимо от их источников.'+sLineBreak+
    'Перед удалением программа проверит выбранные записи, личные данные и файлы сохраняемых копий.',
    [FPlan.SelectedRemovedCount,FPlan.SelectedCount]),mtWarning,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  Worker:=TDuplicateScanWorker.Create(FPlan);
  try
    Worker.FPrepareDeletion:=True; Worker.FCollectionInfo:=FCollectionInfo;
    Progress:=TImportProgressFormEx.Create(Self);
    try
      Progress.Caption:='Проверка перед удалением дублей';
      Progress.WorkerThread:=Worker;
      Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1;
      Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
      Progress.ShowModal; Worker.WaitFor;
    finally Progress.Free; end;
    if Worker.Canceled then Exit;
    if Assigned(Worker.FatalException) then raise EReadError.Create(Exception(Worker.FatalException).Message);
    if Worker.FError<>'' then
    begin
      FDetails.Lines.Text:='Удаление не началось.'+sLineBreak+Worker.FError;
      MessageDlg(FDetails.Lines.Text,mtInformation,[mbOK],0);
      Exit;
    end;
    FFileDeletion:=Worker.FFileDeletion;
    ModalResult:=mrOk;
  finally Worker.Free; end;
end;

procedure TfrmBookDuplicates.Scan(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
begin
  FSearch.Enabled:=False;
  Worker:=TDuplicateScanWorker.Create(FPlan); Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Поиск повторных книг'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    FOffset:=0; LoadSources; RenderPage;
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError;
  finally Progress.Free; Worker.Free; FSearch.Enabled:=True; end;
end;

procedure TfrmBookDuplicates.LoadSources;
begin
  FSource.Items.BeginUpdate;
  try
    FSource.Items.Clear;
    for var Name in FPlan.Sources do FSource.Items.Add(Name);
    if FSource.Items.Count>0 then FSource.ItemIndex:=0;
  finally FSource.Items.EndUpdate; end;
end;

procedure TfrmBookDuplicates.SelectSource(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
begin
  if not FPlan.Ready or (FSource.ItemIndex<0) then Exit;
  Worker:=TDuplicateScanWorker.Create(FPlan); Worker.FSourceName:=FSource.Text;
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Выбор повторных записей по источнику'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    RenderPage;
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError
    else FDetails.Lines.Text:=Format('Добавлено групп для объединения: %d.'+#13#10+
      'Предпочтительный источник: %s.'+#13#10+
      'Каталог ещё не изменён. Проверьте выбор и нажмите «Объединить выбранные группы…».'+#13#10+
      'Пропущенные группы можно проверить вручную.',[Worker.FSelected,Worker.FSourceName]);
  finally Progress.Free; Worker.Free; UpdateStatus; end;
end;

procedure TfrmBookDuplicates.ClearSelection(Sender: TObject);
begin FPlan.ClearSelection; RenderPage; end;

procedure TfrmBookDuplicates.RenderPage;
var Item: TListItem;
begin
  if FPlan.Ready and (FSource.Items.Count=0) then LoadSources;
  FUpdating:=True; FGroups.Items.BeginUpdate;
  try
    FGroups.Items.Clear; FCopies.Items.Clear; FBooks:=nil; FPage:=nil; FUseGroup.Checked:=False;
    if FPlan.Ready then FPage:=FPlan.Groups(FOffset,50);
    for var Group in FPage do
    begin
      Item:=FGroups.Items.Add; Item.Caption:=Group.Title; Item.SubItems.Add(IntToStr(Group.Count));
      Item.SubItems.Add(IfThen(Group.Selected,'Да','—'));
    end;
  finally FGroups.Items.EndUpdate; FUpdating:=False; end;
  if FGroups.Items.Count>0 then FGroups.Items[0].Selected:=True;
  UpdateStatus;
end;

procedure TfrmBookDuplicates.ChangePage(Sender: TObject);
begin
  if Sender=FNext then Inc(FOffset,50) else FOffset:=System.Math.Max(0,FOffset-50);
  RenderPage;
end;

procedure TfrmBookDuplicates.SelectGroup(Sender: TObject; Item: TListItem; Selected: Boolean);
var CopyItem: TListItem; Preferred: Integer;
begin
  if FUpdating or not Selected then Exit;
  FUpdating:=True; FCopies.Items.BeginUpdate;
  try
    FCopies.Items.Clear; FBooks:=nil; FUseGroup.Checked:=False; Preferred:=-1;
    try FBooks:=FPlan.Books(FPage[Item.Index].ID);
    except on E: Exception do begin FDetails.Lines.Text:=E.Message; Exit; end; end;
    for var I:=0 to High(FBooks) do
    begin
      CopyItem:=FCopies.Items.Add; CopyItem.Caption:=IntToStr(FBooks[I].Book.BookKey.BookID)+
        IfThen(FBooks[I].Book.BookKey.BookID=FPage[Item.Index].KeepID,' ★','');
      CopyItem.SubItems.Add(FBooks[I].Book.Title); CopyItem.SubItems.Add(FormatFloat('0.0',FBooks[I].Book.Size/1024.0)+' КБ');
      CopyItem.SubItems.Add(IfThen(FBooks[I].HasPersonalData,'Есть','—'));
      CopyItem.SubItems.Add(IfThen(FBooks[I].SourceName<>'',FBooks[I].SourceName,'Неизвестен'));
      CopyItem.SubItems.Add(FBooks[I].Book.Folder+' / '+FBooks[I].Book.FileName+FBooks[I].Book.FileExt);
      CopyItem.SubItems.Add(TAuthorsHelper.GetList(FBooks[I].Book.Authors));
      if FBooks[I].Book.BookKey.BookID=FPage[Item.Index].KeepID then Preferred:=I;
    end;
    FUseGroup.Checked:=FPage[Item.Index].Selected;
  finally FCopies.Items.EndUpdate; FUpdating:=False; UpdateStatus; end;
  if Preferred>=0 then FCopies.Items[Preferred].Selected:=True;
end;

procedure TfrmBookDuplicates.SelectCopy(Sender: TObject; Item: TListItem; Selected: Boolean);
var Book: TDuplicateBook;
begin
  if FUpdating or not Selected then Exit;
  Book:=FBooks[Item.Index];
  FDetails.Lines.Text:='Основная запись: '+IntToStr(FPage[FGroups.Selected.Index].KeepID)+#13#10+
    'Выбранная запись: '+IntToStr(Book.Book.BookKey.BookID)+#13#10+
    'Название: '+Book.Book.Title+#13#10+'Автор: '+TAuthorsHelper.GetList(Book.Book.Authors)+#13#10+
    'Формат / язык: '+Book.Book.FileExt+' / '+Book.Book.Lang+#13#10+
    'Размер: '+IntToStr(Book.Book.Size)+' байт'+#13#10+'ID источника: '+Book.Book.LibID+#13#10+
    'Папка коллекции: '+Book.Book.CollectionRoot+#13#10+'Папка / архив: '+Book.Book.Folder+#13#10+
    'Файл: '+Book.Book.FileName+Book.Book.FileExt+#13#10+
    IfThen(Book.HasPersonalData,'Есть личные данные или история чтения. Эту запись нельзя убирать в пользу другой.',
      'Личные данные и история чтения не обнаружены в текущем снимке.');
  UpdateStatus;
end;

procedure TfrmBookDuplicates.KeepCopy(Sender: TObject);
var Index, KeepID: Integer;
begin
  if not Assigned(FGroups.Selected) or not Assigned(FCopies.Selected) then Exit;
  Index:=FGroups.Selected.Index; KeepID:=FBooks[FCopies.Selected.Index].Book.BookKey.BookID;
  try
    FPlan.Choose(FPage[Index].ID,KeepID,FPage[Index].Selected); FPage[Index].KeepID:=KeepID;
    FPage[Index].Title:=FBooks[FCopies.Selected.Index].Book.Title;
    FGroups.Selected.Caption:=FPage[Index].Title;
    for var I:=0 to High(FBooks) do FCopies.Items[I].Caption:=IntToStr(FBooks[I].Book.BookKey.BookID)+
      IfThen(FBooks[I].Book.BookKey.BookID=KeepID,' ★','');
    SelectCopy(FCopies,FCopies.Selected,True);
  except on E: Exception do MessageDlg(E.Message,mtInformation,[mbOK],0); end;
  UpdateStatus;
end;

procedure TfrmBookDuplicates.MarkGroup(Sender: TObject);
var Index: Integer;
begin
  if FUpdating or not Assigned(FGroups.Selected) then Exit;
  Index:=FGroups.Selected.Index;
  try
    FPlan.Choose(FPage[Index].ID,FPage[Index].KeepID,FUseGroup.Checked);
    FPage[Index].Selected:=FUseGroup.Checked; FGroups.Selected.SubItems[1]:=IfThen(FUseGroup.Checked,'Да','—');
  except
    on E: Exception do
    begin
      FUpdating:=True; try FUseGroup.Checked:=FPage[Index].Selected; finally FUpdating:=False; end;
      MessageDlg(E.Message,mtInformation,[mbOK],0);
    end;
  end;
  UpdateStatus;
end;

end.
