// Two physical source copies compressed before a reviewed source update.
procedure TestReviewedBoundCompression(const Originals:TArray<TBookRecord>;
  const BackupFolder:string; const SavedOptions:TBookCompressionOperationOptions);
var Root:string; Sources:TCatalogSources; Bodies:TArray<TBytes>; Titles:TArray<string>;
  Target:IBookCollection; ID:Integer; Profile:TLibraryUpdateSource;
  Expected:TDictionary<string,Int64>; Hashes:TDictionary<string,string>;
  Options:TBookCompressionOperationOptions; HasThird:Boolean; ThirdBody:TBytes; Downloads:string;
  BaselineBookIDs,TransferredKeysSHA:string;

  function Find(const Number:string; out Book:TBookRecord):Boolean;
  var It:IBookIterator;
  begin It:=Target.GetBookIterator(bmAll,True); Result:=False;
    while It.Next(Book) do if Book.DisplayLibID=Number then Exit(True); end;
  function PayloadHash(const Book:TBookRecord):string;
  var Stream:TStream;
  begin Stream:=Book.GetBookStream(True,False);
    try Require(Assigned(Stream),'Bound compressed copy is unreadable');
      Require(Book.Size=Stream.Size,Format('Bound update replaced measured copy size %d with payload size %d: %s',
        [Book.Size,Stream.Size,Book.GetBookFileName]));
      Result:=THashSHA2.GetHashString(Stream);
    finally Stream.Free; end;
  end;
  function CurrentIdentitySHA:string;
  begin
    if BaselineBookIDs='' then Exit('');
    var DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(ID).DBFileName);
    var Text:='';
    try
      for var Table in ['Books','CatalogSourceBooks','CatalogBookCopies'] do
      begin
        var Columns:='BookID,SourceKey'; var Order:='SourceKey';
        if Table='Books' then begin Columns:='BookID,LibID'; Order:='BookID'; end;
        var Query:=DB.NewQuery('SELECT '+Columns+' FROM '+Table+' WHERE BookID IN ('+BaselineBookIDs+') ORDER BY '+Order);
        try Query.Open; Text:=Text+#0+Table;
          while not Query.Eof do
          begin Text:=Text+#0+Query.FieldAsString(0)+#1+Query.FieldAsString(1); Query.Next; end;
        finally Query.Free; end;
      end;
    finally DB.Free; end;
    Result:=THashSHA2.GetHashString(Text);
  end;
  procedure WriteIndex(Source:Integer; Correct:Boolean);
  var Zip:TZipFile; Rows,Title:string;
  begin
    Rows:='';
    for var I:=0 to High(Originals) do
    begin
      Title:=Originals[I].Title; if Correct then Title:=Title+' corrected in source '+IntToStr(Source);
      Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4+Title+#4#4#4+Originals[I].FileName+#4+
        IntToStr(Length(Bodies[I]))+#4+IntToStr(1001+I)+#4'0'#4+Copy(Originals[I].FileExt,2,MaxInt)+#4'2026-11-15'#4'ru'+sLineBreak;
    end;
    Zip:=TZipFile.Create;
    try Zip.Open(Sources[Source].INPXFile,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes('20261115'),'version.info'); Zip.Add(TEncoding.UTF8.GetBytes(Rows),'shared.inp');
      if HasThird and (Source=1) then
      begin
        var Line:='Author,Test:'#4'prose_contemporary:'#4'Bound downloaded book'#4#4#4'third'#4+
          IntToStr(Length(ThirdBody))+#4'1003'#4'0'#4'fb2'#4'2026-11-15'#4'ru';
        Zip.Add(TEncoding.UTF8.GetBytes(Line),'arrived.inp');
      end;
    finally Zip.Free; end;
  end;
  procedure CheckCopies(Capture:Boolean);
  var Book,Personal:TBookRecord; Key,Hash:string;
  begin
    Target:=SystemDB.GetCollection(ID,True);
    if TransferredKeysSHA<>'' then Require(CurrentIdentitySHA=TransferredKeysSHA,
      'Post-transfer INPX update changed retained book IDs or source/copy keys');
    for var I:=0 to High(Originals) do
    begin
      Require(Find(IntToStr(1001+I),Book),'Bound update lost a compressed book');
      Require(Book.GetBookFileName.Contains(Sources[0].Root) and (Book.Title=Titles[I]),
        'Lower-source update changed the preferred path or metadata');
      var Copies:=Target.GetCatalogBookCopies(Book.BookKey); Require(Length(Copies)=2,'Bound update lost a physical copy');
      for var CopyBook in Copies do
      begin
        Hash:=PayloadHash(CopyBook); Key:=CopyBook.GetBookFileName+#1+CopyBook.FileName+CopyBook.FileExt;
        if Capture then begin Expected.Add(Key,CopyBook.Size); Hashes.Add(Key,Hash); end
        else Require(Expected.ContainsKey(Key) and (Expected[Key]=CopyBook.Size) and (Hashes[Key]=Hash),
          'Bound update changed a retained compressed copy or its measured size');
      end;
      PayloadHash(Book);
      if I=0 then
      begin
        SystemDB.GetBookRecord(Book.BookKey,Personal);
        Require(Personal.Size=Book.Size,Format('Bound personal card kept size %d instead of physical %d after source update',[Personal.Size,Book.Size]));
        Require((Book.Rate=4) and (Personal.Progress=37) and (Personal.Review='Bound compressed review') and
          (Book.Annotation='Bound compressed annotation'),'Bound compressed update lost personal fields');
      end;
    end;
  end;
  procedure CompressAll(OnlyNew:Boolean; ExpectedBooks,ExpectedChecked,ExpectedFiles:Integer);
  var Info:TCollectionInfo; Work,Personal:string; Operation:TBookCompressionOperation;
    State:TBookCompressionOperationStatus; Started:UInt64; Choice:TMenuItem; Book:TBookRecord;
  begin
    Options.OnlyNew:=OnlyNew;
    Info:=SystemDB.GetCollectionInfo(ID); Work:=Options.WorkRoot; Personal:=Settings.SystemFileName[sfSystemDB];
    Operation:=TBookCompressionOperation.Create(Options,
      function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
      begin Result:=BuildCollectionCompressionPlan(Info,Personal,Work,Cancelled,Progress); end);
    try
      Operation.Start; Started:=GetTickCount64;
      repeat Application.ProcessMessages; Sleep(10); State:=Operation.Status;
        if GetTickCount64-Started>90000 then begin Operation.RequestStop; raise Exception.Create('Bound compression timed out: '+State.Stage); end;
      until State.Finished;
      Operation.WaitFor; Require(State.Error='','Bound compression: '+State.Error);
      Require((State.BooksTotal=ExpectedBooks) and (State.PreviouslyProcessedBooks=ExpectedChecked) and
        (State.ChangedFiles=ExpectedFiles),Format('Bound incremental selection: %d books, %d checked, %d changed files; expected %d/%d/%d',
          [State.BooksTotal,State.PreviouslyProcessedBooks,State.ChangedFiles,ExpectedBooks,ExpectedChecked,ExpectedFiles]));
      Target:=SystemDB.GetCollection(ID,True); Require(Find('1001',Book),'Bound compression lost first book');
      PrepareReaderFile(Book,True); SystemDB.ClearCollectionCache;
      Choice:=TMenuItem.Create(nil);
      try Choice.Tag:=Originals[0].BookKey.DatabaseID; frmMain.miActiveCollectionClick(Choice);
        Choice.Tag:=ID; frmMain.miActiveCollectionClick(Choice);
      finally Choice.Free; end;
      Application.ProcessMessages;
      if HasThird then Require(Find('1003',Book),'Bound arrival disappeared before cache refresh')
      else Require(Find('1001',Book),'Bound first book disappeared before cache refresh');
      PrepareReaderFile(Book,True);
      ShowPage(PAGE_SEARCH); frmMain.btnClearFilterEdits.Click; frmMain.acApplyPreset.Execute;
      var Number:=Book.DisplayLibID; var ExpectedSize:=Book.Size; var Visible:=False; Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; Sleep(10); var Node:=frmMain.tvBooksSR.GetFirst;
        while Assigned(Node) do
        begin var Data:PBookRecord:=frmMain.tvBooksSR.GetNodeData(Node);
          if Assigned(Data) and (Data^.nodeType=ntBookInfo) and (Data^.DisplayLibID=Number) then Visible:=Data^.Size=ExpectedSize;
          Node:=frmMain.tvBooksSR.GetNext(Node);
        end;
      until Visible or (GetTickCount64-Started>10000);
      Require(Visible,'Bound catalogue size did not refresh before acknowledgment');
      Operation.AcknowledgeCompletedJobs;
      Require(Length(TBookCompressionJob.Pending(Operation.QueueRoot))=0,'Bound compression left pending jobs');
    finally Operation.Free; end;
  end;
  procedure ApplyIndex(Reject:Boolean=False);
  var Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview; Worker:TCollectionWorker; Probe:TLibraryApplyProbe;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Review:=nil;
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage); Worker:=CreateLibraryReviewWorker(ID,Review);
      try Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise Exception.Create('Bound compressed review: '+Exception(Worker.FatalException).Message);
        Require(Worker.Success and Review.Ready,'Bound compressed review failed');
      finally Worker.Free; end;
      Probe:=TLibraryApplyProbe.Create; Probe.Accept:=True; Worker:=CreateLibraryApplyWorker(ID,Review,False);
      try Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
        if Reject then
          Require(Probe.Confirmed and Assigned(Worker.FatalException) and not Worker.CommittedChanges and
            Exception(Worker.FatalException).Message.Contains('bound-size-test-fault'),'Personal-size failure did not roll back the bound update')
        else
        begin
          if Assigned(Worker.FatalException) then raise Exception.Create('Bound compressed apply: '+Exception(Worker.FatalException).Message);
          Require(Probe.Confirmed and Worker.Success and Worker.CommittedChanges,'Bound compressed update did not commit');
          if TransferredKeysSHA<>'' then Require(Review.MissingBooks=0,
            'Post-transfer update incorrectly requires old publisher archives: '+Review.MissingDetails);
        end;
      finally Worker.Free; Probe.Free; end;
    finally Review.Free; Stage.Free; end;
  end;
  {$I CollectionTransferBoundUpdateTests.inc}
begin
  RequireIsolatedRegression; Root:=Settings.AppPath+'bound-compressed'; ForceDirectories(Root); HasThird:=False;
  BaselineBookIDs:=''; TransferredKeysSHA:='';
  Downloads:=TPath.Combine(Root,'downloads'); ForceDirectories(Downloads);
  SetLength(Bodies,Length(Originals)); SetLength(Titles,Length(Originals));
  var Backups:=TDirectory.GetFiles(BackupFolder,'*.zip'); Require(Length(Backups)=1,'Missing original fixture backup');
  var Zip:=TZipFile.Create;
  try Zip.Open(Backups[0],zmRead);
    for var I:=0 to High(Originals) do
    begin Zip.Read('books/'+Originals[I].FileName+Originals[I].FileExt,Bodies[I]); Titles[I]:=Originals[I].Title; end;
  finally Zip.Free; end;
  SetLength(Sources,2);
  for var S:=0 to 1 do
  begin
    Sources[S]:=Default(TCatalogSource); Sources[S].ID:=TCatalogSource.NewID; Sources[S].Name:='Compressed source '+IntToStr(S);
    Sources[S].Root:=TPath.Combine(Root,'source-'+IntToStr(S)); ForceDirectories(Sources[S].Root);
    Sources[S].LibraryNamespace:='flibusta'; Sources[S].INPXFile:=TPath.Combine(Sources[S].Root,'source.inpx');
    Zip:=TZipFile.Create;
    try Zip.Open(TPath.Combine(Sources[S].Root,'shared.zip'),zmWrite);
      for var I:=0 to High(Originals) do Zip.Add(Bodies[I],Originals[I].FileName+Originals[I].FileExt);
    finally Zip.Free; end;
    WriteIndex(S,False);
    var Refresh:=TCatalogRefreshWorker.Create(Sources[S]);
    try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Bound compression source setup: '+Refresh.Error); Sources[S]:=Refresh.Source;
    finally Refresh.Free; end;
  end;
  ID:=SystemDB.CreateCollection('Bound compressed fixture',Root,TPath.Combine(Root,'target.hlc2'),
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Target:=SystemDB.GetCollection(ID); SaveCatalogSources(Target,Sources);
  var Merge:=TCatalogMergeWorker.CreatePreview(ID,Sources,mpSourcePriority); var Plan:TCollectionMergePlan:=nil;
  try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Bound compression merge preview: '+Merge.Error); Plan:=Merge.TakePlan;
  finally Merge.Free; end;
  try Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Root,'merge-backup'));
    try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Bound compression merge apply: '+Merge.Error);
    finally Merge.Free; end;
  finally Plan.Free; end;
  Target:=SystemDB.GetCollection(ID,True); var Book:TBookRecord; Require(Find('1001',Book),'Bound fixture did not merge matching books');
  Target.SetRate(Book.BookKey,4); Target.SetProgress(Book.BookKey,37); Target.SetReview(Book.BookKey,'Bound compressed review');
  Target.SetAnnotation(Book.BookKey,'Bound compressed annotation'); Target.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
  Options:=SavedOptions; Options.OnlyNew:=False; Options.ReviewResults:=False; Options.BackupOriginals:=False;
  Options.EstimateFirst:=False; Options.WorkRoot:=TPath.Combine(Root,'work'); Options.QueueName:=TGUID.NewGuid.ToString;
  Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Incomplete bound compression runtime');
  Expected:=TDictionary<string,Int64>.Create; Hashes:=TDictionary<string,string>.Create;
  try
    CompressAll(False,4,0,2); CheckCopies(True);
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed compressed lower source';
    Profile.CatalogSourceID:=Sources[1].ID; Profile.Location:=TPath.GetDirectoryName(Sources[1].INPXFile);
    Profile.IndexFile:=TPath.GetFileName(Sources[1].INPXFile); Profile.BooksRoot:=Sources[1].Root;
    WriteIndex(1,True); ApplyIndex; CheckCopies(False);
    ApplyIndex; CheckCopies(False); Profile.Full:=False; ApplyIndex; CheckCopies(False);
    CompressAll(True,0,4,0); CheckCopies(False);
    if FileExists(Settings.AppPath+'transfer-bound-compression.marker') then MoveBoundFixture;
    ThirdBody:=TEncoding.UTF8.GetBytes(TEncoding.UTF8.GetString(Bodies[0]).Replace('</body>',
      '<section><p>bound-arrival-text</p></section></body>'));
    Require(TEncoding.UTF8.GetString(ThirdBody).Contains('bound-arrival-text'),'Cannot build bound arrival fixture');
    Zip:=TZipFile.Create;
    try Zip.Open(TPath.Combine(Downloads,'arrived.zip'),zmWrite); Zip.Add(ThirdBody,'third.fb2'); finally Zip.Free; end;
    HasThird:=True; Profile.Full:=True; Profile.BooksRoot:=Downloads; WriteIndex(1,True); ApplyIndex; CheckCopies(False);
    Require(Find('1003',Book) and Book.GetBookFileName.Contains(Downloads) and (Book.Size=Length(ThirdBody)),
      'Bound reviewed update missed its new member in the downloads folder'); PrepareReaderFile(Book,True);
    CompressAll(True,1,4,1); CheckCopies(False);
    Require(Find('1003',Book) and (Book.Size>0) and (Book.Size<Length(ThirdBody)), 'Bound downloaded member did not shrink');
    var ThirdSize:=Book.Size; var ThirdArchiveSHA:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
    Require(TFile.ReadAllText(PrepareReaderFile(Book,True),TEncoding.UTF8).Contains('bound-arrival-text'),
      'Bound downloaded text was lost');
    ApplyIndex; CheckCopies(False); Profile.Full:=False; ApplyIndex; CheckCopies(False);
    Require(Find('1003',Book) and (Book.Size=ThirdSize) and
      (THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=ThirdArchiveSHA),'Bound full/append update changed the compressed download');
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed preferred compressed source';
    Profile.CatalogSourceID:=Sources[0].ID; Profile.Location:=TPath.GetDirectoryName(Sources[0].INPXFile);
    Profile.IndexFile:=TPath.GetFileName(Sources[0].INPXFile); Profile.BooksRoot:=Sources[0].Root;
    WriteIndex(0,True);
    Require(Find('1001',Book),'Missing personal-size rollback fixture');
    var FaultDB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
    try FaultDB.ExecSQL('CREATE TRIGGER BoundCompressedSizeFault BEFORE UPDATE OF BookSize ON Books WHEN '+
      'NEW.DatabaseID='+IntToStr(ID)+' AND NEW.BookID='+IntToStr(Book.BookKey.BookID)+' AND NEW.BookSize='+IntToStr(Book.Size)+
      ' AND OLD.BookSize<>NEW.BookSize BEGIN SELECT RAISE(ABORT,''bound-size-test-fault''); END');
    finally FaultDB.Free; end;
    try ApplyIndex(True); CheckCopies(False);
    finally
      FaultDB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
      try FaultDB.ExecSQL('DROP TRIGGER BoundCompressedSizeFault'); finally FaultDB.Free; end;
    end;
    ApplyIndex;
    for var I:=0 to High(Titles) do Titles[I]:=Originals[I].Title+' corrected in source 0';
    CheckCopies(False); CompressAll(True,0,5,0); CheckCopies(False);
    var Favourites:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,ID); var Count:=0;
    while Favourites.Next(Book) do begin Inc(Count); Require(Book.DisplayLibID='1001','Bound compression changed favourite membership'); end;
    Favourites:=nil; Require(Count=1,'Bound compressed updates lost the favourite');
    Writeln('PASS bound reviewed full and append updates preserve actual compressed copy sizes payloads priorities and personal fields');
    Writeln('PASS bound reviewed update incrementally compresses one new download and preserves all five processed physical members across either source');
    Writeln('PASS bound measured-size updates preserve the existing personal card and roll back both stores if the size write fails');
  finally Hashes.Free; Expected.Free; end;
end;
