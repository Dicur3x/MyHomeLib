program CollectionViewsTest;

{$APPTYPE CONSOLE}
{$R *.res}
{$R '..\..\..\Program\MyhomeLib.res'}
{$R '..\..\..\Program\MyhomeLib.dres'}
{$R '..\..\..\Program\lang.res'}

uses
  unit_StartupCatalog, unit_FLibraryCompat, NativeRegressionGuard, System.SysUtils, System.StrUtils, System.Classes, System.IOUtils, System.IniFiles, System.JSON, System.Net.HttpClient, System.Net.URLClient, System.Generics.Collections, System.Variants, Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, Winapi.RichEdit, Winapi.ActiveX, Winapi.ShlObj,
  Vcl.Forms, Vcl.Dialogs, Vcl.Themes, Vcl.Styles, Vcl.Clipbrd, Vcl.CheckLst, Vcl.Graphics, Vcl.Menus, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Controls, Vcl.StdCtrls, Vcl.ActnList,
  VirtualTrees, VirtualTrees.Types, VirtualTrees.BaseTree, BookTreeView, BookInfoPanel, unit_MHLTheme, unit_BookGallery, unit_UpdateNotes, unit_UpdateTextCache,
  System.SyncObjs, System.Zip, System.Hash, System.NetEncoding, System.Diagnostics, System.Math, System.DateUtils, Vcl.Imaging.pngimage,
  unit_ImageBounds, unit_BookCache, unit_MHLOperationStatus, unit_Globals, unit_Consts, unit_Interfaces, unit_Localization, unit_TreeUtils, unit_Settings, unit_ReaderCache, unit_BookMetadataCache, unit_FB2Utils, FictionBook_21, unit_BookColumnFilters, unit_BookInfoPreview, unit_CollectionMerge, unit_SeriesAliases, unit_CatalogSources, frm_CatalogSources, unit_CollectionSpace, unit_Database_SQLite, SQLiteWrap, SQLite3, SQLiteProfile,
  unit_MHLExternalTools, unit_MHLArchiveHelpers, unit_ExportToDeviceThread, unit_AuthorInfo, unit_Helpers,
  unit_Scripts, frm_edit_script, Vcl.ToolWin, unit_ImportOldUserData,
  unit_Events, unit_BookExportResults, unit_BookExportSelection, unit_BookExportPlan,
  unit_SearchQueryModeControl, unit_LegacyUserDataPreview, frm_LegacyUserDataPreview, unit_InpLineReader,
  frm_ExportToDeviceProgressForm, unit_ReaderDocument, unit_SearchPresets, unit_xmlUtils,
  MHLButtonedEdit, MHLLinkLabel, unit_Columns,
  unit_SystemDatabase_SQLite,
  unit_WorkerThread, unit_CollectionWorkerThread, unit_libupdateThread, unit_ImportFB2Thread,
  unit_ImportFBDThread, unit_ImportMetabibThread,
  unit_ReaderDOC, unit_ReaderOffice, unit_ReaderKindle, unit_ReaderFormats,
  unit_MetadataSyncTypes, unit_CollectionMetadataSync, frm_BookMetadataFill, unit_NCWParams,
  unit_FB2PublisherMetadataReader, unit_PublisherSeriesSource, unit_SevenZipMetadata, unit_PackageBookMetadata, unit_ReaderAnnotations, unit_ReaderNoteBooks,
  unit_Downloader, unit_DownloadBooksThread, unit_DownloadManagerThread, unit_DownloadView, unit_treeController,
  IdHTTPServer, IdCustomHTTPServer, IdContext,
  unit_FB2MetadataRecovery, unit_WriteFb2Info,
  unit_BookConversion in '..\..\..\Program\Units\unit_BookConversion.pas', unit_UserData,
  unit_AtomicIniFile in '..\..\..\Program\Units\unit_AtomicIniFile.pas',
  unit_AuthorFavorites in '..\..\..\Program\Units\unit_AuthorFavorites.pas',
  unit_AuthorFavoriteRefresh in '..\..\..\Program\Units\unit_AuthorFavoriteRefresh.pas',
  frm_AuthorInformation, frm_book_info, frm_statistic, unit_ReviewParser, frm_BuiltinReader,
  dm_user, dm_Images, frm_splash, frm_main, frm_genre_tree, unit_PublisherSeriesView,
  frm_ProgramUpdate, frm_settings, unit_ProgramUpdates, unit_ComponentUpdates, unit_ProgramUpdateInstaller,
  frm_ImportProgressFormEx, unit_IndexPublisherSeriesThread, unit_ImportInpxThread, frm_NewCollectionWizard,
  frame_NCWCollectionNameAndLocation, frame_NCWCollectionFileTypes,
  frame_NCWFinish, frame_WizardPageBase, frm_ConverToFBD, unit_FileMutex;

type
  TRegressionExceptionHandler = class
    procedure HandleException(Sender: TObject; E: Exception);
  end;

procedure TRegressionExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  // VCL otherwise displays a modal dialog inside form/event construction,
  // hiding the cause from a console runner until its timeout.
  Writeln('FAIL VCL ', E.ClassName, ': ', E.Message);
  Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
  Flush(Output);
  // Live VCL timers must not run unit finalizers after a failed assertion.
  Winapi.Windows.ExitProcess(1);
end;

procedure Require(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create(Message);
end;

type
  TFBDNavigationFixture = class
    Book: TBookRecord; Moves, Changes: Integer;
    procedure GetBook(var Value: TBookRecord);
    procedure NextBook(MoveForward: Boolean);
    procedure Converted(const Value: TBookRecord);
  end;

procedure TFBDNavigationFixture.GetBook(var Value: TBookRecord);
begin Value:=Book; end;
procedure TFBDNavigationFixture.NextBook(MoveForward: Boolean);
begin Inc(Moves); end;
procedure TFBDNavigationFixture.Converted(const Value: TBookRecord);
begin Inc(Changes); Book.FileName:='payload.zip'; end;

procedure TestFBDEditorSave;
var Fixture: TFBDNavigationFixture; Dialog: TfrmConvertToFBD;
  Locked, Released: TEvent; Worker: TThread; Folder, RawPath, RawText: string;
begin
  Fixture:=TFBDNavigationFixture.Create; Dialog:=TfrmConvertToFBD.Create(nil);
  Locked:=TEvent.Create(nil,True,False,''); Released:=TEvent.Create(nil,True,False,''); Worker:=nil;
  try
    Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'fbd-edit-fixture'));
    ForceDirectories(Folder); RawPath:=Folder+'payload.txt'; RawText:='Исходная книга ё и Unicode.';
    TFile.WriteAllText(RawPath,RawText,TEncoding.UTF8);
    Fixture.Book:=Default(TBookRecord); Fixture.Book.BookKey:=CreateBookKey(1,1);
    Fixture.Book.CollectionRoot:=Folder; Fixture.Book.FileName:='payload'; Fixture.Book.FileExt:='.txt';
    Fixture.Book.Title:='Книга без автора'; Fixture.Book.Lang:='ru'; Fixture.Book.NodeType:=ntBookInfo;
    Dialog.OnGetBook:=Fixture.GetBook; Dialog.OnSelectBook:=Fixture.NextBook; Dialog.OnChangeBook2Zip:=Fixture.Converted;
    Dialog.FBD.ReportErrors:=False; Dialog.Show; Application.ProcessMessages;
    Require(Dialog.lblAuthor.Caption='Автор не указан','Authorless FBD card has no useful label');
    Dialog.mmAnnotation.Text:='Новая аннотация ё'; Dialog.edPublisher.Text:='Свой издатель';
    var ArchivePath:=Dialog.FBD.ArchiveFileName;
    Worker:=TThread.CreateAnonymousThread(procedure
      var Mutex: TFileMutex;
      begin
        Mutex:=TFileMutex.Create(ArchivePath);
        try
          if Mutex.TryAcquire then Locked.SetEvent;
          Released.WaitFor(5000);
        finally Mutex.Free; end;
      end);
    Worker.FreeOnTerminate:=False; Worker.Start;
    Require(Locked.WaitFor(1000)=wrSignaled,'FBD lock fixture failed');
    Dialog.btnNextClick(nil); Dialog.btnPreviousClick(nil); Dialog.btnSaveClick(nil);
    Require((Fixture.Moves=0) and (Fixture.Changes=0),'Failed saving moved away from the current book or changed its filename');
    Require((Dialog.mmAnnotation.Text='Новая аннотация ё') and (Dialog.edPublisher.Text='Свой издатель'),'Failed saving erased entered metadata');
    Require(TFile.ReadAllText(RawPath,TEncoding.UTF8)=RawText,'Locked FBD conversion changed book contents');
    Require(not FileExists(ArchivePath) and (Dialog.ModalResult<>mrOk),'Locked saving published an archive or closed the editor');
    Released.SetEvent; Worker.WaitFor;
    Dialog.btnNextClick(nil);
    Require((Fixture.Moves=1) and (Fixture.Changes=1),'Successful FBD save did not resume navigation exactly once');
    Require(FileExists(ArchivePath),'Successful conversion failed to publish archive');
    Require((Dialog.mmAnnotation.Lines.Count=1) and (Dialog.mmAnnotation.Lines[0]='Новая аннотация ё') and (Dialog.edPublisher.Text='Свой издатель'),'Saved FBD metadata failed to reopen');
    Require((Dialog.FBD.Title.Annotation.P.Count=1) and (Dialog.FBD.Title.Annotation.P.Items[0].Text='Новая аннотация ё'),'Saved annotation lost Unicode');
    var Payload:=Dialog.FBD.ExtractBook(Folder);
    Require(TFile.ReadAllText(Payload,TEncoding.UTF8)=RawText,'Successful FBD conversion lost original payload');
    Writeln('PASS FBD editor preserves unsaved metadata on locked save, authorless cards, Unicode payload and resumes navigation only after successful publication');
  finally
    Released.SetEvent; if Assigned(Worker) then begin Worker.WaitFor; Worker.Free; end;
    Released.Free; Locked.Free; Dialog.Free; Fixture.Free;
  end;
end;

procedure TestSQLiteRuntime;
var DB: TSQLiteDatabase;
begin
  DB:=TSQLiteDatabase.Create(Settings.AppPath+'sqlite-runtime-probe.db');
  try
    Require(DB.QuerySingleString('SELECT sqlite_version()')='3.54.1','Unexpected packaged SQLite runtime');
    Require(DB.QuerySingleString('SELECT sqlite_source_id()')=
      '2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76','SQLite source differs from pinned release');
    DB.ExecSQL('CREATE VIRTUAL TABLE RuntimeSearch USING fts5(Text)');
    DB.ExecSQL('INSERT INTO RuntimeSearch VALUES (''книга поиск''),(''другой документ'')');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM RuntimeSearch WHERE RuntimeSearch MATCH ''поиск''')=1,'Packaged FTS5 Unicode search failed');
    Require(DB.QuerySingleString('PRAGMA integrity_check')='ok','SQLite runtime fixture integrity failed');
    Writeln('PASS packaged SQLite 3.54.1 source identity, FTS5 Unicode search and integrity');
  finally DB.Free; end;
end;

procedure TestSQLiteQueryBatch;
var DB: TSQLiteDatabase; First, Second: TSQLiteQuery; I: Integer;
begin
  DB:=TSQLiteDatabase.Create(':memory:');
  try
    DB.ExecSQL('CREATE TABLE BatchValues(ID INTEGER PRIMARY KEY, Value TEXT)');
    DB.BeginQueryBatch;
    try
      for I:=1 to 250 do DB.ExecSQL('INSERT INTO BatchValues VALUES(?,?)',[I,IntToStr(I)]);
      First:=DB.NewQuery('SELECT ? AS Value');
      try
        First.SetParam(0,'first'); First.Open;
        Second:=DB.NewQuery('SELECT ? AS Value');
        try
          Second.SetParam(0,'second'); Second.Open;
          Require(First.FieldAsString(0)='first','Live cached statements shared parameters');
          Require(Second.FieldAsString(0)='second','Concurrent statement lost its own value');
        finally Second.Free; end;
      finally First.Free; end;
      First:=DB.NewQuery('SELECT ? AS Value');
      try First.Open; Require(First.FieldIsNull(0),'Reused statement retained prior parameters');
      finally First.Free; end;
      First:=DB.NewQuery('SELECT * FROM BatchValues');
      try Require(First.ColCount=2,'Initial query has wrong column count');
      finally First.Free; end;
      DB.ExecSQL('ALTER TABLE BatchValues ADD COLUMN Extra TEXT');
      First:=DB.NewQuery('SELECT * FROM BatchValues');
      try Require(First.ColCount=3,'Schema change retained old column metadata');
      finally First.Free; end;
      First:=DB.NewQuery('SELECT * FROM BatchValues');
      try DB.ExecSQL('ALTER TABLE BatchValues ADD COLUMN Later TEXT');
      finally First.Free; end;
      First:=DB.NewQuery('SELECT * FROM BatchValues');
      try Require(First.ColCount=4,'Old live query entered the pool after a schema change');
      finally First.Free; end;
      DB.BeginQueryBatch;
      try
        for I:=1 to 256 do Require(DB.QuerySingleInt('SELECT '+IntToStr(I))=I,
          'Bounded statement pool returned a different query');
      finally DB.EndQueryBatch; end;
      DB.Start;
      DB.ExecSQL('INSERT INTO BatchValues(ID,Value) VALUES(?,?)',[251,'rollback']);
      DB.Rollback;
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM BatchValues')=250,'Cached statements broke rollback');
    finally DB.EndQueryBatch; end;
    Require(DB.QuerySingleString('PRAGMA integrity_check')='ok','Query batch integrity failed');
    Writeln('PASS bounded statement reuse, cleared parameters, concurrent queries, schema changes and rollback');
    Flush(Output);
  finally DB.Free; end;
end;

type
  TFirstRunDriver = class
    Step: Integer;
    Finished: Boolean;
    Timer: TTimer;
    procedure Tick(Sender: TObject);
  end;

procedure TFirstRunDriver.Tick(Sender: TObject);
var I: Integer; Wizard: TNewCollectionWizard; Page: TWizardPageBase;
  Names: TframeNCWNameAndLocation; Files: TframeNCWCollectionFileTypes;
begin
  Wizard := nil;
  for I := 0 to Screen.FormCount - 1 do
    if Screen.Forms[I] is TNewCollectionWizard then
      Wizard := TNewCollectionWizard(Screen.Forms[I]);
  if not Assigned(Wizard) or not Wizard.Visible or not IsWindowVisible(Wizard.Handle) then Exit;
  Writeln('TRACE wizard Visible=', Wizard.Visible, ' bounds=', Wizard.Left, ',',
    Wizard.Top, ',', Wizard.Width, ',', Wizard.Height);
  Flush(Output);
  Require((Wizard.Width >= 520) and (Wizard.Height >= 390), 'First-run wizard has invalid bounds');
  if ParamStr(1) = 'first-run-cancel' then
  begin
    Finished := True; Timer.Enabled := False; Wizard.OnCancel(Wizard.btnCancel); Exit;
  end;
  Page := nil;
  for I := 0 to Wizard.ComponentCount - 1 do
    if (Wizard.Components[I] is TWizardPageBase) and
      TWizardPageBase(Wizard.Components[I]).Visible then
      Page := TWizardPageBase(Wizard.Components[I]);
  Require(Assigned(Page), 'First-run wizard has no visible page');
  if Page is TframeNCWNameAndLocation then
  begin
    Names := TframeNCWNameAndLocation(Page);
    Names.edCollectionName.Text := 'First launch regression';
    Names.edCollectionRoot.Text := Settings.AppPath + 'first-run-books';
    ForceDirectories(Names.edCollectionRoot.Text);
    Names.edCollectionFile.Text := Settings.DataDir + 'first-run.hlc2';
  end;
  if Page is TframeNCWCollectionFileTypes then
  begin
    Files := TframeNCWCollectionFileTypes(Page);
    Files.cbAutoImport.Checked := False;
  end;
  Inc(Step); Require(Step <= 8, 'First-run wizard did not advance');
  Writeln('TRACE wizard page ', Page.ClassName); Flush(Output);
  if Page is TframeNCWFinish then
  begin
    Finished := True; Timer.Enabled := False; Wizard.OnCancel(Wizard.btnCancel);
  end
  else
    Wizard.DoChangePage(Wizard.btnForward);
end;

procedure RunFirstRunRegression;
var Driver: TFirstRunDriver; Started: UInt64; Collection: IBookCollection;
begin
  Require(not SystemDB.HasCollections, 'First-run regression needs an empty profile');
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TdmImages, dmImages);
  dmImages.ApplyThemeIcons;
  Driver := TFirstRunDriver.Create;
  try
    Driver.Timer := TTimer.Create(nil); Driver.Timer.Enabled := False;
    Driver.Timer.Interval := 100; Driver.Timer.OnTimer := Driver.Tick;
    Driver.Timer.Enabled := True;
    TfrmMain.DeferInitialCollection := True;
    Application.CreateForm(TfrmMain, frmMain);
    if not Assigned(frmGenreTree) then Application.CreateForm(TfrmGenreTree, frmGenreTree);
    frmSplash.Hide;
    frmMain.StartInitialCollectionLoad;
    Started := GetTickCount64;
    if ParamStr(1) <> 'first-run-cancel' then Application.ProcessMessages;
    while not Driver.Finished and (GetTickCount64 - Started < 10000) do
    begin Application.ProcessMessages; Sleep(10); end;
    Require(Driver.Finished, 'First-run wizard did not appear');
    if ParamStr(1) = 'first-run-cancel' then
    begin
      Require(not SystemDB.HasCollections, 'Cancelling first launch created a collection');
      // Match the real DPR: Run consumes the posted quit message.
      // ProcessMessages may remove WM_QUIT without ending Run.
      Application.Run;
      Require(Application.Terminated and not SystemDB.HasCollections,
        'Cancelling first launch must exit without creating a collection');
      Writeln('PASS visible first-run wizard cancellation exits cleanly');
    end
    else
    begin
      Require(SystemDB.HasCollections and (Settings.ActiveCollection > 0),
        'First-run wizard did not create and select the collection');
      Collection := SystemDB.GetCollection(Settings.ActiveCollection);
      Require(Assigned(Collection) and (Collection.CollectionDisplayName = 'First launch regression'),
        'First-run collection name was not saved');
      Require(not Application.Terminated and frmMain.Visible, 'Main window did not remain visible');
      Writeln('PASS visible first-run wizard creates an empty collection without indexing');
      Collection := nil;
    end;
    frmGenreTree.Free; frmGenreTree := nil;
    frmMain.Free; frmMain := nil;
    dmImages.Free; dmImages := nil;
    DMUser.Free; DMUser := nil;
  finally Driver.Timer.Free; Driver.Free; end;
end;

var
  CleanupExitTemp, CleanupExitPersistent, CleanupExitSource: string;

procedure TestUpdateDefaults;
var Ini: TMemIniFile; Loaded: TMHLSettings;
begin
  Ini := TMemIniFile.Create(Settings.SettingsFileName, TEncoding.UTF8);
  try
    Ini.DeleteKey('SYSTEM', 'CheckUpdates');
    Ini.DeleteKey('SYSTEM', 'ProgramUpdateMinutes');
    Ini.UpdateFile;
    Loaded := TMHLSettings.Create;
    try
      Loaded.LoadSettings;
      Require(Loaded.CheckUpdate and (Loaded.ProgramUpdateMinutes = 4320),
        'Fresh profile must check every three days');
    finally Loaded.Free; end;
    Ini.WriteBool('SYSTEM', 'CheckUpdates', False);
    Ini.WriteInteger('SYSTEM', 'ProgramUpdateMinutes', 60);
    Ini.UpdateFile;
    Loaded := TMHLSettings.Create;
    try
      Loaded.LoadSettings;
      Require(not Loaded.CheckUpdate and (Loaded.ProgramUpdateMinutes = 60),
        'Explicit Never and interval must survive defaults');
    finally Loaded.Free; end;
  finally Ini.Free; end;
  Writeln('PASS new update default is three days and preserves explicit choices');
end;

// Synthetic update versions must be visibly separated from real author checks.
function CreateTestProgramUpdate: TfrmProgramUpdate;
begin
  Result:=TfrmProgramUpdate.Create(nil);
  Result.Caption:='Обновление HomeLib Ru — тестовые данные';
end;

{$I UpdateComponentTableTests.inc}

procedure TestProgramUpdateUI;
var Popup: TfrmProgramUpdate; Configuration: TfrmSettings; ReleaseInfo, Parsed: TProgramRelease;
  ComponentID, SQLiteArch: string; NotesView: TUpdateNotesView;
  I, HeightBefore, BodyBefore, SavedWidth, SavedHeight: Integer; Notes, PreviousEditor: TRichEdit;
  Primary: TButton; Version, Bytes: TLabel; Selector, ReloadedSelector: TListView;
  Previous, Failed: TComponentReleases; Cache: string; Reloaded: TfrmProgramUpdate;
  ReloadedView: TUpdateNotesView; EndPoint: TPoint;
  CycleComponents: TComponentReleases;

  function StatusText(Form: TfrmProgramUpdate): string;
  var Index: Integer;
  begin
    Result := '';
    for Index := 0 to Form.ControlCount - 1 do
      if (Form.Controls[Index] is TLabel) and (Form.Controls[Index].Name = 'UpdateStatus') then
        Result := TLabel(Form.Controls[Index]).Caption;
  end;

  function CopiedText: string;
  begin
    for var Attempt:=0 to 29 do
      try Exit(Clipboard.AsText);
      except on E: EClipboardException do if Attempt=29 then raise else Sleep(10); end;
    Result:='';
  end;

  procedure ChooseRow(View: TListView; Index: Integer);
  begin
    View.Items[Index].Selected:=True;
    View.OnSelectItem(View,View.Items[Index],True);
  end;

  procedure CheckTableLayout;
  var Form: TfrmProgramUpdate; View: TListView; Body: TUpdateNotesView; DPI, Index: Integer;
    SavedDark: Boolean; Button: TButton; Tabs: TTabControl; HistorySelector: TComboBox;
  begin
    SavedDark:=MHLThemeDark;
    try
      for DPI in [96,144,192] do
      begin
        // Each native harness subcase keeps the full workflow, cached notes
        // and its original functional guard, then checks one requested DPI.
        if ParamStr(2).StartsWith('layout-') and
          (ParamStr(2)<>'layout-'+IntToStr(DPI)) then Continue;
        Form:=CreateTestProgramUpdate;
        try
          Form.Show; Application.ProcessMessages;
          Form.ScaleForPPI(DPI); Form.ClientWidth:=MulDiv(760,DPI,96); Form.ClientHeight:=MulDiv(560,DPI,96);
          Tabs:=TTabControl(Form.FindComponent('UpdateTabs'));
          HistorySelector:=TComboBox(Form.FindComponent('UpdateHistoryComponent'));
          Require(Assigned(Tabs) and Assigned(HistorySelector),'Update/changes views missing');
          Tabs.TabIndex:=0; Tabs.OnChange(Tabs);
          Form.Show; Application.ProcessMessages; View:=nil; Body:=nil; Button:=nil;
          for Index:=0 to Form.ControlCount-1 do
          begin
            if Form.Controls[Index] is TListView then View:=TListView(Form.Controls[Index]);
            if Form.Controls[Index] is TUpdateNotesView then Body:=TUpdateNotesView(Form.Controls[Index]);
            if (Form.Controls[Index] is TButton) and TButton(Form.Controls[Index]).Default then Button:=TButton(Form.Controls[Index]);
          end;
          Require(Assigned(View) and Assigned(Body) and Assigned(Button),'Component layout controls missing');
          Require((Body.Top>=View.Top+View.Height) and (Body.Top+Body.Height<=Button.Top) and
            (Button.Top+Button.Height<=Form.ClientHeight),'Component table/status/details/buttons overlap at '+IntToStr(DPI));
          Require(View.Items[High(UPDATE_COMPONENTS)+1].DisplayRect(drBounds).Bottom<=View.ClientHeight,
            'Last component does not fit at '+IntToStr(DPI));
          SetMHLTheme(True); Application.ProcessMessages;
          Require((ColorToRGB(View.Color)=RGB(30,31,34)) and
            (ColorToRGB(View.Font.Color)=ColorToRGB(MHLThemeText)),'Dark component table has unreadable colors');
          SetMHLTheme(False); Application.ProcessMessages;
          Require(ColorToRGB(View.Color)=ColorToRGB(clWindow),'Light component table was not restored');
          Form.ScaleForPPI(DPI); Form.ClientWidth:=MulDiv(760,DPI,96); Form.ClientHeight:=MulDiv(560,DPI,96);
          var PreviewHeight:=Body.Height;
          View.OnDblClick(View); Application.ProcessMessages;
          Writeln('TRACE changes DPI=',DPI,' PPI=',Form.CurrentPPI,' preview=',PreviewHeight,
            ' reading=',Body.Height,' table=',View.Height,' selected=',Tabs.TabIndex,
            ' client=',Form.ClientHeight);
          Require((Tabs.TabIndex=1) and not View.Visible and HistorySelector.Visible and
            (Body.Height>=PreviewHeight+MulDiv(150,Form.CurrentPPI,96)) and
            (Body.Height>=MulDiv(280,Form.CurrentPPI,96)),
            'Changes tab does not reclaim enough reading space at '+IntToStr(DPI));
          Require(HistorySelector.ItemIndex=View.Selected.Index,'Changes tab lost the selected component');
          HistorySelector.ItemIndex:=6; HistorySelector.OnChange(HistorySelector);
          Require(View.Selected.Index=6,'Changes component selector and table disagree');
          SetMHLTheme(True); Application.ProcessMessages;
          Require(string(Body.PrimaryNotes.Text).Contains('DocSharp'),'Theme switch lost DOC changes on reading tab');
          SetMHLTheme(False); Application.ProcessMessages;
          TLabel(Form.FindComponent('UpdateBytes')).Caption:='Скачано: 1 / 2 МБ';
          Form.ClientHeight:=Form.ClientHeight+1; Application.ProcessMessages;
          var Progress: TProgressBar;
          Progress:=nil;
          for var ControlIndex:=0 to Form.ControlCount-1 do
            if Form.Controls[ControlIndex] is TProgressBar then Progress:=TProgressBar(Form.Controls[ControlIndex]);
          Require(Assigned(Progress) and Progress.Visible and (Body.Top+Body.Height<=Progress.Top),
            'Minimum-size details overlap download progress at '+IntToStr(DPI));
          Tabs.TabIndex:=0; Tabs.OnChange(Tabs); Application.ProcessMessages;
          Require(View.Visible and not HistorySelector.Visible and (Body.Top+Body.Height<=Progress.Top),
            'Returning to components overlaps progress or loses the view at '+IntToStr(DPI));

        finally Form.Free; end;
      end;
    finally SetMHLTheme(SavedDark); end;
    Writeln('PASS component table and dedicated changes tab remain separate at 96 144 192 DPI, minimum size and both themes');
  end;

  procedure CheckCycles;
  var Cycle: TfrmProgramUpdate; App, Current: TProgramRelease; Selector: TListView; Index: Integer; Primary: TButton;
  begin
    Cycle := CreateTestProgramUpdate;
    try
      Selector := nil;
      for Index := 0 to Cycle.ControlCount - 1 do
        if Cycle.Controls[Index] is TListView then Selector := TListView(Cycle.Controls[Index]);
      Current := Default(TProgramRelease); Current.Tag := PROGRAM_RELEASE_VERSION;
      CycleComponents := Default(TComponentReleases);
      Require(Cycle.StartCheckCycle(True), 'Automatic cycle did not start');
      Cycle.ApplicationChecked(Current, True, '');
      Require(not Cycle.Visible, 'Empty automatic cycle opened before component response');
      Cycle.ComponentsReceived(CycleComponents, True, '');
      Require(not Cycle.Visible, 'Automatic cycle without updates opened a window');
      Require(Cycle.StartCheckCycle(True), 'Second cycle did not start');
      Cycle.ComponentsReceived(CycleComponents, False, 'Component failure');
      Cycle.ApplicationChecked(Current, False, 'Application failure');
      Require(not Cycle.Visible, 'Automatic failed check opened a window');
      CycleComponents[0].ComponentID := 'SQLite'; CycleComponents[0].ComponentVersion := '100.0';
      CycleComponents[0].Tag := '100.0'; CycleComponents[0].DownloadURL := 'http://127.0.0.1/fixture.zip';
      CycleComponents[2] := CycleComponents[0]; CycleComponents[2].ComponentID := 'SumatraPDF';
      Require(Cycle.StartCheckCycle(True), 'Component cycle did not start');
      Cycle.ComponentsReceived(CycleComponents, True, '');
      Require(not Cycle.Visible, 'Component response opened before application check completed');
      Cycle.ApplicationChecked(Current, True, '');
      Require(Cycle.Visible and (Selector.Selected.Index = 1), 'Component-only update did not select SQLite');
      Require(StatusText(Cycle) = 'Есть обновления для SQLite и SumatraPDF', 'Two-component summary incorrect');
      Cycle.Hide;
      App := Current; App.Tag := '2.7.0_pre5.999'; App.DownloadURL := 'http://127.0.0.1/application.zip';
      // Metadata-only cycle fixture; this case never starts a download.
      App.SHA256 := StringOfChar('a',64); App.Size := 1024;
      Require(Cycle.StartCheckCycle(True), 'Combined cycle did not start');
      Cycle.ApplicationChecked(App, True, '');
      Require(not Cycle.Visible, 'Application response opened before component check completed');
      Cycle.ComponentsReceived(CycleComponents, True, '');
      Require(Cycle.Visible and (Selector.Selected.Index = 0), 'Application update did not select program');
      Require(StatusText(Cycle) = 'Есть обновления для HomeLib Ru, SQLite и SumatraPDF', 'Combined summary incorrect');
      Cycle.Hide;
      CycleComponents := Default(TComponentReleases);
      Require(Cycle.StartCheckCycle(False), 'Manual cycle disabled by Never');
      Cycle.ApplicationChecked(Current, False, 'Не удалось проверить обновления');
      Cycle.ComponentsReceived(CycleComponents, False, 'Не удалось проверить компоненты');
      Require(Cycle.Visible and StatusText(Cycle).Contains('Не удалось'), 'Manual failure was silent');
      Cycle.Hide;
      CycleComponents := Default(TComponentReleases);
      Require(ParseRasterComponent('/projects/djvu/files/DjVuLibre_Windows/3.5.99+4.12/',
        'DjVuLibre', CycleComponents[3]), 'Windows DjVu version fixture failed');
      Require(Cycle.StartCheckCycle(True), 'DjVu check cycle did not start');
      Cycle.ApplicationChecked(Current, True, ''); Cycle.ComponentsReceived(CycleComponents, True, '');
      Require(Cycle.Visible and (Selector.Selected.Index=4), 'DjVu-only update was not presented');
      Primary := nil;
      for Index := 0 to Cycle.ControlCount-1 do
        if (Cycle.Controls[Index] is TButton) and TButton(Cycle.Controls[Index]).Default then
          Primary := TButton(Cycle.Controls[Index]);
      Require(Assigned(Primary) and (Primary.Caption='Проверить у автора') and
        StatusText(Cycle).Contains('3.5.99'), 'Check-only component pretends it can install');
      Cycle.Hide;
      CycleComponents[0].ComponentID:='SQLite'; CycleComponents[0].ComponentVersion:='100.0';
      CycleComponents[0].Tag:='100.0'; CycleComponents[0].DownloadURL:='http://127.0.0.1/fixture.zip';
      Require(Cycle.StartCheckCycle(True), 'Mixed component cycle did not start');
      Cycle.ApplicationChecked(Current, True, ''); Cycle.ComponentsReceived(CycleComponents, True, '');
      Require(StatusText(Cycle)='Есть обновления для SQLite', 'Check-only component entered download summary');
      ChooseRow(Selector, 4);
      Require((Primary.Caption='Проверить у автора') and StatusText(Cycle).Contains('3.5.99'),
        'Batch summary overwrote check-only action');
      Cycle.Hide;
      CycleComponents:=Default(TComponentReleases);
      Require(ParseDocSharpVersions('{"versions":["0.99.0"]}','{"versions":["0.99.0"]}',CycleComponents[5]),
        'DOC available-version fixture failed');
      Require(Cycle.StartCheckCycle(True),'DOC-only check cycle failed');
      Cycle.ApplicationChecked(Current,True,''); Cycle.ComponentsReceived(CycleComponents,True,'');
      Require(Cycle.Visible and (Selector.Selected.Index=6) and (Primary.Caption='Скачать обновление') and
        (StatusText(Cycle)='Есть обновления для DocSharp'),'Official DOC pair does not offer automatic installation');
      Require(Selector.Items[6].SubItems[1]='0.99.0','DOC available version missing from table');
      Cycle.Hide;
      Require(Cycle.StartCheckCycle(False),'DOC failed refresh did not start');
      Cycle.ApplicationChecked(Current,True,''); Cycle.ComponentsReceived(CycleComponents,False,'Сеть недоступна');
      Require(Selector.Items[6].SubItems[2]='Не удалось проверить','Failed refresh claims DOC is current');
      Cycle.Hide;
      Require(CycleComponents[5].OfficialComponent and not CycleComponents[5].CheckOnly and
        IsOfficialComponentURL('DocSharp','0.99.0',CycleComponents[5].DownloadURL,ProgramUpdatePlatform,False) and
        IsOfficialComponentURL('DocSharp','0.99.0',CycleComponents[5].SecondaryURL,ProgramUpdatePlatform,True),
        'DOC metadata does not retain the matched direct NuGet pair');
      Require(not IsOfficialComponentURL('DocSharp','0.99.0',
        'https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.999/doc.zip',ProgramUpdatePlatform,False),
        'Own release asset was accepted as an official DOC package');
      Require(not IsOfficialComponentURL('DocSharp','0.99.0','https://other.example/doc.zip',ProgramUpdatePlatform,False),
        'Foreign DOC origin was accepted');
      Writeln('PASS official DOC pair offers direct automatic installation and rejects own or foreign package origins');
      Writeln('PASS an unconfirmed DjVu Windows archive is reported without entering the installation queue');
    finally Cycle.Free; end;
    Writeln('PASS automatic update cycle waits for both responses, stays quiet without updates and selects components');
    Writeln('PASS one-line update summaries combine all available components and manual failure remains visible');
  end;
begin
  if ParamStr(2).StartsWith('layout-') then
    Require(MatchText(ParamStr(2),['layout-96','layout-144','layout-192']),
      'Unknown update layout audit subcase');
  TestUpdateDefaults;
  CheckCycles;
  Configuration := TfrmSettings.Create(nil);
  try
    Require(Configuration.cbProgramInterval.Items[0] = 'Никогда', 'Never option missing');
    Configuration.cbProgramInterval.ItemIndex := 8; Configuration.ProgramIntervalChanged(nil);
    Require(Configuration.edProgramInterval.Visible and Configuration.cbProgramIntervalUnit.Visible,
      'Custom interval controls missing');
    Configuration.edProgramInterval.Text := '17'; Configuration.cbProgramIntervalUnit.ItemIndex := 1;
    Configuration.SaveSettingsClick(nil);
    Require(Settings.CheckUpdate and (Settings.ProgramUpdateMinutes = 1020), 'Custom hours not saved');
    Configuration.cbProgramInterval.ItemIndex := 0; Configuration.SaveSettingsClick(nil);
    Require(not Settings.CheckUpdate, 'Never does not disable checking');
    Settings.SaveSettings;
  finally Configuration.Free; end;
  Writeln('PASS update settings preserve never and custom hours');
  Popup := CreateTestProgramUpdate;
  try
    NotesView := nil; Notes := nil; Primary := nil; Version := nil; Bytes := nil; Selector := nil;
    for I := 0 to Popup.ControlCount - 1 do
    begin
      if Popup.Controls[I] is TUpdateNotesView then
      begin NotesView := TUpdateNotesView(Popup.Controls[I]); Notes := NotesView.PrimaryNotes; end;
      if Popup.Controls[I] is TListView then Selector := TListView(Popup.Controls[I]);
      if (Popup.Controls[I] is TButton) and TButton(Popup.Controls[I]).Default then Primary := TButton(Popup.Controls[I]);
      if (Popup.Controls[I] is TLabel) and (Pos('Текущая', TLabel(Popup.Controls[I]).Caption) = 1) then Version := TLabel(Popup.Controls[I]);
      if (Popup.Controls[I] is TLabel) and (Popup.Controls[I].Top > 400) then Bytes := TLabel(Popup.Controls[I]);
    end;
    Require(Assigned(Notes) and Assigned(Primary) and Assigned(Version) and Assigned(Bytes), 'Popup controls incomplete');
    Require(Pos(PROGRAM_RELEASE_VERSION, Version.Caption) > 0, 'Installed version missing');
    Require(Assigned(Selector) and (Selector.Items.Count=Length(UPDATE_COMPONENTS)+1), 'Registered component rows missing');
    Require((Selector.Columns.Count=4) and (Selector.Columns[1].Caption='Установлено') and
      (Selector.Columns[2].Caption='У автора'),'Installed/available component columns missing');
    for I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
      Require(Selector.Items[I+1].Caption.Contains(UPDATE_COMPONENTS[I].ID) and
        Selector.Items[I+1].Caption.Contains(UPDATE_COMPONENTS[I].Title),'Purpose or library name missing');
    Require(Selector.Items[6].SubItems[0]='0.21.0','Installed bundled DocSharp version missing');
    ChooseRow(Selector,6); var CopyKey: Word:=Ord('C');
    Selector.OnKeyDown(Selector,CopyKey,[ssCtrl]);
    Require((CopyKey=0) and CopiedText.Contains('Чтение DOC, PPT и XLS · DocSharp') and
      CopiedText.Contains('0.21.0'),'Component purpose/library/version cannot be copied');
    Selector.PopupMenu.Items[1].Click;
    Require(CopiedText.StartsWith('Компонент'+#9) and CopiedText.Contains('HomeLib Ru') and
      CopiedText.Contains('DocSharp'),'Entire component list cannot be copied');

    Require(ParseDocSharpVersions('{"versions":["0.9.0","0.21.0","0.22.0-preview","0.100.0","0.99.0"]}',
      '{"versions":["0.99.0","0.21.0","0.9.0"]}',Parsed) and (Parsed.ComponentVersion='0.99.0') and
      not Parsed.CheckOnly and Parsed.OfficialComponent and (Parsed.SecondaryURL<>''),'DOC update check must ignore previews and incomplete assembly pairs and offer the official pair');
    Require(not ParseDocSharpVersions('<html>error</html>','{"versions":["0.21.0"]}',Parsed),'Invalid DOC feed accepted');
    Require(not ParseDocSharpVersions('{"versions":["0.22.0-beta"]}','{"versions":["0.22.0-beta"]}',Parsed),
      'DOC preview-only feed accepted');
    var FeedRoot:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'COMPONENTS.json',TEncoding.UTF8));
    try
      var FeedRows:=TJSONObject(FeedRoot).GetValue<TJSONArray>('components');
      var Future:=TJSONObject.Create; Future.AddPair('id','FutureReader'); Future.AddPair('platform',ProgramUpdatePlatform);
      Future.AddPair('version','1.0'); var History:=TJSONArray.Create;
      var Entry:=TJSONObject.Create; Entry.AddPair('version','1.0'); Entry.AddPair('notes','Future component');
      History.AddElement(Entry); Future.AddPair('history',History); FeedRows.AddElement(Future);
      var FeedResult: TComponentReleases;
      Require(ParseComponentFeed(FeedRoot.ToJSON,PROGRAM_RELEASE_VERSION,'[]',FeedResult,False) and
        (FeedResult[5].ComponentVersion='0.21.0'),'More than five components or a future ID invalidates known metadata');
    finally FeedRoot.Free; end;
    Writeln('PASS scalable component table keeps purpose, library name, installed and available versions; DocSharp checks stable pairs');
    ChooseRow(Selector, 1);
    Require((Pos('3.54.1', NotesView.SectionHeader(0).Caption) > 0) and
      ContainsText(Notes.Text,'исправлены'), 'Installed component changelog missing');
    Require(Primary.Caption = 'Проверить всё', 'Component check missing');
    ChooseRow(Selector, 0);
    ReleaseInfo := Default(TProgramRelease); ReleaseInfo.Tag := '2.7.0_pre5.12';
    // GitHub and bundled Markdown may use Unix line breaks; the Windows memo
    // must retain separate heading and bullet lines when displaying them.
    ReleaseInfo.Changelog := '2.7.0_pre5.12' + #10 + 'Новые изменения' + #10#10 + '- Первый пункт';
    ReleaseInfo.History := ReleaseInfo.Changelog + sLineBreak + PROGRAM_RELEASE_VERSION;
    ReleaseInfo.DownloadURL := 'https://github.com/Dicur3x/MyHomeLib/releases/download/2.7.0_pre5.12/HomeLibRu.zip';
    Popup.SetRelease(ReleaseInfo);
    Require(Primary.Enabled and (Primary.Caption = 'Скачать обновление'), 'New release download button missing');
    Require(Pos('Новые изменения', Notes.Text) > 0, 'Changelog missing');
    Require((Notes.Lines.Count >= 3) and (Pos('2.7.0_pre5.12', NotesView.SectionHeader(0).Caption) > 0) and
      (Notes.Lines[0] = 'Новые изменения') and (Pos('Первый пункт', Notes.Lines[2]) > 0),
      'Unix changelog line breaks collapsed in Windows memo');
    Require((NotesView.SectionCount = 2) and not NotesView.IsExpanded(1) and
      (Pos(PROGRAM_RELEASE_VERSION, NotesView.SectionHeader(1).Caption) > 0),
      'New update hides installed-version history');
    ReleaseInfo.History := '';
    ReleaseInfo.Changelog := '2.7.0_pre5.12' + #10 + '## Исправления' + #10 +
      '- **Переходы** по ссылкам' + #10 + '  - Дочерний пункт' + #10#10 +
      '2.7.0_pre5.11' + #10 + 'Текст {\rtf1} и кириллица ← ↔';
    Popup.SetRelease(ReleaseInfo);
    Require((fsBold in NotesView.SectionHeader(0).Font.Style) and
      (NotesView.SectionHeader(0).Font.Size > Notes.Font.Size),
      'Release heading is not emphasized');
    Notes.SelStart := Pos('Исправления', Notes.Text) - 1; Notes.SelLength := Length('Исправления');
    Require(fsBold in Notes.SelAttributes.Style, 'Markdown section heading is not bold');
    Notes.SelStart := Pos('Дочерний пункт', Notes.Text) - 1; Notes.SelLength := 1;
    Require(Notes.Paragraph.LeftIndent > 0, 'Nested list lost its indentation');
    Require((Pos('**', Notes.Text) = 0) and (Pos('{\rtf1}', NotesView.SectionNotes(1).Text) > 0) and
      (Pos('кириллица ← ↔', NotesView.SectionNotes(1).Text) > 0), 'Markdown or Unicode/RTF escaping is broken');
    Require((NotesView.SectionCount = 2) and
      (Pos('2.7.0_pre5.11', NotesView.SectionHeader(1).Caption) > 0), 'Second release was lost');
    Require(NotesView.IsExpanded(0) and not NotesView.IsExpanded(1) and
      not NotesView.SectionNotes(1).Visible, 'Previous changelog is not collapsed initially');
    NotesView.SectionHeader(1).OnClick(NotesView.SectionHeader(1));
    Require(NotesView.IsExpanded(0) and NotesView.IsExpanded(1) and
      NotesView.SectionNotes(1).Visible, 'Previous changelog cannot be expanded independently');
    NotesView.SectionHeader(1).OnClick(NotesView.SectionHeader(1));
    Require(not NotesView.IsExpanded(1), 'Previous changelog cannot be collapsed again');
    Writeln('PASS previous changelogs start collapsed and can be expanded independently');
    ReleaseInfo.Changelog := SQLiteNotesToMarkdown('<ol><li>Fix the bug.' + #10 +
      '<li>New SQL language features:<ol><li>Nested   item' + #10 +
      ' continuation &amp; &harr;</ol></ol><p><b>Hashes:</b><ol><li>SHA3: abc</ol>');
    Require((Pos('  - Nested item continuation & ↔', ReleaseInfo.Changelog) > 0) and
      (Pos('## Hashes:', ReleaseInfo.Changelog) > 0), 'SQLite HTML hierarchy or whitespace lost');
    Popup.SetRelease(ReleaseInfo);
    Notes.SelStart := Pos('New SQL language features:', Notes.Text) - 1;
    Notes.SelLength := Length('New SQL language features:');
    Require(fsBold in Notes.SelAttributes.Style, 'SQLite subsection is not emphasized');
    Writeln('PASS update notes retain nested SQLite lists, headings and safe Unicode text');
    Require(ReleaseNotesHeading('3.53.0', '2026-04-09T00:00:00Z') =
      '3.53.0 — 09.04.2026', 'Release date missing');
    Require((ReleaseNotesHeading('3.53.0', '') = '3.53.0') and
      (ReleaseNotesHeading('3.53.0', '2026-02-30') = '3.53.0'), 'Unknown or invalid date was invented');
    Require(ParseProgramReleases('[{"tag_name":"2.7.0_pre9.99","draft":false,' +
      '"published_at":"2026-10-07T12:00:00Z","body":"## Изменения\n- Первый пункт",' +
      '"assets":[{"name":"HomeLibRu.zip"}]}]', Parsed), 'Application date fixture failed');
    Require((Pos('2.7.0_pre9.99 — 07.10.2026', Parsed.Changelog) > 0) and
      (Pos('2.7.0_pre9.99 — 07.10.2026', Parsed.History) > 0), 'Application history omitted its date');
{$IFDEF WIN64}
    SQLiteArch := 'x64';
{$ELSE}
    SQLiteArch := 'x86';
{$ENDIF}
    Require(ParseSQLiteDownload('PRODUCT,3.53.0,2026/sqlite-dll-win-' + SQLiteArch +
      '-3530000.zip,2000000,' + StringOfChar('a', 64),
      '<h3>2026-04-09 (3.53.0)</h3><ol><li>New SQL language features:' +
      '<ol><li>Nested feature</ol></ol><h3>2026-03-06 (3.52.0)</h3><ol><li>Old feature</ol>', Parsed),
      'SQLite dated changelog fixture failed');
    Require((Pos('3.53.0 — 09.04.2026', ComponentChanges(Parsed, '3.52.0')) > 0) and
      (Pos('Old feature', ComponentChanges(Parsed, '3.52.0')) = 0), 'SQLite missed releases or dates are wrong');
    Require(ParseSumatraReleases('[{"tag_name":"3.6.1rel","published_at":"2026-01-15T12:00:00Z",' +
      '"body":"## Bugfixes\n- First fix\n  - Nested detail"}]', Parsed), 'Sumatra dated changelog fixture failed');
    Require(Pos('3.6.1 — 15.01.2026', ComponentChanges(Parsed, '3.6.0')) > 0,
      'Sumatra changelog omitted its date');
    for ComponentID in ComponentIDs do
    begin
      ReleaseInfo.ComponentID := ComponentID; ReleaseInfo.ComponentVersion := '3.53.0';
      ReleaseInfo.PublishedAt := '2026-04-09';
      ReleaseInfo.Changelog := ReleaseNotesHeading('3.53.0', ReleaseInfo.PublishedAt) + #10 +
        '## Изменения' + #10 + '- **Исправление**' + #10 + '  - Дочерний пункт' + #10#10 +
        ReleaseNotesHeading('3.52.0', '2026-03-06') + #10 + '- Прежний выпуск';
      Popup.SetRelease(ReleaseInfo);
      Require((Pos('3.53.0 — 09.04.2026', NotesView.SectionHeader(0).Caption) > 0) and
        (fsBold in NotesView.SectionHeader(0).Font.Style) and
        (NotesView.SectionHeader(0).Font.Size > Notes.Font.Size),
        ComponentID + ' dated heading is not emphasized');
      Notes.SelStart := Pos('Дочерний пункт', Notes.Text) - 1; Notes.SelLength := 1;
      Require(Notes.Paragraph.LeftIndent > 0, ComponentID + ' nested list is flat');
    end;
    ReleaseInfo.ComponentID := ''; ReleaseInfo.PublishedAt := '';
    Writeln('PASS dates and shared formatting cover application and every component');

    ReleaseInfo.History := '2.7.0_pre5.12' + sLineBreak;
    for I := 1 to 100 do ReleaseInfo.History := ReleaseInfo.History +
      '- Строка ' + IntToStr(I) + ' длинного журнала изменений' + sLineBreak;
    ReleaseInfo.History := ReleaseInfo.History + '2.7.0_pre5.11' + sLineBreak + '- Старый выпуск';
    Popup.SetRelease(ReleaseInfo);
    Require((Popup.BorderStyle = bsSizeable) and (biMaximize in Popup.BorderIcons), 'Update window cannot resize/maximize');
    HeightBefore := NotesView.Height; Popup.ClientHeight := Popup.ClientHeight + 80;
    Require((NotesView.Height > HeightBefore + 60) and (NotesView.Height > Popup.ClientHeight div 2),
      'Reading area does not use the available window space');
    Require(Notes.ScrollBars = ssNone, 'Individual release traps scrolling');
    Require(Notes.Height > NotesView.ClientHeight, 'Long release text is clipped instead of fully laid out');
    Notes.Perform(WM_MOUSEWHEEL, WPARAM($FF880000), 0);
    Require(NotesView.VertScrollBar.Position > 0, 'Wheel over text cannot scroll across release history');
    NotesView.SetExpanded(1, True); PreviousEditor := NotesView.SectionNotes(1);
    PreviousEditor.Perform(WM_MOUSEWHEEL, WPARAM($00780000), 0);
    Require(NotesView.VertScrollBar.Position = 0, 'Wheel over a previous release does not reach the common scrollbar');
    BodyBefore := Notes.Height;
    Notes.Perform(WM_MOUSEWHEEL, WPARAM($00780008), 0);
    Require((NotesView.ZoomPercent = 110) and (Notes.Height > BodyBefore), 'Ctrl-wheel does not enlarge/reflow text');
    NotesView.Load(ReleaseInfo.History);
    Require((NotesView.SectionNotes(1) = PreviousEditor) and NotesView.IsExpanded(1),
      'Unchanged history is recreated, losing expansion and causing flicker');
    NotesView.ZoomPercent := 100;
    Writeln('PASS update window expands reading space, reflows zoom and scrolls continuously across releases');

    Popup.Show; Application.ProcessMessages;
    NotesView.VertScrollBar.Position := 1000;
    NotesView.SetExpanded(1, False); NotesView.SetExpanded(1, True);
    Require(NotesView.SectionNotes(1).Height < MulDiv(70, Notes.CurrentPPI, 96),
      'Scrolled short release has blank height: ' + IntToStr(NotesView.SectionNotes(1).Height));
    // Short releases must shrink after a long document and remain compact
    // across repeated layout, expansion and zoom changes.
    NotesView.Load('3.51.1 — 28.11.2025' + sLineBreak +
      '- First fix' + sLineBreak + '- Second fix' + sLineBreak +
      '## Hashes:' + sLineBreak + '- SQLITE_SOURCE_ID: abc' + sLineBreak +
      '- SHA3: def' + sLineBreak + '3.51.0 — 04.11.2025' + sLineBreak +
      '- Another short release');
    Require(Notes.Height < MulDiv(180, Notes.CurrentPPI, 96),
      'Short release retains blank height from previous long text: ' + IntToStr(Notes.Height));
    BodyBefore := Notes.Height;
    for I := 1 to 20 do
    begin
      Popup.ClientHeight := Popup.ClientHeight + 8;
      Popup.ClientHeight := Popup.ClientHeight - 8;
      NotesView.SetExpanded(1, True); NotesView.SetExpanded(1, False);
    end;
    Require(Abs(Notes.Height - BodyBefore) <= 1,
      'Repeated layout accumulates blank space: ' + IntToStr(BodyBefore) + ' -> ' + IntToStr(Notes.Height));
    NotesView.SetExpanded(1, True);
    Require(NotesView.SectionNotes(1).Height < MulDiv(70, Notes.CurrentPPI, 96),
      'Previous short release has excessive blank space');
    NotesView.ZoomPercent := 200; NotesView.ZoomPercent := 80; NotesView.ZoomPercent := 100;
    Require(Abs(Notes.Height - BodyBefore) <= 1, 'Zoom down does not shrink the document');
    Popup.ClientWidth := Popup.ClientWidth - 180; Popup.ClientWidth := Popup.ClientWidth + 180;
    Require(Abs(Notes.Height - BodyBefore) <= 1, 'Width reflow retains blank space');
    NotesView.Load('3.51.1 — 28.11.2025' + sLineBreak + '- Short release' + sLineBreak +
      '3.51.0 — 04.11.2025' + sLineBreak + Copy(ReleaseInfo.History,
      Pos(sLineBreak, ReleaseInfo.History) + Length(sLineBreak), MaxInt));
    NotesView.SetExpanded(1, True); PreviousEditor := NotesView.SectionNotes(1);
    Application.ProcessMessages;
    EndPoint := Point(0, 0);
    PreviousEditor.Perform(WM_USER + 38, WPARAM(@EndPoint), PreviousEditor.GetTextLen - 1);
    Writeln('TRACE expanded old release height ', PreviousEditor.Height, ' last line ', EndPoint.Y);
    Require((EndPoint.Y > 0) and (PreviousEditor.Height - EndPoint.Y < MulDiv(60, Notes.CurrentPPI, 96)),
      'Expanded previous release has blank space after its last line');
    Writeln('PASS expanded old release ends directly after its text');
    Writeln('PASS short release height stays compact after long text, resize, expansion and zoom');
    Popup.Hide;
    NotesView.Load(ReleaseInfo.History);

    Cache := ProgramUpdateCache(Settings.AppPath);
    Previous := Default(TComponentReleases);
    Previous[0].History := '3.53.4' + sLineBreak + '- Сохранённое описание SQLite';
    Previous[2].History := '3.6.1' + sLineBreak + '- Сохранённое описание SumatraPDF';
    Failed := Default(TComponentReleases); Failed[0].ComponentError := 'Проверка не удалась';
    PreserveComponentHistory(Failed, Previous);
    Require((Failed[0].History = Previous[0].History) and (Failed[0].DownloadURL = '') and
      (Failed[0].ComponentError <> ''), 'Failed check erases history or revives stale download metadata');
    SaveComponentHistory(Cache, Failed);
    Failed := Default(TComponentReleases); LoadComponentHistory(Cache, Failed);
    Require(Failed[2].History = Previous[2].History, 'Saved component history not reloaded');
    Popup.RememberHistory(ReleaseInfo);
    Reloaded := CreateTestProgramUpdate;
    try
      ReloadedView := nil; ReloadedSelector := nil;
      for I := 0 to Reloaded.ControlCount - 1 do
      begin
        if Reloaded.Controls[I] is TUpdateNotesView then ReloadedView := TUpdateNotesView(Reloaded.Controls[I]);
        if Reloaded.Controls[I] is TListView then ReloadedSelector := TListView(Reloaded.Controls[I]);
      end;
      Require(Pos('длинного журнала', ReloadedView.PrimaryNotes.Text) > 0, 'Application history missing before network check');
      ChooseRow(ReloadedSelector, 3);
      Require(Pos('Сохранённое описание SumatraPDF', ReloadedView.PrimaryNotes.Text) > 0,
        'Cached component history missing before network check');
      Reloaded.CheckFailed('Сеть недоступна');
      Require(Pos('Сохранённое описание', ReloadedView.PrimaryNotes.Text) > 0, 'Manual failure clears cached text');
      Reloaded.ClientWidth := MulDiv(1000, Reloaded.CurrentPPI, 96);
      Reloaded.ClientHeight := MulDiv(760, Reloaded.CurrentPPI, 96);
      ReloadedView.ZoomPercent := 140;
      TTabControl(Reloaded.FindComponent('UpdateTabs')).TabIndex:=1;
      SavedWidth := MulDiv(Reloaded.ClientWidth, 96, Reloaded.CurrentPPI);
      SavedHeight := MulDiv(Reloaded.ClientHeight, 96, Reloaded.CurrentPPI);
    finally Reloaded.Free; end;
    Reloaded := CreateTestProgramUpdate;
    try
      ReloadedView := nil;
      for I := 0 to Reloaded.ControlCount - 1 do
        if Reloaded.Controls[I] is TUpdateNotesView then ReloadedView := TUpdateNotesView(Reloaded.Controls[I]);
      Require((Abs(MulDiv(Reloaded.ClientWidth, 96, Reloaded.CurrentPPI) - SavedWidth) <= 1) and
        (Abs(MulDiv(Reloaded.ClientHeight, 96, Reloaded.CurrentPPI) - SavedHeight) <= 1),
        'Resized update window was not restored from disk');
      Require(Assigned(ReloadedView) and (ReloadedView.ZoomPercent = 140), 'Text zoom was not restored from disk');
      Require(TTabControl(Reloaded.FindComponent('UpdateTabs')).TabIndex=1,'Reading tab was not restored from disk');
    finally Reloaded.Free; end;
    Writeln('PASS resized update window and text zoom survive reopening from disk');
    Require(ParseProgramReleases('[{"tag_name":"2.7.0_pre5.11","draft":false,"body":"",' +
      '"assets":[{"name":"HomeLibRu.zip"}]}]', Parsed) and
      (Pos('Автор не опубликовал', Parsed.History) > 0), 'Empty author release mistaken for unloaded history');
    Writeln('PASS saved histories survive reopening and network failure; empty author notes are explained');
    Require(Bytes.Caption = '', 'No download must happen before the click');
    Popup.BeginCheck; Popup.SetCurrent(ReleaseInfo);
    Require(Primary.Enabled and (Primary.Caption = 'Проверить ещё раз'), 'No-update check is not retryable');
    Popup.CheckFailed('Не удалось проверить');
    Require(Primary.Enabled and (Primary.Caption = 'Повторить проверку'), 'Manual failure is not retryable');
    // Optional local preview for Computer Use, only inside the guarded fixture runtime.
    if FileExists(Settings.AppPath + 'notes-preview.html') then
    begin
      ReleaseInfo.History := '';
      ReleaseInfo.Changelog := ReleaseNotesHeading('3.53.0', '2026-04-09') + sLineBreak + SQLiteNotesToMarkdown(
        TFile.ReadAllText(Settings.AppPath + 'notes-preview.html', TEncoding.UTF8)) +
        sLineBreak + sLineBreak + ReleaseNotesHeading('3.52.0', '2026-03-06') + sLineBreak + '## Предыдущий выпуск' +
        sLineBreak + '- Пример отдельного выпуска';
      if FileExists(Settings.AppPath + 'notes-preview-history.txt') then
        ReleaseInfo.Changelog := TFile.ReadAllText(Settings.AppPath + 'notes-preview-history.txt', TEncoding.UTF8);
      Popup.SetRelease(ReleaseInfo); Popup.Hide; Popup.ShowModal;
    end;
    CheckTableLayout;
    Writeln('PASS update popup shows installed version and changelog without automatic download');
    // Interactive preview may change theme, selection or close the main form.
    // Run every assertion first so human inspection cannot alter its fixture.
    if ParamStr(2)='visual' then
    begin
      SetMHLTheme(True); ChooseRow(Selector,0);
      Popup.ClientWidth:=960; Popup.ClientHeight:=760; NotesView.ZoomPercent:=100;
      Popup.Show; Application.Run;
    end;
  finally Popup.Free; end;
end;

procedure TestProgramUpdateDownload;
var Popup, OwnedPopup: TfrmProgramUpdate; Info: TProgramRelease;
  Primary, Later: TButton; Notes: TRichEdit; Bytes: TLabel; Bar: TProgressBar;
  I, ComponentIndex: Integer; Deadline: UInt64; ReadyFile, Scenario, Descriptor: string;
  Releases: TComponentReleases; Root: TJSONValue; Item: TJSONObject;
  procedure Controls;
  var J: Integer;
  begin
    Primary := nil; Later := nil; Notes := nil; Bytes := nil; Bar := nil;
    for J := 0 to Popup.ControlCount - 1 do
    begin
      if Popup.Controls[J] is TUpdateNotesView then Notes := TUpdateNotesView(Popup.Controls[J]).PrimaryNotes;
      if Popup.Controls[J] is TProgressBar then Bar := TProgressBar(Popup.Controls[J]);
      if (Popup.Controls[J] is TLabel) and (Popup.Controls[J].Top > 400) then Bytes := TLabel(Popup.Controls[J]);
      if Popup.Controls[J] is TButton then
      begin
        if TButton(Popup.Controls[J]).Default then Primary := TButton(Popup.Controls[J]);
        if TButton(Popup.Controls[J]).Caption = 'Позже' then Later := TButton(Popup.Controls[J]);
      end;
    end;
    Require(Assigned(Primary) and Assigned(Later) and Assigned(Notes) and Assigned(Bytes) and Assigned(Bar), 'Update controls missing');
  end;
begin
  Require((ParamCount = 4) or (ParamCount = 6), 'Update test requires loopback URL, size and checksum');
  Require(ParamStr(2).StartsWith('http://127.0.0.1:'), 'Update test must use loopback');
  Scenario := ParamStr(6); Releases := Default(TComponentReleases);
  if ParamCount=6 then
  begin
    Descriptor := TPath.GetFullPath(ParamStr(5));
    Require(Descriptor.StartsWith(Settings.AppPath,True), 'Component fixture outside isolated runtime');
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(Descriptor,TEncoding.UTF8));
    try
      Require((Root is TJSONArray) and (TJSONArray(Root).Count>=1) and
        (TJSONArray(Root).Count<=Length(UPDATE_COMPONENTS)),'Component fixture malformed');
      for I := 0 to TJSONArray(Root).Count-1 do
      begin
        Require(TJSONArray(Root).Items[I] is TJSONObject,'Invalid component fixture');
        Item := TJSONObject(TJSONArray(Root).Items[I]);
        ComponentIndex:=0;
        while (ComponentIndex<Length(UPDATE_COMPONENTS)) and
          (UPDATE_COMPONENTS[ComponentIndex].ID<>Item.GetValue<string>('id')) do Inc(ComponentIndex);
        Require(ComponentIndex<Length(UPDATE_COMPONENTS),'Unknown component fixture');
        Require(Releases[ComponentIndex].ComponentID='','Repeated component fixture');
        Releases[ComponentIndex].Tag := '2.7.0_pre5.99';
        Item.TryGetValue<string>('release',Releases[ComponentIndex].Tag);
        Releases[ComponentIndex].ComponentID := Item.GetValue<string>('id');
        Releases[ComponentIndex].ComponentVersion := '9.0.0.0';
        Item.TryGetValue<string>('version',Releases[ComponentIndex].ComponentVersion);
        Releases[ComponentIndex].DownloadURL := Item.GetValue<string>('url');
        Releases[ComponentIndex].SHA256 := Item.GetValue<string>('sha256');
        Releases[ComponentIndex].Size := Item.GetValue<Int64>('size');
        Releases[ComponentIndex].Changelog := 'Новые изменения тестового компонента';
        Releases[ComponentIndex].History := Releases[ComponentIndex].ComponentVersion +
          sLineBreak + Releases[ComponentIndex].Changelog;
        Releases[ComponentIndex].Notes := '[{"version":"'+Releases[ComponentIndex].ComponentVersion+
          '","notes":"Новые изменения тестового компонента"}]';
        Require(Releases[ComponentIndex].DownloadURL.StartsWith('http://127.0.0.1:'),'External component fixture URL');
      end;
    finally Root.Free; end;
  end;
  Popup := CreateTestProgramUpdate;
  try
    Controls;
    Info := Default(TProgramRelease); Info.Tag := '2.7.0_pre5.99';
    if ParamCount=6 then
      for ComponentIndex:=Low(Releases) to High(Releases) do
        if Releases[ComponentIndex].Tag<>'' then begin Info.Tag:=Releases[ComponentIndex].Tag; Break; end;
    Info.DownloadURL := ParamStr(2); Info.Size := StrToInt64(ParamStr(3)); Info.SHA256 := ParamStr(4);
    Info.Changelog := 'Новые изменения тестового выпуска';
    if Scenario='components' then
    begin
      Require(Popup.StartCheckCycle(False),'Component cycle did not start');
      Popup.ComponentsReceived(Releases,True,''); Info.Tag := PROGRAM_RELEASE_VERSION;
      Popup.ApplicationChecked(Info,True,'');
    end
    else
    begin
      Popup.SetRelease(Info);
      if ParamCount=6 then Popup.ComponentsReceived(Releases,True,'');
    end;
    Require(Bytes.Caption = '', 'Unexpected automatic download');
    Primary.Click;
    Require(not Primary.Enabled and (Later.Caption = 'Отменить'), 'Download did not enter cancellable state');
    CheckUpdateComponentTable(Popup,'downloading');
    Deadline := GetTickCount64 + 30000;
    repeat Application.ProcessMessages; Sleep(10);
    until Primary.Enabled or (GetTickCount64 > Deadline);
    if Scenario='failure' then
    begin
      Require(Primary.Caption='Повторить загрузку','Component failure offered partial installation');
      ReadyFile := IncludeTrailingPathDelimiter(ProgramUpdateCache(Settings.AppPath)) + 'ready.json';
      Require(not FileExists(ReadyFile),'Component failure saved partial ready update');
      Require(Length(TDirectory.GetDirectories(ProgramUpdateCache(Settings.AppPath),'HomeLibRu-update-*'))=0,
        'Component failure retained staged jobs');
      Writeln('PASS failed component download removes all stages and prevents partial installation'); Exit;
    end;
    Require(Primary.Caption = 'Установить и перезапустить', 'Download failed: ' + Popup.Caption + ' / ' + Primary.Caption);
    CheckUpdateComponentTable(Popup,'downloaded-ready');
    Require((Bar.Position = 100) and (Pos('Скачано:', Bytes.Caption) = 1) and (Pos(' / ', Bytes.Caption) > 0), 'Download size or progress missing');
    Require(Pos('Новые изменения', Notes.Text) > 0, 'Download discarded changelog');
    Later.Click; Require(not Popup.Visible, 'Later did not hide ready update');
  finally Popup.Free; end;
  Writeln('PASS update popup downloads only on click, displays bytes, retains changelog and postpones installation');
  OwnedPopup := nil;
  for I := 0 to frmMain.ComponentCount - 1 do
    if frmMain.Components[I] is TfrmProgramUpdate then OwnedPopup := TfrmProgramUpdate(frmMain.Components[I]);
  Require(Assigned(OwnedPopup), 'Main form update popup missing');
  Popup := OwnedPopup;
  Require(Popup.RestoreReady, 'Ready update did not survive reopening'); Controls;
  Require(Primary.Caption = 'Установить и перезапустить', 'Restored update cannot install');
  CheckUpdateComponentTable(Popup,'reopened-ready');
  ReadyFile := IncludeTrailingPathDelimiter(ProgramUpdateCache(Settings.AppPath)) + 'ready.json';
  Require(FileExists(ReadyFile), 'Ready download was lost');
  if Scenario='components' then
  begin Writeln('PASS component batch download restores one ready installation without replacing application'); Exit; end;
  Primary.Click;
  Writeln('PASS ready update restores and real main close launches native replacement and restart');
end;

procedure TestHeaderMenuTags;
const
  Expected: array[0..12] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE, COL_COLLECTION,
    COL_LANG, COL_LIBRATE, COL_LIBID);
var
  I: Integer;
  ColumnHandler: TMethod;
begin
  Require(frmMain.pmHeaders.Items.Count = Length(Expected) + 12,
    'Wrong header menu structure');
  ColumnHandler := TMethod(frmMain.pmHeaders.Items[0].OnClick);
  for I := Low(Expected) to High(Expected) do
  begin
    Require(frmMain.pmHeaders.Items[I].Tag = Expected[I],
      'Header column identity changed at index ' + IntToStr(I));
    Require(TMethod(frmMain.pmHeaders.Items[I].OnClick).Code = ColumnHandler.Code,
      'A column lost its header action');
  end;
  Require((frmMain.pmHeaders.Items[13] = frmMain.N25) and
    (frmMain.N25.Caption = '-') and (frmMain.N25.Tag = 0) and
    not Assigned(frmMain.N25.OnClick),
    'Header separator must never be treated as a column');
  Require((frmMain.pmHeaders.Items[14] = frmMain.N27) and
    (frmMain.N27.Tag = 0) and Assigned(frmMain.N27.OnClick) and
    (TMethod(frmMain.N27.OnClick).Code <> ColumnHandler.Code),
    'Default header action must never be treated as a column');
  var PublisherColumn := frmMain.FindComponent('miColumnPublisher') as TMenuItem;
  Require(Assigned(PublisherColumn) and (PublisherColumn.Tag = COL_PUBLISHER) and
    (PublisherColumn.Caption = 'Издательство') and
    (TMethod(PublisherColumn.OnClick).Code = ColumnHandler.Code),
    'Publisher column lost its distinct identity or header action');
  Writeln('PASS header menu keeps column IDs separate from separator and default action');
end;

procedure Trace(const Stage: string);
begin
  Writeln('TRACE ', Stage);
  Flush(Output);
end;

procedure HandleReaderProbe;
var
  Root, FileName: string;
begin
  if (ParamCount <> 1) or not SameText(ExtractFileExt(ParamStr(1)), '.fb2') then Exit;
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ExtractFilePath(ParamStr(0))));
  FileName := ExpandFileName(ParamStr(1));
  Require(SameText(Copy(FileName, 1, Length(Root)), Root) and FileExists(FileName),
    'Reader probe must remain inside its isolated runtime');
  TFile.WriteAllText(Root + 'reader-probe-path.txt.tmp', FileName, TEncoding.UTF8);
  TFile.Move(Root + 'reader-probe-path.txt.tmp', Root + 'reader-probe-path.txt');
  Halt(0);
end;

type
  TBuiltinReadDriver = class
    Timer: TTimer;
    Started: UInt64;
    Finished: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TBuiltinReadDriver.Tick(Sender: TObject);
var I: Integer; Reader: TfrmBuiltinReader;
begin
  Require(GetTickCount64-Started<10000,'Main built-in reader did not finish loading');
  for I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I] is TfrmBuiltinReader then
    begin
      Reader:=TfrmBuiltinReader(Screen.Forms[I]);
      if not Reader.Ready then Exit;
      Timer.Enabled:=False;
      Require(Pos('Исходный текст встроенной читалки',Reader.BookText)>0,'Main reader loaded wrong book');
      Require(Reader.PictureCount=1,'Main modal reader lost its illustration at first show');
      Reader.SetBounds(70,80,640,440); Reader.SetTypography('Georgia',110,32);
      Require(Reader.PictureCount=1,'Main modal reader resize lost its illustration');
      Reader.NextPage; Require(Reader.TextPosition>0,'Main reader did not turn a page');
      Reader.AddBookmark; Reader.Close; Finished:=True; Exit;
    end;
end;

type
  TFailedBuiltinReadDriver = class(TBuiltinReadDriver)
    CancelDuringLoad, ObservedFailure, ObservedCancellation, WarmUI: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TFailedBuiltinReadDriver.Tick(Sender: TObject);
begin
  Require(GetTickCount64-Started<10000,'Failed modal reader did not return');
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I] is TfrmBuiltinReader then
    begin
      var Reader:=TfrmBuiltinReader(Screen.Forms[I]);
      // A timer can run while the modal form is still being constructed.
      // Exercise an actual visible modal window, as a user closing it would.
      if not Reader.HandleAllocated or not Reader.Visible or
        not IsWindowVisible(Reader.Handle) or (Application.ModalLevel=0) then Exit;
      if not CancelDuringLoad and not Reader.LoadFinished then Exit;
      if WarmUI then
      begin
        // Both reported cold paths must paint before the baseline is sampled.
        // Synchronous paint does not deliver the loader's queued completion.
        Require(RedrawWindow(Reader.Handle,nil,0,RDW_INVALIDATE or RDW_UPDATENOW or
          RDW_ALLCHILDREN or RDW_FRAME),'Cold modal reader did not paint');
        WarmUI:=False;
      end;
      if CancelDuringLoad then
      begin
        Require(not Reader.LoadFinished,'Cancellation test missed the active loader');
        ObservedCancellation:=True;
      end;
      if not CancelDuringLoad then
      begin
        Require(not Reader.Ready,'Malformed FB2 opened successfully');
        ObservedFailure:=True;
      end;
      Timer.Enabled:=False; Reader.Close; Finished:=True; Exit;
    end;
end;

{$I ReaderFailureCleanupTests.inc}

procedure TestFailedBuiltinReaderOwner;
var Source, Hash: string; Driver: TFailedBuiltinReadDriver; WasVisible: Boolean; BeforeGDI, BeforeUSER: Cardinal;
  BaseControls, BaseWindows, Controls, Windows: TStringList;
  ColdGDI, ColdUSER: Cardinal; FormsBaseline, ColdControlCount, ColdWindowCount: Integer;

  function NativeClass(Window: HWND): string;
  var Buffer: array[0..255] of Char; Count: Integer;
  begin
    Count := GetClassName(Window, Buffer, Length(Buffer));
    SetString(Result, PChar(@Buffer[0]), Count);
  end;

  procedure CaptureMainControls(Owner: TComponent; const Path: string; Snapshot: TStrings);
  var Control: TWinControl; Name, Description: string;
  begin
    if Owner is TWinControl then
    begin
      Control := TWinControl(Owner);
      // Reading Handle only after HandleAllocated must not warm the UI under test.
      if Control.HandleAllocated then
      begin
        Description := Path + ' vcl=' + Control.ClassName + ' native=' + NativeClass(Control.Handle) +
          ' hwnd=' + IntToHex(NativeUInt(Control.Handle), 16) + ' visible=' + IntToStr(Ord(Control.Visible));
        Snapshot.Add(IntToHex(NativeUInt(Control), 16) + '=' + Description);
      end;
    end;
    for var J := 0 to Owner.ComponentCount - 1 do
    begin
      Name := Owner.Components[J].Name;
      if Name = '' then Name := Owner.Components[J].ClassName + '#' + IntToStr(J);
      CaptureMainControls(Owner.Components[J], Path + '/' + Name, Snapshot);
    end;
  end;

  function CaptureOwnedWindow(Window: HWND; Snapshot: TStrings): Boolean;
  var PID: DWORD;
  begin
    PID := 0; GetWindowThreadProcessId(Window, @PID);
    Result := (PID = GetCurrentProcessId) and IsWindow(Window);
    if Result then
      Snapshot.Add(IntToHex(NativeUInt(Window), 16) + '=' + NativeClass(Window) +
        ' thread=' + IntToStr(GetWindowThreadProcessId(Window, nil)) +
        ' visible=' + IntToStr(Ord(IsWindowVisible(Window))));
  end;

  procedure CaptureOwnedChildren(Parent: HWND; Snapshot: TStrings; Depth: Integer);
  var Child, Next: HWND;
  begin
    if Depth > 64 then Exit;
    Child := GetWindow(Parent, GW_CHILD);
    while Child <> 0 do
    begin
      Next := GetWindow(Child, GW_HWNDNEXT);
      if CaptureOwnedWindow(Child, Snapshot) then CaptureOwnedChildren(Child, Snapshot, Depth + 1);
      Child := Next;
    end;
  end;

  procedure CaptureWindows(Snapshot: TStrings);
  var Window, Next: HWND;
  begin
    Window := GetTopWindow(0);
    while Window <> 0 do
    begin
      Next := GetWindow(Window, GW_HWNDNEXT);
      if CaptureOwnedWindow(Window, Snapshot) then CaptureOwnedChildren(Window, Snapshot, 0);
      Window := Next;
    end;
    // Timer/COM message-only windows are not part of the top-level desktop list.
    Window := FindWindowEx(HWND_MESSAGE, 0, nil, nil);
    while Window <> 0 do
    begin
      Next := FindWindowEx(HWND_MESSAGE, Window, nil, nil);
      CaptureOwnedWindow(Window, Snapshot);
      Window := Next;
    end;
  end;

  procedure ReportDelta(const Stage: string; Current, Baseline: TStrings);
  var Key: string;
  begin
    Writeln('TRACE failed reader ', Stage, ' baseline_count=', Baseline.Count, ' current_count=', Current.Count);
    for var J := 0 to Current.Count - 1 do
    begin
      Key := Current.Names[J];
      if Baseline.Values[Key] <> Current.ValueFromIndex[J] then
        Writeln('TRACE failed reader ', Stage, ' new-or-changed ', Current[J]);
    end;
    for var J := 0 to Baseline.Count - 1 do
      if Current.IndexOfName(Baseline.Names[J]) < 0 then
        Writeln('TRACE failed reader ', Stage, ' released ', Baseline[J]);
    Flush(Output);
  end;

  procedure ExerciseRound(I: Integer; const Phase: string; EnforceBudget: Boolean);
  var Prefix: string;
  begin
    Prefix := 'failed-modal-';
    if Phase <> 'original' then Prefix := Prefix + Phase + '-';
    Source := Settings.AppPath + Prefix + IntToStr(I) + '.fb2';
    if I mod 2 = 0 then TFile.WriteAllText(Source, '<FictionBook><body><p>broken</body>', TEncoding.UTF8)
    else TFile.WriteAllText(Source, '<FictionBook><body><section><p>' + StringOfChar('A',3000000) +
      '</p></section></body></FictionBook>', TEncoding.UTF8);
    Hash := THashSHA2.GetHashStringFromFile(Source); Driver := TFailedBuiltinReadDriver.Create;
    try
      Driver.CancelDuringLoad := I mod 2 <> 0; Driver.WarmUI := Phase='cold';
      Driver.Timer := TTimer.Create(nil); Driver.Timer.Interval := 1; Driver.Timer.OnTimer := Driver.Tick;
      Driver.Started := GetTickCount64; Driver.Timer.Enabled := True;
      // Exercise the same real main-owned modal path for both first-use and measured cycles.
      OpenBuiltinReader(frmMain, Source, 'Failure cleanup', Prefix + IntToStr(I),
        Settings.DataDir + 'failed-modal.ini', Settings.AppPath + 'tools\pdfium\pdfium.dll');
      Require(Driver.Finished and (Driver.ObservedCancellation or Driver.ObservedFailure),
        'Failed/canceled modal reader was not exercised');
    finally Driver.Timer.Free; Driver.Free; end;
    if EnforceBudget then
      DrainFailedReaderIdleCleanup(Phase + '-round-' + IntToStr(I),BeforeGDI+4,BeforeUSER+4)
    else DrainFailedReaderIdleCleanup(Phase + '-round-' + IntToStr(I));
    Require(frmMain.Visible and frmMain.Enabled, 'Failed reader left main window hidden or disabled');
    Require(THashSHA2.GetHashStringFromFile(Source) = Hash, 'Reader failure changed its input');
    for var F := 0 to Screen.FormCount - 1 do
      Require(not (Screen.Forms[F] is TfrmBuiltinReader), 'Reader error left an orphan window');
    Require(Screen.FormCount = FormsBaseline, 'Failure/cancel lifecycle left another orphan form');
    GdiFlush;
    Writeln('PROFILE failed reader phase=', Phase, ' round=', I,
      ' gdi=', GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS),
      ' user=', ReaderApplicationUSERCount, ' forms=', Screen.FormCount);
    Flush(Output);
    Controls.Clear; Windows.Clear;
    CaptureMainControls(frmMain, 'frmMain', Controls); CaptureWindows(Windows);
    ReportDelta(Phase + '-round-' + IntToStr(I) + '-main-controls', Controls, BaseControls);
    ReportDelta(Phase + '-round-' + IntToStr(I) + '-native-windows', Windows, BaseWindows);
    if EnforceBudget then
    begin
      RequireFailedReaderHandleBaseline('main VCL controls', Controls, BaseControls);
      RequireFailedReaderHandleBaseline('native windows', Windows, BaseWindows);
      Require(GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS) <= BeforeGDI + 4,
        'Failed main-owned readers leak drawing handles');
      Require(ReaderApplicationUSERCount <= BeforeUSER + 4,
        'Failed main-owned readers leak window handles');
    end;
  end;

begin
  BaseControls := TStringList.Create; BaseWindows := TStringList.Create;
  Controls := TStringList.Create; Windows := TStringList.Create;
  WasVisible := frmMain.Visible;
  try
    frmMain.Show; Application.ProcessMessages;
    DrainFailedReaderIdleCleanup('before-cold-baseline');
    ColdGDI := GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS);
    ColdUSER := ReaderApplicationUSERCount;
    FormsBaseline := Screen.FormCount;
    CaptureMainControls(frmMain, 'frmMain', BaseControls); CaptureWindows(BaseWindows);
    ColdControlCount := BaseControls.Count; ColdWindowCount := BaseWindows.Count;
    Writeln('PROFILE failed reader cold baseline gdi=', ColdGDI, ' user=', ColdUSER,
      ' forms=', FormsBaseline, ' allocated_main_controls=', ColdControlCount,
      ' owned_native_windows=', ColdWindowCount); Flush(Output);
    // First show and paint BOTH distinct lifecycles before sampling steady-state.
    // Report the complete first-use delta instead of treating it as a leak.
    // These two cycles retain every input, enabled-main and orphan-form guard.
    ExerciseRound(0, 'cold', False); ExerciseRound(1, 'cold', False);
    BeforeGDI := GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS);
    BeforeUSER := ReaderApplicationUSERCount;
    Writeln('PROFILE failed reader steady-state baseline gdi=', BeforeGDI, ' user=', BeforeUSER,
      ' cold_gdi_delta=', Int64(BeforeGDI) - ColdGDI,
      ' cold_user_delta=', Int64(BeforeUSER) - ColdUSER,
      ' cold_main_controls=', ColdControlCount, ' current_main_controls=', Controls.Count,
      ' cold_native_windows=', ColdWindowCount, ' current_native_windows=', Windows.Count); Flush(Output);
    BaseControls.Assign(Controls); BaseWindows.Assign(Windows);
    // Preserve the original eight loops, then independently probe another
    // twenty-four complete lifecycles. The original +4 budget applies after
    // EVERY measured close, rather than only to the final sample.
    // Windows-worker default HIMCs are reported separately; see ReaderApplicationUSERCount.
    if ParamStr(1)='reader-resource-idle' then
    begin
      // Independent control: no reader is created or closed during these samples.
      for var I:=0 to 99 do
      begin
        DrainFailedReaderIdleCleanup('idle-control-'+IntToStr(I));
        Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=BeforeGDI+4,'Idle control drawing resources drifted without a reader');
        Require(ReaderApplicationUSERCount<=BeforeUSER+4,'Idle control USER resources drifted without a reader');
      end;
      Writeln('PASS reader resource idle control retains the same +4 budgets without repeated reader lifecycles');
    end
    else
    begin
      for var I := 0 to 7 do ExerciseRound(I, 'original', True);
      for var I := 0 to 23 do ExerciseRound(I, 'stress', True);
    end;
    GdiFlush;
    Require(GetGuiResources(GetCurrentProcess,GR_GDIOBJECTS)<=BeforeGDI+4,'Failed main-owned readers leak drawing handles');
    Require(ReaderApplicationUSERCount<=BeforeUSER+4,'Failed main-owned readers leak window handles');
  finally
    if not WasVisible then frmMain.Hide;
    Windows.Free; Controls.Free; BaseWindows.Free; BaseControls.Free;
  end;
  if ParamStr(1)<>'reader-resource-idle' then
    Writeln('PASS 32 steady-state failed/canceled reader lifecycles preserve +4 application budgets with Windows worker input contexts reported separately');
  Writeln('PASS malformed and canceled readers return to enabled visible main window, release handles and preserve inputs');
end;

procedure TestReaderDefaultSettings;
var Configuration: TfrmSettings; Toggle: TCheckBox; Loaded: TMHLSettings;
  Count, I: Integer; Paths: TStringList; External: TAction;
begin
  Require(Settings.UseBuiltinReaderByDefault,'Builtin reader default is not checked for fresh profile');
  Configuration:=TfrmSettings.Create(nil); Paths:=TStringList.Create;
  try
    Configuration.LoadSetting;
    Toggle:=Configuration.FindComponent('cbUseBuiltinReaderByDefault') as TCheckBox;
    Require(Assigned(Toggle) and Toggle.Checked,'Reader default checkbox missing or unchecked');
    Count:=Settings.Readers.Count;
    for I:=0 to Count-1 do Paths.Add(Settings.Readers[I].Extension+'='+Settings.Readers[I].Path);
    Require(not Configuration.lvReaders.Enabled and not Configuration.btnAddExt.Enabled and
      not Configuration.btnChangeExt.Enabled and not Configuration.btnDeleteExt.Enabled,'External editors active under builtin default');
    if Count>0 then
    begin
      Configuration.lvReaders.Selected:=Configuration.lvReaders.Items[0];
      Configuration.btnDeleteExtClick(nil);
      Require(Configuration.lvReaders.Items.Count=Count,'Programmatic delete bypasses reader-mode lock');
    end;
    Toggle.Checked:=False; Toggle.OnClick(Toggle);
    Require(Configuration.lvReaders.Enabled and Configuration.btnAddExt.Enabled and
      Configuration.btnChangeExt.Enabled and Configuration.btnDeleteExt.Enabled,'Disabling builtin default did not unlock external paths');
    Configuration.SaveSettings; Settings.SaveSettings;
    Loaded:=TMHLSettings.Create;
    try
      Loaded.LoadSettings;
      Require(not Loaded.UseBuiltinReaderByDefault,'Disabled reader preference lost after reload');
      Require(Loaded.Readers.Count=Count,'Reader mode toggle erased configured programs');
      for I:=0 to Count-1 do Require(Paths[I]=Loaded.Readers[I].Extension+'='+Loaded.Readers[I].Path,'Reader path changed during toggle');
    finally Loaded.Free; end;
    Toggle.Checked:=True; Toggle.OnClick(Toggle); Configuration.SaveSettings; Settings.SaveSettings;
    Loaded:=TMHLSettings.Create;
    try Loaded.LoadSettings; Require(Loaded.UseBuiltinReaderByDefault,'Enabled reader preference lost after reload');
    finally Loaded.Free; end;
    External:=frmMain.FindComponent('acReadExternal') as TAction;
    Require(Assigned(External),'Explicit external reader command missing'); External.Update;
    Require(External.Enabled,'Builtin default disables explicit external reading');
    Require((Toggle.BoundsRect.Bottom<=Configuration.lvReaders.Top) and
      (Configuration.lvReaders.Height>100),'Reader settings controls overlap or consume the whole list');
    Writeln('PASS reader default checkbox, editor locks, persistence, preserved paths and explicit external command');
  finally Paths.Free; Configuration.Free; end;
end;

procedure TestBuiltinReaderIntegration(const Collection: IBookCollection);
var Book: PBookRecord; Updated: TBookRecord; Source, BeforeHash, Body: string;
  Action: TAction; Driver: TBuiltinReadDriver; I: Integer;
  Bitmap: TBitmap; Png: TPngImage; Bytes: TBytesStream; Picture: string;
begin
  TestReaderDefaultSettings;
  Book:=frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Book.GetBookFormat=bfFb2),'Main built-in fixture is not FB2');
  Source:=Book.GetBookFileName; Body:='';
  for I:=1 to 180 do Body:=Body+'<p>Исходный текст встроенной читалки. Проверка чтения из главной формы и сохранения прогресса. '+IntToStr(I)+'</p>';
  Bitmap:=TBitmap.Create; Png:=TPngImage.Create; Bytes:=TBytesStream.Create;
  try
    Bitmap.SetSize(160,100); Bitmap.Canvas.Brush.Color:=clGreen;
    Bitmap.Canvas.FillRect(Rect(0,0,160,100)); Png.Assign(Bitmap); Png.SaveToStream(Bytes);
    Picture:=TNetEncoding.Base64.EncodeBytesToString(Copy(Bytes.Bytes,0,Integer(Bytes.Size)));
  finally Bytes.Free; Png.Free; Bitmap.Free; end;
  TFile.WriteAllText(Source,'<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body><section><image l:href="#picture"/>'+Body+
    '</section></body><binary id="picture" content-type="image/png">'+Picture+'</binary></FictionBook>',TEncoding.UTF8);
  BeforeHash:=THashSHA2.GetHashStringFromFile(Source);
  Settings.ConvertWebPToPNG:=True; Settings.OverwriteFB2Info:=True;
  Action:=frmMain.FindComponent('acReadBuiltin') as TAction;
  Require(Assigned(Action),'Main built-in reader action absent');
  Action.Update;
  Require(Action.Enabled and (Action.ShortCut=ShortCut(Ord('R'),[ssCtrl,ssAlt])),'Main reader shortcut or availability incorrect');
  Driver:=TBuiltinReadDriver.Create;
  try
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=25; Driver.Timer.OnTimer:=Driver.Tick;
    Driver.Started:=GetTickCount64; Driver.Timer.Enabled:=True;
    frmMain.acBookRead.Execute; // Same automatic opening path as a double click.
    while not Driver.Finished and (GetTickCount64-Driver.Started<12000) do
    begin Application.ProcessMessages; CheckSynchronize(0); Sleep(10); end;
    Require(Driver.Finished,'Main reader did not close through ordinary modal pipeline');
    Collection.GetBookRecord(Book^.BookKey,Updated,False);
    Require((Updated.Progress>0) and (Updated.Progress<100),'Main reader did not persist partial progress');
    Require(Book^.Progress=Updated.Progress,'Main visible book progress was not refreshed');
    Require(FileExists(TPath.Combine(Settings.DataDir,'reader.ini')),'Main reader settings not saved under data folder');
    Require(THashSHA2.GetHashStringFromFile(Source)=BeforeHash,'Built-in reading rewrote original FB2 metadata');
    Require(Settings.ConvertWebPToPNG and Settings.OverwriteFB2Info,'Built-in reader changed export settings');
    Writeln('PASS main built-in reader action opens selected book, saves progress and preserves source and external-reader settings');
  finally Driver.Timer.Free; Driver.Free; end;
  TestFailedBuiltinReaderOwner;
end;

procedure TestReaderCompatibility;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  PLAIN = '<?xml version="1.0" encoding="utf-8"?><FictionBook><body><section><p>Plain book</p></section></body></FictionBook>';
var
  Book: PBookRecord;
  Original, Probe, Converted, WithWebP, Captured: string;
  Started: UInt64;
  Locked: TFileStream;
  Other: TBookRecord;
  ReaderPreferences: TMemIniFile;

  procedure WriteSource(const Content: string);
  var Deadline: UInt64;
  begin
    // The initial info-panel preview can still hold a read-only source handle.
    // Wait for that independent worker before replacing our test fixture.
    Deadline:=GetTickCount64+3000;
    repeat
      try TFile.WriteAllText(Original,Content,TEncoding.UTF8); Exit;
      except on E: EFCreateError do if GetTickCount64>=Deadline then raise; end;
      Application.ProcessMessages; CheckSynchronize(0); Sleep(20);
    until False;
  end;

  function ReadSelected: string;
  var PreviousBuiltin: Boolean;
  begin
    PreviousBuiltin:=Settings.UseBuiltinReaderByDefault;
    Settings.UseBuiltinReaderByDefault:=False;
    try
      if FileExists(Probe) then TFile.Delete(Probe);
      frmMain.ReadBookExecute(nil);
      Started := GetTickCount64;
      while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do
      begin Application.ProcessMessages; CheckSynchronize(0); Sleep(20); end;
      Require(FileExists(Probe), 'The isolated reader probe did not receive a book');
      Result := TFile.ReadAllText(Probe, TEncoding.UTF8);
    finally Settings.UseBuiltinReaderByDefault:=PreviousBuiltin; end;
  end;

begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Book.GetBookFormat = bfFb2), 'Reader fixture is not a plain FB2');
  Original := Book.GetBookFileName;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  // The chooser itself is exercised by Round2Probe. This compatibility test
  // remembers the isolated probe, as a user can remember an external reader.
  ReaderPreferences:=TMemIniFile.Create(TPath.Combine(Settings.DataDir,'reader.ini'),TEncoding.UTF8);
  try
    ReaderPreferences.WriteString('OpenWith','.fb2','@configured');
    ReaderPreferences.UpdateFile;
  finally ReaderPreferences.Free; end;
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  WriteSource(PLAIN);
  Captured := ReadSelected;
  Require(SameFileName(Captured, Original), 'An ordinary FB2 lost its stable reader path');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = PLAIN, 'An ordinary source book changed');
  WithWebP := '<FictionBook><body><section><p>WebP book</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
  WriteSource(WithWebP);
  Converted := ReadSelected;
  Require(not SameFileName(Converted, Original) and
    (Pos('webp-png', LowerCase(Converted)) > 0), 'A WebP book was not read from its converted cache');
  Captured := TFile.ReadAllText(Converted, TEncoding.UTF8);
  Require((Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0),
    'The reader received no converted PNG');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'The WebP source book changed');
  Require(SameFileName(PrepareReaderFile(Book^, True), Original), 'Built-in reader received a converted plain FB2');
  Require(Settings.ConvertWebPToPNG, 'Built-in reader changed export compatibility setting');
  Locked := TFileStream.Create(Original, fmOpenRead or fmShareExclusive);
  try
    Require(SameFileName(ReadSelected, Converted), 'Cache hit reopened the locked source');
  finally Locked.Free; end;
  Other := Book^;
  Inc(Other.BookKey.DatabaseID);
  Require(ReaderCopyName(Other) <> ReaderCopyName(Book^), 'Different collections share a reader path');
  Writeln('PASS reader cache hit avoids source extraction and isolates collection identities');
  Settings.ConvertWebPToPNG := False;
  Require(SameFileName(ReadSelected, Original), 'Original mode reused the converted reader cache');
  Settings.ConvertWebPToPNG := True;
  Require(SameFileName(ReadSelected, Converted), 'PNG mode lost its separate reader cache');
  Book.BookKey.BookID := Book.BookKey.BookID + 10000;
  Book.Title := 'Renamed title after reimport';
  Require(SameFileName(ReadSelected, Converted), 'Reimport or metadata edit changed the reader path');
  WithWebP := StringReplace(WithWebP, 'WebP book', 'Updated WebP book', []);
  WriteSource(WithWebP);
  Require(SameFileName(ReadSelected, Converted), 'Source refresh changed the reader path');
  Require(TFile.ReadAllText(Converted, TEncoding.UTF8).Contains('Updated WebP book'),
    'Changed source reused stale reader bytes');
  Require(TFile.ReadAllText(Original, TEncoding.UTF8) = WithWebP, 'Reader policy changes wrote to the source');
  Writeln('PASS stable reader cache survives reimport and refreshes changed sources');
  Writeln('PASS plain FB2 reader preserves ordinary paths, converts WebP, separates policy cache and leaves source unchanged');
end;

procedure TestLooseArchiveReading;
const WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
var Book: TBookRecord; Source, Prepared, Expected, BeforeHash: string;
  Zip: TZipFile; Failed: Boolean; Stamp: TDateTime;
  procedure WriteArchive(const Entries, Contents: array of string);
  var I: Integer;
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(Source, zmWrite);
      for I := 0 to High(Entries) do Zip.Add(TEncoding.UTF8.GetBytes(Contents[I]), Entries[I]);
      Zip.Close;
    finally Zip.Free; end;
  end;
  procedure ChooseMember(Index: Integer; Accept: Boolean);
  begin
    TThread.ForceQueue(nil,
      procedure
      var Popup: TForm; Component: TComponent;
      begin
        Popup := Screen.ActiveForm;
        Require(Assigned(Popup) and (Popup.Caption = 'Какую книгу открыть?'), 'Archive picker is absent');
        for Component in Popup do if Component is TListBox then
        begin
          Require(TListBox(Component).Items.Count = 2, 'Executable was offered as a reading format');
          TListBox(Component).ItemIndex := Index;
        end;
        if Accept then Popup.ModalResult := mrOk else Popup.ModalResult := mrCancel;
      end);
  end;
begin
  Book := Default(TBookRecord); Book.NodeType := ntBookInfo;
  Book.BookKey := CreateBookKey(777, Settings.ActiveCollection);
  Book.CollectionRoot := IncludeTrailingPathDelimiter(Settings.AppPath);
  Book.FileName := 'loose-reader'; Book.FileExt := '.zip'; Book.LibID := 'archive-fixture';
  Source := Book.GetBookFileName;
  Require(Book.GetBookFormat = bfRaw, 'Loose archive fixture uses catalog-member semantics');
  WriteArchive(['../../escape.txt'], ['Original archive text']);
  BeforeHash := THashSHA2.GetHashStringFromFile(Source);
  Prepared := PrepareReaderFile(Book);
  Require(SameText(ExtractFileExt(Prepared), '.txt') and
    SameFileName(ExtractFilePath(Prepared), IncludeTrailingPathDelimiter(BookCachePath)),
    'Loose archive extraction did not use a flat reading-cache path');
  Require(TFile.ReadAllText(Prepared, TEncoding.UTF8) = 'Original archive text', 'Loose member bytes changed');
  Require(not FileExists(Settings.AppPath + 'escape.txt'), 'Archive path escaped the reading cache');
  Require(THashSHA2.GetHashStringFromFile(Source) = BeforeHash, 'Reading rewrote the source archive');
  BeforeHash:=THashSHA2.GetHashStringFromFile(Prepared);
  Require(SameFileName(PrepareReaderFile(Book), Prepared) and
    (THashSHA2.GetHashStringFromFile(Prepared)=BeforeHash), 'Loose archive cache hit rewrote extracted bytes');
  WriteArchive(['../../escape.txt'], ['Refreshed and longer archive text']);
  Require(SameFileName(PrepareReaderFile(Book), Prepared) and
    TFile.ReadAllText(Prepared, TEncoding.UTF8).Contains('Refreshed'), 'Changed archive reused stale member bytes');
  Settings.ConvertWebPToPNG := True;
  Expected := '<FictionBook><body><section><p>Original WebP</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/webp">' + WEBP + '</binary></FictionBook>';
  WriteArchive(['book.fb2'], [Expected]);
  BeforeHash := THashSHA2.GetHashStringFromFile(Source);
  Prepared := PrepareReaderFile(Book);
  Require(Pos('webp-png', LowerCase(Prepared)) > 0, 'Archive FB2 bypassed reader compatibility policy');
  Require(TFile.ReadAllText(Prepared, TEncoding.UTF8).Contains('image/png') and
    (THashSHA2.GetHashStringFromFile(Source) = BeforeHash), 'Archive conversion changed source or lost PNG');
  Prepared := PrepareReaderFile(Book, True);
  Require(TFile.ReadAllText(Prepared, TEncoding.UTF8) = Expected,
    'Built-in reader lost original archive WebP');
  Require(Settings.ConvertWebPToPNG, 'Archive original mode changed global conversion policy');
  Settings.ConvertWebPToPNG := False;
  Prepared := PrepareReaderFile(Book);
  Require(TFile.ReadAllText(Prepared, TEncoding.UTF8) = Expected, 'Original archive policy reused converted bytes');
  WriteArchive(['one.txt', 'two.pdf', 'unsafe.exe'], ['One text', '%PDF-1.4 test', 'Never execute']);
  ChooseMember(1, True); Prepared := PrepareReaderFile(Book);
  Require(SameText(ExtractFileExt(Prepared), '.pdf') and
    TFile.ReadAllText(Prepared, TEncoding.UTF8).StartsWith('%PDF-'), 'Archive picker extracted the wrong member');
  ChooseMember(0, False);
  Require(PrepareReaderFile(Book) = '', 'Cancelled archive picker opened a file');
  WriteArchive(['unsafe.exe', 'another.zip'], ['Never execute', 'Not a nested-book scan']);
  Failed := False;
  try PrepareReaderFile(Book); except on E: Exception do Failed := Pos('не найдены книги', E.Message) > 0; end;
  Require(Failed, 'Archive without readable members was accepted');
  Writeln('PASS loose archives open readable members, preserve originals, refresh cache and contain entry paths');
  Writeln('PASS archive picker handles several books and cancellation without offering executables');
end;

procedure TestBookColumnFilters;
var Filters: TBookColumnFilters; Node: PVirtualNode; Book: PBookRecord;
  Marked, I, PopupTag: Integer;

  function CountVisible: Integer;
  var N: PVirtualNode; B: PBookRecord;
  begin
    Result := 0;
    N := frmMain.tvBooksA.GetFirst;
    while Assigned(N) do
    begin
      B := frmMain.tvBooksA.GetNodeData(N);
      if (B.NodeType = ntBookInfo) and not frmMain.tvBooksA.IsEffectivelyFiltered[N] then Inc(Result);
      N := frmMain.tvBooksA.GetNext(N);
    end;
  end;
begin
  Filters := TBookColumnFilters.ForTree(frmMain.tvBooksA);
  Filters.SetValue(COL_TITLE, 'EXTRA');
  Filters.SetValue(COL_LANG, 'uk');
  frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  Require((Filters.Count = 2) and (CountVisible = 1), 'Combined column filters did not narrow book rows');
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Book.Title = 'Alpha extra uk', 'Filter retained a hidden focused book');
  Require(Pos('1 из 3', frmMain.lblBooksTotalA.Caption) > 0, 'Active filter count is invisible');
  Filters.SetValue(COL_TITLE,'unmatched'); Filters.SetCaseSensitive(COL_TITLE,True);
  PostMessage(frmMain.Handle,WM_KEYDOWN,VK_ESCAPE,0);
  frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  Require(frmMain.BookListCancelled and (CountVisible=1) and (Filters.Value(COL_TITLE)='EXTRA') and
    not Filters.CaseSensitive(COL_TITLE) and (Filters.Value(COL_LANG)='uk'),
    'Cancelled filtering erased previous conditions, case setting or displayed result');
  Require(Pos('1 из 3',frmMain.lblBooksTotalA.Caption)>0,'Cancelled filter count differs from restored result');
  frmMain.pmiCheckAllClick(nil);
  Marked := 0;
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if Book.NodeType = ntBookInfo then
    begin
      if Node.CheckState = csCheckedNormal then Inc(Marked);
      Require(not frmMain.tvBooksA.IsEffectivelyFiltered[Node] or (Node.CheckState = csUncheckedNormal),
        'Mark all included a filtered-out book');
    end;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Require(Marked = 1, 'Filtered mark-all selected the wrong books');
  frmMain.pmiSelectAllClick(nil);
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Require(not frmMain.tvBooksA.IsEffectivelyFiltered[Node] or not frmMain.tvBooksA.Selected[Node],
      'Select all included a filtered-out row');
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  frmMain.LocateBook('Alpha ru', False);
  Require(frmMain.tvBooksA.GetFirstSelected = nil, 'Quick search selected a filtered-out book');
  frmMain.btnSwitchTreeModeClick(nil);
  Require(CountVisible = 1, 'Flat mode rebuild lost active column filters');
  frmMain.btnSwitchTreeModeClick(nil);
  Require(CountVisible = 1, 'Grouped mode rebuild lost active column filters');
  Filters.SetValue(COL_TITLE, 'nothing matches');
  frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  Require((CountVisible = 0) and (frmMain.tvBooksA.FocusedNode = nil), 'No-match filter retained a book');
  Require(frmMain.tvBooksA.GetFirstVisible = nil, 'Empty groups survived the filter');
  Filters.Clear;
  frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  Require((CountVisible = 3) and Assigned(frmMain.tvBooksA.FocusedNode), 'Clearing filters failed to restore books');
  Writeln('PASS column filters combine, survive regrouping, hide empty groups and mark only matching books');
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if Book.NodeType = ntBookInfo then
    begin
      if Book.Title = 'Alpha extra uk' then Book.Date := EncodeDate(2026, 10, 10)
      else Book.Date := EncodeDate(2026, 10, 9);
      if Book.Title = 'Alpha ru' then begin Book.Size := 1024; Book.Rate := 1; Book.SeqNumber := 1; end
      else if Book.Title = 'Alpha uk' then begin Book.Size := 1048576; Book.Rate := 3; Book.SeqNumber := 2; end
      else begin Book.Size := 2097152; Book.Rate := 5; Book.SeqNumber := 3; end;
      TSeriesHelper.Add(Book.PublisherSeries, 1234, 'Publisher fixture', 1, False);
      Book.PublisherSeriesKnown := True;
    end;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Filters.SetValue(COL_DATE, 'date;1;2026-10-09;2026-10-09');
  Require(Filters.Apply = 2, 'Equal-date filter includes another day');
  Filters.SetValue(COL_DATE, 'date;4;2026-10-09;2026-10-09');
  Require(Filters.Apply = 1, 'After-date filter is not exclusive');
  Filters.SetValue(COL_DATE, 'date;3;2026-10-09;2026-10-09');
  Require(Filters.Apply = 2, 'Before-inclusive filter excludes its boundary');
  Filters.SetValue(COL_DATE, 'date;6;2026-10-09;2026-10-10');
  Require(Filters.Apply = 3, 'Date range is not inclusive');
  Filters.Clear;
  Filters.SetValue(COL_PUBLISHER_SERIES_FILTER, 'Publisher fixture');
  Require(Filters.Apply = 3, 'Loaded publisher series are not filterable');
  Filters.Clear;
  Filters.SetValue(COL_SIZE, 'num;4;1048576;1048576;2');
  Require(Filters.Apply = 1, 'Greater-than size includes equal or smaller bytes');
  Filters.SetValue(COL_SIZE, 'num;5;1048576;1048576;2');
  Require(Filters.Apply = 1, 'Less-than size includes equal or larger bytes');
  Filters.SetValue(COL_SIZE, 'num;1;1048576;1048576;1');
  Require(Filters.Apply = 1, 'Equal size compares a rounded display string');
  Filters.SetValue(COL_SIZE, 'num;6;1024;1048576;1');
  Require(Filters.Apply = 2, 'Size range excludes either boundary');
  Filters.SetValue(COL_RATE, 'num;2;3;3;0');
  Require(Filters.Apply = 1, 'Rating and size do not combine');
  Filters.Clear; Filters.SetValue(COL_NO, 'num;6;2;3;0');
  Require(Filters.Apply = 2, 'Sequence numbers lack numeric comparisons');
  Filters.Clear;
  for I in TArray<Integer>.Create(COL_TITLE, COL_AUTHOR, COL_SERIES, COL_TYPE, COL_COLLECTION, COL_DATE, COL_LIBID, COL_LIBRATE, COL_SIZE, COL_NO, COL_RATE) do
  begin
    PopupTag := I;
    TThread.ForceQueue(nil,
      procedure
      var Popup: TForm; Component: TComponent; EditCount, ChoiceCount, DateCount: Integer; Checks: TCheckListBox; Values: TVirtualStringTree;
      begin
        Checks := nil; Values := nil; Popup := Screen.ActiveForm;
        EditCount := 0; ChoiceCount := 0; DateCount := 0;
        for Component in Popup do
        begin
          if Component is TEdit then Inc(EditCount);
          if Component is TComboBox then Inc(ChoiceCount);
          if Component is TDateTimePicker then Inc(DateCount);
          if Component is TCheckListBox then Checks := TCheckListBox(Component);
          if Component is TVirtualStringTree then Values := TVirtualStringTree(Component);
        end;
        if PopupTag = COL_DATE then Require((EditCount = 0) and (ChoiceCount = 1) and (DateCount = 2), 'Date icon opens unrelated fields')
        else if PopupTag in [COL_AUTHOR,COL_SERIES,COL_TYPE,COL_COLLECTION] then
          Require(Assigned(Values) and (EditCount = 1) and (ChoiceCount = 0) and (DateCount = 0), 'Loaded-value popup lacks searchable checkbox list')
        else if PopupTag in [COL_RATE,COL_LIBRATE] then
          Require(Assigned(Checks) and (Checks.Items.Count=6) and (EditCount = 0) and (ChoiceCount = 0) and (DateCount = 0), 'Rating checklist lacks six values or contains numeric controls')
        else if PopupTag in [COL_SIZE, COL_NO] then
          Require((EditCount = 2) and (ChoiceCount = 1 + Ord(PopupTag = COL_SIZE)) and (DateCount = 0), 'Numeric icon lacks comparison or size units')
        else Require((EditCount = 1) and (ChoiceCount = 0) and (DateCount = 0), 'Text icon opens more than its column');
        Require(Popup.BorderStyle=bsSizeable,'Column filter cannot resize');
        Require(Popup.ClientWidth <= MulDiv(420, Popup.CurrentPPI, 96), 'Individual filter is wider than its initial layout');
        if Assigned(Values) then
        begin
          var N:=Values.GetFirst;
          while Assigned(N) do
          begin
            Values.ValidateNode(N,False);
            Require(N.CheckState=csUncheckedNormal,'Opening an inactive filter automatically checked a value');
            N:=Values.GetNext(N);
          end;
        end;
        for var PPI in TArray<Integer>.Create(96,120,144,192) do
        begin
          Popup.ScaleForPPI(PPI);
          Popup.ClientWidth:=MulDiv(420,PPI,96); Popup.ClientHeight:=MulDiv(440,PPI,96);
          for var C in Popup do if C is TButton then
          begin
            var B:=TButton(C);
            Require((B.Left>=0) and (B.Top>=0) and (B.Left+B.Width<=B.Parent.ClientWidth) and
              (B.Top+B.Height<=B.Parent.ClientHeight),'Filter button is cropped at '+IntToStr(PPI)+' DPI: '+B.Caption);
          end;
          Popup.ClientWidth:=Popup.ClientWidth+MulDiv(200,PPI,96);
          if Assigned(Values) then Require(Values.Width>MulDiv(500,PPI,96),'Resizing popup did not enlarge its value list');
        end;
        Popup.ModalResult := mrCancel;
      end);
    Require(not EditBookColumnFilter(frmMain.tvBooksA, I), 'Cancel unexpectedly applied a column filter');
    Require(Filters.Count = 0, 'Cancel changed existing filters');
  end;
  TThread.ForceQueue(nil,
    procedure
    var Popup: TForm; Component: TComponent; Mode, Units: TComboBox; First, Last: TEdit;
    begin
      Popup := Screen.ActiveForm; Mode := nil; Units := nil; First := nil; Last := nil;
      for Component in Popup do
      begin
        if Component is TComboBox then
          if TComboBox(Component).Items.IndexOf('МБ') >= 0 then Units := TComboBox(Component)
          else Mode := TComboBox(Component);
        if Component is TEdit then
          if not Assigned(First) then First := TEdit(Component) else Last := TEdit(Component);
      end;
      Require(Assigned(Mode) and Assigned(Units) and Assigned(First) and Assigned(Last), 'Size editor controls missing');
      Mode.ItemIndex := 6; Mode.OnChange(Mode); Units.ItemIndex := 2;
      First.Text := FloatToStr(0.5); Last.Text := FloatToStr(1.5);
      Require(Last.Visible, 'Between condition hides its second value');
      Popup.ModalResult := mrOk;
    end);
  Require(EditBookColumnFilter(frmMain.tvBooksA, COL_SIZE), 'Size popup did not apply');
  Require(Filters.Value(COL_SIZE) = 'num;6;524288;1572864;2', 'MB fractions were not converted to bytes');
  Require(Filters.Apply = 1, 'MB range retained the wrong books');
  Filters.SetValue(COL_TITLE, 'Alpha');
  TThread.ForceQueue(nil,
    procedure
    var Component: TComponent; Reset: TButton;
    begin
      Reset := nil;
      for Component in Screen.ActiveForm do
        if (Component is TButton) and (TButton(Component).Caption = 'Сбросить') then Reset := TButton(Component);
      Require(Assigned(Reset), 'Compact filter lacks reset'); Reset.Click;
    end);
  Require(EditBookColumnFilter(frmMain.tvBooksA, COL_SIZE), 'Size reset did not apply');
  Require((Filters.Value(COL_SIZE) = '') and (Filters.Value(COL_TITLE) <> ''), 'Reset cleared other columns');
  Filters.SetCaseSensitive(COL_TITLE,True);
  TThread.ForceQueue(nil,
    procedure
    var Manager: TForm; Component: TComponent; TitleButton: TButton;
    begin
      Manager := Screen.ActiveForm; TitleButton := nil;
      for Component in Manager do
        if (Component is TButton) and (TButton(Component).Tag=COL_TITLE) and
          string(TButton(Component).Caption).StartsWith('Название') then TitleButton := TButton(Component);
      Require(Assigned(TitleButton),'All-filters manager lacks title button');
      TThread.ForceQueue(nil,
        procedure
        var C: TComponent;
        begin
          for C in Screen.ActiveForm do
          begin
            if C is TEdit then TEdit(C).Text := 'temporary';
            if C is TCheckBox then TCheckBox(C).Checked := False;
          end;
          Screen.ActiveForm.ModalResult := mrOk;
        end);
      TitleButton.Click;
      Require((Filters.Value(COL_TITLE)='Alpha') and Filters.CaseSensitive(COL_TITLE),'Manager child edit leaked unconfirmed draft into live conditions');
      Manager.ModalResult := mrCancel;
    end);
  Require(not EditBookColumnFilters(frmMain.tvBooksA),'Manager cancel unexpectedly applied');
  Require((Filters.Value(COL_TITLE)='Alpha') and Filters.CaseSensitive(COL_TITLE),
    'Manager cancel did not restore both value and case flag');
  Filters.Clear;
  frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if Book.NodeType = ntBookInfo then
    begin
      if Book.Rate = 5 then Book.Title := 'Учебник Творца';
      if Book.Rate = 3 then Book.Title := 'Второе творение';
    end;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Filters.SetValue(COL_TITLE,'твор'); Require(Filters.Apply = 2,'Cyrillic default filter is case-sensitive');
  Filters.SetCaseSensitive(COL_TITLE,True); Require(Filters.Apply = 1,'Case checkbox does not distinguish Cyrillic');
  Filters.SetCaseSensitive(COL_TITLE,False);
  Filters.SetValue(COL_RATE,'set;3;5'); Require(Filters.Apply = 2,'Rating checklist does not union selected values');
  Filters.SetValue(COL_RATE,'set;5'); Require(Filters.Apply = 1,'Rating checklist does not combine with text');
  Filters.Clear; frmMain.ApplyBookColumnFilters(frmMain.tvBooksA);
  // A facet showing only one available value is still an explicit selection.
  Filters.SetValue(COL_RATE,'set;5');
  TThread.ForceQueue(nil,
    procedure
    var Component: TComponent; Select: TButton;
    begin
      Select:=nil;
      for Component in Screen.ActiveForm do if (Component is TButton) and
        (TButton(Component).Caption='Выбрать найденные') then Select:=TButton(Component);
      Require(Assigned(Select),'Value popup lacks select found'); Select.Click;
      Screen.ActiveForm.ModalResult:=mrOk;
    end);
  Require(EditBookColumnFilter(frmMain.tvBooksA,COL_LANG),'Explicit facet selection did not apply');
  Require(Filters.Value(COL_LANG).StartsWith('values:'),'Selecting all current facet values silently removed the filter');
  Filters.SetValue(COL_RATE,''); Require(Filters.Apply=2,'Clearing another column broadened the chosen language');
  Filters.Clear;
  TThread.ForceQueue(nil,
    procedure begin Screen.ActiveForm.ModalResult:=mrOk; end);
  Require(EditBookColumnFilter(frmMain.tvBooksA,COL_LANG),'Empty selection did not apply');
  Require(Filters.Value(COL_LANG)='','No explicit choices should leave all values available');
  Filters.Apply;
  Writeln('PASS no implicit value selections, explicit facets survive other filters, all popup buttons fit at 96/120/144/192 DPI and lists resize');
  Writeln('PASS Unicode Cyrillic case mapping, explicit case mode and multi-value ratings');
  Writeln('PASS numeric size, number and rating filters compare raw values with inclusive ranges');
  Writeln('PASS compact size popup converts fractional MB and resets only its own column');
  Writeln('PASS per-column dialogs expose only their own loaded values; date boundaries and publisher series filters work');
  if ParamStr(2) = 'visual' then
  begin
    frmMain.Show;
    frmMain.ShowBookColumnFilters(nil);
  end;
end;

procedure TestBookGallery;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  FB2 = '<FictionBook><body><section><p>Gallery</p></section></body>' +
    '<binary id="one.webp" content-type="image/webp">' + WEBP + '</binary>' +
    '<binary id="damaged.png" content-type="image/png">not-an-image</binary>' +
    '<binary id="two.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
var Host: TForm; Panel: TInfoPanel; Gallery: TBookGallery; Calls: Integer;
  Started, ReleaseOld, OldFactoryDone: TEvent; Zip: TZipFile; Stream: TBytesStream;
  EpubFile: string; BeforeSource, SmallImage, LargeImage: string; DuplicateCase: Integer;

  function PNGBytes(W, H: Integer): string;
  var Bitmap: TBitmap; Png: TPngImage; Bytes: TBytesStream;
  begin
    Bitmap := TBitmap.Create; Png := TPngImage.Create; Bytes := TBytesStream.Create;
    try
      Bitmap.SetSize(W, H); Bitmap.Canvas.Brush.Color := clBlue;
      Bitmap.Canvas.FillRect(Rect(0, 0, W, H)); Png.Assign(Bitmap); Png.SaveToStream(Bytes);
      Result := TNetEncoding.Base64.EncodeBytesToString(Copy(Bytes.Bytes, 0, Integer(Bytes.Size)));
    finally Bytes.Free; Png.Free; Bitmap.Free; end;
  end;

  function VisualBook: string;
  var Bitmap: TBitmap; Png: TPngImage; Bytes: TBytesStream; I: Integer;
  begin
    Result := '<FictionBook><body><section><p>Gallery</p></section></body>';
    Bitmap := TBitmap.Create;
    Png := TPngImage.Create;
    Bytes := TBytesStream.Create;
    try
      Bitmap.SetSize(640, 400);
      for I := 1 to 3 do
      begin
        Bitmap.Canvas.Brush.Color := RGB(30 + I * 30, 90 + I * 25, 150);
        Bitmap.Canvas.FillRect(Rect(0, 0, 640, 400));
        Bitmap.Canvas.Font.Name := 'Segoe UI';
        Bitmap.Canvas.Font.Size := 24;
        Bitmap.Canvas.Font.Color := clWhite;
        Bitmap.Canvas.TextOut(40, 60, 'Проверочная иллюстрация ' + IntToStr(I));
        Bitmap.Canvas.Brush.Color := RGB(230, 180 - I * 20, 80);
        Bitmap.Canvas.Ellipse(220, 160, 420, 360);
        Png.Assign(Bitmap);
        Bytes.Clear;
        Png.SaveToStream(Bytes);
        Result := Result + '<binary id="image' + IntToStr(I) + '.png" content-type="image/png">' +
          TNetEncoding.Base64.EncodeBytesToString(Copy(Bytes.Bytes, 0, Integer(Bytes.Size))) + '</binary>';
      end;
      Result := Result + '</FictionBook>';
    finally Bytes.Free; Png.Free; Bitmap.Free; end;
  end;

  procedure WaitLoaded;
  var Start: UInt64;
  begin
    Start := GetTickCount64;
    while Gallery.Loading and (GetTickCount64 - Start < 10000) do
    begin Application.ProcessMessages; CheckSynchronize(10); end;
    Require(not Gallery.Loading, 'Gallery worker failed to finish');
  end;

begin
  Calls := 0;
  Host := TForm.CreateNew(nil);
  Started := TEvent.Create(nil, True, False, '');
  ReleaseOld := TEvent.Create(nil, True, False, '');
  OldFactoryDone := TEvent.Create(nil, True, False, '');
  try
    Host.Width := 850;
    Host.Height := 450;
    Panel := TInfoPanel.Create(Host);
    Panel.Parent := Host;
    Panel.Align := alClient;
    Gallery := Panel.Gallery;
    Gallery.PreviewSettingsFile := Settings.DataPath + 'gallery-window.ini';
    Panel.SetBookInfo('Gallery fixture', '', '', '');
    Gallery.SetBook('fixture', '.fb2',
      function: TStream
      begin
        TInterlocked.Increment(Calls);
        Result := TBytesStream.Create(TEncoding.UTF8.GetBytes(FB2));
      end);
    Host.Show;
    Application.ProcessMessages;
    if ParamStr(2) = 'visual' then
    begin
      BeforeSource := VisualBook;
      Host.Caption := 'HomeLib Ru — проверка галереи';
      Panel.SetBookInfo('Проверочная книга с иллюстрациями', '', '', '');
      Gallery.SetBook('visual-book', '.fb2',
        function: TStream
        begin Result := TBytesStream.Create(TEncoding.UTF8.GetBytes(BeforeSource)); end);
      while Host.Visible do
      begin Application.ProcessMessages; CheckSynchronize(10); end;
      Exit;
    end;
    Require(not Gallery.Expanded and not Gallery.Loading and (Calls = 0),
      'Collapsed gallery read the source eagerly');
    Gallery.Expanded := True;
    WaitLoaded;
    Require((Gallery.ImageCount = 2) and (Calls = 1),
      'FB2 gallery did not isolate damaged image or decode WebP by signature');
    Gallery.Expanded := False;
    Gallery.Expanded := True;
    WaitLoaded;
    Require((Calls = 1) and (Gallery.ImageCount = 2), 'Reopening gallery reread the same book');
    Writeln('PASS gallery loads lazily in background, isolates damaged images and reuses memory');

    TThread.ForceQueue(nil,
      procedure
      var Preview: TForm;
      begin
        Preview := Screen.ActiveForm;
        Require(Pos('Иллюстрации — 1 из 2', Preview.Caption) = 1, 'Wrong initial preview image');
        Preview.Perform(CM_DIALOGKEY, VK_RIGHT, 0);
        Require(Pos('2 из 2', Preview.Caption) > 0, 'Preview right arrow was consumed by button focus');
        Preview.Perform(CM_DIALOGKEY, VK_LEFT, 0);
        Require(Pos('1 из 2', Preview.Caption) > 0, 'Preview left arrow did not navigate');
        Preview.SetBounds(100, 80, 720, 500);
        Preview.Perform(CM_DIALOGKEY, VK_ESCAPE, 0);
      end);
    Gallery.OpenImage(0);
    Require(FileExists(Gallery.PreviewSettingsFile), 'Preview preferences were not saved');
    TThread.ForceQueue(nil,
      procedure
      var Preview: TForm;
      begin
        Preview := Screen.ActiveForm;
        Require((Preview.Left = 100) and (Preview.Top = 80) and
          (Preview.Width = 720) and (Preview.Height = 500), 'Preview bounds were not restored');
        Preview.Perform(CM_DIALOGKEY, VK_ESCAPE, 0);
      end);
    Gallery.OpenImage(1);
    Writeln('PASS illustration preview arrows work and resized window position persists');

    SmallImage := PNGBytes(200, 300); LargeImage := PNGBytes(333, 500);
    for DuplicateCase := 0 to 2 do
    begin
      BeforeSource := '<FictionBook><binary id="cover.jpg">';
      case DuplicateCase of
        0: BeforeSource := BeforeSource + SmallImage + '</binary><binary id="cover.jpg">' + LargeImage;
        1: BeforeSource := BeforeSource + LargeImage + '</binary><binary id="cover.jpg">' + SmallImage;
        2: BeforeSource := BeforeSource + 'broken' + '</binary><binary id="cover.jpg">' + LargeImage;
      end;
      BeforeSource := BeforeSource + '</binary></FictionBook>';
      Gallery.SetBook('duplicate-' + IntToStr(DuplicateCase), '.fb2',
        function: TStream begin Result := TBytesStream.Create(TEncoding.UTF8.GetBytes(BeforeSource)); end);
      Gallery.Expanded := True; WaitLoaded;
      Require(Gallery.ImageCount = 1, 'Repeated XML image ID produced multiple thumbnails');
      TThread.ForceQueue(nil,
        procedure
        var Component: TComponent; Found: Boolean;
        begin
          Found := False;
          for Component in Screen.ActiveForm do
            if Component is TImage then
            begin
              Found := True;
              Require((TImage(Component).Picture.Width = 333) and (TImage(Component).Picture.Height = 500),
                'Duplicate cover retained its smaller image');
            end;
          Require(Found, 'Image preview is missing');
          Screen.ActiveForm.ModalResult := mrCancel;
        end);
      Gallery.OpenImage(0);
    end;
    Writeln('PASS duplicate cover IDs retain the larger original pixels in either order and recover a broken first image');

    Gallery.SetBook('slow-old', '.fb2',
      function: TStream
      begin
        Started.SetEvent;
        ReleaseOld.WaitFor(10000);
        OldFactoryDone.SetEvent;
        Result := TBytesStream.Create(TEncoding.UTF8.GetBytes(FB2));
      end);
    Gallery.Expanded := True;
    Require(Started.WaitFor(5000) = wrSignaled, 'Gallery cancellation fixture never started');
    Gallery.SetBook('new-book', '.fb2',
      function: TStream
      begin
        Result := TBytesStream.Create(TEncoding.UTF8.GetBytes(
          '<FictionBook><binary id="new.webp">' + WEBP + '</binary></FictionBook>'));
      end);
    Require((Gallery.ImageCount = 0) and not Gallery.Expanded, 'Book change retained old thumbnails');
    ReleaseOld.SetEvent;
    Gallery.Expanded := True;
    WaitLoaded;
    Require(Gallery.ImageCount = 1, 'Cancelled old gallery published pictures into the new book');
    Writeln('PASS changing books cancels old gallery and releases temporary pictures');

    EpubFile := Settings.TempPath + 'gallery-fixture.epub';
    Zip := TZipFile.Create;
    try
      Zip.Open(EpubFile, zmWrite);
      Stream := TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(WEBP));
      try Zip.Add(Stream, 'images/one.webp'); finally Stream.Free; end;
      Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes('not an image'));
      try Zip.Add(Stream, '../../bad.png'); finally Stream.Free; end;
    finally Zip.Free; end;
    BeforeSource := TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(EpubFile));
    Gallery.SetBook('epub-book', '.epub',
      function: TStream
      begin Result := TFileStream.Create(EpubFile, fmOpenRead or fmShareDenyWrite); end);
    Gallery.Expanded := True;
    WaitLoaded;
    Require(Gallery.ImageCount = 1, 'EPUB gallery did not read image entries');
    Require(BeforeSource = TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(EpubFile)), 'Gallery changed EPUB source');
    Panel.Clear;
    Require(not Gallery.Visible and (Gallery.ImageCount = 0) and not Gallery.Loading,
      'Clearing card retained temporary gallery pictures');
    Writeln('PASS EPUB gallery leaves source unchanged, uses no extracted image files and clears with card');
  finally
    ReleaseOld.SetEvent;
    Host.Free;
    if (Started.WaitFor(0) <> wrSignaled) or (OldFactoryDone.WaitFor(5000) = wrSignaled) then
    begin
      ReleaseOld.Free;
      Started.Free;
      OldFactoryDone.Free;
    end;
  end;
end;

procedure MakeCleanupFixture(const Folder: string);
begin
  TDirectory.CreateDirectory(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER));
  TFile.WriteAllText(TPath.Combine(Folder, 'ordinary.tmp'), 'temporary root file');
  TFile.WriteAllText(TPath.Combine(Folder, WEBP_READER_CACHE_FOLDER + '\copy.fb2'), 'converted copy');
end;

procedure TestReviewHTTP;
var Details: TfrmBookDetails; URL: string; Started: UInt64;
  procedure WaitDownload;
  begin
    Started := GetTickCount64;
    while Assigned(Details.Downloading) do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64 - Started < 20000, 'Review request hung');
    end;
  end;
begin
  URL := 'http://127.0.0.1:' + ParamStr(2) + '/b/';
  Details := TfrmBookDetails.Create(nil);
  try
    Details.Review := 'Сохранённый отзыв';
    Require(not Details.ReviewChanged, 'Showing saved reviews counts as an edit');
    Details.AllowOnlineReview(URL + '1/'); Details.Download; WaitDownload;
    Require((Pos('Читатель:', Details.Review) > 0) and (Pos('хорошая', Details.Review) > 0),
      'HTTP UTF-8 review text corrupted');
    Details.Review := 'Не терять этот отзыв'; Details.ReviewChanged := False;
    Details.AllowOnlineReview(URL + '2/'); Details.Download; WaitDownload;
    Require((Pos('Не терять этот отзыв', Details.Review) > 0) and
      not Details.ReviewChanged and (Pos('HTTP 503', Details.ReviewStatus.Caption) > 0),
      'HTTP failure cleared saved reviews or was hidden');
    Details.AllowOnlineReview(URL + '3/'); Details.Download; WaitDownload;
    Require((Pos('Не терять этот отзыв', Details.Review) > 0) and
      not Details.ReviewChanged and (Pos('Не удалось', Details.ReviewStatus.Caption) = 1),
      'Blocked page replaced saved reviews');
  finally Details.Free; end;
  Details := TfrmBookDetails.Create(nil);
  Details.AllowOnlineReview(URL + '4/'); Details.Download;
  Started := GetTickCount64;
  while not FileExists(Settings.AppPath + 'review-request-started.marker') do
  begin
    Application.ProcessMessages; CheckSynchronize(10);
    Require(GetTickCount64 - Started < 5000, 'Closing test did not start HTTP request');
  end;
  Started := GetTickCount64; Details.Free;
  Require(GetTickCount64 - Started < 200, 'Closing reviews waits for network');
  Started := GetTickCount64;
  while GetTickCount64 - Started < 1800 do
  begin Application.ProcessMessages; CheckSynchronize(10); end;
  Writeln('PASS HTTP reviews decode UTF-8, preserve saved text on failures and close safely during an active request');
end;

procedure TestBookInformation;
var BookData: PBookRecord; OldLocal: Boolean; Details: TfrmBookDetails; Information: TAuthorInformation;
  Parser: TReviewParser; Reviews, Annotation: TStringList; Before: string;
  Started: UInt64; PhotoHash: string;
  procedure WaitForAuthor;
  begin
    Started := GetTickCount64;
    while Pos('Загрузка', Details.AuthorInformation.Status.Caption) = 1 do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64 - Started < 15000, 'Author worker did not finish');
    end;
  end;
begin
  BookData := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  OldLocal := bpIsLocal in BookData.BookProps; Exclude(BookData.BookProps, bpIsLocal);
  try
    Settings.ShowInfoPanel := False; frmMain.ShowBookInfoPanelExecute(nil);
    Require(frmMain.ipnlAuthors.DetailsButton.Visible and
      (frmMain.ipnlAuthors.DetailsButton.Caption = 'Информация о книге'), 'Card has no common information button');
    TThread.ForceQueue(nil,
      procedure
      var Popup: TfrmBookDetails;
      begin
        Require(Screen.ActiveForm is TfrmBookDetails, 'Card button did not open book details');
        Popup := TfrmBookDetails(Screen.ActiveForm);
        Require(Popup.AuthorTab.Caption = 'Об авторе', 'Common author tab absent');
        Require(not Popup.ReviewChanged, 'Opening book details modified review'); Popup.Close;
      end);
    frmMain.ipnlAuthors.DetailsButton.Click;
  finally
    if OldLocal then Include(BookData.BookProps, bpIsLocal);
  end;
  Writeln('PASS card bottom button opens common book and author information');
  PhotoHash := '323283b6c184ad7fcabf271fbe3ea655'; // independently generated fixture name
  Require(AuthorNameHash('  Толстой' + #9 + 'Лев   Николаевич ') = PhotoHash,
    'Author hash differs from FLibrary fullname normalization: ' + AuthorNameHash('Толстой Лев Николаевич'));
  Information := ReadAuthorInformation(Settings.AppPath + 'authors', 'Толстой Лев Николаевич');
  Require(Information.Found and (Pos('Русский писатель', Information.HTML) > 0),
    'Real PPMd author archive did not decode UTF-8');
  Require(not ReadAuthorInformation(Settings.AppPath + 'authors', 'Другой Автор').Found,
    'Unknown author matched another biography');
  Before := TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(Information.SourceFile));
  Details := TfrmBookDetails.Create(nil);
  try
    Details.Caption := 'HomeLib Ru — информация о книге';
    Details.AuthorInformation.Configure(Settings.AppPath, '', ['Толстой Лев Николаевич'], nil);
    Require(Details.AuthorInformation.Text.Text = '', 'Book information loaded biography eagerly');
    Details.pcBookInfo.ActivePage := Details.AuthorTab; Details.pcBookInfo.OnChange(nil);
    WaitForAuthor;
    Require(Pos('Русский писатель', Details.AuthorInformation.Text.Text) > 0, 'Biography did not reach common book information window');
    Require(not Details.AuthorInformation.Photographs.Expanded and
      (Details.AuthorInformation.Photographs.ImageCount = 0), 'Author photographs loaded before expansion');
    Details.AuthorInformation.Photographs.Expanded := True;
    Started := GetTickCount64;
    while Details.AuthorInformation.Photographs.Loading do
    begin
      Application.ProcessMessages; CheckSynchronize(10);
      Require(GetTickCount64 - Started < 15000, 'Photographs did not finish');
    end;
    Require(Details.AuthorInformation.Photographs.ImageCount = 1, 'Author photograph boundary leaked another author or failed to decode');
    if ParamStr(2) = 'visual' then Details.ShowModal;
    Require(Before = TNetEncoding.Base64.EncodeBytesToString(TFile.ReadAllBytes(Information.SourceFile)), 'Biography source changed');
    Details.AuthorInformation.Configure('', '', ['Другой Автор'], nil);
    Details.AuthorInformation.Activate;
    Require(Pos('В INPX нет биографий', Details.AuthorInformation.Status.Caption) = 1, 'Missing author packs not explained');
    Details.AllowOnlineReview('https://flibusta.is/b/merged:source:1/');
    Require(not Details.btnLoadReview.Enabled, 'Merged local ID became an online book number');
  finally Details.Free; end;
  Details := TfrmBookDetails.Create(nil);
  Details.AuthorInformation.Configure(Settings.AppPath, '', ['Толстой Лев Николаевич'], nil);
  Details.AuthorInformation.Activate; Details.Free; CheckSynchronize(0);
  Writeln('PASS common book information loads real FLibrary biographies and isolated photographs lazily, closes safely and preserves sources');
  Parser := TReviewParser.Create; Reviews := TStringList.Create; Annotation := TStringList.Create;
  try
    Parser.ParsePage('<h2>Аннотация</h2><p>Русская &amp; аннотация</p><form></form>' +
      '<a href="/polka/show/1">Читатель</a><br><p>Очень <strong>хорошая</strong> книга</p><div></div><div id="newann"></div>',
      'https://flibusta.is/b/1/', Reviews, Annotation);
    Require((Pos('Читатель:', Reviews.Text) > 0) and (Pos('хорошая', Reviews.Text) > 0) and
      (Pos('<strong>', Reviews.Text) = 0) and (Pos('Русская & аннотация', Annotation.Text) > 0),
      'Review parser lost UTF-8, formatting or annotation');
    Require(not IsLibraryReviewURL('https://flibusta.is/b/1/?q=bad') and
      IsLibraryReviewURL('http://127.0.0.1:1234/b/1/'), 'Review URL boundaries incorrect');
  finally Parser.Free; Reviews.Free; Annotation.Free; end;
  Writeln('PASS review parser preserves Russian text and shows readable public comments');
end;

procedure TestReadFolderCleanup;
var
  Root, Converted, Persistent, Unrelated, JunctionRoot, Outside: string;
  Busy: TFileStream;
begin
  TestReaderCompatibility;
  Root := Settings.TempDir;
  Converted := TFile.ReadAllText(Settings.AppPath + 'reader-probe-path.txt', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(Root, 'ordinary.tmp'), 'root cleanup probe');
  Unrelated := TPath.Combine(Root, 'unrelated\keep.txt');
  TDirectory.CreateDirectory(ExtractFilePath(Unrelated));
  TFile.WriteAllText(Unrelated, 'unrelated directory must survive');
  Busy := TFileStream.Create(Converted, fmOpenRead or fmShareExclusive);
  try
    frmMain.ClearReadFolderExecute(nil);
    Require(FileExists(Converted), 'A reader-locked book was deleted');
    Require(not FileExists(TPath.Combine(Root, 'ordinary.tmp')), 'Other temporary files were not cleaned');
  finally
    Busy.Free;
  end;
  frmMain.ClearReadFolderExecute(nil);
  Require(not FileExists(Converted), 'Converted reader copy survived explicit cleanup');
  Require(not DirectoryExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER)), 'Empty converted reader folder survived cleanup');
  Require(FileExists(Unrelated), 'Cleanup recursed into an unrelated directory');
  frmMain.ClearReadFolderExecute(nil);
  Writeln('PASS manual reader cleanup removes converted copies, preserves unrelated folders and retries busy files');

  Persistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(Persistent);
  MakeCleanupFixture(Root);
  TFile.WriteAllText(TPath.Combine(Persistent,'homelib-old.fb2'),'owned reader cache');
  TFile.WriteAllText(TPath.Combine(Persistent,'homelib-old.fb2.source'),'owned stamp');
  Settings.ReadDir := Persistent;
  frmMain.ClearReadFolderExecute(nil);
  Require(FileExists(TPath.Combine(Persistent,'ordinary.tmp')) and
    FileExists(TPath.Combine(Persistent,WEBP_READER_CACHE_FOLDER+'\copy.fb2')) and
    not FileExists(TPath.Combine(Persistent,'homelib-old.fb2')),'Custom reader cleanup must preserve unowned files');
  Require(FileExists(TPath.Combine(Root, 'ordinary.tmp')) and
    FileExists(TPath.Combine(Root, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Custom reader cleanup changed the default temp folder');
  Writeln('PASS custom reading folder is cleared safely: only owned stamped copies, personal files preserved');

  // The Node wrapper creates this junction entirely inside its owned runtime.
  JunctionRoot := TPath.Combine(Settings.AppPath, 'junction-reading');
  Outside := TPath.Combine(Settings.AppPath, 'junction-target\keep.fb2');
  Require(FileExists(Outside) and DirectoryExists(TPath.Combine(JunctionRoot, WEBP_READER_CACHE_FOLDER)), 'Junction fixture is absent');
  Settings.ReadDir := JunctionRoot;
  frmMain.ClearReadFolderExecute(nil);
  Require(FileExists(Outside), 'Cleanup followed the cache junction into another folder');
  Require(FileExists(TPath.Combine(JunctionRoot,'ordinary.tmp')),'Legacy cleanup deleted unowned file next to junction');
  Settings.ReadDir := '';
  Writeln('PASS reader cleanup does not follow a converted-cache junction');
end;

procedure TestExitReaderCleanup;
var
  Book: PBookRecord;
begin
  TestReaderCompatibility;
  CleanupExitTemp := Settings.TempDir;
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  CleanupExitSource := Book.GetBookFileName;
  MakeCleanupFixture(CleanupExitTemp);
  CleanupExitPersistent := TPath.Combine(Settings.AppPath, 'persistent-reading');
  MakeCleanupFixture(CleanupExitPersistent);
  Settings.ReadDir := CleanupExitPersistent;
end;

procedure CheckExitReaderCleanup;
begin
  Require(not FileExists(TPath.Combine(CleanupExitTemp, 'ordinary.tmp')) and
    not DirectoryExists(TPath.Combine(CleanupExitTemp, WEBP_READER_CACHE_FOLDER)), 'Main-form destruction left temporary reader copies');
  Require(FileExists(TPath.Combine(CleanupExitPersistent, 'ordinary.tmp')) and
    FileExists(TPath.Combine(CleanupExitPersistent, WEBP_READER_CACHE_FOLDER + '\copy.fb2')), 'Exit removed persistent custom reading files');
  Require(FileExists(CleanupExitSource), 'Exit removed the original library book');
  Writeln('PASS real main-form exit removes temporary converted copies and preserves custom reading files and originals');
end;

function AddBook(const Collection: IBookCollection; const Title, Author,
  Lang, Series, Genre: string; Deleted: Boolean = False): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := Title;
  Book.FileExt := '.fb2';
  Book.LibID := Title;
  Book.Lang := Lang;
  Book.Series := Series;
  Book.Date := EncodeDate(2020, 1, 1);
  Book.Size := 100; // Ordinary fixture books are not deleted zero-size placeholders.
  TAuthorsHelper.Add(Book.Authors, Author, 'Alex', '');
  if Genre <> '' then
    if Pos('0.', Genre) = 1 then
      TGenresHelper.Add(Book.Genres, Genre, '', '')
    else
      TGenresHelper.Add(Book.Genres, '', '', Genre);
  Include(Book.BookProps, bpIsLocal);
  if Deleted then
    Include(Book.BookProps, bpIsDeleted);
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Fixture book was not inserted');
end;

function SourceBookMapping(const Target: IBookCollection; const Source: TMergeSource;
  BookID: Integer): Integer;
var Book: TBookRecord;
begin
  Source.Collection.GetBookRecord(CreateBookKey(BookID, Source.Collection.CollectionID), Book, False);
  Result := Target.GetCatalogBookID(MergeSourceKey(Source, Book));
end;

procedure TestSourceKeyCollisions;
var Source, Target: IBookCollection; SourceID, TargetID, A, B, C, D, Anchor, Count: Integer;
  Book, Moved: TBookRecord; Sources: TMergeSources; Shifted: TMergeSource;
  Plan: TCollectionMergePlan; Policy: TCollectionMergePolicy; Iterator: IBookIterator;
  procedure Locate(ID: Integer; const FileName, LibID, Ext: string);
  begin
    Source.GetBookRecord(CreateBookKey(ID, SourceID), Book, True);
    Book.FileName := FileName; Book.LibID := LibID; Book.FileExt := Ext;
    Source.UpdateBook(Book);
  end;
begin
  SourceID := SystemDB.CreateCollection('Collision source', Settings.AppPath+'collision-root\',
    'collision-source.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath+'genres_fb2.glst');
  Source := SystemDB.GetCollection(SourceID);
  A := AddBook(Source,'Alpha','Author','ru','','prose_contemporary');
  B := AddBook(Source,'Beta','Author','ru','','prose_contemporary');
  C := AddBook(Source,'Alpha','Author','ru','','prose_contemporary');
  D := AddBook(Source,'Alpha','Author','ru','','prose_contemporary');
  Locate(A,'alpha','42','.fb2'); Locate(B,'beta','42','.fb2');
  Locate(C,'alpha','42','.pdf'); Locate(D,'alpha','43','.fb2');
  SetLength(Sources,1); Sources[0].ID := 'collision'; Sources[0].Name := 'Collision';
  Sources[0].Collection := Source; Sources[0].Root := Source.CollectionRoot;
  Sources[0].LibraryNamespace := 'flibusta';
  Sources[0].DatabaseFile := SystemDB.GetCollectionInfo(SourceID).DBFileName;
  Source.GetBookRecord(CreateBookKey(A,SourceID),Book,False);
  Shifted := Sources[0]; Shifted.Root := Settings.AppPath+'moved-collision-root\';
  Moved := Book; Moved.CollectionRoot := Shifted.Root;
  Require(MergeSourceKey(Sources[0],Book)=MergeSourceKey(Shifted,Moved),
    'Source file identity changes when its root moves');
  for Policy := Low(TCollectionMergePolicy) to High(TCollectionMergePolicy) do
  begin
    TargetID := SystemDB.CreateCollection('Collision target '+IntToStr(Ord(Policy)), Settings.AppPath,
      'collision-target-'+IntToStr(Ord(Policy))+'.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath+'genres_fb2.glst');
    Target := SystemDB.GetCollection(TargetID);
    Anchor := AddBook(Target,'Unrelated legacy book','Author','ru','','prose_contemporary');
    Target.SetCatalogBookID('collision:42',Anchor);
    Plan := TCollectionMergePlan.Create(Target,Sources,nil,Policy);
    try
      Plan.Preview;
      Require((Plan.NewBooks=3) and (Plan.Duplicates=1),'Colliding IDs/physical alias preview is wrong');
      Require(Plan.SourceLookupCount=0,'Legacy-only catalog still performs impossible stable-key lookups');
      Plan.Apply(Settings.AppPath+'collision-backup-'+IntToStr(Ord(Policy)));
      Iterator := Target.GetBookIterator(bmAll,False); Count := 0;
      while Iterator.Next(Book) do Inc(Count);
      Require(Count=4,'Colliding numeric IDs overwrite different files or formats');
      Require(SourceBookMapping(Target,Sources[0],A)=SourceBookMapping(Target,Sources[0],D),
        'Physical file alias was duplicated');
      Require(SourceBookMapping(Target,Sources[0],A)<>SourceBookMapping(Target,Sources[0],B),
        'Different titles with the same ID collapsed');
      Require(SourceBookMapping(Target,Sources[0],A)<>SourceBookMapping(Target,Sources[0],C),
        'Different formats with the same ID collapsed');
      Target.GetBookRecord(CreateBookKey(Anchor,TargetID),Book,False);
      Require(Book.Title='Unrelated legacy book','Old ambiguous source link replaced an unrelated book');
      Plan.Preview; Require(Plan.NewBooks=0,'Repeated collision-safe merge adds books');
      Require(Plan.SourceLookupCount>0,'Repeated merge skips existing stable source links');
      var OriginalRoot:=Source.CollectionRoot;
      Plan.Free; Plan:=nil;
      try
        Source.SetProperty(PROP_ROOTFOLDER,Shifted.Root); Sources[0].Root:=Shifted.Root;
        Plan:=TCollectionMergePlan.Create(Target,Sources,nil,Policy); Plan.Preview;
        Require((Plan.NewBooks=0) and (Plan.SourceLookupCount>0),'Moving a source root loses stable links');
        Plan.Apply(Settings.AppPath+'moved-collision-backup-'+IntToStr(Ord(Policy)));
        Require(SourceBookMapping(Target,Sources[0],A)=SourceBookMapping(Target,Sources[0],D),'Moved physical aliases lose their shared book');
      finally Source.SetProperty(PROP_ROOTFOLDER,OriginalRoot); Sources[0].Root:=OriginalRoot; end;
    finally Plan.Free; end;
  end;
  Writeln('PASS repeated source IDs retain distinct titles/formats, physical aliases match preview, moved roots stay stable and legacy ambiguous links are ignored');
end;

procedure TestMergePolicies;
var HighSource, LowSource, Target: IBookCollection; Sources: TMergeSources;
  Policy: TCollectionMergePolicy; Plan: TCollectionMergePlan;
  Book, Stored, Original, Resolved: TBookRecord; TargetID, ID, I, Count: Integer;
  Iterator: IBookIterator; Copies: TArray<TBookRecord>; BasePath: string;
  procedure Configure(const Collection: IBookCollection; const FileName: string; Size: Integer);
  var BookID: Integer;
  begin
    BookID := AddBook(Collection, 'Same edition', 'Author', 'ru', 'Same cycle', 'detective');
    Collection.GetBookRecord(CreateBookKey(BookID, Collection.CollectionID), Book, False);
    Book.LibID := '42'; Book.Folder := Settings.AppPath; Book.FileName := FileName;
    Book.FileExt := '.fb2'; Book.Size := Size; Include(Book.BookProps, bpIsLocal);
    Collection.UpdateBook(Book);
    TFile.WriteAllText(Book.GetBookFileName, '<FictionBook><body>' + FileName + '</body></FictionBook>', TEncoding.UTF8);
  end;
begin
  I := SystemDB.CreateCollection('Policy high', Settings.AppPath, 'policy-high.hlc2',
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst'); HighSource := SystemDB.GetCollection(I);
  I := SystemDB.CreateCollection('Policy low', Settings.AppPath, 'policy-low.hlc2',
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst'); LowSource := SystemDB.GetCollection(I);
  Configure(HighSource, 'policy-high', 100); Original := Book;
  Configure(LowSource, 'policy-low', 50);
  Require(BookLibraryIdentity(Original, 'flibusta') = BookLibraryIdentity(Book, 'flibusta'),
    'Size difference hides equal library IDs');
  Require(BookLibraryIdentity(Original, 'flibusta') <> BookLibraryIdentity(Book, 'librusec'),
    'Equal numeric IDs from different libraries collide');
  Book.Title := 'Different edition';
  Require(BookLibraryIdentity(Original, 'flibusta') <> BookLibraryIdentity(Book, 'flibusta'), 'Different titles collapse');
  Book := Original; Book.Lang := 'en';
  Require(BookLibraryIdentity(Original, 'flibusta') <> BookLibraryIdentity(Book, 'flibusta'), 'Different languages collapse');
  Book := Original; Include(Book.BookProps,bpIsDeleted);
  Require(BookLibraryIdentity(Book,'flibusta')='', 'Deleted placeholders qualify for merging');
  Require(BookLibraryIdentity(Original,'')='', 'Unknown numeric origin qualifies for merging');
  Book := Original; Book.LibID := 'merged:{A}:flibusta:42';
  Require(BookLibraryIdentity(Book,'')=BookLibraryIdentity(Original,'flibusta'), 'Scoped merged identity is lost');
  SetLength(Sources,2);
  Sources[0].ID := 'policy-high'; Sources[0].Name := 'High'; Sources[0].Collection := HighSource;
  Sources[0].DatabaseFile := SystemDB.GetCollectionInfo(HighSource.CollectionID).DBFileName;
  Sources[1].ID := 'policy-low'; Sources[1].Name := 'Low'; Sources[1].Collection := LowSource;
  Sources[1].DatabaseFile := SystemDB.GetCollectionInfo(LowSource.CollectionID).DBFileName;
  for Policy := Low(TCollectionMergePolicy) to High(TCollectionMergePolicy) do
  begin
    Sources[0].LibraryNamespace := 'flibusta'; Sources[1].LibraryNamespace := 'flibusta';
    TargetID := SystemDB.CreateCollection('Policy target ' + IntToStr(Ord(Policy)), Settings.AppPath,
      'policy-target-' + IntToStr(Ord(Policy)) + '.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
    Target := SystemDB.GetCollection(TargetID); Target.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
    Configure(Target,'policy-base-' + IntToStr(Ord(Policy)),300); ID := Book.BookKey.BookID;
    Target.SetRate(Book.BookKey,5); Target.SetProgress(Book.BookKey,72);
    Plan := TCollectionMergePlan.Create(Target,Sources,nil,Policy);
    try
      Plan.Preview;
      if Policy=mpKeepAll then Require((Plan.NewBooks=2) and (Plan.Duplicates=0),'Default merges different copies')
      else Require((Plan.NewBooks=0) and (Plan.Duplicates=2),'Verified IDs are not previewed as copies');
      Plan.Apply(Settings.AppPath + 'policy-backup-' + IntToStr(Ord(Policy)));
      Iterator := Target.GetBookIterator(bmAll,False); Count := 0;
      while Iterator.Next(Book) do Inc(Count);
      if Policy=mpKeepAll then Require(Count=3,'Keep-all lost a copy')
      else
      begin
        Require(Count=1,'Optional mode left duplicate book rows');
        Target.GetBookRecord(CreateBookKey(ID,TargetID),Stored,False);
        Require((Stored.Rate=5) and (Stored.Progress=72),'Optional merge lost reading progress');
        if Policy=mpSourcePriority then Require(Stored.FileName='policy-high','Source order was not used')
        else Require((Stored.FileName='policy-low') and (Stored.Size=50),'Smallest file was not selected');
        if Policy=mpSourcePriority then Require(Stored.CollectionName='High','Preferred source name is hidden')
        else Require(Stored.CollectionName='Low','Smallest source name is hidden');
        Iterator := Target.GetBookIterator(bmAll,False); Require(Iterator.Next(Book), 'Merged iterator is empty');
        Require(Book.CollectionName=Stored.CollectionName,'Streamed list lost preferred source name'); Iterator := nil;
        Copies := Target.GetCatalogBookCopies(Stored.BookKey); Require(Length(Copies)>=3,'Original paths were lost');
        BasePath := Stored.GetBookFileName; TFile.Move(BasePath,BasePath+'.busy');
        try
          Resolved := ResolveReaderBook(Target,Stored);
          Require(FileExists(Resolved.GetBookFileName) and (Resolved.Title=Stored.Title), 'Missing preferred copy has no fallback');
        finally TFile.Move(BasePath+'.busy',BasePath); end;
        Plan.Preview; Plan.Apply(Settings.AppPath+'policy-repeat-'+IntToStr(Ord(Policy)));
        Iterator := Target.GetBookIterator(bmAll,False); Count := 0; while Iterator.Next(Book) do Inc(Count);
        Require(Count=1,'Repeated optional merge duplicates records');
      end;
    finally Plan.Free; end;
  end;
  HighSource.GetBookRecord(Original.BookKey,Stored,False);
  Require((Stored.LibID=Original.LibID) and (Stored.FileName=Original.FileName) and
    (Stored.Title=Original.Title),'Optional merge modified source catalog');
  Writeln('PASS optional copy merging verifies origin, ID, title, language and format, preserves sources and alternatives, and honors priority or size');
end;

procedure EnableScaleFixtureTriggers(Context: TSQLite3Context; ArgumentCount: Integer; Arguments: TSQLite3Value); cdecl;
begin
  SQLite3_Result_Int(Context,1);
end;

procedure TestOctoberElevenUI;
var Configuration: TfrmSettings; Reader: TfrmBuiltinReader; Component: TComponent;
  ThemeButton: TToolButton; Item: TMenuItem; Captions: TStringList; I: Integer;
  Background,TextColour: TColor; Deadline: UInt64; Column: TVirtualTreeColumn;
begin
  Require(not Settings.DarkTheme,'Fresh fixture unexpectedly starts dark');
  Require(MHLShouldOfferWindowsDarkTheme(True,False,False),'Windows dark theme is not offered');
  Require(not MHLShouldOfferWindowsDarkTheme(True,False,True),'Dismissed suggestion is repeated');
  Require(not MHLShouldOfferWindowsDarkTheme(True,True,False),'Matching theme is offered again');
  Require(not MHLShouldOfferWindowsDarkTheme(False,False,False),'Light Windows incorrectly offers dark');
  Require((Settings.InpxURL='') and (Settings.UpdateURL=''),'Fresh fixture retains dead catalog servers');
  ThemeButton:=nil;
  for Component in frmMain do
    if (Component is TToolButton) and (TToolButton(Component).ImageIndex=25) then ThemeButton:=TToolButton(Component);
  Require(Assigned(ThemeButton),'Main toolbar has no theme switch');
  frmMain.Show; Application.ProcessMessages;
  Require((ThemeButton.Parent.Parent=frmMain) and (ThemeButton.Parent.Left>frmMain.ClientWidth-80),
    'Theme switch is not at the right edge');
  Captions:=TStringList.Create;
  try
    for I:=0 to frmMain.pmiReadBook.Parent.Count-1 do
    begin Item:=frmMain.pmiReadBook.Parent.Items[I]; if Item.Visible then Captions.Add(Item.Caption); end;
    Require((Captions.Count>=2) and Captions[0].Contains('встроенной') and Captions[1].Contains('внешней'),
      'Read destinations are duplicated or incorrectly ordered: '+Captions.Text);
  finally Captions.Free; end;
  for I:=0 to frmMain.tvBooksA.Header.Columns.Count-1 do
  begin
    Column:=frmMain.tvBooksA.Header.Columns[I];
    if (Column.Tag=COL_LANG) or (Column.Tag=COL_TYPE) then
      Require((coResizable in Column.Options) and (Column.MaxWidth>Column.MinWidth), 'Language/type column remains fixed width');
  end;
  Configuration:=TfrmSettings.Create(nil); Reader:=TfrmBuiltinReader.Create(nil);
  try
    Configuration.LoadSetting;
    Background:=Configuration.pnCA.Color; TextColour:=Configuration.pnDefaultFontColor.Font.Color;
    TFile.WriteAllText('theme-reader.txt','Theme readability test.');
    Reader.Show; Reader.OpenBook('theme-reader.txt','Theme reader','theme-reader','theme-reader.ini','');
    Deadline:=GetTickCount64+15000;
    while not Reader.LoadFinished and (GetTickCount64<Deadline) do begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(Reader.Ready,'Theme reader failed to open');
    ThemeButton.OnClick(ThemeButton); Application.ProcessMessages;
    Require(TStyleManager.ActiveStyle.Name='Charcoal Dark Slate','Dark menu/control style was not activated');
    Require(Settings.DarkTheme and MHLThemeDark,'Theme switch failed');
    Require(ColorToRGB(frmMain.tvBooksA.Color)=RGB(30,31,34),'Book table stayed light');
    Require(ColorToRGB(frmMain.tvBooksA.Font.Color)=RGB(205,208,214),'Book text lacks dark-theme contrast');
    Require(Reader.ThemeIndex=4,'Open reader did not follow dark theme');
    Require((Configuration.pnCA.Color=Background) and (Configuration.pnDefaultFontColor.Font.Color=TextColour),
      'Theme switch overwrote user colour previews');
    Configuration.SaveSettings;
    Require((Settings.AuthorColor=Background) and (Settings.FontColor=TextColour),'Saving dark settings corrupts light colours');
    ThemeButton.OnClick(ThemeButton); Application.ProcessMessages;
    Require(not Settings.DarkTheme and not MHLThemeDark,'Light theme was not restored');
    Require(Reader.ThemeIndex=1,'Open reader did not return to paper');
    Require((Configuration.pnCA.Color=Background) and (Configuration.pnDefaultFontColor.Font.Color=TextColour),
      'Returning to light theme overwrote user colour previews');
    Settings.WindowsDarkThemeOfferDismissed:=False;
    frmMain.UpdateWindowsThemeOffer(True);
    Require(TPanel(frmMain.FindComponent('pnWindowsThemeOffer')).Visible,'Windows theme suggestion is hidden');
    TButton(frmMain.FindComponent('btnDismissWindowsTheme')).Click;
    frmMain.UpdateWindowsThemeOffer(True);
    Require(Settings.WindowsDarkThemeOfferDismissed and not TPanel(frmMain.FindComponent('pnWindowsThemeOffer')).Visible,
      'Dismissing the Windows theme suggestion is not retained');
    Settings.WindowsDarkThemeOfferDismissed:=False; Settings.LoadSettings;
    Require(Settings.WindowsDarkThemeOfferDismissed,'Dismissed Windows suggestion is not saved across startup');
    Require(TPanel(frmMain.FindComponent('pnWindowsThemeOffer')).Caption='','Suggestion shows an internal panel name');
    frmMain.UpdateWindowsThemeOffer(False); frmMain.UpdateWindowsThemeOffer(True);
    Require(TPanel(frmMain.FindComponent('pnWindowsThemeOffer')).Visible,'A new Windows dark-theme cycle is not offered');
    TButton(frmMain.FindComponent('btnApplyWindowsTheme')).Click; Application.ProcessMessages;
    Require(Settings.DarkTheme and (Reader.ThemeIndex=4),'Windows suggestion does not apply app/reader theme');
    ThemeButton.OnClick(ThemeButton); Application.ProcessMessages;
    Writeln('PASS Windows dark-theme suggestion, dismissal and reader synchronization without changing Windows');
    Writeln('PASS app theme switch, reader synchronization, preserved colour settings, explicit read menus and resizable language/type'); Flush(Output);
    if ParamStr(2)='visual' then
    begin
      Reader.Close; Settings.WindowsDarkThemeOfferDismissed:=False;
      frmMain.UpdateWindowsThemeOffer(True); frmMain.Show; Application.Run;
    end;
  finally Reader.Free; Configuration.Free; end;
end;

procedure TestUpdateNotesTheme;
var Popup: TfrmProgramUpdate; View: TUpdateNotesView; Info: TProgramRelease;
  SavedDark: Boolean; I, SelectedStart, SelectedCount: Integer; Text: string;
  procedure RequireForeground(Body: TRichEdit);
  begin
    Body.SelStart := Body.FindText('Проверяемый',0,MaxInt,[]); Body.SelLength := 5;
    Require(Body.SelStart >= 0,'Theme fixture text missing');
    Require(ColorToRGB(Body.SelAttributes.Color)=ColorToRGB(MHLThemeText),
      'Formatted update text ignores the current foreground');
  end;
begin
  SavedDark := MHLThemeDark; SetMHLTheme(True);
  Popup := CreateTestProgramUpdate;
  try
    View := nil;
    for I := 0 to Popup.ControlCount-1 do
      if Popup.Controls[I] is TUpdateNotesView then View := TUpdateNotesView(Popup.Controls[I]);
    Require(Assigned(View),'Update notes view missing');
    Info := Default(TProgramRelease); Info.Tag := PROGRAM_RELEASE_VERSION;
    Info.History := PROGRAM_RELEASE_VERSION+#10+'## Проверяемый заголовок'+#10+
      '- Проверяемый **жирный** текст'+#10+'  - Дочерний пункт'+#10+#10+
      '2.7.0_pre5.14'+#10+'Проверяемый предыдущий выпуск';
    Popup.SetCurrent(Info); Application.ProcessMessages;
    View.SetExpanded(1,True); View.ZoomPercent := 140;
    RequireForeground(View.PrimaryNotes); RequireForeground(View.SectionNotes(1));
    Require(ColorToRGB(View.PrimaryNotes.Color)=RGB(30,31,34),'Update body background is light');
    Text := View.PrimaryNotes.Text;
    View.PrimaryNotes.SelStart := View.PrimaryNotes.FindText('жирный',0,MaxInt,[]);
    View.PrimaryNotes.SelLength := Length('жирный');
    Require(fsBold in View.PrimaryNotes.SelAttributes.Style,'Theme removes inline emphasis');
    SelectedStart := View.PrimaryNotes.SelStart; SelectedCount := View.PrimaryNotes.SelLength;
    SetMHLTheme(False);
    Require((View.PrimaryNotes.SelStart=SelectedStart) and (View.PrimaryNotes.SelLength=SelectedCount),
      'Theme switch resets text selection');
    Require((View.PrimaryNotes.Text=Text) and (View.ZoomPercent=140) and View.IsExpanded(1),
      'Theme switch resets content, zoom or expanded releases');
    Require(fsBold in View.PrimaryNotes.SelAttributes.Style,'Theme switch removes inline emphasis');
    RequireForeground(View.PrimaryNotes);
    Require(ColorToRGB(View.PrimaryNotes.Color)=ColorToRGB(clWindow),'Light update body was not restored');
    SetMHLTheme(True); View.ZoomPercent := 90; RequireForeground(View.PrimaryNotes);
    Info.ComponentID := 'SQLite'; Info.ComponentVersion := '3.54.0';
    Info.History := '3.54.0'+#10+'Проверяемый текст другого компонента';
    Popup.SetCurrent(Info); RequireForeground(View.PrimaryNotes);
    Writeln('PASS update notes retain visible dark/light foreground, content, selection, emphasis, zoom and component switching');
    Flush(Output);
  finally Popup.Free; SetMHLTheme(SavedDark); end;
end;

procedure TestSchemaReopenSafety;
var Collection, Reopened: IBookCollection; Info: TCollectionInfo; ID, BookID, Schema, Revision: Integer;
  DB, Writer: TSQLiteDatabase; ExpectedTrigger: string; Book: TBookRecord;
begin
  ID:=SystemDB.CreateCollection('Schema reopen safety',Settings.AppPath,'schema-reopen.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(ID); Info:=SystemDB.GetCollectionInfo(ID);
  BookID:=AddBook(Collection,'Preserved schema book','Writer','ru','Primary cycle','prose_contemporary');
  Collection.AddBookSeries(BookID,'Secondary cycle',7);
  Collection.SetRate(CreateBookKey(BookID,ID),5); Collection.SetProgress(CreateBookKey(BookID,ID),38);
  Collection.SetReview(CreateBookKey(BookID,ID),'Личная мысль 😀');
  DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
  try
    Schema:=DB.QuerySingleInt('PRAGMA schema_version'); Revision:=DB.QuerySingleInt('PRAGMA data_version');
    ExpectedTrigger:=DB.QuerySingleString('SELECT sql FROM sqlite_master WHERE name=''TRBooks_BD''');
    for var I:=1 to 4 do
    begin
      Reopened:=TBookCollection_SQLite.Create(Info,SystemDB); Reopened:=nil;
      Require(DB.QuerySingleInt('PRAGMA schema_version')=Schema,'Opening an up-to-date catalog rewrites its triggers');
      Require(DB.QuerySingleInt('PRAGMA data_version')=Revision,'Opening an up-to-date catalog commits a database mutation');
    end;
    Writer:=TSQLiteDatabase.Create(Info.DBFileName);
    try
      Writer.ExecSQL('DROP TRIGGER TRBooks_BD');
      Writer.ExecSQL('CREATE TRIGGER TRBooks_BD BEFORE DELETE ON Books BEGIN SELECT 1; END');
    finally Writer.Free; end;
    Reopened:=TBookCollection_SQLite.Create(Info,SystemDB); Reopened:=nil;
    Require(DB.QuerySingleString('SELECT sql FROM sqlite_master WHERE name=''TRBooks_BD''')=ExpectedTrigger,'Legacy cleanup trigger was not repaired');
    Schema:=DB.QuerySingleInt('PRAGMA schema_version'); Revision:=DB.QuerySingleInt('PRAGMA data_version');
    Reopened:=TBookCollection_SQLite.Create(Info,SystemDB); Reopened:=nil;
    Require((DB.QuerySingleInt('PRAGMA schema_version')=Schema) and (DB.QuerySingleInt('PRAGMA data_version')=Revision),'A repaired catalog is still rewritten on reopen');
    Collection.GetBookRecord(CreateBookKey(BookID,ID),Book,True);
    Require((Book.Title='Preserved schema book') and (Book.Rate=5) and (Book.Progress=38) and
      (Book.Review='Личная мысль 😀') and (Length(Collection.GetBookSeries(Book.BookKey))=2),'Schema reopen/repair changed books or personal fields');
    Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Schema reopen damaged integrity');
  finally Reopened:=nil; DB.Free; end;
  Writeln('PASS current catalogs reopen without schema/data writes; legacy triggers repair once and preserve books, reviews, ratings, progress and secondary series');
end;

procedure TestMetadataDeltaSafety;
const Fields='Title,Folder,FileName,Ext,InsideNo,SeqNumber,BookSize,LibID,IsDeleted,IsLocal,UpdateDate,Lang,LibRate,KeyWords,Rate,Progress,Review,Annotation,Translators,Publisher,City,PubYear,ISBN,SeriesID,SearchTitle,SearchLang,SearchFolder,SearchFileName,SearchExt,SearchKeyWords,SearchAnnotation';
var Target: IBookCollection; Full: IBookMergeMetadataUpdater; Delta: IBookMergeMetadataDeltaUpdater;
  TargetID, A, B, Step: Integer; Original, Before, Value, Stored: TBookRecord; DB: TSQLiteDatabase;
  OldRow, NewRow: TSQLiteQuery; Failed: Boolean;
  procedure EqualRows;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(TargetID).DBFileName);
    try
      OldRow:=DB.NewQuery('SELECT '+Fields+' FROM Books WHERE BookID=?');
      NewRow:=DB.NewQuery('SELECT '+Fields+' FROM Books WHERE BookID=?');
      try
        OldRow.SetParam(0,A); NewRow.SetParam(0,B); OldRow.Open; NewRow.Open;
        for var I:=0 to 30 do
          if I=16 then Require(OldRow.FieldAsBlobString(I)=NewRow.FieldAsBlobString(I),'Delta changed review bytes at step '+IntToStr(Step))
          else Require(OldRow.FieldAsString(I)=NewRow.FieldAsString(I),'Delta field '+IntToStr(I)+' differs at step '+IntToStr(Step));
      finally NewRow.Free; OldRow.Free; end;
      Require(DB.QuerySingleString('SELECT group_concat(SeriesID||'':''||IFNULL(SeqNumber,0)||'':''||IsPrimary) FROM (SELECT * FROM Series_List WHERE BookID=? ORDER BY SeriesID)',[A])=
        DB.QuerySingleString('SELECT group_concat(SeriesID||'':''||IFNULL(SeqNumber,0)||'':''||IsPrimary) FROM (SELECT * FROM Series_List WHERE BookID=? ORDER BY SeriesID)',[B]),'Delta changed series membership');
    finally DB.Free; end;
  end;
begin
  TargetID:=SystemDB.CreateCollection('Metadata delta',Settings.AppPath,'metadata-delta.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Target:=SystemDB.GetCollection(TargetID);
  Require(Supports(Target,IBookMergeMetadataUpdater,Full) and Supports(Target,IBookMergeMetadataDeltaUpdater,Delta),'Delta path was not built');
  A:=AddBook(Target,'Delta baseline','Автор','ru','Cycle','prose_contemporary');
  B:=AddBook(Target,'Delta baseline','Автор','ru','Cycle','prose_contemporary');
  Target.GetBookRecord(CreateBookKey(A,TargetID),Original,True);
  Original.PublisherSeriesKnown:=False; Original.Rate:=5; Original.Progress:=72; Original.Review:='Личная мысль 😀';
  Target.AddBookToGroup(CreateBookKey(A,TargetID),FAVORITES_GROUP_ID);
  Target.AddBookToGroup(CreateBookKey(B,TargetID),FAVORITES_GROUP_ID);
  Target.AddBookSeries(A,'Secondary preserved',9); Target.AddBookSeries(B,'Secondary preserved',9);
  for Step:=0 to 26 do
  begin
    Target.BeginBulkOperation; SystemDB.BeginDataUpdate;
    try
      Original.BookKey:=CreateBookKey(A,TargetID); Full.UpdateBookPreservingSeries(Original);
      Original.BookKey:=CreateBookKey(B,TargetID); Full.UpdateBookPreservingSeries(Original);
      Target.GetBookRecord(CreateBookKey(B,TargetID),Before,True); Value:=Before; Value.PublisherSeriesKnown:=False;
      case Step of
        0: Value.Title:='Новое название ё 日本語';
        1: Value.Folder:='archive-new.zip';
        2: Value.FileName:='новый файл';
        3: Value.FileExt:='epub';
        4: Value.InsideNo:=87;
        5: Value.SeqNumber:=41;
        6: Value.Size:=987654;
        7: Value.LibID:='flibusta:12345';
        8: Include(Value.BookProps,bpIsDeleted);
        9: Exclude(Value.BookProps,bpIsLocal);
        10: Value.Date:=EncodeDate(2026,10,13)+EncodeTime(4,27,15,123);
        11: Value.Lang:='be';
        12: Value.LibRate:=3;
        13: Value.KeyWords:='ключевые слова Ελληνικά';
        14: Value.Rate:=2;
        15: Value.Progress:=34;
        16: Value.Review:='  Новая мысль 😀  ';
        17: Value.Annotation:='Аннотация עברית';
        18: Value.Translators:='Новый переводчик';
        19: Value.Publisher:='Издатель';
        20: Value.City:='Минск';
        21: Value.PubYear:=2024;
        22: Value.ISBN:='978-0-123456-00-1';
        23: Value.Series:='New primary';
        24: begin Value.Series:=''; Value.SeqNumber:=47; end;
        25: begin Value.Title:='Several fields'; Value.Folder:='other.zip'; Value.Size:=1456; Value.Review:=''; Value.Rate:=3; Value.Progress:=42; Value.PubYear:=0; end;
        26: begin Value.Title:=''; Value.SeqNumber:=9000; Value.Annotation:=''; end;
      end;
      Delta.UpdateBookMetadataDelta(Before,Value);
      Value.BookKey:=CreateBookKey(A,TargetID); Full.UpdateBookPreservingSeries(Value);
      Target.EndBulkOperation(True); SystemDB.EndDataUpdate(True);
    except if Target.InBulkOperation then Target.EndBulkOperation(False); SystemDB.EndDataUpdate(False); raise; end;
    EqualRows;
  end;
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try
    var Q:=DB.NewQuery('UPDATE Books SET Review=? WHERE BookID=?');
    try Q.SetBlobParam(0,#13#10+'  Личная мысль 😀  '+#13#10); Q.SetParam(1,B); Q.ExecSQL; finally Q.Free; end;
  finally DB.Free; end;
  Target.GetBookRecord(CreateBookKey(B,TargetID),Before,True); Value:=Before; Value.PublisherSeriesKnown:=False;
  Value.Review:=Before.Review+#13#10+'[Другой источник]'+#13#10+'Дополнение';
  Target.BeginBulkOperation; SystemDB.BeginDataUpdate;
  try Delta.UpdateBookMetadataDelta(Before,Value); Target.EndBulkOperation(True); SystemDB.EndDataUpdate(True);
  except if Target.InBulkOperation then Target.EndBulkOperation(False); SystemDB.EndDataUpdate(False); raise; end;
  Require(Target.GetReview(Value.BookKey)=Value.Review,'Delta trimmed original personal review prefix');
  Writeln('PASS metadata delta preserves exact personal review prefix and appended Unicode text');
  // Return both rows to the parity baseline before testing failure rollback.
  Target.BeginBulkOperation; SystemDB.BeginDataUpdate;
  try
    Original.BookKey:=CreateBookKey(A,TargetID); Full.UpdateBookPreservingSeries(Original);
    Original.BookKey:=CreateBookKey(B,TargetID); Full.UpdateBookPreservingSeries(Original);
    Target.EndBulkOperation(True); SystemDB.EndDataUpdate(True);
  except if Target.InBulkOperation then Target.EndBulkOperation(False); SystemDB.EndDataUpdate(False); raise; end;
  Target.GetBookRecord(CreateBookKey(B,TargetID),Before,True);
  Before.PublisherSeriesKnown:=False;
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try DB.ExecSQL('CREATE TRIGGER RejectDelta BEFORE UPDATE ON Books WHEN NEW.BookID='+IntToStr(B)+' BEGIN SELECT RAISE(ABORT,''injected delta failure''); END'); finally DB.Free; end;
  Target.BeginBulkOperation; SystemDB.BeginDataUpdate;
  try
    Delta.UpdateBookMetadataDelta(Before,Before); // No metadata write should reach the rejection trigger.
    Target.EndBulkOperation(True); SystemDB.EndDataUpdate(True);
  except if Target.InBulkOperation then Target.EndBulkOperation(False); SystemDB.EndDataUpdate(False); raise; end;
  Value:=Before; Value.Folder:='must roll back'; Failed:=False;
  Target.BeginBulkOperation; SystemDB.BeginDataUpdate;
  try Delta.UpdateBookMetadataDelta(Before,Value); except on E: Exception do Failed:=True; end;
  Target.EndBulkOperation(False); SystemDB.EndDataUpdate(False);
  Require(Failed,'Delta ignored injected write failure');
  Target.GetBookRecord(CreateBookKey(B,TargetID),Stored,True);
  Require((Stored.Folder=Before.Folder) and (Stored.Rate=Before.Rate) and (Stored.Progress=Before.Progress) and (Stored.Review=Before.Review),'Delta rollback lost metadata or personal state');
  EqualRows;
  Writeln('PASS metadata delta matches full writes for every column, Unicode, primary and secondary series; no-op and failed updates preserve user state');
end;

procedure TestBulkWriteSafety;
var Target: IBookCollection;
  TargetID, ID, I: Integer; Book, Stored: TBookRecord; Copies: TArray<TBookRecord>;
  DB: TSQLiteDatabase; Failed: Boolean;
begin
  TargetID:=SystemDB.CreateCollection('Batch writes',Settings.AppPath,'batch-writes.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Target:=SystemDB.GetCollection(TargetID);
  ID:=AddBook(Target,'Batch book','Author','ru','','prose_contemporary');
  Target.GetBookRecord(CreateBookKey(ID,TargetID),Book,True);
  Target.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
  Book.FileName:='файл_日本語'; Book.CollectionRoot:='C:\Книги'; Book.Folder:='archive.zip';
  Book.FileExt:='fb2'; Book.InsideNo:=7; Book.Size:=123456; Book.LibID:='flibusta:42';
  Target.BeginBulkOperation;
  try
    for I:=1 to 1200 do
    begin
      Target.SetCatalogBookID('key-'+IntToStr(I),ID);
      Target.SetCatalogBookCopy('key-'+IntToStr(I),'Источник '+IntToStr(I),Book);
      Target.SetCatalogBookPreferredSource(Book.BookKey,'Источник '+IntToStr(I));
    end;
    Target.SetCatalogBookID('key-1200',999999);
    Require(Target.GetCatalogBookID('key-1200')=0,'Source lookup accepts an orphan mapping');
    Target.SetCatalogBookID('key-1200',ID);
    Book.FileName:='последняя копия';
    Target.SetCatalogBookCopy('key-1200','Последний источник',Book);
    Copies:=Target.GetCatalogBookCopies(Book.BookKey);
    Require(Length(Copies)=1200,'Bulk copies are invisible or an iteration loses a row');
    Require(Target.GetCatalogBookID('key-1200')=ID,'Replacement mapping is invisible');
    Target.GetBookRecord(Book.BookKey,Stored,False);
    Require(Stored.CollectionName='Источник 1200','Preferred source is invisible');
    Target.SetCatalogBookID('tail',ID);
    Target.EndBulkOperation(True);
  except Target.EndBulkOperation(False); raise; end;
  DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM CatalogSourceBooks')=1201,'Commit omits the last bulk row');
    Require(DB.QuerySingleString('SELECT FileName FROM CatalogBookCopies WHERE SourceKey=''key-1200''')=Book.FileName,
      'Repeated copy did not keep its last value');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM CatalogBookCopies WHERE Root=? AND Ext=? AND InsideNo=? AND BookSize=?',
      [Book.CollectionRoot,Book.FileExt,Book.InsideNo,Book.Size])=1200,'Copy paths/fields changed in bulk writes');
  finally DB.Free; end;
  Target.BeginBulkOperation;
  for I:=1 to 617 do
  begin
    Target.SetCatalogBookID('rollback-'+IntToStr(I),ID);
    Target.SetCatalogBookCopy('rollback-'+IntToStr(I),'Откат',Book);
    Target.SetCatalogBookPreferredSource(Book.BookKey,'Откат');
  end;
  Target.EndBulkOperation(False);
  Require(Target.GetCatalogBookID('rollback-1')=0,'Rollback retained flushed mappings');
  Require(Target.GetCatalogBookID('rollback-617')=0,'Rollback retained the last bulk row');
  Require(Length(Target.GetCatalogBookCopies(Book.BookKey))=1200,'Rollback retained copies');
  Target.GetBookRecord(Book.BookKey,Stored,False);
  Require(Stored.CollectionName='Источник 1200','Rollback retained preferred-source cache');
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try DB.ExecSQL('CREATE TRIGGER RejectBatchCopy BEFORE INSERT ON CatalogBookCopies '+
    'WHEN NEW.SourceKey=''fail'' BEGIN SELECT RAISE(ABORT,''injected batch failure''); END');
  finally DB.Free; end;
  Target.BeginBulkOperation;
  Target.SetCatalogBookID('fail',ID);
  Failed:=False;
  try Target.SetCatalogBookCopy('fail','Fail',Book); except on E: Exception do Failed:=True; end;
  Require(Failed,'Injected failure did not interrupt bulk writes');
  Target.EndBulkOperation(False);
  Require(Target.GetCatalogBookID('fail')=0,'Partial failed writes were not rolled back');
  Target.BeginBulkOperation;
  Target.SetCatalogBookID('after-failure',ID); Target.EndBulkOperation(True);
  Require(Target.GetCatalogBookID('after-failure')=ID,'Bulk operation cannot be reused after rollback');
  Target.SetCatalogBookID('ordinary',ID);
  Require(Target.GetCatalogBookID('ordinary')=ID,'Ordinary writes became deferred');
  Writeln('PASS bulk writes preserve Unicode fields, replacements, complete commits, rollback and failure recovery'); Flush(Output);
end;

procedure BenchmarkMergeScale;
const BookCount=10000; SeriesCount=160000;
var Source,Target: IBookCollection; SourceID,TargetID,I,Anchor,BookID: Integer;
  DB: TSQLiteDatabase; Sources: TMergeSources; Plan: TCollectionMergePlan;
  SeedMS,PreviewMS,ApplyMS,Started: UInt64; RecordValue: TBookRecord;
begin
  Started:=GetTickCount64;
  SourceID:=SystemDB.CreateCollection('Merge scale source',Settings.AppPath,'merge-scale-source.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  TargetID:=SystemDB.CreateCollection('Merge scale target',Settings.AppPath,'merge-scale-target.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID); Target:=SystemDB.GetCollection(TargetID);
  Source.BeginBulkOperation; Target.BeginBulkOperation;
  try
    Anchor:=AddBook(Target,'Keep unrelated secondary series','Anchor','ru','','');
    for I:=1 to BookCount do
    begin
      AddBook(Source,'Scale '+IntToStr(I),'Author','ru','','prose_contemporary');
      AddBook(Target,'Scale '+IntToStr(I),'Author','ru','','prose_contemporary');
    end;
    Source.EndBulkOperation(True); Target.EndBulkOperation(True);
  except Source.EndBulkOperation(False); Target.EndBulkOperation(False); raise; end;
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    DB.Start;
    DB.ExecSQL('WITH RECURSIVE ids(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM ids WHERE n<'+IntToStr(SeriesCount)+') '+
      'INSERT INTO Series(SeriesID,SeriesTitle,SearchSeriesTitle) SELECT 200000+n,''Unrelated ''||n,''Unrelated ''||n FROM ids');
    DB.ExecSQL('INSERT INTO Series_List(BookID,SeriesID,SeqNumber,IsPrimary,OrdNum) SELECT '+IntToStr(Anchor)+',SeriesID,0,0,0 FROM Series');
    DB.Commit;
  finally DB.Free; end;
  SeedMS:=GetTickCount64-Started;
  SetLength(Sources,1); Sources[0].ID:='scale'; Sources[0].Name:='Scale'; Sources[0].Collection:=Source;
  Sources[0].DatabaseFile:=SystemDB.GetCollectionInfo(SourceID).DBFileName;
  Plan:=TCollectionMergePlan.Create(Target,Sources,nil,mpSourcePriority);
  try
    Started:=GetTickCount64; Plan.Preview; PreviewMS:=GetTickCount64-Started;
    Require((Plan.Total=BookCount) and (Plan.NewBooks=0) and (Plan.Duplicates=BookCount),'Large merge did not match already imported books');
    Started:=GetTickCount64; Plan.Apply(Settings.AppPath+'merge-scale-backup'); ApplyMS:=GetTickCount64-Started;
    DB:=TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(TargetID).DBFileName);
    try
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books')=BookCount+1,'Large merge duplicated existing catalog');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Series')=SeriesCount,'Large merge deleted unrelated secondary series');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List')=SeriesCount,'Large merge damaged secondary memberships');
    finally DB.Free; end;
    BookID:=SourceBookMapping(Target,Sources[0],BookCount); Require(BookID>0,'Last book lost source mapping');
    Target.GetBookRecord(CreateBookKey(BookID,TargetID),RecordValue,True);
    Require(RecordValue.Title='Scale 10000','Last merged metadata missing');
    Writeln('PROFILE merge_scale books=',BookCount,' series=',SeriesCount,' seed_ms=',SeedMS,' preview_ms=',PreviewMS,' apply_ms=',ApplyMS);
    Writeln('PASS large merge reuses imported books and preserves unrelated secondary series'); Flush(Output);
  finally Plan.Free; end;
end;

procedure BenchmarkExistingMerge;
var Target: IBookCollection; Catalogs: TCatalogSources; Sources: TMergeSources;
  Info: TCollectionInfo; Plan: TCollectionMergePlan; DB: TSQLiteDatabase;
  I, OriginalCount, ExpectedTotal, NewCount, ProbeCount: Integer;
  Started, PreviewMS, ApplyMS, LastLog, LastProfileSave: UInt64; Backup, Root: string;
  LogProgress: TMergeStageProgress;
  procedure RequirePrivatePath(const FileName: string);
  begin
    Require(TPath.GetFullPath(FileName).ToLower.StartsWith(Root),
      'Existing-profile regression would access a database outside its private runtime: '+FileName);
  end;
begin
  LogProgress:=procedure(const Stage: string; Current,Total: Integer)
    begin
      if (GetTickCount64-LastLog>=10000) or ((Total>0) and (Current=Total)) then
      begin
        Writeln('PROGRESS ',Stage,' ',Current,'/',Total,' elapsed_ms=',GetTickCount64-Started);
        Flush(Output); LastLog:=GetTickCount64;
      end;
      if (ParamStr(4)='profile') and (GetTickCount64-LastProfileSave>=60000) then
      begin SaveSQLiteProfile(Settings.AppPath+'profile-current.tsv'); LastProfileSave:=GetTickCount64; end;
    end;
  Root:=IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath)).ToLower;
  RequirePrivatePath(Settings.SystemFileName[sfSystemDB]);
  RequirePrivatePath(Settings.TempPath);
  Info:=SystemDB.GetCollectionInfo(StrToInt(ParamStr(2)));
  RequirePrivatePath(Info.DBFileName);
  Target:=SystemDB.GetCollection(Info.ID); Catalogs:=LoadCatalogSources(Target);
  Require(Length(Catalogs)>0,'Existing-profile fixture has no catalog sources');
  SetLength(Sources,Length(Catalogs));
  for I:=0 to High(Catalogs) do
  begin
    Require(Catalogs[I].IsINPX,'Existing-profile regression accepts private INPX snapshots only');
    RequirePrivatePath(Catalogs[I].CacheFile);
    Sources[I].ID:=Catalogs[I].ID; Sources[I].Name:=Catalogs[I].Name;
    Sources[I].LibraryNamespace:=Catalogs[I].LibraryNamespace;
    Sources[I].DatabaseFile:=Catalogs[I].CacheFile;
    Sources[I].Collection:=OpenCatalogSource(Catalogs[I],SystemDB);
  end;
  DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
  try OriginalCount:=DB.QuerySingleInt('SELECT COUNT(*) FROM Books'); finally DB.Free; end;
  Writeln('PROFILE existing_merge before=',OriginalCount,' sources=',Length(Sources)); Flush(Output);
  ExpectedTotal:=StrToInt(ParamStr(3)); Backup:=Settings.AppPath+'full-merge-backup';
  Plan:=TCollectionMergePlan.Create(Target,Sources,SystemDB,mpSourcePriority);
  try
    Started:=GetTickCount64; LastLog:=Started; LastProfileSave:=Started;
    if ParamStr(4)='profile' then StartSQLiteProfile;
    Plan.StageProgress:=LogProgress;
    Plan.Preview(procedure(Current,Total: Integer) begin LogProgress('preview',Current,Total); end);
    PreviewMS:=GetTickCount64-Started;
    if ParamStr(4)='profile' then
    begin SaveSQLiteProfile(Settings.AppPath+'profile-preview.tsv'); StartSQLiteProfile; end;
    Require(Plan.Total=ExpectedTotal,'Existing merge did not read every source record');
    NewCount:=Plan.NewBooks;
    Writeln('PROFILE existing_merge total=',Plan.Total,' new=',NewCount,' duplicates=',Plan.Duplicates,
      ' conflicts=',Plan.Conflicts,' preview_ms=',PreviewMS); Flush(Output);
    if ParamStr(4)='preview-only' then
    begin
      Require(NewCount=StrToInt(ParamStr(5)),'Read-only preview changed new-book count');
      Require(Plan.Conflicts=0,'Read-only real preview invented personal-value conflicts');
      Writeln('PASS full read-only merge preview covers every record and preserves expected duplicates'); Flush(Output); Exit;
    end;
    Started:=GetTickCount64; LastLog:=Started;
    ProbeCount:=0;
    if ParamStr(4)='probe' then
    begin
      try
        Plan.Apply(Backup,
          procedure(Current,Total: Integer)
          begin ProbeCount:=Current; LogProgress('apply',Current,Total); end,
          function: Boolean begin Result:=ProbeCount>=20000; end);
        Require(False,'Merge probe did not cancel');
      except on E: EAbort do Require(ProbeCount>=20000,'Merge probe canceled too early'); end;
      ApplyMS:=GetTickCount64-Started;
      DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
      try
        Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books')=OriginalCount,'Probe rollback changed the catalog');
        Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Probe rollback damaged the catalog');
      finally DB.Free; end;
      Writeln('PROFILE existing_merge_probe rows=',ProbeCount,' preview_ms=',PreviewMS,' apply_ms=',ApplyMS);
      Writeln('PASS existing merge probe cancels and rolls back'); Flush(Output); Exit;
    end;
    Plan.Apply(Backup,procedure(Current,Total: Integer) begin LogProgress('apply',Current,Total); end);
    Writeln('PROFILE merge read_snapshot_books=',Plan.ReadCacheBooks,' hits=',Plan.ReadCacheHits,' source_lookups=',Plan.SourceLookupCount); Flush(Output);
    ApplyMS:=GetTickCount64-Started;
    if ParamStr(4)='profile' then
    begin SaveSQLiteProfile(Settings.AppPath+'profile-apply.tsv'); StopSQLiteProfile; end;
    DB:=TSQLiteDatabase.CreateReadOnly(Info.DBFileName);
    try
      Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Merged catalog integrity failed');
      DB.ExecSQL('ATTACH DATABASE '+QuotedStr(Backup+'\destination.hlc2')+' AS prior');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books')=OriginalCount+NewCount,'Merged count differs from preview');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM prior.Books p LEFT JOIN Books b USING(BookID) WHERE b.BookID IS NULL')=0,
        'Full merge removed pre-existing books');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM prior.Books p JOIN Books b USING(BookID) WHERE '+
        '(p.Rate<>0 AND b.Rate<>p.Rate) OR (p.Progress<>0 AND b.Progress<>p.Progress) OR '+
        '(length(p.Review)>0 AND instr(b.Review,p.Review)=0)')=0,'Full merge lost ratings, progress or reviews');
      Writeln('PROFILE existing_merge after=',DB.QuerySingleInt('SELECT COUNT(*) FROM Books'),
        ' preview_ms=',PreviewMS,' apply_ms=',ApplyMS);
    finally DB.Free; end;
    DB:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    try Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Merged system profile integrity failed');
    finally DB.Free; end;
    Writeln('PASS full existing merge reads every source, preserves committed books and user data, and passes integrity');
    Flush(Output);
  finally Plan.Free; end;
end;

procedure TestSeriesReadStream;
var Collection: IBookCollection; Provider: IBookSeriesStreamProvider; Stream: IBookSeriesReadStream;
  IDs: TArray<Integer>; CollectionID, ID, I: Integer; Expected, Actual: TBookSeries; Rejected: Boolean;
begin
  CollectionID:=SystemDB.CreateCollection('Series stream fixture',Settings.AppPath,
    'series-stream.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CollectionID);
  SetLength(IDs,3);
  IDs[0]:=AddBook(Collection,'First stream book','Author','ru','Primary ё','prose_contemporary');
  IDs[1]:=AddBook(Collection,'Book without series','Author','ru','','prose_contemporary');
  IDs[2]:=AddBook(Collection,'Last stream book','Author','ru','Other series','prose_contemporary');
  Collection.AddBookSeries(IDs[0],'Additional ё',9);
  Collection.AddBookSeries(IDs[0],'Second additional',3);
  Require(Supports(Collection,IBookSeriesStreamProvider,Provider),'SQLite has no series stream');
  Stream:=Provider.OpenBookSeriesReadStream;
  for ID in IDs do
  begin
    Expected:=Collection.GetBookSeries(CreateBookKey(ID,CollectionID)); Actual:=Stream.ReadBook(ID);
    Require(Length(Actual)=Length(Expected),'Stream lost empty/primary/secondary relationships');
    for I:=0 to High(Expected) do
      Require((Actual[I].SeriesID=Expected[I].SeriesID) and (Actual[I].SeriesTitle=Expected[I].SeriesTitle) and
        (Actual[I].SeqNumber=Expected[I].SeqNumber) and (Actual[I].IsPrimary=Expected[I].IsPrimary),'Stream changed series order, titles, numbers or primary flags');
    if Length(Actual)>0 then Actual[0].SeriesTitle:='Changed caller copy';
    Actual:=Stream.ReadBook(ID);
    if Length(Expected)>0 then Require(Actual[0].SeriesTitle=Expected[0].SeriesTitle,'Caller mutated cached series array');
  end;
  Require(Length(Stream.ReadBook(IDs[2]+10))=0,'Missing book at end has unrelated series');
  Require(Length(Stream.ReadBook(IDs[2]+10))=0,'Repeated empty read changed result');
  Rejected:=False;
  try Stream.ReadBook(IDs[0]); except on E: EArgumentException do Rejected:=True; end;
  Require(Rejected,'Unordered stream reads silently lose relations');
  Stream:=nil;
  Require(Length(Collection.GetBookSeries(CreateBookKey(IDs[0],CollectionID)))=3,'Read stream mutated collection');
  Writeln('PASS sequential series stream matches ordinary lookup, preserves primary/additional order and Unicode, handles missing and repeated IDs and protects caller copies');
end;

procedure TestCatalogWriteNoOps;
var Collection: IBookCollection; CollectionID, BookID, Before, RowID, OriginalCycle: Integer;
  Updater: IBookMergeMetadataUpdater;
  Book: TBookRecord; DB: TSQLiteDatabase; FileName: string;
begin
  CollectionID:=SystemDB.CreateCollection('No-op catalog links',Settings.AppPath,'no-op-catalog.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CollectionID); BookID:=AddBook(Collection,'Preserved book','Writer','ru','','prose_contemporary');
  Collection.GetBookRecord(CreateBookKey(BookID,CollectionID),Book,False);
  FileName:=Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
  Collection.BeginBulkOperation;
  try
    Collection.SetCatalogBookID('noop:source',BookID);
    Collection.SetCatalogBookPreferredSource(Book.BookKey,'Case Source');
    Collection.SetCatalogBookCopy('noop:copy','Case Source',Book); Collection.EndBulkOperation(True);
  except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
  DB:=TSQLiteDatabase.CreateReadOnly(FileName);
  try
    Before:=DB.QuerySingleInt('PRAGMA data_version');
    RowID:=DB.QuerySingleInt('SELECT rowid FROM CatalogBookCopies WHERE SourceKey=''noop:copy''');
    Collection.BeginBulkOperation;
    try
      for var I:=1 to 10 do
      begin
        Collection.SetCatalogBookID('noop:source',BookID);
        Collection.SetCatalogBookPreferredSource(Book.BookKey,'Case Source');
        Collection.SetCatalogBookCopy('noop:copy','Case Source',Book);
      end;
      Collection.EndBulkOperation(True);
    except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
    Require(DB.QuerySingleInt('PRAGMA data_version')=Before,'Identical catalog links still dirty the database');
    Require(DB.QuerySingleInt('SELECT rowid FROM CatalogBookCopies WHERE SourceKey=''noop:copy''')=RowID,'Repeat copy write replaced its row identity');
    Collection.BeginBulkOperation;
    try
      Book.InsideNo:=12; Collection.SetCatalogBookCopy('noop:copy','case source',Book);
      Collection.SetCatalogBookPreferredSource(Book.BookKey,'case source'); Collection.EndBulkOperation(True);
    except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
    Require(DB.QuerySingleInt('SELECT InsideNo FROM CatalogBookCopies WHERE SourceKey=''noop:copy''')=12,'Changed copy member was discarded by no-op optimization');
    Require(DB.QuerySingleString('SELECT SourceName FROM CatalogBookCopies WHERE SourceKey=''noop:copy''')='case source','Case-only copy name change was lost');
    Require(DB.QuerySingleString('SELECT SourceName FROM CatalogPreferredSource WHERE BookID='+IntToStr(BookID))='case source','Case-only preferred source name change was lost');
    Require(DB.QuerySingleInt('SELECT rowid FROM CatalogBookCopies WHERE SourceKey=''noop:copy''')=RowID,'Updating a copy unnecessarily replaced its row');
    Require(Supports(Collection,IBookMergeMetadataUpdater,Updater),'SQLite merge metadata updater is unavailable');
    Collection.AddBookSeries(BookID,'Unique preserved cycle',7); OriginalCycle:=Collection.GetBookSeries(Book.BookKey)[0].SeriesID;
    Collection.GetBookRecord(CreateBookKey(BookID,CollectionID),Book,True); Book.Series:='Incoming primary cycle'; Book.SeqNumber:=3;
    Collection.BeginBulkOperation;
    try Updater.UpdateBookPreservingSeries(Book); Collection.EndBulkOperation(True);
    except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE BookID=? AND SeriesID=?',[BookID,OriginalCycle])=1,
      'Merge metadata update deleted the old cycle identity');
    Book.Series:=''; Collection.BeginBulkOperation;
    try Updater.UpdateBookPreservingSeries(Book); Collection.EndBulkOperation(True);
    except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE BookID=?',[BookID])=2,'Unsequenced source deleted existing cycle memberships');
    Require(DB.QuerySingleString('SELECT SeriesTitle FROM Series WHERE SeriesID=?',[OriginalCycle])='Unique preserved cycle','Original cycle ID was recreated');
    // A normal explicit edit still clears every membership; merge semantics must not leak into it.
    Collection.SetSeriesID(Book.BookKey,NO_SERIES_ID);
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Series_List WHERE BookID=?',[BookID])=0,'Normal series removal inherited merge preservation mode');
    Require(DB.QuerySingleString('PRAGMA quick_check')='ok','No-op catalog writes damaged integrity');
  finally DB.Free; end;
  Writeln('PASS identical catalog mappings/copies/preferences do not rewrite pages; changed values and case-only names persist without replacing row identities');
end;

procedure TestMergeArchiveResolution; forward;

procedure TestCollectionMerge;
var High, Low, Target: IBookCollection; HighID, LowID, TargetID, A, B, C, ExistingID, ID: Integer;
  Sources: TMergeSources; Plan: TCollectionMergePlan; Book, Existing, Probe: TBookRecord;
  Series: TBookSeries; Iterator: IBookIterator; Count, CancelCalls: Integer; Backup, OriginalReview: string;
  DB: TSQLiteDatabase;

  procedure Locate(const Collection: IBookCollection; BookID: Integer;
    const Folder, FileName, LibID: string);
  begin
    Collection.GetBookRecord(CreateBookKey(BookID, Collection.CollectionID), Book, True);
    Book.Folder := Folder; Book.FileName := FileName; Book.LibID := LibID; Collection.UpdateBook(Book);
  end;

  procedure Publisher(const Collection: IBookCollection; BookID: Integer; const Name: string);
  begin
    Series := nil; TSeriesHelper.Add(Series, 0, Name, 7, True);
    Collection.SetBookPublisherSeries(CreateBookKey(BookID, Collection.CollectionID), Series);
  end;
begin
  HighID := SystemDB.CreateCollection('Merge high', Settings.AppPath + 'root-one\',
    'merge-high.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  LowID := SystemDB.CreateCollection('Merge low', Settings.AppPath + 'root-two\',
    'merge-low.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  TargetID := SystemDB.CreateCollection('Merge target', Settings.AppPath,
    'merge-target.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  High := SystemDB.GetCollection(HighID); Low := SystemDB.GetCollection(LowID); Target := SystemDB.GetCollection(TargetID);
  A := AddBook(High, 'High title', 'High', 'ru', 'High cycle', 'prose_contemporary');
  B := AddBook(Low, 'Low title', 'Low', 'ru', 'Low cycle', 'detective');
  C := AddBook(Low, 'Other file', 'Other', 'ru', '', 'prose_contemporary');
  ExistingID := AddBook(Target, 'User title', 'User', 'ru', 'User cycle', 'prose_contemporary');
  Locate(High, A, '', 'book', '42');
  Locate(Low, B, High.CollectionRoot, 'book', '99');
  Locate(Low, C, '', 'other', '42');
  Locate(Target, ExistingID, High.CollectionRoot, 'book', 'user-book');
  High.SetRate(CreateBookKey(A, HighID), 4); High.SetProgress(CreateBookKey(A, HighID), 20);
  High.SetReview(CreateBookKey(A, HighID), 'High review');
  Low.SetRate(CreateBookKey(B, LowID), 3); Low.SetProgress(CreateBookKey(B, LowID), 80);
  Low.SetReview(CreateBookKey(B, LowID), 'Low review');
  Target.SetRate(CreateBookKey(ExistingID, TargetID), 5);
  Target.SetProgress(CreateBookKey(ExistingID, TargetID), 10);
  Target.SetReview(CreateBookKey(ExistingID, TargetID), 'User review');
  OriginalReview:='  User review'+sLineBreak+' preserved personal spacing  ';
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
  try
    var ReviewQuery:=DB.NewQuery('UPDATE Books SET Review=? WHERE BookID=?');
    try ReviewQuery.SetBlobParam(0,OriginalReview); ReviewQuery.SetParam(1,ExistingID); ReviewQuery.ExecSQL;
    finally ReviewQuery.Free; end;
  finally DB.Free; end;
  Target.AddBookToGroup(CreateBookKey(ExistingID,TargetID),FAVORITES_GROUP_ID);
  Publisher(High,A,'High publisher'); Publisher(Low,B,'Low publisher'); Publisher(Target,ExistingID,'User publisher');
  High.AddBookToGroup(CreateBookKey(A, HighID), FAVORITES_GROUP_ID);
  Low.AddBookToGroup(CreateBookKey(C, LowID), FAVORITES_GROUP_ID);
  SetLength(Sources, 2);
  Sources[0].ID := 'high'; Sources[0].Name := 'High'; Sources[0].Collection := High;
  Sources[0].DatabaseFile := SystemDB.GetCollectionInfo(HighID).DBFileName;
  Sources[1].ID := 'low'; Sources[1].Name := 'Low'; Sources[1].Collection := Low;
  Sources[1].DatabaseFile := SystemDB.GetCollectionInfo(LowID).DBFileName;
  Target.BeginBulkOperation;
  try
    Target.SetCatalogBookID('unselected:file:proof',ExistingID);
    Target.SetCatalogBookID('high:file;looks-similar',ExistingID);
    Target.EndBulkOperation(True);
  except if Target.InBulkOperation then Target.EndBulkOperation(False); raise; end;
  Plan := TCollectionMergePlan.Create(Target, Sources);
  try
    High.SetRate(CreateBookKey(A,HighID),0); High.SetProgress(CreateBookKey(A,HighID),0);
    StartSQLiteProfile;
    try Plan.Preview; SaveSQLiteProfile(Settings.AppPath+'preview-user-snapshot.tsv'); finally StopSQLiteProfile; end;
    Require((Plan.Conflicts=1) and Plan.Report.Text.Contains('Сохраняемая оценка 5 / источник 3; прогресс: 10 / 80.'),
      'A later source lost conflicts with original target values after an empty first source');
    Require(not TFile.ReadAllText(Settings.AppPath+'preview-user-snapshot.tsv').Contains('SELECT Rate,Progress FROM Books WHERE BookID'),
      'Preview rereads user fields for every matched book');
    Require(Plan.SourceLookupCount=0,'Unselected or neighboring source prefixes caused per-book stable lookups');
    High.SetRate(CreateBookKey(A,HighID),4); High.SetProgress(CreateBookKey(A,HighID),20);
    Plan.Preview;
    Require((Plan.NewBooks=1) and (Plan.Duplicates=2) and (Plan.Conflicts=2), 'Merge preview counts incorrect');
    Require(Plan.Report.Text.Contains('Источник High: новых записей 0; уже подключено 0; сопоставленных копий 1.') and
      Plan.Report.Text.Contains('Источник Low: новых записей 1; уже подключено 0; сопоставленных копий 1.'),
      'Initial source summary does not distinguish physical matches: '+Plan.Report.Text);
    Backup := Settings.AppPath + 'merge-backup'; Plan.Apply(Backup);
    Require((Plan.ReadCacheBooks=0) or (Plan.ReadCacheHits>0),'Prepared merge snapshot did not read matching existing books');
    Writeln('PROFILE merge read_snapshot_books=',Plan.ReadCacheBooks,' hits=',Plan.ReadCacheHits,' source_lookups=',Plan.SourceLookupCount);
    ID := SourceBookMapping(Target,Sources[0],A); Require(ID=ExistingID, 'Merge changed existing BookID');
    Require(SourceBookMapping(Target,Sources[1],B)=ID, 'Physical duplicate was not combined');
    Require((SourceBookMapping(Target,Sources[1],C)>0) and (SourceBookMapping(Target,Sources[1],C)<>ID), 'Cross-source numeric ID merged distinct books');
    Target.GetBookRecord(CreateBookKey(ID,TargetID), Existing, True);
    Require((Existing.Title='High title') and (Existing.Rate=5) and (Existing.Progress=10), 'Priority or target user values lost');
    Require(Existing.Review.Contains('User review') and Existing.Review.Contains('High review') and Existing.Review.Contains('Low review'), 'Merge lost reviews');
    Require(Existing.Review.StartsWith(OriginalReview),'Source reviews trimmed existing personal text or line breaks');
    SystemDB.GetBookRecord(Existing.BookKey,Probe);
    Require((Probe.Title=Existing.Title) and (Probe.Rate=5) and (Probe.Progress=10) and
      Probe.Review.Contains('User review') and (Length(Probe.Authors)=Length(Existing.Authors)),
      'Stored group card was skipped or lost user values during merge');
    Require(Probe.Review.StartsWith(OriginalReview),'Group card lost original personal review prefix');
    Writeln('PASS merge preview reuses sparse target user snapshot, detects late-source conflicts and preserves original review prefix in catalog and groups');
    Require(Length(Target.GetBookSeries(Existing.BookKey))=3, 'Merge lost author cycles');
    Require(Length(Target.GetBookPublisherSeries(Existing.BookKey))=3, 'Merge lost publisher series');
    Require(Length(Existing.Authors)=3, 'Merge lost authors');
    Iterator := Target.GetBookIterator(bmAll,False); Count := 0;
    while Iterator.Next(Book) do Inc(Count); Require(Count=2, 'Merge book count incorrect');
    Iterator := SystemDB.GetBookIterator(FAVORITES_GROUP_ID, TargetID); Count := 0;
    while Iterator.Next(Book) do Inc(Count); Require(Count=2, 'Merge lost group membership');
    DB := TSQLiteDatabase.CreateReadOnly(Backup + '\destination.hlc2');
    try Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books')=1, 'Backup did not preserve pre-merge state');
    finally DB.Free; end;
    High.GetBookRecord(CreateBookKey(A,HighID), Book, True);
    Require((Book.Title='High title') and (Book.LibID='42') and (Book.Review='High review'), 'Merge modified source');
    DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
    try
      DB.ExecSQL('CREATE TABLE MergeWriteProbe(Count INTEGER)');
      DB.ExecSQL('INSERT INTO MergeWriteProbe VALUES (0)');
      DB.ExecSQL('CREATE TRIGGER MergeWriteProbeTrigger AFTER UPDATE ON Books BEGIN UPDATE MergeWriteProbe SET Count = Count + 1; END');
    finally DB.Free; end;
    Plan.Preview;
    Require(Plan.Report.Text.Contains('Источник Low: новых записей 0; уже подключено 2; сопоставленных копий 0.'),
      'Repeat preview describes existing source links as new physical matches');
    Plan.Apply(Settings.AppPath + 'merge-repeat');
    Target.GetBookRecord(CreateBookKey(ID,TargetID), Book, True);
    Require((Book.Review=Existing.Review) and (Length(Target.GetBookSeries(Book.BookKey))=3), 'Repeat merge duplicated data');
    DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(TargetID).DBFileName);
    try
      Require(DB.QuerySingleInt('SELECT Count FROM MergeWriteProbe')=0,
        'Repeat merge rewrites identical book metadata');
      DB.ExecSQL('DROP TRIGGER MergeWriteProbeTrigger');
      DB.ExecSQL('DROP TABLE MergeWriteProbe');
    finally DB.Free; end;
    Writeln('PASS repeated merge does not rewrite unchanged book metadata');
    Plan.Preview;
    High.GetBookRecord(CreateBookKey(A,HighID), Book, True);
    Book.Title := 'Changed after preview'; High.UpdateBook(Book);
    try
      Plan.Apply(Settings.AppPath + 'merge-stale');
      Require(False, 'Stale preview was accepted');
    except on E: Exception do Require(E.Message.Contains('заново'), 'Unexpected stale preview error'); end;
    Require(not DirectoryExists(Settings.AppPath + 'merge-stale'), 'Stale merge created backup or changed data');
    Plan.Preview; CancelCalls := 0;
    try
      Plan.Apply(Settings.AppPath + 'merge-canceled', nil,
        function: Boolean
        begin
          Inc(CancelCalls);
          Target.GetBookRecord(CreateBookKey(ID,TargetID), Probe, False);
          Result := Probe.Title <> Existing.Title;
        end);
      Require(False, 'Cancellation did not abort merge');
    except on E: EAbort do ; end;
    Target.GetBookRecord(CreateBookKey(ID,TargetID), Book, True);
    Require((Book.Review=Existing.Review) and (Book.Title=Existing.Title), 'Canceled merge changed committed data');
    Require((CancelCalls>1) and TFile.ReadAllText(Settings.AppPath + 'merge-canceled\status.txt').Contains('Отменено'),
      'Cancellation was not tested after mutation started');
    BackupCollectionFile(Backup + '\destination.hlc2', Settings.AppPath + 'restore-test.hlc2');
    DB := TSQLiteDatabase.Create(Settings.AppPath + 'restore-test.hlc2');
    try
      DB.ExecSQL('CREATE TABLE RestoreProbe(Value TEXT)');
      DB.ExecSQL('INSERT INTO RestoreProbe VALUES (''Changed'')');
      DB.RestoreFrom(Backup + '\destination.hlc2');
      Require(DB.QuerySingleString('SELECT Title FROM Books')='User title', 'SQLite backup restore lost original data');
      Require(DB.QuerySingleInt('SELECT COUNT(*) FROM sqlite_master WHERE name = ''RestoreProbe''')=0, 'Restore retained post-backup changes');
      Require(DB.QuerySingleString('PRAGMA integrity_check')='ok', 'Restored SQLite database is damaged');
    finally DB.Free; end;
    High.BeginBulkOperation;
    try
      High.GetBookRecord(CreateBookKey(A,HighID), Book, True);
      for Count := 1 to 2200 do
      begin Book.LibID := 'report-' + IntToStr(Count); High.InsertBook(Book, False, False); end;
      High.EndBulkOperation(True);
    except High.EndBulkOperation(False); raise; end;
    Plan.Preview;
    Require((Plan.Report.Count<=2052) and (Length(TFile.ReadAllText(Plan.FullReportFile).Split([#10]))>2200),
      'Large preview report is truncated or loads all lines into the UI');
    Require(Plan.Report[1].StartsWith('Источник High:') and Plan.Report[2].StartsWith('Источник Low:'),
      'Source summaries are hidden behind thousands of matches');
    Writeln('PASS merge cancellation rolls back mutations, SQLite restore is intact and large report is saved in full');
    Writeln('PASS repeat merge remains idempotent and stale previews are rejected');
    Writeln('PASS safe merge previews duplicates, keeps IDs, all series, user values and groups, backs up WAL and rolls back cancellation');
  finally Plan.Free; end;
  TestMergePolicies; TestMergeArchiveResolution; TestCatalogWriteNoOps;
  TestSourceKeyCollisions;
end;

procedure TestCollectionSpaceEstimate;
var Zip: TZipFile; Estimate: TCollectionSpaceEstimate; Bytes: TBytes; Hash, Text: string;
  One, Large: TCollectionSpaceEstimate;
begin
  Bytes:=TEncoding.UTF8.GetBytes(StringOfChar('X',2*1024*1024));
  Zip:=TZipFile.Create;
  try Zip.Open('space-estimate.inpx',zmWrite); Zip.Add(Bytes,'books.inp'); Zip.Add(Bytes,'ignored.txt');
  finally Zip.Free; end;
  Hash:=THashSHA2.GetHashStringFromFile('space-estimate.inpx');
  Estimate:=EstimateCatalogBytes('space-estimate.inpx');
  Require(Estimate.Known and (Estimate.LowBytes=4*1024*1024) and (Estimate.HighBytes=12*1024*1024),
    'Disk estimate uses compressed size or unrelated ZIP entries');
  Require(THashSHA2.GetHashStringFromFile('space-estimate.inpx')=Hash,'Size estimation modified index');
  Require(not EstimateCatalogBytes('missing.inpx').Known,'Missing index acquired a misleading estimate');
  TFile.WriteAllText('malformed.inpx','not a ZIP');
  Require(not EstimateCatalogBytes('malformed.inpx').Known,'Broken index acquired a misleading estimate');
  One:=EstimateMetadataBytes(1000000,False,False); Large:=EstimateMetadataBytes(10000000,False,False);
  Require(Large.HighBytes>One.HighBytes,'Larger import did not increase estimate');
  Require(not EstimateMetadataBytes(High(Int64),False,False).Known,'Estimated size overflowed');
  Text:=CollectionSpaceText(Estimate,20*1024*1024,1024);
  Require(Text.Contains('Места может не хватить'),'Estimate hides insufficient disk space');
  Text:=CollectionSpaceText(Estimate,20*1024*1024,100*1024*1024);
  Require(not Text.Contains('Места может не хватить'),'Estimate invents a full-disk warning');
  Require(CollectionDiskFree(Settings.AppPath)>0,'Disk-free lookup failed for private runtime');
  Writeln('PASS approximate disk estimates use uncompressed catalog metadata, preserve inputs, handle unknown/corrupt/overflow sizes and show available space');
end;

procedure TestMergeArchiveResolution;
var Source, Target: IBookCollection; SourceID, TargetID, BookID: Integer; Book: TBookRecord;
  Sources: TMergeSources; Plan: TCollectionMergePlan; Root, Archive, Hash: string; Rejected: Boolean;
begin
  Root:=Settings.AppPath+'archive-cache-fixture\'; ForceDirectories(Root);
  SourceID:=SystemDB.CreateCollection('Archive cache source',Root,'archive-cache-source.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  TargetID:=SystemDB.CreateCollection('Archive cache target',Settings.AppPath,'archive-cache-target.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID); Target:=SystemDB.GetCollection(TargetID);
  BookID:=AddBook(Source,'Archive cache','Author','ru','','prose_contemporary');
  Source.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True); Book.Folder:='library.zip'; Book.FileName:='1'; Book.FileExt:='.fb2'; Source.UpdateBook(Book);
  Archive:=Root+'library.7z'; TFile.WriteAllText(Archive,'identity fixture'); Hash:=THashSHA2.GetHashStringFromFile(Archive);
  Require(SameFileName(Book.GetBookContainer,Archive),'ZIP to 7z fallback missing');
  Require((Book.GetBookFormat=Book.GetBookFormat(Book.GetBookContainer)) and
    (Book.GetBookFileName=Book.GetBookFileName(Book.GetBookContainer)),'Resolved-container overload changes archive semantics');
  SetLength(Sources,1); Sources[0].ID:='archive-cache'; Sources[0].Name:='Cache fixture'; Sources[0].Root:=Root;
  Sources[0].Collection:=Source; Sources[0].DatabaseFile:=SystemDB.GetCollectionInfo(SourceID).DBFileName;
  Plan:=TCollectionMergePlan.Create(Target,Sources,SystemDB,mpKeepAll);
  try
    Plan.Preview; Require(Plan.NewBooks=1,'Archive cache fixture did not preview');
    // The ZIP has higher priority than fallback 7z, but appeared after the preview.
    TFile.WriteAllText(Root+'library.zip','new identity fixture'); Rejected:=False;
    try Plan.Apply(Settings.AppPath+'archive-cache-stale-backup');
    except on E: Exception do Rejected:=E.Message.Contains('Расположение архивов изменилось'); end;
    Require(Rejected and not DirectoryExists(Settings.AppPath+'archive-cache-stale-backup'),'Changed archive was applied using a stale preview');
    Plan.Preview; Plan.Apply(Settings.AppPath+'archive-cache-fresh-backup');
    Target.GetBookRecord(CreateBookKey(SourceBookMapping(Target,Sources[0],BookID),TargetID),Book,True);
    Require(SameFileName(Book.GetBookContainer,Root+'library.zip'),'New preview reused stale 7z path');
    Require(THashSHA2.GetHashStringFromFile(Archive)=Hash,'Merge rewrote original archive');
  finally Plan.Free; end;
  Writeln('PASS bounded merge archive paths refresh between operations and reject stale ZIP/7z previews before writes');
end;

function FeedbackButton(Form: TCustomForm; const Prefix: string): TButton;
begin
  Result:=nil;
  for var Component in Form do
    if (Component is TButton) and string(TButton(Component).Caption).StartsWith(Prefix) then Exit(TButton(Component));
  Require(False,'Missing feedback action: '+Prefix);
end;

procedure CheckSourceDialogLayout(Form: TCustomForm);
var R: TRect; LabelText: string;
begin
  for var DPI in TArray<Integer>.Create(96,144,192) do
  begin
    Form.ScaleForPPI(DPI);
    for var C in Form do
    begin
      if C is TLabel then
      begin
        var LabelControl:=TLabel(C); LabelText:=LabelControl.Caption;
        Form.Canvas.Font.Assign(LabelControl.Font); R:=Rect(0,0,LabelControl.Width,0);
        DrawText(Form.Canvas.Handle,PChar(LabelText),Length(LabelText),R,DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
        Require(R.Height<=LabelControl.Height,'Source explanation clipped at '+IntToStr(DPI)+': '+LabelText);
      end;
      if C is TButton then
      begin
        var B:=TButton(C);
        Require((B.Left>=0) and (B.Top>=0) and (B.Left+B.Width<=B.Parent.ClientWidth) and
          (B.Top+B.Height<=B.Parent.ClientHeight),Format('Source button out of parent at %d: %s; button=%d,%d %dx%d; parent=%dx%d; form=%dx%d',
            [DPI,string(B.Caption),B.Left,B.Top,B.Width,B.Height,B.Parent.ClientWidth,B.Parent.ClientHeight,Form.ClientWidth,Form.ClientHeight]));
        Form.Canvas.Font.Assign(B.Font);
        Require(Form.Canvas.TextWidth(B.Caption)+MulDiv(16,DPI,96)<=B.Width,'Source button text clipped at '+IntToStr(DPI)+': '+string(B.Caption));
      end;
    end;
  end;
  Form.ScaleForPPI(96);
end;

{$I Feedback529JXLTests.inc}
{$I Feedback529Tests.inc}

procedure TestCatalogSources;
var Sources, Loaded: TCatalogSources; Target, SourceCollection: IBookCollection;
  ID, I: Integer; Refresh: TCatalogRefreshWorker; Worker: TCatalogMergeWorker;
  Plan: TCollectionMergePlan; Book, AliasBook: TBookRecord; Iterator: IBookIterator; Count, AliasID: Integer;
  AliasWorker: TSeriesAliasWorker; AliasPlan: TSeriesAliasPlan;
  Dialog: TfrmCatalogSources; Statistics: TfrmStat; Review: TfrmSeriesAliasReview;

  procedure IndexFile(const FileName, Title: string);
  var Zip: TZipFile; Data: TBytes;
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(FileName,zmWrite);
      Data := TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG');
      Zip.Add(Data,'structure.info');
      Data := TEncoding.UTF8.GetBytes('Автор,Тест:'#4'prose_contemporary:'#4 + Title + #4'Цикл'#4'1'#4'1'#4'100'#4'1'#4'0'#4'fb2'#4'2026-10-08'#4'ru');
      Zip.Add(Data,'books.inp');
    finally Zip.Free; end;
  end;
begin
  TestCollectionSpaceEstimate;
  ID := SystemDB.CreateCollection('Multiple sources', Settings.AppPath,
    'source-target.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.SystemFileName[sfGenresFB2]);
  Target := SystemDB.GetCollection(ID); SetLength(Sources,2);
  for I := 0 to 1 do
  begin
    Sources[I].ID := TCatalogSource.NewID; Sources[I].Name := 'Source ' + IntToStr(I);
    Sources[I].Root := Settings.AppPath + 'source-books-' + IntToStr(I);
    ForceDirectories(Sources[I].Root);
    Sources[I].INPXFile := Settings.AppPath + 'source-' + IntToStr(I) + '.inpx';
    Sources[I].CollectionID := INVALID_COLLECTION_ID;
    IndexFile(Sources[I].INPXFile, 'Source title ' + IntToStr(I));
    Refresh := TCatalogRefreshWorker.Create(Sources[I]);
    try Refresh.Start; Refresh.WaitFor;
      Require(Refresh.Success and not Assigned(Refresh.FatalException),'Snapshot refresh failed: ' + Refresh.Error);
    finally Refresh.Free; end;
  end;
  SaveCatalogSources(Target,Sources); Loaded := LoadCatalogSources(Target);
  Require((Length(Loaded)=2) and (Loaded[0].ID=Sources[0].ID) and (Loaded[1].Root=Sources[1].Root),'Sources settings lost priority/root');
  Worker := TCatalogMergeWorker.CreatePreview(ID,Loaded);
  try Worker.Start; Worker.WaitFor;
    Require(Worker.Success,'Multi-source preview failed: ' + Worker.Error); Plan := Worker.TakePlan;
  finally Worker.Free; end;
  try
    Require((Plan.NewBooks=2) and (Plan.Duplicates=0),'Different archive roots merged identical numeric IDs');
    Worker := TCatalogMergeWorker.CreateApply(Plan,Settings.AppPath + 'source-merge-backup');
    try Worker.Start; Worker.WaitFor; Require(Worker.Success,'Source apply failed: ' + Worker.Error);
    finally Worker.Free; end;
  finally Plan.Free; end;
  Target := SystemDB.GetCollection(ID,True); Iterator := Target.GetBookIterator(bmAll,True); Count := 0;
  while Iterator.Next(Book) do
  begin
    Require(Book.GetBookContainer.Contains('source-books-' + IntToStr(Count)), 'Source root was lost');
    Inc(Count);
  end;
  Require(Count=2,'Multi-source collection lost books'); Iterator := nil;
  Statistics := TfrmStat.Create(nil);
  try
    Statistics.LoadCollectionInfo(Target); WaitCollectionStatistics(Statistics);
    Require((Statistics.lvInfo.Items[5].SubItems[0]='2') and
      (Statistics.lvInfo.Groups.Count=3), 'Statistics duplicate multi-series books or hide sources');
    Require(Statistics.lvInfo.Items[8].SubItems[0].StartsWith('1 связанных записей;') and
      Statistics.lvInfo.Items[9].SubItems[0].StartsWith('1 связанных записей;'), 'Source record count incorrect');
    Statistics.LoadCollectionInfo(Target); WaitCollectionStatistics(Statistics);
    Require(Statistics.lvInfo.Items.Count=11, 'Repeated statistics load duplicates source rows');
  finally Statistics.Free; end;
  Writeln('PASS statistics count book records once and show linked supplemental sources');
  IndexFile(Sources[0].INPXFile,'Updated source title');
  Refresh := TCatalogRefreshWorker.Create(Sources[0]);
  try Refresh.Start; Refresh.WaitFor; Require(Refresh.Success,'Independent refresh failed: ' + Refresh.Error);
  finally Refresh.Free; end;
  SourceCollection := OpenCatalogSource(Sources[1],SystemDB); Iterator := SourceCollection.GetBookIterator(bmAll,False);
  Require(Iterator.Next(Book) and (Book.Title='Source title 1'),'Refreshing first source altered second');
  Iterator := nil; SourceCollection := nil;
  Worker := TCatalogMergeWorker.CreatePreview(ID,Sources);
  try Worker.Start; Worker.WaitFor; Require(Worker.Success,'Refresh preview failed: ' + Worker.Error); Plan := Worker.TakePlan;
  finally Worker.Free; end;
  try
    Require((Plan.NewBooks=0) and (Plan.Duplicates=2),'Refresh created duplicate books');
    Worker := TCatalogMergeWorker.CreateApply(Plan,Settings.AppPath + 'source-refresh-backup');
    try Worker.Start; Worker.WaitFor; Require(Worker.Success,'Refreshed source apply failed: ' + Worker.Error);
    finally Worker.Free; end;
  finally Plan.Free; end;
  Target := SystemDB.GetCollection(ID,True); Iterator := Target.GetBookIterator(bmAll,True); Count := 0;
  while Iterator.Next(Book) do
  begin
    if Count=0 then Require(Book.Title='Updated source title','Source update did not refresh metadata');
    Inc(Count);
  end;
  Require(Count=2,'Source update duplicated books'); Iterator := nil;
  TFile.WriteAllText(Sources[0].INPXFile,'broken INPX');
  Refresh := TCatalogRefreshWorker.Create(Sources[0]);
  try Refresh.Start; Refresh.WaitFor; Require(not Refresh.Success,'Broken index was accepted');
  finally Refresh.Free; end;
  SourceCollection := OpenCatalogSource(Sources[0],SystemDB); Iterator := SourceCollection.GetBookIterator(bmAll,False);
  Require(Iterator.Next(Book) and (Book.Title='Updated source title'),'Failed refresh replaced good source snapshot');
  Iterator := nil; SourceCollection := nil;
  AliasBook := Default(TBookRecord); AliasBook.Title := 'Alias fixture'; AliasBook.Series := 'Цикл[a]';
  AliasBook.LibID := 'alias-fixture'; AliasBook.FileName := 'alias-fixture'; AliasBook.FileExt := '.fb2';
  TAuthorsHelper.Add(AliasBook.Authors,'Автор','Тест','');
  AliasID := Target.InsertBook(AliasBook,False,False);
  AliasWorker := TSeriesAliasWorker.CreatePreview(ID);
  try
    AliasWorker.Start; AliasWorker.WaitFor;
    Require(AliasWorker.Success,'Series alias worker preview failed: '+AliasWorker.Error);
    AliasPlan := AliasWorker.TakePlan;
  finally AliasWorker.Free; end;
  try
    Require(AliasPlan.Count=1,'Threaded series alias preview missed shared author');
    AliasWorker := TSeriesAliasWorker.CreateApply(AliasPlan,Settings.AppPath+'threaded-series-backup');
    try AliasWorker.Start; AliasWorker.WaitFor;
      Require(AliasWorker.Success,'Series alias worker apply failed: '+AliasWorker.Error);
    finally AliasWorker.Free; end;
  finally AliasPlan.Free; end;
  Target := SystemDB.GetCollection(ID,True);
  Target.GetBookRecord(CreateBookKey(AliasID,ID),AliasBook,False);
  Require(AliasBook.Series='Цикл','Threaded series merge did not refresh primary name');
  Writeln('PASS series aliases preview and apply across background workers');
  // A separate series review must not replace the source-merge action.
  Dialog:=TfrmCatalogSources.CreateForCollection(frmMain,Target);
  try
    CheckSourceDialogLayout(Dialog);
    Require(not FeedbackButton(Dialog,'2. Добавить книги').Enabled,'Source apply enabled before preview');
    FeedbackButton(Dialog,'1. Проверить все источники').OnClick(FeedbackButton(Dialog,'1. Проверить все источники'));
    Require(FeedbackButton(Dialog,'2. Добавить книги').Enabled,'All-source preview did not enable source apply');
    Review:=TfrmSeriesAliasReview.CreateFor(Dialog);
    try
      Review.PreviewAliases(nil); CheckSourceDialogLayout(Review);
      Require(not FeedbackButton(Review,'Объединить').Enabled,'Zero-pair series review offers a write');
      Require(FeedbackButton(Dialog,'2. Добавить книги').Enabled,'Read-only series check invalidated source preview');
    finally Review.Free; end;
    var Scroll: TScrollBox:=nil;
    for var C in Dialog do if C is TScrollBox then Scroll:=TScrollBox(C);
    Require(Assigned(Scroll),'Sources cannot scroll in a short window');
    Dialog.Height:=Dialog.Constraints.MinHeight; Application.ProcessMessages;
    Require(Scroll.VertScrollBar.Range>Scroll.ClientHeight,'Short source window hides content without scrolling');
  finally Dialog.Free; end;
  Writeln('PASS all sources participate without multiselect; independent series review shows zero result; source labels/buttons fit 100/150/200 percent and short windows scroll');
  if ParamStr(1)='catalog-sources-ui' then
  begin
    frmMain.Show; Dialog := TfrmCatalogSources.CreateForCollection(frmMain,Target);
    try Dialog.ShowModal; finally Dialog.Free; end;
  end;
  Writeln('PASS multiple INPX sources keep separate roots and IDs, persist priority, refresh independently and merge in worker');
end;

procedure ExpectTitles(Tree: TBookTree; const Expected: array of string);
var
  Actual, Wanted: TStringList;
  Node: PVirtualNode;
  Book: PBookRecord;
  Title: string;
begin
  Actual := TStringList.Create;
  Wanted := TStringList.Create;
  try
    Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      Book := Tree.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) then
        Actual.Add(Book.Title);
      Node := Tree.GetNext(Node);
    end;
    for Title in Expected do
      Wanted.Add(Title);
    Actual.Sort;
    Wanted.Sort;
    Require(Actual.Text = Wanted.Text,
      'Wrong visible books. Expected: ' + Wanted.CommaText + '; actual: ' + Actual.CommaText);
  finally
    Wanted.Free;
    Actual.Free;
  end;
end;

procedure ChangeCollection(ID: Integer);
var
  Item: TMenuItem;
begin
  for Item in frmMain.miCollSelect do
    if Item.Tag = ID then
    begin
      frmMain.miActiveCollectionClick(Item);
      Exit;
    end;
  raise Exception.Create('Fixture collection is absent from the collection menu');
end;

procedure ShowPage(Index: Integer);
begin
  // HomeLib Ru inserts Publisher Series between the physical tab pages.
  // PAGE_* values identify views, not PageIndex after that insertion.
  case Index of
    PAGE_AUTHORS: frmMain.pgControl.ActivePage := frmMain.tsByAuthor;
    PAGE_SERIES: frmMain.pgControl.ActivePage := frmMain.tsBySerie;
    PAGE_GENRES: frmMain.pgControl.ActivePage := frmMain.tsByGenre;
    PAGE_SEARCH: frmMain.pgControl.ActivePage := frmMain.tsSearch;
    PAGE_FAVORITES: frmMain.pgControl.ActivePage := frmMain.tsByGroup;
  else
    raise Exception.Create('Unsupported test view');
  end;
  frmMain.pgControlChange(nil);
end;

procedure TestAdjacentSeriesSelection(const Collection: IBookCollection; OneID, TwoID: Integer);
var Node, FirstBook: PVirtualNode; Data: PSeriesData; Book: PBookRecord;
  I: Integer; Name: string;
  procedure SelectSeries(const SeriesName: string);
  begin
    Node := frmMain.tvSeries.GetFirst;
    while Assigned(Node) do
    begin
      Data := frmMain.tvSeries.GetNodeData(Node);
      if Data.SeriesTitle = SeriesName then Break;
      Node := frmMain.tvSeries.GetNext(Node);
    end;
    Require(Assigned(Node), 'Adjacent series fixture is absent');
    frmMain.tvSeries.ClearSelection;
    frmMain.tvSeries.Selected[Node] := True;
    frmMain.tvSeries.FocusedNode := Node;
    frmMain.tvSeriesChange(frmMain.tvSeries, Node);
    FirstBook := frmMain.tvBooksS.GetFirst;
    while Assigned(FirstBook) do
    begin
      Book := frmMain.tvBooksS.GetNodeData(FirstBook);
      if Book.NodeType = ntBookInfo then Break;
      FirstBook := frmMain.tvBooksS.GetNext(FirstBook);
    end;
    Require(Assigned(FirstBook), 'Adjacent series has no books');
    Require(frmMain.tvBooksS.FocusedNode = FirstBook, 'New series selected its second book');
  end;
begin
  for I := 1 to 3 do
  begin
    AddBook(Collection, 'First group ' + IntToStr(I), 'Selection', 'ru', 'Alpha selection base', 'prose_contemporary');
    AddBook(Collection, 'Second group ' + IntToStr(I), 'Selection', 'ru', 'Alpha selection base[a]', 'prose_contemporary');
  end;
  ChangeCollection(TwoID); ChangeCollection(OneID);
  ShowPage(PAGE_SERIES);
  frmMain.cbLangSelectS.ItemIndex := 0;
  frmMain.cbLangSelectS.OnChange(frmMain.cbLangSelectS);
  for I := 1 to 8 do
  begin
    if Odd(I) then Name := 'Alpha selection base' else Name := 'Alpha selection base[a]';
    SelectSeries(Name);
  end;
  Writeln('PASS adjacent series consistently select the first book without a mutable saved-key race');
end;

procedure RequestRootGenreBooks;
begin
  if frmMain.btnShowGenreBooks.Visible then
    frmMain.btnShowGenreBooksClick(nil);
end;

procedure TestOnlineDownload(const Collection: IBookCollection;
  DirectBookID, QueueBookID, RestartBookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured, SourceFile, ExportDir: string;
  Started: UInt64;
  SourceBytes: TBytes;
  Keys: TBookIdList;
  Worker: TExportToDeviceThread;
  Component: TComponent;
  HasCover: Boolean; I: Integer;

  procedure RequireUnchangedZip;
  var
    Actual: TBytes;
  begin
    Actual := TFile.ReadAllBytes(SourceFile);
    Require((Length(Actual) = Length(SourceBytes)) and
      CompareMem(Pointer(SourceBytes), Pointer(Actual), Length(SourceBytes)),
      'Reading, preview or export rewrote the downloaded ZIP');
  end;

  procedure Pump;
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;

  procedure SelectBook(const BookID: Integer);
  begin
    Node := frmMain.tvBooksA.GetFirst;
    while Assigned(Node) do
    begin
      Book := frmMain.tvBooksA.GetNodeData(Node);
      if Assigned(Book) and (Book.NodeType = ntBookInfo) and
        (Book.BookKey.BookID = BookID) then Break;
      Node := frmMain.tvBooksA.GetNext(Node);
    end;
    Require(Assigned(Node), 'Online book is absent from the visible author list');
    frmMain.tvBooksA.ClearSelection;
    frmMain.tvBooksA.Selected[Node] := True;
    frmMain.tvBooksA.FocusedNode := Node;
    frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  end;

  procedure ReadSelected;
  begin
    Settings.UseBuiltinReaderByDefault:=False;
    if FileExists(Probe) then TFile.Delete(Probe);
    frmMain.ReadBookExecute(nil);
    Started := GetTickCount64;
    while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do Pump;
    Require(FileExists(Probe), 'Online download did not hand a book to the reader');
    Captured := TFile.ReadAllText(Probe, TEncoding.UTF8);
    Require(FileExists(Captured), 'The reader received an absent file');
    Captured := TFile.ReadAllText(Captured, TEncoding.UTF8);
    Require((Pos('Online fixture text', Captured) > 0) and
      (Pos('image/png', Captured) > 0) and (Pos('iVBOR', Captured) > 0) and
      (Pos('UklGR', Captured) = 0),
      'Online reader received the wrong book or unconverted WebP');
  end;

begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.DwnldInterval := 0;
  Settings.AutoStartDwnld := False;
  Settings.SelectedIsChecked := True;
  Settings.ErrorLog := True;
  Settings.Readers.Clear;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  Settings.ShowBookCover := True;
  Settings.ShowBookAnnotation := True;
  Settings.ShowInfoPanel := True;
  frmMain.ipnlAuthors.ShowCover := True;
  frmMain.ipnlAuthors.ShowAnnotation := True;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  SelectBook(DirectBookID);
  Require((Book.GetBookFormat = bfFb2Archive) and
    not (bpIsLocal in Book.BookProps), 'Online fixture must start as a remote FB2 ZIP');
  Trace('online direct reader download');
  ReadSelected;
  Collection.GetBookRecord(CreateBookKey(DirectBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Online direct download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  Require(FileExists(SourceFile), 'Downloaded ZIP is absent');
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  for I:=1 to 100 do begin Application.ProcessMessages; CheckSynchronize(10); Sleep(10); end;
  HasCover := False;
  for Component in frmMain.ipnlAuthors do
    if (Component is TImage) and Assigned(TImage(Component).Picture.Graphic) then
      HasCover := not TImage(Component).Picture.Graphic.Empty;
  Require(HasCover, 'Downloaded WebP cover is absent from the real main info panel');
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main reader downloads ZIP, updates local status, previews cover and reads converted FB2');

  SelectBook(QueueBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Queue fixture is already local');
  Trace('online download queue');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Online book was not added to the real download queue');
  frmMain.btnStartDownloadClick(nil);
  Trace('online queue manager started');
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'Online download queue did not complete successfully');
  Collection.GetBookRecord(CreateBookKey(QueueBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Queue download did not update database and main tree local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  Trace('online queued book downloaded');
  ReadSelected;
  Settings.FileNameTemplate := '%t';
  Settings.FolderTemplate := '';
  ExportDir := TPath.Combine(Settings.AppPath, 'online-export');
  ForceDirectories(ExportDir);
  SetLength(Keys, 1);
  Keys[0].BookKey := Stored.BookKey;
  Worker := TExportToDeviceThread.Create;
  Trace('online export worker created');
  try
    Worker.BookIdList := Keys;
    Worker.ExtractOnly := False;
    Worker.ExportMode := emFB2;
    Worker.DeviceDir := ExportDir;
    Worker.Start;
    Worker.WaitFor;
    Require(not Assigned(Worker.FatalException), 'Online downloaded book export failed');
  finally
    Worker.Free;
  end;
  Captured := TFile.ReadAllText(TPath.Combine(ExportDir, Stored.Title + '.fb2'), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Export of the queued online book lost its text or conversion policy');
  RequireUnchangedZip;
  Writeln('PASS online main queue downloads ZIP and its local book remains readable and exportable');

  SelectBook(RestartBookID);
  Require(not (bpIsLocal in Book.BookProps), 'Restart fixture is already local');
  frmMain.Add2DownloadListExecute(nil);
  Require(frmMain.tvDownloadList.GetFirst <> nil, 'Restart book was not added to the real queue');
  frmMain.btnStartDownloadClick(nil);
  Started := GetTickCount64;
  while ((frmMain.tvDownloadList.GetFirst <> nil) or not frmMain.btnStartDownload.Enabled) and
    (GetTickCount64 - Started < 20000) do Pump;
  Require((frmMain.tvDownloadList.GetFirst = nil) and frmMain.btnStartDownload.Enabled,
    'The completed download manager could not be restarted');
  Collection.GetBookRecord(CreateBookKey(RestartBookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Restart download did not update database and visible local status');
  SourceFile := Stored.GetBookFileName;
  SourceBytes := TFile.ReadAllBytes(SourceFile);
  ReadSelected;
  RequireUnchangedZip;
  Writeln('PASS online main queue restarts for another remote book and preserves its downloaded ZIP');
end;

procedure CreateOnlineResponse;
const
  WEBP = 'UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
  XML = '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ' +
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>' +
    '<author><first-name>Alex</first-name><last-name>Online</last-name></author>' +
    '<book-title>Online payload</book-title><annotation><p>Online fixture annotation</p></annotation>' +
    '<coverpage><image l:href="#cover.jpg"/></coverpage><lang>ru</lang>' +
    '</title-info></description><body><section><p>Online fixture text</p></section></body>' +
    '<binary id="cover.jpg" content-type="image/jpeg">' + WEBP + '</binary></FictionBook>';
var
  Zip: TMHLZip;
  Stream: TBytesStream;
begin
  TFile.WriteAllBytes(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8.GetBytes(XML));
  Zip := TMHLZip.Create(Settings.AppPath + 'download-response.zip', False);
  try
    Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML));
    try
      // Real servers need not use the INPX display filename for their ZIP member.
      Zip.AddFromStream('server-member-name.fb2', Stream);
    finally
      Stream.Free;
    end;
  finally
    Zip.Free;
  end;
end;

function AddOnlineBook(const Collection: IBookCollection;
  const Title, LibID: string; const AsArchive: Boolean = True): Integer;
var
  Book: TBookRecord;
begin
  Book.Clear;
  Book.Title := Title;
  Book.FileName := LibID;
  Book.FileExt := '.fb2';
  Book.LibID := LibID;
  Book.Lang := 'ru';
  Book.Date := EncodeDate(2026, 10, 6);
  TAuthorsHelper.Add(Book.Authors, 'Online', 'Alex', '');
  TGenresHelper.Add(Book.Genres, '', '', 'prose_contemporary');
  if AsArchive then
    Book.Folder := Book.GenerateLocation + FB2ZIP_EXTENSION
  else
    Book.Folder := 'online-plain' + PathDelim;
  Book.InsideNo := 0;
  Result := Collection.InsertBook(Book, False, False);
  Require(Result > 0, 'Online fixture book was not inserted');
end;

procedure TestOnlinePlain(const Collection: IBookCollection; BookID: Integer);
var
  Book: PBookRecord;
  Stored: TBookRecord;
  Node: PVirtualNode;
  Probe, Captured: string;
  Started: UInt64;
begin
  Settings.UseIESettings := False;
  Settings.ProxyType := 0;
  Settings.ProxyServer := '';
  Settings.ProxyPort := 0;
  Settings.TimeOut := 5000;
  Settings.ReadTimeOut := 5000;
  Settings.Readers.Clear;
  Settings.ErrorLog := True;
  Settings.Readers.Add('.fb2', ParamStr(0));
  Settings.OverwriteFB2Info := False;
  Settings.ConvertWebPToPNG := True;
  ChangeCollection(Collection.CollectionID);
  ShowPage(PAGE_AUTHORS);
  Node := frmMain.tvBooksA.GetFirst;
  Require(Assigned(Node), 'Plain online fixture is absent');
  Book := frmMain.tvBooksA.GetNodeData(Node);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID) and
    (Book.GetBookFormat = bfFb2) and not (bpIsLocal in Book.BookProps),
    'Plain online fixture must start remote without a ZIP container');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  Probe := Settings.AppPath + 'reader-probe-path.txt';
  Settings.UseBuiltinReaderByDefault:=False;
  frmMain.ReadBookExecute(nil);
  Started := GetTickCount64;
  while not FileExists(Probe) and (GetTickCount64 - Started < 10000) do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
    Sleep(10);
  end;
  Require(FileExists(Probe), 'Plain remote FB2 was opened before downloading');
  Captured := TFile.ReadAllText(TFile.ReadAllText(Probe, TEncoding.UTF8), TEncoding.UTF8);
  Require((Pos('Online fixture text', Captured) > 0) and
    (Pos('image/png', Captured) > 0) and (Pos('UklGR', Captured) = 0),
    'Plain online reader received the wrong book or unconverted WebP');
  Collection.GetBookRecord(CreateBookKey(BookID, Collection.CollectionID), Stored, False);
  Require((bpIsLocal in Stored.BookProps) and (bpIsLocal in Book.BookProps),
    'Plain online download did not update local status');
  Require(TFile.ReadAllText(Stored.GetBookFileName, TEncoding.UTF8) =
    TFile.ReadAllText(Settings.AppPath + 'online-plain-response.fb2', TEncoding.UTF8),
    'Plain online reader modified the downloaded source');
  Writeln('PASS plain online FB2 is downloaded before compatibility conversion and reader handoff');
end;

type
  TProfileBooks = class(TInterfacedObject, IBookIterator)
  private FIndex: Integer;
  public
    CancelAt: Integer;
    CancelControl: TButton;
    function Next(out Book: TBookRecord): Boolean;
    function RecordCount: Integer;
  end;

function TProfileBooks.RecordCount: Integer;
begin Result := 50000; end;

function TProfileBooks.Next(out Book: TBookRecord): Boolean;
begin
  Result := FIndex < RecordCount;
  if not Result then Exit;
  Inc(FIndex); Book.Clear; Book.nodeType := ntBookInfo;
  if Assigned(CancelControl) and (FIndex = CancelAt) then
  begin
    PostMessage(CancelControl.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(4, 4));
    PostMessage(CancelControl.Handle, WM_LBUTTONUP, 0, MakeLParam(4, 4));
  end;
  Book.BookKey := CreateBookKey(FIndex, Settings.ActiveCollection);
  Book.Title := Format('Profile book %.6d', [FIndex]);
  TAuthorsHelper.Add(Book.Authors, 'Profile', '', '');
  Book.SeriesID := 1 + (FIndex mod 5000);
  Book.Series := Format('Series %.5d', [Book.SeriesID]);
  Book.Lang := 'ru'; Book.FileExt := '.fb2';
end;

procedure TestNestedGenreIterators;
var Collection: IBookCollection; Filter: TFilterValue; First, Second: IBookIterator;
  Book: TBookRecord; ID, I, Count, FirstID: Integer; Criteria: TBookSearchCriteria;
  Publisher: TBookSeries;
begin
  ID := SystemDB.CreateCollection('Nested genres', Settings.AppPath, 'nested-genres.hlc2',
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(ID);
  for I := 1 to 20 do AddBook(Collection, 'Nested ' + IntToStr(I), 'Nested', 'ru', '', 'prose_contemporary', I mod 3 = 0);
  Collection.SetHideDeleted(True); Filter.ValueString := '0.3';
  First := Collection.GetBookIterator(bmByGenreRecursive, False, @Filter);
  Require(First.RecordCount = 14, 'Genre count includes deleted books');
  Require(First.Next(Book), 'First nested iterator has no book');
  Second := Collection.GetBookIterator(bmByGenreRecursive, False, @Filter);
  Require(Second.Next(Book), 'Second nested iterator has no book');
  Second := nil;
  Count := 1; while First.Next(Book) do begin Inc(Count); Require(Length(Book.Authors)=1, 'Genre stream lost author'); end;
  Require(Count=14, 'Destroying second genre iterator changed first membership'); First := nil;
  Collection.SetHideDeleted(False);
  First := Collection.GetBookIterator(bmByGenreRecursive, False, @Filter);
  Require(First.RecordCount=20, 'Genre filter change retained old temporary membership');
  First := nil;
  Criteria := Default(TBookSearchCriteria); Criteria.Deleted := True;
  Criteria.DateIdx := -1; Criteria.CollapseMultiSeriesResults := True;
  First := Collection.Search(Criteria, False);
  Require(First.RecordCount = 14, 'Compact hide-deleted search count is wrong');
  Count := 0; FirstID := 0;
  while First.Next(Book) do
  begin
    Inc(Count); if FirstID = 0 then FirstID := Book.BookKey.BookID;
    Require((Length(Book.Authors) = 1) and (Length(Book.Genres) = 1), 'Bulk search lost metadata');
    Require(Book.PublisherSeriesKnown, 'Bulk search left publisher series unloaded');
  end;
  Require(Count = 14, 'Compact hide-deleted search lost books'); First := nil;
  Collection.AddBookSeries(FirstID, 'First cycle', 1);
  Collection.AddBookSeries(FirstID, 'Second cycle', 2);
  TSeriesHelper.Add(Publisher, 0, 'Publisher cycle', 3, False);
  Collection.SetBookPublisherSeries(CreateBookKey(FirstID, ID), Publisher);
  Criteria.CollapseMultiSeriesResults := False;
  First := Collection.Search(Criteria, False);
  Require(First.RecordCount = 15, 'Expanded hide-deleted search count is wrong');
  Count := 0;
  while First.Next(Book) do
  begin
    Inc(Count); Require(Length(Book.Authors) = 1, 'Expanded second series lost cached authors');
    if Book.BookKey.BookID = FirstID then
      Require((Length(Book.PublisherSeries) = 1) and (Book.PublisherSeries[0].SeriesTitle = 'Publisher cycle'),
        'Expanded search lost preloaded publisher series');
  end;
  Require(Count = 15, 'Expanded search lost a relationship'); First := nil;
  Criteria.Series := 'Second cycle';
  First := Collection.Search(Criteria, False);
  Require((First.RecordCount = 1) and First.Next(Book) and (Book.Series = 'Second cycle'), 'Expanded series search shows nonmatching relationships');
  First := nil; Collection := nil;
  Writeln('PASS compact and expanded bulk searches preserve books, all metadata, counts and matching series');
  Writeln('PASS nested genre iterators retain independent membership and deletion filters without table locks');
end;

type
  TLoadingPaintProbe = class(TCustomControl)
  public PaintCount: Integer;
  protected procedure Paint; override;
  end;

procedure TLoadingPaintProbe.Paint;
begin Inc(PaintCount); Canvas.Brush.Color:=clWindow; Canvas.FillRect(ClientRect); end;

procedure TestAsyncBookPreview;
var Host: TForm; Panel: TInfoPanel; Preview: TBookInfoPreview; Book: TBookRecord;
  Started, Elapsed: UInt64; Viewport: TScrollBox; Content: TWinControl; Annotation: TMemo;
  LockedSource: TFileStream;
  I: Integer; FileName, OriginalHash: string;
  procedure WaitPreview;
  var Deadline: UInt64;
  begin
    Deadline:=GetTickCount64+15000;
    while Preview.Busy and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(5); end;
    Require(not Preview.Busy,'Book preview did not finish');
  end;
begin
  Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host;
  Host.SetBounds(80,100,850,450); Panel.Align:=alClient; Host.Show;
  Preview:=TBookInfoPreview.CreateFor(Host,Panel);
  try
    FileName:=Settings.AppPath+'preview-first.fb2';
    TFile.WriteAllText(FileName,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
      '<description><title-info><book-title>First</book-title><annotation><p>Stale first annotation</p>'+
      '</annotation></title-info></description><body><section><p>'+StringOfChar('x',16*1024*1024)+
      '</p></section></body></FictionBook>',TEncoding.UTF8);
    OriginalHash:=THashSHA2.GetHashStringFromFile(FileName);
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath;
    Book.FileName:='preview-first'; Book.FileExt:='.fb2';
    Panel.SetBookInfo('Immediate title','Author','Series','Genre');
    // Measure user selection after the new host's first paint. Keep the same
    // responsiveness bound, and prove that Load does not need a source handle.
    Application.ProcessMessages; CheckSynchronize(0);
    LockedSource:=TFileStream.Create(FileName,fmOpenRead or fmShareExclusive);
    try
      Started:=GetTickCount64; Preview.Load(Book,True,True,True);
      Elapsed:=GetTickCount64-Started;
      Writeln('PROFILE preview selection_ms=',Elapsed);
      Require(Elapsed<100,'Book preview selection exceeded 100 ms');
      Require(Preview.Busy and (Panel.PreviewStatusText='Загрузка дополнительных сведений из файла…'),
        'Preview tried to read its exclusively locked source during selection');
    finally LockedSource.Free; end;
    // Let the first worker start, then replace it while it is reading.
    Sleep(120); Application.ProcessMessages;
    TFile.WriteAllText(Settings.AppPath+'preview-second.fb2',
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>'+
      '<title-info><book-title>Second</book-title><annotation><p>Latest annotation</p></annotation>'+
      '</title-info></description><body><section><p>Second book</p></section></body></FictionBook>',TEncoding.UTF8);
    Book.FileName:='preview-second'; Preview.Load(Book,True,True,True); WaitPreview;
    Viewport:=nil; Annotation:=nil;
    for I:=0 to Panel.ControlCount-1 do if Panel.Controls[I] is TScrollBox then Viewport:=TScrollBox(Panel.Controls[I]);
    Require(Assigned(Viewport),'Preview viewport absent'); Content:=TWinControl(Viewport.Controls[0]);
    for I:=0 to Content.ControlCount-1 do if Content.Controls[I] is TMemo then Annotation:=TMemo(Content.Controls[I]);
    Require(Assigned(Annotation) and (Pos('Latest annotation',Annotation.Text)>0), 'Latest annotation absent');
    Require(Pos('Stale first annotation',Annotation.Text)=0,'A stale preview replaced the selected book');
    Require(THashSHA2.GetHashStringFromFile(FileName)=OriginalHash,'Preview modified its source');
    TFile.WriteAllText(Settings.AppPath+'preview-missing.fb2',
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>'+
      '<title-info><book-title>'+Char($FFFD)+'broken</book-title></title-info></description>'+
      '<body><section><p>Text</p></section></body></FictionBook>',TEncoding.UTF8);
    Book.FileName:='preview-missing'; Preview.Load(Book,True,True,True); WaitPreview;
    Require((Pos('В файле нет аннотации.',Panel.PreviewStatusText)>0) and
      (Pos('Обложка в метаданных не задана.',Panel.PreviewStatusText)>0) and
      (Pos('Название в метаданных повреждено',Panel.PreviewStatusText)>0),
      'Missing metadata did not explain all three conditions');
    if TFile.Exists(Settings.AppPath+'preview-real.fb2') then
    begin
      OriginalHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'preview-real.fb2');
      Book.FileName:='preview-real'; Book.Title:='Космос Пушкина'; Preview.Load(Book,True,True,True); WaitPreview;
      Require((Pos('В файле нет аннотации.',Panel.PreviewStatusText)>0) and
        (Pos('Обложка в метаданных не задана.',Panel.PreviewStatusText)>0) and
        (Pos('Название в файле отличается от каталога: «ГЛАВА ЧЕТВЁРТАЯ»',Panel.PreviewStatusText)>0) and
        (Pos('Название в метаданных повреждено',Panel.PreviewStatusText)=0),'Real metadata warnings differ: '+Panel.PreviewStatusText);
      Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'preview-real.fb2')=OriginalHash,'Real preview modified copy');
      Writeln('PASS real Cosmos metadata explains missing annotation, cover and different title');
    end;
    Writeln('PASS missing metadata shows explicit explanations without replacing catalogue fields');
    Book.FileName:='preview-first'; Preview.Load(Book,True,True,True);
    Sleep(120); Application.ProcessMessages; FreeAndNil(Preview);
    Writeln('PASS asynchronous book preview keeps latest selection, annotation, source and safe teardown');
  finally Preview.Free; Host.Free; end;
end;



procedure TestArchiveAndImageAudit;
var Source, XML, ImageText, BeforeHash, Prepared, Kind: string;
  Book: TBookRecord; Zip: TZipFile; Stream: TStream; Doc: IXMLFictionBook;
  Bitmap: TBitmap; PNG: TPngImage; Bytes: TBytesStream; Graphic: TGraphic;
  Header: TBytes; W,H,I: Integer;
  procedure CheckDescriptor;
  begin
    Stream:=OpenBookMetadataSource(Book);
    try
      Require(Assigned(Stream),'Selected archive descriptor missing'); Doc:=LoadFB2Description(Stream);
      Require(Doc.Description.Titleinfo.Booktitle.Text='Нужная книга','Description belongs to another archived book');
      Require(GetBookAnnotation(Doc).Contains('Правильная аннотация'),'Selected annotation missing');
      Graphic:=GetBookCover(Doc);
      try Require(Assigned(Graphic) and (Graphic.Width=32) and (Graphic.Height=48),'Original archive cover missing');
      finally Graphic.Free; end;
    finally Doc:=nil; Stream.Free; end;
    Stream:=OpenBookImageSource(Book);
    try Require(Assigned(Stream),'FBD illustration source missing'); finally Stream.Free; end;
  end;
  procedure LE32(P: Integer; Value: Cardinal);
  var J: Integer;
  begin for J:=0 to 3 do Header[P+J]:=(Value shr (8*J)) and $FF; end;
  procedure BE32(P: Integer; Value: Cardinal);
  var J: Integer;
  begin for J:=0 to 3 do Header[P+J]:=(Value shr (8*(3-J))) and $FF; end;
  procedure Magic(P: Integer; const Value: AnsiString);
  var J: Integer;
  begin for J:=1 to Length(Value) do Header[P+J-1]:=Ord(Value[J]); end;
  procedure RejectImage;
  begin
    Stream:=TBytesStream.Create(Header);
    try
      Stream.Position:=3; Require(ImageDimensions(Stream,W,H),'Oversized header not recognized');
      Require(Stream.Position=3,'Header inspection moved caller position');
      Require(not ImageFitsMemory(Stream,64*1024*1024),'Oversized image passed allocation guard');
      Graphic:=CreateGraphicFromStream(Stream);
      try Require(not Assigned(Graphic),'Oversized image decoded before size check'); finally Graphic.Free; end;
      Require(Stream.Position=3,'Rejected decoder moved caller position');
    finally Stream.Free; end;
  end;
begin
  Kind:=ParamStr(2);
  if Kind='images' then
  begin
    SetLength(Header,64); Magic(0,#137'PNG'#13#10#26#10); Magic(12,'IHDR'); BE32(16,100000); BE32(20,100000); RejectImage;
    FillChar(Header[0],Length(Header),0); Magic(0,'BM'); LE32(14,40); LE32(18,100000); LE32(22,100000); RejectImage;
    FillChar(Header[0],Length(Header),0); Magic(0,'GIF89a'); Header[6]:=$FF; Header[7]:=$FF; Header[8]:=$FF; Header[9]:=$FF; RejectImage;
    FillChar(Header[0],Length(Header),0); Magic(0,#255#216#255#192#0#8#8#255#255#255#255); RejectImage;
    FillChar(Header[0],Length(Header),0); Magic(0,'RIFF'); Magic(8,'WEBP'); Magic(12,'VP8X');
    for I:=24 to 29 do Header[I]:=$FF; RejectImage;
    Writeln('PASS PNG JPEG GIF BMP WebP dimensions reject oversized allocation before decoder');
  end else
  begin
    Bitmap:=TBitmap.Create; PNG:=TPngImage.Create; Bytes:=TBytesStream.Create;
    try
      Bitmap.SetSize(32,48); Bitmap.Canvas.Brush.Color:=clBlue; Bitmap.Canvas.FillRect(Rect(0,0,32,48));
      PNG.Assign(Bitmap); PNG.SaveToStream(Bytes); ImageText:=TNetEncoding.Base64.EncodeBytesToString(Copy(Bytes.Bytes,0,Integer(Bytes.Size)));
    finally Bytes.Free; PNG.Free; Bitmap.Free; end;
    XML:='<FictionBook xmlns="'+TargetNamespace+'" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'+
      '<book-title>Нужная книга</book-title><annotation><p>Правильная аннотация</p></annotation>'+
      '<coverpage><image l:href="#cover"/></coverpage></title-info></description><binary id="cover" content-type="image/png">'+ImageText+'</binary></FictionBook>';
    Source:=Settings.AppPath+'archive-books.zip'; Zip:=TZipFile.Create;
    try
      Zip.Open(Source,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes('%PDF-1.4 exact selected book'),'чтение/Книга [1].pdf');
      Zip.Add(TEncoding.UTF8.GetBytes(XML.Replace('Нужная книга','Чужая книга')),'другие/Книга [1].fbd');
      Zip.Add(TEncoding.UTF8.GetBytes(XML),'чтение/Книга [1].fbd');
      Zip.Add(TEncoding.UTF8.GetBytes('%PDF-1.4 another book'),'другие/Другая.pdf');
      Zip.Add(TEncoding.UTF8.GetBytes(XML.Replace('Нужная книга','Другая книга')),'другие/Другая.fbd'); Zip.Close;
    finally Zip.Free; end;
    BeforeHash:=THashSHA2.GetHashStringFromFile(Source);
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath; Book.Folder:='archive-books.zip';
    Book.FileName:='чтение/Книга [1]'; Book.FileExt:='.pdf'; CheckDescriptor;
    Prepared:=PrepareReaderFile(Book); Require(SameText(ExtractFileExt(Prepared),'.pdf'),'Archive launched archive handler');
    Require(TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('exact selected book'),'Wrong archived book opened');
    Book.FileName:='bad metadata'; Book.FileExt:='.pdf'; Book.InsideNo:=0; CheckDescriptor;
    Prepared:=PrepareReaderFile(Book); Require(TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('exact selected book'),'Catalog locator selects wrong reading member');
    Book.FileExt:='.295510'; CheckDescriptor;
    Book.Folder:=''; Book.FileName:='archive-books.zip'; Book.FileExt:='';
    Stream:=OpenBookMetadataSource(Book); try Require(not Assigned(Stream),'Ambiguous multi-book archive borrowed unrelated description'); finally Stream.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Source)=BeforeHash,'Reading or metadata modified source archive');
    Writeln('PASS exact archived PDF opens with its own FBD annotation and original cover; UTF8 nested paths, brackets, damaged catalog locator and ambiguity preserve source');
  end;
  Writeln('PASS adversarial audit fixed checks with isolated fixture');
end;

procedure TestAdversarialAudit;
var Kind, Root, Name, Other, Dest, Probe, Text, ErrorText, ArchivePath: string;
  Started, FirstTime, SecondTime: UInt64; I, N, BeforeCount, AfterCount: Integer;
  Stream: TStream; FileStream: TFileStream; ByteValue: Byte; Worker: TThread;
  Tree: TBookTree; Filters: TBookColumnFilters; Node: PVirtualNode; Data: PBookRecord;
  Names: TStringList; Config: TfrmSettings; Book: TBookRecord; Scope: TBookCacheWrite;
  procedure AwaitMigration;
  var Since: UInt64;
  begin Since:=GetTickCount64; while BookCacheMigrationBusy and (GetTickCount64-Since<35000) do
    begin CheckSynchronize(0); Sleep(20); end;
  end;
begin
  Kind:=ParamStr(2); Settings.ClearBookCacheOnExit:=False;
  Settings.BookCacheLimitMB:=5120;
  if Kind='legacy' then
  begin
    AwaitMigration;
    Require(not BookCacheMigrationBusy and not BookCacheMigrationPending,'Legacy transfer did not complete');
    Other:=TPath.Combine(Settings.AppPath,'legacy-read');
    Name:=TPath.Combine(Other,'homelib-owned.pdf'); Dest:=TPath.Combine(BookCachePath,ExtractFileName(Name));
    Require(not FileExists(Name) and FileExists(Dest),'Owned legacy cache was not moved');
    Require(TFile.ReadAllText(Dest,TEncoding.UTF8)='legacy owned book','Legacy bytes changed');
    Require(TFile.ReadAllText(TPath.Combine(Other,'personal.pdf'),TEncoding.UTF8)='personal preserved','Legacy transfer changed personal file');
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath; Book.Folder:='legacy-source.zip';
    Book.FileName:='book'; Book.FileExt:='.pdf';
    Settings.ReadDir:=Other;
    Dest:=PrepareReaderFile(Book); Require(SameFileName(ExtractFileDir(Dest),BookCachePath),'Explicit ReadDir bypassed managed cache');
    frmMain.ClearReadFolderExecute(nil); Require(not FileExists(Dest),'New prepared copy bypassed cache cleanup');
    Require(FileExists(TPath.Combine(Other,'personal.pdf')),'Cache cleanup deleted personal legacy file');
    Writeln('PASS legacy owned cache migrates, personal files survive, explicit reading folder cannot bypass managed cache');
    Writeln('PASS adversarial audit fixed checks with isolated fixture'); Exit;
  end;
  ClearBookCache; Root:=BookCachePath;
  ForceDirectories(Root);
  if Kind='filters' then
  begin
    Tree:=frmMain.tvBooksA; Filters:=TBookColumnFilters.ForTree(Tree); Filters.Clear;
    Node:=Tree.GetFirst; I:=0;
    while Assigned(Node) do
    begin
      Data:=Tree.GetNodeData(Node);
      if Data.NodeType=ntBookInfo then
      begin
        case I of
          0: begin Data.Title:='творца'; Data.FileExt:='.pdf'; end;
          1: begin Data.Title:='Творца'; Data.FileExt:='.epub'; end;
        else begin Data.Title:='Другой'; Data.FileExt:='.pdf'; end;
        end;
        Inc(I);
      end;
      Node:=Tree.GetNext(Node);
    end;
    Filters.SetCaseSensitive(COL_TITLE,True); Filters.SetValue(COL_TITLE,'твор');
    BeforeCount:=Filters.Apply; Filters.SetValue(COL_TITLE,'Твор'); AfterCount:=Filters.Apply;
    Writeln('OBSERVE case-sensitive change lower=',BeforeCount,' upper incremental=',AfterCount);
    Filters.Clear; Filters.SetCaseSensitive(COL_TITLE,True); Filters.SetValue(COL_TITLE,'Твор'); N:=Filters.Apply;
    Writeln('OBSERVE same uppercase filter fresh=',N);
    Require((BeforeCount=1) and (AfterCount=1) and (N=1),'Case-sensitive change narrowed the old subset');
    Writeln('REGRESSION originally: case-sensitive filter incorrectly narrows when only letter case changes');
    Filters.Clear; Filters.Apply; Names:=TStringList.Create;
    try
      Filters.GetOptions(COL_TYPE,Names); BeforeCount:=Names.Count;
      Filters.SetValue(COL_TYPE,'=pdf'); Filters.Apply; Filters.GetOptions(COL_TYPE,Names);
      Writeln('OBSERVE type choices before=',BeforeCount,' after own filter=',Names.Count,' EPUB available=',Names.IndexOf('epub')>=0);
      Require((BeforeCount=2) and (Names.Count=2) and (Names.IndexOf('epub')>=0),'Own format filter restricts available choices');
      Filters.SetValue(COL_TYPE,'=epub'); Require(Filters.Apply=1,'Direct PDF to EPUB switch failed');
      Writeln('REGRESSION originally: reopening format filter cannot directly select a different loaded format');
    finally Names.Free; end;
  end
  else if Kind='orphan' then
  begin
    Name:=TPath.Combine(Root,'homelib-orphan.fb2.pending-99999999');
    FileStream:=TFileStream.Create(Name,fmCreate); try FileStream.Size:=1024*1024; finally FileStream.Free; end;
    Writeln('OBSERVE orphan disk bytes=',TFile.GetSize(Name),' reported bytes=',BookCacheUsage);
    ClearBookCache;
    Require(not FileExists(Name) and (BookCacheUsage=0),'Stale pending file survived clear');
    Writeln('REGRESSION originally: stale pending file is invisible to usage, size limit and clear');
  end
  else if Kind='nested' then
  begin
    ChangeBookCacheDirectory(Root); AwaitMigration;
    Name:=TPath.Combine(BookCachePath,'homelib-nested.fb2'); Dest:=CurrentBookCacheFile(Name);
    Writeln('OBSERVE intended path=',Name); Writeln('OBSERVE rewritten path=',Dest);
    Require(SameFileName(Name,Dest) and SameFileName(BookCachePath,Root),'Selecting cache root nested the path');
    Writeln('REGRESSION originally: selecting cache root as its parent remaps new files into a second nested subdirectory');
  end
  else if Kind='collision' then
  begin
    Name:=TPath.Combine(Root,'homelib-collision.fb2'); TFile.WriteAllText(Name,'NEW-current-book',TEncoding.UTF8);
    Other:=TPath.Combine(Settings.AppPath,'previous-cache'); Dest:=TPath.Combine(Other,'HomeLibRu-BookCache');
    ForceDirectories(Dest); Dest:=TPath.Combine(Dest,ExtractFileName(Name));
    TFile.WriteAllText(Dest,'OLD-stale-book',TEncoding.UTF8);
    RefreshBookCache(True); ChangeBookCacheDirectory(Other); AwaitMigration;
    Text:=TFile.ReadAllText(Dest,TEncoding.UTF8);
    Writeln('OBSERVE destination=',Text,' current source survives=',FileExists(Name));
    Require((Text='NEW-current-book') and not FileExists(Name),'Transfer kept stale destination');
    Writeln('REGRESSION originally: transfer discards current cache when destination already contains stale file with same name');
  end
  else if Kind='failure' then
  begin
    Name:=TPath.Combine(Root,'homelib-failure.fb2'); TFile.WriteAllText(Name,'current book',TEncoding.UTF8);
    Other:=TPath.Combine(Settings.AppPath,'bad-cache'); Dest:=TPath.Combine(Other,'HomeLibRu-BookCache');
    ForceDirectories(Dest);
    Probe:=TPath.Combine(Dest,ExtractFileName(Name)+'.pending-transfer-'+IntToStr(GetCurrentProcessId));
    ForceDirectories(Probe); RefreshBookCache(True); ChangeBookCacheDirectory(Other); AwaitMigration;
    Writeln('OBSERVE busy=',BookCacheMigrationBusy,' transfer error=',BookCacheMigrationError);
    Require(BookCacheMigrationError<>'','Expected blocked transfer did not report its error');
    ErrorText:=''; try ChangeBookCacheDirectory(TPath.Combine(Settings.AppPath,'good-cache'));
    except on E: Exception do ErrorText:=E.Message; end;
    Writeln('OBSERVE attempt to choose working directory=',ErrorText);
    Require(ErrorText='','Failed migration blocked recovery: '+ErrorText); AwaitMigration;
    Dest:=TPath.Combine(BookCachePath,ExtractFileName(Name));
    Require(FileExists(Dest) and (TFile.ReadAllText(Dest,TEncoding.UTF8)='current book'),'Recovery lost current book');
    Writeln('REGRESSION originally: failed transfer blocks choosing a different directory although no transfer is running');
  end
  else if (Kind='inflight') or (Kind='source-inflight') then
  begin
    ArchivePath:=ParamStr(3); Require(FileExists(ArchivePath),'Real read-only Amber input unavailable');
    Book:=Default(TBookRecord); Book.CollectionRoot:=ExtractFilePath(ArchivePath);
    Book.Folder:=ExtractFileName(ArchivePath); Book.FileName:='793007'; Book.FileExt:='.fb2';
    Book.Size:=17487703; Book.InsideNo:=0; Book.BookProps:=[bpIsLocal];
    ErrorText:='';
    Worker:=TThread.CreateAnonymousThread(procedure
      var Input: TStream;
      begin
        try Input:=OpenRawBookSource(Book); try Require(Input.Size=17487703,'Amber size changed'); finally Input.Free; end;
        except on E: Exception do ErrorText:=E.Message; end;
      end);
    Worker.FreeOnTerminate:=False;
    try
      Worker.Start; Sleep(500); Require(not Worker.Finished,'Input decoded too quickly for clear race');
      if Kind='source-inflight' then RemoveBookCacheSource(Book.CollectionRoot,[]) else ClearBookCache;
      Writeln('OBSERVE bytes immediately after invalidation=',BookCacheUsage);
      Worker.WaitFor; Require(Pos('кэш очищен',ErrorText)>0,'In-flight writer was not invalidated: '+ErrorText);
      Writeln('OBSERVE bytes after previously active decoder completes=',BookCacheUsage);
      Require(BookCacheUsage=0,'In-flight decoder republished cache after clear');
      Writeln('REGRESSION originally: clearing cache does not invalidate previously started book extraction');
    finally Worker.Free; end;
  end
  else if Kind='active-pending' then
  begin
    Name:=TPath.Combine(Root,'homelib-active.fb2'); Scope:=TBookCacheWrite.Create(Settings.AppPath+'source.fb2');
    try
      Other:=Scope.TemporaryName(Name); FileStream:=TFileStream.Create(Other,fmCreate);
      try FileStream.Size:=1024*1024; finally FileStream.Free; end;
      RefreshBookCache(True); Require(BookCacheUsage>=1024*1024,'Active pending bytes not counted');
      ClearBookCache; Require(FileExists(Other),'Clear deleted an active writer temporary file');
      ErrorText:=''; try Scope.Publish(Other,Name); except on E: EAbort do ErrorText:=E.Message; end;
      Require(ErrorText<>'','Canceled active writer still published');
    finally Scope.Free; end;
    Require(not FileExists(Other) and (BookCacheUsage=0),'Canceled temporary file leaked');
  end
  else if Kind='return' then
  begin
    Name:=TPath.Combine(Root,'homelib-return.fb2'); TFile.WriteAllText(Name,'fresh',TEncoding.UTF8);
    RegisterBookCacheFile(Name,Settings.AppPath+'source.fb2');
    Other:=TPath.Combine(Settings.AppPath,'return-other'); ChangeBookCacheDirectory(Other); AwaitMigration;
    Require(FileExists(CurrentBookCacheFile(Name)),'First move lost file');
    ChangeBookCacheDirectory(''); AwaitMigration; Require(SameFileName(BookCachePath,Root),'Return did not restore default root');
    Dest:=CurrentBookCacheFile(Name); Require(FileExists(Dest),'Return move lost file');
    Require(SameFileName(Dest,TPath.Combine(BookCachePath,ExtractFileName(Name))),'Return move remaps into nested folder');
    Require(TFile.ReadAllText(Dest,TEncoding.UTF8)='fresh','Return changed bytes');
  end
  else if Kind='performance' then
  begin
    frmMain.BookCacheActionUpdate(nil); Started:=GetTickCount64;
    for I:=1 to 5 do frmMain.BookCacheActionUpdate(nil); FirstTime:=GetTickCount64-Started;
    for I:=1 to 5000 do
    begin
      Name:=TPath.Combine(Root,'homelib-bench-'+IntToStr(I)+'.fb2');
      FileStream:=TFileStream.Create(Name,fmCreate); try ByteValue:=1; FileStream.WriteBuffer(ByteValue,1); finally FileStream.Free; end;
      TFile.WriteAllText(Name+'.origin',TPath.Combine(Settings.AppPath,'original.fb2'),TEncoding.UTF8);
    end;
    RefreshBookCache(True); Started:=GetTickCount64;
    for I:=1 to 5 do frmMain.BookCacheActionUpdate(nil); SecondTime:=GetTickCount64-Started;
    Writeln('PROFILE five UI cache updates empty ms=',FirstTime,' 5000 entries ms=',SecondTime,' average ms=',SecondTime div 5);
    Require(SecondTime<500,'Cache UI counter still blocks the main thread');
  end
  else raise Exception.Create('Unknown audit case');
  Writeln('PASS adversarial audit fixed checks with isolated fixture');
end;

procedure TestPersistentCache;
var A,B,C,Root,OtherRoot,Folder,Origin: string; Stream: TStream; Writer: TFileStream;
  Configuration: TfrmSettings; Status: TMHLOperationStatus; Started: UInt64;
  SettingsCopy: TMHLSettings; LoadedBytes: TBytes;
  procedure AddCache(const Name, Source: string; Size: Integer);
  begin
    Writer:=TFileStream.Create(Name,fmCreate);
    try Writer.Size:=Size; finally Writer.Free; end;
    RegisterBookCacheFile(Name,Source);
  end;
begin
  Require(Settings.BookCacheLimitMB=5120,'New cache default is not 5 GiB');
  Require(Settings.ClearBookCacheOnExit,'New profile must clear cache at exit by default');
  Settings.ClearBookCacheOnExit:=False;
  frmMain.ClearReadFolderExecute(nil); ForceDirectories(BookCachePath);
  Root:=TPath.Combine(Settings.AppPath,'cache-source'); OtherRoot:=Root+'-other';
  ForceDirectories(Root); ForceDirectories(OtherRoot);
  Origin:=TPath.Combine(Root,'original.fb2'); TFile.WriteAllText(Origin,'original unchanged',TEncoding.UTF8);
  A:=TPath.Combine(BookCachePath,'homelib-cache-a.fb2');
  B:=TPath.Combine(BookCachePath,'homelib-cache-b.fb2');
  C:=TPath.Combine(BookCachePath,'homelib-cache-c.fb2');
  Settings.BookCacheLimitMB:=2;
  AddCache(A,Origin,400*1024); Sleep(30); AddCache(B,Origin,400*1024); Sleep(30);
  Stream:=OpenCachedBookFile(A); Stream.Free; Sleep(30);
  AddCache(C,TPath.Combine(OtherRoot,'other.fb2'),400*1024);
  Settings.BookCacheLimitMB:=1; TrimBookCache;
  Require(not FileExists(B) and FileExists(A) and FileExists(C),'LRU eviction or cache limit failed');
  Require(BookCacheUsage<=1024*1024,'Cache exceeds configured byte limit');
  Settings.BookCacheLimitMB:=2; AddCache(A,Origin,400*1024);
  Stream:=OpenCachedBookFile(A);
  try RemoveBookCacheSource(Root,[]); Require(FileExists(A),'An active stream was removed');
  finally Stream.Free; end;
  Require(not FileExists(A) and FileExists(C),'Disconnected-source deferred cleanup failed');
  AddCache(A,Origin,100); RemoveBookCacheSource(Root,[Root]);
  Require(FileExists(A),'Shared connected source cache was removed');
  FinishBookCacheSession; Require(FileExists(A),'Disabled exit cleanup lost persistent cache');
  Settings.ClearBookCacheOnExit:=True; FinishBookCacheSession;
  Require(not FileExists(A) and not FileExists(C),'Optional exit cleanup failed');
  Require(TFile.ReadAllText(Origin,TEncoding.UTF8)='original unchanged','Cache cleanup damaged original');
  Writeln('PASS bounded persistent cache evicts least recently used files, defers active deletion and preserves shared sources');
  Settings.ClearBookCacheOnExit:=False; Settings.BookCacheLimitMB:=5120;
  AddCache(A,Origin,900*1024); frmMain.BookCacheActionUpdate(nil);
  Require(frmMain.acToolsClearReadFolder.Caption.Contains('МБ'),'Cache menu has no live size');
  Configuration:=TfrmSettings.Create(nil);
  try
    Configuration.LoadSetting;
    Require((Pos('Занято:',TLabel(Configuration.FindComponent('lblBookCacheUsage')).Caption)>0),'Settings has no live cache level');
    Require(TComboBox(Configuration.FindComponent('cbBookCacheUnit')).Items.Count=2,'Cache units missing');
    Require(not TCheckBox(Configuration.FindComponent('cbClearBookCacheOnExit')).Checked,'Explicitly disabled exit toggle was lost');
    Require(Assigned(Configuration.FindComponent('btnClearBookCache')),'Settings cleanup button absent');
    TEdit(Configuration.FindComponent('edBookCacheLimit')).Text:='1,5';
    Configuration.SaveSettings;
    Require(Settings.BookCacheLimitMB=1536,'Fractional cache GiB conversion failed');
    Folder:=TPath.Combine(Settings.AppPath,'custom-cache'); ForceDirectories(Folder);
    TFile.WriteAllText(TPath.Combine(Folder,'keep-personal.txt'),'keep',TEncoding.UTF8);
    TComboBox(Configuration.FindComponent('cbBookCacheUnit')).ItemIndex:=0;
    TEdit(Configuration.FindComponent('edBookCacheLimit')).Text:='1';
    TEdit(Configuration.FindComponent('edBookCacheDirectory')).Text:=Folder;
    Configuration.SaveSettings;
  finally Configuration.Free; end;
  Started:=GetTickCount64;
  while not FileExists(TPath.Combine(BookCachePath,ExtractFileName(A))) and (GetTickCount64-Started<10000) do
  begin Application.ProcessMessages; CheckSynchronize(0); Sleep(10); end;
  B:=TPath.Combine(BookCachePath,ExtractFileName(A));
  Require(FileExists(B) and FileExists(B+'.origin'),'Accumulated cache did not transfer automatically');
  TrimBookCache;
  Require(FileExists(A) and FileExists(B),'Transfer counted one book twice and evicted its cache');
  Stream:=OpenCachedBookFile(A); Stream.Free;
  Started:=GetTickCount64;
  while BookCacheMigrationBusy and (GetTickCount64-Started<35000) do
  begin Application.ProcessMessages; CheckSynchronize(0); Sleep(20); end;
  Require(not BookCacheMigrationBusy and not FileExists(A),'Old cache was not removed after transfer');
  Require(SameFileName(CurrentBookCacheFile(A),B),'Late cache writer retains the retired directory');
  LoadedBytes:=TFile.ReadAllBytes(B); Require(Length(LoadedBytes)=900*1024,'Transferred bytes truncated');
  // A clear during an unfinished move must cover both roots and not reappear.
  Stream:=OpenCachedBookFile(B);
  try
    ChangeBookCacheDirectory(Folder+'-second');
    ClearBookCache;
    Require(FileExists(B),'Transfer cleanup removed an active stream');
  finally Stream.Free; end;
  Started:=GetTickCount64;
  while BookCacheMigrationBusy and (GetTickCount64-Started<5000) do
  begin Application.ProcessMessages; CheckSynchronize(0); Sleep(20); end;
  Require(not BookCacheMigrationBusy and (BookCacheUsage=0),'Clear during transfer republished deleted cache');
  Require(not FileExists(B),'Retired active copy survived stream release');
  Folder:=Folder+'-second';
  Configuration:=TfrmSettings.Create(nil);
  try
    Configuration.LoadSetting;
    B:=TPath.Combine(BookCachePath,'homelib-settings-cleanup.fb2'); AddCache(B,Origin,50);
    TButton(Configuration.FindComponent('btnClearBookCache')).Click;
    Require(not FileExists(B),'Settings cleanup button did not clear cache');
    if ParamStr(2)='visual' then
    begin
      Settings.ClearBookCacheOnExit:=True; Configuration.LoadSetting;
      Configuration.ShowModal; Settings.ClearBookCacheOnExit:=False;
    end;
  finally Configuration.Free; end;
  Settings.SaveSettings;
  SettingsCopy:=TMHLSettings.Create;
  try SettingsCopy.LoadSettings;
    Require(SettingsCopy.BookCacheDirectory=Folder,'Custom cache directory did not persist');
    Require(SettingsCopy.BookCacheLimitMB=1,'Cache size setting did not persist');
    Require(not SettingsCopy.ClearBookCacheOnExit,'Explicitly disabled cleanup did not persist');
  finally SettingsCopy.Free; end;
  Writeln('PASS cache menu and settings show live size, fractional MB/GB limits persist, existing cache moves in background');
  Status:=TMHLOperationStatus.Create('Распаковка книги из архива…',True);
  try
    Require(not Status.Visible,'Fast operation flashes a status window');
    Sleep(450); Status.Pulse; Require(Status.Visible,'Slow opening has no cursor status');
    Status.SetStage('Открытие книги…');
  finally Status.Free; end;
  Require(not Assigned(MHLExternalToolHeartbeat),'Decoder status callback survived destruction');
  ClearBookCache;
  Require(TFile.ReadAllText(TPath.Combine(Folder.Substring(0,Length(Folder)-7),'keep-personal.txt'),TEncoding.UTF8)='keep','Custom directory cleanup removed unrelated data');
  Writeln('PASS delayed cursor status has no fast-operation flicker and custom cache cleanup preserves other files');
end;

procedure TestFeedback14;
var Tree: TBookTree; Filters: TBookColumnFilters; Node: PVirtualNode; Data: PBookRecord;
  I: Integer; Names: TStringList; Item: TMenuItem; Column: TVirtualTreeColumn;
  Keys: TArray<TBookSortKey>; Reset: TButton; Component: TComponent;
  Book: TBookRecord; Source, Inner, XML, ImageText, BeforeHash, Prepared: string;
  Zip: TZipFile; ImageStream, Stream: TStream; Document: IXMLFictionBook;
  Bitmap: TBitmap; Png: TPngImage; ImageBytes: TBytesStream;
  Started: UInt64; Pictures: Integer; Loader: TGalleryLoader;
  procedure ExpectOrder(const Expected: array of Integer);
  var N: PVirtualNode; B: PBookRecord; Index: Integer;
  begin
    N := Tree.GetFirst; Index := 0;
    while Assigned(N) do
    begin
      B := Tree.GetNodeData(N);
      Writeln('TRACE sort row ',Index,' order=',B.ListOrder,' expected=',Expected[Index]);
      Require(B.ListOrder = Expected[Index],'Multi-column sort returned wrong order');
      Inc(Index); N := Tree.GetNext(N);
    end;
    Require(Index=Length(Expected),'Sort lost rows');
  end;
  procedure ClickSortColumn(Tag: Integer);
  var Hit: TVTHeaderHitInfo; LeftEdge, RightEdge: TDimension; J: Integer;
  begin
    Hit:=Default(TVTHeaderHitInfo); Hit.Column:=NoColumn; Hit.Button:=mbLeft;
    for J:=0 to Tree.Header.Columns.Count-1 do
      if Tree.Header.Columns[J].Tag=Tag then Hit.Column:=J;
    Require(Hit.Column>=0,'Sort column missing from header');
    Tree.Header.Columns.GetColumnBounds(Hit.Column,LeftEdge,RightEdge);
    Hit.X:=LeftEdge+10;
    frmMain.tvBooksTreeHeaderClick(Tree.Header,Hit);
  end;
  procedure RequireDescriptor;
  var Cover: TGraphic;
  begin
    Stream := Book.GetBookDescriptorStream(False);
    try
      Require(Assigned(Stream),'Archive FBD is absent'); Document := LoadFB2Description(Stream);
      Require(Pos('Настоящая аннотация',GetBookAnnotation(Document))>0,'FBD annotation is absent');
      Cover := GetBookCover(Document);
      try Require(Assigned(Cover) and (Cover.Width=32) and (Cover.Height=48),'FBD cover is absent');
      finally Cover.Free; end;
    finally Document := nil; Stream.Free; end;
  end;
begin
  TestBookColumnFilters; Tree := frmMain.tvBooksA; Filters := TBookColumnFilters.ForTree(Tree);
  Names := TStringList.Create;
  try
    Node := Tree.GetFirst; I := 0;
    while Assigned(Node) do
    begin
      Data := Tree.GetNodeData(Node);
      if Data.NodeType=ntBookInfo then
      begin
        Data.Series := 'Серия '+IntToStr(I); Inc(I);
        if Data.Rate=5 then begin Data.FileExt := '._Современный_этикет'; Data.FileName := 'actual.pdf'; end;
        if Data.Rate=3 then begin Data.FileExt := '.295510'; Data.FileName := 'actual'; end;
      end;
      Node := Tree.GetNext(Node);
    end;
    Filters.SetValue(COL_RATE,'set;5'); Require(Filters.Apply=1,'Rating selection failed');
    Filters.GetOptions(COL_SERIES,Names); Require(Names.Count=1,'Series menu ignores remaining rows');
    Filters.GetOptions(COL_TYPE,Names); Require((Names.Count=1) and (Names[0]='pdf'),'Invalid catalog extension did not use real suffix');
    Filters.Clear; Filters.Apply; Filters.GetOptions(COL_TYPE,Names);
    Require((Names.IndexOf('295510')<0) and (Names.IndexOf('_Современный_этикет')<0),'Malformed catalog type leaked into formats');
    Filters.SetValue(COL_TITLE,'твор'); frmMain.ApplyBookColumnFilters(Tree);
    Reset := nil;
    for Component in frmMain do
      if (Component is TButton) and (TButton(Component).Parent=frmMain.lblBooksTotalA.Parent) and
        (TButton(Component).Caption='Сбросить фильтры столбцов') then Reset := TButton(Component);
    Require(Assigned(Reset) and Reset.Visible,'Reset button beside count is absent');
    frmMain.edFTitle.Text := 'Сохранить'; frmMain.cbDeleted.Checked := True; Reset.Click;
    Require((Filters.Count=0) and (frmMain.edFTitle.Text='Сохранить') and frmMain.cbDeleted.Checked,
      'Reset erased sidebar filters');
    Require(frmMain.edFAnnotation.Enabled,'Sidebar annotation field is disabled');
    frmMain.edFTitle.Text := ''; frmMain.cbDeleted.Checked := False;
    Writeln('PASS visible-result series choices, valid formats, reset preserves sidebar and annotation input is active');
  finally Names.Free; end;
  if Settings.TreeModes[Tree.Tag]=tmTree then frmMain.btnSwitchTreeModeClick(nil);
  Require(Settings.TreeModes[Tree.Tag]=tmFlat,'Sort fixture is not flat');
  Item := nil; for I:=0 to frmMain.pmHeaders.Items.Count-1 do
    if frmMain.pmHeaders.Items[I].Tag=COL_PUBLISHER_SERIES then Item := frmMain.pmHeaders.Items[I];
  Require(Assigned(Item),'Publisher-series column menu absent');
  for I:=0 to Tree.Header.Columns.Count-1 do
    Require(Tree.Header.Columns[I].Tag<>COL_PUBLISHER_SERIES,'Publisher-series column enabled by default');
  Item.Click;
  Require(Item.Checked,'Publisher-series column did not turn on');
  I := 0; Node := Tree.GetFirst;
  while Assigned(Node) do
  begin
    Data := Tree.GetNodeData(Node); Data.ListOrder := I; Data.Lang := 'ru';
    case I of
      0: begin Data.Size := 20; Data.Title := 'Z'; end;
      1: begin Data.Size := 10; Data.Title := 'A'; end;
      2: begin Data.Size := 10; Data.Title := 'B'; end;
    end;
    Inc(I); Node := Tree.GetNext(Node);
  end;
  Item := nil; for I:=0 to frmMain.pmHeaders.Items.Count-1 do
    if frmMain.pmHeaders.Items[I].Tag=COL_LANG then Item := frmMain.pmHeaders.Items[I];
  Require(Assigned(Item),'Language column menu absent');
  if not Item.Checked then Item.Click;
  SetLength(Keys,3); Keys[0].Tag:=COL_LANG; Keys[0].Direction:=sdAscending;
  Keys[1].Tag:=COL_SIZE; Keys[1].Direction:=sdDescending;
  Keys[2].Tag:=COL_TITLE; Keys[2].Direction:=sdDescending;
  Tree.SortKeys:=Keys; frmMain.SortLoadedBooks(Tree); ExpectOrder([0,2,1]);
  Keys[0].Direction:=sdDescending; Tree.SortKeys:=Keys; frmMain.SortLoadedBooks(Tree); ExpectOrder([0,2,1]);
  frmMain.ClearBookSorting(nil); ExpectOrder([0,1,2]);
  Require(Tree.Header.SortColumn=NoColumn,'Clear sort retained a header sort');
  Writeln('PASS optional publisher-series column, three sort priorities and explicit restoration of catalog order');
  Node:=Tree.GetFirst; I:=0;
  while Assigned(Node) do
  begin
    Data:=Tree.GetNodeData(Node); SetLength(Data.Authors,1); Data.Authors[0]:=Default(TAuthorData);
    if I<2 then Data.Authors[0].LastName:='Автор А' else Data.Authors[0].LastName:='Автор Б';
    Inc(I); Node:=Tree.GetNext(Node);
  end;
  Item := nil; for I:=0 to frmMain.pmHeaders.Items.Count-1 do
    if frmMain.pmHeaders.Items[I].Tag=COL_AUTHOR then Item := frmMain.pmHeaders.Items[I];
  Require(Assigned(Item),'Author column menu absent');
  if not Item.Checked then Item.Click;
  ClickSortColumn(COL_TITLE); ExpectOrder([1,2,0]);
  ClickSortColumn(COL_AUTHOR); ExpectOrder([1,0,2]);
  Require((Length(Tree.SortKeys)=2) and (Tree.SortKeys[0].Tag=COL_AUTHOR) and (Tree.SortKeys[1].Tag=COL_TITLE),
    'A normal author click discarded the preceding title priority');
  ClickSortColumn(COL_AUTHOR); ExpectOrder([2,1,0]);
  ClickSortColumn(COL_TITLE); ExpectOrder([1,2,0]);
  ClickSortColumn(COL_TITLE); ExpectOrder([0,2,1]);
  ClickSortColumn(COL_AUTHOR); ExpectOrder([2,0,1]);
  frmMain.ClearBookSorting(nil); ExpectOrder([0,1,2]);
  Writeln('PASS ordinary header clicks retain author/title priorities in both directions and reset restores original order');


  Bitmap:=TBitmap.Create; Png:=TPngImage.Create; ImageBytes:=TBytesStream.Create;
  try
    Bitmap.SetSize(32,48); Bitmap.Canvas.Brush.Color:=clBlue; Bitmap.Canvas.FillRect(Rect(0,0,32,48));
    Png.Assign(Bitmap); Png.SaveToStream(ImageBytes);
    ImageText:=TNetEncoding.Base64.EncodeBytesToString(Copy(ImageBytes.Bytes,0,Integer(ImageBytes.Size)));
  finally ImageBytes.Free; Png.Free; Bitmap.Free; end;
  XML := '<FictionBook xmlns="'+TargetNamespace+'" xmlns:l="http://www.w3.org/1999/xlink">'+
    '<description><title-info><book-title>Рубаийат</book-title><annotation><p>Настоящая аннотация</p></annotation>'+
    '<coverpage><image l:href="#original"/></coverpage></title-info></description>'+
    '<body><section><p>Недопустимый символ &#xDC50;</p></section></body>'+
    '<binary id="original" content-type="image/png">'+ImageText+'</binary></FictionBook>';
  Stream:=TStringStream.Create(XML,TEncoding.UTF8);
  try
    Document:=LoadFB2Description(Stream);
    Require(Pos('Настоящая аннотация',GetBookAnnotation(Document))>0,'Broken body hides valid metadata');
    Pictures:=0; VisitFB2Images(Stream,procedure(const Name: string; Image: TStream) begin Inc(Pictures); end);
    Require(Pictures=1,'Broken body hides original illustration');
  finally Document:=nil; Stream.Free; end;
  Inner:=Settings.AppPath+'nested-inner.zip'; Source:=Settings.AppPath+'nested-outer.zip';
  Zip:=TZipFile.Create;
  try
    Zip.Open(Inner,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes(XML),'readable.fbd');
    Zip.Add(TEncoding.UTF8.GetBytes('%PDF-1.4 preserved original bytes'),'readable.pdf'); Zip.Close;
    Zip.Open(Source,zmWrite); Zip.Add(TFile.ReadAllBytes(Inner),'member.zip');
    Zip.Add(TEncoding.UTF8.GetBytes(XML),'direct.fbd');
    Zip.Add(TEncoding.UTF8.GetBytes('%PDF-1.4 direct original'),'direct.pdf'); Zip.Close;
  finally Zip.Free; end;
  BeforeHash:=THashSHA2.GetHashStringFromFile(Source);
  Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath; Book.Folder:='nested-outer.zip';
  Book.FileName:='member'; Book.FileExt:='.zip'; Book.LibID:='nested fixture'; Book.BookKey.BookID:=999;
  RequireDescriptor;
  Prepared:=PrepareReaderFile(Book); Require(SameText(ExtractFileExt(Prepared),'.pdf'),'Nested book ZIP opens archive handler');
  Require(TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('preserved original'),'Nested reader bytes changed');
  Book.FileName:='direct'; Book.FileExt:='.pdf'; RequireDescriptor;
  Book.FileName:='broken catalog'; Book.FileExt:='.295510'; Book.InsideNo:=2;
  Prepared:=PrepareReaderFile(Book);
  Require(SameText(ExtractFileExt(Prepared),'.pdf') and
    TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('direct original'),'Invalid catalog type does not resolve actual archived reader member');
  Book.FileName:='direct.pdf'; Book.FileExt:='._Современный_этикет';
  Prepared:=PrepareReaderFile(Book);
  Require(SameText(ExtractFileExt(Prepared),'.pdf'),'Filename format fallback still opens a malformed extension');
  Book.Folder:=''; Book.FileName:='nested-inner.zip'; Book.FileExt:=''; RequireDescriptor;
  Require(Book.GetBookFormat=bfFbd,'Standalone FBD archive fixture is absent');
  Require(SameText(ExtractFileExt(PrepareReaderFile(Book)),'.pdf'),'Standalone FBD archive opens archive handler');
  Require(THashSHA2.GetHashStringFromFile(Source)=BeforeHash,'Metadata or reading modified archive');
  Writeln('PASS nested ZIP and standalone FBD archives open actual PDF, read annotation and original cover, preserve sources');
  Writeln('PASS broken body Unicode leaves description and original illustrations readable');
  if ParamStr(2)<>'' then
  begin
    Source:=ParamStr(2); Book:=Default(TBookRecord); Book.CollectionRoot:=ExtractFilePath(Source);
    Book.Folder:=ExtractFileName(Source); Book.FileName:='793007'; Book.FileExt:='.fb2';
    Started:=GetTickCount64; Stream:=Book.GetBookDescriptorStream(False);
    try Document:=LoadFB2Description(Stream);
      Require(Document.Description.Titleinfo.Booktitle.Text='Amber Sword','Real Amber title differs');
      Require(GetBookAnnotation(Document).Trim='','Real Amber unexpectedly has annotation');
      Require(Document.Description.Titleinfo.Coverpage.Count=0,'Real Amber unexpectedly has assigned cover');
    finally Document:=nil; Stream.Free; end;
    Writeln('PROFILE real Amber first metadata ms=',GetTickCount64-Started);
    Started:=GetTickCount64; Stream:=Book.GetBookDescriptorStream(False); Stream.Free;
    Writeln('PROFILE real Amber repeated metadata ms=',GetTickCount64-Started);
    Started:=GetTickCount64; Stream:=OpenBookImageSource(Book); Pictures:=0;
    Writeln('PROFILE real Amber raw extraction ms=',GetTickCount64-Started);
    Started:=GetTickCount64;
    try VisitFB2Images(Stream,procedure(const Name: string; Image: TStream) begin Inc(Pictures); end);
    finally Stream.Free; end;
    Require(Pictures=0,'Real Amber unexpectedly has illustrations');
    Writeln('PROFILE real Amber image scan ms=',GetTickCount64-Started);
    Started:=GetTickCount64; Stream:=OpenBookImageSource(Book); Stream.Free;
    Writeln('PROFILE real Amber repeated gallery source ms=',GetTickCount64-Started);
    Started:=GetTickCount64; Prepared:=PrepareReaderFile(Book,True);
    Require(THashSHA2.GetHashStringFromFile(Prepared)='62c18a6a9337527b852a8b858e3f7f1a40d7a7d6eafd484c272777f795c43c32','Shared reader cache altered original bytes');
    Writeln('PROFILE real Amber reader after gallery ms=',GetTickCount64-Started);
    Writeln('PASS real LightLib Amber metadata and empty gallery ignore damaged body Unicode');
  end;
  Writeln('PASS feedback14 fixes verified with isolated fixtures');
end;

procedure TestInteractiveCancel;
var Languages: TComboBox; DB: TSQLiteDatabase; Factory: TFunc<IBookIterator>;
begin
  ShowPage(PAGE_SEARCH); frmMain.Caption:='HomeLib Ru — проверка отмены загрузки';
  frmMain.Hide; frmMain.WindowState:=wsNormal; frmMain.SetBounds(80,80,1100,700);
  frmMain.Show; frmMain.BringToFront; Application.ProcessMessages;
  Languages:=TComboBox.Create(nil);
  DB:=TSQLiteDatabase.Create(Settings.AppPath+'interactive-cancel.db');
  try
    Languages.Parent:=frmMain; Languages.Visible:=False;
    Languages.Items.Add('-'); Languages.ItemIndex:=0;
    Writeln('WAIT real mouse cancellation on the lower progress cross'); Flush(Output);
    Factory := function: IBookIterator
      begin
        DB.QuerySingleInt('WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<500000000) SELECT SUM(x) FROM n');
        Result:=TProfileBooks.Create;
      end;
    frmMain.FillBooksTree(frmMain.tvBooksSR,Languages,Factory,True,True,nil);
    Require(frmMain.BookListCancelled,'A real mouse click did not cancel the query');
    Require(frmMain.tvBooksSR.GetFirst=nil,'Cancelled query retained partial results');
    Require(DB.QuerySingleInt('SELECT 7')=7,'Database did not recover after mouse cancellation');
    Writeln('PASS real mouse cancels running SQLite without a frozen white window');
  finally DB.Free; Languages.Free; end;
end;

type
  TActionProbeTree = class(TBookTree)
  public property OnBeforeGetCheckState; end;
  TActionScanProbe = class
    Visits: Integer;
    procedure Checked(Sender: TBaseVirtualTree; Node: PVirtualNode);
  end;
procedure TActionScanProbe.Checked(Sender: TBaseVirtualTree; Node: PVirtualNode);
begin Inc(Visits); end;

procedure TestListPerformance;
var I, BookCount, SeriesCount: Integer; Started: UInt64; Node: PVirtualNode;
  Data: PBookRecord; Languages: TComboBox; CancelButton: TButton; Component: TComponent;
  Profile: TProfileBooks; DB: TSQLiteDatabase; PaintProbe: TLoadingPaintProbe;
  Filters: TBookColumnFilters; Column: TVirtualTreeColumn; Polls: Integer; Factory: TFunc<IBookIterator>;
  OptionNames: TStringList; ColdOptionsMS, WarmOptionsMS: UInt64;
  procedure CheckIdleActions(Probe: TActionScanProbe; Expected: Boolean; const Context: string);
  begin
    frmMain.UpdateBookAction(frmMain.acBookSetRate1);
    Require(frmMain.acBookSetRate1.Enabled=Expected,'Stale checked-book availability: '+Context);
    Probe.Visits:=0;
    for var ActionIndex:=1 to 120 do
    begin
      frmMain.UpdateBookAction(frmMain.acBookSetRate1);
      frmMain.UpdateBookAction(frmMain.acBookSetRate2);
      Require(frmMain.acBookSetRate1.Enabled=Expected,'Wrong idle availability: '+Context);
      Require(frmMain.acBookSetRate2.Enabled=Expected,'Actions disagree: '+Context);
    end;
    Require(Probe.Visits=0,'Repeated idle scans without book focus: '+Context);
  end;
begin
  TestNestedGenreIterators;
  frmMain.pgControl.ActivePage:=frmMain.tsSearch;
  Languages := TComboBox.Create(nil);
  try
    Languages.Parent := frmMain; Languages.Visible := False;
    Languages.Items.Add('-'); Languages.ItemIndex := 0;
    Settings.TreeModes[PAGE_SEARCH] := tmTree;
    for I := 1 to 3 do
    begin
      Started := GetTickCount64;
      frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, TProfileBooks.Create as IBookIterator, True, True, nil);
      Writeln('PROFILE list build 50000 books / 5000 series ms=', GetTickCount64 - Started);
      BookCount := 0; SeriesCount := 0; Node := frmMain.tvBooksSR.GetFirst;
      while Assigned(Node) do
      begin
        Data := frmMain.tvBooksSR.GetNodeData(Node);
        if Data.nodeType = ntBookInfo then Inc(BookCount);
        if Data.nodeType = ntSeriesInfo then Inc(SeriesCount);
        Node := frmMain.tvBooksSR.GetNext(Node);
      end;
      Require((BookCount = 50000) and (SeriesCount = 5000), 'Profile tree lost books or groups');
      Require(Languages.Items.IndexOf('ru') > 0, 'Profile language was not registered');
    end;
    Writeln('PASS list profiling preserves all books, author-series groups and languages');
    Column := frmMain.tvBooksSR.Header.Columns[1];
    Started := GetTickCount64;
    for I := 1 to 120 do Column.Width := 220+(I mod 80);
    Writeln('PROFILE 120 column widths, 50000 loaded books ms=',GetTickCount64-Started);
    Require(GetTickCount64-Started<1500,'Resizing traverses the complete book list');
    Filters := TBookColumnFilters.ForTree(frmMain.tvBooksSR);
    OptionNames:=TStringList.Create;
    try
      Started:=GetTickCount64; Filters.GetOptions(COL_SERIES,OptionNames);
      ColdOptionsMS:=GetTickCount64-Started;
      Require(OptionNames.Count=5000,'Series options lost distinct values from 50000 books');
      Started:=GetTickCount64;
      for I:=1 to 100 do Filters.GetOptions(COL_SERIES,OptionNames);
      WarmOptionsMS:=GetTickCount64-Started;
      Require(OptionNames.Count=5000,'Cached series options lost distinct values');
      Writeln('PROFILE series options 50000 books cold_ms=',ColdOptionsMS,
        ' cached_100_ms=',WarmOptionsMS,' options=',OptionNames.Count);
    finally OptionNames.Free; end;
    Started:=GetTickCount64;
    Filters.SetValue(COL_TITLE,'000001'); Require(Filters.Apply=1,'Single result profile failed');
    Writeln('PROFILE title filter 50000 books ms=',GetTickCount64-Started);
    Started := GetTickCount64;
    for I := 1 to 120 do Column.Width := 220+(I mod 80);
    Writeln('PROFILE 120 column widths, one visible / 50000 loaded ms=',GetTickCount64-Started);
    Require(GetTickCount64-Started<1500,'Resizing a filtered list traverses hidden rows');
    Filters.SetValue(COL_LANG,'=ru'); Polls := 0;
    Require(Filters.Apply(True,function: Boolean begin Inc(Polls); Result:=False; end)=1,'Narrowing lost result');
    Require(Polls<4,'Additional filters rescan all 50000 loaded rows');
    Filters.Clear; Require(Filters.Apply=50000,'Clearing filter lost loaded rows');
    Writeln('PASS general fixed-height resizing and incremental filtering on 50000 books');
    var AllowedTypes:=TStringList.Create; var Probe:=TActionScanProbe.Create;
    try
      // Exactly the reported selection: select every type, then exclude FB2.
      AllowedTypes.Add('pdf');
      for var ExtIndex:=1 to 49 do AllowedTypes.Add('format'+IntToStr(ExtIndex));
      Node:=frmMain.tvBooksSR.GetFirst;
      while Assigned(Node) do
      begin
        Data:=frmMain.tvBooksSR.GetNodeData(Node);
        if Data.NodeType=ntBookInfo then
          if Data.BookKey.BookID mod 100=0 then Data.FileExt:='.pdf' else Data.FileExt:='.fb2';
        Node:=frmMain.tvBooksSR.GetNext(Node);
      end;
      Filters.SetSelectedValues(COL_TYPE,AllowedTypes); Require(Filters.Apply=500,'All types except FB2 filter lost visible PDF rows');
      Node:=frmMain.tvBooksSR.GetFirstVisible;
      while Assigned(Node) do
      begin
        Data:=frmMain.tvBooksSR.GetNodeData(Node);
        if Data.NodeType=ntBookInfo then Break;
        Node:=frmMain.tvBooksSR.GetNextVisible(Node);
      end;
      Require(Assigned(Node),'No visible book to reproduce filtered-row selection');
      frmMain.tvBooksSR.FocusedNode:=Node;
      frmMain.tvBooksSR.Selected[Node]:=True;
      Probe.Visits:=0; TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=Probe.Checked;
      Started:=GetTickCount64;
      for var ActionIndex:=1 to 120 do
      begin
        frmMain.UpdateBookAction(frmMain.acBookSetRate1);
        Require(frmMain.acBookSetRate1.Enabled,'Rating action disabled for filtered focused book');
      end;
      Require(Probe.Visits=0,'Selecting filtered book still scans checked state across catalogue');
      Require(GetTickCount64-Started<500,'Filtered book action updates block the UI');
      Writeln('PROFILE 120 action updates, all types except FB2 / 50000 loaded ms=',GetTickCount64-Started,' checked_visits=',Probe.Visits);
      var CheckedBook:=Node; var FocusGroup:=Node.Parent;
      frmMain.tvBooksSR.FocusedNode:=nil;
      CheckIdleActions(Probe,False,'no focused or checked book');
      frmMain.tvBooksSR.CheckState[CheckedBook]:=csCheckedNormal;
      CheckIdleActions(Probe,True,'one checked book without focus');
      Require(Assigned(FocusGroup) and (FocusGroup<>frmMain.tvBooksSR.RootNode),'Missing group fallback fixture');
      frmMain.tvBooksSR.FocusedNode:=FocusGroup;
      CheckIdleActions(Probe,True,'series focused and a book checked');
      frmMain.tvBooksSR.CheckState[CheckedBook]:=csUncheckedNormal;
      CheckIdleActions(Probe,False,'last book unchecked');
      frmMain.pmiCheckAllClick(nil);
      CheckIdleActions(Probe,True,'bulk check all visible books');
      frmMain.pmiDeselectAllClick(nil);
      CheckIdleActions(Probe,False,'bulk uncheck all books');
      frmMain.tvBooksSR.CheckState[CheckedBook]:=csCheckedNormal;
      CheckIdleActions(Probe,True,'checked book before narrowing');
      var CheckedTitle:=PBookRecord(frmMain.tvBooksSR.GetNodeData(CheckedBook)).Title;
      Filters.SetValue(COL_TITLE,'000200'); Require(Filters.Apply(False)=1,'Alternate filter result missing');
      frmMain.tvBooksSR.FocusedNode:=nil;
      CheckIdleActions(Probe,False,'checked book hidden by filter');
      Filters.SetValue(COL_TITLE,CheckedTitle); Require(Filters.Apply(False)=1,'Original row cannot be restored');
      CheckIdleActions(Probe,False,'same-count filter must preserve cleared checks');
      frmMain.tvBooksSR.CheckState[CheckedBook]:=csCheckedNormal;
      CheckIdleActions(Probe,True,'rechecked restored row');
      frmMain.tvBooksSR.DeleteNode(CheckedBook);
      CheckIdleActions(Probe,False,'checked row removed');
      Writeln('PASS no-focus and group-focus idle actions cache checks and refresh on checking, bulk changes, filtering and deletion');
      Filters.SetValue(COL_TITLE,'no-such-title-anywhere'); Require(Filters.Apply=0,'Empty filter fixture contains books');
      Probe.Visits:=0;
      for var ActionIndex:=1 to 120 do
      begin
        frmMain.UpdateBookAction(frmMain.acBookSetRate1);
        Require(not frmMain.acBookSetRate1.Enabled,'Empty filtered list offers a rating action');
      end;
      Require(Probe.Visits=0,'Empty filtered list scans all hidden books during idle');
      TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil;
      Filters.Clear; Filters.Apply;
      Node:=frmMain.tvBooksSR.GetFirstVisible;
      while Assigned(Node) do
      begin
        Data:=frmMain.tvBooksSR.GetNodeData(Node);
        if Data.NodeType=ntBookInfo then Break;
        Node:=frmMain.tvBooksSR.GetNextVisible(Node);
      end;
      Require(Assigned(Node),'Missing book for format-independent action regression');
      frmMain.tvBooksSR.FocusedNode:=Node;
      var OldExtension:=Data.FileExt;
      Probe.Visits:=0; TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=Probe.Checked;
      try
        for var Extension in string('fb2|fb3|epub|pdf|txt|rtf|html|htm|xhtml|shtml|mht|mhtml|docx|odt|md|markdown|faq|wri|jpg|jpeg|png|gif|bmp|webp|tif|tiff|cbz|cbr|cb7|djvu|djv|dju|djm|djvm|mobi|azw|azw3|prc|doc|xls|xlsx|ppt|pptx|ods|odp|xps|oxps|chm|zip|rar|7z|unknown').Split(['|']) do
        begin
          Data.FileExt:='.'+Extension;
          frmMain.UpdateBookAction(frmMain.acBookSetRate1);
          Require(frmMain.acBookSetRate1.Enabled,'General book action depends on format: '+Extension);
        end;
        Require(Probe.Visits=0,'General action scans catalogue for a different book format');
      finally Data.FileExt:=OldExtension; TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil; end;
      Writeln('PASS common book action path avoids catalogue scans across all registered reader and external formats');
    finally TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil; Probe.Free; AllowedTypes.Free; end;
    Writeln('PASS filtered focused-book actions avoid repeated complete catalogue scans');
    if ParamStr(2)='visual' then
    begin
      ShowPage(PAGE_SEARCH);
      frmMain.WindowState:=wsNormal; frmMain.SetBounds(80,80,1500,850);
      Filters.SetValue(COL_TITLE,'000001'); frmMain.ApplyBookColumnFilters(frmMain.tvBooksSR);
      frmMain.Caption:='HomeLib Ru — проверка таблицы на 50 000 книг';
      frmMain.Show; Application.Run; Exit;
    end;

    CancelButton := nil;
    for Component in frmMain do
      if (Component is TButton) and (Component.Name = 'BookListCancel') then CancelButton := TButton(Component);
    Require(Assigned(CancelButton), 'Book list has no cancellation button');
    PaintProbe:=TLoadingPaintProbe.Create(frmMain); PaintProbe.Parent:=frmMain;
    PaintProbe.SetBounds(10,10,50,30); PaintProbe.Visible:=True; PaintProbe.PaintCount:=0;
    DB := TSQLiteDatabase.Create(Settings.AppPath + 'cancel-probe.db');
    try
      Factory := function: IBookIterator
        begin
          PaintProbe.Invalidate;
          PostMessage(CancelButton.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(4, 4));
          PostMessage(CancelButton.Handle, WM_LBUTTONUP, 0, MakeLParam(4, 4));
          DB.QuerySingleInt('WITH RECURSIVE numbers(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM numbers WHERE x<1000000) SELECT SUM(x) FROM numbers');
          Result := TProfileBooks.Create;
        end;
      frmMain.FillBooksTree(frmMain.tvBooksSR, Languages,Factory,True,True,nil);
      Require(PaintProbe.PaintCount>0,'Window painting was blocked during SQLite preparation');
      Require(frmMain.BookListCancelled and (frmMain.tvBooksSR.GetFirst = nil), 'SQL preparation ignored cancel or retained partial rows');
      Require(not Assigned(SQLiteCancelCallback) and not CancelButton.Visible, 'Cancellation callback or button leaked');
      Require(DB.QuerySingleInt('SELECT 7') = 7, 'Cancellation left the database unusable');
    finally DB.Free; PaintProbe.Free; end;
    Profile := TProfileBooks.Create; Profile.CancelControl := CancelButton; Profile.CancelAt := 900;
    frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, Profile as IBookIterator, True, True, nil);
    Require(frmMain.BookListCancelled and (frmMain.tvBooksSR.GetFirst = nil), 'Row loading ignored cancel or retained partial rows');
    frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, TProfileBooks.Create as IBookIterator, True, True, nil);
    Require(not frmMain.BookListCancelled and (frmMain.tvBooksSR.GetFirst <> nil), 'Loading did not recover after cancel');
    Writeln('PASS main window repaints while SQL runs and cancel is available');
    Writeln('PASS cancellation interrupts SQL preparation and row loading, clears partial results and permits the next request');
  finally Languages.Free; end;
end;

procedure TestReaderWithColumnFilter;
const Files: array[0..5] of string = ('reader-sky.pdf','reader-apple.djvu','reader-quixote.epub','reader-story.txt','reader-dome.fb2','reader-novel.doc');
var Filters: TBookColumnFilters; Allowed: TStringList; Probe: TActionScanProbe;
  Reader: TfrmBuiltinReader; Node: PVirtualNode; Data: PBookRecord; Watch: TStopwatch;
  OpenTimes, PageTimes, PageTotals: array[0..1,0..5] of Int64; Trial, BookIndex, PageIndex: Integer; ActionVisits: Integer;
  procedure UpdateMainActions;
  var Before: Integer;
  begin
    Before:=Probe.Visits;
    for var I:=1 to 6 do frmMain.UpdateBookAction(frmMain.acBookSetRate1);
    Inc(ActionVisits,Probe.Visits-Before);
    // Painting visible checkboxes legitimately reads their state. Count only
    // the action updates, separately from ordinary window painting.
    Application.ProcessMessages; CheckSynchronize(5);
  end;
  procedure WaitReader(Opening: Boolean);
  var Deadline: TStopwatch;
  begin
    Deadline:=TStopwatch.StartNew;
    while ((Opening and not Reader.LoadFinished) or Reader.PageLoading) and (Deadline.ElapsedMilliseconds<15000) do
    begin UpdateMainActions; Sleep(2); end;
    Require(Reader.Ready and not Reader.PageLoading,'Reader did not complete: '+Reader.ReaderStatus.Caption);
  end;
begin
  TestListPerformance;
  Filters:=TBookColumnFilters.ForTree(frmMain.tvBooksSR); Allowed:=TStringList.Create; Probe:=TActionScanProbe.Create;
  try
    Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Data.NodeType=ntBookInfo then
        if Data.BookKey.BookID mod 100=0 then Data.FileExt:='.pdf' else Data.FileExt:='.fb2';
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Allowed.Add('pdf'); for var I:=1 to 49 do Allowed.Add('format'+IntToStr(I));
    frmMain.Show;
    for Trial:=0 to 1 do
    begin
      Filters.Clear;
      if Trial=1 then Filters.SetSelectedValues(COL_TYPE,Allowed);
      Filters.Apply;
      Node:=frmMain.tvBooksSR.GetFirstVisible;
      while Assigned(Node) do
      begin
        Data:=frmMain.tvBooksSR.GetNodeData(Node);
        if Data.NodeType=ntBookInfo then Break;
        Node:=frmMain.tvBooksSR.GetNextVisible(Node);
      end;
      Require(Assigned(Node),'Reader filter fixture has no focused book');
      frmMain.tvBooksSR.FocusedNode:=Node; frmMain.tvBooksSR.Selected[Node]:=True;
      Probe.Visits:=0; ActionVisits:=0; TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=Probe.Checked;
      for BookIndex:=0 to High(Files) do
      begin
        Require(FileExists(Files[BookIndex]),'Missing readonly reader fixture: '+Files[BookIndex]);
        Reader:=TfrmBuiltinReader.Create(frmMain);
        try
          Reader.PopupMode:=pmExplicit; Reader.PopupParent:=frmMain; Reader.Show;
          Watch:=TStopwatch.StartNew;
          var InputBook:=Default(TBookRecord);
          InputBook.CollectionRoot:=Settings.AppPath;
          InputBook.FileName:=ChangeFileExt(Files[BookIndex],''); InputBook.FileExt:=ExtractFileExt(Files[BookIndex]);
          InputBook.BookKey:=CreateBookKey(BookIndex+1,1); InputBook.LibID:=IntToStr(BookIndex+1);
          InputBook.BookProps:=[bpIsLocal];
          // Use the application's actual asynchronous preparation, including
          // direct DOC conversion, before the reflow/page reader receives it.
          PrepareReaderFileInBackground(frmMain,InputBook,True,
            procedure(Prepared: string)
            begin
              Reader.OpenBook(Prepared,Files[BookIndex],Format('filter-%d-%d',[Trial,BookIndex]),
                Format('filter-%d-%d.ini',[Trial,BookIndex]),'tools\pdfium\pdfium.dll');
            end,False,False,True);
          WaitReader(True); OpenTimes[Trial,BookIndex]:=Watch.ElapsedMilliseconds;
          PageTimes[Trial,BookIndex]:=0; PageTotals[Trial,BookIndex]:=0;
          for PageIndex:=1 to 5 do
          begin
            Watch:=TStopwatch.StartNew; Reader.NextPage; WaitReader(False); UpdateMainActions;
            Inc(PageTotals[Trial,BookIndex],Watch.ElapsedMilliseconds);
            PageTimes[Trial,BookIndex]:=Max(PageTimes[Trial,BookIndex],Watch.ElapsedMilliseconds);
            Require(Watch.ElapsedMilliseconds<1500,'Page change blocks for seconds: '+Files[BookIndex]);
            Require(Reader.Visible,'Paging hid or closed the reader');
            Require(not string(Reader.ReaderStatus.Caption).StartsWith('Не удалось'),'Page failed: '+Reader.ReaderStatus.Caption);
          end;
          Writeln('PROFILE reader filter=',Trial,' file=',Files[BookIndex],' open_ms=',OpenTimes[Trial,BookIndex],
            ' max_page_ms=',PageTimes[Trial,BookIndex],' mean_page_ms=',PageTotals[Trial,BookIndex] div 5);
          Reader.Close;
        finally Reader.Free; end;
      end;
      Require(ActionVisits=0,'Main action updates scan the catalogue while reader is open');
      TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil;
    end;
    for BookIndex:=0 to High(Files) do
    begin
      Require(OpenTimes[1,BookIndex]<OpenTimes[0,BookIndex]+1500,'Type filter adds seconds to reader opening');
      Require(PageTotals[1,BookIndex]<PageTotals[0,BookIndex]+5*150,'Type filter delays page changes');
    end;
    Writeln('PASS actual PDF DjVu EPUB TXT FB2 and DOC readers stay visible and avoid catalogue scans with filter on and off');
  finally
    TActionProbeTree(frmMain.tvBooksSR).OnBeforeGetCheckState:=nil;
    Filters.Clear; Filters.Apply; Probe.Free; Allowed.Free; frmMain.Hide;
  end;
end;

procedure TestLanguageIsolation;
begin
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  ShowPage(PAGE_GENRES);
  ShowPage(PAGE_AUTHORS);
  frmMain.btnSwitchTreeModeClick(nil);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Another view reset the selected author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  frmMain.btnSwitchTreeModeClick(nil);
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  Writeln('PASS language choice survives another view first load and repeated refreshes');
end;

procedure TestAddBeforeFirstGroupVisit;
var
  Node: PVirtualNode;
  Book: PBookRecord;
begin
  Node := frmMain.tvBooksA.GetFirst;
  while Assigned(Node) do
  begin
    Book := frmMain.tvBooksA.GetNodeData(Node);
    if (Book.NodeType = ntBookInfo) and (Book.Title = 'Alpha extra uk') then
      Break;
    Node := frmMain.tvBooksA.GetNext(Node);
  end;
  Require(Assigned(Node), 'The book to add is absent');
  frmMain.tvBooksA.ClearSelection;
  frmMain.tvBooksA.Selected[Node] := True;
  frmMain.tvBooksA.FocusedNode := Node;
  frmMain.tvBooksTreeChange(frmMain.tvBooksA, Node);
  Require(frmMain.acBookAdd2Favorites.Execute, 'Add to Favorites action was disabled');
  ShowPage(PAGE_FAVORITES);
  Require(frmMain.cbLangSelectF.Text = 'ru', 'Adding a book lost the unopened group language filter');
  ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
  Writeln('PASS adding a book before first group visit preserves its language filter');
end;

procedure TestGenreLink;
var
  Book: PBookRecord;
  BookID: Integer;
  GenreCode: string;
begin
  Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
  Require(Assigned(Book) and (Length(Book.Genres) = 1), 'The linked book has no genre');
  BookID := Book.BookKey.BookID;
  GenreCode := Book.Genres[0].GenreCode;
  frmMain.ipnlAuthors.OnGenreLinkClicked(frmMain.ipnlAuthors, GenreCode, Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsByGenre, 'Genre link did not activate its page');
  Require(frmMain.lblGenreTitle.Caption = Book.Genres[0].GenreAlias,
    'Genre link left the previous genre title visible');
  ExpectTitles(frmMain.tvBooksG, ['Alpha ru']);
  Book := frmMain.tvBooksG.GetNodeData(frmMain.tvBooksG.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Genre link did not retain the requested book');
  Writeln('PASS genre link restores the requested genre, language and book');
end;

procedure TestGenreOrder(const Collection: IBookCollection; UnknownBook: Integer);
var
  Node: PVirtualNode;
  Genre: PGenreData;
  Filter: TFilterValue;
begin
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = '0.1'), 'First classified genre was not selected');
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(frmMain.tvGenres.GetNextSibling(Node)) do
    Node := frmMain.tvGenres.GetNextSibling(Node);
  Genre := frmMain.tvGenres.GetNodeData(Node);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Unsorted is not the last tree category');
  ShowPage(PAGE_GENRES);
  ExpectTitles(frmMain.tvBooksG, []);
  Require(frmMain.btnShowGenreBooks.Visible, 'Root genre has no explicit Show action');
  RequestRootGenreBooks;
  Require(frmMain.cbLangSelectG.Text = 'ru', 'Root Show lost the deferred saved language');
  ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmAll), False, UNKNOWN_GENRE_CODE);
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Explicit Unsorted selection was lost');
  ExpectTitles(frmMain.tvBooksG, ['Unknown']);
  Filter.ValueInt := UnknownBook;
  FillGenresTree(frmMain.tvGenres, Collection.GetGenreIterator(gmByBook, @Filter));
  Genre := frmMain.tvGenres.GetNodeData(frmMain.tvGenres.GetFirstSelected);
  Require(Assigned(Genre) and (Genre.GenreCode = UNKNOWN_GENRE_CODE), 'Only-Unsorted tree has no selection');
  Writeln('PASS Unsorted is last, first genre is default, explicit selection and fallback work');
end;

procedure TestSourceGenrePreservation(const Expected: TGenreData);
var
  Node: PVirtualNode;
  Genre: PGenreData;
begin
  Node := frmMain.tvGenres.GetFirst;
  while Assigned(Node) do
  begin
    Genre := frmMain.tvGenres.GetNodeData(Node);
    if Genre.GenreCode = Expected.GenreCode then
    begin
      Require((Genre.GenreAlias = Expected.GenreAlias) and
        (Genre.ParentCode = Expected.ParentCode), 'Locale update changed imported genre metadata');
      Writeln('PASS imported source genre survives locale synchronization');
      Exit;
    end;
    Node := frmMain.tvGenres.GetNext(Node);
  end;
  raise Exception.Create('Locale synchronization removed an imported genre');
end;

function PublisherView: TPublisherSeriesView;
var
  Component: TComponent;
begin
  for Component in frmMain do
    if Component is TPublisherSeriesView then
      Exit(TPublisherSeriesView(Component));
  raise Exception.Create('Publisher view was not created');
end;

procedure TestPublisherSelection(OneID, TwoID, SavedBook: Integer);
var
  View: TPublisherSeriesView;
  Book: PBookRecord;
begin
  View := PublisherView;
  Require(View.SeriesTree.GetFirst = nil, 'Hidden publisher list was eagerly built');
  ExpectTitles(View.Books, []);
  frmMain.cbLangSelectA.ItemIndex := frmMain.cbLangSelectA.Items.IndexOf('ru');
  frmMain.cbLangSelectAChange(frmMain.cbLangSelectA);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'First publisher visit lost its saved language');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'First publisher visit lost its saved book');
  ShowPage(PAGE_AUTHORS);
  Require(frmMain.cbLangSelectA.Text = 'ru', 'Publisher filtering reset author language');
  ExpectTitles(frmMain.tvBooksA, ['Alpha ru']);
  ChangeCollection(TwoID);
  ChangeCollection(OneID);
  frmMain.pgControl.ActivePage := View.Tab;
  frmMain.pgControlChange(nil);
  Require(View.Language.Text = 'ru', 'Publisher language was lost across collections');
  ExpectTitles(View.Books, ['Alpha ru']);
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = SavedBook),
    'Publisher book was lost across collections');
  Writeln('PASS deferred publisher view restores its language and book without changing author selection');
end;

procedure TestPublisherLinks(const One: IBookCollection; OneID, TwoID: Integer);
var View: TPublisherSeriesView; Series: TBookSeries; Item: TSeriesData;
  Iter: ISeriesIterator; Book: PBookRecord; Node: PVirtualNode;
  BookID, OtherBook, SeriesID, CycleID: Integer; GenreCode: string;
  Annotation: TMemo; I: Integer; Viewport: TScrollBox; Content: TWinControl;
begin
  View := PublisherView;
  BookID := AddBook(One, 'Audit prose', 'Audit', 'ru', 'Audit cycle', 'prose_contemporary');
  OtherBook := AddBook(One, 'Audit science', 'Audit', 'ru', 'Audit cycle', 'sci_physics');
  TSeriesHelper.Add(Series, 0, 'Audit common', 7, False);
  One.SetBookPublisherSeries(CreateBookKey(BookID, OneID), Series);
  One.SetBookPublisherSeries(CreateBookKey(OtherBook, OneID), Series);
  Iter := One.GetPublisherSeriesIterator('Audit'); Require(Iter.Next(Item), 'Publisher fixture absent');
  SeriesID := Item.SeriesID; Iter := nil;
  // A previously saved grouping must not hide books after returning to a flat list.
  One.SetProperty(PROP_PUBLISHER_BY_GENRE, True); One.SetProperty(PROP_PUBLISHER_GENRE, 'missing-genre');
  One.SetProperty(PROP_LAST_PUBLISHER_SERIES, SeriesID);
  One.SetProperty(PROP_LAST_PUBLISHER_BOOK, BookID); One.SetProperty(PROP_PUBLISHER_LANG_FILTER, 0);
  ChangeCollection(TwoID); ChangeCollection(OneID);
  frmMain.pgControl.ActivePage := View.Tab; frmMain.pgControlChange(nil);
  Require(View.SeriesTree.RootNodeCount = 1, 'Flat view duplicated or hid a mixed-genre series');
  ExpectTitles(View.Books, ['Audit prose', 'Audit science']);
  Node := View.Books.FocusedNode; Book := View.Books.GetNodeData(Node);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Publisher selection lost');
  CycleID := Book.SeriesID; GenreCode := Book.Genres[0].GenreCode;
  Annotation := nil; Viewport := nil;
  for I := 0 to View.Info.ControlCount - 1 do
    if View.Info.Controls[I] is TScrollBox then Viewport := TScrollBox(View.Info.Controls[I]);
  Require(Assigned(Viewport), 'Card viewport missing'); Content := TWinControl(Viewport.Controls[0]);
  for I := 0 to Content.ControlCount - 1 do
    if Content.Controls[I] is TMemo then Annotation := TMemo(Content.Controls[I]);
  Require(Assigned(Annotation), 'Annotation missing'); Annotation.Text := 'Keep the current card';
  View.Info.OnPublisherSeriesLinkClicked(View.Info, IntToStr(SeriesID), Low(TSysLinkType));
  Require((View.Books.FocusedNode = Node) and (Annotation.Text = 'Keep the current card'),
    'Same publisher link rebuilt its book tree or cleared its card');
  View.Info.OnSeriesLinkClicked(View.Info, IntToStr(CycleID), Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsBySerie, 'Cycle link did not switch tabs');
  Book := frmMain.tvBooksS.GetNodeData(frmMain.tvBooksS.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Cycle link lost the book');
  frmMain.ipnlSeries.OnPublisherSeriesLinkClicked(frmMain.ipnlSeries, IntToStr(SeriesID), Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = View.Tab, 'Publisher link did not return');
  Book := View.Books.GetNodeData(View.Books.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Return link lost the book');
  View.Info.OnGenreLinkClicked(View.Info, GenreCode, Low(TSysLinkType));
  Require(frmMain.pgControl.ActivePage = frmMain.tsByGenre, 'Genre link did not switch tabs');
  Book := frmMain.tvBooksG.GetNodeData(frmMain.tvBooksG.FocusedNode);
  Require(Assigned(Book) and (Book.BookKey.BookID = BookID), 'Genre link lost the book');
  Require(One.GetBookPublisherSeries(CreateBookKey(BookID, OneID))[0].SeqNumber = 7,
    'Navigation changed a publisher number');
  Writeln('PASS flat publisher list ignores old grouping and retains mixed genres without duplicates');
  Writeln('PASS publisher links keep current card and select the same book across cycle and genre tabs');
end;

type
  TPublisherLogDriver = class
    Timer: TTimer;
    SavedLog, SourceLog: string;
    PreviewCount: Integer;
    procedure Tick(Sender: TObject);
  end;

procedure TPublisherLogDriver.Tick(Sender: TObject);
var
  I: Integer;
  Progress: TImportProgressFormEx;
begin
  for I := Screen.FormCount - 1 downto 0 do
    if (Screen.Forms[I] is TImportProgressFormEx) and Screen.Forms[I].Visible then
    begin
      Progress := TImportProgressFormEx(Screen.Forms[I]);
      if (Progress.WorkerThread is TIndexPublisherSeriesThread) and
        Progress.WorkerThread.Finished and (Progress.btnCancel.Caption = 'Закрыть') then
      begin
        SourceLog := Progress.FullErrorLogFileName;
        PreviewCount := Progress.errorLog.Items.Count;
        Require(Progress.btnSaveLog.Visible, 'Full journal save button is hidden');
        Progress.SaveErrorLog(SavedLog);
        Progress.btnCancel.Click;
      end;
    end;
end;

procedure TestPublisherErrorLog(const Collection: IBookCollection);
var
  R: TBookRecord;
  Series: TBookSeries;
  IDs: TArray<Integer>;
  I, ErrorCount, PlaceholderID, NoDescriptionID, RepairedID, DeletedValidID: Integer;
  Driver: TPublisherLogDriver;
  Log: TStringList;
  Line: string;

  function AddFixture(const Name, XML: string; Deleted: Boolean; Size: Integer): Integer;
  var Book: TBookRecord;
  begin
    Book.Clear;
    Book.Title := Name; Book.LibID := Name; Book.FileName := Name;
    Book.FileExt := '.fb2'; Book.Size := Size;
    Include(Book.BookProps, bpIsLocal);
    if Deleted then Include(Book.BookProps, bpIsDeleted);
    Result := Collection.InsertBook(Book, False, False);
    Collection.SetBookPublisherSeries(CreateBookKey(Result, Collection.CollectionID), Series);
    if XML = '' then
      TFile.WriteAllBytes(TPath.Combine(Collection.CollectionRoot, Name + '.fb2'), nil)
    else
      TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, Name + '.fb2'), XML, TEncoding.UTF8);
  end;
begin
  SetLength(IDs, 25);
  TSeriesHelper.Add(Series, 0, 'Keep existing publisher', 7, False);
  for I := 0 to High(IDs) do
  begin
    R.Clear;
    R.Title := 'Broken series fixture ' + IntToStr(I);
    R.LibID := 'broken-' + IntToStr(I);
    R.FileName := 'broken-' + IntToStr(I);
    R.FileExt := '.fb2';
    Include(R.BookProps, bpIsLocal);
    IDs[I] := Collection.InsertBook(R, False, False);
    Collection.SetBookPublisherSeries(CreateBookKey(IDs[I], Collection.CollectionID), Series);
    TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, R.FileName + '.fb2'),
      '<NotFictionBook/>', TEncoding.UTF8);
  end;
  R.Clear;
  R.Title := 'Valid reset namespace'; R.LibID := 'valid-reset';
  R.FileName := 'valid-reset'; R.FileExt := '.fb2';
  Include(R.BookProps, bpIsLocal);
  I := Collection.InsertBook(R, False, False);
  TFile.WriteAllText(TPath.Combine(Collection.CollectionRoot, R.FileName + '.fb2'),
    '<?xml version="1.0" encoding="UTF8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.1">' +
    '<description xmlns=""><title-info/><publish-info><sequence name="Recovered" number="5"/>' +
    '</publish-info></description><body/></FictionBook>', TEncoding.UTF8);
  PlaceholderID := AddFixture('empty-deleted-placeholder', '', True, 0);
  NoDescriptionID := AddFixture('no-description', '<FictionBook><body/></FictionBook>', False, 40);
  RepairedID := AddFixture('repair-annotation', '<FictionBook><description><title-info>' +
    '<annotation><p>text</annotation></title-info><publish-info>' +
    '<sequence name="Recovered & exact" number="26"/></publish-info></description>', False, 250);
  DeletedValidID := AddFixture('deleted-valid', '<FictionBook><description><title-info/>' +
    '<publish-info><sequence name="Deleted readable" number="8"/></publish-info></description>', True, 200);
  Driver := TPublisherLogDriver.Create;
  try
    Driver.SavedLog := Settings.AppPath + 'saved-publisher-errors.log';
    Driver.Timer := TTimer.Create(nil);
    Driver.Timer.Interval := 25;
    Driver.Timer.OnTimer := Driver.Tick;
    PublisherView.IndexButton.Click;
    Require(FileExists(Driver.SavedLog), 'Actual main command did not save its full error log');
    Require(Driver.PreviewCount <= 24, 'Preview grows without a bound');
    Require(TFile.ReadAllText(Driver.SourceLog, TEncoding.UTF8) =
      TFile.ReadAllText(Driver.SavedLog, TEncoding.UTF8), 'Save journal copied only the visible errors');
    Log := TStringList.Create;
    try
      Log.LoadFromFile(Driver.SavedLog, TEncoding.UTF8);
      ErrorCount := 0;
      for Line in Log do
        if Line.StartsWith('Книга ') then Inc(ErrorCount);
      Require(ErrorCount = 32, Format('Full journal has %d errors; expected 32 broken/missing books', [ErrorCount]));
      Require(Log.Text.Contains('broken-24.fb2'), 'Error beyond the first twenty is missing');
      Require(not Log.Text.Contains('empty-deleted-placeholder'), 'Deleted empty placeholder was logged as error');
      Require(not Log.Text.Contains('no-description'), 'Missing optional metadata was logged as error');
      Require(Log.Text.Contains('Восстановлено при чтении:'), 'Recovery was not recorded in the full journal');
    finally
      Log.Free;
    end;
    for ErrorCount in IDs do
    begin
      Series := Collection.GetBookPublisherSeries(CreateBookKey(ErrorCount, Collection.CollectionID));
      Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Keep existing publisher'),
        'Malformed book erased existing publisher metadata');
    end;
    Series := Collection.GetBookPublisherSeries(CreateBookKey(I, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Recovered') and
      (Series[0].SeqNumber = 5), 'Actual command failed to recover converter metadata');
    for ErrorCount in TArray<Integer>.Create(PlaceholderID, NoDescriptionID) do
    begin
      Series := Collection.GetBookPublisherSeries(CreateBookKey(ErrorCount, Collection.CollectionID));
      Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Keep existing publisher'),
        'Skipped book erased existing publisher metadata');
    end;
    Series := Collection.GetBookPublisherSeries(CreateBookKey(RepairedID, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Recovered & exact') and
      (Series[0].SeqNumber = 26), 'Recovered metadata lost exact title or number');
    Series := Collection.GetBookPublisherSeries(CreateBookKey(DeletedValidID, Collection.CollectionID));
    Require((Length(Series) = 1) and (Series[0].SeriesTitle = 'Deleted readable'),
      'Nonempty deleted book was incorrectly skipped');
    Require(TFile.ReadAllText(TPath.Combine(Collection.CollectionRoot, 'repair-annotation.fb2'),
      TEncoding.UTF8).Contains('<p>text</annotation>'), 'Recovery modified the original book');
    Writeln('PASS actual publisher indexing saves all errors, bounds preview and preserves metadata');
  finally
    Driver.Timer.Free;
    if FileExists(Driver.SourceLog) then TFile.Delete(Driver.SourceLog);
    Driver.Free;
  end;
end;

procedure BenchmarkLargeINPX;
var ID, A, B, S, I, Count, BookNodes, MetadataRows: Integer; Started: UInt64;
  Importer: TImportInpxThread; Collection: IBookCollection; Iterator: IBookIterator;
  Book: TBookRecord; Filter: TFilterValue; Criteria: TBookSearchCriteria;
  Node: PVirtualNode; Data: PBookRecord; Languages: TComboBox; FileName: string;
  function Query(Mode: Integer): IBookIterator;
  begin
    Filter := Default(TFilterValue);
    case Mode of
      0: begin Filter.ValueString := '0.1'; Result := Collection.GetBookIterator(bmByGenreRecursive, False, @Filter); end;
      1: begin Filter.ValueString := '0.0'; Result := Collection.GetBookIterator(bmByGenre, False, @Filter); end;
      2: begin Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
          Criteria.Deleted := True; Criteria.CollapseMultiSeriesResults := True; Result := Collection.Search(Criteria, False); end;
      3: begin Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
          Criteria.Deleted := True; Criteria.CollapseMultiSeriesResults := True; Criteria.Title := 'Поттер';
          Result := Collection.Search(Criteria, False); end;
    else raise Exception.Create('Unknown benchmark query'); end;
  end;
begin
  FileName := Settings.AppPath + 'large-fixture.inpx';
  Require(FileExists(FileName), 'Large INPX must be copied into the isolated runtime');
  ID := SystemDB.CreateCollection('Native full INPX benchmark', Settings.AppPath + 'books\',
    'large-native.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Started := GetTickCount64;
  Importer := TImportInpxThread.Create(ID, FileName, gtFb2);
  try
    Importer.Start; Importer.WaitFor;
    if Assigned(Importer.FatalException) then raise Exception.Create(Exception(Importer.FatalException).Message);
  finally Importer.Free; end;
  Writeln('NATIVE import_ms=', GetTickCount64 - Started); Flush(Output);
  Collection := SystemDB.GetCollection(ID); Collection.GetStatistics(A, B, S);
  Writeln('NATIVE statistics authors=', A, ' books=', B, ' series=', S); Flush(Output);
  Require(B > 500000, 'Full benchmark input unexpectedly contains a small catalog');
  Collection.SetHideDeleted(True); Collection.SetShowLocalOnly(False);
  for I := 0 to 3 do
  begin
    Started := GetTickCount64; Iterator := Query(I);
    Writeln('NATIVE query=', I, ' prepare_ms=', GetTickCount64 - Started); Flush(Output);
    Count := 0; MetadataRows := 0;
    while Iterator.Next(Book) do begin Inc(Count); Inc(MetadataRows, Length(Book.Authors) + Length(Book.Genres)); end;
    Iterator := nil;
    Writeln('NATIVE query=', I, ' all_rows_ms=', GetTickCount64 - Started, ' rows=', Count, ' metadata=', MetadataRows); Flush(Output);
  end;
  Settings.ActiveCollection := ID; Settings.ActivePage := PAGE_SEARCH;
  Settings.ShowInfoPanel := False; Settings.ShowBookCover := False; Settings.ShowBookAnnotation := False;
  Settings.CheckUpdate := False;
  Started := GetTickCount64;
  Application.CreateForm(TdmImages, dmImages); dmImages.ApplyThemeIcons;
  Application.CreateForm(TfrmMain, frmMain);
  Writeln('NATIVE main_bootstrap_ms=', GetTickCount64 - Started); Flush(Output);
  Languages := TComboBox.Create(nil);
  try
    Languages.Parent := frmMain; Languages.Visible := False; Languages.Items.Add('-'); Languages.ItemIndex := 0;
    Settings.TreeModes[PAGE_SEARCH] := tmTree;
    for I := 0 to 2 do
    begin
      Started := GetTickCount64;
      Iterator := Query(I);
      frmMain.FillBooksTree(frmMain.tvBooksSR, Languages, Iterator, True, True, nil);
      Iterator := nil;
      Writeln('NATIVE tree_query=', I, ' build_ms=', GetTickCount64 - Started); Flush(Output);
      Require(not frmMain.BookListCancelled, 'Native large query was cancelled');
      BookNodes := 0; Node := frmMain.tvBooksSR.GetFirst;
      while Assigned(Node) do begin Data := frmMain.tvBooksSR.GetNodeData(Node);
        if Data.NodeType = ntBookInfo then Inc(BookNodes); Node := frmMain.tvBooksSR.GetNext(Node); end;
      Writeln('NATIVE tree_query=', I, ' book_nodes=', BookNodes); Flush(Output);
      frmMain.tvBooksSR.Clear;
    end;
  finally Languages.Free; frmMain.Free; frmMain := nil; dmImages.Free; dmImages := nil; end;
  Writeln('PASS full INPX production import and heavy native lists use only an isolated catalog');
end;

{$I BuiltinBookExportTests.inc}
{$I SearchPresetTests.inc}
{$I SearchPresetTransferTests.inc}
{$I FilterCaptionTests.inc}
{$I DeletedFilterTests.inc}
{$I PublisherSearchTests.inc}
{$I Feedback20Tests.inc}
{$I Feedback21Tests.inc}
{$I MetadataArchiveCodecTests.inc}
{$I PublisherColumnTests.inc}
{$I AuthorFavoriteTests.inc}
{$I AuthorFavoriteDaoTests.inc}
{$I FavoriteAuthorColumnTests.inc}
{$I SystemBookRemapTests.inc}
{$I UpdateOutcomeTests.inc}
{$I FavoriteAuthorUiTests.inc}
{$I ReaderCopyIdentityTests.inc}
{$I ReaderMainFilterTests.inc}
{$I ReaderChapterTitlesTests.inc}
{$I MetadataPrefixBoundsTests.inc}
{$I ReaderExternalNameTests.inc}
{$I GroupBookIdentityTests.inc}
{$I OrdinaryBookExportIdentityTests.inc}
{$I AtomicIniFileTests.inc}
{$I DownloadQueueSerializationTests.inc}
{$I QueuePersistenceTests.inc}
{$I SearchStartupLayoutTests.inc}
{$I CatalogSourcesWorkflowTests.inc}
{$I MainLiveInputFavoriteTests.inc}
{$I UpdateFormNotifierTests.inc}
{$I UpdateRepairTests.inc}
{$I MetadataFillUiTests.inc}
{$I BookInfoPanelFooterTests.inc}
{$I CompactBookViewsTests.inc}
{$I CollectionMetadataSyncTests.inc}
{$I PublisherMetadataIndexTests.inc}
{$I ReaderPipelineCacheTests.inc}
{$I ReaderCachePerformanceTests.inc}
{$I MetabibSizeComparisonTests.inc}
{$I ..\..\..\Program\Tests\cache_folder_presets_test.inc}
{$I NativeFolderPickerTests.inc}
{$I Feedback22Tests.inc}
{$I CatalogAuditTests.inc}
{$I MainExportPreparationTests.inc}
{$I MainLegacyImportWorkflowTests.inc}
{$I SettingsWorkflowAuditTests.inc}
{$I ReaderConversionAuditTests.inc}
{$I ExportResultsAuditTests.inc}
{$I CatalogSearchModeTests.inc}
{$I AuthorDisplaySettingTests.inc}
{$I LegacyImportPreviewTests.inc}
{$I InpStreamingTests.inc}
{$I ReaderNotesProposalTests.inc}
{$I UpdateProposalsTests.inc}
{$I Release23UiTests.inc}
{$I MetadataBookColumnsTests.inc}
{$I RefactorAuditTests.inc}
{$I Post525UpdateTests.inc}
{$I StartupDeferredTests.inc}
{$I BookViewSessionTests.inc}
{$I FirstBookListTests.inc}

var
  One, Two, Online: IBookCollection;
  OneID, TwoID, FirstBook, LastBook, UnknownBook, I: Integer;
  OnlineID, DirectBookID, QueueBookID, RestartBookID, Port: Integer;
  Book: PBookRecord;
  ImportedGenre: TGenreData;
  PublisherSeries: TBookSeries;
  PublisherIterator: ISeriesIterator;
  Publisher: TSeriesData;
  ExceptionHandler: TRegressionExceptionHandler;
begin
  SetTextCodePage(Output, 65001);
  try
    RequireIsolatedRegression;
    if ParamStr(1) = 'external-tool-probe' then begin RunExternalToolProbe; Halt(0); end;
    if (ParamStr(1)='refactor-slow-converter') or (ParamStr(1)='refactor-slow-leaf') then
    begin RefactorSlowConverter; Halt(0); end;
    HandleReaderProbe;
    DirectBookID := 0;
    QueueBookID := 0;
    RestartBookID := 0;
    Trace('application bootstrap');
    Application.Initialize;
    if (ParamStr(1) = 'publisher-startup') or (ParamStr(1) = 'cancel-interactive') or
      ParamStr(1).StartsWith('startup-deferred') or (ParamStr(1) = 'view-session-reopen') then
      Application.MainFormOnTaskbar := True;
    ExceptionHandler := TRegressionExceptionHandler.Create;
    Application.OnException := ExceptionHandler.HandleException;
    Trace('localization');
    InitLocalization;
    Trace('splash construction');
    frmSplash := TfrmSplash.Create(Application);
    try
      Trace('isolated user module');
      Application.CreateForm(TDMUser, DMUser);
      DMUser.Init;
      if ParamStr(1) = 'view-session-reopen' then begin ViewSessionChild; Halt(0); end;
      if ParamStr(1) = 'query-batch' then begin TestSQLiteQueryBatch; Halt(0); end;
      if ParamStr(1) = 'update-theme' then begin TestUpdateNotesTheme; Halt(0); end;
      if ParamStr(1) = 'fbd-editor-save' then begin TestFBDEditorSave; Halt(0); end;
      if ParamStr(1) = 'series-stream' then begin TestSeriesReadStream; Halt(0); end;
      if ParamStr(1) = 'bulk-writes' then begin TestBulkWriteSafety; TestSchemaReopenSafety; TestMetadataDeltaSafety; Halt(0); end;
      if ParamStr(1) = 'large-inpx' then begin BenchmarkLargeINPX; Halt(0); end;
      if ParamStr(1) = 'merge-scale' then begin BenchmarkMergeScale; Halt(0); end;
      if ParamStr(1) = 'existing-merge' then begin BenchmarkExistingMerge; Halt(0); end;
      if (ParamStr(1) = 'first-run') or (ParamStr(1) = 'first-run-cancel') then
      begin
        RunFirstRunRegression;
        Flush(Output);
        Halt(0);
      end;
      Trace('tiny fixtures');
      OneID := SystemDB.CreateCollection('One', Settings.AppPath,
        'one.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      TwoID := SystemDB.CreateCollection('Two', Settings.AppPath,
        'two.hlc2', CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
      One := SystemDB.GetCollection(OneID);
      Two := SystemDB.GetCollection(TwoID);
      FirstBook := AddBook(One, 'Alpha uk', 'Alpha', 'uk', 'Alpha series', 'prose_contemporary');
      LastBook := AddBook(One, 'Alpha ru', 'Alpha', 'ru', 'Alpha series', 'prose_contemporary');
      One.AddBookToGroup(CreateBookKey(FirstBook, OneID), FAVORITES_GROUP_ID);
      One.AddBookToGroup(CreateBookKey(LastBook, OneID), FAVORITES_GROUP_ID);
      AddBook(One, 'Alpha extra uk', 'Alpha', 'uk', '', 'prose_contemporary');
      AddBook(One, 'Genre uk', 'Beta', 'uk', '', '0.1');
      AddBook(One, 'Genre ru', 'Beta', 'ru', '', '0.1');
      AddBook(One, 'Genre deleted', 'Beta', 'ru', '', '0.1', True);
      UnknownBook := AddBook(One, 'Unknown', 'Gamma', 'ru', '', '');
      AddBook(Two, 'Other uk', 'Other', 'uk', '', '0.1');
      AddBook(Two, 'Other ru', 'Other', 'ru', '', '0.1');
      if (ParamStr(1) = 'online-download') or (ParamStr(1) = 'online-plain') then
      begin
        Port := StrToIntDef(ParamStr(2), 0);
        Require((Port > 0) and (Port <= 65535), 'Online regression requires its loopback server port');
        CreateOnlineResponse;
        OnlineID := SystemDB.CreateCollection('Online regression', Settings.AppPath,
          'online.hlc2', CT_EXTERNAL_ONLINE_FB, Settings.AppPath + 'genres_fb2.glst');
        Online := SystemDB.GetCollection(OnlineID);
        Online.SetProperty(PROP_URL, Format('http://127.0.0.1:%d/', [Port]));
        Online.SetProperty(PROP_CONNECTIONSCRIPT, 'GET %URL%b/%LIBID%/get' + sLineBreak + 'CHECK');
        if ParamStr(1) = 'online-plain' then
          DirectBookID := AddOnlineBook(Online, 'Online plain', '900003', False)
        else
        begin
          DirectBookID := AddOnlineBook(Online, 'Online reader', '900001');
          QueueBookID := AddOnlineBook(Online, 'Online queue', '900002');
          RestartBookID := AddOnlineBook(Online, 'Online restart', '900004');
        end;
      end;
      if (ParamStr(1) = 'publisher-selection') or (ParamStr(1) = 'publisher-startup') or (ParamStr(1) = 'startup-deferred-publisher') then
      begin
        TSeriesHelper.Add(PublisherSeries, 0, 'Fixture publisher', 1, False);
        One.SetBookPublisherSeries(CreateBookKey(FirstBook, OneID), PublisherSeries);
        PublisherSeries[0].SeqNumber := 2;
        One.SetBookPublisherSeries(CreateBookKey(LastBook, OneID), PublisherSeries);
        PublisherIterator := One.GetPublisherSeriesIterator;
        Require(PublisherIterator.Next(Publisher), 'Publisher fixture was not registered');
        One.SetProperty(PROP_LAST_PUBLISHER_SERIES, Publisher.SeriesID);
        One.SetProperty(PROP_LAST_PUBLISHER_BOOK, LastBook);
        One.SetProperty(PROP_PUBLISHER_LANG_FILTER, 2);
        PublisherIterator := nil;
      end;
      if ParamStr(1) = 'source-genres' then
      begin
        ImportedGenre := One.EnsureGenre('popadancy', 'Imported genre', 'Imported category');
        One.SetProperty(PROP_GENRE_FILE, 'genres_fb2_uk.glst');
      end;
      One.SetProperty(PROP_LAST_AUTHOR_BOOK, LastBook);
      if ParamStr(1) = 'language-isolation' then
        One.SetProperty(PROP_GENRES_LANG_FILTER, 0)
      else
        One.SetProperty(PROP_GENRES_LANG_FILTER, 2);
      One.SetProperty(PROP_SERIES_LANG_FILTER, 1);
      One.SetProperty(PROP_GROUPS_LANG_FILTER, 2);
      Two.SetProperty(PROP_GENRES_LANG_FILTER, 1);
      Settings.ActiveCollection := OneID;
      Settings.ActivePage := PAGE_AUTHORS;
      if ParamStr(1) = 'view-sessions' then
      begin
        Require(Settings.RestoreBookViews = rbvAsk, 'Restore must default to asking');
        Settings.RestoreBookViews := rbvAutomatic;
        for I := 0 to 6 do Settings.TreeModes[I] := tmFlat;
      end;
      if (ParamStr(1) = 'publisher-startup') or (ParamStr(1) = 'startup-deferred-publisher') then
      begin
        Settings.ActivePage := PAGE_PUBLISHER_SERIES;
        Settings.ShowInfoPanel := True;
        Settings.ShowBookCover := True;
        Settings.ShowBookAnnotation := True;
        Settings.InfoPanelHeight := 310;
        Settings.FormWidth := 1173;
        Settings.FormHeight := 1073;
        Settings.Splitters[5] := 434;
      end;
      Trace('image module');
      Application.CreateForm(TdmImages, dmImages);
      dmImages.ApplyThemeIcons;
      Require(SystemDB.FindFirstExistingCollectionID(OneID) = OneID,
        'The registered fixture collection file is absent');
      if ParamStr(1) = 'queue-load-negative' then PrepareQueuePersistenceStartup('negative')
      else if ParamStr(1) = 'queue-load-truncated' then PrepareQueuePersistenceStartup('truncated')
      else if ParamStr(1) = 'queue-load-zero' then PrepareQueuePersistenceStartup('zero');
      if ParamStr(1) = 'search-startup-layout' then PrepareSearchStartupLayout;
      Trace('main form');
      if ParamStr(1) = 'feedback22' then PrepareFeedback22Scripts;
      if ParamStr(1).StartsWith('startup-deferred') then TfrmMain.DeferInitialCollection := True;
      if ParamStr(1) = 'startup-deferred-fallback' then Settings.ActiveCollection := 999999;
      Application.CreateForm(TfrmMain, frmMain);
      if ParamStr(1) = 'startup-deferred-close' then
      begin TestDeferredStartupEarlyClose; Halt(0); end;
      if ParamStr(1).StartsWith('startup-deferred') then CompleteDeferredStartup;
      if ParamStr(1) = 'search-startup-layout' then TestSearchStartupLayout;
      TestHeaderMenuTags;
      Trace('genre form');
      if not Assigned(frmGenreTree) then Application.CreateForm(TfrmGenreTree, frmGenreTree);
      Trace('initial selection checks');
      if (ParamStr(1) = 'publisher-startup') or (ParamStr(1) = 'startup-deferred-publisher') then
      begin
        Require(frmMain.pgControl.ActivePage = PublisherView.Tab, 'Saved publisher page was not restored');
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        Require(PublisherView.Info.Visible and PublisherView.Info.HandleAllocated,
          'Publisher information panel was not created');
        Application.ProcessMessages;
        Writeln('PASS saved publisher page starts with visible cover and information panel');
        ShowPage(PAGE_AUTHORS);
      end;
      if ParamStr(1) <> 'search-startup-layout' then
      begin
        ExpectTitles(frmMain.tvBooksA, ['Alpha uk', 'Alpha ru', 'Alpha extra uk']);
        Book := frmMain.tvBooksA.GetNodeData(frmMain.tvBooksA.FocusedNode);
        Require(Assigned(Book) and (Book.BookKey.BookID = LastBook),
          'The saved author book was not restored');
        Writeln('PASS default author selection and saved book');
      end;
      if ParamStr(1) = 'search-startup-layout' then
        Trace('fresh Search startup already checked before other Main actions')
      else if ParamStr(1).StartsWith('startup-deferred') then
      begin
        TestStartupWorkerLifecycle;
        TestPreferredSourceRows;
        Require(Settings.ActiveCollection = OneID, 'Startup fallback selected the wrong collection');
        Writeln('PASS deferred startup keeps saved book, view and collection fallback');
      end
      else if ParamStr(1) = 'view-sessions' then
        TestBookViewSessions(OneID, TwoID)
      else if ParamStr(1) = 'post525-update' then
        TestPost525UpdateDetails
      else if ParamStr(1) = 'oct11-ui' then
        TestOctoberElevenUI
      else if ParamStr(1) = 'builtin-export' then
        TestBuiltinBookExport(One)
      else if ParamStr(1) = 'search-presets' then
        TestSearchPresetSafety
      else if ParamStr(1) = 'search-preset-transfer' then
        TestSearchPresetTransfer(One, OneID)
      else if ParamStr(1) = 'filter-captions' then
      begin
        Trace('filter caption native subcase=' + ParamStr(2));
        if ParamStr(2) = '' then
        begin
          TestFilterCaptionLayout(frmMain.tvBooksA);
          TestAnnotationCaptionLayout;
        end
        else if ParamStr(2) = 'popup' then
          TestFilterCaptionLayout(frmMain.tvBooksA)
        else if ParamStr(2) = 'annotation-light' then
          TestAnnotationCaptionLayout(0)
        else if ParamStr(2) = 'annotation-dark' then
          TestAnnotationCaptionLayout(1)
        else
          Require(False, 'Unknown filter-caption subcase: ' + ParamStr(2));
      end
      else if ParamStr(1) = 'deleted-filter' then
        TestUnifiedDeletedFilter(One, OneID, TwoID)
      else if ParamStr(1) = 'cache-presets' then
        TestCacheFolderPresets
      else if ParamStr(1) = 'metadata-archive-codecs' then
        TestMetadataArchiveCodecs
      else if ParamStr(1) = 'main-search-proposals-visual' then TestMainSearchProposalsVisual(One)
      else if ParamStr(1) = 'catalog-proposals-visual' then TestCatalogProposalsVisual
      else if ParamStr(1) = 'reader-notes-visual' then TestReaderNotesVisual('G:\HomeLibRu-proposals-2026-10-16\reader-notes')
      else if ParamStr(1) = 'update-proposals-visual' then TestUpdateProposalsVisual
      else if ParamStr(1) = 'export-results-audit' then TestExportResultsAudit
      else if ParamStr(1) = 'search-query-modes' then TestCatalogSearchModes(One)
      else if ParamStr(1) = 'author-display-setting' then TestAuthorDisplaySetting
      else if ParamStr(1) = 'metadata-book-columns' then TestMetadataBookColumns(One)
      else if ParamStr(1) = 'metadata-book-columns-visual' then TestMetadataBookColumnsVisual(One)
      else if ParamStr(1) = 'legacy-import-preview' then TestLegacyImportPreviewProposals
      else if ParamStr(1) = 'inp-streaming' then TestInpStreamingProposals
      else if ParamStr(1) = 'inp-streaming-memory' then TestInpStreamingMemory
      else if ParamStr(1) = 'reader-notes-proposals' then TestReaderNotesProposals('G:\HomeLibRu-proposals-2026-10-16\reader-notes')
      else if ParamStr(1) = 'update-keyboard-accessibility' then TestUpdateKeyboardAccessibility
      else if ParamStr(1) = 'update-source-failures' then TestUpdateSourceFailures
      else if ParamStr(1) = 'reader-conversion-audit' then
        TestReaderConversionAudit(Settings.AppPath + 'reader-conversion-audit', Settings.AppPath)
      else if ParamStr(1) = 'settings-workflow-audit' then TestSettingsWorkflowAudit
      else if ParamStr(1) = 'catalog-audit' then TestCatalogAudit(One, Two, OneID, TwoID)
      else if ParamStr(1) = 'export-preparation' then TestMainExportPreparation(False)
      else if ParamStr(1) = 'legacy-import-interactive' then TestMainLegacyImportWorkflow(One, OneID)
      else if ParamStr(1) = 'refactor-audit' then TestRefactorAudit
      else if ParamStr(1) = 'export-cancel-interactive' then TestMainExportPreparation(True)
      else if ParamStr(1) = 'native-folder-picker' then TestNativeFolderPicker
      else if ParamStr(1) = 'feedback22' then TestFeedback22(One, OneID)
      else if ParamStr(1) = 'feedback21' then TestFeedback21
      else if ParamStr(1) = 'feedback20-main' then
        TestFeedback20(One,Two,OneID,TwoID)
      else if ParamStr(1) = 'publisher-search' then
        TestPublisherSearch(One, OneID)
      else if ParamStr(1) = 'publisher-columns' then
        TestPublisherColumnFilters
      else if ParamStr(1) = 'author-favorites' then
        TestAuthorFavorites
      else if ParamStr(1) = 'favorite-dao' then
        TestAuthorFavoriteDAO(One)
      else if ParamStr(1) = 'favorite-columns' then
        TestFavoriteAuthorColumnFilters
      else if ParamStr(1) = 'system-remap' then
        TestSystemBookRemapSafety
      else if ParamStr(1) = 'update-outcomes' then
        TestUpdateOutcomes
      else if ParamStr(1) = 'favorite-ui' then
        TestFavoriteAuthorUI(One, OneID, TwoID)
      else if ParamStr(1) = 'atomic-ini' then
        TestAtomicIniFile
      else if ParamStr(1) = 'queue-serialization' then
        TestDownloadQueueSerialization
      else if ParamStr(1) = 'queue-persistence' then
        TestQueuePersistence(OneID)
      else if (ParamStr(1) = 'queue-load-negative') or (ParamStr(1) = 'queue-load-truncated') or
        (ParamStr(1) = 'queue-load-zero') then
        TestQueuePersistenceStartup
      else if ParamStr(1) = 'group-book-identity' then
        TestGroupBookIdentity(ParamStr(2))
      else if ParamStr(1) = 'ordinary-book-export-identity' then
        TestOrdinaryBookExportIdentity
      else if ParamStr(1) = 'reader-copy-identity' then
        TestReaderCopyIdentity
      else if ParamStr(1) = 'language-isolation' then
        TestLanguageIsolation
      else if ParamStr(1) = 'favorites-add' then
        TestAddBeforeFirstGroupVisit
      else if ParamStr(1) = 'genre-link' then
        TestGenreLink
      else if ParamStr(1) = 'genre-order' then
        TestGenreOrder(One, UnknownBook)
      else if ParamStr(1) = 'publisher-selection' then
        TestPublisherSelection(OneID, TwoID, LastBook)
      else if ParamStr(1) = 'publisher-links' then
        TestPublisherLinks(One, OneID, TwoID)
      else if (ParamStr(1) = 'publisher-startup') or (ParamStr(1) = 'startup-deferred-publisher') then
      begin
        frmMain.pgControl.ActivePage := PublisherView.Tab;
        frmMain.pgControlChange(nil);
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        ChangeCollection(TwoID);
        ChangeCollection(OneID);
        ExpectTitles(PublisherView.Books, ['Alpha ru']);
        Writeln('PASS startup publisher view survives collection switches');
      end
      else if ParamStr(1) = 'publisher-error-log' then
        TestPublisherErrorLog(One)
      else if ParamStr(1) = 'adjacent-series' then
        TestAdjacentSeriesSelection(One, OneID, TwoID)
      else if ParamStr(1) = 'loose-archive' then
        TestLooseArchiveReading
      else if ParamStr(1) = 'reader-compatibility' then
        TestReaderCompatibility
      else if (ParamStr(1) = 'builtin-reader') or (ParamStr(1)='reader-resource-idle') then
        TestBuiltinReaderIntegration(One)
      else if ParamStr(1) = 'main-preview' then
      begin
        frmMain.Show;
        Application.Run;
      end
      else if ParamStr(1) = 'review-http' then
        TestReviewHTTP
      else if ParamStr(1) = 'book-information' then
        TestBookInformation
      else if ParamStr(1) = 'book-gallery' then
        TestBookGallery
      else if (ParamStr(1) = 'catalog-sources') or (ParamStr(1) = 'catalog-sources-ui') then
        TestCatalogSources
      else if ParamStr(1) = 'collection-merge' then
        TestCollectionMerge
      else if ParamStr(1) = 'book-preview' then
        TestAsyncBookPreview
      else if ParamStr(1) = 'first-book-list' then
        TestFirstBookList
      else if ParamStr(1) = 'list-performance' then
        TestListPerformance
      else if ParamStr(1) = 'reader-filter' then
        TestReaderWithColumnFilter
      else if ParamStr(1) = 'reader-main-filter' then
        TestReaderMainWithColumnFilter
      else if ParamStr(1) = 'catalog-sources-workflow' then TestCatalogSourcesWorkflow
      else if ParamStr(1) = 'compact-book-views' then TestCompactBookViews
      else if ParamStr(1) = 'update-repair' then TestUpdateRepair
      else if ParamStr(1) = 'reader-cache-performance' then TestReaderCachePerformance
      else if ParamStr(1) = 'book-preview-layout' then TestInfoPanelFooter
      else if ParamStr(1) = 'metadata-fill-layout' then TestMetadataFillLayout(OneID)
      else if ParamStr(1) = 'metadata-fill-ui' then TestMetadataFillUI(OneID)
      else if ParamStr(1) = 'collection-metadata-sync' then TestCollectionMetadataSync
      else if ParamStr(1) = 'main-toolbar-states' then TestMainThemeToolbarStates
      else if ParamStr(1) = 'main-publisher-index-cache' then TestMainPublisherIndexCache(OneID)
      else if ParamStr(1) = 'conversion-menu' then TestMainBuiltinConversionMenus(OneID)
      else if ParamStr(1) = 'metabib-size' then TestMetabibSizeComparison(ExpandFileName('metabib-size-inputs/same-records-full.jsonl'),ExpandFileName('metabib-size-inputs/same-records.inpx'))
      else if ParamStr(1) = 'reader-pipeline-cache' then TestReaderPipelineCache
      else if ParamStr(1) = 'publisher-metadata-index' then TestPublisherMetadataIndex
      else if ParamStr(1) = 'feedback19-main' then
      begin
        TestMainLiveLocateInput(One, OneID); TestFavoriteAuthorAffordances(One, OneID); TestLoadedListThemeMetrics;
      end
      else if ParamStr(1) = 'feedback529' then TestFeedback529ReaderAndStatistics(One)
      else if ParamStr(1) = 'reader-chapters' then
        TestReaderChapterTitles
      else if ParamStr(1) = 'metadata-prefix-bounds' then
        TestMetadataPrefixBounds
      else if ParamStr(1) = 'external-reader-names' then
        TestExternalReaderNames
      else if ParamStr(1) = 'cancel-interactive' then
        TestInteractiveCancel
      else if ParamStr(1) = 'persistent-cache' then
        TestPersistentCache
      else if ParamStr(1) = 'audit-new' then
      begin
        TestSQLiteRuntime;
        if (ParamStr(2)='archives') or (ParamStr(2)='images') then TestArchiveAndImageAudit
        else TestAdversarialAudit;
      end
      else if ParamStr(1) = 'feedback14' then
        TestFeedback14
      else if ParamStr(1) = 'column-filters' then
        TestBookColumnFilters
      else if ParamStr(1) = 'read-folder-cleanup' then
        TestReadFolderCleanup
      else if ParamStr(1) = 'temp-exit-cleanup' then
        TestExitReaderCleanup
      else if ParamStr(1) = 'update-form-notifier' then TestUpdateFormNotifier
      else if ParamStr(1) = 'release23-filters' then TestRelease23Filters(frmMain.tvBooksA)
      else if ParamStr(1) = 'release23-ready-visual' then TestUpdateReadyReleasePages
      else if ParamStr(1) = 'program-update-ui' then
        TestProgramUpdateUI
      else if ParamStr(1) = 'program-update-download' then
        TestProgramUpdateDownload
      else if ParamStr(1) = 'online-download' then
        TestOnlineDownload(Online, DirectBookID, QueueBookID, RestartBookID)
      else if ParamStr(1) = 'online-plain' then
        TestOnlinePlain(Online, DirectBookID)
      else if ParamStr(1) = 'source-genres' then
      begin
        TestSourceGenrePreservation(ImportedGenre);
        ChangeCollection(TwoID);
        ChangeCollection(OneID);
        TestSourceGenrePreservation(ImportedGenre);
      end
      else
      begin
        ChangeCollection(TwoID);
        Require(One.GetProperty(PROP_GENRES_LANG_FILTER) = 2,
          'Switching collections overwrote an unopened genre language filter');
        ChangeCollection(OneID);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru']);
        Require(frmMain.cbLangSelectG.Text = 'ru', 'Saved genre language was not restored');
        Writeln('PASS unopened genre filter survives collection switches');
        ShowPage(PAGE_SERIES);
        ExpectTitles(frmMain.tvBooksS, ['Alpha uk']);
        Require(frmMain.cbLangSelectS.Text = 'uk', 'Saved series language was not restored');
        Writeln('PASS first series visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        frmMain.HideDeletedBooksExecute(nil);
        ShowPage(PAGE_GENRES);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS changed deletion filter refreshes previously visited views');
        ChangeCollection(TwoID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Other uk']);
        ChangeCollection(OneID);
        RequestRootGenreBooks;
        ExpectTitles(frmMain.tvBooksG, ['Genre ru', 'Genre deleted']);
        Writeln('PASS visible genre view refreshes across collections');
        ShowPage(PAGE_FAVORITES);
        ExpectTitles(frmMain.tvBooksF, ['Alpha ru']);
        Require(frmMain.cbLangSelectF.Text = 'ru', 'Saved group language was not restored');
        Writeln('PASS first group visit restores its language filter');
        ShowPage(PAGE_AUTHORS);
        for I := 0 to frmMain.tbarAuthorsEng.ButtonCount - 1 do
          if frmMain.tbarAuthorsEng.Buttons[I].Caption = 'Z' then
            frmMain.tbarAuthorsEng.Buttons[I].OnClick(frmMain.tbarAuthorsEng.Buttons[I]);
        ExpectTitles(frmMain.tvBooksA, []);
        frmMain.HideDeletedBooksExecute(nil);
        ExpectTitles(frmMain.tvBooksA, []);
        Writeln('PASS empty author selection stays empty after a global refresh');
      end;
      Trace('test completed; cleanup genre');
      frmGenreTree.Free;
      frmGenreTree := nil;
      Trace('cleanup main');
      frmMain.Free;
      frmMain := nil;
      Trace('main cleanup complete');
      if (ParamStr(1) = 'queue-persistence') or (ParamStr(1) = 'queue-load-negative') or
        (ParamStr(1) = 'queue-load-truncated') or (ParamStr(1) = 'queue-load-zero') then
        CheckQueuePersistenceAfterClose;
      if ParamStr(1) = 'temp-exit-cleanup' then CheckExitReaderCleanup;
      One := nil;
      Two := nil;
      Online := nil;
      dmImages.Free;
      dmImages := nil;
      DMUser.Free;
      DMUser := nil;
    finally
      frmSplash.Free;
      frmSplash := nil;
    end;
    Application.OnException := nil;
    ExceptionHandler.Free;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Writeln('TRACE exception RVA ', IntToHex(NativeUInt(ExceptAddr) - NativeUInt(HInstance), 8));
      Flush(Output);
      Winapi.Windows.ExitProcess(1);
    end;
  end;
end.
