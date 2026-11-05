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
    var AliasName:=Root+'same-physical-archive.zip';
    Win32Check(CreateHardLink(PChar(AliasName),PChar(First),nil));
    try
      var GuardHash:=THashSHA2.GetHashStringFromFile(First);
      var Lease:=AcquireArchiveChange(First);
      try
        Require(IsArchiveChanging(First) and IsArchiveChanging(AliasName) and not IsArchiveChanging(Second),
          'Archive guard did not follow physical aliases or blocked a different source');
        var Blocked:=False; var Reader:TMHLZip:=nil;
        try Reader:=TMHLZip.Create(AliasName,True);
        except on E:EMHLArchiveInUse do Blocked:=True; end;
        Reader.Free; Require(Blocked,'Reader opened an archive while its change guard was active');
        Reader:=TMHLZip.Create(Second,True);
        try Require(Reader.FileCount=3,'A different archive became unreadable during a source change');
        finally Reader.Free; end;
        Blocked:=False; var Duplicate:IInterface;
        try Duplicate:=AcquireArchiveChange(AliasName);
        except on E:EMHLArchiveInUse do Blocked:=True; end;
        Require(Blocked and not Assigned(Duplicate) and IsArchiveChanging(First),
          'A rejected duplicate writer released the first writer guard');
      finally Lease:=nil; end;
      Require(not IsArchiveChanging(First) and not IsArchiveChanging(AliasName) and
        (THashSHA2.GetHashStringFromFile(First)=GuardHash),'Archive guard leaked or changed source bytes');
      Writeln('PASS archive change guard follows physical aliases and blocks current source readers without blocking other archives'); Flush(Output);
      var Aliases:=Copy(Tasks); Aliases[1].Archive:=AliasName;
      var Rejected:=False;
      try Queue:=TArchiveDeletionQueue.Create(Aliases,Root+'journals'); Queue.Free;
      except on E:EArgumentException do Rejected:=True; end;
      Require(Rejected,'Queue accepted two conflicting tasks for one physical archive');
    finally TFile.Delete(AliasName); end;
    Writeln('PASS archive queue rejects physical aliases before creating conflicting jobs'); Flush(Output);
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
    var SavedBinding:=TFile.ReadAllBytes(TPath.Combine(Receipts[0].WorkDirectory,'binding.json'));
    var RejectedBinding:=False;
    TFile.WriteAllBytes(TPath.Combine(Receipts[0].WorkDirectory,'binding.json'),
      TEncoding.UTF8.GetBytes(TEncoding.UTF8.GetString(SavedBinding)+' '));
    try
      try TArchiveDeletionQueue.ReadReceipt(Receipts[0].WorkDirectory);
      except on E:EReadError do RejectedBinding:=E.Message.Contains('Привязка каталога'); end;
      Require(RejectedBinding,'Changed catalogue receipt was accepted after archive mutation');
    finally TFile.WriteAllBytes(TPath.Combine(Receipts[0].WorkDirectory,'binding.json'),SavedBinding); end;
    var WrongReceipt:=Receipts[0]; WrongReceipt.CatalogueBinding:='foreign catalogue';
    RejectedBinding:=False;
    try TArchiveDeletionQueue.Acknowledge(WrongReceipt);
    except on E:EReadError do RejectedBinding:=True; end;
    Require(RejectedBinding and DirectoryExists(Receipts[0].JournalDirectory),
      'Foreign catalogue acknowledgement discarded the source recovery journal');
    Queue:=TArchiveDeletionQueue.Recover([Receipts[0].WorkDirectory,Receipts[1].WorkDirectory]);
    try
      Queue.Start; WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=2) and Receipts[0].FilesVerified and Receipts[1].FilesVerified,
        'A restarted queue did not validate both finished archive receipts');
      for var Receipt in Receipts do TArchiveDeletionQueue.Acknowledge(Receipt);
    finally Queue.Free; end;
    Require(not DirectoryExists(OwnedWork),'Completed queue left acknowledged journals');
    Writeln('PASS archive queue batches exact members across archives while UI timers continue and catalogue receipts remain durable'); Flush(Output);
    Writeln('PASS archive receipts reject changed catalogue bindings and resume after destroying the original worker'); Flush(Output);

    Fixture(First);
    var InterruptedDirectory:=Root+'interrupted-bound-task'; ForceDirectories(InterruptedDirectory);
    // Only a tiny owned fixture is used. The production worker writes the
    // binding before starting its journal; simulate process loss afterwards.
    TFile.WriteAllBytes(TPath.Combine(InterruptedDirectory,'binding.json'),SavedBinding);
    var Engine:=TZipMemberDeletion.Prepare(First,Tasks[0].Members);
    var WasInterrupted:=False;
    try
      Engine.BindContext(THashSHA2.GetHashStringFromFile(TPath.Combine(InterruptedDirectory,'binding.json')));
      try
        Engine.Execute(InterruptedDirectory,nil,
          procedure(const Stage:string; Chunk:Integer)
          begin if Stage='half-written' then raise EAbort.Create('owned receipt interruption'); end);
      except on E:EAbort do WasInterrupted:=True; end;
      Require(WasInterrupted and (Engine.JobDirectory<>''),'Bound receipt interruption did not exercise an in-flight write');
    finally Engine.Free; end;
    var PendingReceipt:=TArchiveDeletionQueue.ReadReceipt(InterruptedDirectory);
    Require(not PendingReceipt.FilesVerified,'Loading a receipt falsely claimed that source data had already been reverified');
    Queue:=TArchiveDeletionQueue.Recover([InterruptedDirectory]);
    try
      Queue.Start; WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and Receipts[0].FilesVerified,
        'Recovered queue did not finish the interrupted source deletion');
      Verify(First,1); TArchiveDeletionQueue.Acknowledge(Receipts[0]);
    finally Queue.Free; end;
    Require(not DirectoryExists(InterruptedDirectory),'Recovered queue left its acknowledged task');
    Writeln('PASS persisted archive queue resumes a half-written source using its original bound catalogue receipt'); Flush(Output);

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
    try
      OwnedWork:=Queue.WorkDirectory;
      TFile.Move(First,Root+'replaced-source.zip'); Fixture(First);
      BeforeFirst:=THashSHA2.GetHashStringFromFile(First);
      Queue.Start; WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and not Receipts[0].FilesVerified and
        (Pos('изменился после выбора',Receipts[0].Error)>0),
        'Queue did not reject a replaced source after the captured selection');
      Require((THashSHA2.GetHashStringFromFile(First)=BeforeFirst) and
        (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond) and not DirectoryExists(OwnedWork),
        'Stale queue intent modified a replacement archive or left an unstarted journal');
      TFile.Delete(Root+'replaced-source.zip');
    finally Queue.Free; end;
    Writeln('PASS archive queue revalidates captured file identity before any mutation'); Flush(Output);

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
    SetLength(Tasks[0].Members,128);
    for var I:=0 to High(Tasks[0].Members) do
      Tasks[0].Members[I]:=StringOfChar('a',70000)+IntToStr(I);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    try
      OwnedWork:=Queue.WorkDirectory; Queue.Start; WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and not Receipts[0].FilesVerified and
        Receipts[0].Error.Contains('Слишком большой список') and
        not DirectoryExists(OwnedWork) and (THashSHA2.GetHashStringFromFile(First)=BeforeFirst) and
        (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond),
        'Oversized recovery context changed the source or left an unresumable journal');
    finally Queue.Free; end;
    Writeln('PASS oversized durable context is rejected before source mutation and its empty work is removed'); Flush(Output);

    Tasks[0].Members:=TArray<string>.Create('selected/one.fb2','selected/two.fb2');
    Fixture(First); Fixture(Second); BeforeSecond:=THashSHA2.GetHashStringFromFile(Second);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals',True);
    try
      OwnedWork:=Queue.WorkDirectory; Queue.Start;
      var Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; Receipts:=Queue.Results;
        if GetTickCount64-Started>15000 then raise Exception.Create('Owner receipt guard expired');
        if Length(Receipts)=0 then Sleep(1);
      until Length(Receipts)>0;
      Require(Receipts[0].FilesVerified and not Queue.Status.Finished and IsArchiveChanging(First) and
        not IsArchiveChanging(Second),'Owner phase did not keep only its current source protected');
      var Rejected:=False;
      try TArchiveDeletionQueue.Acknowledge(Receipts[0]);
      except on E:EInvalidOperation do Rejected:=True; end;
      Require(Rejected and DirectoryExists(Receipts[0].JournalDirectory),'A journal was discarded before its owner commit');
      Queue.StopAfterCurrentArchive;
      Require(not Queue.Status.Finished,'Stop abandoned an archive awaiting its catalogue phase');
      Queue.CatalogueCommitted(0); WaitForQueue; Receipts:=Queue.Results;
      Require((Length(Receipts)=1) and Receipts[0].CatalogueCommitted and Receipts[0].Acknowledged and
        (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond) and not DirectoryExists(OwnedWork),
        'Owner completion did not acknowledge current work before stopping queued sources');
    finally Queue.Free; end;
    Writeln('PASS owner-coordinated archive queue waits for catalogue commit off the UI thread and stops before queued sources'); Flush(Output);

    for var Abandon in [False,True] do
    begin
      Fixture(First); Fixture(Second); BeforeSecond:=THashSHA2.GetHashStringFromFile(Second);
      Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals',True);
      try
        OwnedWork:=Queue.WorkDirectory; Queue.Start;
        var Started:=GetTickCount64;
        repeat
          Application.ProcessMessages; Receipts:=Queue.Results;
          if GetTickCount64-Started>15000 then raise Exception.Create('Retained owner receipt guard expired');
          if Length(Receipts)=0 then Sleep(1);
        until Length(Receipts)>0;
        Require(Receipts[0].FilesVerified,Receipts[0].Error);
        if not Abandon then
        begin Queue.CatalogueRejected(0); WaitForQueue; Receipts:=Queue.Results; end;
      finally Queue.Free; end;
      Require(DirectoryExists(Receipts[0].JournalDirectory) and
        (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond) and not IsArchiveChanging(First),
        'Rejected/abandoned owner lost its journal changed queued sources or kept a writer guard');
      Queue:=TArchiveDeletionQueue.Recover([Receipts[0].WorkDirectory],True);
      try
        Queue.Start; var Started:=GetTickCount64;
        repeat
          Application.ProcessMessages; Receipts:=Queue.Results;
          if GetTickCount64-Started>15000 then raise Exception.Create('Recovered owner receipt guard expired');
          if Length(Receipts)=0 then Sleep(1);
        until Length(Receipts)>0;
        Require(Receipts[0].FilesVerified,Receipts[0].Error);
        Queue.CatalogueCommitted(0); WaitForQueue; Receipts:=Queue.Results;
        Require(Receipts[0].Acknowledged and not DirectoryExists(OwnedWork) and
          (THashSHA2.GetHashStringFromFile(Second)=BeforeSecond),'Fresh owner did not complete retained work safely');
        Verify(First,1);
      finally Queue.Free; end;
    end;
    Writeln('PASS rejected or abandoned owner retains recoverable journals and fresh owner completes them safely'); Flush(Output);
  finally Timer.Free; Probe.Free; end;
end;
