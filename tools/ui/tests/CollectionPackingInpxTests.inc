type
  TPackedInpxResultProbe = class(TPackingReviewProbe)
    Accepted: Boolean;
    procedure Tick(Sender: TObject); reintroduce;
  end;

function AcceptPackedInpxResult(Window: HWND; Data: LPARAM): BOOL; stdcall;
var Caption: array[0..127] of Char;
begin
  Result:=True;
  if not IsWindowVisible(Window) then Exit;
  GetWindowText(Window,Caption,Length(Caption));
  if string(Caption)<>'Обновление коллекции' then Exit;
  TPackedInpxResultProbe(Pointer(Data)).Accepted:=True;
  PostMessage(Window,WM_USER+102,mrRetry,0); // TDM_CLICK_BUTTON
  Result:=False;
end;

procedure TPackedInpxResultProbe.Tick(Sender: TObject);
begin
  Dialog:=frmMain.FindComponent('CollectionPackingProgress') as TfrmCollectionPackingProgress;
  if Assigned(Dialog) then inherited Tick(Sender)
  else if SawEstimate and not Accepted then
    EnumThreadWindows(GetCurrentThreadId,@AcceptPackedInpxResult,LPARAM(Pointer(Self)));
end;

procedure TestPackedInpxResultChild;
var Probe: TPackedInpxResultProbe; Timer: TTimer; Started: UInt64; PreviousID: Integer;
begin
  PreviousID:=Settings.ActiveCollection;
  Settings.EnableSort:=False;
  Settings.RestoreBookViews:=rbvAutomatic;
  Application.CreateForm(TdmImages,dmImages);
  dmImages.ApplyThemeIcons;
  TfrmMain.DeferInitialCollection:=True;
  Application.CreateForm(TfrmMain,frmMain);
  Probe:=TPackedInpxResultProbe.Create;
  Timer:=TTimer.Create(nil);
  try
    Probe.ExpectedBooks:=4; Probe.ExpectedUnavailable:=1;
    Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
    frmSplash.Hide;
    frmMain.Show;
    frmMain.StartInitialCollectionLoad;
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages;
      CheckSynchronize(2);
      Sleep(5);
      Require(GetTickCount64-Started<45000,'Packed update did not open its new books');
    until Probe.Accepted and (frmMain.pgControl.ActivePage=frmMain.tsSearch);
    Require((Settings.ActiveCollection<>PreviousID) and
      (SystemDB.GetCollectionInfo(Settings.ActiveCollection).DataVersion=20261104) and
      (frmMain.cbDate.ItemIndex=SEARCH_DATE_LAST_CATALOG_UPDATE),
      'Packed update result did not open the filter on the registered generation');
    ExpectTitles(frmMain.tvBooksSR,['New title','Absent member']);
    Writeln('PASS packed INPX result opens only new books from the registered generation');
    Flush(Output);
  finally
    Timer.Free; Probe.Free;
    FreeAndNil(frmMain); FreeAndNil(dmImages);
  end;
end;

procedure TestPackingInpx;
var Source, PackedSource, Updated: IBookCollection; Book, Card: TBookRecord;
  Options: TCollectionPackingOptions; Snapshot: TCollectionPackingSnapshot;
  LegacyUpdate: TManualUpdateThread;
  SourceID, PackedID, UpdatedID, ChangedID, RetainedID, NewID, MissingID: Integer;
  Root, UpdateRoot, IndexFile, BeforeCatalog, BeforeHash, BeforePackedPath: string;
  ImageFixture, ResumeArgument, ChangedIndex: string;
  PendingPacking, ResumedPacking: TCollectionPackingRequest;
  Rejected: Boolean;
  Profile: TPackingImageProfile;
  Grayscale, UseJpegXL: Boolean;
  Archive: TZipFile;

  procedure AddZipText(const Name, Value: string);
  begin
    Archive.Add(TEncoding.UTF8.GetBytes(Value),Name);
  end;

  function Row(const Title, FileName, LibID: string; const Ext: string = 'txt'): string;
  begin
    Result:='Автор,Тест:'#4'prose_contemporary:'#4+Title+#4'Цикл из INPX'#4'1'#4+
      FileName+#4'123'#4+LibID+#4'0'#4+Ext+#4'2026-11-04'#4'ru';
  end;

  function AddInput(const Title, Name, LibID, Value: string): Integer;
  begin
    Result:=AddBook(Source,Title,'Автор','ru','Существующая серия','prose_contemporary');
    Source.GetBookRecord(CreateBookKey(Result,SourceID),Book,True);
    Book.FileName:=Name; Book.FileExt:='.txt'; Book.LibID:=LibID;
    Source.UpdateBook(Book);
    TFile.WriteAllBytes(TPath.Combine(Root,Name+'.txt'),TEncoding.UTF8.GetBytes(Value));
  end;

  function ReviewUpdate(Cancel: Boolean): TCollectionPackingSnapshot;
  var Dialog: TfrmCollectionPackingProgress; Probe: TPackingReviewProbe; Timer: TTimer;
  begin
    Result:=nil;
    Dialog:=TfrmCollectionPackingProgress.Create(nil);
    Probe:=TPackingReviewProbe.Create;
    Timer:=TTimer.Create(nil);
    try
      Probe.Dialog:=Dialog; Probe.Cancel:=Cancel;
      Probe.ExpectedBooks:=4; Probe.ExpectedUnavailable:=1;
      Timer.Interval:=20; Timer.OnTimer:=Probe.Tick;
      try
        Result:=Dialog.Execute(Options,True,IndexFile,UpdateRoot);
      except
        on E:EAbort do if not Cancel then raise;
      end;
      Require(Probe.SawEstimate and (Assigned(Result)<>Cancel),
        'INPX estimate did not honor cancellation or continuation');
    finally
      Timer.Free; Probe.Free; Dialog.Free;
    end;
  end;

  function ReadText(const Collection: IBookCollection; ID: Integer): string;
  var Value: TBookRecord; Stream: TStream; Bytes: TBytes;
  begin
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Value,True);
    Stream:=Value.GetBookStream(True,False);
    try
      Require(Assigned(Stream),'Expected exact packed text stream');
      SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes,Length(Bytes));
      Result:=TEncoding.UTF8.GetString(Bytes);
    finally Stream.Free; end;
  end;

  procedure InstallPackingCodecs;
  var Job, FileName, DecoderHash, Arch, JSON: string; Info: TProgramRelease;
  begin
    FileName:=Settings.AppPath+'official-jxl.zip';
    if ProgramUpdatePlatform='Win64' then Arch:='x64' else Arch:='x86';
    JSON:='{"tag_name":"v0.12.0","assets":[{"name":"jxl-'+Arch+'-windows-static.zip",'+
      '"browser_download_url":"https://github.com/libjxl/libjxl/releases/download/v0.12.0/jxl-'+Arch+'-windows-static.zip",'+
      '"digest":"sha256:'+UpdateSHA256(FileName)+'","size":'+IntToStr(TFile.GetSize(FileName))+'}]}';
    Require(IsOptionalComponent(JPEG_XL_ENCODER_COMPONENT) and ParseImageComponent(JSON,JPEG_XL_ENCODER_COMPONENT,Info) and
      Info.OfficialComponent and (Info.ComponentVersion='0.12.0') and
      IsOfficialComponentURL(JPEG_XL_ENCODER_COMPONENT,Info.ComponentVersion,Info.DownloadURL,ProgramUpdatePlatform,False),
      'Official encoder metadata was not accepted');
    TFile.Copy(ParamStr(0),Settings.AppPath+'HomeLibRu.exe');
    Options.JpegXLEncoder:=TPath.Combine(Settings.AppPath,ComponentFileName(JPEG_XL_ENCODER_COMPONENT));
    Options.JpegXLDecoder:=TPath.Combine(Settings.AppPath,ComponentFileName('JPEG XL'));
    Job:=Settings.AppPath+'packing-decoder-job';
    PrepareOfficialComponent(FileName,Job,'JPEG XL','0.12.0',ProgramUpdatePlatform);
    InstallProgramUpdate(Job,Settings.AppPath);
    Require(not ComponentNeedsRepair(Settings.AppPath,'JPEG XL') and not FileExists(Options.JpegXLEncoder),
      'Reading module installed the encoder');
    DecoderHash:=UpdateSHA256(Options.JpegXLDecoder);
    Job:=Settings.AppPath+'packing-encoder-job';
    PrepareOfficialComponent(FileName,Job,JPEG_XL_ENCODER_COMPONENT,'0.12.0',ProgramUpdatePlatform);
    InstallProgramUpdate(Job,Settings.AppPath);
    Require(not ComponentNeedsRepair(Settings.AppPath,JPEG_XL_ENCODER_COMPONENT) and
      (InstalledComponentVersion(Settings.AppPath,JPEG_XL_ENCODER_COMPONENT)='0.12.0') and
      (UpdateSHA256(Options.JpegXLDecoder)=DecoderHash), 'Installing the encoder changed the decoder or left an incomplete module');
    Writeln('PASS official JPEG XL encoder installs separately from the reading component');
  end;

  procedure CheckRecoveredPictures(Stream: TStream);
  var SourceStream: TFileStream; Hashes: TDictionary<string,string>; BookXML: IXMLFictionBook;
    Image: IXMLBinary; Expected: string;
    function ImageHash(const Picture: IXMLBinary): string;
    var Bytes: TBytesStream;
    begin
      Bytes:=TBytesStream.Create(TNetEncoding.Base64.DecodeStringToBytes(Picture.Text));
      try Result:=THashSHA2.GetHashString(Bytes); finally Bytes.Free; end;
    end;
  begin
    Hashes:=TDictionary<string,string>.Create;
    try
      SourceStream:=TFileStream.Create(ImageFixture,fmOpenRead or fmShareDenyWrite);
      try BookXML:=LoadFictionBook(SourceStream); finally SourceStream.Free; end;
      for var I:=0 to BookXML.Binary.Count-1 do
      begin
        Image:=BookXML.Binary[I]; Hashes.Add(Image.ID,ImageHash(Image));
      end;
      Image:=nil; BookXML:=nil;
      Stream.Position:=0;
      BookXML:=LoadFictionBook(Stream);
      Require((Hashes.Count>256) and (BookXML.Binary.Count=Hashes.Count),
        Format('Native INPX read returned %d of %d illustrations',[BookXML.Binary.Count,Hashes.Count]));
      for var I:=0 to BookXML.Binary.Count-1 do
      begin
        Image:=BookXML.Binary[I];
        Require(Hashes.TryGetValue(Image.ID,Expected) and (ImageHash(Image)=Expected),
          'Native INPX read changed image bytes: '+Image.ID);
        Hashes.Remove(Image.ID);
      end;
    finally Hashes.Free; end;
  end;

begin
  Root:=Settings.AppPath+'packing-inpx-source';
  UpdateRoot:=Settings.AppPath+'packing-inpx-input';
  ImageFixture:=Settings.AppPath+'packing-inpx-illustration.fb2';
  ForceDirectories(Root); ForceDirectories(UpdateRoot);
  SourceID:=SystemDB.CreateCollection('INPX packing source',Root,'packing-inpx-source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID);
  ChangedID:=AddInput('Earlier title','changed','10001','Earlier bytes');
  RetainedID:=AddInput('Untouched title','untouched','10002','Untouched bytes');
  Source.SetRate(CreateBookKey(ChangedID,SourceID),4);
  Source.SetProgress(CreateBookKey(ChangedID,SourceID),37);
  Source.SetReview(CreateBookKey(ChangedID,SourceID),'Личная заметка');
  Source.AddBookToGroup(CreateBookKey(ChangedID,SourceID),FAVORITES_GROUP_ID);

  Options:=Default(TCollectionPackingOptions);
  Options.CatalogFile:=Source.GetProperty(PROP_DATAFILE);
  Options.PersonalFile:=Settings.SystemFileName[sfSystemDB]; Options.SourceID:=SourceID;
  Options.SourceRoot:=Root; Options.OutputRoot:=Settings.AppPath+'packing-inpx-copy';
  Options.DisplayName:='Packed before INPX';
  Options.Python:=Settings.AppPath+'tools\kindle\python\python.exe';
  Options.SevenZip:=Settings.AppPath+'tools\7zip\7za.exe';
  Options.Script:=Settings.AppPath+'tools\collectionpack\pack_collection.py';
  UseJpegXL:=FileExists(Settings.AppPath+'official-jxl.zip');
  if UseJpegXL then
  begin
    Options.ImageProfile:=pipJpegXL;
    InstallPackingCodecs;
  end
  else if FileExists(ImageFixture) then Options.ImageProfile:=pipMaximum;
  Options.ImageGrayscale:=FileExists(Settings.AppPath+'packing-inpx-grayscale.flag');
  Snapshot:=TCollectionPackingSnapshot.Create(Options);
  try
    Snapshot.Prepare; Snapshot.Pack; Snapshot.ApplyPrepared;
    PackedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;
  PackedSource:=SystemDB.GetCollection(PackedID);
  PackedSource.GetBookRecord(CreateBookKey(RetainedID,PackedID),Book,True);
  BeforePackedPath:=Book.GetBookFileName;
  BeforeCatalog:=PackedSource.GetProperty(PROP_DATAFILE);
  BeforeHash:=THashSHA2.GetHashStringFromFile(BeforeCatalog);
  Archive:=TZipFile.Create;
  try
    Archive.Open(TPath.Combine(UpdateRoot,'books.zip'),zmWrite);
    AddZipText('unrelated.txt','Unrelated first member');
    if FileExists(ImageFixture) then Archive.Add(TFile.ReadAllBytes(ImageFixture),'new.fb2')
    else AddZipText('new.txt','New bytes from INPX');
    AddZipText('changed.txt','Changed bytes from INPX');
    Archive.Close;
    Archive.Open(TPath.Combine(UpdateRoot,'absent.zip'),zmWrite);
    AddZipText('untouched.txt','');
  finally Archive.Free; end;
  IndexFile:=TPath.Combine(UpdateRoot,'selected.inpx');
  Archive:=TZipFile.Create;
  try
    Archive.Open(IndexFile,zmWrite);
    AddZipText('structure.info','AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG');
    if FileExists(ImageFixture) then
      AddZipText('books.inp',Row('Changed title','changed','10001')+sLineBreak+
        Row('New title','new','10003','fb2')+sLineBreak+Row('Absent member','missing','10004')+sLineBreak)
    else
      AddZipText('books.inp',Row('Changed title','changed','10001')+sLineBreak+
        Row('New title','new','10003')+sLineBreak+Row('Absent member','missing','10004')+sLineBreak);
    AddZipText('absent.inp',Row('Untouched title','untouched','10002')+sLineBreak);
    AddZipText('version.info','20261104');
  finally Archive.Free; end;

  Options.CatalogFile:=BeforeCatalog; Options.SourceID:=PackedID;
  Options.SourceRoot:=Options.OutputRoot; Options.DisplayName:='Packed after INPX';
  Require(TryReadPackingImageProfile(Options.OutputRoot,Profile,Grayscale) and
    (Profile=Options.ImageProfile) and (Grayscale=Options.ImageGrayscale),
    'The destination did not retain the selected profile');
  Options.ImageProfile:=Profile;
  Options.ImageGrayscale:=Grayscale;
  Require(IsPackedCollectionCatalog(BeforeCatalog) and
    not IsPackedCollectionCatalog(Source.GetProperty(PROP_DATAFILE)), 'Packed catalogue marker recognition failed');
  LegacyUpdate:=TManualUpdateThread.Create(PackedID,IndexFile,True,gtFb2);
  try
    LegacyUpdate.Start; LegacyUpdate.WaitFor;
    Require(not LegacyUpdate.Success and not LegacyUpdate.CommittedChanges,
      'Ordinary full import replaced a packed catalogue');
  finally LegacyUpdate.Free; end;
  PendingPacking:=Default(TCollectionPackingRequest);
  PendingPacking.SourceID:=Options.SourceID;
  PendingPacking.CatalogFile:=Options.CatalogFile;
  PendingPacking.SourceRoot:=Options.SourceRoot;
  PendingPacking.OutputRoot:=Options.OutputRoot;
  PendingPacking.Inpx:=IndexFile;
  PendingPacking.UpdateRoot:=UpdateRoot;
  PendingPacking.ImageProfile:=Options.ImageProfile;
  PendingPacking.ImageGrayscale:=Options.ImageGrayscale;
  PendingPacking.CaptureIdentity;
  Require(not TakePackingContinuation(Settings.SettingsFileName,'',ResumedPacking),
    'Packing resumed without the updater restart switch');
  ResumeArgument:=StorePackingContinuation(Settings.SettingsFileName,PendingPacking);
  Require(not TakePackingContinuation(Settings.SettingsFileName,PACKING_RESUME_SWITCH+TGUID.NewGuid.ToString,ResumedPacking),
    'A different updater restart claimed the selected INPX request');
  Require(TakePackingContinuation(Settings.SettingsFileName,ResumeArgument,ResumedPacking),
    'The selected INPX request was lost after the component restart');
  ResumedPacking.CheckIdentity(Options.CatalogFile,Options.SourceRoot,Options.SourceID);
  Require((ResumedPacking.Inpx=IndexFile) and (ResumedPacking.UpdateRoot=UpdateRoot) and
    (ResumedPacking.OutputRoot=Options.OutputRoot) and (ResumedPacking.ImageProfile=Options.ImageProfile) and
    (ResumedPacking.ImageGrayscale=Options.ImageGrayscale),
    'The component restart changed a selected input or the profile');
  Require(not TakePackingContinuation(Settings.SettingsFileName,ResumeArgument,PendingPacking),
    'The same restart applied packing settings twice');

  ChangedIndex:=TPath.Combine(UpdateRoot,'changed.inpx');
  TFile.Copy(IndexFile,ChangedIndex);
  PendingPacking:=ResumedPacking;
  PendingPacking.Inpx:=ChangedIndex;
  PendingPacking.CaptureIdentity;
  TFile.AppendAllText(ChangedIndex,'changed');
  ResumeArgument:=StorePackingContinuation(Settings.SettingsFileName,PendingPacking);
  Require(TakePackingContinuation(Settings.SettingsFileName,ResumeArgument,PendingPacking),
    'Could not read the changed-source continuation test');
  Rejected:=False;
  try PendingPacking.CheckIdentity(Options.CatalogFile,Options.SourceRoot,Options.SourceID);
  except on E: Exception do Rejected:=E.Message.Contains('INPX'); end;
  Require(Rejected,'Packing accepted an INPX changed during component installation');
  Rejected:=False;
  try ResumedPacking.CheckIdentity(Options.CatalogFile,Options.SourceRoot,Options.SourceID+1);
  except on E: Exception do Rejected:=True; end;
  Require(Rejected,'Packing accepted a different source collection');
  Writeln('PASS packing restart restores selected INPX and profile once and rejects changed inputs');
  ReviewUpdate(True);
  Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName) and
    (THashSHA2.GetHashStringFromFile(BeforeCatalog)=BeforeHash),'Canceling the estimate changed the active collection');
  Snapshot:=ReviewUpdate(False);
  try
    Require((Snapshot.PlannedLocations>=3) and (Snapshot.Status.Unavailable=1),
      'INPX preparation did not distinguish an absent archive member');
    Require((Snapshot.Status.SourcesDone=2) and (Snapshot.Status.Reused=1),
      'INPX preparation reprocessed an unchanged source');
    if FileExists(ImageFixture) then
      Require((Snapshot.Status.ImageBooksOptimized=1) and (Snapshot.Status.ImageBooksSkipped=0),
        'The retained image profile did not optimize the new INPX book');
    Require(not SystemDB.HasCollectionWithProp(PROP_DISPLAYNAME,Options.DisplayName),
      'An INPX update was registered before publication');
    UpdatedID:=Snapshot.RegisterNew(SystemDB);
  finally Snapshot.Free; end;

  Updated:=SystemDB.GetCollection(UpdatedID);
  Require(Updated.ResolveBookID('10001',0)=ChangedID,'INPX changed the stable book number');
  Updated.GetBookRecord(CreateBookKey(ChangedID,UpdatedID),Book,True);
  Require(Book.Title='Changed title','Updated INPX metadata was not stored');
  SystemDB.GetBookRecord(CreateBookKey(ChangedID,UpdatedID),Card);
  Require((Card.Rate=4) and (Card.Progress=37) and
    (SystemDB.GetReview(Card.BookKey)='Личная заметка') and SameFileName(Card.GetBookFileName,Book.GetBookFileName),
    'INPX update lost personal data or left its physical card pointing at the old edition');
  Require(ReadText(Updated,ChangedID)='Changed bytes from INPX','Changed archive member was not updated exactly');
  Require(ReadText(Updated,RetainedID)='Untouched bytes','INPX update changed a retained book');
  Updated.GetBookRecord(CreateBookKey(RetainedID,UpdatedID),Book,True);
  Require(SameFileName(Book.GetBookFileName,BeforePackedPath),'INPX changed the untouched archive locator');
  NewID:=Updated.ResolveBookID('10003',0);
  Require(NewID>0,'New INPX book was not registered');
  if FileExists(ImageFixture) then
  begin
    Updated.GetBookRecord(CreateBookKey(NewID,UpdatedID),Book,True);
    var Stream:=Book.GetBookStream(True,True);
    try
      Require((Book.FileExt='.fb2') and Assigned(Stream) and (Stream.Size>0),
        'Native catalogue could not open the optimized FB2');
      if UseJpegXL then
      begin
        Require(SameText(ExtractFileExt(Book.GetBookFileName),'.7z'),'New INPX book did not use the separated JPEG layout');
        CheckRecoveredPictures(Stream);
      end
      else Require(Stream.Size<TFile.GetSize(ImageFixture),'Native catalogue did not open the optimized FB2 copy');
    finally Stream.Free; end;
    Writeln('PASS native packed INPX reuses the profile and opens the optimized FB2');
    if Grayscale then Writeln('PASS native INPX retains independent grayscale selection');
    if UseJpegXL then Writeln('PASS native INPX retains the JPEG XL profile and reconstructs every image exactly');
  end
  else Require(ReadText(Updated,NewID)='New bytes from INPX','New INPX book was not packed');
  MissingID:=Updated.ResolveBookID('10004',0);
  Require(MissingID>0,'An unavailable INPX book disappeared from the catalogue');
  Updated.GetBookRecord(CreateBookKey(MissingID,UpdatedID),Book,True);
  Require(not (bpIsLocal in Book.BookProps),'Missing INPX member was resolved to an unrelated archive entry');
  Require(Updated.HasLastCatalogUpdate and not PackedSource.HasLastCatalogUpdate,
    'The latest INPX result was not confined to the updated generation');
  var Search:=Default(TBookSearchCriteria);
  Search.DateIdx:=SEARCH_DATE_LAST_CATALOG_UPDATE; Search.CollapseMultiSeriesResults:=True;
  var NewBooks:=Updated.Search(Search,False);
  var SeenNew, SeenMissing: Boolean;
  SeenNew:=False; SeenMissing:=False;
  while NewBooks.Next(Book) do
    if (Book.BookKey.BookID=NewID) and not SeenNew then SeenNew:=True
    else if (Book.BookKey.BookID=MissingID) and not SeenMissing then SeenMissing:=True
    else Require(False,'Last INPX search included a replaced or unchanged packed book');
  Require(SeenNew and SeenMissing,'Last INPX search lost new packed catalogue records');
  NewBooks:=nil;
  Writeln('PASS last INPX search in a packed catalogue selects only the new records');
  Require((SystemDB.GetCollectionInfo(UpdatedID).DataVersion=20261104) and
    (SystemDB.GetCollectionInfo(PackedID).DataVersion<>20261104),'INPX version changed the old collection');
  Require((THashSHA2.GetHashStringFromFile(BeforeCatalog)=BeforeHash) and
    (ReadText(PackedSource,ChangedID)='Earlier bytes'),'INPX modified a registered previous catalogue or its books');
  Writeln('PASS selected INPX adds and replaces exact books, retains prior archives and IDs, and publishes a separate generation');
  Writeln('PASS an empty INPX replacement retains the previously readable book');
  Writeln('PASS selected INPX estimate cancels and continues, and legacy full import refuses a packed catalogue');
  if GetEnvironmentVariable('HOMELIB_PACKED_RESULT_COMPONENTS')<>'' then
  begin
    Settings.ActiveCollection:=PackedID;
    Settings.ActivePage:=PAGE_AUTHORS;
    Settings.SaveSettings;
    TFile.WriteAllText(Settings.AppPath+'packing-inpx-result.argument',
      StorePackingContinuation(Settings.SettingsFileName,ResumedPacking),TEncoding.ASCII);
  end;
end;
