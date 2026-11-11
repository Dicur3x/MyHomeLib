unit unit_BookCompressionJob;

interface

uses System.SysUtils, System.JSON, unit_ZipMemberDeletion, unit_BookCompressionReceipt;

type
  // One physical file, one immutable catalogue receipt. The job survives until
  // its caller has refreshed the visible catalogue and explicitly forgets it.
  TBookCompressionJob = class
  private
    FDirectory, FJournalRoot, FSource, FCandidate, FIdentity: string;
    FReceipt: TBookCompressionReceipt;
    FData: TJSONObject;
    FLease, FDirectoryGuard: THandle;
    FCompleted: Boolean;
    procedure OpenLease;
    procedure ReadBinding;
    function FindJournal: string;
    procedure CheckCompleted;
    procedure SaveCompleted;
    function Field(const Name: string): string;
  public
    constructor CreatePrepared(const QueueRoot, ReceiptJSON, Candidate: string);
    constructor OpenExisting(const Directory: string);
    destructor Destroy; override;
    procedure Execute(const Cancelled: TFunc<Boolean> = nil;
      const Progress: TZipDeleteProgress = nil; const Fault: TProc<string> = nil);
    // A completed job may be forgotten after the application has refreshed its
    // caches. A failed or interrupted operation must keep its recovery data.
    procedure Forget;
    class function Pending(const QueueRoot: string): TArray<string>; static;
    property Directory: string read FDirectory;
    property Source: string read FSource;
    property Completed: Boolean read FCompleted;
  end;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Hash,
  System.Generics.Collections, unit_AtomicIniFile, unit_MHLArchiveBusy;

const
  JobPrefix = 'compress-';
  JobKind = 'HomeLibre in-place compression job';

function ReadText(const FileName: string; Limit: Integer): string;
var Stream: TFileStream; Bytes: TBytes; Info: TByHandleFileInformation;
begin
  Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    if not GetFileInformationByHandle(Stream.Handle,Info) then RaiseLastOSError;
    if (Stream.Size<=0) or (Stream.Size>Limit) or (Info.nNumberOfLinks<>1) or
      ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0) then
      raise EReadError.Create('Некорректный файл задания сжатия.');
    SetLength(Bytes,Integer(Stream.Size)); Stream.ReadBuffer(Bytes[0],Length(Bytes));
    Result:=TEncoding.UTF8.GetString(Bytes);
  finally Stream.Free; end;
end;

procedure SaveText(const FileName, Value: string);
var Stream: TStringStream;
begin
  Stream:=TStringStream.Create(Value,TEncoding.UTF8);
  try SaveStreamAtomically(Stream,DeletionNativePath(FileName)); finally Stream.Free; end;
end;

function TryGUID(const Text: string; out ID: TGUID): Boolean;
begin
  try ID:=StringToGUID(Text); Result:=True;
  except on E:EConvertError do Result:=False; end;
end;

function IsJobName(const Name: string): Boolean;
var ID: TGUID;
begin
  Result:=Name.StartsWith(JobPrefix) and
    TryGUID(Copy(Name,Length(JobPrefix)+1,MaxInt),ID) and
    (Name=JobPrefix+GUIDToString(ID));
end;

function FileDigest(const FileName: string): string;
var Stream: TFileStream; Hash: THashSHA2; Bytes: TBytes; Count: Integer;
begin
  Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    Hash:=THashSHA2.Create; SetLength(Bytes,1024*1024);
    repeat
      Count:=Stream.Read(Bytes[0],Length(Bytes));
      if Count>0 then Hash.Update(Bytes,Count);
    until Count=0;
    Result:=Hash.HashAsString;
  finally Stream.Free; end;
end;

procedure CheckDirectory(const Path: string);
var Attr: DWORD;
begin
  Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
  if Attr=INVALID_FILE_ATTRIBUTES then RaiseLastOSError;
  if ((Attr and FILE_ATTRIBUTE_DIRECTORY)=0) or ((Attr and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
    raise EReadError.Create('Папка задания сжатия заменена ссылкой или файлом.');
end;

function TBookCompressionJob.Field(const Name: string): string;
begin
  var Value:=FData.GetValue(Name);
  if not (Value is TJSONString) then raise EReadError.Create('Неполное задание сжатия: '+Name);
  Result:=Value.Value;
end;

procedure TBookCompressionJob.OpenLease;
var Info: TByHandleFileInformation; Path: string; FinalPath: TArray<Char>; Count: DWORD;
begin
  CheckDirectory(FDirectory);
  FDirectoryGuard:=CreateFile(PChar(DeletionNativePath(FDirectory)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FDirectoryGuard=INVALID_HANDLE_VALUE then begin FDirectoryGuard:=0; RaiseLastOSError; end;
  // Reject junctions in parent components too, and keep the directory from
  // being renamed while any published receipt or recovery file is in use.
  SetLength(FinalPath,32768);
  Count:=GetFinalPathNameByHandle(FDirectoryGuard,@FinalPath[0],Length(FinalPath),0);
  if (Count=0) or (Count>=DWORD(Length(FinalPath))) then RaiseLastOSError;
  SetString(Path,PChar(@FinalPath[0]),Count);
  if not SameFileName(Path,DeletionNativePath(FDirectory)) then
    raise EReadError.Create('Путь папки сжатия проходит через ссылку.');
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'active.lock'))),
    GENERIC_READ or GENERIC_WRITE,FILE_SHARE_DELETE,nil,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  if not GetFileInformationByHandle(FLease,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or (Info.nFileSizeLow<>0) or (Info.nFileSizeHigh<>0) or
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0) then
    raise EReadError.Create('Некорректная блокировка задания сжатия.');
end;

constructor TBookCompressionJob.CreatePrepared(const QueueRoot, ReceiptJSON, Candidate: string);
var Binding: TJSONObject;
begin
  inherited Create;
  FReceipt:=TBookCompressionReceipt.Create(ReceiptJSON);
  FData:=TJSONObject.ParseJSONValue(FReceipt.ToJSON) as TJSONObject;
  FSource:=Field('source'); FCandidate:=ExpandFileName(Candidate);
  if SameFileName(FSource,FCandidate) then
    raise EArgumentException.Create('Результат сжатия должен быть отдельным подготовленным файлом.');
  FReceipt.CheckBeforeWrite;
  FIdentity:=ArchiveDeletionSourceIdentity(FSource);
  if Copy(FIdentity,1,25)<>Field('source_file_key') then
    raise EReadError.Create('Исходный файл изменился до создания задания.');
  ForceDirectories(DeletionNativePath(QueueRoot)); CheckDirectory(QueueRoot);
  FDirectory:=TPath.Combine(ExpandFileName(QueueRoot),JobPrefix+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(DeletionNativePath(FDirectory)),nil) then RaiseLastOSError;
  OpenLease;
  FJournalRoot:=TPath.Combine(FDirectory,'file');
  SaveText(TPath.Combine(FDirectory,'receipt.json'),FReceipt.ToJSON);
  Binding:=TJSONObject.Create;
  try
    Binding.AddPair('kind',JobKind); Binding.AddPair('job',ExtractFileName(FDirectory));
    Binding.AddPair('receipt_sha256',FReceipt.SHA256);
    Binding.AddPair('source_identity',FIdentity); Binding.AddPair('candidate',FCandidate);
    SaveText(TPath.Combine(FDirectory,'job.json'),Binding.ToJSON);
  finally Binding.Free; end;
end;

procedure TBookCompressionJob.ReadBinding;
var Value: TJSONValue; Binding: TJSONObject;
begin
  Value:=TJSONObject.ParseJSONValue(ReadText(TPath.Combine(FDirectory,'job.json'),65536));
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждено задание сжатия.'); end;
  Binding:=TJSONObject(Value);
  try
    FReceipt:=TBookCompressionReceipt.Create(ReadText(TPath.Combine(FDirectory,'receipt.json'),16*1024*1024));
    if (Binding.GetValue<string>('kind','')<>JobKind) or
      (Binding.GetValue<string>('job','')<>ExtractFileName(FDirectory)) or
      (Binding.GetValue<string>('receipt_sha256','')<>FReceipt.SHA256) then
      raise EReadError.Create('Задание сжатия не соответствует сохранённому каталогу.');
    FData:=TJSONObject.ParseJSONValue(FReceipt.ToJSON) as TJSONObject;
    FSource:=Field('source'); FIdentity:=Binding.GetValue<string>('source_identity','');
    FCandidate:=Binding.GetValue<string>('candidate','');
    if (Length(FIdentity)<>59) or (Copy(FIdentity,1,25)<>Field('source_file_key')) or
      (FCandidate='') or (FCandidate<>ExpandFileName(FCandidate)) or SameFileName(FSource,FCandidate) then
      raise EReadError.Create('Неполная привязка файла в задании сжатия.');
    FJournalRoot:=TPath.Combine(FDirectory,'file');
  finally Binding.Free; end;
end;

constructor TBookCompressionJob.OpenExisting(const Directory: string);
begin
  inherited Create;
  FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory));
  if not IsJobName(ExtractFileName(FDirectory)) then
    raise EReadError.Create('Это не папка задания сжатия книг.');
  OpenLease; ReadBinding;
end;

destructor TBookCompressionJob.Destroy;
begin
  if FLease<>0 then CloseHandle(FLease);
  if FDirectoryGuard<>0 then CloseHandle(FDirectoryGuard);
  FReceipt.Free; FData.Free; inherited;
end;

function TBookCompressionJob.FindJournal: string;
var ID: TGUID; Name: string;
begin
  Result:='';
  if not DirectoryExists(DeletionNativePath(FJournalRoot)) then Exit;
  CheckDirectory(FJournalRoot);
  for var Path in TDirectory.GetDirectories(DeletionNativePath(FJournalRoot),'zip-delete-*') do
  begin
    CheckDirectory(Path);
    Name:=ExtractFileName(Path);
    if not TryGUID(Copy(Name,Length('zip-delete-')+1,MaxInt),ID) or
      (Name<>'zip-delete-'+GUIDToString(ID)) then
      raise EReadError.Create('Посторонняя папка в журнале сжатия. Она сохранена.');
    if Result<>'' then raise EReadError.Create('В задании несколько журналов применения. Продолжение остановлено.');
    Result:=Path;
  end;
end;

procedure TBookCompressionJob.SaveCompleted;
begin
  SaveText(TPath.Combine(FDirectory,'completed.json'),FReceipt.SHA256);
end;

procedure TBookCompressionJob.CheckCompleted;
begin
  if (ReadText(TPath.Combine(FDirectory,'completed.json'),128)<>FReceipt.SHA256) or
    (CompressionFileKey(FSource)<>Field('source_file_key')) or
    (FileDigest(FSource)<>Field('result_sha256')) then
    raise EReadError.Create('Завершённое задание сжатия или его файл изменены. Журнал сохранён.');
  FReceipt.CheckApplied;
  FCompleted:=True;
end;

procedure TBookCompressionJob.Execute(const Cancelled: TFunc<Boolean>;
  const Progress: TZipDeleteProgress; const Fault: TProc<string>);
var Engine: TZipMemberDeletion; Journal: string; ChangeLease: IInterface; EngineFault: TZipDeleteFault;
  procedure Signal(const Stage: string);
  begin if Assigned(Fault) then Fault(Stage); end;
begin
  if not Assigned(FReceipt) then raise EInvalidOperation.Create('Задание сжатия уже закрыто.');
  ChangeLease:=AcquireArchiveChange(FSource);
  if FileExists(DeletionNativePath(TPath.Combine(FDirectory,'completed.json'))) then
  begin CheckCompleted; Exit; end;
  Journal:=FindJournal;
  if Journal<>'' then
    Engine:=TZipMemberDeletion.RecoverReplacement(FSource,Journal)
  else
  begin
    if Assigned(Cancelled) and Cancelled() then Abort;
    // A crash before publication leaves the original intact. Abandoned
    // staging may be discarded, but never guessed at as a recovery plan.
    if DirectoryExists(DeletionNativePath(FJournalRoot)) then
      DiscardUnpublishedDeletionStages(FJournalRoot);
    FReceipt.CheckBeforeWrite;
    Engine:=TZipMemberDeletion.PrepareReplacement(FSource,FCandidate,FIdentity,
      Field('source_sha256'),Field('result_sha256'),FJournalRoot,Cancelled,Progress);
    try
      Engine.BindContext(FReceipt.SHA256);
      FReceipt.CheckBeforeWrite;
      if Assigned(Cancelled) and Cancelled() then Abort;
    except Engine.Free; raise; end;
  end;
  try
    if Engine.ContextHash<>FReceipt.SHA256 then
      raise EReadError.Create('Журнал файла относится к другому заданию сжатия.');
    EngineFault:=nil;
    if Assigned(Fault) then
      EngineFault:=procedure(const Stage: string; Chunk: Integer) begin Fault(Stage); end;
    Engine.Execute(FJournalRoot,Progress,EngineFault);
    Signal('file-committed');
    FReceipt.Apply(Engine,Fault);
    SaveCompleted;
    Signal('completed-published');
    Engine.Acknowledge;
    FCompleted:=True;
    Signal('file-journal-forgotten');
  finally Engine.Free; end;
end;

procedure TBookCompressionJob.Forget;
var Journal, Tombstone: string;
  procedure RemoveFile(const Path: string);
  var Attr: DWORD;
  begin
    Attr:=GetFileAttributes(PChar(DeletionNativePath(Path)));
    if Attr=INVALID_FILE_ATTRIBUTES then
    begin if GetLastError=ERROR_FILE_NOT_FOUND then Exit; RaiseLastOSError; end;
    if (Attr and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT))<>0 then
      raise EReadError.Create('В папке задания появился посторонний объект. Он сохранён.');
    if not Winapi.Windows.DeleteFile(PChar(DeletionNativePath(Path))) then RaiseLastOSError;
  end;
begin
  if not FCompleted or not Assigned(FReceipt) then
    raise EInvalidOperation.Create('Задание сжатия ещё не завершено или уже закрыто.');
  // Execute has just verified/acknowledged the file, or CheckCompleted has
  // verified recovery and both stores. Cleanup does not write book bytes and
  // must not reread a multi-gigabyte archive a second time just to discard its
  // own receipt. A changed completion marker still prevents cleanup.
  if ReadText(TPath.Combine(FDirectory,'completed.json'),128)<>FReceipt.SHA256 then
    raise EReadError.Create('Подтверждение сжатия изменилось. Задание сохранено.');
  // Stop advertising the job atomically before removing any receipt bytes.
  // A cleanup crash may leave a small done-* directory, never a half-deleted
  // pending job that could be mistaken for another compression operation.
  Tombstone:=TPath.Combine(ExtractFileDir(FDirectory),'done-'+ExtractFileName(FDirectory));
  // Windows also checks open descendants when renaming a directory. Release
  // the completed job's lease first. A competing recovery opens its directory
  // guard and makes the rename fail safely instead of sharing cleanup work.
  CloseHandle(FLease); FLease:=0;
  CloseHandle(FDirectoryGuard); FDirectoryGuard:=0;
  if not MoveFileEx(PChar(DeletionNativePath(FDirectory)),PChar(DeletionNativePath(Tombstone)),
    MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
  FDirectory:=Tombstone; FJournalRoot:=TPath.Combine(FDirectory,'file');
  // After the durable completion marker, a crash halfway through engine
  // cleanup must not trigger a second database update. Only fixed owned
  // recovery filenames are disposable; an unknown file keeps the directory.
  Journal:=FindJournal;
  if Journal<>'' then
  begin
    for var Name in ['pending.bin','replacement.bin','checkpoint.json','plan.json'] do
      RemoveFile(TPath.Combine(Journal,Name));
    if not RemoveDirectory(PChar(DeletionNativePath(Journal))) then RaiseLastOSError;
  end;
  if DirectoryExists(DeletionNativePath(FJournalRoot)) then
  begin
    DiscardUnpublishedDeletionStages(FJournalRoot);
    if not RemoveDirectory(PChar(DeletionNativePath(FJournalRoot))) then RaiseLastOSError;
  end;
  for var Name in ['job.json','receipt.json','completed.json'] do RemoveFile(TPath.Combine(FDirectory,Name));
  FreeAndNil(FReceipt); FreeAndNil(FData);
  RemoveFile(TPath.Combine(FDirectory,'active.lock'));
  if not RemoveDirectory(PChar(DeletionNativePath(FDirectory))) then RaiseLastOSError;
end;

class function TBookCompressionJob.Pending(const QueueRoot: string): TArray<string>;
var Items: TList<string>;
begin
  Result:=nil;
  if not DirectoryExists(DeletionNativePath(QueueRoot)) then Exit;
  CheckDirectory(QueueRoot);
  Items:=TList<string>.Create;
  try
    for var Path in TDirectory.GetDirectories(DeletionNativePath(QueueRoot),JobPrefix+'*') do
      if IsJobName(ExtractFileName(Path)) then
      begin CheckDirectory(Path); Items.Add(ExpandFileName(Path)); end;
    Items.Sort; Result:=Items.ToArray;
  finally Items.Free; end;
end;

end.
