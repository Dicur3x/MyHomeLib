unit frm_CollectionPackingProgress;

interface

uses System.Classes, System.SyncObjs, Vcl.Forms, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  frm_CatalogSources, unit_CollectionPacking;

type
  // The worker owns all SQLite snapshots. The UI reads one bounded status
  // record on a timer, without a queued callback for every library record.
  TfrmCollectionPackingProgress = class(TSourceDialogForm)
  private
    FStage, FSource, FStep, FCounts, FSize, FTime, FNote: TLabel;
    FStepBar, FOverall: TProgressBar;
    FCancelButton, FContinueButton: TButton;
    FTimer: TTimer;
    FThread: TThread;
    FLock: TObject;
    FStatus: TCollectionPackingStatus;
    FImageProfile: TPackingImageProfile;
    FSnapshot: TCollectionPackingSnapshot;
    FCancel, FReviewPending: Integer;
    FReviewEvent: TEvent;
    FStarted: UInt64;
    procedure Poll(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure ContinueClick(Sender: TObject);
    procedure Closing(Sender: TObject; var CanClose: Boolean);
    function ThreadDone: Boolean;
    procedure ReceiveStatus(const Status: TCollectionPackingStatus);
    procedure Review(const Status: TCollectionPackingStatus);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RenderStatus(const Status: TCollectionPackingStatus);
    procedure RequestCancel;
    function ReadStatus: TCollectionPackingStatus;
    function Execute(const Options: TCollectionPackingOptions; ReviewEstimate: Boolean = False;
      const Inpx: string = ''; const UpdateRoot: string = ''): TCollectionPackingSnapshot;
  end;

function PackingRemainingSeconds(const Status: TCollectionPackingStatus): Int64;
function PackingSize(Bytes: Int64): string;

implementation

uses System.SysUtils, System.Math, Winapi.Windows, Vcl.Controls, Vcl.Graphics, unit_MHLTheme,
  unit_CollectionPackingInpx;

function PackingRemainingSeconds(const Status: TCollectionPackingStatus): Int64;
begin
  Result:=-1;
  if (Status.SourcesDone<2) or (Status.SourcesTotal<=Status.SourcesDone) or
    (Status.PackingMS<5000) or (Status.StageKey='native') or (Status.StageKey='prepared') then Exit;
  // A rough estimate from completed sources, never a promise about the size
  // or complexity of the remaining files. Show no ETA before enough work.
  Result:=Ceil((Status.PackingMS/1000)*(Status.SourcesTotal-Status.SourcesDone)/Status.SourcesDone);
end;

function PackingTime(Seconds: Int64): string;
begin
  if Seconds>=3600 then Result:=Format('%d ч %d мин',[Seconds div 3600,(Seconds div 60) mod 60])
  else if Seconds>=60 then Result:=Format('%d мин %d с',[Seconds div 60,Seconds mod 60])
  else Result:=IntToStr(Max(Int64(0),Seconds))+' с';
end;

function PackingSize(Bytes: Int64): string;
begin
  if Bytes>=Int64(1024)*1024*1024 then Result:=FormatFloat('0.00',Bytes/(Int64(1024)*1024*1024))+' ГБ'
  else if Bytes>=1024*1024 then Result:=FormatFloat('0.0',Bytes/(1024*1024))+' МБ'
  else if Bytes>=1024 then Result:=FormatFloat('0.0',Bytes/1024)+' КБ'
  else Result:=IntToStr(Bytes)+' Б';
end;

constructor TfrmCollectionPackingProgress.Create(AOwner: TComponent);
  function LabelAt(const AName: string; Y,H: Integer): TLabel;
  begin
    Result:=TLabel.Create(Self); Result.Parent:=Self; Result.Name:=AName;
    Result.AutoSize:=False; Result.WordWrap:=True;
    Result.SetBounds(16,Y,648,H); Result.Anchors:=[akLeft,akTop,akRight];
  end;
  function BarAt(const AName: string; Y: Integer): TProgressBar;
  begin
    Result:=TProgressBar.Create(Self); Result.Parent:=Self; Result.Name:=AName;
    Result.SetBounds(16,Y,648,18); Result.Anchors:=[akLeft,akTop,akRight]; Result.Max:=1000;
  end;
begin
  inherited CreateNew(AOwner); Name:='CollectionPackingProgress'; Caption:='Сжатие коллекции';
  Position:=poOwnerFormCenter; BorderStyle:=bsSizeable;
  PixelsPerInch:=96; Font.PixelsPerInch:=96; Font.Name:='Segoe UI'; Font.Size:=9;
  ClientWidth:=680; ClientHeight:=400; Constraints.MinWidth:=640; Constraints.MinHeight:=430;
  FLock:=TObject.Create;
  FReviewEvent:=TEvent.Create(nil,True,False,'');
  FStage:=LabelAt('lblPackingStage',16,30); FStage.Font.Style:=[fsBold];
  FStage.Caption:='Подготавливаем сжатие…'; FStatus.Stage:=FStage.Caption;
  FSource:=LabelAt('lblPackingSource',54,38);
  FSource.WordWrap:=False; FSource.EllipsisPosition:=epPathEllipsis; FSource.ShowHint:=True;
  FStep:=LabelAt('lblPackingStep',100,22); FStepBar:=BarAt('pbPackingStep',126);
  FCounts:=LabelAt('lblPackingCounts',160,24); FOverall:=BarAt('pbPackingOverall',190);
  FSize:=LabelAt('lblPackingSize',224,26); FTime:=LabelAt('lblPackingTime',260,24);
  FNote:=LabelAt('lblPackingNote',296,48);
  FNote.Caption:='Исходные книги сохраняются. При отмене готовые архивы останутся для продолжения. Объём ниже относится к обработанной части, без каталога и временных файлов.';
  FCancelButton:=TButton.Create(Self); FCancelButton.Parent:=Self;
  FCancelButton.Name:='btnCancelPacking'; FCancelButton.SetBounds(520,356,144,28);
  FCancelButton.Anchors:=[akRight,akBottom]; FCancelButton.Caption:='Отменить';
  FCancelButton.Cancel:=True; FCancelButton.OnClick:=CancelClick;
  FContinueButton:=TButton.Create(Self); FContinueButton.Parent:=Self;
  FContinueButton.Name:='btnContinuePacking'; FContinueButton.SetBounds(344,356,164,28);
  FContinueButton.Anchors:=[akRight,akBottom]; FContinueButton.Caption:='Начать упаковку';
  FContinueButton.Visible:=False; FContinueButton.OnClick:=ContinueClick;
  FTimer:=TTimer.Create(Self); FTimer.Enabled:=False; FTimer.Interval:=100; FTimer.OnTimer:=Poll;
  OnCloseQuery:=Closing;
  if MHLThemeDark then ApplyMHLControlTheme(Self);
end;

destructor TfrmCollectionPackingProgress.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  if Assigned(FThread) then begin RequestCancel; FThread.WaitFor; FreeAndNil(FThread); end;
  FSnapshot.Free; FReviewEvent.Free; FLock.Free; inherited;
end;

procedure TfrmCollectionPackingProgress.RequestCancel;
begin
  TInterlocked.Exchange(FCancel,1); FCancelButton.Enabled:=False;
  if FThread is TCollectionPackingInpxWorker then TCollectionPackingInpxWorker(FThread).Canceled:=True;
  FContinueButton.Visible:=False; FReviewEvent.SetEvent;
  FStage.Caption:='Отменяем сжатие…';
  FNote.Caption:='Дождитесь завершения текущего шага. Готовые архивы сохранятся; при следующем запуске выберите ту же папку, чтобы продолжить.';
end;

procedure TfrmCollectionPackingProgress.CancelClick(Sender: TObject);
begin RequestCancel; end;

procedure TfrmCollectionPackingProgress.ContinueClick(Sender: TObject);
begin
  FContinueButton.Visible:=False;
  TInterlocked.Exchange(FReviewPending,0);
  FNote.Caption:='Размеры относятся к обработанной части. Временное место проверяется перед распаковкой каждого архива.';
  FReviewEvent.SetEvent;
end;

procedure TfrmCollectionPackingProgress.Closing(Sender: TObject; var CanClose: Boolean);
begin
  CanClose:=ThreadDone;
  if not CanClose then RequestCancel;
end;

function TfrmCollectionPackingProgress.ThreadDone: Boolean;
begin
  Result:=not Assigned(FThread) or (WaitForSingleObject(FThread.Handle,0)=WAIT_OBJECT_0);
end;

procedure TfrmCollectionPackingProgress.ReceiveStatus(const Status: TCollectionPackingStatus);
begin
  System.TMonitor.Enter(FLock);
  try FStatus:=Status; finally System.TMonitor.Exit(FLock); end;
end;

procedure TfrmCollectionPackingProgress.Review(const Status: TCollectionPackingStatus);
begin
  ReceiveStatus(Status);
  TInterlocked.Exchange(FReviewPending,1);
  FReviewEvent.WaitFor(INFINITE);
end;

function TfrmCollectionPackingProgress.ReadStatus: TCollectionPackingStatus;
begin
  System.TMonitor.Enter(FLock);
  try Result:=FStatus; finally System.TMonitor.Exit(FLock); end;
end;

procedure TfrmCollectionPackingProgress.RenderStatus(const Status: TCollectionPackingStatus);
var Remaining: Int64;
begin
  if TInterlocked.CompareExchange(FCancel,0,0)=0 then FStage.Caption:=Status.Stage;
  FSource.Caption:=Status.SourceName;
  FSource.Hint:=Status.SourceName;
  FStep.Caption:='Текущий этап';
  if Status.Total>0 then
  begin
    FStep.Caption:=Format('Текущий этап: %d из %d',[Status.Current,Status.Total]);
    FStepBar.Style:=pbstNormal;
    FStepBar.Position:=Round(EnsureRange(Status.Current/Status.Total,0.0,1.0)*1000);
  end else FStepBar.Style:=pbstMarquee;
  if Status.SourcesTotal>0 then
  begin
    FCounts.Caption:=Format('Архивы и файлы: %d из %d · Записей книг: %d из %d',
      [Status.SourcesDone,Status.SourcesTotal,Status.BooksDone,Status.BooksTotal]);
    FOverall.Style:=pbstNormal;
    FOverall.Position:=Round(EnsureRange(Status.SourcesDone/Status.SourcesTotal,0.0,1.0)*1000);
  end
  else begin FCounts.Caption:='Проверяем каталог и расположение книг…'; FOverall.Style:=pbstMarquee; end;
  if Status.Unavailable>0 then FCounts.Caption:=FCounts.Caption+Format(' · Без файла: %d',[Status.Unavailable]);
  FSize.Caption:='Готовая часть: '+PackingSize(Status.InputBytes)+' → '+PackingSize(Status.OutputBytes);
  if Status.Reused>0 then FSize.Caption:=FSize.Caption+Format(' · Повторно использовано: %d',[Status.Reused]);
  FTime.Caption:='Прошло: '+PackingTime(Status.ElapsedMS div 1000);
  Remaining:=PackingRemainingSeconds(Status);
  if Remaining>=0 then FTime.Caption:=FTime.Caption+' · Осталось примерно: '+PackingTime(Remaining);
end;

procedure TfrmCollectionPackingProgress.Poll(Sender: TObject);
var Status: TCollectionPackingStatus;
begin
  Status:=ReadStatus; Status.ElapsedMS:=GetTickCount64-FStarted; RenderStatus(Status);
  if (TInterlocked.CompareExchange(FReviewPending,0,0)<>0) and
    (TInterlocked.CompareExchange(FCancel,0,0)=0) then
  begin
    FStage.Caption:='Папка проверена. '+PackingImageProfileCaption(FImageProfile)+'.';
    FCounts.Caption:=Format('Записей с файлами: %d · Без файла: %d',[Status.BooksTotal,Status.Unavailable]);
    FSize.Caption:='Новые исходные файлы: '+PackingSize(Status.PlannedInputBytes)+
      ' · Рабочая копия каталога: '+PackingSize(Status.WorkingBytes);
    if Status.FreeBytes>=0 then FTime.Caption:='Свободно после подготовки: '+PackingSize(Status.FreeBytes);
    FNote.Caption:='Объём исходных файлов даёт ориентир. Итоговый размер зависит от книг и повторного использования архивов. При распаковке потребуется временное место.';
    FContinueButton.Visible:=True;
  end;
  if ThreadDone then
  begin FTimer.Enabled:=False; ModalResult:=mrOk; end;
end;

function TfrmCollectionPackingProgress.Execute(const Options: TCollectionPackingOptions;
  ReviewEstimate: Boolean; const Inpx, UpdateRoot: string): TCollectionPackingSnapshot;
var Worker: TCollectionPackingInpxWorker;
begin
  if FStarted<>0 then raise Exception.Create('Для новой операции откройте новое окно сжатия.');
  FStarted:=GetTickCount64;
  FImageProfile:=Options.ImageProfile;
  Worker:=nil;
  if Inpx<>'' then
  begin
    Caption:='Обновление сжатой коллекции';
    Worker:=TCollectionPackingInpxWorker.Create(Options,Inpx,UpdateRoot,
      procedure(const Stage:string; Current,Total:Int64) begin ReceiveStatus(Worker.ReadStatus); end,
      procedure(const Status:TCollectionPackingStatus) begin if ReviewEstimate then Review(Status); end);
    FThread:=Worker;
  end
  else
    FThread:=TThread.CreateAnonymousThread(procedure
      begin
        FSnapshot:=TCollectionPackingSnapshot.Create(Options);
        FSnapshot.Prepare(function:Boolean begin Result:=TInterlocked.CompareExchange(FCancel,0,0)<>0; end,
          procedure(const Stage:string; Current,Total:Int64) begin ReceiveStatus(FSnapshot.Status); end);
        if ReviewEstimate then Review(FSnapshot.Status);
        FSnapshot.Pack; FSnapshot.ApplyPrepared;
      end);
  FThread.FreeOnTerminate:=False;
  try
    FThread.Start; FTimer.Enabled:=True;
    try ShowModal;
    finally
      if not ThreadDone then RequestCancel;
      FThread.WaitFor; FTimer.Enabled:=False;
    end;
    if TInterlocked.CompareExchange(FCancel,0,0)<>0 then
      raise EAbort.Create('Сжатие отменено. Готовые архивы сохранены для продолжения.');
    if FThread.FatalException is Exception then
      raise Exception.Create(Exception(FThread.FatalException).Message);
    if Assigned(Worker) then Exit(Worker.TakeSnapshot);
    FSnapshot.ClearNotifications; Result:=FSnapshot; FSnapshot:=nil;
  finally FreeAndNil(FThread); end;
end;

end.
