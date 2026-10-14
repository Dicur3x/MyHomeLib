// Native real-DAO gate; include after Require/AddBook. Add unit_SystemDatabase_SQLite to DPR uses.
// Creates a fresh private system DB/catalog per scenario, on G only.
function SBRRows(DB: TSQLiteDatabase; const SQL: string): string;
var Q: TSQLiteQuery; B: TStringBuilder;
begin
  B:=TStringBuilder.Create;
  try
    Q:=DB.NewQuery(SQL);
    try Q.Open; while not Q.Eof do begin B.Append(Q.FieldAsString(0)).Append(#10); Q.Next; end;
    finally Q.Free; end;
    Result:=B.ToString;
  finally B.Free; end;
end;

function SBRTable(DB: TSQLiteDatabase; const TableName: string; OmitID: Boolean=False; OmitDeleted: Boolean=False; const WhereSQL: string=''): string;
var Q: TSQLiteQuery; Columns, Name: string;
begin
  Columns:=''; Q:=DB.NewQuery('PRAGMA table_info('+TableName+')');
  try
    Q.Open;
    while not Q.Eof do
    begin
      Name:=Q.FieldAsString(1);
      if not ((OmitID and SameText(Name,'BookID')) or (OmitDeleted and SameText(Name,'IsDeleted'))) then
      begin
        if Columns<>'' then Columns:=Columns+'||char(31)||';
        Columns:=Columns+'typeof('+Name+')||char(30)||hex(CAST('+Name+' AS BLOB))';
      end;
      Q.Next;
    end;
  finally Q.Free; end;
  Result:=SBRRows(DB,'SELECT '+Columns+' FROM '+TableName+WhereSQL+' ORDER BY 1');
end;

function SBRExact(DB: TSQLiteDatabase): string;
begin
  Result:=SBRTable(DB,'Books')+#1+SBRTable(DB,'BookGroups')+#1+SBRTable(DB,'Groups')+#1+SBRTable(DB,'Bases');
end;

function SBRGroups(DB: TSQLiteDatabase): string;
begin
  Result:=SBRRows(DB,'SELECT quote(b.LibID)||char(31)||quote(g.DatabaseID)||char(31)||quote(g.GroupID) '+
    'FROM BookGroups g LEFT JOIN Books b ON b.BookID=g.BookID AND b.DatabaseID=g.DatabaseID ORDER BY 1');
end;

procedure TestSystemBookRemapSafety;
var
  User: ISystemData; Presence: ISystemBookPresence; Collection: IBookCollection;
  DB, Catalog: TSQLiteDatabase; Book: TBookRecord; IDs: TArray<Integer>;
  WorkRoot, CaseRoot, UserFile, CatalogFile, BeforeRows, BeforePayload, BeforeGroups, CatalogHash: string;
  Source, SourceHash, History, HistoryHash, Notes, NotesHash, IniHash, ErrorText: string;
  DatabaseID, GroupOne, GroupTwo, RestoredID, ArchivedID: Integer; Failed: Boolean; OtherRows: string;

  procedure CloseCase;
  begin
    if Assigned(User) then User.ClearCollectionCache;
    Collection:=nil; Presence:=nil; User:=nil; FreeAndNil(Catalog); FreeAndNil(DB);
  end;

  procedure CheckProtected;
  begin
    Require(THashSHA2.GetHashStringFromFile(Source)=SourceHash,'Remap changed original book bytes');
    Require(THashSHA2.GetHashStringFromFile(History)=HistoryHash,'Remap changed reading history');
    Require(THashSHA2.GetHashStringFromFile(Notes)=NotesHash,'Remap changed reader notes');
    if IniHash<>'' then Require(THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini')=IniHash,'Remap changed settings');
    Require(THashSHA2.GetHashStringFromFile(CatalogFile)=CatalogHash,'Remap wrote the source catalog');
  end;

  procedure BeginCase(const Name: string; CardCount: Integer);
  var CardIndex: Integer;
  begin
    CloseCase; CaseRoot:=TPath.Combine(WorkRoot,Name); ForceDirectories(CaseRoot);
    UserFile:=TPath.Combine(CaseRoot,'user.dbs2'); Require(not FileExists(UserFile),'Use a fresh remap fixture runtime');
    TSystemData_SQLite.CreateSystemTables(UserFile); User:=TSystemData_SQLite.Create(UserFile);
    Require(Supports(User,ISystemBookPresence,Presence),'System stored-book interface missing');
    DatabaseID:=User.CreateCollection('Remap '+Name,CaseRoot,TPath.Combine(CaseRoot,'catalog.hlc2'),
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Collection:=User.GetCollection(DatabaseID); CatalogFile:=User.GetCollectionInfo(DatabaseID).DBFileName;
    DB:=TSQLiteDatabase.Create(UserFile); Catalog:=TSQLiteDatabase.Create(CatalogFile);
    User.AddGroup('Remap one'); User.AddGroup('Remap two');
    GroupOne:=DB.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=''Remap one''');
    GroupTwo:=DB.QuerySingleInt('SELECT GroupID FROM Groups WHERE GroupName=''Remap two''');
    SetLength(IDs,CardCount);
    for CardIndex:=0 to CardCount-1 do
    begin
      IDs[CardIndex]:=AddBook(Collection,'L'+IntToStr(CardIndex+1),'Автор ё і ў','ru','','');
      Collection.GetBookRecord(CreateBookKey(IDs[CardIndex],DatabaseID),Book,True);
      User.AddBookToGroup(Book.BookKey,GroupOne,Book); User.AddBookToGroup(Book.BookKey,GroupTwo,Book);
      // Distinct user fields and exact BLOBs: review has whitespace/NUL/newline;
      // ExtraInfo keeps its readable TReader prefix plus opaque trailing bytes.
      DB.ExecSQL('UPDATE Books SET Rate=?,Progress=?,Annotation=?,KeyWords=?,BookSize=?, '+
        'Review=X''2020000AD191D196D19E2020'',ExtraInfo=CAST(ExtraInfo||X''00FF'' AS BLOB) WHERE BookID=? AND DatabaseID=?',
        [CardIndex+1,(CardIndex+1)*11,'Мысль '+IntToStr(CardIndex),'ключ '+IntToStr(CardIndex),100+CardIndex,IDs[CardIndex],DatabaseID]);
    end;
  end;

  procedure Snapshot;
  begin
    BeforeRows:=SBRExact(DB); BeforePayload:=SBRTable(DB,'Books',True); BeforeGroups:=SBRGroups(DB);
    CatalogHash:=THashSHA2.GetHashStringFromFile(CatalogFile);
  end;

  procedure Swap;
  begin
    Catalog.ExecSQL('UPDATE Books SET LibID=CASE BookID WHEN ? THEN ''L2'' WHEN ? THEN ''L1'' ELSE LibID END',[IDs[0],IDs[1]]);
  end;

  procedure Cycle;
  begin
    Catalog.ExecSQL('UPDATE Books SET LibID=CASE BookID WHEN ? THEN ''L2'' WHEN ? THEN ''L3'' WHEN ? THEN ''L1'' ELSE LibID END',
      [IDs[0],IDs[1],IDs[2]]);
  end;

  procedure CheckPayload;
  begin
    Require(SBRTable(DB,'Books',True)=BeforePayload,'Remap changed personal fields/raw BLOBs');
    Require(SBRGroups(DB)=BeforeGroups,'Remap lost/reassigned memberships'); CheckProtected;
  end;

  procedure ExpectFailure(const ExpectedError: string);
  begin
    Failed:=False; ErrorText:='';
    try User.RemapCollectionBookIDs(DatabaseID,True);
    except on E:Exception do begin Failed:=True; ErrorText:=E.Message; end; end;
    Require(Failed,'Unsafe remap succeeded');
    if ExpectedError<>'' then Require(ErrorText.Contains(ExpectedError),'Unexpected remap failure: '+ErrorText);
    Require(SBRExact(DB)=BeforeRows,'Failed remap changed cards/groups'); CheckProtected;
  end;

begin
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Remap tests need private G runtime');
  User:=nil; Presence:=nil; Collection:=nil; DB:=nil; Catalog:=nil;
  WorkRoot:=TPath.Combine(Settings.AppPath,'system-book-remap-safety'); ForceDirectories(WorkRoot);
  Source:=TPath.Combine(WorkRoot,'original.fb2');
  TFile.WriteAllText(Source,'<FictionBook><body><section><p>Книга ё і ў.</p></section></body></FictionBook>',TEncoding.UTF8);
  History:=TPath.Combine(Settings.DataPath,'reader.ini'); Notes:=TPath.Combine(Settings.DataPath,'reader-notes.json');
  if not FileExists(History) then TFile.WriteAllText(History,'[Reader]'+#13#10+'Position=72'+#13#10+'Font=PT Serif',TEncoding.UTF8);
  if not FileExists(Notes) then TFile.WriteAllText(Notes,'{"version":1,"notes":[{"id":"remap","book":"L1","text":"Мысль ё і ў","position":72}]}',TEncoding.UTF8);
  SourceHash:=THashSHA2.GetHashStringFromFile(Source); HistoryHash:=THashSHA2.GetHashStringFromFile(History);
  NotesHash:=THashSHA2.GetHashStringFromFile(Notes); IniHash:='';
  if FileExists(Settings.AppPath+'myhomelib2.ini') then IniHash:=THashSHA2.GetHashStringFromFile(Settings.AppPath+'myhomelib2.ini');
  try
    BeginCase('swap',2); Snapshot;
    Require(User.RemapCollectionBookIDs(DatabaseID+100000,True)=0,'Unavailable collection was guessed');
    Require(SBRExact(DB)=BeforeRows,'Unavailable collection changed personal cards/groups'); CheckProtected;
    Swap; Snapshot;
    Require(User.RemapCollectionBookIDs(DatabaseID,True)=2,'Swap failed'); CheckPayload;
    Require(DB.QuerySingleString('SELECT LibID FROM Books WHERE BookID=?',[IDs[0]])='L2','Swap identity wrong');
    BeforeRows:=SBRExact(DB); Require(User.RemapCollectionBookIDs(DatabaseID,True)=0,'Repeat swap not idempotent');
    Require(SBRExact(DB)=BeforeRows,'Repeat swap changed rows');
    Writeln('PASS system remap swap/raw BLOBs/groups/repeat'); Flush(Output);

    BeginCase('cycle',3); Cycle;
    DB.ExecSQL('INSERT INTO BookGroups(BookID,DatabaseID,GroupID) VALUES(-1,?,?)',[DatabaseID,GroupOne]); Snapshot;
    Require(User.RemapCollectionBookIDs(DatabaseID,True)=3,'Cycle failed'); CheckPayload;
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM BookGroups WHERE BookID=-1 AND DatabaseID=?',[DatabaseID])=1,
      'Temporary IDs collided with existing negative orphan membership');
    Require(DB.QuerySingleString('SELECT LibID FROM Books WHERE BookID=?',[IDs[2]])='L1','Cycle identity wrong');
    Writeln('PASS system remap three-way cycle'); Flush(Output);

    BeginCase('database-isolation',2); Swap;
    DB.ExecSQL('INSERT INTO Books SELECT BookID,DatabaseID+1000,LibID,Title,SeriesID,SeqNumber,UpdateDate,LibRate,Lang,Folder,FileName,InsideNo,Ext,BookSize,IsLocal,IsDeleted,KeyWords,Rate,Progress,Annotation,Review,ExtraInfo FROM Books');
    DB.ExecSQL('INSERT INTO BookGroups SELECT BookID,DatabaseID+1000,GroupID FROM BookGroups'); Snapshot;
    OtherRows:=SBRTable(DB,'Books',False,False,' WHERE DatabaseID<>'+IntToStr(DatabaseID))+#1+
      SBRTable(DB,'BookGroups',False,False,' WHERE DatabaseID<>'+IntToStr(DatabaseID));
    Require(User.RemapCollectionBookIDs(DatabaseID,False)=2,'Isolated swap failed'); CheckPayload;
    Require(SBRTable(DB,'Books',False,False,' WHERE DatabaseID<>'+IntToStr(DatabaseID))+#1+
      SBRTable(DB,'BookGroups',False,False,' WHERE DatabaseID<>'+IntToStr(DatabaseID))=OtherRows,
      'Remap changed another collection sharing the same BookIDs');
    Writeln('PASS system remap isolates equal keys in other collections'); Flush(Output);

    BeginCase('duplicate-target',2);
    DB.ExecSQL('UPDATE Books SET LibID=''L1'' WHERE BookID=?',[IDs[1]]);
    Catalog.ExecSQL('UPDATE Books SET LibID=''L99'' WHERE BookID=?',[IDs[1]]); Snapshot;
    ExpectFailure('Несколько'); Writeln('PASS system remap ambiguous targets fail closed'); Flush(Output);

    BeginCase('occupied-local',2);
    DB.ExecSQL('UPDATE Books SET LibID='''' WHERE BookID=?',[IDs[1]]);
    Catalog.ExecSQL('UPDATE Books SET LibID=CASE BookID WHEN ? THEN ''L99'' ELSE ''L1'' END',[IDs[0]]); Snapshot;
    ExpectFailure('занят'); Writeln('PASS system remap occupied local card stays intact'); Flush(Output);

    BeginCase('orphan-group-target',2);
    RestoredID:=AddBook(Collection,'L1','New current copy','ru','','');
    Catalog.ExecSQL('UPDATE Books SET LibID=''L99'' WHERE BookID=?',[IDs[0]]);
    DB.ExecSQL('INSERT INTO BookGroups(BookID,DatabaseID,GroupID) VALUES(?,?,?)',[RestoredID,DatabaseID,GroupOne]); Snapshot;
    ExpectFailure('без карточки'); Writeln('PASS system remap conflicting orphan memberships stay intact'); Flush(Output);

    BeginCase('local-identities',2); Swap;
    DB.ExecSQL('UPDATE Books SET LibID=CASE BookID WHEN ? THEN '''' ELSE ''0'' END',[IDs[0]]); Snapshot;
    Require(User.RemapCollectionBookIDs(DatabaseID,True)=0,'Local empty/zero identities changed');
    Require(SBRExact(DB)=BeforeRows,'Local cards/groups changed'); CheckProtected;
    Writeln('PASS system remap empty/zero LibID untouched'); Flush(Output);

    BeginCase('missing-reappears',2);
    Catalog.ExecSQL('UPDATE Books SET LibID=''L99'' WHERE BookID=?',[IDs[0]]); Snapshot;
    BeforePayload:=SBRTable(DB,'Books',True,True);
    Require(User.RemapCollectionBookIDs(DatabaseID,True)=1,'Missing card not detached');
    ArchivedID:=DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=''L1''');
    Require(ArchivedID<0,'Missing card retains reusable catalog key');
    Require(DB.QuerySingleInt('SELECT IsDeleted FROM Books WHERE LibID=''L1''')=1,'Missing card not unavailable');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID=?',[IDs[0]])=0,'Missing card points to another book');
    Require(SBRTable(DB,'Books',True,True)=BeforePayload,'Archiving changed payload');
    Require(SBRGroups(DB)=BeforeGroups,'Archiving lost memberships');
    User.GetBookRecord(CreateBookKey(ArchivedID,DatabaseID),Book);
    Require((Book.LibID='L1') and (bpIsDeleted in Book.BookProps),'Archived system card unreadable'); CheckProtected;
    BeforeRows:=SBRExact(DB); Require(User.RemapCollectionBookIDs(DatabaseID,True)=0,'Missing card rewritten on repeat');
    Require(SBRExact(DB)=BeforeRows,'Repeated missing check changed key/BLOBs');
    RestoredID:=AddBook(Collection,'L1','Возвратившийся автор','ru','',''); Snapshot;
    BeforePayload:=SBRTable(DB,'Books',True,True);
    Require(User.RemapCollectionBookIDs(DatabaseID,True)=1,'Reappearance not restored');
    Require(DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=''L1''')=RestoredID,'Reappearance wrong key');
    Require(DB.QuerySingleInt('SELECT IsDeleted FROM Books WHERE LibID=''L1''')=0,'Restored card remains unavailable');
    Require(SBRTable(DB,'Books',True,True)=BeforePayload,'Restoration changed personal payload');
    Require(SBRGroups(DB)=BeforeGroups,'Restoration lost memberships'); CheckProtected;
    Writeln('PASS system remap missing/reused ID, stable archive and reappearance'); Flush(Output);

    BeginCase('missing-false-safe',2);
    Catalog.ExecSQL('UPDATE Books SET LibID=''L99'' WHERE BookID=?',[IDs[0]]); Snapshot;
    BeforePayload:=SBRTable(DB,'Books',True,True);
    Require(User.RemapCollectionBookIDs(DatabaseID,False)=1,'False mode leaves a missing identity on a reused ID');
    ArchivedID:=DB.QuerySingleInt('SELECT BookID FROM Books WHERE LibID=''L1''');
    Require((ArchivedID<0) and (DB.QuerySingleInt('SELECT IsDeleted FROM Books WHERE LibID=''L1''')=1),
      'False-mode missing card is not safely unavailable');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM Books WHERE BookID=?',[IDs[0]])=0,'False mode still refers to another catalog book');
    Require(SBRTable(DB,'Books',True,True)=BeforePayload,'False-mode archive changed personal payload');
    Require(SBRGroups(DB)=BeforeGroups,'False-mode archive lost memberships'); CheckProtected;
    BeforeRows:=SBRExact(DB); Require(User.RemapCollectionBookIDs(DatabaseID,False)=0,'False-mode repeat moves archived keys');
    Require(SBRExact(DB)=BeforeRows,'False-mode repeat rewrites payloads/groups');
    Writeln('PASS system remap False mode quarantines missing/reused IDs without data loss'); Flush(Output);

    BeginCase('phase-two-abort',3); Cycle;
    DB.ExecSQL('CREATE TRIGGER remap_test_abort BEFORE UPDATE OF BookID ON Books '+
      'WHEN OLD.BookID<0 AND NEW.BookID>0 BEGIN SELECT RAISE(ABORT,''forced remap phase2''); END'); Snapshot;
    ExpectFailure('forced remap phase2'); Writeln('PASS system remap phase-two trigger rolls back all rows'); Flush(Output);

    BeginCase('group-ignore',2); Swap;
    DB.ExecSQL(Format('CREATE TRIGGER remap_test_ignore BEFORE UPDATE OF BookID ON BookGroups '+
      'WHEN NEW.BookID<0 AND OLD.GroupID=%d BEGIN SELECT RAISE(IGNORE); END',[GroupTwo])); Snapshot;
    ExpectFailure('безопасно'); Writeln('PASS system remap ignored group update rolls back'); Flush(Output);

    BeginCase('outer-rollback',2); Swap; Snapshot;
    User.BeginDataUpdate;
    try
      Require(User.RemapCollectionBookIDs(DatabaseID,True)=2,'Remap failed inside outer update');
      User.GetBookRecord(CreateBookKey(IDs[1],DatabaseID),Book); Require(Book.LibID='L1','Outer remap identity wrong');
    finally User.EndDataUpdate(False); end;
    Require(SBRExact(DB)=BeforeRows,'Remap committed outer transaction'); CheckProtected;
    Writeln('PASS system remap savepoint respects outer rollback'); Flush(Output);

    BeginCase('outer-failure',2); Swap;
    DB.ExecSQL('CREATE TRIGGER remap_test_abort BEFORE UPDATE OF BookID ON Books '+
      'WHEN OLD.BookID<0 AND NEW.BookID>0 BEGIN SELECT RAISE(ABORT,''forced nested remap''); END');
    DB.ExecSQL('UPDATE Books SET Progress=88 WHERE BookID=?',[IDs[0]]); BeforeRows:=SBRExact(DB);
    DB.ExecSQL('UPDATE Books SET Progress=11 WHERE BookID=?',[IDs[0]]); CatalogHash:=THashSHA2.GetHashStringFromFile(CatalogFile);
    User.BeginDataUpdate;
    try
      User.SetProgress(CreateBookKey(IDs[0],DatabaseID),88); Failed:=False;
      try User.RemapCollectionBookIDs(DatabaseID,True);
      except on E:Exception do begin Failed:=True; Require(E.Message.Contains('forced nested remap'),'Unexpected nested failure'); end; end;
      Require(Failed,'Nested trigger did not fail'); User.GetBookRecord(CreateBookKey(IDs[0],DatabaseID),Book);
      Require(Book.Progress=88,'Remap rolled back earlier outer change'); User.EndDataUpdate(True);
    except User.EndDataUpdate(False); raise; end;
    Require(SBRExact(DB)=BeforeRows,'Nested failure damaged outer rows'); CheckProtected;
    Writeln('PASS system remap failed savepoint preserves earlier outer changes'); Flush(Output);

    BeginCase('locked-system',2); Swap; Snapshot;
    DB.Start('','IMMEDIATE');
    try ExpectFailure(''); finally DB.Rollback; end;
    Require(SBRExact(DB)=BeforeRows,'Locked remap changed rows');
    Writeln('PASS system remap lock failure preserves all rows'); Flush(Output);

    BeginCase('oversized-card-id',2); Swap;
    DB.Start;
    try
      DB.ExecSQL('UPDATE BookGroups SET BookID=? WHERE BookID=?',[Int64(High(Integer))+1,IDs[0]]);
      DB.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=?',[Int64(High(Integer))+1,IDs[0]]); DB.Commit;
    except DB.Rollback; raise; end;
    Snapshot; ExpectFailure('диапазон'); Writeln('PASS system remap reads full 64-bit card key and rejects overflow'); Flush(Output);

    BeginCase('oversized-group-id',2); Swap;
    DB.ExecSQL('INSERT INTO BookGroups(BookID,DatabaseID,GroupID) VALUES(?,?,?)',[Int64(High(Integer))+1,DatabaseID,GroupOne]); Snapshot;
    ExpectFailure('диапазон'); Writeln('PASS system remap reads full 64-bit group key and rejects overflow'); Flush(Output);

    BeginCase('private-id-limit',2); Swap;
    DB.Start;
    try
      DB.ExecSQL('UPDATE BookGroups SET BookID=? WHERE BookID=?',[Low(Integer),IDs[0]]);
      DB.ExecSQL('UPDATE Books SET BookID=? WHERE BookID=?',[Low(Integer),IDs[0]]); DB.Commit;
    except DB.Rollback; raise; end;
    Snapshot; ExpectFailure('служебных'); Writeln('PASS system remap private-ID exhaustion fails closed'); Flush(Output);
  finally CloseCase; end;
  Writeln('PASS system remap exact BLOBs/personal fields/groups, atomic cycles, missing identities, ambiguity and source/history/notes/settings preservation'); Flush(Output);
end;
