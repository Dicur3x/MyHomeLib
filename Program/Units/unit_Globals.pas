(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  *                     Nick Rymanov (nrymanov@gmail.com)
  * Created             12.02.2010
  * Description
  *
  * $Id: unit_Globals.pas 1166 2014-05-22 03:09:17Z koreec $
  *
  * History
  * NickR 15.02.2010    Код переформатирован
  *
  ****************************************************************************** *)

unit unit_Globals;

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,
  VirtualTrees,
  VirtualTrees.Types,
  unit_Consts,
  Dialogs;

type
  TTeletypeSeverity = (tsInfo, tsWarning, tsError);

  COLLECTION_TYPE = Integer;
  TPropertyID = Integer;

  TTXTEncoding = (enUTF8, en1251, enUnicode, enUnknown);

  TTreeMode = (tmTree, tmFlat);

  TGenresType = (gtFb2, gtAny);

  TBookIteratorMode = (
    bmAll,       // All books
    bmByGenre,   // Books by genre
    bmByAuthor,  // Books by author
    bmBySeries,  // Books by series
    bmSearch     // Book search
  );

  TAuthorIteratorMode = (
    amAll,       // All authors
    amByBook,    // Authors by book id
    amFullFilter // Full filter - both Alpha, Local and Deleted
  );

  TGenreIteratorMode = (
    gmAll,       // All genres
    gmByBook     // Genres by book id
  );

  TSeriesIteratorMode = (
    smAll,       // All series
    smFullFilter // Full filter - both Alpha, Local and Deleted
  );

  TBookFormat = (
    bfFb2,        // A pure FB2 file
    bfFb2Archive, // An FB2 packed in ZIP or 7z (or another supported archive)
    bfFbd,        // An (FBD + a raw book file) packed together in a zip
    bfRaw,         // A raw file = any other book format
    bfRawArchive
  );

  PBookKey = ^TBookKey;
  TBookKey = record
    BookID: Integer;
    DatabaseID: Integer;

    procedure Clear; inline;
    function IsSameAs(const other: TBookKey): Boolean; inline;
  end;

  TBookIdStruct = record
    BookKey: TBookKey;
    Res: Boolean;
  end;

  TBookIdList = array of TBookIdStruct;

  TExportMode = (emFB2, emFB2Zip, emLrf, emTxt, emEpub, emPDF, emMobi);

  //
  // TreeView data records
  //
  // --------------------------------------------------------------------------
  PAuthorData = ^TAuthorData;
  TAuthorData = record
    AuthorID: Integer;
    FFirstName: string;
    FMiddleName: string;
    FLastName: string;

    procedure SetFirstName(const Value: string); inline;
    procedure SetLastName(const Value: string); inline;
    procedure SetMiddleName(const Value: string); inline;

    function GetFullName(onlyInitials: Boolean = False): string; inline;

    property FirstName: string read FFirstName write SetFirstName;
    property MiddleName: string read FMiddleName write SetMiddleName;
    property LastName: string read FLastName write SetLastName;

    procedure Clear;

    class function FormatName(const LastName: string; const FirstName: string; const MiddleName: string; const nickName: string = ''; onlyInitials: Boolean = False): string; static;
  end;
  TBookAuthors = array of TAuthorData;

  TAuthorsHelper = class
  public
    class procedure Add(
      var Authors: TBookAuthors;
      const LastName: string;
      const FirstName: string;
      const MiddleName: string;
      AuthorID: Integer = 0
    );

    class function GetList(const Authors: TBookAuthors): string;
    class function GetLinkList(const Authors: TBookAuthors): string;
  end;

  // --------------------------------------------------------------------------
  PSeriesData = ^TSeriesData;
  TSeriesData = record
    SeriesID: Integer;
    SeriesTitle: string;
  end;

  TBookSeriesData = record
    SeriesID: Integer;
    SeriesTitle: string;
    SeqNumber: Integer;
    IsPrimary: Boolean;
  end;
  TBookSeries = array of TBookSeriesData;

  TSeriesHelper = class
  public
    class procedure Add(
      var Series: TBookSeries;
      const SeriesID: Integer;
      const SeriesTitle: string;
      const SeqNumber: Integer;
      const IsPrimary: Boolean
    );
    class function GetLink(const SeriesID: Integer; const SeriesTitle: string): string;
    class function GetLinkList(const Series: TBookSeries): string;
  end;

  // --------------------------------------------------------------------------
  PGenreData = ^TGenreData;
  TGenreData = record
    GenreCode: string;
    ParentCode: string;
    FB2GenreCode: string;
    GenreAlias: string;

    procedure Clear;
  end;
  TBookGenres = array of TGenreData;

  TGenresHelper = class
  public
    class procedure Add(
      var Genres: TBookGenres;
      const GenreCode: string;
      const Alias: string;
      const GenreFb2Code: string
    );

    class function GetList(const Genres: TBookGenres): string;
    class function GetLinkList(const Genres: TBookGenres): string;
  end;

  // --------------------------------------------------------------------------
  PGroupData = ^TGroupData;
  TGroupData = record
    GroupID: Integer;
    Text: string;
    CanDelete: Boolean;
  end;

  // --------------------------------------------------------------------------
  TDownloadState = (dsWait, dsRun, dsOk, dsError);
  PDownloadData = ^TDownloadData;
  TDownloadData = record
    BookKey: TBookKey;
    Author: string;
    Title: string;
    Size: Integer;
    FileName: string;
    URL: string;
    State: TDownloadState;
  end;

  // --------------------------------------------------------------------------
  TBookNodeType = (ntAuthorInfo = 1, ntSeriesInfo, ntBookInfo);

  TBookProp = (bpIsLocal = 1, bpIsDeleted, bpHasReview);
  TBookProps = set of TBookProp;

  PBookRecord = ^TBookRecord;
  TBookRecord = record
    nodeType: TBookNodeType;
    BookKey: TBookKey;
    SeriesID: Integer;
    Title: string;
    Series: string;
    Genres: TBookGenres;
    Authors: TBookAuthors;
    CollectionName: string;
    Lang: string;
    Size: Integer;
    Rate: Integer;
    SeqNumber: Integer;
    Progress: Integer;
    LibRate: Integer;
    BookProps: TBookProps;
    Date: TDateTime;
    FileExt: string;

    FileName: string;
    LibID: string;
    Folder: string;
    InsideNo: Integer;
    RootGenre: TGenreData;
    KeyWords: string;
    CollectionRoot: String;

    //TODO - rethink when to load the memo fields. Today are loaded only when LoadMemos flag is True
    Annotation: string;
    Review: string;

    // Metabib-only metadata (empty/0 for INPX and FB2 imports)
    Translators: string;
    Publisher: string;
    City: string;
    PubYear: Integer;
    ISBN: string;

    // ----------------------------------------------------
    function GetFileType: string;
    procedure Normalize;
    procedure Clear;

    function GenerateLocation: string;

    procedure ClearAuthors; inline;
    function AuthorCount: Integer; inline;

    procedure ClearGenres; inline;
    function GenreCount: Integer; inline;

    // ----------------------------------------------------
    function GetBookFormat: TBookFormat;
    function GetBookFileName: string;
    function GetBookContainer: string;
    function GetBookStream: TStream;
    function GetBookDescriptorStream(const RestoreImages: Boolean = True): TStream;
    function GetBookPreviewCoverStream: TStream;
    procedure SaveBookToFile(const DestFileName: String);
    function SaveBookToStream:TStream;
  end;

  // --------------------------------------------------------------------------
  PFileData = ^TFileData;
  TFileData = record
    FullPath, FileName, Folder, Ext, Title: string;
    Size: Integer;
    DataType: (dtFolder, dtFile);
    Date: TDateTime;
  end;

  // --------------------------------------------------------------------------
  TColumnData = record
    Text: string;
    Position, Width, MaxWidth, MinWidth: Integer;
    Alignment: TAlignment;
    Options: TVTColumnOptions;
  end;

  // --------------------------------------------------------------------------
  TBookSearchCriteria = record
    FullName: string;
    Series: string;
    Annotation: string;
    Genre: string;
    Title: string;
    FileName: string;
    Folder: string;
    FileExt: string;
    Lang: string;
    KeyWord: string;
    Deleted: Boolean;
    LibRate: string;
    Readed: Boolean;  //Признак, что книга прочитана

    DownloadedIdx: Integer;
    DateIdx: Integer;
    DateText: string;

    // True keeps one search row per physical book. False preserves the
    // classic MyHomeLib view where every series relationship has its own row.
    CollapseMultiSeriesResults: Boolean;
  end;

  PFilterValue = ^TFilterValue;
  TFilterValue = record
    // Only one of the following values will actually be used at a time
    ValueInt: Integer;
    ValueString: string;
  end;

  //
  // Вспомогательная структура для обработки заголовков INPX
  //
  // Структура заголовка
  // 1. Название коллекции
  // 2. Название файла коллекции
  // 3. Тип коллекции
  // 4. Notes
  // 5. URL
  // 6. Все оставшиеся строки содержат скрипт подключения
  //
  TINPXHeader = record
    Name: string;
    FileName: string;
    ContentType: COLLECTION_TYPE;
    Notes: string;
    URL: string;
    Script: string;

    procedure Clear;
    function AsString: string;
    procedure ParseString(const Value: string);
  end;

  TCollectionInfo = record
    ID: Integer;
    DisplayName: string;
    RootFolder: string;
    DBFileName: string;
    Notes: string;
    User: string;
    Password: string;
    DataVersion: Integer;
    CollectionType: COLLECTION_TYPE;
    URL: string;
    Script: string;

    procedure Clear;
    function GetRootPath: string;
  end;

  // Per-import dictionaries eliminate repeated author and series SELECTs on
  // the hot path. One cache belongs to one worker thread.
  TImportCache = class
  private
    FAuthors: TDictionary<string, Integer>;
    FSeries: TDictionary<string, Integer>;
  public
    constructor Create;
    destructor Destroy; override;

    function AuthorKey(const LastName, FirstName, MiddleName: string): string; inline;
    function TryGetAuthor(const Key: string; out ID: Integer): Boolean; inline;
    procedure AddAuthor(const Key: string; const ID: Integer); inline;
    function TryGetSeries(const NormalizedTitle: string; out ID: Integer): Boolean; inline;
    procedure AddSeries(const NormalizedTitle: string; const ID: Integer); inline;
    procedure Clear;
  end;


// ============================================================================
//
// helpers
//
// ============================================================================
  function CreateBookKey(BookID: Integer; DatabaseID: Integer): TBookKey; inline;

  // -----------------------------------------------------------------------------
  function isPrivateCollection(t: COLLECTION_TYPE): Boolean; inline;
  function isExternalCollection(t: COLLECTION_TYPE): Boolean; inline;
  function isLocalCollection(t: COLLECTION_TYPE): Boolean; inline;
  function isOnlineCollection(t: COLLECTION_TYPE): Boolean; inline;
  function isFB2Collection(t: COLLECTION_TYPE): Boolean; inline;
  function isNonFB2Collection(t: COLLECTION_TYPE): Boolean; inline;

  // -----------------------------------------------------------------------------
  function isSystemProp(propID: TPropertyID): Boolean; inline;
  function isCollectionProp(propID: TPropertyID): Boolean; inline;
  function propertyType(propID: TPropertyID): Integer; inline;

  // -----------------------------------------------------------------------------
  function Transliterate(const Input: string): string;
  function CheckSymbols(const Input: string; const Full: boolean = False): string;
  function EncodePassString(const Input: string): string;
  function DecodePassString(const Input: string): string;
  procedure StrReplace(const s1: string; const s2: string; var s3: string);
  function CleanFileName(const Input: string): string;

  function ClearDir(const DirectoryName: string): Boolean;
  //function IsRelativePath(const FileName: string): Boolean;
  function CreateFolders(const Root: string; const Path: string): Boolean;
  function CopyFile(const SourceFileName: string; const DestFileName: string): boolean;
  procedure ConvertToTxt(DestFileName: string; Enc: TTXTEncoding; Stream: TStream);

  function IncludeUrlSlash(const S: string): string;

  function PosChr(aCh: Char; const S: string): Integer;
  function CompareInt(i1, i2: Integer): Integer; inline;
  function CompareSeqNumber(i1, i2: Integer): Integer; inline;
  function CompareDate(d1, d2: TDateTime): Integer; inline;

  function GenerateBookLocation(const FullName: string): string;
  function GenerateFileName(const Title: string; libID: string): string;

  procedure DebugOut(const DebugMessage: string); overload;
  procedure DebugOut(const DebugMessage: string; const Args: array of const ); overload;

  function GetSpecialPath(CSIDL: word): string;
  function ExecAndWait(const FileName, Params: string; const WinState: word): Boolean; overload;
  // Тот же запуск, но возвращает и код завершения процесса: внешние конвертеры
  // сигнализируют об ошибке именно им (например, fb2pdf.cmd -> 1, если нет Java)
  function ExecAndWait(const FileName, Params: string; const WinState: word;
    out ExitCode: Cardinal): Boolean; overload;

  function CleanExtension(const Ext: string): string;
  function c_GetTempPath: String;

  procedure CheckUpdates(const Version: string; var AutoCheck: Boolean);

var
  CurrentSelectedAuthor: string; //Текущий выбранный автор для передачи в парсер экспорта
  CurrentSelectedGroup: string;  //Текущая выбранная группа для передачи в парсер экспорта

implementation

uses
  Forms,
  Windows,
  StrUtils,
  Math,
  IOUtils,
  Character,
  dm_user,
  ShlObj,
  System.Net.HttpClient,
  System.Net.URLClient,
  unit_MHLHttpClient,
  unit_fb2ToText,
  unit_FB2Utils,
  unit_MHLGenerics,
  unit_MHLArchiveHelpers,
  unit_MHLExternalTools,
  unit_FLibraryCompat,
  unit_Errors,
  unit_Settings;

resourcestring
rstrUnableToLaunch = 'Не удалось запустить %s! ';
   rstrBookNotFoundInArchive = 'В архиве "%s" не найдено описания книги!';
   rstrUpdateFailedServerNotFound = 'Проверка обновления не удалась! Сервер не найден.' + CRLF + 'Код ошибки: %d';
   rstrUpdateFailedConnectionError = 'Проверка обновления не удалась! Ошибка подключения.' + CRLF + 'Код ошибки: %d';
   rstrUpdateFailedServerError = 'Проверка обновления не удалась! Сервер сообщает об ошибке.' + CRLF + 'Код ошибки: %d';
   rstrFoundNewAppVersion = 'Доступна новая версия: "%s". Посетите сайт приложения, чтобы загрузить обновление.';
   rstrLatestVersion = 'У вас самая свежая версия.';

const
  lat: set of AnsiChar = ['A' .. 'Z', 'a' .. 'z', '\', '-', ':', '`', ',', '.', '0' .. '9', '_', ' ', '(', ')', '[', ']', '{', '}'];

const
  denied: set of AnsiChar = ['<', '>', ':', '"', '/', '|', '*', '?'];
  denied_full: set of AnsiChar = ['<', '>', ':', '"', '/', '|', '*', '?', '\', '«', '»'];

const
  TransL: array [0 .. 31] of string = ('a', 'b', 'v', 'g', 'd', 'e', 'zh', 'z', 'i', 'y', 'k', 'l', 'm', 'n', 'o', 'p', 'r', 's', 't', 'u', 'f', 'h', 'c', 'ch', 'sh', 'sch', '''', 'i', '''', 'e', 'yu', 'ya');

const
  TransU: array [0 .. 31] of string = ('A', 'B', 'V', 'G', 'D', 'E', 'Zh', 'Z', 'I', 'Y', 'K', 'L', 'M', 'N', 'O', 'P', 'R', 'S', 'T', 'U', 'F', 'H', 'C', 'Ch', 'Sh', 'Sch', '''', 'I', '''', 'E', 'Yu', 'Ya');

constructor TImportCache.Create;
begin
  inherited;
  FAuthors := TDictionary<string, Integer>.Create(32768);
  FSeries := TDictionary<string, Integer>.Create(8192);
end;

destructor TImportCache.Destroy;
begin
  FreeAndNil(FAuthors);
  FreeAndNil(FSeries);
  inherited;
end;

function TImportCache.AuthorKey(const LastName, FirstName,
  MiddleName: string): string;
begin
  Result := LastName + #0 + FirstName + #0 + MiddleName;
end;

function TImportCache.TryGetAuthor(const Key: string; out ID: Integer): Boolean;
begin
  Result := FAuthors.TryGetValue(Key, ID);
end;

procedure TImportCache.AddAuthor(const Key: string; const ID: Integer);
begin
  FAuthors.AddOrSetValue(Key, ID);
end;

function TImportCache.TryGetSeries(const NormalizedTitle: string;
  out ID: Integer): Boolean;
begin
  Result := FSeries.TryGetValue(NormalizedTitle, ID);
end;

procedure TImportCache.AddSeries(const NormalizedTitle: string;
  const ID: Integer);
begin
  FSeries.AddOrSetValue(NormalizedTitle, ID);
end;

procedure TImportCache.Clear;
begin
  FAuthors.Clear;
  FSeries.Clear;
end;

  // -----------------------------------------------------------------------------
  // различная информация о коллекции
  // -----------------------------------------------------------------------------
function isPrivateCollection(t: COLLECTION_TYPE): Boolean;
begin
  Result := (t and CT_TYPE_MASK) = LIBRARY_PRIVATE;
end;

function isExternalCollection(t: COLLECTION_TYPE): Boolean;
begin
  Result := (t and CT_TYPE_MASK) <> LIBRARY_PRIVATE;
end;

function isLocalCollection(t: COLLECTION_TYPE): Boolean;
begin
  Result := (t and CT_LOCATION_MASK) = LOCATION_LOCAL;
end;

function isOnlineCollection(t: COLLECTION_TYPE): Boolean;
begin
  Result := (t and CT_LOCATION_MASK) = LOCATION_ONLINE;
end;

function isFB2Collection(t: COLLECTION_TYPE): Boolean; inline;
begin
  Result := (t and CT_CONTENT_MASK) = CONTENT_FB;
end;

function isNonFB2Collection(t: COLLECTION_TYPE): Boolean; inline;
begin
  Result := (t and CT_CONTENT_MASK) = CONTENT_NONFB;
end;

// -----------------------------------------------------------------------------
function isSystemProp(propID: TPropertyID): Boolean; inline;
begin
  Result := (propID and PROP_CLASS_SYSTEM) = PROP_CLASS_SYSTEM;
end;

function isCollectionProp(propID: TPropertyID): Boolean; inline;
begin
  Result := (propID and PROP_CLASS_COLLECTION) = PROP_CLASS_COLLECTION;
end;

function propertyType(propID: TPropertyID): Integer; inline;
begin
  Result := (propID and PROP_TYPE_MASK);
end;

// -----------------------------------------------------------------------------
//
// -----------------------------------------------------------------------------

function c_GetTempPath: String;
var
  Buffer: array[0..65535] of Char;
begin
  SetString(Result, Buffer, GetTempPath(Length(Buffer), Buffer));
end;

function PosChr(aCh: Char; const S: string): Integer;
var
  i, max: Integer;
begin
  Result := 0;
  max := Length(S);
  for i := 1 to max do
    if S[i] = aCh then
    begin
      Result := i;
      Exit;
    end;
end;

procedure StrReplace(const s1: string; const s2: string; var s3: string);
begin
  s3 := StringReplace(s3, s1, s2, [rfReplaceAll]);
end;

function IsReservedWindowsName(const Value: string): Boolean;
var
  BaseName: string;
  DotPos: Integer;
begin
  BaseName := Trim(Value);
  while (BaseName <> '') and CharInSet(BaseName[Length(BaseName)], [' ', '.']) do
    Delete(BaseName, Length(BaseName), 1);

  DotPos := Pos('.', BaseName);
  if DotPos > 0 then
    BaseName := Copy(BaseName, 1, DotPos - 1);
  BaseName := UpperCase(BaseName);

  Result := (BaseName = 'CON') or (BaseName = 'PRN') or
    (BaseName = 'AUX') or (BaseName = 'NUL') or
    ((Length(BaseName) = 4) and
     ((Copy(BaseName, 1, 3) = 'COM') or (Copy(BaseName, 1, 3) = 'LPT')) and
     CharInSet(BaseName[4], ['1'..'9']));
end;

function SanitizeWindowsComponent(const Value: string): string;
begin
  if (Trim(Value) = '.') or (Trim(Value) = '..') then
    Exit('_');

  Result := Value;
  while (Result <> '') and CharInSet(Result[Length(Result)], [' ', '.']) do
    Delete(Result, Length(Result), 1);

  if IsReservedWindowsName(Result) then
    Result := '_' + Result;
end;

function SanitizeWindowsPathComponents(const Value: string): string;
var
  Builder: TStringBuilder;
  ComponentStart: Integer;
  I: Integer;
begin
  Builder := TStringBuilder.Create(Length(Value));
  try
    ComponentStart := 1;
    for I := 1 to Length(Value) do
      if Value[I] = '\' then
      begin
        Builder.Append(SanitizeWindowsComponent(
          Copy(Value, ComponentStart, I - ComponentStart)));
        Builder.Append('\');
        ComponentStart := I + 1;
      end;
    Builder.Append(SanitizeWindowsComponent(
      Copy(Value, ComponentStart, MaxInt)));
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

// Replace non-valid file name characters with spaces
function CleanFileName(const Input: string): string;
var
  i: Integer;
begin
  Result := Input;

  Result := StringReplace(Result,'...','',[rfReplaceAll]);
  Result := StringReplace(Result,'..','',[rfReplaceAll]);

  for i := 1 to Length(Result) do
  begin
    if not TPath.IsValidFileNameChar(Result[i]) then
      Result[i] := ' ';
  end;
  Result := SanitizeWindowsComponent(Result);
end;

(*
function IsRelativePath(const FileName: string): Boolean;
//var
//  L: Integer;
begin
  Result := TPath.IsPathRooted(FileName);
  {
  Result := True;
  L := Length(FileName);
  if ((L >= 1) and IsPathDelimiter(FileName, 1)) or // \dir\subdir or /dir/subdir
    ((L >= 2) and CharInSet(FileName[1], ['A' .. 'Z', 'a' .. 'z']) and (FileName[2] = ':')) // C:, D:, etc.
  then
    Result := False;
  }
end;
*)

function CreateFolders(const Root: string; const Path: string): Boolean;
var
  RootPath: string;
  FullPath: string;
begin
  // Some established callers already pass an absolute destination and leave
  // Root empty (notably the downloader). In that mode there is no relative
  // template to confine; normalise the explicit path and create it directly.
  if Root = '' then
  begin
    if Path = '' then
      Exit(False);
    FullPath := TPath.GetFullPath(Path);
    Exit(SysUtils.ForceDirectories(FullPath));
  end;

  RootPath := ExcludeTrailingPathDelimiter(TPath.GetFullPath(Root));
  if (Path = '') or (Path = '\') then
    FullPath := RootPath
  else
    FullPath := TPath.GetFullPath(TPath.Combine(RootPath, Path));
  if not SameText(FullPath, RootPath) and
     not StartsText(IncludeTrailingPathDelimiter(RootPath), FullPath) then
    Exit(False);

  Result := SysUtils.ForceDirectories(FullPath);
end;
{$WARNINGS OFF}

function CopyFile(const SourceFileName: string; const DestFileName: string): boolean;
var
  SourceFile: TFileStream;
  DestFile: TFileStream;
begin
  SourceFile := TFileStream.Create(SourceFileName, fmOpenRead or fmShareDenyNone);
  try
    DestFile := TFileStream.Create(DestFileName, fmCreate or fmShareDenyRead);
    try
      if SourceFile.Size <> DestFile.CopyFrom(SourceFile, 0) then
        RaiseLastOSError;
    finally
      DestFile.Free;
    end;
    Result := True;
  finally
    SourceFile.Free;
  end;
end;
{$WARNINGS ON}

procedure ConvertToTxt(DestFileName: string; Enc: TTXTEncoding; Stream: TStream);
var
  Converter: TFb2ToText;
begin
  Converter := TFb2ToText.Create;
  try
    DestFileName := ChangeFileExt(DestFileName, '.txt');
    Converter.Convert(DestFileName, Enc, Stream);
  finally
    Converter.Free;
  end;
end;

function EncodePassString(const Input: string): string;
var
  i: Integer;
begin
  Result := Input;
  for i := 1 to Length(Input) do
    Result[i] := Chr(Ord(Input[i]) + 5);
end;

function DecodePassString(const Input: string): string;
var
  i: Integer;
begin
  Result := Input;
  for i := 1 to Length(Input) do
    Result[i] := Chr(Ord(Input[i]) - 5);
end;

{$WARNINGS OFF}
function ClearDir(const DirectoryName: string): Boolean;
var
  SearchRec: TSearchRec;
  ACurrentDir: string;
begin
  Result := True;
  ACurrentDir := IncludeTrailingPathDelimiter(DirectoryName);

  try
    if FindFirst(ACurrentDir + '*.*', faAnyFile, SearchRec) = 0 then
      try
        repeat
          if (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then
            if (SearchRec.Attr and faDirectory) = 0 then
              Result := SysUtils.DeleteFile(ACurrentDir + SearchRec.Name) and Result;
        until FindNext(SearchRec) <> 0;
      finally
        SysUtils.FindClose(SearchRec);
      end;
  except
    Result := False;
  end;
end;
{$WARNINGS ON}

function Transliterate(const Input: string): string;
var
  S: string;
  SB: TStringBuilder;
  f, o: Integer;
begin
  SB := TStringBuilder.Create(Length(Input));
  try
    for f := 1 to Length(Input) do
    begin
      o := Ord(Input[f]);
      if (o >= 1072) and (o <= 1103) then
        S := TransL[o - 1072]
      else if Input[f] = 'ё' then
        S := 'e'
      else if (o >= 1040) and (o <= 1071) then
        S := TransU[o - 1040]
      else if Input[f] = 'Ё' then
        S := 'E'
      else if CharInSet(Input[f], lat) then
        S := Input[f]
      else
        S := '_';
      SB.Append(S);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function CheckSymbols(const Input: string; const Full: boolean = False): string;
var
  SB: TStringBuilder;
  f: Integer;
  ch: Char;
  IsDenied: Boolean;
begin
  SB := TStringBuilder.Create(Length(Input));
  try
    for f := 1 to Length(Input) do
    begin
      ch := Input[f];
      if Full then
        IsDenied := CharInSet(ch, denied_full)
      else
        IsDenied := CharInSet(ch, denied);

      if IsDenied then
        SB.Append(' ')
      else
        SB.Append(ch);
    end;

    // Windows ignores trailing spaces/dots and reserves several device names.
    while (SB.Length > 0) and CharInSet(SB.Chars[SB.Length - 1], [' ', '.']) do
      SB.Length := SB.Length - 1;

    if Full then
      Result := SanitizeWindowsComponent(SB.ToString)
    else
      Result := SanitizeWindowsPathComponents(SB.ToString);
  finally
    SB.Free;
  end;
end;

function GenerateBookLocation(const FullName: string): string;
var
  Letter: Char;
  AuthorName: string;
begin
  //
  // Не обрезаем пробелы здесь!!! От их наличия зависит расположение файла - на букве или в каталоге '_'
  //
  AuthorName := Trim(CheckSymbols(FullName)); // Ф.И.О. - полностью!

  if AuthorName = '' then
    AuthorName := rstrUnknownAuthor;

  Letter := AuthorName[1];
  if not Letter.IsLetterOrDigit then
    Letter := '_';

  Result := IncludeTrailingPathDelimiter(Letter) + IncludeTrailingPathDelimiter(AuthorName);
end;

function GenerateFileName(const Title: string; libID: string): string;
var
  BookTitle: string;
begin
  BookTitle := Trim(CheckSymbols(Title));
  if BookTitle = '' then
    BookTitle := rstrNoTitle;
  Result := libID + ' ' + BookTitle;
end;

{ TAuthorRecord }

procedure TAuthorData.Clear;
begin
  AuthorID := 0;
  FFirstName := '';
  FMiddleName := '';
  FLastName := rstrUnknownAuthor;
end;

class function TAuthorData.FormatName(const LastName: string; const FirstName: string; const MiddleName: string; const nickName: string = ''; onlyInitials: Boolean = False): string;
begin
  Result := unit_FB2Utils.FormatName(Lastname, Firstname, Middlename, NickName, onlyInitials)
end;

function TAuthorData.GetFullName(onlyInitials: Boolean = False): string;
begin
  Assert(LastName <> '');

  Result := FormatName(LastName, FirstName, MiddleName, '', onlyInitials);
end;

procedure TAuthorData.SetFirstName(const Value: string);
begin
  FFirstName := Trim(Value);
end;

procedure TAuthorData.SetLastName(const Value: string);
begin
  FLastName := Trim(Value);
end;

procedure TAuthorData.SetMiddleName(const Value: string);
begin
  FMiddleName := Trim(Value);
end;

{ TAuthorsHelper }

class procedure TAuthorsHelper.Add(
  var Authors: TBookAuthors;
  const LastName: string;
  const FirstName: string;
  const MiddleName: string;
  AuthorID: Integer = 0
);
var
  i: Integer;
begin
  i := Length(Authors);
  SetLength(Authors, i + 1);

  Authors[i].LastName := LastName;
  Authors[i].FirstName := FirstName;
  Authors[i].MiddleName := MiddleName;
  Authors[i].AuthorID := AuthorID;
end;

class function TAuthorsHelper.GetList(const Authors: TBookAuthors): string;
begin
  Result := TArrayUtils.Join<TAuthorData>(
    Authors,
    ', ',
    function(const Author: TAuthorData): string
    begin
      Result := Author.GetFullName;
    end
  );
end;

class function TAuthorsHelper.GetLinkList(const Authors: TBookAuthors): string;
begin
  Result := TArrayUtils.Join<TAuthorData>(
    Authors,
    ' ',
    function(const Author: TAuthorData): string
    begin
      Result := Format('<a href="%d">%s</a>', [Author.AuthorID, Author.GetFullName(True)]);
    end
  );
end;

{ TSeriesHelper }

class procedure TSeriesHelper.Add(var Series: TBookSeries;
  const SeriesID: Integer; const SeriesTitle: string;
  const SeqNumber: Integer; const IsPrimary: Boolean);
var
  i: Integer;
begin
  i := Length(Series);
  SetLength(Series, i + 1);
  Series[i].SeriesID := SeriesID;
  Series[i].SeriesTitle := SeriesTitle;
  Series[i].SeqNumber := SeqNumber;
  Series[i].IsPrimary := IsPrimary;
end;

class function TSeriesHelper.GetLink(const SeriesID: Integer; const SeriesTitle: string): string;
begin
  Result := Format('<a href="%d">%s</a>', [SeriesID, SeriesTitle]);
end;

class function TSeriesHelper.GetLinkList(const Series: TBookSeries): string;
begin
  Result := TArrayUtils.Join<TBookSeriesData>(
    Series,
    '<br>',
    function(const Item: TBookSeriesData): string
    begin
      Result := GetLink(Item.SeriesID, Item.SeriesTitle);
      if Item.SeqNumber <> 0 then
        Result := Result + Format(' № %d', [Item.SeqNumber]);
    end
  );
end;

{ TGenreData }

procedure TGenreData.Clear;
begin
  GenreCode := UNKNOWN_GENRE_CODE;
  ParentCode := '';
  FB2GenreCode := '';
  GenreAlias := '';
end;

{ TGenresHelper }

class procedure TGenresHelper.Add(var Genres: TBookGenres; const GenreCode, Alias, GenreFb2Code: string);
var
  i: Integer;
begin
  i := Length(Genres);
  SetLength(Genres, i + 1);

  Genres[i].GenreCode := GenreCode;
  Genres[i].ParentCode := '';
  Genres[i].FB2GenreCode := GenreFb2Code;
  Genres[i].GenreAlias := Alias;
end;

class function TGenresHelper.GetList(const Genres: TBookGenres): string;
begin
  Result := TArrayUtils.Join<TGenreData>(
    Genres,
    ' / ',
    function(const genre: TGenreData): string
    begin
      Result := genre.GenreAlias;
    end
  );
end;

class function TGenresHelper.GetLinkList(const Genres: TBookGenres): string;
begin
  Result := TArrayUtils.Join<TGenreData>(
    Genres,
    ' ',
    function(const genre: TGenreData): string
    begin
      Result := Format('<a href="%s">%s</a>', [genre.GenreCode, genre.GenreAlias]);
    end
  );
end;

function CreateBookKey(BookID: Integer; DatabaseID: Integer): TBookKey;
begin
  Result.BookID := BookID;
  Result.DatabaseID := DatabaseID;
end;

procedure TBookKey.Clear;
begin
  BookID := MHL_INVALID_ID;
  DatabaseID := MHL_INVALID_ID;
end;

// Is the other key equal to this one?
function TBookKey.IsSameAs(const other: TBookKey): Boolean;
begin
  Result := (BookID = other.BookID) and (DatabaseID = other.DatabaseID);
end;

procedure TBookRecord.Clear;
begin
  nodeType := ntBookInfo;
  BookKey.Clear;
  SeriesID := NO_SERIES_ID;
  Title := '';
  Series := NO_SERIES_TITLE;
  ClearAuthors;
  ClearGenres;
  CollectionName := '';
  Lang := '';
  Size := 0;
  Rate := 0;
  SeqNumber := 0;
  Progress := 0;
  LibRate := 0;
  BookProps := [];
  Date := 0;
  FileExt := '';
  FileName := '';
  LibID := '';
  Folder := '';
  InsideNo := 0;
  RootGenre.Clear;
  KeyWords := '';
  CollectionRoot := '';
  Annotation := '';
  Review := '';
  Translators := '';
  Publisher := '';
  City := '';
  PubYear := 0;
  ISBN := '';
end;

//
// Добавляет отсутствующую информацию о книге, заполняя поля значения по умолчанию
//
procedure TBookRecord.Normalize;
var
  i: Integer;
begin
  if Title = '' then
    Title := rstrNoTitle;

  for i := 0 to AuthorCount - 1 do
    if Authors[i].LastName = '' then
      Authors[i].LastName := rstrUnknownAuthor;
  if AuthorCount = 0 then
    TAuthorsHelper.Add(Authors, rstrUnknownAuthor, '', '');

  for i := 0 to GenreCount - 1 do
    if Genres[i].GenreCode = '' then
      Genres[i].GenreCode := UNKNOWN_GENRE_CODE;
  if GenreCount = 0 then
    TGenresHelper.Add(Genres, UNKNOWN_GENRE_CODE, '', '');
end;

function TBookRecord.GetFileType: string;
begin
  Result := CleanExtension(FileExt);
end;

//
// Формирует И\Иванов Иван Иванович\Просто книга
//
function TBookRecord.GenerateLocation: string;
begin
  Assert(AuthorCount > 0);
  Result := GenerateBookLocation(Authors[0].GetFullName) + GenerateFileName(Title, libID);
end;

procedure TBookRecord.ClearAuthors;
begin
  SetLength(Authors, 0);
end;

function TBookRecord.AuthorCount: Integer;
begin
  Result := Length(Authors);
end;

procedure TBookRecord.ClearGenres;
begin
  SetLength(Genres, 0);
end;

function TBookRecord.GenreCount: Integer;
begin
  Result := Length(Genres);
end;

// Get the book format enum value
function TBookRecord.GetBookFormat: TBookFormat;
var
  BookContainer: string;
  PathLen: Integer;
  LongFileName: string;
begin
  Result := bfRaw; // default
  BookContainer := GetBookContainer;
  PathLen := Length(BookContainer);

  if
    (PathLen = 0) or
    (BookContainer[PathLen] = TPath.DirectorySeparatorChar) or
    (BookContainer[PathLen] = TPath.AltDirectorySeparatorChar) then
  begin
    //BookContainer is either empty or a path
    LongFileName := TPath.Combine(BookContainer, FileName);

    if AnsiLowercase(ExtractFileExt(LongFileName)) = ZIP_EXTENSION then
      Result := bfFbd
    else if FileExt = FB2_EXTENSION then
      Result := bfFb2
  end
  else
  begin

    if IsArchiveExt(BookContainer) then
    begin
      if (FileExt = FB2_EXTENSION) then
        Result := bfFb2Archive
      else
        Result := bfRawArchive;
    end;
  end;

  if (Result = bfRaw) and (FileExt = FB2_EXTENSION) then
    Result := bfFb2
end;

// Get the fully expanded book file name
function TBookRecord.GetBookFileName: string;
var
  BookFormat: TBookFormat;
  BookContainer: string;
begin
  BookContainer := GetBookContainer;
  BookFormat := GetBookFormat;
  if BookFormat = bfFBD then
    Result := TPath.Combine(BookContainer, FileName)
  else if (BookFormat = bfFb2Archive) or (BookFormat = bfRawArchive)  then
    Result := BookContainer
  else // bfFb2 or bfRaw
    Result := TPath.Combine(BookContainer, FileName) + FileExt;
end;

// Get the container holding the book (folder or zip file)
//  For bfFb2, bfFBD and bfRaw - brings the folder containing the file
//  For bfFb2Zip - brings the name of the Zip file
function TBookRecord.GetBookContainer: string;
var
  SevenZipFallback: string;
begin
  Result := TPath.Combine(CollectionRoot, Folder);
  // Collections imported by older MyHomeLib builds assumed that every INPX
  // member referred to a ZIP.  FLibrary keeps the same base name in 7z.  Make
  // an already-created collection usable without rewriting its database.
  if SameText(ExtractFileExt(Result), ZIP_EXTENSION) and
    not FileExists(Result) then
  begin
    SevenZipFallback := ChangeFileExt(Result,
      SEVENZIP_ARCHIVE_EXTENSION);
    if FileExists(SevenZipFallback) then
      Result := SevenZipFallback;
  end;
end;

// Get the book file as a stream.
// The caller code must free the stream when done!
// For FBD archives brings the raw book (and NOT the FBD descriptor)
function TBookRecord.GetBookStream: TStream;
var
  ArchiveFileName: string;
  ArchiveEntryName: string;
  BookFormat: TBookFormat;
  BookFileName: string;
  archiver: TMHLZip;
  RestoredStream: TStream;
begin
  Result := nil;
  archiver := nil;
  BookFileName := GetBookFileName;

  BookFormat := GetBookFormat;
  if BookFormat in [bfFb2Archive, bfFbd, bfRawArchive] then
  begin
    try
      try
        ArchiveFileName := TPath.Combine(Settings.ReadPath, BookFileName);
        archiver := TMHLZip.Create(ArchiveFileName, True);
        ArchiveEntryName := FileName + FileExt;
        if IsSevenZipArchive(ArchiveFileName) then
        begin
          Result := TMemoryStream.Create;
          archiver.ExtractToStream(ArchiveEntryName, Result);
        end
        else
          Result := archiver.ExtractToStream(InsideNo);
      except
        on E: EMHLExternalToolError do
        begin
          FreeAndNil(Result);
          raise;
        end;
        on E: Exception do
        begin
          FreeAndNil(Result);
          if not Settings.IgnoreAbsentArchives then
            raise EBookNotFound.CreateFmt(rstrArchiveNotFound, [BookFileName]);
        end;
      end;

      if Assigned(Result) and IsSevenZipArchive(ArchiveFileName) then
      begin
        try
          RestoredStream := RestoreFLibraryBook(ArchiveFileName,
            ArchiveEntryName, Result);
          if Assigned(RestoredStream) then
          begin
            FreeAndNil(Result);
            Result := RestoredStream;
          end;
        except
          FreeAndNil(Result);
          raise;
        end;
      end;
    finally
      FreeAndNil(archiver);
    end;
  end
  else // bfFb2, bfRaw
  begin
    try
      Result := TFileStream.Create(BookFileName, fmOpenRead);
    except
      on e: EFOpenError do
      begin
        //
        // TODO: на самом деле, файл может существовать, но буть заблокирован другим приложением
        //
        raise EBookNotFound.CreateFmt(rstrFileNotFound, [BookFileName]);
      end;
    end;
  end;

  Assert(Assigned(Result) or Settings.IgnoreAbsentArchives);
end;

// Get the descriptor file as a stream.
// The caller code must free the stream when done!
//  For bfFbd - brings the FBD descriptor file
//  For bfFb2Zip and bfFb2 - brings the FB2 file
//  For bfRaw - raise ENotSupportedException exception
function TBookRecord.GetBookDescriptorStream(
  const RestoreImages: Boolean): TStream;
var
  bookFileName: string;
  archiveFileName: string;
  archiveEntryName: string;
  archiver: TMHLZip;
begin
  Result := nil;
  archiver := nil;

  case GetBookFormat of
    bfFb2:
      begin
        Result := GetBookStream;
      end;

    bfFb2Archive:
      begin
        bookFileName := GetBookFileName;
        archiveFileName := TPath.Combine(Settings.ReadPath, bookFileName);
        if RestoreImages or not IsSevenZipArchive(archiveFileName) then
          Result := GetBookStream
        else
        begin
          // The information panel only needs FB2 metadata.  In an FLibrary
          // collection, restoring every external illustration here used to
          // block the UI for several seconds on each selection change.
          archiveEntryName := FileName + FileExt;
          archiver := TMHLZip.Create(archiveFileName, True);
          try
            Result := TMemoryStream.Create;
            try
              archiver.ExtractToStream(archiveEntryName, Result);
            except
              FreeAndNil(Result);
              raise;
            end;
          finally
            FreeAndNil(archiver);
          end;
        end;
      end;

    bfFbd:
      begin
        bookFileName := GetBookFileName;
        archiveFileName := TPath.Combine(Settings.ReadPath, bookFileName);
        if not FileExists(archiveFileName) then
          raise EBookNotFound.CreateFmt(rstrFileNotFound, [archiveFileName]);

        try
          archiver := TMHLZip.Create(archiveFileName, True);
          if not archiver.Find('*' + FBD_EXTENSION) then
            raise EBookNotFound.CreateFmt(rstrBookNotFoundInArchive,
              [archiveFileName]);

          Result := TMemoryStream.Create;
          try
            archiver.ExtractToStream(archiver.LastName, Result);
          except
            FreeAndNil(Result);
            raise;
          end;
        finally
          FreeAndNil(archiver);
        end;
      end;

    bfRaw:
      begin
        raise ENotSupportedException.Create(rstrErrorNotSupported);
      end;
  end;

end;

function TBookRecord.GetBookPreviewCoverStream: TStream;
var
  ArchiveFileName: string;
  BookFormat: TBookFormat;
begin
  Result := nil;
  BookFormat := GetBookFormat;
  if not (BookFormat in [bfFb2Archive, bfRawArchive]) then
    Exit;

  ArchiveFileName := TPath.Combine(Settings.ReadPath, GetBookFileName);
  if IsSevenZipArchive(ArchiveFileName) then
    Result := ExtractFLibraryBookCover(ArchiveFileName,
      FileName + FileExt);
end;

// Save the book to a destination file
procedure TBookRecord.SaveBookToFile(const DestFileName: String);
var
  SourceStream: TStream;
  DestStream: TFileStream;
begin
  SourceStream := GetBookStream;
  try
    if SourceStream <> nil then
    begin
      DestStream := TFileStream.Create(DestFileName, fmCreate);
      try
        DestStream.CopyFrom(SourceStream, 0);
      finally
        FreeAndNil(DestStream);
      end;
    end;
  finally
    FreeAndNil(SourceStream);
  end;
end;

function TBookRecord.SaveBookToStream: TStream;
begin
  Result := GetBookStream;
end;

// ============================================================================

function IncludeUrlSlash(const S: string): string;
begin
  Result := S;
  if Result <> '' then
  begin
    // relevant only for non-empty URL strings
    if Result[Length(Result)] <> '/' then
      Result := Result + '/';
  end;
end;

function CompareDate(d1, d2: TDateTime): Integer;
begin
  if d1 > d2 then
    Result := 1
  else if d1 < d2 then
    Result := -1
  else // if d1 = d2 then
    Result := 0;
end;

function CompareInt(i1, i2: Integer): Integer;
begin
  if i1 > i2 then
    Result := 1
  else if i1 < i2 then
    Result := -1
  else
    Result := 0;
end;

function CompareSeqNumber(i1, i2: Integer): Integer;
begin
  if (i1 > 0) and (i2 = 0) then
    Result := -1
  else if (i1 = 0) and (i2 > 0) then
    Result := 1
  else
    Result := Sign(i1 - i2);
end;

procedure DebugOut(const DebugMessage: string);
begin
{$IFOPT D+}
  DebugOut(DebugMessage, []);
{$ENDIF}
end;

procedure DebugOut(const DebugMessage: string; const Args: array of const );
begin
{$IFOPT D+}
  OutputDebugString(PChar(Format(DebugMessage, Args)));
{$ENDIF}
end;

function GetSpecialPath(CSIDL: word): string;
var
  S: string;
begin
  SetLength(S, MAX_PATH);
  if not SHGetSpecialFolderPath(0, PChar(S), CSIDL, True) then
  begin
    Result := '';
    Exit;
  end;
  Result := IncludeTrailingPathDelimiter(PChar(S));
end;

procedure CheckUpdates(const Version: string; var AutoCheck: Boolean);
var
  SL: TStringList;
  LF: TMemoryStream;
  i: Integer;
  S: string;
  HTTP: THTTPClient;
begin
  LF := TMemoryStream.Create;
  try
    SL := TStringList.Create;
    try
      HTTP := CreateHTTPClientGlobal;
      try
        try
          HTTP.Get(IncludeUrlSlash(Settings.UpdateURL) + PROGRAM_VERINFO_FILENAME, LF);
        except
          on E: ENetHTTPClientException do
          begin
            MHLShowError(rstrUpdateFailedConnectionError, [0]);
            AutoCheck := False;
            Exit;
          end;
          on E: Exception do
          begin
            MHLShowError(rstrUpdateFailedServerError, [0]);
            AutoCheck := False;
            Exit;
          end;
        end;
        LF.SaveToFile(Settings.SystemFileName[sfAppVerInfo]);
        SL.LoadFromFile(Settings.SystemFileName[sfAppVerInfo]);
        if SL.Count > 0 then
          if CompareStr(Version, SL[0]) < 0 then
          begin
            S := CRLF;
            for i := 1 to SL.Count - 1 do
              S := S + '  ' + SL[i] + CRLF;
            MHLShowInfo(Format(rstrFoundNewAppVersion, [SL[0] + CRLF + S + CRLF]));
          end
          else if not AutoCheck then
            MHLShowInfo(rstrLatestVersion);
        AutoCheck := False;
      finally
        HTTP.Free;
      end;
    finally
      SL.Free;
    end;
  finally
    LF.Free;
  end;
end;


function ExecAndWait(const FileName, Params: string; const WinState: word): Boolean;
var
  ExitCode: Cardinal;
begin
  Result := ExecAndWait(FileName, Params, WinState, ExitCode);
end;

function ExecAndWait(const FileName, Params: string; const WinState: word;
  out ExitCode: Cardinal): Boolean;
var
  StartInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  ApplicationName: string;
  CmdLine: string;
begin
  ExitCode := 0;
  if SameText(ExtractFileExt(FileName), '.cmd') or
     SameText(ExtractFileExt(FileName), '.bat') then
  begin
    ApplicationName := GetEnvironmentVariable('ComSpec');
    if ApplicationName = '' then
      ApplicationName := TPath.Combine(
        GetEnvironmentVariable('SystemRoot'), 'System32\cmd.exe');
    CmdLine := '"' + ApplicationName + '" /D /S /C ""' + FileName +
      '" ' + Params + '"';
  end
  else
  begin
    ApplicationName := FileName;
    CmdLine := '"' + FileName + '"';
    if Params <> '' then
      CmdLine := CmdLine + ' ' + Params;
  end;
  FillChar(StartInfo, Sizeof(StartInfo), #0);
  with StartInfo do
  begin
    cb := Sizeof(StartInfo);
    dwFlags := STARTF_USESHOWWINDOW;
    wShowWindow := WinState;
  end;

  Result := CreateProcess(
    PChar(ApplicationName),
    PChar(CmdLine),
    nil,
    nil,
    False,
    CREATE_NEW_CONSOLE or NORMAL_PRIORITY_CLASS,
    nil,
    PChar(ExtractFilePath(FileName)),
    StartInfo,
    ProcInfo
  );

  if Result then
  begin
    WaitForSingleObject(ProcInfo.hProcess, INFINITE);
    // Запуск удался - это еще не успех: конвертер мог завершиться с ошибкой
    if not GetExitCodeProcess(ProcInfo.hProcess, ExitCode) then
    begin
      ExitCode := Cardinal(-1);
      Result := False;
    end
    else
      Result := ExitCode = 0;
    { Free the Handles }
    CloseHandle(ProcInfo.hProcess);
    CloseHandle(ProcInfo.hThread);
  end;
end;

function CleanExtension(const Ext: string): string;
begin
  Result := Trim(Ext);
  if (Result <> '') and (Result[1] = '.') then
    Delete(Result, 1, 1);
end;

{ TINPXHeader }

procedure TINPXHeader.Clear;
begin
  Name := '';
  FileName := '';
  ContentType := CT_PRIVATE_FB;
  Notes := '';
  URL := '';
  Script := '';
end;

function TINPXHeader.AsString: string;
begin
  Result :=
    Name + CRLF +
    ExtractFileName(FileName) + CRLF +
    IntToStr(ContentType) + CRLF +
    Notes + CRLF +
    URL + CRLF +
    Script;
end;

procedure TINPXHeader.ParseString(const Value: string);
var
  slHelper: TStringList;
  i: Integer;
begin
  Clear;

  slHelper := TStringList.Create;
  try
    slHelper.Text := Value;

    if slHelper.Count > 0 then
      Name := slHelper[0];

    if slHelper.Count > 1 then
      FileName := slHelper[1];

    if slHelper.Count > 2 then
      ContentType := StrToIntDef(slHelper[2], CT_PRIVATE_FB);

    if slHelper.Count > 3 then
      Notes := slHelper[3];

    if slHelper.Count > 4 then
      URL := slHelper[4];

    for i := 5 to slHelper.Count - 1 do
      Script := Script + slHelper[i] + CRLF;
  finally
    slHelper.Free;
  end;
end;

{ TCollectionInfo }

procedure TCollectionInfo.Clear;
begin
  ID := INVALID_COLLECTION_ID;
  DisplayName := '';
  RootFolder := '';
  DBFileName := '';
  Notes := '';
  DataVersion := UNVERSIONED_COLLECTION;
  CollectionType := CT_PRIVATE_FB;
  User := '';
  Password := '';
  URL := '';
  Script := '';
end;

function TCollectionInfo.GetRootPath: string;
begin
  Result := IncludeTrailingPathDelimiter(RootFolder);
end;

end.
