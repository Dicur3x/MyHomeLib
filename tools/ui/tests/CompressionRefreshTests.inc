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
