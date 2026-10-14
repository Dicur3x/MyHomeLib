// Decoder boundaries are probes only. Malformed metadata must never acquire
// invented Unicode or a changed series name; closed metadata ignores the body.
type
  TMPBoundedSource = class(TStream)
  private
    FBytes: TBytes;
    FConsumed, FFragment, FReads, FSeeks, FWrites: Integer;
  public
    FailReads: Boolean;
    constructor Create(const Bytes: TBytes; Fragment: Integer);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    function BytesHash: string;
    property Consumed: Integer read FConsumed;
    property Reads: Integer read FReads;
    property Seeks: Integer read FSeeks;
    property Writes: Integer read FWrites;
  end;

function MPBytesHash(const Bytes: TBytes): string;
var Stream: TBytesStream;
begin
  Stream:=TBytesStream.Create(Bytes);
  try Result:=THashSHA2.GetHashString(Stream); finally Stream.Free; end;
end;

constructor TMPBoundedSource.Create(const Bytes: TBytes; Fragment: Integer);
begin
  inherited Create; FBytes:=Copy(Bytes,0,Length(Bytes)); FFragment:=Fragment;
end;

function TMPBoundedSource.Read(var Buffer; Count: Longint): Longint;
begin
  Inc(FReads); if FailReads then raise EStreamError.Create('Private metadata fixture read failure');
  Result:=Min(Max(0,Count),Min(FFragment,Length(FBytes)-FConsumed));
  if Result>0 then begin Move(FBytes[FConsumed],Buffer,Result); Inc(FConsumed,Result); end;
end;

function TMPBoundedSource.Write(const Buffer; Count: Longint): Longint;
begin Inc(FWrites); raise EStreamError.Create('Private metadata fixture is read-only'); end;

function TMPBoundedSource.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin Inc(FSeeks); raise EStreamError.Create('Private metadata fixture is not seekable'); end;

function TMPBoundedSource.BytesHash: string;
begin Result:=MPBytesHash(FBytes); end;

procedure TestMetadataPrefixBounds;
const
  NS='http://www.gribuser.ru/xml/fictionbook/2.0';
  ExpectedID='PREFIX_ORIGINAL_A';
  SeriesTitle='Серия ё, ї, ў '+#$D83D+#$DE00+' '+#$FFFD;
var
  UnicodeTitle, GrowingTitle, Head, Body, ProfileHash, ProfileFile: string;
  Bytes, Bad, Prefix, Suffix, Good: TBytes;
  Encoding: TEncoding;
  Checks, PrefixBytes, Pad, Partial, E, B, V: Integer;

  function MetadataHead(const Title, SequenceName, Declaration: string): string;
  begin
    Result:=Declaration+'<FictionBook xmlns="'+NS+'"><description><title-info>'+
      '<genre>prose_contemporary</genre><author><first-name>Own</first-name><last-name>Probe</last-name></author>'+
      '<book-title>'+Title+'</book-title><lang>ru</lang><sequence name="'+SequenceName+'" number="3"/>'+
      '</title-info><document-info><author><first-name>Own</first-name><last-name>Probe</last-name></author>'+
      '<program-used>Native prefix fixture</program-used><date value="2026-10-14">2026-10-14</date>'+
      '<id>'+ExpectedID+'</id><version>1.0</version></document-info></description>';
  end;

  function Encode(const Text: string; Enc: TEncoding; BOM: Boolean): TBytes;
  begin
    Result:=Enc.GetBytes(Text); if BOM then Result:=Enc.GetPreamble+Result;
  end;

  procedure VerifyBook(Book: IXMLFictionBook; const Title, LabelText: string);
  begin
    Require(Book.Description.Titleinfo.Booktitle.Text=Title,LabelText+': book title changed');
    Require((Book.Description.Documentinfo.Id=ExpectedID) and
      (Book.Description.Documentinfo.Version='1.0'),LabelText+': stable document metadata changed');
    Require((Book.Description.Titleinfo.Sequence.Count=1) and
      (Book.Description.Titleinfo.Sequence[0].Name=SeriesTitle) and
      (Book.Description.Titleinfo.Sequence[0].Number=3),LabelText+': Unicode series name/number changed');
    Require(Book.Description.Publishinfo.Year='',LabelText+': missing optional publish-info was invented');
  end;

  procedure Probe(const LabelText: string; const Data: TBytes; Seed, Fragment, Limit: Integer;
    WantSuccess, NoGrowth: Boolean; const Title: string; CancelAt: Integer=0);
  var Source: TMPBoundedSource; Recorded: TRecordedMetadataStream; Stream: TStringStream;
    Buffer: array[0..8191] of Byte; Count, ReadCalls, Consumed: Integer; XML, Details, BeforeHash: string;
    WasCanceled, Recovered: Boolean; Book: IXMLFictionBook;
  begin
    Source:=TMPBoundedSource.Create(Data,Fragment);
    try
    Recorded:=TRecordedMetadataStream.Create(Source,Limit);
    try
      BeforeHash:=Source.BytesHash;
      repeat
        Count:=Recorded.Read(Buffer,Min(SizeOf(Buffer),Seed-Integer(Recorded.Captured.Size)));
      until (Count=0) or (Recorded.Captured.Size>=Seed);
      ReadCalls:=Source.Reads; Consumed:=Source.Consumed;
      Recovered:=RecoverMetadataPrefix(Recorded,Limit,64,
        function: Boolean begin Result:=(CancelAt>0) and (Source.Consumed>=CancelAt); end,
        XML,Details,WasCanceled,True);
      Require(Recovered=WantSuccess,LabelText+': wrong recovery outcome '+BoolToStr(Recovered,True));
      Require(WasCanceled=(CancelAt>0),LabelText+': cancellation flag changed');
      Require(Source.Consumed<=Limit,LabelText+': read exceeded the metadata byte limit');
      Require((Source.Seeks=0) and (Source.Writes=0),LabelText+': recovery sought/wrote the borrowed source');
      Require(Source.BytesHash=BeforeHash,LabelText+': source bytes changed');
      if NoGrowth then Require((Source.Consumed=Consumed) and (Source.Reads=ReadCalls),
        LabelText+': complete metadata unnecessarily read more body bytes');
      if WantSuccess then
      begin
        if not NoGrowth then Require(Source.Consumed>Consumed,LabelText+': growth/fragmented path was not exercised');
        Require(Details='',LabelText+': valid metadata was spuriously repaired');
        Stream:=TStringStream.Create(XML,TEncoding.UTF8);
        try Book:=LoadFictionBook(Stream); VerifyBook(Book,Title,LabelText); finally Book:=nil; Stream.Free; end;
      end;
      Consumed:=Source.Consumed;
    finally Recorded.Free; end;
      // The recording wrapper neither owns nor repositions its borrowed stream.
      if Consumed<Length(Data) then
      begin
        Require(Source.Read(Buffer,1)=1,LabelText+': borrowed stream was closed by recovery');
        Require(Buffer[0]=Data[Consumed],LabelText+': next unread source byte was lost/replayed');
      end;
    finally Source.Free; end;
    Inc(Checks);
  end;

  procedure Caller(const LabelText: string; const Data: TBytes; const Title: string; WantSuccess: Boolean);
  var Stream: TBytesStream; BeforeHash: string; Book: IXMLFictionBook; Rejected: Boolean;
  begin
    Stream:=TBytesStream.Create(Data); BeforeHash:=MPBytesHash(Data); Rejected:=False;
    try
      try
        Book:=LoadFB2Description(Stream,False);
      except
        on E: Exception do
        begin
          if WantSuccess then raise;
          Rejected:=True;
        end;
      end;
      if WantSuccess then VerifyBook(Book,Title,LabelText)
      else Require(Rejected and not Assigned(Book),LabelText+': public description parser did not fail closed');
      Require(Stream.Position=Min(8192,Length(Data)),LabelText+': public parser consumed full body or lost position');
      Require(MPBytesHash(Data)=BeforeHash,LabelText+': public parser changed source bytes');
    finally Book:=nil; Stream.Free; end;
    Inc(Checks);
  end;

  procedure UTF8Split(const Symbol: string; BOM: Boolean; Part: Integer);
  var Data, Leading: TBytes; LabelText: string;
  begin
    Leading:=Encode(MetadataHead(UnicodeTitle,SeriesTitle,'<?xml version="1.0" encoding="UTF-8"?>')+
      '<body><section><p>',TEncoding.UTF8,BOM);
    Pad:=8192-Part-Length(Leading); Require(Pad>0,'UTF8 split fixture prefix is too large');
    Data:=Leading+TEncoding.UTF8.GetBytes(StringOfChar('a',Pad)+Symbol+Body);
    Require(Length(Data)>8192,'UTF8 split fixture did not extend beyond SAX chunk');
    LabelText:=Format('UTF8 body split BOM=%d bytes=%d partial=%d',[Ord(BOM),Length(TEncoding.UTF8.GetBytes(Symbol)),Part]);
    Probe(LabelText,Data,8192,MaxInt,65536,True,True,UnicodeTitle);
    Caller(LabelText,Data,UnicodeTitle,True);
  end;

begin
  RequireIsolatedRegression; Checks:=0;
  ProfileFile:=Settings.SettingsFileName; ProfileHash:='';
  if FileExists(ProfileFile) then ProfileHash:=THashSHA2.GetHashStringFromFile(ProfileFile);
  UnicodeTitle:='Граница ё, ї, ў '+#$D83D+#$DE00+' '+#$FFFD;
  Body:=StringOfChar('z',32768)+'</p></section></body></FictionBook>';
  for B:=0 to 1 do
  begin
    UTF8Split('т',B=1,1);
    for Partial:=1 to 2 do UTF8Split('€',B=1,Partial);
    for Partial:=1 to 3 do UTF8Split(#$D83D+#$DE00,B=1,Partial);
  end;
  Writeln('PASS metadata prefix UTF8 all two-three-four-byte body splits, BOM and public parser, no extra body reads');

  Head:=MetadataHead(UnicodeTitle,SeriesTitle,'<?xml version="1.0" encoding="UTF-8"?>');
  Good:=Encode(Head+'<body><section><p>',TEncoding.UTF8,True);
  Bad:=TBytes.Create($FF,$C0,$AF,$ED,$A0,$80,$F4,$90,$80,$80,$D1);
  Bytes:=Good+Bad+TEncoding.UTF8.GetBytes(Body);
  Probe('UTF8 damaged body',Bytes,8192,MaxInt,65536,True,True,UnicodeTitle);
  Caller('UTF8 damaged body',Bytes,UnicodeTitle,True);
  Probe('UTF8 fragmented closed description',Bytes,8192,17,65536,True,True,UnicodeTitle);
  Writeln('PASS metadata prefix closed Unicode metadata ignores malformed body, exact legal replacement character and series preserved');

  for E:=0 to 1 do
  begin
    if E=0 then Encoding:=TEncoding.Unicode else Encoding:=TEncoding.BigEndianUnicode;
    Head:=MetadataHead(UnicodeTitle,SeriesTitle,'<?xml version="1.0" encoding="UTF-16"?>')+'<body><section><p>';
    Good:=Encode(Head,Encoding,True);
    Require((Length(Good) mod 2=0) and (Length(Good)<8190),'UTF16 split prefix is invalid');
    Pad:=(8190-Length(Good)) div 2;
    Bytes:=Good+Encoding.GetBytes(StringOfChar('a',Pad)+'т'+Body);
    Probe('UTF16 odd tail '+IntToStr(E),Bytes,8191,MaxInt,65536,True,True,UnicodeTitle);
    Bytes:=Good+Encoding.GetBytes(StringOfChar('a',Pad)+#$D83D+#$DE00+Body);
    Probe('UTF16 body split surrogate '+IntToStr(E),Bytes,8192,MaxInt,65536,True,True,UnicodeTitle);
    Caller('UTF16 body split surrogate '+IntToStr(E),Bytes,UnicodeTitle,True);
    if E=0 then Bad:=TBytes.Create($00,$D8,$00,$DC,$00,$D8,$00)
    else Bad:=TBytes.Create($D8,$00,$DC,$00,$D8,$00,$00);
    Bytes:=Good+Bad+Encoding.GetBytes(Body);
    Probe('UTF16 damaged body '+IntToStr(E),Bytes,8191,MaxInt,65536,True,True,UnicodeTitle);
    // LE ends at the first byte of the high surrogate inside an unfinished
    // title; BE ends after its complete high unit. Neither may lose the tail
    // when fragmented growth supplies the missing bytes and closing metadata.
    Head:=MetadataHead('',SeriesTitle,'<?xml version="1.0" encoding="UTF-16"?>');
    PrefixBytes:=Pos('<book-title>',Head)+Length('<book-title>')-1;
    Head:=Copy(Head,1,PrefixBytes);
    Pad:=(8190-Length(Encode(Head,Encoding,True))) div 2;
    Require(Pad>0,'UTF16 growing metadata prefix is too large');
    GrowingTitle:=StringOfChar('a',Pad)+#$D83D+#$DE00+StringOfChar('b',1000)+' ё '+#$FFFD;
    Bytes:=Encode(MetadataHead(GrowingTitle,SeriesTitle,'<?xml version="1.0" encoding="UTF-16"?>')+
      '<body><section><p>'+Body,Encoding,True);
    Probe('UTF16 fragmented split inside metadata '+IntToStr(E),Bytes,
      8191+E,13,65536,True,False,GrowingTitle);
  end;
  Writeln('PASS metadata prefix UTF16 LE-BE odd byte and split surrogate remain body-only, source position exact');

  Head:=MetadataHead(UnicodeTitle,'SAFE_MARKER','<?xml version="1.0" encoding="UTF-8"?>');
  V:=Pos('SAFE_MARKER',Head); Require(V>0,'Mutation marker is absent');
  Prefix:=Encode(Copy(Head,1,V-1),TEncoding.UTF8,True);
  Suffix:=TEncoding.UTF8.GetBytes(Copy(Head,V+Length('SAFE_MARKER'),MaxInt)+'<body><section><p>'+Body);
  // Deterministic byte-property probes: every orphan continuation and all
  // truncated UTF8 lead classes are inside metadata, never in the body.
  for V:=$80 to $BF do
    Probe('UTF8 orphan metadata '+IntToHex(V,2),Prefix+TBytes.Create(V)+Suffix,
      8192,MaxInt,65536,False,True,'');
  for V:=$C2 to $F4 do
    Probe('UTF8 incomplete metadata '+IntToHex(V,2),Prefix+TBytes.Create(V)+Suffix,
      8192,MaxInt,65536,False,True,'');
  for V:=0 to 5 do
  begin
    case V of
      0: Bad:=TBytes.Create($FF);
      1: Bad:=TBytes.Create($C0,$AF);
      2: Bad:=TBytes.Create($E0,$80,$AF);
      3: Bad:=TBytes.Create($ED,$A0,$80);
      4: Bad:=TBytes.Create($F4,$90,$80,$80);
    else Bad:=TBytes.Create($F5,$80,$80,$80); end;
    Bytes:=Prefix+Bad+Suffix;
    Probe('UTF8 illegal metadata '+IntToStr(V),Bytes,8192,MaxInt,65536,False,True,'');
    Caller('UTF8 illegal metadata '+IntToStr(V),Bytes,'',False);
  end;
  Writeln('PASS metadata prefix 121 deterministic UTF8 corruption probes fail closed without changing series metadata');

  for E:=0 to 1 do
  begin
    if E=0 then Encoding:=TEncoding.Unicode else Encoding:=TEncoding.BigEndianUnicode;
    Head:=MetadataHead(UnicodeTitle,'SAFE_MARKER','<?xml version="1.0" encoding="UTF-16"?>');
    V:=Pos('SAFE_MARKER',Head);
    Prefix:=Encode(Copy(Head,1,V-1),Encoding,True);
    Suffix:=Encoding.GetBytes(Copy(Head,V+Length('SAFE_MARKER'),MaxInt)+'<body><section><p>'+Body);
    for V:=0 to 3 do
    begin
      if E=0 then
        case V of
          0: Bad:=TBytes.Create($00,$D8);
          1: Bad:=TBytes.Create($00,$DC);
          2: Bad:=TBytes.Create($00,$D8,$61,$00);
        else Bad:=TBytes.Create($00,$DC,$00,$D8); end
      else
        case V of
          0: Bad:=TBytes.Create($D8,$00);
          1: Bad:=TBytes.Create($DC,$00);
          2: Bad:=TBytes.Create($D8,$00,$00,$61);
        else Bad:=TBytes.Create($DC,$00,$D8,$00); end;
      Bytes:=Prefix+Bad+Suffix;
      Probe(Format('UTF16 malformed metadata endian=%d kind=%d',[E,V]),Bytes,
        8192,MaxInt,65536,False,True,'');
      Caller(Format('UTF16 malformed metadata endian=%d kind=%d',[E,V]),Bytes,'',False);
    end;
  end;
  Writeln('PASS metadata prefix UTF16 malformed high-low-surrogate metadata rejected by recovery and public parser');

  Head:='<?xml version="1.0" encoding="UTF-8"?><FictionBook xmlns="'+NS+'"><description><title-info>'+
    '<genre>prose_contemporary</genre><author><first-name>Own</first-name><last-name>Probe</last-name></author><book-title>';
  Pad:=8191-Length(Encode(Head,TEncoding.UTF8,True)); Require(Pad>0,'Growing title prefix is too large');
  UnicodeTitle:=StringOfChar('a',Pad)+#$D83D+#$DE00+StringOfChar('b',1500)+' ё '+#$FFFD;
  Bytes:=Encode(MetadataHead(UnicodeTitle,SeriesTitle,'<?xml version="1.0" encoding="UTF-8"?>')+
    '<body><section><p>'+Body,TEncoding.UTF8,True);
  Probe('UTF8 split inside growing metadata',Bytes,8192,7,65536,True,False,UnicodeTitle);
  Probe('bounded metadata limit',Bytes,32,17,1024,False,False,'');
  Probe('cancel before probe',Bytes,8192,MaxInt,65536,False,True,'',1);
  Probe('cancel during fragmented growth',Bytes,16,17,65536,False,False,'',64);
  Writeln('PASS metadata prefix fragmented split inside metadata resumes exactly, byte bound and both cancellation paths preserved');

  var Source:=TMPBoundedSource.Create(Bytes,17);
  var Recorded:=TRecordedMetadataStream.Create(Source,65536);
  try
    var Buffer: array[0..31] of Byte; Recorded.Read(Buffer,16); Source.FailReads:=True;
    var Rejected:=False;
    try Recorded.Read(Buffer,16); except on E: EStreamError do Rejected:=True; end;
    Require(Rejected and Recorded.ReadFailed,'Read-failed fixture was not exercised');
    var Before:=Source.Consumed; var Calls:=Source.Reads; var XML,Details: string; var Canceled: Boolean;
    Require(not RecoverMetadataPrefix(Recorded,65536,64,nil,XML,Details,Canceled,True),
      'Metadata recovery ignored an earlier source read failure');
    Require((Source.Consumed=Before) and (Source.Reads=Calls) and
      (Source.Seeks=0) and (Source.Writes=0),'Read-failed recovery touched borrowed source');
  finally Recorded.Free; Source.Free; end;
  if ProfileHash<>'' then Require(THashSHA2.GetHashStringFromFile(ProfileFile)=ProfileHash,
    'Metadata-prefix fixture changed main settings/profile');
  Writeln('PASS metadata prefix failed stream untouched, source bytes ownership and main profile preserved checks=',Checks);
end;
