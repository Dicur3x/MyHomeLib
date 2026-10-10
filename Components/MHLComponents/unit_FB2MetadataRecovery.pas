unit unit_FB2MetadataRecovery;

interface

uses System.Classes, System.SysUtils;

type
  // Replay only the bounded prefix already consumed by SAX. Never seeks or
  // changes the borrowed archive stream, and never writes the source book.
  TRecordedMetadataStream = class(TStream)
  private
    FSource: TStream;
    FCaptured: TMemoryStream;
    FLimit: Integer;
    FReadFailed: Boolean;
  public
    constructor Create(Source: TStream; Limit: Integer);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Captured: TMemoryStream read FCaptured;
    property ReadFailed: Boolean read FReadFailed;
  end;

function RecoverMetadataPrefix(Input: TRecordedMetadataStream;
  MaxBytes, MaxDepth: Integer; const IsCanceled: TFunc<Boolean>;
  out XML, Details: string; out WasCanceled: Boolean;
  AllowUnchanged: Boolean = False): Boolean;

implementation

uses System.Math, System.RegularExpressions, System.Generics.Collections;

constructor TRecordedMetadataStream.Create(Source: TStream; Limit: Integer);
begin
  inherited Create;
  FSource := Source;
  FLimit := Limit;
  FCaptured := TMemoryStream.Create;
end;

destructor TRecordedMetadataStream.Destroy;
begin
  FCaptured.Free;
  inherited;
end;

function TRecordedMetadataStream.Read(var Buffer; Count: Longint): Longint;
begin
  Count := Min(Count, FLimit - Integer(FCaptured.Size));
  if Count <= 0 then Exit(0);
  try
    Result := FSource.Read(Buffer, Count);
    if Result > 0 then FCaptured.WriteBuffer(Buffer, Result);
  except
    FReadFailed := True;
    raise;
  end;
end;

function TRecordedMetadataStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EStreamError.Create('Metadata input is read-only');
end;

function TRecordedMetadataStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  raise EStreamError.Create('Metadata input is not seekable');
end;

function LocalName(const Name: string): string;
var I: Integer;
begin
  I := Pos(':', Name);
  if I = 0 then Result := Name else Result := Copy(Name, I + 1, MaxInt);
end;

function FormattingTag(const Name: string): Boolean;
begin
  Result := (Name = 'p') or (Name = 'strong') or (Name = 'emphasis') or
    (Name = 'style') or (Name = 'strikethrough') or (Name = 'sub') or
    (Name = 'sup') or (Name = 'code') or (Name = 'a');
end;

function RepairText(const Text: string; MaxDepth: Integer;
  const IsCanceled: TFunc<Boolean>; out XML, Details: string;
  out PrefixEnd: Integer; out NeedMore, WasCanceled: Boolean; AllowUnchanged: Boolean): Boolean;
var
  Stack: TList<string>;
  Notes: TStringList;
  Output: TStringBuilder;
  I, J, K, Found, EndAt: Integer;
  Token, Name, Plain, FixedPlain: string;
  Quote: Char;
  Closing, EmptyTag, DescriptionEnded: Boolean;
  Match: TMatch;

  procedure Note(const Value: string);
  begin
    if Notes.IndexOf(Value) < 0 then Notes.Add(Value);
  end;

  function EscapeAmpersands(const Value: string): string;
  begin
    Result := TRegEx.Replace(Value,
      '&(amp|lt|gt|apos|quot)(?=[\s"''<>]|$)', '&$1;');
    Result := TRegEx.Replace(Result,
      '&(?!amp;|lt;|gt;|apos;|quot;|#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z_][\w:.-]*;)', '&amp;');
    if Result <> Value then Note('экранирование & / завершение известной XML-сущности');
  end;

  procedure CloseFormatting;
  begin
    Output.Append('</' + Stack.Last + '>');
    Stack.Delete(Stack.Count - 1);
    Note('закрытие незавершённого тега оформления');
  end;

begin
  Result := False;
  XML := ''; Details := ''; PrefixEnd := 0;
  NeedMore := False; WasCanceled := False;
  Stack := TList<string>.Create;
  Notes := TStringList.Create;
  Output := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(Text) do
    begin
      if Assigned(IsCanceled) and IsCanceled() then
      begin WasCanceled := True; Exit; end;
      if Text[I] <> '<' then
      begin
        J := I;
        while (J <= Length(Text)) and (Text[J] <> '<') do Inc(J);
        Plain := Copy(Text, I, J - I);
        // Only the exact closing marker at the description boundary, followed
        // by a real body, can become markup. Literal examples in annotations,
        // comments and CDATA are never promoted to metadata tags.
        if (Stack.Count = 2) and (LocalName(Stack.Last) = 'description') and
          (Trim(Plain) = '&lt;/description&gt;') and
          TRegEx.IsMatch(Copy(Text, J, 120), '^<(?:[\w.-]+:)?body(?:\s|>)') then
        begin
          Output.Append('</' + Stack.Last + '>');
          PrefixEnd := J - 1;
          Note('восстановление экранированного закрытия description');
          if AllowUnchanged then Output.Append('</' + Stack[0] + '>');
          XML := Output.ToString;
          Details := Notes.Text.Trim;
          Exit(True);
        end;
        Output.Append(EscapeAmpersands(Plain));
        I := J;
        Continue;
      end;
      if Copy(Text, I, 4) = '<!--' then
      begin
        EndAt := Pos('-->', Text, I + 4);
        if EndAt = 0 then begin NeedMore := True; Exit; end;
        Output.Append(Copy(Text, I, EndAt + 3 - I));
        I := EndAt + 3; Continue;
      end;
      if Copy(Text, I, 9) = '<![CDATA[' then
      begin
        EndAt := Pos(']]>', Text, I + 9);
        if EndAt = 0 then begin NeedMore := True; Exit; end;
        Output.Append(Copy(Text, I, EndAt + 3 - I));
        I := EndAt + 3; Continue;
      end;
      if Copy(Text, I, 2) = '<!' then Exit; // No DTD or entity declarations.
      if Copy(Text, I, 2) = '<?' then
      begin
        EndAt := Pos('?>', Text, I + 2);
        if EndAt = 0 then begin NeedMore := True; Exit; end;
        Token := Copy(Text, I, EndAt + 2 - I);
        if Copy(Token, 1, 6) = '<?xml ' then
        begin
          FixedPlain := TRegEx.Replace(Token, 'version\s*=\s*(["''])1\.01\1', 'version="1.0"');
          if FixedPlain <> Token then Note('декларация XML version="1.01" → "1.0"');
          Token := TRegEx.Replace(FixedPlain, 'encoding\s*=\s*(["''])[^"'']+\1', 'encoding="UTF-8"');
        end;
        Output.Append(Token);
        I := EndAt + 2; Continue;
      end;
      Quote := #0;
      J := I + 1;
      while J <= Length(Text) do
      begin
        if Quote <> #0 then
        begin
          if Text[J] = Quote then Quote := #0;
        end
        else if CharInSet(Text[J], ['"', '''']) then Quote := Text[J]
        else if CharInSet(Text[J], ['<', '>']) then Break;
        Inc(J);
      end;
      if J > Length(Text) then begin NeedMore := True; Exit; end;
      Token := Copy(Text, I, J - I);
      if Text[J] = '<' then
      begin
        // Only unambiguous non-series fields: closing annotation/nickname,
        // empty image/line, or a glued ISO language before its exact closing.
        // Series and metadata container tags are never guessed.
        Match := TRegEx.Match(Token, '^<((?:[\w.-]+:)?lang)([a-z]{2,3})$');
        if Match.Success and (Copy(Text, J, Length('</' + Match.Groups[1].Value + '>')) =
          '</' + Match.Groups[1].Value + '>') then
        begin
          Token := '<' + Match.Groups[1].Value + '>' + Match.Groups[2].Value;
          Note('восстановление > у lang перед кодом языка');
        end
        else
        begin
          if not TRegEx.IsMatch(Token, '^</(?:[\w.-]+:)?(?:annotation|nickname)\s*$') and
            not TRegEx.IsMatch(Token, '^<(?:[\w.-]+:)?(?:image\s+[^<>]*|empty-line\s*)/\s*$') then Exit;
          Token := TrimRight(Token) + '>';
          Note('восстановление > у annotation/nickname/image/empty-line');
        end;
      end
      else
      begin Token := Token + '>'; Inc(J); end;
      Closing := Copy(Token, 1, 2) = '</';
      if Closing then K := 3 else K := 2;
      Found := K;
      while (K <= Length(Token)) and not CharInSet(Token[K], [#9, #10, #13, ' ', '/', '>']) do Inc(K);
      Name := Copy(Token, Found, K - Found);
      if Name = '' then Exit;
      EmptyTag := TRegEx.IsMatch(Token, '/\s*>$');
      DescriptionEnded := False;
      if Closing then
      begin
        Found := Stack.Count - 1;
        while (Found >= 0) and (Stack[Found] <> Name) do Dec(Found);
        if Found < 0 then Exit;
        while Stack.Count - 1 > Found do
        begin
          if not FormattingTag(LocalName(Stack.Last)) then Exit;
          CloseFormatting;
        end;
        DescriptionEnded := (Stack.Count = 2) and (LocalName(Name) = 'description');
        Stack.Delete(Stack.Count - 1);
      end
      else if not EmptyTag then
      begin
        if Stack.Count >= MaxDepth then Exit;
        Stack.Add(Name);
      end;
      if (Stack.Count = 1) and not Closing and (LocalName(Name) = 'FictionBook') and
        (Pos('l:href', Text) > 0) and not TRegEx.IsMatch(Text, '\bxmlns:l\s*=') then
      begin
        Insert(' xmlns:l="http://www.w3.org/1999/xlink"', Token, Length(Token));
        Note('объявление стандартного префикса l для ссылок на изображения');
      end;
      Output.Append(EscapeAmpersands(Token));
      I := J;
      if DescriptionEnded then
      begin
        PrefixEnd := I - 1;
        if (Notes.Count = 0) and not AllowUnchanged then Exit;
        XML := Output.ToString;
        if AllowUnchanged and (Stack.Count = 1) then XML := XML + '</' + Stack[0] + '>';
        Details := Notes.Text.Trim;
        Exit(True);
      end;
    end;
    NeedMore := True;
  finally
    Output.Free; Notes.Free; Stack.Free;
  end;
end;

function RecoverMetadataPrefix(Input: TRecordedMetadataStream;
  MaxBytes, MaxDepth: Integer; const IsCanceled: TFunc<Boolean>;
  out XML, Details: string; out WasCanceled: Boolean; AllowUnchanged: Boolean): Boolean;
var
  Bytes, RoundTrip: TBytes;
  Buffer: array[0..8191] of Byte;
  Encoding: TEncoding;
  Text, Header, Name: string;
  Match: TMatch;
  Offset, Count, TargetSize, PrefixEnd, I: Integer;
  NeedMore, OwnEncoding: Boolean;
begin
  Result := False; XML := ''; Details := ''; WasCanceled := False;
  if Input.ReadFailed or (Input.Captured.Size = 0) or
    (Input.Captured.Size >= MaxBytes) then Exit;
  Encoding := TEncoding.UTF8; OwnEncoding := False; Offset := 0;
  SetLength(Bytes, Input.Captured.Size);
  Move(Input.Captured.Memory^, Bytes[0], Length(Bytes));
  if (Length(Bytes) >= 3) and (Bytes[0]=$EF) and (Bytes[1]=$BB) and (Bytes[2]=$BF) then Offset:=3
  else if (Length(Bytes) >= 2) and (Bytes[0]=$FF) and (Bytes[1]=$FE) then
  begin Encoding:=TEncoding.Unicode; Offset:=2; end
  else if (Length(Bytes) >= 2) and (Bytes[0]=$FE) and (Bytes[1]=$FF) then
  begin Encoding:=TEncoding.BigEndianUnicode; Offset:=2; end
  else
  begin
    Header := TEncoding.ANSI.GetString(Bytes, 0, Min(Length(Bytes),1024));
    Match := TRegEx.Match(Header, '^<\?xml\s+[^?]*\bencoding\s*=\s*(["''])([^"'']+)\1');
    if Match.Success then
    begin
      Name := Match.Groups[2].Value;
      if SameText(Name, 'UTF8') then Name := 'UTF-8';
      try Encoding := TEncoding.GetEncoding(Name); OwnEncoding := True;
      except
        on E: EEncodingError do Exit;
        on E: EArgumentException do Exit;
      end;
    end;
  end;
  try
    repeat
      if Assigned(IsCanceled) and IsCanceled() then begin WasCanceled := True; Exit; end;
      SetLength(Bytes, Input.Captured.Size);
      Move(Input.Captured.Memory^, Bytes[0], Length(Bytes));
      try
        Text := Encoding.GetString(Bytes, Offset, Length(Bytes)-Offset);
      except on E: EEncodingError do Exit; end;
      if RepairText(Text, MaxDepth, IsCanceled, XML, Details,
        PrefixEnd, NeedMore, WasCanceled, AllowUnchanged) then
      begin
        // A decoder replacement must never silently change a series name.
        // Validate only the metadata prefix; damaged body bytes stay irrelevant.
        Text := Copy(Text, 1, PrefixEnd);
        for I := 1 to Length(Text) do
          if (Ord(Text[I]) >= $D800) and (Ord(Text[I]) <= $DFFF) then
          begin
            if ((Ord(Text[I]) <= $DBFF) and ((I = Length(Text)) or
              (Ord(Text[I+1]) < $DC00) or (Ord(Text[I+1]) > $DFFF))) or
              ((Ord(Text[I]) >= $DC00) and ((I = 1) or
              (Ord(Text[I-1]) < $D800) or (Ord(Text[I-1]) > $DBFF))) then Exit;
          end;
        RoundTrip := Encoding.GetBytes(Text);
        if (Length(RoundTrip) > Length(Bytes)-Offset) or
          ((Length(RoundTrip)>0) and not CompareMem(@RoundTrip[0], @Bytes[Offset], Length(RoundTrip))) then Exit;
        Exit(True);
      end;
      if WasCanceled or not NeedMore or (Input.Captured.Size >= MaxBytes) then Exit;
      // Grow geometrically, and fill a chunk even for fragmented sources.
      // Avoid reparsing the whole prefix after every single byte / 8 KiB.
      TargetSize := Min(MaxBytes, Max(SizeOf(Buffer), Integer(Input.Captured.Size) * 2));
      repeat
        if Assigned(IsCanceled) and IsCanceled() then
        begin WasCanceled := True; Exit; end;
        Count := Input.Read(Buffer, Min(SizeOf(Buffer), TargetSize - Integer(Input.Captured.Size)));
      until (Count = 0) or (Input.Captured.Size >= TargetSize);
      // Parse a final partial chunk once before reporting an incomplete prefix.
      if (Count = 0) and (Input.Captured.Size = Length(Bytes)) then Exit;
    until False;
  finally
    if OwnEncoding then Encoding.Free;
  end;
end;

end.
