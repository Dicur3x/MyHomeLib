{$I ReaderDiagnosticsTests.inc}

type
  TReaderHostSessionDriver = class
    Host: TfrmReaderHost;
    Request: TReaderSessionRequest;
    Timer: TTimer;
    Started: UInt64;
    Error: string;
    Completed: Boolean;
    SavedPosition: Integer;
    procedure Tick(Sender: TObject);
  end;

type
  TStandaloneNotesProbe = class
    Host: TfrmReaderHost;
    Timer: TTimer;
    Profile, PlainFile, Error: string;
    Stage: Integer;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

procedure TStandaloneNotesProbe.Tick(Sender: TObject);
var Picker, Dialog: TCustomForm; Reader: TfrmBuiltinReader; Books: TComboBox;
  NotesList: TListView; Store: TReaderAnnotations; Note: TReaderAnnotation;
  Recent: TListBox; Key: Word; Title: string; Item: TListItem;
begin
  Picker:=nil; Dialog:=nil; Reader:=nil;
  for var I:=0 to Host.ComponentCount-1 do
    if Host.Components[I] is TfrmBuiltinReader then Reader:=TfrmBuiltinReader(Host.Components[I]);
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible then
    begin
      if Screen.Forms[I].Caption='Какую книгу открыть?' then Picker:=Screen.Forms[I];
      if Assigned(Screen.Forms[I].FindComponent('NotesList')) then Dialog:=Screen.Forms[I];
    end;
  try
    Require(GetTickCount64<Deadline,'Standalone notes timed out at step '+IntToStr(Stage));
    if Stage>0 then Require(not Assigned(Picker),'The reader asked for the archive entry again');
    case Stage of
      0: if Assigned(Picker) then
        for var Component in Picker do
          if Component is TListBox then
          begin
            var Choice:=TListBox(Component);
            Choice.ItemIndex:=Choice.Items.IndexOf('books/selected.fb2');
            Require(Choice.ItemIndex>=0,'The archive picker did not list the second book');
            Stage:=1; Picker.ModalResult:=mrOk; Exit;
          end;
      1: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('TARGET SECOND'),'Incorrect original archive selection');
          Reader.SetPageLayout(rplSingle);
          Reader.GoToPosition(900); Reader.AddBookmark('Место закладки');
          Note:=Reader.AnnotationDraft('');
          Note.Title:='Место заметки'; Note.Text:='Сохранённое место'; Note.Position:=1200;
          Store:=TReaderAnnotations.Create(Profile);
          try Store.Put(Note); finally Store.Free; end;
          Stage:=2; Reader.Close;
        end;
      2: if not Assigned(Reader) and Host.Visible then
        begin
          Recent:=Host.FindComponent('ReaderRecentBooks') as TListBox;
          Recent.ItemIndex:=Recent.Items.IndexOf(PlainFile);
          Require(Recent.ItemIndex>=0,'The previously opened plain file is missing from recent books');
          Key:=VK_RETURN; Stage:=3; Recent.OnKeyDown(Recent,Key,[]);
          Require(Key=0,'Enter was not handled in recent books');
        end;
      3: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('PLAIN TEXT'),'Recent book did not reopen the plain file');
          for var Component in Reader do
            if (Component is TButton) and (TButton(Component).Caption='Закладки и заметки') then
            begin Stage:=4; TButton(Component).Click; Exit; end;
          Require(False,'Book toolbar has no notes button');
        end;
      4,8: if Assigned(Dialog) then
        begin
          Books:=Dialog.FindComponent('NotesBooks') as TComboBox;
          if Stage=4 then
          begin
            Require(Books.ItemIndex>0,'Book toolbar did not default to the current book');
            Books.ItemIndex:=0; Books.OnChange(Books);
            Title:='Место заметки';
          end
          else
          begin
            Require(Books.ItemIndex=0,'Launcher did not open notes for all books');
            Title:='Место закладки';
          end;
          NotesList:=Dialog.FindComponent('NotesList') as TListView;
          for var I:=0 to NotesList.Items.Count-1 do
          begin
            Item:=NotesList.Items[I];
            if (Item.SubItems.Count>0) and (Item.SubItems[0]=Title) then
            begin NotesList.Selected:=Item; Inc(Stage); NotesList.OnDblClick(NotesList); Exit; end;
          end;
          Require(False,'Could not find '+Title+' in the normal notes list');
        end;
      5,9: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('TARGET SECOND') and not Reader.BookText.Contains('WRONG FIRST'),
            'The saved record opened the wrong archive entry');
          if Stage=5 then Require(Reader.TextPosition=1200,'The other book did not open at the note position')
          else Require(Reader.TextPosition=900,'The archive did not open at the bookmark after restarting');
          Inc(Stage); Reader.Close; Timer.Enabled:=False;
        end;
      7: if Host.Visible then
        begin
          var MenuItem:=Host.Menu.FindComponent('ReaderAllNotesMenu') as TMenuItem;
          Require(Assigned(MenuItem),'Standalone launcher has no all-books notes command');
          Stage:=8; MenuItem.Click;
        end;
    end;
  except on E: Exception do
    begin
      Error:=E.Message; Timer.Enabled:=False;
      if Assigned(Dialog) then Dialog.ModalResult:=mrCancel;
      if Assigned(Picker) then Picker.ModalResult:=mrCancel;
      if Assigned(Reader) then Reader.Close;
    end;
  end;
end;

procedure TestStandaloneNotes;
var Probe: TStandaloneNotesProbe; Host: TfrmReaderHost; Ini: TMemIniFile;
  Zip: TZipFile; ArchiveFile, TextFile, Payload, SourceHash: string;
  procedure WaitForStep(EndStage: Integer);
  begin
    Probe.Deadline:=GetTickCount64+20000; Probe.Timer.Enabled:=True;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(10);
    until (Probe.Stage=EndStage) or (Probe.Error<>'') or (GetTickCount64>Probe.Deadline);
    Require(Probe.Error='',Probe.Error);
    Require(Probe.Stage=EndStage,'Standalone notes did not finish at '+IntToStr(Probe.Stage));
  end;
begin
  RequireIsolatedRegression;
  ArchiveFile:=Settings.AppPath+'standalone-notes.zip'; TextFile:=Settings.AppPath+'standalone-recent.txt';
  TFile.WriteAllText(TextFile,'PLAIN TEXT',TEncoding.UTF8);
  Payload:='<FictionBook><body><section>';
  for var I:=1 to 120 do
    Payload:=Payload+'<p>TARGET SECOND '+IntToStr(I)+' Раздел книги для проверки точного перехода.</p>';
  Payload:=Payload+'</section></body></FictionBook>';
  Zip:=TZipFile.Create;
  try
    Zip.Open(ArchiveFile,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('<FictionBook><body><section><p>WRONG FIRST</p></section></body></FictionBook>'),
      'first.fb2',zcStored);
    Zip.Add(TEncoding.UTF8.GetBytes(Payload),'books/selected.fb2',zcStored);
  finally Zip.Free; end;
  SourceHash:=THashSHA2.GetHashStringFromFile(ArchiveFile);
  Probe:=TStandaloneNotesProbe.Create;
  try
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
    Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
    Probe.PlainFile:=TextFile; Probe.Profile:=ResolveReaderSettingsFile(Settings.DataDir);
    for var Run:=0 to 1 do
    begin
      Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
      try
        Ini.EraseSection('ReaderRecent'); Ini.WriteString('ReaderRecent','File0',TextFile);
        SaveMemIniFileAtomically(Ini);
      finally Ini.Free; end;
      Host:=TfrmReaderHost.Create(nil);
      try
        Probe.Host:=Host; Host.Show;
        if Run=0 then begin Probe.Stage:=0; Host.OpenFile(ArchiveFile); WaitForStep(6); end
        else begin Probe.Stage:=7; WaitForStep(10); end;
      finally Probe.Timer.Enabled:=False; Host.Free; end;
    end;
    Require(THashSHA2.GetHashStringFromFile(ArchiveFile)=SourceHash,'Standalone notes modified the source ZIP');
    Writeln('PASS standalone recent books and cross-book notes and bookmarks reopen the exact archive member');
  finally Probe.Timer.Free; Probe.Free; end;
end;

procedure TReaderHostSessionDriver.Tick(Sender: TObject);
var View: TfrmBuiltinReader; Probe: TStream; Blocked: Boolean; Key: Word; Deadline: UInt64;
begin
  View:=nil;
  for var I:=0 to Host.ComponentCount-1 do
    if Host.Components[I] is TfrmBuiltinReader then View:=TfrmBuiltinReader(Host.Components[I]);
  try
    Require(GetTickCount64-Started<20000,'Catalogue reader host did not finish opening');
    if not Assigned(View) or not View.Ready or View.PageLoading then Exit;
    Timer.Enabled:=False;
    Require(not Host.Visible,'Empty reader launcher remained visible behind the book');
    var KeysItem:=View.Menu.FindComponent('ReaderNavigationKeysMenu') as TMenuItem;
    Require(Assigned(KeysItem) and Assigned(KeysItem.OnClick) and (KeysItem.Parent.Caption='Настройки'),
      'The normal reader settings menu does not offer navigation keys');
    Require((GetWindow(View.Handle,GW_OWNER)=0) and
      ((GetWindowLongPtr(View.Handle,GWL_EXSTYLE) and WS_EX_APPWINDOW)<>0),
      'Standalone book did not become its own taskbar window');
    Require(View.BookText.Contains('SELECTED SECOND') and not View.BookText.Contains('WRONG FIRST'),
      'Catalogue reader host chose the wrong archive entry');
    Require(View.TextPosition=1200,'Catalogue reader host did not restore the existing position');
    Require(View.PageBackground=ReaderThemeBackground(4),
      'Catalogue launcher replaced the saved independent reading theme');
    Require(Host.Color<>View.Color,'Book theme leaked into the catalogue-themed launcher');
    var ExistingNotes:=View.AnnotationItems(False);
    Require((Length(ExistingNotes)=1) and (ExistingNotes[0].Text='Нельзя потерять'),
      'Catalogue reader host did not display the existing note');
    Require(Pos(Request.Book.Title,string(View.Caption))>0,'Catalogue reader host lost the catalogue title');
    Blocked:=False;
    try Probe:=TFileStream.Create(Request.SourceFile,fmOpenWrite or fmShareDenyNone); Probe.Free;
    except on E: Exception do Blocked:=True; end;
    Require(Blocked,'Catalogue reader host did not keep the original archive protected');
    CheckReaderDiagnosticsMenu(View);
    View.SetTheme(1);
    Require((View.PageBackground=RGB(244,231,215)) and (View.Font.Color=RGB(64,35,18)),
      'Reader did not restore the paper theme overrides');
    CheckReaderDiagnosticsMenu(View);
    View.SetThemeColors(clDefault,clDefault);
    Require((View.PageBackground=ReaderThemeBackground(1)) and
      (View.Font.Color=ReaderThemeText(1)), 'Reset did not restore the paper theme defaults');
    View.SetTheme(4);
    Require(View.PageBackground=ReaderThemeBackground(4), 'The paper palette changed the dark theme');
    View.SetThemeColors(RGB(23,32,40),RGB(236,234,222));
    Require((View.PageBackground=RGB(23,32,40)) and (View.Color=RGB(23,32,40)) and
      (View.Font.Color=RGB(236,234,222)), 'Custom colors did not repaint book and reader controls');
    Require(View.TextPosition=1200, 'Changing palette moved the reading position');
    View.SetPageLayout(rplContinuous);
    Require((View.VisiblePageCount=1) and (View.TextPosition=1200) and
      (View.PageRasterSize.Y=2*View.ReadingSurface.Height), 'Continuous text did not prepare two vertical tiles');
    View.ReadingSurface.SetFocus;
    for var Step:=1 to 3 do
    begin Key:=VK_DOWN; View.OnKeyDown(View,Key,[]); end;
    Deadline:=GetTickCount64+1500;
    repeat Application.ProcessMessages; Sleep(10);
    until (View.TextPosition>1200) or (GetTickCount64>Deadline);
    Require((Key=0) and (View.TextPosition>1200),Format(
      'Down arrow did not advance visible text: key=%d position=%d',[Key,View.TextPosition]));
    var Scrolled:=View.TextPosition;
    View.SelectText(Scrolled,12);
    Require(View.SelectedText<>'', 'Text selection stopped working during continuous reading');
    View.SetPageLayout(rplSingle);
    Require(View.TextPosition>=Scrolled, 'Leaving continuous reading jumped backwards');
    View.NextPage; View.AddBookmark('Передача из каталога');
    SavedPosition:=View.TextPosition; Require(SavedPosition>1200,'Reader did not turn the selected book');
    Completed:=True;
  except on E: Exception do begin Error:=E.Message; Timer.Enabled:=False; end; end;
  if Assigned(View) then View.Close;
end;

type
  TReaderCloseDriver = class
    Reader: TfrmBuiltinReader;
    Entered, ReleaseWork: TEvent;
    Timer: TTimer;
    Deadline: UInt64;
    Step: Integer;
    Retry: Boolean;
    Error: string;
    procedure Tick(Sender: TObject);
  end;

procedure TReaderCloseDriver.Tick(Sender: TObject);
begin
  try
    Require(GetTickCount64<Deadline,'Reader did not handle closing during background work');
    case Step of
      0:
        begin
          if Entered.WaitFor(0)<>wrSignaled then Exit;
          if Retry then Reader.ModalResult:=mrRetry
          else PostMessage(Reader.Handle,WM_CLOSE,0,0);
          Inc(Step);
        end;
      1:
        begin
          Require(Reader.Visible and not Reader.Enabled,'Reader did not defer the first close');
          if not Retry then PostMessage(Reader.Handle,WM_CLOSE,0,0);
          Inc(Step);
        end;
      2:
        begin
          Require(Reader.Visible and not Reader.Enabled,'Reader closed while work was still running');
          ReleaseWork.SetEvent;
          Inc(Step);
        end;
    end;
  except
    on E: Exception do
    begin
      Error:=E.Message;
      ReleaseWork.SetEvent;
      Timer.Enabled:=False;
      Reader.ModalResult:=mrCancel;
    end;
  end;
end;

procedure TestReaderCloseDuringWork;
var Driver: TReaderCloseDriver; Archive: TZipFile; Bitmap: TBitmap; Bytes: TBytesStream;
  TextFile, ComicFile: string; HoldWork: TProc;
begin
  RequireIsolatedRegression;
  TextFile:=TPath.Combine(Settings.AppPath,'reader-close.fb2');
  ComicFile:=TPath.Combine(Settings.AppPath,'reader-close.cbz');
  TFile.WriteAllText(TextFile,'<FictionBook><body><section><p>Reader close</p></section></body></FictionBook>',TEncoding.UTF8);
  Archive:=TZipFile.Create; Bitmap:=TBitmap.Create; Bytes:=TBytesStream.Create;
  try
    Bitmap.SetSize(64,64); Bitmap.SaveToStream(Bytes);
    Archive.Open(ComicFile,zmWrite);
    for var Index:=1 to 3 do
      Archive.Add(Copy(Bytes.Bytes,0,Integer(Bytes.Size)),IntToStr(Index)+'.bmp',zcStored);
  finally Bytes.Free; Bitmap.Free; Archive.Free; end;

  for var OnPage in [False,True] do
  begin
    Driver:=TReaderCloseDriver.Create;
    try
      Driver.Entered:=TEvent.Create(nil,True,False,'');
      Driver.ReleaseWork:=TEvent.Create(nil,True,False,'');
      Driver.Retry:=OnPage;
      HoldWork:=procedure
        begin
          Driver.Entered.SetEvent;
          Require(Driver.ReleaseWork.WaitFor(12000)=wrSignaled,'Reader close fixture was not released');
        end;
      if OnPage then TReaderPageThread.BeforePageForProfile:=HoldWork
      else TReaderLoadThread.BeforeLoadForProfile:=HoldWork;
      Driver.Reader:=TfrmBuiltinReader.Create(nil);
      Driver.Reader.SetPageLayout(rplSingle);
      Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=45; Driver.Timer.OnTimer:=Driver.Tick;
      Driver.Deadline:=GetTickCount64+8000;
      if OnPage then Driver.Reader.OpenBook(ComicFile,'Comic','reader-close-comic','','',nil)
      else Driver.Reader.OpenBook(TextFile,'Book','reader-close-book','','',nil);
      var Result:=Driver.Reader.ShowModal;
      Require(Driver.Error='',Driver.Error);
      Require(Driver.Step=3,'Reader modal loop stopped before the decoder was released');
      if OnPage then
        Require((Result=mrRetry) and Driver.Reader.Ready,'Reader lost the requested modal result while closing')
      else Require((Result=mrCancel) and not Driver.Reader.Ready,'A cancelled book was applied while closing');
    finally
      Driver.Timer.Free;
      if Assigned(Driver.ReleaseWork) then Driver.ReleaseWork.SetEvent;
      Driver.Reader.Free;
      TReaderPageThread.BeforePageForProfile:=nil;
      TReaderLoadThread.BeforeLoadForProfile:=nil;
      Driver.ReleaseWork.Free;
      Driver.Entered.Free;
      Driver.Free;
    end;
  end;
  Writeln('PASS reader closes responsively during document loading and page prefetch');
end;

procedure TestReaderPreparationClose;
var Archive: TZipFile; Host: TfrmReaderHost; Owner: TCustomForm;
  Entered, ReleaseWork: TEvent; FileName, Hash, CacheRoot: string;
  Started: UInt64; Opened, ShowMain: Boolean;
begin
  RequireIsolatedRegression;
  FileName:=TPath.Combine(Settings.AppPath,'reader-preparation-close.zip');
  Archive:=TZipFile.Create;
  try
    Archive.Open(FileName,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes('<FictionBook><body><section><p>Close during extraction</p></section></body></FictionBook>'),
      'book.fb2',zcDeflate);
  finally Archive.Free; end;
  Hash:=THashSHA2.GetHashStringFromFile(FileName);
  CacheRoot:=BookCachePath;
  ShowMain:=Application.ShowMainForm;
  for var Standalone in [True,False] do
  begin
    Entered:=TEvent.Create(nil,True,False,'');
    ReleaseWork:=TEvent.Create(nil,True,False,'');
    Host:=nil; Owner:=frmMain; Opened:=False;
    try
      BeforeReaderArchiveExtractForProfile:=procedure
        begin
          Entered.SetEvent;
          Require(ReleaseWork.WaitFor(12000)=wrSignaled,'Archive extraction fixture was not released');
        end;
      if Standalone then
      begin
        Host:=TfrmReaderHost.Create(nil); Owner:=Host;
        Host.OpenInitialFile(FileName);
      end
      else PrepareReaderFileInBackground(Owner,FileBook(FileName),True,
        procedure(Prepared: string) begin Opened:=True; end);
      Owner.Show;
      Started:=GetTickCount64;
      while (Entered.WaitFor(0)<>wrSignaled) and (GetTickCount64-Started<5000) do
      begin Application.ProcessMessages; Sleep(1); end;
      Require(Entered.WaitFor(0)=wrSignaled,'Preparation did not start extracting the ZIP');
      Require(Length(TDirectory.GetFiles(CacheRoot,'*.pending-*',TSearchOption.soAllDirectories))>0,
        'The extraction fixture did not create a temporary file');
      Started:=GetTickCount64;
      SendMessage(Owner.Handle,WM_CLOSE,0,0);
      Require(GetTickCount64-Started<500,'Close waited in the window thread for extraction');
      PostMessage(Owner.Handle,WM_CLOSE,0,0);
      Application.ProcessMessages;
      Require(Owner.Visible and not Application.Terminated and ReaderPreparationsPending(Owner),
        'Window stopped or freed an active extraction');
      ReleaseWork.SetEvent;
      Started:=GetTickCount64;
      while (ReaderPreparationsPending(Owner) or (Standalone and Owner.Visible) or
          (not Standalone and not Application.Terminated)) and (GetTickCount64-Started<5000) do
      begin Application.ProcessMessages; Sleep(1); end;
      Require(not ReaderPreparationsPending(Owner),'Cancelled extraction task remained active');
      Require((Standalone and not Owner.Visible) or (not Standalone and Application.Terminated),
        'Owner did not finish closing after extraction');
      Require(not Opened,'Cancelled extraction opened a book');
      Require((Length(TDirectory.GetFiles(CacheRoot,'*.pending-*',TSearchOption.soAllDirectories))=0) and
        (THashSHA2.GetHashStringFromFile(FileName)=Hash),'Cancellation left temporary bytes or changed the source');
    finally
      ReleaseWork.SetEvent;
      CancelReaderPreparations(Owner);
      BeforeReaderArchiveExtractForProfile:=nil;
      Host.Free;
      Application.ShowMainForm:=ShowMain;
      ReleaseWork.Free; Entered.Free;
    end;
  end;
  Writeln('PASS catalogue and standalone reader close during archive extraction and remove incomplete files');
end;

procedure TestReaderHostSession;
var Book: TBookRecord; Request: TReaderSessionRequest; Reply: TReaderSessionReply;
  Driver: TReaderHostSessionDriver; Host: TfrmReaderHost; Archive: TZipFile;
  Ini: TMemIniFile; Content, SettingsFile, SourceHash, NotesFile, NotesHash, HistoryKey: string;
  OldTemp, OldTmp, DiagnosticRoot: string; OldDark: Boolean;
  Note: TReaderAnnotation; Notes: TReaderAnnotations; Watch: TStopwatch; Probe: TStream;
begin
  RequireIsolatedRegression;
  Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Include(Book.BookProps,bpIsLocal);
  Book.BookKey:=CreateBookKey(4321,37); Book.CollectionRoot:=Settings.AppPath;
  Book.Folder:='reader-host-session.zip'; Book.FileName:='selected'; Book.FileExt:='.fb2';
  Book.InsideNo:=0; Book.LibID:='merged:37:98765'; Book.Title:='Выбранная в каталоге книга';
  Content:='<FictionBook><description><title-info><book-title>SELECTED SECOND</book-title></title-info>'+
    '</description><body><section>';
  for var I:=1 to 250 do Content:=Content+'<p>SELECTED SECOND '+IntToStr(I)+
    ' Книга из второй записи архива. Текст для проверки истории и перелистывания.</p>';
  Content:=Content+'</section></body></FictionBook>';
  Archive:=TZipFile.Create;
  try
    Archive.Open(Book.GetBookFileName,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes('<FictionBook><body><section><p>WRONG FIRST</p></section></body></FictionBook>'),
      'first.fb2',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes(Content),'selected.fb2',zcStored);
  finally Archive.Free; end;
  Book.Size:=TFile.GetSize(Book.GetBookFileName); SourceHash:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
  SettingsFile:=TPath.Combine(Settings.AppPath,'catalogue-reader\reader.ini');
  ForceDirectories(ExtractFileDir(SettingsFile));
  var SessionRoot:=Settings.AppPath+StringOfChar('ч',Max(10,220-Length(Settings.AppPath)));
  Request:=CreateReaderSession(SessionRoot,Book,'catalogue-history-unchanged',SettingsFile);
  Require(Length(Request.RequestFile)>MAX_PATH,'Reader session fixture did not use a long path');
  HistoryKey:=Copy(THashSHA2.GetHashString(Request.HistoryIdentity),1,40);
  Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
  try
    Ini.WriteInteger('Book.'+HistoryKey,'Position',1200);
    Ini.WriteInteger('Reader','Theme',4);
    Ini.WriteInteger('Reader','ThemeBackground1',RGB(244,231,215));
    Ini.WriteInteger('Reader','ThemeText1',RGB(64,35,18));
    Ini.WriteBool('Reader','AppThemeDark',not MHLThemeDark);
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  Note:=Default(TReaderAnnotation); Note.BookID:=HistoryKey; Note.BookTitle:=Book.Title;
  Note.Title:='Существующая заметка'; Note.Text:='Нельзя потерять'; Note.Position:=1200;
  Notes:=TReaderAnnotations.Create(SettingsFile);
  try Notes.Put(Note); finally Notes.Free; end;
  NotesFile:=TPath.Combine(ExtractFileDir(SettingsFile),'reader-notes.json');
  NotesHash:=THashSHA2.GetHashStringFromFile(NotesFile);
  OldTemp:=GetEnvironmentVariable('TEMP'); OldTmp:=GetEnvironmentVariable('TMP'); OldDark:=MHLThemeDark;
  DiagnosticRoot:=Settings.AppPath+'reader-diagnostic-temp'; ForceDirectories(DiagnosticRoot);
  SetEnvironmentVariable('TEMP',PChar(DiagnosticRoot)); SetEnvironmentVariable('TMP',PChar(DiagnosticRoot));
  LogDiagnosticMessage('reader-diagnostics-fixture','Owned reader-diagnostics-fixture');
  Host:=TfrmReaderHost.Create(nil); Driver:=TReaderHostSessionDriver.Create;
  try
    CheckReaderDiagnosticsMenu(Host);
    SetMHLTheme(not OldDark); CheckReaderDiagnosticsMenu(Host); SetMHLTheme(OldDark);
    Driver.Host:=Host; Driver.Request:=Request; Driver.Started:=GetTickCount64;
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=100; Driver.Timer.OnTimer:=Driver.Tick;
    Host.OpenInitialSession(Request.RequestFile); Host.Show; Watch:=TStopwatch.StartNew;
    repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(10);
    until (TryReadReaderSessionReply(Request,Reply) and ((Reply.State='closed') or (Reply.State='failed'))) or
      (Driver.Error<>'') or (Watch.ElapsedMilliseconds>25000);
    Require(Driver.Error='',Driver.Error);
    Require(Driver.Completed and (Reply.State='closed') and Reply.Opened and Reply.HasProgress and
      (Reply.Progress>0) and (Reply.ProcessID=GetCurrentProcessId),
      'Catalogue reader host did not return the selected book progress');
    Ini:=TMemIniFile.Create(SettingsFile,TEncoding.UTF8);
    try
      Require(Ini.ReadInteger('Book.'+HistoryKey,'Position',-1)=Driver.SavedPosition,
        'Catalogue reader host wrote a different history identity');
      Require((Ini.ReadInteger('Reader','ThemeBackground4',clDefault)=RGB(23,32,40)) and
        (Ini.ReadInteger('Reader','ThemeText4',clDefault)=RGB(236,234,222)) and
        (Ini.ReadInteger('Reader','ThemeBackground1',0)=clDefault) and
        (Ini.ReadInteger('Reader','ThemeText1',0)=clDefault), 'Palette overrides or reset were lost');
      Require(Ini.ReadInteger('Bookmarks.'+HistoryKey,'Count',0)=1,
        'Catalogue reader host lost its new bookmark');
    finally Ini.Free; end;
    Require(THashSHA2.GetHashStringFromFile(NotesFile)=NotesHash,'Catalogue reader host changed existing notes');
    Require(THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=SourceHash,'Catalogue reader host changed the source archive');
    Probe:=TFileStream.Create(Request.SourceFile,fmOpenReadWrite or fmShareDenyNone); Probe.Free;
    Writeln('PASS reader continuous text scroll preserves selection and the visible position');
    Writeln('PASS reader themes restore, apply and reset per-theme foreground and background');
    Writeln('PASS catalogue reader host opens the selected archive member with existing history notes bookmarks progress and source protection');
  finally
    Driver.Timer.Free; Driver.Free; Host.Free; SetMHLTheme(OldDark);
    SetEnvironmentVariable('TEMP',PChar(OldTemp)); SetEnvironmentVariable('TMP',PChar(OldTmp));
  end;
  Require(RemoveReaderSessionFiles(Request) and
    not DirectoryExists(BookOutputPath(ExtractFileDir(Request.RequestFile))),
    'Reader host left files at the long session path after close');
  Writeln('PASS long catalogue reader session opens the book, returns progress and removes its files');
end;
