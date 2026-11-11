unit unit_BookDuplicates;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, SQLiteWrap, unit_Globals,
  unit_CollectionMerge, unit_BookDeletionBinding;

const LINKED_DUPLICATE_BATCH_SIZE = 5000;
const DUPLICATE_FILE_BATCH_SIZE = 8000;

type
  TDuplicateBook = record
    Book: TBookRecord;
    SourceName, CopyKey: string;
    HasPersonalData, Selected: Boolean;
  end;
  TDuplicateGroup = record
    ID, Count, KeepID, SelectedCopies: Integer;
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
    FRemoved, FSkippedCopies: Integer;
    FSelectedGroups, FSelectedCopies: Integer;
    FSelectionCountsValid: Boolean;
    FSources: TArray<string>;
    FSkippedDetails: TArray<string>;
    FBaseDigest, FTitle, FCatalogueKey: string;
    FCanceled: TMergeCanceled;
    function QueryCanceled: Boolean;
    procedure LoadSourceChoices;
    function PrioritySourceTable: string;
    procedure ReadSelectionCounts;
    procedure LoadPersonalProtection;
    function LinkedBooks(BookID: Integer): TArray<TDuplicateBook>;
    function LinkedCopy(const CopyKey: string; BookID: Integer; out SourceName: string): TBookRecord;
    function PreferredLinkedLocation(const Current: TBookRecord; const CopyKey: string;
      out SourceName: string): TBookRecord;
    procedure ResetLinkedPromotions;
    procedure CreateSourcePriority(const SourcesByPriority: TArray<string>);
    function RankRegularSources: Integer;
    procedure RankLinkedSources(Combined: Boolean);
    procedure PlanLinkedPromotions(Combined: Boolean = False);
    procedure CommitLinkedPromotions;
    function SelectedPromotionKey(BookID: Integer): string;
    function ReadLinkedDeletion(const Info: TCollectionInfo; Selection: TSQLiteQuery;
      out LastArchive, LastKey: string; out Files: Integer): TBookDeletionBinding;
    function HasSelectedLinkedCopy(const CopyKey: string; BookID: Integer): Boolean;
  public
    constructor Create(const CatalogFile, Root, LibraryNamespace, SystemFile,
      ReaderFile: string; CollectionID: Integer; const WorkRoot: string = '');
    destructor Destroy; override;
    procedure Preview(const Canceled: TMergeCanceled = nil; const Progress: TMergeProgress = nil);
    procedure DiscardPreview;
    procedure PreviewLinked(const Canceled: TMergeCanceled = nil; const Progress: TMergeProgress = nil);
    function Groups(Offset, Limit: Integer; UnmarkedOnly: Boolean = False): TArray<TDuplicateGroup>;
    function Books(GroupID: Integer): TArray<TDuplicateBook>;
    function Sources: TArray<string>;
    function PrioritySources: TArray<string>;
    procedure AlignPrioritySources(Other: TBookDuplicatePlan = nil);
    function SelectSource(const SourceName: string; const Canceled: TMergeCanceled = nil): Integer;
    function SelectSourcePriority(const SourcesByPriority: TArray<string>;
      const Canceled: TMergeCanceled = nil; AllowPrimaryPromotion: Boolean = False): Integer;
    function SelectCombinedSourcePriority(LinkedPlan: TBookDuplicatePlan; const SourcesByPriority: TArray<string>;
      const Canceled: TMergeCanceled; out LinkedSelected: Integer): Integer;
    procedure CheckCombinedSelection(RegularPlan: TBookDuplicatePlan; const Canceled: TMergeCanceled);
    procedure PreviewSelectedPromotion(var Value: TDuplicateBook);
    procedure ClearSelection;
    procedure Choose(GroupID, KeepID: Integer; Selected: Boolean);
    procedure ChooseCopy(const CopyKey: string; Selected: Boolean);
    procedure PreferLinkedCopy(BookID:Integer; const CopyKey:string);
    procedure Apply(const BackupFolder: string; const Canceled: TMergeCanceled = nil;
      const Progress: TMergeStageProgress = nil);
    procedure PrepareDeletionBatches(const Info: TCollectionInfo; const Canceled: TMergeCanceled;
      const Progress: TMergeProgress; ApprovedLinks: TBookDuplicatePlan = nil; SkipBlocked: Boolean = False);
    procedure PrepareLinkedBatches(const Info: TCollectionInfo; const Canceled: TMergeCanceled;
      const Progress: TMergeProgress; AllowPrimaryPromotion: Boolean = True);
    function LinkedDeletionBatch(Index: Integer): TBookDeletionBinding;
    function KeepRecordsWithSkippedFiles(const Books: TArray<TBookRecord>): Integer;
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
    property SkippedCopies: Integer read FSkippedCopies;
    property SkippedDetails: TArray<string> read FSkippedDetails;
  end;

  TUnifiedDuplicateCopy = record
    Value: TDuplicateBook;
    Origins: TArray<TDuplicateBook>;
    Kept, Selected: Boolean;
  end;

  // One user-facing family can contain both separate catalogue cards and
  // alternatives retained by a previous merge. The temporary owner index is
  // small; physical files are resolved only for the requested page/family.
  TUnifiedDuplicateView = class
  private
    FRegular, FLinked: TBookDuplicatePlan;
    FTable: string;
    FReady: Boolean;
    FCanceled: TMergeCanceled;
    function QueryCanceled: Boolean;
    function TableName: string;
  public
    constructor Create(Regular, Linked: TBookDuplicatePlan);
    procedure Build(const Canceled:TMergeCanceled = nil; const Progress:TMergeProgress = nil);
    procedure RefreshMarks;
    procedure RefreshFamilyMarks(GroupID:Integer);
    procedure Choose(GroupID,CopyIndex:Integer; Selected:Boolean);
    function GroupCount(UnmarkedOnly:Boolean = False): Integer;
    function SelectedCount: Integer;
    function Groups(Offset,Limit:Integer; UnmarkedOnly:Boolean = False):TArray<TDuplicateGroup>;
    function Books(GroupID:Integer):TArray<TUnifiedDuplicateCopy>;
    property Ready:Boolean read FReady;
  end;

function DuplicateCandidateKey(const Book: TBookRecord; const LibraryNamespace: string): string;

implementation

uses System.IniFiles, System.IOUtils, System.StrUtils, System.Hash, System.JSON, Winapi.Windows,
  unit_CollectionSpace, unit_LibrarySourceID,
  unit_ReaderCache, unit_ReaderNoteBooks, unit_ReaderAnnotations, unit_Consts, unit_CollectionBackup,
  unit_ZipMemberDeletion, unit_BookDeletionInventory, unit_BookDeletionMembers, SQLite3;

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

function DuplicatePriorityRoot(const Root: string): string;
begin
  Result:='';
  if not TPath.IsPathRooted(Root) then Exit;
  try
    Result:=UpperCase(ExcludeTrailingPathDelimiter(TPath.GetFullPath(Root.Replace('/','\'))));
  except on E:EArgumentException do Result:=''; end;
end;

procedure TBookDuplicatePlan.Preview(const Canceled: TMergeCanceled; const Progress: TMergeProgress);
var Q, Insert, Protected, ReaderKey: TSQLiteQuery; Book: TBookRecord;
  Key, SourceName, SourceID: string; Previous: TSQLiteCancelCallback;
  SourceNames: TDictionary<string,string>; JSON: TJSONValue;
  RootsByName: TDictionary<string,TArray<string>>;
  SourceIDs: TDictionary<string,Integer>;
  LastSource, LastFolder: string;
  LastSourceID: Integer;
  ProtectedBook, HasReaderKeys: Boolean; Separator: Integer;
  procedure Check;
  begin if Assigned(Canceled) and Canceled() then Abort; end;

  procedure AddRoot(const Name, Folder: string);
  begin
    var Root:=DuplicatePriorityRoot(Folder);
    if (Name='') or (Root='') then Exit;
    var Roots:TArray<string>;
    RootsByName.TryGetValue(Name,Roots);
    if not MatchStr(Root,Roots) then RootsByName.AddOrSetValue(Name,Roots+[Root]);
  end;

  function CandidateSource(const Name, Folder: string): Integer;
  var Roots:TArray<string>; Root, Container, Token:string;
  begin
    if Name='' then Exit(0);
    if (Name=LastSource) and (Folder=LastFolder) then Exit(LastSourceID);
    Root:='';
    if RootsByName.TryGetValue(Name,Roots) then
    begin
      try Container:=DuplicatePriorityRoot(TPath.Combine(FRoot,Folder));
      except on E:EArgumentException do Container:=''; end;
      for var CandidateRoot in Roots do
        if (Container=CandidateRoot) or Container.StartsWith(IncludeTrailingPathDelimiter(CandidateRoot)) then
        begin
          if Root<>'' then
          begin
            Root:='';
            Break;
          end;
          Root:=CandidateRoot;
        end;
    end;
    Token:=Name+#1+Root;
    if not SourceIDs.TryGetValue(Token,Result) then
    begin
      Result:=SourceIDs.Count+1;
      FStage.ExecSQL('INSERT INTO RegularSourceChoices(SourceID,Name,PriorityRoot) VALUES(?,?,?)',
        [Result,Name,Root]);
      SourceIDs.Add(Token,Result);
    end;
    LastSource:=Name;
    LastFolder:=Folder;
    LastSourceID:=Result;
  end;

begin
  RootsByName:=TDictionary<string,TArray<string>>.Create;
  SourceIDs:=TDictionary<string,Integer>.Create;
  SourceNames:=TDictionary<string,string>.Create;
  try
  DiscardPreview;
  FLinkedMode:=False; FBaseDigest:='';
  Check;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
   try
    FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(FFile),1,25);
    FSource:=TSQLiteDatabase.CreateReadOnly(FFile); FSource.Start;
    // SQLite owns and removes this unnamed temporary database. Memory is
    // bounded on x86; the user's catalog and its indexes remain read-only.
    FStage:=TSQLiteDatabase.Create(''); FStage.ExecSQL('PRAGMA cache_size=-4096');
    FStage.ExecSQL('CREATE TABLE Candidates(BookID INTEGER PRIMARY KEY,Identity TEXT NOT NULL,'+
      'SourceName TEXT NOT NULL,Protected INTEGER NOT NULL,SourceID INTEGER NOT NULL)');
    FStage.ExecSQL('CREATE TABLE RegularSourceChoices(SourceID INTEGER PRIMARY KEY,Name TEXT NOT NULL,'+
      'PriorityRoot TEXT NOT NULL,PriorityCaption TEXT)');
    // Reject changed paths and unreadable personal data before scanning a
    // large catalog. Apply rechecks the same data under writer reservations.
    LoadPersonalProtection; Check;
    AddRoot(FTitle,FRoot);
    JSON:=TJSONObject.ParseJSONValue(FSource.QuerySingleString(
      'SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_CATALOG_SOURCES]));
    try
      if Assigned(JSON) and not (JSON is TJSONArray) then
        raise EInvalidOperation.Create('Не удалось прочитать источники коллекции.');
      if JSON is TJSONArray then
        for var Item in TJSONArray(JSON) do
          if Item is TJSONObject then
          begin
            var Name:=TJSONObject(Item).GetValue<string>('name','');
            SourceNames.AddOrSetValue(TJSONObject(Item).GetValue<string>('id',''),Name);
            AddRoot(Name,TJSONObject(Item).GetValue<string>('root',''));
          end;
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
      Insert:=FStage.NewQuery('INSERT INTO Candidates VALUES(?,?,?,?,?)');
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
            Insert.SetParam(2,SourceName); Insert.SetParam(3,ProtectedBook);
            Insert.SetParam(4,CandidateSource(SourceName,Book.Folder)); Insert.ExecSQL; Insert.Reset;
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
    FStage.ExecSQL('CREATE TABLE DuplicateGroups(GroupID INTEGER PRIMARY KEY,Identity TEXT UNIQUE,Count INTEGER,KeepID INTEGER,'+
      'Selected INTEGER DEFAULT 0,Manual INTEGER NOT NULL DEFAULT 0)');
    FStage.ExecSQL('INSERT INTO DuplicateGroups(Identity,Count,KeepID) SELECT Identity,count(*),min(BookID) FROM Candidates GROUP BY Identity HAVING count(*)>1 ORDER BY min(BookID)');
    FGroupCount:=FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups');
    LoadSourceChoices;
    Check;
    AlignPrioritySources;
    FReady:=True;
    if Assigned(Progress) then Progress(FScanned,FScanned);
  except
    FreeAndNil(FSource); FreeAndNil(FStage); FGroupCount:=0; raise;
  end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
  finally SourceNames.Free; SourceIDs.Free; RootsByName.Free; end;
end;

function ReadDuplicateLocation(Q: TSQLiteQuery; First: Integer; const Root: string;
  const Key: TBookKey): TBookRecord;
begin
  Result:=Default(TBookRecord); Result.BookKey:=Key;
  Result.CollectionRoot:=Root; Result.LibID:=Q.FieldAsString(First);
  Result.Folder:=Q.FieldAsString(First+1); Result.FileName:=Q.FieldAsString(First+2);
  Result.FileExt:=Q.FieldAsString(First+3); Result.InsideNo:=Q.FieldAsInt(First+4);
end;

procedure TBookDuplicatePlan.DiscardPreview;
begin
  FReady:=False;
  FGroupCount:=0;
  FScanned:=0;
  FSelectionCountsValid:=False;
  FSources:=nil;
  FreeAndNil(FSource);
  FreeAndNil(FStage);
end;

procedure TBookDuplicatePlan.PreviewLinked(const Canceled: TMergeCanceled; const Progress: TMergeProgress);
const MaxCachedArchives = 8192;
var Previous: TSQLiteCancelCallback; Q, Insert, AddPrimary, AddOriginal: TSQLiteQuery;
  CopyBook: TBookRecord; Identity, PrimaryIdentity, PrimaryName, CopyKey: string;
  SourceIDs: TDictionary<string,Integer>; ArchivePaths: TDictionary<string,string>; LastBookID: Integer;

  function DeletionSortPath(const Book: TBookRecord; const PhysicalIdentity: string): string;
  var Container: string;
  begin
    if Pos(#1,PhysicalIdentity)=0 then Exit(UpperCase(TPath.GetFullPath(Book.GetBookFileName)));
    Container:=TPath.Combine(Book.CollectionRoot,Book.Folder);
    if ArchivePaths.TryGetValue(Container,Result) then Exit;
    // Resolve legacy ZIP-to-7z fallback once per archive for sorting only.
    // The deletion worker still verifies each archive against live files.
    Result:=UpperCase(TPath.GetFullPath(Book.GetBookFileName));
    if ArchivePaths.Count=MaxCachedArchives then ArchivePaths.Clear;
    ArchivePaths.Add(Container,Result);
  end;

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
    FStage.ExecSQL('INSERT INTO LinkedSourceChoices(SourceID,Name,Root,Origin,PriorityRoot) VALUES(?,?,?,?,?)',
      [Result,Name,Folder,Origin,DuplicatePriorityRoot(Root)]);
    SourceIDs.Add(Token,Result);
  end;

  procedure CollapseFileAliases(const TableName: string; ResolveSource: Boolean);
  var Scope: string;
  begin
    Scope:='';
    // Original aliases are needed for deletion only when another file of the
    // same card can become the primary file.
    if not ResolveSource then Scope:=' WHERE BookID IN (SELECT BookID FROM LinkedCopies)';
    // A reference imported from another collection can contain an absolute
    // path outside its recorded root. Give the matching root precedence.
    FStage.ExecSQL('CREATE TEMP TABLE AliasCandidates AS '+
      'SELECT c.CopyKey,c.BookID,c.Archive,c.PhysicalIdentity,s.Name,s.PriorityRoot,'+
      'CASE WHEN s.PriorityRoot<>'''' AND (c.Archive=s.PriorityRoot OR '+
      'substr(c.Archive,1,length(s.PriorityRoot)+1)=s.PriorityRoot||char(92)) '+
      'THEN length(s.PriorityRoot) ELSE 0 END AS Depth FROM '+TableName+' c '+
      'JOIN (SELECT BookID,Archive,PhysicalIdentity FROM '+TableName+Scope+' '+
      'GROUP BY BookID,Archive,PhysicalIdentity HAVING count(*)>1) d USING(BookID,Archive,PhysicalIdentity) '+
      'LEFT JOIN LinkedSourceChoices s USING(SourceID)');
    FStage.ExecSQL('CREATE TEMP TABLE AliasWinners AS WITH Ranked AS ('+
      'SELECT *,max(Depth) OVER(PARTITION BY BookID,Archive,PhysicalIdentity) AS Best FROM temp.AliasCandidates) '+
      'SELECT BookID,Archive,PhysicalIdentity,min(CopyKey) AS Representative,'+
      'count(DISTINCT coalesce(Name,'''')||char(1)||coalesce(PriorityRoot,''''))=1 AS Unambiguous '+
      'FROM Ranked WHERE Depth=Best GROUP BY BookID,Archive,PhysicalIdentity');
    FStage.ExecSQL('INSERT INTO LinkedFileAliases SELECT a.CopyKey,w.Representative FROM temp.AliasCandidates a '+
      'JOIN temp.AliasWinners w USING(BookID,Archive,PhysicalIdentity) WHERE a.CopyKey<>w.Representative');
    if ResolveSource then
      FStage.ExecSQL('UPDATE '+TableName+' SET SourceID=0 WHERE CopyKey IN '+
        '(SELECT Representative FROM temp.AliasWinners WHERE Unambiguous=0)');
    FStage.ExecSQL('DELETE FROM '+TableName+' WHERE CopyKey IN (SELECT CopyKey FROM LinkedFileAliases)');
    FStage.ExecSQL('DROP TABLE temp.AliasWinners');
    FStage.ExecSQL('DROP TABLE temp.AliasCandidates');
  end;

begin
  DiscardPreview;
  FLinkedMode:=True;
  Q:=nil; Insert:=nil; AddPrimary:=nil; AddOriginal:=nil; SourceIDs:=nil; ArchivePaths:=nil; LastBookID:=0;
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
    try
      if QueryCanceled then Abort;
      FCatalogueKey:=Copy(ArchiveDeletionSourceIdentity(FFile),1,25);
      FSource:=TSQLiteDatabase.CreateReadOnly(FFile); FSource.Start;
      FStage:=TSQLiteDatabase.Create(''); FStage.ExecSQL('PRAGMA cache_size=-4096');
      SourceIDs:=TDictionary<string,Integer>.Create;
      ArchivePaths:=TDictionary<string,string>.Create;
      FStage.ExecSQL('CREATE TABLE LinkedCopies(CopyKey TEXT PRIMARY KEY,BookID INTEGER NOT NULL,'+
        'SourceID INTEGER NOT NULL,Archive TEXT NOT NULL,Selected INTEGER NOT NULL DEFAULT 0,'+
        'Manual INTEGER NOT NULL DEFAULT 0,PhysicalIdentity TEXT NOT NULL)');
      FStage.ExecSQL('CREATE TABLE LinkedPrimarySources(BookID INTEGER PRIMARY KEY,Name TEXT NOT NULL,'+
        'Manual INTEGER NOT NULL DEFAULT 0,SourceID INTEGER NOT NULL)');
      FStage.ExecSQL('CREATE TABLE LinkedOriginals(BookID INTEGER NOT NULL,CopyKey TEXT PRIMARY KEY,Archive TEXT NOT NULL,'+
        'PhysicalIdentity TEXT NOT NULL,SourceID INTEGER NOT NULL)');
      FStage.ExecSQL('CREATE INDEX LinkedOriginalBooks ON LinkedOriginals(BookID)');
      FStage.ExecSQL('CREATE TABLE LinkedFileAliases(CopyKey TEXT PRIMARY KEY,Representative TEXT NOT NULL) WITHOUT ROWID');
      FStage.ExecSQL('CREATE TABLE LinkedPromotions(BookID INTEGER PRIMARY KEY,PreviousKey TEXT NOT NULL,'+
        'PreferredKey TEXT NOT NULL,PreferredSourceID INTEGER NOT NULL,PreferredArchive TEXT NOT NULL,'+
        'PreferredIdentity TEXT NOT NULL)');
      FStage.ExecSQL('CREATE TABLE LinkedSourceChoices(SourceID INTEGER PRIMARY KEY,Name TEXT NOT NULL,'+
        'Root TEXT NOT NULL,Origin TEXT NOT NULL,Caption TEXT,PriorityRoot TEXT NOT NULL,PriorityCaption TEXT)');
      Q:=FSource.NewQuery('SELECT c.SourceKey,c.BookID,c.SourceName,c.Root,c.LibID,c.Folder,c.FileName,c.Ext,c.InsideNo,'+
        'b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,p.SourceName FROM CatalogBookCopies c JOIN Books b USING(BookID) '+
        'LEFT JOIN CatalogPreferredSource p USING(BookID) WHERE b.IsDeleted=0 ORDER BY c.BookID');
      Insert:=FStage.NewQuery('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID,Archive,PhysicalIdentity) VALUES(?,?,?,?,?)');
      AddPrimary:=FStage.NewQuery('INSERT INTO LinkedPrimarySources(BookID,Name,SourceID) VALUES(?,?,?) '+
        'ON CONFLICT(BookID) DO UPDATE SET Name=CASE WHEN Name=excluded.Name THEN Name ELSE '''' END,'+
        'SourceID=CASE WHEN Name=excluded.Name THEN SourceID ELSE 0 END');
      AddOriginal:=FStage.NewQuery('INSERT INTO LinkedOriginals VALUES(?,?,?,?,?)');
      FStage.Start;
      Q.Open;
      while not Q.Eof do
      begin
        if QueryCanceled then Abort;
        var Key:=CreateBookKey(Q.FieldAsInt(1),FCID);
        if Key.BookID<>LastBookID then
        begin
          PrimaryIdentity:=ReaderBookPhysicalIdentity(ReadDuplicateLocation(Q,9,FRoot,Key));
          PrimaryName:=Q.FieldAsString(14);
          if PrimaryName<>'' then
          begin
            AddPrimary.SetParam(0,Key.BookID); AddPrimary.SetParam(1,PrimaryName);
            AddPrimary.SetParam(2,SourceID(PrimaryName,'',''));
            AddPrimary.ExecSQL; AddPrimary.Reset;
          end;
          LastBookID:=Key.BookID;
        end;
        CopyBook:=ReadDuplicateLocation(Q,4,Q.FieldAsString(3),Key);
        if (PrimaryIdentity<>'') and not CopyBook.IsLinkedSource then
        begin
          Identity:=ReaderBookPhysicalIdentity(CopyBook);
          if Identity=PrimaryIdentity then
          begin
            if (PrimaryName='') and (Q.FieldAsString(2)<>'') then
            begin
              AddPrimary.SetParam(0,Key.BookID); AddPrimary.SetParam(1,Q.FieldAsString(2));
              AddPrimary.SetParam(2,SourceID(Q.FieldAsString(2),'',''));
              AddPrimary.ExecSQL; AddPrimary.Reset;
            end;
            AddOriginal.SetParam(0,Key.BookID); AddOriginal.SetParam(1,Q.FieldAsString(0));
            AddOriginal.SetParam(2,DeletionSortPath(CopyBook,Identity));
            AddOriginal.SetParam(3,Identity);
            AddOriginal.SetParam(4,SourceID(Q.FieldAsString(2),CopyBook.CollectionRoot,Q.FieldAsString(0)));
            AddOriginal.ExecSQL; AddOriginal.Reset;
          end;
          if (Identity<>'') and (Identity<>PrimaryIdentity) then
          begin
            CopyKey:=Q.FieldAsString(0);
            Insert.SetParam(0,CopyKey); Insert.SetParam(1,Key.BookID);
            Insert.SetParam(2,SourceID(Q.FieldAsString(2),CopyBook.CollectionRoot,CopyKey));
            Insert.SetParam(3,DeletionSortPath(CopyBook,Identity));
            Insert.SetParam(4,Identity);
            Insert.ExecSQL; Insert.Reset;
          end;
        end;
        Inc(FScanned);
        if (FScanned mod 4096=0) and Assigned(Progress) then Progress(FScanned,0);
        Q.Next;
      end;
      FStage.Commit;
      FStage.ExecSQL('CREATE INDEX LinkedBooks ON LinkedCopies(BookID)');
      FStage.ExecSQL('WITH Exact AS MATERIALIZED (SELECT o.BookID,min(s.SourceID) AS SourceID FROM LinkedOriginals o '+
        'JOIN LinkedSourceChoices s USING(SourceID) JOIN LinkedPrimarySources p ON p.BookID=o.BookID AND p.Name=s.Name '+
        'WHERE s.PriorityRoot<>'''' AND (o.Archive=s.PriorityRoot OR '+
        'substr(o.Archive,1,length(s.PriorityRoot)+1)=s.PriorityRoot||char(92)) '+
        'GROUP BY o.BookID HAVING count(DISTINCT s.PriorityRoot)=1) '+
        'UPDATE LinkedPrimarySources AS p SET SourceID=e.SourceID FROM Exact e WHERE p.BookID=e.BookID');
      FStage.Start;
      CollapseFileAliases('LinkedCopies',True);
      CollapseFileAliases('LinkedOriginals',False);
      FStage.Commit;
      FStage.ExecSQL('CREATE INDEX LinkedAliasesByFile ON LinkedFileAliases(Representative)');
      FStage.ExecSQL('CREATE INDEX LinkedSources ON LinkedCopies(SourceID,Selected,BookID,CopyKey)');
      FStage.ExecSQL('UPDATE LinkedSourceChoices AS a SET Caption=Name || CASE WHEN '+
        'EXISTS(SELECT 1 FROM LinkedSourceChoices b WHERE b.SourceID<>a.SourceID AND b.Name=a.Name '+
        'AND EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.SourceID=b.SourceID)) '+
        'THEN '' · '' || Root || CASE WHEN EXISTS(SELECT 1 FROM LinkedSourceChoices b WHERE b.SourceID<>a.SourceID '+
        'AND b.Name=a.Name AND b.Root=a.Root COLLATE NOCASE AND EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.SourceID=b.SourceID)) '+
        'THEN '' · '' || Origin ELSE '''' END ELSE '''' END');
      FStage.ExecSQL('CREATE INDEX LinkedPrimaryBySource ON LinkedPrimarySources(SourceID)');
      FStage.ExecSQL('CREATE INDEX LinkedSelected ON LinkedCopies(BookID) WHERE Selected=1');
      FStage.ExecSQL('CREATE TABLE LinkedGroups(BookID INTEGER PRIMARY KEY,Count INTEGER NOT NULL)');
      FStage.ExecSQL('CREATE TABLE MixedSelection(GroupID INTEGER PRIMARY KEY,KeepID INTEGER NOT NULL)');
      FStage.ExecSQL('INSERT INTO LinkedGroups SELECT BookID,count(*)+1 FROM LinkedCopies GROUP BY BookID');
      FGroupCount:=FStage.QuerySingleInt('SELECT count(*) FROM LinkedGroups');
      LoadSourceChoices;
      if QueryCanceled then Abort;
      AlignPrioritySources;
      FReady:=True;
      if Assigned(Progress) then Progress(FScanned,FScanned);
    finally AddOriginal.Free; AddPrimary.Free; Insert.Free; Q.Free; ArchivePaths.Free; SourceIDs.Free; end;
  except
    FreeAndNil(FSource); FreeAndNil(FStage); FGroupCount:=0;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    raise;
  end;
  SQLiteCancelCallback:=Previous; FCanceled:=nil;
end;

procedure TBookDuplicatePlan.LoadSourceChoices;
var Q: TSQLiteQuery; Names: TList<string>;
begin
  Names:=TList<string>.Create;
  try
    if FLinkedMode then
      Q:=FStage.NewQuery('SELECT Caption FROM LinkedSourceChoices s '+
        'WHERE EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.SourceID=s.SourceID) ORDER BY Caption')
    else
      Q:=FStage.NewQuery('SELECT DISTINCT c.SourceName FROM Candidates c JOIN DuplicateGroups g USING(Identity) '+
        'WHERE c.SourceName<>'''' ORDER BY c.SourceName');
    try
      Q.Open;
      while not Q.Eof do begin Names.Add(Q.FieldAsString(0)); Q.Next; end;
    finally Q.Free; end;
    FSources:=Names.ToArray;
  finally Names.Free; end;
end;

function TBookDuplicatePlan.Sources: TArray<string>;
begin
  if not FReady then Exit(nil);
  Result:=Copy(FSources);
end;

function TBookDuplicatePlan.PrioritySourceTable: string;
begin
  if FLinkedMode then Result:='LinkedSourceChoices' else Result:='RegularSourceChoices';
end;

procedure TBookDuplicatePlan.AlignPrioritySources(Other: TBookDuplicatePlan);
const MultipleRoots = #0;
var Roots: TDictionary<string,string>;

  procedure ReadRoots(Plan: TBookDuplicatePlan);
  var Q:TSQLiteQuery; Name, Root, Previous:string;
  begin
    Q:=Plan.FStage.NewQuery('SELECT Name,PriorityRoot FROM '+Plan.PrioritySourceTable+' WHERE PriorityRoot<>''''');
    try
      Q.Open;
      while not Q.Eof do
      begin
        Name:=Q.FieldAsString(0); Root:=Q.FieldAsString(1);
        if not Roots.TryGetValue(Name,Previous) then Roots.Add(Name,Root)
        else if Previous<>Root then Roots[Name]:=MultipleRoots;
        Q.Next;
      end;
    finally Q.Free; end;
  end;

  procedure SetCaptions(Plan: TBookDuplicatePlan);
  var Q:TSQLiteQuery; TableName, Name, Root, CommonRoot, Caption:string;
  begin
    TableName:=Plan.PrioritySourceTable;
    Q:=Plan.FStage.NewQuery('SELECT SourceID,Name,PriorityRoot FROM '+TableName);
    try
      Q.Open;
      while not Q.Eof do
      begin
        Name:=Q.FieldAsString(1); Root:=Q.FieldAsString(2);
        Caption:=Name;
        if Roots.TryGetValue(Name,CommonRoot) and (CommonRoot=MultipleRoots) then
        begin
          if Root='' then Caption:=''
          else Caption:=Name+' · '+Root;
        end;
        Plan.FStage.ExecSQL('UPDATE '+TableName+' SET PriorityCaption=? WHERE SourceID=?',
          [Caption,Q.FieldAsInt(0)]);
        Q.Next;
      end;
    finally Q.Free; end;
  end;

begin
  Roots:=TDictionary<string,string>.Create;
  try
    ReadRoots(Self);
    if Assigned(Other) then ReadRoots(Other);
    SetCaptions(Self);
    if Assigned(Other) then SetCaptions(Other);
  finally Roots.Free; end;
end;

function TBookDuplicatePlan.PrioritySources: TArray<string>;
var Q:TSQLiteQuery; Names:TList<string>;
begin
  if not FReady then Exit(nil);
  Names:=TList<string>.Create;
  try
    if FLinkedMode then
      Q:=FStage.NewQuery('SELECT s.PriorityCaption FROM LinkedSourceChoices s WHERE s.PriorityCaption<>'''' AND '+
        '(EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.SourceID=s.SourceID) OR '+
        'EXISTS(SELECT 1 FROM LinkedPrimarySources p JOIN LinkedGroups g USING(BookID) WHERE p.SourceID=s.SourceID)) '+
        'GROUP BY s.PriorityCaption ORDER BY s.PriorityCaption')
    else
      Q:=FStage.NewQuery('SELECT DISTINCT s.PriorityCaption FROM DuplicateGroups g JOIN Candidates c USING(Identity) '+
        'JOIN RegularSourceChoices s USING(SourceID) WHERE s.PriorityCaption<>'''' ORDER BY s.PriorityCaption');
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
  if not FLinkedMode and (SourceName='') then raise EArgumentException.Create('Выберите предпочтительный источник.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
    if QueryCanceled then Abort;
    FStage.Start;
    try
      if FLinkedMode then
      begin
        if SourceName='' then
          FStage.ExecSQL('UPDATE LinkedCopies SET Selected=1,Manual=1 WHERE Selected=0')
        else
        begin
          if FStage.QuerySingleInt('SELECT count(*) FROM LinkedSourceChoices WHERE Caption=?',[SourceName])<>1 then
            raise EInvalidOperation.Create('Не удалось однозначно определить источник. Отметьте файлы вручную.');
          FStage.ExecSQL('UPDATE LinkedCopies SET Selected=1,Manual=1 WHERE Selected=0 AND '+
            'SourceID=(SELECT SourceID FROM LinkedSourceChoices WHERE Caption=?)',[SourceName]);
        end;
        Result:=FStage.QuerySingleInt('SELECT changes()');
        if QueryCanceled then Abort;
        FStage.Commit;
        FSelectionCountsValid:=False;
        Exit;
      end;
      FStage.ExecSQL('DROP TABLE IF EXISTS SourceChoices');
      // Only a unique preferred copy in a group spanning known sources can be
      // chosen automatically. Preserve manual selections and all protected rows.
      FStage.ExecSQL('CREATE TEMP TABLE SourceChoices(GroupID INTEGER PRIMARY KEY,KeepID INTEGER NOT NULL)');
      FStage.ExecSQL('INSERT INTO SourceChoices '+
        'SELECT g.GroupID,min(CASE WHEN c.SourceName=? COLLATE BINARY THEN c.BookID END) FROM DuplicateGroups g '+
        'JOIN Candidates c USING(Identity) WHERE g.Selected=0 AND g.Manual=0 AND g.Count=2 '+
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
      FSelectionCountsValid:=False;
    except FStage.Rollback; raise; end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

procedure TBookDuplicatePlan.ClearSelection;
begin
  if not FReady then Exit;
  if FLinkedMode then
  begin
    FStage.Start;
    try
      ResetLinkedPromotions;
      FStage.ExecSQL('DELETE FROM MixedSelection');
      FStage.ExecSQL('UPDATE LinkedPrimarySources SET Manual=0 WHERE Manual<>0');
      FStage.ExecSQL('UPDATE LinkedCopies SET Selected=0,Manual=0 WHERE Selected<>0 OR Manual<>0');
      FStage.Commit;
    except FStage.Rollback; raise; end;
  end
  else FStage.ExecSQL('UPDATE DuplicateGroups SET Selected=0,Manual=0 WHERE Selected<>0 OR Manual<>0');
  FSelectionCountsValid:=False;
end;

procedure TBookDuplicatePlan.ResetLinkedPromotions;
begin
  FStage.ExecSQL('DELETE FROM LinkedCopies WHERE CopyKey IN (SELECT PreviousKey FROM LinkedPromotions)');
  FStage.ExecSQL('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID,Archive,PhysicalIdentity) '+
    'SELECT PreferredKey,BookID,PreferredSourceID,PreferredArchive,PreferredIdentity FROM LinkedPromotions');
  FStage.ExecSQL('DELETE FROM LinkedPromotions');
end;

procedure TBookDuplicatePlan.CreateSourcePriority(const SourcesByPriority: TArray<string>);
begin
  FStage.ExecSQL('CREATE TEMP TABLE SourcePriority(Name TEXT PRIMARY KEY, Position INTEGER NOT NULL) WITHOUT ROWID');
  for var I:=0 to High(SourcesByPriority) do
  begin
    if SourcesByPriority[I]='' then raise EArgumentException.Create('Не указан источник.');
    FStage.ExecSQL('INSERT INTO temp.SourcePriority VALUES(?,?)',[SourcesByPriority[I],I]);
  end;
end;

function TBookDuplicatePlan.RankRegularSources: Integer;
begin
  // Automatic selection never removes a card with personal data.
  FStage.ExecSQL('UPDATE DuplicateGroups AS g SET Selected=0,KeepID='+
    '(SELECT min(BookID) FROM Candidates c WHERE c.Identity=g.Identity) WHERE Manual=0 AND Selected=1');
  FStage.ExecSQL('WITH RankedGroups AS MATERIALIZED ('+
    'SELECT g.GroupID,g.Identity,min(p.Position) AS Best FROM DuplicateGroups g '+
    'JOIN Candidates c USING(Identity) LEFT JOIN RegularSourceChoices s USING(SourceID) '+
    'LEFT JOIN temp.SourcePriority p ON p.Name=s.PriorityCaption '+
    'WHERE g.Manual=0 AND g.Count BETWEEN 2 AND 1000 GROUP BY g.GroupID '+
    'HAVING count(DISTINCT p.Position)=g.Count AND '+
    'coalesce(max(CASE WHEN c.Protected<>0 THEN p.Position END),min(p.Position))=min(p.Position)) '+
    'UPDATE DuplicateGroups AS g SET KeepID=c.BookID,Selected=1 FROM RankedGroups r '+
    'JOIN temp.SourcePriority p ON p.Position=r.Best '+
    'JOIN Candidates c ON c.Identity=r.Identity JOIN RegularSourceChoices s ON s.SourceID=c.SourceID '+
    'AND s.PriorityCaption=p.Name WHERE g.GroupID=r.GroupID');
  Result:=FStage.QuerySingleInt('SELECT changes()');
end;

procedure TBookDuplicatePlan.RankLinkedSources(Combined: Boolean);
begin
  FStage.ExecSQL('WITH Eligible AS MATERIALIZED ('+
    'SELECT c.BookID FROM LinkedCopies c JOIN LinkedPrimarySources b USING(BookID) '+
    'JOIN LinkedSourceChoices a ON a.SourceID=b.SourceID JOIN temp.SourcePriority k ON k.Name=a.PriorityCaption '+
    'LEFT JOIN LinkedSourceChoices s ON s.SourceID=c.SourceID '+
    'LEFT JOIN temp.SourcePriority p ON p.Name=s.PriorityCaption '+
    IfThen(Combined,'WHERE c.BookID NOT IN (SELECT BookID FROM temp.MixedCards) ','')+
    'GROUP BY c.BookID HAVING count(p.Position)=count(*) AND min(p.Position)>min(k.Position) '+
    'AND count(DISTINCT c.PhysicalIdentity)=count(*)) '+
    'UPDATE LinkedCopies SET Selected=(BookID IN (SELECT BookID FROM Eligible)) WHERE Manual=0');
end;

procedure TBookDuplicatePlan.PlanLinkedPromotions(Combined: Boolean);
var Planned, Current:TSQLiteQuery; Name:string; BookID:Integer;
begin
  // Every ranked source must be distinct and the current file must have one
  // exact alias. That alias remains available until its physical deletion.
  FStage.ExecSQL('WITH Ranked AS MATERIALIZED ('+
    'SELECT c.BookID,min(p.Position) AS Best FROM LinkedCopies c '+
    'JOIN LinkedPrimarySources b USING(BookID) JOIN LinkedSourceChoices a ON a.SourceID=b.SourceID '+
    'JOIN temp.SourcePriority k ON k.Name=a.PriorityCaption LEFT JOIN LinkedSourceChoices s ON s.SourceID=c.SourceID '+
    'LEFT JOIN temp.SourcePriority p ON p.Name=s.PriorityCaption '+
    'WHERE b.Manual=0 '+
    IfThen(Combined,'AND c.BookID NOT IN (SELECT BookID FROM temp.MixedCards) ','')+
    'GROUP BY c.BookID HAVING count(DISTINCT p.Position)=count(*) AND min(p.Position)<min(k.Position) '+
    'AND sum(p.Position=k.Position)=0 AND max(c.Manual)=0 AND count(DISTINCT c.PhysicalIdentity)=count(*)), '+
    'Original AS MATERIALIZED (SELECT BookID,min(CopyKey) AS CopyKey FROM LinkedOriginals '+
    'JOIN Ranked USING(BookID) GROUP BY BookID HAVING count(*)=1) '+
    'INSERT INTO LinkedPromotions SELECT r.BookID,o.CopyKey,c.CopyKey,c.SourceID,c.Archive,c.PhysicalIdentity FROM Ranked r '+
    'JOIN Original o USING(BookID) JOIN LinkedCopies c USING(BookID) JOIN LinkedSourceChoices s USING(SourceID) '+
    'JOIN temp.SourcePriority p ON p.Name=s.PriorityCaption AND p.Position=r.Best');
  if Combined then
    FStage.ExecSQL('INSERT INTO LinkedPromotions SELECT w.BookID,min(o.CopyKey),c.CopyKey,c.SourceID,c.Archive,c.PhysicalIdentity '+
      'FROM temp.MixedWinners w JOIN LinkedOriginals o USING(BookID) JOIN LinkedCopies c ON c.CopyKey=w.CopyKey '+
      'GROUP BY w.BookID HAVING count(*)=1');
  FStage.ExecSQL('CREATE TEMP TABLE RejectedLinkedPromotions(BookID INTEGER PRIMARY KEY)');
  Planned:=FStage.NewQuery('SELECT BookID,PreferredKey FROM LinkedPromotions ORDER BY BookID');
  try
    Current:=FSource.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=?');
    try
      Planned.Open;
      while not Planned.Eof do
      begin
        if QueryCanceled then Abort;
        BookID:=Planned.FieldAsInt(0);
        Current.SetParam(0,BookID); Current.Open;
        try
          if Current.Eof then raise EReadError.Create('Карточка книги недоступна.');
          PreferredLinkedLocation(ReadDuplicateLocation(Current,0,FRoot,CreateBookKey(BookID,FCID)),
            Planned.FieldAsString(1),Name);
        except
          on E:EReadError do FStage.ExecSQL('INSERT INTO temp.RejectedLinkedPromotions VALUES(?)',[BookID]);
        end;
        Current.Reset;
        Planned.Next;
      end;
    finally Current.Free; end;
  finally Planned.Free; end;
  FStage.ExecSQL('DELETE FROM LinkedPromotions WHERE BookID IN (SELECT BookID FROM temp.RejectedLinkedPromotions)');
  FStage.ExecSQL('DROP TABLE temp.RejectedLinkedPromotions');
  FStage.ExecSQL('DELETE FROM LinkedCopies WHERE CopyKey IN (SELECT PreferredKey FROM LinkedPromotions)');
  FStage.ExecSQL('UPDATE LinkedCopies SET Selected=1 WHERE BookID IN (SELECT BookID FROM LinkedPromotions)');
  FStage.ExecSQL('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID,Archive,PhysicalIdentity,Selected) '+
    'SELECT o.CopyKey,o.BookID,o.SourceID,o.Archive,o.PhysicalIdentity,1 FROM LinkedOriginals o '+
    'JOIN LinkedPromotions p ON o.CopyKey=p.PreviousKey');
end;

function TBookDuplicatePlan.SelectSourcePriority(const SourcesByPriority: TArray<string>;
  const Canceled: TMergeCanceled; AllowPrimaryPromotion: Boolean): Integer;
var Previous: TSQLiteCancelCallback;
begin
  if not FReady then
    raise EInvalidOperation.Create('Сначала найдите дубли книг.');
  if Length(SourcesByPriority)<2 then
    raise EArgumentException.Create('Для массового выбора нужны хотя бы два известных источника.');
  Previous:=SQLiteCancelCallback;
  FCanceled:=Canceled;
  SQLiteCancelCallback:=QueryCanceled;
  try
    if QueryCanceled then Abort;
    FStage.Start;
    try
      CreateSourcePriority(SourcesByPriority);
      if FLinkedMode then
      begin
        FStage.ExecSQL('DELETE FROM MixedSelection');
        ResetLinkedPromotions;
        RankLinkedSources(False);
        if AllowPrimaryPromotion then PlanLinkedPromotions;
        Result:=FStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE Selected=1 AND Manual=0');
      end
      else Result:=RankRegularSources;
      FStage.ExecSQL('DROP TABLE temp.SourcePriority');
      if QueryCanceled then Abort;
      FStage.Commit;
      FSelectionCountsValid:=False;
    except FStage.Rollback; raise; end;
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

function TBookDuplicatePlan.SelectCombinedSourcePriority(LinkedPlan: TBookDuplicatePlan;
  const SourcesByPriority: TArray<string>; const Canceled: TMergeCanceled; out LinkedSelected: Integer): Integer;
var Previous: TSQLiteCancelCallback; LinkedStage: TSQLiteDatabase;
  Rows, Insert: TSQLiteQuery;

  procedure Transfer(const FromDB, ToDB: TSQLiteDatabase; const SelectSQL, InsertSQL: string; Columns: Integer);
  begin
    Rows:=FromDB.NewQuery(SelectSQL);
    try
      Insert:=ToDB.NewQuery(InsertSQL);
      try
        Rows.Open;
        while not Rows.Eof do
        begin
          if QueryCanceled then Abort;
          for var Column:=0 to Columns-1 do
            Insert.SetParam(Column,Rows.FieldAsString(Column));
          Insert.ExecSQL;
          Insert.Reset;
          Rows.Next;
        end;
      finally Insert.Free; end;
    finally Rows.Free; end;
  end;

begin
  if not FReady or FLinkedMode or not Assigned(LinkedPlan) or not LinkedPlan.FReady or
    not LinkedPlan.FLinkedMode or (FCID<>LinkedPlan.FCID) or (FCatalogueKey<>LinkedPlan.FCatalogueKey) then
    raise EInvalidOperation.Create('Сначала найдите дубли и дополнительные файлы в этой коллекции.');
  if Length(SourcesByPriority)<2 then
    raise EArgumentException.Create('Для массового выбора нужны хотя бы два известных источника.');
  LinkedStage:=LinkedPlan.FStage;
  Previous:=SQLiteCancelCallback;
  FCanceled:=Canceled;
  LinkedPlan.FCanceled:=Canceled;
  SQLiteCancelCallback:=QueryCanceled;
  try
    FStage.Start;
    LinkedStage.Start;
    AlignPrioritySources(LinkedPlan);
    CreateSourcePriority(SourcesByPriority);
    LinkedPlan.CreateSourcePriority(SourcesByPriority);
    Result:=RankRegularSources;
    LinkedPlan.ResetLinkedPromotions;

    // Transfer IDs between the two temporary databases, then compare only
    // groups that contain both separate cards and attached files.
    FStage.ExecSQL('CREATE TEMP TABLE LinkedOwners(BookID INTEGER PRIMARY KEY)');
    Transfer(LinkedStage,FStage,'SELECT BookID FROM LinkedGroups','INSERT INTO temp.LinkedOwners VALUES(?)',1);
    FStage.ExecSQL('CREATE TEMP TABLE MixedGroups(GroupID INTEGER PRIMARY KEY)');
    FStage.ExecSQL('INSERT OR IGNORE INTO temp.MixedGroups SELECT g.GroupID FROM temp.LinkedOwners o '+
      'JOIN Candidates c USING(BookID) JOIN DuplicateGroups g USING(Identity)');
    LinkedStage.ExecSQL('CREATE TEMP TABLE MixedCards(BookID INTEGER PRIMARY KEY,GroupID INTEGER NOT NULL,'+
      'SourceName TEXT NOT NULL,PriorityCaption TEXT NOT NULL,Protected INTEGER NOT NULL,Manual INTEGER NOT NULL)');
    Transfer(FStage,LinkedStage,'SELECT c.BookID,g.GroupID,c.SourceName,coalesce(s.PriorityCaption,''''),c.Protected,g.Manual '+
      'FROM temp.MixedGroups m JOIN DuplicateGroups g USING(GroupID) JOIN Candidates c USING(Identity) '+
      'LEFT JOIN RegularSourceChoices s USING(SourceID)',
      'INSERT INTO temp.MixedCards VALUES(?,?,?,?,?,?)',6);
    LinkedStage.ExecSQL('CREATE INDEX temp.MixedCardsByGroup ON MixedCards(GroupID)');
    LinkedPlan.RankLinkedSources(True);
    LinkedStage.ExecSQL('CREATE TEMP TABLE MixedWinners(GroupID INTEGER PRIMARY KEY,BookID INTEGER NOT NULL,CopyKey TEXT NOT NULL)');
    LinkedStage.ExecSQL('WITH Files AS MATERIALIZED ('+
      'SELECT m.GroupID,m.BookID,'''' AS CopyKey,NULL AS FileIdentity, '+
      'CASE WHEN b.BookID IS NULL OR b.Name=m.SourceName THEN p.Position END AS Rank, '+
      'max(m.Manual,coalesce(b.Manual,0)) AS Manual FROM temp.MixedCards m '+
      'LEFT JOIN LinkedPrimarySources b USING(BookID) LEFT JOIN LinkedSourceChoices a ON a.SourceID=b.SourceID '+
      'LEFT JOIN temp.SourcePriority p ON p.Name=CASE WHEN a.PriorityRoot<>'''' THEN a.PriorityCaption ELSE m.PriorityCaption END '+
      'UNION ALL SELECT m.GroupID,c.BookID,c.CopyKey,c.PhysicalIdentity,p.Position,c.Manual FROM temp.MixedCards m '+
      'JOIN LinkedCopies c USING(BookID) LEFT JOIN LinkedSourceChoices s USING(SourceID) '+
      'LEFT JOIN temp.SourcePriority p ON p.Name=s.PriorityCaption), '+
      'Best AS MATERIALIZED (SELECT GroupID,min(Rank) AS Rank FROM Files GROUP BY GroupID '+
      'HAVING count(*) BETWEEN 3 AND 1000 AND count(DISTINCT Rank)=count(*) AND max(Manual)=0 '+
      'AND count(DISTINCT FileIdentity)=count(FileIdentity)) '+
      'INSERT INTO temp.MixedWinners SELECT f.GroupID,f.BookID,f.CopyKey FROM Files f JOIN Best USING(GroupID,Rank) '+
      'WHERE NOT EXISTS(SELECT 1 FROM temp.MixedCards c WHERE c.GroupID=f.GroupID AND c.BookID<>f.BookID AND c.Protected<>0)');
    LinkedPlan.PlanLinkedPromotions(True);
    LinkedStage.ExecSQL('DELETE FROM temp.MixedWinners WHERE CopyKey<>'''' AND '+
      'BookID NOT IN (SELECT BookID FROM LinkedPromotions)');
    LinkedStage.ExecSQL('DELETE FROM MixedSelection');
    LinkedStage.ExecSQL('INSERT INTO MixedSelection SELECT GroupID,BookID FROM temp.MixedWinners');
    LinkedStage.ExecSQL('UPDATE LinkedCopies SET Selected=1 WHERE BookID IN (SELECT m.BookID FROM temp.MixedCards m '+
      'JOIN temp.MixedWinners w USING(GroupID))');

    FStage.ExecSQL('CREATE TEMP TABLE MixedWinners(GroupID INTEGER PRIMARY KEY,BookID INTEGER NOT NULL)');
    Transfer(LinkedStage,FStage,'SELECT GroupID,BookID FROM temp.MixedWinners','INSERT INTO temp.MixedWinners VALUES(?,?)',2);
    Dec(Result,FStage.QuerySingleInt('SELECT count(*) FROM DuplicateGroups g JOIN temp.MixedGroups m USING(GroupID) '+
      'WHERE g.Manual=0 AND g.Selected=1'));
    FStage.ExecSQL('UPDATE DuplicateGroups AS g SET Selected=0,KeepID=(SELECT min(BookID) FROM Candidates c '+
      'WHERE c.Identity=g.Identity) WHERE Manual=0 AND GroupID IN (SELECT GroupID FROM temp.MixedGroups)');
    FStage.ExecSQL('UPDATE DuplicateGroups AS g SET KeepID=w.BookID,Selected=1 FROM temp.MixedWinners w WHERE g.GroupID=w.GroupID');
    Inc(Result,FStage.QuerySingleInt('SELECT changes()'));
    LinkedSelected:=LinkedStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE Selected=1 AND Manual=0');
    FStage.ExecSQL('DROP TABLE temp.MixedWinners');
    FStage.ExecSQL('DROP TABLE temp.MixedGroups');
    FStage.ExecSQL('DROP TABLE temp.LinkedOwners');
    FStage.ExecSQL('DROP TABLE temp.SourcePriority');
    LinkedStage.ExecSQL('DROP TABLE temp.MixedWinners');
    LinkedStage.ExecSQL('DROP TABLE temp.MixedCards');
    LinkedStage.ExecSQL('DROP TABLE temp.SourcePriority');
    if QueryCanceled then Abort;
    FStage.Commit;
    try
      LinkedStage.Commit;
    except
      // Temporary plans are on separate connections. A failure after the
      // first commit invalidates both previews until the next scan.
      FReady:=False;
      LinkedPlan.FReady:=False;
      raise;
    end;
    FSelectionCountsValid:=False;
    LinkedPlan.FSelectionCountsValid:=False;
  finally
    if LinkedStage.InTransaction then LinkedStage.Rollback;
    if FStage.InTransaction then FStage.Rollback;
    SQLiteCancelCallback:=Previous;
    LinkedPlan.FCanceled:=nil;
    FCanceled:=nil;
  end;
end;

procedure TBookDuplicatePlan.CheckCombinedSelection(RegularPlan: TBookDuplicatePlan; const Canceled: TMergeCanceled);
var Groups, Retained: TSQLiteQuery;
begin
  if FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM MixedSelection)')=0 then Exit;
  if not Assigned(RegularPlan) or not RegularPlan.FReady then
    raise EReadError.Create('Выбор сохраняемых книг изменился. Примените порядок источников заново.');
  Groups:=FStage.NewQuery('SELECT GroupID,KeepID FROM MixedSelection ORDER BY GroupID');
  try
    Retained:=RegularPlan.FStage.NewQuery('SELECT EXISTS(SELECT 1 FROM DuplicateGroups g '+
      'JOIN DeletionKept k ON k.BookID=g.KeepID WHERE g.GroupID=? AND g.KeepID=? AND g.Selected=1)');
    try
      Groups.Open;
      while not Groups.Eof do
      begin
        if Assigned(Canceled) and Canceled() then Abort;
        Retained.SetParam(0,Groups.FieldAsInt(0));
        Retained.SetParam(1,Groups.FieldAsInt(1));
        Retained.Open;
        if not Retained.FieldAsBoolean(0) then
          raise EReadError.Create('Выбор сохраняемых книг изменился. Примените порядок источников заново.');
        Retained.Reset;
        Groups.Next;
      end;
    finally Retained.Free; end;
  finally Groups.Free; end;
end;

function TBookDuplicatePlan.Groups(Offset, Limit: Integer; UnmarkedOnly: Boolean): TArray<TDuplicateGroup>;
var Q: TSQLiteQuery; Values: TList<TDuplicateGroup>; Group: TDuplicateGroup;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала выполните поиск повторов.');
  if (Offset<0) or (Limit<1) or (Limit>100) then raise EArgumentOutOfRangeException.Create('Страница повторов');
  Values:=TList<TDuplicateGroup>.Create;
  try
    if FLinkedMode then
      Q:=FStage.NewQuery('SELECT BookID,'''',Count,BookID,(SELECT count(*) FROM LinkedCopies c WHERE c.BookID=g.BookID '+
        'AND c.Selected=1) FROM LinkedGroups g ORDER BY BookID LIMIT ? OFFSET ?')
    else
      Q:=FStage.NewQuery('SELECT GroupID,Identity,Count,KeepID,CASE WHEN Selected=1 THEN Count-1 ELSE 0 END FROM DuplicateGroups '+
        IfThen(UnmarkedOnly,'WHERE Selected=0 ','')+'ORDER BY GroupID LIMIT ? OFFSET ?');
    try
      Q.SetParam(0,Limit); Q.SetParam(1,Offset); Q.Open;
      while not Q.Eof do
      begin
        Group:=Default(TDuplicateGroup); Group.ID:=Q.FieldAsInt(0); Group.Identity:=Q.FieldAsString(1);
        Group.Count:=Q.FieldAsInt(2); Group.KeepID:=Q.FieldAsInt(3); Group.SelectedCopies:=Q.FieldAsInt(4);
        Group.Selected:=Group.SelectedCopies>0;
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
    IDs:=FStage.NewQuery('SELECT c.BookID,coalesce(nullif(s.PriorityCaption,''''),c.SourceName) '+
      'FROM Candidates c JOIN DuplicateGroups g USING(Identity) LEFT JOIN RegularSourceChoices s USING(SourceID) '+
      'WHERE g.GroupID=? ORDER BY c.BookID');
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

function TBookDuplicatePlan.LinkedCopy(const CopyKey: string; BookID: Integer;
  out SourceName: string): TBookRecord;
var Q:TSQLiteQuery;
begin
  Q:=FSource.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,BookSize,SourceName '+
    'FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?',[CopyKey,BookID]);
  try
    Q.Open;
    if Q.Eof then raise EReadError.Create('Привязка файла исчезла из снимка.');
    Result:=ReadDuplicateLocation(Q,0,Q.FieldAsString(5),CreateBookKey(BookID,FCID));
    Result.Size:=Q.FieldAsInt(6);
    SourceName:=Q.FieldAsString(7);
  finally Q.Free; end;
end;

function TBookDuplicatePlan.PreferredLinkedLocation(const Current:TBookRecord; const CopyKey:string;
  out SourceName:string):TBookRecord;
var Preferred:TBookRecord; Container:string;
begin
  Preferred:=LinkedCopy(CopyKey,Current.BookKey.BookID,SourceName);
  Container:=Preferred.GetBookContainer;
  Result:=Current;
  Result.Folder:=Container;
  Result.FileName:=Preferred.FileName;
  Result.FileExt:=Preferred.FileExt;
  Result.InsideNo:=Preferred.InsideNo;
  Result.Size:=Preferred.Size;
  if Preferred.IsLinkedSource or (SourceName='') or not SameText(Current.FileExt,Preferred.FileExt) or
    (ReaderBookPhysicalIdentity(Preferred)='') or
    (ReaderBookPhysicalIdentity(Result)<>ReaderBookPhysicalIdentity(Preferred)) or
    (ReaderHistoryName(Current,FNamespace)<>ReaderHistoryName(Result,FNamespace)) then
    raise EReadError.Create('Нельзя безопасно заменить основной файл этой книги.');
end;

function TBookDuplicatePlan.LinkedBooks(BookID: Integer): TArray<TDuplicateBook>;
var Q, Staged: TSQLiteQuery; Values: TList<TDuplicateBook>; Primary, Entry: TDuplicateBook;
  PreferredKey, Name:string;
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
    Name:=FStage.QuerySingleString('SELECT s.PriorityCaption FROM LinkedPrimarySources p '+
      'JOIN LinkedSourceChoices s USING(SourceID) WHERE p.BookID=?',[BookID]);
    if Name<>'' then Primary.SourceName:=Name;
    PreferredKey:=FStage.QuerySingleString('SELECT PreferredKey FROM LinkedPromotions WHERE BookID=?',[BookID]);
    if PreferredKey<>'' then
    begin
      Primary.Book:=PreferredLinkedLocation(Primary.Book,PreferredKey,Name);
      Primary.SourceName:=FStage.QuerySingleString('SELECT s.PriorityCaption FROM LinkedPromotions p '+
        'JOIN LinkedSourceChoices s ON s.SourceID=p.PreferredSourceID WHERE p.BookID=?',[BookID]);
      if Primary.SourceName='' then Primary.SourceName:=Name;
    end;
    Values.Add(Primary); FreeAndNil(Q);
    Staged:=FStage.NewQuery('SELECT c.CopyKey,s.Caption,c.Selected FROM LinkedCopies c LEFT JOIN LinkedSourceChoices s USING(SourceID) '+
      'WHERE c.BookID=? ORDER BY c.CopyKey',[BookID]);
    Q:=FSource.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo,Root,BookSize,SourceName FROM CatalogBookCopies WHERE SourceKey=?');
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
      if Entry.SourceName='' then Entry.SourceName:=Q.FieldAsString(7);
      Values.Add(Entry); Q.Reset; Staged.Next;
    end;
    Result:=Values.ToArray;
  finally Q.Free; Staged.Free; Values.Free; end;
end;

procedure TBookDuplicatePlan.PreferLinkedCopy(BookID:Integer; const CopyKey:string);
var PreviousKey,OldPreferred,Name:string; Current:TBookRecord; OwnTransaction:Boolean; Entries:TArray<TDuplicateBook>;
begin
  if not FReady or not FLinkedMode then raise EInvalidOperation.Create('Сначала найдите копии книг.');
  if CopyKey='' then Exit;
  Entries:=Books(BookID);
  var Found:=False;
  for var Entry in Entries do if Entry.CopyKey=CopyKey then Found:=True;
  if not Found then raise EArgumentException.Create('Выбранная копия больше не входит в список.');
  OwnTransaction:=not FStage.InTransaction;
  if OwnTransaction then FStage.Start;
  try
    OldPreferred:=FStage.QuerySingleString('SELECT PreferredKey FROM LinkedPromotions WHERE BookID=?',[BookID]);
    PreviousKey:=FStage.QuerySingleString('SELECT PreviousKey FROM LinkedPromotions WHERE BookID=?',[BookID]);
    if OldPreferred<>'' then
    begin
      FStage.ExecSQL('DELETE FROM LinkedCopies WHERE CopyKey=?',[PreviousKey]);
      FStage.ExecSQL('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID,Archive,PhysicalIdentity) '+
        'SELECT PreferredKey,BookID,PreferredSourceID,PreferredArchive,PreferredIdentity FROM LinkedPromotions WHERE BookID=?',[BookID]);
      FStage.ExecSQL('DELETE FROM LinkedPromotions WHERE BookID=?',[BookID]);
    end;
    if CopyKey<>PreviousKey then
    begin
      Entries:=Books(BookID); Current:=Entries[0].Book;
      PreferredLinkedLocation(Current,CopyKey,Name);
      if FStage.QuerySingleInt('SELECT count(*) FROM LinkedOriginals WHERE BookID=?',[BookID])<>1 then
        raise EInvalidOperation.Create('Исходный путь этой копии нельзя однозначно определить. Обновите список дублей.');
      FStage.ExecSQL('INSERT INTO LinkedPromotions SELECT c.BookID,o.CopyKey,c.CopyKey,c.SourceID,c.Archive,c.PhysicalIdentity '+
        'FROM LinkedCopies c JOIN LinkedOriginals o USING(BookID) WHERE c.CopyKey=? AND c.BookID=?',[CopyKey,BookID]);
      FStage.ExecSQL('DELETE FROM LinkedCopies WHERE CopyKey=?',[CopyKey]);
      FStage.ExecSQL('INSERT INTO LinkedCopies(CopyKey,BookID,SourceID,Archive,PhysicalIdentity) '+
        'SELECT o.CopyKey,o.BookID,o.SourceID,o.Archive,o.PhysicalIdentity FROM LinkedOriginals o WHERE o.BookID=?',[BookID]);
    end;
    FStage.ExecSQL('UPDATE LinkedPrimarySources SET Manual=1 WHERE BookID=?',[BookID]);
    if OwnTransaction then FStage.Commit;
  except if OwnTransaction then FStage.Rollback; raise; end;
  FSelectionCountsValid:=False;
end;

procedure TBookDuplicatePlan.ChooseCopy(const CopyKey: string; Selected: Boolean);
begin
  if not FReady or not FLinkedMode or (CopyKey='') then
    raise EArgumentException.Create('Основная копия сохраняется.');
  FStage.Start;
  try
    FStage.ExecSQL('UPDATE LinkedPrimarySources SET Manual=1 WHERE BookID='+
      '(SELECT BookID FROM LinkedPromotions WHERE PreviousKey=?)',[CopyKey]);
    FStage.ExecSQL('UPDATE LinkedCopies SET Selected=?,Manual=1 WHERE CopyKey=?',[Ord(Selected),CopyKey]);
    FStage.Commit;
  except FStage.Rollback; raise; end;
  FSelectionCountsValid:=False;
end;

procedure TBookDuplicatePlan.Choose(GroupID, KeepID: Integer; Selected: Boolean);
var Found,OwnTransaction:Boolean;
begin
  if FReady and FLinkedMode then
  begin
    OwnTransaction:=not FStage.InTransaction;
    if OwnTransaction then FStage.Start;
    try
      FStage.ExecSQL('UPDATE LinkedPrimarySources SET Manual=1 WHERE BookID='+
        '(SELECT BookID FROM LinkedPromotions WHERE BookID=?)',[GroupID]);
      FStage.ExecSQL('UPDATE LinkedCopies SET Selected=?,Manual=1 WHERE BookID=?',[Ord(Selected),GroupID]);
      if OwnTransaction then FStage.Commit;
    except if OwnTransaction then FStage.Rollback; raise; end;
    FSelectionCountsValid:=False;
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
  FStage.ExecSQL('UPDATE DuplicateGroups SET KeepID=?,Selected=?,Manual=1 WHERE GroupID=?',[KeepID,Selected,GroupID]);
  FSelectionCountsValid:=False;
end;

procedure TBookDuplicatePlan.ReadSelectionCounts;
var Query: TSQLiteQuery;
begin
  if FSelectionCountsValid then Exit;
  if FLinkedMode then
    Query:=FStage.NewQuery('SELECT count(DISTINCT BookID),count(*) FROM LinkedCopies WHERE Selected=1')
  else
    Query:=FStage.NewQuery('SELECT count(*),coalesce(sum(Count-1),0) FROM DuplicateGroups WHERE Selected<>0');
  try
    Query.Open;
    FSelectedGroups:=Query.FieldAsInt(0);
    FSelectedCopies:=Query.FieldAsInt(1);
    FSelectionCountsValid:=True;
  finally Query.Free; end;
end;

function TBookDuplicatePlan.SelectedCount: Integer;
begin
  if not FReady then Exit(0);
  ReadSelectionCounts;
  Result:=FSelectedGroups;
end;

function TBookDuplicatePlan.SelectedRemovedCount: Integer;
begin
  if not FReady then Exit(0);
  ReadSelectionCounts;
  Result:=FSelectedCopies;
end;

function TBookDuplicatePlan.SelectedPromotionKey(BookID: Integer): string;
begin
  Result:='';
  if FReady and FLinkedMode then
    Result:=FStage.QuerySingleString('SELECT p.PreferredKey FROM LinkedPromotions p WHERE p.BookID=? '+
      'AND EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.BookID=p.BookID AND c.Selected=1)',[BookID]);
end;

procedure TBookDuplicatePlan.PreviewSelectedPromotion(var Value: TDuplicateBook);
begin
  var Key:=SelectedPromotionKey(Value.Book.BookKey.BookID);
  if Key='' then Exit;
  Value.Book:=PreferredLinkedLocation(Value.Book,Key,Value.SourceName);
  var Caption:=FStage.QuerySingleString('SELECT s.PriorityCaption FROM LinkedPromotions p '+
    'JOIN LinkedSourceChoices s ON s.SourceID=p.PreferredSourceID WHERE p.BookID=?',[Value.Book.BookKey.BookID]);
  if Caption<>'' then Value.SourceName:=Caption;
end;

function TBookDuplicatePlan.HasSelectedLinkedCopy(const CopyKey: string; BookID: Integer): Boolean;
begin
  Result:=FReady and FLinkedMode and
    (FStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE BookID=? AND Selected=1 AND '+
      'CopyKey=coalesce((SELECT Representative FROM LinkedFileAliases WHERE CopyKey=?),?)',
      [BookID,CopyKey,CopyKey])=1);
end;

function TBookDuplicatePlan.ReadLinkedDeletion(const Info: TCollectionInfo; Selection: TSQLiteQuery;
  out LastArchive, LastKey: string; out Files: Integer): TBookDeletionBinding;
const Limit = LINKED_DUPLICATE_BATCH_SIZE;
var Q, Aliases: TSQLiteQuery; Keys: TArray<string>; Copies, Primary: TArray<TBookRecord>;
  Count, Boundary, BoundaryFiles, PrimaryBookID: Integer;
  Archive, Representative, BoundaryArchive, BoundaryKey, PreferredKey, PreferredName:string;
  ChosenPrimary:TBookRecord;

  procedure AddRow(const SourceKey: string; const Key: TBookKey);
  begin
    if QueryCanceled then Abort;
    Q.SetParam(0,SourceKey); Q.SetParam(1,Key.BookID); Q.Open;
    if Q.Eof then raise EReadError.Create('Дополнительная копия исчезла из снимка.');
    Keys[Count]:=SourceKey;
    Copies[Count]:=ReadDuplicateLocation(Q,0,Q.FieldAsString(5),Key);
    if PrimaryBookID<>Key.BookID then
    begin
      PrimaryBookID:=Key.BookID;
      ChosenPrimary:=ReadDuplicateLocation(Q,6,FRoot,Key);
      PreferredKey:=Selection.FieldAsString(3);
      if PreferredKey<>'' then ChosenPrimary:=PreferredLinkedLocation(ChosenPrimary,PreferredKey,PreferredName);
    end;
    Primary[Count]:=ChosenPrimary;
    Inc(Count); Q.Reset;
  end;

begin
  PrimaryBookID:=0;
  Files:=0;
  Result:=Default(TBookDeletionBinding);
  Selection.Open;
  if Selection.Eof then Exit;
  SetLength(Keys,Limit);
  SetLength(Copies,Limit); SetLength(Primary,Limit);
  Count:=0; Boundary:=0; BoundaryFiles:=0;
  LastArchive:=''; LastKey:='';
  Q:=FSource.NewQuery('SELECT c.LibID,c.Folder,c.FileName,c.Ext,c.InsideNo,c.Root,'+
    'b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo FROM CatalogBookCopies c JOIN Books b USING(BookID) WHERE c.SourceKey=? AND c.BookID=?');
  Aliases:=nil;
  try
    Aliases:=FStage.NewQuery('SELECT CopyKey FROM LinkedFileAliases WHERE Representative=? ORDER BY CopyKey');
    while (Count<Limit) and not Selection.Eof do
    begin
      var RowsForFile:=Selection.FieldAsInt(4)+1;
      if RowsForFile>Limit then raise EReadError.Create('У файла слишком много ссылок для одного удаления.');
      if Count+RowsForFile>Limit then Break;
      Archive:=Selection.FieldAsString(0);
      Representative:=Selection.FieldAsString(1);
      if (Count>0) and (Archive<>LastArchive) then
      begin
        Boundary:=Count; BoundaryFiles:=Files;
        BoundaryArchive:=LastArchive; BoundaryKey:=LastKey;
      end;
      var Key:=CreateBookKey(Selection.FieldAsInt(2),FCID);
      AddRow(Representative,Key);
      if RowsForFile>1 then
      begin
        Aliases.SetParam(0,Representative); Aliases.Open;
        while not Aliases.Eof do
        begin
          AddRow(Aliases.FieldAsString(0),Key);
          Aliases.Next;
        end;
        Aliases.Reset;
      end;
      LastArchive:=Archive; LastKey:=Representative;
      Inc(Files); Selection.Next;
    end;
    if not Selection.Eof and (Boundary>0) and
      (Selection.FieldAsString(0)=LastArchive) then
    begin
      Count:=Boundary; Files:=BoundaryFiles;
      LastArchive:=BoundaryArchive; LastKey:=BoundaryKey;
    end;
    SetLength(Keys,Count); SetLength(Copies,Count); SetLength(Primary,Count);
    Result:=TBookDeletionBinding.CaptureCopies(Info,Copies,Primary,Keys);
  finally Aliases.Free; Q.Free; end;
end;

procedure EnableDuplicateLocationTriggers(Context:TSQLite3Context; Count:Integer; Args:TSQLite3Value); cdecl;
begin
  SQLite3_Result_Int(Context,1);
end;

procedure TBookDuplicatePlan.CommitLinkedPromotions;
const PrimarySQL='SELECT b.LibID,b.Folder,b.FileName,b.Ext,b.InsideNo,b.IsDeleted,p.SourceName '+
    'FROM Books b LEFT JOIN CatalogPreferredSource p USING(BookID) WHERE b.BookID=?';
  AliasSQL='SELECT * FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?';
var DB:TSQLiteDatabase; Selection, Current, Personal:TSQLiteQuery; BookID:Integer;
  OldBook, Preferred:TBookRecord; Name, PreviousKey, PreferredKey, FileName, SourceID, LastArchive:string;
  MemberIndex:TBookDeletionMemberIndex;

  procedure CheckAlias(const CopyKey:string);
  begin
    if DuplicateQueryDigest(DB,AliasSQL,[CopyKey,BookID])<>
      DuplicateQueryDigest(FSource,AliasSQL,[CopyKey,BookID]) then
      raise EReadError.Create('Источник книги изменился после проверки. Повторите поиск дублей.');
  end;

begin
  Selection:=FStage.NewQuery('SELECT BookID,PreviousKey,PreferredKey FROM LinkedPromotions p '+
    'WHERE EXISTS(SELECT 1 FROM LinkedCopies c WHERE c.BookID=p.BookID AND c.Selected=1) ORDER BY PreferredArchive');
  DB:=nil; Current:=nil; Personal:=nil; MemberIndex:=nil;
  try
    Selection.Open;
    if Selection.Eof then Exit;
    DB:=TSQLiteDatabase.Create(FFile);
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableDuplicateLocationTriggers);
    DB.ExecSQL('ATTACH DATABASE ? AS Personal',[FSystemFile]);
    DB.Start('','IMMEDIATE');
    Current:=FSource.NewQuery(PrimarySQL);
    Personal:=DB.NewQuery('SELECT LibID,Folder,FileName,Ext,InsideNo FROM Personal.Books '+
      'WHERE DatabaseID=? AND BookID=?');
    while not Selection.Eof do
    begin
      if QueryCanceled then Abort;
      BookID:=Selection.FieldAsInt(0);
      PreviousKey:=Selection.FieldAsString(1);
      PreferredKey:=Selection.FieldAsString(2);
      if DuplicateQueryDigest(DB,PrimarySQL,[BookID])<>DuplicateQueryDigest(FSource,PrimarySQL,[BookID]) then
        raise EReadError.Create('Основной файл книги изменился после проверки. Повторите поиск дублей.');
      CheckAlias(PreviousKey);
      CheckAlias(PreferredKey);
      Current.SetParam(0,BookID);
      Current.Open;
      if Current.Eof or Current.FieldAsBoolean(5) then
        raise EReadError.Create('Карточка книги недоступна.');
      OldBook:=ReadDuplicateLocation(Current,0,FRoot,CreateBookKey(BookID,FCID));
      Current.Reset;
      if ReaderBookPhysicalIdentity(LinkedCopy(PreviousKey,BookID,Name))<>ReaderBookPhysicalIdentity(OldBook) then
        raise EReadError.Create('Привязка прежнего основного файла изменилась.');
      Preferred:=PreferredLinkedLocation(OldBook,PreferredKey,Name);
      FileName:=Preferred.GetBookFileName;
      if not FileExists(DeletionNativePath(FileName)) or (TFile.GetSize(DeletionNativePath(FileName))<=0) then
        raise EReadError.Create('Приоритетный файл недоступен: '+FileName);
      if Preferred.GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd] then
      begin
        SourceID:=ArchiveDeletionSourceIdentity(FileName);
        if SourceID<>LastArchive then
        begin
          FreeAndNil(MemberIndex);
          MemberIndex:=TBookDeletionMemberIndex.Create(ReadBookDeletionInventory(FileName,SourceID,
            function:Boolean begin Result:=QueryCanceled; end));
          LastArchive:=SourceID;
        end;
        MemberIndex.Resolve(Preferred);
      end;
      // Group and favourite views can use a personal copy of the catalogue row.
      // Keep its identity and personal fields, and update only its file location.
      Personal.SetParam(0,FCID); Personal.SetParam(1,BookID); Personal.Open;
      if not Personal.Eof then
      begin
        var Stored:=ReadDuplicateLocation(Personal,0,FRoot,OldBook.BookKey);
        if (Stored.LibID<>OldBook.LibID) or
          (ReaderBookPhysicalIdentity(Stored)<>ReaderBookPhysicalIdentity(OldBook)) then
          raise EReadError.Create('Путь к книге в пользовательской группе изменился. Повторите поиск дублей.');
        Personal.Reset;
        DB.ExecSQL('UPDATE Personal.Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,BookSize=?,IsLocal=1 '+
          'WHERE DatabaseID=? AND BookID=?',
          [Preferred.Folder,Preferred.FileName,Preferred.FileExt,Preferred.InsideNo,Preferred.Size,FCID,BookID]);
      end
      else Personal.Reset;
      DB.ExecSQL('UPDATE Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,BookSize=?,IsLocal=1 WHERE BookID=?',
        [Preferred.Folder,Preferred.FileName,Preferred.FileExt,Preferred.InsideNo,Preferred.Size,BookID]);
      DB.ExecSQL('INSERT INTO CatalogPreferredSource(BookID,SourceName) VALUES(?,?) '+
        'ON CONFLICT(BookID) DO UPDATE SET SourceName=excluded.SourceName',[BookID,Name]);
      Selection.Next;
    end;
    if QueryCanceled then Abort;
    DB.Commit;
    FCommitted:=True;
  finally
    MemberIndex.Free;
    Personal.Free;
    Current.Free;
    Selection.Free;
    if Assigned(DB) then
      try if DB.InTransaction then DB.Rollback; finally DB.Free; end;
  end;
end;

procedure TBookDuplicatePlan.PrepareLinkedBatches(const Info: TCollectionInfo; const Canceled: TMergeCanceled;
  const Progress: TMergeProgress; AllowPrimaryPromotion: Boolean);
var Selection: TSQLiteQuery; LastArchive, LastKey: string; Previous: TSQLiteCancelCallback;
  Count, Done, Batch, Files: Integer; Binding: TBookDeletionBinding;
begin
  if not FReady or not FLinkedMode or (Info.ID<>FCID) or isOnlineCollection(Info.CollectionType) or
    not SameFileName(FFile,Info.DBFileName) or
    not SameFileName(ExcludeTrailingPathDelimiter(Info.GetRootPath),ExcludeTrailingPathDelimiter(FRoot)) or
    (Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey) then
    raise EReadError.Create('Коллекция изменилась. Повторите поиск дублей.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  Selection:=nil;
  try
    if QueryCanceled then Abort;
    if not AllowPrimaryPromotion and (FStage.QuerySingleInt('SELECT count(*) FROM LinkedPromotions')>0) then
      raise EReadError.Create('Смену основного файла нужно применить отдельно от удаления повторных карточек.');
    Count:=SelectedRemovedCount;
    Done:=0; Batch:=0;
    LastArchive:=''; LastKey:='';
    FStage.Start;
    FStage.ExecSQL('CREATE TABLE LinkedDeletionBatches(BatchID INTEGER PRIMARY KEY,Binding TEXT NOT NULL)');
    FStage.ExecSQL('CREATE INDEX LinkedDeletionOrder ON LinkedCopies(Archive,CopyKey) WHERE Selected=1');
    Selection:=FStage.NewQuery('SELECT c.Archive,c.CopyKey,c.BookID,p.PreferredKey,'+
      '(SELECT count(*) FROM LinkedFileAliases a WHERE a.Representative=c.CopyKey) FROM LinkedCopies c '+
      'LEFT JOIN LinkedPromotions p USING(BookID) WHERE c.Selected=1 '+
      'AND (c.Archive,c.CopyKey)>(?,?) ORDER BY c.Archive,c.CopyKey LIMIT ?');
    while Done<Count do
    begin
      Selection.SetParam(0,LastArchive); Selection.SetParam(1,LastKey);
      Selection.SetParam(2,LINKED_DUPLICATE_BATCH_SIZE+1);
      Binding:=ReadLinkedDeletion(Info,Selection,LastArchive,LastKey,Files);
      Selection.Reset;
      if Binding.CollectionID=0 then raise EReadError.Create('Выбор дополнительных копий изменился.');
      Inc(Batch); Inc(Done,Files);
      FStage.ExecSQL('INSERT INTO LinkedDeletionBatches VALUES(?,?)',[Batch,Binding.ToJSON]);
      if Assigned(Progress) then Progress(Done,Count);
    end;
    if QueryCanceled then Abort;
    FStage.Commit;
    CommitLinkedPromotions;
    FreeAndNil(FSource);
  finally
    Selection.Free;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    if FStage.InTransaction then FStage.Rollback;
  end;
end;

function TBookDuplicatePlan.LinkedDeletionBatch(Index: Integer): TBookDeletionBinding;
begin
  var Data:=FStage.QuerySingleString('SELECT Binding FROM LinkedDeletionBatches WHERE BatchID=?',[Index]);
  if Data='' then Exit(Default(TBookDeletionBinding));
  Result:=TBookDeletionBinding.Parse(Data);
end;

procedure TBookDuplicatePlan.PrepareDeletionBatches(const Info: TCollectionInfo;
  const Canceled: TMergeCanceled; const Progress: TMergeProgress; ApprovedLinks: TBookDuplicatePlan;
  SkipBlocked: Boolean);
var Current, Personal: TSQLiteDatabase; Selection, Copies, AddRemoved, AddKept: TSQLiteQuery;
  Previous: TSQLiteCancelCallback;
  GroupsTotal, RemovedTotal, GroupsDone, RemovedDone: Integer;
  BatchQueries, CheckPromotions: Boolean;
  BlockReason: Integer;
  PreferredKey, PreferredName: string;
  SkippedGroups: array[1..3] of Integer;
const
  BlockReasons: array[1..3] of string = ('сведения о книге изменились после поиска дублей',
    'у копии есть оценка, заметка или другие личные данные', 'выбраны не все файлы этой книги');
  function ExtraLinksApproved(const Book: TBookRecord): Boolean;
  var Identity: string;
  begin
    Identity:=ReaderBookPhysicalIdentity(Book);
    Copies.Reset; Copies.SetParam(0,Book.BookKey.BookID); Copies.Open;
    while not Copies.Eof do
    begin
      var Linked:=Default(TBookRecord);
      Linked.CollectionRoot:=Copies.FieldAsString(0);
      Linked.Folder:=Copies.FieldAsString(1);
      Linked.FileName:=Copies.FieldAsString(2);
      Linked.FileExt:=Copies.FieldAsString(3);
      Linked.InsideNo:=Copies.FieldAsInt(4);
      if (ReaderBookPhysicalIdentity(Linked)<>Identity) and
        (not Assigned(ApprovedLinks) or
          not ApprovedLinks.HasSelectedLinkedCopy(Copies.FieldAsString(5),Book.BookKey.BookID)) then Exit(False);
      Copies.Next;
    end;
    Result:=True;
  end;

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
  FSkippedCopies:=0;
  FSkippedDetails:=nil;
  FillChar(SkippedGroups, SizeOf(SkippedGroups), 0);
  if not FReady or FLinkedMode or (SelectedCount=0) then
    raise EInvalidOperation.Create('Сначала отметьте группы и выберите копии, которые нужно сохранить.');
  if (Info.ID<>FCID) or isOnlineCollection(Info.CollectionType) or
    not SameFileName(FFile,Info.DBFileName) or
    (Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey) then
    raise EInvalidOperation.Create('Коллекция изменилась. Повторите поиск дублей.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  Current:=nil; Personal:=nil; Selection:=nil; Copies:=nil;
  AddRemoved:=nil; AddKept:=nil; BatchQueries:=False;
  try
    CheckCanceled;
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
    // Store file identities in the preview database and release the
    // catalogue snapshot before the worker changes any files.
    FStage.Start;
    FStage.ExecSQL('CREATE TABLE DeletionKept(BookID INTEGER PRIMARY KEY,LibID TEXT,Folder TEXT,'+
      'FileName TEXT,Ext TEXT,InsideNo INTEGER)');
    FStage.ExecSQL('CREATE TABLE DeletionFiles(Archive TEXT,BookID INTEGER,LibID TEXT,Folder TEXT,'+
      'FileName TEXT,Ext TEXT,InsideNo INTEGER,KeepID INTEGER,PRIMARY KEY(Archive,BookID)) WITHOUT ROWID');
    AddRemoved:=FStage.NewQuery('INSERT INTO DeletionFiles VALUES(?,?,?,?,?,?,?,?)');
    AddKept:=FStage.NewQuery('INSERT INTO DeletionKept VALUES(?,?,?,?,?,?)');
    CheckPromotions:=Assigned(ApprovedLinks) and ApprovedLinks.FReady and ApprovedLinks.FLinkedMode and
      (ApprovedLinks.FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM LinkedPromotions)')<>0);
    GroupsTotal:=SelectedCount; RemovedTotal:=SelectedRemovedCount;
    GroupsDone:=0; RemovedDone:=0;
    Selection:=FStage.NewQuery('SELECT GroupID,KeepID FROM DuplicateGroups WHERE Selected<>0 ORDER BY GroupID');
    Copies:=Current.NewQuery('SELECT Root,Folder,FileName,Ext,InsideNo,SourceKey FROM CatalogBookCopies WHERE BookID=?');
    Selection.Open;
    while not Selection.Eof do
    begin
      CheckCanceled;
      var KeepID:=Selection.FieldAsInt(1);
      var Group:=Books(Selection.FieldAsInt(0));
      BlockReason := 0;
      PreferredKey:='';
      if CheckPromotions then
      begin
        PreferredKey:=ApprovedLinks.SelectedPromotionKey(KeepID);
        for var Item in Group do
          if (Item.Book.BookKey.BookID<>KeepID) and
            (ApprovedLinks.SelectedPromotionKey(Item.Book.BookKey.BookID)<>'') then
            raise EReadError.CreateFmt('У книги «%s» выбраны разные сохраняемые копии. Уточните выбор перед удалением.',
              [Item.Book.Title]);
      end;
      var BlockedTitle := '';
      // Check reasons that prohibit removal before hashing records. A group
      // can proceed only after every original safety check succeeds.
      for var Item in Group do
      begin
        CheckCanceled;
        if Item.Book.BookKey.BookID = KeepID then Continue;
        if Item.HasPersonalData then BlockReason := 2
        else if not ExtraLinksApproved(Item.Book) then BlockReason := 3;
        if BlockReason = 0 then Continue;
        BlockedTitle := Item.Book.Title;
        Break;
      end;
      if BlockReason = 0 then
        for var Item in Group do
        begin
          CheckCanceled;
          var ID := Item.Book.BookKey.BookID;
          if DuplicateQueryDigest(Current,'SELECT * FROM Books WHERE BookID=?',[ID]) =
             DuplicateQueryDigest(FSource,'SELECT * FROM Books WHERE BookID=?',[ID]) then Continue;
          BlockReason := 1;
          BlockedTitle := Item.Book.Title;
          Break;
        end;
      if BlockReason <> 0 then
      begin
        var Detail := Format('«%s» — %s.', [Copy(BlockedTitle, 1, 100), BlockReasons[BlockReason]]);
        if not SkipBlocked or (PreferredKey<>'') then raise EInvalidOperation.Create(Detail);
        if Length(FSkippedDetails) < 8 then FSkippedDetails := FSkippedDetails + [Detail];
        Inc(SkippedGroups[BlockReason]);
        Inc(FSkippedCopies, Length(Group) - 1);
      end
      else
        for var Item in Group do
        begin
          CheckCanceled;
          var Book:=Item.Book;
          if Book.BookKey.BookID=KeepID then
          begin
            if PreferredKey<>'' then Book:=ApprovedLinks.PreferredLinkedLocation(Book,PreferredKey,PreferredName);
            BindBookLocation(AddKept,0,Book);
            AddKept.ExecSQL; AddKept.Reset;
            Continue;
          end;
          AddRemoved.SetParam(0,UpperCase(TPath.GetFullPath(Book.GetBookFileName)));
          BindBookLocation(AddRemoved,1,Book);
          AddRemoved.SetParam(7,KeepID);
          AddRemoved.ExecSQL; AddRemoved.Reset;
          Inc(RemovedDone);
        end;
      Inc(GroupsDone);
      if Assigned(Progress) and ((GroupsDone mod 256=0) or (GroupsDone=GroupsTotal)) then
        Progress(GroupsDone,GroupsTotal);
      Selection.Next;
    end;
    CheckCanceled;
    if (GroupsDone<>GroupsTotal) or (RemovedDone+FSkippedCopies<>RemovedTotal) or
      (Copy(ArchiveDeletionSourceIdentity(FFile),1,25)<>FCatalogueKey) then
      raise EInvalidOperation.Create('Выбор или каталог изменились. Повторите поиск дублей.');
    FStage.Commit;
    for var Reason := High(SkippedGroups) downto Low(SkippedGroups) do
      if SkippedGroups[Reason] > 0 then
        FSkippedDetails := [Format('%d — %s.', [SkippedGroups[Reason], BlockReasons[Reason]])] + FSkippedDetails;
    if Length(FSkippedDetails) > 0 then
      FSkippedDetails := ['Почему некоторые книги пропущены:'] + FSkippedDetails;
  finally
    AddKept.Free; AddRemoved.Free;
    Copies.Free; Selection.Free;
    if BatchQueries then
    begin Current.EndQueryBatch; FStage.EndQueryBatch; FSource.EndQueryBatch; end;
    Personal.Free; Current.Free;
    SQLiteCancelCallback:=Previous; FCanceled:=nil;
    if FStage.InTransaction then FStage.Rollback;
  end;
  FreeAndNil(FSource);
end;

function TBookDuplicatePlan.KeepRecordsWithSkippedFiles(const Books: TArray<TBookRecord>): Integer;
const AffectedGroups = ' WHERE KeepID=(SELECT KeepID FROM DeletionFiles WHERE BookID=?)';
begin
  Result := 0;
  FStage.Start;
  try
    FStage.ExecSQL('CREATE INDEX IF NOT EXISTS DeletionFilesByBook ON DeletionFiles(BookID)');
    FStage.ExecSQL('CREATE INDEX IF NOT EXISTS DeletionFilesByKeep ON DeletionFiles(KeepID)');
    for var Book in Books do
    begin
      var ID := Book.BookKey.BookID;
      Inc(Result, FStage.QuerySingleInt('SELECT COUNT(*) FROM DeletionFiles' + AffectedGroups, [ID]));
      FStage.ExecSQL('DELETE FROM DeletionFiles' + AffectedGroups, [ID]);
    end;
    FStage.Commit;
  finally
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

constructor TUnifiedDuplicateView.Create(Regular,Linked:TBookDuplicatePlan);
begin
  inherited Create;
  if not Assigned(Regular) or not Assigned(Linked) then
    raise EArgumentNilException.Create('Не заданы результаты поиска копий.');
  FRegular:=Regular; FLinked:=Linked;
  FTable:='UnifiedOwners_'+TGUID.NewGuid.ToString.Replace('{','').Replace('}','').Replace('-','');
end;

function TUnifiedDuplicateView.TableName:string;
begin Result:='temp.'+FTable; end;

function TUnifiedDuplicateView.QueryCanceled:Boolean;
begin Result:=Assigned(FCanceled) and FCanceled(); end;

procedure TUnifiedDuplicateView.Build(const Canceled:TMergeCanceled; const Progress:TMergeProgress);
var Owners,FindGroup,Insert:TSQLiteQuery; Previous:TSQLiteCancelCallback;
  Done,FamilyID,BookID:Integer;
begin
  FReady:=False;
  if not FRegular.Ready or FRegular.LinkedMode or not FLinked.Ready or not FLinked.LinkedMode or
    (FRegular.FCID<>FLinked.FCID) or (FRegular.FCatalogueKey<>FLinked.FCatalogueKey) then
    raise EInvalidOperation.Create('Сначала найдите все копии книг в одной коллекции.');
  Previous:=SQLiteCancelCallback; FCanceled:=Canceled; SQLiteCancelCallback:=QueryCanceled;
  try
    FRegular.FStage.ExecSQL('DROP TABLE IF EXISTS '+TableName);
    FRegular.FStage.ExecSQL('CREATE TEMP TABLE '+FTable+'(BookID INTEGER PRIMARY KEY,'+
      'FamilyID INTEGER NOT NULL,ExtraCopies INTEGER NOT NULL,SelectedCopies INTEGER NOT NULL DEFAULT 0)');
    Owners:=FLinked.FStage.NewQuery('SELECT BookID,Count-1 FROM LinkedGroups ORDER BY BookID');
    FindGroup:=nil; Insert:=nil;
    try
      FindGroup:=FRegular.FStage.NewQuery('SELECT g.GroupID FROM Candidates c '+
        'JOIN DuplicateGroups g USING(Identity) WHERE c.BookID=?');
      Insert:=FRegular.FStage.NewQuery('INSERT INTO '+TableName+'(BookID,FamilyID,ExtraCopies) VALUES(?,?,?)');
      FRegular.FStage.Start;
      try
        Done:=0; Owners.Open;
        while not Owners.Eof do
        begin
          if QueryCanceled then Abort;
          BookID:=Owners.FieldAsInt(0); FamilyID:=-BookID;
          FindGroup.SetParam(0,BookID); FindGroup.Open;
          if not FindGroup.Eof then FamilyID:=FindGroup.FieldAsInt(0);
          FindGroup.Reset;
          Insert.SetParam(0,BookID); Insert.SetParam(1,FamilyID); Insert.SetParam(2,Owners.FieldAsInt(1));
          Insert.ExecSQL; Insert.Reset;
          Inc(Done);
          if Assigned(Progress) and (Done mod 4096=0) then Progress(Done,FLinked.GroupCount);
          Owners.Next;
        end;
        FRegular.FStage.Commit;
      finally if FRegular.FStage.InTransaction then FRegular.FStage.Rollback; end;
    finally Insert.Free; FindGroup.Free; Owners.Free; end;
    FRegular.FStage.ExecSQL('CREATE INDEX temp.'+FTable+'_Family ON '+FTable+'(FamilyID)');
    RefreshMarks;
    FReady:=True;
    if Assigned(Progress) then Progress(Done,Done);
  finally SQLiteCancelCallback:=Previous; FCanceled:=nil; end;
end;

procedure TUnifiedDuplicateView.RefreshMarks;
var Rows,Update:TSQLiteQuery;
begin
  Rows:=FLinked.FStage.NewQuery('SELECT BookID,count(*) FROM LinkedCopies WHERE Selected=1 GROUP BY BookID');
  Update:=nil;
  try
    Update:=FRegular.FStage.NewQuery('UPDATE '+TableName+' SET SelectedCopies=? WHERE BookID=?');
    FRegular.FStage.Start;
    try
      FRegular.FStage.ExecSQL('UPDATE '+TableName+' SET SelectedCopies=0 WHERE SelectedCopies<>0');
      Rows.Open;
      while not Rows.Eof do
      begin
        if QueryCanceled then Abort;
        Update.SetParam(0,Rows.FieldAsInt(1)); Update.SetParam(1,Rows.FieldAsInt(0));
        Update.ExecSQL; Update.Reset; Rows.Next;
      end;
      FRegular.FStage.Commit;
    finally if FRegular.FStage.InTransaction then FRegular.FStage.Rollback; end;
  finally Update.Free; Rows.Free; end;
end;

procedure TUnifiedDuplicateView.RefreshFamilyMarks(GroupID:Integer);
var Rows:TSQLiteQuery;
begin
  Rows:=FRegular.FStage.NewQuery('SELECT BookID FROM '+TableName+' WHERE FamilyID=?',[GroupID]);
  try
    Rows.Open;
    while not Rows.Eof do
    begin
      var ID:=Rows.FieldAsInt(0);
      var Count:=FLinked.FStage.QuerySingleInt('SELECT count(*) FROM LinkedCopies WHERE BookID=? AND Selected=1',[ID]);
      FRegular.FStage.ExecSQL('UPDATE '+TableName+' SET SelectedCopies=? WHERE BookID=?',[Count,ID]);
      Rows.Next;
    end;
  finally Rows.Free; end;
end;

procedure TUnifiedDuplicateView.Choose(GroupID,CopyIndex:Integer; Selected:Boolean);
var Copies:TArray<TUnifiedDuplicateCopy>; Keep:TUnifiedDuplicateCopy; Found:Boolean;
begin
  Copies:=Books(GroupID); Found:=False;
  for var I:=0 to High(Copies) do
    if ((CopyIndex<0) and Copies[I].Kept) or (CopyIndex=I) then
    begin Keep:=Copies[I]; Found:=True; Break; end;
  if not Found then raise EArgumentOutOfRangeException.Create('Выберите сохраняемую копию.');
  var KeepID:=Keep.Value.Book.BookKey.BookID;
  FRegular.FStage.Start;
  try
   FLinked.FStage.Start;
   try
    if GroupID>0 then FRegular.Choose(GroupID,KeepID,Selected);
  if Keep.Value.CopyKey<>'' then FLinked.PreferLinkedCopy(KeepID,Keep.Value.CopyKey);
  if GroupID<0 then FLinked.Choose(-GroupID,KeepID,Selected)
  else
    for var Card in FRegular.Books(GroupID) do
      if FRegular.FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM '+TableName+' WHERE BookID=?)',
        [Card.Book.BookKey.BookID])<>0 then
        FLinked.Choose(Card.Book.BookKey.BookID,KeepID,Selected);
    RefreshFamilyMarks(GroupID);
    FLinked.FStage.Commit;
   except FLinked.FStage.Rollback; raise; end;
   FRegular.FStage.Commit;
  except FRegular.FStage.Rollback; raise; end;
end;

function TUnifiedDuplicateView.SelectedCount:Integer;
begin
  if not FReady then Exit(0);
  Result:=FRegular.FStage.QuerySingleInt('SELECT count(*) FROM ('+
    'SELECT GroupID AS ID FROM DuplicateGroups WHERE Selected=1 UNION '+
    'SELECT FamilyID FROM '+TableName+' WHERE SelectedCopies>0)');
end;

function TUnifiedDuplicateView.GroupCount(UnmarkedOnly:Boolean):Integer;
begin
  if not FReady then Exit(0);
  Result:=FRegular.GroupCount+FRegular.FStage.QuerySingleInt('SELECT count(*) FROM '+TableName+' WHERE FamilyID<0');
  if UnmarkedOnly then Dec(Result,SelectedCount);
end;

function TUnifiedDuplicateView.Groups(Offset,Limit:Integer; UnmarkedOnly:Boolean):TArray<TDuplicateGroup>;
var Query:TSQLiteQuery; Values:TList<TDuplicateGroup>; Group:TDuplicateGroup;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала найдите копии книг.');
  if (Offset<0) or (Limit<1) or (Limit>100) then raise EArgumentOutOfRangeException.Create('Страница копий');
  Values:=TList<TDuplicateGroup>.Create;
  try
    Query:=FRegular.FStage.NewQuery('WITH Families AS ('+
      'SELECT g.GroupID AS ID,g.KeepID AS KeepID,0 AS Kind,g.GroupID AS Ordinal,'+
      '(g.Selected=1 OR EXISTS(SELECT 1 FROM '+TableName+' o WHERE o.FamilyID=g.GroupID AND o.SelectedCopies>0)) AS Marked '+
      'FROM DuplicateGroups g UNION ALL '+
      'SELECT FamilyID,BookID,1,BookID,SelectedCopies>0 FROM '+TableName+' WHERE FamilyID<0) '+
      'SELECT ID,KeepID,Marked FROM Families '+IfThen(UnmarkedOnly,'WHERE Marked=0 ','')+
      'ORDER BY Kind,Ordinal LIMIT ? OFFSET ?',[Limit,Offset]);
    try
      Query.Open;
      while not Query.Eof do
      begin
        Group:=Default(TDuplicateGroup); Group.ID:=Query.FieldAsInt(0); Group.KeepID:=Query.FieldAsInt(1);
        Group.Title:=FRegular.FSource.QuerySingleString('SELECT Title FROM Books WHERE BookID=?',[Group.KeepID]);
        Group.Selected:=Query.FieldAsInt(2)<>0;
        var Copies:=Books(Group.ID); Group.Count:=Length(Copies);
        for var Entry in Copies do if Entry.Selected then Inc(Group.SelectedCopies);
        Values.Add(Group); Query.Next;
      end;
    finally Query.Free; end;
    Result:=Values.ToArray;
  finally Values.Free; end;
end;

function TUnifiedDuplicateView.Books(GroupID:Integer):TArray<TUnifiedDuplicateCopy>;
var Values:TList<TUnifiedDuplicateCopy>; Physical:TDictionary<string,Integer>;
  Selected:Boolean; KeepID:Integer;
  procedure Add(const Entry:TDuplicateBook; Kept,Marked:Boolean);
  var Key:string; Index:Integer; Value:TUnifiedDuplicateCopy;
  begin
    Key:=ReaderBookPhysicalIdentity(Entry.Book);
    if Key='' then Key:='unknown:'+IntToStr(Entry.Book.BookKey.BookID)+':'+Entry.CopyKey;
    if Physical.TryGetValue(Key,Index) then
    begin
      Value:=Values[Index]; Value.Origins:=Value.Origins+[Entry];
      Value.Kept:=Value.Kept or Kept;
      Value.Selected:=Value.Selected and Marked and not Value.Kept;
      if Kept then Value.Value:=Entry;
      Values[Index]:=Value;
    end
    else
    begin
      Value:=Default(TUnifiedDuplicateCopy); Value.Value:=Entry; Value.Origins:=[Entry];
      Value.Kept:=Kept; Value.Selected:=Marked and not Kept;
      Physical.Add(Key,Values.Count); Values.Add(Value);
    end;
  end;
begin
  if not FReady then raise EInvalidOperation.Create('Сначала найдите копии книг.');
  Values:=TList<TUnifiedDuplicateCopy>.Create; Physical:=TDictionary<string,Integer>.Create;
  try
    if GroupID<0 then
    begin
      for var Entry in FLinked.Books(-GroupID) do Add(Entry,Entry.CopyKey='',Entry.Selected);
    end
    else
    begin
      KeepID:=FRegular.FStage.QuerySingleInt('SELECT KeepID FROM DuplicateGroups WHERE GroupID=?',[GroupID]);
      Selected:=FRegular.FStage.QuerySingleInt('SELECT Selected FROM DuplicateGroups WHERE GroupID=?',[GroupID])<>0;
      for var Card in FRegular.Books(GroupID) do
      begin
        var Owner:=Card.Book.BookKey.BookID;
        if FRegular.FStage.QuerySingleInt('SELECT EXISTS(SELECT 1 FROM '+TableName+' WHERE BookID=?)',[Owner])<>0 then
          for var Entry in FLinked.Books(Owner) do
            Add(Entry,(Owner=KeepID) and (Entry.CopyKey=''),Entry.Selected or (Selected and (Owner<>KeepID)))
        else Add(Card,Owner=KeepID,Selected and (Owner<>KeepID));
      end;
    end;
    Result:=Values.ToArray;
  finally Physical.Free; Values.Free; end;
end;

end.
