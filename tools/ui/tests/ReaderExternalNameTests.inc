// Optional native mode external-reader-names. No external app is launched.
// Original files/history/profiles remain protected in this private G fixture.
procedure TestExternalReaderNames;
var
  Root, Source, OtherSource, CacheRoot, Named, OtherNamed, Canonical, Occupied,
    HistoryFile, NotesFile, HistoryName, AsyncResult: string;
  Book, Other, Reimported, Document: TBookRecord;
  ProtectedNames, ProtectedHashes: TArray<string>;
  Locked: TFileStream; Writer: TBookCacheWrite; Owner: TComponent;
  Finished, Rejected: Boolean; Started: UInt64;
  SavedLimit: Integer; SavedOverwrite: Boolean;

  procedure Protect(const Name: string);
  begin
    for var I:=0 to High(ProtectedNames) do
      if ProtectedNames[I]=Name then
      begin ProtectedHashes[I]:=THashSHA2.GetHashStringFromFile(Name); Exit; end;
    ProtectedNames:=ProtectedNames+[Name];
    ProtectedHashes:=ProtectedHashes+[THashSHA2.GetHashStringFromFile(Name)];
  end;

  procedure Unchanged;
  begin
    for var I:=0 to High(ProtectedNames) do
      Require(FileExists(ProtectedNames[I]) and
        (THashSHA2.GetHashStringFromFile(ProtectedNames[I])=ProtectedHashes[I]),
        'External filename preparation changed protected source/history/profile: '+ProtectedNames[I]);
  end;

  procedure CheckName(const Name, Extension: string);
  var Base: string; Ch: Char;
  begin
    Base:=ExtractFileName(Name);
    Require(TPath.GetFullPath(Name).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(CacheRoot)),True),
      'Friendly external filename escaped the private cache');
    Require(Base.StartsWith('homelib-') and not Base.Contains('.pending'),
      'Friendly external filename lost cache ownership or became a pending file');
    Require(SameText(ExtractFileExt(Name),Extension),'Friendly filename lost the actual prepared extension');
    Require(Length(Name)+Length('.source.pending-4294967295-4294967295-{00000000-0000-0000-0000-000000000000}')<MAX_PATH,
      'Friendly filename leaves no bounded Windows path for atomic publication');
    for var I:=1 to Length(Base) do
    begin
      Ch:=Base[I];
      Require((Ord(Ch)>=32) and not CharInSet(Ch,['<','>',':','/','\','|','?','*']),
        'Friendly filename contains a control/path character');
      if (Ord(Ch)>=$D800) and (Ord(Ch)<=$DBFF) then
        Require((I<Length(Base)) and (Ord(Base[I+1])>=$DC00) and (Ord(Base[I+1])<=$DFFF),
          'Friendly filename splits a high UTF16 surrogate');
      if (Ord(Ch)>=$DC00) and (Ord(Ch)<=$DFFF) then
        Require((I>1) and (Ord(Base[I-1])>=$D800) and (Ord(Base[I-1])<=$DBFF),
          'Friendly filename splits a low UTF16 surrogate');
    end;
  end;

  procedure MakeCanonical(const Original, Extension, Payload: string; out Name: string; ProtectOutput: Boolean = True);
  var Temporary, TemporaryStamp: string;
  begin
    Name:=TPath.Combine(CacheRoot,'homelib-native-'+TGUID.NewGuid.ToString+Extension);
    Writer:=TBookCacheWrite.Create(Original);
    try
      Temporary:=Writer.TemporaryName(Name); TemporaryStamp:=Writer.TemporaryName(Name+'.source');
      TFile.WriteAllText(Temporary,Payload,TEncoding.UTF8);
      TFile.WriteAllText(TemporaryStamp,'Private canonical preparation',TEncoding.UTF8);
      Writer.Publish(Temporary,Name,TemporaryStamp);
    finally Writer.Free; end;
    if ProtectOutput then begin Protect(Name); Protect(Name+'.source'); Protect(Name+'.origin'); end;
  end;

  procedure CheckOriginalFB2Rewrite(const BaseName: string);
  const BodyText='Неприкосновенный текст тела ё ї ў.';
    OriginalTitle='Исходное название FB2';
  var SourceName, CopyName, DefaultName, Prepared, OutputText, SavedHeader, AsyncCopy: string;
    FB2Book: TBookRecord; Description: IXMLFictionBook; Stream: TStream;
    SavedConvert, SavedRewrite, AsyncFinished: Boolean; CopyOwner: TComponent; CopyStarted: UInt64;
  begin
    SourceName:=TPath.Combine(Root,BaseName+'.fb2');
    TFile.WriteAllText(SourceName,
      '<?xml version="1.0" encoding="utf-8"?>'+
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'+
      '<description><title-info><genre>sf</genre><author><first-name>Исходный</first-name><last-name>Автор</last-name></author>'+
      '<book-title>'+OriginalTitle+'</book-title><annotation><p>Исходная аннотация ё.</p></annotation><lang>ru</lang>'+
      '<sequence name="Исходная серия" number="3"/><sequence name="Дополнительная серия" number="4"/></title-info>'+
      '<document-info><author><first-name>Составитель</first-name></author><program-used>Native private fixture</program-used>'+
      '<date value="2026-10-14">14 октября 2026</date><id>external-name-original-id</id><version>1.0</version></document-info></description>'+
      '<body><section><title><p>Неизменяемая глава</p></title><p>'+BodyText+'</p><p><emphasis>Неизменяемый стиль</emphasis></p>'+
      '<image l:href="#protected-binary"/></section></body><binary id="protected-binary" content-type="image/png">YWJjZA==</binary></FictionBook>',
      TEncoding.UTF8); Protect(SourceName);
    FB2Book:=Book; FB2Book.FileName:=BaseName; FB2Book.FileExt:='.fb2';
    FB2Book.Title:='Название из каталога ё ї ў'; FB2Book.Authors:=nil;
    TAuthorsHelper.Add(FB2Book.Authors,'Тестов','Иван','');
    FB2Book.Genres:=nil; TGenresHelper.Add(FB2Book.Genres,'sf','Фантастика','sf');
    FB2Book.Series:='Серия каталога ё'; FB2Book.SeqNumber:=9;
    SavedConvert:=Settings.ConvertWebPToPNG; SavedRewrite:=Settings.OverwriteFB2Info;
    SavedHeader:=Settings.BookHeaderTemplate;
    Settings.ConvertWebPToPNG:=False; Settings.OverwriteFB2Info:=True; Settings.BookHeaderTemplate:='%t';
    try
      Prepared:=PrepareReaderFile(FB2Book,False);
      Require(SameFileName(Prepared,SourceName),'Plain FB2 no-WebP setup did not reproduce direct original preparation');
      DefaultName:=PrepareExternalReaderFile(FB2Book,Prepared,'',False);
      CopyName:=PrepareExternalReaderFile(FB2Book,Prepared,'',True); CheckName(CopyName,'.fb2');
      Require(not SameFileName(CopyName,SourceName) and not SameFileName(CopyName,Prepared) and
        not SameFileName(CopyName,DefaultName),'Rewrite FB2 shares its original, prepared input, or non-rewrite alias');
      Require(THashSHA2.GetHashStringFromFile(CopyName)=THashSHA2.GetHashStringFromFile(SourceName),
        'Forced rewrite copy changed body/metadata before the real writer'); Unchanged;
      Require(WriteFb2InfoToFile(FB2Book,CopyName),'Real FB2 metadata writer failed on its private valid copy');
      Stream:=TFileStream.Create(CopyName,fmOpenRead or fmShareDenyWrite);
      try
        Description:=LoadFB2Description(Stream);
        Require(Description.Description.Titleinfo.Booktitle.Text=FB2Book.Title,'Private rewrite copy title was not updated');
        Require((Description.Description.Titleinfo.Author.Count=1) and
          (Description.Description.Titleinfo.Author[0].Lastname.Text='Тестов'),'Private rewrite copy author was not updated');
        Require((Description.Description.Titleinfo.Sequence.Count=2) and
          (Description.Description.Titleinfo.Sequence[0].Name=FB2Book.Series) and
          (Description.Description.Titleinfo.Sequence[0].Number=9) and
          (Description.Description.Titleinfo.Sequence[1].Name='Дополнительная серия'),
          'Private rewrite changed additional series or missed the requested primary metadata');
        Require(Description.Description.Documentinfo.Id='external-name-original-id','Private rewrite changed stable document identity');
        Require(GetBookAnnotation(Description).Contains('Исходная аннотация ё.'),'Private rewrite lost annotation');
      finally Description:=nil; Stream.Free; end;
      OutputText:=TFile.ReadAllText(CopyName,TEncoding.UTF8);
      Require(OutputText.Contains(BodyText) and OutputText.Contains('Неизменяемая глава') and
        OutputText.Contains('<emphasis>Неизменяемый стиль</emphasis>') and OutputText.Contains('YWJjZA=='),
        'Private rewrite changed body, style or embedded binary'); Unchanged;
      Require(PrepareExternalReaderFile(FB2Book,Prepared,'',False)=DefaultName,
        'Turning rewrite off reused the rewritten alias');
      Require(THashSHA2.GetHashStringFromFile(DefaultName)=THashSHA2.GetHashStringFromFile(SourceName),
        'Non-rewrite opening contains the rewritten title instead of original bytes');
      Require((PrepareExternalReaderFile(FB2Book,Prepared,'',True)=CopyName) and
        (THashSHA2.GetHashStringFromFile(CopyName)=THashSHA2.GetHashStringFromFile(SourceName)),
        'Repeated forced copy retained an earlier rewritten title or changed its stable path'); Unchanged;
      CopyOwner:=TComponent.Create(nil); AsyncFinished:=False; AsyncCopy:=''; CopyStarted:=GetTickCount64;
      try
        PrepareExternalReaderFileInBackground(CopyOwner,FB2Book,Prepared,'',
          procedure(FileName: string) begin AsyncCopy:=FileName; AsyncFinished:=True; end,True);
        // A later settings change must not change captured rewrite intent.
        Settings.OverwriteFB2Info:=False;
        while not AsyncFinished and (GetTickCount64-CopyStarted<5000) do
        begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
        Require(AsyncFinished and (AsyncCopy=CopyName) and not SameFileName(AsyncCopy,SourceName),
          'Background forced copy lost captured rewrite intention after settings changed');
        Require(THashSHA2.GetHashStringFromFile(AsyncCopy)=THashSHA2.GetHashStringFromFile(SourceName),
          'Background rewrite preparation changed original body bytes');
      finally CopyOwner.Free; end; Unchanged;
    finally
      Settings.ConvertWebPToPNG:=SavedConvert; Settings.OverwriteFB2Info:=SavedRewrite;
      Settings.BookHeaderTemplate:=SavedHeader;
    end;
    Writeln('PASS real FB2 rewrite changes only private copy for ',BaseName,
      '; original/body/style/additional series/history/settings remain intact');
  end;

begin
  RequireIsolatedRegression;
  Root:=TPath.Combine(Settings.AppPath,'external-names-'+TGUID.NewGuid.ToString); ForceDirectories(Root);
  CacheRoot:=BookCachePath;
  Require(TPath.GetFullPath(Root).StartsWith('G:\',True) and TPath.GetFullPath(CacheRoot).StartsWith('G:\',True),
    'External filename gate must stay on private G');
  if FileExists(Settings.AppPath+'myhomelib2.ini') then Protect(Settings.AppPath+'myhomelib2.ini');
  Source:=TPath.Combine(Root,'0017.txt');
  TFile.WriteAllText(Source,'Source A: ё, ї, ў 😀'+sLineBreak+'Exact original bytes.',TEncoding.UTF8); Protect(Source);
  Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo; Book.BookKey:=CreateBookKey(1,900001);
  Book.CollectionRoot:=IncludeTrailingPathDelimiter(Root); Book.FileName:='0017'; Book.FileExt:='.txt';
  Book.Title:='Привет, Каролинка! ё ї ў 😀'; Book.LibID:='42'; Include(Book.BookProps,bpIsLocal);
  TAuthorsHelper.Add(Book.Authors,'Крюгер','Мария','');
  HistoryName:=ReaderHistoryName(Book,''); HistoryFile:=TPath.Combine(Root,'reader.ini'); NotesFile:=TPath.Combine(Root,'reader-notes.json');
  TFile.WriteAllText(HistoryFile,'[Book.'+THashSHA2.GetHashString(HistoryName)+']'+sLineBreak+'Position=12345',TEncoding.UTF8);
  TFile.WriteAllText(NotesFile,'{"note":"Keep exact ё ї ў 😀 thought"}',TEncoding.UTF8); Protect(HistoryFile); Protect(NotesFile);
  Named:=PrepareExternalReaderFile(Book,Source,''); CheckName(Named,'.txt');
  Require(ExtractFileName(Named).StartsWith('homelib-Привет, Каролинка!'),
    'External reader still receives a checksum instead of the title first');
  Require(ExtractFileName(Named).Contains('Крюгер'),'External title lost its short author name');
  Require(THashSHA2.GetHashStringFromFile(Named)=THashSHA2.GetHashStringFromFile(Source),'Friendly alias changed original bytes');
  Require(TPath.GetFullPath(BookCacheSource(Named))=TPath.GetFullPath(Source),'Friendly alias lost real source provenance'); Unchanged;
  Locked:=TFileStream.Create(Source,fmOpenRead or fmShareExclusive);
  try Require(PrepareExternalReaderFile(Book,Source,'')=Named,'Cache hit reopens bytes or changes its filename');
  finally Locked.Free; end;
  Reimported:=Book; Reimported.BookKey.BookID:=987654;
  Require((PrepareExternalReaderFile(Reimported,Source,'')=Named) and
    (ReaderHistoryName(Reimported,'')=HistoryName),'Reimported BookID changed external or internal reading identity'); Unchanged;
  Reimported.Title:='Исправленное название каталога'; Reimported.Authors:=nil;
  TAuthorsHelper.Add(Reimported.Authors,'Исправленный','Автор','');
  Require((PrepareExternalReaderFile(Reimported,Source,'')=Named) and
    (ReaderHistoryName(Reimported,'')=HistoryName),
    'Catalogue title/author edit broke an external filename or reading identity'); Unchanged;
  Writeln('PASS external title-first Unicode name, source provenance, locked-source warm hit and stable reimport/history');

  OtherSource:=TPath.Combine(Root,'0018.txt'); TFile.WriteAllText(OtherSource,'Different source B, never A.',TEncoding.UTF8); Protect(OtherSource);
  Other:=Book; Other.BookKey.BookID:=2; Other.FileName:='0018';
  OtherNamed:=PrepareExternalReaderFile(Other,OtherSource,'');
  Require((OtherNamed<>Named) and
    (THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(OtherSource)),
    'Same title/raw LibID selected another physical book');
  Require(PrepareExternalReaderFile(Book,Source,'flibusta')<>PrepareExternalReaderFile(Book,Source,'librusec'),
    'Raw IDs from different source namespaces share external filenames');
  Reimported:=Book; Reimported.BookKey.DatabaseID:=900002;
  Require(PrepareExternalReaderFile(Reimported,Source,'')<>Named,'Different collection IDs share an external alias'); Unchanged;
  Writeln('PASS equal titles/raw IDs remain separate by physical book, source namespace and collection');

  // Changed prepared bytes refresh the same reading path, never the original.
  TFile.WriteAllText(Source,'Updated authorized fixture source A with a different size, ё ї ў.',TEncoding.UTF8); Protect(Source);
  Require((PrepareExternalReaderFile(Book,Source,'')=Named) and
    (THashSHA2.GetHashStringFromFile(Named)=THashSHA2.GetHashStringFromFile(Source)),
    'Source change kept stale external bytes or changed a stable reading path'); Unchanged;
  Other.Title:='Occupied name test'; Occupied:=PrepareExternalReaderFile(Other,OtherSource,'');
  TFile.WriteAllText(Occupied,'Foreign occupied cache filename must remain intact.',TEncoding.UTF8);
  TFile.WriteAllText(Occupied+'.source','A different full identity, not this book.',TEncoding.UTF8);
  Protect(Occupied); Protect(Occupied+'.source');
  OtherNamed:=PrepareExternalReaderFile(Other,OtherSource,'');
  Require((OtherNamed<>Occupied) and
    (THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(OtherSource)),
    'Occupied/ambiguous short name was overwritten or returned as this book'); Unchanged;
  Writeln('PASS changed source refreshes owned alias; conflicting short-name bytes/stamp are retained');

  MakeCanonical(Source,'.pdf','%PDF-1.7 Prepared bytes whose actual format is PDF.',Canonical);
  Document:=Book; Document.Title:='Документ после подготовки';
  OtherNamed:=PrepareExternalReaderFile(Document,Canonical,''); CheckName(OtherNamed,'.pdf');
  Require((THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(Canonical)) and
    (TPath.GetFullPath(BookCacheSource(OtherNamed))=TPath.GetFullPath(Source)),
    'Friendly name confused recorded TXT with actual PDF or lost canonical origin');
  RegisterBookCacheFile(Canonical,Source); // Production cache hits Touch payload timestamps.
  Locked:=TFileStream.Create(Canonical,fmOpenRead or fmShareExclusive);
  try Require(PrepareExternalReaderFile(Document,Canonical,'')=OtherNamed,
    'Touched canonical warm hit rereads locked payload bytes or changes the filename');
  finally Locked.Free; end;
  Require(THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(Canonical),
    'Touched canonical warm hit returned different payload'); Unchanged;
  Writeln('PASS touched canonical warm hit uses dependency metadata without reopening locked payload bytes');
  Rejected:=False;
  try PrepareExternalReaderFile(Other,Canonical,''); except on E: Exception do Rejected:=E.Message.Contains('другой книге'); end;
  Require(Rejected,'External friendly alias authorized a prepared copy of a different original'); Unchanged;
  var HumanSource:=TPath.Combine(Root,'Already readable filename.txt'); TFile.WriteAllText(HumanSource,'Readable source.',TEncoding.UTF8); Protect(HumanSource);
  Other:=Book; Other.FileName:='Already readable filename';
  Require(PrepareExternalReaderFile(Other,HumanSource,'')=HumanSource,'Ordinary readable source/history path was needlessly copied'); Unchanged;
  // Prepared origin spelling can predate a harmless Windows path-case edit.
  // The underlying original must be the same real file, not just folded text.
  Other:=Book; Other.CollectionRoot:=UpperCase(Book.CollectionRoot); Other.FileName:=UpperCase(Book.FileName);
  Other.FileExt:=UpperCase(Book.FileExt); Other.Title:='Case-insensitive source proof';
  OtherNamed:=PrepareExternalReaderFile(Other,Canonical,''); CheckName(OtherNamed,'.pdf');
  Require(THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(Canonical),
    'Harmless Windows original path-case variation rejected/altered prepared content'); Unchanged;
  Writeln('PASS actual prepared extension, wrong-origin rejection, real file-ID casing proof and unchanged readable original/history paths');

  Other:=Book; Other.BookKey.DatabaseID:=900100; Other.Title:='..\CON: .pending- * / ? '+#0+'ё 😀'+StringOfChar('Ж',500); Other.Authors:=nil;
  OtherNamed:=PrepareExternalReaderFile(Other,Source,''); CheckName(OtherNamed,'.txt');
  Require(THashSHA2.GetHashStringFromFile(OtherNamed)=THashSHA2.GetHashStringFromFile(Source),'Long/malformed title changed payload'); Unchanged;
  var BoundaryLimit:=Min(140,MAX_PATH-1-Length(IncludeTrailingPathDelimiter(CacheRoot))-Length('homelib-')-
    Length(' []')-12-Length('.txt')-Length('.source')-
    Length('.pending-4294967295-4294967295-{00000000-0000-0000-0000-000000000000}'));
  Require(BoundaryLimit>8,'Native Unicode boundary cache path has insufficient room');
  Other.BookKey.DatabaseID:=900101;
  Other.Title:=StringOfChar('А',BoundaryLimit-1)+'😀'+StringOfChar('Б',200); Other.Authors:=nil;
  OtherNamed:=PrepareExternalReaderFile(Other,Source,''); CheckName(OtherNamed,'.txt'); Unchanged;
  Writeln('PASS invalid control/device/path title and exact surrogate truncation boundary remain bounded, safe and intact');

  var LegacyCanonical, LegacyNamed: string;
  MakeCanonical(Source,'.pdf','%PDF-1.7 Legacy canonical without dependency metadata.',LegacyCanonical,False);
  Require(System.SysUtils.DeleteFile(LegacyCanonical+'.source'),'Cannot set up own legacy missing-stamp case');
  Protect(LegacyCanonical); Protect(LegacyCanonical+'.origin');
  Document:=Book; Document.Title:='Копия старого кэша без штампа';
  LegacyNamed:=PrepareExternalReaderFile(Document,LegacyCanonical,'');
  RegisterBookCacheFile(LegacyCanonical,Source);
  Require((PrepareExternalReaderFile(Document,LegacyCanonical,'')=LegacyNamed) and
    (THashSHA2.GetHashStringFromFile(LegacyNamed)=THashSHA2.GetHashStringFromFile(LegacyCanonical)),
    'Missing dependency metadata plus cache Touch falsely aborted or returned wrong legacy bytes'); Unchanged;

  var RewrittenCanonical, RewrittenNamed: string;
  MakeCanonical(Source,'.fb2','Prepared FB2 metadata value A.',RewrittenCanonical);
  Document:=Book; Document.Title:='Перезапись сведений FB2';
  RewrittenNamed:=PrepareExternalReaderFile(Document,RewrittenCanonical,'',True);
  SavedOverwrite:=Settings.OverwriteFB2Info; Settings.OverwriteFB2Info:=True;
  try
    // Same-size description change; upstream preparation dependency remains unchanged.
    TFile.WriteAllText(RewrittenCanonical,'Prepared FB2 metadata value B.',TEncoding.UTF8); Protect(RewrittenCanonical);
    RegisterBookCacheFile(RewrittenCanonical,Source);
    Require((PrepareExternalReaderFile(Document,RewrittenCanonical,'',True)=RewrittenNamed) and
      (THashSHA2.GetHashStringFromFile(RewrittenNamed)=THashSHA2.GetHashStringFromFile(RewrittenCanonical)),
      'Explicit same-size FB2 metadata rewrite retained stale alias bytes');
  finally Settings.OverwriteFB2Info:=SavedOverwrite; end; Unchanged;
  Writeln('PASS legacy missing dependency metadata and explicit same-size FB2 rewrite refresh safely after cache Touch');
  CheckOriginalFB2Rewrite('Readable original book');
  CheckOriginalFB2Rewrite('0031');
  Unchanged;

  // Publication may trim an unpinned input when the entire cache is over limit.
  // Keep prior protected payloads pinned; the new canonical is disposable cache.
  for var ProtectedName in ProtectedNames do PinReaderCacheFile(ProtectedName);
  var LargeSource:=TPath.Combine(Root,'0030.txt');
  TFile.WriteAllText(LargeSource,'Original source for a large prepared page.',TEncoding.UTF8); Protect(LargeSource);
  var LargeCanonical, LargeNamed: string;
  MakeCanonical(LargeSource,'.pdf','%PDF-1.7 '+StringOfChar('A',2*1024*1024),LargeCanonical,False);
  var LargePayloadHash:=THashSHA2.GetHashStringFromFile(LargeCanonical);
  Document:=Book; Document.FileName:='0030'; Document.Title:='Копия при маленьком лимите';
  SavedLimit:=Settings.BookCacheLimitMB; Settings.BookCacheLimitMB:=1;
  try
    LargeNamed:=PrepareExternalReaderFile(Document,LargeCanonical,''); CheckName(LargeNamed,'.pdf');
    Require(FileExists(LargeNamed) and (THashSHA2.GetHashStringFromFile(LargeNamed)=LargePayloadHash),
      'Small cache limit evicted the input before verification/publication or altered the pinned result');
  finally Settings.BookCacheLimitMB:=SavedLimit; end; Unchanged;
  Writeln('PASS small cache limit keeps the canonical input alive through stamp verification and alias publication');

  Owner:=TComponent.Create(nil); Finished:=False; AsyncResult:=''; Other:=Book; Other.Title:='Асинхронная читалка';
  try
    Started:=GetTickCount64;
    PrepareExternalReaderFileInBackground(Owner,Other,Source,'',
      procedure(FileName: string) begin AsyncResult:=FileName; Finished:=True; end);
    Require(GetTickCount64-Started<500,'Friendly alias preparation blocks the UI caller');
    while not Finished and (GetTickCount64-Started<5000) do
    begin Application.ProcessMessages; CheckSynchronize(5); Sleep(2); end;
    Require(Finished and FileExists(AsyncResult),'Background friendly preparation did not complete'); CheckName(AsyncResult,'.txt');
  finally Owner.Free; end; Unchanged;
  Owner:=TComponent.Create(nil); Finished:=False;
  PrepareExternalReaderFileInBackground(Owner,Book,Source,'',
    procedure(FileName: string) begin Finished:=True; end);
  CancelReaderPreparations(Owner); Owner.Free; Application.ProcessMessages;
  Require(not Finished,'Cancelled external preparation still launched its reader callback'); Unchanged;
  Writeln('PASS external friendly alias uses cancellable background lifecycle and never launches after owner cancellation');
  // A warm compatibility hit may avoid source reads, but a changed source
  // with a misleading .fb2 extension must invalidate it and be detected anew.
  var ChangedSource:=TPath.Combine(Root,'changed-format.fb2');
  TFile.WriteAllText(ChangedSource,'<FictionBook><body><section><p>WebP source.</p></section></body>'+
    '<binary id="cover" content-type="image/webp">UklGRi4AAABXRUJQVlA4TCIAAAAvAUAAEBcwFEKChO7/vY6HgKDouuUC7A1KAgRAUUIi+h8D</binary></FictionBook>',TEncoding.UTF8);
  Other:=Book; Other.FileName:='changed-format'; Other.FileExt:='.fb2'; Other.LibID:='changed-format';
  var ConvertBefore:=Settings.ConvertWebPToPNG; Settings.ConvertWebPToPNG:=True;
  try
    var CachedFB2:=PrepareReaderFile(Other);
    Require(not SameFileName(CachedFB2,ChangedSource) and TFile.ReadAllText(CachedFB2,TEncoding.UTF8).Contains('image/png'),
      'Changed-format fixture did not first create a real compatibility cache');
    TFile.WriteAllText(ChangedSource,'%PDF-1.4'+sLineBreak+'Changed source payload with a misleading FB2 filename.',TEncoding.ASCII); Protect(ChangedSource);
    var DetectedPDF:=PrepareReaderFile(Other);
    Require(SameText(ExtractFileExt(DetectedPDF),'.pdf') and
      (THashSHA2.GetHashStringFromFile(DetectedPDF)=THashSHA2.GetHashStringFromFile(ChangedSource)),
      'Warm FB2 cache bypassed content detection after the physical source changed'); Unchanged;
  finally Settings.ConvertWebPToPNG:=ConvertBefore; end;
  Writeln('PASS external reader compatibility cache invalidates changed misleading source and detects the actual PDF bytes');
  Writeln('PASS external-reader filename policy preserves original/canonical bytes, profiles, reader history and notes'); Flush(Output);
end;
