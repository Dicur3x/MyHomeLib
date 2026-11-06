procedure TestZipCrashChild;
var Archive, Parent, Stage, Report: string; Delete: TZipMemberDeletion; Fault: TZipDeleteFault;
begin
  RequireIsolatedRegression;
  Archive:=ExpandFileName(ParamStr(2)); Parent:=ExpandFileName(ParamStr(3));
  Stage:=ParamStr(4); Report:=ExpandFileName(ParamStr(5));
  var Owned:=IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0))+'zip-member-delete'));
  Require(StartsText(Owned,Archive) and StartsText(Owned,Parent) and StartsText(Owned,Report),
    'ZIP crash child may only access its owned native fixture');
  Require(MatchText(Stage,['half-written','half-metadata','half-prefix']),'Unexpected ZIP crash stage');
  Fault:=procedure(const At: string; Chunk: Integer)
    begin
      if At=Stage then
      begin
        TFile.WriteAllText(Report,Delete.JobDirectory,TEncoding.UTF8);
        if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
      end;
    end;
  var Member:='каталог/book.fb2';
  if ParamStr(6)<>'' then Member:=ParamStr(6);
  try
    Delete:=TZipMemberDeletion.Prepare(Archive,[Member]);
    try Delete.Execute(Parent,nil,Fault); finally Delete.Free; end;
  except
    on E:Exception do
    begin TFile.WriteAllText(Report+'.error',E.ClassName+': '+E.Message,TEncoding.UTF8); raise; end;
  end;
  raise Exception.Create('ZIP crash point was not reached');
end;

procedure TestZipMemberDeletion;
var Root, Archive, JournalParent, Job, BeforeHash, OriginalPath: string;
  Payload, Image, Small: TBytes; Delete: TZipMemberDeletion;
  Expected: TDictionary<string,string>; Zip: TZipFile; Interrupted, Rejected: Boolean;
  FaultStage: string; Proof, Items: TJSONObject; FaultCallback: TZipDeleteFault;
  procedure KillWorker(const Phase: string);
  var Startup: TStartupInfo; ProcessInfo: TProcessInformation; Command, Report: string;
    Started: UInt64; ExitCode: DWORD;
  begin
    Report:=Root+'crash-'+Phase+'.txt';
    Command:='"'+ParamStr(0)+'" zip-member-crash-child "'+Archive+'" "'+JournalParent+'" "'+Phase+'" "'+Report+'"';
    UniqueString(Command); ZeroMemory(@Startup,SizeOf(Startup)); Startup.cb:=SizeOf(Startup);
    Startup.dwFlags:=STARTF_USESHOWWINDOW; Startup.wShowWindow:=SW_HIDE;
    ZeroMemory(@ProcessInfo,SizeOf(ProcessInfo)); Started:=GetTickCount64;
    if not CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
      PChar(Settings.AppPath),Startup,ProcessInfo) then RaiseLastOSError;
    try
      while WaitForSingleObject(ProcessInfo.hProcess,50)=WAIT_TIMEOUT do
        if GetTickCount64-Started>15000 then
        begin TerminateProcess(ProcessInfo.hProcess,74); raise Exception.Create('Owned ZIP worker exceeded crash guard'); end;
      Win32Check(GetExitCodeProcess(ProcessInfo.hProcess,ExitCode));
      Require((ExitCode=73) and FileExists(Report),'Owned ZIP worker was not killed at the requested phase; exit='+IntToStr(ExitCode));
    finally CloseHandle(ProcessInfo.hThread); CloseHandle(ProcessInfo.hProcess); end;
    Job:=TFile.ReadAllText(Report,TEncoding.UTF8);
    Require(StartsText(IncludeTrailingPathDelimiter(JournalParent),Job) and DirectoryExists(Job),
      'Killed ZIP worker did not publish its durable journal');
  end;
  function Hash(const Bytes: TBytes): string;
  var State: THashSHA2;
  begin State:=THashSHA2.Create; State.Update(Bytes); Result:=State.HashAsString; end;
  procedure Fixture(Ambiguous: Boolean = False);
  var Stream: TBytesStream;
    procedure Add(const Name: string; const Bytes: TBytes; Compression: TZipCompression);
    begin
      Stream := TBytesStream.Create(Bytes);
      try Zip.Add(Stream,Name,Compression); finally Stream.Free; end;
      Expected.AddOrSetValue(Name,Hash(Bytes));
    end;
  begin
    Expected.Clear; Zip := TZipFile.Create;
    try
      Zip.Open(Archive,zmWrite); Zip.UTF8Support := True; Zip.Comment := 'Preserve this archive comment';
      Add('Начало.fb2',Small,zcDeflate);
      Add('каталог/book.fb2',Small,zcStored);
      Add('другой каталог/book.fb2',Payload,zcStored);
      Add('images/Иллюстрация.jxl',Image,zcStored);
      Add('Case.fb2',Small,zcStored); Add('case.fb2',Image,zcDeflate);
      Add('literal[1]*?.fb2',Small,zcStored);
      if Ambiguous then Add('каталог\book.fb2',Small,zcStored);
    finally Zip.Free; end;
  end;
  procedure Verify;
  var Source: TStream; Header: TZipHeader; Output: TMemoryStream; Names: TArray<string>; Bytes: TBytes;
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(Archive,zmRead); Names := Zip.FileNames;
      Require(Zip.Comment='Preserve this archive comment','ZIP deletion lost the archive comment');
      Require(Length(Names)=Expected.Count,'ZIP deletion changed unselected inventory');
      for var I := 0 to High(Names) do
      begin
        Require(Expected.ContainsKey(Names[I]),'Unexpected or undeleted ZIP entry '+Names[I]);
        Zip.Read(I,Source,Header,True); Output := TMemoryStream.Create;
        try
          Output.CopyFrom(Source,0); SetLength(Bytes,Integer(Output.Size)); Output.Position:=0;
          if Length(Bytes)>0 then Output.ReadBuffer(Bytes[0],Length(Bytes));
          Require(Hash(Bytes)=Expected[Names[I]],'ZIP deletion changed unselected payload '+Names[I]);
        finally Source.Free; Output.Free; end;
      end;
    finally Zip.Free; end;
  end;
  function ActualJournalBytes(const Directory: string): Int64;
  var Stream: TFileStream;
  begin
    Result:=0;
    for var Name in TDirectory.GetFiles(Directory) do
    begin
      Require(MatchText(ExtractFileName(Name),['plan.json','checkpoint.json','pending.bin']),
        'Deletion created an unexpected working copy '+Name);
      Stream:=TFileStream.Create(Name,fmOpenRead or fmShareDenyNone);
      try Inc(Result,Stream.Size); finally Stream.Free; end;
    end;
  end;
begin
  RequireIsolatedRegression;
  FaultCallback := procedure(const Stage: string; Chunk: Integer)
    begin
      if Stage=FaultStage then
      begin Interrupted:=True; raise EAbort.Create('Owned interruption at '+Stage); end;
    end;
  Root:=Settings.AppPath+'zip-member-delete\'; ForceDirectories(Root);
  Archive:=Root+'source.zip'; JournalParent:=Root+'journals';
  SetLength(Payload,6*1024*1024+137); SetLength(Image,6*1024*1024+51);
  for var I:=0 to High(Payload) do Payload[I]:=Byte((I*17+13) mod 251);
  for var I:=0 to High(Image) do Image[I]:=Byte((I*29+7) mod 253);
  Small:=TEncoding.UTF8.GetBytes('Содержимое отдельной книги — ё. Повторяющийся текст.');
  Expected:=TDictionary<string,string>.Create;
  try
    Fixture; BeforeHash:=THashSHA2.GetHashStringFromFile(Archive);
    Rejected:=False;
    try Delete:=TZipMemberDeletion.Prepare(Archive,['book.fb2']); Delete.Free;
    except on E: Exception do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Archive)=BeforeHash),
      'Basename-only deletion guessed an entry or changed its source');
    Rejected:=False;
    try Delete:=TZipMemberDeletion.Prepare(Archive,['CASE.fb2']); Delete.Free;
    except on E: Exception do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Archive)=BeforeHash),
      'Case-folded deletion guessed a different entry');
    Rejected:=False;
    try
      Delete:=TZipMemberDeletion.Prepare(Archive,['каталог/book.fb2'],nil,
        function: Boolean begin Result:=True; end);
      Delete.Free;
    except on E: EAbort do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Archive)=BeforeHash),
      'Cancellation during planning changed the archive');

    Delete:=TZipMemberDeletion.Prepare(Archive,['каталог\book.fb2','literal[1]*?.fb2']);
    try
      Require(Delete.JournalBytes<10*1024*1024,'ZIP workspace grew to an archive-sized copy');
      Delete.Execute(JournalParent); Job:=Delete.JobDirectory;
      Require(Delete.Finished and DirectoryExists(Job),'Verified ZIP receipt was not retained for catalogue commit');
      Expected.Remove('каталог/book.fb2'); Expected.Remove('literal[1]*?.fb2');
      Require(ActualJournalBytes(Job)<5*1024*1024,'Actual ZIP journal contains an archive clone');
      Delete.Acknowledge;
      Require(not DirectoryExists(Job),'Acknowledged ZIP operation left its journal');
    finally Delete.Free; end;
    Verify;
    Writeln('PASS exact ZIP member deletion preserves bytes names comments and bounded workspace'); Flush(Output);

    Fixture;
    Delete:=TZipMemberDeletion.Prepare(Archive,['literal[1]*?.fb2']);
    try
      Require((Delete.BytesToProcess=0) and (Delete.JournalBytes<128*1024),
        'Deleting the last local entry scans or duplicates untouched book payloads');
      Delete.Execute(JournalParent); Delete.Acknowledge;
    finally Delete.Free; end;
    Expected.Remove('literal[1]*?.fb2'); Verify;
    Zip:=TZipFile.Create;
    try Zip.Open(Archive,zmRead); var All:=Zip.FileNames; Zip.Close;
      Delete:=TZipMemberDeletion.Prepare(Archive,All);
      try Delete.Execute(JournalParent); Delete.Acknowledge; finally Delete.Free; end;
    finally Zip.Free; end;
    Zip:=TZipFile.Create;
    try Zip.Open(Archive,zmRead); Require(Zip.FileCount=0,'Deleting all selected ZIP members left an entry');
    finally Zip.Free; end;

    for FaultStage in ['half-metadata','metadata','truncated'] do
    begin
      Fixture; Interrupted:=False;
      Zip:=TZipFile.Create;
      try
        Zip.Open(Archive,zmRead); var All:=Zip.FileNames; Zip.Close;
        Delete:=TZipMemberDeletion.Prepare(Archive,All);
        try
          try Delete.Execute(JournalParent,nil,FaultCallback);
          except on E: EAbort do if not Interrupted then raise; end;
          Job:=Delete.JobDirectory;
        finally Delete.Free; end;
        Require(Interrupted and DirectoryExists(Job),'Empty ZIP interruption was not exercised: '+FaultStage);
        Delete:=TZipMemberDeletion.Recover(Archive,Job);
        try
          Delete.Execute(JournalParent); Delete.Acknowledge; Delete.RemoveEmptyArchive;
        finally Delete.Free; end;
        Require(not FileExists(Archive) and not DirectoryExists(Job),'Empty ZIP recovery left the archive or journal');
      finally Zip.Free; end;
    end;
    Writeln('PASS empty ZIP footer and truncation recover at every interrupted write boundary'); Flush(Output);

    for FaultStage in ['pending','half-written','written','checkpoint','half-metadata','metadata','truncated','finished'] do
    begin
      Fixture; Interrupted:=False;
      Delete:=TZipMemberDeletion.Prepare(Archive,['каталог/book.fb2']);
      try
        try Delete.Execute(JournalParent,nil,FaultCallback);
        except on E: EAbort do begin if not Interrupted then raise; end; end;
        Job:=Delete.JobDirectory;
      finally Delete.Free; end;
      Require(Interrupted and DirectoryExists(Job),'Requested interruption was not exercised: '+FaultStage);
      Delete:=TZipMemberDeletion.Recover(Archive,Job);
      try
        Delete.Execute(JournalParent); Require(Delete.Finished,'Recovery did not finish '+FaultStage);
        Expected.Remove('каталог/book.fb2'); Delete.Acknowledge;
      finally Delete.Free; end;
      Verify; Require(not DirectoryExists(Job),'Recovery retained a completed journal');
      Writeln('TRACE ZIP recovery '+FaultStage); Flush(Output);
    end;
    Writeln('PASS interrupted ZIP block and metadata writes recover without an archive clone'); Flush(Output);
    for var Phase in ['half-written','half-metadata'] do
    begin
      Fixture; KillWorker(Phase);
      Delete:=TZipMemberDeletion.Recover(Archive,Job);
      try Delete.Execute(JournalParent); Delete.Acknowledge; finally Delete.Free; end;
      Expected.Remove('каталог/book.fb2'); Verify;
    end;
    Writeln('PASS killed own ZIP worker recovers partial payload and metadata writes'); Flush(Output);

    Fixture(True); BeforeHash:=THashSHA2.GetHashStringFromFile(Archive); Rejected:=False;
    try Delete:=TZipMemberDeletion.Prepare(Archive,['каталог/book.fb2']); Delete.Free;
    except on E: Exception do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Archive)=BeforeHash),
      'Ambiguous slash aliases were destructively resolved');

    Fixture; FaultStage:='pending'; Interrupted:=False;
    Delete:=TZipMemberDeletion.Prepare(Archive,['каталог/book.fb2']);
    try
      try Delete.Execute(JournalParent,nil,FaultCallback);
      except on E: EAbort do if not Interrupted then raise; end;
      Job:=Delete.JobDirectory;
    finally Delete.Free; end;
    OriginalPath:=Root+'owned-original.zip';
    TFile.Move(Archive,OriginalPath); Fixture; BeforeHash:=THashSHA2.GetHashStringFromFile(Archive); Rejected:=False;
    try Delete:=TZipMemberDeletion.Recover(Archive,Job); Delete.Free;
    except on E: Exception do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(Archive)=BeforeHash),
      'Recovery overwrote a replacement archive at the same path');
    TFile.Delete(Archive); TFile.Move(OriginalPath,Archive);
    Delete:=TZipMemberDeletion.Recover(Archive,Job);
    try Delete.Execute(JournalParent); Delete.Acknowledge; finally Delete.Free; end;
    Expected.Remove('каталог/book.fb2'); Verify;
    var Zip64Archive:=Settings.AppPath+'zip64-sparse.zip';
    var SparseSize:=TFileStream.Create(Zip64Archive,fmOpenRead or fmShareDenyWrite);
    try Require(SparseSize.Size>Int64(High(Cardinal)),'ZIP64 test did not exceed 4 GiB');
    finally SparseSize.Free; end;
    FaultStage:='half-written'; Interrupted:=False;
    Delete:=TZipMemberDeletion.Prepare(Zip64Archive,['chosen.fb2']);
    try
      Require((Delete.BytesToProcess>0) and (Delete.BytesToProcess<1024) and (Delete.JournalBytes<128*1024),
        'ZIP64 deletion planned work for the removed multi-GiB sparse payload');
      try Delete.Execute(JournalParent,nil,FaultCallback);
      except on E: EAbort do if not Interrupted then raise; end;
      Job:=Delete.JobDirectory;
    finally Delete.Free; end;
    Require(Interrupted,'ZIP64 partial block write was not interrupted');
    Delete:=TZipMemberDeletion.Recover(Zip64Archive,Job);
    try Delete.Execute(JournalParent); Delete.Acknowledge; finally Delete.Free; end;
    var Small64:=TEncoding.UTF8.GetBytes('ZIP64 retained payload — ё.');
    Zip:=TZipFile.Create;
    try
      Zip.Open(Zip64Archive,zmRead);
      Require((Zip.FileCount=1) and (Zip.FileNames[0]='сохранить/book.fb2'),'ZIP64 retained inventory changed');
      var Bytes64: TBytes; Zip.Read(0,Bytes64);
      Require(Hash(Bytes64)=Hash(Small64),'ZIP64 neighbour was damaged');
    finally Zip.Free; end;
    SparseSize:=TFileStream.Create(Zip64Archive,fmOpenRead or fmShareDenyWrite);
    try Require(SparseSize.Size<1024,'ZIP64 result was not compacted');
    finally SparseSize.Free; end;
    Writeln('PASS ZIP64 offsets above 4 GiB recover with sub-128-KiB journal'); Flush(Output);
    Proof:=TJSONObject.Create; Items:=TJSONObject.Create;
    try
      Proof.AddPair('archive','zip-member-delete/source.zip'); Proof.AddPair('entries',Items);
      Proof.AddPair('zip64Archive','zip64-sparse.zip'); Proof.AddPair('zip64Hash',Hash(Small64));
      for var Item in Expected do Items.AddPair(Item.Key,Item.Value);
      TFile.WriteAllText(Settings.AppPath+'zip-member-delete-proof.json',Proof.ToJSON,TEncoding.UTF8);
    finally Proof.Free; end;
    Writeln('PASS ZIP recovery rejects replaced files and ambiguous exact paths'); Flush(Output);
  finally Expected.Free; end;
end;
