procedure TestMetadataArchiveCodecs;
var Source: TPublisherSeriesSource; Reader: TFB2PublisherMetadataReader; Book: TBookRecord;
  Metadata: TFB2CatalogMetadata; ErrorText,Folder,BeforeKey,ActualExtension: string; Stream: TStream;
  Archive: TSevenZipMetadataArchive; Rejected: Boolean; Samples: TJSONValue; Item: TJSONValue; Started: UInt64; Collection: IBookCollection; CID: Integer; Plan: TCollectionMetadataPlan; Counts: TMetadataSyncCounts;
begin
  RequireIsolatedRegression; Folder:=Settings.AppPath+'metadata-archive-fixtures\';
  Source:=TPublisherSeriesSource.Create(nil); Reader:=TFB2PublisherMetadataReader.Create;
  try
    Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(1,1); Book.NodeType:=ntBookInfo;
    Book.CollectionRoot:=Folder; Book.FileName:='native-source'; Book.FileExt:='.fb2'; Book.InsideNo:=999;
    for var Name in TArray<string>.Create('ppmd.zip','ordinary.7z','solid.7z') do
    begin
      Book.Folder:=Name; BeforeKey:=Source.GetSourceKey(Book);
      Require(BeforeKey<>'','Archive codec fixture missing: '+Name);
      Stream:=Source.OpenDescriptor(Book,False);
      try
        Require((Stream.Size>100) and (Stream.Size<2*1024*1024),'Native metadata read expanded the complete 10 MB book');
        Require(Reader.ReadCatalogMetadata(Stream,Metadata,ErrorText,True)=fmsComplete,
          'Native archive metadata parse failed: '+Name+' '+ErrorText);
        Require((Metadata.Publisher='Издательство Ёжик') and (Metadata.City='Киев') and
          (Metadata.PubYear=2025) and (Metadata.ISBN='978-fixture') and
          Metadata.Translators.Contains('Человек') and Metadata.Annotation.Contains('Мысль'),
          'Archive codec lost publication metadata: '+Name);
      finally Stream.Free; end;
      Require(Source.GetSourceKey(Book)=BeforeKey,'Archive source changed while reading metadata');
      Book.FileName:='absent'; Rejected:=False;
      try Stream:=Source.OpenDescriptor(Book,False); Stream.Free; except on E: EReadError do Rejected:=True; end;
      Require(Rejected,'Archive metadata guessed a different book from a stale numeric index'); Book.FileName:='native-source';
      Writeln('PASS native metadata prefix ',Name,' exact names, complete fields, bounded output and unchanged source');
    end;
  finally Reader.Free; Source.Free; end;
  Archive:=TSevenZipMetadataArchive.Create(Folder+'ppmd.zip',nil);
  try Stream:=Archive.ReadPrefix('native-source.fb2',128);
    try Require(Stream.Size=128,'Native metadata prefix limit was exceeded'); finally Stream.Free; end;
  finally Archive.Free; end;
  Rejected:=False;
  try Archive:=TSevenZipMetadataArchive.Create(Folder+'ppmd.zip',function: Boolean begin Result:=True; end); Archive.Free;
  except on E: EAbort do Rejected:=True; end;
  Require(Rejected,'Native archive cancellation did not abort before reading');
  Writeln('PASS native archive prefix limit and cancellation do not require any helper process');
  Source:=TPublisherSeriesSource.Create(nil);
  try
    for var Extension in TArray<string>.Create('.epub','.docx','.odt','.fb3') do
      for var IsPacked in [False,True] do
      begin
        Book:=Default(TBookRecord); Book.CollectionRoot:=Folder; Book.FileName:='package'+Extension;
        Book.FileName:=ChangeFileExt(Book.FileName,''); Book.FileExt:=Extension;
        if IsPacked then Book.Folder:='packages.zip';
        Stream:=Source.OpenDescriptor(Book,False);
        try
          Require(ReadPackageMetadata(Stream,Extension,Metadata,ErrorText,True)=fmsComplete,
            'Package metadata parse failed '+Extension+': '+ErrorText);
          Require((Metadata.Publisher='Издательство Ёжик') and (Metadata.PubYear=2025) and
            (Metadata.ISBN='978-fixture') and Metadata.Translators.Contains('Человек') and
            Metadata.Annotation.Contains('Мысль'),'Package publication fields were lost '+Extension);
          if Extension<>'.epub' then Require(Metadata.City='Киев','Explicit document city missing');
          Stream.Position:=0;
          Require(ReadPackageMetadata(Stream,Extension,Metadata,ErrorText,False)=fmsComplete,'Package annotation-off parse failed');
          Require(Metadata.Annotation='','Package annotation was read despite explicit opt-out');
        finally Stream.Free; end;
        Writeln('PASS bounded publication metadata ',Extension,' packed=',Ord(IsPacked));
      end;
  finally Source.Free; end;

  Source:=TPublisherSeriesSource.Create(nil); Reader:=TFB2PublisherMetadataReader.Create;
  try
    for var Name in TArray<string>.Create('single.zip','single.tar','single.fb2.gz','single.fb2.bz2','single.fb2.xz','renamed.zip') do
    begin
      Book:=Default(TBookRecord); Book.CollectionRoot:=Folder; Book.FileName:=ChangeFileExt(Name,''); Book.FileExt:=ExtractFileExt(Name);
      Stream:=Source.OpenCatalogMetadata(Book,ActualExtension);
      try
        Require(Assigned(Stream),'Container metadata did not locate its single supported book: '+Name);
        if ActualExtension='.epub' then Require(ReadPackageMetadata(Stream,ActualExtension,Metadata,ErrorText,True)=fmsComplete,ErrorText)
        else Require(Reader.ReadCatalogMetadata(Stream,Metadata,ErrorText,True)=fmsComplete,ErrorText);
        Require(Metadata.Publisher='Издательство Ёжик','Container metadata chose the wrong contents '+Name);
      finally Stream.Free; end;
      Writeln('PASS single-book metadata container ',Name,' detected=',ActualExtension);
    end;
    Book.FileName:='ambiguous'; Book.FileExt:='.zip'; Rejected:=False;
    try Stream:=Source.OpenCatalogMetadata(Book,ActualExtension); Stream.Free;
    except on E: EMetadataAmbiguousBook do Rejected:=True; end;
    Require(Rejected,'Ambiguous metadata archive silently assigned a random book to its catalog card');
    Writeln('PASS ambiguous metadata archive is reported without guessing or opening a modal dialog');
  finally Reader.Free; Source.Free; end;
  CID:=SystemDB.CreateCollection('Archive metadata batches',Folder,Settings.AppPath+'archive-batch-metadata.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to 1205 do
  begin
    Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Book.Title:='Batch '+IntToStr(I);
    Book.FileName:='native-source'; Book.FileExt:='.fb2'; Book.LibID:='native-batch-'+IntToStr(I);
    case I mod 3 of 0:Book.Folder:='ppmd.zip'; 1:Book.Folder:='ordinary.7z'; 2:Book.Folder:='solid.7z'; end;
    Book.Size:=100; Include(Book.BookProps,bpIsLocal); Collection.InsertBook(Book,False,False);
  end;
  Started:=GetTickCount64; Plan:=PreviewCollectionMetadata(Collection,[msfPublisher],Counts);
  try
    Require(Assigned(Plan) and (Counts.BooksChecked=1206) and (Counts.BooksPlanned=1206) and
      (Counts.BooksFailed=0),'Archive-grouped metadata batches lost or repeated catalog rows');
    Require(Counts.ArchiveOpens<=6,'Archive-grouped scan reopened central directories for individual books');
    Writeln('PASS 1206 interleaved archive records scanned exactly once with ',Counts.ArchiveOpens,' archive opens in ',GetTickCount64-Started,' ms');
  finally Plan.Free; Collection:=nil; end;
  if FileExists(Folder+'real-samples.json') then
  begin
    Samples:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Folder+'real-samples.json',TEncoding.UTF8));
    Source:=TPublisherSeriesSource.Create(nil); Reader:=TFB2PublisherMetadataReader.Create;
    try
      for Item in (Samples as TJSONArray) do
      begin
        Book:=Default(TBookRecord); Book.BookKey:=CreateBookKey(Item.GetValue<Integer>('id'),1);
        Book.CollectionRoot:=Item.GetValue<string>('root');
        Require(CharInSet(UpCase(Book.CollectionRoot[1]),['G','H','F']),'Read-only sample outside allowed book drives');
        Book.Folder:=Item.GetValue<string>('folder'); Book.FileName:=Item.GetValue<string>('file');
        Book.FileExt:=Item.GetValue<string>('ext'); Book.InsideNo:=Item.GetValue<Integer>('index');
        BeforeKey:=Source.GetSourceKey(Book); Started:=GetTickCount64;
        Stream:=Source.OpenDescriptor(Book,False);
        try
          Require(Reader.ReadCatalogMetadata(Stream,Metadata,ErrorText,True)=fmsComplete,
            'Real sample metadata failed: '+IntToStr(Book.BookKey.BookID)+' '+ErrorText);
        finally Stream.Free; end;
        Require(Source.GetSourceKey(Book)=BeforeKey,'Real sample source changed');
        Writeln('PASS read-only real metadata sample ',Book.BookKey.BookID,' ',Item.GetValue<string>('kind'),' ',GetTickCount64-Started,' ms');
      end;
    finally Reader.Free; Source.Free; Samples.Free; end;
  end;

end;
