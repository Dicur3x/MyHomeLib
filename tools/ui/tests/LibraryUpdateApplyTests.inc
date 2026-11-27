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
  SevenZipExecutable: string;
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
  procedure Archive7z(const Folder, Name: string; const Numbers: array of string);
  var Args:TArray<string>; Sink:TMemoryStream; Input, FileName:string;
  begin
    ForceDirectories(Folder); Input:=TPath.Combine(Root,'seven-inputs'); ForceDirectories(Input);
    Args:=TArray<string>.Create('a','-t7z','-mx=0','-y',TPath.Combine(Folder,Name));
    for var Number in Numbers do
    begin
      FileName:=TPath.Combine(Input,Number+'.fb2'); TFile.WriteAllText(FileName,XML(Number),TEncoding.UTF8);
      Args:=Args+[FileName];
    end;
    Sink:=TMemoryStream.Create;
    try RunExternalToolToStream(SevenZipExecutable,Args,Sink); finally Sink.Free; end;
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
  procedure MetabibIndex(const Path:string);
  var Text,Number,Arc,Title:string;
  begin
    Text:='{"schema":"metabib.dataset/1","record_schema":"metabib.dataset_record/1","library":"flibusta","records":2,'+
      '"archives":[{"id":"books","name":"books.zip"},{"id":"new","name":"new.zip"}]}';
    for Number in TArray<string>.Create('601','602') do
    begin
      if Number='601' then begin Arc:='books'; Title:='Corrected 601'; end else begin Arc:='new'; Title:='Downloaded 602'; end;
      Text:=Text+sLineBreak+'{"schema":"metabib.dataset_record/1","record":{"library":"flibusta","locator":{"kind":"archive_entry","source":"'+Arc+'","index":0,"book_id":'+Number+'}},'+
        '"artifacts":[{"occurrences":[{"archive":"'+Arc+'","entry":"'+Number+'.fb2","index":0,"uncompressed_size":'+IntToStr(Length(TEncoding.UTF8.GetBytes(XML(Number))))+'}]}],'+
        '"claims":{"bibliographic":{"title":[{"value":"'+Title+'"}],"language":[{"value":"ru"}]},"catalog":{"modified":[{"value":"2026-11-14T00:00:00Z"}]}}}';
    end;
    TFile.WriteAllText(Path,Text,TEncoding.UTF8);
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
  begin
    Review.Free; Review:=nil;
    if Assigned(Stage) then
      Require((Length(TDirectory.GetFiles(Stage.Folder,'*.hlc2*'))=0) and
        (Length(TDirectory.GetFiles(Stage.Folder,'comparison-*.sqlite*'))=0),'Closing a review retained its private database files');
    Stage.Free; Stage:=nil;
  end;
  procedure RejectReview(const Expected: string);
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil);
    Review:=TLibraryUpdateReview.Create(Profile,Stage); Worker:=CreateLibraryReviewWorker(ID,Review);
    try
      Worker.Start; Worker.WaitFor;
      Require(Assigned(Worker.FatalException) and not Review.Ready and not Worker.CommittedChanges and
        Exception(Worker.FatalException).Message.Contains(Expected),'Unavailable input did not fail its read-only review: '+Expected);
    finally Worker.Free; CloseReview; end;
  end;
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
  {$I CollectionTransferEmptyUpdateTests.inc}
  procedure TestReviewedIDReservation;
  var LocalID,ArrivalID:Integer; LocalLib:string;
  begin
    RequireIsolatedRegression;
    Root:=Settings.AppPath+'reviewed-id-reservation'; ForceDirectories(Root);
    OldRoot:=Root+'\old'; DownloadRoot:=Root+'\downloads'; IndexName:=Root+'\publisher.inpx';
    Archive(OldRoot,'books.zip',['101']); Archive(DownloadRoot,'new.zip',['102','103']);
    Index(IndexName,['books','new'],['101','102'],['Kept 101','New 102']);
    ID:=SystemDB.CreateCollection('Reviewed stable IDs',OldRoot,Root+'\target.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Target:=SystemDB.GetCollection(ID); Seed:=Default(TBookRecord);
    Seed.Title:='Original'; Seed.LibID:='101'; Seed.Folder:='books.zip';
    Seed.FileName:='101'; Seed.FileExt:='.fb2';
    BookID:=Target.InsertBook(Seed,False,False); Seed.BookKey:=CreateBookKey(BookID,ID);
    Target.SetRate(Seed.BookKey,4);
    DB:=TSQLiteDatabase.Create(Root+'\target.hlc2');
    try DB.ExecSQL('UPDATE sqlite_sequence SET seq=19 WHERE name=''Books'''); finally DB.Free; end;
    var Own:=Seed; Own.LibID:=NewLocalBookID; LocalLib:=Own.LibID;
    Own.Title:='Manual local book'; Own.Folder:=''; Own.FileName:='own'; Include(Own.BookProps,bpIsLocal);
    TFile.WriteAllText(OldRoot+'\own.fb2',XML('own'),TEncoding.UTF8);
    LocalID:=Target.InsertBook(Own,False,False); Require(LocalID=20,'Local ID gap fixture was not created');
    Target.SetProgress(CreateBookKey(LocalID,ID),63);
    DB:=TSQLiteDatabase.Create(Root+'\target.hlc2');
    try DB.ExecSQL('UPDATE sqlite_sequence SET seq=90 WHERE name=''Books'''); finally DB.Free; end;
    DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
    try
      DB.ExecSQL('INSERT INTO Books(BookID,DatabaseID,LibID,Title,UpdateDate,LibRate,FileName,InsideNo,IsLocal,IsDeleted,Rate,Progress) '+
        'VALUES(120,?,'''',''Retired personal card'',''2026-11-18'',0,''retired'',0,0,0,5,88)',[ID]);
      DB.ExecSQL('INSERT INTO BookGroups(BookID,DatabaseID,GroupID) VALUES(130,?,?)',[ID,FAVORITES_GROUP_ID]);
    finally DB.Free; end;
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed ID reservation';
    Profile.Location:=Root; Profile.IndexFile:='publisher.inpx'; Profile.BooksRoot:=DownloadRoot;
    OpenReview;
    try Apply(True); finally CloseReview; end;
    Require(Target.ResolveBookID('101',0)=BookID,'Full review renumbered the retained published book');
    Require(Target.ResolveBookID(LocalLib,0)=LocalID,'Full review renumbered a manually added book');
    Target.GetBookRecord(CreateBookKey(LocalID,ID),Book,True);
    Require((Book.Progress=63) and (Book.Title='Manual local book') and (bpIsLocal in Book.BookProps),
      'Full review changed local-book fields');
    RequireBody(Book,'own');
    ArrivalID:=Target.ResolveBookID('102',0);
    Require(ArrivalID>130,'New arrival reused a retired personal/group number');
    DB:=TSQLiteDatabase.Create(Root+'\target.hlc2');
    try DB.ExecSQL('UPDATE sqlite_sequence SET seq=200 WHERE name=''Books'''); finally DB.Free; end;
    Index(IndexName,['books','new','new'],['101','102','103'],['Kept 101','New 102','New 103']);
    OpenReview;
    try Apply(True); finally CloseReview; end;
    Require((Target.ResolveBookID('101',0)=BookID) and (Target.ResolveBookID(LocalLib,0)=LocalID) and
      (Target.ResolveBookID('102',0)=ArrivalID) and (Target.ResolveBookID('103',0)>200),
      'Repeated full review lost stable IDs or reused the retired catalogue sequence');
    DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
    try
      Require((DB.QuerySingleInt('SELECT Progress FROM Books WHERE DatabaseID=? AND BookID=120',[ID])=88) and
        (DB.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE DatabaseID=? AND BookID=130',[ID])=1),
        'Full review changed an unrelated retired personal card or group link');
    finally DB.Free; end;
    Writeln('PASS reviewed full imports preserve published and local UUID IDs and allocate beyond retired catalogue personal and group numbers');
  end;
begin
  Stage:=nil; Review:=nil;
  if (ParamStr(1)='transfer-empty-updates') or (ParamStr(1)='transfer-cross-volume-updates') then
    begin TestTransferredEmptyIDs; Exit; end;
  if ParamStr(1)='reviewed-id-reservation' then begin TestReviewedIDReservation; Exit; end;
  SevenZipExecutable:=TPath.Combine(Settings.AppPath,'tools\7zip\7z.exe');
  if not FileExists(SevenZipExecutable) or not FileExists(ExtractFilePath(SevenZipExecutable)+'7z.dll') then
    SevenZipExecutable:=TPath.Combine(Settings.AppPath,'tools\7zip\7za.exe');
  Require(FileExists(SevenZipExecutable),'Library update fixture needs the local 7-Zip command line tool');
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

  // Disconnect only this private fixture's original book root. Its database
  // and saved raw baseline remain available, as with a detached library disk.
  BookID:=Target.ResolveBookID('104',0); Require(BookID>0,'Missing offline-root baseline book');
  Target.SetRate(CreateBookKey(BookID,ID),3); Target.SetProgress(CreateBookKey(BookID,ID),19);
  Require(TPath.GetFullPath(OldRoot).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),True),
    'Offline-root fixture escaped its private workspace');
  TFile.Delete(TPath.Combine(OldRoot,'books.zip')); TDirectory.Delete(OldRoot,False);
  var AvailableProfile:=Profile; Profile.BooksRoot:=''; RejectReview('Исходная папка книг недоступна');
  Profile.BooksRoot:=TPath.Combine(Root,'missing-download-root'); RejectReview('Папка докачанных архивов недоступна');
  Profile:=AvailableProfile;
  Archive(DownloadRoot,'only-new.zip',['105']);
  Index(IndexName,['books','new','new','books','only-new'],['101','102','103','104','105'],
    ['Returned 101','New 102','Awaiting 103','Publisher returned 104','Downloaded with original disk offline']);
  OpenReview;
  try
    Require(Review.Summary.Contains('Исходная папка книг сейчас недоступна') and
      Review.HistoricalMissing.Contains('books.zip') and not Review.NeededArchives.Contains('books.zip'),
      'An offline original root turned historical books into a download request');
    Apply(True);
    Require(not DirectoryExists(OldRoot) and (Target.ResolveBookID('101',0)=0),
      'Offline-root update recreated the old folder or resurrected an excluded book');
    BookID:=Target.ResolveBookID('104',0); Require(BookID>0,'Offline-root update discarded a retained old publication');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require((Book.Rate=3) and (Book.Progress=19) and not FileExists(Book.GetBookFileName),
      'Offline-root update changed old personal fields or invented an available old file');
    BookID:=Target.ResolveBookID('105',0); Require(BookID>0,'Offline-root update did not add the downloaded publication');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require(Book.GetBookFileName.Contains(DownloadRoot),'Offline-root update lost the actual download root'); RequireBody(Book,'105');
  finally CloseReview; end;
  Writeln('PASS reviewed update accepts only new archives with its original book root offline, retains historical cards and personal data, preserves exclusions and rejects unavailable download roots');

  // A missing replacement may retain an existing card. Deleting that card
  // must remain an exclusion when the file returns; a never-added missing book
  // must still be eligible for a later download from the same index.
  BookID:=Target.ResolveBookID('104',0); Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
  var RetainedTitle:=Book.Title;
  Index(IndexName,['books','new','new','books','only-new','only-new','pending'],['101','102','103','104','105','106','107'],
    ['Returned 101','New 102','Awaiting 103','Changed while offline 104','Downloaded with original disk offline',
     'Pending new 106','Still awaiting archive 107']);
  OpenReview;
  try Apply(True);
    BookID:=Target.ResolveBookID('104',0); Require(BookID>0,'Missing replacement discarded its retained card');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require((Book.Title=RetainedTitle) and (Book.Rate=3) and (Book.Progress=19),
      'Missing replacement changed retained metadata or personal fields');
    Require(Target.ResolveBookID('106',0)=0,'Never-downloaded member was added prematurely');
  finally CloseReview; end;
  OpenReview;
  try
    Require(Review.NeededArchives.Contains('books.zip') and Review.NeededArchives.Contains('pending.zip') and
      not Review.NeededArchives.Contains('only-new.zip'),
      'Rechecking the same index lost a pending download or requested an already present archive');
  finally CloseReview; end;
  Target.DeleteBook(CreateBookKey(BookID,ID));
  OpenReview; try Apply(True); finally CloseReview; end;
  OpenReview;
  try
    Require(not Review.NeededArchives.Contains('books.zip') and Review.NeededArchives.Contains('pending.zip'),
      'The download list failed to distinguish a recorded exclusion from a pending book');
  finally CloseReview; end;
  Archive(OldRoot,'books.zip',['101','104']); Archive(DownloadRoot,'only-new.zip',['105','106']);
  OpenReview;
  try Apply(True);
    Require(Target.ResolveBookID('104',0)=0,'A deleted retained card returned after its missing file became available');
    BookID:=Target.ResolveBookID('106',0); Require(BookID>0,'An excluded retained card also excluded a never-added missing publication');
    Target.GetBookRecord(CreateBookKey(BookID,ID),Book,True); RequireBody(Book,'106');
  finally CloseReview; end;
  Writeln('PASS deleted retained cards stay excluded after offline replacement while never-added missing books can arrive later');

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
  Require(TPath.GetFullPath(Sources[1].Root).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),True),
    'Bound offline-root fixture escaped its private workspace');
  TFile.Delete(TPath.Combine(Sources[1].Root,'base.zip')); TDirectory.Delete(Sources[1].Root,False);
  Profile:=ProfileA; Profile.Full:=True; var BoundDownloads:=Profile.BooksRoot;
  Profile.BooksRoot:=''; RejectReview('Исходная папка книг недоступна'); Profile.BooksRoot:=BoundDownloads;
  Archive(DownloadRoot,'offline-new.zip',['206']);
  Index(IndexName,['base','next','next','next','next','offline-new'],['201','202','203','204','205','206'],
    ['Returned lower copy','Corrected through B','Removed through B','Retained through B','Appended through A','Downloaded with source disk offline']);
  OpenReview;
  try
    Require(Review.Summary.Contains('Исходная папка книг сейчас недоступна') and
      (Review.NeededArchives.IndexOf('base.zip')<0),'Offline merged source requested a historical archive');
    Apply(True);
    Require(not DirectoryExists(Sources[1].Root) and not FindDisplayBook('203',Book) and not FindDisplayBook('204',Book),
      'Offline merged source recreated its folder or resurrected excluded publications');
    Require(FindDisplayBook('206',Book),'Offline merged source did not add its downloaded publication'); RequireBody(Book,'206');
    Require(FindDisplayBook('202',Book) and (Book.Rate=2) and (Book.Progress=23) and
      (Book.Annotation='Keep cross-profile annotation'),'Offline merged source changed retained personal fields');
    Target.GetBookRecord(Seed.BookKey,Book,True);
    Require(Book.GetBookFileName.Contains(Sources[0].Root),'Offline merged-source update changed the other source priority');
  finally CloseReview; end;
  Writeln('PASS reviewed bound-source update adds downloaded books with its original root offline and preserves source priorities, personal fields and exclusions');

  // A card from another source must not create a phantom copy when the
  // new source's member is missing. It remains a pending new copy.
  var LowerProfile:=Profile;
  var PreferredIndex:=TPath.Combine(Root,'preferred-new.inpx');
  Archive(Sources[0].Root,'other.zip',['208']);
  Index(PreferredIndex,['base','other'],['201','208'],['Shared book','Preferred 208']);
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Add preferred shared card';
  Profile.Location:=Root; Profile.IndexFile:=TPath.GetFileName(PreferredIndex);
  Profile.CatalogSourceID:=Sources[0].ID; Profile.BooksRoot:=Sources[0].Root;
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('208',Book),'Preferred source did not add the shared-card fixture');
  Target.SetRate(Book.BookKey,4); Target.SetProgress(Book.BookKey,43);
  var Preferred208:=Book.GetBookFileName;
  Profile:=LowerProfile; Profile.Full:=False;
  Index(IndexName,['incoming-lower'],['208'],['Preferred 208']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('208',Book) and SameFileName(Book.GetBookFileName,Preferred208) and
    (Book.Rate=4) and (Book.Progress=43) and (Length(Target.GetCatalogBookCopies(Book.BookKey))=1),
    'A missing new source copy changed the preferred card or registered a phantom copy');
  Archive(DownloadRoot,'incoming-lower.zip',['208']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('208',Book) and SameFileName(Book.GetBookFileName,Preferred208) and
    (Book.Rate=4) and (Book.Progress=43) and (Length(Target.GetCatalogBookCopies(Book.BookKey))=2),
    'A missing new source copy was excluded instead of being added after download');
  RequireBody(Book,'208');
  InputSource:=Default(TMergeSource); InputSource.ID:=Sources[1].ID; InputSource.Root:=Sources[1].Root;
  var LowerKey:='';
  for var CopyBook in Target.GetCatalogBookCopies(Book.BookKey) do
    if CopyBook.GetBookFileName.Contains(DownloadRoot) then LowerKey:=MergeSourceKey(InputSource,CopyBook);
  Require((LowerKey<>'') and (Target.GetCatalogBookID(LowerKey)=Book.BookKey.BookID),'Downloaded lower copy lost its source key');
  var LowerID:=Book.BookKey.BookID;
  var HeldLower:=TPath.Combine(Root,'held-incoming-lower.zip');
  TFile.Move(TPath.Combine(DownloadRoot,'incoming-lower.zip'),HeldLower);
  Index(IndexName,['incoming-lower'],['208'],['Changed while lower copy offline 208']);
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('208',Book) and SameFileName(Book.GetBookFileName,Preferred208) and
    (Book.Rate=4) and (Book.Progress=43) and (Length(Target.GetCatalogBookCopies(Book.BookKey))=2),
    'A missing lower replacement changed another source or lost an existing copy');
  DB:=TSQLiteDatabase.Create(VarToStr(Target.GetProperty(PROP_DATAFILE)));
  try DB.ExecSQL('DELETE FROM CatalogBookCopies WHERE SourceKey=? AND BookID=?',[LowerKey,LowerID]);
    DB.ExecSQL('DELETE FROM CatalogSourceBooks WHERE SourceKey=? AND BookID=?',[LowerKey,LowerID]);
  finally DB.Free; end;
  OpenReview; try Apply(True); finally CloseReview; end;
  TFile.Move(HeldLower,TPath.Combine(DownloadRoot,'incoming-lower.zip'));
  OpenReview; try Apply(True); finally CloseReview; end;
  Require(FindDisplayBook('208',Book) and SameFileName(Book.GetBookFileName,Preferred208) and
    (Book.Rate=4) and (Book.Progress=43) and (Target.GetCatalogBookID(LowerKey)=0) and
    (Length(Target.GetCatalogBookCopies(Book.BookKey))=1),
    'A retained missing lower copy returned after removal or damaged the preferred source'); RequireBody(Book,'208');
  Writeln('PASS missing new copies wait for download without phantom links and removed retained copies stay excluded while another source remains preferred');

  for var AliasCase:=0 to 2 do
  begin
    var BoundAlias:=AliasCase<>0; var AliasName:=IntToStr(AliasCase);
    OldRoot:=TPath.Combine(Root,'seven-old-'+AliasName);
    DownloadRoot:=TPath.Combine(Root,'seven-downloads-'+AliasName);
    Archive7z(OldRoot,'books.7z',['601','603']); Archive7z(DownloadRoot,'new.7z',['602','604']);
    IndexName:=TPath.Combine(Root,'seven-'+AliasName+'.inpx');
    Index(IndexName,['books','books'],['601','603'],['Seed 601','Seed 603']);
    ID:=SystemDB.CreateCollection('ZIP names with actual 7z '+AliasName,OldRoot,
      TPath.Combine(Root,'seven-'+AliasName+'.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Target:=SystemDB.GetCollection(ID); Profile:=TLibraryUpdateSource.NewSource;
    Target.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
    Profile.Name:='ZIP names with 7z '+AliasName;
    Profile.Location:=Root; Profile.IndexFile:=TPath.GetFileName(IndexName); Profile.BooksRoot:=DownloadRoot;
    if BoundAlias then
    begin
      SetLength(Sources,1); Sources[0]:=Default(TCatalogSource); Sources[0].ID:=TCatalogSource.NewID;
      Sources[0].Root:=OldRoot; Sources[0].Name:='Actual 7z source'; Sources[0].INPXFile:=IndexName; Sources[0].LibraryNamespace:='flibusta';
      Refresh:=TCatalogRefreshWorker.Create(Sources[0]);
      try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'7z source preparation failed: '+Refresh.Error);
      finally Refresh.Free; end;
      SaveCatalogSources(Target,Sources); Merge:=TCatalogMergeWorker.CreatePreview(ID,Sources,mpSourcePriority);
      try Merge.Start; Merge.WaitFor; Require(Merge.Success,'7z initial merge preview failed: '+Merge.Error); Plan:=Merge.TakePlan;
      finally Merge.Free; end;
      try
        Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Root,'seven-backup-'+AliasName));
        try Merge.Start; Merge.WaitFor; Require(Merge.Success,'7z initial merge failed: '+Merge.Error);
        finally Merge.Free; end;
      finally Plan.Free; end;
      Target:=SystemDB.GetCollection(ID,True); Profile.CatalogSourceID:=Sources[0].ID;
    end
    else
      for var Number in TArray<string>.Create('601','603') do
      begin
        var Item:=Default(TBookRecord); Item.Title:='Seed '+Number; Item.LibID:=Number;
        Item.FileName:=Number; Item.FileExt:='.fb2'; Item.Folder:='books.zip'; Item.Lang:='ru';
        Item.Date:=EncodeDate(2026,11,14); Item.Size:=Length(TEncoding.UTF8.GetBytes(XML(Number)));
        TAuthorsHelper.Add(Item.Authors,'Author','Test',''); Target.InsertBook(Item,False,False);
      end;
    Index(IndexName,['books','books'],['601','603'],['Corrected 601','Retained 603']);
    OpenReview;
    try Apply(True);
      Require(FindDisplayBook('601',Book) and (Book.Title='Corrected 601') and
        SameText(ExtractFileExt(Book.GetBookFileName),'.7z'),'ZIP-to-7z source links did not update their actual publication');
      RequireBody(Book,'601'); Target.SetRate(Book.BookKey,4); Target.SetProgress(Book.BookKey,29);
    finally CloseReview; end;
    Require(FindDisplayBook('603',Book),'Missing removable 7z publication'); Target.DeleteBook(Book.BookKey);
    Profile.Full:=False; Index(IndexName,['new'],['602'],['Downloaded 602']);
    OpenReview; try Apply(True); finally CloseReview; end;
    Require(LoadLibraryUpdateHistory(Target,Profile,CacheInfo),'7z append did not publish its baseline');
    DB:=TSQLiteDatabase.CreateReadOnly(CacheInfo.CacheFile);
    try
      Require(DB.QuerySingleString('SELECT l.Location FROM LibraryUpdatePublisherLocations l JOIN Books b ON b.BookID=l.BookID WHERE b.LibID=''602''')='new.zip',
        '7z append stored a resolved path or used input IDs instead of cache IDs for the publisher locator');
    finally DB.Free; end;
    Profile.Full:=True;
    Index(IndexName,['books','new'],['601','602'],['Corrected 601','Downloaded 602']);
    OpenReview; try Apply(True); finally CloseReview; end;
    if AliasCase=2 then
    begin
      var MetaName:=TPath.Combine(Root,'previous-metabib.jsonl'); MetabibIndex(MetaName);
      Profile.IndexFile:=TPath.GetFileName(MetaName);
      OpenReview; try Apply(True); finally CloseReview; end;
      Profile.IndexFile:=TPath.GetFileName(IndexName);
    end;
    if BoundAlias then
    begin
      // Simulate the old cache schema with resolved locations but no separate
      // publisher-location table. The original-root alias remains recoverable.
      Require(LoadLibraryUpdateHistory(Target,Profile,CacheInfo),'Missing legacy 7z cache fixture');
      DB:=TSQLiteDatabase.Create(CacheInfo.CacheFile);
      try DB.ExecSQL('DROP TABLE LibraryUpdatePublisherLocations'); finally DB.Free; end;
      var FrozenBytes:=TFile.ReadAllBytes(CacheInfo.INPXFile);
      var BeforeRecovery:=Target.GetCatalogRevision;
      TFile.WriteAllBytes(CacheInfo.INPXFile,FrozenBytes+TEncoding.ASCII.GetBytes('changed frozen index'));
      try RejectReview('Не совпала контрольная сумма прежнего исходного индекса');
      finally TFile.WriteAllBytes(CacheInfo.INPXFile,FrozenBytes); end;
      Require(Target.GetCatalogRevision=BeforeRecovery,'Rejected publisher recovery changed the live catalogue');
{$IFDEF MHL_COMPRESSION_TEST}
      var ReachedRecovery:=False;
      LibraryUpdateTestPoint:=procedure(Stage:string) begin
        if Stage='publisher-recovery-row' then begin ReachedRecovery:=True; raise EAbort.Create('publisher recovery canceled'); end;
      end;
      try RejectReview('publisher recovery canceled'); finally LibraryUpdateTestPoint:=nil; end;
      Require(ReachedRecovery and (Target.GetCatalogRevision=BeforeRecovery),'Canceled prior-index reader changed the catalogue or never reached its import');
{$ENDIF}
    end;
    var SevenOriginal:=TPath.Combine(OldRoot,'books.7z'); var HeldOriginal:=TPath.Combine(Root,'held-'+AliasName+'.7z');
    var SevenHash:=THashSHA2.GetHashStringFromFile(SevenOriginal);
    var NewSevenHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(DownloadRoot,'new.7z'));
    var HeldDownloads:=TPath.Combine(Root,'held-downloads-'+AliasName+'.7z');
    var NewDownloadRoot:=TPath.Combine(Root,'seven-fresh-'+AliasName);
    Archive7z(NewDownloadRoot,'last.7z',['604']);
    Require(TPath.GetFullPath(OldRoot).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),True),'7z root fixture escaped its workspace');
    TFile.Move(SevenOriginal,HeldOriginal); TDirectory.Delete(OldRoot,False);
    Require(TPath.GetFullPath(DownloadRoot).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Root)),True),'Old download fixture escaped its workspace');
    TFile.Move(TPath.Combine(DownloadRoot,'new.7z'),HeldDownloads); TDirectory.Delete(DownloadRoot,False);
    Profile.BooksRoot:=NewDownloadRoot;
    Index(IndexName,['books','books','new','last'],['601','603','602','604'],['Corrected 601','Returned 603','Downloaded 602','Downloaded 604']);
    OpenReview;
    try
      if (Review.NeededArchives.IndexOf('books.zip')>=0) or (Review.ChangedBooks<>0) then
      begin
        Writeln('TRACE 7z comparison bound=',AliasName,' changed=',Review.ChangedBooks,' needed=',Review.NeededArchives.CommaText);
        Writeln(Review.Summary);
        for var ComparisonFile in TDirectory.GetFiles(Stage.Folder,'comparison-*.sqlite') do
        begin
          DB:=TSQLiteDatabase.CreateReadOnly(ComparisonFile);
          try
            var Rows:=DB.NewQuery('SELECT r.BookID,r.Location,r.PublisherLocation,r.Available,p.Location,p.Stamp=r.Stamp,p.Physical=r.Physical,p.State,e.Key IS NOT NULL '+
              'FROM ReviewRows r LEFT JOIN ReviewPrevious p ON p.Key=r.Key LEFT JOIN ReviewExcluded e ON e.Key=r.Key');
            try Rows.Open; while not Rows.Eof do
              begin for var C:=0 to Rows.ColCount-1 do Write(Rows.FieldAsString(C),' | '); Writeln; Rows.Next; end;
            finally Rows.Free; end;
          finally DB.Free; end;
        end;
      end;
      Require((Review.NeededArchives.IndexOf('books.zip')<0) and (Review.NeededArchives.IndexOf('new.zip')<0) and (Review.ChangedBooks=0),
        'An offline 7z alias or excluded publication requested a historical ZIP again');
      Require(Length(TDirectory.GetFiles(Stage.Folder,'publisher-*.hlc2*'))=0,
        'Successful locator recovery retained its large scratch database until confirmation');
      Apply(True);
      Require(not FindDisplayBook('603',Book),'Offline 7z update resurrected an excluded publication');
      Require(FindDisplayBook('604',Book) and Book.GetBookFileName.Contains(NewDownloadRoot),
        'Offline 7z update missed the actual member in its new download root'); RequireBody(Book,'604');
      Require(FindDisplayBook('602',Book) and not FileExists(Book.GetBookFileName),
        'Offline migration lost an old externally downloaded card or invented its file');
      Require(FindDisplayBook('601',Book) and (Book.Rate=4) and (Book.Progress=29) and
        SameText(ExtractFileExt(Book.GetBookFileName),'.7z'),'Offline 7z update lost its retained locator or personal fields');
    finally CloseReview; end;
    OpenReview;
    try Require(Review.ChangedBooks=0,'Repeating the migrated offline index lost publisher locations'); Apply(True);
    finally CloseReview; end;
    ForceDirectories(OldRoot); TFile.Move(HeldOriginal,SevenOriginal);
    ForceDirectories(DownloadRoot); TFile.Move(HeldDownloads,TPath.Combine(DownloadRoot,'new.7z'));
    Require(FindDisplayBook('601',Book),'Reconnecting the 7z root lost its retained publication'); RequireBody(Book,'601');
    Require(FindDisplayBook('602',Book),'Reconnecting the old download root lost its retained publication'); RequireBody(Book,'602');
    Require((THashSHA2.GetHashStringFromFile(SevenOriginal)=SevenHash) and
      (THashSHA2.GetHashStringFromFile(TPath.Combine(DownloadRoot,'new.7z'))=NewSevenHash),'Update rewrote an original or downloaded 7z');
    Require(FindDisplayBook('602',Book),'Missing prior download for retained deletion fixture');
    var KeptDownload:=Book.GetBookFileName; var KeptTitle:=Book.Title;
    Target.SetRate(Book.BookKey,5); Target.SetProgress(Book.BookKey,11);
    TFile.Move(TPath.Combine(DownloadRoot,'new.7z'),HeldDownloads);
    Profile.BooksRoot:=DownloadRoot; Profile.Full:=AliasCase<>2;
    Index(IndexName,['books','books','new','last'],['601','603','602','604'],
      ['Corrected 601','Returned 603','Changed offline download 602','Downloaded 604']);
    OpenReview;
    try Apply(True);
      Require(FindDisplayBook('602',Book) and (Book.Title=KeptTitle) and (Book.Rate=5) and
        (Book.Progress=11) and SameFileName(Book.GetBookFileName,KeptDownload),
        'Missing externally downloaded replacement changed its retained metadata path or personal fields');
    finally CloseReview; end;
    Target.DeleteBook(Book.BookKey);
    OpenReview; try Apply(True); finally CloseReview; end;
    TFile.Move(HeldDownloads,TPath.Combine(DownloadRoot,'new.7z'));
    OpenReview;
    try Apply(True);
      Require(not FindDisplayBook('602',Book),'A deleted retained download returned after its 7z became available');
      Require(FindDisplayBook('604',Book),'Retained exclusion affected a different downloaded publication'); RequireBody(Book,'604');
    finally CloseReview; end;
    Require(THashSHA2.GetHashStringFromFile(TPath.Combine(DownloadRoot,'new.7z'))=NewSevenHash,
      'Retained-card exclusion changed the book archive');
  end;
  Writeln('PASS retained download deletions survive missing 7z restoration in whole bound full and bound append updates');
  Writeln('PASS reviewed ZIP names retain actual 7z source links and publisher locations across offline roots, excluded returns and downloaded 7z members');
  Writeln('PASS legacy publisher locations recover from a verified saved index outside the original root, survive both roots offline and repeat, and reject a changed saved input without touching the catalogue');
  Writeln('PASS publisher recovery reads saved INPX and Metabib independently of the new input format and rolls back canceled recovery imports');
end;
