unit unit_MCP_Fixture;

interface

// Builds a small throwaway collection for tests/cases. Run as
//   MHLMcpServer.exe --make-fixture uselocaldata user mcpfixture
// and the server under test with the same switches: TMHLSettings.Create reads
// them in both processes, so both resolve <exedir>\Data\mcpfixture.dbs.
//
// DESTRUCTIVE: deletes a system database, settings file and collection folder;
// RequireFixtureTarget refuses to run without the switches.
procedure RunMakeFixtureMode;

const
  FIXTURE_USER_NAME = 'mcpfixture';

  FIXTURE_DISPLAY_NAME = 'MCP Fixture';

  // The trailing separator is required: GetBookFormat classifies a row as
  // bfFb2 only when the container path ends in a separator.
  FIXTURE_FOLDER = 'books\';

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  System.DateUtils,
  dm_user,
  unit_Settings,
  unit_Globals,
  unit_Consts,
  unit_Interfaces,
  unit_MCP_Transport;

const
  FIXTURE_COLLECTION_TYPE = CONTENT_FB or LIBRARY_PRIVATE or LOCATION_LOCAL;

function WriteFixtureBook(
  const Folder: string;
  const BaseName: string;
  const BookTitle: string;
  const Sections: TArray<string>
): Integer;
var
  Body: string;
  Text: string;
  I: Integer;
  FullPath: string;
  Bytes: TBytes;
begin
  Body := '';
  if Length(Sections) = 0 then
    Body := '<section><p>Текст без розділів.</p></section>'
  else
    for I := 0 to High(Sections) do
      Body := Body +
        '<section><title><p>' + Sections[I] + '</p></title>' +
        '<p>Абзац розділу ' + IntToStr(I + 1) + '.</p></section>';

  Text :=
    '<?xml version="1.0" encoding="utf-8"?>' + sLineBreak +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' + sLineBreak +
    ' <description><title-info><book-title>' + BookTitle +
    '</book-title></title-info></description>' + sLineBreak +
    ' <body>' + Body + '</body>' + sLineBreak +
    '</FictionBook>' + sLineBreak;

  FullPath := TPath.Combine(Folder, BaseName + '.fb2');
  Bytes := TEncoding.UTF8.GetBytes(Text);
  TFile.WriteAllBytes(FullPath, Bytes);
  Result := Length(Bytes);
end;

// Genres by FB2 code: InsertBook maps them through the genre cache.
function AddFixtureBook(
  const Collection: IBookCollection;
  const Root: string;
  const BaseName: string;
  const BookTitle: string;
  const LastName, FirstName: string;
  const Series: string;
  SeqNumber: Integer;
  const FB2Genre: string;
  const Lang: string;
  LibRate: Integer;
  IsDeleted: Boolean;
  const Sections: TArray<string>
): Integer;
var
  Book: TBookRecord;
  BooksDir: string;
begin
  BooksDir := TPath.Combine(Root, ExcludeTrailingPathDelimiter(FIXTURE_FOLDER));
  TDirectory.CreateDirectory(BooksDir);

  Book.Clear;
  Book.Title := BookTitle;
  Book.Folder := FIXTURE_FOLDER;
  Book.FileName := BaseName;
  Book.FileExt := FB2_EXTENSION;
  Book.Series := Series;
  Book.SeqNumber := SeqNumber;
  Book.Lang := Lang;
  Book.LibRate := LibRate;
  Book.LibID := BaseName;
  Book.Date := EncodeDate(2026, 1, 1);
  Book.CollectionRoot := Root;

  SetLength(Book.Authors, 1);
  Book.Authors[0].LastName := LastName;
  Book.Authors[0].FirstName := FirstName;
  Book.Authors[0].MiddleName := '';

  SetLength(Book.Genres, 1);
  Book.Genres[0].FB2GenreCode := FB2Genre;

  Include(Book.BookProps, bpIsLocal);
  if IsDeleted then
    Include(Book.BookProps, bpIsDeleted);

  Book.Size := WriteFixtureBook(BooksDir, BaseName, BookTitle, Sections);

  Result := Collection.InsertBook(Book, False, False);
end;

// Without `user mcpfixture` the paths fall back to the real user.dbs2 /
// myhomelib2.ini, and the wipe would destroy the user's library data with no
// undo. Checked per target so a later edit cannot quietly un-scope one.
procedure RequireFixtureTarget(const Target: string);
begin
  if not SameText(
       ChangeFileExt(ExtractFileName(ExcludeTrailingPathDelimiter(Target)), ''),
       FIXTURE_USER_NAME)
  then
    raise Exception.CreateFmt(
      '--make-fixture refuses to run against %s. It must be invoked as ' +
      '"MHLMcpServer.exe --make-fixture uselocaldata user %s"; without those ' +
      'switches it would delete the real system database.',
      [Target, FIXTURE_USER_NAME]);
end;

procedure RunMakeFixtureMode;
var
  DbFileName: string;
  IniFileName: string;
  RootFolder: string;
  CollectionFile: string;
  CollectionID: Integer;
  Summary: TJSONObject;
  Transport: TMcpTransport;
  Collection: IBookCollection;
  Books: TJSONArray;
  Entry: TJSONObject;
  I: Integer;
  Ids: TArray<Integer>;
  Titles: TArray<string>;
begin
  if not Assigned(DMUser) then
    DMUser := TDMUser.Create(nil);

  DbFileName := DMUser.Settings.SystemFileName[sfSystemDB];
  IniFileName := DMUser.Settings.SettingsFileName;
  RootFolder := TPath.Combine(ExtractFilePath(ParamStr(0)), FIXTURE_USER_NAME);
  CollectionFile := TPath.Combine(RootFolder, FIXTURE_USER_NAME + '.hlc2');

  RequireFixtureTarget(DbFileName);
  RequireFixtureTarget(IniFileName);
  RequireFixtureTarget(RootFolder);

  // Fresh databases give collection id 1 and book ids 1.. in insertion order;
  // tests/cases depend on that.
  if TFile.Exists(DbFileName) then
    TFile.Delete(DbFileName);
  if TDirectory.Exists(RootFolder) then
    TDirectory.Delete(RootFolder, True);
  TDirectory.CreateDirectory(RootFolder);

  // TMHLSettings.Create (inside TDMUser.Create) copies myhomelib2.ini to a
  // missing mcpfixture.ini, and the server process would do so again, so the
  // fixture would inherit the developer's settings. An empty file is never
  // re-seeded and yields LoadSettings defaults; it must be written here,
  // between TDMUser.Create and DMUser.Init.
  if TFile.Exists(IniFileName) then
    TFile.Delete(IniFileName);
  TFile.WriteAllBytes(IniFileName, TEncoding.UTF8.GetBytes(
    '; Generated by MHLMcpServer --make-fixture. Deliberately empty: the' + sLineBreak +
    '; fixture must run on LoadSettings'' defaults, never on a copy of the' + sLineBreak +
    '; developer''s myhomelib2.ini. Do not populate.' + sLineBreak));

  DMUser.Init;

  // Not Settings.SystemFileName[sfGenresFB2]: that one is per UI locale, and
  // the tests assert on genre aliases byte-for-byte.
  CollectionID := SystemDB.CreateCollection(
    FIXTURE_DISPLAY_NAME,
    RootFolder,
    CollectionFile,
    FIXTURE_COLLECTION_TYPE,
    DMUser.Settings.AppPath + GENRES_FB2_FILENAME
  );

  if CollectionID <> 1 then
    raise Exception.CreateFmt(
      'Fixture collection was registered as id %d, expected 1. ' +
      'The previous system database at %s was not removed.',
      [CollectionID, DbFileName]);

  Collection := SystemDB.GetCollection(CollectionID);

  SetLength(Ids, 6);
  SetLength(Titles, 6);

  Titles[0] := 'Тихий вечер';
  Ids[0] := AddFixtureBook(Collection, RootFolder, 'book1', Titles[0],
    'Іваненко', 'Петро', 'Хроніки', 1, 'prose_contemporary', 'uk', 0, False,
    ['Розділ перший', 'Розділ другий']);

  Titles[1] := 'Гроза 100% певна';
  Ids[1] := AddFixtureBook(Collection, RootFolder, 'book2', Titles[1],
    'Іваненко', 'Петро', 'Хроніки', 2, 'prose_contemporary', 'uk', 4, False,
    ['Вступ', 'Середина', 'Кінець']);

  Titles[2] := 'Пісня_про_море';
  Ids[2] := AddFixtureBook(Collection, RootFolder, 'book3', Titles[2],
    'Ковальчук', 'Ольга', '', 0, 'sf_action', 'uk', 0, False, []);

  Titles[3] := 'О''Генрі та інші';
  Ids[3] := AddFixtureBook(Collection, RootFolder, 'book4', Titles[3],
    'Ковальчук', 'Ольга', 'Збірка "Класика"', 1, 'love_history', 'ru', 5, False, []);

  Titles[4] := 'Книга з "лапками"';
  Ids[4] := AddFixtureBook(Collection, RootFolder, 'book5', Titles[4],
    'Шевченко', 'Іван', '', 0, 'sf_action', 'en', 0, False, []);

  Titles[5] := 'Вилучена книга';
  Ids[5] := AddFixtureBook(Collection, RootFolder, 'book6', Titles[5],
    'Шевченко', 'Іван', '', 0, 'prose_contemporary', 'uk', 0, True, []);

  Summary := TJSONObject.Create;
  try
    Summary.AddPair('collection_id', TJSONNumber.Create(CollectionID));
    Summary.AddPair('root', RootFolder);
    Summary.AddPair('db', DbFileName);

    Books := TJSONArray.Create;
    for I := 0 to 5 do
    begin
      if Ids[I] <> I + 1 then
        raise Exception.CreateFmt(
          'Fixture book %d was inserted as id %d; expected %d. ' +
          'The collection file was not removed before this run.',
          [I + 1, Ids[I], I + 1]);

      Entry := TJSONObject.Create;
      Entry.AddPair('book_id', TJSONNumber.Create(Ids[I]));
      Entry.AddPair('title', Titles[I]);
      Entry.AddPair('path', TPath.Combine(
        TPath.Combine(RootFolder, ExcludeTrailingPathDelimiter(FIXTURE_FOLDER)),
        'book' + IntToStr(I + 1) + '.fb2'));
      Books.AddElement(Entry);
    end;
    Summary.AddPair('books', Books);

    Transport := TMcpTransport.Create;
    try
      Transport.WriteMessage(Summary.ToJSON);
    finally
      Transport.Free;
    end;
  finally
    Summary.Free;
  end;
end;

end.
