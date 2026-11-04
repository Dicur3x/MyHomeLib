procedure TestPackingFbd;
const
  ArchiveName = 'Пара.zip';
  BookText = 'Исходный текст книги ё.';
  Description = '<FictionBook><description>Описание ё.</description></FictionBook>';
var
  Source, PackedCollection: IBookCollection;
  SourceID, BookID, ArchivedID, PackedID: Integer;
  Book: TBookRecord;
  Options: TCollectionPackingOptions;
  SourceDir, Original, SourceHash: string;
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
      Snapshot.Pack;
      Require((Snapshot.Status.SourcesDone=1) and (Snapshot.Status.BooksDone=2) and
        (Snapshot.Status.Reused=ExpectedReused), 'A shared FBD container was omitted or counted twice');
      Snapshot.ApplyPrepared;
      Result:=Snapshot.RegisterNew(SystemDB);
    finally
      Snapshot.Free;
    end;
  end;

  procedure VerifyCopy(ID: Integer);
  var Fbd, Archived: TBookRecord;
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
  end;

begin
  SourceDir:=IncludeTrailingPathDelimiter(Settings.AppPath+'packing-fbd-source');
  ForceDirectories(SourceDir);
  Original:=SourceDir+ArchiveName;
  Zip:=TZipFile.Create;
  try
    Zip.Open(Original,zmWrite);
    Zip.Add(TEncoding.UTF8.GetBytes(BookText),'chapter.txt');
    Zip.Add(TEncoding.UTF8.GetBytes(Description),'chapter.fbd');
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
    VerifyCopy(CreateCopy(Options,1));
  finally
    Require(RenameFile(Original+'.held',Original), 'Cannot restore the owned original fixture');
  end;
  Writeln('PASS original FBD container, both native locator forms, exact book and descriptor, reuse without originals');
end;
