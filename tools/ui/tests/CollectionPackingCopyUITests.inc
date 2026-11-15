// The source books, picker destinations and INPX all belong to the private
// portable runtime. Windows pickers/profile/registration use Computer Use.
type
  TPackingCopyUIDriver = class
    Timer:TTimer;
    Phase, Reviews, MaxReused:Integer;
    ProtectedFile, ProtectedSHA:string;
    procedure Tick(Sender:TObject);
  end;

procedure TPackingCopyUIDriver.Tick(Sender:TObject);
begin
  for var I:=0 to Screen.FormCount-1 do
    if (Screen.Forms[I] is TfrmCollectionPackingProgress) and Screen.Forms[I].Visible then
    begin
      var Form:=TfrmCollectionPackingProgress(Screen.Forms[I]);
      MaxReused:=Max(MaxReused,Integer(Form.ReadStatus.Reused));
      var Accept:=TButton(Form.FindComponent('btnContinuePacking'));
      if Accept.Visible and Accept.Enabled then
      begin
        Require(UpdateSHA256(ProtectedFile)=ProtectedSHA,'Copy review changed a protected source');
        // Three/four catalogue books plus the same selected book's personal locator.
        var Note:string:=TLabel(Form.FindComponent('lblPackingCounts')).Caption;
        Require(Note.Contains('Записей с файлами: '+IntToStr(Phase+3)) and Note.Contains('Без файла: 0'),
          'Copy estimate lost a readable book: '+Note);
        Inc(Reviews); Writeln('TRACE copy estimate approved phase=',Phase,' counts=',Note); Flush(Output);
        Accept.Click;
      end;
    end;
end;

procedure TestPackingCopyCatalogue;
const Extensions:array[0..3] of string=('.cbz','.docx','.odt','.docx');
var Source,FirstCopy,Updated:IBookCollection; SourceID,ID,FirstID,UpdatedID:Integer;
    OriginalRoot,OutputRoot,HeldRoot,SourceZIP,Index,BookPath:string;
    OriginalHashes,FirstHashes:TArray<string>; Sizes:TArray<Int64>;
    Book:TBookRecord; Archive:TZipFile; Driver:TPackingCopyUIDriver;
    Proof:TJSONObject; Info:TCollectionInfo; Profile:TPackingImageProfile; Gray:Boolean;
    OriginalPositions:TArray<Integer>;

  procedure CheckPersonal(const Collection:IBookCollection);
  var Personal:TBookRecord; Iterator:IBookIterator; Count:Integer;
  begin
    ID:=Collection.ResolveBookID('101',0); Require(ID>0,'Copy lost the personal book');
    SystemDB.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Personal);
    Require((Personal.Progress=37) and (Personal.Rate=4) and
      (SystemDB.GetReview(Personal.BookKey)='Copy UI note'),'Copy changed personal fields');
    Iterator:=SystemDB.GetBookIterator(FAVORITES_GROUP_ID,Collection.CollectionID); Count:=0;
    while Iterator.Next(Personal) do begin Inc(Count); Require(Personal.LibID='101','Copy added another favourite'); end;
    Require(Count=1,'Copy lost its favourite');
  end;

  procedure Verify(const Collection:IBookCollection; Count:Integer; const LabelName:string);
  var Stream:TStream; FileOut:TFileStream; Hash:string; Visible:Integer; Node:PVirtualNode; Data:PBookRecord;
  begin
    ForceDirectories(Settings.AppPath+'decoded-'+LabelName);
    for var I:=0 to Count-1 do
    begin
      ID:=Collection.ResolveBookID(IntToStr(101+I),0); Require(ID>0,'Copy lost a library ID');
      Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Book,True);
      Require((Book.Title='Copy UI '+IntToStr(101+I)) and (Book.FileExt=Extensions[I]),'Copy changed title or format');
      Require(Book.GetBookFileName.StartsWith(OutputRoot,True),'Copy still depends on an original archive');
      Stream:=Book.GetBookStream(True,False);
      try
        Require(Assigned(Stream) and (Stream.Size=Book.Size) and (Book.Size<Sizes[I]),'Copy has an invalid measured size');
        Hash:=THashSHA2.GetHashString(Stream); Stream.Position:=0;
        if LabelName='first' then FirstHashes[I]:=Hash
        else if I<3 then Require(Hash=FirstHashes[I],'INPX update recompressed a ready book');
        BookPath:=Settings.AppPath+'decoded-'+LabelName+'\'+IntToStr(101+I)+Extensions[I];
        FileOut:=TFileStream.Create(BookPath,fmCreate);
        try FileOut.CopyFrom(Stream,0); finally FileOut.Free; end;
      finally Stream.Free; end;
      if LabelName='first' then OriginalPositions[I]:=ID
      else if I<3 then Require(ID=OriginalPositions[I],'Packed INPX update renumbered a retained book');
    end;
    CheckPersonal(Collection);
    ShowPage(PAGE_SEARCH); frmMain.btnClearFilterEdits.Click; frmMain.acApplyPreset.Execute;
    Visible:=0; Node:=frmMain.tvBooksSR.GetFirst;
    while Assigned(Node) do
    begin
      Data:=frmMain.tvBooksSR.GetNodeData(Node);
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin
        Inc(Visible); Collection.GetBookRecord(Data^.BookKey,Book,False);
        Require(Data^.Size=Book.Size,'Registered copy shows a stale book size');
      end;
      Node:=frmMain.tvBooksSR.GetNext(Node);
    end;
    Require(Visible=Count,'Registered copy did not open all books in the normal search list');
  end;
begin
  OriginalRoot:=Settings.AppPath+'copy-originals\'; HeldRoot:=Settings.AppPath+'copy-originals-held';
  OutputRoot:=Settings.AppPath+'packed-copy\'; SourceZIP:=OriginalRoot+'shared.zip';
  Index:=Settings.AppPath+'copy-incoming\update.inpx';
  Require(FileExists(SourceZIP) and FileExists(Index),'Missing positively identified copy UI inputs');
  SourceID:=SystemDB.CreateCollection('Copy UI source',OriginalRoot,'copy-ui-source.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Source:=SystemDB.GetCollection(SourceID); SetLength(Sizes,4); SetLength(OriginalHashes,4);
  SetLength(FirstHashes,3); SetLength(OriginalPositions,3);
  for var I:=0 to 3 do
  begin
    BookPath:=Settings.AppPath+'known-inputs\'+IntToStr(101+I)+Extensions[I];
    Sizes[I]:=TFile.GetSize(BookPath); OriginalHashes[I]:=UpdateSHA256(BookPath);
    if I=3 then Continue;
    ID:=AddBook(Source,'Copy UI '+IntToStr(101+I),'CopyAuthor','ru','','prose_contemporary');
    Source.GetBookRecord(CreateBookKey(ID,SourceID),Book,True);
    Book.LibID:=IntToStr(101+I); Book.Folder:='shared.zip'; Book.FileName:=Book.LibID;
    Book.FileExt:=Extensions[I]; Book.Size:=Sizes[I]; Book.InsideNo:=I; Source.UpdateBook(Book);
  end;
  ID:=Source.ResolveBookID('101',0); Source.SetProgress(CreateBookKey(ID,SourceID),37);
  Source.SetRate(CreateBookKey(ID,SourceID),4); Source.SetReview(CreateBookKey(ID,SourceID),'Copy UI note');
  Source.AddBookToGroup(CreateBookKey(ID,SourceID),FAVORITES_GROUP_ID);
  Source.SetProperty(PROP_DATAVERSION,20261114);
  Settings.ActiveCollection:=SourceID; Settings.ActivePage:=PAGE_SEARCH; Settings.RestoreBookViews:=rbvAutomatic;
  Settings.TreeModes[PAGE_SEARCH]:=tmFlat;
  Application.CreateForm(TdmImages,dmImages); dmImages.ApplyThemeIcons;
  Application.CreateForm(TfrmMain,frmMain); frmMain.Show; Application.ProcessMessages;
  Driver:=TPackingCopyUIDriver.Create; Proof:=TJSONObject.Create;
  try
    Driver.Phase:=1; Driver.ProtectedFile:=SourceZIP; Driver.ProtectedSHA:=UpdateSHA256(SourceZIP);
    Driver.Timer:=TTimer.Create(nil); Driver.Timer.Interval:=50; Driver.Timer.OnTimer:=Driver.Tick;
    var Menu:=frmMain.FindComponent('miCreateCompressedCopy') as TMenuItem;
    Require(Assigned(Menu) and (Menu.Parent=frmMain.N2),'Missing ordinary compressed-copy menu');
    Writeln('TRACE copy menu ready output=',OutputRoot); Flush(Output); Menu.Click;
    FirstID:=Settings.ActiveCollection; Require(FirstID<>SourceID,'Copy was not registered/opened');
    FirstCopy:=SystemDB.GetCollection(FirstID);
    Require(IsPackedCollectionCatalog(FirstCopy.GetProperty(PROP_DATAFILE)),'Registered result is not a packed collection');
    Require(TryReadPackingImageProfile(OutputRoot,Profile,Gray) and (Profile=pipEconomy) and Gray,
      'The Windows profile dialog lost economy/grayscale choices');
    Require(Driver.Reviews=1,'Copy did not show its actual estimate');
    Require(RenameFile(ExcludeTrailingPathDelimiter(OriginalRoot),HeldRoot),'Cannot hide owned originals for the independent-copy check');
    try
      Verify(FirstCopy,3,'first'); Driver.Phase:=2; Driver.MaxReused:=0;
      Driver.ProtectedFile:=HeldRoot+'\shared.zip';
      Writeln('TRACE copy update menu ready inpx=',Index,' incoming=',ExtractFileDir(Index)); Flush(Output);
      frmMain.UpdateCollectionFromFileExecute(nil);
      UpdatedID:=Settings.ActiveCollection;
      Require((UpdatedID<>FirstID) and (UpdatedID<>SourceID),'Packed update replaced an existing catalogue');
      Updated:=SystemDB.GetCollection(UpdatedID); Verify(Updated,4,'updated');
      Require((Driver.Reviews=2) and (Driver.MaxReused>=1),'INPX copy update did not review/reuse old archive data');
      Info:=SystemDB.GetCollectionInfo(UpdatedID); Require(Info.DataVersion=20261115,'Copy update lost its INPX version');
      // The previous collection is still independently readable while the originals are absent.
      for var I:=0 to 2 do
      begin
        ID:=FirstCopy.ResolveBookID(IntToStr(101+I),0); FirstCopy.GetBookRecord(CreateBookKey(ID,FirstID),Book,True);
        var Stream:=Book.GetBookStream(True,False);
        try Require(Assigned(Stream) and (THashSHA2.GetHashString(Stream)=FirstHashes[I]),'Packed update changed an earlier copy');
        finally Stream.Free; end;
      end;
      CheckPersonal(FirstCopy);
    finally Require(RenameFile(HeldRoot,ExcludeTrailingPathDelimiter(OriginalRoot)),'Cannot restore owned original fixture'); end;
    Require(UpdateSHA256(SourceZIP)=Driver.ProtectedSHA,'Copy workflow changed original archive');
    for var I:=0 to 2 do
    begin
      ID:=Source.ResolveBookID(IntToStr(101+I),0); Source.GetBookRecord(CreateBookKey(ID,SourceID),Book,True);
      Require((Book.Size=Sizes[I]) and (Book.FileName=IntToStr(101+I)) and (Book.Folder='shared.zip'),
        'Copy workflow changed source metadata');
      var Stream:=Book.GetBookStream(True,False);
      try Require(Assigned(Stream) and (THashSHA2.GetHashString(Stream)=OriginalHashes[I]),'Copy workflow changed source book');
      finally Stream.Free; end;
    end;
    CheckPersonal(Source);
    Proof.AddPair('source',TJSONNumber.Create(SourceID)); Proof.AddPair('first',TJSONNumber.Create(FirstID));
    Proof.AddPair('updated',TJSONNumber.Create(UpdatedID)); Proof.AddPair('reviews',TJSONNumber.Create(Driver.Reviews));
    Proof.AddPair('reused',TJSONNumber.Create(Driver.MaxReused));
    Proof.AddPair('source_catalogue',VarToStr(Source.GetProperty(PROP_DATAFILE)));
    Proof.AddPair('first_catalogue',VarToStr(FirstCopy.GetProperty(PROP_DATAFILE)));
    Proof.AddPair('updated_catalogue',VarToStr(Updated.GetProperty(PROP_DATAFILE)));
    TFile.WriteAllText(Settings.AppPath+'copy-ui-results.json',Proof.ToJSON,TEncoding.UTF8);
    Writeln('PASS ordinary compressed-copy menu and INPX-only arrival register separate readable catalogues with personal data and unchanged ready books'); Flush(Output);
  finally
    Driver.Timer.Free; Driver.Free; Proof.Free;
    FreeAndNil(frmMain); FreeAndNil(dmImages);
  end;
end;
