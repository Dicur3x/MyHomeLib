unit unit_ReaderPDFWorker;

interface

uses System.SysUtils, Winapi.Windows, unit_PDFProtocol;

type
  // PDFium rendering lives in a separate process from selection and search.
  // Only completed BGRA buffers cross into the reader; cancellation kills the job.
  TReaderPDFWorker = class
  private
    FFileName: string;
    FProcess, FJob, FInput, FOutput, FMapping: THandle;
    FView: Pointer;
    FPageCount: Integer;
    procedure Start;
    procedure Stop;
    procedure Send(const Request: TPDFRequest; const Text: UTF8String='');
    procedure Receive(out Response: TPDFResponse);
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    procedure RenderPage(Index: Integer; out Pixels: TBytes; out Width, Height: Integer;
      MaxEdge: Integer = 0);
    property PageCount: Integer read FPageCount;
  end;

function PDFWorkerAvailable: Boolean;

implementation

uses System.Classes, System.IOUtils, System.Math, unit_MHLExternalTools;

function PDFWorkerAvailable: Boolean;
begin Result:=FindExternalTool('HomeLibPDF.exe','pdfium')<>''; end;

function Canceled: Boolean;
begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end;

procedure WriteExact(Handle: THandle; const Buffer; Count: Cardinal);
var Done, Written: Cardinal;
begin
  Done:=0;
  while Done<Count do
  begin
    if not WriteFile(Handle,PByte(@Buffer)[Done],Count-Done,Written,nil) or (Written=0) then RaiseLastOSError;
    Inc(Done,Written);
  end;
end;

procedure TReaderPDFWorker.Send(const Request: TPDFRequest; const Text: UTF8String);
begin
  if Canceled then Abort;
  WriteExact(FInput,Request,SizeOf(Request));
  if Text<>'' then WriteExact(FInput,Text[1],Length(Text));
end;

procedure TReaderPDFWorker.Receive(out Response: TPDFResponse);
var Started: UInt64; Available, Got: Cardinal; Error: UTF8String;
  procedure ReadExact(var Buffer; Size: Cardinal);
  var Done: Cardinal;
  begin
    Done:=0;
    while Done<Size do
    begin
      if Canceled then Abort;
      if GetTickCount64-Started>30000 then raise Exception.Create('Декодирование PDF заняло больше 30 секунд.');
      if not PeekNamedPipe(FOutput,nil,0,nil,@Available,nil) then
        raise Exception.Create('Декодер PDF завершился до получения страницы.');
      if Available>0 then
      begin
        if not ReadFile(FOutput,PByte(@Buffer)[Done],Min(Available,Size-Done),Got,nil) or (Got=0) then RaiseLastOSError;
        Inc(Done,Got);
      end
      else if WaitForSingleObject(FProcess,1)=WAIT_OBJECT_0 then
        raise Exception.Create('Декодер PDF завершился до получения страницы.');
    end;
  end;
begin
  Started:=GetTickCount64;
  try
    ReadExact(Response,SizeOf(Response));
    if (Response.Magic<>PDF_PROTOCOL) or (Response.Length<0) or (Response.Length>12000) then
      raise Exception.Create('Некорректный ответ декодера PDF.');
    if Response.Length>0 then
    begin SetLength(Error,Response.Length); ReadExact(Error[1],Response.Length); end;
    if Response.Status<>0 then raise Exception.Create(string(Error));
  except Stop; raise; end;
end;

procedure TReaderPDFWorker.Start;
var Security: TSecurityAttributes; ChildIn, ChildOut, NullError: THandle;
  StartInfo: TStartupInfo; ProcessInfo: TProcessInformation;
  JobLimits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  GUID: TGUID; MapName, Tool, CommandLine: string; Text: UTF8String;
  Request: TPDFRequest; Response: TPDFResponse;
begin
  if FProcess<>0 then Exit;
  if Canceled then Abort;
  try
  Tool:=FindExternalTool('HomeLibPDF.exe','pdfium');
  if Tool='' then raise EMHLComponentRequired.Create('PDFium','Для этой книги нужен модуль PDFium.');
  CreateGUID(GUID); MapName:='Local\HomeLibRu-PDF-'+GUIDToString(GUID);
  FMapping:=CreateFileMapping(INVALID_HANDLE_VALUE,nil,PAGE_READWRITE,0,PDF_BUFFER_BYTES,PChar(MapName));
  if FMapping=0 then RaiseLastOSError;
  FView:=MapViewOfFile(FMapping,FILE_MAP_READ,0,0,PDF_BUFFER_BYTES);
  if FView=nil then RaiseLastOSError;
  FillChar(Security,SizeOf(Security),0); Security.nLength:=SizeOf(Security); Security.bInheritHandle:=True;
  ChildIn:=0; ChildOut:=0; NullError:=INVALID_HANDLE_VALUE;
  FillChar(ProcessInfo,SizeOf(ProcessInfo),0);
  try
    if not CreatePipe(ChildIn,FInput,@Security,4096) then RaiseLastOSError;
    if not SetHandleInformation(FInput,HANDLE_FLAG_INHERIT,0) then RaiseLastOSError;
    if not CreatePipe(FOutput,ChildOut,@Security,4096) then RaiseLastOSError;
    if not SetHandleInformation(FOutput,HANDLE_FLAG_INHERIT,0) then RaiseLastOSError;
    NullError:=CreateFile('NUL',GENERIC_WRITE,FILE_SHARE_READ or FILE_SHARE_WRITE,@Security,OPEN_EXISTING,0,0);
    if NullError=INVALID_HANDLE_VALUE then RaiseLastOSError;
    FillChar(StartInfo,SizeOf(StartInfo),0); StartInfo.cb:=SizeOf(StartInfo);
    StartInfo.dwFlags:=STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES; StartInfo.wShowWindow:=SW_HIDE;
    StartInfo.hStdInput:=ChildIn; StartInfo.hStdOutput:=ChildOut; StartInfo.hStdError:=NullError;
    // A file name is sent through the pipe, never through a shell or command.
    CommandLine:='"'+Tool+'" --worker "'+MapName+'"'; UniqueString(CommandLine);
    FJob:=CreateJobObject(nil,nil); if FJob=0 then RaiseLastOSError;
    FillChar(JobLimits,SizeOf(JobLimits),0); JobLimits.BasicLimitInformation.LimitFlags:=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if not SetInformationJobObject(FJob,JobObjectExtendedLimitInformation,@JobLimits,SizeOf(JobLimits)) then RaiseLastOSError;
    if not CreateProcess(PChar(Tool),PChar(CommandLine),nil,nil,True,CREATE_NO_WINDOW or CREATE_SUSPENDED,
      nil,PChar(ExtractFilePath(Tool)),StartInfo,ProcessInfo) then RaiseLastOSError;
    FProcess:=ProcessInfo.hProcess;
    if not AssignProcessToJobObject(FJob,FProcess) then begin TerminateProcess(FProcess,ERROR_CANCELLED); RaiseLastOSError; end;
    if ResumeThread(ProcessInfo.hThread)=DWORD(-1) then RaiseLastOSError;
  finally
    if ProcessInfo.hThread<>0 then CloseHandle(ProcessInfo.hThread);
    if ChildIn<>0 then CloseHandle(ChildIn);
    if ChildOut<>0 then CloseHandle(ChildOut);
    if NullError<>INVALID_HANDLE_VALUE then CloseHandle(NullError);
  end;
  Text:=UTF8String(FFileName);
  Request:=Default(TPDFRequest); Request.Magic:=PDF_PROTOCOL; Request.Command:=PDF_OPEN; Request.Length:=Length(Text);
  Send(Request,Text); Receive(Response);
  if (Response.Count<=0) or (Response.Count>100000) then raise Exception.Create('Некорректное число страниц PDF.');
  FPageCount:=Response.Count;
  except Stop; raise; end;
end;

procedure TReaderPDFWorker.Stop;
begin
  // Closing the job terminates its entire process tree, also during cancellation.
  if FJob<>0 then begin CloseHandle(FJob); FJob:=0; end;
  if FProcess<>0 then begin WaitForSingleObject(FProcess,1000); CloseHandle(FProcess); FProcess:=0; end;
  if FInput<>0 then begin CloseHandle(FInput); FInput:=0; end;
  if FOutput<>0 then begin CloseHandle(FOutput); FOutput:=0; end;
  if FView<>nil then begin UnmapViewOfFile(FView); FView:=nil; end;
  if FMapping<>0 then begin CloseHandle(FMapping); FMapping:=0; end;
end;

constructor TReaderPDFWorker.Create(const FileName: string);
begin inherited Create; FFileName:=TPath.GetFullPath(FileName); Start; end;

destructor TReaderPDFWorker.Destroy;
begin Stop; inherited; end;

procedure TReaderPDFWorker.RenderPage(Index: Integer; out Pixels: TBytes; out Width, Height: Integer;
  MaxEdge: Integer);
var Request: TPDFRequest; Response: TPDFResponse; Size: Int64;
begin
  Start;
  if (Index<0) or (Index>=FPageCount) then raise ERangeError.Create('Номер страницы PDF вне диапазона.');
  Request:=Default(TPDFRequest); Request.Magic:=PDF_PROTOCOL; Request.Command:=PDF_RENDER; Request.Index:=Index;
  Request.Length:=MaxEdge;
  Send(Request); Receive(Response);
  Width:=Response.Width; Height:=Response.Height; Size:=Int64(Width)*Height*4;
  if (Width<=0) or (Height<=0) or (Width>4000) or (Height>4000) or (Size>PDF_BUFFER_BYTES) then
    raise Exception.Create('Некорректный размер готовой страницы PDF.');
  SetLength(Pixels,Size); Move(FView^,Pixels[0],Size);
  if Canceled then Abort;
end;

end.
