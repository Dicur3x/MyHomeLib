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
  finally
    Writer:=nil; Personal.Free; Catalog.Free; Collection:=nil; Other:=nil; User:=nil;
  end;
end;
