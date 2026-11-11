procedure RunPackingLeaseChild;
var Options: TCollectionPackingOptions; Root: TJSONObject;
  Snapshot: TCollectionPackingSnapshot; Partial: TFileStream;
begin
  Require(SameFileName(ParamStr(2),ExtractFilePath(ParamStr(0))+'packing-lease-options.json'),
    'Lease child requires its owned fixture options');
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ParamStr(2),TEncoding.UTF8)) as TJSONObject;
  try
    Options:=Default(TCollectionPackingOptions);
    Options.CatalogFile:=Root.GetValue<string>('catalog');
    Options.PersonalFile:=Root.GetValue<string>('personal');
    Options.SourceRoot:=Root.GetValue<string>('source');
    Options.OutputRoot:=Root.GetValue<string>('output');
    Options.Dataset:=Root.GetValue<string>('dataset');
    Options.SourceID:=Root.GetValue<Integer>('source_id'); Options.DisplayName:='Lease child';
  finally Root.Free; end;
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare(nil,procedure(const Stage:string; Current,Total:Int64)
    begin
      // Pause during real preparation with its output lease held. The next
      // process must reclaim a partly written snapshot after a hard stop.
      Partial:=TFileStream.Create(Snapshot.CatalogFile,fmCreate);
      try Partial.Size:=4*1024*1024; finally Partial.Free; end;
      TFile.WriteAllText(ExtractFilePath(ParamStr(0))+'packing-lease-ready.txt',
        ExtractFileDir(Snapshot.CatalogFile),TEncoding.UTF8);
      while True do Sleep(1000);
    end);
    raise Exception.Create('Lease child unexpectedly passed the controlled pause');
  finally Snapshot.Free; end;
end;

procedure RequirePackingLeaseBusy(const Options:TCollectionPackingOptions);
var Other:TCollectionPackingSnapshot; Rejected:Boolean;
begin
  Other:=TCollectionPackingSnapshot.Create(Options);
  try
    Rejected:=False;
    try Other.Prepare;
    except on E:Exception do if Pos('уже обрабатывается',E.Message)>0 then Rejected:=True else raise; end;
    Require(Rejected,'Concurrent packing was allowed to touch a live snapshot');
  finally Other.Free; end;
end;

procedure TestPackingLeaseRecovery(const Options:TCollectionPackingOptions);
var Root:TJSONObject; Names,Hashes:TArray<string>;
  FileName,Ready,Work,Command,Foreign,Unknown,DirectoryJob:string;
  Startup:TStartupInfo; Process:TProcessInformation; Started:UInt64;
  Snapshot:TCollectionPackingSnapshot; Code:Cardinal;
  function MakeJob(const Dataset,Entry:string; IsDirectory:Boolean=False):string;
  var Marker:TJSONObject;
  begin
    Result:=TPath.Combine(Options.OutputRoot,'.job-'+TGUID.NewGuid.ToString);
    ForceDirectories(Result); Marker:=TJSONObject.Create;
    try
      Marker.AddPair('version',TJSONNumber.Create(1));
      Marker.AddPair('kind','HomeLibRu collection packing snapshots'); Marker.AddPair('dataset',Dataset);
      TFile.WriteAllText(TPath.Combine(Result,'HomeLibRu-job.json'),Marker.ToJSON,TEncoding.UTF8);
    finally Marker.Free; end;
    if IsDirectory then
    begin ForceDirectories(TPath.Combine(Result,Entry));
      TFile.WriteAllText(TPath.Combine(Result,Entry+'\keep.txt'),'owned test sentinel',TEncoding.UTF8); end
    else TFile.WriteAllText(TPath.Combine(Result,Entry),'owned test sentinel',TEncoding.UTF8);
  end;
begin
  Names:=TDirectory.GetFiles(TPath.Combine(Options.OutputRoot,'archives'),'*',TSearchOption.soAllDirectories);
  Require(Length(Names)>0,'Crash recovery needs real completed packed archives');
  SetLength(Hashes,Length(Names));
  for var I:=0 to High(Names) do Hashes[I]:=THashSHA2.GetHashStringFromFile(Names[I]);
  Foreign:=MakeJob('another-dataset','source.hlc2');
  Unknown:=MakeJob(Options.Dataset,'user-notes.txt');
  DirectoryJob:=MakeJob(Options.Dataset,'source.hlc2',True);
  FileName:=Settings.AppPath+'packing-lease-options.json'; Ready:=Settings.AppPath+'packing-lease-ready.txt';
  Root:=TJSONObject.Create;
  try
    Root.AddPair('catalog',Options.CatalogFile); Root.AddPair('personal',Options.PersonalFile);
    Root.AddPair('source',Options.SourceRoot); Root.AddPair('output',Options.OutputRoot);
    Root.AddPair('dataset',Options.Dataset); Root.AddPair('source_id',TJSONNumber.Create(Options.SourceID));
    TFile.WriteAllText(FileName,Root.ToJSON,TEncoding.UTF8);
  finally Root.Free; end;
  Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Command:='"'+ParamStr(0)+'" packing-lease-child "'+FileName+'"'; UniqueString(Command);
  Require(CreateProcess(PChar(ParamStr(0)),PChar(Command),nil,nil,False,CREATE_NO_WINDOW,nil,
    PChar(Settings.AppPath),Startup,Process),'Cannot launch the owned crash-recovery child');
  try
    Started:=GetTickCount64;
    while not FileExists(Ready) do
    begin
      Require(GetExitCodeProcess(Process.hProcess,Code) and (Code=STILL_ACTIVE),
        'Packing lease child exited before acquiring its lease');
      Require(GetTickCount64-Started<10000,'Packing lease child did not reach its controlled pause');
      Sleep(10);
    end;
    Work:=TFile.ReadAllText(Ready,TEncoding.UTF8);
    Require(SameFileName(ExtractFileDir(Work),Options.OutputRoot) and
      (TFile.GetSize(TPath.Combine(Work,'source.hlc2'))=4*1024*1024),'Partial snapshot was not created on the output drive');
    RequirePackingLeaseBusy(Options);
    Require(FileExists(TPath.Combine(Work,'source.hlc2')),'Active child snapshot was cleaned');
    Require(TerminateProcess(Process.hProcess,90),'Cannot stop the owned test child');
    Require(WaitForSingleObject(Process.hProcess,5000)=WAIT_OBJECT_0,'Stopped test child is still active');
    Snapshot:=TCollectionPackingSnapshot.Create(Options);
    try
      Snapshot.Prepare;
      Require(not DirectoryExists(Work),'Crashed native snapshot was not reclaimed on the next preparation');
      Require(FileExists(Foreign+'\source.hlc2') and FileExists(Foreign+'\HomeLibRu-job.json'),
        'Cleanup touched another dataset');
      Require(FileExists(Unknown+'\user-notes.txt') and FileExists(Unknown+'\HomeLibRu-job.json'),
        'Cleanup touched an unknown user file');
      Require(FileExists(DirectoryJob+'\source.hlc2\keep.txt') and FileExists(DirectoryJob+'\HomeLibRu-job.json'),
        'Cleanup recursed into a directory');
      for var I:=0 to High(Names) do
        Require(FileExists(Names[I]) and (THashSHA2.GetHashStringFromFile(Names[I])=Hashes[I]),
          'Crash recovery changed a completed archive');
    finally Snapshot.Free; end;
  finally
    if WaitForSingleObject(Process.hProcess,0)<>WAIT_OBJECT_0 then
    begin TerminateProcess(Process.hProcess,91); WaitForSingleObject(Process.hProcess,5000); end;
    CloseHandle(Process.hThread); CloseHandle(Process.hProcess);
  end;
  Writeln('PASS native packing lease rejects same-thread and cross-process overlap releases after hard stop and reclaims only owned snapshots preserving archives');
end;
