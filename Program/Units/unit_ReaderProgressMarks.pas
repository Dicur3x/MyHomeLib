unit unit_ReaderProgressMarks;

interface

type
  // One slot per physical pixel: -1 is a major section, 1 is a subchapter.
  TReaderProgressTicks = TArray<ShortInt>;

procedure IncludeReaderProgressTick(var Ticks: TReaderProgressTicks;
  Position, TextLength, Depth: Integer);

implementation

uses Winapi.Windows;

procedure IncludeReaderProgressTick(var Ticks: TReaderProgressTicks;
  Position, TextLength, Depth: Integer);
var Pixel: Integer;
begin
  if (Length(Ticks)<2) or (TextLength<=0) or (Position<=0) or
    (Position>=TextLength) or (Depth>1) then Exit;
  Pixel:=MulDiv(High(Ticks),Position,TextLength);
  if (Pixel<0) or (Pixel>High(Ticks)) then Exit;
  // Only true pixel collisions merge; there is no arbitrary chapter-count cap.
  if Depth<=0 then Ticks[Pixel]:=-1
  else if Ticks[Pixel]=0 then Ticks[Pixel]:=1;
end;

end.
