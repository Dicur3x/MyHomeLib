type
  TInventoryDialog = class(TfrmComponentMaintenance)
  public
    Consent: Boolean;
    Confirmations: Integer;
    ConfirmedSize: Int64;
    SelectedArchive: string;
    ArchiveSelections: Integer;
  protected
    function ConfirmInventoryDownload(Size: Int64): Boolean; override;
    function ChooseInventoryArchive(out Archive: string): Boolean; override;
  end;

function TInventoryDialog.ConfirmInventoryDownload(Size: Int64): Boolean;
begin Inc(Confirmations); ConfirmedSize:=Size; Result:=Consent; end;

function TInventoryDialog.ChooseInventoryArchive(out Archive: string): Boolean;
begin Inc(ArchiveSelections); Archive:=SelectedArchive; Result:=Archive<>''; end;

procedure TestComponentInventoryUI;
var Server: TUFNServer; Dialog: TInventoryDialog; Available: TComponentReleases;
  LastWorker: TUFNDownloadWorker; Info: TProgramRelease; Resolve: TButton;
  Target, Archive, Job, Primary, PrimaryHash, Receipt: string;
  FactoryCalls, BeforeRequests, BeforeCreated, BeforeFreed: Integer;
  procedure WaitPlan;
  var Started: UInt64;
  begin
    Started:=GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    until Dialog.PlanReady or (GetTickCount64-Started>15000);
    Require(Dialog.PlanReady,'Inventory UI plan did not finish');
  end;
  procedure WaitClosed;
  var Started: UInt64;
  begin
    Started:=GetTickCount64;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
    until (Dialog.ModalResult=mrCancel) or (GetTickCount64-Started>15000);
    Require(Dialog.ModalResult=mrCancel,'Inventory download cancellation did not finish');
  end;
  procedure PrepareCase(const Mode: string);
  var Root, Codec, Hashes, Entry: TJSONObject; Files: TJSONArray; Zip: TZipFile;
    Name, FullName: string;
  begin
    Target:=Settings.AppPath+'inventory-ui-'+Mode; ForceDirectories(Target+'\Data');
    TFile.WriteAllText(Target+'\HomeLibRu.exe','OWNED NONEXECUTABLE APPLICATION');
    TFile.WriteAllText(Target+'\Data\notes.json','private preserved notes');
    Primary:=CheckedUpdateChildPath(Target,ComponentFileName('WebP')); ForceDirectories(ExtractFileDir(Primary));
    TFile.Copy(CheckedUpdateChildPath(Settings.AppPath,ComponentFileName('WebP')),Primary);
    PrimaryHash:=UpdateSHA256(Primary); Root:=TJSONObject.Create;
    try
      Root.AddPair('component','WebP'); Codec:=TJSONObject.Create; Root.AddPair('codec',Codec);
      Codec.AddPair('version','1.6.0'); Hashes:=TJSONObject.Create; Codec.AddPair('files',Hashes);
      Hashes.AddPair('libwebp.dll',PrimaryHash);
      TFile.WriteAllText(ExtractFileDir(Primary)+'\RUNTIME.json',Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
    for Name in ['COPYING.txt','PATENTS.txt','AUTHORS.txt'] do
      TFile.WriteAllText(ExtractFileDir(Primary)+'\'+Name,'OWNED INVENTORY FIXTURE '+Name);
    TFile.WriteAllText(ExtractFileDir(Primary)+'\private-notes.txt','unlisted private file');
    Receipt:=CheckedUpdateChildPath(Target,ComponentReceiptName('WebP'));
    Require(InstalledComponentVersion(Target,'WebP')='1.6.0','Existing codec fixture has no recognized version');
    Archive:=Settings.AppPath+'inventory-ui-'+Mode+'.zip'; Zip:=TZipFile.Create; Root:=TJSONObject.Create;
    try
      Root.AddPair('format',TJSONNumber.Create(1)); Root.AddPair('release',ALREADER_FIXED_TAG);
      Root.AddPair('platform',ProgramUpdatePlatform);
      if Mode='local-bad-manifest' then Root.AddPair('component','SQLite') else Root.AddPair('component','WebP');
      Root.AddPair('version','1.6.0');
      Files:=TJSONArray.Create; Root.AddPair('files',Files); Zip.Open(Archive,zmWrite);
      for Name in ['libwebp.dll','RUNTIME.json','COPYING.txt','PATENTS.txt','AUTHORS.txt'] do
      begin
        var Member:='tools/webp/'+Name; FullName:=CheckedUpdateChildPath(Target,Member); Zip.Add(FullName,Member);
        Entry:=TJSONObject.Create; Entry.AddPair('path',Member); Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(FullName)));
        Entry.AddPair('sha256',UpdateSHA256(FullName)); Files.AddElement(Entry);
      end;
      Zip.Add(TEncoding.UTF8.GetBytes(Root.ToJSON),UPDATE_MANIFEST); Zip.Close;
    finally Root.Free; Zip.Free; end;
    Info:=Default(TProgramRelease); Info.ComponentID:='WebP'; Info.ComponentVersion:='1.6.0';
    Info.Tag:=ALREADER_FIXED_TAG; Info.SHA256:=UpdateSHA256(Archive); Info.Size:=TFile.GetSize(Archive);
    Info.DownloadURL:=Server.URL+'download'; Server.Payload:=TFile.ReadAllBytes(Archive);
    Server.Requested.ResetEvent; Server.Released.SetEvent; Server.Failure:='';
    BeforeRequests:=Server.Requests; BeforeCreated:=Server.CreatedWorkers; BeforeFreed:=Server.FreedWorkers;
    Available:=Default(TComponentReleases);
    for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      if UPDATE_COMPONENTS[I].ID='WebP' then Available[I]:=Info;
  end;
  procedure CreateDialog;
  begin
    FactoryCalls:=0; LastWorker:=nil;
    Dialog:=TInventoryDialog.CreateManager(frmMain,Target,False,False,TArray<string>.Create('WebP'),Available,
      function(const ReleaseInfo: TProgramRelease; const Destination: string): TProgramDownloadThread
      begin
        Inc(FactoryCalls); Job:=Destination;
        LastWorker:=TUFNDownloadWorker.Create(0,ReleaseInfo,Destination,Server); Result:=LastWorker;
      end);
    Dialog.Show; WaitPlan; Dialog.Consent:=True; Dialog.SelectedArchive:=Archive;
    Resolve:=TButton(Dialog.FindComponent('MaintenanceInventory'));
    Require(Resolve.Enabled and not TButton(Dialog.FindComponent('MaintenanceRemove')).Enabled,
      'Unknown existing inventory was removable before verification');
  end;
  procedure RequirePrivate;
  begin
    Require((UpdateSHA256(Primary)=PrimaryHash) and
      (TFile.ReadAllText(Target+'\Data\notes.json')='private preserved notes') and
      (TFile.ReadAllText(ExtractFileDir(Primary)+'\private-notes.txt')='unlisted private file'),
      'Inventory acquisition changed runtime or personal data');
  end;
  procedure CheckUpdaterEntry(ReaderOnly: Boolean);
  var Update: TfrmProgramUpdate; Seen: Boolean;
  begin
    Update:=TfrmProgramUpdate.Create(nil);
    try
      if ReaderOnly then Update.UseReaderComponents;
      Update.Show; Seen:=False;
      TThread.ForceQueue(nil,procedure
        var Manager: TCustomForm; Items: TListView;
        begin
          Manager:=nil;
          for var I:=0 to Screen.FormCount-1 do
            if Screen.Forms[I].Name='ComponentMaintenance' then Manager:=Screen.Forms[I];
          Require(Assigned(Manager) and (Manager.Owner=Update),'Normal updater did not open its real module manager');
          Items:=TListView(Manager.FindComponent('MaintenanceModules'));
          Require(Items.Items.Count=Length(InstalledOptionalComponents(Settings.AppPath,ReaderOnly)),
            'Updater manager changed catalogue/Reader component scope');
          for var Item in Items.Items do Require(not Item.Checked,'Opening Modules preselected removal');
          Seen:=True; TButton(Manager.FindComponent('MaintenanceClose')).Click;
        end);
      var Button:=TButton(Update.FindComponent('ManageOptionalComponents'));
      Require(Button.Enabled,'Normal updater Modules entry is disabled at rest'); Button.Click;
      Require(Seen,'Normal updater did not finish the module manager entry'); Update.Close;
    finally Update.Free; end;
  end;
begin
  RequireIsolatedRegression; CheckUpdaterEntry(False); CheckUpdaterEntry(True);
  Writeln('PASS ordinary catalogue and Reader updater Modules entries open the actual scoped manager without preselected deletion');
  Server:=TUFNServer.Create; Dialog:=nil;
  try
    for var Mode in ['decline','success','queued-cancel','inflight-cancel','bad-digest','prestart-failure',
      'local-decline','local-success','local-cancel','local-bad-manifest'] do
    begin
      PrepareCase(Mode);
      if Mode='bad-digest' then
        for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
          if UPDATE_COMPONENTS[I].ID='WebP' then Available[I].SHA256:=StringOfChar('0',64);
      if Mode.StartsWith('local-') then Available:=Default(TComponentReleases);
      CreateDialog;
      try
        if Mode='decline' then
        begin
          Dialog.Consent:=False; Resolve.Click;
          Require((FactoryCalls=0) and (Server.Requests=BeforeRequests) and not FileExists(Receipt),
            'Declining inventory download started a worker or changed installed metadata');
        end
        else if Mode='prestart-failure' then
        begin
          var Probe:=TUFNPrestartProbe.Create; Probe.Original:=Resolve.WindowProc; Resolve.WindowProc:=Probe.WindowMessage;
          try
            Resolve.Click;
            Require((Probe.Calls=1) and (Server.CreatedWorkers=BeforeCreated+1) and
              (Server.FreedWorkers=BeforeFreed+1) and (Server.Requests=BeforeRequests),
              'Pre-start inventory failure orphaned a suspended worker or sent HTTP');
            Require(Resolve.Enabled and TListView(Dialog.FindComponent('MaintenanceModules')).Enabled and
              (Pos('OWN_UPDATER_PRESTART_UI_FAILURE',TMemo(Dialog.FindComponent('MaintenanceDetails')).Text)>0),
              'Pre-start inventory failure did not recover usable controls and a readable cause');
          finally Resolve.WindowProc:=Probe.Original; Probe.Free; end;
        end
        else if Mode.StartsWith('local-') then
        begin
          if Mode='local-decline' then Dialog.SelectedArchive:='';
          Resolve.Click;
          Require((Dialog.ArchiveSelections=1) and (Dialog.Confirmations=0) and (FactoryCalls=0) and
            (Server.Requests=BeforeRequests),'Saved inventory archive requested an unrelated download');
          if Mode='local-cancel' then begin Dialog.Close; WaitClosed; end
          else if Mode<>'local-decline' then
          begin
            var Started:=GetTickCount64;
            repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
            until FileExists(Receipt) or (Pos('Архив относится к другому модулю',TMemo(Dialog.FindComponent('MaintenanceDetails')).Text)>0) or
              (GetTickCount64-Started>20000);
            if Mode='local-success' then
            begin
              WaitPlan; Require(FileExists(Receipt) and TButton(Dialog.FindComponent('MaintenanceRemove')).Enabled,
                'Matching saved archive did not produce a verified removal inventory');
              Require(Length(InstalledComponentFiles(Target,'WebP'))=5,'Saved archive inventory owns unrelated files');
            end
            else Require(not FileExists(Receipt) and
              (Pos('Архив относится к другому модулю',TMemo(Dialog.FindComponent('MaintenanceDetails')).Text)>0),
              'Saved archive for another module was accepted or its cause hidden: '+
                TMemo(Dialog.FindComponent('MaintenanceDetails')).Text);
          end;
        end
        else
        begin
          if Mode='inflight-cancel' then Server.Released.ResetEvent;
          Resolve.Click;
          Require((Dialog.Confirmations=1) and (Dialog.ConfirmedSize=Info.Size) and (FactoryCalls=1),
            'Inventory download lost consent size or requested unrelated modules');
          if Mode='queued-cancel' then
          begin
            Require(WaitForSingleObject(LastWorker.Handle,15000)=WAIT_OBJECT_0,'Verified inventory worker did not complete');
            Require(LastWorker.Successful,'Inventory fixture package failed before the queued cancellation case: '+LastWorker.ErrorText);
            Dialog.Close; WaitClosed;
          end
          else if Mode='inflight-cancel' then
          begin
            Require(Server.Requested.WaitFor(5000)=wrSignaled,'Inventory request did not reach the actual paused HTTP server');
            Dialog.Close; Server.Released.SetEvent; WaitClosed;
          end
          else
          begin
            var Started:=GetTickCount64;
            repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
            until (Server.FreedWorkers=BeforeFreed+1) or (GetTickCount64-Started>20000);
            Require(Server.FreedWorkers=BeforeFreed+1,'Inventory UI did not release its real download worker');
            if Mode='success' then
            begin
              WaitPlan; Require(FileExists(Receipt) and TButton(Dialog.FindComponent('MaintenanceRemove')).Enabled,
                'Verified inventory did not enable ordinary manual removal without reinstallation');
              Require(Length(InstalledComponentFiles(Target,'WebP'))=5,'Downloaded inventory includes unrelated or unlisted files');
            end
            else Require(not TButton(Dialog.FindComponent('MaintenanceRemove')).Enabled and
              (TMemo(Dialog.FindComponent('MaintenanceDetails')).Text<>''),'Bad digest was accepted or its reason hidden');
          end;
          Require(Server.Requests=BeforeRequests+1,'Inventory acquired an extra or unrelated package');
        end;
        if (Mode<>'success') and (Mode<>'local-success') then
          Require(not FileExists(Receipt),'Cancelled or invalid inventory changed installed ownership');
        RequirePrivate; Dialog.Close;
      finally
        Server.Released.SetEvent; Dialog.Free; Dialog:=nil;
      end;
      if FactoryCalls>0 then Require(not DirectoryExists(Job),'Closed inventory dialog left its downloaded staging folder');
      if DirectoryExists(Target+'\tools\component-state') then
        Require(Length(TDirectory.GetDirectories(Target+'\tools\component-state','HomeLibRu-update-inventory-*'))=0,
          'Saved inventory archive left its owned staging directory');
      Require(FileExists(Archive) and (UpdateSHA256(Archive)=Info.SHA256),'Inventory acquisition changed its source ZIP');
      Require((Server.Failure='') and (Server.CreatedWorkers- BeforeCreated=Server.FreedWorkers-BeforeFreed),
        'Inventory lifecycle left a real worker or an unexpected HTTP route');
      Writeln('PASS actual inventory download UI '+Mode+' preserves runtime private data and cleans owned work');
    end;
  finally Dialog.Free; Server.Free; end;
end;
