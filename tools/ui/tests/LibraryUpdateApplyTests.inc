type
  TLibraryApplyProbe = class
    Accept: Boolean;
    Confirmed: Boolean;
    function Confirm(const Text: string; Flags: Longint): Integer;
  end;

function TLibraryApplyProbe.Confirm(const Text: string; Flags: Longint): Integer;
begin
  Require(Text.Contains('Применить обновление') and ((Flags and MB_DEFBUTTON2)<>0),
    'Library update did not present a prepared review with default No');
  Confirmed:=True;
  if Accept then Result:=IDYES else Result:=IDNO;
end;

procedure TestLibraryUpdateApplication;
var Root, OldRoot, DownloadRoot, IndexName, OldHash, DownloadHash, ExpectedTitle, FirstCache, CacheHash: string;
  Target: IBookCollection; Profile: TLibraryUpdateSource; Stage: TStagedLibraryIndex; Review: TLibraryUpdateReview;
  Worker: TCollectionWorker; Probe: TLibraryApplyProbe; ID, BookID: Integer; Book, Seed: TBookRecord;
  Sources: TCatalogSources; CacheInfo: TCatalogSource; Refresh: TCatalogRefreshWorker;
  Merge: TCatalogMergeWorker; Plan: TCollectionMergePlan; DB: TSQLiteDatabase; InputSource: TMergeSource; SourceKey: string;
  GroupBooks: IBookIterator;

  function XML(const Number: string): string;
  begin
    Result:='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
      '<book-title>Book '+Number+'</book-title></title-info></description><body><section><p>body '+Number+
      '</p></section></body></FictionBook>';
  end;
  procedure Archive(const Folder, Name: string; const Numbers: array of string);
  var Zip: TZipFile;
  begin
    ForceDirectories(Folder); Zip:=TZipFile.Create;
    try Zip.Open(TPath.Combine(Folder,Name),zmWrite);
      for var Number in Numbers do Zip.Add(TEncoding.UTF8.GetBytes(XML(Number)),Number+'.fb2');
    finally Zip.Free; end;
  end;
  procedure Index(const Path: string; const Archives, Numbers, Titles: array of string);
  var Zip: TZipFile; Rows: TDictionary<string,string>; Line, Existing: string;
  begin
    Rows:=TDictionary<string,string>.Create; Zip:=TZipFile.Create;
    try
      for var I:=0 to High(Numbers) do
      begin
        Line:='Author,Test:'#4'prose_contemporary:'#4+Titles[I]+#4#4#4+Numbers[I]+#4+
          IntToStr(Length(TEncoding.UTF8.GetBytes(XML(Numbers[I]))))+#4+Numbers[I]+#4'0'#4'fb2'#4'2026-11-14'#4'ru'+sLineBreak;
        if not Rows.TryGetValue(Archives[I],Existing) then Existing:='';
        Rows.AddOrSetValue(Archives[I],Existing+Line);
      end;
      Zip.Open(Path,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes('20261114'),'version.info');
      for var Pair in Rows do Zip.Add(TEncoding.UTF8.GetBytes(Pair.Value),Pair.Key+'.inp');
    finally Zip.Free; Rows.Free; end;
  end;
  procedure OpenReview;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
    Review:=TLibraryUpdateReview.Create(Profile,Stage);
    Worker:=CreateLibraryReviewWorker(ID,Review);
    try Worker.Start; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create('Apply fixture review: '+Exception(Worker.FatalException).Message);
      Require(Worker.Success and Review.Ready,'Apply fixture index review failed');
    finally Worker.Free; end;
  end;
  procedure Apply(Accept: Boolean);
  begin
    Probe:=TLibraryApplyProbe.Create; Probe.Accept:=Accept;
    Worker:=CreateLibraryApplyWorker(ID,Review,False);
    try
      Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create('Apply fixture worker: '+Exception(Worker.FatalException).Message);
      Require(Probe.Confirmed,'Library update skipped its concrete confirmation');
      Require((Worker.CommittedChanges=Accept) and (Worker.Success=Accept), 'Wrong reviewed application outcome');
    finally Worker.Free; Probe.Free; end;
    if Accept then Target:=SystemDB.GetCollection(ID,True);
  end;
  procedure CloseReview;
  begin Review.Free; Review:=nil; Stage.Free; Stage:=nil; end;
  procedure RejectCommit;
  begin
    Probe:=TLibraryApplyProbe.Create; Probe.Accept:=True;
    Worker:=CreateLibraryApplyWorker(ID,Review,False);
    try
      Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
      Require(Probe.Confirmed and Assigned(Worker.FatalException) and not Worker.CommittedChanges and
        Exception(Worker.FatalException).Message.Contains('reviewed-update-test-fault'),
        'Injected final-state failure did not roll the application back');
    finally Worker.Free; Probe.Free; end;
    Target:=SystemDB.GetCollection(ID,True);
  end;
  procedure CommitFault(Install: Boolean);
  begin
    DB:=TSQLiteDatabase.Create(VarToStr(Target.GetProperty(PROP_DATAFILE)));
    try
      if Install then DB.ExecSQL('CREATE TRIGGER ReviewedApplyFailure BEFORE INSERT ON Settings WHEN NEW.SettingID='+
        IntToStr(Int64(PROP_LIBRARY_UPDATE_HISTORY))+' BEGIN SELECT RAISE(ABORT,''reviewed-update-test-fault''); END')
      else DB.ExecSQL('DROP TRIGGER ReviewedApplyFailure');
    finally DB.Free; end;
  end;
  procedure RequireBody(const Item: TBookRecord; const Number: string);
  var Stream: TStream; Bytes: TBytes;
  begin
    Stream:=Item.GetBookStream;
    try
      SetLength(Bytes,Stream.Size); if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
      Require(TEncoding.UTF8.GetString(Bytes).Contains('body '+Number),'Updated book does not read the correct actual archive member');
    finally Stream.Free; end;
  end;
  function FindDisplayBook(const Number: string; out Item: TBookRecord): Boolean;
  var Books: IBookIterator;
  begin
    Books:=Target.GetBookIterator(bmAll,True); Result:=False;
    while Books.Next(Item) do if Item.DisplayLibID=Number then Exit(True);
  end;
begin
  Stage:=nil; Review:=nil;
  Root:=TPath.Combine(Settings.AppPath,'library-apply-fixture'); ForceDirectories(Root);
  OldRoot:=TPath.Combine(Root,'old'); DownloadRoot:=TPath.Combine(Root,'downloads');
  Archive(OldRoot,'books.zip',['101','104']); Archive(DownloadRoot,'new.zip',['102']);
  IndexName:=TPath.Combine(Root,'whole.inpx');
  Index(IndexName,['books','new','new'],['101','102','103'],['Fish &amp;amp; chips','New 102','Awaiting 103']);
  ID:=SystemDB.CreateCollection('Reviewed whole update',OldRoot,TPath.Combine(Root,'whole.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Target:=SystemDB.GetCollection(ID); Seed:=Default(TBookRecord);
  Seed.Title:='Old 101'; Seed.LibID:='101'; Seed.FileName:='101'; Seed.FileExt:='.fb2'; Seed.Folder:='books.zip';
  Seed.Lang:='ru'; Seed.Date:=EncodeDate(2026,10,1); Seed.Size:=Length(TEncoding.UTF8.GetBytes(XML('101')));
  TAuthorsHelper.Add(Seed.Authors,'Author','Test',''); TGenresHelper.Add(Seed.Genres,'','','prose_contemporary');
  BookID:=Target.InsertBook(Seed,False,False); Seed.BookKey:=CreateBookKey(BookID,ID);
  var Unlisted:=Seed; Unlisted.LibID:='104'; Unlisted.FileName:='104'; Unlisted.Title:='Initially indexed 104';
  Target.InsertBook(Unlisted,False,False);
  Target.SetRate(Seed.BookKey,4); Target.SetProgress(Seed.BookKey,37);
  Target.SetReview(Seed.BookKey,'Keep my note ё'); Target.SetAnnotation(Seed.BookKey,'Keep &lt;literal&gt; annotation');
  Target.AddBookToGroup(Seed.BookKey,FAVORITES_GROUP_ID);
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed whole fixture';
  Profile.Location:=Root; Profile.IndexFile:='whole.inpx'; Profile.BooksRoot:=DownloadRoot;
  OldHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(OldRoot,'books.zip'));
  DownloadHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(DownloadRoot,'new.zip'));
  CommitFault(True); OpenReview;
  try
    RejectCommit;
    BookID:=Target.ResolveBookID('101',0); Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require((Book.Title='Old 101') and (Book.Rate=4) and (Book.Progress=37) and
      (Book.Annotation='Keep &lt;literal&gt; annotation') and (Target.ResolveBookID('104',0)>0) and
      (Target.ResolveBookID('102',0)=0) and (VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_HISTORY))=''),
      'Failed whole update changed books, personal data or the saved baseline');
  finally CloseReview; CommitFault(False); end;
  OpenReview;
  try
    BookID:=Review.Snapshot.ResolveBookID('101',0); Review.Snapshot.GetBookRecord(CreateBookKey(BookID,Review.Snapshot.CollectionID),Book,True);
    ExpectedTitle:=Book.Title;
    var Revision:=Target.GetCatalogRevision; Apply(False);
    Require(Target.GetCatalogRevision=Revision,'Declined application changed the live catalogue');
    Target.SetRate(Seed.BookKey,3); Target.SetRate(Seed.BookKey,4);
    Worker:=CreateLibraryApplyWorker(ID,Review,False);
    try
      Worker.Start; Worker.WaitFor;
      Require(Assigned(Worker.FatalException) and not Worker.CommittedChanges and
        Exception(Worker.FatalException).Message.Contains('Коллекция изменилась'),
        'A separate worker accepted an externally changed reviewed catalogue');
    finally Worker.Free; end;
    CloseReview; OpenReview;
    Apply(True);
    BookID:=Target.ResolveBookID('101',0); Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require((Book.Title=ExpectedTitle) and (Book.Rate=4) and (Book.Progress=37) and
      (Book.Review='Keep my note ё') and (Book.Annotation='Keep &lt;literal&gt; annotation'),
      Format('Full source snapshot changed literal metadata or personal fields: title="%s" expected="%s" rate=%d progress=%d review="%s" annotation="%s"',
        [Book.Title,ExpectedTitle,Book.Rate,Book.Progress,Book.Review,Book.Annotation])); RequireBody(Book,'101');
    BookID:=Target.ResolveBookID('102',0); Require(BookID>0,'Downloaded new book was not added');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require(Book.GetBookFileName.Contains(DownloadRoot),'Downloaded root was lost during full replacement'); RequireBody(Book,'102');
    Require(Target.ResolveBookID('103',0)=0,'A missing actual archive member was added as a new book');
    Require(Target.ResolveBookID('104',0)=0,'Full update retained a nonlocal row absent from its new index');
    Require(LoadLibraryUpdateHistory(Target,Profile,CacheInfo),'Committed update did not save its per-profile baseline');
    FirstCache:=CacheInfo.CacheFile; CacheHash:=THashSHA2.GetHashStringFromFile(FirstCache);
    GroupBooks:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,ID);
    Require(GroupBooks.Next(Book) and (Book.LibID='101') and not GroupBooks.Next(Book),'Full replacement lost favourite membership'); GroupBooks:=nil;
  finally CloseReview; end;
  Require((THashSHA2.GetHashStringFromFile(TPath.Combine(OldRoot,'books.zip'))=OldHash) and
    (THashSHA2.GetHashStringFromFile(TPath.Combine(DownloadRoot,'new.zip'))=DownloadHash),'Catalogue update rewrote a book archive');
  BookID:=Target.ResolveBookID('101',0); Target.DeleteBook(CreateBookKey(BookID,ID));
  Archive(DownloadRoot,'new.zip',['102','103']);
  OpenReview;
  try Apply(True);
    Require(Target.ResolveBookID('101',0)=0,'A previously removed book was resurrected by the same index');
    BookID:=Target.ResolveBookID('102',0); Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True); RequireBody(Book,'102');
    BookID:=Target.ResolveBookID('103',0); Require(BookID>0,'Same-index continuation ignored a newly downloaded member');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True); RequireBody(Book,'103');
    Require(THashSHA2.GetHashStringFromFile(FirstCache)=CacheHash,'A later update overwrote an older baseline generation');
  finally CloseReview; end;
  Index(IndexName,['new','new'],['102','103'],['New 102','Awaiting 103']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Index(IndexName,['books','new','new','books'],['101','102','103','104'],['Returned 101','New 102','Awaiting 103','Publisher returned 104']);
  OpenReview;
  try Apply(True);
    Require(Target.ResolveBookID('101',0)=0,'An excluded book returned after an intervening index omitted it');
    Require(Target.ResolveBookID('104',0)>0,'Publisher omission was incorrectly treated as a user deletion');
  finally CloseReview; end;
  Writeln('PASS reviewed whole update keeps literal metadata personal data favourites and roots, skips missing members, continues the same index and retains removed books as excluded');

  SetLength(Sources,2);
  for var I:=0 to 1 do
  begin
    Sources[I].ID:=TCatalogSource.NewID; Sources[I].Name:='Priority '+IntToStr(I);
    Sources[I].Root:=TPath.Combine(Root,'priority-'+IntToStr(I)); Sources[I].LibraryNamespace:='flibusta';
    Sources[I].INPXFile:=TPath.Combine(Root,'priority-'+IntToStr(I)+'.inpx');
    Archive(Sources[I].Root,'base.zip',['201']); Index(Sources[I].INPXFile,['base'],['201'],['Shared book']);
    Refresh:=TCatalogRefreshWorker.Create(Sources[I]);
    try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Priority source preparation failed: '+Refresh.Error);
    finally Refresh.Free; end;
  end;
  ID:=SystemDB.CreateCollection('Reviewed merged update',Root,TPath.Combine(Root,'merged.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Target:=SystemDB.GetCollection(ID); SaveCatalogSources(Target,Sources);
  Merge:=TCatalogMergeWorker.CreatePreview(ID,Sources,mpSourcePriority);
  try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Priority fixture preview failed: '+Merge.Error); Plan:=Merge.TakePlan;
  finally Merge.Free; end;
  try Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Root,'priority-backup'));
    try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Priority fixture merge failed: '+Merge.Error);
    finally Merge.Free; end;
  finally Plan.Free; end;
  Target:=SystemDB.GetCollection(ID,True); var All:=Target.GetBookIterator(bmAll,True); Require(All.Next(Book),'Priority fixture is empty'); All:=nil;
  Seed:=Book; Target.SetRate(Book.BookKey,5); Target.SetProgress(Book.BookKey,61);
  Target.SetAnnotation(Book.BookKey,'Preferred annotation'); Target.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
  InputSource.ID:=Sources[1].ID; InputSource.Root:=Sources[1].Root;
  Book.CollectionRoot:=Sources[1].Root; Book.Folder:='base.zip'; Book.FileName:='201'; Book.FileExt:='.fb2';
  SourceKey:=MergeSourceKey(InputSource,Book);
  DB:=TSQLiteDatabase.Create(VarToStr(Target.GetProperty(PROP_DATAFILE)));
  try DB.ExecSQL('DELETE FROM CatalogBookCopies WHERE SourceKey=?',[SourceKey]);
    DB.ExecSQL('DELETE FROM CatalogSourceBooks WHERE SourceKey=?',[SourceKey]);
  finally DB.Free; end;
  Archive(Sources[1].Root,'base.zip',['299']);
  DownloadRoot:=TPath.Combine(Root,'priority-downloads'); Archive(DownloadRoot,'next.zip',['202']);
  IndexName:=TPath.Combine(Root,'priority-update.inpx');
  Index(IndexName,['base','next'],['201','202'],['Lower correction','New source book']);
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed bound source';
  Profile.Location:=Root; Profile.IndexFile:=TPath.GetFileName(IndexName); Profile.CatalogSourceID:=Sources[1].ID; Profile.BooksRoot:=DownloadRoot;
  CommitFault(True); OpenReview;
  try
    RejectCommit; Target.GetBookRecord(Seed.BookKey,Book,True);
    Require((Book.Title='Shared book') and (Book.Rate=5) and (Book.Progress=61) and
      (Target.GetCatalogBookID(SourceKey)=0) and (VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_HISTORY))=''),
      'Failed bound update changed priorities, removed copies, personal data or baseline');
    var BeforeBooks:=Target.GetBookIterator(bmAll,True);
    Require(BeforeBooks.Next(Book) and not BeforeBooks.Next(Book),'Failed bound update retained its inserted new card'); BeforeBooks:=nil;
  finally CloseReview; CommitFault(False); end;
  Target:=SystemDB.GetCollection(ID,True); OpenReview;
  try Apply(True);
    Target.GetBookRecord(Seed.BookKey,Book,True);
    Require((Book.Title='Shared book') and (Book.Rate=5) and (Book.Progress=61) and
      (Book.Annotation='Preferred annotation') and Book.GetBookFileName.Contains(Sources[0].Root),
      'Updating a lower source changed the preferred book or its personal data');
    Require(Target.GetCatalogBookID(SourceKey)=0,'A removed lower-priority source copy was resurrected');
    All:=Target.GetBookIterator(bmAll,True); var Count:=0;
    while All.Next(Book) do begin Inc(Count); if Book.DisplayLibID='202' then RequireBody(Book,'202'); end;
    All:=nil; Require(Count=2,'Bound-source update did not add exactly the new book');
    Require(LoadLibraryUpdateHistory(Target,Profile,CacheInfo) and FileExists(CacheInfo.CacheFile),'Merged source baseline was not published');
  finally CloseReview; end;
  OpenReview;
  try Apply(True);
    All:=Target.GetBookIterator(bmAll,True); var RepeatCount:=0;
    while All.Next(Book) do begin Inc(RepeatCount); if Book.DisplayLibID='202' then RequireBody(Book,'202'); end;
    All:=nil; Require(RepeatCount=2,'Repeating a bound-source update added duplicates or broke its downloaded root');
  finally CloseReview; end;
  Index(IndexName,['next'],['202'],['New source book']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Index(IndexName,['base','next'],['201','202'],['Returned lower copy','New source book']);
  OpenReview;
  try Apply(True);
    Require(Target.GetCatalogBookID(SourceKey)=0,'A removed source copy returned after an intervening index omitted it');
    Target.GetBookRecord(Seed.BookKey,Book,True); Require(Book.GetBookFileName.Contains(Sources[0].Root),
      'A returning excluded copy replaced the preferred source');
  finally CloseReview; end;
  Writeln('PASS reviewed merged-source update preserves priorities personal data and removed copies, adds verified members from a second root and repeats without duplicate cards');
  Writeln('PASS reviewed updates retain exclusions across omitted indexes, distinguish publisher omissions and roll back catalogues personal fields source links and baseline publication on a late failure');

  // The binding owns one applied baseline even when two profiles update it.
  // Keep A's older cache intact, then use B, delete a publication, omit it,
  // return through A with an append package, and finally apply a full index.
  var ProfileA:=Profile; var ProfileB:=Profile;
  ProfileB.ID:=TCatalogSource.NewID; ProfileB.Name:='Second profile for the same source';
  Require(LoadLibraryUpdateHistory(Target,ProfileA,CacheInfo),'Missing first profile baseline');
  var OlderHistory:=VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_HISTORY));
  FirstCache:=CacheInfo.CacheFile; CacheHash:=THashSHA2.GetHashStringFromFile(FirstCache);
  Require(FindDisplayBook('202',Book),'Missing shared-source original publication');
  Target.SetRate(Book.BookKey,2); Target.SetProgress(Book.BookKey,23);
  Target.SetAnnotation(Book.BookKey,'Keep cross-profile annotation');
  Archive(DownloadRoot,'next.zip',['202','203','204','205']);
  Index(IndexName,['base','next','next','next'],['201','202','203','204'],
    ['Returned lower copy','Corrected through B','Removed through B','Retained through B']);
  Profile:=ProfileB; OpenReview;
  try Apply(True);
    Require(FindDisplayBook('203',Book),'Second profile did not add its actual publication'); RequireBody(Book,'203');
    Require(FindDisplayBook('204',Book),'Second profile lost its other new publication'); RequireBody(Book,'204');
  finally CloseReview; end;
  Require(FindDisplayBook('203',Book),'Cannot remove the second-profile publication'); Target.DeleteBook(Book.BookKey);
  Index(IndexName,['base','next','next'],['201','202','204'],
    ['Returned lower copy','Corrected through B','Retained through B']);
  OpenReview; try Apply(True); finally CloseReview; end;
  // Migrate the earlier v1 layout, which kept stale per-profile entries.
  var LegacyHistory:=TJSONObject.ParseJSONValue(OlderHistory) as TJSONObject;
  var LatestHistory:=TJSONObject.ParseJSONValue(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_HISTORY))) as TJSONObject;
  try
    Require(Assigned(LegacyHistory) and Assigned(LatestHistory),'Invalid shared history fixture');
    for var Entry in LatestHistory.GetValue<TJSONArray>('sources') do
      LegacyHistory.GetValue<TJSONArray>('sources').AddElement(Entry.Clone as TJSONValue);
    Target.SetProperty(PROP_LIBRARY_UPDATE_HISTORY,LegacyHistory.ToJSON);
  finally LegacyHistory.Free; LatestHistory.Free; end;
  // Removing a delivery profile must not erase its source's applied state.
  var RemainingProfiles:TLibraryUpdateSources; SetLength(RemainingProfiles,1); RemainingProfiles[0]:=ProfileA;
  Target.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(RemainingProfiles));
  Profile:=ProfileA; Profile.Full:=False;
  Index(IndexName,['next'],['205'],['Appended through A']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('204',Book),'Switching profiles dropped a live publication'); Target.DeleteBook(Book.BookKey);
  Index(IndexName,['base','next','next','next','next'],['201','202','203','204','205'],
    ['Returned lower copy','Corrected through B','Removed through B','Retained through B','Appended through A']);
  Profile.Full:=True; OpenReview;
  try Apply(True);
    Require(not FindDisplayBook('203',Book),'Switching profiles forgot the other profile''s exclusion after an omitted index');
    Require(not FindDisplayBook('204',Book),'Appending through an older profile lost the latest source baseline');
    Require(FindDisplayBook('205',Book),'Full update lost the appended publication'); RequireBody(Book,'205');
    Require(FindDisplayBook('202',Book) and (Book.Title='Corrected through B') and (Book.Rate=2) and
      (Book.Progress=23) and (Book.Annotation='Keep cross-profile annotation'),'Profile switch changed retained metadata or personal fields');
    Require(THashSHA2.GetHashStringFromFile(FirstCache)=CacheHash,'Profile switching overwrote the old immutable cache');
  finally CloseReview; end;
  Require(LoadLibraryUpdateHistory(Target,Profile,CacheInfo),'Missing latest shared-source baseline');
  var HeldCache:=CacheInfo.CacheFile+'.fixture-hold';
  Require(FileExists(CacheInfo.CacheFile) and not FileExists(HeldCache),'Unsafe shared-source cache fixture path');
  TFile.Move(CacheInfo.CacheFile,HeldCache);
  try
    Profile:=ProfileB; Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
    Review:=TLibraryUpdateReview.Create(Profile,Stage); Worker:=CreateLibraryReviewWorker(ID,Review);
    try
      Worker.Start; Worker.WaitFor;
      Require(Assigned(Worker.FatalException) and not Review.Ready and not Worker.CommittedChanges and
        Exception(Worker.FatalException).Message.Contains('Сохранённый индекс обновления недоступен'),
        'An unavailable shared baseline silently fell back to a stale profile or the live catalogue');
    finally Worker.Free; end;
  finally CloseReview; TFile.Move(HeldCache,CacheInfo.CacheFile); end;
  // Reusing a delivery profile for a different source retains the old source's
  // authority. Keep the invented second binding inside a rolled-back fixture.
  var RetainedCache:=CacheInfo.CacheVersion; var ReboundProfile:=ProfileA;
  ReboundProfile.CatalogSourceID:=TCatalogSource.NewID;
  var ReboundSource:=CacheInfo; ReboundSource.ID:=ReboundProfile.CatalogSourceID;
  ReboundSource.CacheVersion:=TCatalogSource.NewID;
  Target.BeginBulkOperation;
  try
    SaveLibraryUpdateHistory(Target,ReboundProfile,ReboundSource,StringOfChar('a',64));
    Require(LoadLibraryUpdateHistory(Target,ProfileB,CacheInfo) and (CacheInfo.CacheVersion=RetainedCache),
      'Rebinding a delivery profile erased the old source baseline');
    Require(LoadLibraryUpdateHistory(Target,ReboundProfile,CacheInfo) and
      (CacheInfo.CacheVersion=ReboundSource.CacheVersion),'Rebound profile did not keep its new independent baseline');
  finally Target.EndBulkOperation(False); end;
  Require(LoadLibraryUpdateHistory(Target,ProfileB,CacheInfo) and (CacheInfo.CacheVersion=RetainedCache),
    'Rolling back the rebinding fixture changed the source baseline');
  Writeln('PASS shared-source profiles use the latest applied baseline across append, omission, deletion and profile removal, retain immutable caches and refuse a missing authoritative baseline');
end;
