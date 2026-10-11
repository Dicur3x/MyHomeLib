unit unit_MCP_TextCache;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.IOUtils,
  System.Generics.Collections,
  unit_MCP_Fb2Extract;

type
  TCachedBook = record
    TotalLength: Integer;
    Sections: TFb2Sections;
    Structured: Boolean;
  end;

const
  CACHE_CAP_BYTES = 200 * 1024 * 1024;

function CacheDir: string;

procedure EvictCache(const CapBytes: Int64 = CACHE_CAP_BYTES);

function EnsureCached(const CollectionID, BookID: Integer;
  const SourceSize: Int64; const SourceStamp: TDateTime;
  ExtractProc: TFunc<TFb2Extraction>): TCachedBook;

function ReadCachedSlice(const CollectionID, BookID: Integer;
  const SourceSize: Int64; const SourceStamp: TDateTime;
  Offset, Count: Integer): string;

procedure SetCacheDirOverrideForTests(const Dir: string);

implementation

var
  GCacheDirOverride: string = '';

procedure SetCacheDirOverrideForTests(const Dir: string);
begin
  GCacheDirOverride := Dir;
end;

function CacheDir: string;
var
  LocalAppData: string;
begin
  if GCacheDirOverride <> '' then
    Result := GCacheDirOverride
  else
  begin
    LocalAppData := GetEnvironmentVariable('LOCALAPPDATA');
    if LocalAppData = '' then
      LocalAppData := TPath.GetHomePath;
    Result := TPath.Combine(LocalAppData, 'MyHomeLib\McpCache');
  end;

  if not TDirectory.Exists(Result) then
    TDirectory.CreateDirectory(Result);
end;

const
  CACHE_TIMESTAMP_DIGITS = 17;
  CACHE_TIMESTAMP_FORMAT = 'yyyymmddhhnnsszzz';

function CacheKey(const CollectionID, BookID: Integer;
  const SourceSize: Int64; const SourceStamp: TDateTime): string;
begin
  Result := Format('%d_%d_%d_%s',
    [CollectionID, BookID, SourceSize, FormatDateTime(CACHE_TIMESTAMP_FORMAT, SourceStamp)]);
end;

function IsValidCacheKeyName(const BaseName: string): Boolean;
var
  Parts: TArray<string>;

  function IsAllDigits(const S: string): Boolean;
  var
    K: Integer;
  begin
    Result := S <> '';
    if not Result then
      Exit;
    for K := 1 to Length(S) do
      if not CharInSet(S[K], ['0'..'9']) then
        Exit(False);
  end;

begin
  Parts := BaseName.Split(['_']);
  Result := (Length(Parts) = 4) and
    IsAllDigits(Parts[0]) and IsAllDigits(Parts[1]) and IsAllDigits(Parts[2]) and
    IsAllDigits(Parts[3]) and (Length(Parts[3]) = CACHE_TIMESTAMP_DIGITS);
end;

function TextPathFor(const Key: string): string;
begin
  Result := TPath.Combine(CacheDir, Key + '.txt');
end;

function JsonPathFor(const Key: string): string;
begin
  Result := TPath.Combine(CacheDir, Key + '.json');
end;

procedure TouchPair(const TxtPath, JsonPath: string);
var
  Stamp: TDateTime;
begin
  Stamp := Now;
  TFile.SetLastAccessTime(TxtPath, Stamp);
  TFile.SetLastAccessTime(JsonPath, Stamp);
end;

procedure WriteSidecar(const JsonPath: string; const Extraction: TFb2Extraction);
var
  Root: TJSONObject;
  Arr: TJSONArray;
  Entry: TJSONObject;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    try
      for I := 0 to High(Extraction.Sections) do
      begin
        Entry := TJSONObject.Create;
        try
          Entry.AddPair('title', Extraction.Sections[I].Title);
          Entry.AddPair('level', TJSONNumber.Create(Extraction.Sections[I].Level));
          Entry.AddPair('offset', TJSONNumber.Create(Extraction.Sections[I].Offset));
          Entry.AddPair('length', TJSONNumber.Create(Extraction.Sections[I].Length));
        except
          Entry.Free;
          raise;
        end;
        Arr.AddElement(Entry);
      end;
    except
      Arr.Free;
      raise;
    end;
    Root.AddPair('sections', Arr);

    Root.AddPair('total_length', TJSONNumber.Create(Length(Extraction.Text)));
    Root.AddPair('structured', TJSONBool.Create(Extraction.Structured));
    TFile.WriteAllText(JsonPath, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

function TryReadSidecar(const JsonPath: string; out Cached: TCachedBook): Boolean;
var
  JsonText: string;
  Value: TJSONValue;
  Root: TJSONObject;
  SectionsValue: TJSONValue;
  Arr: TJSONArray;
  Entry: TJSONObject;
  I: Integer;
begin
  Cached.TotalLength := 0;
  SetLength(Cached.Sections, 0);
  Cached.Structured := False;

  try
    JsonText := TFile.ReadAllText(JsonPath, TEncoding.UTF8);
    Value := TJSONObject.ParseJSONValue(JsonText);
    if not Assigned(Value) then
      Exit(False);
    try
      if not (Value is TJSONObject) then
        Exit(False);
      Root := TJSONObject(Value);

      Cached.TotalLength := Root.GetValue<Integer>('total_length');
      Cached.Structured := Root.GetValue<Boolean>('structured');

      SectionsValue := Root.Values['sections'];
      if not (SectionsValue is TJSONArray) then
        Exit(False);
      Arr := TJSONArray(SectionsValue);

      SetLength(Cached.Sections, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr.Items[I] is TJSONObject) then
          Exit(False);
        Entry := TJSONObject(Arr.Items[I]);
        Cached.Sections[I].Title := Entry.GetValue<string>('title');
        Cached.Sections[I].Level := Entry.GetValue<Integer>('level');
        Cached.Sections[I].Offset := Entry.GetValue<Integer>('offset');
        Cached.Sections[I].Length := Entry.GetValue<Integer>('length');
      end;

      Result := True;
    finally
      Value.Free;
    end;
  except
    Result := False;
  end;
end;

function EnsureCached(const CollectionID, BookID: Integer;
  const SourceSize: Int64; const SourceStamp: TDateTime;
  ExtractProc: TFunc<TFb2Extraction>): TCachedBook;
var
  Key, TxtPath, JsonPath: string;
  Extraction: TFb2Extraction;
begin
  Key := CacheKey(CollectionID, BookID, SourceSize, SourceStamp);
  TxtPath := TextPathFor(Key);
  JsonPath := JsonPathFor(Key);

  if TFile.Exists(TxtPath) and TFile.Exists(JsonPath) and TryReadSidecar(JsonPath, Result) and
     ((TFile.GetSize(TxtPath) div SizeOf(Char)) = Result.TotalLength) then
  begin
    TouchPair(TxtPath, JsonPath);
    Exit;
  end;

  Extraction := ExtractProc();

  TFile.WriteAllBytes(TxtPath, TEncoding.Unicode.GetBytes(Extraction.Text));
  WriteSidecar(JsonPath, Extraction);

  Result.TotalLength := Length(Extraction.Text);
  Result.Sections := Extraction.Sections;
  Result.Structured := Extraction.Structured;
end;

function IsLowSurrogate(C: Char): Boolean; inline;
begin
  Result := (Ord(C) >= $DC00) and (Ord(C) <= $DFFF);
end;

function IsHighSurrogate(C: Char): Boolean; inline;
begin
  Result := (Ord(C) >= $D800) and (Ord(C) <= $DBFF);
end;

function TrimSurrogateBoundaries(const S: string;
  TrimLeading, TrimTrailing: Boolean): string;
var
  Lo, Hi: Integer;
begin
  Lo := 1;
  Hi := Length(S);

  if TrimLeading and (Hi >= Lo) and IsLowSurrogate(S[Lo]) then
    Inc(Lo);

  if TrimTrailing and (Hi >= Lo) and IsHighSurrogate(S[Hi]) then
    Dec(Hi);

  if Hi < Lo then
    Exit('');

  Result := Copy(S, Lo, Hi - Lo + 1);
end;

function ReadCachedSlice(const CollectionID, BookID: Integer;
  const SourceSize: Int64; const SourceStamp: TDateTime;
  Offset, Count: Integer): string;
var
  Key, TxtPath, JsonPath: string;
  Stream: TFileStream;
  MaxUnits: Int64;
  ClampedOffset, ClampedCount: Int64;
  ByteCount: Integer;
  Bytes: TBytes;
  Raw: string;
begin
  Key := CacheKey(CollectionID, BookID, SourceSize, SourceStamp);
  TxtPath := TextPathFor(Key);
  JsonPath := JsonPathFor(Key);

  Stream := TFileStream.Create(TxtPath, fmOpenRead or fmShareDenyWrite);
  try
    MaxUnits := Stream.Size div SizeOf(Char);

    ClampedOffset := Offset;
    if ClampedOffset < 0 then
      ClampedOffset := 0;
    if ClampedOffset > MaxUnits then
      ClampedOffset := MaxUnits;

    ClampedCount := Count;
    if ClampedCount < 0 then
      ClampedCount := 0;
    if ClampedOffset + ClampedCount > MaxUnits then
      ClampedCount := MaxUnits - ClampedOffset;

    Stream.Position := ClampedOffset * SizeOf(Char);
    ByteCount := ClampedCount * SizeOf(Char);
    SetLength(Bytes, ByteCount);
    if ByteCount > 0 then
      Stream.ReadBuffer(Bytes[0], ByteCount);
  finally
    Stream.Free;
  end;

  if TFile.Exists(JsonPath) then
    TouchPair(TxtPath, JsonPath)
  else
    TFile.SetLastAccessTime(TxtPath, Now);

  Raw := TEncoding.Unicode.GetString(Bytes);
  Result := TrimSurrogateBoundaries(Raw,
    ClampedOffset > 0, ClampedOffset + ClampedCount < MaxUnits);
end;

type
  TCachePairInfo = record
    Key: string;
    TxtBytes: Int64;
    JsonBytes: Int64;
    LastAccess: TDateTime;
  end;

procedure LogToStderr(const Msg: string);
begin
  Writeln(ErrOutput, Msg);
end;

function SafeDeleteFile(const Path: string): Boolean;
begin
  Result := False;
  try
    TFile.Delete(Path);
    Result := True;
  except
    on E: Exception do
      LogToStderr(Format('EvictCache: could not delete %s: %s', [Path, E.Message]));
  end;
end;

procedure EvictCache(const CapBytes: Int64);
var
  Dir, TxtPath, JsonPath, BaseName: string;
  Pairs: TArray<TCachePairInfo>;
  PairCount: Integer;
  Info: TCachePairInfo;
  TotalSize: Int64;
  I, J: Integer;
  Tmp: TCachePairInfo;
begin
  Dir := CacheDir;
  TotalSize := 0;
  PairCount := 0;
  SetLength(Pairs, 0);

  for TxtPath in TDirectory.GetFiles(Dir, '*.txt') do
  begin
    BaseName := TPath.GetFileNameWithoutExtension(TxtPath);
    if not IsValidCacheKeyName(BaseName) then
      Continue;

    JsonPath := ChangeFileExt(TxtPath, '.json');
    if not TFile.Exists(JsonPath) then
      SafeDeleteFile(TxtPath)
    else
    begin
      Info.Key := BaseName;
      Info.TxtBytes := TFile.GetSize(TxtPath);
      Info.JsonBytes := TFile.GetSize(JsonPath);
      Info.LastAccess := TFile.GetLastAccessTime(TxtPath);

      SetLength(Pairs, PairCount + 1);
      Pairs[PairCount] := Info;
      Inc(PairCount);
      Inc(TotalSize, Info.TxtBytes + Info.JsonBytes);
    end;
  end;

  for JsonPath in TDirectory.GetFiles(Dir, '*.json') do
  begin
    BaseName := TPath.GetFileNameWithoutExtension(JsonPath);
    if not IsValidCacheKeyName(BaseName) then
      Continue;

    TxtPath := ChangeFileExt(JsonPath, '.txt');
    if not TFile.Exists(TxtPath) then
      SafeDeleteFile(JsonPath);
  end;

  if TotalSize <= CapBytes then
    Exit;

  for I := 1 to PairCount - 1 do
  begin
    J := I;
    while (J > 0) and (Pairs[J - 1].LastAccess > Pairs[J].LastAccess) do
    begin
      Tmp := Pairs[J - 1];
      Pairs[J - 1] := Pairs[J];
      Pairs[J] := Tmp;
      Dec(J);
    end;
  end;

  I := 0;
  while (TotalSize > CapBytes) and (I < PairCount) do
  begin
    if SafeDeleteFile(TPath.Combine(Dir, Pairs[I].Key + '.txt')) then
      Dec(TotalSize, Pairs[I].TxtBytes);
    if SafeDeleteFile(TPath.Combine(Dir, Pairs[I].Key + '.json')) then
      Dec(TotalSize, Pairs[I].JsonBytes);
    Inc(I);
  end;
end;

end.
