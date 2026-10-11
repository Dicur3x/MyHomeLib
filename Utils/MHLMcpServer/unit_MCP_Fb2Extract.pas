unit unit_MCP_Fb2Extract;

interface

uses
  System.Classes,
  System.SysUtils;

type
  TFb2ExtractErrorKind = (eekExtractionFailed, eekNoText);

  EFb2ExtractError = class(Exception)
  private
    FKind: TFb2ExtractErrorKind;
  public
    constructor Create(const AKind: TFb2ExtractErrorKind; const AMessage: string); reintroduce;
    property Kind: TFb2ExtractErrorKind read FKind;
  end;

  TFb2Section = record
    Title: string;
    Level: Integer;
    Offset: Integer;
    Length: Integer;
  end;

  TFb2Sections = array of TFb2Section;

  TFb2Extraction = record
    Text: string;
    Sections: TFb2Sections;
    Structured: Boolean;
  end;

function ExtractFb2(Stream: TStream): TFb2Extraction;

implementation

uses
  System.Variants,
  Xml.XMLIntf,
  Xml.XMLDoc,
  Xml.xmldom;

const
  CP_KOI8R = 20866;

type
  TFb2Walker = class
  private
    FText: TStringBuilder;
    FSections: TFb2Sections;
    procedure WalkNode(const Node: IXMLNode; Level: Integer);
    function NodeText(const Node: IXMLNode): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Walk(const Root: IXMLNode);
    property Text: TStringBuilder read FText;
    property Sections: TFb2Sections read FSections;
  end;

constructor TFb2Walker.Create;
begin
  inherited Create;
  FText := TStringBuilder.Create;
end;

destructor TFb2Walker.Destroy;
begin
  FText.Free;
  inherited Destroy;
end;

function TFb2Walker.NodeText(const Node: IXMLNode): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    if Node.IsTextElement then
      SB.Append(Node.Text)
    else
      for I := 0 to Node.ChildNodes.Count - 1 do
      begin
        if Node.ChildNodes[I].NodeType = ntText then
          SB.Append(Node.ChildNodes[I].Text)
        else
          SB.Append(NodeText(Node.ChildNodes[I]));
        SB.Append(' ');
      end;
    Result := SB.ToString.Trim;
  finally
    SB.Free;
  end;
end;

procedure TFb2Walker.WalkNode(const Node: IXMLNode; Level: Integer);
var
  I, SectionIndex, StartOffset: Integer;
  Name, Title: string;
begin
  if Node.NodeType = ntText then
  begin
    FText.Append(Node.Text);
    Exit;
  end;

  Name := LowerCase(Node.LocalName);

  if Name = 'description' then
    Exit;

  if Name = 'section' then
  begin
    StartOffset := FText.Length;
    SectionIndex := System.Length(FSections);
    SetLength(FSections, SectionIndex + 1);
    FSections[SectionIndex].Level := Level;
    FSections[SectionIndex].Offset := StartOffset;
    FSections[SectionIndex].Title := '';

    for I := 0 to Node.ChildNodes.Count - 1 do
    begin
      if LowerCase(Node.ChildNodes[I].LocalName) = 'title' then
      begin
        Title := NodeText(Node.ChildNodes[I]);
        if FSections[SectionIndex].Title = '' then
          FSections[SectionIndex].Title := Title;
        FText.Append(Title);
        FText.AppendLine;
        FText.AppendLine;
        Continue;
      end;
      WalkNode(Node.ChildNodes[I], Level + 1);
    end;

    FSections[SectionIndex].Length := FText.Length - StartOffset;
    Exit;
  end;

  if (Name = 'p') or (Name = 'v') or (Name = 'subtitle') then
  begin
    FText.Append(NodeText(Node));
    FText.AppendLine;
    if Name = 'subtitle' then
      FText.AppendLine;
    Exit;
  end;

  if Node.HasChildNodes then
    for I := 0 to Node.ChildNodes.Count - 1 do
      WalkNode(Node.ChildNodes[I], Level);
end;

procedure TFb2Walker.Walk(const Root: IXMLNode);
var
  I: Integer;
begin
  for I := 0 to Root.ChildNodes.Count - 1 do
    if LowerCase(Root.ChildNodes[I].LocalName) = 'body' then
      WalkNode(Root.ChildNodes[I], 0);
end;


function SniffDeclaredEncoding(const Bytes: TBytes): string;
const
  Needle: array[0..7] of Byte = (
    Ord('e'), Ord('n'), Ord('c'), Ord('o'), Ord('d'), Ord('i'), Ord('n'), Ord('g'));

  function LowerAsciiByte(B: Byte): Byte; inline;
  begin
    if (B >= Ord('A')) and (B <= Ord('Z')) then
      Result := B + 32
    else
      Result := B;
  end;

  function MatchesNeedle(Pos, N: Integer): Boolean;
  var
    K: Integer;
  begin
    Result := Pos + System.Length(Needle) <= N;
    if not Result then
      Exit;
    for K := 0 to High(Needle) do
      if LowerAsciiByte(Bytes[Pos + K]) <> Needle[K] then
        Exit(False);
  end;

var
  N, I, J, K: Integer;
  Quote: Byte;
  NameBytes: TBytes;
begin
  Result := '';
  N := System.Length(Bytes);
  if N > 512 then
    N := 512;

  I := 0;
  while I < N do
  begin
    if MatchesNeedle(I, N) then
    begin
      J := I + System.Length(Needle);
      while (J < N) and (Bytes[J] in [Ord(' '), 9, 10, 13]) do
        Inc(J);
      if (J < N) and (Bytes[J] = Ord('=')) then
      begin
        Inc(J);
        while (J < N) and (Bytes[J] in [Ord(' '), 9, 10, 13]) do
          Inc(J);
        if (J < N) and ((Bytes[J] = Ord('"')) or (Bytes[J] = Ord(''''))) then
        begin
          Quote := Bytes[J];
          Inc(J);
          SetLength(NameBytes, 0);
          while (J < N) and (Bytes[J] <> Quote) do
          begin
            SetLength(NameBytes, System.Length(NameBytes) + 1);
            NameBytes[High(NameBytes)] := Bytes[J];
            Inc(J);
          end;
          SetLength(Result, System.Length(NameBytes));
          for K := 0 to High(NameBytes) do
            Result[K + 1] := Chr(NameBytes[K]);
          Result := Result.ToLower;
          Exit;
        end;
      end;
    end;
    Inc(I);
  end;
end;

function CodePageForDeclaredEncoding(const Name: string): Integer;
begin
  if (Name = 'windows-1251') or (Name = 'cp1251') or (Name = 'x-cp1251') then
    Result := 1251
  else if (Name = 'koi8-r') or (Name = 'koi8r') then
    Result := CP_KOI8R
  else if (Name = 'utf-8') or (Name = 'utf8') then
    Result := CP_UTF8
  else
    Result := 0;
end;

function DecodeFb2Bytes(const Bytes: TBytes): string;
var
  BomEncoding, GuessEncoding: TEncoding;
  Preamble, CodePage: Integer;
  Declared: string;
  OwnsGuess: Boolean;
begin
  BomEncoding := nil;
  Preamble := TEncoding.GetBufferEncoding(Bytes, BomEncoding, nil);
  if Assigned(BomEncoding) then
  begin
    try
      Exit(BomEncoding.GetString(Bytes, Preamble, System.Length(Bytes) - Preamble));
    except
      on E: EEncodingError do
        ;
    end;
  end;

  Declared := SniffDeclaredEncoding(Bytes);
  CodePage := CodePageForDeclaredEncoding(Declared);

  GuessEncoding := nil;
  OwnsGuess := False;
  try
    if (CodePage = CP_UTF8) and TEncoding.UTF8.IsBufferValid(Bytes) then
      GuessEncoding := TEncoding.UTF8
    else if (CodePage <> 0) and (CodePage <> CP_UTF8) then
    begin
      GuessEncoding := TEncoding.GetEncoding(CodePage);
      OwnsGuess := True;
    end
    else if TEncoding.UTF8.IsBufferValid(Bytes) then
      GuessEncoding := TEncoding.UTF8
    else
    begin
      GuessEncoding := TEncoding.GetEncoding(1251);
      OwnsGuess := True;
    end;

    Result := GuessEncoding.GetString(Bytes);
  finally
    if OwnsGuess then
      GuessEncoding.Free;
  end;
end;

function DecodeEntities(const S: string): string;
var
  SB: TStringBuilder;
  I, J, SemiPos, Code: Integer;
  Entity: string;
  Handled: Boolean;
begin
  SB := TStringBuilder.Create;
  try
    I := 1;
    while I <= System.Length(S) do
    begin
      if S[I] = '&' then
      begin
        SemiPos := 0;
        J := I + 1;
        while (J <= System.Length(S)) and (J <= I + 12) do
        begin
          if S[J] = ';' then
          begin
            SemiPos := J;
            Break;
          end;
          Inc(J);
        end;

        if SemiPos > 0 then
        begin
          Entity := Copy(S, I + 1, SemiPos - I - 1);
          Handled := True;
          if Entity = 'amp' then
            SB.Append('&')
          else if Entity = 'lt' then
            SB.Append('<')
          else if Entity = 'gt' then
            SB.Append('>')
          else if Entity = 'quot' then
            SB.Append('"')
          else if Entity = 'apos' then
            SB.Append('''')
          else if (System.Length(Entity) > 1) and (Entity[1] = '#') then
          begin
            try
              if (System.Length(Entity) > 2) and CharInSet(Entity[2], ['x', 'X']) then
                Code := StrToInt('$' + Copy(Entity, 3, MaxInt))
              else
                Code := StrToInt(Copy(Entity, 2, MaxInt));
            except
              Code := -1;
            end;
            if (Code >= 0) and (Code <= $FFFF) then
              SB.Append(Char(Code))
            else
              Handled := False;
          end
          else
            Handled := False;

          if Handled then
          begin
            I := SemiPos + 1;
            Continue;
          end;
        end;
      end;

      SB.Append(S[I]);
      Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TagBoundaryOk(const Chunk: string; NameLen: Integer): Boolean;
begin
  Result := (System.Length(Chunk) <= NameLen) or
    CharInSet(Chunk[NameLen + 1], ['>', ' ', #9, #10, #13, '/']);
end;

function StartsWithOpenTag(const Chunk, Name: string): Boolean;
var
  Prefix: string;
begin
  Prefix := '<' + Name;
  Result := Chunk.StartsWith(Prefix) and TagBoundaryOk(Chunk, System.Length(Prefix));
end;

function StartsWithCloseTag(const Chunk, Name: string): Boolean;
var
  Prefix: string;
begin
  Prefix := '</' + Name;
  Result := Chunk.StartsWith(Prefix) and TagBoundaryOk(Chunk, System.Length(Prefix));
end;

function StripTags(Stream: TStream): string;
var
  Bytes: TBytes;
  Raw, Chunk: string;
  I, Depth: Integer;
  SB: TStringBuilder;
  Suppress: Boolean;
begin
  Stream.Position := 0;
  SetLength(Bytes, Stream.Size);
  if System.Length(Bytes) > 0 then
    Stream.ReadBuffer(Bytes[0], System.Length(Bytes));

  Raw := DecodeFb2Bytes(Bytes);

  SB := TStringBuilder.Create;
  try
    Depth := 0;
    Suppress := False;
    I := 1;
    while I <= System.Length(Raw) do
    begin
      if Raw[I] = '<' then
      begin
        Chunk := Copy(Raw, I, 16).ToLower;
        if StartsWithOpenTag(Chunk, 'description') or
           StartsWithOpenTag(Chunk, 'binary') or
           StartsWithOpenTag(Chunk, 'stylesheet') then
          Suppress := True
        else if StartsWithCloseTag(Chunk, 'description') or
                StartsWithCloseTag(Chunk, 'binary') or
                StartsWithCloseTag(Chunk, 'stylesheet') then
          Suppress := False;
        Depth := 1;
      end
      else if Raw[I] = '>' then
        Depth := 0
      else if (Depth = 0) and (not Suppress) then
        SB.Append(Raw[I]);
      Inc(I);
    end;
    Result := DecodeEntities(SB.ToString);
  finally
    SB.Free;
  end;
end;

constructor EFb2ExtractError.Create(const AKind: TFb2ExtractErrorKind; const AMessage: string);
begin
  inherited Create(AMessage);
  FKind := AKind;
end;

function ExtractFb2(Stream: TStream): TFb2Extraction;
var
  Doc: IXMLDocument;
  Walker: TFb2Walker;
begin
  Result.Structured := False;
  SetLength(Result.Sections, 0);

  if not Assigned(Stream) then
    raise EFb2ExtractError.Create(eekExtractionFailed,
      'FB2 extraction failed: no stream provided (nil)');

  try
    Doc := TXMLDocument.Create(nil);
    Doc.ParseOptions := [poPreserveWhiteSpace];
    Stream.Position := 0;
    Doc.LoadFromStream(Stream);
    Doc.Active := True;

    Walker := TFb2Walker.Create;
    try
      Walker.Walk(Doc.DocumentElement);
      Result.Text := Walker.Text.ToString;
      Result.Sections := Walker.Sections;
      Result.Structured := True;
    finally
      Walker.Free;
    end;
  except
    on E: Exception do
    begin
      try
        Result.Text := StripTags(Stream);
        Result.Structured := False;
        SetLength(Result.Sections, 0);
      except
        on Inner: Exception do
          raise EFb2ExtractError.Create(eekExtractionFailed,
            Format('FB2 extraction failed: %s / %s', [E.Message, Inner.Message]));
      end;
    end;
  end;

  if Result.Text.Trim = '' then
  begin
    if Result.Structured then
      raise EFb2ExtractError.Create(eekNoText,
        'FB2 book has no extractable text (likely picture-only or an empty body)')
    else
      raise EFb2ExtractError.Create(eekExtractionFailed,
        'FB2 extraction failed: no text could be recovered from this file');
  end;
end;

end.
