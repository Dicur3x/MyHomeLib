// Optional mode reader-pipeline-cache. All actual DOC/helper/cache files are
// staged in a private G regression folder; no external reader is launched.
procedure TestReaderPipelineCache;
const KindleMagic = 'BOOKMOBI'; MobiMagic = 'MOBI';
var Root, CacheRoot, Original, Canonical, Stamp, ChangedStamp, OutputName,
  Again, ArchiveName, RawResult, Detected, ChangedDetected, KindleSource,
  KindleInput, KindleResult, OfficeSource, OfficeInput, OfficeResult, Tool: string;
  ProtectedNames, ProtectedHashes: TArray<string>; Stages: TStringList;
  Payload, Altered: TBytes; Input: TStream; Locked: TFileStream;
  Writer: TBookCacheWrite; Book: TBookRecord; Zip: TZipFile;
  ToolData: TWin32FileAttributeData; BeforeWrite, AfterWrite: TDateTime;

  procedure Protect(const Name: string);
  begin
    ProtectedNames:=ProtectedNames+[Name];
    ProtectedHashes:=ProtectedHashes+[THashSHA2.GetHashStringFromFile(Name)];
  end;

  procedure Unchanged(const Context: string);
  begin
    for var I:=0 to High(ProtectedNames) do
      Require(FileExists(ProtectedNames[I]) and
        (THashSHA2.GetHashStringFromFile(ProtectedNames[I])=ProtectedHashes[I]),
        Context+': protected original/history/notes/profile changed: '+ProtectedNames[I]);
  end;

  procedure Publish(const Source, Extension: string; const Bytes: TBytes; out Name: string;
    const Dependency: string = 'private pipeline extraction v1');
  var Temporary, TemporaryStamp: string;
  begin
    Name:=TPath.Combine(CacheRoot,'homelib-pipeline-'+TGUID.NewGuid.ToString+Extension);
    Writer:=TBookCacheWrite.Create(Source);
    try
      Temporary:=Writer.TemporaryName(Name); TemporaryStamp:=Writer.TemporaryName(Name+'.source');
      TFile.WriteAllBytes(Temporary,Bytes); TFile.WriteAllText(TemporaryStamp,Dependency,TEncoding.UTF8);
      Writer.Publish(Temporary,Name,TemporaryStamp);
    finally Writer.Free; end;
  end;

  procedure SeedResult(const Source, Name, ResultStamp: string; const Bytes: TBytes);
  var Destination, Temporary, TemporaryStamp: string;
  begin
    Destination:=Name; Writer:=TBookCacheWrite.Create(Source);
    try
      Temporary:=Writer.TemporaryName(Destination); TemporaryStamp:=Writer.TemporaryName(Destination+'.source');
      TFile.WriteAllBytes(Temporary,Bytes); TFile.WriteAllText(TemporaryStamp,ResultStamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Destination,TemporaryStamp);
      Require(SameFileName(Destination,Name),'Pipeline seeding changed the expected output location');
    finally Writer.Free; end;
  end;

  function DocumentXML(const Name: string): string;
  var PackageFile: TZipFile; Bytes: TBytes;
  begin
    PackageFile:=TZipFile.Create;
    try PackageFile.Open(Name,zmRead); PackageFile.Read('word/document.xml',Bytes);
      Result:=TEncoding.UTF8.GetString(Bytes);
    finally PackageFile.Free; end;
  end;

  function DOCStarts: Integer;
  begin
    Result:=0; for var Stage in Stages do if Stage.Contains('текста и изображений DOC') then Inc(Result);
  end;

begin
  RequireIsolatedRegression;
  Require(TPath.GetFullPath(Settings.AppPath).StartsWith('G:\',True),'Pipeline gate must remain private G');
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'pipeline-'+TGUID.NewGuid.ToString));
  ForceDirectories(Root); CacheRoot:=BookCachePath;
  Require(TPath.GetFullPath(CacheRoot).StartsWith('G:\',True),'Pipeline cache must remain private G');
  Require(ForceDirectories(CacheRoot),'Could not create the private pipeline cache folder');
  Stages:=TStringList.Create; Locked:=nil; Input:=nil;
  try
    if FileExists(Settings.SettingsFileName) then Protect(Settings.SettingsFileName);
    for var Name in ['reader.ini','reader-notes.json','profiles.json'] do
    begin TFile.WriteAllText(Root+Name,'Protected pipeline '+Name,TEncoding.UTF8); Protect(Root+Name); end;
    Original:=Root+'owner-source.zip'; TFile.WriteAllText(Original,'Protected physical source',TEncoding.UTF8); Protect(Original);
    Payload:=TEncoding.UTF8.GetBytes('%PDF-1.4'+#10+'private payload A');
    Publish(Original,'.bin',Payload,Canonical);
    // Prove the real cache does change last-write time, while dependency
    // identity remains stable. Keep the input handle alive as callers do.
    TFile.SetLastWriteTime(Canonical,EncodeDate(2000,1,1)); BeforeWrite:=TFile.GetLastWriteTime(Canonical);
    Input:=OpenCachedBookFile(Canonical);
    try Stamp:=BookCacheInputStamp(Canonical,Original); AfterWrite:=TFile.GetLastWriteTime(Canonical);
      Require(AfterWrite>BeforeWrite,'Native input did not exercise the actual cache Touch');
    finally FreeAndNil(Input); end;
    RegisterBookCacheFile(Canonical,Original);
    Require(BookCacheInputStamp(Canonical,Original)=Stamp,'LRU Touch invalidated a proved payload/dependency stamp');
    Require(BookCacheInputStamp(UpperCase(Canonical),UpperCase(Original))=Stamp,'Windows path case changed input identity');
    TFile.WriteAllText(Canonical+'.source','private pipeline extraction v2',TEncoding.UTF8);
    Require(BookCacheInputStamp(Canonical,Original)<>Stamp,'Changed extraction dependency reused old input stamp');
    TFile.WriteAllText(Canonical+'.source','private pipeline extraction v1',TEncoding.UTF8);
    Require(BookCacheInputStamp(Canonical,Original)=Stamp,'Restored exact dependency failed to restore exact identity');
    Altered:=Copy(Payload); Altered[High(Altered)]:=Ord('B'); TFile.WriteAllBytes(Canonical,Altered);
    ChangedStamp:=BookCacheInputStamp(Canonical,Original);
    Require(ChangedStamp<>Stamp,'Same-size managed payload replacement with unchanged dependency sidecar was accepted');
    TFile.WriteAllBytes(Canonical,Payload);
    TFile.WriteAllText(Canonical+'.origin',Root+'foreign-source.zip',TEncoding.UTF8);
    Require(BookCacheInputStamp(Canonical,Original)<>BookCacheInputStamp(Canonical,Original),
      'Foreign origin authorized a repeatable derived cache hit');
    TFile.WriteAllBytes(Canonical+'.origin',TBytes.Create($FF,$FE,$FD));
    Require(BookCacheInputStamp(Canonical,Original)<>BookCacheInputStamp(Canonical,Original),
      'Malformed origin authorized a repeatable derived cache hit');
    RegisterBookCacheFile(Canonical,Original);
    TFile.Delete(Canonical+'.source');
    Require(BookCacheInputStamp(Canonical,Original)<>BookCacheInputStamp(Canonical,Original),
      'Missing dependency authorized a repeatable derived cache hit');
    TFile.WriteAllText(Canonical+'.source','private pipeline extraction v1',TEncoding.UTF8);
    Require(BookCacheInputStamp(Canonical,Original)=Stamp,'Legacy-metadata probe did not restore proved identity');
    Detected:=PrepareDetectedReaderFile(Canonical,Original);
    var DetectedHash:=THashSHA2.GetHashStringFromFile(Detected);
    Locked:=TFileStream.Create(Detected,fmOpenRead or fmShareDenyWrite);
    try
      RegisterBookCacheFile(Canonical,Original); Again:=PrepareDetectedReaderFile(Canonical,Original);
      Require(SameFileName(Again,Detected) and (THashSHA2.GetHashStringFromFile(Again)=DetectedHash),
        'Touched incorrectly named archive member created a new alias or rewrote the locked warm result');
    finally FreeAndNil(Locked); end;
    TFile.WriteAllBytes(Canonical,Altered); ChangedDetected:=PrepareDetectedReaderFile(Canonical,Original);
    Require(not SameFileName(Detected,ChangedDetected) and
      (THashSHA2.GetHashStringFromFile(ChangedDetected)=THashSHA2.GetHashStringFromFile(Canonical)),
      'Same-size changed misnamed payload reused a stale format alias');
    Unchanged('Bounded stable input and detected format');
    Writeln('PASS actual LRU Touch keeps proved bounded input and detected-extension aliases warm; changed payload/dependency and foreign/malformed/legacy metadata invalidate safely'); Flush(Output);

    // Raw originals keep their actual timestamp and are never touched.
    var Raw:=Root+'raw.doc'; TFile.WriteAllBytes(Raw,Payload); TFile.SetLastWriteTime(Raw,EncodeDate(2001,1,1));
    Stamp:=BookCacheInputStamp(Raw,Raw); Input:=OpenCachedBookFile(Raw); Input.Free; Input:=nil;
    Require(BookCacheInputStamp(Raw,Raw)=Stamp,'Reading an unmanaged original touched its content timestamp');
    TFile.WriteAllBytes(Raw,Altered); TFile.SetLastWriteTime(Raw,EncodeDate(2002,1,1));
    Require(BookCacheInputStamp(Raw,Raw)<>Stamp,'Same-size changed raw original reused its old stamp');
    Writeln('PASS unmanaged raw input stamps retain true timestamps and invalidate same-size replacements without touching original files'); Flush(Output);

    // Source lifetime covers format copy/publication, then the result pin
    // survives the input destructor even when one result exceeds the limit.
    var SavedLimit:=Settings.BookCacheLimitMB;
    try
      Settings.BookCacheLimitMB:=1;
      SetLength(Payload,2*1024*1024); FillChar(Payload[0],Length(Payload),Ord(' '));
      var Prefix:=TEncoding.ASCII.GetBytes('%PDF-1.4'); Move(Prefix[0],Payload[0],Length(Prefix));
      Publish(Original,'.bin',Payload,Canonical); var LargeHash:=THashSHA2.GetHashStringFromFile(Canonical);
      Detected:=PrepareDetectedReaderFile(Canonical,Original);
      Require(FileExists(Detected) and (THashSHA2.GetHashStringFromFile(Detected)=LargeHash),
        'Small cache evicted a live format input or its completed result on input release');
      Require(SameFileName(PrepareDetectedReaderFile(Detected,Original),Detected) and FileExists(Detected),
        'Unchanged-format preparation released an oversized live result without its pin');
    finally Settings.BookCacheLimitMB:=SavedLimit; end;
    Unchanged('Small-cache format input/result lifetime');
    Writeln('PASS format preparation retains a 2MB managed input and pins completed/unchanged output before release under a 1MB cache limit'); Flush(Output);


    // Actual bundled DOC converter: first cold preparation, then a protected
    // warm call. The locked result makes an attempted rebuild fail visibly.
    var RealDOC:=Settings.AppPath+'reader-novel.doc';
    Require(FileExists(RealDOC),'Stage private reader-novel.doc before the actual DOC pipeline gate'); Protect(RealDOC);
    Stages.Clear;
    RawResult:=PrepareDirectDOC(RealDOC,RealDOC,procedure(Stage: string) begin Stages.Add(Stage); end);
    Require((DOCStarts=1) and SameText(ExtractFileExt(RawResult),'.docx'),'Actual raw DOC was not prepared by the bundled helper');
    var RawOutputHash:=THashSHA2.GetHashStringFromFile(RawResult); Stages.Clear;
    Locked:=TFileStream.Create(RawResult,fmOpenRead or fmShareDenyWrite);
    try Again:=PrepareDirectDOC(RealDOC,RealDOC,procedure(Stage: string) begin Stages.Add(Stage); end);
      Require((DOCStarts=0) and SameFileName(Again,RawResult) and
        (THashSHA2.GetHashStringFromFile(Again)=RawOutputHash),'Actual raw DOC warm cache launched the helper or changed bytes');
    finally FreeAndNil(Locked); end;
    ArchiveName:=Root+'doc-archive.zip'; Zip:=TZipFile.Create;
    try Zip.Open(ArchiveName,zmWrite); Zip.Add(RealDOC,'reader-novel.doc',zcStored); finally Zip.Free; end; Protect(ArchiveName);
    Book.Clear; Book.Title:='Actual archived DOC'; Book.LibID:='pipeline-'+TGUID.NewGuid.ToString;
    Book.CollectionRoot:=Root; Book.Folder:=ExtractFileName(ArchiveName); Book.FileName:='reader-novel'; Book.FileExt:='.doc';
    Include(Book.BookProps,bpIsLocal); Stages.Clear;
    OutputName:=PrepareReaderFile(Book,True,procedure(Stage: string) begin Stages.Add(Stage); end,False,True,True);
    Require((DOCStarts=1) and SameText(ExtractFileExt(OutputName),'.docx'),'Actual archived DOC never reached the bundled helper');
    var ArchiveOutputHash:=THashSHA2.GetHashStringFromFile(OutputName); Stages.Clear;
    Locked:=TFileStream.Create(OutputName,fmOpenRead or fmShareDenyWrite);
    try Again:=PrepareReaderFile(Book,True,procedure(Stage: string) begin Stages.Add(Stage); end,False,True,True);
      Require((DOCStarts=0) and SameFileName(Again,OutputName) and
        (THashSHA2.GetHashStringFromFile(Again)=ArchiveOutputHash),'Second archived DOC open launched the helper or rewrote the protected result');
    finally FreeAndNil(Locked); end;
    Require(DocumentXML(OutputName)=DocumentXML(RawResult),'Actual raw/archived DOC body/style XML differs for identical source bytes');
    Unchanged('Actual raw and archived DOC');
    Writeln('PASS actual bundled DOC cold preparation runs once for raw and archived input; each locked warm result opens with zero helper starts and exact unchanged content'); Flush(Output);

    // Exercise KF8 adapter warm logic without launching synthetic input. The
    // input header is sufficient for the adapter; its prepared EPUB is owned.
    Require(FileExists(Settings.AppPath+'tools\kindle\python\python.exe') and
      FileExists(Settings.AppPath+'tools\kindle\convert_kf8.py'),'Stage bundled Kindle component for the warm adapter gate');
    SetLength(Payload,126); FillChar(Payload[0],Length(Payload),0);
    for var I:=1 to 8 do Payload[59+I]:=Ord(KindleMagic[I]); Payload[81]:=86;
    for var I:=1 to 4 do Payload[101+I]:=Ord(MobiMagic[I]); Payload[125]:=8;
    KindleSource:=Root+'source.azw3'; TFile.WriteAllBytes(KindleSource,Payload); Protect(KindleSource);
    Publish(KindleSource,'.azw3',Payload,KindleInput);
    KindleResult:=TPath.Combine(CacheRoot,'homelib-kindle-'+Copy(THashSHA2.GetHashString(KindleInput),1,32)+'.epub');
    Input:=OpenCachedBookFile(KindleInput);
    try Stamp:='kindleunpack-bf0ca6e-v2|'+BookCacheInputStamp(KindleInput,KindleSource);
      SeedResult(KindleSource,KindleResult,Stamp,TEncoding.UTF8.GetBytes('Private preseeded EPUB bytes'));
    finally FreeAndNil(Input); end;
    var KindleHash:=THashSHA2.GetHashStringFromFile(KindleResult); Stages.Clear;
    Locked:=TFileStream.Create(KindleResult,fmOpenRead or fmShareDenyWrite);
    try Again:=PrepareKindleReflow(KindleInput,KindleSource,procedure(Stage: string) begin Stages.Add(Stage); end);
      Require((Stages.Count=0) and SameFileName(Again,KindleResult) and
        (THashSHA2.GetHashStringFromFile(Again)=KindleHash),'Actual KF8 warm adapter started unpacking or rewrote its locked result');
    finally FreeAndNil(Locked); end;
    Unchanged('KF8 warm adapter');
    Writeln('PASS actual KF8 warm adapter accepts a proved preseeded dependency despite input Touch with zero unpack stages and exact result bytes'); Flush(Output);

    Require(FindReaderOffice<>'','Bundled portable office interpreter is missing');
    OfficeSource:=Root+'source.pptx';
    TFile.Copy(Settings.AppPath+'metadata-archive-fixtures\portable-reader.pptx',OfficeSource,False); Protect(OfficeSource);
    Publish(OfficeSource,'.pptx',TFile.ReadAllBytes(OfficeSource),OfficeInput);
    OfficeResult:=PrepareOfficeReaderFile(OfficeInput,OfficeSource); var OfficeHash:=THashSHA2.GetHashStringFromFile(OfficeResult);
    Locked:=TFileStream.Create(OfficeResult,fmOpenRead or fmShareDenyWrite);
    try Stages.Clear; Again:=PrepareOfficeReaderFile(OfficeInput,OfficeSource,procedure(Stage: string) begin Stages.Add(Stage); end);
      Require((Stages.Count=1) and Stages[0].Contains('из кэша') and SameFileName(Again,OfficeResult) and
        (THashSHA2.GetHashStringFromFile(Again)=OfficeHash),'Portable Office warm adapter ran conversion or rewrote its locked result');
    finally FreeAndNil(Locked); end;
    Writeln('PASS portable Office adapter reuses a protected real warm result without starting an installed office suite'); Flush(Output);
    Unchanged('Complete pipeline cache gate');
    Writeln('PASS pipeline preparation preserves all physical originals, archive bytes, reader history, notes and active settings/profile'); Flush(Output);
  finally FreeAndNil(Locked); FreeAndNil(Input); Stages.Free; end;
end;
