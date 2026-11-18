type
  TLibraryWindowDriver = class
    Profile: TLibraryUpdateSource;
    Accept, Started, Applying, Checked, Confirmed, Committed: Boolean;
    Failure, Report: string;
    TestWorkspace,WorkspaceValidated:Boolean;
    WorkspaceRoot:string;
    ProtectedCollectionID:Integer;
    Timer: TTimer;
    procedure CheckWorkspace(Dialog:TfrmLibraryUpdateSources);
    procedure Tick(Sender: TObject);
    function Confirm(const Text: string; Flags: Longint): Integer;
  end;

procedure TLibraryWindowDriver.CheckWorkspace(Dialog:TfrmLibraryUpdateSources);
var Catalogue,Personal:TSQLiteDatabase; Rows,PersonalRows,BeforeINI,BeforeFallback,Configured,Text:string;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Workspace window test requires G:');
  WorkspaceRoot:=Settings.AppPath+'update-workspace-'+BoolToStr(Accept,True);
  Require(not FileExists(WorkspaceRoot) and not DirectoryExists(WorkspaceRoot),'Workspace fixture already exists');
  ForceDirectories(WorkspaceRoot); Settings.UpdateDir:=WorkspaceRoot; Configured:=Settings.UpdateDir;
  TDirectory.Delete(WorkspaceRoot,False);
  if Accept then TFile.WriteAllText(WorkspaceRoot,'Owned file must remain unchanged',TEncoding.UTF8);
  Catalogue:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(ProtectedCollectionID).DBFileName);
  Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
  try
    Rows:=ReaderAllCatalogRows(Catalogue); PersonalRows:=ReaderAllCatalogRows(Personal);
    BeforeINI:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
    BeforeFallback:=string.Join(#0,TDirectory.GetDirectories(Settings.WorkPath,'HomeLibre-index-*'));
    TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
    Text:=TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption;
    Require(not Assigned(Dialog.Review) and not TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled,
      'Unavailable workspace produced a review through the fallback directory');
    Require(Text.ToLower.Contains('рабочая папка') and Text.Contains(WorkspaceRoot) and
      Text.Contains('Папки/Устройства'),'Workspace failure did not name its folder and recovery setting: '+Text);
    Require(Settings.UpdateDir=Configured,'Workspace refusal erased the configured folder');
    Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=BeforeINI,'Workspace refusal rewrote settings');
    Require(string.Join(#0,TDirectory.GetDirectories(Settings.WorkPath,'HomeLibre-index-*'))=BeforeFallback,
      'Workspace refusal allocated an index in the fallback directory');
    Require((ReaderAllCatalogRows(Catalogue)=Rows) and (ReaderAllCatalogRows(Personal)=PersonalRows),
      'Workspace refusal changed catalogue or personal rows/schema');
    if Accept then
    begin
      Require(TFile.ReadAllText(WorkspaceRoot,TEncoding.UTF8)='Owned file must remain unchanged',
        'Workspace refusal changed a file occupying the configured path');
      TFile.Delete(WorkspaceRoot);
    end
    else Require(not DirectoryExists(WorkspaceRoot),'Workspace refusal recreated the unavailable folder');
    ForceDirectories(WorkspaceRoot);
    TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
    Require(Assigned(Dialog.Review) and Dialog.Review.Ready,'Restored workspace did not allow retry: '+
      TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption);
    Require(Length(TDirectory.GetDirectories(WorkspaceRoot,'HomeLibre-index-*'))=1,
      'Restored review did not use the configured folder');
    WorkspaceValidated:=True;
    Writeln('PASS actual source window refuses unavailable workspace preserves configured folder settings rows and fallback then retries in restored folder file=',Ord(Accept)); Flush(Output);
  finally Personal.Free; Catalogue.Free; end;
end;

function TLibraryWindowDriver.Confirm(const Text: string; Flags: Longint): Integer;
begin
  Require(Checked and Applying and Text.Contains(Profile.Name) and ((Flags and MB_DEFBUTTON2)<>0),
    'Source window did not present its reviewed confirmation with default No');
  Confirmed:=True;
  if Accept then Result:=IDYES else Result:=IDNO;
end;

procedure TLibraryWindowDriver.Tick(Sender: TObject);
var Dialog: TfrmLibraryUpdateSources;
begin
  if Applying then
  begin
    for var I:=0 to Screen.FormCount-1 do
      if (Screen.Forms[I] is TImportProgressFormEx) and
        (Screen.Forms[I].Caption='Обновление библиотеки') then
      begin
        var Progress:=TImportProgressFormEx(Screen.Forms[I]);
        if Assigned(Progress.WorkerThread) then Progress.WorkerThread.OnShowMessage:=Confirm;
      end;
    Exit;
  end;
  if Started then Exit;
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmLibraryUpdateSources) and
      (fsModal in Screen.Forms[I].FormState) and IsWindowVisible(Screen.Forms[I].Handle) then
    begin
      Dialog:=TfrmLibraryUpdateSources(Screen.Forms[I]); Started:=True;
      try
        var Action:=TAction(frmMain.FindComponent('acUpdateLibrary')); Action.Update;
        Require(not Action.Enabled and not IsWindowEnabled(frmMain.Handle),
          'Main library actions remain available behind source settings');
        Dialog.SelectProfile(Profile.ID);
        if TestWorkspace then CheckWorkspace(Dialog)
        else TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
        Require(Assigned(Dialog.Review) and Dialog.Review.Ready,'Window review failed: '+TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption);
        Require(not TButton(Dialog.FindComponent('btnSaveMissingUpdateBooks')).Enabled,
          'Source window offers an obsolete missing-member report before verification');
        Checked:=True; Applying:=True;
        try TButton(Dialog.FindComponent('btnApplyUpdateSource')).Click;
        finally Applying:=False; end;
        Committed:=Dialog.Committed; Report:=TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption;
        Require(Confirmed and (Committed=Accept),'Unexpected window application outcome: '+Report);
        Require(TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled<>Accept,
          'Source window retained an obsolete apply state');
        var SaveButton:=TButton(Dialog.FindComponent('btnSaveMissingUpdateBooks'));
        Require(SaveButton.Enabled and Assigned(SaveButton.OnClick) and Dialog.Review.MissingReportReady and
          (Dialog.Review.MissingBooks=9),'Source window cannot save its verified missing members');
        Require(Report.Contains('503.fb2') and Report.Contains('books.zip') and
          Report.Contains('В архиве нет книги') and not Report.Contains('511.fb2') and
          Report.Contains('Сохранить пропуски'),'Missing-member preview is absent or is not bounded');
        var ReportFile:=TPath.Combine(Settings.AppPath,'missing-'+BoolToStr(Accept,True)+'.txt');
        Dialog.Review.SaveMissingReport(ReportFile);
        var Complete:=TFile.ReadAllText(ReportFile,TEncoding.UTF8);
        for var Number:=503 to 511 do Require(Complete.Contains(IntToStr(Number)+'.fb2'),
          'Complete missing-member report lost '+IntToStr(Number));
        Require(Complete.Contains('Неоднозначное имя книги') and Complete.Contains('Записей: 9.') and
          not Complete.Contains('501.fb2') and not Complete.Contains('502.fb2'),
          'Complete missing-member report omits the reason or includes available books');
        if not Accept then
        begin
          TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
          Require(not SaveButton.Enabled and (Dialog.Review.MissingDetails=''),
            'Rechecking the index retained an obsolete missing-member report');
        end;
      except on E:Exception do Failure:=E.Message; end;
      Timer.Enabled:=False; Dialog.ModalResult:=mrCancel; Exit;
    end;
end;

procedure TestLibraryUpdateWindow;
var Root, IndexFile, IndexHash, ArchiveHash: string; ID: Integer;
  Target: IBookCollection; Book: TBookRecord; Profile: TLibraryUpdateSource;
  Driver: TLibraryWindowDriver; Timer: TTimer; Choice: TMenuItem; Button: TToolButton;
  Action: TAction; Options: TBookCompressionOperationOptions; OldTheme: Boolean; SavedUpdateDir:string;
begin
  Root:=TPath.Combine(Settings.AppPath,'window-update'); ForceDirectories(Root);
  var Zip:=TZipFile.Create;
  try
    Zip.Open(TPath.Combine(Root,'books.zip'),zmWrite);
    for var Number in TArray<string>.Create('501','502') do
      Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Number+'</p></section></body></FictionBook>'),Number+'.fb2');
    Zip.Add(TEncoding.UTF8.GetBytes('first duplicate'),'a/511.fb2');
    Zip.Add(TEncoding.UTF8.GetBytes('second duplicate'),'b/511.fb2');
  finally Zip.Free; end;
  ArchiveHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'books.zip'));
  IndexFile:=TPath.Combine(Root,'new.inpx'); Zip:=TZipFile.Create;
  try
    Zip.Open(IndexFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
    var Rows:='Author,Test:'#4'prose_contemporary:'#4'Updated 501'#4#4#4'501'#4'100'#4'501'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak+
      'Author,Test:'#4'prose_contemporary:'#4'New 502'#4#4#4'502'#4'100'#4'502'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak;
    for var Number:=503 to 511 do Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4'Pending '+IntToStr(Number)+#4#4#4+
      IntToStr(Number)+#4'100'#4+IntToStr(Number)+#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak;
    Zip.Add(TEncoding.UTF8.GetBytes(Rows),'books.inp');
  finally Zip.Free; end;
  IndexHash:=THashSHA2.GetHashStringFromFile(IndexFile);
  ID:=SystemDB.CreateCollection('Window source update',Root,TPath.Combine(Root,'target.hlc2'),CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Target:=SystemDB.GetCollection(ID); Book:=Default(TBookRecord);
  Book.Title:='Original 501'; Book.LibID:='501'; Book.FileName:='501'; Book.FileExt:='.fb2'; Book.Folder:='books.zip';
  Book.Size:=100; Book.Lang:='ru'; TAuthorsHelper.Add(Book.Authors,'Author','Test','');
  Target.InsertBook(Book,False,False);
  Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Window source'; Profile.Location:=Root; Profile.IndexFile:='new.inpx';
  Target.SetProperty(PROP_LIBRARY_UPDATE_SOURCES,WriteLibraryUpdateSources(TArray<TLibraryUpdateSource>.Create(Profile)));
  Options:=Default(TBookCompressionOperationOptions); Options.Profile:='original'; Options.WorkRoot:=TPath.Combine(Root,'compression-work');
  RememberCollectionCompressionWork(TPath.Combine(Settings.DataPath,'compression-work.ini'),Target,Options);
  Choice:=TMenuItem.Create(nil);
  try Choice.Tag:=ID; frmMain.miActiveCollectionClick(Choice);
  finally Choice.Free; end;
  frmMain.Show; Application.ProcessMessages;
  ShowPage(PAGE_AUTHORS); ExpectTitles(frmMain.tvBooksA,['Original 501']);
  Button:=frmMain.FindComponent('btnUpdateLibrary') as TToolButton;
  Action:=frmMain.FindComponent('acUpdateLibrary') as TAction;
  Require(Assigned(Button) and Assigned(Action) and (Button.Action=Action) and (Button.Parent=frmMain.tlbrMain) and
    (Button.Style=tbsDropDown) and Assigned(Button.DropdownMenu) and (Button.DropdownMenu.Items.Count=2),
    'Library update toolbar entry is absent or disconnected');
  OldTheme:=MHLThemeDark;
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark); Application.ProcessMessages;
      Require((Button.ImageIndex=24) and (dmImages.ToolbarImageCollection.Images[24].SourceImages.Count>0),
        Format('Library update toolbar glyph is missing: index=%d sources=%d dark=%s',
          [Button.ImageIndex,dmImages.ToolbarImageCollection.Images[24].SourceImages.Count,BoolToStr(Dark,True)]));
    end;
  finally SetMHLTheme(OldTheme); end;
  for var Accept in TArray<Boolean>.Create(False,True) do
  begin
    Driver:=TLibraryWindowDriver.Create; Timer:=TTimer.Create(nil); SavedUpdateDir:=Settings.UpdateDir;
    try
      Driver.Profile:=Profile; Driver.Accept:=Accept; Driver.Timer:=Timer;
      Driver.TestWorkspace:=ParamStr(1)='library-update-workspace'; Driver.ProtectedCollectionID:=ID;
      Timer.Interval:=1; Timer.OnTimer:=Driver.Tick; Timer.Enabled:=True;
      Action.Update; Require(Action.Enabled,'Library update action stayed disabled');
      if Accept then Action.Execute else TMenuItem(frmMain.FindComponent('miLibraryUpdateSources')).Click;
      Require(Driver.Started and Driver.Checked and Driver.Confirmed and (Driver.Failure=''),
        'Source window integration failed: '+Driver.Failure);
      Require(not Driver.TestWorkspace or Driver.WorkspaceValidated,'Workspace refusal/retry was not observed');
      Require(IsWindowEnabled(frmMain.Handle) and (Settings.ActiveCollection=ID),
        'Source update did not restore the main window');
      if Accept then
      begin
        ShowPage(PAGE_AUTHORS); ExpectTitles(frmMain.tvBooksA,['Updated 501','New 502']);
        var Offer:=frmMain.FindComponent('pnCompressionOffer') as TPanel;
        Require(Assigned(Offer) and Offer.Visible,'Successful source update did not offer incremental compression');
        TButton(frmMain.FindComponent('btnCompressArrivalsLater')).Click;
        Require(not Offer.Visible,'Compression offer could not be postponed');
        Require(Driver.Report.Contains('Обновление применено') and not Driver.Report.Contains('Применить обновление'),
          'Finished report still asks whether to apply the completed update');
      end
      else
      begin
        ExpectTitles(frmMain.tvBooksA,['Original 501']);
        var Offer:=frmMain.FindComponent('pnCompressionOffer') as TPanel;
        Require(not Assigned(Offer) or not Offer.Visible,'Declined update offered compression');
      end;
      Action.Update; Require(Action.Enabled,'Library update action did not recover after closing settings');
    finally
      Settings.UpdateDir:=SavedUpdateDir;
      if Driver.WorkspaceValidated then
      begin
        Require(TDirectory.IsEmpty(Driver.WorkspaceRoot),'Closed source window retained workspace files');
        TDirectory.Delete(Driver.WorkspaceRoot,False);
      end;
      Timer.Free; Driver.Free;
    end;
  end;
  Require((THashSHA2.GetHashStringFromFile(IndexFile)=IndexHash) and
    (THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'books.zip'))=ArchiveHash),
    'Window update changed its source index or book archive');
  Writeln('PASS library update menu and toolbar run reviewed confirmation, keep declined data, refresh the actual book view and offer incremental compression; both theme glyphs remain available');
  Writeln('PASS reviewed update missing-member report previews bounded details and saves complete archive/member reasons after decline or apply');
end;
