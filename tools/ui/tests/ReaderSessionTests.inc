procedure TestHTMLReaderPictures;
begin
  var FixtureRoot:=ExtractFilePath(ParamStr(0));
  var PictureFolder:=TPath.Combine(FixtureRoot,'html-pictures');
  TDirectory.CreateDirectory(PictureFolder);
  var ImageText:='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQMgn7DwAClAGcHVtGXwAAAABJRU5ErkJggg==';
  var PictureBytes:=TNetEncoding.Base64.DecodeStringToBytes(ImageText);
  TFile.WriteAllBytes(TPath.Combine(PictureFolder,'leaf+1.png'),PictureBytes);
  TFile.WriteAllBytes(TPath.Combine(FixtureRoot,'outside.png'),PictureBytes);

  var PictureHTML:='<html><body><p>Начало <img alt="Лист &gt; 3 &amp; примечание" src="missing.gif" /> конец.</p>'+
    '<p><img alt="Только подпись" /></p>'+
    '<p><img title="Другой атрибут alt=wrong src=wrong" src="leaf%2B1.png?cache=9" alt="Уцелевшая картинка" /></p>'+
    '<p><img alt="Внешняя подпись" src="..%2Foutside.png" /></p></body></html>';
  var PictureXHTML:=TPath.Combine(PictureFolder,'pictures.xhtml');
  TFile.WriteAllText(PictureXHTML,PictureHTML,TEncoding.UTF8);
  var PictureLooseHTML:=TPath.Combine(PictureFolder,'pictures.html');
  TFile.WriteAllText(PictureLooseHTML,PictureHTML.Replace(' />','>').Replace('&gt;','>'),TEncoding.UTF8);
  var PictureMHTML:=TPath.Combine(PictureFolder,'pictures.mht');
  var MimeBody:=PictureHTML.Replace('leaf%2B1.png?cache=9','cid:reader-test-img').Replace(' />','>');
  TFile.WriteAllText(PictureMHTML,'MIME-Version: 1.0'+sLineBreak+
    'Content-Type: multipart/related; boundary="home-reader-test"'+sLineBreak+sLineBreak+
    '--home-reader-test'+sLineBreak+
    'Content-Type: text/html; charset=utf-8'+sLineBreak+
    'Content-Transfer-Encoding: base64'+sLineBreak+sLineBreak+
    TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(MimeBody))+sLineBreak+
    '--home-reader-test'+sLineBreak+'Content-Type: image/png'+sLineBreak+
    'Content-ID: <reader-test-img>'+sLineBreak+'Content-Transfer-Encoding: base64'+sLineBreak+sLineBreak+
    ImageText+sLineBreak+'--home-reader-test--'+sLineBreak,TEncoding.ASCII);

  var Document:=TReaderDocument.Create;
  try
    for var Source in TArray<string>.Create(PictureXHTML,PictureLooseHTML,PictureMHTML) do
    begin
      Document.Load(Source);
      var Simplified:=Document.Warnings.IndexOf('HTML: показано упрощённое оформление.')>=0;
      Require(Simplified=(Source=PictureLooseHTML),'The HTML fixture ran through the wrong parser');
      var Text:=Document.PlainText;
      Require(Text.Contains('Начало [Изображение не читается.] Лист > 3 & примечание конец.'),
        'The reader lost the original description or its position in '+ExtractFileName(Source));
      Require(Text.Contains('Только подпись') and Text.Contains('[Изображение не читается.] Внешняя подпись'),
        'The reader lost a description for an omitted or inaccessible image in '+ExtractFileName(Source));
      Require((Document.ImageCount=1) and (Document.SkippedImages=2) and not Text.Contains('Уцелевшая картинка'),
        'The reader loaded the wrong image or duplicated the visible description in '+ExtractFileName(Source));
    end;
  finally Document.Free; end;
  Writeln('PASS reader keeps image descriptions in HTML XHTML and MHTML without duplicating available images');
end;

procedure TestReaderSessionContext;
var Book: TBookRecord; Request, Reloaded: TReaderSessionRequest;
  Reply, ReadReply: TReaderSessionReply; Lease: TReaderSessionLease;
  Archive: TZipFile; ArchiveReader: TMHLZip; Input: TStream; Data: TBytes;
  Root: TJSONObject; Original, Response, SourceHash: string;
  Blocked, OtherBlocked: Boolean; Worker: TThread; Recent: TArray<TReaderCatalogueRecent>;
  procedure RejectReply(const Contents: string);
  begin
    TFile.WriteAllText(Response,Contents,TEncoding.UTF8);
    ReadReply:=Reply;
    Require(not TryReadReaderSessionReply(Request,ReadReply),'Invalid reader response accepted');
    Require((ReadReply.State='') and not ReadReply.HasProgress and
      (ReadReply.RequestedNote.ID=''),'Invalid reader response left usable partial data');
  end;
begin
  RequireIsolatedRegression;
  Book:=Default(TBookRecord); Book.NodeType:=ntBookInfo;
  Book.BookKey:=CreateBookKey(4321,37); Book.CollectionRoot:=Settings.AppPath;
  Book.Folder:='session-books.zip'; Book.FileName:='second'; Book.FileExt:='.fb2';
  Book.InsideNo:=0; Book.Title:='Вторая книга: ё, ї, ў'; Book.LibID:='merged:37:98765';
  Book.Lang:='ru'; Include(Book.BookProps,bpIsLocal);
  Archive:=TZipFile.Create;
  try
    Archive.Open(Book.GetBookFileName,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes('wrong first book'),'first.fb2',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes('wrong capitalized book'),'Second.fb2',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes('selected second book'),'second.fb2',zcStored);
  finally Archive.Free; end;
  Book.Size:=TFile.GetSize(Book.GetBookFileName);
  SourceHash:=THashSHA2.GetHashStringFromFile(Book.GetBookFileName);
  SetLength(Recent,1);
  Recent[0].Key:=CreateBookKey(42,38); Recent[0].Identity:=StringOfChar('b',40);
  Recent[0].Caption:='Недавняя книга из другой коллекции';
  Request:=CreateReaderSession(Settings.AppPath,Book,'existing-history-id-ё',
    TPath.Combine(Settings.DataPath,'reader.ini'),True,'','',Recent);
  Original:=TFile.ReadAllText(Request.RequestFile,TEncoding.UTF8);
  // An ordinary UTF-8 file writer may add a BOM. It is not part of the JSON.
  TFile.WriteAllText(Request.RequestFile,Original,TEncoding.UTF8);
  Reloaded:=LoadReaderSession(Request.RequestFile);
  Require(Reloaded.Book.BookKey.IsSameAs(Book.BookKey) and
    (Reloaded.Book.FileName=Book.FileName) and (Reloaded.Book.InsideNo=0) and
    (Reloaded.Book.Title=Book.Title) and (Reloaded.Book.LibID=Book.LibID) and
    (Reloaded.HistoryIdentity='existing-history-id-ё') and
    (Reloaded.SettingsFile=Request.SettingsFile) and Reloaded.RequirePersonalProgress,'Reader session lost catalogue context');
  Require((Length(Reloaded.CatalogueRecent)=1) and Reloaded.CatalogueRecent[0].Key.IsSameAs(Recent[0].Key) and
    (Reloaded.CatalogueRecent[0].Identity=Recent[0].Identity) and (Reloaded.CatalogueRecent[0].Caption=Recent[0].Caption),
    'Reader session lost the catalogue recent entry');
  Input:=Reloaded.Book.GetBookStream(True,True);
  try
    SetLength(Data,Input.Size); Input.ReadBuffer(Data[0],Length(Data));
    Require(TEncoding.UTF8.GetString(Data)='selected second book',
      'Reader session chose the first archive member or a stale entry index');
  finally Input.Free; end;
  for var ExternalDecoder in [False,True] do
  begin
    ArchiveReader:=TMHLZip.Create(Book.GetBookFileName,True,False,nil,ExternalDecoder);
    Input:=TStringStream.Create('',TEncoding.UTF8);
    try
      ArchiveReader.ExtractToStream('second.fb2',Input);
      Require(TStringStream(Input).DataString='selected second book',
        'Exact extraction combined or chose the wrong archive entry');
      ArchiveReader.ExtractBookToStream('Second.fb2',0,Input);
      Require(TStringStream(Input).DataString='wrong capitalized book',
        'Selected case variant did not retain its own bytes');
      Require(ArchiveReader.ResolveBookName('FIRST.FB2',-1)='first.fb2',
        'A unique case-insensitive alias was lost');
      Blocked:=False;
      try ArchiveReader.ResolveBookName('SECOND.fb2',0);
      except on E:EArchiveBookEntryNotFound do Blocked:=True; end;
      Require(Blocked,'An ambiguous archive path fell back to the old index');
    finally Input.Free; ArchiveReader.Free; end;
  end;
  Writeln('PASS exact archive paths distinguish case variants with native ZIP and 7-Zip');
  var TrimmedZip:=Settings.AppPath+'trimmed-books.zip';
  Archive:=TZipFile.Create;
  try
    Archive.Open(TrimmedZip,zmWrite);
    Archive.Add(TEncoding.UTF8.GetBytes('different book'),'previous.epub',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes('chosen book'),'nested/selected ..epub',zcDeflate);
    Archive.Add(TEncoding.UTF8.GetBytes('first ambiguous book'),'collision .epub',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes('second ambiguous book'),'collision..epub',zcStored);
    Archive.Add(TEncoding.UTF8.GetBytes('other folder'),'other/selected ..epub',zcStored);
  finally Archive.Free; end;
  ArchiveReader:=TMHLZip.Create(TrimmedZip,True);
  Input:=TStringStream.Create('',TEncoding.UTF8);
  try
    Require(ArchiveReader.ResolveBookName('nested/selected.epub',-1,True)='nested/selected ..epub',
      'A unique trimmed ZIP path required a catalogue index');
    ArchiveReader.ExtractBookToStream('nested/selected.epub',0,Input);
    Require(TStringStream(Input).DataString='chosen book','A stale index outranked a unique trimmed ZIP path');
    Require(ArchiveReader.ResolveBookName('renamed-by-importer.epub',0)='previous.epub',
      'A ZIP with a position-only locator lost the legacy fallback');
    Blocked:=False;
    try ArchiveReader.ResolveBookName('collision.epub',2);
    except on E:EArchiveBookEntryNotFound do Blocked:=True; end;
    Require(Blocked,'An ambiguous trimmed ZIP path fell back to an index');
  finally Input.Free; ArchiveReader.Free; end;
  Writeln('PASS unique trimmed ZIP paths outrank stale indexes and ambiguous names are rejected');
  var AliasArchive:=Settings.AppPath+'trimmed-books.7z';
  var AliasFiles:=TArray<string>.Create(Settings.AppPath+'selected ..epub',
    Settings.AppPath+'collision .epub',Settings.AppPath+'collision..epub');
  for var FileName in AliasFiles do TFile.WriteAllText(FileName,ExtractFileName(FileName),TEncoding.UTF8);
  Input:=TMemoryStream.Create;
  try
    RunExternalToolToStream(FindExternalTool('7za.exe','7zip'),
      ['a','-t7z','-spd','--',AliasArchive,AliasFiles[0],AliasFiles[1],AliasFiles[2]],Input);
  finally Input.Free; end;
  ArchiveReader:=TMHLZip.Create(AliasArchive,True);
  try
    var Match, Collision: Integer;
    Match:=-1; Collision:=-1;
    for var Index:=0 to ArchiveReader.FileCount-1 do
    begin
      if ArchiveReader.FileNames[Index]='selected ..epub' then Match:=Index;
      if ArchiveReader.FileNames[Index]='collision .epub' then Collision:=Index;
    end;
    Require((Match>=0) and (Collision>=0),'Missing real 7z alias test entries');
    Require(ArchiveReader.ResolveBookName('selected.epub',Match,True)='selected ..epub',
      'An old 7z catalogue lost a book because its name was trimmed');
    for var Index in TArray<Integer>.Create(-1,Collision) do
    begin
      Blocked:=False;
      try ArchiveReader.ResolveBookName('selected.epub',Index);
      except on E:EArchiveBookEntryNotFound do Blocked:=True; end;
      Require(Blocked,'A missing or stale 7z index was accepted');
    end;
    Blocked:=False;
    try ArchiveReader.ResolveBookName('collision.epub',Collision);
    except on E:EArchiveBookEntryNotFound do Blocked:=True; end;
    Require(Blocked,'An ambiguous trimmed 7z name was accepted');
    var AliasBook:=Book;
    AliasBook.Folder:='trimmed-books.7z'; AliasBook.FileName:='selected';
    AliasBook.FileExt:='.epub'; AliasBook.InsideNo:=Match;
    Input:=AliasBook.GetBookStream(True,False);
    try Require(THashSHA2.GetHashString(Input)=THashSHA2.GetHashStringFromFile(AliasFiles[0]),
      '7z alias resolution extracted different bytes');
    finally Input.Free; end;
  finally ArchiveReader.Free; end;
  Writeln('PASS legacy 7z locators recover exact trimmed-stem bytes and reject stale indexes and ambiguous names');
  Require(ReaderSessionSourceMatches(Request,Book.GetBookFileName) and
    not ReaderSessionSourceMatches(Request,Settings.AppPath+'other.fb2'),
    'Reader session matched a different physical source');
  Lease:=TReaderSessionLease.Create(Request);
  try
    Blocked:=False;
    try Input:=TFileStream.Create(Request.SourceFile,fmOpenWrite or fmShareDenyNone); Input.Free;
    except on E: Exception do Blocked:=True; end;
    Require(Blocked,'A reader session allowed its source archive to be overwritten');
    Blocked:=False;
    try Input:=TFileStream.Create(Request.RequestFile,fmOpenWrite or fmShareDenyNone); Input.Free;
    except on E: Exception do Blocked:=True; end;
    Require(Blocked,'A live reader request could be replaced');
    OtherBlocked:=False;
    Worker:=TThread.CreateAnonymousThread(
      procedure
      var Other: TReaderSessionLease;
      begin
        try Other:=TReaderSessionLease.Create(Request); Other.Free;
        except on E: Exception do OtherBlocked:=True; end;
      end);
    Worker.FreeOnTerminate:=False;
    try Worker.Start; Worker.WaitFor; finally Worker.Free; end;
    Require(OtherBlocked,'A second reader acquired the same live session');
  finally Lease.Free; end;
  Lease:=TReaderSessionLease.Create(Request); Lease.Free;
  Reply:=Default(TReaderSessionReply); Reply.State:='closed'; Reply.ProcessID:=GetCurrentProcessID;
  Reply.HasProgress:=True; Reply.Progress:=42; Reply.RequestedNote.ID:='note-ё';
  Reply.RequestedNote.BookID:='other-history-id'; Reply.RequestedNote.BookTitle:='Другая книга';
  Reply.RequestedNote.Position:=12345; Reply.OriginProcessID:=123;
  Reply.RequestedCatalogueRecent:=1;
  WriteReaderSessionReply(Request,Reply);
  Require(TryReadReaderSessionReply(Request,ReadReply) and
    (ReadReply.State='closed') and ReadReply.HasProgress and (ReadReply.Progress=42) and
    (ReadReply.OriginProcessID=123) and (ReadReply.RequestedNote.ID='note-ё') and (ReadReply.RequestedNote.Position=12345),
    'Reader session lost progress or a requested note');
  Require(ReadReply.RequestedCatalogueRecent=1,'Reader session lost the recent-book request');
  Response:=TPath.Combine(ExtractFileDir(Request.RequestFile),'response.json');
  var ValidResponse:=TFile.ReadAllText(Response,TEncoding.UTF8);
  RejectReply(ValidResponse.Replace('"closed"','"unknown-state"'));
  RejectReply(ValidResponse.Replace(Request.ID,StringOfChar('0',32)));
  RejectReply(ValidResponse.Replace('"position":12345','"position":-1'));
  RejectReply(ValidResponse.Replace('"catalogue_recent":1','"catalogue_recent":2'));
  RejectReply('{"format":1');
  Reply.Progress:=101; Blocked:=False;
  try WriteReaderSessionReply(Request,Reply); except on E: Exception do Blocked:=True; end;
  Require(Blocked,'Reader session wrote an invalid progress percentage');
  Root:=TJSONObject.ParseJSONValue(Original) as TJSONObject;
  try
    Root.RemovePair('source').Free; Root.AddPair('source','relative.fb2');
    TFile.WriteAllText(Request.RequestFile,Root.ToJSON,TEncoding.UTF8);
  finally Root.Free; end;
  Blocked:=False;
  try Reloaded:=LoadReaderSession(Request.RequestFile); except on E: Exception do Blocked:=True; end;
  Require(Blocked,'Reader session accepted a relative source path');
  TFile.WriteAllText(Request.RequestFile,Original,TEncoding.UTF8);
  Require(THashSHA2.GetHashStringFromFile(Book.GetBookFileName)=SourceHash,
    'Reader session modified the source book archive');
  Writeln('PASS reader session preserves selected archive member history settings progress notes and source leases while rejecting invalid replies');

  var LegacyHTML:=Settings.AppPath+'legacy-links.html';
  var UnicodeHTML:=Settings.AppPath+'unicode-links.xhtml';
  var CodePage:=TEncoding.GetEncoding(1251);
  try
    TFile.WriteAllBytes(LegacyHTML,CodePage.GetBytes('<html><head><meta charset="windows-1251"></head><body>'+
      '<a href="#%DF+B">Literal jump</a><a href="#%DF+C">Legacy jump</a><a href="#absent">Missing jump</a>'+
      '<p id="Я+B">Literal target</p><p id="Я B">Other target</p><a name="Я C"></a><p>Legacy target</p></body></html>'));
  finally CodePage.Free; end;
  TFile.WriteAllText(UnicodeHTML,'<html><body><a href="#%D1%8F">Unicode jump</a>'+
    '<p id="я">Unicode target</p><a href="https://example.invalid/">External jump</a></body></html>',TEncoding.UTF8);
  var Document:=TReaderDocument.Create;
  try
    Document.Load(LegacyHTML);
    var Text:=Document.PlainText;
    var Target: Integer;
    Require(Length(Document.Links)=2,'The HTML fallback lost a local link or retained a missing target');
    Require(Document.LinkTargetAt(Text.IndexOf('Literal jump'),Target) and
      Text.Substring(Target).TrimLeft.StartsWith('Literal target'),'An HTML plus sign jumped to another anchor');
    Require(Document.LinkTargetAt(Text.IndexOf('Legacy jump'),Target) and
      Text.Substring(Target).TrimLeft.StartsWith('Legacy target'),'A legacy HTML link did not jump to its named anchor');
    Document.Load(UnicodeHTML);
    Text:=Document.PlainText;
    Require((Length(Document.Links)=1) and Document.LinkTargetAt(Text.IndexOf('Unicode jump'),Target) and
      Text.Substring(Target).TrimLeft.StartsWith('Unicode target'),'Well-formed XHTML lost a local Unicode link');
  finally Document.Free; end;
  Writeln('PASS HTML local links preserve UTF-8 legacy code page named anchors and literal plus targets');
  TestHTMLReaderPictures;
end;
