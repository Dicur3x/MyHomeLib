procedure TestSevenZipDeletionPlan;
var Root, ArchivePath, BeforeHash: string; Source, Target:TFileStream;
  Layout:TSevenZipDeletionLayout; Bytes:TBytes; Hash:THashSHA2; Rejected:Boolean;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'sevenzip-delete-plan\';
  for var Kind in ['ppmd','lzma2'] do
  begin
    ArchivePath:=Root+Kind+'.7z'; BeforeHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
    Source:=TFileStream.Create(ArchivePath,fmOpenRead or fmShareDenyWrite);
    try
      // Planning is physically incapable of writing this read-only handle.
      var Observed:=ReadBookDeletionInventory(ArchivePath,ArchiveDeletionSourceIdentity(ArchivePath));
      var HasOne,HasTwo:Boolean; HasOne:=False; HasTwo:=False;
      for var Name in Observed do
      begin
        HasOne:=HasOne or (Name.Replace('\','/')='selected/one.fb2');
        HasTwo:=HasTwo or (Name.Replace('\','/')='selected/two.fb2');
      end;
      Require(HasOne and HasTwo,'Metadata-only 7z inventory lost exact selected names');
      Layout:=PlanSevenZipDeletion(Source,['selected\one.fb2','selected/two.fb2']);
      Require((Length(Layout.Remaining)>=1) and (Layout.FinalSize<Source.Size) and
        (Length(Layout.Header)=32) and (Length(Layout.Tail)<128*1024),
        '7z planner did not produce a bounded deletion layout');
      Require((Length(Layout.Ranges)=1) and (Layout.Ranges[0].Bytes>128*1024) and
        (Layout.Ranges[0].Source>Layout.Ranges[0].Target),
        'Adjacent 7z writes for one moved stream were not merged into one journal block');
      Target:=TFileStream.Create(Root+'planned-'+Kind+'.7z',fmCreate);
      try
        Target.WriteBuffer(Layout.Header[0],Length(Layout.Header));
        for var Range in Layout.Ranges do
        begin
          Require((Range.Bytes<=4*1024*1024) and (Range.Source>=Range.Target),'Unbounded or right-moving 7z payload');
          SetLength(Bytes,Range.Bytes); Source.Position:=Range.Source;
          Source.ReadBuffer(Bytes[0],Length(Bytes)); Hash:=THashSHA2.Create; Hash.Update(Bytes);
          Require(Hash.HashAsString=Range.SHA256,'7z planned compressed block hash differs');
          Target.Position:=Range.Target; Target.WriteBuffer(Bytes[0],Length(Bytes));
        end;
        Target.Position:=Layout.TailOffset;
        if Length(Layout.Tail)>0 then Target.WriteBuffer(Layout.Tail[0],Length(Layout.Tail));
        Target.Size:=Layout.FinalSize;
        VerifySevenZipInventory(Target,Layout.Remaining);
      finally Target.Free; end;
    finally Source.Free; end;
    Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeHash,'7z planning changed its original archive');
  end;
  Writeln('PASS read-only 7z deletion planner retains original compressed blocks and metadata with bounded virtual output'); Flush(Output);
  Writeln('PASS adjacent 7z writes use one bounded recovery block with the original SHA-256'); Flush(Output);
  ArchivePath:=Root+'solid.7z'; BeforeHash:=THashSHA2.GetHashStringFromFile(ArchivePath);
  Source:=TFileStream.Create(ArchivePath,fmOpenRead or fmShareDenyWrite);
  try
    Rejected:=False;
    try Layout:=PlanSevenZipDeletion(Source,['selected/one.fb2']);
    except on E:ENotSupportedException do Rejected:=Pos('solid',E.Message)>0; end;
    Require(Rejected,'7z planner silently re-encoded a partial solid block');
  finally Source.Free; end;
  Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeHash,'Rejected solid plan changed the archive');
  Writeln('PASS partial solid 7z removal is rejected before any source mutation'); Flush(Output);
end;

procedure TestSevenZipDeletionRecovery;
var Root, SourceName, Seed, Journal, Job, Stage:string; Layout:TSevenZipDeletionLayout;
  Source:TFileStream; Deletion:TZipMemberDeletion; Fault:TZipDeleteFault;
  Interrupted:Boolean;
  procedure ResetSeed;
  begin TFile.Copy(Seed,SourceName,True); end;
  procedure Verify;
  begin
    Source:=TFileStream.Create(SourceName,fmOpenRead or fmShareDenyWrite);
    try VerifySevenZipInventory(Source,Layout.Remaining); finally Source.Free; end;
    Require(not DirectoryExists(Job),'7z recovery left an acknowledged journal');
  end;
  procedure KillWorker(const Phase:string);
  var Startup:TStartupInfo; Info:TProcessInformation; Command,Report:string; ExitCode:DWORD;
  begin
    Report:=Root+'killed-'+Phase+'.txt';
    Command:='"'+ParamStr(0)+'" zip-member-crash-child "'+SourceName+'" "'+Journal+'" "'+Phase+'" "'+Report+'" "selected/one.fb2"';
    UniqueString(Command); ZeroMemory(@Startup,SizeOf(Startup)); Startup.cb:=SizeOf(Startup);
    Startup.dwFlags:=STARTF_USESHOWWINDOW; Startup.wShowWindow:=SW_HIDE;
    ZeroMemory(@Info,SizeOf(Info));
    if not CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
      PChar(Settings.AppPath),Startup,Info) then RaiseLastOSError;
    try
      if WaitForSingleObject(Info.hProcess,15000)<>WAIT_OBJECT_0 then
      begin TerminateProcess(Info.hProcess,74); raise Exception.Create('Owned 7z crash worker exceeded its guard'); end;
      Win32Check(GetExitCodeProcess(Info.hProcess,ExitCode));
      var Details:='';
      if FileExists(Report+'.error') then Details:=TFile.ReadAllText(Report+'.error',TEncoding.UTF8);
      Require((ExitCode=73) and FileExists(Report),'7z worker missed '+Phase+'; exit='+IntToStr(ExitCode)+' '+Details);
    finally CloseHandle(Info.hThread); CloseHandle(Info.hProcess); end;
    Job:=TFile.ReadAllText(Report,TEncoding.UTF8);
    Require(StartsText(IncludeTrailingPathDelimiter(Journal),Job),'7z crash journal escaped its owned fixture');
  end;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'zip-member-delete\sevenzip-recovery\'; ForceDirectories(Root);
  SourceName:=Root+'source.7z'; Journal:=Root+'journals';
  Fault:=procedure(const At:string; Chunk:Integer)
    begin if At=Stage then begin Interrupted:=True; raise EAbort.Create('Owned 7z interruption'); end; end;
  for var Kind in ['ppmd','lzma2'] do
  begin
    Seed:=Settings.AppPath+'sevenzip-delete-plan\'+Kind+'.7z';
    Source:=TFileStream.Create(Seed,fmOpenRead or fmShareDenyWrite);
    try Layout:=PlanSevenZipDeletion(Source,['selected/one.fb2']); finally Source.Free; end;
    for Stage in ['pending','half-written','written','checkpoint','half-metadata','metadata','half-prefix','prefix','truncated','finished'] do
    begin
      Trace('7z fault '+Kind+' '+Stage+' tick='+UIntToStr(GetTickCount64));
      ResetSeed; Interrupted:=False;
      Deletion:=TZipMemberDeletion.Prepare(SourceName,['selected/one.fb2']);
      try
        Require(Deletion.JournalBytes<512*1024,'Small 7z removal required an archive-sized journal');
        try Deletion.Execute(Journal,nil,Fault);
        except on E:EAbort do if not Interrupted then raise; end;
        Job:=Deletion.JobDirectory;
      finally Deletion.Free; end;
      Require(Interrupted and DirectoryExists(Job),'7z interruption point was not reached: '+Stage);
      Deletion:=TZipMemberDeletion.Recover(SourceName,Job);
      try Deletion.Execute(Journal); Require(Deletion.Finished,'7z forward recovery did not finish');
        Deletion.Acknowledge;
      finally Deletion.Free; end;
      Verify;
    end;
  end;
  for Stage in ['half-written','half-prefix'] do
  begin
    Trace('7z child '+Stage+' tick='+UIntToStr(GetTickCount64));
    ResetSeed; KillWorker(Stage);
    Deletion:=TZipMemberDeletion.Recover(SourceName,Job);
    try Deletion.Execute(Journal); Deletion.Acknowledge; finally Deletion.Free; end;
    Verify;
  end;
  TFile.WriteAllText(Settings.AppPath+'sevenzip-recovery-proof.json',
    '{"archive":"zip-member-delete/sevenzip-recovery/source.7z","files":["selected/two.fb2","unselected/keep.fb2"]}',TEncoding.UTF8);
  Writeln('PASS in-place PPMd and LZMA2 removal recovers ten interruption phases and killed workers without an archive clone'); Flush(Output);

  var Tasks:TArray<TArchiveDeletionTask>; SetLength(Tasks,2);
  for var I:=0 to 1 do
  begin
    Tasks[I].Archive:=Root+'queued-'+IntToStr(I)+'.7z';
    TFile.Copy(Seed,Tasks[I].Archive,True);
    Tasks[I].Members:=TArray<string>.Create('selected/one.fb2','selected/two.fb2');
    Tasks[I].CatalogueBinding:='owned grouped 7z catalogue intent '+IntToStr(I);
  end;
  var Queue:=TArchiveDeletionQueue.Create(Tasks,Journal);
  try
    var Work:=Queue.WorkDirectory; Queue.Start; var Started:=GetTickCount64;
    while not Queue.Status.Finished do
    begin
      Application.ProcessMessages; Sleep(1);
      Require(GetTickCount64-Started<30000,'Owned grouped 7z queue exceeded its guard');
    end;
    Queue.WaitFor; var Receipts:=Queue.Results;
    Require((Length(Receipts)=2) and Receipts[0].FilesVerified and Receipts[1].FilesVerified,
      'Grouped 7z queue failed to delete multiple members across archives');
    for var Receipt in Receipts do
    begin
      Source:=TFileStream.Create(Receipt.Archive,fmOpenRead or fmShareDenyWrite);
      try
        Layout:=PlanSevenZipDeletion(Source,['unselected/keep.fb2']);
        // Only the final book is now selected; everything remaining is a
        // directory. Do not mistake directory records for another book.
        for var Name in Layout.Remaining do Require(not Name.EndsWith('.fb2'),'Selected 7z group left a deleted book');
      finally Source.Free; end;
      TArchiveDeletionQueue.Acknowledge(Receipt);
    end;
    Require(not DirectoryExists(Work),'Grouped 7z queue retained acknowledged work');
  finally Queue.Free; end;
  Writeln('PASS background 7z queue removes multiple exact members from one and different archives'); Flush(Output);
end;
