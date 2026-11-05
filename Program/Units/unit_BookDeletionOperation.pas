unit unit_BookDeletionOperation;

interface

uses System.Classes, System.SysUtils, unit_Interfaces, unit_Globals,
  unit_BookDeletionBinding, unit_ArchiveDeletionQueue;

type
  TBookDeletionOperationStatus = record
    Stage, Archive, Error, RequiredComponent, PendingJournal, CleanupWarning: string;
    Done, Total: Int64;
    ArchiveIndex, ArchiveCount, CompletedBooks: Integer;
    Stopping, Finished, CatalogueChanged: Boolean;
  end;

  // Owns the catalogue connection and drives the existing archive worker.
  // Only snapshots cross to the window; no VCL work runs on either thread.
  TBookDeletionOperation = class(TThread)
  private
    FBinding: TBookDeletionBinding;
    FJournalRoot, FUserFile: string;
    FRecovery: Boolean;
    FLock: TObject;
    FStop: Integer;
    FState: TBookDeletionOperationStatus;
    function Stopping: Boolean;
    procedure Report(const Stage, Archive: string; Index, Count: Integer;
      Done: Int64 = 0; Total: Int64 = 0);
    procedure CompleteBinding(const Binding: TBookDeletionBinding; const User: ISystemData);
    procedure RunQueue(Queue: TArchiveDeletionQueue; const User: ISystemData;
      Offset, Count: Integer);
    procedure RunRemoval(const User: ISystemData);
    procedure RunRecovery(const User: ISystemData);
  protected
    procedure Execute; override;
  public
    constructor Create(const Binding: TBookDeletionBinding; const UserFile, JournalRoot: string);
    constructor Recover(const UserFile, JournalRoot: string);
    destructor Destroy; override;
    procedure RequestStop;
    function Status: TBookDeletionOperationStatus;
  end;

function IsArchiveBookSource(const Book: TBookRecord): Boolean;
function HasArchiveDeletionJournals(const JournalRoot: string): Boolean;

implementation

uses Winapi.Windows, System.IOUtils, System.SyncObjs, System.Generics.Collections,
  unit_SystemDatabase_SQLite, unit_BookDeletionPreparation, unit_ZipMemberDeletion,
  unit_MHLArchiveHelpers, unit_MHLExternalTools, unit_BookDeletionReferences;

function IsArchiveBookSource(const Book: TBookRecord): Boolean;
begin
  // A catalogue-only confirmation never probes the source drive.
  Result:=IsArchiveExt(Book.GetBookFileName(TPath.Combine(Book.CollectionRoot,Book.Folder)));
end;

constructor TBookDeletionOperation.Create(const Binding:TBookDeletionBinding;
  const UserFile,JournalRoot:string);
begin
  inherited Create(True);
  FLock:=TObject.Create; FreeOnTerminate:=False;
  FBinding:=Binding; FUserFile:=UserFile; FJournalRoot:=ExpandFileName(JournalRoot);
  Priority:=tpLower;
end;

constructor TBookDeletionOperation.Recover(const UserFile,JournalRoot:string);
begin
  Create(Default(TBookDeletionBinding),UserFile,JournalRoot);
  FRecovery:=True;
end;

destructor TBookDeletionOperation.Destroy;
begin
  RequestStop;
  inherited;
  FLock.Free;
end;

function TBookDeletionOperation.Stopping:Boolean;
begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end;

procedure TBookDeletionOperation.RequestStop;
begin TInterlocked.Exchange(FStop,1); end;

function TBookDeletionOperation.Status:TBookDeletionOperationStatus;
begin
  TMonitor.Enter(FLock);
  try Result:=FState; finally TMonitor.Exit(FLock); end;
  Result.Stopping:=Stopping;
end;

procedure TBookDeletionOperation.Report(const Stage,Archive:string; Index,Count:Integer;
  Done,Total:Int64);
begin
  TMonitor.Enter(FLock);
  try
    FState.Stage:=Stage; FState.Archive:=Archive;
    FState.ArchiveIndex:=Index; FState.ArchiveCount:=Count;
    FState.Done:=Done; FState.Total:=Total;
  finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.CompleteBinding(const Binding:TBookDeletionBinding;
  const User:ISystemData);
begin
  // Two durable stores may commit separately. Even on failure the owner must
  // refresh the view and keep the receipt so the remaining phase can replay.
  TMonitor.Enter(FLock);
  try FState.CatalogueChanged:=True; finally TMonitor.Exit(FLock); end;
  if Binding.RemoveRecords then Binding.CommitRecords(User)
  else Binding.CommitSourceMissing(User);
  var Count:=Length(Binding.ExpectedBooks);
  TMonitor.Enter(FLock);
  try Inc(FState.CompletedBooks,Count); finally TMonitor.Exit(FLock); end;
end;

procedure TBookDeletionOperation.RunQueue(Queue:TArchiveDeletionQueue; const User:ISystemData;
  Offset,Count:Integer);
var Submitted:Integer; Progress:TArchiveDeletionStatus; Receipts:TArray<TArchiveDeletionResult>;
begin
  Submitted:=0; Queue.Start;
  repeat
    if Stopping then Queue.StopAfterCurrentArchive;
    Progress:=Queue.Status;
    if Progress.Archive<>'' then
      Report(Progress.Stage,Progress.Archive,Offset+Progress.ArchiveIndex,Count,
        Progress.Done,Progress.Total);
    Receipts:=Queue.Results;
    while Submitted<Length(Receipts) do
    begin
      var Receipt:=Receipts[Submitted];
      if not Receipt.FilesVerified then Break;
      try
        Report('Обновление коллекции',Receipt.Archive,Offset+Receipt.Index+1,Count);
        CompleteBinding(TBookDeletionBinding.Parse(Receipt.CatalogueBinding),User);
        if Stopping then Queue.StopAfterCurrentArchive;
        Queue.CatalogueCommitted(Receipt.Index);
      except
        Queue.CatalogueRejected(Receipt.Index);
        TMonitor.Enter(FLock);
        try FState.PendingJournal:=Receipt.WorkDirectory; finally TMonitor.Exit(FLock); end;
        raise;
      end;
      Inc(Submitted);
    end;
    if not Progress.Finished then Sleep(25);
  until Progress.Finished;
  Queue.WaitFor;
  if Assigned(Queue.FatalException) then
    raise EInvalidOperation.Create(Exception(Queue.FatalException).Message);
  for var Receipt in Queue.Results do
    if Receipt.Acknowledged then
    begin
      if Receipt.CleanupWarning = '' then Continue;
      TMonitor.Enter(FLock);
      try
        if FState.CleanupWarning = '' then FState.CleanupWarning := Receipt.CleanupWarning;
      finally TMonitor.Exit(FLock); end;
    end
    else
    begin
      if Receipt.JournalDirectory<>'' then
      begin
        TMonitor.Enter(FLock);
        try FState.PendingJournal:=Receipt.WorkDirectory; finally TMonitor.Exit(FLock); end;
      end;
      if Receipt.Cancelled then Abort;
      if Receipt.Error<>'' then raise EInOutError.Create(Receipt.Error);
      raise EInOutError.Create('Не удалось подтвердить удаление из архива.');
    end;
end;

procedure DeleteLooseBook(const Book:TBookRecord);
begin
  var Path:=DeletionNativePath(Book.GetBookFileName);
  if IsArchiveExt(Path) then raise EInOutError.Create('Путь книги изменился и указывает на архив.');
  var Attributes:=GetFileAttributes(PChar(Path));
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    var Error:=GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then Exit;
    RaiseLastOSError(Error);
  end;
  if Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then
    raise EInOutError.Create('Путь книги указывает на папку или ссылку. Файл не удалён.');
  if not Winapi.Windows.DeleteFile(PChar(Path)) then RaiseLastOSError;
end;

procedure TBookDeletionOperation.RunRemoval(const User:ISystemData);
var Archives,Loose,Absent:TList<Integer>; Preparation:TBookDeletionPreparation;
  Progress:TBookDeletionPreparationStatus; Tasks:TArray<TArchiveDeletionTask>;
  Queue:TArchiveDeletionQueue;
begin
  Report('Проверка выбранных книг','',0,0);
  if Stopping then Exit;
  FBinding.CheckBeforePhysicalRemoval(User);
  var Books:=FBinding.ExpectedBooks;
  Archives:=TList<Integer>.Create; Loose:=TList<Integer>.Create; Absent:=TList<Integer>.Create;
  try
    for var I:=0 to High(Books) do
    begin
      if Stopping then Exit;
      if not IsArchiveBookSource(Books[I]) then
      begin Loose.Add(I); Continue; end;
      var Path:=DeletionNativePath(Books[I].GetBookFileName);
      if GetFileAttributes(PChar(Path))=INVALID_FILE_ATTRIBUTES then
      begin
        var Error:=GetLastError;
        if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then
        begin Absent.Add(I); Continue; end;
        RaiseLastOSError(Error);
      end;
      Archives.Add(I);
    end;
    if Archives.Count>0 then
    begin
      Preparation:=TBookDeletionPreparation.Create(FBinding.Slice(Archives.ToArray));
      try
        Preparation.Start;
        repeat
          if Stopping then Preparation.RequestStop;
          Progress:=Preparation.Status;
          if Progress.Stage<>'' then Report(Progress.Stage,Progress.Archive,0,Progress.ArchiveCount);
          if not Progress.Finished then Sleep(25);
        until Progress.Finished;
        Preparation.WaitFor;
        if Assigned(Preparation.FatalException) then
          raise EInvalidOperation.Create(Exception(Preparation.FatalException).Message);
        if Progress.RequiredComponent<>'' then
        begin
          TMonitor.Enter(FLock);
          try FState.RequiredComponent:=Progress.RequiredComponent; finally TMonitor.Exit(FLock); end;
        end;
        if Progress.Error<>'' then raise EReadError.Create(Progress.Error);
        if Progress.Cancelled or Stopping then Exit;
        Tasks:=Preparation.PreparedTasks;
      finally Preparation.Free; end;

      Report('Проверка других записей в этих архивах','',0,Length(Tasks));
      CheckArchiveDeletionReferences(User,Tasks,function:Boolean begin Result:=Stopping; end);
      for var I:=0 to High(Tasks) do
      begin
        if Stopping then Exit;
        TBookDeletionBinding.Parse(Tasks[I].CatalogueBinding).CheckBeforePhysicalRemoval(User);
        Queue:=TArchiveDeletionQueue.Create([Tasks[I]],FJournalRoot,True);
        try
          if Stopping then Queue.StopAfterCurrentArchive;
          RunQueue(Queue,User,I,Length(Tasks));
        finally Queue.Free; end;
      end;
    end;
    for var I in Absent do
    begin
      if Stopping then Exit;
      var Binding:=FBinding.Slice([I]);
      Binding.CheckBeforePhysicalRemoval(User);
      if GetFileAttributes(PChar(DeletionNativePath(Books[I].GetBookFileName)))<>INVALID_FILE_ATTRIBUTES then
        raise EInOutError.Create('Архив появился во время удаления. Повторите выбор книг.');
      var Error:=GetLastError;
      if not (Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError(Error);
      CompleteBinding(Binding,User);
    end;
    for var I in Loose do
    begin
      if Stopping then Exit;
      var Binding:=FBinding.Slice([I]);
      Report('Удаление отдельных файлов',Books[I].GetBookFileName,0,0);
      Binding.CheckBeforePhysicalRemoval(User);
      // Preserve the existing loose-file contract: a failed catalogue
      // delete must never remove a source that still belongs to that row.
      if Binding.RemoveRecords then
      begin CompleteBinding(Binding,User); DeleteLooseBook(Books[I]); end
      else begin DeleteLooseBook(Books[I]); CompleteBinding(Binding,User); end;
    end;
  finally Absent.Free; Loose.Free; Archives.Free; end;
end;

function OrdinaryDirectory(const Path:string):Boolean;
begin
  var Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
  Result:=(Attr<>INVALID_FILE_ATTRIBUTES) and (Attr and FILE_ATTRIBUTE_DIRECTORY<>0) and
    (Attr and FILE_ATTRIBUTE_REPARSE_POINT=0);
end;

function HasArchiveDeletionJournals(const JournalRoot:string):Boolean;
var Search:TSearchRec;
begin
  Result:=False;
  if not OrdinaryDirectory(JournalRoot) or
    (System.SysUtils.FindFirst(TPath.Combine(JournalRoot,'archive-delete-*'),faDirectory,Search)<>0) then Exit;
  try
    repeat
      if (Search.Attr and faDirectory<>0) and OrdinaryDirectory(TPath.Combine(JournalRoot,Search.Name)) then
        Exit(True);
    until System.SysUtils.FindNext(Search)<>0;
  finally System.SysUtils.FindClose(Search); end;
end;

procedure TBookDeletionOperation.RunRecovery(const User:ISystemData);
var Jobs:TList<string>; Queue:TArchiveDeletionQueue;
begin
  if not DirectoryExists(FJournalRoot) then Exit;
  if not OrdinaryDirectory(FJournalRoot) then
    raise EReadError.Create('Папка журналов удаления недоступна или является ссылкой.');
  Report('Поиск незавершённых удалений','',0,0);
  Jobs:=TList<string>.Create;
  try
    for var OperationDir in TDirectory.GetDirectories(FJournalRoot,'archive-delete-*') do
    begin
      if Stopping then Exit;
      if not OrdinaryDirectory(OperationDir) then Continue;
      for var TaskDir in TDirectory.GetDirectories(OperationDir,'archive-*') do
        if OrdinaryDirectory(TaskDir) and
          (Length(TDirectory.GetDirectories(TaskDir,'zip-delete-*'))>0) then
        begin
          if Jobs.Count>=10000 then raise EReadError.Create('Слишком много незавершённых удалений.');
          Jobs.Add(TaskDir);
        end;
    end;
    if Stopping or (Jobs.Count=0) then Exit;
    Report('Проверка журналов удаления','',0,Jobs.Count);
    TMonitor.Enter(FLock);
    try FState.PendingJournal:=FJournalRoot; finally TMonitor.Exit(FLock); end;
    Queue:=TArchiveDeletionQueue.Recover(Jobs.ToArray,True);
    try
      if Stopping then Queue.StopAfterCurrentArchive;
      RunQueue(Queue,User,0,Jobs.Count);
    finally Queue.Free; end;
    if not Stopping then
    begin
      TMonitor.Enter(FLock);
      try FState.PendingJournal:=''; finally TMonitor.Exit(FLock); end;
    end;
  finally Jobs.Free; end;
end;

procedure TBookDeletionOperation.Execute;
var User:ISystemData;
begin
  try
    try
      if Stopping then Exit;
      if not FileExists(FUserFile) then raise EReadError.Create('База коллекций не найдена.');
      User:=TSystemData_SQLite.Create(FUserFile);
      if FRecovery then RunRecovery(User) else RunRemoval(User);
    except
      on E:EAbort do RequestStop;
      on E:Exception do
      begin
        TMonitor.Enter(FLock);
        try
          FState.Error:=E.Message;
          if E is EMHLComponentRequired then FState.RequiredComponent:=EMHLComponentRequired(E).ComponentID;
        finally TMonitor.Exit(FLock); end;
      end;
    end;
  finally
    if Assigned(User) then User.ClearCollectionCache;
    User:=nil;
    // Remove only our empty journal root. Failed or interrupted jobs stay.
    if OrdinaryDirectory(FJournalRoot) then
      RemoveDirectory(PChar(DeletionNativePath(FJournalRoot)));
    TMonitor.Enter(FLock);
    try FState.Finished:=True; finally TMonitor.Exit(FLock); end;
  end;
end;

end.
