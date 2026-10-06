program HomeLibRuUpdater;

{$APPTYPE GUI}
{$R *.res}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Winapi.Windows, Winapi.ShellAPI,
  unit_UpdateAuthenticity in '..\..\Program\Units\unit_UpdateAuthenticity.pas',
  unit_ProgramUpdateInstaller in '..\..\Program\Units\unit_ProgramUpdateInstaller.pas';

const PROCESS_QUERY_LIMITED_INFORMATION = $1000;
function QueryFullProcessImageName(Process: THandle; Flags: DWORD;
  Name: PChar; var Size: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryFullProcessImageNameW';

// This small helper runs from the update cache, waits for normal application
// shutdown, replaces the distribution, and relaunches the same profile.
function QuoteArgument(const Value: string): string;
begin
  // Delphi ParamStr does not use the C runtime backslash escaping rules.
  Result := '"' + StringReplace(Value, '"', '', [rfReplaceAll]) + '"';
end;

procedure Restart(const Target: string; Args: TJSONArray; const OriginalCommandLine: string);
var Command: string; Arg: TJSONValue; Startup: TStartupInfo; Process: TProcessInformation;
begin
  Command := QuoteArgument(IncludeTrailingPathDelimiter(Target) + 'HomeLibRu.exe');
  for Arg in Args do
  begin
    if not (Arg is TJSONString) then raise Exception.Create('Повреждены параметры запуска.');
    Command := Command + ' ' + QuoteArgument(Arg.Value);
  end;
  // Reuse original quoting verbatim; the executable path remains explicit.
  if OriginalCommandLine <> '' then Command := OriginalCommandLine;
  UniqueString(Command); Startup := Default(TStartupInfo); Startup.cb := SizeOf(Startup);
  if not CreateProcess(PChar(IncludeTrailingPathDelimiter(Target) + 'HomeLibRu.exe'), PChar(Command),
    nil, nil, False, 0, nil, PChar(Target), Startup, Process) then RaiseLastOSError;
  CloseHandle(Process.hThread); CloseHandle(Process.hProcess);
end;

var Job, Target, Tag, Digest, ParentImage, Error, Cache, OriginalCommandLine: string;
  Root: TJSONValue; Request: TJSONObject; Args: TJSONArray;
  PID, Length: Cardinal; Parent: THandle; CanRestart, Recover: Boolean;
begin
  Root := nil; Args := nil; CanRestart := False;
  try
    if (ParamCount <> 2) or (ParamStr(1) <> '--job') then Halt(2);
    Job := TPath.GetFullPath(ParamStr(2)); AssertUpdatePath(Job);
    if not ExtractFileName(Job).StartsWith('HomeLibRu-update-') or
       not SameText(ExtractFilePath(ParamStr(0)), IncludeTrailingPathDelimiter(Job)) then
      raise Exception.Create('Недопустимая папка обновления.');
    Root := TJSONObject.ParseJSONValue(TFile.ReadAllText(IncludeTrailingPathDelimiter(Job) + 'request.json', TEncoding.UTF8));
    if not (Root is TJSONObject) then raise Exception.Create('Нет параметров установки обновления.');
    Request := TJSONObject(Root);
    if not Request.TryGetValue<string>('target', Target) or
       not Request.TryGetValue<Cardinal>('pid', PID) or
       not Request.TryGetValue<string>('tag', Tag) or
       not Request.TryGetValue<string>('sha256', Digest) or not IsUpdateSHA256(Digest) or
       not Request.TryGetValue<TJSONArray>('args', Args) then
      raise Exception.Create('Повреждены параметры обновления.');
    Target := TPath.GetFullPath(Target); AssertUpdatePath(Target);
    OriginalCommandLine := ''; Request.TryGetValue<string>('commandLine', OriginalCommandLine);
    Recover := False; Request.TryGetValue<Boolean>('recover', Recover);
    Parent := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION, False, PID);
    if (Parent = 0) and (GetLastError <> ERROR_INVALID_PARAMETER) then RaiseLastOSError;
    if Parent <> 0 then
    try
      SetLength(ParentImage, 32768); Length := System.Length(ParentImage);
      if QueryFullProcessImageName(Parent, 0, PChar(ParentImage), Length) then
      begin
        SetLength(ParentImage, Length);
        if not SameText(ParentImage, IncludeTrailingPathDelimiter(Target) + 'HomeLibRu.exe') then
          raise Exception.Create('Обновление запущено для другого экземпляра программы.');
      end
      else if WaitForSingleObject(Parent, 0) <> WAIT_OBJECT_0 then RaiseLastOSError;
      if WaitForSingleObject(Parent, 120000) <> WAIT_OBJECT_0 then
        raise Exception.Create('HomeLib Ru не закрылась. Обновление отложено.');
    finally CloseHandle(Parent); end;
    CanRestart := True;
    if Recover then
    begin
      RollbackProgramUpdate(Job, Target);
      Restart(Target, Args, OriginalCommandLine);
      Root.Free; Halt(0);
    end;
    if not SameText(UpdateSHA256(IncludeTrailingPathDelimiter(Job) + 'release.zip'), Digest) then
      raise Exception.Create('Архив обновления изменился после загрузки.');
    VerifyPreparedProgramUpdate(Job, Tag, ProgramUpdatePlatform);
    InstallProgramUpdate(Job, Target);
    Cache := ExtractFileDir(Job);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(Cache) + 'result.txt',
      'Установлена версия ' + Tag + '.', TEncoding.UTF8);
    Restart(Target, Args, OriginalCommandLine);
  except
    on E: Exception do
    begin
      Error := 'Обновление не установлено.' + sLineBreak + E.Message + sLineBreak +
        'Резервная копия и журнал сохранены в:' + sLineBreak + Job;
      MessageBox(0, PChar(Error), 'HomeLib Ru', MB_OK or MB_ICONERROR);
      if CanRestart and Assigned(Args) then
        try Restart(Target, Args, OriginalCommandLine); except end;
      Root.Free; Halt(1);
    end;
  end;
  Root.Free;
end.
