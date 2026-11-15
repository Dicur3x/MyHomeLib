program CollectionTransferCopyTest;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Generics.Collections, Winapi.Windows,
  NativeRegressionGuard, unit_ZipMemberDeletion, unit_CollectionTransferPlan, unit_CollectionTransferCopy;

var ExternalSourceRoot:string;

function OwnedPath(const Path:string):string;
begin
  Result:=ExpandFileName(Path);
  if not Result.StartsWith(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))),True) then
    raise EReadError.Create('Copy fixture path is outside its owned runtime');
end;

procedure ValidateExternalSource;
begin
  if ExternalSourceRoot='' then Exit;
  ExternalSourceRoot:=ExcludeTrailingPathDelimiter(ExpandFileName(ExternalSourceRoot));
  var Drive:=ExtractFileDrive(ExternalSourceRoot);
  if (Length(Drive)<>2) or SameText(Drive,'C:') or SameText(Drive,ExtractFileDrive(ParamStr(0))) or
    not SameFileName(ExtractFileDir(ExternalSourceRoot),Drive+'\') or
    not ExtractFileName(ExternalSourceRoot).StartsWith('HomeLibRu-native-source-') or
    not SameFileName(TransferCanonicalDirectory(ExternalSourceRoot),IncludeTrailingPathDelimiter(ExternalSourceRoot)) then
    raise EReadError.Create('External source is not a private cross-volume fixture root');
  var Marker:=TPath.Combine(ExternalSourceRoot,'transfer-source.marker');
  if TFile.ReadAllText(Marker,TEncoding.UTF8)<>'HomeLibre isolated transfer source v1'+sLineBreak+
    ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) then
    raise EReadError.Create('External source does not belong to this runtime');
end;

function OwnedSourcePath(const Path:string):string;
begin
  Result:=ExpandFileName(Path);
  if Result.StartsWith(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))),True) then Exit;
  if (ExternalSourceRoot<>'') and SameFileName(Result,TPath.Combine(ExternalSourceRoot,'same.zip')) then Exit;
  raise EReadError.Create('Source is outside the private runtime and its declared cross-volume fixture');
end;

function JSONFile(const Path:string):TJSONObject;
begin
  Result:=TJSONObject.ParseJSONValue(TFile.ReadAllText(OwnedPath(Path),TEncoding.UTF8)) as TJSONObject;
  if Result=nil then raise EReadError.Create('Invalid fixture JSON');
end;

var Request,Attempt,Output:TJSONObject; Entry:TCollectionTransferFile;
    Job:TCollectionTransferCopy; Prepared:TTransferPreparedCopy;
    WorkRoot,AllowedRoot,AttemptFile,Crash,Canonical,Probe:string;
    Bytes:Int64; Stop,Rejected:Boolean; Reader,Writer:TFileStream; Hooks,Copies:Integer;
begin
  SetTextCodePage(System.Output,CP_UTF8);
  try
    RequireIsolatedRegression;
    if ParamCount<>2 then raise EArgumentException.Create('Expected request and result');
    Request:=JSONFile(ParamStr(1)); Job:=nil; Prepared:=nil;
    try
      ExternalSourceRoot:=Request.GetValue<string>('external_source_root',''); ValidateExternalSource;
      Entry:=Default(TCollectionTransferFile); Stop:=False; Hooks:=0; Copies:=0;
      WorkRoot:=OwnedPath(Request.GetValue<string>('work')); AllowedRoot:=OwnedPath(Request.GetValue<string>('root'));
      AttemptFile:=OwnedPath(Request.GetValue<string>('attempt')); Crash:=Request.GetValue<string>('crash','');
      if Request.GetValue<Boolean>('resume',False) then
      begin
        Attempt:=JSONFile(AttemptFile);
        try
          Entry.Source:=OwnedSourcePath(Attempt.GetValue<string>('source'));
          Entry.Destination:=OwnedPath(Attempt.GetValue<string>('destination'));
          Entry.Identity:=Attempt.GetValue<string>('identity'); Entry.Bytes:=Attempt.GetValue<Int64>('bytes');
          Entry.KeepInPlace:=Attempt.GetValue<Boolean>('keep');
          Job:=TCollectionTransferCopy.Resume(WorkRoot,AllowedRoot,OwnedPath(Attempt.GetValue<string>('directory')),Entry);
        finally Attempt.Free; end;
      end
      else
      begin
        TransferReadFileState(OwnedSourcePath(Request.GetValue<string>('source')),Canonical,Entry.Identity,Bytes);
        Entry.Source:=Canonical; Entry.Bytes:=Bytes;
        Entry.Destination:=OwnedPath(Request.GetValue<string>('destination'));
        Entry.KeepInPlace:=SameFileName(Entry.Source,Entry.Destination);
        Job:=TCollectionTransferCopy.CreateNew(WorkRoot,AllowedRoot,Entry);
        Attempt:=TJSONObject.Create;
        try
          Attempt.AddPair('source',Entry.Source); Attempt.AddPair('destination',Entry.Destination);
          Attempt.AddPair('identity',Entry.Identity); Attempt.AddPair('bytes',TJSONNumber.Create(Entry.Bytes));
          Attempt.AddPair('keep',TJSONBool.Create(Entry.KeepInPlace)); Attempt.AddPair('directory',Job.Directory);
          TFile.WriteAllText(AttemptFile,Attempt.ToJSON,TEncoding.UTF8);
        finally Attempt.Free; end;
      end;
      Probe:=Request.GetValue<string>('wait_for_release','');
      if Probe<>'' then
      begin
        Probe:=OwnedPath(Probe); TFile.WriteAllText(Probe+'.waiting','ready',TEncoding.UTF8);
        var Started:=GetTickCount64;
        while not FileExists(Probe) do
        begin if GetTickCount64-Started>20000 then raise EAbort.Create('Fixture wait expired'); Sleep(25); end;
      end;
      TransferCopyTestPoint:=
        procedure(Stage,Directory:string)
        begin
          Inc(Hooks);
          if Stage='copy-stream-start' then Inc(Copies);
          if Stage=Crash then begin Writeln('CRASH ',Stage); Flush(System.Output); Halt(97); end;
          if (Stage='after-verified') and Request.GetValue<Boolean>('occupy_destination',False) then
            TFile.WriteAllText(OwnedPath(Entry.Destination),'foreign fixture result',TEncoding.UTF8);
          if (Stage='after-attempt-intent') and Request.GetValue<Boolean>('occupy_temporary',False) then
          begin
            var Records:=TDirectory.GetFiles(Directory,'state-*.json'); TArray.Sort<string>(Records);
            var Wrapped:=JSONFile(Records[High(Records)]);
            try
              var State:=TJSONObject.ParseJSONValue(Wrapped.GetValue<string>('payload')) as TJSONObject;
              try
                var Path:=OwnedPath(TPath.Combine(ExtractFilePath(Entry.Destination),State.GetValue<string>('temporary')));
                TFile.WriteAllText(Path,'foreign fixture temporary',TEncoding.UTF8);
              finally State.Free; end;
            finally Wrapped.Free; end;
          end;
        end;
      Prepared:=Job.Prepare(
        function:Boolean
        begin Result:=Stop; end,
        procedure(const Stage:string; Done,Total:Int64)
        begin
          if Request.GetValue<Boolean>('cancel_copy',False) and (Stage='Копирование') and (Done>0) then Stop:=True;
        end);
      // Normal native readers must coexist with the retained publication lease.
      Reader:=TFileStream.Create(DeletionNativePath(OwnedPath(Prepared.Destination)),fmOpenRead or fmShareDenyWrite);
      try if Reader.Size<>Entry.Bytes then raise EReadError.Create('Native reader has the wrong size'); finally Reader.Free; end;
      Rejected:=False;
      try Writer:=TFileStream.Create(DeletionNativePath(OwnedPath(Prepared.Destination)),fmOpenReadWrite or fmShareDenyNone); Writer.Free;
      except on E:EFOpenError do Rejected:=True; end;
      if not Rejected then raise EWriteError.Create('Prepared copy did not deny writers');
      Output:=TJSONObject.Create;
      try
        Output.AddPair('status','PASS'); Output.AddPair('directory',Job.Directory);
        Output.AddPair('source',Prepared.Source); Output.AddPair('destination',Prepared.Destination);
        Output.AddPair('identity',Prepared.Identity); Output.AddPair('sha256',Prepared.SHA256);
        Output.AddPair('streams',Prepared.StreamsJSON); Output.AddPair('copy_streams',TJSONNumber.Create(Copies));
        Output.AddPair('hooks',TJSONNumber.Create(Hooks));
        TFile.WriteAllText(OwnedPath(ParamStr(2)),Output.ToJSON,TEncoding.UTF8);
      finally Output.Free; end;
      Writeln('PASS verified file copy with retained read leases');
    finally
      TransferCopyTestPoint:=nil; Prepared.Free; Job.Free; Request.Free;
    end;
  except on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end; end;
end.
