unit unit_CollectionTransferCachePreparation;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections, SQLiteWrap,
  unit_CollectionTransferJournal, unit_CollectionTransferPublication, unit_CollectionTransferCacheSnapshot,
  unit_CollectionTransferCacheInstallation;

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
    FInstalled:TObjectList<TTransferCacheInstallation>;
    FDataRoot:TTransferCachePathGuard;
    FPublished:TDictionary<string,Boolean>;
    FRootSHA,FInstallSetSHA,FPublicationState:string;
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
    procedure RememberInstallation(const Job,Binding,Stage,Data:string);
    procedure InstallJob(Job:TJSONObject; Snapshot:TTransferCacheSnapshot);
    function ReadRootSHA:string;
    procedure RecoverInstalledVersions;
    procedure ReadPublication;
    procedure CheckMetadataReceipts;
    procedure PublishDatabase(const Participant:TTransferPublicationDatabase);
  public
    constructor Create(Journal:TCollectionTransferJournal; Session:TTransferPublicationSession; RootsApplied:Boolean);
    destructor Destroy; override;
    class function HasIntent(Journal:TCollectionTransferJournal):Boolean; static;
    class function HasPublication(Journal:TCollectionTransferJournal):Boolean; static;
    class function OpenPublishedGuard(Journal:TCollectionTransferJournal; Session:TTransferPublicationSession;
      const RootSHA:string; const Cancelled:TFunc<Boolean>=nil):TCollectionTransferCachePreparation; static;
    function AuthorizedSources(CID:Integer):string;
    function Prepare(const Cancelled:TFunc<Boolean>=nil; InstallVersions:Boolean=False):Int64;
    function PublishMetadata(const Cancelled:TFunc<Boolean>=nil):Int64;
    function MetadataPublished:Boolean;
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
  InstallTable='HomeLibreTransferCacheInstallations'; InstallClaims='HomeLibreTransferCacheInstallClaims';
  PublicationTable='HomeLibreTransferCachePublication'; MetadataReceipt='HomeLibreTransferCacheMetadata';

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
  FInstalled:=TObjectList<TTransferCacheInstallation>.Create(True);
  FPublished:=TDictionary<string,Boolean>.Create;
end;

destructor TCollectionTransferCachePreparation.Destroy;
begin
  FInstalled.Free;
  FReady.Free;
  FInputs.Free;
  if FOwnedDBs<>nil then for var DB in FOwnedDBs do if DB.InTransaction then DB.Rollback;
  FOwnedDBs.Free; FSourceDBs.Free; FLeases.Free; FPlan.Free; FDataRoot.Free; FPublished.Free; inherited;
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
  FreeAndNil(FPlan); FState:=''; FIntentSHA:='';
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
  FDataRoot:=TTransferCachePathGuard.Create(Settings.DataPath);
  FPlan.AddPair('data_root_key',FDataRoot.Key);
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
  if FDataRoot=nil then FDataRoot:=TTransferCachePathGuard.Create(Settings.DataPath);
  if FPlan.GetValue<string>('data_root_key')<>FDataRoot.Key then
    raise EReadError.Create('Папка данных заменена после намерения переноса.');
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
  for var Participant in FDatabases do for var ID in Participant.Registrations do
    if (ID=CID) and FPublished.ContainsKey(Participant.Key) then Exit(PlanDB(Participant.Key).GetValue<string>('sources_after'));
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
    var History:=Row.GetValue<string>('history_before');
    if FPublished.ContainsKey(Participant.Key) then History:=Row.GetValue<string>('history_after');
    if (Setting(Participant.Database,PROP_LIBRARY_UPDATE_HISTORY,Present)<>History) or
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

procedure TCollectionTransferCachePreparation.RememberInstallation(const Job,Binding,Stage,Data:string);
begin
  Stop; CheckOperation;
  var Row:=TJSONObject.ParseJSONValue(Data) as TJSONObject;
  try
    var PlanJob:TJSONObject:=nil;
    for var Value in FPlan.GetValue<TJSONArray>('jobs') do if TJSONObject(Value).GetValue<string>('job')=Job then PlanJob:=TJSONObject(Value);
    if PlanJob=nil then raise EReadError.Create('Нет задания установки в независимом намерении.');
    var Destination:=ExcludeTrailingPathDelimiter(ExtractFilePath(PlanJob.GetValue<string>('after_file')));
    var Directory:=Row.GetValue<string>('directory'); var Key:=Row.GetValue<string>('directory_key'); var Path:=Row.GetValue<string>('path');
    var Name:=ExtractFileName(Directory);
    if (Row.GetValue<string>('binding')<>Binding) or (Row.GetValue<string>('destination')<>Destination) or (Length(Key)<>25) or
      not SameFileName(ExtractFileDir(Directory),ExtractFileDir(Destination)) or not Name.StartsWith('transfer-cache-') or
      (Name<>'transfer-cache-'+StringToGUID(Copy(Name,16,MaxInt)).ToString) then
      raise EReadError.Create('Запись установки кэша выходит за пределы выбранной версии.');
    FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+InstallTable+'(Operation TEXT,Job TEXT,BindingSHA TEXT,'+
      'Directory TEXT,DirectoryKey TEXT,Destination TEXT,ProofJSON TEXT,ProofSHA TEXT,State TEXT '+
      'CHECK(State IN (''copying'',''ready'',''published'')),PRIMARY KEY(Operation,Job)) WITHOUT ROWID');
    FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+InstallClaims+'(Operation TEXT,Job TEXT,Directory TEXT,Stage TEXT,'+
      'Path TEXT,FileKey TEXT,PRIMARY KEY(Operation,Job,Directory,Stage,Path)) WITHOUT ROWID');
    if Stage='install-directory-created' then
    begin
      if (Path<>Directory) or (Row.GetValue<string>('key')<>Key) or
        (FPersonal.QuerySingleInt('SELECT count(*) FROM '+InstallTable+' WHERE Operation=? AND Job=? AND State<>''copying''',[FOperation,Job])<>0) then
        raise EReadError.Create('Нельзя заменить подтверждённую установку кэша новой попыткой.');
      FPersonal.ExecSQL('INSERT OR REPLACE INTO '+InstallTable+' VALUES(?,?,?,?,?,?,'''','''',''copying'')',
        [FOperation,Job,Binding,Directory,Key,Destination]);
    end
    else
    begin
      var Saved:=FPersonal.NewQuery('SELECT BindingSHA,Directory,DirectoryKey,Destination,State FROM '+InstallTable+' WHERE Operation=? AND Job=?',[FOperation,Job]);
      var State:string;
      try
        Saved.Open;
        if Saved.Eof or (Saved.FieldAsString(0)<>Binding) or (Saved.FieldAsString(1)<>Directory) or
          (Saved.FieldAsString(2)<>Key) or (Saved.FieldAsString(3)<>Destination) then
          raise EReadError.Create('Изменена независимая запись установки кэша.');
        State:=Saved.FieldAsString(4);
      finally Saved.Free; end;
      if Stage='install-ready' then
      begin
        if (State<>'copying') or (Path<>Directory) then raise EReadError.Create('Нет подготовки для подтверждения установки.');
        var Raw:=Row.GetValue<string>('proof'); var SHA:=Row.GetValue<string>('proof_sha256');
        var Proof:=TJSONObject.ParseJSONValue(Raw) as TJSONObject;
        try
          if (Length(Raw)>16*1024*1024) or (THashSHA2.GetHashString(Raw)<>SHA) or (Proof=nil) or
            (Proof.GetValue<string>('binding')<>Binding) or (Proof.GetValue<string>('directory_key')<>Key) or
            (Proof.GetValue<string>('stage_directory')<>Directory) or (Proof.GetValue<string>('destination')<>Destination) then
            raise EReadError.Create('Не совпало подтверждение готовой установки кэша.');
        finally Proof.Free; end;
        FPersonal.ExecSQL('UPDATE '+InstallTable+' SET ProofJSON=?,ProofSHA=?,State=''ready'' WHERE Operation=? AND Job=?',[Raw,SHA,FOperation,Job]);
      end
      else if Stage='install-published' then
      begin
        if (State<>'ready') or (Path<>Destination) or (Row.GetValue<string>('key')<>Key) then
          raise EReadError.Create('Нет готового подтверждения публикации кэша.');
        FPersonal.ExecSQL('UPDATE '+InstallTable+' SET State=''published'' WHERE Operation=? AND Job=?',[FOperation,Job]);
      end
      else if (Stage<>'install-file-reserved') or (State<>'copying') or
        not SameFileName(ExtractFileDir(Path),Directory) or (Length(Row.GetValue<string>('key'))<>25) then
        raise EReadError.Create('Неизвестная запись владения установкой кэша.');
    end;
    FPersonal.ExecSQL('INSERT OR REPLACE INTO '+InstallClaims+' VALUES(?,?,?,?,?,?)',[FOperation,Job,Directory,Stage,Path,Row.GetValue<string>('key')]);
    Point('cache-installation-before-claim-commit'); FPersonal.Commit; Point('cache-installation-claim-committed');
    FSession.ReopenFinalizationPersonal;
  finally Row.Free; end;
end;

procedure TCollectionTransferCachePreparation.InstallJob(Job:TJSONObject; Snapshot:TTransferCacheSnapshot);
begin
  Stop; var ID:=Job.GetValue<string>('job'); var Inputs:=InputsFor(ID); var Installed:TTransferCacheInstallation:=nil;
  try
    var Binding:=TTransferCacheInstallation.Binding(FJournal.ReviewSHA256,FIntentSHA,Job.ToJSON,Inputs.ToJSON,Snapshot.ReadySHA);
    var Raw,SHA,State:string;
    if HasTable(FPersonal,InstallTable) then
    begin
      var Q:=FPersonal.NewQuery('SELECT BindingSHA,ProofJSON,ProofSHA,State FROM '+InstallTable+' WHERE Operation=? AND Job=?',[FOperation,ID]);
      try Q.Open;
        if not Q.Eof then
        begin
          if Q.FieldAsString(0)<>Binding then raise EReadError.Create('Изменена привязка постоянного кэша.');
          Raw:=Q.FieldAsString(1); SHA:=Q.FieldAsString(2); State:=Q.FieldAsString(3);
        end;
      finally Q.Free; end;
    end;
    if (State<>'') and (State<>'copying') and (State<>'ready') and (State<>'published') then
      raise EReadError.Create('Неизвестное состояние установки кэша.');
    if SHA<>'' then
    begin
      if not ((State='ready') or (State='published')) then raise EReadError.Create('Не совпало состояние готовой установки кэша.');
      Installed:=TTransferCacheInstallation.Recover(FJournal.ReviewSHA256,FIntentSHA,Job.ToJSON,Inputs.ToJSON,Snapshot.ReadySHA,FDataRoot.Key,
        Raw,SHA,State='published',procedure(const Stage,Data:string) begin RememberInstallation(ID,Binding,Stage,Data); end,Check);
    end
    else
    begin
      if (State='ready') or (State='published') or (Raw<>'') then raise EReadError.Create('Потеряно независимое подтверждение постоянного кэша.');
      Installed:=TTransferCacheInstallation.CreateNew(FJournal.ReviewSHA256,FIntentSHA,Job.ToJSON,Inputs.ToJSON,FDataRoot.Key,Snapshot,
        procedure(const Stage,Data:string) begin RememberInstallation(ID,Binding,Stage,Data); end,Check);
    end;
    Installed.CheckUnchanged; FInstalled.Add(Installed); Installed:=nil; Point('cache-installation-job-published');
  finally Installed.Free; Inputs.Free; end;
end;

function TCollectionTransferCachePreparation.Prepare(const Cancelled:TFunc<Boolean>; InstallVersions:Boolean):Int64;
begin
  FCancelled:=Cancelled; Stop; FSession.BeginFinalization(Stop);
  try
    FPersonal:=FSession.FinalizationPersonal; FDatabases:=FSession.FinalizationDatabases;
    CheckOperation; ReadIntent;
    if InstallVersions and (not FRootDone or (FPlan=nil) or (FState<>'prepared')) then
      raise EReadError.Create('Для установки кэша нужны подготовленное намерение и подтверждённые итоговые корни.');
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
    if InstallVersions then
    begin
      FSession.ReopenFinalizationPersonal;
      for var I:=0 to FReady.Count-1 do InstallJob(TJSONObject(FPlan.GetValue<TJSONArray>('jobs').Items[I]),FReady[I]);
      for var Installed in FInstalled do Installed.CheckUnchanged;
      CheckOperation; CheckCurrent; FSession.RefreshFinalizationReferences(CurrentSources,Root);
      FPersonal.Commit; Point('cache-installation-complete');
    end;
  finally
    FInstalled.Clear;
    FReady.Clear;
    FInputs.Clear;
    for var DB in FOwnedDBs do if DB.InTransaction then DB.Rollback;
    FOwnedDBs.Clear; FSourceDBs.Clear; FLeases.Clear;
    FSession.EndFinalization; FCancelled:=nil;
  end;
end;

class function TCollectionTransferCachePreparation.HasPublication(Journal:TCollectionTransferJournal):Boolean;
begin
  var Path:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal''');
  var Lease:=AcquireCompressionDatabaseLease(Path,Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key'''));
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Path));
  try Result:=HasTable(DB,PublicationTable) and (DB.QuerySingleInt('SELECT count(*) FROM '+PublicationTable+' WHERE Operation=?',
    [Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''')])<>0);
  finally DB.Free; Lease:=nil; end;
end;

function TCollectionTransferCachePreparation.ReadRootSHA:string;
begin
  if not HasTable(FPersonal,'HomeLibreTransferFinalization') then raise EReadError.Create('Нет подтверждённых итоговых корней для источников.');
  var Q:=FPersonal.NewQuery('SELECT ReviewSHA256,IntentJSON,IntentSHA256,State FROM HomeLibreTransferFinalization WHERE Operation=?',[FOperation]);
  try Q.Open;
    if Q.Eof or (Q.FieldAsString(0)<>FJournal.ReviewSHA256) or (Length(Q.FieldAsString(1))>16*1024*1024) or
      (THashSHA2.GetHashString(Q.FieldAsString(1))<>Q.FieldAsString(2)) or (Q.FieldAsString(3)<>'roots-applied') then
      raise EReadError.Create('Итоговые корни не подтверждены для публикации источников.');
    Result:=Q.FieldAsString(2);
  finally Q.Free; end;
end;

procedure TCollectionTransferCachePreparation.RecoverInstalledVersions;
begin
  FInstalled.Clear; var Signature:='HomeLibre cache metadata v1'+#0+FJournal.ReviewSHA256+#0+FIntentSHA+#0+FRootSHA;
  for var Value in FPlan.GetValue<TJSONArray>('jobs') do
  begin
    Stop; var Job:=Value as TJSONObject; var ID:=Job.GetValue<string>('job'); var Inputs:=InputsFor(ID);
    try
      if not HasTable(FPersonal,InstallTable) or not HasTable(FPersonal,StageTable) then
        raise EReadError.Create('Нет независимого подтверждения постоянных версий кэша.');
      var Source:=FPersonal.NewQuery('SELECT BindingSHA,ReadySHA FROM '+StageTable+' WHERE Operation=? AND Job=?',[FOperation,ID]);
      var SnapshotSHA:string;
      try Source.Open;
        if Source.Eof or (Source.FieldAsString(0)<>TTransferCacheSnapshot.Binding(FJournal.ReviewSHA256,Job.ToJSON,Inputs.ToJSON)) or
          (Length(Source.FieldAsString(1))<>64) then raise EReadError.Create('Потеряно подтверждение исходного снимка установки.');
        SnapshotSHA:=Source.FieldAsString(1);
      finally Source.Free; end;
      var Q:=FPersonal.NewQuery('SELECT BindingSHA,Directory,DirectoryKey,Destination,ProofJSON,ProofSHA,State FROM '+InstallTable+
        ' WHERE Operation=? AND Job=?',[FOperation,ID]);
      try Q.Open;
        var Binding:=TTransferCacheInstallation.Binding(FJournal.ReviewSHA256,FIntentSHA,Job.ToJSON,Inputs.ToJSON,SnapshotSHA);
        if Q.Eof or (Q.FieldAsString(0)<>Binding) or (Q.FieldAsString(6)<>'published') or
          (Length(Q.FieldAsString(4))>16*1024*1024) or (Length(Q.FieldAsString(5))<>64) or
          (THashSHA2.GetHashString(Q.FieldAsString(4))<>Q.FieldAsString(5)) then
          raise EReadError.Create('Не все постоянные версии кэша подтверждены.');
        var Proof:=TJSONObject.ParseJSONValue(Q.FieldAsString(4)) as TJSONObject;
        try
          if (Proof=nil) or (Q.FieldAsString(1)<>Proof.GetValue<string>('stage_directory')) or
            (Q.FieldAsString(2)<>Proof.GetValue<string>('directory_key')) or
            (Q.FieldAsString(3)<>Proof.GetValue<string>('destination')) then
            raise EReadError.Create('Независимая запись установки не совпала с её подтверждением.');
        finally Proof.Free; end;
        var Installed:=TTransferCacheInstallation.Recover(FJournal.ReviewSHA256,FIntentSHA,Job.ToJSON,Inputs.ToJSON,SnapshotSHA,
          FDataRoot.Key,Q.FieldAsString(4),Q.FieldAsString(5),True,nil,Check);
        FInstalled.Add(Installed); Signature:=Signature+#0+ID+#0+Q.FieldAsString(5);
      finally Q.Free; end;
    finally Inputs.Free; end;
  end;
  FInstallSetSHA:=THashSHA2.GetHashString(Signature);
end;

procedure TCollectionTransferCachePreparation.ReadPublication;
begin
  FPublicationState:='';
  if not HasTable(FPersonal,PublicationTable) then Exit;
  var Q:=FPersonal.NewQuery('SELECT ReviewSHA256,CacheSHA256,RootSHA256,InstallSetSHA256,State FROM '+PublicationTable+' WHERE Operation=?',[FOperation]);
  try Q.Open; if Q.Eof then Exit;
    if (Q.FieldAsString(0)<>FJournal.ReviewSHA256) or (Q.FieldAsString(1)<>FIntentSHA) or
      (Q.FieldAsString(2)<>FRootSHA) or (Q.FieldAsString(3)<>FInstallSetSHA) or
      not ((Q.FieldAsString(4)='intent') or (Q.FieldAsString(4)='published')) then
      raise EReadError.Create('Независимое намерение публикации источников изменено.');
    FPublicationState:=Q.FieldAsString(4); Q.Next;
    if not Q.Eof then raise EReadError.Create('Повтор намерения публикации источников.');
  finally Q.Free; end;
end;

procedure TCollectionTransferCachePreparation.CheckMetadataReceipts;
begin
  FPublished.Clear;
  for var Participant in FDatabases do
  begin
    Stop; var Found:=False;
    if HasTable(Participant.Database,MetadataReceipt) then
    begin
      var Q:=Participant.Database.NewQuery('SELECT ReviewSHA256,CacheSHA256,RootSHA256,InstallSetSHA256,DatabaseKey,SourceSHA256,HistorySHA256 '+
        'FROM '+MetadataReceipt+' WHERE Operation=?',[FOperation]);
      try Q.Open; Found:=not Q.Eof;
        if Found then
        begin
          var Row:=PlanDB(Participant.Key);
          if (FPublicationState='') or (Q.FieldAsString(0)<>FJournal.ReviewSHA256) or (Q.FieldAsString(1)<>FIntentSHA) or
            (Q.FieldAsString(2)<>FRootSHA) or (Q.FieldAsString(3)<>FInstallSetSHA) or (Q.FieldAsString(4)<>Participant.Key) or
            (Q.FieldAsString(5)<>THashSHA2.GetHashString(Row.GetValue<string>('sources_after'))) or
            (Q.FieldAsString(6)<>THashSHA2.GetHashString(Row.GetValue<string>('history_after'))) then
            raise EReadError.Create('Квитанция публикации источников изменилась.');
          FPublished.Add(Participant.Key,True); Q.Next;
          if not Q.Eof then raise EReadError.Create('Повтор квитанции источников в каталоге.');
        end;
      finally Q.Free; end;
    end;
    if not Found and (FPublicationState='published') then raise EReadError.Create('Потеряна квитанция опубликованных источников.');
  end;
end;

class function TCollectionTransferCachePreparation.OpenPublishedGuard(Journal:TCollectionTransferJournal;
  Session:TTransferPublicationSession; const RootSHA:string; const Cancelled:TFunc<Boolean>):TCollectionTransferCachePreparation;
begin
  Result:=nil; var Personal:=Session.FinalizationPersonal;
  if not HasTable(Personal,PublicationTable) or
    (Personal.QuerySingleInt('SELECT count(*) FROM '+PublicationTable+' WHERE Operation=?',
      [Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''directory''')])=0) then Exit;
  Result:=TCollectionTransferCachePreparation.Create(Journal,Session,True);
  try
    Result.FCancelled:=Cancelled; Result.FPersonal:=Personal; Result.FDatabases:=Session.FinalizationDatabases;
    Result.CheckOperation; Result.ReadIntent;
    if (Result.FPlan=nil) or (Result.FState<>'prepared') then raise EReadError.Create('Потеряно подготовленное намерение источников.');
    Result.ValidatePlan; Result.FRootSHA:=Result.ReadRootSHA;
    if Result.FRootSHA<>RootSHA then raise EReadError.Create('Публикация относится к другому завершению корней.');
    Result.RecoverInstalledVersions; Result.ReadPublication; Result.CheckMetadataReceipts; Result.CheckCurrent;
  except Result.Free; raise; end;
end;

function TCollectionTransferCachePreparation.MetadataPublished:Boolean;
begin Result:=FPublicationState='published'; end;

function TCollectionTransferCachePreparation.AuthorizedSources(CID:Integer):string;
begin Result:=CurrentSources(CID); end;

procedure TCollectionTransferCachePreparation.PublishDatabase(const Participant:TTransferPublicationDatabase);
begin
  Stop; if FPublished.ContainsKey(Participant.Key) then Exit;
  var DB:=Participant.Database; var Row:=PlanDB(Participant.Key);
  for var Kind in ['sources','history'] do
  begin
    var Before:=Row.GetValue<string>('history_before'); var After:=Row.GetValue<string>('history_after');
    var ID:=PROP_LIBRARY_UPDATE_HISTORY;
    if Kind='sources' then
    begin Before:=CurrentSources(Participant.Registrations[0]); After:=Row.GetValue<string>('sources_after'); ID:=PROP_CATALOG_SOURCES; end;
    if Before=After then Continue;
    DB.ExecSQL('UPDATE Settings SET SettingValue=? WHERE SettingID=?',[After,ID]);
    if DB.LastChangedRows<>1 then raise EWriteError.Create('Не сохранены ссылки источников или история обновлений.');
  end;
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+MetadataReceipt+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
    'CacheSHA256 TEXT NOT NULL,RootSHA256 TEXT NOT NULL,InstallSetSHA256 TEXT NOT NULL,DatabaseKey TEXT NOT NULL,'+
    'SourceSHA256 TEXT NOT NULL,HistorySHA256 TEXT NOT NULL) WITHOUT ROWID');
  DB.ExecSQL('INSERT INTO '+MetadataReceipt+' VALUES(?,?,?,?,?,?,?,?)',[FOperation,FJournal.ReviewSHA256,FIntentSHA,FRootSHA,FInstallSetSHA,
    Participant.Key,THashSHA2.GetHashString(Row.GetValue<string>('sources_after')),THashSHA2.GetHashString(Row.GetValue<string>('history_after'))]);
  var Version:=DB.QuerySingleInt('PRAGMA data_version'); Point('cache-metadata-before-catalogue-commit');
  DB.Commit; Point('cache-metadata-after-catalogue-commit'); DB.ExecSQL('BEGIN IMMEDIATE');
  if DB.QuerySingleInt('PRAGMA data_version')<>Version then
    raise EReadError.Create('Каталог изменился между этапами публикации источников. Повторите продолжение переноса.');
  FPublished.Add(Participant.Key,True); CheckCurrent;
end;

function TCollectionTransferCachePreparation.PublishMetadata(const Cancelled:TFunc<Boolean>):Int64;
begin
  FCancelled:=Cancelled; FRootDone:=True; Stop; FSession.BeginFinalization(Stop);
  try
    FPersonal:=FSession.FinalizationPersonal; FDatabases:=FSession.FinalizationDatabases;
    CheckOperation; ReadIntent;
    if (FPlan=nil) or (FState<>'prepared') then raise EReadError.Create('Нет подготовленного намерения для публикации источников.');
    ValidatePlan; FRootSHA:=ReadRootSHA; RecoverInstalledVersions; ReadPublication; CheckMetadataReceipts; CheckCurrent;
    var Layout:=TCollectionTransferLayout.Create(FJournal.Review); var Root:string;
    try Root:=Layout.RootDestination('collection'); finally Layout.Free; end;
    FSession.RefreshFinalizationReferences(CurrentSources,Root);
    if FPublicationState='' then
    begin
      FPersonal.ExecSQL('CREATE TABLE IF NOT EXISTS '+PublicationTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
        'CacheSHA256 TEXT NOT NULL,RootSHA256 TEXT NOT NULL,InstallSetSHA256 TEXT NOT NULL,State TEXT NOT NULL CHECK(State IN (''intent'',''published''))) WITHOUT ROWID');
      FPersonal.ExecSQL('INSERT INTO '+PublicationTable+' VALUES(?,?,?,?,?,''intent'')',[FOperation,FJournal.ReviewSHA256,FIntentSHA,FRootSHA,FInstallSetSHA]);
      Point('cache-metadata-before-intent-commit'); FPersonal.Commit; Point('cache-metadata-intent-committed');
      FSession.ReopenFinalizationPersonal; FPublicationState:='intent'; CheckOperation; CheckCurrent;
      FSession.RefreshFinalizationReferences(CurrentSources,Root);
    end;
    for var Participant in FDatabases do PublishDatabase(Participant);
    for var Installed in FInstalled do Installed.CheckUnchanged;
    CheckOperation; CheckMetadataReceipts; CheckCurrent; FSession.RefreshFinalizationReferences(CurrentSources,Root);
    if FPublished.Count<>Length(FDatabases) then raise EReadError.Create('Не все каталоги подтвердили источники.');
    if FPublicationState<>'published' then
    begin
      FPersonal.ExecSQL('UPDATE '+PublicationTable+' SET State=''published'' WHERE Operation=? AND ReviewSHA256=? AND CacheSHA256=? AND RootSHA256=? AND InstallSetSHA256=?',
        [FOperation,FJournal.ReviewSHA256,FIntentSHA,FRootSHA,FInstallSetSHA]);
      if FPersonal.LastChangedRows<>1 then raise EReadError.Create('Не подтверждено завершение публикации источников.');
    end;
    Point('cache-metadata-before-complete-commit'); FPersonal.Commit; Point('cache-metadata-complete'); Result:=FPublished.Count;
  finally FInstalled.Clear; FSession.EndFinalization; FCancelled:=nil; end;
end;

end.
