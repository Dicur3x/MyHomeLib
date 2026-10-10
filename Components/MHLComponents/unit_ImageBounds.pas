unit unit_ImageBounds;

interface
uses System.Classes, System.SysUtils;
// Read dimensions without invoking an image decoder or allocating pixel data.
function ImageDimensions(const Stream: TStream; out Width, Height: Integer): Boolean;
function ImageFitsMemory(const Stream: TStream; const MaxBytes: Int64): Boolean;

implementation
uses System.Math;

function ImageDimensions(const Stream: TStream; out Width, Height: Integer): Boolean;
var Header: array[0..63] of Byte; Saved, SegmentEnd: Int64;
  Count, Marker, SegmentSize: Integer; W,H: Int64;
  function LE16(P: Integer): Cardinal;
  begin Result:=Cardinal(Header[P]) or (Cardinal(Header[P+1]) shl 8); end;
  function LE32(P: Integer): Cardinal;
  begin Result:=LE16(P) or (LE16(P+2) shl 16); end;
  function BE32(P: Integer): Cardinal;
  begin Result:=(Cardinal(Header[P]) shl 24) or (Cardinal(Header[P+1]) shl 16) or
    (Cardinal(Header[P+2]) shl 8) or Header[P+3]; end;
  function Tag(P: Integer; const S: AnsiString): Boolean;
  var I: Integer;
  begin Result:=P+Length(S)<=Count; if Result then
    for I:=1 to Length(S) do if Header[P+I-1]<>Ord(S[I]) then Exit(False); end;
  function ReadByte: Integer;
  var B: Byte;
  begin if Stream.Read(B,1)=1 then Result:=B else Result:=-1; end;
begin
  Result:=False; Width:=0; Height:=0;
  if not Assigned(Stream) then Exit;
  Saved:=Stream.Position; W:=0; H:=0;
  try
    Stream.Position:=0; FillChar(Header,SizeOf(Header),0);
    Count:=Stream.Read(Header,SizeOf(Header));
    if (Count>=24) and Tag(0,#137'PNG'#13#10#26#10) and Tag(12,'IHDR') then
    begin W:=BE32(16); H:=BE32(20); end
    else if (Count>=10) and (Tag(0,'GIF87a') or Tag(0,'GIF89a')) then
    begin W:=LE16(6); H:=LE16(8); end
    else if (Count>=26) and Tag(0,'BM') then
    begin
      if LE32(14)=12 then begin W:=LE16(18); H:=LE16(20); end
      else if (Count>=30) and (LE32(14)>=40) then
      begin W:=Integer(LE32(18)); H:=Abs(Int64(Integer(LE32(22)))); end;
    end
    else if (Count>=30) and Tag(0,'RIFF') and Tag(8,'WEBP') then
    begin
      if Tag(12,'VP8X') then
      begin W:=1+Cardinal(Header[24])+(Cardinal(Header[25]) shl 8)+(Cardinal(Header[26]) shl 16);
        H:=1+Cardinal(Header[27])+(Cardinal(Header[28]) shl 8)+(Cardinal(Header[29]) shl 16); end
      else if Tag(12,'VP8L') and (Header[20]=$2F) then
      begin W:=1+(LE32(21) and $3FFF); H:=1+((LE32(21) shr 14) and $3FFF); end
      else if Tag(12,'VP8 ') and Tag(23,#157#1#42) then
      begin W:=LE16(26) and $3FFF; H:=LE16(28) and $3FFF; end;
    end
    else if (Count>=8) and (LE16(0)=0) and (LE16(2) in [1,2]) and (LE16(4)>0) then
    begin W:=Header[6]; H:=Header[7]; if W=0 then W:=256; if H=0 then H:=256; end
    else if (Count>=2) and (Header[0]=$FF) and (Header[1]=$D8) then
    begin
      Stream.Position:=2;
      while Stream.Position<Stream.Size do
      begin
        if ReadByte<>$FF then Break;
        repeat Marker:=ReadByte; until Marker<>$FF;
        if (Marker<0) or (Marker in [$D9,$DA]) then Break;
        if (Marker=$01) or (Marker in [$D0..$D8]) then Continue;
        Count:=Stream.Read(Header,2); if Count<>2 then Break;
        SegmentSize:=(Integer(Header[0]) shl 8) or Header[1];
        SegmentEnd:=Stream.Position+SegmentSize-2;
        if (SegmentSize<2) or (SegmentEnd>Stream.Size) then Break;
        if (Marker in [$C0..$C3,$C5..$C7,$C9..$CB,$CD..$CF]) and (SegmentSize>=8) then
        begin
          if Stream.Read(Header,5)<>5 then Break;
          H:=(Integer(Header[1]) shl 8) or Header[2];
          W:=(Integer(Header[3]) shl 8) or Header[4]; Break;
        end;
        Stream.Position:=SegmentEnd;
      end;
    end;
    Result:=(W>0) and (H>0) and (W<=MaxInt) and (H<=MaxInt);
    if Result then begin Width:=W; Height:=H; end;
  finally Stream.Position:=Saved; end;
end;

function ImageFitsMemory(const Stream: TStream; const MaxBytes: Int64): Boolean;
var W,H: Integer; Saved, Next: Int64; B: Byte;
  Header: array[0..12] of Byte; Pixels, Frames: Int64;
  function SkipBlocks: Boolean;
  begin
    Result:=False;
    repeat
      if Stream.Read(B,1)<>1 then Exit;
      Next:=Stream.Position+B; if Next>Stream.Size then Exit;
      Stream.Position:=Next;
    until B=0;
    Result:=True;
  end;
begin
  Result:=False;
  if not Assigned(Stream) or (Stream.Size>16*1024*1024) or (MaxBytes<=0) then Exit;
  if not ImageDimensions(Stream,W,H) then Exit;
  Pixels:=Int64(W)*H;
  if Pixels>MaxBytes div 4 then Exit;
  // GIF may allocate every frame; also inspect local frame dimensions.
  Saved:=Stream.Position;
  try
    Stream.Position:=0;
    if (Stream.Read(Header,13)=13) and (Header[0]=Ord('G')) and
      (Header[1]=Ord('I')) and (Header[2]=Ord('F')) then
    begin
      if Header[10] and $80<>0 then Stream.Position:=13+3*(1 shl ((Header[10] and 7)+1));
      Frames:=0;
      while Stream.Position<Stream.Size do
      begin
        if Stream.Read(B,1)<>1 then Exit;
        case B of
          $3B: Break;
          $21: begin if Stream.Read(B,1)<>1 then Exit; if not SkipBlocks then Exit; end;
          $2C:
          begin
            if Stream.Read(Header,9)<>9 then Exit;
            W:=Integer(Header[4]) or (Integer(Header[5]) shl 8);
            H:=Integer(Header[6]) or (Integer(Header[7]) shl 8);
            if (W=0) or (H=0) then Exit;
            Inc(Frames,Int64(W)*H); if Frames+Pixels>MaxBytes div 4 then Exit;
            if Header[8] and $80<>0 then Stream.Position:=Stream.Position+3*(1 shl ((Header[8] and 7)+1));
            if (Stream.Position>=Stream.Size) or (Stream.Read(B,1)<>1) or not SkipBlocks then Exit;
          end;
        else Exit; end;
      end;
    end;
    Result:=True;
  finally Stream.Position:=Saved; end;
end;
end.
