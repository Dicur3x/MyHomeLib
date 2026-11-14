unit BookCompressionReceiptFixture;

interface

procedure RunCompressionReceiptFixture;

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  unit_ZipMemberDeletion, unit_BookCompressionReceipt, unit_AtomicIniFile, unit_BookCompressionJob,
  unit_BookCompressionFileGroup, SQLiteWrap;

var Root, Mode, FaultAt, ReceiptFile, Report, LastStage: string;
    Receipt: TBookCompressionReceipt;
    Engine: TZipMemberDeletion;
    Job: TBookCompressionJob;

procedure Require(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;

procedure ErrorUTF8(const MessageText: string);
var Bytes: TBytes; Written: DWORD;
begin
  Bytes:=TEncoding.UTF8.GetBytes(MessageText+sLineBreak);
  if not WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),Bytes[0],Length(Bytes),Written,nil) then RaiseLastOSError;
end;

procedure CrashAt(Stage: string);
begin
  LastStage:=Stage;
  if (Mode='job-group-change-row') and (Stage='group-ready') then
  begin
    var DB:=TSQLiteDatabase.Create(Root+'catalog.hlc2');
    try DB.ExecSQL('UPDATE Books SET FileName=''moved'' WHERE BookID=101'); finally DB.Free; end;
  end;
  if Stage<>FaultAt then Exit;
  if Assigned(Job) then TFile.WriteAllText(Report,Job.Directory,TEncoding.UTF8)
  else TFile.WriteAllText(Report,Engine.JobDirectory,TEncoding.UTF8);
  if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
end;

procedure PreparationFault(Stage:string);
begin
  if (Mode='job-prepare-hold') and (Stage='job-published') then
  begin
    TFile.WriteAllText(Root+'publication-ready','ready');
    while not FileExists(Root+'release-publication') do Sleep(25);
    Exit;
  end;
  if Stage<>FaultAt then Exit;
  TFile.WriteAllText(Root+'preparation-stage.txt',Stage,TEncoding.UTF8);
  if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
end;

function LoadReceipt: TBookCompressionReceipt;
var Data: TJSONObject; Value: TJSONValue; Stream: TStringStream;
begin
  if (Mode='recover') or Mode.StartsWith('group-recover') or (Mode='captured-apply') or (Mode='captured-inspection') then
    Exit(TBookCompressionReceipt.Create(TFile.ReadAllText(ReceiptFile,TEncoding.UTF8)));
  Value:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Root+'receipt-template.json',TEncoding.UTF8));
  Require(Value is TJSONObject,'Invalid fixture template');
  Data:=TJSONObject(Value);
  try
    for var Name in ['catalogue','personal','source'] do
    begin
      var Path:=Data.GetValue(Name).Value;
      Require(ExpandFileName(Path).StartsWith(Root,True),'Fixture path escaped its private root');
      var Key:=Name+'_key';
      if Name='source' then Key:='source_file_key';
      Data.RemovePair(Key).Free;
      Data.AddPair(Key,CompressionFileKey(Path));
    end;
    if Data.GetValue('compression_options') is TJSONObject then
    begin
      var Options:=Data.GetValue<TJSONObject>('compression_options');
      if Options.GetValue<string>('source_identity','')='@source' then
      begin
        Options.RemovePair('source_identity').Free;
        Options.AddPair('source_identity',ArchiveDeletionSourceIdentity(Data.GetValue<string>('source')));
      end;
    end;
    if Data.GetValue('group_files') is TJSONArray then
      for var FileValue in Data.GetValue<TJSONArray>('group_files') do
      begin
        var FileData:=TJSONObject(FileValue);
        Require(ExpandFileName(FileData.GetValue<string>('source')).StartsWith(Root,True),'Group source escaped fixture');
        Require(ExpandFileName(FileData.GetValue<string>('candidate')).StartsWith(Root,True),'Group candidate escaped fixture');
        FileData.RemovePair('source_identity').Free;
        FileData.AddPair('source_identity',ArchiveDeletionSourceIdentity(FileData.GetValue<string>('source')));
      end;
    Result:=TBookCompressionReceipt.Create(Data.ToJSON);
    try
      Stream:=TStringStream.Create(Result.ToJSON,TEncoding.UTF8);
      try SaveStreamAtomically(Stream,ReceiptFile); finally Stream.Free; end;
    except Result.Free; raise; end;
  finally Data.Free; end;
end;

procedure RunJob;
begin
  LastStage:='open-job';
  if Mode='job-list' then
  begin
    var Names:=TBookCompressionJob.Pending(Root+'queue');
    var List:=TJSONArray.Create;
    try
      for var Name in Names do List.Add(Name);
      TFile.WriteAllText(Root+'pending.json',List.ToJSON,TEncoding.UTF8);
    finally List.Free; end;
    Exit;
  end;
  if (Mode='job-recover') or (Mode='job-group-recover') then
  begin
    var Names:=TBookCompressionJob.Pending(Root+'queue');
    Require(Length(Names)=1,'Expected exactly one pending compression job');
    Job:=TBookCompressionJob.OpenExisting(Names[0]);
  end
  else
  begin
    Receipt:=LoadReceipt;
    try
      if (Mode='job-prepare-crash') or (Mode='job-prepare-hold') then
        Job:=TBookCompressionJob.CreatePrepared(Root+'queue',Receipt.ToJSON,Root+'candidate.bin',PreparationFault)
      else Job:=TBookCompressionJob.CreatePrepared(Root+'queue',Receipt.ToJSON,Root+'candidate.bin');
    finally Receipt.Free; Receipt:=nil; end;
  end;
  try
    TFile.WriteAllText(Report,Job.Directory,TEncoding.UTF8);
    if Mode='job-hold' then
    begin
      TFile.WriteAllText(Root+'hold-ready','ready');
      while not FileExists(Root+'release-hold') do Sleep(25);
    end;
    CrashAt('job-prepared');
    LastStage:='execute-job';
    if (FaultAt='-') and (Mode<>'job-group-change-row') then
      Job.Execute(function:Boolean begin Result:=Mode='job-cancel'; end)
    else Job.Execute(function:Boolean begin Result:=Mode='job-cancel'; end,nil,CrashAt);
    LastStage:='forget-job';
    Job.Forget;
    Writeln('PASS durable compression job');
  finally FreeAndNil(Job); end;
end;

procedure RunGroup;
var Group: TBookCompressionFileGroup; Data: TJSONObject; FilesJSON, Binding: string; StopRequested: Boolean;
    GroupFault: TProc<string>;
begin
  StopRequested:=False;
  GroupFault:=procedure(Stage: string)
    begin
      LastStage:=Stage;
      if (Mode='group-stop-after-first') and (Stage='group-file-committed-0') then StopRequested:=True;
      if Stage=FaultAt then
        if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
    end;
  Receipt:=LoadReceipt;
  try
    Data:=TJSONObject.ParseJSONValue(Receipt.ToJSON) as TJSONObject;
    try
      FilesJSON:=Data.GetValue<TJSONArray>('group_files').ToJSON;
      Binding:=TBookCompressionFileGroup.ComputeManifestSHA256(FilesJSON,Receipt.SHA256);
      if Mode.StartsWith('group-recover') then
      begin
        Require(TFile.ReadAllText(Root+'group-binding.txt',TEncoding.UTF8)=Binding,'Group binding changed');
        Group:=TBookCompressionFileGroup.OpenExisting(Root+'group',Binding,Receipt.SHA256);
      end
      else
      begin
        Receipt.CheckBeforeWrite;
        TFile.WriteAllText(Root+'group-binding.txt',Binding,TEncoding.UTF8);
        Group:=TBookCompressionFileGroup.CreatePrepared(Root+'group',FilesJSON,Receipt.SHA256,nil,nil,GroupFault);
      end;
      try
        Group.Execute(
          procedure(Engines: TArray<TZipMemberDeletion>) begin Receipt.Apply(Engines[0],GroupFault); end,
          procedure begin Receipt.CheckApplied; end,
          function:Boolean begin Result:=(Mode='group-cancel') or (Mode='group-recover-stopping') or StopRequested; end,nil,GroupFault);
        Group.Forget;
        Writeln('PASS linked archive group commits all files before catalogue and recovers through cleanup');
      finally Group.Free; end;
    finally Data.Free; end;
  finally FreeAndNil(Receipt); end;
end;

procedure RunTest;
begin
    Require(ParamCount=3,'Expected fixture root, mode and fault stage');
    Root:=IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
    Require(TFile.ReadAllText(Root+'fixture-owner.txt')='HomeLibre compression catalogue regression',
      'No owned fixture marker');
    Mode:=ParamStr(2); FaultAt:=ParamStr(3);
    ReceiptFile:=Root+'receipt.json'; Report:=Root+'job.txt';
    if Mode.StartsWith('group-') then begin RunGroup; Exit; end;
    if Mode.StartsWith('job-') then begin RunJob; Exit; end;
    Receipt:=LoadReceipt;
    try
      if Mode='preflight' then
      begin Receipt.CheckBeforeWrite; Writeln('PASS read-only compression preflight'); Halt(0); end;
      if (Mode='inspection') or (Mode='captured-inspection') or (Mode='inspection-cancel') then
      begin
        Receipt.RecordInspection(function:Boolean begin Result:=Mode='inspection-cancel'; end);
        Writeln('PASS unchanged book inspection'); Exit;
      end;
      var Data:=TJSONObject.ParseJSONValue(Receipt.ToJSON) as TJSONObject;
      try
        if Mode='recover' then
        begin
          var Job:=TFile.ReadAllText(Report,TEncoding.UTF8);
          Require(ExpandFileName(Job).StartsWith(Root,True),'Recovery escaped its fixture root');
          Engine:=TZipMemberDeletion.RecoverReplacement(Data.GetValue('source').Value,Job);
        end
        else
        begin
          Receipt.CheckBeforeWrite;
          Engine:=TZipMemberDeletion.PrepareReplacement(Data.GetValue('source').Value,Root+'candidate.bin',
            ArchiveDeletionSourceIdentity(Data.GetValue('source').Value),
            Data.GetValue('source_sha256').Value,Data.GetValue('result_sha256').Value,Root+'journal');
          Engine.BindContext(Receipt.SHA256);
        end;
        try
          if Mode='publish-only' then
          begin
            Engine.PublishJournal(Root+'journal');
            TFile.WriteAllText(Report,Engine.JobDirectory,TEncoding.UTF8);
            Writeln('PASS durable file journal published before source writes');
            Exit;
          end;
          Engine.Execute(Root+'journal');
          CrashAt('file-committed');
          var Changed:=Receipt.Apply(Engine,CrashAt);
          Engine.Acknowledge;
          Writeln('PASS compression catalogue receipt; size rows changed: ',Changed);
        finally Engine.Free; end;
      finally Data.Free; end;
    finally Receipt.Free; end;
end;

procedure RunCompressionReceiptFixture;
begin
  SetTextCodePage(Output,CP_UTF8);
  try RunTest;
  except on E:Exception do begin ErrorUTF8('FAIL '+E.ClassName+' ['+LastStage+']: '+E.Message); Halt(1); end; end;
end;

end.
