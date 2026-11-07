type
  TBookDeletionDialogProbe = class
    Timer: TTimer;
    Accept: Boolean;
    Confirmations, Warnings: Integer;
    ExpectedCount, ExpectedArchives: Integer;
    Failure, LastConfirmation: string;
    BeforeAccept: TProc;
    OverrideFiles: Boolean;
    DeleteSource: Boolean;
    procedure Tick(Sender: TObject);
  end;

procedure TBookDeletionDialogProbe.Tick(Sender: TObject);
var Form: TForm; Text: string; DefaultNo: Boolean;
begin
  for var I := Screen.FormCount - 1 downto 0 do
  begin
    Form := Screen.Forms[I];
    if not Form.Visible or not ((Form.ClassName = 'TMessageForm') or
      (Form.Name = 'BookDeletionConfirmation')) then Continue;
    Text := GBIComponentText(Form);
    try
      if Text.Contains('Выбрано книг:') then
      begin
        Inc(Confirmations); LastConfirmation := Text;
        Require(Text.Contains('Коллекция: Delete safety'), 'Deletion omitted its collection');
        Require(Text.Contains('Выбрано книг: '+IntToStr(ExpectedCount)), 'Deletion counted repeated series rows as separate books');
        if ExpectedArchives > 0 then
          Require(Text.Contains('Книг в архивах: '+IntToStr(ExpectedArchives)) and
            Text.Contains('уберёт только выбранные книги'), 'Deletion hid its archive scope');
        DefaultNo := False;
        for var J := 0 to Form.ComponentCount - 1 do
          if Form.Components[J] is TButton then
            if TButton(Form.Components[J]).Default then
              DefaultNo := TButton(Form.Components[J]).ModalResult = mrNo;
        Require(DefaultNo, 'Destructive confirmation must default to No');
        var Files := Form.FindComponent('DeleteBookSourceFiles');
        Require(Files is TCheckBox, 'Deletion omitted its explicit physical-file choice');
        if OverrideFiles then
        begin
          Require(TCheckBox(Files).Enabled, 'Record deletion did not allow changing the file choice');
          TCheckBox(Files).Checked := DeleteSource;
        end;
        if Accept and Assigned(BeforeAccept) then begin BeforeAccept(); BeforeAccept := nil; end;
        if Accept then Form.ModalResult := mrYes else Form.ModalResult := mrNo;
      end
      else if Text.Contains('Не удалось полностью обработать книг:') or Text.Contains('Не удалось завершить удаление.') then
      begin Inc(Warnings); Form.ModalResult := mrOk; end
      else raise Exception.Create('Unexpected deletion dialog: '+Text);
    except
      on E: Exception do begin Failure := E.Message; Form.ModalResult := mrCancel; end;
    end;
    Exit;
  end;
end;

type TBookDeletionSafetyScenario = (bdsGeneral, bdsFLibrary, bdsLifecycle, bdsFLibraryReal);

procedure TestBookDeletionSafety(Scenario: TBookDeletionSafetyScenario = bdsGeneral);
var PrivateID, OnlineID, ExternalID, RawID, ArchiveID, OtherID, PrivateFBD, FailID, GoodID,
  SevenID, LegacyID, NeighbourID, Count: Integer;
  Collection: IBookCollection; Probe: TBookDeletionDialogProbe;
  Root, RawPath, ArchivePath, BeforeRaw, BeforeArchive, OldTemp, OldTmp: string;
  SavedDelete, SavedSelection, SavedDialogs: Boolean; Book, Other: TBookRecord;
  Tree: TBookTree; DB: TSQLiteDatabase; Locked: TFileStream;

  function XML(const Title: string): string;
  begin Result := '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'+
    '<description><title-info><book-title>'+Title+'</book-title><lang>ru</lang></title-info></description>'+
    '<body><section><p>Книга для проверки удаления — ё.</p></section></body></FictionBook>'; end;

  procedure WriteZip(const Name: string; const Entries: array of string);
  var Zip: TZipFile; Stream: TBytesStream;
  begin
    Zip := TZipFile.Create;
    try
      Zip.Open(Name,zmWrite);
      for var Entry in Entries do
      begin
        Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML(Entry)));
        try Zip.Add(Stream,Entry); finally Stream.Free; end;
      end;
    finally Zip.Free; end;
  end;

  function Insert(const Title, Folder, FileName, Ext: string; const LibraryID: string = ''): Integer;
  begin
    Book.Clear; Book.Title := Title; Book.Folder := Folder; Book.FileName := FileName;
    Book.FileExt := Ext; Book.LibID := Title;
    if LibraryID <> '' then Book.LibID := LibraryID;
    Book.Lang := 'ru'; Book.Size := 100;
    Book.Series := 'Delete series'; Book.Publisher := 'Delete publisher';
    Include(Book.BookProps,bpIsLocal); TAuthorsHelper.Add(Book.Authors,'Delete author','Alex','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    Result := Collection.InsertBook(Book,False,False); Require(Result>0,'Deletion fixture insert failed');
  end;

  function Exists(ID: Integer): Boolean;
  var Query: TSQLiteDatabase;
  begin
    Query := TSQLiteDatabase.CreateReadOnly(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName);
    try Result := Query.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID='+IntToStr(ID))=1;
    finally Query.Free; end;
  end;

  function Local(ID: Integer): Boolean;
  var Stored: TBookRecord;
  begin Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Stored,False);
    Result := bpIsLocal in Stored.BookProps; end;

  procedure AddRow(ID: Integer; Checked: Boolean; Parent: PVirtualNode = nil);
  var Node: PVirtualNode; Data: PBookRecord;
  begin
    Node := Tree.AddChild(Parent); Data := Tree.GetNodeData(Node);
    Collection.GetBookRecord(CreateBookKey(ID,Collection.CollectionID),Data^,False);
    if Checked then Tree.CheckState[Node] := csCheckedNormal;
  end;

  procedure Rows(const IDs: array of Integer; Page: Integer = PAGE_SEARCH);
  var Header: PVirtualNode; Data: PBookRecord;
  begin
    if Page = PAGE_PUBLISHER_SERIES then frmMain.pgControl.ActivePage := PublisherView.Tab
    else ShowPage(Page);
    case Page of
      PAGE_AUTHORS: Tree := frmMain.tvBooksA;
      PAGE_SERIES: Tree := frmMain.tvBooksS;
      PAGE_GENRES: Tree := frmMain.tvBooksG;
      PAGE_PUBLISHER_SERIES: Tree := PublisherView.Books;
      else Tree := frmMain.tvBooksSR;
    end;
    Tree.Clear; Header := Tree.AddChild(nil); Data := Tree.GetNodeData(Header);
    Data^.Clear; Data^.nodeType := ntSeriesInfo; Data^.Title := 'Delete series';
    for var ID in IDs do AddRow(ID,True,Header);
    if Length(IDs)>0 then AddRow(IDs[0],True); // Same book can appear in several series.
    Tree.FocusedNode := nil;
  end;

  procedure Execute(Accept, OnlyFiles: Boolean; Count, Archives: Integer; ExpectedWarnings: Integer = 0;
    const DuringProgress: TProc<TForm> = nil; Timeout: Cardinal = 20000);
  begin
    // Main initialization restores native common dialogs. Select the VCL
    // message form only after constructing Main so its real text is inspectable.
    Vcl.Dialogs.UseLatestCommonDialogs := False;
    Probe.Accept := Accept; Probe.ExpectedCount := Count; Probe.ExpectedArchives := Archives;
    Probe.Confirmations := 0; Probe.Warnings := 0; Probe.Failure := '';
    Probe.Timer.Enabled := True;
    Trace('delete safety invoking Main action');
    try
      if OnlyFiles then frmMain.miDeleteFilesClick(nil)
      else
      begin
        Require(frmMain.N74.Visible and frmMain.N74.Enabled and frmMain.tbtnDeleteBook.Visible,
          'Book deletion is unavailable in the menu or toolbar of the active collection');
        frmMain.N74.Click;
      end;
      var ProgressForm:=frmMain.FindComponent('BookDeletionProgress');
      if Assigned(ProgressForm) then
      begin
        Require(frmMain.Enabled,'Background deletion disabled the main window');
        var Started:=GetTickCount64;
        repeat
          if Assigned(DuringProgress) then DuringProgress(TForm(ProgressForm));
          Application.ProcessMessages;
          var CurrentProgress:=frmMain.FindComponent('BookDeletionProgress');
          Require((CurrentProgress=nil) or (CurrentProgress=ProgressForm),
            'One deletion batch opened a new progress window');
          if GetTickCount64-Started>Timeout then raise Exception.Create('Main archive deletion exceeded guard');
          Sleep(5);
        until not Assigned(frmMain.FindComponent('BookDeletionProgress'));
      end;
    finally Probe.Timer.Enabled := False; end;
    Require(Probe.Failure='',Probe.Failure);
    Require(Probe.Confirmations=1,'Deletion did not ask exactly once per batch');
    Require(Probe.Warnings=ExpectedWarnings,'Deletion did not aggregate failures into one warning');
  end;

  procedure Sources(const Tag: string);
  begin
    RawPath := Root+Tag+'.fb2'; ArchivePath := Root+Tag+'.zip';
    TFile.WriteAllText(RawPath,XML(Tag),TEncoding.UTF8); WriteZip(ArchivePath,['chosen.fb2','unselected.fb2']);
    RawID := Insert(Tag+' raw','',Tag,'.fb2');
    ArchiveID := Insert(Tag+' archived',Tag+'.zip','chosen','.fb2');
    OtherID := Insert(Tag+' unselected',Tag+'.zip','unselected','.fb2');
    Collection.SetReview(CreateBookKey(OtherID,Collection.CollectionID),'Сохранённая заметка — ё');
    BeforeRaw := THashSHA2.GetHashStringFromFile(RawPath);
    BeforeArchive := THashSHA2.GetHashStringFromFile(ArchivePath);
  end;

  procedure ProtectedArchive(Removed: Boolean=False);
  var Zip: TZipFile; Bytes: TBytes;
  begin
    if not Removed then
      Require(THashSHA2.GetHashStringFromFile(ArchivePath)=BeforeArchive,'Record-only deletion changed the shared archive');
    Require(Exists(OtherID) and (Collection.GetReview(CreateBookKey(OtherID,Collection.CollectionID))='Сохранённая заметка — ё'),
      'Deletion damaged another book or its personal note');
    Zip := TZipFile.Create;
    try Zip.Open(ArchivePath,zmRead); Zip.Read('unselected.fb2',Bytes);
      Require(Zip.FileCount=2-Ord(Removed),'Unexpected files in the shared archive after deletion');
      Require(TEncoding.UTF8.GetString(Bytes)=XML('unselected.fb2'),'Other archive member is no longer readable');
    finally Zip.Free; end;
  end;

  procedure FLibraryPictureDeletion;
  const Fixture='N3q8ryccAAS720OouwAAAAAAAAAhAAAAAAAAAC91JgIBAAxmaXh0dXJlIDEuZmIyAAEADGZpeHR1cmUgMi5mYjIAAQAWZml4dHVyZSBuZXN0ZWQvc2FtZS5mYjIAAQAPZml4dHVyZSBzYW1lLmZiMgAAAIEzB65tv4S4Pn+szENcZpUgYdHFIikzccx3Wit7Y7HNiFhZHKc/oqTFoLP1J93K4n9lHcojBCzfCpRQuHO0A+j7AG90HHi+m2+YW6HtzV4LLn9Qr7920LUFEwKry2qDCyFH4HKeuAAAFwZRAQlqAAcLAQABIwMBAQVdABAAAAyAsgoBRh9+dwAA';
  var One,Two,First,Second:Integer;
    RootArchive,Covers,Images:string; CurrentCollection:IBookCollection;

    procedure Verify(const FileName:string; const Members:array of string);
    var Zip:TZipFile; Bytes:TBytes;
    begin
      Zip:=TZipFile.Create;
      try
        Zip.Open(FileName,zmRead);
        Require(Zip.FileCount=Length(Members),'Wrong remaining image count: '+FileName);
        for var Member in Members do
        begin
          Zip.Read(Member,Bytes);
          Require(TEncoding.UTF8.GetString(Bytes)=XML(Member),'Retained image was changed: '+Member);
        end;
      finally Zip.Free; end;
    end;

    procedure Setup(const Folder:string);
    begin
      ForceDirectories(Root+Folder+'\covers'); ForceDirectories(Root+Folder+'\images');
      var Relative:=Folder+'\books.7z';
      RootArchive:=Root+Relative; Covers:=Root+Folder+'\covers\books.zip'; Images:=Root+Folder+'\images\books.zip';
      TFile.WriteAllBytes(RootArchive,TNetEncoding.Base64.DecodeStringToBytes(Fixture));
      One:=Insert(Folder+' one',Relative,'1','.fb2'); Two:=Insert(Folder+' two',Relative,'2','.fb2');
      First:=Insert(Folder+' shared first',Relative,'same','.fb2');
      Second:=Insert(Folder+' shared second',Relative,'nested\same','.fb2');
    end;

    procedure RecoverPictures(const Phase:string);
    var Selected:TArray<TBookRecord>; Binding:TBookDeletionBinding;
      Preparation:TBookDeletionPreparation; Queue:TArchiveDeletionQueue; Tasks:TArray<TArchiveDeletionTask>;
      SavedReceipt:TArchiveDeletionResult; Job, JournalRoot:string; Engine:TZipMemberDeletion;
      Operation:TBookDeletionOperation; Started:UInt64;
    begin
      Setup('flibrary-recovery-'+Phase);
      WriteZip(Covers,['1','2','same','readme']); WriteZip(Images,['1/1','2/1','same/1']);
      var IDs:=TArray<Integer>.Create(One,Two,First,Second);
      SetLength(Selected,4);
      for var I:=0 to High(Selected) do
        Collection.GetBookRecord(CreateBookKey(IDs[I],
          Collection.CollectionID),Selected[I],False);
      Binding:=TBookDeletionBinding.Capture(SystemDB.GetCollectionInfo(Collection.CollectionID),Selected,True);
      Preparation:=TBookDeletionPreparation.Create(Binding);
      try
        Preparation.Start; Preparation.WaitFor; Tasks:=Preparation.PreparedTasks;
        Require((Length(Tasks)=1) and (Length(Tasks[0].Companions)=2),'Preparation did not bind both picture archives');
      finally Preparation.Free; end;
      JournalRoot:=TPath.Combine(Settings.DataPath,'BookDeletion');
      Queue:=TArchiveDeletionQueue.Create(Tasks,JournalRoot,True);
      try
        Queue.Start; Started:=GetTickCount64;
        while Length(Queue.Results)=0 do
        begin
          Require(GetTickCount64-Started<15000,'Picture cleanup did not record an archive plan');
          Queue.WaitForResult(25);
        end;
        SavedReceipt:=Queue.Results[0];
        Require(SavedReceipt.FilesVerified,'Picture archive receipt preparation failed: '+SavedReceipt.Error);
      finally Queue.Free; end;
      Require(FileExists(RootArchive) and Exists(One),'Archive or catalogue changed before confirmation');
      Verify(Covers,['1','2','same','readme']); Verify(Images,['1/1','2/1','same/1']);
      if Phase<>'before-commit' then
      begin
        // Model a process stopping after the primary commit and halfway
        // through the companion phase, before its acknowledgement.
        Require(Binding.CommitRecords(SystemDB)=4,'Unable to commit the owned fixture before recovery');
        TFile.Delete(RootArchive);
        Job:=TPath.Combine(SavedReceipt.WorkDirectory,'pictures-0');
        ForceDirectories(Job);
        var Image:=Tasks[0].Companions[0];
        var Context:=THashSHA2.GetHashStringFromFile(TPath.Combine(SavedReceipt.WorkDirectory,'binding.json'));
        Engine:=TZipMemberDeletion.Prepare(Image.Archive,Image.Members,nil,nil,Image.SourceIdentity);
        try
          Engine.BindContext(Context);
          Engine.Execute(Job);
          if Phase='after-marker' then
            try
              Engine.Acknowledge(procedure begin
                TFile.WriteAllText(TPath.Combine(Job,'complete'),Context+':'+Image.SourceIdentity,TEncoding.ASCII);
                Abort;
              end);
            except on E:EAbort do ; end;
        finally Engine.Free; end;
        Verify(Covers,['readme']);
      end;
      if Phase='replaced-image' then
      begin
        TFile.Move(Images,Images+'.saved');
        WriteZip(Images,['foreign/0']);
      end;
      Operation:=TBookDeletionOperation.Recover(Settings.SystemFileName[sfSystemDB],JournalRoot);
      try
        Operation.Start; Started:=GetTickCount64;
        while not Operation.Status.Finished do
        begin
          Require(GetTickCount64-Started<15000,'Picture archive recovery timed out'); Sleep(5);
        end;
        Operation.WaitFor;
        Require((Operation.Status.Error='') and ((Operation.Status.CleanupWarning<>'')=(Phase='replaced-image')),
          'Picture archive recovery failed: '+Operation.Status.Error+' '+Operation.Status.CleanupWarning);
      finally Operation.Free; end;
      Require(not FileExists(RootArchive) and not Exists(One) and not Exists(Two) and
        (FileExists(Images)=(Phase='replaced-image')) and not DirectoryExists(JournalRoot),
        'Picture archive recovery did not finish');
      if Phase='replaced-image' then Verify(Images,['foreign/0']);
      Verify(Covers,['readme']);
    end;

  begin
    Settings.DeleteFiles:=True;
    Setup('flibrary-delete');
    WriteZip(Covers,['1','2','same','nested/same','readme']);
    WriteZip(Images,['1/cover','1/1','2/1','same/1','nested/same/1','archive-readme']);
    Rows([One,First]); Execute(True,False,2,2);
    Verify(Covers,['2','same','nested/same','readme']);
    Verify(Images,['2/1','same/1','nested/same/1','archive-readme']);
    Require(not Exists(One) and not Exists(First) and Exists(Two) and Exists(Second),
      'Picture cleanup did not retain the surviving books');
    Rows([Two,Second]); Execute(True,False,2,2);
    Verify(Covers,['readme']); Verify(Images,['archive-readme']);
    Require(not FileExists(RootArchive),'A wholly selected FLibrary book archive was not deleted');

    Setup('flibrary-all');
    WriteZip(Covers,['1','2','same']); WriteZip(Images,['1/0','2/1','same/1']);
    Rows([One,Two,First,Second]); Execute(True,False,4,4);
    Require(not FileExists(RootArchive) and not FileExists(Covers) and not FileExists(Images),
      'Fully owned companions were not removed together with the whole book archive');

    Setup('flibrary-reference');
    WriteZip(Covers,['1','2','same']); WriteZip(Images,['1/1','2/1','same/1']);
    var Hash:=THashSHA2.GetHashStringFromFile(Covers);
    CurrentCollection:=Collection; Collection:=SystemDB.GetCollection(ExternalID);
    try Insert('shared cover archive','flibrary-reference\covers\books.zip','1','.png');
    finally Collection:=CurrentCollection; end;
    Rows([One,Two,First,Second]); Execute(True,False,4,4);
    Require(not FileExists(RootArchive) and not FileExists(Images) and
      (THashSHA2.GetHashStringFromFile(Covers)=Hash),'Deletion changed a companion used directly by another collection');
    Writeln('PASS FLibrary deletion cleans private covers and images and preserves shared stems archives and unrelated members');
    for var Phase in ['before-commit','after-primary','after-marker','replaced-image'] do RecoverPictures(Phase);
    Writeln('PASS FLibrary companion plans resume before catalogue commit and during picture cleanup');
    Flush(Output);
  end;

  procedure TimeSingleBookZipBatch;
  const FixtureCount=3000;
  var Selected: TArray<TBookRecord>; SelectedIDs: TArray<Integer>;
    Operation: TBookDeletionOperation; State: TBookDeletionOperationStatus;
    Binding: TBookDeletionBinding; Timer: TStopwatch;
    ReferenceStart, FirstWrite, Finished: Int64; ZipFolder, NeighbourHash: string;
  begin
    ZipFolder:=Root+'delete-timing\'; ForceDirectories(ZipFolder);
    WriteZip(ZipFolder+'template.zip',['only.fb2']);
    NeighbourHash:=THashSHA2.GetHashStringFromFile(ZipFolder+'template.zip');
    for var I:=1 to FixtureCount do
      TFile.Copy(ZipFolder+'template.zip',ZipFolder+'book-'+IntToStr(I)+'.zip');
    Collection.BeginBulkOperation;
    try
      for var I:=1 to FixtureCount do
        Insert('Timing neighbour '+IntToStr(I),'delete-timing\book-'+IntToStr(I)+'.zip','only','.fb2');
      Collection.EndBulkOperation;
    except
      if Collection.InBulkOperation then Collection.EndBulkOperation(False);
      raise;
    end;
    for var BatchSize in [5,26,26] do
    begin
      SetLength(Selected,BatchSize); SetLength(SelectedIDs,BatchSize);
      for var I:=0 to BatchSize-1 do
      begin
        var Name:=Format('selected-%d.zip',[I]);
        TFile.Copy(ZipFolder+'template.zip',ZipFolder+Name);
        SelectedIDs[I]:=Insert(Name,'delete-timing\'+Name,'only','.fb2');
        Collection.GetBookRecord(CreateBookKey(SelectedIDs[I],Collection.CollectionID),Selected[I],False);
      end;
      Binding:=TBookDeletionBinding.Capture(SystemDB.GetCollectionInfo(Collection.CollectionID),Selected,True);
      Operation:=TBookDeletionOperation.Create(Binding,Settings.SystemFileName[sfSystemDB],
        TPath.Combine(Settings.DataPath,'BookDeletion'));
      try
        ReferenceStart:=-1; FirstWrite:=-1;
        Timer:=TStopwatch.StartNew; Operation.Start;
        repeat
          State:=Operation.Status;
          if (ReferenceStart<0) and (State.Stage='Проверка других записей в этих архивах') then
            ReferenceStart:=Timer.ElapsedMilliseconds;
          if (FirstWrite<0) and (State.ArchiveIndex>0) then FirstWrite:=Timer.ElapsedMilliseconds;
          if Timer.ElapsedMilliseconds>30000 then raise Exception.Create('Isolated archive timing exceeded guard');
          if not State.Finished then Sleep(1);
        until State.Finished;
        Operation.WaitFor;
        Finished:=Timer.ElapsedMilliseconds;
        Require((State.Error='') and (State.CleanupWarning='') and (State.CompletedBooks=BatchSize),
          'Timed deletion failed: '+State.Error+' '+State.CleanupWarning);
        Require((ReferenceStart>=0) and (FirstWrite>=ReferenceStart),'Timing missed the reference check');
        for var I:=0 to BatchSize-1 do
          Require(not Exists(SelectedIDs[I]) and not FileExists(Selected[I].GetBookFileName),
            'Timed deletion left a catalogue entry or its ZIP');
        Writeln(Format('TIMING single-book ZIPs: count=%d preparation=%dms references=%dms removal=%dms total=%dms',
          [BatchSize,ReferenceStart,FirstWrite-ReferenceStart,Finished-FirstWrite,Finished])); Flush(Output);
      finally Operation.Free; end;
    end;
    Require(THashSHA2.GetHashStringFromFile(ZipFolder+'book-1.zip')=NeighbourHash,
      'Timed deletion changed an unselected ZIP');
  end;

  procedure DeleteRealFLibraryDuplicate;
  const ArchiveStem = 'f.fb2-556318-558302';
    SelectedID = '557950';
    NeighbourID = '557949';
    Title = 'Ярлинги поневоле';
  var Archive, Covers, Images, Original, OriginalHash: string;
    OriginalCollection: IBookCollection;
    OriginalBook: TBookRecord;
    Selected, Neighbour, Duplicate: Integer;

    function Inventory(const FileName: string): TArray<string>;
    begin
      Result := ReadBookDeletionInventory(FileName, ArchiveDeletionSourceIdentity(FileName));
    end;

    function MemberHash(const FileName, Member: string): string;
    var Reader: TMHLZip; Content: TMemoryStream;
    begin
      Reader := TMHLZip.Create(FileName,True);
      try
        Content := TMemoryStream.Create;
        try
          Reader.ExtractToStream(Member,Content);
          Require(Content.Size>0,'Empty retained member: '+Member);
          Content.Position := 0;
          Result := THashSHA2.GetHashString(Content);
        finally Content.Free; end;
      finally Reader.Free; end;
    end;

    procedure CheckRemaining(const FileName: string; const Before: TArray<string>;
      const Removed: array of string);
    var After: TArray<string>; Index: Integer;
    begin
      After := Inventory(FileName);
      Require(Length(After)=Length(Before)-Length(Removed),'Incorrect member count: '+FileName);
      Index := 0;
      for var Member in Before do
      begin
        if MatchStr(StringReplace(Member,'\','/',[rfReplaceAll]),Removed) then Continue;
        Require((Index<Length(After)) and (After[Index]=Member),
          'An unselected member was renamed, removed or moved: '+Member);
        Inc(Index);
      end;
      Require(Index=Length(After),'Removed members did not match the exact expected paths');
    end;

  begin
    Archive := Root+'real-flibrary\'+ArchiveStem+'.7z';
    Covers := Root+'real-flibrary\covers\'+ArchiveStem+'.zip';
    Images := Root+'real-flibrary\images\'+ArchiveStem+'.zip';
    Original := Root+'real-original\'+SelectedID+'.fb2';
    OriginalHash := THashSHA2.GetHashStringFromFile(Original);
    var BeforeArchive := Inventory(Archive);
    var BeforeCovers := Inventory(Covers);
    var BeforeImages := Inventory(Images);
    var BookHash := MemberHash(Archive,NeighbourID+'.fb2');
    var CoverHash := MemberHash(Covers,NeighbourID);
    var ImageHash := MemberHash(Images,NeighbourID+'/1');
    Require(MemberHash(Archive,SelectedID+'.fb2')<>OriginalHash,
      'Expected real ordinary and compact copies of the same book');
    OriginalCollection := SystemDB.GetCollection(ExternalID);
    var CompactCollection := Collection;
    Collection := OriginalCollection;
    try
      Duplicate := Insert(Title,'real-original',SelectedID,'.fb2',SelectedID);
    finally Collection := CompactCollection; end;
    Selected := Insert(Title,'real-flibrary\'+ArchiveStem+'.7z',SelectedID,'.fb2',SelectedID);
    Neighbour := Insert('Neighbour '+NeighbourID,'real-flibrary\'+ArchiveStem+'.7z',NeighbourID,'.fb2',NeighbourID);
    Collection.SetReview(CreateBookKey(Neighbour,Collection.CollectionID),'Retained FLibrary neighbour');
    Settings.DeleteFiles := True;
    Rows([Selected]);
    Execute(True,False,1,1,0,nil,150000);
    Require(not Exists(Selected) and Exists(Neighbour) and
      (Collection.GetReview(CreateBookKey(Neighbour,Collection.CollectionID))='Retained FLibrary neighbour'),
      'FLibrary deletion changed the neighbour record or note');
    OriginalCollection.GetBookRecord(CreateBookKey(Duplicate,ExternalID),OriginalBook,False);
    Require((OriginalBook.BookKey.BookID=Duplicate) and (OriginalBook.LibID=SelectedID) and
      SameFileName(OriginalBook.GetBookFileName,Original) and
      (THashSHA2.GetHashStringFromFile(Original)=OriginalHash), 'The second copy did not survive');
    CheckRemaining(Archive,BeforeArchive,[SelectedID+'.fb2']);
    CheckRemaining(Covers,BeforeCovers,[SelectedID]);
    CheckRemaining(Images,BeforeImages,[SelectedID+'/1',SelectedID+'/2']);
    Require((MemberHash(Archive,NeighbourID+'.fb2')=BookHash) and
      (MemberHash(Covers,NeighbourID)=CoverHash) and (MemberHash(Images,NeighbourID+'/1')=ImageHash),
      'The retained FLibrary book, cover or illustration changed');
    Writeln(Format('PASS real FLibrary duplicate deletes only the selected book cover and images and preserves the second copy (%d/%d/%d archive entries checked)',
      [Length(BeforeArchive),Length(BeforeCovers),Length(BeforeImages)]));
    Flush(Output);
  end;

  procedure StopOrCloseDeletion(CloseMain: Boolean);
  var FirstZip, SecondZip, SecondHash, JournalRoot, LabelText: string;
    FirstBook, SecondBook, KeepFirst, KeepSecond: Integer;
    KeptBytes, ReadBytes: TBytes;
    Zip: TZipFile;
    KeptStream: TBytesStream;
    Requested: Boolean;
    ClosedAt: UInt64;
  begin
    LabelText := 'stop';
    if CloseMain then LabelText := 'close';
    FirstZip := Root + LabelText + '-first.zip';
    SecondZip := Root + LabelText + '-second.zip';
    JournalRoot := TPath.Combine(Settings.DataPath, 'BookDeletion');
    SetLength(KeptBytes, 32 * 1024 * 1024);
    for var Index := 0 to High(KeptBytes) do
      KeptBytes[Index] := Byte((Index * 13 + 17) mod 251);
    Zip := TZipFile.Create;
    try
      Zip.Open(FirstZip, zmWrite);
      KeptStream := TBytesStream.Create(TEncoding.UTF8.GetBytes(XML('first selected')));
      try Zip.Add(KeptStream, 'chosen.fb2'); finally KeptStream.Free; end;
      KeptStream := TBytesStream.Create(KeptBytes);
      try Zip.Add(KeptStream, 'keep.fb2', zcStored); finally KeptStream.Free; end;
    finally Zip.Free; end;
    WriteZip(SecondZip, ['chosen.fb2', 'keep.fb2']);
    SecondHash := THashSHA2.GetHashStringFromFile(SecondZip);
    FirstBook := Insert(LabelText+' first', ExtractFileName(FirstZip), 'chosen', '.fb2');
    KeepFirst := Insert(LabelText+' first neighbour', ExtractFileName(FirstZip), 'keep', '.fb2');
    SecondBook := Insert(LabelText+' second', ExtractFileName(SecondZip), 'chosen', '.fb2');
    KeepSecond := Insert(LabelText+' second neighbour', ExtractFileName(SecondZip), 'keep', '.fb2');
    Settings.DeleteFiles := True;
    frmMain.Show;
    Application.ProcessMessages;
    Rows([FirstBook, SecondBook]);
    Requested := False;
    Execute(True, False, 2, 2, 0,
      procedure(Progress: TForm)
      begin
        if Requested or not DirectoryExists(JournalRoot) then Exit;
        // A live pending block marks the archive write boundary. Stop then
        // must finish this archive and its catalogue phase before leaving.
        if Length(TDirectory.GetFiles(JournalRoot,'pending.bin',TSearchOption.soAllDirectories))=0 then Exit;
        var StopButton := TButton(Progress.FindComponent('StopBookDeletion'));
        Require(Assigned(StopButton) and StopButton.Enabled and frmMain.Visible,
          'Archive work did not expose the live Stop button');
        if CloseMain then
        begin
          frmMain.Close;
          Require(frmMain.Visible and not Application.Terminated,
            'Closing Main abandoned an active archive');
        end
        else StopButton.Click;
        Requested := True;
        Require(not StopButton.Enabled, 'Stop was not delivered to the live deletion operation');
      end);
    Require(Requested, 'Test did not observe the archive write boundary');
    if CloseMain then
    begin
      ClosedAt := GetTickCount64;
      while frmMain.Visible and not Application.Terminated do
      begin
        Application.ProcessMessages;
        Require(GetTickCount64-ClosedAt<5000, 'Main did not close after deletion completed');
        Sleep(5);
      end;
    end
    else Require(frmMain.Visible and frmMain.Enabled and not Application.Terminated,
      'Stopping deletion disabled or closed Main');
    Require(not Exists(FirstBook) and Exists(KeepFirst) and Exists(SecondBook) and Exists(KeepSecond),
      'Stopping at the current archive removed the wrong catalogue records');
    Require(THashSHA2.GetHashStringFromFile(SecondZip)=SecondHash, 'Stop modified the queued archive');
    Zip := TZipFile.Create;
    try
      Zip.Open(FirstZip,zmRead);
      Require((Zip.FileCount=1) and (Zip.FileNames[0]='keep.fb2'), 'Active archive did not finish its update');
      Zip.Read('keep.fb2',ReadBytes);
      Require((Length(ReadBytes)=Length(KeptBytes)) and CompareMem(@ReadBytes[0],@KeptBytes[0],Length(KeptBytes)),
        'Active archive lost its retained payload');
    finally Zip.Free; end;
    Require(not DirectoryExists(JournalRoot) or TDirectory.IsEmpty(JournalRoot),
      'Acknowledged deletion kept a recovery journal');
    Writeln('PASS Main '+LabelText+' finishes current archive and catalogue records and leaves the queued archive intact');
    Flush(Output);
  end;

begin
  RequireIsolatedRegression;
  Trace('delete safety create private fixtures');
  Root := Settings.AppPath+'book-delete-source\'; ForceDirectories(Root);
  PrivateID := SystemDB.CreateCollection('Delete safety private',Root,'delete-private.hlc2',CT_PRIVATE_FB,Settings.AppPath+'genres_fb2.glst');
  OnlineID := SystemDB.CreateCollection('Delete safety online',Root,'delete-online.hlc2',CT_EXTERNAL_ONLINE_FB,Settings.AppPath+'genres_fb2.glst');
  ExternalID := SystemDB.CreateCollection('Delete safety external FB2',Root,'delete-external.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  SavedDelete := Settings.DeleteFiles; SavedSelection := Settings.SelectedIsChecked;
  SavedDialogs := Vcl.Dialogs.UseLatestCommonDialogs;
  OldTemp := GetEnvironmentVariable('TEMP'); OldTmp := GetEnvironmentVariable('TMP');
  ForceDirectories(Root+'logs'); SetEnvironmentVariable('TEMP',PChar(Root+'logs')); SetEnvironmentVariable('TMP',PChar(Root+'logs'));
  Probe := TBookDeletionDialogProbe.Create; Probe.Timer := TTimer.Create(nil);
  Probe.Timer.Enabled := False; Probe.Timer.Interval := 15; Probe.Timer.OnTimer := Probe.Tick;
  try
    Settings.SelectedIsChecked := True; Vcl.Dialogs.UseLatestCommonDialogs := False;
    Settings.ShowInfoPanel := False; Settings.ShowBookCover := False; Settings.ShowBookAnnotation := False;
    Trace('delete safety replace isolated Main');
    FreeAndNil(frmMain); Settings.ActiveCollection := PrivateID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(PrivateID);
    case Scenario of
      bdsFLibrary: begin FLibraryPictureDeletion; Exit; end;
      bdsFLibraryReal: begin DeleteRealFLibraryDuplicate; Exit; end;
      bdsLifecycle: begin StopOrCloseDeletion(False); StopOrCloseDeletion(True); Exit; end;
    end;

    Trace('delete safety cancellation');
    Settings.DeleteFiles := True; Sources('cancel'); Trace('delete safety source files ready'); Rows([RawID,ArchiveID]); Trace('delete safety selection ready'); Execute(False,False,2,1);
    Require(Exists(RawID) and Exists(ArchiveID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Canceled deletion changed the book'); ProtectedArchive;
    Settings.DeleteFiles := False; Rows([RawID,ArchiveID]); Execute(True,False,2,0);
    Require(not Exists(RawID) and not Exists(ArchiveID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Record-only deletion changed files'); ProtectedArchive;

    Trace('delete safety records and source files');
    Settings.DeleteFiles := True; Sources('delete-files');
    var PairZip:=TZipFile.Create;
    try
      PairZip.Open(Root+'private-book.zip',zmWrite);
      for var Entry in ['private-book.fbd','private-book.fb2','readme.txt'] do
      begin
        var Bytes:=TBytesStream.Create(TEncoding.UTF8.GetBytes(XML(Entry)));
        try PairZip.Add(Bytes,Entry); finally Bytes.Free; end;
      end;
    finally PairZip.Free; end;
    PrivateFBD := Insert('private FBD','','private-book.zip','.fb2');
    Rows([RawID,ArchiveID,PrivateFBD]); Execute(True,False,3,2);
    Require(not Exists(RawID) and not Exists(ArchiveID) and not Exists(PrivateFBD) and not FileExists(RawPath) and FileExists(Root+'private-book.zip'),
      'Deletion failed to distinguish the raw book and private/shared archives'); ProtectedArchive(True);
    PairZip:=TZipFile.Create;
    try
      PairZip.Open(Root+'private-book.zip',zmRead);
      Require((PairZip.FileCount=1) and (PairZip.FileNames[0]='readme.txt'),
        'Only the private FBD descriptor and book may be removed');
    finally PairZip.Free; end;

    // Valid two-member 7z made by 7-Zip and independently tested before
    // embedding. Preservation/fallback checks require no installed decoder.
    TFile.WriteAllBytes(Root+'fallback.7z',TNetEncoding.Base64.DecodeStringToBytes(
      'N3q8ryccAASkdbxdnQAAAAAAAAAhAAAAAAAAAObLj+dPd25lZCBjaG9zZW4gYm9va093bmVkIHByb3RlY3RlZCBuZWlnaGJvdXJpbmcgYm9vawAAgTMHrjGZZ562gPIalnBnsCPEi+eGNCu7DSNRYELXNgsyAM33hSbO+pghYazfJwTN+wZppJl14obMIKq07QZm6Z4euNEvjySl4Wvysd1OiLu31MyKy4dm5buX25eqzGELLrs2FzwPqjJgFwYyAQlrAAcLAQABIwMBAQVdABAAAAyAhgoBCrGfBgAA'));
    SevenID := Insert('7z source','fallback.7z','chosen','.fb2');
    LegacyID := Insert('legacy ZIP alias','fallback.zip','chosen','.fb2');
    NeighbourID := Insert('7z unselected','fallback.7z','unselected','.fb2');
    Collection.GetBookRecord(CreateBookKey(LegacyID,PrivateID),Book,False);
    Require(SameFileName(Book.GetBookFileName,Root+'fallback.7z'),'Legacy fixture did not resolve ZIP to existing 7z');
    BeforeRaw := THashSHA2.GetHashStringFromFile(Root+'fallback.7z');
    Rows([SevenID,LegacyID]); Probe.OverrideFiles:=True; Probe.DeleteSource:=False;
    try Execute(True,False,2,2); finally Probe.OverrideFiles:=False; end;
    Require(not Exists(SevenID) and not Exists(LegacyID) and Exists(NeighbourID) and Local(NeighbourID) and
      (THashSHA2.GetHashStringFromFile(Root+'fallback.7z')=BeforeRaw),'Deletion removed a 7z or its legacy ZIP fallback neighbour');

    Trace('delete safety remove empty containers');
    ArchivePath:=Root+'last-book.zip';
    WriteZip(ArchivePath,['only.fb2']);
    ArchiveID:=Insert('last ZIP book','last-book.zip','only','.fb2');
    Rows([ArchiveID]); Execute(True,False,1,1);
    Require(not Exists(ArchiveID) and not FileExists(ArchivePath),
      'The last book and its empty ZIP must both disappear');

    SevenID:=Insert('last 7z selected book','fallback.7z','chosen','.fb2');
    Rows([SevenID,NeighbourID]); Execute(True,False,2,2);
    Require(not Exists(SevenID) and not Exists(NeighbourID) and not FileExists(Root+'fallback.7z'),
      'The final 7z books and their empty container must all disappear');

    ArchivePath:=Root+'linked-last-book.zip';
    WriteZip(ArchivePath,['only.fb2']);
    var LinkPath:=Root+'linked-last-book-alias.zip';
    Win32Check(CreateHardLink(PChar(LinkPath),PChar(ArchivePath),nil));
    ArchiveID:=Insert('linked last ZIP book','linked-last-book.zip','only','.fb2');
    Rows([ArchiveID]); Execute(True,False,1,1);
    Require(not Exists(ArchiveID) and FileExists(ArchivePath) and FileExists(LinkPath),
      'Removing a last book must preserve the names of hard-linked archives');
    PairZip:=TZipFile.Create;
    try
      PairZip.Open(LinkPath,zmRead);
      Require(PairZip.FileCount=0,'The linked archive must be valid and empty');
    finally PairZip.Free; end;
    Writeln('PASS Main removes verified empty ZIP and 7z containers and keeps hard-linked paths and companion files');
    Flush(Output);

    for var Page in [PAGE_AUTHORS,PAGE_SERIES,PAGE_GENRES,PAGE_SEARCH,PAGE_PUBLISHER_SERIES] do
    begin
      Sources('view-'+IntToStr(Page)); Rows([RawID,ArchiveID],Page); Execute(True,True,2,1);
      Require(Exists(RawID) and Exists(ArchiveID) and not Local(RawID) and not Local(ArchiveID) and not FileExists(RawPath),
        'Files-only deletion did not keep records and update availability'); ProtectedArchive(True);
      Sources('records-view-'+IntToStr(Page)); Rows([RawID,ArchiveID],Page); Execute(True,False,2,1);
      Require(not Exists(RawID) and not Exists(ArchiveID) and not FileExists(RawPath),
        'Record deletion from this view did not commit unique selected books'); ProtectedArchive(True);
    end;

    Trace('delete safety references across collections');
    Sources('shared-reference');
    Win32Check(CreateHardLink(PChar(Root+'shared-reference-alias.zip'),PChar(ArchivePath),nil));
    var MainCollection:=Collection;
    Collection:=SystemDB.GetCollection(ExternalID);
    try
      Insert('Book from another collection','shared-reference-alias.zip','chosen','.fb2');
    finally Collection:=MainCollection; MainCollection:=nil; end;
    Rows([ArchiveID,RawID]); Execute(True,False,2,1,1);
    Require(Exists(ArchiveID) and Exists(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),
      'A blocked archive batch changed unrelated selected sources or rows');
    ProtectedArchive;
    Writeln('PASS Main refuses physical deletion through a shared archive alias in another collection'); Flush(Output);

    Trace('delete safety database failure');
    Sources('rejected-write'); FailID := RawID;
    TFile.WriteAllText(Root+'successful.fb2',XML('successful'),TEncoding.UTF8);
    GoodID := Insert('successful','','successful','.fb2');
    DB := TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(PrivateID).DBFileName);
    try DB.ExecSQL('CREATE TRIGGER RejectDelete BEFORE DELETE ON Books WHEN OLD.BookID='+IntToStr(FailID)+
      ' BEGIN SELECT RAISE(ABORT,''owned deletion write fault''); END'); finally DB.Free; end;
    Rows([FailID,GoodID]); Execute(True,False,2,0,1);
    Require(Exists(FailID) and not Exists(GoodID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw) and not FileExists(Root+'successful.fb2'),
      'A failed database deletion removed its source or prevented independent successful books'); ProtectedArchive;

    Trace('delete safety locked and changed sources');
    Sources('locked-file'); Rows([RawID]); Locked := TFileStream.Create(RawPath,fmOpenRead or fmShareExclusive);
    try Execute(True,True,1,0,1); finally Locked.Free; end;
    Require(Exists(RawID) and Local(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),'Busy file was lost or falsely marked removed');

    Sources('changed-source'); Rows([RawID]);
    TFile.WriteAllText(Root+'replacement.fb2',XML('replacement'),TEncoding.UTF8);
    Probe.BeforeAccept := procedure
      begin
        Collection.GetBookRecord(CreateBookKey(RawID,Collection.CollectionID),Other,False);
        Other.FileName := 'replacement'; Collection.UpdateBook(Other);
      end;
    Execute(True,False,1,0,1);
    Require(Exists(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw) and FileExists(Root+'replacement.fb2'),
      'Changed source identity deleted the original or replacement file'); ProtectedArchive;
    Require(TFile.ReadAllText(DiagnosticLogFile,TEncoding.UTF8).Contains('book-delete'),'Deletion failures were not recorded in the diagnostic log');

    for var Ext in ['.pdf','.djvu','.doc'] do
    begin
      // File operations must not load a format decoder. These are opaque
      // filename/path fixtures, not claims of PDF/DjVu/DOC content parsing.
      RawPath := Root+'opaque'+Ext; TFile.WriteAllText(RawPath,'Owned opaque source',TEncoding.UTF8);
      RawID := Insert('opaque '+Ext,'','opaque',Ext); Rows([RawID]); Execute(True,True,1,0);
      Require(Exists(RawID) and not Local(RawID) and not FileExists(RawPath),'Files-only deletion mishandled a non-FB2 extension');
    end;

    Sources('filtered-selection'); Rows([ArchiveID]);
    var Node := Tree.GetFirst;
    while Assigned(Node) do begin Include(Node.States,vsFiltered); Node := Tree.GetNext(Node); end;
    Probe.Confirmations := 0; Probe.Accept := False; Probe.Timer.Enabled := True;
    try frmMain.DeleteBookExecute(nil); finally Probe.Timer.Enabled := False; end;
    Require((Probe.Confirmations=0) and Exists(ArchiveID),'Filtered checked rows were treated as an active deletion selection'); ProtectedArchive;

    Sources('applied-search'); ShowPage(PAGE_SEARCH);
    frmMain.edFTitle.Text := 'applied-search'; frmMain.DoApplyFilter(nil); Tree := frmMain.tvBooksSR;
    Count := 0; Node := Tree.GetFirst; Tree.ClearSelection; Tree.FocusedNode := nil;
    while Assigned(Node) do
    begin
      var Data := PBookRecord(Tree.GetNodeData(Node));
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin Inc(Count); if (Data^.BookKey.BookID=RawID) or (Data^.BookKey.BookID=ArchiveID) then Tree.CheckState[Node] := csCheckedNormal; end;
      Node := Tree.GetNext(Node);
    end;
    Require(Count=3,'Actual applied search did not load three source books');
    frmMain.edFTitle.Text := 'Unsaved deletion search draft'; Settings.DeleteFiles := False;
    Execute(True,False,2,0); Count := 0; Node := Tree.GetFirst;
    while Assigned(Node) do
    begin
      var Data := PBookRecord(Tree.GetNodeData(Node));
      if Assigned(Data) and (Data^.nodeType=ntBookInfo) then
      begin Inc(Count); Require(Data^.BookKey.BookID=OtherID,'Refreshed applied search kept a removed book'); end;
      Node := Tree.GetNext(Node);
    end;
    Require((Count=1) and (frmMain.edFTitle.Text='Unsaved deletion search draft'),'Deletion lost the applied search or overwritten its unsaved draft');
    Require(THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw,'Record-only applied search deletion changed the source'); ProtectedArchive;

    Trace('delete safety complete archive receipt on startup');
    Sources('recover-command');
    Collection.GetBookRecord(CreateBookKey(ArchiveID,PrivateID),Book,False);
    var Binding:=TBookDeletionBinding.Capture(SystemDB.GetCollectionInfo(PrivateID),[Book],True);
    var Task:TArchiveDeletionTask;
    Task.Archive:=ArchivePath; Task.Members:=TArray<string>.Create('chosen.fb2');
    Task.SourceIdentity:=ArchiveDeletionSourceIdentity(ArchivePath); Task.CatalogueBinding:=Binding.ToJSON;
    var JournalRoot:=TPath.Combine(Settings.DataPath,'BookDeletion');
    var Interrupted:=TArchiveDeletionQueue.Create([Task],JournalRoot);
    try
      Interrupted.Start;
      var Started:=GetTickCount64;
      while not Interrupted.Status.Finished do
      begin
        if GetTickCount64-Started>15000 then raise Exception.Create('Owned recovery seed timed out');
        Sleep(5);
      end;
      Interrupted.WaitFor;
      Require((Length(Interrupted.Results)=1) and Interrupted.Results[0].FilesVerified,
        'Owned recovery seed did not leave a verified archive and pending catalogue receipt');
      Require(Exists(ArchiveID),'Recovery seed changed catalogue before new Main startup');
    finally Interrupted.Free; end;
    FreeAndNil(frmMain); Settings.ActiveCollection:=PrivateID; Settings.ActivePage:=PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain);
    var Started:=GetTickCount64;
    Probe.Accept:=False; Probe.Failure:=''; Probe.Timer.Enabled:=True;
    try
      repeat
        Application.ProcessMessages;
        if GetTickCount64-Started>20000 then raise Exception.Create('Main did not resume a valid archive journal');
        Sleep(5);
      until not Exists(ArchiveID) and not DirectoryExists(JournalRoot)
        and not Assigned(frmMain.FindComponent('BookDeletionProgress'));
    finally Probe.Timer.Enabled:=False; end;
    Require(Probe.Failure='',Probe.Failure);
    ProtectedArchive(True);
    Writeln('PASS Main startup completes a bound archive deletion receipt and clears its private journals'); Flush(Output);

    for var AfterUnlink in [False,True] do
    begin
      var Name:='whole-recovery-'+BoolToStr(AfterUnlink,True)+'.zip';
      var Path:=Root+Name;
      WriteZip(Path,['one.fb2','two.fb2']);
      var One:=Insert(Name+' one',Name,'one','.fb2');
      var Two:=Insert(Name+' two',Name,'two','.fb2');
      Collection.GetBookRecord(CreateBookKey(One,PrivateID),Book,False);
      Collection.GetBookRecord(CreateBookKey(Two,PrivateID),Other,False);
      Binding:=TBookDeletionBinding.Capture(SystemDB.GetCollectionInfo(PrivateID),[Book,Other],True);
      Task.Archive:=Path; Task.Members:=TArray<string>.Create('one.fb2','two.fb2');
      Task.SourceIdentity:=ArchiveDeletionSourceIdentity(Path); Task.CatalogueBinding:=Binding.ToJSON;
      var Hash:=THashSHA2.GetHashStringFromFile(Path);
      Interrupted:=TArchiveDeletionQueue.Create([Task],JournalRoot,True);
      try
        Interrupted.Start; Started:=GetTickCount64;
        while Length(Interrupted.Results)=0 do
        begin
          Require(GetTickCount64-Started<15000,'Direct removal did not produce a receipt');
          Interrupted.WaitForResult(25);
        end;
        Require(Interrupted.Results[0].FilesVerified,'Direct removal did not prepare the verified archive');
      finally Interrupted.Free; end;
      Require((THashSHA2.GetHashStringFromFile(Path)=Hash) and Exists(One) and Exists(Two),
        'Stopping before catalogue acknowledgement modified the whole archive or its rows');
      if AfterUnlink then
      begin
        Require(Binding.CommitRecords(SystemDB)=2,'Could not simulate a committed catalogue after direct removal');
        TFile.Delete(Path);
      end;
      var Recovery:=TBookDeletionOperation.Recover(Settings.SystemFileName[sfSystemDB],JournalRoot);
      try
        Recovery.Start; Started:=GetTickCount64;
        while not Recovery.Status.Finished do
        begin
          Require(GetTickCount64-Started<15000,'Whole archive recovery exceeded guard');
          Sleep(5);
        end;
        Recovery.WaitFor;
        Require((Recovery.Status.Error='') and (Recovery.Status.CompletedBooks=2),
          'Whole archive recovery did not finish both rows: '+Recovery.Status.Error);
      finally Recovery.Free; end;
      Require(not FileExists(Path) and not Exists(One) and not Exists(Two) and not DirectoryExists(JournalRoot),
        'Whole archive recovery kept an archive, catalogue row or journal');
    end;
    Writeln('PASS whole archive catalogue recovery before commit and after final unlink'); Flush(Output);

    Trace('delete safety external local FB2 loose files');
    FreeAndNil(frmMain); Settings.ActiveCollection := ExternalID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(ExternalID);
    var LooseFolder := 'Обновление 2026-11-05\Автор с пробелом\';
    ForceDirectories(Root+LooseFolder);
    var UnselectedPath := Root+LooseFolder+'Соседняя книга.fb2';
    TFile.WriteAllText(UnselectedPath,XML('Не выбранная книга'),TEncoding.UTF8);
    var NeighbourHash := THashSHA2.GetHashStringFromFile(UnselectedPath);
    for var Page in [PAGE_AUTHORS,PAGE_SERIES,PAGE_GENRES,PAGE_SEARCH,PAGE_PUBLISHER_SERIES] do
      for var DeleteSource in [False,True] do
      begin
        Settings.DeleteFiles := DeleteSource;
        var LooseName := 'Книга ё '+IntToStr(Page)+' '+BoolToStr(DeleteSource,True);
        RawPath := Root+LooseFolder+LooseName+'.fb2';
        TFile.WriteAllText(RawPath,XML(LooseName),TEncoding.UTF8);
        BeforeRaw := THashSHA2.GetHashStringFromFile(RawPath);
        RawID := Insert(LooseName,LooseFolder,LooseName,'.fb2');
        Rows([RawID],Page);
        Execute(True,False,1,0);
        Require(not Exists(RawID),'External local deletion kept the selected catalogue record');
        if DeleteSource then
          Require(not FileExists(RawPath),'Enabled Delete files setting was ignored in an external local FB2 collection')
        else
          Require(THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw,'Disabled Delete files setting still changed the loose source');
        Require(THashSHA2.GetHashStringFromFile(UnselectedPath)=NeighbourHash,'Loose file deletion changed an unselected neighbouring file');
      end;
    Writeln('PASS external local FB2 deletion honours the file setting in five views and Unicode update folders'); Flush(Output);

    Trace('delete safety per-operation physical file choice');
    Probe.OverrideFiles := True;
    try
      for var Preference in [False, True] do
      begin
        Settings.DeleteFiles := Preference; Probe.DeleteSource := not Preference;
        Sources('explicit-'+BoolToStr(Preference,True)); Rows([RawID,ArchiveID]);
        Execute(False,False,2,1);
        Require(Exists(RawID) and (THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw),
          'Cancelling the explicit choice changed a source or catalogue record');
        Require(Settings.DeleteFiles=Preference, 'Cancelling changed the saved file preference');
        Execute(True,False,2,1);
        Require(not Exists(RawID) and not Exists(ArchiveID), 'Explicit deletion did not remove the selected catalogue entries');
        ProtectedArchive(Probe.DeleteSource);
        if Probe.DeleteSource then Require(not FileExists(RawPath), 'Explicit physical deletion was ignored')
        else Require(THashSHA2.GetHashStringFromFile(RawPath)=BeforeRaw, 'Record-only override changed the source');
        Require(Settings.DeleteFiles=Preference, 'One deletion silently changed the saved file preference');
      end;
    finally Probe.OverrideFiles := False; end;
    Writeln('PASS per-operation checkbox overrides either preference and cancellation preserves files and settings'); Flush(Output);

    if GetEnvironmentVariable('HOMELIB_DELETE_TIMING')='1' then TimeSingleBookZipBatch;

    Trace('delete safety online catalog');
    FreeAndNil(frmMain); Settings.ActiveCollection := OnlineID; Settings.ActivePage := PAGE_SEARCH;
    Application.CreateForm(TfrmMain,frmMain); Collection := SystemDB.GetCollection(OnlineID);
    Sources('online'); Collection.SetRate(CreateBookKey(RawID,OnlineID),4); Collection.SetProgress(CreateBookKey(RawID,OnlineID),23);
    Rows([RawID,ArchiveID]); Execute(True,False,2,1);
    Require(Exists(RawID) and Exists(ArchiveID) and not Local(RawID) and not Local(ArchiveID) and not FileExists(RawPath),
      'Online deletion removed catalogue records or kept the removed copy available'); ProtectedArchive(True);
    Collection.GetBookRecord(CreateBookKey(RawID,OnlineID),Book,False);
    Require((Book.Rate=4) and (Book.Progress=23),'Online file removal lost personal rating or reading progress');
    RawID := Insert('already absent archive','already-absent.zip','chosen','.fb2');
    Rows([RawID]); Execute(True,False,1,1);
    Require(Exists(RawID) and not Local(RawID),'An already absent archive kept a false downloaded flag');
    Writeln('PASS deletion confirmations unique books cancel records files shared archives five views online failures identity and protected neighbours'); Flush(Output);
  finally
    Probe.Timer.Free; Probe.Free; Settings.DeleteFiles := SavedDelete; Settings.SelectedIsChecked := SavedSelection;
    Vcl.Dialogs.UseLatestCommonDialogs := SavedDialogs;
    SetEnvironmentVariable('TEMP',PChar(OldTemp)); SetEnvironmentVariable('TMP',PChar(OldTmp));
  end;
end;
