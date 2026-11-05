type
  TArchiveDeletionUIProbe = class
    Ticks: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure TArchiveDeletionUIProbe.Tick(Sender: TObject);
begin Inc(Ticks); end;

procedure TestArchiveDeletionQueue;
var Root, First, Second, BeforeFirst, BeforeSecond, OwnedWork: string;
  Queue: TArchiveDeletionQueue; Tasks: TArray<TArchiveDeletionTask>;
  Receipts: TArray<TArchiveDeletionResult>; Zip: TZipFile;
  Payload: TBytes; Timer: TTimer; Probe: TArchiveDeletionUIProbe;
  KeepHash: string;
  function Hash(const Bytes:TBytes):string;
  var State:THashSHA2;
  begin State:=THashSHA2.Create; State.Update(Bytes); Result:=State.HashAsString; end;
  procedure Fixture(const Archive: string);
  var Stream:TBytesStream;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Archive,zmWrite); Zip.UTF8Support:=True;
      for var Name in ['selected/one.fb2','selected/two.fb2','unselected/keep.fb2'] do
      begin
        Stream:=TBytesStream.Create(Payload);
        try Zip.Add(Stream,Name,zcStored); finally Stream.Free; end;
      end;
    finally Zip.Free; end;
  end;
  procedure Verify(const Archive: string; Count: Integer);
  var Bytes:TBytes;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Archive,zmRead);
      Require(Zip.FileCount=Count,'Archive queue lost or retained unexpected members');
      Zip.Read('unselected/keep.fb2',Bytes);
      Require(Hash(Bytes)=KeepHash,'Archive queue damaged the retained book');
    finally Zip.Free; end;
  end;
  procedure WaitForQueue(StopDuringWrite: Boolean=False);
  var Started:UInt64; Stopped:Boolean; State:TArchiveDeletionStatus;
  begin
    Started:=GetTickCount64; Stopped:=False;
    repeat
      Application.ProcessMessages;
      State:=Queue.Status;
      if StopDuringWrite and not Stopped and (State.ArchiveIndex=1) and
        (State.Stage='Удаление из архива') and (State.Done>0) and (State.Done<State.Total) then
      begin Queue.StopAfterCurrentArchive; Stopped:=True; end;
      if GetTickCount64-Started>30000 then
      begin Queue.StopAfterCurrentArchive; raise Exception.Create('Owned archive queue exceeded its guard'); end;
      if not State.Finished then Sleep(1);
    until State.Finished;
    Queue.WaitFor;
    if StopDuringWrite then Require(Stopped,'Archive queue was not stopped during a payload write');
  end;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'archive-delete-queue\'; ForceDirectories(Root);
  First:=Root+'same-archive.zip'; Second:=Root+'another-archive.zip';
  SetLength(Payload,12*1024*1024+31);
  for var I:=0 to High(Payload) do Payload[I]:=Byte((I*13+17) mod 251);
  KeepHash:=Hash(Payload);
  SetLength(Tasks,2);
  Tasks[0].Archive:=First; Tasks[0].Members:=TArray<string>.Create('selected/one.fb2','selected/two.fb2');
  Tasks[0].CatalogueBinding:='{"collection":5,"books":[71,72],"source":"FLibrary test"}';
  Tasks[1].Archive:=Second; Tasks[1].Members:=TArray<string>.Create('selected/one.fb2');
  Tasks[1].CatalogueBinding:='{"collection":5,"books":[73],"source":"FLibrary test"}';
  Probe:=TArchiveDeletionUIProbe.Create; Timer:=TTimer.Create(nil);
  Timer.Interval:=1; Timer.OnTimer:=Probe.Tick;
  try
    Fixture(First); Fixture(Second);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    try
      OwnedWork:=Queue.WorkDirectory; Queue.Start; WaitForQueue;
      Receipts:=Queue.Results;
      for var Receipt in Receipts do
        Writeln('TRACE archive queue verified=',Receipt.FilesVerified,' error=',Receipt.Error);
      Flush(Output);
      Require((Length(Receipts)=2) and Receipts[0].FilesVerified and Receipts[1].FilesVerified,
        'Grouped deletion did not finish both archive tasks');
      Require(Probe.Ticks>2,'Archive worker blocked UI message processing');
      for var I:=0 to High(Receipts) do
      begin
        Require((Receipts[I].CatalogueBinding=Tasks[I].CatalogueBinding) and
          DirectoryExists(Receipts[I].JournalDirectory) and
          FileExists(TPath.Combine(Receipts[I].WorkDirectory,'binding.json')),
          'Queue discarded the catalogue recovery receipt before its commit');
      end;
      Verify(First,1); Verify(Second,2);
    finally Queue.Free; end;
    // Model a catalogue failure: keep the results after destroying the worker.
    // Reopen and independently validate their journals before acknowledging.
    for var Receipt in Receipts do
    begin
      var Recovery:=TZipMemberDeletion.Recover(Receipt.Archive,Receipt.JournalDirectory);
      try Require(Recovery.Finished,'A completed queue receipt is not recoverable');
      finally Recovery.Free; end;
      TArchiveDeletionQueue.Acknowledge(Receipt);
    end;
    Require(not DirectoryExists(OwnedWork),'Completed queue left acknowledged journals');
    Writeln('PASS archive queue batches exact members across archives while UI timers continue and catalogue receipts remain durable'); Flush(Output);

    Fixture(First); Fixture(Second); BeforeSecond:=THashSHA2.GetHashStringFromFile(Second);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    try
      OwnedWork:=Queue.WorkDirectory; Queue.Start; WaitForQueue(True); Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and Receipts[0].FilesVerified and Queue.Status.Stopping,
        'Stop-after-current abandoned the active archive or started another');
      Verify(First,1);
      Require(THashSHA2.GetHashStringFromFile(Second)=BeforeSecond,'Stopped queue changed the next archive');
      TArchiveDeletionQueue.Acknowledge(Receipts[0]);
    finally Queue.Free; end;
    Require(not DirectoryExists(OwnedWork),'Stopped queue retained an acknowledged archive');

    Fixture(First); BeforeFirst:=THashSHA2.GetHashStringFromFile(First);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    OwnedWork:=Queue.WorkDirectory;
    Queue.StopAfterCurrentArchive; Queue.Free;
    Require(not DirectoryExists(OwnedWork) and (THashSHA2.GetHashStringFromFile(First)=BeforeFirst),
      'Destroying an unstarted queue changed its archive or left work');

    Tasks[0].Members:=TArray<string>.Create('missing.fb2');
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    try
      OwnedWork:=Queue.WorkDirectory; Queue.Start; WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and not Receipts[0].FilesVerified and (Receipts[0].Error<>''),
        'Invalid exact member unexpectedly succeeded or continued into another archive');
      Require(not DirectoryExists(OwnedWork) and
        (THashSHA2.GetHashStringFromFile(First)=BeforeFirst) and
        (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond),
        'Failed queue changed sources or retained a non-mutating plan');
    finally Queue.Free; end;
    Writeln('PASS archive queue stop finishes current archive preserves queued sources and rejects missing members without mutation'); Flush(Output);
  finally Timer.Free; Probe.Free; end;
end;
