unit unit_ReaderDjvu;

interface

uses System.SysUtils, unit_ReaderPDF;

function DjvuPageCount(const FileName: string): Integer;
function DjvuOutline(const FileName: string; PageCount: Integer): TArray<TPDFChapter>;
function PrepareDjvuPage(const FileName: string; Index: Integer): string;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Hash, System.RegularExpressions,
  System.Generics.Collections, System.NetEncoding,
  unit_BookCache, unit_MHLExternalTools;

function Canceled: Boolean;
begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end;

function Decoder(const Name: string): string;
begin
  Result:=FindExternalTool(Name,'djvu');
  if Result='' then raise EMHLComponentRequired.Create('DjVuLibre','Для этой книги нужен модуль DjVuLibre.');
end;

procedure RunDjvu(const Tool: string; const Args: array of string; Output: TStream;
  PrefixBytes: Integer = 0);
var Started: UInt64;
begin
  Started:=GetTickCount64;
  RunExternalToolToStream(Tool,Args,Output,
    function: Boolean
    begin
      Result:=Canceled;
      if GetTickCount64-Started>30000 then raise Exception.Create('Не удалось прочитать страницу DjVu за 30 секунд.');
    end,PrefixBytes,True);
end;

function DjvuPageCount(const FileName: string): Integer;
var Log: TStringStream;
begin
  Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    RunDjvu(Decoder('djvused.exe'),['-n','-e','n',FileName],Log);
    if not TryStrToInt(Log.DataString.Trim,Result) or (Result<=0) or (Result>100000) then
      raise Exception.Create('Не удалось прочитать число страниц DjVu. Файл может быть повреждён.');
  finally Log.Free; end;
end;

function DjvuOutline(const FileName: string; PageCount: Integer): TArray<TPDFChapter>;
const MaxOutlineBytes = 2 * 1024 * 1024;
var Tool, Outline, Link, LabelText: string; Chapters: TList<TPDFChapter>;
  PageIDs: TDictionary<string, Integer>; Item: TPDFChapter; PageNumber: Integer;

  function ReadMetadata(const Command: string): string;
  var Output: TStringStream;
  begin
    Output := TStringStream.Create('', TEncoding.UTF8);
    try
      RunDjvu(Tool, ['-u', '-n', '-e', Command, FileName], Output, MaxOutlineBytes + 1);
      Result := '';
      if Output.Size > MaxOutlineBytes then Exit;
      Result := Output.DataString;
      if Result.StartsWith(#$FEFF) then Result := Result.Substring(1);
    finally Output.Free; end;
  end;

  function DecodeString(const Value: string): string;
  var Text: TStringBuilder; I, Code: Integer;
  begin
    Text := TStringBuilder.Create(Length(Value));
    try
      I := 1;
      while I <= Length(Value) do
      begin
        if (Value[I] <> '\') or (I = Length(Value)) then Text.Append(Value[I])
        else
        begin
          Inc(I);
          case Value[I] of
            't', 'n', 'r', 'b', 'f': Text.Append(' ');
            '0'..'3':
              if (I + 2 <= Length(Value)) and CharInSet(Value[I + 1], ['0'..'7']) and
                CharInSet(Value[I + 2], ['0'..'7']) then
              begin
                Code := 64 * (Ord(Value[I]) - Ord('0')) +
                  8 * (Ord(Value[I + 1]) - Ord('0')) + Ord(Value[I + 2]) - Ord('0');
                if Code >= 32 then Text.Append(Char(Code)) else Text.Append(' ');
                Inc(I, 2);
              end
              else Text.Append(Value[I]);
          else Text.Append(Value[I]);
          end;
        end;
        Inc(I);
      end;
      Result := Text.ToString;
    finally Text.Free; end;
  end;

  function ResolvePage(const Target: string; out Number: Integer): Boolean;
  var Entry, ID: string; Index, At: Integer;
  begin
    if TryStrToInt(Target, Number) then Exit(True);
    if PageIDs = nil then
    begin
      PageIDs := TDictionary<string, Integer>.Create;
      // djvused lists the page ID, followed by optional file and display names.
      for var Row in TRegEx.Matches(ReadMetadata('ls'), '(?m)^[ \t]*(\d+) P +\d+  ([^\r\n]+)') do
      begin
        Index := StrToIntDef(Row.Groups[1].Value, 0);
        Entry := Row.Groups[2].Value;
        At := Pos(' T=', Entry);
        if At > 0 then
        begin
          PageIDs.TryAdd(Copy(Entry, At + 3, MaxInt), Index);
          SetLength(Entry, At - 1);
        end;
        At := Pos(' F=', Entry);
        if At > 0 then
        begin
          PageIDs.TryAdd(Copy(Entry, At + 3, MaxInt), Index);
          SetLength(Entry, At - 1);
        end;
        PageIDs.AddOrSetValue(Entry, Index);
      end;
    end;
    if PageIDs.TryGetValue(Target, Number) then Exit(True);
    ID := TNetEncoding.URL.Decode(Target.Replace('+', '%2B'));
    Result := PageIDs.TryGetValue(ID, Number);
  end;

begin
  Result := nil;
  Tool := FindExternalTool('djvused.exe', 'djvu');
  if Tool = '' then Exit;
  Chapters := TList<TPDFChapter>.Create;
  PageIDs := nil;
  try
    Outline := ReadMetadata('print-outline');
    if not Outline.StartsWith('(bookmarks') then Exit;
    // The decoder writes one entry per line, with its depth in the indent.
    for var Entry in TRegEx.Matches(Outline, '(?m)^( +)\("((?:\\.|[^"\\])*)"\s+"((?:\\.|[^"\\])*)"') do
    begin
      if Chapters.Count = 4096 then Break;
      if Canceled then Abort;
      Link := DecodeString(Entry.Groups[3].Value);
      LabelText := DecodeString(Entry.Groups[2].Value).Trim;
      if (LabelText = '') or not Link.StartsWith('#') then Continue;
      if not ResolvePage(Link.Substring(1), PageNumber) then Continue;
      if (PageNumber < 1) or (PageNumber > PageCount) then Continue;
      Item.Title := LabelText;
      Item.Page := PageNumber - 1;
      Item.Depth := Entry.Groups[1].Length - 1;
      Chapters.Add(Item);
    end;
    Result := Chapters.ToArray;
  finally PageIDs.Free; Chapters.Free; end;
end;

function PrepareDjvuPage(const FileName: string; Index: Integer): string;
var Tool,Stamp,Temporary: string; Attributes, ToolAttributes: TWin32FileAttributeData;
  Writer: TBookCacheWrite; Log: TStringStream;
begin
  if Canceled then Abort;
  if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
  Tool:=Decoder('ddjvu.exe');
  if not GetFileAttributesEx(PChar(Tool),GetFileExInfoStandard,@ToolAttributes) then RaiseLastOSError;
  Stamp:='djvu-raster-v2|'+TPath.GetFullPath(FileName)+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+
    IntToStr(Attributes.nFileSizeLow)+'|'+IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+
    IntToStr(Attributes.ftLastWriteTime.dwLowDateTime)+'|'+IntToStr(Index)+'|'+
    IntToStr(ToolAttributes.nFileSizeHigh)+':'+IntToStr(ToolAttributes.nFileSizeLow)+'|'+
    IntToStr(ToolAttributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(ToolAttributes.ftLastWriteTime.dwLowDateTime);
  Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-djvu-'+Copy(THashSHA2.GetHashString(Stamp),1,40)+'.tif'));
  if FileExists(Result) then begin RegisterBookCacheFile(Result,BookCacheSource(FileName)); Exit; end;
  ForceDirectories(ExtractFileDir(Result));
  Writer:=TBookCacheWrite.Create(BookCacheSource(FileName)); Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    Temporary:=Writer.TemporaryName(Result);
    // Decode just the requested original page, with lossless TIFF compression.
    // This is raster rendering, never text recognition or OCR.
    RunDjvu(Tool,['-format=tiff','-quality=deflate','-page='+IntToStr(Index+1),'-size=4000x4000',FileName,Temporary],Log);
    if Canceled then Abort;
    if not FileExists(Temporary) then raise Exception.Create('Декодер не создал страницу DjVu.');
    Writer.Publish(Temporary,Result);
  finally Log.Free; Writer.Free; end;
end;

end.
