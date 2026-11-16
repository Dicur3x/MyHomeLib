unit unit_CollectionTransferCacheInstallation;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Winapi.Windows, unit_CollectionTransferCacheSnapshot;

type
  TTransferCachePathGuard=class
  private
    FHandle:THandle;
    FPath,FKey:string;
  public
    constructor Create(const Path:string; RenameAccess:Boolean=False);
    destructor Destroy; override;
    procedure RenameTo(const Destination:string);
    property Key:string read FKey;
    property Path:string read FPath;
  end;

  // Materializes an independently bound work snapshot in a new version folder.
  // The caller commits every ownership/ready/published callback in its personal
  // registry. This class never changes settings or removes an old cache.
  TTransferCacheInstallation=class
  private
    FParents:TObjectList<TTransferCachePathGuard>;
    FDirectoryGuard:TTransferCachePathGuard;
    FHandles:TList<THandle>;
    FProof:TJSONObject;
    FNames:TDictionary<string,Boolean>;
    FDirectory,FDestination,FBinding,FProofSHA,FDataRootKey:string;
    FCheck:TProc;
    FRemember:TTransferCacheRemember;
    constructor Initialize(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA,DataRootKey:string;
      const Remember:TTransferCacheRemember; const Cancelled:TProc);
    procedure Check;
    procedure Point(const Stage:string);
    procedure Space(Required:UInt64=0);
    procedure Remember(const Stage,Path,Key:string);
    procedure PinParents;
    procedure CopyFiles(Snapshot:TTransferCacheSnapshot);
    procedure OpenFiles(RenamePending:Boolean);
    procedure CheckFiles(RenamePending:Boolean=False);
    procedure Publish;
  public
    class function Binding(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA:string):string; static;
    class function CreateNew(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,DataRootKey:string;
      Snapshot:TTransferCacheSnapshot; const Remember:TTransferCacheRemember;
      const Cancelled:TProc=nil):TTransferCacheInstallation; static;
    class function Recover(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA,DataRootKey,
      ProofJSON,ProofSHA:string; AlreadyPublished:Boolean; const Remember:TTransferCacheRemember;
      const Cancelled:TProc=nil):TTransferCacheInstallation; static;
    destructor Destroy; override;
    procedure CheckUnchanged;
    function ProofJSON:string;
    property Directory:string read FDirectory;
    property ProofSHA:string read FProofSHA;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferCacheInstallationTestPoint:TProc<string>;
{$ENDIF}

implementation

uses System.IOUtils, System.Hash, unit_Settings, dm_user, unit_CatalogSources,
  unit_CollectionTransferPlan, unit_ZipMemberDeletion;

const Kind='HomeLibre installed cache v1'; Prefix='transfer-cache-';

type TCacheRenameInfo=record
  Flags:DWORD;
  RootDirectory:THandle;
  FileNameLength:DWORD;
  FileName:array[0..0] of WideChar;
end;
PCacheRenameInfo=^TCacheRenameInfo;

function CacheSetFileInformation(Handle:THandle; InfoClass:Integer; Data:Pointer; Bytes:DWORD):BOOL;
  stdcall; external kernel32 name 'SetFileInformationByHandle';

function FileKey(Handle:THandle; Directory:Boolean=False):string;
begin
  var Info:TByHandleFileInformation;
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY<>0)<>Directory) or
    (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
    (not Directory and (Info.nNumberOfLinks<>1)) then raise EReadError.Create('Неподходящий объект новой версии кэша.');
  Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
end;

function Present(const Path:string):Boolean;
begin
  Result:=GetFileAttributes(PChar(DeletionNativePath(Path)))<>INVALID_FILE_ATTRIBUTES;
  if not Result and not (GetLastError in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND]) then RaiseLastOSError;
end;

function Hash(Stream:TStream; const Check:TProc):string;
begin
  var Digest:=THashSHA2.Create; var Bytes:TBytes; SetLength(Bytes,1024*1024); Stream.Position:=0;
  repeat
    if Assigned(Check) then Check;
    var Count:=Stream.Read(Bytes[0],Length(Bytes)); if Count=0 then Break; Digest.Update(Bytes,Count);
  until False;
  Result:=Digest.HashAsString; Stream.Position:=0;
end;

constructor TTransferCachePathGuard.Create(const Path:string; RenameAccess:Boolean);
begin
  inherited Create; FPath:=ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  var Access:DWORD:=FILE_READ_ATTRIBUTES; if RenameAccess then Access:=Access or Winapi.Windows._DELETE;
  FHandle:=CreateFile(PChar(DeletionNativePath(FPath)),Access,FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FHandle=INVALID_HANDLE_VALUE then begin FHandle:=0; RaiseLastOSError; end;
  FKey:=FileKey(FHandle,True);
  if not SameFileName(TransferCanonicalDirectory(FPath),IncludeTrailingPathDelimiter(FPath)) then
    raise EReadError.Create('Папка версии кэша перенаправлена: '+Path);
end;

destructor TTransferCachePathGuard.Destroy;
begin if FHandle<>0 then CloseHandle(FHandle); inherited; end;

procedure TTransferCachePathGuard.RenameTo(const Destination:string);
begin
  if FileKey(FHandle,True)<>FKey then raise EReadError.Create('Папка версии кэша заменена перед публикацией.');
  var Full:=DeletionNativePath(ExpandFileName(Destination)); var Buffer:TBytes;
  SetLength(Buffer,SizeOf(TCacheRenameInfo)+Length(Full)*SizeOf(WideChar)); FillChar(Buffer[0],Length(Buffer),0);
  var Info:PCacheRenameInfo; Info:=Pointer(@Buffer[0]); Info.FileNameLength:=Length(Full)*SizeOf(WideChar);
  Move(PChar(Full)^,Info.FileName[0],Info.FileNameLength);
  if not CacheSetFileInformation(FHandle,3,Info,Length(Buffer)) then
    RaiseLastOSError(GetLastError,'Переименование новой версии кэша');
  FPath:=ExcludeTrailingPathDelimiter(ExpandFileName(Destination));
  if not SameFileName(TransferCanonicalDirectory(FPath),IncludeTrailingPathDelimiter(FPath)) then
    raise EReadError.Create('Опубликованная папка кэша перенаправлена.');
end;

class function TTransferCacheInstallation.Binding(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA:string):string;
begin Result:=THashSHA2.GetHashString(Kind+#0+ReviewSHA+#0+IntentSHA+#0+JobJSON+#0+InputsJSON+#0+SnapshotSHA); end;

constructor TTransferCacheInstallation.Initialize(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA,DataRootKey:string;
  const Remember:TTransferCacheRemember; const Cancelled:TProc);
begin
  inherited Create; FCheck:=Cancelled; FRemember:=Remember; FDataRootKey:=DataRootKey;
  if (Length(ReviewSHA)<>64) or (Length(IntentSHA)<>64) or (Length(SnapshotSHA)<>64) or (Length(DataRootKey)<>25) or
    (Length(JobJSON)+Length(InputsJSON)>16*1024*1024) then raise EArgumentException.Create('Нет независимой привязки постоянной версии кэша.');
  FParents:=TObjectList<TTransferCachePathGuard>.Create(True); FHandles:=TList<THandle>.Create;
  FNames:=TDictionary<string,Boolean>.Create; FNames.Add('catalog.hlc2',True);
  var Job:=TJSONObject.ParseJSONValue(JobJSON) as TJSONObject;
  var Inputs:=TJSONObject.ParseJSONValue(InputsJSON) as TJSONArray;
  try
    if (Job=nil) or (Inputs=nil) or (Inputs.Count>16384) then raise EReadError.Create('Не прочитано задание публикации кэша.');
    var Source:=Default(TCatalogSource); Source.ID:=Job.GetValue<string>('source'); Source.CacheVersion:=Job.GetValue<string>('after_version');
    if Source.CacheVersion='' then raise EReadError.Create('Нет новой версии кэша.');
    var Target:=ExpandFileName(Source.CacheFile); FDestination:=ExcludeTrailingPathDelimiter(ExtractFilePath(Target));
    Source.CacheVersion:=Job.GetValue<string>('before_version');
    if (Target<>Job.GetValue<string>('after_file')) or
      (ExpandFileName(Source.CacheFile)<>Job.GetValue<string>('before_file')) or SameFileName(Target,Source.CacheFile) then
      raise EReadError.Create('Публикация не совпала с выбранными версиями кэша.');
    for var Value in Inputs do
    begin
      var Row:=Value as TJSONObject; var FileName:=Row.GetValue<string>('target_file'); var Name:=ExtractFileName(FileName);
      if (Row.GetValue<string>('job')<>Job.GetValue<string>('job')) or (Name='') or (Pos(':',Name)>0) or
        not SameFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(FileName)),FDestination) or
        FNames.ContainsKey(LowerCase(Name)) then raise EReadError.Create('Повторный или посторонний файл постоянного кэша.');
      FNames.Add(LowerCase(Name),True);
    end;
    FBinding:=Binding(ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA);
  finally Inputs.Free; Job.Free; end;
  PinParents;
end;

destructor TTransferCacheInstallation.Destroy;
begin
  if FHandles<>nil then for var Handle in FHandles do CloseHandle(Handle);
  FHandles.Free; FDirectoryGuard.Free; FParents.Free; FNames.Free; FProof.Free; inherited;
end;

procedure TTransferCacheInstallation.Check;
begin if Assigned(FCheck) then FCheck; Space; end;

procedure TTransferCacheInstallation.Point(const Stage:string);
begin
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferCacheInstallationTestPoint) then TransferCacheInstallationTestPoint(Stage);
{$ENDIF}
  Check;
end;

procedure TTransferCacheInstallation.Space(Required:UInt64);
begin
  var Available,Capacity:UInt64; var Root:=TPath.GetPathRoot(GetEnvironmentVariable('SystemRoot'));
  if not GetDiskFreeSpaceEx(PChar(Root),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then raise EWriteError.Create('Сохраните 8 ГБ свободного места на системном диске.');
  var Serial,MaxName,Flags:DWORD;
  if not GetVolumeInformation(PChar(Root),nil,0,@Serial,MaxName,Flags,nil,0) then RaiseLastOSError;
  var Reserve:=UInt64(512)*1024*1024;
  if SameText(Copy(FDataRootKey,1,8),IntToHex(Serial,8)) then Reserve:=UInt64(8)*1024*1024*1024;
  if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(Settings.DataPath)),Available,Capacity,nil) then RaiseLastOSError;
  if (Available<Required) or (Available-Required<Reserve) then
    raise EWriteError.Create('Недостаточно места для постоянной версии кэша и обязательного резерва.');
end;

procedure TTransferCacheInstallation.PinParents;
begin
  var Root:=ExcludeTrailingPathDelimiter(ExpandFileName(Settings.DataPath));
  var Guard:=TTransferCachePathGuard.Create(Root); FParents.Add(Guard);
  if Guard.Key<>FDataRootKey then raise EReadError.Create('Папка данных заменена после намерения переноса.');
  var Parent:=ExcludeTrailingPathDelimiter(ExtractFilePath(FDestination));
  if not Parent.StartsWith(IncludeTrailingPathDelimiter(Root),True) then raise EReadError.Create('Версия кэша выходит из папки данных.');
  var Relative:=Copy(Parent,Length(Root)+2,MaxInt); var Current:=Root;
  for var Part in Relative.Split(['\'],TStringSplitOptions.ExcludeEmpty) do
  begin
    Check; Current:=TPath.Combine(Current,Part);
    if not Present(Current) then if not CreateDirectory(PChar(DeletionNativePath(Current)),nil) then RaiseLastOSError;
    FParents.Add(TTransferCachePathGuard.Create(Current));
  end;
end;

procedure TTransferCacheInstallation.Remember(const Stage,Path,Key:string);
begin
  Check; if not Assigned(FRemember) then raise EReadError.Create('Нет независимой записи установки кэша.');
  var Row:=TJSONObject.Create;
  try
    Row.AddPair('binding',FBinding); Row.AddPair('directory',FProof.GetValue<string>('stage_directory'));
    Row.AddPair('directory_key',FDirectoryGuard.Key); Row.AddPair('destination',FDestination);
    Row.AddPair('path',Path); Row.AddPair('key',Key);
    if Stage='install-ready' then begin Row.AddPair('proof',FProof.ToJSON); Row.AddPair('proof_sha256',FProofSHA); end;
    FRemember(Stage,Row.ToJSON);
  finally Row.Free; end;
  Point(Stage);
end;

procedure TTransferCacheInstallation.CopyFiles(Snapshot:TTransferCacheSnapshot);
begin
  Snapshot.CheckUnchanged; var Original:=TJSONObject.ParseJSONValue(Snapshot.ProofJSON) as TJSONObject;
  try
    var Files:=Original.GetValue<TJSONArray>('files'); var Total:UInt64:=0;
    if (Files=nil) or (Files.Count<>FNames.Count) then raise EReadError.Create('Неполный исходный снимок установки.');
    for var Value in Files do
    begin var Bytes:=(Value as TJSONObject).GetValue<Int64>('bytes');
      if (Bytes<0) or (UInt64(Bytes)>High(UInt64)-Total) then raise EReadError.Create('Неверный размер снимка установки.');
      Inc(Total,UInt64(Bytes));
    end;
    Space(Total); var Seen:=TDictionary<string,Boolean>.Create;
    try for var Value in Files do
      begin
        Check; var Row:=Value as TJSONObject; var Name:=Row.GetValue<string>('name');
        if not FNames.ContainsKey(LowerCase(Name)) or Seen.ContainsKey(LowerCase(Name)) or
          (ExtractFileName(Name)<>Name) then raise EReadError.Create('Посторонний файл исходного снимка.');
        Seen.Add(LowerCase(Name),True);
        var Input:=TFileStream.Create(DeletionNativePath(TPath.Combine(Snapshot.Directory,Name)),fmOpenRead or fmShareDenyWrite);
        try
          if (FileKey(Input.Handle)<>Row.GetValue<string>('key')) or (Input.Size<>Row.GetValue<Int64>('bytes')) then
            raise EReadError.Create('Файл исходного снимка заменён.');
          var Path:=TPath.Combine(FDirectory,Name);
          var Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_READ or GENERIC_WRITE,
            FILE_SHARE_READ or FILE_SHARE_DELETE,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
          if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
          FHandles.Add(Handle); var Key:=FileKey(Handle); Remember('install-file-reserved',Path,Key);
          var Output:=THandleStream.Create(Handle);
          try
            var Buffer:TBytes; SetLength(Buffer,1024*1024);
            repeat
              Check; Space(Total); var Count:=Input.Read(Buffer[0],Length(Buffer)); if Count=0 then Break;
              Output.WriteBuffer(Buffer[0],Count); Dec(Total,UInt64(Count));
            until False;
            if not FlushFileBuffers(Handle) then RaiseLastOSError;
            if (Output.Size<>Input.Size) or not SameText(Hash(Output,Check),Row.GetValue<string>('sha256')) or
              not SameText(Hash(Input,Check),Row.GetValue<string>('sha256')) then
              raise EReadError.Create('Копия постоянного кэша не совпала со снимком.');
            var Saved:=TJSONObject.Create; Saved.AddPair('name',Name); Saved.AddPair('key',Key);
            Saved.AddPair('bytes',TJSONNumber.Create(Output.Size)); Saved.AddPair('sha256',Row.GetValue<string>('sha256'));
            FProof.GetValue<TJSONArray>('files').AddElement(Saved);
          finally Output.Free; end;
        finally Input.Free; end;
      end;
    finally Seen.Free; end;
    Snapshot.CheckUnchanged;
  finally Original.Free; end;
end;

procedure TTransferCacheInstallation.OpenFiles(RenamePending:Boolean);
begin
  for var Value in FProof.GetValue<TJSONArray>('files') do
  begin
    Check; var Path:=TPath.Combine(FDirectory,(Value as TJSONObject).GetValue<string>('name'));
    var Share:DWORD:=FILE_SHARE_READ; if RenamePending then Share:=Share or FILE_SHARE_DELETE;
    var Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_READ,Share,nil,OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
    if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
    FHandles.Add(Handle);
  end;
end;

procedure TTransferCacheInstallation.CheckFiles(RenamePending:Boolean);
begin
  Check;
  if (FProof=nil) or (THashSHA2.GetHashString(FProof.ToJSON)<>FProofSHA) or
    (FProof.GetValue<string>('binding')<>FBinding) or (FDirectoryGuard.Key<>FProof.GetValue<string>('directory_key')) then
    raise EReadError.Create('Изменено независимое подтверждение установленного кэша.');
  var Files:=FProof.GetValue<TJSONArray>('files');
  if (Files=nil) or (Files.Count<>FNames.Count) then raise EReadError.Create('Неполная постоянная версия кэша.');
  var Seen:=TDictionary<string,Boolean>.Create;
  try
    for var Value in Files do
    begin
      Check; var Row:=Value as TJSONObject; var Name:=Row.GetValue<string>('name');
      if not FNames.ContainsKey(LowerCase(Name)) or Seen.ContainsKey(LowerCase(Name)) or
        (ExtractFileName(Name)<>Name) then raise EReadError.Create('Неверный состав установленного кэша.');
      Seen.Add(LowerCase(Name),True);
      // Existing write handles from creation remain exclusive against other
      // writers. Read handles here share those own writes but deny replacement.
      var Path:=TPath.Combine(FDirectory,Name);
      var Share:DWORD:=FILE_SHARE_READ or FILE_SHARE_WRITE; if RenamePending then Share:=Share or FILE_SHARE_DELETE;
      var Handle:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_READ,Share,
        nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
      if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
      FHandles.Add(Handle); var Stream:=THandleStream.Create(Handle);
      try
        var Canonical,Identity:string; var Bytes:Int64; TransferReadFileState(Path,Canonical,Identity,Bytes);
        if not SameFileName(Canonical,Path) or (FileKey(Handle)<>Copy(Identity,1,25)) or
          (FileKey(Handle)<>Row.GetValue<string>('key')) or (Stream.Size<>Row.GetValue<Int64>('bytes')) or
          not SameText(Hash(Stream,Check),Row.GetValue<string>('sha256')) then raise EReadError.Create('Изменён файл установленного кэша.');
      finally Stream.Free; end;
    end;
    var Entries:=TDirectory.GetFileSystemEntries(DeletionNativePath(FDirectory));
    if Length(Entries)<>Files.Count then raise EReadError.Create('В новой версии кэша появились посторонние файлы.');
    for var Entry in Entries do if not Seen.ContainsKey(LowerCase(ExtractFileName(Entry))) then
      raise EReadError.Create('В новой версии кэша появился посторонний объект.');
  finally Seen.Free; end;
end;

procedure TTransferCacheInstallation.Publish;
begin
  CheckFiles(True);
  Point('install-before-rename');
  // NTFS directory rename requires its child files to be closed. The ready
  // proof is already independently committed. Rename this exact directory
  // handle without replacement, then acquire strict named-file leases and
  // recheck every key/hash before recording publication or exposing settings.
  for var Handle in FHandles do CloseHandle(Handle); FHandles.Clear;
  FDirectoryGuard.RenameTo(FDestination); FDirectory:=FDestination;
  Point('install-after-rename'); OpenFiles(False); CheckFiles;
  Remember('install-published',FDirectory,FDirectoryGuard.Key);
end;

class function TTransferCacheInstallation.CreateNew(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,DataRootKey:string;
  Snapshot:TTransferCacheSnapshot; const Remember:TTransferCacheRemember; const Cancelled:TProc):TTransferCacheInstallation;
begin
  if Snapshot=nil then raise EArgumentException.Create('Нет подготовленного снимка кэша.');
  Result:=TTransferCacheInstallation.Initialize(ReviewSHA,IntentSHA,JobJSON,InputsJSON,Snapshot.ReadySHA,DataRootKey,Remember,Cancelled);
  try
    if Present(Result.FDestination) then raise EReadError.Create('Путь новой версии кэша уже занят; существующая папка сохранена.');
    Result.FDirectory:=TPath.Combine(ExtractFileDir(Result.FDestination),Prefix+TGUID.NewGuid.ToString);
    if not CreateDirectory(PChar(DeletionNativePath(Result.FDirectory)),nil) then RaiseLastOSError;
    Result.FDirectoryGuard:=TTransferCachePathGuard.Create(Result.FDirectory,True);
    Result.FProof:=TJSONObject.Create; Result.FProof.AddPair('kind',Kind); Result.FProof.AddPair('binding',Result.FBinding);
    Result.FProof.AddPair('stage_directory',Result.FDirectory); Result.FProof.AddPair('directory_key',Result.FDirectoryGuard.Key);
    Result.FProof.AddPair('destination',Result.FDestination); Result.FProof.AddPair('files',TJSONArray.Create);
    Result.Remember('install-directory-created',Result.FDirectory,Result.FDirectoryGuard.Key);
    Result.CopyFiles(Snapshot); Result.FProofSHA:=THashSHA2.GetHashString(Result.FProof.ToJSON);
    if Length(Result.FProof.ToJSON)>16*1024*1024 then raise EReadError.Create('Слишком большое подтверждение установки кэша.');
    Result.CheckFiles(True); Result.Remember('install-ready',Result.FDirectory,Result.FProofSHA); Result.Publish;
  except Result.Free; raise; end;
end;

class function TTransferCacheInstallation.Recover(const ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA,DataRootKey,
  ProofJSON,ProofSHA:string; AlreadyPublished:Boolean; const Remember:TTransferCacheRemember;
  const Cancelled:TProc):TTransferCacheInstallation;
begin
  Result:=TTransferCacheInstallation.Initialize(ReviewSHA,IntentSHA,JobJSON,InputsJSON,SnapshotSHA,DataRootKey,Remember,Cancelled);
  try
    if (Length(ProofJSON)>16*1024*1024) or (Length(ProofSHA)<>64) or
      (THashSHA2.GetHashString(ProofJSON)<>ProofSHA) then raise EReadError.Create('Изменено подтверждение постоянной версии кэша.');
    Result.FProof:=TJSONObject.ParseJSONValue(ProofJSON) as TJSONObject; Result.FProofSHA:=ProofSHA;
    if (Result.FProof=nil) or (Result.FProof.GetValue<string>('kind')<>Kind) or
      (Result.FProof.GetValue<string>('binding')<>Result.FBinding) or
      (Result.FProof.GetValue<string>('destination')<>Result.FDestination) then raise EReadError.Create('Подтверждение относится к другой версии кэша.');
    var Stage:=Result.FProof.GetValue<string>('stage_directory'); var Name:=ExtractFileName(Stage);
    if not SameFileName(ExtractFileDir(Stage),ExtractFileDir(Result.FDestination)) or
      not Name.StartsWith(Prefix) or (Name<>Prefix+StringToGUID(Copy(Name,Length(Prefix)+1,MaxInt)).ToString) then
      raise EReadError.Create('Подготовка постоянного кэша находится вне назначения.');
    var Published:=Present(Result.FDestination);
    if AlreadyPublished and not Published then raise EReadError.Create('Опубликованная версия кэша исчезла.');
    Result.FDirectory:=Stage; if Published then Result.FDirectory:=Result.FDestination;
    Result.FDirectoryGuard:=TTransferCachePathGuard.Create(Result.FDirectory,not Published);
    if Result.FDirectoryGuard.Key<>Result.FProof.GetValue<string>('directory_key') then raise EReadError.Create('Папка постоянного кэша заменена.');
    Result.OpenFiles(not Published);
    if Published then Result.CheckFiles
    else
    begin
      // Keep the pre-rename named-file leases share-delete, but deny writes.
      // Post-rename verification acquires the strict replacement guards.
      Result.Point('install-recover-ready'); Result.Publish;
    end;
    if Published and not AlreadyPublished then Result.Remember('install-published',Result.FDirectory,Result.FDirectoryGuard.Key);
  except Result.Free; raise; end;
end;

procedure TTransferCacheInstallation.CheckUnchanged;
begin CheckFiles; end;

function TTransferCacheInstallation.ProofJSON:string;
begin Result:=FProof.ToJSON; end;

end.
