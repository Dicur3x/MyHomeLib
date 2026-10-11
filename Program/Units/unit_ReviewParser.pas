
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
    function Extract(const page: string; const idxReviewBlockStart: Integer; const before: string; const after: string): string;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Parse(const url: string; targetList, targetlistA: TStringList);
    procedure ParsePage(const PageText, URL: string; targetList, targetlistA: TStringList);
  end;

function IsLibraryReviewURL(const URL: string): Boolean;

implementation

uses
  SysUtils,
  unit_Globals,
  unit_MHLHttpClient, System.RegularExpressions, unit_UpdateNotes;

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

procedure TReviewParser.ParsePage(const PageText, URL: string; targetList, targetlistA: TStringList);
const
  NAME_REVIEW_DELIM = ':';
var
  page: string;
  idxReviewBlockStart: Integer;
  idxReviewBlockEnd: Integer;
  idxEndAllBookReviews: Integer;
  name: string;
  review: string;
  BLOCK_PREFIX, BLOCK_END, END_ALL, ANNOTATION_START, ANNOTATION_END: string;

begin
  Assert(Assigned(targetList));
  Assert(Assigned(targetListA));

  page := PageText;
  targetList.Clear; targetListA.Clear;
  if (Pos('<h2', LowerCase(page)) = 0) and (Pos('/polka/show/', page) = 0) and
    (Pos('newann', page) = 0) then
    raise Exception.Create('Сайт вернул страницу без сведений о книге (возможна блокировка или смена формата).');




  if pos('lib.rus.ec', URL) <> 0 then
  begin
    ANNOTATION_START := '<h2>Аннотация</h2>';
    ANNOTATION_END := '<h3>';

    BLOCK_PREFIX := '/polka/show/';
    BLOCK_END := '<hr>';
    END_ALL := '/stat/r/';
  end
  else begin
    ANNOTATION_START := '<h2>Аннотация</h2>';
    ANNOTATION_END := '<form';

    BLOCK_PREFIX := '/polka/show/';
    BLOCK_END := '<div></div>';
    END_ALL := 'newann';

  end;

  idxReviewBlockStart := Pos(ANNOTATION_START, page);
  Delete(page, 1 , idxReviewBlockStart);
  idxReviewBlockStart := 1;
  idxEndAllBookReviews := Pos(ANNOTATION_END, page);

  // Сравнивается в условии цикла еще до первого присвоения внутри него
  idxReviewBlockEnd := 0;

  while ((idxReviewBlockStart <> idxReviewBlockEnd) and (idxReviewBlockStart < idxEndAllBookReviews)) do
  begin
    idxReviewBlockStart := PosEx('<p>', page, idxReviewBlockStart);
    idxReviewBlockEnd := PosEx('</p>', page, idxReviewBlockStart);

    if idxReviewBlockEnd > idxEndAllBookReviews then Break;


    review := Copy(page, idxReviewBlockStart + 3, idxReviewBlockEnd - 3 - idxReviewBlockStart);
    if review <> '' then targetlistA.Add(review);
    idxReviewBlockStart := PosEx('<p>', page, idxReviewBlockEnd);
  end;

  targetListA.Text := ReplaceStr(targetListA.Text,'<br />','');
  targetListA.Text := ReplaceStr(targetListA.Text,'<br>','');



  idxReviewBlockStart := Pos(BLOCK_PREFIX, page);
  idxEndAllBookReviews := Pos(END_ALL, page);
  while ((idxReviewBlockStart <> 0) and (idxReviewBlockStart < idxEndAllBookReviews)) do
  begin
    name := Extract(page, idxReviewBlockStart, '>', '<');
    review := Extract(page, idxReviewBlockStart, '<br>', BLOCK_END);
    targetList.Add(name + NAME_REVIEW_DELIM);
    targetList.Add(review);
    targetList.Add('');
    idxReviewBlockStart := PosEx(BLOCK_PREFIX, page, idxReviewBlockStart + 1);
  end;

  targetList.Text := ReplaceStr(targetList.Text,'&quot;','"');
  targetList.Text := ReplaceStr(targetList.Text,'&gt;','');
  targetList.Text := ReplaceStr(targetList.Text,'<hr>','');
  targetList.Text := SQLiteNotesToMarkdown(targetList.Text);
  targetListA.Text := SQLiteNotesToMarkdown(targetListA.Text);
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

function TReviewParser.Extract(const page: string; const idxReviewBlockStart: Integer; const before: string; const after: string): string;
var
  idxNameStart: Integer;
  idxNameEnd: Integer;
  lenName: Integer;
begin
  Assert(idxReviewBlockStart > 0);
  Result := '';

  idxNameStart := PosEx(before, page, idxReviewBlockStart + 1);
  if (idxNameStart <> 0) then
  begin
    idxNameStart := idxNameStart + Length(before);
    idxNameEnd := PosEx(after, page, idxNameStart);
    if (idxNameEnd <> 0) then
    begin
      lenName := idxNameEnd - idxNameStart;
      Result := Copy(page, idxNameStart, lenName);
      Result := ReplaceStr(Result, '<br>', '');
    end;
  end;
end;

end.
