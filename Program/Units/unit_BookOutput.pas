unit unit_BookOutput;

interface

uses System.SysUtils;

type
  TBookNameCollision = (bncAsk, bncReplace, bncKeepBoth);
  TBookCollisionPrompt = reference to function(const FileName: string;
    out ReplaceFile, ApplyToAll: Boolean): Boolean;
  TBookCollisionResolver = reference to function(const FileName: string;
    out ReplaceFile: Boolean): Boolean;

// Keep the user's complete directory path. Only individual generated file
// names are bounded; temporary names never repeat the full book title.
function BookOutputPath(const FileName: string): string;
function BookOutputExists(const FileName: string): Boolean;
function SameBookOutputFile(const Left, Right: string): Boolean;
function BookOutputName(const BaseName, Extension: string; BookID: Integer): string;
function CreateBookOutputStage(const TargetFile: string): string;
procedure PublishBookOutput(const Stage, TargetFile: string;
  OverwriteExisting: Boolean = False; const ProtectedSource: string = '');
procedure DeleteBookOutputStage(const Stage: string);

implementation

uses Winapi.Windows, System.IOUtils;

function BookOutputPath(const FileName: string): string;
begin
  Result:=TPath.GetFullPath(FileName);
  if Result.StartsWith('\\?\') or (Length(Result)<240) then Exit;
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Result.Substring(2)
  else Result:='\\?\'+Result;
end;

function BookOutputExists(const FileName: string): Boolean;
begin
  Result:=GetFileAttributes(PChar(BookOutputPath(FileName)))<>INVALID_FILE_ATTRIBUTES;
end;

function SameBookOutputFile(const Left, Right: string): Boolean;
var A, B: THandle; InfoA, InfoB: TByHandleFileInformation;
begin
  Result:=False;
  if (Left='') or (Right='') then Exit;
  if SameText(BookOutputPath(Left),BookOutputPath(Right)) then Exit(True);
  if not BookOutputExists(Left) or not BookOutputExists(Right) then Exit;
  A:=CreateFile(PChar(BookOutputPath(Left)),FILE_READ_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if A=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    B:=CreateFile(PChar(BookOutputPath(Right)),FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    if B=INVALID_HANDLE_VALUE then RaiseLastOSError;
    try
      if not GetFileInformationByHandle(A,InfoA) or not GetFileInformationByHandle(B,InfoB) then RaiseLastOSError;
      Result:=(InfoA.dwVolumeSerialNumber=InfoB.dwVolumeSerialNumber) and
        (InfoA.nFileIndexHigh=InfoB.nFileIndexHigh) and (InfoA.nFileIndexLow=InfoB.nFileIndexLow);
    finally CloseHandle(B); end;
  finally CloseHandle(A); end;
end;

function BookOutputName(const BaseName, Extension: string; BookID: Integer): string;
var Limit: Integer; Suffix: string;
begin
  Result:=BaseName;
  // Leave room for the actual format suffix and a collision number. Windows
  // limits one path component independently of the complete path length.
  Limit:=255-Length(Extension)-16;
  if Length(Result)<=Limit then Exit;
  Suffix:='-'+IntToStr(BookID);
  Result:=Copy(Result,1,Limit-Length(Suffix));
  if (Result<>'') and (Ord(Result[Length(Result)])>=$D800) and
    (Ord(Result[Length(Result)])<=$DBFF) then Delete(Result,Length(Result),1);
  Result:=Result+Suffix;
end;

function CreateBookOutputStage(const TargetFile: string): string;
var Folder: string; Handle: THandle;
begin
  Folder:=ExtractFilePath(TPath.GetFullPath(TargetFile));
  if not ForceDirectories(BookOutputPath(Folder)) then
    raise EInOutError.Create('Не удалось создать папку сохранения: '+Folder);
  Result:=BookOutputPath(TPath.Combine(Folder,'.homelib-book-'+
    TGUID.NewGuid.ToString.Replace('{','').Replace('}','').Replace('-','')+'.tmp'));
  Handle:=CreateFile(PChar(Result),GENERIC_WRITE,0,nil,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then RaiseLastOSError;
  CloseHandle(Handle);
end;

procedure PublishBookOutput(const Stage, TargetFile: string;
  OverwriteExisting: Boolean; const ProtectedSource: string);
var Flags: DWORD;
begin
  if OverwriteExisting and SameBookOutputFile(TargetFile,ProtectedSource) then
    raise EInOutError.Create('Папка и имя результата совпадают с исходной книгой. Выберите другую папку или маску имени.');
  // Replacement is one same-volume publication after the complete copy has
  // been prepared. Without explicit consent even a racing file stays intact.
  Flags:=MOVEFILE_WRITE_THROUGH;
  if OverwriteExisting then Flags:=Flags or MOVEFILE_REPLACE_EXISTING;
  if not MoveFileEx(PChar(Stage),PChar(BookOutputPath(TargetFile)),Flags) then
    RaiseLastOSError;
end;

procedure DeleteBookOutputStage(const Stage: string);
begin
  if (Stage<>'') and ExtractFileName(Stage).StartsWith('.homelib-book-') and
    SameText(ExtractFileExt(Stage),'.tmp') then Winapi.Windows.DeleteFile(PChar(Stage));
end;

end.
