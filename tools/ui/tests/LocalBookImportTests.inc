type
  TLocalImportProbe = class(TImportLocalBookThread)
  private
    FCOM: Boolean;
  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
  public
    Profile: string;
  end;

procedure TLocalImportProbe.Initialize;
begin FCOM:=TOOInitialize(Self,Profile); end;

procedure TLocalImportProbe.Uninitialize;
begin try inherited; finally if FCOM then CoUninitialize; end; end;

procedure TestLocalBookImport;
const
  FB2 = '<?xml version="1.0" encoding="UTF-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>' +
    '<genre>prose_contemporary</genre><author><last-name>Сорокин</last-name></author>' +
    '<book-title>Моя книга</book-title><lang>ru</lang><sequence name="Основная серия" number="2"/>' +
    '</title-info></description><body><section><p>Свой текст.</p></section></body></FictionBook>';
var
  Root, Files, Profile, Original, Index, LocalID, OriginalHash, History, NotesPath, Managed: string;
  EPUB, PDF, ZipName, HtmlZip, HtmlPath, Invalid: string;
  SystemData: ISystemData;
  Catalog: IBookCollection;
  Cursor: IBookIterator;
  Book, Favorite: TBookRecord;
  BookSeries: TBookSeries;
  Snapshot: TArray<TLocalCatalogBook>;
  CID, OldID, RemoteID, FileCount: Integer;
  SourceZip: TZipFile;
  Member, HtmlOutput: TStream;
  HtmlEncoding: TEncoding;
  FoundHtml: Boolean;
  TestReader: TReaderDocument;
  Notes: TReaderAnnotations;
  Note: TReaderAnnotation;
  AddedNote: string;

  procedure AddFile(const Path: string; ExpectSuccess: Boolean = True; Cancel: Boolean = False);
  var Worker: TLocalImportProbe;
  begin
    Worker:=TLocalImportProbe.Create(CID,Path); Worker.Profile:=Profile; Worker.Canceled:=Cancel;
    try
      TOORun(Worker);
      Require((Worker.Success=ExpectSuccess) and (Worker.CommittedChanges=ExpectSuccess),
        'Unexpected import outcome for '+Path);
    finally Worker.Free; end;
  end;

  procedure AddReservedSourceRow(const FileName: string);
  var Zip: TZipFile; Lines: TBytes;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(FileName,zmReadWrite);
      Zip.Read('books.inp',Lines);
      Zip.Delete('books.inp');
      Zip.Add(TEncoding.UTF8.GetBytes(TEncoding.UTF8.GetString(Lines)+sLineBreak+
        'Автор,Тест:'#4'prose_contemporary:'#4'Чужая запись с локальным UUID'#4#4#4+
        'spoof'#4'100'#4+LocalID+#4'0'#4'fb2'#4'2026-10-13'#4'ru'),'books.inp');
    finally Zip.Free; end;
  end;

  procedure UpdateFrom(const Path: string; Full: Boolean; Cancel: Boolean = False);
  var Worker: TOOManualWorker;
  begin
    Worker:=TOOManualWorker.Create(CID,Path,Full,gtFb2);
    Worker.FixtureProfile:=Profile;
    try
      TOORun(Worker,Cancel);
      Require((Worker.Success=not Cancel) and (Worker.CommittedChanges=not Cancel),
        'Unexpected INPX update outcome');
    finally Worker.Free; end;
  end;

  procedure CheckBook(ExpectedRemote: Boolean);
  var CurrentID: Integer;
  begin
    Catalog:=SystemData.GetCollection(CID,True);
    CurrentID:=Catalog.ResolveBookID(LocalID,OldID);
    Require(CurrentID>0,'Full update lost the local key');
    Catalog.GetBookRecord(CreateBookKey(CurrentID,CID),Book,True);
    Require((Book.LibID=LocalID) and (Book.Title='Моя книга') and
      (Book.CollectionName='Добавлено вручную') and (Book.Progress=37) and (Book.Rate=4) and
      (Book.Review='Своё примечание') and (Book.Annotation='Своя аннотация'),
      'The local catalogue record or its personal data changed');
    Require((Book.AuthorCount=1) and (Book.Authors[0].LastName='Сорокин'),'Local author was lost');
    Require(Book.GetBookFileName=Managed,'Managed copy moved during the update');
    Require(THashSHA2.GetHashStringFromFile(Managed)=OriginalHash,'Managed copy changed during the update');
    Require((Catalog.GetViewURL(LocalID)='') and (Catalog.GetEditURL(LocalID)=''),
      'Manual book was assigned the external library URL');
    BookSeries:=Catalog.GetBookSeries(Book.BookKey);
    Require((Length(BookSeries)=2) and BookSeries[0].IsPrimary and
      (BookSeries[0].SeriesTitle='Основная серия') and (BookSeries[1].SeriesTitle='Дополнительная серия'),
      'Local series relationships did not survive the update');
    Require(ReaderNoteIdentity(ReaderHistoryName(Book,'flibusta'))=History,
      'The new catalogue key changed the Reader bookmark key');
    Notes:=TReaderAnnotations.Create(NotesPath);
    try
      Require(Notes.Find(AddedNote,Note) and (Note.BookID=History) and (Note.Position=12),
        'The bookmark was lost');
      Require(FindReaderNoteBook(SystemData,NotesPath,Note,CID,Favorite) and
        Favorite.BookKey.IsSameAs(Book.BookKey),'The bookmark resolves to the wrong catalogue record');
    finally Notes.Free; end;
    Cursor:=SystemData.GetBookIterator(FAVORITES_GROUP_ID,CID);
    Require(Cursor.Next(Favorite),'The favorite is missing after update');
    Require((Favorite.LibID=LocalID) and Favorite.BookKey.IsSameAs(Book.BookKey),
      'The favorites card was bound to the wrong book');
    Cursor:=nil;
    if ExpectedRemote then
    begin
      RemoteID:=Catalog.ResolveBookID(IntToStr(OldID),0);
      Require((RemoteID>0) and (RemoteID<>CurrentID),'The remote numeric ID overwrote the local book');
      Catalog.GetBookRecord(CreateBookKey(RemoteID,CID),Favorite,False);
      Require(Favorite.Title='Запись Флибусты','The external book was not imported independently');
    end;
    Catalog:=nil;
  end;

begin
  RequireIsolatedRegression;
  frmMain.ImportSelectedBookUpdate(frmMain.acImportSelectedBook);
  Require((frmMain.miImportSelectedBook.Parent=frmMain.N39) and
    (frmMain.miImportSelectedBook.Action=frmMain.acImportSelectedBook) and
    frmMain.acImportSelectedBook.Enabled,'The main menu does not expose single-file import');
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'local-book-import-'+TGUID.NewGuid.ToString));
  Files:=Root+'arbitrary source\'; ForceDirectories(Files);
  Profile:=Root+'system.sqlite';
  TSystemData_SQLite.CreateSystemTables(Profile);
  SystemData:=TSystemData_SQLite.Create(Profile);
  ForceDirectories(Root+'collection\');
  CID:=SystemData.CreateCollection('Local imports and Flibusta',Root+'collection\',Root+'collection.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);

  Original:=Files+'Выбранный файл.fb2'; TFile.WriteAllText(Original,FB2,TEncoding.UTF8);
  OriginalHash:=THashSHA2.GetHashStringFromFile(Original);
  AddFile(Original);
  Catalog:=SystemData.GetCollection(CID,True);
  Catalog.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
  Snapshot:=Catalog.CaptureLocalBooks;
  Require(Length(Snapshot)=1,'The selected file did not receive a protected local key');
  Book:=Snapshot[0].Book; LocalID:=Book.LibID; OldID:=Book.BookKey.BookID;
  Require(IsLocalBookID(LocalID),'Invalid local UUID');
  Require(Book.Title='Моя книга','The selected FB2 title was not imported');
  Managed:=Book.GetBookFileName;
  Require(Managed.StartsWith(Root+'collection\') and (Managed<>Original),'The managed path is incorrect');
  Require(THashSHA2.GetHashStringFromFile(Original)=OriginalHash,'Import modified the selected file');
  Catalog.SetProgress(Book.BookKey,37); Catalog.SetRate(Book.BookKey,4);
  Catalog.SetReview(Book.BookKey,'Своё примечание'); Catalog.SetAnnotation(Book.BookKey,'Своя аннотация');
  Catalog.AddBookSeries(OldID,'Дополнительная серия',3);
  Catalog.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
  History:=ReaderNoteIdentity(ReaderHistoryName(Book,'flibusta'));
  NotesPath:=Root+'reader.ini';
  RegisterReaderNoteBook(NotesPath,Book,'flibusta');
  Note:=Default(TReaderAnnotation); Note.BookID:=History; Note.BookTitle:=Book.Title;
  Note.Title:='Закладка'; Note.Position:=12;
  Notes:=TReaderAnnotations.Create(NotesPath);
  try AddedNote:=Notes.Put(Note); finally Notes.Free; end;
  Catalog:=nil;

  EPUB:=Files+'wrong filename.epub';
  SourceZip:=TZipFile.Create;
  try
    SourceZip.Open(EPUB,zmWrite);
    SourceZip.Add(TEncoding.UTF8.GetBytes('<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'+
      '<rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),'META-INF/container.xml');
    SourceZip.Add(TEncoding.UTF8.GetBytes('<package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'+
      '<dc:title>Мой EPUB</dc:title><dc:creator>Автор EPUB</dc:creator><dc:language>ru</dc:language></metadata>'+
      '<manifest><item id="text" href="book.xhtml" media-type="application/xhtml+xml"/></manifest>'+
      '<spine><itemref idref="text"/></spine></package>'),'book.opf');
    SourceZip.Add(TEncoding.UTF8.GetBytes('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Текст EPUB.</p></body></html>'),'book.xhtml');
  finally SourceZip.Free; end;
  AddFile(EPUB);

  PDF:=Files+'Мой PDF.pdf'; TFile.WriteAllText(PDF,'%PDF-1.4'+#10+'%%EOF',TEncoding.ASCII);
  AddFile(PDF);
  ZipName:=Files+'archived books.zip';
  SourceZip:=TZipFile.Create;
  try
    SourceZip.Open(ZipName,zmWrite);
    SourceZip.Add(TEncoding.UTF8.GetBytes(FB2.Replace('Моя книга','Книга из архива')),'inner/Книга.fb2');
  finally SourceZip.Free; end;
  AddFile(ZipName);

  HtmlZip:=Files+'Архив с HTML.zip';
  SourceZip:=TZipFile.Create;
  try
    SourceZip.Open(HtmlZip,zmWrite);
    SourceZip.UTF8Support:=False;
    HtmlEncoding:=TEncoding.GetEncoding(1251);
    try
      SourceZip.Add(HtmlEncoding.GetBytes('<html><head><meta charset="windows-1251"></head>'+
        '<body><p>Текст из старого HTML.</p></body></html>'),'Книга.html');
    finally HtmlEncoding.Free; end;
  finally SourceZip.Free; end;
  AddFile(HtmlZip);

  Catalog:=SystemData.GetCollection(CID,True);
  Snapshot:=Catalog.CaptureLocalBooks;
  Require(Length(Snapshot)=5,'Multiple chosen formats did not create separate local keys');
  FileCount:=Length(TDirectory.GetFiles(ExtractFilePath(Managed)));
  FoundHtml:=False;
  for var Entry in Snapshot do
  begin
    if Entry.Book.FileExt='.epub' then
    begin
      Require((Entry.Book.Title='Мой EPUB') and (Entry.Book.Authors[0].LastName='Автор EPUB'),
        'The EPUB title and author were not extracted');
      Require(THashSHA2.GetHashStringFromFile(Entry.Book.GetBookFileName)=THashSHA2.GetHashStringFromFile(EPUB),
        'The EPUB copy changed');
    end;
    if Entry.Book.FileExt='.pdf' then Require(Entry.Book.Title='Мой PDF','Missing PDF fallback title');
    if Entry.Book.Title='Книга из архива' then
    begin
      Member:=Entry.Book.GetBookStream(False,False);
      try Require(Assigned(Member) and (Member.Size>0),'The selected ZIP member cannot be read by name');
      finally Member.Free; end;
    end;
    if Entry.Book.FileExt='.html' then
    begin
      FoundHtml:=True;
      Require(THashSHA2.GetHashStringFromFile(Entry.Book.GetBookFileName)=THashSHA2.GetHashStringFromFile(HtmlZip),
        'The ZIP with HTML was changed during import');
      HtmlPath:=Files+'extracted.html';
      Member:=Entry.Book.GetBookStream(False,False);
      try
        Require(Assigned(Member),'The selected HTML entry cannot be read');
        HtmlOutput:=TFileStream.Create(HtmlPath,fmCreate);
        try HtmlOutput.CopyFrom(Member,0); finally HtmlOutput.Free; end;
      finally Member.Free; end;
      TestReader:=TReaderDocument.Create;
      try
        TestReader.Load(HtmlPath);
        Require(TestReader.PlainText.Contains('Текст из старого HTML.'),'The HTML text did not decode');
      finally TestReader.Free; end;
    end;
  end;
  Require(FoundHtml,'A ZIP containing only HTML was not catalogued');
  Catalog:=nil;

  Invalid:=Files+'invalid.exe'; TFile.WriteAllText(Invalid,'MZ is an executable signature',TEncoding.ASCII);
  AddFile(Invalid,False);
  Invalid:=Files+'incomplete.fb2';
  TFile.WriteAllText(Invalid,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description>',TEncoding.UTF8);
  AddFile(Invalid,False);
  AddFile(Original,False,True);
  Require(Length(TDirectory.GetFiles(ExtractFilePath(Managed)))=FileCount,'Rejected import left a managed copy');

  Index:=Root+'remote.inpx';
  TOOIndex(Index,'Запись Флибусты',IntToStr(OldID));
  UpdateFrom(Index,False);
  CheckBook(True);
  AddReservedSourceRow(Index);
  UpdateFrom(Index,True);
  CheckBook(True);
  Require(Book.BookKey.BookID<>OldID,'The full reimport did not exercise a changed numeric catalogue key');
  Require(TOOBookCount(SystemData,CID)=6,'Full INPX import lost or duplicated records');
  UpdateFrom(Index,True,True);
  CheckBook(True);

  TestReader:=TReaderDocument.Create;
  try
    TestReader.Load(Managed);
    Require(TestReader.PlainText.Contains('Свой текст.'),'The local book cannot be read after the update');
  finally TestReader.Free; end;
  Require(THashSHA2.GetHashStringFromFile(Original)=OriginalHash,'Catalogue changes modified the selected file');
  Writeln('PASS single-file import preserves managed bytes and local identity across INPX updates');
end;
