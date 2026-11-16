unit unit_CollectionTransferPublication;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap,
  unit_CollectionTransferJournal, unit_CollectionTransferReferenceFence;

type TTransferPublicationSession=class
  private
    FReview,FPersonal:TSQLiteDatabase;
    FPersonalFile,FWorkRoot,FOperation,FReviewSHA,FPersonalKey:string;
    FDatabases:TObjectDictionary<string,TSQLiteDatabase>;
    FLists:TObjectDictionary<string,TList<Integer>>;
    FPaths:TDictionary<string,string>;
    FVersions:TDictionary<string,Int64>;
    FIDs:TList<Integer>;
    FLeases:TList<IInterface>;
    FSnapshot:TTransferReferenceSnapshot;
    FEffective:TFunc<Integer,string>;
    FTargets:TProc<TSQLiteDatabase>;
    FCancelled:TFunc<Boolean>;
    FScans:Integer;
    function CheckStop:Boolean;
    function VersionChanged(const Key:string; DB:TSQLiteDatabase):Boolean;
    function UnknownChanged:Boolean;
    procedure Rollback;
  public
    constructor Create(Review:TSQLiteDatabase; const PersonalFile,WorkRoot,Operation,ReviewSHA:string;
      const Effective:TFunc<Integer,string>; const Targets:TProc<TSQLiteDatabase>);
    destructor Destroy; override;
    procedure Publish(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>; const Point:TProc<string>;
      const PersonalChanges:TProc<TSQLiteDatabase> = nil);
    property Scans:Integer read FScans;
end;

implementation

uses System.Classes, unit_BookCompressionReceipt, unit_ZipMemberDeletion,
  unit_CollectionTransferLocations;

function TTransferPublicationSession.CheckStop:Boolean;
begin
  Result:=False;
  if Assigned(FCancelled) and FCancelled() then
    raise EAbort.Create('Публикация переноса остановлена. Исходные книги сохранены.');
end;

constructor TTransferPublicationSession.Create(Review:TSQLiteDatabase;
  const PersonalFile,WorkRoot,Operation,ReviewSHA:string;
  const Effective:TFunc<Integer,string>; const Targets:TProc<TSQLiteDatabase>);
begin
  inherited Create;
  FReview:=Review; FPersonalFile:=PersonalFile; FWorkRoot:=WorkRoot; FOperation:=Operation; FReviewSHA:=ReviewSHA;
  FEffective:=Effective; FTargets:=Targets;
  FDatabases:=TObjectDictionary<string,TSQLiteDatabase>.Create([doOwnsValues]);
  FLists:=TObjectDictionary<string,TList<Integer>>.Create([doOwnsValues]);
  FPaths:=TDictionary<string,string>.Create; FVersions:=TDictionary<string,Int64>.Create;
  FIDs:=TList<Integer>.Create; FLeases:=TList<IInterface>.Create;
  FPersonalKey:=FReview.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''');
  FLeases.Add(AcquireCompressionDatabaseLease(FPersonalFile,FPersonalKey));
  FPersonal:=TSQLiteDatabase.Create(DeletionNativePath(FPersonalFile));
  FPersonal.ExecSQL('PRAGMA synchronous=FULL');
end;

function TTransferPublicationSession.VersionChanged(const Key:string; DB:TSQLiteDatabase):Boolean;
begin
  var Version:=DB.QuerySingleInt('PRAGMA data_version'); var Before:Int64;
  Result:=not FVersions.TryGetValue(Key,Before) or (Before<>Version);
  // This exact connection survives own commits. SQLite data_version observes
  // commits by other connections, so no post-commit acknowledgement can hide
  // an intervening writer.
  FVersions.AddOrSetValue(Key,Version);
end;

function TTransferPublicationSession.UnknownChanged:Boolean;
begin
  Result:=False;
  var Q:=FReview.NewQuery('SELECT Catalogue,CatalogueKey FROM ReferenceRegistrations WHERE State<>''ready''');
  try
    Q.Open;
    while not Q.Eof do
    begin
      CheckStop; var Key:='';
      try Key:=CompressionFileKey(Q.FieldAsString(0));
      except
        on E:EOSError do begin if not (E.ErrorCode in [2,3]) then Exit(True); end;
        on E:EReadError do Exit(True);
      end;
      if (Key<>'') or (Key<>Q.FieldAsString(1)) then Exit(True);
      Q.Next;
    end;
  finally Q.Free; end;
end;

procedure TTransferPublicationSession.Rollback;
begin
  if FDatabases<>nil then
    for var Pair in FDatabases do if Pair.Value.InTransaction then Pair.Value.Rollback;
  if (FPersonal<>nil) and FPersonal.InTransaction then FPersonal.Rollback;
end;

procedure TTransferPublicationSession.Publish(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const Point:TProc<string>; const PersonalChanges:TProc<TSQLiteDatabase>);
var Q:TSQLiteQuery; Dirty:Boolean;
begin
  FCancelled:=Cancelled; Q:=nil;
  try
    try
    CheckStop; FPersonal.ExecSQL('BEGIN IMMEDIATE');
    Dirty:=VersionChanged(FPersonalKey,FPersonal) or (FSnapshot=nil);
    if FIDs.Count=0 then
    begin
      Q:=FReview.NewQuery('SELECT RegistrationID,State FROM ReferenceRegistrations ORDER BY RegistrationID'); Q.Open;
      while not Q.Eof do
      begin
        CheckStop; var CID:=Q.FieldAsInt(0); FIDs.Add(CID);
        if Q.FieldAsString(1)='ready' then
        begin
          var Path:=FEffective(CID); var Key:=CompressionFileKey(Path); var IDs:TList<Integer>;
          if Key=FPersonalKey then raise EReadError.Create('Каталог ссылается на личную базу данных.');
          if not FLists.TryGetValue(Key,IDs) then
          begin
            IDs:=TList<Integer>.Create; FLists.Add(Key,IDs); FPaths.Add(Key,Path);
            FLeases.Add(AcquireCompressionDatabaseLease(Path,Key));
            var DB:=TSQLiteDatabase.Create(DeletionNativePath(Path));
            FDatabases.Add(Key,DB); DB.ExecSQL('PRAGMA synchronous=FULL');
          end;
          IDs.Add(CID);
        end;
        Q.Next;
      end;
      FreeAndNil(Q);
    end;
    for var Pair in FDatabases do
    begin
      CheckStop; Pair.Value.ExecSQL('BEGIN IMMEDIATE');
      if VersionChanged(Pair.Key,Pair.Value) then Dirty:=True;
    end;
    if UnknownChanged then Dirty:=True;
    if Dirty then
    begin
      FreeAndNil(FSnapshot);
      FSnapshot:=TTransferReferenceSnapshot.Create(FReview,FPersonalFile,FWorkRoot,FEffective,FTargets,CheckStop);
      Inc(FScans);
    end;
    FSnapshot.CheckGroup(Prepared);
    if Assigned(Point) then Point('references-before-publication'); CheckStop;
    for var Pair in FDatabases do
    begin
      CheckStop;
      ApplyTransferLocations(Pair.Value,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FLists[Pair.Key].ToArray,False);
      if Assigned(Point) then Point('locations-before-catalogue-commit'); CheckStop;
      Pair.Value.ExecSQL('COMMIT');
      if Assigned(Point) then Point('locations-after-catalogue-commit');
    end;
    CheckStop;
    ApplyTransferLocations(FPersonal,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FIDs.ToArray,True);
    if Assigned(PersonalChanges) then PersonalChanges(FPersonal);
    if Assigned(Point) then Point('locations-before-personal-commit'); CheckStop;
    FPersonal.ExecSQL('COMMIT');
    if Assigned(Point) then Point('locations-after-personal-commit');
    except
      FreeAndNil(FSnapshot); Rollback; raise;
    end;
  finally Q.Free; FCancelled:=nil; end;
end;

destructor TTransferPublicationSession.Destroy;
begin
  Rollback; FSnapshot.Free; FDatabases.Free; FPersonal.Free; FLeases.Free;
  FIDs.Free; FVersions.Free; FPaths.Free; FLists.Free; inherited;
end;

end.
