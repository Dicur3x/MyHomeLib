procedure TestPackedPlaceholderIds(Metabib: Boolean; const LegacyExclusion: string);
const
  Names: array[0..6] of string = ('empty-left','empty-right','zero-left','zero-right',
    'text-left','text-right','arrival');
  PublisherIDs: array[0..6] of string = ('','','0','0','file:duplicate','file:duplicate','');
  Replaced = 4;
  Arrival = 6;
var
  Root, Original, Downloads, IndexFile, OriginalState, OriginalPayloads: string;
  Source, PackedSource, Current: IBookCollection;
  Profile: TLibraryUpdateSource;
  Options: TCollectionPackingOptions;
  Snapshot: TCollectionPackingSnapshot;
  StableIDs: array[0..5] of Integer;
  LiveIDs: array[0..5] of string;
  CollectionID, PackedID, UpdatedID, Deleted: Integer;
  OriginalArchives: TArray<string>;
  Book: TBookRecord;

  function Title(Index: Integer; Updated: Boolean): string;
  begin
    Result := 'Publisher '+Names[Index];
    if Updated and (Index=Replaced) then Result:=Result+' corrected';
  end;

  procedure Archive(const Directory: string; Index: Integer; const Body: string);
  var Zip: TZipFile;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(TPath.Combine(Directory,Names[Index]+'.zip'),zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes(Body),'same.txt');
    finally Zip.Free; end;
  end;

  procedure WriteInpx(const FileName: string; Updated: Boolean);
  var Zip:TZipFile; Row:string;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),
        'structure.info');
      for var I:=0 to 5+Ord(Updated) do
      begin
        Row:='Author,Test:'#4'prose_contemporary:'#4+Title(I,Updated)+#4#4#4'same'#4+
          IntToStr(100+Ord(Updated and (I=Replaced)))+#4+PublisherIDs[I]+#4'0'#4'txt'#4'2026-11-18'#4'ru'+sLineBreak;
        Zip.Add(TEncoding.UTF8.GetBytes(Row),Names[I]+'.inp');
      end;
    finally Zip.Free; end;
  end;

  procedure WriteMetabib;
  var Rows:TMemoryStream; Stream:TFileStream; Volumes:TArray<TMetabibExportArchive>;
    Location:TMetabibExportLocation; Item:TBookRecord;
  begin
    Rows:=TMemoryStream.Create;
    try
      SetLength(Volumes,Length(Names));
      for var I:=0 to High(Names) do
      begin
        Volumes[I].ID:=Names[I]; Volumes[I].Name:=Names[I]+'.zip';
        Volumes[I].Ordinal:=I; Volumes[I].Entries:=1;
        Item:=Default(TBookRecord);
        Item.LibID:=PublisherIDs[I]; Item.Title:=Title(I,True); Item.Lang:='ru';
        Item.Date:=EncodeDate(2026,11,18);
        TAuthorsHelper.Add(Item.Authors,'Author','Test','');
        Location:=Default(TMetabibExportLocation);
        Location.ArchiveID:=Names[I]; Location.EntryName:='same.txt';
        Location.UncompressedSize:=100+Ord(I=Replaced);
        TMetabibWriter.WriteRecord(Rows,Item,nil,Location,'flibusta','fixture');
      end;
      Stream:=TFileStream.Create(IndexFile,fmCreate);
      try TMetabibWriter.WriteDataset(Stream,Rows,'packed-placeholder-fixture','flibusta','3.0',
        EncodeDate(2026,11,18),Length(Volumes),Volumes);
      finally Stream.Free; end;
    finally Rows.Free; end;
  end;

  function ReadBody(const Item:TBookRecord):string;
  var Stream:TStream; Bytes:TBytes;
  begin
    Stream:=Item.GetBookStream(True,False);
    Require(Assigned(Stream),'Packed placeholder copy is unreadable: '+Item.Title);
    try
      SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
      Result:=TEncoding.UTF8.GetString(Bytes);
    finally Stream.Free; end;
  end;

  procedure CaptureAndSetPersonal;
  var Books:IBookIterator; Index:Integer;
  begin
    Books:=PackedSource.GetBookIterator(bmAll,True);
    while Books.Next(Book) do
    begin
      Index:=-1;
      for var I:=0 to High(StableIDs) do
        if Book.Title=Title(I,False) then begin Index:=I; Break; end;
      Require(Index>=0,'Unexpected packed baseline card');
      Require(StableIDs[Index]=0,'Packed baseline duplicated the card '+Book.Title);
      Require(ReadBody(Book)=Names[Index],'Packed baseline mixed archive members for '+Book.Title);
      StableIDs[Index]:=Book.BookKey.BookID; LiveIDs[Index]:=Book.LibID;
    end;
    Books:=nil;
    for var I:=0 to High(StableIDs) do
    begin
      Require(StableIDs[I]>0,'Packed baseline lost '+Names[I]);
      var Key:=CreateBookKey(StableIDs[I],PackedID);
      PackedSource.SetRate(Key,4); PackedSource.SetProgress(Key,10+I);
      PackedSource.SetReview(Key,'Saved review '+Names[I]);
    end;
  end;

  procedure Verify(Collection:IBookCollection; Delivered:Boolean);
  var Books:IBookIterator; Count:Integer;
  begin
    Books:=Collection.GetBookIterator(bmAll,True); Count:=0;
    while Books.Next(Book) do
    begin
      Inc(Count);
      Require(Book.Title<>Title(Deleted,False),'The excluded copy was restored');
      if Book.Title=Title(Arrival,True) then
        Require(ReadBody(Book)=Names[Arrival],'New copy from the wrong archive');
    end;
    Books:=nil;
    Require(Count=6,'Packed update duplicated or lost one of the shared-name cards: '+IntToStr(Count));
    for var I:=0 to High(StableIDs) do
    begin
      if I=Deleted then Continue;
      Book:=Default(TBookRecord);
      Collection.GetBookRecord(CreateBookKey(StableIDs[I],Collection.CollectionID),Book,True);
      Require((Book.LibID=LiveIDs[I]) and (Book.Title=Title(I,True)),
        'The publisher update mapped the wrong retained identity: '+Names[I]);
      Require((Book.Rate=4) and (Book.Progress=10+I) and
        (Collection.GetReview(Book.BookKey)='Saved review '+Names[I]),'Personal data moved to the wrong card');
      if Delivered and (I=Replaced) then Require(ReadBody(Book)='Updated '+Names[I],'Late delivery was not selected')
      else Require(ReadBody(Book)=Names[I],'Another archive changed the wrong payload: '+Names[I]);
    end;
  end;

  function ProtectedCatalogState: string;
  var DB:TSQLiteDatabase; Tables:TSQLiteQuery; Name, Filter: string;
  begin
    Result:='';
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(PackedID).DBFileName);
    try
      Result:=SBRRows(DB,'SELECT type||char(31)||name||char(31)||coalesce(sql,'''') '+
        'FROM sqlite_master ORDER BY type,name');
      Tables:=DB.NewQuery('SELECT name FROM sqlite_master WHERE type=''table'' ORDER BY name');
      try
        Tables.Open;
        while not Tables.Eof do
        begin
          Name:=Tables.FieldAsString(0); Filter:='';
          if Name='Settings' then
            // Switching collections saves the previous view's selections and
            // language filters. Everything else in the original must match.
            Filter:=Format(' WHERE SettingID NOT IN (%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)',
              [PROP_LAST_AUTHOR,PROP_LAST_AUTHOR_BOOK,PROP_LAST_SERIES,PROP_LAST_PUBLISHER_SERIES,
               PROP_LAST_PUBLISHER_BOOK,PROP_PUBLISHER_LANG_FILTER,PROP_LAST_SERIES_BOOK,
               PROP_BOOKS_LANG_FILTER,PROP_SERIES_LANG_FILTER,PROP_GENRES_LANG_FILTER,PROP_GROUPS_LANG_FILTER]);
          Result:=Result+#1+Name+#2+SBRTable(DB,Name,False,False,Filter);
          Tables.Next;
        end;
      finally Tables.Free; end;
    finally DB.Free; end;
  end;

  function ProtectedPayloadState: string;
  begin
    Result:='';
    for var Path in OriginalArchives do
      if MatchText(ExtractFileExt(Path),['.zip','.7z']) then
        Result:=Result+#1+Path+#2+THashSHA2.GetHashStringFromFile(Path);
    Require(Result<>'','Packed fixture did not produce any protected archives');
  end;

  procedure RewriteOldExclusion(Restore: Boolean);
  var History: TCatalogSource; DB: TSQLiteDatabase; Prior:TBookRecord;
    ExactKey, PreviousKey: string;
  begin
    Require(LoadLibraryUpdateHistory(Current,Profile,History),'Saved source history is unavailable');
    Prior:=Default(TBookRecord);
    Prior.Folder:=Names[Deleted]+'.zip'; Prior.FileName:='same'; Prior.FileExt:='.txt';
    Prior.LibID:=PublisherIDs[Deleted];
    ExactKey:=LibraryPackedArtifactKey(Prior,LibraryPublisherLocation(Prior));
    PreviousKey:=LibraryUpdateBookKey(Prior,'flibusta',Original);
    DB:=TSQLiteDatabase.Create(History.CacheFile);
    try
      if Restore then
        DB.ExecSQL('UPDATE LibraryUpdateExclusions SET Key=? WHERE Key=?',[ExactKey,PreviousKey])
      else
      begin
        Require(DB.QuerySingleInt('SELECT count(*) FROM LibraryUpdateExclusions WHERE Key=?',[ExactKey])=1,
          'The exact archive exclusion was not saved in the cache');
        DB.ExecSQL('UPDATE LibraryUpdateExclusions SET Key=? WHERE Key=?',[PreviousKey,ExactKey]);
      end;
    finally DB.Free; end;
  end;

  procedure CheckAmbiguousOldExclusion(ID:Integer);
  var Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview; Worker:TCollectionWorker;
    BeforeState:string;
  begin
    RewriteOldExclusion(False);
    BeforeState:=ProtectedCatalogState;
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.LibraryUpdateWorkPath,nil);
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        Worker:=CreateLibraryReviewWorker(ID,Review);
        try
          Worker.Start; Worker.WaitFor;
          Require(not Worker.Success and not Review.Ready and Assigned(Worker.FatalException) and
            Exception(Worker.FatalException).Message.Contains('Прежнее исключение соответствует нескольким архивам'),
            'An ambiguous historical exclusion was accepted or misdiagnosed');
        finally Worker.Free; end;
      finally Review.Free; end;
    finally Stage.Free; end;
    Require(ProtectedCatalogState=BeforeState,'Refusing an ambiguous exclusion changed the protected catalogue');
    RewriteOldExclusion(True);
    Writeln('PASS ambiguous archive exclusion is refused before any update');
  end;

  function ReviewAndApply(ID:Integer; RepeatOnly:Boolean=False):Integer;
  var Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview; Worker:TCollectionWorker; Judge:TLibraryApplyProbe;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.LibraryUpdateWorkPath,nil);
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage);
      try
        Worker:=CreateLibraryReviewWorker(ID,Review);
        try
          TOORun(Worker);
          if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
          Require(Worker.Success and Review.Ready,'Placeholder publisher review failed');
        finally Worker.Free; end;
        if RepeatOnly then
        begin
          Require((Review.NewBooks=0) and (Review.ChangedBooks=0) and (Review.NeededArchives.Count=0),
            'Unchanged published index was offered again after delivery: '+Review.Summary);
          Exit(ID);
        end;
        Require((Review.NewBooks=0) and (Review.ChangedBooks=1) and (Review.NeededArchives.Count=0),
          'Late delivery changed more than one book: '+Review.Summary);
        Judge:=TLibraryApplyProbe.Create; Judge.Accept:=True;
        Worker:=CreateLibraryApplyWorker(ID,Review,False);
        try
          Worker.OnShowMessage:=Judge.Confirm; Worker.Start; Worker.WaitFor;
          if Assigned(Worker.FatalException) then raise Exception.Create(Exception(Worker.FatalException).Message);
          Require(Judge.Confirmed and Worker.CommittedChanges,'Late delivery did not apply');
          Result:=Review.PublishedCollectionID;
        finally Worker.Free; Judge.Free; end;
      finally Review.Free; end;
    finally Stage.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Placeholder packing needs an isolated G: runtime');
  FillChar(StableIDs,SizeOf(StableIDs),0);
  Deleted:=3;
  if LegacyExclusion='migrate' then Deleted:=1;
  Root:=Settings.AppPath+'packed-placeholder-ids'; Original:=TPath.Combine(Root,'original');
  Downloads:=TPath.Combine(Root,'downloads');
  ForceDirectories(Original); ForceDirectories(Downloads);
  for var I:=0 to High(StableIDs) do Archive(Original,I,Names[I]);
  WriteInpx(TPath.Combine(Original,'base.inpx'),False);
  CollectionID:=SystemDB.CreateCollection('Placeholder originals',Original,TPath.Combine(Root,'original.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  var Importer:=TImportInpxThread.Create(CollectionID,TPath.Combine(Original,'base.inpx'),gtFb2);
  try TOORun(Importer); Require(Importer.Success,'Initial INPX import failed'); finally Importer.Free; end;
  Source:=SystemDB.GetCollection(CollectionID);
  Source.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
  Options:=Default(TCollectionPackingOptions); Options.SourceID:=CollectionID;
  Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE); Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Options.SourceRoot:=Original; Options.OutputRoot:=TPath.Combine(Root,'packed'); Options.DisplayName:='Packed placeholders';
  Options.Python:=Settings.AppPath+'tools\python\python.exe';
  Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared; PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  Require(RenameFile(Original,Original+'-offline'),'Cannot hide the original fixture archive directory');
  PackedSource:=SystemDB.GetCollection(PackedID); CaptureAndSetPersonal;
  PackedSource.DeleteBook(CreateBookKey(StableIDs[Deleted],PackedID));
  Archive(Downloads,Arrival,Names[Arrival]);
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Placeholder publisher';
  Profile.Location:=Downloads; Profile.BooksRoot:=Downloads;
  if Metabib then Profile.IndexFile:='publisher.jsonl' else Profile.IndexFile:='publisher.inpx';
  IndexFile:=TPath.Combine(Downloads,Profile.IndexFile);
  if Metabib then WriteMetabib else WriteInpx(IndexFile,True);
  PackedSource.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
  OriginalState:=ProtectedCatalogState;
  OriginalArchives:=TDirectory.GetFiles(PackedSource.CollectionRoot,'*',TSearchOption.soAllDirectories);
  TArray.Sort<string>(OriginalArchives);
  OriginalPayloads:=ProtectedPayloadState;
  UpdatedID:=ApplyPackedUpdateFromMain(Profile,PackedID,Names[Replaced]+'.zip',1,1);
  Current:=SystemDB.GetCollection(UpdatedID,True); Verify(Current,False);
  if LegacyExclusion='migrate' then RewriteOldExclusion(False)
  else if LegacyExclusion='ambiguous' then CheckAmbiguousOldExclusion(UpdatedID);
  Archive(Downloads,Replaced,'Updated '+Names[Replaced]);
  CollectionID:=ReviewAndApply(UpdatedID);
  Current:=SystemDB.GetCollection(CollectionID,True); Verify(Current,True);
  ReviewAndApply(CollectionID,True);
  if LegacyExclusion='migrate' then Writeln('PASS a unique historical exclusion survives the archive-key migration');
  Require(ProtectedCatalogState=OriginalState,'Update changed the original packed catalogue');
  Require(ProtectedPayloadState=OriginalPayloads,'Update overwrote an original packed archive');
  Writeln('PASS packed update preserves repeated empty zero and textual publisher IDs by archive: ',Profile.IndexFile);
  Flush(Output);
end;
