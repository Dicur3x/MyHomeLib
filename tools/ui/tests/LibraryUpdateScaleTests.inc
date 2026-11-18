// Sparse payloads isolate catalogue scale; they do not model terabyte archive I/O.
type
  TLibraryScaleApplyProbe=class(TLibraryApplyProbe)
    AnalysisFile,TargetFile:string;
    PlanChecked:Boolean;
    function ConfirmPlan(const Text:string; Flags:Longint):Integer;
  end;

function TLibraryScaleApplyProbe.ConfirmPlan(const Text:string; Flags:Longint):Integer;
var DB:TSQLiteDatabase; Query:TSQLiteQuery; Searched:Boolean; Plan:string;
begin
  DB:=TSQLiteDatabase.CreateReadOnly(AnalysisFile);
  try
    DB.ExecSQL('ATTACH DATABASE ? AS personalSource',[TargetFile]);
    Query:=DB.NewQuery('EXPLAIN QUERY PLAN SELECT count(*) FROM ApplyLive l '+
      'JOIN personalSource.Books b ON b.BookID=l.BookID WHERE coalesce(b.IsLocal,0)=0 '+
      'AND NOT EXISTS(SELECT 1 FROM ReviewRows r WHERE r.Key=l.Key)');
    try
      Query.Open; Searched:=False; Plan:='';
      while not Query.Eof do
      begin
        var Detail:=Query.FieldAsString(3); Plan:=Plan+' | '+Detail;
        Require(not Detail.Contains('SCAN r'),'Scale update still scans the incoming table for each live key');
        if Detail.Contains('SEARCH r') and Detail.Contains('ReviewRowsKey') then Searched:=True;
        Query.Next;
      end;
      Require(Searched,'Scale unlisted-card lookup did not use its key index: '+Plan); PlanChecked:=True;
      Writeln('PASS reviewed scale exact native unlisted-card query searches ReviewRowsKey',Plan); Flush(Output);
    finally Query.Free; end;
  finally DB.Free; end;
  Result:=Confirm(Text,Flags);
end;

procedure TestLibraryUpdateScale;
var Root,CountText,BaseInput,UpdateInput,TargetFile,BeforeFile,WorkFolder:string;
  BaseHash,UpdateHash,OldArchiveHash,NewArchiveHash,TargetHash,PersonalRows:string;
  Count,ID:Integer; Target:IBookCollection; Importer:TImportInpxThread;
  Profile:TLibraryUpdateSource; Stage:TStagedLibraryIndex; Review:TLibraryUpdateReview;
  Worker:TCollectionWorker; Probe:TLibraryScaleApplyProbe; DB,Personal,Observer:TSQLiteDatabase;
  Started:UInt64; Book:TBookRecord; DataVersion:Integer;
  procedure Metric(const Name:string; Since:UInt64);
  begin Writeln('METRIC scale stage=',Name,' elapsed_ms=',GetTickCount64-Since,' books=',Count); Flush(Output); end;
  procedure CheckWorker(const Context:string);
  begin
    if Assigned(Worker.FatalException) then raise Exception.Create(Context+': '+Exception(Worker.FatalException).Message);
    Require(Worker.Success,Context+' did not finish successfully');
  end;
  function PersonalDataRows:string;
  var Tables:TSQLiteQuery; Name,Filter:string;
  begin
    Result:=''; Tables:=Personal.NewQuery('SELECT name,sql FROM sqlite_master WHERE type=''table'' '+
      'AND name NOT LIKE ''sqlite_%'' ORDER BY name');
    try
      Tables.Open;
      while not Tables.Eof do
      begin
        Name:=Tables.FieldAsString(0); Filter:='';
        if Name='CatalogCommitWitnesses' then Filter:=' WHERE CollectionID<>'+IntToStr(ID);
        Result:=Result+#1+Name+#2+Tables.FieldAsString(1)+#2+SBRTable(Personal,Name,False,False,Filter);
        Tables.Next;
      end;
    finally Tables.Free; end;
  end;
  procedure CheckStoredData;
  var Columns:TSQLiteQuery; Predicate,Name,Condition:string;
  begin
    DB:=TSQLiteDatabase.CreateReadOnly(TargetFile,Root);
    try
      DB.ExecSQL('PRAGMA temp_store=FILE');
      DB.ExecSQL('ATTACH DATABASE ? AS original',[BeforeFile]);
      Require(DB.QuerySingleInt('SELECT count(*) FROM Books')=Count+1,'Scale update lost or duplicated cards');
      Require(DB.QuerySingleInt('SELECT count(*) FROM original.Books p LEFT JOIN Books b ON b.BookID=p.BookID '+
        'WHERE b.BookID IS NULL OR b.LibID<>p.LibID')=0,'Scale update renumbered old identities');
      Predicate:=''; Columns:=DB.NewQuery('PRAGMA main.table_info(Books)');
      try
        Columns.Open;
        while not Columns.Eof do
        begin
          Name:=Columns.FieldAsString(1);
          Condition:='b."'+Name+'" IS NOT p."'+Name+'"';
          // Memo setters may store UTF-8 as BLOB; catalogue import uses TEXT.
          // Compare the complete bytes while keeping NULL distinct from empty.
          if MatchText(Name,['Annotation','Review']) then
            Condition:='CAST(b."'+Name+'" AS BLOB) IS NOT CAST(p."'+Name+'" AS BLOB)';
          if MatchText(Name,['Title','SearchTitle','Folder','SearchFolder']) then
            Condition:='('+Condition+') AND b.BookID<>2';
          if Predicate<>'' then Predicate:=Predicate+' OR ';
          Predicate:=Predicate+'('+Condition+')';
          Columns.Next;
        end;
      finally Columns.Free; end;
      Require((Predicate<>'') and (DB.QuerySingleInt('SELECT count(*) FROM original.Books p '+
        'JOIN Books b ON b.BookID=p.BookID WHERE '+Predicate)=0),'Scale update changed unrelated book fields');
      Require(DB.QuerySingleInt('SELECT count(*) FROM original.Books p JOIN Books b ON b.BookID=p.BookID '+
        'WHERE b.BookID<>2 AND (b.Title IS NOT p.Title OR b.SearchTitle IS NOT p.SearchTitle)')=0,
        'Scale update changed an unrelated title');
      Require(DB.QuerySingleString('SELECT Title FROM Books WHERE BookID=2')='Corrected scale book 2',
        'Scale update did not apply the corrected title');
      for var TableName in ['Author_List','Genre_List','Series_List'] do
      begin
        Require(DB.QuerySingleInt('SELECT count(*) FROM '+TableName+' WHERE BookID<=?',[Count])=
          DB.QuerySingleInt('SELECT count(*) FROM original.'+TableName),'Scale update changed relation counts: '+TableName);
        Require(DB.QuerySingleInt('SELECT count(*) FROM (SELECT * FROM original.'+TableName+
          ' EXCEPT SELECT * FROM main.'+TableName+' WHERE BookID<=?)',[Count])=0,
          'Scale update changed old relation rows: '+TableName);
      end;
      Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Scale result failed SQLite quick_check');
    finally DB.Free; end;
    Require(PersonalDataRows=PersonalRows,'Scale update changed personal data or schema');
    for var Number in [1,2] do
    begin
      Target.GetBookRecord(CreateBookKey(Number,ID),Book,True);
      Require((Book.Rate=4) and (Book.Progress=37) and (Book.Review='Scale personal note '+IntToStr(Number)) and
        (Book.Annotation='Scale private annotation '+IntToStr(Number)),'Scale update lost personal fields');
      Require(SameFileName(Book.GetBookContainer,Root+'\books.zip'),'Scale correction changed its actual container');
    end;
    Target.GetBookRecord(CreateBookKey(Count+1,ID),Book,True);
    Require((Book.LibID=IntToStr(Count+1)) and (Book.Title='New scale book'), 'Scale arrival identity is wrong');
    var Stream:=Book.GetBookStream;
    try
      var Bytes:TBytes; SetLength(Bytes,Stream.Size); if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
      Require(TEncoding.UTF8.GetString(Bytes).Contains('new scale body'),'Scale arrival does not read from the new archive');
    finally Stream.Free; end;
  end;
begin
  RequireIsolatedRegression;
  Require(SameText(ExtractFileDrive(Settings.AppPath),'G:'),'Scale fixture requires G:');
  Root:=Settings.AppPath+'scale-inputs'; CountText:=TFile.ReadAllText(Root+'\count.txt',TEncoding.UTF8).Trim;
  Count:=StrToInt(CountText); Require((Count>=10000) and (Count<=1500000),'Unexpected scale fixture size');
  BaseInput:=Root+'\base.inpx'; UpdateInput:=Root+'\update.inpx'; TargetFile:=Root+'\target.hlc2';
  BeforeFile:=Root+'\before.hlc2'; BaseHash:=THashSHA2.GetHashStringFromFile(BaseInput);
  UpdateHash:=THashSHA2.GetHashStringFromFile(UpdateInput);
  OldArchiveHash:=THashSHA2.GetHashStringFromFile(Root+'\books.zip');
  NewArchiveHash:=THashSHA2.GetHashStringFromFile(Root+'\new.zip');
  ID:=SystemDB.CreateCollection('Owned reviewed-update scale',Root,TargetFile,CT_EXTERNAL_LOCAL_FB,
    Settings.SystemFileName[sfGenresFB2]);
  Started:=GetTickCount64; Importer:=TImportInpxThread.Create(ID,BaseInput,gtFb2);
  try
    Importer.Start; Importer.WaitFor;
    if Assigned(Importer.FatalException) then raise Exception.Create('Scale seed: '+Exception(Importer.FatalException).Message);
    Require(Importer.Success,'Scale seed import failed');
  finally Importer.Free; end;
  Metric('seed',Started); Target:=SystemDB.GetCollection(ID,True);
  DB:=TSQLiteDatabase.CreateReadOnly(TargetFile);
  try
    Require((DB.QuerySingleInt('SELECT count(*) FROM Books')=Count) and
      (DB.QuerySingleInt('SELECT count(*) FROM Books WHERE CAST(LibID AS INTEGER)<>BookID')=0),
      'Scale seed count or ordered identity differs from its independent input');
  finally DB.Free; end;
  for var Number in [1,2] do
  begin
    var Key:=CreateBookKey(Number,ID); Target.SetRate(Key,4); Target.SetProgress(Key,37);
    Target.SetReview(Key,'Scale personal note '+IntToStr(Number));
    Target.SetAnnotation(Key,'Scale private annotation '+IntToStr(Number));
  end;
  DB:=TSQLiteDatabase.CreateReadOnly(TargetFile);
  try DB.BackupTo(BeforeFile,nil); finally DB.Free; end;
  DB:=TSQLiteDatabase.Create(Settings.SystemFileName[sfSystemDB]);
  try DB.ExecSQL('CREATE TABLE IF NOT EXISTS CatalogCommitWitnesses(CollectionID INTEGER PRIMARY KEY,OperationID TEXT NOT NULL)');
  finally DB.Free; end;
  Personal:=TSQLiteDatabase.CreateReadOnly(Settings.SystemFileName[sfSystemDB]);
  Stage:=nil; Review:=nil; Worker:=nil; Probe:=nil; Observer:=nil;
  try
    PersonalRows:=PersonalDataRows;
    Profile:=TLibraryUpdateSource.NewSource; Profile.Name:='Owned scale source';
    Profile.Location:=Root; Profile.IndexFile:='update.inpx'; Profile.BooksRoot:=Root;
    for var Pass:=1 to 2 do
    begin
      TargetHash:=THashSHA2.GetHashStringFromFile(TargetFile);
      var FullPersonalBefore:=ReaderAllCatalogRows(Personal);
      Observer:=TSQLiteDatabase.CreateReadOnly(TargetFile);
      DataVersion:=Observer.QuerySingleInt('PRAGMA data_version');
      Started:=GetTickCount64; Stage:=TStagedLibraryIndex.Fetch(Profile,Settings.LibraryUpdateWorkPath,nil);
      WorkFolder:=Stage.Folder; Review:=TLibraryUpdateReview.Create(Profile,Stage);
      Worker:=CreateLibraryReviewWorker(ID,Review);
      try Worker.Start; Worker.WaitFor; CheckWorker('Scale review'); finally FreeAndNil(Worker); end;
      Require(Review.Ready and (Review.Total=Count+1),'Scale review count is wrong');
      if Pass=1 then Require((Review.NewBooks=1) and (Review.ChangedBooks=1),'Scale delta is not one new and one correction')
      else Require(Review.PreviousIndex and (Review.NewBooks=0) and (Review.ChangedBooks=0),
        'Repeated scale review did not use the published baseline');
      Require((THashSHA2.GetHashStringFromFile(TargetFile)=TargetHash) and
        (Observer.QuerySingleInt('PRAGMA data_version')=DataVersion) and
        (ReaderAllCatalogRows(Personal)=FullPersonalBefore),'Scale review wrote to current data before confirmation');
      FreeAndNil(Observer);
      Metric('review-'+IntToStr(Pass),Started);
      if Pass=2 then
      begin
        FreeAndNil(Review); FreeAndNil(Stage);
        Require(not DirectoryExists(WorkFolder),'Repeated scale review retained its workspace');
        Writeln('PASS reviewed scale repeat review has zero delta and preserves every current catalogue byte personal row and closed workspace'); Flush(Output);
        Break;
      end;
      Started:=GetTickCount64; Probe:=TLibraryScaleApplyProbe.Create; Probe.Accept:=True;
      var AnalysisFiles:=TDirectory.GetFiles(Stage.Folder,'comparison-*.sqlite');
      Require(Length(AnalysisFiles)=1,'Scale comparison database is ambiguous');
      Probe.AnalysisFile:=AnalysisFiles[0]; Probe.TargetFile:=TargetFile;
      Worker:=CreateLibraryApplyWorker(ID,Review,False); Worker.OnShowMessage:=Probe.ConfirmPlan;
      try
        Worker.Start; Worker.WaitFor; CheckWorker('Scale apply');
        Require(Probe.Confirmed and Probe.PlanChecked and Worker.CommittedChanges and Review.Applied,'Scale apply did not confirm and commit');
      finally FreeAndNil(Worker); FreeAndNil(Probe); end;
      Target:=SystemDB.GetCollection(ID,True); Metric('apply-'+IntToStr(Pass),Started);
      FreeAndNil(Review); FreeAndNil(Stage);
      Require(not DirectoryExists(WorkFolder),'Scale review retained its workspace');
      Started:=GetTickCount64; CheckStoredData; Metric('verify-'+IntToStr(Pass),Started);
      Writeln('PASS reviewed scale full update pass=',Pass,' cards=',Count+1,
        ' stable old identities fields relations personal data new readable book and closed workspace'); Flush(Output);
    end;
    Require((THashSHA2.GetHashStringFromFile(BaseInput)=BaseHash) and
      (THashSHA2.GetHashStringFromFile(UpdateInput)=UpdateHash) and
      (THashSHA2.GetHashStringFromFile(Root+'\books.zip')=OldArchiveHash) and
      (THashSHA2.GetHashStringFromFile(Root+'\new.zip')=NewArchiveHash),'Scale update changed publisher inputs');
    Writeln('PASS reviewed scale original INPX and sparse old new payload bytes preserved'); Flush(Output);
  finally Observer.Free; Probe.Free; Worker.Free; Review.Free; Stage.Free; Personal.Free; end;
end;
