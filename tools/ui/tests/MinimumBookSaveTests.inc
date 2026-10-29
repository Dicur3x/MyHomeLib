procedure TestMinimumBookSaving;
const XML='<?xml version="1.0" encoding="utf-8"?>'+
  '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>'+
  '<book-title>Сохранение без модулей</book-title><lang>ru</lang></title-info></description>'+
  '<body><section><p>Полный текст. Ё, Україна, 中文.</p></section></body></FictionBook>';
var Root, FB2, EPUB, PDF, DjVu, DOC, Required, Member: string; ZIP: TZipFile;
  Probe: TUnifiedSendProbe; Options: TBookSendOptions; Results: TBookExportResults;
  SavedShowMainForm: Boolean;
  procedure Policy;
  var Choices: TArray<TBookSaveChoice>;
  begin
    Choices:=BookSaveChoices(['.fb2','.FB2']);
    Require((Length(Choices)=3) and Choices[0].KeepOriginal and Choices[1].KeepOriginal and
      (Choices[1].Mode=emFB2Zip) and (Choices[2].Mode=emEpub),'FB2 choices lost native ZIP or repeat conversion to FB2');
    Choices:=BookSaveChoices(['epub']);
    Require((Length(Choices)=3) and Choices[0].KeepOriginal and
      (Choices[1].Mode=emFB2) and (Choices[2].Mode=emFB2Zip),'EPUB choices repeat conversion to EPUB or lost FB2 ZIP');
    Choices:=BookSaveChoices(['.pdf','.djvu','.doc']);
    Require((Length(Choices)=4) and Choices[0].KeepOriginal,'Non-FB2/EPUB sources lost original copying');
    Choices:=BookSaveChoices(['.fb2','.epub','.pdf','.djvu']);
    Require((Length(Choices)=7) and Choices[4].KeepFB2EPUB and Choices[5].KeepFB2EPUB and Choices[6].KeepFB2EPUB,
      'Mixed set has no preference that keeps existing FB2 and EPUB');
    Require(BookSaveZipsTarget('.fb2',emFB2Zip) and not BookSaveZipsTarget('.epub',emFB2Zip,True) and
      not BookSaveZipsTarget('.pdf',emFB2,True),'ZIP packaging is not restricted to FB2');
    Require(BookSaveTargetExtension('.pdf',emFB2,True,False)='.pdf','Keep original converts PDF');
    Require(BookSaveTargetExtension('.epub',emFB2,False,True)='.epub','FB2 preference converts retained EPUB');
    Require(BookSaveTargetExtension('.pdf',emFB2,False,True)='.fb2','FB2 preference does not convert PDF');
    Require(BookSaveTargetExtension('.fb2',emEpub,False,True)='.fb2','EPUB preference converts retained FB2');
    Require(BookSaveTargetExtension('.djvu',emEpub,False,True)='.epub','EPUB preference does not convert DjVu');
    Writeln('PASS minimum save source-aware and mixed-format policy'); Flush(Output);
  end;
  procedure Mixed(const Name: string; const Sources: TArray<string>; Zipped, Prefer: Boolean; Mode: TExportMode;
    Subfolders: Boolean = False);
  var Books: TArray<TBookRecord>; Bytes: TBytes; Archive: TZipFile;
  begin
    SetLength(Books,Length(Sources));
    for var I:=0 to High(Sources) do
    begin
      Books[I]:=FileBook(Sources[I]);
      if Subfolders then
      begin
        if not (I mod 4 in [1,3]) then
        begin SetLength(Books[I].Authors,1); Books[I].Authors[0].FLastName:='Автор Ё '+IntToStr(I); end
        else SetLength(Books[I].Authors,0);
        if not (I mod 4 in [2,3]) then Books[I].Series:='Серия '+IntToStr(I) else Books[I].Series:='';
      end;
    end;
    Options:=Default(TBookSendOptions); Options.Folder:=TPath.Combine(Root,Name);
    ForceDirectories(Options.Folder); Options.FileNameTemplate:='%t';
    Options.ImageQuality:='original'; Options.Mode:=Mode;
    Options.KeepSourceFormat:=not Prefer; Options.KeepFB2EPUB:=Prefer;
    Options.ExplicitFormat:=Prefer; Options.ZipEachBook:=Zipped;
    if Subfolders then Options.FolderTemplate:='%f\%s';
    Probe.Deadline:=GetTickCount64+30000; Probe.Messages.Clear; Probe.Worker:=nil;
    Probe.Timer.Enabled:=True;
    try Results:=SaveFileBooks(Books,Options,Required);
    finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
    Require((Required='') and (Probe.Messages.Count=0) and (Probe.Failure=''),
      'Mixed unchanged batch required a module or failed: '+Required+Probe.Messages.Text+Probe.Failure);
    Require(Length(Results)=Length(Sources),'Mixed save lost per-book results');
    for var I:=0 to High(Results) do
    begin
      Require(Results[I].State=besSucceeded,'Mixed copy failed at book '+IntToStr(I));
      var Output:=Results[I].OutputFile;
      if Subfolders then
      begin
        var ExpectedFolder:=Options.Folder;
        if not (I mod 4 in [1,3]) then ExpectedFolder:=TPath.Combine(ExpectedFolder,'Автор Ё '+IntToStr(I));
        if not (I mod 4 in [2,3]) then ExpectedFolder:=TPath.Combine(ExpectedFolder,'Серия '+IntToStr(I));
        Require(SameFileName(ExtractFileDir(Output),ExpectedFolder),'Author/series folders ignore their mask or missing metadata');
      end
      else Require(SameFileName(ExtractFileDir(Output),Options.Folder),'Flat save unexpectedly created author folders');
      if BookSaveZipsTarget(ExtractFileExt(Sources[I]),Mode,Zipped) then
      begin
        Require(SameText(ExtractFileExt(Output),'.zip'),'Mixed ZIP copy is not a ZIP');
        Archive:=TZipFile.Create;
        try
          Archive.Open(Output,zmRead); Require(Archive.FileCount=1,'Mixed ZIP contains wrong member count');
          Require(SameText(ExtractFileExt(Archive.FileNames[0]),ExtractFileExt(Sources[I])),
            'Mixed ZIP leaked a previous book format');
          Archive.Read(Archive.FileNames[0],Bytes);
          var Hash:=THashSHA2.Create; Hash.Update(Bytes);
          Require(Hash.HashAsString=UpdateSHA256(Sources[I]),'Mixed ZIP changed the source bytes');
        finally Archive.Free; end;
      end
      else
      begin
        Require(SameText(ExtractFileExt(Output),ExtractFileExt(Sources[I])),
          'Mixed unchanged save leaked a previous book format');
        Require(UpdateSHA256(Output)=UpdateSHA256(Sources[I]),'Mixed copy changed the source bytes');
      end;
    end;
    Writeln('PASS minimum save mixed ',Name); Flush(Output);
  end;
  procedure Put(const Name, Text: string);
  var Input: TStringStream;
  begin
    Input:=TStringStream.Create(Text,TEncoding.UTF8);
    try ZIP.Add(Input,Name); finally Input.Free; end;
  end;
  procedure ArchivedMislabels;
  var Books: TArray<TBookRecord>; Archive, Before, Expected: string;
    Sources, Extensions: TArray<string>; Bytes: TBytes; Input: TFileStream;
  begin
    Archive:=TPath.Combine(Root,'mislabelled.zip');
    Sources:=[EPUB,FB2,PDF,DjVu,EPUB];
    Extensions:=['.epub','.fb2','.pdf','.djvu','.epub'];
    ZIP:=TZipFile.Create;
    try
      ZIP.Open(Archive,zmWrite); SetLength(Books,Length(Sources));
      for var I:=0 to High(Sources) do
      begin
        Books[I]:=FileBook(Sources[I]); Books[I].Folder:=ExtractFileName(Archive);
        Books[I].FileName:='member-'+IntToStr(I); Books[I].FileExt:='.bin';
        Books[I].InsideNo:=I;
        // The last source is a document ZIP with a dedicated declared identity.
        // It must be copied as a book container, never opened as a loose ZIP.
        if I=High(Sources) then Books[I].FileExt:='.cbz';
        Input:=TFileStream.Create(Sources[I],fmOpenRead or fmShareDenyWrite);
        try ZIP.Add(Input,Books[I].FileName+Books[I].FileExt); finally Input.Free; end;
      end;
    finally ZIP.Free; end;
    Before:=UpdateSHA256(Archive);
    for var Zipped in [False,True] do
    begin
      Options:=Default(TBookSendOptions); Options.Folder:=TPath.Combine(Root,'archived-'+BoolToStr(Zipped,True));
      ForceDirectories(Options.Folder); Options.Mode:=emFB2; Options.KeepSourceFormat:=True;
      Options.ImageQuality:='original'; Options.ZipEachBook:=Zipped;
      Probe.Deadline:=GetTickCount64+30000; Probe.Messages.Clear; Probe.Worker:=nil;
      Probe.Timer.Enabled:=True;
      try Results:=SaveFileBooks(Books,Options,Required);
      finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
      Require((Required='') and (Probe.Messages.Count=0) and (Probe.Failure=''),
        'Archived original copy required a decoder: '+Required+Probe.Messages.Text+Probe.Failure);
      Require(Length(Results)=Length(Sources),'Archived copy lost per-book results');
      for var I:=0 to High(Results) do
      begin
        Require(Results[I].State=besSucceeded,'Archived original copy failed');
        Expected:=Extensions[I];
        if BookSaveZipsTarget(Expected,Options.Mode,Zipped) then
        begin
          ZIP:=TZipFile.Create;
          try
            ZIP.Open(Results[I].OutputFile,zmRead);
            Require((ZIP.FileCount=1) and SameText(ExtractFileExt(ZIP.FileNames[0]),Expected),
              'Archived original ZIP did not use its detected book extension');
            ZIP.Read(ZIP.FileNames[0],Bytes);
            var Hash:=THashSHA2.Create; Hash.Update(Bytes);
            Require(Hash.HashAsString=UpdateSHA256(Sources[I]),'Archived original ZIP changed book bytes');
          finally ZIP.Free; end;
        end
        else
        begin
          Require(SameText(ExtractFileExt(Results[I].OutputFile),Expected),'Archived original kept the wrong extension');
          Require(UpdateSHA256(Results[I].OutputFile)=UpdateSHA256(Sources[I]),'Archived original changed book bytes');
        end;
      end;
      Require(UpdateSHA256(Archive)=Before,'Saving modified the source collection archive');
    end;
    // A generic comic ZIP has no EPUB marker, so its strong container label
    // survives content sniffing in both direct and archived source paths.
    var Comic:=TPath.Combine(Root,'comic.cbz');
    ZIP:=TZipFile.Create;
    try ZIP.Open(Comic,zmWrite); Put('one.png','opaque test image'); finally ZIP.Free; end;
    Require(BookSaveKnownExtension(FileBook(Comic))='.cbz','Generic ZIP signature erased comic identity');
    ZIP:=TZipFile.Create;
    try ZIP.Open(Archive,zmWrite); ZIP.Add(Comic,'comic.cbz'); finally ZIP.Free; end;
    var Book:=FileBook(Comic); Book.Folder:=ExtractFileName(Archive);
    var Actual: string;
    var Stream:=OpenArchivedBookSaveSource(Book,Actual);
    try Require((Actual='.cbz') and (Stream.Size=TFile.GetSize(Comic)),'Archived comic was unpacked or relabelled');
    finally Stream.Free; end;
    Writeln('PASS minimum save archived mislabels and original book containers without converter'); Flush(Output);
  end;
  procedure Save(const Source, Name: string; Mode: TExportMode; Keep: Boolean;
    const Quality: string; Missing: Boolean; Zipped: Boolean = False);
  var Before: string; Bytes: TBytes;
  begin
    Before:=UpdateSHA256(Source); Options:=Default(TBookSendOptions);
    Options.Folder:=TPath.Combine(Root,Name); ForceDirectories(Options.Folder);
    Options.Mode:=Mode; Options.KeepSourceFormat:=Keep; Options.ExplicitFormat:=not Keep;
    Options.ImageQuality:=Quality;
    Probe.Deadline:=GetTickCount64+30000; Probe.Messages.Clear; Probe.Worker:=nil;
    Probe.Timer.Enabled:=True;
    try Results:=SaveFileBook(FileBook(Source),Options,Required);
    finally Probe.Timer.Enabled:=False; Probe.Worker:=nil; end;
    Require(Probe.Failure='',Probe.Failure);
    Require(UpdateSHA256(Source)=Before,'Minimal save modified the source book');
    if Missing then
    begin
      Require(Required='BookProcessing','A genuine conversion/image edit did not report its missing module');
      Require(Length(TDirectory.GetFiles(Options.Folder,'*'))=0,'Missing conversion module published a file');
      Require(Probe.Messages.Count=0,'Missing module was shown as an export failure before its install prompt');
    end
    else
    begin
      Require((Required='') and (Length(Results)=1) and (Results[0].State=besSucceeded),
        'An unchanged FB2/EPUB required conversion: '+Probe.Messages.Text);
      if Zipped then
      begin
        ZIP:=TZipFile.Create;
        try
          ZIP.Open(Results[0].OutputFile,zmRead); Require(ZIP.FileCount=1,'ZIP includes extra files');
          Member:=ZIP.FileNames[0]; Require(SameText(ExtractFileExt(Member),ExtractFileExt(Source)),'ZIP changed the book format');
          ZIP.Read(Member,Bytes);
          var Hash:=THashSHA2.Create; Hash.Update(Bytes);
          Require(Hash.HashAsString=Before,'ZIP did not preserve the exact book bytes');
        finally ZIP.Free; end;
      end
      else Require(UpdateSHA256(Results[0].OutputFile)=Before,'Unchanged save modified original bytes');
    end;
    Writeln('PASS minimum save ',Name); Flush(Output);
  end;
begin
  RequireIsolatedRegression;
  Require(not FileExists(Settings.AppPath+'tools/kindle/python/python.exe'),'Minimal save fixture includes the converter');
  Require(not DirectoryExists(Settings.AppPath+'tools/doc') and not DirectoryExists(Settings.AppPath+'tools/djvu'),
    'Minimal save fixture includes optional native adapters');
  Root:=TPath.Combine(Settings.AppPath,'minimum-save'); ForceDirectories(Root);
  Policy;
  FB2:=TPath.Combine(Root,'Книга Ё.fb2'); EPUB:=TPath.Combine(Root,'Книга Ё.epub');
  TFile.WriteAllText(FB2,XML,TEncoding.UTF8);
  ZIP:=TZipFile.Create;
  try
    ZIP.Open(EPUB,zmWrite); Put('mimetype','application/epub+zip');
    Put('META-INF/container.xml','<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');
    Put('OEBPS/book.opf','<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Книга Ё</dc:title><dc:identifier id="id">minimum-save</dc:identifier><dc:language>ru</dc:language></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>');
    Put('OEBPS/text.xhtml','<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Полный текст. Ё, Україна, 中文.</p></body></html>');
  finally ZIP.Free; end;
  // Native copying must not need a decoder, even for an unreadable or unusual
  // document: its contract is to preserve the selected source bytes.
  PDF:=TPath.Combine(Root,'Исходный.pdf'); DjVu:=TPath.Combine(Root,'Исходный.djvu');
  DOC:=TPath.Combine(Root,'Исходный.doc');
  TFile.WriteAllText(PDF,'%PDF-1.4'+#10+'% Native unchanged copy fixture',TEncoding.ASCII);
  TFile.WriteAllBytes(DjVu,TBytes.Create($41,$54,$26,$54,$46,$4F,$52,$4D,0,0,0,4,$44,$4A,$56,$55));
  TFile.WriteAllBytes(DOC,TBytes.Create($D0,$CF,$11,$E0,$A1,$B1,$1A,$E1,0,0,0,0));
  Probe:=TUnifiedSendProbe.Create; Probe.Messages:=TStringList.Create;
  SavedShowMainForm:=Application.ShowMainForm;
  try
    Probe.Timer:=TTimer.Create(nil); Probe.Timer.Interval:=50; Probe.Timer.OnTimer:=Probe.Tick;
    Probe.SavedModal:=Application.OnModalBegin; Application.OnModalBegin:=Probe.ModalBegin;
    Save(FB2,'fb2-explicit-original',emFB2,False,'original',False);
    Save(EPUB,'epub-explicit-original',emEpub,False,'original',False);
    Save(FB2,'fb2-keep-original',emFB2,True,'original',False);
    Save(EPUB,'epub-keep-original',emFB2,True,'original',False);
    Save(FB2,'fb2-native-zip',emFB2Zip,False,'original',False,True);
    Save(EPUB,'epub-legacy-zip-ignored',emEpubZip,False,'original',False);
    Save(EPUB,'epub-keep-zip-ignored',emFB2Zip,True,'original',False);
    Save(FB2,'fb2-to-epub-offer',emEpub,False,'original',True);
    Save(FB2,'fb2-images-offer',emFB2,False,'economy',True);
    Mixed('five-original-formats',[EPUB,FB2,PDF,DjVu,DOC,FB2],False,False,emFB2);
    Mixed('five-native-zip-formats',[EPUB,FB2,PDF,DjVu,DOC,EPUB],True,False,emFB2);
    Mixed('keep-readable-prefer-fb2',[EPUB,FB2,EPUB],False,True,emFB2);
    Mixed('keep-readable-prefer-epub-zip',[FB2,EPUB,FB2],True,True,emEpub);
    Mixed('custom-folders',[EPUB,FB2,PDF,DjVu],False,False,emFB2,True);
    Mixed('custom-folders-zip',[FB2,EPUB,DjVu,PDF],True,False,emEpub,True);
    ArchivedMislabels;
    Require(not FileExists(Settings.AppPath+'tools/7zip/7z.exe'),'Native ZIP fixture unexpectedly has 7-Zip');
    Writeln('PASS minimum save byte-exact FB2 EPUB and native ZIP without converter or 7-Zip; real changes report one missing-module request');
  finally
    Application.OnModalBegin:=Probe.SavedModal; Application.ShowMainForm:=SavedShowMainForm;
    Probe.Timer.Free; Probe.Messages.Free; Probe.Free;
  end;
end;
