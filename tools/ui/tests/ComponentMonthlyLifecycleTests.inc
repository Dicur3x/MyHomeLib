type
  TComponentMonthlyDriver = class
    Host: TfrmReaderHost;
    Timer: TTimer;
    Started: UInt64;
    Mode, Error: string;
    ClosedBook, SeenOffer, TurnedPage: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TComponentMonthlyDriver.Tick(Sender: TObject);
var Offer: TCustomForm; View: TfrmBuiltinReader; PID: DWORD;
begin
  Offer:=nil; View:=nil;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I].Name='ComponentMaintenance') and Screen.Forms[I].Visible then Offer:=Screen.Forms[I];
  if Assigned(Host) then
    for var I:=0 to Host.ComponentCount-1 do
      if Host.Components[I] is TfrmBuiltinReader then View:=TfrmBuiltinReader(Host.Components[I]);
  try
    Require(GetTickCount64-Started<70000,'Ordinary monthly lifecycle deadline exceeded: '+Mode);
    if Assigned(Offer) then
    begin
      Require((Mode='main-idle') or ((Mode='reader-close') and ClosedBook),
        'Monthly offer interrupted reading or updater closure: '+Mode);
      var Items:=TListView(Offer.FindComponent('MaintenanceModules'));
      Require((Items.Items.Count=1) and not Items.Items[0].Checked,
        'Ordinary monthly offer included a recent module or selected removal');
      SeenOffer:=True; TButton(Offer.FindComponent('MaintenanceClose')).Click; Exit;
    end;
    if (Mode='main-idle') or ClosedBook or not Assigned(View) or not View.Visible or
      not View.Ready or View.PageLoading then Exit;
    Require(View.BookText.Contains('MONTHLY LIFECYCLE BOOK'),'Reader did not open the actual fixture');
    if not TurnedPage then begin TurnedPage:=True; View.NextPage; Exit; end;
    Require(View.TextPosition>0,'Reader did not turn the fixture page before closing');
    // Closing an active book is intentionally distinguished from a background
    // updater request. Allow Computer Use to activate this owned test window;
    // do not pretend Windows granted a rejected SetForegroundWindow request.
    PID:=0;
    GetWindowThreadProcessId(GetForegroundWindow,PID);
    if PID<>GetCurrentProcessId then Exit;
    ClosedBook:=True;
    if Mode='host-close-first' then
    begin
      SendMessage(Host.Handle,WM_CLOSE,0,0);
      PostMessage(View.Handle,WM_CLOSE,0,0);
    end
    else if Mode='book-close-first' then
    begin
      PostMessage(View.Handle,WM_CLOSE,0,0);
      PostMessage(Host.Handle,WM_CLOSE,0,0);
    end
    else View.Close;
  except
    on E: Exception do
    begin
      Error:=E.ClassName+': '+E.Message; Timer.Enabled:=False;
      SetComponentCleanupSuppressed(Settings.AppPath,True);
      if Assigned(Offer) then Offer.Close;
      if Assigned(View) then View.Close;
    end;
  end;
end;

procedure TestComponentMonthlyLifecycle;
var StateName, Source, SourceHash, ModuleName, ModuleHash: string; SavedState: TBytes;
  HadState, OldShowMain: Boolean; Driver: TComponentMonthlyDriver;
  Host: TfrmReaderHost; Book: TBookRecord; Request: TReaderSessionRequest; Reply: TReaderSessionReply;
  Unused: TArray<string>;
  procedure SeedUnusedModule;
  var Root, Modules, Row: TJSONObject; Time: string;
  begin
    Time:=DateToISO8601(TTimeZone.Local.ToUniversalTime(Now)-31,True);
    Root:=TJSONObject.Create;
    try
      Root.AddPair('format',TJSONNumber.Create(1)); Modules:=TJSONObject.Create; Root.AddPair('modules',Modules);
      Row:=TJSONObject.Create; Modules.AddPair('WebP',Row); Row.AddPair('firstSeenUtc',Time);
      ForceDirectories(ExtractFileDir(StateName)); TFile.WriteAllText(StateName,Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
  end;
  procedure StartDriver(const Mode: string; ReaderHost: TfrmReaderHost);
  begin
    Driver:=TComponentMonthlyDriver.Create; Driver.Mode:=Mode; Driver.Host:=ReaderHost;
    Driver.Started:=GetTickCount64; Driver.Timer:=TTimer.Create(nil);
    Driver.Timer.Interval:=100; Driver.Timer.OnTimer:=Driver.Tick;
  end;
  procedure StopDriver;
  begin Driver.Timer.Free; Driver.Free; end;
begin
  RequireIsolatedRegression;
  StateName:=CheckedUpdateChildPath(Settings.AppPath,'tools/component-state/usage.json');
  HadState:=FileExists(StateName); if HadState then SavedState:=TFile.ReadAllBytes(StateName);
  ModuleName:=CheckedUpdateChildPath(Settings.AppPath,ComponentFileName('WebP'));
  Require(FileExists(ModuleName),'Isolated runtime must include the existing WebP module');
  ModuleHash:=UpdateSHA256(ModuleName); OldShowMain:=Application.ShowMainForm;
  try
    SeedUnusedModule; StartDriver('main-idle',nil);
    try
      frmMain.Show; frmMain.BringToFront; SetForegroundWindow(frmMain.Handle);
      repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      until Driver.SeenOffer or (Driver.Error<>'');
      Require(Driver.Error='',Driver.Error);
      Require(Driver.SeenOffer,'Normal catalogue scheduler did not show the combined monthly offer');
    finally StopDriver; end;
    Writeln('PASS real catalogue idle scheduler presents monthly offer without direct test invocation');

    Source:=TPath.Combine(Settings.AppPath,'monthly-lifecycle.fb2');
    var Content:='<FictionBook><body><section><title><p>MONTHLY LIFECYCLE BOOK</p></title>';
    for var I:=1 to 80 do Content:=Content+'<p>MONTHLY LIFECYCLE BOOK paragraph '+IntToStr(I)+
      ' Preserved original text for the actual reader and its update-close path.</p>';
    TFile.WriteAllText(Source,Content+'</section></body></FictionBook>',TEncoding.UTF8);
    SourceHash:=UpdateSHA256(Source);
    for var Mode in ['reader-close','host-close-first','book-close-first'] do
    begin
      SeedUnusedModule;
      Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Include(Book.BookProps,bpIsLocal);
      Book.CollectionRoot:=Settings.AppPath; Book.FileName:='monthly-lifecycle'; Book.FileExt:='.fb2';
      Book.BookKey:=CreateBookKey(4321,90); Book.Title:='MONTHLY LIFECYCLE BOOK'; Book.Size:=TFile.GetSize(Source);
      Request:=CreateReaderSession(Settings.AppPath,Book,'monthly-'+Mode,
        TPath.Combine(Settings.DataDir,'monthly-'+Mode+'-reader.ini'));
      Host:=TfrmReaderHost.Create(nil); StartDriver(Mode,Host);
      try
        Host.OpenInitialSession(Request.RequestFile); Host.Show;
        repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
        until (TryReadReaderSessionReply(Request,Reply) and ((Reply.State='closed') or (Reply.State='failed'))) or
          (Driver.Error<>'') or (GetTickCount64-Driver.Started>75000);
        Require(Driver.Error='',Driver.Error);
        Require(Driver.ClosedBook and (Reply.State='closed') and Reply.HasProgress,
          Format('Ordinary reader lifecycle lost session completion: %s state=%s progress=%d close=%d',
            [Mode,Reply.State,Ord(Reply.HasProgress),Ord(Driver.ClosedBook)]));
        if Mode='reader-close' then Require(Driver.SeenOffer,'Active user book close did not offer monthly cleanup')
        else
        begin
          Require(not Driver.SeenOffer,'Updater close opened a cleanup dialog: '+Mode);
          Require(ReserveUnusedComponentOffer(Settings.AppPath,TArray<string>.Create('WebP'),Unused),
            'Updater close silently consumed the future monthly offer: '+Mode);
        end;
        Require((UpdateSHA256(Source)=SourceHash) and (UpdateSHA256(ModuleName)=ModuleHash),
          'Ordinary monthly lifecycle changed original books or modules');
        Writeln('PASS real reader monthly lifecycle '+Mode+' preserves source module and session progress');
      finally StopDriver; Host.Free; end;
    end;
  finally
    Application.ShowMainForm:=OldShowMain;
    if HadState then TFile.WriteAllBytes(StateName,SavedState) else if FileExists(StateName) then TFile.Delete(StateName);
  end;
end;
