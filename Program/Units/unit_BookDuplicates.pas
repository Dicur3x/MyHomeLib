unit unit_BookDuplicates;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Globals,
  unit_CollectionMerge, unit_BookDeletionBinding;

const MAX_LINKED_DUPLICATE_SELECTION = 5000;
const DUPLICATE_FILE_BATCH_SIZE = 8000;

type
  TDuplicateBook = record
    Book: TBookRecord;
    SourceName, CopyKey: string;
    HasPersonalData, Selected: Boolean;
  end;
  TDuplicateGroup = record
    ID, Count, KeepID: Integer;
    Identity, Title: string;
    Selected: Boolean;
  end;
  TDuplicateDeletionCursor = record
    Archive: string;
    BookID: Integer;
  end;
  // This key finds candidates, never proves equal editions or file contents.
  TBookDuplicatePlan = class
  private
    FSource, FStage: TSQLiteDatabase;
    FFile, FRoot, FNamespace, FSystemFile, FReaderFile, FWorkRoot: string;
    FCID, FGroupCount, FScanned: Integer;
    FReady, FCommitted, FLinkedMode: Boolean;
    FRemoved: Integer;
    FBaseDigest, FTitle, FCatalogueKey: string;
    FCanceled: TMergeCanceled;
    function QueryCanceled: Boolean;
    procedure LoadPersonalProtection;
    function LinkedBooks(BookID: Integer): TArray<TDuplicateBook>;
    function PrepareLinkedDeletion(const Info: TCollectionInfo): TBookDeletionBinding;
    function PrepareDeletion(const Info: TCollectionInfo; const Canceled: TMergeCanceled;
      const Progress: TMergeProgress; InBatches: Boolean): TDuplicateFileDeletion;
  public
    constructor Create(const CatalogFile, Root, LibraryNamespace, SystemFile,
      ReaderFile: string; CollectionID: Integer; const WorkRoot: string = '');
    destructor Destroy; override;
    procedure Preview(const Canceled: TMergeCanceled = nil; const Progress: TMergeProgress = nil);
    procedure PreviewLinked(const Canceled: TMergeCanceled = nil; const Progress: TMergeProgress = nil);
    function Groups(Offset, Limit: Integer; UnmarkedOnly: Boolean = False): TArray<TDuplicateGroup>;
    function Books(GroupID: Integer): TArray<TDuplicateBook>;
    function Sources: TArray<string>;
    function SelectSource(const SourceName: string; const Canceled: TMergeCanceled = nil): Integer;
    function SelectSourcePriority(const SourcesByPriority: TArray<string>;
      const Canceled: TMergeCanceled = nil): Integer;
    procedure ClearSelection;
    procedure Choose(GroupID, KeepID: Integer; Selected: Boolean);
    procedure ChooseCopy(const CopyKey: string; Selected: Boolean);
    procedure Apply(const BackupFolder: string; const Canceled: TMergeCanceled = nil;
      const Progress: TMergeStageProgress = nil);
    function PrepareFileDeletion(const Info: TCollectionInfo; const Canceled: TMergeCanceled): TDuplicateFileDeletion;
    procedure PrepareDeletionBatches(const Info: TCollectionInfo; const Canceled: TMergeCanceled;
      const Progress: TMergeProgress);
    function NextDeletionBatch(const Info: TCollectionInfo; var Cursor: TDuplicateDeletionCursor;
      const Canceled: TMergeCanceled): TDuplicateFileDeletion;
    function SelectedCount: Integer;
    function SelectedRemovedCount: Integer;
    property GroupCount: Integer read FGroupCount;
    property Scanned: Integer read FScanned;
    property Ready: Boolean read FReady;
    property LinkedMode: Boolean read FLinkedMode;
    property Committed: Boolean read FCommitted;
    property Removed: Integer read FRemoved;
  end;

function DuplicateCandidateKey(const Book: TBookRecord; const LibraryNamespace: string): string;

implementation

uses System.IniFiles, System.IOUtils, System.StrUtils, System.Hash, System.JSON, Winapi.Windows,
  unit_CollectionSpace, unit_LibrarySourceID,
  unit_ReaderCache, unit_ReaderNoteBooks, unit_ReaderAnnotations, unit_Consts, unit_CollectionBackup,
  unit_ZipMemberDeletion;

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
    FTitle:=DB.QuerySingleString('SELECT BaseName FROM Bases WHERE DatabaseID=?',[FCID]);
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
var Q, Insert, Protected, ReaderKey: TSQLiteQuery; Book: TBookRecord;
  Key, SourceName, SourceID: string; Previous: TSQLiteCancelCallback;
  SourceNames: TDictionary<string,string>; JSON: TJSONValue;
  ProtectedBook, HasReaderKeys: Boolean; Separator: Integer;
  procedure Check;
  begin if Assigned(Canceled) and Canceled() then Abort; end;
begin
  SourceNames:=TDictionary<string,string>.Create;
  try
  FReady:=False; FLinkedMode:=False; FGroupCount:=0; FScanned:=0; FBaseDigest:=''; FreeAndNil(FSource); FreeAndNil(FStage);
  Check;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
   try
    FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(FFile),1,25);
    FSource:=TSQLiteDatabase.CreateReadOnly(FFile); FSource.Start;
    // SQLite owns and removes this unnamed temporary database. Memory is
    // bounded on x86; the user's catalog and its indexes remain read-only.
    FStage:=TSQLiteDatabase.Create(''); FStage.ExecSQL('PRAGMA cache_size=-4096');
    FStage.ExecSQL('CREATE TABLE Candidates(BookID INTEGER PRIMARY KEY,Identity TEXT NOT NULL,SourceName TEXT NOT NULL,Protected INTEGER NOT NULL)');
    // Reject changed paths and unreadable personal data before scanning a
    // large catalog. Apply rechecks the same data under writer reservations.
    LoadPersonalProtection; Check;
    JSON:=TJSONObject.ParseJSONValue(FSource.QuerySingleString(
      'SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_CATALOG_SOURCES]));
    try
      if Assigned(JSON) and not (JSON is TJSONArray) then
        raise EInvalidOperation.Create('Не удалось прочитать источники коллекции.');
      if JSON is TJSONArray then
        for var Item in TJSONArray(JSON) do
          if Item is TJSONObject then
            SourceNames.AddOrSetValue(TJSONObject(Item).GetValue<string>('id',''),
              TJSONObject(Item).GetValue<string>('name',''));
    finally JSON.Free; end;
    HasReaderKeys:=FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM ReaderKeys)')<>0;
    Protected:=FStage.NewQuery('SELECT BookID FROM ProtectedBooks ORDER BY BookID');
    ReaderKey:=nil;
    try
    Protected.Open;
    ReaderKey:=FStage.NewQuery('SELECT EXISTS(SELECT 1 FROM ReaderKeys WHERE Identity=?)');
    FStage.Start; FStage.BeginQueryBatch;
    Q:=FSource.NewQuery('SELECT b.BookID,b.LibID,b.Title,b.Lang,b.Ext,b.BookSize,b.IsDeleted,b.Folder,'+
      'b.FileName,b.InsideNo,b.Rate,b.Progress,length(CAST(b.Review AS BLOB)),p.SourceName '+
      'FROM Books b LEFT JOIN CatalogPreferredSource p ON p.BookID=b.BookID ORDER BY b.BookID');
    try
      Insert:=FStage.NewQuery('INSERT INTO Candidates VALUES(?,?,?,?)');
      try
        Q.Open;
        while not Q.Eof do
        begin
          Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(Q.FieldAsInt(0),FCID);
          Book.LibID:=Q.FieldAsString(1); Book.Title:=Q.FieldAsString(2);
          Book.Lang:=Q.FieldAsString(3); Book.FileExt:=Q.FieldAsString(4); Book.Size:=Q.FieldAsInt(5);
          Book.Folder:=Q.FieldAsString(7); if Q.FieldAsInt(6)<>0 then Include(Book.BookProps,bpIsDeleted);
          Key:=DuplicateCandidateKey(Book,FNamespace);
          if Key<>'' then
          begin
            SourceName:=Q.FieldAsString(13);
            if SourceName='' then
              if Book.LibID.StartsWith('merged:') then
              begin
                Separator:=PosEx(':',Book.LibID,8);
                SourceID:=Copy(Book.LibID,8,Separator-8);
                if (Separator<=8) or not SourceNames.TryGetValue(SourceID,SourceName) then SourceName:='';
              end
              else SourceName:=FTitle;
            while not Protected.Eof and (Protected.FieldAsInt(0)<Q.FieldAsInt(0)) do Protected.Next;
            ProtectedBook:=(not Protected.Eof and (Protected.FieldAsInt(0)=Q.FieldAsInt(0))) or
              (Q.FieldAsInt(10)<>0) or (Q.FieldAsInt(11)<>0) or (Q.FieldAsInt(12)>0);
            if HasReaderKeys and not ProtectedBook then
            begin
              Book.CollectionRoot:=FRoot; Book.FileName:=Q.FieldAsString(8); Book.InsideNo:=Q.FieldAsInt(9);
              ReaderKey.Reset; ReaderKey.SetParam(0,ReaderNoteIdentity(ReaderHistoryName(Book,FNamespace)));
              ReaderKey.Open; ProtectedBook:=ReaderKey.FieldAsInt(0)<>0; ReaderKey.Reset;
            end;
            Insert.Reset; Insert.SetParam(0,Q.FieldAsInt(0)); Insert.SetParam(1,Key);
            Insert.SetParam(2,SourceName); Insert.SetParam(3,ProtectedBook); Insert.ExecSQL; Insert.Reset;
          end;
          Inc(FScanned);
          if FScanned mod 4096=0 then
          begin Check; if Assigned(Progress) then Progress(FScanned,0); end;
          Q.Next;
        end;
      finally Insert.Free; end;
    finally Q.Free; FStage.EndQueryBatch; end;
    finally ReaderKey.Free; Protected.Free; end;
    Check; FStage.Commit;
    FStage.ExecSQL('CREATE INDEX CandidateIdentity ON Candidates(Identity,BookID)'); Check;
    FStage.ExecSQL('CREATE TABLE DuplicateGroups(GroupID INTEGER PRIMARY KEY,Identity TEXT UNIQUE,Count INTEGER,KeepID INTEGER,Selected INTEGER DEFAULT 0)');
    FStage.ExecSQL('INSERT INTO DuplicateGroups(Identity,Count,KeepID) SELECT Identity,count(*),min(BookID) FROM Candidates GROUP BY Identity HAVING count(*)>1 ORDER BY min(BookID)');
    FGroupCount:=FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups');
    Check; FReady:=True;
    if Assigned(Progress) then Progress(FScanned,FScanned);
  except
    FreeAndNil(FSource); FreeAndNil(FStage); FGroupCount:=0; raise;
  end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
  finally SourceNames.Free; end;
end;

function ReadDuplicateLocation(Q: TSQLiteQuery; First: Integer; const Root: string;
  const Key: TBookKey): TBookRecord;
begin
  Result:=Default(TBookRecord); Result.BookKey:=Key;
  Result.CollectionRoot:=Root; Result.LibID:=Q.FieldAsString(First);
  Result.Folder:=Q.FieldAsString(First+1); Result.FileName:=Q.FieldAsString(First+2);
  Result.FileExt:=Q.FieldAsString(First+3); Result.InsideNo:=Q.FieldAsInt(First+4);
end;

procedure TBookDuplicatePlan.PreviewLinked(const Canceled: TMergeCanceled; const Progress: TMergeProgress);
var Previous: TSQLiteCancelCallback; Q, Insert: TSQLiteQuery;
  CopyBook: TBookRecord; Identity, PrimaryIdentity, CopyKey: string;
  SourceIDs: TDictionary<string,Integer>; LastBookID: Integer;

  function SourceID(const Name, Root, Key: string): Integer;
  var Origin, Token, Folder: string; P: Integer;
  begin
    if Name='' then Exit(0);
    // Imported source keys carry the registered source ID before :file:.
    // Old entries without that ID are separated by their recorded root.
    P:=Pos(':file:',Key);
    if (P>1) and (Length(Key)-P=69) then Origin:=Copy(Key,1,P-1);
    Folder:=ExcludeTrailingPathDelimiter(Root.Replace('/','\'));
    Token:=Name+#1+LowerCase(Folder)+#1+Origin;
    if SourceIDs.TryGetValue(Token,Result) then Exit;
    Result:=SourceIDs.Count+1;
    FStage.ExecSQL('INSERT INTO LinkedSourceChoices(SourceID,Name,Root,Origin) VALUES(?,?,?,?)',
      [Result,Name,Folder,Origin]);
    SourceIDs.Add(Token,Result);
  end;

begin
  FReady:=False; FLinkedMode:=True; FGroupCount:=0; FScanned:=0;
  FreeAndNil(FSource); FreeAndNil(FStage);
  Q:=nil; Insert:=nil; SourceIDs:=nil; LastBookID:=0;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
    try
      if QueryCanceled then Abort;
      FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(FFile),1,25);
      FSource:=TSQLiteDatabase.CreateReadOnly(FFile); FSource.Start;
      FStage:=TSQLiteDatabase.Create(''); FStage.ExecSQL('PRAGMA cache_size=-4096');
      SourceIDs:=TDictionary<string,Integer>.Create;
      FStage.ExecSQL('CREATE TABLE LinkedCopies(CopyKey TEXT PRIMARY KEY,BookID INTEGER NOT NULL,'+
        'SourceID INTEGER NOT NULL,Selected INTEGER NOT NULL DEFAULT 0)');
      FStage.ExecSQL('CREATE TABLE LinkedSourceChoices(SourceID INTEGER PRIMARY KEY,Name TEXT NOT NULL,'+
        'Root TEXT NOT NULL,Origin TEXT NOT NULL,Caption TEXT)');
      Q:=FSource.NewQuery('SELECT c.SourceKey,c.BookID,c.SourceName,c.Root,c.LibID,c.Folder,c.FileName,c.Ext,c.InsideNo,'+
        'b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo FROM CatalogBookCopies c JOIN Books b USING(BookID) '+
        'WHERE b.IsDeleted=0');
      Insert:=FStage.NewQuery('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID) VALUES(?,?,?)');
      FStage.Start;
      Q.Open;
      while not Q.Eof do
      begin
        if QueryCanceled then Abort;
        var Key:=CreateBookKey(Q.FieldAsInt(1),FCID);
        if Key.BookID<>LastBookID then
        begin
          PrimaryIdentity:=ReaderBookPhysicalIdentity(ReadDuplicateLocation(Q,9,FRoot,Key));
          LastBookID:=Key.BookID;
        end;
        CopyBook:=ReadDuplicateLocation(Q,4,Q.FieldAsString(3),Key);
        if (PrimaryIdentity<>'') and not CopyBook.IsLinkedSource then
        begin
          Identity:=ReaderBookPhysicalIdentity(CopyBook);
          if (Identity<>'') and (Identity<>PrimaryIdentity) then
          begin
            CopyKey:=Q.FieldAsString(0);
            Insert.SetParam(0,CopyKey); Insert.SetParam(1,Key.BookID);
            Insert.SetParam(2,SourceID(Q.FieldAsString(2),CopyBook.CollectionRoot,CopyKey));
            Insert.ExecSQL; Insert.Reset;
          end;
        end;
        Inc(FScanned);
        if (FScanned mod 4096=0) and Assigned(Progress) then Progress(FScanned,0);
        Q.Next;
      end;
      FStage.Commit;
      FStage.ExecSQL('UPDATE LinkedSourceChoices AS a SET Caption=Name || CASE WHEN '+
        'EXISTS(SELECT 1 FROM LinkedSourceChoices b WHERE b.SourceID<>a.SourceID AND b.Name=a.Name) '+
        'THEN '' · '' || Root || CASE WHEN EXISTS(SELECT 1 FROM LinkedSourceChoices b WHERE b.SourceID<>a.SourceID '+
        'AND b.Name=a.Name AND b.Root=a.Root COLLATE NOCASE) THEN '' · '' || Origin ELSE '''' END ELSE '''' END');
      FStage.ExecSQL('CREATE INDEX LinkedBooks ON LinkedCopies(BookID)');
      FStage.ExecSQL('CREATE INDEX LinkedSources ON LinkedCopies(SourceID,Selected,BookID,CopyKey)');
      FStage.ExecSQL('CREATE INDEX LinkedSelected ON LinkedCopies(BookID) WHERE Selected=1');
      FStage.ExecSQL('CREATE TABLE LinkedGroups(BookID INTEGER PRIMARY KEY,Count INTEGER NOT NULL)');
      FStage.ExecSQL('INSERT INTO LinkedGroups SELECT BookID,count(*)+1 FROM LinkedCopies GROUP BY BookID');
      FGroupCount:=FStage.QuerySingleInt('SELECT count(*) FROM LinkedGroups');
      if QueryCanceled then Abort;
      FReady:=True;
      if Assigned(Progress) then Progress(FScanned,FScanned);
    finally Insert.Free; Q.Free; SourceIDs.Free; end;
  except
    FreeAndNil(FSource); FreeAndNil(FStage); FGroupCount:=0;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    raise;
  end;
  SQLiteCancelCallback:=Previous; FCanceled:=nil;
end;

function TBookDuplicatePlan.Sources: TArray<string>;
var Q: TSQLiteQuery; Names: TList<string>;
begin
  if not FReady then Exit(nil);
  Names:=TList<string>.Create;
  try
    if FLinkedMode then
      Q:=FStage.NewQuery('SELECT Caption FROM LinkedSourceChoices ORDER BY Caption')
    else
      Q:=FStage.NewQuery('SELECT DISTINCT c.SourceName FROM Candidates c JOIN DuplicateGroups g USING(Identity) '+
        'WHERE c.SourceName<>'''' ORDER BY c.SourceName');
    try
      Q.Open;
      while not Q.Eof do begin Names.Add(Q.FieldAsString(0)); Q.Next; end;
    finally Q.Free; end;
    Result:=Names.ToArray;
  finally Names.Free; end;
end;

function TBookDuplicatePlan.SelectSource(const SourceName: string; const Canceled: TMergeCanceled): Integer;
var Previous: TSQLiteCancelCallback;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала выполните поиск повторов.');
  if SourceName='' then raise EArgumentException.Create('Выберите предпочтительный источник.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
    if QueryCanceled then Abort;
    FStage.Start;
    try
      if FLinkedMode then
      begin
        if FStage.QuerySingleInt('SELECT count(*) FROM LinkedSourceChoices WHERE Caption=?',[SourceName])<>1 then
          raise EInvalidOperation.Create('Не удалось однозначно определить источник. Отметьте файлы вручную.');
        FStage.ExecSQL('UPDATE LinkedCopies SET Selected=1 WHERE CopyKey IN ('+
          'SELECT CopyKey FROM LinkedCopies WHERE SourceID=(SELECT SourceID FROM LinkedSourceChoices WHERE Caption=?) '+
          'AND Selected=0 ORDER BY BookID,CopyKey LIMIT ?)',
          [SourceName,MAX_LINKED_DUPLICATE_SELECTION-SelectedRemovedCount]);
        Result:=FStage.QuerySingleInt('SELECT changes()');
        if QueryCanceled then Abort;
        FStage.Commit;
        Exit;
      end;
      FStage.ExecSQL('DROP TABLE IF EXISTS SourceChoices');
      // Only a unique preferred copy in a group spanning known sources can be
      // chosen automatically. Preserve manual selections and all protected rows.
      FStage.ExecSQL('CREATE TEMP TABLE SourceChoices(GroupID INTEGER PRIMARY KEY,KeepID INTEGER NOT NULL)');
      FStage.ExecSQL('INSERT INTO SourceChoices '+
        'SELECT g.GroupID,min(CASE WHEN c.SourceName=? COLLATE BINARY THEN c.BookID END) FROM DuplicateGroups g '+
        'JOIN Candidates c USING(Identity) WHERE g.Selected=0 AND g.Count=2 '+
        'GROUP BY g.GroupID HAVING '+
        'sum(c.SourceName=? COLLATE BINARY)=1 AND '+
        'sum(c.SourceName='''')=0 AND count(DISTINCT c.SourceName)=2 AND '+
        'sum(c.Protected<>0 AND c.SourceName<>? COLLATE BINARY)=0', [SourceName,SourceName,SourceName]);
      Result:=FStage.QuerySingleInt('SELECT count(*) FROM SourceChoices');
      FStage.ExecSQL('UPDATE DuplicateGroups SET KeepID=(SELECT KeepID FROM SourceChoices s '+
        'WHERE s.GroupID=DuplicateGroups.GroupID),Selected=1 '+
        'WHERE GroupID IN (SELECT GroupID FROM SourceChoices)');
      if QueryCanceled then Abort;
      FStage.Commit;
    except FStage.Rollback; raise; end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

procedure TBookDuplicatePlan.ClearSelection;
begin
  if not FReady then Exit;
  if FLinkedMode then FStage.ExecSQL('UPDATE LinkedCopies SET Selected=0 WHERE Selected=1')
  else FStage.ExecSQL('UPDATE DuplicateGroups SET Selected=0 WHERE Selected<>0');
end;

function TBookDuplicatePlan.SelectSourcePriority(const SourcesByPriority: TArray<string>;
  const Canceled: TMergeCanceled): Integer;
var Previous: TSQLiteCancelCallback;
begin
  if not FReady or FLinkedMode then
    raise EInvalidOperation.Create('Сначала найдите повторные записи книг.');
  if Length(SourcesByPriority)<2 then
    raise EArgumentException.Create('Для массового выбора нужны хотя бы два известных источника.');
  Previous:=SQLiteCancelCallback;
  FCanceled:=Canceled;
  SQLiteCancelCallback:=QueryCanceled;
  try
    if QueryCanceled then Abort;
    FStage.Start;
    try
      FStage.ExecSQL('CREATE TEMP TABLE SourcePriority(Name TEXT PRIMARY KEY, Position INTEGER NOT NULL) WITHOUT ROWID');
      for var I:=0 to High(SourcesByPriority) do
      begin
        if SourcesByPriority[I]='' then raise EArgumentException.Create('Не указан источник.');
        FStage.ExecSQL('INSERT INTO temp.SourcePriority VALUES(?,?)',[SourcesByPriority[I],I]);
      end;
      // Every copy must belong to a different ranked source. A copy with
      // personal data may be kept, but never selected for removal.
      FStage.ExecSQL('WITH RankedGroups AS MATERIALIZED ('+
        'SELECT g.GroupID,g.Identity,min(p.Position) AS Best FROM DuplicateGroups g '+
        'JOIN Candidates c USING(Identity) LEFT JOIN temp.SourcePriority p ON p.Name=c.SourceName '+
        'WHERE g.Selected=0 AND g.Count BETWEEN 2 AND 1000 GROUP BY g.GroupID '+
        'HAVING count(DISTINCT p.Position)=g.Count AND '+
        'coalesce(max(CASE WHEN c.Protected<>0 THEN p.Position END),min(p.Position))=min(p.Position)) '+
        'UPDATE DuplicateGroups AS g SET KeepID=c.BookID,Selected=1 FROM RankedGroups r '+
        'JOIN temp.SourcePriority p ON p.Position=r.Best '+
        'JOIN Candidates c ON c.Identity=r.Identity AND c.SourceName=p.Name WHERE g.GroupID=r.GroupID');
      Result:=FStage.QuerySingleInt('SELECT changes()');
      FStage.ExecSQL('DROP TABLE temp.SourcePriority');
      if QueryCanceled then Abort;
      FStage.Commit;
    except FStage.Rollback; raise; end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

function TBookDuplicatePlan.Groups(Offset, Limit: Integer; UnmarkedOnly: Boolean): TArray<TDuplicateGroup>;
var Q: TSQLiteQuery; Values: TList<TDuplicateGroup>; Group: TDuplicateGroup;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала выполните поиск повторов.');
  if (Offset<0) or (Limit<1) or (Limit>100) then raise EArgumentOutOfRangeException.Create('Страница повторов');
  Values:=TList<TDuplicateGroup>.Create;
  try
    if FLinkedMode then
      Q:=FStage.NewQuery('SELECT BookID,'''',Count,BookID,EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.BookID=g.BookID '+
        'AND c.Selected=1) FROM LinkedGroups g ORDER BY BookID LIMIT ? OFFSET ?')
    else
      Q:=FStage.NewQuery('SELECT GroupID,Identity,Count,KeepID,Selected FROM DuplicateGroups '+
        IfThen(UnmarkedOnly,'WHERE Selected=0 ','')+'ORDER BY GroupID LIMIT ? OFFSET ?');
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
  if FLinkedMode then Exit(LinkedBooks(GroupID));
  Values:=TList<TDuplicateBook>.Create;
  try
    IDs:=FStage.NewQuery('SELECT c.BookID,c.SourceName FROM Candidates c JOIN DuplicateGroups g USING(Identity) WHERE g.GroupID=? ORDER BY c.BookID');
    try
      IDs.SetParam(0,GroupID); IDs.Open;
      Q:=FSource.NewQuery('SELECT LibID,Title,Lang,Ext,BookSize,Folder,FileName,InsideNo,Rate,Progress,length(CAST(Review AS BLOB)),IsLocal FROM Books WHERE BookID=?');
      try
        while not IDs.Eof do
        begin
          if Values.Count>=1000 then
            raise EInvalidOperation.Create('В группе больше 1000 записей. Автоматическое объединение такой группы недоступно.');
          Value:=Default(TDuplicateBook); Value.Book.BookKey:=CreateBookKey(IDs.FieldAsInt(0),FCID);
          Value.SourceName:=IDs.FieldAsString(1);
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

function TBookDuplicatePlan.LinkedBooks(BookID: Integer): TArray<TDuplicateBook>;
var Q, Staged: TSQLiteQuery; Values: TList<TDuplicateBook>; Primary, Entry: TDuplicateBook;
begin
  Values:=TList<TDuplicateBook>.Create;
  Q:=nil; Staged:=nil;
  try
    Q:=FSource.NewQuery('SELECT b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.Title,b.Lang,b.BookSize,p.SourceName '+
      'FROM Books b LEFT JOIN CatalogPreferredSource p USING(BookID) WHERE b.BookID=?',[BookID]);
    Q.Open;
    if Q.Eof then raise EReadError.Create('Основная запись исчезла из снимка.');
    Primary:=Default(TDuplicateBook);
    Primary.Book:=ReadDuplicateLocation(Q,0,FRoot,CreateBookKey(BookID,FCID));
    Primary.Book.Title:=Q.FieldAsString(5); Primary.Book.Lang:=Q.FieldAsString(6);
    Primary.Book.Size:=Q.FieldAsInt(7); Primary.SourceName:=Q.FieldAsString(8);
    Values.Add(Primary); FreeAndNil(Q);
    Staged:=FStage.NewQuery('SELECT c.CopyKey,s.Caption,c.Selected FROM LinkedCopies c LEFT JOIN LinkedSourceChoices s USING(SourceID) '+
      'WHERE c.BookID=? ORDER BY c.CopyKey',[BookID]);
    Q:=FSource.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,BookSize FROM CatalogBookCopies WHERE SourceKey=?');
    Staged.Open;
    while not Staged.Eof do
    begin
      if Values.Count>=1000 then raise EReadError.Create('С этой книгой связано больше 999 дополнительных копий.');
      Entry:=Default(TDuplicateBook);
      Entry.CopyKey:=Staged.FieldAsString(0); Entry.SourceName:=Staged.FieldAsString(1);
      Entry.Selected:=Staged.FieldAsBoolean(2);
      Q.SetParam(0,Entry.CopyKey); Q.Open;
      if Q.Eof then raise EReadError.Create('Дополнительная копия исчезла из снимка.');
      Entry.Book:=ReadDuplicateLocation(Q,0,Q.FieldAsString(5),Primary.Book.BookKey);
      Entry.Book.Title:=Primary.Book.Title; Entry.Book.Lang:=Primary.Book.Lang;
      Entry.Book.Size:=Q.FieldAsInt(6);
      Values.Add(Entry); Q.Reset; Staged.Next;
    end;
    Result:=Values.ToArray;
  finally Q.Free; Staged.Free; Values.Free; end;
end;

procedure TBookDuplicatePlan.ChooseCopy(const CopyKey: string; Selected: Boolean);
begin
  if not FReady or not FLinkedMode or (CopyKey='') then
    raise EArgumentException.Create('Основная копия сохраняется.');
  var Previous:=FStage.QuerySingleInt('SELECT Selected FROM LinkedCopies WHERE CopyKey=?',[CopyKey]);
  if Selected and (Previous=0) and (SelectedRemovedCount>=MAX_LINKED_DUPLICATE_SELECTION) then
    raise EInvalidOperation.CreateFmt('За один раз можно удалить до %d дополнительных копий.',[MAX_LINKED_DUPLICATE_SELECTION]);
  FStage.ExecSQL('UPDATE LinkedCopies SET Selected=? WHERE CopyKey=?',[Ord(Selected),CopyKey]);
end;

procedure TBookDuplicatePlan.Choose(GroupID, KeepID: Integer; Selected: Boolean);
var Found: Boolean;
begin
  if FReady and FLinkedMode then
  begin
    if Selected and (SelectedRemovedCount+
      FStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE BookID=? AND Selected=0',[GroupID])>
      MAX_LINKED_DUPLICATE_SELECTION) then
      raise EInvalidOperation.CreateFmt('За один раз можно удалить до %d дополнительных копий.',[MAX_LINKED_DUPLICATE_SELECTION]);
    FStage.ExecSQL('UPDATE LinkedCopies SET Selected=? WHERE BookID=?',[Ord(Selected),GroupID]);
    Exit;
  end;
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
  if not FReady then Exit(0);
  if FLinkedMode then Exit(FStage.QuerySingleInt('SELECT count(DISTINCT BookID) FROM LinkedCopies WHERE Selected=1'));
  Result:=FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups WHERE Selected<>0');
end;

function TBookDuplicatePlan.SelectedRemovedCount: Integer;
begin
  if not FReady then Exit(0);
  if FLinkedMode then Exit(FStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE Selected=1'));
  Result:=FStage.QuerySingleInt('SELECT coalesce(sum(Count-1),0) FROM DuplicateGroups WHERE Selected<>0');
end;

function TBookDuplicatePlan.PrepareLinkedDeletion(const Info: TCollectionInfo): TBookDeletionBinding;
var Selection, Q: TSQLiteQuery; Keys: TArray<string>; Copies, Primary: TArray<TBookRecord>;
begin
  if not SameFileName(ExcludeTrailingPathDelimiter(Info.GetRootPath),ExcludeTrailingPathDelimiter(FRoot)) then
    raise EReadError.Create('Папка книг изменилась. Повторите поиск дополнительных копий.');
  var Count:=SelectedRemovedCount;
  if (Count=0) or (Count>MAX_LINKED_DUPLICATE_SELECTION) then
    raise EReadError.Create('Неверное число дополнительных копий в выбранной партии.');
  SetLength(Keys,Count); SetLength(Copies,Count); SetLength(Primary,Count);
  Selection:=FStage.NewQuery('SELECT CopyKey,BookID FROM LinkedCopies WHERE Selected=1 ORDER BY BookID,CopyKey');
  Q:=nil;
  try
    Q:=FSource.NewQuery('SELECT c.LibID,c.Folder,c.FileName,c.Ext,c.InsideNo,c.Root,'+
      'b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo FROM CatalogBookCopies c JOIN Books b USING(BookID) WHERE c.SourceKey=? AND c.BookID=?');
    Selection.Open;
    for var I:=0 to Count-1 do
    begin
      if QueryCanceled then Abort;
      if Selection.Eof then raise EReadError.Create('Выбор дополнительных копий изменился.');
      Keys[I]:=Selection.FieldAsString(0);
      var Key:=CreateBookKey(Selection.FieldAsInt(1),FCID);
      Q.SetParam(0,Keys[I]); Q.SetParam(1,Key.BookID); Q.Open;
      if Q.Eof then raise EReadError.Create('Дополнительная копия исчезла из снимка.');
      Copies[I]:=ReadDuplicateLocation(Q,0,Q.FieldAsString(5),Key);
      Primary[I]:=ReadDuplicateLocation(Q,6,FRoot,Key);
      Q.Reset; Selection.Next;
    end;
    if not Selection.Eof then raise EReadError.Create('Выбор дополнительных копий изменился.');
    Result:=TBookDeletionBinding.CaptureCopies(Info,Copies,Primary,Keys);
  finally Q.Free; Selection.Free; end;
end;

function TBookDuplicatePlan.PrepareFileDeletion(const Info: TCollectionInfo;
  const Canceled: TMergeCanceled): TDuplicateFileDeletion;
begin
  Result:=PrepareDeletion(Info,Canceled,nil,False);
end;

procedure TBookDuplicatePlan.PrepareDeletionBatches(const Info: TCollectionInfo;
  const Canceled: TMergeCanceled; const Progress: TMergeProgress);
begin
  if FLinkedMode then raise EInvalidOperation.Create('Выберите режим поиска повторных записей.');
  PrepareDeletion(Info,Canceled,Progress,True);
  FreeAndNil(FSource);
end;

function TBookDuplicatePlan.PrepareDeletion(const Info: TCollectionInfo;
  const Canceled: TMergeCanceled; const Progress: TMergeProgress; InBatches: Boolean): TDuplicateFileDeletion;
var Current, Personal: TSQLiteDatabase; Selection, Copies, AddRemoved, AddKept: TSQLiteQuery;
  Removed, Retained: TList<TBookRecord>;
  Previous: TSQLiteCancelCallback;
  GroupsTotal, RemovedTotal, GroupsDone, RemovedDone: Integer;
  BatchQueries: Boolean;
  procedure CheckCanceled;
  begin if QueryCanceled then Abort; end;
  procedure BindBookLocation(Query: TSQLiteQuery; First: Integer; const Book: TBookRecord);
  begin
    Query.SetParam(First,Book.BookKey.BookID);
    Query.SetParam(First+1,Book.LibID);
    Query.SetParam(First+2,Book.Folder);
    Query.SetParam(First+3,Book.FileName);
    Query.SetParam(First+4,Book.FileExt);
    Query.SetParam(First+5,Book.InsideNo);
  end;
begin
  Result:=Default(TDuplicateFileDeletion);
  if not FReady or (SelectedCount=0) then
    raise EInvalidOperation.Create('Сначала отметьте группы и выберите копии, которые нужно сохранить.');
  if (Info.ID<>FCID) or isOnlineCollection(Info.CollectionType) or
    not SameFileName(FFile,Info.DBFileName) or
    (Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey) then
    raise EInvalidOperation.Create('Коллекция изменилась. Повторите поиск дублей.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  Current:=nil; Personal:=nil; Selection:=nil; Copies:=nil; Removed:=nil; Retained:=nil;
  AddRemoved:=nil; AddKept:=nil; BatchQueries:=False;
  try
    CheckCanceled;
    if FLinkedMode then
    begin
      Result.Removed:=PrepareLinkedDeletion(Info);
      Exit;
    end;
    LoadPersonalProtection;
    Personal:=TSQLiteDatabase.CreateReadOnly(FSystemFile);
    if DuplicateQueryDigest(Personal,'SELECT * FROM Bases WHERE DatabaseID=?',[FCID])<>FBaseDigest then
      raise EInvalidOperation.Create('Параметры коллекции изменились. Повторите поиск дублей.');
    Current:=TSQLiteDatabase.CreateReadOnly(FFile);
    Current.Start;
    if DuplicateQueryDigest(Current,'SELECT * FROM Settings ORDER BY SettingID',[])<>
       DuplicateQueryDigest(FSource,'SELECT * FROM Settings ORDER BY SettingID',[]) then
      raise EInvalidOperation.Create('Настройки коллекции изменились. Повторите поиск дублей.');
    FSource.BeginQueryBatch; FStage.BeginQueryBatch; Current.BeginQueryBatch;
    BatchQueries:=True;
    if InBatches then
    begin
      // Stage only file identities in the existing disk-backed preview.
      // Release the old catalogue snapshot before the first archive write.
      FStage.Start;
      FStage.ExecSQL('CREATE TABLE DeletionKept(BookID INTEGER PRIMARY KEY,LibID TEXT,Folder TEXT,'+
        'FileName TEXT,Ext TEXT,InsideNo INTEGER)');
      FStage.ExecSQL('CREATE TABLE DeletionFiles(Archive TEXT,BookID INTEGER,LibID TEXT,Folder TEXT,'+
        'FileName TEXT,Ext TEXT,InsideNo INTEGER,KeepID INTEGER,PRIMARY KEY(Archive,BookID)) WITHOUT ROWID');
      AddRemoved:=FStage.NewQuery('INSERT INTO DeletionFiles VALUES(?,?,?,?,?,?,?,?)');
      AddKept:=FStage.NewQuery('INSERT INTO DeletionKept VALUES(?,?,?,?,?,?)');
    end
    else
    begin
      Removed:=TList<TBookRecord>.Create;
      Retained:=TList<TBookRecord>.Create;
    end;
    GroupsTotal:=SelectedCount; RemovedTotal:=SelectedRemovedCount;
    GroupsDone:=0; RemovedDone:=0;
    Selection:=FStage.NewQuery('SELECT GroupID,KeepID FROM DuplicateGroups WHERE Selected<>0 ORDER BY GroupID');
    Copies:=Current.NewQuery('SELECT Root,Folder,FileName,Ext,InsideNo FROM CatalogBookCopies WHERE BookID=?');
    Selection.Open;
    while not Selection.Eof do
    begin
      CheckCanceled;
      var KeepID:=Selection.FieldAsInt(1);
      var Group:=Books(Selection.FieldAsInt(0));
      for var Item in Group do
      begin
        CheckCanceled;
        var Book:=Item.Book;
        var ID:=Book.BookKey.BookID;
        if DuplicateQueryDigest(Current,'SELECT * FROM Books WHERE BookID=?',[ID])<>
           DuplicateQueryDigest(FSource,'SELECT * FROM Books WHERE BookID=?',[ID]) then
          raise EInvalidOperation.Create('Запись книги изменилась. Повторите поиск дублей.');
        if ID=KeepID then
        begin
          if InBatches then
          begin
            BindBookLocation(AddKept,0,Book);
            AddKept.ExecSQL; AddKept.Reset;
          end
          else Retained.Add(Book);
          Continue;
        end;
        if Item.HasPersonalData then
          raise EInvalidOperation.CreateFmt('У копии «%s» есть личные данные или история чтения. Она защищена от удаления.',[Book.Title]);
        Copies.Reset; Copies.SetParam(0,ID); Copies.Open;
        while not Copies.Eof do
        begin
          var Linked:=Default(TBookRecord);
          Linked.CollectionRoot:=Copies.FieldAsString(0);
          Linked.Folder:=Copies.FieldAsString(1);
          Linked.FileName:=Copies.FieldAsString(2);
          Linked.FileExt:=Copies.FieldAsString(3);
          Linked.InsideNo:=Copies.FieldAsInt(4);
          if ReaderBookPhysicalIdentity(Linked)<>ReaderBookPhysicalIdentity(Book) then
            raise EInvalidOperation.CreateFmt('С записью «%s» связаны дополнительные копии. '+
              'Чтобы выбрать эти файлы отдельно, нажмите «Найти дополнительные копии».',[Book.Title]);
          Copies.Next;
        end;
        if InBatches then
        begin
          AddRemoved.SetParam(0,UpperCase(TPath.GetFullPath(Book.GetBookFileName)));
          BindBookLocation(AddRemoved,1,Book);
          AddRemoved.SetParam(7,KeepID);
          AddRemoved.ExecSQL; AddRemoved.Reset;
        end
        else Removed.Add(Book);
        Inc(RemovedDone);
      end;
      Inc(GroupsDone);
      if Assigned(Progress) and ((GroupsDone mod 256=0) or (GroupsDone=GroupsTotal)) then
        Progress(GroupsDone,GroupsTotal);
      Selection.Next;
    end;
    CheckCanceled;
    if (GroupsDone<>GroupsTotal) or (RemovedDone<>RemovedTotal) or
      (Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey) then
      raise EInvalidOperation.Create('Выбор или каталог изменились. Повторите поиск дублей.');
    if InBatches then FStage.Commit
    else
    begin
      Result.Removed:=TBookDeletionBinding.Capture(Info,Removed.ToArray,True);
      Result.Retained:=TBookDeletionBinding.Capture(Info,Retained.ToArray,True);
    end;
  finally
    AddKept.Free; AddRemoved.Free;
    Copies.Free; Selection.Free;
    if BatchQueries then
    begin Current.EndQueryBatch; FStage.EndQueryBatch; FSource.EndQueryBatch; end;
    Retained.Free; Removed.Free; Personal.Free; Current.Free;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    if FStage.InTransaction then FStage.Rollback;
  end;
end;

function TBookDuplicatePlan.NextDeletionBatch(const Info: TCollectionInfo;
  var Cursor: TDuplicateDeletionCursor; const Canceled: TMergeCanceled): TDuplicateFileDeletion;
var Q: TSQLiteQuery; Removed, Retained: TArray<TBookRecord>;
  Order: TArray<string>; Seen: TDictionary<Integer,Byte>; Count, Boundary, KeptCount: Integer;
  Previous: TSQLiteCancelCallback;
  function ReadBook(First: Integer): TBookRecord;
  begin
    Result:=ReadDuplicateLocation(Q,First+1,FRoot,CreateBookKey(Q.FieldAsInt(First),FCID));
  end;
begin
  Result:=Default(TDuplicateFileDeletion);
  if Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey then
    raise EReadError.Create('Коллекция изменилась. Повторите поиск дублей.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  Seen:=nil; Q:=nil;
  try
    if QueryCanceled then Abort;
    Q:=FStage.NewQuery('SELECT d.Archive,d.BookID,d.LibID,d.Folder,d.FileName,d.Ext,d.InsideNo,'+
      'k.BookID,k.LibID,k.Folder,k.FileName,k.Ext,k.InsideNo FROM DeletionFiles d JOIN DeletionKept k '+
      'ON k.BookID=d.KeepID WHERE (d.Archive,d.BookID)>(?,?) '+
      'ORDER BY d.Archive,d.BookID LIMIT ?',[Cursor.Archive,Cursor.BookID,DUPLICATE_FILE_BATCH_SIZE+1]);
    Q.Open;
    if Q.Eof then Exit;
    LoadPersonalProtection;
    SetLength(Removed,DUPLICATE_FILE_BATCH_SIZE); SetLength(Retained,DUPLICATE_FILE_BATCH_SIZE);
    SetLength(Order,DUPLICATE_FILE_BATCH_SIZE); Count:=0; Boundary:=0;
    while not Q.Eof and (Count<DUPLICATE_FILE_BATCH_SIZE) do
    begin
      if QueryCanceled then Abort;
      Order[Count]:=Q.FieldAsString(0);
      if (Count>0) and (Order[Count]<>Order[Count-1]) then Boundary:=Count;
      Removed[Count]:=ReadBook(1); Retained[Count]:=ReadBook(7);
      Inc(Count); Q.Next;
    end;
    if not Q.Eof and (Q.FieldAsString(0)=Order[Count-1]) and (Boundary>0) then Count:=Boundary;
    SetLength(Removed,Count);
    Seen:=TDictionary<Integer,Byte>.Create; KeptCount:=0;
    for var I:=0 to Count-1 do
    begin
      if QueryCanceled then Abort;
      var Book:=Removed[I];
      if FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM ProtectedBooks WHERE BookID=?) OR '+
        'EXISTS(SELECT 1 FROM ReaderKeys WHERE Identity=?)',[Book.BookKey.BookID,
        ReaderNoteIdentity(ReaderHistoryName(Book,FNamespace))])<>0 then
        raise EReadError.CreateFmt('У удаляемой записи %d появились личные данные. Повторите поиск дублей.',
          [Book.BookKey.BookID]);
      if Seen.ContainsKey(Retained[I].BookKey.BookID) then Continue;
      Seen.Add(Retained[I].BookKey.BookID,0); Retained[KeptCount]:=Retained[I]; Inc(KeptCount);
    end;
    SetLength(Retained,KeptCount);
    Result.Removed:=TBookDeletionBinding.Capture(Info,Removed,True);
    Result.Retained:=TBookDeletionBinding.Capture(Info,Retained,True);
    Cursor.Archive:=Order[Count-1]; Cursor.BookID:=Removed[Count-1].BookKey.BookID;
  finally
    Q.Free; Seen.Free;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    if FStage.InTransaction then FStage.Rollback;
  end;
end;

procedure TBookDuplicatePlan.Apply(const BackupFolder: string; const Canceled: TMergeCanceled;
  const Progress: TMergeStageProgress);
var Catalog, Personal: TSQLiteDatabase; GroupsQuery, Map: TSQLiteQuery;
  ReaderHandle, NotesLock: THandle; CreatedReader: Boolean;
  GroupID, KeepID, LoseID, Total, Done: Integer; Values: TArray<TDuplicateBook>;
  BeforeCount, Required, FreeBytes: Int64; Previous: TSQLiteCancelCallback;
  Manifest: TStringList; Folder, PreferredSource: string; Writer: TStreamWriter;
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
  function PreserveFile(BookID: Integer): string;
  var Q: TSQLiteQuery; Primary, CopyBook: TBookRecord; Identity: string; Found: Boolean;
  begin
    Result:=Catalog.QuerySingleString('SELECT SourceName FROM CatalogPreferredSource WHERE BookID=?',[BookID]);
    if Result='' then Result:=FTitle;
    Q:=Catalog.NewQuery('SELECT Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?',[BookID]);
    try
      Q.Open; if Q.Eof then raise EInvalidOperation.Create('Основная запись исчезла из каталога.');
      Primary:=Default(TBookRecord); Primary.CollectionRoot:=FRoot;
      Primary.Folder:=Q.FieldAsString(0); Primary.FileName:=Q.FieldAsString(1);
      Primary.FileExt:=Q.FieldAsString(2); Primary.InsideNo:=Q.FieldAsInt(3);
    finally Q.Free; end;
    Identity:=ReaderBookPhysicalIdentity(Primary); Found:=False;
    Q:=Catalog.NewQuery('SELECT Root,Folder,FileName,Ext,InsideNo,SourceName FROM CatalogBookCopies WHERE BookID=? '+
      'ORDER BY (SourceName=? COLLATE BINARY) DESC,SourceKey',[BookID,Result]);
    try
      Q.Open;
      while not Q.Eof do
      begin
        CopyBook:=Default(TBookRecord); CopyBook.CollectionRoot:=Q.FieldAsString(0);
        CopyBook.Folder:=Q.FieldAsString(1); CopyBook.FileName:=Q.FieldAsString(2);
        CopyBook.FileExt:=Q.FieldAsString(3); CopyBook.InsideNo:=Q.FieldAsInt(4);
        if ((Identity<>'') and (Identity=ReaderBookPhysicalIdentity(CopyBook))) or
          ((CopyBook.CollectionRoot=Primary.CollectionRoot) and (CopyBook.Folder=Primary.Folder) and
           (CopyBook.FileName=Primary.FileName) and (CopyBook.FileExt=Primary.FileExt) and
           (CopyBook.InsideNo=Primary.InsideNo)) then
        begin
          Found:=True; if Q.FieldAsString(5)<>'' then Result:=Q.FieldAsString(5);
          Break;
        end;
        Q.Next;
      end;
    finally Q.Free; end;
    // Compare paths as metadata only, including absolute/relative equivalents.
    // No existence probe, archive extraction, move or deletion is performed.
    if not Found then Catalog.ExecSQL('INSERT INTO CatalogBookCopies '+
      '(SourceKey,BookID,SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID) '+
      'SELECT ?,BookID,?,?,Folder,FileName,Ext,InsideNo,BookSize,LibID FROM Books WHERE BookID=?',
      ['dedupe-base:'+IntToStr(FCID)+':'+IntToStr(BookID),Result,FRoot,BookID]);
  end;
begin
  if not FReady or FLinkedMode or (SelectedCount=0) then
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
    WriteCollectionBackupInfo(Folder,cboBooks);
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
        PreferredSource:=PreserveFile(KeepID); PreserveFile(LoseID);
        Catalog.ExecSQL('INSERT INTO CatalogPreferredSource(BookID,SourceName) VALUES(?,?) '+
          'ON CONFLICT(BookID) DO UPDATE SET SourceName=excluded.SourceName',[KeepID,PreferredSource]);
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
