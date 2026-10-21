// Native backend fixture; extra uses: unit_AuthorFavorites.
// Test files and sources belong to the guarded disposable profile.

procedure AFRRawExecute(Database: TSQLite3DB; const SQL: string);
var Statement: TSQLiteStmt; Tail: PUTF8Char; Value: UTF8String; Code: Integer;
begin
  Value:=UTF8String(SQL); Statement:=nil; Tail:=nil;
  Require(SQLite3_Prepare_v2(Database,PUTF8Char(Value),Length(Value)+1,Statement,Tail)=SQLITE_OK,
    'Favorite fixture raw statement failed: '+SQL);
  try
    repeat Code:=SQLite3_Step(Statement); until Code<>SQLITE_ROW;
    Require(Code=SQLITE_DONE,'Favorite fixture raw execution failed: '+SQL);
  finally SQLite3_Finalize(Statement); end;
end;

function AFROpenRaw(const FileName: string): TSQLite3DB;
var Value: UTF8String;
begin
  Value:=UTF8String(FileName); Result:=nil;
  if SQLite3_Open_v2(PUTF8Char(Value),Result,SQLITE_OPEN_READWRITE or SQLITE_OPEN_PRIVATECACHE,nil)<>SQLITE_OK then
  begin
    if Result<>nil then SQLite3_Close(Result);
    Result:=nil; Require(False,'Favorite fixture raw opening failed');
  end;
  SQLite3_BusyTimeout(Result,0);
end;

function AFRHasID(const IDs: TArray<Integer>; ID: Integer): Boolean;
begin
  for var Value in IDs do if Value=ID then Exit(True);
  Result:=False;
end;

procedure AFRAddBook(Database: TSQLiteDatabase; ID, AuthorID: Integer;
  const LibraryID, Folder, FileName, Title: string; Deleted: Boolean = False);
begin
  Database.ExecSQL('INSERT INTO Books(BookID,LibID,Folder,FileName,Ext,Title,Lang,IsDeleted,Rate,Progress,Review) '
    +'VALUES(?,?,?,?,?,?,?,?,?,?,?)',[ID,LibraryID,Folder,FileName,'.fb2',Title,'ru',Deleted,4,37,'Сохранить мои мысли ё']);
  Database.ExecSQL('INSERT INTO Author_List VALUES(?,?)',[AuthorID,ID]);
end;

procedure AFRCreateCatalogue(const FileName: string);
var Database: TSQLiteDatabase;
begin
  Database:=TSQLiteDatabase.Create(FileName);
  try
    Database.QuerySingleString('PRAGMA journal_mode=DELETE');
    Database.ExecSQL('CREATE TABLE Authors(AuthorID INTEGER PRIMARY KEY, '
      +'LastName TEXT NOT NULL COLLATE MHL_SYSTEM_NOCASE, FirstName TEXT COLLATE MHL_SYSTEM_NOCASE, MiddleName TEXT COLLATE MHL_SYSTEM_NOCASE)');
    Database.ExecSQL('CREATE INDEX IXAuthors_FullName ON Authors(LastName,FirstName,MiddleName)');
    Database.ExecSQL('CREATE TABLE Books(BookID INTEGER PRIMARY KEY, LibID TEXT, Folder TEXT, FileName TEXT, Ext TEXT, Title TEXT, '
      +'Lang TEXT, IsDeleted INTEGER NOT NULL DEFAULT 0, Rate INTEGER, Progress INTEGER, Review TEXT, Publisher TEXT)');
    Database.ExecSQL('CREATE TABLE Author_List(AuthorID INTEGER NOT NULL, BookID INTEGER NOT NULL, PRIMARY KEY(BookID,AuthorID))');
    Database.ExecSQL('CREATE INDEX IXAuthorList_AuthorID_BookID ON Author_List(AuthorID,BookID)');
    Database.ExecSQL('CREATE TABLE FavoriteBooks(BookID INTEGER PRIMARY KEY, MyCaption TEXT)');
    Database.ExecSQL('CREATE TABLE UserGroups(ID INTEGER PRIMARY KEY, Name TEXT, Members TEXT)');
    Database.ExecSQL('CREATE TABLE ReadingHistory(BookID INTEGER PRIMARY KEY, Position INTEGER, Note TEXT)');
    Database.ExecSQL('CREATE TABLE UserNotes(ID INTEGER PRIMARY KEY, BookID INTEGER, Text TEXT, Quote TEXT)');
    Database.ExecSQL('CREATE TABLE Settings(Name TEXT PRIMARY KEY, Value TEXT)');
    Database.Start;
    try
      Database.ExecSQL('INSERT INTO Authors VALUES(1,?,?,?)',['Кинг','Стивен','']);
      Database.ExecSQL('INSERT INTO Authors VALUES(2,?,?,?)',['Кинг','Ричард','']);
      Database.ExecSQL('INSERT INTO Authors VALUES(3,?,?,NULL)',['КИНГ','СТИВЕН']);
      Database.ExecSQL('INSERT INTO Authors VALUES(4,?,?,?)',['Мартин','Джордж','Р.Р.']);
      AFRAddBook(Database,100,1,'flibusta:11','archive-a.zip','100','Роман');
      AFRAddBook(Database,101,3,'99','archive-a.zip','101','Неизвестный источник');
      AFRAddBook(Database,102,2,'flibusta:90','archive-a.zip','102','Однофамилец');
      AFRAddBook(Database,103,1,'flibusta:91','archive-a.zip','103','Удалённая книга',True);
      Database.ExecSQL('INSERT INTO Author_List VALUES(4,100)');
      Database.ExecSQL('INSERT INTO FavoriteBooks VALUES(100,?)',['Моя любимая книга']);
      Database.ExecSQL('INSERT INTO UserGroups VALUES(7,?,?)',['Моя группа','100,102']);
      Database.ExecSQL('INSERT INTO ReadingHistory VALUES(100,37,?)',['Не потерять историю']);
      Database.ExecSQL('INSERT INTO UserNotes VALUES(1,100,?,?)',['Моя заметка ё','Моя цитата']);
      Database.ExecSQL('INSERT INTO Settings VALUES(?,?)',['reader.font','Georgia 20']);
      // A sizeable unrelated catalogue must not be scanned for one author.
      for var I:=1 to 12000 do
      begin
        Database.ExecSQL('INSERT INTO Authors VALUES(?,?,?,?)',[10000+I,'Другой '+IntToStr(I),'Автор','']);
        AFRAddBook(Database,10000+I,10000+I,IntToStr(I),'unrelated.zip',IntToStr(I),'Посторонняя книга');
      end;
      Database.Commit;
    except Database.Rollback; raise; end;
  finally Database.Free; end;
end;

procedure AFRRequirePointPlans(const FileName: string);
var Database: TSQLiteDatabase; Query: TSQLiteQuery; Plan: string;
begin
  Database:=TSQLiteDatabase.CreateReadOnly(FileName);
  try
    Query:=Database.NewQuery('EXPLAIN QUERY PLAN SELECT AuthorID,LastName,FirstName,MiddleName '
      +'FROM Authors INDEXED BY IXAuthors_FullName WHERE LastName=? AND FirstName IS ? AND MiddleName IS ?',
      ['Кинг','Стивен','']);
    try
      Query.Open; Plan:='';
      while not Query.Eof do begin Plan:=Plan+Query.FieldAsString(3)+sLineBreak; Query.Next; end;
      Require(ContainsText(Plan,'SEARCH Authors USING COVERING INDEX IXAuthors_FullName'),
        'Favorite author lookup lost the full tuple index: '+Plan);
      Require(not ContainsText(Plan,'SCAN Authors'),'Favorite author lookup scans catalogue: '+Plan);
      Writeln('PLAN author favorites ',Trim(Plan));
    finally Query.Free; end;
    Query:=Database.NewQuery('EXPLAIN QUERY PLAN SELECT b.BookID,b.LibID,b.Folder,b.FileName,b.Ext,b.Title,b.Lang '
      +'FROM Author_List al INDEXED BY IXAuthorList_AuthorID_BookID JOIN Books b ON b.BookID=al.BookID '
      +'WHERE al.AuthorID=? AND b.IsDeleted=0',[1]);
    try
      Query.Open; Plan:='';
      while not Query.Eof do begin Plan:=Plan+Query.FieldAsString(3)+sLineBreak; Query.Next; end;
      Require(ContainsText(Plan,'SEARCH al USING COVERING INDEX IXAuthorList_AuthorID_BookID'),
        'Favorite books lost the author list index: '+Plan);
      Require(ContainsText(Plan,'SEARCH b USING INTEGER PRIMARY KEY'),
        'Favorite books lost primary key lookups: '+Plan);
      Require(not ContainsText(Plan,'SCAN '),'Favorite refresh scans entire catalogue: '+Plan);
      Writeln('PLAN favorite book snapshot ',Trim(Plan));
    finally Query.Free; end;
  finally Database.Free; end;
end;

procedure AFRRequireRejected(const FileName, Reason: string);
var Store: TAuthorFavorites; Rejected: Boolean; Hash: string;
begin
  Hash:=THashSHA2.GetHashStringFromFile(FileName); Store:=nil; Rejected:=False;
  try
    try Store:=TAuthorFavorites.Create(FileName);
    except on E: EAuthorFavorites do Rejected:=True; end;
  finally Store.Free; end;
  Require(Rejected,Reason+' was accepted');
  Require(THashSHA2.GetHashStringFromFile(FileName)=Hash,Reason+' was modified');
  Require(not FileExists(FileName+'-wal') and not FileExists(FileName+'-shm') and
    not FileExists(FileName+'-journal'),Reason+' created writable sidecars');
end;

procedure TestAuthorFavorites;
var Folder, Catalogue, Profile, KingKey, MartinKey, Hash, SourceHash, ProtectedFile, ProtectedHash: string;
  Store, Other: TAuthorFavorites; Collection: TAuthorFavoriteCollection; Database: TSQLiteDatabase;
  IDs: TArray<Integer>; Authors: TBookAuthors; CachedEntries: TArray<TAuthorFavoriteEntry>;
  Raw: TSQLite3DB; WasCanceled, CancelNow, WasBusy, Rejected: Boolean; CancelCalls: Integer;
  Before: UInt64; Worker: TThread; Locked, Released: TEvent; LockFailure: string;
  Unknown, Corrupt, Tampered, ReadonlyFile, Nested, CachedProfile: string;
begin
  RequireIsolatedRegression;
  Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'author-favorite-fixture-'+TGUID.NewGuid.ToString));
  ForceDirectories(Folder); Catalogue:=Folder+'catalogue.sqlite'; Profile:=Folder+AUTHOR_FAVORITES_FILE_NAME;
  ProtectedFile:=Folder+'settings-notes-history-books-sentinel.txt';
  TFile.WriteAllText(ProtectedFile,'Книги, настройки, закладки, заметки и история остаются прежними ё.',TEncoding.UTF8);
  ProtectedHash:=THashSHA2.GetHashStringFromFile(ProtectedFile);
  AFRCreateCatalogue(Catalogue); AFRRequirePointPlans(Catalogue);
  Collection:=Default(TAuthorFavoriteCollection); Collection.ID:=7;
  Collection.DatabaseFile:=Catalogue; Collection.RootFolder:=Folder+'missing-book-root\';
  Collection.LibraryNamespace:=''; Collection.Revision:='baseline-1';
  SourceHash:=THashSHA2.GetHashStringFromFile(Catalogue);
  Store:=TAuthorFavorites.Create(Profile); Other:=nil;
  try
    Require(not FileExists(Profile),'Opening empty favorites eagerly created a profile');
    Require((Length(Store.Entries)=0) and (Store.NewCount(7)=0),'Empty favorite state is wrong');
    Require(Store.CollectionRevision(7)='','Missing collection unexpectedly has a revision');
    KingKey:=AuthorFavoriteKey('Кинг','Стивен',''); MartinKey:=AuthorFavoriteKey('Мартин','Джордж','Р.Р.');
    Require(KingKey=AuthorFavoriteKey(' КИНГ ',' СТИВЕН ',''),'Invariant Russian name case/trim failed');
    Require(KingKey<>AuthorFavoriteKey('Кинг','Ричард',''),'Same surname collapsed different authors');
    Require(AuthorFavoriteKey('A','BC','D')<>AuthorFavoriteKey('AB','C','D'),'Name field boundaries collide');
    Require(AuthorFavoriteKey('Ёлкин','Іван','Їжак')=AuthorFavoriteKey('ёлкин','іван','їжак'),'Multilingual case normalization failed');
    Require(AuthorFavoriteKey('Ångström','Émile','')=AuthorFavoriteKey('ångström','émile',''),'Latin Unicode case normalization failed');
    Require(AuthorFavoriteKey('Иван','Сергей','Петрович')<>AuthorFavoriteKey('Иван','Сергей','Ильич'),'Patronymics collapsed');
    Require(AuthorFavoriteKey('','','')='','Empty author acquired an identity');
    Require(AuthorFavoriteBookKey(7,'flibusta:12','a.zip','a','.fb2','Роман','ru','')<>
      AuthorFavoriteBookKey(7,'librusec:12','a.zip','a','.fb2','Роман','ru',''),'Numeric library IDs collapsed');
    Require(AuthorFavoriteBookKey(7,'merged:source-a:12','a.zip','a','.fb2','Роман','ru','flibusta')<>
      AuthorFavoriteBookKey(7,'merged:source-b:12','a.zip','a','.fb2','Роман','ru','flibusta'),'Unknown merged origins collapsed');
    Require(AuthorFavoriteBookKey(7,'12','a.zip','a','.fb2','Роман','ru','')<>
      AuthorFavoriteBookKey(7,'12','b.zip','a','.fb2','Роман','ru',''),'Unknown physical origins collapsed');
    Require(AuthorFavoriteBookKey(7,'12','a.zip','a','.fb2','Роман','ru','')<>
      AuthorFavoriteBookKey(8,'12','a.zip','a','.fb2','Роман','ru',''),'Unknown CIDs collapsed');
    Require(AuthorFavoriteBookKey(7,'merged:one:flibusta:12','a.zip','a','.fb2','Роман','ru','')=
      AuthorFavoriteBookKey(7,'merged:two:flibusta:12','b.zip','b','fb2','Роман','ru',''),'Verified library identity depends on copy location');
    Require(AuthorFavoriteBookKey(7,'flibusta:12','a.zip','a','.fb2','Исходное название','ru','')=
      AuthorFavoriteBookKey(7,'flibusta:12','a.zip','a','.fb2','Исправленное название','uk',''),
      'Trusted book metadata corrections changed stable identity');
    Require(AuthorFavoriteBookKey(7,'merged:outer:merged:inner:flibusta:12','a.zip','a','.fb2','Роман','ru','')=
      AuthorFavoriteBookKey(7,'flibusta:12','b.zip','b','.fb2','Исправлено','uk',''),
      'Nested trusted merged identity did not unwrap to the original library');
    Require(AuthorFavoriteBookKey(7,'merged:outer:merged:inner-a:12','same.zip','same','.fb2','Роман','ru','flibusta')<>
      AuthorFavoriteBookKey(7,'merged:outer:merged:inner-b:12','same.zip','same','.fb2','Роман','ru','flibusta'),
      'Unknown nested inner origins collapsed');
    Require(AuthorFavoriteBookKey(7,'merged:outer-a:merged:inner:12','same.zip','same','.fb2','Роман','ru','flibusta')<>
      AuthorFavoriteBookKey(7,'merged:outer-b:merged:inner:12','same.zip','same','.fb2','Роман','ru','flibusta'),
      'Unknown nested outer origins collapsed');
    Nested:='flibusta:12';
    for var I:=1 to 32 do Nested:='merged:s'+IntToStr(I)+':'+Nested;
    Require(AuthorFavoriteBookKey(7,Nested,'a.zip','a','.fb2','Роман','ru','')=
      AuthorFavoriteBookKey(7,'flibusta:12','a.zip','a','.fb2','Роман','ru',''),
      'Allowed nested merge depth lost trusted identity');
    Rejected:=False;
    try AuthorFavoriteBookKey(7,'merged:over-limit:'+Nested,'a.zip','a','.fb2','Роман','ru','');
    except on E: EAuthorFavorites do Rejected:=True; end;
    Require(Rejected,'Excessive merged provenance depth was not rejected');
    Store.SetFavorite('Кинг','Стивен','',True); Store.SetFavorite('Мартин','Джордж','Р.Р.',True);
    Store.SetFavorite('КИНГ','СТИВЕН','',True);
    Require(Length(Store.Keys)=2,'Same author case variant duplicated favorite');
    CachedEntries:=Store.Entries; CachedEntries[0].LastName:='Outside mutation';
    Require(Store.Entries[0].LastName<>'Outside mutation','Favorite entries exposed mutable cache');
    Authors:=nil; TAuthorsHelper.Add(Authors,'Кинг','Стивен','',9999);
    Require(Store.MatchesAuthors(Authors),'Favorite match depended on AuthorID');
    Authors:=nil; TAuthorsHelper.Add(Authors,'Кинг','Ричард','',1);
    Require(not Store.MatchesAuthors(Authors),'Unrelated author inherited favorite from remapped numeric ID');
    Before:=GetTickCount64; Store.RefreshCollection(Collection);
    Require((Store.NewCount(7)=0) and Store.State(7,KingKey).HasBaseline,'Initial books were falsely marked new');
    Require(Store.CollectionRevision(7)='baseline-1','Baseline revision was not cached after commit');
    CachedProfile:=Folder+'temporarily-offline-profile.sqlite';
    TFile.Move(Profile,CachedProfile);
    try
      Require((Store.CollectionRevision(7)='baseline-1') and (Store.CollectionRevision(9999)=''),
        'Collection revision accessor attempted SQL or file access');
    finally TFile.Move(CachedProfile,Profile); end;
    Require((Store.State(7,KingKey).BookCount=2) and (Store.State(7,MartinKey).BookCount=1),
      'Baseline omitted NULL/case author aliases or included deleted/other authors');
    IDs:=Store.BoundAuthorIDs(7);
    Require((Length(IDs)=3) and AFRHasID(IDs,1) and AFRHasID(IDs,3) and AFRHasID(IDs,4) and not AFRHasID(IDs,2),
      'Favorite author ID bindings are incomplete or ambiguous');
    IDs[0]:=123456;
    Require(not AFRHasID(Store.BoundAuthorIDs(7),123456),'Bound IDs exposed mutable cache');
    Require(THashSHA2.GetHashStringFromFile(Catalogue)=SourceHash,'Baseline modified source catalogue or protected personal data');
    Writeln('PASS favorite authors baseline with 12,000 unrelated books: ',GetTickCount64-Before,' ms; indexed tuple lookup, deleted guard and NULL aliases');

    Database:=TSQLiteDatabase.Create(Catalogue);
    try
      Database.QuerySingleString('PRAGMA journal_mode=DELETE'); Database.Start;
      try
        AFRAddBook(Database,104,1,'flibusta:12','new.zip','104','Новая общая книга');
        Database.ExecSQL('INSERT INTO Author_List VALUES(4,104)');
        AFRAddBook(Database,105,1,'librusec:12','new.zip','105','Новая общая книга');
        AFRAddBook(Database,106,1,'99','archive-b.zip','101','Неизвестный источник');
        AFRAddBook(Database,107,1,'merged:outer:merged:source-a:99','same.zip','same','Новый неизвестный');
        AFRAddBook(Database,108,1,'merged:outer:merged:source-b:99','same.zip','same','Новый неизвестный');
        AFRAddBook(Database,109,1,'merged:outer:merged:copy:flibusta:12','other.zip','109','Новая общая книга');
        Database.Commit;
      except Database.Rollback; raise; end;
    finally Database.Free; end;
    SourceHash:=THashSHA2.GetHashStringFromFile(Catalogue); Collection.Revision:='new-books-2';
    Store.RefreshCollection(Collection);
    Require((Store.NewCount(7,KingKey)=5) and (Store.NewCount(7,MartinKey)=1) and (Store.NewCount(7)=5),
      'New badge collapsed origins or double-counted coauthors/copies');
    IDs:=Store.NewBookIDs(7);
    Require((Length(IDs)=6) and AFRHasID(IDs,104) and AFRHasID(IDs,109) and not AFRHasID(IDs,100),
      'Only-new result IDs lost a current copy or included baseline books');
    Hash:=THashSHA2.GetHashStringFromFile(Profile);
    Store.RefreshCollection(Collection);
    Require(Store.NewCount(7)=5,'Listing or repeated refresh acknowledged new books automatically');
    FreeAndNil(Store); Store:=TAuthorFavorites.Create(Profile);
    Require((Store.NewCount(7)=5) and Store.IsFavorite('Кинг','Стивен',''),'Reopening lost favorites or unread badge');
    Require(Store.CollectionRevision(7)='new-books-2','Reopening did not reload cached collection revision');
    Require(THashSHA2.GetHashStringFromFile(Catalogue)=SourceHash,'New book snapshot modified original catalogue');

    Database:=TSQLiteDatabase.Create(Catalogue);
    try
      Database.QuerySingleString('PRAGMA journal_mode=DELETE'); Database.Start;
      try
        for var I:=1 to 600 do
          AFRAddBook(Database,30000+I,1,'flibusta:'+IntToStr(30000+I),'cancel.zip',IntToStr(I),'Книга для отмены '+IntToStr(I));
        Database.Commit;
      except Database.Rollback; raise; end;
    finally Database.Free; end;
    Hash:=THashSHA2.GetHashStringFromFile(Profile); SourceHash:=THashSHA2.GetHashStringFromFile(Catalogue);
    CancelNow:=False; WasCanceled:=False; Collection.Revision:='canceled-must-not-persist';
    try
      Store.RefreshCollection(Collection,function: Boolean begin Result:=CancelNow; end,
        procedure(AuthorsDone,AuthorsTotal,BooksRead: Integer)
        begin if BooksRead>=256 then CancelNow:=True; end);
    except on E: EAuthorFavoritesCanceled do WasCanceled:=True; end;
    Require(WasCanceled,'Mid-snapshot favorite cancellation did not fire');
    Require((Store.NewCount(7)=5) and (THashSHA2.GetHashStringFromFile(Profile)=Hash),
      'Canceled favorite snapshot changed last-good membership, seen keys or counts');
    Require(Store.CollectionRevision(7)='new-books-2','Canceled snapshot changed cached revision');
    Require(THashSHA2.GetHashStringFromFile(Catalogue)=SourceHash,'Canceled snapshot modified source');
    Store.Reload;
    Require((Store.NewCount(7)=5) and (Store.CollectionRevision(7)='new-books-2'),
      'Canceled transaction or revision survived reopening');
    CancelCalls:=0; WasCanceled:=False;
    try
      Store.MarkViewed(7,'',function: Boolean begin Inc(CancelCalls); Result:=CancelCalls>=2; end);
    except on E: EAuthorFavoritesCanceled do WasCanceled:=True; end;
    Require(WasCanceled and (Store.NewCount(7)=5) and (THashSHA2.GetHashStringFromFile(Profile)=Hash),
      'Canceled Mark Viewed acknowledged books or changed the profile');

    // Remove uncommitted test additions in the source, keeping last-good counts.
    Database:=TSQLiteDatabase.Create(Catalogue);
    try
      Database.QuerySingleString('PRAGMA journal_mode=DELETE');
      Database.Start;
      try
        Database.ExecSQL('DELETE FROM Author_List WHERE BookID>=30001 AND BookID<=30600');
        Database.ExecSQL('DELETE FROM Books WHERE BookID>=30001 AND BookID<=30600');
        Database.ExecSQL('UPDATE Books SET Title=?,Lang=?,Publisher=? WHERE BookID=100',
          ['Исправленное название','uk','Исправленное издательство']);
        Database.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=100',
          ['merged:outer:merged:inner:flibusta:11']);
        // Simulate INPX recreation: full author names and physical/source
        // identities stay the same while all internal catalogue IDs change.
        Database.ExecSQL('UPDATE Authors SET AuthorID=AuthorID+500 WHERE AuthorID<100');
        Database.ExecSQL('UPDATE Author_List SET AuthorID=AuthorID+500 WHERE AuthorID<100');
        Database.ExecSQL('UPDATE Books SET BookID=BookID+1000 WHERE BookID<1000');
        Database.ExecSQL('UPDATE Author_List SET BookID=BookID+1000 WHERE BookID<1000');
        Database.Commit;
      except Database.Rollback; raise; end;
    finally Database.Free; end;
    SourceHash:=THashSHA2.GetHashStringFromFile(Catalogue); Collection.Revision:='remap-3';
    Store.RefreshCollection(Collection);
    Require((Store.NewCount(7)=5) and AFRHasID(Store.BoundAuthorIDs(7),501) and not AFRHasID(Store.BoundAuthorIDs(7),1),
      'Internal author/book ID remapping reset baseline or lost bindings');
    Require(not AFRHasID(Store.NewBookIDs(7),1100),
      'Trusted existing title/publisher/language correction became a new book');
    Require(AFRHasID(Store.NewBookIDs(7),1104) and not AFRHasID(Store.NewBookIDs(7),104),'Only-new IDs did not remap');
    Collection.ID:=8; Store.RefreshCollection(Collection);
    Require((Store.NewCount(8)=0) and (Store.NewCount(7)=5),'New collection stole another collection seen state');
    Collection.ID:=7;
    Require((Store.CollectionRevision(7)='remap-3') and (Store.CollectionRevision(8)='remap-3'),
      'Revision cache did not retain independent collection entries');
    Store.MarkViewed(7,KingKey);
    Require((Store.NewCount(7,KingKey)=0) and (Store.NewCount(7,MartinKey)=1) and (Store.NewCount(7)=1),
      'Per-author explicit acknowledgment affected another favorite');
    Store.MarkViewed(7);
    Require((Store.NewCount(7)=0) and (Length(Store.NewBookIDs(7))=0),'Explicit Mark Viewed did not clear unread membership');
    Require(Store.CollectionRevision(7)='remap-3','Mark Viewed changed catalogue revision');
    Store.RefreshCollection(Collection); Require(Store.NewCount(7)=0,'Refresh after acknowledgment recreated old badge');
    Require(THashSHA2.GetHashStringFromFile(Catalogue)=SourceHash,'Acknowledgment modified original books/groups/history/notes');
    Writeln('PASS favorite authors persistence, per-collection baselines, qualified library/provenance identity, ID remapping, coauthor dedup, cancel rollback and explicit acknowledgment');

    Other:=TAuthorFavorites.Create(Profile);
    Store.SetFavorite('Новый','Первый','',True);
    Other.SetFavorite('Новый','Второй','',True);
    Store.Reload;
    Require(Store.IsFavorite('Новый','Первый','') and Store.IsFavorite('Новый','Второй',''),
      'Independent stale favorite instances lost concurrent additions');
    Store.SetFavorite('Васильев [#168147]','Андрей','Александрович',True);
    Store.SetFavorite('Васильев','Андрей','Александрович [#168147]',True);
    Require(Store.RemoveFavorites([KingKey,AuthorFavoriteKey('Васильев [#168147]','Андрей','Александрович')]),
      'Global favorite removal did not remove selected persisted identities');
    Require(not Store.IsFavorite('Васильев [#168147]','Андрей','Александрович') and
      Store.IsFavorite('Васильев','Андрей','Александрович [#168147]'),
      'Removing absent old spelling also removed the other author identity');
    Require((Length(Store.BoundAuthorIDs(7))=1) and (Length(Store.BoundAuthorIDs(8))=1),
      'Global removal did not cascade bindings across collections');
    Hash:=THashSHA2.GetHashStringFromFile(Profile); Rejected:=False;
    try Store.RemoveFavorites([MartinKey,'invalid-key']);
    except on E: EAuthorFavorites do Rejected:=True; end;
    Require(Rejected and Store.IsFavorite('Мартин','Джордж','Р.Р.') and
      (THashSHA2.GetHashStringFromFile(Profile)=Hash),'Invalid bulk removal was not rejected atomically');
    Require(not Store.IsFavorite('Кинг','Стивен','') and Store.IsFavorite('Мартин','Джордж','Р.Р.'),
      'Removing favorite changed another author');
    Store.SetFavorite('Кинг','Стивен','',True); Store.RefreshCollection(Collection);
    Require(Store.NewCount(7,KingKey)=0,'Re-adding favorite did not create an existing-books baseline');
    FreeAndNil(Store); Store:=TAuthorFavorites.Create(Profile);
    Require(Store.IsFavorite('Кинг','Стивен','') and (Store.NewCount(7)=0),'Re-add/reopen lost favorite state');

    // Test the actual SQLite write lock separately from the cooperating mutex.
    Hash:=THashSHA2.GetHashStringFromFile(Profile); Raw:=AFROpenRaw(Profile);
    try
      AFRRawExecute(Raw,'BEGIN IMMEDIATE'); WasBusy:=False; Before:=GetTickCount64;
      try Store.SetFavorite('Не записать','Занято','',True);
      except on E: EAuthorFavoritesBusy do WasBusy:=True; end;
      Require(WasBusy and (GetTickCount64-Before<1000),'Favorite writer waited on a locked profile instead of failing promptly');
      AFRRawExecute(Raw,'ROLLBACK');
    finally SQLite3_Close(Raw); end;
    Require((THashSHA2.GetHashStringFromFile(Profile)=Hash) and not Store.IsFavorite('Не записать','Занято',''),
      'Locked write changed durable or cached favorites');
    Locked:=TEvent.Create(nil,True,False,''); Released:=TEvent.Create(nil,True,False,'');
    Worker:=nil; LockFailure:='';
    try
      Worker:=TThread.CreateAnonymousThread(procedure
        var Mutex: TFileMutex;
        begin
          Mutex:=TFileMutex.Create(Profile);
          try
            if not Mutex.TryAcquire then LockFailure:='Failed to acquire fixture mutex';
            Locked.SetEvent; Released.WaitFor(5000);
          finally Mutex.Free; end;
        end);
      Worker.FreeOnTerminate:=False; Worker.Start;
      Require((Locked.WaitFor(1000)=wrSignaled) and (LockFailure=''),'Favorite mutex fixture failed');
      WasBusy:=False; Before:=GetTickCount64;
      try Store.SetFavorite('Не записать','Мьютекс','',True);
      except on E: EAuthorFavoritesBusy do WasBusy:=True; end;
      Require(WasBusy and (GetTickCount64-Before<1000),'Cooperating favorite writer blocked on mutex');
    finally
      Released.SetEvent; if Worker<>nil then begin Worker.WaitFor; Worker.Free; end;
      Released.Free; Locked.Free;
    end;
    Require(THashSHA2.GetHashStringFromFile(Profile)=Hash,'Mutex rejected write altered profile');
    Rejected:=False;
    try Store.SetFavorite(StringOfChar('A',2049),'','',True);
    except on E: EAuthorFavorites do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Profile)=Hash),'Oversized author was accepted or modified profile');

    Unknown:=Folder+'unknown-version.sqlite'; TFile.Copy(Profile,Unknown,False); Raw:=AFROpenRaw(Unknown);
    try AFRRawExecute(Raw,'PRAGMA user_version=99'); finally SQLite3_Close(Raw); end;
    AFRRequireRejected(Unknown,'Unknown favorite schema version');
    Tampered:=Folder+'tampered-schema.sqlite'; TFile.Copy(Profile,Tampered,False); Raw:=AFROpenRaw(Tampered);
    try AFRRawExecute(Raw,'CREATE TRIGGER Unexpected AFTER INSERT ON FavoriteAuthors BEGIN DELETE FROM SeenBooks; END');
    finally SQLite3_Close(Raw); end;
    AFRRequireRejected(Tampered,'Unexpected favorite trigger');
    Corrupt:=Folder+'corrupt.sqlite'; TFile.WriteAllText(Corrupt,'This is not SQLite: мои данные.',TEncoding.UTF8);
    AFRRequireRejected(Corrupt,'Corrupt favorite profile');
    AFRRequireRejected(Catalogue,'Existing catalogue supplied as favorite profile');
    ReadonlyFile:=Folder+'readonly.sqlite'; TFile.Copy(Profile,ReadonlyFile,False);
    Hash:=THashSHA2.GetHashStringFromFile(ReadonlyFile);
    Require(SetFileAttributes(PChar(ReadonlyFile),FILE_ATTRIBUTE_READONLY),'Readonly fixture attribute failed');
    try
      FreeAndNil(Other); Other:=TAuthorFavorites.Create(ReadonlyFile); Rejected:=False;
      try Other.SetFavorite('Не записать','Только чтение','',True);
      except on E: EAuthorFavorites do Rejected:=True; end;
      Require(Rejected and (THashSHA2.GetHashStringFromFile(ReadonlyFile)=Hash),'Readonly favorite profile changed');
    finally SetFileAttributes(PChar(ReadonlyFile),FILE_ATTRIBUTE_NORMAL); end;
    Require(THashSHA2.GetHashStringFromFile(ProtectedFile)=ProtectedHash,'Favorite operations changed protected book/settings/notes/history sentinel');
    Require(THashSHA2.GetHashStringFromFile(Catalogue)=SourceHash,'Favorite guard tests changed catalogue or personal rows');
    Database:=TSQLiteDatabase.CreateReadOnly(Profile);
    try
      Require(Database.QuerySingleString('PRAGMA integrity_check')='ok','Favorite profile integrity failed');
      Require(Database.QuerySingleInt('SELECT COUNT(*) FROM pragma_foreign_key_check')=0,'Favorite membership has broken references');
    finally Database.Free; end;
    Writeln('PASS favorite authors isolated durable profile, stale-instance safety, nonblocking SQLite/mutex locks, readonly/unknown/corrupt guards, protected data hashes and integrity');
  finally Other.Free; Store.Free; end;
end;
