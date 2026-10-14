function ReaderAllCatalogRows(DB: TSQLiteDatabase): string;
var Query: TSQLiteQuery;
begin
  Result:=''; Query:=DB.NewQuery('SELECT name,sql FROM sqlite_master WHERE type=''table'' AND name NOT LIKE ''sqlite_%'' ORDER BY name');
  try
    Query.Open;
    while not Query.Eof do
    begin
      Result:=Result+#1+Query.FieldAsString(0)+#2+Query.FieldAsString(1)+#2+SBRTable(DB,Query.FieldAsString(0));
      Query.Next;
    end;
  finally Query.Free; end;
end;

// Exact independently loaded output oracle for the aliased key/out-record API.
procedure ReaderRequireSameReload(const Expected, Actual: TBookRecord; const Context: string);
begin
  Require(Expected.BookKey.IsSameAs(Actual.BookKey),Context+': book/database identity changed');
  Require((Expected.NodeType=Actual.NodeType) and (Expected.ListOrder=Actual.ListOrder) and
    (Expected.SeriesID=Actual.SeriesID) and (Expected.Series=Actual.Series) and
    (Expected.Title=Actual.Title) and (Expected.CollectionName=Actual.CollectionName) and
    (Expected.CollectionRoot=Actual.CollectionRoot),Context+': title/series/collection metadata changed');
  Require((Expected.FileName=Actual.FileName) and (Expected.FileExt=Actual.FileExt) and
    (Expected.Folder=Actual.Folder) and (Expected.LibID=Actual.LibID) and
    (Expected.InsideNo=Actual.InsideNo) and (Expected.Size=Actual.Size),Context+': physical/copy metadata changed');
  Require((Expected.Lang=Actual.Lang) and (Expected.Date=Actual.Date) and
    (Expected.LibRate=Actual.LibRate) and (Expected.KeyWords=Actual.KeyWords) and
    (Expected.SeqNumber=Actual.SeqNumber) and (Expected.BookProps=Actual.BookProps),Context+': flags/catalogue fields changed');
  Require((Expected.Rate=Actual.Rate) and (Expected.Progress=Actual.Progress) and
    (Expected.Review=Actual.Review) and (Expected.Annotation=Actual.Annotation),Context+': exact personal fields changed');
  Require((Expected.Translators=Actual.Translators) and (Expected.Publisher=Actual.Publisher) and
    (Expected.City=Actual.City) and (Expected.PubYear=Actual.PubYear) and
    (Expected.ISBN=Actual.ISBN) and (Expected.PublisherSeriesKnown=Actual.PublisherSeriesKnown) and
    (Expected.PublisherSeqNumber=Actual.PublisherSeqNumber),Context+': publishing fields changed');
  Require((Expected.RootGenre.GenreCode=Actual.RootGenre.GenreCode) and
    (Expected.RootGenre.ParentCode=Actual.RootGenre.ParentCode) and
    (Expected.RootGenre.FB2GenreCode=Actual.RootGenre.FB2GenreCode) and
    (Expected.RootGenre.GenreAlias=Actual.RootGenre.GenreAlias),Context+': root genre changed');
  Require((Length(Expected.Authors)=Length(Actual.Authors)) and
    (Length(Expected.Genres)=Length(Actual.Genres)) and
    (Length(Expected.PublisherSeries)=Length(Actual.PublisherSeries)),Context+': relations count changed');
  for var I:=0 to High(Expected.Authors) do
    Require((Expected.Authors[I].AuthorID=Actual.Authors[I].AuthorID) and
      (Expected.Authors[I].LastName=Actual.Authors[I].LastName) and
      (Expected.Authors[I].FirstName=Actual.Authors[I].FirstName) and
      (Expected.Authors[I].MiddleName=Actual.Authors[I].MiddleName),Context+': exact author relation changed');
  for var I:=0 to High(Expected.Genres) do
    Require((Expected.Genres[I].GenreCode=Actual.Genres[I].GenreCode) and
      (Expected.Genres[I].ParentCode=Actual.Genres[I].ParentCode) and
      (Expected.Genres[I].FB2GenreCode=Actual.Genres[I].FB2GenreCode) and
      (Expected.Genres[I].GenreAlias=Actual.Genres[I].GenreAlias),Context+': exact genre relation changed');
  for var I:=0 to High(Expected.PublisherSeries) do
    Require((Expected.PublisherSeries[I].SeriesID=Actual.PublisherSeries[I].SeriesID) and
      (Expected.PublisherSeries[I].SeriesTitle=Actual.PublisherSeries[I].SeriesTitle) and
      (Expected.PublisherSeries[I].SeqNumber=Actual.PublisherSeries[I].SeqNumber) and
      (Expected.PublisherSeries[I].IsPrimary=Actual.PublisherSeries[I].IsPrimary),Context+': exact publisher relation changed');
end;

// Real source/system writer boundaries. No live profile or caller transaction
// is changed: every scenario uses this private G-only catalog and user store.
procedure TestReaderAtomicProgress;
var
  User: ISystemData; Collection: IBookCollection;
  Catalog, Personal: TSQLiteDatabase;
  Writer: IBookIdentityPersonalWriter;
  Match: TBookIdentityPredicate;
  Saved, Changed, Foreign: TBookRecord;
  Root, UserFile, CatalogFile, SourceFile, HistoryFile, NotesFile: string;
  SourceHash, HistoryHash, NotesHash, SettingsHash, BeforeSource, BeforePersonal: string;
  BID, CID, GroupID, MatchCalls: Integer;

  function CatalogRows: string;
  begin Result := SBRTable(Catalog,'Books')+#1+SBRTable(Catalog,'Series_List')+#1+
    SBRTable(Catalog,'Author_List')+#1+SBRTable(Catalog,'Genre_List'); end;

  procedure CheckProtected;
  begin
    Require(THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash,'Atomic personal writer changed source book bytes');
    Require(THashSHA2.GetHashStringFromFile(HistoryFile)=HistoryHash,'Atomic personal writer changed reader.ini');
    Require(THashSHA2.GetHashStringFromFile(NotesFile)=NotesHash,'Atomic personal writer changed reader notes');
    if SettingsHash<>'' then Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini')=SettingsHash,
      'Atomic personal writer changed settings/profile bytes');
  end;

  procedure Snapshot;
  begin BeforeSource:=CatalogRows; BeforePersonal:=SBRExact(Personal); end;

  procedure Unchanged(const Reason: string);
  begin
    Require(CatalogRows=BeforeSource,Reason+': source rows changed');
    Require(SBRExact(Personal)=BeforePersonal,Reason+': system cards/groups/raw BLOBs changed');
    Require(not Collection.InBulkOperation,Reason+': writer left a source savepoint/transaction open');
    CheckProtected;
  end;

  procedure ResetMatching(const ID: string=''; const LibraryName: string='');
  begin
    Collection.SetProperty(PROP_SOURCE_LIBRARY,LibraryName);
    Catalog.ExecSQL('UPDATE Books SET LibID=?,Folder='''',FileName=''original'',Ext=''.fb2'',InsideNo=0,'+
      'Rate=4,Progress=37,IsLocal=0,Review=X''2020000AD191D196D19E2020'',Annotation=X''6100FF62'' WHERE BookID=?',[ID,BID]);
    Personal.ExecSQL('UPDATE Books SET LibID=?,Folder='''',FileName=''original'',Ext=''.fb2'',InsideNo=0,'+
      'Rate=4,Progress=37,IsLocal=0,Review=X''2020000AD191D196D19E2020'',Annotation=X''6100FF62'' '+
      'WHERE BookID=? AND DatabaseID=?',[ID,BID,CID]);
    Saved:=Default(TBookRecord); Collection.GetBookRecord(CreateBookKey(BID,CID),Saved,False);
    Saved.CollectionRoot:=IncludeTrailingPathDelimiter(Root);
    Changed:=Saved; Changed.Progress:=73; Changed.Rate:=5;
    Changed.Review:='Exact new thought '+#0+' ё, ї, ў 😀'+sLineBreak+'  final  ';
    Changed.Annotation:='Exact new annotation '+#0+' — ё 😀';
  end;

  procedure ProgressIs(Progress: Integer; const Reason: string);
  begin
    Require(Catalog.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=?',[BID])=Progress,Reason+': source progress');
    Require(Personal.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=Progress,
      Reason+': saved-card progress');
    CheckProtected;
  end;

  procedure RetryAfterFailure(const Reason: string);
  begin
    Require(TryStoreReaderBookProgress(Collection,Saved,73),Reason+': writer did not recover after rollback');
    ProgressIs(73,Reason);
  end;

begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'reader-atomic-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  SourceFile:=TPath.Combine(Root,'original.fb2'); HistoryFile:=TPath.Combine(Root,'reader.ini');
  NotesFile:=TPath.Combine(Root,'reader-notes.json');
  TFile.WriteAllText(SourceFile,'<FictionBook>Protected original — ё, ї, ў 😀</FictionBook>',TEncoding.UTF8);
  TFile.WriteAllText(HistoryFile,'[Book.protected]'+sLineBreak+'Position=9876',TEncoding.UTF8);
  TFile.WriteAllText(NotesFile,'{"protected":"Exact thought — ё, ї, ў 😀"}',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(SourceFile); HistoryHash:=THashSHA2.GetHashStringFromFile(HistoryFile);
  NotesHash:=THashSHA2.GetHashStringFromFile(NotesFile); SettingsHash:='';
  if FileExists(Settings.AppPath+'myhomelib2.ini') then SettingsHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini');
  UserFile:=TPath.Combine(Root,'user.dbs2'); TSystemData_SQLite.CreateSystemTables(UserFile);
  User:=TSystemData_SQLite.Create(UserFile); Catalog:=nil; Personal:=nil;
  try
    CID:=User.CreateCollection('Atomic reader identity',Root,TPath.Combine(Root,'catalog.hlc2'),
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection:=User.GetCollection(CID); CatalogFile:=User.GetCollectionInfo(CID).DBFileName;
    Catalog:=TSQLiteDatabase.Create(CatalogFile); Personal:=TSQLiteDatabase.Create(UserFile);
    // Direct fixture connections (including the WAL contender below) must
    // honor the real DAO trigger contracts, rather than deleting triggers.
    Catalog.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Catalog.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Personal.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Personal.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Require(Catalog.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE type=''trigger''')>0,
      'Atomic fixture catalog has no production triggers');
    BID:=AddBook(Collection,'Original A','Автор ё і ў','ru','','prose_contemporary');
    Collection.GetBookRecord(CreateBookKey(BID,CID),Saved,True);
    User.AddGroup('Atomic reader group'); GroupID:=Personal.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=''Atomic reader group''');
    User.AddBookToGroup(Saved.BookKey,GroupID,Saved);
    User.AddGroup('Atomic second membership');
    User.AddBookToGroup(Saved.BookKey,Personal.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=''Atomic second membership'''),Saved);
    Personal.ExecSQL('UPDATE Books SET ExtraInfo=CAST(ExtraInfo||X''00FF'' AS BLOB) WHERE BookID=? AND DatabaseID=?',[BID,CID]);
    Require(Supports(Collection,IBookIdentityPersonalWriter,Writer),'Atomic source personal writer unavailable');
    Match:=function(const Current: TBookRecord): Boolean
      begin
        Result:=Current.BookKey.IsSameAs(Saved.BookKey) and
          ReaderBookMatchesExpectedIdentity(Saved.LibID,ReaderBookPhysicalIdentity(Saved),Current,
            VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)));
      end;

    // The natural in-place reload must retain its key before clearing Book.
    // Compare every output field with an independently keyed read; neither
    // read is permitted to modify catalogue rows or saved raw cards/groups.
    ResetMatching('flibusta:77','flibusta');
    Catalog.ExecSQL('UPDATE Books SET LibRate=4,IsDeleted=1,BookSize=3109,InsideNo=7,'+
      'KeyWords=?,Translators=?,Publisher=?,City=?,PubYear=1987,ISBN=?,Review=CAST(? AS BLOB),Annotation=? WHERE BookID=?',
      ['Alias keywords ё','Translator ї','Publisher ў','City 😀','978-0-1234',
      '  Exact aliased review '+#0+' ё, ї, ў 😀'+sLineBreak+'  final  ',
      '  Exact aliased annotation '+#0+' ё 😀  ',BID]);
    Collection.AddBookSeries(BID,'Alias secondary cycle',7);
    var AliasPublisher:TBookSeries;
    TSeriesHelper.Add(AliasPublisher,0,'Alias publisher series',9,False);
    Collection.SetBookPublisherSeries(CreateBookKey(BID,CID),AliasPublisher);
    Snapshot; var AliasCatalogRows:=ReaderAllCatalogRows(Catalog);
    for var LoadMemos in TArray<Boolean>.Create(False,True) do
    begin
      var ExpectedReload:=Default(TBookRecord); var AliasedReload:=Default(TBookRecord);
      Collection.GetBookRecord(CreateBookKey(BID,CID),ExpectedReload,LoadMemos);
      AliasedReload:=ExpectedReload;
      Collection.GetBookRecord(AliasedReload.BookKey,AliasedReload,LoadMemos);
      ReaderRequireSameReload(ExpectedReload,AliasedReload,'Aliased catalogue reload '+BoolToStr(LoadMemos,True));
      Unchanged('Aliased catalogue reload');
      Require(ReaderAllCatalogRows(Catalog)=AliasCatalogRows,'Aliased catalogue reload changed any table/schema metadata');
    end;
    // The same snapshot also protects the foreign-CID saved-card fallback.
    // System reload replaces the two complete stored relation lists. It
    // preserves metadata this var API does not store; compare to a fresh
    // independent key read, never to the previously populated record itself.
    // The earlier atomic cases intentionally keep malformed UTF8 annotation
    // bytes. A typed string getter must not be asked to decode those bytes;
    // use a separate valid memo card and leave that raw corruption gate intact.
    var CorruptCardRows:=SBRTable(Personal,'Books',False,False,
      ' WHERE BookID='+IntToStr(BID)+' AND DatabaseID='+IntToStr(CID));
    Require(Personal.QuerySingleString('SELECT hex(Annotation) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])='6100FF62',
      'System reload setup lost the earlier malformed raw annotation preservation case');
    var RepeatKey:=CreateBookKey(BID+5000,CID);
    var RepeatCard:=Default(TBookRecord);
    Collection.GetBookRecord(CreateBookKey(BID,CID),RepeatCard,True);
    RepeatCard.BookKey:=RepeatKey;
    RepeatCard.Review:='  Stored repeat-read review '+#0+' ё, ї, ў 😀'+sLineBreak+'  keep exact  ';
    RepeatCard.Annotation:='  Stored repeat-read annotation '+#0+' ё, ї, ў 😀  ';
    User.AddBookToGroup(RepeatKey,GroupID,RepeatCard);
    Personal.ExecSQL('UPDATE Books SET Review=CAST(? AS BLOB),Annotation=CAST(? AS BLOB),'+
      'ExtraInfo=CAST(ExtraInfo||X''00FF'' AS BLOB) WHERE BookID=? AND DatabaseID=?',
      [RepeatCard.Review,RepeatCard.Annotation,RepeatKey.BookID,RepeatKey.DatabaseID]);
    var FreshSystem:=Default(TBookRecord);
    User.GetBookRecord(RepeatKey,FreshSystem);
    Require((FreshSystem.Review=RepeatCard.Review) and (FreshSystem.Annotation=RepeatCard.Annotation),
      'Fresh system reload changed valid UTF8 memo BLOBs, NUL, Unicode or whitespace');
    Require((Length(FreshSystem.Authors)=1) and (Length(FreshSystem.Genres)=1),
      'System repeat-read fixture lacks its exact single stored author/genre');
    var PopulatedSystem:=Default(TBookRecord);
    Collection.GetBookRecord(CreateBookKey(BID,CID),PopulatedSystem,True);
    PopulatedSystem.BookKey:=RepeatKey;
    PopulatedSystem.ListOrder:=987;
    PopulatedSystem.RootGenre.GenreCode:='preserved-root'; PopulatedSystem.RootGenre.ParentCode:='preserved-parent';
    PopulatedSystem.RootGenre.FB2GenreCode:='preserved-root-fb2'; PopulatedSystem.RootGenre.GenreAlias:='Preserved root ё';
    PopulatedSystem.Translators:='Preserved translator ї'; PopulatedSystem.Publisher:='Preserved publisher ў';
    PopulatedSystem.City:='Preserved city 😀'; PopulatedSystem.PubYear:=1999; PopulatedSystem.ISBN:='preserved-isbn';
    PopulatedSystem.PublisherSeries:=nil;
    TSeriesHelper.Add(PopulatedSystem.PublisherSeries,731,'Preserved publisher primary ё',5,True);
    TSeriesHelper.Add(PopulatedSystem.PublisherSeries,732,'Preserved publisher secondary ї',6,False);
    PopulatedSystem.PublisherSeriesKnown:=True; PopulatedSystem.PublisherSeqNumber:=8;
    TAuthorsHelper.Add(PopulatedSystem.Authors,'Unrelated previous','Author','',909);
    TGenresHelper.Add(PopulatedSystem.Genres,'previous-genre','Unrelated previous genre','previous-fb2');
    var ExpectedSystem:=FreshSystem;
    ExpectedSystem.ListOrder:=PopulatedSystem.ListOrder; ExpectedSystem.RootGenre:=PopulatedSystem.RootGenre;
    ExpectedSystem.Translators:=PopulatedSystem.Translators; ExpectedSystem.Publisher:=PopulatedSystem.Publisher;
    ExpectedSystem.City:=PopulatedSystem.City; ExpectedSystem.PubYear:=PopulatedSystem.PubYear;
    ExpectedSystem.ISBN:=PopulatedSystem.ISBN; ExpectedSystem.PublisherSeries:=PopulatedSystem.PublisherSeries;
    ExpectedSystem.PublisherSeriesKnown:=PopulatedSystem.PublisherSeriesKnown;
    ExpectedSystem.PublisherSeqNumber:=PopulatedSystem.PublisherSeqNumber;
    Snapshot; AliasCatalogRows:=ReaderAllCatalogRows(Catalog);
    var SystemRows:=ReaderAllCatalogRows(Personal); var SystemSchema:=SBRTable(Personal,'sqlite_master');
    for var ReloadIndex:=1 to 3 do
    begin
      // Aliased const key/var record is a natural repeated reload call.
      User.GetBookRecord(PopulatedSystem.BookKey,PopulatedSystem);
      ReaderRequireSameReload(ExpectedSystem,PopulatedSystem,'Populated aliased system reload '+IntToStr(ReloadIndex));
      var IndependentSystem:=Default(TBookRecord);
      User.GetBookRecord(RepeatKey,IndependentSystem);
      ReaderRequireSameReload(FreshSystem,IndependentSystem,'Independent fresh system reload '+IntToStr(ReloadIndex));
      Unchanged('Repeated system getter');
      Require((ReaderAllCatalogRows(Catalog)=AliasCatalogRows) and
        (ReaderAllCatalogRows(Personal)=SystemRows) and (SBRTable(Personal,'sqlite_master')=SystemSchema),
        'System repeat-read changed any catalogue/system table, raw BLOB or schema');
    end;
    Require(SBRTable(Personal,'Books',False,False,
      ' WHERE BookID='+IntToStr(BID)+' AND DatabaseID='+IntToStr(CID))=CorruptCardRows,
      'Typed repeat-read fixture changed the independent malformed raw BLOB preservation card');
    Writeln('PASS system fresh/populated/aliased repeated reload replaces stored authors/genres, preserves every nonstored metadata field and exact DB/raw BLOB/schema snapshots');

    var AliasOtherCID:=User.CreateCollection('Alias foreign fallback',Root,TPath.Combine(Root,'alias-other.hlc2'),
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    var AliasOther:=User.GetCollection(AliasOtherCID);
    var AliasOtherBID:=AddBook(AliasOther,'Other alias source','Other author ё','uk','','prose_contemporary');
    var OtherRecord:=Default(TBookRecord);
    AliasOther.GetBookRecord(CreateBookKey(AliasOtherBID,AliasOtherCID),OtherRecord,True);
    OtherRecord.Rate:=3; OtherRecord.Progress:=64; OtherRecord.Review:='Other exact thought '+#0+' ї';
    OtherRecord.Annotation:='Other annotation ў'; AliasOther.UpdateBook(OtherRecord);
    AliasOther.AddBookToGroup(CreateBookKey(AliasOtherBID,AliasOtherCID),GroupID);
    var OtherCatalog:=TSQLiteDatabase.Create(User.GetCollectionInfo(AliasOtherCID).DBFileName);
    try
      var OtherRows:=ReaderAllCatalogRows(OtherCatalog); Snapshot; AliasCatalogRows:=ReaderAllCatalogRows(Catalog);
      var ExpectedOther:=Default(TBookRecord);
      Collection.GetBookRecord(CreateBookKey(AliasOtherBID,AliasOtherCID),ExpectedOther,True);
      OtherRecord:=ExpectedOther;
      Collection.GetBookRecord(OtherRecord.BookKey,OtherRecord,True);
      ReaderRequireSameReload(ExpectedOther,OtherRecord,'Aliased saved foreign-CID reload');
      Unchanged('Aliased saved foreign-CID reload');
      Require((ReaderAllCatalogRows(OtherCatalog)=OtherRows) and (ReaderAllCatalogRows(Catalog)=AliasCatalogRows),
        'Aliased foreign fallback changed either catalogue tables/schema');
    finally OtherCatalog.Free; AliasOther:=nil; end;
    Writeln('PASS aliased record-key reload preserves every field, memos, publishing relations and foreign-CID saved-card fallback without writes');

    for var Placeholder in TArray<string>.Create('','0','42') do
    begin
      ResetMatching(Placeholder,''); Snapshot;
      Require(ReaderBookMatchesCatalog(Collection,Saved),'Exact physical original was rejected');
      Catalog.ExecSQL('UPDATE Books SET FileName=''foreign'',Progress=7,Rate=2 WHERE BookID=?',[BID]); Snapshot;
      Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Late reused-ID reader callback wrote foreign catalog book');
      Unchanged('Late replacement '+Placeholder);
      // The actual Main callback may store the proven original personal card;
      // this source-only scalar helper must never claim foreign-source success.
      Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfProgress])=rpwPersonal,
        'Late replacement did not explicitly preserve matching personal progress');
      Require(Catalog.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=?',[BID])=7,'Personal fallback changed foreign source progress');
      Require(Personal.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=73,
        'Personal fallback did not preserve the original progress'); CheckProtected;
    end;
    Writeln('PASS late empty/zero/unscoped numeric ID reuse rejects source writes and preserves proven personal progress');

    ResetMatching; var RawReview:=Catalog.QuerySingleString('SELECT hex(Review) FROM Books WHERE BookID=?',[BID]);
    var RawExtra:=Personal.QuerySingleString('SELECT hex(ExtraInfo) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID]);
    var Groups:=SBRGroups(Personal);
    Require(TryStoreReaderBookProgress(Collection,Saved,73),'Matching physical source progress was rejected'); ProgressIs(73,'Physical identity');
    Require(Catalog.QuerySingleString('SELECT hex(Review) FROM Books WHERE BookID=?',[BID])=RawReview,'Progress write normalized source raw review BLOB');
    Require(Personal.QuerySingleString('SELECT hex(Review) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=RawReview,
      'Progress write normalized saved raw review BLOB');
    Require((Personal.QuerySingleString('SELECT hex(ExtraInfo) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=RawExtra) and
      (SBRGroups(Personal)=Groups),'Progress write changed opaque personal data/group membership');
    ResetMatching('flibusta:42','librusec'); Catalog.ExecSQL('UPDATE Books SET FileName=''moved-original'' WHERE BookID=?',[BID]);
    Require(TryStoreReaderBookProgress(Collection,Saved,73),'Known stable preferred origin lost availability after a physical move');
    ProgressIs(73,'Stable identity');
    ResetMatching; var LocalBook:=Saved; Include(LocalBook.BookProps,bpIsLocal);
    Require(Writer.TrySetIdentityPersonal(LocalBook,[bpfIsLocal],Match,True)=biwSaved,'Matching guarded local flag rejected');
    Require((Catalog.QuerySingleInt('SELECT IsLocal FROM Books WHERE BookID=?',[BID])=1) and
      (Personal.QuerySingleInt('SELECT IsLocal FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=1),
      'Matching local flag did not synchronize the proven source and saved card');
    Writeln('PASS exact physical and validated stable-origin progress preserve all unrelated raw personal BLOBs and groups');

    ResetMatching; Snapshot; Collection.BeginBulkOperation;
    try
      Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Writer committed progress inside caller source transaction');
      Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview])=rpwRejected,
        'Reader personal fallback escaped an uncommitted source batch');
      Require(Collection.InBulkOperation,'Writer ended caller source transaction');
      Require(SBRExact(Personal)=BeforePersonal,'Outer source transaction changed durable personal card');
    finally Collection.EndBulkOperation(False); end;
    Unchanged('Caller source transaction');
    ResetMatching; Snapshot; User.BeginDataUpdate;
    try
      Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Source committed while saved-card transaction was pending');
      Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview,bpfAnnotation])=rpwRejected,
        'Memo sync failure escaped pending personal transaction');
    finally User.EndDataUpdate(False); end;
    Unchanged('Caller personal transaction');
    Writeln('PASS caller source/system batches retain transaction ownership and prevent partial durable personal synchronization');

    for var StoreName in TArray<string>.Create('source','personal') do
      for var RaiseMode in TArray<string>.Create('ABORT','IGNORE','ROLLBACK') do
      begin
        ResetMatching; Snapshot;
        var FaultDB:=Catalog; if StoreName='personal' then FaultDB:=Personal;
        var RaiseSQL:='RAISE('+RaiseMode; if RaiseMode<>'IGNORE' then RaiseSQL:=RaiseSQL+',''injected identity writer failure''';
        RaiseSQL:=RaiseSQL+')';
        FaultDB.ExecSQL('CREATE TRIGGER identity_fail BEFORE UPDATE OF Progress,Review,Annotation,IsLocal ON Books BEGIN SELECT '+RaiseSQL+'; END');
        try
          Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Guarded progress ignored '+StoreName+' '+RaiseMode);
          Unchanged('Progress '+StoreName+' '+RaiseMode);
          Require(Writer.TrySetIdentityPersonal(Changed,[bpfReview,bpfAnnotation],Match,True)<>biwSaved,
            'Source writer accepted '+StoreName+' '+RaiseMode+' memo failure');
          Unchanged('Memo writer '+StoreName+' '+RaiseMode);
          var LocalFailureBook:=Saved; Include(LocalFailureBook.BookProps,bpIsLocal);
          Require(Writer.TrySetIdentityPersonal(LocalFailureBook,[bpfIsLocal],Match,True)<>biwSaved,
            'Local-bit writer accepted '+StoreName+' '+RaiseMode+' failure');
          Unchanged('Local writer '+StoreName+' '+RaiseMode);
          if StoreName='personal' then
          begin
            Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview,bpfAnnotation])=rpwRejected,
              'Review accepted a failed required matching saved card');
            Unchanged('Memo helper '+StoreName+' '+RaiseMode);
          end
          else
          begin
            // A proven durable personal-only outcome is explicitly allowed.
            Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview,bpfAnnotation])=rpwPersonal,
              'Source failure was not reported as a durable personal-only outcome');
            Require(CatalogRows=BeforeSource,'Personal-only memo fallback changed rejected source rows');
            Require((User.GetReview(Saved.BookKey)=Changed.Review) and
              (User.GetAnnotation(Saved.BookKey)=Changed.Annotation),'Personal-only fallback lost exact submitted text');
            CheckProtected;
          end;
        finally FaultDB.ExecSQL('DROP TRIGGER identity_fail'); end;
        RetryAfterFailure(StoreName+' '+RaiseMode);
      end;
    Writeln('PASS source/system ABORT, IGNORE and ROLLBACK triggers reject progress/memo writes and recover without lost source/user BLOBs');

    ResetMatching; Snapshot; Personal.Start;
    try
      Personal.ExecSQL('UPDATE Books SET Progress=Progress WHERE BookID=? AND DatabaseID=?',[BID,CID]);
      Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Locked matching personal store committed source progress');
      Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview,bpfAnnotation])=rpwRejected,
        'Locked matching personal store lost new review by claiming success');
      Require(Personal.InTransaction,'Guarded writer ended the external lock owner transaction');
    finally Personal.Rollback; end;
    Unchanged('External personal write lock'); RetryAfterFailure('External personal write lock');
    ResetMatching; Personal.ExecSQL('UPDATE Books SET FileName=''foreign'',Progress=7 WHERE BookID=? AND DatabaseID=?',[BID,CID]); Snapshot;
    Require(not TryStoreReaderBookProgress(Collection,Saved,73),'Source writer overwrote a stale foreign personal card');
    Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfReview,bpfAnnotation])=rpwRejected,
      'Source saved a new review without its required matching group card');
    Unchanged('Stale saved system card');
    Writeln('PASS locked/stale saved cards roll back catalog updates and do not overwrite another book or lose required group synchronization');

    ResetMatching; Personal.ExecSQL('UPDATE Books SET BookID=-17 WHERE BookID=? AND DatabaseID=?',[BID,CID]);
    Personal.ExecSQL('UPDATE BookGroups SET BookID=-17 WHERE BookID=? AND DatabaseID=?',[BID,CID]);
    Changed.BookKey.BookID:=-17; Changed.Progress:=81; BeforeSource:=CatalogRows;
    Require(TryStoreReaderBookPersonal(Collection,User,Changed,[bpfProgress])=rpwPersonal,
      'Quarantined matching negative personal card became unwritable');
    Require((CatalogRows=BeforeSource) and
      (Personal.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=-17 AND DatabaseID=?',[CID])=81),
      'Negative personal progress touched source or wrong saved card');
    Personal.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=-17 AND DatabaseID=?',[BID,CID]);
    Personal.ExecSQL('UPDATE BookGroups SET BookID=? WHERE BookID=-17 AND DatabaseID=?',[BID,CID]); CheckProtected;

    ResetMatching; var OldBID:=BID; BID:=High(Integer)-1;
    Catalog.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=?',[BID,OldBID]);
    Personal.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=? AND DatabaseID=?',[BID,OldBID,CID]);
    Personal.ExecSQL('UPDATE BookGroups SET BookID=? WHERE BookID=? AND DatabaseID=?',[BID,OldBID,CID]);
    Saved.BookKey.BookID:=BID;
    Require(TryStoreReaderBookProgress(Collection,Saved,73),'Valid large positive BookID was truncated/rejected'); ProgressIs(73,'Large positive ID');
    Catalog.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=?',[OldBID,BID]);
    Personal.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=? AND DatabaseID=?',[OldBID,BID,CID]);
    Personal.ExecSQL('UPDATE BookGroups SET BookID=? WHERE BookID=? AND DatabaseID=?',[OldBID,BID,CID]); BID:=OldBID;
    Writeln('PASS quarantined negative personal cards and large valid positive BookIDs preserve exact book identity');
    var OrdinaryID:=AddBook(Collection,'Ordinary without personal card','Автор ё','ru','','');
    var Ordinary:=Default(TBookRecord); Collection.GetBookRecord(CreateBookKey(OrdinaryID,CID),Ordinary,False);
    Require(TryStoreReaderBookProgress(Collection,Ordinary,61),'Ordinary source book without a saved personal card became unwritable');
    Require(Catalog.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=?',[OrdinaryID])=61,
      'Ordinary source progress did not commit');
    Require(Personal.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID=? AND DatabaseID=?',[OrdinaryID,CID])=0,
      'Guarded writer created an unrelated personal card');
    Ordinary.Progress:=82; Snapshot;
    Require(Writer.TrySetIdentityPersonal(Ordinary,[bpfProgress],
      function(const Current: TBookRecord): Boolean
      begin Result:=Current.BookKey.IsSameAs(Ordinary.BookKey) and
        ReaderBookMatchesExpectedIdentity(Ordinary.LibID,ReaderBookPhysicalIdentity(Ordinary),Current,''); end,True)<>biwSaved,
      'Required absent personal card was silently accepted');
    Unchanged('Required absent personal card');
    Writeln('PASS ordinary source books remain available while required missing personal cards reject partial saves');

    ResetMatching; Require(SameText(Catalog.QuerySingleString('PRAGMA journal_mode=WAL'),'wal'),'Could not enable isolated WAL race fixture');
    Snapshot; MatchCalls:=0;
    Require(Writer.TrySetIdentityPersonal(Changed,[bpfProgress],
      function(const Current: TBookRecord): Boolean
      begin
        Inc(MatchCalls);
        if MatchCalls=1 then
        begin
          // A separate committed writer replaces the row after identity read,
          // before the guarded UPDATE. SQLite must reject this old snapshot.
          Catalog.ExecSQL('UPDATE Books SET FileName=''foreign-after-read'',Progress=7 WHERE BookID=?',[BID]);
          BeforeSource:=SBRTable(Catalog,'Books')+#1+SBRTable(Catalog,'Series_List')+#1+
            SBRTable(Catalog,'Author_List')+#1+SBRTable(Catalog,'Genre_List');
        end;
        Result:=Current.BookKey.IsSameAs(Saved.BookKey) and
          ReaderBookMatchesExpectedIdentity(Saved.LibID,ReaderBookPhysicalIdentity(Saved),Current,
            VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY)));
      end,True)<>biwSaved,'Concurrent WAL replacement wrote progress to the new book');
    Require(MatchCalls=1,'WAL race did not reach the original identity snapshot exactly once');
    Unchanged('WAL snapshot replacement');
    Require(Catalog.QuerySingleInt('SELECT Progress FROM Books WHERE BookID=?',[BID])=7,'WAL replacement received original progress');
    Writeln('PASS concurrent catalog commit after identity read is rejected without foreign progress or saved-card writes');
    Require(Catalog.QuerySingleString('PRAGMA integrity_check')='ok','Atomic fixture source integrity failed');
    Require(Personal.QuerySingleString('PRAGMA integrity_check')='ok','Atomic fixture user integrity failed'); CheckProtected;
  finally
    Match:=nil; Writer:=nil;
    if Assigned(Collection) and Collection.InBulkOperation then Collection.EndBulkOperation(False);
    if Assigned(User) then User.ClearCollectionCache;
    Collection:=nil; User:=nil; Catalog.Free; Personal.Free;
  end;
  Writeln('PASS atomic reader progress/local/personal guards use private native catalogs and retain protected books, history, notes and settings');
  Flush(Output);
end;

// Adversarial reader fallback; actual DAO copies, isolated native G: profile.
// Existing uses suffice: unit_ReaderCache, SQLiteWrap, unit_Globals.
procedure TestReaderCopyIdentity;
var Collection: IBookCollection; CID, BID: Integer;
  Saved, Current, CopyBook, Resolved: TBookRecord;
  Root, ForeignFile, SameFile, CatalogFile, BeforeCatalog, ForeignHash, SameHash: string;

  function RawPath(const Book: TBookRecord): string;
  begin Result := Book.GetBookFileName; end;

  procedure Setup(const SavedID, CurrentID, CopyID, LibraryName: string;
    SamePrimary: Boolean = False);
  begin
    Collection.SetProperty(PROP_SOURCE_LIBRARY, LibraryName);
    Collection.GetBookRecord(CreateBookKey(BID, CID), Current, False);
    Current.LibID := CurrentID; Current.CollectionRoot := Root; Current.Folder := '';
    Current.FileName := 'current-missing'; Current.FileExt := '.fb2'; Current.Size := 100;
    if SamePrimary then Current.FileName := 'saved-missing';
    Collection.UpdateBook(Current);
    Saved := Current; Saved.LibID := SavedID; Saved.FileName := 'saved-missing';
    Saved.Title := 'Saved book title'; Saved.Rate := 4; Saved.Progress := 37;
    Saved.Review := 'Preserve my thought — ё, ї, ў 😀';
    CopyBook := Current; CopyBook.LibID := CopyID; CopyBook.FileName := 'foreign-existing';
    CopyBook.CollectionRoot := Root; CopyBook.Folder := ''; CopyBook.InsideNo := 7;
    Collection.SetCatalogBookCopy('reader-proof:copy', 'Verified copy binding', CopyBook);
    BeforeCatalog := THashSHA2.GetHashStringFromFile(CatalogFile);
  end;

  procedure CheckNoMutation;
  begin
    Require(THashSHA2.GetHashStringFromFile(CatalogFile) = BeforeCatalog,
      'Reader identity resolution changed catalog bytes');
    Require((THashSHA2.GetHashStringFromFile(ForeignFile) = ForeignHash) and
      (THashSHA2.GetHashStringFromFile(SameFile) = SameHash),
      'Reader identity resolution changed source book bytes');
    Require(Resolved.BookKey.IsSameAs(Saved.BookKey) and (Resolved.LibID = Saved.LibID) and
      (Resolved.Title = Saved.Title) and (Resolved.Rate = Saved.Rate) and
      (Resolved.Progress = Saved.Progress) and (Resolved.Review = Saved.Review),
      'Fallback rewrote the saved book/history identity or personal metadata');
  end;

  procedure Reject(const Reason: string);
  begin
    Require(not FileExists(Saved.GetBookFileName) and FileExists(CopyBook.GetBookFileName),
      'Rejected reader fallback fixture has no missing original/existing alternate');
    Resolved := ResolveReaderBook(Collection, Saved);
    Require((RawPath(Resolved) = RawPath(Saved)) and (Resolved.FileName = Saved.FileName), Reason);
    CheckNoMutation;
  end;

  procedure Accept(const Reason: string);
  begin
    Resolved := ResolveReaderBook(Collection, Saved);
    Require((RawPath(Resolved) = ForeignFile) and (Resolved.InsideNo = CopyBook.InsideNo), Reason);
    CheckNoMutation;
  end;

  procedure ProveLegacyWrongChoice;
  var Copies: TArray<TBookRecord>; Picked: string;
  begin
    // This is the prior algorithm, using real linked-copy rows. It never opens
    // the book; the adversarial alternate is a private fixture file.
    Copies := Collection.GetCatalogBookCopies(Saved.BookKey); Picked := '';
    for var Item in Copies do
      if FileExists(Item.GetBookFileName) then begin Picked := Item.GetBookFileName; Break; end;
    Require(Picked = ForeignFile, 'Reused-ID fixture did not reproduce the old unproven fallback');
  end;

begin
  RequireIsolatedRegression;
  Root := IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath, 'reader-copy-identity'));
  ForceDirectories(Root);
  CID := SystemDB.CreateCollection('Reader identity oracle', Root, 'reader-identity.hlc2',
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  BID := AddBook(Collection, 'Current primary book', 'Identity author', 'ru', '', 'prose_contemporary');
  CatalogFile := SystemDB.GetCollectionInfo(CID).DBFileName;
  ForeignFile := TPath.Combine(Root, 'foreign-existing.fb2'); SameFile := TPath.Combine(Root, 'same-existing.fb2');
  TFile.WriteAllText(ForeignFile, '<FictionBook>Alternate private fixture ё</FictionBook>', TEncoding.UTF8);
  TFile.WriteAllText(SameFile, '<FictionBook>Original private fixture ї</FictionBook>', TEncoding.UTF8);
  ForeignHash := THashSHA2.GetHashStringFromFile(ForeignFile); SameHash := THashSHA2.GetHashStringFromFile(SameFile);

  Setup('', '9002', '9002', 'flibusta'); ProveLegacyWrongChoice;
  Reject('Empty saved LibID opened an unrelated book under its reused positive ID');
  Setup('0', '9002', '9002', 'flibusta');
  Reject('Zero saved LibID opened another book after row reuse');
  Setup('flibusta:0', 'flibusta:9002', 'flibusta:9002', '');
  Reject('Scoped zero qualified as reader identity');
  Setup('merged:old:0', 'merged:new:9002', '9002', '');
  Reject('Merged placeholder qualified as reader identity');
  Setup('', '', '', '', True);
  Reject('Matching current physical metadata authorized an unknown different alternate');
  Setup('41', '42', '41', 'flibusta');
  Reject('Saved known ID mismatch reused current copy links');
  Setup('42', '42', '43', 'flibusta');
  Reject('Wrong copy LibID was accepted for a valid current book');
  Setup('flibusta:42', 'librusec:42', 'flibusta:42', '');
  Reject('Equal numeric IDs crossed known current library origins');
  Setup('flibusta:42', 'flibusta:42', 'librusec:42', '');
  Reject('Equal numeric copy IDs crossed known library origins');
  Setup('42', '42', 'flibusta:42', '');
  Reject('Unknown raw origin was guessed from a scoped alternate');
  Setup('42', '42', '42', '');
  Reject('Unknown raw numeric IDs authorized a different physical copy after row reuse');
  Setup('42', '42', '42', 'mixed');
  Reject('Mixed default library gave unrelated raw numeric IDs a global identity');
  Setup('merged:old:42', 'merged:new:42', '42', '');
  Reject('Merged wrappers gave unscoped numeric IDs a global identity');
  Setup('flibusta:', 'flibusta:', 'flibusta:', '');
  Reject('Reserved empty Flibusta ID became an opaque reader identity');
  Setup('librusec:', 'librusec:', 'librusec:', '');
  Reject('Reserved empty Librusec ID became an opaque reader identity');
  Setup('merged:old:flibusta:', 'merged:new:flibusta:', 'flibusta:', '');
  Reject('Merged reserved empty ID became an opaque reader identity');
  Setup('flibusta: 0', 'flibusta: 0', 'flibusta: 0', '');
  Reject('Whitespace around a reserved zero ID authorized reader fallback');
  Writeln('PASS reused positive IDs, placeholders and conflicting library/copy identities keep the missing original without guessing another book');

  Setup('42', '42', '42', 'flibusta'); Accept('Known matching reader copy was rejected');
  Setup('opaque-uuid-42', 'opaque-uuid-42', 'opaque-uuid-42', '');
  Accept('Known opaque stable reader ID was rejected');
  Setup('local:opaque-uuid-42', 'local:opaque-uuid-42', 'local:opaque-uuid-42', '');
  Accept('Meaningful local opaque ID was mistaken for a source-library ID');
  Setup('urn:uuid:1c68290f-bb67-4d52-a195-69901aadfcd8',
    'urn:uuid:1c68290f-bb67-4d52-a195-69901aadfcd8',
    'urn:uuid:1c68290f-bb67-4d52-a195-69901aadfcd8', 'mixed');
  Accept('Opaque UUID history identity became unavailable under a mixed library');
  Setup('merged:old:flibusta:42', 'merged:new:flibusta:42', '42', '');
  Accept('Verified merged raw copy lost the preferred explicit library provenance');
  Setup('merged:old:flibusta:42', 'merged:new:flibusta:42', '42', 'librusec');
  Accept('Mixed target namespace overrode the explicit preferred/saved copy provenance');
  Setup('merged:old:flibusta:42', 'merged:new:flibusta:42', 'librusec:42', 'librusec');
  Reject('Mixed target namespace accepted an explicitly conflicting copy origin');
  Setup('42', 'merged:current:flibusta:42', '42', 'flibusta');
  Accept('Collection library provenance failed to bridge valid scoped/current raw IDs');
  Writeln('PASS matching stable and merged verified copies preserve original title, key, notes, rating and progress');

  Setup('', '', '', '', True);
  Saved.FileName := 'same-existing'; Current.FileName := 'same-existing';
  Collection.UpdateBook(Current); BeforeCatalog := THashSHA2.GetHashStringFromFile(CatalogFile);
  Resolved := ResolveReaderBook(Collection, Saved);
  Require(RawPath(Resolved) = SameFile, 'Existing exact physical original was not retained'); CheckNoMutation;
  Setup('42', '42', '42', ''); Saved.FileName := 'same-existing';
  Resolved := ResolveReaderBook(Collection, Saved);
  Require(RawPath(Resolved) = SameFile,
    'Unscoped ordinary numeric ID prevented opening its exact existing original'); CheckNoMutation;

  Setup('', '', '', '', True);
  Saved.Folder := 'missing-original.zip'; Saved.FileName := 'wanted';
  Current.Folder := Saved.Folder; Current.FileName := 'other-member'; Collection.UpdateBook(Current);
  CopyBook.Folder := 'alternate-existing.zip'; CopyBook.FileName := 'other-member'; CopyBook.LibID := '';
  var ArchivePath := TPath.Combine(Root, CopyBook.Folder);
  TFile.WriteAllText(ArchivePath, 'Private fixture container; never decompressed', TEncoding.UTF8);
  var ArchiveHash := THashSHA2.GetHashStringFromFile(ArchivePath);
  Collection.SetCatalogBookCopy('reader-proof:copy', 'Unproven member', CopyBook);
  BeforeCatalog := THashSHA2.GetHashStringFromFile(CatalogFile);
  Reject('Unknown archive/member metadata opened a different archive/member');
  Require(THashSHA2.GetHashStringFromFile(ArchivePath) = ArchiveHash, 'Identity proof opened or changed the archive fixture');
  Writeln('PASS exact existing physical originals and archive member identity are preserved without source/foreign-content reads');
  // ReaderCopyName is also the value passed to the reader history/notes ID
  // hash. Placeholder IDs must distinguish physical books; retain ambiguous
  // pre-fix notes byte-for-byte rather than assigning them to a guessed book.
  var First := Saved; var Second := Saved;
  First.Folder := ''; First.FileName := 'physical-one'; First.FileExt := '.fb2';
  Second.Folder := ''; Second.FileName := 'physical-two'; Second.FileExt := '.fb2';
  for var Placeholder in TArray<string>.Create('', '0', '000', 'flibusta:0', 'librusec:000',
    'merged:source:flibusta:0', 'flibusta:', 'librusec:', 'merged:source:flibusta:', 'flibusta: 0') do
  begin
    First.LibID := Placeholder; Second.LibID := Placeholder;
    var FirstName := ReaderCopyName(First); var SecondName := ReaderCopyName(Second);
    Require(FirstName <> SecondName, 'Different physical books share a placeholder cache name');
    Require(Copy(THashSHA2.GetHashString(FirstName), 1, 40) <> Copy(THashSHA2.GetHashString(SecondName), 1, 40),
      'Placeholder books still share the actual reader history/notes ID');
  end;
  First.LibID := ''; First.FileName := 'physical-one'; First.InsideNo := 1;
  Require(ReaderCopyName(First) = 'homelib-' + IntToStr(CID) + '-' +
    Copy(THashSHA2.GetHashString(LowerCase(First.Folder + #1 + First.FileName + First.FileExt)), 1, 32) + '.fb2',
    'Existing empty-ID named-member history identity changed');
  Second := First; Second.InsideNo := 9;
  Require(ReaderCopyName(First) = ReaderCopyName(Second), 'Named member history now depends on a changing archive index');
  First.LibID := '0'; Second.LibID := '0'; First.FileName := ''; Second.FileName := '';
  First.Folder := 'index-only.zip'; Second.Folder := First.Folder;
  First.InsideNo := 0; Second.InsideNo := 1;
  Require(ReaderCopyName(First) <> ReaderCopyName(Second), 'Unnamed index-only members share placeholder cache/history');
  First.Folder := ''; Second.Folder := ''; First.FileName := 'physical-one'; Second.FileName := 'physical-two';
  First.LibID := '42';
  Require(ReaderCopyName(First) = 'homelib-' + IntToStr(CID) + '-' +
    Copy(THashSHA2.GetHashString('42'), 1, 32) + '.fb2', 'Known reader cache/history identity changed');
  // Refusing an unproven fallback must not rename existing normal history.
  for var StableID in TArray<string>.Create('42', 'opaque-uuid-42', 'local:opaque-uuid-42',
    'urn:uuid:1c68290f-bb67-4d52-a195-69901aadfcd8') do
  begin
    First.LibID := StableID;
    Require(ReaderCopyName(First) = 'homelib-' + IntToStr(CID) + '-' +
      Copy(THashSHA2.GetHashString(StableID), 1, 32) + '.fb2',
      'Normal raw/opaque cache/history identity changed: ' + StableID);
  end;
  First.LibID := 'merged:source:file:stable-physical-hash';
  Require(ReaderCopyName(First) = 'homelib-' + IntToStr(CID) + '-' +
    Copy(THashSHA2.GetHashString(First.LibID), 1, 32) + '.fb2', 'Existing merged physical history identity changed');
  var LegacyName := 'homelib-' + IntToStr(CID) + '-' + Copy(THashSHA2.GetHashString('0'), 1, 32) + '.fb2';
  var LegacyHistoryID := Copy(THashSHA2.GetHashString(LegacyName), 1, 40);
  var LegacyIni := TPath.Combine(Root, 'reader.ini');
  TFile.WriteAllText(LegacyIni, '[Book.' + LegacyHistoryID + ']' + sLineBreak + 'Position=9876' + sLineBreak +
    '[Bookmarks.' + LegacyHistoryID + ']' + sLineBreak + 'Count=1' + sLineBreak + 'Title0=Keep legacy bookmark', TEncoding.UTF8);
  var LegacyNotes := TReaderAnnotations.Create(LegacyIni);
  try
    var Note := Default(TReaderAnnotation); Note.BookID := LegacyHistoryID; Note.BookTitle := 'Legacy ambiguous book';
    Note.Text := 'Keep legacy note — ё, ї, ў 😀'; Note.Position := 9876; LegacyNotes.Put(Note);
    var IniHash := THashSHA2.GetHashStringFromFile(LegacyIni);
    var NotesPath := TPath.Combine(Root, 'reader-notes.json'); var NotesHash := THashSHA2.GetHashStringFromFile(NotesPath);
    First.LibID := '0'; Second.LibID := '0';
    Require(ReaderCopyName(First) <> ReaderCopyName(Second), 'Legacy placeholder migration merged new identities');
    Require((THashSHA2.GetHashStringFromFile(LegacyIni) = IniHash) and
      (THashSHA2.GetHashStringFromFile(NotesPath) = NotesHash), 'Identity change modified or removed legacy positions/notes');
    Require((Length(LegacyNotes.Items(LegacyHistoryID)) = 1) and
      ReaderAnnotationsText(LegacyNotes.Items, False).Contains(Note.Text), 'Legacy note is unavailable to export-all');
  finally LegacyNotes.Free; end;
  Writeln('PASS placeholder cache/history IDs distinguish physical books, known IDs stay compatible and legacy shared positions/bookmarks/notes remain intact');
  TestReaderAtomicProgress;
  Flush(Output);
end;
