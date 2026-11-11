unit BookCompressionReceiptFixture;

interface

procedure RunCompressionReceiptFixture;

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  unit_ZipMemberDeletion, unit_BookCompressionReceipt, unit_AtomicIniFile;

var Root, Mode, FaultAt, ReceiptFile, Report: string;
    Receipt: TBookCompressionReceipt;
    Engine: TZipMemberDeletion;

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
  if Stage<>FaultAt then Exit;
  TFile.WriteAllText(Report,Engine.JobDirectory,TEncoding.UTF8);
  if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
end;

function LoadReceipt: TBookCompressionReceipt;
var Data: TJSONObject; Value: TJSONValue; Stream: TStringStream;
begin
  if (Mode='recover') or (Mode='captured-apply') then
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
    Result:=TBookCompressionReceipt.Create(Data.ToJSON);
    try
      Stream:=TStringStream.Create(Result.ToJSON,TEncoding.UTF8);
      try SaveStreamAtomically(Stream,ReceiptFile); finally Stream.Free; end;
    except Result.Free; raise; end;
  finally Data.Free; end;
end;

procedure RunTest;
begin
    Require(ParamCount=3,'Expected fixture root, mode and fault stage');
    Root:=IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
    Require(TFile.ReadAllText(Root+'fixture-owner.txt')='HomeLibre compression catalogue regression',
      'No owned fixture marker');
    Mode:=ParamStr(2); FaultAt:=ParamStr(3);
    ReceiptFile:=Root+'receipt.json'; Report:=Root+'job.txt';
    Receipt:=LoadReceipt;
    try
      if Mode='preflight' then
      begin Receipt.CheckBeforeWrite; Writeln('PASS read-only compression preflight'); Halt(0); end;
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
  except on E:Exception do begin ErrorUTF8('FAIL '+E.ClassName+': '+E.Message); Halt(1); end; end;
end;

end.
