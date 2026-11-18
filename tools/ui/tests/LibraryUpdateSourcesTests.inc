type
  TLibrarySourcesEntryDriver = class
  public
    Seen: Boolean;
    procedure Tick(Sender: TObject);
  end;
  TLibraryVersionServer = class
    IndividualRequests, GlobalRequests: Integer;
    Fail: Boolean;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  end;
  TLibraryReviewCancel = class
    Worker: TCollectionWorker;
    procedure Progress(Percent: Integer);
  end;

procedure TLibraryVersionServer.Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
begin
  Response.ResponseNo:=200;
  if Request.Document='/individual/version.txt' then
  begin InterlockedIncrement(IndividualRequests); Response.ContentText:='42'; end
  else if Request.Document='/global/version.txt' then
  begin InterlockedIncrement(GlobalRequests); Response.ContentText:='17'; end
  else Response.ResponseNo:=404;
  if Fail then begin Response.ResponseNo:=404; Response.ContentText:='999'; end;
end;

procedure TLibraryReviewCancel.Progress(Percent: Integer);
begin if Percent>0 then Worker.Cancel; end;

procedure TestLegacyIndividualUpdateURL;
var Server: TIdHTTPServer; Probe: TLibraryVersionServer; Updates: TUpdateInfoList; URL: string;
begin
  Server:=TIdHTTPServer.Create(nil); Probe:=TLibraryVersionServer.Create; Updates:=TUpdateInfoList.Create;
  try
    Server.OnCommandGet:=Probe.Command; Server.Bindings.Add.IP:='127.0.0.1';
    Server.Bindings[0].Port:=0; Server.Active:=True;
    URL:='http://127.0.0.1:'+IntToStr(Server.Bindings[0].Port);
    Updates.URL:=URL+'/global';
    Updates.Add('Individual',URL+'/individual','version.txt','not-present.individual.inpx',True,1);
    Updates.Add('Fallback','','version.txt','not-present.fallback.inpx',True,1);
    Updates.UpdateExternalVersions;
    Require((Updates[0].ExternalVersion=42) and (Updates[1].ExternalVersion=17) and
      (Probe.IndividualRequests=1) and (Probe.GlobalRequests=1),'Legacy update URLs did not reach their individual/default endpoints');
    Updates.URL:=''; Updates.UpdateExternalVersions;
    Require((Updates[0].ExternalVersion=42) and (Updates[1].ExternalVersion=0) and
      (Probe.IndividualRequests=2) and (Probe.GlobalRequests=1) and not Updates.ConnectionError,
      'Empty global URL disabled the individual endpoint or kept a stale version');
    Probe.Fail:=True; Updates.UpdateExternalVersions;
    Require((Updates[0].ExternalVersion=0) and Updates.ConnectionError and
      not Updates[0].CheckVersion(Settings.AppPath,0),'HTTP error response was treated as an available version');
    Updates.Clear; Updates.Add('Local only','','version.txt','not-present.local.inpx',True,1);
    Updates.UpdateExternalVersions;
    Require(not Updates.ConnectionError and (Probe.IndividualRequests=3) and (Probe.GlobalRequests=1),
      'Local-only updates tried to fetch a missing server endpoint');
  finally Server.Active:=False; Server.Free; Probe.Free; Updates.Free; end;
  Writeln('PASS legacy library updates request individual and default URLs, keep individual URLs with no global server, reset stale versions and reject HTTP errors');
end;

procedure TLibrarySourcesEntryDriver.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I] is TfrmLibraryUpdateSources then
    begin Seen:=True; TTimer(Sender).Enabled:=False; Screen.Forms[I].ModalResult:=mrCancel; Exit; end;
end;

procedure TestLibraryUpdateSources(const Target: IBookCollection);
var Sources, Loaded: TLibraryUpdateSources; Source: TLibraryUpdateSource;
  Editor: TfrmLibraryUpdateSourceEditor; Dialog: TfrmLibraryUpdateSources;
  CatalogSources: TCatalogSources; Reopened: IBookCollection;
  OriginalName, IndexFile, OriginalHash, Staging, Exported, Legacy, Revision, DownloadFolder, MetaFile, CacheHash, DateFile: string;
  Dark, OldTheme: Boolean;
  Entry: TMenuItem; Driver: TLibrarySourcesEntryDriver; Timer: TTimer;
  Zip: TZipFile; Row: string; Failed: Boolean;
  CanceledReview: TLibraryUpdateReview; CancelDriver: TLibraryReviewCancel; FileCount: Integer;
begin
  TestLegacyIndividualUpdateURL;
  CatalogSources:=LoadCatalogSources(Target);
  Require(Length(CatalogSources)>0,'Update source fixture needs a merged catalogue source');
  Source:=TLibraryUpdateSource.NewSource; Source.Name:='Исходное имя';
  Source.Location:=Settings.AppPath; Source.IndexFile:='review-source.inpx';
  Source.CatalogSourceID:=CatalogSources[0].ID;
  IndexFile:=TPath.Combine(Source.Location,Source.IndexFile);
  Zip:=TZipFile.Create;
  try
    Zip.Open(IndexFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
    Zip.Add(TEncoding.UTF8.GetBytes('20261114'),'version.info');
    Row:='Автор,Тест:'#4'prose_contemporary:'#4'Updated source title'#4'Цикл'#4'1'#4'1'#4'100'#4'1'#4'0'#4'fb2'#4'2026-10-08'#4'ru';
    Zip.Add(TEncoding.UTF8.GetBytes(Row),'books.inp');
    Row:='Автор,Тест:'#4'prose_contemporary:'#4'New source title'#4#4#4'2'#4'150'#4'2'#4'0'#4'fb2'#4'2026-11-14'#4'ru';
    Zip.Add(TEncoding.UTF8.GetBytes(Row),'f.fb2-100-200.inp');
    Row:='Автор,Тест:'#4'prose_contemporary:'#4'Dropped by source'#4#4#4'3'#4'150'#4'3'#4'1'#4'fb2'#4'2026-11-14'#4'ru';
    Zip.Add(TEncoding.UTF8.GetBytes(Row),'deleted-only.inp');
  finally Zip.Free; end;
  CacheHash:=THashSHA2.GetHashStringFromFile(CatalogSources[0].CacheFile);
  Editor:=TfrmLibraryUpdateSourceEditor.CreateForSource(frmMain,Source,CatalogSources);
  try
    TEdit(Editor.FindComponent('edUpdateSourceName')).Text:='Переименованный источник';
    TButton(Editor.FindComponent('btnAcceptUpdateSource')).Click;
    Require(Editor.ModalResult=mrOk,'Source editor did not accept valid fields');
    Require((Editor.Source.ID=Source.ID) and (Editor.Source.CatalogSourceID=Source.CatalogSourceID),
      'Editing display text changed the persistent source identity');
    Source:=Editor.Source;
    CheckSourceDialogLayout(Editor);
  finally Editor.Free; end;
  Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,Target);
  try
    Dialog.AppendSource(Source); Dialog.SaveSources;
    Require(not TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled,'Unreviewed source can be applied');
    Require(not TButton(Dialog.FindComponent('btnCopyNeededUpdateArchives')).Enabled,'Unreviewed source can clear the clipboard');
    Sources:=ReadLibraryUpdateSources(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
    Require((Length(Sources)=1) and (Sources[0].ID=Source.ID),'Source settings were not stored in this catalogue');
    OldTheme:=MHLThemeDark;
    try
      for Dark in TArray<Boolean>.Create(False,True) do
      begin SetMHLTheme(Dark); Dialog.Show; Application.ProcessMessages; CheckSourceDialogLayout(Dialog); Dialog.Hide; end;
    finally SetMHLTheme(OldTheme); end;
    IndexFile:=TPath.Combine(Settings.AppPath,Source.IndexFile);
    OriginalHash:=THashSHA2.GetHashStringFromFile(IndexFile);
    Revision:=Target.GetCatalogRevision;
    Dialog.CheckSource;
    Require(TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled,'Reviewed source does not offer application');
    Require(TButton(Dialog.FindComponent('btnCopyNeededUpdateArchives')).Enabled,'Missing archive names cannot be copied');
    Require(Assigned(Dialog.Prepared),'Source check did not retain its frozen index');
    Require(Dialog.Prepared.SHA256=OriginalHash,'Source check changed the index bytes');
    Require(Assigned(Dialog.Review) and Dialog.Review.Ready and Dialog.Review.PreviousIndex,
      'Actual index review did not use the saved source index');
    Require((Dialog.Review.Total=3) and (Dialog.Review.DeletedRecords=1) and
      (Dialog.Review.NewBooks=1) and (Dialog.Review.ChangedBooks=0),
      'Index review did not distinguish old and new records');
    Require((Dialog.Review.NeededArchives.Count=1) and
      (Dialog.Review.NeededArchives[0]='f.fb2-100-200.zip') and
      (Dialog.Review.HistoricalMissing.IndexOf('books.zip')>=0),
      'Index review requested a historical missing archive or omitted the exact new archive name');
    Require(Target.GetCatalogRevision=Revision,'Read-only update review changed the current catalogue');
    Require(THashSHA2.GetHashStringFromFile(CatalogSources[0].CacheFile)=CacheHash,
      'Read-only update review replaced the previous source index');
    CheckSourceDialogLayout(Dialog);
    Staging:=Dialog.Prepared.Folder;
    Exported:=Settings.AppPath+'update-source-export.json'; Dialog.ExportFile(Exported);
    Loaded:=ReadLibraryUpdateSources(TFile.ReadAllText(Exported,TEncoding.UTF8));
    Require((Length(Loaded)=1) and (Loaded[0].CatalogSourceID=Source.CatalogSourceID),'Window export lost its source binding');
    DateFile:=Settings.AppPath+'review-date-change.inpx'; Zip:=TZipFile.Create;
    try
      Zip.Open(DateFile,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Row:='Автор,Тест:'#4'prose_contemporary:'#4'Updated source title'#4'Цикл'#4'1'#4'1'#4'100'#4'1'#4'0'#4'fb2'#4'2026-11-13'#4'ru';
      Zip.Add(TEncoding.UTF8.GetBytes(Row),'books.inp');
    finally Zip.Free; end;
    Source.IndexFile:=TPath.GetFileName(DateFile); Dialog.ReplaceSource(0,Source); Dialog.CheckSource;
    Require((Dialog.Review.NewBooks=0) and (Dialog.Review.ChangedBooks=1) and
      (Dialog.Review.NeededArchives.IndexOf('books.zip')>=0),'A changed date in the same archive was ignored');
    Source.IndexFile:='review-source.inpx';
    DownloadFolder:=Settings.AppPath+'review-new-archives'; ForceDirectories(DownloadFolder);
    TFile.WriteAllText(TPath.Combine(DownloadFolder,'f.fb2-100-200.7z'),'presence only, no archive reads',TEncoding.UTF8);
    Source.BooksRoot:=DownloadFolder; Dialog.ReplaceSource(0,Source); Dialog.CheckSource;
    Require((Dialog.Review.FoundArchives.Count=1) and (Dialog.Review.NeededArchives.Count=0) and
      Dialog.Review.FoundArchives[0].Contains('f.fb2-100-200.7z'),
      'New archive folder or ZIP-to-7z fallback was ignored');
    Require(not TButton(Dialog.FindComponent('btnCopyNeededUpdateArchives')).Enabled,'Empty download list can clear the clipboard');
    TFile.WriteAllText(TPath.Combine(CatalogSources[0].Root,'f.fb2-100-200.zip'),'another presence fixture',TEncoding.UTF8);
    Dialog.CheckSource;
    Require(Dialog.Review.AmbiguousArchives.Count=1,'Same named archives in both roots were silently treated as one');
    TFile.Delete(TPath.Combine(CatalogSources[0].Root,'f.fb2-100-200.zip'));
    CanceledReview:=TLibraryUpdateReview.Create(Source,Dialog.Prepared); CancelDriver:=TLibraryReviewCancel.Create;
    FileCount:=Length(TDirectory.GetFiles(Dialog.Prepared.Folder));
    try
      CancelDriver.Worker:=CreateLibraryReviewWorker(Target.CollectionID,CanceledReview);
      try
        CancelDriver.Worker.OnProgress:=CancelDriver.Progress;
        CancelDriver.Worker.Start; CancelDriver.Worker.WaitFor;
        Require(CancelDriver.Worker.Canceled and not CanceledReview.Ready and not CancelDriver.Worker.CommittedChanges,
          'Canceled real index import left a ready update or committed live changes');
      finally CancelDriver.Worker.Free; end;
    finally CanceledReview.Free; CancelDriver.Free; end;
    Require((Length(TDirectory.GetFiles(Dialog.Prepared.Folder))=FileCount) and
      (Target.GetCatalogRevision=Revision),'Canceled index review retained its private database or changed the target');
    MetaFile:=Settings.AppPath+'review-metabib.jsonl';
    TFile.WriteAllText(MetaFile,'{"schema":"metabib.dataset/1","record_schema":"metabib.dataset_record/1",'+
      '"library":"flibusta","records":1,"archives":[{"id":"arc","name":"metabib-new.zip"}]}'+sLineBreak+
      '{"schema":"metabib.dataset_record/1","record":{"library":"flibusta","locator":{"kind":"archive_entry",'+
      '"source":"arc","index":0,"book_id":7002}},"artifacts":[{"occurrences":[{"archive":"arc",'+
      '"entry":"7002.fb2","index":0,"uncompressed_size":100}]}],"claims":{"bibliographic":{"title":[{"value":"New metabib book"}]}}}',TEncoding.UTF8);
    Source.IndexFile:=TPath.GetFileName(MetaFile); Dialog.ReplaceSource(0,Source); Dialog.CheckSource;
    Require((Dialog.Review.Total=1) and (Dialog.Review.NewBooks=1) and
      (Dialog.Review.NeededArchives.IndexOf('metabib-new.zip')>=0),'Metabib review did not use the real importer/archive map');
    TFile.AppendAllText(MetaFile,sLineBreak+'{"schema":"not-a-book"}'+sLineBreak,TEncoding.UTF8);
    Dialog.CheckSource;
    Require((Dialog.Review.SkippedRecords=1) and Dialog.Review.Summary.Contains('неполный'),
      'Skipped malformed Metabib records were hidden from the update review');
    CatalogSources[0].LibraryNamespace:='librusec'; SaveCatalogSources(Target,CatalogSources);
    Failed:=False;
    try Dialog.CheckSource; except on E:Exception do Failed:=E.Message.Contains('библиотеки'); end;
    Require(Failed and not Assigned(Dialog.Review),'Metabib from another library was accepted for a bound source');
    CatalogSources[0].LibraryNamespace:=''; SaveCatalogSources(Target,CatalogSources);
    Source.IndexFile:='source-0.inpx'; Dialog.ReplaceSource(0,Source); Failed:=False;
    try Dialog.CheckSource; except on E:Exception do Failed:=True; end;
    Require(Failed and not Assigned(Dialog.Review),'Broken index was presented as a valid update');
    Source.IndexFile:='review-source.inpx'; Dialog.ReplaceSource(0,Source); Dialog.CheckSource;
    Staging:=Dialog.Prepared.Folder;
    Writeln('PASS update review reads INPX and Metabib, separates historical missing archives, resolves downloaded 7z, diagnoses same names and library mismatches, rejects corrupt input and preserves live catalogues');
    Writeln('PASS update review detects same-archive date changes, excludes deleted placeholders, reports partial input and rolls back canceled inspection');
    Legacy:=Settings.AppPath+'update-source-import.ini';
    TFile.WriteAllText(Legacy,'[Groups]'+sLineBreak+'Group0=One'+sLineBreak+'[INPX]'+sLineBreak+
      'Inpx0="5";"Test";"Description";"catalog.inpx";'+sLineBreak+'[UPDATES]'+sLineBreak+
      'Update9="First";"";"";"first.inpx";"1";"0";'+sLineBreak+
      'Update9="Second";"";"";"second.inpx";"1";"0";',TEncoding.UTF8);
    Dialog.ImportFile(Legacy);
    Require(not Assigned(Dialog.Prepared),'Import did not invalidate the prior file check');
    Require(not TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled,'Imported settings retain an obsolete apply action');
    Require(not DirectoryExists(Staging),'Invalidated file check retained its owned staging');
    Loaded:=Dialog.Sources;
    Require((Length(Loaded)=2) and not Loaded[0].Enabled and not Loaded[1].Enabled,
      'Imported foreign templates were enabled for the current collection');
    Require((Pos('update9',LowerCase(TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption))>0) and
      (Pos('group5',LowerCase(TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption))>0),
      'Source import warnings are missing from the visible report');
    Loaded:=ReadLibraryUpdateSources(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
    Require((Length(Loaded)=1) and (Loaded[0].ID=Source.ID),'Reviewing an INI overwrote saved settings before Save');
  finally Dialog.Free; end;
  Require(THashSHA2.GetHashStringFromFile(IndexFile)=OriginalHash,'Window check removed or changed the original index');
  OriginalName:=Target.CollectionDisplayName;
  SystemDB.SetProperty(Target.CollectionID,PROP_DISPLAYNAME,'Renamed source target');
  try
    Reopened:=SystemDB.GetCollection(Target.CollectionID,True);
    Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,Reopened);
    try
      Loaded:=Dialog.Sources;
      Require((Length(Loaded)=1) and (Loaded[0].ID=Source.ID) and
        (Loaded[0].CatalogSourceID=CatalogSources[0].ID),'Collection rename broke update-source settings');
    finally Dialog.Free; end;
  finally SystemDB.SetProperty(Target.CollectionID,PROP_DISPLAYNAME,OriginalName); end;
  Entry:=frmMain.FindComponent('miLibraryUpdateSources') as TMenuItem;
  Require(Assigned(Entry),'Main collection menu has no update-source settings entry');
  Driver:=TLibrarySourcesEntryDriver.Create; Timer:=TTimer.Create(nil);
  try
    Timer.Interval:=1; Timer.OnTimer:=Driver.Tick; Timer.Enabled:=True;
    Entry.Click; Require(Driver.Seen,'Main collection menu did not open source settings');
  finally Timer.Free; Driver.Free; end;
  Writeln('PASS source settings window edits, persists stable bindings, checks a frozen local index, exports, reviews disabled legacy templates and survives collection rename; both themes and 96-288 DPI');
end;
