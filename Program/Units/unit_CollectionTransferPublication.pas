unit unit_CollectionTransferPublication;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap,
  unit_CollectionTransferJournal, unit_CollectionTransferReferenceFence;

type
  TTransferPublicationDatabase=record
    Key,Path:string;
    Database:TSQLiteDatabase;
    Registrations:TArray<Integer>;
  end;
  TTransferPublicationSession=class
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
    procedure LockGroup(Prepared:TPreparedTransferGroup; ForceFresh:Boolean; SkipReferences:Boolean=False);
    function CheckLocations(Prepared:TPreparedTransferGroup; const Point:TProc<string>):Int64;
    procedure RefreshLockedGroup(Prepared:TPreparedTransferGroup);
  public
    constructor Create(Review:TSQLiteDatabase; const PersonalFile,WorkRoot,Operation,ReviewSHA:string;
      const Effective:TFunc<Integer,string>; const Targets:TProc<TSQLiteDatabase>);
    destructor Destroy; override;
    procedure Publish(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>; const Point:TProc<string>;
      const PersonalChanges:TProc<TSQLiteDatabase> = nil; ReconcileOnly:Boolean=False);
    // Verifies receipts/current locators under fresh reference and writer locks.
    // Returns retained/unresolved locators; never writes or permits later unlink.
    function VerifyPublished(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>;
      const Point:TProc<string>):Int64;
    procedure RemovePublished(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean>; const Point:TProc<string>;
      const RegistryCheck:TProc<TSQLiteDatabase>;
      const SaveIntent,RemoveSources:TProc<TSQLiteDatabase,TArray<Int64>>);
    // Metadata finalization owns these transactions until EndFinalization.
    // No source unlink can be authorized by these checks.
    procedure BeginFinalization(const Cancelled:TFunc<Boolean>);
    procedure RefreshFinalizationReferences(const FinalSources:TFunc<Integer,string>; const FinalRoot:string);
    procedure CheckFinalizationGroup(Prepared:TPreparedTransferGroup);
    procedure ReopenFinalizationPersonal;
    procedure EndFinalization;
    function FinalizationDatabases:TArray<TTransferPublicationDatabase>;
    property FinalizationPersonal:TSQLiteDatabase read FPersonal;
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
  FPersonal:=TSQLiteDatabase.Create(DeletionNativePath(FPersonalFile),False,False,FReview.TemporaryDirectory);
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

procedure TTransferPublicationSession.LockGroup(Prepared:TPreparedTransferGroup; ForceFresh,SkipReferences:Boolean);
var Q:TSQLiteQuery; Dirty:Boolean;
begin
  Q:=nil;
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
            var DB:=TSQLiteDatabase.Create(DeletionNativePath(Path),False,False,FReview.TemporaryDirectory);
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
    if not SkipReferences and (Dirty or ForceFresh) then
    begin
      FreeAndNil(FSnapshot);
      FSnapshot:=TTransferReferenceSnapshot.Create(FReview,FPersonalFile,FWorkRoot,FEffective,FTargets,CheckStop);
      Inc(FScans);
    end;
    if (Prepared<>nil) and not SkipReferences then FSnapshot.CheckGroup(Prepared);
  finally Q.Free; end;
end;

procedure TTransferPublicationSession.BeginFinalization(const Cancelled:TFunc<Boolean>);
begin
  FCancelled:=Cancelled;
  try LockGroup(nil,False,True);
  except EndFinalization; raise; end;
end;

procedure TTransferPublicationSession.RefreshFinalizationReferences(const FinalSources:TFunc<Integer,string>; const FinalRoot:string);
begin
  CheckStop;
  if not FPersonal.InTransaction then raise EArgumentException.Create('Нет личной транзакции завершения.');
  for var Pair in FDatabases do
    if not Pair.Value.InTransaction then raise EArgumentException.Create('Нет транзакции каталога для завершения.');
  FreeAndNil(FSnapshot);
  FSnapshot:=TTransferReferenceSnapshot.Create(FReview,FPersonalFile,FWorkRoot,FEffective,FTargets,CheckStop,FinalSources,FinalRoot);
  Inc(FScans);
end;

function TTransferPublicationSession.FinalizationDatabases:TArray<TTransferPublicationDatabase>;
begin
  var Keys:=TList<string>.Create;
  try
    for var Key in FDatabases.Keys do Keys.Add(Key); Keys.Sort;
    SetLength(Result,Keys.Count);
    for var I:=0 to Keys.Count-1 do
    begin
      var Key:=Keys[I]; Result[I].Key:=Key; Result[I].Path:=FPaths[Key];
      Result[I].Database:=FDatabases[Key]; Result[I].Registrations:=FLists[Key].ToArray;
    end;
  finally Keys.Free; end;
end;

procedure TTransferPublicationSession.CheckFinalizationGroup(Prepared:TPreparedTransferGroup);
begin
  CheckStop;
  if (FSnapshot=nil) or (Prepared=nil) then raise EArgumentException.Create('Нет свежей сверки завершения переноса.');
  FSnapshot.CheckGroup(Prepared);
  for var Pair in FDatabases do
    ApplyTransferLocations(Pair.Value,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FLists[Pair.Key].ToArray,False,True,False,True);
  ApplyTransferLocations(FPersonal,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FIDs.ToArray,True,False,True,True);
end;

procedure TTransferPublicationSession.ReopenFinalizationPersonal;
begin
  CheckStop;
  if FPersonal.InTransaction then raise EArgumentException.Create('Личная транзакция ещё открыта.');
  FPersonal.ExecSQL('BEGIN IMMEDIATE');
end;

procedure TTransferPublicationSession.EndFinalization;
begin Rollback; FreeAndNil(FSnapshot); FCancelled:=nil; end;

procedure TTransferPublicationSession.Publish(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const Point:TProc<string>; const PersonalChanges:TProc<TSQLiteDatabase>;
  ReconcileOnly:Boolean);
begin
  FCancelled:=Cancelled;
  try
    try
    LockGroup(Prepared,False);
    if Assigned(Point) then Point('references-before-publication'); CheckStop;
    for var Pair in FDatabases do
    begin
      CheckStop;
      ApplyTransferLocations(Pair.Value,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FLists[Pair.Key].ToArray,False,False,ReconcileOnly);
      if Assigned(Point) then Point('locations-before-catalogue-commit'); CheckStop;
      Pair.Value.ExecSQL('COMMIT');
      if Assigned(Point) then Point('locations-after-catalogue-commit');
    end;
    CheckStop;
    ApplyTransferLocations(FPersonal,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FIDs.ToArray,True,False,ReconcileOnly);
    if Assigned(PersonalChanges) then PersonalChanges(FPersonal);
    if Assigned(Point) then Point('locations-before-personal-commit'); CheckStop;
    FPersonal.ExecSQL('COMMIT');
    if Assigned(Point) then Point('locations-after-personal-commit');
    except
      FreeAndNil(FSnapshot); Rollback; raise;
    end;
  finally FCancelled:=nil; end;
end;

function TTransferPublicationSession.CheckLocations(Prepared:TPreparedTransferGroup; const Point:TProc<string>):Int64;
begin
  Result:=0;
      if Assigned(Point) then Point('locations-before-verification'); CheckStop;
      for var Pair in FDatabases do
      begin
        var Check:=ApplyTransferLocations(Pair.Value,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FLists[Pair.Key].ToArray,False,True);
        Inc(Result,Check.Retained);
        if Assigned(Point) then Point('locations-after-catalogue-verification'); CheckStop;
      end;
      var Check:=ApplyTransferLocations(FPersonal,FPersonal,FReview,Prepared,FOperation,FReviewSHA,FIDs.ToArray,True,True);
      Inc(Result,Check.Retained);
      if Assigned(Point) then Point('locations-after-personal-verification'); CheckStop;
end;

procedure TTransferPublicationSession.RefreshLockedGroup(Prepared:TPreparedTransferGroup);
begin
  FreeAndNil(FSnapshot);
  FSnapshot:=TTransferReferenceSnapshot.Create(FReview,FPersonalFile,FWorkRoot,FEffective,FTargets,CheckStop);
  Inc(FScans); FSnapshot.CheckGroup(Prepared);
end;

procedure TTransferPublicationSession.RemovePublished(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const Point:TProc<string>; const RegistryCheck:TProc<TSQLiteDatabase>;
  const SaveIntent,RemoveSources:TProc<TSQLiteDatabase,TArray<Int64>>);
begin
  if not Assigned(RegistryCheck) or not Assigned(SaveIntent) or not Assigned(RemoveSources) then
    raise EArgumentException.Create('Для освобождения исходников нужны привязанные этапы журнала.');
  FCancelled:=Cancelled;
  try
    try
      LockGroup(Prepared,True); CheckLocations(Prepared,Point); RegistryCheck(FPersonal);
      SaveIntent(FPersonal,FSnapshot.RetainedFiles(Prepared)); CheckStop;
      if Assigned(Point) then Point('removal-before-intent-commit'); CheckStop;
      FPersonal.ExecSQL('COMMIT');
      if Assigned(Point) then Point('removal-intent-committed');
      FPersonal.ExecSQL('BEGIN IMMEDIATE'); CheckStop;
      RefreshLockedGroup(Prepared); CheckLocations(Prepared,Point); RegistryCheck(FPersonal);
      if Assigned(Point) then Point('removal-before-sources'); CheckStop;
      RemoveSources(FPersonal,FSnapshot.RetainedFiles(Prepared));
      if Assigned(Point) then Point('removal-before-state-commit');
      FPersonal.ExecSQL('COMMIT');
      if Assigned(Point) then Point('removal-state-committed');
    except FreeAndNil(FSnapshot); raise; end;
  finally Rollback; FCancelled:=nil; end;
end;

function TTransferPublicationSession.VerifyPublished(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const Point:TProc<string>):Int64;
begin
  Result:=0; FCancelled:=Cancelled;
  try
    try
      LockGroup(Prepared,True);
      Result:=CheckLocations(Prepared,Point);
    except FreeAndNil(FSnapshot); raise; end;
  finally Rollback; FCancelled:=nil; end;
end;

destructor TTransferPublicationSession.Destroy;
begin
  Rollback; FSnapshot.Free; FDatabases.Free; FPersonal.Free; FLeases.Free;
  FIDs.Free; FVersions.Free; FPaths.Free; FLists.Free; inherited;
end;

end.
