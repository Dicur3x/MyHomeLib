program ProgramUpdatesTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Net.HttpClient, System.Net.URLClient,
  Winapi.Windows, Winapi.Messages,
  unit_ProgramUpdates in '..\Units\unit_ProgramUpdates.pas';

var
  Checks: Integer;

procedure Check(Condition: Boolean; const Name: string);
begin
  Inc(Checks);
  if not Condition then
    raise Exception.Create(Name);
end;

procedure Compare(const A, B: string; Expected: Integer);
var C: Integer;
begin
  Check(CompareReleaseTags(A, B, C) and (C = Expected), A + ' vs ' + B);
end;

function ReleaseJSON(const Tag: string; Draft: Boolean = False): string;
begin
  Result := '{"tag_name":"' + Tag + '","draft":' + LowerCase(BoolToStr(Draft, True)) +
    ',"html_url":"https://example.invalid/evil","assets":[{"name":"HomeLibRu.zip"}]}';
end;

procedure HTTPCheck(const URL: string; Expected: Boolean; Cancel: Boolean = False;
  const CacheFolder: string = ''; const ExpectedTag: string = '2.7.0_pre5.08');
var
  HTTP: THTTPClient;
  Thread: TProgramUpdateThread;
  Window: HWND;
  Msg: TMsg;
  Started: UInt64;
begin
  Window := CreateWindowEx(0, 'STATIC', 'HomeLib Ru update test', 0,
    0, 0, 0, 0, HWND_MESSAGE, 0, HInstance, nil);
  Check(Window <> 0, 'hidden test window');
  HTTP := THTTPClient.Create;
  HTTP.ProxySettings := TProxySettings.Create('direct', 80, '', '', 'http');
  Thread := TProgramUpdateThread.Create(Window, HTTP, URL, CacheFolder);
  try
    Started := GetTickCount64;
    Thread.Start;
    Check(GetTickCount64 - Started < 500, 'start must not block UI');
    if Cancel then Thread.Terminate;
    Thread.WaitFor;
    Check(GetTickCount64 - Started < 12000, 'bounded network wait');
    Check(Thread.Successful = Expected, URL);
    if Expected then Check(Thread.ReleaseInfo.Tag = ExpectedTag, 'HTTP release');
    if not Cancel then
      Check(PeekMessage(Msg, Window, WM_PROGRAM_UPDATE_CHECKED, WM_PROGRAM_UPDATE_CHECKED,
        PM_REMOVE), 'completion message without payload');
  finally
    Thread.Free;
    DestroyWindow(Window);
  end;
end;

var
  Info: TProgramRelease;
  C: Integer;
  BaseURL, CacheFolder: string; CacheID: TGUID;
begin
  try
    Compare('2.7.0_pre5.07', '2.7.0_pre5.06', 1);
    Compare('2.7.0_pre5.10', '2.7.0_pre5.9', 1);
    Compare('2.7.0_pre10', '2.7.0_pre9.99', 1);
    Compare('2.7.0', '2.7.0_pre5.99', 1);
    Compare('2.8.0_pre1', '2.7.0', 1);
    Compare('2.7.0_pre5.07', 'v2.7.0_pre5.7', 0);
    Compare('2.7.0_pre2.02', '2.7.0_pre5.06', -1);
    Check(not CompareReleaseTags('junk', PROGRAM_RELEASE_VERSION, C), 'invalid tag');
    Check(not CompareReleaseTags('2.7.0_pre5.07/evil', PROGRAM_RELEASE_VERSION, C), 'unsafe tag');
    Check(not CompareReleaseTags('999999999999.0.0', PROGRAM_RELEASE_VERSION, C), 'overflow');
    Check(ParseProgramReleases('[' + ReleaseJSON('2.7.0_pre5.10') + ',' +
      ReleaseJSON('2.7.0_pre5.08') + ',' + ReleaseJSON('9.0.0', True) + ']', Info), 'release list');
    Check(Info.Tag = '2.7.0_pre5.10', 'numeric ordering, skip drafts');
    Check(Info.URL = 'https://github.com/Dicur3x/MyHomeLib/releases/tag/2.7.0_pre5.10', 'safe URL');
    Check(not ParseProgramReleases('[]', Info), 'empty list');
    Check(not ParseProgramReleases('{"message":"rate limit"}', Info), 'API error');
    Check(not ParseProgramReleases('<html>error</html>', Info), 'non JSON');
    Check(not ParseProgramReleases('[{"tag_name":"3.0.0","draft":false,"assets":[]}]', Info), 'no archive');
    if ParamCount = 1 then
    begin
      BaseURL := ParamStr(1);
      HTTPCheck(BaseURL + '/ok', True);
      HTTPCheck(BaseURL + '/forbidden', False);
      HTTPCheck(BaseURL + '/missing', False);
      HTTPCheck(BaseURL + '/invalid', False);
      HTTPCheck(BaseURL + '/slow', False);
      HTTPCheck(BaseURL + '/ok', False, True);
      HTTPCheck('http://127.0.0.1:1/unavailable', False);
      CreateGUID(CacheID);
      CacheFolder := IncludeTrailingPathDelimiter(TPath.GetTempPath) + 'HomeLibRu-update-test-http-' + GUIDToString(CacheID);
      HTTPCheck(BaseURL + '/cached', True, False, CacheFolder);
      HTTPCheck(BaseURL + '/cached', True, False, CacheFolder);
      HTTPCheck(BaseURL + '/cached', True, False, CacheFolder, '2.7.0_pre5.09');
      HTTPCheck(BaseURL + '/cached', False, False, CacheFolder);
      HTTPCheck(BaseURL + '/modified', True, False, CacheFolder);
      HTTPCheck(BaseURL + '/modified', True, False, CacheFolder);
      Writeln('PASS conditional history cache handles 304, changed releases and manual network failure');
    end;
    Writeln('PASS: ', Checks, ' program-update checks');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, 'FAIL: ', E.Message);
      Halt(1);
    end;
  end;
end.
