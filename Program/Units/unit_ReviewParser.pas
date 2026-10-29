
unit unit_ReviewParser;

interface

uses
  Classes,
  StrUtils,
  System.Net.HttpClient;

type
  TReviewParser = class
  strict private
    FHTTPClient: THTTPClient;

    function GetPage(const url: string): string;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Parse(const url: string; targetList, targetlistA: TStringList);
    procedure ParsePage(const PageText, URL: string; targetList, targetlistA: TStringList);
  end;

function IsLibraryReviewURL(const URL: string): Boolean;

implementation

uses
  SysUtils, System.Math,
  unit_Globals,
  unit_MHLHttpClient, System.RegularExpressions, System.NetEncoding;

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
  FHTTPClient := CreateHTTPClientGlobal;
  FHTTPClient.ConnectionTimeout := 5000;
  FHTTPClient.ResponseTimeout := 15000;
end;

destructor TReviewParser.Destroy;
begin
  FreeAndNil(FHTTPClient);
  inherited Destroy;
end;

procedure TReviewParser.Parse(const url: string; targetList, targetlistA: TStringList);
begin
  ParsePage(GetPage(URL), URL, targetList, targetlistA);
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
begin
  if not IsLibraryReviewURL(URL) then
    raise Exception.Create('Для книги нет корректного адреса отзывов.');
  Stream := TReviewPageStream.Create;
  try
    Response := FHTTPClient.Get(URL, Stream);
    if Response.StatusCode <> 200 then
      raise Exception.CreateFmt('Сайт ответил HTTP %d.', [Response.StatusCode]);
    SetLength(Bytes, Stream.Size); Stream.Position := 0;
    if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[0], Length(Bytes));
    Result := TEncoding.UTF8.GetString(Bytes);
  finally Stream.Free; end;
end;

end.
