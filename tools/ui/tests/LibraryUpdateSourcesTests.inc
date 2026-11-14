type
  TLibrarySourcesEntryDriver = class
  public
    Seen: Boolean;
    procedure Tick(Sender: TObject);
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
  OriginalName, IndexFile, OriginalHash, Staging, Exported, Legacy: string;
  Dark, OldTheme: Boolean;
  Entry: TMenuItem; Driver: TLibrarySourcesEntryDriver; Timer: TTimer;
begin
  CatalogSources:=LoadCatalogSources(Target);
  Require(Length(CatalogSources)>0,'Update source fixture needs a merged catalogue source');
  Source:=TLibraryUpdateSource.NewSource; Source.Name:='Исходное имя';
  Source.Location:=Settings.AppPath; Source.IndexFile:='source-0.inpx';
  Source.CatalogSourceID:=CatalogSources[0].ID;
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
    Sources:=ReadLibraryUpdateSources(VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_SOURCES)));
    Require((Length(Sources)=1) and (Sources[0].ID=Source.ID),'Source settings were not stored in this catalogue');
    OldTheme:=MHLThemeDark;
    try
      for Dark in TArray<Boolean>.Create(False,True) do
      begin SetMHLTheme(Dark); Dialog.Show; Application.ProcessMessages; CheckSourceDialogLayout(Dialog); Dialog.Hide; end;
    finally SetMHLTheme(OldTheme); end;
    IndexFile:=TPath.Combine(Settings.AppPath,Source.IndexFile);
    OriginalHash:=THashSHA2.GetHashStringFromFile(IndexFile);
    Dialog.CheckSource;
    Require(Assigned(Dialog.Prepared),'Source check did not retain its frozen index');
    Require(Dialog.Prepared.SHA256=OriginalHash,'Source check changed the index bytes');
    Staging:=Dialog.Prepared.Folder;
    Exported:=Settings.AppPath+'update-source-export.json'; Dialog.ExportFile(Exported);
    Loaded:=ReadLibraryUpdateSources(TFile.ReadAllText(Exported,TEncoding.UTF8));
    Require((Length(Loaded)=1) and (Loaded[0].CatalogSourceID=Source.CatalogSourceID),'Window export lost its source binding');
    Legacy:=Settings.AppPath+'update-source-import.ini';
    TFile.WriteAllText(Legacy,'[Groups]'+sLineBreak+'Group0=One'+sLineBreak+'[INPX]'+sLineBreak+
      'Inpx0="5";"Test";"Description";"catalog.inpx";'+sLineBreak+'[UPDATES]'+sLineBreak+
      'Update9="First";"";"";"first.inpx";"1";"0";'+sLineBreak+
      'Update9="Second";"";"";"second.inpx";"1";"0";',TEncoding.UTF8);
    Dialog.ImportFile(Legacy);
    Require(not Assigned(Dialog.Prepared),'Import did not invalidate the prior file check');
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
