procedure TestDistributionLayout;
var OldLocale, Root, Backup, Name, Expected, LegacyHistory, LegacyChanges: string;
  Collection: IBookCollection; Genre: TGenreData; Count, ID: Integer;
  Iterator: IGenreIterator; Types: TArray<TMHLSystemFile>;
  procedure CheckGenres(NewLayout: Boolean);
  begin
    for var Locale in ['', 'en', 'uk', 'bg', 'missing'] do
    begin
      Settings.Locale:=Locale;
      for var Kind in Types do
      begin
        if Kind=sfGenresFB2 then Name:=GENRES_FB2_FILENAME else Name:=GENRES_NONFB2_FILENAME;
        if (Locale<>'') and (Locale<>'missing') then
          Name:=ChangeFileExt(Name,'')+'_'+Locale+ExtractFileExt(Name);
        if NewLayout then Expected:=Root+GENRELIST_DIR_NAME+Name else Expected:=Root+Name;
        Require(SameFileName(Settings.SystemFileName[Kind],Expected),'Incorrect genre resource for '+Locale+': '+Settings.SystemFileName[Kind]);
        Require(FileExists(Expected),'Genre resource is missing: '+Expected);
        if NewLayout then Require(UpdateSHA256(Expected)=UpdateSHA256(Backup+Name),'Genre resource bytes changed');
      end;
      if NewLayout then
      begin
        ID:=SystemDB.CreateCollection('Layout '+Locale,Root,'layout-'+Locale+'.hlc2',
          CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
        Collection:=SystemDB.GetCollection(ID); Iterator:=Collection.GetGenreIterator(gmAll); Count:=0;
        while Iterator.Next(Genre) do Inc(Count);
        Require(Count>100,'New collection lost its translated genre registry');
        Iterator:=nil; Collection:=nil;
      end;
    end;
  end;
begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath; OldLocale:=Settings.Locale;
  Types:=TArray<TMHLSystemFile>.Create(sfGenresFB2,sfGenresNonFB2);
  Backup:=Root+'layout-legacy\'; ForceDirectories(Backup);
  try
    CheckGenres(False);
    ForceDirectories(Root+GENRELIST_DIR_NAME);
    for Name in TDirectory.GetFiles(Root,'genres*.glst') do
    begin
      TFile.Copy(Name,Root+GENRELIST_DIR_NAME+ExtractFileName(Name),False);
      TFile.Move(Name,Backup+ExtractFileName(Name));
    end;
    CheckGenres(True);
    LegacyHistory:=Root+'COMPONENTS.json'; LegacyChanges:=Root+'CHANGES.txt';
    Require(SameFileName(Settings.SystemFileName[sfComponentHistory],LegacyHistory),'Legacy component history not found');
    TFile.WriteAllText(LegacyChanges,'# HomeLib Ru fixture changes',TEncoding.UTF8);
    Require(SameFileName(Settings.SystemFileName[sfProgramChanges],LegacyChanges),'Legacy changes not found');
    ForceDirectories(Root+'tools\updates'); ForceDirectories(Root+'Help');
    TFile.Copy(LegacyHistory,Root+'tools\updates\COMPONENTS.json',False);
    TFile.Move(LegacyHistory,Backup+'COMPONENTS.json');
    TFile.Move(LegacyChanges,Root+'Help\CHANGES.txt');
    Require(SameFileName(Settings.SystemFileName[sfComponentHistory],Root+'tools\updates\COMPONENTS.json'),'Grouped component history not found');
    Require(SameFileName(Settings.SystemFileName[sfProgramChanges],Root+'Help\CHANGES.txt'),'Grouped changes not found');
    Require(UpdateSHA256(Settings.SystemFileName[sfComponentHistory])=UpdateSHA256(Backup+'COMPONENTS.json'),'Component history bytes changed');
    Require(SafeUpdateName('tools/genres/genres_fb2_uk.glst') and
      SafeUpdateName('tools/updates/COMPONENTS.json') and SafeUpdateName('Help/CHANGES.txt'),
      'Grouped resources are not accepted by the update path policy');
    Require(not SafeUpdateName('tools/../Data/user.dbs2') and not SafeUpdateName('tools/genres/profile.ini'),
      'Resource layout weakened user-data protection');
    Writeln('PASS distribution layout resolves grouped and legacy resources all genre languages and update metadata without root copies');
  finally Settings.Locale:=OldLocale; end;
end;
