unit unit_ExplorerImport;

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, Winapi.ActiveX;

const
  EXPLORER_IMPORT_SWITCH = '--import';
  EXPLORER_IMPORT_ACK = $484C494D;

function ReadExplorerImportArguments(out Paths: TArray<string>): Boolean;
function DeliverExplorerImport(Target: HWND; const Paths: TArray<string>): Boolean;
function ReadExplorerImport(const Message: TMessage; out Paths: TArray<string>): Boolean;
function ReadDroppedImportFiles(Drop: HDROP): TArray<string>;
function ExplorerDropHasFiles(const Data: IDataObject): Boolean;
function ReadExplorerDropData(const Data: IDataObject): TArray<string>;
function ToggleExplorerImportShortcut: Boolean;

implementation

uses
  Winapi.ShlObj, System.SysUtils, System.IOUtils,
  System.Win.ComObj, Vcl.Forms;

const
  MAX_IMPORT_PATH = 32767;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  SHORTCUT_MARKER = 'HomeLibre portable book import';
  SHORTCUT_NAME = 'Добавить в HomeLibre.lnk';
  FILE_DROP_FORMAT: TFormatEtc = (cfFormat: CF_HDROP; ptd: nil;
    dwAspect: DVASPECT_CONTENT; lindex: -1; tymed: TYMED_HGLOBAL);

function ProcessImageName(Process: THandle; Flags: DWORD; Buffer: PWideChar;
  var Length: DWORD): BOOL; stdcall;
  external kernel32 name 'QueryFullProcessImageNameW';

function IsExplorerImportPath(const Path: string): Boolean;
var Drive: string;
begin
  Result := False;
  if (Length(Path) > MAX_IMPORT_PATH) or (Pos(#0, Path) <> 0) or
    (Pos(#10, Path) <> 0) or (Pos(#13, Path) <> 0) or
    Path.StartsWith('\\.\') or Path.StartsWith('\\?\') then Exit;
  Drive := ExtractFileDrive(Path);
  Result := (Drive <> '') and (Length(Path) > Length(Drive) + 1) and
    CharInSet(Path[Length(Drive) + 1], ['\', '/']) and
    (ExtractFileName(Path) <> '') and (Pos(':', Copy(Path, Length(Drive) + 1, MaxInt)) = 0);
end;

function ReadExplorerImportArguments(out Paths: TArray<string>): Boolean;
begin
  Paths := nil;
  if ParamCount < 2 then Exit(False);
  SetLength(Paths, ParamCount - 1);
  for var I := 0 to High(Paths) do
  begin
    Paths[I] := ParamStr(I + 2);
    if not IsExplorerImportPath(Paths[I]) then
    begin
      Paths := nil;
      Exit(False);
    end;
  end;
  Result := True;
end;

function DeliverExplorerImport(Target: HWND; const Paths: TArray<string>): Boolean;
var
  PID, Size: DWORD;
  Process: THandle;
  TargetPath, Payload: string;
  Packet: TCopyDataStruct;
  Ack: DWORD_PTR;
begin
  Result := False;
  if Length(Paths) = 0 then Exit;
  Payload := string.Join(#10, Paths);
  if (Length(Payload) > MAX_IMPORT_PATH) or (GetWindowThreadProcessId(Target, @PID) = 0) then Exit;
  Process := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, PID);
  if Process = 0 then Exit;
  try
    Size := MAX_IMPORT_PATH;
    SetLength(TargetPath, Size);
    if not ProcessImageName(Process, 0, PChar(TargetPath), Size) then Exit;
    SetLength(TargetPath, Size);
    if not SameFileName(TargetPath, Application.ExeName) then Exit;
    Packet.dwData := EXPLORER_IMPORT_ACK;
    Packet.cbData := (Length(Payload) + 1) * SizeOf(Char);
    Packet.lpData := PChar(Payload);
    Ack := 0;
    Result := (SendMessageTimeout(Target, WM_COPYDATA, 0, LPARAM(@Packet),
      SMTO_ABORTIFHUNG or SMTO_BLOCK, 2000, @Ack) <> 0) and (Ack = EXPLORER_IMPORT_ACK);
  finally
    CloseHandle(Process);
  end;
end;

function ReadExplorerImport(const Message: TMessage; out Paths: TArray<string>): Boolean;
var
  Packet: PCopyDataStruct;
  Count: Integer;
  Payload, Path: string;
  Files: TArray<string>;
begin
  Result := False;
  Paths := nil;
  if (Message.Msg <> WM_COPYDATA) or (Message.LParam = 0) then Exit;
  Packet := PCopyDataStruct(Message.LParam);
  if (Packet.dwData <> EXPLORER_IMPORT_ACK) or (Packet.lpData = nil) or
    (Packet.cbData < 2 * SizeOf(Char)) or (Packet.cbData > (MAX_IMPORT_PATH + 1) * SizeOf(Char)) or
    (Packet.cbData mod SizeOf(Char) <> 0) then Exit;
  Count := Packet.cbData div SizeOf(Char) - 1;
  if PChar(Packet.lpData)[Count] <> #0 then Exit;
  SetString(Payload, PChar(Packet.lpData), Count);
  Files := Payload.Split([#10]);
  for Path in Files do
    if not IsExplorerImportPath(Path) then Exit;
  Paths := Files;
  Result := Length(Paths) > 0;
end;

function ReadDroppedImportFiles(Drop: HDROP): TArray<string>;
var
  Files: TArray<string>;
  Path: string;
  PathLength: UINT;
begin
  Result := nil;
  if Drop = 0 then Exit;
  SetLength(Files, DragQueryFileW(Drop, High(UINT), nil, 0));
  for var Index := 0 to High(Files) do
  begin
    PathLength := DragQueryFileW(Drop, Index, nil, 0);
    if (PathLength = 0) or (PathLength > MAX_IMPORT_PATH) then Exit;
    SetLength(Path, PathLength + 1);
    if DragQueryFileW(Drop, Index, PChar(Path), PathLength + 1) <> PathLength then Exit;
    SetLength(Path, PathLength);
    if not IsExplorerImportPath(Path) then Exit;
    Files[Index] := Path;
  end;
  Result := Files;
end;

function ExplorerDropHasFiles(const Data: IDataObject): Boolean;
begin
  Result := Assigned(Data) and (Data.QueryGetData(FILE_DROP_FORMAT) = S_OK);
end;

function ReadExplorerDropData(const Data: IDataObject): TArray<string>;
var Medium: TStgMedium;
begin
  Result := nil;
  if not Assigned(Data) or (Data.GetData(FILE_DROP_FORMAT, Medium) <> S_OK) then Exit;
  try
    if Medium.tymed = TYMED_HGLOBAL then Result := ReadDroppedImportFiles(Medium.hGlobal);
  finally
    ReleaseStgMedium(Medium);
  end;
end;

function ToggleExplorerImportShortcut: Boolean;
var
  Path: string;
  SendTo: array[0..MAX_PATH] of Char;
  Buffer: array[0..MAX_PATH] of Char;
  FindData: TWin32FindDataW;
  Link: IShellLinkW;
  LinkFile: IPersistFile;
  Initialized: HRESULT;

  function RepairLegacyShortcut(const Directory: string): Boolean;
  var
    LegacyEncoding: TEncoding;
    LegacyPath: string;
    LegacyLink: IShellLinkW;
    LegacyFile: IPersistFile;
  begin
    // Beta 5 compiled the UTF-8 name as Windows-1251. Repair only a link
    // owned by this installation and only when the user enables the command.
    LegacyEncoding := TEncoding.GetEncoding(1251);
    try
      LegacyPath := TPath.Combine(Directory,
        LegacyEncoding.GetString(TEncoding.UTF8.GetBytes(SHORTCUT_NAME)));
    finally
      LegacyEncoding.Free;
    end;
    Result := False;
    if not FileExists(LegacyPath) then Exit;
    LegacyLink := CreateComObject(CLSID_ShellLink) as IShellLinkW;
    LegacyFile := LegacyLink as IPersistFile;
    if Failed(LegacyFile.Load(PChar(LegacyPath), STGM_READ)) then Exit;
    if Failed(LegacyLink.GetDescription(Buffer, Length(Buffer))) or
      (string(PChar(@Buffer[0])) <> SHORTCUT_MARKER) then Exit;
    if Failed(LegacyLink.GetPath(Buffer, Length(Buffer), FindData, SLGP_RAWPATH)) or
      not SameFileName(string(PChar(@Buffer[0])), Application.ExeName) then Exit;
    if Failed(LegacyLink.GetArguments(Buffer, Length(Buffer))) or
      (string(PChar(@Buffer[0])) <> EXPLORER_IMPORT_SWITCH) then Exit;
    if not MoveFile(PChar(LegacyPath), PChar(Path)) then RaiseLastOSError;
    Result := True;
  end;

begin
  Initialized := CoInitialize(nil);
  OleCheck(Initialized);
  try
    OleCheck(SHGetFolderPath(0, CSIDL_SENDTO, 0, SHGFP_TYPE_CURRENT, SendTo));
    Path := TPath.Combine(string(PChar(@SendTo[0])), SHORTCUT_NAME);
    Link := CreateComObject(CLSID_ShellLink) as IShellLinkW;
    LinkFile := Link as IPersistFile;
    if FileExists(Path) then
    begin
      OleCheck(LinkFile.Load(PChar(Path), STGM_READ));
      OleCheck(Link.GetDescription(Buffer, Length(Buffer)));
      if string(PChar(@Buffer[0])) <> SHORTCUT_MARKER then
        raise EInOutError.Create('В меню «Отправить» уже есть другой ярлык с таким именем.');
      OleCheck(Link.GetPath(Buffer, Length(Buffer), FindData, SLGP_RAWPATH));
      if SameFileName(string(PChar(@Buffer[0])), Application.ExeName) then
      begin
        if not Winapi.Windows.DeleteFile(PChar(Path)) then RaiseLastOSError;
        Exit(False);
      end;
    end
    else if RepairLegacyShortcut(string(PChar(@SendTo[0]))) then
      Exit(True);
    OleCheck(Link.SetPath(PChar(Application.ExeName)));
    OleCheck(Link.SetArguments(PChar(EXPLORER_IMPORT_SWITCH)));
    OleCheck(Link.SetWorkingDirectory(PChar(ExtractFilePath(Application.ExeName))));
    OleCheck(Link.SetDescription(PChar(SHORTCUT_MARKER)));
    OleCheck(LinkFile.Save(PChar(Path), True));
    Result := True;
  finally
    LinkFile := nil;
    Link := nil;
    CoUninitialize;
  end;
end;

end.
