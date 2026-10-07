program FB2PublisherMetadataReaderTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  Winapi.ActiveX,
  System.Win.ComObj,
  fictionbook_21 in '..\fictionbook_21.pas',
  unit_FB2Utils in '..\unit_FB2Utils.pas',
  unit_FB2PublisherMetadataReader in '..\unit_FB2PublisherMetadataReader.pas',
  unit_FB2MetadataRecovery in '..\unit_FB2MetadataRecovery.pas';

type
  TNonSeekableInput = class(TStream)
  private
    FBytes: TBytes;
    FPosition: Integer;
    FTailLength: Integer;
    FMaxChunk: Integer;
  public
    ReadCalls: Integer;
    SeekCalls: Integer;
    BytesRead: Integer;
    constructor Create(const Bytes: TBytes; TailLength: Integer = 0;
      MaxChunk: Integer = MaxInt);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TRaisingInput = class(TNonSeekableInput)
  public
    Critical: Boolean;
    function Read(var Buffer; Count: Longint): Longint; override;
  end;

const
  FB2_NS = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  CYRILLIC_TITLE = #$041A#$043D#$0438#$0433#$0438;

var
  Report: TStringList;
  Failures: Integer;
  Checks: Integer;
  Reader: TFB2PublisherMetadataReader;

constructor TNonSeekableInput.Create(const Bytes: TBytes;
  TailLength, MaxChunk: Integer);
begin
  inherited Create;
  FBytes := Bytes;
  FTailLength := TailLength;
  FMaxChunk := MaxChunk;
end;

function TNonSeekableInput.Read(var Buffer; Count: Longint): Longint;
var
  Copied: Integer;
begin
  Inc(ReadCalls);
  Result := Length(FBytes) + FTailLength - FPosition;
  if Result > Count then
    Result := Count;
  if Result > FMaxChunk then
    Result := FMaxChunk;
  Copied := Length(FBytes) - FPosition;
  if Copied < 0 then
    Copied := 0;
  if Copied > Result then
    Copied := Result;
  if Copied > 0 then
    Move(FBytes[FPosition], Buffer, Copied);
  if Result > Copied then
    FillChar((PByte(@Buffer) + Copied)^, Result - Copied, Ord(' '));
  Inc(FPosition, Result);
  Inc(BytesRead, Result);
end;

function TNonSeekableInput.Write(const Buffer; Count: Longint): Longint;
begin
  raise EStreamError.Create('Test input is read-only');
end;

function TNonSeekableInput.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Inc(SeekCalls);
  raise EStreamError.Create('Test input is not seekable');
end;

function TRaisingInput.Read(var Buffer; Count: Longint): Longint;
begin
  if Critical then
    raise EOutOfMemory.Create('Synthetic critical stream error');
  raise EReadError.Create('Synthetic input read error');
end;

procedure Check(Value: Boolean; const Name: string);
begin
  Inc(Checks);
  if Value then
    Report.Add('PASS ' + Name)
  else
  begin
    Inc(Failures);
    Report.Add('FAIL ' + Name);
  end;
end;

function Metadata(const Sequences: string): string;
begin
  Result := '<FictionBook xmlns="' + FB2_NS + '"><description>' +
    '<title-info><sequence name="Author cycle" number="99"/></title-info>' +
    '<publish-info>' + Sequences + '</publish-info></description>';
end;

function Encoded(const Value: string; Encoding: TEncoding;
  WithBOM: Boolean = False): TBytes;
begin
  if WithBOM then
    Result := Encoding.GetPreamble + Encoding.GetBytes(Value)
  else
    Result := Encoding.GetBytes(Value);
end;

procedure Run(const Name: string; const Bytes: TBytes;
  ExpectedStatus: TFB2MetadataStatus; ExpectedCount: Integer;
  const ExpectedFirst: string = ''; ExpectedNumber: Integer = 0;
  MaxChunk: Integer = MaxInt; CancelAfter: Integer = -1;
  TailLength: Integer = 0);
var
  Input: TNonSeekableInput;
  Series, Stored: TFB2PublisherSeries;
  Status: TFB2MetadataStatus;
  ErrorText: string;
begin
  Input := TNonSeekableInput.Create(Bytes, TailLength, MaxChunk);
  try
    SetLength(Stored, 1);
    Stored[0].Title := 'Previously indexed';
    Stored[0].Number := 42;
    Status := Reader.Read(Input, Series, ErrorText,
      function: Boolean
      begin
        Result := (CancelAfter >= 0) and (Input.BytesRead >= CancelAfter);
      end);
    Check(Status = ExpectedStatus, Name + ': status ' + IntToStr(Ord(Status)));
    if Status = fmsComplete then
    begin
      Check(ErrorText = '', Name + ': no error on completion');
      Check(Length(Series) = ExpectedCount, Name + ': item count');
      if (ExpectedCount > 0) and (Length(Series) > 0) then
      begin
        Check(Series[0].Title = ExpectedFirst, Name + ': decoded title');
        Check(Series[0].Number = ExpectedNumber, Name + ': series number');
      end;
      Stored := Series;
    end
    else
    begin
      Check(Length(Series) = 0, Name + ': no partial output');
      if Status = fmsInvalid then
        Check(ErrorText <> '', Name + ': diagnostic');
      Check((Stored[0].Title = 'Previously indexed') and
        (Stored[0].Number = 42), Name + ': caller retains previous metadata');
    end;
    Check(Input.SeekCalls = 0, Name + ': no seek or size request');
    Check(Input.BytesRead <= FB2_METADATA_MAX_BYTES, Name + ': bounded input');
    if TailLength > 0 then
      Check(Input.BytesRead <= 8192, Name + ': body not consumed');
    if CancelAfter = 0 then
      Check(Input.BytesRead = 0, Name + ': immediate cancellation does not read');
    if Status <> ExpectedStatus then
      Report.Add('  Diagnostic: ' + ErrorText);
  finally
    Input.Free;
  end;
end;

procedure RunText(const Name, XML: string; ExpectedStatus: TFB2MetadataStatus;
  ExpectedCount: Integer = 0; const ExpectedFirst: string = '';
  ExpectedNumber: Integer = 0);
begin
  Run(Name, Encoded(XML, TEncoding.UTF8), ExpectedStatus,
    ExpectedCount, ExpectedFirst, ExpectedNumber);
end;

procedure CheckSeriesDetails;
var
  Input: TStringStream;
  Items: TFB2PublisherSeries;
  ErrorText: string;
  Status: TFB2MetadataStatus;
  I: Integer;
const
  Names: array[0..6] of string = ('Parent', 'Child', 'Zero', 'Bad',
    'Negative', 'Overflow', 'After blank parent');
  Numbers: array[0..6] of Integer = (4, 7, 0, 0, 0, 0, 12);
begin
  Input := TStringStream.Create(Metadata(
    '<sequence name=" Parent " number="4"><sequence name="Child" number="7"/></sequence>' +
    '<sequence name="Zero" number="0"/><sequence name="Bad" number="x"/>' +
    '<sequence name="Negative" number="-1"/><sequence name="Overflow" number="999999999999"/>' +
    '<sequence name=" "><sequence name="After blank parent" number="12"/></sequence>' +
    '<other><sequence name="Not a publisher sequence"/></other>' +
    '<sequence xmlns="urn:foreign" name="Wrong namespace"/>'), TEncoding.UTF8);
  try
    Status := Reader.Read(Input, Items, ErrorText);
    Check(Status = fmsComplete, 'nested sequences: complete');
    Check(Length(Items) = Length(Names), 'nested sequences: only direct/nested publisher sequences');
    for I := 0 to Length(Items) - 1 do
      if I < Length(Names) then
      begin
        Check(Items[I].Title = Names[I], 'nested sequences: title ' + IntToStr(I));
        Check(Items[I].Number = Numbers[I], 'nested sequences: number ' + IntToStr(I));
      end;
  finally
    Input.Free;
  end;
end;

procedure CheckCurrentPosition;
var
  Input: TNonSeekableInput;
  Items: TFB2PublisherSeries;
  ErrorText: string;
  Skipped: array[0..6] of Byte;
begin
  Input := TNonSeekableInput.Create(TEncoding.UTF8.GetBytes('ignored' +
    Metadata('<sequence name="Offset"/>')));
  try
    Input.ReadBuffer(Skipped, SizeOf(Skipped));
    Check(Reader.Read(Input, Items, ErrorText) = fmsComplete,
      'nonzero current position: complete');
    Check((Length(Items) = 1) and (Items[0].Title = 'Offset'),
      'nonzero current position: correct metadata');
    Check(Input.SeekCalls = 0, 'nonzero current position: input was not rewound');
  finally
    Input.Free;
  end;
end;

procedure CheckExceptions;
var
  Input: TRaisingInput;
  Items: TFB2PublisherSeries;
  ErrorText: string;
  Raised: Boolean;
begin
  Input := TRaisingInput.Create(nil);
  try
    Check(Reader.Read(Input, Items, ErrorText) = fmsInvalid,
      'stream read error: invalid status');
    Check((Length(Items) = 0) and (Pos('Synthetic input read error', ErrorText) > 0),
      'stream read error: diagnostic and no partial metadata');
    Input.Critical := True;
    Raised := False;
    try
      Reader.Read(Input, Items, ErrorText);
    except
      on E: EOutOfMemory do
        Raised := E.Message = 'Synthetic critical stream error';
    end;
    Check(Raised, 'critical stream exception is rethrown across COM boundary');
    Raised := False;
    try
      Reader.Read(Input, Items, ErrorText,
        function: Boolean
        begin
          raise EAbort.Create('Synthetic cancellation callback error');
        end);
    except
      on E: EAbort do
        Raised := E.Message = 'Synthetic cancellation callback error';
    end;
    Check(Raised, 'callback exception is rethrown across COM boundary');
    Check(Length(Items) = 0, 'callback exception has no partial output');
  finally
    Input.Free;
  end;
end;

procedure RunTests;
var
  Text, Prefix, DeepXML: string;
  Encoding1251: TEncoding;
  Bytes, Tail: TBytes;
  I: Integer;
begin
  Text := Metadata('<sequence name="' + CYRILLIC_TITLE + ' &amp; &lt;test&gt; &quot;quoted&quot;" number="17"/>');
  Run('UTF-8', Encoded(Text, TEncoding.UTF8), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Run('UTF-8 BOM', Encoded(Text, TEncoding.UTF8, True), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  for I := 1 to 4 do
    Run('UTF8 declaration alias fragmented ' + IntToStr(I),
      Encoded('<?xml version="1.0" encoding = ''UTF8''?>' + Text, TEncoding.UTF8),
      fmsComplete, 1, CYRILLIC_TITLE + ' & <test> "quoted"', 17, I);
  RunText('UTF8 alias does not hide malformed description',
    '<?xml version="1.0" encoding="UTF8"?><FictionBook><description><title-info></description>', fmsInvalid);
  RunText('unknown encoding is not guessed',
    '<?xml version="1.0" encoding="unrecognized-xyz"?>' + Text, fmsInvalid);
  Run('UTF8 alias does not hide invalid UTF-8 metadata',
    TEncoding.ASCII.GetBytes('<?xml version="1.0" encoding="UTF8"?><FictionBook><description><title-info>') +
    TBytes.Create($FF) + TEncoding.ASCII.GetBytes('</title-info></description>'), fmsInvalid, 0);
  Prefix := '<?xml version="1.0" encoding="UTF-16"?>';
  Run('UTF-16 LE', Encoded(Prefix + Text, TEncoding.Unicode, True), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Run('UTF-16 BE', Encoded(Prefix + Text, TEncoding.BigEndianUnicode, True), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  for I := 1 to 4 do
  begin
    Run('UTF-16 LE BOM overrides UTF-8 declaration ' + IntToStr(I),
      Encoded('<?xml version="1.0" encoding="UTF-8"?>' + Text,
        TEncoding.Unicode, True), fmsComplete, 1,
      CYRILLIC_TITLE + ' & <test> "quoted"', 17, I);
    Run('UTF-16 BE BOM overrides UTF-8 declaration ' + IntToStr(I),
      Encoded('<?xml version="1.0" encoding="UTF-8"?>' + Text,
        TEncoding.BigEndianUnicode, True), fmsComplete, 1,
      CYRILLIC_TITLE + ' & <test> "quoted"', 17, I);
  end;
  Run('UTF-8 BOM overrides windows-1251 declaration',
    Encoded('<?xml version="1.0" encoding="windows-1251"?>' + Text,
      TEncoding.UTF8, True), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17, 1);
  Run('UTF-16 BOM override with large unread body',
    Encoded('<?xml version="1.0" encoding="UTF-8"?>' + Text,
      TEncoding.Unicode, True), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17, MaxInt, -1, 64 * 1024 * 1024);
  Run('BOM override does not hide malformed metadata',
    Encoded('<?xml version="1.0" encoding="UTF-8"?>' +
      '<FictionBook><description><title-info></description>',
      TEncoding.Unicode, True), fmsInvalid, 0);
  Run('reuse without BOM after override', Encoded(Text, TEncoding.UTF8),
    fmsComplete, 1, CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Encoding1251 := TEncoding.GetEncoding(1251);
  try
    Run('Windows-1251', Encoded('<?xml version="1.0" encoding="windows-1251"?>' +
      Text, Encoding1251), fmsComplete, 1, CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  finally
    Encoding1251.Free;
  end;
  for I := 1 to 4 do
    Run('fragmented UTF-8 ' + IntToStr(I), Encoded(Text, TEncoding.UTF8),
      fmsComplete, 1, CYRILLIC_TITLE + ' & <test> "quoted"', 17, I);
  Run('fragmented UTF-16', Encoded(Prefix + Text, TEncoding.Unicode, True),
    fmsComplete, 1, CYRILLIC_TITLE + ' & <test> "quoted"', 17, 1);
  RunText('no publisher info', '<FictionBook><description><title-info/></description>', fmsComplete);
  RunText('empty publisher info', Metadata(''), fmsComplete);
  RunText('description-only FBD', Metadata('<sequence name="FBD"/>') + '</FictionBook>', fmsComplete, 1, 'FBD');
  RunText('namespace prefix', '<fb:FictionBook xmlns:fb="' + FB2_NS + '">' +
    '<fb:description><fb:title-info/><fb:publish-info><fb:sequence name="Prefix"/>' +
    '</fb:publish-info></fb:description>', fmsComplete, 1, 'Prefix');
  RunText('FB2 namespace 2.1', StringReplace(Metadata('<sequence name="Version 2.1" number="8"/>'),
    FB2_NS, 'http://www.gribuser.ru/xml/fictionbook/2.1', []), fmsComplete, 1, 'Version 2.1', 8);
  RunText('FB2 namespace 2.2', StringReplace(Metadata('<sequence name="Version 2.2" number="9"/>'),
    FB2_NS, 'http://www.gribuser.ru/xml/fictionbook/2.2', []), fmsComplete, 1, 'Version 2.2', 9);
  RunText('converter resets description namespace', StringReplace(Metadata('<sequence name="Reset" number="6"/>'),
    '<description>', '<description xmlns="">', []), fmsComplete, 1, 'Reset', 6);
  RunText('converter resets publish-info namespace', StringReplace(Metadata('<sequence name="Reset publish"/>'),
    '<publish-info>', '<publish-info xmlns="">', []), fmsComplete, 1, 'Reset publish');
  RunText('namespace reset does not accept foreign sequence',
    StringReplace(Metadata('<sequence xmlns="urn:wrong" name="Ignore"/>'),
    '<description>', '<description xmlns="">', []), fmsComplete, 0);
  RunText('namespace reset does not hide malformed XML',
    '<FictionBook xmlns="' + FB2_NS + '"><description xmlns=""><title-info></description>', fmsInvalid);
  RunText('unknown FB2 namespace stays invalid', '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.20">' +
    '<description><title-info/></description>', fmsInvalid);
  RunText('wrong root', '<Book><description><title-info/></description></Book>', fmsInvalid);
  RunText('wrong namespace', '<FictionBook xmlns="urn:wrong"><description><title-info/></description>', fmsInvalid);
  RunText('foreign description', '<FictionBook><description xmlns="urn:wrong"><title-info/></description></FictionBook>', fmsInvalid);
  RunText('missing title-info', '<FictionBook><description><publish-info/></description>', fmsInvalid);
  RunText('foreign title-info', '<FictionBook><description><title-info xmlns="urn:wrong"/></description>', fmsInvalid);
  RunText('empty stream', '', fmsInvalid);
  Run('single BOM byte', TBytes.Create($FF), fmsInvalid, 0, '', 0, 1);
  Run('UTF-16 BOM only', TBytes.Create($FF, $FE), fmsInvalid, 0, '', 0, 1);
  Run('UTF-8 BOM only', TBytes.Create($EF, $BB, $BF), fmsInvalid, 0, '', 0, 1);
  Run('UTF-32 is not mistaken for UTF-16', TBytes.Create($FF, $FE, 0, 0,
    $3C, 0, 0, 0), fmsInvalid, 0, '', 0, 1);
  RunText('truncated description', '<FictionBook><description><title-info/>', fmsInvalid);
  RunText('malformed description', '<FictionBook><description><title-info></description>', fmsInvalid);
  RunText('malformed description after publisher sequence', '<FictionBook><description>' +
    '<title-info/><publish-info><sequence name="Partial"/></publish-info><bad></description>', fmsInvalid);
  RunText('unknown entity', Metadata('<sequence name="&unknown;"/>'), fmsInvalid);
  RunText('invalid attribute character', Metadata('<sequence name="bad<name"/>'), fmsInvalid);
  RunText('DTD internal rejected', '<!DOCTYPE FictionBook [<!ENTITY x "name">]>' +
    Metadata('<sequence name="&x;"/>'), fmsInvalid);
  RunText('DTD external rejected', '<!DOCTYPE FictionBook SYSTEM "file:///C:/must-not-be-read.dtd">' + Text, fmsInvalid);
  RunText('DTD network rejected', '<!DOCTYPE FictionBook SYSTEM "http://127.0.0.1:9/must-not-connect.dtd">' + Text, fmsInvalid);
  RunText('missing description before body', '<FictionBook><body>' + StringOfChar('x', 16000), fmsNoMetadata);
  RunText('absent description in closed root', '<FictionBook/>', fmsNoMetadata);
  RunText('malformed body ignored', Text + '<body><p>broken &unknown; <tag></body>', fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  RunText('XML lookalikes in comments CDATA PI', '<FictionBook><!-- </description> -->' +
    '<description><title-info><annotation><![CDATA[</description><body>]]></annotation>' +
    '</title-info><?test description?><publish-info><sequence name="Real"/>' +
    '</publish-info></description>', fmsComplete, 1, 'Real');
  Bytes := Encoded(Text, TEncoding.UTF8);
  Tail := TBytes.Create($FF, $C0, $00);
  Run('invalid UTF-8 immediately after description', Bytes + Tail, fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Bytes := Encoded(Prefix + Text, TEncoding.Unicode, True);
  Tail := TBytes.Create($00, $D8, $00);
  Run('invalid UTF-16 LE immediately after description', Bytes + Tail, fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Bytes := Encoded(Prefix + Text, TEncoding.BigEndianUnicode, True);
  Tail := TBytes.Create($D8, $00, $00);
  Run('invalid UTF-16 BE immediately after description', Bytes + Tail, fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17);
  Run('64 MiB body stays unread', Encoded(Text, TEncoding.UTF8), fmsComplete, 1,
    CYRILLIC_TITLE + ' & <test> "quoted"', 17, MaxInt, -1, 64 * 1024 * 1024);
  Run('canceled before reading', Encoded(Text, TEncoding.UTF8), fmsCanceled, 0, '', 0, MaxInt, 0);
  Run('canceled during fragmented BOM', Encoded(Prefix + Text,
    TEncoding.Unicode, True), fmsCanceled, 0, '', 0, 1, 1);
  Run('canceled during description', Encoded('<FictionBook><description><title-info>' +
    StringOfChar(' ', 32000) + '</title-info><publish-info><sequence name="Never"/>' +
    '</publish-info></description>', TEncoding.UTF8), fmsCanceled, 0, '', 0, 8192, 8192);
  Run('canceled after publisher sequence', Encoded('<FictionBook><description><title-info/>' +
    '<publish-info><sequence name="Partial"/></publish-info><custom-info>' +
    StringOfChar(' ', 32000) + '</custom-info></description>', TEncoding.UTF8),
    fmsCanceled, 0, '', 0, 8192, 8192);
  RunText('prefix limit', '<FictionBook><description><title-info>' +
    StringOfChar(' ', FB2_METADATA_MAX_BYTES) + '</title-info></description>', fmsInvalid);
  DeepXML := '<FictionBook><description><title-info>';
  for I := 4 to FB2_METADATA_MAX_DEPTH do
    DeepXML := DeepXML + '<p>';
  for I := 4 to FB2_METADATA_MAX_DEPTH do
    DeepXML := DeepXML + '</p>';
  RunText('depth 256 allowed', DeepXML + '</title-info></description>', fmsComplete);
  RunText('depth 257 rejected', StringReplace(DeepXML, '<title-info>',
    '<title-info><p>', []) + '</p></title-info></description>', fmsInvalid);
  CheckSeriesDetails;
  CheckCurrentPosition;
  CheckExceptions;
  RunText('reuse after errors and cancellation', Metadata('<sequence name="Final" number="2"/>'), fmsComplete, 1, 'Final', 2);
end;

procedure CheckRecovery;
var
  XML, Broken: string;
  I: Integer;
  CP1251: TEncoding;
begin
  XML := Metadata('<sequence name="' + CYRILLIC_TITLE + ' & Palm" number="26"/>');
  for I := 1 to 4 do
  begin
    Run('recover bare amp UTF8 fragment ' + IntToStr(I), Encoded(XML, TEncoding.UTF8),
      fmsComplete, 1, CYRILLIC_TITLE + ' & Palm', 26, I);
    Run('recover bare amp UTF16 fragment ' + IntToStr(I),
      Encoded('<?xml version="1.0" encoding="UTF8"?>' + XML, TEncoding.Unicode, True),
      fmsComplete, 1, CYRILLIC_TITLE + ' & Palm', 26, I);
  end;
  Run('recovery keeps large body unread', Encoded(XML, TEncoding.UTF8),
    fmsComplete, 1, CYRILLIC_TITLE + ' & Palm', 26, MaxInt, -1, 64 * 1024 * 1024);
  CP1251 := TEncoding.GetEncoding(1251);
  try
    Run('recovery windows1251 preserves title',
      Encoded('<?xml version="1.0" encoding="windows-1251"?>' + XML, CP1251),
      fmsComplete, 1, CYRILLIC_TITLE + ' & Palm', 26, 1);
  finally CP1251.Free; end;
  RunText('recover known entity missing semicolon', Metadata('<sequence name="A &amp B" number="3"/>'),
    fmsComplete, 1, 'A & B', 3);
  RunText('recover annotation formatting only', '<FictionBook><description><title-info>' +
    '<annotation><p>text<strong>words</annotation></title-info><publish-info>' +
    '<sequence name="Keep exact name" number="9"/></publish-info></description>',
    fmsComplete, 1, 'Keep exact name', 9);
  RunText('recover image missing greater', '<FictionBook><description><title-info>' +
    '<coverpage><image href="#cover" /</coverpage></title-info><publish-info>' +
    '<sequence name="Cover"/></publish-info></description>', fmsComplete, 1, 'Cover');
  RunText('recover annotation closing greater', '<FictionBook><description><title-info>' +
    '<annotation><p>text</p></annotation <date>2000</date></title-info><publish-info>' +
    '<sequence name="Date"/></publish-info></description>', fmsComplete, 1, 'Date');
  RunText('recover joined language and empty line', '<FictionBook><description><title-info>' +
    '<langru</lang></title-info><document-info><empty-line/' + #13#10 +
    '<nickname>author</nickname</document-info><publish-info><sequence name="Language"/>' +
    '</publish-info></description>', fmsComplete, 1, 'Language');
  RunText('recover standard undeclared image link', '<FictionBook><description><title-info>' +
    '<coverpage><image l:href="#cover"/></coverpage></title-info><publish-info>' +
    '<sequence name="Image"/></publish-info></description>', fmsComplete, 1, 'Image');
  RunText('existing foreign link namespace unchanged', '<FictionBook xmlns:l="urn:foreign">' +
    '<description><title-info><coverpage><image l:href="#cover"/></coverpage></title-info>' +
    '<publish-info><sequence name="Image"/></publish-info></description>', fmsComplete, 1, 'Image');
  RunText('recover exact escaped description boundary', StringReplace(Metadata('<sequence name="Boundary"/>'),
    '</description>', '&lt;/description&gt;<body>', []), fmsComplete, 1, 'Boundary');
  RunText('do not invent absent description closing', Metadata('<sequence name="Partial"/>').Replace(
    '</description>', '<body>'), fmsInvalid);
  RunText('escaped example in annotation is not markup', '<FictionBook><description><title-info>' +
    '<annotation>&lt;/description&gt;<body/></annotation></title-info>', fmsInvalid);
  RunText('CDATA escaped example is not markup', '<FictionBook><description><title-info>' +
    '<annotation><![CDATA[&lt;/description&gt;<body>]]></annotation></title-info>', fmsInvalid);
  RunText('recover typo XML version', '<?xml version="1.01" encoding="UTF-8"?>' +
    Metadata('<sequence name="Version" number="8"/>'), fmsComplete, 1, 'Version', 8);
  RunText('unknown XML version not guessed', '<?xml version="1.2"?>' +
    Metadata('<sequence name="Version"/>'), fmsInvalid);
  RunText('namespace typo 2.01', Metadata('<sequence name="Namespace"/>').Replace(
    FB2_NS, 'http://www.gribuser.ru/xml/fictionbook/2.01'), fmsComplete, 1, 'Namespace');
  RunText('recognized mixed namespace', '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.1">' +
    '<description xmlns="' + FB2_NS + '"><title-info/><publish-info>' +
    '<sequence name="Mixed" number="4"/><sequence xmlns="urn:foreign" name="Ignored"/>' +
    '</publish-info></description>', fmsComplete, 1, 'Mixed', 4);
  RunText('binary before metadata', '<FictionBook><binary id="cover">AAAA</binary>' +
    '<description><title-info/><publish-info><sequence name="Binary"/></publish-info></description>',
    fmsComplete, 1, 'Binary');
  Broken := '<FictionBook><description><title-info><annotation><p>oops</annotation>' +
    '</title-info><publish-info><sequence name="Partial"><bad/></publish-info></description>';
  RunText('repair does not guess sequence container', Broken, fmsInvalid);
  Run('invalid UTF8 not hidden by repair', TEncoding.UTF8.GetBytes('<FictionBook><description><title-info>') +
    TBytes.Create($FF) + TEncoding.UTF8.GetBytes('</title-info><publish-info>' +
    '<sequence name="A & B"/></publish-info></description>'), fmsInvalid, 0);
  Run('cancel while recovery reads fragmented prefix', Encoded(XML, TEncoding.UTF8),
    fmsCanceled, 0, '', 0, 1, Length(XML)-10);
  RunText('reuse after recovered and unrecoverable metadata', Metadata('<sequence name="After" number="2"/>'),
    fmsComplete, 1, 'After', 2);
  Check(Reader.LastRecoveryDetails = '', 'reuse clears prior recovery details');
end;

procedure CheckFiles;
var
  I: Integer;
  Input: TFileStream;
  Items: TFB2PublisherSeries;
  ErrorText: string;
  Expected, Actual: TFB2MetadataStatus;
  Recorded: TRecordedMetadataStream;
  Retry: TStringStream;
  XML, Details: string;
  Canceled: Boolean;
begin
  I := 1;
  while I <= ParamCount do
  begin
    Expected := fmsComplete;
    if ParamStr(I) = '--invalid-file' then
    begin Expected := fmsInvalid; Inc(I); end;
    if I > ParamCount then raise EArgumentException.Create('Missing file after option');
    Input := TFileStream.Create(ParamStr(I), fmOpenRead or fmShareDenyNone);
    try
      Actual := Reader.Read(Input, Items, ErrorText);
      Check(Actual = Expected,
        'file metadata: ' + ExtractFileName(ParamStr(I)));
      if ErrorText <> '' then
        Report.Add('  Diagnostic: ' + ErrorText);
      Report.Add(Format('  Read %d of %d bytes; %d publisher series',
        [Input.Position, Input.Size, Length(Items)]));
      if Reader.LastRecoveryDetails <> '' then
        Report.Add('  Recovered: ' + Reader.LastRecoveryDetails);
      if (Actual <> Expected) and (Expected = fmsComplete) then
      begin
        Input.Position := 0;
        Recorded := TRecordedMetadataStream.Create(Input, FB2_METADATA_MAX_BYTES);
        try
          // Seed the bounded prefix without a parser, for failure diagnostics.
          SetLength(Items, 0);
          Reader.Read(Recorded, Items, ErrorText);
          if RecoverMetadataPrefix(Recorded, FB2_METADATA_MAX_BYTES,
            FB2_METADATA_MAX_DEPTH, nil, XML, Details, Canceled) then
          begin
            Report.Add('  Recovery candidate: ' + Details);
            Retry := TStringStream.Create(XML, TEncoding.UTF8);
            try
              Actual := Reader.Read(Retry, Items, ErrorText);
              Report.Add('  Candidate status: ' + IntToStr(Ord(Actual)) + ' ' + ErrorText);
            finally Retry.Free; end;
          end
          else Report.Add('  No complete recovery candidate');
        finally Recorded.Free; end;
      end;
    finally
      Input.Free;
    end;
    Inc(I);
  end;
end;

var
  ComInitialized: Boolean;
begin
  Report := TStringList.Create;
  ComInitialized := False;
  try
    try
      OleCheck(CoInitializeEx(nil, COINIT_APARTMENTTHREADED));
      ComInitialized := True;
      Reader := TFB2PublisherMetadataReader.Create;
      RunTests;
      CheckRecovery;
      CheckFiles;
    except
      on E: Exception do
      begin
        Inc(Failures);
        Report.Add('FATAL ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    Reader.Free;
    if ComInitialized then
      CoUninitialize;
    Report.Add(Format('RESULT %d checks, %d failures', [Checks, Failures]));
    Report.SaveToFile(ChangeFileExt(ParamStr(0), '.log'), TEncoding.UTF8);
    Write(Report.Text);
    ExitCode := Ord(Failures <> 0);
  finally
    Report.Free;
  end;
end.
