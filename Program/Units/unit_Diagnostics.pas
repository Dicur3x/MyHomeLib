unit unit_Diagnostics;

interface

uses System.SysUtils, System.Classes;

// Local diagnostics only. Daily logs expire after seven days; each is bounded.
function DiagnosticLogDirectory: string;
function DiagnosticLogFile: string;
function SanitizeDiagnosticText(const Value: string): string;
procedure InitializeDiagnostics;
procedure PruneDiagnosticLogs;
procedure LogDiagnosticMessage(const Operation, Message: string);
procedure LogDiagnosticError(const Operation: string; Error: Exception; const FormatName: string = '');
procedure SaveDiagnosticReport(const FileName: string; AllowOverwrite: Boolean = False);
procedure ShowDiagnostics(Owner: TComponent);

implementation

uses Winapi.Windows, Winapi.ShellAPI, System.IOUtils, System.DateUtils,
  System.JSON, System.Zip, System.RegularExpressions, Vcl.Forms, Vcl.StdCtrls,
  Vcl.Controls, Vcl.Dialogs, Vcl.AppEvnts;

const MAX_DAILY_LOG = 2 * 1024 * 1024;
  LOG_DAYS = 7;

type
  TDiagnosticEvents = class(TApplicationEvents)
    procedure AppException(Sender: TObject; E: Exception);
  end;
  TDiagnosticForm = class(TForm)
  private
    procedure SaveClick(Sender: TObject);
    procedure FolderClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var LogGuard: TObject; Started: Boolean; LastPrunedDay: TDateTime; CachedVersion: string;
  Events: TDiagnosticEvents;

function DiagnosticLogDirectory: string;
begin Result:=TPath.Combine(TPath.GetTempPath,'HomeLibRu-Logs'); end;

function DiagnosticLogFile: string;
begin Result:=TPath.Combine(DiagnosticLogDirectory,'HomeLibRu-'+FormatDateTime('yyyy-mm-dd',Now)+'.log'); end;

function SafeDirectory: Boolean;
var Attributes: DWORD;
begin
  Result:=False;
  if not ForceDirectories(DiagnosticLogDirectory) then Exit;
  Attributes:=GetFileAttributes(PChar(DiagnosticLogDirectory));
  Result:=(Attributes<>INVALID_FILE_ATTRIBUTES) and
    (Attributes and FILE_ATTRIBUTE_DIRECTORY<>0) and (Attributes and FILE_ATTRIBUTE_REPARSE_POINT=0);
end;

function OwnedLog(const Name: string; out Day: TDateTime): Boolean;
var Y,M,D: Integer; Attributes: DWORD; Base: string;
begin
  Result:=False; Base:=ExtractFileName(Name);
  if (Length(Base)<>24) or not Base.StartsWith('HomeLibRu-') or not Base.EndsWith('.log') then Exit;
  if not TryStrToInt(Copy(Base,11,4),Y) or not TryStrToInt(Copy(Base,16,2),M) or
    not TryStrToInt(Copy(Base,19,2),D) then Exit;
  if (Y<1) or (Y>9999) or (M<1) or (M>12) or (D<1) or (D>31) then Exit;
  if not TryEncodeDate(Y,M,D,Day) or (Base<>'HomeLibRu-'+FormatDateTime('yyyy-mm-dd',Day)+'.log') then Exit;
  if not SameFileName(ExtractFileDir(TPath.GetFullPath(Name)),DiagnosticLogDirectory) then Exit;
  Attributes:=GetFileAttributes(PChar(Name));
  Result:=(Attributes<>INVALID_FILE_ATTRIBUTES) and
    (Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)=0);
end;

procedure PruneDiagnosticLogs;
var Search: TSearchRec; Name: string; Day: TDateTime; Count: Integer;
begin
  System.TMonitor.Enter(LogGuard);
  try
    try
      if not SafeDirectory then Exit;
      Count:=0;
      if FindFirst(TPath.Combine(DiagnosticLogDirectory,'HomeLibRu-*.log'),faAnyFile,Search)=0 then
      try
        repeat
          Name:=TPath.Combine(DiagnosticLogDirectory,Search.Name);
          if OwnedLog(Name,Day) and (Day<Trunc(Now)-LOG_DAYS+1) then System.SysUtils.DeleteFile(Name);
          Inc(Count);
        until (FindNext(Search)<>0) or (Count>=256);
      finally System.SysUtils.FindClose(Search); end;
    except // Diagnostics must not interrupt reading, startup or shutdown.
    end;
    LastPrunedDay:=Trunc(Now);
  finally System.TMonitor.Exit(LogGuard); end;
end;

function SanitizeDiagnosticText(const Value: string): string;
begin
  Result:=Copy(Value,1,4096);
  Result:=TRegEx.Replace(Result,'(?i)\b(?:https?|ftp)://[^\s<>"'']+','[URL]');
  Result:=TRegEx.Replace(Result,'(?i)(?:\b(?:password|passwd|pwd|token|secret|cookie|authorization)|пароль)\s*[:=][^\r\n]*','[секретные параметры скрыты]');
  Result:=TRegEx.Replace(Result,'(?i)(?:\b[a-z]:[\\/]|\\\\)[^\r\n\t"<>|]+','[путь]');
end;

function ProgramVersion: string;
var Bytes: TBytes; Dummy, Size, Count: DWORD; Info: PVSFixedFileInfo;
begin
  if CachedVersion<>'' then Exit(CachedVersion);
  Result:='unknown'; Size:=GetFileVersionInfoSize(PChar(ParamStr(0)),Dummy);
  if (Size=0) or (Size>1024*1024) then Exit;
  SetLength(Bytes,Size);
  if GetFileVersionInfo(PChar(ParamStr(0)),0,Size,@Bytes[0]) and
    VerQueryValue(@Bytes[0],'\',Pointer(Info),Count) and (Count>=SizeOf(TVSFixedFileInfo)) then
    Result:=Format('%d.%d.%d.%d',[HiWord(Info.dwFileVersionMS),LoWord(Info.dwFileVersionMS),
      HiWord(Info.dwFileVersionLS),LoWord(Info.dwFileVersionLS)]);
  CachedVersion:=Result;
end;

procedure WriteDiagnostic(const Level, Operation, Kind, Message, FormatName: string);
var Row: TJSONObject; Bytes: TBytes; Handle: THandle; Written: DWORD; Size: Int64;
begin
  System.TMonitor.Enter(LogGuard);
  try
    try
      if LastPrunedDay<>Trunc(Now) then PruneDiagnosticLogs;
      if not SafeDirectory then Exit;
      Handle:=CreateFile(PChar(DiagnosticLogFile),FILE_APPEND_DATA or FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ or FILE_SHARE_WRITE,nil,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
      if Handle=INVALID_HANDLE_VALUE then Exit;
      try
        if not GetFileSizeEx(Handle,Size) or (Size>=MAX_DAILY_LOG) then Exit;
        Row:=TJSONObject.Create;
        try
          Row.AddPair('time',DateToISO8601(TTimeZone.Local.ToUniversalTime(Now),True));
          Row.AddPair('level',Level); Row.AddPair('operation',Copy(Operation,1,80));
          Row.AddPair('version',ProgramVersion);
          {$IFDEF WIN64} Row.AddPair('architecture','x64'); {$ELSE} Row.AddPair('architecture','x86'); {$ENDIF}
          Row.AddPair('pid',TJSONNumber.Create(GetCurrentProcessId));
          Row.AddPair('exception',Copy(Kind,1,80)); Row.AddPair('format',Copy(FormatName,1,24));
          Row.AddPair('message',SanitizeDiagnosticText(Message));
          Bytes:=TEncoding.UTF8.GetBytes(Row.ToJSON+sLineBreak);
        finally Row.Free; end;
        if Size+Length(Bytes)<=MAX_DAILY_LOG then WriteFile(Handle,Bytes[0],Length(Bytes),Written,nil);
      finally CloseHandle(Handle); end;
    except end;
  finally System.TMonitor.Exit(LogGuard); end;
end;

procedure LogDiagnosticMessage(const Operation, Message: string);
begin WriteDiagnostic('error',Operation,'',Message,''); end;

procedure LogDiagnosticError(const Operation: string; Error: Exception; const FormatName: string);
begin
  if not Assigned(Error) or (Error is EAbort) then Exit;
  WriteDiagnostic('error',Operation,Error.ClassName,Error.Message,FormatName);
end;

procedure TDiagnosticEvents.AppException(Sender: TObject; E: Exception);
begin LogDiagnosticError('application',E); Application.ShowException(E); end;

procedure InitializeDiagnostics;
begin
  if Started then Exit; Started:=True;
  Events:=TDiagnosticEvents.Create(nil); Events.OnException:=Events.AppException;
  WriteDiagnostic('info','session','','Программа запущена. Журналы хранятся 7 дней.','');
end;

procedure SaveDiagnosticReport(const FileName: string; AllowOverwrite: Boolean);
var Stage, Name: string; Zip: TZipFile; Search: TSearchRec; Day: TDateTime; Size: Int64; Flags: DWORD; Info: TStringStream;
begin
  if FileExists(FileName) and not AllowOverwrite then raise EWriteError.Create('Файл отчёта уже существует.');
  PruneDiagnosticLogs;
  Stage:=TPath.Combine(ExtractFileDir(TPath.GetFullPath(FileName)),'HomeLibRu-report-'+TGUID.NewGuid.ToString+'.tmp');
  Zip:=TZipFile.Create;
  try
    Zip.Open(Stage,zmWrite);
    Info:=TStringStream.Create('HomeLib Ru '+ProgramVersion+sLineBreak+TOSVersion.ToString+sLineBreak+
      {$IFDEF WIN64}'x64'+{$ELSE}'x86'+{$ENDIF}sLineBreak+'Logs: last 7 days; 2 MiB maximum per day.'+sLineBreak,TEncoding.UTF8);
    try Zip.Add(Info,'HomeLibRu-info.txt'); finally Info.Free; end;
    if SafeDirectory and (FindFirst(TPath.Combine(DiagnosticLogDirectory,'HomeLibRu-*.log'),faAnyFile,Search)=0) then
    try
      repeat
        Name:=TPath.Combine(DiagnosticLogDirectory,Search.Name);
        if OwnedLog(Name,Day) and (Day>=Trunc(Now)-LOG_DAYS+1) and (Day<=Trunc(Now)) then
        begin
          Size:=TFile.GetSize(Name);
          if Size<=MAX_DAILY_LOG then Zip.Add(Name,Search.Name);
        end;
      until FindNext(Search)<>0;
    finally System.SysUtils.FindClose(Search); end;
    Zip.Close; Flags:=MOVEFILE_WRITE_THROUGH;
    if AllowOverwrite then Flags:=Flags or MOVEFILE_REPLACE_EXISTING;
    if not MoveFileEx(PChar(Stage),PChar(TPath.GetFullPath(FileName)),Flags) then RaiseLastOSError;
  finally
    Zip.Free;
    if FileExists(Stage) then System.SysUtils.DeleteFile(Stage);
  end;
end;

constructor TDiagnosticForm.Create(AOwner: TComponent);
var Text: TLabel; Memo: TMemo; Button: TButton; Input: TFileStream; Bytes: TBytes; Count: Integer;
begin
  inherited CreateNew(AOwner); Caption:='Журнал ошибок'; Position:=poOwnerFormCenter;
  Font.Name:='Segoe UI'; Font.Size:=9; ClientWidth:=680; ClientHeight:=420;
  Constraints.MinWidth:=640; Constraints.MinHeight:=320;
  Text:=TLabel.Create(Self); Text.Parent:=Self; Text.SetBounds(12,12,656,54);
  Text.AutoSize:=False; Text.WordWrap:=True; Text.Anchors:=[akLeft,akTop,akRight];
  Text.Caption:='Журналы хранятся во временной папке Windows 7 дней. В них записываются версия программы, действие и сообщение об ошибке. Сохраните ZIP-отчёт, чтобы приложить его к сообщению об ошибке.';
  Memo:=TMemo.Create(Self); Memo.Parent:=Self; Memo.SetBounds(12,74,656,290);
  Memo.ReadOnly:=True; Memo.ScrollBars:=ssBoth; Memo.WordWrap:=False; Memo.Anchors:=[akLeft,akTop,akRight,akBottom];
  try if FileExists(DiagnosticLogFile) then
    begin
      Input:=TFileStream.Create(DiagnosticLogFile,fmOpenRead or fmShareDenyNone);
      try
        Count:=MAX_DAILY_LOG; if Input.Size<Count then Count:=Input.Size;
        SetLength(Bytes,Count); if Count>0 then Input.ReadBuffer(Bytes[0],Count);
        Memo.Text:=TEncoding.UTF8.GetString(Bytes);
      finally Input.Free; end;
    end
    else Memo.Text:='Сегодня ошибок ещё не записано.';
  except Memo.Text:='Не удалось прочитать журнал. Проверьте доступ к временной папке.'; end;
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.SetBounds(12,378,225,30);
  Button.Caption:='Сохранить отчёт для отправки…'; Button.OnClick:=SaveClick; Button.Anchors:=[akLeft,akBottom];
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.SetBounds(248,378,225,30);
  Button.Caption:='Открыть папку журналов'; Button.OnClick:=FolderClick; Button.Anchors:=[akLeft,akBottom];
  Button:=TButton.Create(Self); Button.Parent:=Self; Button.SetBounds(568,378,100,30);
  Button.Caption:='Закрыть'; Button.ModalResult:=mrClose; Button.Cancel:=True; Button.Anchors:=[akRight,akBottom];
  ScaleForPPI(Screen.PixelsPerInch);
end;

procedure TDiagnosticForm.SaveClick(Sender: TObject);
var Dialog: TSaveDialog;
begin
  Dialog:=TSaveDialog.Create(Self);
  try
    Dialog.Title:='Сохранить журнал для отправки'; Dialog.DefaultExt:='zip';
    Dialog.Filter:='ZIP-отчёт (*.zip)|*.zip'; Dialog.Options:=[ofOverwritePrompt,ofPathMustExist,ofEnableSizing];
    Dialog.FileName:='HomeLibRu-diagnostics-'+FormatDateTime('yyyymmdd',Now)+'.zip';
    if Dialog.Execute then SaveDiagnosticReport(Dialog.FileName,True);
  finally Dialog.Free; end;
end;

procedure TDiagnosticForm.FolderClick(Sender: TObject);
begin
  if SafeDirectory then ShellExecute(Handle,'open',PChar(DiagnosticLogDirectory),nil,nil,SW_SHOWNORMAL);
end;

procedure ShowDiagnostics(Owner: TComponent);
var Dialog: TDiagnosticForm;
begin Dialog:=TDiagnosticForm.Create(Owner); try Dialog.ShowModal; finally Dialog.Free; end; end;

initialization
  LogGuard:=TObject.Create;
finalization
  Events.Free;
  LogGuard.Free;
end.
