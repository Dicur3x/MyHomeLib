unit unit_LibraryUpdateFetch;

interface

uses System.SysUtils, System.Classes, System.Net.HttpClient, Winapi.Windows,
  unit_LibraryUpdateSources;

type
  TLibraryIndexProgress = reference to procedure(Done, Total: Int64);
  TStagedLibraryIndex = class
  private
    FFolder, FFileName, FSHA256: string;
    FDirectoryHandle: THandle;
    FLease: TFileStream;
    FOwned: Boolean;
    procedure CreateFolder(const Root: string);
  public
    destructor Destroy; override;
    class function Fetch(const Source: TLibraryUpdateSource; const CacheRoot: string;
      HTTP: THTTPClient; const Check: TProc = nil;
      const Progress: TLibraryIndexProgress = nil): TStagedLibraryIndex; static;
    procedure CopyVerified(const Destination: string; const Check: TProc;
      const Progress: TLibraryIndexProgress = nil);
    property FileName: string read FFileName;
    property Folder: string read FFolder;
    property SHA256: string read FSHA256;
  end;

implementation

uses System.IOUtils, System.Hash, System.NetEncoding;

const MaxIndexBytes: Int64 = 1024*1024*1024;

function NativePath(const Value: string): string;
begin
  if Value.StartsWith('\\?\') then Exit(Value);
  Result:=TPath.GetFullPath(Value);
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Result.Substring(2)
  else Result:='\\?\'+Result;
end;

procedure CheckSpace(const Folder: string; Needed: UInt64);
var Available, Capacity: UInt64; SystemRoot: string;
begin
  SystemRoot:=GetEnvironmentVariable('SystemDrive')+'\';
  if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
  if Available<UInt64(8)*1024*1024*1024 then
    raise EWriteError.Create('На системном диске осталось меньше 8 ГБ. Получение каталога остановлено.');
  if not GetDiskFreeSpaceEx(PChar(NativePath(Folder)),Available,Capacity,nil) then RaiseLastOSError;
  if (Available<Needed) or (Available-Needed<UInt64(512)*1024*1024) then
    raise EWriteError.Create('Недостаточно места для служебной копии каталога. Исходный индекс не изменён.');
end;

type
  TIndexOutput = class(TFileStream)
  private
    FFolder: string;
    FCheck: TProc;
    FProgress: TLibraryIndexProgress;
    FTotal: Int64;
  public
    constructor Create(const Name, Folder: string; const Check: TProc;
      const Progress: TLibraryIndexProgress; Total: Int64);
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

constructor TIndexOutput.Create(const Name, Folder: string; const Check: TProc;
  const Progress: TLibraryIndexProgress; Total: Int64);
begin
  inherited Create(NativePath(Name),fmCreate);
  FFolder:=Folder; FCheck:=Check; FProgress:=Progress; FTotal:=Total;
end;

function TIndexOutput.Write(const Buffer; Count: Longint): Longint;
begin
  if Assigned(FCheck) then FCheck;
  if (Count<0) or (Position>MaxIndexBytes-Count) then
    raise EWriteError.Create('Индекс превышает предел 1 ГБ. Загрузка остановлена.');
  CheckSpace(FFolder,UInt64(Count));
  Result:=inherited Write(Buffer,Count);
  if Assigned(FProgress) then FProgress(Position,FTotal);
end;

procedure TStagedLibraryIndex.CreateFolder(const Root: string);
var Parent, Candidate: string; Length, Written: DWORD; Attributes: DWORD;
begin
  FDirectoryHandle:=INVALID_HANDLE_VALUE;
  Parent:=TPath.GetFullPath(Root);
  while not DirectoryExists(NativePath(Parent)) do
  begin
    Candidate:=TPath.GetDirectoryName(Parent);
    if (Candidate='') or (Candidate=Parent) then raise EDirectoryNotFoundException.Create('Рабочая папка недоступна.');
    Parent:=Candidate;
  end;
  CheckSpace(Parent,0);
  ForceDirectories(NativePath(Root));
  FFolder:=TPath.Combine(TPath.GetFullPath(Root),'HomeLibre-index-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(NativePath(FFolder)),nil) then RaiseLastOSError;
  FOwned:=True;
  FDirectoryHandle:=CreateFile(PChar(NativePath(FFolder)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,0);
  if FDirectoryHandle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  Attributes:=GetFileAttributes(PChar(NativePath(FFolder)));
  if (Attributes=INVALID_FILE_ATTRIBUTES) or ((Attributes and FILE_ATTRIBUTE_REPARSE_POINT)<>0) then
    raise EReadError.Create('Рабочая папка была подменена.');
  Length:=GetFinalPathNameByHandle(FDirectoryHandle,nil,0,0);
  if Length=0 then RaiseLastOSError;
  SetLength(Candidate,Length);
  Written:=GetFinalPathNameByHandle(FDirectoryHandle,PChar(Candidate),Length,0);
  if (Written=0) or (Written>=Length) then RaiseLastOSError;
  SetLength(Candidate,Written); FFolder:=Candidate;
end;

function SourceURL(const Source: TLibraryUpdateSource): string;
var Part: string;
begin
  Result:=Source.Location.TrimRight(['/']);
  for Part in Source.IndexFile.Replace('\','/').Split(['/']) do
    Result:=Result+'/'+TNetEncoding.URL.Encode(Part).Replace('+','%20');
end;

class function TStagedLibraryIndex.Fetch(const Source: TLibraryUpdateSource;
  const CacheRoot: string; HTTP: THTTPClient; const Check: TProc;
  const Progress: TLibraryIndexProgress): TStagedLibraryIndex;
var Input: TFileStream; Output: TIndexOutput; Response: IHTTPResponse;
begin
  Source.Validate;
  if Source.IsRemote and not Assigned(HTTP) then raise EArgumentNilException.Create('HTTP');
  if Assigned(Check) then Check;
  Result:=TStagedLibraryIndex.Create;
  Result.FDirectoryHandle:=INVALID_HANDLE_VALUE;
  try
    Result.CreateFolder(CacheRoot);
    Result.FFileName:=TPath.Combine(Result.FFolder,TPath.GetFileName(Source.IndexFile.Replace('/',PathDelim)));
    if Source.IsRemote then
    begin
      Output:=TIndexOutput.Create(Result.FFileName,Result.FFolder,Check,Progress,0);
      try
        Response:=HTTP.Get(SourceURL(Source),Output);
        if (Response.StatusCode<200) or (Response.StatusCode>=300) then
          raise EReadError.CreateFmt('Сервер не выдал каталог: HTTP %d.',[Response.StatusCode]);
      finally Output.Free; end;
    end
    else
    begin
      // The source is read-only and cannot be rewritten/replaced while copied.
      Input:=TFileStream.Create(NativePath(Source.LocalFile),fmOpenRead or fmShareDenyWrite);
      try
        if (Input.Size<=0) or (Input.Size>MaxIndexBytes) then raise EReadError.Create('Индекс пуст или превышает 1 ГБ.');
        CheckSpace(Result.FFolder,UInt64(Input.Size));
        Output:=TIndexOutput.Create(Result.FFileName,Result.FFolder,Check,Progress,Input.Size);
        try Output.CopyFrom(Input,Input.Size); finally Output.Free; end;
      finally Input.Free; end;
    end;
    if Assigned(Check) then Check;
    Result.FLease:=TFileStream.Create(NativePath(Result.FFileName),fmOpenRead or fmShareDenyWrite);
    if Result.FLease.Size<=0 then raise EReadError.Create('Получен пустой индекс.');
    Result.FSHA256:=THashSHA2.GetHashString(Result.FLease); Result.FLease.Position:=0;
  except Result.Free; raise; end;
end;

procedure TStagedLibraryIndex.CopyVerified(const Destination: string; const Check: TProc;
  const Progress: TLibraryIndexProgress);
var Input:TFileStream; Output:TIndexOutput; Folder:string;
begin
  Folder:=TPath.GetDirectoryName(Destination);
  Input:=TFileStream.Create(NativePath(FFileName),fmOpenRead or fmShareDenyWrite);
  try
    CheckSpace(Folder,UInt64(Input.Size));
    Output:=TIndexOutput.Create(Destination,Folder,Check,Progress,Input.Size);
    try
      Output.CopyFrom(Input,Input.Size);
      if not FlushFileBuffers(Output.Handle) then RaiseLastOSError;
    finally Output.Free; end;
  finally Input.Free; end;
  if not SameText(THashSHA2.GetHashStringFromFile(NativePath(Destination)),FSHA256) then
    raise EReadError.Create('Не совпала контрольная сумма копии индекса обновления.');
end;

destructor TStagedLibraryIndex.Destroy;
begin
  FLease.Free;
  if FOwned and (FFolder<>'') then
  begin
    if FFileName<>'' then Winapi.Windows.DeleteFile(PChar(NativePath(FFileName)));
    if (FDirectoryHandle<>0) and (FDirectoryHandle<>INVALID_HANDLE_VALUE) then
    begin CloseHandle(FDirectoryHandle); FDirectoryHandle:=INVALID_HANDLE_VALUE; end;
    // Never recurse: unexpected files remain visible rather than being deleted.
    RemoveDirectory(PChar(NativePath(FFolder)));
  end;
  inherited;
end;

end.
