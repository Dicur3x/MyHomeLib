procedure FillFeedback19Note(const Quote, Thought: string);
  var Editor: TForm; Body: TMemo; Title: TEdit; QuoteBox: TMemo;
  begin
    Editor:=Screen.ActiveForm; Require(Editor.Caption='Заметка к книге','Actual note editor not opened');
    Body:=nil; Title:=nil; QuoteBox:=nil;
    for var C in Editor do
    begin
      if C is TEdit then Title:=TEdit(C);
      if C is TMemo then if TMemo(C).ReadOnly then QuoteBox:=TMemo(C) else Body:=TMemo(C);
    end;
    Require(Assigned(Body) and Assigned(Title) and Assigned(QuoteBox),'Note input controls absent');
    Require(string(QuoteBox.Text).Contains(Quote),'Toolbar/manager add discarded the visible selection');
    Title.Text:=''; Body.Text:=Thought; Editor.ModalResult:=mrOk;
  end;

// Actual reader form, native page geometry and modal note editor; no user profile.
procedure AuditReaderFeedback19;
var Reader: TfrmBuiltinReader; Store: TReaderAnnotations; Note, Draft: TReaderAnnotation;
  Notes: TArray<TReaderAnnotation>; Fixture, Source, Profile, Text, Quote, Snapshot, SourceHash: string;
  Ini: TMemIniFile; Position, X, Y, HitX, HitY: Integer; Button: TButton; LabelText: TLabel;


begin
  Source:=ExpandFileName('feedback19-note-book.fb2'); Profile:=ExpandFileName('feedback19-notes/reader.ini');
  ForceDirectories(ExtractFilePath(Profile));
  Fixture:='<FictionBook><description><title-info><book-title>Nested notes</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><title><p>Часть I</p></title><section><title><p>Младший и Энджи</p></title>'+
    '<section><title><p>3</p></title><p>Энджи вышла из душа. Цитата для новой мысли. Остальная часть этого абзаца.</p>'+
    '<p>Следующий абзац тоже входит в страницу и не должен теряться в закладке.</p>';
  for var I:=1 to 80 do Fixture:=Fixture+'<p>Продолжение '+IntToStr(I)+'. '+StringOfChar('Т',120)+'</p>';
  Fixture:=Fixture+'</section></section></section></body></FictionBook>';
  TFile.WriteAllText(Source,Fixture,TEncoding.UTF8); SourceHash:=THashSHA2.GetHashStringFromFile(Source);
  Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
  try Ini.WriteBool('Reader','NumberChapters',False); Ini.UpdateFile; finally Ini.Free; end;
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Reader.Show; Reader.OpenBook(Source,'Nested notes','feedback19-notes',Profile,'pdfium.dll'); WaitReady(Reader);
    Reader.SetShowFootnotes(False); Reader.GoToChapter(2); Application.ProcessMessages;
    Require(Reader.CurrentChapterPath='Часть I › Младший и Энджи › 3','Reader breadcrumb lost root or parent chapter');
    LabelText:=Reader.FindComponent('ReaderChapterPath') as TLabel;
    Require(Assigned(LabelText) and (LabelText.Caption=Reader.CurrentChapterPath),'Small visible breadcrumb differs from current chapter');
    Require(LabelText.Height>=20,'Chapter breadcrumb row is clipped');
    Snapshot:=Reader.PageText; Reader.AddBookmark; Require(Reader.PageHasBookmark,'Saved page lacks visible bookmark indicator');
    Require(Reader.BookmarkContext(0)=Snapshot,'New bookmark stores an excerpt instead of the whole page');
    Require(Snapshot.Contains('Следующий абзац'),'Fixture did not exercise multiple bookmark paragraphs');
    Reader.NextPage; Require(not Reader.PageHasBookmark,'Bookmark icon leaked to the next page'); Require(Reader.BookmarkContext(0)=Snapshot,'Saved page context changed after navigating'); Reader.GoToBookmark(0);
    Text:=Reader.BookText; Quote:='Цитата для новой мысли.'; Position:=Pos(Quote,Text)-1;
    Require(Position>=Reader.TextPosition,'Quote is outside the test page'); Reader.SelectText(Position,Length(Quote));
    Require(Reader.SelectedText=Quote,'Actual native text selection changed quote'); Draft:=Reader.AnnotationDraft(Quote);
    Require((Draft.RangeStart=Position) and (Draft.RangeEnd=Position+Length(Quote)) and not Draft.RangeIsPageText,'Text note range differs from selection');
    Button:=Reader.FindComponent('ReaderAddNote') as TButton; Require(Assigned(Button),'Direct toolbar add-note control missing');
    TThread.ForceQueue(nil,procedure begin FillFeedback19Note(Quote,'Первая мысль без заголовка.'); end); Button.OnClick(Button);
    Store:=TReaderAnnotations.Create(Profile);
    try
      Notes:=Store.Items; Require((Length(Notes)=1) and (Notes[0].Quote=Quote) and (Notes[0].Title=''),'Untitled selected note did not persist correctly');
      Require(ReaderAnnotationDisplayTitle(Notes[0])='—','Untitled note repeats its text as a heading'); Note:=Notes[0];
    finally Store.Free; end;
    Require(Reader.VisibleAnnotationCount=1,'Visible selected note has no annotation marker');
    HitX:=-1; HitY:=-1;
    for Y:=0 to Reader.ReadingSurface.ClientHeight div 6 do
    begin
      for X:=0 to Reader.ReadingSurface.ClientWidth div 6 do
        if Reader.AnnotationAtPoint(X*6,Y*6)>=0 then begin HitX:=X*6; HitY:=Y*6; Break; end;
      if HitX>=0 then Break;
    end;
    Require(HitX>=0,'Rendered quote marker cannot be hit with the mouse');
    Reader.ReadingSurface.Perform(WM_MOUSEMOVE,0,MakeLParam(HitX,HitY));
    Require(string(Reader.ReadingSurface.Hint).Contains(Note.Text),'Hover over quoted passage does not display the note');
    Draft:=Note; Draft.Text:=StringOfChar(WideChar('Т'),1199)+'😀'+StringOfChar(WideChar('Д'),200)+'Конец мысли.';
    Store:=TReaderAnnotations.Create(Profile);
    try Store.Put(Draft); finally Store.Free; end;
    Reader.ReloadAnnotations; Reader.GoToBookmark(0);
    Reader.ReadingSurface.Perform(WM_MOUSEMOVE,0,MakeLParam(HitX,HitY));
    Require(string(Reader.ReadingSurface.Hint).StartsWith(StringOfChar(WideChar('Т'),1199)+'…'),
      'Long note preview splits a UTF-16 surrogate pair or hides truncation');
    Require(string(Reader.ReadingSurface.Hint).Contains('открыть заметку целиком'),
      'Long note preview does not explain how to read the whole thought');
    Store:=TReaderAnnotations.Create(Profile);
    try
      Notes:=Store.Items; Require((Length(Notes)=1) and (Notes[0].Text=Draft.Text),
        'Short hover preview truncated the stored complete note');
      Store.Put(Note);
    finally Store.Free; end;
    Reader.ReloadAnnotations; Reader.GoToBookmark(0);
    Writeln('PASS long note hover explicitly previews without splitting emoji or changing the full stored thought');
    Reader.SelectText(Position,Length(Quote));
    TThread.ForceQueue(nil,
      procedure
      begin
        var Manager:=Screen.ActiveForm; Require(string(Manager.Caption).StartsWith('Закладки и заметки'),'Notes manager absent');
        var Add:=NoteDialogButton(Manager,'Добавить заметку…');
        TThread.ForceQueue(nil,procedure begin FillFeedback19Note(Quote,'Вторая мысль из окна заметок.'); end); Add.OnClick(Add);
        var BookExport:=Manager.FindComponent('ExportBookNotes') as TMenuItem;
        var AllExport:=Manager.FindComponent('ExportAllNotes') as TMenuItem;
        Require(Assigned(BookExport) and Assigned(AllExport) and
          (BookExport.Tag=0) and (AllExport.Tag=1) and
          BookExport.Caption.Contains('выбранной книги') and AllExport.Caption.Contains('всех книг'),
          'Selected-book/all-books export actions must have distinct scopes');
        Manager.ModalResult:=mrCancel;
      end);
    NoteDialogButton(Reader,'Заметки').OnClick(nil);
    Store:=TReaderAnnotations.Create(Profile);
    try Notes:=Store.Items; Require((Length(Notes)=2) and (Notes[1].Quote=Quote) and ReaderAnnotationHasRange(Notes[1]),'Manager add-note lost selected quote or its range'); finally Store.Free; end;
    Reader.NextPage; Require(Reader.VisibleAnnotationCount=0,'Annotation marker leaked onto an unrelated page');
    Reader.GoToBookmark(0); Require(Reader.VisibleAnnotationCount=2,'Returning to saved page lost both quote markers');
    for var Theme in [0,1,4,5] do
    begin Reader.SetTheme(Theme); Require(Reader.VisibleAnnotationCount=2,'Reflow/theme switch lost quote ranges'); end;
    Reader.Close;
  finally Reader.Free; end;
  Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Note interaction changed the source book');
  Writeln('PASS feedback19 reader breadcrumb shows root and subchapter without duplicate numbering');
  Writeln('PASS feedback19 toolbar and manager note actions retain selected quote, range and optional blank title');
  Writeln('PASS feedback19 visible quote markers show hover notes, survive themes and remain page-local');
  Writeln('PASS feedback19 page bookmarks retain all paragraphs after navigation and export scopes name their books');
end;
