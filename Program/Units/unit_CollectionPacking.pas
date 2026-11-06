unit unit_CollectionPacking;

interface

uses System.SysUtils, System.Classes, System.JSON, Winapi.Windows, SQLiteWrap, unit_Interfaces,
  unit_Globals, unit_CollectionBackup;

const
  PACKING_RESUME_SWITCH = '--resume-collection-packing=';
  WM_RESUME_COLLECTION_PACKING = $8000+371;

type
  TPackingImageProfile = (pipOriginal, pipBalanced, pipEconomy, pipMaximum, pipJpegXL);
  TCollectionPackingProgress = reference to procedure(const Stage: string; Current, Total: Int64);
  TCollectionPackingCatalogEdit = reference to procedure(const CatalogFile, PersonalFile: string);
  TCollectionPackingOptions = record
    CatalogFile, PersonalFile, SourceRoot, OutputRoot, Dataset, DisplayName: string;
    SourceID: Integer;
    Python, Script, SevenZip, JpegXLEncoder, JpegXLDecoder: string;
    ImageProfile: TPackingImageProfile;
    ImageGrayscale: Boolean;
    VerifySources, VerifyOutputs: Boolean;
  end;

  TCollectionPackingRequest = record
    SourceID: Integer;
    CatalogFile, SourceRoot, OutputRoot, Inpx, UpdateRoot: string;
    CatalogIdentity, InpxIdentity: string;
    ImageProfile: TPackingImageProfile;
    ImageGrayscale: Boolean;
    procedure CaptureIdentity;
    procedure CheckIdentity(const CurrentCatalog, CurrentRoot: string; CurrentID: Integer);
  end;
  PCollectionPackingRequest = ^TCollectionPackingRequest;

  TCollectionPackingStatus = record
    Stage, StageKey, SourceName: string;
    Current, Total, SourcesDone, SourcesTotal, BooksDone, BooksTotal: Int64;
    InputBytes, OutputBytes, Reused, Unavailable, ElapsedMS, PackingMS: Int64;
    PlannedInputBytes, WorkingBytes, FreeBytes: Int64;
    ImageBooksOptimized, ImageBooksSkipped: Int64;
  end;

  // Owns disposable snapshots only. Packing never writes the source catalogue,
  // personal store or original book files. Registration is the final step.
  TCollectionPackingSnapshot = class
  private
    FOptions: TCollectionPackingOptions;
    FWork, FPlanFile, FCatalogFile, FPersonalFile, FPrepared, FError: string;
    FPlan: TSQLiteDatabase;
    FLease: THandle;
    FCanceled: TSnapshotCanceled;
    FProgress: TCollectionPackingProgress;
    FCancelStarted: UInt64;
    FReady, FApplied, FRegistered: Boolean;
    FCount: Int64;
    FStarted: UInt64;
    FStatus: TCollectionPackingStatus;
    function QueryCanceled: Boolean;
    procedure CheckCanceled;
    procedure Report(const Stage: string; Current, Total: Int64);
    procedure InitializeOutput;
    procedure AcquireOutputLease;
    function RemoveOwnedJob(const Folder: string): Boolean;
    procedure CleanAbandonedJobs;
    procedure CopySnapshot(const Source, Destination, Stage: string);
    procedure BuildPlan;
    procedure ReceiveEvent(const Value: string);
    function CancelProcess: Boolean;
    function CheckedOutputFile(const Relative: string): string;
  public
    constructor Create(const Options: TCollectionPackingOptions);
    destructor Destroy; override;
    procedure Prepare(const Canceled: TSnapshotCanceled = nil;
      const Progress: TCollectionPackingProgress = nil; const EditCatalog: TCollectionPackingCatalogEdit = nil);
    procedure Pack;
    procedure ApplyPrepared;
    procedure ClearNotifications;
    function RegisterNew(const SystemData: ISystemData): Integer;
    property PlanFile: string read FPlanFile;
    property CatalogFile: string read FCatalogFile;
    property PersonalFile: string read FPersonalFile;
    property PreparedGeneration: string read FPrepared;
    property PlannedLocations: Int64 read FCount;
    // Read on the operation's thread, normally from its progress callback.
    property Status: TCollectionPackingStatus read FStatus;
  end;

function IsPackedCollectionCatalog(const CatalogFile: string): Boolean;
function TryReadPackingImageProfile(const Folder: string; out Profile: TPackingImageProfile;
  out Grayscale: Boolean; const Dataset: string = ''): Boolean;
function PackingImageProfileCaption(Profile: TPackingImageProfile; Grayscale: Boolean = False): string;
function PackingReducesImageQuality(Profile: TPackingImageProfile): Boolean;
function ResolvePackingTools(const AppPath: string; var Options: TCollectionPackingOptions): TArray<string>;
function StorePackingContinuation(const SettingsFile: string; const Request: TCollectionPackingRequest): string;
function TakePackingContinuation(const SettingsFile, Argument: string; out Request: TCollectionPackingRequest): Boolean;

implementation

uses System.IOUtils, System.Hash, System.Math, System.StrUtils,
  System.Generics.Collections, SQLite3, unit_MHLArchiveHelpers, unit_CollectionSpace,
  unit_MHLExternalTools, unit_AtomicIniFile, System.DateUtils,
  unit_FormatComponents, unit_ProgramUpdateInstaller;

const
  PACKING_LEASE = 'HomeLibRu-native-packing.lock';
  PACKING_MARKER = 'HomeLibRu-compressed.json';
  PACKING_PROFILES: array[TPackingImageProfile] of string = ('original','balanced','economy','maximum','original');
  PACKING_JOB_KIND = 'HomeLibRu collection packing snapshots';
  DEFERRED_COLUMNS = '(kind INTEGER NOT NULL,book_id INTEGER NOT NULL,source_key TEXT NOT NULL,'+
    'folder TEXT NOT NULL,filename TEXT NOT NULL,ext TEXT NOT NULL,inside_no INTEGER NOT NULL,'+
    'root TEXT NOT NULL,PRIMARY KEY(kind,book_id,source_key))';

type
  TPackingOutput = class(TStream)
  private
    FOwner: TCollectionPackingSnapshot;
    FLine: UTF8String;
  public
    constructor Create(Owner: TCollectionPackingSnapshot);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

procedure PackingTriggers(pCtx: TSQLite3Context; nArgs: Integer; Args: TSQLite3Value); cdecl;
begin SQLite3_Result_Int(pCtx,1); end;

constructor TPackingOutput.Create(Owner: TCollectionPackingSnapshot);
begin inherited Create; FOwner:=Owner; end;

function PackingEngine(Profile: TPackingImageProfile; Grayscale: Boolean): string;
begin
  if Profile=pipOriginal then Result:='reversible-ppmd'
  else if Profile=pipJpegXL then Result:='jpeg-xl-7z'
  else if Grayscale then Result:='illustrations-gray-ppmd'
  else Result:='illustrations-ppmd';
end;

function PackingReducesImageQuality(Profile: TPackingImageProfile): Boolean;
begin
  Result:=Profile in [pipBalanced,pipEconomy,pipMaximum];
end;

function ResolvePackingTools(const AppPath: string; var Options: TCollectionPackingOptions): TArray<string>;
var Comparison: Integer; Version: string;
begin
  Result:=nil;
  Options.Script:=TPath.Combine(AppPath,PACKING_WORKER_FILE);
  Options.Python:=TPath.Combine(AppPath,FormatComponentFile('BookProcessing'));
  Version:=InstalledComponentVersion(AppPath,'BookProcessing');
  if not CompareComponentVersions(Version,PACKING_COMPONENT_VERSION,Comparison) or (Comparison<0) then
    Result:=Result+['BookProcessing'];
  Options.SevenZip:=FindFullSevenZip(AppPath);
  if Options.SevenZip='' then Options.SevenZip:=FindExternalTool('7za.exe','7zip');
  if Options.SevenZip='' then Result:=Result+['7-Zip'];
  if PackingReducesImageQuality(Options.ImageProfile) then
  begin
    Version:=InstalledComponentVersion(AppPath,'ImageProcessing');
    if not CompareComponentVersions(Version,PACKING_COMPONENT_VERSION,Comparison) or (Comparison<0) then
      Result:=Result+['ImageProcessing'];
  end;
  Options.JpegXLEncoder:='';
  Options.JpegXLDecoder:='';
  if Options.ImageProfile=pipJpegXL then
  begin
    if ComponentNeedsRepair(AppPath,JPEG_XL_ENCODER_COMPONENT) then
      Result:=Result+[JPEG_XL_ENCODER_COMPONENT]
    else Options.JpegXLEncoder:=TPath.Combine(AppPath,ComponentFileName(JPEG_XL_ENCODER_COMPONENT));
    if ComponentNeedsRepair(AppPath,'JPEG XL') or
      not CompareComponentVersions(InstalledComponentVersion(AppPath,'JPEG XL'),'0.12.0',Comparison) or
      (Comparison<0) then Result:=Result+['JPEG XL']
    else Options.JpegXLDecoder:=TPath.Combine(AppPath,ComponentFileName('JPEG XL'));
  end;
end;

function PackingImageProfileCaption(Profile: TPackingImageProfile; Grayscale: Boolean): string;
begin
  case Profile of
    pipBalanced: Result:='Сбалансированное сжатие иллюстраций';
    pipEconomy: Result:='Экономное сжатие иллюстраций';
    pipMaximum: Result:='Максимальная экономия места';
    pipJpegXL: Result:='JPEG XL без потери качества';
    else Result:='Обратимая упаковка';
  end;
  if Grayscale then Result:=Result+' · оттенки серого';
end;

function TryReadPackingImageProfile(const Folder: string; out Profile: TPackingImageProfile;
  out Grayscale: Boolean; const Dataset: string): Boolean;
var Marker, Images, Engine: string; Value: TJSONValue;
begin
  Profile:=pipOriginal;
  Grayscale:=False;
  Marker:=TPath.Combine(Folder,PACKING_MARKER);
  if not FileExists(Marker) then Exit(False);
  if (GetFileAttributes(PChar(Marker)) and FILE_ATTRIBUTE_REPARSE_POINT<>0) or
    (TFile.GetSize(Marker)>4096) then
    raise Exception.Create('Некорректный файл описания сжатой коллекции.');
  Value:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Marker,TEncoding.UTF8));
  try
    if not (Value is TJSONObject) or (Value.GetValue<Integer>('version',0)<>1) or
      (Value.GetValue<string>('dataset','')='') then
      raise Exception.Create('Некорректный файл описания сжатой коллекции.');
    if (Dataset<>'') and (Value.GetValue<string>('dataset','')<>Dataset) then
      raise Exception.Create('В этой папке находится другая коллекция.');
    Images:=Value.GetValue<string>('images','original');
    Engine:=Value.GetValue<string>('engine','');
    Grayscale:=Engine='illustrations-gray-ppmd';
    for var Candidate:=Low(TPackingImageProfile) to High(TPackingImageProfile) do
      if (not Grayscale or PackingReducesImageQuality(Candidate)) and
        (Images=PACKING_PROFILES[Candidate]) and (Engine=PackingEngine(Candidate,Grayscale)) then
      begin Profile:=Candidate; Exit(True); end;
    raise Exception.Create('Неизвестный профиль сжатой коллекции.');
  finally Value.Free; end;
end;

function IsPackedCollectionCatalog(const CatalogFile: string): Boolean;
var Catalog: TSQLiteDatabase;
begin
  if not FileExists(CatalogFile) then Exit(False);
  Catalog:=TSQLiteDatabase.CreateReadOnly(CatalogFile);
  try
    Result:=Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master '+
      'WHERE type=''table'' AND name=''HomeLibPackingState''')<>0;
  finally Catalog.Free; end;
end;

function PackingInputIdentity(const FileName: string; IncludeWriteTime: Boolean): string;
var Handle: THandle; Info: TByHandleFileInformation;
begin
  Handle:=CreateFile(PChar(FileName),FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,0);
  if Handle=INVALID_HANDLE_VALUE then
    raise Exception.Create('Исходный файл сжатия недоступен: '+FileName);
  try
    if not GetFileInformationByHandle(Handle,Info) then RaiseLastOSError;
    if (Info.dwFileAttributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0 then
      raise Exception.Create('Исходный файл сжатия заменён ссылкой или папкой: '+FileName);
    Result:=IntToHex(Info.dwVolumeSerialNumber,8)+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
    if IncludeWriteTime then
      Result:=Result+IntToHex(Info.ftLastWriteTime.dwHighDateTime,8)+IntToHex(Info.ftLastWriteTime.dwLowDateTime,8)+
        IntToHex(Info.nFileSizeHigh,8)+IntToHex(Info.nFileSizeLow,8);
  finally CloseHandle(Handle); end;
end;

procedure TCollectionPackingRequest.CaptureIdentity;
begin
  CatalogIdentity:=PackingInputIdentity(CatalogFile,False);
  if Inpx<>'' then InpxIdentity:=PackingInputIdentity(Inpx,True);
end;

procedure TCollectionPackingRequest.CheckIdentity(const CurrentCatalog, CurrentRoot: string; CurrentID: Integer);
begin
  if (SourceID<>CurrentID) or not SameFileName(CatalogFile,CurrentCatalog) or
    not SameFileName(ExcludeTrailingPathDelimiter(SourceRoot),ExcludeTrailingPathDelimiter(CurrentRoot)) or
    (CatalogIdentity<>PackingInputIdentity(CurrentCatalog,False)) then
    raise Exception.Create('После перезапуска исходная коллекция изменилась. Начните сжатие заново.');
  if (Inpx<>'') and (InpxIdentity<>PackingInputIdentity(Inpx,True)) then
    raise Exception.Create('После выбора файл INPX изменился. Выберите обновление заново.');
end;

function PackingContinuationFile(const SettingsFile: string): string;
begin Result:=TPath.GetFullPath(SettingsFile)+'.pending-packing.json'; end;

function StorePackingContinuation(const SettingsFile: string; const Request: TCollectionPackingRequest): string;
var Root: TJSONObject; Stream: TStringStream; Token: string;
begin
  Token:=TGUID.NewGuid.ToString;
  Root:=TJSONObject.Create;
  try
    Root.AddPair('version',TJSONNumber.Create(1));
    Root.AddPair('token',Token);
    Root.AddPair('created',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
    Root.AddPair('collection',TJSONNumber.Create(Request.SourceID));
    Root.AddPair('catalog',Request.CatalogFile);
    Root.AddPair('catalog_identity',Request.CatalogIdentity);
    Root.AddPair('source_root',Request.SourceRoot);
    Root.AddPair('output_root',Request.OutputRoot);
    Root.AddPair('inpx',Request.Inpx);
    Root.AddPair('inpx_identity',Request.InpxIdentity);
    Root.AddPair('update_root',Request.UpdateRoot);
    Root.AddPair('image_profile',TJSONNumber.Create(Ord(Request.ImageProfile)));
    Root.AddPair('grayscale',TJSONBool.Create(Request.ImageGrayscale));
    Stream:=TStringStream.Create(Root.ToJSON,TEncoding.UTF8);
    try SaveStreamAtomically(Stream,PackingContinuationFile(SettingsFile)); finally Stream.Free; end;
  finally Root.Free; end;
  Result:=PACKING_RESUME_SWITCH+Token;
end;

function TakePackingContinuation(const SettingsFile, Argument: string; out Request: TCollectionPackingRequest): Boolean;
var Token, Name, Claimed: string; Root: TJSONValue; Created, UTCNow: TDateTime; Profile: Integer;

  function ReadPlan(const FileName: string): TJSONValue;
  var Attr: DWORD;
  begin
    Attr:=GetFileAttributes(PChar(FileName));
    if (Attr=INVALID_FILE_ATTRIBUTES) or ((Attr and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>0) or
      (TFile.GetSize(FileName)>65536) then
      raise Exception.Create('Некорректный файл продолжения сжатия.');
    Result:=TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName,TEncoding.UTF8));
    if not (Result is TJSONObject) then
    begin Result.Free; raise Exception.Create('Повреждены параметры продолжения сжатия.'); end;
  end;

  function PathField(const Key: string; AllowEmpty: Boolean = False): string;
  begin
    Result:=Root.GetValue<string>(Key);
    if AllowEmpty and (Result='') then Exit;
    if (Result='') or (Length(Result)>4096) or Result.Contains(#0) or not TPath.IsPathRooted(Result) then
      raise Exception.Create('Недопустимый путь в параметрах продолжения сжатия.');
  end;

begin
  Result:=False; Request:=Default(TCollectionPackingRequest);
  if not Argument.StartsWith(PACKING_RESUME_SWITCH) then Exit;
  Token:=Argument.Substring(Length(PACKING_RESUME_SWITCH));
  if Length(Token)<>38 then Exit;
  Name:=PackingContinuationFile(SettingsFile);
  if not FileExists(Name) then Exit;
  Root:=ReadPlan(Name);
  try
    if Root.GetValue<string>('token','')<>Token then Exit;
  finally Root.Free; end;
  Claimed:=Name+'.claimed-'+TGUID.NewGuid.ToString;
  if not MoveFile(PChar(Name),PChar(Claimed)) then Exit;
  try
    Root:=ReadPlan(Claimed);
    try
      if Root.GetValue<string>('token','')<>Token then Exit;
      Created:=ISO8601ToDate(Root.GetValue<string>('created'),True);
      UTCNow:=TTimeZone.Local.ToUniversalTime(Now);
      Profile:=Root.GetValue<Integer>('image_profile');
      if (Root.GetValue<Integer>('version')<>1) or (Created<IncDay(UTCNow,-1)) or
        (Created>IncMinute(UTCNow,5)) or not InRange(Profile,Ord(Low(TPackingImageProfile)),Ord(High(TPackingImageProfile))) then
        raise Exception.Create('Параметры продолжения сжатия устарели или повреждены.');
      Request.SourceID:=Root.GetValue<Integer>('collection');
      Request.CatalogFile:=PathField('catalog');
      Request.CatalogIdentity:=Root.GetValue<string>('catalog_identity');
      Request.SourceRoot:=PathField('source_root');
      Request.OutputRoot:=PathField('output_root');
      Request.Inpx:=PathField('inpx',True);
      Request.InpxIdentity:=Root.GetValue<string>('inpx_identity');
      Request.UpdateRoot:=PathField('update_root',True);
      Request.ImageProfile:=TPackingImageProfile(Profile);
      Request.ImageGrayscale:=Root.GetValue<Boolean>('grayscale');
      if (Request.SourceID<=0) or (Length(Request.CatalogIdentity)<>24) or
        ((Request.Inpx='')<>(Request.UpdateRoot='')) or
        ((Request.Inpx<>'') and ((Length(Request.InpxIdentity)<>56) or
          not SameFileName(ExcludeTrailingPathDelimiter(Request.OutputRoot),ExcludeTrailingPathDelimiter(Request.SourceRoot)))) or
        (Request.ImageGrayscale and not PackingReducesImageQuality(Request.ImageProfile)) then
        raise Exception.Create('Повреждены параметры продолжения сжатия.');
      Result:=True;
    finally Root.Free; end;
  finally Winapi.Windows.DeleteFile(PChar(Claimed)); end;
end;

function TPackingOutput.Read(var Buffer; Count: Longint): Longint;
begin Result:=0; end;

function TPackingOutput.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin Result:=0; end;

function TPackingOutput.Write(const Buffer; Count: Longint): Longint;
var Bytes: PByte;
begin
  Bytes:=@Buffer;
  for var I:=0 to Count-1 do
  begin
    if Bytes^=10 then
    begin
      if FLine<>'' then FOwner.ReceiveEvent(string(FLine)); FLine:='';
    end
    else if Bytes^<>13 then
    begin
      FLine:=FLine+AnsiChar(Bytes^);
      if Length(FLine)>16384 then raise Exception.Create('Слишком длинное сообщение модуля сжатия.');
    end;
    Inc(Bytes);
  end;
  Result:=Count;
end;

constructor TCollectionPackingSnapshot.Create(const Options: TCollectionPackingOptions);
var Catalog: TSQLiteDatabase;
begin
  inherited Create; FLease:=INVALID_HANDLE_VALUE; FOptions:=Options; FStarted:=GetTickCount64;
  if FOptions.ImageGrayscale and not PackingReducesImageQuality(FOptions.ImageProfile) then
    raise EArgumentException.Create('Оттенки серого доступны при сжатии иллюстраций.');
  if (FOptions.ImageProfile=pipJpegXL) and
    (not FileExists(FOptions.JpegXLEncoder) or not FileExists(FOptions.JpegXLDecoder)) then
    raise EFileNotFoundException.Create('Для упаковки JPEG XL нужны кодировщик и декодер.');
  FOptions.CatalogFile:=TPath.GetFullPath(FOptions.CatalogFile);
  FOptions.PersonalFile:=TPath.GetFullPath(FOptions.PersonalFile);
  FOptions.SourceRoot:=IncludeTrailingPathDelimiter(TPath.GetFullPath(FOptions.SourceRoot));
  FOptions.OutputRoot:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(FOptions.OutputRoot));
  if FOptions.Dataset='' then
  begin
    Catalog:=TSQLiteDatabase.CreateReadOnly(FOptions.CatalogFile);
    try
      if Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibPackingState''')<>0 then
        FOptions.Dataset:=Catalog.QuerySingleString('SELECT Value FROM HomeLibPackingState WHERE Key=''dataset''');
    finally Catalog.Free; end;
    if FOptions.Dataset='' then FOptions.Dataset:=THashSHA2.GetHashString(LowerCase(FOptions.CatalogFile));
  end;
  if (FOptions.SourceID<=0) or (Trim(FOptions.DisplayName)='') then
    raise EArgumentException.Create('Не задана исходная коллекция или название сжатой копии.');
end;

function TCollectionPackingSnapshot.RemoveOwnedJob(const Folder: string): Boolean;
var Files: TArray<string>; Name, Marker: string; Value: TJSONValue; ID: TGUID;
begin
  Result:=False;
  if not ExtractFileName(Folder).StartsWith('.job-') then Exit;
  try ID:=StringToGUID(Copy(ExtractFileName(Folder),6,MaxInt)); except Exit; end;
  if not SameFileName(ExtractFileDir(Folder),FOptions.OutputRoot) then Exit;
  if (GetFileAttributes(PChar(Folder)) and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))<>FILE_ATTRIBUTE_DIRECTORY then Exit;
  Marker:=TPath.Combine(Folder,'HomeLibRu-job.json');
  if not FileExists(Marker) or
    (GetFileAttributes(PChar(Marker)) and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
    (TFile.GetSize(Marker)>4096) then Exit;
  Value:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Marker,TEncoding.UTF8));
  try
    if not (Value is TJSONObject) or (Value.GetValue<Integer>('version',0)<>1) or
      (Value.GetValue<string>('kind','')<>PACKING_JOB_KIND) or
      (Value.GetValue<string>('dataset','')<>FOptions.Dataset) then Exit;
  finally Value.Free; end;
  // Validate every entry before deleting any. An unexpected user file or
  // directory preserves the entire job, including its ownership marker.
  Files:=TDirectory.GetFileSystemEntries(Folder);
  for Name in Files do
    if (GetFileAttributes(PChar(Name)) and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
      not MatchText(ExtractFileName(Name),['source.hlc2','source.hlc2-wal','source.hlc2-shm','source.hlc2-journal',
        'personal.hlc2','personal.hlc2-wal','personal.hlc2-shm','personal.hlc2-journal',
        'plan.sqlite','plan.sqlite-journal','plan.sqlite-wal','plan.sqlite-shm',
        'job.json','cancel.marker','HomeLibRu-job.json']) then Exit;
  for Name in Files do
    if not SameFileName(Name,Marker) and not Winapi.Windows.DeleteFile(PChar(Name)) then Exit;
  // Keep the marker until everything else has gone, so a failed cleanup can
  // be retried on the next run. Never recurse into newly appearing entries.
  Files:=TDirectory.GetFileSystemEntries(Folder);
  if (Length(Files)<>1) or not SameFileName(Files[0],Marker) then Exit;
  if not Winapi.Windows.DeleteFile(PChar(Marker)) then Exit;
  Result:=RemoveDir(Folder);
end;

procedure TCollectionPackingSnapshot.CleanAbandonedJobs;
begin
  for var Folder in TDirectory.GetDirectories(FOptions.OutputRoot,'.job-*') do
  begin
    CheckCanceled;
    try RemoveOwnedJob(Folder); except
      // A locked or damaged old snapshot must not hide the current operation
      // or authorize deletion of anything beyond its proven owned files.
    end;
  end;
end;

destructor TCollectionPackingSnapshot.Destroy;
begin
  try
    FreeAndNil(FPlan);
    if FWork<>'' then try RemoveOwnedJob(FWork); except end;
  finally
    if FLease<>INVALID_HANDLE_VALUE then CloseHandle(FLease);
    inherited;
  end;
end;

function TCollectionPackingSnapshot.QueryCanceled: Boolean;
begin Result:=Assigned(FCanceled) and FCanceled(); end;

procedure TCollectionPackingSnapshot.CheckCanceled;
begin if QueryCanceled then raise EAbort.Create('Сжатие отменено. Готовые архивы сохранены для продолжения.'); end;

procedure TCollectionPackingSnapshot.Report(const Stage: string; Current, Total: Int64);
begin
  CheckCanceled; FStatus.Stage:=Stage; FStatus.StageKey:='native'; FStatus.SourceName:='';
  FStatus.Current:=Current; FStatus.Total:=Total; FStatus.ElapsedMS:=GetTickCount64-FStarted;
  if Assigned(FProgress) then FProgress(Stage,Current,Total);
end;

procedure TCollectionPackingSnapshot.ClearNotifications;
begin FCanceled:=nil; FProgress:=nil; end;

procedure TCollectionPackingSnapshot.AcquireOutputLease;
var Info: TByHandleFileInformation; Error: Cardinal;
begin
  if FLease<>INVALID_HANDLE_VALUE then raise Exception.Create('Эта операция сжатия уже начата.');
  ForceDirectories(FOptions.OutputRoot);
  // An exclusive handle works across processes and also rejects a second
  // operation on the same thread. Windows releases it after a process crash.
  FLease:=CreateFile(PChar(TPath.Combine(FOptions.OutputRoot,PACKING_LEASE)),
    GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FLease=INVALID_HANDLE_VALUE then
  begin
    Error:=GetLastError;
    if Error=ERROR_SHARING_VIOLATION then
      raise Exception.Create('Эта папка уже обрабатывается другой операцией сжатия. Дождитесь её завершения.');
    RaiseLastOSError(Error);
  end;
  if not GetFileInformationByHandle(FLease,Info) then RaiseLastOSError;
  if (Info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0) or
    (Info.nFileSizeHigh<>0) or (Info.nFileSizeLow<>0) then
    raise Exception.Create('В папке находится посторонний файл блокировки сжатия.');
end;

procedure TCollectionPackingSnapshot.InitializeOutput;
var Marker, Temporary: string; ExistingProfile: TPackingImageProfile; ExistingGrayscale: Boolean; Obj: TJSONObject;
begin
  Marker:=TPath.Combine(FOptions.OutputRoot,PACKING_MARKER);
  if not FileExists(Marker) and DirectoryExists(FOptions.OutputRoot) then
    for var Name in TDirectory.GetFileSystemEntries(FOptions.OutputRoot) do
      if not SameText(ExtractFileName(Name),PACKING_LEASE) then
        raise Exception.Create('Для новой сжатой копии нужна пустая папка.');
  AcquireOutputLease;
  if TryReadPackingImageProfile(FOptions.OutputRoot,ExistingProfile,ExistingGrayscale,FOptions.Dataset) then
  begin
    if (ExistingProfile<>FOptions.ImageProfile) or (ExistingGrayscale<>FOptions.ImageGrayscale) then
      raise Exception.Create('Для этой папки выбран другой профиль сжатия. Повторно выберите папку.');
    Exit;
  end;
  Obj:=TJSONObject.Create;
  try
    Obj.AddPair('version',TJSONNumber.Create(1)); Obj.AddPair('dataset',FOptions.Dataset);
    Obj.AddPair('engine',PackingEngine(FOptions.ImageProfile,FOptions.ImageGrayscale));
    Obj.AddPair('images',PACKING_PROFILES[FOptions.ImageProfile]);
    Temporary:=Marker+'.'+TGUID.NewGuid.ToString+'.partial';
    TFile.WriteAllText(Temporary,Obj.ToJSON,TEncoding.UTF8);
    try if not MoveFile(PChar(Temporary),PChar(Marker)) then RaiseLastOSError;
    finally if FileExists(Temporary) then TFile.Delete(Temporary); end;
  finally Obj.Free; end;
end;

procedure TCollectionPackingSnapshot.CopySnapshot(const Source, Destination, Stage: string);
var DB: TSQLiteDatabase;
begin
  DB:=TSQLiteDatabase.CreateReadOnly(Source);
  try
    DB.BackupTo(Destination,procedure(Done,Total: Integer) begin Report(Stage,Done,Total); end);
  finally DB.Free; end;
end;

procedure TCollectionPackingSnapshot.Prepare(const Canceled: TSnapshotCanceled;
  const Progress: TCollectionPackingProgress; const EditCatalog: TCollectionPackingCatalogEdit);
var Marker: TJSONObject;
begin
  if FWork<>'' then raise Exception.Create('План сжатия уже создан.');
  FCanceled:=Canceled; FProgress:=Progress; CheckCanceled; InitializeOutput; CleanAbandonedJobs;
  FWork:=TPath.Combine(FOptions.OutputRoot,'.job-'+TGUID.NewGuid.ToString);
  if not CreateDir(FWork) then RaiseLastOSError;
  Marker:=TJSONObject.Create;
  try
    Marker.AddPair('version',TJSONNumber.Create(1)); Marker.AddPair('kind',PACKING_JOB_KIND);
    Marker.AddPair('dataset',FOptions.Dataset);
    TFile.WriteAllText(TPath.Combine(FWork,'HomeLibRu-job.json'),Marker.ToJSON,TEncoding.UTF8);
  finally Marker.Free; end;
  FCatalogFile:=TPath.Combine(FWork,'source.hlc2');
  FPersonalFile:=TPath.Combine(FWork,'personal.hlc2');
  FPlanFile:=TPath.Combine(FWork,'plan.sqlite');
  Report('Подготавливаем рабочие снимки',0,0);
  CopySnapshot(FOptions.CatalogFile,FCatalogFile,'Сохраняем снимок каталога');
  CopySnapshot(FOptions.PersonalFile,FPersonalFile,'Сохраняем личные данные');
  CheckCanceled;
  if Assigned(EditCatalog) then
  begin
    Report('Читаем обновление INPX',0,0);
    EditCatalog(FCatalogFile,FPersonalFile);
  end;
  BuildPlan;
  FStatus.WorkingBytes:=TFile.GetSize(FCatalogFile)+TFile.GetSize(FPersonalFile)+TFile.GetSize(FPlanFile);
  FStatus.FreeBytes:=CollectionDiskFree(FOptions.OutputRoot);
  FStatus.BooksTotal:=FCount;
  FReady:=True;
end;

function PackingSourceExists(const FileName: string): Boolean;
var Attributes, Error: Cardinal;
begin
  Attributes:=GetFileAttributes(PChar(FileName));
  if Attributes=INVALID_FILE_ATTRIBUTES then
  begin
    Error:=GetLastError;
    if Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND] then Exit(False);
    RaiseLastOSError(Error);
  end;
  if (Attributes and FILE_ATTRIBUTE_DIRECTORY)<>0 then
    raise EInOutError.Create('Вместо файла книги найдена папка: '+FileName);
  Result:=True;
end;

procedure TCollectionPackingSnapshot.BuildPlan;
var Catalog, Personal: TSQLiteDatabase;
  Query, Insert, Target, Retained, Origin, Deferred, PreviousDeferred: TSQLiteQuery;
  Book: TBookRecord; CurrentArchive: TMHLZip; CurrentFile, Source, Member, Locator, Key, Root: string;
  OriginalName, Payload, Container, DeferredRoot: string;
  OriginalInside, NativeID: Integer; ID, Done, Total: Int64;
  Keep, Fbd, Missing: Boolean; BookFormat: TBookFormat;
  function ResolveSource(const SourceRoot: string): Boolean;
  begin
    if Book.FileName='' then Exit(False);
    Book.CollectionRoot:=IncludeTrailingPathDelimiter(SourceRoot);
    Container:=Book.GetBookContainer;
    BookFormat:=Book.GetBookFormat(Container); Fbd:=BookFormat=bfFbd;
    Source:=TPath.GetFullPath(Book.GetBookFileName(Container));
    if not SameFileName(CurrentFile,Source) and not PackingSourceExists(Source) then Exit(False);
    Member:='';
    if BookFormat in [bfFb2Archive,bfRawArchive,bfFbd] then
    begin
      if not SameFileName(CurrentFile,Source) then
      begin
        FreeAndNil(CurrentArchive); CurrentFile:='';
        CurrentArchive:=TMHLZip.Create(Source,True); CurrentFile:=Source;
      end;
      try
        Member:=CurrentArchive.ResolveBookName(Book.FileName+Book.FileExt,Book.InsideNo);
      except
        on E:EArchiveBookEntryNotFound do Exit(False);
      end;
    end;
    Result:=True;
  end;
  procedure ReadRows(DB: TSQLiteDatabase; const SQL: string; TargetKind: Integer);
  begin
    Query:=DB.NewQuery(SQL);
    try
      Query.Open;
      while not Query.Eof do
      begin
        CheckCanceled; Book.Clear;
        NativeID:=Query.FieldAsInt(0); Book.Folder:=Query.FieldAsString(1);
        Book.FileName:=Query.FieldAsString(2); Book.FileExt:=Query.FieldAsString(3);
        Book.InsideNo:=Query.FieldAsInt(4); Root:=FOptions.SourceRoot; Key:='';
        if TargetKind=2 then begin Root:=Query.FieldAsString(5); Key:=Query.FieldAsString(6); end;
        if Root='' then Root:=FOptions.SourceRoot;
        Book.CollectionRoot:=IncludeTrailingPathDelimiter(Root);
        Keep:=False; Missing:=False;
        if Assigned(Origin) and SameFileName(ExcludeTrailingPathDelimiter(Root),FOptions.OutputRoot) then
        begin
          Origin.Reset; Origin.SetParam(0,Book.Folder); Origin.SetParam(1,Book.FileName); Origin.SetParam(2,Book.FileExt);
          Origin.Open; Keep:=not Origin.Eof;
        end;
        Inc(ID);
        if Keep then
        begin
          // A registered immutable payload needs no original archive. Keep
          // its exact location; the backend verifies the payload ledger and
          // all companion images before accepting it into the new plan.
          Source:=Origin.FieldAsString(0); Member:=Origin.FieldAsString(1);
          OriginalName:=Origin.FieldAsString(2); OriginalInside:=Origin.FieldAsInt(3);
          Retained.Reset; Retained.SetParam(0,ID); Retained.SetParam(1,Book.Folder);
          Retained.SetParam(2,Book.FileName); Retained.SetParam(3,Book.FileExt); Retained.SetParam(4,Book.InsideNo);
          Fbd:=Book.GetBookFormat=bfFbd;
          Payload:=Book.Folder;
          if Fbd then Payload:=Payload+Book.FileName;
          Retained.SetParam(5,Payload);
          Retained.ExecSQL;
        end
        else
        begin
          Missing:=not ResolveSource(Root);
          DeferredRoot:=Root;
          if Missing and (Book.FileName<>'') and Assigned(PreviousDeferred) then
          begin
            PreviousDeferred.Reset; PreviousDeferred.SetParam(0,TargetKind);
            PreviousDeferred.SetParam(1,NativeID); PreviousDeferred.SetParam(2,Key);
            PreviousDeferred.SetParam(3,Book.Folder); PreviousDeferred.SetParam(4,Book.FileName);
            PreviousDeferred.SetParam(5,Book.FileExt); PreviousDeferred.SetParam(6,Book.InsideNo);
            PreviousDeferred.Open;
            if not PreviousDeferred.Eof then
            begin
              DeferredRoot:=PreviousDeferred.FieldAsString(0);
              if not SameFileName(ExcludeTrailingPathDelimiter(Root),ExcludeTrailingPathDelimiter(DeferredRoot)) then
                Missing:=not ResolveSource(DeferredRoot);
            end;
          end;
          if Missing then
          begin
            Deferred.Reset; Deferred.SetParam(0,TargetKind); Deferred.SetParam(1,NativeID);
            Deferred.SetParam(2,Key); Deferred.SetParam(3,Book.Folder); Deferred.SetParam(4,Book.FileName);
            Deferred.SetParam(5,Book.FileExt); Deferred.SetParam(6,Book.InsideNo);
            Deferred.SetParam(7,DeferredRoot); Deferred.ExecSQL;
            Inc(FStatus.Unavailable);
          end
          else
          begin
            OriginalName:=Book.FileName; OriginalInside:=Book.InsideNo;
            if Fbd then Locator:='fbd:'+IntToStr(Book.InsideNo)+':'+Member
            else Locator:='member:'+Member;
            Insert.Reset; Insert.SetParam(0,ID);
            Insert.SetParam(1,Source); Insert.SetParam(2,Member); Insert.SetParam(3,Locator);
            Insert.SetParam(4,Book.FileName); Insert.SetParam(5,Book.FileExt); Insert.SetParam(6,Book.InsideNo);
            Insert.SetParam(7,Ord(Fbd)); Insert.ExecSQL;
          end;
        end;
        if not Missing then
        begin
          Target.Reset; Target.SetParam(0,ID); Target.SetParam(1,TargetKind);
          Target.SetParam(2,NativeID); Target.SetParam(3,Key); Target.SetParam(4,Source);
          Target.SetParam(5,Member); Target.SetParam(6,OriginalName); Target.SetParam(7,OriginalInside);
          Target.SetParam(8,Ord(Fbd)); Target.ExecSQL;
        end;
        Inc(Done); if Done mod 256=0 then Report('Проверяем расположение книг',Done,Total);
        Query.Next;
      end;
    finally Query.Free; end;
  end;
begin
  Catalog:=nil; Personal:=nil; CurrentArchive:=nil; Insert:=nil; Target:=nil; Retained:=nil; Origin:=nil;
  Deferred:=nil; PreviousDeferred:=nil;
  FPlan:=TSQLiteDatabase.Create(FPlanFile);
  try
    FPlan.ExecSQL('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)');
    FPlan.ExecSQL('INSERT INTO metadata VALUES(?,?)',['api',string('1')]);
    FPlan.ExecSQL('INSERT INTO metadata VALUES(?,?)',['dataset',FOptions.Dataset]);
    FPlan.ExecSQL('CREATE TABLE books(book_id INTEGER PRIMARY KEY,source TEXT NOT NULL,member TEXT NOT NULL,'+
      'locator TEXT NOT NULL,filename TEXT NOT NULL,ext TEXT NOT NULL,inside_no INTEGER NOT NULL,fbd INTEGER NOT NULL)');
    FPlan.ExecSQL('CREATE TABLE retained(book_id INTEGER PRIMARY KEY,folder TEXT NOT NULL,filename TEXT NOT NULL,'+
      'ext TEXT NOT NULL,inside_no INTEGER NOT NULL,payload TEXT NOT NULL)');
    FPlan.ExecSQL('CREATE TABLE targets(plan_id INTEGER PRIMARY KEY,kind INTEGER NOT NULL,book_id INTEGER NOT NULL,source_key TEXT NOT NULL,'+
      'source TEXT NOT NULL,member TEXT NOT NULL,filename TEXT NOT NULL,inside_no INTEGER NOT NULL,fbd INTEGER NOT NULL)');
    FPlan.ExecSQL('CREATE TABLE deferred'+DEFERRED_COLUMNS);
    Catalog:=TSQLiteDatabase.CreateReadOnly(FCatalogFile);
    Personal:=TSQLiteDatabase.CreateReadOnly(FPersonalFile);
    Total:=Catalog.QuerySingleInt('SELECT count(*) FROM Books')+
      Personal.QuerySingleInt('SELECT count(*) FROM Books WHERE DatabaseID=?',[FOptions.SourceID]);
    if Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''CatalogBookCopies''')<>0 then
      Inc(Total,Catalog.QuerySingleInt('SELECT count(*) FROM CatalogBookCopies WHERE FileName<>'''' AND Ext<>'''''));
    if (Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''HomeLibPackingState''')<>0) and
      (Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''HomeLibPackingOrigins''')<>0) then
      if Catalog.QuerySingleString('SELECT Value FROM HomeLibPackingState WHERE Key=''dataset''')=FOptions.Dataset then
        Origin:=Catalog.NewQuery('SELECT Source,Member,OriginalFileName,OriginalInsideNo FROM HomeLibPackingOrigins '+
          'WHERE Folder=? AND FileName=? AND Ext=?');
    if Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE type=''table'' AND name=''HomeLibPackingDeferred''')<>0 then
      PreviousDeferred:=Catalog.NewQuery('SELECT root FROM HomeLibPackingDeferred WHERE kind=? AND book_id=? '+
        'AND source_key=? AND folder=? AND filename=? AND ext=? AND inside_no=?');
    Deferred:=FPlan.NewQuery('INSERT INTO deferred VALUES(?,?,?,?,?,?,?,?)');
    Insert:=FPlan.NewQuery('INSERT INTO books VALUES(?,?,?,?,?,?,?,?)');
    Retained:=FPlan.NewQuery('INSERT INTO retained VALUES(?,?,?,?,?,?)');
    Target:=FPlan.NewQuery('INSERT INTO targets VALUES(?,?,?,?,?,?,?,?,?)');
    FPlan.Start;
    try
      Done:=0; ID:=0;
      ReadRows(Catalog,'SELECT BookID,Folder,FileName,Ext,InsideNo FROM Books ORDER BY Folder,BookID',0);
      ReadRows(Personal,'SELECT BookID,Folder,FileName,Ext,InsideNo FROM Books WHERE DatabaseID='+IntToStr(FOptions.SourceID)+
        ' ORDER BY Folder,BookID',1);
      if Catalog.QuerySingleInt('SELECT count(*) FROM sqlite_master WHERE name=''CatalogBookCopies''')<>0 then
        ReadRows(Catalog,'SELECT BookID,Folder,FileName,Ext,InsideNo,Root,SourceKey FROM CatalogBookCopies '+
          'WHERE FileName<>'''' AND Ext<>'''' ORDER BY Root,Folder,BookID',2);
      FPlan.ExecSQL('CREATE INDEX source_books ON books(source)');
      FPlan.ExecSQL('CREATE INDEX retained_payload ON retained(payload)');
      FCount:=Done-FStatus.Unavailable;
      if FCount=0 then raise Exception.Create('В коллекции не найдено локальных файлов для сжатия.');
      FPlan.Commit;
    except if FPlan.InTransaction then FPlan.Rollback; raise; end;
    Query:=FPlan.NewQuery('SELECT DISTINCT source FROM books ORDER BY source');
    try
      Query.Open;
      while not Query.Eof do
      begin
        CheckCanceled;
        Source:=Query.FieldAsString(0);
        Inc(FStatus.PlannedInputBytes,TFile.GetSize(Source));
        if MatchText(ExtractFileExt(Source),['.zip','.7z']) then
          for var Kind in ['covers','images'] do
            for var Suffix in ['.zip','.7z'] do
            begin
              Payload:=TPath.Combine(TPath.Combine(ExtractFileDir(Source),Kind),
                ChangeFileExt(ExtractFileName(Source),Suffix));
              if FileExists(Payload) then Inc(FStatus.PlannedInputBytes,TFile.GetSize(Payload));
            end;
        Query.Next;
      end;
    finally Query.Free; end;
    Report('Расположение книг проверено',Done,Total);
  finally
    PreviousDeferred.Free; Deferred.Free; Origin.Free; Retained.Free; Target.Free;
    Insert.Free; CurrentArchive.Free; Personal.Free; Catalog.Free;
    FreeAndNil(FPlan);
  end;
end;

procedure TCollectionPackingSnapshot.ReceiveEvent(const Value: string);
var Obj: TJSONObject; Stage, Message: string; Current, Total: Int64;
begin
  Obj:=TJSONObject.ParseJSONValue(Value) as TJSONObject;
  if not Assigned(Obj) then raise Exception.Create('Модуль сжатия вернул некорректный ответ.');
  try
    Stage:=Obj.GetValue<string>('stage',''); Message:=Stage;
    if Stage='prepared' then FPrepared:=Obj.GetValue<string>('generation','');
    if Stage='error' then FError:=Obj.GetValue<string>('error','Ошибка сжатия коллекции.');
    if Stage='source' then Message:='Обрабатываем архивы';
    if Stage='books' then Message:='Подготавливаем книги';
    if Stage='compressing' then Message:='Упаковываем архив';
    if Stage='verifying' then Message:='Проверяем созданную копию';
    if Stage='retained' then Message:='Проверяем готовые архивы';
    if Stage='prepared' then Message:='Архивы готовы, проверяем каталог';
    Current:=Obj.GetValue<Int64>('current',0); Total:=Obj.GetValue<Int64>('total',0);
    FStatus.Stage:=Message; FStatus.StageKey:=Stage;
    FStatus.SourceName:=Obj.GetValue<string>('source',FStatus.SourceName);
    FStatus.Current:=Current; FStatus.Total:=Total;
    FStatus.SourcesDone:=Obj.GetValue<Int64>('sources_done',FStatus.SourcesDone);
    FStatus.SourcesTotal:=Obj.GetValue<Int64>('sources_total',FStatus.SourcesTotal);
    FStatus.BooksDone:=Obj.GetValue<Int64>('books_done',FStatus.BooksDone);
    FStatus.BooksTotal:=Obj.GetValue<Int64>('books_total',FStatus.BooksTotal);
    FStatus.InputBytes:=Obj.GetValue<Int64>('input_bytes',FStatus.InputBytes);
    FStatus.OutputBytes:=Obj.GetValue<Int64>('output_bytes',FStatus.OutputBytes);
    FStatus.Reused:=Obj.GetValue<Int64>('reused',FStatus.Reused);
    FStatus.ImageBooksOptimized:=Obj.GetValue<Int64>('image_books_optimized',FStatus.ImageBooksOptimized);
    FStatus.ImageBooksSkipped:=Obj.GetValue<Int64>('image_books_skipped',FStatus.ImageBooksSkipped);
    FStatus.ElapsedMS:=GetTickCount64-FStarted;
    FStatus.PackingMS:=Round(Obj.GetValue<Double>('elapsed_seconds',0)*1000);
    if Assigned(FProgress) then FProgress(Message,Current,Total);
  finally Obj.Free; end;
end;

function TCollectionPackingSnapshot.CancelProcess: Boolean;
begin
  Result:=False;
  if not QueryCanceled then Exit;
  if FCancelStarted=0 then
  begin
    FCancelStarted:=GetTickCount64;
    TFile.WriteAllText(TPath.Combine(FWork,'cancel.marker'),'cancel',TEncoding.ASCII);
  end;
  Result:=GetTickCount64-FCancelStarted>=3000;
end;

procedure TCollectionPackingSnapshot.Pack;
var Job: TJSONObject; JobFile: string; Output: TPackingOutput;
begin
  if not FReady then raise Exception.Create('Сначала нужно проверить коллекцию.');
  CheckCanceled;
  for var Tool in [FOptions.Python,FOptions.Script,FOptions.SevenZip] do
    if not FileExists(Tool) then raise EFileNotFoundException.Create('Не найден модуль сжатия: '+Tool);
  Job:=TJSONObject.Create;
  try
    Job.AddPair('version',TJSONNumber.Create(1)); Job.AddPair('dataset',FOptions.Dataset);
    Job.AddPair('engine',PackingEngine(FOptions.ImageProfile,FOptions.ImageGrayscale));
    Job.AddPair('images',PACKING_PROFILES[FOptions.ImageProfile]);
    if FOptions.ImageProfile=pipJpegXL then
    begin
      Job.AddPair('jpeg_xl_encoder',FOptions.JpegXLEncoder);
      Job.AddPair('jpeg_xl_decoder',FOptions.JpegXLDecoder);
    end;
    Job.AddPair('plan',FPlanFile); Job.AddPair('output',FOptions.OutputRoot); Job.AddPair('seven_zip',FOptions.SevenZip);
    Job.AddPair('verify_sources',TJSONBool.Create(FOptions.VerifySources));
    Job.AddPair('verify_outputs',TJSONBool.Create(FOptions.VerifyOutputs));
    Job.AddPair('allow_copy_inputs',TJSONBool.Create(
      SameFileName(ExcludeTrailingPathDelimiter(FOptions.SourceRoot),FOptions.OutputRoot)));
    JobFile:=TPath.Combine(FWork,'job.json'); TFile.WriteAllText(JobFile,Job.ToJSON,TEncoding.UTF8);
  finally Job.Free; end;
  Output:=TPackingOutput.Create(Self);
  try
    try
      RunExternalToolToStream(FOptions.Python,['-I','-B','-X','utf8',FOptions.Script,'--job',JobFile,
        '--cancel',TPath.Combine(FWork,'cancel.marker')],Output,CancelProcess,0,True,NativeUInt(512)*1024*1024);
    except
      on E: EMHLExternalToolError do
      begin CheckCanceled; if FError<>'' then raise Exception.Create(FError); raise; end;
    end;
  finally Output.Free; end;
  CheckCanceled;
  if Length(FPrepared)<>32 then
    raise Exception.Create('Модуль не подтвердил подготовку копии.');
  for var Ch in FPrepared do
    if not CharInSet(Ch,['0'..'9','a'..'f']) then
      raise Exception.Create('Модуль вернул некорректный номер операции.');
end;

function TCollectionPackingSnapshot.CheckedOutputFile(const Relative: string): string;
begin
  if TPath.IsPathRooted(Relative) or (Pos(':',Relative)>0) then
    raise Exception.Create('Модуль вернул недопустимый путь книги.');
  Result:=TPath.GetFullPath(TPath.Combine(FOptions.OutputRoot,Relative));
  if not Result.StartsWith(IncludeTrailingPathDelimiter(FOptions.OutputRoot),True) or not FileExists(Result) then
    raise Exception.Create('Созданный архив не найден в папке сжатой копии.');
end;

procedure TCollectionPackingSnapshot.ApplyPrepared;
var Plan, Locations, Catalog, Personal: TSQLiteDatabase; Q, Target, Deferred: TSQLiteQuery;
  Folder, Filename, Ext, SourceKey: string; ID, Total, Done: Int64; Kind, BookID, Inside: Integer;
begin
  if FApplied or (FPrepared='') then raise Exception.Create('Нет подготовленного результата сжатия.');
  Plan:=nil; Locations:=nil; Catalog:=nil; Personal:=nil; Q:=nil; Target:=nil; Deferred:=nil;
  try
    Plan:=TSQLiteDatabase.CreateReadOnly(FPlanFile);
    Locations:=TSQLiteDatabase.CreateReadOnly(TPath.Combine(FOptions.OutputRoot,'generations\'+FPrepared+'\locations.sqlite'));
    Catalog:=TSQLiteDatabase.Create(FCatalogFile); Personal:=TSQLiteDatabase.Create(FPersonalFile);
    Catalog.AddFunction('MHL_TRIGGERS_ON',0,PackingTriggers);
    Catalog.AddFunction('MHL_SERIES_TRIGGERS_ON',0,PackingTriggers);
    Total:=Locations.QuerySingleInt('SELECT count(*) FROM locations');
    if Total<>FCount then raise Exception.Create('Не все книги получили новое расположение.');
    Catalog.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibPackingState(Key TEXT PRIMARY KEY,Value TEXT NOT NULL)');
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['dataset',FOptions.Dataset]);
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['engine',PackingEngine(FOptions.ImageProfile,FOptions.ImageGrayscale)]);
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['images',PACKING_PROFILES[FOptions.ImageProfile]]);
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['generation',FPrepared]);
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['source_catalog',FOptions.CatalogFile]);
    Catalog.ExecSQL('INSERT OR REPLACE INTO HomeLibPackingState VALUES(?,?)',['source_root',FOptions.SourceRoot]);
    Catalog.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibPackingOrigins(Folder TEXT NOT NULL,FileName TEXT NOT NULL,Ext TEXT NOT NULL,'+
      'Source TEXT NOT NULL,Member TEXT NOT NULL,OriginalFileName TEXT NOT NULL,OriginalInsideNo INTEGER NOT NULL,PRIMARY KEY(Folder,FileName,Ext))');
    Target:=Plan.NewQuery('SELECT kind,book_id,source_key,source,member,filename,inside_no,fbd FROM targets WHERE plan_id=?');
    Q:=Locations.NewQuery('SELECT book_id,folder,filename,ext,inside_no FROM locations ORDER BY book_id');
    Deferred:=Plan.NewQuery('SELECT kind,book_id,source_key,folder,filename,ext,inside_no,root FROM deferred ORDER BY kind,book_id');
    Catalog.Start; Personal.Start;
    try
      Done:=0; Q.Open;
      while not Q.Eof do
      begin
        CheckCanceled; ID:=Q.FieldAsInt(0); Folder:=Q.FieldAsString(1);
        Filename:=Q.FieldAsString(2); Ext:=Q.FieldAsString(3); Inside:=Q.FieldAsInt(4);
        Target.Reset; Target.SetParam(0,ID); Target.Open;
        if Target.Eof then raise Exception.Create('Не найдено исходное назначение книги.');
        if Target.FieldAsBoolean(7) then
        begin
          if not Folder.EndsWith(PathDelim) or (ExtractFileName(Filename)<>Filename) or
            not SameText(ExtractFileExt(Filename),'.zip') then
            raise Exception.Create('Модуль вернул неверное расположение книги с описанием FBD.');
          CheckedOutputFile(Folder+Filename);
        end
        else CheckedOutputFile(Folder);
        Kind:=Target.FieldAsInt(0); BookID:=Target.FieldAsInt(1); SourceKey:=Target.FieldAsString(2);
        case Kind of
          0: Catalog.ExecSQL('UPDATE Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,IsLocal=1 WHERE BookID=?',
               [Folder,Filename,Ext,Inside,BookID]);
          1: Personal.ExecSQL('UPDATE Books SET Folder=?,FileName=?,Ext=?,InsideNo=?,IsLocal=1 WHERE BookID=? AND DatabaseID=?',
               [Folder,Filename,Ext,Inside,BookID,FOptions.SourceID]);
          2: Catalog.ExecSQL('UPDATE CatalogBookCopies SET Root=?,Folder=?,FileName=?,Ext=?,InsideNo=? WHERE SourceKey=?',
               [FOptions.OutputRoot,Folder,Filename,Ext,Inside,SourceKey]);
        else raise Exception.Create('Неизвестное назначение книги.'); end;
        Catalog.ExecSQL('INSERT OR IGNORE INTO HomeLibPackingOrigins VALUES(?,?,?,?,?,?,?)',
          [Folder,Filename,Ext,Target.FieldAsString(3),Target.FieldAsString(4),Target.FieldAsString(5),Target.FieldAsInt(6)]);
        Inc(Done); if Done mod 256=0 then Report('Обновляем отдельный каталог',Done,Total);
        Q.Next;
      end;
      Catalog.ExecSQL('CREATE TABLE IF NOT EXISTS HomeLibPackingDeferred'+DEFERRED_COLUMNS);
      Catalog.ExecSQL('DELETE FROM HomeLibPackingDeferred');
      Deferred.Open;
      while not Deferred.Eof do
      begin
        CheckCanceled;
        Kind:=Deferred.FieldAsInt(0); BookID:=Deferred.FieldAsInt(1);
        case Kind of
          0: Catalog.ExecSQL('UPDATE Books SET IsLocal=0 WHERE BookID=? AND IsLocal<>0',[BookID]);
          1: Personal.ExecSQL('UPDATE Books SET IsLocal=0 WHERE BookID=? AND DatabaseID=? AND IsLocal<>0',
               [BookID,FOptions.SourceID]);
        end;
        Catalog.ExecSQL('INSERT INTO HomeLibPackingDeferred VALUES(?,?,?,?,?,?,?,?)',
          [Kind,BookID,Deferred.FieldAsString(2),Deferred.FieldAsString(3),Deferred.FieldAsString(4),
           Deferred.FieldAsString(5),Deferred.FieldAsInt(6),Deferred.FieldAsString(7)]);
        Deferred.Next;
      end;
      CheckCanceled; Catalog.Commit; Personal.Commit;
    except
      if Catalog.InTransaction then Catalog.Rollback;
      if Personal.InTransaction then Personal.Rollback;
      raise;
    end;
    if (Catalog.QuerySingleString('PRAGMA quick_check')<>'ok') or
      (Personal.QuerySingleString('PRAGMA quick_check')<>'ok') then
      raise Exception.Create('Отдельная копия каталога не прошла проверку.');
    FApplied:=True; Report('Отдельный каталог проверен',Done,Total);
  finally Deferred.Free; Target.Free; Q.Free; Personal.Free; Catalog.Free; Locations.Free; Plan.Free; end;
end;

function TCollectionPackingSnapshot.RegisterNew(const SystemData: ISystemData): Integer;
var Restorer: ISnapshotCollectionRestorer; Personal: TSQLiteDatabase; Destination: string; Moved: Boolean;
begin
  if not FApplied or FRegistered then raise Exception.Create('Сжатая копия ещё не проверена или уже зарегистрирована.');
  if not Supports(SystemData,ISnapshotCollectionRestorer,Restorer) then
    raise Exception.Create('Хранилище не поддерживает отдельную копию коллекции.');
  Destination:=TPath.Combine(FOptions.OutputRoot,'collection.hlc2'); Personal:=nil; Moved:=False;
  if FileExists(Destination) then Destination:=TPath.Combine(FOptions.OutputRoot,'collection-'+FPrepared+'.hlc2');
  try
    CheckCanceled;
    if not MoveFile(PChar(FCatalogFile),PChar(Destination)) then RaiseLastOSError;
    Moved:=True; Personal:=TSQLiteDatabase.CreateReadOnly(FPersonalFile);
    Result:=Restorer.RegisterSnapshotCollection(Destination,FOptions.DisplayName,FOptions.OutputRoot,
      FOptions.SourceRoot,Personal,FOptions.SourceID,FCanceled);
    FRegistered:=True; Moved:=False;
  finally
    Personal.Free;
    if Moved then MoveFile(PChar(Destination),PChar(FCatalogFile));
  end;
end;

end.
