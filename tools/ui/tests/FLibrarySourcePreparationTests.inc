procedure TestFLibrarySourcePreparation;
var Folder, SourceHash, BeforeImages, BeforeBody, AgainImages, AgainBody, SourceBody,
  SavedTemplate: string;
  Source: TMemoryStream; Restored, Repeated: TStream; Book: TBookRecord;

  procedure Signature(const Input: TStream; out Images, Body: string; ExpectedImages: Integer=3;
    const ExpectedTitle: string='');
  var Document: IXMLDocument; Values: TStringList; Text: TStringBuilder;
    procedure Walk(const Node: IXMLNode; InBody: Boolean);
    begin
      if Node.NodeType in [Xml.XMLIntf.ntText,Xml.XMLIntf.ntCData] then
      begin
        if InBody then for var C in VarToStr(Node.NodeValue) do
          if not CharInSet(C,[' ',#9,#10,#13]) then Text.Append(C);
        Exit;
      end;
      if Node.LocalName='binary' then
      begin
        var ID:=VarToStr(Node.Attributes['id']);
        Require(Values.IndexOfName(ID)<0,'Preparation created duplicate binary ID '+ID);
        var ImageData:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(Node.Text));
        try Values.Add(ID+'='+THashSHA2.GetHashString(ImageData));
        finally ImageData.Free; end;
        Exit;
      end;
      for var I:=0 to Node.ChildNodes.Count-1 do
        Walk(Node.ChildNodes[I],InBody or (Node.LocalName='body'));
    end;
  begin
    Values:=TStringList.Create; Text:=TStringBuilder.Create;
    try
      Input.Position:=0; Document:=NewXMLDocument;
      Document.ParseOptions:=[poPreserveWhiteSpace]; Document.LoadFromStream(Input);
      if ExpectedTitle<>'' then
        Require(Document.DocumentElement.ChildNodes['description'].ChildNodes['title-info'].ChildNodes['book-title'].Text=ExpectedTitle,
          'Metadata rewrite did not publish the changed title');
      Walk(Document.DocumentElement,False); Values.Sort;
      Images:=Values.Text; Body:=Text.ToString;
      Require(Values.Count=ExpectedImages,'Unexpected number of image binaries from the compressed source');
      if ExpectedImages>0 then Require((Values.IndexOfName('cover')>=0) and (Values.IndexOfName('1')>=0) and
        (Values.IndexOfName('2')>=0),'Restored image identities differ from the compressed layout');
    finally Document:=nil; Text.Free; Values.Free; end;
  end;

begin
  RequireIsolatedRegression; Folder:=Settings.AppPath+'flibrary-source-fixtures\';
  Source:=TMemoryStream.Create; Restored:=nil;
  SavedTemplate:=Settings.BookHeaderTemplate;
  try
    Source.LoadFromFile(Folder+'557950.fb2'); SourceHash:=UpdateSHA256(Folder+'557950.fb2');
    Require(SameText(SourceHash,'efc28dc668f1d9971833a501baba6480e5a0775996652f6f921e6798118b3019'),
      'Actual compressed source fixture changed');
    Signature(Source,AgainImages,SourceBody,0);
    Source.Position:=17;
    Restored:=RestoreFLibraryBook(Folder+'source.7z','557950.fb2',Source);
    Require((Restored<>nil) and (Source.Position=17),'Restoration lost images or changed borrowed source position');
    Signature(Restored,BeforeImages,BeforeBody);
    Require((Length(BeforeBody)>10000) and (BeforeBody=SourceBody),'Restoration changed readable body text');
    Writeln('PASS actual FLibrary source restores one cover and two illustrations with unchanged borrowed bytes');
    Repeated:=RestoreFLibraryBook(Folder+'source.7z','557950.fb2',Restored);
    try Require(Repeated=nil,'Repeated restoration added already present image binaries');
    finally Repeated.Free; end;
    Signature(Restored,AgainImages,AgainBody);
    Require((AgainImages=BeforeImages) and (AgainBody=BeforeBody),'Repeated restoration changed text or image bytes');
    Writeln('PASS repeated FLibrary restoration does not create another cover or illustration');
    Book.Clear; Book.Title:='Проверка сведений — Ярлинги поневоле';
    Book.Series:=NO_SERIES_TITLE; Settings.BookHeaderTemplate:='%t';
    for var Pass:=1 to 2 do
    begin
      if Pass=1 then Book.Title:='Проверка сведений '+string.Create('я',400)
      else Book.Title:='Короткое название';
      Restored.Position:=0;
      Require(WriteFb2InfoToStream(Book,Restored),'Metadata rewrite failed for the restored source');
      Signature(Restored,AgainImages,AgainBody,3,Book.Title);
      Require((AgainImages=BeforeImages) and (AgainBody=BeforeBody),'Metadata rewrite changed text or image binaries');
    end;
    Require(UpdateSHA256(Folder+'557950.fb2')=SourceHash,'Preparation modified original fixture bytes');
    Writeln('PASS repeated native FB2 metadata rewrite preserves every restored image and readable body');
  finally Settings.BookHeaderTemplate:=SavedTemplate; Restored.Free; Source.Free; end;
end;

procedure TestPackedUsrZip;
const Members: array[0..2] of string = ('word.doc','slides.ppt','kindle.mobi');
var Folder, Member, Expected, Extension, Prepared: string; Book: TBookRecord; Stream: TStream;
begin
  RequireIsolatedRegression;
  Folder:=Settings.AppPath+'packed-usr-fixtures\';
  Book.Clear;
  Book.CollectionRoot:=Settings.AppPath;
  Book.Folder:='packed-usr-fixtures\books.zip';
  Book.InsideNo:=-1;
  for Member in Members do
  begin
    Book.Title:=Member;
    Book.FileName:=TPath.GetFileNameWithoutExtension(Member);
    Book.FileExt:=ExtractFileExt(Member);
    Expected:=UpdateSHA256(Folder+Member);
    Stream:=Book.GetBookStream;
    try Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Expected),
      'Catalogue stream differs for '+Member);
    finally Stream.Free; end;
    if SameText(Book.FileExt,'.mobi') then
      Prepared:=PrepareConversionSource(Book,nil,'.epub')
    else Prepared:=PrepareReaderFile(Book,True);
    Require(SameText(UpdateSHA256(Prepared),Expected),'Reader preparation differs for '+Member);
    Stream:=OpenArchivedBookSaveSource(Book,Extension);
    try Require(SameText(Extension,Book.FileExt) and Assigned(Stream) and
      SameText(THashSHA2.GetHashString(Stream),Expected),'Save original differs for '+Member);
    finally Stream.Free; end;
  end;
  Writeln('PASS catalogue, reader preparation and Save original restore exact LZMA and PPMd ZIP entries');
end;

procedure TestPackedPdfPreparation;
var Folder, Expected, SavedName, Extension, Prepared, Decoder, SavedPath: string;
  Book, Standalone: TBookRecord; Stream: TStream; Failed: Boolean;
begin
  RequireIsolatedRegression;
  Folder:=Settings.AppPath+'packed-pdf-fixtures\';
  Expected:=UpdateSHA256(Folder+'original.pdf');
  Book.Clear;
  Book.CollectionRoot:=Settings.AppPath;
  Book.Folder:='packed-pdf-fixtures\books.7z';
  Book.Title:='Packed PDF'; Book.FileName:='packed'; Book.FileExt:='.pdf'; Book.InsideNo:=-1;

  Stream:=Book.GetBookStream(True,False);
  try Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Expected),
    'Conversion without illustrations did not reconstruct the original PDF');
  finally Stream.Free; end;
  Prepared:=PrepareReaderFile(Book,True);
  Require(SameText(ExtractFileExt(Prepared),'.pdf') and SameText(UpdateSHA256(Prepared),Expected),
    'Reader preparation returned packed bytes instead of a PDF');
  Stream:=OpenArchivedBookSaveSource(Book,Extension);
  try Require((Extension='.pdf') and Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Expected),
    'Save original did not return the exact PDF');
  finally Stream.Free; end;
  Standalone.Clear;
  Standalone.CollectionRoot:=Settings.AppPath;
  Standalone.Folder:='packed-pdf-fixtures\';
  Standalone.FileName:='single'; Standalone.FileExt:='.7z';
  Prepared:=PrepareReaderFile(Standalone,True);
  Require(SameText(ExtractFileExt(Prepared),'.pdf') and SameText(UpdateSHA256(Prepared),Expected),
    'Opening a standalone packed archive did not restore its PDF');
  Writeln('PASS JPEG XL PDF restores exact bytes for reading, conversion and saving');

  Book.FileName:='plain';
  Stream:=Book.GetBookStream;
  try Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Expected),
    'Ordinary PDF changed when opened from 7z');
  finally Stream.Free; end;

  Book.FileName:='broken'; Failed:=False;
  try
    Stream:=Book.GetBookStream;
    Stream.Free;
  except on E:EZipException do Failed:=True; end;
  Require(Failed,'Corrupt reconstructed PDF was returned to a caller');

  Book.FileName:='packed'; Failed:=False;
  Decoder:=Settings.AppPath+'tools\jpeg-xl\djxl.exe'; SavedName:=Decoder+'.hold';
  SavedPath:=GetEnvironmentVariable('PATH');
  TFile.Move(Decoder,SavedName);
  try
    SetEnvironmentVariable('PATH',PChar(GetEnvironmentVariable('SystemRoot')+'\System32'));
    try
      Stream:=Book.GetBookStream;
      Stream.Free;
    except on E:EMHLComponentRequired do Failed:=E.ComponentID='JPEG XL'; end;
    Require(Failed,'Packed PDF did not request the missing JPEG XL decoder');
  finally
    SetEnvironmentVariable('PATH',PChar(SavedPath));
    TFile.Move(SavedName,Decoder);
  end;
  Writeln('PASS JPEG XL PDF rejects corruption and requests only its missing decoder');
end;

procedure TestPackedPdfInpx;
var Root, Incoming, Original, Changed, IndexFile, RetainedArchive, OriginalHash, ChangedHash, ExportFolder: string;
  Source, PackedCollection, Updated: IBookCollection;
  Options: TCollectionPackingOptions;
  Snapshot: TCollectionPackingSnapshot;
  Update: TCollectionPackingInpxWorker;
  Archive: TZipFile;
  Stream: TStream;
  Book, Retained: TBookRecord;
  SourceID, PackedID, UpdatedID, FirstID, RetainedID, NewID, Port: Integer;
  Server: THomeLibOPDSServer;
  PortProbe: TIdHTTPServer;
  Client: THTTPClient;
  Exporter: TExportToDeviceThread;

  function AddSourcePdf(const Title, Name, LibID: string): Integer;
  begin
    Result:=AddBook(Source,Title,'Fixture author','en','','prose_contemporary');
    Source.GetBookRecord(CreateBookKey(Result,SourceID),Book,True);
    Book.FileName:=Name; Book.FileExt:='.pdf'; Book.LibID:=LibID;
    Source.UpdateBook(Book);
    TFile.Copy(Original,Root+Name+'.pdf');
  end;

  function Row(const Title, Name, LibID: string; Size: Int64): string;
  begin
    Result:='Author,Fixture:'#4'prose_contemporary:'#4+Title+#4#4'0'#4+Name+#4+
      IntToStr(Size)+#4+LibID+#4'0'#4'pdf'#4'2026-11-07'#4'en'+sLineBreak;
  end;

  procedure VerifyPdf(const Collection: IBookCollection; ID: Integer; const Expected: string; out RecordValue: TBookRecord);
  begin
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),RecordValue,True);
    Require((RecordValue.FileExt='.pdf') and IsSevenZipArchive(RecordValue.GetBookFileName),
      'The native packer did not publish the JPEG XL PDF archive');
    Stream:=RecordValue.GetBookStream(True,False);
    try Require(Assigned(Stream) and SameText(THashSHA2.GetHashString(Stream),Expected),
      'A registered packed PDF changed bytes');
    finally Stream.Free; end;
  end;

begin
  RequireIsolatedRegression;
  Original:=Settings.AppPath+'packed-pdf-fixtures\original.pdf'; OriginalHash:=UpdateSHA256(Original);
  Root:=Settings.AppPath+'packed-pdf-input\'; Incoming:=Settings.AppPath+'packed-pdf-update\';
  ForceDirectories(Root); ForceDirectories(Incoming);
  SourceID:=SystemDB.CreateCollection('Packed PDF source',Root,'packed-pdf-source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  FirstID:=AddSourcePdf('First PDF','first','90101');
  RetainedID:=AddSourcePdf('Retained PDF','retained','90102');
  Options:=Default(TCollectionPackingOptions);
  Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE); Options.SourceID:=SourceID;
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.SourceRoot:=Root;
  Options.OutputRoot:=Settings.AppPath+'packed-pdf-output'; Options.DisplayName:='Packed PDF before INPX';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  Options.ImageProfile:=pipJpegXL;
  Options.JpegXLEncoder:=Settings.AppPath+'tools\jpeg-xl\cjxl.exe';
  Options.JpegXLDecoder:=Settings.AppPath+'tools\jpeg-xl\djxl.exe';
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared;
    Require(Snapshot.Status.ImageBooksOptimized=2,'The native packing job did not enable PDF compression');
    PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  PackedCollection:=SystemDB.GetCollection(PackedID);
  VerifyPdf(PackedCollection,RetainedID,OriginalHash,Retained); RetainedArchive:=Retained.GetBookFileName;

  Changed:=Incoming+'changed.pdf'; TFile.Copy(Original,Changed);
  TFile.AppendAllText(Changed,#10'% isolated update fixture'#10,TEncoding.ASCII);
  ChangedHash:=UpdateSHA256(Changed);
  Require(ChangedHash<>OriginalHash,'The incoming PDF version must differ');
  Archive:=TZipFile.Create;
  try
    Archive.Open(Incoming+'books.zip',zmWrite);
    Archive.Add(Changed,'first.pdf'); Archive.Add(Original,'new.pdf'); Archive.Close;
    IndexFile:=Incoming+'index.inpx'; Archive.Open(IndexFile,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes('AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG'),'structure.info');
    Archive.Add(TEncoding.UTF8.GetBytes('20261107'),'version.info');
    Archive.Add(TEncoding.UTF8.GetBytes(Row('Changed PDF','first','90101',TFile.GetSize(Changed))+
      Row('New PDF','new','90103',TFile.GetSize(Original))),'books.inp');
  finally Archive.Free; end;
  Options.CatalogFile:=PackedCollection.GetProperty(PROP_DATAFILE); Options.SourceID:=PackedID;
  Options.SourceRoot:=Options.OutputRoot; Options.DisplayName:='Packed PDF after INPX';
  Update:=TCollectionPackingInpxWorker.Create(Options,IndexFile,Incoming,nil,
    procedure(const Status: TCollectionPackingStatus)
    begin Require(Status.PlannedInputBytes>0,'The incoming PDF archive was not included in the estimate'); end);
  try
    Update.Start; Update.WaitFor;
    if Update.FatalException is Exception then
      raise Exception.Create(Exception(Update.FatalException).Message);
    Require(Update.Success,'Packed PDF INPX update failed');
    Snapshot:=Update.TakeSnapshot;
  finally Update.Free; end;
  try
    Require((Snapshot.Status.Reused=1) and (Snapshot.Status.ImageBooksOptimized=3),
      Format('INPX reused %d archives and packed %d PDFs instead of reusing 1 and packing 3',
        [Snapshot.Status.Reused,Snapshot.Status.ImageBooksOptimized]));
    UpdatedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  Updated:=SystemDB.GetCollection(UpdatedID);
  Require(Updated.ResolveBookID('90101',0)=FirstID,'INPX changed the PDF catalogue identity');
  VerifyPdf(PackedCollection,FirstID,OriginalHash,Book);
  VerifyPdf(Updated,RetainedID,OriginalHash,Retained);
  Require(SameFileName(RetainedArchive,Retained.GetBookFileName),'INPX replaced the retained archive');
  NewID:=Updated.ResolveBookID('90103',0); Require(NewID>0,'INPX lost the new PDF');
  VerifyPdf(Updated,NewID,OriginalHash,Book);
  VerifyPdf(Updated,FirstID,ChangedHash,Book);
  Require(SameText(UpdateSHA256(Root+'first.pdf'),OriginalHash) and SameText(UpdateSHA256(Original),OriginalHash),
    'Packing modified an original PDF');

  ExportFolder:=Settings.AppPath+'packed-pdf-export'; ForceDirectories(ExportFolder);
  Exporter:=TExportToDeviceThread.Create;
  try
    Exporter.StandaloneBooks:=[Book]; Exporter.DeviceDir:=ExportFolder;
    Exporter.FileNameTemplate:='%t'; Exporter.KeepSourceFormat:=True; Exporter.ImageQuality:='original';
    Exporter.Start; Exporter.WaitFor;
    Require((SuccessfulBookExportCount(Exporter.Results)=1) and
      SameText(UpdateSHA256(TPath.Combine(ExportFolder,'Changed PDF.pdf')),ChangedHash),
      'Exported PDF changed after updating the packed collection');
  finally Exporter.Free; end;

  PortProbe:=TIdHTTPServer.Create(nil);
  try
    PortProbe.Bindings.Add.IP:='127.0.0.1'; PortProbe.Bindings[0].Port:=0;
    PortProbe.Active:=True; Port:=PortProbe.Bindings[0].Port;
  finally PortProbe.Free; end;
  Server:=THomeLibOPDSServer.Create; Client:=THTTPClient.Create; Stream:=TMemoryStream.Create;
  try
    Server.Start(SystemDB.GetCollectionInfo(UpdatedID),Port,False);
    Client.ConnectionTimeout:=5000; Client.ResponseTimeout:=15000;
    Require(Client.Get(Server.CatalogURL('127.0.0.1')+'/book/'+IntToStr(FirstID)+'.pdf',Stream).StatusCode=200,
      'OPDS did not serve the reconstructed PDF');
    Stream.Position:=0;
    Require(SameText(THashSHA2.GetHashString(Stream),ChangedHash),'OPDS returned different PDF bytes');
  finally Stream.Free; Client.Free; Server.Free; end;
  Writeln('PASS JPEG XL PDF INPX retains old payloads and serves updated exact PDF bytes');
end;
