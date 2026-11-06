unit unit_ArchiveDeletionQueue;

interface

uses System.Classes, System.SysUtils, System.SyncObjs;

type
  TArchiveDeletionTask = record
    Archive: string;
    Members: TArray<string>;
    SourceIdentity: string;
    // Captured catalogue identity. Only the owning UI thread may interpret or
    // commit it; the filesystem worker never touches a database connection.
    CatalogueBinding: string;
  end;

  TArchiveDeletionResult = record
    Index: Integer;
    Archive, CatalogueBinding, WorkDirectory, JournalDirectory, Error, CleanupWarning: string;
    FilesVerified, Cancelled: Boolean;
    WaitsForCatalogue, CatalogueCommitted, Acknowledged: Boolean;
  end;

  TArchiveDeletionStatus = record
    Archive, Stage: string;
    Done, Total: Int64;
    ArchiveIndex, ArchiveCount: Integer;
    Stopping, Finished: Boolean;
  end;

  // A queue owns only filesystem work. Results and their durable receipts
  // remain until the catalogue owner explicitly acknowledges its own commit.
  TArchiveDeletionQueue = class(TThread)
  private
    FTasks: TArray<TArchiveDeletionTask>;
    FRecoveryJobs: TArray<string>;
    FResults: TArray<TArchiveDeletionResult>;
    FLock: TObject;
    FRoot: string;
    FStatus: TArchiveDeletionStatus;
    FStop: Integer;
    FPublished: Integer;
    FWaitForCatalogue: Boolean;
    FOwnerEvent, FResultEvent: TEvent;
    FCommittedIndex, FRejectedIndex, FAbandonOwner: Integer;
    function WaitForCatalogue(var Item: TArchiveDeletionResult): Boolean;
    procedure Report(const Stage: string; Done, Total: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(const Tasks: TArray<TArchiveDeletionTask>; const JournalParent: string;
      WaitForOwner: Boolean = False);
    constructor Recover(const TaskDirectories: TArray<string>; WaitForOwner: Boolean = False);
    // Reads an existing receipt; its context must match the durable engine
    // plan. This does not finish a pending write or commit catalogue rows.
    class function ReadReceipt(const TaskDirectory: string): TArchiveDeletionResult; static;
    destructor Destroy; override;
    procedure StopAfterCurrentArchive;
    // Production mode keeps the archive exclusively open until its owning UI
    // thread confirms its durable database phase. The worker then cleans up.
    procedure CatalogueCommitted(Index: Integer);
    procedure CatalogueRejected(Index: Integer);
    procedure WaitForResult(Timeout: Cardinal);
    function Status: TArchiveDeletionStatus;
    function Results: TArray<TArchiveDeletionResult>;
    // Revalidate the finished archive, then discard only this task's receipt.
    // Call only AFTER the matching catalogue transaction is durable.
    class procedure Acknowledge(const Result: TArchiveDeletionResult); static;
    property WorkDirectory: string read FRoot;
  end;

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.Hash,
  System.Generics.Collections, unit_ZipMemberDeletion, unit_AtomicIniFile, unit_MHLArchiveBusy;

procedure SaveBinding(const Task: TArchiveDeletionTask; const Directory: string);
var ObjectValue: TJSONObject; Members: TJSONArray; Stream: TStringStream;
begin
  ObjectValue:=TJSONObject.Create;
  try
    ObjectValue.AddPair('schema',TJSONNumber.Create(1));
    ObjectValue.AddPair('archive',Task.Archive);
    ObjectValue.AddPair('sourceIdentity',Task.SourceIdentity);
    ObjectValue.AddPair('catalogue',Task.CatalogueBinding);
    Members:=TJSONArray.Create; ObjectValue.AddPair('members',Members);
    for var Member in Task.Members do Members.Add(Member);
    Stream:=TStringStream.Create(ObjectValue.ToJSON,TEncoding.UTF8);
    try
      // Recovery has the same bound. Refuse before opening the archive if
      // the durable context would be too large to load after a restart.
      if Stream.Size>8*1024*1024 then
        raise EWriteError.Create('Слишком большой список для одного журнала удаления. Выберите меньше книг.');
      SaveStreamAtomically(Stream,DeletionNativePath(TPath.Combine(Directory,'binding.json')));
    finally Stream.Free; end;
  finally ObjectValue.Free; end;
end;

constructor TArchiveDeletionQueue.Create(const Tasks: TArray<TArchiveDeletionTask>;
  const JournalParent: string; WaitForOwner: Boolean);
var Seen: TDictionary<string,Byte>;
begin
  inherited Create(True); FreeOnTerminate:=False;
  FLock:=TObject.Create; FOwnerEvent:=TEvent.Create(nil,False,False,'');
  FResultEvent:=TEvent.Create(nil,False,False,'');
  FWaitForCatalogue:=WaitForOwner; FCommittedIndex:=-1; FRejectedIndex:=-1;
  if (Length(Tasks)=0) or (Length(Tasks)>10000) then
    raise EArgumentException.Create('Не выбраны архивы для удаления книг.');
  Seen:=TDictionary<string,Byte>.Create;
  try
    SetLength(FTasks,Length(Tasks)); SetLength(FRecoveryJobs,Length(Tasks));
    for var I:=0 to High(Tasks) do
    begin
      FTasks[I]:=Tasks[I]; FTasks[I].Archive:=ExpandFileName(Tasks[I].Archive);
      FTasks[I].Members:=Copy(Tasks[I].Members);
      var CurrentIdentity:=ArchiveDeletionSourceIdentity(FTasks[I].Archive);
      if FTasks[I].SourceIdentity='' then
        FTasks[I].SourceIdentity:=CurrentIdentity;
      if (Length(FTasks[I].Members)=0) or
        (Length(TEncoding.UTF8.GetBytes(FTasks[I].CatalogueBinding))>4*1024*1024) then
        raise EArgumentException.Create('Неверный список книг для удаления из архива.');
      // Drive aliases, junctions and hard links can name the same physical
      // archive twice. They must not create two conflicting recovery jobs.
      var Key:=Copy(CurrentIdentity,1,25); // volume serial + 64-bit file index
      if Seen.ContainsKey(Key) then
        raise EArgumentException.Create('Книги из одного архива должны обрабатываться вместе.');
      Seen.Add(Key,0);
    end;
  finally Seen.Free; end;
  ForceDirectories(DeletionNativePath(JournalParent));
  FRoot:=TPath.Combine(ExpandFileName(JournalParent),'archive-delete-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(DeletionNativePath(FRoot)),nil) then RaiseLastOSError;
  FStatus.ArchiveCount:=Length(FTasks);
  SetLength(FResults,Length(FTasks));
end;

function BindingHash(const Directory:string):string;
begin Result:=THashSHA2.GetHashStringFromFile(DeletionNativePath(TPath.Combine(Directory,'binding.json'))); end;

class function TArchiveDeletionQueue.ReadReceipt(const TaskDirectory:string):TArchiveDeletionResult;
var JSON:TJSONValue; ObjectValue:TJSONObject; Stream:TFileStream; Bytes:TBytes;
  Jobs:TArray<string>; Deletion:TZipMemberDeletion;
begin
  Result:=Default(TArchiveDeletionResult);
  Result.WorkDirectory:=ExpandFileName(TaskDirectory);
  var Binding:=DeletionNativePath(TPath.Combine(Result.WorkDirectory,'binding.json'));
  Stream:=TFileStream.Create(Binding,fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size=0) or (Stream.Size>8*1024*1024) then
      raise EReadError.Create('Неверный размер журнала привязки каталога.');
    SetLength(Bytes,Integer(Stream.Size)); Stream.ReadBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
  JSON:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  try
    if not (JSON is TJSONObject) then raise EReadError.Create('Повреждён журнал привязки каталога.');
    ObjectValue:=TJSONObject(JSON);
    if not (ObjectValue.GetValue('schema') is TJSONNumber) or
      (ObjectValue.GetValue('schema').Value<>'1') or
      not (ObjectValue.GetValue('archive') is TJSONString) or
      not (ObjectValue.GetValue('sourceIdentity') is TJSONString) or
      not (ObjectValue.GetValue('catalogue') is TJSONString) or
      not (ObjectValue.GetValue('members') is TJSONArray) then
      raise EReadError.Create('Неподдерживаемый журнал привязки каталога.');
    Result.Archive:=ObjectValue.GetValue('archive').Value;
    Result.CatalogueBinding:=ObjectValue.GetValue('catalogue').Value;
    if (Result.Archive='') or not SameFileName(Result.Archive,ExpandFileName(Result.Archive)) then
      raise EReadError.Create('В журнале удаления отсутствует полный путь архива.');
    Jobs:=TDirectory.GetDirectories(DeletionNativePath(Result.WorkDirectory),'zip-delete-*',TSearchOption.soTopDirectoryOnly);
    if Length(Jobs)<>1 then raise EReadError.Create('Не найден единственный журнал изменения архива.');
    Result.JournalDirectory:=ExcludeTrailingPathDelimiter(Jobs[0]);
    // Keep the public receipt paths in the same conventional spelling as the
    // queue; only actual I/O needs the native long-path prefix.
    if Result.JournalDirectory.StartsWith('\\?\UNC\') then
      Result.JournalDirectory:='\\'+Result.JournalDirectory.Substring(8)
    else if Result.JournalDirectory.StartsWith('\\?\') then
      Result.JournalDirectory:=Result.JournalDirectory.Substring(4);
    var Attributes:=GetFileAttributes(PChar(DeletionNativePath(Result.JournalDirectory)));
    if (Attributes=INVALID_FILE_ATTRIBUTES) or (Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
      raise EReadError.Create('Журнал удаления не должен быть ссылкой на другую папку.');
    Deletion:=TZipMemberDeletion.Recover(Result.Archive,Result.JournalDirectory);
    try
      var State:=THashSHA2.Create; State.Update(Bytes);
      if (Deletion.ContextHash='') or (Deletion.ContextHash<>State.HashAsString) then
        raise EReadError.Create('Привязка каталога не совпадает с журналом удаления архива.');
      // Finished is not FilesVerified: the worker must still check all moved
      // blocks and the final inventory before catalogue changes are allowed.
    finally Deletion.Free; end;
  finally JSON.Free; end;
end;

constructor TArchiveDeletionQueue.Recover(const TaskDirectories:TArray<string>; WaitForOwner:Boolean);
var Seen:TDictionary<string,Byte>; Receipt:TArchiveDeletionResult;
begin
  inherited Create(True); FreeOnTerminate:=False; FLock:=TObject.Create;
  FOwnerEvent:=TEvent.Create(nil,False,False,'');
  FResultEvent:=TEvent.Create(nil,False,False,'');
  FWaitForCatalogue:=WaitForOwner; FCommittedIndex:=-1; FRejectedIndex:=-1;
  if (Length(TaskDirectories)=0) or (Length(TaskDirectories)>10000) then
    raise EArgumentException.Create('Не выбраны журналы для завершения удаления.');
  SetLength(FTasks,Length(TaskDirectories)); SetLength(FRecoveryJobs,Length(TaskDirectories));
  SetLength(FResults,Length(TaskDirectories)); FStatus.ArchiveCount:=Length(TaskDirectories);
  Seen:=TDictionary<string,Byte>.Create;
  try
    for var I:=0 to High(TaskDirectories) do
    begin
      Receipt:=ReadReceipt(TaskDirectories[I]);
      var Key:=Copy(ArchiveDeletionSourceIdentity(Receipt.Archive),1,25);
      if Seen.ContainsKey(Key) then raise EReadError.Create('Для одного архива найдены повторные журналы.');
      Seen.Add(Key,0);
      FTasks[I].Archive:=Receipt.Archive; FTasks[I].CatalogueBinding:=Receipt.CatalogueBinding;
      FRecoveryJobs[I]:=Receipt.JournalDirectory;
    end;
  finally Seen.Free; end;
end;

destructor TArchiveDeletionQueue.Destroy;
begin
  StopAfterCurrentArchive;
  TInterlocked.Exchange(FAbandonOwner,1);
  if Assigned(FOwnerEvent) then FOwnerEvent.SetEvent;
  // TThread.Destroy resumes a never-started thread before joining it. A
  // stopped suspended queue must therefore perform no filesystem mutation.
  inherited;
  // TThread may skip Execute entirely when destroyed before Start. Remove
  // that empty queue root too, without touching any receipt or source file.
  if FRoot<>'' then RemoveDirectory(PChar(DeletionNativePath(FRoot)));
  FResultEvent.Free; FOwnerEvent.Free; FLock.Free;
end;

procedure TArchiveDeletionQueue.StopAfterCurrentArchive;
begin TInterlocked.Exchange(FStop,1); end;

procedure TArchiveDeletionQueue.WaitForResult(Timeout:Cardinal);
begin FResultEvent.WaitFor(Timeout); end;

procedure TArchiveDeletionQueue.CatalogueCommitted(Index:Integer);
begin
  TMonitor.Enter(FLock);
  try
    if not FWaitForCatalogue or (Index<0) or (Index>=FPublished) or
      not FResults[Index].FilesVerified or (FResults[Index].Error<>'') then
      raise EInvalidOperation.Create('Очередь не ожидает подтверждения этой записи.');
    if FResults[Index].CatalogueCommitted or FResults[Index].Acknowledged then Exit;
    TInterlocked.Exchange(FCommittedIndex,Index);
  finally TMonitor.Exit(FLock); end;
  FOwnerEvent.SetEvent;
end;

procedure TArchiveDeletionQueue.CatalogueRejected(Index:Integer);
begin
  TMonitor.Enter(FLock);
  try
    if not FWaitForCatalogue or (Index<0) or (Index>=FPublished) or
      not FResults[Index].FilesVerified then
      raise EInvalidOperation.Create('Нет ожидающей операции с каталогом.');
    if FResults[Index].Acknowledged then Exit;
    TInterlocked.Exchange(FRejectedIndex,Index);
  finally TMonitor.Exit(FLock); end;
  StopAfterCurrentArchive; FOwnerEvent.SetEvent;
end;

function TArchiveDeletionQueue.WaitForCatalogue(var Item:TArchiveDeletionResult):Boolean;
begin
  Result:=False; Report('Обновление записей каталога',0,0);
  repeat
    if TInterlocked.CompareExchange(FRejectedIndex,0,0)=Item.Index then Break;
    if TInterlocked.CompareExchange(FCommittedIndex,0,0)=Item.Index then
    begin Item.CatalogueCommitted:=True; Exit(True); end;
    if TInterlocked.CompareExchange(FAbandonOwner,0,0)<>0 then Break;
    FOwnerEvent.WaitFor(100);
  until False;
  Item.Error:='Файлы обработаны. Журнал сохранён для завершения записей каталога.';
end;

procedure CleanupReceiptDirectories(const Item:TArchiveDeletionResult; RemoveOperationRoot:Boolean=True);
begin
  var Binding:=DeletionNativePath(TPath.Combine(Item.WorkDirectory,'binding.json'));
  if not System.SysUtils.DeleteFile(Binding) then RaiseLastOSError;
  if not RemoveDirectory(PChar(DeletionNativePath(Item.WorkDirectory))) then RaiseLastOSError;
  if RemoveOperationRoot then
    RemoveDirectory(PChar(DeletionNativePath(ExtractFileDir(Item.WorkDirectory))));
end;

procedure TArchiveDeletionQueue.Report(const Stage: string; Done, Total: Int64);
begin
  TMonitor.Enter(FLock);
  try FStatus.Stage:=Stage; FStatus.Done:=Done; FStatus.Total:=Total;
  finally TMonitor.Exit(FLock); end;
end;

function TArchiveDeletionQueue.Status: TArchiveDeletionStatus;
begin
  TMonitor.Enter(FLock);
  try Result:=FStatus; finally TMonitor.Exit(FLock); end;
  Result.Stopping:=TInterlocked.CompareExchange(FStop,0,0)<>0;
end;

function TArchiveDeletionQueue.Results: TArray<TArchiveDeletionResult>;
begin
  TMonitor.Enter(FLock);
  try Result:=Copy(FResults,0,FPublished); finally TMonitor.Exit(FLock); end;
end;

procedure TArchiveDeletionQueue.Execute;
var Deletion: TZipMemberDeletion; Item: TArchiveDeletionResult; Lease:IInterface;
begin
  try
    for var I:=0 to High(FTasks) do
    begin
      if TInterlocked.CompareExchange(FStop,0,0)<>0 then Break;
      Item:=Default(TArchiveDeletionResult); Item.Index:=I; Item.WaitsForCatalogue:=FWaitForCatalogue;
      Item.Archive:=FTasks[I].Archive; Item.CatalogueBinding:=FTasks[I].CatalogueBinding;
      if FRecoveryJobs[I]<>'' then
      begin
        Item.JournalDirectory:=FRecoveryJobs[I];
        Item.WorkDirectory:=ExtractFileDir(Item.JournalDirectory);
      end
      else Item.WorkDirectory:=TPath.Combine(FRoot,Format('archive-%.6d',[I]));
      Deletion:=nil; Lease:=nil;
      TMonitor.Enter(FLock);
      try
        FStatus.ArchiveIndex:=I+1; FStatus.Archive:=Item.Archive;
        FStatus.Stage:='Проверка архива'; FStatus.Done:=0; FStatus.Total:=0;
      finally TMonitor.Exit(FLock); end;
      try
        Lease:=AcquireArchiveChange(Item.Archive);
        if FRecoveryJobs[I]<>'' then
        begin
          var Receipt:=ReadReceipt(Item.WorkDirectory);
          if (Receipt.Archive<>Item.Archive) or
            (Receipt.CatalogueBinding<>Item.CatalogueBinding) or
            not SameFileName(Receipt.JournalDirectory,Item.JournalDirectory) then
            raise EReadError.Create('Журнал удаления изменился после выбора восстановления.');
          Deletion:=TZipMemberDeletion.Recover(Item.Archive,Item.JournalDirectory);
          if Deletion.ContextHash<>BindingHash(Item.WorkDirectory) then
            raise EReadError.Create('Привязка каталога изменилась перед продолжением удаления.');
        end
        else
        begin
          if not CreateDirectory(PChar(DeletionNativePath(Item.WorkDirectory)),nil) then RaiseLastOSError;
          SaveBinding(FTasks[I],Item.WorkDirectory);
          Deletion:=TZipMemberDeletion.Prepare(Item.Archive,FTasks[I].Members,
            procedure(const Stage: string; Done,Total: Int64) begin Report(Stage,Done,Total); end,
            function: Boolean begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end,
            FTasks[I].SourceIdentity);
          Deletion.BindContext(BindingHash(Item.WorkDirectory));
          // Cancellation is safe before the first write. After that, finish the
          // current archive; never abandon it with half-shifted compressed data.
          if TInterlocked.CompareExchange(FStop,0,0)<>0 then Abort;
        end;
        Deletion.Execute(Item.WorkDirectory,
          procedure(const Stage: string; Done,Total: Int64) begin Report(Stage,Done,Total); end);
        Item.FilesVerified:=Deletion.Finished;
      except
        on E:EAbort do begin Item.Cancelled:=True; Item.Error:='Удаление остановлено до изменения архива.'; end;
        on E:Exception do Item.Error:=E.Message;
      end;
      if Assigned(Deletion) then Item.JournalDirectory:=Deletion.JobDirectory;
      if (Item.JournalDirectory='') and DirectoryExists(DeletionNativePath(Item.WorkDirectory)) then
      begin
        // Planning cannot mutate the source. Its small binding is disposable
        // only when no filesystem recovery journal was started.
        var Binding:=DeletionNativePath(TPath.Combine(Item.WorkDirectory,'binding.json'));
        if FileExists(Binding) then System.SysUtils.DeleteFile(Binding);
        if RemoveDirectory(PChar(DeletionNativePath(Item.WorkDirectory))) then Item.WorkDirectory:='';
      end;
      // Even a failed archive with a journal stays for forward recovery. Do
      // not move to another archive after any unexpected filesystem failure.
      TMonitor.Enter(FLock);
      try FResults[FPublished]:=Item; Inc(FPublished);
      finally TMonitor.Exit(FLock); end;
      FResultEvent.SetEvent;
      try
        if Item.FilesVerified and FWaitForCatalogue then
        begin
          try
            if WaitForCatalogue(Item) then
            begin
              Report('Очистка журнала удаления',0,0);
              if Deletion.ContextHash<>BindingHash(Item.WorkDirectory) then
                raise EReadError.Create('Привязка каталога изменена. Журнал удаления сохранён.');
              // Keep the original exclusive source handle throughout the
              // owner phase. Acknowledgement stays off the UI thread and
              // cannot race an external archive update between the phases.
              Deletion.Acknowledge;
              // A live new queue has not created its later task directories
              // yet. Its operation root must survive until the loop finishes.
              CleanupReceiptDirectories(Item,FRoot=''); Item.Acknowledged:=True;
              // Unlink only after the catalogue commit and journal cleanup.
              // If interrupted here, an empty container can remain safely.
              try
                Deletion.RemoveEmptyArchive;
              except
                on E:Exception do
                  Item.CleanupWarning:='Не удалось убрать пустой архив '+Item.Archive+sLineBreak+E.Message;
              end;
            end;
          except on E:Exception do Item.Error:=E.Message; end;
          TMonitor.Enter(FLock);
          try FResults[I]:=Item; finally TMonitor.Exit(FLock); end;
        end;
      finally Deletion.Free; Lease:=nil; end;
      if not Item.FilesVerified or (FWaitForCatalogue and not Item.Acknowledged) then Break;
    end;
  finally
    if FRoot<>'' then RemoveDirectory(PChar(DeletionNativePath(FRoot))); // empty owned queue only
    TMonitor.Enter(FLock);
    try FStatus.Archive:=''; FStatus.Finished:=True;
    finally TMonitor.Exit(FLock); end;
    FResultEvent.SetEvent;
  end;
end;

class procedure TArchiveDeletionQueue.Acknowledge(const Result: TArchiveDeletionResult);
var Deletion: TZipMemberDeletion;
begin
  if Result.WaitsForCatalogue and not Result.CatalogueCommitted then
    raise EInvalidOperation.Create('Сначала завершите записи каталога.');
  if not Result.FilesVerified or (Result.JournalDirectory='') then
    raise EInvalidOperation.Create('Удаление файлов ещё не подтверждено.');
  if not SameFileName(ExtractFileDir(Result.JournalDirectory),Result.WorkDirectory) then
    raise EInvalidOperation.Create('Журнал удаления находится в другой папке.');
  var Stored:=ReadReceipt(Result.WorkDirectory);
  if (Stored.Archive<>Result.Archive) or (Stored.CatalogueBinding<>Result.CatalogueBinding) or
    not SameFileName(Stored.JournalDirectory,Result.JournalDirectory) then
    raise EReadError.Create('Подтверждение не относится к этому журналу удаления.');
  Deletion:=TZipMemberDeletion.Recover(Result.Archive,Result.JournalDirectory);
  try
    if Deletion.ContextHash<>BindingHash(Result.WorkDirectory) then
      raise EReadError.Create('Привязка каталога изменена. Журнал удаления сохранён.');
    if not Deletion.Finished then raise EInvalidOperation.Create('Удаление архива не завершено.');
    Deletion.Execute(Result.WorkDirectory); // reverify moved data after a detached owner phase
    Deletion.Acknowledge;
  finally Deletion.Free; end;
  CleanupReceiptDirectories(Result);
end;

end.
