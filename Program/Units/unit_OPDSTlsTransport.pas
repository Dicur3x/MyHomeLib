unit unit_OPDSTlsTransport;

interface

uses Winapi.Windows, System.SysUtils;

type
  TOPDSTlsTransport = class
  private
    FInput, FOutput, FProcess, FJob: THandle;
    procedure Launch(const Tool: string);
    procedure WaitForReady;
  public
    constructor Create(const Tool, Route, Hostname, Certificate, PrivateKey: string;
      Port, BackendPort: Integer; AllowLAN: Boolean);
    destructor Destroy; override;
    function Active: Boolean;
  end;

implementation

uses System.Classes, System.JSON;

procedure TOPDSTlsTransport.Launch(const Tool: string);
var Security: TSecurityAttributes; Startup: TStartupInfo; Process: TProcessInformation;
  ChildInput, ChildOutput, NullError: THandle;
  Limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION; Command: string;
begin
  Security := Default(TSecurityAttributes);
  Security.nLength := SizeOf(Security);
  Security.bInheritHandle := True;
  ChildInput := 0;
  ChildOutput := 0;
  NullError := INVALID_HANDLE_VALUE;
  Process := Default(TProcessInformation);
  try
    Win32Check(CreatePipe(ChildInput, FInput, @Security, 32768));
    Win32Check(SetHandleInformation(FInput, HANDLE_FLAG_INHERIT, 0));
    Win32Check(CreatePipe(FOutput, ChildOutput, @Security, 4096));
    Win32Check(SetHandleInformation(FOutput, HANDLE_FLAG_INHERIT, 0));
    NullError := CreateFile('NUL', GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE,
      @Security, OPEN_EXISTING, 0, 0);
    if NullError = INVALID_HANDLE_VALUE then RaiseLastOSError;
    Startup := Default(TStartupInfo);
    Startup.cb := SizeOf(Startup);
    Startup.dwFlags := STARTF_USESTDHANDLES;
    Startup.hStdInput := ChildInput;
    Startup.hStdOutput := ChildOutput;
    Startup.hStdError := NullError;
    FJob := CreateJobObject(nil, nil);
    if FJob = 0 then RaiseLastOSError;
    Limits := Default(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    Limits.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    Win32Check(SetInformationJobObject(FJob, JobObjectExtendedLimitInformation, @Limits, SizeOf(Limits)));
    Command := '"' + Tool + '"';
    UniqueString(Command);
    Win32Check(CreateProcess(PChar(Tool), PChar(Command), nil, nil, True,
      CREATE_NO_WINDOW or CREATE_SUSPENDED, nil, PChar(ExtractFilePath(Tool)), Startup, Process));
    FProcess := Process.hProcess;
    if not AssignProcessToJobObject(FJob, FProcess) then
    begin
      var Code := GetLastError;
      TerminateProcess(FProcess, ERROR_CANCELLED);
      RaiseLastOSError(Code);
    end;
    if ResumeThread(Process.hThread) = DWORD(-1) then RaiseLastOSError;
  finally
    if Process.hThread <> 0 then CloseHandle(Process.hThread);
    if ChildInput <> 0 then CloseHandle(ChildInput);
    if ChildOutput <> 0 then CloseHandle(ChildOutput);
    if NullError <> INVALID_HANDLE_VALUE then CloseHandle(NullError);
  end;
end;

procedure TOPDSTlsTransport.WaitForReady;
var Started: UInt64; Available, ReadCount: Cardinal; Chunk: array[0..511] of Byte;
  Buffer: TBytesStream; Reply: TJSONValue; Payload, Reason: string;
begin
  Started := GetTickCount64;
  Buffer := TBytesStream.Create;
  try
    repeat
      if not PeekNamedPipe(FOutput, nil, 0, nil, @Available, nil) then Break;
      if Available > 0 then
      begin
        if Available > SizeOf(Chunk) then Break;
        if not ReadFile(FOutput, Chunk, Available, ReadCount, nil) or (ReadCount = 0) then Break;
        Buffer.WriteBuffer(Chunk, ReadCount);
        if Buffer.Size > SizeOf(Chunk) then Break;
        if Chunk[ReadCount-1] = Ord(#10) then
        begin
          Payload := TEncoding.UTF8.GetString(Buffer.Bytes, 0, Integer(Buffer.Size));
          Reply := TJSONObject.ParseJSONValue(Trim(Payload));
          try
            if not (Reply is TJSONObject) then Break;
            if Reply.GetValue<Boolean>('ready', False) and Active then Exit;
            Reason := Reply.GetValue<string>('error', '');
            if Reason = 'certificate could not be read' then
              raise Exception.Create('Не удалось прочитать сертификат.');
            if Reason = 'private key could not be read' then
              raise Exception.Create('Не удалось прочитать закрытый ключ.');
            if Reason = 'certificate does not cover the public hostname' then
              raise Exception.Create('В сертификате нет указанного имени компьютера или IP-адреса.');
            if Reason = 'certificate is outside its validity period' then
              raise Exception.Create('Сертификат ещё не действует или срок его действия истёк.');
            if Reason = 'invalid or mismatched PEM certificate and key' then
              raise Exception.Create('Проверьте формат PEM и соответствие сертификата закрытому ключу.');
            if Reason = 'HTTPS port is unavailable' then
              raise Exception.Create('Порт HTTPS недоступен. Выберите другой порт.');
          finally
            Reply.Free;
          end;
          Break;
        end;
      end
      else if not Active then Break
      else Sleep(10);
    until GetTickCount64-Started >= 8000;
  finally
    Buffer.Free;
  end;
  raise Exception.Create('Модуль HTTPS не подтвердил запуск.');
end;

constructor TOPDSTlsTransport.Create(const Tool, Route, Hostname, Certificate, PrivateKey: string;
  Port, BackendPort: Integer; AllowLAN: Boolean);
var Config: TJSONObject; Data: UTF8String; Written: Cardinal;
begin
  inherited Create;
  Config := TJSONObject.Create;
  try
    Config.AddPair('listen_port', TJSONNumber.Create(Port));
    Config.AddPair('backend_port', TJSONNumber.Create(BackendPort));
    Config.AddPair('allow_lan', TJSONBool.Create(AllowLAN));
    Config.AddPair('route', Route);
    Config.AddPair('hostname', Hostname);
    Config.AddPair('certificate', Certificate);
    Config.AddPair('private_key', PrivateKey);
    Data := UTF8String(Config.ToJSON + #10);
  finally
    Config.Free;
  end;
  if Length(Data) > 32768 then raise Exception.Create('Пути к сертификату и ключу слишком длинные.');
  Launch(Tool);
  Win32Check(WriteFile(FInput, Data[1], Length(Data), Written, nil));
  if Written <> Cardinal(Length(Data)) then raise Exception.Create('Не удалось передать настройки HTTPS.');
  WaitForReady;
end;

destructor TOPDSTlsTransport.Destroy;
begin
  if FInput <> 0 then CloseHandle(FInput);
  if FProcess <> 0 then WaitForSingleObject(FProcess, 1000);
  if FJob <> 0 then CloseHandle(FJob);
  if FOutput <> 0 then CloseHandle(FOutput);
  if FProcess <> 0 then CloseHandle(FProcess);
  inherited;
end;

function TOPDSTlsTransport.Active: Boolean;
begin
  Result := (FProcess <> 0) and (WaitForSingleObject(FProcess, 0) = WAIT_TIMEOUT);
end;

end.
