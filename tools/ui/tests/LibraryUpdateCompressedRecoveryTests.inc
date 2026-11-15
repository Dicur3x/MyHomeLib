// Real compression precedes the actual update-process termination fixture.
function LibraryRecoveryCompressionHistory(const Collection:IBookCollection):string;
var DB:TSQLiteDatabase; Query:TSQLiteQuery; Text:TStringBuilder;
begin
  DB:=TSQLiteDatabase.CreateReadOnly(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
  Text:=TStringBuilder.Create;
  try
    for var Name in TArray<string>.Create('HomeLibreBookCompression','HomeLibreCompressionChecks',
      'HomeLibreRestoredBookSizes','HomeLibreCompressionImageSets') do
    begin
      if DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=0 then Continue;
      Text.Append(Name);
      Query:=DB.NewQuery('SELECT * FROM '+Name+' ORDER BY 1,2');
      try Query.Open; while not Query.Eof do
        begin for var I:=0 to Query.ColCount-1 do
          begin var Value:=Query.FieldAsString(I); Text.Append(Length(Value)).Append(':').Append(Value); end;
          Text.Append(#10); Query.Next;
        end;
      finally Query.Free; end;
    end;
    Result:=THashSHA2.GetHashString(Text.ToString);
  finally Text.Free; DB.Free; end;
end;

function LibraryRecoveryHasParagraph(const Node:IXMLNode; const Text:string):Boolean;
begin
  Result:=False; if not Assigned(Node) then Exit;
  if (Node.LocalName='p') and (Node.ChildNodes.Count=1) then
  begin
    var Value:=Node.ChildNodes[0];
    if Value.NodeType in [Xml.XMLIntf.ntText,Xml.XMLIntf.ntCData] then
      if VarToStr(Value.NodeValue)=Text then Exit(True);
  end;
  for var I:=0 to Node.ChildNodes.Count-1 do
    if LibraryRecoveryHasParagraph(Node.ChildNodes[I],Text) then Exit(True);
end;

procedure RunLibraryRecoveryCompression(const Collection:IBookCollection; const Root:string;
  OnlyNew:Boolean; ExpectedBooks,ExpectedChecked:Integer);
var Options:TBookCompressionOperationOptions; Info:TCollectionInfo; Personal,Work:string;
  Operation:TBookCompressionOperation; State:TBookCompressionOperationStatus; Started:UInt64;
begin
  Options:=Default(TBookCompressionOperationOptions); Options.Profile:='balanced'; Options.OnlyNew:=OnlyNew;
  Options.WorkRoot:=TPath.Combine(Root,'compression-work'); Options.QueueName:=TGUID.NewGuid.ToString;
  Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Compressed update recovery tools are incomplete');
  Info:=SystemDB.GetCollectionInfo(Collection.CollectionID); Personal:=Settings.SystemFileName[sfSystemDB]; Work:=Options.WorkRoot;
  Operation:=TBookCompressionOperation.Create(Options,
    function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
    begin Result:=BuildCollectionCompressionPlan(Info,Personal,Work,Cancelled,Progress); end);
  try
    Operation.Start; Started:=GetTickCount64;
    repeat Application.ProcessMessages; Sleep(10); State:=Operation.Status;
      if GetTickCount64-Started>90000 then
      begin Operation.RequestStop; raise Exception.Create('Compressed update recovery preparation timed out: '+State.Stage); end;
    until State.Finished;
    Operation.WaitFor; Require(State.Error='','Compressed update recovery operation: '+State.Error);
    Require((State.BooksTotal=ExpectedBooks) and (State.PreviouslyProcessedBooks=ExpectedChecked) and
      (State.ChangedFiles=ExpectedBooks),Format('Compressed recovery selection %d books/%d checked/%d files; expected %d/%d/%d',
        [State.BooksTotal,State.PreviouslyProcessedBooks,State.ChangedFiles,ExpectedBooks,ExpectedChecked,ExpectedBooks]));
    SystemDB.ClearCollectionCache; ClearBookCache; Operation.AcknowledgeCompletedJobs;
    Require(Length(TBookCompressionJob.Pending(Operation.QueueRoot))=0,'Compressed recovery left completed jobs');
  finally Operation.Free; end;
end;

procedure CaptureLibraryRecoveryCompression(const Collection:IBookCollection; const Original:TBookRecord;
  Proof:TJSONObject);
var Members:TJSONArray; Stream:TStream;
begin
  Members:=TJSONArray.Create; Proof.AddPair('compressed_members',Members);
  var Copies:=Collection.GetCatalogBookCopies(Original.BookKey);
  if Length(Copies)=0 then Copies:=TArray<TBookRecord>.Create(Original);
  for var Book in Copies do
  begin
    Stream:=Book.GetBookStream(True,False);
    try
      Require(Assigned(Stream) and (Book.Size=Stream.Size),'Initial compressed recovery size is not measured');
      var Item:=TJSONObject.Create; Members.AddElement(Item);
      Item.AddPair('path',Book.GetBookFileName); Item.AddPair('size',TJSONNumber.Create(Book.Size));
      Item.AddPair('payload_sha256',THashSHA2.GetHashString(Stream));
      Item.AddPair('archive_sha256',THashSHA2.GetHashStringFromFile(Book.GetBookFileName));
    finally Stream.Free; end;
  end;
  Proof.AddPair('compression_history',LibraryRecoveryCompressionHistory(Collection));
end;

procedure VerifyLibraryRecoveryCompression(const Collection:IBookCollection; const Original:TBookRecord;
  Proof:TJSONObject; CheckArchives:Boolean);
var Stream:TStream; Personal:TBookRecord;
begin
  var Expected:=Proof.GetValue<TJSONArray>('compressed_members');
  var Copies:=Collection.GetCatalogBookCopies(Original.BookKey);
  if Length(Copies)=0 then Copies:=TArray<TBookRecord>.Create(Original);
  Require(Length(Copies)=Expected.Count,'Recovery lost a physical compressed source copy');
  for var Book in Copies do
  begin
    var Found:=False;
    for var Item in Expected do
      if SameFileName(Book.GetBookFileName,Item.GetValue<string>('path')) then
      begin
        Require(not Found,'Recovery has duplicate physical compressed paths'); Found:=True;
        Stream:=Book.GetBookStream(True,False);
        try Require(Assigned(Stream) and (Book.Size=Stream.Size) and (Book.Size=Item.GetValue<Int64>('size')) and
          SameText(THashSHA2.GetHashString(Stream),Item.GetValue<string>('payload_sha256')),
          'Recovery changed compressed payload or measured copy size');
        finally Stream.Free; end;
        if CheckArchives then Require(SameText(THashSHA2.GetHashStringFromFile(Book.GetBookFileName),
          Item.GetValue<string>('archive_sha256')),'Update recovery rewrote a compressed archive');
      end;
    Require(Found,'Recovery replaced a retained compressed path');
  end;
  SystemDB.GetBookRecord(Original.BookKey,Personal);
  Require(Personal.Size=Original.Size,'Recovery replaced the measured personal-card size');
  var Prepared:=PrepareReaderFile(Original,True);
  Require(TFile.GetSize(Prepared)=Original.Size,'Recovered Reader file has a different compressed size');
  if CheckArchives then Require(LibraryRecoveryCompressionHistory(Collection)=Proof.GetValue<string>('compression_history'),
    'Update recovery changed retained compression witnesses');
end;
