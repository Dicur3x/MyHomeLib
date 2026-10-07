unit unit_ProgramUpdates;

interface

uses
  System.Classes, System.Net.HttpClient, Winapi.Windows, Winapi.Messages;

const
  WM_PROGRAM_UPDATE_CHECKED = WM_APP + $0501;
  WM_PROGRAM_UPDATE_DOWNLOADED = WM_APP + $0502;
  WM_PROGRAM_UPDATE_PROGRESS = WM_APP + $0503;
  PROGRAM_RELEASE_VERSION = '2.7.0_pre5.11';
  PROGRAM_RELEASES_API = 'https://api.github.com/repos/Dicur3x/MyHomeLib/releases?per_page=100';

type
  TProgramRelease = record
    Tag: string;
    URL: string;
    DownloadURL, SHA256: string;
    Notes, Changelog, History: string;
    PublishedAt: string;
    Size: Int64;
    ComponentID, ComponentVersion: string;
    SourceSHA3, ComponentError: string;
    OfficialComponent: Boolean;
  end;

  TProgramDownloadThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FWindow: HWND;
    FRelease: TProgramRelease;
    FJob, FError: string;
    FSuccessful: Boolean;
    FProgress: Integer;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const ReleaseInfo: TProgramRelease; const Job: string);
    destructor Destroy; override;
    property Successful: Boolean read FSuccessful;
    property ErrorText: string read FError;
    property Progress: Integer read FProgress;
    property ReleaseInfo: TProgramRelease read FRelease;
  end;

  // The form owns this thread. Results are read only after WaitFor; the
  // Windows message carries no pointers and shutdown never synchronizes VCL.
  TProgramUpdateThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FWindow: HWND;
    FURL, FCacheFolder: string;
    FSuccessful: Boolean;
    FRelease: TProgramRelease;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const AURL: string = PROGRAM_RELEASES_API; const CacheFolder: string = '');
    destructor Destroy; override;
    property Successful: Boolean read FSuccessful;
    property ReleaseInfo: TProgramRelease read FRelease;
  end;

function CompareReleaseTags(const Left, Right: string; out Comparison: Integer): Boolean;
function ReleaseNotesHeading(const Version, PublishedAt: string): string;
function ParseProgramReleases(const JSON: string; out ReleaseInfo: TProgramRelease): Boolean;
function ProgramUpdateDue(LastCheck, CurrentUTC: TDateTime; IntervalMinutes: Integer): Boolean;
function ProgramUpdateCache(const AppPath: string): string;

implementation

uses
  System.SysUtils, System.JSON, System.RegularExpressions, System.IOUtils,
  System.Hash, System.Generics.Collections, System.Generics.Defaults, unit_ProgramUpdateInstaller,
  unit_UpdateAuthenticity, unit_UpdateTextCache;

type
  TReleaseNumbers = array[0..4] of Integer;

function ParseTag(const Tag: string; out Numbers: TReleaseNumbers): Boolean;
var
  Match: TMatch;
  I: Integer;
begin
  Result := False;
  Match := TRegEx.Match(Tag,
    '^v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:_pre([0-9]+)(?:\.([0-9]+))?)?$');
  if not Match.Success then
    Exit;
  for I := 0 to 2 do
    if not TryStrToInt(Match.Groups[I + 1].Value, Numbers[I]) then
      Exit;
  Numbers[3] := MaxInt; // a final release follows every pre-release
  Numbers[4] := 0;
  if (Match.Groups.Count > 4) and Match.Groups[4].Success then
  begin
    if not TryStrToInt(Match.Groups[4].Value, Numbers[3]) then
      Exit;
    if (Match.Groups.Count > 5) and Match.Groups[5].Success and
       not TryStrToInt(Match.Groups[5].Value, Numbers[4]) then
      Exit;
  end;
  Result := True;
end;

function CompareReleaseTags(const Left, Right: string; out Comparison: Integer): Boolean;
var
  A, B: TReleaseNumbers;
  I: Integer;
begin
  Comparison := 0;
  Result := ParseTag(Left, A) and ParseTag(Right, B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      if A[I] > B[I] then Comparison := 1 else Comparison := -1;
      Exit;
    end;
end;

function ReleaseNotesHeading(const Version, PublishedAt: string): string;
var Match: TMatch; Year, Month, Day: Integer; Date: TDateTime;
begin
  Result := Version;
  Match := TRegEx.Match(PublishedAt.Trim, '^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T.*)?$');
  if Match.Success and TryStrToInt(Match.Groups[1].Value, Year) and
     TryStrToInt(Match.Groups[2].Value, Month) and
     TryStrToInt(Match.Groups[3].Value, Day) and
     TryEncodeDate(Year, Month, Day, Date) then
    Result := Result + ' — ' + FormatDateTime('dd.mm.yyyy', Date);
end;

function ParseProgramReleases(const JSON: string; out ReleaseInfo: TProgramRelease): Boolean;
var
  Root, Item, Asset: TJSONValue;
  Obj: TJSONObject;
  Assets: TJSONArray;
  Draft, HasArchive: Boolean;
  Tag, Name, DownloadURL, Digest, ExpectedName: string;
  Comparison: Integer;
  Candidate: TProgramRelease;
  Releases: TList<TProgramRelease>;
  NewNotes, History: string;
begin
  Result := False;
  ReleaseInfo := Default(TProgramRelease);
  Root := TJSONObject.ParseJSONValue(JSON);
  Releases := TList<TProgramRelease>.Create;
  try
    if not (Root is TJSONArray) then
      Exit;
    for Item in TJSONArray(Root) do
    begin
      if not (Item is TJSONObject) then
        Continue;
      Obj := TJSONObject(Item);
      if not Obj.TryGetValue<Boolean>('draft', Draft) or Draft then
        Continue;
      if not Obj.TryGetValue<string>('tag_name', Tag) or
         not CompareReleaseTags(Tag, Tag, Comparison) then
        Continue;
      if not Obj.TryGetValue<TJSONArray>('assets', Assets) then
        Continue;
      HasArchive := False;
      Candidate := Default(TProgramRelease);
      Candidate.Tag := Tag;
      if Obj.TryGetValue<string>('published_at', Candidate.PublishedAt) then
        Candidate.PublishedAt := Copy(Candidate.PublishedAt, 1, 64);
      if Obj.TryGetValue<string>('body', Candidate.Notes) then
        Candidate.Notes := Copy(Candidate.Notes, 1, 24000);
      if Candidate.Notes.Trim = '' then
        Candidate.Notes := 'Автор не опубликовал описание изменений этого выпуска.';
{$IFDEF WIN64}
      ExpectedName := 'HomeLibRu_x64.zip';
{$ELSE}
      ExpectedName := 'HomeLibRu.zip';
{$ENDIF}
      for Asset in Assets do
        if (Asset is TJSONObject) and
           TJSONObject(Asset).TryGetValue<string>('name', Name) and
           ((Name = 'HomeLibRu.zip') or (Name = 'HomeLibRu_x64.zip')) then
        begin
          HasArchive := True;
          if (Name = ExpectedName) and
             TJSONObject(Asset).TryGetValue<string>('browser_download_url', DownloadURL) and
             (DownloadURL = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + Tag + '/' + ExpectedName) and
             TJSONObject(Asset).TryGetValue<string>('digest', Digest) and Digest.StartsWith('sha256:') and
             IsUpdateSHA256(Copy(Digest, 8, MaxInt)) and
             TJSONObject(Asset).TryGetValue<Int64>('size', Candidate.Size) and
             (Candidate.Size > 0) and (Candidate.Size <= UPDATE_MAX_ARCHIVE) then
          begin
            Candidate.DownloadURL := DownloadURL;
            Candidate.SHA256 := Copy(Digest, 8, MaxInt);
          end;
        end;
      if not HasArchive then
        Continue;
      Candidate.URL := 'https://github.com/Dicur3x/MyHomeLib/releases/tag/' + Tag;
      Releases.Add(Candidate);
      if (ReleaseInfo.Tag = '') or
         (CompareReleaseTags(Tag, ReleaseInfo.Tag, Comparison) and (Comparison > 0)) then
      begin
        ReleaseInfo := Candidate;
        // Only our repository can be opened, never a URL supplied in JSON.
        ReleaseInfo.URL := 'https://github.com/Dicur3x/MyHomeLib/releases/tag/' + Tag;
      end;
    end;
    Releases.Sort(TComparer<TProgramRelease>.Construct(
      function(const A, B: TProgramRelease): Integer
      begin
        CompareReleaseTags(A.Tag, B.Tag, Result); Result := -Result;
      end));
    NewNotes := ''; History := '';
    for Candidate in Releases do
    begin
      if Length(History) < 300000 then
        History := History + ReleaseNotesHeading(Candidate.Tag, Candidate.PublishedAt) + sLineBreak + Candidate.Notes.Trim + sLineBreak + sLineBreak;
      if CompareReleaseTags(Candidate.Tag, PROGRAM_RELEASE_VERSION, Comparison) and (Comparison > 0) and
         (Length(NewNotes) < 300000) then
        NewNotes := NewNotes + ReleaseNotesHeading(Candidate.Tag, Candidate.PublishedAt) + sLineBreak + Candidate.Notes.Trim + sLineBreak + sLineBreak;
    end;
    ReleaseInfo.Changelog := NewNotes.Trim; ReleaseInfo.History := History.Trim;
    Result := ReleaseInfo.Tag <> '';
  finally
    Releases.Free;
    Root.Free;
  end;
end;

function ProgramUpdateDue(LastCheck, CurrentUTC: TDateTime; IntervalMinutes: Integer): Boolean;
begin
  if IntervalMinutes < 1 then Exit(False);
  // A corrected system clock must not disable checking indefinitely.
  Result := (LastCheck <= 0) or (LastCheck > CurrentUTC) or ((CurrentUTC - LastCheck) * 1440 >= IntervalMinutes);
end;

function ProgramUpdateCache(const AppPath: string): string;
var Base: string;
begin
  Base := GetEnvironmentVariable('LOCALAPPDATA');
  if Base = '' then Base := TPath.GetTempPath;
  Result := IncludeTrailingPathDelimiter(Base) + 'HomeLibRu\Updates\' +
    Copy(THashSHA2.GetHashString(LowerCase(TPath.GetFullPath(AppPath))), 1, 20);
end;

constructor TProgramDownloadThread.Create(AWindow: HWND; AHTTP: THTTPClient;
  const ReleaseInfo: TProgramRelease; const Job: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWindow := AWindow; FHTTP := AHTTP; FRelease := ReleaseInfo; FJob := Job;
  FHTTP.UserAgent := 'HomeLib Ru';
  FHTTP.ConnectionTimeout := 10000; FHTTP.ResponseTimeout := 15000;
  FHTTP.OnReceiveData := ReceiveData;
end;

destructor TProgramDownloadThread.Destroy;
begin
  inherited;
  FHTTP.Free;
end;

procedure TProgramDownloadThread.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
var Percent: Integer;
begin
  AAbort := Terminated or (AReadCount > FRelease.Size) or
    ((AContentLength > 0) and (AContentLength <> FRelease.Size));
  if AAbort then Exit;
  Percent := Integer(AReadCount * 90 div FRelease.Size);
  if Percent <> FProgress then
  begin
    FProgress := Percent;
    PostMessage(FWindow, WM_PROGRAM_UPDATE_PROGRESS, Percent, LPARAM(AReadCount));
  end;
end;

procedure TProgramDownloadThread.Execute;
var Response: IHTTPResponse; Stream: TFileStream; Archive: string;
begin
  try
    if Terminated then Abort;
    if FRelease.OfficialComponent then
    begin
      if not TRegEx.IsMatch(FRelease.ComponentVersion, '^[0-9]+\.[0-9]+(?:\.[0-9]+){0,2}$') then
        raise Exception.Create('Не удалось подтвердить версию компонента.');
      if FRelease.ComponentID = 'SQLite' then
      begin
{$IFDEF WIN64}
        if not TRegEx.IsMatch(FRelease.DownloadURL, '^https://www\.sqlite\.org/[0-9]{4}/sqlite-dll-win-x64-[0-9]{7}\.zip$') then
{$ELSE}
        if not TRegEx.IsMatch(FRelease.DownloadURL, '^https://www\.sqlite\.org/[0-9]{4}/sqlite-dll-win-x86-[0-9]{7}\.zip$') then
{$ENDIF}
          raise Exception.Create('Адрес обновления SQLite не принадлежит официальному источнику.');
      end
      else if FRelease.ComponentID = 'SumatraPDF' then
      begin
{$IFDEF WIN64}
        if FRelease.DownloadURL <> 'https://www.sumatrapdfreader.org/dl/rel/' + FRelease.ComponentVersion + '/SumatraPDF-' + FRelease.ComponentVersion + '-64.zip' then
{$ELSE}
        if FRelease.DownloadURL <> 'https://www.sumatrapdfreader.org/dl/rel/' + FRelease.ComponentVersion + '/SumatraPDF-' + FRelease.ComponentVersion + '.zip' then
{$ENDIF}
          raise Exception.Create('Адрес обновления SumatraPDF не принадлежит официальному источнику.');
      end
      else raise Exception.Create('Официальное обновление этого компонента пока недоступно.');
    end;
    if (FRelease.DownloadURL = '') or
       (not FRelease.OfficialComponent and not IsUpdateSHA256(FRelease.SHA256)) or
       (FRelease.Size <= 0) or (FRelease.Size > UPDATE_MAX_ARCHIVE) then
      raise Exception.Create('Для этого выпуска недоступно обновление внутри программы. Откройте страницу выпуска.');
    AssertUpdatePath(FJob); ForceDirectories(FJob);
    Archive := IncludeTrailingPathDelimiter(FJob) + 'release.zip';
    Stream := TFileStream.Create(Archive, fmCreate);
    try
      Response := FHTTP.Get(FRelease.DownloadURL, Stream);
      if Terminated then Abort;
      if (Response.StatusCode <> 200) or (Stream.Size <> FRelease.Size) then
        raise Exception.Create('Не удалось полностью скачать обновление. Попробуйте позже.');
    finally Stream.Free; end;
    PostMessage(FWindow, WM_PROGRAM_UPDATE_PROGRESS, 95, LPARAM(FRelease.Size));
    if FRelease.OfficialComponent then
    begin
      if (FRelease.ComponentID = 'SQLite') and
         (not IsUpdateSHA256(FRelease.SourceSHA3) or not SameText(UpdateSHA3(Archive), FRelease.SourceSHA3)) then
        raise Exception.Create('Официальная контрольная сумма SQLite не совпадает.');
      FRelease.SHA256 := UpdateSHA256(Archive);
      PrepareOfficialComponent(Archive, FJob, FRelease.ComponentID, FRelease.ComponentVersion, ProgramUpdatePlatform);
    end
    else PrepareProgramUpdate(Archive, FRelease.SHA256, FRelease.Tag, ProgramUpdatePlatform, FJob,
      True, FRelease.ComponentID, FRelease.ComponentVersion);
    if Terminated then Abort;
    FSuccessful := True;
  except
    on E: EAbort do FError := 'Загрузка отменена.';
    on E: Exception do FError := E.Message;
  end;
  PostMessage(FWindow, WM_PROGRAM_UPDATE_DOWNLOADED, 0, 0);
end;

constructor TProgramUpdateThread.Create(AWindow: HWND; AHTTP: THTTPClient;
  const AURL, CacheFolder: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWindow := AWindow;
  FURL := AURL;
  FCacheFolder := CacheFolder;
  FHTTP := AHTTP;
  FHTTP.UserAgent := 'HomeLib Ru';
  FHTTP.ConnectionTimeout := 4000;
  FHTTP.ResponseTimeout := 6000;
  FHTTP.OnReceiveData := ReceiveData;
end;

procedure TProgramUpdateThread.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin
  AAbort := Terminated or (AContentLength > 8 * 1024 * 1024) or
    (AReadCount > 8 * 1024 * 1024);
end;

destructor TProgramUpdateThread.Destroy;
begin
  // inherited waits for Execute before its HTTP client can be destroyed
  inherited;
  FHTTP.Free;
end;

procedure TProgramUpdateThread.Execute;
var Text: string;
begin
  try
    if not Terminated then
    begin
      Text := CachedUpdateText(FHTTP, FURL, FCacheFolder);
      if not Terminated then FSuccessful := ParseProgramReleases(Text, FRelease);
    end;
  except
    // The form decides whether a failed check needs a manual-check message.
    FSuccessful := False;
  end;
  if not Terminated then
    PostMessage(FWindow, WM_PROGRAM_UPDATE_CHECKED, 0, 0);
end;

end.
