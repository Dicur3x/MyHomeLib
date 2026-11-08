type
  TReviewHTTPClock = class
    Ticks: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure TReviewHTTPClock.Tick(Sender: TObject);
begin Inc(Ticks); end;

procedure TestReviewHTTP;
var Details: TfrmBookDetails; URL: string; Started: UInt64; Clock: TReviewHTTPClock;
  Timer: TTimer; BeforeTicks: Integer;
  procedure WaitDownload(Limit: Cardinal = 20000; ReviewReadOnly: Boolean = False);
  var WaitingSince: UInt64;
  begin
    WaitingSince := GetTickCount64;
    while Assigned(Details.Downloading) do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64 - WaitingSince < Limit, 'Review request hung: '+Details.URL+'; '+Details.ReviewStatus.Caption);
    end;
    Require((Details.mmReview.ReadOnly=ReviewReadOnly) and not Details.mmoAnnotation.ReadOnly,
      'Review completion did not restore editor state');
  end;
  procedure SavedText;
  begin
    Details.Review := 'Не терять этот отзыв';
    Details.Annotation := 'Не терять эту аннотацию';
    Details.ReviewChanged := False;
  end;
  procedure RequirePreserved;
  begin
    Require((Details.Review.Trim = 'Не терять этот отзыв') and
      (Details.Annotation.Trim = 'Не терять эту аннотацию') and not Details.ReviewChanged,
      'Failed/cancelled request changed saved review, annotation or dirty flag');
  end;
  procedure StartBook(const ID: string);
  begin Writeln('TRACE review book '+ID); Details.AllowOnlineReview(URL + ID + '/'); Details.Download; end;
begin
  URL := 'http://127.0.0.1:' + ParamStr(2) + '/b/';
  Clock := TReviewHTTPClock.Create; Timer := TTimer.Create(nil);
  Details := TfrmBookDetails.Create(nil);
  try
    Timer.Interval := 50; Timer.OnTimer := Clock.Tick;
    Details.Review := 'Сохранённый отзыв';
    Require(not Details.ReviewChanged, 'Showing saved reviews counts as an edit');
    StartBook('1'); WaitDownload;
    Require((Pos('Читатель:'+sLineBreak+'Очень хорошая книга'+sLineBreak+sLineBreak+'Второй абзац.', Details.Review) > 0) and
      (Pos(sLineBreak+sLineBreak+'Другой читатель:'+sLineBreak+'Отдельный отзыв.',Details.Review)>0),
      'HTTP UTF-8 reviews lost paragraphs or reviewer boundaries');
    SavedText; StartBook('2'); WaitDownload; RequirePreserved;
    Require(Pos('HTTP 503',Details.ReviewStatus.Caption)>0, 'Final HTTP failure hidden');
    StartBook('3'); WaitDownload; RequirePreserved;
    Require(Pos('Не удалось',Details.ReviewStatus.Caption)=1, 'Blocked page hidden');
    StartBook('5'); WaitDownload; RequirePreserved;
    Require(Pos('нет отзывов',Details.ReviewStatus.Caption)>0, 'Empty review page hidden');

    BeforeTicks := Clock.Ticks; Started := GetTickCount64;
    StartBook('6'); WaitDownload;
    Require((GetTickCount64-Started>=6500) and (Clock.Ticks-BeforeTicks>=40),
      'Timeout retry did not use real network waiting or blocked UI timer');
    Require(Pos('Очень хорошая книга',Details.Review)>0, 'Timeout retry did not recover');
    SavedText; StartBook('7'); WaitDownload(35000); RequirePreserved;
    Require((Pos('не ответил вовремя',Details.ReviewStatus.Caption)>0) and
      (Pos('Error receiving',Details.ReviewStatus.Caption)=0), 'Timeout message not localized');
    Details.btnLoadReview.Click; WaitDownload;
    Require(Pos('Очень хорошая книга',Details.Review)>0, 'Manual retry after two failures not available');

    SavedText; StartBook('8'); Started := GetTickCount64;
    while Assigned(Details.Downloading) and (Details.Downloading.Parser.Phase<>3) do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64-Started<3000,'Backoff state not reached');
    end;
    Require(Assigned(Details.Downloading),'Expected active retry pause');
    Details.btnLoadReview.Click; WaitDownload(1000); RequirePreserved;
    Require(Pos('отменена',Details.ReviewStatus.Caption)>0,'Cancelled backoff status missing');
    StartBook('9'); WaitDownload; RequirePreserved;
    Require(Pos('HTTP 403',Details.ReviewStatus.Caption)>0,'HTTP access error hidden');
    StartBook('10'); WaitDownload; RequirePreserved;
    StartBook('11'); WaitDownload; RequirePreserved;
    Require(Details.btnAnnotationSite.Enabled,'The description has no site source action');
    Details.btnAnnotationSite.Click; WaitDownload;
    Require((Details.Review.Trim='Не терять этот отзыв') and Details.ReviewChanged and
      (Details.Annotation.Trim='Только новая аннотация'), 'Explicit site description changed the review or did not apply');
    SavedText; StartBook('12'); WaitDownload; RequirePreserved;
    Details.mmReview.ReadOnly:=True;
    StartBook('1'); WaitDownload(20000,True);
    Require(Details.Review.Contains('Очень хорошая книга') and not Details.ReviewChanged and
      (Details.Annotation.Trim='Не терять эту аннотацию'),'Read-only reviews were hidden or treated as a saved edit');
  finally Details.Free; Timer.Free; Clock.Free; end;

  Details := TfrmBookDetails.Create(nil);
  try
    SavedText; StartBook('4'); Started := GetTickCount64;
    while not FileExists(Settings.AppPath + 'review-request-started.marker') do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64-Started<5000,'Cancellation test did not start HTTP request');
    end;
    Started := GetTickCount64; Details.btnLoadReview.Click;
    Require(GetTickCount64-Started<200,'Cancel button waited for network');
    WaitDownload(1000); RequirePreserved;
  finally Details.Free; end;

  System.SysUtils.DeleteFile(Settings.AppPath + 'review-request-started.marker');
  Details := TfrmBookDetails.Create(nil); StartBook('4'); Started := GetTickCount64;
  while not FileExists(Settings.AppPath + 'review-request-started.marker') do
  begin
    Application.ProcessMessages; CheckSynchronize(10);
    Require(GetTickCount64-Started<5000,'Closing test did not start HTTP request');
  end;
  Started := GetTickCount64; Details.Free;
  Require(GetTickCount64-Started<200,'Closing reviews waits for network');
  Started := GetTickCount64;
  while GetTickCount64-Started<1300 do
  begin Application.ProcessMessages; CheckSynchronize(10); end;
  Writeln('PASS HTTP reviews decode UTF-8, bounded timeout/503 retry, manual retry, responsive cancel/close, preserved review and annotation, annotation-only persistence');
end;

procedure TestReviewDeadline;
var Details: TfrmBookDetails; Started: UInt64;
begin
  Details := TfrmBookDetails.Create(nil);
  try
    Details.Review := 'Сохранённый отзыв'; Details.Annotation := 'Сохранённая аннотация';
    Details.ReviewChanged := False;
    Details.AllowOnlineReview('http://127.0.0.1:'+ParamStr(2)+'/b/13/'); Details.Download;
    Started := GetTickCount64;
    while Assigned(Details.Downloading) do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64-Started<35000,'Slow response bypassed total request deadline');
    end;
    Require((GetTickCount64-Started>=29000) and
      (Pos('не ответил вовремя',Details.ReviewStatus.Caption)>0) and
      (Details.Review.Trim='Сохранённый отзыв') and
      (Details.Annotation.Trim='Сохранённая аннотация') and not Details.ReviewChanged,
      'Slow response was published or total deadline was not explained');
    Writeln('PASS continuous slow HTTP response stops at 30-second total deadline and preserves saved text');
  finally Details.Free; end;
end;
