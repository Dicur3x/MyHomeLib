unit frm_BookDuplicates;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_Interfaces,
  unit_BookDuplicates, unit_BookDeletionBinding, unit_BookDeletionOperation, unit_Globals, frm_CatalogSources;

type
  TfrmBookDuplicates = class(TSourceDialogForm)
  private
    FPlan, FRegularPlan, FLinkedPlan: TBookDuplicatePlan;
    FGroups, FCopies: TListView;
    FDetails: TMemo;
    FSearch, FPrevious, FNext, FKeep, FApply, FDelete, FSelectSource, FClearSelection: TButton;
    FCollectionInfo: TCollectionInfo;
    FSource, FResultKind: TComboBox;
    FUseGroup, FUnmarkedOnly: TCheckBox;
    FStatus, FModeHelp: TLabel;
    FPage: TArray<TDuplicateGroup>;
    FSourcePriority, FSavedPriority: TArray<string>;
    FBooks: TArray<TDuplicateBook>;
    FOffset: Integer;
    FUpdating, FChanged, FDeleteInBatches, FLinkedResultsValid: Boolean;
    FBeforeApply: TNotifyEvent;
    procedure Scan(Sender: TObject);
    procedure SwitchResults(Sender: TObject);
    procedure ReadSourcePriority;
    procedure SaveSourcePriority;
    procedure ChangePage(Sender: TObject);
    procedure SelectGroup(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure SelectCopy(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure UpdateCopyStates;
    procedure CheckCopy(Sender: TObject; Item: TListItem);
    procedure RefreshLinkedMarks;
    procedure KeepCopy(Sender: TObject);
    procedure MarkGroup(Sender: TObject);
    procedure ApplySelected(Sender: TObject);
    procedure DeleteSelectedFiles(Sender: TObject);
    procedure UpdateStatus;
    procedure SelectSource(Sender: TObject);
    procedure ClearSelection(Sender: TObject);
    procedure LoadSources;
    procedure FilterGroups(Sender: TObject);
    function VisibleGroupCount: Integer;
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    procedure RenderPage;
    function TakeDeletionOperation(const UserFile, JournalRoot: string): TBookDeletionOperation;
    property Plan: TBookDuplicatePlan read FPlan;
    property CatalogChanged: Boolean read FChanged;
    property OnBeforeApply: TNotifyEvent read FBeforeApply write FBeforeApply;
  end;

implementation

uses System.SysUtils, System.IOUtils, System.Variants, System.StrUtils, System.Math, System.JSON, System.IniFiles, Vcl.Controls,
  Vcl.ExtCtrls, Vcl.Dialogs, unit_Settings, unit_Consts, unit_CollectionWorkerThread,
  frm_ImportProgressFormEx, frm_BuiltinReader, dm_user, unit_AtomicIniFile;

type
  TDuplicateSourcePriorityForm = class(TSourceDialogForm)
  private
    FList: TListBox;
    procedure MoveSource(Sender: TObject);
  public
    constructor CreateForSources(AOwner: TComponent; const Sources: TArray<string>);
    function ReadPriority: TArray<string>;
  end;

  TDuplicateScanWorker = class(TCollectionWorker)
  private
    FPlan: TBookDuplicatePlan;
    FError: string;
    FApply, FSelectLinkedFiles: Boolean;
    FLinkedPlan: TBookDuplicatePlan;
    FBackup: string;
    FSourceName: string;
    FSourcePriority: TArray<string>;
    FSelected: Integer;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TBookDuplicatePlan);
  end;

constructor TDuplicateSourcePriorityForm.CreateForSources(AOwner: TComponent; const Sources: TArray<string>);
var HintLabel: TLabel; Button: TButton;
  function AddButton(const Text: string; X,Y,W: Integer): TButton;
  begin
    Result:=TButton.Create(Self);
    Result.Parent:=Self;
    Result.SetBounds(X,Y,W,30);
    Result.Caption:=Text;
  end;
begin
  inherited CreateNew(AOwner);
  Name:='DuplicateSourcePriorityForm';
  Caption:='Какие копии оставить';
  BorderStyle:=bsDialog;
  Position:=poOwnerFormCenter;
  PopupMode:=pmExplicit;
  PopupParent:=AOwner as TForm;
  PixelsPerInch:=96;
  Font.PixelsPerInch:=96;
  Font.Name:='Segoe UI';
  Font.Size:=9;
  ClientWidth:=540;
  ClientHeight:=297;
  HintLabel:=TLabel.Create(Self);
  HintLabel.Parent:=Self;
  HintLabel.AutoSize:=False;
  HintLabel.WordWrap:=True;
  HintLabel.SetBounds(12,10,516,42);
  HintLabel.Caption:='Поднимите нужные источники вверх. Программа пересчитает автоматические отметки по этому порядку. Ручной выбор сохранится.';
  FList:=TListBox.Create(Self);
  FList.Name:='lbDuplicateSourcePriority';
  FList.Parent:=Self;
  FList.SetBounds(12,55,394,190);
  for var Source in Sources do FList.Items.Add(Source);
  FList.ItemIndex:=0;
  ActiveControl:=FList;
  Button:=AddButton('Выше',418,55,110);
  Button.Name:='btnRaiseDuplicateSourcePriority';
  Button.Tag:=-1;
  Button.OnClick:=MoveSource;
  Button:=AddButton('Ниже',418,91,110);
  Button.Tag:=1;
  Button.OnClick:=MoveSource;
  Button:=AddButton('Применить порядок',242,255,170);
  Button.Default:=True;
  Button.ModalResult:=mrOk;
  Button:=AddButton('Отмена',418,255,110);
  Button.Cancel:=True;
  Button.ModalResult:=mrCancel;
  ScaleForPPI(PopupParent.CurrentPPI);
end;

procedure TDuplicateSourcePriorityForm.MoveSource(Sender: TObject);
var FromIndex, ToIndex: Integer;
begin
  FromIndex:=FList.ItemIndex;
  ToIndex:=FromIndex+TButton(Sender).Tag;
  if (FromIndex<0) or (ToIndex<0) or (ToIndex>=FList.Items.Count) then Exit;
  FList.Items.Exchange(FromIndex,ToIndex);
  FList.ItemIndex:=ToIndex;
end;

function TDuplicateSourcePriorityForm.ReadPriority: TArray<string>;
begin
  SetLength(Result,FList.Items.Count);
  for var I:=0 to High(Result) do Result[I]:=FList.Items[I];
end;

constructor TDuplicateScanWorker.Create(Plan: TBookDuplicatePlan);
begin inherited Create(INVALID_COLLECTION_ID); FPlan:=Plan; end;

procedure TDuplicateScanWorker.WorkFunction;
begin
  try
    SetProgressHint(pbstMarquee); SetComment('Поиск повторных записей книг…');
    if Length(FSourcePriority)>0 then
    begin
      SetComment('Выбор повторов по порядку источников…');
      FSelected:=FPlan.SelectSourcePriority(FSourcePriority,function: Boolean begin Result:=Canceled; end);
    end
    else if FSelectLinkedFiles then
    begin
      SetComment('Отметка дополнительных файлов…');
      FSelected:=FPlan.SelectSource(FSourceName,function: Boolean begin Result:=Canceled; end);
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
    begin
      FPlan.Preview(function: Boolean begin Result:=Canceled; end,
        procedure(Current,Total: Integer)
        begin SetComment(Format('Проверено карточек книг: %d',[Current])); end);
      if Assigned(FLinkedPlan) and not Canceled then
      begin
        SetComment('Поиск книг с несколькими файлами…');
        FLinkedPlan.PreviewLinked(function: Boolean begin Result:=Canceled; end,
          procedure(Current,Total: Integer)
          begin SetComment(Format('Проверено путей к файлам: %d',[Current])); end);
      end;
    end;
  except
    on E: Exception do
      if Canceled then FError:='Операция отменена. Изменения не сохранены.' else FError:=E.Message;
  end;
end;

constructor TfrmBookDuplicates.CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
var Top, Bottom, LeftPanel, RightPanel, CopyActions: TPanel; Splitter: TSplitter;
  LabelText: TLabel; CloseButton: TButton;

  function NewPlan: TBookDuplicatePlan;
  begin
    Result:=TBookDuplicatePlan.Create(Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE))),
      Settings.ExpandCollectionRoot(VarToStr(Collection.GetProperty(PROP_ROOTFOLDER))),
      VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)),Settings.SystemFileName[sfSystemDB],
      ResolveReaderSettingsFile(Settings.DataDir),Collection.CollectionID,Settings.WorkPath);
  end;

begin
  inherited CreateNew(AOwner); Name:='BookDuplicatesForm'; Caption:='Дубли книг';
  Position:=poOwnerFormCenter; PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  BorderStyle:=bsSizeable; ClientWidth:=1040; ClientHeight:=640;
  Constraints.MinWidth:=900; Constraints.MinHeight:=580;
  FCollectionInfo:=SystemDB.GetCollectionInfo(Collection.CollectionID);
  FRegularPlan:=NewPlan;
  FLinkedPlan:=NewPlan;
  FPlan:=FRegularPlan;
  ReadSourcePriority;
  Top:=TPanel.Create(Self); Top.Parent:=Self; Top.Align:=alTop; Top.Height:=135; Top.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False;
  LabelText.SetBounds(12,10,1016,24); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='Найдите дубли, выберите, что оставить, затем проверьте отметки перед удалением.';
  FSearch:=TButton.Create(Self); FSearch.Parent:=Top; FSearch.Name:='btnFindBookDuplicates';
  FSearch.SetBounds(12,36,148,30); FSearch.Caption:='Найти дубли'; FSearch.OnClick:=Scan;
  FResultKind:=TComboBox.Create(Self); FResultKind.Parent:=Top; FResultKind.Name:='cbDuplicateResultKind';
  FResultKind.SetBounds(172,38,260,28); FResultKind.Style:=csDropDownList;
  FResultKind.Items.Add('Отдельные записи');
  FResultKind.Items.Add('Файлы одной записи');
  FResultKind.ItemIndex:=0; FResultKind.OnChange:=SwitchResults;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Top; FStatus.AutoSize:=False;
  FStatus.SetBounds(444,34,584,38); FStatus.Anchors:=[akLeft,akTop,akRight]; FStatus.WordWrap:=True;
  FSource:=TComboBox.Create(Self); FSource.Parent:=Top; FSource.Name:='cbDuplicatePreferredSource';
  FSource.Style:=csDropDownList; FSource.SetBounds(12,76,380,26); FSource.Anchors:=[akLeft,akTop,akRight];
  FUnmarkedOnly:=TCheckBox.Create(Self); FUnmarkedOnly.Parent:=Top; FUnmarkedOnly.Name:='cbUnmarkedDuplicateGroups';
  FUnmarkedOnly.SetBounds(316,76,260,26); FUnmarkedOnly.Caption:='Только книги без отметок';
  FUnmarkedOnly.OnClick:=FilterGroups;
  FSelectSource:=TButton.Create(Self); FSelectSource.Parent:=Top; FSelectSource.Name:='btnSelectDuplicateSource';
  FSelectSource.SetBounds(12,73,290,30); FSelectSource.OnClick:=SelectSource;
  FClearSelection:=TButton.Create(Self); FClearSelection.Parent:=Top; FClearSelection.Name:='btnClearDuplicateSelection';
  FClearSelection.Caption:='Снять все отметки'; FClearSelection.SetBounds(848,73,180,30);
  FClearSelection.Anchors:=[akTop,akRight]; FClearSelection.OnClick:=ClearSelection;
  FModeHelp:=TLabel.Create(Self); FModeHelp.Parent:=Top; FModeHelp.AutoSize:=False; FModeHelp.WordWrap:=True;
  FModeHelp.SetBounds(12,108,1016,26); FModeHelp.Anchors:=[akLeft,akTop,akRight];
  Bottom:=TPanel.Create(Self); Bottom.Parent:=Self; Bottom.Align:=alBottom; Bottom.Height:=52; Bottom.BevelOuter:=bvNone;
  FPrevious:=TButton.Create(Self); FPrevious.Parent:=Bottom; FPrevious.Name:='btnPreviousDuplicatePage';
  FPrevious.SetBounds(12,10,140,30); FPrevious.Caption:='Предыдущие 50'; FPrevious.OnClick:=ChangePage;
  FNext:=TButton.Create(Self); FNext.Parent:=Bottom; FNext.Name:='btnNextDuplicatePage';
  FNext.SetBounds(164,10,140,30); FNext.Caption:='Следующие 50'; FNext.OnClick:=ChangePage;
  FApply:=TButton.Create(Self); FApply.Parent:=Bottom; FApply.Name:='btnApplyBookDuplicates';
  FApply.SetBounds(316,10,211,30); FApply.Caption:='Объединить, сохранив файлы…'; FApply.OnClick:=ApplySelected;
  FDelete:=TButton.Create(Self); FDelete.Parent:=Bottom; FDelete.Name:='btnDeleteDuplicateFiles';
  FDelete.SetBounds(539,10,212,30); FDelete.Caption:='Удалить с диска…'; FDelete.OnClick:=DeleteSelectedFiles;
  CloseButton:=TButton.Create(Self); CloseButton.Parent:=Bottom;
  CloseButton.SetBounds(908,10,120,30); CloseButton.Anchors:=[akTop,akRight];
  CloseButton.Caption:='Закрыть'; CloseButton.Cancel:=True; CloseButton.ModalResult:=mrCancel;
  LeftPanel:=TPanel.Create(Self); LeftPanel.Parent:=Self; LeftPanel.Width:=370; LeftPanel.Align:=alLeft; LeftPanel.BevelOuter:=bvNone;
  FGroups:=TListView.Create(Self); FGroups.Parent:=LeftPanel; FGroups.Align:=alClient;
  FGroups.Name:='lvDuplicateGroups'; FGroups.ViewStyle:=vsReport; FGroups.ReadOnly:=True;
  FGroups.RowSelect:=True; FGroups.HideSelection:=False; FGroups.OnSelectItem:=SelectGroup;
  with FGroups.Columns.Add do begin Caption:='Книга'; Width:=226; end;
  with FGroups.Columns.Add do begin Caption:='Копий'; Width:=52; end;
  with FGroups.Columns.Add do begin Caption:='К удалению'; Width:=86; end;
  Splitter:=TSplitter.Create(Self); Splitter.Parent:=Self; Splitter.Left:=370; Splitter.Align:=alLeft;
  RightPanel:=TPanel.Create(Self); RightPanel.Parent:=Self; RightPanel.Align:=alClient; RightPanel.BevelOuter:=bvNone;
  CopyActions:=TPanel.Create(Self); CopyActions.Parent:=RightPanel; CopyActions.Align:=alBottom;
  CopyActions.Height:=66; CopyActions.BevelOuter:=bvNone;
  FKeep:=TButton.Create(Self); FKeep.Parent:=CopyActions; FKeep.Name:='btnPreferDuplicateCopy';
  FKeep.SetBounds(12,4,235,28); FKeep.Caption:='Оставить выбранную копию'; FKeep.OnClick:=KeepCopy;
  FUseGroup:=TCheckBox.Create(Self); FUseGroup.Parent:=CopyActions; FUseGroup.Name:='cbSelectDuplicateGroup';
  FUseGroup.SetBounds(12,36,600,22); FUseGroup.Anchors:=[akLeft,akTop,akRight];
  FUseGroup.Caption:='Отметить остальные копии к удалению'; FUseGroup.OnClick:=MarkGroup;
  FDetails:=TMemo.Create(Self); FDetails.Parent:=RightPanel; FDetails.Name:='mmDuplicateCopyDetails';
  FDetails.Align:=alBottom; FDetails.Height:=102; FDetails.ReadOnly:=True; FDetails.WordWrap:=True; FDetails.ScrollBars:=ssVertical;
  FCopies:=TListView.Create(Self); FCopies.Parent:=RightPanel; FCopies.Align:=alClient;
  FCopies.Name:='lvDuplicateCopies'; FCopies.ViewStyle:=vsReport; FCopies.ReadOnly:=True;
  FCopies.RowSelect:=True; FCopies.HideSelection:=False; FCopies.OnSelectItem:=SelectCopy;
  FCopies.OnItemChecked:=CheckCopy;
  with FCopies.Columns.Add do begin Caption:='Решение'; Width:=112; end;
  with FCopies.Columns.Add do begin Caption:='Источник'; Width:=170; end;
  with FCopies.Columns.Add do begin Caption:='Название'; Width:=190; end;
  with FCopies.Columns.Add do begin Caption:='Размер'; Width:=80; end;
  with FCopies.Columns.Add do begin Caption:='Личные данные'; Width:=110; end;
  with FCopies.Columns.Add do begin Caption:='Файл / архив'; Width:=260; end;
  with FCopies.Columns.Add do begin Caption:='Автор'; Width:=190; end;
  FDetails.Lines.Text:='Здесь появятся сведения о выбранном файле.';
  UpdateStatus; ScaleForPPI(Screen.PixelsPerInch);
end;

destructor TfrmBookDuplicates.Destroy;
begin
  FLinkedPlan.Free;
  FRegularPlan.Free;
  inherited;
end;

procedure TfrmBookDuplicates.UpdateStatus;
var Linked: Boolean; ShownCount, RegularMarks, LinkedMarks: Integer;
begin
  Linked:=FPlan.LinkedMode;
  FResultKind.Enabled:=FLinkedResultsValid;
  ShownCount:=VisibleGroupCount;
  FPrevious.Enabled:=FPlan.Ready and (FOffset>0);
  FNext.Enabled:=FPlan.Ready and (FOffset+50<ShownCount);
  FKeep.Enabled:=Assigned(FCopies.Selected) and Assigned(FGroups.Selected);
  if FKeep.Enabled and not Linked then
    FKeep.Enabled:=(FCopies.Selected.Index<Length(FBooks)) and (FGroups.Selected.Index<Length(FPage)) and
      (FBooks[FCopies.Selected.Index].Book.BookKey.BookID<>FPage[FGroups.Selected.Index].KeepID);
  FKeep.Visible:=not Linked;
  FUseGroup.Enabled:=Assigned(FGroups.Selected);
  FUseGroup.Top:=ScaleValue(IfThen(Linked,8,36));
  FUseGroup.Caption:=IfThen(Linked,'Отметить все копии файла этой книги','Отметить остальные копии к удалению');
  FApply.Visible:=not Linked;
  if Linked then FDelete.Left:=FApply.Left else FDelete.Left:=FApply.Left+FApply.Width+ScaleValue(12);
  RegularMarks:=FRegularPlan.SelectedRemovedCount;
  LinkedMarks:=0;
  if FLinkedResultsValid then LinkedMarks:=FLinkedPlan.SelectedRemovedCount;
  FDelete.Enabled:=RegularMarks+LinkedMarks>0;
  FApply.Enabled:=not Linked and (RegularMarks>0);
  FSource.Enabled:=FPlan.Ready and (FSource.Items.Count>0);
  FSource.Visible:=Linked;
  FUnmarkedOnly.Visible:=not Linked;
  FUnmarkedOnly.Enabled:=FPlan.Ready;
  FSelectSource.Left:=IfThen(Linked,FSource.Left+FSource.Width+ScaleValue(12),ScaleValue(12));
  if Linked then FSelectSource.Anchors:=[akTop,akRight] else FSelectSource.Anchors:=[akTop,akLeft];
  FSelectSource.Caption:=IfThen(Linked,'Отметить копии из источника','Выбрать, что оставить…');
  FSelectSource.Enabled:=FPlan.Ready and
    ((Linked and (FPlan.GroupCount>0) and (FSource.ItemIndex>=0)) or (not Linked and (Length(FSourcePriority)>=2)));
  FClearSelection.Enabled:=FDelete.Enabled;
  if Linked then
  begin
    FModeHelp.Caption:='Одна запись в каталоге, несколько файлов на диске. Основной файл останется. Отметки в обоих списках применяются вместе.';
  end
  else
  begin
    if FPlan.Ready and (FSource.Items.Count<2) then
      FModeHelp.Caption:='Выберите основную копию вручную. Для выбора по приоритету нужны разные известные источники.'
    else
      FModeHelp.Caption:='Одна книга добавлена несколькими записями. Выберите запись, которую оставить, вручную или по порядку источников.';
  end;
  if FPlan.Ready then
    FStatus.Caption:=Format('Книг в этом списке: %d · Показано: %d–%d'+sLineBreak+
      'Отмечено: %d записей с файлами и %d копий файлов.',
      [ShownCount,Ord(ShownCount>0)*(FOffset+1),FOffset+Length(FPage),RegularMarks,LinkedMarks])
  else if FChanged then FStatus.Caption:='Чтобы обновить список, нажмите «Найти дубли».'
  else FStatus.Caption:='Поиск ещё не выполнен';
end;

procedure TfrmBookDuplicates.ApplySelected(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx; BackupFolder: string;
begin
  if not FPlan.Ready or FPlan.LinkedMode or (FPlan.SelectedCount=0) then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  BackupFolder:=TPath.Combine(TPath.Combine(Settings.DataPath,'Backups'),
    'books-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+TGUID.NewGuid.ToString);
  if MessageDlg(Format('Объединить групп: %d; убрать повторных записей: %d?'+#13#10+#13#10+
    'Останутся выбранные предпочтительные записи. Пути ко всем копиям, связи с источниками и сериями сохранятся. Файлы книг не удаляются.'+#13#10+#13#10+
    'Записи с личными данными и историей чтения защищены. Перед изменениями будет создана резервная копия:'+#13#10+'%s',
    [FPlan.SelectedCount,FPlan.SelectedRemovedCount,BackupFolder]),mtConfirmation,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  // The other results still hold a read snapshot of the same catalogue.
  FLinkedPlan.DiscardPreview;
  FLinkedResultsValid:=False;
  Worker:=TDuplicateScanWorker.Create(FPlan); Worker.FApply:=True; Worker.FBackup:=BackupFolder;
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Объединение повторных записей книг'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    FChanged:=FChanged or FPlan.Committed;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    FOffset:=0; LoadSources; RenderPage;
    FResultKind.Items[0]:='Отдельные записи';
    FResultKind.Items[1]:='Файлы одной записи';
    if FPlan.Committed then
      FDetails.Lines.Text:=Format('Объединение сохранено. Убрано повторных записей: %d.'+#13#10+
        'Файлы книг и личные данные сохранены.'+#13#10+'Резервная копия: %s'+#13#10+
        'Восстановление: Коллекция → Обслуживание каталога → Восстановить из резервной копии.',[FPlan.Removed,BackupFolder])
    else
    begin
      FDetails.Lines.Text:=Worker.FError+#13#10+'Чтобы продолжить, выполните поиск повторов заново.';
      if DirectoryExists(BackupFolder) then FDetails.Lines.Add('Папка резервной копии: '+BackupFolder);
    end;
  finally Progress.Free; Worker.Free; UpdateStatus; end;
end;

procedure TfrmBookDuplicates.DeleteSelectedFiles(Sender: TObject);
var Prompt: string; RegularCount, LinkedCount: Integer;
begin
  RegularCount:=FRegularPlan.SelectedRemovedCount;
  LinkedCount:=0;
  if FLinkedResultsValid then LinkedCount:=FLinkedPlan.SelectedRemovedCount;
  if RegularCount+LinkedCount=0 then Exit;
  Prompt:=Format('Удалить отмеченные файлы с диска?'+sLineBreak+
    'Дубли записей вместе с их файлами: %d. Лишние файлы у одной записи: %d.'+sLineBreak+sLineBreak+
    'Для каждой книги останется основная копия. Программа оставит книгу целиком, если запись изменилась, '+
    'содержит личные данные или с ней связаны файлы, которые вы не отметили.'+sLineBreak+
    'Связанные копии можно отметить в списке «Файлы одной записи». Удаление идёт в фоне. При остановке уже выполненное сохранится.',
    [RegularCount,LinkedCount]);
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  if MessageDlg(Prompt,mtWarning,[mbYes,mbNo],0,mbNo)<>mrYes then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  FDeleteInBatches:=True;
  ModalResult:=mrOk;
end;

function TfrmBookDuplicates.TakeDeletionOperation(const UserFile, JournalRoot: string): TBookDeletionOperation;
begin
  if not FDeleteInBatches then Exit(nil);
  if not FLinkedResultsValid then FLinkedPlan.DiscardPreview;
  Result:=TBookDeletionOperation.CreateDuplicateCleanup(FRegularPlan,FLinkedPlan,FCollectionInfo.ID,UserFile,JournalRoot);
  FPlan:=nil;
  FDeleteInBatches:=False;
end;

procedure TfrmBookDuplicates.Scan(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
begin
  FSearch.Enabled:=False;
  FResultKind.Enabled:=False;
  FLinkedResultsValid:=False;
  FLinkedPlan.DiscardPreview;
  Worker:=TDuplicateScanWorker.Create(FRegularPlan); Progress:=TImportProgressFormEx.Create(Self);
  try
    Worker.FLinkedPlan:=FLinkedPlan;
    Progress.Caption:='Поиск дублей книг'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    FLinkedResultsValid:=(Worker.FError='') and FLinkedPlan.Ready;
    FResultKind.Items[0]:=Format('Отдельные записи (%d)',[FRegularPlan.GroupCount]);
    FResultKind.Items[1]:=Format('Файлы одной записи (%d)',[FLinkedPlan.GroupCount]);
    FResultKind.ItemIndex:=Ord(FLinkedResultsValid and (FRegularPlan.GroupCount=0) and (FLinkedPlan.GroupCount>0));
    SwitchResults(FResultKind);
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError;
  finally Progress.Free; Worker.Free; FSearch.Enabled:=True; end;
end;

procedure TfrmBookDuplicates.SwitchResults(Sender: TObject);
begin
  if FLinkedResultsValid and (FResultKind.ItemIndex=1) then
    FPlan:=FLinkedPlan
  else
    FPlan:=FRegularPlan;
  FOffset:=0;
  FDetails.Clear;
  LoadSources;
  RenderPage;
  if FPlan.Ready and (FPlan.GroupCount=0) then
    FDetails.Lines.Text:=IfThen(FPlan.LinkedMode,'Дополнительных файлов не найдено.','Повторных карточек не найдено.');
end;

procedure TfrmBookDuplicates.ReadSourcePriority;
var Ini: TMemIniFile; Value: TJSONValue;
begin
  Ini:=TMemIniFile.Create(TPath.Combine(Settings.DataPath,'duplicate-source-priority.ini'),TEncoding.UTF8);
  try
    Value:=TJSONObject.ParseJSONValue(Ini.ReadString('Collections',IntToStr(FCollectionInfo.ID),'[]'));
    try
      if Value is TJSONArray then
        for var Item in TJSONArray(Value) do
          if (Item is TJSONString) and not MatchStr(Item.Value,FSavedPriority) then
            FSavedPriority:=FSavedPriority+[Item.Value];
    finally Value.Free; end;
  finally Ini.Free; end;
end;

procedure TfrmBookDuplicates.SaveSourcePriority;
var Ini: TMemIniFile; Values: TJSONArray;
begin
  Values:=TJSONArray.Create;
  try
    for var Source in FSourcePriority do Values.Add(Source);
    for var Source in FSavedPriority do
      if not MatchStr(Source,FSourcePriority) then Values.Add(Source);
    Ini:=TMemIniFile.Create(TPath.Combine(Settings.DataPath,'duplicate-source-priority.ini'),TEncoding.UTF8);
    try
      Ini.WriteString('Collections',IntToStr(FCollectionInfo.ID),Values.ToJSON);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  finally Values.Free; end;
  for var I:=High(FSavedPriority) downto 0 do
    if MatchStr(FSavedPriority[I],FSourcePriority) then Delete(FSavedPriority,I,1);
  FSavedPriority:=FSourcePriority+FSavedPriority;
end;

procedure TfrmBookDuplicates.LoadSources;
var Sources: TArray<string>;
begin
  Sources:=FPlan.Sources;
  FSource.Items.BeginUpdate;
  try
    FSource.Items.Clear;
    if FPlan.LinkedMode then FSource.Items.Add('Все источники');
    for var Name in Sources do FSource.Items.Add(Name);
    if FSource.Items.Count>0 then FSource.ItemIndex:=0;
  finally FSource.Items.EndUpdate; end;
  if FPlan.LinkedMode then Exit;
  FSourcePriority:=nil;
  for var Name in FSavedPriority do
    if MatchStr(Name,Sources) then FSourcePriority:=FSourcePriority+[Name];
  for var Name in Sources do
    if not MatchStr(Name,FSourcePriority) then FSourcePriority:=FSourcePriority+[Name];
end;

procedure TfrmBookDuplicates.SelectSource(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
  Dialog: TDuplicateSourcePriorityForm;
begin
  if not FSelectSource.Enabled then Exit;
  if not FPlan.LinkedMode then
  begin
    Dialog:=TDuplicateSourcePriorityForm.CreateForSources(Self,FSourcePriority);
    try
      if Dialog.ShowModal<>mrOk then Exit;
      FSourcePriority:=Dialog.ReadPriority;
      try
        SaveSourcePriority;
      except
        on E:Exception do
          MessageDlg('Не удалось запомнить приоритет источников. В этом окне выбор будет применён.'+
            sLineBreak+E.Message,mtWarning,[mbOK],0);
      end;
    finally Dialog.Free; end;
  end;
  Worker:=TDuplicateScanWorker.Create(FPlan);
  if FPlan.LinkedMode then
  begin
    Worker.FSelectLinkedFiles:=True;
    if FSource.ItemIndex>0 then Worker.FSourceName:=FSource.Text;
  end
  else Worker.FSourcePriority:=FSourcePriority;
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Выбор повторных записей по источнику'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    RenderPage;
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError
    else if FPlan.LinkedMode then FDetails.Lines.Text:=Format('Добавлено отметок: %d. Всего отмечено дополнительных файлов: %d.'+sLineBreak+
      'Можно снять отметку с любого файла перед удалением.',[Worker.FSelected,FPlan.SelectedRemovedCount])
    else FDetails.Lines.Text:=Format('Автоматически отмечено книг: %d.'+sLineBreak+
      'Порядок источников: %s.'+sLineBreak+
      'Проверьте выбор. Затем можно объединить записи или удалить повторные копии с диска.'+sLineBreak+
      'Включите «Только книги без отметок», чтобы просмотреть пропущенные книги.',
      [Worker.FSelected,string.Join(' → ',FSourcePriority)]);
  finally Progress.Free; Worker.Free; UpdateStatus; end;
end;

procedure TfrmBookDuplicates.ClearSelection(Sender: TObject);
begin
  FRegularPlan.ClearSelection;
  FLinkedPlan.ClearSelection;
  RenderPage;
end;

procedure TfrmBookDuplicates.FilterGroups(Sender: TObject);
begin
  FOffset:=0;
  RenderPage;
end;

function TfrmBookDuplicates.VisibleGroupCount: Integer;
begin
  Result:=FPlan.GroupCount;
  if FUnmarkedOnly.Checked and not FPlan.LinkedMode then
    Dec(Result,FPlan.SelectedCount);
end;

procedure TfrmBookDuplicates.RenderPage;
var Item: TListItem; ShownCount: Integer;
begin
  if FPlan.Ready and (FSource.Items.Count=0) then LoadSources;
  ShownCount:=VisibleGroupCount;
  if FOffset>=ShownCount then FOffset:=(Max(0,ShownCount-1) div 50)*50;
  FUpdating:=True; FGroups.Items.BeginUpdate;
  try
    FGroups.Items.Clear; FCopies.Items.Clear; FBooks:=nil; FPage:=nil; FUseGroup.Checked:=False;
    FCopies.Checkboxes:=FPlan.LinkedMode;
    if FPlan.Ready then FPage:=FPlan.Groups(FOffset,50,FUnmarkedOnly.Checked);
    for var Group in FPage do
    begin
      Item:=FGroups.Items.Add; Item.Caption:=Group.Title; Item.SubItems.Add(IntToStr(Group.Count));
      Item.SubItems.Add(IfThen(Group.Selected,IntToStr(Group.SelectedCopies),'—'));
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
var CopyItem: TListItem; Preferred: Integer; IsPrimary: Boolean;
begin
  if FUpdating or not Selected then Exit;
  FUpdating:=True; FCopies.Items.BeginUpdate;
  try
    FCopies.Items.Clear; FBooks:=nil; FUseGroup.Checked:=False; Preferred:=-1;
    try FBooks:=FPlan.Books(FPage[Item.Index].ID);
    except on E: Exception do begin FDetails.Lines.Text:=E.Message; Exit; end; end;
    for var I:=0 to High(FBooks) do
    begin
      if FPlan.LinkedMode then IsPrimary:=FBooks[I].CopyKey=''
      else IsPrimary:=FBooks[I].Book.BookKey.BookID=FPage[Item.Index].KeepID;
      CopyItem:=FCopies.Items.Add;
      CopyItem.SubItems.Add(IfThen(FBooks[I].SourceName<>'',FBooks[I].SourceName,
        IfThen(FPlan.LinkedMode and IsPrimary,'Основная копия','Неизвестен')));
      CopyItem.SubItems.Add(FBooks[I].Book.Title); CopyItem.SubItems.Add(FormatFloat('0.0',FBooks[I].Book.Size/1024.0)+' КБ');
      CopyItem.SubItems.Add(IfThen(FBooks[I].HasPersonalData,'Есть','—'));
      CopyItem.SubItems.Add(FBooks[I].Book.Folder+' / '+FBooks[I].Book.FileName+FBooks[I].Book.FileExt);
      CopyItem.SubItems.Add(TAuthorsHelper.GetList(FBooks[I].Book.Authors));
      if FPlan.LinkedMode then CopyItem.Checked:=FBooks[I].Selected;
      if IsPrimary then Preferred:=I;
    end;
    if FPlan.LinkedMode then RefreshLinkedMarks else FUseGroup.Checked:=FPage[Item.Index].Selected;
    UpdateCopyStates;
  finally FCopies.Items.EndUpdate; FUpdating:=False; UpdateStatus; end;
  if Preferred>=0 then FCopies.Items[Preferred].Selected:=True;
end;

procedure TfrmBookDuplicates.UpdateCopyStates;
var Group: TDuplicateGroup; Primary, Marked: Boolean;
begin
  if not Assigned(FGroups.Selected) then Exit;
  Group:=FPage[FGroups.Selected.Index];
  for var I:=0 to High(FBooks) do
  begin
    if FPlan.LinkedMode then
    begin
      Primary:=FBooks[I].CopyKey='';
      Marked:=FBooks[I].Selected;
    end
    else
    begin
      Primary:=FBooks[I].Book.BookKey.BookID=Group.KeepID;
      Marked:=Group.Selected and not Primary;
    end;
    if Primary then FCopies.Items[I].Caption:='Основная'
    else FCopies.Items[I].Caption:=IfThen(Marked,'К удалению','—');
  end;
end;

procedure TfrmBookDuplicates.SelectCopy(Sender: TObject; Item: TListItem; Selected: Boolean);
var Book: TDuplicateBook;
begin
  if FUpdating or not Selected then Exit;
  Book:=FBooks[Item.Index];
  if FPlan.LinkedMode then
  begin
    FDetails.Lines.Text:=IfThen(Book.CopyKey='','Основная копия сохранится.','Дополнительная копия этой книги.')+sLineBreak+
      'Название: '+Book.Book.Title+sLineBreak+'Источник: '+Book.SourceName+sLineBreak+
      'Папка коллекции: '+Book.Book.CollectionRoot+sLineBreak+'Папка / архив: '+Book.Book.Folder+sLineBreak+
      'Файл: '+Book.Book.FileName+Book.Book.FileExt;
    Exit;
  end;
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

procedure TfrmBookDuplicates.RefreshLinkedMarks;
var Count, Marked, Index: Integer; Updating: Boolean;
begin
  if not Assigned(FGroups.Selected) then Exit;
  Count:=0; Marked:=0;
  for var Entry in FBooks do
    if Entry.CopyKey<>'' then
    begin
      Inc(Count);
      if Entry.Selected then Inc(Marked);
    end;
  Index:=FGroups.Selected.Index; FPage[Index].Selected:=Marked>0;
  FPage[Index].SelectedCopies:=Marked;
  FGroups.Selected.SubItems[1]:=IfThen(Marked>0,IntToStr(Marked),'—');
  Updating:=FUpdating; FUpdating:=True;
  try FUseGroup.Checked:=(Count>0) and (Count=Marked); finally FUpdating:=Updating; end;
end;

procedure TfrmBookDuplicates.CheckCopy(Sender: TObject; Item: TListItem);
begin
  if FUpdating or not FPlan.LinkedMode or (Item.Index<0) or (Item.Index>=Length(FBooks)) then Exit;
  var Index:=Item.Index;
  FUpdating:=True;
  try
    try
      if FBooks[Index].CopyKey<>'' then
      begin
        FPlan.ChooseCopy(FBooks[Index].CopyKey,Item.Checked);
        FBooks[Index].Selected:=Item.Checked;
      end;
    except on E:Exception do MessageDlg(E.Message,mtInformation,[mbOK],0); end;
    if Item.Checked<>FBooks[Index].Selected then Item.Checked:=FBooks[Index].Selected;
    RefreshLinkedMarks;
    UpdateCopyStates;
  finally FUpdating:=False; end;
  UpdateStatus;
end;

procedure TfrmBookDuplicates.KeepCopy(Sender: TObject);
var Index, KeepID: Integer;
begin
  if FPlan.LinkedMode or not Assigned(FGroups.Selected) or not Assigned(FCopies.Selected) then Exit;
  Index:=FGroups.Selected.Index; KeepID:=FBooks[FCopies.Selected.Index].Book.BookKey.BookID;
  try
    FPlan.Choose(FPage[Index].ID,KeepID,FPage[Index].Selected); FPage[Index].KeepID:=KeepID;
    FPage[Index].Title:=FBooks[FCopies.Selected.Index].Book.Title;
    FGroups.Selected.Caption:=FPage[Index].Title;
    UpdateCopyStates;
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
    if FPlan.LinkedMode then
    begin
      SelectGroup(FGroups,FGroups.Selected,True);
      Exit;
    end;
    FPage[Index].Selected:=FUseGroup.Checked;
    FPage[Index].SelectedCopies:=Ord(FUseGroup.Checked)*(FPage[Index].Count-1);
    FGroups.Selected.SubItems[1]:=IfThen(FUseGroup.Checked,IntToStr(FPage[Index].SelectedCopies),'—');
    UpdateCopyStates;
    if FUnmarkedOnly.Checked then
    begin
      RenderPage;
      Exit;
    end;
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
