procedure TestCatalogueSourceIndex(const Collection:IBookCollection);
var DB:TSQLiteDatabase; Query:TSQLiteQuery; Indexed:Boolean;
begin
  RequireIsolatedRegression;
  DB:=TSQLiteDatabase.Create(SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName);
  try
    Query:=DB.NewQuery('EXPLAIN QUERY PLAN DELETE FROM CatalogSourceBooks WHERE BookID=?',[123]);
    try
      Indexed:=False; Query.Open;
      while not Query.Eof do
      begin
        if Query.FieldAsString(3).Contains('IXCatalogSourceBooks_BookID') then Indexed:=True;
        Query.Next;
      end;
      Require(Indexed,'Catalogue deletion still scans every source mapping');
    finally Query.Free; end;
    DB.Start;
    try
      DB.ExecSQL('INSERT INTO CatalogSourceBooks(SourceKey,BookID) VALUES(?,?)',['palette-index:target-a',-100]);
      DB.ExecSQL('INSERT INTO CatalogSourceBooks(SourceKey,BookID) VALUES(?,?)',['palette-index:target-b',-100]);
      DB.ExecSQL('INSERT INTO CatalogSourceBooks(SourceKey,BookID) VALUES(?,?)',['palette-index:retain',-101]);
      DB.ExecSQL('DELETE FROM CatalogSourceBooks WHERE BookID=?',[-100]);
      Require(DB.LastChangedRows=2,'Indexed cleanup removed the wrong number of source mappings');
      Query:=DB.NewQuery('SELECT BookID FROM CatalogSourceBooks WHERE SourceKey=?',['palette-index:retain']);
      try Query.Open; Require(not Query.Eof and (Query.FieldAsInt(0)=-101),'Indexed cleanup touched another book');
      finally Query.Free; end;
    finally DB.Rollback; end;
  finally DB.Free; end;
  Writeln('PASS source mapping deletion uses BookID index and preserves mappings of other books');
end;

procedure TestIndexedArchiveReferences;
var C:IBookCollection; Info:TCollectionInfo; DB:TSQLiteDatabase; Zip:TZipFile;
  A,B,CID:Integer; Books:TArray<TBookRecord>; Tasks:TArray<TArchiveDeletionTask>;
  Preparation:TBookDeletionPreparation; CheckedRows:Int64; Started:UInt64;
  IndexedMS,FullMS:UInt64; Refused:Boolean;
begin
  RequireIsolatedRegression;
  CID:=SystemDB.CreateCollection('Indexed references',Settings.AppPath,'indexed-references.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.SystemFileName[sfGenresFB2]);
  C:=SystemDB.GetCollection(CID); Info:=SystemDB.GetCollectionInfo(CID);
  A:=AddBook(C,'Delete member','Author','ru','','');
  B:=AddBook(C,'Keep member','Author','ru','','');
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('UPDATE Books SET Folder=''indexed-target.zip'',FileName=CASE WHEN BookID=? THEN ''delete'' ELSE ''keep'' END',[A]);
    DB.ExecSQL('WITH RECURSIVE n(x) AS(VALUES(1000) UNION ALL SELECT x+1 FROM n WHERE x<350999) '+
      'INSERT INTO Books(BookID,LibID,Title,UpdateDate,Folder,FileName,InsideNo,Lang,Ext,BookSize,IsLocal) '+
      'SELECT x,''flibusta:''||x,''Unrelated ''||x,''2026-11-11'',''not-this-archive.zip'',''other''||x,0,''ru'',''.fb2'',100,1 FROM n');
  finally DB.Free; end;
  Zip:=TZipFile.Create;
  try
    Zip.Open(Settings.AppPath+'indexed-target.zip',zmWrite);
    for var Name in ['delete.fb2','keep.fb2'] do
    begin
      var Data:=TStringStream.Create(Name,TEncoding.UTF8);
      try Zip.Add(Data,Name); finally Data.Free; end;
    end;
  finally Zip.Free; end;
  SetLength(Books,1); C.GetBookRecord(CreateBookKey(A,CID),Books[0],False);
  Preparation:=TBookDeletionPreparation.Create(TBookDeletionBinding.Capture(Info,Books,True));
  try
    Preparation.Start; Preparation.WaitFor; Tasks:=Preparation.PreparedTasks;
    Require((Length(Tasks)=1) and (Preparation.Status.Error=''),'Could not prepare the owned reference fixture');
  finally Preparation.Free; end;
  CheckedRows:=0; Started:=GetTickCount64;
  CheckArchiveDeletionReferences(SystemDB,Tasks,nil,procedure(Value:Int64) begin CheckedRows:=Value; end);
  IndexedMS:=GetTickCount64-Started;
  Require(CheckedRows<100,'Reference check decoded unrelated books instead of using archive folders');
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try DB.ExecSQL('DROP INDEX IXBooks_DeletionFolder'); finally DB.Free; end;
  CheckedRows:=0; Started:=GetTickCount64;
  CheckArchiveDeletionReferences(SystemDB,Tasks,nil,procedure(Value:Int64) begin CheckedRows:=Value; end);
  FullMS:=GetTickCount64-Started;
  Require(CheckedRows>=350002,'Legacy fallback did not perform the complete reference check');
  DB:=TSQLiteDatabase.Create(Info.DBFileName);
  try
    DB.ExecSQL('CREATE INDEX IXBooks_DeletionFolder ON Books(Folder)');
    DB.AddFunction('MHL_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.AddFunction('MHL_SERIES_TRIGGERS_ON',0,DuplicateFixtureTriggersOff);
    DB.ExecSQL('UPDATE Books SET Folder=''indexed-target.zip'',FileName=''delete'' WHERE BookID=?',[B]);
  finally DB.Free; end;
  Refused:=False;
  try CheckArchiveDeletionReferences(SystemDB,Tasks,nil,nil);
  except on E:EInOutError do Refused:=True; end;
  Require(Refused,'A newly added live reference was missed by the next indexed check');
  Writeln('PROFILE archive references 350k rows full_ms=',FullMS,' indexed_ms=',IndexedMS);
  Writeln('PASS indexed references inspect target archives preserve neighbours and detect new live references');
end;
