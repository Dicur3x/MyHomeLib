// Own G: fixtures only. Requires Require, frm_BuiltinReader,
// unit_ReaderAnnotations, unit_AtomicIniFile, System.JSON/IOUtils/Hash/Zip/
// NetEncoding/Diagnostics/IniFiles, Vcl.Forms/StdCtrls/ComCtrls/ExtCtrls,
// unit_MHLTheme.
procedure RNPCheckDialogLayout(Form: TCustomForm; Width, Height: Integer);
var PreviousTheme: Boolean;
begin
  PreviousTheme:=MHLThemeDark;
  try
    for var Dark in TArray<Boolean>.Create(False,True) do
    begin
      SetMHLTheme(Dark); ApplyMHLControlTheme(Form);
      for var DPI in TArray<Integer>.Create(96,144,192) do
      begin
        Form.ScaleForPPI(DPI); Form.ClientWidth:=MulDiv(Width,DPI,96); Form.ClientHeight:=MulDiv(Height,DPI,96);
        Application.ProcessMessages;
        for var I:=0 to Form.ComponentCount-1 do
          if Form.Components[I] is TButton then
          begin
            var Button:=TButton(Form.Components[I]);
            Require((Button.Left>=0) and (Button.Top>=0) and
              (Button.Left+Button.Width<=Button.Parent.ClientWidth) and
              (Button.Top+Button.Height<=Button.Parent.ClientHeight),
              'Notes action clipped at DPI '+IntToStr(DPI)+': '+Button.Name);
          end;
      end;
    end;
    Form.ScaleForPPI(96); Form.ClientWidth:=Width; Form.ClientHeight:=Height;
  finally SetMHLTheme(PreviousTheme); ApplyMHLControlTheme(Form); end;
end;

// Manual Computer Use entry point: the list remains open until Close/Esc,
// followed by a live conflicted editor. Only one setup callback triggers the
// initial conflict; no timer accepts, saves or closes either window.
procedure TestReaderNotesVisual(const Root: string);
var Work, Profile, ID: string; Store, External: TReaderAnnotations;
  Note, Latest: TReaderAnnotation; Dialog: TReaderSavedDialog;
begin
  Require(SameText(ExtractFileDrive(TPath.GetFullPath(Root)),'G:') and
    TPath.GetFullPath(Root).StartsWith('G:\HomeLibRu-proposals-2026-10-16\reader-notes',True),
    'Visual notes checks require the explicitly isolated G: fixture root');
  Work:=TPath.Combine(Root,'visual-'+TGUID.NewGuid.ToString); ForceDirectories(Work);
  Profile:=TPath.Combine(Work,'reader.ini'); Store:=TReaderAnnotations.Create(Profile);
  try
    Note:=Default(TReaderAnnotation); Note.BookID:='visual-book-a'; Note.BookTitle:='Лесная книга Ё';
    Note.Title:='Маяк — первая заметка'; Note.Text:='Точный собственный текст ё ї є ґ ў 😀';
    Note.Quote:='Цитата из собственной тестовой книги'; Note.Place:='Глава 1'; Note.Position:=10;
    ID:=Store.Put(Note); Store.Find(ID,Note);
    Latest:=Note; Latest.ID:=''; Latest.BookID:='visual-book-b'; Latest.BookTitle:='Другая книга';
    Latest.Title:='Скрытая запись'; Latest.Text:='Еж и отдельная мысль'; Store.Put(Latest);
    Writeln('PROFILE reader-notes-visual profile=',Profile); Flush(Output);
    Dialog:=TReaderSavedDialog.CreateProfile(nil,Profile);
    try Dialog.ShowModal; finally Dialog.Free; end;
    // Use a separate conflict fixture: the operator may freely delete/edit
    // every row in the first window without invalidating the second scenario.
    FreeAndNil(Store); Profile:=TPath.Combine(Work,'conflict\reader.ini');
    Store:=TReaderAnnotations.Create(Profile); Note:=Default(TReaderAnnotation);
    Note.BookID:='visual-conflict-book'; Note.BookTitle:='Книга для проверки конфликта';
    Note.Title:='Сравнить две версии'; Note.Text:='Исходная сохранённая версия';
    Note.Quote:='Своя тестовая цитата'; Note.Place:='Глава 2'; Note.Position:=20;
    ID:=Store.Put(Note); Store.Find(ID,Note);
    Writeln('PROFILE reader-notes-visual conflict_profile=',Profile); Flush(Output);
    External:=TReaderAnnotations.Create(Profile);
    try External.Find(ID,Latest); Latest.Text:='Сохранённая версия из другого окна. Не затирать.'; External.Put(Latest);
    finally External.Free; end;
    Note.Text:='Мой несохранённый черновик. Проверить копию текста и перечитывание.';
    TThread.ForceQueue(nil,
      procedure
      begin
        var Editor:=Screen.ActiveCustomForm;
        Require(Assigned(Editor) and (Editor.Name='ReaderNoteEditor'),'Own visual conflict editor missing');
        TButton(Editor.FindComponent('NoteEditorSave')).Click;
      end);
    EditAndSaveReaderNote(nil,Store,Note);
  finally Store.Free; end;
  Writeln('PASS reader-notes-visual closed_by_operator');
end;

type
  TRNPConfirm = class
  public
    Timer: TTimer;
    Started: UInt64;
    FixtureRoot, ExpectedScope: string;
    ExpectedCount: Integer;
    Confirmed: Boolean;
    procedure Tick(Sender: TObject);
  end;

function RNPConfirmationChildText(Window: HWND; Value: LPARAM): BOOL; stdcall;
var PID: DWORD; Buffer: array[0..8191] of Char; Count: Integer;
begin
  PID:=0; GetWindowThreadProcessId(Window,@PID);
  if PID=GetCurrentProcessId then
  begin
    Count:=GetWindowText(Window,Buffer,Length(Buffer));
    if Count>0 then TStrings(Pointer(Value)).Add(Copy(string(PChar(@Buffer[0])),1,Count));
  end;
  Result:=True;
end;

procedure TRNPConfirm.Tick(Sender: TObject);
var Window, Next, YesButton: HWND; PID: DWORD; ClassName: array[0..255] of Char; Parts: TStringList;
  function IsExpected(const Text: string): Boolean;
  begin
    Result:=Text.Contains(Format('Удалить только показанные записи? Записей: %d.',[ExpectedCount])) and
      Text.Contains('Область: '+ExpectedScope+'.') and
      Text.Contains('Скрытые поиском и другими фильтрами записи останутся.');
  end;
begin
  Require((ExpectedCount=2) and DirectoryExists(FixtureRoot) and
    TPath.GetFullPath(FixtureRoot).StartsWith('G:\HomeLibRu-proposals-2026-10-16\reader-notes\',True),
    'Automatic confirmation is restricted to this own notes fixture');
  Require(GetTickCount64-Started<5000,'Own notes fixture confirmation did not appear');
  // TaskDialog is not a Screen.Forms entry. Match the current process and the
  // complete fixture-specific message before accepting a native dialog.
  Window:=GetTopWindow(0);
  while Window<>0 do
  begin
    Next:=GetWindow(Window,GW_HWNDNEXT); PID:=0; GetWindowThreadProcessId(Window,@PID);
    if (PID=GetCurrentProcessId) and IsWindowVisible(Window) and
      (GetClassName(Window,ClassName,Length(ClassName))>0) and (string(PChar(@ClassName[0]))='#32770') then
    begin
      Parts:=TStringList.Create;
      try
        EnumChildWindows(Window,@RNPConfirmationChildText,LPARAM(Pointer(Parts)));
        if IsExpected(Parts.Text) then
        begin
          Timer.Enabled:=False; Confirmed:=True; YesButton:=GetDlgItem(Window,IDYES);
          if YesButton<>0 then PostMessage(YesButton,BM_CLICK,0,0)
          else PostMessage(Window,WM_USER+102,IDYES,0); // TDM_CLICK_BUTTON
          Exit;
        end;
      finally Parts.Free; end;
    end;
    Window:=Next;
  end;
  for var I:=0 to Screen.FormCount-1 do
  begin
    if not Screen.Forms[I].Visible or not Screen.Forms[I].HandleAllocated then Continue;
    PID:=0; GetWindowThreadProcessId(Screen.Forms[I].Handle,@PID);
    if PID<>GetCurrentProcessId then Continue;
    for var J:=0 to Screen.Forms[I].ComponentCount-1 do
      if (Screen.Forms[I].Components[J] is TLabel) and
        IsExpected(TLabel(Screen.Forms[I].Components[J]).Caption) then
      begin
        Timer.Enabled:=False; Confirmed:=True; Screen.Forms[I].ModalResult:=mrYes; Exit;
      end;
  end;
end;

procedure TestReaderNotesProposals(const Root: string);
var
  Work, Profile, NotesFile, Hash, OriginalID, OtherID, Output: string;
  Store, Stale, External: TReaderAnnotations;
  Note, Original, Draft, Found: TReaderAnnotation;
  Bytes: TBytes;
  Rejected: Boolean;
  Dialog: TReaderSavedDialog;
  Search: TEdit;
  Books: TComboBox;
  ShowNotes, ShowBookmarks: TCheckBox;
  List: TListView;
  Ini: TMemIniFile;
  Confirm: TRNPConfirm;
  Items: TArray<TReaderAnnotation>;
  IDs: TStringList;
  Watch: TStopwatch;
  OpenMS, FilterMS: Int64;

  function NewNote(const ID, BookID, BookTitle, Text: string): TReaderAnnotation;
  begin
    Result:=Default(TReaderAnnotation); Result.ID:=ID; Result.BookID:=BookID;
    Result.BookTitle:=BookTitle; Result.Title:='Заголовок '+ID; Result.Text:=Text;
    Result.Quote:='Цитата Україна'; Result.Place:='Страница 12'; Result.Position:=12;
    Result.Created:='2026-10-16T01:02:03Z';
  end;

  procedure WriteFixture(const FileName: string; const Notes: TArray<TReaderAnnotation>);
  var JSON, Row: TJSONObject; Rows: TJSONArray;
  begin
    JSON:=TJSONObject.Create;
    try
      JSON.AddPair('version',TJSONNumber.Create(1)); Rows:=TJSONArray.Create; JSON.AddPair('notes',Rows);
      for var Entry in Notes do
      begin
        Row:=TJSONObject.Create; Rows.AddElement(Row);
        Row.AddPair('id',Entry.ID); Row.AddPair('book',Entry.BookID); Row.AddPair('bookTitle',Entry.BookTitle);
        Row.AddPair('title',Entry.Title); Row.AddPair('text',Entry.Text); Row.AddPair('quote',Entry.Quote);
        Row.AddPair('place',Entry.Place); Row.AddPair('created',Entry.Created);
        Row.AddPair('position',TJSONNumber.Create(Entry.Position));
      end;
      TFile.WriteAllText(FileName,JSON.ToJSON,TEncoding.UTF8);
    finally JSON.Free; end;
  end;

  procedure ExpectVisible(const Expected: array of string);
  var Actual, Wanted: TStringList;
  begin
    Items:=Dialog.VisibleItems; Actual:=TStringList.Create; Wanted:=TStringList.Create;
    try
      Actual.Sorted:=True; Wanted.Sorted:=True;
      for var Entry in Items do Actual.Add(Entry.BookID+'/'+Entry.ID);
      for var Value in Expected do Wanted.Add(Value);
      Require(Actual.Text=Wanted.Text,'Notes filter returned unexpected identities: '+Actual.Text);
      Require(List.Items.Count=Length(Expected),'Virtual notes count disagrees with export snapshot');
    finally Wanted.Free; Actual.Free; end;
  end;

  procedure SelectBook(const Title: string);
  begin
    Books.ItemIndex:=Books.Items.IndexOf(Title); Require(Books.ItemIndex>=0,'Own fixture book missing');
    Books.OnChange(Books);
  end;

  procedure Bookmark(const BookID, BookTitle: string; Index: Integer; const Title, Quote: string);
  var Section, Suffix: string;
  begin
    Section:='Bookmarks.'+BookID; Suffix:=IntToStr(Index);
    Ini.WriteString('Book.'+BookID,'Title',BookTitle);
    Ini.WriteInteger(Section,'Count',Index+1); Ini.WriteString(Section,'Title'+Suffix,Title);
    Ini.WriteInteger(Section,'Position'+Suffix,100+Index); Ini.WriteInteger(Section,'EndPosition'+Suffix,180+Index);
    Ini.WriteString(Section,'PageQuote'+Suffix,TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(Quote)).Replace(#13,'').Replace(#10,''));
    Ini.WriteString(Section,'Created'+Suffix,'2026-10-16T01:02:03Z');
    Ini.WriteString(Section,'Place'+Suffix,'Глава '+Suffix); Ini.WriteBool(Section,'PageText'+Suffix,False);
  end;

begin
  Require(SameText(ExtractFileDrive(TPath.GetFullPath(Root)),'G:') and
    TPath.GetFullPath(Root).StartsWith('G:\HomeLibRu-proposals-2026-10-16\reader-notes',True),
    'Notes proposals tests require the explicitly isolated G: fixture root');
  Work:=TPath.Combine(Root,'native-'+TGUID.NewGuid.ToString); ForceDirectories(Work);
  Profile:=TPath.Combine(Work,'reader.ini'); NotesFile:=TPath.Combine(Work,'reader-notes.json');
  TFile.WriteAllText(Profile,'[Unrelated]'+sLineBreak+'Keep=Сохранено ё',TEncoding.UTF8);
  Store:=TReaderAnnotations.Create(Profile);
  try
    Original:=NewNote('','book-a','Книга Альфа','Начальная запись'); OriginalID:=Store.Put(Original);
    Require(Store.Find(OriginalID,Original),'New note could not be found by exact ID');
    Stale:=TReaderAnnotations.Create(Profile); External:=TReaderAnnotations.Create(Profile);
    try
      Note:=Original; Note.Text:='Чужая запись'; External.Put(Note); Hash:=THashSHA2.GetHashStringFromFile(NotesFile);
      Draft:=Original; Draft.Text:='  Черновик ё ї 😀'+sLineBreak+'Вторая строка  ';
      Rejected:=False; try Stale.Put(Draft); except on E: EReaderAnnotationConflict do Rejected:=True; end;
      Require(Rejected,'Parallel note save was not reported as a recoverable conflict');
      Require(THashSHA2.GetHashStringFromFile(NotesFile)=Hash,'Conflict overwrote another window revision');
      Require(Stale.Find(OriginalID,Found) and (Found.Text='Начальная запись'),'Conflict discarded the previous snapshot');
      Stale.Reload; Require(Stale.Find(OriginalID,Found) and (Found.Text='Чужая запись'),'Explicit reload did not refresh the snapshot');
      Bytes:=TFile.ReadAllBytes(NotesFile); TFile.WriteAllText(NotesFile,'{broken',TEncoding.UTF8);
      Rejected:=False; try Stale.Reload; except on E: Exception do Rejected:=True; end;
      Require(Rejected and Stale.Find(OriginalID,Found) and (Found.Text='Чужая запись'),'Failed reload lost the last good snapshot');
      TFile.WriteAllBytes(NotesFile,Bytes);
      Output:=TPath.Combine(Work,'Копия черновика Ё.txt'); SaveReaderAnnotationDraft(Draft,Output);
      Require(TFile.ReadAllText(Output,TEncoding.UTF8).Contains(Draft.Text),'Draft text copy lost Unicode/whitespace');
      Rejected:=False; try SaveReaderAnnotationDraft(Draft,NotesFile); except on E: Exception do Rejected:=True; end;
      Require(Rejected and (THashSHA2.GetHashStringFromFile(NotesFile)=Hash),'Draft export could replace the annotation store');
    finally External.Free; Stale.Free; end;
    Store.Reload; Store.Find(OriginalID,Original); Draft:=Original;
    TThread.ForceQueue(nil,
      procedure
      var Editor: TCustomForm; TextBox: TMemo; Save, ReloadButton: TButton; Foreign: TReaderAnnotations; Entry: TReaderAnnotation;
      begin
        Editor:=Screen.ActiveCustomForm; Require(Editor.Name='ReaderNoteEditor','Live note editor missing');
        TextBox:=Editor.FindComponent('NoteEditorText') as TMemo; TextBox.Text:='  Мой черновик Ё ї 😀'+sLineBreak+'Сохранить пробелы  ';
        Foreign:=TReaderAnnotations.Create(Profile);
        try Foreign.Find(OriginalID,Entry); Entry.Text:='Новая чужая версия'; Foreign.Put(Entry); finally Foreign.Free; end;
        Save:=Editor.FindComponent('NoteEditorSave') as TButton; Save.Click;
        Require(Editor.Visible and not Save.Enabled,'Conflict closed the editor or allowed a blind retry');
        Require(TextBox.Text.Contains('Мой черновик Ё ї 😀'),'Conflict lost the live draft');
        Require(TButton(Editor.FindComponent('NoteDraftCopy')).Visible,'Draft copy recovery action missing');
        ReloadButton:=Editor.FindComponent('NoteReload') as TButton; ReloadButton.Click;
        Require(TextBox.Text.Contains('Мой черновик Ё ї 😀'),'Explicit reload replaced the draft');
        Require(TMemo(Editor.FindComponent('NoteLatest')).Text.Contains('Новая чужая версия'),'Fresh version is not visible separately');
        Require(Save.Enabled and (Save.Caption='Сохранить новой заметкой'),'Changed note is not clearly saved as a new record');
        RNPCheckDialogLayout(Editor,650,720);
        Require(TextBox.Height>=48,'Conflict layout collapsed the live draft');
        // Another writer can race even after an explicit reload. A second
        // conflict must again preserve the draft and create only one copy.
        Foreign:=TReaderAnnotations.Create(Profile);
        try Foreign.Find(OriginalID,Entry); Entry.Text:='Ещё более новая чужая версия'; Foreign.Put(Entry); finally Foreign.Free; end;
        Save.Click; Require(not Save.Enabled and TextBox.Text.Contains('Мой черновик'),'Second conflict lost the draft or bypassed concurrency');
        ReloadButton.Click;
        Save.Click;
      end);
    Require(EditAndSaveReaderNote(nil,Store,Draft),'Recovered draft did not save from its live editor');
    Require((Draft.ID<>'') and (Draft.ID<>OriginalID),'Recovered draft reused the other window note ID');
    Require(Store.Find(OriginalID,Found) and (Found.Text='Ещё более новая чужая версия'),'Recovery overwrote another window note');
    Require(Store.Find(Draft.ID,Found) and Found.Text.StartsWith('  Мой черновик'),'Saved copy lost its exact draft text');
    Require(Length(Store.Items)=2,'Conflict recovery created an unexpected number of notes');
    OtherID:=Draft.ID;
    for var RemoveCurrent in TArray<Boolean>.Create(False,True) do
    begin
      Store.Find(OriginalID,Draft);
      TThread.ForceQueue(nil,
        procedure
        var Editor: TCustomForm; Foreign: TReaderAnnotations; Entry: TReaderAnnotation; Save: TButton;
        begin
          Editor:=Screen.ActiveCustomForm; TMemo(Editor.FindComponent('NoteEditorText')).Text:='Ещё один черновик';
          Foreign:=TReaderAnnotations.Create(Profile);
          try
            if RemoveCurrent then Foreign.Remove(OriginalID)
            else begin Foreign.Find(OtherID,Entry); Entry.Text:='Не затирать другую заметку'; Foreign.Put(Entry); end;
          finally Foreign.Free; end;
          Save:=Editor.FindComponent('NoteEditorSave') as TButton; Save.Click;
          Require(not Save.Enabled,'Parallel unrelated change/deletion was not detected');
          TButton(Editor.FindComponent('NoteReload')).Click;
          if RemoveCurrent then Require(Save.Caption='Сохранить новой заметкой','Deleted note was not recovered as a new record')
          else Require(Save.Caption='Сохранить','Unchanged current note unnecessarily requires replacement');
          Save.Click;
        end);
      Require(EditAndSaveReaderNote(nil,Store,Draft),'Unrelated/deleted-note recovery did not save');
      if RemoveCurrent then Require((Draft.ID<>OriginalID) and not Store.Find(OriginalID,Found),'Deleted original ID was reused')
      else Require(Draft.ID=OriginalID,'Unrelated changes replaced the current note identity');
      Require(Store.Find(OtherID,Found) and (Found.Text='Не затирать другую заметку'),'Recovery overwrote an unrelated note');
      Require(Length(Store.Items)=2,'Recovery duplicated or removed another record');
    end;
  finally Store.Free; end;
  Writeln('PASS reader-note-conflict typed_conflict reload_preserves_snapshot live_draft fresh_version new_id atomic_txt_copy');

  Profile:=TPath.Combine(Work,'filter\reader.ini'); NotesFile:=TPath.Combine(Work,'filter\reader-notes.json');
  ForceDirectories(ExtractFilePath(Profile));
  WriteFixture(NotesFile,TArray<TReaderAnnotation>.Create(
    NewNote('note-a','book-a','Книга Альфа','Маяк Ёж и Україна'),
    NewNote('note-b','book-b','Книга Бета','Скрытая запись Бета'),
    NewNote('note-c','book-a','Книга Альфа','Еж без точек'),
    NewNote('note-d','book-c','Книга Гамма','ALPHA [literal] ?')));
  Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try
    Ini.WriteString('Unrelated','Keep','Настройки не менять');
    Bookmark('book-a','Книга Альфа',0,'Маяк закладка','Цитата МАЯК');
    Bookmark('book-a','Книга Альфа',1,'Скрытая закладка Альфа','Точная скрытая цитата');
    Bookmark('book-b','Книга Бета',0,'Скрытая закладка Бета','Другая цитата');
    SaveMemIniFileAtomically(Ini);
  finally Ini.Free; end;
  Dialog:=TReaderSavedDialog.CreateProfile(nil,Profile);
  try
    Dialog.Show; Application.ProcessMessages;
    Search:=Dialog.FindComponent('NotesSearch') as TEdit; Books:=Dialog.FindComponent('NotesBooks') as TComboBox;
    ShowNotes:=Dialog.FindComponent('NotesShowNotes') as TCheckBox;
    ShowBookmarks:=Dialog.FindComponent('NotesShowBookmarks') as TCheckBox;
    List:=Dialog.FindComponent('NotesList') as TListView;
    Require(List.OwnerData,'Large notes list is not virtual');
    RNPCheckDialogLayout(Dialog,760,560);
    ExpectVisible(['book-a/note-a','book-b/note-b','book-a/note-c','book-c/note-d','book-a/0','book-a/1','book-b/0']);
    Search.Text:='маЯК'; ExpectVisible(['book-a/note-a','book-a/0']);
    Output:=ReaderAnnotationsText(Dialog.VisibleItems,False);
    TFile.WriteAllText(TPath.Combine(Work,'filtered-export.txt'),Output,TEncoding.UTF8);
    Require(Output.Contains('Маяк Ёж') and Output.Contains('Маяк закладка') and
      not Output.Contains('Скрытая запись') and not Output.Contains('Еж без точек'),'Visible export contains hidden records');
    TFile.WriteAllText(TPath.Combine(Work,'filtered-export.html'),ReaderAnnotationsText(Dialog.VisibleItems,True),TEncoding.UTF8);
    TFile.WriteAllBytes(TPath.Combine(Work,'filtered-export.docx'),ReaderAnnotationsDocx(Dialog.VisibleItems));
    Search.Text:='ЁЖ'; ExpectVisible(['book-a/note-a']);
    Search.Text:='ЕЖ'; ExpectVisible(['book-a/note-c']);
    Search.Text:='[literal] ?'; ExpectVisible(['book-c/note-d']);
    Search.Text:='note-a'; ExpectVisible([]); // IDs are not normalized/searched.
    Search.Text:='бЕта'; ExpectVisible(['book-b/note-b','book-b/0']);
    Search.Text:='маяк'; ShowNotes.Checked:=False; ExpectVisible(['book-a/0']);
    ShowNotes.Checked:=True; SelectBook('Книга Бета'); ExpectVisible([]);
    SelectBook('Книга Альфа'); ExpectVisible(['book-a/note-a','book-a/0']);
    Search.Text:=''; ExpectVisible(['book-a/note-a','book-a/note-c','book-a/0','book-a/1']);
    // Select a row that will be hidden, then delete while debounce is pending.
    List.Items[List.Items.Count-1].Selected:=True; Search.Text:='маяк';
    Confirm:=TRNPConfirm.Create; Confirm.Timer:=TTimer.Create(nil);
    try
      Confirm.FixtureRoot:=Work; Confirm.ExpectedCount:=2;
      Confirm.ExpectedScope:='книга «Книга Альфа»; поиск «маяк»';
      Confirm.Started:=GetTickCount64; Confirm.Timer.Interval:=10; Confirm.Timer.OnTimer:=Confirm.Tick;
      TButton(Dialog.FindComponent('NotesDeleteAll')).Click;
      Require(Confirm.Confirmed,'Filtered destructive action skipped its own-fixture confirmation');
    finally Confirm.Timer.Free; Confirm.Free; end;
    ExpectVisible([]); Search.Text:=''; ExpectVisible(['book-a/note-c','book-a/0']);
    SelectBook('Все книги'); ExpectVisible(['book-b/note-b','book-a/note-c','book-c/note-d','book-a/0','book-b/0']);
    Store:=TReaderAnnotations.Create(Profile);
    try
      Require(not Store.Find('note-a',Found),'Shown note was not deleted');
      Require(Store.Find('note-b',Found) and Store.Find('note-c',Found) and Store.Find('note-d',Found),'Filtered deletion removed a hidden note');
    finally Store.Free; end;
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try
      Require(Ini.ReadString('Unrelated','Keep','')='Настройки не менять','Filtered deletion changed unrelated reader settings');
      Require((Ini.ReadInteger('Bookmarks.book-a','Count',0)=1) and
        (Ini.ReadString('Bookmarks.book-a','Title0','')='Скрытая закладка Альфа') and
        (Ini.ReadInteger('Bookmarks.book-a','EndPosition0',0)=181) and
        (Ini.ReadInteger('Bookmarks.book-b','Count',0)=1),'Filtered bookmark deletion lost hidden fields/books');
    finally Ini.Free; end;
  finally Dialog.Free; end;
  Writeln('PASS reader-note-filter exact_visible_ids unicode_case distinct_e_yo book_kind_clear pending_search_delete filtered_exports');

  Profile:=TPath.Combine(Work,'large\reader.ini'); NotesFile:=TPath.Combine(Work,'large\reader-notes.json');
  ForceDirectories(ExtractFilePath(Profile)); SetLength(Items,10000);
  for var I:=0 to High(Items) do
    Items[I]:=NewNote('large-'+IntToStr(I),'book-'+IntToStr(I mod 100),
      'Большая книга '+IntToStr(I mod 100),'Обычная собственная запись '+IntToStr(I));
  Items[7777].Text:='Уникальная игла Ё — Україна 😀'; WriteFixture(NotesFile,Items); Items:=nil;
  Hash:=THashSHA2.GetHashStringFromFile(NotesFile); Watch:=TStopwatch.StartNew;
  Dialog:=TReaderSavedDialog.CreateProfile(nil,Profile);
  try
    Dialog.Show; Application.ProcessMessages; OpenMS:=Watch.ElapsedMilliseconds;
    Search:=Dialog.FindComponent('NotesSearch') as TEdit; List:=Dialog.FindComponent('NotesList') as TListView;
    Require(List.OwnerData and (List.Items.Count=10000),'Own 10K notes fixture is not completely represented');
    Watch:=TStopwatch.StartNew; Search.Text:='УНИКАЛЬНАЯ ИГЛА Ё'; Items:=Dialog.VisibleItems; FilterMS:=Watch.ElapsedMilliseconds;
    Require((Length(Items)=1) and (Items[0].ID='large-7777'),'Own 10K filter lost the exact matching identity');
    Require(FilterMS<1500,'Own 10K filter blocks the UI for 1.5 seconds');
    Require(THashSHA2.GetHashStringFromFile(NotesFile)=Hash,'Large list viewing/filtering modified notes');
    Writeln('PROFILE reader-notes-10k open_ms=',OpenMS,' filter_ms=',FilterMS,' records=10000 visible=1 source_unchanged=1');
  finally Dialog.Free; end;
  Writeln('PASS reader-notes-proposals');
end;
