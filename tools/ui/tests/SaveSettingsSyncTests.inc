// Actual Settings and Save As entry points against the wrapper-owned profile.
procedure TestSaveSettingsSync;
var SavedINI: TBytes; Root, FirstFolder, ChosenFolder, FB2, TXT: string;
  Form: TfrmSettings; Probe: TFCTModalProbe; Options, Initial: TBookSendOptions;
  Books: TArray<TBookRecord>; BeforeFB2, BeforeTXT: string;
  procedure EditINI(const Callback: TProc<TMemIniFile>);
  var Ini: TMemIniFile;
  begin
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try Callback(Ini); Ini.UpdateFile; finally Ini.Free; end;
    Settings.LoadSettings;
  end;
  procedure ApplyForm(Index: Integer; Folders: Boolean; const Destination, Mask: string);
  begin
    Form:=TfrmSettings.Create(nil);
    try
      Form.LoadSetting; Form.ScaleForPPI(96+(Index mod 3)*48);
      Require((Form.cbSaveAsSubfolders.Top+Form.cbSaveAsSubfolders.Height<=Form.edFolderTemplate.Top) and
        (Form.edFolderTemplate.Top+Form.edFolderTemplate.Height<=Form.edFileNameTemplate.Top) and
        (Form.edFileNameTemplate.Top+Form.edFileNameTemplate.Height<=Form.pnNameFormat.ClientHeight),
        'Settings naming controls overlap or are clipped after scaling');
      Require(Form.rgDeviceFormat.Items.Count=7,'Settings lost original or a supported default target');
      Form.rgDeviceFormat.ItemIndex:=Index;
      Form.edDeviceDir.Text:=Destination; Form.edFolderTemplate.Text:=Mask;
      Form.edFileNameTemplate.Text:='%t'; Form.cbSaveAsSubfolders.Checked:=Folders;
      Form.SaveAsFoldersClick(nil); Form.cbPromptPath.Checked:=True;
      Form.cbPromptPathClick(nil);
      Require(Form.edDeviceDir.Enabled and Form.btnDeviceDir.Enabled,
        'External-tool path preference disables the ordinary Save As destination');
      Require(Form.edFolderTemplate.Enabled=Folders,'Disabled subfolder policy has an active mask editor');
      Form.SaveSettingsClick(nil); Settings.SaveSettings; Settings.LoadSettings;
      Require((Settings.DeviceDir=Destination) and (Settings.SyncExportDir=Destination),
        'Settings changes are shadowed by a previous destination');
      Require((Settings.SaveAsUseSubfolders=Folders) and
        (Settings.SaveAsFolderTemplate=Mask) and (Settings.FileNameTemplate='%t'),
        'Settings changes did not reach the common naming policy');
      if Folders then Require(Settings.FolderTemplate=Mask,'Legacy worker mask differs from Save As')
      else Require(Settings.FolderTemplate='','Disabled subfolders remain active for the worker');
    finally FreeAndNil(Form); end;
  end;
  procedure Choose(const Selection: TArray<TBookRecord>; Accept, EditValues: Boolean;
    const ExpectedFolder, ExpectedCaption: string; Restored: PBookSendOptions = nil);
  begin
    Probe:=TFCTModalProbe.Create('TBookSendOptionsForm',
      Format('Сохранить как · книг: %d',[Length(Selection)]),
      procedure(Popup: TForm)
      begin
        Require(TEdit(Popup.FindComponent('SendDestination')).Text=ExpectedFolder,
          'Save As opened a stale destination');
        Require(TComboBox(Popup.FindComponent('SendFormat')).Text=ExpectedCaption,
          'Save As ignored the configured/restored format: '+TComboBox(Popup.FindComponent('SendFormat')).Text);
        if EditValues then
        begin
          TEdit(Popup.FindComponent('SendDestination')).Text:=ChosenFolder;
          TEdit(Popup.FindComponent('SaveNameTemplate')).Text:='%t';
          TCheckBox(Popup.FindComponent('SaveSubfolders')).Checked:=False;
          TEdit(Popup.FindComponent('SaveFolderTemplate')).Text:='%f\%s';
        end;
        if Accept then TButton(Popup.FindComponent('SendBooks')).Click
        else Popup.ModalResult:=mrCancel;
      end);
    try
      Require(ChooseBookSendOptions(Length(Selection),Root+'wrong-fallback',Settings.ExportMode,
        Options,False,Selection,Restored)=Accept,'Save As acceptance/cancellation changed');
      Require(Probe.Completed,'Actual Save As modal was not inspected');
    finally FreeAndNil(Probe); end;
  end;
begin
  RequireIsolatedRegression;
  SavedINI:=TFile.ReadAllBytes(Settings.SettingsFileName);
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'save-settings-sync');
  ForceDirectories(Root); FirstFolder:=Root+'settings destination'; ChosenFolder:=Root+'chosen destination';
  FB2:=Root+'source.fb2'; TXT:=Root+'source.txt';
  TFile.WriteAllText(FB2,'<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Source</book-title><lang>ru</lang></title-info></description><body><section><p>Текст ё 中文</p></section></body></FictionBook>',TEncoding.UTF8);
  TFile.WriteAllText(TXT,'Original text ё 中文',TEncoding.UTF8);
  BeforeFB2:=UpdateSHA256(FB2); BeforeTXT:=UpdateSHA256(TXT);
  Books:=[FileBook(FB2),FileBook(TXT)]; Form:=nil; Probe:=nil;
  try
    EditINI(procedure(Ini:TMemIniFile)
      begin
        Ini.WriteString('PATH','Device',Root+'old device');
        Ini.WriteString('PATH','SyncExport',Root+'last destination');
        Ini.WriteString('SYSTEM','FolderTemplate','%f\%s');
        Ini.DeleteKey('SYSTEM','SaveAsFolderTemplate');
        Ini.DeleteKey('SYSTEM','SaveAsUseSubfolders');
        Ini.DeleteKey('SYSTEM','SaveAsKeepSourceFormat');
        Ini.WriteInteger('SYSTEM','ExpFormat',Ord(emEpub));
      end);
    Require((Settings.DeviceDir=Root+'last destination') and
      (Settings.SyncExportDir=Settings.DeviceDir),'Older remembered folder was not migrated');
    Require((Settings.SaveAsFolderTemplate='%f\%s') and Settings.SaveAsUseSubfolders and
      Settings.SaveAsKeepSourceFormat,'Upgrade changed the prior source-copy default or folder policy');
    EditINI(procedure(Ini:TMemIniFile)
      begin
        Ini.WriteString('SYSTEM','SaveAsFolderTemplate','%s\%f');
        Ini.WriteBool('SYSTEM','SaveAsUseSubfolders',False);
        Ini.WriteInteger('SYSTEM','ExpFormat',Ord(emMobi));
      end);
    Require((Settings.SaveAsFolderTemplate='%s\%f') and not Settings.SaveAsUseSubfolders and
      (Settings.FolderTemplate='') and not Settings.SaveAsKeepSourceFormat,
      'Migration lost the disabled mask or an existing Kindle default');
    Writeln('PASS save settings migration preserves legacy choices and unifies remembered destination and active folder policy');

    for var Index:=0 to 6 do
    begin
      SetMHLTheme(Odd(Index));
      ApplyForm(Index,Index<>0,FirstFolder,'%s\%f');
      var Caption: string;
      case Index of
        0: Caption:='Оставить исходный формат каждой книги';
        1: Caption:='Преобразовать в FB2';
        2: Caption:='Преобразовать в FB2 в ZIP';
        3: Caption:='Преобразовать в EPUB';
        4: Caption:='Преобразовать в TXT — только текст';
        5: Caption:='Преобразовать в MOBI — для старых Kindle';
      else Caption:='Преобразовать в AZW3 — для Kindle с KF8'; end;
      Choose(Books,True,False,FirstFolder,Caption);
      Require((Options.KeepSourceFormat=(Index=0)) and not Options.KeepFB2EPUB,
        'A requested default silently changed its mixed-selection policy');
      if Index>0 then Require(Options.Mode=BOOK_SAVE_DEVICE_MODES[Index-1],
        'A requested default targets another format');
      Require((Options.FileNameTemplate='%t') and (Options.Folder=FirstFolder),
        'Default dialog dropped the configured naming or destination');
    end;
    Writeln('PASS save settings actual form applies seven defaults, shared masks and destination at three DPIs');
    ApplyForm(1,False,FirstFolder,'%s\%f');
    Choose([Books[0]],True,False,FirstFolder,'Оставить FB2');
    Require(Options.KeepSourceFormat and (Options.Mode=emFB2),'Same-format FB2 default requests needless conversion');
    var EpubChoices:=BookSaveChoices(['epub']);
    var EpubIndex:=BookSaveDefaultChoiceIndex(EpubChoices,emEpub,False);
    Require(EpubChoices[EpubIndex].KeepOriginal and (EpubChoices[EpubIndex].Mode=emEpub),
      'Homogeneous EPUB default requests needless conversion');
    Writeln('PASS save settings defaults reach single and mixed Save As without same-format duplicates');

    Initial:=Default(TBookSendOptions); Initial.Folder:=Root+'restored destination';
    Initial.Mode:=emEpub; Initial.KeepFB2EPUB:=True; Initial.FileNameTemplate:='%t';
    Initial.FolderTemplate:='%f'; Initial.ImageQuality:='original'; Initial.NameCollision:=bncKeepBoth;
    Choose(Books,True,False,Initial.Folder,'Оставить FB2 и EPUB; остальные — в EPUB',@Initial);
    Require(Options.KeepFB2EPUB and (Options.Mode=emEpub) and (Options.FolderTemplate='%f'),
      'Configured defaults overrode a restored operation');
    Writeln('PASS save settings restored operation retains explicit format, destination and folder policy');

    ApplyForm(0,False,FirstFolder,'%s\%f');
    Choose(Books,True,True,FirstFolder,'Оставить исходный формат каждой книги');
    Require(Options.KeepSourceFormat and (Options.Folder=ChosenFolder) and
      (Options.FolderTemplate=''),'Accepted Save As options lost disabled subfolders');
    Form:=TfrmSettings.Create(nil);
    try
      Form.LoadSetting;
      Require((Form.edDeviceDir.Text=ChosenFolder) and not Form.cbSaveAsSubfolders.Checked and
        (Form.edFolderTemplate.Text='%f\%s'),'Reopened Settings shows stale Save As values');
      Form.edDeviceDir.Text:=Root+'cancelled destination'; Form.edFolderTemplate.Text:='%s';
    finally FreeAndNil(Form); end;
    Settings.LoadSettings;
    Require((Settings.DeviceDir=ChosenFolder) and (Settings.SaveAsFolderTemplate='%f\%s') and
      not Settings.SaveAsUseSubfolders,'Canceling settings changed persisted Save As choices');
    Writeln('PASS save settings accepted Save As path and masks survive reopen, cancel and disabled subfolders');

    Require(not FileExists(Settings.AppPath+'tools\bookconvert\HomeLibBookConvert.exe'),
      'Minimum-save regression unexpectedly has a converter installed');
    Options.NameCollision:=bncKeepBoth;
    var Required: string;
    var Results:=SaveFileBooks(Books,Options,Required);
    Require((Required='') and (SuccessfulBookExportCount(Results)=2),'Unchanged originals requested an optional converter');
    Require((UpdateSHA256(ChosenFolder+'\source.fb2')=BeforeFB2) and
      (UpdateSHA256(ChosenFolder+'\source.txt')=BeforeTXT) and
      (UpdateSHA256(FB2)=BeforeFB2) and (UpdateSHA256(TXT)=BeforeTXT),
      'Mixed unchanged copy changed source or output bytes');
    Writeln('PASS save settings original mixed copy preserves exact bytes without an optional converter');

    for var Destination in TArray<string>.Create('shell:Downloads','::{20D04FE0-3AEA-1069-A2D8-08002B30309D}\device','\\?\wpd#device') do
    begin
      Settings.SyncExportDir:=Destination; Settings.SaveSettings; Settings.LoadSettings;
      Require((Settings.DeviceDir=Destination) and (Settings.SyncExportDir=Destination),
        'Device parsing name changed during shared path persistence');
    end;
    Writeln('PASS save settings device parsing names survive shared destination persistence');
  finally
    Probe.Free; Form.Free; TFile.WriteAllBytes(Settings.SettingsFileName,SavedINI); Settings.LoadSettings;
  end;
end;
