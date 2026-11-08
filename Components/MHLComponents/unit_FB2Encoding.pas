unit unit_FB2Encoding;

interface

uses System.Classes, System.SysUtils, Winapi.MSXML;

const FB2_ENCODING_PROBE_SIZE = 8192;

// Correct an ASCII XML declaration in the caller's working buffer.
// PrefixOnly is for metadata readers that do not load the rest of the book.
function RepairFB2UTF8Declaration(var Bytes: TBytes; PrefixOnly: Boolean = False): Boolean;

// Retry only local, unambiguous syntax errors reported by a strict parser.
function TryRepairFB2Markup(const Document: IXMLDOMDocument3; var XML: string;
  out ClosedTail: Boolean): Boolean;
function FB2MarkupFailure(const Error: IXMLDOMParseError; const XML: string): string;
function FB2BinaryFailure(const Bytes: TBytes): string;
function RepairedFB2Stream(const Source: TStream; out Failure: string): TStream;

implementation

uses System.Math, System.RegularExpressions, System.Win.ComObj, Winapi.Windows;

const
  MaxFB2RepairBytes = 16*1024*1024;
  XMLUnexpectedEnd = $C00CE553;
  XMLUnexpectedSpace = $C00CE513;
  XMLMismatchedTag = $C00CE56D;
  XMLUndeclaredPrefix = $C00CE01D;
  FB2Namespace = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  ZeroedFB2 = 'FB2 повреждён: внутри файла найдены нулевые байты.';

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

function CloseFB2Tail(const Document: IXMLDOMDocument3; var XML: string): Boolean;
const
  // The strict parser found EOF. Ignore comments, CDATA and quoted attributes
  // when collecting open tag names, then validate the complete result.
  TokenPattern = '<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|' +
    '</?([A-Za-z_][\w.:-]*)(?=[\s/>])(?:[^"''<>]++|"[^"]*"|''[^'']*'')*>';
var
  Stack: array[0..128] of string;
  Depth, LastEnd: Integer;
  Closing, Candidate, Name: string;
  Match: TMatch;
  Bodies: IXMLDOMNodeList;
  HasText: Boolean;
begin
  Result := False;
  Depth := 0;
  LastEnd := 0;
  Match := TRegEx.Match(XML,TokenPattern);
  while Match.Success do
  begin
    Name := '';
    if Match.Groups.Count>1 then Name := Match.Groups[1].Value;
    LastEnd := 0;
    if Name<>'' then
      if Match.Value.StartsWith('</') then
      begin
        if (Depth=0) or (Stack[Depth-1]<>Name) then Exit;
        Dec(Depth);
        LastEnd := Match.Index+Match.Length;
      end
      else if not Match.Value.EndsWith('/>') then
      begin
        if Depth=Length(Stack) then Exit;
        Stack[Depth] := Name;
        Inc(Depth);
      end;
    Match := Match.NextMatch;
  end;
  if (Depth=0) or (LastEnd=0) or (Trim(Copy(XML,LastEnd,MaxInt))<>'') then Exit;
  for var I := 0 to Depth-1 do
  begin
    Name := Copy(Stack[I],Pos(':',Stack[I])+1,MaxInt);
    case I of
      0: if Name<>'FictionBook' then Exit;
      1: if Name<>'body' then Exit;
    else
      if Name<>'section' then Exit;
    end;
  end;
  Closing := '';
  for var I := Depth-1 downto 0 do Closing := Closing+'</'+Stack[I]+'>';
  Candidate := XML+Closing;
  if not Document.loadXML(Candidate) then Exit;
  if (Document.documentElement.baseName<>'FictionBook') or
    (Document.documentElement.namespaceURI<>FB2Namespace) then Exit;
  Bodies := Document.documentElement.selectNodes(
    '*[local-name()="body" and namespace-uri()="'+FB2Namespace+'"]');
  HasText := False;
  for var I := 0 to Bodies.length-1 do
    if Trim(Bodies.item[I].text)<>'' then
    begin
      HasText := True;
      Break;
    end;
  if not HasText then Exit;
  XML := Candidate;
  Result := True;
end;

function TryRepairFB2Markup(const Document: IXMLDOMDocument3; var XML: string;
  out ClosedTail: Boolean): Boolean;
begin
  ClosedTail := False;
  Result := False;
  if (Length(XML)>MaxFB2RepairBytes) or (Pos(#0,XML)>0) then Exit;
  for var Attempt := 1 to 4 do
  begin
    if Cardinal(Document.parseError.errorCode)=XMLUnexpectedEnd then
    begin
      ClosedTail := CloseFB2Tail(Document,XML);
      Exit(ClosedTail);
    end;
    // MSXML reports a zero-based UTF-16 position after loadXML.
    var At := Document.parseError.filepos + 1;
    if (At<2) or (At>Length(XML)) then Exit;
    case Cardinal(Document.parseError.errorCode) of
      XMLUnexpectedSpace:
        begin
          if (XML[At-1]<>'&') or not CharInSet(XML[At],[' ',#9,#10,#13]) then Exit;
          Insert('amp;',XML,At);
        end;
      XMLMismatchedTag:
        begin
          if (At<3) or (Copy(XML,At-2,8)<>'</title>') then Exit;
          Delete(XML,At-2,8);
        end;
      XMLUndeclaredPrefix:
        begin
          var TagStart := At-1;
          while (TagStart>Max(1,At-2048)) and (XML[TagStart]<>'<') do Dec(TagStart);
          if not TRegEx.IsMatch(Copy(XML,TagStart,At-TagStart+1),
            '^<[^<>]*\s+xlink:(?:href|type)\s*=') then Exit;
          var Root := TRegEx.Match(Copy(XML,1,8192),
            '^\s*(?:<\?xml[^?]*\?>\s*)?<FictionBook(?=[\s>])');
          if not Root.Success then Exit;
          Insert(' xmlns:xlink="http://www.w3.org/1999/xlink"',XML,Root.Index+Root.Length);
        end;
    else
      Exit;
    end;
    if Document.loadXML(XML) then
      Exit((Document.documentElement.baseName='FictionBook') and
        (Document.documentElement.namespaceURI=FB2Namespace));
  end;
end;

function FB2MarkupFailure(const Error: IXMLDOMParseError; const XML: string): string;
begin
  if Pos(#0,XML)>0 then
    Exit(ZeroedFB2);
  if Cardinal(Error.errorCode)=XMLUnexpectedEnd then
    Exit('FB2 обрывается до конца документа. '+Trim(Error.reason));
  Result := '';
end;

function FB2BinaryFailure(const Bytes: TBytes): string;
begin
  Result := '';
  if Length(Bytes)<4 then Exit;
  // Zero bytes are part of the encoding of UTF-16/32 XML. Inspect those
  // documents after decoding instead.
  if (Bytes[0]=0) or (Bytes[1]=0) or (Bytes[2]=0) or (Bytes[3]=0) or
    ((Bytes[0]=$FF) and (Bytes[1]=$FE)) or ((Bytes[0]=$FE) and (Bytes[1]=$FF)) then Exit;
  for var Value in Bytes do if Value=0 then Exit(ZeroedFB2);
end;

function RepairedFB2Stream(const Source: TStream; out Failure: string): TStream;
var
  Bytes, RoundTrip: TBytes;
  Enc: TEncoding;
  Offset: Integer;
  XML: string;
  Declaration: TMatch;
  Document: IXMLDOMDocument3;
  ClosedTail: Boolean;
begin
  Result := nil;
  Failure := '';
  if (Source.Size=0) or (Source.Size>MaxFB2RepairBytes) then Exit;
  Source.Position := 0;
  SetLength(Bytes,Source.Size);
  Source.ReadBuffer(Bytes,Length(Bytes));
  Failure := FB2BinaryFailure(Bytes);
  if Failure<>'' then Exit;
  Enc := nil;
  Offset := TEncoding.GetBufferEncoding(Bytes,Enc,TEncoding.UTF8);
  if Offset=0 then
  begin
    Declaration := TRegEx.Match(TEncoding.ASCII.GetString(Bytes,0,Min(512,Length(Bytes))),
      '^<\?xml\s+[^?]*?\bencoding\s*=\s*["'']([^"'']+)');
    if Declaration.Success then
      try Enc := TEncoding.GetEncoding(Declaration.Groups[1].Value); except Exit; end;
  end;
  try
    if Offset>=Length(Bytes) then Exit;
    XML := Enc.GetString(Bytes,Offset,Length(Bytes)-Offset);
    RoundTrip := Enc.GetBytes(XML);
    if (Length(RoundTrip)<>Length(Bytes)-Offset) or
      not CompareMem(Pointer(RoundTrip),@Bytes[Offset],Length(RoundTrip)) then Exit;
    Document := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
    Document.async := False;
    Document.resolveExternals := False;
    Document.validateOnParse := False;
    Document.preserveWhiteSpace := True;
    Document.setProperty('ProhibitDTD',True);
    if Document.loadXML(XML) then Exit;
    Failure := FB2MarkupFailure(Document.parseError,XML);
    if not TryRepairFB2Markup(Document,XML,ClosedTail) then Exit;
    var Repaired := TMemoryStream.Create;
    try
      if Offset>0 then Repaired.WriteBuffer(Bytes[0],Offset);
      Bytes := Enc.GetBytes(XML);
      Repaired.WriteBuffer(Bytes[0],Length(Bytes));
      Repaired.Position := 0;
      Result := Repaired;
    except
      Repaired.Free;
      raise;
    end;
  finally
    if not TEncoding.IsStandardEncoding(Enc) then Enc.Free;
  end;
end;

end.
