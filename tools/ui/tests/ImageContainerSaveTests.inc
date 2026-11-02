procedure TestImageContainerBookSaving;
const Profiles: array[0..1] of string = ('balanced','economy');
  Modes: array[0..2] of TExportMode = (emFB2,emFB2Zip,emEpub);
var Root, SourceName, OriginalHash, Required, Status, Capability, Backup: string;
  Books: TArray<TBookRecord>; Options: TBookSendOptions; Results: TBookExportResults;
  Probe: TUnifiedSendProbe; Sizes: array[0..2,0..1] of Int64;
  Choice: TBookSaveChoice; Worker: TBookSendEstimateThread; Items: TBookSaveEstimateItems;
  Revision: Integer; Complete, Raised: Boolean; Deadline: UInt64;
  Archive: TZipFile; Bytes: TBytes; Document: TReaderDocument;
begin
  Root:=Settings.AppPath+'mixed-save-inputs'; SourceName:=TPath.Combine(Root,'container-profile.fb2');
  Require(FileExists(SourceName),'Container profile fixture was not prepared');
  Books:=TArray<TBookRecord>.Create(FileBook(SourceName)); OriginalHash:=UpdateSHA256(SourceName);
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
  Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
  try
    for var M:=0 to High(Modes) do for var Q:=0 to High(Profiles) do
    begin
      Options:=Default(TBookSendOptions); Options.Mode:=Modes[M]; Options.ExplicitFormat:=True;
      Options.Folder:=TPath.Combine(Root,Format('container-%d-%d',[M,Q])); ForceDirectories(Options.Folder);
      Options.FileNameTemplate:='%t'; Options.ImageQuality:=Profiles[Q]; Options.NameCollision:=bncKeepBoth;
      Probe.Deadline:=GetTickCount64+120000; Probe.Messages.Clear; Probe.Worker:=nil;
      Probe.Timer.Enabled:=True;
      try Results:=SaveFileBooks(Books,Options,Required);
      finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
      Require((Required='') and (Probe.Failure='') and (Length(Results)=1),
        'Container Save As failed: '+Required+Probe.Failure);
      Require(Results[0].State=besSucceeded,Results[0].ErrorText+Probe.Messages.Text);
      Sizes[M,Q]:=TFile.GetSize(Results[0].OutputFile);
      var Readable:=Results[0].OutputFile;
      if Modes[M]=emFB2Zip then
      begin
        Archive:=TZipFile.Create;
        try
          Archive.Open(Readable,zmRead); Require(Archive.FileCount=1,'Unexpected packed book count');
          Archive.Read(Archive.FileNames[0],Bytes);
        finally Archive.Free; end;
        Readable:=TPath.Combine(Options.Folder,'decoded.fb2'); TFile.WriteAllBytes(Readable,Bytes);
      end;
      Document:=TReaderDocument.Create;
      try
        Document.Load(Readable);
        // Reader count includes a displayed cover; unique binary resources
        // are checked separately by the independent output decoder.
        Require(Document.ImageCount>0,Format('Container mode %d quality %d has no displayed illustration',[M,Q]));
        Require(Document.PlainText.Contains('Full text, final sentence. Ё, Україна, 中文.'),
          Format('Container mode %d quality %d lost body text: %s',[M,Q,Document.PlainText]));
      finally Document.Free; end;
      Require(UpdateSHA256(SourceName)=OriginalHash,'Container profile changed its source');
      Writeln('PASS native container profile mode=',M,' quality=',Profiles[Q],' bytes=',Sizes[M,Q]); Flush(Output);
    end;
  finally
    Application.OnModalBegin:=Probe.SavedModal; Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
  end;
  Require(Sizes[0,1]<Sizes[0,0],'Raw FB2 no longer uses its smaller raw candidate');
  Require(Sizes[1,1]<=Sizes[1,0]+256,'Economy FB2.ZIP is materially larger than balanced');
  Require(Sizes[2,1]<=Sizes[2,0]+256,'Economy EPUB is materially larger than balanced');
  Choice:=Default(TBookSaveChoice); Choice.Mode:=emFB2Zip;
  Worker:=TBookSendEstimateThread.Create(Books,Choice,Settings.AppPath,Settings.TempPath);
  try
    Revision:=-1; Complete:=False; Deadline:=GetTickCount64+120000; Worker.Start;
    repeat
      Application.ProcessMessages; Worker.Poll(Revision,Items,Status,Complete);
      if GetTickCount64>Deadline then begin Worker.Terminate; raise Exception.Create('Container estimate timeout: '+Status); end;
      if not Complete then Sleep(10);
    until Complete;
    Require((Length(Items)=1) and Items[0].Completed and (Items[0].ErrorText=''),'Container estimate failed');
    for var Q:=0 to High(Profiles) do
      Require(Abs(Items[0].Options.ZipOutputBytes[0,Q+1]-Sizes[1,Q])<1024,
        'ZIP estimate used a different image candidate from saving');
    Require(Items[0].Options.ZipOutputBytes[0,2]<=Items[0].Options.ZipOutputBytes[0,1]+256,
      'ZIP estimate still reverses economy and balanced');
  finally Worker.Free; end;
  Capability:=TPath.Combine(Settings.AppPath,'tools/bookconvert/IMAGE_CONTAINER_API.txt');
  Backup:=Capability+'.owned-test-backup'; Require(FileExists(Capability) and not FileExists(Backup),'Capability fixture unavailable');
  TFile.Move(Capability,Backup);
  try
    Raised:=False;
    try ConvertBasicBook(Settings.AppPath,Settings.TempPath,SourceName,'.fb2',TPath.Combine(Root,'missing-capability.fb2'),
      nil,nil,nil,'','','',False,nil,'economy',nil,False,'',True);
    except on E:EMHLComponentRequired do
    begin Raised:=True; Require(String.Join('|',E.ComponentIDs)='BookProcessing','Capability repair requested unrelated components'); end; end;
    Require(Raised and not FileExists(TPath.Combine(Root,'missing-capability.fb2')),'Old core ran before capability repair');
  finally TFile.Move(Backup,Capability); end;
  Require(UpdateSHA256(SourceName)=OriginalHash,'Estimate or capability inspection changed the source');
  Writeln('PASS native packed image profiles estimates content integrity and single core capability repair'); Flush(Output);
end;
