// Diagnostic only: isolate the three label changes in one optimized binary.
// The author-list reference deliberately uses the current GetFullName, so its
// result measures the list fast path separately from component FormatName.
procedure BenchmarkDisplayLabels;
const Iterations = 2000000;
var
  Names: array[0..7] of TAuthorData;
  Authors: array[0..7] of TBookAuthors;
  Genres: array[0..7] of TBookGenres;
  Phase, Trial, Index, Item: Integer;
  BeforeTicks, AfterTicks, BeforeSum, AfterSum: UInt64;
  BeforeCycles, AfterCycles: UInt64;

  function FormerName(const LastName, FirstName, MiddleName: string;
    const NickName: string = ''; OnlyInitials: Boolean = False): string;
  begin
    Result := LastName;
    if FirstName <> '' then
      if OnlyInitials then Result := Result + ' ' + FirstName[1] + '.'
      else Result := Result + ' ' + FirstName;
    if MiddleName <> '' then
      if OnlyInitials then Result := Result + ' ' + MiddleName[1] + '.'
      else Result := Result + ' ' + MiddleName;
    if NickName <> '' then
      if Result = '' then Result := NickName
      else Result := Result + '(' + NickName + ')';
  end;

  function FormerAuthors(const Values: TBookAuthors): string;
  begin
    Result := TArrayUtils.Join<TAuthorData>(Values, ', ',
      function(const Value: TAuthorData): string
      begin Result := Value.GetFullName; end);
  end;

  function FormerGenres(const Values: TBookGenres): string;
  begin
    Result := TArrayUtils.Join<TGenreData>(Values, ' / ',
      function(const Value: TGenreData): string
      begin Result := Value.GenreAlias; end);
  end;

  function Measure(Kind: Integer; Current: Boolean; out Checksum, Cycles: UInt64): UInt64;
  var I, At: Integer; Text: string; Watch: TStopwatch; StartedCycles: UInt64;
  begin
    Checksum := 0;
    if not QueryThreadCycleTime(GetCurrentThread,StartedCycles) then RaiseLastOSError;
    Watch := TStopwatch.StartNew;
    case Kind of
      0:
        if Current then
          for I := 0 to Iterations-1 do
          begin
            At := I and 7;
            Text := unit_FB2Utils.FormatName(Names[At].LastName, Names[At].FirstName, Names[At].MiddleName);
            Inc(Checksum, Length(Text));
          end
        else
          for I := 0 to Iterations-1 do
          begin
            At := I and 7;
            Text := FormerName(Names[At].LastName, Names[At].FirstName, Names[At].MiddleName);
            Inc(Checksum, Length(Text));
          end;
      1:
        if Current then
          for I := 0 to Iterations-1 do
          begin Text := TAuthorsHelper.GetList(Authors[I and 7]); Inc(Checksum, Length(Text)); end
        else
          for I := 0 to Iterations-1 do
          begin Text := FormerAuthors(Authors[I and 7]); Inc(Checksum, Length(Text)); end;
      2:
        if Current then
          for I := 0 to Iterations-1 do
          begin Text := TGenresHelper.GetList(Genres[I and 7]); Inc(Checksum, Length(Text)); end
        else
          for I := 0 to Iterations-1 do
          begin Text := FormerGenres(Genres[I and 7]); Inc(Checksum, Length(Text)); end;
    end;
    Result := Watch.ElapsedTicks;
    if not QueryThreadCycleTime(GetCurrentThread,Cycles) then RaiseLastOSError;
    Dec(Cycles,StartedCycles);
  end;
begin
  {$IFNDEF MHL_RELEASE_PERFORMANCE}
  raise Exception.Create('Display label diagnosis requires the GUI Performance build');
  {$ENDIF}
  TestBookDisplayNames;
  for Index := 0 to 7 do
  begin
    Names[Index].LastName := 'Васильев '+IntToStr(Index);
    if Index <> 6 then Names[Index].FirstName := 'Андрей';
    if Index <> 7 then Names[Index].MiddleName := 'Александрович';
  end;
  for Index := 0 to 7 do
  begin
    // Four single values, then empty/two/three/four. Include Unicode, short
    // names and the same separators/order the production tree uses.
    Item := 1;
    case Index of 4: Item:=0; 5: Item:=2; 6: Item:=3; 7: Item:=4; end;
    SetLength(Authors[Index], Item); SetLength(Genres[Index], Item);
    for var J := 0 to Item-1 do
    begin
      Authors[Index][J] := Names[(Index+J) and 7];
      Genres[Index][J].GenreAlias := 'Проза ё '+IntToStr(J);
    end;
    Require(FormerName(Names[Index].LastName,Names[Index].FirstName,Names[Index].MiddleName)=
      unit_FB2Utils.FormatName(Names[Index].LastName,Names[Index].FirstName,Names[Index].MiddleName),
      'Display benchmark name output differs');
    Require(FormerAuthors(Authors[Index])=TAuthorsHelper.GetList(Authors[Index]),
      'Display benchmark author output differs');
    Require(FormerGenres(Genres[Index])=TGenresHelper.GetList(Genres[Index]),
      'Display benchmark genre output differs');
  end;
  Writeln('LABELBENCH frequency=',TStopwatch.Frequency,' iterations=',Iterations,' trials=7'); Flush(Output);
  for Phase := 0 to 2 do
  begin
    Measure(Phase,False,BeforeSum,BeforeCycles); Measure(Phase,True,AfterSum,AfterCycles);
    Require(BeforeSum=AfterSum,'Display label warm-up checksums differ');
    for Trial := 0 to 6 do
    begin
      if Odd(Trial) then
      begin AfterTicks:=Measure(Phase,True,AfterSum,AfterCycles); BeforeTicks:=Measure(Phase,False,BeforeSum,BeforeCycles); end
      else
      begin BeforeTicks:=Measure(Phase,False,BeforeSum,BeforeCycles); AfterTicks:=Measure(Phase,True,AfterSum,AfterCycles); end;
      Require((BeforeSum=AfterSum) and (BeforeTicks>0) and (AfterTicks>0),
        'Display label measured results differ');
      Writeln('LABELBENCH phase=',Phase,' trial=',Trial,' before_ticks=',BeforeTicks,
        ' after_ticks=',AfterTicks,' before_cycles=',BeforeCycles,
        ' after_cycles=',AfterCycles,' checksum=',AfterSum); Flush(Output);
    end;
  end;
  Writeln('PASS diagnostic display labels same-process alternating comparison preserves all values'); Flush(Output);
end;
