unit unit_CollectionTransferCompletion;

interface

uses System.SysUtils, System.Generics.Collections, SQLiteWrap, unit_CollectionTransferJournal;

type
  // Used only inside the final roots session, with every participant locked.
  TTransferCompletionWriter=class
  private
    FJournal:TCollectionTransferJournal;
    FReady,FCancelled:TFunc<Boolean>;
    FSeen:TDictionary<Int64,Boolean>;
    FResult:TTransferCompletionResult;
    FOperation:string;
    procedure CheckReady;
  public
    constructor Create(Journal:TCollectionTransferJournal; const ApplicationReady,Cancelled:TFunc<Boolean>);
    destructor Destroy; override;
    procedure CheckGroup(Personal:TSQLiteDatabase; Prepared:TPreparedTransferGroup; const ProofSHA:string);
    procedure Save(Personal:TSQLiteDatabase; const RootSHA:string);
    procedure BeforeCommit;
    property Outcome:TTransferCompletionResult read FResult;
  end;

function ReadTransferCompletion(Journal:TCollectionTransferJournal; out Outcome:TTransferCompletionResult):Boolean;

implementation

uses System.Classes, System.JSON, System.Hash, System.DateUtils,
  unit_BookCompressionReceipt, unit_ZipMemberDeletion;

const CompletionTable='HomeLibreTransferCompletion';

function Meta(Journal:TCollectionTransferJournal; const Name:string):string;
begin Result:=Journal.Review.QuerySingleString('SELECT Value FROM Context WHERE Name=?',[Name]); end;

function HasTable(DB:TSQLiteDatabase; const Name:string):Boolean;
begin Result:=DB.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=?',[Name])=1; end;

function ReadTransferCompletion(Journal:TCollectionTransferJournal; out Outcome:TTransferCompletionResult):Boolean;
begin
  Result:=False; Outcome:=Default(TTransferCompletionResult);
  var PersonalFile:=Meta(Journal,'personal'); var PersonalKey:=Meta(Journal,'personal_key');
  var Lease:=AcquireCompressionDatabaseLease(PersonalFile,PersonalKey);
  var DB:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(PersonalFile),Journal.Directory);
  try
    if not HasTable(DB,'HomeLibreTransferOperations') then Exit;
    var Q:=DB.NewQuery('SELECT Directory,ReviewSHA256,PersonalKey,WorkRoot,Destination,CollectionID,State '+
      'FROM HomeLibreTransferOperations WHERE Operation=?',[Meta(Journal,'directory')]);
    try
      Q.Open; if Q.Eof then Exit;
      if (Q.FieldAsString(0)<>Journal.Directory) or (Q.FieldAsString(1)<>Journal.ReviewSHA256) or
        (Q.FieldAsString(2)<>PersonalKey) or (Q.FieldAsString(3)<>Meta(Journal,'work_root')) or
        (Q.FieldAsString(4)<>Meta(Journal,'destination')) or
        (Q.FieldAsInt(5)<>StrToInt(Meta(Journal,'collection'))) then
        raise EReadError.Create('Итог относится к другой операции переноса.');
      var State:=Q.FieldAsString(6);
      if State='pending' then Exit;
      if State<>'completed' then raise EReadError.Create('Неизвестное состояние переноса.');
    finally Q.Free; end;
    if not HasTable(DB,CompletionTable) then raise EReadError.Create('Потеряно подтверждение завершения переноса.');
    Q:=DB.NewQuery('SELECT ReviewSHA256,RootSHA256,SummaryJSON,SummarySHA256 FROM '+CompletionTable+' WHERE Operation=?',
      [Meta(Journal,'directory')]);
    try
      Q.Open;
      if Q.Eof or (Q.FieldAsString(0)<>Journal.ReviewSHA256) or (Length(Q.FieldAsString(1))<>64) or
        (Length(Q.FieldAsString(2))>65536) or (THashSHA2.GetHashString(Q.FieldAsString(2))<>Q.FieldAsString(3)) then
        raise EReadError.Create('Итог переноса изменён или не подтверждён.');
      var Value:=TJSONObject.ParseJSONValue(Q.FieldAsString(2)) as TJSONObject;
      try
        if (Value=nil) or (Value.GetValue<string>('kind')<>'HomeLibre transfer completion v1') or
          (Value.GetValue<string>('operation')<>Meta(Journal,'directory')) or
          (Value.GetValue<string>('review')<>Journal.ReviewSHA256) or
          (Value.GetValue<string>('personal_key')<>PersonalKey) or
          (Value.GetValue<string>('roots')<>Q.FieldAsString(1)) then
          raise EReadError.Create('Неверная привязка итога переноса.');
        Outcome.Files:=Value.GetValue<Int64>('files'); Outcome.Groups:=Value.GetValue<Int64>('groups');
        Outcome.Bytes:=Value.GetValue<Int64>('bytes'); Outcome.Removed:=Value.GetValue<Int64>('removed');
        Outcome.Missing:=Value.GetValue<Int64>('missing'); Outcome.Retained:=Value.GetValue<Int64>('retained');
        Outcome.CompletedAt:=Value.GetValue<string>('completed_at');
        var Stamp:TDateTime;
        if (Outcome.Files<>Journal.FileCount) or (Outcome.Groups<>Journal.GroupCount) or
          (Outcome.Bytes<>Journal.Review.QuerySingleInt('SELECT coalesce(sum(Bytes),0) FROM Files')) or
          (Outcome.Removed<0) or (Outcome.Missing<0) or (Outcome.Retained<0) or
          (Outcome.Removed>Outcome.Files) or (Outcome.Missing>Outcome.Files) or (Outcome.Retained>Outcome.Files) or
          (Outcome.Removed+Outcome.Missing+Outcome.Retained<>Outcome.Files) or
          not TryISO8601ToDate(Outcome.CompletedAt,Stamp,True) then
          raise EReadError.Create('Неверные счётчики итога переноса.');
      finally Value.Free; end;
      Result:=True;
    finally Q.Free; end;
  finally DB.Free; Lease:=nil; end;
end;

constructor TTransferCompletionWriter.Create(Journal:TCollectionTransferJournal;
  const ApplicationReady,Cancelled:TFunc<Boolean>);
begin
  inherited Create; FJournal:=Journal; FReady:=ApplicationReady; FCancelled:=Cancelled;
  FSeen:=TDictionary<Int64,Boolean>.Create; FOperation:=Meta(Journal,'directory'); CheckReady;
end;

destructor TTransferCompletionWriter.Destroy;
begin FSeen.Free; inherited; end;

procedure TTransferCompletionWriter.CheckReady;
begin
  if Assigned(FCancelled) and FCancelled() then raise EAbort.Create('Завершение переноса остановлено; журнал сохранён.');
  if not Assigned(FReady) or not FReady() then
    raise EReadError.Create('Открытая коллекция ещё не обновлена или есть незавершённые задания чтения.');
  FJournal.CheckSpace;
end;

procedure TTransferCompletionWriter.CheckGroup(Personal:TSQLiteDatabase;
  Prepared:TPreparedTransferGroup; const ProofSHA:string);
begin
  CheckReady;
  if not Personal.InTransaction then raise EReadError.Create('Нет общей транзакции завершения переноса.');
  var Q:=Personal.NewQuery('SELECT GroupID,ProofSHA256,SourceIdentity,TargetIdentity,Source,Destination,SHA256,StreamsJSON,'+
    'ProtectionBound,State FROM HomeLibreTransferRemovalIntent WHERE Operation=? AND FileID=?');
  var R:=FJournal.Review.NewQuery('SELECT Identity,Bytes FROM Files WHERE ID=? AND GroupID=?');
  try
    for var I:=0 to Prepared.Count-1 do
    begin
      CheckReady; var ID:=Prepared.FileID(I); var Item:=Prepared.CopyAt(I);
      if FSeen.ContainsKey(ID) then raise EReadError.Create('Повтор файла в итоге переноса.');
      Q.Reset; Q.SetParam(0,FOperation); Q.SetParam(1,ID); Q.Open;
      R.Reset; R.SetParam(0,ID); R.SetParam(1,Prepared.ID); R.Open;
      if R.Eof then raise EReadError.Create('Нет файла в неизменяемом плане завершения.');
      var SourceIdentity:=R.FieldAsString(0); var Bytes:=StrToInt64(R.FieldAsString(1)); R.Reset;
      if Q.Eof or (Q.FieldAsInt(0)<>Prepared.ID) or (Q.FieldAsString(1)<>ProofSHA) or
        (Q.FieldAsString(2)<>SourceIdentity) or (Q.FieldAsString(3)<>Item.Identity) or
        (Q.FieldAsString(4)<>Item.Source) or (Q.FieldAsString(5)<>Item.Destination) or
        (Q.FieldAsString(6)<>Item.SHA256) or (Q.FieldAsString(7)<>Item.StreamsJSON) then
        raise EReadError.Create('Освобождение исходника не совпало с подтверждённой копией.');
      var State:=Q.FieldAsString(9);
      if State='removed' then
      begin
        if Q.FieldAsInt(8)<>1 then raise EReadError.Create('Не подтверждена защита удалённого исходника.');
        Inc(FResult.Removed);
      end
      else if State='missing' then Inc(FResult.Missing)
      else if State='retained' then Inc(FResult.Retained)
      else raise EReadError.Create('Освобождение исходных файлов ещё не завершено.');
      FSeen.Add(ID,True); Inc(FResult.Files); Inc(FResult.Bytes,Bytes); Q.Reset;
    end;
    Inc(FResult.Groups);
  finally R.Free; Q.Free; end;
end;

procedure TTransferCompletionWriter.BeforeCommit;
begin CheckReady; end;

procedure TTransferCompletionWriter.Save(Personal:TSQLiteDatabase; const RootSHA:string);
begin
  CheckReady;
  if not Personal.InTransaction or (Length(RootSHA)<>64) or (FResult.Files<>FJournal.FileCount) or
    (FResult.Groups<>FJournal.GroupCount) or (FResult.Removed+FResult.Missing+FResult.Retained<>FResult.Files) or
    (Personal.QuerySingleInt('SELECT count(*) FROM HomeLibreTransferRemovalIntent WHERE Operation=?',[FOperation])<>FResult.Files) then
    raise EReadError.Create('Не все файлы вошли в подтверждённый итог переноса.');
  FResult.CompletedAt:=DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True);
  var Value:=TJSONObject.Create;
  try
    Value.AddPair('kind','HomeLibre transfer completion v1'); Value.AddPair('operation',FOperation);
    Value.AddPair('review',FJournal.ReviewSHA256); Value.AddPair('personal_key',Meta(FJournal,'personal_key'));
    Value.AddPair('roots',RootSHA); Value.AddPair('completed_at',FResult.CompletedAt);
    Value.AddPair('files',TJSONNumber.Create(FResult.Files)); Value.AddPair('groups',TJSONNumber.Create(FResult.Groups));
    Value.AddPair('bytes',TJSONNumber.Create(FResult.Bytes)); Value.AddPair('removed',TJSONNumber.Create(FResult.Removed));
    Value.AddPair('missing',TJSONNumber.Create(FResult.Missing)); Value.AddPair('retained',TJSONNumber.Create(FResult.Retained));
    var Raw:=Value.ToJSON;
    Personal.ExecSQL('CREATE TABLE IF NOT EXISTS '+CompletionTable+'(Operation TEXT PRIMARY KEY,ReviewSHA256 TEXT NOT NULL,'+
      'RootSHA256 TEXT NOT NULL,SummaryJSON TEXT NOT NULL,SummarySHA256 TEXT NOT NULL) WITHOUT ROWID');
    Personal.ExecSQL('INSERT INTO '+CompletionTable+' VALUES(?,?,?,?,?)',
      [FOperation,FJournal.ReviewSHA256,RootSHA,Raw,THashSHA2.GetHashString(Raw)]);
    Personal.ExecSQL('UPDATE HomeLibreTransferOperations SET State=''completed'' WHERE Operation=? AND ReviewSHA256=? AND State=''pending''',
      [FOperation,FJournal.ReviewSHA256]);
    if Personal.LastChangedRows<>1 then raise EWriteError.Create('Не сохранено завершение переноса.');
    CheckReady;
  finally Value.Free; end;
end;

end.
