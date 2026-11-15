{$I LibraryUpdateCompressedRecoveryTests.inc}

{$IFDEF MHL_COMPRESSION_TEST}
type
  TLibraryRecoveryFault = class
    Phase: string;
    Proof: TJSONObject;
    Review: TLibraryUpdateReview;
    procedure Point(const Stage: string);
    function Confirm(const Text: string; Flags: Longint): Integer;
  end;

function TLibraryRecoveryFault.Confirm(const Text: string; Flags: Longint): Integer;
begin
  Require(Text.Contains('Применить обновление') and ((Flags and MB_DEFBUTTON2)<>0),'Recovery fixture lost its prepared default-No confirmation');
  Result:=IDYES;
end;

procedure TLibraryRecoveryFault.Point(const Stage: string);
begin
  if Stage<>Phase then Exit;
  Proof.AddPair('operation',Review.OperationID);
  TFile.WriteAllText(Settings.AppPath+'library-update-recovery-state.json',Proof.ToJSON,TEncoding.UTF8);
  TFile.WriteAllText(Settings.AppPath+'library-update-recovery-crash.txt',Stage,TEncoding.UTF8);
  Writeln('TRACE actual library update terminated at ',Stage); Flush(Output);
  if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
end;
{$ENDIF}

procedure TestLibraryUpdateRecoveryCrash;
{$IFDEF MHL_COMPRESSION_TEST}
var Root, ArchivePath, OtherFile: string; Bound,Compressed: Boolean; ID, OtherID: Integer;
  PublisherSize:Int64; Body,ImageBody:TBytes;
  Config, Proof: TJSONObject; Target: IBookCollection; Book, Original: TBookRecord;
  Sources: TCatalogSources; Profile: TLibraryUpdateSource; Stage: TStagedLibraryIndex;
  Review: TLibraryUpdateReview; Worker: TCollectionWorker; Fault: TLibraryRecoveryFault;
  Refresh: TCatalogRefreshWorker; Merge: TCatalogMergeWorker; Plan: TCollectionMergePlan; Books: IBookIterator;
  procedure Index(const FileName: string; Updated: Boolean);
  var Zip: TZipFile; Rows: string;
  begin
    if Updated then Rows:='Updated 601' else Rows:='Original 601';
    Rows:='Author,Test:'#4'prose_contemporary:'#4+Rows+#4#4#4'601'#4+IntToStr(PublisherSize)+#4'601'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak;
    if Updated then Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4'New 602'#4#4#4'602'#4+IntToStr(PublisherSize)+#4'602'#4'0'#4'fb2'#4'2026-11-15'#4'ru';
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes(Rows),'books.inp');
    finally Zip.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Config:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'library-update-recovery-request.json',TEncoding.UTF8)) as TJSONObject;
  Require(Assigned(Config),'Missing library recovery configuration');
  Proof:=TJSONObject.Create; Fault:=nil; Review:=nil; Stage:=nil;
  try
    Bound:=Config.GetValue<Boolean>('bound'); Compressed:=Config.GetValue<Boolean>('compressed',False); PublisherSize:=100; Root:=TPath.Combine(Settings.AppPath,'library-recovery'); ForceDirectories(Root);
    ArchivePath:=TPath.Combine(Root,'books.zip');
    if Compressed then
    begin
      var Images:=TZipFile.Create;
      try Images.Open(Settings.AppPath+'books\shared.zip',zmRead); Images.Read('two.fb2',ImageBody);
      finally Images.Free; end;
    end;
    var Zip:=TZipFile.Create;
    try
      Zip.Open(ArchivePath,zmWrite);
      for var Number in TArray<string>.Create('601','602') do
      begin
        if Compressed then
        begin
          Body:=TEncoding.UTF8.GetBytes(TEncoding.UTF8.GetString(ImageBody).Replace('</section>','<p>'+Number+'</p></section>'));
          Require(TEncoding.UTF8.GetString(Body).Contains('<p>'+Number+'</p>'),'Cannot create private compressed recovery paragraph');
          PublisherSize:=Length(Body);
        end
        else Body:=TEncoding.UTF8.GetBytes('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Number+'</p></section></body></FictionBook>');
        Zip.Add(Body,Number+'.fb2');
      end;
    finally Zip.Free; end;
    Index(TPath.Combine(Root,'old.inpx'),False); Index(TPath.Combine(Root,'new.inpx'),True);
    ID:=SystemDB.CreateCollection('Actual update recovery',Root,TPath.Combine(Root,'target.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    OtherID:=SystemDB.CreateCollection('Untouched update neighbour',Root,TPath.Combine(Root,'other.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    OtherFile:=SystemDB.GetCollectionInfo(OtherID).DBFileName;
    Target:=SystemDB.GetCollection(ID);
    if Bound then
    begin
      SetLength(Sources,1); Sources[0]:=Default(TCatalogSource); Sources[0].ID:=TCatalogSource.NewID;
      Sources[0].Name:='Bound recovery source'; Sources[0].Root:=Root;
      Sources[0].INPXFile:=TPath.Combine(Root,'old.inpx'); Sources[0].LibraryNamespace:='flibusta';
      if Compressed then
      begin
        SetLength(Sources,2); Sources[1]:=Sources[0]; Sources[1].ID:=TCatalogSource.NewID;
        Sources[1].Name:='Second compressed recovery source'; Sources[1].Root:=TPath.Combine(Root,'second-source');
        ForceDirectories(Sources[1].Root); TFile.Copy(ArchivePath,TPath.Combine(Sources[1].Root,'books.zip'),False);
      end;
      for var Source in Sources do
      begin
        Refresh:=TCatalogRefreshWorker.Create(Source);
        try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Recovery source preparation failed: '+Refresh.Error);
        finally Refresh.Free; end;
      end;
      SaveCatalogSources(Target,Sources);
      Merge:=TCatalogMergeWorker.CreatePreview(ID,Sources,mpSourcePriority);
      try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Recovery source preview failed: '+Merge.Error); Plan:=Merge.TakePlan;
      finally Merge.Free; end;
      try
        Merge:=TCatalogMergeWorker.CreateApply(Plan,TPath.Combine(Root,'baseline'));
        try Merge.Start; Merge.WaitFor; Require(Merge.Success,'Recovery baseline merge failed: '+Merge.Error);
        finally Merge.Free; end;
      finally Plan.Free; end;
      Target:=SystemDB.GetCollection(ID,True);
    end
    else
    begin
      Book:=Default(TBookRecord); Book.LibID:='601'; Book.FileName:='601'; Book.FileExt:='.fb2';
      Book.Folder:='books.zip'; Book.Title:='Original 601'; Book.Size:=PublisherSize; Book.Lang:='ru';
      TAuthorsHelper.Add(Book.Authors,'Author','Test',''); Target.InsertBook(Book,False,False);
    end;
    Books:=Target.GetBookIterator(bmAll,True); Require(Books.Next(Original),'Recovery baseline is empty'); Books:=nil;
    Target.SetRate(Original.BookKey,4); Target.SetProgress(Original.BookKey,37);
    Target.SetReview(Original.BookKey,'Keep recovery review ё'); Target.SetAnnotation(Original.BookKey,'Keep &lt;literal&gt; annotation');
    Target.AddBookToGroup(Original.BookKey,FAVORITES_GROUP_ID);
    if Compressed then
    begin
      RunLibraryRecoveryCompression(Target,Root,False,IfThen(Bound,2,1),0);
      Target:=SystemDB.GetCollection(ID,True); Target.GetBookRecord(Original.BookKey,Original,True);
      Require(Original.Size<PublisherSize,'Recovery fixture did not actually compress the original book');
      CaptureLibraryRecoveryCompression(Target,Original,Proof);
    end;
    var DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(ID).DBFileName);
    try
      DB.ExecSQL('CREATE TABLE RecoveryGuardProbe(ID TEXT PRIMARY KEY,Payload BLOB,TextValue TEXT,RealValue REAL) WITHOUT ROWID');
      DB.ExecSQL('INSERT INTO RecoveryGuardProbe VALUES(''a'',X''410042'',''A''||char(0)||''B'',0.10000000000000002)');
    finally DB.Free; end;
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Actual recovery update'; Profile.Location:=Root; Profile.IndexFile:='new.inpx';
    if Bound then Profile.CatalogSourceID:=Sources[0].ID;
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Review:=TLibraryUpdateReview.Create(Profile,Stage);
    Worker:=CreateLibraryReviewWorker(ID,Review);
    try
      Worker.Start; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create('Recovery review failed: '+Exception(Worker.FatalException).Message);
      Require(Worker.Success and Review.Ready,'Recovery review is not ready');
    finally Worker.Free; end;
    SystemDB.ClearCollectionCache;
    Proof.AddPair('phase',Config.GetValue<string>('phase')); Proof.AddPair('bound',TJSONBool.Create(Bound));
    Proof.AddPair('compressed',TJSONBool.Create(Compressed));
    Proof.AddPair('collection',TJSONNumber.Create(ID)); Proof.AddPair('original_id',Original.LibID);
    Proof.AddPair('archive',ArchivePath); Proof.AddPair('archive_sha256',THashSHA2.GetHashStringFromFile(ArchivePath));
    Proof.AddPair('index',TPath.Combine(Root,'new.inpx')); Proof.AddPair('index_sha256',THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'new.inpx')));
    Proof.AddPair('other',OtherFile); Proof.AddPair('other_sha256',THashSHA2.GetHashStringFromFile(OtherFile));
    Settings.ActiveCollection:=ID; Settings.SaveSettings;
    Fault:=TLibraryRecoveryFault.Create; Fault.Phase:=Config.GetValue<string>('phase'); Fault.Proof:=Proof; Fault.Review:=Review;
    Worker:=CreateLibraryApplyWorker(ID,Review,False);
    LibraryUpdateTestPoint:=procedure(Value:string) begin Fault.Point(Value); end; MergeApplyTestPoint:=LibraryUpdateTestPoint;
    try
      Worker.OnShowMessage:=Fault.Confirm; Worker.Start; Worker.WaitFor;
      if Assigned(Worker.FatalException) then raise Exception.Create('Recovery update did not reach crash point: '+Exception(Worker.FatalException).Message);
      Require(False,'Actual update did not terminate at '+Fault.Phase);
    finally LibraryUpdateTestPoint:=nil; MergeApplyTestPoint:=nil; Worker.Free; end;
  finally Fault.Free; Review.Free; Stage.Free; Proof.Free; Config.Free; end;
end;
{$ELSE}
begin raise EInvalidOperation.Create('Recovery diagnostics require the guarded test build.'); end;
{$ENDIF}

procedure TestLibraryUpdateRecoveryStartup;
var Proof: TJSONObject; Target: IBookCollection; Book,Original: TBookRecord; Books: IBookIterator;
  Committed, FoundOriginal: Boolean; ID, Count: Integer; Before: string;
begin
  Proof:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'library-update-recovery-state.json',TEncoding.UTF8)) as TJSONObject;
  Require(Assigned(Proof),'Missing persisted update recovery fixture');
  try
    if Assigned(Proof.GetValue('preserve')) then
    begin
      Require(DMUser.LibraryUpdateRecoveryWarnings.Count>0,'Unsafe update recovery did not report its conflict');
      Require(Length(TLibraryUpdateJournal.Pending(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery')))=1,
        'Conflicted recovery discarded its pending journal');
      Require(TLibraryUpdateJournal.HasPendingForCollection(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),
        Proof.GetValue<Integer>('collection')),'Conflicted collection is not protected from another update');
      Writeln('PASS actual library update startup retains conflicting data ',Proof.GetValue<string>('preserve'));
      Exit;
    end;
    Require(DMUser.LibraryUpdateRecoveryWarnings.Count=0,'Ordinary startup update recovery failed: '+DMUser.LibraryUpdateRecoveryWarnings.Text);
    Require(Length(TLibraryUpdateJournal.Pending(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery')))=0,'Startup retained an unresolved update job');
    Require(TFile.ReadAllText(Settings.AppPath+'library-update-recovery-crash.txt',TEncoding.UTF8)=Proof.GetValue<string>('phase'),
      'Previous process did not reach the actual update crash point');
    ID:=Proof.GetValue<Integer>('collection'); Committed:=Proof.GetValue<string>('phase')='stores-committed';
    Target:=SystemDB.GetCollection(ID,True); Books:=Target.GetBookIterator(bmAll,True); Count:=0; FoundOriginal:=False;
    while Books.Next(Book) do
    begin
      Inc(Count);
      if Book.LibID=Proof.GetValue<string>('original_id') then
      begin
        FoundOriginal:=True; Original:=Book;
        if Committed then Require(Book.Title='Updated 601','Completed update lost its metadata')
        else Require(Book.Title='Original 601','Partial update did not restore its original catalogue');
        Require((Book.Rate=4) and (Book.Progress=37) and (Book.Review='Keep recovery review ё') and
          (Book.Annotation='Keep &lt;literal&gt; annotation'),'Recovery changed literal personal data');
      end;
      Require(SameFileName(Book.GetBookFileName,Proof.GetValue<string>('archive')),'Recovered book points to another archive');
      var Member:=Book.FileName; if not SameText(ExtractFileExt(Member),Book.FileExt) then Member:=Member+Book.FileExt;
      var Stream:=Book.GetBookStream(True,False);
      try
        Require(Assigned(Stream),'Recovered book has no readable matching member');
        var Bytes:TBytes; SetLength(Bytes,Stream.Size); if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
        var Document:=LoadXMLData(TEncoding.UTF8.GetString(Bytes));
        var Body:=Document.DocumentElement.ChildNodes.FindNode('body','http://www.gribuser.ru/xml/fictionbook/2.0');
        Require(LibraryRecoveryHasParagraph(Body,TPath.GetFileNameWithoutExtension(Member)),
          'Recovered book does not read its actual matching archive member '+Member);
      finally Stream.Free; end;
    end;
    Books:=nil;
    Require(FoundOriginal,'Recovery lost the original publication identity');
    if Proof.GetValue<Boolean>('compressed',False) then VerifyLibraryRecoveryCompression(Target,Original,Proof,True);
    if Committed then Require(Count=2,'Completed update lost its added book') else Require(Count=1,'Rollback retained an uncommitted added book');
    Books:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,ID);
    Require(Books.Next(Book) and (Book.LibID=Proof.GetValue<string>('original_id')) and not Books.Next(Book),'Recovery changed favourite membership'); Books:=nil;
    var DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(ID).DBFileName);
    try
      var Rows:=DB.NewQuery('SELECT hex(Payload),hex(TextValue) FROM RecoveryGuardProbe WHERE ID=''a''');
      try Rows.Open; Require((Rows.FieldAsString(0)='410042') and (Rows.FieldAsString(1)='410042'),
        'Recovery changed a WITHOUT ROWID table or embedded NUL bytes');
      finally Rows.Free; end;
    finally DB.Free; end;
    for var Name in TArray<string>.Create('archive','index','other') do
      Require(THashSHA2.GetHashStringFromFile(Proof.GetValue<string>(Name))=Proof.GetValue<string>(Name+'_sha256'),
        'Recovery changed protected input '+Name);
    Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
    Application.CreateForm(TfrmMain,frmMain); frmMain.Show; Application.ProcessMessages;
    ShowPage(PAGE_AUTHORS);
    if Committed then ExpectTitles(frmMain.tvBooksA,['Updated 601','New 602']) else ExpectTitles(frmMain.tvBooksA,['Original 601']);
    Before:=VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION));
    var Warnings:=TStringList.Create;
    try
      TLibraryUpdateJournal.RecoverAll(TPath.Combine(Settings.DataPath,'LibraryUpdateRecovery'),
        TPath.Combine(Settings.DataPath,'LibraryUpdateBackups'),Settings.SystemFileName[sfSystemDB],SystemDB,Warnings);
      Require((Warnings.Count=0) and (VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION))=Before),
        'A repeated recovery changed an already acknowledged update');
    finally Warnings.Free; end;
    if Proof.GetValue<Boolean>('compressed',False) then
    begin
      var Previous:=Proof.GetValue<TJSONArray>('compressed_members').Count;
      var WorkRoot:=TPath.Combine(Settings.AppPath,'library-recovery');
      RunLibraryRecoveryCompression(Target,WorkRoot,True,Ord(Committed),Previous);
      Target:=SystemDB.GetCollection(ID,True); Target.GetBookRecord(Original.BookKey,Original,True);
      VerifyLibraryRecoveryCompression(Target,Original,Proof,False);
      RunLibraryRecoveryCompression(Target,WorkRoot,True,0,Previous+Ord(Committed));
      Writeln('PASS compressed source copies recover actual payloads sizes personal cards and witnesses then resume only the unprocessed new book');
    end;
    Writeln('PASS actual library update crash and ordinary startup recovery ',Proof.GetValue<string>('phase'),
      ' bound=',BoolToStr(Proof.GetValue<Boolean>('bound'),True));
  finally Proof.Free; end;
end;
