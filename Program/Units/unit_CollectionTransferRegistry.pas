unit unit_CollectionTransferRegistry;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal;

type
  TRegisteredCollectionTransfer=record
    Operation,Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination:string;
    CollectionID:Integer;
  end;

  // The personal database is independent of the mutable per-file/group state.
  // Registration never grants source-removal or operation-completion authority.
  TCollectionTransferRegistry=class
  private
    FJournal:TCollectionTransferJournal;
    FInfo:TRegisteredCollectionTransfer;
    FPersonal:string;
    function OpenDatabase(Writable:Boolean; out Lease:IInterface):TSQLiteDatabase;
    procedure CheckRegistration(DB:TSQLiteDatabase);
    procedure StoreGroupProof(DB:TSQLiteDatabase; GroupID:Int64; const SHA:string;
      const Cancelled:TFunc<Boolean>);
  public
    constructor Create(Journal:TCollectionTransferJournal);
    procedure RegisterOperation(const Cancelled:TFunc<Boolean> = nil);
    function RememberPreparedGroup(Prepared:TPreparedTransferGroup;
      const Cancelled:TFunc<Boolean> = nil):string;
    // Commit the independent proof with personal locators, on the publication
    // session's existing connection. Own registry writes cannot invalidate its
    // reference snapshot or mask an intervening external writer.
    procedure PublishPreparedGroup(Prepared:TPreparedTransferGroup;
      const Cancelled:TFunc<Boolean> = nil);
    function RecoverGroup(GroupID:Int64; const Cancelled:TFunc<Boolean> = nil):TPreparedTransferGroup;
  end;

function RegisteredCollectionTransfers(const PersonalFile:string):TArray<TRegisteredCollectionTransfer>;
function ResumeRegisteredCollectionTransfer(const PersonalFile,Operation:string):TCollectionTransferJournal;

{$IFDEF MHL_TRANSFER_TEST}
var TransferRegistryTestPoint:TProc<string,string,Int64>;
{$ENDIF}

implementation

uses System.Classes, System.IOUtils, System.Generics.Collections,
  unit_BookCompressionReceipt, unit_ZipMemberDeletion;

const OperationTable='HomeLibreTransferOperations'; ProofTable='HomeLibreTransferGroupProofs';

procedure Stop(const Cancelled:TFunc<Boolean>);
begin
  if Assigned(Cancelled) and Cancelled() then
    raise EAbort.Create('Сохранение переноса остановлено. Исходники сохранены.');
end;

procedure Point(const Stage,Operation:string; GroupID:Int64);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferRegistryTestPoint) then TransferRegistryTestPoint(Stage,Operation,GroupID);
{$ENDIF}
end;

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=1; end;

procedure CheckInfo(const Info:TRegisteredCollectionTransfer);
begin
  if not Info.Operation.StartsWith('collection-transfer-') then raise EReadError.Create('Неверное имя операции переноса.');
  var ID:=StringToGUID(Copy(Info.Operation,Length('collection-transfer-')+1,MaxInt));
  if (Info.Operation<>'collection-transfer-'+GUIDToString(ID)) or (Info.CollectionID<=0) or
    (Length(Info.PersonalKey)<>25) or (Length(Info.ReviewSHA256)<>64) or
    not TPath.IsPathRooted(Info.Directory) or not TPath.IsPathRooted(Info.WorkRoot) or
    not TPath.IsPathRooted(Info.Destination) or
    (ExtractFileName(Info.Directory)<>Info.Operation) or
    not SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(Info.Directory)),Info.WorkRoot) then
    raise EReadError.Create('Повреждена регистрация переноса.');
  for var C in Info.ReviewSHA256 do
    if not CharInSet(C,['0'..'9','a'..'f']) then raise EReadError.Create('Неверная проверочная сумма зарегистрированного переноса.');
end;

function ReadInfo(Q:TSQLiteQuery):TRegisteredCollectionTransfer;
begin
  Result.Operation:=Q.FieldAsString(0); Result.Directory:=Q.FieldAsString(1);
  Result.ReviewSHA256:=Q.FieldAsString(2); Result.PersonalKey:=Q.FieldAsString(3);
  Result.WorkRoot:=Q.FieldAsString(4); Result.Destination:=Q.FieldAsString(5);
  Result.CollectionID:=Q.FieldAsInt(6); CheckInfo(Result);
end;

function RegisteredCollectionTransfers(const PersonalFile:string):TArray<TRegisteredCollectionTransfer>;
var Lease:IInterface; DB:TSQLiteDatabase; Q:TSQLiteQuery; Items:TList<TRegisteredCollectionTransfer>;
begin
  Result:=nil; DB:=nil; Q:=nil; Items:=TList<TRegisteredCollectionTransfer>.Create;
  try
    var Key:=CompressionFileKey(PersonalFile); Lease:=AcquireCompressionDatabaseLease(PersonalFile,Key);
    DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(PersonalFile));
    if not HasTable(DB,OperationTable) then Exit;
    Q:=DB.NewQuery('SELECT Operation,Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination,CollectionID '+
      'FROM '+OperationTable+' WHERE State=''pending'' ORDER BY Operation'); Q.Open;
    while not Q.Eof do
    begin
      var Info:=ReadInfo(Q);
      if Info.PersonalKey<>Key then raise EReadError.Create('Перенос относится к другой личной базе.');
      if Items.Count>=1024 then raise EReadError.Create('Слишком много незавершённых переносов.');
      Items.Add(Info); Q.Next;
    end;
    Result:=Items.ToArray;
  finally Q.Free; DB.Free; Lease:=nil; Items.Free; end;
end;

constructor TCollectionTransferRegistry.Create(Journal:TCollectionTransferJournal);
  function Meta(const Name:string):string;
  begin Result:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;
begin
  inherited Create;
  if Journal=nil then raise EArgumentException.Create('Не указан проверенный журнал переноса.');
  FJournal:=Journal; FInfo.Operation:=Meta('directory'); FInfo.Directory:=Journal.Directory;
  FInfo.ReviewSHA256:=Journal.ReviewSHA256; FInfo.PersonalKey:=Meta('personal_key');
  FInfo.WorkRoot:=Meta('work_root'); FInfo.Destination:=Meta('destination');
  FInfo.CollectionID:=StrToInt(Meta('collection')); FPersonal:=Meta('personal'); CheckInfo(FInfo);
end;

function TCollectionTransferRegistry.OpenDatabase(Writable:Boolean; out Lease:IInterface):TSQLiteDatabase;
begin
  Result:=nil; Lease:=AcquireCompressionDatabaseLease(FPersonal,FInfo.PersonalKey);
  if Writable then
  begin
    Result:=TSQLiteDatabase.Create(DeletionNativePath(FPersonal));
    try Result.ExecSQL('PRAGMA synchronous=FULL'); except Result.Free; raise; end;
  end
  else Result:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(FPersonal));
end;

procedure TCollectionTransferRegistry.CheckRegistration(DB:TSQLiteDatabase);
begin
  if not HasTable(DB,OperationTable) then raise EReadError.Create('Перенос не зарегистрирован в личной базе.');
  var Q:=DB.NewQuery('SELECT Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination,CollectionID,State '+
    'FROM '+OperationTable+' WHERE Operation=?',[FInfo.Operation]);
  try
    Q.Open;
    if Q.Eof or (Q.FieldAsString(0)<>FInfo.Directory) or (Q.FieldAsString(1)<>FInfo.ReviewSHA256) or
      (Q.FieldAsString(2)<>FInfo.PersonalKey) or (Q.FieldAsString(3)<>FInfo.WorkRoot) or
      (Q.FieldAsString(4)<>FInfo.Destination) or (Q.FieldAsInt(5)<>FInfo.CollectionID) or
      (Q.FieldAsString(6)<>'pending') then
      raise EReadError.Create('Регистрация переноса изменилась или относится к другой операции.');
  finally Q.Free; end;
end;

procedure TCollectionTransferRegistry.RegisterOperation(const Cancelled:TFunc<Boolean>);
var Lease:IInterface; DB:TSQLiteDatabase;
begin
  Stop(Cancelled); DB:=OpenDatabase(True,Lease);
  try
    DB.ExecSQL('BEGIN IMMEDIATE');
    try
      DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+OperationTable+'(Operation TEXT PRIMARY KEY,Directory TEXT NOT NULL,'+
        'ReviewSHA256 TEXT NOT NULL,PersonalKey TEXT NOT NULL,WorkRoot TEXT NOT NULL,Destination TEXT NOT NULL,'+
        'CollectionID INTEGER NOT NULL,State TEXT NOT NULL CHECK(State IN (''pending'',''completed''))) WITHOUT ROWID');
      DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+ProofTable+'(Operation TEXT NOT NULL,GroupID INTEGER NOT NULL,'+
        'ProofSHA256 TEXT NOT NULL,PRIMARY KEY(Operation,GroupID)) WITHOUT ROWID');
      DB.ExecSQL('INSERT OR IGNORE INTO '+OperationTable+' VALUES(?,?,?,?,?,?,?,''pending'')',
        [FInfo.Operation,FInfo.Directory,FInfo.ReviewSHA256,FInfo.PersonalKey,FInfo.WorkRoot,FInfo.Destination,FInfo.CollectionID]);
      CheckRegistration(DB); Point('registry-before-operation-commit',FInfo.Operation,0); Stop(Cancelled);
      DB.ExecSQL('COMMIT'); Point('registry-after-operation-commit',FInfo.Operation,0);
    except if DB.InTransaction then DB.Rollback; raise; end;
  finally DB.Free; Lease:=nil; end;
end;

function TCollectionTransferRegistry.RememberPreparedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>):string;
var Lease:IInterface; DB:TSQLiteDatabase;
begin
  Stop(Cancelled); DB:=OpenDatabase(False,Lease);
  try CheckRegistration(DB); finally DB.Free; Lease:=nil; end;
  Result:=FJournal.SealPreparedGroup(Prepared,Cancelled);
  DB:=OpenDatabase(True,Lease);
  try
    DB.ExecSQL('BEGIN IMMEDIATE');
    try
      StoreGroupProof(DB,Prepared.ID,Result,Cancelled);
      DB.ExecSQL('COMMIT'); Point('registry-after-group-commit',FInfo.Operation,Prepared.ID);
    except if DB.InTransaction then DB.Rollback; raise; end;
  finally DB.Free; Lease:=nil; end;
end;

procedure TCollectionTransferRegistry.StoreGroupProof(DB:TSQLiteDatabase; GroupID:Int64;
  const SHA:string; const Cancelled:TFunc<Boolean>);
begin
  if not DB.InTransaction then raise EArgumentException.Create('Подтверждение группы сохраняется только в транзакции.');
  CheckRegistration(DB);
  var Q:=DB.NewQuery('SELECT ProofSHA256 FROM '+ProofTable+' WHERE Operation=? AND GroupID=?',[FInfo.Operation,GroupID]);
  try
    Q.Open;
    if not Q.Eof and (Q.FieldAsString(0)<>SHA) then raise EReadError.Create('Независимое подтверждение группы изменилось.');
  finally Q.Free; end;
  DB.ExecSQL('INSERT OR IGNORE INTO '+ProofTable+' VALUES(?,?,?)',[FInfo.Operation,GroupID,SHA]);
  Point('registry-before-group-commit',FInfo.Operation,GroupID); Stop(Cancelled);
end;

procedure TCollectionTransferRegistry.PublishPreparedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>);
var Lease:IInterface; DB:TSQLiteDatabase;
begin
  Stop(Cancelled); DB:=OpenDatabase(False,Lease);
  try CheckRegistration(DB); finally DB.Free; Lease:=nil; end;
  var SHA:=FJournal.SealPreparedGroup(Prepared,Cancelled);
  FJournal.PublishGroupLocations(Prepared,Cancelled,
    procedure(Personal:TSQLiteDatabase)
    begin StoreGroupProof(Personal,Prepared.ID,SHA,Cancelled); end);
  Point('registry-after-group-commit',FInfo.Operation,Prepared.ID);
end;

function TCollectionTransferRegistry.RecoverGroup(GroupID:Int64;
  const Cancelled:TFunc<Boolean>):TPreparedTransferGroup;
var Lease:IInterface; DB:TSQLiteDatabase; SHA:string;
begin
  Stop(Cancelled); DB:=OpenDatabase(False,Lease);
  try
    CheckRegistration(DB);
    if not HasTable(DB,ProofTable) then raise EReadError.Create('Нет независимых подтверждений групп переноса.');
    SHA:=DB.QuerySingleString('SELECT ProofSHA256 FROM '+ProofTable+' WHERE Operation=? AND GroupID=?',[FInfo.Operation,GroupID]);
    if SHA='' then raise EReadError.Create('Группа ещё не зарегистрирована для восстановления без исходников.');
  finally DB.Free; Lease:=nil; end;
  Result:=FJournal.RecoverPreparedGroup(GroupID,SHA,Cancelled);
end;

function ResumeRegisteredCollectionTransfer(const PersonalFile,Operation:string):TCollectionTransferJournal;
begin
  Result:=nil;
  for var Info in RegisteredCollectionTransfers(PersonalFile) do
    if Info.Operation=Operation then
    begin
      Result:=TCollectionTransferJournal.Resume(Info.WorkRoot,Info.Destination,Info.Directory,Info.ReviewSHA256);
      try
        if Result.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=''personal_key''')<>Info.PersonalKey then
          raise EReadError.Create('Журнал относится к другой личной базе.');
        var Registry:=TCollectionTransferRegistry.Create(Result);
        try
          var Lease:IInterface; var DB:=Registry.OpenDatabase(False,Lease);
          try Registry.CheckRegistration(DB); finally DB.Free; Lease:=nil; end;
        finally Registry.Free; end;
      except Result.Free; Result:=nil; raise; end;
      Exit;
    end;
  raise EReadError.Create('Незавершённый перенос не найден в личной базе.');
end;

end.
