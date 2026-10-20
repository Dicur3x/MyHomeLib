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
  XML:='<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'+
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
