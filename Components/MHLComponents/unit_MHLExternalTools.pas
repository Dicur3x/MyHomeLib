(* ****************************************************************************
  MyHomeLib external runtime tool helper.

  The helper deliberately uses CreateProcess instead of a command shell.  This
  keeps archive and book names as data and avoids cmd.exe interpretation.
****************************************************************************** *)

unit unit_MHLExternalTools;

interface

uses
  System.Classes,
  System.SysUtils;

type
  EMHLExternalToolError = class(Exception);

function FindExternalTool(const ToolName, ToolSubFolder: string): string;
procedure RunExternalToolToStream(const ToolPath: string;
  const Arguments: array of string; const Output: TStream);

implementation

uses
  Winapi.Windows,
  System.IOUtils;

function QuoteCommandLineArgument(const Value: string): string;
var
  Ch: Char;
  I: Integer;
  BackslashCount: Integer;
begin
  Result := '"';
  BackslashCount := 0;
  for I := 1 to Length(Value) do
  begin
    Ch := Value[I];
    if Ch = '\' then
      Inc(BackslashCount)
    else
    begin
      if Ch = '"' then
      begin
        Result := Result + StringOfChar('\', BackslashCount * 2 + 1) + '"';
        BackslashCount := 0;
      end
      else
      begin
        if BackslashCount > 0 then
        begin
          Result := Result + StringOfChar('\', BackslashCount);
          BackslashCount := 0;
        end;
        Result := Result + Ch;
      end;
    end;
  end;

  // Backslashes immediately before the closing quote must be doubled.
  if BackslashCount > 0 then
    Result := Result + StringOfChar('\', BackslashCount * 2);
  Result := Result + '"';
end;

function FindOnPath(const ToolName: string): string;
var
  Buffer: array [0 .. 32767] of Char;
  FilePart: PChar;
  Required: DWORD;
begin
  Result := '';
  FilePart := nil;
  Required := SearchPath(nil, PChar(ToolName), nil, Length(Buffer), Buffer,
    FilePart);
  if (Required > 0) and (Required < DWORD(Length(Buffer))) then
    SetString(Result, Buffer, Required);
end;

function FindExternalTool(const ToolName, ToolSubFolder: string): string;
var
  AppFolder: string;
  Candidate: string;
  ProgramFilesFolder: string;
begin
  AppFolder := ExtractFilePath(ParamStr(0));

  Candidate := TPath.Combine(AppFolder,
    TPath.Combine('tools', TPath.Combine(ToolSubFolder, ToolName)));
  if FileExists(Candidate) then
    Exit(Candidate);

  Candidate := TPath.Combine(AppFolder, ToolName);
  if FileExists(Candidate) then
    Exit(Candidate);

  // Development machines commonly have 7-Zip installed but not added to
  // PATH.  Release archives still carry their private runtime under tools.
  if SameText(ToolSubFolder, '7zip') then
  begin
    ProgramFilesFolder := GetEnvironmentVariable('ProgramFiles');
    if ProgramFilesFolder <> '' then
    begin
      Candidate := TPath.Combine(ProgramFilesFolder,
        TPath.Combine('7-Zip', ToolName));
      if FileExists(Candidate) then
        Exit(Candidate);
    end;
    ProgramFilesFolder := GetEnvironmentVariable('ProgramFiles(x86)');
    if ProgramFilesFolder <> '' then
    begin
      Candidate := TPath.Combine(ProgramFilesFolder,
        TPath.Combine('7-Zip', ToolName));
      if FileExists(Candidate) then
        Exit(Candidate);
    end;
  end;

  Result := FindOnPath(ToolName);
end;

procedure RunExternalToolToStream(const ToolPath: string;
  const Arguments: array of string; const Output: TStream);
const
  BUFFER_SIZE = 64 * 1024;
var
  Buffer: array [0 .. BUFFER_SIZE - 1] of Byte;
  BytesRead: DWORD;
  CommandLine: string;
  ExitCode: Cardinal;
  I: Integer;
  NullInput: THandle;
  NullError: THandle;
  PipeRead: THandle;
  PipeWrite: THandle;
  ProcessInfo: TProcessInformation;
  Security: TSecurityAttributes;
  StartInfo: TStartupInfo;
begin
  if not FileExists(ToolPath) then
    raise EMHLExternalToolError.CreateFmt(
      'Не найден вспомогательный файл "%s".', [ToolPath]);
  if not Assigned(Output) then
    raise EArgumentNilException.Create('Output');

  FillChar(Security, SizeOf(Security), 0);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  if not CreatePipe(PipeRead, PipeWrite, @Security, 0) then
    RaiseLastOSError;
  try
    if not SetHandleInformation(PipeRead, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;

    NullInput := CreateFile('NUL', GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE, @Security, OPEN_EXISTING, 0, 0);
    if NullInput = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    try
      NullError := CreateFile('NUL', GENERIC_WRITE,
        FILE_SHARE_READ or FILE_SHARE_WRITE, @Security, OPEN_EXISTING, 0, 0);
      if NullError = INVALID_HANDLE_VALUE then
        RaiseLastOSError;
      try
        FillChar(StartInfo, SizeOf(StartInfo), 0);
        StartInfo.cb := SizeOf(StartInfo);
        StartInfo.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
        StartInfo.wShowWindow := SW_HIDE;
        StartInfo.hStdInput := NullInput;
        StartInfo.hStdOutput := PipeWrite;
        StartInfo.hStdError := NullError;

        CommandLine := QuoteCommandLineArgument(ToolPath);
        for I := Low(Arguments) to High(Arguments) do
          CommandLine := CommandLine + ' ' +
            QuoteCommandLineArgument(Arguments[I]);
        UniqueString(CommandLine);

        FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
        if not CreateProcess(PChar(ToolPath), PChar(CommandLine), nil, nil,
          True, CREATE_NO_WINDOW or NORMAL_PRIORITY_CLASS, nil,
          PChar(ExtractFilePath(ToolPath)), StartInfo, ProcessInfo) then
          RaiseLastOSError;

        CloseHandle(PipeWrite);
        PipeWrite := 0;
        try
          Output.Position := 0;
          Output.Size := 0;
          while ReadFile(PipeRead, Buffer[0], SizeOf(Buffer), BytesRead, nil) and
            (BytesRead > 0) do
            Output.WriteBuffer(Buffer[0], BytesRead);

          WaitForSingleObject(ProcessInfo.hProcess, INFINITE);
          if not GetExitCodeProcess(ProcessInfo.hProcess, ExitCode) then
            RaiseLastOSError;
          if ExitCode <> 0 then
            raise EMHLExternalToolError.CreateFmt(
              'Вспомогательная программа "%s" завершилась с ошибкой %d.',
              [ExtractFileName(ToolPath), ExitCode]);
          Output.Position := 0;
        finally
          CloseHandle(ProcessInfo.hThread);
          CloseHandle(ProcessInfo.hProcess);
        end;
      finally
        CloseHandle(NullError);
      end;
    finally
      CloseHandle(NullInput);
    end;
  finally
    if PipeWrite <> 0 then
      CloseHandle(PipeWrite);
    CloseHandle(PipeRead);
  end;
end;

end.
