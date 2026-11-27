unit unit_ReaderRTF;

interface

uses System.SysUtils, System.Types;

type
  TRtfPictureFormat = (rpfUnknown, rpfPNG, rpfJPEG, rpfDIB, rpfWMF, rpfEMF);
  TRtfPicture = record
    Bytes: TBytes;
    Format: TRtfPictureFormat;
    GoalWidth, GoalHeight, ScaleX, ScaleY: Integer;
    CropLeft, CropTop, CropRight, CropBottom: Integer;
    RuleBounds: TRect;
    RuleColor: Cardinal;
    PositionedLine: Boolean;
  end;

function PrepareReaderRTF(const Source: RawByteString; const AddPicture: TFunc<TRtfPicture, Boolean>;
  const MissingPicture: TProc<string>; const Canceled: TFunc<Boolean>;
  out PictureOffsets: TArray<Integer>; out HasTables: Boolean): RawByteString;
function ReaderDibAsBMP(const Dib: TBytes): TBytes;

implementation

uses System.Classes, System.Generics.Collections, System.Math, System.StrUtils,
  System.RegularExpressions, Winapi.Windows, Vcl.Imaging.pngimage;

function ReaderDibAsBMP(const Dib: TBytes): TBytes;
var Info: TBitmapInfoHeader; Header: TBitmapFileHeader; Colors: Cardinal; Offset: Int64;
begin
  Result:=nil;
  if Length(Dib)<SizeOf(Info) then Exit;
  Move(Dib[0],Info,SizeOf(Info));
  if (Info.biSize<SizeOf(Info)) or (Info.biSize>Cardinal(Length(Dib))) or
    not (Info.biBitCount in [1,4,8,16,24,32]) or
    not (Info.biCompression in [BI_RGB,BI_BITFIELDS]) then Exit;
  Colors:=Info.biClrUsed;
  if (Colors=0) and (Info.biBitCount<=8) then Colors:=1 shl Info.biBitCount;
  Offset:=Int64(Info.biSize)+Int64(Colors)*4;
  if (Info.biSize=SizeOf(Info)) and (Info.biCompression=BI_BITFIELDS) then Inc(Offset,12);
  if Offset>=Length(Dib) then Exit;
  FillChar(Header,SizeOf(Header),0);
  Header.bfType:=$4D42;
  Header.bfSize:=Length(Dib)+SizeOf(Header);
  Header.bfOffBits:=Offset+SizeOf(Header);
  SetLength(Result,Header.bfSize);
  Move(Header,Result[0],SizeOf(Header));
  Move(Dib[0],Result[SizeOf(Header)],Length(Dib));
end;

type
  TGroupKind = (rgNormal, rgHidden, rgPicture, rgPrimary, rgFallback, rgObject,
    rgObjectClass, rgObjectData, rgResult, rgShape, rgShapeGroup, rgShapeResult, rgShapeInstance, rgShapeText,
    rgShapeProperty, rgPropertyName, rgPropertyValue, rgField, rgFieldResult, rgLegacyDraw);
  TGroup = record
    First, Last, Next, Content: Integer;
    Kind: TGroupKind;
    ContainsGraphics: Boolean;
  end;

function PrepareReaderRTF(const Source: RawByteString; const AddPicture: TFunc<TRtfPicture, Boolean>;
  const MissingPicture: TProc<string>; const Canceled: TFunc<Boolean>;
  out PictureOffsets: TArray<Integer>; out HasTables: Boolean): RawByteString;
var Groups: TList<TGroup>;
  Offsets: TList<Integer>;
  Output: TMemoryStream;
  SourceLength, NextCheck: Integer;
  RuleShape, RulePicture: Integer;
  RuleBounds: TRect;
  RuleColor: Cardinal;

  procedure Check(Position: Integer);
  begin
    if Position<NextCheck then Exit;
    NextCheck:=Position+65536;
    if Assigned(Canceled) and Canceled() then Abort;
  end;

  procedure SkipSpace(var Position: Integer; Limit: Integer);
  begin
    while (Position<Limit) and (Source[Position] in [#9,#10,#13,' ']) do Inc(Position);
  end;

  procedure ReadControl(var Position: Integer; Limit: Integer; out Name: AnsiString;
    out Value: Integer; out HasValue: Boolean);
  var First, Sign, Digit: Integer; Magnitude, Maximum: Int64;
  begin
    Inc(Position);
    Name:=''; Value:=0; HasValue:=False;
    if Position>=Limit then raise EReadError.Create('Оборвана команда RTF.');
    if not (Source[Position] in ['a'..'z','A'..'Z']) then
    begin
      if Source[Position]='''' then Inc(Position,3) else Inc(Position);
      if Position>Limit then raise EReadError.Create('Оборвана команда RTF.');
      Exit;
    end;
    First:=Position;
    while (Position<Limit) and (Source[Position] in ['a'..'z','A'..'Z']) do Inc(Position);
    Name:=Copy(Source,First,Position-First);
    Sign:=1;
    if (Position+1<Limit) and (Source[Position]='-') and (Source[Position+1] in ['0'..'9']) then
    begin Sign:=-1; Inc(Position); end;
    Magnitude:=0; Maximum:=Int64(MaxInt)+Ord(Sign<0);
    while (Position<Limit) and (Source[Position] in ['0'..'9']) do
    begin
      HasValue:=True;
      Digit:=Ord(Source[Position])-Ord('0');
      if Magnitude>(Maximum-Digit) div 10 then raise EReadError.Create('Недопустимое число в RTF.');
      Magnitude:=Magnitude*10+Digit;
      Inc(Position);
    end;
    Value:=Integer(Magnitude*Sign);
    if (Position<Limit) and (Source[Position]=' ') then Inc(Position);
  end;

  procedure CheckBinary(Position, Limit, Count: Integer; HasValue: Boolean);
  begin
    if not HasValue or (Count<0) or (Count>Limit-Position) then
      raise EReadError.Create('Оборван двоичный блок RTF.');
  end;

  function GroupStart(Position: Integer): TGroup;
  var Name: AnsiString; Value: Integer; HasValue, Starred: Boolean;
  begin
    Result:=Default(TGroup);
    Result.First:=Position;
    Inc(Position);
    SkipSpace(Position,SourceLength+1);
    Starred:=(Position<SourceLength) and (Source[Position]='\') and (Source[Position+1]='*');
    if Starred then
    begin Inc(Position,2); SkipSpace(Position,SourceLength+1); end;
    Name:='';
    if (Position<=SourceLength) and (Source[Position]='\') then
      ReadControl(Position,SourceLength+1,Name,Value,HasValue);
    Result.Content:=Position;
    if Name='pict' then Result.Kind:=rgPicture
    else if Name='shppict' then Result.Kind:=rgPrimary
    else if Name='nonshppict' then Result.Kind:=rgFallback
    else if Name='object' then Result.Kind:=rgObject
    else if Name='objclass' then Result.Kind:=rgObjectClass
    else if Name='objdata' then Result.Kind:=rgObjectData
    else if Name='result' then Result.Kind:=rgResult
    else if Name='shp' then Result.Kind:=rgShape
    else if Name='shpgrp' then Result.Kind:=rgShapeGroup
    else if Name='shprslt' then Result.Kind:=rgShapeResult
    else if Name='shpinst' then Result.Kind:=rgShapeInstance
    else if Name='shptxt' then Result.Kind:=rgShapeText
    else if Name='sp' then Result.Kind:=rgShapeProperty
    else if Name='sn' then Result.Kind:=rgPropertyName
    else if Name='sv' then Result.Kind:=rgPropertyValue
    else if Name='field' then Result.Kind:=rgField
    else if Name='fldrslt' then Result.Kind:=rgFieldResult
    else if Name='do' then Result.Kind:=rgLegacyDraw
    else if Starred or MatchStr(string(Name),['fonttbl','colortbl','stylesheet','info',
      'header','footer','headerl','headerr','headerf','footerl','footerr','footerf',
      'footnote','annotation','fldinst']) then Result.Kind:=rgHidden;
  end;

  procedure ScanGroups;
  var Position, Index, Depth, Value: Integer; HasValue: Boolean;
    Ancestors: array[0..127] of Integer; Group: TGroup; Name: AnsiString;
  begin
    Position:=1;
    SkipSpace(Position,SourceLength+1);
    if Copy(Source,Position,5)<>'{\rtf' then raise EReadError.Create('Файл не является RTF.');
    Depth:=0;
    while Position<=SourceLength do
    begin
      Check(Position);
      case Source[Position] of
        '{': begin
          if (Depth=Length(Ancestors)) or (Groups.Count>=500000) then
            raise EReadError.Create('Слишком сложная структура RTF.');
          Ancestors[Depth]:=Groups.Add(GroupStart(Position));
          Inc(Depth); Inc(Position);
        end;
        '}': begin
          Dec(Depth);
          Index:=Ancestors[Depth];
          Group:=Groups[Index];
          Group.Last:=Position;
          Group.Next:=Groups.Count;
          Group.ContainsGraphics:=Group.ContainsGraphics or (Group.Kind in [rgPicture,rgObject,rgObjectData]);
          Groups[Index]:=Group;
          Inc(Position);
          if Depth=0 then Exit;
          if Group.ContainsGraphics then
          begin
            Index:=Ancestors[Depth-1];
            Group:=Groups[Index];
            Group.ContainsGraphics:=True;
            Groups[Index]:=Group;
          end;
        end;
        '\': begin
          ReadControl(Position,SourceLength+1,Name,Value,HasValue);
          if Name='bin' then
          begin CheckBinary(Position,SourceLength+1,Value,HasValue); Inc(Position,Value); end
          else if Name='trowd' then HasTables:=True;
        end;
      else
        Inc(Position);
      end;
    end;
    raise EReadError.Create('Оборвана группа RTF.');
  end;

  procedure WriteSource(First, Limit: Integer);
  begin
    if Limit>First then Output.WriteBuffer(Source[First],Limit-First);
  end;

  procedure WriteLiteral(const Text: AnsiString);
  begin
    if Text<>'' then Output.WriteBuffer(Text[1],Length(Text));
  end;

  procedure WriteMissing(const Detail: string);
  begin
    MissingPicture(Detail);
    WriteLiteral('{\uc1');
    for var Ch in '['+Detail+']' do
      WriteLiteral(AnsiString('\u'+IntToStr(SmallInt(Ord(Ch)))+'?'));
    WriteLiteral('}');
  end;

  function HexDigit(Ch: AnsiChar): Integer;
  begin
    case Ch of
      '0'..'9': Result:=Ord(Ch)-Ord('0');
      'a'..'f': Result:=Ord(Ch)-Ord('a')+10;
      'A'..'F': Result:=Ord(Ch)-Ord('A')+10;
    else
      Result:=-1;
    end;
  end;

  function DecodePicture(Index: Integer; out Picture: TRtfPicture): Boolean;
  var Group, Child: TGroup; Position, ChildIndex, Count, Value, Digit, Nibble: Integer;
    HasValue, Binary: Boolean; Name: AnsiString;
  begin
    Result:=False; Picture:=Default(TRtfPicture);
    Picture.ScaleX:=100; Picture.ScaleY:=100;
    Group:=Groups[Index];
    Position:=Group.Content; ChildIndex:=Index+1;
    SetLength(Picture.Bytes,Min(16*1024*1024,(Group.Last-Position) div 2));
    Count:=0; Nibble:=-1; Binary:=False;
    while Position<Group.Last do
    begin
      Check(Position);
      if Source[Position]='{' then
      begin
        Child:=Groups[ChildIndex];
        Position:=Child.Last+1; ChildIndex:=Child.Next;
      end
      else if Source[Position]='\' then
      begin
        ReadControl(Position,Group.Last,Name,Value,HasValue);
        if Name='pngblip' then Picture.Format:=rpfPNG
        else if Name='jpegblip' then Picture.Format:=rpfJPEG
        else if Name='dibitmap' then Picture.Format:=rpfDIB
        else if Name='wmetafile' then Picture.Format:=rpfWMF
        else if Name='emfblip' then Picture.Format:=rpfEMF
        else if Name='picwgoal' then Picture.GoalWidth:=Value
        else if Name='pichgoal' then Picture.GoalHeight:=Value
        else if Name='picscalex' then Picture.ScaleX:=Value
        else if Name='picscaley' then Picture.ScaleY:=Value
        else if Name='piccropl' then Picture.CropLeft:=Value
        else if Name='piccropt' then Picture.CropTop:=Value
        else if Name='piccropr' then Picture.CropRight:=Value
        else if Name='piccropb' then Picture.CropBottom:=Value
        else if Name='bin' then
        begin
          CheckBinary(Position,Group.Last,Value,HasValue);
          if Binary or (Nibble>=0) or (Count<>0) or (Value>16*1024*1024) then Exit;
          SetLength(Picture.Bytes,Value);
          if Value>0 then Move(Source[Position],Picture.Bytes[0],Value);
          Inc(Position,Value);
          Count:=Value; Binary:=True;
        end;
      end
      else
      begin
        if not (Source[Position] in [#9,#10,#13,' ']) then
        begin
          Digit:=HexDigit(Source[Position]);
          if (Digit<0) or Binary then Exit;
          if Nibble<0 then Nibble:=Digit
          else
          begin
            if Count>=Length(Picture.Bytes) then Exit;
            Picture.Bytes[Count]:=Byte(Nibble*16+Digit);
            Inc(Count); Nibble:=-1;
          end;
        end;
        Inc(Position);
      end;
    end;
    SetLength(Picture.Bytes,Count);
    Result:=(Count>0) and (Nibble<0) and (Picture.Format<>rpfUnknown);
  end;

  function WritePicture(Index: Integer): Boolean;
  var Picture: TRtfPicture;
  begin
    if Groups[Index].Kind<>rgPicture then
    begin
      if Index+1>=Groups[Index].Next then Exit(False);
      Inc(Index);
      if Groups[Index].Kind<>rgPicture then Exit(False);
    end;
    if not DecodePicture(Index,Picture) then Exit(False);
    if Index=RulePicture then
    begin
      Picture.RuleBounds:=RuleBounds;
      Picture.RuleColor:=RuleColor;
    end;
    Result:=AddPicture(Picture);
    if Result then Offsets.Add(Integer(Output.Size));
  end;

  function FindChild(Index: Integer; Kind: TGroupKind): Integer;
  var Limit: Integer;
  begin
    Limit:=Groups[Index].Next;
    Result:=Index+1;
    while Result<Limit do
    begin
      if Groups[Result].Kind=Kind then Exit;
      Result:=Groups[Result].Next;
    end;
    Result:=-1;
  end;

  function WritePositionedLine(Left, Top, Right, Weight, Color: Integer): Boolean;
  var Picture: TRtfPicture; PNG: TPngImage; Stream: TBytesStream;
    Origin, Height, WidthPixels, HeightPixels, Start, Finish, Vertical, Horizontal: Integer;
    Pixel, Alpha: PByte;
  begin
    Result:=False;
    Origin:=Min(0,Left);
    if (Origin< -1440) or (Right<=Left) or (Right<=0) or (Right>28800+Origin) or (Abs(Int64(Top))>720) or (Weight<1) or
      (Weight>720) or (Color<0) or (Color>$FFFFFF) then Exit;
    Dec(Left,Origin); Dec(Right,Origin);
    Height:=Abs(Top)+Weight;
    if Height>720 then Exit;
    WidthPixels:=(Right+14) div 15;
    HeightPixels:=(Height+14) div 15;
    Start:=Max(0,Top)*HeightPixels;
    Finish:=Start+Weight*HeightPixels;
    PNG:=TPngImage.CreateBlank(COLOR_RGBALPHA,8,WidthPixels,HeightPixels);
    Stream:=nil;
    try
      // A transparent strip preserves the offsets without drawing over
      // text that has moved because the reading window is a different size.
      for var Y:=0 to HeightPixels-1 do
      begin
        Vertical:=Max(0,Min((Y+1)*Height,Finish)-Max(Y*Height,Start));
        Pixel:=PNG.Scanline[Y];
        Alpha:=PByte(PNG.AlphaScanline[Y]);
        for var X:=0 to WidthPixels-1 do
        begin
          Horizontal:=Max(0,(X+1)*Right-Max(X*Right,Left*WidthPixels));
          Pixel^:=Byte((Color shr 16) and $FF); Inc(Pixel);
          Pixel^:=Byte((Color shr 8) and $FF); Inc(Pixel);
          Pixel^:=Byte(Color and $FF); Inc(Pixel);
          Alpha^:=Round(255.0*Horizontal*Vertical/(Right*Height)); Inc(Alpha);
        end;
      end;
      Stream:=TBytesStream.Create;
      PNG.SaveToStream(Stream);
      Picture:=Default(TRtfPicture);
      Picture.Bytes:=Copy(Stream.Bytes,0,Stream.Size);
      Picture.Format:=rpfPNG;
      Picture.GoalWidth:=Right; Picture.GoalHeight:=Height;
      Picture.ScaleX:=100; Picture.ScaleY:=100;
      Picture.PositionedLine:=True;
      Result:=AddPicture(Picture);
      if Result then
      begin
        if Origin<0 then WriteLiteral(AnsiString(Format('\ql\li%d\lin%d\fi0 ',[Origin,Origin])));
        Offsets.Add(Integer(Output.Size));
      end;
    finally Stream.Free; PNG.Free; end;
  end;

  function WriteHorizontalRule(Index: Integer): Boolean;
  const
    StrokePath = '2;5;16384;45824;1;45824;32768';
    StripPath = '2;12;16384;45824;1;45824;1;45824;1;45824;1;45824;24577;32768';
  var
    Shape, Instance, Field, NameGroup, ValueGroup: TGroup;
    Properties: TDictionary<string,string>;
    Position, InstanceIndex, I, NameIndex, ValueIndex, Value, Divider: Integer;
    ShapeWidth, ShapeHeight: Int64;
    Left, Top, Right, Bottom, GeoLeft, GeoTop, GeoRight, GeoBottom, Width, Height, Color: Integer;
    HasValue, HasLeft, HasTop, HasRight, HasBottom, HorizontalOrigin, ParagraphOrigin,
      PageOrigin, NoWrap, NativeLineControls: Boolean;
    Control: AnsiString;
    Name, Vertices, Pair, Segments: string;
    Coordinates: TArray<string>;
    Points: array[0..4] of TPoint;
    Picture: TRtfPicture;
    Info: TBitmapInfoHeader;
    function ReadNumber(const Text: string; out Number: Integer): Boolean;
    var Start: Integer;
    begin
      Result:=False;
      if (Text='') or (Length(Text)>9) then Exit;
      Start:=1+Ord(Text[1]='-');
      if (Start>Length(Text)) or (Length(Text)-Start>=8) then Exit;
      for var Digit in Copy(Text,Start,MaxInt) do
        if not CharInSet(Digit,['0'..'9']) then Exit;
      Result:=TryStrToInt(Text,Number);
    end;
    function ReadProperty(const Key: string; out Number: Integer; Required: Boolean = False): Boolean;
    var Text: string;
    begin
      if Properties.TryGetValue(Key,Text) then Exit(ReadNumber(Text,Number));
      Number:=0;
      Result:=not Required;
    end;
    function PropertyText(const Key: string; const DefaultValue: string = ''): string;
    begin
      if not Properties.TryGetValue(Key,Result) then Result:=DefaultValue;
    end;
    function GroupText(const G: TGroup): string;
    begin
      Result:=Trim(string(Copy(Source,G.Content,G.Last-G.Content)));
    end;
    function RectangularPath: Boolean;
    begin
      Result:=(Points[0]=Points[4]) and (Left<Right) and (Top<Bottom) and
        (((Points[0].X=Points[1].X) and (Points[1].Y=Points[2].Y) and
          (Points[2].X=Points[3].X) and (Points[3].Y=Points[0].Y)) or
         ((Points[0].Y=Points[1].Y) and (Points[1].X=Points[2].X) and
          (Points[2].Y=Points[3].Y) and (Points[3].X=Points[0].X)));
    end;
  begin
    Result:=False;
    Shape:=Groups[Index];
    InstanceIndex:=Index+1;
    if (Shape.Last-Shape.First>4095) or (InstanceIndex>=Shape.Next) then Exit;
    Instance:=Groups[InstanceIndex];
    if (Instance.Kind<>rgShapeInstance) or (Instance.Next<>Shape.Next) then Exit;
    Position:=Shape.Content;
    SkipSpace(Position,Instance.First);
    if Position<>Instance.First then Exit;
    Position:=Instance.Last+1;
    SkipSpace(Position,Shape.Last);
    if Position<>Shape.Last then Exit;
    Left:=0; Top:=0; Right:=0; Bottom:=0;
    HasLeft:=False; HasTop:=False; HasRight:=False; HasBottom:=False;
    HorizontalOrigin:=False; ParagraphOrigin:=False; PageOrigin:=False; NoWrap:=False;
    NativeLineControls:=True;
    I:=InstanceIndex+1;
    if I>=Instance.Next then Exit;
    Position:=Instance.Content;
    while Position<Groups[I].First do
    begin
      SkipSpace(Position,Groups[I].First);
      if Position=Groups[I].First then Break;
      if Source[Position]<>'\' then Exit;
      ReadControl(Position,Groups[I].First,Control,Value,HasValue);
      if (Control='shpleft') and HasValue and not HasLeft then begin Left:=Value; HasLeft:=True; end
      else if (Control='shptop') and HasValue and not HasTop then begin Top:=Value; HasTop:=True; end
      else if (Control='shpright') and HasValue and not HasRight then begin Right:=Value; HasRight:=True; end
      else if (Control='shpbottom') and HasValue and not HasBottom then begin Bottom:=Value; HasBottom:=True; end
      else if MatchStr(string(Control),['shpbxmargin','shpbxcolumn']) then
      begin
        if HorizontalOrigin or HasValue then Exit;
        HorizontalOrigin:=True;
      end
      else if Control='shpbypara' then
      begin
        NativeLineControls:=NativeLineControls and not ParagraphOrigin and not HasValue;
        ParagraphOrigin:=True;
      end
      else if Control='shpbxpage' then PageOrigin:=True
      else if Control='shpwr' then
      begin
        NativeLineControls:=NativeLineControls and not NoWrap;
        NoWrap:=HasValue and (Value=3);
      end
      else if MatchStr(string(Control),['shpfhdr','shpwrk','shpfblwtxt']) then
        NativeLineControls:=NativeLineControls and HasValue and
          ((Value=0) or ((Control='shpfblwtxt') and (Value=1)))
      else if not MatchStr(string(Control),['shplid','shpz']) then Exit;
    end;
    ShapeWidth:=Int64(Right)-Left; ShapeHeight:=Int64(Bottom)-Top;
    if not (HasLeft and HasTop and HasRight and HasBottom) or (ShapeWidth<=0) or (ShapeWidth>240000) or
      (ShapeHeight<0) or (ShapeHeight>240000) then Exit;
    Properties:=TDictionary<string,string>.Create;
    try
      while I<Instance.Next do
      begin
        Field:=Groups[I]; NameIndex:=I+1; ValueIndex:=I+2;
        if (Field.First<>Position) or (Field.Kind<>rgShapeProperty) or (Field.Next<>I+3) then Exit;
        NameGroup:=Groups[NameIndex]; ValueGroup:=Groups[ValueIndex];
        if (NameGroup.Kind<>rgPropertyName) or (ValueGroup.Kind<>rgPropertyValue) or
          (NameGroup.Next<>ValueIndex) or (ValueGroup.Next<>Field.Next) then Exit;
        Position:=Field.Content;
        SkipSpace(Position,NameGroup.First);
        if Position<>NameGroup.First then Exit;
        Position:=NameGroup.Last+1;
        SkipSpace(Position,ValueGroup.First);
        if Position<>ValueGroup.First then Exit;
        Position:=ValueGroup.Last+1;
        SkipSpace(Position,Field.Last);
        if Position<>Field.Last then Exit;
        Name:=GroupText(NameGroup);
        if Properties.ContainsKey(Name) or not MatchStr(Name,['shapeType','shapePath','pVerticies','pVertices',
          'pSegmentInfo','geoLeft','geoTop','geoRight','geoBottom','fFillOK','fFilled','fillColor','fLine',
          'lineWidth','lineType','lineColor','fArrowheadsOK','rotation','fFlipH','fFlipV','dxWrapDistLeft',
          'dxWrapDistRight','posrelh','posrelv']) then Exit;
        Properties.Add(Name,GroupText(ValueGroup));
        I:=Field.Next;
        Position:=Field.Last+1;
        if I<Instance.Next then SkipSpace(Position,Groups[I].First);
      end;
      SkipSpace(Position,Instance.Last);
      if Position<>Instance.Last then Exit;
      if PropertyText('shapeType')='20' then
      begin
        if not (HorizontalOrigin and ParagraphOrigin and NoWrap and NativeLineControls) or PageOrigin or
          (Left<0) or (Top<>Bottom) or (PropertyText('fLine','1')<>'1') or (PropertyText('lineType','0')<>'0') or
          not ReadProperty('lineWidth',Value,True) or not ReadProperty('lineColor',Color) then Exit;
        for Name in Properties.Keys do
          if not MatchStr(Name,['shapeType','fLine','lineType','lineWidth','lineColor']) then Exit;
        Exit(WritePositionedLine(Left,Top,Right,Round(Value/635),Color));
      end;
      if HorizontalOrigin then Exit;
      if (PropertyText('shapeType')<>'0') or (PropertyText('shapePath')<>'4') then Exit;
      if (PropertyText('rotation','0')<>'0') or (PropertyText('fFlipH','0')<>'0') or
        (PropertyText('fFlipV','0')<>'0') or (PropertyText('lineType','0')<>'0') then Exit;
      if not Properties.TryGetValue('pVerticies',Vertices) then Vertices:=PropertyText('pVertices');
      Coordinates:=Vertices.Split([';']);
      if not (Length(Coordinates) in [4,7]) or (Coordinates[0]<>'8') or
        (Coordinates[1]<>IntToStr(Length(Coordinates)-2)) then Exit;
      Left:=MaxInt; Top:=MaxInt; Right:=-MaxInt; Bottom:=-MaxInt;
      for I:=0 to Length(Coordinates)-3 do
      begin
        Pair:=Trim(Coordinates[I+2]);
        Divider:=Pos(',',Pair);
        if (Divider<3) or (Length(Pair)<=Divider+1) or (Pair[1]<>'(') or
          (Pair[Length(Pair)]<>')') or not ReadNumber(Copy(Pair,2,Divider-2),Points[I].X) or
          not ReadNumber(Copy(Pair,Divider+1,Length(Pair)-Divider-1),Points[I].Y) then Exit;
        Left:=Min(Left,Points[I].X); Right:=Max(Right,Points[I].X);
        Top:=Min(Top,Points[I].Y); Bottom:=Max(Bottom,Points[I].Y);
      end;
      if not ReadProperty('geoLeft',GeoLeft) or not ReadProperty('geoTop',GeoTop) or
        not ReadProperty('geoRight',GeoRight) or not ReadProperty('geoBottom',GeoBottom) or
        (Left<GeoLeft) or (Left>=Right) or (Right>GeoRight) or (Top<GeoTop) or (Bottom>GeoBottom) then Exit;
      Width:=Round(ShapeWidth*(Right-Left)/(GeoRight-GeoLeft));
      Segments:=PropertyText('pSegmentInfo');
      if (Segments=StrokePath) and (Length(Coordinates)=4) and (Top=Bottom) then
      begin
        if (PropertyText('fFilled','0')<>'0') or (PropertyText('fLine')<>'1') or
          not ReadProperty('lineWidth',Value,True) or not ReadProperty('lineColor',Color,True) then Exit;
        Height:=Round(Value/635);
      end
      else if (Segments=StripPath) and (Length(Coordinates)=7) and RectangularPath then
      begin
        if (PropertyText('fFilled')<>'1') or (PropertyText('fLine')<>'0') or
          not ReadProperty('fillColor',Color,True) then Exit;
        Height:=Round(ShapeHeight*(Bottom-Top)/(GeoBottom-GeoTop));
      end
      else Exit;
    finally Properties.Free; end;
    if (Width<=0) or (Height<=0) or (Height>720) or (Color<0) or (Color>$FFFFFF) then Exit;
    // Stretch a single solid pixel to the authored size in the reading layout.
    Picture:=Default(TRtfPicture);
    Picture.Format:=rpfDIB;
    Picture.GoalWidth:=Width; Picture.GoalHeight:=Height;
    Picture.ScaleX:=100; Picture.ScaleY:=100;
    FillChar(Info,SizeOf(Info),0);
    Info.biSize:=SizeOf(Info);
    Info.biWidth:=1; Info.biHeight:=1; Info.biPlanes:=1; Info.biBitCount:=24; Info.biSizeImage:=4;
    SetLength(Picture.Bytes,SizeOf(Info)+4);
    Move(Info,Picture.Bytes[0],SizeOf(Info));
    Picture.Bytes[SizeOf(Info)]:=Byte((Color shr 16) and $FF);
    Picture.Bytes[SizeOf(Info)+1]:=Byte((Color shr 8) and $FF);
    Picture.Bytes[SizeOf(Info)+2]:=Byte(Color and $FF);
    Result:=AddPicture(Picture);
    if Result then Offsets.Add(Integer(Output.Size));
  end;

  function ShapePicture(Instance: Integer): Integer;
  var PropertyIndex, NameIndex, ValueIndex: Integer; Name: TGroup;
  begin
    Result:=-1;
    if Instance<0 then Exit;
    PropertyIndex:=Instance+1;
    while PropertyIndex<Groups[Instance].Next do
    begin
      if Groups[PropertyIndex].Kind=rgShapeProperty then
      begin
        NameIndex:=FindChild(PropertyIndex,rgPropertyName);
        if NameIndex>=0 then
        begin
          Name:=Groups[NameIndex];
          if Trim(Copy(Source,Name.Content,Name.Last-Name.Content))='pib' then
          begin
            ValueIndex:=FindChild(PropertyIndex,rgPropertyValue);
            if ValueIndex>=0 then Exit(FindChild(ValueIndex,rgPicture));
          end;
        end;
      end;
      PropertyIndex:=Groups[PropertyIndex].Next;
    end;
  end;

  function ReadPictureGroup(Index: Integer; out Image: Integer; out Labels: TArray<Integer>): Boolean;
  var Instance, Member, MemberInstance, Picture, ShapeText: Integer; TextBoxes: TList<Integer>;
  begin
    Result:=False;
    Image:=-1;
    Labels:=nil;
    Instance:=FindChild(Index,rgShapeInstance);
    if Instance<0 then Exit;
    TextBoxes:=TList<Integer>.Create;
    try
      Member:=Instance+1;
      while Member<Groups[Instance].Next do
      begin
        Check(Groups[Member].First);
        if Groups[Member].Kind<>rgShapeProperty then
        begin
          if Groups[Member].Kind<>rgShape then Exit;
          MemberInstance:=FindChild(Member,rgShapeInstance);
          if MemberInstance<0 then Exit;
          Picture:=ShapePicture(MemberInstance);
          ShapeText:=FindChild(MemberInstance,rgShapeText);
          if Picture>=0 then
          begin
            if (Image>=0) or (ShapeText>=0) then Exit;
            Image:=Picture;
          end
          else if (ShapeText>=0) and not Groups[Member].ContainsGraphics then TextBoxes.Add(ShapeText)
          else Exit;
        end;
        Member:=Groups[Member].Next;
      end;
      if (Image<0) or (TextBoxes.Count=0) then Exit;
      Labels:=TextBoxes.ToArray;
      Result:=True;
    finally TextBoxes.Free; end;
  end;

  function HasMatchingWordPicture(ShapeText, ShapeImage: Integer): Boolean;
  var I, J, ClassIndex, Preview: Integer; ClassGroup: TGroup; Original, Candidate: TRtfPicture;
  begin
    Result:=False;
    if (ShapeText<0) or (ShapeImage<0) or not Groups[ShapeText].ContainsGraphics or
      not DecodePicture(ShapeImage,Original) then Exit;
    I:=ShapeText+1;
    while I<Groups[ShapeText].Next do
    begin
      Check(Groups[I].First);
      if Groups[I].Kind=rgNormal then begin Inc(I); Continue; end;
      if Groups[I].Kind=rgObject then
      begin
        ClassIndex:=FindChild(I,rgObjectClass);
        Preview:=FindChild(I,rgResult);
        if (ClassIndex>=0) and (Preview>=0) then
        begin
          ClassGroup:=Groups[ClassIndex];
          if StartsStr('Word.Picture.',Trim(string(Copy(Source,ClassGroup.Content,
            ClassGroup.Last-ClassGroup.Content)))) then
          begin
            J:=Preview+1;
            while J<Groups[Preview].Next do
            begin
              if Groups[J].Kind in [rgNormal,rgPrimary,rgFallback] then begin Inc(J); Continue; end;
              if Groups[J].Kind=rgPicture then
              begin
                if DecodePicture(J,Candidate) and (Candidate.Format=Original.Format) and
                  (Candidate.GoalWidth=Original.GoalWidth) and (Candidate.GoalHeight=Original.GoalHeight) and
                  (Candidate.ScaleX=Original.ScaleX) and (Candidate.ScaleY=Original.ScaleY) and
                  (Candidate.CropLeft=Original.CropLeft) and (Candidate.CropTop=Original.CropTop) and
                  (Candidate.CropRight=Original.CropRight) and (Candidate.CropBottom=Original.CropBottom) and
                  (Length(Candidate.Bytes)=Length(Original.Bytes)) and
                  CompareMem(Pointer(Candidate.Bytes),Pointer(Original.Bytes),Length(Original.Bytes)) then Exit(True);
                // Do not use a matching backup when the primary picture differs.
                Break;
              end;
              J:=Groups[J].Next;
            end;
          end;
        end;
      end;
      I:=Groups[I].Next;
    end;
  end;

  function IsLegacyShapeResult(Index: Integer): Boolean;
  var Parent, Legacy: TGroup; Position: Integer;
  begin
    Result:=False;
    Parent:=Groups[Index];
    if Index+1>=Parent.Next then Exit;
    Legacy:=Groups[Index+1];
    if (Legacy.Kind<>rgLegacyDraw) or (Legacy.Next<>Parent.Next) then Exit;
    Position:=Parent.Content;
    SkipSpace(Position,Legacy.First);
    if Position<>Legacy.First then Exit;
    Position:=Legacy.Last+1;
    SkipSpace(Position,Parent.Last);
    Result:=Position=Parent.Last;
  end;

  function ReadCompatibilityLine(Index: Integer; Horizontal: Boolean; out Bounds: TRect;
    out Color: Cardinal): Boolean;
  const
    PropertyPattern = '\{\s*\\sp\s*\{\s*\\sn\s+([a-zA-Z0-9]+)\s*\}\s*\{\s*\\sv\s+(-?\d{1,10})\s*\}\s*\}';
  var
    Shape, Instance, Backup, Legacy: TGroup;
    Modern, LegacyFields, Properties: TDictionary<string,Integer>;
    BackupIndex, FirstProperty, X, Top, Right, Bottom, Width, DX, DY, R, G, B, Value: Integer;
    Body, Name: string;

    function Controls(First, Last: Integer; const Allowed, Switches: array of string;
      Fields: TDictionary<string,Integer>): Boolean;
    var Control: AnsiString; Key: string; Value: Integer; HasValue: Boolean;
    begin
      while First<Last do
      begin
        SkipSpace(First,Last);
        if First=Last then Break;
        if Source[First]<>'\' then Exit(False);
        ReadControl(First,Last,Control,Value,HasValue);
        Key:=string(Control);
        if not MatchStr(Key,Allowed) or (HasValue=MatchStr(Key,Switches)) then Exit(False);
        if (Key='dpptx') or (Key='dppty') then
          if Fields.ContainsKey(Key) then Key:=Key+'2';
        if Fields.ContainsKey(Key) then Exit(False);
        Fields.Add(Key,Value);
      end;
      Result:=True;
    end;

    function FieldIs(Fields: TDictionary<string,Integer>; const Key: string; Value: Integer): Boolean;
    var Actual: Integer;
    begin
      Result:=Fields.TryGetValue(Key,Actual) and (Actual=Value);
    end;

    function OffOrAbsent(Fields: TDictionary<string,Integer>; const Key: string): Boolean;
    var Value: Integer;
    begin
      Result:=not Fields.TryGetValue(Key,Value) or (Value=0);
    end;

  begin
    Result:=False;
    Shape:=Groups[Index];
    if (Shape.Last-Shape.First>4096) or (Index+1>=Shape.Next) then Exit;
    Instance:=Groups[Index+1];
    BackupIndex:=Instance.Next;
    FirstProperty:=Index+2;
    if (Instance.Kind<>rgShapeInstance) or (FirstProperty>=BackupIndex) or
      (BackupIndex>=Shape.Next) then Exit;
    Backup:=Groups[BackupIndex];
    if (Backup.Kind<>rgShapeResult) or (Backup.Next<>Shape.Next) or
      not IsLegacyShapeResult(BackupIndex) then Exit;
    Legacy:=Groups[BackupIndex+1];
    X:=Shape.Content;
    SkipSpace(X,Instance.First);
    if X<>Instance.First then Exit;
    X:=Instance.Last+1;
    SkipSpace(X,Backup.First);
    if X<>Backup.First then Exit;
    X:=Backup.Last+1;
    SkipSpace(X,Shape.Last);
    if X<>Shape.Last then Exit;

    Modern:=TDictionary<string,Integer>.Create;
    LegacyFields:=TDictionary<string,Integer>.Create;
    Properties:=TDictionary<string,Integer>.Create;
    try
      if not Controls(Instance.Content,Groups[FirstProperty].First,
        ['shpleft','shptop','shpright','shpbottom','shpfhdr','shpbxcolumn','shpbxignore',
         'shpbypara','shpbyignore','shpwr','shpwrk','shpfblwtxt','shpz','shplid'],
        ['shpbxcolumn','shpbxignore','shpbypara','shpbyignore'],Modern) then Exit;
      if not (Modern.ContainsKey('shpbxcolumn') and Modern.ContainsKey('shpbypara') and
        FieldIs(Modern,'shpwr',3) and OffOrAbsent(Modern,'shpfhdr') and
        Modern.TryGetValue('shpleft',X) and Modern.TryGetValue('shpright',Right) and
        Modern.TryGetValue('shptop',Top) and
        Modern.TryGetValue('shpbottom',Bottom)) then Exit;
      if Horizontal then
      begin
        if (X< -1440) or (Right<=X) or (Right<=0) or (Right>28800+Min(0,X)) or
          (Top<>Bottom) or (Abs(Int64(Top))>=720) or
          not OffOrAbsent(Modern,'shpwrk') or
          not (OffOrAbsent(Modern,'shpfblwtxt') or FieldIs(Modern,'shpfblwtxt',1)) then Exit;
      end
      else if (X<>Right) or (Abs(Int64(X))>240000) or (Abs(Int64(Top))>240000) or
        (Abs(Int64(Bottom))>240000) or (Bottom<=Top) or (Bottom-Top>240000) or
        not OffOrAbsent(Modern,'shpfblwtxt') then Exit;
      DX:=Right-X; DY:=Bottom-Top;

      Body:=string(Copy(Source,Groups[FirstProperty].First,Instance.Last-Groups[FirstProperty].First));
      if Trim(TRegEx.Replace(Body,PropertyPattern,''))<>'' then Exit;
      for var PropertyMatch in TRegEx.Matches(Body,PropertyPattern) do
      begin
        Name:=PropertyMatch.Groups[1].Value;
        if (not MatchStr(Name,['shapeType','shapePath','fFlipH','fFlipV','fFillOK','fFilled',
          'fArrowheadsOK','dhgt','fLayoutInCell','fPseudoInline']) and
          not (Horizontal and MatchStr(Name,['lineWidth','lineColor','fLine','lineType']))) or
          not TryStrToInt(PropertyMatch.Groups[2].Value,Width) then Exit;
        if Properties.ContainsKey(Name) then
        begin
          if not FieldIs(Properties,Name,Width) then Exit;
        end
        else Properties.Add(Name,Width);
      end;
      if not FieldIs(Properties,'shapeType',20) or not OffOrAbsent(Properties,'fFilled') then Exit;
      if Horizontal and (not OffOrAbsent(Properties,'fFlipH') or not OffOrAbsent(Properties,'fFlipV') or
        not OffOrAbsent(Properties,'fPseudoInline') or not OffOrAbsent(Properties,'lineType') or
        (Properties.ContainsKey('shapePath') and not FieldIs(Properties,'shapePath',4)) or
        (Properties.ContainsKey('fLine') and not FieldIs(Properties,'fLine',1))) then Exit;

      // The compatibility drawing must describe the same stroke and placement.
      if not Controls(Legacy.Content,Legacy.Last,
        ['dobxcolumn','dobypara','dodhgt','dpline','dpptx','dppty','dpx','dpy','dpxsize',
         'dpysize','dplinew','dplinecor','dplinecog','dplinecob','dplinesolid'],
        ['dobxcolumn','dobypara','dpline','dplinesolid'],LegacyFields) then Exit;
      if not (LegacyFields.ContainsKey('dobxcolumn') and LegacyFields.ContainsKey('dobypara') and
        LegacyFields.ContainsKey('dpline') and FieldIs(LegacyFields,'dpptx',0) and
        FieldIs(LegacyFields,'dpptx2',DX) and FieldIs(LegacyFields,'dppty',0) and
        FieldIs(LegacyFields,'dppty2',DY) and FieldIs(LegacyFields,'dpx',X) and
        FieldIs(LegacyFields,'dpy',Top) and FieldIs(LegacyFields,'dpxsize',DX) and
        FieldIs(LegacyFields,'dpysize',DY) and LegacyFields.TryGetValue('dplinew',Width) and
        LegacyFields.TryGetValue('dplinecor',R) and LegacyFields.TryGetValue('dplinecog',G) and
        LegacyFields.TryGetValue('dplinecob',B)) then Exit;
      if (Width<1) or (Width>720) or (R<0) or (R>255) or (G<0) or (G>255) or (B<0) or (B>255) then Exit;
      Color:=RGB(Byte(R),Byte(G),Byte(B));
      if Horizontal then
      begin
        if (Abs(Top)+Width>720) or
          (Properties.TryGetValue('lineWidth',Value) and (Round(Value/635)<>Width)) or
          (Properties.TryGetValue('lineColor',Value) and (Value<>Integer(Color))) then Exit;
        Bounds:=Rect(X,Top,Right,Top+Width);
      end
      else Bounds:=Rect(X-Width div 2,Top,X-Width div 2+Width,Bottom);
      Result:=True;
    finally
      Properties.Free; LegacyFields.Free; Modern.Free;
    end;
  end;

  function OnlyRunChild(Index: Integer; Kind: TGroupKind): Integer;
  var Run, Child: TGroup; Position, Value: Integer; Name: AnsiString; HasValue: Boolean;
  begin
    Result:=-1;
    Run:=Groups[Index];
    if (Run.Kind<>rgNormal) or (Index+1>=Run.Next) then Exit;
    Child:=Groups[Index+1];
    if (Child.Kind<>Kind) or (Child.Next<>Run.Next) then Exit;
    Position:=Run.First+1;
    while Position<Child.First do
    begin
      SkipSpace(Position,Child.First);
      if Position=Child.First then Break;
      if Source[Position]<>'\' then Exit;
      ReadControl(Position,Child.First,Name,Value,HasValue);
      if not MatchStr(string(Name),['rtlch','ltrch','fcs','af','lang','langfe','noproof',
        'langnp','langfenp','insrsid','charrsid']) then Exit;
    end;
    Position:=Child.Last+1;
    SkipSpace(Position,Run.Last);
    if Position=Run.Last then Result:=Index+1;
  end;

  procedure PairVerticalRule(ShapeRun, EndOfParent: Integer);
  var NextRun, Shape, Picture, Position: Integer;
  begin
    NextRun:=Groups[ShapeRun].Next;
    if NextRun>=EndOfParent then Exit;
    Shape:=OnlyRunChild(ShapeRun,rgShape);
    if Shape<0 then Exit;
    Picture:=OnlyRunChild(NextRun,rgPicture);
    if Picture<0 then Exit;
    Position:=Groups[ShapeRun].Last+1;
    SkipSpace(Position,Groups[NextRun].First);
    if Position<>Groups[NextRun].First then Exit;
    if not ReadCompatibilityLine(Shape,False,RuleBounds,RuleColor) then Exit;
    RuleShape:=Shape;
    RulePicture:=Picture;
  end;

  function WriteOverhangingRule(RunIndex, Start, Limit: Integer): Boolean;
  var Run, ClosingRun: TGroup; Shape, Position, Value: Integer;
    HasValue, Closed: Boolean; Control: AnsiString; Bounds: TRect; Color: Cardinal;
  begin
    Result:=False;
    Run:=Groups[RunIndex];
    if (Run.First-Start>512) or (Run.Next>=Limit) then Exit;
    SkipSpace(Start,Run.First);
    if (Start>=Run.First) or (Source[Start]<>'\') then Exit;
    ReadControl(Start,Run.First,Control,Value,HasValue);
    if (Control<>'pard') or HasValue then Exit;
    Shape:=OnlyRunChild(RunIndex,rgShape);
    if (Shape<0) or not ReadCompatibilityLine(Shape,True,Bounds,Color) or (Bounds.Left>=0) then Exit;
    while Start<Run.First do
    begin
      SkipSpace(Start,Run.First);
      if Start=Run.First then Break;
      if Source[Start]<>'\' then Exit;
      ReadControl(Start,Run.First,Control,Value,HasValue);
      if not MatchStr(string(Control),['plain','ltrpar','ql','qr','qj','qc','fi','li','ri','sl','slmult',
        'sa','sb','widctlpar','nowidctlpar','aspalpha','aspnum','faauto','adjustright','rin','lin','itap',
        'pararsid','fs','lang','langfe','cgrid','langnp','langfenp']) or
        ((Control='itap') and (not HasValue or (Value<>0))) then Exit;
    end;
    ClosingRun:=Groups[Run.Next];
    if (ClosingRun.Kind<>rgNormal) or (ClosingRun.Next<>Run.Next+1) or
      (ClosingRun.Last-ClosingRun.First>256) or (ClosingRun.Next>=Limit) then Exit;
    Position:=Run.Last+1;
    SkipSpace(Position,ClosingRun.First);
    if Position<>ClosingRun.First then Exit;
    Position:=ClosingRun.First+1; Closed:=False;
    while Position<ClosingRun.Last do
    begin
      SkipSpace(Position,ClosingRun.Last);
      if Position=ClosingRun.Last then Break;
      if Closed or (Source[Position]<>'\') then Exit;
      ReadControl(Position,ClosingRun.Last,Control,Value,HasValue);
      if (Control='par') and not HasValue then Closed:=True
      else if not MatchStr(string(Control),['lang','langfe','langnp','langfenp','insrsid','charrsid']) then Exit;
    end;
    // Only override the formatting of an empty paragraph. The next authored
    // paragraph must reset its own properties before any visible content.
    Position:=ClosingRun.Last+1;
    var NextStart:=Groups[ClosingRun.Next].First;
    SkipSpace(Position,NextStart);
    if not Closed or (Position>=NextStart) or (Source[Position]<>'\') then Exit;
    ReadControl(Position,NextStart,Control,Value,HasValue);
    if (Control<>'pard') or HasValue then Exit;
    Result:=WritePositionedLine(Bounds.Left,Bounds.Top,Bounds.Right,Bounds.Height,Integer(Color));
  end;

  procedure Walk(Index, Position: Integer);
  var Group, Child, Fallback: TGroup; I, J, Instance, Picture, ShapeText, Between, Gap: Integer;
    Labels: TArray<Integer>;
    LineBounds: TRect;
    LineColor: Cardinal;
  begin
    Group:=Groups[Index]; I:=Index+1;
    while I<Group.Next do
    begin
      Child:=Groups[I];
      Check(Child.First);
      if Child.Kind=rgNormal then PairVerticalRule(I,Group.Next);
      Gap:=Position;
      WriteSource(Position,Child.First);
      Position:=Child.Last+1;
      case Child.Kind of
        rgPicture, rgFallback:
          if not WritePicture(I) then WriteMissing('Изображение RTF не читается.');
        rgPrimary: begin
          Between:=Position;
          SkipSpace(Between,Group.Last);
          if Child.Next<Group.Next then Fallback:=Groups[Child.Next] else Fallback:=Default(TGroup);
          if (Fallback.Kind=rgFallback) and (Fallback.First=Between) then
          begin
            if not WritePicture(I) and not WritePicture(Child.Next) then
              WriteMissing('Изображение RTF не читается.');
            Position:=Fallback.Last+1;
            I:=Fallback.Next; Continue;
          end;
          if not WritePicture(I) then WriteMissing('Изображение RTF не читается.');
        end;
        rgObject: begin
          J:=FindChild(I,rgResult);
          if J>=0 then
          begin
            WriteLiteral('{'); Walk(J,Groups[J].Content); WriteLiteral('}');
          end
          else WriteMissing('Представление объекта RTF отсутствует.');
        end;
        rgShape: begin
          // RichEdit ignores these freeform rules. Leave other drawing
          // commands untouched unless we have an actual picture to display.
          if not Child.ContainsGraphics then
          begin
            if (I<>RuleShape) and not WriteHorizontalRule(I) then
              if not ReadCompatibilityLine(I,True,LineBounds,LineColor) or
                (LineBounds.Left<0) or
                not WritePositionedLine(LineBounds.Left,LineBounds.Top,LineBounds.Right,
                  LineBounds.Height,Integer(LineColor)) then WriteSource(Child.First,Position);
          end
          else
          begin
            J:=FindChild(I,rgShapeResult);
            Instance:=FindChild(I,rgShapeInstance);
            ShapeText:=-1;
            if Instance>=0 then ShapeText:=FindChild(Instance,rgShapeText);
            Picture:=ShapePicture(Instance);
            if ((J<0) or not Groups[J].ContainsGraphics or IsLegacyShapeResult(J)) and
              HasMatchingWordPicture(ShapeText,Picture) then
              // The modern shape text already displays the same graphic.
              // The alternate Word drawing can contain only hidden RTF data.
              J:=ShapeText
            else if (J<0) or not Groups[J].ContainsGraphics then
            begin
              if (Picture>=0) and WritePicture(Picture) then
              begin
                J:=ShapeText;
                if J>=0 then
                begin
                  WriteLiteral('{'); Walk(J,Groups[J].Content); WriteLiteral('}');
                end;
                I:=Child.Next;
                Continue;
              end;
              if J<0 then J:=ShapeText;
            end;
            if J>=0 then
            begin
              WriteLiteral('{'); Walk(J,Groups[J].Content); WriteLiteral('}');
            end
            else WriteMissing('Представление изображения RTF отсутствует.');
          end;
        end;
        rgShapeGroup: begin
          if ReadPictureGroup(I,Picture,Labels) and WritePicture(Picture) then
          begin
            // The same drawing can have a legacy result as well as the
            // original image and editable labels in the modern group.
            for ShapeText in Labels do
            begin
              WriteLiteral('{'); Walk(ShapeText,Groups[ShapeText].Content); WriteLiteral('}');
            end;
          end
          else
          begin
            WriteLiteral('{'); Walk(I,Child.First+1); WriteLiteral('}');
          end;
        end;
        rgField: begin
          J:=FindChild(I,rgFieldResult);
          if (J>=0) and Groups[J].ContainsGraphics then
          begin
            // A native field is atomic when its inline image is replaced.
            // Keep its displayed result editable by the layout buffer.
            WriteLiteral('{'); Walk(J,Groups[J].Content); WriteLiteral('}');
          end
          else WriteSource(Child.First,Position);
        end;
        rgObjectClass, rgObjectData: ;
        rgHidden, rgLegacyDraw: WriteSource(Child.First,Position);
      else
        if (Child.Kind<>rgNormal) or not WriteOverhangingRule(I,Gap,Group.Next) then
        begin
          WriteLiteral('{'); Walk(I,Child.First+1); WriteLiteral('}');
        end;
      end;
      I:=Child.Next;
    end;
    WriteSource(Position,Group.Last);
  end;

begin
  Groups:=TList<TGroup>.Create;
  Offsets:=TList<Integer>.Create;
  Output:=TMemoryStream.Create;
  try
    SourceLength:=Length(Source); NextCheck:=1;
    RuleShape:=-1; RulePicture:=-1;
    HasTables:=False;
    ScanGroups;
    NextCheck:=1;
    WriteSource(1,Groups[0].First+1);
    Walk(0,Groups[0].First+1);
    WriteSource(Groups[0].Last,SourceLength+1);
    SetLength(Result,Integer(Output.Size));
    if Result<>'' then Move(Output.Memory^,Result[1],Length(Result));
    PictureOffsets:=Offsets.ToArray;
  finally
    Output.Free; Offsets.Free; Groups.Free;
  end;
end;

end.
