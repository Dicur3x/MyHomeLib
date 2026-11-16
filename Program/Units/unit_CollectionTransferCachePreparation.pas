unit unit_CollectionTransferCachePreparation;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, SQLiteWrap,
  unit_CollectionTransferJournal, unit_CollectionTransferPublication, unit_CollectionTransferCacheSnapshot;

type TCollectionTransferCachePreparation=class
  private
    FJournal:TCollectionTransferJournal;
    FSession:TTransferPublicationSession;
    FPersonal:TSQLiteDatabase;
    FDatabases:TArray<TTransferPublicationDatabase>;
    FPlan:TJSONObject;
    FOperation,FIntentSHA,FState:string;
    FRootDone:Boolean;
    FCancelled:TFunc<Boolean>;
    FSourceDBs:TDictionary<string,TSQLiteDatabase>;
    FOwnedDBs:TObjectList<TSQLiteDatabase>;
    FLeases:TList<IInterface>;
    FInputs:TObjectDictionary<string,TFileStream>;
    FReady:TObjectList<TTransferCacheSnapshot>;
    function Stop:Boolean;
    procedure Check;
    procedure Point(const Stage:string);
    function Meta(const Name:string):string;
    procedure CheckOperation;
    procedure ReadIntent;
    procedure BuildPlan;
    procedure ValidatePlan;
    procedure CheckCurrent;
    function CurrentSources(CID:Integer):string;
    function PlanDB(const Key:string):TJSONObject;
    function InputsFor(const Job:string):TJSONArray;
    function LockSource(Job:TJSONObject; Capture:Boolean):TSQLiteDatabase;
    procedure LockInput(Row:TJSONObject; Capture:Boolean);
    procedure SaveIntent;
    procedure Remember(const Job,Binding,Stage,Data:string);
    function PrepareJob(Job:TJSONObject):Boolean;
  public
    constructor Create(Journal:TCollectionTransferJournal; Session:TTransferPublicationSession; RootsApplied:Boolean);
    destructor Destroy; override;
    class function HasIntent(Journal:TCollectionTransferJournal):Boolean; static;
    function Prepare(const Cancelled:TFunc<Boolean>=nil):Int64;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferCachePreparationTestPoint:TProc<string>;
{$ENDIF}

implementation

uses System.Hash, System.IOUtils, Winapi.Windows, unit_Consts, unit_Settings, dm_user,
  unit_BookCompressionReceipt, unit_BookCompressionPlanStore, unit_ZipMemberDeletion,
  unit_CollectionTransferLayout, unit_CollectionTransferPlan, unit_CollectionTransferCacheSettings;

const IntentTable='HomeLibreTransferCacheIntent'; StageTable='HomeLibreTransferCacheStages';
  ClaimTable='HomeLibreTransferCacheClaims'; Kind='HomeLibre cache preparation v1';

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=1; end;

function Setting(DB:TSQLiteDatabase; ID:Integer; out Present:Boolean):string;
begin
  Result:=''; var Q:=DB.NewQuery('SELECT SettingValue FROM Settings WHERE SettingID=?',[ID]);
  try Q.Open; Present:=not Q.Eof; if Present then Result:=Q.FieldAsString(0); finally Q.Free; end;
end;

function WithoutKeys(Items:TJSONArray):string;
begin
  var CopyValue:=TJSONObject.ParseJSONValue(Items.ToJSON) as TJSONArray;
  try for var Value in CopyValue do TJSONObject(Value).RemovePair('source_key').Free; Result:=CopyValue.ToJSON;
  finally CopyValue.Free; end;
end;

constructor TCollectionTransferCachePreparation.Create(Journal:TCollectionTransferJournal;
  Session:TTransferPublicationSession; RootsApplied:Boolean);
begin
  inherited Create;
  if (Journal=nil) or (Session=nil) then raise EArgumentException.Create('Нет журнала подготовки кэша.');
  FJournal:=Journal; FSession:=Session; FRootDone:=RootsApplied; FOperation:=Meta('directory');
  FSourceDBs:=TDictionary<string,TSQLiteDatabase>.Create;
  FOwnedDBs:=TObjectList<TSQLiteDatabase>.Create(True); FLeases:=TList<IInterface>.Create;
  FInputs:=TObjectDictionary<string,TFileStream>.Create([doOwnsValues]);
  FReady:=TObjectList<TTransferCacheSnapshot>.Create(True);
end;

destructor TCollectionTransferCachePreparation.Destroy;
begin
  FReady.Free;
  FInputs.Free;
  if FOwnedDBs<>nil then for var DB in FOwnedDBs do if DB.InTransaction then DB.Rollback;
  FOwnedDBs.Free; FSourceDBs.Free; FLeases.Free; FPlan.Free; inherited;
end;

function TCollectionTransferCachePreparation.Meta(const Name:string):string;
begin Result:=FJournal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;

function TCollectionTransferCachePreparation.Stop:Boolean;
begin
  Result:=False;
  if Assigned(FCancelled) and FCancelled() then raise EAbort.Create('Подготовка кэша остановлена. Перенос можно продолжить.');
  FJournal.CheckSpace;
end;

procedure TCollectionTransferCachePreparation.Check;
begin Stop; end;

procedure TCollectionTransferCachePreparation.Point(const Stage:string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferCachePreparationTestPoint) then TransferCachePreparationTestPoint(Stage);
{$ENDIF}
  Stop;
end;

class function TCollectionTransferCachePreparation.HasIntent(Journal:TCollectionTransferJournal):Boolean;
begin
  var Path:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal''');
  var Lease:=AcquireCompressionDatabaseLease(Path,Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key'''));
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Path));
  try Result:=HasTable(DB,IntentTable) and (DB.QuerySingleInt('SELECT count(*) FROM '+IntentTable+' WHERE Operation=?',
    [Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''')])=1);
  finally DB.Free; Lease:=nil; end;
end;

procedure TCollectionTransferCachePreparation.CheckOperation;
begin
  var Q:=FPersonal.NewQuery('SELECT Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination,CollectionID,State '+
    'FROM HomeLibreTransferOperations WHERE Operation=?',[FOperation]);
  try
    Q.Open;
    if Q.Eof or (Q.FieldAsString(0)<>FJournal.Directory) or (Q.FieldAsString(1)<>FJournal.ReviewSHA256) or
      (Q.FieldAsString(2)<>Meta('personal_key')) or (Q.FieldAsString(3)<>Meta('work_root')) or
      (Q.FieldAsString(4)<>Meta('destination')) or (Q.FieldAsInt(5)<>StrToInt(Meta('collection'))) or
      (Q.FieldAsString(6)<>'pending') then raise EReadError.Create('Регистрация подготовки кэша изменилась.');
  finally Q.Free; end;
end;

procedure TCollectionTransferCachePreparation.ReadIntent;
begin
  if not HasTable(FPersonal,IntentTable) then Exit;
  var Q:=FPersonal.NewQuery('SELECT ReviewSHA256,IntentJSON,IntentSHA256,State FROM '+IntentTable+' WHERE Operation=?',[FOperation]);
  try
    Q.Open; if Q.Eof then Exit; var Raw:=Q.FieldAsString(1);
    if (Q.FieldAsString(0)<>FJournal.ReviewSHA256) or (Length(Raw)>16*1024*1024) or
      (THashSHA2.GetHashString(Raw)<>Q.FieldAsString(2)) then raise EReadError.Create('Изменено независимое намерение подготовки кэша.');
    FPlan:=TJSONObject.ParseJSONValue(Raw) as TJSONObject; FIntentSHA:=Q.FieldAsString(2); FState:=Q.FieldAsString(3);
    if FPlan=nil then raise EReadError.Create('Нет намерения подготовки кэша.');
  finally Q.Free; end;
end;

function TCollectionTransferCachePreparation.PlanDB(const Key:string):TJSONObject;
begin
  Result:=nil;
  for var Value in FPlan.GetValue<TJSONArray>('databases') do if TJSONObject(Value).GetValue<string>('key')=Key then
  begin if Result<>nil then raise EReadError.Create('База повторяется в плане кэша.'); Result:=TJSONObject(Value); end;
  if Result=nil then raise EReadError.Create('В плане кэша пропущена база.');
end;

procedure TCollectionTransferCachePreparation.BuildPlan;
begin
  FPlan:=TJSONObject.Create; FPlan.AddPair('kind',Kind); FPlan.AddPair('operation',FOperation);
  FPlan.AddPair('review',FJournal.ReviewSHA256); FPlan.AddPair('data_root',Settings.DataPath);
  var Rows:=TJSONArray.Create; FPlan.AddPair('databases',Rows);
  var Store:=TCompressionPlanStore.Create(FJournal.Directory);
  try
    Store.DB.ExecSQL('BEGIN'); var Model:=TTransferCacheSettingsPlan.Create(FJournal.Review,Store.DB,Check);
    try
      for var Participant in FDatabases do
      begin
        Stop; var Row:=TJSONObject.Create; Rows.AddElement(Row); Row.AddPair('key',Participant.Key); Row.AddPair('path',Participant.Path);
        var Before:=FJournal.Review.QuerySingleString('SELECT SourcesJSON FROM ReferenceRegistrations WHERE RegistrationID=?',[Participant.Registrations[0]]);
        Row.AddPair('sources_before',Before); var Present:Boolean; Setting(Participant.Database,PROP_CATALOG_SOURCES,Present);
        Row.AddPair('sources_present',TJSONBool.Create(Present));
        Row.AddPair('sources_after',Model.ProjectSources(Before,Participant.Key=Meta('catalogue_key')));
        Before:=Setting(Participant.Database,PROP_LIBRARY_UPDATE_HISTORY,Present);
        Row.AddPair('history_before',Before); Row.AddPair('history_present',TJSONBool.Create(Present));
        Row.AddPair('history_after',Model.ProjectHistory(Before,Participant.Key=Meta('catalogue_key')));
      end;
      FPlan.AddPair('jobs',Model.Jobs); FPlan.AddPair('inputs',Model.Inputs); Store.DB.Commit;
    finally Model.Free; end;
  finally Store.Free; end;
  CheckCurrent;
  for var Value in FPlan.GetValue<TJSONArray>('jobs') do LockSource(TJSONObject(Value),True);
  for var Value in FPlan.GetValue<TJSONArray>('inputs') do LockInput(TJSONObject(Value),True);
end;

procedure TCollectionTransferCachePreparation.ValidatePlan;
begin
  if (FPlan.GetValue<string>('kind')<>Kind) or (FPlan.GetValue<string>('operation')<>FOperation) or
    (FPlan.GetValue<string>('review')<>FJournal.ReviewSHA256) or (FPlan.GetValue<string>('data_root')<>Settings.DataPath) or
    not ((FState='intent') or (FState='prepared') or (FState='')) or
    (FPlan.GetValue<TJSONArray>('databases').Count<>Length(FDatabases)) then raise EReadError.Create('Намерение относится к другой подготовке кэша.');
  var Versions:=TDictionary<string,string>.Create;
  try
    for var Value in FPlan.GetValue<TJSONArray>('jobs') do
    begin
      var Job:=Value as TJSONObject;
      if Length(Job.GetValue<string>('source_key'))<>25 then raise EReadError.Create('Нет ключа исходного кэша.');
      Versions.Add(Job.GetValue<string>('job'),Job.GetValue<string>('after_version'));
    end;
    for var Value in FPlan.GetValue<TJSONArray>('inputs') do
      if Length(TJSONObject(Value).GetValue<string>('source_key'))<>25 then raise EReadError.Create('Нет ключа исходного индекса.');
    var Store:=TCompressionPlanStore.Create(FJournal.Directory);
    try
      Store.DB.ExecSQL('BEGIN');
      var Model:=TTransferCacheSettingsPlan.Create(FJournal.Review,Store.DB,Check,
        function(Job:string):string
        begin if not Versions.TryGetValue(Job,Result) then raise EReadError.Create('В намерении пропущена версия кэша.'); end);
      try
        for var Participant in FDatabases do
        begin
          Stop; var Row:=PlanDB(Participant.Key);
          var Before:=FJournal.Review.QuerySingleString('SELECT SourcesJSON FROM ReferenceRegistrations WHERE RegistrationID=?',[Participant.Registrations[0]]);
          if (Row.GetValue<string>('path')<>Participant.Path) or (Row.GetValue<string>('sources_before')<>Before) or
            (Row.GetValue<string>('sources_after')<>Model.ProjectSources(Before,Participant.Key=Meta('catalogue_key'))) or
            (Row.GetValue<string>('history_after')<>Model.ProjectHistory(Row.GetValue<string>('history_before'),Participant.Key=Meta('catalogue_key'))) then
            raise EReadError.Create('Настройки кэша не совпали с проверенным планом.');
        end;
        var Jobs:=Model.Jobs; var Inputs:=Model.Inputs;
        try
          if (Jobs.ToJSON<>WithoutKeys(FPlan.GetValue<TJSONArray>('jobs'))) or
            (Inputs.ToJSON<>WithoutKeys(FPlan.GetValue<TJSONArray>('inputs'))) then raise EReadError.Create('Состав заданий кэша изменён.');
        finally Inputs.Free; Jobs.Free; end;
        Store.DB.Rollback;
      finally Model.Free; end;
    finally Store.Free; end;
  finally Versions.Free; end;
end;

function TCollectionTransferCachePreparation.CurrentSources(CID:Integer):string;
begin
  Result:=FJournal.Review.QuerySingleString('SELECT SourcesJSON FROM ReferenceRegistrations WHERE RegistrationID=?',[CID]);
  if FRootDone then
  begin
    var MoveRoots:=False;
    for var Participant in FDatabases do for var ID in Participant.Registrations do
      if ID=CID then MoveRoots:=Participant.Key=Meta('catalogue_key');
    var Layout:=TCollectionTransferLayout.Create(FJournal.Review);
    try Result:=Layout.ProjectSources(Result,MoveRoots); finally Layout.Free; end;
  end;
end;

procedure TCollectionTransferCachePreparation.CheckCurrent;
begin
  for var Participant in FDatabases do
  begin
    Stop; var Row:=PlanDB(Participant.Key); var Present:Boolean;
    if (Setting(Participant.Database,PROP_CATALOG_SOURCES,Present)<>CurrentSources(Participant.Registrations[0])) or
      (Present<>Row.GetValue<Boolean>('sources_present')) then raise EReadError.Create('Источники изменились перед подготовкой кэша.');
    if (Setting(Participant.Database,PROP_LIBRARY_UPDATE_HISTORY,Present)<>Row.GetValue<string>('history_before')) or
      (Present<>Row.GetValue<Boolean>('history_present')) then raise EReadError.Create('История обновлений изменилась перед подготовкой кэша.');
  end;
  var Root:=FJournal.Review.QuerySingleString('SELECT RawRoot FROM ReferenceRegistrations WHERE RegistrationID=?',[StrToInt(Meta('collection'))]);
  if FRootDone then
  begin var Layout:=TCollectionTransferLayout.Create(FJournal.Review);
    try Root:=Layout.RootDestination('collection'); finally Layout.Free; end;
  end;
  if FPersonal.QuerySingleString('SELECT RootFolder FROM Bases WHERE DatabaseID=?',[StrToInt(Meta('collection'))])<>Root then
    raise EReadError.Create('Корень коллекции изменился перед подготовкой кэша.');
end;

function TCollectionTransferCachePreparation.LockSource(Job:TJSONObject; Capture:Boolean):TSQLiteDatabase;
begin
  Stop; var Canonical,Identity:string; var Bytes:Int64; TransferReadFileState(Job.GetValue<string>('before_file'),Canonical,Identity,Bytes);
  var Key:=Copy(Identity,1,25);
  if Capture then Job.AddPair('source_key',Key)
  else if Job.GetValue<string>('source_key')<>Key then raise EReadError.Create('Исходный кэш заменён после намерения.');
  if Key=Meta('personal_key') then raise EReadError.Create('Кэш не может одновременно быть личной базой.');
  if FSourceDBs.TryGetValue(Key,Result) then Exit;
  FLeases.Add(AcquireCompressionDatabaseLease(Canonical,Key)); Result:=nil;
  for var Participant in FDatabases do if Participant.Key=Key then Result:=Participant.Database;
  if Result=nil then
  begin
    Result:=TSQLiteDatabase.Create(DeletionNativePath(Canonical),False); FOwnedDBs.Add(Result); Result.ExecSQL('BEGIN IMMEDIATE');
  end;
  FSourceDBs.Add(Key,Result);
end;

procedure TCollectionTransferCachePreparation.LockInput(Row:TJSONObject; Capture:Boolean);
begin
  Stop; var Path:=Row.GetValue<string>('source_file'); var Canonical,Identity:string; var Bytes:Int64;
  TransferReadFileState(Path,Canonical,Identity,Bytes); var Key:=Copy(Identity,1,25);
  if Capture then Row.AddPair('source_key',Key)
  else if Row.GetValue<string>('source_key')<>Key then raise EReadError.Create('Исходный индекс заменён после намерения.');
  if not FInputs.ContainsKey(LowerCase(Path)) then
  begin
    var Stream:=TFileStream.Create(DeletionNativePath(Canonical),fmOpenRead or fmShareDenyWrite);
    try
      if CompressionFileKey(Canonical)<>Key then raise EReadError.Create('Исходный индекс заменён при открытии.');
      FInputs.Add(LowerCase(Path),Stream);
    except Stream.Free; raise; end;
  end;
end;

function TCollectionTransferCachePreparation.InputsFor(const Job:string):TJSONArray;
begin
  Result:=TJSONArray.Create;
  for var Value in FPlan.GetValue<TJSONArray>('inputs') do if TJSONObject(Value).GetValue<string>('job')=Job then
    Result.AddElement(TJSONObject.ParseJSONValue(Value.ToJSON));
end;

procedure TCollectionTransferCachePreparation.SaveIntent;
begin
  var Raw:=FPlan.ToJSON; if Length(Raw)>16*1024*1024 then raise EReadError.Create('Слишком большой план подготовки кэша.');
  FIntentSHA:=THashSHA2.GetHashString(Raw);
  FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+IntentTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT,IntentJSON TEXT,IntentSHA256 TEXT,State TEXT CHECK(State IN (''intent'',''prepared''))) WITHOUT ROWID');
  FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+StageTable+'(Operation TEXT,Job TEXT,BindingSHA TEXT,Directory TEXT,DirectoryKey TEXT,ReadySHA TEXT,PRIMARY KEY(Operation,Job)) WITHOUT ROWID');
  FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+ClaimTable+'(Operation TEXT,Job TEXT,Directory TEXT,Stage TEXT,Path TEXT,FileKey TEXT,PRIMARY KEY(Operation,Job,Directory,Stage,Path)) WITHOUT ROWID');
  FPersonal.ExecSQL('INSERT INTO '+IntentTable+' VALUES(?,?,?,?,''intent'')',[FOperation,FJournal.ReviewSHA256,Raw,FIntentSHA]);
  Point('cache-preparation-before-intent-commit'); FPersonal.Commit; Point('cache-preparation-intent-committed');
  FSession.ReopenFinalizationPersonal; FState:='intent';
end;

procedure TCollectionTransferCachePreparation.Remember(const Job,Binding,Stage,Data:string);
begin
  Stop; CheckOperation;
  var Row:=TJSONObject.ParseJSONValue(Data) as TJSONObject;
  try
    var Directory:=Row.GetValue<string>('directory'); var Key:=Row.GetValue<string>('directory_key'); var Path:=Row.GetValue<string>('path');
    if (Row.GetValue<string>('binding')<>Binding) or
      not SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(Directory)),IncludeTrailingPathDelimiter(FJournal.Directory)) or
      ((Stage<>'cache-directory-created') and not Path.StartsWith(IncludeTrailingPathDelimiter(Directory),True)) then
      raise EReadError.Create('Запись владения кэшем выходит за пределы операции.');
    if Stage='cache-directory-created' then
      FPersonal.ExecSQL('INSERT OR REPLACE INTO '+StageTable+' VALUES(?,?,?,?,?,'''')',[FOperation,Job,Binding,Directory,Key])
    else
    begin
      var Saved:=FPersonal.NewQuery('SELECT BindingSHA,Directory,DirectoryKey,ReadySHA FROM '+StageTable+' WHERE Operation=? AND Job=?',[FOperation,Job]);
      try Saved.Open;
        if Saved.Eof or (Saved.FieldAsString(0)<>Binding) or (Saved.FieldAsString(1)<>Directory) or (Saved.FieldAsString(2)<>Key) or
          (Saved.FieldAsString(3)<>'') then raise EReadError.Create('Изменена независимая запись подготовки кэша.');
      finally Saved.Free; end;
    end;
    FPersonal.ExecSQL('INSERT OR REPLACE INTO '+ClaimTable+' VALUES(?,?,?,?,?,?)',[FOperation,Job,Directory,Stage,Path,Row.GetValue<string>('key')]);
    if Stage='cache-ready' then FPersonal.ExecSQL('UPDATE '+StageTable+' SET ReadySHA=? WHERE Operation=? AND Job=?',[Row.GetValue<string>('key'),FOperation,Job]);
    Point('cache-preparation-before-claim-commit'); FPersonal.Commit; Point('cache-preparation-claim-committed');
    FSession.ReopenFinalizationPersonal;
  finally Row.Free; end;
end;

function TCollectionTransferCachePreparation.PrepareJob(Job:TJSONObject):Boolean;
begin
  Stop; var ID:=Job.GetValue<string>('job'); var Inputs:=InputsFor(ID); var Snapshot:TTransferCacheSnapshot:=nil;
  try
    var Binding:=TTransferCacheSnapshot.Binding(FJournal.ReviewSHA256,Job.ToJSON,Inputs.ToJSON);
    var Q:=FPersonal.NewQuery('SELECT BindingSHA,Directory,DirectoryKey,ReadySHA FROM '+StageTable+' WHERE Operation=? AND Job=?',[FOperation,ID]);
    var Directory,DirectoryKey,ReadySHA:string;
    try Q.Open;
      if not Q.Eof then
      begin
        if Q.FieldAsString(0)<>Binding then raise EReadError.Create('Изменена привязка подготовленного кэша.');
        Directory:=Q.FieldAsString(1); DirectoryKey:=Q.FieldAsString(2); ReadySHA:=Q.FieldAsString(3);
      end;
    finally Q.Free; end;
    if ReadySHA<>'' then Snapshot:=TTransferCacheSnapshot.Recover(FJournal.Review,FJournal.ReviewSHA256,FJournal.Directory,
      Directory,DirectoryKey,Job.ToJSON,Inputs.ToJSON,Binding,ReadySHA,Check)
    else
    begin
      if FState='prepared' then raise EReadError.Create('Потеряно независимое подтверждение готового кэша.');
      var Writer:=LockSource(Job,False);
      for var Value in Inputs do LockInput(TJSONObject(Value),False);
      Snapshot:=TTransferCacheSnapshot.CreateNew(FJournal.Review,FJournal.ReviewSHA256,FJournal.Directory,Job.ToJSON,Inputs.ToJSON,Binding,
        procedure(const Stage,Data:string) begin Remember(ID,Binding,Stage,Data); end,Check,Writer);
    end;
    Snapshot.CheckUnchanged; Point('cache-preparation-job-ready');
    FReady.Add(Snapshot); Snapshot:=nil; Result:=True;
  finally Snapshot.Free; Inputs.Free; end;
end;

function TCollectionTransferCachePreparation.Prepare(const Cancelled:TFunc<Boolean>):Int64;
begin
  FCancelled:=Cancelled; Stop; FSession.BeginFinalization(Stop);
  try
    FPersonal:=FSession.FinalizationPersonal; FDatabases:=FSession.FinalizationDatabases;
    CheckOperation; ReadIntent;
    if FPlan=nil then begin BuildPlan; ValidatePlan; SaveIntent; end;
    ValidatePlan; CheckOperation; CheckCurrent;
    var Root:='';
    if FRootDone then begin var Layout:=TCollectionTransferLayout.Create(FJournal.Review);
      try Root:=Layout.RootDestination('collection'); finally Layout.Free; end;
    end;
    FSession.RefreshFinalizationReferences(CurrentSources,Root); Result:=0;
    for var Value in FPlan.GetValue<TJSONArray>('jobs') do if PrepareJob(TJSONObject(Value)) then Inc(Result);
    for var Snapshot in FReady do Snapshot.CheckUnchanged;
    CheckOperation; CheckCurrent; FSession.RefreshFinalizationReferences(CurrentSources,Root);
    if FState<>'prepared' then
    begin
      FPersonal.ExecSQL('UPDATE '+IntentTable+' SET State=''prepared'' WHERE Operation=? AND IntentSHA256=?',[FOperation,FIntentSHA]);
      if FPersonal.LastChangedRows<>1 then raise EReadError.Create('Не сохранена готовность зависимостей переноса.');
    end;
    Point('cache-preparation-before-complete-commit'); FPersonal.Commit; Point('cache-preparation-complete');
  finally
    FReady.Clear;
    FInputs.Clear;
    for var DB in FOwnedDBs do if DB.InTransaction then DB.Rollback;
    FOwnedDBs.Clear; FSourceDBs.Clear; FLeases.Clear;
    FSession.EndFinalization; FCancelled:=nil;
  end;
end;

end.
