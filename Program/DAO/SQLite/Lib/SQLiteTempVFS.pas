unit SQLiteTempVFS;

interface

uses System.SysUtils, System.Generics.Collections, Winapi.Windows, SQLite3;

type
  PSQLiteVFS=^TSQLiteVFS;
  TSQLiteVFS=record
    Version,FileSize,MaxPath:Integer;
    Next:PSQLiteVFS;
    Name:PUTF8Char;
    Data:Pointer;
    Open:function(VFS:PSQLiteVFS; Name:PUTF8Char; FileObject:Pointer; Flags:Integer; OutFlags:PInteger):Integer; cdecl;
    Delete:function(VFS:PSQLiteVFS; Name:PUTF8Char; SyncDir:Integer):Integer; cdecl;
    Access:function(VFS:PSQLiteVFS; Name:PUTF8Char; Flags:Integer; OutResult:PInteger):Integer; cdecl;
    FullPath:function(VFS:PSQLiteVFS; Name:PUTF8Char; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
    DLOpen:function(VFS:PSQLiteVFS; Name:PUTF8Char):Pointer; cdecl;
    DLError:procedure(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char); cdecl;
    DLSym:function(VFS:PSQLiteVFS; Handle:Pointer; Name:PUTF8Char):Pointer; cdecl;
    DLClose:procedure(VFS:PSQLiteVFS; Handle:Pointer); cdecl;
    Randomness:function(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
    Sleep:function(VFS:PSQLiteVFS; Microseconds:Integer):Integer; cdecl;
    CurrentTime:function(VFS:PSQLiteVFS; Output:PDouble):Integer; cdecl;
    LastError:function(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
    CurrentTime64:function(VFS:PSQLiteVFS; Output:PInt64):Integer; cdecl;
    SetSystemCall:function(VFS:PSQLiteVFS; Name:PUTF8Char; Call:Pointer):Integer; cdecl;
    GetSystemCall:function(VFS:PSQLiteVFS; Name:PUTF8Char):Pointer; cdecl;
    NextSystemCall:function(VFS:PSQLiteVFS; Name:PUTF8Char):PUTF8Char; cdecl;
  end;

  // One opt-in connection. No process environment, default VFS or global
  // sqlite3_temp_directory changes. Free only after sqlite3_close succeeds.
  TSQLiteTemporaryVFS=class
  private
    FNative:TSQLiteVFS;
    FParent:PSQLiteVFS;
    FName:UTF8String;
    FDirectory:string;
    FGuard:THandle;
    FRegistered:Boolean;
    // SQLite permits a VFS to retain filenames until xClose. Keep allocated
    // sqlite3_filename objects even longer, until this connection is closed.
    FNames:TList<PUTF8Char>;
    FError:string;
    function TemporaryName:PUTF8Char;
    procedure CheckSpace;
    procedure Failed(const Text:string);
  public
    constructor Create(const Directory:string);
    destructor Destroy; override;
    function Name:PUTF8Char;
    function ErrorText:string;
    function FilesCreated:Integer;
  end;

implementation

uses System.Classes, System.IOUtils;

type ESQLiteTemporarySpace=class(Exception);

function SQLiteVFSFind(Name:PUTF8Char):PSQLiteVFS; cdecl; external SQLiteDLL name 'sqlite3_vfs_find';
function SQLiteVFSRegister(VFS:PSQLiteVFS; Default:Integer):Integer; cdecl; external SQLiteDLL name 'sqlite3_vfs_register';
function SQLiteVFSUnregister(VFS:PSQLiteVFS):Integer; cdecl; external SQLiteDLL name 'sqlite3_vfs_unregister';
function SQLiteFilename(Database,Journal,WAL:PUTF8Char; Count:Integer; Params:Pointer):PUTF8Char; cdecl; external SQLiteDLL name 'sqlite3_create_filename';
procedure SQLiteFreeFilename(Name:PUTF8Char); cdecl; external SQLiteDLL name 'sqlite3_free_filename';

function Owner(VFS:PSQLiteVFS):TSQLiteTemporaryVFS; inline;
begin Result:=TSQLiteTemporaryVFS(VFS.Data); end;

procedure NoteFailure(VFS:PSQLiteVFS; const Text:string);
begin
  // In particular, reporting an allocation failure must not raise across C.
  try Owner(VFS).Failed(Text); except end;
end;

function RoutedOpen(VFS:PSQLiteVFS; Name:PUTF8Char; FileObject:Pointer; Flags:Integer; OutFlags:PInteger):Integer; cdecl;
begin
  try
    var Item:=Owner(VFS);
    if Name=nil then
    begin
      // SQLite promises DELETEONCLOSE for anonymous files. Refuse an unknown
      // request rather than letting an error spill into the system temp folder.
      if (Flags and SQLITE_OPEN_DELETEONCLOSE)=0 then Exit(SQLITE_CANTOPEN);
      Item.CheckSpace; Name:=Item.TemporaryName;
      if Name=nil then Exit(SQLITE_NOMEM);
      Flags:=Flags or SQLITE_OPEN_EXCLUSIVE;
    end;
    Result:=Item.FParent.Open(Item.FParent,Name,FileObject,Flags,OutFlags);
  except
    on E:EOutOfMemory do begin NoteFailure(VFS,E.Message); Result:=SQLITE_NOMEM; end;
    on E:ESQLiteTemporarySpace do begin NoteFailure(VFS,E.Message); Result:=SQLITE_FULL; end;
    on E:Exception do begin NoteFailure(VFS,E.Message); Result:=SQLITE_CANTOPEN; end;
  end;
end;

function ForwardDelete(VFS:PSQLiteVFS; Name:PUTF8Char; SyncDir:Integer):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.Delete(P,Name,SyncDir); end;
function ForwardAccess(VFS:PSQLiteVFS; Name:PUTF8Char; Flags:Integer; OutResult:PInteger):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.Access(P,Name,Flags,OutResult); end;
function ForwardFullPath(VFS:PSQLiteVFS; Name:PUTF8Char; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.FullPath(P,Name,Bytes,Output); end;
function ForwardDLOpen(VFS:PSQLiteVFS; Name:PUTF8Char):Pointer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.DLOpen(P,Name); end;
procedure ForwardDLError(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char); cdecl;
begin var P:=Owner(VFS).FParent; P.DLError(P,Bytes,Output); end;
function ForwardDLSym(VFS:PSQLiteVFS; Handle:Pointer; Name:PUTF8Char):Pointer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.DLSym(P,Handle,Name); end;
procedure ForwardDLClose(VFS:PSQLiteVFS; Handle:Pointer); cdecl;
begin var P:=Owner(VFS).FParent; P.DLClose(P,Handle); end;
function ForwardRandomness(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.Randomness(P,Bytes,Output); end;
function ForwardSleep(VFS:PSQLiteVFS; Microseconds:Integer):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.Sleep(P,Microseconds); end;
function ForwardTime(VFS:PSQLiteVFS; Output:PDouble):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.CurrentTime(P,Output); end;
function ForwardError(VFS:PSQLiteVFS; Bytes:Integer; Output:PUTF8Char):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.LastError(P,Bytes,Output); end;
function ForwardTime64(VFS:PSQLiteVFS; Output:PInt64):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.CurrentTime64(P,Output); end;
function ForwardSetCall(VFS:PSQLiteVFS; Name:PUTF8Char; Call:Pointer):Integer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.SetSystemCall(P,Name,Call); end;
function ForwardGetCall(VFS:PSQLiteVFS; Name:PUTF8Char):Pointer; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.GetSystemCall(P,Name); end;
function ForwardNextCall(VFS:PSQLiteVFS; Name:PUTF8Char):PUTF8Char; cdecl;
begin var P:=Owner(VFS).FParent; Result:=P.NextSystemCall(P,Name); end;

constructor TSQLiteTemporaryVFS.Create(const Directory:string);
begin
  inherited Create; FGuard:=INVALID_HANDLE_VALUE;
  FNames:=TList<PUTF8Char>.Create;
  if not TPath.IsPathRooted(Directory) then raise EArgumentException.Create('Нужна абсолютная рабочая папка SQLite.');
  var NativeDirectory:=TPath.GetFullPath(Directory);
  if not NativeDirectory.StartsWith('\\?\') then
    if NativeDirectory.StartsWith('\\') then NativeDirectory:='\\?\UNC\'+Copy(NativeDirectory,3,MaxInt)
    else NativeDirectory:='\\?\'+NativeDirectory;
  FGuard:=CreateFile(PChar(NativeDirectory),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FGuard=INVALID_HANDLE_VALUE then RaiseLastOSError;
  var Info:TByHandleFileInformation;
  if not GetFileInformationByHandle(FGuard,Info) then RaiseLastOSError;
  if (Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY=0) or
    (Info.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT<>0) then
    raise EArgumentException.Create('Рабочая папка SQLite недоступна или является ссылкой.');
  var Buffer:TArray<Char>; SetLength(Buffer,32768);
  var Count:=GetFinalPathNameByHandle(FGuard,@Buffer[0],Length(Buffer),0);
  if Count=0 then RaiseLastOSError;
  if Count>=DWORD(Length(Buffer)) then raise EArgumentException.Create('Слишком длинный рабочий путь SQLite.');
  SetString(FDirectory,PChar(@Buffer[0]),Count);
  FDirectory:=IncludeTrailingPathDelimiter(FDirectory);
  FParent:=SQLiteVFSFind('win32-longpath');
  if FParent=nil then FParent:=SQLiteVFSFind(nil);
  if (FParent=nil) or not (FParent.Version in [1..3]) then
    raise EInvalidOperation.Create('Неизвестный файловый интерфейс SQLite.');
  if Length(TEncoding.UTF8.GetBytes(FDirectory))+80>FParent.MaxPath then
    raise EArgumentException.Create('Слишком длинный рабочий путь SQLite.');
  FName:=UTF8String('HomeLibre-temp-'+GUIDToString(TGUID.NewGuid));
  FNative:=Default(TSQLiteVFS); FNative.Version:=FParent.Version;
  FNative.FileSize:=FParent.FileSize; FNative.MaxPath:=FParent.MaxPath;
  FNative.Name:=PUTF8Char(FName); FNative.Data:=Self;
  FNative.Open:=RoutedOpen; FNative.Delete:=ForwardDelete;
  FNative.Access:=ForwardAccess; FNative.FullPath:=ForwardFullPath;
  if Assigned(FParent.DLOpen) then FNative.DLOpen:=ForwardDLOpen;
  if Assigned(FParent.DLError) then FNative.DLError:=ForwardDLError;
  if Assigned(FParent.DLSym) then FNative.DLSym:=ForwardDLSym;
  if Assigned(FParent.DLClose) then FNative.DLClose:=ForwardDLClose;
  FNative.Randomness:=ForwardRandomness; FNative.Sleep:=ForwardSleep;
  FNative.CurrentTime:=ForwardTime;
  if Assigned(FParent.LastError) then FNative.LastError:=ForwardError;
  if FNative.Version>=2 then
    if Assigned(FParent.CurrentTime64) then FNative.CurrentTime64:=ForwardTime64;
  if FNative.Version>=3 then
  begin
    if Assigned(FParent.SetSystemCall) then FNative.SetSystemCall:=ForwardSetCall;
    if Assigned(FParent.GetSystemCall) then FNative.GetSystemCall:=ForwardGetCall;
    if Assigned(FParent.NextSystemCall) then FNative.NextSystemCall:=ForwardNextCall;
  end;
  if SQLiteVFSRegister(@FNative,0)<>SQLITE_OK then raise EInvalidOperation.Create('Не удалось назначить рабочую папку SQLite.');
  FRegistered:=True;
end;

destructor TSQLiteTemporaryVFS.Destroy;
begin
  if FRegistered then SQLiteVFSUnregister(@FNative);
  if FNames<>nil then for var Item in FNames do SQLiteFreeFilename(Item);
  FNames.Free;
  if FGuard<>INVALID_HANDLE_VALUE then CloseHandle(FGuard);
  inherited;
end;

function TSQLiteTemporaryVFS.Name:PUTF8Char;
begin Result:=PUTF8Char(FName); end;

function TSQLiteTemporaryVFS.TemporaryName:PUTF8Char;
begin
  var Path:=UTF8String(FDirectory+'sqlite-temp-'+GUIDToString(TGUID.NewGuid));
  Result:=SQLiteFilename(PUTF8Char(Path),'','',0,nil);
  if Result=nil then Exit;
  try
    TMonitor.Enter(Self);
    try FNames.Add(Result); finally TMonitor.Exit(Self); end;
  except SQLiteFreeFilename(Result); raise; end;
end;

procedure TSQLiteTemporaryVFS.CheckSpace;
  procedure Require(const Path:string; Reserve:UInt64);
  var FreeBytes,Total:UInt64;
  begin
    if not GetDiskFreeSpaceEx(PChar(Path),FreeBytes,Total,nil) then RaiseLastOSError;
    if FreeBytes<Reserve then raise ESQLiteTemporarySpace.Create('Недостаточно места для временных файлов SQLite: '+Path);
  end;
begin
  var SystemRoot:=GetEnvironmentVariable('SystemDrive'); if SystemRoot='' then SystemRoot:='C:';
  Require(IncludeTrailingPathDelimiter(SystemRoot),UInt64(8)*1024*1024*1024);
  Require(FDirectory,UInt64(512)*1024*1024);
end;

procedure TSQLiteTemporaryVFS.Failed(const Text:string);
begin TMonitor.Enter(Self); try FError:=Text; finally TMonitor.Exit(Self); end; end;

function TSQLiteTemporaryVFS.ErrorText:string;
begin TMonitor.Enter(Self); try Result:=FError; finally TMonitor.Exit(Self); end; end;

function TSQLiteTemporaryVFS.FilesCreated:Integer;
begin TMonitor.Enter(Self); try Result:=FNames.Count; finally TMonitor.Exit(Self); end; end;

end.
