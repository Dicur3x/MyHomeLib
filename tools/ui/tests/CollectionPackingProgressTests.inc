type
  TPackingCancelProbe = class
    Dialog: TfrmCollectionPackingProgress;
    SawLive, Clicked: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TPackingCancelProbe.Tick(Sender: TObject);
var Status:TCollectionPackingStatus;
begin
  Status:=Dialog.ReadStatus;
  if (Status.SourceName<>'') and (Status.SourcesTotal>0) then SawLive:=True;
  if not Clicked and (Status.SourcesDone>=1) and (Status.SourcesDone<Status.SourcesTotal) then
  begin Clicked:=True; TButton(Dialog.FindComponent('btnCancelPacking')).Click; end;
end;

procedure TestPackingProgress(const SourceOptions:TCollectionPackingOptions);
var Options:TCollectionPackingOptions; Dialog:TfrmCollectionPackingProgress;
  Status:TCollectionPackingStatus; Timer:TTimer; Probe:TPackingCancelProbe;
  Snapshot:TCollectionPackingSnapshot; SavedDark, Canceled:Boolean;
begin
  SavedDark:=MHLThemeDark;
  Status:=Default(TCollectionPackingStatus); Status.Stage:='Упаковываем архив'; Status.StageKey:='compressing';
  Status.SourceName:=StringOfChar('a',180)+' — русское название.zip';
  Status.SourcesDone:=12; Status.SourcesTotal:=100; Status.BooksDone:=123456; Status.BooksTotal:=1856990;
  Status.InputBytes:=Int64(10)*1024*1024*1024; Status.OutputBytes:=Int64(3)*1024*1024*1024;
  Status.Reused:=5; Status.ElapsedMS:=60000; Status.PackingMS:=60000;
  Require(PackingRemainingSeconds(Status)>0,'Completed work provides no estimated remaining time');
  try
    for var Dark in [False,True] do for var PPI in [96,144,192] do
    begin
      SetMHLTheme(Dark); Dialog:=TfrmCollectionPackingProgress.Create(frmMain);
      try
        Dialog.ScaleForPPI(PPI); Dialog.RenderStatus(Status);
        for var I:=0 to Dialog.ControlCount-1 do
        begin
          var Control:=Dialog.Controls[I];
          Require((Control.Left>=0) and (Control.Top>=0) and
            (Control.Left+Control.Width<=Dialog.ClientWidth) and
            (Control.Top+Control.Height<=Dialog.ClientHeight),'Packing progress control is clipped');
        end;
        Require(TProgressBar(Dialog.FindComponent('pbPackingStep')).Style=pbstMarquee,
          'Compressor percentage must remain unknown');
        Require(TProgressBar(Dialog.FindComponent('pbPackingOverall')).Position=120,
          'Overall progress does not use actual completed sources');
        Require(Pos('Осталось примерно',TLabel(Dialog.FindComponent('lblPackingTime')).Caption)>0,
          'Estimate is absent despite sufficient completed work');
        Require(TLabel(Dialog.FindComponent('lblPackingSource')).Hint=Status.SourceName,
          'Long source filename is not available in its hint');
      finally Dialog.Free; end;
    end;
  finally SetMHLTheme(SavedDark); end;
  Status.SourcesDone:=1; Require(PackingRemainingSeconds(Status)<0,'ETA guessed from one tiny source');
  Status.SourcesDone:=12; Status.StageKey:='native';
  Require(PackingRemainingSeconds(Status)<0,'Packing ETA leaked into native catalogue validation');

  Options:=SourceOptions; Options.OutputRoot:=Settings.AppPath+'progress-copy';
  Options.Dataset:='native-progress-fixture'; Options.DisplayName:='Progress fixture';
  Dialog:=TfrmCollectionPackingProgress.Create(frmMain); Probe:=TPackingCancelProbe.Create;
  Timer:=TTimer.Create(nil); Snapshot:=nil; Canceled:=False;
  try
    Probe.Dialog:=Dialog; Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
    try Snapshot:=Dialog.Execute(Options); except on E:EAbort do Canceled:=True; end;
    Require(Canceled and Probe.Clicked and Probe.SawLive,'Progress form did not cancel real active packing');
    Require(not TButton(Dialog.FindComponent('btnCancelPacking')).Enabled,'Cancel button allows repeated submissions');
    Require(not FileExists(Options.OutputRoot+'\collection.hlc2'),'Canceled progress published a catalogue');
  finally Timer.Free; Probe.Free; Snapshot.Free; Dialog.Free; end;
  Dialog:=TfrmCollectionPackingProgress.Create(frmMain); Snapshot:=nil;
  try
    Snapshot:=Dialog.Execute(Options); Status:=Dialog.ReadStatus;
    Require((Status.SourcesDone=5) and (Status.SourcesTotal=5) and
      (Status.BooksDone>=7) and (Status.BooksDone=Status.BooksTotal) and
      (Status.InputBytes>0) and (Status.OutputBytes>0) and (Status.Reused>=1),
      'Resumed progress form lost real counts, bytes or completed archives');
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
      'Progress window registered a copy before review');
    // Returned snapshots cannot retain callbacks into the closed progress form.
    Dialog.Free; Dialog:=nil;
    Require(Snapshot.RegisterNew(SystemDB)>0,'Prepared result did not survive its progress window');
  finally Snapshot.Free; Dialog.Free; end;
  Writeln('PASS packing progress live worker cancel resume real counts bytes no invented percent ETA and 96 144 192 DPI');
end;
