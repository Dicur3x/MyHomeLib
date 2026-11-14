procedure TestPackingJpegXLFormats;
var Source,PackedCopy,ReusedCopy:IBookCollection; Options:TCollectionPackingOptions;
    Manifest:TJSONObject; IDs:TArray<Integer>; SourceID:Integer; Book,Card:TBookRecord;
    SourceArchive,SourceCatalog,ArchiveHash,CatalogHash,OutputRoot:string;

  procedure VerifyEpub(Stream:TStream);
  var Zip:TZipFile; Bytes:TBytes;
  begin
    Zip:=TZipFile.Create;
    try
      Stream.Position:=0; Zip.Open(Stream,zmRead);
      var Assets:=Manifest.GetValue<TJSONObject>('epub_assets');
      Require((Zip.FileCount=Assets.Count) and (Zip.FileNames[0]='mimetype') and
        (Zip.FileInfo[0].CompressionMethod=0),'Reconstructed EPUB has a private index or invalid mimetype layout');
      for var Asset in Assets do
      begin
        Require(Zip.IndexOf(Asset.JsonString.Value)>=0,'Missing EPUB resource '+Asset.JsonString.Value);
        Zip.Read(Asset.JsonString.Value,Bytes);
        var AssetStream:=TBytesStream.Create(Bytes);
        try Require(SameText(THashSHA2.GetHashString(AssetStream),Asset.JsonValue.Value),
          'JPEG XL changed EPUB resource '+Asset.JsonString.Value);
        finally AssetStream.Free; end;
      end;
    finally Zip.Free; end;
  end;

  procedure VerifyTextOnly(const Value:TBookRecord);
  var Held,SavedPath,Prepared,Target:string; Uncached:TBookRecord; Missing:Boolean;
      Warnings:TStringList; Document:TReaderDocument; Zip:TZipFile;
  begin
    Require(StartsText(Settings.AppPath,TPath.GetFullPath(Options.JpegXLDecoder)),
      'Text-only test may hold only its private decoder');
    Held:=Options.JpegXLDecoder+'.held'; SavedPath:=GetEnvironmentVariable('PATH');
    TFile.Move(Options.JpegXLDecoder,Held);
    try
      SetEnvironmentVariable('PATH','');
      Require(FindExternalTool('djxl.exe','jpeg-xl')='','A decoder remains available during the text-only test');
      Uncached:=Value; Uncached.LibID:=Value.LibID+'-text-only';
      Prepared:=PrepareConversionSource(Uncached,nil,'.epub',False);
      Target:=Settings.AppPath+'text-only-jxl-'+IntToStr(Value.BookKey.DatabaseID)+'.epub';
      Warnings:=TStringList.Create;
      try ConvertBasicBook(Settings.AppPath,Settings.TempPath,Prepared,'.epub',Target,nil,
        Warnings,nil,'','','',False,nil,'none');
      finally Warnings.Free; end;
      Document:=TReaderDocument.Create;
      try
        Document.Load(Target);
        Require((Document.ImageCount=0) and Document.PlainText.Contains('Keep this text') and
          (Length(Document.PlainText)>1000),'Text-only EPUB export lost its readable text or kept images');
      finally Document.Free; end;
      Zip:=TZipFile.Create;
      try Zip.Open(Target,zmRead);
        Require(Zip.IndexOf('FLibraryImageIndex.json')<0,'Text-only EPUB export kept a stale external-image index');
      finally Zip.Free; end;
      Missing:=False;
      try PrepareConversionSource(Uncached,nil,'.epub',True);
      except on E:EMHLComponentRequired do Missing:=E.ComponentID='JPEG XL'; end;
      Require(Missing,'Full EPUB export reused a text-only source without its decoder');
    finally
      SetEnvironmentVariable('PATH',PChar(SavedPath)); TFile.Move(Held,Options.JpegXLDecoder);
    end;
    Writeln('PASS native JPEG XL EPUB text-only export works without its decoder and cannot replace full-image preparation');
  end;

  procedure Verify(const Collection:IBookCollection; IsPacked:Boolean);
  var Value,Personal:TBookRecord; Stream:TStream; Zip:TZipFile; Bytes:TBytes;
      Prepared:string; Document:TReaderDocument;
  begin
    for var I:=0 to 1 do
    begin
      Collection.GetBookRecord(CreateBookKey(IDs[I],Collection.CollectionID),Value,True);
      Require(Value.Size=StrToInt64(Manifest.GetValue<TJSONArray>('sizes').Items[I].Value),
        'JPEG XL catalogue stored a surrogate size');
      if IsPacked then Require(SameText(ExtractFileExt(Value.GetBookFileName),'.7z'),
        'JPEG XL fixture did not publish the separated layout');
      Stream:=Value.GetBookStream(True,True);
      try
        Require(Assigned(Stream),'Native JPEG XL book stream is missing');
        if I=0 then Require(SameText(THashSHA2.GetHashString(Stream),Manifest.GetValue<string>('pdf_sha256')),
          'Native PDF reconstruction changed original bytes')
        else VerifyEpub(Stream);
      finally Stream.Free; end;
      var Converted:=PrepareConversionSource(Value,nil,Value.FileExt,True);
      Require(FileExists(Converted),'JPEG XL export has no prepared source');
      if I=0 then
      begin
        Require(SameText(UpdateSHA256(Converted),Manifest.GetValue<string>('pdf_sha256')),
          'Full PDF conversion source differs from its original');
        var TextSource:=PrepareConversionSource(Value,nil,'.pdf',False);
        Require(SameText(UpdateSHA256(TextSource),Manifest.GetValue<string>('pdf_sha256')),
          'PDF conversion without illustrations did not restore its real container');
      end
      else
      begin
        var ExportStream:=TFileStream.Create(Converted,fmOpenRead or fmShareDenyNone);
        try VerifyEpub(ExportStream); finally ExportStream.Free; end;
        if IsPacked then VerifyTextOnly(Value);
      end;
      Prepared:=PrepareReaderFile(Value,True);
      Require(FileExists(Prepared),'Native JPEG XL preparation produced no reading file');
      if I=0 then Require(SameText(UpdateSHA256(Prepared),Manifest.GetValue<string>('pdf_sha256')),
        'Prepared PDF differs from its original')
      else
      begin
        Document:=TReaderDocument.Create;
        try
          Document.Load(Prepared);
          Require((Length(Document.PlainText)>1000) and (Document.ImageCount>=2),
            'Reconstructed EPUB did not load its text, cover and escaped image path');
        finally Document.Free; end;
        SystemDB.GetBookRecord(Value.BookKey,Personal);
        Require((Personal.Progress=37) and (Personal.Review='Keep format notes') and (Personal.Size=Value.Size),
          'JPEG XL publication lost a personal card or its logical size');
      end;
    end;
  end;

  function Pack(const Collection:IBookCollection; Reused:Integer):IBookCollection;
  var Snapshot:TCollectionPackingSnapshot;
  begin
    Options.SourceID:=Collection.CollectionID;
    Options.CatalogFile:=Settings.ExpandCollectionFileName(VarToStr(Collection.GetProperty(PROP_DATAFILE)));
    var Info:=SystemDB.GetCollectionInfo(Collection.CollectionID);
    Options.SourceRoot:=Info.GetRootPath;
    Options.DisplayName:='JPEG XL formats '+IntToStr(Reused);
    Snapshot:=TCollectionPackingSnapshot.Create(Options);
    try
      Snapshot.Prepare; Snapshot.Pack;
      Require((Snapshot.Status.Reused=Reused) and (Snapshot.Status.ImageBooksOptimized>=2) and
        (Snapshot.Status.OutputBytes<Snapshot.Status.InputBytes),'JPEG XL format fixture did not shrink and retain both books');
      Snapshot.ApplyPrepared;
      Result:=SystemDB.GetCollection(Snapshot.RegisterNew(SystemDB));
    finally Snapshot.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Manifest:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Settings.AppPath+'packing-jxl-formats.json',TEncoding.UTF8)) as TJSONObject;
  try
    SourceArchive:=Settings.AppPath+'books\shared.zip'; OutputRoot:=Settings.AppPath+'packing-jxl-formats-output';
    SourceID:=SystemDB.CreateCollection('JPEG XL source formats',Settings.AppPath+'books',
      'packing-jxl-formats.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Source:=SystemDB.GetCollection(SourceID); SetLength(IDs,2);
    for var I:=0 to 1 do
    begin
      IDs[I]:=AddBook(Source,'JPEG XL format '+IntToStr(I),'Author','en','','prose_contemporary');
      Source.GetBookRecord(CreateBookKey(IDs[I],SourceID),Book,True);
      Book.LibID:='jxl-format-'+IntToStr(I); Book.Folder:='shared.zip'; Book.InsideNo:=I;
      if I=0 then begin Book.FileName:='one'; Book.FileExt:='.pdf'; end
      else begin Book.FileName:='two'; Book.FileExt:='.epub'; end;
      Book.Size:=StrToInt64(Manifest.GetValue<TJSONArray>('sizes').Items[I].Value);
      Source.UpdateBook(Book);
      if I=1 then
      begin
        Source.SetProgress(Book.BookKey,37); Source.SetReview(Book.BookKey,'Keep format notes');
        Source.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID);
      end;
    end;
    Verify(Source,False); Writeln('TRACE native format sources verified');
    SourceCatalog:=Settings.ExpandCollectionFileName(VarToStr(Source.GetProperty(PROP_DATAFILE)));
    ArchiveHash:=UpdateSHA256(SourceArchive); CatalogHash:=THashSHA2.GetHashStringFromFile(SourceCatalog);
    Options:=Default(TCollectionPackingOptions); Options.OutputRoot:=OutputRoot;
    Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.ImageProfile:=pipJpegXL;
    Options.Python:=Settings.AppPath+'tools\python\python.exe';
    Options.Script:=Settings.AppPath+'tools\bookconvert\pack_collection.py';
    Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
    InstallPackingCodecs(Options);
    PackedCopy:=Pack(Source,0); Verify(PackedCopy,True); Writeln('TRACE native formats published');
    TFile.Move(SourceArchive,SourceArchive+'.held');
    try
      ReusedCopy:=Pack(PackedCopy,1); Verify(ReusedCopy,True); Writeln('TRACE native formats retained');
    finally TFile.Move(SourceArchive+'.held',SourceArchive); end;
    Require((UpdateSHA256(SourceArchive)=ArchiveHash) and (THashSHA2.GetHashStringFromFile(SourceCatalog)=CatalogHash),
      'JPEG XL formats changed original books or source catalogue');
    SystemDB.GetBookRecord(CreateBookKey(IDs[1],SourceID),Card);
    Require((Card.Progress=37) and (Card.Review='Keep format notes'),'JPEG XL formats changed original personal data');
    Writeln('PASS native JPEG XL PDF exact bytes and EPUB complete resources reading and retention without originals');
  finally Manifest.Free; end;
end;
