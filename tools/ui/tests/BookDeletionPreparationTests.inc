procedure TestBookDeletionPreparation;
var Root,UserFile,A,B,FBD,AliasName,BeforeA,BeforeB,BeforeFBD:string;
  User:ISystemData; Collection:IBookCollection; CID:Integer;
  Books:TArray<TBookRecord>; Binding:TBookDeletionBinding;
  Preparation:TBookDeletionPreparation; Queue:TArchiveDeletionQueue;
  Tasks:TArray<TArchiveDeletionTask>; Receipts:TArray<TArchiveDeletionResult>;
  Neighbour:TBookRecord; Rejected:Boolean;
  procedure ZipFixture(const Path:string; const Names:array of string);
  var Zip:TZipFile; Stream:TStringStream;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Path,zmWrite); Zip.UTF8Support:=True;
      for var Name in Names do
      begin
        Stream:=TStringStream.Create('Owned '+Name+' — ё',TEncoding.UTF8);
        try Zip.Add(Stream,Name); finally Stream.Free; end;
      end;
    finally Zip.Free; end;
  end;
  function Insert(const Folder,Name,Extension,LibID:string):TBookRecord;
  var Value:TBookRecord;
  begin
    Value.Clear; Value.Title:=LibID; Value.Folder:=Folder; Value.FileName:=Name;
    Value.FileExt:=Extension; Value.LibID:=LibID; Value.Lang:='ru';
    TAuthorsHelper.Add(Value.Authors,'Owned author','Alex','');
    TGenresHelper.Add(Value.Genres,'','','prose_contemporary');
    var ID:=Collection.InsertBook(Value,False,False);
    Collection.GetBookRecord(CreateBookKey(ID,CID),Result,False);
  end;
  procedure WaitPreparation;
  var Started:UInt64;
  begin
    Started:=GetTickCount64;
    repeat
      Application.ProcessMessages;
      if GetTickCount64-Started>15000 then
      begin Preparation.RequestStop; raise Exception.Create('Owned source preparation exceeded guard'); end;
      if not Preparation.Status.Finished then Sleep(1);
    until Preparation.Status.Finished;
    Preparation.WaitFor;
  end;
  procedure VerifySources;
  begin
    Require((THashSHA2.GetHashStringFromFile(A)=BeforeA) and
      (THashSHA2.GetHashStringFromFile(B)=BeforeB) and
      (THashSHA2.GetHashStringFromFile(FBD)=BeforeFBD),'Preparation changed an original source archive');
  end;
  procedure VerifyRetained(const Path,Name:string; Count:Integer);
  var Zip:TZipFile; Data:TBytes;
  begin
    Zip:=TZipFile.Create;
    try
      Zip.Open(Path,zmRead); Require(Zip.FileCount=Count,'Queue lost or retained an unexpected archive member');
      Zip.Read(Name,Data);
      Require(TEncoding.UTF8.GetString(Data)='Owned '+Name+' — ё','Queue damaged a retained payload');
    finally Zip.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'deletion-preparation'); ForceDirectories(Root);
  UserFile:=Root+'user.dbs2'; A:=Root+'one.zip'; B:=Root+'two.zip'; FBD:=Root+'private.zip'; AliasName:=Root+'alias.zip';
  ZipFixture(A,['nested/Книга ё.fb2','nested/two.fb2','other/Книга ё.fb2','keep.fb2']);
  ZipFixture(B,['three.fb2','keep.fb2']);
  ZipFixture(FBD,['nested/private.fbd','nested/private.pdf','unrelated.txt']);
  Win32Check(CreateHardLink(PChar(AliasName),PChar(A),nil));
  BeforeA:=THashSHA2.GetHashStringFromFile(A); BeforeB:=THashSHA2.GetHashStringFromFile(B);
  BeforeFBD:=THashSHA2.GetHashStringFromFile(FBD);
  var Lease:=AcquireArchiveChange(A);
  try
    var Locked:=TFileStream.Create(A,fmOpenReadWrite or fmShareExclusive);
    try
      Require(IsArchiveChanging(AliasName),'Archive guard could not identify a physical alias under exclusive access');
      var Blocked:=False; var Reader:TMHLZip:=nil;
      try Reader:=TMHLZip.Create(AliasName,True);
      except on E:EMHLArchiveInUse do Blocked:=True; end;
      Reader.Free; Require(Blocked,'Reader did not report a guarded exclusively held source');
      Reader:=TMHLZip.Create(B,True);
      try Require(Reader.FileCount=2,'Exclusive source guard blocked a different archive');
      finally Reader.Free; end;
    finally Locked.Free; end;
  finally Lease:=nil; end;
  Require(not IsArchiveChanging(A) and (THashSHA2.GetHashStringFromFile(A)=BeforeA),
    'Exclusive guard test leaked its lease or changed the source');
  Writeln('PASS active archive guard identifies physical aliases under exclusive source access while other archives remain readable'); Flush(Output);
  TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
  try
    CID:=User.CreateCollection('Owned preparation',Root,Root+'catalog.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection:=User.GetCollection(CID); SetLength(Books,4);
    Books[0]:=Insert('one.zip','nested/Книга ё','.fb2','owned:one');
    Books[1]:=Insert('two.zip','three','.fb2','owned:three');
    Books[2]:=Insert('alias.zip','nested/two','.fb2','owned:two');
    Books[3]:=Insert('','private.zip','.pdf','owned:private');
    Neighbour:=Insert('one.zip','other/Книга ё','.fb2','owned:neighbour');
    Collection.SetReview(Neighbour.BookKey,'Keep neighbour note — ё');
    for var Book in Books do User.AddBookToGroup(Book.BookKey,FAVORITES_GROUP_ID,Book);
    Binding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),Books,True);
    var OriginalBinding:=Binding.ToJSON;
    var BadBooks:=Copy(Books); BadBooks[3].FileExt:='.doc';
    var BadBinding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),BadBooks,True);
    Preparation:=TBookDeletionPreparation.Create(BadBinding);
    try
      Preparation.Start; WaitPreparation;
      Require(Preparation.Status.Error<>'' ,'Ambiguous preparation unexpectedly succeeded');
      Rejected:=False;
      try Preparation.PreparedTasks; except on E:EInvalidOperation do Rejected:=True; end;
      Require(Rejected,'Preparation exposed partial tasks after a later invalid FBD source');
      VerifySources;
    finally Preparation.Free; end;
    Preparation:=TBookDeletionPreparation.Create(Binding);
    try
      Preparation.RequestStop; Preparation.Start; WaitPreparation;
      Require(Preparation.Status.Cancelled,'Cancelled preparation continued into sources'); VerifySources;
    finally Preparation.Free; end;
    Preparation:=TBookDeletionPreparation.Create(Binding);
    try
      Preparation.Start; WaitPreparation;
      Require((Preparation.Status.Error='') and not Preparation.Status.Cancelled,Preparation.Status.Error);
      Require(Preparation.ThreadID<>GetCurrentThreadId,'Preparation ran in the UI thread');
      Tasks:=Preparation.PreparedTasks;
      Require((Length(Tasks)=3) and (Length(Tasks[0].Members)=2) and
        (Length(Tasks[1].Members)=1) and (Length(Tasks[2].Members)=2),'Preparation did not group physical aliases and exact FBD pairs');
      Require((Length(TBookDeletionBinding.Parse(Tasks[0].CatalogueBinding).ExpectedBooks)=2) and
        (Length(TBookDeletionBinding.Parse(Tasks[1].CatalogueBinding).ExpectedBooks)=1) and
        (Length(TBookDeletionBinding.Parse(Tasks[2].CatalogueBinding).ExpectedBooks)=1),'Archive tasks lost their exact catalogue slices');
      Require(Binding.ToJSON=OriginalBinding,'Archive slicing modified the original captured selection');
      VerifySources;
    finally Preparation.Free; end;
    Writeln('PASS background deletion preparation groups hard-link aliases exact members and FBD pairs without source writes or partial tasks'); Flush(Output);
    Queue:=TArchiveDeletionQueue.Create(Tasks,Root+'journals');
    try
      Queue.Start; var Started:=GetTickCount64;
      repeat
        Application.ProcessMessages;
        if GetTickCount64-Started>15000 then
        begin Queue.StopAfterCurrentArchive; raise Exception.Create('Owned prepared queue exceeded guard'); end;
        if not Queue.Status.Finished then Sleep(1);
      until Queue.Status.Finished;
      Queue.WaitFor; Receipts:=Queue.Results;
      Require(Length(Receipts)=3,'Prepared queue did not finish all archives');
      for var Receipt in Receipts do Require(Receipt.FilesVerified,Receipt.Error);
      VerifyRetained(A,'other/Книга ё.fb2',2); VerifyRetained(B,'keep.fb2',1); VerifyRetained(FBD,'unrelated.txt',1);
      var Applied:=0;
      for var Receipt in Receipts do
      begin
        Inc(Applied,TBookDeletionBinding.Parse(Receipt.CatalogueBinding).CommitRecords(User));
        TArchiveDeletionQueue.Acknowledge(Receipt);
      end;
      Require(Applied=4,'Prepared queue did not apply exactly four selected catalogue/personal records');
      var Catalog:=TSQLiteDatabase.CreateReadOnly(User.GetCollectionInfo(CID).DBFileName);
      try Require(Catalog.QuerySingleInt('SELECT count(*) FROM Books')=1,'Prepared queue removed an unselected catalogue record');
      finally Catalog.Free; end;
      Require(Collection.GetReview(Neighbour.BookKey)='Keep neighbour note — ё','Prepared queue lost the retained neighbour note');
      Require(Length(TDirectory.GetDirectories(Root+'journals'))=0,'Prepared queue retained acknowledged work directories');
    finally Queue.Free; end;
    Writeln('PASS prepared archive tasks complete filesystem and exact catalogue phases while preserving neighbours notes and unrelated FBD members'); Flush(Output);
  finally Collection:=nil; User:=nil; end;
end;
