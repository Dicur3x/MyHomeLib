// Cancel the real list reload after a second physical compression, then let
// Main's recovery hook finish publication without rewriting the approved file.
procedure TestCancelledCompressionRefresh(const Collection:IBookCollection;
  const PreviousBooks:TArray<TBookRecord>);
var Options:TBookCompressionOperationOptions; Info:TCollectionInfo;
    Operation:TBookCompressionOperation; State:TBookCompressionOperationStatus;
    Books:TArray<TBookRecord>; Reloaded:IBookCollection; After,Personal:TBookRecord;
    Driver:TCompressionCatalogueDriver; Started:UInt64;
    Source,SourceSHA,Backup,BackupSHA,PersonalFile,Queue:string;
    Pending:TArray<string>; Proofs:TArray<string>; Node:PVirtualNode; Data:PBookRecord;
    Found:Integer;
begin
  Options:=Default(TBookCompressionOperationOptions);
  Require(LoadCollectionCompressionPreferences(TPath.Combine(Settings.DataPath,'compression-work.ini'),'',
    Collection,Options)='','Missing remembered compression queue');
  Options.Profile:='maximum'; Options.Grayscale:=True; Options.ReviewResults:=False;
  Options.BackupOriginals:=False; Options.EstimateFirst:=False; Options.OnlyNew:=False;
  Require(Length(ResolveSelectedCompressionTools(Settings.AppPath,Options))=0,'Missing second compression tools');
  Queue:=CompressionQueueRoot(Options);
  Require(Length(TBookCompressionJob.Pending(Queue))=0,'Fixture already has a pending job');
  Backup:=TDirectory.GetFiles(Options.BackupFolder,'*.zip')[0];
  BackupSHA:=THashSHA2.GetHashStringFromFile(Backup);
  Source:=Settings.AppPath+'books\shared.zip';
  SourceSHA:=THashSHA2.GetHashStringFromFile(Source);
  Reloaded:=SystemDB.GetCollection(Collection.CollectionID,True);
  SetLength(Books,Length(PreviousBooks));
  for var I:=0 to High(Books) do Reloaded.GetBookRecord(PreviousBooks[I].BookKey,Books[I],True);
  Info:=SystemDB.GetCollectionInfo(Collection.CollectionID);
  PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Operation:=TBookCompressionOperation.Create(Options,
    function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
    begin Result:=BuildSelectedCompressionPlan(Info,PersonalFile,Books,Cancelled,Progress); end);
  // Main owns the operation. Deliberately defer the UI timer until the actual
  // worker has finished; no product fault hook or synthetic exception is used.
  frmMain.StartBookCompression(Operation);
  Started:=GetTickCount64;
  while not Operation.Finished and (GetTickCount64-Started<60000) do Sleep(10);
  Require(Operation.Finished,'Second compression exceeded its deadline');
  State:=Operation.Status;
  Require((State.Error='') and (State.ChangedFiles=1),'Second compression did not publish one archive: '+State.Error);
  Require(THashSHA2.GetHashStringFromFile(Source)<>SourceSHA,'Second compression did not change the source');
  SourceSHA:=THashSHA2.GetHashStringFromFile(Source);
  Pending:=TBookCompressionJob.Pending(Queue);
  Require(Length(Pending)=1,'Completed worker did not retain its unacknowledged job');
  SetLength(Proofs,3); var Names:=TArray<string>.Create('job.json','receipt.json','completed.json');
  for var I:=0 to High(Names) do Proofs[I]:=THashSHA2.GetHashStringFromFile(TPath.Combine(Pending[0],Names[I]));
  PostMessage(frmMain.Handle,WM_KEYDOWN,VK_ESCAPE,0);
  frmMain.BookCompressionTick(nil);
  Require(frmMain.BookListCancelled,'Escape did not cancel the actual post-compression list reload');
  Require(Length(TBookCompressionJob.Pending(Queue))=1,'Canceled list refresh acknowledged the completed journal');
  for var I:=0 to High(Names) do
    Require(THashSHA2.GetHashStringFromFile(TPath.Combine(Pending[0],Names[I]))=Proofs[I],
      'Canceled list refresh changed its durable proof');
  var ResultFound:=False;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmBookCompressionProgress) and Screen.Forms[I].Visible then
    begin
      Require(Pos('Журнал сохранён',TLabel(Screen.Forms[I].FindComponent('CompressionNote')).Caption)>0,
        'Canceled publication did not explain retained recovery');
      Require(TButton(Screen.Forms[I].FindComponent('CompressionStop')).Caption='Закрыть',
        'Cancellation silently started another recovery');
      TButton(Screen.Forms[I].FindComponent('CompressionStop')).Click; ResultFound:=True;
    end;
  Require(ResultFound,'Missing canceled-publication result');
  Writeln('PASS canceled post-compression list refresh retains completed journal and immutable proofs'); Flush(Output);
  Driver:=TCompressionCatalogueDriver.Create;
  try
    Driver.Mode:='recovery'; Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick;
    // Exercise the same hook as ordinary startup, after the canceled result.
    frmMain.CheckCompressionRecovery; Driver.Timer.Enabled:=True;
    Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<45000) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.ResultSeen and not Driver.OptionsSeen and not Driver.ReviewSeen,
      'Recovery hook failed to publish the canceled list refresh: '+Driver.LastStage);
    Require(not frmMain.BookListCancelled,'Successful recovery kept a stale cancellation');
    Require(Length(TBookCompressionJob.Pending(Queue))=0,'Successful list refresh did not acknowledge the job');
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceSHA,'Recovery rewrote the approved archive');
    Require((Length(TDirectory.GetFiles(Options.BackupFolder,'*.zip'))=1) and
      (THashSHA2.GetHashStringFromFile(Backup)=BackupSHA),'Recovery changed the original backup');
    Reloaded:=SystemDB.GetCollection(Collection.CollectionID,True);
    for var I:=0 to High(Books) do
    begin
      Reloaded.GetBookRecord(Books[I].BookKey,After,True); SystemDB.GetBookRecord(Books[I].BookKey,Personal);
      if I=0 then Require(Personal.Progress=37,'Canceled-refresh recovery lost reading progress');
      Require(After.Size=Length(TFile.ReadAllBytes(PrepareReaderFile(After,True))),
        'Canceled-refresh recovery reused stale Reader cache or catalogue size');
      Found:=0; Node:=frmMain.tvBooksSR.GetFirst;
      while Assigned(Node) do
      begin
        Data:=frmMain.tvBooksSR.GetNodeData(Node);
        if Assigned(Data) and (Data^.nodeType=ntBookInfo) and (Data^.BookKey.BookID=After.BookKey.BookID) then
        begin Inc(Found); Require(Data^.Size=After.Size,'Recovered visible row has a stale size'); end;
        Node:=frmMain.tvBooksSR.GetNext(Node);
      end;
      Require(Found=1,'Canceled-refresh recovery lost or duplicated a visible selected book');
    end;
    Writeln('PASS recovery hook acknowledges a successful list refresh without changing approved books or backup');
  finally Driver.Timer.Free; Driver.Free; end;
end;

procedure TestSharedArchiveRefresh(const Collection:IBookCollection; FirstID,SecondID:Integer);
var Options:TBookCompressionOperationOptions; Books:TArray<TBookRecord>; State:TBookCompressionOperationStatus;
    Info:TCollectionInfo; PersonalFile,Queue:string; Operation:TBookCompressionOperation; Started:UInt64;
begin
  SetLength(Books,2);
  for var I:=0 to 1 do
  begin
    Collection.GetBookRecord(CreateBookKey(IfThen(I=0,FirstID,SecondID),Collection.CollectionID),Books[I],True);
    Books[I].Folder:=IfThen(I=0,'books.zip','books.7z');
    Books[I].FileName:=IfThen(I=0,'one','neighbor'); Books[I].FileExt:='.fb2'; Books[I].InsideNo:=0;
    Books[I].Size:=123; Collection.UpdateBook(Books[I]);
  end;
  Require(TryStoreReaderBookProgress(Collection,Books[0],37),'Cannot seed shared-archive reader progress');
  Options:=Default(TBookCompressionOperationOptions);
  Options.WorkRoot:=Settings.AppPath+'compression-work'; Options.Profile:='maximum'; Options.Grayscale:=True;
  Options.ToolsRoot:=Settings.AppPath+'tools'; Options.Python:=Options.ToolsRoot+'\python\python.exe';
  Options.SevenZip:=Options.ToolsRoot+'\7zip\7z.exe'; Options.Script:=Options.ToolsRoot+'\bookconvert\prepare_book_compression.py';
  Queue:=CompressionQueueRoot(Options); Info:=SystemDB.GetCollectionInfo(Collection.CollectionID);
  PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Operation:=TBookCompressionOperation.Create(Options,
    function(const Cancelled:TFunc<Boolean>; const Progress:TProc<Int64>):TBookCompressionPlan
    begin Result:=BuildSelectedCompressionPlan(Info,PersonalFile,Books,Cancelled,Progress); end);
  frmMain.StartBookCompression(Operation);
  Started:=GetTickCount64;
  repeat
    State:=Operation.Status;
    if State.AwaitingRefresh or State.Finished then Break;
    Require(GetTickCount64-Started<90000,'Timed out before shared archive refresh: '+State.Stage);
    Sleep(10);
  until False;
  Require(State.AwaitingRefresh and (State.ChangedFiles=1),'Missing intermediate list refresh: '+State.Error);
  Require(Length(TBookCompressionJob.Pending(Queue))=1,'First result was forgotten before Main refreshed');
  frmMain.BookCompressionTick(nil);
  Started:=GetTickCount64;
  while not Operation.Finished and (GetTickCount64-Started<90000) do Sleep(10);
  State:=Operation.Status;
  Require(State.Finished and (State.ChangedFiles=2) and (State.Error=''),'Second archive did not finish: '+State.Stage+' '+State.Error);
  Require(Length(TBookCompressionJob.Pending(Queue))=1,'Earlier receipt still refers to the changed shared archive');
  frmMain.BookCompressionTick(nil);
  Require(Length(TBookCompressionJob.Pending(Queue))=0,'Main did not acknowledge the second group');
  var Reloaded:=SystemDB.GetCollection(Collection.CollectionID,True);
  for var I:=0 to 1 do
  begin
    var Updated:TBookRecord;
    Reloaded.GetBookRecord(Books[I].BookKey,Updated,True);
    Require((Updated.Size>123) and (Updated.Size=TFile.GetSize(PrepareReaderFile(Updated,True))),
      'Catalogue size differs from the restored book after the shared refresh');
  end;
  var Personal:TBookRecord; SystemDB.GetBookRecord(Books[0].BookKey,Personal);
  Require(Personal.Progress=37,'Shared archive refresh lost reading progress');
  Writeln('PASS Main refreshes before reusing the shared archive, acknowledges both results, and opens both complete books');
end;
