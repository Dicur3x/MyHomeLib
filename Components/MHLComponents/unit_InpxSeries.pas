unit unit_InpxSeries;

interface

uses
  System.SysUtils;

type
  TInpxSeriesItem = record
    Title: string;
    Number: Integer;
  end;
  TInpxSeriesItems = TArray<TInpxSeriesItem>;

// LightLib stores several series in one row: names separated by backslashes,
// with corresponding sequence numbers separated by colons. Standard INPX
// continues to use a single title and a single integer.
function ParseInpxSeries(const Titles, Numbers: string): TInpxSeriesItems;

implementation

function ParseInpxSeries(const Titles, Numbers: string): TInpxSeriesItems;
var
  Names, Values: TArray<string>;
  I, Count: Integer;
begin
  SetLength(Result, 0);
  if Trim(Titles) = '' then
    Exit;
  Names := Titles.Split(['\']);
  Values := Numbers.Split([':']);
  SetLength(Result, Length(Names));
  Count := 0;
  for I := 0 to High(Names) do
    if Trim(Names[I]) <> '' then
    begin
      Result[Count].Title := Trim(Names[I]);
      if I < Length(Values) then
        Result[Count].Number := StrToIntDef(Trim(Values[I]), 0)
      else
        Result[Count].Number := 0;
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

end.
