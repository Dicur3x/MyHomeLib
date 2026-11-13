// A real private catalogue command prepares its actual durable job. The test
// build can terminate its own process at an existing job stage; the next
// process follows ordinary Main.FormCreate recovery without a test-only resume.

procedure ArmCompressionRecoveryCrash(const Fault, ReportFile: string);
var Report, Receipt, Proof:TJSONObject; Options:TBookCompressionOperationOptions;
    Collection:IBookCollection; FaultStage, CrashFile:string;
    OtherInfo:TCollectionInfo; Collections:ICollectionInfoIterator; OtherPath:string;
begin
{$IFNDEF MHL_COMPRESSION_TEST}
  raise Exception.Create('Compression recovery fixture requires its explicit test build symbol');
{$ELSE}
  Require(MatchText(Fault,['job-published','file-committed','catalogue-committed',
    'personal-committed','completed-published','file-journal-forgotten']),'Unknown recovery crash stage');
  Require(ExpandFileName(ReportFile).StartsWith(Settings.AppPath+'compression-work\',True),
    'Recovery report escaped the private workspace');
  Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportFile,TEncoding.UTF8)) as TJSONObject;
  Require(Assigned(Report),'No actual producer report');
  try
    Receipt:=Report.GetValue<TJSONObject>('receipt');
    Require(Assigned(Receipt),'No candidate receipt before crash');
    Require(SameFileName(Receipt.GetValue<string>('source'),Settings.AppPath+'books\shared.zip'),
      'Recovery source escaped the synthetic fixture');
    Collection:=SystemDB.GetCollection(Receipt.GetValue<Integer>('collection_id'));
    OtherPath:=''; Collections:=SystemDB.GetCollectionInfoIterator;
    while Collections.Next(OtherInfo) do
      if OtherInfo.DisplayName='Two' then OtherPath:=SystemDB.GetCollectionInfo(OtherInfo.ID).DBFileName;
    Collections:=nil;
    Require((OtherPath<>'') and ExpandFileName(OtherPath).StartsWith(Settings.AppPath,True),
      'Missing isolated neighbour catalogue path');
    Options:=Default(TBookCompressionOperationOptions);
    Require(LoadCollectionCompressionPreferences(TPath.Combine(Settings.DataPath,'compression-work.ini'),'',Collection,Options)='',
      'Actual compression command failed to remember its recovery queue');
    Proof:=TJSONObject.Create;
    try
      Proof.AddPair('fault',Fault);
      Proof.AddPair('collection_id',TJSONNumber.Create(Collection.CollectionID));
      Proof.AddPair('source_sha256',Receipt.GetValue<string>('source_sha256'));
      Proof.AddPair('result_sha256',Receipt.GetValue<string>('result_sha256'));
      Proof.AddPair('payloads',TJSONArray(Receipt.GetValue<TJSONArray>('payloads').Clone));
      Proof.AddPair('rows',TJSONArray(Receipt.GetValue<TJSONArray>('rows').Clone));
      for var Row in Receipt.GetValue<TJSONArray>('rows') do
        if (Row.GetValue<Integer>('kind')=0) and (Row.GetValue<string>('member')='one.fb2') then
          Proof.AddPair('progress_book_id',TJSONNumber.Create(Row.GetValue<Integer>('id')));
      Proof.AddPair('work_root',Options.WorkRoot); Proof.AddPair('queue_name',Options.QueueName);
      Proof.AddPair('backup_folder',Options.BackupFolder);
      Proof.AddPair('other_catalogue',OtherPath);
      Proof.AddPair('other_catalogue_sha256',THashSHA2.GetHashStringFromFile(OtherPath));
      TFile.WriteAllText(Settings.AppPath+'compression-recovery-state.json',Proof.ToJSON,TEncoding.UTF8);
    finally Proof.Free; end;
    Settings.SaveSettings;
    FaultStage:=Fault; CrashFile:=Settings.AppPath+'compression-recovery-crash.txt';
    CompressionOperationTestFault:=procedure(Stage:string)
      begin
        if Stage<>FaultStage then Exit;
        TFile.WriteAllText(CrashFile,Stage,TEncoding.UTF8);
        Writeln('TRACE actual compression terminated at ',Stage); Flush(Output);
        if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
      end;
  finally Report.Free; end;
{$ENDIF}
end;

procedure TestCompressionRecoveryStartup;
var Proof:TJSONObject; Options:TBookCompressionOperationOptions;
    Driver:TCompressionCatalogueDriver; Collection:IBookCollection;
    Rows,Payloads:TJSONArray; After,Personal:TBookRecord;
    Started:UInt64; BookID,Found,SelectedCount:Integer; Body:TBytes;
    ExpectedHash, Member, BeforeTwo:string; Node:PVirtualNode; Data:PBookRecord;
begin
  Proof:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'compression-recovery-state.json',TEncoding.UTF8)) as TJSONObject;
  Require(Assigned(Proof),'Missing persisted recovery fixture');
  Driver:=TCompressionCatalogueDriver.Create;
  try
    Require(TFile.ReadAllText(Settings.AppPath+'compression-recovery-crash.txt',TEncoding.UTF8)=Proof.GetValue<string>('fault'),
      'Previous process did not reach the selected crash point');
    Options:=Default(TBookCompressionOperationOptions);
    Options.WorkRoot:=Proof.GetValue<string>('work_root'); Options.QueueName:=Proof.GetValue<string>('queue_name');
    Require(Length(TBookCompressionJob.Pending(CompressionQueueRoot(Options)))=1,'No durable job survived actual termination');
    Collection:=SystemDB.GetCollection(Proof.GetValue<Integer>('collection_id'));
    Require(Settings.ActiveCollection=Collection.CollectionID,'Restart lost the selected collection');
    Require(ExpandFileName(Proof.GetValue<string>('other_catalogue')).StartsWith(Settings.AppPath,True),
      'Neighbour catalogue escaped private runtime');
    BeforeTwo:=THashSHA2.GetHashStringFromFile(Proof.GetValue<string>('other_catalogue'));
    Require(BeforeTwo=Proof.GetValue<string>('other_catalogue_sha256'),'Crash changed another collection');
    Driver.Mode:='recovery'; Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Enabled:=False;
    Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick;
    Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
    // This is the product's startup hook, not a call to Recover from the test.
    Application.CreateForm(TfrmMain,frmMain); frmMain.Show;
    Driver.Timer.Enabled:=True;
    Started:=GetTickCount64;
    while not Driver.ResultSeen and (GetTickCount64-Started<45000) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.ResultSeen and not Driver.OptionsSeen and not Driver.ReviewSeen,
      'Ordinary startup failed to recover an already-approved job: '+Driver.LastStage);
    Require(frmMain.Enabled,'Recovered catalogue is blocked behind another window');
    Require(Length(TBookCompressionJob.Pending(CompressionQueueRoot(Options)))=0,'Normal UI failed to acknowledge recovery');
    Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'books\shared.zip')=Proof.GetValue<string>('result_sha256'),
      'Recovered archive differs from the approved candidate');
    Require(THashSHA2.GetHashStringFromFile(Proof.GetValue<string>('other_catalogue'))=BeforeTwo,'Recovery changed another collection');
    Rows:=Proof.GetValue<TJSONArray>('rows'); Payloads:=Proof.GetValue<TJSONArray>('payloads'); SelectedCount:=0;
    Collection:=SystemDB.GetCollection(Collection.CollectionID,True);
    ShowPage(PAGE_SEARCH); frmMain.btnClearFilterEdits.Click; frmMain.acApplyPreset.Execute;
    for var Row in Rows do
      if Row.GetValue<Integer>('kind')=0 then
      begin
        Inc(SelectedCount); BookID:=Row.GetValue<Integer>('id'); Member:=Row.GetValue<string>('member');
        ExpectedHash:='';
        for var Payload in Payloads do
          if Payload.GetValue<string>('member')=Member then ExpectedHash:=Payload.GetValue<string>('output_sha256');
        Require(ExpectedHash<>'','Selected recovery member lost its output proof');
        Collection.GetBookRecord(CreateBookKey(BookID,Collection.CollectionID),After,True);
        SystemDB.GetBookRecord(After.BookKey,Personal);
        if BookID=Proof.GetValue<Integer>('progress_book_id') then
          Require(Personal.Progress=37,'Recovery lost personal reading progress');
        Body:=TFile.ReadAllBytes(PrepareReaderFile(After,True));
        Require(CompressionBodyHash(Body)=ExpectedHash,'Restart reused the stale Reader cache');
        Require(After.Size=Length(Body),'Recovered catalogue kept the old book size');
        Found:=0; Node:=frmMain.tvBooksSR.GetFirst;
        while Assigned(Node) do
        begin
          Data:=frmMain.tvBooksSR.GetNodeData(Node);
          if Assigned(Data) and (Data^.nodeType=ntBookInfo) and (Data^.BookKey.BookID=BookID) then
          begin Inc(Found); Require(Data^.Size=After.Size,'Visible row differs from recovered catalogue'); end;
          Node:=frmMain.tvBooksSR.GetNext(Node);
        end;
        Require(Found=1,'Recovered selected book disappeared or duplicated in the ordinary list');
      end;
    Require(SelectedCount=2,'Recovery did not verify both selected books');
    Require(Length(TDirectory.GetFiles(Proof.GetValue<string>('backup_folder'),'*.zip'))=1,
      'Recovery lost or duplicated the original backup');
    if Proof.GetValue('preserved_work') is TJSONObject then
    begin
      var Preserved:=Proof.GetValue<TJSONObject>('preserved_work');
      var KeptPath:=Preserved.GetValue<string>('path');
      Require(ExpandFileName(KeptPath).StartsWith(Options.WorkRoot+'\',True),'Preserved sentinel escaped work root');
      Require(FileExists(KeptPath) and (THashSHA2.GetHashStringFromFile(KeptPath)=Preserved.GetValue<string>('sha256')),
        'Recovery removed or modified foreign/live preparation data');
      Require(Length(TDirectory.GetDirectories(Options.WorkRoot,'prepare-*'))=1,'Foreign or live preparation was removed');
      Require(Pos('Рабочая папка:',Driver.ResultNote)>0,'Retained preparation has no cleanup explanation');
    end
    else if Length(TDirectory.GetDirectories(Options.WorkRoot,'prepare-*'))<>0 then
      Driver.RecoveryIssues:=Driver.RecoveryIssues+'Completed recovery retained preparation data. ';
    Require(Driver.RecoveryIssues='','Recovery defects: '+Driver.RecoveryIssues);
    Writeln('PASS actual compression crash and ordinary startup recovery ',Proof.GetValue<string>('fault'));
    Flush(Output);
  finally Driver.Timer.Free; Driver.Free; Proof.Free; end;
end;
