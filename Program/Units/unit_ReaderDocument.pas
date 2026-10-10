unit unit_ReaderDocument;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections;

type
  TReaderChapter = record
    Title: string;
    Position: Integer;
  end;

  // A read-only presentation. No source book or archive member is rewritten.
  TReaderPicture = record
    Bytes: TBytes;
    Width, Height: Integer;
  end;

  TReaderDocument = class
  private
    FBody, FText: TStringBuilder;
    FPlainRTF: UTF8String;
    FChapters: TList<TReaderChapter>;
    FImages, FSkippedImages: Integer;
    FPictures: TList<TReaderPicture>;
    procedure AddText(const Value: string; PreserveWhitespace: Boolean = False);
    procedure Paragraph;
    procedure Chapter(const Value: string);
    procedure Picture(const Bytes: TBytes);
  public
    Title, FormatName: string;
    Warnings: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Load(const FileName: string; const Canceled: TFunc<Boolean> = nil);
    function RTF(MaxPictureWidth: Integer = 500; MaxPictureHeight: Integer = 500): UTF8String;
    // After native loading, retain RTF only when images require resize reflow.
    procedure ReleaseUnusedBuffers;
    function PlainText: string;
    function Chapters: TArray<TReaderChapter>;
    property ImageCount: Integer read FImages;
    property SkippedImages: Integer read FSkippedImages;
  end;

function ReaderDecodeText(const Bytes: TBytes): string;
function ReaderSupportsReflow(const FileName: string): Boolean;

implementation

uses Winapi.Windows, Winapi.ActiveX, System.IOUtils, System.Math, System.Types,
  System.RegularExpressions, System.NetEncoding, System.Zip, System.Variants,
  System.Win.ComObj, Winapi.MSXML, Vcl.Graphics, unit_ImageBounds, unit_FB2Utils, unit_ReaderMIME, unit_ReaderFormats;

const
  MAX_DOCUMENT_BYTES = 64 * 1024 * 1024;
  READER_RTF_HEADER: UTF8String = '{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0 Georgia;}{\f1 Consolas;}}\uc1\f0\fs28 ';

// TXT needs no intermediate Unicode RTF builders. Count once, then encode
// straight into one immutable ASCII/UTF8 buffer retained by the native stream.
function PlainTextRTF(const Value: string; const Canceled: TFunc<Boolean>): UTF8String;
var I, Code, Magnitude, Digits, J, At: Integer; Total: Int64; C: Char;
  Number: array[0..4] of AnsiChar;
  procedure Check;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
    if Total>128*1024*1024 then raise Exception.Create('Книга слишком велика для экспериментальной читалки.');
  end;
  procedure Emit(C: AnsiChar);
  begin Result[At]:=C; Inc(At); end;
  procedure EmitControl(const Value: UTF8String);
  var K: Integer;
  begin for K:=1 to Length(Value) do Emit(Value[K]); end;
begin
  Total:=Length(READER_RTF_HEADER)+1;
  for I:=1 to Length(Value) do
  begin
    if (I and 4095)=0 then Check;
    C:=Value[I];
    case C of
      '\','{','}': Inc(Total,2);
      #13,#9: Inc(Total,5);
      #10: ;
    else
      if Ord(C)<=127 then Inc(Total)
      else
      begin
        Code:=Ord(C); if Code>32767 then Dec(Code,65536);
        Magnitude:=Abs(Code); Digits:=1;
        while Magnitude>=10 do begin Inc(Digits); Magnitude:=Magnitude div 10; end;
        Inc(Total,3+Digits+Ord(Code<0));
      end;
    end;
  end;
  Check; SetLength(Result,Integer(Total));
  Move(READER_RTF_HEADER[1],Result[1],Length(READER_RTF_HEADER));
  At:=Length(READER_RTF_HEADER)+1;
  for I:=1 to Length(Value) do
  begin
    if (I and 4095)=0 then Check;
    C:=Value[I];
    case C of
      '\','{','}': begin Emit('\'); Emit(AnsiChar(C)); end;
      #13: EmitControl('\par ');
      #10: ;
      #9: EmitControl('\tab ');
    else
      if Ord(C)<=127 then Emit(AnsiChar(C))
      else
      begin
        Code:=Ord(C); if Code>32767 then Dec(Code,65536);
        EmitControl('\u');
        if Code<0 then begin Emit('-'); Code:=-Code; end;
        Digits:=0;
        repeat
          Number[Digits]:=AnsiChar(Ord('0')+Code mod 10); Inc(Digits); Code:=Code div 10;
        until Code=0;
        for J:=Digits-1 downto 0 do Emit(Number[J]);
        Emit('?');
      end;
    end;
  end;
  Emit('}');
  Assert(At=Length(Result)+1,'Incorrect TXT RTF byte count');
end;

function ReaderSupportsReflow(const FileName: string): Boolean;
var E: string;
begin
  E := LowerCase(ExtractFileExt(FileName));
  Result := IsBuiltinReaderFormat(E) and (E<>'.pdf');
end;

function ReaderDecodeText(const Bytes: TBytes): string;
var Enc: TEncoding; Start, Count: Integer;
begin
  Start := 0; Count := Length(Bytes);
  if Count=0 then Exit('');
  if (Count>=2) and (Bytes[0]=$FF) and (Bytes[1]=$FE) then
    Exit(TEncoding.Unicode.GetString(Bytes,2,Count-2));
  if (Count>=2) and (Bytes[0]=$FE) and (Bytes[1]=$FF) then
    Exit(TEncoding.BigEndianUnicode.GetString(Bytes,2,Count-2));
  if (Count>=3) and (Bytes[0]=$EF) and (Bytes[1]=$BB) and (Bytes[2]=$BF) then Start:=3;
  if Start=Count then Exit('');
  if MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Bytes[Start]),Count-Start,nil,0)>0 then
    Exit(TEncoding.UTF8.GetString(Bytes,Start,Count-Start));
  Enc := TEncoding.GetEncoding(1251);
  try Result := Enc.GetString(Bytes); finally Enc.Free; end;
end;

function EscapeRTF(const Value: string; const Canceled: TFunc<Boolean> = nil): string;
var C: Char; B: TStringBuilder; Code,I: Integer;
begin
  B := TStringBuilder.Create;
  try
    for I:=1 to Length(Value) do
    begin
      if (I and 4095)=0 then
      begin
        if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
        if B.Length>128*1024*1024 then raise Exception.Create('Книга слишком велика для экспериментальной читалки.');
      end;
      C:=Value[I];
      case C of
        '\','{','}': B.Append('\').Append(C);
        #13: B.Append('\par ');
        #10: ;
        #9: B.Append('\tab ');
      else
        if Ord(C)>127 then
        begin
          Code:=Ord(C); if Code>32767 then Dec(Code,65536);
          B.Append('\u').Append(Code).Append('?');
        end
        else B.Append(C);
      end;
    end;
    Result := B.ToString;
  finally B.Free; end;
end;

function NormalizeReaderXML(const Value: string): string;
var M: TMatch; B: TStringBuilder; Start, Finish: Integer; Quote: Char; Entity: string;
begin
  B:=TStringBuilder.Create; Start:=1;
  try
    // Literal text, comments and processing instructions are opaque. HTML
    // entities and external DTD declarations only affect actual XML markup.
    for M in TRegEx.Matches(Value,
      '<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE|&(?:nbsp|mdash|ndash|hellip|laquo|raquo|copy|reg|trade);',
      [roSingleLine]) do
    begin
      if M.Index<Start then Continue;
      B.Append(Copy(Value,Start,M.Index-Start));
      if M.Value='<!DOCTYPE' then
      begin
        Finish:=M.Index+9; Quote:=#0;
        while Finish<=Length(Value) do
        begin
          if Quote<>#0 then begin if Value[Finish]=Quote then Quote:=#0; end
          else if CharInSet(Value[Finish],['"',#39]) then Quote:=Value[Finish]
          else if Value[Finish]='[' then raise Exception.Create('Документы с внутренними DTD пока открываются внешней читалкой.')
          else if Value[Finish]='>' then Break;
          Inc(Finish);
        end;
        if Finish>Length(Value) then raise Exception.Create('Некорректное объявление DTD.');
        Start:=Finish+1;
      end
      else
      begin
        Entity:=M.Value;
        if Entity='&nbsp;' then Entity:='&#160;'
        else if Entity='&mdash;' then Entity:='&#8212;'
        else if Entity='&ndash;' then Entity:='&#8211;'
        else if Entity='&hellip;' then Entity:='&#8230;'
        else if Entity='&laquo;' then Entity:='&#171;'
        else if Entity='&raquo;' then Entity:='&#187;'
        else if Entity='&copy;' then Entity:='&#169;'
        else if Entity='&reg;' then Entity:='&#174;'
        else if Entity='&trade;' then Entity:='&#8482;';
        B.Append(Entity); Start:=M.Index+M.Length;
      end;
    end;
    B.Append(Copy(Value,Start,MaxInt)); Result:=B.ToString;
  finally B.Free; end;
end;

function XMLDocument(const Bytes: TBytes): IXMLDOMDocument3;
var S: string; M: TMatch; Enc: TEncoding;
begin
  if Length(Bytes)>MAX_DOCUMENT_BYTES then raise Exception.Create('Документ превышает предел экспериментальной читалки (64 МБ).');
  S := ReaderDecodeText(Bytes);
  M := TRegEx.Match(Copy(S,1,512),'^<\?xml\s+[^?]*?\bencoding\s*=\s*["'']([^"'']+)');
  if M.Success and not SameText(M.Groups[1].Value,'utf-8') and
    not SameText(M.Groups[1].Value,'utf-16') then
  begin
    Enc := TEncoding.GetEncoding(M.Groups[1].Value);
    try S := Enc.GetString(Bytes); finally Enc.Free; end;
  end;
  S:=NormalizeReaderXML(S);
  Result := CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async := False; Result.resolveExternals := False; Result.validateOnParse := False;
  Result.setProperty('ProhibitDTD',True);
  if not Result.loadXML(S) then raise Exception.Create('Не удалось прочитать XML: '+Result.parseError.reason);
end;

function LocalName(const Node: IXMLDOMNode): string;
begin
  Result := LowerCase(Node.baseName);
  if Result='' then Result := LowerCase(Node.nodeName);
end;

function Attribute(const Node: IXMLDOMNode; const Name: string): string;
var I: Integer; A: IXMLDOMNode;
begin
  Result := '';
  if Node.attributes=nil then Exit;
  for I:=0 to Node.attributes.length-1 do
  begin A:=Node.attributes.item[I]; if LocalName(A)=Name then Exit(A.text); end;
end;

function FindNode(const Node: IXMLDOMNode; const Name: string; Depth: Integer = 0): IXMLDOMNode;
var I: Integer;
begin
  Result := nil;
  if (Node=nil) then Exit;
  if Depth>256 then raise Exception.Create('Слишком глубокая разметка книги.');
  if LocalName(Node)=Name then Exit(Node);
  for I:=0 to Node.childNodes.length-1 do
  begin Result:=FindNode(Node.childNodes.item[I],Name,Depth+1); if Result<>nil then Exit; end;
end;

constructor TReaderDocument.Create;
begin
  inherited;
  FBody:=TStringBuilder.Create; FText:=TStringBuilder.Create;
  FPictures:=TList<TReaderPicture>.Create;
  FChapters:=TList<TReaderChapter>.Create; Warnings:=TStringList.Create;
end;

destructor TReaderDocument.Destroy;
begin
  FPictures.Free; Warnings.Free; FChapters.Free; FText.Free; FBody.Free; inherited;
end;

procedure TReaderDocument.AddText(const Value: string; PreserveWhitespace: Boolean);
var S: string;
begin
  if PreserveWhitespace then S:=Value
  else S:=TRegEx.Replace(Value,'[\r\n\t ]+',' ');
  FBody.Append(EscapeRTF(S)); FText.Append(S);
end;

procedure TReaderDocument.Paragraph;
begin FBody.Append('\par '); FText.Append(#13); end;

procedure TReaderDocument.Chapter(const Value: string);
var C: TReaderChapter;
begin
  C.Title:=Trim(TRegEx.Replace(Value,'\s+',' ')); C.Position:=FText.Length;
  if C.Title<>'' then FChapters.Add(C);
end;

procedure TReaderDocument.Picture(const Bytes: TBytes);
var Stream: TStream; Graphic: TGraphic; Item: TReaderPicture; Scale: Double;
begin
  if Length(Bytes)=0 then raise Exception.Create('Данные изображения отсутствуют.');
  if Length(Bytes)>16*1024*1024 then raise Exception.Create('Изображение превышает 16 МБ.');
  Stream:=TBytesStream.Create(Bytes); Graphic:=nil;
  try
    Graphic:=CreateGraphicFromStream(Stream);
    if not Assigned(Graphic) or (Graphic.Width<=0) or (Graphic.Height<=0) then
      raise Exception.Create('Неподдерживаемое изображение.');
    if Int64(Graphic.Width)*Graphic.Height>64000000 then raise Exception.Create('Слишком большое изображение.');
    Scale:=Min(1.0,1024.0/Max(Graphic.Width,Graphic.Height));
    Item.Bytes:=Bytes;
    Item.Width:=Max(1,Round(Graphic.Width*Scale));
    Item.Height:=Max(1,Round(Graphic.Height*Scale));
    // Keep compressed source bytes, not multi-megabyte Unicode hexadecimal DIB.
    FBody.Append('\pard\qc {\mhlimage ').Append(FPictures.Count).Append('}');
    FPictures.Add(Item);
    FText.Append(#$FFFC); Paragraph; FBody.Append('\pard\qj\fi360 '); Inc(FImages);
  finally Graphic.Free; Stream.Free; end;
end;

function ReaderBinaryArea(const Value: string): Int64;
var Bytes: TBytes; Stream: TStream; W,H: Integer;
begin
  Result:=-1; if Length(Value)>24*1024*1024 then Exit;
  Stream:=nil;
  try
    try
      Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Value); Stream:=TBytesStream.Create(Bytes);
      if ImageDimensions(Stream,W,H) then Result:=Int64(W)*H;
    except Result:=-1; end;
  finally Stream.Free; end;
end;

procedure TReaderDocument.Load(const FileName: string; const Canceled: TFunc<Boolean>);
var Document: IXMLDOMDocument3; Root, Node, Manifest, Spine, Item: IXMLDOMNode;
  Binaries, Paths: TDictionary<string,string>; Resources: TDictionary<string,TBytes>; Zip: TZipFile;
  Data: TBytes; E, PackagePath, CurrentPath, ID, ExistingBinary, HTML: string; I: Integer; UnpackedBytes: Int64;
  procedure Check;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
    if FBody.Length>128*1024*1024 then raise Exception.Create('Книга слишком велика для экспериментальной читалки.');
  end;
  procedure ReadDocument(out Bytes: TBytes);
  var Stream: TFileStream;
  begin
    Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size>MAX_DOCUMENT_BYTES then raise Exception.Create('Документ превышает предел экспериментальной читалки (64 МБ).');
      SetLength(Bytes,Stream.Size);
      if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
    finally Stream.Free; end;
  end;
  function ZipPath(const Base, Href: string): string;
  var Parts: TStringList; P,S: string; Segment: string;
  begin
    // This is a URI path, not form data: a literal '+' is part of the filename.
    S:=StringReplace(TNetEncoding.URL.Decode(Href.Replace('+','%2B')),'\','/',[rfReplaceAll]);
    if (Pos(':',S)>0) or S.StartsWith('/') then raise Exception.Create('Внешнее изображение пропущено.');
    P:=Copy(Base,1,LastDelimiter('/',Base)); Parts:=TStringList.Create;
    try
      for Segment in (P+S).Split(['/']) do
        if (Segment='') or (Segment='.') then Continue
        else if Segment='..' then
        begin if Parts.Count=0 then raise Exception.Create('Недопустимый путь EPUB.'); Parts.Delete(Parts.Count-1); end
        else Parts.Add(Segment);
      Result:=StringReplace(Trim(Parts.Text),sLineBreak,'/',[rfReplaceAll]);
    finally Parts.Free; end;
  end;
  procedure ReadZip(const Path: string; out Bytes: TBytes);
  var Index: Integer;
  begin
    Check; Index:=Zip.IndexOf(Path);
    if Index<0 then raise Exception.Create('Не найден элемент EPUB: '+Path);
    if Zip.FileInfo[Index].UncompressedSize>MAX_DOCUMENT_BYTES then raise Exception.Create('Элемент EPUB слишком велик.');
    Inc(UnpackedBytes,Zip.FileInfo[Index].UncompressedSize);
    if UnpackedBytes>256*1024*1024 then raise Exception.Create('EPUB слишком велик для экспериментальной читалки.');
    Zip.Read(Index,Bytes);
  end;
  procedure Walk(const N: IXMLDOMNode; Depth: Integer; InsideTitle: Boolean = False);
  var J, Spaces: Integer; Name, Ref, Binary, Style: string; StyleNode, StyleValue: IXMLDOMNode; Bytes: TBytes; IsParagraph, IsTitle: Boolean;
  begin
    Check; if Depth>256 then raise Exception.Create('Слишком глубокая разметка книги.');
    if N.nodeType in [NODE_TEXT,NODE_CDATA_SECTION] then
    begin
      AddText(N.text,(E='.docx') and Assigned(N.parentNode) and
        SameText(Attribute(N.parentNode,'space'),'preserve'));
      Exit;
    end;
    Name:=LocalName(N);
    if (Name='script') or (Name='style') or (Name='binary') or (Name='description') or
      (Name='ppr') or (Name='rpr') or (Name='del') or (Name='instrtext') then Exit;
    IsParagraph:=(Name='p') or (Name='v') or (Name='li') or (Name='tr');
    IsTitle:=(Name='title') or (Name='h') or (Name='h1') or (Name='h2') or (Name='h3');
    if (E='.docx') and (Name='p') then
    begin
      StyleNode:=FindNode(N,'ppr'); Style:='';
      if Assigned(StyleNode) then
      begin StyleValue:=FindNode(StyleNode,'pstyle'); if Assigned(StyleValue) then Style:=LowerCase(Attribute(StyleValue,'val')); end;
      IsTitle:=Style.StartsWith('heading') or (Style='title');
    end;
    if IsTitle then begin Paragraph; Chapter(N.text); FBody.Append('{\pard\qc\b '); end;
    if IsParagraph and not InsideTitle then FBody.Append('\pard\qj\fi360\sa100 ');
    if (Name='strong') or (Name='b') or (Name='subtitle') then FBody.Append('{\b ');
    if (Name='emphasis') or (Name='i') or (Name='em') then FBody.Append('{\i ');
    if Name='code' then FBody.Append('{\f1 ');
    if (E='.docx') and (Name='r') then
    begin
      FBody.Append('{'); StyleNode:=FindNode(N,'rpr');
      if Assigned(StyleNode) then
      begin
        StyleValue:=FindNode(StyleNode,'b');
        if Assigned(StyleValue) and not (Attribute(StyleValue,'val')='0') and not SameText(Attribute(StyleValue,'val'),'false') then FBody.Append('\b ');
        StyleValue:=FindNode(StyleNode,'i');
        if Assigned(StyleValue) and not (Attribute(StyleValue,'val')='0') and not SameText(Attribute(StyleValue,'val'),'false') then FBody.Append('\i ');
      end;
    end;
    if (Name='image') or (Name='img') or (Name='blip') then
    begin
      Ref:=Attribute(N,'href'); if Ref='' then Ref:=Attribute(N,'src');
      if Name='blip' then Ref:=Attribute(N,'embed');
      try
        if (E='.docx') and Assigned(Zip) then
        begin
          if not Paths.TryGetValue(Ref,Binary) then raise Exception.Create('Не найдено вложенное изображение DOCX.');
          ReadZip(Binary,Bytes);
        end
        else if Assigned(Zip) then ReadZip(ZipPath(CurrentPath,Ref),Bytes)
        else if Binaries.TryGetValue(Ref.TrimLeft(['#']),Binary) then
          Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Binary) else Bytes:=nil;
        Picture(Bytes);
      except
        on E: EAbort do raise;
        on E: Exception do begin Inc(FSkippedImages); if Warnings.Count<20 then Warnings.Add('Изображение: '+E.Message); end;
      end;
    end;
    if (Name='br') or (Name='empty-line') or (Name='line-break') then Paragraph;
    if Name='tab' then AddText(#9,True);
    if (E='.odt') and (Name='s') then
    begin
      Spaces:=StrToIntDef(Attribute(N,'c'),1);
      if (Spaces<1) or (Spaces>10000) then raise Exception.Create('Недопустимое число пробелов в документе ODT.');
      AddText(StringOfChar(' ',Spaces),True);
    end;
    for J:=0 to N.childNodes.length-1 do Walk(N.childNodes.item[J],Depth+1,InsideTitle or IsTitle);
    if (Name='strong') or (Name='b') or (Name='subtitle') or (Name='emphasis') or
      (Name='i') or (Name='em') or (Name='code') or ((E='.docx') and (Name='r')) then FBody.Append('}');
    if IsTitle then begin FBody.Append('}'); Paragraph; end;
    if IsParagraph then Paragraph;
  end;
  procedure WalkHTML(const Value: string);
  var Match, AttributeMatch: TMatch; Token, Name, Ref, Heading: string; Bytes: TBytes; Closing: Boolean;
  begin
    for Match in TRegEx.Matches(Value,'<!\[CDATA\[.*?\]\]>|<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>|<[^>]*>|[^<]+|<',[roSingleLine,roIgnoreCase]) do
    begin
      Check; Token:=Match.Value;
      if Token.StartsWith('<![CDATA[') then begin AddText(Copy(Token,10,Length(Token)-12)); Continue; end;
      if Token.StartsWith('<!--') or LowerCase(Token).StartsWith('<script') or LowerCase(Token).StartsWith('<style') then Continue;
      if not Token.StartsWith('<') or (Token='<') then begin AddText(TNetEncoding.HTML.Decode(Token)); Continue; end;
      AttributeMatch:=TRegEx.Match(Token,'^</?\s*([a-z0-9]+)',[roIgnoreCase]);
      if not AttributeMatch.Success then Continue;
      Name:=LowerCase(AttributeMatch.Groups[1].Value); Closing:=Token.StartsWith('</');
      if (Name='p') or (Name='div') or (Name='li') or (Name='tr') or (Name='br') or (Name='pre') then Paragraph;
      if (Name='b') or (Name='strong') then begin if Closing then FBody.Append('\b0 ') else FBody.Append('\b '); end;
      if (Name='i') or (Name='em') then begin if Closing then FBody.Append('\i0 ') else FBody.Append('\i '); end;
      if (Length(Name)=2) and (Name[1]='h') and CharInSet(Name[2],['1'..'6']) then
      begin
        Paragraph;
        if Closing then FBody.Append('\b0 ')
        else
        begin
          Heading:=Copy(Value,Match.Index+Match.Length,MaxInt); Heading:=Copy(Heading,1,Pos('</'+Name,LowerCase(Heading))-1);
          Chapter(TNetEncoding.HTML.Decode(TRegEx.Replace(Heading,'<[^>]*>',''))); FBody.Append('\b ');
        end;
      end;
      if (Name='img') and not Closing then
      begin
        AttributeMatch:=TRegEx.Match(Token,'\bsrc\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))',[roIgnoreCase]);
        Ref:=AttributeMatch.Groups[1].Value; if Ref='' then Ref:=AttributeMatch.Groups[2].Value; if Ref='' then Ref:=AttributeMatch.Groups[3].Value;
        Ref:=TNetEncoding.HTML.Decode(Ref);
        try
          if not Resources.TryGetValue(Ref,Bytes) then
          begin
            if Ref.StartsWith('data:image/',True) and (Pos(';base64,',Ref)>0) then Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Copy(Ref,Pos(',',Ref)+1,MaxInt))
            else if (Ref<>'') and (Pos(':',Ref)=0) and not Ref.StartsWith('/') and not Ref.StartsWith('\') and not Assigned(Zip) then
            begin
              Ref:=TPath.GetFullPath(TPath.Combine(ExtractFilePath(TPath.GetFullPath(FileName)),TNetEncoding.URL.Decode(Ref.Replace('+','%2B'))));
              if not Ref.StartsWith(ExtractFilePath(TPath.GetFullPath(FileName)),True) then raise Exception.Create('Внешнее изображение пропущено.');
              if not FileExists(Ref) then raise Exception.Create('Изображение не найдено.');
              with TFileStream.Create(Ref,fmOpenRead or fmShareDenyNone) do
                try if Size>16*1024*1024 then raise Exception.Create('Изображение слишком велико.'); SetLength(Bytes,Size); if Size>0 then ReadBuffer(Bytes[0],Size); finally Free; end;
            end
            else raise Exception.Create('Внешнее изображение пропущено.');
          end;
          Picture(Bytes);
        except
          on Error: EAbort do raise;
          on Error: Exception do begin Inc(FSkippedImages); if Warnings.Count<20 then Warnings.Add('Изображение: '+Error.Message); end;
        end;
      end;
    end;
  end;

begin
  FPlainRTF:=''; FPictures.Clear; FBody.Clear; FText.Clear; FChapters.Clear; Warnings.Clear; FImages:=0; FSkippedImages:=0;
  UnpackedBytes:=0; Check; E:=LowerCase(ExtractFileExt(FileName)); FormatName:=E.TrimLeft(['.']);
  Title:=ExtractFileName(FileName); Zip:=nil;
  Binaries:=TDictionary<string,string>.Create; Paths:=TDictionary<string,string>.Create; Resources:=TDictionary<string,TBytes>.Create;
  try
    if (E='.txt') or (E='.md') or (E='.markdown') or (E='.faq') or (E='.wri') then
    begin
      ReadDocument(Data);
      if E='.wri' then
      begin
        if (Length(Data)<128) or not ((Data[1]=$BE) and ((Data[0]=$31) or (Data[0]=$32))) then raise Exception.Create('Файл не является документом Windows Write.');
        I:=Data[14] or (Integer(Data[15]) shl 8) or (Integer(Data[16]) shl 16) or (Integer(Data[17]) shl 24);
        if (I<128) or (I>Length(Data)) then raise Exception.Create('Повреждён текст Windows Write.');
        Data:=Copy(Data,128,I-128); Warnings.Add('Windows Write: показан текст без старого форматирования и объектов.');
      end;
      if (E='.md') or (E='.markdown') then Warnings.Add('Markdown: показан исходный текст.');
      AddText(''); FText.Append(ReaderDecodeText(Data).Replace(#13#10,#13).Replace(#10,#13));
      Check; FPlainRTF:=PlainTextRTF(FText.ToString,Canceled); Check; Exit;
    end;
    if (E='.jpg') or (E='.jpeg') or (E='.png') or (E='.gif') or (E='.bmp') or (E='.webp') or (E='.tif') or (E='.tiff') then
    begin ReadDocument(Data); Picture(Data); Exit; end;
    if (E='.mht') or (E='.mhtml') then
    begin
      ReadDocument(Data); HTML:=ReadReaderMHTML(Data,Resources,Canceled); WalkHTML(HTML);
      if FText.Length=0 then raise Exception.Create('В MHTML нет текста для чтения.');
      Warnings.Add('MHTML: локальный текст и вложенные изображения; оформление упрощено.'); Exit;
    end;
    if E='.fb3' then
    begin
      Zip:=TZipFile.Create; Zip.Open(FileName,zmRead); CurrentPath:='fb3/body.xml';
      ReadZip(CurrentPath,Data); Document:=XMLDocument(Data); Walk(Document.documentElement,0);
      if FText.Length=0 then raise Exception.Create('В FB3 нет текста для чтения.'); Exit;
    end;
    if (E='.docx') or (E='.odt') then
    begin
      Zip:=TZipFile.Create; Zip.Open(FileName,zmRead);
      if E='.docx' then
      begin
        CurrentPath:='word/document.xml';
        if Zip.IndexOf('word/_rels/document.xml.rels')>=0 then
        begin
          ReadZip('word/_rels/document.xml.rels',Data); Document:=XMLDocument(Data);
          Root:=Document.documentElement;
          for I:=0 to Root.childNodes.length-1 do
          begin
            Item:=Root.childNodes.item[I];
            if (LocalName(Item)='relationship') and not SameText(Attribute(Item,'targetmode'),'external') then
              Paths.AddOrSetValue(Attribute(Item,'id'),ZipPath(CurrentPath,Attribute(Item,'target')));
          end;
        end;
      end else CurrentPath:='content.xml';
      ReadZip(CurrentPath,Data); Document:=XMLDocument(Data);
      Node:=FindNode(Document.documentElement,'body');
      if Node=nil then raise Exception.Create('В документе не найден текст книги.');
      Walk(Node,0);
      if FText.Length=0 then raise Exception.Create('В документе нет текста для чтения.');
      Exit;
    end;
    if E='.epub' then
    begin
      Zip:=TZipFile.Create; Zip.Open(FileName,zmRead);
      ReadZip('META-INF/container.xml',Data); Document:=XMLDocument(Data);
      Node:=FindNode(Document.documentElement,'rootfile');
      if Node=nil then raise Exception.Create('В EPUB не найден основной документ.');
      PackagePath:=Attribute(Node,'full-path'); ReadZip(PackagePath,Data); Document:=XMLDocument(Data);
      Root:=Document.documentElement; Node:=FindNode(Root,'title'); if Node<>nil then Title:=Node.text;
      Manifest:=FindNode(Root,'manifest'); Spine:=FindNode(Root,'spine');
      if (Manifest=nil) or (Spine=nil) then raise Exception.Create('В EPUB нет порядка чтения.');
      for I:=0 to Manifest.childNodes.length-1 do
      begin Item:=Manifest.childNodes.item[I]; if LocalName(Item)='item' then
        // Resolve only a resource actually used by the reading spine.
        Paths.AddOrSetValue(Attribute(Item,'id'),Attribute(Item,'href')); end;
      for I:=0 to Spine.childNodes.length-1 do
      begin
        Item:=Spine.childNodes.item[I]; if LocalName(Item)<>'itemref' then Continue;
        if SameText(Attribute(Item,'linear'),'no') then Continue;
        ID:=Attribute(Item,'idref');
        if not Paths.TryGetValue(ID,CurrentPath) then raise Exception.Create('Не найден раздел EPUB: '+ID);
        CurrentPath:=ZipPath(PackagePath,CurrentPath);
        ReadZip(CurrentPath,Data); Document:=XMLDocument(Data);
        Node:=FindNode(Document.documentElement,'body'); if Node<>nil then Walk(Node,0);
      end;
    end
    else
    begin
      ReadDocument(Data);
      try Document:=XMLDocument(Data);
      except
        on Error: Exception do
        begin
          if (E<>'.html') and (E<>'.htm') and (E<>'.shtml') then raise;
          HTML:=DecodeReaderHTML(Data); WalkHTML(HTML);
          if FText.Length=0 then raise Exception.Create('В HTML нет текста для чтения.');
          Warnings.Add('HTML: показано упрощённое оформление.'); Exit;
        end;
      end;
      Root:=Document.documentElement;
      if E='.fb2' then
      begin
        if LocalName(Root)<>'fictionbook' then raise Exception.Create('Файл не является FB2.');
        Node:=FindNode(Root,'book-title'); if Node<>nil then Title:=Node.text;
        for I:=0 to Root.childNodes.length-1 do
        begin
          Node:=Root.childNodes.item[I];
          if LocalName(Node)='binary' then
          begin
            ID:=Attribute(Node,'id');
            if not Binaries.TryGetValue(ID,ExistingBinary) then Binaries.Add(ID,Node.text)
            else if ReaderBinaryArea(Node.text)>ReaderBinaryArea(ExistingBinary) then Binaries[ID]:=Node.text;
          end;
        end;
        for I:=0 to Root.childNodes.length-1 do
        begin Node:=Root.childNodes.item[I]; if LocalName(Node)='body' then Walk(Node,0); end;
      end
      else
      begin Node:=FindNode(Root,'body'); if Node=nil then Node:=Root; Walk(Node,0); end;
    end;
    if FText.Length=0 then raise Exception.Create('В документе нет текста для чтения.');
  finally Resources.Free; Zip.Free; Paths.Free; Binaries.Free; end;
end;

function TReaderDocument.RTF(MaxPictureWidth, MaxPictureHeight: Integer): UTF8String;
var Body: string; Match: TMatch; Item: TReaderPicture; Headers: TList<UTF8String>;
  At, Start, I, Y, Pitch, DIBSize, GoalW, GoalH, Index: Integer;
  Total: Int64; Scale: Double; Header: UTF8String;
  Stream: TStream; Graphic: TGraphic; Bitmap: TBitmap; Info: TBitmapInfoHeader;
  procedure AppendASCII(const Value: string);
  var K: Integer;
  begin
    for K:=1 to Length(Value) do
    begin Assert(Ord(Value[K])<=127); Result[At]:=AnsiChar(Value[K]); Inc(At); end;
  end;
  procedure AppendBytes(const Buffer; Count: Integer);
  begin if Count>0 then begin Move(Buffer,Result[At],Count); Inc(At,Count); end; end;
begin
  if FPlainRTF<>'' then Exit(FPlainRTF);
  if FImages=0 then
  begin
    SetLength(Result,Length(READER_RTF_HEADER)+FBody.Length+1);
    At:=1; AppendBytes(READER_RTF_HEADER[1],Length(READER_RTF_HEADER));
    for I:=0 to FBody.Length-1 do
    begin Assert(Ord(FBody.Chars[I])<=127); Result[At]:=AnsiChar(FBody.Chars[I]); Inc(At); end;
    Result[At]:='}'; Exit;
  end;
  Body:=FBody.ToString; Headers:=TList<UTF8String>.Create;
  try
    Total:=Length(READER_RTF_HEADER)+Length(Body)+1;
    for Match in TRegEx.Matches(Body,'\{\\mhlimage (\d+)\}') do
    begin
      Item:=FPictures[StrToInt(Match.Groups[1].Value)];
      Pitch:=((Item.Width*3+3) div 4)*4;
      DIBSize:=SizeOf(Info)+Pitch*Item.Height;
      Scale:=Min(1.0,Min(Max(16,MaxPictureWidth)/Item.Width,Max(16,MaxPictureHeight)/Item.Height));
      GoalW:=Max(1,Round(Item.Width*15*Scale)); GoalH:=Max(1,Round(Item.Height*15*Scale));
      Header:=UTF8String('{\pict\dibitmap0\picw'+IntToStr(Item.Width)+'\pich'+IntToStr(Item.Height)+
        '\picwgoal'+IntToStr(GoalW)+'\pichgoal'+IntToStr(GoalH)+'\bin'+IntToStr(DIBSize)+' ');
      Headers.Add(Header); Inc(Total,Length(Header)+DIBSize+1-Match.Length);
    end;
    // One bounded byte buffer; no full-book hex strings or Unicode bitmap copies.
    if Total>256*1024*1024 then raise Exception.Create('Изображения книги требуют слишком много памяти для читалки.');
    SetLength(Result,Integer(Total)); At:=1;
    AppendBytes(READER_RTF_HEADER[1],Length(READER_RTF_HEADER)); Start:=1; Index:=0;
    for Match in TRegEx.Matches(Body,'\{\\mhlimage (\d+)\}') do
    begin
      AppendASCII(Copy(Body,Start,Match.Index-Start));
      Header:=Headers[Index]; Inc(Index); AppendBytes(Header[1],Length(Header));
      Item:=FPictures[StrToInt(Match.Groups[1].Value)];
      Stream:=TBytesStream.Create(Item.Bytes); Graphic:=nil; Bitmap:=TBitmap.Create;
      try
        Graphic:=CreateGraphicFromStream(Stream);
        if not Assigned(Graphic) then raise Exception.Create('Не удалось прочитать изображение.');
        Bitmap.PixelFormat:=pf24bit; Bitmap.SetSize(Item.Width,Item.Height);
        Bitmap.Canvas.Brush.Color:=clWhite; Bitmap.Canvas.FillRect(Rect(0,0,Item.Width,Item.Height));
        Bitmap.Canvas.StretchDraw(Rect(0,0,Item.Width,Item.Height),Graphic);
        FillChar(Info,SizeOf(Info),0); Info.biSize:=SizeOf(Info); Info.biWidth:=Item.Width;
        Info.biHeight:=Item.Height; Info.biPlanes:=1; Info.biBitCount:=24; Info.biCompression:=BI_RGB;
        Pitch:=((Item.Width*3+3) div 4)*4; Info.biSizeImage:=Pitch*Item.Height;
        AppendBytes(Info,SizeOf(Info));
        for Y:=Item.Height-1 downto 0 do AppendBytes(Bitmap.ScanLine[Y]^,Pitch);
      finally Bitmap.Free; Graphic.Free; Stream.Free; end;
      AppendASCII('}'); Start:=Match.Index+Match.Length;
    end;
    AppendASCII(Copy(Body,Start,MaxInt)); AppendASCII('}');
    Assert(At=Length(Result)+1,'Reader binary RTF length differs');
  finally Headers.Free; end;
end;

procedure TReaderDocument.ReleaseUnusedBuffers;
begin
  FPlainRTF:='';
  FreeAndNil(FText); FText:=TStringBuilder.Create;
  if FImages=0 then begin FreeAndNil(FBody); FBody:=TStringBuilder.Create; end;
end;

function TReaderDocument.PlainText: string;
begin Result:=FText.ToString; end;

function TReaderDocument.Chapters: TArray<TReaderChapter>;
begin Result:=FChapters.ToArray; end;

end.
