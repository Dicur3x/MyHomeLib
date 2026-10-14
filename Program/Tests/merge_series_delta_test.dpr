program merge_series_delta_test;

{$APPTYPE CONSOLE}
{$R '..\MyhomeLib.res'}
{$R '..\MyhomeLib.dres'}
{$R '..\lang.res'}

uses
  NativeRegressionGuard, System.SysUtils, System.Classes, System.IOUtils,
  System.Variants, System.Generics.Collections, Vcl.Forms,
  unit_Globals, unit_Consts, unit_Interfaces, unit_Settings, unit_Localization,
  unit_CollectionMerge, unit_Database_SQLite, SQLiteWrap, SQLiteProfile,
  dm_user;

const PersonalReview = '  Личная мысль ё 😀' + #13#10 + ' пробелы сохранить  ';
  PersonalAnnotation = 'Моя аннотация — українська, беларуская і English.';

type
  TSeriesRow = record ID, Number, Primary, Position: Integer; end;
  TSeriesRows = TDictionary<string,TSeriesRow>;

procedure Require(Value: Boolean; const Message: string);
begin if not Value then raise Exception.Create(Message); end;

function CollectionFile(const Collection: IBookCollection): string;
begin Result := SystemDB.GetCollectionInfo(Collection.CollectionID).DBFileName; end;

function SnapshotDatabase(const FileName: string): string;
var DB: TSQLiteDatabase; Tables, Columns, Rows: TSQLiteQuery;
  Names: TStringList; Name, SQL, OrderBy: string; I, ColumnCount: Integer;
begin
  DB := TSQLiteDatabase.CreateReadOnly(FileName); Names := TStringList.Create;
  try
    Tables := DB.NewQuery('SELECT name FROM sqlite_master WHERE type=''table'' AND name NOT LIKE ''sqlite_%'' ORDER BY name');
    try Tables.Open; while not Tables.Eof do begin Names.Add(Tables.FieldAsString(0)); Tables.Next; end;
    finally Tables.Free; end;
    Result := '';
    for Name in Names do
    begin
      SQL := ''; OrderBy := ''; ColumnCount := 0; Columns := DB.NewQuery('PRAGMA table_info("'+Name+'")');
      try
        Columns.Open;
        while not Columns.Eof do
        begin
          if SQL<>'' then SQL:=SQL+',';
          SQL:=SQL+'quote("'+Columns.FieldAsString(1)+'")';
          Inc(ColumnCount); if OrderBy<>'' then OrderBy:=OrderBy+',';
          OrderBy:=OrderBy+IntToStr(ColumnCount); Columns.Next;
        end;
      finally Columns.Free; end;
      // Order the complete quoted row, including WITHOUT ROWID tables.
      Rows:=DB.NewQuery('SELECT '+SQL+' FROM "'+Name+'" ORDER BY '+OrderBy);
      try
        Rows.Open; Result:=Result+Name+#13#10;
        while not Rows.Eof do
        begin
          for I:=0 to Rows.ColCount-1 do
            Result:=Result+IntToStr(Length(Rows.FieldAsString(I)))+':'+Rows.FieldAsString(I)+';';
          Result:=Result+#13#10; Rows.Next;
        end;
      finally Rows.Free; end;
    end;
  finally Names.Free; DB.Free; end;
end;

function SeriesRows(const Collection: IBookCollection; BookID: Integer): TSeriesRows;
var DB: TSQLiteDatabase; Query: TSQLiteQuery; Row: TSeriesRow;
begin
  Result:=TSeriesRows.Create; DB:=TSQLiteDatabase.CreateReadOnly(CollectionFile(Collection));
  try
    Query:=DB.NewQuery('SELECT s.SeriesTitle,s.SeriesID,sl.SeqNumber,sl.IsPrimary,sl.OrdNum '+
      'FROM Series_List sl JOIN Series s ON s.SeriesID=sl.SeriesID WHERE sl.BookID=? ORDER BY sl.OrdNum,s.SeriesID');
    try
      Query.SetParam(0,BookID); Query.Open;
      while not Query.Eof do
      begin
        Row.ID:=Query.FieldAsInt(1); Row.Number:=Query.FieldAsInt(2);
        Row.Primary:=Query.FieldAsInt(3); Row.Position:=Query.FieldAsInt(4);
        Result.Add(Query.FieldAsString(0),Row); Query.Next;
      end;
    finally Query.Free; end;
  except Result.Free; raise; end;
  DB.Free;
end;

function ProfileCalls(const FileName, Fragment: string): Int64;
var Lines: TStringList; Line: string; Fields: TArray<string>;
begin
  Result:=0; Lines:=TStringList.Create;
  try
    Lines.LoadFromFile(FileName,TEncoding.UTF8);
    for Line in Lines do
    begin
      Fields:=Line.Split([#9]);
      if (Length(Fields)>=5) and (Fields[1]='step') and Fields[4].Contains(Fragment) then
        Inc(Result,StrToInt64(Fields[2]));
    end;
  finally Lines.Free; end;
end;

function MakeBook(const Collection: IBookCollection; const FileName, LibID, Cycle: string;
  Size, Number: Integer; const Review: string): Integer;
var Book: TBookRecord;
begin
  Book.Clear; Book.Title:='Одинаковое издание '+LibID; Book.FileName:=FileName;
  Book.FileExt:='.fb2'; Book.Folder:=''; Book.LibID:=LibID; Book.Lang:='ru';
  Book.Series:=Cycle; Book.SeqNumber:=Number; Book.Size:=Size;
  Book.Date:=EncodeDate(2020,1,1); Book.Review:=Review; Include(Book.BookProps,bpIsLocal);
  TAuthorsHelper.Add(Book.Authors,'Автор','Алексей','');
  TGenresHelper.Add(Book.Genres,'','','prose_contemporary');
  Result:=Collection.InsertBook(Book,False,False); Require(Result>0,'Fixture insertion failed');
  TFile.WriteAllText(Settings.AppPath+FileName+'.fb2','<FictionBook><body><section><p>Fixture.</p></section></body></FictionBook>',TEncoding.UTF8);
end;

procedure RemovePrimary(const Collection: IBookCollection; BookID: Integer);
var Before, Changed: TBookRecord; Updater: IBookMergeMetadataDeltaUpdater;
begin
  Require(Supports(Collection,IBookMergeMetadataDeltaUpdater,Updater),'Fixture needs actual delta updater');
  Collection.GetBookRecord(CreateBookKey(BookID,Collection.CollectionID),Before,True);
  Changed:=Before; Changed.Series:=''; Changed.PublisherSeriesKnown:=False;
  Collection.BeginBulkOperation;
  try Updater.UpdateBookMetadataDelta(Before,Changed,False); Collection.EndBulkOperation(True);
  except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
end;

procedure TestOriginalCopyCapture;
var Collection: IBookCollection; Recorder: IBookMergeOriginalCopyRecorder;
  CollectionID, OriginalID, LegacyID, MergedID, PrefixID, DamagedID, RollbackID: Integer;
  Book, Changed: TBookRecord; Before, Profile: string; DB: TSQLiteDatabase;
  procedure ReadBook(ID: Integer);
  begin Collection.GetBookRecord(CreateBookKey(ID,CollectionID),Book,True); end;
begin
  CollectionID:=SystemDB.CreateCollection('Copy guard',Settings.AppPath,'copy-guard.hlc2',
    CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
  Collection:=SystemDB.GetCollection(CollectionID);
  Require(Supports(Collection,IBookMergeOriginalCopyRecorder,Recorder),'Atomic original-copy API absent');
  OriginalID:=MakeBook(Collection,'copy-original','old','Cycle',300,5,'Original');
  LegacyID:=MakeBook(Collection,'copy-legacy','legacy','Cycle',250,5,'Legacy');
  MergedID:=MakeBook(Collection,'copy-merged','merged:source:flibusta:99','Cycle',125,5,'Merged');
  // A LibID prefix alone is not proof that a file copy has already been saved.
  PrefixID:=MakeBook(Collection,'copy-prefix','merged:legacy:42','Cycle',175,5,'Prefix only');
  DamagedID:=MakeBook(Collection,'copy-damaged','damaged','Cycle',300,5,'Preexisting damaged provenance');
  RollbackID:=MakeBook(Collection,'copy-rollback','rollback','Cycle',225,5,'Rollback');
  ReadBook(LegacyID); Collection.SetCatalogBookCopy('legacy:copy','Legacy source',Book);
  ReadBook(MergedID); Collection.SetCatalogBookCopy('source:file:99','High',Book);
  ReadBook(DamagedID); Changed:=Book; Changed.Size:=50;
  Collection.SetCatalogBookCopy('base:damaged','Previously selected source',Changed);
  Profile:=Settings.AppPath+'original-copy-guard.tsv'; StartSQLiteProfile;
  Collection.BeginBulkOperation;
  try
    ReadBook(OriginalID); Recorder.CaptureOriginalCopyIfMissing('base:original','Original library',Book);
    Changed:=Book; Changed.Size:=50;
    Recorder.CaptureOriginalCopyIfMissing('base:original','Preferred source',Changed);
    ReadBook(LegacyID); Recorder.CaptureOriginalCopyIfMissing('base:legacy','Original library',Book);
    ReadBook(MergedID); Recorder.CaptureOriginalCopyIfMissing('base:merged','High',Book);
    ReadBook(PrefixID); Recorder.CaptureOriginalCopyIfMissing('base:prefix','Original library',Book);
    ReadBook(DamagedID); Recorder.CaptureOriginalCopyIfMissing('base:damaged','Original library',Book);
    Collection.EndBulkOperation(True);
    SaveSQLiteProfile(Profile);
  except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise;
  end;
  StopSQLiteProfile;
  Require(ProfileCalls(Profile,'SELECT SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID FROM CatalogBookCopies')=0,
    'Original-copy guard separately reads copy lists');
  DB:=TSQLiteDatabase.CreateReadOnly(CollectionFile(Collection));
  try
    Require(DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=?',['base:original'])=300,
      'Repeat capture overwrote original size');
    Require(DB.QuerySingleString('SELECT SourceName FROM CatalogBookCopies WHERE SourceKey=?',['base:original'])='Original library',
      'Repeat capture overwrote original origin');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM CatalogBookCopies WHERE BookID=?',[LegacyID])=1,'Legacy copy was duplicated');
    Require(DB.QuerySingleInt('SELECT COUNT(*) FROM CatalogBookCopies WHERE BookID=? AND SourceKey LIKE ''base:%''',[MergedID])=0,
      'Source-imported book acquired an invented base copy');
    Require(DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=?',['base:prefix'])=175,
      'LibID prefix suppressed uncatalogued original copy');
    Require(DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE SourceKey=?',['base:damaged'])=50,
      'New guard pretends to reconstruct previously overwritten provenance');
  finally DB.Free; end;
  Before:=SnapshotDatabase(CollectionFile(Collection)); ReadBook(RollbackID);
  Collection.BeginBulkOperation;
  try Recorder.CaptureOriginalCopyIfMissing('base:rollback','Original library',Book); Collection.EndBulkOperation(False);
  except if Collection.InBulkOperation then Collection.EndBulkOperation(False); raise; end;
  Require(Before=SnapshotDatabase(CollectionFile(Collection)),'Original capture escaped canceled transaction');
  Writeln('PASS original-copy atomic guard preserves origin/size, legacy copies and factual merged state; rollback; no standalone copy reads'); Flush(Output);
end;

procedure RunCase(Policy: TCollectionMergePolicy; Scenario: Integer);
var Target, HighSource, LowSource: IBookCollection; Sources: TMergeSources;
  TargetID, HighID, LowID, Anchor, HighBook, LowBook, NewBook, I, DestinationNew, ExpectedAdds: Integer;
  Prefix, IncomingPrimary, HighBefore, LowBefore, TargetBefore, SystemBefore, Profile, BeforeRepeat, SourceName, ExpectedReview: string;
  Plan: TCollectionMergePlan; Book, Stored, Card, CancelBook: TBookRecord;
  BeforeRows, AfterRows: TSeriesRows; Pair: TPair<string,TSeriesRow>; AfterRow: TSeriesRow;
  CancelCalls: Integer; Canceled: Boolean; DB: TSQLiteDatabase; Publishers: TBookSeries;
  function MakeCollection(const Suffix: string): IBookCollection;
  var ID: Integer;
  begin
    ID:=SystemDB.CreateCollection(Prefix+Suffix,Settings.AppPath,Prefix+Suffix+'.hlc2',
      CT_EXTERNAL_LOCAL_FB,Settings.AppPath+'genres_fb2.glst');
    Result:=SystemDB.GetCollection(ID); Result.SetProperty(PROP_SOURCE_LIBRARY,'flibusta');
  end;
  procedure CheckPersonal;
  begin
    Target.GetBookRecord(CreateBookKey(Anchor,TargetID),Stored,True);
    Require((Stored.BookKey.BookID=Anchor) and (Stored.LibID='42'),'Existing IDs changed');
    Require((Stored.Rate=5) and (Stored.Progress=72),'User rating/progress changed');
    Require(Stored.Review.StartsWith(ExpectedReview),'User review prefix changed');
    Require(Stored.Annotation=PersonalAnnotation,'User annotation changed');
    Require(Stored.Review.Contains('[High]') and Stored.Review.Contains('[Low]'),'Source reviews were lost');
    SystemDB.GetBookRecord(Stored.BookKey,Card);
    Require((Card.Rate=5) and (Card.Progress=72) and Card.Review.StartsWith(ExpectedReview),'Group card lost personal values');
  end;
begin
  Prefix:='series-'+IntToStr(Ord(Policy))+'-'+IntToStr(Scenario)+'-';
  Target:=MakeCollection('target'); HighSource:=MakeCollection('high'); LowSource:=MakeCollection('low');
  TargetID:=Target.CollectionID; HighID:=HighSource.CollectionID; LowID:=LowSource.CollectionID;
  IncomingPrimary:='Original cycle';
  case Scenario of
    1: IncomingPrimary:='New primary';
    2: IncomingPrimary:='Secondary 037';
  end;
  Anchor:=MakeBook(Target,Prefix+'shared','42','Original cycle',300,5,PersonalReview);
  Target.SetRate(CreateBookKey(Anchor,TargetID),5); Target.SetProgress(CreateBookKey(Anchor,TargetID),72);
  Target.SetAnnotation(CreateBookKey(Anchor,TargetID),PersonalAnnotation);
  // Ordinary book insertion trims imported reviews. Model already committed
  // personal text verbatim, including leading/trailing spaces, as the merge
  // preservation test in CollectionViewsTest does.
  DB:=TSQLiteDatabase.Create(CollectionFile(Target));
  try
    var ReviewQuery:=DB.NewQuery('UPDATE Books SET Review=? WHERE BookID=?');
    try ReviewQuery.SetBlobParam(0,PersonalReview); ReviewQuery.SetParam(1,Anchor); ReviewQuery.ExecSQL;
    finally ReviewQuery.Free; end;
  finally DB.Free; end;
  Target.GetBookRecord(CreateBookKey(Anchor,TargetID),Book,True); ExpectedReview:=Book.Review;
  Require(ExpectedReview=PersonalReview,'Before-merge fixture did not store exact personal text');
  Target.AddBookToGroup(CreateBookKey(Anchor,TargetID),FAVORITES_GROUP_ID);
  HighBook:=MakeBook(HighSource,Prefix+'shared','42',IncomingPrimary,100,7,'High thought ё');
  LowBook:=MakeBook(LowSource,Prefix+'shared','42',IncomingPrimary,50,7,'Low thought і');
  for I:=1 to 160 do
  begin
    SourceName:=Format('Secondary %.3d',[I]);
    Target.AddBookSeries(Anchor,SourceName,I);
    HighSource.AddBookSeries(HighBook,SourceName,I);
    LowSource.AddBookSeries(LowBook,SourceName,I);
  end;
  if Scenario<>3 then
  begin HighSource.AddBookSeries(HighBook,'Missing high',71); LowSource.AddBookSeries(LowBook,'Missing low',72); end
  else begin RemovePrimary(HighSource,HighBook); RemovePrimary(LowSource,LowBook); IncomingPrimary:=''; end;
  Publishers:=nil; TSeriesHelper.Add(Publishers,0,'Shared publisher',8,True);
  Target.SetBookPublisherSeries(CreateBookKey(Anchor,TargetID),Publishers);
  HighSource.SetBookPublisherSeries(CreateBookKey(HighBook,HighID),Publishers);
  LowSource.SetBookPublisherSeries(CreateBookKey(LowBook,LowID),Publishers);
  NewBook:=MakeBook(HighSource,Prefix+'new','99','New-book primary',125,3,'New-book thought');
  HighSource.AddBookSeries(NewBook,'New-book second',4); HighSource.AddBookSeries(NewBook,'New-book third',5);
  SetLength(Sources,3);
  Sources[0].ID:=Prefix+'high'; Sources[0].Name:='High'; Sources[0].Collection:=HighSource;
  Sources[1].ID:=Prefix+'low'; Sources[1].Name:='Low'; Sources[1].Collection:=LowSource;
  Sources[2].ID:=Prefix+'high-repeat'; Sources[2].Name:='High'; Sources[2].Collection:=HighSource;
  for I:=0 to High(Sources) do
  begin Sources[I].DatabaseFile:=CollectionFile(Sources[I].Collection); Sources[I].LibraryNamespace:='flibusta'; end;
  HighBefore:=SnapshotDatabase(CollectionFile(HighSource)); LowBefore:=SnapshotDatabase(CollectionFile(LowSource));
  BeforeRows:=SeriesRows(Target,Anchor); Plan:=TCollectionMergePlan.Create(Target,Sources,SystemDB,Policy);
  try
    Plan.Preview; Require((Plan.NewBooks=1) and (Plan.Duplicates=4),'Unexpected repeated-source preview counts');
    Profile:=Settings.AppPath+Prefix+'apply.tsv'; StartSQLiteProfile;
    try Plan.Apply(Settings.AppPath+Prefix+'backup'); SaveSQLiteProfile(Profile); finally StopSQLiteProfile; end;
    CheckPersonal;
    Require(Stored.Series=IncomingPrimary,'Primary selection differs from source');
    if IncomingPrimary<>'' then Require(Stored.SeqNumber=7,'Incoming primary number was lost');
    if Policy=mpSmallestFile then Require(Stored.Size=50,'Smallest policy lost selected metadata')
    else Require(Stored.Size=100,'Source order lost selected metadata');
    if Policy<>mpKeepAll then
    begin
      if Policy=mpSourcePriority then Require(Stored.CollectionName='High','Preferred source priority changed')
      else Require(Stored.CollectionName='Low','Preferred smallest source changed');
      DB:=TSQLiteDatabase.CreateReadOnly(CollectionFile(Target));
      try
        Require(DB.QuerySingleInt('SELECT BookSize FROM CatalogBookCopies WHERE BookID=? AND SourceKey LIKE ''base:%''',[Anchor])=300,
          'Original-copy size was replaced by preferred metadata');
        Require(DB.QuerySingleString('SELECT SourceName FROM CatalogBookCopies WHERE BookID=? AND SourceKey LIKE ''base:%''',[Anchor])=Prefix+'target',
          'Original-copy provenance changed');
      finally DB.Free; end;
    end;
    AfterRows:=SeriesRows(Target,Anchor);
    try
      for Pair in BeforeRows do
      begin
        Require(AfterRows.TryGetValue(Pair.Key,AfterRow),'Old membership disappeared: '+Pair.Key);
        Require(AfterRow.ID=Pair.Value.ID,'Existing SeriesID changed: '+Pair.Key);
        if (Scenario=2) and (Pair.Key='Secondary 037') then
          Require((AfterRow.Primary=1) and (AfterRow.Position=0) and (AfterRow.Number=7),'Promoted secondary has wrong primary/ordinal/number')
        else
        begin
          Require(AfterRow.Position=Pair.Value.Position,'Existing ordinal changed: '+Pair.Key);
          if (Pair.Key='Original cycle') and (Scenario=0) then
            Require((AfterRow.Number=7) and (AfterRow.Primary=1),'Original primary number/flag changed')
          else
          begin
            Require(AfterRow.Number=Pair.Value.Number,'Existing sequence changed: '+Pair.Key);
            if Pair.Key='Original cycle' then Require(AfterRow.Primary=0,'Old primary was not retained as secondary');
          end;
        end;
      end;
      if Scenario=3 then Require(AfterRows.Count=BeforeRows.Count,'Clearing primary invented or removed memberships')
      else
      begin
        Require(AfterRows.ContainsKey('Missing high') and AfterRows.ContainsKey('Missing low'),'New secondary membership missing');
        Require(AfterRows['Missing high'].Position=161,'First new membership ordinal is wrong');
        Require(AfterRows['Missing low'].Position=162,'Second new membership ordinal is wrong');
      end;
    finally AfterRows.Free; end;
    HighSource.GetBookRecord(CreateBookKey(NewBook,HighID),Book,True);
    DestinationNew:=Target.GetCatalogBookID(MergeSourceKey(Sources[0],Book));
    Require((DestinationNew>0) and (DestinationNew<>Anchor),'New book mapping failed');
    AfterRows:=SeriesRows(Target,DestinationNew);
    try
      Require((AfterRows.Count=3) and (AfterRows['New-book primary'].Position=0) and
        (AfterRows['New-book primary'].Primary=1) and (AfterRows['New-book second'].Position=1) and
        (AfterRows['New-book third'].Position=2),'New book duplicated primary or lost secondary order');
    finally AfterRows.Free; end;
    ExpectedAdds:=4; if Scenario=3 then ExpectedAdds:=2;
    Require(ProfileCalls(Profile,'SELECT IFNULL(MAX(OrdNum), -1) + 1 FROM Series_List')=ExpectedAdds,
      'Merge still adds existing memberships; see '+Profile);
    Require(ProfileCalls(Profile,'SELECT SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID FROM CatalogBookCopies')=0,
      'Merge original-copy guard added per-book copy-list reads');
    Require(HighBefore=SnapshotDatabase(CollectionFile(HighSource)),'Merge modified high source');
    Require(LowBefore=SnapshotDatabase(CollectionFile(LowSource)),'Merge modified low source');
    BeforeRepeat:=SnapshotDatabase(CollectionFile(Target)); Plan.Preview;
    Profile:=Settings.AppPath+Prefix+'repeat.tsv'; StartSQLiteProfile;
    try Plan.Apply(Settings.AppPath+Prefix+'repeat-backup'); SaveSQLiteProfile(Profile); finally StopSQLiteProfile; end;
    Require(ProfileCalls(Profile,'SELECT IFNULL(MAX(OrdNum), -1) + 1 FROM Series_List')=0,'Repeat merge called AddBookSeries');
    Require(ProfileCalls(Profile,'SELECT SourceName,Root,Folder,FileName,Ext,InsideNo,BookSize,LibID FROM CatalogBookCopies')=0,
      'Repeat original-copy guard added per-book copy-list reads');
    Require(BeforeRepeat=SnapshotDatabase(CollectionFile(Target)),'Repeat Apply changed catalog rows or series order');
    CheckPersonal;
    HighSource.GetBookRecord(CreateBookKey(HighBook,HighID),CancelBook,True);
    CancelBook.Title:='Mutation that must roll back'; HighSource.UpdateBook(CancelBook);
    HighSource.AddBookSeries(HighBook,'Canceled membership',85);
    Plan.Preview; TargetBefore:=SnapshotDatabase(CollectionFile(Target));
    SystemBefore:=SnapshotDatabase(Settings.SystemFileName[sfSystemDB]); CancelCalls:=0; Canceled:=False;
    try
      Plan.Apply(Settings.AppPath+Prefix+'cancel-backup',nil,
        function: Boolean
        var Probe: TBookRecord;
        begin
          Inc(CancelCalls); Target.GetBookRecord(CreateBookKey(Anchor,TargetID),Probe,False);
          Result:=Probe.Title<>Stored.Title;
        end);
    except on E: EAbort do Canceled:=True; end;
    Require(Canceled and (CancelCalls>1),'Cancellation was not exercised after mutation');
    Require(TargetBefore=SnapshotDatabase(CollectionFile(Target)),'Canceled Apply changed catalog data');
    Require(SystemBefore=SnapshotDatabase(Settings.SystemFileName[sfSystemDB]),'Canceled Apply changed groups/settings/user cards');
    DB:=TSQLiteDatabase.CreateReadOnly(CollectionFile(Target));
    try Require(DB.QuerySingleString('PRAGMA quick_check')='ok','Merged fixture integrity failed'); finally DB.Free; end;
    Writeln('PASS series delta policy=',Ord(Policy),' scenario=',Scenario,' adds=',ExpectedAdds,
      ' exact IDs/ordinals/personal values; repeat=0; canceled rollback'); Flush(Output);
  finally Plan.Free; BeforeRows.Free; end;
end;

var Policy: TCollectionMergePolicy; Scenario: Integer;
begin
  try
    RequireIsolatedRegression;
    Require(SameText(ExtractFileDrive(ExtractFilePath(ParamStr(0))),'G:'),'Tests require isolated G runtime');
    Require(ParamStr(1)='all','Run mode: all');
    Application.Initialize; InitLocalization; Application.CreateForm(TDMUser,DMUser); DMUser.Init;
    try
      TestOriginalCopyCapture;
      for Policy:=Low(TCollectionMergePolicy) to High(TCollectionMergePolicy) do
        for Scenario:=0 to 3 do RunCase(Policy,Scenario);
      Writeln('PASS all twelve native merge series delta fixtures'); Flush(Output);
    finally DMUser.Free; DMUser:=nil; end;
  except on E: Exception do begin Writeln('FAIL ',E.ClassName,': ',E.Message); Flush(Output); Halt(1); end; end;
end.
