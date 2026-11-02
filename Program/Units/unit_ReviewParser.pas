
unit unit_ReviewParser;

interface

uses
  Classes,
  StrUtils,
  System.SyncObjs,
  System.Net.HttpClient;

type
  TReviewParser = class
  strict private
    FHTTPClient: THTTPClient;
    FRequest: IHTTPRequest;
    FRequestLock: TObject;
    FCancel: TEvent;
    FStarted: UInt64;
    FPhase, FExpired: Integer;

    function GetPage(const url: string): string;
    function GetCancelled: Boolean;
    function GetPhase: Integer;
    procedure ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);

  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    procedure CheckDeadline;
    property Cancelled: Boolean read GetCancelled;
    property Expired: Integer read FExpired;
    property Phase: Integer read GetPhase;

    procedure Parse(const url: string; targetList, targetlistA: TStringList);
    procedure ParsePage(const PageText, URL: string; targetList, targetlistA: TStringList);
  end;

function IsLibraryReviewURL(const URL: string): Boolean;

implementation

uses
  SysUtils, System.Math, Winapi.Windows, System.Net.URLClient,
  unit_Globals,
  unit_MHLHttpClient, System.RegularExpressions, System.NetEncoding, unit_Diagnostics;

function IsLibraryReviewURL(const URL: string): Boolean;
begin
  // Merged IDs and arbitrary local IDs must never become a remote book number.
  Result := TRegEx.IsMatch(URL, '^https?://[^/\s]+/b/[0-9]+/?$', [roIgnoreCase]);
end;

type
  TReviewPageStream = class(TMemoryStream)
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

function TReviewPageStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (Position + Count > 4 * 1024 * 1024) then
    raise EStreamError.Create('Ответ сайта слишком велик.');
  Result := inherited Write(Buffer, Count);
end;

constructor TReviewParser.Create;
begin
  inherited Create;
  FRequestLock := TObject.Create;
  FCancel := TEvent.Create(nil, True, False, '');
  FStarted := GetTickCount64;
  FHTTPClient := CreateHTTPClientGlobal;
  FHTTPClient.ConnectionTimeout := 5000;
  FHTTPClient.ResponseTimeout := 7000;
  FHTTPClient.OnReceiveData := ReceiveData;
end;

destructor TReviewParser.Destroy;
begin
  FreeAndNil(FHTTPClient);
  FCancel.Free;
  FRequestLock.Free;
  inherited Destroy;
end;

function TReviewParser.GetCancelled: Boolean;
begin
  Result := FCancel.WaitFor(0) = wrSignaled;
end;

function TReviewParser.GetPhase: Integer;
begin
  Result := TInterlocked.CompareExchange(FPhase, 0, 0);
end;

procedure TReviewParser.Cancel;
var Request: IHTTPRequest;
begin
  FCancel.SetEvent;
  TMonitor.Enter(FRequestLock);
  try Request := FRequest; finally TMonitor.Exit(FRequestLock); end;
  // Keep a local interface reference: completion can release the active request.
  if Assigned(Request) then Request.Cancel;
end;

procedure TReviewParser.CheckDeadline;
begin
  if not Cancelled and (GetTickCount64 - FStarted >= 30000) then
  begin TInterlocked.Exchange(FExpired, 1); Cancel; end;
end;

procedure TReviewParser.ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);
begin
  CheckDeadline;
  Abort := Cancelled;
end;

procedure TReviewParser.Parse(const url: string; targetList, targetlistA: TStringList);
begin
  ParsePage(GetPage(URL), URL, targetList, targetlistA);
  if Cancelled then begin targetList.Clear; targetlistA.Clear; end;
end;

// Reviews are ordinary text, not release-note Markdown. Keep HTML block/break
// boundaries before discarding tags, and never join separate reviewers together.
function ReviewHTMLToText(const HTML: string): string;
var Token: TMatch; Tag, Value, Text: string; Lines: TStringList; Line: TStringBuilder;
  procedure Flush(Paragraph: Boolean);
  begin
    Value:=TRegEx.Replace(Line.ToString,'\s+',' ').Trim; Line.Clear;
    if Value<>'' then Lines.Add(Value);
    if Paragraph and (Lines.Count>0) and (Lines[Lines.Count-1]<>'') then Lines.Add('');
  end;
begin
  Lines:=TStringList.Create; Line:=TStringBuilder.Create;
  try
    Text:=TRegEx.Replace(HTML,'(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>','');
    for Token in TRegEx.Matches(Text,'<[^>]*>|[^<]+') do
    begin
      Tag:=LowerCase(Token.Value);
      if TRegEx.IsMatch(Tag,'^</?(?:p|div|blockquote|h[1-6]|ul|ol|table|tr)\b') then Flush(True)
      else if TRegEx.IsMatch(Tag,'^<br\b') then
      begin
        if Line.Length=0 then Flush(True) else Flush(False);
      end
      else if TRegEx.IsMatch(Tag,'^<li\b') then begin Flush(False); Line.Append('• '); end
      else if TRegEx.IsMatch(Tag,'^</li\b') then Flush(False)
      else if TRegEx.IsMatch(Tag,'^</?(?:td|th)\b') then Line.Append(' ')
      else if not Tag.StartsWith('<') then Line.Append(TNetEncoding.HTML.Decode(Token.Value));
    end;
    Flush(False); Result:=Lines.Text.Trim;
  finally Line.Free; Lines.Free; end;
end;

procedure TReviewParser.ParsePage(const PageText, URL: string; targetList, targetlistA: TStringList);
const
  REVIEW_ANCHOR='(?is)<a\b[^>]*\bhref\s*=\s*["''][^"'']*/polka/show/[^"'']*["''][^>]*>(.*?)</a\s*>';
var Page, Body, Name, Review: string; Authors: TMatchCollection; Heading, Boundary, BreakTag, FirstBlock: TMatch;
  I, StartAt, EndAt, ReviewsEnd: Integer; IsLibrusec: Boolean;
begin
  Assert(Assigned(targetList)); Assert(Assigned(targetlistA));
  if Length(PageText)>4*1024*1024 then raise EStreamError.Create('Ответ сайта слишком велик.');
  Page:=TRegEx.Replace(PageText,'(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>','');
  if not TRegEx.IsMatch(Page,'(?i)<h2\b|/polka/show/|newann') then
    raise Exception.Create('Сайт вернул страницу без сведений о книге (возможна блокировка или смена формата).');
  targetList.Clear; targetListA.Clear;
  // Delphi regex indices are 1-based; EndAt/ReviewsEnd are exclusive.
  Authors:=TRegEx.Matches(Page,REVIEW_ANCHOR);
  Heading:=TRegEx.Match(Page,'(?is)<h2\b[^>]*>\s*(?:<[^>]+>\s*)*Аннотация\s*(?:<[^>]+>\s*)*</h2\s*>');
  if Heading.Success then
  begin
    StartAt:=Heading.Index+Heading.Length; EndAt:=Length(Page)+1;
    Boundary:=TRegEx.Match(Copy(Page,StartAt,MaxInt),'(?is)<form\b|<h[1-6]\b|'+REVIEW_ANCHOR);
    if Boundary.Success then EndAt:=StartAt+Boundary.Index-1;
    targetListA.Text:=ReviewHTMLToText(Copy(Page,StartAt,EndAt-StartAt));
  end;
  IsLibrusec:=Pos('lib.rus.ec',LowerCase(URL))>0; ReviewsEnd:=Length(Page)+1;
  Boundary:=TRegEx.Match(Page,'(?is)<[a-z][^>]*\b(?:id|name)\s*=\s*["'']newann["''][^>]*>|'+
    '<a\b[^>]*\bhref\s*=\s*["''][^"'']*/stat/r/[^"'']*["''][^>]*>');
  if Boundary.Success then ReviewsEnd:=Boundary.Index;
  for I:=0 to Authors.Count-1 do
  begin
    if Authors[I].Index>=ReviewsEnd then Break;
    StartAt:=Authors[I].Index+Authors[I].Length; EndAt:=ReviewsEnd;
    if I+1<Authors.Count then EndAt:=Min(EndAt,Authors[I+1].Index);
    Body:=Copy(Page,StartAt,EndAt-StartAt);
    BreakTag:=TRegEx.Match(Body,'(?is)<br\b[^>]*>');
    FirstBlock:=TRegEx.Match(Body,'(?is)<(?:p|div|blockquote|ul|ol|table)\b');
    if BreakTag.Success and (not FirstBlock.Success or (BreakTag.Index<FirstBlock.Index)) then
      Delete(Body,1,BreakTag.Index+BreakTag.Length-1);
    if IsLibrusec then Boundary:=TRegEx.Match(Body,'(?is)<hr\b[^>]*>|<form\b')
    else Boundary:=TRegEx.Match(Body,'(?is)<div\b[^>]*>\s*</div\s*>|<form\b');
    if Boundary.Success then Body:=Copy(Body,1,Boundary.Index-1);
    Name:=ReviewHTMLToText(Authors[I].Groups[1].Value); Review:=ReviewHTMLToText(Body);
    if (Name='') or (Review='') then Continue;
    if targetList.Count>0 then targetList.Add('');
    targetList.Add(Name+':'); targetList.Add(Review);
  end;
end;

function TReviewParser.GetPage(const url: string): string;
var Stream: TReviewPageStream; Response: IHTTPResponse; Bytes: TBytes;
  Request: IHTTPRequest; Attempt: Integer; Retryable, TimedOut: Boolean; Failure: string;
begin
  if not IsLibraryReviewURL(URL) then
    raise Exception.Create('Для книги нет корректного адреса отзывов.');
  Stream := TReviewPageStream.Create;
  try
    for Attempt := 1 to 2 do
    begin
      CheckDeadline;
      if Cancelled then Abort;
      TInterlocked.Exchange(FPhase, Attempt);
      if Attempt = 1 then FHTTPClient.ResponseTimeout := 7000
      else FHTTPClient.ResponseTimeout := 15000;
      Stream.Clear; Retryable := False;
      try
        Request := FHTTPClient.GetRequest('GET', URL);
        TMonitor.Enter(FRequestLock);
        try FRequest := Request; finally TMonitor.Exit(FRequestLock); end;
        try
          if Cancelled then Abort;
          Response := FHTTPClient.Execute(Request, Stream);
        finally
          TMonitor.Enter(FRequestLock);
          try FRequest := nil; finally TMonitor.Exit(FRequestLock); end;
        end;
        CheckDeadline;
        if Cancelled then Abort;
        if Response.StatusCode <> 200 then
        begin
          // Respect a server-requested backoff; never retry access/login errors.
          Retryable := MatchText(IntToStr(Response.StatusCode), ['408', '500', '502', '503', '504']) and
            (Response.HeaderValue['Retry-After'] = '');
          raise Exception.CreateFmt('Сайт ответил HTTP %d.', [Response.StatusCode]);
        end;
        SetLength(Bytes, Stream.Size); Stream.Position := 0;
        if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[0], Length(Bytes));
        Exit(TEncoding.UTF8.GetString(Bytes));
      except
        on E: Exception do
        begin
          if Cancelled then Abort;
          LogDiagnosticError('reviews-http', E);
          TimedOut := Pos('(12002)', E.Message) > 0;
          Retryable := Retryable or
            (((E is ENetHTTPClientException) or (E is ENetHTTPRequestException)) and
            (TimedOut or (Pos('(12029)', E.Message) > 0) or
             (Pos('(12030)', E.Message) > 0) or (Pos('(12031)', E.Message) > 0)));
          Failure := E.Message;
          if (E is ENetHTTPClientException) or (E is ENetHTTPRequestException) then
            Failure := 'Ошибка соединения с сайтом. Подробности записаны в журнал ошибок.';
          if TimedOut then Failure := 'Сайт не ответил вовремя. Попробуйте позже.';
          if not Retryable or (Attempt = 2) then raise Exception.Create(Failure);
        end;
      end;
      TInterlocked.Exchange(FPhase, 3);
      // One retry only, with an interruptible pause. No access to form controls.
      if FCancel.WaitFor(1000) = wrSignaled then Abort;
    end;
  finally Stream.Free; end;
end;

end.
