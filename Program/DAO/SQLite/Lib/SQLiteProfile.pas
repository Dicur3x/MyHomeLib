unit SQLiteProfile;

interface

uses System.SysUtils;

// Compiled only for isolated benchmarks. The distributed program has no
// profile storage, timer or locking overhead; user preferences cannot enable it.
procedure StartSQLiteProfile(IncludeSteps: Boolean = True; IncludeIteratorSamples: Boolean = False);
procedure SaveSQLiteProfile(const FileName: string);
procedure StopSQLiteProfile;
function SQLiteProfileClock: Int64; {$IFNDEF MHL_SQL_PROFILE}inline;{$ENDIF}
function SQLiteStepProfileClock: Int64; {$IFNDEF MHL_SQL_PROFILE}inline;{$ENDIF}
function SQLiteIteratorProfileClock: Int64; {$IFNDEF MHL_SQL_PROFILE}inline;{$ENDIF}
procedure RecordSQLiteProfile(const Database, Operation, SQL: string; Started: Int64); {$IFNDEF MHL_SQL_PROFILE}inline;{$ENDIF}

implementation

{$IFDEF MHL_SQL_PROFILE}
uses Winapi.Windows, System.Classes, System.Generics.Collections,
  System.Generics.Defaults;

type
  TProfileEntry = class
    Database, Operation, SQL: string;
    Calls, Ticks: Int64;
  end;

var
  Active: Boolean;
  CaptureSteps, CaptureIteratorSamples: Boolean;
  Frequency: Int64;
  Guard: TObject;
  Entries: TObjectDictionary<string,TProfileEntry>;

procedure StartSQLiteProfile(IncludeSteps, IncludeIteratorSamples: Boolean);
begin
  TMonitor.Enter(Guard);
  try
    Active := False;
    if Entries = nil then Entries := TObjectDictionary<string,TProfileEntry>.Create([doOwnsValues]);
    Entries.Clear;
    QueryPerformanceFrequency(Frequency);
    CaptureSteps := IncludeSteps;
    CaptureIteratorSamples := IncludeIteratorSamples;
    Active := Frequency > 0;
  finally TMonitor.Exit(Guard); end;
end;

procedure StopSQLiteProfile;
begin
  TMonitor.Enter(Guard);
  try Active := False; finally TMonitor.Exit(Guard); end;
end;

function SQLiteProfileClock: Int64;
begin
  Result := 0;
  if Active then QueryPerformanceCounter(Result);
end;

function SQLiteStepProfileClock: Int64;
begin
  Result := 0;
  if Active and CaptureSteps then QueryPerformanceCounter(Result);
end;

function SQLiteIteratorProfileClock: Int64;
begin
  Result := 0;
  if Active and CaptureIteratorSamples then QueryPerformanceCounter(Result);
end;

procedure RecordSQLiteProfile(const Database, Operation, SQL: string; Started: Int64);
var Finished: Int64; Key: string; Entry: TProfileEntry;
begin
  if Started = 0 then Exit;
  QueryPerformanceCounter(Finished);
  TMonitor.Enter(Guard);
  try
    if not Active then Exit;
    Key := Database + #1 + Operation + #1 + SQL;
    if not Entries.TryGetValue(Key, Entry) then
    begin
      if Entries.Count >= 1024 then Key := '<other operations>';
      if not Entries.TryGetValue(Key, Entry) then
      begin
        Entry := TProfileEntry.Create;
        if Key = '<other operations>' then Entry.SQL := Key
        else begin Entry.Database := Database; Entry.Operation := Operation; Entry.SQL := SQL; end;
        Entries.Add(Key, Entry);
      end;
    end;
    Inc(Entry.Calls); Inc(Entry.Ticks, Finished-Started);
  finally TMonitor.Exit(Guard); end;
end;

procedure SaveSQLiteProfile(const FileName: string);
var Values: TArray<TProfileEntry>; Entry: TProfileEntry; Lines: TStringList;
  function OneLine(const Value: string): string;
  begin
    Result := StringReplace(StringReplace(StringReplace(Value,#13,' ',[rfReplaceAll]),
      #10,' ',[rfReplaceAll]),#9,' ',[rfReplaceAll]);
  end;
begin
  TMonitor.Enter(Guard);
  try
    if (Entries = nil) or (Frequency <= 0) then Exit;
    Values := Entries.Values.ToArray;
    TArray.Sort<TProfileEntry>(Values,TComparer<TProfileEntry>.Construct(
      function(const A,B: TProfileEntry): Integer
      begin
        if A.Ticks > B.Ticks then Result := -1
        else if A.Ticks < B.Ticks then Result := 1 else Result := 0;
      end));
    Lines := TStringList.Create;
    try
      Lines.Add('database'+#9+'operation'+#9+'calls'+#9+'elapsed_ms'+#9+'sql_or_phase');
      for Entry in Values do
        Lines.Add(OneLine(Entry.Database)+#9+Entry.Operation+#9+IntToStr(Entry.Calls)+#9+
          IntToStr(Round(Entry.Ticks*1000/Frequency))+#9+OneLine(Entry.SQL));
      Lines.SaveToFile(FileName,TEncoding.UTF8);
    finally Lines.Free; end;
  finally TMonitor.Exit(Guard); end;
end;

initialization
  Guard := TObject.Create;
finalization
  Active := False;
  Entries.Free;
  Guard.Free;
{$ELSE}
procedure StartSQLiteProfile(IncludeSteps, IncludeIteratorSamples: Boolean); begin end;
procedure StopSQLiteProfile; begin end;
procedure SaveSQLiteProfile(const FileName: string); begin end;
function SQLiteProfileClock: Int64; begin Result:=0; end;
function SQLiteStepProfileClock: Int64; begin Result:=0; end;
function SQLiteIteratorProfileClock: Int64; begin Result:=0; end;
procedure RecordSQLiteProfile(const Database, Operation, SQL: string; Started: Int64); begin end;
{$ENDIF}
end.
