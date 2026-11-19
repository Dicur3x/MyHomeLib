procedure TestContextToolGuides(CID:Integer);
const Topics:array[0..15] of string=('book-compression','book-duplicates','book-metadata-fill',
    'collection-backup','library-update-sources','book-description','book-export','opds-catalogue',
    'update-from-file','module-maintenance','new-collection','reader-saved-items','manual-book-import',
    'catalog-colors','reader-cache','program-updates');
  Names:array[0..15] of string=('CompressionContextGuide','DuplicatesContextGuide','MetadataContextGuide',
    'BackupContextGuide','UpdateSourcesContextGuide','BookDescriptionContextGuide','BookExportContextGuide',
    'OPDSContextGuide','UpdateFileContextGuide','ModulesContextGuide','NewCollectionContextGuide','ReaderSavedContextGuide','ManualImportContextGuide',
    'CatalogColorsContextGuide','ReaderCacheContextGuide','UpdatesContextGuide');
  Inputs:array[0..15] of string=('CompressionProfile','btnFindBookDuplicates','cbMetadataField0',
    'lbCollectionBackups','lvLibraryUpdateSources','mmoAnnotation','SendDestination','OPDSPort','edFile',
    'MaintenanceModules','btnForward','NotesSearch','pcPages','PaletteTheme','ReaderCachePolicy','UpdateComponents');
  Intros:array[0..15] of string=('CompressionOptionsIntro','DuplicateIntro','lblMetadataFillScope',
    'BackupIntro','UpdateSourcesIntro','lblAnnotationState','SaveIntro','OPDSCollection','lblFile',
    'ModuleMaintenanceIntro','','','','PaletteTheme','ReaderCacheIntro','UpdateVersion');
var OriginalTheme:Boolean; Host,Popup:TForm; Tool:TContextToolGuide; Guide:TFirstUseGuide;
  Collection:IBookCollection; BeforeData,PreferencesSHA:string; Ini:TMemIniFile;
  FocusBefore:TWinControl; ActiveBefore,ForegroundBefore:HWND; FocusChecks:Integer; FocusFailure,ExportFolderBefore:string;

  procedure Pump;
  begin
    var UntilTick:=GetTickCount64+60;
    repeat Application.ProcessMessages; CheckSynchronize(1); Sleep(1); until GetTickCount64>=UntilTick;
  end;
  procedure Preferences(Topic:Integer; Seen:string; Disabled:Boolean);
  begin
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try
      Ini.WriteString('ToolGuidesSeen',Topics[Topic],Seen);
      Ini.WriteBool('ToolGuidesDisabled',Topics[Topic],Disabled);
      Ini.WriteString('ContextGuideSentinel','Keep','unchanged');
      Ini.UpdateFile;
    finally Ini.Free; end;
  end;
  procedure OpenHost(Kind,PPI:Integer);
  begin
    case Kind of
      0: begin
        var Options:=Default(TBookCompressionOperationOptions);
        Options.Profile:='balanced'; Options.WorkRoot:=Settings.WorkPath;
        Host:=TfrmBookCompressionOptions.CreateOptions(frmMain,1,Options);
      end;
      1: Host:=TfrmBookDuplicates.CreateForCollection(frmMain,Collection);
      2: Host:=TfrmBookMetadataFill.CreateForCollection(frmMain,CID);
      3: Host:=TfrmCollectionBackup.Create(frmMain);
      4: Host:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,Collection);
      5: begin
        var Details:=TfrmBookDetails.Create(frmMain); Host:=Details;
        Details.ConfigureDescription(Default(TBookRecord),True,False);
        Details.LoadDescription('Проверенное описание'); Details.FocusDescription;
      end;
      6: begin
        Host:=TBookSendOptionsForm.Create(frmMain);
        ExportFolderBefore:=TEdit(Host.FindComponent('SendDestination')).Text;
      end;
      7: Host:=TfrmOPDS.Create(frmMain);
      8: Host:=TdlgUpdateFromFile.Create(frmMain);
      9: Host:=TfrmComponentMaintenance.CreateManager(frmMain,Settings.AppPath,False,False,nil,Default(TComponentReleases),nil);
      10: Host:=TNewCollectionWizard.Create(frmMain);
      11: Host:=TReaderSavedDialog.CreateProfile(frmMain,Settings.SettingsFileName);
      12: begin
        Host:=TfrmAddnonfb2.Create(frmMain);
        TfrmAddnonfb2(Host).Collection:=Collection;
      end;
      13: Host:=TInterfaceColorsDialog.CreateFor(frmMain,Default(TMHLThemePalettes),False);
      14: Host:=TfrmReaderCacheSettings.Create(frmMain);
      15: Host:=TfrmProgramUpdate.Create(frmMain);
    end;
    var BasePPI:=Host.PixelsPerInch;
    var BaseWidth:=Host.ClientWidth;
    var BaseHeight:=Host.ClientHeight;
    Host.ScaleForPPI(PPI);
    if (Kind in [9,13,14,15]) and (BasePPI<>PPI) then
    begin
      Host.ClientWidth:=MulDiv(BaseWidth,PPI,BasePPI);
      Host.ClientHeight:=MulDiv(BaseHeight,PPI,BasePPI);
    end;
    Host.Show;
    Tool:=Host.FindComponent(Names[Kind]) as TContextToolGuide;
    Require(Assigned(Tool) and Assigned(Tool.HelpButton.OnClick),'Tool-local help button is absent');
    Require(Tool.HelpButton.BoundsRect.Right<=Tool.HelpButton.Parent.ClientWidth,'Help button is outside its panel');
    if Intros[Kind]<>'' then
    begin
      var Intro:=Host.FindComponent(Intros[Kind]) as TControl;
      Require((Tool.HelpButton.Parent=Intro.Parent) and
        (Intro.BoundsRect.Right<=Tool.HelpButton.Left),
        Format('Help overlaps %s at %d PPI. Intro ends at %d, button starts at %d, parent width %d',
          [Intros[Kind],PPI,Intro.BoundsRect.Right,Tool.HelpButton.Left,Tool.HelpButton.Parent.ClientWidth]));
    end;
    var Input:=Host.FindComponent(Inputs[Kind]) as TWinControl;
    Input.SetFocus; var BeforeChecks:=FocusChecks;
    Pump;
    Popup:=Tool.FindComponent('ToolGuidePopup'+Topics[Kind].Replace('-','')) as TForm;
    Require(Assigned(Popup),'First-use controller did not initialize its guide');
    Guide:=Popup.FindComponent('ToolFirstUseGuide') as TFirstUseGuide;
    Require(FocusChecks>BeforeChecks,'Automatic first-use path was not observed');
    Require(FocusFailure='',FocusFailure);
  end;
  procedure CheckGuide(Kind:Integer);
  begin
    var Work:=Host.Monitor.WorkareaRect;
    Require(Popup.Visible and Guide.Expanded,'Context guide is not visible/expanded');
    Require((Popup.Left>=Work.Left) and (Popup.Top>=Work.Top) and
      (Popup.BoundsRect.Right<=Work.Right) and (Popup.BoundsRect.Bottom<=Work.Bottom),
      'Context guide is outside the work area');
    for var Name in ['GuideSummary','GuideDetails'] do
    begin
      var LabelControl:=Guide.FindComponent(Name) as TLabel;
      Popup.Canvas.Font.Assign(LabelControl.Font); var Bounds:=Rect(0,0,LabelControl.Width,0);
      DrawTextW(Popup.Canvas.Handle,PChar(LabelControl.Caption),Length(LabelControl.Caption),Bounds,
        DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
      Require((Bounds.Height<=LabelControl.Height) and
        (LabelControl.BoundsRect.Bottom<=Guide.ClientHeight),'Guide text is clipped');
    end;
    Require(Guide.FindComponent('GuideContextHelp')=nil,'Popup contains a redundant help button');
    Require(TControl(Guide.FindComponent('GuideSummary')).Width=TControl(Guide.FindComponent('GuideDetails')).Width,
      'Popup still reserves a help-button column');
    for var Name in ['GuideToggle','GuideNever'] do
    begin
      var Control:=Guide.FindComponent(Name) as TControl;
      Require(Control.Visible and (Control.Left>=0) and
        (Control.BoundsRect.Right<=Guide.ClientWidth) and
        (Control.BoundsRect.Bottom<=Guide.ClientHeight),Format('Guide action is clipped: %s %d,%d %dx%d parent %dx%d',
          [Name,Control.Left,Control.Top,Control.Width,Control.Height,Guide.ClientWidth,Guide.ClientHeight]));
    end;
    var More:=Guide.FindComponent('GuideMore') as TButton;
    Require(More.Visible=((Kind<>11) and DirectoryExists(Settings.AppPath+'Help')),
      'The guide offered a link to absent help or omitted the installed help');
    if More.Visible then
      Require(Assigned(More.OnClick) and (More.BoundsRect.Right<=Guide.ClientWidth) and
        (More.BoundsRect.Bottom<=Guide.ClientHeight),'Context guide link is inaccessible');
  end;
  procedure CheckSearchGuide;
  begin
    var OldTab:=frmMain.pgControl.ActivePage;
    var OldVisible:=frmMain.Visible;
    var OldText:=frmMain.edFFullName.Text;
    try
      frmMain.pgControl.ActivePage:=frmMain.tsSearch;
      frmMain.pgControlChange(nil);
      frmMain.edFFullName.Text:='Проверочный запрос';
      frmMain.Show;
      frmMain.edFFullName.SetFocus;
      var BeforeChecks:=FocusChecks;
      Pump;
      var SearchTool:=frmMain.FindComponent('SearchContextGuide') as TContextToolGuide;
      var SearchPopup:=SearchTool.FindComponent('ToolGuidePopupcatalogsearch') as TForm;
      var Mode:=frmMain.FindComponent('SearchQueryModeControl').FindComponent('SearchQueryModeCombo') as TComboBox;
      Require(Mode.BoundsRect.Right<=SearchTool.HelpButton.Left,'Search mode overlaps help');
      Require((FocusChecks>BeforeChecks) and (FocusFailure=''),'The search guide interrupted input focus');
      Require(SearchPopup.Visible,'Search guide did not open on entry');

      frmMain.pgControl.ActivePage:=frmMain.tsByAuthor;
      frmMain.pgControlChange(nil);
      Pump;
      Require(not SearchPopup.Visible,'Search guide remained visible on the author tab');

      frmMain.pgControl.ActivePage:=frmMain.tsSearch;
      frmMain.pgControlChange(nil);
      Pump;
      Require(not SearchPopup.Visible,'Returning to the search tab repeated the guide');
      SearchTool.HelpButton.Click;
      Pump;
      Require(SearchPopup.Visible and (frmMain.edFFullName.Text='Проверочный запрос'),
        'Manual help did not open or changed the current search');
      frmMain.Hide;
      Pump;
      Require(not SearchPopup.Visible,'Search help remained visible after hiding the catalogue');
      Writeln('PASS search contextual guide on tab entry, exit and re-entry with preserved criteria');
    finally
      frmMain.edFFullName.Text:=OldText;
      frmMain.pgControl.ActivePage:=OldTab;
      frmMain.pgControlChange(nil);
      frmMain.Visible:=OldVisible;
    end;
  end;
  procedure CheckIdle(Kind:Integer);
  begin
    Require(Host.ModalResult=mrNone,'Help accepted/closed its tool');
    case Kind of
      0: Require(TfrmBookCompressionOptions(Host).SelectedOptions.Profile='balanced',
        'Help changed compression settings');
      1: Require(not TfrmBookDuplicates(Host).Plan.Ready and
        not TfrmBookDuplicates(Host).CatalogChanged,'Help scanned or changed duplicates');
      2: Require(not TfrmBookMetadataFill(Host).Busy and
        not TfrmBookMetadataFill(Host).CommittedChanges,'Help started metadata processing');
      3: Require((TfrmCollectionBackup(Host).NewCollectionID=INVALID_COLLECTION_ID) and
        not TButton(Host.FindComponent('btnRestoreBackup')).Enabled,'Help restored a backup or enabled restoration');
      4: Require(not Assigned(TfrmLibraryUpdateSources(Host).Prepared) and
        not TfrmLibraryUpdateSources(Host).Committed,'Help prepared or applied an update');
      5: Require(not TfrmBookDetails(Host).AnnotationChanged and not TfrmBookDetails(Host).ReviewChanged and
        (TfrmBookDetails(Host).Annotation.Trim='Проверенное описание'),'Help changed the book description');
      6: Require(TEdit(Host.FindComponent('SendDestination')).Text=ExportFolderBefore,'Help changed the export folder');
      7: Require(not TButton(Host.FindComponent('OPDSStop')).Enabled,'Help started the OPDS server');
      8: Require((TEdit(Host.FindComponent('edFile')).Text='') and not TCheckBox(Host.FindComponent('cbFull')).Checked,
        'Help changed the index or update mode');
      9: Require(not TButton(Host.FindComponent('MaintenanceRemove')).Enabled,'Help selected modules for removal');
      10: Require(not TNewCollectionWizard(Host).CommittedChanges,'Help created a collection');
      11: Require((TEdit(Host.FindComponent('NotesSearch')).Text='') and
        TCheckBox(Host.FindComponent('NotesShowNotes')).Checked,'Help changed note filters');
      12: Require(not TfrmAddnonfb2(Host).BooksAdded,'Help added a book');
      13: Require(TComboBox(Host.FindComponent('PaletteTheme')).ItemIndex=0,'Help changed the edited theme');
      14: Require(TComboBox(Host.FindComponent('ReaderCachePolicy')).ItemIndex=Ord(Settings.BookCachePolicy),'Help changed the cache policy');
    end;
  end;
begin
  RequireIsolatedRegression; OriginalTheme:=MHLThemeDark; Host:=nil;
  Collection:=SystemDB.GetCollection(CID); BeforeData:=MLIReadCatalogData(CID);
  FocusChecks:=0;
  ContextGuideShowProbe:=procedure(After:Boolean)
    begin
      if not After then
      begin
        FocusBefore:=FindControl(GetFocus); ActiveBefore:=GetActiveWindow; ForegroundBefore:=GetForegroundWindow;
      end
      else
      begin
        if FindControl(GetFocus)<>FocusBefore then FocusFailure:='Automatic guide changed the input component';
        if GetActiveWindow<>ActiveBefore then FocusFailure:='Automatic guide activated another window';
        if GetForegroundWindow<>ForegroundBefore then FocusFailure:='Automatic guide changed foreground application';
        Inc(FocusChecks);
      end;
    end;
  try
    for var Dark in [False,True] do
      for var PPI in [96,216] do
        for var Kind:=Low(Topics) to High(Topics) do
        begin
          SetMHLTheme(Dark); Pump; Preferences(Kind,'earlier-release',False);
          PreferencesSHA:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
          try
            OpenHost(Kind,PPI); CheckGuide(Kind); CheckIdle(Kind);
            if Dark and (PPI=216) and (Kind=0) and
              FileExists(Settings.AppPath+'context-guide-preview.marker') then
            begin
              TFile.WriteAllText(Settings.AppPath+'context-guide-preview.ready','ready',TEncoding.UTF8);
              var Deadline:=GetTickCount64+300000;
              while not FileExists(Settings.AppPath+'context-guide-preview.done') do
              begin Require(GetTickCount64<Deadline,'Context guide preview timed out'); Pump; end;
            end;
            Require(THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=PreferencesSHA,
              'Opening context help persisted preferences before acknowledgement');
            TButton(Guide.FindComponent('GuideToggle')).Click; Pump;
            Require(not Popup.Visible,'Acknowledged context guide remains in front');
            Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
            try Require((Ini.ReadString('ToolGuidesSeen',Topics[Kind],'')=PROGRAM_RELEASE_VERSION) and
              (Ini.ReadString('ContextGuideSentinel','Keep','')='unchanged'),
              'Acknowledgement lost the topic version or another preference');
            finally Ini.Free; end;
          finally FreeAndNil(Host); end;
          try
            OpenHost(Kind,PPI);
            Require(not Popup.Visible,'Same beta repeated an acknowledged guide');
            Tool.HelpButton.Click; Pump; CheckGuide(Kind); CheckIdle(Kind);
            var NarrowWidth:=Popup.Width-MulDiv(80,PPI,96);
            Popup.Width:=NarrowWidth; Pump;
            Require(Popup.Width=NarrowWidth,'Context guide overwrote a user resize');
            CheckGuide(Kind);
            TCheckBox(Guide.FindComponent('GuideNever')).Checked:=True;
            Popup.Close; Pump; Require(not Popup.Visible,'Closing the guide did not hide it');
          finally FreeAndNil(Host); end;
          Preferences(Kind,'earlier-release',True);
          try
            OpenHost(Kind,PPI); Require(not Popup.Visible,'Disabled guide reopened for another beta');
            Tool.HelpButton.Click; Pump; CheckGuide(Kind);
            PreferencesSHA:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
            var Hold:=TFileStream.Create(Settings.SettingsFileName,fmOpenRead or fmShareDenyWrite);
            try TButton(Guide.FindComponent('GuideToggle')).Click; Pump;
            finally Hold.Free; end;
            Require(not Popup.Visible and (THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=PreferencesSHA),
              'Unavailable preference storage blocked the tool or rewrote preferences');
            CheckIdle(Kind);
          finally FreeAndNil(Host); end;
          Require(MLIReadCatalogData(CID)=BeforeData,'Guide-only interaction changed catalogue data');
          Writeln('PASS contextual tool guide ',Topics[Kind],' ppi=',PPI,' dark=',Dark,
            ' automatic focus layout acknowledgement repeat suppression manual and readonly preferences');
        end;
    CheckSearchGuide;
  finally ContextGuideShowProbe:=nil; Host.Free; SetMHLTheme(OriginalTheme); end;
end;
