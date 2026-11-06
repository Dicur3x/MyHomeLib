procedure TestFeedback529JXL(const Collection: IBookCollection);
var Root, Source, Container, Prepared, Stamp, XML: string; Book: TBookRecord;
  ID, Pitch, Offset: Integer; Sink: TMemoryStream; Zip: TZipFile;
  Doc: TReaderDocument; RTF, Token: AnsiString;
begin
  // Regression input: an Aksakov illustration reported by the
  // user. RGB is entirely black; the complete drawing lives in varying alpha.
  // Independent PNG decoding found (0,0) transparent and (187,0) opaque.
  Root:=Settings.AppPath+'feedback529-jxl'; ForceDirectories(Root+'\images');
  Source:=Root+'\1.fb2'; Container:=Root+'\alpha.7z';
  XML:='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'+
    '<book-title>Transparent ink regression</book-title></title-info></description>'+
    '<body><section><title><p>Проверка</p></title><p>Текст с иллюстрацией</p>'+
    '<image l:href="#1"/></section></body></FictionBook>';
  TFile.WriteAllText(Source,XML,TEncoding.UTF8);
  Sink:=TMemoryStream.Create;
  try RunExternalToolToStream(Settings.AppPath+'tools\7zip\7za.exe',['a','-t7z',Container,Source],Sink);
  finally Sink.Free; end;
  Zip:=TZipFile.Create;
  try
    Zip.Open(Root+'\images\alpha.zip',zmWrite);
    Zip.Add(Settings.AppPath+'transparent-ink.jxl','1/1');
  finally Zip.Free; end;
  ID:=AddBook(Collection,'JXL transparency','Автор','ru','','prose_contemporary');
  Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Book,False);
  Book.Folder:=Container; Book.FileName:='1'; Book.FileExt:='.fb2'; Book.InsideNo:=0;
  Prepared:=PrepareReaderFile(Book,True);
  Require(TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('content-type="image/png"'),
    'JXL image without a suffix was flattened to JPEG instead of preserving alpha');
  Stamp:=TFile.ReadAllText(Prepared+'.source',TEncoding.UTF8);
  Require(Stamp.StartsWith('reader-cache-v2|'),'Reader cache conversion revision not updated');
  TFile.WriteAllText(Prepared,'stale black reader copy',TEncoding.UTF8);
  TFile.WriteAllText(Prepared+'.source',StringReplace(Stamp,'reader-cache-v2|','reader-cache-v1|',[]),TEncoding.UTF8);
  Prepared:=PrepareReaderFile(Book,True);
  Require(TFile.ReadAllText(Prepared,TEncoding.UTF8).Contains('content-type="image/png"'),
    'Prepared copy from the old JPEG conversion cache was reused');
  Doc:=TReaderDocument.Create;
  try
    Doc.Load(Prepared); Require(Doc.ImageCount=1,'Restored JXL illustration was omitted');
    RTF:=AnsiString(Doc.RTF(600,800)); Pitch:=((354*3+3) div 4)*4;
    Token:=AnsiString('\bin'+IntToStr(40+Pitch*378)+' ');
    Offset:=Pos(Token,RTF); Require(Offset>0,'Restored illustration dimensions changed');
    Inc(Offset,Length(Token)+40+Pitch*377);
    Require((Byte(RTF[Offset])=255) and (Byte(RTF[Offset+1])=255) and
      (Byte(RTF[Offset+2])=255),'Transparent background is a black rectangle in reader output');
    Inc(Offset,187*3);
    Require((Byte(RTF[Offset])=0) and (Byte(RTF[Offset+1])=0) and
      (Byte(RTF[Offset+2])=0),'Opaque illustration ink was lost during alpha restoration');
  finally Doc.Free; end;
  Writeln('PASS feedback529 JPEG XL alpha through actual 7z/side ZIP, native reader pixels and old cache invalidation');
end;

procedure TestFLibraryJpegReconstruction;
var Root, Container, Original, Encoded, Prepared, Fb2: string; Book: TBookRecord;
  Sink: TMemoryStream; Zip: TZipFile; Bytes, OriginalBytes: TBytes; Document: TReaderDocument;
begin
  Root:=Settings.AppPath+'feedback529-jpeg'; ForceDirectories(Root+'\images');
  Original:=Settings.AppPath+'reconstruct-original.jpg';
  Encoded:=Settings.AppPath+'reconstruct-encoded.jxl';
  Container:=Root+'\books.7z';
  TFile.WriteAllText(Root+'\1.fb2','<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '+
    'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>JPEG round trip</book-title></title-info></description>'+
    '<body><section><p>Complete JPEG illustration text.</p><image l:href="#1"/></section></body></FictionBook>',TEncoding.UTF8);
  Zip:=TZipFile.Create;
  try
    Zip.Open(Root+'\2.epub',zmWrite);
    Zip.Add(TEncoding.ASCII.GetBytes('application/epub+zip'),'mimetype',zcStored);
    Zip.Add(TEncoding.UTF8.GetBytes('<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'+
      '<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),'META-INF/container.xml');
    Zip.Add(TEncoding.UTF8.GetBytes('<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'+
      '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>'+
      '<item id="picture" href="picture.jpg" media-type="image/jpeg"/></manifest>'+
      '<spine><itemref idref="chapter"/></spine></package>'),'OPS/book.opf');
    Zip.Add(TEncoding.UTF8.GetBytes('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Complete EPUB text.</p>'+
      '<img src="picture.jpg" alt="Picture"/></body></html>'),'OPS/chapter.xhtml');
    Zip.Add(TEncoding.UTF8.GetBytes('[{"id":"OPS/picture.jpg","num":0}]'),'FLibraryImageIndex.json');
    Zip.Close;
    Zip.Open(Root+'\images\books.zip',zmWrite);
    Zip.Add(Encoded,'1/1'); Zip.Add(Encoded,'2/0');
  finally Zip.Free; end;
  Sink:=TMemoryStream.Create;
  try RunExternalToolToStream(Settings.AppPath+'tools\7zip\7za.exe',
    ['a','-t7z','-ms=off',Container,Root+'\1.fb2',Root+'\2.epub'],Sink);
  finally Sink.Free; end;
  OriginalBytes:=TFile.ReadAllBytes(Original);
  Book:=Default(TBookRecord); Book.Folder:=Container; Book.FileName:='1'; Book.FileExt:='.fb2';
  Book.LibID:='jpeg-reconstruct-fb2';
  Prepared:=PrepareReaderFile(Book,True);
  Fb2:=TFile.ReadAllText(Prepared,TEncoding.UTF8);
  Require(Fb2.Contains('Complete JPEG illustration text.') and
    Fb2.Contains('content-type="image/jpeg">'+TNetEncoding.Base64.EncodeBytesToString(OriginalBytes)+'</binary>'),
    'Reading preparation did not reconstruct the exact FB2 JPEG');
  Prepared:=PrepareConversionSource(Book,nil,'.fb2');
  Require(TFile.ReadAllText(Prepared,TEncoding.UTF8)=Fb2,'Saving preparation changed the recovered FB2 JPEG');
  Book.FileName:='2'; Book.FileExt:='.epub'; Book.LibID:='jpeg-reconstruct-epub';
  Prepared:=PrepareConversionSource(Book,nil,'.epub');
  Zip:=TZipFile.Create;
  try
    Zip.Open(Prepared,zmRead); Zip.Read('OPS/picture.jpg',Bytes);
    Require((Length(Bytes)>0) and (Length(Bytes)=Length(OriginalBytes)) and
      CompareMem(@Bytes[0],@OriginalBytes[0],Length(Bytes)),
      'Restored EPUB JPEG differs from its original bytes');
  finally Zip.Free; end;
  Document:=TReaderDocument.Create;
  try
    Document.Load(Prepared);
    Require((Document.ImageCount=1) and Document.PlainText.Contains('Complete EPUB text.'),
      'The EPUB reader could not display the recovered JPEG and text');
  finally Document.Free; end;
  Writeln('PASS FLibrary reconstructs exact JPEG bytes in native FB2 and EPUB reading and export preparation');
end;

{$I FLibraryTextOnlyTests.inc}

procedure TestFLibraryQualityExport(const Collection: IBookCollection);
const WebPSample='UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D';
var Book: TBookRecord; Root, Prepared, Target, OriginalImageHash, ContainerHash,
  PreparedHash, ImageHash: string; Images: Integer; Warnings: TStringList;
  Stream: TStream; Zip: TZipFile; Bytes: TBytes; Document: TReaderDocument;
  TrackUsage: Boolean; Usage: TJSONObject;
  procedure CompressLargeIllustration;
  var Bitmap: TBitmap; PNG: TPngImage; Encoded: TMemoryStream; Row: PByteArray;
    Seed: Cardinal; InputName, OutputName, SourceHash: string; Image: TBytes;
  begin
    Bitmap:=TBitmap.Create; PNG:=TPngImage.Create; Encoded:=TMemoryStream.Create;
    try
      Bitmap.PixelFormat:=pf24bit; Bitmap.SetSize(1200,900); Seed:=41;
      for var Y:=0 to Bitmap.Height-1 do
      begin
        Row:=Bitmap.ScanLine[Y];
        for var X:=0 to Bitmap.Width*3-1 do
        begin
          Seed:=Cardinal((UInt64(Seed)*1664525+1013904223) and $FFFFFFFF);
          Row^[X]:=Byte(Seed shr 24);
        end;
      end;
      PNG.Assign(Bitmap); PNG.SaveToStream(Encoded); SetLength(Image,Encoded.Size);
      Encoded.Position:=0; Encoded.ReadBuffer(Image[0],Length(Image));
    finally Encoded.Free; PNG.Free; Bitmap.Free; end;
    Require(Length(Image)>128*1024,'Compression fixture did not exceed the small-image shortcut');
    InputName:=Root+'\compression-source.fb2'; OutputName:=Root+'\compression-result.epub';
    TFile.WriteAllText(InputName,'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'+
      '<description><title-info><genre>nonf_publicism</genre><author><first-name>Native</first-name><last-name>Test</last-name></author>'+
      '<book-title>Compression test</book-title><lang>en</lang></title-info><document-info><author><nickname>Native test</nickname></author>'+
      '<date>2026-11-03</date><id>native-compression-test</id><version>1.0</version></document-info></description>'+
      '<body><section><p>Complete compression test text.</p><image l:href="#large"/></section></body>'+
      '<binary id="large" content-type="image/png">'+TNetEncoding.Base64.EncodeBytesToString(Image)+'</binary></FictionBook>',TEncoding.UTF8);
    SourceHash:=UpdateSHA256(InputName);
    ConvertBasicBook(Settings.AppPath,Settings.TempPath,InputName,'.fb2',OutputName,nil,nil,nil,'','','',False,nil,'economy');
    Require(ComponentLastUse(Settings.AppPath,'ImageProcessing')>0,'Actual compression helper use was not recorded');
    Require(UpdateSHA256(InputName)=SourceHash,'Image compression changed its source book');
    Document:=TReaderDocument.Create;
    try
      Document.Load(OutputName);
      Require((Document.ImageCount=1) and Document.PlainText.Contains('Complete compression test text.'),'Compressed book lost text or its illustration');
    finally Document.Free;end;
  end;
begin
  TrackUsage:=GetEnvironmentVariable('HOMELIB_TEST_IMAGE_USAGE')='1';
  if TrackUsage then
  begin
    ConfigureComponentUsage(Settings.AppPath);
    for var ID in ['JPEG XL','WebP','ImageProcessing','BookProcessing'] do
      Require(ComponentLastUse(Settings.AppPath,ID)=0,'Image usage fixture already has actual-use records: '+ID);
    Bytes:=ConvertWebPToPNG(TNetEncoding.Base64.DecodeStringToBytes(WebPSample));
    Require((Length(Bytes)>8) and (Bytes[0]=$89) and (ComponentLastUse(Settings.AppPath,'WebP')>0),
      'Actual WebP decoding did not renew its module use');
  end;
  TestFeedback529JXL(Collection);
  TestFLibraryJpegReconstruction;
  if TrackUsage then Require(ComponentLastUse(Settings.AppPath,'JPEG XL')>0,'Actual FLibrary restoration did not record JPEG XL');
  Root:=Settings.AppPath+'feedback529-jxl';
  Book:=Default(TBookRecord); Book.Folder:=Root+'\alpha.7z';
  Book.FileName:='1'; Book.FileExt:='.fb2'; Book.LibID:='quality-flibrary';
  ContainerHash:=UpdateSHA256(Book.Folder);
  Prepared:=PrepareConversionSource(Book,nil,'.fb2');
  PreparedHash:=UpdateSHA256(Prepared); Images:=0;
  Stream:=TFileStream.Create(Prepared,fmOpenRead or fmShareDenyWrite);
  try VisitFB2Images(Stream,procedure(const Name: string; Image: TStream)
    begin Inc(Images); OriginalImageHash:=THashSHA2.GetHashString(Image); end);
  finally Stream.Free; end;
  Require(Images=1,'FLibrary conversion source omitted its restored JXL');
  Warnings:=TStringList.Create;
  try
    for var Extension in ['.fb2','.epub'] do for var Profile in ['high','none'] do
    begin
      Target:=Settings.AppPath+'quality-flibrary-'+Profile+Extension;
      ConvertBasicBook(Settings.AppPath,Settings.TempPath,Prepared,'.fb2',Target,nil,
        Warnings,nil,'','','',False,nil,'ask',
        function(const Options: TBookImageQualityOptions): string
        begin
          Require(Options.NoImagesBytes>0,'FLibrary text-only size was not offered');
          Result:=Profile;
        end);
      Images:=0; ImageHash:='';
      if Extension='.fb2' then
      begin
        Stream:=TFileStream.Create(Target,fmOpenRead or fmShareDenyWrite);
        try VisitFB2Images(Stream,procedure(const Name: string; Image: TStream)
          begin Inc(Images); ImageHash:=THashSHA2.GetHashString(Image); end);
        finally Stream.Free; end;
      end
      else
      begin
        Zip:=TZipFile.Create;
        try
          Zip.Open(Target,zmRead);
          for var I:=0 to Zip.FileCount-1 do
            if SameText(ExtractFileExt(Zip.FileNames[I]),'.png') then
            begin
              Zip.Read(I,Bytes); Stream:=TBytesStream.Create(Bytes);
              try Inc(Images); ImageHash:=THashSHA2.GetHashString(Stream);
              finally Stream.Free; end;
            end;
        finally Zip.Free; end;
      end;
      if Profile='none' then Require(Images=0,'FLibrary text-only export retained an image')
      else Require((Images=1) and (ImageHash=OriginalImageHash),
        'Quality-aware FLibrary export changed alpha or dropped the restored illustration');
      Document:=TReaderDocument.Create;
      try
        Document.Load(Target);
        Require(Document.ImageCount=Ord(Profile<>'none'),'FLibrary export image choice was not preserved');
        Require(Document.PlainText.Contains('Текст с иллюстрацией'),'FLibrary text-only export lost the book text');
      finally Document.Free; end;
    end;
    Require((UpdateSHA256(Book.Folder)=ContainerHash) and (UpdateSHA256(Prepared)=PreparedHash),
      'FLibrary image-quality export changed its source');
  finally Warnings.Free; end;
  TestFLibraryExplicitTextOnlyExport(Book,Prepared);
  if TrackUsage then
  begin
    CompressLargeIllustration;
    Usage:=TJSONObject.Create;
    try
      for var ID in ['WebP','JPEG XL','ImageProcessing','BookProcessing'] do
      begin
        Require(ComponentLastUse(Settings.AppPath,ID)>0,'Actual image operation omitted module use: '+ID);
        Usage.AddPair(ID,TJSONBool.Create(True));
      end;
      for var ID in ['PDFium','DjVuLibre','DocSharp','Kindle','LegacyBooks','LegacyOffice','XPS','KindleExport','BookConverter','IBK'] do
        Require(ComponentLastUse(Settings.AppPath,ID)=0,'Image processing recorded an unrelated format module: '+ID);
      TFile.WriteAllText(Settings.AppPath+'image-component-usage.json',Usage.ToJSON,TEncoding.UTF8);
    finally Usage.Free;end;
    Writeln('PASS actual WebP JPEG XL and image-quality module use preserves source alpha and excludes unrelated format modules');Flush(Output);
  end;
  Writeln('PASS FLibrary JPEG XL quality-aware FB2 EPUB exports preserve alpha or remove pictures while retaining the complete text');
end;
