unit unit_KindleBookCover;

interface

uses System.Classes, System.SysUtils;

function IsKindleCoverFormat(const Extension: string): Boolean;
// An EXTH cover or thumbnail needs no text reads. Older MOBI books can point
// to a cover via the HTML guide. Both paths operate on the caller's stream.
function ReadKindleBookCover(Stream: TStream; out Status: string;
  const IsCanceled: TFunc<Boolean> = nil): TBytes;

implementation

uses System.Math, unit_KindleGuideCover;

const MaxMetadata=1024*1024; MaxCover=16*1024*1024; Missing=High(Cardinal);

function IsKindleCoverFormat(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|mobi|azw|azw3|azw4|prc|pdb|')>0;
end;

function ReadKindleBookCover(Stream: TStream; out Status: string;
  const IsCanceled: TFunc<Boolean>): TBytes;
var Saved,FileSize:Int64; Header,Table:TBytes; Offsets:TArray<Int64>;
  Records:Integer; CoverRecord,NextHeader,LastText:Cardinal; Thumbnail:Boolean;
  procedure Check;
  begin if Assigned(IsCanceled) and IsCanceled() then Abort; end;
  procedure Invalid;
  begin raise EReadError.Create('Повреждены метаданные обложки Kindle.'); end;
  function ReadAt(Position:Int64; Count,Limit:Integer):TBytes;
  var Done,Chunk:Integer;
  begin
    Check;
    if (Position<0) or (Position>FileSize) or (Count<0) or (Count>Limit) or
      (Int64(Count)>FileSize-Position) then Invalid;
    SetLength(Result,Count); Stream.Position:=Position; Done:=0;
    while Done<Count do
    begin
      Check; Chunk:=Count-Done; if Chunk>32768 then Chunk:=32768;
      Stream.ReadBuffer(Result[Done],Chunk); Inc(Done,Chunk);
    end;
  end;
  function Number(const Data:TBytes; At,Count:Integer):Cardinal;
  begin
    if (At<0) or (Count<1) or (Count>4) or (At>Length(Data)-Count) then Invalid;
    Result:=0;
    for var I:=At to At+Count-1 do Result:=(Result shl 8) or Data[I];
  end;
  function Magic(const Data:TBytes; At:Integer; const Value:AnsiString):Boolean;
  begin
    Result:=False;
    if (At<0) or (At>Length(Data)-Length(Value)) then Exit;
    for var I:=1 to Length(Value) do if Data[At+I-1]<>Byte(Value[I]) then Exit;
    Result:=True;
  end;
  function RecordSize(Index:Cardinal):Int64;
  begin
    if Index>=Cardinal(Records) then Invalid;
    Result:=Offsets[Index+1]-Offsets[Index];
  end;
  procedure ReadHeader(Index:Cardinal; out ImageRecord,Boundary,LastTextRecord:Cardinal;
    out IsThumbnail:Boolean);
  var Data,Metadata:TBytes; Size:Int64; HeaderSize,FirstResource,Version,Flags:Cardinal;
    EXTHSize,Items,Key,ItemSize,Value:Cardinal; At:Integer;
    CoverOffset,ThumbOffset:Cardinal; CoverSeen,ThumbSeen,BoundarySeen:Boolean;
  begin
    Check; ImageRecord:=Missing; Boundary:=Missing; LastTextRecord:=Index; IsThumbnail:=False;
    Size:=RecordSize(Index);
    if Size<40 then Invalid;
    Data:=ReadAt(Offsets[Index],40,40);
    if not Magic(Data,16,'MOBI') then Invalid;
    if UInt64(Index)+Number(Data,8,2)>=UInt64(Records) then Invalid;
    LastTextRecord:=Index+Number(Data,8,2);
    HeaderSize:=Number(Data,20,4); Version:=Number(Data,36,4);
    if (HeaderSize<24) or (HeaderSize>MaxMetadata) or (Int64(HeaderSize)+16>Size) then Invalid;
    if Version>8 then
      raise EReadError.Create('Этот вариант Kindle пока не поддерживает прямое чтение обложки.');
    // Older Palm/MOBI headers can have no EXTH block at all.
    if HeaderSize<116 then Exit;
    Data:=ReadAt(Offsets[Index],132,132); Flags:=Number(Data,128,4);
    if Flags and $40=0 then Exit;
    FirstResource:=Number(Data,108,4);
    if FirstResource=Missing then FirstResource:=Number(Data,8,2)+1;
    if (Int64(HeaderSize)+28>Size) then Invalid;
    Metadata:=ReadAt(Offsets[Index]+16+HeaderSize,12,12);
    if not Magic(Metadata,0,'EXTH') then Invalid;
    EXTHSize:=Number(Metadata,4,4); Items:=Number(Metadata,8,4);
    if (EXTHSize<12) or (EXTHSize>MaxMetadata) or
      (Int64(EXTHSize)>Size-16-HeaderSize) or (Items>(EXTHSize-12) div 8) then Invalid;
    Metadata:=ReadAt(Offsets[Index]+16+HeaderSize,Integer(EXTHSize),MaxMetadata);
    CoverOffset:=Missing; ThumbOffset:=Missing;
    CoverSeen:=False; ThumbSeen:=False; BoundarySeen:=False; At:=12;
    for var I:=1 to Integer(Items) do
    begin
      Check; Key:=Number(Metadata,At,4); ItemSize:=Number(Metadata,At+4,4);
      if (ItemSize<8) or (ItemSize>Cardinal(Length(Metadata)-At)) then Invalid;
      if (Key=201) or (Key=202) or (Key=121) then
      begin
        if (ItemSize<>9) and (ItemSize<>10) and (ItemSize<>12) then Invalid;
        Value:=Number(Metadata,At+8,Integer(ItemSize)-8);
        if Key=201 then
        begin if CoverSeen then Invalid; CoverSeen:=True; CoverOffset:=Value; end
        else if Key=202 then
        begin if ThumbSeen then Invalid; ThumbSeen:=True; ThumbOffset:=Value; end
        else
        begin if BoundarySeen then Invalid; BoundarySeen:=True; Boundary:=Value; end;
      end;
      Inc(At,Integer(ItemSize));
    end;
    // An explicit cover takes precedence. A corrupt cover pointer must not
    // silently select some other illustration or the thumbnail instead.
    if CoverSeen and (CoverOffset<>Missing) then Value:=CoverOffset
    else if ThumbSeen and (ThumbOffset<>Missing) then
    begin Value:=ThumbOffset; IsThumbnail:=True; end
    else Exit;
    if (UInt64(Index)+FirstResource+Value>=UInt64(Records)) or (FirstResource=0) then Invalid;
    ImageRecord:=Cardinal(UInt64(Index)+FirstResource+Value);
    if ImageRecord<=LastTextRecord then Invalid;
  end;
  function LegacyGuideRecord(EndRecord:Cardinal):Cardinal;
  var Info:TBytes; HeaderLength,FirstResource,TextLength:Cardinal;
      Compression,TextRecords,ExtraFlags,Image:Integer;
  begin
    Result:=Missing;
    Info:=ReadAt(Offsets[0],Integer(Min(RecordSize(0),Int64(244))),244);
    HeaderLength:=Number(Info,20,4);
    if (Number(Info,36,4)>=8) or (Number(Info,12,2)<>0) then Exit;
    Compression:=Number(Info,0,2);
    if (Compression<>1) and (Compression<>2) then Exit;
    TextRecords:=Number(Info,8,2);
    TextLength:=Number(Info,4,4);
    if (TextRecords=0) or (TextLength=0) then Exit;
    FirstResource:=Missing;
    if HeaderLength>=96 then FirstResource:=Number(Info,108,4);
    if FirstResource=Missing then FirstResource:=Cardinal(TextRecords)+1;
    if (FirstResource<=Cardinal(TextRecords)) or (FirstResource>=EndRecord) then Exit;
    ExtraFlags:=0;
    if (HeaderLength>=228) and (Number(Info,104,4)>=5) then ExtraFlags:=Number(Info,242,2);
    if (Compression=1) and (ExtraFlags=0) and (TextRecords=1) and
      (RecordSize(1)>Int64(TextLength)+3) then Exit;
    Image:=KindleGuideImage(Stream,Offsets,TextRecords,Compression,ExtraFlags,TextLength,IsCanceled);
    if Image=0 then Exit;
    if UInt64(FirstResource)+Cardinal(Image)-1>=EndRecord then Invalid;
    Result:=FirstResource+Cardinal(Image)-1;
  end;
begin
  Result:=nil; Status:='';
  if not Assigned(Stream) then raise EArgumentNilException.Create('Stream');
  Saved:=Stream.Position;
  try
    try
      Check; FileSize:=Stream.Size;
      if FileSize<78 then Invalid;
      Header:=ReadAt(0,78,78);
      if not Magic(Header,60,'BOOKMOBI') then
      begin Status:='В этом формате нет поддерживаемой обложки MOBI/KF8.'; Exit; end;
      if (Number(Header,32,2) and 1<>0) or (Number(Header,72,4)<>0) then
        raise EReadError.Create('Не поддерживается эта таблица записей Kindle/Palm.');
      Records:=Number(Header,76,2); if Records=0 then Invalid;
      Table:=ReadAt(78,Records*8,65535*8); SetLength(Offsets,Records+1);
      for var I:=0 to Records-1 do
      begin
        Check; Offsets[I]:=Number(Table,I*8,4);
        if (Offsets[I]<78+Records*8) or (Offsets[I]>=FileSize) then Invalid;
        if (I>0) and (Offsets[I]<=Offsets[I-1]) then Invalid;
      end;
      Offsets[Records]:=FileSize;
      ReadHeader(0,CoverRecord,NextHeader,LastText,Thumbnail);
      if (CoverRecord=Missing) and (NextHeader<>Missing) then
      begin
        if (UInt64(NextHeader)<=UInt64(LastText)+1) or (NextHeader>=Cardinal(Records)) then Invalid;
        // Follow only the declared KF8 boundary, never scan arbitrary records.
        if RecordSize(NextHeader-1)<>8 then Invalid;
        Header:=ReadAt(Offsets[NextHeader-1],8,8);
        if not Magic(Header,0,'BOUNDARY') then Invalid;
        var Unused:Cardinal;
        ReadHeader(NextHeader,CoverRecord,Unused,LastText,Thumbnail);
      end;
      if CoverRecord=Missing then
      begin
        var EndRecord:=Cardinal(Records);
        if NextHeader<>Missing then EndRecord:=NextHeader-1;
        CoverRecord:=LegacyGuideRecord(EndRecord);
      end;
      if CoverRecord=Missing then
      begin Status:='В метаданных Kindle не указана обложка или её миниатюра.'; Exit; end;
      var Size:=RecordSize(CoverRecord);
      if (Size<=0) or (Size>MaxCover) then
        raise EReadError.Create('Обложка Kindle превышает допустимый размер 16 МБ.');
      Result:=ReadAt(Offsets[CoverRecord],Integer(Size),MaxCover);
      if Thumbnail then Status:='Миниатюра обложки из метаданных Kindle.';
    except
      on E:EStreamError do begin Result:=nil; Status:=E.Message; end;
    end;
  finally Stream.Position:=Saved; end;
end;

end.
