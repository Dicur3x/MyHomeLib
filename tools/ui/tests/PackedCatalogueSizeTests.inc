// Full copy publication, followed by an INPX update without original archives.
procedure TestPackedCatalogueSizes;
var Source,Published,Updated:IBookCollection; Options:TCollectionPackingOptions;
    Snapshot:TCollectionPackingSnapshot; Worker:TCollectionPackingInpxWorker;
    SourceID,FirstID,SecondID:Integer; Book,Card:TBookRecord; Zip:TZipFile;
    OriginalSizes:TArray<Int64>; ExpectedSizes:TArray<Int64>;
    Root,Input,Rows,BeforeSource,SourceCatalogue,BeforeCatalogue,OriginalArchive,HiddenArchive:string;

  procedure Verify(const Collection:IBookCollection; Initial:Boolean);
  var Value:TBookRecord; Stream:TStream; I:Integer;
  begin
    for I:=0 to 1 do
    begin
      var ID:=FirstID; if I=1 then ID:=SecondID;
      Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Value,True);
      Stream:=Value.GetBookStream(True,False);
      try
        Require(Assigned(Stream),'Published packed book cannot be opened');
        Require(Value.Size=Stream.Size,Format('Packed catalogue kept size %d instead of actual %d for %s',
          [Value.Size,Stream.Size,Value.FileExt]));
        if Initial then
        begin
          Require(Stream.Size<OriginalSizes[I],'Large illustrated fixture was not compressed');
          ExpectedSizes[I]:=Stream.Size;
        end
        else Require(Stream.Size=ExpectedSizes[I],'INPX update recompressed a retained book');
      finally Stream.Free; end;
      if I=0 then
      begin
        SystemDB.GetBookRecord(Value.BookKey,Card);
        Require((Card.Progress=37) and (Card.Review='Keep personal note') and (Card.Size=Value.Size),'Packed personal card lost progress or kept an old size');
      end;
    end;
    var Copies:=Collection.GetCatalogBookCopies(CreateBookKey(FirstID,Collection.CollectionID));
    Require(Length(Copies)=1,'Packing lost the alternate source location');
    Require(Copies[0].Size=ExpectedSizes[0],'Packed alternate copy kept an old size');
  end;

  procedure VerifyCompatibility;
  var Mode,I,ID:Integer; CopyOptions:TCollectionPackingOptions;
      CopySnapshot:TCollectionPackingSnapshot; Mapping:TSQLiteDatabase;
      CopyCollection:IBookCollection; Value,PersonalValue:TBookRecord; Stream:TStream;
  begin
    for Mode:=0 to 1 do
    begin
      CopyOptions:=Options; CopyOptions.ImageProfile:=pipOriginal;
      CopyOptions.DisplayName:='Size compatibility '+IntToStr(Mode);
      CopyOptions.OutputRoot:=Root+'-compat-'+IntToStr(Mode);
      CopySnapshot:=TCollectionPackingSnapshot.Create(CopyOptions);
      try
        CopySnapshot.Prepare; CopySnapshot.Pack;
        Mapping:=TSQLiteDatabase.Create(TPath.Combine(CopyOptions.OutputRoot,
          'generations\'+CopySnapshot.PreparedGeneration+'\locations.sqlite'));
        try
          if Mode=0 then Mapping.ExecSQL('UPDATE locations SET book_size=NULL')
          else
          begin
            Mapping.ExecSQL('CREATE TABLE old_locations AS SELECT book_id,folder,filename,ext,inside_no FROM locations');
            Mapping.ExecSQL('DROP TABLE locations');
            Mapping.ExecSQL('ALTER TABLE old_locations RENAME TO locations');
          end;
        finally Mapping.Free; end;
        CopySnapshot.ApplyPrepared;
        CopyCollection:=SystemDB.GetCollection(CopySnapshot.RegisterNew(SystemDB));
      finally CopySnapshot.Free; end;
      for I:=0 to 1 do
      begin
        ID:=FirstID; if I=1 then ID:=SecondID;
        CopyCollection.GetBookRecord(CreateBookKey(ID,CopyCollection.CollectionID),Value,True);
        Stream:=Value.GetBookStream(True,False);
        try Require(Assigned(Stream) and (Value.Size=OriginalSizes[I]) and
          (Stream.Size=OriginalSizes[I]),'Unknown or legacy mapping changed an unchanged book size');
        finally Stream.Free; end;
      end;
      SystemDB.GetBookRecord(CreateBookKey(FirstID,CopyCollection.CollectionID),PersonalValue);
      Require((PersonalValue.Size=OriginalSizes[0]) and (PersonalValue.Progress=37),
        'Unknown or legacy mapping changed the personal card');
      var Copies:=CopyCollection.GetCatalogBookCopies(CreateBookKey(FirstID,CopyCollection.CollectionID));
      Require((Length(Copies)=1) and (Copies[0].Size=OriginalSizes[0]),
        'Unknown or legacy mapping changed an alternate copy size');
    end;
  end;

  procedure VerifyInvalidSizes(const Prepared:TCollectionPackingSnapshot);
  var Mapping:TSQLiteDatabase; Invalid:string; Rejected:Boolean;
  begin
    Mapping:=TSQLiteDatabase.Create(TPath.Combine(Options.OutputRoot,
      'generations\'+Prepared.PreparedGeneration+'\locations.sqlite'));
    try
      Mapping.ExecSQL('CREATE TEMP TABLE saved_sizes AS SELECT book_id,book_size FROM locations');
      Mapping.ExecSQL('PRAGMA ignore_check_constraints=ON');
      for Invalid in ['-1','1.5'] do
      begin
        Mapping.ExecSQL('UPDATE locations SET book_size='+Invalid);
        Rejected:=False;
        try Prepared.ApplyPrepared;
        except on E:Exception do Rejected:=Pos('некорректный размер книги',E.Message)>0; end;
        Require(Rejected,'Publication accepted a negative or fractional book size');
      end;
      Mapping.ExecSQL('UPDATE locations SET book_size=(SELECT book_size FROM saved_sizes s WHERE s.book_id=locations.book_id)');
    finally Mapping.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Root:=Settings.AppPath+'packed-size-output';
  SourceID:=SystemDB.CreateCollection('Packed size source',Settings.AppPath+'books',
    'packed-size-source.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  FirstID:=AddBook(Source,'Size FB2','Author','en','','prose_contemporary');
  SecondID:=AddBook(Source,'Size EPUB','Author','en','','prose_contemporary');
  SetLength(OriginalSizes,2); SetLength(ExpectedSizes,2);
  Zip:=TZipFile.Create;
  try
    Zip.Open(Settings.AppPath+'books\shared.zip',zmRead);
    for var I:=0 to 1 do
    begin
      var ID:=FirstID; var Name:='one.fb2'; if I=1 then begin ID:=SecondID; Name:='two.epub'; end;
      Source.GetBookRecord(CreateBookKey(ID,SourceID),Book,True);
      Book.LibID:=IntToStr(101+I); Book.Folder:='shared.zip'; Book.FileName:=ChangeFileExt(Name,'');
      Book.FileExt:=ExtractFileExt(Name); Book.InsideNo:=I;
      OriginalSizes[I]:=Zip.FileInfo[Zip.IndexOf(Name)].UncompressedSize; Book.Size:=OriginalSizes[I];
      Source.UpdateBook(Book);
      if I=0 then
      begin
        Source.SetRate(Book.BookKey,4); Source.SetProgress(Book.BookKey,37);
        Source.SetReview(Book.BookKey,'Keep personal note');
        Source.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
        SystemDB.GetBookRecord(Book.BookKey,Card);
        Require((Card.Progress=37) and (Card.Size=Book.Size),'Cannot seed the source personal card');
        Source.SetCatalogBookCopy('size-alternate','Alternate source',Book);
      end;
    end;
  finally Zip.Free; end;
  SourceCatalogue:=Settings.ExpandCollectionFileName(VarToStr(Source.GetProperty(PROP_DATAFILE)));
  BeforeSource:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'books\shared.zip');
  BeforeCatalogue:=THashSHA2.GetHashStringFromFile(SourceCatalogue);
  Options:=Default(TCollectionPackingOptions);
  Options.SourceID:=SourceID; Options.SourceRoot:=Settings.AppPath+'books'; Options.OutputRoot:=Root;
  Options.CatalogFile:=SourceCatalogue; Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
  Options.DisplayName:='Published size copy'; Options.ImageProfile:=pipMaximum;
  Options.Python:=Settings.AppPath+'tools\python\python.exe';
  Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare; Snapshot.Pack; VerifyInvalidSizes(Snapshot); Snapshot.ApplyPrepared;
    Published:=SystemDB.GetCollection(Snapshot.RegisterNew(SystemDB));
  finally Snapshot.Free; end;
  Writeln('TRACE packed sizes published');
  Verify(Published,True);
  VerifyCompatibility;
  Writeln('TRACE packed sizes compatibility');
  Require(THashSHA2.GetHashStringFromFile(SourceCatalogue)=BeforeCatalogue,'Publication changed the source catalogue');
  Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'books\shared.zip')=BeforeSource,'Publication changed source books');
  Rows:='';
  for var I:=0 to 1 do
  begin
    var Name:='one'; var Ext:='fb2'; if I=1 then begin Name:='two'; Ext:='epub'; end;
    Rows:=Rows+'Author,Test:'#4'prose_contemporary:'#4'Updated metadata'#4#4#4+Name+#4+
      IntToStr(OriginalSizes[I])+#4+IntToStr(101+I)+#4'0'#4+Ext+#4'2026-11-14'#4'en'+sLineBreak;
  end;
  Input:=Settings.AppPath+'packed-size-refresh.inpx'; Zip:=TZipFile.Create;
  try Zip.Open(Input,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes(Rows),'shared.inp');
    Zip.Add(TEncoding.UTF8.GetBytes('20261114'),'version.info');
  finally Zip.Free; end;
  ForceDirectories(Settings.AppPath+'packed-size-empty-update');
  Options.SourceID:=Published.CollectionID; Options.SourceRoot:=Root;
  Options.DisplayName:='Updated packed size copy';
  Options.CatalogFile:=Settings.ExpandCollectionFileName(VarToStr(Published.GetProperty(PROP_DATAFILE)));
  BeforeCatalogue:=THashSHA2.GetHashStringFromFile(Options.CatalogFile);
  OriginalArchive:=Settings.AppPath+'books\shared.zip'; HiddenArchive:=OriginalArchive+'.held';
  TFile.Move(OriginalArchive,HiddenArchive);
  try
    Worker:=TCollectionPackingInpxWorker.Create(Options,Input,Settings.AppPath+'packed-size-empty-update',nil,
      procedure(const Status:TCollectionPackingStatus) begin end);
    try
      Worker.Start; Worker.WaitFor;
      Require(Worker.Success,'Actual packed INPX update failed');
      Snapshot:=Worker.TakeSnapshot;
    finally Worker.Free; end;
    try Updated:=SystemDB.GetCollection(Snapshot.RegisterNew(SystemDB)); finally Snapshot.Free; end;
    Writeln('TRACE packed sizes updated');
    Verify(Updated,False);
  finally TFile.Move(HiddenArchive,OriginalArchive); end;
  Require(THashSHA2.GetHashStringFromFile(Options.CatalogFile)=BeforeCatalogue,'Update changed the preceding packed catalogue');
  Writeln('PASS packed publication and actual INPX retain book copy and personal sizes without originals');
end;
