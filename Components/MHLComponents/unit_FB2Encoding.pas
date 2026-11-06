unit unit_FB2Encoding;

interface

uses System.SysUtils;

const FB2_ENCODING_PROBE_SIZE = 8192;

// Correct an ASCII XML declaration in the caller's working buffer.
// PrefixOnly is for metadata readers that do not load the rest of the book.
function RepairFB2UTF8Declaration(var Bytes: TBytes; PrefixOnly: Boolean = False): Boolean;

implementation

uses System.Math, System.RegularExpressions, Winapi.Windows;

function RepairFB2UTF8Declaration(var Bytes: TBytes; PrefixOnly: Boolean): Boolean;
const
  UTF8Name: AnsiString = 'UTF-8';
var
  Header: string;
  Declaration: TMatch;
  Name: TGroup;
  Start, CheckLength, ProbeEnd, I, RunLength, NameOffset: Integer;
begin
  Result := False;
  if Length(Bytes) < 6 then Exit;
  Start := 0;
  if (Bytes[0]=$EF) and (Bytes[1]=$BB) and (Bytes[2]=$BF) then Start := 3;
  if (Bytes[Start]<>Ord('<')) or (Bytes[Start+1]<>Ord('?')) then Exit;
  Header := TEncoding.ASCII.GetString(Bytes,Start,Min(512,Length(Bytes)-Start));
  Declaration := TRegEx.Match(Header,
    '^<\?xml\s+[^?]*\bencoding\s*=\s*(["''])(windows-1251|cp1251)\1', [roIgnoreCase]);
  if not Declaration.Success then Exit;

  // A CP1251 document can contain isolated byte pairs that also decode as UTF-8.
  // Require a UTF-8 BOM or a run of Russian letters, then verify the UTF-8 bytes.
  CheckLength := Length(Bytes);
  if PrefixOnly then
  begin
    // The final read can stop partway through a UTF-8 character.
    // The preceding markup boundary ends on an ASCII byte.
    while (CheckLength>Start) and (Bytes[CheckLength-1]<>Ord('>')) do
      Dec(CheckLength);
  end;
  ProbeEnd := Min(CheckLength,FB2_ENCODING_PROBE_SIZE);
  if Start=0 then
  begin
    RunLength := 0;
    I := Declaration.Length;
    while I+1 < ProbeEnd do
    begin
      if ((Bytes[I]=$D0) and ((Bytes[I+1]=$81) or (Bytes[I+1] in [$90..$BF]))) or
        ((Bytes[I]=$D1) and ((Bytes[I+1]=$91) or (Bytes[I+1] in [$80..$8F]))) then
      begin
        Inc(RunLength);
        Inc(I,2);
        if RunLength=4 then Break;
      end
      else
      begin
        RunLength := 0;
        Inc(I);
      end;
    end;
    if RunLength<4 then Exit;
  end;

  if (CheckLength<=Start) or
    (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Bytes[Start]),
      CheckLength-Start,nil,0)=0) then Exit;

  Name := Declaration.Groups[2];
  NameOffset := Start+Name.Index-1;
  Bytes[NameOffset+Length(UTF8Name)] := Bytes[NameOffset+Name.Length];
  Move(UTF8Name[1],Bytes[NameOffset],Length(UTF8Name));
  // Keep the declaration and all following byte offsets the same length.
  FillChar(Bytes[NameOffset+Length(UTF8Name)+1],Name.Length-Length(UTF8Name),Ord(' '));
  Result := True;
end;

end.
