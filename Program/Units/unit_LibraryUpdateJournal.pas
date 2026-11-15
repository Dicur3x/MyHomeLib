unit unit_LibraryUpdateJournal;

interface

uses System.SysUtils, System.Classes, System.JSON, Winapi.Windows, unit_Interfaces;

type
  TLibraryUpdateJournal = class
  private
    FDirectory, FRoot, FBackupRoot, FSystemFile, FMetaHash: string;
    FData: TJSONObject;
    FLease, FDirectoryGuard, FRootGuard: THandle;
    FBackupGuard: TFileStream;
    procedure GuardDirectory;
    procedure OpenLease(NewJob: Boolean);
    procedure ValidateBinding(const SystemData: ISystemData);
    function Text(const Name: string): string;
    function BackupFile: string;
    function OperationID: string;
    function CollectionID: Integer;
    function Done: Boolean;
    procedure Finish(const State: string);
    constructor OpenExisting(const Root, BackupRoot, SystemFile, Directory: string;
      const SystemData: ISystemData);
  public
    constructor CreatePrepared(const Root, BackupRoot, SystemFile, Backup: string;
      const Target: IBookCollection; const SystemData: ISystemData;
      const TransactionID: string; Bound: Boolean; const Check: TProc);
    destructor Destroy; override;
    procedure Seal(const Target: IBookCollection; const Check: TProc);
    function CatalogueCommitted(const Target: IBookCollection): Boolean;
    function CompleteAttempt(const Target: IBookCollection; const SystemData: ISystemData;
      PersonalRemapComplete: Boolean): Boolean;
    procedure Recover(const SystemData: ISystemData; const Check: TProc);
    class function Pending(const Root: string): TArray<string>; static;
    class function HasPendingForCollection(const Root: string; ID: Integer): Boolean; static;
    class procedure RecoverAll(const Root, BackupRoot, SystemFile: string;
      const SystemData: ISystemData; const Warnings: TStrings; const Check: TProc = nil); static;
  end;

{$IFDEF MHL_COMPRESSION_TEST}
var LibraryUpdateRecoveryTestPoint:TProc<string,Integer,Integer>;
{$ENDIF}

implementation

uses System.IOUtils, System.Hash, System.Generics.Collections, System.Variants,
  SQLiteWrap, unit_Consts, unit_Globals, unit_AtomicIniFile, unit_ZipMemberDeletion, unit_CatalogContentDigest;

const JobKind='HomeLibre reviewed library update'; JobPrefix='update-';

function Full(const Value: string): string;
begin Result:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(Value)); end;

function CanonicalGUID(const Value: string): Boolean;
var ID: TGUID;
begin
  Result:=False;
  try ID:=StringToGUID(Value); Result:=Value=GUIDToString(ID);
  except on E:EConvertError do Exit; end;
end;

function IsSHA(const Value: string): Boolean;
begin
  Result:=Length(Value)=64;
  if Result then for var C in Value do
    if not CharInSet(C,['0'..'9','a'..'f']) then Exit(False);
end;

function Field(Data: TJSONObject; const Name: string): string;
var Value: TJSONValue;
begin
  Value:=Data.GetValue(Name);
  if not (Value is TJSONString) then raise EReadError.Create('Некорректное поле журнала обновления: '+Name);
  Result:=TJSONString(Value).Value;
end;

function FileKey(const FileName: string): string;
begin
  if not IsPrivateArchiveDeletionSource(FileName) then
    raise EReadError.Create('Файл обновления недоступен, является ссылкой или имеет несколько имён: '+FileName);
  Result:=Copy(ArchiveDeletionSourceIdentity(FileName),1,25);
end;

function ReadJSON(const FileName: string): TJSONObject;
var Stream: TFileStream; Bytes: TBytes; Value: TJSONValue;
begin
  FileKey(FileName);
  Stream:=TFileStream.Create(DeletionNativePath(FileName),fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size<=0) or (Stream.Size>512*1024) then raise EReadError.Create('Неверный размер журнала обновления.');
    SetLength(Bytes,Integer(Stream.Size)); Stream.ReadBuffer(Bytes[0],Length(Bytes));
  finally Stream.Free; end;
  Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждён журнал обновления.'); end;
  Result:=TJSONObject(Value);
end;

procedure SaveJSON(const FileName: string; Data: TJSONObject);
var Stream: TStringStream;
begin
  Stream:=TStringStream.Create(Data.ToJSON,TEncoding.UTF8);
  try SaveStreamAtomically(Stream,DeletionNativePath(FileName)); finally Stream.Free; end;
end;

function Guard(const Directory: string): THandle;
var Info: TByHandleFileInformation; Buffer: TArray<Char>; Count: DWORD; Resolved: string;
begin
  Result:=CreateFile(PChar(DeletionNativePath(Directory)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    if not GetFileInformationByHandle(Result,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
      (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
      raise EReadError.Create('Папка журнала обновления заменена ссылкой.');
    SetLength(Buffer,32768); Count:=GetFinalPathNameByHandle(Result,@Buffer[0],Length(Buffer),0);
    if (Count=0) or (Count>=DWORD(Length(Buffer))) then RaiseLastOSError;
    SetString(Resolved,PChar(@Buffer[0]),Count);
    if not SameFileName(Resolved,DeletionNativePath(Full(Directory))) then
      raise EReadError.Create('Путь журнала обновления проходит через ссылку.');
  except CloseHandle(Result); raise; end;
end;

procedure EnsureDirectory(const Directory: string);
begin
  if not DirectoryExists(Directory) and not CreateDirectory(PChar(DeletionNativePath(Directory)),nil) then RaiseLastOSError;
end;

function StreamSHA(Stream: TStream; const Check: TProc): string;
var Hash: THashSHA2; Bytes: TBytes; Count: Integer;
begin
  Hash:=THashSHA2.Create; SetLength(Bytes,1024*1024); Stream.Position:=0;
  repeat
    if Assigned(Check) then Check;
    Count:=Stream.Read(Bytes[0],Length(Bytes)); if Count>0 then Hash.Update(Bytes,Count);
  until Count=0;
  Result:=Hash.HashAsString;
end;

function PersonalWitness(const SystemData: ISystemData; ID: Integer): string;
var Witness: ISystemCatalogCommitWitness;
begin
  if not Supports(SystemData,ISystemCatalogCommitWitness,Witness) then
    raise ENotSupportedException.Create('Хранилище не поддерживает восстановление обновления.');
  Result:=Witness.CatalogCommitWitness(ID);
end;

function RawWitness(Database: TSQLiteDatabase): string;
var Query: TSQLiteQuery;
begin
  Result:=''; Query:=Database.NewQuery('SELECT SettingValue FROM Settings WHERE SettingID=?',[PROP_LIBRARY_UPDATE_TRANSACTION]);
  try Query.Open; if not Query.Eof then Result:=Query.FieldAsString(0); finally Query.Free; end;
end;

procedure RecoverySpace(const Folder: string; Required: UInt64 = 0);
var Available, Capacity: UInt64; SystemRoot: string;
begin
  SystemRoot:=TPath.GetPathRoot(TPath.GetFullPath(GetEnvironmentVariable('SystemRoot')));
  if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then raise EWriteError.Create('Для восстановления нужно сохранить 8 ГБ свободного места на системном диске.');
  if not GetDiskFreeSpaceEx(PChar(Folder),Available,Capacity,nil) then RaiseLastOSError;
  if (Available<Required) or (Available-Required<UInt64(512)*1024*1024) then
    raise EWriteError.Create('Недостаточно свободного места для восстановления каталога.');
end;

function TLibraryUpdateJournal.Text(const Name: string): string;
begin Result:=Field(FData,Name); end;
function TLibraryUpdateJournal.OperationID: string;
begin Result:=Text('operation'); end;
function TLibraryUpdateJournal.CollectionID: Integer;
var Value: TJSONValue;
begin
  Value:=FData.GetValue('collection');
  if not (Value is TJSONNumber) or not TryStrToInt(TJSONNumber(Value).Value,Result) or (Result<=0) then
    raise EReadError.Create('Неверная коллекция в журнале обновления.');
end;
function TLibraryUpdateJournal.BackupFile: string;
begin
  if Text('mode')='bound' then Result:=TPath.Combine(TPath.Combine(FBackupRoot,OperationID),'destination.hlc2')
  else if Text('mode')='ordinary' then Result:=TPath.Combine(FBackupRoot,OperationID+'.hlc2')
  else raise EReadError.Create('Неверный режим журнала обновления.');
end;

procedure TLibraryUpdateJournal.GuardDirectory;
begin
  if FRootGuard=0 then FRootGuard:=Guard(FRoot);
  FDirectoryGuard:=Guard(FDirectory);
end;

procedure TLibraryUpdateJournal.OpenLease(NewJob: Boolean);
var Info: TByHandleFileInformation; Disposition: DWORD;
begin
  if NewJob then Disposition:=CREATE_NEW else Disposition:=OPEN_EXISTING;
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'active.lock'))),
    GENERIC_READ or GENERIC_WRITE,FILE_SHARE_DELETE,nil,Disposition,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  if not GetFileInformationByHandle(FLease,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or (Info.nFileSizeHigh<>0) or (Info.nFileSizeLow<>0) or
    (Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) then
    raise EReadError.Create('Повреждена блокировка журнала обновления.');
end;

constructor TLibraryUpdateJournal.CreatePrepared(const Root, BackupRoot, SystemFile, Backup: string;
  const Target: IBookCollection; const SystemData: ISystemData;
  const TransactionID: string; Bound: Boolean; const Check: TProc);
begin
  inherited Create;
  if not CanonicalGUID(TransactionID) then raise EArgumentException.Create('Неверный номер операции.');
  FRoot:=Full(Root); FBackupRoot:=Full(BackupRoot); FSystemFile:=Full(SystemFile);
  EnsureDirectory(FRoot); FRootGuard:=Guard(FRoot);
  FDirectory:=TPath.Combine(FRoot,JobPrefix+TransactionID);
  if not CreateDirectory(PChar(DeletionNativePath(FDirectory)),nil) then RaiseLastOSError;
  GuardDirectory; OpenLease(True);
  FData:=TJSONObject.Create;
  FData.AddPair('kind',JobKind); FData.AddPair('version',TJSONNumber.Create(1));
  FData.AddPair('operation',TransactionID); FData.AddPair('collection',TJSONNumber.Create(Target.CollectionID));
  if Bound then FData.AddPair('mode','bound') else FData.AddPair('mode','ordinary');
  FData.AddPair('system',FSystemFile); FData.AddPair('system_key',FileKey(FSystemFile));
  FData.AddPair('target',Full(VarToStr(Target.GetProperty(PROP_DATAFILE))));
  FData.AddPair('target_key',FileKey(Text('target'))); FData.AddPair('root',Full(Target.CollectionRoot));
  FData.AddPair('previous_catalogue',VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION)));
  FData.AddPair('previous_personal',PersonalWitness(SystemData,Target.CollectionID));
  if not SameFileName(Full(Backup),BackupFile) then raise EReadError.Create('Резервная копия не принадлежит операции.');
  FileKey(BackupFile); FBackupGuard:=TFileStream.Create(DeletionNativePath(BackupFile),fmOpenRead or fmShareDenyWrite);
  FData.AddPair('backup_sha256',StreamSHA(FBackupGuard,Check));
  ValidateBinding(SystemData);
  FMetaHash:=THashSHA2.GetHashString(FData.ToJSON);
  SaveJSON(TPath.Combine(FDirectory,'job.json'),FData);
end;

constructor TLibraryUpdateJournal.OpenExisting(const Root, BackupRoot, SystemFile, Directory: string;
  const SystemData: ISystemData);
begin
  inherited Create; FRoot:=Full(Root); FBackupRoot:=Full(BackupRoot); FSystemFile:=Full(SystemFile); FDirectory:=Full(Directory);
  if not SameFileName(TPath.GetDirectoryName(FDirectory),FRoot) then raise EReadError.Create('Журнал вне папки восстановления.');
  GuardDirectory; OpenLease(False); FData:=ReadJSON(TPath.Combine(FDirectory,'job.json'));
  if (Text('kind')<>JobKind) or not (FData.GetValue('version') is TJSONNumber) or
    (TJSONNumber(FData.GetValue('version')).Value<>'1') or not CanonicalGUID(OperationID) or
    (TPath.GetFileName(FDirectory)<>JobPrefix+OperationID) then raise EReadError.Create('Неверный журнал обновления.');
  FMetaHash:=THashSHA2.GetHashString(FData.ToJSON);
  if not Done then ValidateBinding(SystemData);
end;

destructor TLibraryUpdateJournal.Destroy;
begin
  FBackupGuard.Free; FData.Free;
  if FLease<>0 then CloseHandle(FLease);
  if FDirectoryGuard<>0 then CloseHandle(FDirectoryGuard);
  if FRootGuard<>0 then CloseHandle(FRootGuard);
  inherited;
end;

procedure TLibraryUpdateJournal.ValidateBinding(const SystemData: ISystemData);
var Info: TCollectionInfo;
begin
  if not SameFileName(Text('system'),FSystemFile) or (FileKey(FSystemFile)<>Text('system_key')) then
    raise EReadError.Create('Журнал относится к другому профилю программы.');
  Info:=SystemData.GetCollectionInfo(CollectionID);
  if not SameFileName(Full(Info.DBFileName),Text('target')) or
    not SameFileName(Full(Info.RootFolder),Text('root')) or (FileKey(Text('target'))<>Text('target_key')) then
    raise EReadError.Create('Файл или папка коллекции после сбоя изменились.');
  if not IsSHA(Text('backup_sha256')) then raise EReadError.Create('Повреждена проверка резервной копии.');
  for var Name in TArray<string>.Create('previous_catalogue','previous_personal') do
    if (Text(Name)<>'') and not CanonicalGUID(Text(Name)) then raise EReadError.Create('Повреждена прежняя отметка операции.');
  BackupFile;
end;

procedure TLibraryUpdateJournal.Seal(const Target: IBookCollection; const Check: TProc);
var Digest: ICatalogContentDigest; Data: TJSONObject;
begin
  if not Supports(Target,ICatalogContentDigest,Digest) then raise ENotSupportedException.Create('Нет проверки содержимого каталога.');
  Data:=TJSONObject.Create;
  try
    Data.AddPair('owner',FMetaHash); Data.AddPair('digest_version',TJSONNumber.Create(1));
    Data.AddPair('sha256',Digest.CaptureContentDigest(Check));
    SaveJSON(TPath.Combine(FDirectory,'expected.json'),Data);
  finally Data.Free; end;
end;

function TLibraryUpdateJournal.CatalogueCommitted(const Target: IBookCollection): Boolean;
begin Result:=VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION))=OperationID; end;

function TLibraryUpdateJournal.Done: Boolean;
var Data: TJSONObject;
begin
  Result:=False; if not FileExists(TPath.Combine(FDirectory,'done.json')) then Exit;
  Data:=ReadJSON(TPath.Combine(FDirectory,'done.json'));
  try
    if Field(Data,'owner')<>FMetaHash then raise EReadError.Create('Итог относится к другому журналу.');
    Result:=True;
  finally Data.Free; end;
end;

procedure TLibraryUpdateJournal.Finish(const State: string);
var Data: TJSONObject; Completed, Destination: string; CompletedGuard: THandle;
begin
  if SameFileName(TPath.GetDirectoryName(FDirectory),TPath.Combine(FRoot,'completed')) and Done then Exit;
  if not Done then
  begin
    Data:=TJSONObject.Create;
    try Data.AddPair('owner',FMetaHash); Data.AddPair('state',State); SaveJSON(TPath.Combine(FDirectory,'done.json'),Data);
    finally Data.Free; end;
  end;
{$IFDEF MHL_COMPRESSION_TEST}
  if Assigned(LibraryUpdateRecoveryTestPoint) then LibraryUpdateRecoveryTestPoint('recovery-done',0,0);
{$ENDIF}
  Completed:=TPath.Combine(FRoot,'completed'); EnsureDirectory(Completed); CompletedGuard:=Guard(Completed);
  try
    Destination:=TPath.Combine(Completed,JobPrefix+OperationID);
    if not SameFileName(TPath.GetDirectoryName(Destination),Completed) or
      not SameFileName(TPath.GetDirectoryName(FDirectory),FRoot) then raise EReadError.Create('Неверная папка завершённого журнала.');
    // Windows cannot rename a directory while a file inside it is open,
    // even when that file permits delete sharing. The durable done record
    // makes any concurrent retry metadata-only before we release the lease.
    if FLease<>0 then begin CloseHandle(FLease); FLease:=0; end;
    CloseHandle(FDirectoryGuard); FDirectoryGuard:=0;
{$IFDEF MHL_COMPRESSION_TEST}
    if Assigned(LibraryUpdateRecoveryTestPoint) then LibraryUpdateRecoveryTestPoint('recovery-lease-released',0,0);
{$ENDIF}
    if not MoveFileEx(PChar(DeletionNativePath(FDirectory)),PChar(DeletionNativePath(Destination)),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    FDirectory:=Destination;
{$IFDEF MHL_COMPRESSION_TEST}
    if Assigned(LibraryUpdateRecoveryTestPoint) then LibraryUpdateRecoveryTestPoint('recovery-moved',0,0);
{$ENDIF}
  finally CloseHandle(CompletedGuard); end;
end;

function TLibraryUpdateJournal.CompleteAttempt(const Target: IBookCollection; const SystemData: ISystemData;
  PersonalRemapComplete: Boolean): Boolean;
var Catalogue, Personal: string;
begin
  Catalogue:=VarToStr(Target.GetProperty(PROP_LIBRARY_UPDATE_TRANSACTION)); Personal:=PersonalWitness(SystemData,CollectionID);
  Result:=False;
  if (Catalogue=OperationID) and (Personal=OperationID) then
  begin
    if not PersonalRemapComplete then SystemData.RemapCollectionBookIDs(CollectionID,False);
    Finish('committed'); Exit(True);
  end;
  if (Catalogue=Text('previous_catalogue')) and (Personal=Text('previous_personal')) then
  begin Finish('rolled-back'); Result:=True; end;
  if (Catalogue<>OperationID) and (Catalogue<>'') and (Catalogue=Personal) then
  begin Finish('superseded'); Result:=True; end;
end;

procedure TLibraryUpdateJournal.Recover(const SystemData: ISystemData; const Check: TProc);
var Database: TSQLiteDatabase; Catalogue, Personal, ExpectedSHA: string; Expected: TJSONObject;
  GuardCheck: TProc;
  Metadata: IMetadataCollectionRootGuard;
begin
  GuardCheck:=procedure begin
    RecoverySpace(FRoot); RecoverySpace(TPath.GetDirectoryName(Text('target')));
    if Assigned(Check) then Check;
  end;
  if Done then begin Finish('finished'); Exit; end;
  ValidateBinding(SystemData);
  GuardCheck;
  if not Supports(SystemData,IMetadataCollectionRootGuard,Metadata) then
    raise ENotSupportedException.Create('Нет защиты личных данных для восстановления.');
  Metadata.BeginMetadataRootGuard;
  try
    Personal:=PersonalWitness(SystemData,CollectionID);
    Database:=TSQLiteDatabase.Create(Text('target'));
    try
      if not SameText(Database.QuerySingleString('PRAGMA locking_mode=EXCLUSIVE'),'exclusive') then
        raise EReadError.Create('Не удалось защитить каталог на время восстановления.');
      Database.Start('','EXCLUSIVE');
      try
        Catalogue:=RawWitness(Database);
        if (Catalogue=OperationID) and (Personal=Text('previous_personal')) then
        begin
          Expected:=ReadJSON(TPath.Combine(FDirectory,'expected.json'));
          try
            if (Field(Expected,'owner')<>FMetaHash) or not (Expected.GetValue('digest_version') is TJSONNumber) or
              (TJSONNumber(Expected.GetValue('digest_version')).Value<>'1') then raise EReadError.Create('Неверная проверка подготовленного каталога.');
            ExpectedSHA:=Field(Expected,'sha256');
          finally Expected.Free; end;
          if not IsSHA(ExpectedSHA) or (CatalogContentDigest(Database,GuardCheck)<>ExpectedSHA) then
            raise EReadError.Create('После сбоя содержимое каталога изменилось. Автоматический откат остановлен.');
          FileKey(BackupFile); FBackupGuard:=TFileStream.Create(DeletionNativePath(BackupFile),fmOpenRead or fmShareDenyWrite);
          if StreamSHA(FBackupGuard,GuardCheck)<>Text('backup_sha256') then raise EReadError.Create('Резервная копия повреждена или заменена.');
          RecoverySpace(TPath.GetDirectoryName(Text('target')),UInt64(FBackupGuard.Size));
          Database.Rollback;
          // Exclusive locking mode retains the file lock across this restore.
          Database.RestoreFrom(BackupFile,procedure(Copied,Total:Integer) begin
            GuardCheck;
{$IFDEF MHL_COMPRESSION_TEST}
            if Assigned(LibraryUpdateRecoveryTestPoint) and (Copied<Total) then
              LibraryUpdateRecoveryTestPoint('recovery-restore-step',Copied,Total);
{$ENDIF}
          end);
{$IFDEF MHL_COMPRESSION_TEST}
          if Assigned(LibraryUpdateRecoveryTestPoint) then LibraryUpdateRecoveryTestPoint('recovery-restored',0,0);
{$ENDIF}
          if RawWitness(Database)<>Text('previous_catalogue') then raise EReadError.Create('Не восстановлена прежняя версия каталога.');
        end
        else if not (((Catalogue=OperationID) and (Personal=OperationID)) or
          ((Catalogue=Text('previous_catalogue')) and (Personal=Text('previous_personal'))) or
          ((Catalogue<>OperationID) and (Catalogue<>'') and (Catalogue=Personal))) then
          raise EReadError.Create('Отметки каталога и личных данных не соответствуют журналу.');
      finally if Database.InTransaction then Database.Rollback; end;
    finally Database.Free; end;
  finally Metadata.EndMetadataRootGuard; end;
  SystemData.ClearCollectionCache;
  SystemData.RemapCollectionBookIDs(CollectionID,False);
{$IFDEF MHL_COMPRESSION_TEST}
  if Assigned(LibraryUpdateRecoveryTestPoint) then LibraryUpdateRecoveryTestPoint('recovery-remapped',0,0);
{$ENDIF}
  Finish('recovered');
end;

class function TLibraryUpdateJournal.HasPendingForCollection(const Root: string; ID: Integer): Boolean;
var Data: TJSONObject; Value: TJSONValue; FoundID: Integer;
begin
  Result:=False;
  for var Directory in Pending(Root) do
  begin
    Data:=nil;
    try
      try
        Data:=ReadJSON(TPath.Combine(Directory,'job.json')); Value:=Data.GetValue('collection');
        if not (Value is TJSONNumber) or not TryStrToInt(TJSONNumber(Value).Value,FoundID) then Exit(True);
        if FoundID=ID then Exit(True);
      except on E:Exception do Exit(True); end;
    finally Data.Free; end;
  end;
end;

class function TLibraryUpdateJournal.Pending(const Root: string): TArray<string>;
var Found: TList<string>; Name: string;
begin
  Result:=nil; if not DirectoryExists(Root) then Exit;
  Found:=TList<string>.Create;
  try
    for var Directory in TDirectory.GetDirectories(Root,JobPrefix+'*',TSearchOption.soTopDirectoryOnly) do
    begin
      Name:=TPath.GetFileName(Directory);
      if CanonicalGUID(Copy(Name,Length(JobPrefix)+1,MaxInt)) and FileExists(TPath.Combine(Directory,'job.json')) then Found.Add(Directory);
    end;
    Result:=Found.ToArray;
  finally Found.Free; end;
end;

class procedure TLibraryUpdateJournal.RecoverAll(const Root, BackupRoot, SystemFile: string;
  const SystemData: ISystemData; const Warnings: TStrings; const Check: TProc);
var Journal: TLibraryUpdateJournal;
begin
  for var Directory in Pending(Root) do
  begin
    Journal:=nil;
    try
      try
        if Assigned(Check) then Check;
        Journal:=TLibraryUpdateJournal.OpenExisting(Root,BackupRoot,SystemFile,Directory,SystemData);
        Journal.Recover(SystemData,Check);
      except on E:Exception do if Assigned(Warnings) then Warnings.Add(Directory+': '+E.Message); end;
    finally Journal.Free; end;
  end;
end;

end.
