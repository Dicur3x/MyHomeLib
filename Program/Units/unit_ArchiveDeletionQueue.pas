unit unit_ArchiveDeletionQueue;

interface

uses System.Classes, System.SysUtils;

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
    Archive, CatalogueBinding, WorkDirectory, JournalDirectory, Error: string;
    FilesVerified, Cancelled: Boolean;
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
    FResults: TArray<TArchiveDeletionResult>;
    FLock: TObject;
    FRoot: string;
    FStatus: TArchiveDeletionStatus;
    FStop: Integer;
    FPublished: Integer;
    procedure Report(const Stage: string; Done, Total: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(const Tasks: TArray<TArchiveDeletionTask>; const JournalParent: string);
    destructor Destroy; override;
    procedure StopAfterCurrentArchive;
    function Status: TArchiveDeletionStatus;
    function Results: TArray<TArchiveDeletionResult>;
    // Revalidate the finished archive, then discard only this task's receipt.
    // Call only AFTER the matching catalogue transaction is durable.
    class procedure Acknowledge(const Result: TArchiveDeletionResult); static;
    property WorkDirectory: string read FRoot;
  end;

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.SyncObjs,
  System.Generics.Collections, unit_ZipMemberDeletion, unit_AtomicIniFile;

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
    try SaveStreamAtomically(Stream,DeletionNativePath(TPath.Combine(Directory,'binding.json')));
    finally Stream.Free; end;
  finally ObjectValue.Free; end;
end;

constructor TArchiveDeletionQueue.Create(const Tasks: TArray<TArchiveDeletionTask>;
  const JournalParent: string);
var Seen: TDictionary<string,Byte>;
begin
  inherited Create(True); FreeOnTerminate:=False;
  FLock:=TObject.Create;
  if (Length(Tasks)=0) or (Length(Tasks)>10000) then
    raise EArgumentException.Create('Не выбраны архивы для удаления книг.');
  Seen:=TDictionary<string,Byte>.Create;
  try
    SetLength(FTasks,Length(Tasks));
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

destructor TArchiveDeletionQueue.Destroy;
begin
  StopAfterCurrentArchive;
  // TThread.Destroy resumes a never-started thread before joining it. A
  // stopped suspended queue must therefore perform no filesystem mutation.
  inherited;
  // TThread may skip Execute entirely when destroyed before Start. Remove
  // that empty queue root too, without touching any receipt or source file.
  if FRoot<>'' then RemoveDirectory(PChar(DeletionNativePath(FRoot)));
  FLock.Free;
end;

procedure TArchiveDeletionQueue.StopAfterCurrentArchive;
begin TInterlocked.Exchange(FStop,1); end;

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
var Deletion: TZipMemberDeletion; Item: TArchiveDeletionResult;
begin
  try
    for var I:=0 to High(FTasks) do
    begin
      if TInterlocked.CompareExchange(FStop,0,0)<>0 then Break;
      Item:=Default(TArchiveDeletionResult); Item.Index:=I;
      Item.Archive:=FTasks[I].Archive; Item.CatalogueBinding:=FTasks[I].CatalogueBinding;
      Item.WorkDirectory:=TPath.Combine(FRoot,Format('archive-%.6d',[I]));
      Deletion:=nil;
      TMonitor.Enter(FLock);
      try
        FStatus.ArchiveIndex:=I+1; FStatus.Archive:=Item.Archive;
        FStatus.Stage:='Проверка архива'; FStatus.Done:=0; FStatus.Total:=0;
      finally TMonitor.Exit(FLock); end;
      try
        if not CreateDirectory(PChar(DeletionNativePath(Item.WorkDirectory)),nil) then RaiseLastOSError;
        SaveBinding(FTasks[I],Item.WorkDirectory);
        Deletion:=TZipMemberDeletion.Prepare(Item.Archive,FTasks[I].Members,
          procedure(const Stage: string; Done,Total: Int64) begin Report(Stage,Done,Total); end,
          function: Boolean begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end,
          FTasks[I].SourceIdentity);
        // Cancellation is safe before the first write. After that, finish the
        // current archive; never abandon it with half-shifted compressed data.
        if TInterlocked.CompareExchange(FStop,0,0)<>0 then Abort;
        Deletion.Execute(Item.WorkDirectory,
          procedure(const Stage: string; Done,Total: Int64) begin Report(Stage,Done,Total); end);
        Item.FilesVerified:=Deletion.Finished;
      except
        on E:EAbort do begin Item.Cancelled:=True; Item.Error:='Удаление остановлено до изменения архива.'; end;
        on E:Exception do Item.Error:=E.Message;
      end;
      if Assigned(Deletion) then Item.JournalDirectory:=Deletion.JobDirectory;
      Deletion.Free;
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
      if not Item.FilesVerified then Break;
    end;
  finally
    if FRoot<>'' then RemoveDirectory(PChar(DeletionNativePath(FRoot))); // empty owned queue only
    TMonitor.Enter(FLock);
    try FStatus.Archive:=''; FStatus.Finished:=True;
    finally TMonitor.Exit(FLock); end;
  end;
end;

class procedure TArchiveDeletionQueue.Acknowledge(const Result: TArchiveDeletionResult);
var Deletion: TZipMemberDeletion;
begin
  if not Result.FilesVerified or (Result.JournalDirectory='') then
    raise EInvalidOperation.Create('Удаление файлов ещё не подтверждено.');
  if not SameFileName(ExtractFileDir(Result.JournalDirectory),Result.WorkDirectory) then
    raise EInvalidOperation.Create('Журнал удаления находится в другой папке.');
  Deletion:=TZipMemberDeletion.Recover(Result.Archive,Result.JournalDirectory);
  try
    if not Deletion.Finished then raise EInvalidOperation.Create('Удаление архива не завершено.');
    Deletion.Acknowledge;
  finally Deletion.Free; end;
  var Binding:=DeletionNativePath(TPath.Combine(Result.WorkDirectory,'binding.json'));
  if not System.SysUtils.DeleteFile(Binding) then RaiseLastOSError;
  if not RemoveDirectory(PChar(DeletionNativePath(Result.WorkDirectory))) then RaiseLastOSError;
  // The last acknowledgement removes only an empty operation directory.
  RemoveDirectory(PChar(DeletionNativePath(ExtractFileDir(Result.WorkDirectory))));
end;

end.
