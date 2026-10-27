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

{$I FLibraryTextOnlyTests.inc}

procedure TestFLibraryQualityExport(const Collection: IBookCollection);
var Book: TBookRecord; Root, Prepared, Target, OriginalImageHash, ContainerHash,
  PreparedHash, ImageHash: string; Images: Integer; Warnings: TStringList;
  Stream: TStream; Zip: TZipFile; Bytes: TBytes; Document: TReaderDocument;
begin
  TestFeedback529JXL(Collection);
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
  Writeln('PASS FLibrary JPEG XL quality-aware FB2 EPUB exports preserve alpha or remove pictures while retaining the complete text');
end;
