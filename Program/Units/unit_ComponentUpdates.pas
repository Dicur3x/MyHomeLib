unit unit_ComponentUpdates;

interface

uses System.Classes, System.SysUtils, System.Net.HttpClient, Winapi.Windows, Winapi.Messages,
  unit_ProgramUpdates;

type
  TComponentCheckKind = (ccBundled, ccSQLite, ccSumatra, ccRaster, ccDocSharp, ccJPEGXL, ccWebP, ccPublished, ccIBK);
  TUpdateComponent = record
    ID, Title, URL: string;
    CheckKind: TComponentCheckKind;
    CheckOnly: Boolean;
  end;

const
  WM_COMPONENT_UPDATE_CHECKED = WM_APP + $0504;
  WM_COMPONENT_UPDATE_PROGRESS = WM_APP + $0505;
  ALREADER_FIXED_TAG = 'optional-alreader-2.5.1009.25';
  ALREADER_FIXED_NAME = 'AlReader-2.5.1009.25.zip';
  ALREADER_FIXED_SHA256 = '20b3563c3af8e26f7cedb1d20106fe570cb4e169ab121e467b71b3541dfb88ab';
  ALREADER_FIXED_SIZE = 4739366;
  COMPONENT_FEED_NAME = 'HomeLibRu.components.json';
  COMPONENT_MIRROR_API = 'https://api.github.com/repos/Dicur3x/MyHomeLib/releases/tags/' + ALREADER_FIXED_TAG;
  UPDATE_COMPONENTS: array[0..11] of TUpdateComponent = (
    (ID:'SQLite'; Title:'База коллекций'; URL:'https://www.sqlite.org/changes.html'; CheckKind:ccSQLite; CheckOnly:False),
    (ID:'AlReader'; Title:'Внешняя читалка'; URL:'https://github.com/Dicur3x/MyHomeLib/releases/tag/optional-alreader-2.5.1009.25'; CheckKind:ccBundled; CheckOnly:False),
    (ID:'SumatraPDF'; Title:'Внешняя читалка PDF и DjVu'; URL:'https://www.sumatrapdfreader.org/docs/Version-history'; CheckKind:ccSumatra; CheckOnly:False),
    (ID:'DjVuLibre'; Title:'Чтение DjVu'; URL:'https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/'; CheckKind:ccRaster; CheckOnly:False),
    (ID:'7-Zip'; Title:'Распаковка архивов'; URL:'https://www.7-zip.org/download.html'; CheckKind:ccRaster; CheckOnly:False),
    (ID:'DocSharp'; Title:'Чтение DOC, PPT и XLS'; URL:'https://github.com/manfromarce/DocSharp/releases'; CheckKind:ccDocSharp; CheckOnly:False),
    (ID:'JPEG XL'; Title:'Иллюстрации JPEG XL'; URL:'https://github.com/libjxl/libjxl/releases'; CheckKind:ccJPEGXL; CheckOnly:False),
    (ID:'WebP'; Title:'Иллюстрации WebP'; URL:'https://github.com/Dicur3x/MyHomeLib/releases/tag/optional-alreader-2.5.1009.25'; CheckKind:ccWebP; CheckOnly:False),
    (ID:'HomeLibReader'; Title:'HomeLib Reader'; URL:'https://github.com/Dicur3x/MyHomeLib/releases'; CheckKind:ccPublished; CheckOnly:False),
    (ID:'PDFium'; Title:'Чтение PDF'; URL:'https://github.com/bblanchon/pdfium-binaries/releases'; CheckKind:ccPublished; CheckOnly:False),
    (ID:'BookConverter'; Title:'Подготовка и конвертация книг'; URL:'https://github.com/Dicur3x/MyHomeLib/releases'; CheckKind:ccPublished; CheckOnly:False),
    (ID:'IBK'; Title:'Данные чтения IBK'; URL:'https://www.bestfree.ru/soft/office/bookreader-en-downloader.php'; CheckKind:ccIBK; CheckOnly:False));

type
  TComponentReleases = array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of TProgramRelease;
  TComponentUpdateThread = class(TThread)
  private
    FHTTP: THTTPClient;
    FClients: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of THTTPClient;
    FCompleted: array[Low(UPDATE_COMPONENTS)..High(UPDATE_COMPONENTS)] of Integer;
    procedure CheckComponent(I: Integer);
    function StartComponent(I: Integer): TThread;
  private
    FWindow: HWND;
    FSuccessful: Boolean;
    FError, FURL, FCacheFolder: string;
    FReleases: TComponentReleases;
    FLimit: Int64;
    FOnlyIDs: TArray<string>;
    procedure ReceiveData(const Sender: TObject; AContentLength, AReadCount: Int64;
      var AAbort: Boolean);
  protected
    procedure Execute; override;
    function FetchText(const URL: string): string; virtual;
    function FetchHead(const URL: string): IHTTPResponse; virtual;
    function FetchMirrorRelease(const ID, Version: string; out Info: TProgramRelease): Boolean; virtual;
  public
    constructor Create(AWindow: HWND; AHTTP: THTTPClient;
      const URL: string = PROGRAM_RELEASES_API; const CacheFolder: string = '');
    destructor Destroy; override;
    function TryGetRelease(Index: Integer; out Info: TProgramRelease): Boolean;
    property Successful: Boolean read FSuccessful;
    property ErrorText: string read FError;
    property Releases: TComponentReleases read FReleases;
    property OnlyIDs: TArray<string> read FOnlyIDs write FOnlyIDs;
  end;

function IsOptionalComponent(const ID: string): Boolean;
function ComponentNotificationEnabled(const ID, Choices: string): Boolean;
function SetComponentNotification(const ID, Choices: string; Enabled: Boolean): string;
function RequiredReaderComponent(const AppPath, Extension: string): string;
function ComponentPurpose(const ID: string): string;
procedure ConfigureReaderAdapterDownload(var Info: TProgramRelease; const AppPath: string);
type
  EReaderComponentRequired = class(Exception)
  private FComponentID: string;
  public
    constructor Create(const ID: string);
    property ComponentID: string read FComponentID;
  end;

function FixedAlReaderRelease: TProgramRelease;

function ParseComponentFeed(const JSON, ReleaseTag, AssetsJSON: string;
  out Releases: TComponentReleases; RequireAssets: Boolean = True; AllowPartial: Boolean = False): Boolean;
function ComponentDisplayVersion(const ID, Version: string): string;
function ParseDjVuHistory(const News, WindowsFiles: string; var Info: TProgramRelease): Boolean;
function ComponentInstalledVersion(const AppPath, ID: string): string;
function ComponentNewer(const ReleaseInfo: TProgramRelease; const Installed: string): Boolean;
function ComponentArchiveName(const ID, Platform: string): string;
function ComponentVersionedArchiveName(const ID, Version, Platform: string): string;
function ParseIBKMirror(const Metadata, Version: string; out Info: TProgramRelease): Boolean;
function ComponentMirrorFeedURL(const Metadata: string): string;
function ParseComponentMirror(const Metadata, Feed, ID, Version: string; out Info: TProgramRelease): Boolean;
function ComponentChanges(const Info: TProgramRelease; const Installed: string): string;
function ParseSQLiteDownload(const HTML, Changes: string; out Info: TProgramRelease): Boolean;
function ParseSumatraReleases(const JSON: string; out Info: TProgramRelease): Boolean;
function ParseRasterComponent(const Text, ID: string; out Info: TProgramRelease): Boolean;
function ParseImageComponent(const Text, ID: string; out Info: TProgramRelease): Boolean;
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

uses System.JSON, System.RegularExpressions, System.IOUtils, System.StrUtils,
  System.Hash, System.Generics.Collections, System.Generics.Defaults, unit_ProgramUpdateInstaller,
  unit_UpdateNotes, unit_UpdateTextCache, unit_IBKRuntime, unit_ReaderAdapters;

// Each probe owns its HTTP session. Never share WinHTTP handles across workers.
threadvar ComponentProbeHTTP: THTTPClient;

function FixedAlReaderRelease: TProgramRelease;
begin
  Result:=Default(TProgramRelease); Result.ComponentID:='AlReader';
  Result.Tag:=ALREADER_FIXED_TAG; Result.ComponentVersion:='2.5.1009.25';
  Result.URL:='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+ALREADER_FIXED_TAG;
  Result.DownloadURL:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+ALREADER_FIXED_NAME;
  Result.SHA256:=ALREADER_FIXED_SHA256; Result.Size:=ALREADER_FIXED_SIZE;
  Result.History:=ReleaseNotesHeading(Result.ComponentVersion,'')+sLineBreak+
    'Сохранённый Windows-выпуск AlReader. Это прежняя версия, а не новый выпуск автора.'+sLineBreak+
    'Один постоянный архив HomeLib Ru на GitHub, одинаковый для x86 и x64. '+
    'Контрольная сумма зафиксирована в программе. С каждым выпуском HomeLib Ru архив заново не публикуется.'+sLineBreak+
    'AlReader свободен для некоммерческого использования; условия автора сохранены в readme.txt.';
  Result.Changelog:=Result.History;
end;

function IsOptionalComponent(const ID: string): Boolean;
begin Result:=(ID='AlReader') or (ID='SumatraPDF') or (ID='DjVuLibre') or (ID='DocSharp') or (ID='7-Zip') or (ID='JPEG XL') or (ID='WebP') or (ID='HomeLibReader') or (ID='PDFium') or (ID='BookConverter') or (ID='IBK'); end;

function ComponentNotificationEnabled(const ID, Choices: string): Boolean;
begin Result:=not IsOptionalComponent(ID) or (IndexText(ID,Choices.Split([',']))>=0); end;

function SetComponentNotification(const ID, Choices: string; Enabled: Boolean): string;
var Selected: TStringList;
begin
  Result:=Choices; if not IsOptionalComponent(ID) then Exit;
  Selected:=TStringList.Create;
  try
    Selected.StrictDelimiter:=True; Selected.Delimiter:=','; Selected.DelimitedText:=Choices;
    for var I:=Selected.Count-1 downto 0 do if SameText(Selected[I],ID) then Selected.Delete(I);
    if Enabled then Selected.Add(ID);
    Result:=Selected.DelimitedText;
  finally Selected.Free; end;
end;

procedure ConfigureReaderAdapterDownload(var Info: TProgramRelease; const AppPath: string);
var Package: TReaderAdapterPackage;
begin
  if (Info.ReaderAdapterSize<0) or (Info.ReaderAdapterSize>Info.Size) then
    raise EArgumentException.Create('Некорректный размер вспомогательного модуля.');
  Dec(Info.Size,Info.ReaderAdapterSize); Info.ReaderAdapterSize:=0;
  if (Info.DownloadURL<>'') and not Info.CheckOnly and (Info.Size>0) and
    ReaderAdapterPackage(Info.ComponentID,Package) and ReaderAdapterRequired(AppPath,Info.ComponentID) then
  begin Info.ReaderAdapterSize:=Package.Size; Inc(Info.Size,Package.Size); end;
end;

function RequiredReaderComponent(const AppPath, Extension: string): string;
var Ext: string;
begin
  Result:=''; Ext:='.'+LowerCase(Extension.TrimLeft(['.']));
  if (Pos('|'+Ext+'|','|.chm|.cbr|.cb7|')>0) and ComponentNeedsRepair(AppPath,'7-Zip') then Exit('7-Zip');
  if (Ext='.pdf') and ComponentNeedsRepair(AppPath,'PDFium') then Exit('PDFium');
  if (Ext='.webp') and ComponentNeedsRepair(AppPath,'WebP') then Exit('WebP');
  if ((Ext='.djvu') or (Ext='.djv')) and ComponentNeedsRepair(AppPath,'DjVuLibre') then Exit('DjVuLibre');
  if (Pos('|'+Ext+'|','|.doc|.dot|.ppt|.pps|.pot|.xls|.xlt|')>0) and
    ComponentNeedsRepair(AppPath,'DocSharp') then Result:='DocSharp';
end;

constructor EReaderComponentRequired.Create(const ID: string);
begin inherited Create('Для чтения этой книги нужен компонент '+ID+'. '+ComponentPurpose(ID)); FComponentID:=ID; end;

function ComponentPurpose(const ID: string): string;
begin
  if ID='PDFium' then Exit('PDFium — модуль чтения страниц PDF, в том числе для преобразования в FB2/EPUB.');
  if ID='DocSharp' then Exit('DocSharp — модуль чтения DOC, PPT и XLS, в том числе для преобразования в FB2/EPUB.');
  if ID='DjVuLibre' then Exit('DjVuLibre — модуль чтения страниц DjVu, в том числе для преобразования в FB2/EPUB.');
  if ID='BookConverter' then Exit('Конвертер HomeLib Ru (BookConverter) — общий модуль создания FB2/EPUB и обработки изображений.');
  if ID='JPEG XL' then Exit('JPEG XL (libjxl) — восстановление иллюстраций JPEG XL для чтения и сохранения книги.');
  if ID='WebP' then Exit('WebP (libwebp) — чтение иллюстраций WebP для показа и сохранения книги.');
  if ID='7-Zip' then Exit('7-Zip — распаковка книг и вспомогательных компонентов из архивов.');
  if ID='IBK' then Exit('Данные ICE Book Reader — чтение книг IBK во встроенной читалке и конвертере.');
  Result:='';
end;

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
    if URL='https://github.com/Dicur3x/MyHomeLib/releases' then Exit('Выпуски HomeLib Ru');
    if URL='https://www.bestfree.ru/soft/office/bookreader-en-downloader.php' then
      Exit('Источник исходного пакета ICE Reader');
    if URL='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+ALREADER_FIXED_TAG then
      Exit('Постоянные компоненты HomeLib Ru');
    for Info in UPDATE_COMPONENTS do
      if URL = Info.URL then Exit('Сайт автора: ' + Info.ID);
    Exit('Выпуски HomeLib Ru');
  end;
  if Component='AlReader' then Exit('Постоянный архив AlReader');
  if Component='WebP' then Exit('Постоянный архив WebP');
  if Component='HomeLibReader' then Exit('Выпуски HomeLib Reader');
  if Component='BookConverter' then Exit('Выпуски модуля конвертации');
  if URL='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+ALREADER_FIXED_TAG then
    Exit('Компоненты на GitHub');
  if Component='IBK' then Exit('Источник исходного пакета ICE Reader');
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
    if Text.Trim <> '' then
    begin
      Releases[I].History := Copy(Text, 1, 324000);
      if (ComponentIDs[I]='DjVuLibre') and Text.Contains('NEW IN VERSION ') then
        ParseDjVuHistory(Text,'',Releases[I]);
    end;
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
      Assets:=nil;
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
      // A portable installation may have no extractor yet. The author's small
      // standalone decoder extracts the installer without running the installer.
      if Assigned(Assets) then
        for Asset in Assets do
          if (Asset is TJSONObject) and Asset.TryGetValue<string>('name',Notes) and (Notes='7zr.exe') and
            Asset.TryGetValue<string>('browser_download_url',URL) and
            (URL='https://github.com/ip7z/7zip/releases/download/'+Tag+'/7zr.exe') and
            Asset.TryGetValue<string>('digest',Digest) and Digest.StartsWith('sha256:') and
            IsUpdateSHA256(Copy(Digest,8,MaxInt)) and Asset.TryGetValue<Int64>('size',Info.SecondarySize) and
            (Info.SecondarySize>0) and (Info.SecondarySize<=4*1024*1024) then
          begin Info.SecondaryURL:=URL; Info.SecondarySHA256:=Copy(Digest,8,MaxInt); Break; end;
      if Info.SecondaryURL<>'' then Inc(Info.Size,Info.SecondarySize);
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

function ParseImageComponent(const Text, ID: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Assets: TJSONArray; Asset: TJSONValue;
  Tag, Name, Expected, URL, Digest, Version, Suffix, Prefix: string;
  Size: Int64; Comparison: Integer; Flag: Boolean; Match: TMatch;
begin
  Result:=False; Info:=Default(TProgramRelease); Info.ComponentID:=ID;
  if (ID<>'JPEG XL') and (ID<>'WebP') then Exit;
  Root:=TJSONObject.ParseJSONValue(Text);
  try
    if not (Root is TJSONObject) or not Root.TryGetValue<string>('tag_name',Tag) or
      not Root.TryGetValue<TJSONArray>('assets',Assets) then Exit;
    Flag:=False; Root.TryGetValue<Boolean>('draft',Flag); if Flag then Exit;
    Flag:=False; Root.TryGetValue<Boolean>('prerelease',Flag); if Flag then Exit;
    if ID='JPEG XL' then
    begin
      if not TRegEx.IsMatch(Tag,'\Av[0-9]+\.[0-9]+\.[0-9]+\z') then Exit;
      Version:=Copy(Tag,2,MaxInt);
      if ProgramUpdatePlatform='Win64' then Suffix:='x64' else Suffix:='x86';
      Expected:='jxl-'+Suffix+'-windows-static.zip';
      Prefix:='https://github.com/libjxl/libjxl/releases/download/'+Tag+'/';
    end
    else
    begin
      if Tag<>ALREADER_FIXED_TAG then Exit;
      Expected:=''; Prefix:='https://github.com/Dicur3x/MyHomeLib/releases/download/'+Tag+'/';
    end;
    for Asset in Assets do
    begin
      if not (Asset is TJSONObject) or not Asset.TryGetValue<string>('name',Name) then Continue;
      if ID='JPEG XL' then begin if Name<>Expected then Continue; end
      else
      begin
        Match:=TRegEx.Match(Name,'\AWebP-([0-9]+\.[0-9]+\.[0-9]+)-'+ProgramUpdatePlatform+'\.zip\z');
        if not Match.Success then Continue;
        Version:=Match.Groups[1].Value;
        if (Info.ComponentVersion<>'') and
          (not CompareComponentVersions(Version,Info.ComponentVersion,Comparison) or (Comparison<=0)) then Continue;
      end;
      if not CompareComponentVersions(Version,Version,Comparison) or
        not Asset.TryGetValue<string>('browser_download_url',URL) or (URL<>Prefix+Name) or
        not Asset.TryGetValue<string>('digest',Digest) or not Digest.StartsWith('sha256:') or
        not IsUpdateSHA256(Copy(Digest,8,MaxInt)) or not Asset.TryGetValue<Int64>('size',Size) or
        (Size<=0) or (Size>UPDATE_MAX_ARCHIVE) then Continue;
      Info.ComponentVersion:=Version; Info.Tag:=Tag; Info.DownloadURL:=URL;
      Info.SHA256:=Copy(Digest,8,MaxInt); Info.Size:=Size;
    end;
    if Info.DownloadURL='' then Exit;
    if ID='JPEG XL' then
    begin
      Info.OfficialComponent:=True; Info.URL:='https://github.com/libjxl/libjxl/releases';
      Root.TryGetValue<string>('body',Info.History);
      Info.History:='Готовый декодер djxl из официального Windows-пакета libjxl. '+
        'Скачивается только при необходимости в изображениях JPEG XL.'+sLineBreak+Copy(Info.History,1,12000);
    end
    else
    begin
      Info.URL:='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+ALREADER_FIXED_TAG;
      Info.History:='Готовая сборка HomeLib Ru из официальных исходников libwebp '+Info.ComponentVersion+'. '+
        'Пользователю компилятор не требуется. Исходники и порядок сборки указаны в отдельном выпуске компонентов.'+sLineBreak+
        'Обновляется независимо от HomeLib Ru; один архив для каждой разрядности, без повторной публикации с программой.';
    end;
    Info.Changelog:=Info.History; Result:=True;
  finally Root.Free; end;
end;

function ComponentArchiveName(const ID, Platform: string): string;
begin
  Result := 'HomeLibRu-' + ID + '-' + Platform + '.zip';
end;

function ComponentVersionedArchiveName(const ID, Version, Platform: string): string;
begin
  Result := 'HomeLibRu-' + ID.Replace(' ', '') + '-' + Version + '-' + Platform + '.zip';
end;

function ComponentDisplayVersion(const ID, Version: string): string;
var Parts: TArray<string>; Count, Minimum, Major, Minor, Comparison: Integer;
begin
  Result:=Version;
  // Presentation only; validation and comparisons retain the fixed-file version.
  if not CompareComponentVersions(Version,Version,Comparison) then Exit;
  Parts:=Version.Split(['.']); Count:=Length(Parts);
  if ID='7-Zip' then
  begin
    for var I:=2 to Count-1 do if StrToInt(Parts[I])<>0 then Exit;
    Major:=StrToInt(Parts[0]); Minor:=StrToInt(Parts[1]);
    if Minor<=99 then Result:=Format('%d.%.2d',[Major,Minor]);
    Exit;
  end;
  if ID='SumatraPDF' then Minimum:=2
  else if (ID='SQLite') or (ID='DocSharp') or (ID='DjVuLibre') then Minimum:=3
  else Exit;
  while (Count>Minimum) and (StrToInt(Parts[Count-1])=0) do Dec(Count);
  if Count=Length(Parts) then Exit;
  Result:=Parts[0];
  for var I:=1 to Count-1 do Result:=Result+'.'+Parts[I];
end;

function ParseDjVuHistory(const News, WindowsFiles: string; var Info: TProgramRelease): Boolean;
var Dates, Seen: TDictionary<string,string>; History: TJSONArray; Entry: TJSONObject;
  Row, Link, Stamp, Section: TMatch; Version, Date, Body, Text, Published: string;
  Comparison, Year, Month, Day: Integer; ValidDate: TDateTime;
begin
  Result:=False;
  if (Info.ComponentID<>'DjVuLibre') or
    not CompareComponentVersions(Info.ComponentVersion,Info.ComponentVersion,Comparison) then Exit;
  Dates:=TDictionary<string,string>.Create; Seen:=TDictionary<string,string>.Create;
  History:=TJSONArray.Create;
  try
    // NEWS has no dates. Label SourceForge's Windows-package dates explicitly,
    // rather than substituting the source-code or DjView release date.
    for Row in TRegEx.Matches(WindowsFiles,'(?is)<tr\b[^>]*>.*?</tr>') do
    begin
      Link:=TRegEx.Match(Row.Value,'/projects/djvu/files/DjVuLibre_Windows/(3\.5\.[0-9]+)(?:\+|%2[bB])[0-9.]+/');
      Stamp:=TRegEx.Match(Row.Value,'(?is)headers="files_date_h"[^>]*>\s*<abbr\b[^>]*title="([0-9]{4})-([0-9]{2})-([0-9]{2})[^"]*"');
      if not Link.Success or not Stamp.Success then Continue;
      if not TryStrToInt(Stamp.Groups[1].Value,Year) or
        not TryStrToInt(Stamp.Groups[2].Value,Month) or not TryStrToInt(Stamp.Groups[3].Value,Day) or
        not TryEncodeDate(Year,Month,Day,ValidDate) then Continue;
      Date:=FormatDateTime('yyyy-mm-dd',ValidDate); Version:=Link.Groups[1].Value;
      if not Dates.ContainsKey(Version) or (Dates[Version]<Date) then Dates.AddOrSetValue(Version,Date);
    end;
    Text:=''; Published:=Info.PublishedAt;
    for Section in TRegEx.Matches(News,'(?ms)^NEW IN VERSION ([0-9]+\.[0-9]+\.[0-9]+)[ \t]*\r?\n[-=]+[ \t]*\r?\n(.*?)(?=^NEW IN VERSION |\z)') do
    begin
      Version:=Section.Groups[1].Value;
      if not CompareComponentVersions(Version,Info.ComponentVersion,Comparison) or
        (Comparison>0) or Seen.ContainsKey(Version) then Continue;
      Seen.Add(Version,''); Body:=Section.Groups[2].Value.Trim;
      if Body='' then Continue;
      Date:=''; Dates.TryGetValue(Version,Date);
      if Date<>'' then Body:='Дата Windows-пакета в каталоге SourceForge: '+
        Copy(Date,9,2)+'.'+Copy(Date,6,2)+'.'+Copy(Date,1,4)+'.'+sLineBreak+sLineBreak+Body
      else Body:='Дата Windows-пакета не опубликована в каталоге SourceForge.'+sLineBreak+sLineBreak+Body;
      if Comparison=0 then Published:=Date;
      Entry:=TJSONObject.Create; Entry.AddPair('version',Version); Entry.AddPair('date',Date); Entry.AddPair('notes',Body);
      History.AddElement(Entry);
      Text:=Text+ReleaseNotesHeading('DjVuLibre '+Version,Date)+sLineBreak+Body+sLineBreak+sLineBreak;
      if (History.Count>=100) or (Length(Text)>120000) then Break;
    end;
    if History.Count=0 then Exit;
    Info.Notes:=History.ToJSON; Info.History:=Text.Trim; Info.Changelog:=Info.History;
    Info.PublishedAt:=Published; Result:=True;
  finally History.Free; Seen.Free; Dates.Free; end;
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
  out Releases: TComponentReleases; RequireAssets, AllowPartial: Boolean): Boolean;
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
      if Obj.TryGetValue<string>('archive', Digest) then
      begin
        if Digest <> ComponentVersionedArchiveName(ID,Version,Platform) then Exit;
        Name := Digest;
      end;
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
    if AllowPartial then for var Present in Found do Result:=Result or Present;
  finally Root.Free; AssetsRoot.Free; end;
end;

constructor TComponentUpdateThread.Create(AWindow: HWND; AHTTP: THTTPClient; const URL, CacheFolder: string);
begin
  inherited Create(True); FreeOnTerminate := False; FHTTP := AHTTP; FWindow := AWindow; FURL := URL;
  FCacheFolder := CacheFolder;
  FHTTP.UserAgent := 'HomeLib Ru'; FHTTP.ConnectionTimeout := 4000; FHTTP.ResponseTimeout := 6000;
  FHTTP.OnReceiveData := ReceiveData; FLimit := 8 * 1024 * 1024;
  for var I:=Low(FClients) to High(FClients) do
  begin
    FClients[I]:=THTTPClient.Create;
    FClients[I].ProxySettings:=FHTTP.ProxySettings;
    FClients[I].HandleRedirects:=FHTTP.HandleRedirects;
    FClients[I].UserAgent:=FHTTP.UserAgent;
    FClients[I].ConnectionTimeout:=FHTTP.ConnectionTimeout;
    FClients[I].ResponseTimeout:=FHTTP.ResponseTimeout;
    FClients[I].OnReceiveData:=ReceiveData;
  end;
end;

destructor TComponentUpdateThread.Destroy;
begin
  inherited;
  for var Client in FClients do Client.Free;
  FHTTP.Free;
end;

procedure TComponentUpdateThread.ReceiveData(const Sender: TObject;
  AContentLength, AReadCount: Int64; var AAbort: Boolean);
begin AAbort := Terminated or (AContentLength > FLimit) or (AReadCount > FLimit); end;

function TComponentUpdateThread.FetchText(const URL: string): string;
begin
  if Terminated then Abort;
  if Assigned(ComponentProbeHTTP) then
    Result:=CachedUpdateText(ComponentProbeHTTP,URL,FCacheFolder,FLimit)
  else Result:=CachedUpdateText(FHTTP,URL,FCacheFolder,FLimit);
  if Terminated then Abort;
end;

function TComponentUpdateThread.FetchHead(const URL: string): IHTTPResponse;
begin
  if Terminated then Abort;
  if Assigned(ComponentProbeHTTP) then Result:=ComponentProbeHTTP.Head(URL)
  else Result:=FHTTP.Head(URL);
end;

function TComponentUpdateThread.FetchMirrorRelease(const ID, Version: string; out Info: TProgramRelease): Boolean;
var Metadata, URL: string;
begin
  Result:=False; Info:=Default(TProgramRelease);
  if Terminated then Abort;
  Metadata:=FetchText(COMPONENT_MIRROR_API);
  if ID='IBK' then Exit(ParseIBKMirror(Metadata,Version,Info));
  URL:=ComponentMirrorFeedURL(Metadata);
  if URL<>'' then Result:=ParseComponentMirror(Metadata,FetchText(URL),ID,Version,Info);
end;

procedure TComponentUpdateThread.CheckComponent(I: Integer);
var DownloadPage, Changes, Folder, WindowsFiles: string; Response: IHTTPResponse; Match: TMatch; NotesInfo: TProgramRelease;
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
    try
      if ParseSumatraReleases(FetchText(API),NotesInfo) then
      begin Info.History:=NotesInfo.History; Info.Notes:=NotesInfo.Notes; Info.Changelog:=NotesInfo.Changelog; end;
    except on E: EAbort do raise; on E: Exception do ; end;
  end;
begin
  FReleases[I].ComponentID:=UPDATE_COMPONENTS[I].ID;
  if Terminated then Exit;
    try
      case UPDATE_COMPONENTS[I].CheckKind of
        ccIBK:
          begin
            FReleases[I].DownloadURL:=IBKPackageURL(FetchText(IBK_PACKAGE_PAGE+'?homelib='+IntToStr(GetTickCount64)));
            if FReleases[I].DownloadURL='' then
              raise Exception.Create('Не удалось найти проверенный исходный пакет IBK.');
            FReleases[I].ComponentVersion:=IBK_VERSION; FReleases[I].Tag:=IBK_VERSION;
            FReleases[I].URL:=IBK_PACKAGE_PAGE; FReleases[I].OfficialComponent:=True;
            FReleases[I].SHA256:=IBK_PACKAGE_SHA256;
            FReleases[I].SecondaryURL:=IBK_EXTRACTOR_URL;
            FReleases[I].SecondarySHA256:=IBK_EXTRACTOR_SHA256;
            FReleases[I].SecondarySize:=IBK_EXTRACTOR_SIZE;
            FReleases[I].Size:=IBK_PACKAGE_SIZE+IBK_EXTRACTOR_SIZE;
            FReleases[I].History:='Данные чтения обычных книг IBK из исходного пакета ICE Book Reader Russian 9.6.5.'+sLineBreak+
              'Исходный пакет скачивается с BestFree и проверяется по зафиксированной контрольной сумме. Установщик ICE не запускается.'+sLineBreak+
              'По условиям автора Russian Edition предназначена для граждан стран бывшего СССР и некоммерческого использования. '+
              'Исходный дистрибутив и полный License.txt сохраняются в tools/ibk.'+sLineBreak+
              'Для распаковки однократно скачивается innoextract 1.9 с сайта его автора; после подготовки он удаляется вместе с временными файлами обновления.';
            FReleases[I].Changelog:=FReleases[I].History;
          end;
        ccJPEGXL, ccWebP:
          begin
            if UPDATE_COMPONENTS[I].CheckKind=ccJPEGXL then
              Changes:=FetchText('https://api.github.com/repos/libjxl/libjxl/releases/latest')
            else Changes:=FetchText('https://api.github.com/repos/Dicur3x/MyHomeLib/releases/tags/'+ALREADER_FIXED_TAG);
            if not ParseImageComponent(Changes,ComponentIDs[I],FReleases[I]) then
              raise Exception.Create('Не удалось подтвердить пакет изображений, разрядность или контрольную сумму.');
          end;
        ccPublished:
          begin
            // HomeLib modules have a permanent component feed. Retain the
            // earlier per-release discovery path for existing distributions.
            var Permanent: TProgramRelease;
            var HasPermanent:=False;
            try HasPermanent:=FetchMirrorRelease(ComponentIDs[I],'',Permanent);
            except on E: EAbort do raise; on E: Exception do HasPermanent:=False; end;
            if HasPermanent then
            begin
              Permanent.ComponentWarning:=''; FReleases[I]:=Permanent;
            end
            else
            begin
            var ReleaseRoot:=TJSONObject.ParseJSONValue(FetchText(FURL));
            try
              if not (ReleaseRoot is TJSONArray) then raise Exception.Create('Некорректный список выпусков.');
              var Found:=False;
              for var Entry in TJSONArray(ReleaseRoot) do
              begin
                if not (Entry is TJSONObject) then Continue;
                var Draft:=True; var Tag: string; var Assets: TJSONArray;
                if not Entry.TryGetValue<Boolean>('draft',Draft) or Draft or
                  not Entry.TryGetValue<string>('tag_name',Tag) or
                  not Entry.TryGetValue<TJSONArray>('assets',Assets) then Continue;
                if not TRegEx.IsMatch(Tag,'^[A-Za-z0-9._-]{1,80}$') then Continue;
                // Old application/component releases usually have no archive
                // for this module. Do not fetch each unrelated feed in turn.
                var HasPackage:=False;
                for var Asset in Assets do
                  if (Asset is TJSONObject) and
                    (Asset.GetValue<string>('name','')=ComponentArchiveName(UPDATE_COMPONENTS[I].ID,ProgramUpdatePlatform)) then
                  begin HasPackage:=True; Break; end;
                if not HasPackage then Continue;
                for var Asset in Assets do
                begin
                  var Name, URL: string; var Size: Int64;
                  if not (Asset is TJSONObject) or not Asset.TryGetValue<string>('name',Name) or
                    (Name<>COMPONENT_FEED_NAME) or not Asset.TryGetValue<string>('browser_download_url',URL) or
                    (URL<>'https://github.com/Dicur3x/MyHomeLib/releases/download/'+Tag+'/'+COMPONENT_FEED_NAME) or
                    not Asset.TryGetValue<Int64>('size',Size) or (Size<1) or (Size>1024*1024) then Continue;
                  var Published: TComponentReleases;
                  if ParseComponentFeed(FetchText(URL),Tag,Assets.ToJSON,Published,True,True) and
                    (Published[I].DownloadURL<>'') then
                  begin FReleases[I]:=Published[I]; Found:=True; Break; end;
                end;
                if Found then Break;
                if Terminated then Abort;
              end;
              if not Found then raise Exception.Create('Пакет этого компонента ещё не опубликован.');
            finally ReleaseRoot.Free; end;
            end;
          end;
        ccBundled:
          // Version and bytes are fixed, not guessed from the unavailable site.
          // Availability is checked by the actual bounded download on user request.
          FReleases[I]:=FixedAlReaderRelease;
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
              WindowsFiles:=Changes;
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
              ParseDjVuHistory(Changes,WindowsFiles,FReleases[I]);
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
        var Mirror: TProgramRelease;
        var Available:=False;
        if not Terminated then
          try Available:=FetchMirrorRelease(ComponentIDs[I],FReleases[I].ComponentVersion,Mirror);
          except on E: Exception do Available:=False; end;
        if Available then
        begin
          FReleases[I]:=Mirror;
          FReleases[I].ComponentWarning:='Сайт автора недоступен. Доступна запасная копия HomeLib Ru на GitHub, версия '+Mirror.ComponentVersion+'.';
        end
        else
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
    end;
  if Terminated then Exit;
  ConfigureReaderAdapterDownload(FReleases[I],ExtractFilePath(ParamStr(0)));
  // Publish only immutable, complete slots; Interlocked supplies the memory barrier.
  InterlockedExchange(FCompleted[I],1);
  PostMessage(FWindow,WM_COMPONENT_UPDATE_PROGRESS,WPARAM(Self),I);
end;

function TComponentUpdateThread.TryGetRelease(Index: Integer; out Info: TProgramRelease): Boolean;
begin
  Result:=(Index>=Low(FCompleted)) and (Index<=High(FCompleted));
  if Result then Result:=InterlockedCompareExchange(FCompleted[Index],1,1)=1;
  if Result then Info:=FReleases[Index];
end;

function TComponentUpdateThread.StartComponent(I: Integer): TThread;
begin
  Result:=TThread.CreateAnonymousThread(
    procedure
    begin
      ComponentProbeHTTP:=FClients[I];
      try CheckComponent(I); finally ComponentProbeHTTP:=nil; end;
    end);
  Result.FreeOnTerminate:=False;
  Result.Start;
end;

procedure TComponentUpdateThread.Execute;
var Workers: TArray<TThread>; I: Integer;
begin
  SetLength(Workers,Length(UPDATE_COMPONENTS));
  try
    try
      for I in CheckedComponentIndices do
        if not Terminated and ((Length(FOnlyIDs)=0) or
          (IndexText(UPDATE_COMPONENTS[I].ID,FOnlyIDs)>=0)) then
          Workers[I]:=StartComponent(I);
    finally
      for var Worker in Workers do
        if Assigned(Worker) then begin Worker.WaitFor; Worker.Free; end;
    end;
    if not Terminated then
      for I in CheckedComponentIndices do
        if ((Length(FOnlyIDs)=0) or (IndexText(UPDATE_COMPONENTS[I].ID,FOnlyIDs)>=0)) and
          (InterlockedCompareExchange(FCompleted[I],1,1)<>1) then
          raise Exception.Create('Проверка '+UPDATE_COMPONENTS[I].ID+' не завершилась.');
    FSuccessful:=not Terminated;
  except
    on E: Exception do FError:=Copy(E.ClassName+': '+E.Message,1,4096);
  end;
  if not Terminated then PostMessage(FWindow,WM_COMPONENT_UPDATE_CHECKED,WPARAM(Self),0);
end;

function ParseIBKMirror(const Metadata, Version: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Assets: TJSONArray; Draft, Main, Extractor: Boolean; Size: Int64;
  Name, URL, Digest: string;
begin
  Result:=False; Info:=Default(TProgramRelease); Root:=nil; Main:=False; Extractor:=False;
  if (Length(Metadata)>1024*1024) or ((Version<>'') and (Version<>IBK_VERSION)) then Exit;
  try
    Root:=TJSONObject.ParseJSONValue(Metadata);
    if not (Root is TJSONObject) or not Root.TryGetValue<Boolean>('draft',Draft) or Draft or
      (Root.GetValue<string>('tag_name','')<>ALREADER_FIXED_TAG) or
      not Root.TryGetValue<TJSONArray>('assets',Assets) or (Assets.Count>256) then Exit;
    for var Asset in Assets do
    begin
      if not (Asset is TJSONObject) or not Asset.TryGetValue<string>('name',Name) or
        not Asset.TryGetValue<string>('browser_download_url',URL) or (URL<>IBK_MIRROR_PREFIX+Name) or
        not Asset.TryGetValue<string>('digest',Digest) or not Asset.TryGetValue<Int64>('size',Size) then Continue;
      if (Name=IBK_MIRROR_NAME) and (Size=IBK_PACKAGE_SIZE) and
        SameText(Digest,'sha256:'+IBK_PACKAGE_SHA256) then Main:=True;
      if (Name=IBK_EXTRACTOR_MIRROR_NAME) and (Size=IBK_EXTRACTOR_SIZE) and
        SameText(Digest,'sha256:'+IBK_EXTRACTOR_SHA256) then Extractor:=True;
    end;
    if not Main or not Extractor then Exit;
    Info.ComponentID:='IBK'; Info.ComponentVersion:=IBK_VERSION; Info.Tag:=IBK_VERSION;
    Info.URL:='https://github.com/Dicur3x/MyHomeLib/releases/tag/'+ALREADER_FIXED_TAG;
    Info.DownloadURL:=IBK_MIRROR_PREFIX+IBK_MIRROR_NAME; Info.SHA256:=IBK_PACKAGE_SHA256;
    Info.SecondaryURL:=IBK_MIRROR_PREFIX+IBK_EXTRACTOR_MIRROR_NAME;
    Info.SecondarySHA256:=IBK_EXTRACTOR_SHA256; Info.SecondarySize:=IBK_EXTRACTOR_SIZE;
    Info.Size:=IBK_PACKAGE_SIZE+IBK_EXTRACTOR_SIZE; Info.OfficialComponent:=True;
    Info.ComponentWarning:='Запасная копия исходного пакета IBK 9.6.5. Дистрибутив автора сохранён без изменений.';
    Info.History:='Данные для чтения IBK в HomeLib Reader. ICE Book Reader не устанавливается и не запускается.'+sLineBreak+
      'Загружается полный неизменённый дистрибутив; данные извлекаются локально. Контрольные суммы обоих оригинальных архивов зафиксированы в программе.'+sLineBreak+
      'Условия ICE Graphics для Russian Edition: граждане стран бывшего СССР, некоммерческое использование. Полный License.txt сохраняется вместе с оригиналом.';
    Info.Changelog:=Info.History; Result:=True;
  finally Root.Free; end;
end;

function ComponentMirrorFeedURL(const Metadata: string): string;
var Root: TJSONValue; Assets: TJSONArray; Draft: Boolean; Name, URL: string; Size: Int64;
begin
  Result := ''; Root := nil;
  if Length(Metadata)>1024*1024 then Exit;
  try
    Root:=TJSONObject.ParseJSONValue(Metadata);
    if not (Root is TJSONObject) or
      not Root.TryGetValue<Boolean>('draft',Draft) or Draft or
      (Root.GetValue<string>('tag_name','')<>ALREADER_FIXED_TAG) or
      not Root.TryGetValue<TJSONArray>('assets',Assets) or (Assets.Count>256) then Exit;
    for var Asset in Assets do
      if (Asset is TJSONObject) and Asset.TryGetValue<string>('name',Name) and
        (Name=COMPONENT_FEED_NAME) and Asset.TryGetValue<Int64>('size',Size) and
        (Size>0) and (Size<=1024*1024) and Asset.TryGetValue<string>('browser_download_url',URL) and
        (URL='https://github.com/Dicur3x/MyHomeLib/releases/download/'+ALREADER_FIXED_TAG+'/'+COMPONENT_FEED_NAME) then
        Exit(URL);
  finally Root.Free; end;
end;

function ParseComponentMirror(const Metadata, Feed, ID, Version: string; out Info: TProgramRelease): Boolean;
var Root: TJSONValue; Assets: TJSONArray; Published: TComponentReleases; Comparison, Index: Integer;
begin
  Result:=False; Info:=Default(TProgramRelease); Root:=nil;
  if (Length(Feed)>1024*1024) or (ComponentMirrorFeedURL(Metadata)='') then Exit;
  try
    Root:=TJSONObject.ParseJSONValue(Metadata);
    if not Root.TryGetValue<TJSONArray>('assets',Assets) or
      not ParseComponentFeed(Feed,ALREADER_FIXED_TAG,Assets.ToJSON,Published,True,True) then Exit;
    Index:=IndexText(ID,ComponentIDs);
    if (Index<0) or (Published[Index].DownloadURL='') or
      ((Version<>'') and (not CompareComponentVersions(Version,Published[Index].ComponentVersion,Comparison) or
        (Comparison<>0))) then Exit;
    Info:=Published[Index];
    Info.ComponentWarning:='Используется запасной пакет HomeLib Ru на GitHub. Версия: '+Info.ComponentVersion+'.';
    Result:=True;
  finally Root.Free; end;
end;

end.
