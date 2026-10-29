unit unit_MCP_Tools_Library;

interface

uses
  System.SysUtils,
  System.JSON,
  unit_Globals,
  unit_Interfaces,
  unit_MCP_Protocol;

procedure RegisterLibraryTools(Server: TMcpServer);
function CollectionOrFail(const CollectionID: Integer): IBookCollection;
function Guarded(Handler: TMcpToolHandler): TMcpToolHandler;
function BookToJson(const Book: TBookRecord; Full: Boolean): TJSONObject;
function AuthorsToJson(const Authors: TBookAuthors): TJSONArray;
function GenresToJson(const Genres: TBookGenres): TJSONArray;

procedure LogToStderr(const Msg: string);

implementation

uses
  System.Character,
  dm_user,
  unit_Settings,
  unit_MCP_Json,
  SQLiteWrap;

var
  GLibraryInitialized: Boolean = False;

procedure EnsureLibraryInitialized;
var
  SysDBFileName: string;
begin
  if GLibraryInitialized then
    Exit;

  if not Assigned(DMUser) then
    DMUser := TDMUser.Create(nil);

  SysDBFileName := DMUser.Settings.SystemFileName[sfSystemDB];
  if not FileExists(SysDBFileName) then
    raise EMcpToolError.Create('system_db_missing',
      Format('Системная база данных HomeLibre не найдена по адресу: %s. ' +
        'Запустите HomeLibre хотя бы один раз, чтобы её создать.',
        [SysDBFileName]));

  DMUser.Init;
  GLibraryInitialized := True;
end;

function Guarded(Handler: TMcpToolHandler): TMcpToolHandler;
begin
  Result :=
    function(const Args: TJSONObject): TJSONObject
    begin
      try
        EnsureLibraryInitialized;
        Result := Handler(Args);
      except
        on E: ESQLiteException do
        begin
          if E.Message.ToLower.Contains('locked') or
             E.Message.ToLower.Contains('busy') then
            raise EMcpToolError.Create('collection_busy',
              'Коллекция занята — возможно, HomeLibre импортирует книги.');
          raise;
        end;
      end;
    end;
end;

procedure LogToStderr(const Msg: string);
begin
  Writeln(ErrOutput, Msg);
end;

function CollectionOrFail(const CollectionID: Integer): IBookCollection;
begin
  try
    Result := SystemDB.GetCollection(CollectionID);
  except
    on E: Exception do
    begin
      LogToStderr(Format('CollectionOrFail(%d): %s', [CollectionID, E.Message]));
      raise EMcpToolError.Create('collection_not_found',
        Format('Collection %d not found', [CollectionID]));
    end;
  end;

  if not Assigned(Result) then
    raise EMcpToolError.Create('collection_not_found',
      Format('Collection %d not found', [CollectionID]));
end;

function ListCollections(const Args: TJSONObject): TJSONObject;
var
  Iterator: ICollectionInfoIterator;
  Info: TCollectionInfo;
  Arr: TJSONArray;
  Entry: TJSONObject;
begin
  Arr := TJSONArray.Create;
  try
    Iterator := SystemDB.GetCollectionInfoIterator;
    while Iterator.Next(Info) do
    begin
      Entry := TJSONObject.Create;
      Entry.AddPair('id', TJSONNumber.Create(Info.ID));
      Entry.AddPair('name', Info.DisplayName);
      Entry.AddPair('root_folder', Info.RootFolder);
      Entry.AddPair('type', TJSONNumber.Create(Info.CollectionType));
      Entry.AddPair('notes', Info.Notes);
      Arr.AddElement(Entry);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('collections', Arr);
end;

function ComposeAuthorFullName(const Author: TAuthorData): string;
begin
  Result := Author.LastName;

  if Author.FirstName <> '' then
  begin
    if Result <> '' then
      Result := Result + ' ' + Author.FirstName
    else
      Result := Author.FirstName;
  end;

  if Author.MiddleName <> '' then
  begin
    if Result <> '' then
      Result := Result + ' ' + Author.MiddleName
    else
      Result := Author.MiddleName;
  end;
end;

function AuthorsToJson(const Authors: TBookAuthors): TJSONArray;
var
  I: Integer;
  Entry: TJSONObject;
begin
  Result := TJSONArray.Create;
  try
    for I := 0 to High(Authors) do
    begin
      Entry := TJSONObject.Create;
      try
        Entry.AddPair('author_id', TJSONNumber.Create(Authors[I].AuthorID));
        Entry.AddPair('last_name', Authors[I].LastName);
        Entry.AddPair('first_name', Authors[I].FirstName);
        Entry.AddPair('middle_name', Authors[I].MiddleName);
        Entry.AddPair('full_name', ComposeAuthorFullName(Authors[I]));
      except
        Entry.Free;
        raise;
      end;
      Result.AddElement(Entry);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function GenresToJson(const Genres: TBookGenres): TJSONArray;
var
  I: Integer;
  Entry: TJSONObject;
begin
  Result := TJSONArray.Create;
  try
    for I := 0 to High(Genres) do
    begin
      Entry := TJSONObject.Create;
      try
        Entry.AddPair('code', Genres[I].GenreCode);
        Entry.AddPair('alias', Genres[I].GenreAlias);
      except
        Entry.Free;
        raise;
      end;
      Result.AddElement(Entry);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function BookToJson(const Book: TBookRecord; Full: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('book_id', TJSONNumber.Create(Book.BookKey.BookID));
    Result.AddPair('title', Book.Title);
    Result.AddPair('authors', AuthorsToJson(Book.Authors));
    Result.AddPair('genres', GenresToJson(Book.Genres));
    Result.AddPair('series', Book.Series);
    Result.AddPair('seq_number', TJSONNumber.Create(Book.SeqNumber));
    Result.AddPair('lang', Book.Lang);
    Result.AddPair('ext', Book.FileExt);
    Result.AddPair('size', TJSONNumber.Create(Book.Size));
    Result.AddPair('has_text',
      TJSONBool.Create(Book.GetBookFormat in [bfFb2, bfFb2Archive]));

    if Full then
    begin
      Result.AddPair('lib_rate', TJSONNumber.Create(Book.LibRate));
      Result.AddPair('rate', TJSONNumber.Create(Book.Rate));
      Result.AddPair('progress', TJSONNumber.Create(Book.Progress));
      Result.AddPair('keywords', Book.KeyWords);
      Result.AddPair('folder', Book.Folder);
      Result.AddPair('file_name', Book.FileName);
      Result.AddPair('annotation', Book.Annotation);
      Result.AddPair('review', Book.Review);
      Result.AddPair('is_local', TJSONBool.Create(bpIsLocal in Book.BookProps));
      Result.AddPair('is_deleted', TJSONBool.Create(bpIsDeleted in Book.BookProps));
      Result.AddPair('has_review', TJSONBool.Create(bpHasReview in Book.BookProps));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function GetBook(const Args: TJSONObject): TJSONObject;
var
  Collection: IBookCollection;
  CollectionID: Integer;
  BookKey: TBookKey;
  Book: TBookRecord;
begin
  CollectionID := RequireInt(Args, 'collection_id');
  Collection := CollectionOrFail(CollectionID);

  BookKey.BookID := RequireInt(Args, 'book_id');
  BookKey.DatabaseID := CollectionID;

  try
    Collection.GetBookRecord(BookKey, Book, True);
  except
    on E: Exception do
    begin
      LogToStderr(Format('GetBook(%d): %s', [BookKey.BookID, E.Message]));
      raise EMcpToolError.Create('book_not_found',
        Format('Book %d not found', [BookKey.BookID]));
    end;
  end;

  Result := BookToJson(Book, True);
end;

procedure ValidateFreeTextArg(const ArgName, Value: string);
const
  MaxLength = 4000;
begin
  if Pos(#0, Value) > 0 then
    raise EMcpToolError.Create('invalid_params',
      Format('Аргумент «%s» не может содержать символ NUL (U+0000)', [ArgName]));

  if Length(Value) > MaxLength then
    raise EMcpToolError.Create('invalid_params',
      Format('Аргумент «%s» слишком длинный (%d символов, максимум %d)',
        [ArgName, Length(Value), MaxLength]));
end;

function LiteralLikeCondition(const ArgName, Value: string): string;
const
  ChunkSize = 100;
  SQ = '''';
var
  Escaped: string;
  Codes, Terms: string;
  ChunkStart, ChunkEnd, I: Integer;
begin
  ValidateFreeTextArg(ArgName, Value);

  Escaped := Char.ToUpper(Value);
  Escaped := StringReplace(Escaped, '\', '\\', [rfReplaceAll]);
  Escaped := StringReplace(Escaped, '%', '\%', [rfReplaceAll]);
  Escaped := StringReplace(Escaped, '_', '\_', [rfReplaceAll]);
  Escaped := '%' + Escaped + '%';

  Terms := '';
  ChunkStart := 1;
  while ChunkStart <= Length(Escaped) do
  begin
    ChunkEnd := ChunkStart + ChunkSize - 1;
    if ChunkEnd > Length(Escaped) then
      ChunkEnd := Length(Escaped);

    Codes := '';
    for I := ChunkStart to ChunkEnd do
    begin
      if Codes <> '' then
        Codes := Codes + ',';
      Codes := Codes + IntToStr(Ord(Escaped[I]));
    end;

    if Terms <> '' then
      Terms := Terms + '||';
    Terms := Terms + 'CHAR(' + Codes + ')';

    ChunkStart := ChunkEnd + 1;
  end;

  Result := 'LIKE ' + Terms + ' ESCAPE ' + SQ + '\' + SQ;
end;

function SearchBooks(const Args: TJSONObject): TJSONObject;
type
  TFreeTextField = record
    ArgName: string;
    Target: PString;
  end;
var
  Collection: IBookCollection;
  Criteria: TBookSearchCriteria;
  Iterator: IBookIterator;
  Book: TBookRecord;
  Arr: TJSONArray;
  Limit, Offset, Skipped, Taken, MinRate: Integer;
  Clamped, ClampedAny: Boolean;
  Total: Integer;
  GenreCode: string;
  FreeTextFields: array[0..5] of TFreeTextField;
  FieldIdx: Integer;
  FieldValue: string;
begin
  Collection := CollectionOrFail(RequireInt(Args, 'collection_id'));

  Criteria := Default(TBookSearchCriteria);
  // The MCP API has always promised unique physical books. Keep that stable;
  // the desktop UI exposes the optional classic per-series expansion.
  Criteria.CollapseMultiSeriesResults := True;

  FreeTextFields[0].ArgName := 'title';      FreeTextFields[0].Target := @Criteria.Title;
  FreeTextFields[1].ArgName := 'author';     FreeTextFields[1].Target := @Criteria.FullName;
  FreeTextFields[2].ArgName := 'series';     FreeTextFields[2].Target := @Criteria.Series;
  FreeTextFields[3].ArgName := 'lang';       FreeTextFields[3].Target := @Criteria.Lang;
  FreeTextFields[4].ArgName := 'keyword';    FreeTextFields[4].Target := @Criteria.KeyWord;
  FreeTextFields[5].ArgName := 'annotation'; FreeTextFields[5].Target := @Criteria.Annotation;

  for FieldIdx := Low(FreeTextFields) to High(FreeTextFields) do
  begin
    FieldValue := ArgStr(Args, FreeTextFields[FieldIdx].ArgName);
    if FieldValue <> '' then
      FreeTextFields[FieldIdx].Target^ :=
        LiteralLikeCondition(FreeTextFields[FieldIdx].ArgName, FieldValue);
  end;

  //
  //
  GenreCode := ArgStr(Args, 'genre');
  if GenreCode <> '' then
  begin
    ValidateFreeTextArg('genre', GenreCode);
    Criteria.Genre := Format('g.GenreCode = ''%s''',
      [StringReplace(GenreCode, '''', '''''', [rfReplaceAll])]);
  end;
  Criteria.Deleted    := not ArgBool(Args, 'include_deleted', False);

  Criteria.DateIdx := -1;

  MinRate := ArgInt(Args, 'min_lib_rate', 0);
  if MinRate > 0 then
    Criteria.LibRate := Format('>= %d', [MinRate]);

  // PrepareSearchData создаёт обычное исключение с сообщением
  // rstrCheckFilterParams («Проверьте параметры фильтра»), если не удалось
  // построить ни одного условия WHERE. Это не EMcpToolError, поэтому без этой
  // проверки исключение дошло бы до клиента как JSON-RPC -32603 с внутренним
  // текстом DAO. Ситуация возникает, когда все поля выше пусты и одновременно
  // include_deleted=true: Criteria.Deleted=False не добавляет стандартный фильтр
  // b.IsDeleted = 0. Перехватываем условие заранее и возвращаем стабильную,
  // машиночитаемую ошибку предметной области.
  if (Criteria.Title = '') and (Criteria.FullName = '') and (Criteria.Series = '') and
     (Criteria.Genre = '') and (Criteria.Lang = '') and (Criteria.KeyWord = '') and
     (Criteria.Annotation = '') and (Criteria.LibRate = '') and (not Criteria.Deleted) then
    raise EMcpToolError.Create('empty_filter',
      'Укажите хотя бы один критерий поиска (title, author, series, genre, ' +
      'lang, keyword, annotation, min_lib_rate) или оставьте include_deleted ' +
      'без изменений (false).');

  Limit := ArgIntClamped(Args, 'limit', 25, 1, 200, ClampedAny);
  Offset := ArgIntClamped(Args, 'offset', 0, 0, MaxInt, Clamped);
  ClampedAny := ClampedAny or Clamped;

  Iterator := Collection.Search(Criteria, False);
  Total := Iterator.RecordCount;

  Arr := TJSONArray.Create;
  try
    Skipped := 0;
    Taken := 0;
    while Iterator.Next(Book) do
    begin
      if Skipped < Offset then
      begin
        Inc(Skipped);
        Continue;
      end;

      if Taken >= Limit then
        Break;

      Arr.AddElement(BookToJson(Book, False));
      Inc(Taken);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('books', Arr);
  Result.AddPair('total_count', TJSONNumber.Create(Total));
  Result.AddPair('has_more', TJSONBool.Create(Offset + Taken < Total));
  if ClampedAny then
    Result.AddPair('clamped', TJSONBool.Create(True));
end;

function ListGenres(const Args: TJSONObject): TJSONObject;
var
  Collection: IBookCollection;
  Iterator: IGenreIterator;
  Genre: TGenreData;
  Arr: TJSONArray;
  Entry: TJSONObject;
begin
  Collection := CollectionOrFail(RequireInt(Args, 'collection_id'));

  Arr := TJSONArray.Create;
  try
    Iterator := Collection.GetGenreIterator(gmAll, nil);
    while Iterator.Next(Genre) do
    begin
      Entry := TJSONObject.Create;
      try
        Entry.AddPair('code', Genre.GenreCode);
        Entry.AddPair('parent_code', Genre.ParentCode);
        Entry.AddPair('alias', Genre.GenreAlias);
      except
        Entry.Free;
        raise;
      end;
      Arr.AddElement(Entry);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('genres', Arr);
end;

//
function ListSeries(const Args: TJSONObject): TJSONObject;
var
  Collection: IBookCollection;
  Iterator: ISeriesIterator;
  Series: TSeriesData;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Filter: string;
  Limit, Taken: Integer;
  Clamped: Boolean;
begin
  Collection := CollectionOrFail(RequireInt(Args, 'collection_id'));
  Filter := ArgStr(Args, 'filter').ToLower;
  Limit := ArgIntClamped(Args, 'limit', 100, 1, 500, Clamped);

  Arr := TJSONArray.Create;
  try
    Taken := 0;
    Iterator := Collection.GetSeriesIterator(smAll);
    while Taken < Limit do
    begin
      if not Iterator.Next(Series) then
        Break;

      if (Filter <> '') and (not Series.SeriesTitle.ToLower.Contains(Filter)) then
        Continue;

      Entry := TJSONObject.Create;
      try
        Entry.AddPair('series_id', TJSONNumber.Create(Series.SeriesID));
        Entry.AddPair('title', Series.SeriesTitle);
      except
        Entry.Free;
        raise;
      end;
      Arr.AddElement(Entry);
      Inc(Taken);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('series', Arr);
  if Clamped then
    Result.AddPair('clamped', TJSONBool.Create(True));
end;

function ListAuthors(const Args: TJSONObject): TJSONObject;
var
  Collection: IBookCollection;
  Iterator: IAuthorIterator;
  Author: TAuthorData;
  Arr: TJSONArray;
  Entry: TJSONObject;
  Filter: string;
  FullName: string;
  Limit, Taken: Integer;
  Clamped: Boolean;
begin
  Collection := CollectionOrFail(RequireInt(Args, 'collection_id'));
  Filter := ArgStr(Args, 'filter').ToLower;
  Limit := ArgIntClamped(Args, 'limit', 100, 1, 500, Clamped);

  Arr := TJSONArray.Create;
  try
    Taken := 0;
    Iterator := Collection.GetAuthorIterator(amAll, nil);
    while Taken < Limit do
    begin
      if not Iterator.Next(Author) then
        Break;

      FullName := ComposeAuthorFullName(Author);
      if (Filter <> '') and (not FullName.ToLower.Contains(Filter)) then
        Continue;

      Entry := TJSONObject.Create;
      try
        Entry.AddPair('author_id', TJSONNumber.Create(Author.AuthorID));
        Entry.AddPair('full_name', FullName);
        Entry.AddPair('last_name', Author.LastName);
      except
        Entry.Free;
        raise;
      end;
      Arr.AddElement(Entry);
      Inc(Taken);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  Result.AddPair('authors', Arr);
  if Clamped then
    Result.AddPair('clamped', TJSONBool.Create(True));
end;

procedure RegisterLibraryTools(Server: TMcpServer);
begin
  Server.RegisterTool(
    'list_collections',
    'Список всех зарегистрированных коллекций HomeLibre.',
    TJSONObject.ParseJSONValue('{"type":"object","properties":{}}') as TJSONObject,
    Guarded(ListCollections));

  Server.RegisterTool(
    'get_book',
    'Полные сведения о книге по её идентификатору.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer","description":"ID коллекции"},' +
      '"book_id":{"type":"integer","description":"ID книги"}},' +
      '"required":["collection_id","book_id"]}') as TJSONObject,
    Guarded(GetBook));

  Server.RegisterTool(
    'search_books',
    'Поиск книг в коллекции по названию, автору, серии, жанру или языку. ' +
    'Текстовые поля (title, author, series, lang, keyword, annotation) ' +
    'ищут буквальную подстроку без учёта регистра; значения с NUL-символом ' +
    'или длиннее 4000 символов отклоняются с ошибкой invalid_params, а ' +
    'символы вне базовой многоязычной плоскости Unicode ' +
    '(например, эмодзи) никогда не совпадают.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer","description":"ID коллекции"},' +
      '"title":{"type":"string","description":"Подстрока названия (без учёта регистра; кавычки, % и _ ищутся буквально, не как спецсимволы)"},' +
      '"author":{"type":"string","description":"Полное или частичное имя автора (без учёта регистра, буквально)"},' +
      '"series":{"type":"string","description":"Подстрока названия серии (без учёта регистра, буквально)"},' +
      '"genre":{"type":"string","description":"Код жанра из списка list_genres"},' +
      '"lang":{"type":"string","description":"Подстрока кода языка (без учёта регистра, буквально)"},' +
      '"keyword":{"type":"string","description":"Подстрока ключевых слов (без учёта регистра, буквально)"},' +
      '"annotation":{"type":"string","description":"Подстрока аннотации (без учёта регистра, буквально)"},' +
      '"min_lib_rate":{"type":"integer","description":"Минимальный рейтинг книги (LibRate) — возвращает книги с таким рейтингом и выше"},' +
      '"include_deleted":{"type":"boolean"},' +
      '"limit":{"type":"integer","description":"По умолчанию 25, максимум 200"},' +
      '"offset":{"type":"integer","description":"Смещение для постраничного вывода; строки ' +
      'пропускаются по одной в Delphi, поэтому большой offset работает медленно ' +
      '(например, offset: 400000 занимает около 18 секунд)"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(SearchBooks));

  Server.RegisterTool(
    'list_genres',
    'Дерево жанров коллекции. Коды жанров нужны для search_books.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListGenres));

  Server.RegisterTool(
    'list_series',
    'Список серий в коллекции.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"filter":{"type":"string","description":"Подстрока названия серии"},' +
      '"limit":{"type":"integer","description":"По умолчанию 100, максимум 500"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListSeries));

  Server.RegisterTool(
    'list_authors',
    'Список авторов в коллекции.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"filter":{"type":"string","description":"Подстрока имени автора"},' +
      '"limit":{"type":"integer","description":"По умолчанию 100, максимум 500"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListAuthors));
end;

end.
