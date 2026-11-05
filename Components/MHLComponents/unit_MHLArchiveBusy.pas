unit unit_MHLArchiveBusy;

interface

uses System.SysUtils;

type
  EMHLArchiveInUse = class(EInOutError);

// Scoped in-process writer guard. Actual file sharing rules still enforce
// exclusion against other processes and against a reader already open.
function AcquireArchiveChange(const FileName: string): IInterface;
function IsArchiveChanging(const FileName: string): Boolean;
procedure CheckArchiveReadable(const FileName: string);

implementation

uses Winapi.Windows, System.Generics.Collections;

var Guard: TObject; Active: TDictionary<string,Byte>;

type
  TArchiveChangeLease = class(TInterfacedObject)
  private
    FKey: string;
    FRegistered: Boolean;
  public
    constructor Create(const Key: string);
    destructor Destroy; override;
  end;

function FileKey(const FileName:string; out Error:Cardinal):string;
var Path:string; Handle:THandle; Info:TByHandleFileInformation;
begin
  Result:=''; Error:=ERROR_INVALID_NAME;
  try Path:=ExpandFileName(FileName); except Exit; end;
  if not Path.StartsWith('\\?\') then
    if Path.StartsWith('\\') then Path:='\\?\UNC\'+Path.Substring(2) else Path:='\\?\'+Path;
  Handle:=CreateFile(PChar(Path),FILE_READ_ATTRIBUTES,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then begin Error:=GetLastError; Exit; end;
  try
    if not GetFileInformationByHandle(Handle,Info) then begin Error:=GetLastError; Exit; end;
    if (Info.nFileIndexHigh=0) and (Info.nFileIndexLow=0) then begin Error:=ERROR_NOT_SUPPORTED; Exit; end;
    Result:=IntToHex(Info.dwVolumeSerialNumber,8)+':'+IntToHex(Info.nFileIndexHigh,8)+IntToHex(Info.nFileIndexLow,8);
  finally CloseHandle(Handle); end;
end;

constructor TArchiveChangeLease.Create(const Key:string);
begin
  inherited Create; FKey:=Key;
  TMonitor.Enter(Guard);
  try
    if Active.ContainsKey(Key) then raise EMHLArchiveInUse.Create('С этим архивом уже выполняется операция. Дождитесь её завершения.');
    Active.Add(Key,0); FRegistered:=True;
  finally TMonitor.Exit(Guard); end;
end;

destructor TArchiveChangeLease.Destroy;
begin
  if FRegistered then
  begin TMonitor.Enter(Guard); try Active.Remove(FKey); finally TMonitor.Exit(Guard); end; end;
  inherited;
end;

function AcquireArchiveChange(const FileName:string):IInterface;
var Error:Cardinal;
begin
  var Key:=FileKey(FileName,Error);
  if Key='' then RaiseLastOSError(Error);
  Result:=TArchiveChangeLease.Create(Key);
end;

function IsArchiveChanging(const FileName:string):Boolean;
var Error:Cardinal;
begin
  Result:=False;
  TMonitor.Enter(Guard);
  try if Active.Count=0 then Exit; finally TMonitor.Exit(Guard); end;
  var Key:=FileKey(FileName,Error); if Key='' then Exit;
  TMonitor.Enter(Guard);
  try Result:=Active.ContainsKey(Key); finally TMonitor.Exit(Guard); end;
end;

procedure CheckArchiveReadable(const FileName:string);
begin
  if IsArchiveChanging(FileName) then
    raise EMHLArchiveInUse.Create('Архив занят операцией с книгами. Откройте книгу после её завершения.');
end;

initialization
  Guard:=TObject.Create; Active:=TDictionary<string,Byte>.Create;
finalization
  Active.Free; Guard.Free;
end.
