unit unit_ReaderFontDownloads;

interface

uses Winapi.Windows, Winapi.Messages, System.SysUtils;

const WM_READER_FONTS_READY = WM_APP + $0541;

function ReaderFontCachePath: string;
function ReaderFontPrefix(const Family: string): string;
function ReaderFontLanguage(const Family: string): string;
function ReaderFontDownloadBytes(const Family: string): Int64;
function ReaderFontFamilyCached(const Family: string): Boolean;
function RegisterReaderFontWindow(Window: HWND): Cardinal;
procedure UnregisterReaderFontWindow(Window: HWND);
procedure RequestReaderFont(const Family: string);
// Does file I/O only. Registration and reader layout stay on the UI thread.
function DownloadReaderFontFamily(const Family, ManifestPath, CachePath: string;
  const Canceled: TFunc<Boolean> = nil): Boolean;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.Hash,
  System.Net.HttpClient, System.SyncObjs, System.Generics.Collections;

const FONT_MANIFEST_SHA256 = 'f873d2b4ab19bbd1c854d7ff5a1be032451c9ee72ce2382f6f1da7104f666053';

var Gate: TCriticalSection; Wake: TEvent; Pending: TQueue<string>;
  Requested: TDictionary<string,UInt64>; FontWindows: TDictionary<HWND,Cardinal>;
  Worker: TThread; NextCookie: Cardinal;

function ReaderFontCachePath: string;
var Base: string;
begin
  Base:=GetEnvironmentVariable('LOCALAPPDATA');
  if Base='' then Base:=TPath.GetTempPath;
  Result:=TPath.Combine(Base,'HomeLibRu\Fonts');
end;

function ReaderFontPrefix(const Family: string): string;
begin
  if Family.StartsWith('Noto Serif CJK') then Exit('noto-cjk/NotoSerifCJK-');
  if Family.StartsWith('Noto Sans CJK') then Exit('noto-cjk/NotoSansCJK-');
  if Family.StartsWith('Noto ') then Exit('noto/'+Family.Replace(' ','')+'-');
  Result:='';
end;

function ReaderFontFamilyCached(const Family: string): Boolean;
var Prefix, Marker: string;
begin
  Result:=False; Prefix:=ReaderFontPrefix(Family); if Prefix='' then Exit;
  Marker:=TPath.Combine(ReaderFontCachePath,Prefix.Replace('/',PathDelim)+'ready');
  try
    Result:=FileExists(Marker) and (TFile.GetSize(Marker)=Length(FONT_MANIFEST_SHA256)) and
      (TFile.ReadAllText(Marker,TEncoding.ASCII)=FONT_MANIFEST_SHA256);
  except Result:=False; end;
end;

function ReaderFontLanguage(const Family: string): string;
const Scripts: array[0..20] of string = ('Armenian','Hebrew','Arabic','Syriac','Thaana',
  'Devanagari','Bengali','Gurmukhi','Gujarati','Oriya','Tamil','Telugu','Kannada',
  'Malayalam','Sinhala','Thai','Lao','Tibetan','Myanmar','Georgian','Ethiopic');
  Labels: array[0..20] of string = ('армянского','иврита','арабского','сирийского','дивехи',
  'деванагари','бенгальского','гурмукхи','гуджарати','ория','тамильского','телугу','каннада',
  'малаялам','сингальского','тайского','лаосского','тибетского','бирманского','грузинского','эфиопского');
begin
  if Family.Contains('CJK') then
  begin
    if Family.EndsWith('JP') then Exit('японского');
    if Family.EndsWith('KR') then Exit('корейского');
    Exit('китайского');
  end;
  if Family.EndsWith('Khmer') then Exit('кхмерского');
  if Family.EndsWith('Symbols2') then Exit('символов');
  for var I:=Low(Scripts) to High(Scripts) do if Family.EndsWith(Scripts[I]) then Exit(Labels[I]);
  Result:='этого языка';
end;

function ReaderFontDownloadBytes(const Family: string): Int64;
var Root: TJSONValue; Items: TJSONArray; Item: TJSONValue; Path, Prefix, Name: string; Size: Int64;
begin
  Result:=0; Path:=ExtractFilePath(ParamStr(0))+'tools\fonts\manifest.json'; Prefix:=ReaderFontPrefix(Family);
  if (Prefix='') or not FileExists(Path) or (TFile.GetSize(Path)>131072) or
    (THashSHA2.GetHashStringFromFile(Path)<>FONT_MANIFEST_SHA256) then Exit;
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Path,TEncoding.UTF8));
  try
    if (Root is TJSONObject) and TJSONObject(Root).TryGetValue<TJSONArray>('files',Items) then
      for Item in Items do
        if (Item is TJSONObject) and TJSONObject(Item).TryGetValue<string>('path',Name) and Name.StartsWith(Prefix) and
          TJSONObject(Item).TryGetValue<Int64>('size',Size) and (Size>0) then Result:=Result+Size;
  finally Root.Free; end;
end;

type
  TFontTransfer = class
  public
    Limit: Int64;
    Canceled: TFunc<Boolean>;
    procedure Receive(const Sender: TObject; AContentLength,AReadCount: Int64; var AAbort: Boolean);
  end;

procedure TFontTransfer.Receive(const Sender: TObject; AContentLength,AReadCount: Int64; var AAbort: Boolean);
begin
  AAbort:=(Assigned(Canceled) and Canceled()) or (AReadCount>Limit) or
    ((AContentLength>0) and (AContentLength<>Limit));
end;

function DownloadReaderFontFamily(const Family, ManifestPath, CachePath: string;
  const Canceled: TFunc<Boolean>): Boolean;
var Root: TJSONValue; Files: TJSONArray; Value: TJSONValue;
  HTTP: THTTPClient; Transfer: TFontTransfer; Stream: TFileStream; Response: IHTTPResponse;
  Prefix, Name, URL, Hash, Destination, Temporary: string; Size: Int64; Found: Integer;
  procedure CheckCanceled;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
begin
  Result:=False; Found:=0; Prefix:=ReaderFontPrefix(Family); if Prefix='' then Exit;
  CheckCanceled;
  if (not FileExists(ManifestPath)) or (TFile.GetSize(ManifestPath)>131072) or
    (THashSHA2.GetHashStringFromFile(ManifestPath)<>FONT_MANIFEST_SHA256) then Exit;
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ManifestPath,TEncoding.UTF8));
  HTTP:=THTTPClient.Create; Transfer:=TFontTransfer.Create; Transfer.Canceled:=Canceled;
  try
    HTTP.UserAgent:='HomeLibre'; HTTP.ConnectionTimeout:=4000; HTTP.ResponseTimeout:=6000;
    HTTP.OnReceiveData:=Transfer.Receive;
    if not (Root is TJSONObject) or not TJSONObject(Root).TryGetValue<TJSONArray>('files',Files) then Exit;
    for Value in Files do
    begin
      if not (Value is TJSONObject) or not TJSONObject(Value).TryGetValue<string>('path',Name) or
        not Name.StartsWith(Prefix) then Continue;
      Inc(Found);
      if not TJSONObject(Value).TryGetValue<string>('source',URL) or
        not TJSONObject(Value).TryGetValue<string>('sha256',Hash) or
        not TJSONObject(Value).TryGetValue<Int64>('size',Size) or (Size<1) or (Size>32*1024*1024) then Exit;
      // The compiled manifest digest pins URLs, full glyph sets and OFL resources.
      Destination:=TPath.Combine(CachePath,Name.Replace('/',PathDelim));
      CheckCanceled;
      if FileExists(Destination) and (TFile.GetSize(Destination)=Size) and
        (THashSHA2.GetHashStringFromFile(Destination)=Hash) then Continue;
      ForceDirectories(ExtractFileDir(Destination)); Temporary:=Destination+'.'+TPath.GetRandomFileName+'.part';
      try
        Stream:=TFileStream.Create(Temporary,fmCreate);
        try
          Transfer.Limit:=Size; Response:=HTTP.Get(URL,Stream); CheckCanceled;
          if (Response.StatusCode<>200) or (Stream.Size<>Size) then Exit;
          FlushFileBuffers(Stream.Handle);
        finally Stream.Free; end;
        if THashSHA2.GetHashStringFromFile(Temporary)<>Hash then Exit;
        CheckCanceled;
        if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
      finally if FileExists(Temporary) then DeleteFile(PChar(Temporary)); end;
    end;
    if Found=0 then Exit;
    // Publish the family only after every style has been verified. A canceled
    // transfer may retain verified files, but must not register half a family.
    CheckCanceled;
    Destination:=TPath.Combine(CachePath,Prefix.Replace('/',PathDelim)+'ready');
    if FileExists(Destination) and (TFile.ReadAllText(Destination,TEncoding.ASCII)=FONT_MANIFEST_SHA256) then
      Exit(True);
    Temporary:=Destination+'.'+TPath.GetRandomFileName+'.part';
    try
      Stream:=TFileStream.Create(Temporary,fmCreate);
      try
        var Marker:=TEncoding.ASCII.GetBytes(FONT_MANIFEST_SHA256);
        Stream.WriteBuffer(Marker[0],Length(Marker)); FlushFileBuffers(Stream.Handle);
      finally Stream.Free; end;
      CheckCanceled;
      if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
      Result:=True;
    finally if FileExists(Temporary) then DeleteFile(PChar(Temporary)); end;
  finally HTTP.Free; Transfer.Free; Root.Free; end;
end;

type
  TFontWorker = class(TThread)
  protected procedure Execute; override;
  end;

procedure TFontWorker.Execute;
var Family: string; Pair: TPair<HWND,Cardinal>; Ready: Boolean;
begin
  while not Terminated do
  begin
    Family:=''; Gate.Acquire;
    try if Pending.Count>0 then Family:=Pending.Dequeue; finally Gate.Release; end;
    if Family='' then begin Wake.WaitFor(1000); Continue; end;
    Ready:=False;
    try
      Ready:=DownloadReaderFontFamily(Family,ExtractFilePath(ParamStr(0))+'tools\fonts\manifest.json',
        ReaderFontCachePath,function: Boolean begin Result:=Terminated; end);
    except end; // Offline reading remains available with Windows fallback fonts.
    if not Terminated then
    begin
      Gate.Acquire;
      try Requested.Remove(Family); for Pair in FontWindows do PostMessage(Pair.Key,WM_READER_FONTS_READY,Pair.Value,Ord(Ready));
      finally Gate.Release; end;
    end;
  end;
end;

procedure RequestReaderFont(const Family: string);
var Last: UInt64;
begin
  if ReaderFontPrefix(Family)='' then Exit;
  Gate.Acquire;
  try
    if Requested.TryGetValue(Family,Last) and (GetTickCount64-Last<15*60*1000) then Exit;
    Requested.AddOrSetValue(Family,GetTickCount64); Pending.Enqueue(Family);
    if not Assigned(Worker) then begin Worker:=TFontWorker.Create(True); Worker.FreeOnTerminate:=False; Worker.Start; end;
    Wake.SetEvent;
  finally Gate.Release; end;
end;

function RegisterReaderFontWindow(Window: HWND): Cardinal;
begin
  Gate.Acquire;
  try Inc(NextCookie); if NextCookie=0 then Inc(NextCookie); Result:=NextCookie; FontWindows.AddOrSetValue(Window,Result);
  finally Gate.Release; end;
end;

procedure UnregisterReaderFontWindow(Window: HWND);
begin Gate.Acquire; try FontWindows.Remove(Window); finally Gate.Release; end; end;

initialization
  Gate:=TCriticalSection.Create; Wake:=TEvent.Create(nil,False,False,'');
  Pending:=TQueue<string>.Create; Requested:=TDictionary<string,UInt64>.Create;
  FontWindows:=TDictionary<HWND,Cardinal>.Create; NextCookie:=0;
finalization
  if Assigned(Worker) then begin Worker.Terminate; Wake.SetEvent; Worker.WaitFor; Worker.Free; end;
  FontWindows.Free; Requested.Free; Pending.Free; Wake.Free; Gate.Free;
end.
