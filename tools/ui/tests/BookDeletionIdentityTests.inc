procedure TestBookDeletionIdentity;
var Root,UserFile,CatalogFile,SourceFile,SourceHash:string;
  User:ISystemData; Collection,Other:IBookCollection;
  Catalog,Personal:TSQLiteDatabase; Writer:IBookIdentityDeletionWriter;
  Saved,Current,Foreign:TBookRecord; Match:TBookIdentityPredicate;
  CID,OtherCID,BID,OtherID:Integer; Rejected:Boolean;
  function Count(DB:TSQLiteDatabase; const Table:string):Integer;
  begin Result:=DB.QuerySingleInt('SELECT count(*) FROM '+Table); end;
  procedure Reset;
  begin
    Catalog.ExecSQL('UPDATE Books SET LibID=?,Folder=?,FileName=?,Ext=?,InsideNo=? WHERE BookID=?',
      [Saved.LibID,Saved.Folder,Saved.FileName,Saved.FileExt,Saved.InsideNo,BID]);
    Personal.ExecSQL('UPDATE Books SET LibID=?,Folder=?,FileName=?,Ext=?,InsideNo=? WHERE BookID=? AND DatabaseID=?',
      [Saved.LibID,Saved.Folder,Saved.FileName,Saved.FileExt,Saved.InsideNo,BID,CID]);
  end;
  procedure BothRemain(const Reason:string);
  begin
    Require(Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[BID])=1,Reason+': catalogue lost selected book');
    Require(Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=1,Reason+': personal card lost');
    Require(Personal.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE BookID=? AND DatabaseID=?',[BID,CID])=1,Reason+': group link lost');
  end;
begin
  RequireIsolatedRegression;
  Root:=IncludeTrailingPathDelimiter(Settings.AppPath+'book-deletion-identity'); ForceDirectories(Root);
  UserFile:=Root+'user.dbs2'; SourceFile:=Root+'source.fb2';
  TFile.WriteAllText(SourceFile,'Selected original — ё; never delete a file through a database writer',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(SourceFile);
  TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
  Catalog:=nil; Personal:=nil;
  try
    CID:=User.CreateCollection('Deletion identity',Root,Root+'catalog.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    OtherCID:=User.CreateCollection('Other collection',Root,Root+'other.hlc2',CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection:=User.GetCollection(CID); Other:=User.GetCollection(OtherCID);
    Saved.Clear; Saved.Title:='Selected book'; Saved.FileName:='source'; Saved.FileExt:='.fb2';
    Saved.LibID:='flibusta:101'; Saved.Lang:='ru'; Saved.Size:=100;
    Saved.Rate:=4; Saved.Progress:=37; Saved.Review:='Своя заметка — ё';
    TAuthorsHelper.Add(Saved.Authors,'Selected author','Alex','');
    TGenresHelper.Add(Saved.Genres,'','','prose_contemporary');
    BID:=Collection.InsertBook(Saved,False,False);
    Collection.GetBookRecord(CreateBookKey(BID,CID),Saved,True);
    User.AddBookToGroup(Saved.BookKey,FAVORITES_GROUP_ID,Saved);
    Current:=Saved; Current.LibID:='flibusta:102'; Current.Title:='Neighbour'; Current.FileName:='neighbour';
    var NeighbourID:=Collection.InsertBook(Current,False,False);
    OtherID:=Other.InsertBook(Current,False,False);
    Other.GetBookRecord(CreateBookKey(OtherID,OtherCID),Foreign,False);
    User.AddBookToGroup(Foreign.BookKey,FAVORITES_GROUP_ID,Foreign);
    CatalogFile:=User.GetCollectionInfo(CID).DBFileName;
    Catalog:=TSQLiteDatabase.Create(CatalogFile); Personal:=TSQLiteDatabase.Create(UserFile);
    Catalog.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Catalog.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Personal.AddFunction('MHL_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Personal.AddFunction('MHL_SERIES_TRIGGERS_ON',0,EnableScaleFixtureTriggers);
    Require(Supports(Collection,IBookIdentityDeletionWriter,Writer),'Conditional catalogue deletion is unavailable');
    Match:=function(const Value:TBookRecord):Boolean
      begin
        Result:=Value.BookKey.IsSameAs(Saved.BookKey) and (Value.LibID=Saved.LibID) and
          (Value.InsideNo=Saved.InsideNo) and (ReaderBookPhysicalIdentity(Saved)<>'') and
          (ReaderBookPhysicalIdentity(Value)=ReaderBookPhysicalIdentity(Saved));
      end;
    var FirstState:=Writer.DeleteBookIfIdentity(Saved,Match,True);
    Require(FirstState=bdwReady,'Check-only deletion failed state='+IntToStr(Ord(FirstState))+
      ' bulk='+BoolToStr(Collection.InBulkOperation,True));
    BothRemain('Check only');
    Catalog.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',['flibusta:999',BID]);
    Require(Writer.DeleteBookIfIdentity(Saved,Match)=bdwChanged,'Reused catalogue ID was accepted');
    BothRemain('Reused catalogue ID'); Reset;
    Personal.ExecSQL('UPDATE Books SET FileName=? WHERE BookID=? AND DatabaseID=?',['foreign-file',BID,CID]);
    Require(Writer.DeleteBookIfIdentity(Saved,Match)=bdwChanged,'Foreign personal card was accepted');
    BothRemain('Foreign personal card'); Reset;
    Collection.BeginBulkOperation;
    try Require(Writer.DeleteBookIfIdentity(Saved,Match)=bdwBusy,'Deletion entered an uncommitted outer operation');
    finally Collection.EndBulkOperation(False); end;
    BothRemain('Outer operation');
    Require(Writer.DeleteBookIfIdentity(Foreign,Match) in [bdwBusy,bdwChanged],
      'A catalogue writer redirected destructive work into another collection');
    BothRemain('Foreign collection');
    Writeln('PASS conditional deletion rejects reused IDs foreign cards and outer transactions while preserving catalogue and groups'); Flush(Output);

    Catalog.ExecSQL('CREATE TRIGGER OwnedRejectDelete BEFORE DELETE ON Books WHEN OLD.BookID='+IntToStr(BID)+
      ' BEGIN SELECT RAISE(ABORT,''owned catalogue failure''); END');
    Rejected:=False;
    try Writer.DeleteBookIfIdentity(Saved,Match); except on E:Exception do Rejected:=True; end;
    Require(Rejected,'Injected catalogue deletion failure was not exercised');
    BothRemain('Catalogue rollback');
    Catalog.ExecSQL('DROP TRIGGER OwnedRejectDelete');
    Personal.ExecSQL('CREATE TRIGGER OwnedRejectDelete BEFORE DELETE ON Books WHEN OLD.BookID='+IntToStr(BID)+
      ' AND OLD.DatabaseID='+IntToStr(CID)+' BEGIN SELECT RAISE(ABORT,''owned personal failure''); END');
    Rejected:=False;
    try Writer.DeleteBookIfIdentity(Saved,Match); except on E:Exception do Rejected:=True; end;
    Require(Rejected,'Injected personal-store deletion failure was not exercised');
    Require(Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[BID])=0,
      'Catalogue phase did not commit before the personal phase');
    Require(Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=? AND DatabaseID=?',[BID,CID])=1,
      'Failed personal phase lost its card');
    Require(Personal.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE BookID=? AND DatabaseID=?',[BID,CID])=1,
      'Failed personal phase lost its group link');
    Personal.ExecSQL('DROP TRIGGER OwnedRejectDelete');
    Require(Writer.DeleteBookIfIdentity(Saved,Match)=bdwDeleted,'Receipt replay did not finish the remaining personal commit');
    Require(Writer.DeleteBookIfIdentity(Saved,Match)=bdwMissing,'Completed deletion was not idempotent');
    Require(Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[NeighbourID])=1,'Neighbour catalogue row was lost');
    Require(Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=? AND DatabaseID=?',[OtherID,OtherCID])=1,
      'Deletion affected another collection with the same numeric book ID');
    Require(THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash,'Database deletion removed or changed the physical book');
    Writeln('PASS conditional deletion rolls back failures and replays split commits without touching physical sources or other collections'); Flush(Output);

    var FirstBound,SecondBound:TBookRecord;
    Current:=Saved; Current.LibID:='binding:one'; Current.FileName:='source';
    var BoundOne:=Collection.InsertBook(Current,False,False);
    Collection.GetBookRecord(CreateBookKey(BoundOne,CID),FirstBound,True);
    User.AddBookToGroup(FirstBound.BookKey,FAVORITES_GROUP_ID,FirstBound);
    Current.LibID:='binding:two'; Current.FileName:='second-bound';
    var BoundTwo:=Collection.InsertBook(Current,False,False);
    Collection.GetBookRecord(CreateBookKey(BoundTwo,CID),SecondBound,True);
    User.AddBookToGroup(SecondBound.BookKey,FAVORITES_GROUP_ID,SecondBound);
    FirstBound.Annotation:='PRIVATE annotation not required by deletion';
    FirstBound.Review:='PRIVATE review not required by deletion';
    var Binding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),[FirstBound,SecondBound],True);
    var Encoded:=Binding.ToJSON;
    Require(not Encoded.Contains('PRIVATE'),'Deletion receipt persisted unrelated personal text');
    Binding:=TBookDeletionBinding.Parse(Encoded);
    var Copies:=Binding.ExpectedBooks;
    Copies[0].FileName:='mutated outside the binding';
    Require(Binding.ExpectedBooks[0].FileName=FirstBound.FileName,'ExpectedBooks exposed mutable internal receipt storage');
    Rejected:=False;
    try TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),[FirstBound,FirstBound],True);
    except on E:EReadError do Rejected:=True; end;
    Require(Rejected,'Catalogue binding accepted repeated book keys');
    var WrongJSON:=TJSONObject.ParseJSONValue(Encoded) as TJSONObject;
    try
      WrongJSON.RemovePair('catalogueKey').Free;
      WrongJSON.AddPair('catalogueKey','00000000:0000000000000000');
      var WrongBinding:=TBookDeletionBinding.Parse(WrongJSON.ToJSON);
      Rejected:=False;
      try WrongBinding.CommitRecords(User); except on E:EReadError do Rejected:=True; end;
      Require(Rejected,'Receipt accepted a replaced catalogue file identity');
    finally WrongJSON.Free; end;
    Catalog.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',['binding:replaced',BoundTwo]);
    Rejected:=False;
    try Binding.CommitRecords(User); except on E:EReadError do Rejected:=True; end;
    Require(Rejected and (Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID IN (?,?)',[BoundOne,BoundTwo])=2),
      'Binding preflight removed an earlier book before rejecting a later changed identity');
    Catalog.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=?',[SecondBound.LibID,BoundTwo]);
    Writeln('PASS durable catalogue binding round-trips exact identities and rejects reused catalogue files duplicate keys and changed books before mutation'); Flush(Output);

    Personal.ExecSQL('CREATE TRIGGER OwnedBindingReject BEFORE DELETE ON Books WHEN OLD.BookID='+IntToStr(BoundOne)+
      ' AND OLD.DatabaseID='+IntToStr(CID)+' BEGIN SELECT RAISE(ABORT,''owned binding replay failure''); END');
    Rejected:=False;
    try Binding.CommitRecords(User); except on E:Exception do Rejected:=True; end;
    Require(Rejected and (Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[BoundOne])=0) and
      (Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[BoundTwo])=1) and
      (Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=? AND DatabaseID=?',[BoundOne,CID])=1),
      'Binding did not preserve its unfinished personal phase and subsequent book after a failure');
    Personal.ExecSQL('DROP TRIGGER OwnedBindingReject');
    Binding:=TBookDeletionBinding.Parse(Encoded);
    Require(Binding.CommitRecords(User)=2,'Persisted binding did not finish its partial batch after restart');
    Require(Binding.CommitRecords(User)=0,'Replaying an applied binding deleted unrelated data');
    Require((Catalog.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=?',[NeighbourID])=1) and
      (Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE BookID=? AND DatabaseID=?',[OtherID,OtherCID])=1) and
      (THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash),'Binding replay touched a neighbour another collection or a physical file');
    var FilesOnly:=TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),[FirstBound],False);
    Rejected:=False;
    try FilesOnly.CommitRecords(User); except on E:EInvalidOperation do Rejected:=True; end;
    Require(Rejected,'A files-only receipt deleted catalogue rows');
    Writeln('PASS persisted catalogue binding resumes a split batch idempotently while protecting files-only mode sources neighbours and other collections'); Flush(Output);

    Current:=Saved; Current.LibID:='files-only:one'; Current.FileName:='source';
    var LocalID:=Collection.InsertBook(Current,False,False);
    Collection.GetBookRecord(CreateBookKey(LocalID,CID),Current,True);
    User.AddBookToGroup(Current.BookKey,FAVORITES_GROUP_ID,Current);
    Collection.SetRate(Current.BookKey,4); Collection.SetProgress(Current.BookKey,53);
    Collection.SetReview(Current.BookKey,'Keep files-only note — ё'); Collection.SetLocal(Current.BookKey,True);
    var LocalBinding:=TBookDeletionBinding.Capture(User.GetCollectionInfo(CID),[Current],False);
    Personal.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=? AND DatabaseID=?',['files-only:foreign',LocalID,CID]);
    Rejected:=False;
    try LocalBinding.CommitSourceMissing(User); except on E:EReadError do Rejected:=True; end;
    Collection.GetBookRecord(CreateBookKey(LocalID,CID),Current,True);
    Require(Rejected and (bpIsLocal in Current.BookProps),'Changed personal identity still cleared catalogue availability');
    Personal.ExecSQL('UPDATE Books SET LibID=? WHERE BookID=? AND DatabaseID=?',['files-only:one',LocalID,CID]);
    Require(LocalBinding.CommitSourceMissing(User)=1,'Files-only receipt did not clear source availability');
    LocalBinding.CommitSourceMissing(User);
    Collection.GetBookRecord(CreateBookKey(LocalID,CID),Current,True);
    Require(not (bpIsLocal in Current.BookProps) and (Current.Rate=4) and (Current.Progress=53) and
      (Collection.GetReview(Current.BookKey)='Keep files-only note — ё'),'Files-only completion removed records or changed personal data');
    Require((Personal.QuerySingleInt('SELECT IsLocal FROM Books WHERE BookID=? AND DatabaseID=?',[LocalID,CID])=0) and
      (Personal.QuerySingleInt('SELECT count(*) FROM BookGroups WHERE BookID=? AND DatabaseID=?',[LocalID,CID])=1) and
      (THashSHA2.GetHashStringFromFile(SourceFile)=SourceHash),'Files-only completion lost a saved card group link or physical source');
    Writeln('PASS files-only receipt clears only matching source availability and preserves records ratings progress notes groups and source bytes'); Flush(Output);

    var MemberBook:TBookRecord; var Members:TArray<string>;
    MemberBook.Clear; MemberBook.CollectionRoot:=Root; MemberBook.Folder:='members.zip';
    MemberBook.FileName:='каталог/Книга ё'; MemberBook.FileExt:='.fb2'; MemberBook.InsideNo:=0;
    Members:=ExactBookDeletionMembers(MemberBook,['Книга ё.fb2','каталог/Книга ё.fb2','other/Книга ё.fb2']);
    Require((Length(Members)=1) and (Members[0]='каталог/Книга ё.fb2'),'Deletion guessed a basename instead of the exact Unicode member');
    MemberBook.FileName:='каталог\Книга ё.fb2';
    Members:=ExactBookDeletionMembers(MemberBook,['каталог/Книга ё.fb2','other.fb2']);
    Require((Length(Members)=1) and (Members[0]='каталог/Книга ё.fb2'),'Deletion duplicated the already-present extension or lost slash identity');
    MemberBook.FileName:='literal[*]?';
    Members:=ExactBookDeletionMembers(MemberBook,['literal[*]?.fb2','literalX.fb2']);
    Require((Length(Members)=1) and (Members[0]='literal[*]?.fb2'),'Deletion treated literal member characters as a wildcard');
    for var BadName in ['missing','Книга ё','КАТАЛОГ/Книга ё',''] do
    begin
      MemberBook.FileName:=BadName; MemberBook.InsideNo:=1; Rejected:=False;
      try ExactBookDeletionMembers(MemberBook,['каталог/Книга ё.fb2','other.fb2']);
      except on E:EReadError do Rejected:=True; end;
      Require(Rejected,'Deletion fell back to a basename case-fold or ordinal for '+BadName);
    end;
    MemberBook.FileName:='same'; Rejected:=False;
    try ExactBookDeletionMembers(MemberBook,['same.fb2','x/y.fb2','x\y.fb2']);
    except on E:EReadError do Rejected:=True; end;
    Require(Rejected,'Deletion accepted ambiguous normalized archive paths');
    MemberBook.Folder:=''; MemberBook.FileName:='private.zip'; MemberBook.FileExt:='.pdf'; MemberBook.InsideNo:=99;
    Members:=ExactBookDeletionMembers(MemberBook,['nested/owned.fbd','nested/owned.pdf','unrelated.pdf','shared.jpg']);
    Require((Length(Members)=2) and (Members[0]='nested/owned.fbd') and (Members[1]='nested/owned.pdf'),
      'FBD deletion removed an unrelated member or used a stale ordinal');
    Rejected:=False;
    try ExactBookDeletionMembers(MemberBook,['one.fbd','one.pdf','two.fbd','two.pdf']);
    except on E:EReadError do Rejected:=True; end;
    Require(Rejected,'FBD deletion guessed one of several descriptor/payload pairs');
    Rejected:=False;
    try ExactBookDeletionMembers(MemberBook,['one.fbd','unrelated.pdf']);
    except on E:EReadError do Rejected:=True; end;
    Require(Rejected,'FBD deletion paired unrelated filenames');
    Writeln('PASS exact deletion member selection preserves Unicode full paths literal characters and FBD companions without basename case or ordinal fallback'); Flush(Output);

    var InventoryPath:=Root+'read-only-inventory.zip';
    var InventoryZip:=TZipFile.Create;
    try
      InventoryZip.Open(InventoryPath,zmWrite); InventoryZip.UTF8Support:=True;
      for var Name in ['nested/Книга ё.fb2','other/Книга ё.fb2','shared.jpg'] do
      begin
        var Contents:=TStringStream.Create('Owned opaque source '+Name,TEncoding.UTF8);
        try InventoryZip.Add(Contents,Name); finally Contents.Free; end;
      end;
    finally InventoryZip.Free; end;
    var InventoryHash:=THashSHA2.GetHashStringFromFile(InventoryPath);
    var SourceIdentity:=ArchiveDeletionSourceIdentity(InventoryPath);
    var Observed:=ReadBookDeletionInventory(InventoryPath,SourceIdentity);
    Require(Length(Observed)=3,'Metadata-only ZIP inventory lost entries');
    MemberBook.CollectionRoot:=Root; MemberBook.Folder:='read-only-inventory.zip';
    MemberBook.FileName:='nested/Книга ё'; MemberBook.FileExt:='.fb2';
    Members:=ExactBookDeletionMembers(MemberBook,Observed);
    Require((Length(Members)=1) and (Members[0]='nested/Книга ё.fb2'),'ZIP metadata did not resolve the exact selected member');
    Rejected:=False;
    try ReadBookDeletionInventory(InventoryPath,SourceIdentity+'changed');
    except on E:EReadError do Rejected:=True; end;
    Require(Rejected,'Inventory accepted a changed source fingerprint');
    Rejected:=False;
    try ReadBookDeletionInventory(InventoryPath,SourceIdentity,function:Boolean begin Result:=True; end);
    except on E:EAbort do Rejected:=True; end;
    Require(Rejected and (THashSHA2.GetHashStringFromFile(InventoryPath)=InventoryHash),
      'Cancelled metadata inventory modified its source');
    Writeln('PASS metadata-only ZIP inventory preserves source bytes and checks captured identity and cancellation before selection'); Flush(Output);
  finally
    Writer:=nil; Personal.Free; Catalog.Free; Collection:=nil; Other:=nil; User:=nil;
  end;
end;
