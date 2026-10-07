unit unit_UpdateTextCache;

interface

uses System.Net.HttpClient;

function ReadUpdateHistory(const FileName: string; MaxBytes: Int64 = 1400000): string;
procedure WriteUpdateHistory(const FileName, Text: string);
function CachedUpdateText(HTTP: THTTPClient; const URL, CacheFolder: string;
  MaxBytes: Int64 = 8388608): string;

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Net.URLClient, Winapi.Windows;

function ReadUpdateHistory(const FileName: string; MaxBytes: Int64): string;
var Stream: TFileStream; Bytes: TBytes;
begin
  Result := '';
  try
    if not FileExists(FileName) then Exit;
    Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      if (Stream.Size < 1) or (Stream.Size > MaxBytes) then Exit;
      SetLength(Bytes, Integer(Stream.Size));
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
      Result := TEncoding.UTF8.GetString(Bytes);
      if Result.StartsWith(#$FEFF) then Delete(Result, 1, 1);
    finally Stream.Free; end;
  except Result := ''; end;
end;

procedure WriteUpdateHistory(const FileName, Text: string);
var Temporary: string;
begin
  if Text.Trim = '' then Exit; // A failed/empty response must not erase history.
  try
    if ReadUpdateHistory(FileName, 20000000) = Text then Exit;
    ForceDirectories(ExtractFilePath(FileName));
    Temporary := FileName + '.new';
    TFile.WriteAllText(Temporary, Text, TEncoding.UTF8);
    if not MoveFileEx(PChar(Temporary), PChar(FileName),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  except
    // A read-only or full cache must never turn a successful check into an error.
  end;
end;

function SafeValidator(const Value: string): Boolean;
begin
  Result := (Length(Value) <= 512) and (Pos(#13, Value) = 0) and (Pos(#10, Value) = 0);
end;

function CachedUpdateText(HTTP: THTTPClient; const URL, CacheFolder: string;
  MaxBytes: Int64): string;
var FileName, Body, ETag, Modified, StoredURL: string; Root: TJSONValue;
  Obj: TJSONObject; Headers: TNetHeaders; Response: IHTTPResponse;
  HasCache: Boolean;
begin
  FileName := ''; Body := ''; ETag := ''; Modified := ''; HasCache := False;
  if CacheFolder <> '' then
  begin
    FileName := IncludeTrailingPathDelimiter(CacheFolder) + 'http-' +
      THashSHA2.GetHashString(URL) + '.json';
    Root := TJSONObject.ParseJSONValue(ReadUpdateHistory(FileName, 2 * MaxBytes + 8192));
    try
      if Root is TJSONObject then
      begin
        Obj := TJSONObject(Root);
        HasCache := Obj.TryGetValue<string>('url', StoredURL) and (StoredURL = URL) and
          Obj.TryGetValue<string>('text', Body) and (Length(Body) <= MaxBytes);
        if HasCache then
        begin
          Obj.TryGetValue<string>('etag', ETag); Obj.TryGetValue<string>('modified', Modified);
          if not SafeValidator(ETag) then ETag := '';
          if not SafeValidator(Modified) then Modified := '';
        end;
      end;
    finally Root.Free; end;
  end;
  SetLength(Headers, 0);
  if HasCache and (ETag <> '') then
  begin SetLength(Headers, 1); Headers[0] := TNameValuePair.Create('If-None-Match', ETag); end
  else if HasCache and (Modified <> '') then
  begin SetLength(Headers, 1); Headers[0] := TNameValuePair.Create('If-Modified-Since', Modified); end;
  Response := HTTP.Get(URL, nil, Headers);
  if (Response.StatusCode = 304) and HasCache then Exit(Body);
  if Response.StatusCode <> 200 then
    raise Exception.Create('Не удалось получить сведения об обновлениях. Попробуйте позже.');
  Result := Response.ContentAsString(TEncoding.UTF8);
  if Length(Result) > MaxBytes then
    raise Exception.Create('Список изменений превышает допустимый размер.');
  if FileName = '' then Exit;
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('url', URL); Obj.AddPair('text', Result);
    ETag := Response.HeaderValue['ETag']; Modified := Response.HeaderValue['Last-Modified'];
    if SafeValidator(ETag) then Obj.AddPair('etag', ETag);
    if SafeValidator(Modified) then Obj.AddPair('modified', Modified);
    WriteUpdateHistory(FileName, Obj.ToJSON);
  finally Obj.Free; end;
end;

end.
