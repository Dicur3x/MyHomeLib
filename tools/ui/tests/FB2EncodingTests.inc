procedure TestFB2Encoding;
const
  UTF8Title = 'Книга с неверной кодировкой';
  RealTitle = 'Отпуск';
  RealBody = 'Громада аэропорта';
  CyrillicBody = 'Текст в исходной кодировке ё';
  Sample = '<?xml version="1.0" encoding="windows-1251"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>' +
    '<genre>prose_contemporary</genre><author><last-name>Сорокин</last-name></author>' +
    '<book-title>'+UTF8Title+'</book-title><lang>ru</lang></title-info>' +
    '<publish-info><publisher>Русский издатель</publisher></publish-info></description>' +
    '<body><section><p>'+CyrillicBody+'</p></section></body></FictionBook>';
var
  Folder, Profile, ArchiveRoot, ExactArchive, ImportedArchive, LegacyFile, ReadFile, ErrorText, Hash: string;
  SystemData: ISystemData;
  Catalog: IBookCollection;
  Stored: TBookRecord;
  Worker: TOOFB2Worker;
  Reader: TReaderDocument;
  MetadataReader: TFB2PublisherMetadataReader;
  Series: TFB2PublisherSeries;
  Bytes, Mixed: TBytes;
  Legacy: TEncoding;
  Member, OutputStream: TStream;
  Archive: TZipFile;
  CID: Integer;
  SavedSort: Boolean;

  procedure CheckDescription(Stream: TStream; const Expected: string);
  begin
    Require(LoadFB2Description(Stream,False).Description.Titleinfo.Booktitle.Text=Expected,
      'FB2 description changed the book title');
  end;

begin
  RequireIsolatedRegression;
  Folder:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'fb2-encoding-'+TGUID.NewGuid.ToString));
  ArchiveRoot:=Folder+'archives\';
  ForceDirectories(ArchiveRoot);
  Profile:=Folder+'system.sqlite';
  TSystemData_SQLite.CreateSystemTables(Profile);
  SystemData:=TSystemData_SQLite.Create(Profile);
  Reader:=TReaderDocument.Create;
  SavedSort:=Settings.EnableSort;
  Settings.EnableSort:=False;
  try
    LegacyFile:=Folder+'legacy.fb2';
    Legacy:=TEncoding.GetEncoding(1251);
    try TFile.WriteAllBytes(LegacyFile,Legacy.GetBytes(Sample)); finally Legacy.Free; end;
    Require(LoadFictionBook(LegacyFile).Description.Titleinfo.Booktitle.Text=UTF8Title,
      'Ordinary Windows-1251 import changed the title');
    Reader.Load(LegacyFile);
    Require(Reader.PlainText.Contains(CyrillicBody),'Ordinary Windows-1251 reader changed the text');

    Bytes:=TEncoding.UTF8.GetBytes(Sample);
    ReadFile:=Folder+'misdeclared.fb2';
    TFile.WriteAllBytes(ReadFile,Bytes);
    Require(LoadFictionBook(ReadFile).Description.Titleinfo.Booktitle.Text=UTF8Title,
      'Loose FB2 import did not recognize the real encoding');
    Reader.Load(ReadFile);
    Require(Reader.PlainText.Contains(CyrillicBody),'Misdeclared UTF-8 reader did not recover text');

    ReadFile:=Folder+'unicode.fb2';
    TFile.WriteAllText(ReadFile,Sample,TEncoding.UTF8);
    Require(LoadFictionBook(ReadFile).Description.Titleinfo.Booktitle.Text=UTF8Title,
      'UTF-8 BOM did not take precedence');
    Reader.Load(ReadFile);
    Require(Reader.PlainText.Contains(CyrillicBody),'UTF-8 BOM reader changed the text');

    TFile.WriteAllText(ReadFile,Sample.Replace('windows-1251','utf-16'),TEncoding.Unicode);
    Require(LoadFictionBook(ReadFile).Description.Titleinfo.Booktitle.Text=UTF8Title,
      'UTF-16 import changed the title');
    Reader.Load(ReadFile);
    Require(Reader.PlainText.Contains(CyrillicBody),'UTF-16 reader changed the text');

    Mixed:=Copy(Bytes);
    Mixed[High(Mixed)]:=$FF;
    Require(not unit_FB2Encoding.RepairFB2UTF8Declaration(Mixed),
      'Malformed UTF-8 later in the file was accepted');

    ImportedArchive:=ArchiveRoot+'sample.zip';
    ExactArchive:=GetEnvironmentVariable('HOMELIB_FB2_ENCODING_FIXTURE');
    if ExactArchive<>'' then
      TFile.Copy(ExactArchive,ImportedArchive,False)
    else
    begin
      Archive:=TZipFile.Create;
      try
        Archive.Open(ImportedArchive,zmWrite);
        Archive.Add(Bytes,'sample.fb2');
      finally Archive.Free; end;
    end;
    Hash:=THashSHA2.GetHashStringFromFile(ImportedArchive);
    CID:=SystemData.CreateCollection('FB2 encoding import',ArchiveRoot,Folder+'catalog.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
    Worker:=TOOFB2Worker.Create(CID,afZip);
    Worker.FixtureProfile:=Profile;
    try
      TOORun(Worker);
      Require(Worker.Success and Worker.CommittedChanges,'FB2 archive import failed');
    finally Worker.Free; end;
    Require(TOOBookCount(SystemData,CID)=1,'FB2 archive import lost the book');

    Catalog:=SystemData.GetCollection(CID,True);
    Catalog.GetBookRecord(CreateBookKey(1,CID),Stored,True);
    if ExactArchive<>'' then Require(Stored.Title=RealTitle,'Wrong title from supplied ZIP')
    else Require(Stored.Title=UTF8Title,'Wrong title from synthetic ZIP');
    Member:=OpenBookMetadataSource(Stored);
    try CheckDescription(Member,Stored.Title); finally Member.Free; end;
    Member:=OpenBookMetadataSource(Stored);
    try CheckDescription(Member,Stored.Title); finally Member.Free; end;
    Member:=Stored.GetBookStream(False,False);
    try
      Require(Assigned(Member) and (Member.Size>0),'Imported archive member cannot be reopened');
      CheckDescription(Member,Stored.Title);
      Member.Position:=0;
      MetadataReader:=TFB2PublisherMetadataReader.Create;
      try
        Require(MetadataReader.Read(Member,Series,ErrorText)=fmsComplete,
          'Streaming FB2 metadata failed: '+ErrorText);
        if ExactArchive='' then
          Require(MetadataReader.LastPublisher='Русский издатель','Streaming metadata changed the publisher');
      finally MetadataReader.Free; end;
      Member.Position:=0;
      ReadFile:=Folder+'reopened.fb2';
      OutputStream:=TFileStream.Create(ReadFile,fmCreate);
      try OutputStream.CopyFrom(Member,0); finally OutputStream.Free; end;
    finally Member.Free; end;
    Reader.Load(ReadFile);
    if ExactArchive<>'' then Require((Reader.Title=RealTitle) and Reader.PlainText.Contains(RealBody),
      'Reader did not recover the supplied ZIP')
    else Require(Reader.PlainText.Contains(CyrillicBody),'Reader did not recover the imported archive');
    Require(THashSHA2.GetHashStringFromFile(ImportedArchive)=Hash,'Original ZIP bytes changed');
    Writeln('PASS FB2 encoding across metadata import and reader; supplied ZIP=',Ord(ExactArchive<>''));
  finally
    Catalog:=nil;
    SystemData:=nil;
    Settings.EnableSort:=SavedSort;
    Reader.Free;
  end;
end;
