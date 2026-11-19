unit unit_KindleGuideCover;

interface

uses System.Classes, System.SysUtils;

// Returns the one-based image index from the MOBI 6 HTML guide, or zero.
function KindleGuideImage(Stream: TStream; const Offsets: TArray<Int64>;
  RecordCount, Compression, ExtraFlags: Integer; TextLength: Cardinal;
  const IsCanceled: TFunc<Boolean>): Integer;

implementation

uses System.Math, System.StrUtils;

const
  HeadLimit = 32 * 1024;
  CoverPageLimit = 8 * 1024;
  TextReadLimit = 16 * 1024 * 1024;
  DecodedRecordLimit = 64 * 1024;

procedure InvalidRecord;
begin
  raise EReadError.Create('Повреждена текстовая запись MOBI со ссылкой на обложку.');
end;

function DecodeRecord(const Data: TBytes; Compression, Flags: Integer): string;
var Size, Trailer, Source, Used, Code, Count, Distance: Integer;
    Plain: TBytes;
  procedure Reserve(N: Integer);
  begin
    if Used > Length(Plain)-N then InvalidRecord;
  end;
begin
  Size := Length(Data);
  // Extra records end with their own length, encoded in up to four 7-bit groups.
  for var Bit := 1 to 15 do
    if Flags and (1 shl Bit) <> 0 then
    begin
      Trailer := 0;
      var Start := Size-1;
      while (Start>=Max(0,Size-4)) and (Data[Start] and $80=0) do Dec(Start);
      if Start<Max(0,Size-4) then InvalidRecord;
      for var I := Start to Size-1 do Trailer := (Trailer shl 7) or (Data[I] and $7F);
      if (Trailer<Size-Start) or (Trailer>Size) then InvalidRecord;
      Dec(Size,Trailer);
    end;
  if Flags and 1 <> 0 then
  begin
    if Size=0 then InvalidRecord;
    Dec(Size,1+(Data[Size-1] and 3));
    if Size<0 then InvalidRecord;
  end;
  if Compression=1 then Exit(TEncoding.ASCII.GetString(Data,0,Size));

  SetLength(Plain,Min(DecodedRecordLimit,Size*8));
  Used := 0;
  Source := 0;
  while Source<Size do
  begin
    Code := Data[Source];
    Inc(Source);
    case Code of
      1..8:
        begin
          if Source>Size-Code then InvalidRecord;
          Reserve(Code);
          Move(Data[Source],Plain[Used],Code);
          Inc(Source,Code);
          Inc(Used,Code);
        end;
      $80..$BF:
        begin
          if Source=Size then InvalidRecord;
          Code := ((Code and $3F) shl 8) or Data[Source];
          Inc(Source);
          Distance := Code shr 3;
          Count := (Code and 7)+3;
          if (Distance=0) or (Distance>Used) then InvalidRecord;
          Reserve(Count);
          for var I := 1 to Count do
          begin
            Plain[Used] := Plain[Used-Distance];
            Inc(Used);
          end;
        end;
      $C0..$FF:
        begin
          Reserve(2);
          Plain[Used] := $20;
          Plain[Used+1] := Code xor $80;
          Inc(Used,2);
        end;
      else
        begin
          Reserve(1);
          Plain[Used] := Code;
          Inc(Used);
        end;
    end;
  end;
  Result := TEncoding.ASCII.GetString(Plain,0,Used);
end;

type
  TGuideTag = record
    Name, RefType, FilePos, RecIndex: string;
  end;

function ReadTag(const S: string; var P: Integer; out Tag: TGuideTag): Boolean;
var Start, Depth: Integer; Key, Value: string; Quote: Char;
  procedure Spaces;
  begin
    while (P<=Length(S)) and (S[P]<=' ') do Inc(P);
  end;
  function NameChar(C: Char): Boolean;
  begin
    Result := CharInSet(C,['a'..'z','0'..'9','-',':','_','.']);
  end;
begin
  Result := False;
  Tag := Default(TGuideTag);
  if (P>Length(S)) or (S[P]<>'<') then Exit;
  if Copy(S,P,4)='<!--' then
  begin
    P := PosEx('-->',S,P+4);
    if P=0 then Exit;
    Inc(P,3);
    Tag.Name := '!--';
    Exit(True);
  end;
  if (Copy(S,P,9)='<!doctype') or (Copy(S,P,2)='<?') then
  begin
    Tag.Name := 'declaration';
    Quote := #0;
    Depth := 0;
    Inc(P,2);
    while P<=Length(S) do
    begin
      var C := S[P];
      Inc(P);
      if Quote<>#0 then
      begin
        if C=Quote then Quote := #0;
      end
      else case C of
        '"',#39: Quote := C;
        '[': Inc(Depth);
        ']': if Depth>0 then Dec(Depth);
        '>': if Depth=0 then Exit(True);
      end;
    end;
    Exit;
  end;
  Inc(P);
  Start := P;
  if (P<=Length(S)) and CharInSet(S[P],['/','!','?']) then Inc(P);
  while (P<=Length(S)) and NameChar(S[P]) do Inc(P);
  if P=Start then Exit;
  Tag.Name := Copy(S,Start,P-Start);
  while P<=Length(S) do
  begin
    Spaces;
    if P>Length(S) then Exit;
    if CharInSet(S[P],['/','?']) and (Copy(S,P+1,1)='>') then Inc(P);
    if S[P]='>' then begin Inc(P); Exit(True); end;
    Start := P;
    while (P<=Length(S)) and NameChar(S[P]) do Inc(P);
    if P=Start then Exit;
    Key := Copy(S,Start,P-Start);
    Spaces;
    if (P>Length(S)) or (S[P]<>'=') then Continue;
    Inc(P);
    Spaces;
    if P>Length(S) then Exit;
    Quote := #0;
    if CharInSet(S[P],['"',#39]) then begin Quote := S[P]; Inc(P); end;
    Start := P;
    if Quote<>#0 then
    begin
      while (P<=Length(S)) and (S[P]<>Quote) do Inc(P);
      if P>Length(S) then Exit;
    end
    else
      while (P<=Length(S)) and (S[P]>' ') and (S[P]<>'>') and
        not ((S[P]='/') and (Copy(S,P+1,1)='>')) do Inc(P);
    Value := Copy(S,Start,P-Start);
    if Quote<>#0 then Inc(P);
    if Key='type' then Tag.RefType := Value
    else if Key='filepos' then Tag.FilePos := Value
    else if Key='recindex' then Tag.RecIndex := Value;
  end;
end;

function Decimal(const S: string): Int64;
begin
  Result := -1;
  if S='' then Exit;
  for var C in S do if not CharInSet(C,['0'..'9']) then Exit;
  if not TryStrToInt64(S,Result) then Result := -1;
end;

function GuidePosition(const S: string; out Complete: Boolean): Int64;
var P: Integer; Inside, Seen: Boolean; Tag: TGuideTag; Target: Int64;
begin
  P := 1;
  Inside := False;
  Seen := False;
  Target := -1;
  Result := -1;
  Complete := False;
  while P<=Length(S) do
  begin
    P := PosEx('<',S,P);
    if (P=0) or not ReadTag(S,P,Tag) then Exit;
    if (Tag.Name='body') or (Tag.Name='/head') then begin Complete := True; Exit; end;
    if (Tag.Name='title') or (Tag.Name='script') or (Tag.Name='style') then
    begin
      P := PosEx('</'+Tag.Name+'>',S,P);
      if P=0 then Exit;
      Inc(P,Length(Tag.Name)+3);
    end
    else if Tag.Name='guide' then Inside := True
    else if Inside and (Tag.Name='/guide') then
    begin
      Complete := True;
      if Target>=P-1 then Result := Target;
      Exit;
    end
    else if Inside and (Tag.Name='reference') and (Tag.RefType='cover') then
    begin
      if Seen then begin Complete := True; Exit; end;
      Seen := True;
      Target := Decimal(Tag.FilePos);
    end;
  end;
end;

function PageImage(const S: string; out Complete: Boolean): Integer;
var P: Integer; Tag: TGuideTag;
begin
  Result := 0;
  Complete := False;
  P := 1;
  while P<=Length(S) do
  begin
    while (P<=Length(S)) and (S[P]<=' ') do Inc(P);
    if P>Length(S) then Exit;
    if S[P]<>'<' then begin Complete := True; Exit; end;
    if not ReadTag(S,P,Tag) then Exit;
    if Tag.Name='img' then
    begin
      Complete := True;
      var Index := Decimal(Tag.RecIndex);
      if (Index>0) and (Index<=High(Word)) then Result := Integer(Index);
      Exit;
    end;
    // Follow only the markup wrapping the explicitly referenced image. Never
    // cross intervening prose or a page break in search of another illustration.
    if not MatchStr(Tag.Name,['!--','body','div','center','p','a','/a','span','font','b','br']) then
    begin Complete := True; Exit; end;
  end;
end;

function KindleGuideImage(Stream: TStream; const Offsets: TArray<Int64>;
  RecordCount, Compression, ExtraFlags: Integer; TextLength: Cardinal;
  const IsCanceled: TFunc<Boolean>): Integer;
var Index, BytesRead, NextCheck: Integer; Position, Target: Int64; Text, Head, Page: string;
    Complete: Boolean;
  function Next: Boolean;
  var Raw: TBytes;
  begin
    Result := False;
    if (Index>=RecordCount) or (Position>=TextLength) then Exit;
    Inc(Index);
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    var Size := Offsets[Index+1]-Offsets[Index];
    if (Size<=0) or (Size>DecodedRecordLimit) or (Size>TextReadLimit-BytesRead) then Exit;
    SetLength(Raw,Integer(Size));
    Stream.Position := Offsets[Index];
    Stream.ReadBuffer(Raw[0],Length(Raw));
    Inc(BytesRead,Length(Raw));
    Text := DecodeRecord(Raw,Compression,ExtraFlags).ToLowerInvariant;
    if Text='' then Exit;
    if Int64(Length(Text))>TextLength-Position then SetLength(Text,Integer(TextLength-Position));
    Inc(Position,Length(Text));
    Result := True;
  end;
begin
  Result := 0;
  Index := 0;
  Position := 0;
  BytesRead := 0;
  NextCheck := 1;
  repeat
    if not Next then Exit;
    Head := Head+Text;
    // Reparse progressively larger prefixes, including at EOF for very
    // short text records. The total work over the header stays linear.
    Complete := False;
    if (Length(Head)>=NextCheck) or (Index=RecordCount) or (Position=TextLength) then
    begin
      Target := GuidePosition(Copy(Head,1,HeadLimit),Complete);
      NextCheck := Min(HeadLimit,Length(Head)*2);
    end;
  until Complete or (Length(Head)>=HeadLimit);
  if (Target<0) or (Target>=TextLength) then Exit;
  if Target<Position then Page := Copy(Head,Integer(Target)+1,CoverPageLimit)
  else
  begin
    repeat if not Next then Exit; until Position>Target;
    Page := Copy(Text,Integer(Target-(Position-Length(Text)))+1,CoverPageLimit);
  end;
  // A tag, including recindex, can straddle a text-record boundary.
  while True do
  begin
    Result := PageImage(Page,Complete);
    if Complete or (Length(Page)>=CoverPageLimit) then Exit;
    NextCheck := Min(CoverPageLimit,Max(1,Length(Page)*2));
    repeat
      if not Next then Exit;
      Page := Page+Copy(Text,1,CoverPageLimit-Length(Page));
    until (Length(Page)>=NextCheck) or (Index=RecordCount) or (Position=TextLength);
  end;
end;

end.
