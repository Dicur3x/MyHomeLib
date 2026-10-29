// Portable favorites, reader records and font/DPI layout; isolated profile only.
procedure FillFeedback21Note(const Quote, Thought: string);
var Editor: TForm; Body, QuoteBox: TMemo; Title: TEdit;
begin
  Editor:=Screen.ActiveForm; Body:=nil; QuoteBox:=nil; Title:=nil;
  Require(Editor.Caption='Заметка к книге','Actual note editor missing');
  for var Component in Editor do
  begin
    if Component is TEdit then Title:=TEdit(Component);
    if Component is TMemo then
      if TMemo(Component).ReadOnly then QuoteBox:=TMemo(Component) else Body:=TMemo(Component);
  end;
  Require(Assigned(Body) and Assigned(QuoteBox) and Assigned(Title),'Note controls missing');
  Require(string(QuoteBox.Text).Replace(#13,'').Trim=('Цитата: '+Quote).Replace(#13,'').Trim,'Unselected note did not capture all visible page text');
  Body.Text:=Thought; Title.Text:=''; Editor.ModalResult:=mrOk;
end;

procedure TestFeedback21ForumExamples;
var Book, Found: TBookRecord; Stream: TStream; Document: IXMLFictionBook; Cover: TGraphic;
  Worker: TCollectionWorker; Collection: IBookCollection; Iterator: IBookIterator;
  ID, Count: Integer; Folder, Expected, Hash: string; Started: UInt64; Criteria: TBookSearchCriteria;
begin
  Folder:=Settings.AppPath+'metadata-archive-fixtures\';
  Require(FileExists(Folder+'forum-327650.zip'),'Real PPMd forum fixture missing');
  Hash:=THashSHA2.GetHashStringFromFile(Folder+'forum-327650.zip');
  Book:=Default(TBookRecord); Book.CollectionRoot:=Folder; Book.Folder:='forum-327650.zip';
  Book.FileName:='327650'; Book.FileExt:='.fb2'; Book.Title:='Леопард'; Book.InsideNo:=-1;
  Stream:=Book.GetBookDescriptorStream(False);
  try
    Document:=LoadFB2Description(Stream);
    Require(Document.Description.Titleinfo.Booktitle.Text='Леопард','Real forum example read an unrelated book');
    Require(Length(GetBookAnnotation(Document))>300,'Real forum annotation was lost');
    Cover:=GetBookCover(Document);
    try Require(Assigned(Cover) and (Cover.Width>0),'Real forum cover was lost'); finally Cover.Free; end;
  finally Document:=nil; Stream.Free; end;
  Require(Hash=THashSHA2.GetHashStringFromFile(Folder+'forum-327650.zip'),'Preview changed its PPMd source');
  Writeln('PASS feedback21 real forum Leopard 327650 PPMd description, annotation and cover; source unchanged');
  for var IsMetabib in [False,True] do
  begin
    Expected:='.inpx'; if IsMetabib then Expected:='.jsonl';
    ID:=SystemDB.CreateCollection('Independent series '+Expected,Folder,'forum-series'+Expected+'.hlc2',
      CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
    if IsMetabib then Worker:=TImportMetabibThread.Create(ID,Folder+'forum-series.jsonl',gtFb2)
    else Worker:=TImportInpxThread.Create(ID,Folder+'forum-series.inpx',gtFb2);
    Started:=GetTickCount64;
    try
      Worker.Start;
      while not Worker.Finished do
      begin CheckSynchronize(10); Require(GetTickCount64-Started<20000,'Small series import did not finish'); end;
      Worker.WaitFor;
      Require(not Assigned(Worker.FatalException),'Actual series import failed');
    finally Worker.Free; end;
    Collection:=SystemDB.GetCollection(ID); Iterator:=Collection.GetBookIterator(bmAll,False); Count:=0;
    while Iterator.Next(Found) do
    begin
      Inc(Count); if Found.Title='Язык костей' then Expected:='Джейн и Стили'
      else if Found.Title='Истина под кожей' then Expected:='Джейн и Стили' else Expected:='Харри Холе';
      Require(Found.Series=Expected,'Import mixed series across authors or deletion flags: '+Found.Title);
    end;
    Require(Count=5,'Series fixture lost books'); Iterator:=nil;
    for var Collapse in [False,True] do
    begin
      Criteria:=Default(TBookSearchCriteria); Criteria.Series:='Джейн и Стили';
      Criteria.CollapseMultiSeriesResults:=Collapse; Iterator:=Collection.Search(Criteria,False); Count:=0;
      while Iterator.Next(Found) do
      begin Inc(Count); Require(Found.Series='Джейн и Стили','Series search mislabeled its records');
        Require((Found.Title='Язык костей') or (Found.Title='Истина под кожей'),'Series search included unrelated/deleted Nesbo books'); end;
      Require(Count=2,'Series search returned the wrong count'); Iterator:=nil;
    end;
    Collection:=nil;
  end;
  Writeln('PASS feedback21 independent INPX and JSONL series stay separate across authors/deleted books and compact/expanded searches');
end;

procedure TestFeedback21ArchivedFBD;
var Host: TForm; Panel: TInfoPanel; Preview: TBookInfoPreview; Book, Selected: TBookRecord;
  Stream: TStream; Document: IXMLFictionBook; Graphic: TGraphic; BeforeHash: string; Deadline: UInt64;
  AnnotationFound, CoverFound: Boolean;
  procedure Inspect(Control: TWinControl);
  begin
    for var I:=0 to Control.ControlCount-1 do
    begin
      if Control.Controls[I] is TMemo then
        AnnotationFound:=AnnotationFound or string(TMemo(Control.Controls[I]).Text).Contains('Описание из FBD — ё, ї, ў.');
      if Control.Controls[I] is TImage then
      begin
        var Image:=TImage(Control.Controls[I]);
        CoverFound:=CoverFound or (Assigned(Image.Picture.Graphic) and (Image.Picture.Width=8) and (Image.Picture.Height=12));
      end;
      if Control.Controls[I] is TWinControl then Inspect(TWinControl(Control.Controls[I]));
    end;
  end;
begin
  for var Name in ['preview-paired-ppmd.zip','preview-paired-solid.7z','preview-single-fbd.zip'] do
  begin
    Book:=Default(TBookRecord); Book.CollectionRoot:=Settings.AppPath+'metadata-archive-fixtures\';
    Book.Folder:=Name; Book.FileName:='чтение/Книга [1]'; Book.FileExt:='.pdf'; Book.Title:='Нужная книга'; Book.InsideNo:=-1;
    if Name='preview-single-fbd.zip' then begin Book.Folder:=''; Book.FileName:=Name; end;
    BeforeHash:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
    Stream:=Book.GetBookDescriptorStream(False);
    try
      Require(Assigned(Stream),'Archived FBD description stream missing'); Document:=LoadFB2Description(Stream);
      Require(Document.Description.Titleinfo.Booktitle.Text='Нужная книга','FBD descriptor was borrowed from a namesake in another directory');
      Require(GetBookAnnotation(Document).Contains('Описание из FBD'),'Archived FBD annotation did not decode');
      Graphic:=GetBookCover(Document);
      try Require(Assigned(Graphic) and (Graphic.Width=8) and (Graphic.Height=12),'Archived FBD base64 cover did not decode by signature'); finally Graphic.Free; end;
    finally Document:=nil; Stream.Free; end;
    Host:=TForm.CreateNew(nil); Panel:=TInfoPanel.Create(Host); Panel.Parent:=Host; Panel.Align:=alClient;
    Host.SetBounds(80,100,850,450); Host.Show; Preview:=TBookInfoPreview.CreateFor(Host,Panel);
    try
      Selected:=Book;
      Panel.Gallery.SetBook(Name,'.pdf',function: TStream begin Result:=OpenBookImageSource(Selected); end);
      Require(not Panel.Gallery.Visible,'PDF without proved descriptor offered unsupported image parsing');
      Preview.Load(Book,True,True,True); Deadline:=GetTickCount64+15000;
      while Preview.Busy and (GetTickCount64<Deadline) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
      Require(not Preview.Busy,'FBD preview worker did not finish'); AnnotationFound:=False; CoverFound:=False; Inspect(Panel);
      Require(AnnotationFound and CoverFound,'FBD data did not reach actual card controls: '+Panel.PreviewStatusText);
      Require(Panel.Gallery.Visible,'FBD image gallery remained hidden because main book is PDF');
      Panel.Gallery.Expanded:=True; Deadline:=GetTickCount64+15000;
      while Panel.Gallery.Loading and (GetTickCount64<Deadline) do begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
      Require(not Panel.Gallery.Loading and (Panel.Gallery.ImageCount=2),'FBD gallery did not decode its cover and illustration or isolate broken binary');
    finally Preview.Free; Host.Free; end;
    Require(THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=BeforeHash,'FBD preview changed original archive');
    Writeln('PASS feedback21 archived FBD card/cover/gallery ',Name,' exact descriptor, Unicode, base64/signature decode, damaged-image isolation and unchanged source');
  end;
end;

procedure TestFeedback21OfficialOffice;
var Input, Job, Partial: string; Failed: Boolean;
begin
  Input:=Settings.AppPath+'metadata-archive-fixtures\';
  Job:=Settings.AppPath+'feedback21-official-office'; ForceDirectories(Job);
  PrepareOfficialComponent(Input+'docsharp.binary.doc.0.21.0.nupkg',Job,'DocSharp','0.21.0',
    ProgramUpdatePlatform,Input+'docsharp.binary.common.0.21.0.nupkg',Settings.AppPath,
    TArray<string>.Create(Input+'docsharp.binary.ppt.0.21.0.nupkg',Input+'docsharp.binary.xls.0.21.0.nupkg'));
  VerifyPreparedProgramUpdate(Job,'0.21.0',ProgramUpdatePlatform);
  for var Name in ['DocSharp.Binary.Doc.dll','DocSharp.Binary.Common.dll','DocSharp.Binary.Ppt.dll','DocSharp.Binary.Xls.dll','HomeLibDoc.exe'] do
    Require(UpdateSHA256(Job+'\payload\tools\doc\'+Name)=UpdateSHA256(Settings.AppPath+'tools\doc\'+Name),
      'Official four-package Office preparation changed or omitted '+Name);
  Partial:=Settings.AppPath+'feedback21-partial-office'; ForceDirectories(Partial); Failed:=False;
  try
    PrepareOfficialComponent(Input+'docsharp.binary.doc.0.21.0.nupkg',Partial,'DocSharp','0.21.0',
      ProgramUpdatePlatform,Input+'docsharp.binary.common.0.21.0.nupkg',Settings.AppPath);
  except on E: Exception do Failed:=E.Message.Contains('четыре'); end;
  Require(Failed and not FileExists(Partial+'\'+UPDATE_MANIFEST),'Incomplete Office update was published');
  Writeln('PASS feedback21 actual official four-package Office update prepares all assemblies, probes retained helper and rejects partial upgrades');
end;

procedure TestFeedback21;
var Data, Loaded: TUserData; First, Second: TAuthorFavorites; Folder, FileName, Hash, Profile, Source, Snapshot: string;
  Reader: TfrmBuiltinReader; Ini: TMemIniFile; Draft: TReaderAnnotation; Button, AddButton, SavedButton: TButton;
  ReleaseInfo: TProgramRelease; Stages: TStringList; Prepared, Warm: string;
  Update: TfrmProgramUpdate; Version, BytesLabel: TLabel; Progress: TProgressBar;
  Height, Buttons: Integer;
  procedure WaitReady(Reader: TfrmBuiltinReader);
  var Started: UInt64;
  begin
    Started:=GetTickCount64;
    while (not Reader.LoadFinished or Reader.PageLoading) and (GetTickCount64-Started<15000) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
    Require(Reader.Ready and not Reader.PageLoading,'Reader did not finish: '+Reader.ReaderStatus.Caption);
  end;

begin
  if ParamStr(2)='visual' then SetMHLTheme(True);
  Require(ParseOfficeDocSharpVersions('{"versions":["0.21.0","0.22.0","0.23.0"]}',
    '{"versions":["0.21.0","0.22.0","0.23.0"]}','{"versions":["0.21.0","0.22.0"]}',
    '{"versions":["0.21.0","0.23.0"]}',ReleaseInfo) and (ReleaseInfo.ComponentVersion='0.21.0') and
    (Length(ReleaseInfo.AdditionalURLs)=2),'Office update did not require a stable version shared by all four libraries');
  Stages:=TStringList.Create;
  try
    for var Extension in ['.pptx','.xlsx','.odp','.ods'] do
    begin
      Source:=Settings.AppPath+'metadata-archive-fixtures\portable-reader'+Extension;
      Require(FileExists(Source),'Portable office fixture missing');
      Hash:=THashSHA2.GetHashStringFromFile(Source); Stages.Clear;
      Prepared:=PrepareOfficeReaderFile(Source,Source,procedure(Stage: string) begin Stages.Add(Stage); end);
      Require(SameText(ExtractFileExt(Prepared),'.epub'),'Portable office reader did not prepare a reading EPUB');
      var OutputHash:=THashSHA2.GetHashStringFromFile(Prepared);
      var Document:=TReaderDocument.Create;
      try Document.Load(Prepared); Require(Document.PlainText.Contains('Последнее предложение.'),'Portable office preparation lost final text'); finally Document.Free; end;
      var ProtectedResult:=TFileStream.Create(Prepared,fmOpenRead or fmShareDenyWrite);
      try
        Stages.Clear; Warm:=PrepareOfficeReaderFile(Source,Source,procedure(Stage: string) begin Stages.Add(Stage); end);
        Require(SameFileName(Prepared,Warm) and (THashSHA2.GetHashStringFromFile(Warm)=OutputHash) and
          (Stages.Count=1) and Stages[0].Contains('из кэша'),'Portable office warm open ran conversion or rewrote protected result');
      finally ProtectedResult.Free; end;
      Require(THashSHA2.GetHashStringFromFile(Source)=Hash,'Portable office reader changed original');
    end;
  finally Stages.Free; end;
  Writeln('PASS feedback21 portable PPTX/XLSX/ODP/ODS reader, complete text, protected warm cache and coherent four-library updates');
  TestFeedback21ForumExamples;
  TestFeedback21ArchivedFBD;
  TestFeedback21OfficialOffice;
  Folder:=TPath.Combine(Settings.AppPath,'feedback21'); ForceDirectories(Folder);
  FileName:=TPath.Combine(Folder,'favorites.cxml2');
  First:=TAuthorFavorites.Create(TPath.Combine(Folder,'first.sqlite'));
  Second:=TAuthorFavorites.Create(TPath.Combine(Folder,'second.sqlite'));
  Data:=TUserData.Create; Loaded:=TUserData.Create;
  try
    First.SetFavorite('Достоевский','Фёдор','Михайлович',True);
    First.SetFavorite('O’Henry','','',True);
    Second.SetFavorite('Купала','Янка','',True);
    Hash:=THashSHA2.GetHashStringFromFile(First.FileName);
    Data.FavoriteAuthors:=First.Entries;
    Data.Extras.AddExtra(17,'lib-17',4,35,'Моя рецензия');
    Data.Groups.AddGroup(2,'Своя группа').AddBook(17,'lib-17');
    Data.Save(FileName); Loaded.Load(FileName);
    Require((Length(Loaded.FavoriteAuthors)=2) and (Loaded.Extras.Count=1) and (Loaded.Groups.Count=1),'User data export lost favorites or previous fields');
    Second.ImportFavorites(Loaded.FavoriteAuthors); Second.ImportFavorites(Loaded.FavoriteAuthors);
    Require((Length(Second.Entries)=3) and Second.IsFavorite('достоевский','фёдор','михайлович') and
      Second.IsFavorite('Купала','Янка',''),'Favorite import did not merge/deduplicate canonical names');
    Require(Hash=THashSHA2.GetHashStringFromFile(First.FileName),'Export changed source favorites');
    Data.FavoriteAuthors:=nil; Data.Save(TPath.Combine(Folder,'legacy.cxml2')); Loaded.Load(TPath.Combine(Folder,'legacy.cxml2'));
    Require(Length(Loaded.FavoriteAuthors)=0,'Old user data retained stale favorite entries');
    Writeln('PASS feedback21 portable favorite authors round-trip, canonical merge, old exports and protected source');
  finally Loaded.Free; Data.Free; Second.Free; First.Free; end;

  Source:=TPath.Combine(Folder,'reader.fb2'); Profile:=TPath.Combine(Folder,'reader.ini');
  TFile.WriteAllText(Source,'<FictionBook><description><title-info><book-title>Записи 21</book-title></title-info></description>'+
    '<body><section><title><p>Глава</p></title><p>Первая строка видимой страницы. Мысль и закладка.</p>'+
    '<p>Второй абзац тоже сохраняется целиком.</p><p>'+StringOfChar('Т',9000)+'</p></section></body></FictionBook>',TEncoding.UTF8);
  if (ParamStr(2)='visual') and FileExists(Settings.AppPath+'metadata-archive-fixtures\visual-fixed.epub') then Source:=Settings.AppPath+'metadata-archive-fixtures\visual-fixed.epub';
  Reader:=TfrmBuiltinReader.Create(nil);
  try
    Require(string(Reader.Caption)='HomeLibre — Читалка','Reader caption differs');
    Reader.Show; Reader.OpenBook(Source,'Записи 21','feedback21-reader',Profile,'pdfium.dll'); WaitReady(Reader);
    if ParamStr(2)='visual' then Reader.SetBounds(400,150,1100,760);
    Reader.SetShowFootnotes(False); Snapshot:=Reader.PageText;
    Reader.AddBookmark('Моё название закладки');
    Require(Reader.BookmarkContext(0)=Snapshot,'Bookmark lost visible page context');
    Ini:=TMemIniFile.Create(Profile,TEncoding.UTF8);
    try
      var Sections:=TStringList.Create;
      try
        Ini.ReadSections(Sections); var Found:=False;
        for var Section in Sections do if Section.StartsWith('Bookmarks.') then
        begin
          Require(Ini.ReadString(Section,'Title0','')='Моё название закладки','Custom bookmark title lost');
          Require(Ini.ReadString(Section,'Created0','').EndsWith('Z'),'Bookmark timestamp not persisted as a portable instant'); Found:=True;
        end;
        Require(Found,'Saved bookmark missing');
      finally Sections.Free; end;
    finally Ini.Free; end;
    Reader.SelectText(0,0); Draft:=Reader.AnnotationDraft(Snapshot);
    Require((Draft.Quote=Snapshot) and ReaderAnnotationHasRange(Draft),'Whole-page note draft lacks complete text/range');
    Button:=TButton(Reader.FindComponent('ReaderAddBookmark')); AddButton:=TButton(Reader.FindComponent('ReaderAddNote'));
    SavedButton:=TButton(Reader.FindComponent('ReaderSavedItems'));
    Require(Assigned(Button) and Assigned(AddButton) and Assigned(SavedButton),'Reader compact record buttons missing');
    Require((Button.Left<AddButton.Left) and (AddButton.Left<SavedButton.Left),'Reader record button order differs from requested');
    Require(SavedButton.Caption='Закладки и заметки','Combined reader manager caption is ambiguous');
    TThread.ForceQueue(nil,procedure begin FillFeedback21Note(Snapshot,'Мысль о всей странице.'); end);
    AddButton.OnClick(AddButton);
    Require(Reader.PageHasBookmark,'Adding a note hid the bookmark marker until page repaint');
    TThread.ForceQueue(nil,procedure
      var Manager: TForm; List: TListView; Notes, Bookmarks: TCheckBox;
      begin
        Manager:=Screen.ActiveForm; List:=TListView(Manager.FindComponent('NotesList'));
        Notes:=TCheckBox(Manager.FindComponent('NotesShowNotes')); Bookmarks:=TCheckBox(Manager.FindComponent('NotesShowBookmarks'));
        Require((Manager.Left>=Manager.Monitor.WorkareaRect.Left) and (Manager.Top>=Manager.Monitor.WorkareaRect.Top),'Saved records dialog escaped screen edge');
        Require(Assigned(Notes) and Assigned(Bookmarks) and Notes.Checked and Bookmarks.Checked,'Record type filters are missing or not enabled by default');
        Require(List.Items.Count=2,'Combined manager lost note/bookmark');
        Require(List.Items[1].SubItems[3].Contains('(UTC'),'Bookmark date is absent from actual list');
        Notes.Checked:=False; Notes.OnClick(Notes); Require((List.Items.Count=1) and (List.Items[0].Caption='Закладка'),'Bookmark-only filter failed');
        Notes.Checked:=True; Bookmarks.Checked:=False; Bookmarks.OnClick(Bookmarks);
        Require((List.Items.Count=1) and (List.Items[0].Caption='Заметка'),'Note-only filter failed');
        if ParamStr(2)<>'visual' then Manager.ModalResult:=mrCancel
        else begin Bookmarks.Checked:=True; Bookmarks.OnClick(Bookmarks); end;
      end);
    SavedButton.OnClick(SavedButton);
    if ParamStr(2)='visual' then
      while Reader.Visible do begin Application.ProcessMessages; CheckSynchronize(10); end;
    Require(Reader.ExportAnnotations(False,False).Contains('Моё название закладки'),'Combined export lost named bookmark');
    Writeln('PASS feedback21 reader toolbar order, named/time-stamped bookmark, whole-page note, visible type filters and combined export');
  finally Reader.Free; end;

  Update:=TfrmProgramUpdate.Create(nil);
  try
    Update.Show;
    BytesLabel:=TLabel(Update.FindComponent('UpdateBytes'));
    Require(Assigned(BytesLabel) and (BytesLabel.Caption='') and not BytesLabel.Visible,
      'Updater exposes its internal progress label before downloading');
    Progress:=nil;
    for var Component in Update do if Component is TProgressBar then Progress:=TProgressBar(Component);
    Require(Assigned(Progress),'Updater progress bar missing');
    BytesLabel.Caption:='Скачано: 100,0 / 200,0 МБ';
    for var PPI in TArray<Integer>.Create(96,120,144,192) do
    begin
      Update.ScaleForPPI(PPI);
      for var Size in TArray<Integer>.Create(9,12,16,20) do
      begin
        Update.Font.Size:=Size; Update.ClientWidth:=MulDiv(900,PPI,96); Update.ClientHeight:=MulDiv(700,PPI,96);
        Application.ProcessMessages; Height:=0; Buttons:=0;
        for var Component in Update do
          if (Component is TButton) and TButton(Component).Visible then
          begin
            Button:=TButton(Component);
            Require((Button.Top>=0) and (Button.BoundsRect.Bottom<=Update.ClientHeight),'Updater button escaped the window at enlarged font/DPI');
            Require(Button.Height>=Abs(Button.Font.Height),'Updater button clips its font'); Inc(Buttons);
          end;
        Require(Buttons>=4,'Updater fixture did not exercise its footer and zoom controls');
        Require(BytesLabel.Visible and Progress.Visible and (BytesLabel.Height>=Abs(BytesLabel.Font.Height)) and
          (Progress.BoundsRect.Bottom<=BytesLabel.Top),'Updater transfer text overlaps its bar or clips enlarged text');
        for var Component in Update do
          if (Component is TButton) and (TButton(Component).Caption='Проверить обновления') then
            Require(BytesLabel.BoundsRect.Bottom<TButton(Component).Top,'Updater transfer text overlaps its action button');
      end;
    end;
    Writeln('PASS feedback21 actual updater form bounds/font height at 100/125/150/200 percent DPI and enlarged text');
    if ParamStr(2)='visual' then begin BytesLabel.Caption:=''; Update.ScaleForPPI(96); Update.Font.Size:=16; Update.ClientWidth:=900; Update.ClientHeight:=700; Update.Hide; Update.ShowModal; end;
  finally Update.Free; end;
end;
