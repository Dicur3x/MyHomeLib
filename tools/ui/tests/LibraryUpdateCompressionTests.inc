// Real catalogue compression followed by reviewed INPX and incremental work.
procedure TestReviewedCompressedCatalogue(const Collection:IBookCollection;
  const Originals:TArray<TBookRecord>; const OriginalBody:TBytes;
  const SavedOptions:TBookCompressionOperationOptions);
var Current:IBookCollection; Profile:TLibraryUpdateSource; Stage:TStagedLibraryIndex;
  Review:TLibraryUpdateReview; Worker:TCollectionWorker; Probe:TLibraryApplyProbe;
  Root,Input,Downloads,Shared,SharedSHA,History,Backup,HeldBackup,ThirdSHA:string;
  Sizes:TArray<Int64>; Payloads:TArray<string>; Third:TBytes; Book:TBookRecord;
  Options:TBookCompressionOperationOptions; HasThird:Boolean; ThirdSize:Int64;

  function HistoryStamp:string;
  var DB:TSQLiteDatabase; Q:TSQLiteQuery; Text:TStringBuilder; Value:string;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Current.GetProperty(PROP_DATAFILE)));
    Text:=TStringBuilder.Create;
    try
      for var TableName in TArray<string>.Create('HomeLibreBookCompression','HomeLibreCompressionChecks') do
      begin
        // Compare the pre-existing books even after the third member is processed.
        Q:=DB.NewQuery('SELECT * FROM '+TableName+' WHERE Member<>''third.fb2'' ORDER BY FileKey,Member');
        try Q.Open; while not Q.Eof do
          begin for var I:=0 to Q.ColCount-1 do
            begin Value:=Q.FieldAsString(I); Text.Append(Length(Value)).Append(':').Append(Value); end;
            Text.Append(#10); Q.Next;
          end;
        finally Q.Free; end;
      end;
      Result:=THashSHA2.GetHashString(Text.ToString);
    finally Text.Free; DB.Free; end;
  end;
  function ReadHash(const Value:TBookRecord):string;
  var Stream:TStream; Bytes:TBytes; Hash:THashSHA2;
  begin
    Stream:=Value.GetBookStream(True,False);
    try SetLength(Bytes,Stream.Size); if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
      Require(Value.Size=Length(Bytes),'Reviewed update lost the physical compressed payload size');
      Hash:=THashSHA2.Create; Hash.Update(Bytes); Result:=Hash.HashAsString;
    finally Stream.Free; end;
  end;
  procedure CheckRetained;
  var Value,Personal:TBookRecord;
  begin
    Current:=SystemDB.GetCollection(Collection.CollectionID,True);
    for var I:=0 to High(Originals) do
    begin
      var ID:=Current.ResolveBookID(Originals[I].LibID,0); Require(ID>0,'Reviewed update lost a compressed publication');
      Current.GetBookRecord(CreateBookKey(ID,Current.CollectionID),Value,True);
      Require((Value.Size=Sizes[I]) and (ReadHash(Value)=Payloads[I]),'Reviewed update changed compressed payload or size');
      Require(THashSHA2.GetHashStringFromFile(PrepareReaderFile(Value,True))=Payloads[I],
        'Reader cache after reviewed update does not match retained compressed payload');
      if I=0 then
      begin SystemDB.GetBookRecord(Value.BookKey,Personal);
        Require(Personal.Progress=37,'Reviewed compressed update lost personal reading progress'); end;
    end;
    Require(THashSHA2.GetHashStringFromFile(Shared)=SharedSHA,'Reviewed update rewrote the retained compressed archive');
    Require(HistoryStamp=History,'Reviewed update changed or dropped compression history');
  end;
  procedure WriteIndex;
  var Zip:TZipFile; Rows,Line:string;
  begin
    Rows:='';
    for var I:=0 to High(Originals) do
      Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4+Originals[I].Title+#4#4#4+Originals[I].FileName+#4+
        IntToStr(Originals[I].Size)+#4+Originals[I].LibID+#4'0'#4+Copy(Originals[I].FileExt,2,MaxInt)+#4'2026-11-14'#4'ru'+sLineBreak;
    Zip:=TZipFile.Create;
    try Zip.Open(Input,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes('20261115'),'version.info');
      Zip.Add(TEncoding.UTF8.GetBytes(Rows),'books/shared.inp');
      if HasThird then
      begin
        Line:='Author,Test:'#4'prose_contemporary:'#4'New after compression'#4#4#4'third'#4+
          IntToStr(Length(Third))+#4'compression-reviewed-third'#4'0'#4'fb2'#4'2026-11-15'#4'ru';
        Zip.Add(TEncoding.UTF8.GetBytes(Line),'arrived.inp');
      end;
    finally Zip.Free; end;
  end;
  procedure ApplyIndex;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Review:=nil;
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage); Worker:=CreateLibraryReviewWorker(Current.CollectionID,Review);
      try Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise Exception.Create('Compressed review: '+Exception(Worker.FatalException).Message);
        Require(Worker.Success and Review.Ready,'Compressed catalogue review failed');
      finally Worker.Free; end;
      Probe:=TLibraryApplyProbe.Create; Probe.Accept:=True; Worker:=CreateLibraryApplyWorker(Current.CollectionID,Review,False);
      try Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise Exception.Create('Compressed apply: '+Exception(Worker.FatalException).Message);
        Require(Probe.Confirmed and Worker.Success and Worker.CommittedChanges,'Reviewed compressed update did not commit');
      finally Worker.Free; Probe.Free; end;
    finally Review.Free; Stage.Free; end;
    CheckRetained;
  end;
  procedure RunIncremental(ExpectedBooks,ExpectedChecked:Integer);
  var Operation:TBookCompressionOperation; State:TBookCompressionOperationStatus;
    Info:TCollectionInfo; Started:UInt64; Work,Personal:string;
  begin
    Info:=SystemDB.GetCollectionInfo(Current.CollectionID); Work:=Options.WorkRoot;
    Personal:=Settings.SystemFileName[sfSystemDB];
    Operation:=TBookCompressionOperation.Create(Options,
      function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
      begin Result:=BuildCollectionCompressionPlan(Info,Personal,Work,Cancelled,Progress); end);
    try
      Operation.Start; Started:=GetTickCount64;
      repeat Application.ProcessMessages; Sleep(10); State:=Operation.Status;
        if GetTickCount64-Started>90000 then begin Operation.RequestStop; raise Exception.Create('Reviewed incremental compression timed out: '+State.Stage); end;
      until State.Finished;
      Operation.WaitFor;
      Require(State.Error='', 'Reviewed incremental compression: '+State.Error);
      Require((State.BooksTotal=ExpectedBooks) and (State.PreviouslyProcessedBooks=ExpectedChecked),
        Format('Reviewed update selected %d books, skipped %d; expected %d and %d',
          [State.BooksTotal,State.PreviouslyProcessedBooks,ExpectedBooks,ExpectedChecked]));
      Require(State.ChangedFiles=Ord(ExpectedBooks>0),'Incremental compression changed an old archive or missed the new book');
      CheckRetained;
      if ExpectedBooks>0 then
      begin
        var ID:=Current.ResolveBookID('compression-reviewed-third',0); Require(ID>0,'Incremental processing lost its downloaded book');
        Current.GetBookRecord(CreateBookKey(ID,Current.CollectionID),Book,True);
        Require((Book.Size<Length(Third)) and (Book.Size>0),'Downloaded book did not shrink'); ThirdSize:=Book.Size;
        var Cached:=PrepareReaderFile(Book,True);
        Require(TFile.GetSize(Cached)=Book.Size,'Reader kept the old downloaded payload size');
        Require(TFile.ReadAllText(Cached,TEncoding.UTF8).Contains('reviewed-third-text'),
          'Incremental processing lost the downloaded text');
        ThirdSHA:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
        // Refresh the actual main catalogue before acknowledging durable jobs.
        SystemDB.ClearCollectionCache;
        var Other:=SystemDB.CreateCollection('Private refresh witness',Root,TPath.Combine(Root,'refresh-witness.hlc2'),
          CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
        var Choice:=TMenuItem.Create(nil);
        try Choice.Tag:=Other; frmMain.miActiveCollectionClick(Choice);
          Choice.Tag:=Current.CollectionID; frmMain.miActiveCollectionClick(Choice);
        finally Choice.Free; end;
        ShowPage(PAGE_SEARCH); frmMain.btnClearFilterEdits.Click; frmMain.acApplyPreset.Execute;
        var Visible:=False; Started:=GetTickCount64;
        repeat
          Application.ProcessMessages; Sleep(10);
          var Node:=frmMain.tvBooksSR.GetFirst;
          while Assigned(Node) do
          begin var Data:PBookRecord:=frmMain.tvBooksSR.GetNodeData(Node);
            if Assigned(Data) and (Data^.nodeType=ntBookInfo) and (Data^.LibID='compression-reviewed-third') then
              Visible:=Data^.Size=ThirdSize;
            Node:=frmMain.tvBooksSR.GetNext(Node);
          end;
        until Visible or (GetTickCount64-Started>10000);
        Require(Visible,'Main catalogue did not refresh the compressed downloaded size');
      end;
      Operation.AcknowledgeCompletedJobs;
      Require(Length(TBookCompressionJob.Pending(Operation.QueueRoot))=0,'Incremental update left pending jobs after cache refresh');
    finally Operation.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath; Input:=Root+'reviewed-compression.inpx'; Downloads:=Root+'reviewed-downloads'; ForceDirectories(Downloads);
  Current:=SystemDB.GetCollection(Collection.CollectionID,True); HasThird:=False; ThirdSize:=0;
  Shared:=Root+'books\shared.zip'; SharedSHA:=THashSHA2.GetHashStringFromFile(Shared);
  SetLength(Sizes,Length(Originals)); SetLength(Payloads,Length(Originals));
  for var I:=0 to High(Originals) do
  begin
    var ID:=Current.ResolveBookID(Originals[I].LibID,0); Require(ID>0,'Missing initial compressed book');
    Current.GetBookRecord(CreateBookKey(ID,Current.CollectionID),Book,True); Sizes[I]:=Book.Size; Payloads[I]:=ReadHash(Book);
  end;
  History:=HistoryStamp;
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed compressed collection'; Profile.Location:=Root;
  Profile.IndexFile:=TPath.GetFileName(Input); Profile.BooksRoot:=Downloads;
  Options:=SavedOptions; Options.OnlyNew:=True; Options.ReviewResults:=False; Options.BackupOriginals:=False;
  Options.EstimateFirst:=False; Options.WorkRoot:=Root+'reviewed-compression-work'; Options.QueueName:=TGUID.NewGuid.ToString;
  Require(Length(ResolveSelectedCompressionTools(Root,Options))=0,'Incomplete reviewed compression runtime');
  var Backups:=TDirectory.GetFiles(SavedOptions.BackupFolder,'*.zip'); Require(Length(Backups)=1,'Expected one verified private original');
  Backup:=Backups[0]; HeldBackup:=Root+'unavailable-original.held';
  TFile.Move(Backup,HeldBackup);
  try
    WriteIndex; ApplyIndex; ApplyIndex; RunIncremental(0,2);
    Third:=TEncoding.UTF8.GetBytes(TEncoding.UTF8.GetString(OriginalBody).Replace('</body>',
      '<section><p>reviewed-third-text</p></section></body>'));
    Require(TEncoding.UTF8.GetString(Third).Contains('reviewed-third-text'),'Cannot build the private downloaded fixture');
    var Zip:=TZipFile.Create;
    try Zip.Open(TPath.Combine(Downloads,'arrived.zip'),zmWrite); Zip.Add(Third,'third.fb2'); finally Zip.Free; end;
    HasThird:=True; WriteIndex; ApplyIndex;
    var ThirdID:=Current.ResolveBookID('compression-reviewed-third',0); Require(ThirdID>0,'Reviewed INPX did not add its actual downloaded member');
    Current.GetBookRecord(CreateBookKey(ThirdID,Current.CollectionID),Book,True);
    Require((Book.Size=Length(Third)) and Book.GetBookFileName.Contains(Downloads),'Downloaded member lost its actual size or second root');
    PrepareReaderFile(Book,True); RunIncremental(1,2);
    History:=HistoryStamp; ApplyIndex;
    Profile.Full:=False; ApplyIndex;
    Current.GetBookRecord(CreateBookKey(Current.ResolveBookID('compression-reviewed-third',0),Current.CollectionID),Book,True);
    Require((Book.Size=ThirdSize) and (THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=ThirdSHA),
      'Full or append INPX changed the compressed download or replaced its measured size');
    RunIncremental(0,3);
    var HistoryDB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Current.GetProperty(PROP_DATAFILE)));
    try Require(HistoryDB.QuerySingleInt('SELECT count(*) FROM HomeLibreBookCompression WHERE Member=? AND BookSize=? AND OutputSHA256=?',
      ['third.fb2',ThirdSize,ReadHash(Book)])=1,'Index update lost the new compressed payload history');
    finally HistoryDB.Free; end;
    Writeln('PASS reviewed full and append updates retain actual compressed sizes history and Reader payloads without originals and incrementally compress only the new downloaded book');
  finally TFile.Move(HeldBackup,Backup); end;
end;
