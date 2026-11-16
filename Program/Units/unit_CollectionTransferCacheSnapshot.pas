unit unit_CollectionTransferCacheSnapshot;

interface

uses System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  Winapi.Windows, SQLiteWrap;

type
  // The parent durably records directory/file ownership before large writes,
  // and the ready proof before publication. A mutable child manifest alone
  // never authorizes recovery, publication or cleanup.
  TTransferCacheRemember=reference to procedure(const Stage,JSON:string);
  TTransferCacheSnapshot=class
  private
    FReview:TSQLiteDatabase;
    FSourceWriter:TSQLiteDatabase;
    FOwnsSourceWriter:Boolean;
    FSourceLease:IInterface;
    FGuards:TList<THandle>;
    FStreams:TObjectList<TFileStream>;
    FReserved:TDictionary<string,string>;
    FJob:TJSONObject;
    FInputs:TJSONArray;
    FProof:TJSONObject;
    FDirectory,FDirectoryKey,FBinding,FReadySHA,FSourceKey:string;
    FRemember:TTransferCacheRemember;
    FCheck:TProc;
    FNextSpace:UInt64;
    function Pin(const Path:string):string;
    procedure Check;
    procedure Space(Required:UInt64=0);
    procedure Remember(const Stage,Path,Key:string);
    function Reserve(const Name:string; Notify:Boolean=True):THandle;
    procedure RecordFile(const Name:string; const Extra:TJSONObject=nil);
    procedure ValidateRequest;
    procedure CopyInputs;
    procedure BuildCache;
    procedure WriteReady;
    constructor Initialize(Review:TSQLiteDatabase; const JobJSON,InputsJSON,ExpectedBinding:string; const Cancelled:TProc);
  public
    class function Binding(const ReviewSHA,JobJSON,InputsJSON:string):string; static;
    class function CreateNew(Review:TSQLiteDatabase; const ReviewSHA,WorkRoot,JobJSON,InputsJSON,ExpectedBinding:string;
      const Remember:TTransferCacheRemember; const Cancelled:TProc=nil;
      BorrowedWriter:TSQLiteDatabase=nil):TTransferCacheSnapshot; static;
    class function Recover(Review:TSQLiteDatabase; const ReviewSHA,WorkRoot,Directory,DirectoryKey,
      JobJSON,InputsJSON,ExpectedBinding,ReadySHA:string; const Cancelled:TProc=nil):TTransferCacheSnapshot; static;
    destructor Destroy; override;
    function ProofJSON:string;
    procedure CheckUnchanged;
    function SourceHeld:Boolean;
    property Directory:string read FDirectory;
    property DirectoryKey:string read FDirectoryKey;
    property ReadySHA:string read FReadySHA;
  end;

{$IFDEF MHL_TRANSFER_TEST}
var TransferCacheSnapshotTestPoint:TProc<string>;
{$ENDIF}

implementation

uses System.IOUtils, System.Hash, unit_CatalogSources, unit_CollectionTransferPlan,
  unit_CollectionTransferCache, unit_BookCompressionReceipt, unit_ZipMemberDeletion;

const Kind='HomeLibre cache snapshot v1'; Prefix='cache-snapshot-';

function Key(Handle:THandle):string;
begin
  var Info:TByHandleFileInformation;
  if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
  Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
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

function ReadJSON(const Path:string):TJSONObject;
begin
  var Input:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
  try
    var Canonical,Identity:string; var Size:Int64; TransferReadFileState(Path,Canonical,Identity,Size);
    if not SameFileName(Canonical,Path) or (Key(Input.Handle)<>Copy(Identity,1,25)) then
      raise EReadError.Create('Подтверждение кэша перенаправлено.');
    if (Input.Size<=0) or (Input.Size>16*1024*1024) then raise EReadError.Create('Неверный размер подтверждения кэша.');
    var Bytes:TBytes; SetLength(Bytes,Integer(Input.Size)); Input.ReadBuffer(Bytes[0],Length(Bytes));
    Result:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes)) as TJSONObject;
    if Result=nil then raise EReadError.Create('Нет подтверждения кэша.');
  finally Input.Free; end;
end;

class function TTransferCacheSnapshot.Binding(const ReviewSHA,JobJSON,InputsJSON:string):string;
begin Result:=THashSHA2.GetHashString(Kind+#0+ReviewSHA+#0+JobJSON+#0+InputsJSON); end;

constructor TTransferCacheSnapshot.Initialize(Review:TSQLiteDatabase;
  const JobJSON,InputsJSON,ExpectedBinding:string; const Cancelled:TProc);
begin
  inherited Create; FReview:=Review; FBinding:=ExpectedBinding; FCheck:=Cancelled;
  if Length(JobJSON)+Length(InputsJSON)>16*1024*1024 then raise EReadError.Create('Слишком большое задание кэша.');
  FGuards:=TList<THandle>.Create; FStreams:=TObjectList<TFileStream>.Create(True);
  FReserved:=TDictionary<string,string>.Create;
  FJob:=TJSONObject.ParseJSONValue(JobJSON) as TJSONObject;
  FInputs:=TJSONObject.ParseJSONValue(InputsJSON) as TJSONArray;
  if (Review=nil) or (FJob=nil) or (FInputs=nil) or (FInputs.Count>16384) then raise EReadError.Create('Нет задания копирования кэша.');
  ValidateRequest;
end;

destructor TTransferCacheSnapshot.Destroy;
begin
  FStreams.Free;
  if Assigned(FSourceWriter) and FOwnsSourceWriter then begin if FSourceWriter.InTransaction then FSourceWriter.Rollback; FSourceWriter.Free; end;
  FSourceLease:=nil;
  if Assigned(FGuards) then begin for var Handle in FGuards do CloseHandle(Handle); FGuards.Free; end;
  FReserved.Free; FProof.Free; FInputs.Free; FJob.Free; inherited;
end;

procedure TTransferCacheSnapshot.ValidateRequest;
begin
  var Source:=Default(TCatalogSource); Source.ID:=FJob.GetValue<string>('source');
  Source.CacheVersion:=FJob.GetValue<string>('before_version'); var Before:=ExpandFileName(Source.CacheFile);
  Source.CacheVersion:=FJob.GetValue<string>('after_version'); var After:=ExpandFileName(Source.CacheFile);
  if (Source.CacheVersion='') or SameFileName(Before,After) or
    (Before<>FJob.GetValue<string>('before_file')) or (After<>FJob.GetValue<string>('after_file')) then
    raise EReadError.Create('Пути кэша не совпали с выбранными версиями.');
  var BeforeRoot:=IncludeTrailingPathDelimiter(ExpandFileName(FJob.GetValue<string>('before_root')));
  var AfterRoot:=IncludeTrailingPathDelimiter(ExpandFileName(FJob.GetValue<string>('after_root')));
  var Semantic:=THashSHA2.GetHashString(Source.ID+#0+LowerCase(Before)+#0+LowerCase(BeforeRoot)+#0+
    LowerCase(AfterRoot)+#0+FJob.GetValue<string>('library'));
  if Semantic<>FJob.GetValue<string>('job') then raise EReadError.Create('Изменена привязка задания кэша.');
  var Seen:=TDictionary<string,Boolean>.Create;
  try
    for var Value in FInputs do
    begin
      var Row:=Value as TJSONObject; var Input:=Row.GetValue<string>('source_file'); var Target:=Row.GetValue<string>('target_file');
      var Ext:=ExtractFileExt(Input);
      if (Input='') or not TPath.IsPathRooted(Input) or (ExpandFileName(Input)<>Input) then
        raise EReadError.Create('Нет абсолютного исходного индекса.');
      for var C in Ext do if CharInSet(C,[':', '\', '/', '*', '?', '"', '<', '>', '|']) then
        raise EReadError.Create('Неверное расширение сохранённого индекса.');
      var Expected:=TPath.Combine(ExtractFilePath(After),'index-'+THashSHA2.GetHashString(LowerCase(Input))+Ext);
      if (Row.GetValue<string>('job')<>Semantic) or (Target<>Expected) or Seen.ContainsKey(LowerCase(Target)) then
        raise EReadError.Create('Неверный или повторный индекс новой версии кэша.');
      Seen.Add(LowerCase(Target),True);
      var SHA:=Row.GetValue<string>('sha256');
      if SHA<>'' then
      begin
        if Length(SHA)<>64 then raise EReadError.Create('Неверная сумма сохранённого индекса.');
        for var C in SHA do if not CharInSet(C,['a'..'f','A'..'F','0'..'9']) then raise EReadError.Create('Неверная сумма сохранённого индекса.');
      end;
    end;
  finally Seen.Free; end;
end;

function TTransferCacheSnapshot.Pin(const Path:string):string;
begin
  var Handle:=CreateFile(PChar(DeletionNativePath(Path)),FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    var Info:TByHandleFileInformation; if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
      not SameFileName(TransferCanonicalDirectory(Path),IncludeTrailingPathDelimiter(ExpandFileName(Path))) then
      raise EReadError.Create('Папка подготовки кэша заменена ссылкой.');
    Result:=Key(Handle); FGuards.Add(Handle);
  except CloseHandle(Handle); raise; end;
end;

procedure TTransferCacheSnapshot.Space(Required:UInt64);
begin
  var Available,Capacity:UInt64; var SystemRoot:=TPath.GetPathRoot(GetEnvironmentVariable('SystemRoot'));
  if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then raise EWriteError.Create('Подготовка кэша остановлена: сохраните 8 ГБ на системном диске.');
  if not GetDiskFreeSpaceEx(PChar(DeletionNativePath(FDirectory)),Available,Capacity,nil) then RaiseLastOSError;
  if (Available<Required) or (Available-Required<UInt64(512)*1024*1024) then
    raise EWriteError.Create('Недостаточно места для копии кэша и резерва 512 МБ.');
end;

procedure TTransferCacheSnapshot.Check;
begin
  if Assigned(FCheck) then FCheck;
  if (FDirectory<>'') and (GetTickCount64>=FNextSpace) then begin FNextSpace:=GetTickCount64+1000; Space; end;
end;

procedure TTransferCacheSnapshot.Remember(const Stage,Path,Key:string);
begin
  Check;
  if not Assigned(FRemember) then raise EReadError.Create('Нет независимой записи владения подготовкой кэша.');
  var Data:=TJSONObject.Create;
  try
    Data.AddPair('binding',FBinding); Data.AddPair('directory',FDirectory); Data.AddPair('directory_key',FDirectoryKey);
    Data.AddPair('path',Path); Data.AddPair('key',Key); FRemember(Stage,Data.ToJSON);
  finally Data.Free; end;
{$IFDEF MHL_TRANSFER_TEST}
  if Assigned(TransferCacheSnapshotTestPoint) then TransferCacheSnapshotTestPoint(Stage);
{$ENDIF}
  Check;
end;

function TTransferCacheSnapshot.Reserve(const Name:string; Notify:Boolean):THandle;
begin
  if (Name='') or (ExtractFileName(Name)<>Name) or (Pos(':',Name)>0) then raise EReadError.Create('Неверное имя файла подготовки кэша.');
  var Path:=TPath.Combine(FDirectory,Name);
  Result:=CreateFile(PChar(DeletionNativePath(Path)),GENERIC_READ or GENERIC_WRITE,FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Result=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    FReserved.Add(Name,Key(Result));
    if Notify then Remember('cache-file-reserved',Path,Key(Result));
  except CloseHandle(Result); raise; end;
end;

procedure TTransferCacheSnapshot.RecordFile(const Name:string; const Extra:TJSONObject);
begin
  Check;
  var Stream:=TFileStream.Create(DeletionNativePath(TPath.Combine(FDirectory,Name)),fmOpenRead or fmShareDenyWrite);
  FStreams.Add(Stream);
  var Canonical,Identity:string; var Size:Int64;
  TransferReadFileState(TPath.Combine(FDirectory,Name),Canonical,Identity,Size);
  if not SameFileName(Canonical,TPath.Combine(FDirectory,Name)) or
    (Key(Stream.Handle)<>FReserved[Name]) or (Key(Stream.Handle)<>Copy(Identity,1,25)) then
    raise EReadError.Create('Файл подготовки кэша заменён.');
  var Info:TByHandleFileInformation; if not GetFileInformationByHandle(Stream.Handle,Info) then RaiseLastOSError;
  if (Info.nNumberOfLinks<>1) or (Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0) then
    raise EReadError.Create('Файл подготовки кэша заменён ссылкой.');
  var Row:TJSONObject;
  if Extra=nil then Row:=TJSONObject.Create else Row:=TJSONObject.ParseJSONValue(Extra.ToJSON) as TJSONObject;
  FProof.GetValue<TJSONArray>('files').AddElement(Row);
  Row.AddPair('name',Name); Row.AddPair('key',Key(Stream.Handle)); Row.AddPair('bytes',TJSONNumber.Create(Stream.Size));
  Row.AddPair('sha256',Hash(Stream,Check));
end;

procedure TTransferCacheSnapshot.BuildCache;
begin
  var Before:=FJob.GetValue<string>('before_file'); var Canonical,Identity:string; var Bytes:Int64;
  TransferReadFileState(Before,Canonical,Identity,Bytes); FSourceKey:=Copy(Identity,1,25);
  if (FJob.GetValue<string>('source_key','')<>'') and (FJob.GetValue<string>('source_key')<>FSourceKey) then
    raise EReadError.Create('Исходный кэш заменён после сохранения плана.');
  FSourceLease:=AcquireCompressionDatabaseLease(Canonical,FSourceKey);
  if FSourceWriter=nil then
  begin
    FSourceWriter:=TSQLiteDatabase.Create(DeletionNativePath(Canonical),False); FOwnsSourceWriter:=True;
    FSourceWriter.ExecSQL('BEGIN IMMEDIATE');
  end
  else
  begin
    var Q:=FSourceWriter.NewQuery('PRAGMA database_list'); var Actual:='';
    try Q.Open; while not Q.Eof do begin if Q.FieldAsString(1)='main' then Actual:=CompressionFileKey(Q.FieldAsString(2)); Q.Next; end;
    finally Q.Free; end;
    if not FSourceWriter.InTransaction or (Actual<>FSourceKey) then raise EReadError.Create('Нет блокировки выбранного исходного кэша.');
  end;
  if CompressionFileKey(Canonical)<>FSourceKey then raise EReadError.Create('Исходный кэш изменился перед копированием.');
  var Reader:=TSQLiteDatabase.CreateReadOnly(DeletionNativePath(Canonical));
  try
    Reader.ExecSQL('BEGIN');
    var Pages:=Reader.QuerySingleInt('PRAGMA page_count'); var PageSize:=Reader.QuerySingleInt('PRAGMA page_size');
    if (Pages<0) or (PageSize<512) or (PageSize>65536) or (Pages>High(Int64) div PageSize div 2) then
      raise EReadError.Create('Неверный размер исходного кэша.');
    Space(UInt64(Pages*PageSize)*2);
    FProof.AddPair('source_file',Before); FProof.AddPair('source_key',FSourceKey);
    var Reserved:=Reserve('catalog.hlc2',False);
    try
      var Target:=TSQLiteDatabase.Create(DeletionNativePath(TPath.Combine(FDirectory,'catalog.hlc2')),False);
      try
        Remember('cache-file-reserved',TPath.Combine(FDirectory,'catalog.hlc2'),Key(Reserved));
        Reader.BackupToEmpty(Target,procedure(Done,Total:Integer) begin Check; end);
        var Backup:=THandleStream.Create(Reserved);
        try FProof.AddPair('source_snapshot_sha256',Hash(Backup,Check)); finally Backup.Free; end;
        Remember('cache-backup-complete',TPath.Combine(FDirectory,'catalog.hlc2'),FSourceKey);
        Target.ExecSQL('PRAGMA synchronous=FULL'); Target.ExecSQL('BEGIN IMMEDIATE');
        try
          ProjectTransferCache(FReview,Target,FJob.GetValue<string>('source'),FJob.GetValue<string>('library'),
            FJob.GetValue<string>('before_root'),FJob.GetValue<string>('after_root'),Check);
          Remember('cache-before-projection-commit',TPath.Combine(FDirectory,'catalog.hlc2'),''); Target.Commit;
        except if Target.InTransaction then Target.Rollback; raise; end;
      finally Target.Free; end;
    finally CloseHandle(Reserved); end;
  finally Reader.Free; end;
  RecordFile('catalog.hlc2'); Remember('cache-projection-complete',TPath.Combine(FDirectory,'catalog.hlc2'),'');
end;

procedure TTransferCacheSnapshot.CopyInputs;
begin
  for var Value in FInputs do
  begin
    Check; var Row:=Value as TJSONObject; var Path:=Row.GetValue<string>('source_file'); var Name:=ExtractFileName(Row.GetValue<string>('target_file'));
    var Input:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
    try
      var Canonical,Identity:string; var Bytes:Int64; TransferReadFileState(Path,Canonical,Identity,Bytes);
      if Key(Input.Handle)<>Copy(Identity,1,25) then raise EReadError.Create('Исходный индекс заменён.');
      if (Row.GetValue<string>('source_key','')<>'') and (Row.GetValue<string>('source_key')<>Copy(Identity,1,25)) then
        raise EReadError.Create('Исходный индекс заменён после сохранения плана.');
      Space(UInt64(Input.Size)); var Handle:=Reserve(Name);
      try
        var Output:=THandleStream.Create(Handle);
        try
          var Buffer:TBytes; SetLength(Buffer,1024*1024); var Digest:=THashSHA2.Create;
          repeat
            Check; var Count:=Input.Read(Buffer[0],Length(Buffer)); if Count=0 then Break;
            Output.WriteBuffer(Buffer[0],Count); Digest.Update(Buffer,Count);
          until False;
          if not FlushFileBuffers(Handle) then RaiseLastOSError;
          var SHA:=Digest.HashAsString;
          if (Row.GetValue<string>('sha256')<>'') and not SameText(SHA,Row.GetValue<string>('sha256')) then
            raise EReadError.Create('Не совпала контрольная сумма сохранённого индекса.');
          if not SameText(SHA,Hash(Output,Check)) then raise EReadError.Create('Не совпало содержимое копии индекса.');
        finally Output.Free; end;
      finally CloseHandle(Handle); end;
      var Extra:=TJSONObject.Create;
      try Extra.AddPair('source_file',Path); Extra.AddPair('source_key',Copy(Identity,1,25)); RecordFile(Name,Extra);
      finally Extra.Free; end;
    finally Input.Free; end;
    Remember('cache-index-copied',TPath.Combine(FDirectory,Name),'');
  end;
end;

procedure TTransferCacheSnapshot.WriteReady;
begin
  var Raw:=TEncoding.UTF8.GetBytes(FProof.ToJSON); FReadySHA:=THashSHA2.GetHashString(FProof.ToJSON);
  if Length(Raw)>16*1024*1024 then raise EReadError.Create('Слишком большое подтверждение готового кэша.');
  var Handle:=Reserve('ready.json');
  try
    var Stream:=THandleStream.Create(Handle);
    try if Length(Raw)>0 then Stream.WriteBuffer(Raw[0],Length(Raw)); finally Stream.Free; end;
    if not FlushFileBuffers(Handle) then RaiseLastOSError;
  finally CloseHandle(Handle); end;
  Remember('cache-ready',TPath.Combine(FDirectory,'ready.json'),FReadySHA);
end;

class function TTransferCacheSnapshot.CreateNew(Review:TSQLiteDatabase;
  const ReviewSHA,WorkRoot,JobJSON,InputsJSON,ExpectedBinding:string;
  const Remember:TTransferCacheRemember; const Cancelled:TProc; BorrowedWriter:TSQLiteDatabase):TTransferCacheSnapshot;
begin
  if (Length(ReviewSHA)<>64) or (Binding(ReviewSHA,JobJSON,InputsJSON)<>ExpectedBinding) or not Assigned(Remember) then
    raise EReadError.Create('Нет независимой привязки подготовки кэша.');
  Result:=TTransferCacheSnapshot.Initialize(Review,JobJSON,InputsJSON,ExpectedBinding,Cancelled);
  try
    Result.FSourceWriter:=BorrowedWriter;
    Result.FRemember:=Remember; Result.Pin(WorkRoot);
    Result.FDirectory:=TPath.Combine(TransferCanonicalDirectory(WorkRoot),Prefix+TGUID.NewGuid.ToString);
    if not CreateDirectory(PChar(DeletionNativePath(Result.FDirectory)),nil) then RaiseLastOSError;
    Result.FDirectoryKey:=Result.Pin(Result.FDirectory);
    Result.Remember('cache-directory-created',Result.FDirectory,Result.FDirectoryKey);
    Result.FProof:=TJSONObject.Create; Result.FProof.AddPair('kind',Kind); Result.FProof.AddPair('binding',ExpectedBinding);
    Result.FProof.AddPair('directory_key',Result.FDirectoryKey); Result.FProof.AddPair('files',TJSONArray.Create);
    Result.BuildCache; Result.CopyInputs; Result.WriteReady;
  except Result.Free; raise; end;
end;

class function TTransferCacheSnapshot.Recover(Review:TSQLiteDatabase;
  const ReviewSHA,WorkRoot,Directory,DirectoryKey,JobJSON,InputsJSON,ExpectedBinding,ReadySHA:string;
  const Cancelled:TProc):TTransferCacheSnapshot;
begin
  if (Length(ReviewSHA)<>64) or (Length(ReadySHA)<>64) or (Binding(ReviewSHA,JobJSON,InputsJSON)<>ExpectedBinding) then
    raise EReadError.Create('Нет независимого подтверждения готового кэша.');
  Result:=TTransferCacheSnapshot.Initialize(Review,JobJSON,InputsJSON,ExpectedBinding,Cancelled);
  try
    Result.Pin(WorkRoot); Result.FDirectory:=ExcludeTrailingPathDelimiter(ExpandFileName(Directory));
    var Name:=ExtractFileName(Result.FDirectory);
    if not Name.StartsWith(Prefix) or
      (Name<>Prefix+GUIDToString(StringToGUID(Copy(Name,Length(Prefix)+1,MaxInt)))) or
      not SameFileName(IncludeTrailingPathDelimiter(ExtractFileDir(Result.FDirectory)),TransferCanonicalDirectory(WorkRoot)) then
      raise EReadError.Create('Готовый кэш находится вне рабочей папки.');
    Result.FDirectoryKey:=Result.Pin(Result.FDirectory);
    if Result.FDirectoryKey<>DirectoryKey then raise EReadError.Create('Папка готового кэша заменена.');
    Result.FReadySHA:=ReadySHA; Result.FProof:=ReadJSON(TPath.Combine(Result.FDirectory,'ready.json'));
    if (THashSHA2.GetHashString(Result.FProof.ToJSON)<>ReadySHA) or
      (Result.FProof.GetValue<string>('kind')<>Kind) or (Result.FProof.GetValue<string>('binding')<>ExpectedBinding) or
      (Result.FProof.GetValue<string>('directory_key')<>DirectoryKey) then raise EReadError.Create('Изменено подтверждение готового кэша.');
    Result.CheckUnchanged;
  except Result.Free; raise; end;
end;

function TTransferCacheSnapshot.ProofJSON:string;
begin Result:=FProof.ToJSON; end;

function TTransferCacheSnapshot.SourceHeld:Boolean;
begin Result:=Assigned(FSourceWriter) and FSourceWriter.InTransaction; end;

procedure TTransferCacheSnapshot.CheckUnchanged;
begin
  Check;
  if (FProof=nil) or (THashSHA2.GetHashString(FProof.ToJSON)<>FReadySHA) then raise EReadError.Create('Изменено подтверждение подготовки кэша.');
  var Files:=FProof.GetValue<TJSONArray>('files');
  if (Files=nil) or (Files.Count<>FInputs.Count+1) then raise EReadError.Create('Неполный состав готового кэша.');
  FStreams.Clear;
  var Seen:=TDictionary<string,Boolean>.Create;
  try
    for var Value in Files do
    begin
      Check; var Row:=Value as TJSONObject; var Name:=Row.GetValue<string>('name');
      if (Name='') or (ExtractFileName(Name)<>Name) or (Pos(':',Name)>0) or Seen.ContainsKey(LowerCase(Name)) then
        raise EReadError.Create('Неверное имя готового файла кэша.');
      Seen.Add(LowerCase(Name),True);
      var Stream:=TFileStream.Create(DeletionNativePath(TPath.Combine(FDirectory,Name)),fmOpenRead or fmShareDenyWrite);
      FStreams.Add(Stream);
      var Canonical,Identity:string; var Size:Int64;
      TransferReadFileState(TPath.Combine(FDirectory,Name),Canonical,Identity,Size);
      if not SameFileName(Canonical,TPath.Combine(FDirectory,Name)) or (Key(Stream.Handle)<>Copy(Identity,1,25)) or
        (Key(Stream.Handle)<>Row.GetValue<string>('key')) or (Stream.Size<>Row.GetValue<Int64>('bytes')) or
        not SameText(Hash(Stream,Check),Row.GetValue<string>('sha256')) then
        raise EReadError.Create('Изменён файл готового кэша.');
    end;
    if not Seen.ContainsKey('catalog.hlc2') then raise EReadError.Create('Нет готовой базы кэша.');
    for var Value in FInputs do if not Seen.ContainsKey(LowerCase(ExtractFileName(TJSONObject(Value).GetValue<string>('target_file')))) then
      raise EReadError.Create('Нет готового исходного индекса.');
  finally Seen.Free; end;
end;

end.
