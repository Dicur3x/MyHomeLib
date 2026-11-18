procedure ExpectTitles(Tree:TBookTree; const Expected:array of string); forward;

type
  TTransferWorkflowProbe=class
    Timer:TTimer;
    Destination,Work,Failure,LastStage:string;
    Deadline:UInt64;
    Phase:Integer;
    InTick,SourcesSeen,WindowSeen,StopFirst,Stopped,Resumed,Completed,Startup,QuestionSeen:Boolean;
    DeclineQuestion,Declined,VisualMarked:Boolean;
    procedure Tick(Sender:TObject);
  end;

procedure TTransferWorkflowProbe.Tick(Sender:TObject);
var Dialog:TCustomForm;
begin
  if InTick then Exit; InTick:=True; Dialog:=nil;
  try
    try
      for var I:=Screen.FormCount-1 downto 0 do
        if Screen.Forms[I].Visible and
          ((Screen.Forms[I] is TfrmCatalogSources) or (Screen.Forms[I].Name='CollectionTransferWindow') or
            (Screen.Forms[I].Name='CollectionTransferResumeQuestion')) then
        begin Dialog:=Screen.Forms[I]; Break; end;
      if Dialog=nil then Exit;
      Require(GetTickCount64<Deadline,'Transfer workflow timed out: '+LastStage);
      if Dialog.Name='CollectionTransferResumeQuestion' then
      begin
        Require(Startup,'Unexpected automatic resume prompt during ordinary transfer'); QuestionSeen:=True;
        for var I:=0 to Dialog.ComponentCount-1 do
          if (Dialog.Components[I] is TButton) and
            (((not DeclineQuestion) and (TButton(Dialog.Components[I]).ModalResult=mrYes)) or
             (DeclineQuestion and (TButton(Dialog.Components[I]).ModalResult=mrNo))) then
          begin Declined:=DeclineQuestion; TButton(Dialog.Components[I]).Click; Exit; end;
        raise Exception.Create('Resume question has no Continue button');
      end;
      if Dialog is TfrmCatalogSources then
      begin
        var PPI:=StrToIntDef(GetEnvironmentVariable('HL_TRANSFER_PPI'),0);
        if PPI>0 then
        begin
          Dialog.ScaleForPPI(PPI); var Area:=Screen.WorkAreaRect;
          Dialog.SetBounds(Area.Left+8,Area.Top+8,Min(Dialog.Width,Area.Width-16),Min(Dialog.Height,Area.Height-16));
        end;
        var Transfer:=TButton(Dialog.FindComponent('btnTransferCollectionFiles'));
        Require(Assigned(Transfer) and Transfer.Visible and Transfer.Enabled,'Sources has no usable transfer command');
        Require(Transfer.Top+Transfer.Height<=Transfer.Parent.ClientHeight,'Sources transfer button is clipped');
        SourcesSeen:=True; Transfer.Click; Exit;
      end;
      WindowSeen:=True;
      var Run:=TButton(Dialog.FindComponent('RunCollectionTransfer'));
      var Preview:=TButton(Dialog.FindComponent('PreviewCollectionTransfer'));
      var Stop:=TButton(Dialog.FindComponent('StopCollectionTransfer'));
      var DestinationEdit:=TEdit(Dialog.FindComponent('TransferDestination'));
      var WorkEdit:=TEdit(Dialog.FindComponent('TransferWorkRoot'));
      var Stage:=TLabel(Dialog.FindComponent('TransferStage'));
      Require(Dialog.FindComponent('TransferCurrentFile') is TLabel,'Current transfer file became an input field');
      if Stage.Caption<>LastStage then
      begin LastStage:=Stage.Caption; Writeln('TRACE transfer workflow ',LastStage); Flush(Output); end;
      if Pos('Перенос завершён.',Stage.Caption)=1 then
      begin
        Require((not StopFirst) or (Stopped and Resumed),'Workflow omitted explicit stop/resume');
        Require(TForm(Dialog).FormStyle=fsStayOnTop,'Completion result did not come to the front');
        Require(not Run.Enabled and not Preview.Enabled,'Completed move can be started again');
        Require(Pos('Удалено рабочих файлов:',TMemo(Dialog.FindComponent('TransferReport')).Text)>0,
          'Completion omitted work-snapshot cleanup');
        Require(Pos('Уборка оставшихся рабочих снимков',TMemo(Dialog.FindComponent('TransferReport')).Text)=0,
          'Ordinary small transfer unexpectedly deferred cleanup');
        Completed:=True; TButton(Dialog.FindComponent('CloseCollectionTransfer')).Click; Exit;
      end;
      case Phase of
        0:
          begin
            if Startup then
            begin
              Require(not DestinationEdit.Enabled and not WorkEdit.Enabled and not Preview.Enabled,'Saved transfer paths can be edited');
              Require(QuestionSeen,'Startup resumed without an explicit choice'); Run.Click; Phase:=3; Exit;
            end;
            var PPI:=StrToIntDef(GetEnvironmentVariable('HL_TRANSFER_PPI'),0);
            if PPI>0 then
            begin
              Dialog.ScaleForPPI(PPI); var Area:=Screen.WorkAreaRect;
              Dialog.SetBounds(Area.Left+8,Area.Top+8,Min(Dialog.Width,Area.Width-16),Min(Dialog.Height,Area.Height-16));
            end;
            var Guide:=Dialog.FindComponent('TransferContextGuide') as TContextToolGuide;
            var Intro:=Dialog.FindComponent('TransferIntro') as TLabel;
            Require(Assigned(Guide) and Assigned(Intro) and Assigned(Guide.HelpButton.OnClick) and
              (Intro.BoundsRect.Right<=Guide.HelpButton.Left) and
              (Guide.HelpButton.BoundsRect.Right<=Dialog.ClientWidth),'Transfer help button overlaps introductory text');
            Guide.HelpButton.Click;
            var Help:=Guide.FindComponent('ToolGuidePopupcollectiontransfer') as TForm;
            Require(Assigned(Help) and Help.Visible and (not Run.Enabled),'Opening help changed the pending transfer');
            Help.Close;
            DestinationEdit.Text:=Destination; WorkEdit.Text:=Work;
            Require(WorkEdit.Width=DestinationEdit.Width,'Working-folder field shrank during DPI layout');
            Require(not Run.Enabled,'Transfer starts before its plan is checked');
            Preview.Click; Phase:=1;
          end;
        1:
          if Run.Enabled then
          begin
            Require(Pos('Место по дискам:',TMemo(Dialog.FindComponent('TransferReport')).Text)>0,
              'Transfer preview omitted the volume-space budget');
            Require(SendMessage(TMemo(Dialog.FindComponent('TransferReport')).Handle,EM_GETFIRSTVISIBLELINE,0,0)=0,
              'Transfer plan opened scrolled past its space budget');
            if GetEnvironmentVariable('HL_TRANSFER_VISUAL')='1' then
            begin
              if not VisualMarked then
              begin TFile.WriteAllText(Settings.AppPath+'transfer-visual-ready.marker','ready',TEncoding.UTF8); VisualMarked:=True; end;
              if not FileExists(Settings.AppPath+'transfer-visual-release.marker') then Exit;
            end;
            DestinationEdit.Text:=Destination+'-other';
            Require(not Run.Enabled,'Manually edited destination reused a stale plan');
            DestinationEdit.Text:=Destination; Preview.Click; Phase:=2;
          end;
        2:
          if Run.Enabled then
          begin
            Run.Click;
            if not Run.Enabled then
            begin
              Phase:=3;
              if StopFirst and not Stopped then begin Stop.Click; Stopped:=True; end
              else if Stopped then Resumed:=True;
            end;
          end;
        3:
          if Stopped and not Resumed and not Stop.Enabled then
          begin
            if Preview.Enabled then begin Preview.Click; Phase:=2; end
            else if Run.Enabled then begin Run.Click; if not Run.Enabled then Resumed:=True; end;
          end;
      end;
    except on E:Exception do begin Failure:=E.Message; Timer.Enabled:=False; if Dialog<>nil then Dialog.Close; end; end;
  finally InTick:=False; end;
end;

procedure RunTransferWorkflowUI(CID:Integer; const Destination,Work:string; StopFirst:Boolean);
begin
  if GetEnvironmentVariable('HL_TRANSFER_DARK')='1' then SetMHLTheme(True);
  var Choice:=TMenuItem.Create(nil);
  try Choice.Tag:=CID; frmMain.miActiveCollectionClick(Choice); finally Choice.Free; end;
  var ReadyUntil:=GetTickCount64+20000;
  while (frmMain.tvBooksA.GetFirst=nil) and (GetTickCount64<ReadyUntil) do
  begin Application.ProcessMessages; CheckSynchronize(5); end;
  var Probe:=TTransferWorkflowProbe.Create;
  try
    Probe.Destination:=Destination; Probe.Work:=Work; Probe.StopFirst:=StopFirst;
    Probe.Deadline:=GetTickCount64+180000;
    if GetEnvironmentVariable('HL_TRANSFER_VISUAL')='1' then Probe.Deadline:=GetTickCount64+600000;
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=20; Probe.Timer.OnTimer:=Probe.Tick;
    var Menu:=TMenuItem(frmMain.FindComponent('miCatalogSources'));
    Require(Assigned(Menu),'Main sources command is absent'); Menu.Click;
    Require(Probe.Failure='','Ordinary transfer workflow: '+Probe.Failure);
    Require(Probe.SourcesSeen and Probe.WindowSeen and Probe.Completed,'Ordinary transfer workflow did not finish');
    Require(Settings.ActiveCollection=CID,'Transfer switched to another active collection');
    ExpectTitles(frmMain.tvBooksA,['До переноса 0','До переноса 1','До переноса 2','До переноса 3','До переноса 4']);
    var CleanupTimer:=TTimer(frmMain.FindComponent('CollectionTransferCleanupTimer'));
    Require(Assigned(CleanupTimer),'Ordinary startup omitted background transfer cleanup');
    CleanupTimer.Interval:=1; var CleanupUntil:=GetTickCount64+15000;
    while Assigned(frmMain.FindComponent('CollectionTransferCleanupTimer')) and (GetTickCount64<CleanupUntil) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(not Assigned(frmMain.FindComponent('CollectionTransferCleanupTimer')),'Background cleanup did not finish');
    Writeln('PASS ordinary completion reports cleanup and delayed background cleanup finishes without a modal window');
    Writeln('PASS ordinary sources transfer refreshes the active Main book view and supports explicit stop resume and changed-plan invalidation');
  finally Probe.Timer.Free; Probe.Free; end;
end;
