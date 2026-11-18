procedure TestPackedSourceReview;
var Folder,OriginalRoot,HeldRoot,PackedRoot,Incoming,BaseIndex,NextIndex:string;
  Source,PackedCollection:IBookCollection; SourceID,PackedID,FirstID,SecondID:Integer;
  Options:TCollectionPackingOptions; Snapshot:TCollectionPackingSnapshot;
  Profile:TLibraryUpdateSource; Dialog:TfrmLibraryUpdateSources;
  Catalog,Personal:TSQLiteDatabase; BeforeRows,BeforePersonal,BeforeINI:string;
  Zip:TZipFile; Worker:TManualUpdateThread; Book:TBookRecord;

  procedure Index(const FileName:string; NewBook:Boolean);
    function Row(ID:Integer):string;
    begin
      Result:='Автор,Тест:'#4'prose_contemporary:'#4'Publisher '+IntToStr(ID)+#4#4#4+
        IntToStr(ID)+#4'123'#4+IntToStr(ID)+#4'0'#4'txt'#4'2026-11-18'#4'ru'+sLineBreak;
    end;
  var Z:TZipFile;
  begin
    Z:=TZipFile.Create;
    try
      Z.Open(FileName,zmWrite);
      Z.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
      Z.Add(TEncoding.UTF8.GetBytes(Row(1001)+Row(1002)),'books.inp');
      if NewBook then Z.Add(TEncoding.UTF8.GetBytes(Row(1003)),'new.inp');
    finally Z.Free; end;
  end;

  procedure Review(Deleted:Boolean);
  var Stream:TStream; Bytes:TBytes;
  begin
    Catalog:=TSQLiteDatabase.CreateReadOnly(PackedCollection.GetProperty(PROP_DATAFILE));
    Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
    Dialog:=nil;
    try
      BeforeRows:=ReaderAllCatalogRows(Catalog); BeforePersonal:=ReaderAllCatalogRows(Personal);
      BeforeINI:=THashSHA2.GetHashStringFromFile(Settings.SettingsFileName);
      Dialog:=TfrmLibraryUpdateSources.CreateForCollection(frmMain,PackedCollection);
      Dialog.AppendSource(Profile); Dialog.CheckSource;
      Require(Assigned(Dialog.Review) and Dialog.Review.Ready,'Packed source profile did not finish review');
      Require((Dialog.Review.NewBooks=1) and (Dialog.Review.ChangedBooks=0),
        'Packed source review confused packed sizes or deleted rows with publisher changes: '+Dialog.Review.Summary);
      Require((Dialog.Review.NeededArchives.Count=1) and SameText(Dialog.Review.NeededArchives[0],'new.zip'),
        'Packed source review asks for old archives instead of only the new archive: '+Dialog.Review.NeededArchives.Text);
      Require(Dialog.Review.Summary.Contains('исходными сведениями упакованной копии'),
        'Packed source review does not explain its publisher baseline');
      Require((ReaderAllCatalogRows(Catalog)=BeforeRows) and (ReaderAllCatalogRows(Personal)=BeforePersonal) and
        (THashSHA2.GetHashStringFromFile(Settings.SettingsFileName)=BeforeINI),
        'Packed source review wrote catalogue personal data or settings');
      PackedCollection.GetBookRecord(CreateBookKey(FirstID,PackedID),Book,True);
      Stream:=Book.GetBookStream(True,False);
      try
        Require(Assigned(Stream),'Packed book cannot be read with originals offline');
        SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
        Require(TEncoding.UTF8.GetString(Bytes)='Original body 1001','Packed source review changed the old book');
      finally Stream.Free; end;
      Require((Book.Rate=4) and (Book.Progress=37) and (PackedCollection.GetReview(Book.BookKey)='Личная заметка ё'),
        'Packed source review lost personal data');
      Require(Catalog.QuerySingleInt('SELECT BookSize FROM HomeLibrePackingPublishers WHERE BookID=?',[FirstID])=123,
        'Packed publisher snapshot lost the original nominal index size');
      if Deleted then Require(PackedCollection.ResolveBookID('1002',0)=0,'Packed review resurrected a deleted card');
      Writeln('PASS packed source profile compares original names sizes and dates with only new archive needed and no writes deleted=',Ord(Deleted)); Flush(Output);
    finally Dialog.Free; Personal.Free; Catalog.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Packed source review requires an isolated G: runtime');
  Folder:=Settings.AppPath+'packed-source-review\'; OriginalRoot:=Folder+'original'; HeldRoot:=Folder+'original-held';
  PackedRoot:=Folder+'packed'; Incoming:=Folder+'incoming'; ForceDirectories(OriginalRoot); ForceDirectories(Incoming);
  BaseIndex:=TPath.Combine(OriginalRoot,'base.inpx'); NextIndex:=TPath.Combine(Incoming,'next.inpx');
  Index(BaseIndex,False); Index(NextIndex,True);
  Zip:=TZipFile.Create;
  try
    Zip.Open(TPath.Combine(OriginalRoot,'books.zip'),zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1001'),'1001.txt');
    Zip.Add(TEncoding.UTF8.GetBytes('Original body 1002'),'1002.txt');
  finally Zip.Free; end;
  SourceID:=SystemDB.CreateCollection('Packed source review originals',OriginalRoot,Folder+'source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  Worker:=TManualUpdateThread.Create(SourceID,BaseIndex,False,gtFb2);
  try TOORun(Worker); Require(Worker.Success,'Packed review original INPX import failed'); finally Worker.Free; end;
  Source:=SystemDB.GetCollection(SourceID); FirstID:=Source.ResolveBookID('1001',0); SecondID:=Source.ResolveBookID('1002',0);
  Source.SetRate(CreateBookKey(FirstID,SourceID),4); Source.SetProgress(CreateBookKey(FirstID,SourceID),37);
  Source.SetReview(CreateBookKey(FirstID,SourceID),'Личная заметка ё');
  Options:=Default(TCollectionPackingOptions); Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.SourceRoot:=OriginalRoot; Options.OutputRoot:=PackedRoot; Options.SourceID:=SourceID;
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.DisplayName:='Packed source profile baseline';
  Options.Python:=Settings.AppPath+'tools\python\python.exe'; Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared; PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  PackedCollection:=SystemDB.GetCollection(PackedID);
  Require(RenameFile(OriginalRoot,HeldRoot),'Cannot hide owned original archive folder');
  try
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Packed publisher';
    Profile.Location:=Incoming; Profile.IndexFile:='next.inpx'; Profile.BooksRoot:=Incoming;
    Review(False);
    PackedCollection.DeleteBook(CreateBookKey(SecondID,PackedID));
    Review(True);
  finally Require(RenameFile(HeldRoot,OriginalRoot),'Cannot restore owned original folder'); end;
end;
