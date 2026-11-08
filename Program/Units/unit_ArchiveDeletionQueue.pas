unit unit_ArchiveDeletionQueue;

interface

uses System.Classes, System.SysUtils, System.SyncObjs;

type
  TArchiveDeletionCompanion = record
    Archive, SourceIdentity: string;
    Members: TArray<string>;
  end;

  TArchiveDeletionTask = record
    Archive: string;
    Members: TArray<string>;
    SourceIdentity: string;
    // Captured catalogue identity. Only the owning UI thread may interpret or
    // commit it; the filesystem worker never touches a database connection.
    CatalogueBinding: string;
    Companions: TArray<TArchiveDeletionCompanion>;
  end;

  TArchiveDeletionResult = record
    Index: Integer;
    Archive, SourceIdentity, CatalogueBinding, WorkDirectory, JournalDirectory, Error, CleanupWarning: string;
    FilesVerified, Cancelled: Boolean;
    WaitsForCatalogue, CatalogueCommitted, Acknowledged: Boolean;
    Companions: TArray<TArchiveDeletionCompanion>;
  end;

  TArchiveDeletionStatus = record
    Archive, Stage: string;
    Done, Total: Int64;
    ArchiveIndex, ArchiveCount: Integer;
    Stopping, Finished: Boolean;
  end;

  TArchiveDeletionReview = procedure(MoveBytes, JournalBytes: Int64; CompanionCount: Integer) of object;

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
    FReview: TArchiveDeletionReview;
    FOwnerEvent, FResultEvent: TEvent;
    FCommittedIndex, FRejectedIndex, FAbandonOwner: Integer;
    function WaitForCatalogue(var Item: TArchiveDeletionResult): Boolean;
    procedure Report(const Stage: string; Done, Total: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(const Tasks: TArray<TArchiveDeletionTask>; const JournalParent: string;
      WaitForOwner: Boolean = False; Review: TArchiveDeletionReview = nil);
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

function ValidCompanion(const Primary:string; const Image:TArchiveDeletionCompanion):Boolean;
begin
  if (Length(Image.SourceIdentity)<>59) or (Length(Image.Members)=0) or
    (Length(Image.Members)>200000) then Exit(False);
  var Stem:=ChangeFileExt(ExtractFileName(Primary),'');
  for var Folder in ['covers','images'] do
    for var Ext in ['.zip','.7z'] do
      if SameFileName(Image.Archive,TPath.Combine(ExtractFileDir(Primary),
        Folder+PathDelim+Stem+Ext)) then Exit(True);
  Result:=False;
end;

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
    if Length(Task.Companions)>0 then
    begin
      var Companions:=TJSONArray.Create; ObjectValue.AddPair('companions',Companions);
      for var Image in Task.Companions do
      begin
        var Entry:=TJSONObject.Create; Companions.AddElement(Entry);
        Entry.AddPair('archive',Image.Archive); Entry.AddPair('sourceIdentity',Image.SourceIdentity);
        Members:=TJSONArray.Create; Entry.AddPair('members',Members);
        for var Member in Image.Members do Members.Add(Member);
      end;
    end;
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
  const JournalParent: string; WaitForOwner: Boolean; Review: TArchiveDeletionReview);
var Seen: TDictionary<string,Byte>;
begin
  inherited Create(True); FreeOnTerminate:=False;
  FLock:=TObject.Create; FOwnerEvent:=TEvent.Create(nil,False,False,'');
  FResultEvent:=TEvent.Create(nil,False,False,'');
  FWaitForCatalogue:=WaitForOwner; FCommittedIndex:=-1; FRejectedIndex:=-1;
  FReview:=Review;
  if (Length(Tasks)=0) or (Length(Tasks)>10000) then
    raise EArgumentException.Create('Не выбраны архивы для удаления книг.');
  Seen:=TDictionary<string,Byte>.Create;
  try
    SetLength(FTasks,Length(Tasks)); SetLength(FRecoveryJobs,Length(Tasks));
    for var I:=0 to High(Tasks) do
    begin
      FTasks[I]:=Tasks[I]; FTasks[I].Archive:=ExpandFileName(Tasks[I].Archive);
      FTasks[I].Members:=Copy(Tasks[I].Members);
      FTasks[I].Companions:=Copy(Tasks[I].Companions);
      if (Length(FTasks[I].Companions)>2) or
        ((Length(FTasks[I].Companions)>0) and not FWaitForCatalogue) then
        raise EArgumentException.Create('Архивы изображений требуют подтверждения удаления из каталога.');
      for var Image in FTasks[I].Companions do
        if not ValidCompanion(FTasks[I].Archive,Image) then
          raise EArgumentException.Create('Архив изображений не относится к выбранной книге.');
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

function ReadCompanions(const Primary:string; Value:TJSONValue):TArray<TArchiveDeletionCompanion>;
begin
  Result:=nil;
  if Value=nil then Exit;
  if not (Value is TJSONArray) or (TJSONArray(Value).Count>2) then
    raise EReadError.Create('Повреждён список архивов изображений.');
  for var Item in TJSONArray(Value) do
  begin
    if not (Item is TJSONObject) then raise EReadError.Create('Повреждён журнал удаления изображений.');
    var Entry:=TJSONObject(Item);
    if not (Entry.GetValue('archive') is TJSONString) or
      not (Entry.GetValue('sourceIdentity') is TJSONString) or
      not (Entry.GetValue('members') is TJSONArray) then
      raise EReadError.Create('Неполный журнал удаления изображений.');
    var Image:TArchiveDeletionCompanion;
    Image.Archive:=Entry.GetValue('archive').Value;
    Image.SourceIdentity:=Entry.GetValue('sourceIdentity').Value;
    var Members:=TJSONArray(Entry.GetValue('members'));
    if Members.Count>200000 then raise EReadError.Create('Слишком много изображений в журнале.');
    SetLength(Image.Members,Members.Count);
    for var I:=0 to Members.Count-1 do
    begin
      if not (Members.Items[I] is TJSONString) or (Members.Items[I].Value='') then
        raise EReadError.Create('В журнале отсутствует точное имя изображения.');
      Image.Members[I]:=Members.Items[I].Value;
    end;
    if not ValidCompanion(Primary,Image) then raise EReadError.Create('В журнале указан чужой архив изображений.');
    Result:=Result+[Image];
  end;
end;

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
    Result.SourceIdentity:=ObjectValue.GetValue('sourceIdentity').Value;
    Result.CatalogueBinding:=ObjectValue.GetValue('catalogue').Value;
    if (Result.Archive='') or not SameFileName(Result.Archive,ExpandFileName(Result.Archive)) then
      raise EReadError.Create('В журнале удаления отсутствует полный путь архива.');
    Result.Companions:=ReadCompanions(Result.Archive,ObjectValue.GetValue('companions'));
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
      if (Deletion.ContextHash='') or (Deletion.ContextHash<>State.HashAsString) or
        (Copy(Result.SourceIdentity,1,25)<>Deletion.FileKey) or
        ((Deletion.WholeSourceIdentity<>'') and (Deletion.WholeSourceIdentity<>Result.SourceIdentity)) then
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
      var Key:=Copy(Receipt.SourceIdentity,1,25);
      if Seen.ContainsKey(Key) then raise EReadError.Create('Для одного архива найдены повторные журналы.');
      Seen.Add(Key,0);
      FTasks[I].Archive:=Receipt.Archive; FTasks[I].CatalogueBinding:=Receipt.CatalogueBinding;
      FTasks[I].SourceIdentity:=Receipt.SourceIdentity;
      FTasks[I].Companions:=Receipt.Companions;
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

function PictureWorkDirectory(const Item:TArchiveDeletionResult; Index:Integer):string;
begin Result:=TPath.Combine(Item.WorkDirectory,'pictures-'+IntToStr(Index)); end;

procedure RequireOrdinaryDirectory(const Directory:string);
begin
  var Attr:=GetFileAttributes(PChar(DeletionNativePath(Directory)));
  if (Attr=INVALID_FILE_ATTRIBUTES) or (Attr and FILE_ATTRIBUTE_DIRECTORY=0) or
    (Attr and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
    raise EReadError.Create('Папка журнала изображений недоступна или является ссылкой.');
end;

procedure RemovePictureMarker(const FileName:string);
begin
  if FileExists(FileName) and not System.SysUtils.DeleteFile(FileName) then RaiseLastOSError;
end;

procedure ApplyPictureRemoval(const Item:TArchiveDeletionResult; Index:Integer;
  const Context:string; const Progress:TZipDeleteProgress);
var Engine:TZipMemberDeletion; Lease:IInterface; Jobs:TArray<string>;
begin
  var Image:=Item.Companions[Index];
  var MarkerText:=Context+':'+Image.SourceIdentity;
  var Directory:=PictureWorkDirectory(Item,Index);
  ForceDirectories(DeletionNativePath(Directory)); RequireOrdinaryDirectory(Directory);
  var Marker:=DeletionNativePath(TPath.Combine(Directory,'complete'));
  Jobs:=TDirectory.GetDirectories(DeletionNativePath(Directory),'zip-delete-*');
  if Length(Jobs)>1 then raise EReadError.Create('Найдено несколько журналов одного архива изображений.');
  if Length(Jobs)>0 then RequireOrdinaryDirectory(Jobs[0]);
  if FileExists(Marker) then
  begin
    if (TFile.GetSize(Marker)<>Length(MarkerText)) or (TFile.ReadAllText(Marker,TEncoding.ASCII)<>MarkerText) then
      raise EReadError.Create('Журнал завершения удаления изображений изменён.');
    if Length(Jobs)>0 then
    begin
      // The marker is written after the image archive is verified and any
      // unlink is complete. A stopped acknowledgement may leave its files.
      for var Name in ['pending.bin','checkpoint.json','plan.json'] do
        RemovePictureMarker(DeletionNativePath(TPath.Combine(Jobs[0],Name)));
      if not RemoveDirectory(PChar(DeletionNativePath(Jobs[0]))) then RaiseLastOSError;
    end;
    Exit;
  end;

  Engine:=nil;
  try
    try Lease:=AcquireArchiveChange(Image.Archive);
    except on E:EOSError do if (Length(Jobs)=0) or (E.ErrorCode<>ERROR_FILE_NOT_FOUND) then raise; end;
    if Length(Jobs)=0 then
    begin
      Engine:=TZipMemberDeletion.Prepare(Image.Archive,Image.Members,Progress,nil,Image.SourceIdentity);
      Engine.RequirePrivateSource;
      Engine.BindContext(Context);
      Engine.EnableWholeRemoval;
    end
    else
    begin
      Engine:=TZipMemberDeletion.Recover(Image.Archive,Jobs[0]);
      if (Engine.ContextHash<>Context) or (Engine.FileKey<>Copy(Image.SourceIdentity,1,25)) or
        ((Engine.WholeSourceIdentity<>'') and (Engine.WholeSourceIdentity<>Image.SourceIdentity)) or
        ((Lease=nil) and not Engine.WholeSourceMissing) then
        raise EReadError.Create('Журнал не соответствует архиву изображений.');
      if not Engine.WholeSourceMissing then Engine.RequirePrivateSource;
    end;
    Engine.Execute(Directory,Progress);
    Engine.Acknowledge(
      procedure
      begin
        var Stream:=TBytesStream.Create(TEncoding.ASCII.GetBytes(MarkerText));
        try SaveStreamAtomically(Stream,Marker); finally Stream.Free; end;
      end);
  finally Engine.Free; Lease:=nil; end;
end;

procedure ApplyPictureRemovals(var Item:TArchiveDeletionResult;
  const Context:string; const Progress:TZipDeleteProgress);
begin
  for var I:=0 to High(Item.Companions) do
    try
      ApplyPictureRemoval(Item,I,Context,Progress);
    except
      on E:Exception do
      begin
        var Directory:=PictureWorkDirectory(Item,I);
        // A read-only planning error keeps the images. Once the engine has
        // a journal, keep the primary receipt so a restart can replay it.
        if DirectoryExists(DeletionNativePath(Directory)) then
        begin
          RequireOrdinaryDirectory(Directory);
          if Length(TDirectory.GetDirectories(DeletionNativePath(Directory),'zip-delete-*'))>0 then raise;
        end;
        if Item.CleanupWarning<>'' then Item.CleanupWarning:=Item.CleanupWarning+sLineBreak;
        Item.CleanupWarning:=Item.CleanupWarning+'Не удалось убрать изображения: '+Item.Companions[I].Archive+
          sLineBreak+E.Message;
      end;
    end;
end;

procedure CleanupReceiptDirectories(const Item:TArchiveDeletionResult; RemoveOperationRoot:Boolean=True);
begin
  for var I:=0 to High(Item.Companions) do
  begin
    var Directory:=PictureWorkDirectory(Item,I);
    if not DirectoryExists(DeletionNativePath(Directory)) then Continue;
    RequireOrdinaryDirectory(Directory);
    RemovePictureMarker(DeletionNativePath(TPath.Combine(Directory,'complete')));
    if not RemoveDirectory(PChar(DeletionNativePath(Directory))) then RaiseLastOSError;
  end;
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
      Item.SourceIdentity:=FTasks[I].SourceIdentity;
      Item.Companions:=FTasks[I].Companions;
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
        if FRecoveryJobs[I]<>'' then
        begin
          try Lease:=AcquireArchiveChange(Item.Archive);
          except on E:EOSError do if E.ErrorCode<>ERROR_FILE_NOT_FOUND then raise; end;
          var Receipt:=ReadReceipt(Item.WorkDirectory);
          if (Receipt.Archive<>Item.Archive) or
            (Receipt.SourceIdentity<>Item.SourceIdentity) or
            (Receipt.CatalogueBinding<>Item.CatalogueBinding) or
            not SameFileName(Receipt.JournalDirectory,Item.JournalDirectory) then
            raise EReadError.Create('Журнал удаления изменился после выбора восстановления.');
          Deletion:=TZipMemberDeletion.Recover(Item.Archive,Item.JournalDirectory);
          if ((Lease=nil) and not Deletion.WholeSourceMissing) or
            (((Deletion.WholeSourceIdentity<>'') or (Length(Item.Companions)>0)) and not FWaitForCatalogue) then
            raise EReadError.Create('Не удалось безопасно продолжить удаление целого архива.');
          if Deletion.ContextHash<>BindingHash(Item.WorkDirectory) then
            raise EReadError.Create('Привязка каталога изменилась перед продолжением удаления.');
        end
        else
        begin
          Lease:=AcquireArchiveChange(Item.Archive);
          if not CreateDirectory(PChar(DeletionNativePath(Item.WorkDirectory)),nil) then RaiseLastOSError;
          SaveBinding(FTasks[I],Item.WorkDirectory);
          Deletion:=TZipMemberDeletion.Prepare(Item.Archive,FTasks[I].Members,
            procedure(const Stage: string; Done,Total: Int64) begin Report(Stage,Done,Total); end,
            function: Boolean begin Result:=TInterlocked.CompareExchange(FStop,0,0)<>0; end,
            FTasks[I].SourceIdentity);
          Deletion.BindContext(BindingHash(Item.WorkDirectory));
          if FWaitForCatalogue then Deletion.EnableWholeRemoval;
          if Assigned(FReview) and (Deletion.WholeSourceIdentity='') then
            FReview(Deletion.BytesToProcess,Deletion.JournalBytes,Length(Item.Companions));
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
              if Length(Item.Companions)=0 then Deletion.Acknowledge
              else Deletion.Acknowledge(
                procedure
                begin
                  Report('Удаление обложек и иллюстраций',0,0);
                  ApplyPictureRemovals(Item,Deletion.ContextHash,
                    procedure(const Stage:string; Done,Total:Int64)
                    begin Report('Удаление обложек и иллюстраций',Done,Total); end);
                end);
              // A live new queue has not created its later task directories
              // yet. Its operation root must survive until the loop finishes.
              CleanupReceiptDirectories(Item,FRoot=''); Item.Acknowledged:=True;
              // Unlink only after the catalogue commit and journal cleanup.
              // If interrupted here, an empty container can remain safely.
              try
                Deletion.RemoveEmptyArchive;
              except
                on E:Exception do
                begin
                  if Item.CleanupWarning<>'' then Item.CleanupWarning:=Item.CleanupWarning+sLineBreak;
                  Item.CleanupWarning:=Item.CleanupWarning+'Не удалось убрать пустой архив '+Item.Archive+sLineBreak+E.Message;
                end;
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
  if Length(Stored.Companions)>0 then
    raise EInvalidOperation.Create('Удаление изображений завершается вместе с каталогом.');
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
