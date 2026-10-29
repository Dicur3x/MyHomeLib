procedure TestSaveDependencyFeedback;
const Picture='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==';
  Header='<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">';
var Empty, Upgrade, FB2, TextOnly, Namespaced, Epub, PDF, Djvu, Output, Mobi, Status:string;
  IDs:TArray<string>; Zip:TZipFile; Part:TStringStream; Bytes:TBytes; BeforeHash:string;
  Options:TBookSendOptions; Results:TBookExportResults; Plan:TBookSaveChoice;
  Worker:TBookSendEstimateThread; Items:TBookSaveEstimateItems; Revision:Integer; Complete, Raised, Ready:Boolean;
  Owner:TComponent; Started:UInt64;
  procedure Expect(const Values:TArray<string>; const Joined, Context:string);
  begin Require(String.Join('|',Values)=Joined,Context+': '+String.Join('|',Values)); end;
  procedure AddZip(const Name, Text:string);
  begin Part:=TStringStream.Create(Text,TEncoding.UTF8); try Zip.Add(Part,Name); finally Part.Free; end; end;
  function Missing(const Name, Extension:string; Images:Boolean=True):TArray<string>;
  begin Result:=MissingBookConversionComponents(Empty,Name,Extension,Images); end;
  procedure CheckEstimate;
  begin
    Plan:=Default(TBookSaveChoice); Plan.Mode:=emEpub;
    Worker:=TBookSendEstimateThread.Create([FileBook(FB2),FileBook(PDF)],Plan,Empty,Settings.TempPath);
    try
      Revision:=-1; Complete:=False; Worker.Start; Started:=GetTickCount64;
      repeat
        Application.ProcessMessages; Worker.Poll(Revision,Items,Status,Complete); Sleep(5);
        Require(GetTickCount64-Started<15000,'Dependency estimate timed out');
      until Complete;
      Require(not Assigned(Worker.FatalException),'Dependency estimate raised an unreported exception');
      Expect(Items[0].RequiredComponents,'BookProcessing|ImageProcessing','Illustrated FB2 estimate');
      Expect(Items[1].RequiredComponents,'BookProcessing|PDFium','PDF estimate');
      Expect(BookSaveMissingComponents(Items),'BookProcessing|ImageProcessing|PDFium','Complete distinct estimate requirements');
    finally Worker.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Empty:=Settings.AppPath+'dependency-empty'; ForceDirectories(Empty);
  FB2:=Settings.AppPath+'dependency-image.pdf'; TextOnly:=Settings.AppPath+'dependency-text.fb2';
  Namespaced:=Settings.AppPath+'dependency-utf16.fb2'; Epub:=Settings.AppPath+'dependency-archive.fb2';
  PDF:=Settings.AppPath+'dependency-pdf.epub'; Djvu:=Settings.AppPath+'dependency.djvu';
  Output:=Settings.AppPath+'dependency-output.epub'; Mobi:=Settings.AppPath+'dependency.mobi';
  TFile.WriteAllText(FB2,Header+'<body><section><p>Text</p><image l:href="#кот"/></section></body>'+
    '<binary id="кот" content-type="image/png">'+Picture+'</binary></FictionBook>',TEncoding.UTF8);
  BeforeHash:=UpdateSHA256(FB2);
  TFile.WriteAllText(TextOnly,Header+'<body><section><p><![CDATA[<image l:href="#picture"/>]]></p>'+
    '<!-- <image l:href="#picture"/> --><x:image xmlns:x="urn:foreign" l:href="#picture"/></section></body>'+
    '<binary id="picture" content-type="image/png">'+Picture+'</binary></FictionBook>',TEncoding.UTF8);
  TFile.WriteAllText(Namespaced,'<?xml version="1.0" encoding="UTF-16"?>'+
    '<b:FictionBook xmlns:b="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:y="http://www.w3.org/1999/xlink">'+
    '<b:body><b:section><b:image y:href="#ёж"/></b:section></b:body>'+
    '<b:binary id="ёж" content-type="image/jpeg">YWJj</b:binary></b:FictionBook>',TEncoding.Unicode);
  Zip:=TZipFile.Create;
  try
    Zip.Open(Epub,zmWrite); AddZip('mimetype','application/epub+zip');
    AddZip('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');
    AddZip('book.opf','<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="image" href="Images/p.png" media-type="image/png"/></manifest></package>');
    AddZip('Images/p.png',Picture);
  finally Zip.Free; end;
  TFile.WriteAllText(PDF,'%PDF-1.4'+#10+'% Owned minimal signature for preflight only',TEncoding.ASCII);
  TFile.WriteAllText(Djvu,'AT&TFORM'+#0#0#0#12+'DJVU',TEncoding.ASCII);
  Expect(Missing(FB2,'.pdf'),'BookProcessing|ImageProcessing','Content identification before decoder selection');
  Expect(Missing(TextOnly,'.fb2'),'BookProcessing','Comments CDATA unreferenced and foreign images');
  Expect(Missing(Namespaced,'.fb2'),'BookProcessing|ImageProcessing','Namespace and UTF-16 image references');
  Expect(Missing(Epub,'.fb2'),'BookProcessing|ImageProcessing','EPUB with misleading file extension');
  Expect(Missing(PDF,'.epub'),'BookProcessing|PDFium','Actual PDF does not install EPUB image processing speculatively');
  Expect(Missing(Djvu,'.djvu'),'BookProcessing|DjVuLibre|ImageProcessing','Known raster DjVu dependencies');
  Expect(Missing(FB2,'.pdf',False),'BookProcessing','Original image quality does not require an image transformer');
  CheckEstimate;
  Raised:=False;
  try ConvertBasicBook(Empty,Settings.TempPath,FB2,'.pdf',Output,nil,nil,nil,'','','',False,nil,'economy');
  except on E:EMHLComponentRequired do
  begin Raised:=True; Expect(E.ComponentIDs,'BookProcessing|ImageProcessing','Conversion preserves complete dependency list'); end; end;
  Require(Raised and not FileExists(Output),'Missing dependencies created an output');
  Upgrade:=Settings.AppPath+'dependency-upgrade';
  ForceDirectories(Upgrade+'\tools\python'); ForceDirectories(Upgrade+'\tools\bookconvert');
  TFile.WriteAllText(Upgrade+'\tools\python\python.exe','Owned inert fixture');
  TFile.WriteAllText(Upgrade+'\tools\bookconvert\convert_book.py','Owned inert fixture');
  TFile.WriteAllText(Upgrade+'\tools\bookconvert\MODULAR_API.txt','1');
  Require(ModularBookProcessingAvailable(Upgrade),'Old core fixture is not recognized');
  Raised:=False;
  try ConvertBasicBook(Upgrade,Settings.TempPath,FB2,'.pdf',Output,nil,nil,nil,'','','',False,nil,'economy');
  except on E:EMHLComponentRequired do
  begin Raised:=True; Expect(E.ComponentIDs,'BookProcessing|ImageProcessing','Core capability repair is batched with image processing'); end; end;
  Require(Raised and not FileExists(Output),'Old core capability ran a tool or created output before repair');
  Raised:=False;
  try ConvertBasicBook(Empty,Settings.TempPath,FB2,'.pdf',Output,nil,nil,nil,'','','',False,nil,'none');
  except on E:EMHLComponentRequired do
  begin Raised:=True; Expect(E.ComponentIDs,'BookProcessing','Removing FB2 pictures must not install image processing'); end; end;
  Require(Raised,'Removing FB2 pictures did not report the required core');
  Raised:=False;
  try ConvertBasicBook(Empty,Settings.TempPath,Djvu,'.djvu',Output,nil,nil,nil,'','','',False,nil,'none');
  except
    on E:EMHLComponentRequired do raise Exception.Create('An unsupported picture-free scan must not download components');
    on E:Exception do Raised:=Pos('распознать текст',E.Message)>0;
  end;
  Require(Raised and not FileExists(Output),'Picture-free scans did not explain the missing text before downloading');
  Output:=Settings.AppPath+'dependency-copy.fb2';
  ConvertBasicBook(Empty,Settings.TempPath,TextOnly,'.fb2',Output,nil,nil);
  Require(UpdateSHA256(Output)=UpdateSHA256(TextOnly),'Unchanged FB2 needs a processing module or changed bytes');
  Output:=Settings.AppPath+'dependency-copy.epub'; ConvertBasicBook(Empty,Settings.TempPath,Epub,'.epub',Output,nil,nil);
  Require(UpdateSHA256(Output)=UpdateSHA256(Epub),'Unchanged EPUB needs a processing module or changed bytes');
  Raised:=False;
  try MissingBookConversionComponents(Empty,FB2,'.fb2',True,function:Boolean begin Result:=True; end);
  except on E:EAbort do Raised:=True; end;
  Require(Raised,'Dependency scan ignores cancellation');
  Require(not ModularBookProcessingAvailable(Settings.AppPath),'Standalone dependency probe unexpectedly has the processing engine');
  Options:=Default(TBookSendOptions); Options.Folder:=Settings.AppPath+'dependency-saved';
  Options.Mode:=emEpub; Options.ExplicitFormat:=True; Options.ImageQuality:='economy'; Options.FileNameTemplate:='%t';
  Results:=SaveFileBook(FileBook(FB2),Options,IDs);
  Expect(IDs,'BookProcessing|ImageProcessing','Standalone export retains complete missing module list');
  Require((Length(Results)=1) and (Results[0].State<>besSucceeded),'Missing modules reported a successful export');
  SetLength(Bytes,200); FillChar(Bytes[0],Length(Bytes),0);
  Move(PAnsiChar(AnsiString('BOOKMOBI'))^,Bytes[60],8); Bytes[77]:=1; Bytes[81]:=86;
  Move(PAnsiChar(AnsiString('MOBI'))^,Bytes[102],4); Bytes[125]:=8; TFile.WriteAllBytes(Mobi,Bytes);
  Owner:=TComponent.Create(nil); IDs:=nil; Ready:=False;
  try
    PrepareReaderFileInBackground(Owner,FileBook(Mobi),True,procedure(Name:string) begin Ready:=True; end,
      False,True,False,nil,procedure(Required:TArray<string>) begin IDs:=Required; end);
    Started:=GetTickCount64;
    while ReaderPreparationsPending(Owner) do
    begin
      Application.ProcessMessages; CheckSynchronize(2); Sleep(5);
      Require(GetTickCount64-Started<10000,'Reader dependency preparation timed out');
    end;
    Expect(IDs,'BookProcessing|Kindle','Reading preparation retains both known Kindle requirements');
    Require(not Ready,'Reader opened a book without required modules');
  finally Owner.Free; end;
  Require(UpdateSHA256(FB2)=BeforeHash,'Dependency inspection changed the source book');
  Writeln('PASS one book reports known missing processing image and format modules together with content detection cancellation and unchanged copies');
end;
