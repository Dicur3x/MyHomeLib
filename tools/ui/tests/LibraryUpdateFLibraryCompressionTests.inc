// Compose separate-image compression with the real reviewed INPX workers.
procedure TestReviewedFLibraryCompression(const Collection:IBookCollection;
  Manifest:TJSONObject; const SourceRoot:string);
var Current:IBookCollection; Profile:TLibraryUpdateSource;
  Options:TBookCompressionOperationOptions; Expected:TDictionary<string,string>;
  Sizes:TDictionary<string,Int64>; Files,Raw:TDictionary<string,string>; History:string;
  CorrectTitles,SavedIgnore:Boolean;

  function HistoryStamp:string;
  var DB:TSQLiteDatabase; Q:TSQLiteQuery; Text:TStringBuilder;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Current.GetProperty(PROP_DATAFILE)));
    Text:=TStringBuilder.Create;
    try
      for var Name in TArray<string>.Create('HomeLibreBookCompression','HomeLibreCompressionChecks',
        'HomeLibreRestoredBookSizes','HomeLibreCompressionImageSets') do
      begin
        Q:=DB.NewQuery('SELECT * FROM '+Name+' ORDER BY 1,2');
        try Q.Open; while not Q.Eof do
          begin for var I:=0 to Q.ColCount-1 do
            begin var Value:=Q.FieldAsString(I); Text.Append(Length(Value)).Append(':').Append(Value); end;
            Text.Append(#10); Q.Next;
          end;
        finally Q.Free; end;
      end;
      Result:=THashSHA2.GetHashString(Text.ToString);
    finally Text.Free; DB.Free; end;
  end;
  function PreparedSignature(const Entry:TJSONValue; const Book:TBookRecord):string;
  var Text:TStringBuilder; Stream:TStream; Bytes:TBytes; Zip:TZipFile;
    FB2,Original:IXMLFictionBook; Document:TReaderDocument;
  begin
    var Prepared:=PrepareReaderFile(Book,True);
    Require(TFile.GetSize(Prepared)=Book.Size,
      Format('FLibrary measured size %d differs from complete Reader size %d for %s',
        [Book.Size,TFile.GetSize(Prepared),Book.LibID]));
    Text:=TStringBuilder.Create;
    try
      if SameText(Book.FileExt,'.fb2') then
      begin
        Stream:=TFileStream.Create(Prepared,fmOpenRead or fmShareDenyNone);
        try FB2:=LoadFictionBook(Stream); finally Stream.Free; end;
        Stream:=TStringStream.Create(Entry.GetValue<string>('fb2_xml'),TEncoding.UTF8);
        try Original:=LoadFictionBook(Stream); finally Stream.Free; end;
        var Namespace:='http://www.gribuser.ru/xml/fictionbook/2.0';
        Require(FB2.ChildNodes.FindNode('body',Namespace).XML=Original.ChildNodes.FindNode('body',Namespace).XML,
          'Reviewed external compression changed FB2 text');
        Require(FB2.Binary.Count=Entry.GetValue<Integer>('image_count'),'Reviewed FB2 lost external images');
        for var I:=0 to FB2.Binary.Count-1 do
        begin
          var Image:=FB2.Binary[I]; Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Image.Text);
          var Hash:=THashSHA2.Create; Hash.Update(Bytes); Text.Append(Image.ID).Append(Hash.HashAsString);
        end;
        FB2:=nil; Original:=nil;
      end
      else
      begin
        Zip:=TZipFile.Create;
        try
          Zip.Open(Prepared,zmRead);
          Require((Zip.FileNames[0]='mimetype') and (Zip.FileInfo[0].CompressionMethod=0) and
            (Zip.IndexOf('FLibraryImageIndex.json')<0) and
            (Zip.FileCount=Entry.GetValue<TJSONObject>('assets').Count),'Reviewed external EPUB is incomplete');
          for var Asset in Entry.GetValue<TJSONObject>('assets') do
          begin
            var Name:=Asset.JsonString.Value; Require(Zip.IndexOf(Name)>=0,'Reviewed EPUB lost '+Name);
            Zip.Read(Name,Bytes); var Hash:=THashSHA2.Create; Hash.Update(Bytes);
            var Value:=Hash.HashAsString; Text.Append(Name).Append(Value);
            if not Name.StartsWith('OPS/Images/') then
              Require(SameText(Value,Asset.JsonValue.Value),'Reviewed external compression changed EPUB text or structure');
          end;
        finally Zip.Free; end;
      end;
      Document:=TReaderDocument.Create;
      try Document.Load(Prepared);
        Require((Length(Document.PlainText)>1000) and (Document.ImageCount=Entry.GetValue<Integer>('image_count')),
          'Reviewed FLibrary book did not reopen with every image');
      finally Document.Free; end;
      Result:=THashSHA2.GetHashString(Text.ToString);
    finally Text.Free; end;
  end;
  procedure CheckBooks(Capture:Boolean);
  var Book,Personal:TBookRecord; Stream:TStream; Cover:TGraphic;
  begin
    Current:=SystemDB.GetCollection(Collection.CollectionID,True);
    for var Entry in Manifest.GetValue<TJSONArray>('books') do
    begin
      var Number:=Entry.GetValue<string>('id'); var ID:=Current.ResolveBookID(Number,0);
      Require(ID>0,'Reviewed update lost FLibrary book '+Number);
      Current.GetBookRecord(CreateBookKey(ID,Current.CollectionID),Book,True);
      var Title:='FLibrary '+Number; if CorrectTitles then Title:=Title+' corrected';
      Require(Book.Title=Title,'Reviewed update missed FLibrary metadata correction');
      Trace('Reviewed FLibrary member '+Number+' at '+Book.GetBookFileName+' inside '+IntToStr(Book.InsideNo));
      Stream:=Book.GetBookStream(True,False);
      try
        Require(Assigned(Stream),'Reviewed FLibrary member cannot open');
        var Hash:=THashSHA2.GetHashString(Stream);
        if Capture then Raw.Add(Number,Hash)
        else Require(SameText(Hash,Raw[Number]),'Reviewed update changed a compressed FLibrary member '+Number);
      finally Stream.Free; end;
      var Archive:=TMHLZip.Create(Book.GetBookFileName,True,False);
      try
        Stream:=TMemoryStream.Create;
        try Archive.ExtractToStream('neighbor.bin',Stream); Stream.Position:=0;
          Require(SameText(THashSHA2.GetHashString(Stream),Manifest.GetValue<string>('neighbor_sha256')),
            'FLibrary compression changed an unselected neighboring member');
        finally Stream.Free; end;
      finally Archive.Free; end;
      var Signature:=PreparedSignature(Entry,Book);
      if Capture then begin Expected.Add(Number,Signature); Sizes.Add(Number,Book.Size); end
      else Require((Expected[Number]=Signature) and (Sizes[Number]=Book.Size),
        'Reviewed INPX changed restored FLibrary resources or actual size');
      Stream:=Book.GetBookPreviewCoverStream;
      try Require(Assigned(Stream),'Reviewed update lost FLibrary cover '+Number);
        Cover:=CreateGraphicFromStream(Stream);
        try Require(Assigned(Cover) and (Cover.Width=32) and (Cover.Height=24),'Reviewed FLibrary cover cannot decode');
        finally Cover.Free; end;
      finally Stream.Free; end;
      SystemDB.GetBookRecord(Book.BookKey,Personal);
      Require((Personal.Progress=37) and (Personal.Review='Sidecar note '+Number),
        'Reviewed FLibrary update lost personal progress or notes');
    end;
    for var FilePair in Files do
      Require(SameText(UpdateSHA256(FilePair.Key),FilePair.Value),'Reviewed update rewrote FLibrary archives');
    if not Capture then Require(HistoryStamp=History,'Reviewed FLibrary update changed compression history');
  end;
  procedure Compress(OnlyNew:Boolean);
  var Info:TCollectionInfo; Operation:TBookCompressionOperation; State:TBookCompressionOperationStatus;
    Started:UInt64; Personal,Work:string;
  begin
    Options.OnlyNew:=OnlyNew; Info:=SystemDB.GetCollectionInfo(Current.CollectionID);
    Personal:=Settings.SystemFileName[sfSystemDB]; Work:=Options.WorkRoot;
    Operation:=TBookCompressionOperation.Create(Options,
      function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
      begin Result:=BuildCollectionCompressionPlan(Info,Personal,Work,Cancelled,Progress); end);
    try
      Operation.Start; Started:=GetTickCount64;
      repeat Application.ProcessMessages; Sleep(10); State:=Operation.Status;
        if GetTickCount64-Started>120000 then
        begin Operation.RequestStop; raise Exception.Create('FLibrary compression timed out: '+State.Stage); end;
      until State.Finished;
      Operation.WaitFor; Trace('Reviewed FLibrary operation complete '+BoolToStr(OnlyNew,True)); Require(State.Error='','Reviewed FLibrary compression: '+State.Error);
      if OnlyNew then Require((State.BooksTotal=0) and (State.PreviouslyProcessedBooks=4) and (State.ChangedFiles=0),
        Format('Reviewed FLibrary incremental selection: %d books, %d checked',[State.BooksTotal,State.PreviouslyProcessedBooks]))
      else Require((State.BooksTotal=4) and (State.ImageChanges>0) and (State.SavedBytes>0),
        'FLibrary fixture did not actually compress its external pictures');
      // As in the main form, invalidate views before acknowledging. The 7z
      // operation lease intentionally prevents opening a book until then.
      SystemDB.ClearCollectionCache; ClearBookCache;
      Operation.AcknowledgeCompletedJobs;
      Require(Length(TBookCompressionJob.Pending(Operation.QueueRoot))=0,'FLibrary compression left unacknowledged jobs');
      CheckBooks(not OnlyNew);
    finally Operation.Free; end;
  end;
  procedure ApplyIndex;
  var Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview; Worker:TCollectionWorker; Probe:TLibraryApplyProbe;
  begin
    Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.UpdatePath,nil); Review:=nil;
    try
      Review:=TLibraryUpdateReview.Create(Profile,Stage); Worker:=CreateLibraryReviewWorker(Current.CollectionID,Review);
      try Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise Exception.Create('FLibrary review: '+Exception(Worker.FatalException).Message);
        Require(Worker.Success and Review.Ready,'FLibrary INPX review failed');
      finally Worker.Free; end;
      Probe:=TLibraryApplyProbe.Create; Probe.Accept:=True; Worker:=CreateLibraryApplyWorker(Current.CollectionID,Review,False);
      try Worker.OnShowMessage:=Probe.Confirm; Worker.Start; Worker.WaitFor;
        if Assigned(Worker.FatalException) then raise Exception.Create('FLibrary apply: '+Exception(Worker.FatalException).Message);
        Require(Probe.Confirmed and Worker.Success and Worker.CommittedChanges,'FLibrary INPX did not commit');
      finally Worker.Free; Probe.Free; end;
    finally Review.Free; Stage.Free; end;
    CheckBooks(False);
  end;
  procedure WriteIndex;
  var Zip:TZipFile; Rows:TDictionary<string,string>;
  begin
    Rows:=TDictionary<string,string>.Create; Zip:=TZipFile.Create;
    try
      for var Entry in Manifest.GetValue<TJSONArray>('books') do
      begin
        var Name:=ChangeFileExt(Entry.GetValue<string>('archive'),'.inp');
        // Publisher ZIP names resolve to their physically present FLibrary 7z.
        var Number:=Entry.GetValue<string>('id'); var Title:='FLibrary '+Number;
        if CorrectTitles then Title:=Title+' corrected';
        var Row:='Author,Test:'#4'prose_contemporary:'#4+Title+#4#4#4+Number+#4+
          Entry.GetValue<Int64>('size').ToString+#4+Number+#4'0'#4+Copy(Entry.GetValue<string>('ext'),2,MaxInt)+#4'2026-11-15'#4'ru'+sLineBreak;
        var Previous:=''; Rows.TryGetValue(Name,Previous); Rows.AddOrSetValue(Name,Previous+Row);
      end;
      Zip.Open(Profile.LocalFile,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Zip.Add(TEncoding.UTF8.GetBytes('20261115'),'version.info');
      for var Pair in Rows do Zip.Add(TEncoding.UTF8.GetBytes(Pair.Value),Pair.Key);
    finally Zip.Free; Rows.Free; end;
  end;
begin
  RequireIsolatedRegression; Current:=Collection; CorrectTitles:=False;
  SavedIgnore:=Settings.IgnoreAbsentArchives; Settings.IgnoreAbsentArchives:=False;
  Expected:=TDictionary<string,string>.Create; Sizes:=TDictionary<string,Int64>.Create;
  Files:=TDictionary<string,string>.Create; Raw:=TDictionary<string,string>.Create;
  try
    Options:=Default(TBookCompressionOperationOptions); Options.Profile:='balanced'; Options.Grayscale:=True;
    Options.WorkRoot:=Settings.AppPath+'reviewed-sidecars-work'; Options.QueueName:=TGUID.NewGuid.ToString;
    Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'FLibrary compression runtime is incomplete');
    Compress(False);
    for var Pair in Manifest.GetValue<TJSONObject>('files') do
    begin var Path:=TPath.Combine(SourceRoot,Pair.JsonString.Value); Files.Add(Path,UpdateSHA256(Path)); end;
    History:=HistoryStamp;
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Reviewed external FLibrary';
    Profile.Location:=Settings.AppPath; Profile.IndexFile:='reviewed-sidecars.inpx'; Profile.BooksRoot:=SourceRoot;
    WriteIndex; ApplyIndex; ApplyIndex; Compress(True);
    CorrectTitles:=True; WriteIndex; ApplyIndex; Compress(True);
    Profile.Full:=False; ApplyIndex; Compress(True);
    Writeln('PASS FLibrary external JPEG XL covers and pictures survive actual compression reviewed full append and repeated new-only selection with measured sizes text and personal data');
  finally Settings.IgnoreAbsentArchives:=SavedIgnore; Raw.Free; Files.Free; Sizes.Free; Expected.Free; end;
end;
