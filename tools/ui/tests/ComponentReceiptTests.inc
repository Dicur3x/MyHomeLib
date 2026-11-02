procedure TestComponentReceipts;
var Target, Job, ReceiptPath, Before, Name: string; Files: TUpdateFiles; Rejected: Boolean;
  function ObservationDate: TDateTime;
  var State: TJSONValue;
  begin
    State:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Target+'\tools\component-state\usage.json',TEncoding.UTF8));
    try Result:=ISO8601ToDate(State.GetValue<string>('modules.7-Zip.firstSeenUtc'),True);
    finally State.Free; end;
  end;
  procedure RealBundle;
  var Folder, Feed, Metadata, ID, Version, BundleJob: string; Root: TJSONValue;
    Entries: TJSONArray; Jobs: TArray<string>; Release: TProgramRelease; Count: Integer;
  begin
    Folder:=GetEnvironmentVariable('HOMELIB_FORMAT_COMPONENT_PACKAGES');
    Require(Folder<>'','Component receipt integration requires actual format packages');
    Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
    Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
    BundleJob:=Settings.AppPath+'HomeLibRu-update-receipt-bundle';
    Root:=TJSONObject.ParseJSONValue(Feed); Jobs:=nil; Count:=0;
    try
      Require(Assigned(Root) and Root.TryGetValue<TJSONArray>('components',Entries),'Invalid real package feed');
      for var Entry in Entries do
      begin
        ID:=Entry.GetValue<string>('id');
        if (Entry.GetValue<string>('platform','')<>ProgramUpdatePlatform) or
          ((ID<>'BookProcessing') and (ID<>'ImageProcessing')) then Continue;
        Version:=Entry.GetValue<string>('version');
        Require(ParseComponentMirror(Metadata,Feed,ID,Version,Release),'Real package identity missing: '+ID);
        var PartJob:=Settings.AppPath+'HomeLibRu-update-receipt-'+ID;
        Jobs:=Jobs+TArray<string>.Create(PartJob);
        PrepareProgramUpdate(TPath.Combine(Folder,ComponentVersionedArchiveName(ID,Version,ProgramUpdatePlatform)),
          Release.SHA256,Release.Tag,ProgramUpdatePlatform,PartJob,True,ID,Version);
        Inc(Count);
      end;
      Require(Count=2,'Need actual base-processing and image-processing packages');
      CombinePreparedProgramUpdates(Jobs,PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform,BundleJob);
      VerifyPreparedProgramUpdate(BundleJob,PROGRAM_RELEASE_VERSION,ProgramUpdatePlatform);
      InstallProgramUpdate(BundleJob,Target);
      for ID in ['BookProcessing','ImageProcessing'] do
      begin
        var Owned:=InstalledComponentFiles(Target,ID); Require(Length(Owned)>1,'Missing bundled receipt: '+ID);
        for var Info in Owned do Require(SafeComponentFile(ID,Info.Name) and
          (UpdateSHA256(TPath.Combine(Target,Info.Name))=Info.SHA256),'Bundled receipt owns wrong bytes: '+ID);
      end;
      Require((TFile.ReadAllText(TPath.Combine(Target,'Data/user.ini'))='personal settings') and
        not DirectoryExists(TPath.Combine(Target,'tools/office')) and not DirectoryExists(TPath.Combine(Target,'tools/kindle')),
        'Bundled receipt installation changed user data or installed unrelated readers');
    finally
      Root.Free; if DirectoryExists(BundleJob) then CleanProgramUpdate(BundleJob);
      for var PartJob in Jobs do if DirectoryExists(PartJob) then CleanProgramUpdate(PartJob);
    end;
    Writeln('PASS real verified processing and image package bundle retains separate installed-file receipts without unrelated format modules');
  end;
  function MakeJob(const Version: string; IncludeOptional: Boolean): string;
  var Root, Item: TJSONObject; Entries: TJSONArray; Names: TArray<string>; PathName: string;
  begin
    Result:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
    ForceDirectories(Result); Root:=TJSONObject.Create;
    try
      Root.AddPair('format',TJSONNumber.Create(1)); Root.AddPair('release',PROGRAM_RELEASE_VERSION);
      Root.AddPair('platform',ProgramUpdatePlatform); Root.AddPair('component','7-Zip'); Root.AddPair('version',Version);
      Entries:=TJSONArray.Create; Root.AddPair('files',Entries);
      Names:=TArray<string>.Create('tools/7zip/7z.exe','tools/7zip/7z.dll','tools/7zip/License.txt');
      if IncludeOptional then Names:=Names+TArray<string>.Create('tools/7zip/7za.exe');
      for var Member in Names do
      begin
        PathName:=TPath.Combine(Result,('payload/'+Member).Replace('/','\')); ForceDirectories(ExtractFileDir(PathName));
        TFile.WriteAllText(PathName,'OWNED NONEXECUTABLE RECEIPT FIXTURE '+Version+' '+Member,TEncoding.UTF8);
        Item:=TJSONObject.Create; Item.AddPair('path',Member);
        Item.AddPair('size',TJSONNumber.Create(TFile.GetSize(PathName)));
        Item.AddPair('sha256',UpdateSHA256(PathName)); Entries.AddElement(Item);
      end;
      TFile.WriteAllText(TPath.Combine(Result,'manifest.json'),Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
  end;
  function HasMember(const Member: string): Boolean;
  begin
    Result:=False; for var Info in InstalledComponentFiles(Target,'7-Zip') do
      if Info.Name=Member then Exit(True);
  end;
begin
  RequireIsolatedRegression;
  Target:=TPath.Combine(Settings.AppPath,'receipt-install-target'); ForceDirectories(Target);
  TFile.WriteAllText(TPath.Combine(Target,'HomeLibRu.exe'),'OWNED NONEXECUTABLE APP MARKER');
  ForceDirectories(TPath.Combine(Target,'Data')); TFile.WriteAllText(TPath.Combine(Target,'Data/user.ini'),'personal settings');
  ReceiptPath:=TPath.Combine(Target,ComponentReceiptName('7-Zip'));
  var OldObservation:=EncodeDate(2026,1,1);
  ObserveInstalledComponents(Target,TArray<string>.Create('7-Zip'),OldObservation);
  Job:=MakeJob('1.0.0.1',True);
  try
    Rejected:=False;
    try InstallProgramUpdate(Job,Target,nil,5); except on E: Exception do Rejected:=E.Message='Имитированная ошибка установки'; end;
    Require(Rejected and not FileExists(ReceiptPath) and not FileExists(TPath.Combine(Target,'tools/7zip/7z.exe')),
      'Failed first installation left an ownership receipt or runtime');
    Require(ObservationDate=OldObservation,'Failed installation restarted module observation');
  finally CleanProgramUpdate(Job); end;
  Job:=MakeJob('1.0.0.1',True);
  try InstallProgramUpdate(Job,Target); finally CleanProgramUpdate(Job); end;
  Require(ObservationDate>OldObservation,'First installation did not renew an old removed module grace period');
  RecordComponentInstallation(Target,'7-Zip',OldObservation,True);
  Files:=InstalledComponentFiles(Target,'7-Zip');
  Require(Length(Files)=4,'Installed-file receipt did not survive job cleanup');
  for var Info in Files do
    Require(not Info.GeneratedReceipt and (UpdateSHA256(TPath.Combine(Target,Info.Name))=Info.SHA256) and
      (TFile.GetSize(TPath.Combine(Target,Info.Name))=Info.Size),'Receipt differs from installed payload');
  Before:=UpdateSHA256(ReceiptPath);
  Job:=MakeJob('1.0.0.2',False);
  try
    Rejected:=False;
    try InstallProgramUpdate(Job,Target,nil,4); except on E: Exception do Rejected:=E.Message='Имитированная ошибка установки'; end;
    Require(Rejected and (UpdateSHA256(ReceiptPath)=Before),'Failed update did not roll back the ownership receipt');
    Require(ObservationDate=OldObservation,'Failed update restarted observation');
    for var Info in Files do Require(UpdateSHA256(TPath.Combine(Target,Info.Name))=Info.SHA256,'Failed update changed runtime bytes');
  finally CleanProgramUpdate(Job); end;
  Name:=TPath.Combine(Target,'tools/7zip/user-notes.txt'); TFile.WriteAllText(Name,'not owned by package');
  Job:=MakeJob('1.0.0.2',False);
  try InstallProgramUpdate(Job,Target); finally CleanProgramUpdate(Job); end;
  Require(ObservationDate=OldObservation,'Updating an installed module restarted observation');
  Require((Length(InstalledComponentFiles(Target,'7-Zip'))=4) and HasMember('tools/7zip/7za.exe') and
    not HasMember('tools/7zip/user-notes.txt'),'Receipt lost earlier owned files or claimed a private file');
  Require((TFile.ReadAllText(Name)='not owned by package') and
    (TFile.ReadAllText(TPath.Combine(Target,'Data/user.ini'))='personal settings'),'Receipt installation changed user files');
  TFile.Delete(TPath.Combine(Target,'tools/7zip/7z.exe'));
  Job:=MakeJob('1.0.0.2',False);
  try InstallProgramUpdate(Job,Target); finally CleanProgramUpdate(Job); end;
  Require(ObservationDate>OldObservation,'Reinstalling a missing module did not start a fresh observation period');
  Writeln('PASS component installer preserves observation on updates and failures while fresh reinstallation renews grace');
  var SavedReceipt:=TFile.ReadAllText(ReceiptPath,TEncoding.UTF8);
  try
    TFile.WriteAllText(ReceiptPath,SavedReceipt.Replace('"7-Zip"','"SQLite"'),TEncoding.UTF8); Rejected:=False;
    try InstalledComponentFiles(Target,'7-Zip'); except on E: Exception do Rejected:=True; end;
    Require(Rejected,'Mismatched component ownership record accepted');
  finally TFile.WriteAllText(ReceiptPath,SavedReceipt,TEncoding.UTF8); end;
  Writeln('PASS installed component receipts commit and roll back with runtime files, survive cleanup, retain prior ownership and preserve unknown personal files');
  RealBundle;
end;
