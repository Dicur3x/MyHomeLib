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
