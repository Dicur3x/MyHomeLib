procedure TestPublishedComponents;
var Folder, Metadata, Feed, ID, Version, Name, Job, Target: string;
  Root: TJSONValue; Entries: TJSONArray; Info: TProgramRelease;
  Count: Integer;
begin
  RequireIsolatedRegression;
  Folder:=GetEnvironmentVariable('HOMELIB_PUBLISHED_COMPONENT_PACKAGES');
  Require(Folder<>'','Published component checks require actual audited archives');
  Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
  Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
  Root:=TJSONObject.ParseJSONValue(Feed); Count:=0;
  try
    Require((Root is TJSONObject) and Root.TryGetValue<TJSONArray>('components',Entries),
      'Invalid published component feed');
    for var Entry in Entries do
    begin
      if Entry.GetValue<string>('platform','')<>ProgramUpdatePlatform then Continue;
      ID:=Entry.GetValue<string>('id'); Version:=Entry.GetValue<string>('version');
      Require((ID='HomeLibReader') or (ID='BookConverter') or (ID='PDFium'),'Unexpected test component');
      Require(ParseComponentMirror(Metadata,Feed,ID,Version,Info),'Published component metadata rejected: '+ID);
      Require(Info.Tag=ALREADER_FIXED_TAG,'Published component tag differs from its hosting release');
      Name:=ComponentVersionedArchiveName(ID,Version,ProgramUpdatePlatform);
      Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-published-'+ID);
      Target:=TPath.Combine(Settings.AppPath,'published-target-'+ID);
      ForceDirectories(Target);
      TFile.WriteAllText(TPath.Combine(Target,'HomeLibRu.exe'),'unchanged catalogue executable');
      TFile.WriteAllText(TPath.Combine(Target,'myhomelib2.ini'),'personal settings');
      ForceDirectories(TPath.Combine(Target,'Data'));
      TFile.WriteAllText(TPath.Combine(Target,'Data/reader-notes.json'),'personal notes');
      try
        PrepareProgramUpdate(TPath.Combine(Folder,Name),Info.SHA256,Info.Tag,
          ProgramUpdatePlatform,Job,True,ID,Version);
        VerifyPreparedProgramUpdate(Job,Info.Tag,ProgramUpdatePlatform);
        InstallProgramUpdate(Job,Target);
        Require(InstalledComponentVersion(Target,ID)=Version,'Installed component identity mismatch: '+ID);
        Require(TFile.ReadAllText(TPath.Combine(Target,'HomeLibRu.exe'))='unchanged catalogue executable','Component changed catalogue executable');
        Require(TFile.ReadAllText(TPath.Combine(Target,'myhomelib2.ini'))='personal settings','Component changed settings');
        Require(TFile.ReadAllText(TPath.Combine(Target,'Data/reader-notes.json'))='personal notes','Component changed notes');
        Writeln('PASS published component manifest prepare verify install ',ID,' ',Version,' ',ProgramUpdatePlatform); Flush(Output);
        Inc(Count);
      finally CleanProgramUpdate(Job); end;
    end;
    Require(Count=3,'Published package check must exercise Reader, converter and PDFium');
  finally Root.Free; end;
end;
