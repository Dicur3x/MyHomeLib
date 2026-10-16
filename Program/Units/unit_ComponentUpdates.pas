unit unit_ComponentUpdates;

interface

uses System.Classes, System.Net.HttpClient, Winapi.Windows, Winapi.Messages,
  unit_ProgramUpdates;

type
  TComponentCheckKind = (ccBundled, ccSQLite, ccSumatra, ccRaster, ccDocSharp);
  TUpdateComponent = record
    ID, Title, URL: string;
    CheckKind: TComponentCheckKind;
    CheckOnly: Boolean;
  end;

const
  WM_COMPONENT_UPDATE_CHECKED = WM_APP + $0504;
  COMPONENT_FEED_NAME = 'HomeLibRu.components.json';
  UPDATE_COMPONENTS: array[0..5] of TUpdateComponent = (
    (ID:'SQLite'; Title:'База коллекций'; URL:'https://www.sqlite.org/changes.html'; CheckKind:ccSQLite; CheckOnly:False),
    (ID:'AlReader'; Title:'Внешняя читалка'; URL:'https://alreader.com'; CheckKind:ccBundled; CheckOnly:False),
    (ID:'SumatraPDF'; Title:'Внешняя читалка PDF и DjVu'; URL:'https://www.sumatrapdfreader.org/docs/Version-history'; CheckKind:ccSumatra; CheckOnly:False),
    (ID:'DjVuLibre'; Title:'Чтение DjVu'; URL:'https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/'; CheckKind:ccRaster; CheckOnly:False),
    (ID:'7-Zip'; Title:'Распаковка архивов'; URL:'https://www.7-zip.org/download.html'; CheckKind:ccRaster; CheckOnly:False),
    (ID:'DocSharp'; Title:'Чтение DOC, PPT и XLS'; URL:'https://github.com/manfromarce/DocSharp/releases'; CheckKind:ccDocSharp; CheckOnly:False));

type
  TComponentReleases = array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of TProgramRelease;
  TComponentUpdateThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FWindow: HWND;
    FSuccessful: Boolean;
    FError, FURL, FCacheFolder: string;
    FReleases: TComponentReleases;
    FLimit: Int64;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
  protected
    procedure Execute; override;
    function FetchText(const URL: string): string; virtual;
    function FetchHead(const URL: string): IHTTPResponse; virtual;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const URL: string = PROGRAM_RELEASES_API; const CacheFolder: string = '');
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
function ParseRasterComponent(const Text, ID: string; out Info: TProgramRelease): Boolean;
function ParseDocSharpVersions(const DocJSON, CommonJSON: string; out Info: TProgramRelease): Boolean;
function ParseOfficeDocSharpVersions(const DocJSON, CommonJSON, PptJSON, XlsJSON: string; out Info: TProgramRelease): Boolean;
function ComponentIDs: TArray<string>;
function CheckedComponentIndices: TArray<Integer>;
function ComponentTitle(Index: Integer): string;
function UpdateReleasePageURL(const Component, Tag, SavedURL: string): string;
function UpdateReleasePageCaption(const Component, URL: string): string;
procedure MergeVerifiedComponentPackages(var Current: TComponentReleases; const Published: TComponentReleases);
procedure PreserveComponentHistory(var Current: TComponentReleases; const Previous: TComponentReleases);
procedure LoadComponentHistory(const CacheFolder: string; var Releases: TComponentReleases);
procedure SaveComponentHistory(const CacheFolder: string; const Releases: TComponentReleases);

implementation

uses System.SysUtils, System.JSON, System.RegularExpressions, System.IOUtils,
  System.Hash, System.Generics.Collections, System.Generics.Defaults, unit_ProgramUpdateInstaller,
  unit_UpdateNotes, unit_UpdateTextCache;

function ComponentIDs: TArray<string>;
var I: Integer;
begin
  SetLength(Result,Length(UPDATE_COMPONENTS));
  for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do Result[I]:=UPDATE_COMPONENTS[I].ID;
end;

function CheckedComponentIndices: TArray<Integer>;
var I, Count: Integer;
begin
  Result:=nil;
  for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
    if (UPDATE_COMPONENTS[I].CheckKind<>ccBundled) or not UPDATE_COMPONENTS[I].CheckOnly then
    begin Count:=Length(Result); SetLength(Result,Count+1); Result[Count]:=I; end;
end;

function ComponentTitle(Index: Integer): string;
begin Result:=UPDATE_COMPONENTS[Index].Title+' · '+UPDATE_COMPONENTS[Index].ID; end;

function UpdateReleasePageURL(const Component, Tag, SavedURL: string): string;
const ReleasesPage = 'https://github.com/Dicur3x/MyHomeLib/releases';
  ReleasePrefix = ReleasesPage + '/tag/';
var Info: TUpdateComponent;
begin
  // Cached UI state is not a source of arbitrary ShellExecute targets. Accept
  // only the canonical pages emitted by our release/component parsers.
  if (SavedURL = ReleasesPage) or (SavedURL.StartsWith(ReleasePrefix) and
    TRegEx.IsMatch(Copy(SavedURL, Length(ReleasePrefix) + 1, MaxInt), '\A[A-Za-z0-9._-]{1,80}\z')) then
    Exit(SavedURL);
  for Info in UPDATE_COMPONENTS do
    if ((Component = Info.ID) or (Component = 'batch')) and (SavedURL = Info.URL) then
      Exit(Info.URL);
  // A component-only batch tag is the first component's version, not an
  // application release tag. Old caches have no page URL: use the release list.
  if Component = 'batch' then Exit(ReleasesPage);
  for Info in UPDATE_COMPONENTS do
    if Component = Info.ID then Exit(Info.URL);
  if (Component = '') and TRegEx.IsMatch(Tag, '\A[A-Za-z0-9._-]{1,80}\z') then
    Exit(ReleasePrefix + Tag);
  Result := ReleasesPage;
end;

function UpdateReleasePageCaption(const Component, URL: string): string;
var Info: TUpdateComponent;
begin
  if Component = 'batch' then
  begin
    for Info in UPDATE_COMPONENTS do
      if URL = Info.URL then Exit('Сайт автора: ' + Info.ID);
    Exit('Выпуски HomeLib Ru');
  end;
  if Component <> '' then Result := 'Сайт автора'
  else Result := 'Открыть GitHub';
end;

function ParseDocSharpVersions(const DocJSON, CommonJSON: string; out Info: TProgramRelease): Boolean;
var Doc, Common: TJSONValue; DocItems, CommonItems: TJSONArray; Value: TJSONValue;
  Versions: TDictionary<string,Boolean>; Version: string; Comparison: Integer;
begin
  Result:=False; Info:=Default(TProgramRelease); Info.ComponentID:='DocSharp'; Info.OfficialComponent:=True;
  Doc:=nil; Common:=nil; Versions:=TDictionary<string,Boolean>.Create;
  try
    Doc:=TJSONObject.ParseJSONValue(DocJSON); Common:=TJSONObject.ParseJSONValue(CommonJSON);
    if not (Doc is TJSONObject) or not (Common is TJSONObject) or
      not TJSONObject(Doc).TryGetValue<TJSONArray>('versions',DocItems) or
      not TJSONObject(Common).TryGetValue<TJSONArray>('versions',CommonItems) or
      (DocItems.Count>4096) or (CommonItems.Count>4096) then Exit;
    // Both assemblies must have the same published stable version. NuGet may
    // return unsorted entries, previews, or a not-yet-complete release pair.
    for Value in CommonItems do
      if Value is TJSONString then Versions.AddOrSetValue(Value.Value,True);
    for Value in DocItems do
    begin
      if not (Value is TJSONString) then Continue;
      Version:=Value.Value;
      if not Versions.ContainsKey(Version) or not TRegEx.IsMatch(Version,'^[0-9]+\.[0-9]+\.[0-9]+$') or
        not CompareComponentVersions(Version,Version,Comparison) then Continue;
      if (Info.ComponentVersion='') or
        (CompareComponentVersions(Version,Info.ComponentVersion,Comparison) and (Comparison>0)) then
        Info.ComponentVersion:=Version;
    end;
    if Info.ComponentVersion='' then Exit;
    Info.Tag:=Info.ComponentVersion; Info.URL:='https://github.com/manfromarce/DocSharp/releases';
    Info.DownloadURL:='https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/'+Info.ComponentVersion+'/docsharp.binary.doc.'+Info.ComponentVersion+'.nupkg';
    Info.SecondaryURL:='https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/'+Info.ComponentVersion+'/docsharp.binary.common.'+Info.ComponentVersion+'.nupkg';
    Info.History:=ReleaseNotesHeading(Info.ComponentVersion,'')+sLineBreak+
      'Версия DocSharp.Binary.Doc и DocSharp.Binary.Common проверена в официальном каталоге NuGet.'+sLineBreak+
      'Новые версии библиотеки выпускаются независимо от HomeLib Ru.'+sLineBreak+
      'Обновление скачивается непосредственно из официального каталога NuGet.'+sLineBreak+
      'Изменения автора: '+Info.URL;
    Info.Changelog:=Info.History; Result:=True;
  finally Versions.Free; Doc.Free; Common.Free; end;
end;

function ParseOfficeDocSharpVersions(const DocJSON, CommonJSON, PptJSON, XlsJSON: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Values: TJSONArray; Sets: TArray<TDictionary<string,Boolean>>;
  Common: TJSONObject; Filtered: TJSONArray; Version: string; Index: Integer;
begin
  Result:=False; Info:=Default(TProgramRelease); SetLength(Sets,3);
  try
    for Index:=0 to 2 do
    begin
      Sets[Index]:=TDictionary<string,Boolean>.Create;
      Root:=TJSONObject.ParseJSONValue(TArray<string>.Create(CommonJSON,PptJSON,XlsJSON)[Index]);
      try
        if not (Root is TJSONObject) or not TJSONObject(Root).TryGetValue<TJSONArray>('versions',Values) or (Values.Count>4096) then Exit;
        for var Value in Values do if Value is TJSONString then Sets[Index].AddOrSetValue(Value.Value,True);
      finally Root.Free; end;
    end;
    Common:=TJSONObject.Create; Filtered:=TJSONArray.Create; Common.AddPair('versions',Filtered);
    try
      for Version in Sets[0].Keys do if Sets[1].ContainsKey(Version) and Sets[2].ContainsKey(Version) then Filtered.Add(Version);
      Result:=ParseDocSharpVersions(DocJSON,Common.ToJSON,Info);
      if Result then
      begin
        Info.AdditionalURLs:=TArray<string>.Create(
          'https://api.nuget.org/v3-flatcontainer/docsharp.binary.ppt/'+Info.ComponentVersion+'/docsharp.binary.ppt.'+Info.ComponentVersion+'.nupkg',
          'https://api.nuget.org/v3-flatcontainer/docsharp.binary.xls/'+Info.ComponentVersion+'/docsharp.binary.xls.'+Info.ComponentVersion+'.nupkg');
        Info.History:=Info.History.Replace('DocSharp.Binary.Doc и DocSharp.Binary.Common','DocSharp.Binary.Doc, Common, Ppt и Xls'); Info.Changelog:=Info.History;
      end;
    finally Common.Free; end;
  finally for var SetValue in Sets do SetValue.Free; end;
end;

procedure MergeVerifiedComponentPackages(var Current: TComponentReleases; const Published: TComponentReleases);
var I, Comparison: Integer; AuthorVersion: string;
begin
  for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
  begin
    if (Published[I].ComponentID<>UPDATE_COMPONENTS[I].ID) or Published[I].CheckOnly or
      not TRegEx.IsMatch(Published[I].Tag,'^[A-Za-z0-9._-]{1,80}$') or
      (Published[I].DownloadURL<>'https://github.com/Dicur3x/MyHomeLib/releases/download/'+Published[I].Tag+'/'+
        ComponentArchiveName(UPDATE_COMPONENTS[I].ID,ProgramUpdatePlatform)) or
      not IsUpdateSHA256(Published[I].SHA256) or
      (Published[I].Size<=0) or (Published[I].Size>UPDATE_MAX_ARCHIVE) then Continue;
    if not Current[I].CheckOnly and (Current[I].DownloadURL<>'') and
      CompareComponentVersions(Current[I].ComponentVersion,Published[I].ComponentVersion,Comparison) and
      (Comparison>=0) then Continue;
    AuthorVersion:=Current[I].AuthorVersion;
    if AuthorVersion='' then AuthorVersion:=Current[I].ComponentVersion;
    if (AuthorVersion='') or (CompareComponentVersions(AuthorVersion,Published[I].ComponentVersion,Comparison) and
      (Comparison<0)) then AuthorVersion:=Published[I].ComponentVersion;
    Current[I]:=Published[I]; Current[I].AuthorVersion:=AuthorVersion;
  end;
end;

procedure PreserveComponentHistory(var Current: TComponentReleases; const Previous: TComponentReleases);
var I: Integer;
begin
  for I in CheckedComponentIndices do
    if Current[I].History.Trim = '' then
    begin
      Current[I].History := Previous[I].History;
      Current[I].Notes := Previous[I].Notes;
    end;
end;

procedure LoadComponentHistory(const CacheFolder: string; var Releases: TComponentReleases);
var I: Integer; Text: string;
begin
  for I in CheckedComponentIndices do
  begin
    Text := ReadUpdateHistory(IncludeTrailingPathDelimiter(CacheFolder) + 'notes-' + ComponentIDs[I] + '.txt');
    if Text.Trim <> '' then Releases[I].History := Copy(Text, 1, 324000);
  end;
end;

procedure SaveComponentHistory(const CacheFolder: string; const Releases: TComponentReleases);
var I: Integer;
begin
  for I in CheckedComponentIndices do
    WriteUpdateHistory(IncludeTrailingPathDelimiter(CacheFolder) + 'notes-' + ComponentIDs[I] + '.txt',
      Copy(Releases[I].History, 1, 324000));
end;

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

function ParseRasterComponent(const Text, ID: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Tag, Notes, Name, Suffix, URL, Digest: string; Match: TMatch; Comparison: Integer; Flag: Boolean; Assets: TJSONArray; Asset: TJSONValue;
begin
  Info:=Default(TProgramRelease); Info.ComponentID:=ID; Info.CheckOnly:=True; Result:=False;
  if ID='7-Zip' then
  begin
    Root:=TJSONObject.ParseJSONValue(Text);
    try
      if not (Root is TJSONObject) or not TJSONObject(Root).TryGetValue<string>('tag_name',Tag) or
        not TRegEx.IsMatch(Tag,'^[0-9]{2}\.[0-9]{2}$') then Exit;
      Flag:=False; TJSONObject(Root).TryGetValue<Boolean>('draft',Flag); if Flag then Exit;
      Flag:=False; TJSONObject(Root).TryGetValue<Boolean>('prerelease',Flag); if Flag then Exit;
      Info.ComponentVersion:=Tag;
      TJSONObject(Root).TryGetValue<string>('body',Notes);
      Info.History:=Copy(Notes,1,12000);
      TJSONObject(Root).TryGetValue<string>('published_at',Info.PublishedAt);
      Info.URL:='https://www.7-zip.org/download.html';
{$IFDEF WIN64}
      Suffix:='-x64';
{$ELSE}
      Suffix:='';
{$ENDIF}
      Name:='7z'+Tag.Replace('.','')+Suffix+'.exe';
      if TJSONObject(Root).TryGetValue<TJSONArray>('assets',Assets) then
        for Asset in Assets do
          if (Asset is TJSONObject) and TJSONObject(Asset).TryGetValue<string>('name',Notes) and
            (Notes=Name) and TJSONObject(Asset).TryGetValue<string>('browser_download_url',URL) and
            (URL='https://github.com/ip7z/7zip/releases/download/'+Tag+'/'+Name) and
            TJSONObject(Asset).TryGetValue<string>('digest',Digest) and Digest.StartsWith('sha256:') and
            IsUpdateSHA256(Copy(Digest,8,MaxInt)) and TJSONObject(Asset).TryGetValue<Int64>('size',Info.Size) and
            (Info.Size>0) and (Info.Size<=UPDATE_MAX_ARCHIVE) then
          begin Info.DownloadURL:=URL; Info.SHA256:=Copy(Digest,8,MaxInt); Info.CheckOnly:=False; Info.OfficialComponent:=True; end;
    finally Root.Free; end;
  end
  else if ID='DjVuLibre' then
  begin
    // Source-only releases do not replace the compatible Windows tools.
    for Match in TRegEx.Matches(Text,'/projects/djvu/files/DjVuLibre_Windows/(3\.5\.[0-9]+)(?:\+|%2[Bb])') do
      if (Info.ComponentVersion='') or (CompareComponentVersions(Match.Groups[1].Value,
        Info.ComponentVersion,Comparison) and (Comparison>0)) then Info.ComponentVersion:=Match.Groups[1].Value;
    if Info.ComponentVersion='' then Exit;
    Info.URL:='https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/';
    Info.History:='Проверяется версия готовых инструментов DjVuLibre для Windows. Версия исходного кода и DjView могут отличаться.';
  end
  else Exit;
  Info.Tag:=Info.ComponentVersion; if Info.DownloadURL='' then Info.DownloadURL:=Info.URL;
  Info.History:=ReleaseNotesHeading(Info.ComponentVersion,Info.PublishedAt)+sLineBreak+Info.History;
  Info.Changelog:=Info.History; Result:=True;
end;

function ComponentArchiveName(const ID, Platform: string): string;
begin
  Result := 'HomeLibRu-' + ID + '-' + Platform + '.zip';
end;

function ComponentInstalledVersion(const AppPath, ID: string): string;
begin
  Result:=InstalledComponentVersion(AppPath,ID);
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
  Format, I, Comparison: Integer; Info: TProgramRelease;
  Found: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of Boolean;
begin
  Result := False; Releases := Default(TComponentReleases); Root := nil; AssetsRoot := nil;
  for I := 0 to High(Found) do Found[I] := False;
  if not TRegEx.IsMatch(ReleaseTag, '^[A-Za-z0-9._-]{1,80}$') then Exit;
  try
    Root := TJSONObject.ParseJSONValue(JSON); AssetsRoot := TJSONObject.ParseJSONValue(AssetsJSON);
    if not (Root is TJSONObject) or not (AssetsRoot is TJSONArray) or
       not TJSONObject(Root).TryGetValue<Integer>('format', Format) or (Format <> 1) or
       not TJSONObject(Root).TryGetValue<TJSONArray>('components', Items) or (Items.Count > 128) then Exit;
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
      I := 0; while (I <= High(ComponentIDs)) and (ComponentIDs[I] <> ID) do Inc(I);
      // A later HomeLib Ru may describe additional components. Older builds
      // can still read their known entries; unknown IDs never gain installers.
      if I>High(UPDATE_COMPONENTS) then Continue;
      if Found[I] then Exit;
      Found[I] := True; Info := Default(TProgramRelease);
      Info.ComponentID := ID; Info.ComponentVersion := Version; Info.Tag := ReleaseTag;
      Info.CheckOnly:=UPDATE_COMPONENTS[I].CheckOnly;
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
      if RequireAssets and not Info.CheckOnly and (Info.DownloadURL = '') then Exit;
      Info.Notes := History.ToJSON;
      Info.Changelog := Info.History.Trim; Releases[I] := Info;
    end;
    Result := Found[0] and Found[1] and Found[2];
  finally Root.Free; AssetsRoot.Free; end;
end;

constructor TComponentUpdateThread.Create(AWindow: HWND; AHTTP: THTTPClient; const URL, CacheFolder: string);
begin
  inherited Create(True); FreeOnTerminate := False; FHTTP := AHTTP; FWindow := AWindow; FURL := URL;
  FCacheFolder := CacheFolder;
  FHTTP.UserAgent := 'HomeLib Ru'; FHTTP.ConnectionTimeout := 4000; FHTTP.ResponseTimeout := 6000;
  FHTTP.OnReceiveData := ReceiveData; FLimit := 8 * 1024 * 1024;
end;

destructor TComponentUpdateThread.Destroy;
begin inherited; FHTTP.Free; end;

procedure TComponentUpdateThread.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin AAbort := Terminated or (AContentLength > FLimit) or (AReadCount > FLimit); end;

function TComponentUpdateThread.FetchText(const URL: string): string;
begin
  if Terminated then Abort;
  Result := CachedUpdateText(FHTTP, URL, FCacheFolder, FLimit);
  if Terminated then Abort;
end;

function TComponentUpdateThread.FetchHead(const URL: string): IHTTPResponse;
begin
  Result := FHTTP.Head(URL);
end;

procedure TComponentUpdateThread.Execute;
var I: Integer; DownloadPage, Changes, Folder: string; Response: IHTTPResponse; Match: TMatch; NotesInfo: TProgramRelease;
  procedure GetSize(var Info: TProgramRelease);
  begin
    Response:=FetchHead(Info.DownloadURL);
    if Terminated then Abort;
    if (Response.StatusCode<>200) or (Response.ContentLength<1) or
      (Response.ContentLength>UPDATE_MAX_ARCHIVE) then raise Exception.Create('Не удалось определить размер официального файла.');
    Info.Size:=Response.ContentLength;
    if Info.SecondaryURL<>'' then
    begin
      Response:=FetchHead(Info.SecondaryURL);
      if Terminated then Abort;
      if (Response.StatusCode<>200) or (Response.ContentLength<1) or
        (Response.ContentLength>UPDATE_MAX_ARCHIVE-Info.Size) then raise Exception.Create('Не удалось проверить второй пакет библиотеки.');
      Info.SecondarySize:=Response.ContentLength; Info.Size:=Info.Size+Info.SecondarySize;
    end;
    SetLength(Info.AdditionalSizes,Length(Info.AdditionalURLs));
    for var Index:=0 to High(Info.AdditionalURLs) do
    begin
      Response:=FetchHead(Info.AdditionalURLs[Index]); if Terminated then Abort;
      if (Response.StatusCode<>200) or (Response.ContentLength<1) or
        (Response.ContentLength>UPDATE_MAX_ARCHIVE-Info.Size) then raise Exception.Create('Не удалось проверить дополнительный пакет библиотеки.');
      Info.AdditionalSizes[Index]:=Response.ContentLength; Inc(Info.Size,Response.ContentLength);
    end;
  end;
  procedure AuthorNotes(const API: string; var Info: TProgramRelease);
  begin
    if ParseSumatraReleases(FetchText(API),NotesInfo) then
    begin Info.History:=NotesInfo.History; Info.Notes:=NotesInfo.Notes; Info.Changelog:=NotesInfo.Changelog; end;
  end;
begin
  for I in CheckedComponentIndices do
  begin
    FReleases[I].ComponentID := ComponentIDs[I];
    try
      case UPDATE_COMPONENTS[I].CheckKind of
        ccBundled:
          begin
            DownloadPage:=FetchText('https://www.alreader.com/');
            if not DownloadPage.Contains('AlReader2.Win32') then
              FReleases[I].ComponentWarning := 'Официальный сайт доступен, но Windows-выпуск не найден. Установленная читалка продолжает работать.'
            else FReleases[I].ComponentWarning := 'Автор не указал версию Windows-выпуска. Автоустановка недоступна; установленная читалка продолжает работать.';
          end;
        ccSQLite:
          begin
            DownloadPage := FetchText('https://www.sqlite.org/download.html');
            Changes := FetchText('https://www.sqlite.org/changes.html');
            if not ParseSQLiteDownload(DownloadPage, Changes, FReleases[I]) then
              raise Exception.Create('Не удалось прочитать версию, контрольную сумму или changelog SQLite.');
          end;
        ccSumatra:
          begin
            Changes := FetchText('https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases?per_page=30');
            if not ParseSumatraReleases(Changes, FReleases[I]) then
              raise Exception.Create('Не удалось прочитать стабильную версию или changelog SumatraPDF.');
            if Terminated then Abort;
            Response := FetchHead(FReleases[I].DownloadURL);
            if Terminated or (Response.StatusCode <> 200) or (Response.ContentLength < 1) or
               (Response.ContentLength > UPDATE_MAX_ARCHIVE) then
              raise Exception.Create('Не удалось определить размер официального архива SumatraPDF.');
            FReleases[I].Size := Response.ContentLength;
          end;
        ccRaster:
          begin
            if UPDATE_COMPONENTS[I].ID='DjVuLibre' then
            begin
              Changes:=FetchText('https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/');
              if not ParseRasterComponent(Changes,ComponentIDs[I],FReleases[I]) then
                raise Exception.Create('Не удалось прочитать Windows-версию DjVuLibre.');
              Match:=TRegEx.Match(Changes,'/projects/djvu/files/DjVuLibre_Windows/'+
                FReleases[I].ComponentVersion.Replace('.','\.')+'(?:\+|%2[Bb])([0-9.]+)/');
              if not Match.Success then raise Exception.Create('Не найдена папка официального Windows-выпуска.');
              Folder:=FReleases[I].ComponentVersion+'%2B'+Match.Groups[1].Value;
              DownloadPage:=FetchText('https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/'+Folder+'/');
              Match:=TRegEx.Match(DownloadPage,'/projects/djvu/files/DjVuLibre_Windows/'+Folder+
                '/(DjVuLibre-'+FReleases[I].ComponentVersion.Replace('.','\.')+'_DjView-[0-9.]+_Setup\.exe)/download');
              if not Match.Success then raise Exception.Create('Не найден официальный Windows-архив DjVuLibre.');
              FReleases[I].DownloadURL:='https://master.dl.sourceforge.net/project/djvu/DjVuLibre_Windows/'+Folder+'/'+Match.Groups[1].Value+'?viasf=1';
              FReleases[I].SecondaryURL:='https://master.dl.sourceforge.net/project/djvu/DjVuLibre/'+FReleases[I].ComponentVersion+'/djvulibre-'+FReleases[I].ComponentVersion+'.tar.gz?viasf=1';
              FReleases[I].OfficialComponent:=True; FReleases[I].CheckOnly:=False; GetSize(FReleases[I]);
              Changes:=FetchText('https://sourceforge.net/p/djvu/djvulibre-git/ci/master/tree/NEWS?format=raw');
              Match:=TRegEx.Match(Changes,'(?is)NEW IN VERSION '+FReleases[I].ComponentVersion.Replace('.','\.')+'\s*(.*)');
              if Match.Success then begin FReleases[I].History:=Copy(Match.Value,1,120000); FReleases[I].Changelog:=FReleases[I].History; end;
            end
            else
            begin
              Changes:=FetchText('https://api.github.com/repos/ip7z/7zip/releases/latest');
              if not ParseRasterComponent(Changes,ComponentIDs[I],FReleases[I]) or FReleases[I].CheckOnly then
                raise Exception.Create('Не удалось подтвердить официальный архив и контрольную сумму 7-Zip.');
              AuthorNotes('https://api.github.com/repos/ip7z/7zip/releases?per_page=30',FReleases[I]);
            end;
          end;
        ccDocSharp:
          begin
            DownloadPage:=FetchText('https://api.nuget.org/v3-flatcontainer/docsharp.binary.doc/index.json');
            Changes:=FetchText('https://api.nuget.org/v3-flatcontainer/docsharp.binary.common/index.json');
            if not ParseOfficeDocSharpVersions(DownloadPage,Changes,
              FetchText('https://api.nuget.org/v3-flatcontainer/docsharp.binary.ppt/index.json'),
              FetchText('https://api.nuget.org/v3-flatcontainer/docsharp.binary.xls/index.json'),FReleases[I]) then
              raise Exception.Create('Не удалось проверить согласованную версию всех четырёх библиотек DocSharp.');
            GetSize(FReleases[I]);
            AuthorNotes('https://api.github.com/repos/manfromarce/DocSharp/releases?per_page=30',FReleases[I]);
          end;
      end;
    except
      on E: Exception do
      begin
        FReleases[I].DownloadURL := ''; FReleases[I].SecondaryURL := '';
        FReleases[I].AdditionalURLs := nil; FReleases[I].AdditionalSizes := nil;
        FReleases[I].Size := 0; FReleases[I].SecondarySize := 0;
        FReleases[I].SHA256 := ''; FReleases[I].SourceSHA3 := '';
        FReleases[I].OfficialComponent := False; FReleases[I].ComponentWarning := '';
        FReleases[I].ComponentError := 'Не удалось проверить ' + ComponentIDs[I] +
          '. Повторите проверку или откройте сайт автора. Установленные файлы не изменены.';
        // Transport exceptions can contain server HTML or private proxy paths.
        // Keep bounded diagnostics for an explicit Copy error command only.
        FReleases[I].ComponentErrorDetails := Copy(E.ClassName + ': ' + E.Message,1,4096);
      end;
    end;
    if Terminated then Exit;
  end;
  if Terminated then Exit;
  FSuccessful := True;
  if not Terminated then PostMessage(FWindow, WM_COMPONENT_UPDATE_CHECKED, 0, 0);
end;

end.
