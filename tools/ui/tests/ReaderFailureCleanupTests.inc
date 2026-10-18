// Failure/cancel lifecycle helpers. Requires Require, Vcl.Forms,
// System.Classes, System.SysUtils, System.Math and Winapi.Windows.
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
  BeforeUSER := GetGuiResources(GetCurrentProcess, GR_USEROBJECTS);
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
    CurrentUSER := GetGuiResources(GetCurrentProcess, GR_USEROBJECTS);
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
    ' gdi_min=', MinimumGDI, ' gdi_max=', MaximumGDI);
  Flush(Output);
  // A no-reader control showed timed resources retiring after the old 500ms
  // sample. Wait for a bounded quiet interval, retaining the original +4
  // budgets and exact HWND/VCL ownership assertions in every measured cycle.
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
