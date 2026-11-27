unit unit_DjvuRecovery;

interface

uses System.SysUtils;

type
  TDjvuComponent = record
    Kind: AnsiChar;
    Size: Integer;
    Identifier, FileName: UTF8String;
  end;

function RecoverBundledDjvu(const Source, Directory: string;
  const ReadComponents: TFunc<TArray<TDjvuComponent>>): Boolean;

implementation

uses
  System.Classes, System.IOUtils, System.Math, System.Generics.Collections;

const
  MaxSourceBytes = 256 * 1024 * 1024;
  MaxMissingBytes = 64 * 1024;
  DirectoryOffset = 16;
  OffsetTable = 27;

function BigEndian(const Data: TBytes; Offset, Bytes: Integer): Cardinal;
begin
  Result := 0;
  for var I := Offset to Offset + Bytes - 1 do
    Result := (Result shl 8) or Data[I];
end;

function HasTag(const Data: TBytes; Offset: Integer; const Tag: AnsiString): Boolean;
begin
  if (Offset < 0) or (Offset > Length(Data) - Length(Tag)) then Exit(False);
  for var I := 1 to Length(Tag) do
    if Data[Offset + I - 1] <> Byte(Tag[I]) then Exit(False);
  Result := True;
end;

procedure WriteSize(Stream: TStream; Size: Cardinal);
var
  Encoded: array[0..3] of Byte;
begin
  for var I := High(Encoded) downto 0 do
  begin
    Encoded[I] := Byte(Size and $FF);
    Size := Size shr 8;
  end;
  Stream.WriteBuffer(Encoded,SizeOf(Encoded));
end;

procedure WriteTag(Stream: TStream; const Tag: AnsiString);
begin
  Stream.WriteBuffer(Tag[1],Length(Tag));
end;

function SafeComponentName(const Name: UTF8String; Kind: AnsiChar): Boolean;
begin
  Result := False;
  if (Length(Name) < 6) or (Length(Name) > 96) then Exit;
  for var I := 1 to Length(Name) do
    if not CharInSet(Name[I], ['a'..'z','A'..'Z','0'..'9','_','-','.']) then Exit;
  if not CharInSet(Name[1], ['a'..'z','A'..'Z','0'..'9']) then Exit;
  var Dot := Pos('.',Name);
  var Stem := UpperCase(string(Copy(Name,1,Dot - 1)));
  if (Stem='CON') or (Stem='PRN') or (Stem='AUX') or (Stem='NUL') or
     ((Length(Stem)=4) and (Stem.StartsWith('COM') or Stem.StartsWith('LPT')) and
       CharInSet(Stem[4],['0'..'9'])) then Exit;
  var Extension := ExtractFileExt(string(Name));
  if Kind = 'P' then Result := SameText(Extension,'.djvu') and not SameText(string(Name),'index.djvu')
  else if Kind = 'I' then Result := SameText(Extension,'.djbz');
end;

function ComponentStart(const Data: TBytes; Expected, Lost, Previous: Integer;
  const Info: TDjvuComponent): Integer;
begin
  Result := -1;
  for var Offset := Max(Expected - Lost,Previous + 1) to Min(Expected,Length(Data) - 16) do
  begin
    if not HasTag(Data,Offset,'FORM') or (BigEndian(Data,Offset + 4,4) <> Cardinal(Info.Size - 8)) then Continue;
    if Info.Kind = 'P' then
    begin
      if not HasTag(Data,Offset + 8,'DJVUINFO') then Continue;
    end
    else if not HasTag(Data,Offset + 8,'DJVIDjbz') then Continue;
    // Ambiguous frame boundaries cannot establish a page's original identity.
    if Result >= 0 then Exit(-1);
    Result := Offset;
  end;
end;

function CompleteComponent(const Data: TBytes; Start, Span, Size: Integer;
  const Includes: TDictionary<UTF8String,Integer>; out References: TArray<Integer>): Boolean;
var
  Offset, Last, ChunkEnd, RefIndex: Integer;
  LengthOnDisk: Cardinal;
  Name: UTF8String;
begin
  Result := False;
  References := nil;
  if (Span < Size) or (Span > Size + (Size and 1)) then Exit;
  Offset := Start + 12;
  Last := Start + Size;
  while Offset < Last do
  begin
    if Last - Offset < 8 then Exit;
    for var I := Offset to Offset + 3 do
      if not CharInSet(AnsiChar(Data[I]), ['0'..'9','A'..'Z','a'..'z',' ']) then Exit;
    if HasTag(Data,Offset,'FORM') or HasTag(Data,Offset,'LIST') or HasTag(Data,Offset,'CAT ') then Exit;
    LengthOnDisk := BigEndian(Data,Offset + 4,4);
    if LengthOnDisk > Cardinal(Last - Offset - 8) then Exit;
    ChunkEnd := Offset + 8 + Integer(LengthOnDisk);
    if HasTag(Data,Offset,'INCL') then
    begin
      if (LengthOnDisk = 0) or (LengthOnDisk > 96) then Exit;
      SetString(Name,PAnsiChar(@Data[Offset + 8]),Integer(LengthOnDisk));
      if not Includes.TryGetValue(Name,RefIndex) then Exit;
      References := References + [RefIndex];
    end;
    Offset := ChunkEnd;
    if (Offset < Last) and (Odd(LengthOnDisk)) then Inc(Offset);
  end;
  Result := Offset = Last;
end;

function RecoverBundledDjvu(const Source, Directory: string;
  const ReadComponents: TFunc<TArray<TDjvuComponent>>): Boolean;
var
  Input, Output: TFileStream;
  Data: TBytes;
  ExpectedEnd, TablesEnd, DirectoryEnd, OutlineEnd, PrefixEnd, Lost, Count, EndOffset, CompletePages: Integer;
  Parts: TArray<TDjvuComponent>;
  Original, Physical: TArray<Integer>;
  Complete: TArray<Boolean>;
  References: TArray<TArray<Integer>>;
  Names: TDictionary<string,Boolean>;
  Includes: TDictionary<UTF8String,Integer>;
  OldIndexSize, OutlineSize: Cardinal;
  IndexSize, IndexTotal: Integer;
  Marker, Padding: Byte;
begin
  Result := False;
  Input := TFileStream.Create(Source,fmOpenRead or fmShareDenyWrite);
  try
    if (Input.Size < OffsetTable) or (Input.Size > MaxSourceBytes) then Exit;
    SetLength(Data,OffsetTable);
    Input.ReadBuffer(Data[0],Length(Data));
    if not HasTag(Data,0,'AT&TFORM') or not HasTag(Data,12,'DJVMDIRM') or (Data[24] <> $81) then Exit;
    var Declared := BigEndian(Data,8,4);
    if (Declared > MaxSourceBytes) or (Int64(Declared) + 12 <= Input.Size) then Exit;
    ExpectedEnd := Integer(Declared) + 12;
    Lost := ExpectedEnd - Integer(Input.Size);
    Count := Integer(BigEndian(Data,25,2));
    if (Lost > MaxMissingBytes) or (Count < 2) or (Int64(Lost)*Count > 16*1024*1024) then Exit;
    OldIndexSize := BigEndian(Data,20,4);
    TablesEnd := OffsetTable + Count*4;
    if (OldIndexSize > Cardinal(Input.Size - 24)) or (TablesEnd >= Integer(OldIndexSize) + 24) then Exit;
    DirectoryEnd := Integer(OldIndexSize) + 24;
    PrefixEnd := DirectoryEnd + (DirectoryEnd and 1);
    SetLength(Data,Integer(Input.Size));
    Input.ReadBuffer(Data[OffsetTable],Length(Data) - OffsetTable);
  finally
    Input.Free;
  end;

  SetLength(Original,Count+1);
  for var I := 0 to Count-1 do
  begin
    var Offset := BigEndian(Data,OffsetTable + I*4,4);
    if (Offset < Cardinal(PrefixEnd)) or (Offset >= Cardinal(ExpectedEnd)) or Odd(Offset) or
       ((I > 0) and (Offset <= Cardinal(Original[I-1]))) then Exit;
    Original[I] := Integer(Offset);
  end;
  Original[Count] := ExpectedEnd;
  OutlineEnd := PrefixEnd;
  if Original[0] <> PrefixEnd then
  begin
    if not HasTag(Data,PrefixEnd,'NAVM') or (PrefixEnd > Length(Data) - 8) then Exit;
    OutlineSize := BigEndian(Data,PrefixEnd + 4,4);
    if OutlineSize > Cardinal(Length(Data)-PrefixEnd-8) then Exit;
    OutlineEnd := PrefixEnd + 8 + Integer(OutlineSize) + Integer(OutlineSize and 1);
    if OutlineEnd <> Original[0] then Exit;
  end;

  Parts := ReadComponents();
  if Length(Parts) <> Count then Exit;
  SetLength(Physical,Count+1);
  SetLength(Complete,Count);
  SetLength(References,Count);
  Physical[Count] := Length(Data);
  Names := TDictionary<string,Boolean>.Create;
  Includes := TDictionary<UTF8String,Integer>.Create;
  try
    var Previous := Original[0] - 1;
    var MissingBefore := 0;
    for var I := 0 to Count-1 do
    begin
      var Part := Parts[I];
      if not SafeComponentName(Part.FileName,Part.Kind) or (Part.Identifier <> Part.FileName) or
         not Names.TryAdd(LowerCase(string(Part.FileName)),True) or
         (Part.Size < 20) or (Part.Size > MaxSourceBytes) then Exit;
      EndOffset := Original[I] + Part.Size;
      if (EndOffset <> Original[I+1]) and (EndOffset + (Part.Size and 1) <> Original[I+1]) then Exit;
      var First := ComponentStart(Data,Original[I] - MissingBefore,Lost - MissingBefore,Previous,Part);
      if (First < 0) or ((I = 0) and (First <> Original[0])) then Exit;
      Physical[I] := First;
      Previous := First;
      MissingBefore := Original[I] - First;
      if Part.Kind = 'I' then Includes.Add(Part.Identifier,I);
    end;
    if MissingBefore = 0 then Exit;
    for var I := 0 to Count-1 do
    begin
      Complete[I] := CompleteComponent(Data,Physical[I],Physical[I+1] - Physical[I],
        Parts[I].Size,Includes,References[I]);
      if (Parts[I].Kind = 'I') and (Length(References[I]) <> 0) then Complete[I] := False;
    end;
    CompletePages := 0;
    for var I := 0 to Count-1 do
      if Complete[I] and (Parts[I].Kind = 'P') then
      begin
        for var Ref in References[I] do
          if not Complete[Ref] then
          begin Complete[I] := False; Break; end;
        if Complete[I] then Inc(CompletePages);
      end;
    if (CompletePages = 0) or not TDirectory.Exists(Directory) or
       (Length(TDirectory.GetFileSystemEntries(Directory)) <> 0) then Exit;

    for var I := 0 to Count-1 do
      if Complete[I] then
      begin
        Output := TFileStream.Create(TPath.Combine(Directory,string(Parts[I].FileName)),fmCreate);
        try
          WriteTag(Output,'AT&T');
          Output.WriteBuffer(Data[Physical[I]],Parts[I].Size);
        finally
          Output.Free;
        end;
      end;
    // Keep the decoder's original directory metadata and page numbering.
    // Indirect directories omit the bundled offsets and keep the same IDs.
    IndexSize := Integer(OldIndexSize) - Count*4;
    IndexTotal := 12 + IndexSize + (IndexSize and 1) + OutlineEnd - PrefixEnd;
    Marker := $01;
    Padding := 0;
    Output := TFileStream.Create(TPath.Combine(Directory,'index.djvu'),fmCreate);
    try
      WriteTag(Output,'AT&TFORM');
      WriteSize(Output,IndexTotal);
      WriteTag(Output,'DJVMDIRM');
      WriteSize(Output,IndexSize);
      Output.WriteBuffer(Marker,1);
      Output.WriteBuffer(Data[25],2);
      Output.WriteBuffer(Data[TablesEnd],DirectoryEnd - TablesEnd);
      if Odd(IndexSize) then Output.WriteBuffer(Padding,1);
      if OutlineEnd > PrefixEnd then Output.WriteBuffer(Data[PrefixEnd],OutlineEnd - PrefixEnd);
    finally
      Output.Free;
    end;
    Result := True;
  finally
    Includes.Free;
    Names.Free;
  end;
end;

end.
