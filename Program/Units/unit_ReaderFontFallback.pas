unit unit_ReaderFontFallback;

interface

uses Vcl.ComCtrls;

procedure ApplyReaderFallbackFonts(Edit: TRichEdit; const Text, BaseFont: string;
  const Language: string = ''; StartOffset: Integer = 0);

implementation

uses Winapi.Windows, Winapi.Messages, Winapi.RichEdit, System.SysUtils,
  System.Generics.Collections, unit_ReaderFonts;

var Coverage: TDictionary<string,TBytes>;

function FontCoverage(const Name: string): TBytes;
var DC: HDC; Font, Previous: HGDIOBJ; Chars: TArray<WideChar>; Glyphs: TArray<Word>; I: Integer;
begin
  if Coverage.TryGetValue(Name,Result) then Exit;
  SetLength(Result,65536); SetLength(Chars,65536); SetLength(Glyphs,65536);
  for I:=0 to High(Chars) do Chars[I]:=WideChar(I);
  DC:=CreateCompatibleDC(0);
  if DC=0 then Exit;
  Font:=CreateFontW(-20,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,PChar(Name));
  try
    Previous:=SelectObject(DC,Font);
    try
      if GetGlyphIndicesW(DC,PWideChar(Chars),Length(Chars),PWord(Glyphs),
        GGI_MARK_NONEXISTING_GLYPHS)<>GDI_ERROR then
        for I:=0 to High(Glyphs) do if (Glyphs[I]<>$FFFF) and (Glyphs[I]<>0) then Result[I]:=1;
    finally SelectObject(DC,Previous); end;
  finally DeleteObject(Font); DeleteDC(DC); end;
  Coverage.Add(Name,Result);
end;

function ScriptFont(Code: Cardinal; Sans: Boolean; const CJK: string): string;
var Script, Prefix: string;
begin
  Script:='';
  case Code of
    $0530..$058F: Script:='Armenian';
    $0590..$05FF,$FB1D..$FB4F: Script:='Hebrew';
    $0600..$06FF,$0750..$077F,$08A0..$08FF,$FB50..$FDFF,$FE70..$FEFF:
      begin if Sans then Exit('Noto Sans Arabic') else Exit('Noto Naskh Arabic'); end;
    $0700..$074F,$0860..$086F: Exit('Noto Sans Syriac');
    $0780..$07BF: Exit('Noto Sans Thaana');
    $0900..$097F,$A8E0..$A8FF: Script:='Devanagari';
    $0980..$09FF: Script:='Bengali';
    $0A00..$0A7F: Script:='Gurmukhi';
    $0A80..$0AFF: Script:='Gujarati';
    $0B00..$0B7F: Script:='Oriya';
    $0B80..$0BFF: Script:='Tamil';
    $0C00..$0C7F: Script:='Telugu';
    $0C80..$0CFF: Script:='Kannada';
    $0D00..$0D7F: Script:='Malayalam';
    $0D80..$0DFF: Script:='Sinhala';
    $0E00..$0E7F: Script:='Thai';
    $0E80..$0EFF: Script:='Lao';
    $0F00..$0FFF: Exit('Noto Serif Tibetan');
    $1000..$109F,$A9E0..$A9FF,$AA60..$AA7F: Script:='Myanmar';
    $10A0..$10FF,$1C90..$1CBF,$2D00..$2D2F: Script:='Georgian';
    $1200..$139F,$2D80..$2DDF,$AB00..$AB2F: Script:='Ethiopic';
    $1780..$17FF,$19E0..$19FF: Script:='Khmer';
    $1100..$11FF,$2E80..$2FFF,$3000..$30FF,$3100..$318F,$31A0..$33FF,
    $3400..$4DBF,$4E00..$9FFF,$A960..$A97F,$AC00..$D7FF,$F900..$FAFF,
    $FF00..$FFEF,$20000..$3134F:
      begin if Sans then Exit('Noto Sans CJK '+CJK) else Exit('Noto Serif CJK '+CJK); end;
    $2190..$2BFF,$1D000..$1D24F,$1F000..$1FFFF: Exit('Noto Sans Symbols2');
  end;
  if Sans then Prefix:='Noto Sans' else Prefix:='Noto Serif';
  if Script<>'' then Result:=Prefix+' '+Script else Result:=Prefix;
end;

procedure ApplyReaderFallbackFonts(Edit: TRichEdit; const Text, BaseFont, Language: string; StartOffset: Integer);
var Supported: TBytes; Sans: Boolean; CJK, RunFont, NextFont: string;
  I, Start, Units, SavedStart, SavedLength, ParagraphStart, J: Integer; Code: Cardinal;
  Character: TCharFormat2; Paragraph: TParaFormat2;
  procedure ApplyRun(Finish: Integer);
  begin
    if (RunFont='') or (Finish<=Start) or not EnsureReaderFont(RunFont) then Exit;
    var Selection: TCharRange;
    Selection.cpMin:=StartOffset+Start; Selection.cpMax:=StartOffset+Finish;
    SendMessage(Edit.Handle,EM_EXSETSEL,0,LPARAM(@Selection));
    FillChar(Character,SizeOf(Character),0); Character.cbSize:=SizeOf(Character);
    Character.dwMask:=CFM_FACE;
    StrPLCopy(PChar(@Character.szFaceName[0]),RunFont,LF_FACESIZE-1);
    SendMessage(Edit.Handle,EM_SETCHARFORMAT,SCF_SELECTION,LPARAM(@Character));
  end;
begin
  if Text='' then Exit;
  PrepareReaderFonts; Supported:=FontCoverage(BaseFont);
  Sans:=BaseFont.ToLower.Contains('sans') or SameText(BaseFont,'Segoe UI') or SameText(BaseFont,'Arial');
  CJK:='SC';
  if Language.StartsWith('ja',True) then CJK:='JP'
  else if Language.StartsWith('ko',True) then CJK:='KR'
  else if SameText(Language,'zh-Hant') or SameText(Language,'zh-TW') then CJK:='TC'
  else if Language='' then
    for I:=1 to Length(Text) do
      if (Ord(Text[I])>=$3040) and (Ord(Text[I])<=$30FF) then begin CJK:='JP'; Break; end
      else if (Ord(Text[I])>=$AC00) and (Ord(Text[I])<=$D7AF) then begin CJK:='KR'; Break; end;
  SavedStart:=Edit.SelStart; SavedLength:=Edit.SelLength;
  try
    RunFont:=''; Start:=0; I:=1;
    while I<=Length(Text) do
    begin
      Code:=Ord(Text[I]); Units:=1;
      if (Code>=$D800) and (Code<=$DBFF) and (I<Length(Text)) and
        (Ord(Text[I+1])>=$DC00) and (Ord(Text[I+1])<=$DFFF) then
      begin Code:=$10000+(Code-$D800)*$400+Ord(Text[I+1])-$DC00; Units:=2; end;
      NextFont:='';
      if (Code>=32) and (Code<>$FFFC) and ((Code>$FFFF) or (Supported[Code]=0)) then
        NextFont:=ScriptFont(Code,Sans,CJK);
      if NextFont<>RunFont then begin ApplyRun(I-1); RunFont:=NextFont; Start:=I-1; end;
      Inc(I,Units);
    end;
    ApplyRun(Length(Text));
    // RichEdit shapes complex scripts; retain source text and copy order.
    ParagraphStart:=1;
    while ParagraphStart<=Length(Text) do
    begin
      J:=ParagraphStart;
      while (J<=Length(Text)) and not CharInSet(Text[J],[#10,#13]) do Inc(J);
      for I:=ParagraphStart to J-1 do
      begin
        Code:=Ord(Text[I]);
        if ((Code>=$0590) and (Code<=$08FF)) then
        begin
          var Selection: TCharRange;
          Selection.cpMin:=StartOffset+ParagraphStart-1; Selection.cpMax:=StartOffset+J-1;
          SendMessage(Edit.Handle,EM_EXSETSEL,0,LPARAM(@Selection));
          FillChar(Paragraph,SizeOf(Paragraph),0); Paragraph.cbSize:=SizeOf(Paragraph);
          Paragraph.dwMask:=PFM_RTLPARA; Paragraph.wReserved:=PFE_RTLPARA;
          SendMessage(Edit.Handle,EM_SETPARAFORMAT,0,LPARAM(@Paragraph)); Break;
        end;
        if ((Code>=Ord('A')) and (Code<=Ord('Z'))) or
          ((Code>=Ord('a')) and (Code<=Ord('z'))) or (Code>=$0370) then Break;
      end;
      ParagraphStart:=J+1;
    end;
  finally Edit.SelStart:=SavedStart; Edit.SelLength:=SavedLength; end;
end;

initialization
  Coverage:=TDictionary<string,TBytes>.Create;
finalization
  Coverage.Free;
end.
