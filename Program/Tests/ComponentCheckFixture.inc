// Controlled author metadata. Execute remains the production component worker;
// only the transport is replaced. HEAD is restricted to the caller-owned loopback.
type
  TComponentCheckFixtureWorker = class(TComponentUpdateThread)
  private
    FHeadHTTP: THTTPClient;
    FHeadURL, FFailureID: string;
    FRequests: TStringList;
    procedure CheckSource(const URL: string);
  protected
    function FetchText(const URL: string): string; override;
    function FetchHead(const URL: string): IHTTPResponse; override;
  public
    constructor Create(Window: HWND; const HeadURL, FailureID: string);
    destructor Destroy; override;
    property Requests: TStringList read FRequests;
  end;

constructor TComponentCheckFixtureWorker.Create(Window: HWND; const HeadURL, FailureID: string);
var PortText: string; Slash, Port: Integer;
begin
  inherited Create(Window,THTTPClient.Create,'','');
  if not HeadURL.StartsWith('http://127.0.0.1:') then
    raise Exception.Create('Component fixture requires its owned loopback URL');
  PortText := Copy(HeadURL,18,MaxInt); Slash := Pos('/',PortText);
  if (Slash<2) or (Copy(PortText,Slash,MaxInt)<>'/head') or
    not TryStrToInt(Copy(PortText,1,Slash-1),Port) or (Port<1) or (Port>65535) then
    raise Exception.Create('Component fixture refused a non-loopback transport');
  FHeadURL:=HeadURL; FFailureID:=FailureID;
  FRequests:=TStringList.Create; FHeadHTTP:=THTTPClient.Create;
  FHeadHTTP.ConnectionTimeout:=1000; FHeadHTTP.ResponseTimeout:=2000;
end;

destructor TComponentCheckFixtureWorker.Destroy;
begin
  inherited;
  FHeadHTTP.Free; FRequests.Free;
end;

procedure TComponentCheckFixtureWorker.CheckSource(const URL: string);
var ID: string;
begin
  if Terminated then Abort;
  FRequests.Add(URL);
  if URL.Contains('sqlite.org/') then ID:='SQLite'
  else if URL.Contains('alreader.com/') then ID:='AlReader'
  else if URL.Contains('sumatrapdf') then ID:='SumatraPDF'
  else if URL.Contains('sourceforge.net/') then ID:='DjVuLibre'
  else if URL.Contains('ip7z/7zip/') then ID:='7-Zip'
  else if URL.Contains('nuget.org/') or URL.Contains('manfromarce/DocSharp/') then ID:='DocSharp'
  else raise Exception.Create('Unexpected component fixture route: '+URL);
  if (FFailureID='all') or (FFailureID=ID) or
    ((FFailureID='DocSharp-head') and URL.EndsWith('.nupkg')) then
    // Deliberately unsafe-looking server detail must remain out of ordinary UI.
    raise Exception.Create('Fixture HTTP 503 <html>private C:\proxy\secret '+StringOfChar('x',6000)+'</html>');
end;

function TComponentCheckFixtureWorker.FetchText(const URL: string): string;
var Arch, Name: string;
begin
  CheckSource(URL);
{$IFDEF WIN64}
  Arch:='x64';
{$ELSE}
  Arch:='x86';
{$ENDIF}
  if URL='https://www.sqlite.org/download.html' then
    Exit('PRODUCT,3.99.0,2026/sqlite-dll-win-'+Arch+'-3990000.zip,128,'+StringOfChar('a',64));
  if URL='https://www.sqlite.org/changes.html' then
    Exit('<h3>2026-10-16 (3.99.0)</h3><p>Owned SQLite changes.</p>');
  if URL='https://www.alreader.com/' then Exit('<a>AlReader2.Win32</a>');
  if URL='https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases?per_page=30' then
    Exit('[{"tag_name":"99.0.0rel","body":"Owned Sumatra changes.","draft":false,"prerelease":false}]');
  if URL='https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/' then
    Exit('/projects/djvu/files/DjVuLibre_Windows/3.5.99%2B4.99/');
  if URL='https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/3.5.99%2B4.99/' then
    Exit('/projects/djvu/files/DjVuLibre_Windows/3.5.99%2B4.99/DjVuLibre-3.5.99_DjView-4.99_Setup.exe/download');
  if URL='https://sourceforge.net/p/djvu/djvulibre-git/ci/master/tree/NEWS?format=raw' then
    Exit('NEW IN VERSION 3.5.99'+sLineBreak+'Owned DjVu changes.');
  if URL='https://api.github.com/repos/ip7z/7zip/releases/latest' then
  begin
{$IFDEF WIN64}
    Name:='7z9999-x64.exe';
{$ELSE}
    Name:='7z9999.exe';
{$ENDIF}
    Exit('{"tag_name":"99.99","draft":false,"prerelease":false,"body":"Owned 7-Zip changes.","assets":['+
      '{"name":"'+Name+'","browser_download_url":"https://github.com/ip7z/7zip/releases/download/99.99/'+Name+'",'+
      '"digest":"sha256:'+StringOfChar('b',64)+'","size":128}]}');
  end;
  if (URL='https://api.github.com/repos/ip7z/7zip/releases?per_page=30') or
    (URL='https://api.github.com/repos/manfromarce/DocSharp/releases?per_page=30') then
    Exit('[{"tag_name":"99.0.0","body":"Owned component changes.","draft":false,"prerelease":false}]');
  if URL.StartsWith('https://api.nuget.org/v3-flatcontainer/docsharp.binary.') and URL.EndsWith('/index.json') then
    Exit('{"versions":["99.0.0","100.0.0-preview"]}');
  raise Exception.Create('Component fixture refused unexpected GET: '+URL);
end;

function TComponentCheckFixtureWorker.FetchHead(const URL: string): IHTTPResponse;
begin
  CheckSource(URL);
  Result:=FHeadHTTP.Head(FHeadURL);
end;
