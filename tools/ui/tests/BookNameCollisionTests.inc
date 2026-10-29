type
  TBookCollisionProbe = class
    Timer: TTimer;
    Actions: TArray<Integer>;
    ApplyAll: Boolean;
    Calls, DPI: Integer;
    ExpectedTarget: string;
    function Prompt(const FileName: string; out ReplaceFile, All: Boolean): Boolean;
    procedure Tick(Sender: TObject);
  end;

function TBookCollisionProbe.Prompt(const FileName: string; out ReplaceFile, All: Boolean): Boolean;
begin
  Require(SameText(FileName,ExpectedTarget),'Collision prompt names a different output');
  Inc(Calls); Require(Calls<=Length(Actions),'Collision prompt repeated an apply-to-all decision');
  Result:=ChooseBookNameCollision(FileName,ReplaceFile,All);
end;

procedure TBookCollisionProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and (Screen.Forms[I].Name='BookNameCollision') then
    begin
      var Dialog:=Screen.Forms[I];
      if Dialog.CurrentPPI<>DPI then Dialog.ScaleForPPI(DPI);
      Require(TMemo(Dialog.FindComponent('ExistingOutputFile')).Text=ExpectedTarget,
        'Existing-file prompt hides or truncates the destination');
      var All:=TCheckBox(Dialog.FindComponent('ApplyToRemainingCollisions'));
      Require(not All.Checked,'Collision prompt silently applies a previous answer to the batch');
      All.Checked:=ApplyAll;
      var ButtonName:='KeepBothOutputFiles';
      if Actions[Calls-1]=mrYes then ButtonName:='ReplaceOutputFile'
      else if Actions[Calls-1]=mrCancel then ButtonName:='CancelOutputSaving';
      var Button:=TButton(Dialog.FindComponent(ButtonName));
      Require((Button.Left>=0) and (Button.Left+Button.Width<=Button.Parent.ClientWidth),
        'Collision action is outside the dialog at high DPI');
      Require(TButton(Dialog.FindComponent('KeepBothOutputFiles')).Default,
        'Default collision action must not replace an existing file');
      Button.Click; Exit;
    end;
end;

procedure TestBookNameCollisions;
var Root, SourceA, SourceB, Target: string; Books: TArray<TBookRecord>;
  Probe: TBookCollisionProbe; Capture: TBBEExportCapture; Results: TBookExportResults;
  function Run: TBookExportResults;
  var Worker: TExportToDeviceThread;
  begin
    Worker:=TExportToDeviceThread.Create;
    try
      Worker.StandaloneBooks:=Books; Worker.DeviceDir:=Root;
      Worker.FolderTemplate:=''; Worker.FileNameTemplate:='%t';
      Worker.KeepSourceFormat:=True; Worker.ImageQuality:='original';
      Worker.NameCollision:=bncAsk; Worker.OnNameCollision:=Probe.Prompt;
      Worker.OnShowMessage:=Capture.Message; Worker.OnTeletype:=Capture.Warning;
      Worker.Start; Worker.WaitFor;
      Require(not Assigned(Worker.FatalException),'Collision worker raised a fatal exception');
      Result:=Worker.Results;
    finally Worker.Free; end;
  end;
begin
  Require(Settings.SaveAsNameCollision=bncAsk,'Fresh Save As does not ask on a name collision');
  Root:=Settings.AppPath+'name-collisions'; ForceDirectories(Root);
  SourceA:=TPath.Combine(Root,'source-a.fb2'); SourceB:=TPath.Combine(Root,'source-b.fb2');
  TFile.WriteAllText(SourceA,'<FictionBook><body><section><p>ONE</p></section></body></FictionBook>',TEncoding.UTF8);
  TFile.WriteAllText(SourceB,'<FictionBook><body><section><p>TWO</p></section></body></FictionBook>',TEncoding.UTF8);
  Books:=TArray<TBookRecord>.Create(FileBook(SourceA),FileBook(SourceB));
  for var I:=0 to High(Books) do Books[I].Title:='Совпадение Ё';
  Target:=TPath.Combine(Root,'Совпадение Ё.fb2');
  Probe:=TBookCollisionProbe.Create; Capture:=TBBEExportCapture.Create;
  Probe.ExpectedTarget:=Target; Probe.DPI:=96;
  Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=30; Probe.Timer.OnTimer:=Probe.Tick;
  try
    TFile.WriteAllText(Target,'existing copy',TEncoding.UTF8);
    Probe.Actions:=TArray<Integer>.Create(mrNo,mrYes); Results:=Run;
    Require((Probe.Calls=2) and (Results[0].State=besSucceeded) and (Results[1].State=besSucceeded) and
      (Results[0].OutputFile<>Target) and (Results[1].OutputFile=Target),
      'Per-file keep-both/replace decisions were not respected');
    Require((UpdateSHA256(Target)=UpdateSHA256(SourceB)) and
      (UpdateSHA256(Results[0].OutputFile)=UpdateSHA256(SourceA)),
      'Per-file collision decision saved the wrong content');
    for var Replace in [False,True] do
    begin
      Probe.Calls:=0; Probe.ApplyAll:=True; Probe.DPI:=192;
      if Replace then Probe.Actions:=TArray<Integer>.Create(mrYes)
      else Probe.Actions:=TArray<Integer>.Create(mrNo);
      var Before:=UpdateSHA256(Target); Results:=Run;
      Require((Probe.Calls=1) and (Results[0].State=besSucceeded) and (Results[1].State=besSucceeded),
        'Apply-to-all repeated the question or lost a saved book');
      if Replace then Require((Results[0].OutputFile=Target) and (Results[1].OutputFile=Target) and
        (UpdateSHA256(Target)=UpdateSHA256(SourceB)),'Batch replacement made extra copies')
      else Require((Results[0].OutputFile<>Target) and (Results[1].OutputFile<>Target) and
        (UpdateSHA256(Target)=Before),'Batch keep-both replaced the existing output');
    end;
    Probe.Calls:=0; Probe.ApplyAll:=False; Probe.Actions:=TArray<Integer>.Create(mrCancel);
    var Before:=UpdateSHA256(Target); Results:=Run;
    Require((Probe.Calls=1) and (Results[0].State=besCanceled) and (Results[1].State=besPending) and
      (UpdateSHA256(Target)=Before),'Cancelling collision saving changed output or processed the rest');
    var HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
    Require(Succeeded(HR) or (HR=RPC_E_CHANGED_MODE),'Cannot initialize collision Shell check');
    try
      var Item:IShellItem;
      Require(Succeeded(SHCreateItemFromParsingName(PChar(Root),nil,IShellItem,Item)),
        'Cannot obtain collision Shell folder');
      Probe.Calls:=0; Probe.Actions:=TArray<Integer>.Create(mrYes);
      Require(ShellCopyFile(SourceA,Item,ExtractFileName(Target),False,SourceA,
        function(const Name:string; out ReplaceFile:Boolean):Boolean
        var All:Boolean;
        begin Result:=Probe.Prompt(Name,ReplaceFile,All); end),
        'Shell existing-file prompt failed');
      Require((Probe.Calls=1) and (UpdateSHA256(Target)=UpdateSHA256(SourceA)),
        'Shell copy bypassed the selected replacement');
      var Marshaled:IStream;
      Require(Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem,Item,Marshaled)),
        'Cannot marshal the protected source Shell folder');
      Books[0].Title:='source-a'; Books[1].Title:='safe-copy';
      var Worker:=TExportToDeviceThread.Create;
      try
        Capture.Messages.Clear;
        Worker.StandaloneBooks:=Books; Worker.DeviceDir:=Root;
        Worker.FolderTemplate:=''; Worker.FileNameTemplate:='%t';
        Worker.KeepSourceFormat:=True; Worker.ImageQuality:='original';
        Worker.NameCollision:=bncReplace; Worker.UseMTP:=True; Worker.MarshalStream:=Marshaled;
        Worker.OnShowMessage:=Capture.Message; Worker.OnTeletype:=Capture.Warning;
        var BeforeSource:=UpdateSHA256(SourceA); Worker.Start; Worker.WaitFor; Results:=Worker.Results;
        Require(not Assigned(Worker.FatalException) and (Results[0].State=besFailed) and
          (Results[1].State=besSucceeded) and (Capture.Messages.Count=1),
          'Protected source Shell collision stopped the batch or omitted its final report');
        Require((UpdateSHA256(SourceA)=BeforeSource) and
          (UpdateSHA256(TPath.Combine(Root,'safe-copy.fb2'))=UpdateSHA256(SourceB)),
          'Protected source Shell collision changed an original or lost the next book');
      finally Worker.Free; Marshaled:=nil; end;
      Item:=nil;
    finally if Succeeded(HR) then CoUninitialize; end;
    Writeln('PASS default ask per-file choices batch apply-to-all cancellation source content and Shell collisions at 96 and 192 DPI'); Flush(Output);
    Writeln('PASS protected source Shell collision reports one failed book continues the batch and preserves original bytes'); Flush(Output);
  finally Probe.Timer.Free; Probe.Free; Capture.Free; end;
end;
