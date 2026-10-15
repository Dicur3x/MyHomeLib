// New metadata predicates and cross-book notes. Isolated catalogs/profile only.
type
  TFeedback20NoteOpenProbe = class
    Timer: TTimer;
    Stage: Integer;
    Done: Boolean;
    procedure Tick(Sender: TObject);
  end;
procedure TFeedback20NoteOpenProbe.Tick(Sender: TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if Screen.Forms[I].Visible then
    begin
      if (Stage=0) and Assigned(Screen.Forms[I].FindComponent('NotesList')) then
      begin
        var Manager:=Screen.Forms[I]; var List:=TListView(Manager.FindComponent('NotesList'));
        Require(List.Items.Count=2,'Integrated global note manager lost its books');
        List.Items[0].Selected:=True; List.Items[0].Focused:=True; Stage:=1;
        for var Component in Manager do
          if (Component is TButton) and (TButton(Component).Caption='Открыть книгу') then
          begin TButton(Component).Click; Exit; end;
      end
      else if (Stage=1) and (Screen.Forms[I] is TfrmBuiltinReader) then
      begin
        var Reader:=TfrmBuiltinReader(Screen.Forms[I]); if not Reader.Ready then Continue;
        Require(Reader.BookText.Contains('Exact note book body'),'Global note command opened an unrelated book');
        Require(Reader.TextPosition=17,'Global note command lost its saved position');
        Reader.NextPage; Require(Reader.TextPosition>17,'Integrated note reader did not advance');
        Stage:=2; Done:=True; Timer.Enabled:=False; Reader.Close; Exit;
      end;
    end;
end;

function Feedback20HasAnnotation(Control: TWinControl; const Text: string): Boolean;
begin
  Result:=(Control is TMemo) and string(TMemo(Control).Text).Contains(Text);
  if Result then Exit;
  for var I:=0 to Control.ControlCount-1 do
    if (Control.Controls[I] is TWinControl) and Feedback20HasAnnotation(TWinControl(Control.Controls[I]),Text) then Exit(True);
end;

procedure TestFeedback20(const One, Two: IBookCollection; OneID, TwoID: Integer);
var A,B,C,Remapped: Integer; Book,Original,Found: TBookRecord;
  Criteria: TBookSearchCriteria; Iterator: IBookIterator;
  Profile,Zone,JSONHash: string; Store,Stale: TReaderAnnotations;
  Note,Other,Requested: TReaderAnnotation; Ini: TMemIniFile; DB: TSQLiteDatabase;
  IDs: TArray<Integer>; Before: TBytes; Stamp: TDateTime; Rejected,Opened: Boolean; OpenProbe: TFeedback20NoteOpenProbe; StartOpen: UInt64;
  function SearchCount: Integer;
  begin Iterator:=One.Search(Criteria,False); Result:=Iterator.RecordCount; end;
  procedure CheckIDs(Expected: Integer);
  begin
    IDs:=ReaderNoteBookIDs(SystemDB,Profile,OneID);
    Require((Length(IDs)=1) and (IDs[0]=Expected),'Notes filter chose the wrong catalog identity');
  end;
begin
  RequireIsolatedRegression;
  A:=AddBook(One,'Metadata twenty A','Metadata author','ru','','0.1');
  B:=AddBook(One,'Metadata twenty B','Metadata author','ru','','0.1');
  One.GetBookRecord(CreateBookKey(A,OneID),Book,True);
  Book.Translators:='Ёлкин Émile'; Book.City:='Санкт-Петербург'; Book.PubYear:=2015;
  Book.ISBN:='978-5-00000-001-X'; One.UpdateBook(Book); Original:=Book;
  One.GetBookRecord(CreateBookKey(B,OneID),Book,True);
  Book.Translators:='Другой переводчик'; Book.City:='Москва'; Book.PubYear:=1990;
  Book.ISBN:='9785000000028'; One.UpdateBook(Book);
  Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.CollapseMultiSeriesResults:=True;
  Criteria.Translators:='="елКИН éMILE"'; Require(SearchCount=1,'Unicode translator exact search failed');
  Criteria.City:='="санкт-петербург"'; Criteria.PubYear:='>= 2010 AND <= 2020';
  Criteria.ISBN:='="978 5 00000 001 x"'; Require(SearchCount=1,'Combined publication metadata search failed');
  Require(Iterator.Next(Book) and (Book.BookKey.BookID=A),'Metadata search returned an unrelated book');
  Criteria.ISBN:='9785000000028'; Require(SearchCount=0,'Metadata predicates were ORed across fields');
  Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.ISBN:='="978-5-00000-002-8"';
  Require(SearchCount=1,'Formatted ISBN did not match unformatted catalog ISBN');
  Criteria.ISBN:='="978-5-00000-001-X" OR ="978-5-00000-002-8"';
  Require(SearchCount=2,'Normalized ISBN broke advanced OR operator spacing');
  Criteria.ISBN:='123'' OR 1=1 --'; Require(SearchCount=0,'ISBN query escaped into SQL');
  Writeln('PASS feedback20 metadata predicates Unicode, year range, normalized ISBN and intersections');

  ShowPage(PAGE_SEARCH); frmMain.DoClearFilter(False);
  TMHLButtonedEdit(frmMain.FindComponent('edFTranslators')).Text:='="елкин Émile"';
  TMHLButtonedEdit(frmMain.FindComponent('edFCity')).Text:='Санкт-Петербург';
  TMHLButtonedEdit(frmMain.FindComponent('edFPubYear')).Text:='>=2010 AND <=2020';
  TMHLButtonedEdit(frmMain.FindComponent('edFISBN')).Text:='978500000001X';
  frmMain.cbPresetName.Text:='Сведения 20'; frmMain.SaveSearchPreset(nil);
  frmMain.DoClearFilter(False); frmMain.cbPresetName.Text:='Сведения 20'; frmMain.cbPresetNameSelect(nil);
  Require(TMHLButtonedEdit(frmMain.FindComponent('edFCity')).Text='Санкт-Петербург','City preset lost text');
  Require(TMHLButtonedEdit(frmMain.FindComponent('edFISBN')).Text='978500000001X','ISBN preset lost text');
  frmMain.DoApplyFilter(nil); ExpectTitles(frmMain.tvBooksSR,['Metadata twenty A']);
  Require(Assigned(frmMain.FindComponent('cbSearchWithNotes')),'Books with notes checkbox missing');
  Writeln('PASS feedback20 actual search fields and presets apply the complete metadata expression');

  Profile:=ResolveReaderSettingsFile(Settings.DataDir);
  Note:=Default(TReaderAnnotation); Note.BookID:=ReaderNoteIdentity(ReaderHistoryName(Original,''));
  Note.BookTitle:=Original.Title; Note.Text:='Первая мысль ё'; Note.Position:=17;
  Note.Created:='2026-10-15T05:18:02.888Z';
  Store:=TReaderAnnotations.Create(Profile);
  try Note.ID:=Store.Put(Note); finally Store.Free; end;
  // A legacy note is still resolved by title AND stable reader identity.
  Require(FindReaderNoteBook(SystemDB,Profile,Note,TwoID,Found) and
    Found.BookKey.IsSameAs(Original.BookKey),'Legacy note cannot resolve its actual book');
  CheckIDs(A); RegisterReaderNoteBook(Profile,Original,'');
  C:=AddBook(Two,Original.Title,'Unrelated author','ru','','0.1');
  Two.GetBookRecord(CreateBookKey(C,TwoID),Book,True); Book.LibID:='UNRELATED_NOTE_BOOK'; Two.UpdateBook(Book);
  Require(FindReaderNoteBook(SystemDB,Profile,Note,TwoID,Found) and
    Found.BookKey.IsSameAs(Original.BookKey),'Matching title selected a different collection book');
  // The saved positive ID is reused; the original title also changes.
  Remapped:=AddBook(One,'Renamed metadata twenty A','Metadata author','ru','','0.1');
  One.GetBookRecord(CreateBookKey(Remapped,OneID),Book,True);
  Book.LibID:=Original.LibID; Book.FileName:=Original.FileName; One.UpdateBook(Book);
  One.GetBookRecord(CreateBookKey(A,OneID),Book,True); Book.LibID:='REUSED_UNRELATED'; One.UpdateBook(Book);
  Require(FindReaderNoteBook(SystemDB,Profile,Note,OneID,Found) and
    (Found.BookKey.BookID=Remapped),'Reimported note opened a reused ID'); CheckIDs(Remapped);
  Criteria:=Default(TBookSearchCriteria); Criteria.DateIdx:=-1; Criteria.NotesOnly:=True; Criteria.NoteBookIDs:=IDs;
  Require(SearchCount=1,'Books with notes SQL filter returned wrong count');
  Criteria.NoteBookIDs:=nil; Require(SearchCount=0,'Empty notes filter returned the whole library');
  Writeln('PASS feedback20 note identities survive legacy lookup, same titles, reimport, rename and reused IDs');

  Other:=Note; Other.ID:=''; Other.BookID:='other-note-book'; Other.BookTitle:='Другая книга'; Other.Text:='Другая мысль';
  Store:=TReaderAnnotations.Create(Profile);
  try Other.ID:=Store.Put(Other); finally Store.Free; end;
  JSONHash:=THashSHA2.GetHashStringFromFile(TPath.Combine(ExtractFilePath(Profile),'reader-notes.json'));
  TThread.ForceQueue(nil,procedure
    var Manager: TForm; Books: TComboBox; List: TListView;
    begin
      Manager:=Screen.ActiveForm; Books:=TComboBox(Manager.FindComponent('NotesBooks'));
      List:=TListView(Manager.FindComponent('NotesList'));
      Require(Assigned(Books) and (Books.Items.Count=3) and (Books.ItemIndex=0),'Global manager did not list all note books');
      Require((List.Items.Count=2) and (List.Columns.Count=5),'Global manager does not show two books and dates');
      Require(TMenuItem(Manager.FindComponent('ExportAllNotes')).Caption.StartsWith('Экспорт закладок и заметок всех книг'),
        'All-books export scope is ambiguous');
      Require(List.Items[0].SubItems[3].Contains('(UTC'),'Note list omits local timezone');
      List.Items[0].Selected:=True; List.Items[0].Focused:=True;
      for var Component in Manager do
        if (Component is TButton) and (TButton(Component).Caption='Открыть книгу') then
          TButton(Component).OnClick(Component);
    end);
  Opened:=BrowseReaderNotes(frmMain,Profile,Requested);
  Require(Opened and (Requested.ID=Note.ID) and (Requested.Position=17),'Global manager lost requested note/book position');
  Require(THashSHA2.GetHashStringFromFile(TPath.Combine(ExtractFilePath(Profile),'reader-notes.json'))=JSONHash,'Viewing notes rewrote stored notes');
  Writeln('PASS feedback20 global notes manager lists books and local dates and opens the selected exact note');
  One.GetBookRecord(CreateBookKey(Remapped,OneID),Found,True);
  var SourcePath:=Found.GetBookFileName;
  Require(TPath.GetFullPath(SourcePath).StartsWith(TPath.GetFullPath(Settings.AppPath),True),'Integrated note fixture outside isolated runtime');
  ForceDirectories(ExtractFilePath(SourcePath));
  TFile.WriteAllText(SourcePath,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Exact note</book-title></title-info></description><body><section><p>Exact note book body '+StringOfChar('x',30000)+'</p></section></body></FictionBook>',TEncoding.UTF8);
  ShowPage(PAGE_FAVORITES);
  OpenProbe:=TFeedback20NoteOpenProbe.Create; OpenProbe.Timer:=TTimer.Create(nil);
  OpenProbe.Timer.Interval:=10; OpenProbe.Timer.OnTimer:=OpenProbe.Tick;
  try
    TAction(frmMain.FindComponent('acAllReaderNotes')).Execute;
    StartOpen:=GetTickCount64;
    while not OpenProbe.Done and (GetTickCount64-StartOpen<15000) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(OpenProbe.Done,'Global notes Main action did not open its resolved reader');
    Application.ProcessMessages;
    One.GetBookRecord(CreateBookKey(Remapped,OneID),Found,False);
    Require(Found.Progress>0,'Opening a note while Groups is active incorrectly required an unrelated saved group row');
  finally OpenProbe.Timer.Free; OpenProbe.Free; ShowPage(PAGE_SEARCH); end;
  Writeln('PASS feedback20 actual Main note command opens exact book and position and saves catalog progress independently of active Groups');


  Zone:=ReaderAnnotationLocalTime(Note.Created); Require(TryISO8601ToDate(Note.Created,Stamp,True),'Bad timestamp fixture');
  Require(Zone.StartsWith(FormatDateTime('dd.mm.yyyy hh:nn',TTimeZone.Local.ToLocalTime(Stamp))) and
    Zone.Contains('(UTC') and not Zone.Contains('T05:18'),'Local note time/zone formatting failed');
  if SameText(TTimeZone.Local.ID,'Russian Standard Time') then
    Require(Zone='15.10.2026 08:18 · Москва (UTC+03:00)','Moscow note timestamp is not readable');
  Require(ReaderAnnotationLocalTime('legacy unknown')='legacy unknown','Unknown old timestamp was destroyed');
  Store:=TReaderAnnotations.Create(Profile); Stale:=TReaderAnnotations.Create(Profile);
  try
    for var HTML in [False,True] do
    begin
      var Exported:=ReaderAnnotationsText(Store.Items,HTML);
      Require(Exported.Contains(Zone) and not Exported.Contains(Note.Created),'Export exposed raw UTC instead of user zone');
    end;
    Store.RemoveAll(Note.BookID); Require((Length(Store.Items)=1) and (Store.Items[0].ID=Other.ID),
      'Delete selected book erased a different book');
    Rejected:=False; try Stale.RemoveAll; except on E: Exception do Rejected:=True; end;
    Require(Rejected and (Length(Stale.Items)=2),'Stale bulk delete was accepted or lost its in-memory recovery state');
    Store.RemoveAll; Require(Length(Store.Items)=0,'Delete all notes left notes behind');
  finally Stale.Free; Store.Free; end;
  Store:=TReaderAnnotations.Create(Profile); try Require(Length(Store.Items)=0,'Bulk deletion did not persist'); finally Store.Free; end;
  Writeln('PASS feedback20 local export timestamps, scoped/all deletion, stale-writer rejection and atomic reopen');
  var AnnotationID:=AddBook(One,'catalog-only-annotation-missing','Описание','ru','Проверка описания','prose_contemporary');
  One.SetAnnotation(CreateBookKey(AnnotationID,OneID),'Каталожное описание — ё, ї, ў. Исходный файл недоступен.');
  var WasInfo:=Settings.ShowInfoPanel; var WasCover:=Settings.ShowBookCover;
  var WasAnnotation:=Settings.ShowBookAnnotation; var WasPriority:=Settings.Fb2InfoPriority;
  try
    Settings.ShowInfoPanel:=True; Settings.ShowBookCover:=False;
    Settings.ShowBookAnnotation:=True; Settings.Fb2InfoPriority:=False;
    ShowPage(PAGE_SEARCH);
    var Key:=CreateBookKey(AnnotationID,OneID);
    frmMain.FillBooksTree(frmMain.tvBooksSR,nil,One.GetBookIterator(bmAll,False),False,False,@Key);
    var Row:=PBookRecord(frmMain.tvBooksSR.GetNodeData(frmMain.tvBooksSR.GetFirstSelected));
    Require(Assigned(Row),'Catalog annotation test lost selected book');
    Row.Annotation:=''; // A lean list row must resolve its catalog description in the worker.
    frmMain.tvBooksTreeChange(frmMain.tvBooksSR,frmMain.tvBooksSR.GetFirstSelected);
    var Deadline:=GetTickCount64+5000;
    while not Feedback20HasAnnotation(frmMain.ipnlSearch,'Каталожное описание — ё, ї, ў.') and (GetTickCount64<Deadline) do
    begin Application.ProcessMessages; CheckSynchronize(5); end;
    Require(Feedback20HasAnnotation(frmMain.ipnlSearch,'Каталожное описание — ё, ї, ў.'),
      'Actual information card did not show catalog annotation without an available source file');
    One.GetBookRecord(Key,Found,True);
    Require(Found.Annotation='Каталожное описание — ё, ї, ў. Исходный файл недоступен.',
      'Read-only card preview changed stored annotation');
    Writeln('PASS feedback20 actual information card shows catalog annotation from a lean row without source files or writes');
  finally
    Settings.ShowInfoPanel:=WasInfo; Settings.ShowBookCover:=WasCover;
    Settings.ShowBookAnnotation:=WasAnnotation; Settings.Fb2InfoPriority:=WasPriority;
  end;
end;
