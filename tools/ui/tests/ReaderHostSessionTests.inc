{$I ReaderDiagnosticsTests.inc}

type
  TFollowingComicProbe = class
    Host: TfrmReaderHost;
    Timer: TTimer;
    Stage, Scrolls, Offers: Integer;
    Deadline, ContinueAt: UInt64;
    Error: string;
    procedure Tick(Sender: TObject);
  end;

procedure TFollowingComicProbe.Tick(Sender: TObject);
var Reader: TfrmBuiltinReader; Dialog: TForm; Key: Word; Choice: TMenuItem;
begin
  Reader:=nil; Dialog:=nil;
  for var Component in Host do
    if Component is TfrmBuiltinReader then Reader:=TfrmBuiltinReader(Component);
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible and (Screen.Forms[I].Name='ReaderFollowingComicDialog') then
      Dialog:=Screen.Forms[I];
  try
    Require(GetTickCount64<Deadline,'Following-comic test timed out at stage '+IntToStr(Stage));
    if Assigned(Dialog) then
    begin
      Inc(Offers);
      Require(Stage in [2,4],'The reader offered another chapter without a forward action');
      var Expected:='Сага 010.zip';
      if Stage=4 then Expected:='Сага 011.cbz';
      var Found:=False;
      for var Component in Dialog do
        if (Component is TLabel) and string(TLabel(Component).Caption).Contains(Expected) then Found:=True;
      Require(Found,'The prompt did not name the next chapter: '+Expected);
      if Stage=2 then
      begin
        Require(Scrolls>=2,'The continuous reader offered the next chapter before scrolling the last page');
        Stage:=3; Dialog.ModalResult:=mrYes;
      end
      else
      begin
        Stage:=5; ContinueAt:=GetTickCount64+900; Dialog.ModalResult:=mrNo;
      end;
      Exit;
    end;
    if not Assigned(Reader) or not Reader.Ready or Reader.PageLoading then Exit;
    case Stage of
      0:
        begin
          Require(string(Reader.Caption).Contains('Сага 009'),'Wrong first chapter');
          Reader.SetPageLayout(rplSingle); Reader.NextPage; Stage:=1;
        end;
      1:
        if Reader.TextPosition=1 then
        begin Reader.SetPageLayout(rplContinuous); Stage:=2; ContinueAt:=GetTickCount64+100; end;
      2:
        if GetTickCount64>=ContinueAt then
        begin
          Require(Reader.PageRasterSize.Y>Reader.ReadingSurface.ClientHeight,
            'The final test page is not taller than the window');
          Key:=VK_NEXT; Reader.OnKeyDown(Reader,Key,[]);
          Inc(Scrolls); ContinueAt:=GetTickCount64+100;
        end;
      3:
        if string(Reader.Caption).Contains('Сага 010') then
        begin
          Require(Reader.TextPosition=0,'Next chapter did not start at its own position');
          Reader.SetPageLayout(rplSingle);
          Stage:=4;
        end;
      4: begin Reader.NextPage; Reader.NextPage; end;
      5:
        begin
          Reader.NextPage;
          if GetTickCount64<ContinueAt then Exit;
          Require(string(Reader.Caption).Contains('Сага 010') and (Offers=2),'Declining moved to another chapter');
          Choice:=Reader.Menu.FindComponent('ReaderOfferFollowingComic') as TMenuItem;
          Require(Assigned(Choice) and Choice.Checked,'Reader settings lack the chapter offer switch');
          Choice.Click;
          Require(not Choice.Checked,'Chapter offer preference did not turn off');
          Stage:=6; Reader.Close; Timer.Enabled:=False;
        end;
      7:
        begin
          Choice:=Reader.Menu.FindComponent('ReaderOfferFollowingComic') as TMenuItem;
          Require(Assigned(Choice) and not Choice.Checked,'The disabled preference was lost after reopening');
          Reader.SetPageLayout(rplSingle); Reader.NextPage;
          Stage:=8; ContinueAt:=GetTickCount64+850;
        end;
      8:
        if GetTickCount64>=ContinueAt then
        begin
          Require(string(Reader.Caption).Contains('Сага 010') and (Offers=2),'A disabled offer changed the current chapter');
          Stage:=9; Reader.Close; Timer.Enabled:=False;
        end;
    end;
  except
    on E: Exception do
    begin
      Error:=E.Message; Timer.Enabled:=False;
      if Assigned(Dialog) then Dialog.ModalResult:=mrNo else if Assigned(Reader) then Reader.Close;
    end;
  end;
end;

procedure TestFollowingComic;
var Folder, First, Second, Third, Other, Ambiguous, Compound: string; Bitmap: TBitmap;
  PNG: TPngImage; Pixels: TBytes; PageStream: TBytesStream;
  Probe: TFollowingComicProbe; Host: TfrmReaderHost; Ini: TMemIniFile; Hash: string;
  Book: TBookRecord;
  procedure Comic(const FileName: string; Pages: Integer);
  var Zip: TZipFile;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmWrite);
      for var I:=1 to Pages do Zip.Add(Pixels,IntToStr(I)+'.png',zcDeflate);
    finally Zip.Free; end;
  end;

  procedure Run(const FileName: string; Finish: Integer);
  begin
    Host:=TfrmReaderHost.Create(nil);
    try
      Probe.Host:=Host; Probe.Deadline:=GetTickCount64+25000;
      Probe.Timer.Enabled:=True; Host.Show; Host.OpenFile(FileName);
      repeat Application.ProcessMessages; CheckSynchronize(5); Sleep(5);
      until (Probe.Stage=Finish) or (Probe.Error<>'') or (GetTickCount64>=Probe.Deadline);
      Require((Probe.Stage=Finish) and (Probe.Error=''),Probe.Error+' at stage '+IntToStr(Probe.Stage));
    finally Probe.Timer.Enabled:=False; Host.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Folder:=TPath.Combine(Settings.AppPath,'comic-chapters');
  ForceDirectories(Folder);
  First:=TPath.Combine(Folder,'Сага 009.cbz'); Second:=TPath.Combine(Folder,'Сага 010.zip');
  Third:=TPath.Combine(Folder,'Сага 011.cbz'); Other:=TPath.Combine(Folder,'Другой комикс 010.cbz');
  Bitmap:=TBitmap.Create; PNG:=TPngImage.Create; PageStream:=TBytesStream.Create;
  try
    Bitmap.SetSize(360,2400); Bitmap.Canvas.Brush.Color:=clSilver;
    Bitmap.Canvas.FillRect(Rect(0,0,Bitmap.Width,Bitmap.Height));
    PNG.Assign(Bitmap); PNG.SaveToStream(PageStream);
    Pixels:=Copy(PageStream.Bytes,0,Integer(PageStream.Size));
  finally PageStream.Free; PNG.Free; Bitmap.Free; end;
  Comic(First,2); Comic(Second,1); Comic(Third,1); Comic(Other,1);
  var TextArchive:=TPath.Combine(Folder,'Сага 009-1.zip');
  var Zip:=TZipFile.Create;
  try
    Zip.Open(TextArchive,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('<html><body>Text</body></html>'),'book.html',zcDeflate);
  finally Zip.Free; end;
  Require(FindFollowingComicArchive(First)='','An ordinary ZIP was treated as a comic chapter');
  TFile.Delete(TextArchive);
  Ambiguous:=TPath.Combine(Folder,'Сага 10.cbz'); Comic(Ambiguous,1);
  Require(FindFollowingComicArchive(First)='','A chapter with two matching copies was selected arbitrarily');
  TFile.Delete(Ambiguous);
  Require(SameFileName(FindFollowingComicArchive(First),Second),'Chapter order ignored leading zeroes or unrelated files');
  Require(FindFollowingComicArchive(Third)='','Last chapter wrapped around or picked an unrelated archive');
  Compound:=TPath.Combine(Folder,'Saga-c16-86.zip'); Comic(Compound,1);
  var CompoundNext:=TPath.Combine(Folder,'Saga-c17-1.cbz'); Comic(CompoundNext,1);
  Require(SameFileName(FindFollowingComicArchive(Compound),CompoundNext),'Multi-part chapter order skipped the next group');
  Hash:=THashSHA2.GetHashStringFromFile(First);
  Probe:=TFollowingComicProbe.Create;
  try
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Enabled:=False;
    Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
    Run(First,6);
    Book:=FileBook(First);
    Ini:=TMemIniFile.Create(ResolveReaderSettingsFile(Settings.DataDir),TEncoding.UTF8);
    try
      Require(Ini.ReadInteger('Book.'+ReaderNoteIdentity(ReaderHistoryName(Book,'')),'Position',-1)=1,
        'Following the next chapter lost the previous reading position');
    finally Ini.Free; end;
    Probe.Stage:=7; Run(Second,9);
  finally Probe.Timer.Free; Probe.Free; end;
  Require(THashSHA2.GetHashStringFromFile(First)=Hash,'Following a chapter modified the original archive');
  Writeln('PASS standalone comic offers the next numbered archive at the end, saves position and honors decline and disable');
end;

type
  TReaderHostSessionDriver = class
    Host: TfrmReaderHost;
    Request: TReaderSessionRequest;
    Timer: TTimer;
    Started: UInt64;
    Error: string;
    Completed: Boolean;
    SavedPosition: Integer;
    RequestedRecent: Boolean;
    procedure Tick(Sender: TObject);
  end;

type
  TStandaloneNotesProbe = class
    Host: TfrmReaderHost;
    Timer: TTimer;
    Profile, PlainFile, ArchiveFile, Error: string;
    Stage: Integer;
    Deadline: UInt64;
    procedure Tick(Sender: TObject);
  end;

procedure TStandaloneNotesProbe.Tick(Sender: TObject);
var Picker, Dialog: TCustomForm; Reader: TfrmBuiltinReader; Books: TComboBox;
  NotesList: TListView; Store: TReaderAnnotations; Note: TReaderAnnotation;
  Recent: TListBox; Key: Word; Title: string; Item: TListItem;

  procedure OpenRecentMember(const Name: string; FromMenu: Boolean);
  begin
    if FromMenu then
    begin
      var Menu:=Host.Menu.FindComponent('ReaderRecentMenu') as TMenuItem;
      Require(Assigned(Menu),'Standalone reader has no recent menu');
      for var I:=0 to Menu.Count-1 do
        if string(Menu.Items[I].Caption).Contains(Name) then
        begin Menu.Items[I].Click; Exit; end;
    end
    else
    begin
      var List:=TListBox(Host.FindComponent('ReaderRecentBooks'));
      for var I:=0 to List.Count-1 do
        if List.Items[I].Contains(Name) then
        begin List.ItemIndex:=I; List.OnDblClick(List); Exit; end;
    end;
    Require(False,'The recently opened archive member is missing: '+Name);
  end;

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
    if (Stage>0) and (Stage<>15) then Require(not Assigned(Picker),'The reader asked for the archive entry again');
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
          Stage:=14; Reader.Close;
        end;
      14: if not Assigned(Reader) and Host.Visible then
        begin Stage:=15; Host.OpenFile(ArchiveFile); end;
      15: if Assigned(Picker) then
        for var Component in Picker do
          if Component is TListBox then
          begin
            var Choice:=TListBox(Component);
            Choice.ItemIndex:=Choice.Items.IndexOf('first.fb2');
            Require(Choice.ItemIndex>=0,'The archive picker omitted the first book');
            Stage:=16; Picker.ModalResult:=mrOk; Exit;
          end;
      16: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('WRONG FIRST'),'Could not open both members of the recent archive');
          Stage:=2; Reader.Close;
        end;
      2: if not Assigned(Reader) and Host.Visible then
        begin Stage:=11; OpenRecentMember('selected.fb2',False); end;
      11: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('TARGET SECOND') and (Reader.TextPosition=900),
            'Recent list opened the wrong member or position');
          Stage:=12; Reader.Close;
        end;
      12: if not Assigned(Reader) and Host.Visible then
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
        begin Stage:=17; OpenRecentMember('first.fb2',True); end;
      17: if Assigned(Reader) and Reader.Ready and not Reader.PageLoading then
        begin
          Require(Reader.BookText.Contains('WRONG FIRST') and (Reader.TextPosition=0),
            'Restarted recent menu selected the wrong archive member or history');
          Stage:=18; Reader.Close;
        end;
      18: if not Assigned(Reader) and Host.Visible then
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
var Probe: TStandaloneNotesProbe; Host, StaleHost: TfrmReaderHost; Ini: TMemIniFile;
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
    Probe.PlainFile:=TextFile; Probe.ArchiveFile:=ArchiveFile;
    Probe.Profile:=ResolveReaderSettingsFile(Settings.DataDir);
    Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
    try
      Ini.EraseSection('ReaderRecent'); Ini.WriteString('ReaderRecent','File0',TextFile);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
    StaleHost:=TfrmReaderHost.Create(nil);
    try
      Host:=TfrmReaderHost.Create(nil);
      try
        Probe.Host:=Host; Host.Show;
        Probe.Stage:=0; Host.OpenFile(ArchiveFile); WaitForStep(6);
      finally Probe.Timer.Enabled:=False; Host.Free; end;
    finally StaleHost.Free; end;
    Host:=TfrmReaderHost.Create(nil);
    try
      Probe.Host:=Host; Host.Show;
      Probe.Stage:=7; WaitForStep(10);
    finally Probe.Timer.Enabled:=False; Host.Free; end;
    Require(THashSHA2.GetHashStringFromFile(ArchiveFile)=SourceHash,'Standalone notes modified the source ZIP');
    Writeln('PASS standalone recent books and cross-book notes and bookmarks reopen the exact archive member');
    Writeln('PASS standalone history preserves two members of one archive and the saved position after reopening');
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
    var Recent:=View.Menu.FindComponent('ReaderRecentMenu') as TMenuItem;
    Require(Assigned(Recent) and (Recent.Caption='Недавние книги') and (Recent.Count=2) and
      (Recent.Items[0].Caption=Request.CatalogueRecent[0].Caption) and
      (Recent.Items[1].Caption=Request.CatalogueRecent[1].Caption) and
      (Recent.Items[0].Count=0) and (Recent.Items[1].Count=0),
      'The normal Reader menu mixed local history with catalogue books or added a submenu');
    Recent.Items[1].Click;
    RequestedRecent:=True; Completed:=True;
  except on E: Exception do begin Error:=E.Message; Timer.Enabled:=False; end; end;
  if Assigned(View) and not RequestedRecent then View.Close;
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
  var Recent: TArray<TReaderCatalogueRecent>;
  SetLength(Recent,2);
  Recent[0].Key:=CreateBookKey(123,37); Recent[0].Identity:=StringOfChar('a',40);
  Recent[0].Caption:='Одинаковое название — первая коллекция';
  Recent[1].Key:=CreateBookKey(123,38); Recent[1].Identity:=StringOfChar('b',40);
  Recent[1].Caption:='Одинаковое название — вторая коллекция';
  Request:=CreateReaderSession(SessionRoot,Book,'catalogue-history-unchanged',SettingsFile,False,'','',Recent);
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
  Ini:=TMemIniFile.Create(Settings.SettingsFileName,TEncoding.UTF8);
  try
    Ini.EraseSection('ReaderRecent');
    Ini.WriteString('ReaderRecent','File0',Settings.AppPath+'independent-recent.txt');
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  Host:=TfrmReaderHost.Create(nil); Driver:=TReaderHostSessionDriver.Create;
  try
    var RecentMenu:=Host.Menu.FindComponent('ReaderRecentMenu') as TMenuItem;
    Require(Assigned(RecentMenu) and (RecentMenu.Count=1) and
      string(RecentMenu.Items[0].Caption).EndsWith('independent-recent.txt'),
      'The separate Reader launcher did not show just its own recent file');
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
    Require((Reply.RequestedCatalogueRecent=2) and
      Request.CatalogueRecent[Reply.RequestedCatalogueRecent-1].Key.IsSameAs(CreateBookKey(123,38)),
      'Reader did not send the selected catalogue row back to its owner');
    Writeln('PASS catalogue recent menu requests the exact selected row while saving current progress');
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
