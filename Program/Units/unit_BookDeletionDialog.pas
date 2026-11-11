unit unit_BookDeletionDialog;

interface

uses System.Classes, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, unit_BookDeletionOperation,
  unit_Globals, unit_BookDeletionBinding, unit_BookDeletionSelection;

type
  TArchiveDeleteConfirmEvent = procedure(AllRemaining: Boolean) of object;

  TBookDeletionProgress = class(TForm)
  private
    FStage, FDetail, FSpace: TLabel;
    FArchive, FVolumeText: TLabel;
    FVolumes: TScrollBox;
    FProgress: TProgressBar;
    FStop, FConfirm, FConfirmAll, FSkipDetails, FPin, FCopyPath: TButton;
    FPinned: Boolean;
    FSkipReport, FSpaceReport, FSpaceSummary: string;
    FOnConfirm: TArchiveDeleteConfirmEvent;
    FWriteStarted: UInt64;
    FWriteStartBytes: Int64;
    FLayoutReady, FScalingLayout: Boolean;
    procedure ArrangeControls(PPI: Integer);
    procedure ConfirmClick(Sender: TObject);
    procedure TogglePin(Sender: TObject);
    procedure ShowSkipDetails(Sender: TObject);
    procedure CopyArchivePath(Sender: TObject);
    procedure HideWhenClosed(Sender: TObject; var Action: TCloseAction);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure Resize; override;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    constructor CreateProgress(AOwner: TForm; Stop: TNotifyEvent; Confirm: TArchiveDeleteConfirmEvent);
    procedure UpdateProgress(const State: TBookDeletionOperationStatus);
  end;

function ConfirmBookDeletion(const CollectionName: string; BookCount, ArchiveCount: Integer;
  RemoveRecords: Boolean; var RemoveFiles: Boolean; const Scope: string = '';
  LinkedCount: Integer = 0): Boolean;

function ConfirmBookDeletionBatch(var Items: TArray<TBookDeletionBatchItem>): Boolean;
procedure ShowBookDeletionReport(Owner:TForm; const Summary, Details:string);
function BookDeletionSpaceSummary(const State:TBookDeletionOperationStatus):string;
function BookDeletionSpaceDetails(const State:TBookDeletionOperationStatus):string;
function PrepareSelectorBookDeletion(Owner:TForm; const Info:TCollectionInfo; Mode:TBookIteratorMode;
  const Selectors:TArray<TBookDeletionSelector>; RemoveRecords:Boolean; out Binding:TBookDeletionBinding):Boolean;

implementation

uses Winapi.Windows, System.SysUtils, System.Math, Vcl.ExtCtrls, unit_MHLTheme,
  frm_ImportProgressForm, unit_BookEstimateReport, unit_ZipMemberDeletion, unit_Errors, Vcl.Clipbrd, System.Types;

type
  TBookDeletionReport = class(TForm)
  private
    FText: TMemo;
    FPin:TButton;
    FDisplayedText: string;
    procedure TogglePin(Sender:TObject);
    procedure CloseClick(Sender:TObject);
    procedure SetReportText(const Text:string);
  protected
    procedure CreateParams(var Params:TCreateParams); override;
  public
    constructor CreateReport(AOwner:TForm; const AName:string='BookDeletionReport');
  end;

  TSelectorDeletionProgress = class(TImportProgressForm)
    procedure CancelDirect(Sender:TObject);
    procedure StopOnClose(Sender:TObject; var CanClose:Boolean);
  end;

constructor TBookDeletionReport.CreateReport(AOwner:TForm; const AName:string);
var Footer:TPanel; Button:TButton;
begin
  inherited CreateNew(AOwner);
  Name:=AName; Caption:='Результат удаления книг'; FormStyle:=fsStayOnTop;
  Position:=poScreenCenter;
  BorderStyle:=bsSizeable; BorderIcons:=[biSystemMenu,biMinimize];
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=620; ClientHeight:=360;
  Constraints.MinWidth:=420; Constraints.MinHeight:=260;
  Footer:=TPanel.Create(Self); Footer.Parent:=Self; Footer.Align:=alBottom;
  Footer.Height:=50; Footer.BevelOuter:=bvNone;
  Button:=TButton.Create(Self); Button.Parent:=Footer; Button.Caption:='Закрыть';
  Button.SetBounds(484,10,120,30); Button.Anchors:=[akTop,akRight]; Button.OnClick:=CloseClick;
  FPin:=TButton.Create(Self); FPin.Parent:=Footer; FPin.Name:='PinBookDeletionReport';
  FPin.SetBounds(12,10,150,30); FPin.Caption:='Открепить'; FPin.OnClick:=TogglePin;
  FText:=TMemo.Create(Self); FText.Name:='BookDeletionReportText'; FText.Parent:=Self;
  FText.Align:=alClient; FText.ReadOnly:=True; FText.ScrollBars:=ssVertical;
  ApplyMHLControlTheme(Self);
end;

function SpaceLine(Bytes:Int64):string;
begin
  if Bytes>=0 then Result:='Освобождено: ≈ '+BookEstimateSizeText(Bytes)
  else Result:='Занято дополнительно: ≈ '+BookEstimateSizeText(Abs(Bytes));
end;

function BookDeletionSpaceSummary(const State:TBookDeletionOperationStatus):string;
var Bytes:Int64; Missing:Integer;
begin
  Bytes:=0; Missing:=0;
  for var Volume in State.SpaceByVolume do
  begin Inc(Bytes,Volume.ReleasedBytes); Inc(Missing,Volume.UnmeasuredFiles); end;
  Result:=SpaceLine(Bytes);
  if Missing>0 then Result:=Result+' · не всё учтено';
end;

function BookDeletionSpaceDetails(const State:TBookDeletionOperationStatus):string;
var Lines:TStringList;
begin
  Lines:=TStringList.Create;
  try
    for var Volume in State.SpaceByVolume do
    begin
      var Name:=ExcludeTrailingPathDelimiter(Volume.Volume);
      if Name='' then Name:='Диск не определён';
      Lines.Add(Name+' — '+SpaceLine(Volume.ReleasedBytes));
      if Volume.UnmeasuredFiles>0 then
        Lines.Add(Format('  Не удалось измерить файлов: %d.',[Volume.UnmeasuredFiles]));
    end;
    Result:=Trim(Lines.Text);
    if Result<>'' then Result:=Result+sLineBreak+sLineBreak+
      'Итог этого удаления: уменьшение файлов книг, архивов, обложек и иллюстраций. '+
      'Суммы обновляются после обработки каждого архива.';
  finally Lines.Free; end;
end;

procedure TBookDeletionReport.CreateParams(var Params:TCreateParams);
begin
  inherited;
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
end;

procedure TBookDeletionReport.TogglePin(Sender:TObject);
begin
  if FormStyle=fsStayOnTop then begin FormStyle:=fsNormal; FPin.Caption:='Поверх окон'; end
  else begin FormStyle:=fsStayOnTop; FPin.Caption:='Открепить'; end;
end;

procedure TBookDeletionReport.CloseClick(Sender:TObject);
begin
  Close;
end;

procedure TBookDeletionReport.SetReportText(const Text:string);
begin
  if FDisplayedText=Text then Exit;
  FDisplayedText:=Text; FText.Text:=Text; FText.SelStart:=0;
end;

procedure ShowBookDeletionReport(Owner:TForm; const Summary, Details:string);
var Report:TBookDeletionReport;
begin
  Report:=Owner.FindComponent('BookDeletionReport') as TBookDeletionReport;
  if not Assigned(Report) then Report:=TBookDeletionReport.CreateReport(Owner);
  if Details='' then Report.SetReportText(Summary)
  else Report.SetReportText(Summary+sLineBreak+sLineBreak+Details);
  if Report.WindowState=wsMinimized then Report.WindowState:=wsNormal;
  Report.FormStyle:=fsStayOnTop; Report.FPin.Caption:='Открепить';
  Report.Show; Report.BringToFront;
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

constructor TBookDeletionProgress.CreateProgress(AOwner:TForm; Stop:TNotifyEvent; Confirm:TArchiveDeleteConfirmEvent);
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
  Position:=poOwnerFormCenter;
  BorderStyle:=bsSizeable; BorderIcons:=[biSystemMenu,biMinimize];
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=560; ClientHeight:=280;
  Constraints.MinWidth:=510; Constraints.MinHeight:=318;
  FStage:=Line('Подготовка удаления…',14,29);
  FStage.Width:=396;
  FPin:=TButton.Create(Self); FPin.Parent:=Self; FPin.Name:='PinBookDeletionProgress';
  FPin.Caption:='Поверх окон'; FPin.Hint:='Закрепить окно поверх всех окон'; FPin.ShowHint:=True;
  FPin.Anchors:=[akTop,akRight]; FPin.SetBounds(424,10,120,28); FPin.OnClick:=TogglePin;
  FArchive:=Line('',49,23); FArchive.Name:='BookDeletionCurrentArchive';
  FArchive.WordWrap:=False; FArchive.EllipsisPosition:=epPathEllipsis; FArchive.ShowHint:=True;
  FArchive.Visible:=False;
  FCopyPath:=TButton.Create(Self); FCopyPath.Parent:=Self; FCopyPath.Name:='BookDeletionCopyPath';
  FCopyPath.Caption:='Копировать'; FCopyPath.OnClick:=CopyArchivePath; FCopyPath.Visible:=False;
  FCopyPath.Hint:='Скопировать полный путь архива'; FCopyPath.ShowHint:=True;
  FProgress:=TProgressBar.Create(Self); FProgress.Parent:=Self;
  FProgress.Name:='BookDeletionProgressBar'; FProgress.Max:=1000;
  FProgress.Anchors:=[akLeft,akTop,akRight]; FProgress.SetBounds(16,86,528,15);
  FDetail:=Line('Можно продолжать работать с другими книгами.',110,60);
  FDetail.Name:='BookDeletionDetails';
  FSpace:=Line('Освобождено: 0 Б',174,18);
  FSpace.Name:='BookDeletionReleasedSpace';
  FVolumes:=TScrollBox.Create(Self); FVolumes.Parent:=Self; FVolumes.Name:='BookDeletionVolumes';
  FVolumes.BorderStyle:=bsNone; FVolumes.HorzScrollBar.Visible:=False;
  FVolumes.VertScrollBar.Tracking:=True; FVolumes.Visible:=False;
  FVolumeText:=TLabel.Create(Self); FVolumeText.Parent:=FVolumes; FVolumeText.Name:='BookDeletionVolumeTotals';
  FVolumeText.AutoSize:=False; FVolumeText.WordWrap:=True; FVolumeText.ShowAccelChar:=False;
  FVolumeText.ShowHint:=True;
  FConfirm:=TButton.Create(Self); FConfirm.Parent:=Self; FConfirm.Name:='ConfirmArchiveDeletion';
  FConfirm.Caption:='Удалить из архива'; FConfirm.Anchors:=[akRight,akBottom];
  FConfirm.SetBounds(254,198,148,30); FConfirm.OnClick:=ConfirmClick; FConfirm.Visible:=False;
  FConfirmAll:=TButton.Create(Self); FConfirmAll.Parent:=Self; FConfirmAll.Name:='ConfirmAllArchiveDeletions';
  FConfirmAll.Caption:='Для всех архивов'; FConfirmAll.Anchors:=[akRight,akBottom];
  FConfirmAll.Hint:='Подтвердить удаление во всех оставшихся архивах этой операции'; FConfirmAll.ShowHint:=True;
  FConfirmAll.SetBounds(86,198,156,30); FConfirmAll.OnClick:=ConfirmClick; FConfirmAll.Visible:=False;
  FOnConfirm:=Confirm;
  FStop:=TButton.Create(Self); FStop.Parent:=Self; FStop.Name:='StopBookDeletion';
  FStop.Caption:='Остановить'; FStop.Anchors:=[akRight,akBottom];
  FStop.SetBounds(414,198,130,30); FStop.OnClick:=Stop;
  FSkipDetails:=TButton.Create(Self); FSkipDetails.Parent:=Self; FSkipDetails.Name:='BookDeletionSkipDetails';
  FSkipDetails.Caption:='Почему оставлены…'; FSkipDetails.Anchors:=[akLeft,akBottom];
  FSkipDetails.SetBounds(16,198,180,30); FSkipDetails.OnClick:=ShowSkipDetails; FSkipDetails.Visible:=False;
  OnClose:=HideWhenClosed;
  ApplyMHLControlTheme(Self);
  FLayoutReady:=True;
  ArrangeControls(PixelsPerInch);
end;

procedure TBookDeletionProgress.ArrangeControls(PPI:Integer);
  function Px(Value:Integer):Integer;
  begin Result:=MulDiv(Value,PPI,96); end;
var RightEdge, BottomY:Integer; Bounds:TRect;
begin
  if not FLayoutReady or FScalingLayout then Exit;
  RightEdge:=ClientWidth-Px(16); BottomY:=ClientHeight-Px(44);
  FStage.SetBounds(Px(16),Px(14),RightEdge-Px(148),Px(29));
  FPin.SetBounds(RightEdge-Px(120),Px(10),Px(120),Px(28));
  FArchive.SetBounds(Px(16),Px(49),RightEdge-Px(136),Px(23));
  FCopyPath.SetBounds(RightEdge-Px(108),Px(45),Px(108),Px(27));
  FProgress.SetBounds(Px(16),Px(86),RightEdge-Px(16),Px(15));
  FDetail.SetBounds(Px(16),Px(110),RightEdge-Px(16),Px(60));
  if FConfirm.Visible then FDetail.Height:=Px(84);
  FSpace.SetBounds(Px(16),Px(174),RightEdge-Px(16),Px(18));
  FVolumes.SetBounds(Px(16),Px(196),RightEdge-Px(16),Px(32));
  FVolumeText.Width:=Max(Px(40),FVolumes.ClientWidth-Px(24));
  Canvas.Font.Assign(FVolumeText.Font); Bounds:=Rect(0,0,FVolumeText.Width,0);
  DrawText(Canvas.Handle,PChar(FVolumeText.Caption),Length(FVolumeText.Caption),Bounds,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
  FVolumeText.Height:=Max(Px(18),Bounds.Height);
  FStop.SetBounds(RightEdge-Px(130),BottomY,Px(130),Px(30));
  FConfirm.SetBounds(RightEdge-Px(290),BottomY,Px(148),Px(30));
  FConfirmAll.SetBounds(RightEdge-Px(458),BottomY,Px(156),Px(30));
  FSkipDetails.SetBounds(Px(16),BottomY,Px(180),Px(30));
end;

procedure TBookDeletionProgress.ScaleForPPI(NewPPI:Integer);
begin
  FScalingLayout:=True;
  try inherited; finally FScalingLayout:=False; end;
  ArrangeControls(PixelsPerInch);
end;

procedure TBookDeletionProgress.Resize;
begin
  inherited;
  ArrangeControls(PixelsPerInch);
end;

procedure TBookDeletionProgress.CreateParams(var Params: TCreateParams);
begin
  inherited;
  // Delphi still owns the component, but Windows treats it as its own window.
  Params.WndParent:=0;
  Params.ExStyle:=(Params.ExStyle or WS_EX_APPWINDOW) and not WS_EX_TOOLWINDOW;
  if FPinned then Params.ExStyle:=Params.ExStyle or WS_EX_TOPMOST;
end;

procedure TBookDeletionProgress.TogglePin(Sender: TObject);
var Layer: HWND;
begin
  if FPinned then Layer:=HWND_NOTOPMOST else Layer:=HWND_TOPMOST;
  if not SetWindowPos(Handle,Layer,0,0,0,0,SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE) then Exit;
  FPinned:=not FPinned;
  if FPinned then
  begin
    FPin.Caption:='Открепить';
    FPin.Hint:='Вернуть обычный порядок окон';
  end
  else
  begin
    FPin.Caption:='Поверх окон';
    FPin.Hint:='Закрепить окно поверх всех окон';
  end;
end;

procedure TBookDeletionProgress.ConfirmClick(Sender: TObject);
begin
  FOnConfirm(Sender=FConfirmAll);
end;

procedure TBookDeletionProgress.ShowSkipDetails(Sender: TObject);
begin
  if FSkipReport<>'' then ShowBookDeletionReport(TForm(Owner),'Оставленные копии',FSkipReport);
end;

procedure TBookDeletionProgress.CopyArchivePath(Sender:TObject);
begin
  if FArchive.Caption<>'' then Clipboard.AsText:=FArchive.Caption;
end;

procedure TBookDeletionProgress.HideWhenClosed(Sender:TObject; var Action:TCloseAction);
begin
  if FConfirm.Visible and FStop.Enabled then FStop.Click;
  Action:=caHide;
end;

procedure TBookDeletionProgress.UpdateProgress(const State:TBookDeletionOperationStatus);
var Detail,Stage,Volumes,VolumeName,VolumeSize: string;
begin
  Stage:=State.Stage;
  if Stage='Проверка других записей в этих архивах' then Stage:='Проверяем оставшиеся книги';
  if Stage='Проверка сохраненных копий дублей' then Stage:='Проверяем сохраняемые копии';
  if (State.DuplicateBatch=0) and (State.ArchiveIndex>0) and (State.ArchiveCount>0) then
    Stage:=Format('%s · архив %d из %d',[Stage,State.ArchiveIndex,State.ArchiveCount]);
  if State.CollectionCount>1 then
    Stage:=Format('%s · коллекция %d из %d',[Stage,State.CollectionIndex,State.CollectionCount]);
  if Stage<>'' then FStage.Caption:=Stage;
  if FArchive.Caption<>State.Archive then FArchive.Caption:=State.Archive;
  FArchive.Visible:=State.Archive<>''; FCopyPath.Visible:=FArchive.Visible;
  FArchive.Hint:=State.Archive;
  if State.CollectionName<>'' then FArchive.Hint:=State.CollectionName+sLineBreak+FArchive.Hint;
  FSpaceSummary:=BookDeletionSpaceSummary(State); FSpace.Caption:=FSpaceSummary;
  FSpaceReport:=BookDeletionSpaceDetails(State);
  FSpace.Hint:=FSpaceReport; FSpace.ShowHint:=True;
  Volumes:='';
  for var Volume in State.SpaceByVolume do
  begin
    VolumeName:=ExcludeTrailingPathDelimiter(Volume.Volume);
    if VolumeName='' then VolumeName:='Неизвестный диск';
    VolumeSize:='≈ '+BookEstimateSizeText(Abs(Volume.ReleasedBytes));
    if Volume.ReleasedBytes<0 then VolumeSize:='занято '+VolumeSize;
    if Volume.UnmeasuredFiles>0 then VolumeSize:=VolumeSize+' (не всё учтено)';
    if Volumes<>'' then Volumes:=Volumes+'   ·   ';
    Volumes:=Volumes+VolumeName+' '+VolumeSize;
  end;
  if FVolumeText.Caption<>Volumes then FVolumeText.Caption:=Volumes;
  FVolumeText.Hint:=FSpaceReport;
  FConfirm.Visible:=State.AwaitingArchiveConfirmation and not State.Stopping;
  FConfirmAll.Visible:=FConfirm.Visible and ((State.DuplicateBatch>0) or
    (State.ArchiveIndex<State.ArchiveCount) or (State.CollectionIndex<State.CollectionCount));
  FSpace.Visible:=not FConfirm.Visible; FVolumes.Visible:=FSpace.Visible and (Volumes<>'');
  ArrangeControls(PixelsPerInch);
  FStop.Enabled:=not State.Stopping;
  FSkipDetails.Visible:=(State.SkippedDuplicates>0) and not FConfirm.Visible;
  if FSkipDetails.Visible then FSkipReport:=State.DuplicateSkipReport else FSkipReport:='';
  if FConfirm.Visible then
  begin
    FWriteStarted:=0;
    FStage.Caption:='Подтвердите удаление из общего архива';
    FProgress.Style:=pbstNormal;
    FProgress.Position:=0;
    Detail:='Нужно обработать в архиве: '+BookEstimateSizeText(State.MoveBytes)+sLineBreak+
      'Оценка места для журнала: '+BookEstimateSizeText(State.JournalBytes)+'.';
    if State.CompanionCount>0 then
      Detail:=Detail+sLineBreak+Format('Отдельно будут обработаны архивы изображений: %d.',[State.CompanionCount]);
    if State.SelectedDuplicates>0 then
      Detail:=Detail+sLineBreak+Format('Всего удалено копий: %d · оставлено: %d.',
        [State.CompletedBooks+State.CompletedCopies,State.SkippedDuplicates]);
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
    if (State.SelectedDuplicates>0) and (State.DuplicateBatch=0) then
    begin
      if State.Total>0 then
        Detail:=Format('Проверено: %d из %d. Удаление начнётся после проверки.',[State.Done,State.Total])
      else
        Detail:='Проверяем выбранные книги. Можно продолжать работу с каталогом.';
    end
    else if State.SelectedDuplicates>0 then
      Detail:=Format('Удалено копий: %d из %d.',
        [State.CompletedBooks+State.CompletedCopies,State.SelectedDuplicates])
    else if State.CompletedCopies>0 then
      Detail:=Format('Удалено копий: %d.',[State.CompletedCopies])
    else Detail:=Format('Обработано книг: %d.',[State.CompletedBooks]);
    if (State.Stage='Обновление коллекции') and (State.Total>0) then
      Detail:=Detail+sLineBreak+Format('Обновлено в каталоге: %d из %d.',[State.Done,State.Total]);
    if State.SkippedDuplicates>0 then
      Detail:=Detail+sLineBreak+Format('Оставлено из отмеченных копий: %d.',[State.SkippedDuplicates]);
    if (State.DuplicateBatch>0) and (State.Stage='Проверка файлов дублей') and (State.Total>0) then
      Detail:=Detail+sLineBreak+Format('Проверено файлов: %d из %d.',[State.Done,State.Total]);
    if (State.Stage=ArchiveDeletionRepackStage) and (State.Done>0) then
    begin
      Detail:=Detail+sLineBreak+'Подготовлено '+BookEstimateSizeText(State.Done);
      if State.Total>0 then Detail:=Detail+' из '+BookEstimateSizeText(State.Total);
      Detail:=Detail+'.';
    end
    else if (State.Done>0) and (State.Total=0) then
      Detail:=Detail+sLineBreak+Format('Проверено книг и копий: %d.',[State.Done]);
    if (State.Stage=ArchiveDeletionWriteStage) and (State.Done>0) then
    begin
      var NowTick:=GetTickCount64;
      if FWriteStarted=0 then
      begin
        FWriteStarted:=NowTick;
        FWriteStartBytes:=State.Done;
      end
      else if (NowTick-FWriteStarted>=1000) and (State.Done>FWriteStartBytes) and (State.Done<State.Total) then
        Detail:=Detail+sLineBreak+Format('Уменьшаем архив после удаления — осталось около %d с.',
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
