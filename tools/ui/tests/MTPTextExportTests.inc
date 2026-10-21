// Included by ExportResultsAuditTests.inc; runs only inside its existing mode.
// Uses the normal MTP shell-copy branch with an owned filesystem Shell folder.
// No device, downloaded book, external converter, live HTTP or new process.
type
  TMTPTextExportCapture = class
  public
    Messages: TStringList;
    function Message(const Text: string; Flags: Longint): Integer;
  end;

function TMTPTextExportCapture.Message(const Text: string; Flags: Longint): Integer;
begin
  Messages.Add(Text);
  if (Flags and $F)=MB_YESNO then Result:=IDYES else Result:=IDOK;
end;

procedure TestMTPTextExport;
const Payload='MTP TXT exact body: Ёж, Україна, 中文, 😀.';
var Root, SourceFile, ArchiveFile, Document, Destination, TempRoot, TempTXT, StaleFB2: string;
  PlainHash, ArchiveHash, SentinelHash, SavedFolder, SavedFile, Expected, Kind: string;
  CID, ID: Integer; Collection: IBookCollection; Books: array[0..1] of TBookRecord;
  Book, After: TBookRecord; Zip: TZipFile; Keys: TBookIdList;
  Worker: TExportToDeviceThread; Capture: TMTPTextExportCapture; Results: TBookExportResults;
  Item: IShellItem; Marshaled: IStream; HR: HRESULT; Files: TArray<string>;
  SavedEncoding: TTXTEncoding; SavedOverwrite, COMInitialized, OwnSentinel: Boolean;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(TPath.Combine(Settings.AppPath,'mtp-txt-'+TGUID.NewGuid.ToString));
  TempRoot:=IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.TempPath));
  Require(TPath.GetFullPath(Root).StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath)),True) and
    TempRoot.StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.AppPath)),True),
    'MTP TXT surrogate must stay inside its marked executable-owned runtime');
  ForceDirectories(Root); ForceDirectories(TempRoot);
  SourceFile:=Root+'source.fb2'; ArchiveFile:=Root+'source.zip';
  Document:='<?xml version="1.0" encoding="utf-8"?>'+sLineBreak+
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+sLineBreak+
    '<description><title-info><genre>prose_contemporary</genre><author><first-name>Own</first-name>'+
    '<last-name>Fixture</last-name></author><book-title>MTP TXT own fixture</book-title><lang>ru</lang>'+
    '</title-info></description>'+sLineBreak+'<body><section>'+sLineBreak+'<p>'+Payload+'</p>'+sLineBreak+
    '</section></body>'+sLineBreak+'</FictionBook>';
  TFile.WriteAllText(SourceFile,Document,TEncoding.UTF8);
  Zip:=TZipFile.Create;
  try Zip.Open(ArchiveFile,zmWrite); Zip.Add(TEncoding.UTF8.GetBytes(Document),'member.fb2'); Zip.Close;
  finally Zip.Free; end;
  PlainHash:=THashSHA2.GetHashStringFromFile(SourceFile); ArchiveHash:=THashSHA2.GetHashStringFromFile(ArchiveFile);
  CID:=SystemDB.CreateCollection('MTP TXT shell surrogate',Root,Root+'catalog.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst'); Collection:=SystemDB.GetCollection(CID);
  for var I:=0 to High(Books) do
  begin
    Book.Clear; Book.Title:='mtp-txt-'+IntToStr(I)+'-'+TGUID.NewGuid.ToString;
    Book.LibID:=Book.Title; Book.FileExt:='.fb2'; Book.Lang:='ru'; Book.Size:=100;
    Book.Date:=EncodeDate(2026,10,16); Include(Book.BookProps,bpIsLocal);
    Book.Rate:=3; Book.Progress:=17; Book.Annotation:='Личная аннотация MTP ё'; Book.Review:='Свой отзыв';
    if I=0 then Book.FileName:='source' else begin Book.Folder:='source.zip'; Book.FileName:='member'; end;
    TAuthorsHelper.Add(Book.Authors,'MTP','Own',''); TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    ID:=Collection.InsertBook(Book,False,False); Require(ID>0,'Cannot insert own MTP TXT source');
    Collection.GetBookRecord(CreateBookKey(ID,CID),Books[I],True);
  end;
  Require((Books[0].GetBookFormat=bfFb2) and (Books[1].GetBookFormat=bfFb2Archive),
    'MTP TXT surrogate did not establish both source branches');
  SavedFolder:=Settings.FolderTemplate; SavedFile:=Settings.FileNameTemplate;
  SavedEncoding:=Settings.TXTEncoding; SavedOverwrite:=Settings.OverwriteFB2Info;
  Settings.FolderTemplate:=''; Settings.FileNameTemplate:='%t'; Settings.TXTEncoding:=enUTF8;
  Settings.OverwriteFB2Info:=False; Capture:=TMTPTextExportCapture.Create; Capture.Messages:=TStringList.Create;
  COMInitialized:=False; Worker:=nil; OwnSentinel:=False; StaleFB2:='';
  try
    HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED); COMInitialized:=Succeeded(HR);
    Require(COMInitialized or (HR=RPC_E_CHANGED_MODE),'Cannot initialize own MTP TXT Shell COM');
    Expected:=Payload+sLineBreak;
    for var I:=0 to High(Books) do
      for var WithStale in TArray<Boolean>.Create(False,True) do
      begin
        if I=0 then Kind:='plain' else Kind:='archive';
        Destination:=TPath.Combine(Root,Kind+'-'+BoolToStr(WithStale,True)); ForceDirectories(Destination);
        TempTXT:=TPath.Combine(TempRoot,Books[I].Title+'.txt'); StaleFB2:=TPath.Combine(TempRoot,Books[I].Title+'.fb2');
        Require(not FileExists(TempTXT) and not FileExists(StaleFB2),'Own MTP TXT temp names are not fresh');
        if WithStale then
        begin
          TFile.WriteAllText(StaleFB2,'STALE FB2 MUST NEVER BE SENT '+Books[I].LibID,TEncoding.UTF8);
          OwnSentinel:=True; SentinelHash:=THashSHA2.GetHashStringFromFile(StaleFB2);
        end;
        SetLength(Keys,1); Keys[0]:=Default(TBookIdStruct); Keys[0].BookKey:=Books[I].BookKey;
        Keys[0].HasExpectedIdentity:=True; Keys[0].ExpectedLibID:=Books[I].LibID;
        Keys[0].ExpectedPhysicalIdentity:=ReaderBookPhysicalIdentity(Books[I]);
        Capture.Messages.Clear; Results:=nil; Worker:=TExportToDeviceThread.Create;
        try
          Require(Succeeded(SHCreateItemFromParsingName(PChar(Destination),nil,IShellItem,Item)),
            'Cannot obtain owned MTP TXT filesystem Shell destination');
          Require(Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem,Item,Marshaled)),
            'Cannot marshal owned MTP TXT Shell destination');
          Worker.DeviceDir:=Destination; Worker.BookIdList:=Keys; Worker.ExportMode:=emTxt;
          Worker.ExtractOnly:=False; Worker.UseMTP:=True; Worker.MarshalStream:=Marshaled;
          Worker.OnShowMessage:=Capture.Message; Worker.Start; Worker.WaitFor;
          Require(Worker.Finished and not Assigned(Worker.FatalException),'MTP TXT surrogate worker did not complete normally');
          Results:=Worker.Results;
        finally FreeAndNil(Worker); Marshaled:=nil; Item:=nil; end;
        Require((Length(Results)=1) and (Results[0].State=besSucceeded),
          'MTP TXT surrogate did not export the actual converted result: '+Capture.Messages.Text);
        Files:=TDirectory.GetFiles(Destination,'*',TSearchOption.soAllDirectories);
        Require((Length(Files)=1) and (ExtractFileName(Files[0])=Books[I].Title+'.txt'),
          'MTP TXT surrogate sent the source or stale FB2 instead of exactly one TXT');
        Require(TFile.ReadAllText(Files[0],TEncoding.UTF8)=Expected,'MTP TXT surrogate changed the exact Unicode body');
        Require(not FileExists(TempTXT),'Successful MTP TXT left its temporary converted artifact');
        if WithStale then
        begin
          Require(FileExists(StaleFB2) and (THashSHA2.GetHashStringFromFile(StaleFB2)=SentinelHash),
            'MTP TXT sent, removed or rewrote the unrelated stale FB2');
          TFile.Delete(StaleFB2); OwnSentinel:=False;
        end;
        Collection.GetBookRecord(Books[I].BookKey,After,True);
        Require((After.LibID=Books[I].LibID) and (After.Annotation=Books[I].Annotation) and
          (After.Review=Books[I].Review) and (After.Rate=Books[I].Rate) and (After.Progress=Books[I].Progress),
          'MTP TXT changed source catalog or personal fields');
        Require((THashSHA2.GetHashStringFromFile(SourceFile)=PlainHash) and
          (THashSHA2.GetHashStringFromFile(ArchiveFile)=ArchiveHash),'MTP TXT changed an original book or archive');
        Writeln('TRACE MTP TXT shell surrogate source=',Kind,' stale_fb2=',Ord(WithStale),
          ' succeeded=1 exact_unicode_txt=1 original_unchanged=1'); Flush(Output);
      end;
    Writeln('PASS export results MTP TXT filesystem-shell surrogate sends exact Unicode TXT from plain and archived FB2 and preserves stale FB2'); Flush(Output);
  finally
    Worker.Free; Marshaled:=nil; Item:=nil;
    if OwnSentinel and FileExists(StaleFB2) then TFile.Delete(StaleFB2);
    if COMInitialized then CoUninitialize;
    Capture.Messages.Free; Capture.Free;
    Settings.FolderTemplate:=SavedFolder; Settings.FileNameTemplate:=SavedFile;
    Settings.TXTEncoding:=SavedEncoding; Settings.OverwriteFB2Info:=SavedOverwrite;
  end;
end;
