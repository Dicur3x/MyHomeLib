unit unit_BookDuplicates;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Globals,
  unit_CollectionMerge;

type
  TDuplicateBook = record
    Book: TBookRecord;
    HasPersonalData: Boolean;
  end;
  TDuplicateGroup = record
    ID, Count, KeepID: Integer;
    Identity, Title: string;
    Selected: Boolean;
  end;
  // This key finds candidates, never proves equal editions or file contents.
  TBookDuplicatePlan = class
  private
    FSource, FStage: TSQLiteDatabase;
    FFile, FRoot, FNamespace, FSystemFile, FReaderFile, FWorkRoot: string;
    FCID, FGroupCount, FScanned: Integer;
    FReady, FCommitted: Boolean;
    FRemoved: Integer;
    FBaseDigest: string;
    FCanceled: TMergeCanceled;
    function QueryCanceled: Boolean;
    procedure LoadPersonalProtection;
  public
    constructor Create(const CatalogFile, Root, LibraryNamespace, SystemFile,
      ReaderFile: string; CollectionID: Integer; const WorkRoot: string = '');
    destructor Destroy; override;
    procedure Preview(const Canceled: TMergeCanceled = nil; const Progress: TMergeProgress = nil);
    function Groups(Offset, Limit: Integer): TArray<TDuplicateGroup>;
    function Books(GroupID: Integer): TArray<TDuplicateBook>;
    procedure Choose(GroupID, KeepID: Integer; Selected: Boolean);
    procedure Apply(const BackupFolder: string; const Canceled: TMergeCanceled = nil;
      const Progress: TMergeStageProgress = nil);
    function SelectedCount: Integer;
    function SelectedRemovedCount: Integer;
    property GroupCount: Integer read FGroupCount;
    property Scanned: Integer read FScanned;
    property Ready: Boolean read FReady;
    property Committed: Boolean read FCommitted;
    property Removed: Integer read FRemoved;
  end;

function DuplicateCandidateKey(const Book: TBookRecord; const LibraryNamespace: string): string;

implementation

uses System.IniFiles, System.IOUtils, System.StrUtils, System.Hash, Winapi.Windows,
  unit_CollectionSpace, unit_LibrarySourceID,
  unit_ReaderCache, unit_ReaderNoteBooks, unit_ReaderAnnotations, unit_Consts;

function DuplicateCandidateKey(const Book: TBookRecord; const LibraryNamespace: string): string;
var ID, Namespace, Original: string; Depth, P: Integer; Nonzero: Boolean;
begin
  Result:='';
  if (bpIsDeleted in Book.BookProps) or (Book.Size<=0) or (Trim(Book.Title)='') or (Book.FileExt='') then Exit;
  ID:=Trim(Book.LibID); if (Length(ID)>4096) or (Pos(#0,ID)>0) then Exit;
  Depth:=0;
  while ID.StartsWith('merged:',True) do
  begin
    Inc(Depth); if Depth>32 then Exit;
    Delete(ID,1,7); P:=Pos(':',ID); if P<=1 then Exit;
    Delete(ID,1,P);
  end;
  if not TryParseLibrarySourceID(ID,Namespace,Original) then
    if not TryParseLibrarySourceID(ScopedLibraryID(Book.Folder,ID),Namespace,Original) then
      if not TryParseLibrarySourceID(LowerCase(Trim(LibraryNamespace))+':'+ID,Namespace,Original) then Exit;
  Nonzero:=False; for var C in Original do Nonzero:=Nonzero or (C<>'0');
  if not Nonzero then Exit;
  // Preserve the upstream identifier's exact spelling; no title-only matches.
  Result:=Namespace+':'+Original+#1+LowerCase(Trim(Book.Lang))+#1+LowerCase(Book.FileExt);
end;

constructor TBookDuplicatePlan.Create(const CatalogFile, Root, LibraryNamespace,
  SystemFile, ReaderFile: string; CollectionID: Integer; const WorkRoot: string);
begin
  inherited Create;
  FFile:=TPath.GetFullPath(CatalogFile); FRoot:=Root; FNamespace:=LibraryNamespace;
  FSystemFile:=SystemFile; FReaderFile:=ReaderFile; FCID:=CollectionID;
  FWorkRoot:=WorkRoot;
  if (CollectionID<=0) or (ReaderFile='') then
    raise EArgumentException.Create('Не задана коллекция или хранилище читалки.');
end;

destructor TBookDuplicatePlan.Destroy;
begin
  FSource.Free; FStage.Free; inherited;
end;

function TBookDuplicatePlan.QueryCanceled: Boolean;
begin Result:=Assigned(FCanceled) and FCanceled(); end;

function DuplicateQueryDigest(DB: TSQLiteDatabase; const SQL: string;
  const Params: array of const): string;
var Query: TSQLiteQuery; Data: TMemoryStream; Value: TStream; Size: Int64; Marker: Byte;
begin
  Data:=TMemoryStream.Create;
  try
    Query:=DB.NewQuery(SQL,Params);
    try
      Query.Open;
      while not Query.Eof do
      begin
        Marker:=2; Data.WriteBuffer(Marker,1);
        for var I:=0 to Query.ColCount-1 do
        begin
          Marker:=Ord(Query.FieldIsNull(I)); Data.WriteBuffer(Marker,1);
          Value:=Query.FieldAsBlob(I);
          try
            Size:=Value.Size; Data.WriteBuffer(Size,SizeOf(Size));
            if Size>0 then Data.CopyFrom(Value,Size);
          finally Value.Free; end;
        end;
        Query.Next;
      end;
    finally Query.Free; end;
    Data.Position:=0; Result:=THashSHA2.GetHashString(Data);
  finally Data.Free; end;
end;

procedure TBookDuplicatePlan.LoadPersonalProtection;
var DB: TSQLiteDatabase; Q, AddID, AddKey: TSQLiteQuery; Ini: TMemIniFile; Sections: TStringList;
  Store: TReaderAnnotations;
  StoredFile, StoredRoot: string;
begin
  FStage.ExecSQL('CREATE TABLE IF NOT EXISTS ProtectedBooks(BookID INTEGER PRIMARY KEY)');
  FStage.ExecSQL('CREATE TABLE IF NOT EXISTS ReaderKeys(Identity TEXT PRIMARY KEY)');
  FStage.Start;
  FStage.ExecSQL('DELETE FROM ProtectedBooks'); FStage.ExecSQL('DELETE FROM ReaderKeys');
  AddID:=FStage.NewQuery('INSERT OR IGNORE INTO ProtectedBooks VALUES(?)');
  AddKey:=FStage.NewQuery('INSERT OR IGNORE INTO ReaderKeys VALUES(?)');
  try
  DB:=TSQLiteDatabase.CreateReadOnly(FSystemFile);
  try
    if DB.QuerySingleInt('SELECT count(*) FROM Bases WHERE DatabaseID=?',[FCID])<>1 then
      raise EInvalidOperation.Create('Коллекция не зарегистрирована в личном хранилище.');
    if isOnlineCollection(DB.QuerySingleInt('SELECT Code FROM Bases WHERE DatabaseID=?',[FCID])) then
      raise EInvalidOperation.Create('Объединение повторов доступно только для локальной коллекции.');
    StoredFile:=DB.QuerySingleString('SELECT DBFileName FROM Bases WHERE DatabaseID=?',[FCID]);
    if ExtractFileExt(StoredFile)='' then StoredFile:=StoredFile+COLLECTION_EXTENSION;
    if not TPath.IsPathRooted(StoredFile) then StoredFile:=TPath.Combine(ExtractFileDir(FSystemFile),StoredFile);
    if not SameFileName(TPath.GetFullPath(StoredFile),FFile) then
      raise EInvalidOperation.Create('Файл каталога не соответствует выбранной коллекции.');
    StoredRoot:=DB.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[FCID]);
    if not TPath.IsPathRooted(StoredRoot) then
    begin
      if FWorkRoot='' then raise EInvalidOperation.Create('Не задана основа относительного пути к книгам.');
      StoredRoot:=TPath.Combine(FWorkRoot,StoredRoot);
    end;
    if not SameFileName(ExcludeTrailingPathDelimiter(TPath.GetFullPath(StoredRoot)),
      ExcludeTrailingPathDelimiter(TPath.GetFullPath(FRoot))) then
      raise EInvalidOperation.Create('Папка книг изменилась. Откройте окно повторов заново.');
    if FBaseDigest='' then FBaseDigest:=DuplicateQueryDigest(DB,'SELECT * FROM Bases WHERE DatabaseID=?',[FCID]);
    Q:=DB.NewQuery('SELECT BookID FROM Books WHERE DatabaseID=? UNION SELECT BookID FROM BookGroups WHERE DatabaseID=?');
    try
      Q.SetParam(0,FCID); Q.SetParam(1,FCID); Q.Open;
      while not Q.Eof do
      begin
        AddID.Reset; AddID.SetParam(0,Q.FieldAsInt(0)); AddID.ExecSQL; AddID.Reset; Q.Next;
      end;
    finally Q.Free; end;
  finally DB.Free; end;
  Ini:=TMemIniFile.Create(FReaderFile,TEncoding.UTF8); Sections:=TStringList.Create;
  try
    Ini.ReadSections(Sections);
    for var Section in Sections do
    begin
      if Section.StartsWith('Book.') then
      begin
        AddKey.Reset; AddKey.SetParam(0,Copy(Section,6,MaxInt)); AddKey.ExecSQL; AddKey.Reset;
        if Ini.ReadInteger(Section,'CollectionID',-1)=FCID then
        begin
          AddID.Reset; AddID.SetParam(0,Ini.ReadInteger(Section,'CatalogBookID',-1)); AddID.ExecSQL; AddID.Reset;
        end;
      end
      else if Section.StartsWith('Bookmarks.') then
      begin
        AddKey.Reset; AddKey.SetParam(0,Copy(Section,11,MaxInt)); AddKey.ExecSQL; AddKey.Reset;
      end;
    end;
  finally Ini.Free; Sections.Free; end;
  // The strict store parser rejects missing/corrupt notes instead of treating
  // them as an empty list and permitting destructive consolidation later.
  Store:=TReaderAnnotations.Create(FReaderFile);
  try
    for var Note in Store.Items do
    begin AddKey.Reset; AddKey.SetParam(0,Note.BookID); AddKey.ExecSQL; AddKey.Reset; end;
  finally Store.Free; end;
  FStage.Commit;
  finally AddID.Free; AddKey.Free; end;
end;

procedure TBookDuplicatePlan.Preview(const Canceled: TMergeCanceled; const Progress: TMergeProgress);
var Q, Insert: TSQLiteQuery; Book: TBookRecord; Key: string; Previous: TSQLiteCancelCallback;
  procedure Check;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
begin
  FReady:=False; FGroupCount:=0; FScanned:=0; FBaseDigest:=''; FreeAndNil(FSource); FreeAndNil(FStage);
  Check;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
   try
    FSource:=TSQLiteDatabase.CreateReadOnly(FFile); FSource.Start;
    // SQLite owns and removes this unnamed temporary database. Memory is
    // bounded on x86; the user's catalog and its indexes remain read-only.
    FStage:=TSQLiteDatabase.Create(''); FStage.ExecSQL('PRAGMA cache_size=-4096');
    FStage.ExecSQL('CREATE TABLE Candidates(BookID INTEGER PRIMARY KEY,Identity TEXT NOT NULL)');
    FStage.Start; FStage.BeginQueryBatch;
    Q:=FSource.NewQuery('SELECT BookID,LibID,Title,Lang,Ext,BookSize,IsDeleted,Folder FROM Books ORDER BY BookID');
    try
      Insert:=FStage.NewQuery('INSERT INTO Candidates VALUES(?,?)');
      try
        Q.Open;
        while not Q.Eof do
        begin
          Book:=Default(TBookRecord); Book.LibID:=Q.FieldAsString(1); Book.Title:=Q.FieldAsString(2);
          Book.Lang:=Q.FieldAsString(3); Book.FileExt:=Q.FieldAsString(4); Book.Size:=Q.FieldAsInt(5);
          Book.Folder:=Q.FieldAsString(7); if Q.FieldAsInt(6)<>0 then Include(Book.BookProps,bpIsDeleted);
          Key:=DuplicateCandidateKey(Book,FNamespace);
          if Key<>'' then
          begin
            Insert.Reset; Insert.SetParam(0,Q.FieldAsInt(0)); Insert.SetParam(1,Key); Insert.ExecSQL; Insert.Reset;
          end;
          Inc(FScanned);
          if FScanned mod 4096=0 then
          begin Check; if Assigned(Progress) then Progress(FScanned,0); end;
          Q.Next;
        end;
      finally Insert.Free; end;
    finally Q.Free; FStage.EndQueryBatch; end;
    Check; FStage.Commit;
    FStage.ExecSQL('CREATE INDEX CandidateIdentity ON Candidates(Identity,BookID)'); Check;
    FStage.ExecSQL('CREATE TABLE DuplicateGroups(GroupID INTEGER PRIMARY KEY,Identity TEXT UNIQUE,Count INTEGER,KeepID INTEGER,Selected INTEGER DEFAULT 0)');
    FStage.ExecSQL('INSERT INTO DuplicateGroups(Identity,Count,KeepID) SELECT Identity,count(*),min(BookID) FROM Candidates GROUP BY Identity HAVING count(*)>1 ORDER BY min(BookID)');
    FGroupCount:=FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups');
    LoadPersonalProtection; Check; FReady:=True;
    if Assigned(Progress) then Progress(FScanned,FScanned);
  except
    FreeAndNil(FSource); FreeAndNil(FStage); FGroupCount:=0; raise;
  end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

function TBookDuplicatePlan.Groups(Offset, Limit: Integer): TArray<TDuplicateGroup>;
var Q: TSQLiteQuery; Values: TList<TDuplicateGroup>; Group: TDuplicateGroup;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала выполните поиск повторов.');
  if (Offset<0) or (Limit<1) or (Limit>100) then raise EArgumentOutOfRangeException.Create('Страница повторов');
  Values:=TList<TDuplicateGroup>.Create;
  try
    Q:=FStage.NewQuery('SELECT GroupID,Identity,Count,KeepID,Selected FROM DuplicateGroups ORDER BY GroupID LIMIT ? OFFSET ?');
    try
      Q.SetParam(0,Limit); Q.SetParam(1,Offset); Q.Open;
      while not Q.Eof do
      begin
        Group:=Default(TDuplicateGroup); Group.ID:=Q.FieldAsInt(0); Group.Identity:=Q.FieldAsString(1);
        Group.Count:=Q.FieldAsInt(2); Group.KeepID:=Q.FieldAsInt(3); Group.Selected:=Q.FieldAsBoolean(4);
        Group.Title:=FSource.QuerySingleString('SELECT Title FROM Books WHERE BookID=?',[Group.KeepID]);
        Values.Add(Group); Q.Next;
      end;
    finally Q.Free; end;
    Result:=Values.ToArray;
  finally Values.Free; end;
end;

function TBookDuplicatePlan.Books(GroupID: Integer): TArray<TDuplicateBook>;
var IDs, Q: TSQLiteQuery; Values: TList<TDuplicateBook>; Value: TDuplicateBook;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала выполните поиск повторов.');
  Values:=TList<TDuplicateBook>.Create;
  try
    IDs:=FStage.NewQuery('SELECT c.BookID FROM Candidates c JOIN DuplicateGroups g USING(Identity) WHERE g.GroupID=? ORDER BY c.BookID');
    try
      IDs.SetParam(0,GroupID); IDs.Open;
      Q:=FSource.NewQuery('SELECT LibID,Title,Lang,Ext,BookSize,Folder,FileName,InsideNo,Rate,Progress,length(CAST(Review AS BLOB)),IsLocal FROM Books WHERE BookID=?');
      try
        while not IDs.Eof do
        begin
          if Values.Count>=1000 then
            raise EInvalidOperation.Create('В группе больше 1000 записей. Автоматическое объединение такой группы недоступно.');
          Value:=Default(TDuplicateBook); Value.Book.BookKey:=CreateBookKey(IDs.FieldAsInt(0),FCID);
          Q.Reset; Q.SetParam(0,IDs.FieldAsInt(0)); Q.Open;
          if Q.Eof then raise EInvalidOperation.Create('Запись книги исчезла из снимка.');
          Value.Book.LibID:=Q.FieldAsString(0); Value.Book.Title:=Q.FieldAsString(1);
          Value.Book.Lang:=Q.FieldAsString(2); Value.Book.FileExt:=Q.FieldAsString(3);
          Value.Book.Size:=Q.FieldAsInt(4); Value.Book.Folder:=Q.FieldAsString(5);
          Value.Book.FileName:=Q.FieldAsString(6); Value.Book.InsideNo:=Q.FieldAsInt(7);
          Value.Book.CollectionRoot:=FRoot; Value.Book.NodeType:=ntBookInfo;
          if Q.FieldAsInt(11)<>0 then Include(Value.Book.BookProps,bpIsLocal);
          Value.HasPersonalData:=(FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM ProtectedBooks WHERE BookID=?)',[IDs.FieldAsInt(0)])<>0) or
            (Q.FieldAsInt(8)<>0) or (Q.FieldAsInt(9)<>0) or (Q.FieldAsInt(10)>0) or
            (FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM ReaderKeys WHERE Identity=?)',
              [ReaderNoteIdentity(ReaderHistoryName(Value.Book,FNamespace))])<>0);
          Values.Add(Value); Q.Reset; IDs.Next;
        end;
      finally Q.Free; end;
    finally IDs.Free; end;
    Result:=Values.ToArray;
  finally Values.Free; end;
end;

procedure TBookDuplicatePlan.Choose(GroupID, KeepID: Integer; Selected: Boolean);
var Found: Boolean;
begin
  Found:=False;
  for var Value in Books(GroupID) do
  begin
    Found:=Found or (Value.Book.BookKey.BookID=KeepID);
    if Selected and Value.HasPersonalData and (Value.Book.BookKey.BookID<>KeepID) then
      raise EInvalidOperation.Create('У другой копии есть личные данные или история чтения. Оставьте её отдельной записью.');
  end;
  if not Found then raise EArgumentException.Create('Предпочтительная книга не входит в группу.');
  FStage.ExecSQL('UPDATE DuplicateGroups SET KeepID=?,Selected=? WHERE GroupID=?',[KeepID,Selected,GroupID]);
end;

function TBookDuplicatePlan.SelectedCount: Integer;
begin
  Result:=0; if FReady then Result:=FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups WHERE Selected<>0');
end;

function TBookDuplicatePlan.SelectedRemovedCount: Integer;
begin
  Result:=0; if FReady then Result:=FStage.QuerySingleInt('SELECT coalesce(sum(Count-1),0) FROM DuplicateGroups WHERE Selected<>0');
end;

procedure TBookDuplicatePlan.Apply(const BackupFolder: string; const Canceled: TMergeCanceled;
  const Progress: TMergeStageProgress);
var Catalog, Personal: TSQLiteDatabase; GroupsQuery, Map: TSQLiteQuery;
  ReaderHandle, NotesLock: THandle; CreatedReader: Boolean;
  GroupID, KeepID, LoseID, Total, Done: Integer; Values: TArray<TDuplicateBook>;
  BeforeCount, Required, FreeBytes: Int64; Previous: TSQLiteCancelCallback;
  Manifest: TStringList; Folder: string; Writer: TStreamWriter;
  procedure Check;
  begin if QueryCanceled then Abort; end;
  procedure Stage(const Text: string; Current, Count: Integer);
  begin Check; if Assigned(Progress) then Progress(Text,Current,Count); Check; end;
  procedure SameQuery(const SQL: string; const Params: array of const);
  begin
    if DuplicateQueryDigest(FSource,SQL,Params)<>DuplicateQueryDigest(Catalog,SQL,Params) then
      raise EInvalidOperation.Create('Книги или их связи изменились после предпросмотра. Повторите поиск повторов.');
  end;
  procedure Backup(const FileName, Destination, Caption: string);
  var Source: TSQLiteDatabase;
  begin
    Source:=TSQLiteDatabase.CreateReadOnly(FileName);
    try Source.BackupTo(Destination,
      procedure(Current,Count: Integer)
      begin
        if Self.QueryCanceled then Abort;
        if Assigned(Progress) then Progress(Caption,Current,Count);
        if Self.QueryCanceled then Abort;
      end);
    finally Source.Free; end;
  end;
  procedure PreserveFile(BookID: Integer);
  begin
    // Capture each primary location when it is not already a recorded copy.
    // No file existence probe, extraction, moving or deletion is performed.
    Catalog.ExecSQL('INSERT INTO CatalogBookCopies(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ?,BookID,?,?,Folder,FileName,Ext,InsideNo,BookSize,LibID FROM Books b WHERE BookID=? AND NOT EXISTS '+
      '(SELECT 1 FROM CatalogBookCopies c WHERE c.BookID=b.BookID AND c.Root=? COLLATE BINARY '+
      'AND c.Folder IS b.Folder COLLATE BINARY AND c.FileName IS b.FileName COLLATE BINARY '+
      'AND c.Ext IS b.Ext COLLATE BINARY AND c.InsideNo IS b.InsideNo)',
      ['dedupe-base:'+IntToStr(FCID)+':'+IntToStr(BookID),ExtractFileName(FFile),FRoot,BookID,FRoot]);
  end;
begin
  if not FReady or (SelectedCount=0) then
    raise EInvalidOperation.Create('Сначала выберите группы и предпочтительные записи в предпросмотре.');
  FCommitted:=False; FRemoved:=0; Catalog:=nil; Personal:=nil;
  ReaderHandle:=INVALID_HANDLE_VALUE; NotesLock:=INVALID_HANDLE_VALUE; CreatedReader:=False;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
   try
    Check; Folder:=TPath.GetFullPath(BackupFolder);
    if DirectoryExists(Folder) then raise EInvalidOperation.Create('Для резервной копии нужна новая папка.');
    Required:=TFile.GetSize(FFile)*2+TFile.GetSize(FSystemFile)+32*Int64(1024)*1024;
    for var Name in TArray<string>.Create(FFile+'-wal',FSystemFile+'-wal') do
      if FileExists(Name) then Inc(Required,TFile.GetSize(Name));
    FreeBytes:=CollectionDiskFree(Folder);
    if (FreeBytes<0) or (FreeBytes<Required) then
      raise EInvalidOperation.Create('Недостаточно подтверждённого свободного места для резервной копии и изменений каталога.');
    Stage('Защита личных данных и каталога',0,0);
    // Reserve SystemDB first, matching other maintenance operations. No rows
    // in it are changed; every personal owner must survive under its old ID.
    Personal:=TSQLiteDatabase.Create(FSystemFile); Personal.Start('','IMMEDIATE');
    if Personal.QuerySingleInt('SELECT count(*) FROM Bases WHERE DatabaseID=?',[FCID])<>1 then
      raise EInvalidOperation.Create('Коллекция не зарегистрирована в личном хранилище.');
    if DuplicateQueryDigest(Personal,'SELECT * FROM Bases WHERE DatabaseID=?',[FCID])<>FBaseDigest then
      raise EInvalidOperation.Create('Параметры коллекции изменились. Повторите предпросмотр.');
    Catalog:=TSQLiteDatabase.Create(FFile); Catalog.Start('','IMMEDIATE');
    SameQuery('SELECT * FROM Settings ORDER BY SettingID',[]);
    // The annotation writer uses this same exclusive lock. The INI handle
    // additionally prevents atomic replacement while identities are checked.
    ForceDirectories(ExtractFilePath(FReaderFile));
    NotesLock:=CreateFile(PChar(TPath.Combine(ExtractFilePath(FReaderFile),'reader-notes.json.lock')),
      GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,FILE_ATTRIBUTE_TEMPORARY or FILE_FLAG_DELETE_ON_CLOSE,0);
    if NotesLock=INVALID_HANDLE_VALUE then raise EInvalidOperation.Create('Заметки сейчас сохраняются. Закройте читалку и повторите поиск.');
    ReaderHandle:=CreateFile(PChar(FReaderFile),GENERIC_READ,FILE_SHARE_READ,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if (ReaderHandle=INVALID_HANDLE_VALUE) and (GetLastError=ERROR_FILE_NOT_FOUND) then
    begin
      ReaderHandle:=CreateFile(PChar(FReaderFile),GENERIC_READ,FILE_SHARE_READ,nil,
        CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
      CreatedReader:=ReaderHandle<>INVALID_HANDLE_VALUE;
      if (ReaderHandle=INVALID_HANDLE_VALUE) and (GetLastError=ERROR_FILE_EXISTS) then
        ReaderHandle:=CreateFile(PChar(FReaderFile),GENERIC_READ,FILE_SHARE_READ,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    end;
    if ReaderHandle=INVALID_HANDLE_VALUE then
      raise EInvalidOperation.Create('Настройки читалки сейчас меняются. Закройте читалку и повторите поиск.');
    LoadPersonalProtection;
    FStage.ExecSQL('DROP TABLE IF EXISTS ApplyMap');
    FStage.ExecSQL('CREATE TABLE ApplyMap(LoseID INTEGER PRIMARY KEY,KeepID INTEGER NOT NULL)');
    GroupsQuery:=FStage.NewQuery('SELECT GroupID,KeepID FROM DuplicateGroups WHERE Selected<>0 ORDER BY GroupID');
    try
      GroupsQuery.Open;
      while not GroupsQuery.Eof do
      begin
        Check; GroupID:=GroupsQuery.FieldAsInt(0); KeepID:=GroupsQuery.FieldAsInt(1);
        // Recheck freshly committed personal data under the reservation.
        Choose(GroupID,KeepID,True); Values:=Books(GroupID);
        if Length(Values)<2 then raise EInvalidOperation.Create('Группа повторов пуста.');
        for var Value in Values do
        begin
          LoseID:=Value.Book.BookKey.BookID;
          SameQuery('SELECT * FROM Books WHERE BookID=?',[LoseID]);
          SameQuery('SELECT * FROM Author_List WHERE BookID=? ORDER BY AuthorID',[LoseID]);
          SameQuery('SELECT * FROM Genre_List WHERE BookID=? ORDER BY GenreCode',[LoseID]);
          SameQuery('SELECT * FROM Series_List WHERE BookID=? ORDER BY SeriesID',[LoseID]);
          SameQuery('SELECT * FROM PublisherSeries_List WHERE BookID=? ORDER BY SeriesID',[LoseID]);
          SameQuery('SELECT * FROM CatalogPreferredSource WHERE BookID=?',[LoseID]);
          SameQuery('SELECT * FROM CatalogBookCopies WHERE BookID=? ORDER BY SourceKey',[LoseID]);
          if LoseID<>KeepID then FStage.ExecSQL('INSERT INTO ApplyMap VALUES(?,?)',[LoseID,KeepID]);
        end;
        GroupsQuery.Next;
      end;
    finally GroupsQuery.Free; end;
    Total:=FStage.QuerySingleInt('SELECT count(*) FROM ApplyMap');
    if Total=0 then raise EInvalidOperation.Create('Не выбраны повторные записи для объединения.');
    BeforeCount:=Catalog.QuerySingleInt('SELECT count(*) FROM Books');
    // With writers reserved, separate read-only connections can create a
    // current backup without invoking backup on a source write transaction.
    ForceDirectories(ExtractFileDir(Folder));
    if not CreateDirectory(PChar(Folder),nil) then RaiseLastOSError;
    Backup(FFile,TPath.Combine(Folder,'destination.hlc2'),'Резервная копия коллекции');
    Backup(FSystemFile,TPath.Combine(Folder,'system.hlc2'),'Резервная копия личных данных');
    Manifest:=TStringList.Create;
    try
      Manifest.Add('Коллекция: '+FFile); Manifest.Add('Группы и настройки: '+FSystemFile);
      Manifest.Add('Папка книг: '+FRoot); Manifest.Add('Файлы книг не изменяются и не удаляются.');
      Manifest.SaveToFile(TPath.Combine(Folder,'restore-paths.txt'),TEncoding.UTF8);
      Writer:=TStreamWriter.Create(TPath.Combine(Folder,'preview.txt'),False,TEncoding.UTF8);
      try
      Writer.WriteLine('Удаляемая запись'+#9+'Предпочтительная запись');
      Map:=FStage.NewQuery('SELECT LoseID,KeepID FROM ApplyMap ORDER BY LoseID');
      try
        Map.Open;
        while not Map.Eof do
        begin Writer.WriteLine(IntToStr(Map.FieldAsInt(0))+#9+IntToStr(Map.FieldAsInt(1))); Map.Next; end;
      finally Map.Free; end;
      finally Writer.Free; end;
    finally Manifest.Free; end;
    if not CreatedReader then TFile.Copy(FReaderFile,TPath.Combine(Folder,'reader.ini'),False);
    for var Name in TArray<string>.Create('reader-notes.json','reader-notes.json.bak') do
      if FileExists(TPath.Combine(ExtractFilePath(FReaderFile),Name)) then
        TFile.Copy(TPath.Combine(ExtractFilePath(FReaderFile),Name),TPath.Combine(Folder,Name),False);
    // The snapshot has now been compared against reserved current rows. Close
    // it before writes so rollback-journal catalogs can also commit safely.
    FreeAndNil(FSource); FReady:=False;
    Stage('Подготовка связей источников',0,0);
    Catalog.ExecSQL('CREATE INDEX IF NOT EXISTS IXCatalogSourceBooks_BookID ON CatalogSourceBooks(BookID)');
    Map:=FStage.NewQuery('SELECT LoseID,KeepID FROM ApplyMap ORDER BY LoseID');
    try
      Map.Open; Done:=0;
      while not Map.Eof do
      begin
        Check; LoseID:=Map.FieldAsInt(0); KeepID:=Map.FieldAsInt(1);
        PreserveFile(KeepID); PreserveFile(LoseID);
        Catalog.ExecSQL('INSERT OR IGNORE INTO Author_List(BookID,AuthorID) SELECT ?,AuthorID FROM Author_List WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('INSERT OR IGNORE INTO Genre_List(BookID,GenreCode) SELECT ?,GenreCode FROM Genre_List WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('INSERT OR IGNORE INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) '+
          'SELECT ?,SeriesID,SeqNumber,0,OrdNum+1000000 FROM Series_List WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('INSERT OR IGNORE INTO PublisherSeries_List(BookID,SeriesID,SeqNumber,OrdNum) '+
          'SELECT ?,SeriesID,SeqNumber,OrdNum+1000000 FROM PublisherSeries_List WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('UPDATE CatalogSourceBooks SET BookID=? WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('UPDATE CatalogBookCopies SET BookID=? WHERE BookID=?',[KeepID,LoseID]);
        Catalog.ExecSQL('DELETE FROM Books WHERE BookID=?',[LoseID]);
        if Catalog.LastChangedRows<>1 then raise EInvalidOperation.Create('Повторная запись изменилась во время объединения.');
        Inc(Done); Stage('Объединение выбранных записей',Done,Total); Map.Next;
      end;
    finally Map.Free; end;
    if Catalog.QuerySingleInt('SELECT count(*) FROM Books')<>BeforeCount-Total then
      raise EInvalidOperation.Create('Количество записей не совпало с предпросмотром. Изменения отменены.');
    Check; Catalog.Commit; FCommitted:=True; FRemoved:=Total;
   except
    FReady:=False; FreeAndNil(FSource); raise;
   end;
  finally
    // No post-commit file write is allowed to turn success into an apparent
    // rollback. SystemDB was reserved only, never modified by consolidation.
    Catalog.Free; Personal.Free;
    if ReaderHandle<>INVALID_HANDLE_VALUE then CloseHandle(ReaderHandle);
    if NotesLock<>INVALID_HANDLE_VALUE then CloseHandle(NotesLock);
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
  end;
end;

end.
