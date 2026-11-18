unit unit_LibraryUpdateContinuation;

interface

uses System.SysUtils, Winapi.Windows, unit_CollectionPacking, unit_LibraryUpdateFetch,
  unit_LibraryUpdateSources;

const
  LIBRARY_UPDATE_RESUME_SWITCH='--resume-library-update=';
  WM_RESUME_LIBRARY_UPDATE=$8000+374;

type
  TLibraryUpdateRestartRequest=record
    Identity:TCollectionPackingRequest;
    SourceID,CatalogDigest,PreviousDigest:string;
    Profiles:TLibraryUpdateSources;
    PreferNewRoot:Boolean;
  end;

  ILibraryUpdateRestart=interface
    function Request:TLibraryUpdateRestartRequest;
    function Arm:string;
    procedure Disarm;
    function OpenIndex(Previous:Boolean; const Check:TProc=nil):TStagedLibraryIndex;
  end;

function PrepareLibraryUpdateRestart(const WorkRoot:string; const Request:TLibraryUpdateRestartRequest;
  Current,Previous:TStagedLibraryIndex; const Check:TProc;
  const Progress:TLibraryIndexProgress=nil):ILibraryUpdateRestart;
function TakeLibraryUpdateRestart(const WorkRoot,Argument:string):ILibraryUpdateRestart;

implementation

uses System.Classes, System.IOUtils, System.JSON, System.DateUtils, System.Hash, unit_AtomicIniFile;

const
  ResumePrefix='HomeLibre-library-resume-';
  ManifestName='resume.json';
  ReadyName='ready';
  ClaimedName='claimed';
  PreviousName='previous.inpx';
  IncomingNames:array[0..7] of string=('incoming.inpx','incoming.jsonl','incoming.jsonl.zst',
    'incoming.jsonl.gz','incoming.zst','incoming.gz','incoming.zip','incoming.dat');

type
  TLibraryUpdateRestart=class(TInterfacedObject,ILibraryUpdateRestart)
  private
    FDirectory,FWorkRoot,FToken,FIncoming,FIncomingSHA,FPreviousSHA,FManifestSHA:string;
    FHandle:THandle;
    FKeep,FOwned:Boolean;
    FRequest:TLibraryUpdateRestartRequest;
    function FilePath(const Name:string):string;
    procedure HoldDirectory;
    procedure WriteManifest;
    procedure ReadManifest(const ExpectedSHA:string);
  public
    constructor Create(const WorkRoot,Token:string);
    destructor Destroy; override;
    function Request:TLibraryUpdateRestartRequest;
    function Arm:string;
    procedure Disarm;
    function OpenIndex(Previous:Boolean; const Check:TProc):TStagedLibraryIndex;
  end;

function FileIsPlain(const Name:string):Boolean;
begin
  var Attr:=GetFileAttributes(PChar(Name));
  Result:=(Attr<>INVALID_FILE_ATTRIBUTES) and
    ((Attr and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY))=0);
end;

function DigestValid(const Value:string; AllowEmpty:Boolean=False):Boolean;
begin
  if AllowEmpty and (Value='') then Exit(True);
  Result:=Length(Value)=64;
  for var C in Value do if not CharInSet(C,['0'..'9','a'..'f','A'..'F']) then Exit(False);
end;

constructor TLibraryUpdateRestart.Create(const WorkRoot,Token:string);
begin
  inherited Create;
  FHandle:=INVALID_HANDLE_VALUE;
  FWorkRoot:=TPath.GetFullPath(WorkRoot);
  FToken:=Token;
  FDirectory:=TPath.Combine(FWorkRoot,ResumePrefix+FToken);
end;

function TLibraryUpdateRestart.FilePath(const Name:string):string;
begin Result:=TPath.Combine(FDirectory,Name); end;

procedure TLibraryUpdateRestart.HoldDirectory;
var Info:TByHandleFileInformation; Count,Written:DWORD; Actual:string;
begin
  FHandle:=CreateFile(PChar(FDirectory),FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FHandle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  if not GetFileInformationByHandle(FHandle,Info) then RaiseLastOSError;
  if ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY)=0) or
    ((Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
    raise EReadError.Create('Рабочая папка продолжения обновления была подменена.');
  Count:=GetFinalPathNameByHandle(FHandle,nil,0,0);
  if Count=0 then RaiseLastOSError;
  SetLength(Actual,Count);
  Written:=GetFinalPathNameByHandle(FHandle,PChar(Actual),Count,0);
  if (Written=0) or (Written>=Count) then RaiseLastOSError;
  SetLength(Actual,Written);
  FDirectory:=Actual;
end;

destructor TLibraryUpdateRestart.Destroy;
begin
  if FOwned and not FKeep then
  begin
    for var Name in IncomingNames do Winapi.Windows.DeleteFile(PChar(FilePath(Name)));
    for var Name in TArray<string>.Create(PreviousName,ManifestName,ReadyName,ClaimedName) do
      Winapi.Windows.DeleteFile(PChar(FilePath(Name)));
  end;
  if FHandle<>INVALID_HANDLE_VALUE then CloseHandle(FHandle);
  if FOwned and not FKeep then RemoveDirectory(PChar(FDirectory));
  inherited;
end;

function TLibraryUpdateRestart.Request:TLibraryUpdateRestartRequest;
begin
  Result:=FRequest;
  Result.Profiles:=Copy(FRequest.Profiles);
end;

function TLibraryUpdateRestart.Arm:string;
var Marker:TFileStream;
begin
  if not FileIsPlain(FilePath(ManifestName)) or
    not SameText(THashSHA2.GetHashStringFromFile(FilePath(ManifestName)),FManifestSHA) then
    raise EReadError.Create('Параметры продолжения обновления изменились после подготовки.');
  Marker:=TFileStream.Create(FilePath(ReadyName),fmCreate);
  try
    if not FlushFileBuffers(Marker.Handle) then RaiseLastOSError;
  finally Marker.Free; end;
  FKeep:=True;
  Result:=LIBRARY_UPDATE_RESUME_SWITCH+FToken+':'+FManifestSHA;
end;

procedure TLibraryUpdateRestart.Disarm;
begin
  Winapi.Windows.DeleteFile(PChar(FilePath(ReadyName)));
  FKeep:=False;
end;

procedure TLibraryUpdateRestart.WriteManifest;
var Json:TJSONObject; Stream:TStringStream;
begin
  Json:=TJSONObject.Create;
  try
    Json.AddPair('version',TJSONNumber.Create(1));
    Json.AddPair('token',FToken);
    Json.AddPair('created',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
    Json.AddPair('collection',TJSONNumber.Create(FRequest.Identity.SourceID));
    Json.AddPair('catalog',FRequest.Identity.CatalogFile);
    Json.AddPair('catalog_identity',FRequest.Identity.CatalogIdentity);
    Json.AddPair('root',FRequest.Identity.SourceRoot);
    Json.AddPair('images',TJSONNumber.Create(Ord(FRequest.Identity.ImageProfile)));
    Json.AddPair('grayscale',TJSONBool.Create(FRequest.Identity.ImageGrayscale));
    Json.AddPair('catalog_digest',FRequest.CatalogDigest);
    Json.AddPair('previous_digest',FRequest.PreviousDigest);
    Json.AddPair('profile',FRequest.SourceID);
    Json.AddPair('profiles',WriteLibraryUpdateSources(FRequest.Profiles));
    Json.AddPair('prefer_new',TJSONBool.Create(FRequest.PreferNewRoot));
    Json.AddPair('incoming',FIncoming);
    Json.AddPair('incoming_sha256',FIncomingSHA);
    Json.AddPair('previous_sha256',FPreviousSHA);
    Stream:=TStringStream.Create(Json.ToJSON,TEncoding.UTF8);
    try
      SaveStreamAtomically(Stream,FilePath(ManifestName));
      FManifestSHA:=THashSHA2.GetHashStringFromFile(FilePath(ManifestName));
    finally Stream.Free; end;
  finally Json.Free; end;
end;

procedure TLibraryUpdateRestart.ReadManifest(const ExpectedSHA:string);
var Json:TJSONValue; Created,UTCNow:TDateTime; Found:Boolean; ProfileID:Integer;
  Input:TFileStream; Bytes:TBytes;
begin
  if not FileIsPlain(FilePath(ManifestName)) then
    raise EReadError.Create('Повреждён файл продолжения обновления коллекции.');
  Input:=TFileStream.Create(FilePath(ManifestName),fmOpenRead or fmShareDenyWrite);
  try
    if (Input.Size<=0) or (Input.Size>4*1024*1024) or
      not SameText(THashSHA2.GetHashString(Input),ExpectedSHA) then
      raise EReadError.Create('Параметры продолжения обновления изменились после подготовки.');
    Input.Position:=0;
    SetLength(Bytes,Input.Size);
    Input.ReadBuffer(Bytes,Length(Bytes));
  finally Input.Free; end;
  Json:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
  try
    if not (Json is TJSONObject) or (Json.GetValue<Integer>('version',0)<>1) or
      (Json.GetValue<string>('token','')<>FToken) then
      raise EReadError.Create('Повреждены параметры продолжения обновления.');
    Created:=ISO8601ToDate(Json.GetValue<string>('created'),True);
    UTCNow:=TTimeZone.Local.ToUniversalTime(Now);
    if (Created<IncDay(UTCNow,-1)) or (Created>IncMinute(UTCNow,5)) then
      raise EReadError.Create('Параметры продолжения обновления устарели.');
    FRequest.Identity.SourceID:=Json.GetValue<Integer>('collection');
    FRequest.Identity.CatalogFile:=Json.GetValue<string>('catalog');
    FRequest.Identity.CatalogIdentity:=Json.GetValue<string>('catalog_identity');
    FRequest.Identity.SourceRoot:=Json.GetValue<string>('root');
    ProfileID:=Json.GetValue<Integer>('images');
    if (ProfileID<Ord(Low(TPackingImageProfile))) or (ProfileID>Ord(High(TPackingImageProfile))) then
      raise EReadError.Create('Неизвестный профиль сжатия в параметрах продолжения.');
    FRequest.Identity.ImageProfile:=TPackingImageProfile(ProfileID);
    FRequest.Identity.ImageGrayscale:=Json.GetValue<Boolean>('grayscale');
    FRequest.CatalogDigest:=Json.GetValue<string>('catalog_digest');
    FRequest.PreviousDigest:=Json.GetValue<string>('previous_digest');
    FRequest.SourceID:=Json.GetValue<string>('profile');
    FRequest.Profiles:=ReadLibraryUpdateSources(Json.GetValue<string>('profiles'));
    FRequest.PreferNewRoot:=Json.GetValue<Boolean>('prefer_new');
    FIncoming:=Json.GetValue<string>('incoming');
    FIncomingSHA:=Json.GetValue<string>('incoming_sha256');
    FPreviousSHA:=Json.GetValue<string>('previous_sha256');
    Found:=False;
    for var Name in IncomingNames do Found:=Found or (FIncoming=Name);
    if not Found or not DigestValid(FIncomingSHA) or not DigestValid(FPreviousSHA,True) or
      not DigestValid(FRequest.CatalogDigest) or not DigestValid(FRequest.PreviousDigest,True) or
      (FRequest.Identity.SourceID<=0) or (Length(FRequest.Identity.CatalogIdentity)<>24) or
      not TPath.IsPathRooted(FRequest.Identity.CatalogFile) or not TPath.IsPathRooted(FRequest.Identity.SourceRoot) then
      raise EReadError.Create('Недопустимые параметры продолжения обновления.');
    Found:=False;
    for var Profile in FRequest.Profiles do Found:=Found or SameText(Profile.ID,FRequest.SourceID);
    if not Found then raise EReadError.Create('В параметрах продолжения отсутствует выбранный источник.');
  finally Json.Free; end;
end;

function TLibraryUpdateRestart.OpenIndex(Previous:Boolean; const Check:TProc):TStagedLibraryIndex;
var Profile:TLibraryUpdateSource; Hash:string;
begin
  Profile:=TLibraryUpdateSource.NewSource;
  Profile.Name:='Проверенный индекс обновления';
  Profile.Location:=FDirectory;
  if Previous then
  begin
    if FPreviousSHA='' then Exit(nil);
    Profile.IndexFile:=PreviousName;
    Hash:=FPreviousSHA;
  end
  else
  begin
    Profile.IndexFile:=FIncoming;
    Hash:=FIncomingSHA;
  end;
  if not FileIsPlain(FilePath(Profile.IndexFile)) then
    raise EReadError.Create('Служебная копия индекса обновления недоступна или была подменена.');
  Result:=TStagedLibraryIndex.Fetch(Profile,FWorkRoot,nil,Check);
  if not SameText(Result.SHA256,Hash) then
  begin
    FreeAndNil(Result);
    raise EReadError.Create('Служебная копия индекса обновления изменилась после проверки.');
  end;
end;

function PrepareLibraryUpdateRestart(const WorkRoot:string; const Request:TLibraryUpdateRestartRequest;
  Current,Previous:TStagedLibraryIndex; const Check:TProc;
  const Progress:TLibraryIndexProgress):ILibraryUpdateRestart;
var State:TLibraryUpdateRestart; Ext:string;
begin
  State:=TLibraryUpdateRestart.Create(WorkRoot,TGUID.NewGuid.ToString);
  try
    if not CreateDirectory(PChar(State.FDirectory),nil) then RaiseLastOSError;
    State.HoldDirectory;
    State.FOwned:=True;
    State.FRequest:=Request;
    State.FRequest.Profiles:=Copy(Request.Profiles);
    Ext:=LowerCase(TPath.GetExtension(Current.FileName));
    if ((Ext='.zst') or (Ext='.gz')) and
      SameText(TPath.GetExtension(ChangeFileExt(Current.FileName,'')),'.jsonl') then Ext:='.jsonl'+Ext;
    State.FIncoming:='incoming.dat';
    for var Name in IncomingNames do if Name='incoming'+Ext then State.FIncoming:=Name;
    State.FIncomingSHA:=Current.SHA256;
    Current.CopyVerified(State.FilePath(State.FIncoming),Check,Progress);
    if Assigned(Previous) then
    begin
      State.FPreviousSHA:=Previous.SHA256;
      Previous.CopyVerified(State.FilePath(PreviousName),Check,Progress);
    end;
    State.WriteManifest;
    Result:=State;
  except State.Free; raise; end;
end;

function TakeLibraryUpdateRestart(const WorkRoot,Argument:string):ILibraryUpdateRestart;
var Payload,Token,Hash:string; ID:TGUID; State:TLibraryUpdateRestart;
begin
  Result:=nil;
  if not Argument.StartsWith(LIBRARY_UPDATE_RESUME_SWITCH) then Exit;
  Payload:=Argument.Substring(Length(LIBRARY_UPDATE_RESUME_SWITCH));
  if (Length(Payload)<>103) or (Payload[39]<>':') then Exit;
  Token:=Copy(Payload,1,38);
  Hash:=Copy(Payload,40,64);
  if not DigestValid(Hash) then Exit;
  try ID:=StringToGUID(Token); except on E:EConvertError do Exit; end;
  if Token<>ID.ToString then Exit;
  State:=TLibraryUpdateRestart.Create(WorkRoot,Token);
  try
    if not DirectoryExists(State.FDirectory) then Exit;
    State.HoldDirectory;
    if not FileIsPlain(State.FilePath(ReadyName)) or
      not MoveFile(PChar(State.FilePath(ReadyName)),PChar(State.FilePath(ClaimedName))) then Exit;
    State.FOwned:=True;
    State.ReadManifest(Hash);
    Result:=State;
    State:=nil;
  finally State.Free; end;
end;

end.
