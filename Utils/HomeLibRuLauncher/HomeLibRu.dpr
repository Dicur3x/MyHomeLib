program HomeLibRu;

{$APPTYPE GUI}
{$R *.res}

uses System.SysUtils, System.IOUtils, Winapi.Windows,
  unit_ApplicationIdentity in '..\..\Program\Units\unit_ApplicationIdentity.pas';

var Executable, Transport, Command: string; Startup: TStartupInfo; Process: TProcessInformation;
begin
  try
    // Compatibility for old shortcuts and update clients, never a second
    // catalogue implementation. All profiles are opened by HomeLibre itself.
    Executable:=TPath.Combine(ExtractFilePath(ParamStr(0)),CATALOGUE_APPLICATION);
    // A manually unpacked bridge archive also works: finish its one-file
    // rename before opening a profile, without making another full EXE copy.
    Transport:=TPath.Combine(ExtractFilePath(ParamStr(0)),CATALOGUE_TRANSPORT_PATH);
    if not FileExists(Executable) and FileExists(Transport) then
      if not MoveFileEx(PChar(Transport),PChar(Executable),MOVEFILE_WRITE_THROUGH) and
        not FileExists(Executable) then RaiseLastOSError;
    if SameFileName(Executable,ParamStr(0)) or not FileExists(Executable) then
      raise EFileNotFoundException.Create('Не найден HomeLibre.exe рядом с файлом запуска. Распакуйте полный архив HomeLibre в эту папку.');
    Command:=ForwardApplicationCommandLine(Executable,string(GetCommandLine));
    UniqueString(Command);
    Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
    if not CreateProcess(PChar(Executable),PChar(Command),nil,nil,False,0,nil,nil,Startup,Process) then
      RaiseLastOSError;
    CloseHandle(Process.hThread); CloseHandle(Process.hProcess);
  except
    on E:Exception do
    begin MessageBox(0,PChar(E.Message),'HomeLibre',MB_OK or MB_ICONERROR); Halt(1); end;
  end;
end.
