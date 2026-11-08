{$I CollectionPackingUnavailableTests.inc}
{$I CollectionPackingInpxTests.inc}
{$I CollectionPackingRealTests.inc}

procedure TestPackingFbd;
const
  ArchiveName = 'Пара.zip';
  BookText = 'Исходный текст книги ё.';
  Description = '<FictionBook><description>Описание ё.</description></FictionBook>';
var
  Source, PackedCollection: IBookCollection;
  SourceID, BookID, ArchivedID, LooseID, PackedID: Integer;
  Book: TBookRecord;
  Options: TCollectionPackingOptions;
  SourceDir, Original, LooseOriginal, SourceHash: string;
  AlternateRoot, AlternateLoose, AlternateHash, AlternateFixture: string;
  AlternateBytes: TBytes;
  DB: TSQLiteDatabase;
  Zip: TZipFile;

  procedure VerifyStream(Stream: TStream; const Expected: string);
  var Bytes: TBytes;
  begin
    try
      Require(Assigned(Stream), 'Expected a book or descriptor stream');
      SetLength(Bytes, Stream.Size);
      Stream.ReadBuffer(Bytes, Length(Bytes));
      Require(TEncoding.UTF8.GetString(Bytes)=Expected, 'Book or descriptor bytes changed');
    finally
      Stream.Free;
    end;
  end;

  function CreateCopy(const CopyOptions: TCollectionPackingOptions; ExpectedReused: Integer): Integer;
  var Snapshot: TCollectionPackingSnapshot;
  begin
    Snapshot:=TCollectionPackingSnapshot.Create(CopyOptions);
    try
      Snapshot.Prepare;
      Require(Snapshot.PlannedLocations=5,'Packing omitted an alternate copy without an extension');
      Snapshot.Pack;
      Require((Snapshot.Status.SourcesDone=3) and (Snapshot.Status.BooksDone=5) and
        (Snapshot.Status.Reused=ExpectedReused), 'A shared FBD container was omitted or counted twice');
      Snapshot.ApplyPrepared;
      Result:=Snapshot.RegisterNew(SystemDB);
    finally
      Snapshot.Free;
    end;
  end;

  procedure VerifyCopy(ID: Integer);
  var Fbd, Archived, Loose: TBookRecord; Copies: TArray<TBookRecord>; Stream: TStream;
  begin
    PackedCollection:=SystemDB.GetCollection(ID);
    PackedCollection.GetBookRecord(CreateBookKey(BookID,ID),Fbd,True);
    PackedCollection.GetBookRecord(CreateBookKey(ArchivedID,ID),Archived,True);
    Require((Fbd.GetBookFormat=bfFbd) and (Archived.GetBookFormat=bfRawArchive),
      'Packing changed a native archive locator kind');
    Require(SameFileName(Fbd.GetBookFileName,Archived.GetBookFileName), 'Copy duplicated the same archive');
    Require(THashSHA2.GetHashStringFromFile(Fbd.GetBookFileName)=SourceHash, 'FBD archive bytes changed');
    VerifyStream(Fbd.GetBookStream(True,False),BookText);
    VerifyStream(Fbd.GetBookDescriptorStream(True),Description);
    VerifyStream(Archived.GetBookStream(True,False),BookText);
    PackedCollection.GetBookRecord(CreateBookKey(LooseID,ID),Loose,True);
    Require(Loose.GetBookFormat=bfRaw,'Small loose file was replaced by a larger archive');
    Require(TFile.GetSize(Loose.GetBookFileName)=Length(TEncoding.UTF8.GetBytes(BookText)),
      'Loose copy grew beyond the original bytes');
    VerifyStream(Loose.GetBookStream(True,False),BookText);
    Copies:=PackedCollection.GetCatalogBookCopies(CreateBookKey(BookID,ID));
    Require((Length(Copies)=2) and (Copies[0].LibID='archive-copy') and (Copies[1].LibID='loose-copy'),
      'Packing changed alternate copy identities');
    for var Copy in Copies do
      Require(SameFileName(Copy.CollectionRoot,Options.OutputRoot) and (Copy.FileExt=''),
        'An extensionless alternate copy still points outside the packed collection');
    Stream:=Copies[0].GetBookStream(True,False);
    try
      Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),AlternateHash),
        'Packing changed the extensionless archived copy');
    finally Stream.Free; end;
    VerifyStream(Copies[1].GetBookStream(True,False),BookText);
  end;

begin
  SourceDir:=IncludeTrailingPathDelimiter(Settings.AppPath+'packing-fbd-source');
  ForceDirectories(SourceDir);
  Original:=SourceDir+ArchiveName;
  AlternateBytes:=TEncoding.UTF8.GetBytes('Другой экземпляр книги.');
  AlternateFixture:=GetEnvironmentVariable('HOMELIB_PACKING_ALTERNATE_PAYLOAD');
  if AlternateFixture<>'' then AlternateBytes:=TFile.ReadAllBytes(AlternateFixture);
  var HashStream:=TBytesStream.Create(AlternateBytes);
  try AlternateHash:=THashSHA2.GetHashString(HashStream); finally HashStream.Free; end;
  Zip:=TZipFile.Create;
  try
    Zip.Open(Original,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes(BookText),'chapter.txt');
    Zip.Add(TEncoding.UTF8.GetBytes(Description),'chapter.fbd');
    Zip.Add(AlternateBytes,'nested book.');
  finally
    Zip.Free;
  end;
  SourceHash:=THashSHA2.GetHashStringFromFile(Original);
  SourceID:=SystemDB.CreateCollection('FBD source',SourceDir,'packing-fbd-source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  BookID:=AddBook(Source,'FBD book','Автор Ё','ru','','prose_contemporary');
  Source.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
  Book.Folder:=''; Book.FileName:=ArchiveName; Book.FileExt:='.txt'; Book.InsideNo:=0;
  Source.UpdateBook(Book);
  ArchivedID:=AddBook(Source,'Ordinary record','Автор Ё','ru','','prose_contemporary');
  Source.GetBookRecord(CreateBookKey(ArchivedID,SourceID),Book,True);
  Book.Folder:=ArchiveName; Book.FileName:='chapter'; Book.FileExt:='.txt'; Book.InsideNo:=0;
  Source.UpdateBook(Book);
  LooseID:=AddBook(Source,'Loose book','Автор Ё','ru','','prose_contemporary');
  Source.GetBookRecord(CreateBookKey(LooseID,SourceID),Book,True);
  Book.Folder:=''; Book.FileName:='Короткая книга'; Book.FileExt:='.txt'; Book.InsideNo:=-1;
  Source.UpdateBook(Book);
  LooseOriginal:=SourceDir+Book.FileName+Book.FileExt;
  TFile.WriteAllBytes(LooseOriginal,TEncoding.UTF8.GetBytes(BookText));

  Source.GetBookRecord(CreateBookKey(BookID,SourceID),Book,True);
  Book.Folder:=ArchiveName; Book.FileName:='nested book'; Book.FileExt:=''; Book.InsideNo:=2;
  Book.LibID:='archive-copy';
  Source.SetCatalogBookCopy('alternate-archive','Other archive',Book);
  AlternateRoot:=IncludeTrailingPathDelimiter(Settings.AppPath+'packing-fbd-alternate');
  ForceDirectories(AlternateRoot);
  Book.CollectionRoot:=AlternateRoot; Book.Folder:=''; Book.FileName:='Other book.txt'; Book.InsideNo:=-1;
  Book.LibID:='loose-copy';
  AlternateLoose:=AlternateRoot+Book.FileName;
  TFile.WriteAllBytes(AlternateLoose,TEncoding.UTF8.GetBytes(BookText));
  Source.SetCatalogBookCopy('alternate-loose','Other source',Book);
  DB:=TSQLiteDatabase.Create(Source.GetProperty(PROP_DATAFILE));
  try DB.ExecSQL('UPDATE CatalogBookCopies SET Ext=NULL WHERE SourceKey=''alternate-loose''');
  finally DB.Free; end;

  Options:=Default(TCollectionPackingOptions);
  Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Options.SourceID:=SourceID;
  Options.SourceRoot:=SourceDir;
  Options.OutputRoot:=Settings.AppPath+'packing-fbd-copy';
  Options.DisplayName:='FBD copy';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  PackedID:=CreateCopy(Options,0);
  VerifyCopy(PackedID);
  Require(THashSHA2.GetHashStringFromFile(Original)=SourceHash, 'Original FBD archive changed');
  Options.CatalogFile:=PackedCollection.GetProperty(PROP_DATAFILE);
  Options.SourceID:=PackedID;
  Options.SourceRoot:=Options.OutputRoot;
  Options.DisplayName:='FBD resumed copy';
  Require(RenameFile(Original,Original+'.held'), 'Cannot hide the owned original for the retention check');
  try
    Require(RenameFile(LooseOriginal,LooseOriginal+'.held'), 'Cannot hide the owned loose fixture');
    try
      Require(RenameFile(AlternateLoose,AlternateLoose+'.held'),'Cannot hide the owned alternate copy');
      try VerifyCopy(CreateCopy(Options,3));
      finally Require(RenameFile(AlternateLoose+'.held',AlternateLoose),'Cannot restore the owned alternate copy'); end;
    finally Require(RenameFile(LooseOriginal+'.held',LooseOriginal), 'Cannot restore the owned loose fixture'); end;
  finally
    Require(RenameFile(Original+'.held',Original), 'Cannot restore the owned original fixture');
  end;
  Writeln('PASS original FBD container, both native locator forms, exact book and descriptor, reuse without originals');
  Writeln('PASS loose book does not grow and remains readable after retention without its original');
  Writeln('PASS alternate copies with empty and NULL extensions survive packing and reuse without originals');
  TestPackingUnavailable;
  TestPackingInpx;
  if DirectoryExists(Settings.AppPath+'packing-real-input') then TestPackingReal;
  if DirectoryExists(Settings.AppPath+'packing-flibrary-epub') then TestPackedFLibraryEpub;
end;
