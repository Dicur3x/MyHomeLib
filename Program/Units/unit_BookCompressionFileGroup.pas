unit unit_BookCompressionFileGroup;

interface

uses System.SysUtils, System.Classes, System.JSON, unit_ZipMemberDeletion;

type
  // The owner persists the catalogue receipt and this ManifestSHA256 before
  // Execute. All file journals become durable before the first source write.
  TBookCompressionFileGroup = class
  private
    FDirectory, FContext, FManifestSHA256: string;
    FData: TJSONObject;
    FEngines: TArray<TZipMemberDeletion>;
    FReadLeases: TArray<TFileStream>;
    FChangeLeases: TArray<IInterface>;
    FLease, FGuard: THandle;
    FCompleted: Boolean;
    procedure OpenLease;
    procedure Validate;
    function Files: TJSONArray;
    function Item(Index: Integer): TJSONObject;
    function JournalRoot(Index: Integer): string;
    function FindJournal(Index: Integer): string;
    procedure CheckMarker(const Name: string);
    procedure OpenEngines(Completed: Boolean);
    procedure CheckResults;
    procedure Acknowledge(const Fault: TProc<string> = nil);
    class function Manifest(const FilesJSON, ContextSHA256: string): TJSONObject; static;
  public
    constructor CreatePrepared(const Directory, FilesJSON, ContextSHA256: string;
      const Cancelled: TFunc<Boolean> = nil; const Progress: TZipDeleteProgress = nil;
      const Fault: TProc<string> = nil);
    constructor OpenExisting(const Directory, ExpectedManifestSHA256, ContextSHA256: string);
    destructor Destroy; override;
    class function ComputeManifestSHA256(const FilesJSON, ContextSHA256: string): string; static;
    procedure Execute(const CommitMetadata: TProc<TArray<TZipMemberDeletion>>;
      const CheckMetadata: TProc; const Cancelled: TFunc<Boolean> = nil;
      const Progress: TZipDeleteProgress = nil; const Fault: TProc<string> = nil);
    // The owner refreshes its views and retains its own completion marker
    // through Forget, just as for a single-file compression job.
    procedure Forget;
    property ManifestSHA256: string read FManifestSHA256;
    property Completed: Boolean read FCompleted;
  end;

implementation

uses Winapi.Windows, System.IOUtils, System.Hash, System.Generics.Collections,
  unit_AtomicIniFile, unit_MHLArchiveBusy;

function Text(Data: TJSONObject; const Name: string): string;
begin
  if not (Data.GetValue(Name) is TJSONString) then
    raise EReadError.Create('Неполное задание связанных файлов сжатия.');
  Result:=Data.GetValue<string>(Name);
end;

function IsHash(const Value: string): Boolean;
begin
  Result:=Length(Value)=64;
  for var C in Value do if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then Exit(False);
end;

function HashStream(Stream: TStream): string;
begin
  Stream.Position:=0;
  Result:=THashSHA2.GetHashString(Stream);
end;

function ReadText(const Name: string): string;
var Stream: TFileStream; Buffer: TBytes;
begin
  Stream:=TFileStream.Create(DeletionNativePath(Name),fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size<=0) or (Stream.Size>1024*1024) then
      raise EReadError.Create('Неверный размер журнала связанных файлов.');
    SetLength(Buffer,Integer(Stream.Size)); Stream.ReadBuffer(Buffer[0],Length(Buffer));
    Result:=TEncoding.UTF8.GetString(Buffer);
  finally Stream.Free; end;
end;

procedure SaveText(const Name, Value: string);
var Stream: TStringStream;
begin
  Stream:=TStringStream.Create(Value,TEncoding.UTF8);
  try SaveStreamAtomically(Stream,DeletionNativePath(Name)); finally Stream.Free; end;
end;

procedure TBookCompressionFileGroup.OpenLease;
var Info: TByHandleFileInformation; FinalName: TArray<Char>; Count: DWORD; Actual: string;
begin
  FGuard:=CreateFile(PChar(DeletionNativePath(FDirectory)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FGuard=INVALID_HANDLE_VALUE then begin FGuard:=0; RaiseLastOSError; end;
  if not GetFileInformationByHandle(FGuard,Info) then RaiseLastOSError;
  if (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0 then
    raise EReadError.Create('Папка связанных файлов заменена ссылкой.');
  SetLength(FinalName,32768);
  Count:=GetFinalPathNameByHandle(FGuard,@FinalName[0],Length(FinalName),0);
  if (Count=0) or (Count>=DWORD(Length(FinalName))) then RaiseLastOSError;
  SetString(Actual,PChar(@FinalName[0]),Count);
  if not SameFileName(Actual,DeletionNativePath(FDirectory)) then
    raise EReadError.Create('Путь связанных файлов проходит через ссылку.');
  FLease:=CreateFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'group.lock'))),
    GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then begin FLease:=0; RaiseLastOSError; end;
  if not GetFileInformationByHandle(FLease,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or (Info.nFileSizeLow<>0) or (Info.nFileSizeHigh<>0) or
    ((Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0) then
    raise EReadError.Create('Повреждена блокировка связанных файлов.');
end;

function TBookCompressionFileGroup.Files: TJSONArray;
begin Result:=FData.GetValue<TJSONArray>('files'); end;

function TBookCompressionFileGroup.Item(Index: Integer): TJSONObject;
begin Result:=TJSONObject(Files.Items[Index]); end;

function TBookCompressionFileGroup.JournalRoot(Index: Integer): string;
begin Result:=TPath.Combine(FDirectory,'file-'+IntToStr(Index)); end;

procedure TBookCompressionFileGroup.Validate;
var SeenPaths, SeenKeys: TDictionary<string,Byte>; Data: TJSONObject; Source, Candidate, Identity: string;
begin
  if not Assigned(FData) or (Text(FData,'kind')<>'HomeLibre compression file group') or
    not (FData.GetValue('version') is TJSONNumber) or (FData.GetValue<Integer>('version')<>1) or
    (Text(FData,'context_sha256')<>FContext) or not IsHash(FContext) or
    not (FData.GetValue('files') is TJSONArray) or (Files.Count<1) or (Files.Count>3) then
    raise EReadError.Create('Неверная привязка связанных файлов сжатия.');
  SeenPaths:=TDictionary<string,Byte>.Create; SeenKeys:=TDictionary<string,Byte>.Create;
  try
    for var Value in Files do
    begin
      if not (Value is TJSONObject) then raise EReadError.Create('Нет сведений о связанном файле.');
      Data:=TJSONObject(Value); Source:=Text(Data,'source'); Candidate:=Text(Data,'candidate');
      Identity:=Text(Data,'source_identity');
      if (Source='') or (Source<>ExpandFileName(Source)) or (Candidate='') or
        (Candidate<>ExpandFileName(Candidate)) or SameFileName(Source,Candidate) or
        Source.StartsWith(IncludeTrailingPathDelimiter(FDirectory),True) or
        Candidate.StartsWith(IncludeTrailingPathDelimiter(FDirectory),True) or
        SeenPaths.ContainsKey(UpperCase(Source)) or SeenPaths.ContainsKey(UpperCase(Candidate)) or
        (Length(Identity)<>59) or SeenKeys.ContainsKey(UpperCase(Copy(Identity,1,25))) or
        not IsHash(Text(Data,'source_sha256')) or not IsHash(Text(Data,'result_sha256')) then
        raise EReadError.Create('Связанные файлы повторяются или имеют неполную привязку.');
      SeenPaths.Add(UpperCase(Source),0); SeenPaths.Add(UpperCase(Candidate),0);
      SeenKeys.Add(UpperCase(Copy(Identity,1,25)),0);
    end;
  finally SeenKeys.Free; SeenPaths.Free; end;
end;

class function TBookCompressionFileGroup.Manifest(const FilesJSON, ContextSHA256: string): TJSONObject;
var Value: TJSONValue;
begin
  Value:=TJSONObject.ParseJSONValue(FilesJSON);
  if not (Value is TJSONArray) then begin Value.Free; raise EReadError.Create('Нет списка связанных файлов.'); end;
  Result:=TJSONObject.Create;
  Result.AddPair('version',TJSONNumber.Create(1)); Result.AddPair('kind','HomeLibre compression file group');
  Result.AddPair('context_sha256',ContextSHA256); Result.AddPair('files',Value);
end;

class function TBookCompressionFileGroup.ComputeManifestSHA256(const FilesJSON, ContextSHA256: string): string;
var Data: TJSONObject;
begin
  Data:=Manifest(FilesJSON,ContextSHA256);
  try Result:=THashSHA2.GetHashString(Data.ToJSON); finally Data.Free; end;
end;

constructor TBookCompressionFileGroup.CreatePrepared(const Directory, FilesJSON, ContextSHA256: string;
  const Cancelled: TFunc<Boolean>; const Progress: TZipDeleteProgress; const Fault: TProc<string>);
var Data: TJSONObject;
begin
  inherited Create;
  FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory)); FContext:=ContextSHA256;
  FData:=Manifest(FilesJSON,ContextSHA256);
  Validate;
  FManifestSHA256:=THashSHA2.GetHashString(FData.ToJSON);
  if not CreateDirectory(PChar(DeletionNativePath(FDirectory)),nil) then RaiseLastOSError;
  OpenLease;
  SaveText(TPath.Combine(FDirectory,'group.json'),FData.ToJSON);
  SetLength(FEngines,Files.Count); SetLength(FReadLeases,Files.Count); SetLength(FChangeLeases,Files.Count);
  for var I:=0 to Files.Count-1 do
  begin
    if Assigned(Cancelled) and Cancelled() then Abort;
    Data:=Item(I); FChangeLeases[I]:=AcquireArchiveChange(Text(Data,'source'));
    FEngines[I]:=TZipMemberDeletion.PrepareReplacement(Text(Data,'source'),Text(Data,'candidate'),
      Text(Data,'source_identity'),Text(Data,'source_sha256'),Text(Data,'result_sha256'),
      JournalRoot(I),Cancelled,Progress);
    FEngines[I].BindContext(FContext);
    FEngines[I].PublishJournal(JournalRoot(I));
    if Assigned(Fault) then Fault('group-file-prepared-'+IntToStr(I));
  end;
  if Assigned(Cancelled) and Cancelled() then Abort;
  SaveText(TPath.Combine(FDirectory,'ready'),FManifestSHA256);
  if Assigned(Fault) then Fault('group-ready');
end;

procedure TBookCompressionFileGroup.CheckMarker(const Name: string);
begin
  if ReadText(TPath.Combine(FDirectory,Name))<>FManifestSHA256 then
    raise EReadError.Create('Подтверждение связанных файлов изменилось. Журналы сохранены.');
end;

function TBookCompressionFileGroup.FindJournal(Index: Integer): string;
begin
  Result:='';
  if not DirectoryExists(DeletionNativePath(JournalRoot(Index))) then Exit;
  for var Path in TDirectory.GetDirectories(DeletionNativePath(JournalRoot(Index)),'zip-delete-*') do
  begin
    if Result<>'' then raise EReadError.Create('У связанного файла несколько журналов.');
    Result:=Path;
  end;
end;

procedure TBookCompressionFileGroup.OpenEngines(Completed: Boolean);
var Journal: string; Data: TJSONObject;
begin
  SetLength(FEngines,Files.Count); SetLength(FReadLeases,Files.Count); SetLength(FChangeLeases,Files.Count);
  for var I:=0 to Files.Count-1 do
  begin
    Data:=Item(I); FChangeLeases[I]:=AcquireArchiveChange(Text(Data,'source'));
    Journal:=FindJournal(I);
    if Journal<>'' then
    begin
      FEngines[I]:=TZipMemberDeletion.RecoverReplacement(Text(Data,'source'),Journal);
      if (FEngines[I].ContextHash<>FContext) or
        not SameText(FEngines[I].FileKey,Copy(Text(Data,'source_identity'),1,25)) then
        raise EReadError.Create('Журнал связанного файла относится к другой операции.');
    end
    else
    begin
      if not Completed then raise EReadError.Create('Не хватает журнала связанного файла. Исходники не изменялись заново.');
      FReadLeases[I]:=TFileStream.Create(DeletionNativePath(Text(Data,'source')),fmOpenRead or fmShareDenyWrite);
    end;
  end;
end;

constructor TBookCompressionFileGroup.OpenExisting(const Directory, ExpectedManifestSHA256, ContextSHA256: string);
var Value: TJSONValue; Raw: string;
begin
  inherited Create;
  FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory)); FContext:=ContextSHA256;
  OpenLease;
  Raw:=ReadText(TPath.Combine(FDirectory,'group.json'));
  FManifestSHA256:=THashSHA2.GetHashString(Raw);
  if not IsHash(ExpectedManifestSHA256) or (FManifestSHA256<>ExpectedManifestSHA256) then
    raise EReadError.Create('Группа файлов не соответствует сохранённому заданию.');
  Value:=TJSONObject.ParseJSONValue(Raw);
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждён журнал связанных файлов.'); end;
  FData:=TJSONObject(Value); Validate; CheckMarker('ready');
  var Complete:=FileExists(DeletionNativePath(TPath.Combine(FDirectory,'complete')));
  if FileExists(DeletionNativePath(TPath.Combine(FDirectory,'started'))) then CheckMarker('started')
  else if Complete then raise EReadError.Create('Нет подтверждения начала связанной операции.');
  if Complete then CheckMarker('complete');
  OpenEngines(Complete);
end;

procedure TBookCompressionFileGroup.CheckResults;
var Data: TJSONObject;
begin
  for var I:=0 to Files.Count-1 do
  begin
    Data:=Item(I);
    if Assigned(FEngines[I]) then
      FEngines[I].CheckReplacementReceipt(Text(Data,'source'),Copy(Text(Data,'source_identity'),1,25),
        Text(Data,'source_sha256'),Text(Data,'result_sha256'),FContext)
    else if not Assigned(FReadLeases[I]) or
      not SameText(Copy(ArchiveDeletionSourceIdentity(Text(Data,'source')),1,25),Copy(Text(Data,'source_identity'),1,25)) or
      not SameText(HashStream(FReadLeases[I]),Text(Data,'result_sha256')) then
      raise EReadError.Create('Завершённый связанный файл изменился. Журнал сохранён.');
  end;
end;

procedure TBookCompressionFileGroup.Acknowledge(const Fault: TProc<string>);
begin
  for var I:=0 to High(FEngines) do
    if Assigned(FEngines[I]) then
    begin
      FEngines[I].Acknowledge; FreeAndNil(FEngines[I]);
      FReadLeases[I]:=TFileStream.Create(DeletionNativePath(Text(Item(I),'source')),fmOpenRead or fmShareDenyWrite);
      if Assigned(Fault) then Fault('group-journal-forgotten-'+IntToStr(I));
    end;
end;

procedure TBookCompressionFileGroup.Execute(const CommitMetadata: TProc<TArray<TZipMemberDeletion>>;
  const CheckMetadata: TProc; const Cancelled: TFunc<Boolean>; const Progress: TZipDeleteProgress;
  const Fault: TProc<string>);
var EngineFault: TZipDeleteFault;
begin
  if not Assigned(CommitMetadata) or not Assigned(CheckMetadata) then
    raise EArgumentException.Create('Нужно подтверждение сохранения каталога.');
  CheckMarker('ready');
  if FileExists(DeletionNativePath(TPath.Combine(FDirectory,'complete'))) then
  begin
    CheckMarker('complete'); CheckResults; CheckMetadata(); Acknowledge(Fault); FCompleted:=True; Exit;
  end;
  if FileExists(DeletionNativePath(TPath.Combine(FDirectory,'started'))) then CheckMarker('started')
  else
  begin
    if Assigned(Cancelled) and Cancelled() then Abort;
    SaveText(TPath.Combine(FDirectory,'started'),FManifestSHA256);
    if Assigned(Fault) then Fault('group-started');
  end;
  // Once any source write starts, finish the entire already-journalled group.
  for var I:=0 to High(FEngines) do
  begin
    EngineFault:=nil;
    if Assigned(Fault) then
      EngineFault:=procedure(const Stage: string; Chunk: Integer)
        begin Fault('group-file-'+IntToStr(I)+'-'+Stage); end;
    FEngines[I].Execute(JournalRoot(I),Progress,EngineFault);
    if Assigned(Fault) then Fault('group-file-committed-'+IntToStr(I));
  end;
  CheckResults; CommitMetadata(FEngines); CheckMetadata();
  if Assigned(Fault) then Fault('group-metadata-committed');
  SaveText(TPath.Combine(FDirectory,'complete'),FManifestSHA256);
  if Assigned(Fault) then Fault('group-complete');
  Acknowledge(Fault); FCompleted:=True;
end;

procedure TBookCompressionFileGroup.Forget;
begin
  if not FCompleted then raise EInvalidOperation.Create('Связанная операция ещё не завершена.');
  CheckMarker('complete');
  // Preflight all children before deleting even a completion marker.
  for var Path in TDirectory.GetFileSystemEntries(DeletionNativePath(FDirectory)) do
  begin
    var Name:=ExtractFileName(Path); var Known:=False;
    var Attr:=GetFileAttributes(PChar(Path));
    if (Attr=INVALID_FILE_ATTRIBUTES) or ((Attr and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
      raise EReadError.Create('В папке операции появилась ссылка или недоступный объект. Он сохранён.');
    for var I:=0 to Files.Count-1 do if Name='file-'+IntToStr(I) then
    begin
      Known:=True;
      if Length(TDirectory.GetFileSystemEntries(Path))<>0 then
        raise EReadError.Create('В папке связанного файла остались данные. Они сохранены.');
    end;
    if not Known and not ((Name='group.json') or (Name='group.lock') or (Name='ready') or (Name='started') or (Name='complete')) then
      raise EReadError.Create('В папке операции появился посторонний файл. Он сохранён.');
  end;
  for var I:=0 to Files.Count-1 do
    if DirectoryExists(DeletionNativePath(JournalRoot(I))) and
      not RemoveDirectory(PChar(DeletionNativePath(JournalRoot(I)))) then RaiseLastOSError;
  for var Name in ['group.json','ready','started','complete'] do
    if not Winapi.Windows.DeleteFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,Name)))) then RaiseLastOSError;
  CloseHandle(FLease); FLease:=0; CloseHandle(FGuard); FGuard:=0;
  if not Winapi.Windows.DeleteFile(PChar(DeletionNativePath(TPath.Combine(FDirectory,'group.lock')))) or
    not RemoveDirectory(PChar(DeletionNativePath(FDirectory))) then RaiseLastOSError;
end;

destructor TBookCompressionFileGroup.Destroy;
begin
  for var Engine in FEngines do Engine.Free;
  for var Stream in FReadLeases do Stream.Free;
  FChangeLeases:=nil;
  if FLease<>0 then CloseHandle(FLease);
  if FGuard<>0 then CloseHandle(FGuard);
  FData.Free; inherited;
end;

end.
