// Failure/cancel lifecycle helpers. Requires Require, Vcl.Forms,
// System.Classes, System.SysUtils, System.Math and Winapi.Windows.
type
  TReaderThreadEntry = record
    Size, Usage, ThreadID, ProcessID: DWORD;
    BasePriority, DeltaPriority: Longint;
    Flags: DWORD;
  end;
  TReaderInputContextCallback = function(Context: THandle; Data: LPARAM): BOOL; stdcall;
  TReaderThreadQuery = function(Thread: THandle; InfoClass: ULONG; Info: Pointer;
    InfoSize: ULONG; Returned: Pointer): Longint; stdcall;
var
  ReaderRawUSER, ReaderSystemInputContexts: Cardinal;
function ReaderEnumInputContexts(ThreadID: DWORD; Callback: TReaderInputContextCallback;
  Data: LPARAM): BOOL; stdcall; external 'imm32.dll' name 'ImmEnumInputContext';
function ReaderThreadSnapshot(Flags, PID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateToolhelp32Snapshot';
function ReaderThreadFirst(Snapshot: THandle; var Entry: TReaderThreadEntry): BOOL; stdcall;
  external 'kernel32.dll' name 'Thread32First';
function ReaderThreadNext(Snapshot: THandle; var Entry: TReaderThreadEntry): BOOL; stdcall;
  external 'kernel32.dll' name 'Thread32Next';
function ReaderOpenThread(Access: DWORD; Inherit: BOOL; ID: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'OpenThread';
function ReaderModuleFromAddress(Flags: DWORD; Address: PChar; var Module: HMODULE): BOOL; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleExW';
function ReaderCountInputContext(Context: THandle; Data: LPARAM): BOOL; stdcall;
begin
  Inc(PInteger(Data)^); Result := True;
end;

function ReaderApplicationUSERCount: Cardinal;
var Snapshot, Thread: THandle; Entry: TReaderThreadEntry; Count: Integer;
  StartAddress: Pointer; Module: HMODULE; Query: TReaderThreadQuery;
begin
  ReaderSystemInputContexts := 0;
  Query := TReaderThreadQuery(GetProcAddress(GetModuleHandle('ntdll.dll'), 'NtQueryInformationThread'));
  Snapshot := ReaderThreadSnapshot(4, 0); // TH32CS_SNAPTHREAD, read-only inventory
  if Snapshot <> INVALID_HANDLE_VALUE then
  try
    Entry.Size := SizeOf(Entry);
    if Assigned(Query) and ReaderThreadFirst(Snapshot, Entry) then
      repeat
        if (Entry.ProcessID <> GetCurrentProcessId) or
          (Entry.ThreadID = GetCurrentThreadId) then Continue;
        Thread := ReaderOpenThread($0040, False, Entry.ThreadID); // THREAD_QUERY_INFORMATION
        if Thread = 0 then Continue;
        try
          StartAddress := nil; Module := 0; Count := 0;
          // Only a single default HIMC on a live Windows worker is accounted
          // separately. EXE reader threads, UI threads, custom contexts and
          // all HWND/menu/icon/etc. allocations remain in the original +4.
          if (Query(Thread, 9, @StartAddress, SizeOf(StartAddress), nil) = 0) and
            ReaderModuleFromAddress(6, PChar(StartAddress), Module) and
            (Module = GetModuleHandle('ntdll.dll')) then
          begin
            ReaderEnumInputContexts(Entry.ThreadID, ReaderCountInputContext, LPARAM(@Count));
            if Count = 1 then Inc(ReaderSystemInputContexts);
          end;
        finally CloseHandle(Thread); end;
      until not ReaderThreadNext(Snapshot, Entry);
  finally CloseHandle(Snapshot); end;
  ReaderRawUSER := Winapi.Windows.GetGuiResources(GetCurrentProcess, GR_USEROBJECTS);
  Require(ReaderRawUSER >= ReaderSystemInputContexts, 'Invalid USER input-context accounting');
  Result := ReaderRawUSER - ReaderSystemInputContexts;
end;

procedure DrainFailedReaderIdleCleanup(const Stage: string; AllowedGDI: Cardinal = 0; AllowedUSER: Cardinal = 0);
const
  MinimumIdleMilliseconds = 500;
  StableMilliseconds = 250;
  MaximumIdleMilliseconds = 5000;
var
  Started, ChangedAt, SampledAt: UInt64;
  BeforeUSER, BeforeGDI, CurrentUSER, CurrentGDI, PreviousUSER, PreviousGDI,
    MinimumUSER, MaximumUSER, MinimumGDI, MaximumGDI: Cardinal;
  Changes: Integer;
begin
  BeforeUSER := ReaderApplicationUSERCount;
  BeforeGDI := GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS);
  PreviousUSER := BeforeUSER; PreviousGDI := BeforeGDI;
  MinimumUSER := BeforeUSER; MaximumUSER := BeforeUSER;
  MinimumGDI := BeforeGDI; MaximumGDI := BeforeGDI;
  Started := GetTickCount64; ChangedAt := Started; Changes := 0;
  repeat
    // Let pending native cleanup run before sampling the original budgets.
    // ProcessMessages does not perform the VCL Idle phase. Run that phase
    // explicitly without using HandleMessage, which can block on an empty queue.
    Sleep(10); Application.ProcessMessages; Application.DoApplicationIdle;
    CheckSynchronize(2); GdiFlush;
    CurrentUSER := ReaderApplicationUSERCount;
    CurrentGDI := GetGuiResources(GetCurrentProcess, GR_GDIOBJECTS);
    SampledAt := GetTickCount64;
    if (CurrentUSER <> PreviousUSER) or (CurrentGDI <> PreviousGDI) then
    begin ChangedAt := SampledAt; Inc(Changes); end;
    PreviousUSER := CurrentUSER; PreviousGDI := CurrentGDI;
    MinimumUSER := Min(MinimumUSER, CurrentUSER);
    MaximumUSER := Max(MaximumUSER, CurrentUSER);
    MinimumGDI := Min(MinimumGDI, CurrentGDI);
    MaximumGDI := Max(MaximumGDI, CurrentGDI);
  until (SampledAt - Started >= MinimumIdleMilliseconds) and
    (((SampledAt - ChangedAt >= StableMilliseconds) and
      ((AllowedGDI=0) or (CurrentGDI<=AllowedGDI)) and
      ((AllowedUSER=0) or (CurrentUSER<=AllowedUSER))) or
     (SampledAt - Started >= MaximumIdleMilliseconds));
  Writeln('PROFILE failed reader idle stage=', Stage,
    ' elapsed_ms=', SampledAt - Started, ' stable_ms=', SampledAt - ChangedAt,
    ' sample_changes=', Changes,
    ' user_before=', BeforeUSER, ' user_after=', CurrentUSER,
    ' user_min=', MinimumUSER, ' user_max=', MaximumUSER,
    ' gdi_before=', BeforeGDI, ' gdi_after=', CurrentGDI,
    ' gdi_min=', MinimumGDI, ' gdi_max=', MaximumGDI,
    ' raw_user=', ReaderRawUSER, ' windows_worker_default_input_contexts=', ReaderSystemInputContexts);
  Flush(Output);
  // Wait for bounded idle cleanup. Report the raw USER count as well as
  // separately identified Windows-worker default input contexts. The +4
  // application budget and exact HWND/VCL ownership checks remain strict.
end;

procedure RequireFailedReaderHandleBaseline(const Stage: string;
  Current, Baseline: TStrings);
begin
  Require(Current.Count = Baseline.Count,
    'Failed reader changed its ' + Stage + ' handle count after idle cleanup');
  for var I := 0 to Current.Count - 1 do
  begin
    Require(Baseline.IndexOfName(Current.Names[I]) >= 0,
      'Failed reader left an unexpected ' + Stage + ' handle after idle cleanup: ' + Current[I]);
    Require(Baseline.Values[Current.Names[I]] = Current.ValueFromIndex[I],
      'Failed reader changed a baseline ' + Stage + ' handle after idle cleanup: ' + Current[I]);
  end;
end;
