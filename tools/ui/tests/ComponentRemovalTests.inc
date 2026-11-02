procedure TestComponentRemoval;
var Target, Source, Hash, Manifest: string; Plan: TComponentRemovalPlan; Failed: Boolean;
  function Fixture(const LabelText: string): string;
  begin
    Result:=Settings.AppPath+'removal-'+LabelText; ForceDirectories(Result+'\Data');
    TFile.WriteAllText(Result+'\HomeLibRu.exe','OWNED NONEXECUTABLE APP MARKER');
    TFile.WriteAllText(Result+'\Data\notes.json','private notes');
  end;
  function Runtime(const ID: string; const Names: TArray<string>; Receipt: Boolean = True): string;
  var Root, Entry: TJSONObject; Files: TJSONArray; Name: string;
  begin
    Root:=TJSONObject.Create;
    try
      Root.AddPair('format',TJSONNumber.Create(1)); Root.AddPair('release',PROGRAM_RELEASE_VERSION);
      Root.AddPair('component',ID); Root.AddPair('version','1.0.0.1'); Root.AddPair('platform',ProgramUpdatePlatform);
      Files:=TJSONArray.Create; Root.AddPair('files',Files);
      for var Member in Names do
      begin
        Name:=CheckedUpdateChildPath(Target,Member); ForceDirectories(ExtractFileDir(Name));
        if not FileExists(Name) then TFile.WriteAllText(Name,'OWNED NONEXECUTABLE MODULE FIXTURE '+Member);
        Entry:=TJSONObject.Create; Entry.AddPair('path',Member); Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(Name)));
        Entry.AddPair('sha256',UpdateSHA256(Name)); Files.AddElement(Entry);
      end;
      if Receipt then Result:=CheckedUpdateChildPath(Target,ComponentReceiptName(ID))
      else Result:=Target+'\legacy-'+ID+'.json';
      ForceDirectories(ExtractFileDir(Result)); TFile.WriteAllText(Result,Root.ToJSON,TEncoding.UTF8);
    finally Root.Free; end;
  end;
  function ZipNames: TArray<string>;
  begin Result:=TArray<string>.Create('tools/7zip/7z.exe','tools/7zip/7z.dll','tools/7zip/License.txt','tools/7zip/7za.exe'); end;
  function Disposition(const Name: string): TComponentRemovalDisposition;
  begin
    for var Item in Plan.Files do if Item.FileInfo.Name=Name then Exit(Item.Disposition);
    raise Exception.Create('Missing removal-plan row: '+Name);
  end;
  procedure RequirePrivate;
  begin
    Require(TFile.ReadAllText(Target+'\Data\notes.json')='private notes','Removal changed personal notes');
    Require(TFile.ReadAllText(Target+'\HomeLibRu.exe')='OWNED NONEXECUTABLE APP MARKER','Removal changed main app');
  end;
  procedure Pending(const LabelText, Member: string);
  var Root, Entry: TJSONObject; IDs, Files: TJSONArray; Stage, Original: string;
  begin
    Stage:=CheckedUpdateChildPath(Target,'tools/component-state/remove-'+LabelText);
    Original:=CheckedUpdateChildPath(Target,Member); Root:=TJSONObject.Create;
    try
      Root.AddPair('kind','HomeLibre component removal v1'); Root.AddPair('target',Target); Root.AddPair('state','removing');
      IDs:=TJSONArray.Create; IDs.Add('7-Zip'); Root.AddPair('ids',IDs); Files:=TJSONArray.Create; Root.AddPair('files',Files);
      Entry:=TJSONObject.Create; Entry.AddPair('component','7-Zip'); Entry.AddPair('path',Member);
      Entry.AddPair('size',TJSONNumber.Create(TFile.GetSize(Original))); Entry.AddPair('sha256',UpdateSHA256(Original)); Files.AddElement(Entry);
      var Destination:=CheckedUpdateChildPath(Stage,'files/'+Member); ForceDirectories(ExtractFileDir(Destination));
      TFile.WriteAllText(CheckedUpdateChildPath(Stage,'state.json'),Root.ToJSON,TEncoding.UTF8);
      TFile.Move(Original,Destination);
    finally Root.Free; end;
  end;
  procedure RealPackages;
  var Folder, Metadata, Feed, Book, OutputBook: string; FeedRoot: TJSONValue; Entries: TJSONArray;
    procedure Install(const ID: string);
    var Release: TProgramRelease; Version, Job: string;
    begin
      Version:='';
      for var Entry in Entries do if (Entry.GetValue<string>('id')=ID) and
        (Entry.GetValue<string>('platform')=ProgramUpdatePlatform) then Version:=Entry.GetValue<string>('version');
      Require((Version<>'') and ParseComponentMirror(Metadata,Feed,ID,Version,Release),'Real removal package metadata missing: '+ID);
      Job:=Settings.AppPath+'HomeLibRu-update-remove-real-'+TGUID.NewGuid.ToString;
      try
        PrepareProgramUpdate(TPath.Combine(Folder,ComponentVersionedArchiveName(ID,Version,ProgramUpdatePlatform)),
          Release.SHA256,Release.Tag,ProgramUpdatePlatform,Job,True,ID,Version);
        InstallProgramUpdate(Job,Target);
        Require(not ComponentNeedsRepair(Target,ID),'Real package failed installed identity: '+ID);
      finally if DirectoryExists(Job) then CleanProgramUpdate(Job); end;
    end;
  begin
    Folder:=GetEnvironmentVariable('HOMELIB_FORMAT_COMPONENT_PACKAGES');
    if Folder='' then Exit;
    Metadata:=TFile.ReadAllText(TPath.Combine(Folder,'local-mirror-release.json'),TEncoding.UTF8);
    Feed:=TFile.ReadAllText(TPath.Combine(Folder,COMPONENT_FEED_NAME),TEncoding.UTF8);
    FeedRoot:=TJSONObject.ParseJSONValue(Feed);
    try
      Require(Assigned(FeedRoot) and FeedRoot.TryGetValue<TJSONArray>('components',Entries),'Invalid actual removal package feed');
      Target:=Fixture('actual-packages'); Install('BookProcessing'); Install('ImageProcessing');
      Book:=Target+'\source.fb2'; OutputBook:=Target+'\before.epub';
      TFile.WriteAllText(Book,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
        '<description><title-info><genre>prose</genre><book-title>Removal test</book-title><lang>en</lang></title-info></description>'+
        '<body><section><p>Readable original removal-test text.</p></section></body></FictionBook>',TEncoding.UTF8);
      var Original:=UpdateSHA256(Book);
      ConvertBasicBook(Target,Settings.TempDir,Book,'.fb2',OutputBook,nil,nil); Require(FileExists(OutputBook),'Actual conversion before removal failed');
      Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('ImageProcessing'));
      Require(Plan.CanRemove and (ExecuteComponentRemovalPlan(Plan)=''),'Real image module removal failed');
      Require(ComponentNeedsRepair(Target,'ImageProcessing') and not ComponentNeedsRepair(Target,'BookProcessing'),'Removing images damaged base converter');
      OutputBook:=Target+'\without-images.epub'; ConvertBasicBook(Target,Settings.TempDir,Book,'.fb2',OutputBook,nil,nil);
      Require(FileExists(OutputBook),'Image module removal broke ordinary text conversion');
      Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('BookProcessing'));
      Require(Plan.CanRemove and (ExecuteComponentRemovalPlan(Plan)='') and ComponentNeedsRepair(Target,'BookProcessing'),'Real base module removal failed');
      Install('BookProcessing'); Install('ImageProcessing'); OutputBook:=Target+'\reinstalled.epub';
      ConvertBasicBook(Target,Settings.TempDir,Book,'.fb2',OutputBook,nil,nil);
      Require(FileExists(OutputBook) and (UpdateSHA256(Book)=Original),'Actual reinstall failed conversion or changed original book'); RequirePrivate;
      Require((Length(InstalledComponentFiles(Target,'BookProcessing'))>0) and
        (Length(InstalledComponentFiles(Target,'ImageProcessing'))>0),'Actual reinstall did not restore file ownership');
    finally FeedRoot.Free; end;
    Writeln('PASS real verified base and image packages remove independently, reinstall with receipts and convert FB2 to EPUB before and after removal');
  end;
begin
  RequireIsolatedRegression;
  Target:=Fixture('rollback'); Runtime('7-Zip',ZipNames); Source:=CheckedUpdateChildPath(Target,'tools/7zip/7z.exe'); Hash:=UpdateSHA256(Source);
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('7-Zip')); Require(Plan.CanRemove and (Plan.Bytes>0),'Valid removal blocked');
  Failed:=False;
  try ExecuteComponentRemovalPlan(Plan,2); except on E: Exception do Failed:=E.Message='Имитированная ошибка удаления'; end;
  Require(Failed and (UpdateSHA256(Source)=Hash) and FileExists(CheckedUpdateChildPath(Target,ComponentReceiptName('7-Zip'))),'Failed removal did not restore module and receipt');
  Require(Length(RecoverComponentRemovals(Target))=0,'Rollback left an unrecoverable transaction'); RequirePrivate;
  var Locked:=TFileStream.Create(Source,fmOpenRead or fmShareDenyWrite);
  try
    Failed:=False; try ExecuteComponentRemovalPlan(Plan); except on E: Exception do Failed:=E.Message.Contains('Файл занят'); end;
    Require(Failed and (UpdateSHA256(Source)=Hash),'Locked runtime was removed or silently accepted');
  finally Locked.Free; end;
  TFile.WriteAllText(CheckedUpdateChildPath(Target,'tools/7zip/7za.exe'),'modified auxiliary runtime');
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('7-Zip'));
  Require(Plan.CanRemove and (Disposition('tools/7zip/7za.exe')=crKeepChanged),'Changed auxiliary file not preserved');
  TFile.WriteAllText(CheckedUpdateChildPath(Target,'tools/7zip/my-notes.txt'),'unknown private file');
  Require(ExecuteComponentRemovalPlan(Plan)='','Successful removal left owned temporary data');
  Require(not FileExists(Source) and not FileExists(CheckedUpdateChildPath(Target,ComponentReceiptName('7-Zip'))),'Module or receipt still installed');
  Require(TFile.ReadAllText(CheckedUpdateChildPath(Target,'tools/7zip/7za.exe'))='modified auxiliary runtime','Changed file lost');
  Require(TFile.ReadAllText(CheckedUpdateChildPath(Target,'tools/7zip/my-notes.txt'))='unknown private file','Unknown file lost'); RequirePrivate;
  Runtime('7-Zip',ZipNames); Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('7-Zip'));
  TFile.WriteAllText(Source,'changed primary'); Failed:=False;
  try ExecuteComponentRemovalPlan(Plan); except on E: Exception do Failed:=True; end;
  Require(Failed and FileExists(Source),'Stale plan removed a changed primary');
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('SQLite')); Require(not Plan.CanRemove,'Mandatory SQLite removable');
  Target:=Fixture('legacy'); Manifest:=Runtime('7-Zip',ZipNames,False);
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('7-Zip')); Require(not Plan.CanRemove,'Unknown legacy inventory silently inferred from a folder');
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('7-Zip'),TArray<string>.Create(Manifest));
  Require(Plan.CanRemove and (ExecuteComponentRemovalPlan(Plan)=''),'Exact legacy manifest requires reinstall or cannot remove'); RequirePrivate;
  Target:=Fixture('settings'); Runtime('AlReader',TArray<string>.Create('Readers/AlReader/AlReader2.exe','Readers/AlReader/$savevtut.ini','Readers/AlReader/readme.txt'));
  Source:=CheckedUpdateChildPath(Target,'Readers/AlReader/$savevtut.ini'); TFile.WriteAllText(Source,'private reader settings');
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('AlReader'));
  Require(Plan.CanRemove and (Disposition('Readers/AlReader/$savevtut.ini')=crKeepSettings),'Reader settings not protected');
  ExecuteComponentRemovalPlan(Plan); Require(TFile.ReadAllText(Source)='private reader settings','AlReader settings lost'); RequirePrivate;
  Target:=Fixture('shared'); Runtime('HomeLibReader',TArray<string>.Create('HomeLibReader.exe','HomeLibReader-LICENSE.txt','HomeLibRuUpdater.exe','sqlite3.dll','libzstd.dll','NOTICE'));
  Runtime('Zstandard',TArray<string>.Create('libzstd.dll','tools/zstd/RUNTIME.json','tools/zstd/LICENSE'));
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('Zstandard')); Require(not Plan.CanRemove and (Disposition('libzstd.dll')=crKeepShared),'Reader dependency not protected');
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('HomeLibReader'));
  Require(Plan.CanRemove and (Disposition('sqlite3.dll')=crKeepCore) and (Disposition('HomeLibRuUpdater.exe')=crKeepCore) and (Disposition('libzstd.dll')=crKeepShared),'Shared catalogue runtime not protected');
  ExecuteComponentRemovalPlan(Plan); Require(FileExists(Target+'\sqlite3.dll') and FileExists(Target+'\HomeLibRuUpdater.exe') and FileExists(Target+'\libzstd.dll'),'Shared files deleted'); RequirePrivate;
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('Zstandard')); Require(Plan.CanRemove,'Orphaned optional module cannot be removed'); ExecuteComponentRemovalPlan(Plan);
  Target:=Fixture('batch'); var ReaderReceipt:=Runtime('HomeLibReader',TArray<string>.Create('HomeLibReader.exe','HomeLibReader-LICENSE.txt','HomeLibRuUpdater.exe','sqlite3.dll','libzstd.dll','NOTICE'));
  TFile.WriteAllText(Target+'\libzstd.dll','new shared runtime owned by selected Zstandard');
  Runtime('Zstandard',TArray<string>.Create('libzstd.dll','tools/zstd/RUNTIME.json','tools/zstd/LICENSE'));
  Plan:=BuildComponentRemovalPlan(Target,TArray<string>.Create('HomeLibReader','Zstandard'));
  Require(Plan.CanRemove and (Disposition('libzstd.dll')=crRemove),'Selected owners of two historical versions did not release shared runtime');
  ExecuteComponentRemovalPlan(Plan); Require(not FileExists(Target+'\libzstd.dll') and FileExists(Target+'\sqlite3.dll'),'Batch removed core or retained an explicitly removed runtime'); RequirePrivate;
  Target:=Fixture('recovery'); Runtime('7-Zip',ZipNames); Source:=CheckedUpdateChildPath(Target,'tools/7zip/7z.exe'); Hash:=UpdateSHA256(Source);
  Pending('partial','tools/7zip/7z.exe'); Require(not FileExists(Source),'Recovery fixture did not interrupt a move');
  Require((Length(RecoverComponentRemovals(Target))=0) and (UpdateSHA256(Source)=Hash),'Interrupted removal did not recover'); RequirePrivate;
  Pending('conflict','tools/7zip/7z.exe'); TFile.WriteAllText(Source,'new foreign file');
  Require((Length(RecoverComponentRemovals(Target))=1) and (TFile.ReadAllText(Source)='new foreign file'),'Recovery overwrote a new user file'); RequirePrivate;
  Target:=Fixture('invalid-journal'); Runtime('7-Zip',ZipNames); Pending('tampered','tools/7zip/7z.exe');
  var Journal:=CheckedUpdateChildPath(Target,'tools/component-state/remove-tampered/state.json');
  var JournalText:=TFile.ReadAllText(Journal,TEncoding.UTF8);
  TFile.WriteAllText(Journal,JournalText.Replace('tools/7zip/7z.exe','Data/notes.json'),TEncoding.UTF8);
  Require(Length(RecoverComponentRemovals(Target))=1,'Recovery trusted a foreign personal-data path'); RequirePrivate;
  Writeln('PASS component removal plans preserve core shared settings modified and unknown files; exact legacy inventory, rollback, busy files, stale plans and interrupted recovery');
  RealPackages;
end;
