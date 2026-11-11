unit unit_BookDeletionSpace;

interface

type
  TDeletionFileSpace = record
    Path, Volume, Identity: string;
    Bytes: Int64;
    Links: Cardinal;
    Known, Exists: Boolean;
  end;

  TDeletionVolumeSpace = record
    Volume: string;
    // Defensive signed accounting never reports unexpected growth as savings.
    // The 7z planner rejects a larger result before writing the source.
    ReleasedBytes: Int64;
    UnmeasuredFiles: Integer;
  end;

function CaptureDeletionSpace(const Paths: TArray<string>): TArray<TDeletionFileSpace>;
function MeasureDeletionSpace(const Before: TArray<TDeletionFileSpace>): TArray<TDeletionVolumeSpace>;
procedure AddDeletionSpace(var Total: TArray<TDeletionVolumeSpace>;
  const Changes: TArray<TDeletionVolumeSpace>);

implementation

uses Winapi.Windows, System.SysUtils, System.Generics.Collections;

function NativePath(const Path: string): string;
begin
  Result:=ExpandFileName(Path);
  if Result.StartsWith('\\?\') then Exit;
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Result.Substring(2)
  else Result:='\\?\'+Result;
end;

function DisplayPath(const Path: string): string;
begin
  Result:=Path;
  if Result.StartsWith('\\?\UNC\') then Result:='\\'+Result.Substring(8)
  else if Result.StartsWith('\\?\') then Result:=Result.Substring(4);
end;

function FileSpace(const Path: string): TDeletionFileSpace;
var Native: string; Volume: TArray<Char>; Attributes, LowPart, HighPart, Error: DWORD;
  Handle: THandle; Info: TByHandleFileInformation; Bytes: UInt64;
begin
  Result:=Default(TDeletionFileSpace); Result.Path:=Path;
  // Progress accounting must never prevent or change a deletion.
  try
    Native:=NativePath(Path);
    Result.Volume:=IncludeTrailingPathDelimiter(ExtractFileDrive(DisplayPath(Native)));
    SetLength(Volume,32768);
    if GetVolumePathName(PChar(Native),PChar(Volume),Length(Volume)) then
      Result.Volume:=DisplayPath(PChar(Volume));
    Attributes:=GetFileAttributes(PChar(Native));
    if Attributes=INVALID_FILE_ATTRIBUTES then
    begin
      Error:=GetLastError;
      Result.Known:=Error in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND];
      Exit;
    end;
    Result.Exists:=True;
    if Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)<>0 then Exit;
    Handle:=CreateFile(PChar(Native),FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,0,0);
    if Handle=INVALID_HANDLE_VALUE then Exit;
    try
      if not GetFileInformationByHandle(Handle,Info) then Exit;
      Result.Identity:=Format('%.8x:%.8x:%.8x',
        [Info.dwVolumeSerialNumber,Info.nFileIndexHigh,Info.nFileIndexLow]);
      Result.Links:=Info.nNumberOfLinks;
      SetLastError(NO_ERROR); HighPart:=0;
      LowPart:=GetCompressedFileSize(PChar(Native),@HighPart); Error:=GetLastError;
      if (LowPart=INVALID_FILE_SIZE) and (Error<>NO_ERROR) then Exit;
      Bytes:=UInt64(HighPart) shl 32 or LowPart;
      if Bytes>UInt64(High(Int64)) then Exit;
      Result.Bytes:=Int64(Bytes); Result.Known:=True;
    finally CloseHandle(Handle); end;
  except Result.Known:=False; end;
end;

function CaptureDeletionSpace(const Paths: TArray<string>): TArray<TDeletionFileSpace>;
var Seen: TDictionary<string,Byte>; Key: string; Count: Integer;
begin
  Seen:=TDictionary<string,Byte>.Create; Count:=0;
  try
    SetLength(Result,Length(Paths));
    for var Path in Paths do
    begin
      var Value:=FileSpace(Path);
      if Value.Identity<>'' then Key:=Value.Identity else Key:=LowerCase(Value.Path);
      if Seen.ContainsKey(Key) then Continue;
      Seen.Add(Key,0); Result[Count]:=Value; Inc(Count);
    end;
    SetLength(Result,Count);
  finally Seen.Free; end;
end;

procedure AddDeletionSpace(var Total: TArray<TDeletionVolumeSpace>;
  const Changes: TArray<TDeletionVolumeSpace>);
var Index: Integer;
begin
  for var Change in Changes do
  begin
    Index:=-1;
    for var I:=0 to High(Total) do
      if SameText(Total[I].Volume,Change.Volume) then begin Index:=I; Break; end;
    if Index<0 then
    begin
      Index:=Length(Total); SetLength(Total,Index+1); Total[Index].Volume:=Change.Volume;
    end;
    Inc(Total[Index].ReleasedBytes,Change.ReleasedBytes);
    Inc(Total[Index].UnmeasuredFiles,Change.UnmeasuredFiles);
  end;
end;

function MeasureDeletionSpace(const Before: TArray<TDeletionFileSpace>): TArray<TDeletionVolumeSpace>;
var Change: TDeletionVolumeSpace;
begin
  Result:=nil;
  for var Previous in Before do
  begin
    Change:=Default(TDeletionVolumeSpace); Change.Volume:=Previous.Volume;
    var Current:=FileSpace(Previous.Path);
    if not Previous.Known or not Current.Known then Change.UnmeasuredFiles:=1
    else if Previous.Exists then
    begin
      if not Current.Exists then
      begin
        // Unlinking one hard-link name does not release the other names' data.
        if Previous.Links=1 then Change.ReleasedBytes:=Previous.Bytes;
      end
      else if Previous.Identity=Current.Identity then Change.ReleasedBytes:=Previous.Bytes-Current.Bytes
      else Change.UnmeasuredFiles:=1;
    end
    else if Current.Exists then Change.UnmeasuredFiles:=1;
    AddDeletionSpace(Result,[Change]);
  end;
end;

end.
