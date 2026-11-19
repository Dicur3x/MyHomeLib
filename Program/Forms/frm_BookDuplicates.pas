unit frm_BookDuplicates;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_Interfaces,
  unit_BookDuplicates, unit_BookDeletionBinding, unit_BookDeletionOperation, unit_Globals, frm_CatalogSources,
  unit_ContextToolGuide;

type
  TfrmBookDuplicates = class(TSourceDialogForm)
  private
    FPlan, FRegularPlan, FLinkedPlan: TBookDuplicatePlan;
    FUnified: TUnifiedDuplicateView;
    FUnifiedBooks: TArray<TUnifiedDuplicateCopy>;
    FGroups, FCopies: TListView;
    FDetails: TMemo;
    FSearch, FPrevious, FNext, FKeep, FApply, FDelete, FSelectSource, FClearSelection: TButton;
    FCollectionInfo: TCollectionInfo;
    FSource, FResultKind: TComboBox;
    FShowDetails: TButton;
    FUseGroup, FUnmarkedOnly: TCheckBox;
    FStatus, FModeHelp: TLabel;
    FPage: TArray<TDuplicateGroup>;
    FSourcePriority, FSavedPriority: TArray<string>;
    FBooks: TArray<TDuplicateBook>;
    FOffset: Integer;
    FUpdating, FChanged, FDeleteInBatches, FLinkedResultsValid, FDetailed: Boolean;
    FBeforeApply: TNotifyEvent;
    FToolGuide:TContextToolGuide;
    procedure Scan(Sender: TObject);
    procedure SwitchResults(Sender: TObject);
    procedure ToggleDetails(Sender: TObject);
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
    function ConfirmSelection(const Summary: string; DeleteFiles: Boolean): Boolean;
    procedure UpdateStatus;
    procedure SelectSource(Sender: TObject);
    procedure ClearSelection(Sender: TObject);
    procedure LoadSources;
    procedure FilterGroups(Sender: TObject);
    function VisibleGroupCount: Integer;
    function GroupExplanation(const Group: TDuplicateGroup): string;
  protected
    procedure DoShow; override;
    procedure DoHide; override;
    procedure ConstrainedResize(var MinWidth, MinHeight, MaxWidth, MaxHeight: Integer); override;
  public
    constructor CreateForCollection(AOwner: TComponent; const Collection: IBookCollection);
    destructor Destroy; override;
    procedure RenderPage;
    function TakeDeletionOperation(const UserFile, JournalRoot: string): TBookDeletionOperation;
    property Plan: TBookDuplicatePlan read FPlan;
    property LinkedPlan:TBookDuplicatePlan read FLinkedPlan;
    property CatalogChanged: Boolean read FChanged;
    property OnBeforeApply: TNotifyEvent read FBeforeApply write FBeforeApply;
  end;

implementation

uses Winapi.Windows, System.SysUtils, System.IOUtils, System.Variants, System.StrUtils, System.Math, System.JSON, System.IniFiles, Vcl.Controls,
  Vcl.ExtCtrls, Vcl.Dialogs, unit_Settings, unit_Consts, unit_CollectionWorkerThread,
  frm_ImportProgressFormEx, frm_BuiltinReader, dm_user, unit_AtomicIniFile, unit_MHLTheme,
  System.Generics.Collections, System.Generics.Defaults, SQLiteWrap, unit_BookCompressionPlanStore;

const
  DuplicateMinWidth = 900;
  DuplicateMinHeight = 580;
  DuplicateReviewPageSize = 50;

type
  TDuplicateReviewSource = reference to procedure(Offset, Limit: Integer; const Visit: TDuplicatePairVisitor);

  TDuplicateSelectionForm = class(TSourceDialogForm)
  private
    FSource: TDuplicateReviewSource;
    FSummary: string;
    FDetails: TMemo;
    FPage: TLabel;
    FBack, FNext: TButton;
    FOffset, FTotal: Integer;
    FDeleteFiles: Boolean;
    procedure ShowPage;
    procedure ChangePage(Sender: TObject);
    procedure SaveReport(Sender: TObject);
    function PairText(const Kept, Selected: TBookRecord): string;
  public
    constructor CreateForSelection(Owner: TCustomForm; const Summary, Action: string; Total: Integer;
      DeleteFiles: Boolean; const Source: TDuplicateReviewSource);
  end;

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
    FUnified: TUnifiedDuplicateView;
    FBackup: string;
    FSourceName: string;
    FSourcePriority, FSavedPriority: TArray<string>;
    FPriorityApplied: Boolean;
    procedure ApplySourcePriority;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TBookDuplicatePlan);
  end;

constructor TDuplicateSourcePriorityForm.CreateForSources(AOwner: TComponent;
  const Sources: TArray<string>);
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
  HintLabel.Caption:='Поставьте любимый источник первым. Если в нём нет книги, HomeLibre проверит следующие по списку.';
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
  Button:=AddButton('Выбрать копии',242,255,170);
  Button.Default:=True;
  Button.ModalResult:=mrOk;
  Button:=AddButton('Отмена',418,255,110);
  Button.Cancel:=True;
  Button.ModalResult:=mrCancel;
  ScaleForPPI(PopupParent.CurrentPPI);
  var Widest:=0;
  for var Source in Sources do Widest:=System.Math.Max(Widest,FList.Canvas.TextWidth(Source));
  if Widest>FList.ClientWidth then FList.ScrollWidth:=Widest+ScaleValue(12);
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

function AvailableDuplicatePriorities(Regular, Linked: TBookDuplicatePlan): TArray<string>;
begin
  Result:=Regular.PrioritySources;
  if Assigned(Linked) then
    for var Name in Linked.PrioritySources do
      if not MatchStr(Name,Result) then Result:=Result+[Name];
end;

procedure TDuplicateScanWorker.ApplySourcePriority;
var LinkedSelected: Integer;
begin
  SetComment('Выбор повторов по порядку источников…');
  if Assigned(FLinkedPlan) then
    FPlan.SelectCombinedSourcePriority(FLinkedPlan,FSourcePriority,
      function: Boolean begin Result:=Canceled; end,LinkedSelected)
  else FPlan.SelectSourcePriority(FSourcePriority,
    function: Boolean begin Result:=Canceled; end);
  FPriorityApplied:=True;
end;

procedure TDuplicateScanWorker.WorkFunction;
begin
  try
    SetProgressHint(pbstMarquee); SetComment('Поиск дублей книг…');
    if Length(FSourcePriority)>0 then ApplySourcePriority
    else if FSelectLinkedFiles then
    begin
      SetComment('Отметка дополнительных файлов…');
      FPlan.SelectSource(FSourceName,function: Boolean begin Result:=Canceled; end);
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
        begin SetComment(Format('Проверено книг в каталоге: %d',[Current])); end);
      if Assigned(FLinkedPlan) and not Canceled then
      begin
        SetComment('Поиск книг с несколькими файлами…');
        FLinkedPlan.PreviewLinked(function: Boolean begin Result:=Canceled; end,
          procedure(Current,Total: Integer)
          begin SetComment(Format('Проверено ссылок на файлы: %d',[Current])); end);
        if not Canceled then FPlan.AlignPrioritySources(FLinkedPlan);
      end;
      if not Canceled and (Length(FSavedPriority)>=2) then
      begin
        var Available:=AvailableDuplicatePriorities(FPlan,FLinkedPlan);
        for var Name in FSavedPriority do
          if MatchStr(Name,Available) then FSourcePriority:=FSourcePriority+[Name];
        if Length(FSourcePriority)>=2 then ApplySourcePriority;
      end;
    end;
    if Assigned(FUnified) and not Canceled and FPlan.Ready and FLinkedPlan.Ready then
    begin
      SetComment('Объединение найденных копий в один список…');
      if FUnified.Ready then FUnified.RefreshMarks
      else FUnified.Build(function:Boolean begin Result:=Canceled; end,
        procedure(Current,Total:Integer)
        begin SetComment(Format('Проверено книг с копиями: %d',[Current])); end);
    end;
  except
    on E: Exception do
    begin
      if Canceled then FError:='Операция отменена.' else FError:=E.Message;
      if FPriorityApplied then FError:=FError+sLineBreak+'Отметки по порядку источников сохранены.';
    end;
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
  Constraints.MinWidth:=DuplicateMinWidth; Constraints.MinHeight:=DuplicateMinHeight;
  FCollectionInfo:=SystemDB.GetCollectionInfo(Collection.CollectionID);
  FRegularPlan:=NewPlan;
  FLinkedPlan:=NewPlan;
  FPlan:=FRegularPlan;
  FUnified:=TUnifiedDuplicateView.Create(FRegularPlan,FLinkedPlan);
  ReadSourcePriority;
  Top:=TPanel.Create(Self); Top.Parent:=Self; Top.Align:=alTop; Top.Height:=135; Top.BevelOuter:=bvNone;
  LabelText:=TLabel.Create(Self); LabelText.Parent:=Top; LabelText.AutoSize:=False;
  LabelText.Name:='DuplicateIntro';
  LabelText.SetBounds(12,10,1016,24); LabelText.Anchors:=[akLeft,akTop,akRight]; LabelText.WordWrap:=True;
  LabelText.Caption:='Найдите дубли и выберите, из каких источников оставить книги. HomeLibre отметит лишние копии.';
  FSearch:=TButton.Create(Self); FSearch.Parent:=Top; FSearch.Name:='btnFindBookDuplicates';
  FSearch.SetBounds(12,36,148,30); FSearch.Caption:='Найти дубли'; FSearch.OnClick:=Scan;
  FShowDetails:=TButton.Create(Self); FShowDetails.Parent:=Top; FShowDetails.Name:='btnDuplicateDetails';
  FShowDetails.SetBounds(172,36,155,30); FShowDetails.OnClick:=ToggleDetails;
  FResultKind:=TComboBox.Create(Self); FResultKind.Parent:=Top; FResultKind.Name:='cbDuplicateResultKind';
  FResultKind.SetBounds(339,38,280,28); FResultKind.Style:=csDropDownList;
  FResultKind.Items.Add('Книги, добавленные несколько раз');
  FResultKind.Items.Add('Книги с несколькими файлами');
  FResultKind.ItemIndex:=0; FResultKind.OnChange:=SwitchResults;
  FStatus:=TLabel.Create(Self); FStatus.Parent:=Top; FStatus.AutoSize:=False;
  FStatus.SetBounds(172,34,856,38); FStatus.Anchors:=[akLeft,akTop,akRight]; FStatus.WordWrap:=True;
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
  FApply.SetBounds(316,10,211,30); FApply.Caption:='Объединить в каталоге…'; FApply.OnClick:=ApplySelected;
  FDelete:=TButton.Create(Self); FDelete.Parent:=Bottom; FDelete.Name:='btnDeleteDuplicateFiles';
  FDelete.SetBounds(539,10,212,30); FDelete.Caption:='Удалить копии с диска…'; FDelete.OnClick:=DeleteSelectedFiles;
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
  FUseGroup.SetBounds(12,36,315,22);
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
  LabelText.Width:=974;
  FToolGuide:=TContextToolGuide.CreateForTool(Self,Top,'book-duplicates','Как выбрать и убрать дубли',
    'Проверьте сохраняемую копию перед удалением. Одного совпадения названия недостаточно.',
    '1. Нажмите «Найти дубли». Одна строка слева — книга, справа — её копии и пути.'+sLineBreak+
    '2. Выберите, какие источники предпочитать, или оставьте нужную копию вручную. Разные издания и размеры могут отличаться.'+sLineBreak+
    '3. Проверьте решения «Оставить» и «Удалить» для каждой копии перед запуском.'+sLineBreak+
    '«Объединить в каталоге» убирает повторные записи и сохраняет файлы. «Удалить копии с диска» удаляет отмеченные файлы; соседние книги в общем архиве сохраняются.'+sLineBreak+
    'Остановка завершает текущий архив. Для незаменимых книг нужна отдельная резервная копия.',
    110,'duplicates');
  FToolGuide.Name:='DuplicatesContextGuide';
  UpdateStatus; ScaleForPPI(Screen.PixelsPerInch);
end;

destructor TfrmBookDuplicates.Destroy;
begin
  FUnified.Free;
  FLinkedPlan.Free;
  FRegularPlan.Free;
  inherited;
end;

procedure TfrmBookDuplicates.DoShow;
begin inherited; FToolGuide.FirstUse; end;

procedure TfrmBookDuplicates.DoHide;
begin if Assigned(FToolGuide) then FToolGuide.Hide; inherited; end;

procedure TfrmBookDuplicates.ConstrainedResize(var MinWidth, MinHeight, MaxWidth, MaxHeight: Integer);
begin
  inherited;
  // The styled frame can restore an old pixel minimum after a DPI change.
  // Keep the minimum needed by the content at its current layout scale.
  MinWidth:=Max(MinWidth,MulDiv(DuplicateMinWidth,PixelsPerInch,96));
  MinHeight:=Max(MinHeight,MulDiv(DuplicateMinHeight,PixelsPerInch,96));
end;

procedure TfrmBookDuplicates.UpdateStatus;
var Linked: Boolean; ShownCount, RegularMarks, LinkedMarks: Integer;
begin
  if Assigned(FUnified) and FUnified.Ready then
  begin
    FShowDetails.Visible:=False; FResultKind.Visible:=False; FSource.Visible:=False;
    FStatus.Left:=ScaleValue(172);
    FStatus.Width:=FStatus.Parent.ClientWidth-FStatus.Left-ScaleValue(12);
    ShownCount:=VisibleGroupCount;
    FStatus.Caption:=Format('Книг с копиями: %d · Показано: %d–%d'+sLineBreak+'Выбрано книг: %d',
      [FUnified.GroupCount,Ord(ShownCount>0)*(FOffset+1),FOffset+Length(FPage),FUnified.SelectedCount]);
    FPrevious.Enabled:=FOffset>0; FNext.Enabled:=FOffset+50<ShownCount;
    FKeep.Visible:=True;
    FKeep.Enabled:=Assigned(FCopies.Selected) and (FCopies.Selected.Index<Length(FUnifiedBooks));
    if FKeep.Enabled then FKeep.Enabled:=not FUnifiedBooks[FCopies.Selected.Index].Kept;
    FUseGroup.Enabled:=Assigned(FGroups.Selected); FUseGroup.Top:=ScaleValue(36);
    FUseGroup.Caption:='Убрать остальные копии этой книги';
    FApply.Visible:=True; FApply.Enabled:=FRegularPlan.SelectedCount>0;
    FDelete.Left:=FApply.Left+FApply.Width+ScaleValue(12);
    FDelete.Enabled:=(FRegularPlan.SelectedRemovedCount+FLinkedPlan.SelectedRemovedCount)>0;
    FClearSelection.Enabled:=FDelete.Enabled;
    FUnmarkedOnly.Visible:=True; FUnmarkedOnly.Enabled:=True;
    FSelectSource.Left:=ScaleValue(12); FSelectSource.Anchors:=[akTop,akLeft];
    FSelectSource.Caption:='Выбрать, что оставить…';
    FSelectSource.Enabled:=(ShownCount>0) and (Length(FSourcePriority)>=2);
    FModeHelp.Caption:='Одна строка — одна книга. Справа — её копии. Оставьте одну по порядку источников или вручную.';
    Exit;
  end;
  FShowDetails.Visible:=False; FResultKind.Visible:=False;
  Linked:=FPlan.LinkedMode;
  FShowDetails.Visible:=False;
  FShowDetails.Caption:=IfThen(FDetailed,'Свернуть','Подробности…');
  FResultKind.Visible:=False;
  FStatus.Left:=ScaleValue(IfThen(FResultKind.Visible,631,339));
  FStatus.Width:=FStatus.Parent.ClientWidth-FStatus.Left-ScaleValue(12);
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
  FUseGroup.Caption:=IfThen(Linked,'Отметить все лишние копии этой книги','Отметить остальные копии к удалению');
  FApply.Visible:=not Linked;
  if Linked then FDelete.Left:=FApply.Left else FDelete.Left:=FApply.Left+FApply.Width+ScaleValue(12);
  RegularMarks:=FRegularPlan.SelectedRemovedCount;
  LinkedMarks:=0;
  if FLinkedResultsValid then LinkedMarks:=FLinkedPlan.SelectedRemovedCount;
  FDelete.Enabled:=RegularMarks+LinkedMarks>0;
  FApply.Enabled:=not Linked and (RegularMarks>0);
  FSource.Enabled:=FPlan.Ready and (FSource.Items.Count>0);
  FSource.Visible:=Linked and FDetailed;
  FUnmarkedOnly.Visible:=not Linked;
  FUnmarkedOnly.Enabled:=FPlan.Ready;
  FSelectSource.Left:=IfThen(FSource.Visible,FSource.Left+FSource.Width+ScaleValue(12),ScaleValue(12));
  if FSource.Visible then FSelectSource.Anchors:=[akTop,akRight] else FSelectSource.Anchors:=[akTop,akLeft];
  if FSource.Visible then FSelectSource.Caption:='Отметить копии из источника'
  else if Linked and (Length(FSourcePriority)<2) then FSelectSource.Caption:='Отметить лишние копии'
  else FSelectSource.Caption:='Выбрать, что оставить…';
  FSelectSource.Enabled:=FPlan.Ready and
    ((Linked and (FPlan.GroupCount>0) and (FSource.ItemIndex>=0)) or (not Linked and (Length(FSourcePriority)>=2)));
  FClearSelection.Enabled:=FDelete.Enabled;
  if Linked then
  begin
    FModeHelp.Caption:='Основной файл каждой книги останется. Вы можете отметить лишние файлы сразу или выбрать их справа.';
  end
  else
  begin
    if FPlan.Ready and (Length(FSourcePriority)<2) then
      FModeHelp.Caption:='Выберите справа копию, которую хотите оставить, и отметьте остальные.'
    else if FPlan.Ready then
      FModeHelp.Caption:='Укажите, копии из каких источников оставить, или выберите копию вручную.'
    else FModeHelp.Caption:='Поиск сравнит книги в текущей коллекции.';
  end;
  if FPlan.Ready then
    FStatus.Caption:=Format('В этом списке: %d · Показано: %d–%d'+sLineBreak+'Отмечено к удалению: %d',
      [ShownCount,Ord(ShownCount>0)*(FOffset+1),FOffset+Length(FPage),RegularMarks+LinkedMarks])
  else if FChanged then FStatus.Caption:='Чтобы обновить список, нажмите «Найти дубли».'
  else FStatus.Caption:='Поиск ещё не выполнен';
end;

function DuplicateReviewArchive(const Book: TBookRecord): string;
begin
  if Book.GetBookFormat in [bfFb2Archive, bfRawArchive] then Result := Book.GetBookContainer
  else Result := 'Отдельные файлы';
end;

function DuplicateReviewPath(const Book: TBookRecord): string;
begin
  Result := Book.GetBookFileName;
  if Book.GetBookFormat in [bfFb2Archive, bfRawArchive] then
    Result := Result + ' → ' + Book.FileName + Book.FileExt;
end;

constructor TDuplicateSelectionForm.CreateForSelection(Owner: TCustomForm; const Summary, Action: string;
  Total: Integer; DeleteFiles: Boolean; const Source: TDuplicateReviewSource);
var TopPanel, Footer: TPanel; Intro: TLabel; CancelButton: TButton;
  function AddButton(const Name, Caption: string; X, Width: Integer; Click: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self); Result.Parent := Footer; Result.Name := Name;
    Result.Caption := Caption; Result.SetBounds(X, 10, Width, 30); Result.OnClick := Click;
  end;
begin
  inherited CreateNew(Owner);
  Name := 'DuplicateSelectionConfirmation';
  Caption := Action;
  Position := poOwnerFormCenter; PopupMode := pmExplicit; PopupParent := Owner;
  Font.Name := 'Segoe UI'; Font.Size := 9; BorderStyle := bsSizeable;
  ClientWidth := 820; ClientHeight := 490; Constraints.MinWidth := 690; Constraints.MinHeight := 420;
  FSource := Source; FTotal := Total; FSummary := Summary; FDeleteFiles := DeleteFiles;
  TopPanel := TPanel.Create(Self); TopPanel.Parent := Self; TopPanel.Align := alTop;
  TopPanel.Height := 132; TopPanel.BevelOuter := bvNone;
  Intro := TLabel.Create(Self); Intro.Parent := TopPanel; Intro.Align := alClient;
  Intro.AlignWithMargins := True; Intro.Margins.SetBounds(12, 8, 12, 4);
  Intro.AutoSize := False; Intro.WordWrap := True; Intro.ShowAccelChar := False; Intro.Caption := Summary;
  FPage := TLabel.Create(Self); FPage.Parent := TopPanel; FPage.Align := alBottom;
  FPage.AlignWithMargins := True; FPage.Margins.SetBounds(12, 0, 12, 4);
  Footer := TPanel.Create(Self); Footer.Parent := Self; Footer.Align := alBottom;
  Footer.Height := 50; Footer.BevelOuter := bvNone;
  FDetails := TMemo.Create(Self); FDetails.Parent := Self; FDetails.Name := 'DuplicateReviewPairs';
  FDetails.AlignWithMargins := True; FDetails.Margins.SetBounds(12, 0, 12, 0);
  FDetails.Align := alClient; FDetails.ReadOnly := True; FDetails.ScrollBars := ssVertical;
  FBack := AddButton('DuplicateReviewPrevious', 'Назад', 12, 74, ChangePage); FBack.Tag := -1;
  FNext := AddButton('DuplicateReviewNext', 'Дальше', 94, 80, ChangePage); FNext.Tag := 1;
  FBack.Visible := Total > DuplicateReviewPageSize; FNext.Visible := FBack.Visible;
  AddButton('DuplicateSaveReview', 'Сохранить список…', IfThen(FBack.Visible, 182, 12), 152, SaveReport);
  var ConfirmButton := AddButton('DuplicateConfirmAction', Action, 500, 174, nil);
  ConfirmButton.Anchors := [akTop, akRight]; ConfirmButton.ModalResult := mrYes;
  CancelButton := AddButton('DuplicateCancelAction', 'Отмена', 686, 122, nil);
  CancelButton.Anchors := [akTop, akRight]; CancelButton.ModalResult := mrCancel;
  CancelButton.Cancel := True; CancelButton.Default := True;
  ActiveControl := CancelButton;
  ScaleForPPI(Owner.CurrentPPI);
  ApplyMHLControlTheme(Self);
  ShowPage;
end;

function TDuplicateSelectionForm.PairText(const Kept, Selected: TBookRecord): string;
begin
  Result := Trim(Selected.Title.Replace(#13, ' ').Replace(#10, ' ')) + sLineBreak +
    '  Остаётся — ' + DuplicateReviewPath(Kept) + sLineBreak +
    IfThen(FDeleteFiles, '  К удалению — ', '  Повторная запись — ') + DuplicateReviewPath(Selected);
end;

procedure TDuplicateSelectionForm.ShowPage;
type Row = TPair<string, string>;
var Values: TList<Row>; LastArchive: string;
begin
  Values := TList<Row>.Create;
  try
    FSource(FOffset, DuplicateReviewPageSize, procedure(const Kept, Selected: TBookRecord)
      begin Values.Add(Row.Create(DuplicateReviewArchive(Selected), PairText(Kept, Selected))); end);
    Values.Sort(TComparer<Row>.Construct(
      function(const A, B: Row): Integer begin Result := CompareText(A.Key, B.Key); end));
    FDetails.Lines.BeginUpdate;
    try
      FDetails.Clear; LastArchive := '';
      for var Item in Values do
      begin
        if not SameText(LastArchive, Item.Key) then
        begin
          if LastArchive <> '' then FDetails.Lines.Add('');
          LastArchive := Item.Key;
          FDetails.Lines.Add(LastArchive);
        end;
        FDetails.Lines.Add(Item.Value);
      end;
      FDetails.SelStart := 0;
    finally FDetails.Lines.EndUpdate; end;
  finally Values.Free; end;
  FPage.Caption := Format('Позиции %d–%d из %d', [FOffset + 1, Min(FTotal, FOffset + DuplicateReviewPageSize), FTotal]);
  FBack.Enabled := FOffset > 0;
  FNext.Enabled := FOffset + DuplicateReviewPageSize < FTotal;
end;

procedure TDuplicateSelectionForm.ChangePage(Sender: TObject);
begin
  Inc(FOffset, TButton(Sender).Tag * DuplicateReviewPageSize);
  ShowPage;
end;

procedure TDuplicateSelectionForm.SaveReport(Sender: TObject);
var Dialog: TSaveDialog; Store: TCompressionPlanStore; DB: TSQLiteDatabase; SavedCursor: TCursor;
begin
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.Title := 'Сохранить список копий'; Dialog.FileName := 'Выбранные дубли.txt';
    Dialog.DefaultExt := 'txt'; Dialog.Filter := 'Текстовые файлы (*.txt)|*.txt';
    Dialog.Options := Dialog.Options + [ofOverwritePrompt, ofPathMustExist];
    if not Dialog.Execute(Handle) then Exit;
    SavedCursor := Screen.Cursor; Screen.Cursor := crHourGlass;
    try
      Store := TCompressionPlanStore.Create(Settings.WorkPath);
      try
        DB := Store.DB;
        DB.ExecSQL('BEGIN');
        try
          DB.ExecSQL('CREATE TABLE Selection(ID INTEGER PRIMARY KEY,Archive TEXT,Description TEXT)');
          var Insert := DB.NewQuery('INSERT INTO Selection(Archive,Description) VALUES(?,?)');
          try
            FSource(0, -1, procedure(const Kept, Selected: TBookRecord)
              begin
                Insert.SetParam(0, DuplicateReviewArchive(Selected));
                Insert.SetParam(1, PairText(Kept, Selected));
                Insert.ExecSQL; Insert.Reset;
              end);
          finally Insert.Free; end;
          DB.ExecSQL('CREATE INDEX SelectionArchive ON Selection(Archive COLLATE NOCASE,ID)');
          DB.Commit;
        except
          DB.Rollback;
          raise;
        end;
        Store.Seal;
        SaveGeneratedTextAtomically(Dialog.FileName, procedure(Writer: TStreamWriter)
          begin
            Writer.WriteLine(FSummary); Writer.WriteLine('');
            var Query := Store.DB.NewQuery('SELECT Archive,Description FROM Selection ORDER BY Archive COLLATE NOCASE,ID');
            try
              Query.Open;
              var LastArchive := '';
              while not Query.Eof do
              begin
                if not SameText(LastArchive, Query.FieldAsString(0)) then
                begin
                  if LastArchive <> '' then Writer.WriteLine('');
                  LastArchive := Query.FieldAsString(0); Writer.WriteLine(LastArchive);
                end;
                Writer.WriteLine(Query.FieldAsString(1)); Query.Next;
              end;
            finally Query.Free; end;
          end);
      finally Store.Free; end;
    finally Screen.Cursor := SavedCursor; end;
  finally Dialog.Free; end;
end;

function TfrmBookDuplicates.ConfirmSelection(const Summary: string; DeleteFiles: Boolean): Boolean;
var Form: TDuplicateSelectionForm; RegularCount, LinkedCount: Integer;
  Promotions: TBookDuplicatePlan; Action: string;
begin
  RegularCount := FRegularPlan.SelectedRemovedCount;
  LinkedCount := 0; Promotions := nil;
  if DeleteFiles and FLinkedResultsValid then
  begin
    LinkedCount := FLinkedPlan.SelectedRemovedCount;
    Promotions := FLinkedPlan;
  end;
  if DeleteFiles then Action := 'Удалить копии' else Action := 'Объединить записи';
  Form := TDuplicateSelectionForm.CreateForSelection(Self, Summary, Action, RegularCount + LinkedCount, DeleteFiles,
    procedure(Offset, Limit: Integer; const Visit: TDuplicatePairVisitor)
    var RegularLimit: Integer;
    begin
      if Offset < RegularCount then
      begin
        RegularLimit := RegularCount - Offset;
        if Limit >= 0 then RegularLimit := Min(RegularLimit, Limit);
        FRegularPlan.VisitSelectedPairs(Offset, RegularLimit, Visit, Promotions);
        if Limit >= 0 then Dec(Limit, RegularLimit);
        Offset := RegularCount;
      end;
      if (LinkedCount > 0) and (Limit <> 0) then
        FLinkedPlan.VisitSelectedPairs(Offset - RegularCount, Limit, Visit);
    end);
  try Result := Form.ShowModal = mrYes; finally Form.Free; end;
end;

procedure TfrmBookDuplicates.ApplySelected(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx; BackupFolder: string;
begin
  if not FPlan.Ready or FPlan.LinkedMode or (FPlan.SelectedCount=0) then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  BackupFolder:=TPath.Combine(TPath.Combine(Settings.DataPath,'Backups'),
    'books-'+FormatDateTime('yyyymmdd-hhnnss',Now)+'-'+TGUID.NewGuid.ToString);
  if not ConfirmSelection(Format('Групп для объединения — %d. Повторных записей — %d.'+sLineBreak+
    'Останутся выбранные предпочтительные записи. Пути ко всем копиям, связи с источниками и сериями сохранятся. Файлы книг не удаляются.'+#13#10+#13#10+
    'Записи с личными данными и историей чтения защищены. Перед изменениями будет создана резервная копия:'+#13#10+'%s',
    [FPlan.SelectedCount,FPlan.SelectedRemovedCount,BackupFolder]),False) then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  // The other results still hold a read snapshot of the same catalogue.
  FreeAndNil(FUnified);
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
    FDetailed:=False;
    FResultKind.Items[0]:='Книги, добавленные несколько раз';
    FResultKind.Items[1]:='Книги с несколькими файлами';
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
  Prompt:=Format('Удалить отмеченные копии с диска, в том числе из архивов?'+sLineBreak+
    'Отмечено копий: %d.',[RegularCount+LinkedCount]);
  Prompt:=Prompt+sLineBreak+sLineBreak+
    'HomeLibre проверит, что сохраняемая копия доступна. Если безопасно удалить копию не получится, причина будет в отчёте.'+sLineBreak+
    'Удаление пройдёт в фоне. При остановке уже выполненное сохранится.';
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  if not ConfirmSelection(Prompt,True) then Exit;
  if Assigned(FBeforeApply) then FBeforeApply(Self);
  FDeleteInBatches:=True;
  ModalResult:=mrOk;
end;

function TfrmBookDuplicates.TakeDeletionOperation(const UserFile, JournalRoot: string): TBookDeletionOperation;
begin
  if not FDeleteInBatches then Exit(nil);
  FreeAndNil(FUnified);
  if not FLinkedResultsValid then FLinkedPlan.DiscardPreview;
  Result:=TBookDeletionOperation.CreateDuplicateCleanup(FRegularPlan,FLinkedPlan,FCollectionInfo.ID,UserFile,JournalRoot);
  FPlan:=nil;
  FDeleteInBatches:=False;
end;

procedure TfrmBookDuplicates.Scan(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
begin
  FSearch.Enabled:=False;
  FDetailed:=False;
  FLinkedResultsValid:=False;
  FShowDetails.Visible:=False;
  FResultKind.Visible:=False;
  FreeAndNil(FUnified);
  FUnified:=TUnifiedDuplicateView.Create(FRegularPlan,FLinkedPlan);
  FLinkedPlan.DiscardPreview;
  Worker:=TDuplicateScanWorker.Create(FRegularPlan); Progress:=TImportProgressFormEx.Create(Self);
  try
    Worker.FLinkedPlan:=FLinkedPlan;
    Worker.FUnified:=FUnified;
    Worker.FSavedPriority:=FSavedPriority;
    Progress.Caption:='Поиск дублей книг'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1; Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    FLinkedResultsValid:=(Worker.FError='') and FLinkedPlan.Ready;
    FResultKind.Items[0]:=Format('Книги, добавленные несколько раз (%d)',[FRegularPlan.GroupCount]);
    FResultKind.Items[1]:=Format('Книги с несколькими файлами (%d)',[FLinkedPlan.GroupCount]);
    FResultKind.ItemIndex:=Ord(FLinkedResultsValid and (FRegularPlan.GroupCount=0) and (FLinkedPlan.GroupCount>0));
    SwitchResults(FResultKind);
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError
    else if Worker.FPriorityApplied then
      FDetails.Lines.Text:='Сохранённый порядок источников применён. Проверьте отметки перед удалением.';
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

procedure TfrmBookDuplicates.ToggleDetails(Sender: TObject);
begin
  FDetailed:=not FDetailed;
  if FDetailed then UpdateStatus
  else
  begin
    FResultKind.ItemIndex:=Ord(FLinkedResultsValid and (FRegularPlan.GroupCount=0) and (FLinkedPlan.GroupCount>0));
    SwitchResults(nil);
  end;
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
  if FLinkedResultsValid then Sources:=AvailableDuplicatePriorities(FRegularPlan,FLinkedPlan)
  else Sources:=FRegularPlan.PrioritySources;
  FSourcePriority:=nil;
  for var Name in FSavedPriority do
    if MatchStr(Name,Sources) then FSourcePriority:=FSourcePriority+[Name];
  for var Name in Sources do
    if not MatchStr(Name,FSourcePriority) then FSourcePriority:=FSourcePriority+[Name];
end;

procedure TfrmBookDuplicates.SelectSource(Sender: TObject);
var Worker: TDuplicateScanWorker; Progress: TImportProgressFormEx;
  Dialog: TDuplicateSourcePriorityForm; Ranked: Boolean;
begin
  if not FSelectSource.Enabled then Exit;
  Ranked:=(Assigned(FUnified) and FUnified.Ready) or not FPlan.LinkedMode or (not FDetailed and (Length(FSourcePriority)>=2));
  if Ranked then
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
  if Ranked then Worker:=TDuplicateScanWorker.Create(FRegularPlan)
  else Worker:=TDuplicateScanWorker.Create(FPlan);
  if not Ranked then
  begin
    Worker.FSelectLinkedFiles:=True;
    if FSource.Visible and (FSource.ItemIndex>0) then Worker.FSourceName:=FSource.Text;
  end
  else
  begin
    Worker.FSourcePriority:=FSourcePriority;
    if FLinkedResultsValid then Worker.FLinkedPlan:=FLinkedPlan;
  end;
  Worker.FUnified:=FUnified;
  Progress:=TImportProgressFormEx.Create(Self);
  try
    Progress.Caption:='Выбор копий по источникам'; Progress.WorkerThread:=Worker;
    Progress.CloseOnTimer:=True; Progress.Timer.Interval:=1;
    Progress.PopupMode:=pmExplicit; Progress.PopupParent:=Self;
    Progress.ShowModal; Worker.WaitFor;
    if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
    RenderPage;
    if Worker.FError<>'' then FDetails.Lines.Text:=Worker.FError
    else if Ranked then
      FDetails.Lines.Text:='Копии сохраняются по порядку источников: '+string.Join(' → ',FSourcePriority)+'.'+sLineBreak+
        'HomeLibre отметила копии, для которых удалось выбрать, что оставить. Проверьте выбор и нажмите «Удалить отмеченные копии…».'
    else FDetails.Lines.Text:=Format('Отмечено файлов к удалению: %d.',[FPlan.SelectedRemovedCount]);
  finally Progress.Free; Worker.Free; UpdateStatus; end;
end;

procedure TfrmBookDuplicates.ClearSelection(Sender: TObject);
begin
  FRegularPlan.ClearSelection;
  FLinkedPlan.ClearSelection;
  if Assigned(FUnified) and FUnified.Ready then FUnified.RefreshMarks;
  RenderPage;
end;

procedure TfrmBookDuplicates.FilterGroups(Sender: TObject);
begin
  FOffset:=0;
  RenderPage;
end;

function TfrmBookDuplicates.VisibleGroupCount: Integer;
begin
  if Assigned(FUnified) and FUnified.Ready then Exit(FUnified.GroupCount(FUnmarkedOnly.Checked));
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
    FUnifiedBooks:=nil;
    FCopies.Checkboxes:=FPlan.LinkedMode and not (Assigned(FUnified) and FUnified.Ready);
    if Assigned(FUnified) and FUnified.Ready then FPage:=FUnified.Groups(FOffset,50,FUnmarkedOnly.Checked)
    else if FPlan.Ready then FPage:=FPlan.Groups(FOffset,50,FUnmarkedOnly.Checked);
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
    try
      if Assigned(FUnified) and FUnified.Ready then
      begin
        FUnifiedBooks:=FUnified.Books(FPage[Item.Index].ID);
        SetLength(FBooks,Length(FUnifiedBooks));
        for var J:=0 to High(FBooks) do FBooks[J]:=FUnifiedBooks[J].Value;
      end
      else FBooks:=FPlan.Books(FPage[Item.Index].ID);
      if not (Assigned(FUnified) and FUnified.Ready) and not FPlan.LinkedMode and
        FLinkedResultsValid and FPage[Item.Index].Selected then
        for var I:=0 to High(FBooks) do
          if FBooks[I].Book.BookKey.BookID=FPage[Item.Index].KeepID then
            FLinkedPlan.PreviewSelectedPromotion(FBooks[I]);
    except on E: Exception do begin FDetails.Lines.Text:=E.Message; Exit; end; end;
    for var I:=0 to High(FBooks) do
    begin
      if Assigned(FUnified) and FUnified.Ready then IsPrimary:=FUnifiedBooks[I].Kept
      else if FPlan.LinkedMode then IsPrimary:=FBooks[I].CopyKey=''
      else IsPrimary:=FBooks[I].Book.BookKey.BookID=FPage[Item.Index].KeepID;
      CopyItem:=FCopies.Items.Add;
      CopyItem.SubItems.Add(IfThen(FBooks[I].SourceName<>'',FBooks[I].SourceName,
        IfThen(FPlan.LinkedMode and IsPrimary,'Основная копия','Неизвестен')));
      CopyItem.SubItems.Add(FBooks[I].Book.Title); CopyItem.SubItems.Add(FormatFloat('0.0',FBooks[I].Book.Size/1024.0)+' КБ');
      CopyItem.SubItems.Add(IfThen(FBooks[I].HasPersonalData,'Есть','—'));
      CopyItem.SubItems.Add(FBooks[I].Book.Folder+' / '+FBooks[I].Book.FileName+FBooks[I].Book.FileExt);
      CopyItem.SubItems.Add(TAuthorsHelper.GetList(FBooks[I].Book.Authors));
      if FCopies.Checkboxes then CopyItem.Checked:=FBooks[I].Selected;
      if IsPrimary then Preferred:=I;
    end;
    if Assigned(FUnified) and FUnified.Ready then
    begin
      var AllMarked:=Length(FUnifiedBooks)>1;
      for var Entry in FUnifiedBooks do if not Entry.Kept and not Entry.Selected then AllMarked:=False;
      FUseGroup.Checked:=AllMarked;
    end
    else if FPlan.LinkedMode then RefreshLinkedMarks else FUseGroup.Checked:=FPage[Item.Index].Selected;
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
    if Assigned(FUnified) and FUnified.Ready then
    begin
      Primary:=FUnifiedBooks[I].Kept; Marked:=FUnifiedBooks[I].Selected;
    end
    else if FPlan.LinkedMode then
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

function TfrmBookDuplicates.GroupExplanation(const Group: TDuplicateGroup): string;
var Key: TArray<string>; TitleDiffers, HasLinkedFiles: Boolean; ComparisonTitle, Language: string;
begin
  if (Group.ID < 0) or ((Group.Identity = '') and FPlan.LinkedMode) then
    Exit('Копии связаны с одной карточкой книги в каталоге.');
  Key := Group.Identity.Split([#1]);
  if Length(Key) <> 3 then Exit('');
  if Key[1] <> '' then Language := Key[1] else Language := 'не указан';
  Result := Format('Совпали ID источника %s, язык (%s) и формат %s.',
    [Key[0], Language, UpperCase(Key[2].TrimLeft(['.']))]);
  TitleDiffers := False; HasLinkedFiles := False; ComparisonTitle := Group.Title;
  for var Book in FBooks do
  begin
    TitleDiffers := TitleDiffers or not SameText(Book.Book.Title, ComparisonTitle);
    HasLinkedFiles := HasLinkedFiles or (Book.CopyKey <> '');
  end;
  if TitleDiffers then Result := Result + ' Названия у копий различаются.';
  if HasLinkedFiles then Result := Result + ' Среди них есть файлы, связанные с одной карточкой.';
end;

procedure TfrmBookDuplicates.SelectCopy(Sender: TObject; Item: TListItem; Selected: Boolean);
var Book: TDuplicateBook; Explanation: string;
begin
  if FUpdating or not Selected or not Assigned(FGroups.Selected) then Exit;
  Book:=FBooks[Item.Index];
  Explanation := GroupExplanation(FPage[FGroups.Selected.Index]);
  if Explanation <> '' then Explanation := Explanation + sLineBreak + sLineBreak;
  if Assigned(FUnified) and FUnified.Ready then
  begin
    FDetails.Lines.Text:=Explanation+Format('Копий этой книги: %d. Выбранная копия: %s.',
      [Length(FUnifiedBooks),IfThen(FUnifiedBooks[Item.Index].Kept,'сохранится',
        IfThen(FUnifiedBooks[Item.Index].Selected,'к удалению','пока не отмечена'))])+sLineBreak+
      'Источник: '+Book.SourceName+sLineBreak+'Папка: '+Book.Book.CollectionRoot+sLineBreak+
      'Файл / архив: '+Book.Book.Folder+' / '+Book.Book.FileName+Book.Book.FileExt+sLineBreak+
      'Копии могут лежать в разных папках и коллекциях, даже если в каталоге была одна строка.';
    UpdateStatus; Exit;
  end;
  if FPlan.LinkedMode then
  begin
    FDetails.Lines.Text:=Explanation+IfThen(Book.CopyKey='','Основная копия сохранится.','Дополнительная копия этой книги.')+sLineBreak+
      'Название: '+Book.Book.Title+sLineBreak+'Источник: '+Book.SourceName+sLineBreak+
      'Папка коллекции: '+Book.Book.CollectionRoot+sLineBreak+'Папка / архив: '+Book.Book.Folder+sLineBreak+
      'Файл: '+Book.Book.FileName+Book.Book.FileExt;
    Exit;
  end;
  FDetails.Lines.Text:=Explanation+'Основная запись: '+IntToStr(FPage[FGroups.Selected.Index].KeepID)+#13#10+
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
  if (Assigned(FUnified) and FUnified.Ready) or FUpdating or not FPlan.LinkedMode or (Item.Index<0) or (Item.Index>=Length(FBooks)) then Exit;
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
  if Assigned(FUnified) and FUnified.Ready and Assigned(FGroups.Selected) and Assigned(FCopies.Selected) then
  begin
    try
      Index:=FGroups.Selected.Index;
      FUnified.Choose(FPage[Index].ID,FCopies.Selected.Index,FPage[Index].Selected);
      FPage:=FUnified.Groups(FOffset,50,FUnmarkedOnly.Checked);
      SelectGroup(FGroups,FGroups.Selected,True);
    except on E:Exception do MessageDlg(E.Message,mtInformation,[mbOK],0); end;
    UpdateStatus; Exit;
  end;
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
  if Assigned(FUnified) and FUnified.Ready then
  begin
    try
      FUnified.Choose(FPage[Index].ID,-1,FUseGroup.Checked);
      FPage:=FUnified.Groups(FOffset,50,FUnmarkedOnly.Checked);
      if FUnmarkedOnly.Checked then RenderPage
      else
      begin
        FGroups.Selected.SubItems[1]:=IfThen(FPage[Index].Selected,IntToStr(FPage[Index].SelectedCopies),'—');
        SelectGroup(FGroups,FGroups.Selected,True);
      end;
    except on E:Exception do
      begin SelectGroup(FGroups,FGroups.Selected,True); MessageDlg(E.Message,mtInformation,[mbOK],0); end; end;
    UpdateStatus; Exit;
  end;
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
