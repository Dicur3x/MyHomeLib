type
  TInpxSourceAccess = class(TframeNCWInpxSource)
    function Params: PNCWParams;
  end;
  TInpxSourceWizard = class(TNewCollectionWizard)
    procedure ShowLocalSource;
    function SourcePageVisible: Boolean;
  end;

function TInpxSourceAccess.Params: PNCWParams;
begin Result:=FPParams; end;

procedure TInpxSourceWizard.ShowLocalSource;
var Source: TInpxSourceAccess;
begin
  Source:=TInpxSourceAccess(FindComponent('frameNCWInpxSource'));
  Require(Assigned(Source),'Wizard source frame is absent');
  Source.Params^.Operation:=otInpx;
  Require(Source.Activate(True),'Local source page did not activate');
  ShowPage(2);
end;

function TInpxSourceWizard.SourcePageVisible: Boolean;
begin Result:=IsPageVisible(2); end;

procedure TestInpxWizardLocalSource;
var Host: TForm; Source: TframeNCWInpxSource; Params: TNCWParams;
  Wizard: TInpxSourceWizard; Names: TframeNCWNameAndLocation; Finish: TframeNCWFinish;
  Zip: TZipFile; Ini: TMemIniFile; Collection: IBookCollection;
  Store, OldURL, Root, IndexFile, SourceFile, SourceHash, IndexHash: string;
  HadStore: Boolean; StoreData: TBytes; Watch: TStopwatch; Authors, Books, Series: Integer;
  procedure SetServerList(Populated: Boolean);
  begin
    Ini:=TMemIniFile.Create(Store,TEncoding.UTF8);
    try
      Ini.EraseSection('GROUPS'); Ini.EraseSection('INPX');
      if Populated then
      begin
        Ini.WriteString('GROUPS','Group0','Fixture catalogues');
        Ini.WriteString('INPX','Inpx0','0;Fixture catalogue;Fixture description;server.inpx;unused');
      end;
      Ini.UpdateFile;
    finally Ini.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Store:=Settings.SystemFileName[sfCollectionsStore];
  Require(TPath.GetFullPath(Store).StartsWith(TPath.GetFullPath(Settings.AppPath),True),
    'INPX wizard fixture would touch a non-private catalogue store');
  OldURL:=Settings.InpxURL; HadStore:=TFile.Exists(Store);
  if HadStore then StoreData:=TFile.ReadAllBytes(Store);
  Root:=TPath.Combine(Settings.AppPath,'local-inpx-source'); ForceDirectories(Root);
  IndexFile:=TPath.Combine(Root,'fb2.flibusta.lib.rus.ec.7z.inpx');
  SourceFile:=TPath.Combine(Root,'book.fb2');
  TFile.WriteAllText(SourceFile,'<?xml version="1.0" encoding="UTF-8"?>'+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
    '<genre>prose_contemporary</genre><author><first-name>Test</first-name><last-name>Writer</last-name></author>'+
    '<book-title>Local INPX book</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Unchanged source book.</p></section></body></FictionBook>',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(SourceFile);
  Zip:=TZipFile.Create;
  try
    Zip.Open(IndexFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('Local INPX source regression'#13#10'local-source.hlc2'#13#10+
      IntToStr(CT_EXTERNAL_LOCAL_FB)+#13#10'Private fixture'),'collection.info');
    Zip.Add(TEncoding.UTF8.GetBytes('20261113'),'version.info');
    Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG;FOLDER'),'structure.info');
    Zip.Add(TEncoding.UTF8.GetBytes('Writer,Test:'#4'prose_contemporary:'#4'Local INPX book'#4#4#4'book'#4+
      IntToStr(TFile.GetSize(SourceFile))+#4'91002'#4'0'#4'fb2'#4'2026-11-13'#4'ru'#4'.'),'books.inp');
    Zip.Close;
  finally Zip.Free; end;
  IndexHash:=THashSHA2.GetHashStringFromFile(IndexFile);
  try
    Settings.InpxURL:=''; SetServerList(False);
    Host:=TForm.CreateNew(nil);
    try
      Source:=TframeNCWInpxSource.Create(Host); Source.Parent:=Host;
      Params:=Default(TNCWParams); Params.Operation:=otInpx; Source.Initialize(@Params);
      Require(Source.Activate(True),'Local page with no server did not activate');
      Require((Source.lvCollections.Items.Count=0) and not Source.rbDownload.Enabled,
        'Clean installation unexpectedly requires an INPX server');
      Require(Source.Deactivate(False),'Back navigation rejected an empty local path');
      Require(not Source.Deactivate(True),'Empty local INPX path was accepted');
      Source.edINPXPath.Text:=IndexFile+'.missing';
      Require(not Source.Deactivate(True),'Missing local INPX path was accepted');
      Source.edINPXPath.Text:=IndexFile;
      Require(Source.Deactivate(True) and (Params.Operation=otInpx) and
        (Params.INPXFile=IndexFile) and (Params.INPXUrl=''),
        'Local INPX still requires selection from the server catalogue list');
      SetServerList(True); Settings.InpxURL:='https://example.invalid/inpx';
      Require(Source.Activate(True) and (Source.lvCollections.Items.Count=1),'Fixture server list did not load');
      Source.rbDownload.Checked:=True; Source.OnSetINPXSource(Source.rbDownload);
      Require(Source.Deactivate(True) and (Params.Operation=otInpxDownload) and
        (Params.INPXUrl='https://example.invalid/inpx/server.inpx'),'Download source lost its selected catalogue');
      Source.lvCollections.Selected:=nil;
      Require(Source.Deactivate(False) and not Source.Deactivate(True),
        'Unselected download source asserts or accepts an undefined catalogue');
      Source.rbLocal.Checked:=True; Source.OnSetINPXSource(Source.rbLocal);
      Require(Source.Deactivate(True) and (Params.Operation=otInpx) and (Params.INPXUrl=''),
        'Switching from a server catalogue to a local INPX retained the download operation');
      SetServerList(False); Settings.InpxURL:='';
      Require(Source.Activate(True) and (Source.lvCollections.Items.Count=0),'Removed server entries remain in the list');
      Require(Source.Deactivate(True),'Local index stopped working after the server list became empty');
    finally Host.Free; end;
    Writeln('PASS local INPX source without server selected download missing file and backwards navigation'); Flush(Output);
    Wizard:=TInpxSourceWizard.Create(nil);
    try
      Wizard.Show; Wizard.ShowLocalSource;
      Source:=TframeNCWInpxSource(Wizard.FindComponent('frameNCWInpxSource'));
      Source.edINPXPath.Text:=IndexFile;
      Wizard.btnForward.Click;
      Names:=TframeNCWNameAndLocation(Wizard.FindComponent('frameNCWNameAndLocation'));
      Require(Assigned(Names) and Names.Visible and (Names.edCollectionName.Text='Local INPX source regression'),
        'Actual Next button did not read the local INPX header');
      Wizard.btnBackward.Click;
      Require(Source.Visible and (Source.edINPXPath.Text=IndexFile),'Back button lost the local source');
      Wizard.btnForward.Click;
      Names.edCollectionFile.Text:=TPath.Combine(Root,'registered.hlc2'); Names.edCollectionRoot.Text:=Root;
      Wizard.btnForward.Click;
      Finish:=TframeNCWFinish(Wizard.FindComponent('frameNCWFinish'));
      Watch:=TStopwatch.StartNew;
      while not Finish.Visible and (Watch.ElapsedMilliseconds<20000) do
      begin Application.ProcessMessages; CheckSynchronize(10); end;
      Require(Finish.Visible and Wizard.OperationSucceeded and Wizard.CommittedChanges and
        (Wizard.NewCollectionID>0),'Actual wizard did not finish importing the local INPX');
      Collection:=SystemDB.GetCollection(Wizard.NewCollectionID);
      Collection.GetStatistics(Authors,Books,Series);
      Require((Books=1) and (Authors=1),'Actual wizard imported an unexpected book count');
      Collection:=nil;
      TInpxSourceAccess(Source).Params^.Operation:=otInpxDownload;
      Require(Wizard.SourcePageVisible,'Download navigation hides its own source page');
      Wizard.Close;
    finally Collection:=nil; Wizard.Free; end;
    Require((THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash) and
      (THashSHA2.GetHashStringFromFile(IndexFile)=IndexHash),'Wizard regression changed its input files');
    Writeln('PASS actual local INPX wizard next back completed collection one book and unchanged inputs'); Flush(Output);
  finally
    Settings.InpxURL:=OldURL;
    if HadStore then TFile.WriteAllBytes(Store,StoreData) else TFile.Delete(Store);
  end;
end;
