{$I CollectionTransferWorkflowTests.inc}

procedure TestTransferReaderHistory(UseUI:Boolean=False; StopFirst:Boolean=False; PrepareStartup:Boolean=False);
const LibraryIDs:array[0..4] of string=('','0','101','file:opaque','flibusta:202');
var Target:IBookCollection; CID:Integer; Books:TArray<TBookRecord>;
  Histories,NoteIDs,BookmarkTexts:TArray<string>; Positions:TArray<Integer>;
  Root,ArchiveName,Destination,Work,SettingsFile,Body,ArchiveSHA:string;
  Capture:TCollectionTransferCatalogue; Plan:TCollectionTransferPlan;
  Journal:TCollectionTransferJournal; Operation:TCollectionTransferOperation;
  Zip:TZipFile; Store:TReaderAnnotations;

  procedure WaitReader(Reader:TfrmBuiltinReader);
  begin
    var Deadline:=GetTickCount64+20000;
    repeat Application.ProcessMessages; CheckSynchronize(5);
    until (Reader.LoadFinished and not Reader.PageLoading) or (GetTickCount64>=Deadline);
    Require(Reader.Ready and not Reader.PageLoading,'Transferred Reader failed: '+Reader.ReaderStatus.Caption);
  end;

  procedure ReadBook(Index:Integer; BeforeMove:Boolean);
  var Reader:TfrmBuiltinReader; Note:TReaderAnnotation;
  begin
    Writeln('TRACE transfer Reader book ',Index,' before=',BeforeMove); Flush(Output);
    var Prepared:=PrepareReaderFile(Books[Index],True);
    Require(THashSHA2.GetHashStringFromFile(Prepared)=THashSHA2.GetHashString(Body),
      'Reader preparation changed the selected transfer payload');
    Reader:=TfrmBuiltinReader.Create(nil);
    try
      Reader.Show; Reader.OpenBook(Prepared,Books[Index].Title,ReaderHistoryName(Books[Index],''),SettingsFile,'');
      WaitReader(Reader);
      if BeforeMove then
      begin
        Reader.GoToPosition(1000+Index*137); WaitReader(Reader);
        Positions[Index]:=Reader.TextPosition; Require(Positions[Index]>0,'Reader did not leave the first page');
        Reader.AddBookmark('Transfer bookmark '+IntToStr(Index));
        BookmarkTexts[Index]:=Reader.BookmarkContext(0);
        Require(BookmarkTexts[Index]<>'','Reader bookmark context was not saved');
        Note:=Reader.AnnotationDraft(''); Note.Title:='Transfer note '+IntToStr(Index);
        Note.Text:='Сохранить заметку ё '+IntToStr(Index);
        NoteIDs[Index]:=Store.Put(Note);
      end
      else
      begin
        Require(Reader.TextPosition=Positions[Index],'Transfer lost actual saved Reader position');
        Require(Reader.BookmarkContext(0)=BookmarkTexts[Index],
          'Transfer lost actual Reader bookmark');
        Reader.GoToPosition(0); Reader.GoToBookmark(0); WaitReader(Reader);
        Require(Reader.TextPosition=Positions[Index],'Transferred Reader bookmark opens a different position');
        var Notes:=Reader.AnnotationItems(False);
        Require(Length(Notes)=2,'Transferred Reader must show both its note and bookmark');
        var SavedNote:=Default(TReaderAnnotation); var Matches:=0;
        for var Item in Notes do if Item.ID=NoteIDs[Index] then begin SavedNote:=Item; Inc(Matches); end;
        Require((Matches=1) and (SavedNote.Text='Сохранить заметку ё '+IntToStr(Index)),
          'Transfer lost actual Reader annotation');
        var Found:TBookRecord;
        Require(FindReaderNoteBook(SystemDB,SettingsFile,SavedNote,CID,Found) and
          Found.BookKey.IsSameAs(Books[Index].BookKey),'Moved note did not resolve after the title changed');
      end;
      Reader.Close;
    finally Reader.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Reader transfer fixture requires G:');
  Root:=Settings.AppPath+'reader-transfer-source'; ArchiveName:=Root+'\books.zip';
  Destination:=Settings.AppPath+'reader-transfer-destination'; Work:=Settings.AppPath+'reader-transfer-work';
  ForceDirectories(Root); ForceDirectories(Destination); ForceDirectories(Work);
  SettingsFile:=Settings.AppPath+'reader-transfer.ini'; Body:='<FictionBook><body><section>';
  for var I:=1 to 500 do Body:=Body+'<p>Текст перенесённой книги ё '+IntToStr(I)+' сохраняется без изменений.</p>';
  Body:=Body+'</section></body></FictionBook>';
  CID:=SystemDB.CreateCollection('Reader transfer',Root,Root+'\reader.hlc2',CT_EXTERNAL_LOCAL_FB,
    Settings.AppPath+'genres_fb2.glst');
  Target:=SystemDB.GetCollection(CID);
  SetLength(Books,5); SetLength(Histories,5); SetLength(NoteIDs,5); SetLength(Positions,5); SetLength(BookmarkTexts,5);
  Zip:=TZipFile.Create;
  try
    Zip.Open(ArchiveName,zmWrite);
    for var I:=0 to High(Books) do
    begin
      var Book:=Default(TBookRecord); Book.Title:='До переноса '+IntToStr(I);
      Book.Folder:='books.zip'; Book.FileName:='reader-'+IntToStr(I); Book.FileExt:='.fb2';
      Book.LibID:=LibraryIDs[I];
      TAuthorsHelper.Add(Book.Authors,'Transfer','Reader',''); Book.Lang:='ru';
      Book.Size:=Length(TEncoding.UTF8.GetBytes(Body)); Include(Book.BookProps,bpIsLocal);
      var ID:=Target.InsertBook(Book,False,False); Require(ID>0,'Cannot create Reader transfer fixture');
      Target.GetBookRecord(CreateBookKey(ID,CID),Books[I],False);
      Zip.Add(TEncoding.UTF8.GetBytes(Body),Book.FileName+Book.FileExt);
    end;
    Zip.Close;
  finally Zip.Free; end;
  ArchiveSHA:=THashSHA2.GetHashStringFromFile(ArchiveName);
  Store:=TReaderAnnotations.Create(SettingsFile); Journal:=nil; Capture:=nil; Plan:=nil;
  try
    for var I:=0 to High(Books) do
    begin
      Histories[I]:=ReaderHistoryName(Books[I],''); // Prime the absent-table cache in the actual DAO.
      RegisterReaderNoteBook(SettingsFile,Books[I],''); ReadBook(I,True);
    end;
    Target:=nil; SystemDB.ClearCollectionCache;
    if UseUI then RunTransferWorkflowUI(CID,Destination,Work,StopFirst)
    else
    begin
    Capture:=TCollectionTransferCatalogue.Create(SystemDB.GetCollectionInfo(CID),Settings.SystemFileName[sfSystemDB],Work);
    Plan:=Capture.BuildFilePlan(Destination,Work,TGUID.NewGuid);
    Journal:=TCollectionTransferJournal.Create(Work,Capture,Plan); FreeAndNil(Plan); FreeAndNil(Capture);
    if PrepareStartup then
    begin
      var Registry:=TCollectionTransferRegistry.Create(Journal);
      try Registry.RegisterOperation; finally Registry.Free; end;
      var Proof:=TJSONObject.Create;
      try
        Proof.AddPair('collection',TJSONNumber.Create(CID)); Proof.AddPair('settings',SettingsFile);
        Proof.AddPair('archive',ArchiveName); Proof.AddPair('archive_sha',ArchiveSHA);
        Proof.AddPair('destination',Destination); Proof.AddPair('work',Work);
        var Rows:=TJSONArray.Create; Proof.AddPair('books',Rows);
        for var I:=0 to High(Books) do
        begin
          var Row:=TJSONObject.Create; Rows.Add(Row); Row.AddPair('book',TJSONNumber.Create(Books[I].BookKey.BookID));
          Row.AddPair('history',Histories[I]); Row.AddPair('note',NoteIDs[I]); Row.AddPair('position',TJSONNumber.Create(Positions[I]));
          Row.AddPair('bookmark',BookmarkTexts[I]);
        end;
        TFile.WriteAllText(Settings.AppPath+'transfer-startup-fixture.json',Proof.ToJSON,TEncoding.UTF8);
      finally Proof.Free; end;
      Require(FileExists(ArchiveName),'Preparing the restart moved an original');
      Writeln('PASS prepared pending transfer retains original books and saved Reader data for ordinary startup'); Exit;
    end;
    Operation:=TCollectionTransferOperation.Create(Journal);
    try
      var State:=Operation.Run(nil,nil,True,True,True);
      Require(State.RootsApplied and (State.GroupsDone=State.GroupsTotal) and (State.Originals.Pending=0),
        'Reader transfer did not finish publishing locations and roots');
    finally Operation.Free; end;
    end;
    Require(not FileExists(ArchiveName),'Reader test still has its original archive available');
    SystemDB.ClearCollectionCache; Target:=SystemDB.GetCollection(CID,True);
    for var I:=0 to High(Books) do
    begin
      var Key:=Books[I].BookKey; Target.GetBookRecord(Key,Books[I],False);
      Require(ReaderHistoryName(Books[I],'')=Histories[I],'Actual DAO did not preserve Reader identity');
      var Original:string;
      Require(TryReaderHistoryAlias(Books[I],'',Original)=(I<4),'Unexpected alias for a scoped stable library ID');
      Require(THashSHA2.GetHashStringFromFile(Books[I].GetBookFileName)=ArchiveSHA,'Transferred archive changed');
      Books[I].Title:='После переноса '+IntToStr(I); Target.UpdateBook(Books[I]);
      ReadBook(I,False);
    end;
    var Noted:=ReaderNoteBookIDs(SystemDB,SettingsFile,CID);
    Require(Length(Noted)=Length(Books),'The ordinary books-with-notes filter lost moved books');
    if not UseUI then
    begin
    var Completed:=Journal.CompleteTransfer(function:Boolean begin Result:=not ReaderPreparationsPending(frmMain); end);
    Require((Completed.Files=1) and (Completed.Groups=1) and (Completed.Removed=1) and
      (Completed.Missing=0) and (Completed.Retained=0),'Actual DAO refresh lost cumulative transfer totals');
    Require(Journal.CompleteTransfer(function:Boolean begin Result:=True; end).CompletedAt=Completed.CompletedAt,
      'Completed transfer replay changed its saved completion time');
    Writeln('PASS actual DAO and Reader refresh permit atomic transfer completion with cumulative totals and unchanged replay');
    end
    else Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=0,'UI left a completed transfer pending');
    Writeln('PASS transferred real Reader preserves positions bookmarks notes and changed-title bindings across placeholder numeric opaque and scoped identities');
  finally Journal.Free; Plan.Free; Capture.Free; Store.Free; Target:=nil; end;
end;

procedure TestTransferStartupUI;
begin
  RequireIsolatedRegression;
  var Proof:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'transfer-startup-fixture.json',TEncoding.UTF8)) as TJSONObject;
  var Probe:=TTransferWorkflowProbe.Create;
  try
    Require(Proof<>nil,'Missing startup transfer fixture');
    var CID:=Proof.GetValue<Integer>('collection'); var SettingsFile:=Proof.GetValue<string>('settings');
    Probe.Startup:=True; Probe.DeclineQuestion:=ParamStr(2)='defer'; Probe.Deadline:=GetTickCount64+180000;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=20; Probe.Timer.OnTimer:=Probe.Tick;
    Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
    Application.CreateForm(TfrmMain,frmMain);
    while not Probe.Completed and not Probe.Declined and (Probe.Failure='') and (GetTickCount64<Probe.Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    if Probe.Declined then
    begin
      Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=1,'Later lost the pending transfer');
      Require(THashSHA2.GetHashStringFromFile(Proof.GetValue<string>('archive'))=Proof.GetValue<string>('archive_sha'),
        'Later changed an original');
      Probe.DeclineQuestion:=False;
      var Choice:=TMenuItem.Create(nil);
      try Choice.Tag:=CID; frmMain.miActiveCollectionClick(Choice); finally Choice.Free; end;
      var ReadyUntil:=GetTickCount64+20000;
      while (frmMain.tvBooksA.GetFirst=nil) and (GetTickCount64<ReadyUntil) do
      begin Application.ProcessMessages; CheckSynchronize(5); end;
      TMenuItem(frmMain.FindComponent('miCatalogSources')).Click;
      Writeln('PASS startup Later keeps original books and the pending operation then the ordinary sources command resumes it');
    end;
    Require((Probe.Failure='') and Probe.QuestionSeen and Probe.Completed,'Ordinary startup transfer: '+Probe.Failure);
    Require(Settings.ActiveCollection=CID,'Startup resumed a different collection');
    Require(Length(RegisteredCollectionTransfers(Settings.SystemFileName[sfSystemDB]))=0,'Startup left the completed move pending');
    Require(not FileExists(Proof.GetValue<string>('archive')),'Startup did not release the checked original');
    ExpectTitles(frmMain.tvBooksA,['До переноса 0','До переноса 1','До переноса 2','До переноса 3','До переноса 4']);
    var Target:=SystemDB.GetCollection(CID);
    for var Value in Proof.GetValue<TJSONArray>('books') do
    begin
      var Row:=TJSONObject(Value); var Book:TBookRecord;
      Target.GetBookRecord(CreateBookKey(Row.GetValue<Integer>('book'),CID),Book,False);
      Require(ReaderHistoryName(Book,'')=Row.GetValue<string>('history'),'Startup lost a Reader history alias');
      Require(THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=Proof.GetValue<string>('archive_sha'),'Startup changed an archive');
      var Reader:=TfrmBuiltinReader.Create(nil);
      try
        Reader.Show; Reader.OpenBook(PrepareReaderFile(Book,True),Book.Title,ReaderHistoryName(Book,''),SettingsFile,'');
        var Deadline:=GetTickCount64+20000;
        repeat Application.ProcessMessages; CheckSynchronize(5);
        until (Reader.LoadFinished and not Reader.PageLoading) or (GetTickCount64>=Deadline);
        Require(Reader.Ready and (Reader.TextPosition=Row.GetValue<Integer>('position')),'Startup lost the actual Reader position');
        Require(Reader.BookmarkContext(0)=Row.GetValue<string>('bookmark'),'Startup lost bookmark context');
        var Found:=False;
        for var Note in Reader.AnnotationItems(False) do if Note.ID=Row.GetValue<string>('note') then Found:=True;
        Require(Found,'Startup lost the saved note'); Reader.Close;
      finally Reader.Free; end;
    end;
    Writeln('PASS ordinary startup offers pending transfer explicitly resumes it refreshes Main and restores actual Reader positions bookmarks and notes');
  finally Probe.Timer.Free; Probe.Free; Proof.Free; end;
end;
