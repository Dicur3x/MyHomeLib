// Original author archives are fixture inputs; no ICE code is executed.
procedure TestIBKLiveDownload;
var Checker: TComponentUpdateThread; Download: TProgramDownloadThread;
  Index, I: Integer; Info: TProgramRelease; Started: UInt64; Job: string;
begin
  RequireIsolatedRegression;
  Index:=-1;
  for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
    if UPDATE_COMPONENTS[I].ID='IBK' then Index:=I;
  Require(Index>=0,'IBK updater entry is absent');
  Checker:=TComponentUpdateThread.Create(0,CreateHTTPClientGlobal,PROGRAM_RELEASES_API,'');
  try
    Checker.OnlyIDs:=TArray<string>.Create('IBK');
    Checker.Start; Started:=GetTickCount64;
    while not Checker.Finished do
    begin
      Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      Require(GetTickCount64-Started<90000,'IBK live source check timed out');
    end;
    Checker.WaitFor;
    Require(Checker.TryGetRelease(Index,Info),'IBK source did not return a component');
    Require((Info.ComponentVersion=IBK_VERSION) and Info.OfficialComponent and
      (Info.SHA256=IBK_PACKAGE_SHA256) and (Info.SecondarySHA256=IBK_EXTRACTOR_SHA256),
      'IBK live source identity differs from pinned original archives: '+Info.ComponentError);
  finally Checker.Terminate; Checker.WaitFor; Checker.Free; end;
  Job:=TPath.Combine(Settings.AppPath,'HomeLibRu-update-'+TGUID.NewGuid.ToString);
  Download:=TProgramDownloadThread.Create(0,CreateHTTPClientGlobal,Info,Job);
  try
    Download.RuntimePath:=Settings.AppPath;
    Download.Start; Started:=GetTickCount64;
    while not Download.Finished do
    begin
      Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      Require(GetTickCount64-Started<90000,'IBK live component download timed out');
    end;
    Download.WaitFor;
    Require(Download.Successful,'IBK live download failed: '+Download.ErrorText);
    Require(not ComponentNeedsRepair(TPath.Combine(Job,'payload'),'IBK'),
      'IBK live download did not prepare complete original data');
    Writeln('PASS IBK live native source check and updater download preserve pinned identities and prepare complete original data');
    Flush(Output);
  finally
    Download.Terminate; Download.WaitFor; Download.Free;
    CleanProgramUpdate(Job);
  end;
end;

procedure TestIBKComponent;
var Original, Extractor, Job, Target, FileName, Hash, SourceHash, OutputName, Source, KeyName: string;
  Failed: Boolean; Warnings: TStringList; PreparationOwner: TComponent;
  Started: UInt64; Book: TBookRecord; Missing: string;
begin
  RequireIsolatedRegression;
  Require(IsOptionalComponent('IBK') and not ComponentNotificationEnabled('IBK',''),
    'IBK must be optional and quiet until requested');
  Require(IsBuiltinReaderFormat('.ibk') and IsBasicConversionSource('.ibk'),
    'IBK is absent from the native reading or Save As dispatch');
  Require(IsBuiltinReaderFormat('.oxps') and IsBasicConversionSource('.oxps'),
    'OpenXPS is absent from the native reading or Save As dispatch');
  Require(ComponentNeedsRepair(Settings.AppPath,'IBK'),'IBK fixture is unexpectedly preinstalled');
  Source:=TPath.Combine(Settings.AppPath,'catalogue-examples\sample-752297.ibk');
  Require(FileExists(Source),'Original IBK fixture is absent'); SourceHash:=UpdateSHA256(Source);
  OutputName:=Settings.AppPath+'missing-ibk.epub'; Warnings:=TStringList.Create;
  try
    Failed:=False;
    try ConvertBasicBook(Settings.AppPath,Settings.TempDir,Source,'.ibk',OutputName,nil,Warnings);
    except on E: EMHLComponentRequired do Failed:=E.ComponentID='IBK'; end;
    Require(Failed and not FileExists(OutputName),'Missing IBK data did not request its own component');
  finally Warnings.Free; end;
  PreparationOwner:=TComponent.Create(nil); Missing:='';
  try
    Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(752297,0); Book.NodeType:=ntBookInfo;
    Book.CollectionRoot:=ExtractFilePath(Source); Book.FileName:=ChangeFileExt(ExtractFileName(Source),'');
    Book.FileExt:='.ibk'; Include(Book.BookProps,bpIsLocal);
    PrepareReaderFileInBackground(PreparationOwner,Book,True,
      procedure(Prepared: string) begin raise Exception.Create('Missing IBK unexpectedly opened'); end,
      False,True,True,procedure(ID: string) begin Missing:=ID; end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(PreparationOwner) do
    begin
      Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      Require(GetTickCount64-Started<30000,'IBK first-use handoff did not finish');
    end;
    Require(Missing='IBK','Native reading preparation did not request missing IBK data');
  finally PreparationOwner.Free; end;
  Writeln('PASS IBK missing data reaches conversion and asynchronous reading component requests'); Flush(Output);
  FileName:='https://www.bestfree.ru/soft/office/ICE_Book_Reader_v9.6.5.Rus.zip?e=1793096000&s='+StringOfChar('a',64);
  Require(IBKPackageURL('<a href="'+FileName.Replace('https://www.bestfree.ru','').Replace('&','&amp;')+'">Download</a>')=FileName,
    'Signed original distribution link was not recognized');
  Require(IsOfficialComponentURL('IBK',IBK_VERSION,FileName,ProgramUpdatePlatform,False),
    'Original IBK package URL was refused');
  Require(not IsOfficialComponentURL('IBK',IBK_VERSION,FileName+'&other=1',ProgramUpdatePlatform,False),
    'Unexpected IBK URL suffix was accepted');
  Require(not IsOfficialComponentURL('IBK',IBK_VERSION,FileName.Replace('www.bestfree.ru','foreign.example'),ProgramUpdatePlatform,False),
    'Foreign IBK package URL was accepted');
  Require(IsOfficialComponentURL('IBK',IBK_VERSION,IBK_EXTRACTOR_URL,ProgramUpdatePlatform,True),
    'Original extractor URL was refused');
  Original:=Settings.AppPath+'ibk-packages/original.zip'; Extractor:=Settings.AppPath+'ibk-packages/innoextract.zip';
  Job:=Settings.AppPath+'HomeLibRu-update-ibk-component-job';
  PrepareOfficialComponent(Original,Job,'IBK',IBK_VERSION,ProgramUpdatePlatform,Extractor,Settings.AppPath);
  Require(InstalledComponentVersion(Job+'/payload','IBK')=IBK_VERSION,'Prepared original IBK data is incomplete');
  Target:=Settings.AppPath+'ibk-install-target'; ForceDirectories(Target);
  TFile.Copy(ParamStr(0),Target+'/HomeLibRu.exe');
  FileName:=TPath.Combine(Target,'tools\ibk\Rus.key'); ForceDirectories(ExtractFileDir(FileName));
  TFile.WriteAllText(FileName,'previous owned fixture bytes');
  Hash:=UpdateSHA256(FileName); Failed:=False;
  try InstallProgramUpdate(Job,Target,nil,1);
  except on E: Exception do
    begin
      if E.Message<>'Имитированная ошибка установки' then raise;
      Failed:=True;
    end;
  end;
  Require(Failed,'IBK installation did not reach the injected failure');
  Require(UpdateSHA256(FileName)=Hash,'IBK interrupted install did not restore previous bytes');
  CleanProgramUpdate(Job);
  Job:=Settings.AppPath+'HomeLibRu-update-ibk-component-installed-job';
  PrepareOfficialComponent(Original,Job,'IBK',IBK_VERSION,ProgramUpdatePlatform,Extractor,Settings.AppPath);
  InstallProgramUpdate(Job,Settings.AppPath);
  Require(not ComponentNeedsRepair(Settings.AppPath,'IBK'),'IBK original data did not install');
  Require(UpdateSHA256(Settings.AppPath+'tools/ibk/ICEBookReader-original.zip')=UpdateSHA256(Original),
    'IBK original distribution was altered');
  KeyName:=Settings.AppPath+'tools/ibk/Rus.key';
  TFile.Move(KeyName,KeyName+'.held');
  try Require(ComponentNeedsRepair(Settings.AppPath,'IBK'),'IBK missing read data was reported as installed');
  finally TFile.Move(KeyName+'.held',KeyName); end;
  Require(not FileExists(Settings.AppPath+'tools/ibk/ICEReaderRus.exe'),
    'IBK installed an unnecessary third-party reader executable');
  Require(not FileExists(Settings.AppPath+'tools/ibk/innoextract.exe'),
    'Temporary extractor leaked into installed component');
  Require(not FileExists(Settings.AppPath+'tools/ibk/original-installer.exe'),
    'Temporary installer leaked into installed component');
  Require(SafeComponentFile('IBK','tools/ibk/License.txt') and
    not SafeComponentFile('IBK','tools/ibk/ICEReaderRus.exe') and
    not SafeComponentFile('IBK','tools/ibk/personal-registration.key') and
    not SafeComponentFile('IBK','Data/collection.hlc2'),'IBK installer accepts unrelated paths');
  Require(UpdateSHA256(Source)=SourceHash,'IBK reading changed the original source');
  Writeln('PASS IBK original component requests on first use, verifies archives, installs without ICE execution, rolls back failures and retains original license and distribution');
  Flush(Output);
end;
