(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           eg (http://forum.home-lib.net)
  * Created             12.02.2010
  * Description         A parser for Lib.rus.ec / Flibusta book reviews
  *
  * $Id: unit_ReviewParser.pas 1186 2015-05-14 05:20:24Z koreec $
  *
  * History
  *
  ****************************************************************************** *)

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
  end;

implementation

uses
  SysUtils,
  unit_Globals,
  unit_MHLHttpClient;

constructor TReviewParser.Create;
begin
  inherited Create;
  FHTTPClient := CreateHTTPClientGlobal;
end;

destructor TReviewParser.Destroy;
begin
  FreeAndNil(FHTTPClient);
  inherited Destroy;
end;

procedure TReviewParser.Parse(const url: string; targetList, targetlistA: TStringList);
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

  page := GetPage(url);

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

  // Порівнюється в умові циклу ще до першого присвоєння всередині нього
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
end;

function TReviewParser.GetPage(const url: string): string;
var
  outputStream: TMemoryStream;
  responseList: TStringList;
begin
  Result := '';

  responseList := TStringList.Create;
  try
    outputStream := TMemoryStream.Create;
    try
      FHTTPClient.Get(url, outputStream);

      outputStream.Position := 0;
      responseList.LoadFromStream(outputStream);

      if responseList.Count > 0 then
        // Сторінка приходить у UTF-8, але завантажується у список як ANSI,
        // тож повертаємо байти назад і декодуємо їх явно.
        Result := UTF8ToString(RawByteString(AnsiString(responseList.Text)));
    finally
      outputStream.Free;
    end;
  finally
    responseList.Free;
  end;
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
