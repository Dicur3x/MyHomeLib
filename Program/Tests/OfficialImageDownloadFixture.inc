type
  TImageDownloadFixture = class(TProgramDownloadThread)
  private
    FOriginalURL, FRedirectURL: string;
  protected
    function FetchDownload(const URL: string; Content: TStream): IHTTPResponse; override;
    function FetchMirrorRelease(out Info: TProgramRelease): Boolean; override;
  public
    Requests: Integer;
    constructor Create(const Info: TProgramRelease; const Job, RedirectURL: string);
  end;

constructor TImageDownloadFixture.Create(const Info: TProgramRelease; const Job, RedirectURL: string);
begin
  if not RedirectURL.StartsWith('http://127.0.0.1:') then
    raise Exception.Create('Fixture requires an owned loopback endpoint');
  FOriginalURL:=Info.DownloadURL; FRedirectURL:=RedirectURL;
  inherited Create(0,THTTPClient.Create,Info,Job);
end;

function TImageDownloadFixture.FetchDownload(const URL: string; Content: TStream): IHTTPResponse;
begin
  if URL<>FOriginalURL then raise Exception.Create('Unexpected fixture download: '+URL);
  Inc(Requests); Result:=inherited FetchDownload(FRedirectURL,Content);
end;

function TImageDownloadFixture.FetchMirrorRelease(out Info: TProgramRelease): Boolean;
begin
  Info:=Default(TProgramRelease); Result:=False;
end;

procedure RunOfficialImageDownloadFixture;
var Info, Prepared: TProgramRelease; Worker: TImageDownloadFixture; Root: TJSONObject;
begin
  Guard(ParamStr(2)); Guard(ParamStr(5));
  if not ParseImageComponent(TFile.ReadAllText(ParamStr(2),TEncoding.UTF8),ParamStr(3),Info) then
    raise Exception.Create('Official image release metadata rejected');
  Worker:=TImageDownloadFixture.Create(Info,ParamStr(5),ParamStr(4));
  try
    Worker.Start; Worker.WaitFor;
    if not Worker.Successful then raise Exception.Create(Worker.ErrorText);
    Prepared:=Worker.ReleaseInfo;
    // This is the same identity the normal form persists and passes to its helper.
    VerifyPreparedProgramUpdate(ParamStr(5),Prepared.Tag,ProgramUpdatePlatform);
    Root:=TJSONObject.Create;
    try
      Root.AddPair('source_tag',Info.Tag); Root.AddPair('prepared_tag',Prepared.Tag);
      Root.AddPair('component',Prepared.ComponentID); Root.AddPair('version',Prepared.ComponentVersion);
      Root.AddPair('sha256',Prepared.SHA256); Root.AddPair('url',Prepared.URL);
      Root.AddPair('requests',TJSONNumber.Create(Worker.Requests));
      Writeln(Root.ToJSON);
    finally Root.Free; end;
  finally Worker.Free; end;
end;
