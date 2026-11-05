unit unit_BookReviewPreview;

interface

uses System.Classes, System.SysUtils, Vcl.ExtCtrls, BookInfoPanel, frm_book_info;

type
  TSavePreviewReview = reference to function(const Previous, Review: string;
    out Failure: string): Boolean;

  // One controller per preview. Only the bounded HTTP worker runs off the UI
  // thread; reading/writing a captured book identity stays on the UI thread.
  TBookReviewPreview = class(TComponent)
  private
    FPanel: TInfoPanel;
    FTimer: TTimer;
    FWorker: TReviewDownloadThread;
    FLoad: TLoadSavedBookReview;
    FSave: TSavePreviewReview;
    FURL, FPrevious: string;
    procedure Request;
    procedure Progress(Sender: TObject);
    procedure Finish(Sender: TObject);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor CreateFor(AOwner: TComponent; Panel: TInfoPanel);
    destructor Destroy; override;
    procedure Configure(const URL: string; const Load: TLoadSavedBookReview;
      const Save: TSavePreviewReview);
    procedure Cancel;
  end;

implementation

uses unit_ReviewParser;

constructor TBookReviewPreview.CreateFor(AOwner: TComponent; Panel: TInfoPanel);
begin
  inherited Create(AOwner);
  FPanel := Panel;
  FPanel.FreeNotification(Self);
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 200;
  FTimer.OnTimer := Progress;
end;

destructor TBookReviewPreview.Destroy;
begin
  Cancel;
  if Assigned(FPanel) then
  begin
    FPanel.ConfigureReviews(nil);
    FPanel.RemoveFreeNotification(Self);
  end;
  inherited;
end;

procedure TBookReviewPreview.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation = opRemove) and (AComponent = FPanel) then
  begin FPanel := nil; Cancel; end;
end;

procedure TBookReviewPreview.Cancel;
var Worker: TReviewDownloadThread;
begin
  if Assigned(FTimer) then FTimer.Enabled := False;
  Worker := FWorker;
  FWorker := nil;
  if Assigned(Worker) then
  begin
    // No wait on close or book change, and no callback to an obsolete panel.
    Worker.OnTerminate := nil;
    Worker.Cancel;
  end;
end;

procedure TBookReviewPreview.Configure(const URL: string; const Load: TLoadSavedBookReview;
  const Save: TSavePreviewReview);
var Action: TProc;
begin
  Cancel;
  FURL := URL; FLoad := Load; FSave := Save;
  Action := nil;
  if IsLibraryReviewURL(URL) then Action := procedure begin Request; end;
  FPanel.ConfigureReviews(Load, Action, procedure begin Cancel; end);
  if not Assigned(Action) then
    FPanel.SetReviewDownloadState('Для этой книги нет адреса отзывов на сайте источника.', False);
end;

procedure TBookReviewPreview.Request;
begin
  if Assigned(FWorker) then
  begin
    FWorker.Cancel;
    FPanel.SetReviewDownloadState('Останавливаем загрузку…', True);
    Exit;
  end;
  if not Assigned(FPanel) or not Assigned(FLoad) or not IsLibraryReviewURL(FURL) then Exit;
  FPrevious := FLoad();
  FPanel.SetSavedReview(FPrevious);
  FWorker := TReviewDownloadThread.Create(FURL);
  FWorker.OnTerminate := Finish;
  FPanel.SetReviewDownloadState('Загружаем отзывы с сайта источника…', True);
  FTimer.Enabled := True;
  FWorker.Start;
end;

procedure TBookReviewPreview.Progress(Sender: TObject);
begin
  if not Assigned(FWorker) or not Assigned(FPanel) then Exit;
  FWorker.Parser.CheckDeadline;
  if FWorker.Parser.Cancelled then Exit;
  case FWorker.Parser.Phase of
    2: FPanel.SetReviewDownloadState('Повторный запрос к сайту (2 из 2)…', True);
    3: FPanel.SetReviewDownloadState('Сайт не ответил. Через секунду повторим запрос один раз.', True);
  end;
end;

procedure TBookReviewPreview.Finish(Sender: TObject);
var Worker: TReviewDownloadThread; Status, Review: string;
begin
  if Sender <> FWorker then Exit;
  Worker := FWorker; FWorker := nil;
  FTimer.Enabled := False;
  if not Assigned(FPanel) then Exit;
  if Worker.Parser.Cancelled then
  begin
    if Worker.Parser.Expired <> 0 then
      Status := 'Сайт не ответил вовремя. Сохранённые отзывы оставлены.'
    else Status := 'Загрузка отменена. Сохранённые отзывы оставлены.';
  end
  else if Worker.ErrorText <> '' then
    Status := 'Не удалось загрузить отзывы: ' + Worker.ErrorText + ' Сохранённые отзывы оставлены.'
  else if Worker.Review.Text.Trim = '' then
    Status := 'На странице книги нет отзывов. Сохранённые отзывы оставлены.'
  else
  begin
    Review := 'Источник: ' + FURL + sLineBreak + sLineBreak + Worker.Review.Text.Trim;
    try
      if Assigned(FSave) and FSave(FPrevious, Review, Status) then
      begin
        FPanel.SetSavedReview(Review);
        Status := 'Отзывы загружены и сохранены.';
      end
      else if Status = '' then Status := 'Не удалось сохранить отзывы. Прежний текст оставлен.';
    except
      on E: Exception do Status := 'Не удалось сохранить отзывы: ' + E.Message + ' Прежний текст оставлен.';
    end;
  end;
  FPanel.SetReviewDownloadState(Status, False);
end;

end.
