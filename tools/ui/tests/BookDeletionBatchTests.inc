procedure TestBookDeletionBatch;
var Root,UserFile,ZipName,LooseName,LooseHash,ZipHash:string;
  User:ISystemData; Collections:array[0..1] of IBookCollection;
  Selected:array[0..1] of TBookRecord; Neighbour,Changed:TBookRecord;
  Items:TArray<TBookDeletionBatchItem>; Operation:TBookDeletionOperation;
  State:TBookDeletionOperationStatus;
  function Insert(Index:Integer; const Folder,Name,LibID:string):TBookRecord;
  var Book:TBookRecord; ID:Integer;
  begin
    Book.Clear; Book.Title:=LibID; Book.LibID:=LibID; Book.Folder:=Folder;
    Book.FileName:=Name; Book.FileExt:='.fb2'; Book.Lang:='ru';
    Include(Book.BookProps,bpIsLocal); TAuthorsHelper.Add(Book.Authors,'Owned batch author','','');
    TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
    ID:=Collections[Index].InsertBook(Book,False,False);
    Collections[Index].GetBookRecord(CreateBookKey(ID,Collections[Index].CollectionID),Result,False);
  end;
  function Exists(const Book:TBookRecord):Boolean;
  var Query:TSQLiteDatabase;
  begin
    Query:=TSQLiteDatabase.CreateReadOnly(User.GetCollectionInfo(Book.BookKey.DatabaseID).DBFileName);
    try Result:=Query.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[Book.BookKey.BookID])=1;
    finally Query.Free; end;
  end;
  procedure Run(Stopped:Boolean=False);
  var Deadline:UInt64;
  begin
    Operation:=TBookDeletionOperation.CreateBatch(Items,UserFile,Root+'journals');
    try
      if Stopped then Operation.RequestStop;
      Deadline:=GetTickCount64+30000; Operation.Start;
      repeat
        Application.ProcessMessages; State:=Operation.Status;
        if GetTickCount64>Deadline then
        begin Operation.RequestStop; raise Exception.Create('Owned deletion batch exceeded deadline'); end;
        if not State.Finished then Sleep(5);
      until State.Finished;
      Operation.WaitFor;
      Require(not Assigned(Operation.FatalException),'Deletion batch escaped the guarded worker');
    finally Operation.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'deletion-batch'); ForceDirectories(Root);
  UserFile:=Root+'user.dbs2'; LooseName:=Root+'keep-source.fb2'; ZipName:=Root+'sources.zip';
  TFile.WriteAllText(LooseName,'Owned source retained by catalogue-only choice',TEncoding.UTF8);
  var Zip:=TZipFile.Create;
  try
    Zip.Open(ZipName,zmWrite);
    for var Name in ['remove.fb2','keep.fb2'] do
    begin
      var Text:=TStringStream.Create('Owned '+Name+' — ё',TEncoding.UTF8);
      try Zip.Add(Text,Name); finally Text.Free; end;
    end;
  finally Zip.Free; end;
  LooseHash:=THashSHA2.GetHashStringFromFile(LooseName); ZipHash:=THashSHA2.GetHashStringFromFile(ZipName);
  TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
  try
    for var I:=0 to 1 do
    begin
      var CID:=User.CreateCollection('Owned batch '+IntToStr(I),Root,Root+'catalog'+IntToStr(I)+'.hlc2',
        CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
      Collections[I]:=User.GetCollection(CID);
    end;
    Selected[0]:=Insert(0,'','keep-source','owned:first');
    Selected[1]:=Insert(1,'sources.zip','remove','owned:second');
    Neighbour:=Insert(1,'sources.zip','keep','owned:neighbour');
    Collections[1].SetReview(Neighbour.BookKey,'Keep neighbour note — ё');
    for var Book in Selected do User.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID,Book);
    Require(Selected[0].BookKey.BookID=Selected[1].BookKey.BookID,'Fixture must exercise equal IDs in different catalogues');
    SetLength(Items,2);
    for var I:=0 to 1 do
    begin
      Items[I].Binding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(Collections[I].CollectionID),[Selected[I]],True);
      Items[I].CollectionName:='Owned batch '+IntToStr(I); Items[I].RemoveFiles:=I=1;
    end;
    Run(True);
    Require(State.Stopping and (State.CompletedBooks=0) and Exists(Selected[0]) and Exists(Selected[1]),
      'Stopped batch changed a catalogue');
    Changed:=Selected[1]; Changed.LibID:='replacement identity'; Collections[1].UpdateBook(Changed);
    Run;
    Require((State.Error<>'') and not State.CatalogueChanged and Exists(Selected[0]) and Exists(Selected[1]) and
      (THashSHA2.GetHashStringFromFile(LooseName)=LooseHash) and (THashSHA2.GetHashStringFromFile(ZipName)=ZipHash),
      'Batch changed the first collection before checking the second identity');
    Collections[1].UpdateBook(Selected[1]);
    var Duplicate:=Items; SetLength(Duplicate,3); Duplicate[2]:=Items[0]; var Rejected:=False;
    try Operation:=TBookDeletionOperation.CreateBatch(Duplicate,UserFile,Root+'journals'); Operation.Free;
    except on E:EArgumentException do Rejected:=True; end;
    Require(Rejected,'Deletion batch accepted duplicate collection phases');
    var AliasBook:=Insert(1,'','keep-source','owned:shared-source');
    var Conflict:=Copy(Items);
    Conflict[1].Binding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(Collections[1].CollectionID),[AliasBook],True);
    Rejected:=False;
    try Operation:=TBookDeletionOperation.CreateBatch(Conflict,UserFile,Root+'journals'); Operation.Free;
    except on E:EArgumentException do Rejected:=True; end;
    Require(Rejected and Exists(Selected[0]) and Exists(Selected[1]) and Exists(AliasBook) and
      (THashSHA2.GetHashStringFromFile(LooseName)=LooseHash),
      'Conflicting retain/delete choices for a shared source were accepted');
    Run;
    Require((State.Error='') and (State.PendingJournal='') and State.CatalogueChanged and
      (State.CompletedBooks=2) and (State.CollectionIndex=2) and (State.CollectionCount=2),
      'Multi-collection deletion failed: '+State.Error);
    Require((Length(State.AffectedCollections)=2) and State.AffectsCollection(Collections[0].CollectionID) and
      State.AffectsCollection(Collections[1].CollectionID) and not State.AffectsCollection(0),
      'Background deletion did not identify exactly the catalogues that need refreshing');
    Require(not Exists(Selected[0]) and not Exists(Selected[1]) and Exists(Neighbour),
      'Equal IDs in two collections were confused or a neighbour row was removed');
    Require(THashSHA2.GetHashStringFromFile(LooseName)=LooseHash,'Catalogue-only phase removed or changed its file');
    Zip:=TZipFile.Create;
    try
      Zip.Open(ZipName,zmRead); Require((Zip.FileCount=1) and (Zip.FileNames[0]='keep.fb2'),
        'Physical phase did not preserve the exact unselected ZIP member');
      var Data:TBytes; Zip.Read('keep.fb2',Data);
      Require(TEncoding.UTF8.GetString(Data)='Owned keep.fb2 — ё','Physical batch changed neighbouring book bytes');
    finally Zip.Free; end;
    Collections[1].GetBookRecord(Neighbour.BookKey,Changed,False);
    Require(Collections[1].GetReview(Neighbour.BookKey)='Keep neighbour note — ё','Batch lost a neighbouring personal note');
    Require(not HasArchiveDeletionJournals(Root+'journals'),'Completed batch retained an archive journal');
    Writeln('PASS one background deletion batch validates every collection first and preserves namespace files neighbours and cancellation');
  finally
    Collections[0]:=nil; Collections[1]:=nil; User.ClearCollectionCache; User:=nil;
  end;
end;
