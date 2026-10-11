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

// Exceptions can carry build-machine paths: log detail here, send the client
// a sanitized message.
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

// Refusing when the system DB file is missing keeps TDMUser.Init from ever
// creating it. SystemFileName is valid right after TDMUser.Create: path fields
// are set in the TMHLSettings constructor, LoadSettings never changes them.
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
      Format('Системну базу даних MyHomeLib не знайдено за шляхом: %s. ' +
        'Запустіть MyHomeLib хоча б один раз, щоб її створити.',
        [SysDBFileName]));

  DMUser.Init;
  GLibraryInitialized := True;
end;

// SQLiteWrap has no read-only or busy-timeout mode, so a write by the running
// app surfaces as "database is locked". EnsureLibraryInitialized is inside the
// try because TDMUser.Init opens the DB and can hit the same lock.
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
              'Колекція зайнята — можливо, MyHomeLib саме імпортує книги.');
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

// Not TAuthorData.GetFullName: it asserts LastName <> '', and assertions are
// on in Release, so a blank last name would leak a build-machine path.
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
  // Once AddPair succeeds Result owns the array; do not free it separately.
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

// A NUL is a terminator inside SQLite (truncating the pattern/statement), so it
// is rejected, not encoded. Overlong values hit SQLite's LIKE length limit,
// whose error message carries the whole generated SQL.
procedure ValidateFreeTextArg(const ArgName, Value: string);
const
  MaxLength = 4000;
begin
  if Pos(#0, Value) > 0 then
    raise EMcpToolError.Create('invalid_params',
      Format('Аргумент "%s" не може містити символ NUL (U+0000)', [ArgName]));

  if Length(Value) > MaxLength then
    raise EMcpToolError.Create('invalid_params',
      Format('Аргумент "%s" задовгий (%d символів, максимум %d)',
        [ArgName, Length(Value), MaxLength]));
end;

// Matches Value as a literal, case-insensitive substring. PrepareQuery and
// AddToFilter (unit_Database_SQLite.PrepareSearchData) splice caller text into
// the WHERE clause unescaped and text-search it for operator tokens, so Value
// is rendered as CHAR(code, ...) calls: no caller character, quote or
// operator-shaped substring reaches the SQL text. Our own 'LIKE' keyword makes
// PrepareQuery pass the string through.
//
// Chunks of 100 codes per CHAR(): SQLITE_MAX_FUNCTION_ARG defaults to 127.
//
// The column side is precomputed by MHL_UPPER (Char.ToUpper), and PrepareQuery
// cannot uppercase encoded codes, so Value is uppercased with the same function.
//
// MaxLength 4000 is well under ~24900 chars, where this construction hits
// SQLite's 50000-byte LIKE pattern limit.
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

// RecordCount is read once: the SQLite iterators assert on a second call.
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

  // genre is not in this loop: it needs an equality, not a LIKE pattern.
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

  // PrepareSearchData splices Genre verbatim into the WHERE clause, so a bare
  // code is not valid SQL. Single quotes, not frm_main's double quotes: SQLite
  // resolves a double-quoted token as an identifier first, so genre "GenreCode"
  // would compare the column to itself and match every row.
  GenreCode := ArgStr(Args, 'genre');
  if GenreCode <> '' then
  begin
    ValidateFreeTextArg('genre', GenreCode);
    Criteria.Genre := Format('g.GenreCode = ''%s''',
      [StringReplace(GenreCode, '''', '''''', [rfReplaceAll])]);
  end;
  // Inverted: Criteria.Deleted means "hide deleted" (filter b.IsDeleted = 0).
  Criteria.Deleted    := not ArgBool(Args, 'include_deleted', False);

  // DateIdx 0 means "modified in the last day"; -1 skips date filtering.
  Criteria.DateIdx := -1;

  // A plain number would become an exact match ="N". '>= N' gives a minimum;
  // AddToFilter's ' >' token splices in the column name. MinRate is our own
  // IntToStr, so no escaping is needed.
  MinRate := ArgInt(Args, 'min_lib_rate', 0);
  if MinRate > 0 then
    Criteria.LibRate := Format('>= %d', [MinRate]);

  // With every field blank and include_deleted=true, PrepareSearchData raises a
  // plain Exception whose DAO text would leak as -32603; fail with a domain
  // error first.
  if (Criteria.Title = '') and (Criteria.FullName = '') and (Criteria.Series = '') and
     (Criteria.Genre = '') and (Criteria.Lang = '') and (Criteria.KeyWord = '') and
     (Criteria.Annotation = '') and (Criteria.LibRate = '') and (not Criteria.Deleted) then
    raise EMcpToolError.Create('empty_filter',
      'Вкажіть хоча б один критерій пошуку (title, author, series, genre, ' +
      'lang, keyword, annotation, min_lib_rate) або залиште include_deleted ' +
      'без змін (false).');

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

// Unpaged: these codes are the only way to discover search_books' genre values.
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

// Limit is checked before Iterator.Next so no record is fetched and discarded.
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
    'Список усіх зареєстрованих колекцій MyHomeLib.',
    TJSONObject.ParseJSONValue('{"type":"object","properties":{}}') as TJSONObject,
    Guarded(ListCollections));

  Server.RegisterTool(
    'get_book',
    'Повні відомості про книгу за її ідентифікатором.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer","description":"ID колекції"},' +
      '"book_id":{"type":"integer","description":"ID книги"}},' +
      '"required":["collection_id","book_id"]}') as TJSONObject,
    Guarded(GetBook));

  Server.RegisterTool(
    'search_books',
    'Пошук книг у колекції за назвою, автором, серією, жанром чи мовою. ' +
    'Текстові поля (title, author, series, lang, keyword, annotation) ' +
    'шукають буквальний підрядок без урахування регістру; значення з ' +
    'NUL-символом або довші за 4000 символів відхиляються помилкою ' +
    'invalid_params, а символи поза базовою багатомовною площиною Unicode ' +
    '(наприклад, емодзі) ніколи не збігаються.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer","description":"ID колекції"},' +
      '"title":{"type":"string","description":"Підрядок назви (без урахування регістру; лапки, % та _ шукаються буквально, не як спецсимволи)"},' +
      '"author":{"type":"string","description":"Повне або часткове ім''я автора (без урахування регістру, буквально)"},' +
      '"series":{"type":"string","description":"Підрядок назви серії (без урахування регістру, буквально)"},' +
      '"genre":{"type":"string","description":"Код жанру зі списку list_genres"},' +
      '"lang":{"type":"string","description":"Підрядок коду мови (без урахування регістру, буквально)"},' +
      '"keyword":{"type":"string","description":"Підрядок ключових слів (без урахування регістру, буквально)"},' +
      '"annotation":{"type":"string","description":"Підрядок анотації (без урахування регістру, буквально)"},' +
      '"min_lib_rate":{"type":"integer","description":"Мінімальний рейтинг книги (LibRate) -- повертає книги з таким рейтингом і вище"},' +
      '"include_deleted":{"type":"boolean"},' +
      '"limit":{"type":"integer","description":"Типово 25, максимум 200"},' +
      '"offset":{"type":"integer","description":"Зсув для пагінації; рядки ' +
      'пропускаються по одному в Delphi, тож великий offset повільний ' +
      '(наприклад, offset: 400000 займає близько 18 секунд)"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(SearchBooks));

  Server.RegisterTool(
    'list_genres',
    'Дерево жанрів колекції. Коди жанрів потрібні для search_books.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListGenres));

  Server.RegisterTool(
    'list_series',
    'Перелік серій у колекції.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"filter":{"type":"string","description":"Підрядок назви серії"},' +
      '"limit":{"type":"integer","description":"Типово 100, максимум 500"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListSeries));

  Server.RegisterTool(
    'list_authors',
    'Перелік авторів у колекції.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"filter":{"type":"string","description":"Підрядок імені автора"},' +
      '"limit":{"type":"integer","description":"Типово 100, максимум 500"}},' +
      '"required":["collection_id"]}') as TJSONObject,
    Guarded(ListAuthors));
end;

end.
