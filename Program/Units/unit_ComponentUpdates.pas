unit unit_ComponentUpdates;

interface

uses System.Classes, System.Net.HttpClient, Winapi.Windows, Winapi.Messages,
  unit_ProgramUpdates;

const WM_COMPONENT_UPDATE_CHECKED = WM_APP + $0504;
  COMPONENT_FEED_NAME = 'HomeLibRu.components.json';
  COMPONENT_IDS: array[0..2] of string = ('SQLite', 'AlReader', 'SumatraPDF');
  CHECKED_COMPONENT_INDICES: array[0..1] of Integer = (0, 2);

type
  TComponentReleases = array[0..2] of TProgramRelease;
  TComponentUpdateThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FWindow: HWND;
    FSuccessful: Boolean;
    FError, FURL: string;
    FReleases: TComponentReleases;
    FLimit: Int64;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const URL: string = PROGRAM_RELEASES_API);
    destructor Destroy; override;
    property Successful: Boolean read FSuccessful;
    property ErrorText: string read FError;
    property Releases: TComponentReleases read FReleases;
  end;

function ParseComponentFeed(const JSON, ReleaseTag, AssetsJSON: string;
  out Releases: TComponentReleases; RequireAssets: Boolean = True): Boolean;
function ComponentInstalledVersion(const AppPath, ID: string): string;
function ComponentNewer(const ReleaseInfo: TProgramRelease; const Installed: string): Boolean;
function ComponentArchiveName(const ID, Platform: string): string;
function ComponentChanges(const Info: TProgramRelease; const Installed: string): string;
function ParseSQLiteDownload(const HTML, Changes: string; out Info: TProgramRelease): Boolean;
function ParseSumatraReleases(const JSON: string; out Info: TProgramRelease): Boolean;

implementation

uses System.SysUtils, System.JSON, System.RegularExpressions, System.IOUtils,
  System.Hash, System.Generics.Collections, System.Generics.Defaults, unit_ProgramUpdateInstaller, unit_UpdateNotes;

function ParseSQLiteDownload(const HTML, Changes: string; out Info: TProgramRelease): Boolean;
var Match, Item: TMatch; Arch, Text: string; History: TJSONArray; Entry: TJSONObject;
  Comparison: Integer;
begin
  Info := Default(TProgramRelease); Info.ComponentID := 'SQLite'; Result := False;
{$IFDEF WIN64}
  Arch := 'x64';
{$ELSE}
  Arch := 'x86';
{$ENDIF}
  Match := TRegEx.Match(HTML, '(?m)^PRODUCT,([0-9.]+),([0-9]{4}/sqlite-dll-win-' +
    Arch + '-[0-9]{7}\.zip),([0-9]+),([a-fA-F0-9]{64})(?:,|\r?$)');
  if not Match.Success or not CompareComponentVersions(Match.Groups[1].Value, '3.0', Comparison) or
     not Match.Groups[1].Value.StartsWith('3.') or
     not TryStrToInt64(Match.Groups[3].Value, Info.Size) or
     (Info.Size < 1) or (Info.Size > UPDATE_MAX_ARCHIVE) then Exit;
  Info.ComponentVersion := Match.Groups[1].Value; Info.Tag := Info.ComponentVersion;
  Info.DownloadURL := 'https://www.sqlite.org/' + Match.Groups[2].Value;
  Info.URL := 'https://www.sqlite.org/changes.html'; Info.SourceSHA3 := Match.Groups[4].Value;
  Info.OfficialComponent := True; History := TJSONArray.Create;
  try
    for Item in TRegEx.Matches(Changes, '(?is)<h3[^>]*>\s*(?:([0-9]{4}-[0-9]{2}-[0-9]{2})\s*)?\(([0-9.]+)\)</h3>(.*?)(?=<h3|\z)') do
      if CompareComponentVersions(Item.Groups[2].Value, Info.ComponentVersion, Comparison) and (Comparison <= 0) then
      begin
        Text := SQLiteNotesToMarkdown(Item.Groups[3].Value);
        Entry := TJSONObject.Create; Entry.AddPair('version', Item.Groups[2].Value);
        Entry.AddPair('date', Item.Groups[1].Value);
        if Comparison = 0 then Info.PublishedAt := Item.Groups[1].Value;
        Entry.AddPair('notes', Copy(Text.Trim, 1, 12000)); History.AddElement(Entry);
        Info.History := Info.History + ReleaseNotesHeading(Item.Groups[2].Value, Item.Groups[1].Value) + sLineBreak + Copy(Text.Trim, 1, 12000) + sLineBreak + sLineBreak;
        if (History.Count >= 30) or (Length(Info.History) > 120000) then Break;
      end;
    if History.Count = 0 then Exit;
    Info.Notes := History.ToJSON; Info.Changelog := Info.History.Trim; Result := True;
  finally History.Free; end;
end;

function ParseSumatraReleases(const JSON: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Value: TJSONValue; Obj, Entry: TJSONObject; History: TJSONArray;
  Version, Tag, Notes, Suffix: string; Draft, Prerelease: Boolean; Comparison: Integer; Match: TMatch;
  Entries: TList<TProgramRelease>; ReleaseEntry: TProgramRelease;
begin
  Result := False; Info := Default(TProgramRelease); Info.ComponentID := 'SumatraPDF';
  Root := TJSONObject.ParseJSONValue(JSON); History := TJSONArray.Create;
  Entries := TList<TProgramRelease>.Create;
  try
    if not (Root is TJSONArray) then Exit;
    for Value in TJSONArray(Root) do
    begin
      if not (Value is TJSONObject) then Continue;
      Obj := TJSONObject(Value); Draft := False; Prerelease := False;
      Obj.TryGetValue<Boolean>('draft', Draft); Obj.TryGetValue<Boolean>('prerelease', Prerelease);
      if Draft or Prerelease or not Obj.TryGetValue<string>('tag_name', Tag) then Continue;
      Match := TRegEx.Match(Tag, '^v?([0-9]+\.[0-9]+(?:\.[0-9]+){0,2})(?:rel)?$');
      if not Match.Success then Continue; Version := Match.Groups[1].Value;
      if not CompareComponentVersions(Version, Version, Comparison) then Continue;
      if (Info.ComponentVersion = '') or
         (CompareComponentVersions(Version, Info.ComponentVersion, Comparison) and (Comparison > 0)) then
        Info.ComponentVersion := Version;
      Notes := ''; Obj.TryGetValue<string>('body', Notes);
      if Notes.Trim = '' then Notes := 'Автор не опубликовал описание изменений этой версии.';
      ReleaseEntry := Default(TProgramRelease); ReleaseEntry.ComponentVersion := Version;
      ReleaseEntry.Notes := Copy(Notes, 1, 12000);
      if Obj.TryGetValue<string>('published_at', ReleaseEntry.PublishedAt) then
        ReleaseEntry.PublishedAt := Copy(ReleaseEntry.PublishedAt, 1, 64);
      Entries.Add(ReleaseEntry);
    end;
    if Info.ComponentVersion = '' then Exit;
    Entries.Sort(TComparer<TProgramRelease>.Construct(
      function(const Left, Right: TProgramRelease): Integer
      begin
        CompareComponentVersions(Right.ComponentVersion, Left.ComponentVersion, Result);
      end));
    for ReleaseEntry in Entries do
    begin
      Entry := TJSONObject.Create; Entry.AddPair('version', ReleaseEntry.ComponentVersion);
      Entry.AddPair('notes', ReleaseEntry.Notes); Entry.AddPair('date', ReleaseEntry.PublishedAt);
      History.AddElement(Entry);
      if ReleaseEntry.ComponentVersion = Info.ComponentVersion then Info.PublishedAt := ReleaseEntry.PublishedAt;
      Info.History := Info.History + ReleaseNotesHeading(ReleaseEntry.ComponentVersion, ReleaseEntry.PublishedAt) + sLineBreak +
        ReleaseEntry.Notes + sLineBreak + sLineBreak;
      if (History.Count >= 30) or (Length(Info.History) > 120000) then Break;
    end;
{$IFDEF WIN64}
    Suffix := '-64';
{$ELSE}
    Suffix := '';
{$ENDIF}
    Info.Tag := Info.ComponentVersion; Info.Notes := History.ToJSON; Info.Changelog := Info.History.Trim;
    Info.URL := 'https://www.sumatrapdfreader.org/docs/Version-history';
    Info.DownloadURL := 'https://www.sumatrapdfreader.org/dl/rel/' + Info.ComponentVersion +
      '/SumatraPDF-' + Info.ComponentVersion + Suffix + '.zip';
    Info.OfficialComponent := True; Result := True;
  finally Entries.Free; Root.Free; History.Free; end;
end;

function ComponentArchiveName(const ID, Platform: string): string;
begin
  Result := 'HomeLibRu-' + ID + '-' + Platform + '.zip';
end;

function ComponentInstalledVersion(const AppPath, ID: string): string;
begin
  Result := UpdateFileVersion(IncludeTrailingPathDelimiter(AppPath) +
    StringReplace(ComponentFileName(ID), '/', PathDelim, [rfReplaceAll]));
end;

function ComponentNewer(const ReleaseInfo: TProgramRelease; const Installed: string): Boolean;
var Comparison: Integer;
begin
  Result := (ReleaseInfo.ComponentID <> '') and (ReleaseInfo.DownloadURL <> '') and
    ((Installed = '') or (CompareComponentVersions(ReleaseInfo.ComponentVersion, Installed, Comparison) and
      (Comparison > 0)));
end;

function ComponentChanges(const Info: TProgramRelease; const Installed: string): string;
var Root: TJSONValue; Entry: TJSONValue; Version, Notes, Date: string; Comparison: Integer;
begin
  Result := ''; Root := TJSONObject.ParseJSONValue(Info.Notes);
  try
    if not (Root is TJSONArray) then Exit(Info.History);
    for Entry in TJSONArray(Root) do
      if (Entry is TJSONObject) and TJSONObject(Entry).TryGetValue<string>('version', Version) and
         TJSONObject(Entry).TryGetValue<string>('notes', Notes) and
         ((Installed = '') or (CompareComponentVersions(Version, Installed, Comparison) and (Comparison > 0))) then
      begin
        Date := ''; TJSONObject(Entry).TryGetValue<string>('date', Date);
        Result := Result + ReleaseNotesHeading(Version, Date) + sLineBreak + Notes + sLineBreak + sLineBreak;
      end;
  finally Root.Free; end;
  Result := Result.Trim;
end;

function ParseComponentFeed(const JSON, ReleaseTag, AssetsJSON: string;
  out Releases: TComponentReleases; RequireAssets: Boolean): Boolean;
var Root, AssetsRoot: TJSONValue; Items, History, Assets: TJSONArray;
  Value, Entry, Asset: TJSONValue; Obj: TJSONObject; ID, Version, Platform, Notes, Name, URL, Digest, Date: string;
  Format, I, Comparison: Integer; Info: TProgramRelease; Found: array[0..2] of Boolean;
begin
  Result := False; Releases := Default(TComponentReleases); Root := nil; AssetsRoot := nil;
  for I := 0 to 2 do Found[I] := False;
  if not TRegEx.IsMatch(ReleaseTag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
  try
    Root := TJSONObject.ParseJSONValue(JSON); AssetsRoot := TJSONObject.ParseJSONValue(AssetsJSON);
    if not (Root is TJSONObject) or not (AssetsRoot is TJSONArray) or
       not TJSONObject(Root).TryGetValue<Integer>('format', Format) or (Format <> 1) or
       not TJSONObject(Root).TryGetValue<TJSONArray>('components', Items) or (Items.Count > 6) then Exit;
    Assets := TJSONArray(AssetsRoot);
    for Value in Items do
    begin
      if not (Value is TJSONObject) then Exit;
      Obj := TJSONObject(Value);
      if not Obj.TryGetValue<string>('platform', Platform) then Exit;
      if Platform <> ProgramUpdatePlatform then Continue;
      if not Obj.TryGetValue<string>('id', ID) or not Obj.TryGetValue<string>('version', Version) or
         not CompareComponentVersions(Version, Version, Comparison) or
         not Obj.TryGetValue<TJSONArray>('history', History) or
         (History.Count < 1) or (History.Count > 100) then Exit;
      I := 0; while (I < 3) and (COMPONENT_IDS[I] <> ID) do Inc(I);
      if (I = 3) or Found[I] then Exit;
      Found[I] := True; Info := Default(TProgramRelease);
      Info.ComponentID := ID; Info.ComponentVersion := Version; Info.Tag := ReleaseTag;
      Info.URL := 'https://github.com/Dicur3x/MyHomeLib/releases/tag/' + ReleaseTag;
      for Entry in History do
      begin
        if not (Entry is TJSONObject) or
           not TJSONObject(Entry).TryGetValue<string>('version', Name) or
           not CompareComponentVersions(Name, Version, Comparison) or (Comparison > 0) or
           not TJSONObject(Entry).TryGetValue<string>('notes', Notes) or (Notes.Trim = '') then Exit;
        Date := ''; TJSONObject(Entry).TryGetValue<string>('date', Date);
        if Name = Version then Info.PublishedAt := Copy(Date, 1, 64);
        Info.History := Info.History + ReleaseNotesHeading(Name, Date) + sLineBreak + Copy(Notes, 1, 12000) + sLineBreak + sLineBreak;
        if Length(Info.History) > 120000 then Exit;
      end;
      // Asset location, checksum and size come from GitHub, not the feed body.
      Name := ComponentArchiveName(ID, Platform);
      for Asset in Assets do
        if (Asset is TJSONObject) and TJSONObject(Asset).TryGetValue<string>('name', Digest) and
           (Digest = Name) and TJSONObject(Asset).TryGetValue<string>('browser_download_url', URL) and
           (URL = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + ReleaseTag + '/' + Name) and
           TJSONObject(Asset).TryGetValue<string>('digest', Digest) and Digest.StartsWith('sha256:') and
           IsUpdateSHA256(Copy(Digest, 8, MaxInt)) and
           TJSONObject(Asset).TryGetValue<Int64>('size', Info.Size) and
           (Info.Size > 0) and (Info.Size <= UPDATE_MAX_ARCHIVE) then
        begin Info.DownloadURL := URL; Info.SHA256 := Copy(Digest, 8, MaxInt); end;
      if RequireAssets and (Info.DownloadURL = '') then Exit;
      Info.Notes := History.ToJSON;
      Info.Changelog := Info.History.Trim; Releases[I] := Info;
    end;
    Result := Found[0] and Found[1] and Found[2];
  finally Root.Free; AssetsRoot.Free; end;
end;

constructor TComponentUpdateThread.Create(AWindow: HWND; AHTTP: THTTPClient; const URL: string);
begin
  inherited Create(True); FreeOnTerminate := False; FHTTP := AHTTP; FWindow := AWindow; FURL := URL;
  FHTTP.UserAgent := 'HomeLib Ru'; FHTTP.ConnectionTimeout := 4000; FHTTP.ResponseTimeout := 6000;
  FHTTP.OnReceiveData := ReceiveData; FLimit := 8 * 1024 * 1024;
end;

destructor TComponentUpdateThread.Destroy;
begin inherited; FHTTP.Free; end;

procedure TComponentUpdateThread.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin AAbort := Terminated or (AContentLength > FLimit) or (AReadCount > FLimit); end;

procedure TComponentUpdateThread.Execute;
var I: Integer; DownloadPage, Changes: string; Response: IHTTPResponse;
  function GetText(const URL: string): string;
  begin
    if Terminated then Abort;
    Response := FHTTP.Get(URL);
    if Terminated or (Response.StatusCode <> 200) then
      raise Exception.Create('Не удалось получить сведения с официального сайта. Попробуйте позже.');
    Result := Response.ContentAsString(TEncoding.UTF8);
  end;
begin
  for I in CHECKED_COMPONENT_INDICES do
  begin
    FReleases[I].ComponentID := COMPONENT_IDS[I];
    try
      case I of
        0:
          begin
            DownloadPage := GetText('https://www.sqlite.org/download.html');
            Changes := GetText('https://www.sqlite.org/changes.html');
            if not ParseSQLiteDownload(DownloadPage, Changes, FReleases[I]) then
              raise Exception.Create('Не удалось прочитать версию, контрольную сумму или changelog SQLite.');
          end;
        2:
          begin
            Changes := GetText('https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases?per_page=30');
            if not ParseSumatraReleases(Changes, FReleases[I]) then
              raise Exception.Create('Не удалось прочитать стабильную версию или changelog SumatraPDF.');
            if Terminated then Abort;
            Response := FHTTP.Head(FReleases[I].DownloadURL);
            if Terminated or (Response.StatusCode <> 200) or (Response.ContentLength < 1) or
               (Response.ContentLength > UPDATE_MAX_ARCHIVE) then
              raise Exception.Create('Не удалось определить размер официального архива SumatraPDF.');
            FReleases[I].Size := Response.ContentLength;
          end;
      end;
    except
      on E: Exception do
      begin
        FReleases[I].DownloadURL := '';
        FReleases[I].ComponentError := COMPONENT_IDS[I] + ': ' + E.Message;
      end;
    end;
    if Terminated then Exit;
  end;
  FSuccessful := True;
  if not Terminated then PostMessage(FWindow, WM_COMPONENT_UPDATE_CHECKED, 0, 0);
end;

end.
