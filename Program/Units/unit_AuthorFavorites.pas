unit unit_AuthorFavorites;

interface

uses
  System.SysUtils, System.Generics.Collections, unit_Globals;

const
  AUTHOR_FAVORITES_FILE_NAME = 'author-favorites.sqlite';

type
  EAuthorFavorites = class(Exception);
  EAuthorFavoritesCanceled = class(EAuthorFavorites);
  EAuthorFavoritesBusy = class(EAuthorFavorites);
  TAuthorFavoritesCanceled = reference to function: Boolean;
  TAuthorFavoritesProgress = reference to procedure(AuthorsDone, AuthorsTotal, BooksRead: Integer);

  TAuthorFavoriteEntry = record
    Key, LastName, FirstName, MiddleName, CreatedUTC: string;
    function DisplayName: string;
  end;

  TAuthorFavoriteCollection = record
    ID: Integer;
    DatabaseFile, RootFolder, LibraryNamespace, Revision: string;
  end;

  TAuthorFavoriteState = record
    HasBaseline: Boolean;
    BookCount, NewCount: Integer;
  end;

  // One instance belongs to one thread. Background refreshes create their own
  // instance; the UI calls Reload after the worker commits. Book clicks only
  // consult the in-memory author set, never a database or a book file.
  TAuthorFavorites = class
  private
    FFileName: string;
    FEntries: TArray<TAuthorFavoriteEntry>;
    FKeys: TDictionary<string, Boolean>;
    FBindings: TDictionary<Integer, TArray<Integer>>;
    FStates: TDictionary<string, TAuthorFavoriteState>;
    FNewCounts: TDictionary<Integer, Integer>;
    FRevisions: TDictionary<Integer, string>;
    FOperationCanceled: TAuthorFavoritesCanceled;
    function CancelRequested: Boolean;
    procedure CheckCanceled;
  public
    constructor Create(const ProfileFile: string);
    destructor Destroy; override;
    procedure Reload;
    procedure SetFavorite(const LastName, FirstName, MiddleName: string; Enabled: Boolean);
    procedure ImportFavorites(const Authors: TArray<TAuthorFavoriteEntry>);
    function IsFavorite(const LastName, FirstName, MiddleName: string): Boolean; overload;
    function IsFavorite(const Author: TAuthorData): Boolean; overload;
    function MatchesAuthors(const Authors: TBookAuthors): Boolean;
    function Entries: TArray<TAuthorFavoriteEntry>;
    function Keys: TArray<string>;
    function BoundAuthorIDs(CollectionID: Integer): TArray<Integer>;
    function State(CollectionID: Integer; const AuthorKey: string): TAuthorFavoriteState;
    function NewCount(CollectionID: Integer; const AuthorKey: string = ''): Integer;
    function CollectionRevision(CollectionID: Integer): string;
    function NewBookIDs(CollectionID: Integer; const AuthorKey: string = ''): TArray<Integer>;
    procedure RefreshCollection(const Collection: TAuthorFavoriteCollection;
      const Canceled: TAuthorFavoritesCanceled = nil;
      const Progress: TAuthorFavoritesProgress = nil);
    procedure MarkViewed(CollectionID: Integer; const AuthorKey: string = '';
      const Canceled: TAuthorFavoritesCanceled = nil);
    property FileName: string read FFileName;
  end;

function AuthorFavoriteKey(const LastName, FirstName, MiddleName: string): string;
// Pure scalar metadata: no file probes, decompression or per-book copy query.
function AuthorFavoriteBookKey(CollectionID: Integer;
  const LibID, Folder, FileName, Extension, Title, Language, LibraryNamespace: string): string;

implementation

uses
  Winapi.Windows, System.Classes, System.IOUtils, System.Hash, System.DateUtils,
  SQLite3, SQLiteWrap, unit_FileMutex, unit_LibrarySourceID;

const
  AF_APPLICATION_ID = $484D4146; // HMAF, private file, never an existing user DB.
  AF_SCHEMA_VERSION = 1;
  AF_MAX_FAVORITES = 4096;
  AF_MAX_BINDINGS = 1048576;
  AF_MAX_REFRESH_ROWS = 10000000;
  AF_MAX_MERGED_DEPTH = 32;
  AF_MAX_FILE_SIZE = Int64(512) * 1024 * 1024;

  AF_TABLE_SCHEMA: array[0..5] of string = (
    'CREATE TABLE FavoriteAuthors(AuthorKey TEXT PRIMARY KEY NOT NULL, LastName TEXT NOT NULL, '
      +'FirstName TEXT NOT NULL, MiddleName TEXT NOT NULL, CreatedUTC TEXT NOT NULL) WITHOUT ROWID',
    'CREATE TABLE Collections(CID INTEGER PRIMARY KEY, Revision TEXT NOT NULL, NewCount INTEGER NOT NULL DEFAULT 0, UpdatedUTC TEXT NOT NULL)',
    'CREATE TABLE CollectionAuthorState(CID INTEGER NOT NULL, AuthorKey TEXT NOT NULL, Baseline INTEGER NOT NULL DEFAULT 0, '
      +'BookCount INTEGER NOT NULL DEFAULT 0, NewCount INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(CID,AuthorKey), '
      +'FOREIGN KEY(AuthorKey) REFERENCES FavoriteAuthors(AuthorKey) ON DELETE CASCADE) WITHOUT ROWID',
    'CREATE TABLE AuthorBindings(CID INTEGER NOT NULL, AuthorKey TEXT NOT NULL, AuthorID INTEGER NOT NULL, PRIMARY KEY(CID,AuthorKey,AuthorID), '
      +'FOREIGN KEY(CID,AuthorKey) REFERENCES CollectionAuthorState(CID,AuthorKey) ON DELETE CASCADE) WITHOUT ROWID',
    'CREATE TABLE CurrentBooks(CID INTEGER NOT NULL, AuthorKey TEXT NOT NULL, BookKey TEXT NOT NULL, BookID INTEGER NOT NULL, '
      +'PRIMARY KEY(CID,AuthorKey,BookKey,BookID), FOREIGN KEY(CID,AuthorKey) REFERENCES CollectionAuthorState(CID,AuthorKey) ON DELETE CASCADE) WITHOUT ROWID',
    'CREATE TABLE SeenBooks(CID INTEGER NOT NULL, AuthorKey TEXT NOT NULL, BookKey TEXT NOT NULL, PRIMARY KEY(CID,AuthorKey,BookKey), '
      +'FOREIGN KEY(CID,AuthorKey) REFERENCES CollectionAuthorState(CID,AuthorKey) ON DELETE CASCADE) WITHOUT ROWID'
  );

  AF_AUTHOR_LOOKUP = 'SELECT AuthorID,LastName,FirstName,MiddleName FROM Authors '
    + 'INDEXED BY IXAuthors_FullName WHERE LastName=? AND FirstName IS ? AND MiddleName IS ?';
  AF_BOOK_LOOKUP = 'SELECT b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,b.Title,b.Lang '
    + 'FROM Author_List al INDEXED BY IXAuthorList_AuthorID_BookID '
    + 'JOIN Books b ON b.BookID=al.BookID WHERE al.AuthorID=? AND b.IsDeleted=0';
  AF_UNSEEN = 'NOT EXISTS(SELECT 1 FROM SeenBooks s WHERE s.CID=c.CID '
    + 'AND s.AuthorKey=c.AuthorKey AND s.BookKey=c.BookKey)';

type
  TAFDatabase = class;
  TAFQuery = class
  private
    FDatabase: TAFDatabase;
    FStatement: TSQLiteStmt;
  public
    constructor Create(Database: TAFDatabase; const SQL: string;
      const Params: array of const);
    destructor Destroy; override;
    procedure Bind(const Params: array of const);
    function Next: Boolean;
    procedure Execute;
    function Text(Index: Integer): string;
    function Number(Index: Integer): Int64;
  end;

  TAFDatabase = class
  private
    FHandle: TSQLite3DB;
  public
    constructor Create(const FileName: string; ReadOnly, NewFile: Boolean);
    destructor Destroy; override;
    procedure Check(Code: Integer);
    procedure Execute(const SQL: string; const Params: array of const); overload;
    procedure Execute(const SQL: string); overload;
    function Number(const SQL: string; const Params: array of const): Int64; overload;
    function Number(const SQL: string): Int64; overload;
    function Text(const SQL: string): string;
    procedure Rollback;
    property Handle: TSQLite3DB read FHandle;
  end;

function InvariantLower(const Value: string): string;
var Count: Integer;
begin
  if Value='' then Exit('');
  Count:=LCMapStringEx('',LCMAP_LOWERCASE,PChar(Value),Length(Value),nil,0,nil,nil,0);
  if Count=0 then RaiseLastOSError;
  SetLength(Result,Count);
  if LCMapStringEx('',LCMAP_LOWERCASE,PChar(Value),Length(Value),PChar(Result),Count,nil,nil,0)=0 then
    RaiseLastOSError;
end;

function KeyPart(const Value: string): string;
begin
  Result:=IntToStr(Length(Value))+':'+Value;
end;

function CanonicalName(const Value: string): string;
begin
  if (Length(Value)>2048) or (Pos(#0,Value)<>0) then
    raise EAuthorFavorites.Create('Слишком длинное или некорректное имя автора.');
  Result:=InvariantLower(Trim(Value));
end;

function AuthorFavoriteKey(const LastName, FirstName, MiddleName: string): string;
var Last, First, Middle: string;
begin
  Last:=CanonicalName(LastName); First:=CanonicalName(FirstName); Middle:=CanonicalName(MiddleName);
  if Last='' then Exit('');
  Result:=THashSHA2.GetHashString('author-v1:'+KeyPart(Last)+KeyPart(First)+KeyPart(Middle));
end;

function IsNumericID(const Value: string): Boolean;
var C: Char;
begin
  Result:=Value<>'';
  for C in Value do if not CharInSet(C,['0'..'9']) then Exit(False);
end;

function AuthorFavoriteBookKey(CollectionID: Integer;
  const LibID, Folder, FileName, Extension, Title, Language, LibraryNamespace: string): string;
var RawID, Namespace, OriginalID, Provenance, Physical, Ext: string; Separator, Depth: Integer;
  Merged, KnownLibrary: Boolean;
begin
  if CollectionID<=0 then raise EAuthorFavorites.Create('Не указана коллекция для любимых авторов.');
  if (Length(LibID)>8192) or (Length(Folder)>32767) or (Length(FileName)>32767) or
    (Length(Title)>8192) or (Length(Extension)>128) or (Length(Language)>128) then
    raise EAuthorFavorites.Create('Некорректные данные книги в коллекции.');
  RawID:=LibID; Provenance:=''; Depth:=0; Merged:=RawID.StartsWith('merged:',True);
  while RawID.StartsWith('merged:',True) do
  begin
    Inc(Depth);
    if Depth>AF_MAX_MERGED_DEPTH then
      raise EAuthorFavorites.Create('Слишком глубокая цепочка источников книги. Последняя проверка любимых авторов сохранена.');
    Delete(RawID,1,7); Separator:=Pos(':',RawID);
    if Separator>0 then
    begin
      // Every origin in an unknown merged chain matters. Length prefixes make
      // chains unambiguous even when source IDs contain punctuation.
      Provenance:=Provenance+KeyPart(Copy(RawID,1,Separator-1));
      Delete(RawID,1,Separator);
    end
    else
    begin Provenance:=Provenance+KeyPart(RawID); RawID:=''; end;
  end;
  KnownLibrary:=TryParseLibrarySourceID(RawID,Namespace,OriginalID);
  if not KnownLibrary and not Merged then
  begin
    Namespace:=InvariantLower(Trim(LibraryNamespace)); OriginalID:=RawID;
    KnownLibrary:=((Namespace='flibusta') or (Namespace='librusec')) and IsNumericID(RawID);
  end;
  Ext:=InvariantLower(Trim(Extension));
  if (Ext<>'') and (Ext[1]<>'.') then Ext:='.'+Ext;
  if KnownLibrary then
    // Same numeric ID in another library or format is another book.
    // A trusted library ID survives ordinary title/publisher/language repairs.
    // Format stays part of identity, so another edition format is independent.
    Result:='library-v1:'+KeyPart(Namespace)+KeyPart(OriginalID)+KeyPart(Ext)
  else
  begin
    // Unknown origins are never equated by numeric LIBID. Folder/member metadata
    // stays stable across AuthorID/BookID remaps and moving the collection root.
    Physical:=InvariantLower(StringReplace(Folder,'/','\',[rfReplaceAll]));
    Physical:=KeyPart(Physical)+KeyPart(InvariantLower(StringReplace(FileName,'/','\',[rfReplaceAll])))+KeyPart(Ext);
    if Trim(FileName)='' then Physical:=Physical+KeyPart(RawID)+KeyPart(InvariantLower(Trim(Title)));
    Result:='physical-v1:'+KeyPart(IntToStr(CollectionID))+KeyPart(Provenance)+Physical;
  end;
  Result:=THashSHA2.GetHashString(Result);
end;

function TAuthorFavoriteEntry.DisplayName: string;
begin
  Result:=TAuthorData.FormatName(LastName,FirstName,MiddleName);
end;

function StateKey(CollectionID: Integer; const Key: string): string;
begin Result:=IntToStr(CollectionID)+':'+Key; end;

function UTCStamp: string;
begin Result:=FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',TTimeZone.Local.ToUniversalTime(Now)); end;

procedure CheckSafeFile(const FileName: string; AllowMissing: Boolean; LimitSize: Boolean);
var Path: string; Attributes: DWORD; Data: WIN32_FILE_ATTRIBUTE_DATA; Size: Int64;
begin
  if (FileName='') or (Pos(#0,FileName)<>0) then
    raise EAuthorFavorites.Create('Не указан файл любимых авторов.');
  Path:=TPath.GetFullPath(FileName);
  Attributes:=GetFileAttributes(PChar(Path));
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    if not AllowMissing or not (GetLastError in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then
      raise EAuthorFavorites.Create('Не удалось открыть файл любимых авторов: '+Path);
  end
  else
  begin
    if Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then
      raise EAuthorFavorites.Create('Файл любимых авторов не должен быть папкой или ссылкой.');
    if LimitSize then
    begin
      if not GetFileAttributesEx(PChar(Path),GetFileExInfoStandard,@Data) then RaiseLastOSError;
      Size:=(Int64(Data.nFileSizeHigh) shl 32) or Data.nFileSizeLow;
      if Size>AF_MAX_FILE_SIZE then
        raise EAuthorFavorites.Create('Файл любимых авторов слишком велик. Он сохранён без изменений.');
    end;
  end;
  // The user-selected profile may live below a junction, redirected Documents
  // or a cloud folder. Those parents are valid locations, not favorite files.
  // Keep checking the actual file and its private SQLite schema before writes.
end;

constructor TAFDatabase.Create(const FileName: string; ReadOnly, NewFile: Boolean);
var Flags: Integer; Name: UTF8String;
begin
  inherited Create; FHandle:=nil;
  if ReadOnly then Flags:=SQLITE_OPEN_READONLY
  else begin Flags:=SQLITE_OPEN_READWRITE; if NewFile then Flags:=Flags or SQLITE_OPEN_CREATE; end;
  Name:=UTF8String(FileName);
  Check(SQLite3_Open_v2(PUTF8Char(Name),FHandle,Flags or SQLITE_OPEN_PRIVATECACHE,nil));
  SQLite3_BusyTimeout(FHandle,0);
  Execute('PRAGMA cache_size=-2048'); Execute('PRAGMA mmap_size=0');
  if ReadOnly then Execute('PRAGMA query_only=ON')
  else
  begin
    Execute('PRAGMA synchronous=FULL'); Execute('PRAGMA foreign_keys=ON');
    if NewFile then Execute('PRAGMA journal_mode=DELETE');
  end;
end;

destructor TAFDatabase.Destroy;
begin
  if FHandle<>nil then SQLite3_Close(FHandle);
  inherited;
end;

procedure TAFDatabase.Check(Code: Integer);
var Message: string;
begin
  if Code=SQLITE_OK then Exit;
  if Code in [SQLITE_BUSY,SQLITE_LOCKED] then
    raise EAuthorFavoritesBusy.Create('Любимые авторы сейчас обновляются. Повторите действие после завершения.');
  if Code=SQLITE_INTERRUPT then
    raise EAuthorFavoritesCanceled.Create('Обновление любимых авторов отменено.');
  if FHandle<>nil then Message:=string(UTF8String(SQLite3_ErrMsg(FHandle))) else Message:=IntToStr(Code);
  raise EAuthorFavorites.Create('Не удалось обработать любимых авторов: '+Message);
end;

constructor TAFQuery.Create(Database: TAFDatabase; const SQL: string; const Params: array of const);
var Tail: PUTF8Char; Text: UTF8String;
begin
  inherited Create; FDatabase:=Database; FStatement:=nil; Tail:=nil; Text:=UTF8String(SQL);
  FDatabase.Check(SQLite3_Prepare_v2(Database.Handle,PUTF8Char(Text),Length(Text)+1,FStatement,Tail));
  Bind(Params);
end;

destructor TAFQuery.Destroy;
begin if FStatement<>nil then SQLite3_Finalize(FStatement); inherited; end;

procedure TAFQuery.Bind(const Params: array of const);
var I, Code: Integer; Text: string; Empty: WideChar; TextPointer: PWideChar;
begin
  FDatabase.Check(SQLite3_Reset(FStatement)); FDatabase.Check(SQLite3_clear_bindings(FStatement));
  for I:=0 to High(Params) do
  begin
    case Params[I].VType of
      vtInteger: Code:=SQLite3_bind_int64(FStatement,I+1,Params[I].VInteger);
      vtInt64: Code:=SQLite3_bind_int64(FStatement,I+1,Params[I].VInt64^);
      vtBoolean: Code:=SQLite3_bind_int64(FStatement,I+1,Ord(Params[I].VBoolean));
      vtUnicodeString,vtWideString,vtAnsiString,vtString,vtPChar,vtPWideChar:
        begin
          case Params[I].VType of
            vtUnicodeString: Text:=UnicodeString(Params[I].VUnicodeString);
            vtWideString: Text:=WideString(Params[I].VWideString);
            vtAnsiString: Text:=string(AnsiString(Params[I].VAnsiString));
            vtString: Text:=string(Params[I].VString^);
            vtPChar: Text:=string(Params[I].VPChar);
            else Text:=string(Params[I].VPWideChar);
          end;
          Empty:=#0;
          if Text='' then TextPointer:=@Empty else TextPointer:=PChar(Text);
          Code:=SQLite3_bind_text16(FStatement,I+1,TextPointer,Length(Text)*SizeOf(Char),SQLITE_TRANSIENT);
        end;
      else raise EAuthorFavorites.Create('Некорректный параметр любимых авторов.');
    end;
    FDatabase.Check(Code);
  end;
end;

function TAFQuery.Next: Boolean;
var Code: Integer;
begin
  Code:=SQLite3_Step(FStatement);
  if not (Code in [SQLITE_ROW,SQLITE_DONE]) then FDatabase.Check(Code);
  Result:=Code=SQLITE_ROW;
end;

procedure TAFQuery.Execute;
begin while Next do ; end;
function TAFQuery.Text(Index: Integer): string;
var Ptr: PWideChar;
begin
  Ptr:=SQLite3_ColumnText16(FStatement,Index);
  if Ptr=nil then Result:='' else SetString(Result,Ptr,SQLite3_ColumnBytes16(FStatement,Index) div SizeOf(Char));
end;
function TAFQuery.Number(Index: Integer): Int64;
begin Result:=SQLite3_ColumnInt64(FStatement,Index); end;

procedure TAFDatabase.Execute(const SQL: string; const Params: array of const);
var Query: TAFQuery;
begin Query:=TAFQuery.Create(Self,SQL,Params); try Query.Execute; finally Query.Free; end; end;
procedure TAFDatabase.Execute(const SQL: string);
begin Execute(SQL,[]); end;
function TAFDatabase.Number(const SQL: string; const Params: array of const): Int64;
var Query: TAFQuery;
begin Query:=TAFQuery.Create(Self,SQL,Params); try if Query.Next then Result:=Query.Number(0) else Result:=0; finally Query.Free; end; end;
function TAFDatabase.Number(const SQL: string): Int64;
begin Result:=Number(SQL,[]); end;
function TAFDatabase.Text(const SQL: string): string;
var Query: TAFQuery;
begin Query:=TAFQuery.Create(Self,SQL,[]); try if Query.Next then Result:=Query.Text(0) else Result:=''; finally Query.Free; end; end;
procedure TAFDatabase.Rollback;
begin
  SQLite3_ProgressHandler(FHandle,0,nil,nil);
  if SQLite3_Get_Autocommit(FHandle)=0 then Execute('ROLLBACK');
end;

procedure ValidateProfile(Database: TAFDatabase);
var Query: TAFQuery; Schema: string;
begin
  if (Database.Number('PRAGMA application_id')<>AF_APPLICATION_ID) or
    (Database.Number('PRAGMA user_version')<>AF_SCHEMA_VERSION) then
    raise EAuthorFavorites.Create('Неизвестная версия файла любимых авторов. Он сохранён без изменений.');
  if Database.Number('SELECT COUNT(*) FROM sqlite_master WHERE type IN (''trigger'',''view'')')<>0 then
    raise EAuthorFavorites.Create('Некорректная схема любимых авторов. Файл сохранён без изменений.');
  if Database.Number('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND name NOT GLOB ''sqlite_*''')<>6 then
    raise EAuthorFavorites.Create('Некорректная схема любимых авторов. Файл сохранён без изменений.');
  // This private version has exactly these keys/FKs/cascades. Missing constraints
  // are rejected read-only, rather than accepting a partial or unrelated schema.
  for Schema in AF_TABLE_SCHEMA do
    if Database.Number('SELECT COUNT(*) FROM sqlite_master WHERE type=''table'' AND sql=? COLLATE BINARY',[Schema])<>1 then
      raise EAuthorFavorites.Create('Некорректная схема любимых авторов. Файл сохранён без изменений.');
  if Database.Number('SELECT COUNT(*) FROM sqlite_master WHERE type=''index'' AND name IN (''IXAFCurrent_CID_BookKey'',''IXAFCurrent_CID_BookID'')')<>2 then
    raise EAuthorFavorites.Create('Некорректные индексы любимых авторов. Файл сохранён без изменений.');
  // Preparing verifies every required column without scanning book membership.
  Query:=TAFQuery.Create(Database,'SELECT AuthorKey,LastName,FirstName,MiddleName,CreatedUTC FROM FavoriteAuthors LIMIT 0',[]); Query.Free;
  Query:=TAFQuery.Create(Database,'SELECT CID,Revision,NewCount,UpdatedUTC FROM Collections LIMIT 0',[]); Query.Free;
  Query:=TAFQuery.Create(Database,'SELECT CID,AuthorKey,Baseline,BookCount,NewCount FROM CollectionAuthorState LIMIT 0',[]); Query.Free;
  Query:=TAFQuery.Create(Database,'SELECT CID,AuthorKey,AuthorID FROM AuthorBindings LIMIT 0',[]); Query.Free;
  Query:=TAFQuery.Create(Database,'SELECT CID,AuthorKey,BookKey,BookID FROM CurrentBooks LIMIT 0',[]); Query.Free;
  Query:=TAFQuery.Create(Database,'SELECT CID,AuthorKey,BookKey FROM SeenBooks LIMIT 0',[]); Query.Free;
end;

procedure CreateProfile(const FileName: string);
var Temporary, Schema: string; Database: TAFDatabase; Stream: TFileStream;
begin
  CheckSafeFile(FileName,True,True);
  if not ForceDirectories(ExtractFilePath(FileName)) then
    raise EAuthorFavorites.Create('Не удалось создать папку любимых авторов.');
  CheckSafeFile(FileName,True,True);
  Temporary:=FileName+'.new-'+TGUID.NewGuid.ToString;
  try
    Database:=TAFDatabase.Create(Temporary,False,True);
    try
      Database.Execute('BEGIN IMMEDIATE');
      Database.Execute('PRAGMA application_id='+IntToStr(AF_APPLICATION_ID));
      Database.Execute('PRAGMA user_version='+IntToStr(AF_SCHEMA_VERSION));
      for Schema in AF_TABLE_SCHEMA do Database.Execute(Schema);
      Database.Execute('CREATE INDEX IXAFCurrent_CID_BookKey ON CurrentBooks(CID,BookKey)');
      Database.Execute('CREATE INDEX IXAFCurrent_CID_BookID ON CurrentBooks(CID,BookID)');
      Database.Execute('COMMIT'); ValidateProfile(Database);
    finally Database.Free; end;
    Stream:=TFileStream.Create(Temporary,fmOpenReadWrite or fmShareExclusive);
    try if not FlushFileBuffers(Stream.Handle) then RaiseLastOSError; finally Stream.Free; end;
    CheckSafeFile(FileName,True,True);
    if not MoveFileEx(PChar(Temporary),PChar(FileName),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    Temporary:='';
  finally
    if (Temporary<>'') and FileExists(Temporary) then TFile.Delete(Temporary);
  end;
end;

function OpenReadProfile(const FileName: string): TAFDatabase;
begin
  CheckSafeFile(FileName,False,True); Result:=TAFDatabase.Create(FileName,True,False);
  try ValidateProfile(Result); except Result.Free; raise; end;
end;

function ReadEntries(Database: TAFDatabase): TArray<TAuthorFavoriteEntry>; forward;

function OpenWriteProfile(const FileName: string; out Lock: TFileMutex): TAFDatabase;
var ReadOnly: TAFDatabase;
begin
  Lock:=TFileMutex.Create(FileName); Result:=nil;
  try
    if not Lock.TryAcquire then raise EAuthorFavoritesBusy.Create('Любимые авторы сейчас обновляются. Повторите действие после завершения.');
    CheckSafeFile(FileName,True,True);
    if not FileExists(FileName) then CreateProfile(FileName);
    ReadOnly:=OpenReadProfile(FileName);
    try ReadEntries(ReadOnly); finally ReadOnly.Free; end;
    CheckSafeFile(FileName,False,True);
    Result:=TAFDatabase.Create(FileName,False,False);
    ValidateProfile(Result);
  except
    Result.Free; FreeAndNil(Lock); raise;
  end;
end;

function ReadEntries(Database: TAFDatabase): TArray<TAuthorFavoriteEntry>;
var Query: TAFQuery; List: TList<TAuthorFavoriteEntry>; Entry: TAuthorFavoriteEntry;
begin
  List:=TList<TAuthorFavoriteEntry>.Create;
  try
    Query:=TAFQuery.Create(Database,'SELECT AuthorKey,LastName,FirstName,MiddleName,CreatedUTC FROM FavoriteAuthors ORDER BY AuthorKey',[]);
    try
      while Query.Next do
      begin
        if List.Count>=AF_MAX_FAVORITES then raise EAuthorFavorites.Create('Слишком большой список любимых авторов.');
        Entry.Key:=Query.Text(0); Entry.LastName:=Query.Text(1); Entry.FirstName:=Query.Text(2);
        Entry.MiddleName:=Query.Text(3); Entry.CreatedUTC:=Query.Text(4);
        if (Entry.Key='') or (Entry.Key<>AuthorFavoriteKey(Entry.LastName,Entry.FirstName,Entry.MiddleName)) then
          raise EAuthorFavorites.Create('Некорректная запись любимого автора. Файл сохранён без изменений.');
        List.Add(Entry);
      end;
    finally Query.Free; end;
    Result:=List.ToArray;
  finally List.Free; end;
end;

constructor TAuthorFavorites.Create(const ProfileFile: string);
begin
  inherited Create;
  if (ProfileFile='') or (Pos(#0,ProfileFile)<>0) then raise EAuthorFavorites.Create('Не указан файл любимых авторов.');
  FFileName:=TPath.GetFullPath(ProfileFile);
  FKeys:=TDictionary<string,Boolean>.Create;
  FBindings:=TDictionary<Integer,TArray<Integer>>.Create;
  FStates:=TDictionary<string,TAuthorFavoriteState>.Create;
  FNewCounts:=TDictionary<Integer,Integer>.Create;
  FRevisions:=TDictionary<Integer,string>.Create;
  Reload;
end;

destructor TAuthorFavorites.Destroy;
begin FRevisions.Free; FNewCounts.Free; FStates.Free; FBindings.Free; FKeys.Free; inherited; end;

procedure TAuthorFavorites.Reload;
var Database: TAFDatabase; Query: TAFQuery; Entry: TAuthorFavoriteEntry;
  NewEntries: TArray<TAuthorFavoriteEntry>; NewKeys: TDictionary<string,Boolean>;
  NewBindings: TDictionary<Integer,TArray<Integer>>; NewStates: TDictionary<string,TAuthorFavoriteState>;
  NewCounts: TDictionary<Integer,Integer>; BindList: TList<Integer>; Value: TAuthorFavoriteState;
  NewRevisions: TDictionary<Integer,string>;
  CID, LastCID, Count: Integer;
begin
  NewKeys:=TDictionary<string,Boolean>.Create;
  NewBindings:=TDictionary<Integer,TArray<Integer>>.Create;
  NewStates:=TDictionary<string,TAuthorFavoriteState>.Create;
  NewCounts:=TDictionary<Integer,Integer>.Create;
  NewRevisions:=TDictionary<Integer,string>.Create; NewEntries:=nil;
  try
    CheckSafeFile(FFileName,True,True);
    if FileExists(FFileName) then
    begin
      Database:=OpenReadProfile(FFileName);
      try
        Database.Execute('BEGIN');
        NewEntries:=ReadEntries(Database);
        for Entry in NewEntries do NewKeys.Add(Entry.Key,True);
        Query:=TAFQuery.Create(Database,'SELECT CID,AuthorKey,Baseline,BookCount,NewCount FROM CollectionAuthorState',[]);
        try
          while Query.Next do
          begin
            if NewStates.Count>=AF_MAX_BINDINGS then raise EAuthorFavorites.Create('Слишком большой список состояний любимых авторов.');
            if (Query.Number(0)<=0) or (Query.Number(0)>MaxInt) or
              ((Query.Number(2)<>0) and (Query.Number(2)<>1)) or (Query.Number(3)<0) or (Query.Number(3)>AF_MAX_REFRESH_ROWS) or
              (Query.Number(4)<0) or (Query.Number(4)>Query.Number(3)) then
              raise EAuthorFavorites.Create('Некорректное состояние любимых авторов.');
            CID:=Query.Number(0); Value.HasBaseline:=Query.Number(2)<>0;
            Value.BookCount:=Query.Number(3); Value.NewCount:=Query.Number(4);
            if (CID<=0) or not NewKeys.ContainsKey(Query.Text(1)) or (Value.BookCount<0) or
              (Value.NewCount<0) or (Value.NewCount>Value.BookCount) then
              raise EAuthorFavorites.Create('Некорректное состояние любимых авторов.');
            NewStates.Add(StateKey(CID,Query.Text(1)),Value);
          end;
        finally Query.Free; end;
        Query:=TAFQuery.Create(Database,'SELECT CID,AuthorID FROM AuthorBindings GROUP BY CID,AuthorID ORDER BY CID,AuthorID',[]);
        BindList:=TList<Integer>.Create;
        try
          LastCID:=-1; Count:=0;
          while Query.Next do
          begin
            Inc(Count); if Count>AF_MAX_BINDINGS then raise EAuthorFavorites.Create('Слишком большой список привязок любимых авторов.');
            CID:=Query.Number(0);
            if (Query.Number(0)<=0) or (Query.Number(0)>MaxInt) or (Query.Number(1)<=0) or (Query.Number(1)>MaxInt) then
              raise EAuthorFavorites.Create('Некорректная привязка любимого автора.');
            if CID<>LastCID then
            begin
              if LastCID>0 then NewBindings.Add(LastCID,BindList.ToArray);
              BindList.Clear; LastCID:=CID;
            end;
            BindList.Add(Query.Number(1));
          end;
          if LastCID>0 then NewBindings.Add(LastCID,BindList.ToArray);
        finally BindList.Free; Query.Free; end;
        Query:=TAFQuery.Create(Database,'SELECT CID,NewCount,Revision FROM Collections',[]);
        try
          while Query.Next do
          begin
            if (NewCounts.Count>=AF_MAX_BINDINGS) or (Query.Number(0)<=0) or (Query.Number(0)>MaxInt) or
              (Query.Number(1)<0) or (Query.Number(1)>AF_MAX_REFRESH_ROWS) then
              raise EAuthorFavorites.Create('Некорректный счётчик новых книг.');
            NewCounts.Add(Query.Number(0),Query.Number(1));
            if Length(Query.Text(2))>4096 then
              raise EAuthorFavorites.Create('Некорректная ревизия коллекции любимых авторов.');
            NewRevisions.Add(Query.Number(0),Query.Text(2));
          end;
        finally Query.Free; end;
        Database.Execute('COMMIT');
      finally Database.Free; end;
    end;
    FEntries:=NewEntries;
    FKeys.Free; FKeys:=NewKeys; NewKeys:=nil;
    FBindings.Free; FBindings:=NewBindings; NewBindings:=nil;
    FStates.Free; FStates:=NewStates; NewStates:=nil;
    FNewCounts.Free; FNewCounts:=NewCounts; NewCounts:=nil;
    FRevisions.Free; FRevisions:=NewRevisions; NewRevisions:=nil;
  finally NewRevisions.Free; NewCounts.Free; NewStates.Free; NewBindings.Free; NewKeys.Free; end;
end;

procedure UpdateCounts(Database: TAFDatabase; CID: Integer);
var Query: TAFQuery; Key: string; BookCount, NewBooks: Integer;
begin
  Query:=TAFQuery.Create(Database,'SELECT AuthorKey FROM CollectionAuthorState WHERE CID=?',[CID]);
  try
    while Query.Next do
    begin
      Key:=Query.Text(0);
      BookCount:=Database.Number('SELECT COUNT(*) FROM (SELECT BookKey FROM CurrentBooks WHERE CID=? AND AuthorKey=? GROUP BY BookKey)',[CID,Key]);
      NewBooks:=Database.Number('SELECT COUNT(*) FROM (SELECT c.BookKey FROM CurrentBooks c WHERE c.CID=? AND c.AuthorKey=? AND '+AF_UNSEEN+' GROUP BY c.BookKey)',[CID,Key]);
      Database.Execute('UPDATE CollectionAuthorState SET BookCount=?,NewCount=? WHERE CID=? AND AuthorKey=?',[BookCount,NewBooks,CID,Key]);
    end;
  finally Query.Free; end;
  NewBooks:=Database.Number('SELECT COUNT(*) FROM (SELECT c.BookKey FROM CurrentBooks c WHERE c.CID=? AND '+AF_UNSEEN+' GROUP BY c.BookKey)',[CID]);
  Database.Execute('UPDATE Collections SET NewCount=?,UpdatedUTC=? WHERE CID=?',[NewBooks,UTCStamp,CID]);
end;

procedure TAuthorFavorites.SetFavorite(const LastName, FirstName, MiddleName: string; Enabled: Boolean);
var Database: TAFDatabase; Lock: TFileMutex; Key: string; Query: TAFQuery;
begin
  Key:=AuthorFavoriteKey(LastName,FirstName,MiddleName);
  if Key='' then raise EAuthorFavorites.Create('Сначала выберите автора.');
  if not Enabled and not FileExists(FFileName) then Exit;
  Database:=OpenWriteProfile(FFileName,Lock);
  try
    Database.Execute('BEGIN IMMEDIATE');
    try
      if Enabled then
      begin
        if Database.Number('SELECT EXISTS(SELECT 1 FROM FavoriteAuthors WHERE AuthorKey=?)',[Key])=0 then
        begin
          if Database.Number('SELECT COUNT(*) FROM FavoriteAuthors')>=AF_MAX_FAVORITES then
            raise EAuthorFavorites.Create('Достигнут предел списка любимых авторов.');
          Database.Execute('INSERT INTO FavoriteAuthors VALUES(?,?,?,?,?)',[Key,Trim(LastName),Trim(FirstName),Trim(MiddleName),UTCStamp]);
        end;
      end
      else
      begin
        Database.Execute('DELETE FROM FavoriteAuthors WHERE AuthorKey=?',[Key]);
        Query:=TAFQuery.Create(Database,'SELECT CID FROM Collections',[]);
        try while Query.Next do UpdateCounts(Database,Query.Number(0)); finally Query.Free; end;
      end;
      Database.Execute('COMMIT');
    except Database.Rollback; raise; end;
  finally Database.Free; Lock.Free; end;
  Reload;
end;

procedure TAuthorFavorites.ImportFavorites(const Authors: TArray<TAuthorFavoriteEntry>);
var Database: TAFDatabase; Lock: TFileMutex; Entry: TAuthorFavoriteEntry; Key: string;
begin
  if Length(Authors)=0 then Exit;
  if Length(Authors)>AF_MAX_FAVORITES then raise EAuthorFavorites.Create('В файле слишком много любимых авторов.');
  // Validate the whole portable list before starting its transaction. Local
  // author/collection IDs and seen-book baselines belong to this installation.
  for Entry in Authors do AuthorFavoriteKey(Entry.LastName,Entry.FirstName,Entry.MiddleName);
  Database:=OpenWriteProfile(FFileName,Lock);
  try
    Database.Execute('BEGIN IMMEDIATE');
    try
      for Entry in Authors do
      begin
        Key:=AuthorFavoriteKey(Entry.LastName,Entry.FirstName,Entry.MiddleName);
        if Key='' then Continue;
        Database.Execute('INSERT OR IGNORE INTO FavoriteAuthors VALUES(?,?,?,?,?)',
          [Key,Trim(Entry.LastName),Trim(Entry.FirstName),Trim(Entry.MiddleName),UTCStamp]);
      end;
      if Database.Number('SELECT COUNT(*) FROM FavoriteAuthors')>AF_MAX_FAVORITES then
        raise EAuthorFavorites.Create('Достигнут предел списка любимых авторов.');
      Database.Execute('COMMIT');
    except Database.Rollback; raise; end;
  finally Database.Free; Lock.Free; end;
  Reload;
end;

function TAuthorFavorites.IsFavorite(const LastName, FirstName, MiddleName: string): Boolean;
begin Result:=FKeys.ContainsKey(AuthorFavoriteKey(LastName,FirstName,MiddleName)); end;
function TAuthorFavorites.IsFavorite(const Author: TAuthorData): Boolean;
begin Result:=IsFavorite(Author.LastName,Author.FirstName,Author.MiddleName); end;
function TAuthorFavorites.MatchesAuthors(const Authors: TBookAuthors): Boolean;
var Author: TAuthorData;
begin
  for Author in Authors do if IsFavorite(Author) then Exit(True);
  Result:=False;
end;
function TAuthorFavorites.Entries: TArray<TAuthorFavoriteEntry>;
begin Result:=Copy(FEntries); end;
function TAuthorFavorites.Keys: TArray<string>;
begin Result:=FKeys.Keys.ToArray; end;
function TAuthorFavorites.BoundAuthorIDs(CollectionID: Integer): TArray<Integer>;
begin if not FBindings.TryGetValue(CollectionID,Result) then Result:=nil else Result:=Copy(Result); end;
function TAuthorFavorites.State(CollectionID: Integer; const AuthorKey: string): TAuthorFavoriteState;
begin if not FStates.TryGetValue(StateKey(CollectionID,AuthorKey),Result) then Result:=Default(TAuthorFavoriteState); end;
function TAuthorFavorites.NewCount(CollectionID: Integer; const AuthorKey: string): Integer;
begin
  if AuthorKey<>'' then Result:=State(CollectionID,AuthorKey).NewCount
  else if not FNewCounts.TryGetValue(CollectionID,Result) then Result:=0;
end;
function TAuthorFavorites.CollectionRevision(CollectionID: Integer): string;
begin
  if not FRevisions.TryGetValue(CollectionID,Result) then Result:='';
end;
function TAuthorFavorites.NewBookIDs(CollectionID: Integer; const AuthorKey: string): TArray<Integer>;
var Database: TAFDatabase; Query: TAFQuery; List: TList<Integer>; SQL: string;
begin
  Result:=nil;
  if not FileExists(FFileName) then Exit;
  Database:=OpenReadProfile(FFileName); List:=TList<Integer>.Create;
  try
    SQL:='SELECT c.BookID FROM CurrentBooks c WHERE c.CID=? AND '+AF_UNSEEN;
    if AuthorKey<>'' then Query:=TAFQuery.Create(Database,SQL+' AND c.AuthorKey=? GROUP BY c.BookID ORDER BY c.BookID',[CollectionID,AuthorKey])
    else Query:=TAFQuery.Create(Database,SQL+' GROUP BY c.BookID ORDER BY c.BookID',[CollectionID]);
    try
      while Query.Next do
      begin
        if (List.Count>=AF_MAX_REFRESH_ROWS) or (Query.Number(0)<=0) or (Query.Number(0)>MaxInt) then
          raise EAuthorFavorites.Create('Слишком большой или некорректный список новых книг.');
        List.Add(Query.Number(0));
      end;
    finally Query.Free; end;
    Result:=List.ToArray;
  finally List.Free; Database.Free; end;
end;

function TAuthorFavorites.CancelRequested: Boolean;
begin
  // SQLite calls from C; Delphi exceptions must never cross that boundary.
  try Result:=Assigned(FOperationCanceled) and FOperationCanceled(); except Result:=True; end;
end;
procedure TAuthorFavorites.CheckCanceled;
begin if CancelRequested then raise EAuthorFavoritesCanceled.Create('Обновление любимых авторов отменено.'); end;
function FavoriteProgress(UserData: Pointer): Integer; cdecl;
begin Result:=Ord(TAuthorFavorites(UserData).CancelRequested); end;

function ResolveAuthorIDs(Source: TSQLiteDatabase; const Entry: TAuthorFavoriteEntry): TArray<Integer>;
var Query: TSQLiteQuery; IDs: TList<Integer>; Seen: TDictionary<Integer,Boolean>; Mask, ID: Integer;
begin
  IDs:=TList<Integer>.Create; Seen:=TDictionary<Integer,Boolean>.Create;
  try
    // Empty names in older catalogues can be NULL. Four tuple point queries
    // retain IXAuthors_FullName; COALESCE/LOWER would force a catalogue scan.
    for Mask:=0 to 3 do
    begin
      if ((Entry.FirstName<>'') and (Mask and 1<>0)) or
        ((Entry.MiddleName<>'') and (Mask and 2<>0)) then Continue;
      Query:=Source.NewQuery(AF_AUTHOR_LOOKUP);
      try
        Query.SetParam(0,Entry.LastName);
        if Mask and 1<>0 then Query.SetNullParam(1) else Query.SetParam(1,Entry.FirstName);
        if Mask and 2<>0 then Query.SetNullParam(2) else Query.SetParam(2,Entry.MiddleName);
        Query.Open;
        while not Query.Eof do
        begin
          if Entry.Key=AuthorFavoriteKey(Query.FieldAsString(1),Query.FieldAsString(2),Query.FieldAsString(3)) then
          begin
            if (Query.FieldAsInt(0)<=0) or (Query.FieldAsInt(0)>MaxInt) then
              raise EAuthorFavorites.Create('Некорректный номер автора в коллекции.');
            ID:=Query.FieldAsInt(0);
            if not Seen.ContainsKey(ID) then
            begin
              if IDs.Count>=AF_MAX_FAVORITES then raise EAuthorFavorites.Create('Слишком много совпадающих записей автора.');
              Seen.Add(ID,True); IDs.Add(ID);
            end;
          end;
          Query.Next;
        end;
      finally Query.Free; end;
    end;
    IDs.Sort; Result:=IDs.ToArray;
  finally Seen.Free; IDs.Free; end;
end;

procedure TAuthorFavorites.RefreshCollection(const Collection: TAuthorFavoriteCollection;
  const Canceled: TAuthorFavoritesCanceled; const Progress: TAuthorFavoritesProgress);
var Database: TAFDatabase; Source: TSQLiteDatabase; Lock: TFileMutex;
  Snapshot: TArray<TAuthorFavoriteEntry>; Entry: TAuthorFavoriteEntry; AuthorIDs: TArray<Integer>;
  Books: TSQLiteQuery; InsertBook: TAFQuery; BookKey: string; AuthorID, Done, Rows: Integer;
  Baseline: Boolean; SavedCallback: TSQLiteCancelCallback;
begin
  if (Collection.ID<=0) or (Collection.DatabaseFile='') or (Length(Collection.Revision)>4096) then
    raise EAuthorFavorites.Create('Не указана коллекция для проверки любимых авторов.');
  if FKeys.Count=0 then Exit;
  CheckSafeFile(Collection.DatabaseFile,False,False);
  if SameFileName(TPath.GetFullPath(Collection.DatabaseFile),FFileName) then
    raise EAuthorFavorites.Create('Каталог книг и любимые авторы должны храниться раздельно.');
  FOperationCanceled:=Canceled; SavedCallback:=SQLiteCancelCallback;
  SQLiteCancelCallback:=CancelRequested; Source:=nil; Database:=nil; Lock:=nil;
  try
    CheckCanceled;
    Source:=TSQLiteDatabase.CreateReadOnly(Collection.DatabaseFile); Source.SetTimeout(0); Source.Start;
    Database:=OpenWriteProfile(FFileName,Lock);
    SQLite3_ProgressHandler(Database.Handle,1000,FavoriteProgress,Self);
    Database.Execute('BEGIN IMMEDIATE');
    try
      Snapshot:=ReadEntries(Database); Done:=0; Rows:=0;
      Database.Execute('INSERT INTO Collections(CID,Revision,UpdatedUTC) VALUES(?,?,?) '
        +'ON CONFLICT(CID) DO UPDATE SET Revision=excluded.Revision,UpdatedUTC=excluded.UpdatedUTC',
        [Collection.ID,Collection.Revision,UTCStamp]);
      InsertBook:=TAFQuery.Create(Database,'INSERT OR IGNORE INTO CurrentBooks(CID,AuthorKey,BookKey,BookID) VALUES(?,?,?,?)',[]);
      try
        for Entry in Snapshot do
        begin
          CheckCanceled;
          Baseline:=Database.Number('SELECT EXISTS(SELECT 1 FROM CollectionAuthorState WHERE CID=? AND AuthorKey=? AND Baseline=1)',[Collection.ID,Entry.Key])<>0;
          Database.Execute('INSERT OR IGNORE INTO CollectionAuthorState(CID,AuthorKey) VALUES(?,?)',[Collection.ID,Entry.Key]);
          Database.Execute('DELETE FROM CurrentBooks WHERE CID=? AND AuthorKey=?',[Collection.ID,Entry.Key]);
          Database.Execute('DELETE FROM AuthorBindings WHERE CID=? AND AuthorKey=?',[Collection.ID,Entry.Key]);
          AuthorIDs:=ResolveAuthorIDs(Source,Entry);
          for AuthorID in AuthorIDs do
          begin
            Database.Execute('INSERT INTO AuthorBindings(CID,AuthorKey,AuthorID) VALUES(?,?,?)',[Collection.ID,Entry.Key,AuthorID]);
            Books:=Source.NewQuery(AF_BOOK_LOOKUP,[AuthorID]);
            try
              Books.Open;
              while not Books.Eof do
              begin
                Inc(Rows);
                if Rows>AF_MAX_REFRESH_ROWS then raise EAuthorFavorites.Create('Слишком много книг для одной проверки любимых авторов.');
                if Rows and 63=0 then CheckCanceled;
                if (Books.FieldAsInt(0)<=0) or (Books.FieldAsInt(0)>MaxInt) then
                  raise EAuthorFavorites.Create('Некорректный номер книги в коллекции.');
                BookKey:=AuthorFavoriteBookKey(Collection.ID,Books.FieldAsString(1),Books.FieldAsString(2),Books.FieldAsString(3),
                  Books.FieldAsString(4),Books.FieldAsString(5),Books.FieldAsString(6),Collection.LibraryNamespace);
                InsertBook.Bind([Collection.ID,Entry.Key,BookKey,Books.FieldAsInt(0)]); InsertBook.Execute;
                if Assigned(Progress) and (Rows and 255=0) then Progress(Done,Length(Snapshot),Rows);
                Books.Next;
              end;
            finally Books.Free; end;
          end;
          if not Baseline then
            Database.Execute('INSERT OR IGNORE INTO SeenBooks SELECT CID,AuthorKey,BookKey FROM CurrentBooks WHERE CID=? AND AuthorKey=?',[Collection.ID,Entry.Key]);
          Database.Execute('UPDATE CollectionAuthorState SET Baseline=1 WHERE CID=? AND AuthorKey=?',[Collection.ID,Entry.Key]);
          Inc(Done); if Assigned(Progress) then Progress(Done,Length(Snapshot),Rows);
        end;
      finally InsertBook.Free; end;
      CheckCanceled; UpdateCounts(Database,Collection.ID); CheckCanceled;
      Database.Execute('COMMIT');
    except Database.Rollback; raise; end;
    Source.Commit;
  finally
    Database.Free; Lock.Free; Source.Free; SQLiteCancelCallback:=SavedCallback; FOperationCanceled:=nil;
  end;
  Reload;
end;

procedure TAuthorFavorites.MarkViewed(CollectionID: Integer; const AuthorKey: string;
  const Canceled: TAuthorFavoritesCanceled);
var Database: TAFDatabase; Lock: TFileMutex;
begin
  if CollectionID<=0 then raise EAuthorFavorites.Create('Не указана коллекция для любимых авторов.');
  if not FileExists(FFileName) then Exit;
  FOperationCanceled:=Canceled; Database:=nil; Lock:=nil;
  try
    CheckCanceled; Database:=OpenWriteProfile(FFileName,Lock);
    SQLite3_ProgressHandler(Database.Handle,1000,FavoriteProgress,Self);
    Database.Execute('BEGIN IMMEDIATE');
    try
      if AuthorKey='' then
        Database.Execute('INSERT OR IGNORE INTO SeenBooks SELECT CID,AuthorKey,BookKey FROM CurrentBooks WHERE CID=?',[CollectionID])
      else
        Database.Execute('INSERT OR IGNORE INTO SeenBooks SELECT CID,AuthorKey,BookKey FROM CurrentBooks WHERE CID=? AND AuthorKey=?',[CollectionID,AuthorKey]);
      CheckCanceled; UpdateCounts(Database,CollectionID); CheckCanceled; Database.Execute('COMMIT');
    except Database.Rollback; raise; end;
  finally Database.Free; Lock.Free; FOperationCanceled:=nil; end;
  Reload;
end;

end.
