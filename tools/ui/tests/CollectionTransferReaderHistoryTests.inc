procedure TestTransferReaderHistory;
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
    Capture:=TCollectionTransferCatalogue.Create(SystemDB.GetCollectionInfo(CID),Settings.SystemFileName[sfSystemDB],Work);
    Plan:=Capture.BuildFilePlan(Destination,Work,TGUID.NewGuid);
    Journal:=TCollectionTransferJournal.Create(Work,Capture,Plan); FreeAndNil(Plan); FreeAndNil(Capture);
    Operation:=TCollectionTransferOperation.Create(Journal);
    try
      var State:=Operation.Run(nil,nil,True,True,True);
      Require(State.RootsApplied and (State.GroupsDone=State.GroupsTotal) and (State.Originals.Pending=0),
        'Reader transfer did not finish publishing locations and roots');
    finally Operation.Free; end;
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
    var Completed:=Journal.CompleteTransfer(function:Boolean begin Result:=not ReaderPreparationsPending(frmMain); end);
    Require((Completed.Files=1) and (Completed.Groups=1) and (Completed.Removed=1) and
      (Completed.Missing=0) and (Completed.Retained=0),'Actual DAO refresh lost cumulative transfer totals');
    Require(Journal.CompleteTransfer(function:Boolean begin Result:=True; end).CompletedAt=Completed.CompletedAt,
      'Completed transfer replay changed its saved completion time');
    Writeln('PASS actual DAO and Reader refresh permit atomic transfer completion with cumulative totals and unchanged replay');
    Writeln('PASS transferred real Reader preserves positions bookmarks notes and changed-title bindings across placeholder numeric opaque and scoped identities');
  finally Journal.Free; Plan.Free; Capture.Free; Store.Free; Target:=nil; end;
end;
