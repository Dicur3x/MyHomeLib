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
  Request:=CreateReaderSession(Settings.AppPath,Book,'catalogue-history-unchanged',SettingsFile);
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
end;
