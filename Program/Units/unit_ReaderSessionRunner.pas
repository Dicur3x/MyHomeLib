unit unit_ReaderSessionRunner;

interface

uses System.Classes, System.SysUtils, unit_ReaderSession;

// Owns the process handle and the original input lease, never the reader's
// lifetime. Closing the catalogue leaves the independent reader running.
procedure LaunchReaderSession(Owner: TComponent; const Executable, Profile: string;
  const Request: TReaderSessionRequest; const OnReply: TProc<TReaderSessionReply>);
procedure CancelReaderSessionRunners(Owner: TComponent);
function RemoveReaderSessionFiles(const Request: TReaderSessionRequest): Boolean;

implementation

uses Winapi.Windows, System.IOUtils, System.RegularExpressions, Vcl.ExtCtrls,
  unit_MHLExternalTools, unit_BookCache, unit_Diagnostics;

const READER_PROCESS_QUERY_LIMITED = $1000;

function ReaderQueryProcessImageName(Process: THandle; Flags: DWORD; Name: PWideChar;
  var Size: DWORD): BOOL; stdcall; external kernel32 name 'QueryFullProcessImageNameW';

type
  TReaderSessionRunner = class(TComponent)
  private
    FRequest: TReaderSessionRequest;
    FExecutable: string;
    FProcess: THandle;
    FOriginalPID: Cardinal;
    FSource: TStream;
    FTimer: TTimer;
    FOnReply: TProc<TReaderSessionReply>;
    FPolling, FRestarting: Boolean;
    FExitedAt: UInt64;
    procedure Tick(Sender: TObject);
    function AdoptReader(ProcessID: Cardinal): Boolean;
  public
    constructor Start(Owner: TComponent; const Executable, Profile: string;
      const Request: TReaderSessionRequest; const OnReply: TProc<TReaderSessionReply>);
    destructor Destroy; override;
  end;

function RemoveReaderSessionFiles(const Request: TReaderSessionRequest): Boolean;
var Folder, FileName: string; Attributes: DWORD;
begin
  Result:=False;
  if not TRegEx.IsMatch(Request.ID,'\A[0-9a-f]{32}\z') then Exit;
  Folder:=ExcludeTrailingPathDelimiter(ExtractFileDir(Request.RequestFile));
  if (ExtractFileName(Request.RequestFile)<>'request.json') or
    (ExtractFileName(Folder)<>'HomeLibReader-session-'+Request.ID) then Exit;
  Attributes:=GetFileAttributes(PChar(Folder));
  if Attributes=INVALID_FILE_ATTRIBUTES then Exit(True);
  if Attributes and FILE_ATTRIBUTE_REPARSE_POINT<>0 then Exit;
  // Only our two JSON messages. Never recursively remove a folder or any
  // original/extracted book; an unexpected extra file keeps the folder intact.
  for var Name in ['request.json','response.json'] do
  begin
    FileName:=TPath.Combine(Folder,Name); Attributes:=GetFileAttributes(PChar(FileName));
    if Attributes=INVALID_FILE_ATTRIBUTES then Continue;
    if Attributes and (FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_DIRECTORY)<>0 then Exit;
    if not Winapi.Windows.DeleteFile(PChar(FileName)) then Exit;
  end;
  Result:=RemoveDirectory(PChar(Folder));
end;

constructor TReaderSessionRunner.Start(Owner: TComponent; const Executable, Profile: string;
  const Request: TReaderSessionRequest; const OnReply: TProc<TReaderSessionReply>);
var Startup: TStartupInfo; Process: TProcessInformation; Command: string;
begin
  inherited Create(Owner);
  FRequest:=Request; FExecutable:=TPath.GetFullPath(Executable);
  FOnReply:=OnReply;
  if not FileExists(FExecutable) then raise EFileNotFoundException.Create('Не найдена HomeLib Reader.');
  // This also registers a cache reader, so explicit cache cleanup cannot
  // retire the original input while a component helper restarts the reader.
  FSource:=OpenCachedBookFile(Request.SourceFile);
  Command:=QuoteCommandLineArgument(FExecutable)+' '+
    QuoteCommandLineArgument('--session='+Request.RequestFile)+' '+
    QuoteCommandLineArgument('--profile='+TPath.GetFullPath(Profile));
  UniqueString(Command); Startup:=Default(TStartupInfo); Startup.cb:=SizeOf(Startup);
  Startup.dwFlags:=STARTF_USESHOWWINDOW; Startup.wShowWindow:=SW_SHOWNORMAL;
  Process:=Default(TProcessInformation);
  if not CreateProcess(PChar(FExecutable),PChar(Command),nil,nil,False,0,nil,
    PChar(ExtractFileDir(FExecutable)),Startup,Process) then RaiseLastOSError;
  FProcess:=Process.hProcess; FOriginalPID:=Process.dwProcessId; CloseHandle(Process.hThread);
  FTimer:=TTimer.Create(Self); FTimer.Interval:=250; FTimer.OnTimer:=Tick;
end;

destructor TReaderSessionRunner.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled:=False;
  if FProcess<>0 then CloseHandle(FProcess);
  FSource.Free;
  FOnReply:=nil;
  inherited;
end;

function TReaderSessionRunner.AdoptReader(ProcessID: Cardinal): Boolean;
var Process: THandle; Name: array[0..32767] of Char; Size: DWORD; ImageName: string;
begin
  Result:=False; Process:=OpenProcess(SYNCHRONIZE or READER_PROCESS_QUERY_LIMITED,False,ProcessID);
  if Process=0 then Exit;
  Size:=Length(Name);
  if ReaderQueryProcessImageName(Process,0,@Name[0],Size) then SetString(ImageName,PChar(@Name[0]),Size);
  if SameFileName(ImageName,FExecutable) then
  begin
    CloseHandle(FProcess); FProcess:=Process; FExitedAt:=0; Result:=True;
  end
  else CloseHandle(Process);
end;

procedure TReaderSessionRunner.Tick(Sender: TObject);
var Reply: TReaderSessionReply; Finished, HasReply, Accepted: Boolean; Error: string;
  ReplyAction: TProc<TReaderSessionReply>;
begin
  if FPolling then Exit;
  FPolling:=True; Finished:=False; HasReply:=False; Error:='';
  try
    if TryReadReaderSessionReply(FRequest,Reply) then
    begin
      Accepted:=(Reply.ProcessID=FOriginalPID) or (Reply.OriginProcessID=FOriginalPID);
      if Accepted then
      begin
        if Reply.State='restarting' then FRestarting:=True;
        if (Reply.State='closed') or (Reply.State='failed') then
        begin Finished:=True; HasReply:=True; if Reply.State='failed' then Error:=Reply.ErrorText; end
        else if Reply.ProcessID<>GetProcessId(FProcess) then
        begin FRestarting:=True; AdoptReader(Reply.ProcessID); end;
      end;
    end;
    if not Finished and (WaitForSingleObject(FProcess,0)=WAIT_OBJECT_0) then
    begin
      if FExitedAt=0 then FExitedAt:=GetTickCount64;
      // A component installation legitimately hands the session to a new
      // process. OriginProcessID survives even if the UI missed that transition.
      if (not FRestarting and (GetTickCount64-FExitedAt>1500)) or
        (FRestarting and (GetTickCount64-FExitedAt>10*60*1000)) then
      begin Finished:=True; Error:='Читалка завершилась до сохранения результата. Позиция чтения остаётся в её настройках.'; end;
    end;
  except
    on E: Exception do
    begin Finished:=True; Error:=E.Message; LogDiagnosticError('reader-session-monitor',E); end;
  end;
  FPolling:=False;
  if not Finished then Exit;
  FTimer.Enabled:=False; FreeAndNil(FSource);
  if not RemoveReaderSessionFiles(FRequest) then
    LogDiagnosticMessage('reader-session-cleanup','Не удалось удалить файлы завершённого сеанса: '+FRequest.RequestFile);
  if not HasReply then
  begin
    Reply:=Default(TReaderSessionReply); Reply.State:='failed'; Reply.ErrorText:=Error;
    Reply.ProcessID:=FOriginalPID; HasReply:=True;
  end;
  ReplyAction:=FOnReply;
  Free; // No component state is accessed after callbacks can close their owner.
  if HasReply and Assigned(ReplyAction) then ReplyAction(Reply);
end;

procedure LaunchReaderSession(Owner: TComponent; const Executable, Profile: string;
  const Request: TReaderSessionRequest; const OnReply: TProc<TReaderSessionReply>);
begin TReaderSessionRunner.Start(Owner,Executable,Profile,Request,OnReply); end;

procedure CancelReaderSessionRunners(Owner: TComponent);
begin
  if not Assigned(Owner) then Exit;
  for var I:=Owner.ComponentCount-1 downto 0 do
    if Owner.Components[I] is TReaderSessionRunner then Owner.Components[I].Free;
end;

end.
