// Failure/cancel lifecycle helpers. Requires Require, Vcl.Forms,
// System.Classes, System.SysUtils, System.Math and Winapi.Windows.
procedure DrainFailedReaderIdleCleanup(const Stage: string);
const
  IdleMilliseconds = 500;
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
    // Match the standalone reader lifecycle test's real idle interval.
    // ProcessMessages/CheckSynchronize alone can return immediately and leave
    // timed cleanup from RichEdit, COM or VCL pending at the resource sample.
    Sleep(10); Application.ProcessMessages; CheckSynchronize(2); GdiFlush;
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
  until SampledAt - Started >= IdleMilliseconds;
  Writeln('PROFILE failed reader idle stage=', Stage,
    ' elapsed_ms=', SampledAt - Started, ' stable_ms=', SampledAt - ChangedAt,
    ' sample_changes=', Changes,
    ' user_before=', BeforeUSER, ' user_after=', CurrentUSER,
    ' user_min=', MinimumUSER, ' user_max=', MaximumUSER,
    ' gdi_before=', BeforeGDI, ' gdi_after=', CurrentGDI,
    ' gdi_min=', MinimumGDI, ' gdi_max=', MaximumGDI);
  Flush(Output);
  // Normal painting/timers can keep USER/GDI moving even before a reader is
  // opened. Sample after the same bounded idle interval as the standalone
  // test; the caller retains its original +4 limits and exact HWND/VCL checks.
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
