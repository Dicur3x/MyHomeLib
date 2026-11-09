unit unit_BookDeletionDialog;

interface

uses System.Classes, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_BookDeletionOperation,
  unit_Globals, unit_BookDeletionBinding, unit_BookDeletionSelection;

type
  TBookDeletionProgress = class(TForm)
  private
    FStage, FArchive, FDetail: TLabel;
    FProgress: TProgressBar;
    FStop, FConfirm: TButton;
    FWriteStarted: UInt64;
    FWriteStartBytes: Int64;
    procedure HideWhenClosed(Sender: TObject; var Action: TCloseAction);
  public
    constructor CreateProgress(AOwner: TForm; Stop, Confirm: TNotifyEvent);
    procedure UpdateProgress(const State: TBookDeletionOperationStatus);
  end;

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean; const Scope: string = '';
  LinkedCount: Integer = 0): Boolean;

function ConfirmBookDeletionBatch(var Items: TArray<TBookDeletionBatchItem>): Boolean;
function PrepareSelectorBookDeletion(Owner:TForm; const Info:TCollectionInfo; Mode:TBookIteratorMode;
  const Selectors:TArray<TBookDeletionSelector>; RemoveRecords:Boolean; out Binding:TBookDeletionBinding):Boolean;

implementation

uses Winapi.Windows, System.SysUtils, System.Math, Vcl.Controls, Vcl.ExtCtrls, unit_MHLTheme,
  frm_ImportProgressForm, unit_BookEstimateReport, unit_ZipMemberDeletion, unit_Errors;

type
  TSelectorDeletionProgress = class(TImportProgressForm)
    procedure CancelDirect(Sender:TObject);
    procedure StopOnClose(Sender:TObject; var CanClose:Boolean);
  end;

procedure TSelectorDeletionProgress.CancelDirect(Sender:TObject);
begin WorkerThread.Cancel; btnCancel.Enabled:=False; end;

procedure TSelectorDeletionProgress.StopOnClose(Sender:TObject; var CanClose:Boolean);
begin
  CanClose:=WorkerThread.Finished;
  if not CanClose then CancelDirect(Sender);
end;

function PrepareSelectorBookDeletion(Owner:TForm; const Info:TCollectionInfo; Mode:TBookIteratorMode;
  const Selectors:TArray<TBookDeletionSelector>; RemoveRecords:Boolean; out Binding:TBookDeletionBinding):Boolean;
var Worker:TBookDeletionSelection; Progress:TSelectorDeletionProgress;
begin
  Result:=False; Binding:=Default(TBookDeletionBinding);
  Worker:=TBookDeletionSelection.Create(Info,Mode,Selectors,RemoveRecords);
  try
    Progress:=TSelectorDeletionProgress.Create(Owner);
    try
      Progress.Name:='BookDeletionSelection'; Progress.Caption:='Подготовка списка книг для удаления';
      Progress.WorkerThread:=Worker; Progress.btnCancel.OnClick:=Progress.CancelDirect;
      Progress.OnCloseQuery:=Progress.StopOnClose; Progress.ShowModal;
    finally Progress.Free; end;
    Worker.WaitFor;
    if Worker.Canceled then Exit;
    if Assigned(Worker.FatalException) then raise EReadError.Create(Exception(Worker.FatalException).Message);
    Result:=Worker.Success;
    if Result then Binding:=Worker.Binding;
  finally Worker.Free; end;
end;

constructor TBookDeletionProgress.CreateProgress(AOwner:TForm; Stop,Confirm:TNotifyEvent);
  function Line(const Text:string; Y,Height:Integer):TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Self;
    Result.AutoSize:=False; Result.WordWrap:=True; Result.ShowAccelChar:=False;
    Result.Anchors:=[akLeft,akTop,akRight]; Result.SetBounds(16,Y,528,Height);
    Result.Caption:=Text;
  end;
begin
  inherited CreateNew(AOwner);
  Name:='BookDeletionProgress'; Caption:='Удаление книг';
  PopupMode:=pmExplicit; PopupParent:=AOwner; Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; BorderIcons:=[biSystemMenu];
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=560; ClientHeight:=222;
  Constraints.MinWidth:=510; Constraints.MinHeight:=260;
  FStage:=Line('Подготовка удаления…',14,25);
  FArchive:=Line('',45,34);
  FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Self;
  FProgress.Name:='BookDeletionProgressBar'; FProgress.Max:=1000;
  FProgress.Anchors:=[akLeft,akTop,akRight]; FProgress.SetBounds(16,86,528,15);
  FDetail:=Line('Можно продолжать работать с другими книгами.',110,65);
  FDetail.Name:='BookDeletionDetails';
  FConfirm:=TButton.Create(Self); FConfirm.Parent:=Self; FConfirm.Name:='ConfirmArchiveDeletion';
  FConfirm.Caption:='Удалить из архива'; FConfirm.Anchors:=[akRight,akBottom];
  FConfirm.SetBounds(254,178,148,30); FConfirm.OnClick:=Confirm; FConfirm.Visible:=False;
  FStop:=TButton.Create(Self); FStop.Parent:=Self; FStop.Name:='StopBookDeletion';
  FStop.Caption:='Остановить'; FStop.Anchors:=[akRight,akBottom];
  FStop.SetBounds(414,178,130,30); FStop.OnClick:=Stop;
  OnClose:=HideWhenClosed;
  ApplyMHLControlTheme(Self);
end;

procedure TBookDeletionProgress.HideWhenClosed(Sender:TObject; var Action:TCloseAction);
begin
  if FConfirm.Visible and FStop.Enabled then FStop.Click;
  Action:=caHide;
end;

procedure TBookDeletionProgress.UpdateProgress(const State:TBookDeletionOperationStatus);
var Detail: string;
begin
  if State.Stage<>'' then FStage.Caption:=State.Stage;
  FArchive.Caption:=ExtractFileName(State.Archive);
  if (State.ArchiveIndex>0) and (State.ArchiveCount>0) then
    FArchive.Caption:=Format('Архив %d из %d · %s',[State.ArchiveIndex,State.ArchiveCount,FArchive.Caption]);
  if State.CollectionCount>1 then
    FArchive.Caption:=Format('Коллекция %d из %d · %s',[State.CollectionIndex,
      State.CollectionCount,State.CollectionName])+sLineBreak+FArchive.Caption;
  FConfirm.Visible:=State.AwaitingArchiveConfirmation and not State.Stopping;
  FStop.Enabled:=not State.Stopping;
  if FConfirm.Visible then
  begin
    FWriteStarted:=0;
    FStage.Caption:='Подтвердите удаление из общего архива';
    FProgress.Style:=pbstNormal;
    FProgress.Position:=0;
    Detail:='Перемещение данных в архиве книг: '+BookEstimateSizeText(State.MoveBytes)+sLineBreak+
      'Оценка места для журнала: '+BookEstimateSizeText(State.JournalBytes)+'.';
    if State.CompanionCount>0 then
      Detail:=Detail+sLineBreak+Format('Отдельно будут обработаны архивы изображений: %d.',[State.CompanionCount]);
    FDetail.Caption:=Detail;
    Exit;
  end;
  if State.Total>0 then
  begin
    if FProgress.Style<>pbstNormal then FProgress.Style:=pbstNormal;
    FProgress.Position:=EnsureRange(Trunc(1000.0*State.Done/State.Total),0,1000);
  end
  else if FProgress.Style<>pbstMarquee then FProgress.Style:=pbstMarquee;
  if (State.Stage<>ArchiveDeletionWriteStage) or (State.Done<FWriteStartBytes) then FWriteStarted:=0;
  if State.Stopping then FDetail.Caption:='Останавливаемся. Если архив уже меняется, сначала закончим его.'
  else
  begin
    if State.SelectedDuplicates>0 then
      Detail:=Format('Удалено копий: %d из %d. Можно продолжать работу с каталогом.',
        [State.CompletedBooks,State.SelectedDuplicates])
    else if State.CompletedCopies>0 then
      Detail:=Format('Обработано дополнительных копий: %d. Можно продолжать работать с другими книгами.',[State.CompletedCopies])
    else Detail:=Format('Готово книг: %d. Можно продолжать работать с другими книгами.',[State.CompletedBooks]);
    if State.DuplicateBatch>0 then
      Detail:=Detail+sLineBreak+Format('Партия %d.',[State.DuplicateBatch]);
    if (State.Stage=ArchiveDeletionWriteStage) and (State.Done>0) then
    begin
      var NowTick:=GetTickCount64;
      if FWriteStarted=0 then
      begin
        FWriteStarted:=NowTick;
        FWriteStartBytes:=State.Done;
      end
      else if (NowTick-FWriteStarted>=1000) and (State.Done>FWriteStartBytes) and (State.Done<State.Total) then
        Detail:=Detail+sLineBreak+Format('Перемещение данных займёт ещё около %d с.',
          [Max(Int64(1),Round((State.Total-State.Done)/(State.Done-FWriteStartBytes)*
            ((NowTick-FWriteStarted)/1000.0)))]);
    end;
    FDetail.Caption:=Detail;
  end;
end;

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean; const Scope:string; LinkedCount:Integer): Boolean;
var Dialog, Owner: TForm; Summary, Details: TLabel; Files: TCheckBox;
  Footer: TPanel; Button: TButton;
begin
  Result:=False;
  if (LinkedCount=BookCount) and not RemoveRecords then
  begin
    MHLShowInfo('Выбранные книги добавлены ссылками. Исходные файлы останутся на месте.');
    Exit;
  end;
  Owner:=Screen.ActiveForm; if not Assigned(Owner) then Owner:=Application.MainForm;
  Dialog:=TForm.CreateNew(Owner);
  try
    Dialog.Name:='BookDeletionConfirmation'; Dialog.Caption:='Удаление книг';
    Dialog.Position:=poOwnerFormCenter; Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Owner;
    Dialog.BorderStyle:=bsSizeable; Dialog.BorderIcons:=[biSystemMenu];
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.ClientWidth:=590; Dialog.ClientHeight:=264;
    Dialog.Constraints.MinWidth:=550; Dialog.Constraints.MinHeight:=290;
    Summary:=TLabel.Create(Dialog); Summary.Parent:=Dialog;
    Summary.SetBounds(20,18,550,50); Summary.Anchors:=[akLeft,akTop,akRight];
    Summary.AutoSize:=False; Summary.WordWrap:=True; Summary.ShowAccelChar:=False;
    Summary.Caption:=Format('Коллекция: %s'+sLineBreak+'Выбрано книг: %d',[CollectionName,BookCount]);
    Files:=TCheckBox.Create(Dialog); Files.Parent:=Dialog; Files.Name:='DeleteBookSourceFiles';
    Files.SetBounds(20,80,550,26); Files.Anchors:=[akLeft,akTop,akRight];
    Files.Caption:='Удалить файлы книг с диска'; Files.Checked:=RemoveFiles;
    Files.Enabled:=RemoveRecords and (LinkedCount<BookCount);
    if not RemoveRecords then Files.Checked:=True
    else if LinkedCount=BookCount then Files.Checked:=False;
    Details:=TLabel.Create(Dialog); Details.Parent:=Dialog;
    Details.SetBounds(20,116,550,86); Details.Anchors:=[akLeft,akTop,akRight,akBottom];
    Details.AutoSize:=False; Details.WordWrap:=True; Details.ShowAccelChar:=False;
    if RemoveRecords then
      Details.Caption:='Без галочки удаляются только записи из коллекции. Файлы книг остаются на диске.'
    else Details.Caption:='Будут удалены загруженные файлы. Записи в каталоге, оценки и заметки сохранятся.';
    if LinkedCount>0 then
    begin
      Details.Caption:=Details.Caption+sLineBreak+Format(
        'У книг, добавленных ссылками (%d), исходные файлы останутся на месте.',[LinkedCount]);
      Dialog.ClientHeight:=Dialog.ClientHeight+40;
    end;
    if ArchiveCount>0 then
      Details.Caption:=Details.Caption+sLineBreak+sLineBreak+Format(
        'Книг в архивах: %d. В общем архиве программа уберёт только выбранные книги и покажет объём работ до записи. Пустой архив тоже может быть удалён.',[ArchiveCount]);
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom;
    Footer.Height:=54; Footer.BevelOuter:=bvNone;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='ConfirmBookDeletion';
    Button.Caption:='Удалить'; Button.ModalResult:=mrYes;
    Button.SetBounds(312,10,120,30); Button.Anchors:=[akTop,akRight];
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='CancelBookDeletion';
    Button.Caption:='Отмена'; Button.ModalResult:=mrNo; Button.Cancel:=True; Button.Default:=True;
    Button.SetBounds(444,10,126,30); Button.Anchors:=[akTop,akRight];
    if Scope<>'' then
    begin
      Dialog.ClientHeight:=Dialog.ClientHeight+86; Dialog.Constraints.MinHeight:=376;
      Details.Caption:=Scope+sLineBreak+sLineBreak+Details.Caption;
    end;
    ApplyMHLControlTheme(Dialog);
    Result:=Dialog.ShowModal=mrYes;
    // Cancelling must not change the caller's pending choice or its settings.
    if Result then RemoveFiles:=Files.Checked;
  finally Dialog.Free; end;
end;


function ConfirmBookDeletionBatch(var Items:TArray<TBookDeletionBatchItem>):Boolean;
var Dialog,Owner:TForm; Summary:TLabel; Rows:TScrollBox; Footer,Row:TPanel;
  Checks:TArray<TCheckBox>; Button:TButton; Books,Archives,Total,Linked:Integer;
begin
  Result:=False;
  if Length(Items)=0 then Exit;
  if Length(Items)=1 then
  begin
    Books:=Length(Items[0].Binding.ExpectedBooks); Archives:=0; Linked:=0;
    for var Book in Items[0].Binding.ExpectedBooks do
      if Book.IsLinkedSource then Inc(Linked)
      else if IsArchiveBookSource(Book) then Inc(Archives);
    Exit(ConfirmBookDeletion(Items[0].CollectionName,Books,Archives,
      Items[0].Binding.RemoveRecords,Items[0].RemoveFiles,'',Linked));
  end;
  Owner:=Screen.ActiveForm; if not Assigned(Owner) then Owner:=Application.MainForm;
  Dialog:=TForm.CreateNew(Owner);
  try
    Dialog.Name:='BookDeletionConfirmation'; Dialog.Caption:='Удаление книг из коллекций';
    Dialog.PopupMode:=pmExplicit; Dialog.PopupParent:=Owner; Dialog.Position:=poOwnerFormCenter;
    Dialog.BorderStyle:=bsSizeable; Dialog.BorderIcons:=[biSystemMenu];
    Dialog.Font.Name:='Segoe UI'; Dialog.Font.Size:=9;
    Dialog.ClientWidth:=640; Dialog.ClientHeight:=Min(520,180+Length(Items)*76);
    Dialog.Constraints.MinWidth:=560; Dialog.Constraints.MinHeight:=300;
    Total:=0; for var Item in Items do Inc(Total,Length(Item.Binding.ExpectedBooks));
    Summary:=TLabel.Create(Dialog); Summary.Parent:=Dialog; Summary.Align:=alTop;
    Summary.AutoSize:=False; Summary.Height:=64; Summary.WordWrap:=True; Summary.ShowAccelChar:=False;
    Summary.Margins.SetBounds(18,14,18,6); Summary.AlignWithMargins:=True;
    Summary.Caption:=Format('Выбрано книг: %d · коллекций: %d'+sLineBreak+
      'В общих архивах удаляются только выбранные книги. Файлы, добавленные ссылками, сохраняются.',
      [Total,Length(Items)]);
    Footer:=TPanel.Create(Dialog); Footer.Parent:=Dialog; Footer.Align:=alBottom;
    Footer.Height:=54; Footer.BevelOuter:=bvNone;
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='ConfirmBookDeletion';
    Button.Caption:='Удалить'; Button.ModalResult:=mrYes;
    Button.SetBounds(362,10,120,30); Button.Anchors:=[akTop,akRight];
    Button:=TButton.Create(Dialog); Button.Parent:=Footer; Button.Name:='CancelBookDeletion';
    Button.Caption:='Отмена'; Button.ModalResult:=mrNo; Button.Cancel:=True; Button.Default:=True;
    Button.SetBounds(494,10,126,30); Button.Anchors:=[akTop,akRight];
    Rows:=TScrollBox.Create(Dialog); Rows.Parent:=Dialog; Rows.Align:=alClient;
    Rows.BorderStyle:=bsNone; Rows.HorzScrollBar.Visible:=False;
    SetLength(Checks,Length(Items));
    for var I:=High(Items) downto 0 do
    begin
      Row:=TPanel.Create(Dialog); Row.Parent:=Rows; Row.Align:=alTop; Row.Height:=76;
      Row.BevelOuter:=bvNone;
      var Title:=TLabel.Create(Dialog); Title.Parent:=Row; Title.Name:='DeleteCollectionTitle'+IntToStr(I);
      Title.SetBounds(18,4,580,23); Title.Anchors:=[akLeft,akTop,akRight];
      Title.AutoSize:=False; Title.EllipsisPosition:=epEndEllipsis; Title.ShowAccelChar:=False;
      Title.Caption:=Format('%s · книг: %d',[Items[I].CollectionName,Length(Items[I].Binding.ExpectedBooks)]);
      Title.Hint:=Items[I].CollectionName; Title.ShowHint:=True;
      if Items[I].Binding.RemoveRecords then
      begin
        var Detail:=TLabel.Create(Dialog); Detail.Parent:=Row;
        Detail.SetBounds(18,26,580,18); Detail.Anchors:=[akLeft,akTop,akRight];
        Detail.Caption:='Удалить выбранные записи из этой коллекции.';
        Checks[I]:=TCheckBox.Create(Dialog); Checks[I].Parent:=Row;
        Checks[I].Name:='DeleteBookSourceFiles'+IntToStr(I);
        Checks[I].SetBounds(18,46,580,23); Checks[I].Anchors:=[akLeft,akTop,akRight];
        Checks[I].Caption:='Также удалить файлы этих книг с диска'; Checks[I].Checked:=Items[I].RemoveFiles;
      end
      else
      begin
        var Detail:=TLabel.Create(Dialog); Detail.Parent:=Row;
        Detail.SetBounds(18,28,580,40); Detail.Anchors:=[akLeft,akTop,akRight];
        Detail.AutoSize:=False; Detail.WordWrap:=True;
        Detail.Caption:='Удалить только загруженные файлы. Записи в каталоге, оценки и заметки сохранятся.';
      end;
    end;
    ApplyMHLControlTheme(Dialog);
    Result:=Dialog.ShowModal=mrYes;
    if Result then for var I:=0 to High(Items) do
      if Assigned(Checks[I]) then Items[I].RemoveFiles:=Checks[I].Checked
      else Items[I].RemoveFiles:=True;
  finally Dialog.Free; end;
end;

end.
