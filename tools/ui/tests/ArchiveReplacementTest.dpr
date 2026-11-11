program ArchiveReplacementTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, Winapi.Windows,
  unit_ZipMemberDeletion;

type
  TNoSpaceReplacement = class(TZipMemberDeletion)
  protected
    function JournalSpaceAvailable(const Directory: string): UInt64; override;
  end;
  TWriterClass = class of TZipMemberDeletion;

var Engine: TZipMemberDeletion;
    Root, Source, Candidate, Journal, Report, Mode, FaultAt, SourceHash, ResultHash: string;

function TNoSpaceReplacement.JournalSpaceAvailable(const Directory: string): UInt64;
begin Result:=0; end;

procedure Require(Value: Boolean; const MessageText: string);
begin
  if not Value then raise Exception.Create(MessageText);
end;

procedure Fault(const Stage: string; Chunk: Integer);
begin
  if (Mode='discard-empty-payload') and (Stage='journal-published') then
  begin
    var Path:=TPath.Combine(Engine.JobDirectory,'replacement.bin');
    Require(TFile.GetSize(Path)=0,'Fixture tried to discard nonempty recovery data');
    TFile.Delete(Path);
  end;
  if Stage<>FaultAt then Exit;
  TFile.WriteAllText(Report,Engine.JobDirectory,TEncoding.UTF8);
  // Do not run destructors: recovery must survive an actual process loss.
  if not TerminateProcess(GetCurrentProcess,73) then RaiseLastOSError;
end;

begin
  SetTextCodePage(Output,CP_UTF8);
  try
    Require(ParamCount=9,'Expected nine fixture arguments');
    Root:=IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(1)));
    Require(TFile.ReadAllText(Root+'fixture-owner.txt')='HomeLibre archive replacement regression',
      'No owned regression fixture marker');
    Source:=ExpandFileName(ParamStr(2)); Candidate:=ExpandFileName(ParamStr(3));
    Journal:=ExpandFileName(ParamStr(4)); Report:=Root+'job.txt';
    for var Path in [Source,Candidate,Journal] do
      Require(Path.StartsWith(Root,True),'Fixture escaped its private root');
    Mode:=ParamStr(5); FaultAt:=ParamStr(6);
    SourceHash:=ParamStr(7); ResultHash:=ParamStr(8);
    if Mode='recover' then
      Engine:=TZipMemberDeletion.RecoverReplacement(Source,TFile.ReadAllText(Report,TEncoding.UTF8))
    else if Mode='recover-delete' then
      Engine:=TZipMemberDeletion.Recover(Source,TFile.ReadAllText(Report,TEncoding.UTF8))
    else if Mode='wrong-recovery-kind' then
      Engine:=TZipMemberDeletion.Recover(Source,TFile.ReadAllText(Report,TEncoding.UTF8))
    else if Mode='delete' then
      Engine:=TZipMemberDeletion.Prepare(Source,['one.fb2'])
    else
    begin
      var Identity:=ArchiveDeletionSourceIdentity(Source);
      if Mode='wrong-identity' then Identity:=StringOfChar('0',59);
      var EngineClass:TWriterClass:=TZipMemberDeletion;
      if Mode='no-space' then EngineClass:=TNoSpaceReplacement;
      Engine:=EngineClass.PrepareReplacement(Source,Candidate,Identity,SourceHash,ResultHash,
        Journal,function:Boolean begin Result:=Mode='cancel'; end);
    end;
    try
      if (Mode<>'recover') and (Mode<>'recover-delete') then Engine.BindContext(StringOfChar('a',64));
      Engine.EnableWholeRemoval;
      Require(Engine.WholeSourceIdentity='','Compression became a whole-file deletion');
      if Mode='prepare-only' then
      begin
        Require(not Engine.Finished,'Preparation changed the source');
        Writeln('PASS prepared without source commit');
      end
      else
      begin
        Engine.Execute(Journal,nil,Fault);
        Require(Engine.Finished,'Replacement did not finish');
        Require(Engine.ContextHash=StringOfChar('a',64),'Receipt context lost');
        if (Mode<>'delete') and (Mode<>'recover-delete') then Engine.RemoveEmptyArchive;
        if ParamStr(9)='hold' then
          TFile.WriteAllText(Report,Engine.JobDirectory,TEncoding.UTF8)
        else
        begin
          Engine.Acknowledge;
          if (Mode='delete') or (Mode='recover-delete') then Engine.RemoveEmptyArchive;
        end;
        Require(FileExists(Source),'Replacement removed its source file');
        Writeln('PASS verified replacement');
      end;
    finally Engine.Free; end;
  except
    on E:Exception do
    begin Writeln('FAIL ',E.ClassName,': ',E.Message); Halt(1); end;
  end;
end.
