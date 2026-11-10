procedure TestComponentMaintenance;
var Target: string; Available: TComponentReleases; Dialog: TfrmComponentMaintenance;
  List: TListView; RemoveButton: TButton; Summary: TLabel; Root, Entry: TJSONObject; Entries: TJSONArray;
  procedure WaitPlan;
  var Started: UInt64;
  begin
    Started:=GetTickCount64;
    repeat Application.ProcessMessages; Sleep(10);
    until Dialog.PlanReady or (GetTickCount64-Started>15000);
    Require(Dialog.PlanReady,'Maintenance plan did not finish without blocking the UI');
  end;
  procedure MonthlyOffers;
  var Time: TDateTime; Seen: Boolean;
    procedure CloseOffer(Suppress: Boolean);
    var CloseDialog: TThreadProcedure;
    begin
      Seen:=False;
      CloseDialog:=procedure
        var Offer: TCustomForm; Items: TListView;
        begin
          Offer:=nil;
          for var I:=0 to Screen.FormCount-1 do
            if Screen.Forms[I].Name='ComponentMaintenance' then Offer:=Screen.Forms[I];
          Require(Assigned(Offer),'Scheduled monthly module dialog did not open');
          Items:=TListView(Offer.FindComponent('MaintenanceModules'));
          Require(Items.Items.Count=2,'Monthly offer did not combine two unused modules into one window');
          for var Item in Items.Items do Require(not Item.Checked,
            'Monthly offer selected deletion automatically');
          Require(not TButton(Offer.FindComponent('MaintenanceRemove')).Enabled,
            'Monthly offer enabled deletion without an explicit choice');
          TCheckBox(Offer.FindComponent('MaintenanceOffers')).Checked:=Suppress;
          Seen:=True; TButton(Offer.FindComponent('MaintenanceClose')).Click;
        end;
      TThread.ForceQueue(nil,CloseDialog);
    end;
  begin
    Time:=EncodeDate(2026,1,1);
    var WebP:=CheckedUpdateChildPath(Target,ComponentFileName('WebP'));
    ForceDirectories(ExtractFileDir(WebP)); TFile.WriteAllText(WebP,'OWNED NONEXECUTABLE WEBP MARKER');
    var Legacy := TJSONObject.Create;
    try
      Legacy.AddPair('format',TJSONNumber.Create(1)); Legacy.AddPair('platform',ProgramUpdatePlatform);
      var Files := TJSONArray.Create; Legacy.AddPair('files',Files);
      for var Name in ['HomeLibRu.exe','LICENSE','NOTICE'] do
      begin
        var Core := TJSONObject.Create; Files.AddElement(Core);
        Core.AddPair('path', Name);
        Core.AddPair('size', TJSONNumber.Create(0));
        Core.AddPair('sha256', StringOfChar('0', 64));
      end;
      var OldFile := TJSONObject.Create; Files.AddElement(OldFile);
      OldFile.AddPair('path', ComponentFileName('WebP'));
      OldFile.AddPair('size', TJSONNumber.Create(TFile.GetSize(WebP)));
      OldFile.AddPair('sha256', StringOfChar('0', 64));
      var OldManifest := CheckedUpdateChildPath(Target, UPDATE_MANIFEST);
      TFile.WriteAllText(OldManifest, Legacy.ToJSON, TEncoding.UTF8);
      var Plan := BuildComponentRemovalPlan(Target, ['WebP']);
      Require(not Plan.CanRemove and (Length(Plan.Files) = 0) and
        Plan.Blockers[0].Contains('сверить состав'), 'Stale main manifest accused an installed module of changing');
      OldFile.RemovePair('sha256').Free;
      OldFile.AddPair('sha256', UpdateSHA256(WebP));
      TFile.WriteAllText(OldManifest, Legacy.ToJSON, TEncoding.UTF8);
      Plan := BuildComponentRemovalPlan(Target, ['WebP']);
      Require(Plan.CanRemove and (Length(Plan.Files) = 1), 'Matching legacy inventory was discarded');
      TFile.Delete(OldManifest);
    finally Legacy.Free; end;
    Dialog:=TfrmComponentMaintenance.CreateManager(frmMain,Target,False,False,nil,Available,nil);
    try
      Dialog.Show; WaitPlan;
      var Modules := TListView(Dialog.FindComponent('MaintenanceModules'));
      var SelectAll := TButton(Dialog.FindComponent('MaintenanceSelectAll'));
      Require(SelectAll.Enabled and (Modules.Items.Count=2),'Bulk selection unavailable');
      SelectAll.Click; WaitPlan;
      for var Item in Modules.Items do Require(Item.Checked,'Select all missed an installed module');
      Require(not TButton(Dialog.FindComponent('MaintenanceRemove')).Enabled,
        'Bulk selection bypassed an unverified inventory');
      SelectAll.Click; WaitPlan;
      for var Item in Modules.Items do Require(not Item.Checked,'Clear all left a module marked');
      Dialog.Close;
    finally Dialog.Free; end;
    // Both files already exist before the first beta-3 launch; WebP has no
    // installation receipt. Discovery must start its clock without a download.
    ObserveInstalledOptionalComponents(Target,False,Time);
    ObserveInstalledOptionalComponents(Target,False,Time+29);
    Require(not OfferUnusedComponents(frmMain,Target,False,Time+29),
      'An existing module was offered before a month since first observation');
    Require(not ComponentCleanupWindowReady(frmMain,True),'Busy application allowed an automatic cleanup window');
    CloseOffer(False);
    Require(OfferUnusedComponents(frmMain,Target,False,Time+30) and Seen,'Monthly offer not shown after one month');
    Require(FileExists(Target+'\tools\7zip\7z.exe') and FileExists(WebP),'Declining the monthly offer deleted a module');
    Require(not OfferUnusedComponents(frmMain,Target,False,Time+40),'Declined monthly offer repeated too early');
    CloseOffer(True);
    Require(OfferUnusedComponents(frmMain,Target,False,Time+62) and Seen,'Monthly postponement did not return');
    Require(ComponentCleanupSuppressed(Target) and not OfferUnusedComponents(frmMain,Target,False,Time+100),
      'Do not offer again failed to suppress future monthly dialogs');
    TFile.Delete(WebP);
    Writeln('PASS existing installed modules observed without update combined monthly dialog postponement suppression and no automatic deletion');
  end;
begin
  RequireIsolatedRegression; Target:=Settings.AppPath+'maintenance-dialog-fixture';
  ForceDirectories(Target+'\tools\7zip'); ForceDirectories(Target+'\Data');
  TFile.WriteAllText(Target+'\HomeLibRu.exe','OWNED NONEXECUTABLE APP MARKER');
  TFile.WriteAllText(Target+'\Data\notes.json','private notes'); Root:=TJSONObject.Create;
  try
    Root.AddPair('format',TJSONNumber.Create(1)); Root.AddPair('component','7-Zip'); Root.AddPair('version','1.0.0.1');
    Root.AddPair('platform',ProgramUpdatePlatform); Entries:=TJSONArray.Create; Root.AddPair('files',Entries);
    for var Member in ['7z.exe','7z.dll','License.txt'] do
    begin
      var Name:=Target+'\tools\7zip\'+Member; TFile.WriteAllText(Name,'OWNED NONEXECUTABLE MODULE '+Member);
      Entry:=TJSONObject.Create; Entry.AddPair('path','tools/7zip/'+Member);
      Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(Name))); Entry.AddPair('sha256',UpdateSHA256(Name)); Entries.AddElement(Entry);
    end;
    var Receipt:=CheckedUpdateChildPath(Target,ComponentReceiptName('7-Zip'));
    ForceDirectories(ExtractFileDir(Receipt)); TFile.WriteAllText(Receipt,Root.ToJSON,TEncoding.UTF8);
  finally Root.Free; end;
  Available:=Default(TComponentReleases);
  for var Dark in [False,True] do for var PPI in [96,144,192] do
  begin
    SetMHLTheme(Dark);
    Dialog:=TfrmComponentMaintenance.CreateManager(frmMain,Target,False,False,TArray<string>.Create('7-Zip'),Available,nil);
    try
      Dialog.ScaleForPPI(PPI); Dialog.Show; WaitPlan;
      List:=TListView(Dialog.FindComponent('MaintenanceModules')); Require(List.Items.Count=1,'Module manager showed absent formats or mandatory SQLite');
      RemoveButton:=TButton(Dialog.FindComponent('MaintenanceRemove'));
      Require(RemoveButton.Enabled,'Ready verified optional module cannot be removed');
      for var Small in [False,True] do
      begin
        if Small then begin Dialog.ClientWidth:=MulDiv(600,PPI,96); Dialog.ClientHeight:=MulDiv(440,PPI,96); end;
        Application.ProcessMessages;
        for var I:=0 to Dialog.ControlCount-1 do
        begin
          var Control:=Dialog.Controls[I]; if not Control.Visible then Continue;
          Require((Control.Left>=0) and (Control.Top>=0) and (Control.BoundsRect.Right<=Dialog.ClientWidth) and
            (Control.BoundsRect.Bottom<=Dialog.ClientHeight),'Module manager control clipped: '+Control.Name);
        end;
      end;
      Dialog.Close;
      Require(FileExists(Target+'\tools\7zip\7z.exe'),'Closing a maintenance preview deleted a module');
    finally Dialog.Free; end;
  end;
  MonthlyOffers;
  Dialog:=TfrmComponentMaintenance.CreateManager(frmMain,Target,False,False,TArray<string>.Create('7-Zip'),Available,nil);
  try
    Dialog.Show; WaitPlan; RemoveButton:=TButton(Dialog.FindComponent('MaintenanceRemove'));
    RemoveButton.OnClick(RemoveButton); WaitPlan;
    Summary:=TLabel(Dialog.FindComponent('MaintenanceSummary'));
    Require(not FileExists(Target+'\tools\7zip\7z.exe') and (Pos('удалены',Summary.Caption)>0),'Actual module manager removal did not finish');
    Require(TFile.ReadAllText(Target+'\Data\notes.json')='private notes','Actual module manager changed personal notes');
    Require(TListView(Dialog.FindComponent('MaintenanceModules')).Items.Count=0,'Removed module remained in manager');
    Dialog.Close;
  finally Dialog.Free; SetMHLTheme(Settings.DarkTheme); end;
  Writeln('PASS module manager actual asynchronous preview cancel remove retained personal data and light dark 96 144 192 DPI layouts');
end;
