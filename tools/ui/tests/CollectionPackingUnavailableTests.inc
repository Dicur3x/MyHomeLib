type
  TPackingReviewProbe = class
    Dialog: TfrmCollectionPackingProgress;
    OutputRoot: string;
    Cancel, SawEstimate, CheckFreshOutput: Boolean;
    ExpectedBooks, ExpectedUnavailable: Integer;
    procedure Tick(Sender: TObject);
  end;

  TPackingDownloadFixture = class
    ResponseFile: string;
    Requests: Integer;
    procedure Command(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
  end;

procedure TPackingReviewProbe.Tick(Sender: TObject);
var StartButton: TButton; Status: TCollectionPackingStatus;
begin
  StartButton:=TButton(Dialog.FindComponent('btnContinuePacking'));
  if SawEstimate or not StartButton.Visible then Exit;
  Status:=Dialog.ReadStatus;
  Require((Status.BooksTotal=ExpectedBooks) and (Status.Unavailable=ExpectedUnavailable) and
    (Status.PlannedInputBytes>0) and (Status.WorkingBytes>0) and (Status.FreeBytes>0),
    Format('Packing review figures differ: books %d, unavailable %d, input %d, working %d, free %d',
      [Status.BooksTotal,Status.Unavailable,Status.PlannedInputBytes,Status.WorkingBytes,Status.FreeBytes]));
  Require((Pos('Без файла: '+IntToStr(ExpectedUnavailable),TLabel(Dialog.FindComponent('lblPackingCounts')).Caption)>0) and
    (Pos('Свободно',TLabel(Dialog.FindComponent('lblPackingTime')).Caption)>0) and
    (not CheckFreshOutput or not DirectoryExists(TPath.Combine(OutputRoot,'archives'))),
    'Packing review hides a figure or started writing archives before approval');
  SawEstimate:=True;
  if Cancel then TButton(Dialog.FindComponent('btnCancelPacking')).Click
  else StartButton.Click;
end;

procedure TPackingDownloadFixture.Command(Context: TIdContext; Request: TIdHTTPRequestInfo;
  Response: TIdHTTPResponseInfo);
begin
  if Request.Document<>'/b/900002/get' then
  begin
    Response.ResponseNo:=404;
    Exit;
  end;
  InterlockedIncrement(Requests);
  Response.ResponseNo:=200;
  Response.ContentType:='application/zip';
  Response.ContentStream:=TFileStream.Create(ResponseFile,fmOpenRead or fmShareDenyNone);
  Response.FreeContentStream:=True;
end;

procedure TestPackingUnavailable;
var
  Source, CopyCollection: IBookCollection;
  SourceID, CopyID, LocalID, DownloadID, MissingID: Integer;
  Options: TCollectionPackingOptions;
  Book, MissingBook: TBookRecord;
  SourceDir, SourceMissing, CopiedDownload, CatalogHash, ResponseHash, OriginalCatalog,
    EmptyHash, SourceExtension: string;
  Zip: TZipFile;
  Stream: TStream;
  EmptyRejected: Boolean;
  Server: TIdHTTPServer;
  Fixture: TPackingDownloadFixture;
  Downloader: TDownloader;

  function ReviewPacking(Cancel: Boolean): TCollectionPackingSnapshot;
  var Dialog: TfrmCollectionPackingProgress; Probe: TPackingReviewProbe; Timer: TTimer;
  begin
    Result:=nil;
    Dialog:=TfrmCollectionPackingProgress.Create(nil);
    Probe:=TPackingReviewProbe.Create; Timer:=TTimer.Create(nil);
    try
      Probe.Dialog:=Dialog; Probe.OutputRoot:=Options.OutputRoot; Probe.Cancel:=Cancel;
      Probe.ExpectedBooks:=1; Probe.ExpectedUnavailable:=2; Probe.CheckFreshOutput:=True;
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
      try
        Result:=Dialog.Execute(Options,True);
      except
        on E:EAbort do if not Cancel then raise;
      end;
      Require(Probe.SawEstimate and (Assigned(Result)<>Cancel),
        'The packing review did not honor the chosen action');
    finally
      Timer.Free; Probe.Free; Dialog.Free;
    end;
  end;

  function MakeCopy(ExpectedPacked, ExpectedMissing, ExpectedReused: Integer): Integer;
  var Snapshot: TCollectionPackingSnapshot;
  begin
    Snapshot:=TCollectionPackingSnapshot.Create(Options);
    try
      Snapshot.Prepare;
      Require((Snapshot.PlannedLocations=ExpectedPacked) and (Snapshot.Status.Unavailable=ExpectedMissing),
        'Physical and unavailable locations were counted together');
      Snapshot.Pack;
      Require((Snapshot.Status.BooksDone=ExpectedPacked) and (Snapshot.Status.Unavailable=ExpectedMissing) and
        (Snapshot.Status.Reused=ExpectedReused),'Packing progress lost its unavailable or reused count');
      Snapshot.ApplyPrepared;
      Result:=Snapshot.RegisterNew(SystemDB);
    finally
      Snapshot.Free;
    end;
  end;

  procedure RejectPlan(const ExpectedError: string);
  var Snapshot: TCollectionPackingSnapshot;
  begin
    Snapshot:=TCollectionPackingSnapshot.Create(Options);
    try
      try
        Snapshot.Prepare;
      except
        on E: Exception do
        begin
          if ExpectedError='' then
          begin
            if not (E is EZipException) then raise;
          end
          else if not E.Message.Contains(ExpectedError) then raise;
          Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
            'Invalid plan registered a catalogue');
          Exit;
        end;
      end;
      Require(False,'Expected packing preparation to fail');
    finally
      Snapshot.Free;
    end;
  end;

  procedure WriteFixture(ID: Integer);
  var Value: TBookRecord; Destination: string;
  begin
    Source.GetBookRecord(CreateBookKey(ID,SourceID),Value,True);
    Destination:=Value.GetBookFileName;
    ForceDirectories(ExtractFileDir(Destination));
    TFile.Copy(Fixture.ResponseFile,Destination);
  end;

  procedure RequirePacked(ID: Integer);
  var Value: TBookRecord; Stream: TStream;
  begin
    CopyCollection.GetBookRecord(CreateBookKey(ID,CopyID),Value,True);
    Require((bpIsLocal in Value.BookProps) and Value.Folder.StartsWith('archives'+PathDelim),
      'Available book did not get a packed locator');
    Stream:=Value.GetBookStream(True,False);
    try
      Require(Assigned(Stream) and (THashSHA2.GetHashString(Stream)=ResponseHash),
        'A packed book changed bytes');
    finally
      Stream.Free;
    end;
  end;

begin
  CreateOnlineResponse;
  Settings.UseIESettings:=False; Settings.ProxyType:=0;
  SourceDir:=IncludeTrailingPathDelimiter(Settings.AppPath+'packing-missing-source');
  ForceDirectories(SourceDir);
  SourceID:=SystemDB.CreateCollection('Packing source',SourceDir,'packing-missing-source.hlc2',
    CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  LocalID:=AddOnlineBook(Source,'Already on disk','900001');
  DownloadID:=AddOnlineBook(Source,'Download later','900002');
  MissingID:=AddOnlineBook(Source,'Original becomes available','900003');
  Source.GetBookRecord(CreateBookKey(MissingID,SourceID),MissingBook,True);
  Include(MissingBook.BookProps,bpIsLocal);
  Include(MissingBook.BookProps,bpIsDeleted);
  Source.UpdateBook(MissingBook);
  SourceMissing:=MissingBook.GetBookFileName;

  Fixture:=TPackingDownloadFixture.Create;
  Server:=nil; Downloader:=nil;
  try
    Fixture.ResponseFile:=Settings.AppPath+'download-response.zip';
    ResponseHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'online-plain-response.fb2');
    Server:=TIdHTTPServer.Create(nil);
    Server.OnCommandGet:=Fixture.Command;
    var Binding:=Server.Bindings.Add;
    Binding.IP:='127.0.0.1'; Binding.Port:=0;
    Server.Active:=True;
    Source.SetProperty(PROP_URL,'http://127.0.0.1:'+IntToStr(Server.Bindings[0].Port)+'/');
    Source.SetProperty(PROP_CONNECTIONSCRIPT,'GET %URL%b/%LIBID%/get'+sLineBreak+'CHECK');

    Options:=Default(TCollectionPackingOptions);
    OriginalCatalog:=Source.GetProperty(PROP_DATAFILE);
    Options.CatalogFile:=OriginalCatalog;
    Options.PersonalFile:=Settings.SystemFileName[sfSystemDB];
    Options.SourceID:=SourceID;
    Options.SourceRoot:=SourceDir;
    Options.OutputRoot:=Settings.AppPath+'packing-no-local-files';
    Options.DisplayName:='Empty packing must fail';
    Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
    Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
    Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
    RejectPlan('не найдено локальных файлов');

    WriteFixture(LocalID);
    ForceDirectories(ExtractFileDir(SourceMissing));
    TFile.WriteAllBytes(SourceMissing,TEncoding.ASCII.GetBytes('Invalid ZIP'));
    Options.OutputRoot:=Settings.AppPath+'packing-invalid-archive';
    Options.DisplayName:='Corrupt packing must fail';
    RejectPlan('');
    TFile.Delete(SourceMissing);
    Zip:=TZipFile.Create;
    try
      Zip.Open(SourceMissing,zmWrite);
      Zip.Add(TEncoding.UTF8.GetBytes(''),MissingBook.FileName+MissingBook.FileExt);
      Zip.Close;
    finally Zip.Free; end;
    EmptyHash:=THashSHA2.GetHashStringFromFile(SourceMissing);
    EmptyRejected:=False;
    try
      Stream:=OpenArchivedBookSaveSource(MissingBook,SourceExtension);
      Stream.Free;
    except
      on E:Exception do EmptyRejected:=E.Message.Contains('пуст');
    end;
    Require(EmptyRejected,'An empty archive member was accepted for export');
    CatalogHash:=THashSHA2.GetHashStringFromFile(OriginalCatalog);

    Options.OutputRoot:=Settings.AppPath+'packing-mixed-copy';
    Options.DisplayName:='Packed online catalogue';
    ReviewPacking(True);
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName) and
      (Length(TDirectory.GetDirectories(Options.OutputRoot,'.job-*'))=0),
      'Canceling the estimate left a collection or disposable snapshot');
    var Prepared:=ReviewPacking(False);
    try
      Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
        'Progress registered a copy before final confirmation');
      CopyID:=Prepared.RegisterNew(SystemDB);
    finally Prepared.Free; end;
    Writeln('PASS packing estimate review, cancellation, continuation and separate registration');
    CopyCollection:=SystemDB.GetCollection(CopyID);
    RequirePacked(LocalID);
    CopyCollection.GetBookRecord(CreateBookKey(MissingID,CopyID),Book,True);
    Require((Book.Title=MissingBook.Title) and (Book.LibID=MissingBook.LibID) and
      (Book.Folder=MissingBook.Folder) and (bpIsDeleted in Book.BookProps) and
      not (bpIsLocal in Book.BookProps),'Missing file lost catalogue identity or kept a stale local flag');

    CopyCollection.GetBookRecord(CreateBookKey(DownloadID,CopyID),Book,True);
    CopiedDownload:=Book.GetBookFileName;
    Require(CopiedDownload.StartsWith(IncludeTrailingPathDelimiter(Options.OutputRoot),True) and
      not FileExists(CopiedDownload),'Missing online download target did not move to the copy');
    Downloader:=TDownloader.Create;
    Require(Downloader.Download(SystemDB,Book.BookKey) and (Fixture.Requests=1) and FileExists(CopiedDownload),
      'A missing book could not be downloaded through the copied connection script');
    Source.GetBookRecord(CreateBookKey(DownloadID,SourceID),Book,True);
    Require(not FileExists(Book.GetBookFileName) and
      (THashSHA2.GetHashStringFromFile(OriginalCatalog)=CatalogHash),
      'Downloading into the copy changed the source catalogue or its books');

    Require(THashSHA2.GetHashStringFromFile(SourceMissing)=EmptyHash,
      'Packing modified the original archive containing an empty member');
    TFile.Delete(SourceMissing);
    WriteFixture(MissingID);
    Options.CatalogFile:=CopyCollection.GetProperty(PROP_DATAFILE);
    Options.SourceID:=CopyID; Options.SourceRoot:=Options.OutputRoot;
    Options.DisplayName:='Packed online catalogue after new files';
    CopyID:=MakeCopy(3,0,1);
    CopyCollection:=SystemDB.GetCollection(CopyID);
    RequirePacked(LocalID); RequirePacked(DownloadID); RequirePacked(MissingID);
    Require(FileExists(SourceMissing) and FileExists(CopiedDownload),
      'Repacking removed previously available files');
  finally
    Downloader.Free;
    Server.Free;
    Fixture.Free;
  end;
  Writeln('PASS unavailable books remain in the catalogue, download into the copy, and become packable later');
  Writeln('PASS empty archived book cannot be exported and becomes packable when the source is restored');
end;
