type
  TFileDropPromptProbe = class
  public
    ExpectedPrompt: string;
    Reply: Integer;
    PromptSeen: Boolean;
    procedure Poll(Sender: TObject);
  end;

procedure TFileDropPromptProbe.Poll(Sender: TObject);
var Active: TCustomForm;
begin
  Active := Screen.ActiveForm;
  if Active is TImportProgressFormEx then
  begin
    if TImportProgressFormEx(Active).btnCancel.Caption = 'Закрыть' then
      Active.ModalResult := mrOk;
    Exit;
  end;
  if not Assigned(Active) or (Active = frmMain) then Exit;
  for var Index := 0 to Active.ComponentCount - 1 do
  begin
    var Item := Active.Components[Index];
    if (Item is TLabel) and (TLabel(Item).Caption = ExpectedPrompt) then
    begin
      PromptSeen := True;
      Active.ModalResult := Reply;
      Exit;
    end;
  end;
end;

procedure TestExplorerFileDrop(const Catalog, OtherCatalog: IBookCollection);
var
  Folder, First, Second, FirstHash, SecondHash, Name, SavedDirectory, LaunchDirectory: string;
  Watch: TTimer;
  Probe: TFileDropPromptProbe;
  SavedDialogs: Boolean;

  procedure DropOnBookList(const Paths: TArray<string>);
  var
    Items: TArray<PItemIDList>;
    ShellItems: IShellItemArray;
    Data: IDataObject;
    Target: IDropTarget;
    Attributes: DWORD;
    Effect: Longint;
    DropPoint: TPoint;
  begin
    SetLength(Items, Length(Paths));
    try
      for var Index := 0 to High(Paths) do
      begin
        Attributes := 0;
        Require(Succeeded(SHParseDisplayName(PChar(Paths[Index]), nil, Items[Index], 0, Attributes)),
          'The Shell could not resolve a drop fixture');
      end;
      Require(Succeeded(SHCreateShellItemArrayFromIDLists(Length(Items), @Items[0], ShellItems)),
        'The Shell could not group the dropped books');
      Require(Succeeded(ShellItems.BindToHandler(nil, BHID_DataObject, IDataObject, Data)),
        'The Shell could not make file drop data');
      Target := frmMain.tvBooksA.DragManager as IDropTarget;
      DropPoint := frmMain.tvBooksA.ClientToScreen(Point(30, 40));
      Effect := DROPEFFECT_COPY or DROPEFFECT_MOVE;
      Require(Succeeded(Target.DragEnter(Data, MK_LBUTTON, DropPoint, Effect)) and
        (Effect = DROPEFFECT_COPY), 'The book list did not offer to copy Shell files');
      Require(Succeeded(Target.Drop(Data, 0, DropPoint, Effect)) and
        (Effect = DROPEFFECT_COPY), 'The book list did not accept the Shell file drop');
    finally
      for var Item in Items do CoTaskMemFree(Item);
    end;
  end;

  procedure DropFiles(const Paths: TArray<string>; const Prompt: string; Reply: Integer;
    OnBookList: Boolean = False);
  var
    Header: PDropFiles;
    Drop: HGLOBAL;
    Files: string;
    Deadline: UInt64;
  begin
    Probe.ExpectedPrompt := Prompt;
    Probe.Reply := Reply;
    Probe.PromptSeen := False;
    if OnBookList then DropOnBookList(Paths)
    else
    begin
      Files := string.Join(#0, Paths) + #0#0;
      Drop := GlobalAlloc(GHND, SizeOf(TDropFiles) + Length(Files) * SizeOf(Char));
      Require(Drop <> 0, 'Could not allocate a shell file-drop fixture');
      Header := GlobalLock(Drop);
      if not Assigned(Header) then
      begin
        GlobalFree(Drop);
        Require(False, 'Could not lock the shell file-drop fixture');
      end;
      Header.pFiles := SizeOf(TDropFiles);
      Header.fWide := True;
      Move(PChar(Files)^, (PByte(Header) + Header.pFiles)^, Length(Files) * SizeOf(Char));
      GlobalUnlock(Drop);
      frmMain.Perform(WM_DROPFILES, WPARAM(Drop), 0);
    end;
    Deadline := GetTickCount64 + 3000;
    repeat
      Application.ProcessMessages;
      Sleep(10);
    until Probe.PromptSeen or (GetTickCount64 >= Deadline);
    Require(Probe.PromptSeen, 'File drop did not ask to import into the selected collection');
  end;

begin
  RequireIsolatedRegression;
  Require((GetWindowLongPtr(frmMain.Handle, GWL_EXSTYLE) and WS_EX_ACCEPTFILES) <> 0,
    'The catalogue window is not registered for Windows file drops');
  Folder := TPath.Combine(Settings.AppPath, 'file-drop');
  ForceDirectories(Folder);
  First := TPath.Combine(Folder, 'Книга с пробелами.txt');
  Second := TPath.Combine(Folder, 'Вторая книга.txt');
  TFile.WriteAllText(First, 'Первая тестовая книга.', TEncoding.UTF8);
  TFile.WriteAllText(Second, 'Вторая тестовая книга.', TEncoding.UTF8);
  FirstHash := THashSHA2.GetHashStringFromFile(First);
  SecondHash := THashSHA2.GetHashStringFromFile(Second);
  Name := VarToStr(Catalog.GetProperty(PROP_DISPLAYNAME));
  Probe := TFileDropPromptProbe.Create;
  Watch := TTimer.Create(nil);
  SavedDialogs := UseLatestCommonDialogs;
  SavedDirectory := GetCurrentDir;
  LaunchDirectory := TPath.Combine(Folder,'outside-profile');
  ForceDirectories(LaunchDirectory);
  try
    Require(SetCurrentDir(LaunchDirectory),'Could not simulate an Explorer launch directory');
    UseLatestCommonDialogs := False;
    Watch.Interval := 30;
    Watch.OnTimer := Probe.Poll;
    DropFiles(TArray<string>.Create(First),
      Format('Добавить файл «%s» в коллекцию «%s»?', [ExtractFileName(First), Name]), mrNo);
    Require(Length(Catalog.CaptureLocalBooks) = 0, 'A declined drop changed the catalogue');
    DropFiles(TArray<string>.Create(First, Second),
      Format('Добавить выбранные файлы (2) в коллекцию «%s»?', [Name]), mrYes, True);
    Require(Length(Catalog.CaptureLocalBooks) = 2, 'The accepted drop did not import both books');
    Require(Length(OtherCatalog.CaptureLocalBooks) = 0, 'The drop changed a different collection');
    var ImportedFolder := TPath.Combine(Catalog.CollectionRoot,'HomeLibre-local-books');
    Require(Length(TDirectory.GetFiles(ImportedFolder,'*.txt')) = 2,
      'Imported copies were not written to the collection root');
    Require(not DirectoryExists(TPath.Combine(LaunchDirectory,'HomeLibre-local-books')),
      'Imported copies were written relative to the process launch directory');
    Require((THashSHA2.GetHashStringFromFile(First) = FirstHash) and
      (THashSHA2.GetHashStringFromFile(Second) = SecondHash), 'A drop changed its source books');
  finally
    SetCurrentDir(SavedDirectory);
    UseLatestCommonDialogs := SavedDialogs;
    Watch.Free;
    Probe.Free;
  end;
  Writeln('PASS Windows file-drop message and book list confirm the destination, support cancellation and import multiple books');
end;

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
  CID, FolderCID, OldID, RemoteID, FileCount: Integer;
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
    Worker:=TLocalImportProbe.Create(CID,TArray<string>.Create(Path));
    Worker.Profile:=Profile; Worker.Canceled:=Cancel;
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
    frmMain.acImportSelectedBook.Enabled,'The main menu does not expose local file import');
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

  PDF:=Files+'Мой PDF.pdf'; TFile.WriteAllText(PDF,'%PDF-1.4'+#10+'%%EOF',TEncoding.ASCII);
  ZipName:=Files+'archived books.zip';
  SourceZip:=TZipFile.Create;
  try
    SourceZip.Open(ZipName,zmWrite);
    SourceZip.Add(TEncoding.UTF8.GetBytes(FB2.Replace('Моя книга','Книга из архива')),'inner/Книга.fb2');
  finally SourceZip.Free; end;

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
  Invalid:=Files+'invalid.exe';
  TFile.WriteAllText(Invalid,'MZ is an executable signature',TEncoding.ASCII);
  var Batch:=TLocalImportProbe.Create(CID,TArray<string>.Create(EPUB,Invalid,PDF,ZipName,HtmlZip));
  Batch.Profile:=Profile;
  try
    TOORun(Batch);
    Require(Batch.Success and Batch.CommittedChanges,'A failed file stopped the selected batch');
  finally Batch.Free; end;

  Catalog:=SystemData.GetCollection(CID,True);
  Snapshot:=Catalog.CaptureLocalBooks;
  Require(Length(Snapshot)=5,'Multiple chosen formats did not create separate local keys');
  FileCount:=Length(TDirectory.GetFiles(ExtractFilePath(Managed)));
  Require(FileCount=5,'The selected batch left an unexpected managed copy');
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

  // Use the same folder worker as the menu and the new-collection wizard.
  var FolderRoot:=Root+'folder scan\';
  ForceDirectories(FolderRoot);
  FolderCID:=SystemData.CreateCollection('Folder import',FolderRoot,Root+'folder-scan.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  TFile.Copy(ZipName,FolderRoot+'ordinary.fb2.zip');
  TFile.Copy(HtmlZip,FolderRoot+'html-only.zip');
  var Mixed:=FolderRoot+'mixed.zip';
  SourceZip:=TZipFile.Create;
  try
    SourceZip.Open(Mixed,zmWrite);
    SourceZip.Add(TEncoding.UTF8.GetBytes(FB2),'inner/book.fb2');
    SourceZip.Add(TEncoding.UTF8.GetBytes('<html><body>Другой формат.</body></html>'),'inner/book.html');
    SourceZip.Add(TEncoding.ASCII.GetBytes('MZ'),'inner/ignore.exe');
  finally SourceZip.Free; end;
  var MixedHash:=THashSHA2.GetHashStringFromFile(Mixed);
  var SavedSort:=Settings.EnableSort;
  Settings.EnableSort:=False;
  try
    for var Scan:=1 to 2 do
    begin
      var FolderWorker:=TOOFB2Worker.Create(FolderCID,afZip);
      FolderWorker.FixtureProfile:=Profile;
      try
        TOORun(FolderWorker);
        Require(FolderWorker.Success,'The folder scanner did not complete');
      finally FolderWorker.Free; end;
      Require(TOOBookCount(SystemData,FolderCID)=4,'The folder scanner lost or duplicated an archive member');
    end;
  finally Settings.EnableSort:=SavedSort; end;
  Catalog:=SystemData.GetCollection(FolderCID,True);
  Cursor:=Catalog.GetBookIterator(bmAll,False);
  var MixedCount:=0;
  while Cursor.Next(Book) do
    if SameFileName(Book.GetBookFileName,Mixed) then
    begin
      Inc(MixedCount);
      Member:=Book.GetBookStream(False,False);
      try
        Require(Assigned(Member),'The mixed archive member could not be opened');
        var Bytes: TBytes;
        SetLength(Bytes,Member.Size);
        Member.ReadBuffer(Bytes[0],Length(Bytes));
        if Book.FileExt='.fb2' then
          Require(TEncoding.UTF8.GetString(Bytes)=FB2,'FB2 resolved to a different archive member')
        else
          Require((Book.FileExt='.html') and TEncoding.UTF8.GetString(Bytes).Contains('Другой формат.'),
            'HTML resolved to a different archive member');
      finally Member.Free; end;
    end;
  Require(MixedCount=2,'Both same-name books must be readable from the original ZIP');
  Require(THashSHA2.GetHashStringFromFile(Mixed)=MixedHash,'The folder scanner changed the ZIP');
  Writeln('PASS local batch, mixed folder import, member readback and local identity across INPX updates');

  // Optional exact reporter samples. Add each through the same worker that
  // handles the menu and Explorer, into a separate temporary collection.
  var ReportSamples:=GetEnvironmentVariable('HOMELIB_TEST_IMPORT_FIXTURES');
  if ReportSamples<>'' then
  begin
    var ReportRoot:=Root+'report-imports\'; ForceDirectories(ReportRoot);
    var ReportCID:=SystemData.CreateCollection('Reported book imports',ReportRoot,Root+'report-imports.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    var Samples:=TDirectory.GetFiles(ReportSamples,'*.zip');
    Require(Length(Samples)=8,'Reporter sample set is incomplete');
    for var Sample in Samples do
    begin
      var Hash:=THashSHA2.GetHashStringFromFile(Sample);
      var Worker:=TLocalImportProbe.Create(ReportCID,[Sample]);
      var Messages:=TStringList.Create;
      Worker.Profile:=Profile;
      try
        TOORun(Worker,False,Messages);
        Require(THashSHA2.GetHashStringFromFile(Sample)=Hash,'Import changed an attached archive');
        Writeln('REPORT import ',ExtractFileName(Sample),' committed=',Ord(Worker.CommittedChanges),
          ' messages=',Messages.Text.Trim.Replace(#13,' ').Replace(#10,' ')); Flush(Output);
        var SampleName:=ExtractFileName(Sample);
        var Expected:=SampleName.StartsWith('ВАЛЬДИРА+') or SampleName.StartsWith('2002+') or
          SampleName.StartsWith('Рев+') or SampleName.StartsWith('Максим+');
        Require(Worker.CommittedChanges=Expected,'Unexpected import result: '+SampleName);
        if not Expected then
          if SampleName.StartsWith('Орловский+') then
            Require(Messages.Text.Contains('нулевые байты'),'The zeroed book lacks a damage diagnosis')
          else Require(Messages.Text.Contains('обрывается'),'The truncated book lacks a damage diagnosis');
      finally Messages.Free; Worker.Free; end;
    end;
    Catalog:=SystemData.GetCollection(ReportCID,True);
    Cursor:=Catalog.GetBookIterator(bmAll,False);
    var RecognizedEPUB:=0; var RepairedFB2:=0;
    while Cursor.Next(Book) do
    begin
      var Prepared:=PrepareReaderFile(Book,True);
      TestReader:=TReaderDocument.Create;
      try
        TestReader.Load(Prepared);
        Require(TestReader.PlainText.Length>500,'The imported book lost its text');
        if SameText(ExtractFileExt(Prepared),'.epub') then
        begin
          Require(TestReader.ImageCount>0,'The imported EPUB lost its illustration');
          Inc(RecognizedEPUB);
        end
        else
        begin
          Require(TestReader.Warnings.Text.Contains('Исправлена разметка FB2'),
            'The imported FB2 did not report its reading repair');
          Inc(RepairedFB2);
        end;
      finally TestReader.Free; end;
    end;
    Require(RecognizedEPUB=2,'The two mislabeled reporter EPUBs did not both reopen');
    Require(RepairedFB2=3,'The three recoverable reporter FB2 files did not all reopen');
  end;
end;
