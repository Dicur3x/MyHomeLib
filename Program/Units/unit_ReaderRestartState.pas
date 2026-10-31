unit unit_ReaderRestartState;

interface

uses Winapi.Windows;

// A per-process receipt refers to an existing Reader session, never a copy of
// the book. The process creation time prevents reuse after Windows reuses a PID.
function ReaderProcessStamp(Process: THandle): string;
function ReaderRestartDirectory(const Profile: string): string;
procedure PublishReaderRestart(const Profile, RequestFile: string);
function ReadReaderRestart(const Profile: string; PID: Cardinal;
  const ProcessStamp: string): string;
procedure RemoveReaderRestart(const Profile: string);
procedure CleanupReaderRestartSession(const Profile, RequestFile: string);

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON;

const RESTART_SESSION_PREFIX = 'HomeLibReader-session-';

function ReaderProcessStamp(Process: THandle): string;
var Created, Exited, Kernel, User: TFileTime;
begin
  if not GetProcessTimes(Process,Created,Exited,Kernel,User) then RaiseLastOSError;
  Result:=IntToHex(Created.dwHighDateTime,8)+IntToHex(Created.dwLowDateTime,8);
end;

function ReaderRestartDirectory(const Profile: string): string;
begin
  Result:=TPath.Combine(TPath.GetFullPath(Profile),'Data\ReaderInstances');
end;

function ReceiptFile(const Profile: string; PID: Cardinal): string;
begin
  Result:=TPath.Combine(ReaderRestartDirectory(Profile),UIntToStr(PID)+'.json');
end;

function OwnedRestartRequest(const Profile, RequestFile: string): Boolean;
var Folder, Name, ID: string;
begin
  Result:=False;
  if (RequestFile='') or not TPath.IsPathRooted(RequestFile) or
    not SameText(ExtractFileName(RequestFile),'request.json') then Exit;
  Folder:=ExtractFileDir(TPath.GetFullPath(RequestFile));
  if not SameFileName(ExtractFileDir(Folder),ReaderRestartDirectory(Profile)) then Exit;
  Name:=ExtractFileName(Folder);
  if not Name.StartsWith(RESTART_SESSION_PREFIX) then Exit;
  ID:=Name.Substring(Length(RESTART_SESSION_PREFIX));
  if Length(ID)<>32 then Exit;
  for var C in ID do if not CharInSet(C,['0'..'9','a'..'f']) then Exit;
  Result:=True;
end;

procedure PublishReaderRestart(const Profile, RequestFile: string);
var Value: TJSONObject; Destination, Temporary: string;
begin
  if not OwnedRestartRequest(Profile,RequestFile) or not FileExists(RequestFile) then
    raise Exception.Create('Invalid current-book restart session');
  ForceDirectories(ReaderRestartDirectory(Profile));
  Destination:=ReceiptFile(Profile,GetCurrentProcessId); Temporary:=Destination+'.new';
  Value:=TJSONObject.Create;
  try
    Value.AddPair('format',TJSONNumber.Create(1));
    Value.AddPair('pid',TJSONNumber.Create(GetCurrentProcessId));
    Value.AddPair('created',ReaderProcessStamp(GetCurrentProcess));
    Value.AddPair('request',TPath.GetFullPath(RequestFile));
    TFile.WriteAllText(Temporary,Value.ToJSON,TEncoding.UTF8);
  finally Value.Free; end;
  if not MoveFileEx(PChar(Temporary),PChar(Destination),MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function ReadReaderRestart(const Profile: string; PID: Cardinal;
  const ProcessStamp: string): string;
var FileName, Stamp: string; Stream: TFileStream; Data: TBytes;
  Value: TJSONValue; Version, RecordedPID: Int64;
begin
  Result:=''; FileName:=ReceiptFile(Profile,PID);
  if not FileExists(FileName) then Exit;
  Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size<1) or (Stream.Size>8192) then
      raise Exception.Create('Invalid current-book restart receipt size');
    SetLength(Data,Stream.Size); Stream.ReadBuffer(Data[0],Length(Data));
  finally Stream.Free; end;
  Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data).TrimLeft([#$FEFF]));
  try
    if not (Value is TJSONObject) or
      not TJSONObject(Value).TryGetValue<Int64>('format',Version) or (Version<>1) or
      not TJSONObject(Value).TryGetValue<Int64>('pid',RecordedPID) or (RecordedPID<>PID) or
      not TJSONObject(Value).TryGetValue<string>('created',Stamp) then
      raise Exception.Create('Invalid current-book restart receipt');
    if Stamp<>ProcessStamp then Exit; // A stale receipt belongs to an exited process.
    if not TJSONObject(Value).TryGetValue<string>('request',Result) or
      not OwnedRestartRequest(Profile,Result) then
      raise Exception.Create('Invalid current-book restart request path');
  finally Value.Free; end;
end;

procedure RemoveReaderRestart(const Profile: string);
begin
  Winapi.Windows.DeleteFile(PChar(ReceiptFile(Profile,GetCurrentProcessId)));
end;

procedure CleanupReaderRestartSession(const Profile, RequestFile: string);
var Folder: string;
begin
  if not OwnedRestartRequest(Profile,RequestFile) then Exit;
  // The updater may still hold the request. Leave it for the resumed Reader;
  // never recursively delete a directory or remove unrelated cached inputs.
  if not Winapi.Windows.DeleteFile(PChar(RequestFile)) then Exit;
  Folder:=ExtractFileDir(RequestFile);
  Winapi.Windows.DeleteFile(PChar(TPath.Combine(Folder,'response.json')));
  Winapi.Windows.RemoveDirectory(PChar(Folder));
end;

end.
