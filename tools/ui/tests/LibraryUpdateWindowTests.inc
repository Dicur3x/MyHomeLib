type
  TLibraryWindowDriver = class
    Profile: TLibraryUpdateSource;
    Accept, Started, Applying, Checked, Confirmed, Committed: Boolean;
    Failure, Report: string;
    Timer: TTimer;
    procedure Tick(Sender: TObject);
    function Confirm(const Text: string; Flags: Longint): Integer;
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
        TButton(Dialog.FindComponent('btnCheckUpdateSource')).Click;
        Require(Assigned(Dialog.Review) and Dialog.Review.Ready,'Window review failed: '+TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption);
        Checked:=True; Applying:=True;
        try TButton(Dialog.FindComponent('btnApplyUpdateSource')).Click;
        finally Applying:=False; end;
        Committed:=Dialog.Committed; Report:=TLabel(Dialog.FindComponent('lblUpdateSourceReport')).Caption;
        Require(Confirmed and (Committed=Accept),'Unexpected window application outcome: '+Report);
        Require(TButton(Dialog.FindComponent('btnApplyUpdateSource')).Enabled<>Accept,
          'Source window retained an obsolete apply state');
      except on E:Exception do Failure:=E.Message; end;
      Timer.Enabled:=False; Dialog.ModalResult:=mrCancel; Exit;
    end;
end;

procedure TestLibraryUpdateWindow;
var Root, IndexFile, IndexHash, ArchiveHash: string; ID: Integer;
  Target: IBookCollection; Book: TBookRecord; Profile: TLibraryUpdateSource;
  Driver: TLibraryWindowDriver; Timer: TTimer; Choice: TMenuItem; Button: TToolButton;
  Action: TAction; Options: TBookCompressionOperationOptions; OldTheme: Boolean;
begin
  Root:=TPath.Combine(Settings.AppPath,'window-update'); ForceDirectories(Root);
  var Zip:=TZipFile.Create;
  try
    Zip.Open(TPath.Combine(Root,'books.zip'),zmWrite);
    for var Number in TArray<string>.Create('501','502') do
      Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>'+Number+'</p></section></body></FictionBook>'),Number+'.fb2');
  finally Zip.Free; end;
  ArchiveHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'books.zip'));
  IndexFile:=TPath.Combine(Root,'new.inpx'); Zip:=TZipFile.Create;
  try
    Zip.Open(IndexFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
    Zip.Add(TEncoding.UTF8.GetBytes('Author,Test:'#4'prose_contemporary:'#4'Updated 501'#4#4#4'501'#4'100'#4'501'#4'0'#4'fb2'#4'2026-11-15'#4'ru'+sLineBreak+
      'Author,Test:'#4'prose_contemporary:'#4'New 502'#4#4#4'502'#4'100'#4'502'#4'0'#4'fb2'#4'2026-11-15'#4'ru'),'books.inp');
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
    Driver:=TLibraryWindowDriver.Create; Timer:=TTimer.Create(nil);
    try
      Driver.Profile:=Profile; Driver.Accept:=Accept; Driver.Timer:=Timer;
      Timer.Interval:=1; Timer.OnTimer:=Driver.Tick; Timer.Enabled:=True;
      Action.Update; Require(Action.Enabled,'Library update action stayed disabled');
      if Accept then Action.Execute else TMenuItem(frmMain.FindComponent('miLibraryUpdateSources')).Click;
      Require(Driver.Started and Driver.Checked and Driver.Confirmed and (Driver.Failure=''),
        'Source window integration failed: '+Driver.Failure);
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
    finally Timer.Free; Driver.Free; end;
  end;
  Require((THashSHA2.GetHashStringFromFile(IndexFile)=IndexHash) and
    (THashSHA2.GetHashStringFromFile(TPath.Combine(Root,'books.zip'))=ArchiveHash),
    'Window update changed its source index or book archive');
  Writeln('PASS library update menu and toolbar run reviewed confirmation, keep declined data, refresh the actual book view and offer incremental compression; both theme glyphs remain available');
end;
