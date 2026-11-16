unit unit_CollectionTransferRegistry;

interface

uses System.SysUtils, SQLiteWrap, unit_CollectionTransferJournal;

type
  TTransferRemovalResult=record Removed,Missing,Retained,Pending:Int64; end;

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
    function GroupProofSHA(GroupID:Int64):string;
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
    // Checks the independent proof and saved locations; does not authorize unlink.
    function VerifyPublishedGroup(Prepared:TPreparedTransferGroup;
      const Cancelled:TFunc<Boolean> = nil):Int64;
    function RemovePublishedGroup(Prepared:TPreparedTransferGroup; const Cancelled:TFunc<Boolean> = nil;
      const Progress:TTransferJournalProgress = nil):TTransferRemovalResult;
  end;

function RegisteredCollectionTransfers(const PersonalFile:string):TArray<TRegisteredCollectionTransfer>;
function ResumeRegisteredCollectionTransfer(const PersonalFile,Operation:string):TCollectionTransferJournal;

{$IFDEF MHL_TRANSFER_TEST}
var TransferRegistryTestPoint:TProc<string,string,Int64>;
{$ENDIF}

implementation

uses System.Classes, System.IOUtils, System.Generics.Collections, Winapi.Windows,
  unit_BookCompressionReceipt, unit_ZipMemberDeletion, unit_CollectionTransferCopy, unit_CollectionTransferReferenceFence;

const OperationTable='HomeLibreTransferOperations'; ProofTable='HomeLibreTransferGroupProofs';
  RemovalTable='HomeLibreTransferRemovalIntent';

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

function TCollectionTransferRegistry.GroupProofSHA(GroupID:Int64):string;
var Lease:IInterface; DB:TSQLiteDatabase;
begin
  DB:=OpenDatabase(False,Lease);
  try
    CheckRegistration(DB);
    if not HasTable(DB,ProofTable) then raise EReadError.Create('Нет независимых подтверждений групп переноса.');
    Result:=DB.QuerySingleString('SELECT ProofSHA256 FROM '+ProofTable+' WHERE Operation=? AND GroupID=?',[FInfo.Operation,GroupID]);
    if Result='' then raise EReadError.Create('Группа ещё не зарегистрирована для восстановления без исходников.');
  finally DB.Free; Lease:=nil; end;
end;

function TCollectionTransferRegistry.RecoverGroup(GroupID:Int64;
  const Cancelled:TFunc<Boolean>):TPreparedTransferGroup;
begin
  Stop(Cancelled); Result:=FJournal.RecoverPreparedGroup(GroupID,GroupProofSHA(GroupID),Cancelled);
end;

function TCollectionTransferRegistry.VerifyPublishedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>):Int64;
begin
  Stop(Cancelled);
  if Prepared=nil then raise EArgumentException.Create('Не указана проверенная группа.');
  FJournal.CheckPreparedGroupProof(Prepared,GroupProofSHA(Prepared.ID),Cancelled);
  Result:=FJournal.VerifyPublishedGroup(Prepared,Cancelled);
end;

function TCollectionTransferRegistry.RemovePublishedGroup(Prepared:TPreparedTransferGroup;
  const Cancelled:TFunc<Boolean>; const Progress:TTransferJournalProgress):TTransferRemovalResult;
type
  TIntent=record
    SourceIdentity,State,Reason:string;
    Attributes:DWORD;
    Bound:Boolean;
  end;
  TLoadIntent=reference to function(DB:TSQLiteDatabase; Index:Integer; out Entry:TIntent):Boolean;
var Guards:TObjectDictionary<Int64,TTransferOriginalRemoval>;
    Entries:TDictionary<Int64,TIntent>; Kept:TDictionary<Int64,Boolean>;
    SHA:string; ProofLease:TStream; Outcome:TTransferRemovalResult;
    Retain:TProc<Int64,string>; AddRetained:TProc<TArray<Int64>>;
    LoadIntent:TLoadIntent; CheckRegistry:TProc<TSQLiteDatabase>;

begin
  Retain:=procedure(ID:Int64; Reason:string)
  begin
    Kept.AddOrSetValue(ID,True);
    var Entry:=Entries[ID]; Entry.Reason:=Reason; Entries[ID]:=Entry;
  end;

  AddRetained:=procedure(Seeds:TArray<Int64>)
  begin
    for var ID in Seeds do Kept.AddOrSetValue(ID,True);
    for var ID in ExpandTransferRetention(FJournal.Review,Prepared.ID,Kept.Keys.ToArray) do Kept.AddOrSetValue(ID,True);
  end;

  LoadIntent:=function(DB:TSQLiteDatabase; Index:Integer; out Entry:TIntent):Boolean
  begin
    var ID:=Prepared.FileID(Index); var Item:=Prepared.CopyAt(Index);
    Entry:=Default(TIntent);
    Entry.SourceIdentity:=FJournal.Review.QuerySingleString('SELECT Identity FROM Files WHERE ID=? AND GroupID=?',[ID,Prepared.ID]);
    if Length(Entry.SourceIdentity)<>59 then raise EReadError.Create('Нет исходной привязки файла для освобождения.');
    var Q:=DB.NewQuery('SELECT GroupID,ProofSHA256,SourceIdentity,TargetIdentity,Source,Destination,SHA256,StreamsJSON,'+
      'OriginalAttributes,ProtectionBound,State,Reason FROM '+RemovalTable+' WHERE Operation=? AND FileID=?',[FInfo.Operation,ID]);
    try
      Q.Open; Result:=not Q.Eof; if not Result then Exit;
      if (Q.FieldAsInt(0)<>Prepared.ID) or (Q.FieldAsString(1)<>SHA) or (Q.FieldAsString(2)<>Entry.SourceIdentity) or
        (Q.FieldAsString(3)<>Item.Identity) or (Q.FieldAsString(4)<>Item.Source) or (Q.FieldAsString(5)<>Item.Destination) or
        (Q.FieldAsString(6)<>Item.SHA256) or (Q.FieldAsString(7)<>Item.StreamsJSON) or
        not (Q.FieldAsInt(9) in [0,1]) then
        raise EReadError.Create('Намерение удаления изменилось или относится к другому файлу. Исходник сохранён.');
      Entry.Attributes:=DWORD(Q.FieldAsInt(8)); Entry.Bound:=Q.FieldAsInt(9)=1;
      Entry.State:=Q.FieldAsString(10); Entry.Reason:=Q.FieldAsString(11);
      if (Entry.State<>'intent') and (Entry.State<>'removed') and (Entry.State<>'missing') and
        (Entry.State<>'retained') and (Entry.State<>'pending') then raise EReadError.Create('Неизвестное состояние освобождения исходника.');
    finally Q.Free; end;
  end;

  CheckRegistry:=procedure(DB:TSQLiteDatabase)
  begin
    Stop(Cancelled); CheckRegistration(DB);
    if DB.QuerySingleString('SELECT ProofSHA256 FROM '+ProofTable+' WHERE Operation=? AND GroupID=?',
      [FInfo.Operation,Prepared.ID])<>SHA then raise EReadError.Create('Независимое подтверждение группы изменилось.');
    FJournal.CheckPreparedGroupProof(Prepared,SHA,Cancelled);
  end;

  Stop(Cancelled);
  if Prepared=nil then raise EArgumentException.Create('Не указана проверенная группа освобождения.');
  SHA:=GroupProofSHA(Prepared.ID); FJournal.CheckPreparedGroupProof(Prepared,SHA,Cancelled);
  ProofLease:=FJournal.HoldPreparedGroupProof(Prepared.ID,SHA);
  Guards:=TObjectDictionary<Int64,TTransferOriginalRemoval>.Create([doOwnsValues]);
  Entries:=TDictionary<Int64,TIntent>.Create; Kept:=TDictionary<Int64,Boolean>.Create;
  Outcome:=Default(TTransferRemovalResult);
  try
    FJournal.RemovePublishedGroup(Prepared,Cancelled,CheckRegistry,
      procedure(DB:TSQLiteDatabase; Retained:TArray<Int64>)
      begin
        DB.ExecSQL('CREATE TABLE IF NOT EXISTS '+RemovalTable+'(Operation TEXT NOT NULL,GroupID INTEGER NOT NULL,FileID INTEGER NOT NULL,'+
          'ProofSHA256 TEXT NOT NULL,SourceIdentity TEXT NOT NULL,TargetIdentity TEXT NOT NULL,Source TEXT NOT NULL,Destination TEXT NOT NULL,'+
          'SHA256 TEXT NOT NULL,StreamsJSON TEXT NOT NULL,OriginalAttributes INTEGER NOT NULL,ProtectionBound INTEGER NOT NULL,'+
          'State TEXT NOT NULL,Reason TEXT NOT NULL,PRIMARY KEY(Operation,FileID)) WITHOUT ROWID');
        AddRetained(Retained);
        for var I:=0 to Prepared.Count-1 do
        begin
          Stop(Cancelled); var ID:=Prepared.FileID(I); var Item:=Prepared.CopyAt(I); var Entry:TIntent;
          LoadIntent(DB,I,Entry); Entries.Add(ID,Entry);
          if (Entry.State='removed') or (Entry.State='missing') or Kept.ContainsKey(ID) then Continue;
          try
            var Path:=Item.Source;
            var Guard:=TTransferOriginalRemoval.Create(Item,Entry.SourceIdentity,Cancelled,
              procedure(const Stage:string; Done,Total:Int64)
              begin if Assigned(Progress) then Progress(Stage,Path,Done,Total); end);
            Guards.Add(ID,Guard);
            if Entry.Bound then Guard.RestoreOriginalAttributes(Entry.Attributes)
            else if not Guard.Missing then
            begin Entry.Attributes:=Guard.Attributes; Entry.Bound:=True; Entries[ID]:=Entry; end;
          except
            on E:EAbort do raise;
            on E:EOSError do Retain(ID,E.Message);
            on E:EReadError do Retain(ID,E.Message);
          end;
        end;
        AddRetained(nil);
        for var I:=0 to Prepared.Count-1 do
        begin
          Stop(Cancelled); var ID:=Prepared.FileID(I); var Item:=Prepared.CopyAt(I); var Entry:=Entries[ID];
          DB.ExecSQL('INSERT OR IGNORE INTO '+RemovalTable+' VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            [FInfo.Operation,Prepared.ID,ID,SHA,Entry.SourceIdentity,Item.Identity,Item.Source,Item.Destination,
             Item.SHA256,Item.StreamsJSON,Int64(Entry.Attributes),Ord(Entry.Bound),'intent',Entry.Reason]);
          if (Entry.State<>'removed') and (Entry.State<>'missing') then
            DB.ExecSQL('UPDATE '+RemovalTable+' SET OriginalAttributes=?,ProtectionBound=?,Reason=? WHERE Operation=? AND FileID=?',
              [Int64(Entry.Attributes),Ord(Entry.Bound),Entry.Reason,FInfo.Operation,ID]);
          LoadIntent(DB,I,Entry); Entries[ID]:=Entry;
        end;
      end,
      procedure(DB:TSQLiteDatabase; Retained:TArray<Int64>)
      begin
        AddRetained(Retained);
        // Verify the whole dependency group before unlinking its first file.
        for var I:=0 to Prepared.Count-1 do
        begin
          Stop(Cancelled); var ID:=Prepared.FileID(I); var Entry:TIntent;
          if not LoadIntent(DB,I,Entry) then raise EReadError.Create('Нет независимо сохранённого намерения удаления.');
          var Before:=Entries[ID];
          if (Entry.State<>Before.State) or (Entry.Attributes<>Before.Attributes) or (Entry.Bound<>Before.Bound) then
            raise EReadError.Create('Намерение удаления изменилось после сохранения.');
          if (Entry.State='removed') or (Entry.State='missing') or Kept.ContainsKey(ID) then Continue;
          var Guard:TTransferOriginalRemoval;
          if not Guards.TryGetValue(ID,Guard) then raise EReadError.Create('Нет удерживаемого исходника для освобождения.');
          try Guard.ProtectAndVerify;
          except
            on E:EAbort do raise;
            on E:EOSError do Retain(ID,E.Message);
            on E:EReadError do Retain(ID,E.Message);
          end;
        end;
        AddRetained(nil);
        for var I:=0 to Prepared.Count-1 do
        begin
          Stop(Cancelled); var ID:=Prepared.FileID(I); var Entry:=Entries[ID]; var State,Reason:string;
          if Entry.State='removed' then begin Inc(Outcome.Removed); Continue; end;
          if Entry.State='missing' then begin Inc(Outcome.Missing); Continue; end;
          Reason:=Entry.Reason;
          if Kept.ContainsKey(ID) then
          begin
            State:='retained'; if Reason='' then Reason:='Исходник нужен другой записи, сохранён вместе с зависимыми картинками.';
            Inc(Outcome.Retained);
          end
          else if Guards[ID].Missing then begin State:='missing'; Reason:=''; Inc(Outcome.Missing); end
          else
          begin
            if Guards[ID].Unlink(procedure begin CheckRegistry(DB); end) then
            begin State:='removed'; Reason:=''; Inc(Outcome.Removed); end
            else begin State:='pending'; Reason:='Освобождение завершится после закрытия внешнего читателя.'; Inc(Outcome.Pending); end;
          end;
          DB.ExecSQL('UPDATE '+RemovalTable+' SET State=?,Reason=? WHERE Operation=? AND FileID=?',[State,Reason,FInfo.Operation,ID]);
        end;
      end);
    Result:=Outcome;
  finally
    Kept.Free; Entries.Free; Guards.Free; ProofLease.Free;
    Retain:=nil; AddRetained:=nil; LoadIntent:=nil; CheckRegistry:=nil;
  end;
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
