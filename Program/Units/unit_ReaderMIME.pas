unit unit_ReaderMIME;

interface

uses System.SysUtils, System.Generics.Collections;

function DecodeReaderHTML(const Bytes: TBytes; const Charset: string = ''): string;
function ReadReaderMHTML(const Bytes: TBytes; Resources: TDictionary<string,TBytes>;
  const Canceled: TFunc<Boolean>): string;

implementation

uses System.Classes, System.Math, System.RegularExpressions, System.NetEncoding, Winapi.Windows;

function DecodeReaderHTML(const Bytes: TBytes; const Charset: string): string;
var Name, Prefix: string; Match: TMatch; Encoding: TEncoding;
begin
  if Length(Bytes)=0 then Exit('');
  Name:=Trim(Charset);
  if Name='' then
  begin
    Prefix:=TEncoding.ASCII.GetString(Bytes,0,Min(Length(Bytes),8192));
    Match:=TRegEx.Match(Prefix,'charset\s*=\s*["'']?([^\s;"''/>]+)',[roIgnoreCase]);
    if Match.Success then Name:=Match.Groups[1].Value;
  end;
  if Name<>'' then
  begin
    Encoding:=TEncoding.GetEncoding(Name);
    try Exit(Encoding.GetString(Bytes)); finally Encoding.Free; end;
  end;
  if (Length(Bytes)>=2) and (Bytes[0]=$FF) and (Bytes[1]=$FE) then Exit(TEncoding.Unicode.GetString(Bytes,2,Length(Bytes)-2));
  if (Length(Bytes)>=2) and (Bytes[0]=$FE) and (Bytes[1]=$FF) then Exit(TEncoding.BigEndianUnicode.GetString(Bytes,2,Length(Bytes)-2));
  if MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Bytes[0]),Length(Bytes),nil,0)>0 then
    Exit(TEncoding.UTF8.GetString(Bytes).TrimLeft([#$FEFF]));
  Encoding:=TEncoding.GetEncoding(1251);
  try Result:=Encoding.GetString(Bytes); finally Encoding.Free; end;
end;

function ReadReaderMHTML(const Bytes: TBytes; Resources: TDictionary<string,TBytes>;
  const Canceled: TFunc<Boolean>): string;
var Raw, HTML, Plain: string; Encoding: TEncoding; PartCount: Integer; Total: Int64;
  function Param(const Value, Name: string): string;
  var Match: TMatch;
  begin
    Match:=TRegEx.Match(Value,Name+'\s*=\s*(?:"([^"]*)"|([^;\s]+))',[roIgnoreCase]);
    if not Match.Success then Exit('');
    Result:='';
    if Match.Groups.Count>1 then Result:=Match.Groups[1].Value;
    if (Result='') and (Match.Groups.Count>2) then Result:=Match.Groups[2].Value;
  end;
  function QuotedPrintable(const Value: string): TBytes;
  var I,N,A,B: Integer;
    function Hex(C: Char): Integer;
    begin
      if CharInSet(C,['0'..'9']) then Exit(Ord(C)-Ord('0'));
      if CharInSet(C,['a'..'f']) then Exit(Ord(C)-Ord('a')+10);
      if CharInSet(C,['A'..'F']) then Exit(Ord(C)-Ord('A')+10);
      Result:=-1;
    end;
  begin
    SetLength(Result,Length(Value)); I:=1; N:=0;
    while I<=Length(Value) do
    begin
      if Value[I]='=' then
      begin
        if (I+2<=Length(Value)) and (Copy(Value,I+1,2)=#13#10) then begin Inc(I,3); Continue; end;
        if (I<Length(Value)) and (Value[I+1]=#10) then begin Inc(I,2); Continue; end;
        if I+2<=Length(Value) then
        begin
          A:=Hex(Value[I+1]); B:=Hex(Value[I+2]);
          if (A>=0) and (B>=0) then begin Result[N]:=A*16+B; Inc(N); Inc(I,3); Continue; end;
        end;
      end;
      Result[N]:=Ord(Value[I]) and $FF; Inc(N); Inc(I);
    end;
    SetLength(Result,N);
  end;
  procedure Parse(const Part: string; Depth: Integer);
  var Header,Body,ContentType,Transfer,Location,CID,Boundary,Line,Name,Value,Item: string;
    Divider,At,Finish,Start: Integer; Payload: TBytes; Lines: TStringList;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
    Inc(PartCount);
    if (Depth>12) or (PartCount>4096) then raise Exception.Create('Слишком сложный MHTML.');
    Divider:=Pos(#13#10#13#10,Part);
    if Divider>0 then begin Header:=Copy(Part,1,Divider-1); Body:=Copy(Part,Divider+4,MaxInt); end
    else begin Divider:=Pos(#10#10,Part); if Divider=0 then Exit; Header:=Copy(Part,1,Divider-1); Body:=Copy(Part,Divider+2,MaxInt); end;
    Header:=TRegEx.Replace(Header,'\r?\n[ \t]+',' ');
    Lines:=TStringList.Create;
    try
      Lines.Text:=Header;
      for Line in Lines do
      begin
        At:=Pos(':',Line); if At=0 then Continue;
        Name:=LowerCase(Trim(Copy(Line,1,At-1))); Value:=Trim(Copy(Line,At+1,MaxInt));
        if Name='content-type' then ContentType:=Value
        else if Name='content-transfer-encoding' then Transfer:=LowerCase(Value)
        else if Name='content-location' then Location:=Value
        else if Name='content-id' then CID:=Value.Trim(['<','>']);
      end;
    finally Lines.Free; end;
    if LowerCase(ContentType).StartsWith('multipart/') then
    begin
      Boundary:='--'+Param(ContentType,'boundary'); if Boundary='--' then raise Exception.Create('В MHTML не задана граница частей.');
      // Match MIME boundary lines, not the same text inside an attachment.
      Start:=0;
      for var Match in TRegEx.Matches(Body,'(?m)^'+TRegEx.Escape(Boundary)+'(--)?[ \t]*\r?$',[]) do
      begin
        if Start>0 then begin Finish:=Match.Index; Item:=Copy(Body,Start,Finish-Start); Parse(Item.TrimRight([#13,#10]),Depth+1); end;
        if (Match.Groups.Count>1) and (Match.Groups[1].Value='--') then Break;
        Start:=Match.Index+Match.Length; if (Start<=Length(Body)) and (Body[Start]=#10) then Inc(Start);
      end;
      Exit;
    end;
    if Transfer='base64' then Payload:=TNetEncoding.Base64.DecodeStringToBytes(Body)
    else if Transfer='quoted-printable' then Payload:=QuotedPrintable(Body)
    else Payload:=Encoding.GetBytes(Body);
    Inc(Total,Length(Payload)); if Total>128*1024*1024 then raise Exception.Create('MHTML содержит слишком много данных.');
    if LowerCase(ContentType).StartsWith('text/html') and (HTML='') then HTML:=DecodeReaderHTML(Payload,Param(ContentType,'charset'))
    else if LowerCase(ContentType).StartsWith('text/plain') and (Plain='') then Plain:=DecodeReaderHTML(Payload,Param(ContentType,'charset'));
    if LowerCase(ContentType).StartsWith('image/') then
    begin
      if Location<>'' then Resources.AddOrSetValue(Location,Payload);
      if CID<>'' then Resources.AddOrSetValue('cid:'+CID,Payload);
    end;
  end;
begin
  Encoding:=TEncoding.GetEncoding(28591); PartCount:=0; Total:=0;
  try
    Raw:=Encoding.GetString(Bytes); Parse(Raw,0);
    if HTML<>'' then Exit(HTML);
    if Plain<>'' then Exit('<html><body><pre>'+TNetEncoding.HTML.Encode(Plain)+'</pre></body></html>');
    raise Exception.Create('В MHTML не найден текст документа.');
  finally Encoding.Free; end;
end;

end.
