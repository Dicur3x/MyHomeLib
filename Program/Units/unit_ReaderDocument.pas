unit unit_ReaderDocument;

interface

uses System.SysUtils, System.Classes, System.Types, System.Generics.Collections, System.UITypes;

const
  ReaderEpubTruncatedChapterWarning = 'В главе EPUB не сохранились закрывающие теги';
  ReaderEpubDanglingTagWarning = 'В главе EPUB оборван открывающий тег';
  ReaderEpubMissingBodyWarning = 'В разделе EPUB отсутствует содержимое';
  ReaderEpubUnreadableStyleWarning = 'Таблица стилей EPUB недоступна';
  ReaderWordPageOverlayWarning = 'Белые накладки печатных страниц не показаны';

type
  TReaderTextEncoding = (rteAutomatic, rteUTF8, rteWindows1251, rteCP866, rteKOI8R,
    rteUTF16LE, rteUTF16BE, rteWindows1252);

  TReaderChapter = record
    Title: string;
    Position, Depth: Integer;
  end;

  // A read-only presentation. No source book or archive member is rewritten.
  TReaderPicture = record
    Bytes: TBytes;
    ArchiveMember: string;
    Width, Height: Integer;
    GoalWidth, GoalHeight, WidthPercentX100: Integer;
    CellWidth, CellInset: Integer;
    CaptionLength: Integer;
    PaintBounds, PaintClip, RuleBounds: TRect;
    RuleColor: Cardinal;
    Monochrome, OfficeImage, Unreadable, FillWidth, WordCanvas, MatchBookBackground: Boolean;
  end;

  TReaderBlockKind = (rbTitle, rbSubtitle, rbEpigraph, rbPoem, rbCite, rbAuthor, rbCode, rbFootnote, rbInitial, rbParagraphInitial, rbRelativeSize, rbLink, rbTextFrame, rbWordSpacer);
  TReaderStyledRange = record
    Start, Count, ScalePercent, SpacerFontTwips, SpacerRiseTwips: Integer;
    Kind: TReaderBlockKind;
  end;

  TReaderFootnoteLink = record
    Start, Count: Integer;
    Target, LabelText: string;
  end;

  TReaderTextLink = record
    Start, Count: Integer;
    Target: string;
  end;

  TReaderMarginRule = record
    Position, TopTwips, HeightTwips, WidthTwips, OffsetTwips, BandTwips: Integer;
    Leading: Boolean;
  end;

  TReaderParagraphShade = record
    Start, Finish: Integer;
    Color: Cardinal;
  end;

  TReaderDocument = class
  private type
    TLayoutInsertion = record
      Offset, Value, CellWidth, CellInset: Integer;
      IsPicture: Boolean;
    end;
    TTableColor = record
      Color: TColor;
      ForBackground: Boolean;
    end;
  private
    FBody, FText: TStringBuilder;
    FLayoutInsertions: TList<TLayoutInsertion>;
    FPlainRTF: UTF8String;
    FNativeRTF: RawByteString;
    FNativePictureOffsets: TArray<Integer>;
    FNativeRTFFallback: Boolean;
    FChapters: TList<TReaderChapter>;
    FStyles: TList<TReaderStyledRange>;
    FNoteLinks: TList<TReaderFootnoteLink>;
    FNoteBodies: TDictionary<string,string>;
    FNoteBodiesInText: TDictionary<string,Byte>;
    FLinks: TList<TReaderTextLink>;
    FMarginRules: TList<TReaderMarginRule>;
    FParagraphShades: TList<TReaderParagraphShade>;
    FCellColors: TList<TTableColor>;
    FHasCellBackgrounds: Boolean;
    FAnchors: TDictionary<string,Integer>;
    FImages, FSkippedImages, FPartialDrawingGroups, FOpeningCoverEnd: Integer;
    FHasTables, FNotesInBody: Boolean;
    FCellWidth, FCellInset: Integer;
    FPictures: TList<TReaderPicture>;
    FImageArchiveName: string;
    FImageArchiveLock: TFileStream;
    procedure AddText(const Value: string; PreserveWhitespace: Boolean = False);
    procedure AddPreformattedText(const Value: string);
    procedure Paragraph;
    procedure Chapter(const Value: string; Depth: Integer = 0; Position: Integer = -1);
    function RegisterPicture(const Bytes: TBytes; OfficeImage: Boolean; const ArchiveMember: string;
      DisplayWidth: Integer = 0; DisplayHeight: Integer = 0): Integer;
    procedure Picture(const Bytes: TBytes; OfficeImage: Boolean = False; const ArchiveMember: string = '';
      const Caption: string = ''; LeftAligned: Boolean = False; DisplayWidth: Integer = 0; DisplayHeight: Integer = 0;
      RuleHeight: Integer = 0; InlinePicture: Boolean = False; SizeInTwips: Boolean = False; LeftTwips: Integer = 0;
      WordCanvas: Boolean = False; WidthPercentX100: Integer = 0);
    procedure NoteUnreadableImage(const Detail: string);
    procedure MakeRecentCover(const Bytes: TBytes);
    function PictureHeader(Index, MaxWidth, MaxHeight: Integer; LayoutOnly: Boolean): UTF8String;
  public
    Title, FormatName, Language, Author, RecentCover: string;
    Warnings: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Load(const FileName: string; const Canceled: TFunc<Boolean> = nil;
      TextEncoding: TReaderTextEncoding = rteAutomatic);
    function RTF(MaxPictureWidth: Integer = 500; MaxPictureHeight: Integer = 500;
      LayoutOnly: Boolean = False; Background: TColor = $00FFFFFF;
      const CellColor: TFunc<TColor,TColor> = nil): UTF8String;
    function PictureRTF(Index, MaxWidth, MaxHeight: Integer; LayoutOnly: Boolean = False;
      Background: TColor = $00FFFFFF): UTF8String;
    function PictureUsesBackground(Index: Integer): Boolean;
    function PictureExtent(Index, MaxWidth, MaxHeight: Integer): TPoint;
    function PictureCaptionLength(Index: Integer): Integer;
    procedure ReleasePlainText;
    // Native text owns the layout; compressed picture bytes support reflow.
    procedure ReleaseUnusedBuffers;
    function PlainText: string;
    function Chapters: TArray<TReaderChapter>;
    function Styles: TArray<TReaderStyledRange>;
    function FootnoteCount: Integer;
    function HasFootnotes: Boolean;
    function FootnoteAt(Position: Integer; out Start, Count: Integer): string;
    function Links: TArray<TReaderTextLink>;
    function HasLinks: Boolean;
    function LinkTargetAt(Position: Integer; out Target: Integer): Boolean;
    function MarginRules(Start, Finish: Integer): TArray<TReaderMarginRule>;
    function HasMarginRules: Boolean;
    function HasCellBackgrounds: Boolean;
    function ParagraphShades(Start, Finish: Integer): TArray<TReaderParagraphShade>;
    function FootnotesForRange(Start, Finish: Integer; MaxCharacters: Integer = 32768;
      SkipNotesInText: Boolean = False): string;
    property ImageCount: Integer read FImages;
    property OpeningCoverEnd: Integer read FOpeningCoverEnd;
    property SkippedImages: Integer read FSkippedImages;
    property PartialDrawingGroups: Integer read FPartialDrawingGroups;
    property HasTables: Boolean read FHasTables;
    property NotesInBody: Boolean read FNotesInBody;
    property NativeRTFFallback: Boolean read FNativeRTFFallback;
  end;

function ReaderDecodeText(const Bytes: TBytes; DetectLegacy: Boolean = False): string;
function ReaderSupportsReflow(const FileName: string): Boolean;
function ReaderSupportsTextEncoding(const FileName: string): Boolean;
function ReaderHasCompleteEpubSpine(const FileName: string; const Canceled: TFunc<Boolean>): Boolean;

implementation

uses Winapi.Windows, Winapi.ActiveX, System.IOUtils, System.Math, System.Hash,
  System.RegularExpressions, System.StrUtils, System.NetEncoding, System.Zip, System.Variants,
  System.Character, System.Win.ComObj, Winapi.MSXML, Vcl.Graphics, Vcl.Imaging.jpeg, Vcl.Imaging.pngimage, unit_ImageBounds, unit_FB2Utils, unit_ReaderMIME, unit_ReaderFormats, unit_ReaderCSS, unit_MHLExternalTools, unit_FB2Encoding, unit_BookCache, unit_SvgBookCover, unit_ReaderRaster, unit_ReaderRTF, unit_Diagnostics, unit_ReaderDOC, unit_ReaderLegacy, unit_Fb3Package;

const
  MAX_DOCUMENT_BYTES = 64 * 1024 * 1024;
  MAX_EPUB_BYTES = 256 * 1024 * 1024;
  MAX_SCAN_EPUB_BYTES = Int64(3 * 1024 + 64) * 1024 * 1024;
  MAX_HTML_IMAGE_PIXELS = 32768;
  READER_RTF_HEADER: UTF8String = '{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\fcharset204 Georgia;}{\f1\fcharset204 Consolas;}{\f2\fcharset0 Courier New;}}\uc1\f0\fs28 ';

type
  EReaderUnsupportedPicture = class(EReadError);

// TXT needs no intermediate Unicode RTF builders. Count once, then encode
// straight into one immutable ASCII/UTF8 buffer retained by the native stream.
function PlainTextRTF(const Value: string; const Canceled: TFunc<Boolean>;
  Frames: TList<TReaderStyledRange>): UTF8String;
const OpenFrame: UTF8String = '{\f1 ';
type
  TLine = record
    Start, Finish, Number: Integer;
    HasText, HasBoxDrawing: Boolean;
    Gaps: TList<TPoint>;
  end;
var I, Code, Magnitude, Digits, J, At, GapStart, FrameIndex: Integer;
  Total: Int64; C: Char; Frame: TReaderStyledRange;
  Current, Previous, Older: TLine;
  Number: array[0..4] of AnsiChar;
  function AlignedColumns(First, Second, Third: TList<TPoint>): Boolean;
  var A, B, C, RightEdge, Width, GapCount: Integer;
    One, Two, Three: TPoint;
  begin
    // Keep common whitespace between fields, including right-aligned data.
    A:=0; B:=0; C:=0; GapCount:=0;
    while (A<First.Count) and (B<Second.Count) and (C<Third.Count) do
    begin
      One:=First[A]; Two:=Second[B]; Three:=Third[C];
      RightEdge:=Min(One.Y,Min(Two.Y,Three.Y));
      Width:=RightEdge-Max(One.X,Max(Two.X,Three.X));
      if Width>=5 then Exit(True);
      if Width>=2 then
      begin
        Inc(GapCount);
        if GapCount>=3 then Exit(True);
      end;
      if One.Y=RightEdge then Inc(A);
      if Two.Y=RightEdge then Inc(B);
      if Three.Y=RightEdge then Inc(C);
    end;
    Result:=False;
  end;
  function IsDrawingLabel(const Drawing, Candidate: TLine): Boolean;
  var At, FirstDigit, AfterDigits, Col, SymbolIndex: Integer;
  begin
    At:=Candidate.Start+1;
    while (At<=Candidate.Finish) and (Value[At]=' ') do Inc(At);
    FirstDigit:=At;
    if FirstDigit<Candidate.Start+3 then Exit(False);
    while (At<=Candidate.Finish) and CharInSet(Value[At],['0'..'9']) do Inc(At);
    AfterDigits:=At;
    if AfterDigits=FirstDigit then Exit(False);
    while (At<=Candidate.Finish) and (Value[At]=' ') do Inc(At);
    if At<=Candidate.Finish then Exit(False);
    for Col:=FirstDigit-Candidate.Start to AfterDigits-Candidate.Start-1 do
    begin
      SymbolIndex:=Drawing.Start+Col;
      if (SymbolIndex<=Drawing.Finish) and (Ord(Value[SymbolIndex])>=$2500) and
        (Ord(Value[SymbolIndex])<=$257F) then Exit(True);
    end;
    Result:=False;
  end;
  procedure KeepLines(First, Last: Integer);
  begin
    // Confirming several rows can extend back into an earlier drawing.
    while (Frames.Count>0) and (Frames.Last.Start+Frames.Last.Count+1>=First) do
    begin
      First:=Min(First,Frames.Last.Start);
      Frames.Delete(Frames.Count-1);
    end;
    Frame:=Default(TReaderStyledRange); Frame.Kind:=rbTextFrame;
    Frame.Start:=First; Frame.Count:=Last-First; Frames.Add(Frame);
  end;
  procedure FinishLine(LineEnd: Integer);
  var First: Integer; Reuse: TList<TPoint>;
  begin
    if Current.HasText then
    begin
      First:=Current.Start; Current.Finish:=LineEnd;
      if Previous.HasText and (Current.Number-Previous.Number<=2) then
      begin
        if ((Current.HasBoxDrawing or Previous.HasBoxDrawing) and
            AlignedColumns(Previous.Gaps,Current.Gaps,Current.Gaps)) or
          (Previous.HasBoxDrawing and IsDrawingLabel(Previous,Current)) or
          (Current.HasBoxDrawing and IsDrawingLabel(Current,Previous)) then First:=Previous.Start;
        if Older.HasText and (Previous.Number-Older.Number<=2) and
          AlignedColumns(Older.Gaps,Previous.Gaps,Current.Gaps) then First:=Older.Start;
      end;
      if Current.HasBoxDrawing or (First<Current.Start) then KeepLines(First,LineEnd);
      Reuse:=Older.Gaps; Older:=Previous; Previous:=Current; Current.Gaps:=Reuse;
      Current.Gaps.Clear;
    end;
    Current.Start:=LineEnd+1; Inc(Current.Number);
    Current.HasText:=False; Current.HasBoxDrawing:=False; GapStart:=-1;
  end;
  procedure Check;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
    if Total>128*1024*1024 then raise Exception.Create('Книга слишком велика для встроенной читалки.');
  end;
  procedure Emit(C: AnsiChar);
  begin Result[At]:=C; Inc(At); end;
  procedure EmitControl(const Value: UTF8String);
  var K: Integer;
  begin for K:=1 to Length(Value) do Emit(Value[K]); end;
begin
  Total:=Length(READER_RTF_HEADER)+1;
  Current:=Default(TLine); Previous:=Default(TLine); Older:=Default(TLine);
  try
    Current.Gaps:=TList<TPoint>.Create; Previous.Gaps:=TList<TPoint>.Create;
    Older.Gaps:=TList<TPoint>.Create; GapStart:=-1;
    for I:=1 to Length(Value) do
    begin
      if (I and 4095)=0 then Check;
      C:=Value[I];
      case C of
        #13: FinishLine(I-1);
        ' ': if (GapStart<0) and Current.HasText and (I>1) and not CharInSet(Value[I-1],[#9,' ']) then GapStart:=I-1;
        #9: GapStart:=-1;
        #10: ;
      else
        if (GapStart>=0) and (I-1-GapStart>=2) then
          Current.Gaps.Add(Point(GapStart-Current.Start,I-1-Current.Start));
        GapStart:=-1; Current.HasText:=True;
        if (Ord(C)>=$2500) and (Ord(C)<=$257F) then Current.HasBoxDrawing:=True;
      end;
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
    FinishLine(Length(Value));
  finally
    Current.Gaps.Free; Previous.Gaps.Free; Older.Gaps.Free;
  end;
  Inc(Total,Int64(Frames.Count)*(Length(OpenFrame)+1));
  Check; SetLength(Result,Integer(Total));
  Move(READER_RTF_HEADER[1],Result[1],Length(READER_RTF_HEADER));
  At:=Length(READER_RTF_HEADER)+1; FrameIndex:=0;
  for I:=1 to Length(Value) do
  begin
    if (I and 4095)=0 then Check;
    if FrameIndex<Frames.Count then
    begin
      Frame:=Frames[FrameIndex];
      if I-1=Frame.Start then EmitControl(OpenFrame)
      else if I-1=Frame.Start+Frame.Count then begin Emit('}'); Inc(FrameIndex); end;
    end;
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
  if FrameIndex<Frames.Count then Emit('}');
  Emit('}');
  Assert(At=Length(Result)+1,'Incorrect TXT RTF byte count');
end;

function ReaderSupportsReflow(const FileName: string): Boolean;
var E: string;
begin
  E := LowerCase(ExtractFileExt(FileName));
  Result := IsBuiltinReaderFormat(E) and (E<>'.pdf');
end;

function DecodePlainTextBytes(const Bytes: TBytes; CodePage: Cardinal; Start, Count: Integer): string;
var Size: Integer;
begin
  if Count=0 then Exit('');
  Size:=MultiByteToWideChar(CodePage,0,PAnsiChar(@Bytes[Start]),Count,nil,0);
  if Size=0 then RaiseLastOSError;
  SetLength(Result,Size);
  if MultiByteToWideChar(CodePage,0,PAnsiChar(@Bytes[Start]),Count,PChar(Result),Size)<>Size then
    RaiseLastOSError;
end;

function PlainTextLegacyCodePage(const Bytes: TBytes): Integer;
const
  CodePages: array[0..2] of Integer = (1251,866,20866);
  CommonWords: array[0..43] of string = (
    'без','был','была','были','будет','для','его','если','еще','ещё','или','как','когда','кто',
    'между','может','можно','над','надо','наш','него','нее','неё','они','она','оно','при','после',
    'перед','про','раз','себя','так','там','тебе','тоже','только','хотя','через','что','чтобы','этот','эта','это');
type
  TTextEvidence = record Hits, Distinct, Letters: Integer; end;
var
  Scores: array[0..2] of TTextEvidence;
  SampleSize, Utf8Letters: Integer;
  function Evidence(const Sample: string): TTextEvidence;
  var Seen: set of 0..43; Index: Integer;
  begin
    Result:=Default(TTextEvidence); Seen:=[];
    for var Word in TRegEx.Matches(Sample.ToLowerInvariant,'[а-яё]+') do
    begin
      Inc(Result.Letters,Word.Length);
      Index:=IndexStr(Word.Value,CommonWords);
      if Index<0 then Continue;
      Inc(Result.Hits);
      if not (Index in Seen) then begin Include(Seen,Index); Inc(Result.Distinct); end;
    end;
  end;
begin
  // Keep the bounded evidence test in sync with plain_text_encoding in the converter.
  SampleSize:=Min(Length(Bytes),65536);
  for var I:=Low(CodePages) to High(CodePages) do
    Scores[I]:=Evidence(DecodePlainTextBytes(Bytes,CodePages[I],0,SampleSize));
  Utf8Letters:=Evidence(DecodePlainTextBytes(Bytes,CP_UTF8,0,SampleSize)).Letters;
  for var I:=1 to High(CodePages) do
    if (Scores[I].Distinct>=3) and (Scores[I].Hits>=2*Max(Scores[0].Hits,Scores[3-I].Hits)+4) and
      (Scores[I].Letters>=Max(24,4*Utf8Letters)) then Exit(CodePages[I]);
  Result:=1251;
end;

function RestoreDOSListMarkers(const Text: string): string;
var Markers: Integer;
begin
  Result:=Text;
  if Pos(#7,Text)=0 then Exit;
  Markers:=TRegEx.Matches(Text,#7).Count;
  // Only restore the DOS glyph when all such bytes introduce list items.
  if (Markers>=3) and
    (TRegEx.Matches(Text,'(?:^|[\r\n])[ \t]*\x07(?=[ \t]*[A-Za-zА-Яа-яЁё0-9])').Count=Markers) then
    Result:=Text.Replace(#7,#$2022);
end;

function ReaderDecodeText(const Bytes: TBytes; DetectLegacy: Boolean): string;
var Enc: TEncoding; Start, Count, CodePage: Integer;
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
  if DetectLegacy then
  begin
    if Start>0 then Exit(DecodePlainTextBytes(Bytes,CP_UTF8,Start,Count-Start));
    CodePage:=PlainTextLegacyCodePage(Bytes);
    Result:=DecodePlainTextBytes(Bytes,CodePage,0,Count);
    if CodePage=866 then Result:=RestoreDOSListMarkers(Result);
    Exit;
  end;
  Enc := TEncoding.GetEncoding(1251);
  try Result := Enc.GetString(Bytes); finally Enc.Free; end;
end;

function IsReaderPlainText(const Extension: string): Boolean;
begin
  Result:=MatchText(Extension,['.txt','.md','.markdown','.faq','.wri']);
end;

function IsReaderHTML(const Extension: string): Boolean;
begin
  Result:=MatchText(Extension,['.html','.htm','.shtml','.xhtml']);
end;

function ReaderSupportsTextEncoding(const FileName: string): Boolean;
var Extension: string;
begin
  Extension:=ExtractFileExt(FileName);
  Result:=SameText(Extension,'.fb2') or IsReaderPlainText(Extension) or IsReaderHTML(Extension);
end;

const ReaderCodePages: array[TReaderTextEncoding] of Integer = (0,65001,1251,866,20866,1200,1201,1252);

function DecodeSelectedEncoding(const Bytes: TBytes; TextEncoding: TReaderTextEncoding;
  DetectLegacy: Boolean = False): string;
var Encoding: TEncoding;
begin
  if TextEncoding=rteAutomatic then Exit(ReaderDecodeText(Bytes,DetectLegacy));
  if Length(Bytes)=0 then Exit('');
  if ((TextEncoding=rteUTF8) and
      (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Bytes[0]),Length(Bytes),nil,0)=0)) or
     ((TextEncoding in [rteUTF16LE,rteUTF16BE]) and Odd(Length(Bytes))) then
    raise EEncodingError.Create('Файл не соответствует выбранной кодировке.');
  Encoding:=TEncoding.GetEncoding(ReaderCodePages[TextEncoding]);
  try Result:=Encoding.GetString(Bytes); finally Encoding.Free; end;
  if Result.StartsWith(#$FEFF) then Delete(Result,1,1);
  if Result.Contains(#0) or Result.StartsWith(#$FFFE) or
     ((TextEncoding in [rteUTF16LE,rteUTF16BE]) and (Result<>'') and
      (WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,PChar(Result),Length(Result),nil,0,nil,nil)=0)) then
    raise EEncodingError.Create('Файл не соответствует выбранной кодировке.');
end;

function EscapeRTF(const Value: string; CompactCyrillic: Boolean): string;
var C: Char; B: TStringBuilder; Code,I,Encoded: Integer;
begin
  B := TStringBuilder.Create;
  try
    for I:=1 to Length(Value) do
    begin
      if ((I and 4095)=0) and (B.Length>128*1024*1024) then
        raise Exception.Create('Книга слишком велика для встроенной читалки.');
      C:=Value[I];
      case C of
        '\','{','}': B.Append('\').Append(C);
        #13: B.Append('\par ');
        #10: ;
        #9: B.Append('\tab ');
      else
        if Ord(C)>127 then
        begin
          Code:=Ord(C);
          Encoded:=0;
          if CompactCyrillic then
            case Code of
              $0410..$044F: Encoded:=Code-$0410+$C0;
              $0401: Encoded:=$A8;
              $0451: Encoded:=$B8;
            end;
          // The RTF header declares Windows-1251. Keep the literal byte in the
          // builder and stream it unchanged, avoiding four bytes per letter.
          if Encoded<>0 then B.Append(Char(Encoded))
          else
          begin
            if Code>32767 then Dec(Code,65536);
            B.Append('\u').Append(Code).Append('?');
          end;
        end
        else B.Append(C);
      end;
    end;
    Result := B.ToString;
  finally B.Free; end;
end;

function ReaderHtmlEntityCode(const Name: string): Word;
type TEntity = record
  Name: string;
  Code: Word;
end;
const
  // HTML 4 names, sorted by ordinal name. XML already handles its built-in entities.
  Entities: array[0..247] of TEntity = (
    (Name: 'AElig'; Code: 198), (Name: 'Aacute'; Code: 193), (Name: 'Acirc'; Code: 194),
    (Name: 'Agrave'; Code: 192), (Name: 'Alpha'; Code: 913), (Name: 'Aring'; Code: 197),
    (Name: 'Atilde'; Code: 195), (Name: 'Auml'; Code: 196), (Name: 'Beta'; Code: 914),
    (Name: 'Ccedil'; Code: 199), (Name: 'Chi'; Code: 935), (Name: 'Dagger'; Code: 8225),
    (Name: 'Delta'; Code: 916), (Name: 'ETH'; Code: 208), (Name: 'Eacute'; Code: 201),
    (Name: 'Ecirc'; Code: 202), (Name: 'Egrave'; Code: 200), (Name: 'Epsilon'; Code: 917),
    (Name: 'Eta'; Code: 919), (Name: 'Euml'; Code: 203), (Name: 'Gamma'; Code: 915),
    (Name: 'Iacute'; Code: 205), (Name: 'Icirc'; Code: 206), (Name: 'Igrave'; Code: 204),
    (Name: 'Iota'; Code: 921), (Name: 'Iuml'; Code: 207), (Name: 'Kappa'; Code: 922),
    (Name: 'Lambda'; Code: 923), (Name: 'Mu'; Code: 924), (Name: 'Ntilde'; Code: 209),
    (Name: 'Nu'; Code: 925), (Name: 'OElig'; Code: 338), (Name: 'Oacute'; Code: 211),
    (Name: 'Ocirc'; Code: 212), (Name: 'Ograve'; Code: 210), (Name: 'Omega'; Code: 937),
    (Name: 'Omicron'; Code: 927), (Name: 'Oslash'; Code: 216), (Name: 'Otilde'; Code: 213),
    (Name: 'Ouml'; Code: 214), (Name: 'Phi'; Code: 934), (Name: 'Pi'; Code: 928),
    (Name: 'Prime'; Code: 8243), (Name: 'Psi'; Code: 936), (Name: 'Rho'; Code: 929),
    (Name: 'Scaron'; Code: 352), (Name: 'Sigma'; Code: 931), (Name: 'THORN'; Code: 222),
    (Name: 'Tau'; Code: 932), (Name: 'Theta'; Code: 920), (Name: 'Uacute'; Code: 218),
    (Name: 'Ucirc'; Code: 219), (Name: 'Ugrave'; Code: 217), (Name: 'Upsilon'; Code: 933),
    (Name: 'Uuml'; Code: 220), (Name: 'Xi'; Code: 926), (Name: 'Yacute'; Code: 221),
    (Name: 'Yuml'; Code: 376), (Name: 'Zeta'; Code: 918), (Name: 'aacute'; Code: 225),
    (Name: 'acirc'; Code: 226), (Name: 'acute'; Code: 180), (Name: 'aelig'; Code: 230),
    (Name: 'agrave'; Code: 224), (Name: 'alefsym'; Code: 8501), (Name: 'alpha'; Code: 945),
    (Name: 'and'; Code: 8743), (Name: 'ang'; Code: 8736), (Name: 'aring'; Code: 229),
    (Name: 'asymp'; Code: 8776), (Name: 'atilde'; Code: 227), (Name: 'auml'; Code: 228),
    (Name: 'bdquo'; Code: 8222), (Name: 'beta'; Code: 946), (Name: 'brvbar'; Code: 166),
    (Name: 'bull'; Code: 8226), (Name: 'cap'; Code: 8745), (Name: 'ccedil'; Code: 231),
    (Name: 'cedil'; Code: 184), (Name: 'cent'; Code: 162), (Name: 'chi'; Code: 967),
    (Name: 'circ'; Code: 710), (Name: 'clubs'; Code: 9827), (Name: 'cong'; Code: 8773),
    (Name: 'copy'; Code: 169), (Name: 'crarr'; Code: 8629), (Name: 'cup'; Code: 8746),
    (Name: 'curren'; Code: 164), (Name: 'dArr'; Code: 8659), (Name: 'dagger'; Code: 8224),
    (Name: 'darr'; Code: 8595), (Name: 'deg'; Code: 176), (Name: 'delta'; Code: 948),
    (Name: 'diams'; Code: 9830), (Name: 'divide'; Code: 247), (Name: 'eacute'; Code: 233),
    (Name: 'ecirc'; Code: 234), (Name: 'egrave'; Code: 232), (Name: 'empty'; Code: 8709),
    (Name: 'emsp'; Code: 8195), (Name: 'ensp'; Code: 8194), (Name: 'epsilon'; Code: 949),
    (Name: 'equiv'; Code: 8801), (Name: 'eta'; Code: 951), (Name: 'eth'; Code: 240),
    (Name: 'euml'; Code: 235), (Name: 'euro'; Code: 8364), (Name: 'exist'; Code: 8707),
    (Name: 'fnof'; Code: 402), (Name: 'forall'; Code: 8704), (Name: 'frac12'; Code: 189),
    (Name: 'frac14'; Code: 188), (Name: 'frac34'; Code: 190), (Name: 'frasl'; Code: 8260),
    (Name: 'gamma'; Code: 947), (Name: 'ge'; Code: 8805), (Name: 'hArr'; Code: 8660),
    (Name: 'harr'; Code: 8596), (Name: 'hearts'; Code: 9829), (Name: 'hellip'; Code: 8230),
    (Name: 'iacute'; Code: 237), (Name: 'icirc'; Code: 238), (Name: 'iexcl'; Code: 161),
    (Name: 'igrave'; Code: 236), (Name: 'image'; Code: 8465), (Name: 'infin'; Code: 8734),
    (Name: 'int'; Code: 8747), (Name: 'iota'; Code: 953), (Name: 'iquest'; Code: 191),
    (Name: 'isin'; Code: 8712), (Name: 'iuml'; Code: 239), (Name: 'kappa'; Code: 954),
    (Name: 'lArr'; Code: 8656), (Name: 'lambda'; Code: 955), (Name: 'lang'; Code: 9001),
    (Name: 'laquo'; Code: 171), (Name: 'larr'; Code: 8592), (Name: 'lceil'; Code: 8968),
    (Name: 'ldquo'; Code: 8220), (Name: 'le'; Code: 8804), (Name: 'lfloor'; Code: 8970),
    (Name: 'lowast'; Code: 8727), (Name: 'loz'; Code: 9674), (Name: 'lrm'; Code: 8206),
    (Name: 'lsaquo'; Code: 8249), (Name: 'lsquo'; Code: 8216), (Name: 'macr'; Code: 175),
    (Name: 'mdash'; Code: 8212), (Name: 'micro'; Code: 181), (Name: 'middot'; Code: 183),
    (Name: 'minus'; Code: 8722), (Name: 'mu'; Code: 956), (Name: 'nabla'; Code: 8711),
    (Name: 'nbsp'; Code: 160), (Name: 'ndash'; Code: 8211), (Name: 'ne'; Code: 8800),
    (Name: 'ni'; Code: 8715), (Name: 'not'; Code: 172), (Name: 'notin'; Code: 8713),
    (Name: 'nsub'; Code: 8836), (Name: 'ntilde'; Code: 241), (Name: 'nu'; Code: 957),
    (Name: 'oacute'; Code: 243), (Name: 'ocirc'; Code: 244), (Name: 'oelig'; Code: 339),
    (Name: 'ograve'; Code: 242), (Name: 'oline'; Code: 8254), (Name: 'omega'; Code: 969),
    (Name: 'omicron'; Code: 959), (Name: 'oplus'; Code: 8853), (Name: 'or'; Code: 8744),
    (Name: 'ordf'; Code: 170), (Name: 'ordm'; Code: 186), (Name: 'oslash'; Code: 248),
    (Name: 'otilde'; Code: 245), (Name: 'otimes'; Code: 8855), (Name: 'ouml'; Code: 246),
    (Name: 'para'; Code: 182), (Name: 'part'; Code: 8706), (Name: 'permil'; Code: 8240),
    (Name: 'perp'; Code: 8869), (Name: 'phi'; Code: 966), (Name: 'pi'; Code: 960),
    (Name: 'piv'; Code: 982), (Name: 'plusmn'; Code: 177), (Name: 'pound'; Code: 163),
    (Name: 'prime'; Code: 8242), (Name: 'prod'; Code: 8719), (Name: 'prop'; Code: 8733),
    (Name: 'psi'; Code: 968), (Name: 'rArr'; Code: 8658), (Name: 'radic'; Code: 8730),
    (Name: 'rang'; Code: 9002), (Name: 'raquo'; Code: 187), (Name: 'rarr'; Code: 8594),
    (Name: 'rceil'; Code: 8969), (Name: 'rdquo'; Code: 8221), (Name: 'real'; Code: 8476),
    (Name: 'reg'; Code: 174), (Name: 'rfloor'; Code: 8971), (Name: 'rho'; Code: 961),
    (Name: 'rlm'; Code: 8207), (Name: 'rsaquo'; Code: 8250), (Name: 'rsquo'; Code: 8217),
    (Name: 'sbquo'; Code: 8218), (Name: 'scaron'; Code: 353), (Name: 'sdot'; Code: 8901),
    (Name: 'sect'; Code: 167), (Name: 'shy'; Code: 173), (Name: 'sigma'; Code: 963),
    (Name: 'sigmaf'; Code: 962), (Name: 'sim'; Code: 8764), (Name: 'spades'; Code: 9824),
    (Name: 'sub'; Code: 8834), (Name: 'sube'; Code: 8838), (Name: 'sum'; Code: 8721),
    (Name: 'sup'; Code: 8835), (Name: 'sup1'; Code: 185), (Name: 'sup2'; Code: 178),
    (Name: 'sup3'; Code: 179), (Name: 'supe'; Code: 8839), (Name: 'szlig'; Code: 223),
    (Name: 'tau'; Code: 964), (Name: 'there4'; Code: 8756), (Name: 'theta'; Code: 952),
    (Name: 'thetasym'; Code: 977), (Name: 'thinsp'; Code: 8201), (Name: 'thorn'; Code: 254),
    (Name: 'tilde'; Code: 732), (Name: 'times'; Code: 215), (Name: 'trade'; Code: 8482),
    (Name: 'uArr'; Code: 8657), (Name: 'uacute'; Code: 250), (Name: 'uarr'; Code: 8593),
    (Name: 'ucirc'; Code: 251), (Name: 'ugrave'; Code: 249), (Name: 'uml'; Code: 168),
    (Name: 'upsih'; Code: 978), (Name: 'upsilon'; Code: 965), (Name: 'uuml'; Code: 252),
    (Name: 'weierp'; Code: 8472), (Name: 'xi'; Code: 958), (Name: 'yacute'; Code: 253),
    (Name: 'yen'; Code: 165), (Name: 'yuml'; Code: 255), (Name: 'zeta'; Code: 950),
    (Name: 'zwj'; Code: 8205), (Name: 'zwnj'; Code: 8204)
  );
var First, Last, Middle, Order: Integer;
begin
  First:=Low(Entities); Last:=High(Entities);
  while First<=Last do
  begin
    Middle:=(First+Last) div 2;
    Order:=CompareStr(Name,Entities[Middle].Name);
    if Order=0 then Exit(Entities[Middle].Code);
    if Order<0 then Last:=Middle-1 else First:=Middle+1;
  end;
  Result:=0;
end;

function NormalizeReaderXML(const Value: string): string;
var M: TMatch; B: TStringBuilder; Start, Finish: Integer; Quote: Char; Code: Word;
begin
  B:=TStringBuilder.Create; Start:=1;
  try
    // Literal text, comments and processing instructions are opaque. HTML
    // entities and external DTD declarations only affect actual XML markup.
    for M in TRegEx.Matches(Value,
      '<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<!DOCTYPE|&(?!amp;|lt;|gt;|quot;|apos;)([A-Za-z][A-Za-z0-9]{0,7});',
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
        Code:=0;
        if M.Groups.Count>1 then Code:=ReaderHtmlEntityCode(M.Groups[1].Value);
        if Code>0 then B.Append('&#').Append(Integer(Code)).Append(';')
        else B.Append(M.Value);
        Start:=M.Index+M.Length;
      end;
    end;
    B.Append(Copy(Value,Start,MaxInt)); Result:=B.ToString;
  finally B.Free; end;
end;

function CloseEpubVoidElements(const Value: string; out OtherTags: Boolean): string;
const Markup = '<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|'+
  '<(/?)([\w:-]+)(?=[\s/>])(?:"[^"]*"|''[^'']*''|[^<>"'']++)*>([ \t\r\n]*</\2[ \t\r\n]*>)?';
var Match: TMatch; Output: TStringBuilder; Start, Finish, TagIndex: Integer;
begin
  Result:=Value; Output:=nil; Start:=1; OtherTags:=False;
  try
    // A literal in CDATA, a comment or a quoted attribute is not a tag.
    Match:=TRegEx.Match(Value,Markup,[roIgnoreCase,roSingleLine]);
    while Match.Success do
    begin
      if (Match.Groups.Count>2) and (Match.Groups[1].Length=0) and (Match.Groups[2].Length>0) and
        ((Match.Groups.Count<4) or (Match.Groups[3].Length=0)) and not Match.Value.EndsWith('/>') then
      begin
        TagIndex:=IndexText(Match.Groups[2].Value,['br','area','base','col','embed','hr','img',
          'input','link','meta','param','source','track','wbr']);
        if TagIndex>=0 then
        begin
          OtherTags:=OtherTags or (TagIndex>0);
          if not Assigned(Output) then Output:=TStringBuilder.Create;
          Finish:=Match.Index+Match.Length-1;
          Output.Append(Copy(Value,Start,Finish-Start));
          Output.Append('/>');
          Start:=Finish+1;
        end;
      end;
      Match:=Match.NextMatch;
    end;
    if Assigned(Output) then
    begin
      Output.Append(Copy(Value,Start,MaxInt));
      Result:=Output.ToString;
    end;
  finally Output.Free; end;
end;

function RepairEpubTextMarkup(const Value: string): string;
const
  Tokens = '<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<mbp:pagebreak\s*/>|'+
    '&(?!amp;|lt;|gt;|quot;|apos;|#[0-9]+;|#x[0-9a-fA-F]+;)|<(?=\s|$)';
var Output:TStringBuilder; Start:Integer; Replacement:string;
begin
  Result:=Value;
  Output:=nil; Start:=1;
  try
    for var Match in TRegEx.Matches(Value,Tokens,[roSingleLine]) do
    begin
      Replacement:=Match.Value;
      if Replacement='&' then Replacement:='&amp;'
      else if Replacement='<' then Replacement:='&lt;'
      else if Replacement.StartsWith('<mbp:pagebreak') then Replacement:='<br/>'
      else Continue;
      if not Assigned(Output) then Output:=TStringBuilder.Create;
      Output.Append(Copy(Value,Start,Match.Index-Start));
      Output.Append(Replacement);
      Start:=Match.Index+Match.Length;
    end;
    if Assigned(Output) then
    begin
      Output.Append(Copy(Value,Start,MaxInt));
      Result:=Output.ToString;
    end;
  finally Output.Free; end;
end;

function RepairEpubBodyNesting(const Value: string): string;
const
  Tokens = '<!\[CDATA\[.*?\]\]>|<!--.*?-->|<\?.*?\?>|<(/?)([\w:-]+)(?=[\s/>])(?:"[^"]*"|''[^'']*''|[^<>"'']++)*>';
var
  Stack: array[0..255] of string;
  Output: TStringBuilder;
  ClosedHeadings: TList<string>;
  Depth, Start, Index, LastDivEnd: Integer;
  Name: string;
  InBody: Boolean;
  function Heading(const Tag: string): Boolean;
  begin Result:=IndexText(Tag,['h1','h2','h3','h4','h5','h6'])>=0; end;
  procedure CopyBefore(At: Integer);
  begin
    if not Assigned(Output) then Output:=TStringBuilder.Create;
    Output.Append(Copy(Value,Start,At-Start));
    Start:=At;
  end;
begin
  Result:=Value; Output:=nil; Depth:=0; Start:=1; InBody:=False; LastDivEnd:=0;
  ClosedHeadings:=TList<string>.Create;
  try
    for var Match in TRegEx.Matches(Value,Tokens,[roSingleLine]) do
    begin
      if Match.Groups.Count<3 then Continue;
      Name:=Match.Groups[2].Value;
      if Name='' then Continue;
      if not InBody then
      begin
        if (Name<>'body') or (Match.Groups[1].Length<>0) or Match.Value.EndsWith('/>') then Continue;
        InBody:=True;
      end;
      if Match.Groups[1].Length=0 then
      begin
        if Match.Value.EndsWith('/>') then Continue;
        if Depth=Length(Stack) then Exit;
        Stack[Depth]:=Name; Inc(Depth);
        Continue;
      end;
      Index:=Depth-1;
      while (Index>=0) and (Stack[Index]<>Name) do Dec(Index);
      if Index>=0 then
      begin
        for var I:=Depth-1 downto Index+1 do
        begin
          // Close a missing paragraph or heading. Keep unknown structural
          // errors for the strict parser instead of moving entire sections.
          if (Stack[I]<>'p') and not Heading(Stack[I]) then Exit;
          CopyBefore(Match.Index);
          Output.Append('</').Append(Stack[I]).Append('>');
        end;
        if (Name='div') and (Index=Depth-1) then LastDivEnd:=Match.Index+Match.Length;
        Depth:=Index;
        if (Depth=0) and (Name='body') then Break;
      end
      else if (Depth>1) and (Name='p') and Heading(Stack[Depth-1]) then
      begin
        CopyBefore(Match.Index);
        Dec(Depth); ClosedHeadings.Add(Stack[Depth]);
        Output.Append('</').Append(Stack[Depth]).Append('>');
        Start:=Match.Index+Match.Length;
      end
      else if ClosedHeadings.Remove(Name)>=0 then
      begin
        // Some producers also emit the original closing heading at the end.
        CopyBefore(Match.Index);
        Start:=Match.Index+Match.Length;
      end
      else if (Name='div') and ((Depth=1) or ((LastDivEnd>0) and
        (Copy(Value,LastDivEnd,Match.Index-LastDivEnd).Trim=''))) then
      begin
        // At body level there is no container this closing tag could end.
        CopyBefore(Match.Index);
        Start:=Match.Index+Match.Length;
        LastDivEnd:=Start;
      end
      else Exit;
    end;
    if Assigned(Output) and InBody and (Depth=0) then
    begin
      Output.Append(Copy(Value,Start,MaxInt));
      Result:=Output.ToString;
    end;
  finally ClosedHeadings.Free; Output.Free; end;
end;

function ReaderXMLParser: IXMLDOMDocument3;
begin
  Result:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async:=False; Result.resolveExternals:=False; Result.validateOnParse:=False;
  Result.preserveWhiteSpace:=True;
  Result.setProperty('ProhibitDTD',True);
end;

function RejoinEpubTrailingMarkup(const Value: string): string;
const
  BoundaryPattern = '</(?:[\w.-]+:)?body\s*>\s*</(?:[\w.-]+:)?html\s*>';
  Tokens = '<!--.*?-->|<!\[CDATA\[.*?\]\]>|<(/?)([a-z][a-z0-9]*)(?=[\s/>])'+
    '((?:"[^"]*"|''[^'']*''|[^<>"''])*)>';
var
  Boundary, Token: TMatch; Prefix: IXMLDOMDocument3; Output: TStringBuilder;
  First, InsertAt, TailStart, Position, Depth: Integer;
  Tail, Gap, Name, Mapped, Attributes: string; Empty: Boolean;
  Stack: array[0..127] of string;
  function ElementName(const Tag: string): string;
  begin if Tag='center' then Result:='p' else Result:=Tag; end;
begin
  Result:='';
  First:=Max(1,Length(Value)-65535);
  Boundary:=TRegEx.Match(Copy(Value,First,MaxInt),BoundaryPattern,[roIgnoreCase]);
  if not Boundary.Success then Exit;
  InsertAt:=First+Boundary.Index-1;
  TailStart:=InsertAt+Boundary.Length;
  Tail:=Copy(Value,TailStart,MaxInt);
  if Tail.Trim='' then Exit;
  // Verify that the marker ends a complete document. Keep any unrelated XML
  // errors and comments with literal closing tags on the strict path.
  Prefix:=ReaderXMLParser;
  if not Prefix.loadXML(Copy(Value,1,TailStart-1)) or
    (Prefix.selectSingleNode('/*[local-name()="html"]/*[local-name()="body"]')=nil) then Exit;
  Output:=TStringBuilder.Create;
  try
    Position:=1; Depth:=0;
    for Token in TRegEx.Matches(Tail,Tokens,[roIgnoreCase,roSingleLine]) do
    begin
      Gap:=Copy(Tail,Position,Token.Index-Position);
      if Gap.Contains('<') then Exit;
      Output.Append(Gap);
      Position:=Token.Index+Token.Length;
      if Token.Groups.Count<4 then begin Output.Append(Token.Value); Continue; end;
      Name:=LowerCase(Token.Groups[2].Value);
      if Name='' then begin Output.Append(Token.Value); Continue; end;
      var BlockTag:=MatchText(Name,['p','center','div','blockquote','pre','ul','ol','li']);
      var VoidTag:=MatchText(Name,['br','hr','img']);
      if not (BlockTag or VoidTag or MatchText(Name,
        ['a','b','big','code','em','i','s','small','span','strong','sub','sup','u'])) then Exit;
      Mapped:=ElementName(Name);
      Attributes:=Token.Groups[3].Value.TrimRight;
      if Token.Groups[1].Value='/' then
      begin
        if (Attributes.Trim<>'') or (Depth=0) or (Stack[Depth-1]<>Name) then Exit;
        Dec(Depth);
        Output.Append('</').Append(Mapped).Append('>');
        Continue;
      end;
      if BlockTag and (Depth>0) and (Stack[Depth-1]='p') then
      begin Dec(Depth); Output.Append('</p>'); end;
      Empty:=Attributes.EndsWith('/');
      if Empty then SetLength(Attributes,Length(Attributes)-1);
      if (Name='center') and not TRegEx.IsMatch(Attributes,'\bstyle\s*=',[roIgnoreCase]) then
        Attributes:=Attributes+' style="text-align:center"';
      Output.Append('<').Append(Mapped).Append(Attributes);
      if Empty or VoidTag then Output.Append('/>')
      else
      begin
        Output.Append('>');
        if Depth=Length(Stack) then Exit;
        Stack[Depth]:=Name; Inc(Depth);
      end;
    end;
    Gap:=Copy(Tail,Position,MaxInt);
    if Gap.Contains('<') then Exit;
    Output.Append(Gap);
    for var I:=Depth-1 downto 0 do Output.Append('</').Append(ElementName(Stack[I])).Append('>');
    Result:=Copy(Value,1,InsertAt-1)+Output.ToString+Boundary.Value;
  finally Output.Free; end;
end;

function BalanceEpubClosingTags(const Value: string; out Truncated: Boolean;
  AllowHeadOnly: Boolean = False): string;
const
  Tokens = '<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|'+
    '<!DOCTYPE(?:"[^"]*"|''[^'']*''|[^<>"''\[])*>|'+
    '<(/?)([A-Za-z_][\w:.-]*)(?=[\s/>])((?:"[^"]*"|''[^'']*''|[^<>"'']++)*)>';
var
  Stack: array[0..127] of string;
  Output: TStringBuilder;
  Depth, Position, Copied, Index: Integer;
  Name, Attributes: string;
  SawBody, HeadOnly: Boolean;
  function Closable(const Tag: string): Boolean;
  begin Result:=IndexStr(Tag,['span','p','div','h1','h2','h3','h4','h5','h6'])>=0; end;
begin
  Result:=''; Truncated:=False; SawBody:=False;
  Depth:=0; Position:=1; Copied:=1; Output:=nil;
  try
    for var Token in TRegEx.Matches(Value,Tokens,[roSingleLine]) do
    begin
      if Copy(Value,Position,Token.Index-Position).Contains('<') then Exit;
      Position:=Token.Index+Token.Length;
      if Token.Groups.Count<4 then Continue;
      Name:=Token.Groups[2].Value;
      if Name='' then Continue;
      Attributes:=Token.Groups[3].Value.TrimRight;
      if Token.Groups[1].Length=0 then
      begin
        if Attributes.EndsWith('/') then Continue;
        if (Name='body') and (Depth=1) and (Stack[0]='html') then SawBody:=True;
        if Depth=Length(Stack) then Exit;
        Stack[Depth]:=Name; Inc(Depth);
        Continue;
      end;
      if Attributes.Trim<>'' then Exit;
      if (Depth>0) and (Name=Stack[Depth-1]) then
      begin Dec(Depth); Continue; end;
      if (Depth<2) or (Stack[0]<>'html') or (Stack[1]<>'body') then Exit;
      if not Assigned(Output) then Output:=TStringBuilder.Create;
      Output.Append(Copy(Value,Copied,Token.Index-Copied));
      Index:=Depth-1;
      while (Index>=0) and (Stack[Index]<>Name) do Dec(Index);
      if Index<0 then
      begin
        if (IndexStr(Name,['span','p','div','blockquote'])<0) or
          ((Stack[Depth-1]<>'body') and not Closable(Stack[Depth-1])) then Exit;
        Copied:=Position;
        Continue;
      end;
      for var I:=Depth-1 downto Index+1 do
      begin
        if not Closable(Stack[I]) and not ((Stack[I]='body') and (Name='html')) then Exit;
        Output.Append('</').Append(Stack[I]).Append('>');
      end;
      Depth:=Index;
      Copied:=Token.Index;
    end;
    HeadOnly:=AllowHeadOnly and not SawBody and (Depth>=1) and (Depth<=3) and
      (Stack[0]='html') and ((Depth<2) or (Stack[1]='head')) and ((Depth<3) or (Stack[2]='title'));
    if not (SawBody or HeadOnly) or Copy(Value,Position,MaxInt).Contains('<') then Exit;
    if Depth>0 then
    begin
      if not HeadOnly then
      begin
        if (Stack[0]<>'html') or ((Depth>1) and (Stack[1]<>'body')) then Exit;
        for var I:=2 to Depth-1 do
          if not Closable(Stack[I]) then Exit;
      end;
      if not Assigned(Output) then Output:=TStringBuilder.Create;
    end;
    if not Assigned(Output) then Exit;
    Output.Append(Copy(Value,Copied,MaxInt));
    for var I:=Depth-1 downto 0 do Output.Append('</').Append(Stack[I]).Append('>');
    Truncated:=Depth>0;
    Result:=Output.ToString;
  finally Output.Free; end;
end;

function XMLDocument(const Bytes: TBytes; TextEncoding: TReaderTextEncoding = rteAutomatic;
  FB2Warnings: TStrings = nil; EpubWarnings: TStrings = nil; const EpubPart: string = '';
  MissingEpubBody: PBoolean = nil): IXMLDOMDocument3;
const
  EpubVersionWarning = 'Объявление XML 1.1 в EPUB прочитано как совместимое с XML 1.0.';
  EpubLineBreakWarning = 'Исправлены теги переноса строки в EPUB для чтения.';
  EpubVoidElementWarning = 'Исправлены незакрытые теги HTML в EPUB для чтения.';
  EpubTextWarning = 'Исправлены специальные символы в главах EPUB для чтения.';
  EpubNestingWarning = 'Исправлена вложенность элементов EPUB для чтения.';
  EpubTrailingWarning = 'Фрагмент после закрывающего тега XHTML возвращён в конец главы EPUB.';
  EpubClosingWarning = 'Исправлены закрывающие теги XHTML в главах EPUB; оформление отдельных фрагментов может отличаться.';
var S, Failure: string; M: TMatch; Enc: TEncoding;
begin
  if Length(Bytes)>MAX_DOCUMENT_BYTES then raise Exception.Create('Документ превышает предел встроенной читалки (64 МБ).');
  S := DecodeSelectedEncoding(Bytes,TextEncoding);
  if TextEncoding=rteAutomatic then
  begin
    M := TRegEx.Match(Copy(S,1,512),'^<\?xml\s+[^?]*?\bencoding\s*=\s*["'']([^"'']+)');
    if M.Success and not SameText(M.Groups[1].Value,'utf-8') and
      not SameText(M.Groups[1].Value,'utf-16') then
    begin
      Enc := TEncoding.GetEncoding(M.Groups[1].Value);
      try S := Enc.GetString(Bytes); finally Enc.Free; end;
    end;
  end;
  if TextEncoding<>rteAutomatic then
  begin
    // The XML parser receives Unicode. Ignore the declaration of the original byte encoding.
    M:=TRegEx.Match(Copy(S,1,512),'^<\?xml\s+[^?]*?\?>');
    if M.Success then Delete(S,1,M.Length);
  end;
  S:=NormalizeReaderXML(S);
  Result:=ReaderXMLParser;
  if Assigned(MissingEpubBody) then MissingEpubBody^:=False;
  if Result.loadXML(S) then Exit;
  if Assigned(EpubWarnings) then
  begin
    if Assigned(MissingEpubBody) and (S.Trim='') then
    begin
      Result.loadXML('<html/>');
      MissingEpubBody^:=True;
      Exit;
    end;
    // MSXML accepts only XML 1.0. Keep the document unchanged apart from
    // its declaration and use this path only if strict parsing succeeds.
    M:=TRegEx.Match(Copy(S,1,512),'\A<\?xml\s+version\s*=\s*(["''])1\.1\1(?=\s|\?>)');
    if M.Success and (Pos(#$0085,S)=0) and (Pos(#$2028,S)=0) then
    begin
      var Compatible:=M.Value.Replace('1.1','1.0')+Copy(S,M.Length+1,MaxInt);
      if Result.loadXML(Compatible) then
      begin
        if EpubWarnings.IndexOf(EpubVersionWarning)<0 then EpubWarnings.Add(EpubVersionWarning);
        Exit;
      end;
    end;
    var OtherTags: Boolean;
    var Repaired:=CloseEpubVoidElements(S,OtherTags);
    if (Repaired<>S) and Result.loadXML(Repaired) then
    begin
      var Warning:=EpubLineBreakWarning;
      if OtherTags then Warning:=EpubVoidElementWarning;
      if EpubWarnings.IndexOf(Warning)<0 then EpubWarnings.Add(Warning);
      Exit;
    end;
    var RepairedText:=RepairEpubTextMarkup(Repaired);
    if (RepairedText<>Repaired) and Result.loadXML(RepairedText) then
    begin
      if EpubWarnings.IndexOf(EpubTextWarning)<0 then EpubWarnings.Add(EpubTextWarning);
      Exit;
    end;
    var RepairedBody:=RepairEpubBodyNesting(RepairedText);
    if (RepairedBody<>RepairedText) and Result.loadXML(RepairedBody) then
    begin
      if EpubWarnings.IndexOf(EpubNestingWarning)<0 then EpubWarnings.Add(EpubNestingWarning);
      Exit;
    end;
    var Rejoined:=RejoinEpubTrailingMarkup(S);
    if (Rejoined<>'') and Result.loadXML(Rejoined) then
    begin
      if EpubWarnings.IndexOf(EpubTrailingWarning)<0 then EpubWarnings.Add(EpubTrailingWarning);
      Exit;
    end;
    var Truncated: Boolean;
    var Balanced:=BalanceEpubClosingTags(RepairedText,Truncated,Assigned(MissingEpubBody));
    if (Balanced<>'') and Result.loadXML(Balanced) then
    begin
      if Result.selectSingleNode('/*[local-name()="html"]/*[local-name()="body"]')<>nil then
      begin
        var Warning:=EpubClosingWarning;
        if Truncated then
        begin
          Warning:=ReaderEpubTruncatedChapterWarning;
          if EpubPart<>'' then Warning:=Warning+' «'+Copy(ExtractFileName(EpubPart),1,100)+'»';
          Warning:=Warning+'. Показано доступное содержимое.';
        end;
        if EpubWarnings.IndexOf(Warning)<0 then EpubWarnings.Add(Warning);
        Exit;
      end;
      if Truncated and Assigned(MissingEpubBody) then
      begin
        MissingEpubBody^:=True;
        Exit;
      end;
    end;
    // Accept a cut-off structural opener only if the rest forms an XHTML body.
    var Fragments:=TRegEx.Matches(S,'<(?:p|div|span|h[1-6])(?:[ \t]+[A-Za-z_:][\w:.-]*)?[ \t]*(?=\r?\n[ \t]*<)');
    if Fragments.Count=1 then
    begin
      var Fragment:=Fragments[0];
      var Restored:=S.Remove(Fragment.Index-1,Fragment.Length);
      if not Result.loadXML(Restored) then Restored:=BalanceEpubClosingTags(Restored,Truncated);
      if Result.loadXML(Restored) and
        (Result.selectSingleNode('/*[local-name()="html"]/*[local-name()="body"]')<>nil) then
      begin
        var Warning:=ReaderEpubDanglingTagWarning;
        if EpubPart<>'' then Warning:=Warning+' «'+Copy(ExtractFileName(EpubPart),1,100)+'»';
        Warning:=Warning+'. Показано доступное содержимое.';
        if EpubWarnings.IndexOf(Warning)<0 then EpubWarnings.Add(Warning);
        Exit;
      end;
    end;
  end;
  if Assigned(FB2Warnings) then
  begin
    Failure:=FB2MarkupFailure(Result.parseError,S);
    var ClosedTail: Boolean;
    if TryRepairFB2Markup(Result,S,ClosedTail) then
    begin
      if ClosedTail then
        FB2Warnings.Add('Закрыты недостающие теги FB2 для чтения. Полноту текста подтвердить нельзя.')
      else
        FB2Warnings.Add('Исправлена разметка FB2 для чтения. Исходный файл сохранён.');
      Exit;
    end;
    if Failure<>'' then raise EReadError.Create(Failure);
  end;
  raise Exception.Create('Не удалось прочитать XML: '+Result.parseError.reason);
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
  if (Node=nil) or (Node.attributes=nil) then Exit;
  for I:=0 to Node.attributes.length-1 do
  begin A:=Node.attributes.item[I]; if LocalName(A)=Name then Exit(A.text); end;
end;

function ReaderZipPath(const Base, Href: string; AllowAbsolute: Boolean = False): string;
var Parts: TStringList; P,S: string; Segment: string;
begin
  // This is a URI path. A literal '+' is part of the filename.
  S:=StringReplace(TNetEncoding.URL.Decode(Href.Replace('+','%2B')),'\','/',[rfReplaceAll]);
  if (Pos(':',S)>0) or S.StartsWith('//') then raise Exception.Create('Внешнее изображение пропущено.');
  if S.StartsWith('/') then
  begin
    if not AllowAbsolute then raise Exception.Create('Внешнее изображение пропущено.');
    P:=''; S:=S.Substring(1);
  end
  else P:=Copy(Base,1,LastDelimiter('/',Base));
  Parts:=TStringList.Create;
  try
    for Segment in (P+S).Split(['/']) do
      if (Segment='') or (Segment='.') then Continue
      else if Segment='..' then
      begin if Parts.Count=0 then raise Exception.Create('Недопустимый путь EPUB.'); Parts.Delete(Parts.Count-1); end
      else Parts.Add(Segment);
    Result:=StringReplace(Trim(Parts.Text),sLineBreak,'/',[rfReplaceAll]);
  finally Parts.Free; end;
end;

function HTMLHeadingLevel(const Name, Role, AriaLevel, Classes: string): Integer;
const WordPrefix = 'MsoHeading';
begin
  if (Length(Name)=2) and (Name[1]='h') and CharInSet(Name[2],['1'..'6']) then
    Exit(Ord(Name[2])-Ord('0'));
  Result:=0;
  if Name<>'p' then Exit;
  if SameText(Role,'heading') and (Length(AriaLevel)=1) and CharInSet(AriaLevel[1],['1'..'9']) then
    Exit(Ord(AriaLevel[1])-Ord('0'));
  for var Value in Classes.Split([' ',#9,#10,#13],TStringSplitOptions.ExcludeEmpty) do
    if (Length(Value)=Length(WordPrefix)+1) and SameText(Copy(Value,1,Length(WordPrefix)),WordPrefix) and
      CharInSet(Value[Length(Value)],['1'..'9']) then Exit(Ord(Value[Length(Value)])-Ord('0'));
end;

function FindNode(const Node: IXMLDOMNode; const Name: string; Depth: Integer = 0): IXMLDOMNode;
var Child: IXMLDOMNode;
begin
  Result := nil;
  if (Node=nil) then Exit;
  if Depth>256 then raise Exception.Create('Слишком глубокая разметка книги.');
  if LocalName(Node)=Name then Exit(Node);
  // A fresh indexed MSXML node list rescans its siblings at every access.
  Child:=Node.firstChild;
  while Assigned(Child) do
  begin
    Result:=FindNode(Child,Name,Depth+1);
    if Result<>nil then Exit;
    Child:=Child.nextSibling;
  end;
end;

function ReaderHasCompleteEpubSpine(const FileName: string; const Canceled: TFunc<Boolean>): Boolean;
var Init: HRESULT;
  function CheckPackage: Boolean;
  var Zip: TZipFile; Document: IXMLDOMDocument3; Package, Manifest, Spine, Item: IXMLDOMNode;
    Paths: TDictionary<string,string>;
    Bytes: TBytes; PackagePath, ID, Path: string; Found: Boolean;
    function Load(const Member: string): Boolean;
    var Index: Integer;
    begin
      Index:=Zip.IndexOf(Member);
      Result:=(Index>=0) and (Zip.FileInfo[Index].UncompressedSize<=MAX_DOCUMENT_BYTES);
      if Result then
      begin
        Zip.Read(Index,Bytes);
        Document:=XMLDocument(Bytes);
      end;
    end;
  begin
    Zip:=TZipFile.Create;
    Paths:=TDictionary<string,string>.Create;
    try
      Zip.Open(FileName,zmRead);
      if not Load('META-INF/container.xml') then Exit(False);
      PackagePath:=Attribute(FindNode(Document.documentElement,'rootfile'),'full-path');
      if (PackagePath='') or not Load(PackagePath) then Exit(False);
      Package:=Document.documentElement;
      Manifest:=FindNode(Package,'manifest');
      Spine:=FindNode(Package,'spine');
      if not Assigned(Manifest) or not Assigned(Spine) then Exit(False);
      for var Index:=0 to Manifest.childNodes.length-1 do
      begin
        if Assigned(Canceled) and Canceled() then Abort;
        Item:=Manifest.childNodes.item[Index];
        if LocalName(Item)<>'item' then Continue;
        ID:=Attribute(Item,'id');
        if (ID='') or not Paths.TryAdd(ID,Attribute(Item,'href')) then Exit(False);
      end;
      Found:=False;
      for var Index:=0 to Spine.childNodes.length-1 do
      begin
        if Assigned(Canceled) and Canceled() then Abort;
        Item:=Spine.childNodes.item[Index];
        if LocalName(Item)<>'itemref' then Continue;
        if not Paths.TryGetValue(Attribute(Item,'idref'),Path) or (Path='') or
          (Zip.IndexOf(ReaderZipPath(PackagePath,Path))<0) then Exit(False);
        Found:=True;
      end;
      Result:=Found;
    finally Paths.Free; Zip.Free; end;
  end;
begin
  Init:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  if Failed(Init) and (Init<>RPC_E_CHANGED_MODE) then Exit(False);
  try
    try Result:=CheckPackage;
    except
      on E: EAbort do raise;
      on E: Exception do Result:=False;
    end;
  finally
    if Succeeded(Init) then CoUninitialize;
  end;
end;

function DirectChild(const Node: IXMLDOMNode; const Name: string): IXMLDOMNode;
begin
  Result:=nil; if Node=nil then Exit;
  Result:=Node.firstChild;
  while Assigned(Result) and (LocalName(Result)<>Name) do Result:=Result.nextSibling;
end;

constructor TReaderDocument.Create;
begin
  inherited;
  FBody:=TStringBuilder.Create; FText:=TStringBuilder.Create;
  FLayoutInsertions:=TList<TLayoutInsertion>.Create;
  FPictures:=TList<TReaderPicture>.Create;
  FChapters:=TList<TReaderChapter>.Create; FStyles:=TList<TReaderStyledRange>.Create;
  FNoteLinks:=TList<TReaderFootnoteLink>.Create; FNoteBodies:=TDictionary<string,string>.Create; Warnings:=TStringList.Create;
  FNoteBodiesInText:=TDictionary<string,Byte>.Create;
  FLinks:=TList<TReaderTextLink>.Create; FAnchors:=TDictionary<string,Integer>.Create;
  FMarginRules:=TList<TReaderMarginRule>.Create;
  FParagraphShades:=TList<TReaderParagraphShade>.Create;
  FCellColors:=TList<TTableColor>.Create;
end;

destructor TReaderDocument.Destroy;
begin
  FImageArchiveLock.Free;
  FCellColors.Free;
  FNoteBodiesInText.Free; FParagraphShades.Free; FMarginRules.Free; FAnchors.Free; FLinks.Free; FNoteBodies.Free; FNoteLinks.Free; FStyles.Free; FPictures.Free; Warnings.Free; FChapters.Free; FLayoutInsertions.Free; FText.Free; FBody.Free; inherited;
end;

procedure TReaderDocument.AddText(const Value: string; PreserveWhitespace: Boolean);
var S: string;
begin
  if PreserveWhitespace then S:=Value
  else S:=TRegEx.Replace(Value,'[\r\n\t ]+',' ');
  // Keep large Cyrillic FB2 and EPUB within the native RTF memory budget.
  FBody.Append(EscapeRTF(S,(FormatName='epub') or (FormatName='fb2'))); FText.Append(S);
end;

procedure TReaderDocument.Paragraph;
begin
  if FCellWidth>0 then FBody.Append('\line ') else FBody.Append('\par ');
  FText.Append(#13);
end;

procedure TReaderDocument.AddPreformattedText(const Value: string);
var Text: string; Start, BreakAt: Integer;
begin
  Text:=Value.Replace(#13#10,#10).Replace(#13,#10);
  Start:=1;
  BreakAt:=PosEx(#10,Text,Start);
  while BreakAt>0 do
  begin
    if BreakAt>Start then AddText(Copy(Text,Start,BreakAt-Start),True);
    Paragraph;
    Start:=BreakAt+1;
    BreakAt:=PosEx(#10,Text,Start);
  end;
  if Start<=Length(Text) then AddText(Copy(Text,Start,MaxInt),True);
end;

procedure TReaderDocument.Chapter(const Value: string; Depth, Position: Integer);
var C: TReaderChapter;
begin
  C.Title:=Trim(TRegEx.Replace(Value,'\s+',' ')); C.Position:=Position; C.Depth:=EnsureRange(Depth,-1,15);
  if C.Position<0 then C.Position:=FText.Length;
  if C.Title<>'' then FChapters.Add(C);
end;

function EbookRelativeImageWidth(const Marker: string): Integer;
const Prefix = 'homelibre-image-width-';
begin
  Result:=0;
  if not Marker.StartsWith(Prefix) or (Length(Marker)>Length(Prefix)+4) then Exit;
  var Value:=Marker.Substring(Length(Prefix));
  if TRegEx.IsMatch(Value,'\A[0-9]{1,4}\z') then TryStrToInt(Value,Result);
end;

function HTMLImageDimension(const Value: string): Integer;
var Pixels: string;
begin
  Result:=0; Pixels:=Trim(Value);
  if (Pixels='') or (Length(Pixels)>5) then Exit;
  for var Digit in Pixels do if not CharInSet(Digit,['0'..'9']) then Exit;
  Result:=StrToInt(Pixels);
  if Result>MAX_HTML_IMAGE_PIXELS then Result:=0;
end;

function WordHorizontalRuleHeight(const Marker: string): Integer;
const Prefix = 'homelibre-word-rule-';
begin
  Result:=0;
  if not Marker.StartsWith(Prefix) then Exit;
  var Value:=Marker.Substring(Length(Prefix));
  if not TRegEx.IsMatch(Value,'\A[1-9][0-9]{0,2}\z') then Exit;
  var Height:=StrToInt(Value);
  if Height<=720 then Result:=Height;
end;

function WordAnchoredRuleGeometry(const Marker: string; var Width, Height, Left: Integer): Boolean;
const Prefix = 'homelibre-word-line-';
begin
  Result:=False;
  if not Marker.StartsWith(Prefix) then Exit;
  var Match:=TRegEx.Match(Marker.Substring(Length(Prefix)), '\A([1-9][0-9]{0,4}):([1-9][0-9]{0,3}):(-?[0-9]{1,4})\z');
  if not Match.Success then Exit;
  var W:=StrToInt(Match.Groups[1].Value);
  var H:=StrToInt(Match.Groups[2].Value);
  var X:=StrToInt(Match.Groups[3].Value);
  if (W>28800) or (H>1440) or (Abs(X)>1440) then Exit;
  Width:=W; Height:=H; Left:=X; Result:=True;
end;

function TReaderDocument.RegisterPicture(const Bytes: TBytes; OfficeImage: Boolean; const ArchiveMember: string;
  DisplayWidth, DisplayHeight: Integer): Integer;
var Stream: TStream; Graphic: TGraphic; Item: TReaderPicture; Scale, GoalWidth, GoalHeight: Double;
  Width, Height: Integer; PNG: Boolean;
begin
  if Length(Bytes)=0 then raise Exception.Create('Данные изображения отсутствуют.');
  if Length(Bytes)>16*1024*1024 then raise Exception.Create('Изображение превышает 16 МБ.');
  Stream:=nil; Graphic:=nil; Item:=Default(TReaderPicture);
  Width:=0; Height:=0;
  PNG:=(Length(Bytes)>=33) and (Bytes[0]=$89) and
    (Bytes[1]=Ord('P')) and (Bytes[2]=Ord('N')) and (Bytes[3]=Ord('G'));
  try
    if OfficeImage then Graphic:=CreatePackageCoverGraphic(Bytes,256*1024*1024)
    else
    begin
      Stream:=TBytesStream.Create(Bytes);
      // In a large EPUB, a PNG only needs its extent until it becomes visible.
      if (ArchiveMember='') or not PNG or not ImageDimensions(Stream,Width,Height) then
        Graphic:=CreateGraphicFromStream(Stream);
    end;
    if Assigned(Graphic) then begin Width:=Graphic.Width; Height:=Graphic.Height; end;
    if (Width<=0) or (Height<=0) then
      raise EReaderUnsupportedPicture.Create('Неподдерживаемое изображение.');
    if Int64(Width)*Height>64000000 then raise Exception.Create('Слишком большое изображение.');
    Item.Monochrome:=PNG and (Bytes[24]=1) and (Bytes[25]=0);
    if Item.Monochrome then
      Scale:=Min(1.0,4096.0/Max(Width,Height))
    else
      Scale:=Min(1.0,1024.0/Max(Width,Height));
    Item.ArchiveMember:=ArchiveMember;
    if ArchiveMember='' then Item.Bytes:=Bytes else Item.Bytes:=nil;
    Item.OfficeImage:=OfficeImage;
    Item.Unreadable:=False;
    Item.Width:=Max(1,Round(Width*Scale));
    Item.Height:=Max(1,Round(Height*Scale));
    if (DisplayWidth>0) or (DisplayHeight>0) then
    begin
      GoalWidth:=DisplayWidth; GoalHeight:=DisplayHeight;
      if DisplayWidth=0 then GoalWidth:=GoalHeight*Width/Height;
      if DisplayHeight=0 then GoalHeight:=GoalWidth*Height/Width;
      Scale:=Min(1.0,MAX_HTML_IMAGE_PIXELS/Max(GoalWidth,GoalHeight));
      Item.GoalWidth:=Max(1,Round(GoalWidth*Scale*15));
      Item.GoalHeight:=Max(1,Round(GoalHeight*Scale*15));
    end;
    Result:=FPictures.Add(Item);
    Inc(FImages);
  finally Graphic.Free; Stream.Free; end;
end;

procedure TReaderDocument.Picture(const Bytes: TBytes; OfficeImage: Boolean; const ArchiveMember, Caption: string;
  LeftAligned: Boolean; DisplayWidth, DisplayHeight, RuleHeight: Integer;
  InlinePicture, SizeInTwips: Boolean; LeftTwips: Integer; WordCanvas: Boolean; WidthPercentX100: Integer);
var Index, CaptionStart: Integer; Item: TReaderPicture;
begin
  if SizeInTwips then Index:=RegisterPicture(Bytes,OfficeImage,ArchiveMember)
  else Index:=RegisterPicture(Bytes,OfficeImage,ArchiveMember,DisplayWidth,DisplayHeight);
  // Keep compressed source bytes, not multi-megabyte Unicode hexadecimal DIB.
  if (FCellWidth<=0) and not InlinePicture then
    if SizeInTwips then FBody.Append('\pard\ql\li').Append(LeftTwips).Append(' ')
    else if LeftAligned then FBody.Append('\pard\ql ')
    else FBody.Append('\pard\qc ');
  var Insertion:=Default(TLayoutInsertion);
  Insertion.Offset:=FBody.Length; Insertion.Value:=Index; Insertion.IsPicture:=True;
  FLayoutInsertions.Add(Insertion);
  FText.Append(#$FFFC);
  Item:=FPictures[Index];
  Item.WordCanvas:=WordCanvas;
  Item.MatchBookBackground:=SizeInTwips;
  Item.WidthPercentX100:=WidthPercentX100;
  if SizeInTwips then
  begin
    Item.GoalWidth:=DisplayWidth;
    Item.GoalHeight:=DisplayHeight;
  end;
  if RuleHeight>0 then
  begin
    Item.FillWidth:=True;
    Item.GoalHeight:=RuleHeight;
  end;
  if Caption<>'' then
  begin
    // The label is visible inside the drawing. Keep its text in the reader's
    // searchable stream without placing a second copy below the picture.
    CaptionStart:=FText.Length;
    FBody.Append('{\v '); AddText(' '+Caption); FBody.Append('}');
    Item.CaptionLength:=FText.Length-CaptionStart;
  end;
  if FCellWidth>0 then
  begin
    Item.CellWidth:=FCellWidth;
    Item.CellInset:=FCellInset;
  end;
  FPictures[Index]:=Item;
  if (FCellWidth>0) or InlinePicture then Exit;
  Paragraph; FBody.Append('\pard\qj\fi360 ');
end;

procedure TReaderDocument.NoteUnreadableImage(const Detail: string);
begin
  Inc(FSkippedImages);
  if FSkippedImages<=20 then
  begin
    if Warnings.Count<20 then Warnings.Add('Изображение: '+Detail);
    LogDiagnosticMessage('reader-image',Detail);
  end;
end;

procedure TReaderDocument.MakeRecentCover(const Bytes: TBytes);
var Source, Output: TBytesStream; Graphic: TGraphic; Bitmap: TBitmap; JPEG: TJPEGImage;
  W,H: Integer; Ratio: Double;
begin
  if (Length(Bytes)=0) or (Length(Bytes)>4*1024*1024) then Exit;
  Source:=TBytesStream.Create(Bytes); Graphic:=nil; Bitmap:=nil; JPEG:=nil; Output:=nil;
  try
    try
      if not ImageDimensions(Source,W,H) or (Int64(W)*H>12000000) then Exit;
      Source.Position:=0;
      Graphic:=CreateGraphicFromStream(Source);
      if not Assigned(Graphic) or (Graphic.Width<=0) or (Graphic.Height<=0) then Exit;
      if Graphic is TJPEGImage then TJPEGImage(Graphic).Scale:=jsEighth;
      Bitmap:=TBitmap.Create; Bitmap.PixelFormat:=pf24bit;
      Ratio:=Min(78/Graphic.Width,108/Graphic.Height);
      Bitmap.SetSize(Max(1,Round(Graphic.Width*Ratio)),Max(1,Round(Graphic.Height*Ratio)));
      Bitmap.Canvas.Brush.Color:=clWhite; Bitmap.Canvas.FillRect(Bitmap.Canvas.ClipRect);
      Bitmap.Canvas.StretchDraw(Bitmap.Canvas.ClipRect,Graphic);
      JPEG:=TJPEGImage.Create; JPEG.CompressionQuality:=75; JPEG.Assign(Bitmap);
      Output:=TBytesStream.Create;
      JPEG.SaveToStream(Output);
      if Output.Size<=12000 then RecentCover:=TNetEncoding.Base64.EncodeBytesToString(
        Copy(Output.Bytes,0,Integer(Output.Size))).Replace(#13,'').Replace(#10,'');
    except
      // An unreadable cover is optional. The reading flow can still use the book.
      on E: Exception do RecentCover:='';
    end;
  finally Output.Free; JPEG.Free; Bitmap.Free; Graphic.Free; Source.Free; end;
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

procedure PlaceRtfRule(var Item: TReaderPicture; const Line: TRect; Color: Cardinal);
var Paper, Rule, Clip, Artwork: TRect;
begin
  Paper:=Rect(Min(0,Line.Left),Min(0,Line.Top),Max(Item.GoalWidth,Line.Right),
    Max(Item.GoalHeight,Line.Bottom));
  if (Paper.Width>Item.GoalWidth*2) or (Paper.Height>Item.GoalHeight*2) then Exit;
  // The drawing is already cropped and scaled. Coordinates in Line
  // belong to the displayed paragraph, not the uncropped metafile.
  Rule:=Rect(MulDiv(Line.Left,Item.Width,Item.GoalWidth),
    MulDiv(Line.Top,Item.Height,Item.GoalHeight),
    MulDiv(Line.Right,Item.Width,Item.GoalWidth),
    MulDiv(Line.Bottom,Item.Height,Item.GoalHeight));
  Rule.Right:=Max(Rule.Left+1,Rule.Right);
  Rule.Bottom:=Max(Rule.Top+1,Rule.Bottom);
  Clip:=Rect(0,0,Item.Width,Item.Height);
  if Item.PaintBounds.IsEmpty then Artwork:=Clip else Artwork:=Item.PaintBounds;
  Artwork.Offset(-Min(0,Rule.Left),-Min(0,Rule.Top));
  Clip.Offset(-Min(0,Rule.Left),-Min(0,Rule.Top));
  Rule.Offset(Clip.Left,Clip.Top);
  if (Color<>0) and (Color<>$FFFFFF) and
    (Int64(Max(Clip.Right,Rule.Right))*Max(Clip.Bottom,Rule.Bottom)>4*1024*1024) then Exit;
  Item.Width:=Max(Clip.Right,Rule.Right);
  Item.Height:=Max(Clip.Bottom,Rule.Bottom);
  Item.GoalWidth:=Paper.Width;
  Item.GoalHeight:=Paper.Height;
  Item.PaintBounds:=Artwork;
  Item.PaintClip:=Clip;
  Item.RuleBounds:=Rule;
  Item.RuleColor:=Color;
  if (Color<>0) and (Color<>$FFFFFF) then Item.Monochrome:=False;
end;

procedure TReaderDocument.Load(const FileName: string; const Canceled: TFunc<Boolean>;
  TextEncoding: TReaderTextEncoding);
type
  TFB2PictureData = record
    Encoded, MediaType: string;
    Preview: TBytes;
  end;
  TEpubStyleSheet = record
    Text, Base: string;
    ListImages: Boolean;
  end;
  TWordVisibility = (wvInherited, wvVisible, wvHidden);
  TWordListIndent = record
    Left, First: string;
  end;
  TWordStyle = record
    OutlineLevel: Integer;
    BasedOn, ListID: string;
    Paragraph: Boolean;
    Visibility: TWordVisibility;
    ListIndent: TWordListIndent;
  end;
  TWordFloatingDrawing = record
    LastBlock: Integer;
    Key, Caption: string;
    Legend: Boolean;
  end;
  TTableMerge = (tmNone, tmStart, tmContinuation);
  TTableSpan = record
    Column, Columns, RowsLeft, Percent: Integer;
  end;
  TWordNoteKind = (wnFootnote, wnEndnote);
  TWordListLevel = record
    Pattern, NumberFormat, ParagraphStyle, Suffix, PictureID: string;
    Start, RestartBefore: Integer;
    Defined, LegalNumbering: Boolean;
    Indent: TWordListIndent;
  end;
  TWordList = record
    Levels: array[0..8] of TWordListLevel;
    Numbers: array[0..8] of Integer;
    Started: set of 0..8;
  end;
const
  WordNoteName: array[TWordNoteKind] of string = ('footnote','endnote');
var Document: IXMLDOMDocument3; Root, Node, Manifest, Spine, Item: IXMLDOMNode;
  Binaries: TDictionary<string,TFB2PictureData>; Paths: TDictionary<string,string>;
  Resources: TDictionary<string,TBytes>; NoteFiles: TDictionary<string,IXMLDOMDocument3>; Zip: TZipFile;
  CSS: TReaderCSS; CSSCache: TDictionary<string,string>; HasFB2Styles: Boolean;
  CellColorIndexes: TDictionary<Cardinal,Integer>;
  RequestedEpubStyles, LoadedEpubStyles: TList<TEpubStyleSheet>;
  ListMarkerBytes: TDictionary<string,TBytes>;
  WordPictureFallbacks: TDictionary<string,TBytes>;
  WordStyleRules: TDictionary<string,TWordStyle>;
  DefaultWordParagraphStyle, DefaultWordCharacterStyle: string;
  WordDefaultHidden, WordHasVisibilityStyles: Boolean;
  WordRenderedDrawings: TDictionary<string,TBytes>;
  WordFloatingDrawings: TDictionary<Integer,TWordFloatingDrawing>;
  WordPictureTemplates: TDictionary<string,Boolean>;
  MathPictures: TDictionary<string,TBytes>;
  MathDeadline: UInt64;
  MathBytesRemaining: Int64;
  MathFormulasRemaining: Integer;
  MathFallback: Boolean;
  JpegRecoveryDeadline: UInt64;
  WordSpacerCount: Integer;
  WordStyles: IXMLDOMNode;
  NumericEpubLinks: TList<Integer>;
  DuplicateEpubAnchors: TDictionary<string,Byte>;
  EpubOutlineNodes: TDictionary<string,IXMLDOMNode>;
  EpubOutlineTargets: TDictionary<string,Integer>;
  EpubAnchorEnds: TDictionary<string,Integer>;
  SavedQuoteSections: TDictionary<string,Byte>;
  NavigationIDs: TDictionary<string,Byte>;
  EpubNavigationDocument, EpubFixedLayout, EpubStylesAvailable, Fb3RelationshipsPresent: Boolean;
  WordThemePath, WordSettingsPath, WordNumberingPath: string;
  WordNotePaths, WordNoteFormats: array[TWordNoteKind] of string;
  WordNoteNumbers: array[TWordNoteKind] of Integer;
  WordNoteLabels: TDictionary<string,string>;
  WordListDefinitions: TDictionary<string,IXMLDOMNode>;
  WordListImagePaths: TDictionary<string,string>;
  WordLists: TDictionary<string,TWordList>;
  ReadingWordNotes, SkipWordCustomMark: Boolean;
  ExistingBinary: TFB2PictureData;
  Data: TBytes; E, PackagePath, CurrentPath, ID, HTML, EpubCoverPath, Fb2CoverRef: string; I: Integer; NoteLink: TReaderFootnoteLink; UnpackedBytes, UnpackedLimit: Int64; NoteCharacters: Integer; PendingInitial: Boolean;
  MIME: TReaderMHTMLRoot;
  DocxFieldDepth, DocxInstructionDepth, WordPageOverlays, TableLevel, CellTextStart: Integer;
  HTMLTableSpans: TArray<TTableSpan>;
  TableWidthPattern, TableLineStylePattern: TRegEx;
  procedure Check;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
    if FBody.Length>128*1024*1024 then raise Exception.Create('Книга слишком велика для встроенной читалки.');
  end;
  procedure ReadDocument(out Bytes: TBytes);
  var Stream: TFileStream;
  begin
    Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size>MAX_DOCUMENT_BYTES then raise Exception.Create('Документ превышает предел встроенной читалки (64 МБ).');
      SetLength(Bytes,Stream.Size);
      if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
    finally Stream.Free; end;
  end;
  procedure ReadNativeRTF;
  var Original: RawByteString;
  begin
    ReadDocument(Data);
    SetLength(Original,Length(Data));
    if Original<>'' then Move(Data[0],Original[1],Length(Data));
    Data:=nil;
    try
      FNativeRTF:=PrepareReaderRTF(Original,
        function(Picture: TRtfPicture): Boolean
        var Bytes: TBytes; Item: TReaderPicture; Index, W, H, CroppedW, CroppedH: Integer;
          Left, Top, Right, Bottom: Integer;
        begin
          Bytes:=Picture.Bytes;
          if Picture.Format=rpfDIB then Bytes:=ReaderDibAsBMP(Bytes);
          try
            Index:=RegisterPicture(Bytes,Picture.Format in [rpfWMF,rpfEMF],'');
          except
            on E: EAbort do raise;
            on E: Exception do Exit(False);
          end;
          Item:=FPictures[Index];
          Item.MatchBookBackground:=Picture.PositionedLine;
          W:=Picture.GoalWidth;
          if W<=0 then W:=Item.Width*15;
          H:=Picture.GoalHeight;
          if H<=0 then H:=Item.Height*15;
          W:=Min(W,240000); H:=Min(H,240000);
          Left:=EnsureRange(Picture.CropLeft,-W,W);
          Top:=EnsureRange(Picture.CropTop,-H,H);
          Right:=EnsureRange(Picture.CropRight,-W,W);
          Bottom:=EnsureRange(Picture.CropBottom,-H,H);
          CroppedW:=W-Left-Right; CroppedH:=H-Top-Bottom;
          if (CroppedW>0) and (CroppedH>0) then
          begin
            Item.GoalWidth:=Max(1,MulDiv(CroppedW,EnsureRange(Picture.ScaleX,1,1000),100));
            Item.GoalHeight:=Max(1,MulDiv(CroppedH,EnsureRange(Picture.ScaleY,1,1000),100));
            if ((Left<>0) or (Top<>0) or (Right<>0) or (Bottom<>0)) and
              (CroppedW*64>=W) and (CroppedH*64>=H) then
              Item.PaintBounds:=Rect(MulDiv(-Left,Item.Width,CroppedW),MulDiv(-Top,Item.Height,CroppedH),
                MulDiv(W-Left,Item.Width,CroppedW),MulDiv(H-Top,Item.Height,CroppedH));
            if not Picture.RuleBounds.IsEmpty then PlaceRtfRule(Item,Picture.RuleBounds,Picture.RuleColor);
          end;
          FPictures[Index]:=Item;
          Result:=True;
        end,
        procedure(Detail: string) begin NoteUnreadableImage(Detail); end,Canceled,FNativePictureOffsets,FHasTables);
    except
      on E: EReadError do
      begin
        // RichEdit can still salvage text from some malformed RTF documents.
        FPictures.Clear; FImages:=0; FNativePictureOffsets:=nil;
        FNativeRTF:=Original;
        FNativeRTFFallback:=True;
        FHasTables:=False;
        NoteUnreadableImage(E.Message);
      end;
    end;
  end;
  function ZipPath(const Base, Href: string): string;
  begin
    Result:=ReaderZipPath(Base,Href,E='.docx');
  end;
  function LocalLinkTarget(const Href: string): string;
  var At: Integer; Part, Fragment: string;
  begin
    Result:='';
    if Href='' then Exit;
    if IsReaderHTML(E) then
    begin
      if Href.StartsWith('#') then Result:=Href.Substring(1);
      Exit;
    end;
    if MatchStr(E,['.fb2','.fb3']) then
    begin
      if Href.StartsWith('#') then
        Result:=TNetEncoding.URL.Decode(Href.Substring(1).Replace('+','%2B'));
      Exit;
    end;
    if E<>'.epub' then Exit;
    if Href.Contains(':') or Href.StartsWith('//') then Exit;
    At:=Pos('#',Href); Part:=Href; Fragment:='';
    if At>0 then
    begin Part:=Copy(Href,1,At-1); Fragment:=TNetEncoding.URL.Decode(Copy(Href,At+1,MaxInt).Replace('+','%2B')); end;
    At:=Pos('?',Part); if At>0 then Part:=Copy(Part,1,At-1);
    if Part='' then Part:=CurrentPath else Part:=ZipPath(CurrentPath,Part);
    Result:=Part+'#'+Fragment;
  end;
  function EpubSpaceAnchor(const Target: string): string;
  var At: Integer; Alternative: string;
  begin
    Result:=Target;
    At:=Pos('#',Target);
    if (At=0) or (Pos(#$00A0,Target,At+1)=0) or FAnchors.ContainsKey(Target) then Exit;
    Alternative:=Copy(Target,1,At)+Target.Substring(At).Replace(#$00A0,' ');
    if FAnchors.ContainsKey(Alternative) and
      (not Assigned(DuplicateEpubAnchors) or not DuplicateEpubAnchors.ContainsKey(Alternative)) then
      Result:=Alternative;
  end;
  function NumericEpubAnchor(const Value: string): Boolean;
  begin
    if (Length(Value)=0) or (Length(Value)>9) then Exit(False);
    for var C in Value do
      if not CharInSet(C,['0'..'9']) then Exit(False);
    Result:=True;
  end;
  procedure RegisterEpubAnchor(const Key: string; const Source: IXMLDOMNode = nil);
  var First: IXMLDOMNode;
    procedure IndexDuplicateLabel(Node: IXMLDOMNode; Position: Integer);
    var LabelText, LabelKey: string; Existing: Integer;
    begin
      if Node=nil then Exit;
      while (Node<>nil) and MatchStr(LocalName(Node),['a','span','b','strong','i','em','small','sup','sub']) do
        Node:=Node.parentNode;
      if (Node=nil) or not MatchStr(LocalName(Node),['p','h1','h2','h3','h4','h5','h6']) then Exit;
      LabelText:=Node.text;
      if (LabelText='') or (Length(LabelText)>4096) then Exit;
      LabelText:=Trim(TRegEx.Replace(LabelText,'\s+',' '));
      if LabelText='' then Exit;
      LabelKey:=Key+#0+LabelText;
      if not Assigned(EpubOutlineTargets) then EpubOutlineTargets:=TDictionary<string,Integer>.Create;
      if EpubOutlineTargets.TryGetValue(LabelKey,Existing) and (Existing<>Position) then
        EpubOutlineTargets[LabelKey]:=-1
      else EpubOutlineTargets.TryAdd(LabelKey,Position);
    end;
  begin
    if FAnchors.TryAdd(Key,FText.Length) then
    begin
      if (Source<>nil) and Assigned(EpubOutlineNodes) then EpubOutlineNodes.Add(Key,Source);
      Exit;
    end;
    if not Assigned(DuplicateEpubAnchors) then
      DuplicateEpubAnchors:=TDictionary<string,Byte>.Create;
    DuplicateEpubAnchors.TryAdd(Key,0);
    if not Assigned(EpubOutlineNodes) or not EpubOutlineNodes.TryGetValue(Key,First) then Exit;
    // Read heading labels only when IDs repeat within this spine document.
    if First<>nil then
    begin
      IndexDuplicateLabel(First,FAnchors[Key]);
      EpubOutlineNodes[Key]:=nil;
    end;
    IndexDuplicateLabel(Source,FText.Length);
  end;
  procedure RecoverEpubFragmentLinks(const CoverID: string);
  const FragmentMedia = 'image/xhtml#';
  var Groups: TObjectDictionary<string,TList<IXMLDOMNode>>;
    Pages, Referenced: TDictionary<string,Byte>;
    Entries: TList<IXMLDOMNode>;
    Pending: TDictionary<string,Integer>;
    Entry: IXMLDOMNode;
    Identity, Href, Mime, Path, Page, Fragment, Target, Key: string;
    Index, At, Position, Added: Integer;
    Verified: Boolean;
    function MemberPath(const Reference: string): string;
    begin
      Result:='';
      if (Reference='') or Reference.Contains('?') or Reference.Contains('\') then Exit;
      try
        Result:=ZipPath(PackagePath,Reference);
      except
        on E: Exception do Result:='';
      end;
    end;
  begin
    if not Assigned(Manifest.selectSingleNode('*[starts-with(@media-type,"image/xhtml#")]')) then Exit;
    Groups:=TObjectDictionary<string,TList<IXMLDOMNode>>.Create([doOwnsValues]);
    Pages:=TDictionary<string,Byte>.Create;
    Referenced:=TDictionary<string,Byte>.Create;
    Pending:=TDictionary<string,Integer>.Create;
    try
      Referenced.TryAdd(CoverID,0);
      Referenced.TryAdd(Attribute(Spine,'toc'),0);
      for Index:=0 to Spine.childNodes.length-1 do
        Referenced.TryAdd(Attribute(Spine.childNodes.item[Index],'idref'),0);
      var Metadata:=FindNode(Root,'metadata');
      if Assigned(Metadata) then
        for Index:=0 to Metadata.childNodes.length-1 do
        begin
          Key:=Attribute(Metadata.childNodes.item[Index],'refines');
          if Key.StartsWith('#') then Referenced.TryAdd(Key.Substring(1),0);
        end;
      for Index:=0 to Manifest.childNodes.length-1 do
      begin
        Check;
        Entry:=Manifest.childNodes.item[Index];
        if LocalName(Entry)<>'item' then Continue;
        Identity:=Attribute(Entry,'id');
        if Identity='' then Continue;
        if not Groups.TryGetValue(Identity,Entries) then
        begin
          Entries:=TList<IXMLDOMNode>.Create;
          Groups.Add(Identity,Entries);
        end;
        Entries.Add(Entry);
        Referenced.TryAdd(Attribute(Entry,'fallback'),0);
        Referenced.TryAdd(Attribute(Entry,'fallback-style'),0);
        Referenced.TryAdd(Attribute(Entry,'media-overlay'),0);
      end;
      for Entries in Groups.Values do
      begin
        if Entries.Count<>1 then Continue;
        Mime:=Attribute(Entries[0],'media-type');
        if (Mime<>'application/xhtml+xml') and (Mime<>'application/x-ibooks-html') then Continue;
        Href:=Attribute(Entries[0],'href');
        if Href.Contains('#') then Continue;
        Path:=MemberPath(Href);
        if (Path<>'') and FAnchors.ContainsKey(Path+'#') then Pages.TryAdd(Path,0);
      end;
      Added:=0;
      for var Group in Groups do
      begin
        if (Group.Value.Count<2) or Referenced.ContainsKey(Group.Key) then Continue;
        Pending.Clear;
        Verified:=True;
        for Entry in Group.Value do
        begin
          Check;
          Href:=Attribute(Entry,'href');
          Mime:=Attribute(Entry,'media-type');
          At:=Pos('#',Href);
          if (At<2) or not Mime.StartsWith(FragmentMedia) or Href.Contains('?') or
            (Entry.attributes.length<>3) then begin Verified:=False; Break; end;
          Fragment:=TNetEncoding.URL.Decode(Href.Substring(At).Replace('+','%2B'));
          Path:=MemberPath(Copy(Href,1,At-1));
          if (Path='') or (Fragment='') or (Mime<>FragmentMedia+Fragment) or
            (Zip.IndexOf(Path)>=0) or (Zip.IndexOf(Path+'#'+Fragment)<0) then
          begin Verified:=False; Break; end;
          At:=LastDelimiter('/',Path);
          Page:=Copy(Path,1,LastDelimiter('/',Copy(Path,1,At-1)))+Path.Substring(At);
          Target:=Page+'#'+Fragment;
          if not Pages.ContainsKey(Page) or not FAnchors.TryGetValue(Target,Position) or
            (Assigned(DuplicateEpubAnchors) and DuplicateEpubAnchors.ContainsKey(Target)) then
          begin Verified:=False; Break; end;
          Pending.TryAdd(Path+'#'+Fragment,Position);
        end;
        if Verified then
          for var Alias in Pending do
            if FAnchors.TryAdd(Alias.Key,Alias.Value) then Inc(Added);
      end;
      if (Added>0) and (Warnings.Count<20) then
        Warnings.Add('Восстановлены переходы EPUB к иллюстрациям и разделам книги.');
    finally
      Pending.Free; Referenced.Free; Pages.Free; Groups.Free;
    end;
  end;
  procedure ResolveNumericEpubLinks;
  var Targets: TDictionary<string,string>; Verified: TDictionary<string,Integer>;
    Link: TReaderTextLink; Key, Part, Fragment, Folder, Replacement: string; At, Count: Integer;
  begin
    if not Assigned(NumericEpubLinks) then Exit;
    Targets:=TDictionary<string,string>.Create;
    Verified:=TDictionary<string,Integer>.Create;
    try
      for var Index in NumericEpubLinks do
      begin
        Check; Key:=FLinks[Index].Target;
        if not Targets.ContainsKey(Key) then
        begin
          if Zip.IndexOf(Key.Substring(0,Length(Key)-1))<0 then Targets.Add(Key,'')
          else Targets.Add(Key,'#');
        end;
      end;
      for var Anchor in FAnchors.Keys do
      begin
        Check; At:=Pos('#',Anchor);
        if At=0 then Continue;
        Fragment:=Anchor.Substring(At);
        if not NumericEpubAnchor(Fragment) then Continue;
        Part:=Anchor.Substring(0,At-1);
        Key:=Copy(Part,1,LastDelimiter('/',Part))+Fragment+'#';
        if Targets.TryGetValue(Key,Replacement) then
          if (Replacement='') and (not Assigned(DuplicateEpubAnchors) or
            not DuplicateEpubAnchors.ContainsKey(Anchor)) then Targets[Key]:=Anchor
          else Targets[Key]:='#';
      end;
      for var Pair in Targets do
        if (Pair.Value<>'') and (Pair.Value<>'#') then
        begin
          Folder:=Copy(Pair.Key,1,LastDelimiter('/',Pair.Key));
          if not Verified.TryGetValue(Folder,Count) then Count:=0;
          Verified.AddOrSetValue(Folder,Count+1);
        end;
      for var Index in NumericEpubLinks do
      begin
        Check;
        Link:=FLinks[Index];
        Folder:=Copy(Link.Target,1,LastDelimiter('/',Link.Target));
        // Multiple exact matches identify the broken link pattern. A file
        // that actually exists or an anchor found twice remains untouched.
        if Verified.TryGetValue(Folder,Count) and (Count>=2) and
          Targets.TryGetValue(Link.Target,Replacement) and (Replacement<>'') and (Replacement<>'#') then
        begin
          Link.Target:=Replacement;
          FLinks[Index]:=Link;
        end;
      end;
    finally Verified.Free; Targets.Free; end;
  end;
  procedure ResolveHTMLLinks(const Bytes: TBytes; AddStyles: Boolean; DeclaredCodePage: Integer = 0);
  var CodePage, Kept: Integer; Legacy: TEncoding; Link: TReaderTextLink;
    Target: string; Range: TReaderStyledRange;
    function DecodeFragment(const Fragment: string; const Options: TURLEncoding.TDecodeOptions;
      Encoding: TEncoding = nil): string;
    begin
      try Result:=TNetEncoding.URL.Decode(Fragment,Options,Encoding);
      except on EEncodingError do Result:=''; end;
    end;
  begin
    if FLinks.Count=0 then Exit;
    if DeclaredCodePage>0 then CodePage:=DeclaredCodePage
    else if TextEncoding=rteAutomatic then CodePage:=ReaderHTMLCodePage(Bytes)
    else CodePage:=ReaderCodePages[TextEncoding];
    Legacy:=nil;
    if (CodePage<>CP_UTF8) and (CodePage<>1200) and (CodePage<>1201) then
      Legacy:=TEncoding.GetEncoding(CodePage);
    try
      Kept:=0;
      for var Index:=0 to FLinks.Count-1 do
      begin
        Check;
        Link:=FLinks[Index];
        Target:=Link.Target;
        if Link.Target.Contains('%') then Target:=DecodeFragment(Link.Target,[]);
        if not FAnchors.ContainsKey(Target) and Assigned(Legacy) and Link.Target.Contains('%') and
          not TRegEx.IsMatch(Link.Target,'[^\x00-\x7f]') then
        begin
          Target:=DecodeFragment(Link.Target,[],Legacy);
          if not FAnchors.ContainsKey(Target) and Link.Target.Contains('+') then
            Target:=DecodeFragment(Link.Target,[TURLEncoding.TDecodeOption.PlusAsSpaces],Legacy);
        end;
        if not FAnchors.ContainsKey(Target) then Continue;
        Link.Target:=Target;
        FLinks[Kept]:=Link;
        Inc(Kept);
        if AddStyles then
        begin
          Range:=Default(TReaderStyledRange);
          Range.Start:=Link.Start; Range.Count:=Link.Count; Range.Kind:=rbLink;
          FStyles.Add(Range);
        end;
      end;
      if Kept<FLinks.Count then FLinks.DeleteRange(Kept,FLinks.Count-Kept);
    finally Legacy.Free; end;
  end;
  procedure ReadZip(const Path: string; out Bytes: TBytes);
  var Index: Integer;
  begin
    Check; Index:=Zip.IndexOf(Path);
    if Index<0 then raise EReadError.CreateFmt('В %s не найден элемент «%s».',[UpperCase(E.Substring(1)),Path]);
    if Zip.FileInfo[Index].UncompressedSize>MAX_DOCUMENT_BYTES then
      raise EReadError.CreateFmt('В %s элемент «%s» превышает предел чтения (%d МиБ).',
        [UpperCase(E.Substring(1)),Path,MAX_DOCUMENT_BYTES div (1024*1024)]);
    Inc(UnpackedBytes,Zip.FileInfo[Index].UncompressedSize);
    if UnpackedBytes>UnpackedLimit then
      raise EReadError.CreateFmt('%s слишком велик для встроенной читалки.',[UpperCase(E.Substring(1))]);
    Zip.Read(Index,Bytes);
  end;
  function WordChild(const Parent: IXMLDOMNode; const Name: string): IXMLDOMNode;
  begin
    Result:=nil;
    if Parent=nil then Exit;
    Result:=Parent.firstChild;
    while (Result<>nil) and (LocalName(Result)<>Name) do Result:=Result.nextSibling;
  end;
  function WordValue(const Parent: IXMLDOMNode; const Name: string): string;
  begin
    var Child:=WordChild(Parent,Name);
    if Child=nil then Exit('');
    Result:=Attribute(Child,'val');
  end;
  procedure ReadWordRelationships(const PartName: string; MainPart: Boolean; Targets: TDictionary<string,string> = nil);
  var RelationshipPart, RelationshipType, Member: string; PartData: TBytes;
    RelationshipDoc: IXMLDOMDocument3; Relationship: IXMLDOMNode;
  begin
    if Targets=nil then Targets:=Paths;
    Targets.Clear;
    var Slash:=LastDelimiter('/',PartName);
    RelationshipPart:=Copy(PartName,1,Slash)+'_rels/'+PartName.Substring(Slash)+'.rels';
    if Zip.IndexOf(RelationshipPart)<0 then Exit;
    ReadZip(RelationshipPart,PartData);
    RelationshipDoc:=XMLDocument(PartData);
    Relationship:=RelationshipDoc.documentElement.firstChild;
    while Assigned(Relationship) do
    begin
      Check;
      if LocalName(Relationship)='relationship' then
      begin
        RelationshipType:=Attribute(Relationship,'type');
        Member:='';
        if not SameText(Attribute(Relationship,'targetmode'),'external') then
        begin
          Member:=ZipPath(PartName,Attribute(Relationship,'target'));
          Targets.AddOrSetValue(Attribute(Relationship,'id'),Member);
        end;
        if MainPart then
        begin
          if RelationshipType.EndsWith('/theme',True) then WordThemePath:=Member;
          if RelationshipType.EndsWith('/numbering',True) then WordNumberingPath:=Member;
          if RelationshipType.EndsWith('/settings',True) then WordSettingsPath:=Member;
          for var Kind:=Low(TWordNoteKind) to High(TWordNoteKind) do
            if RelationshipType.EndsWith('/'+WordNoteName[Kind]+'s',True) then WordNotePaths[Kind]:=Member;
        end;
      end;
      Relationship:=Relationship.nextSibling;
    end;
  end;
  procedure LoadWordNoteNumbering;
  var SettingsDocument: IXMLDOMDocument3; SettingsData: TBytes; Properties: IXMLDOMNode;
  begin
    for var Kind:=Low(TWordNoteKind) to High(TWordNoteKind) do WordNoteNumbers[Kind]:=1;
    if (WordSettingsPath='') or (Zip.IndexOf(WordSettingsPath)<0) then Exit;
    try
      ReadZip(WordSettingsPath,SettingsData);
      SettingsDocument:=XMLDocument(SettingsData);
      for var Kind:=Low(TWordNoteKind) to High(TWordNoteKind) do
      begin
        Properties:=WordChild(SettingsDocument.documentElement,WordNoteName[Kind]+'pr');
        WordNoteFormats[Kind]:=LowerCase(WordValue(Properties,'numfmt'));
        WordNoteNumbers[Kind]:=EnsureRange(StrToIntDef(WordValue(Properties,'numstart'),1),0,1000000);
      end;
    except
      on Error: EAbort do raise;
      on Error: Exception do if Warnings.Count<20 then Warnings.Add('Нумерация сносок DOCX: '+Error.Message);
    end;
  end;
  function WordOrdinal(Number: Integer; const NumberFormat: string): string;
  const RomanValues: array[0..12] of Integer = (1000,900,500,400,100,90,50,40,10,9,5,4,1);
    RomanDigits: array[0..12] of string = ('M','CM','D','CD','C','XC','L','XL','X','IX','V','IV','I');
  begin
    Result:=IntToStr(Number);
    if MatchText(NumberFormat,['upperroman','lowerroman']) and InRange(Number,1,3999) then
    begin
      Result:='';
      for var Digit:=Low(RomanValues) to High(RomanValues) do
        while Number>=RomanValues[Digit] do
        begin Result:=Result+RomanDigits[Digit]; Dec(Number,RomanValues[Digit]); end;
      if NumberFormat='lowerroman' then Result:=LowerCase(Result);
    end
    else if MatchText(NumberFormat,['upperletter','lowerletter']) and InRange(Number,1,702) then
    begin
      Result:=StringOfChar(Char(Ord('A')+(Number-1) mod 26),(Number-1) div 26+1);
      if NumberFormat='lowerletter' then Result:=LowerCase(Result);
    end
    else if (NumberFormat='decimalzero') and (Number<10) then Result:='0'+Result;
  end;
  function WordNoteNumber(Kind: TWordNoteKind): string;
  begin
    Result:=WordOrdinal(WordNoteNumbers[Kind],WordNoteFormats[Kind]);
    Inc(WordNoteNumbers[Kind]);
  end;
  function WordOutline(const Properties: IXMLDOMNode): Integer;
  begin
    Result:=StrToIntDef(WordValue(Properties,'outlinelvl'),-1);
    if (Result<0) or (Result>9) then Result:=-1;
  end;
  function WordRunVisibility(const Properties: IXMLDOMNode): TWordVisibility;
  begin
    var Vanish:=WordChild(Properties,'vanish');
    if Vanish=nil then Exit(wvInherited);
    var Value:=Attribute(Vanish,'val');
    if MatchText(Value,['0','off','false']) then Exit(wvVisible);
    if MatchText(Value,['','1','on','true']) then Exit(wvHidden);
    Result:=wvInherited;
  end;
  function WordListIndent(const Properties: IXMLDOMNode): TWordListIndent;
  begin
    var Indent:=WordChild(Properties,'ind');
    Result.Left:=Attribute(Indent,'start');
    if Result.Left='' then Result.Left:=Attribute(Indent,'left');
    Result.First:=Attribute(Indent,'firstline');
    var Hanging: Integer;
    if TryStrToInt(Attribute(Indent,'hanging'),Hanging) then Result.First:=IntToStr(-Int64(Hanging));
  end;
  procedure ApplyWordListIndent(const Indent: TWordListIndent);
  begin
    if FCellWidth>0 then Exit;
    if Indent.Left<>'' then FBody.Append('\li').Append(EnsureRange(StrToIntDef(Indent.Left,0),-2400,4800)).Append(' ');
    if Indent.First<>'' then FBody.Append('\fi').Append(EnsureRange(StrToIntDef(Indent.First,0),-2400,2400)).Append(' ');
  end;
  procedure LoadWordStyles;
  var Bytes: TBytes; Doc: IXMLDOMDocument3; Style: IXMLDOMNode; Rule: TWordStyle;
    Kind, Identity: string;
  begin
    if Zip.IndexOf('word/styles.xml')<0 then Exit;
    try
      ReadZip('word/styles.xml',Bytes);
      Doc:=XMLDocument(Bytes);
    except
      on Error: EAbort do raise;
      on Error: Exception do
      begin
        Warnings.Add('Не удалось прочитать стили DOCX. Заголовки могут отображаться не полностью.');
        Exit;
      end;
    end;
    WordStyles:=Doc.documentElement;
    WordDefaultHidden:=WordRunVisibility(WordChild(WordChild(WordChild(WordStyles,'docdefaults'),
      'rprdefault'),'rpr'))=wvHidden;
    Style:=WordStyles.firstChild;
    while Style<>nil do
    begin
      Check;
      Kind:=Attribute(Style,'type');
      if (LocalName(Style)='style') and MatchText(Kind,['paragraph','character']) then
      begin
        Identity:=Attribute(Style,'styleid');
        Rule.Paragraph:=SameText(Kind,'paragraph');
        Rule.OutlineLevel:=WordOutline(WordChild(Style,'ppr'));
        Rule.ListID:=WordValue(WordChild(WordChild(Style,'ppr'),'numpr'),'numid');
        Rule.ListIndent:=WordListIndent(WordChild(Style,'ppr'));
        Rule.BasedOn:=WordValue(Style,'basedon');
        Rule.Visibility:=WordRunVisibility(WordChild(Style,'rpr'));
        WordHasVisibilityStyles:=WordHasVisibilityStyles or (Rule.Visibility<>wvInherited);
        WordStyleRules.AddOrSetValue(Identity,Rule);
        if MatchText(Attribute(Style,'default'),['1','on','true']) then
          if Rule.Paragraph then DefaultWordParagraphStyle:=Identity
          else DefaultWordCharacterStyle:=Identity;
      end;
      Style:=Style.nextSibling;
    end;
  end;
  procedure LoadWordListDefinitions;
  var Numbering: IXMLDOMDocument3; Bytes: TBytes; Node: IXMLDOMNode;
  begin
    WordListDefinitions:=TDictionary<string,IXMLDOMNode>.Create;
    WordLists:=TDictionary<string,TWordList>.Create;
    if (WordNumberingPath='') or (Zip.IndexOf(WordNumberingPath)<0) then Exit;
    try
      ReadZip(WordNumberingPath,Bytes);
      Numbering:=XMLDocument(Bytes);
      Node:=Numbering.documentElement.firstChild;
      while Assigned(Node) do
      begin
        Check;
        if LocalName(Node)='abstractnum' then
          WordListDefinitions.TryAdd('a'+Attribute(Node,'abstractnumid'),Node)
        else if LocalName(Node)='num' then
          WordListDefinitions.TryAdd('n'+Attribute(Node,'numid'),Node)
        else if LocalName(Node)='numpicbullet' then
          WordListDefinitions.TryAdd('p'+Attribute(Node,'numpicbulletid'),Node);
        Node:=Node.nextSibling;
      end;
    except
      on Error: EAbort do raise;
      on Error: Exception do if Warnings.Count<20 then Warnings.Add('Списки DOCX: '+Error.Message);
    end;
  end;
  function ReadWordList(const ID: string): TWordList;
  var Number, Definition, Child: IXMLDOMNode; Level, OverrideStart, Restart: Integer;
    procedure ReadLevel(const Node: IXMLDOMNode; Index: Integer);
    begin
      var Entry:=Default(TWordListLevel);
      Entry.Defined:=True;
      Entry.Pattern:=Copy(WordValue(Node,'lvltext'),1,4096);
      Entry.NumberFormat:=LowerCase(WordValue(Node,'numfmt'));
      Entry.Suffix:=LowerCase(WordValue(Node,'suff'));
      Entry.ParagraphStyle:=WordValue(Node,'pstyle');
      Entry.Indent:=WordListIndent(WordChild(Node,'ppr'));
      Entry.PictureID:=WordValue(Node,'lvlpicbulletid');
      Entry.Start:=EnsureRange(StrToIntDef(WordValue(Node,'start'),1),0,1000000);
      Entry.RestartBefore:=Index;
      Entry.LegalNumbering:=Assigned(WordChild(Node,'islgl')) and
        not MatchText(WordValue(Node,'islgl'),['0','false','off']);
      Result.Levels[Index]:=Entry;
    end;
  begin
    Result:=Default(TWordList);
    if not WordListDefinitions.TryGetValue('n'+ID,Number) then Exit;
    if WordListDefinitions.TryGetValue('a'+WordValue(Number,'abstractnumid'),Definition) then
    begin
      Child:=Definition.firstChild;
      while Assigned(Child) do
      begin
        Check;
        if (LocalName(Child)='lvl') and TryStrToInt(Attribute(Child,'ilvl'),Level) and InRange(Level,0,8) then
        begin
          ReadLevel(Child,Level);
          Restart:=StrToIntDef(WordValue(Child,'lvlrestart'),Level);
          if InRange(Restart,0,Level) then Result.Levels[Level].RestartBefore:=Restart;
        end;
        Child:=Child.nextSibling;
      end;
    end;
    Child:=Number.firstChild;
    while Assigned(Child) do
    begin
      Check;
      if (LocalName(Child)='lvloverride') and TryStrToInt(Attribute(Child,'ilvl'),Level) and InRange(Level,0,8) then
      begin
        Definition:=WordChild(Child,'lvl');
        if Assigned(Definition) then
        begin
          Restart:=Result.Levels[Level].RestartBefore;
          if not Result.Levels[Level].Defined then Restart:=Level;
          ReadLevel(Definition,Level);
          Result.Levels[Level].RestartBefore:=Restart;
        end;
        if TryStrToInt(WordValue(Child,'startoverride'),OverrideStart) then
          Result.Levels[Level].Start:=EnsureRange(OverrideStart,0,1000000);
      end;
      Child:=Child.nextSibling;
    end;
  end;
  function AddWordListPicture(const ID: string): Boolean;
  var Definition, Reference: IXMLDOMNode; Images: IXMLDOMNodeList; Relation, Asset: string; Bytes, PNG: TBytes;
  begin
    Result:=False;
    if not WordListDefinitions.TryGetValue('p'+ID,Definition) then Exit;
    Images:=Definition.selectNodes('.//*[local-name()="imagedata" or local-name()="blip"]');
    if Images.length<>1 then Exit;
    Reference:=Images.item[0];
    Relation:=Attribute(Reference,'embed');
    if Relation='' then Relation:=Attribute(Reference,'id');
    if Relation='' then Exit;
    try
      if WordListImagePaths=nil then
      begin
        WordListImagePaths:=TDictionary<string,string>.Create;
        ReadWordRelationships(WordNumberingPath,False,WordListImagePaths);
      end;
      if not WordListImagePaths.TryGetValue(Relation,Asset) then Exit;
      ReadZip(Asset,Bytes);
      try
        Picture(Bytes,True,'','',False,0,16,0,True);
      except
        on Error: EReaderUnsupportedPicture do
        begin
          if not TryRasterizeOfficeWMF(Bytes,Canceled,PNG) then Exit;
          Picture(PNG,False,'','',False,0,16,0,True);
        end;
      end;
      Result:=True;
    except
      on Error: EAbort do raise;
      on Error: EMHLComponentRequired do raise;
      on Error: Exception do NoteUnreadableImage(Error.Message);
    end;
  end;
  procedure AddWordListMarker(const Paragraph: IXMLDOMNode);
  var Properties, Numbering: IXMLDOMNode; ID, StyleID, ParentStyle, Key, Marker, NumberFormat: string;
    Level, Index, Referenced, Number: Integer; Rule: TWordStyle; List: TWordList; Entry: TWordListLevel;
    Styles: TArray<string>; Indent, InheritedIndent: TWordListIndent;
  begin
    Properties:=WordChild(Paragraph,'ppr');
    Numbering:=WordChild(Properties,'numpr');
    ID:=WordValue(Numbering,'numid');
    Level:=StrToIntDef(WordValue(Numbering,'ilvl'),-1);
    StyleID:=WordValue(Properties,'pstyle');
    if StyleID='' then StyleID:=DefaultWordParagraphStyle;
    ParentStyle:=StyleID;
    Indent:=WordListIndent(Properties);
    for var Depth:=1 to 24 do
    begin
      if (ParentStyle='') or not WordStyleRules.TryGetValue(ParentStyle,Rule) or not Rule.Paragraph then Break;
      Styles:=Styles+[ParentStyle];
      if ID='' then ID:=Rule.ListID;
      if InheritedIndent.Left='' then InheritedIndent.Left:=Rule.ListIndent.Left;
      if InheritedIndent.First='' then InheritedIndent.First:=Rule.ListIndent.First;
      ParentStyle:=Rule.BasedOn;
    end;
    if (ID='') or (ID='0') then Exit;
    if WordListDefinitions=nil then LoadWordListDefinitions;
    Key:=CurrentPath+#0+ID;
    if not WordLists.TryGetValue(Key,List) then List:=ReadWordList(ID);
    if Level<0 then
    begin
      for var AppliedStyle in Styles do
      begin
        for Index:=0 to High(List.Levels) do
          if List.Levels[Index].ParagraphStyle=AppliedStyle then begin Level:=Index; Break; end;
        if Level>=0 then Break;
      end;
      if Level<0 then Level:=0;
    end;
    if not InRange(Level,0,High(List.Levels)) or not List.Levels[Level].Defined then Exit;
    Entry:=List.Levels[Level];
    if Indent.Left='' then Indent.Left:=InheritedIndent.Left;
    if Indent.Left='' then Indent.Left:=Entry.Indent.Left;
    if Indent.First='' then Indent.First:=InheritedIndent.First;
    if Indent.First='' then Indent.First:=Entry.Indent.First;
    ApplyWordListIndent(Indent);
    if Level in List.Started then Inc(List.Numbers[Level]) else List.Numbers[Level]:=Entry.Start;
    Include(List.Started,Level);
    for Index:=Level+1 to High(List.Levels) do
      if List.Levels[Index].RestartBefore>Level then Exclude(List.Started,Index);
    WordLists.AddOrSetValue(Key,List);
    if Entry.NumberFormat='none' then Exit;
    if Entry.PictureID<>'' then
    begin
      if AddWordListPicture(Entry.PictureID) then
      begin
        if Entry.Suffix<>'nothing' then AddText(' ',True);
        Exit;
      end;
      var Notice:='Рисунок маркера списка DOCX недоступен «'+Copy(Entry.PictureID,1,60)+'».';
      if (Warnings.Count<20) and (Warnings.IndexOf(Notice)<0) then Warnings.Add(Notice);
    end;
    Marker:=''; Index:=1;
    while Index<=Length(Entry.Pattern) do
    begin
      if (Entry.Pattern[Index]='%') and (Index<Length(Entry.Pattern)) and
        CharInSet(Entry.Pattern[Index+1],['1'..'9']) then
      begin
        Referenced:=Ord(Entry.Pattern[Index+1])-Ord('1');
        if (Referenced<=Level) and List.Levels[Referenced].Defined then
        begin
          Number:=List.Levels[Referenced].Start;
          if Referenced in List.Started then Number:=List.Numbers[Referenced];
          NumberFormat:=List.Levels[Referenced].NumberFormat;
          if Entry.LegalNumbering then NumberFormat:='decimal';
          if not MatchText(NumberFormat,['','decimal','decimalzero','upperroman','lowerroman',
            'upperletter','lowerletter']) and (Warnings.Count<20) then
          begin
            var Notice:='В списке DOCX формат «'+Copy(NumberFormat,1,80)+'» показан обычными цифрами.';
            if Warnings.IndexOf(Notice)<0 then Warnings.Add(Notice);
          end;
          Marker:=Marker+WordOrdinal(Number,NumberFormat);
        end;
        Inc(Index,2);
        Continue;
      end;
      Marker:=Marker+Entry.Pattern[Index];
      Inc(Index);
    end;
    if Marker='' then Exit;
    if Entry.NumberFormat='bullet' then
      case Marker[1] of
        #$F0B7: Marker:='•'+Marker.Substring(1);
        #$F0A7: Marker:='▪'+Marker.Substring(1);
      end;
    if Entry.Suffix<>'nothing' then Marker:=Marker+' ';
    AddText(Marker,True);
  end;
  function WordStyleVisibility(Identity: string; Paragraph: Boolean): TWordVisibility;
  var Rule: TWordStyle;
  begin
    for var Depth:=1 to 24 do
    begin
      if (Identity='') or not WordStyleRules.TryGetValue(Identity,Rule) or (Rule.Paragraph<>Paragraph) then Break;
      if Rule.Visibility<>wvInherited then Exit(Rule.Visibility);
      Identity:=Rule.BasedOn;
    end;
    Result:=wvInherited;
  end;
  function WordRunHidden(const Run: IXMLDOMNode): Boolean;
  var Properties, Paragraph: IXMLDOMNode; Identity: string; Visibility: TWordVisibility;
  begin
    Properties:=WordChild(Run,'rpr');
    Visibility:=WordRunVisibility(Properties);
    if Visibility<>wvInherited then Exit(Visibility=wvHidden);
    Result:=WordDefaultHidden;
    if not WordHasVisibilityStyles then Exit;
    Paragraph:=Run.parentNode;
    while Assigned(Paragraph) and (LocalName(Paragraph)<>'p') do Paragraph:=Paragraph.parentNode;
    Identity:=WordValue(WordChild(Paragraph,'ppr'),'pstyle');
    if Identity='' then Identity:=DefaultWordParagraphStyle;
    Visibility:=WordStyleVisibility(Identity,True);
    if Visibility<>wvInherited then Result:=Visibility=wvHidden;
    Identity:=WordValue(Properties,'rstyle');
    if Identity='' then Identity:=DefaultWordCharacterStyle;
    case WordStyleVisibility(Identity,False) of
      wvVisible: Result:=False;
      wvHidden: Result:=not Result;
    end;
  end;
  function WordHeading(const Paragraph: IXMLDOMNode; out TitleLayout: Boolean): Integer;
  var StyleID, ParentStyle, NamedHeading: string; Style: TWordStyle;
    Level: Integer;
  begin
    var Properties:=WordChild(Paragraph,'ppr');
    Level:=WordOutline(Properties);
    StyleID:=WordValue(Properties,'pstyle');
    NamedHeading:=LowerCase(StyleID);
    TitleLayout:=(NamedHeading='title') or NamedHeading.StartsWith('heading');
    ParentStyle:=StyleID;
    // A cycle or an excessively deep style chain cannot stall reading.
    for var Depth:=1 to 24 do
    begin
      if (Level>=0) or (ParentStyle='') or not WordStyleRules.TryGetValue(ParentStyle,Style) or not Style.Paragraph then Break;
      Level:=Style.OutlineLevel;
      ParentStyle:=Style.BasedOn;
    end;
    if Level>=0 then
    begin
      if Level=9 then Exit(0);
      Exit(Level+1);
    end;
    // Preserve the built-in English names in older or minimal DOCX packages.
    if NamedHeading='title' then Exit(1);
    if NamedHeading.StartsWith('heading') then
      Exit(EnsureRange(StrToIntDef(Trim(NamedHeading.Substring(7)),1),1,9));
    Result:=0;
  end;
  procedure ReadWordPicture(const Member: string; LeftAligned: Boolean; const Caption: string = '');
  var Bytes, PNG: TBytes;
  begin
    if WordPictureFallbacks.TryGetValue(Member,PNG) then
    begin
      if Length(PNG)=0 then raise EReaderUnsupportedPicture.Create('Неподдерживаемое изображение.');
      Picture(PNG,False,'',Caption,LeftAligned);
      Exit;
    end;
    ReadZip(Member,Bytes);
    try
      Picture(Bytes,True,'',Caption,LeftAligned);
    except
      on Error: EReaderUnsupportedPicture do
      begin
        Check;
        // Several placements can refer to the same embedded asset.
        WordPictureFallbacks.Add(Member,nil);
        if not TryRasterizeOfficeWMF(Bytes,Canceled,PNG) then raise;
        Picture(PNG,False,'',Caption,LeftAligned);
        WordPictureFallbacks[Member]:=PNG;
      end;
    end;
  end;
  procedure ApplyWordPictureCrop(const Reference: IXMLDOMNode);
  const DrawingNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  var Crop, Part: IXMLDOMNode; Item: TReaderPicture;
    Left, Top, Right, Bottom, W, H, Scale: Double;
    Limit: Integer;
    function Offset(const Name: string; out Edge: Double): Boolean;
    var Value: string; Percent: Boolean;
    begin
      Value:=Trim(Attribute(Crop,Name));
      Edge:=0;
      if Value='' then Exit(True);
      Percent:=Value.EndsWith('%');
      if Percent then Delete(Value,Length(Value),1);
      if not TRegEx.IsMatch(Value,'^[+-]?(?:[0-9]{1,10}|[0-9]{0,8}\.[0-9]{1,8})$') or
        not TryStrToFloat(Value,Edge,TFormatSettings.Invariant) then Exit(False);
      if Percent then Edge:=Edge/100 else Edge:=Edge/100000;
      Result:=True;
    end;
  begin
    if not Assigned(Reference.parentNode) or (LocalName(Reference.parentNode)<>'blipfill') then Exit;
    Crop:=nil;
    Part:=Reference.parentNode.firstChild;
    while Assigned(Part) do
    begin
      if (Part.nodeType=NODE_ELEMENT) and (LocalName(Part)='srcrect') and
        SameText(VarToStr(Part.namespaceURI),DrawingNamespace) then
      begin Crop:=Part; Break; end;
      Part:=Part.nextSibling;
    end;
    if not Assigned(Crop) then Exit;
    if not Offset('l',Left) or not Offset('t',Top) or not Offset('r',Right) or not Offset('b',Bottom) or
      (Max(0.0,Left)>=Min(1.0,1-Right)) or (Max(0.0,Top)>=Min(1.0,1-Bottom)) then
    begin
      if Warnings.Count<20 then Warnings.Add('Обрезка изображения DOCX не применена. Показано исходное изображение.');
      Exit;
    end;
    if (Left=0) and (Top=0) and (Right=0) and (Bottom=0) then Exit;
    Item:=FPictures.Last;
    W:=Item.Width*(1-Left-Right);
    H:=Item.Height*(1-Top-Bottom);
    Limit:=IfThen(Item.Monochrome,4096,1024);
    Scale:=Min(1.0,Limit/Max(W,H));
    Item.PaintBounds:=Rect(Round(-Left*Item.Width*Scale),Round(-Top*Item.Height*Scale),
      Round((1-Left)*Item.Width*Scale),Round((1-Top)*Item.Height*Scale));
    Item.Width:=Max(1,Round(W*Scale));
    Item.Height:=Max(1,Round(H*Scale));
    FPictures[FPictures.Count-1]:=Item;
  end;
  function ReadWordDocument: IXMLDOMDocument3;
  const MaxWordXML = 2 * MAX_DOCUMENT_BYTES;
  var Index: Integer; Size: Int64; Input: TStream; Header: TZipHeader; Adapter: IStream; Value: OleVariant;
  begin
    Check; Index:=Zip.IndexOf('word/document.xml');
    if Index<0 then raise EReadError.Create('В DOCX не найден основной документ.');
    Size:=Zip.FileInfo[Index].UncompressedSize;
    if Size<=MAX_DOCUMENT_BYTES then
    begin
      ReadZip('word/document.xml',Data);
      Exit(XMLDocument(Data));
    end;
    if (Size>MaxWordXML) or (Size>UnpackedLimit-UnpackedBytes) then
      raise EReadError.CreateFmt('Основной документ DOCX превышает предел чтения (%d МиБ).',
        [MaxWordXML div (1024*1024)]);
    Inc(UnpackedBytes,Size);
    // Parse the large XML part directly. Avoid keeping both the unpacked bytes
    // and a separate UTF-16 copy alive while MSXML builds the document tree.
    Zip.Read(Index,Input,Header,True);
    try
      Adapter:=TStreamAdapter.Create(Input,soReference);
      Value:=IUnknown(Adapter);
      Result:=ReaderXMLParser;
      if not Result.load(Value) then
        raise EReadError.Create('Не удалось прочитать основной документ DOCX: '+Result.parseError.reason);
    finally
      VarClear(Value); Adapter:=nil; Input.Free;
    end;
  end;
  function ReadLargeEpubJpeg(Index: Integer): TBytes;
  var Size, Remaining: Int64; Folder, TempName, SystemRoot: string;
    Available, TotalSpace, Reserve: UInt64; Header: TZipHeader; Input: TStream;
    Output: TFileStream; Buffer: TBytes; Count: Integer; Raster: TReaderRaster;
    Extent: TPoint; Bitmap: TBitmap; JPEG: TJPEGImage; Preview: TBytesStream;
  begin
    Size:=Zip.FileInfo[Index].UncompressedSize;
    if (Size<=0) or (Size>255*1024*1024) then raise EReadError.Create('Изображение JPEG в EPUB слишком велико.');
    Inc(UnpackedBytes,Size);
    if UnpackedBytes>UnpackedLimit then raise EReadError.Create('EPUB слишком велик для встроенной читалки.');
    Folder:=TPath.GetTempPath;
    SystemRoot:=GetEnvironmentVariable('SystemDrive')+'\';
    Reserve:=UInt64(8)*1024*1024*1024;
    if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,TotalSpace,nil) then RaiseLastOSError;
    if Available<Reserve then raise EWriteError.Create('Для чтения большого JPEG нужно оставить 8 ГБ на системном диске.');
    if not SameText(ExtractFileDrive(Folder),ExtractFileDrive(SystemRoot)) then Reserve:=64*1024*1024;
    if not GetDiskFreeSpaceEx(PChar(Folder),Available,TotalSpace,nil) then RaiseLastOSError;
    if Available<UInt64(Size)+Reserve then raise EWriteError.Create('Недостаточно места для подготовки изображения EPUB.');
    TempName:=TPath.Combine(Folder,'homelibre-epub-jpeg-'+TGUID.NewGuid.ToString+'.jpg');
    try
      Input:=nil;
      try
        Zip.Read(Index,Input,Header,True);
        SetLength(Buffer,256*1024);
        Count:=Input.Read(Buffer[0],3);
        if (Count<>3) or (Buffer[0]<>$FF) or (Buffer[1]<>$D8) or (Buffer[2]<>$FF) then
          raise EReadError.Create('В EPUB указан неверный заголовок JPEG.');
        Output:=TFileStream.Create(TempName,fmCreate);
        try
          Output.WriteBuffer(Buffer[0],Count); Remaining:=Size-Count;
          while Remaining>0 do
          begin
            Check; Count:=Integer(Min(Remaining,Length(Buffer)));
            Input.ReadBuffer(Buffer[0],Count); Output.WriteBuffer(Buffer[0],Count);
            Dec(Remaining,Count);
          end;
          if Input.Read(Buffer[0],1)<>0 then raise EReadError.Create('Размер JPEG в EPUB не совпадает с указанным.');
        finally Output.Free; end;
      finally Input.Free; end;
      Check;
      // The original stays inside the EPUB. WIC produces only a bounded view,
      // using the same raster path as a standalone large JPEG.
      Raster:=TReaderRaster.Create(TempName,1600);
      try
        Extent:=Raster.PageSize(0); Bitmap:=Raster.Render(0,Extent.X,Extent.Y);
        try
          JPEG:=TJPEGImage.Create;
          try
            JPEG.CompressionQuality:=92; JPEG.Assign(Bitmap);
            Preview:=TBytesStream.Create;
            try
              JPEG.SaveToStream(Preview);
              Result:=Copy(Preview.Bytes,0,Integer(Preview.Size));
            finally Preview.Free; end;
          finally JPEG.Free; end;
        finally Bitmap.Free; end;
      finally Raster.Free; end;
    finally Winapi.Windows.DeleteFile(PChar(TempName)); end;
  end;
  function DecodeInlineImage(const Ref: string; out Bytes: TBytes): Boolean;
  const ImageLimit=16*1024*1024;
    Base64Limit=(ImageLimit+2) div 3*4;
  var Separator, I, J, HighDigit, LowDigit: Integer;
    Encoded: string;
    IsBase64: Boolean;

    function HexDigit(Value: Byte): Integer;
    begin
      case Value of
        Ord('0')..Ord('9'): Result:=Value-Ord('0');
        Ord('A')..Ord('F'): Result:=Value-Ord('A')+10;
        Ord('a')..Ord('f'): Result:=Value-Ord('a')+10;
      else Result:=-1;
      end;
    end;

  begin
    if not Ref.StartsWith('data:image/',True) then Exit(False);
    Separator:=Pos(',',Ref);
    if Separator<=11 then raise EReadError.Create('Неверный адрес встроенного изображения.');
    if Length(Ref)-Separator>3*Base64Limit then raise EReadError.Create('Изображение превышает 16 МБ.');
    IsBase64:=SameText(Copy(Ref,Separator-7,7),';base64');
    Encoded:=Ref.Substring(Separator);
    if IsBase64 and not Encoded.Contains('%') then
    begin
      if Length(Encoded)>24*1024*1024 then
        raise EReadError.Create('Изображение превышает 16 МБ.');
      Bytes:=TNetEncoding.Base64.DecodeStringToBytes(Encoded);
    end
    else
    begin
      // Data URLs use byte escapes. An unescaped plus is a literal plus.
      Bytes:=TEncoding.UTF8.GetBytes(Encoded);
      I:=0; J:=0;
      while I<Length(Bytes) do
      begin
        if (J and $FFFF)=0 then Check;
        if Bytes[I]=Ord('%') then
        begin
          if I+2>=Length(Bytes) then raise EReadError.Create('Неверные данные встроенного изображения.');
          HighDigit:=HexDigit(Bytes[I+1]); LowDigit:=HexDigit(Bytes[I+2]);
          if (HighDigit<0) or (LowDigit<0) then raise EReadError.Create('Неверные данные встроенного изображения.');
          Bytes[J]:=Byte((HighDigit shl 4)+LowDigit);
          Inc(I,3);
        end
        else
        begin
          Bytes[J]:=Bytes[I];
          Inc(I);
        end;
        Inc(J);
      end;
      SetLength(Bytes,J);
      if IsBase64 then Bytes:=TNetEncoding.Base64.Decode(Bytes);
    end;
    if Length(Bytes)>ImageLimit then raise EReadError.Create('Изображение превышает 16 МБ.');
    Result:=True;
  end;

  function RenderReaderSvg(const Bytes: TBytes; MaxWidth: Integer = 1536; MaxHeight: Integer = 1536): TBytes;
  var Tool: string;
  begin
    Tool:=FindExternalTool('resvg.exe','kfx-export');
    if not FileExists(Tool) then
      raise EMHLComponentRequired.Create('KfxExport','Для показа рисунка SVG нужен обработчик из модуля KFX/AZW8.');
    Result:=RenderStaticSvg(Bytes,Tool,TPath.GetTempPath,MaxWidth,MaxHeight,Canceled);
  end;

  function ReadFb3Picture(const Member: string): TBytes;
  const Svg11Declaration = '(?m)^[ \t]*<!DOCTYPE\s+svg\s+PUBLIC\s+["'']-//W3C//DTD SVG 1\.1//EN["'']\s+'+
      '["'']https?://www\.w3\.org/Graphics/SVG/1\.1/DTD/svg11\.dtd["'']\s*>[ \t]*(?:\r?\n)?';
  begin
    ReadZip(Member,Result);
    var Prefix:=TEncoding.ASCII.GetString(Result,0,Min(Length(Result),4096));
    if not TRegEx.IsMatch(Prefix,'<(?:[\w.-]+:)?svg(?:[\s>/])') then Exit;
    // Remove only the external SVG 1.1 declaration. The static renderer still rejects all other DTDs.
    var Declaration:=TRegEx.Match(Prefix,Svg11Declaration);
    if Declaration.Success then System.Delete(Result,Declaration.Index-1,Declaration.Length);
    Result:=RenderReaderSvg(Result);
  end;

  function NeedsJpegRecovery(const Image: TBytes): Boolean; forward;

  function ReadEpubRasterViewport(const Drawing: IXMLDOMNode): Boolean;
  const SVGNamespace = 'http://www.w3.org/2000/svg';
    PositionValue = '\A[+-]?[0-9]{1,5}(?:\.[0-9]{1,5})?\z';
    ZeroShift = '\Atranslate\(\s*[+-]?(?:0+(?:\.0*)?|\.0+)(?:(?:\s*,\s*|\s+)[+-]?(?:0+(?:\.0*)?|\.0+))?\s*\)\z';
  var Box: TArray<string>; Child, Layer: IXMLDOMNode;
    Width, Height, Index, References, RasterWidth, RasterHeight, Scale, WidthPercentX100: Integer;
    Reflowable, SizedLayer: Boolean;
    X, Y, Left, Top, LayerWidth, LayerHeight: Double;
    Anchor, Reference, Member, ArchiveMember, CssWidth, CssHeight: string; Raster, Bitmap: TBytes;
    function AttributesAllowed(const Node: IXMLDOMNode; const Allowed: string): Boolean;
    begin
      for var Index:=0 to Node.attributes.length-1 do
      begin
        var Item:=Node.attributes.item[Index];
        if (Item.namespaceURI='http://www.w3.org/2000/xmlns/') or (Item.nodeName='xmlns') then Continue;
        var Name:=Item.baseName;
        var Namespace:=VarToStr(Item.namespaceURI);
        if (Namespace='http://www.w3.org/XML/1998/namespace') and (Name='lang') then Name:='xml:lang'
        else if (Namespace<>'') and not ((Namespace='http://www.w3.org/1999/xlink') and (Name='href')) then Exit(False);
        if not Allowed.Contains('|'+Name+'|') then Exit(False);
      end;
      Result:=True;
    end;
    function SupportedAttributes(const Node: IXMLDOMNode; const Allowed: string; InlineSizing: Boolean = False): Boolean;
    var Value: string;
    begin
      if not AttributesAllowed(Node,Allowed) then Exit(False);
      Value:=Trim(Attribute(Node,'transform'));
      if (Value<>'') and (Value<>'none') and not TRegEx.IsMatch(Value,ZeroShift) then Exit(False);
      Value:=Trim(Attribute(Node,'preserveaspectratio'));
      if (Value<>'') and not TRegEx.IsMatch(Value,'\Ax(?:Min|Mid|Max)Y(?:Min|Mid|Max)(?:\s+meet)?\z') then Exit(False);
      Value:='';
      if not InlineSizing then Value:=Attribute(Node,'style');
      Result:=CSS.PreservesSvgViewport(LocalName(Node),Attribute(Node,'class'),Attribute(Node,'id'),Value);
    end;
    function TrailingProse(const Node: IXMLDOMNode): Boolean;
    const MarginLength = '(?:0|[0-9]+(?:\.[0-9]+)?(?:px|pt))';
      FlowRule = '\A(?:float\s*:\s*none|text-align\s*:\s*(?:left|right|center|justify)|'+
        'margin\s*:\s*'+MarginLength+'(?:\s+'+MarginLength+'){0,3})\z';
    begin
      if not MatchText(LocalName(Node),['p','div']) or not AttributesAllowed(Node,'|style|id|') then Exit(False);
      for var Rule in Attribute(Node,'style').Split([';']) do
        if (Rule.Trim<>'') and not TRegEx.IsMatch(Rule.Trim,FlowRule,[roIgnoreCase]) then Exit(False);
      var Descendants:=Node.selectNodes('.//*');
      for var Index:=0 to Descendants.length-1 do
      begin
        var Member:=Descendants.item[Index];
        if LocalName(Member)='a' then
        begin
          if not AttributesAllowed(Member,'|href|id|') then Exit(False);
        end
        else if not MatchText(LocalName(Member),['p','span','em','i','strong','b','br']) or
          not AttributesAllowed(Member,'|id|') then Exit(False);
      end;
      Result:=True;
    end;
    function ReflowablePage: Boolean;
    const CoverCSS = '\A(?:\s*(?:@page|html|body|div)\s*\{(?:\s*(?:;|(?:text-align\s*:\s*center|'+
      '(?:margin|padding)\s*:\s*0(?:pt|px)?)\s*(?:;|(?=\}))))*\s*\})*\s*\z';
    var Container, Item, Head, PathChild: IXMLDOMNode; HasLinks: Boolean;
      function LayoutSafe(const Node: IXMLDOMNode): Boolean;
      begin
        Result:=CSS.PreservesSvgCoverRatio(LocalName(Node),Attribute(Node,'class'),Attribute(Node,'id'));
      end;
    begin
      // With no explicit height on its ancestors, a full-width SVG uses its viewBox ratio.
      if EpubFixedLayout or Assigned(Drawing.ownerDocument.selectSingleNode('//processing-instruction("xml-stylesheet")')) or
        not AttributesAllowed(Drawing,'|viewBox|width|height|version|preserveAspectRatio|id|class|') or
        not AttributesAllowed(Layer,'|width|height|x|y|href|alt|id|class|') then Exit(False);
      PathChild:=Drawing; Container:=Drawing.parentNode;
      while Assigned(Container) and MatchText(LocalName(Container),['body','div']) do
      begin
        if not AttributesAllowed(Container,'|class|id|') then Exit(False);
        // MSXML can return different interface instances for the same node.
        // Check the position through the siblings of the actual path element.
        Item:=PathChild.previousSibling;
        while Assigned(Item) do
        begin
          if (Item.nodeType=NODE_ELEMENT) or
            ((Item.nodeType in [NODE_TEXT,NODE_CDATA_SECTION]) and (Trim(Item.text)<>'')) then Exit(False);
          Item:=Item.previousSibling;
        end;
        Item:=PathChild.nextSibling;
        while Assigned(Item) do
        begin
          if Item.nodeType=NODE_ELEMENT then
          begin
            if (LocalName(Container)<>'body') or not TrailingProse(Item) then Exit(False);
          end
          else if (Item.nodeType in [NODE_TEXT,NODE_CDATA_SECTION]) and (Trim(Item.text)<>'') then Exit(False);
          Item:=Item.nextSibling;
        end;
        if LocalName(Container)='body' then Break;
        PathChild:=Container; Container:=Container.parentNode;
      end;
      if not Assigned(Container) or (LocalName(Container)<>'body') then Exit(False);
      Container:=Container.parentNode;
      if not Assigned(Container) or (LocalName(Container)<>'html') or
        not AttributesAllowed(Container,'|xml:lang|lang|') then Exit(False);
      Head:=Container.selectSingleNode('./*[local-name()="head"]');
      HasLinks:=Assigned(Head) and Assigned(Head.selectSingleNode('./*[local-name()="link"]'));
      if Assigned(Head) then
      begin
        Item:=Head.firstChild;
        while Assigned(Item) do
        begin
          if (Item.nodeType=NODE_ELEMENT) and not MatchText(LocalName(Item),['title','meta']) then
          begin
            if HasLinks then
            begin
              if not MatchText(Attribute(Item,'media').Trim,['','all','screen']) or
                not MatchText(Attribute(Item,'type').Trim,['','text/css']) then Exit(False);
              if LocalName(Item)='link' then
              begin
                if not AttributesAllowed(Item,'|href|rel|type|media|') or
                  not SameText(Attribute(Item,'rel').Trim,'stylesheet') or
                  (Attribute(Item,'href')='') or (Attribute(Item,'href').IndexOfAny(['?','#'])>=0) then Exit(False);
              end
              else if (LocalName(Item)<>'style') or not AttributesAllowed(Item,'|type|media|') then Exit(False);
            end
            else if (LocalName(Item)<>'style') or (Length(Item.text)>65536) or not TRegEx.IsMatch(
              TRegEx.Replace(Item.text,'/\*.*?\*/','',[roSingleLine]),CoverCSS,[roIgnoreCase]) then Exit(False);
          end;
          Item:=Item.nextSibling;
        end;
      end;
      if HasLinks then
      begin
        if not EpubStylesAvailable or ((WidthPercentX100<>10000) and (Attribute(Drawing,'width')<>'')) or
          not LayoutSafe(Drawing) or not LayoutSafe(Layer) then Exit(False);
        Container:=Drawing.parentNode;
        while Assigned(Container) and MatchText(LocalName(Container),['div','body','html']) do
        begin
          if not LayoutSafe(Container) then Exit(False);
          Container:=Container.parentNode;
        end;
      end;
      Result:=True;
    end;
    function ReadPosition(const Value: string; out Position: Double): Boolean;
    begin
      Result:=TRegEx.IsMatch(Value,PositionValue) and TryStrToFloat(Value,Position,TFormatSettings.Invariant);
    end;
    function ReadLayerSizing: Boolean;
    var At: Integer; Key, Value: string; Percent: Double;
      MaxWidth, MaxHeight, ResizeWidth, ResizeHeight: Boolean;
    begin
      CssWidth:=''; CssHeight:=''; MaxWidth:=False; MaxHeight:=False;
      ResizeWidth:=False; ResizeHeight:=False;
      for var Entry in Attribute(Layer,'style').Split([';']) do
      begin
        if Entry.Trim='' then Continue;
        At:=Pos(':',Entry); if At=0 then Exit(False);
        Key:=LowerCase(Copy(Entry,1,At-1).Trim);
        Value:=LowerCase(Copy(Entry,At+1,MaxInt).Trim);
        if (Key='text-align') and MatchText(Value,['start','end','left','right','center','justify']) then Continue;
        if (Key='max-width') and (Value='100%') then MaxWidth:=True
        else if (Key='max-height') and (Value='100%') then MaxHeight:=True
        else
        begin
          if not MatchText(Key,['width','height']) or not TRegEx.IsMatch(Value,'\A[0-9]{1,3}(?:\.[0-9]{1,5})?%\z') or
            not TryStrToFloat(Value.Substring(0,Value.Length-1),Percent,TFormatSettings.Invariant) or
            (Percent<=0) or (Percent>100) then Exit(False);
          if Key='width' then
          begin
            CssWidth:=Value;
            ResizeWidth:=Percent<>100;
          end
          else
          begin
            CssHeight:=Value;
            ResizeHeight:=Percent<>100;
          end;
        end;
      end;
      SizedLayer:=ResizeWidth or ResizeHeight;
      Result:=(not MaxWidth or (CssWidth<>'') or (LayerWidth<=Width)) and
        (not MaxHeight or (CssHeight<>'') or (LayerHeight<=Height));
    end;
  begin
    Result:=False;
    if VarToStr(Drawing.namespaceURI)<>SVGNamespace then Exit;
    Box:=TRegEx.Split(Trim(Attribute(Drawing,'viewbox')),'[\s,]+');
    if (Length(Box)<>4) or not ReadPosition(Box[0],Left) or not ReadPosition(Box[1],Top) or
      not TryStrToInt(Box[2],Width) or not TryStrToInt(Box[3],Height) or
      (Width<1) or (Height<1) or (Width>4096) or (Height>4096) then Exit;
    var SvgWidth:=Attribute(Drawing,'width');
    WidthPercentX100:=0;
    var Percent: Double;
    if TRegEx.IsMatch(SvgWidth,'\A[0-9]{1,3}(?:\.[0-9]{1,2})?%\z') and
      TryStrToFloat(SvgWidth.Substring(0,SvgWidth.Length-1),Percent,TFormatSettings.Invariant) and
      (Percent>0) and (Percent<=100) then WidthPercentX100:=Round(Percent*100);
    if ((WidthPercentX100=0) and not MatchText(SvgWidth,['',Box[2]])) or
      not MatchText(Attribute(Drawing,'height'),['','100%','99%',Box[3]]) then Exit;
    Layer:=nil; Child:=Drawing.firstChild;
    while Assigned(Child) do
    begin
      if Child.nodeType=NODE_ELEMENT then
      begin
        if VarToStr(Child.namespaceURI)<>SVGNamespace then Exit;
        if LocalName(Child)='image' then
        begin
          if Assigned(Layer) then Exit;
          Layer:=Child;
        end
        else if not MatchText(LocalName(Child),['title','desc']) then Exit;
      end;
      Child:=Child.nextSibling;
    end;
    if not Assigned(Layer) or Layer.hasChildNodes or
      not ReadPosition(Attribute(Layer,'width'),LayerWidth) or not ReadPosition(Attribute(Layer,'height'),LayerHeight) or
      (LayerWidth<=0) or (LayerHeight<=0) or (LayerWidth>8192) or (LayerHeight>8192) then Exit;
    X:=0; Y:=0;
    if ((Attribute(Layer,'x')<>'') and not ReadPosition(Attribute(Layer,'x'),X)) or
      ((Attribute(Layer,'y')<>'') and not ReadPosition(Attribute(Layer,'y'),Y)) then Exit;
    if not ReadLayerSizing then Exit;
    if SizedLayer and (not EpubStylesAvailable or not CSS.CompleteSvgRules or
      Assigned(Drawing.ownerDocument.selectSingleNode('//processing-instruction("xml-stylesheet")'))) then Exit;
    Reflowable:=not SizedLayer and (Left=0) and (Top=0) and (X=0) and (Y=0) and
      (LayerWidth=Width) and (LayerHeight=Height);
    if Reflowable then
    begin
      if (Trim(Attribute(Drawing,'preserveaspectratio'))<>'none') or
        ((WidthPercentX100=0) and Assigned(Drawing.selectSingleNode('@width'))) or
        (Attribute(Drawing,'height')<>'100%') or not ReflowablePage then Exit;
      if WidthPercentX100=10000 then WidthPercentX100:=0;
    end
    else
    begin
      if not MatchText(SvgWidth,['','100%','99%',Box[2]]) or
        not SupportedAttributes(Drawing,'|viewBox|width|height|version|class|id|style|transform|preserveAspectRatio|') or
        not SupportedAttributes(Layer,'|x|y|width|height|href|transform|class|id|alt|preserveAspectRatio|style|',SizedLayer) then Exit;
      WidthPercentX100:=0;
    end;
    References:=0;
    for var AttrIndex:=0 to Layer.attributes.length-1 do
      if Layer.attributes.item[AttrIndex].baseName='href' then Inc(References);
    Reference:=Attribute(Layer,'href');
    if (References<>1) or (Reference='') or Reference.Contains('#') or Reference.StartsWith('data:') or
      (Drawing.selectNodes('.//*[local-name()="image" or local-name()="feImage"]').length<>1) then Exit;

    try
      Member:=ZipPath(CurrentPath,Reference); Index:=Zip.IndexOf(Member);
      if (Index>=0) and (Zip.FileInfo[Index].UncompressedSize>16*1024*1024) then
        raise EReadError.Create('Изображение внутри SVG превышает 16 МБ.');
      ReadZip(Member,Raster);
      if not MatchText(StaticSvgRasterMime(Raster),['image/jpeg','image/png']) or NeedsJpegRecovery(Raster) then
        raise EReadError.Create('SVG содержит повреждённое или неподдерживаемое изображение.');
      if Reflowable then
      begin
        var Stream:=TBytesStream.Create(Raster);
        try
          if not ImageDimensions(Stream,RasterWidth,RasterHeight) or (RasterWidth<=0) or (RasterHeight<=0) then Exit;
        finally Stream.Free; end;
        if Int64(RasterWidth)*Height=Int64(RasterHeight)*Width then
        begin
          Bitmap:=Raster;
          if Assigned(FImageArchiveLock) then ArchiveMember:=Member;
        end
        else
        begin
          // Match the export density and keep the PNG within the reader's byte limit.
          Scale:=Min(Min(4096 div Max(Width,Height),Floor(Sqrt(4000000 div (Width*Height)))),
            Max((RasterWidth+Width-1) div Width,(RasterHeight+Height-1) div Height));
          if Scale<1 then Exit;
          Width:=Width*Scale; Height:=Height*Scale;
        end;
      end;
      if Length(Bitmap)=0 then
      begin
        var Viewport:=Drawing.cloneNode(True) as IXMLDOMElement;
        Viewport.setAttribute('width',IntToStr(Width));
        Viewport.setAttribute('height',IntToStr(Height));
        var ViewportLayer:=Viewport.selectSingleNode('./*[local-name()="image"]') as IXMLDOMElement;
        if CssWidth<>'' then ViewportLayer.setAttribute('width',CssWidth);
        if CssHeight<>'' then ViewportLayer.setAttribute('height',CssHeight);
        ViewportLayer.removeAttribute('style');
        EmbedStaticSvgRaster(ViewportLayer.selectSingleNode('./@*[local-name()="href"]'),Raster);
        Bitmap:=SerializeStaticSvg(Viewport);
        if Reflowable then Bitmap:=RenderReaderSvg(Bitmap,Width,Height)
        else Bitmap:=RenderReaderSvg(Bitmap,Min(Width,1536),Min(Height,1536));
      end;
    except
      on Error: EAbort do raise;
      on Error: EMHLComponentRequired do raise;
      on Error: Exception do
      begin
        if Warnings.Count<20 then Warnings.Add('Обрезка SVG не показана: '+Error.Message);
        Exit;
      end;
    end;
    Anchor:=CurrentPath+'#'+Attribute(Layer,'id');
    if not Anchor.EndsWith('#') and (Length(Anchor)<=4096) and (FAnchors.Count<100000) then RegisterEpubAnchor(Anchor);
    Picture(Bitmap,False,ArchiveMember,'',False,0,0,0,False,False,0,False,WidthPercentX100);
    Result:=True;
  end;

  function ReadFB2Picture(const Identity: string): TBytes;
  var Item: TFB2PictureData;
  begin
    if not Binaries.TryGetValue(Identity,Item) then Exit(nil);
    if Length(Item.Preview)>0 then Exit(Item.Preview);
    Result:=TNetEncoding.Base64.DecodeStringToBytes(Item.Encoded);
    if SameText(Item.MediaType,'image/svg+xml') then
    begin
      Result:=RenderReaderSvg(Result);
      Item.Preview:=Result;
      Binaries[Identity]:=Item;
    end;
  end;

  function ReadHTMLImage(const Ref: string): TBytes;
  var Folder, Path: string; Suffix: Integer; Stream: TFileStream;
  begin
    if Resources.TryGetValue(Ref,Result) or DecodeInlineImage(Ref,Result) then Exit;
    Path:=TNetEncoding.URL.Decode(Ref.Replace('+','%2B'));
    if Resources.TryGetValue(Path,Result) then Exit;

    Suffix:=Ref.IndexOfAny(['?','#']);
    if Suffix>=0 then Path:=TNetEncoding.URL.Decode(Ref.Substring(0,Suffix).Replace('+','%2B'));
    if (Path='') or Path.Contains(':') or Path.StartsWith('/') or Path.StartsWith('\') then
      raise Exception.Create('Внешнее изображение пропущено.');
    Folder:=IncludeTrailingPathDelimiter(ExtractFileDir(TPath.GetFullPath(FileName)));
    Path:=TPath.GetFullPath(TPath.Combine(Folder,Path));
    if not Path.StartsWith(Folder,True) then raise Exception.Create('Внешнее изображение пропущено.');
    if not FileExists(Path) then raise Exception.Create('Изображение не найдено.');
    Stream:=TFileStream.Create(Path,fmOpenRead or fmShareDenyNone);
    try
      if Stream.Size>16*1024*1024 then raise Exception.Create('Изображение слишком велико.');
      SetLength(Result,Stream.Size);
      if Length(Result)>0 then Stream.ReadBuffer(Result[0],Length(Result));
    finally Stream.Free; end;
  end;

  procedure HTMLPicture(const Source, Alt, Width, Height: string);
  var Ref, Description: string;
  begin
    Ref:=Trim(Source); Description:=Trim(Alt);
    if Ref='' then
    begin
      if Description<>'' then AddText(Description);
      Exit;
    end;
    try
      Picture(ReadHTMLImage(Ref),False,'','',False,HTMLImageDimension(Width),HTMLImageDimension(Height));
    except
      on Error: EAbort do raise;
      on Error: EMHLComponentRequired do raise;
      on Error: Exception do
      begin
        NoteUnreadableImage(Error.Message);
        AddText('[Изображение не читается.]');
        if Description<>'' then AddText(' '+Description);
      end;
    end;
  end;

  function SavedEpubInfo(const InfoType: string): IXMLDOMNode;
  begin
    Result:=nil;
    var Description:=DirectChild(Root,'description');
    if Description=nil then Exit;
    var Info:=Description.firstChild;
    while Assigned(Info) do
    begin
      if (LocalName(Info)='custom-info') and (Attribute(Info,'info-type')=InfoType) then Exit(Info);
      Info:=Info.nextSibling;
    end;
  end;

  function CoverAlreadyInBody(const Cover: IXMLDOMNode; out PreviewID: string): Boolean;
  var Info, Section: IXMLDOMNode; Ref, Key: string; Binary: TFB2PictureData; Sources: TDictionary<string,Byte>;
  begin
    Result:=False; PreviewID:='';
    Info:=SavedEpubInfo('HomeLibre: EPUB cover in body v1');
    if Info=nil then Exit;
    Key:=Info.text;
    if not TRegEx.IsMatch(Key,'\Aid_[0-9a-f]{24}\z') then Exit;
    Section:=Root.selectSingleNode('./*[local-name()="body"]/*[local-name()="section" and @id="'+Key+'"]');
    if Section=nil then Exit;
    Sources:=TDictionary<string,Byte>.Create;
    try
      var Pictures:=Section.selectNodes('.//*[local-name()="image"]');
      for var K:=0 to Pictures.length-1 do Sources.TryAdd(Attribute(Pictures.item[K],'href'),0);
      Pictures:=Cover.selectNodes('./*[local-name()="image"]');
      for var K:=0 to Pictures.length-1 do
      begin
        Ref:=Attribute(Pictures.item[K],'href');
        if not Ref.StartsWith('#') or not Sources.ContainsKey(Ref) then Exit;
        if PreviewID='' then
          if Binaries.TryGetValue(Ref.Substring(1),Binary) and (Length(Binary.Encoded)<=6*1024*1024) then
            PreviewID:=Ref.Substring(1);
      end;
      Result:=Pictures.length>0;
    finally Sources.Free; end;
  end;

  procedure LoadSavedEpubOutline;
  var Payload: string; Rows, Fields: TArray<string>;
    Entries: TList<TReaderChapter>; Entry: TReaderChapter; Depth: Integer;
  begin
    var Info:=SavedEpubInfo('HomeLibre: EPUB outline v1');
    if Info=nil then Exit;
    Payload:=Info.text;
    if (Payload='') or (Length(Payload)>2*1024*1024) then Exit;
    Rows:=Payload.Replace(#13#10,#10).Split([#10]);
    if Length(Rows)>20000 then Exit;
    Entries:=TList<TReaderChapter>.Create;
    try
      for var Row in Rows do
      begin
        Check;
        Fields:=Row.Split([#9]);
        if Length(Fields)<>3 then Exit;
        if not TryStrToInt(Fields[1],Depth) or (Depth<1) or (Depth>16) or (Fields[1]<>IntToStr(Depth)) then Exit;
        Entry.Title:=Fields[2].Trim;
        if (Entry.Title='') or (Length(Entry.Title)>4096) or not FAnchors.TryGetValue(Fields[0],Entry.Position) then Exit;
        Entry.Depth:=Depth-1;
        Entries.Add(Entry);
      end;
      FChapters.Clear;
      FChapters.AddRange(Entries);
    finally Entries.Free; end;
  end;

  procedure LoadEpubOutline;
  var Entries:TList<TReaderChapter>;
    OwnEpub, OwnFb2Epub, OwnKfxView, RootEntry, KfxFallback: Boolean; PageEntries, ChapterIndex: Integer;
    SavedPath, Resource, NcxID:string; Navigation:IXMLDOMDocument3; Bytes:TBytes; J:Integer;
    Entry, TocNode:IXMLDOMNode;

    function IsPreparedEpub: Boolean;
    const BookCSS = 'body{line-height:1.35}p{margin:.45em 0}h1,h2,h3,h4,h5,h6{text-align:center}'+
      'img{max-width:100%;height:auto}pre{white-space:pre-wrap}table{border-collapse:collapse}'+
      'td,th{padding:.2em .4em}';
    var Style: string;
    begin
      // Recognize older EPUBs from BookProcessing without changing publisher TOCs.
      Result := (PackagePath = 'OEBPS/package.opf') and
        (Attribute(Root,'unique-identifier') = 'book-id') and
        CSSCache.TryGetValue('OEBPS/book.css',Style) and
        ((Style = BookCSS) or Style.StartsWith(BookCSS+'.homelibre-text-frame{'));
    end;

    function PageLabel(const Text: string): Boolean;
    begin
      Result := TRegEx.IsMatch(Text,'^(Страница|Слайд) [1-9][0-9]*$');
    end;

    procedure AddEntry(const LabelText, Href:string; Depth:Integer; StartOnly:Boolean=False);
    var Target:string; Position, MatchedPosition:Integer; C:TReaderChapter;
    begin
      Check; if (Href='') or (LabelText='') or (Length(LabelText)>4096) then Exit;
      Target:=EpubSpaceAnchor(LocalLinkTarget(Href));
      if (Target='') or not FAnchors.TryGetValue(Target,Position) then Exit;
      C.Title:=Trim(TRegEx.Replace(LabelText,'\s+',' ')); if C.Title='' then Exit;
      if Assigned(EpubOutlineTargets) and EpubOutlineTargets.TryGetValue(Target+#0+C.Title,MatchedPosition) and
        (MatchedPosition>=0) then Position:=MatchedPosition;
      if Entries.Count>=20000 then raise Exception.Create('Слишком много пунктов оглавления EPUB.');
      C.Position:=Position; C.Depth:=EnsureRange(Depth,0,15);
      if StartOnly and (Depth=0) and Target.EndsWith('#') then RootEntry:=True;
      if OwnFb2Epub and (Target='OEBPS/body-1.xhtml#') and SameText(C.Title,Title.Trim) then RootEntry:=True;
      if OwnEpub then
      begin
        if (Target='OEBPS/book.xhtml#') and SameText(C.Title,Title.Trim) then RootEntry:=True;
        if (Depth=0) and Target.StartsWith('OEBPS/book.xhtml#heading-') and PageLabel(C.Title) then
          Inc(PageEntries);
      end;
      // Boko writes an EPUB-required root entry when the KFX has no TOC.
      // Actual KFX entries carry fragment targets, including ones on the first page.
      if OwnKfxView and (Target='OEBPS/chapter_0.xhtml#') then KfxFallback:=True;
      Entries.Add(C);
    end;
    procedure ReadList(const N:IXMLDOMNode; NCX:Boolean; Depth:Integer);
    var K:Integer; Child, LabelNode, LinkNode, Nested:IXMLDOMNode;
    begin
      Check; if (N=nil) or (Depth>128) then Exit;
      for K:=0 to N.childNodes.length-1 do
      begin
        Child:=N.childNodes.item[K];
        if NCX then
        begin
          if LocalName(Child)<>'navpoint' then Continue;
          LabelNode:=DirectChild(Child,'navlabel'); LinkNode:=DirectChild(Child,'content');
          if (LabelNode<>nil) and (LinkNode<>nil) then AddEntry(LabelNode.text,Attribute(LinkNode,'src'),Depth);
          ReadList(Child,True,Depth+1);
        end
        else
        begin
          if LocalName(Child)<>'li' then Continue;
          LinkNode:=DirectChild(Child,'a');
          if LinkNode<>nil then AddEntry(LinkNode.text,Attribute(LinkNode,'href'),Depth,
            Attribute(LinkNode,'data-homelib-start-only')='1');
          Nested:=DirectChild(Child,'ol'); if Nested<>nil then ReadList(Nested,False,Depth+1);
        end;
      end;
    end;
    function FindToc(const N:IXMLDOMNode; Depth:Integer=0):IXMLDOMNode;
    var K:Integer;
    begin
      Check; Result:=nil; if (N=nil) or (Depth>128) then Exit;
      if (LocalName(N)='nav') and
        (TRegEx.IsMatch(Attribute(N,'type'),'(^|\s)toc(\s|$)') or (Attribute(N,'role')='doc-toc')) then Exit(N);
      for K:=0 to N.childNodes.length-1 do
      begin Result:=FindToc(N.childNodes.item[K],Depth+1); if Result<>nil then Exit; end;
    end;
    procedure ReadNavigation(const Href:string; NCX:Boolean);
    begin
      Entries.Clear; PageEntries:=0; RootEntry:=False; KfxFallback:=False;
      try
        CurrentPath:=ZipPath(PackagePath,Href); ReadZip(CurrentPath,Bytes);
        Navigation:=XMLDocument(Bytes,rteAutomatic,nil,Warnings);
        if NCX then TocNode:=DirectChild(Navigation.documentElement,'navmap')
        else TocNode:=DirectChild(FindToc(Navigation.documentElement),'ol');
        ReadList(TocNode,NCX,0);
      except
        on Error:EAbort do raise;
        on Error:EMHLComponentRequired do raise;
        on Error:Exception do
        begin
          Entries.Clear;
          if Warnings.Count<20 then Warnings.Add('Оглавление EPUB: '+Error.Message+' Заголовки из текста сохранены.');
        end;
      end;
    end;
  begin
    // A recovered scan contains an EPUB-required start link, not a publisher's outline.
    if Attribute(Root,'unique-identifier')='recovered-id' then Exit;
    SavedPath:=CurrentPath; Entries:=TList<TReaderChapter>.Create;
    try
      OwnEpub:=IsPreparedEpub; PageEntries:=0; RootEntry:=False; KfxFallback:=False;
      OwnFb2Epub:=(PackagePath='OEBPS/package.opf') and
        Attribute(Root,'prefix').Contains('mhl: https://github.com/Dicur3x/MyHomeLib/conversion/') and
        Assigned(Root.selectSingleNode('./*[local-name()="metadata"]/*[local-name()="meta" and @property="mhl:fb2-description"]'));
      OwnKfxView:=(PackagePath='OEBPS/content.opf') and
        ExtractFileName(FileName).StartsWith(KFX_READER_CACHE_PREFIX,True) and
        not SameText(BookCacheSource(FileName),FileName);
      // Publisher navigation is authoritative, including chapters without h1-h6.
      // Resolve only anchors already encountered in the actual reading spine.
      for J:=0 to Manifest.childNodes.length-1 do
      begin
        Entry:=Manifest.childNodes.item[J];
        if (LocalName(Entry)<>'item') or not TRegEx.IsMatch(Attribute(Entry,'properties'),'(^|\s)nav(\s|$)') then Continue;
        ReadNavigation(Attribute(Entry,'href'),False); if Entries.Count>0 then Break;
      end;
      if Entries.Count=0 then
      begin
        NcxID:=Attribute(Spine,'toc');
        if (NcxID<>'') and Paths.TryGetValue(NcxID,Resource) then ReadNavigation(Resource,True);
      end;
      if OwnKfxView and ((Entries.Count=0) or ((Entries.Count=1) and KfxFallback)) then
      begin
        FChapters.Clear;
        Exit;
      end;
      if Entries.Count>0 then
      begin
        // BookProcessing supplies a mandatory link to the document start when
        // the text has no headings. Its page and slide labels are also navigation aids.
        if (Entries.Count=1) and RootEntry then Exit;
        if PageEntries=Entries.Count then
        begin
          for ChapterIndex:=FChapters.Count-1 downto 0 do
            if PageLabel(FChapters[ChapterIndex].Title) then FChapters.Delete(ChapterIndex);
          Exit;
        end;
        // Keep the publisher's order and nesting even when entries share a
        // destination or point to chapters out of reading order.
        FChapters.Clear; FChapters.AddRange(Entries);
      end;
    finally CurrentPath:=SavedPath; Entries.Free; end;
  end;
  procedure LoadCSS(const N: IXMLDOMNode; Depth: Integer = 0);
  var Index: Integer; Name, Path, Text: string; Bytes: TBytes; Child: IXMLDOMNode;
    procedure CollectSheet(const Text, Base: string);
    var Sheet: TEpubStyleSheet;
    begin
      Sheet.Text:=Text; Sheet.Base:=Base;
      Sheet.ListImages:=MatchText(Attribute(N,'media').Trim,['','all','screen']);
      RequestedEpubStyles.Add(Sheet);
    end;
  begin
    Check; if (N=nil) or (Depth>32) then Exit;
    Name:=LocalName(N);
    if MatchText(Name,['style','link']) and
      (not MatchText(Attribute(N,'media').Trim,['','all','screen']) or
      not MatchText(Attribute(N,'type').Trim,['','text/css'])) then EpubStylesAvailable:=False;
    if Name='style' then CollectSheet(N.text,CurrentPath)
    else if (Name='link') and LowerCase(Attribute(N,'rel')).Contains('stylesheet') then
    begin
      try
        Path:=ZipPath(CurrentPath,Attribute(N,'href'));
        if not CSSCache.TryGetValue(Path,Text) then
        begin
          Index:=Zip.IndexOf(Path);
          if (Index<0) or (Zip.FileInfo[Index].UncompressedSize>1024*1024) then
          begin
            EpubStylesAvailable:=False;
            Exit;
          end;
          ReadZip(Path,Bytes);
          Text:=ReaderDecodeText(Bytes).Replace(#12,#10);
          if TRegEx.IsMatch(Text,'[\x00-\x08\x0b\x0e-\x1f\x{fffe}\x{ffff}]') then
          begin
            if Warnings.Count<20 then Warnings.Add(ReaderEpubUnreadableStyleWarning+': «'+
              Copy(ExtractFileName(Path),1,100)+'». Показано доступное оформление.');
            Text:=#0;
          end;
          CSSCache.Add(Path,Text);
        end;
        if Text=#0 then
        begin
          EpubStylesAvailable:=False;
          Exit;
        end;
        CollectSheet(Text,Path);
      except
        on E: EAbort do raise;
        on Error: EMHLComponentRequired do raise;
        on Error: Exception do
        begin
          EpubStylesAvailable:=False;
          if Warnings.Count<20 then Warnings.Add('Оформление EPUB: '+Error.Message);
        end;
      end;
    end;
    Child:=N.firstChild;
    while Assigned(Child) do
    begin
      LoadCSS(Child,Depth+1);
      Child:=Child.nextSibling;
    end;
  end;
  procedure ReadEpubListMarker(const N: IXMLDOMNode);
  var Element: IXMLDOMNode; Base, Reference, Member: string; Bytes: TBytes;
  begin
    Element:=N;
    while Assigned(Element) do
    begin
      Reference:=CSS.ListImage(LocalName(Element),Attribute(Element,'class'),
        Attribute(Element,'id'),Attribute(Element,'style'),Base);
      if Reference<>'' then Break;
      Element:=Element.parentNode;
    end;
    if (Reference='') or (Reference=#0) then Exit;
    if Base='' then Base:=CurrentPath;
    Member:='';
    try
      if DecodeInlineImage(Reference,Bytes) then
        Picture(Bytes,False,'','',False,0,0,0,True)
      else
      begin
        Member:=ZipPath(Base,Reference);
        if not ListMarkerBytes.TryGetValue(Member,Bytes) then
        begin
          ReadZip(Member,Bytes);
          ListMarkerBytes.Add(Member,Bytes);
        end;
        if Length(Bytes)=0 then Exit;
        Picture(Bytes,False,'','',False,0,0,0,True);
      end;
      AddText(' ');
    except
      on E: EAbort do raise;
      on E: EMHLComponentRequired do raise;
      on E: Exception do
      begin
        if Member<>'' then ListMarkerBytes.AddOrSetValue(Member,nil);
        NoteUnreadableImage('Маркер списка EPUB «'+Copy(Reference,1,120)+'» недоступен. '+E.Message);
      end;
    end;
  end;
  procedure ApplyEpubStyles(const Head: IXMLDOMNode);
  var Previous, Current: TEpubStyleSheet; SameRules: Boolean; Buffer: TList<TEpubStyleSheet>;
  begin
    EpubStylesAvailable:=True;
    RequestedEpubStyles.Clear;
    LoadCSS(Head);
    SameRules:=RequestedEpubStyles.Count=LoadedEpubStyles.Count;
    if SameRules then
      for var Index:=0 to RequestedEpubStyles.Count-1 do
      begin
        Current:=RequestedEpubStyles[Index]; Previous:=LoadedEpubStyles[Index];
        if (Current.Base<>Previous.Base) or (Current.Text<>Previous.Text) or
          (Current.ListImages<>Previous.ListImages) then
        begin
          SameRules:=False;
          Break;
        end;
      end;
    if SameRules then Exit;
    CSS.Clear;
    for Current in RequestedEpubStyles do CSS.Add(Current.Text,Current.Base,Current.ListImages);
    Buffer:=LoadedEpubStyles;
    LoadedEpubStyles:=RequestedEpubStyles;
    RequestedEpubStyles:=Buffer;
  end;

  function IsEbookWordCanvas(const N: IXMLDOMNode): Boolean;
  const Style = 'homelibre-word-canvas';
  begin
    Result:=False;
    if not MatchStr(E,['.epub','.fb2']) then Exit;
    if (E='.epub') and MatchStr(Style,Attribute(N,'class').Split([' ',#9,#10,#13])) then Exit(True);
    var Host:=N.parentNode;
    while Assigned(Host) and MatchStr(LocalName(Host),['style','span','a']) do
    begin
      if ((E='.fb2') and (Attribute(Host,'name')=Style)) or
        ((E='.epub') and MatchStr(Style,Attribute(Host,'class').Split([' ',#9,#10,#13]))) then Exit(True);
      Host:=Host.parentNode;
    end;
  end;
  function InlineEbookPicture(const N: IXMLDOMNode; const Bytes: TBytes;
    DisplayWidth, DisplayHeight: Integer): Boolean;
  const
    MarkerStyle = 'homelibre-list-marker';
    MaxInlineIconPixels = 96;
  var Host: IXMLDOMNode; Name: string; Width, Height: Integer; Stream: TBytesStream;
  begin
    Result:=False;
    if not MatchText(E,['.epub','.fb2']) then Exit;
    Host:=N.parentNode;
    if Host=nil then Exit;
    if (E='.fb2') and (LocalName(Host)='style') and (Attribute(Host,'name')=MarkerStyle) then Exit(True);
    if (E='.epub') and (LocalName(Host)='span') and
      MatchStr(MarkerStyle,Attribute(Host,'class').Split([' ',#9,#10,#13])) then Exit(True);
    if E='.epub' then
    begin
      var Classes:=Attribute(N,'class').Split([' ',#9,#10,#13]);
      if MatchStr(MarkerStyle,Classes) then Exit(True);
    end;
    if TRegEx.IsMatch(Attribute(N,'style'),'(?:^|;)\s*display\s*:\s*block\b',[roIgnoreCase]) then Exit;
    while Assigned(Host) do
    begin
      Name:=LocalName(Host);
      if ((E='.fb2') and (Name='p')) or ((E='.epub') and
        ((Name='li') or ((Name='p') and (Attribute(Host,'data-fb2')='p')))) then Break;
      if not MatchText(Name,['p','span','style','a','em','emphasis','i','strong','b','small','sub','sup','code']) then Exit;
      Host:=Host.parentNode;
    end;
    if Host=nil then Exit;
    Stream:=TBytesStream.Create(Bytes);
    try
      if not ImageDimensions(Stream,Width,Height) then Exit;
    finally Stream.Free; end;
    if (DisplayWidth>0) and (DisplayHeight=0) then DisplayHeight:=MulDiv(DisplayWidth,Height,Width)
    else if (DisplayHeight>0) and (DisplayWidth=0) then DisplayWidth:=MulDiv(DisplayHeight,Width,Height);
    if DisplayWidth>0 then Width:=DisplayWidth;
    if DisplayHeight>0 then Height:=DisplayHeight;
    Result:=(Width<=MaxInlineIconPixels) and (Height<=MaxInlineIconPixels);
  end;
  function NoteText(const N: IXMLDOMNode; Depth: Integer = 0): string;
  var J: Integer; Name: string;
  begin
    Check; Result:=''; if (N=nil) or (Depth>256) then Exit;
    Name:=LocalName(N);
    if (Name='script') or (Name='style') or (Name='binary') or (Name='img') or (Name='image') then Exit;
    if N.nodeType in [NODE_TEXT,NODE_CDATA_SECTION] then
      Exit(TRegEx.Replace(N.text,'[\r\n\t ]+',' '));
    for J:=0 to N.childNodes.length-1 do
    begin
      Result:=Result+NoteText(N.childNodes.item[J],Depth+1);
      if Length(Result)>65536 then begin Result:=Copy(Result,1,65536); Break; end;
    end;
    if (Name='p') or (Name='title') or (Name='br') or (Name='li') then Result:=Result+#13#10;
  end;
  procedure StoreNote(const Key, Text: string);
  begin
    if (Text='') or FNoteBodies.ContainsKey(Key) or (FNoteBodies.Count>=10000) or
      (Int64(NoteCharacters)+Length(Text)>4*1024*1024) then Exit;
    FNoteBodies.Add(Key,Text); Inc(NoteCharacters,Length(Text));
  end;
  procedure CollectNotes(const N: IXMLDOMNode; const Prefix: string; FB2Notes: Boolean; Depth: Integer = 0);
  var Child: IXMLDOMNode; Name,Key,Kind,Text: string;
  begin
    Check; if (N=nil) or (Depth>256) then Exit;
    Name:=LocalName(N); Key:=Attribute(N,'id'); Kind:=LowerCase(Attribute(N,'type')+' '+Attribute(N,'role'));
    if (Key<>'') and ((FB2Notes and (Name='section')) or ((E='.fb3') and (Name='notebody')) or
      Kind.Contains('footnote') or Kind.Contains('endnote')) then
    begin
      Text:=Trim(NoteText(N));
      StoreNote(Prefix+Key,Text);
    end;
    Child:=N.firstChild;
    while Assigned(Child) do
    begin
      CollectNotes(Child,Prefix,FB2Notes,Depth+1);
      Child:=Child.nextSibling;
    end;
  end;
  function NodeWithID(const N: IXMLDOMNode; const ID: string; Depth: Integer = 0): IXMLDOMNode;
  var J: Integer;
  begin
    Check; Result:=nil; if (N=nil) or (Depth>256) then Exit;
    if Attribute(N,'id')=ID then Exit(N);
    for J:=0 to N.childNodes.length-1 do
    begin Result:=NodeWithID(N.childNodes.item[J],ID,Depth+1); if Assigned(Result) then Exit; end;
  end;
  function UnmarkedHeading(const N: IXMLDOMNode): Boolean;
  var Text: string; C: Char; Letters: Integer;
  begin
    Result:=False;
    // Some FB2 files use a short all-caps paragraph instead of <subtitle>.
    // Restrict inference to direct prose section paragraphs, not poems, quotes,
    // inline-marked paragraphs, long prose or sentences ending in punctuation.
    if (E<>'.fb2') or (LocalName(N)<>'p') or (N.parentNode=nil) or
      (LocalName(N.parentNode)<>'section') or (N.childNodes.length<>1) or
      not (N.childNodes.item[0].nodeType in [NODE_TEXT,NODE_CDATA_SECTION]) then Exit;
    Text:=Trim(N.text);
    if (Length(Text)<6) or (Length(Text)>100) then Exit;
    if CharInSet(Text[Length(Text)],['.','!','?',';',',',':']) then Exit;
    Letters:=0;
    for C in Text do
      if C.IsLetter then
      begin if not C.IsUpper then Exit; Inc(Letters); end
      else if not C.IsDigit and not C.IsWhiteSpace and not CharInSet(C,['-',':','.', '(',')']) then Exit;
    Result:=Letters>=6;
  end;
  function HeadingText(const N: IXMLDOMNode): string;
  var Child: IXMLDOMNode; J: Integer; Part: string; Block: Boolean;
  begin
    // DOM .text concatenates adjacent FB2 paragraphs without separators in
    // minified books: <p>1</p><p>Бекас</p> becomes "1Бекас". Preserve inline
    // emphasis and only introduce boundaries for actual block elements.
    if N.nodeType in [NODE_TEXT,NODE_CDATA_SECTION] then Exit(N.text);
    if (E='.docx') and (LocalName(N)='r') and WordRunHidden(N) then Exit('');
    Result:='';
    for J:=0 to N.childNodes.length-1 do
    begin
      Child:=N.childNodes.item[J]; Part:=HeadingText(Child);
      Block:=MatchText(LocalName(Child),['p','br','empty-line','div']);
      if Block and (Result<>'') then Result:=Result+' ';
      Result:=Result+Part;
      if Block then Result:=Result+' ';
    end;
  end;
  const
    WordCompatibilityNamespace = 'http://schemas.openxmlformats.org/markup-compatibility/2006';
    WordGroupNamespace = 'http://schemas.microsoft.com/office/word/2010/wordprocessingGroup';
    WordShapeNamespace = 'http://schemas.microsoft.com/office/word/2010/wordprocessingShape';
    WordCanvasNamespace = 'http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas';
    WordPlacementNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
    WordNamespace = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    WordDrawingNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/main';
    VMLNamespace = 'urn:schemas-microsoft-com:vml';
    WordVmlTextBoxQuery = '*[local-name()="shape" and namespace-uri()="'+VMLNamespace+'" '+
      'and @type="#_x0000_t202" and *[local-name()="textbox" and namespace-uri()="'+VMLNamespace+'"]]';
    WordVmlInlineOvalQuery = '*[local-name()="oval" and namespace-uri()="'+VMLNamespace+'" and count(../*)=1]';
    WordCanvasQuery = '*[local-name()="drawing" and namespace-uri()="'+WordNamespace+'"]/'+
      '*[local-name()="inline" and namespace-uri()="'+WordPlacementNamespace+'"]/'+
      '*[local-name()="graphic" and namespace-uri()="'+WordDrawingNamespace+'"]/'+
      '*[local-name()="graphicData" and namespace-uri()="'+WordDrawingNamespace+'"]/'+
      '*[local-name()="wpc" and namespace-uri()="'+WordCanvasNamespace+'"]';
  function WordCanvasInline(const Node: IXMLDOMNode): IXMLDOMNode;
  begin
    Result:=nil;
    if (LocalName(Node)<>'wpc') or (VarToStr(Node.namespaceURI)<>WordCanvasNamespace) then Exit;
    var Frame:=Node.selectSingleNode('parent::*/parent::*/parent::*[local-name()="inline" and namespace-uri()="'+WordPlacementNamespace+'"]');
    if Assigned(Frame) and Assigned(DirectChild(Frame,'extent')) then Result:=Frame;
  end;
  function WordFigureSource(const Node: IXMLDOMNode): string;
  begin
    Result:=Node.xml;
    var Frame:=WordCanvasInline(Node);
    if Frame=nil then Exit;
    Result:=Result+DirectChild(Frame,'extent').xml;
    var Effects:=DirectChild(Frame,'effectextent');
    if Effects<>nil then Result:=Result+Effects.xml;
  end;
  function WordDrawingSpacer(const Drawing: IXMLDOMNode; out Width, Height: Integer): Boolean;
  const HiddenNamespace = 'http://schemas.microsoft.com/office/drawing/2010/main';
  var Placement, Extent, Effects, Description, Graphic, Data, Shape, Properties, Stroke, Stored, Child: IXMLDOMNode;
    Nodes: IXMLDOMNodeList; WidthEMU, HeightEMU: Integer; Distance: string;
    function ChildOf(const Parent: IXMLDOMNode; const Name, Namespace: string): IXMLDOMNode;
    begin
      Result:=nil;
      if Parent<>nil then Result:=Parent.selectSingleNode('*[local-name()="'+Name+'" and namespace-uri()="'+Namespace+'"]');
    end;
    function OnlyChildren(const Parent: IXMLDOMNode; const Names: array of string; const Namespace: string): Boolean;
    var Children: IXMLDOMNodeList;
    begin
      Result:=False;
      if Parent=nil then Exit;
      Children:=Parent.selectNodes('./*');
      for var I:=0 to Children.length-1 do
      begin
        var Element:=Children.item[I];
        if (VarToStr(Element.namespaceURI)<>Namespace) or not MatchText(LocalName(Element),Names) then Exit;
      end;
      Result:=True;
    end;
  begin
    Result:=False;
    if (Drawing=nil) or (Drawing.selectNodes('./*').length<>1) then Exit;
    Placement:=ChildOf(Drawing,'inline',WordPlacementNamespace);
    if Placement=nil then Exit;
    for var Side in ['T','B','L','R'] do
    begin
      Distance:=Attribute(Placement,'dist'+Side);
      if (Distance<>'') and (Distance<>'0') then Exit;
    end;
    Extent:=ChildOf(Placement,'extent',WordPlacementNamespace);
    if Extent=nil then Exit;
    Effects:=ChildOf(Placement,'effectExtent',WordPlacementNamespace);
    if Effects<>nil then
      for var I:=0 to Effects.attributes.length-1 do
        if VarToStr(Effects.attributes.item[I].nodeValue)<>'0' then Exit;
    Description:=ChildOf(Placement,'docPr',WordPlacementNamespace);
    if (Description<>nil) and (Description.selectNodes('./*').length<>0) then Exit;
    Graphic:=ChildOf(Placement,'graphic',WordDrawingNamespace);
    if (Graphic=nil) or (Graphic.selectNodes('./*').length<>1) then Exit;
    Nodes:=Placement.selectNodes('./*');
    for var I:=0 to Nodes.length-1 do
    begin
      Child:=Nodes.item[I];
      if (LocalName(Child)='graphic') and (VarToStr(Child.namespaceURI)=WordDrawingNamespace) then Continue;
      if (VarToStr(Child.namespaceURI)<>WordPlacementNamespace) or
        not MatchText(LocalName(Child),['extent','effectextent','docpr','cnvgraphicframepr']) then Exit;
    end;
    Data:=ChildOf(Graphic,'graphicData',WordDrawingNamespace);
    if (Data=nil) or (Attribute(Data,'uri')<>WordShapeNamespace) or (Data.selectNodes('./*').length<>1) then Exit;
    Shape:=ChildOf(Data,'wsp',WordShapeNamespace);
    if not OnlyChildren(Shape,['cnvsppr','sppr','bodypr'],WordShapeNamespace) then Exit;
    Properties:=ChildOf(Shape,'spPr',WordShapeNamespace);
    if not OnlyChildren(Properties,['xfrm','prstgeom','nofill','ln','extlst'],WordDrawingNamespace) then Exit;
    Child:=ChildOf(Properties,'prstGeom',WordDrawingNamespace);
    if (Child=nil) or (Attribute(Child,'prst')<>'rect') or (ChildOf(Properties,'noFill',WordDrawingNamespace)=nil) then Exit;
    Stroke:=ChildOf(Properties,'ln',WordDrawingNamespace);
    if (Stroke=nil) or (Stroke.selectNodes('./*').length<>1) or (ChildOf(Stroke,'noFill',WordDrawingNamespace)=nil) then Exit;
    Stored:=ChildOf(Properties,'extLst',WordDrawingNamespace);
    if Stored<>nil then
    begin
      if not OnlyChildren(Stored,['ext'],WordDrawingNamespace) then Exit;
      Nodes:=Stored.selectNodes('./*');
      for var I:=0 to Nodes.length-1 do
      begin
        Child:=Nodes.item[I];
        if (Child.selectNodes('./*').length<>1) or not OnlyChildren(Child,['hiddenfill','hiddenline'],HiddenNamespace) then Exit;
      end;
    end;
    if not TryStrToInt(Attribute(Extent,'cx'),WidthEMU) or not TryStrToInt(Attribute(Extent,'cy'),HeightEMU) or
      (WidthEMU<6350) or (WidthEMU>9144000) or (HeightEMU<6350) or (HeightEMU>9144000) then Exit;
    Width:=MulDiv(WidthEMU,1,635); Height:=MulDiv(HeightEMU,1,635);
    Result:=True;
  end;
  function WordCompatibilityBranch(const Container: IXMLDOMNode): IXMLDOMNode;
  var Branch, Fallback, Spacer, Rectangle: IXMLDOMNode; BestScore, Score, Width, Height: Integer;
    function Rank(const Node: IXMLDOMNode; Depth: Integer): Integer;
    var Name, Ref, Member: string; Child: IXMLDOMNode;
    begin
      Check;
      if Depth>256 then raise Exception.Create('Слишком глубокая разметка книги.');
      Name:=LocalName(Node);
      if MatchText(Name,['blip','imagedata']) then
      begin
        Ref:=Attribute(Node,'embed');
        if Ref='' then Ref:=Attribute(Node,'id');
        if (Ref<>'') and Paths.TryGetValue(Ref,Member) and (Zip.IndexOf(Member)>=0) then Exit(2);
      end;
      Result:=0;
      if MatchText(Name,['t','tbl']) and SameText(VarToStr(Node.namespaceURI),WordNamespace) and
        ((Name='tbl') or (Trim(Node.text)<>'')) then Result:=1;
      Child:=Node.firstChild;
      while Assigned(Child) do
      begin
        if Child.nodeType=NODE_ELEMENT then
        begin
          Result:=Max(Result,Rank(Child,Depth+1));
          if Result=2 then Exit;
        end;
        Child:=Child.nextSibling;
      end;
    end;
  begin
    Result:=nil; Fallback:=nil; Spacer:=nil; BestScore:=-1;
    Branch:=Container.firstChild;
    while Assigned(Branch) do
    begin
      if (Branch.nodeType=NODE_ELEMENT) and SameText(VarToStr(Branch.namespaceURI),WordCompatibilityNamespace) then
      begin
        if LocalName(Branch)='fallback' then Fallback:=Branch;
        if MatchText(LocalName(Branch),['choice','fallback']) then
        begin
          if (LocalName(Branch)='choice') and Assigned(WordRenderedDrawings) and
            (Branch.selectNodes('./*').length=1) then
          begin
            var Canvas:=Branch.selectSingleNode(WordCanvasQuery);
            if (Canvas<>nil) and WordRenderedDrawings.ContainsKey(THashSHA2.GetHashString(WordFigureSource(Canvas))) then
              Exit(Branch);
          end;
          if (Spacer=nil) and (LocalName(Branch)='choice') and (Branch.selectNodes('./*').length=1) and
            WordDrawingSpacer(Branch.selectSingleNode('*[local-name()="drawing" and namespace-uri()="'+WordNamespace+'"]'),
              Width,Height) then Spacer:=Branch;
          Score:=Rank(Branch,0);
          if Score>BestScore then begin BestScore:=Score; Result:=Branch; end;
          if Score=2 then Exit;
        end;
      end;
      Branch:=Branch.nextSibling;
    end;
    if BestScore<>0 then Exit;
    if Assigned(Fallback) then
    begin
      Result:=Fallback;
      if Spacer=nil then Exit;
      Rectangle:=Fallback.selectSingleNode('*[local-name()="pict" and namespace-uri()="'+WordNamespace+
        '" and count(../*)=1]/*[local-name()="rect" and namespace-uri()="'+VMLNamespace+'" and count(../*)=1]');
      if (Rectangle=nil) or not MatchText(Attribute(Rectangle,'filled'),['f','false','0']) or
        not MatchText(Attribute(Rectangle,'stroked'),['f','false','0']) or Assigned(Rectangle.selectSingleNode(
          '*[not((local-name()="lock" and namespace-uri()="urn:schemas-microsoft-com:office:office") or '+
          '(local-name()="anchorlock" and namespace-uri()="urn:schemas-microsoft-com:office:word"))]')) then Exit;
    end;
    if Spacer<>nil then Result:=Spacer;
  end;
  function WordStandaloneShape(const Node: IXMLDOMNode): Boolean;
  var Parent: IXMLDOMNode;
  begin
    Result:=False;
    if (LocalName(Node)<>'wsp') or (VarToStr(Node.namespaceURI)<>WordShapeNamespace) then Exit;
    Parent:=Node.parentNode;
    if not Assigned(Parent) or (LocalName(Parent)<>'graphicdata') or
      (VarToStr(Parent.namespaceURI)<>WordDrawingNamespace) then Exit;
    Result:=Assigned(Node.selectSingleNode(
      '*[local-name()="txbx" and namespace-uri()="'+WordShapeNamespace+'"]'));
  end;
  function WordVmlTextBox(const Node: IXMLDOMNode): IXMLDOMNode;
  begin
    Result:=nil;
    if (LocalName(Node)='pict') and (VarToStr(Node.namespaceURI)=WordNamespace) then
      Result:=Node.selectSingleNode(WordVmlTextBoxQuery);
  end;
  function EmptyFloatingWordBox(const Picture, Shape: IXMLDOMNode): Boolean;
  var Box, Content, PropertyNode: IXMLDOMNode; Attributes: IXMLDOMNamedNodeMap;
    function BlankContent(const Node: IXMLDOMNode; Depth: Integer): Boolean;
    var Name: string; Child: IXMLDOMNode;
    begin
      if Node.nodeType in [NODE_TEXT,NODE_CDATA_SECTION] then Exit(Trim(Node.text)='');
      if (Depth>32) or (Node.nodeType<>NODE_ELEMENT) or
        (VarToStr(Node.namespaceURI)<>WordNamespace) then Exit(False);
      Name:=LocalName(Node);
      if MatchText(Name,['ppr','rpr']) then
        Exit(not Assigned(Node.selectSingleNode(
          './/*[local-name()="pBdr" or local-name()="shd" or local-name()="bdr" or local-name()="numPr"]')));
      if not MatchText(Name,['txbxcontent','p','r','t']) then Exit(False);
      Child:=Node.firstChild;
      while Assigned(Child) do
      begin
        if not BlankContent(Child,Depth+1) then Exit(False);
        Child:=Child.nextSibling;
      end;
      Result:=True;
    end;
  begin
    Result:=False;
    if not Assigned(Shape) or not MatchText(Attribute(Shape,'filled'),['f','false','0']) or
      not MatchText(Attribute(Shape,'stroked'),['f','false','0']) or
      not TRegEx.IsMatch(Attribute(Shape,'style'),'(?:^|;)s*positions*:s*absolutes*(?:;|$)',[roIgnoreCase]) then Exit;
    if Assigned(Picture.selectSingleNode('*[not(namespace-uri()="'+VMLNamespace+
      '" and (local-name()="shapetype" or local-name()="shape"))]')) or
      (Picture.selectNodes('*[local-name()="shape"]').length<>1) then Exit;
    if Assigned(Shape.selectSingleNode('*[not((local-name()="textbox" and namespace-uri()="'+VMLNamespace+
      '") or (local-name()="wrap" and namespace-uri()="urn:schemas-microsoft-com:office:word"))]')) then Exit;
    Box:=Shape.selectSingleNode('*[local-name()="textbox" and namespace-uri()="'+VMLNamespace+'"]');
    if not Assigned(Box) or (Shape.selectNodes('*[local-name()="textbox"]').length<>1) then Exit;
    Attributes:=Box.attributes;
    for var Index:=0 to Attributes.length-1 do
    begin
      PropertyNode:=Attributes.item[Index];
      if (VarToStr(PropertyNode.namespaceURI)<>'http://www.w3.org/2000/xmlns/') and
        (PropertyNode.nodeName<>'inset') then Exit;
    end;
    Content:=Box.selectSingleNode('*[local-name()="txbxContent" and namespace-uri()="'+WordNamespace+'"]');
    Result:=Assigned(Content) and (Box.selectNodes('*').length=1) and BlankContent(Content,0);
  end;
  function WordDrawingCaption(const Group: IXMLDOMNode): string; forward;
  function PrepareWordDrawings(const Body: IXMLDOMNode; PagePreview: Boolean = False): Boolean;
  const RequestLimit = 16*1024*1024; MaxBatch = 128;
    SceneLimit = 1024*1024; MaxSceneParagraphs = 32;
    WordRunPath = './*[local-name()="r" and namespace-uri()="'+WordNamespace+'"]';
    WordDrawingPath = '*[local-name()="drawing" and namespace-uri()="'+WordNamespace+'"]';
    WordModernPath = '*[local-name()="AlternateContent" and namespace-uri()="'+WordCompatibilityNamespace+
      '"]/*[local-name()="Choice" and namespace-uri()="'+WordCompatibilityNamespace+'"]';
    WordAnchorPath = '/*[local-name()="anchor" and namespace-uri()="'+WordPlacementNamespace+'"]';
    WordAnchorQuery = WordRunPath+'/'+WordDrawingPath+WordAnchorPath+' | '+
      WordRunPath+'/'+WordModernPath+'/'+WordDrawingPath+WordAnchorPath;
    ExcludeDrawingFallback = ' and not(ancestor::*[local-name()="Fallback" and namespace-uri()="'+
      WordCompatibilityNamespace+'"])';
  var Groups: IXMLDOMNodeList; Group, Part: IXMLDOMNode;
    Tool, Prefix, Source: string; XML: TStringBuilder;
    Keys: TList<string>; Pictures: TArray<TBytes>; PrefixBytes, RequestBytes: Integer;
    function ReadPart(const Member: string): IXMLDOMNode;
    var PartData: TBytes; Doc: IXMLDOMDocument3;
    begin
      Result:=nil;
      if Zip.IndexOf(Member)<0 then Exit;
      try
        ReadZip(Member,PartData); Doc:=XMLDocument(PartData); Result:=Doc.documentElement;
      except
        on Error: EAbort do raise;
        on Error: Exception do ; // An unavailable optional part leaves the original figure fallback.
      end;
    end;
    function FigureRequest(const Group: IXMLDOMNode; const Source: string; Floating: Boolean = False): string;
    var Blips: IXMLDOMNodeList; Blip: IXMLDOMNode; Id, Member: string;
      Seen: TStringList; Image: TBytes; PartIndex, Remaining: Integer; Request: TStringBuilder;
    begin
      Result:='';
      if Floating then
        Blips:=Group.selectNodes('.//*[local-name()="blip" and namespace-uri()="'+WordDrawingNamespace+'"'+
          ExcludeDrawingFallback+'] | .//*[local-name()="imagedata" and namespace-uri()="'+VMLNamespace+'"'+ExcludeDrawingFallback+']')
      else
        Blips:=Group.selectNodes('.//*[local-name()="blip" and namespace-uri()="'+WordDrawingNamespace+'"] | '+
          './/*[local-name()="imagedata" and namespace-uri()="'+VMLNamespace+'"]');
      if not Assigned(Blips) or (Blips.length=0) then Exit('<figure>'+Source+'</figure>');
      Remaining:=3*1024*1024;
      Seen:=TStringList.Create; Request:=TStringBuilder.Create('<figure>');
      try
        Seen.CaseSensitive:=True; Request.Append(Source);
        Blip:=Blips.nextNode;
        while Assigned(Blip) do
        begin
          Check;
          if LocalName(Blip)='imagedata' then Id:=Attribute(Blip,'id') else Id:=Attribute(Blip,'embed');
          if Id='' then Exit;
          if Seen.IndexOf(Id)<0 then
          begin
            if not Paths.TryGetValue(Id,Member) then Exit;
            PartIndex:=Zip.IndexOf(Member);
            if (PartIndex<0) or (Zip.FileInfo[PartIndex].UncompressedSize>Remaining) then Exit;
            try ReadZip(Member,Image);
            except
              on E: EAbort do raise;
              on E: Exception do Exit;
            end;
            if (Length(Image)<8) or not (((Image[0]=$89) and (Image[1]=Ord('P')) and
              (Image[2]=Ord('N')) and (Image[3]=Ord('G'))) or
              ((Image[0]=$FF) and (Image[1]=$D8) and (Image[2]=$FF)) or
              ((Length(Image)>=44) and (Image[0]=1) and (Image[1]=0) and (Image[2]=0) and (Image[3]=0) and
               (Image[40]=$20) and (Image[41]=Ord('E')) and (Image[42]=Ord('M')) and (Image[43]=Ord('F')))) then Exit;
            Dec(Remaining,Length(Image)); Seen.Add(Id);
            Request.Append('<asset id="').Append(Id.Replace('&','&amp;').Replace('"','&quot;').Replace('<','&lt;'))
              .Append('">').Append(TNetEncoding.Base64.EncodeBytesToString(Image)).Append('</asset>');
          end;
          Blip:=Blips.nextNode;
        end;
        Result:=Request.Append('</figure>').ToString;
      finally Request.Free; Seen.Free; end;
    end;
    procedure RenderBatch;
    begin
      if Keys.Count=0 then Exit;
      XML.Append('</figures>');
      LogDiagnosticTrace('word-drawings','Отправлено групп: '+IntToStr(Keys.Count),'DOCX');
      Pictures:=RenderWordDrawingBatch(Tool,TEncoding.UTF8.GetBytes(XML.ToString),Keys.Count,Canceled);
      for var Index:=0 to High(Pictures) do
        if (Length(Pictures[Index])>0) and (Length(Pictures[Index])<=UnpackedLimit-UnpackedBytes) then
        begin
          WordRenderedDrawings.AddOrSetValue(Keys[Index],Pictures[Index]);
          Inc(UnpackedBytes,Length(Pictures[Index]));
        end;
      Pictures:=nil; Keys.Clear; XML.Clear; XML.Append(Prefix); RequestBytes:=PrefixBytes;
    end;
    function QueueFigure(const Source, Figure: string): string;
    var Size: Integer;
    begin
      Result:='';
      Size:=TEncoding.UTF8.GetByteCount(Figure);
      if (Size=0) or (Size>RequestLimit-PrefixBytes) then Exit;
      Result:=THashSHA2.GetHashString(Source);
      if WordRenderedDrawings.ContainsKey(Result) or Keys.Contains(Result) then Exit;
      if (Keys.Count>=MaxBatch) or (Size>RequestLimit-RequestBytes) then RenderBatch;
      XML.Append(Figure); Keys.Add(Result); Inc(RequestBytes,Size);
    end;
    procedure PrepareFloating;
    var Paragraphs: TStringBuilder; Caption: TStringList; Anchors: IXMLDOMNodeList;
      Child, Anchor, Drawing: IXMLDOMNode; ParagraphXML, LabelText: string;
      Index, First, Last, LastLength, ParagraphCount, AnchorCount: Integer;
      procedure Flush;
      var Raw: string; Candidate: IXMLDOMDocument3; Layout: TWordFloatingDrawing;
      begin
        if AnchorCount>=2 then
        begin
          Raw:='<floating>'+Copy(Paragraphs.ToString,1,LastLength)+'</floating>';
          try
            Candidate:=XMLDocument(TEncoding.UTF8.GetBytes(Raw));
            Layout.Key:=QueueFigure(Raw,FigureRequest(Candidate.documentElement,Raw,True));
            if Layout.Key<>'' then
            begin
              Layout.LastBlock:=Last;
              Layout.Caption:=Trim(Caption.Text);
              Layout.Legend:=False;
              WordFloatingDrawings.Add(First,Layout);
            end;
          except
            on E: EAbort do raise;
            on E: Exception do ; // Preserve the original paragraphs when a diagram cannot be prepared.
          end;
        end;
        Paragraphs.Clear; Caption.Clear;
        First:=0; Last:=0; LastLength:=0; ParagraphCount:=0; AnchorCount:=0;
      end;
      function FloatingParagraph(const Node: IXMLDOMNode): Boolean;
      begin
        Result:=(LocalName(Node)='p') and (VarToStr(Node.namespaceURI)=WordNamespace) and
          not Assigned(Node.selectSingleNode('./*[not(namespace-uri()="'+WordNamespace+
          '" and (local-name()="pPr" or local-name()="r"))] | '+WordRunPath+'/*[not('+
          '(namespace-uri()="'+WordNamespace+'" and (local-name()="rPr" or local-name()="tab" or '+
          'local-name()="drawing" or local-name()="lastRenderedPageBreak" or (local-name()="t" and normalize-space(.)=""))) or '+
          '(namespace-uri()="'+WordCompatibilityNamespace+'" and local-name()="AlternateContent"))]'));
      end;
      function QueueLegend(const Node: IXMLDOMNode): Boolean;
      var Labels, MarkerAnchors: IXMLDOMNodeList; Layout: TWordFloatingDrawing;
        Raw, Source: string; Previous: Boolean;
      begin
        Result:=False;
        if (LocalName(Node)<>'p') or (VarToStr(Node.namespaceURI)<>WordNamespace) then Exit;
        Labels:=Node.selectNodes(WordRunPath+'/*[local-name()="t" and namespace-uri()="'+WordNamespace+'"]');
        if (Labels.length<>1) or not TRegEx.IsMatch(Labels.item[0].text,'^ {2,24}[-–—] ') then Exit;
        MarkerAnchors:=Node.selectNodes(WordAnchorQuery);
        Previous:=(MarkerAnchors.length=0) and (AnchorCount=1) and (First=Index-1) and (Last=First);
        if (MarkerAnchors.length<>1) and not Previous then Exit;
        Source:=Node.xml;
        if Previous then Source:=Paragraphs.ToString+Source;
        if Length(Source)>SceneLimit then Exit;
        Raw:='<legend>'+Source+'</legend>';
        Layout.Key:=QueueFigure(Raw,'<figure>'+Raw+'</figure>');
        if Layout.Key='' then Exit;
        Layout.LastBlock:=Index;
        Layout.Caption:='';
        Layout.Legend:=True;
        Flush;
        WordFloatingDrawings.Add(Index-Ord(Previous),Layout);
        Result:=True;
      end;
    begin
      WordFloatingDrawings:=TDictionary<Integer,TWordFloatingDrawing>.Create;
      Paragraphs:=TStringBuilder.Create; Caption:=TStringList.Create;
      try
        Index:=0; First:=0; Last:=0; LastLength:=0; ParagraphCount:=0; AnchorCount:=0;
        Child:=Body.firstChild;
        while Assigned(Child) do
        begin
          Check;
          if Child.nodeType=NODE_ELEMENT then
          begin
            Inc(Index);
            if QueueLegend(Child) then
            begin
              Child:=Child.nextSibling;
              Continue;
            end;
            if FloatingParagraph(Child) then
            begin
              Anchors:=Child.selectNodes(WordAnchorQuery);
              if (Anchors.length=0) and Assigned(Child.selectSingleNode(WordRunPath+'/'+WordDrawingPath+' | '+
                WordRunPath+'/*[local-name()="AlternateContent"]')) then Flush
              else if (Anchors.length>0) or (First<>0) then
              begin
                ParagraphXML:=Child.xml;
                if (ParagraphCount>=MaxSceneParagraphs) or (Paragraphs.Length+Length(ParagraphXML)>SceneLimit) then Flush;
                if (Length(ParagraphXML)<=SceneLimit) and ((Anchors.length>0) or (First<>0)) then
                begin
                  if First=0 then First:=Index;
                  Paragraphs.Append(ParagraphXML); Inc(ParagraphCount);
                  if Anchors.length>0 then
                  begin
                    Last:=Index; LastLength:=Paragraphs.Length; Inc(AnchorCount,Anchors.length);
                    Anchor:=Anchors.nextNode;
                    while Assigned(Anchor) do
                    begin
                      Drawing:=Anchor.selectSingleNode('.//*[local-name()="wsp" and namespace-uri()="'+WordShapeNamespace+'"]');
                      if Assigned(Drawing) then
                      begin
                        LabelText:=WordDrawingCaption(Drawing);
                        if LabelText<>'' then Caption.Add(LabelText);
                      end;
                      LabelText:=Trim(Attribute(DirectChild(Anchor,'docpr'),'descr'));
                      if LabelText<>'' then Caption.Add(LabelText);
                      Anchor:=Anchors.nextNode;
                    end;
                  end;
                end;
              end;
            end else Flush;
          end;
          Child:=Child.nextSibling;
        end;
        Flush;
      finally Caption.Free; Paragraphs.Free; end;
    end;
    function RenderPages: Boolean;
    var Anchors: IXMLDOMNodeList; Request: TBytes; Rendered: TArray<TBytes>; Node: IXMLDOMNode;
    begin
      Result:=False;
      var DocumentIndex:=Zip.IndexOf('word/document.xml');
      if (DocumentIndex<0) or (Zip.FileInfo[DocumentIndex].UncompressedSize>4*1024*1024) then Exit;
      Anchors:=Body.selectNodes('./*[local-name()="p" and namespace-uri()="'+WordNamespace+'" and '+
        '*[local-name()="r" and namespace-uri()="'+WordNamespace+'"]/*[local-name()="pict" and namespace-uri()="'+
        WordNamespace+'"]/*[local-name()="shape" and namespace-uri()="'+VMLNamespace+'" and '+
        'contains(@style,"mso-position-horizontal-relative:page")]]');
      if not Assigned(Anchors) or (Anchors.length<1) or (Anchors.length>MaxBatch) then Exit;
      Request:=TEncoding.UTF8.GetBytes(Prefix+Body.xml+'</figures>');
      Rendered:=RenderWordDrawingBatch(Tool,Request,Anchors.length,Canceled,45000);
      if Length(Rendered)<>Anchors.length then Exit;
      var Remaining:=UnpackedLimit-UnpackedBytes;
      for var Image in Rendered do
      begin
        if (Length(Image)<25) or (Length(Image)>Remaining) or (Image[0]<>$89) or
          (Image[1]<>Ord('P')) or (Image[2]<>Ord('N')) or (Image[3]<>Ord('G')) then Exit;
        Dec(Remaining,Length(Image));
      end;
      for var Index:=0 to High(Rendered) do
      begin
        Check;
        Node:=Anchors.item[Index];
        Picture(Rendered[Index],False,'',WordDrawingCaption(Node));
      end;
      UnpackedBytes:=UnpackedLimit-Remaining;
      Result:=True;
    end;
  begin
    Result:=False;
    Groups:=Body.selectNodes('.//*[local-name()="wgp" and namespace-uri()="'+WordGroupNamespace+'"] | '+
      './/*[local-name()="pict" and namespace-uri()="'+WordNamespace+'"]/*[local-name()="group" and namespace-uri()="'+
      VMLNamespace+'" and count(../*)=1] | '+
      './/*[local-name()="pict" and namespace-uri()="'+WordNamespace+'"]/'+WordVmlInlineOvalQuery+' | '+
      './/*[local-name()="pict" and namespace-uri()="'+WordNamespace+'" and '+WordVmlTextBoxQuery+'] | '+
      './/*[local-name()="graphicData" and namespace-uri()="'+WordDrawingNamespace+'"]/*[local-name()="wsp" '+
      'and namespace-uri()="'+WordShapeNamespace+'" and *[local-name()="txbx" and namespace-uri()="'+WordShapeNamespace+'"]] | '+
      './/'+WordCanvasQuery);
    if not Assigned(Groups) then Exit;
    if (Groups.length=0) and (not PagePreview or
      not Assigned(Body.selectSingleNode('.//*[local-name()="anchor" and namespace-uri()="'+WordPlacementNamespace+'"]'))) then Exit;
    Tool:=FindDirectDOCReader;
    if Tool='' then
    begin
      LogDiagnosticTrace('word-drawings','Отрисовщик схем Word недоступен.','DOCX');
      Exit;
    end;
    XML:=TStringBuilder.Create('<figures>'); Keys:=TList<string>.Create;
    try
      if Assigned(WordStyles) then XML.Append(WordStyles.xml);
      Part:=ReadPart(WordThemePath);
      if Assigned(Part) then XML.Append(Part.xml);
      Part:=WordChild(ReadPart(WordSettingsPath),'clrschememapping');
      if Assigned(Part) then XML.Append(Part.xml);
      if Assigned(Body.selectSingleNode('.//*[local-name()="txbxContent" and namespace-uri()="'+
        WordNamespace+'"]//*[local-name()="numPr" and namespace-uri()="'+WordNamespace+'"]')) then
      begin
        var NumberingIndex:=Zip.IndexOf(WordNumberingPath);
        if (NumberingIndex>=0) and (Zip.FileInfo[NumberingIndex].UncompressedSize<=1024*1024) then
        begin
          Part:=ReadPart(WordNumberingPath);
          if Assigned(Part) then XML.Append(Part.xml);
        end;
      end;
      Prefix:=XML.ToString;
      if PagePreview and RenderPages then Exit(True);
      PrefixBytes:=TEncoding.UTF8.GetByteCount(Prefix)+Length('</figures>'); RequestBytes:=PrefixBytes;
      WordRenderedDrawings:=TDictionary<string,TBytes>.Create;
      if PagePreview then PrepareFloating;
      Group:=Groups.nextNode;
      while Assigned(Group) do
      begin
        Check;
        if EmptyFloatingWordBox(Group,WordVmlTextBox(Group)) then
        begin Group:=Groups.nextNode; Continue; end;
        Source:=WordFigureSource(Group);
        QueueFigure(Source,FigureRequest(Group,Source));
        Group:=Groups.nextNode;
      end;
      RenderBatch;
      LogDiagnosticTrace('word-drawings','Получено рисунков: '+IntToStr(WordRenderedDrawings.Count),'DOCX');
    finally
      Keys.Free; XML.Free;
    end;
  end;
  function WordDrawingCaption(const Group: IXMLDOMNode): string;
  var Paragraphs, Parts: IXMLDOMNodeList; Node, Part: IXMLDOMNode;
    Lines: TStringList; Caption: TStringBuilder; Text: string;
  begin
    Paragraphs:=Group.selectNodes('.//*[local-name()="p" and namespace-uri()="'+WordNamespace+'"]');
    Lines:=TStringList.Create; Caption:=TStringBuilder.Create;
    try
      Node:=Paragraphs.nextNode;
      while Assigned(Node) do
      begin
        Caption.Clear;
        Parts:=Node.selectNodes('.//*[namespace-uri()="'+WordNamespace+
          '" and (local-name()="t" or local-name()="br" or local-name()="cr" or local-name()="tab")]');
        Part:=Parts.nextNode;
        while Assigned(Part) do
        begin
          if LocalName(Part)='t' then Caption.Append(Part.text)
          else if LocalName(Part)='tab' then Caption.Append(#9)
          else Caption.AppendLine;
          Part:=Parts.nextNode;
        end;
        Text:=Trim(Caption.ToString);
        if Text<>'' then Lines.Add(Text);
        Node:=Paragraphs.nextNode;
      end;
      Result:=Trim(Lines.Text);
    finally Caption.Free; Lines.Free; end;
  end;
  function AddMarginRule(const Side: string; Offset, Band, Top, Height, Width: Integer): Boolean;
  var Rule: TReaderMarginRule;
  begin
    Result:=False;
    if not MatchText(Side,['left','right']) or (Band<1) or (Band>57600) or
      (Offset<0) or (Offset>Band) or (Width<635) or (Width>63500) or (Height<635) or
      (Height>12700*800) or (Top< -12700*80) or (Top>12700*720) or (FMarginRules.Count>=100000) then Exit;
    Rule.Position:=FText.Length;
    Rule.OffsetTwips:=Offset; Rule.BandTwips:=Band;
    Rule.TopTwips:=Top div 635; Rule.HeightTwips:=Height div 635;
    Rule.WidthTwips:=Max(1,MulDiv(Width,1,635)); Rule.Leading:=SameText(Side,'left');
    FMarginRules.Add(Rule);
    Result:=True;
  end;
  function ReadWordMarginRule(const N: IXMLDOMNode): Boolean;
  const WordAnchor = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
  var Drawing, Extent, Vertical: IXMLDOMNode; Name: string; Parts: TArray<string>;
    Offset, Band, Top, Height, Width: Integer;
  begin
    Result:=False;
    if VarToStr(N.namespaceURI)<>WordAnchor then Exit;
    Drawing:=N.selectSingleNode('*[local-name()="docPr"]');
    if Drawing=nil then Exit;
    Name:=Attribute(Drawing,'name');
    if not Name.StartsWith('HomeLibreMarginRule-') then Exit;
    Parts:=Name.Split(['-']);
    if (Length(Parts)<>4) or not TryStrToInt(Parts[2],Offset) or not TryStrToInt(Parts[3],Band) then Exit;
    Extent:=N.selectSingleNode('*[local-name()="extent"]');
    Vertical:=N.selectSingleNode('*[local-name()="positionV"][@relativeFrom="paragraph"]/*[local-name()="posOffset"]');
    if (Extent=nil) or (Vertical=nil) or
      not TryStrToInt(Attribute(Extent,'cx'),Width) or not TryStrToInt(Attribute(Extent,'cy'),Height) or
      not TryStrToInt(Vertical.text,Top) then Exit;
    Result:=AddMarginRule(Parts[1],Offset,Band,Top,Height,Width);
  end;
  function ReadEbookMarginRule(const Marker: string): Boolean;
  var Parts: TArray<string>; Offset, Band, Left, Top, Height, Width: Integer;
  begin
    Result:=False;
    if (Length(Marker)>90) or not Marker.StartsWith('homelibre-margin-rule:') then Exit;
    Parts:=Marker.Split([':']);
    if (Length(Parts)<>8) or not TryStrToInt(Parts[2],Offset) or not TryStrToInt(Parts[3],Band) or
      not TryStrToInt(Parts[4],Left) or (Left< -57600*635) or (Left>57600*635) or
      not TryStrToInt(Parts[5],Top) or not TryStrToInt(Parts[6],Height) or not TryStrToInt(Parts[7],Width) then Exit;
    Result:=AddMarginRule(Parts[1],Offset,Band,Top,Height,Width);
  end;

  function ReadWordPageOverlay(const Node: IXMLDOMNode): Boolean;
  const PointDistance = '[+-]?[0-9]{1,4}(?:\.[0-9]{1,4})?pt';
  var Children: IXMLDOMNodeList; Rectangle, Prop: IXMLDOMNode;
    Position: TDictionary<string,string>; Value: string; Sep: Integer; Points: Double;
  begin
    Result:=False;
    if VarToStr(Node.namespaceURI)<>WordNamespace then Exit;
    Children:=Node.selectNodes('./*');
    if Children.length<>1 then Exit;
    Rectangle:=Children.item[0];
    if (LocalName(Rectangle)<>'rect') or (VarToStr(Rectangle.namespaceURI)<>VMLNamespace) or
      (Rectangle.selectNodes('./*').length<>0) or (Trim(Rectangle.text)<>'') then Exit;
    for var Index:=0 to Rectangle.attributes.length-1 do
    begin
      Prop:=Rectangle.attributes.item[Index];
      var Namespace:=VarToStr(Prop.namespaceURI);
      if Namespace='http://www.w3.org/2000/xmlns/' then Continue;
      if (Namespace<>'') or not MatchStr(LocalName(Prop),
        ['id','type','style','fillcolor','filled','stroked','strokeweight']) then Exit;
    end;
    if not MatchStr(Attribute(Rectangle,'type'),['','#_x0000_t1']) or
      not MatchText(Attribute(Rectangle,'fillcolor'),['','white','#fff','#ffffff']) or
      not MatchText(Attribute(Rectangle,'filled'),['','t','true','1']) or
      not MatchText(Attribute(Rectangle,'stroked'),['f','false','0']) then Exit;

    Position:=TDictionary<string,string>.Create;
    try
      for var Declaration in Attribute(Rectangle,'style').ToLower.Split([';']) do
      begin
        if Trim(Declaration)='' then Continue;
        Sep:=Pos(':',Declaration);
        if (Sep=0) or not Position.TryAdd(Trim(Copy(Declaration,1,Sep-1)),
          Trim(Copy(Declaration,Sep+1,MaxInt))) then Exit;
      end;
      if (Position.Count<>8) or not Position.TryGetValue('position',Value) or (Value<>'absolute') or
        not Position.TryGetValue('mso-position-horizontal-relative',Value) or (Value<>'page') or
        not Position.TryGetValue('mso-position-vertical-relative',Value) or (Value<>'page') or
        not Position.TryGetValue('z-index',Value) or not TRegEx.IsMatch(Value,'\A[1-9][0-9]{0,9}\z') then Exit;
      for var Key in TArray<string>.Create('margin-left','margin-top','width','height') do
      begin
        if not Position.TryGetValue(Key,Value) or not TRegEx.IsMatch(Value,'\A'+PointDistance+'\z') then Exit;
        if MatchStr(Key,['width','height']) and
          (not TryStrToFloat(Copy(Value,1,Length(Value)-2),Points,TFormatSettings.Invariant) or (Points<=0)) then Exit;
      end;
      // Page coordinates cannot be applied to the text after it is reflowed.
      Inc(WordPageOverlays);
      Result:=True;
    finally Position.Free; end;
  end;

  function ReadWordHorizontalRule(const Node: IXMLDOMNode): Boolean;
  const VML = 'urn:schemas-microsoft-com:vml';
    Office = 'urn:schemas-microsoft-com:office:office';
    WidthPattern = '\A\s*width\s*:\s*0(?:pt)?\s*\z';
    HeightPattern = '\A\s*height\s*:\s*([0-9]{1,2}(?:\.[0-9]{1,4})?|\.[0-9]{1,4})pt\s*\z';
  var Shapes: IXMLDOMNodeList; Shape, PropertyNode: IXMLDOMNode; Parts: TArray<string>;
    Stroke, Color, Style, WidthStyle, HeightStyle: string; Match: TMatch; Points: Double;
    ColorCode, Height: Integer; Bitmap: TBitmap; Stream: TBytesStream;
  begin
    Result:=False;
    Shapes:=Node.selectNodes('./*');
    if Shapes.length<>1 then Exit;
    Shape:=Shapes.item[0];
    if (LocalName(Shape)<>'rect') or (VarToStr(Shape.namespaceURI)<>VML) or
      (Shape.selectNodes('./*').length<>0) or (Trim(Shape.text)<>'') then Exit;
    for var PropertyName in TArray<string>.Create('hr','hrstd','hrnoshade') do
    begin
      PropertyNode:=Shape.attributes.getQualifiedItem(PropertyName,Office);
      if not Assigned(PropertyNode) or not MatchText(PropertyNode.text,['1','t','true']) then Exit;
    end;
    for var I:=0 to Shape.attributes.length-1 do
    begin
      PropertyNode:=Shape.attributes.item[I];
      var Namespace:=VarToStr(PropertyNode.namespaceURI);
      if Namespace='http://www.w3.org/2000/xmlns/' then Continue;
      if Namespace=Office then
      begin
        if not MatchStr(LocalName(PropertyNode),['hr','hrstd','hrnoshade','hralign']) then Exit;
      end
      else if (Namespace<>'') or not MatchStr(LocalName(PropertyNode),['id','style','fillcolor','stroked']) then Exit;
    end;
    Stroke:=Attribute(Shape,'stroked'); Color:=Attribute(Shape,'fillcolor');
    if not MatchText(Stroke,['0','f','false']) or not TRegEx.IsMatch(Color,'\A#[0-9A-Fa-f]{6}\z') then Exit;
    Style:=TRegEx.Replace(Trim(Attribute(Shape,'style')).ToLower,'\s*;\s*',';');
    Parts:=Style.Split([';'],TStringSplitOptions.ExcludeEmpty);
    if Length(Parts)<>2 then Exit;
    WidthStyle:=Parts[0]; HeightStyle:=Parts[1];
    if TRegEx.IsMatch(HeightStyle,WidthPattern) then
    begin WidthStyle:=Parts[1]; HeightStyle:=Parts[0]; end;
    Match:=TRegEx.Match(HeightStyle,HeightPattern);
    if not TRegEx.IsMatch(WidthStyle,WidthPattern) or not Match.Success or
      not TryStrToFloat(Match.Groups[1].Value,Points,TFormatSettings.Invariant) then Exit;
    Height:=Round(Points*20);
    if (Height<=0) or (Height>720) then Exit;
    ColorCode:=StrToInt('$'+Color.Substring(1));
    Bitmap:=TBitmap.Create; Stream:=nil;
    try
      Stream:=TBytesStream.Create;
      Bitmap.PixelFormat:=pf24bit; Bitmap.SetSize(1,1);
      Bitmap.Canvas.Pixels[0,0]:=RGB((ColorCode shr 16) and $FF,(ColorCode shr 8) and $FF,ColorCode and $FF);
      Bitmap.SaveToStream(Stream);
      Picture(Copy(Stream.Bytes,0,Stream.Size),False,'','',False,0,0,Height);
    finally Stream.Free; Bitmap.Free; end;
    Result:=True;
  end;

  function ReadWordAnchoredLine(const Node: IXMLDOMNode): Boolean;
  const Office = 'urn:schemas-microsoft-com:office:office';
    Word14 = 'http://schemas.microsoft.com/office/word/2010/wordml';
    Declarations = '\A(?:position:absolute|visibility:visible|z-index:-[0-9]{1,10}|'+
      'mso-wrap-style:(?:square|none)|mso-position-(?:horizontal|vertical):absolute|'+
      'mso-position-(?:horizontal|vertical)-relative:text|mso-(?:width|height)-relative:page|'+
      'mso-(?:width|height)-percent:0|mso-wrap-distance-(?:left|top|right|bottom):(?:0(?:pt)?|9pt))\z';
  var Line, Run, Paragraph, Child: IXMLDOMNode; Style, Color: string; Properties, FromPoint, ToPoint: TArray<string>;
    X1,Y1,X2,Y2,Weight,Width,Height,Left,ColorCode,PixelWidth,PixelHeight,Start,Finish,Stride: Integer;
    PNG: TPngImage; Stream: TBytesStream;
    function ParseTwips(const Value: string; out Twips: Integer): Boolean;
    begin
      var Text:=Trim(Value).ToLower;
      if Text='0' then begin Twips:=0; Exit(True); end;
      var Match:=TRegEx.Match(Text,'\A(-?(?:[0-9]{1,4}(?:\.[0-9]{1,4})?|\.[0-9]{1,4}))pt\z');
      var Points: Double;
      Result:=Match.Success and TryStrToFloat(Match.Groups[1].Value,Points,TFormatSettings.Invariant);
      if Result then Twips:=Round(Points*20);
    end;
  begin
    Result:=False;
    var Shapes:=Node.selectNodes('./*');
    if Shapes.length<>1 then Exit;
    Line:=Shapes.item[0];
    if (LocalName(Line)<>'line') or (VarToStr(Line.namespaceURI)<>VMLNamespace) or (Trim(Line.text)<>'') then Exit;
    Child:=Line.firstChild;
    while Assigned(Child) do
    begin
      if (Child.nodeType=NODE_ELEMENT) and ((LocalName(Child)<>'lock') or
        (VarToStr(Child.namespaceURI)<>Office) or (Child.selectNodes('./*').length<>0)) then Exit;
      Child:=Child.nextSibling;
    end;
    for var I:=0 to Line.attributes.length-1 do
    begin
      var Attr:=Line.attributes.item[I];
      var Space:=VarToStr(Attr.namespaceURI);
      var Name:=LocalName(Attr);
      if Space='http://www.w3.org/2000/xmlns/' then Continue;
      if (Space=Office) and MatchStr(Name,['spid','gfxdata']) then Continue;
      if (Space=Word14) and (Name='anchorid') then Continue;
      if (Space<>'') or not MatchStr(Name,['id','style','from','to','strokeweight','strokecolor','stroked']) then Exit;
    end;
    Run:=Node.parentNode;
    if (LocalName(Run)='fallback') and (VarToStr(Run.namespaceURI)=WordCompatibilityNamespace) then
    begin
      if Run.selectNodes('./*').length<>1 then Exit;
      Run:=Run.parentNode.parentNode;
    end;
    if (LocalName(Run)<>'r') or (VarToStr(Run.namespaceURI)<>WordNamespace) or
      (Run.selectNodes('./*[local-name()!="rPr"]').length<>1) then Exit;
    Paragraph:=Run.parentNode;
    if (LocalName(Paragraph)<>'p') or (VarToStr(Paragraph.namespaceURI)<>WordNamespace) or
      (Paragraph.selectNodes('./*[local-name()!="pPr"]').length<>1) then Exit;
    var Stroke:=Attribute(Line,'stroked');
    if (Stroke<>'') and not MatchText(Stroke,['1','t','true']) then Exit;
    Style:=TRegEx.Replace(Trim(Attribute(Line,'style')).ToLower,'\s*([;:])\s*','$1');
    Properties:=Style.Split([';'],TStringSplitOptions.ExcludeEmpty);
    if not MatchStr('position:absolute',Properties) or not MatchStr('mso-position-horizontal-relative:text',Properties) or
      not MatchStr('mso-position-vertical-relative:text',Properties) or not TRegEx.IsMatch(Style,'(?:\A|;)z-index:-[0-9]{1,10}(?:;|\z)') then Exit;
    for var PropertyText in Properties do if not TRegEx.IsMatch(PropertyText,Declarations) then Exit;
    FromPoint:=Attribute(Line,'from').Split([',']); ToPoint:=Attribute(Line,'to').Split([',']);
    if (Length(FromPoint)<>2) or (Length(ToPoint)<>2) or not ParseTwips(FromPoint[0],X1) or not ParseTwips(FromPoint[1],Y1) or
      not ParseTwips(ToPoint[0],X2) or not ParseTwips(ToPoint[1],Y2) or not ParseTwips(Attribute(Line,'strokeweight'),Weight) then Exit;
    Width:=Abs(X2-X1); Left:=Min(X1,X2); Height:=Y1+(Weight+1) div 2;
    if (Y1<>Y2) or (Y1<0) or (Height>720) or (Weight<1) or (Weight>720) or
      (Width<1) or (Width>28800) or (Abs(Left)>1440) then Exit;
    Color:=Attribute(Line,'strokecolor').ToLower;
    if MatchStr(Color,['','black']) then Color:='#000000';
    if not TRegEx.IsMatch(Color,'\A#[0-9a-f]{6}\z') then Exit;
    ColorCode:=StrToInt('$'+Color.Substring(1));
    PixelWidth:=(Width+14) div 15; PixelHeight:=(Height*2+14) div 15;
    Start:=Max(0,2*Y1-Weight)*PixelHeight; Finish:=(2*Y1+Weight)*PixelHeight; Stride:=2*Height;
    PNG:=TPngImage.CreateBlank(COLOR_RGBALPHA,8,PixelWidth,PixelHeight);
    Stream:=nil;
    try
      for var Y:=0 to PixelHeight-1 do
      begin
        var Pixel:PByte:=PNG.Scanline[Y];
        for var X:=0 to PixelWidth-1 do
        begin
          Pixel^:=Byte(ColorCode and $FF); Inc(Pixel);
          Pixel^:=Byte((ColorCode shr 8) and $FF); Inc(Pixel);
          Pixel^:=Byte((ColorCode shr 16) and $FF); Inc(Pixel);
        end;
        var Coverage:=Max(0,Min(Finish,(Y+1)*Stride)-Max(Start,Y*Stride));
        FillChar(PNG.AlphaScanline[Y]^,PixelWidth,Round(255*Coverage/Stride));
      end;
      Stream:=TBytesStream.Create;
      PNG.SaveToStream(Stream);
      Picture(Copy(Stream.Bytes,0,Stream.Size),False,'','',True,Width,Height,0,False,True,Left);
    finally Stream.Free; PNG.Free; end;
    Result:=True;
  end;

  procedure FB2PictureDimensions(const Node: IXMLDOMNode; out Width, Height, RuleHeight, LeftTwips, WidthPercentX100: Integer;
    out SizeInTwips: Boolean);
  const Prefix = 'homelibre-image-size-';
  var Parent: IXMLDOMNode; Marker: string; Dimensions: TArray<string>; W,H: Integer;
  begin
    Width:=0; Height:=0; RuleHeight:=0; LeftTwips:=0; WidthPercentX100:=0; SizeInTwips:=False;
    Parent:=Node.parentNode;
    if Assigned(Parent) and (LocalName(Parent)='a') then Parent:=Parent.parentNode;
    if not Assigned(Parent) or (LocalName(Parent)<>'style') then Exit;
    Marker:=Attribute(Parent,'name');
    WidthPercentX100:=EbookRelativeImageWidth(Marker);
    if WidthPercentX100>0 then Exit;
    SizeInTwips:=WordAnchoredRuleGeometry(Marker,Width,Height,LeftTwips);
    if SizeInTwips then Exit;
    RuleHeight:=WordHorizontalRuleHeight(Marker);
    if RuleHeight>0 then Exit;
    if (Length(Marker)>Length(Prefix)+11) or not Marker.StartsWith(Prefix) then Exit;
    Dimensions:=Marker.Substring(Length(Prefix)).Split(['-']);
    if Length(Dimensions)<>2 then Exit;
    W:=HTMLImageDimension(Dimensions[0]); H:=HTMLImageDimension(Dimensions[1]);
    if ((W=0) and (Dimensions[0]<>'0')) or ((H=0) and (Dimensions[1]<>'0')) then Exit;
    Width:=W; Height:=H;
  end;

  procedure WriteWordNoteReference(const Ref: IXMLDOMNode; Kind: TWordNoteKind);
  var NoteID, Start: Integer; Key, LabelText: string; Mark: IXMLDOMNode;
    Note: TReaderFootnoteLink; Link: TReaderTextLink; Range: TReaderStyledRange;
  begin
    if ReadingWordNotes or (FNoteLinks.Count>=10000) or not TryStrToInt(Attribute(Ref,'id'),NoteID) then Exit;
    if WordNoteLabels=nil then
    begin
      WordNoteLabels:=TDictionary<string,string>.Create;
      LoadWordNoteNumbering;
    end;
    Key:=WordNoteName[Kind]+':'+IntToStr(NoteID);
    if MatchText(Attribute(Ref,'custommarkfollows'),['1','true','on']) then
    begin
      Mark:=Ref.nextSibling;
      while Assigned(Mark) and (Mark.nodeType<>NODE_ELEMENT) do Mark:=Mark.nextSibling;
      if Assigned(Mark) and (LocalName(Mark)='t') and (Trim(Mark.text)<>'') then
      begin
        LabelText:=Mark.text;
        SkipWordCustomMark:=True;
      end
      else LabelText:='*';
      WordNoteLabels.TryAdd(Key,LabelText);
    end
    else if not WordNoteLabels.TryGetValue(Key,LabelText) then
    begin
      LabelText:=WordNoteNumber(Kind);
      WordNoteLabels.Add(Key,LabelText);
    end;
    Start:=FText.Length;
    FBody.Append('{\super\ul '); AddText(LabelText,True); FBody.Append('}');
    Note.Start:=Start; Note.Count:=FText.Length-Start; Note.Target:=Key; Note.LabelText:=LabelText;
    FNoteLinks.Add(Note);
    FAnchors.TryAdd('ref:'+Key,Start);
    Link.Start:=Start; Link.Count:=Note.Count; Link.Target:=Key; FLinks.Add(Link);
    Range:=Default(TReaderStyledRange); Range.Start:=Start; Range.Count:=Note.Count; Range.Kind:=rbFootnote;
    FStyles.Add(Range);
  end;
  function ReadWordMissingPicture(const N: IXMLDOMNode): Boolean;
  var Shape, Child: IXMLDOMNode; Alternative: string;
  begin
    Result:=False;
    Shape:=nil; Child:=N.firstChild;
    while Assigned(Child) do
    begin
      if Child.nodeType=NODE_ELEMENT then
      begin
        if VarToStr(Child.namespaceURI)<>VMLNamespace then Exit;
        if LocalName(Child)='shape' then
        begin
          if Assigned(Shape) or (Attribute(Child,'type')<>'#_x0000_t75') or (Child.childNodes.length<>0) then Exit;
          Shape:=Child;
        end
        else if LocalName(Child)<>'shapetype' then Exit;
      end;
      Child:=Child.nextSibling;
    end;
    if Shape=nil then Exit;
    Alternative:=Trim(Attribute(Shape,'alt'));
    if Alternative='' then Exit;
    NoteUnreadableImage('В DOCX отсутствуют данные рисунка. Показан альтернативный текст.');
    AddText(Alternative,True);
    Result:=True;
  end;
  procedure AppendWordSpacer(Width, Height: Integer);
  var Range: TReaderStyledRange;
  begin
    // RichEdit renders fixed-pitch nonbreaking blanks as layout, without a
    // visible picture or a coloured box in dark themes. Raise them to the
    // authored inline object's height while retaining the surrounding line.
    Range:=Default(TReaderStyledRange); Range.Kind:=rbWordSpacer;
    Range.Start:=FText.Length; Range.Count:=Max(1,MulDiv(Width,1,120));
    Range.SpacerFontTwips:=Max(10,MulDiv(Width,5,3*Range.Count));
    Range.SpacerRiseTwips:=Max(0,Height-MulDiv(Range.SpacerFontTwips,83,100));
    FBody.Append('{\f2\fs').Append(Max(1,MulDiv(Range.SpacerFontTwips,1,10)))
      .Append('\up').Append(MulDiv(Range.SpacerRiseTwips,1,10)).Append(' ');
    for var I:=1 to Range.Count do FBody.Append('\~');
    FBody.Append('}'); FText.Append(StringOfChar(#$00A0,Range.Count)); FStyles.Add(Range);
    Inc(WordSpacerCount);
  end;
  function ReadEbookWordSpacer(const N: IXMLDOMNode): Boolean;
  const Prefix = '^homelibre-word-space-([0-9]{1,5})-([0-9]{1,5})$';
  var Marker: string; Parsed: TMatch; Width, Height: Integer;
  begin
    Result:=False;
    if Assigned(N.firstChild) then Exit;
    if E='.fb2' then Marker:=Attribute(N,'name')
    else
    begin
      for var ClassName in Attribute(N,'class').Split([' ',#9,#10,#13],TStringSplitOptions.ExcludeEmpty) do
        if ClassName.StartsWith('homelibre-word-space-') then
        begin Marker:=ClassName; Break; end;
    end;
    Parsed:=TRegEx.Match(Marker,Prefix); if not Parsed.Success then Exit;
    Width:=StrToInt(Parsed.Groups[1].Value); Height:=StrToInt(Parsed.Groups[2].Value);
    if (Width<10) or (Width>14400) or (Height<10) or (Height>14400) then Exit;
    AppendWordSpacer(Width,Height); Result:=True;
  end;
  function ReadWordPictureSpacer(const N: IXMLDOMNode): Boolean;
  const OfficeNamespace = 'urn:schemas-microsoft-com:office:office';
  var Shape, Child, Attr: IXMLDOMNode; Reference, Key, Entry: string;
    Width, Height, Twips: Integer; Template, Known: Boolean; Parsed: TMatch;
    function Off(const Value: string): Boolean;
    begin Result:=MatchText(Value,['f','false','0']); end;
    function AttributesAllowed(const Node: IXMLDOMNode; const Allowed: array of string): Boolean;
    var A: IXMLDOMNode; Namespace, Name: string;
    begin
      Result:=False;
      for var I:=0 to Node.attributes.length-1 do
      begin
        A:=Node.attributes.item[I];
        Namespace:=VarToStr(A.namespaceURI);
        if Namespace='http://www.w3.org/2000/xmlns/' then Continue;
        Name:=A.nodeName;
        if Namespace=OfficeNamespace then Name:='o:'+LocalName(A)
        else if Namespace<>'' then Exit;
        if not MatchText(Name,Allowed) then Exit;
      end;
      Result:=True;
    end;
    function EmptyTemplate(const Node: IXMLDOMNode): Boolean;
    var C: IXMLDOMNode;
    begin
      Result:=False;
      if (Attribute(Node,'spt')<>'75') or not Off(Attribute(Node,'filled')) or not Off(Attribute(Node,'stroked')) or
        not AttributesAllowed(Node,['id','coordsize','path','filled','stroked','o:spt','o:preferrelative']) then Exit;
      C:=Node.firstChild;
      while Assigned(C) do
      begin
        if C.nodeType=NODE_ELEMENT then
        begin
          if VarToStr(C.namespaceURI)=VMLNamespace then
          begin
            if LocalName(C)='stroke' then
            begin if not AttributesAllowed(C,['joinstyle']) then Exit; end
            else if not MatchText(LocalName(C),['path','formulas']) then Exit;
          end
          else if (VarToStr(C.namespaceURI)<>OfficeNamespace) or (LocalName(C)<>'lock') then Exit;
        end;
        C:=C.nextSibling;
      end;
      Result:=True;
    end;
  begin
    Result:=False; Shape:=nil; Child:=N.firstChild;
    while Assigned(Child) do
    begin
      if Child.nodeType=NODE_ELEMENT then
      begin
        if VarToStr(Child.namespaceURI)<>VMLNamespace then Exit;
        if LocalName(Child)='shapetype' then
        begin
          Key:=Attribute(Child,'id');
          if Key<>'' then
          begin
            if WordPictureTemplates=nil then WordPictureTemplates:=TDictionary<string,Boolean>.Create;
            WordPictureTemplates.AddOrSetValue(CurrentPath+#1+Key,EmptyTemplate(Child));
          end;
        end
        else if (LocalName(Child)='shape') and not Assigned(Shape) then Shape:=Child
        else Exit;
      end;
      Child:=Child.nextSibling;
    end;
    if (Shape=nil) or Assigned(Shape.firstChild) or (Trim(Attribute(Shape,'alt'))<>'') or
      not AttributesAllowed(Shape,['id','type','alt','style','filled','stroked']) then Exit;
    Reference:=Attribute(Shape,'type');
    if not Reference.StartsWith('#') or (WordPictureTemplates=nil) then Exit;
    Known:=WordPictureTemplates.TryGetValue(CurrentPath+#1+Copy(Reference,2,MaxInt),Template);
    if not Known or not Template then Exit;
    for Key in TArray<string>.Create('filled','stroked') do
    begin
      Attr:=Shape.attributes.getNamedItem(Key);
      if Assigned(Attr) and not Off(Attr.text) then Exit;
    end;
    Width:=0; Height:=0;
    for Entry in Attribute(Shape,'style').Split([';'],TStringSplitOptions.ExcludeEmpty) do
    begin
      Parsed:=TRegEx.Match(Entry,'^\s*(width|height)\s*:\s*([0-9]{1,3}(?:\.[0-9]{1,3})?)pt\s*$',[roIgnoreCase]);
      if not Parsed.Success then Exit;
      Twips:=Round(StrToFloat(Parsed.Groups[2].Value,TFormatSettings.Invariant)*20);
      if (Twips<10) or (Twips>14400) then Exit;
      if SameText(Parsed.Groups[1].Value,'width') then
      begin if Width<>0 then Exit; Width:=Twips; end
      else begin if Height<>0 then Exit; Height:=Twips; end;
    end;
    if (Width=0) or (Height=0) then Exit;
    if FCellWidth=0 then
    begin
      var ParagraphNode:=N.selectSingleNode('ancestor::*[local-name()="p" and namespace-uri()="'+WordNamespace+'"][1]');
      var Alignment:=Attribute(DirectChild(DirectChild(ParagraphNode,'ppr'),'jc'),'val');
      if Alignment='center' then FBody.Append('\qc\fi0 ')
      else if Alignment='right' then FBody.Append('\qr\fi0 ')
      else if Alignment='left' then FBody.Append('\ql\fi0 ');
    end;
    AppendWordSpacer(Width,Height); Result:=True;
  end;
  procedure ReadEpubMath(const Body: IXMLDOMNode; const Chapter: TBytes);
  const MathElement = 'local-name()="math" and (namespace-uri()="http://www.w3.org/1998/Math/MathML" or '+
    'namespace-uri()="http://www.w3.org/1999/xhtml" or namespace-uri()="")';
  begin
    if Assigned(MathPictures) then MathPictures.Clear;
    if MathFormulasRemaining<=0 then Exit;
    var Nodes:=Body.selectNodes('.//*['+MathElement+' and not(ancestor::*['+MathElement+'])]');
    var Count:=Nodes.length;
    if (Count=0) or (Count>MathFormulasRemaining) then Exit;
    if MathDeadline=0 then MathDeadline:=GetTickCount64+90000;
    Dec(MathFormulasRemaining,Count);
    var Images:=PrepareEpubMathImages(Chapter,Count,MathDeadline,MathBytesRemaining,Canceled);
    if Length(Images)<>Count then Exit;
    if MathPictures=nil then MathPictures:=TDictionary<string,TBytes>.Create;
    for var Index:=0 to Count-1 do
      if Length(Images[Index])>0 then
        MathPictures.TryAdd(THashSHA2.GetHashString(Nodes.item[Index].xml),Images[Index]);
  end;

  function ReservedBaselineJpegMarker(const Image: TBytes): Boolean;
  var Offset, SegmentSize: Integer; Code: Byte; Baseline: Boolean;
  begin
    Result:=False; Baseline:=False; Offset:=2;
    // Check the first scan only. Header bytes can legitimately look like markers.
    while Offset+3<Length(Image) do
    begin
      if Image[Offset]<>$FF then Exit;
      while (Offset<Length(Image)) and (Image[Offset]=$FF) do Inc(Offset);
      if Offset+2>=Length(Image) then Exit;
      Code:=Image[Offset]; Inc(Offset);
      SegmentSize:=Integer(Image[Offset])*256+Image[Offset+1];
      if (SegmentSize<2) or (SegmentSize>Length(Image)-Offset) then Exit;
      Inc(Offset,SegmentSize);
      if Code=$C0 then Baseline:=True;
      if Code<>$DA then Continue;
      if not Baseline then Exit;
      while Offset<Length(Image)-1 do
      begin
        if Image[Offset]<>$FF then
        begin
          Inc(Offset);
          Continue;
        end;
        repeat Inc(Offset) until (Offset>=Length(Image)) or (Image[Offset]<>$FF);
        if Offset>=Length(Image) then Exit;
        Code:=Image[Offset]; Inc(Offset);
        // Stuffed bytes and restart markers are part of the scan.
        if (Code<>0) and not ((Code>=$D0) and (Code<=$D7)) then
          Exit((Code>=$02) and (Code<=$BF));
      end;
      Exit;
    end;
  end;

  function NeedsJpegRecovery(const Image: TBytes): Boolean;
  begin
    Result:=(Length(Image)>=4) and (Image[0]=$FF) and (Image[1]=$D8) and (Image[2]=$FF);
    if not Result then Exit;
    // Some encoders leave extra bytes after an otherwise usable end marker.
    for var I:=Length(Image)-2 downto 2 do
      if Image[I]=$FF then
      begin
        if Image[I+1]=$D9 then Exit(ReservedBaselineJpegMarker(Image));
        if Image[I+1]=$DA then Break;
      end;
  end;

  function DrawEpubMath(const N: IXMLDOMNode): Boolean;
  var Image: TBytes; Width, Height: Integer; Caption: string;
  begin
    Result:=False;
    if Assigned(MathPictures) and MathPictures.TryGetValue(THashSHA2.GetHashString(N.xml),Image) then
    begin
      var Stream:=TBytesStream.Create(Image);
      try Result:=ImageDimensions(Stream,Width,Height); finally Stream.Free; end;
      if Result then
      begin
        var Targets:=N.selectNodes('.//*[@id]');
        for var Index:=0 to Targets.length-1 do
        begin
          var Target:=Attribute(Targets.item[Index],'id');
          if (Target<>'') and (Length(CurrentPath)+Length(Target)<4096) and (FAnchors.Count<100000) then
            RegisterEpubAnchor(CurrentPath+'#'+Target);
        end;
        Caption:=Attribute(N,'alttext');
        if Caption='' then Caption:=N.text;
        var InlineMath:=not SameText(Attribute(N,'display'),'block');
        if not InlineMath and (FCellWidth=0) and (FText.Length>0) and (FText.Chars[FText.Length-1]<>#13) then Paragraph;
        Picture(Image,False,'',Copy(Caption,1,512),False,Width div 2,Height div 2,0,InlineMath);
        Exit;
      end;
    end;
    if not MathFallback then
    begin
      MathFallback:=True;
      if Warnings.Count<20 then Warnings.Add('Часть формул EPUB показана текстом. Для отрисовки нужна актуальная версия модуля «Вёрстка EPUB в PDF».');
    end;
  end;

  function TrailingWordOffsetRule(const Paragraph: IXMLDOMNode): IXMLDOMNode;
  var Run, Drawing, Anchor, Properties: IXMLDOMNode;
  begin
    Result:=nil;
    Run:=Paragraph.lastChild;
    if not Assigned(Run) or (LocalName(Run)<>'r') then Exit;
    Drawing:=Run.firstChild;
    if not Assigned(Drawing) or (LocalName(Drawing)<>'drawing') or Assigned(Drawing.nextSibling) then Exit;
    Anchor:=Drawing.firstChild;
    if not Assigned(Anchor) or (LocalName(Anchor)<>'anchor') then Exit;
    Properties:=Anchor.selectSingleNode('*[local-name()="docPr"]');
    if Assigned(Properties) and Attribute(Properties,'name').StartsWith('rIdHomeLibreParagraphRuleOffset') then
      Result:=Run;
  end;

  procedure Walk(const N: IXMLDOMNode; Depth: Integer; InsideTitle: Boolean = False;
    StyledContainer: Boolean = False; InheritedFontPercent: Integer = 100; Preformatted: Boolean = False;
    const LegendMarker: TBytes = nil; LegendWidth: Integer = 0; LegendHeight: Integer = 0);
  var J, Spaces, StyleIndex, NoteStart, InitialStart, HeadingLevel, FontPercent, FontStyleIndex, LinkStart: Integer; Name, Ref, Binary, Style, NoteTarget, CSSStyle, AppliedAlignment, LinkTarget, Anchor: string; Link: TReaderFootnoteLink; TextLink: TReaderTextLink;
    StyleNode, StyleValue, Ancestor, Previous, Child, TrailingRule: IXMLDOMNode; Bytes: TBytes;
    IsParagraph, IsTitle, IsBlock, IsCode, IsTextFrame, ChapterInitial, InferredHeading, NumericLink: Boolean;
    Range: TReaderStyledRange;
    OuterFieldDepth, OuterInstructionDepth: Integer;
    OuterTableSpans: TArray<TTableSpan>;
    ShadeStart, SpacerCountBefore, NoteBodyStart: Integer;
    ShadeColor: string;
    function WriteTableRow: Boolean;
    const CellHalfGap = 55;
    var Cells: TArray<IXMLDOMNode>; Widths: TArray<Integer>; Cell, Properties, WidthNode, Merge, Part, ContentNode: IXMLDOMNode;
      MergeKinds: TArray<TTableMerge>;
      CellInsets: TArray<Integer>;
      CellStyles: TArray<TReaderCellStyle>;
      RowColors: array[0..1] of Integer;
      Weight, Total, Edge, I, OuterCellWidth, OuterCellInset, OuterCellTextStart: Integer;
      CellAnchor, RowProperties: string; SeenContent, NestedInRow, PreserveCellLines, RowHasPadding: Boolean;
      Layout: TStringBuilder;
      CellPositions: TArray<TLayoutInsertion>;
      procedure AppendRowProperties;
      begin
        for var CellPosition in CellPositions do
        begin
          var Insertion:=CellPosition;
          Inc(Insertion.Offset,FBody.Length);
          FLayoutInsertions.Add(Insertion);
        end;
        FBody.Append(RowProperties);
      end;
      function PaddingOrDefault(const Style: TReaderCellStyle; Side: TReaderCellSide): Integer;
      begin
        Result:=Style.Padding[Side];
        if Result<0 then
          if Side in [rcLeft,rcRight] then Result:=CellHalfGap else Result:=0;
      end;
      procedure BeginCell(Index: Integer = -1);
      begin
        FBody.Append('\pard\intbl\itap').Append(TableLevel).Append('\ql\fi0');
        // RichEdit has a single horizontal margin per row. Use paragraph
        // margins for per-cell CSS padding in the native presentation.
        if RowHasPadding and (Index>=0) then
        begin
          FBody.Append('\li').Append(PaddingOrDefault(CellStyles[Index],rcLeft))
            .Append('\ri').Append(PaddingOrDefault(CellStyles[Index],rcRight))
            .Append('\sb').Append(PaddingOrDefault(CellStyles[Index],rcTop))
            .Append('\sa').Append(PaddingOrDefault(CellStyles[Index],rcBottom));
        end;
        FBody.Append(' ');
      end;
      procedure EndCell;
      begin
        if TableLevel>1 then FBody.Append('\nestcell{\nonesttables\par}')
        else FBody.Append('\cell ');
      end;
      function PercentWidth(const Source: IXMLDOMNode): Integer;
      var Parsed: TMatch; Number: Double;
      begin
        Result:=0;
        Parsed:=TableWidthPattern.Match(Attribute(Source,'style'));
        if Parsed.Success and TryStrToFloat(Parsed.Groups[1].Value,Number,TFormatSettings.Invariant) and
          (Number>0) and (Number<=100) then
          Result:=Max(1,Round(Number*100));
      end;
      function CellColorIndex(const Text: string; ForBackground: Boolean): Integer;
      var Value: Integer; Hex: string; Entry: TTableColor; Key: Cardinal;
      begin
        Result:=0;
        Hex:=Text;
        if not Hex.StartsWith('#') then Exit;
        if Length(Hex)=4 then
          Hex:='#'+StringOfChar(Hex[2],2)+StringOfChar(Hex[3],2)+StringOfChar(Hex[4],2);
        if (Length(Hex)<>7) or not TryStrToInt('$'+Copy(Hex,2,6),Value) then Exit;
        Entry.Color:=RGB(Byte(Value shr 16),Byte(Value shr 8),Byte(Value));
        Entry.ForBackground:=ForBackground;
        // COLORREF uses only the low 24 bits. A fill and an equal-colored
        // border need distinct palette entries because only the fill is tinted.
        Key:=Cardinal(Entry.Color) or (Cardinal(Ord(ForBackground)) shl 24);
        if CellColorIndexes.TryGetValue(Key,Result) then Exit;
        FCellColors.Add(Entry);
        FHasCellBackgrounds:=FHasCellBackgrounds or ForBackground;
        Result:=FCellColors.Count; CellColorIndexes.Add(Key,Result);
      end;
      function ReadCellStyle(const Source: IXMLDOMNode): TReaderCellStyle;
      var Previous: IXMLDOMNode; PreviousName: string;
      begin
        Result:=Default(TReaderCellStyle);
        if not Assigned(Source) or not MatchStr(E,['.epub','.fb2']) then
        begin
          for var Side:=Low(TReaderCellSide) to High(TReaderCellSide) do Result.Padding[Side]:=-1;
          Exit;
        end;
        Previous:=nil;
        if CSS.HasAdjacentRules then
        begin
          Previous:=Source.previousSibling;
          while Assigned(Previous) and (Previous.nodeType<>NODE_ELEMENT) do Previous:=Previous.previousSibling;
        end;
        if Assigned(Previous) then PreviousName:=LocalName(Previous);
        Result:=CSS.CellStyle(LocalName(Source),Attribute(Source,'class'),Attribute(Source,'id'),
          Attribute(Source,'style'),PreviousName,Attribute(Previous,'class'),Attribute(Previous,'id'));
      end;
      function ReserveRowColor(Index: Integer): Boolean;
      begin
        if (Index=0) or (Index=RowColors[0]) or (Index=RowColors[1]) then Exit(True);
        for var Slot:=Low(RowColors) to High(RowColors) do
          if RowColors[Slot]=0 then begin RowColors[Slot]:=Index; Exit(True); end;
        Result:=False;
      end;
      procedure WriteCellStyle(const CellStyle: TReaderCellStyle);
      const Edge: array[TReaderCellSide] of string = ('\clbrdrt','\clbrdrr','\clbrdrb','\clbrdrl');
        Patterns: array[0..6] of string = ('\brdrdot','\brdrdash','\brdrdb','\brdrengrave',
          '\brdremboss','\brdrinset','\brdroutset');
      var Index: Integer;
      begin
        Index:=CellColorIndex(CellStyle.Background,True);
        if Index>0 then Layout.Append('\clcbpat').Append(Index);
        for var Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
        begin
          Layout.Append(Edge[Side]);
          if not CellStyle.HasBorders then
          begin Layout.Append('\brdrs\brdrw10'); Continue; end;
          var Border:=CellStyle.Borders[Side];
          if (Border.Width=0) or (Border.Style='') or MatchText(Border.Style,['none','hidden']) or
            (Border.Color='transparent') then
          begin Layout.Append('\brdrnone'); Continue; end;
          Index:=IndexText(Border.Style,['dotted','dashed','double','groove','ridge','inset','outset']);
          if Index>=0 then Layout.Append(Patterns[Index]) else Layout.Append('\brdrs');
          Layout.Append('\brdrw').Append(Border.Width);
          if not MatchText(Border.Color,['#000','#000000']) then
          begin
            Index:=CellColorIndex(Border.Color,False);
            if (Index>0) and ReserveRowColor(Index) then Layout.Append('\brdrcf').Append(Index);
          end;
        end;
      end;
      function ExpandHTMLSpans: Boolean;
      var ExpandedCells: TArray<IXMLDOMNode>; ExpandedWidths, Percents: TArray<Integer>;
        ExpandedKinds: TArray<TTableMerge>; NextSpans: TArray<TTableSpan>;
        Span: TTableSpan; Source: IXMLDOMNode;
        Column, Position, Columns, Percent, Rows: Integer; Kind: TTableMerge;
        HasPercents: Boolean;
        procedure AddCell(const Value: IXMLDOMNode; Count, Percent: Integer; Kind: TTableMerge);
        begin
          ExpandedCells:=ExpandedCells+TArray<IXMLDOMNode>.Create(Value);
          ExpandedWidths:=ExpandedWidths+TArray<Integer>.Create(Count);
          ExpandedKinds:=ExpandedKinds+TArray<TTableMerge>.Create(Kind);
          Percents:=Percents+TArray<Integer>.Create(Percent);
          HasPercents:=HasPercents and (Percent>0);
          Inc(Column,Count);
        end;
        procedure ContinueSpan;
        var Previous: TTableSpan;
        begin
          Previous:=HTMLTableSpans[Position];
          AddCell(nil,Previous.Columns,Previous.Percent,tmContinuation);
          Dec(Previous.RowsLeft);
          if Previous.RowsLeft>0 then NextSpans:=NextSpans+TArray<TTableSpan>.Create(Previous);
          Inc(Position);
        end;
      begin
        Result:=False; Column:=0; Position:=0; HasPercents:=True;
        for Source in Cells do
        begin
          while (Position<Length(HTMLTableSpans)) and (HTMLTableSpans[Position].Column=Column) do
            ContinueSpan;
          Columns:=EnsureRange(StrToIntDef(Attribute(Source,'colspan'),1),1,64);
          if (Position<Length(HTMLTableSpans)) and (HTMLTableSpans[Position].Column<Column+Columns) then Exit;
          Percent:=PercentWidth(Source);
          Rows:=EnsureRange(StrToIntDef(Attribute(Source,'rowspan'),1),1,100000);
          Kind:=tmNone;
          if Rows>1 then
          begin
            Span.Column:=Column; Span.Columns:=Columns; Span.RowsLeft:=Rows-1; Span.Percent:=Percent;
            NextSpans:=NextSpans+TArray<TTableSpan>.Create(Span);
            Kind:=tmStart;
          end;
          AddCell(Source,Columns,Percent,Kind);
        end;
        while Position<Length(HTMLTableSpans) do
        begin
          if HTMLTableSpans[Position].Column>Column then
            AddCell(nil,HTMLTableSpans[Position].Column-Column,0,tmNone);
          ContinueSpan;
        end;
        if Length(ExpandedCells)>63 then Exit;
        Cells:=ExpandedCells; MergeKinds:=ExpandedKinds; HTMLTableSpans:=NextSpans;
        if HasPercents then Widths:=Percents else Widths:=ExpandedWidths;
        Total:=0;
        for var Width in Widths do Inc(Total,Width);
        Result:=True;
      end;
    begin
      Result:=False;
      if (Name<>'tr') or not Assigned(N.parentNode) or
        not MatchText(LocalName(N.parentNode),['tbl','table','tbody','thead','tfoot']) then Exit;
      if TableLevel>=15 then Exit;
      Cell:=N.firstChild; Total:=0; NestedInRow:=False;
      while Assigned(Cell) do
      begin
        if MatchText(LocalName(Cell),['tc','td','th']) then
        begin
          if Length(Cells)>=63 then
          begin HTMLTableSpans:=nil; Exit; end;
          NestedInRow:=NestedInRow or Assigned(FindNode(Cell,'tbl')) or Assigned(FindNode(Cell,'table'));
          Weight:=1;
          if E='.docx' then
          begin
            Properties:=FindNode(Cell,'tcpr'); WidthNode:=FindNode(Properties,'tcw');
            if Assigned(WidthNode) then Weight:=EnsureRange(StrToIntDef(Attribute(WidthNode,'w'),1),1,100000);
          end
          else Weight:=EnsureRange(StrToIntDef(Attribute(Cell,'colspan'),1),1,64);
          Cells:=Cells+TArray<IXMLDOMNode>.Create(Cell);
          Widths:=Widths+TArray<Integer>.Create(Weight); Inc(Total,Weight);
        end;
        Cell:=Cell.nextSibling;
      end;
      if ((E='.epub') or (E='.fb2')) and not ExpandHTMLSpans then HTMLTableSpans:=nil;
      if Length(Cells)=0 then Exit;
      FHasTables:=True; Edge:=0;
      OuterCellWidth:=FCellWidth; OuterCellInset:=FCellInset; OuterCellTextStart:=CellTextStart;
      Layout:=TStringBuilder.Create;
      try
        SetLength(CellPositions,Length(Cells));
        SetLength(CellInsets,Length(Cells));
        SetLength(CellStyles,Length(Cells));
        RowHasPadding:=False;
        RowColors[0]:=0; RowColors[1]:=0;
        for I:=0 to High(Cells) do
        begin
          CellStyles[I]:=ReadCellStyle(Cells[I]);
          for var Padding in CellStyles[I].Padding do RowHasPadding:=RowHasPadding or (Padding>=0);
          CellInsets[I]:=PaddingOrDefault(CellStyles[I],rcLeft)+PaddingOrDefault(CellStyles[I],rcRight);
          // RichEdit imports at most two explicit colors per row. Keep the
          // cell fills ahead of any border colors so a rule cannot erase a fill.
          ReserveRowColor(CellColorIndex(CellStyles[I].Background,True));
        end;
        Layout.Append('\trowd\trgaph').Append(IfThen(RowHasPadding,0,CellHalfGap)).Append('\trleft0 ');
        for I:=0 to High(Cells) do
        begin
          if E='.docx' then
          begin
            Properties:=FindNode(Cells[I],'tcpr'); Merge:=FindNode(Properties,'vmerge');
            if Assigned(Merge) then
              if SameText(Attribute(Merge,'val'),'restart') then Layout.Append('\clvmgf') else Layout.Append('\clvmrg');
          end
          else if I<Length(MergeKinds) then
            case MergeKinds[I] of
              tmStart: Layout.Append('\clvmgf');
              tmContinuation: Layout.Append('\clvmrg');
            end;
          WriteCellStyle(CellStyles[I]);
          Inc(Edge,Widths[I]);
          CellPositions[I].Offset:=Layout.Length;
          CellPositions[I].CellWidth:=IfThen(OuterCellWidth=0,10000,OuterCellWidth);
          CellPositions[I].CellInset:=OuterCellInset;
          CellPositions[I].Value:=MulDiv(Edge,10000,Total);
        end;
        RowProperties:=Layout.ToString;
      finally Layout.Free; end;
      Inc(TableLevel);
      try
        if TableLevel=1 then AppendRowProperties;
        for I:=0 to High(Cells) do
        begin
          FCellWidth:=Max(1,MulDiv(IfThen(OuterCellWidth=0,10000,OuterCellWidth),Widths[I],Total));
          FCellInset:=MulDiv(OuterCellInset,Widths[I],Total)+CellInsets[I];
          BeginCell(I);
          CellTextStart:=FText.Length;
          if Cells[I]<>nil then
          begin
            if LocalName(Cells[I])='th' then FBody.Append('\b ');
            PreserveCellLines:=Preformatted or (((E='.fb2') or (E='.epub') or IsReaderHTML(E)) and
              TableLineStylePattern.IsMatch(Attribute(Cells[I],'style')));
            CellAnchor:=Attribute(Cells[I],'id');
            if (CellAnchor<>'') and (Length(CellAnchor)<=4096) and (FAnchors.Count<100000) then
              if E='.epub' then RegisterEpubAnchor(CurrentPath+'#'+CellAnchor)
              else if MatchStr(E,['.fb2','.fb3']) then FAnchors.TryAdd(CellAnchor,FText.Length);
            SeenContent:=False; Part:=Cells[I].firstChild;
            while Assigned(Part) do
            begin
              if LocalName(Part)='p' then
              begin
                if SeenContent then Paragraph;
                ContentNode:=Part.firstChild;
                while Assigned(ContentNode) do
                begin Walk(ContentNode,Depth+3,False,True,InheritedFontPercent,PreserveCellLines); ContentNode:=ContentNode.nextSibling; end;
                SeenContent:=True;
              end
              else if not MatchText(LocalName(Part),['tcpr']) then
              begin
                var Before:=FText.Length;
                Walk(Part,Depth+2,False,True,InheritedFontPercent,PreserveCellLines);
                SeenContent:=SeenContent or (FText.Length>Before);
              end;
              Part:=Part.nextSibling;
            end;
            if LocalName(Cells[I])='th' then FBody.Append('\b0 ');
          end;
          EndCell;
          if I<High(Cells) then FText.Append(#9);
        end;
        if TableLevel>1 then
        begin
          BeginCell;
          FBody.Append('{\*\nesttableprops');
          AppendRowProperties;
          FBody.Append('\nestrow}{\nonesttables\par}');
        end
        else
        begin
          // RichEdit needs the outer definition again after an inner row.
          if NestedInRow then
          begin
            FBody.Append('{');
            AppendRowProperties;
            FBody.Append('\row}');
          end
          else FBody.Append('\row');
          FBody.Append('\pard\qj\fi360 ');
        end;
        FText.Append(#13);
      finally
        Dec(TableLevel);
        FCellWidth:=OuterCellWidth; FCellInset:=OuterCellInset; CellTextStart:=OuterCellTextStart;
      end;
      Result:=True;
    end;
  begin
    Check; if Depth>256 then raise Exception.Create('Слишком глубокая разметка книги.');
    if EpubNavigationDocument and (N.nodeType=NODE_ELEMENT) and
      Assigned(N.attributes.getNamedItem('hidden')) then Exit;
    if N.nodeType in [NODE_TEXT,NODE_CDATA_SECTION] then
    begin
      if Preformatted then begin AddPreformattedText(N.text); Exit; end;
      // Preserve the spaces around inline markup; discard indentation between blocks.
      if (Trim(N.text)='') and Assigned(N.parentNode) and
        not MatchText(LocalName(N.parentNode),['p','v','li','subtitle','text-author',
          'span','style','a','strong','b','emphasis','i','em','t','h','h1','h2','h3','h4','h5','h6']) then Exit;
      AddText(N.text,(E='.docx') and Assigned(N.parentNode) and
        SameText(Attribute(N.parentNode,'space'),'preserve'));
      Exit;
    end;
    Name:=LocalName(N); NoteStart:=-1; InitialStart:=-1; ChapterInitial:=False; NoteTarget:=''; LinkStart:=-1;
    if (Name='section') and Assigned(SavedQuoteSections) and
      SavedQuoteSections.ContainsKey(Attribute(N,'id')) then Name:='blockquote';
    ShadeStart:=-1;
    NumericLink:=False;
    if E='.docx' then
    begin
      if (Name='r') and WordRunHidden(N) then
      begin
        // Hidden display runs can still contain the delimiters of a Word field.
        Child:=N.firstChild;
        while Assigned(Child) do
        begin
          if LocalName(Child)='fldchar' then Walk(Child,Depth+1);
          Child:=Child.nextSibling;
        end;
        Exit;
      end;
      if (Name='t') and SkipWordCustomMark then begin SkipWordCustomMark:=False; Exit; end;
      if Name='footnotereference' then begin WriteWordNoteReference(N,wnFootnote); Exit; end;
      if Name='endnotereference' then begin WriteWordNoteReference(N,wnEndnote); Exit; end;
      if (Name='anchor') and ReadWordMarginRule(N) then Exit;
      if Name='drawing' then
      begin
        var Width, Height: Integer;
        if WordDrawingSpacer(N,Width,Height) then
        begin
          AppendWordSpacer(Width,Height);
          Exit;
        end;
      end;
      // Placement offsets and alignment names describe the drawing, not the text.
      if MatchStr(Name,['positionh','positionv']) and
        (VarToStr(N.namespaceURI)='http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing') then Exit;
      if (Name='pict') and (ReadWordHorizontalRule(N) or ReadWordAnchoredLine(N) or
        ReadWordPictureSpacer(N) or ReadWordMissingPicture(N) or ReadWordPageOverlay(N)) then Exit;
    end;
    if ((E='.fb2') and (Name='style') or (E='.epub') and (Name='span')) and ReadEbookWordSpacer(N) then Exit;
    if (E='.fb2') and (Name='style') and (N.firstChild=nil) and ReadEbookMarginRule(Attribute(N,'name')) then Exit;
    if (E='.epub') and (Name='span') and (N.firstChild=nil) then
    begin
      var Classes:=Attribute(N,'class');
      if Classes.Contains('homelibre-margin-rule:') then
        for var Marker in Classes.Split([' ',#9,#10,#13],TStringSplitOptions.ExcludeEmpty) do
          if ReadEbookMarginRule(Marker) then Exit;
    end;
    if (E='.docx') and (Name='alternatecontent') and SameText(VarToStr(N.namespaceURI),WordCompatibilityNamespace) then
    begin
      Child:=WordCompatibilityBranch(N);
      if Assigned(Child) then Walk(Child,Depth+1,InsideTitle,StyledContainer,InheritedFontPercent,Preformatted);
      Exit;
    end;
    var LegacyTextBox:IXMLDOMNode:=nil;
    if (E='.docx') and (Name='pict') then
    begin
      var Oval:=N.selectSingleNode(WordVmlInlineOvalQuery);
      if Assigned(Oval) then
      begin
        if Assigned(WordRenderedDrawings) and WordRenderedDrawings.TryGetValue(THashSHA2.GetHashString(Oval.xml),Bytes) then
          try
            Picture(Bytes,False,'','',False,0,0,0,True);
            Exit;
          except
            on Error: EAbort do raise;
            on Error: EReaderUnsupportedPicture do ;
          end;
        Inc(FPartialDrawingGroups);
      end;
      LegacyTextBox:=WordVmlTextBox(N);
      // An empty floating box with no paint must not become a white bitmap.
      if EmptyFloatingWordBox(N,LegacyTextBox) then Exit;
    end;
    var CanvasFrame: IXMLDOMNode:=nil;
    if (E='.docx') and (Name='wpc') then CanvasFrame:=WordCanvasInline(N);
    if (E='.docx') and (((Name='wgp') and (VarToStr(N.namespaceURI)=WordGroupNamespace)) or
      ((Name='group') and (VarToStr(N.namespaceURI)=VMLNamespace) and Assigned(N.parentNode) and
      (LocalName(N.parentNode)='pict')) or
      Assigned(LegacyTextBox) or Assigned(CanvasFrame) or WordStandaloneShape(N)) then
    begin
      if Assigned(WordRenderedDrawings) and WordRenderedDrawings.TryGetValue(THashSHA2.GetHashString(WordFigureSource(N)),Bytes) then
      begin
        var DrawingHasTables:=Assigned(N.selectSingleNode('.//*[local-name()="tbl" and namespace-uri()="'+WordNamespace+'"]'));
        const HorizontalAnchor = 'ancestor::*[local-name()="anchor"][1]/*[local-name()="positionH"]';
        var LeftMargin:=N.selectSingleNode(HorizontalAnchor+'[@relativeFrom="leftMargin"]/*[local-name()="align"]');
        var DrawingLeft:=Assigned(LeftMargin) and SameText(LeftMargin.text,'left');
        if Assigned(LegacyTextBox) then
        begin
          var Offset:=TRegEx.Match(Attribute(LegacyTextBox,'style'),
            '(?:^|;)\s*margin-left\s*:\s*([0-9]{1,3}(?:\.[0-9]+)?)pt\s*(?:;|$)',[roIgnoreCase]);
          var Points:Double;
          DrawingLeft:=Offset.Success and TryStrToFloat(Offset.Groups[1].Value,Points,TFormatSettings.Invariant) and (Points<=36);
        end;
        if not DrawingLeft and Assigned(N.selectSingleNode(
          '*[local-name()="bodyPr"]/*[local-name()="spAutoFit" and namespace-uri()="'+WordDrawingNamespace+'"]')) then
        begin
          var MarginOffset:=N.selectSingleNode(HorizontalAnchor+'[@relativeFrom="margin"]/*[local-name()="posOffset"]');
          var Offset: Integer;
          DrawingLeft:=Assigned(MarginOffset) and TryStrToInt(MarginOffset.text,Offset) and (Offset>=0) and (Offset<=36*12700);
        end;
        try
          if Assigned(CanvasFrame) then
          begin
            var Extent:=DirectChild(CanvasFrame,'extent');
            var Effects:=DirectChild(CanvasFrame,'effectextent');
            var Width:=Round((StrToInt64Def(Attribute(Extent,'cx'),0)+StrToInt64Def(Attribute(Effects,'l'),0)+
              StrToInt64Def(Attribute(Effects,'r'),0))/635);
            var Height:=Round((StrToInt64Def(Attribute(Extent,'cy'),0)+StrToInt64Def(Attribute(Effects,'t'),0)+
              StrToInt64Def(Attribute(Effects,'b'),0))/635);
            var Caption:='';
            if not DrawingHasTables then Caption:=WordDrawingCaption(N);
            Picture(Bytes,False,'',Caption,False,Width,Height,0,True,True,0,True);
          end
          else if DrawingHasTables then Picture(Bytes) else Picture(Bytes,False,'',WordDrawingCaption(N),DrawingLeft);
        except
          on Error: EAbort do raise;
          on Error: EReaderUnsupportedPicture do Bytes:=nil;
        end;
        if Length(Bytes)>0 then
        begin
          if DrawingHasTables then
          begin
            AddText('Текст и таблицы схемы'); Paragraph;
            var DrawingBoxes:=N.selectNodes('.//*[local-name()="txbxContent" and namespace-uri()="'+WordNamespace+'"]');
            for var BoxIndex:=0 to DrawingBoxes.length-1 do
              Walk(DrawingBoxes.item[BoxIndex],Depth+1,InsideTitle,StyledContainer,InheritedFontPercent,Preformatted);
          end;
          Exit;
        end;
      end;
      if Name<>'group' then Inc(FPartialDrawingGroups);
    end;
    if (E='.docx') and (Name='group') and SameText(VarToStr(N.namespaceURI),VMLNamespace) then
    begin
      Ancestor:=N.parentNode;
      while Assigned(Ancestor) and not ((LocalName(Ancestor)='group') and
        SameText(VarToStr(Ancestor.namespaceURI),VMLNamespace)) do Ancestor:=Ancestor.parentNode;
      if not Assigned(Ancestor) then Inc(FPartialDrawingGroups);
    end;
    if (Name='script') or ((Name='style') and (E<>'.fb2')) or (Name='binary') or (Name='description') or
      (Name='ppr') or (Name='rpr') or (Name='del') then Exit;
    if Name='instrtext' then
    begin
      // Word field codes are hidden. Outside the instruction region the text
      // is literal, including prose mislabeled by DocSharp after an OLE object.
      if (E='.docx') and (DocxInstructionDepth=0) then
        AddText(N.text,SameText(Attribute(N,'space'),'preserve'));
      Exit;
    end;
    if (E='.docx') and (Name='fldchar') then
    begin
      Style:=Attribute(N,'fldchartype');
      if Style='begin' then
      begin
        Inc(DocxFieldDepth);
        if DocxInstructionDepth=0 then DocxInstructionDepth:=DocxFieldDepth;
      end
      else if (DocxFieldDepth>0) and MatchText(Style,['separate','end']) then
      begin
        if DocxInstructionDepth=DocxFieldDepth then DocxInstructionDepth:=0;
        if Style='end' then Dec(DocxFieldDepth);
      end;
      Exit;
    end;
    const TextFrameStyle = 'homelibre-text-frame';
    IsTextFrame:=((E='.fb2') and (Name='p') and (Attribute(N,'style')=TextFrameStyle)) or
      ((E='.epub') and MatchText(Name,['pre','p']) and
        MatchStr(TextFrameStyle,Attribute(N,'class').Split([' ',#9,#10,#13])));
    if Name='pre' then
    begin
      if (FText.Length>0) and (FText.Chars[FText.Length-1]<>#13) then Paragraph;
      if FCellWidth=0 then
        if IsTextFrame then FBody.Append('\pard\ql\fi0\sa0 ')
        else FBody.Append('\pard\ql\fi0\sa100 ');
    end;
    IsCode:=(Name='code') or (Name='pre');
    Anchor:=Attribute(N,'id');
    if (Anchor='') and (Name='a') then Anchor:=Attribute(N,'name');
    if E='.epub' then
    begin
      if Name='body' then FAnchors.TryAdd(CurrentPath+'#',FText.Length);
      if Anchor<>'' then Anchor:=CurrentPath+'#'+Anchor;
    end
    else if not MatchStr(E,['.fb2','.fb3']) and not IsReaderHTML(E) then Anchor:='';
    if (Anchor<>'') and (Length(Anchor)<=4096) and (FAnchors.Count<100000) then
      if E='.epub' then RegisterEpubAnchor(Anchor,N)
      else if (E<>'.fb3') or (Name<>'title') then FAnchors.TryAdd(Anchor,FText.Length);
    NoteBodyStart:=-1;
    if (Anchor<>'') and (FNoteBodies.ContainsKey(Anchor) or
      (Assigned(EpubAnchorEnds) and FAnchors.TryGetValue(Anchor,J) and (J=FText.Length))) then
      NoteBodyStart:=FText.Length;
    if (E='.epub') and (Name='svg') and ReadEpubRasterViewport(N) then Exit;
    if (E='.epub') and (Name='math') and DrawEpubMath(N) then Exit;
    if WriteTableRow then Exit;
    if (E='.fb2') and (Name='style') and (TableLevel>0) then
    begin
      const TableHeadingPrefix = 'homelibre-table-heading-';
      var Marker:=Attribute(N,'name');
      if (Length(Marker)=Length(TableHeadingPrefix)+1) and Marker.StartsWith(TableHeadingPrefix) and
        CharInSet(Marker[Length(Marker)],['1'..'9']) then
        Chapter(HeadingText(N),Ord(Marker[Length(Marker)])-Ord('1'));
    end;
    if ((Name='a') or ((E='.fb3') and (Name='note'))) and (FNoteLinks.Count<10000) then
    begin
      Ref:=Attribute(N,'href');
      if (E='.fb2') and Ref.StartsWith('#') and
        (SameText(Attribute(N,'type'),'note') or FNoteBodies.ContainsKey(LocalLinkTarget(Ref))) then NoteTarget:=LocalLinkTarget(Ref)
      else if (E='.fb3') and (Name='note') and (Ref<>'') then NoteTarget:=LocalLinkTarget('#'+Ref.TrimLeft(['#']))
      else if (E='.epub') and (Pos('#',Ref)>0) and
        (LowerCase(Attribute(N,'type')+' '+Attribute(N,'role')).Contains('noteref')) then
      begin
        J:=Pos('#',Ref);
        try
          Binary:=TNetEncoding.URL.Decode(Copy(Ref,J+1,MaxInt).Replace('+','%2B'));
          if J=1 then NoteTarget:=CurrentPath+'#'+Binary
          else NoteTarget:=ZipPath(CurrentPath,Copy(Ref,1,J-1))+'#'+Binary;
        except
          on Error: EMHLComponentRequired do raise;
          on Error: Exception do if Warnings.Count<20 then Warnings.Add('Сноска: '+Error.Message);
        end;
      end;
      if NoteTarget<>'' then begin NoteStart:=FText.Length; FBody.Append('{\super\ul '); end;
    end;
    if (Name='a') and (NoteStart<0) and (FLinks.Count<100000) then
    begin
      Ref:=Attribute(N,'href');
      try LinkTarget:=LocalLinkTarget(Ref); except LinkTarget:=''; end;
      if (LinkTarget<>'') and (Length(LinkTarget)<=4096) then
      begin
        NumericLink:=(E='.epub') and (NumericEpubAnchor(Ref) or (Ref.StartsWith('./') and
          NumericEpubAnchor(Ref.Substring(2))));
        LinkStart:=FText.Length; FBody.Append('{\ul ');
      end;
    end;
    IsParagraph:=(Name='p') or (Name='v') or (Name='li') or (Name='tr') or
      (Name='subtitle') or (Name='text-author');
    IsTitle:=(Name='title') or (Name='h') or ((Length(Name)=2) and (Name[1]='h') and CharInSet(Name[2],['1'..'6']));
    HeadingLevel:=1;
    if IsTitle then
      if (Length(Name)=2) and (Name[1]='h') then HeadingLevel:=Ord(Name[2])-Ord('0')
      else if (E='.odt') and (Name='h') then HeadingLevel:=StrToIntDef(Attribute(N,'outline-level'),1)
      else if MatchStr(E,['.fb2','.fb3']) and (Name='title') then
      begin
        HeadingLevel:=0; Ancestor:=N.parentNode;
        while Assigned(Ancestor) do
        begin
          if LocalName(Ancestor)='section' then Inc(HeadingLevel);
          Ancestor:=Ancestor.parentNode;
        end;
      end;
    if (Name='p') and ((E='.epub') or IsReaderHTML(E)) then
    begin
      var ExplicitLevel:=HTMLHeadingLevel(Name,Attribute(N,'role'),Attribute(N,'aria-level'),Attribute(N,'class'));
      if ExplicitLevel>0 then begin IsTitle:=True; HeadingLevel:=ExplicitLevel; end;
    end;
    if (E='.docx') and (Name='p') then
    begin
      HeadingLevel:=WordHeading(N,IsTitle);
      if (HeadingLevel>0) and not IsTitle and not ReadingWordNotes then Chapter(HeadingText(N),HeadingLevel-1);
    end;
    InferredHeading:=not IsTextFrame and not InsideTitle and not StyledContainer and UnmarkedHeading(N);
    if IsTitle or InferredHeading or (Name='body') or (Name='section') then PendingInitial:=True;
    IsBlock:=IsTitle or InferredHeading or (Name='subtitle') or (Name='epigraph') or
      (Name='poem') or (Name='cite') or (Name='blockquote') or (Name='text-author') or IsCode or IsTextFrame;
    StyleIndex:=-1;
    if IsTitle then
    begin
      // An opening FB3 title can contain a full-page illustration. A generated
      // paragraph before it would force the illustration onto the next page.
      if (E<>'.fb3') or (FText.Length>0) then Paragraph;
      if (E='.fb3') and (Name='title') and (Anchor<>'') and (Length(Anchor)<=4096) and (FAnchors.Count<100000) then
        FAnchors.TryAdd(Anchor,FText.Length);
      if ((E<>'.fb3') or not Assigned(N.selectSingleNode('ancestor::*[local-name()="notes"]'))) and
        ((E<>'.docx') or ((HeadingLevel>0) and not ReadingWordNotes)) then Chapter(HeadingText(N),HeadingLevel-1);
      if FCellWidth>0 then FBody.Append('{\b ') else FBody.Append('{\pard\qc\b\sa160\sb200 ');
    end;
    if IsParagraph and not IsTitle and not InsideTitle and (FCellWidth=0) then
      if (Length(LegendMarker)>0) or ((E='.fb2') and (Name='p') and
        Assigned(N.selectSingleNode('./*[1][local-name()="style" and @name="homelibre-word-legend"]'))) then
        FBody.Append('\pard\ql\fi0\sa100 ')
      else if IsTextFrame then FBody.Append('\pard\ql\fi0\sa0 ')
      else if Name='v' then FBody.Append('\pard\ql\fi0\li360\sa40 ')
      else if Name='text-author' then FBody.Append('\pard\qr\fi0\sa120 ')
      else if (Name='subtitle') or InferredHeading then FBody.Append('\pard\qc\fi0\sa160\sb140 ')
      else FBody.Append('\pard\qj\fi360\sa100 ');
    var Fb3Style:='';
    if E='.fb3' then
    begin
      if IsParagraph and (FCellWidth=0) then
      begin
        var Alignment:=Attribute(N,'align');
        if Alignment='left' then FBody.Append('\ql\fi0 ')
        else if Alignment='center' then FBody.Append('\qc\fi0 ')
        else if Alignment='right' then FBody.Append('\qr\fi0 ');
      end;
      if Name='underline' then Fb3Style:='\ul '
      else if Name='strikethrough' then Fb3Style:='\strike '
      else if Name='sub' then Fb3Style:='\sub '
      else if Name='sup' then Fb3Style:='\super ';
      if Fb3Style<>'' then FBody.Append('{'+Fb3Style);
    end;
    AppliedAlignment:='';
    if (FCellWidth=0) and (((E='.fb2') and (Name='p')) or
      ((E='.epub') and (IsParagraph or (HeadingLevel>0)))) then
    begin
      var Marker: string;
      if E='.fb2' then Marker:=Attribute(N,'style') else Marker:=Attribute(N,'class');
      var ParagraphStyle:=TRegEx.Match(Marker,
        '(?:^|\s)homelibre-word-space-paragraph-(left|right|center|justify)-(none|[0-9a-f]{6})(?:\s|$)');
      if ParagraphStyle.Success then
      begin
        ShadeColor:=ParagraphStyle.Groups[2].Value;
        ShadeStart:=FText.Length;
        var Alignment:=ParagraphStyle.Groups[1].Value;
        if Alignment='center' then AppliedAlignment:='\qc'
        else if Alignment='right' then AppliedAlignment:='\qr'
        else if Alignment='left' then AppliedAlignment:='\ql'
        else if Alignment='justify' then AppliedAlignment:='\qj';
        FBody.Append(AppliedAlignment);
        if Alignment='justify' then FBody.Append(' ')
        else FBody.Append('\fi0 ');
      end;
      if Marker.Contains('homelibre-word-list-') then
      begin
        var Layout:=TRegEx.Match(Marker,'(?:^|\s)homelibre-word-list-(-?[0-9]{1,7}):(-?[0-9]{1,7})(?:\s|$)');
        if Layout.Success then
        begin
          var Indent: TWordListIndent;
          Indent.Left:=Layout.Groups[1].Value; Indent.First:=Layout.Groups[2].Value;
          ApplyWordListIndent(Indent);
        end;
      end;
    end;
    if (FCellWidth=0) and (E='.docx') and (Name='p') then
    begin
      var ShadeNode:=DirectChild(DirectChild(N,'ppr'),'shd');
      if (Attribute(ShadeNode,'val')='clear') and (Attribute(ShadeNode,'themefill')='') then
      begin
        ShadeColor:=Attribute(ShadeNode,'fill');
        ShadeStart:=FText.Length;
      end;
    end;
    SpacerCountBefore:=WordSpacerCount;
    if IsBlock then
    begin
      Range:=Default(TReaderStyledRange); Range.Start:=FText.Length;
      if IsTitle then begin if HeadingLevel>1 then Range.Kind:=rbSubtitle else Range.Kind:=rbTitle; end
      else if (Name='subtitle') or InferredHeading then Range.Kind:=rbSubtitle
      else if Name='epigraph' then Range.Kind:=rbEpigraph
      else if Name='poem' then Range.Kind:=rbPoem
      else if Name='text-author' then Range.Kind:=rbAuthor
      else if IsTextFrame then Range.Kind:=rbTextFrame
      else if IsCode then Range.Kind:=rbCode else Range.Kind:=rbCite;
      StyleIndex:=FStyles.Count; FStyles.Add(Range);
    end;
    if (Name='epigraph') or (Name='cite') or (Name='blockquote') then
      begin Paragraph; FBody.Append('{\i '); end;
    if (Name='poem') or (Name='stanza') then Paragraph;
    if (Name='strong') or (Name='b') or (Name='subtitle') or InferredHeading then FBody.Append('{\b ');
    if (Name='emphasis') or (Name='i') or (Name='em') then FBody.Append('{\i ');
    if IsCode or IsTextFrame then FBody.Append('{\f1 ');
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
    CSSStyle:=''; FontStyleIndex:=-1; FontPercent:=InheritedFontPercent;
    if (E='.epub') or HasFB2Styles then
    begin
      var Classes:=Attribute(N,'class');
      var InlineStyle:=Attribute(N,'style');
      if HasFB2Styles then
      begin
        if Name='style' then Classes:=Attribute(N,'name') else Classes:=InlineStyle;
        InlineStyle:='';
      end;
      var PreviousTag:=''; var PreviousClasses:=''; var PreviousID:='';
      if CSS.HasAdjacentRules then
      begin
        var Sibling:=N.previousSibling;
        while Assigned(Sibling) and (Sibling.nodeType<>NODE_ELEMENT) do Sibling:=Sibling.previousSibling;
        if Assigned(Sibling) then
        begin
          PreviousTag:=LocalName(Sibling);
          PreviousID:=Attribute(Sibling,'id');
          if not HasFB2Styles then PreviousClasses:=Attribute(Sibling,'class')
          else if PreviousTag='style' then PreviousClasses:=Attribute(Sibling,'name')
          else PreviousClasses:=Attribute(Sibling,'style');
        end;
      end;
      CSSStyle:=CSS.RTF(Name,Classes,Attribute(N,'id'),InlineStyle,PreviousTag,PreviousClasses,PreviousID);
      // This alignment is already active through the paragraph mark.
      if (AppliedAlignment<>'') and (CSSStyle=AppliedAlignment+' ') then CSSStyle:='';
      FontPercent:=CSS.FontPercent(Name,Classes,Attribute(N,'id'),InlineStyle,InheritedFontPercent,
        PreviousTag,PreviousClasses,PreviousID);
      if FontPercent<>InheritedFontPercent then
      begin
        Range:=Default(TReaderStyledRange); Range.Start:=FText.Length; Range.Kind:=rbRelativeSize; Range.ScalePercent:=FontPercent;
        FontStyleIndex:=FStyles.Count; FStyles.Add(Range);
      end;
    end;
    if CSSStyle<>'' then FBody.Append('{'+CSSStyle);
    if (E='.epub') and (Name='li') and not EpubNavigationDocument then ReadEpubListMarker(N);
    if (E='.docx') and (Name='p') then AddWordListMarker(N);
    if Length(LegendMarker)>0 then
      Picture(LegendMarker,False,'','',False,LegendWidth,LegendHeight,0,True,True,0,True);
    var VideoPoster:='';
    if (E='.epub') and (Name='video') then VideoPoster:=Attribute(N,'poster').Trim;
    if (Name='img') and IsReaderHTML(E) then
      HTMLPicture(Attribute(N,'src'),Attribute(N,'alt'),Attribute(N,'width'),Attribute(N,'height'))
    else if (Name='image') or (Name='img') or (VideoPoster<>'') or (Name='blip') or ((E='.docx') and (Name='imagedata')) then
    begin
      var ArchiveMember:='';
      var EpubImagePath:='';
      Ref:=Attribute(N,'href'); if Ref='' then Ref:=Attribute(N,'src');
      if VideoPoster<>'' then Ref:=VideoPoster;
      if Name='blip' then Ref:=Attribute(N,'embed');
      if (E='.docx') and (Name='imagedata') then Ref:=Attribute(N,'id');
      try
        if (E='.docx') and Assigned(Zip) then
        begin
          if not Paths.TryGetValue(Ref,Binary) then raise Exception.Create('Не найдено вложенное изображение DOCX.');
          var Caption:='';
          if Ref.StartsWith('rIdHomeLibreCompoundFigure') then
          begin
            var Properties:=N.selectSingleNode('ancestor::*[local-name()="inline"][1]/*[local-name()="docPr"]');
            if Assigned(Properties) then Caption:=Copy(Attribute(Properties,'descr'),1,4096);
          end;
          var RuleWidth:=0; var RuleHeight:=0; var RuleLeft:=0;
          if Ref.StartsWith('rIdHomeLibreParagraphRule') and WordAnchoredRuleGeometry(
            Attribute(N.selectSingleNode('ancestor::*[local-name()="inline" or local-name()="anchor"][1]/*[local-name()="docPr"]'),'descr'),
            RuleWidth,RuleHeight,RuleLeft) then
          begin
            ReadZip(Binary,Bytes);
            Picture(Bytes,False,'','',True,RuleWidth,RuleHeight,0,False,True,RuleLeft);
          end
          else ReadWordPicture(Binary,Ref.StartsWith('rIdHomeLibreParagraphRule') or
            Ref.StartsWith('rIdHomeLibreCompoundLegend'),Caption);
          if Name='blip' then ApplyWordPictureCrop(N);
        end
        else if E='.fb3' then
        begin
          if not Paths.TryGetValue(Ref,Binary) and not Fb3RelationshipsPresent and (Ref<>'') then
            Binary:=ZipPath(CurrentPath,Ref);
          if Binary='' then
            raise EReadError.CreateFmt('В FB3 не найдено изображение «%s».',[Copy(Ref,1,120)]);
          Bytes:=ReadFb3Picture(Binary);
        end
        else if Assigned(Zip) then
        begin
          if (E='.epub') and (Ref.Trim='') then
            raise EReadError.Create('В разделе «'+Copy(ExtractFileName(CurrentPath),1,100)+'» не указан файл изображения.');
          if (E<>'.epub') or not DecodeInlineImage(Ref,Bytes) then
          begin
            var Member:=ZipPath(CurrentPath,Ref);
            var Index:=Zip.IndexOf(Member);
            if E='.epub' then EpubImagePath:=Member;
            if (E='.epub') and (Index>=0) and (Zip.FileInfo[Index].UncompressedSize>16*1024*1024) and
              MatchText(ExtractFileExt(Member),['.jpeg','.jpg']) then
              Bytes:=ReadLargeEpubJpeg(Index)
            else
            begin
              ReadZip(Member,Bytes);
              if FImageArchiveLock<>nil then ArchiveMember:=Member;
            end;
          end;
          if (E='.epub') and (Ref.EndsWith('.svg',True) or Ref.StartsWith('data:image/svg+xml;',True) or
            Ref.StartsWith('data:image/svg+xml,',True)) then
          begin
            Bytes:=RenderReaderSvg(Bytes);
            ArchiveMember:='';
          end;
        end
        else Bytes:=ReadFB2Picture(Ref.TrimLeft(['#']));
        if (E<>'.docx') or not Assigned(Zip) then
        begin
          var LeftAligned:=False;
          var UseCaption:=False;
          if E='.epub' then
          begin
            var Classes:=Attribute(N,'class').Split([' ']);
            LeftAligned:=MatchText('paragraph-rule',Classes) or MatchText('word-textbox-left',Classes) or
              MatchText('word-diagram-legend',Classes);
            UseCaption:=MatchText('word-textbox',Classes) or MatchText('word-textbox-left',Classes) or
              MatchText('word-diagram',Classes);
          end
          else if E='.fb2' then
          begin
            LeftAligned:=Ref.StartsWith('#paragraph_rule_') or Ref.StartsWith('#word_textbox_left_') or
              Ref.StartsWith('#word_diagram_legend_');
            UseCaption:=Ref.StartsWith('#word_textbox_') or Ref.StartsWith('#word_diagram_');
          end;
          var Caption:='';
          if UseCaption then Caption:=Copy(Attribute(N,'alt'),1,4096);
          var DisplayWidth:=0;
          var DisplayHeight:=0;
          var RuleHeight:=0;
          var LeftTwips:=0;
          var WidthPercentX100:=0;
          var SizeInTwips:=False;
          if (E='.epub') and ((Name='img') or (VideoPoster<>'')) then
          begin
            DisplayWidth:=HTMLImageDimension(Attribute(N,'width'));
            DisplayHeight:=HTMLImageDimension(Attribute(N,'height'));
            for var Marker in Attribute(N,'class').Split([' ',#9,#10,#13],TStringSplitOptions.ExcludeEmpty) do
            begin
              WidthPercentX100:=EbookRelativeImageWidth(Marker);
              if WidthPercentX100>0 then Break;
              SizeInTwips:=WordAnchoredRuleGeometry(Marker,DisplayWidth,DisplayHeight,LeftTwips);
              if SizeInTwips then Break;
              RuleHeight:=WordHorizontalRuleHeight(Marker);
              if RuleHeight>0 then Break;
            end;
          end
          else if (E='.fb2') and (Name='image') then
            FB2PictureDimensions(N,DisplayWidth,DisplayHeight,RuleHeight,LeftTwips,WidthPercentX100,SizeInTwips);
          var JpegNotice:='';
          if ((E='.epub') or (E='.fb2')) and NeedsJpegRecovery(Bytes) then
          begin
            if JpegRecoveryDeadline=0 then JpegRecoveryDeadline:=GetTickCount64+45000;
            var Recovered: TBytes;
            var Rows, OriginalRows, PreviewScans: Integer;
            if not RecoverReaderJpeg(Bytes,JpegRecoveryDeadline,Canceled,Recovered,Rows,OriginalRows,PreviewScans) then
              raise EReadError.Create('JPEG повреждён. Читаемую часть изображения восстановить не удалось.');
            Bytes:=Recovered; ArchiveMember:='';
            if Rows<OriginalRows then
            begin
              if DisplayHeight>0 then DisplayHeight:=Max(1,MulDiv(DisplayHeight,Rows,OriginalRows));
              JpegNotice:=Format('Сохранены верхние %d из %d строк изображения JPEG.',[Rows,OriginalRows]);
            end
            else if PreviewScans>0 then
              JpegNotice:=Format('JPEG восстановлен частично. Полных проходов: %d. Часть мелких деталей утрачена.',[PreviewScans]);
          end;
          var WordCanvas:=IsEbookWordCanvas(N);
          var InlineImage:=(WidthPercentX100=0) and not SizeInTwips and not LeftAligned and not UseCaption and (RuleHeight=0) and
            (WordCanvas or InlineEbookPicture(N,Bytes,DisplayWidth,DisplayHeight));
          var PicturePosition:=FText.Length;
          var OpeningCover:=(FPictures.Count=0) and (FCellWidth=0) and (FText.Length<=2048) and
            (((E='.epub') and not EpubFixedLayout and (EpubCoverPath<>'') and (EpubImagePath=EpubCoverPath)) or
             ((E='.fb2') and (Fb2CoverRef<>'') and (Ref=Fb2CoverRef))) and (FText.ToString.Trim='');
          Picture(Bytes,E='.docx',ArchiveMember,Caption,LeftAligned,DisplayWidth,DisplayHeight,RuleHeight,
            InlineImage,SizeInTwips,LeftTwips,WordCanvas,WidthPercentX100);
          if EpubImagePath<>'' then FAnchors.TryAdd(EpubImagePath+'#',PicturePosition);
          if JpegNotice<>'' then
          begin
            AddText(' ['+JpegNotice+']');
            if FCellWidth=0 then Paragraph;
          end;
          if OpeningCover then FOpeningCoverEnd:=FText.Length;
        end;
      except
        on E: EAbort do raise;
        on E: EMHLComponentRequired do raise;
        on Error: Exception do
        begin
          NoteUnreadableImage(Error.Message);
          AddText('[Изображение не читается.]');
          if MatchStr(E,['.epub','.fb3']) then
          begin
            var AlternateText:=Attribute(N,'alt').Trim;
            if AlternateText<>'' then AddText(' '+AlternateText);
          end;
        end;
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
    // Keep neighbouring table cells distinct in readable/copyable text.
    if MatchText(Name,['td','th']) then
    begin
      Previous:=N.previousSibling;
      while Assigned(Previous) and not MatchText(LocalName(Previous),['td','th']) do Previous:=Previous.previousSibling;
      if Assigned(Previous) then AddText(#9,True);
    end;
    if IsParagraph and (Name='p') and not IsTextFrame and not IsTitle and not InferredHeading and not InsideTitle and not StyledContainer then
    begin InitialStart:=FText.Length; ChapterInitial:=PendingInitial; PendingInitial:=False; end;
    // Walk the siblings in order. Indexed access through a fresh DOM node
    // list for every paragraph grows quadratically in long chapters.
    OuterFieldDepth:=DocxFieldDepth;
    OuterInstructionDepth:=DocxInstructionDepth;
    if (E='.docx') and (Name='txbxcontent') then
    begin
      DocxFieldDepth:=0;
      DocxInstructionDepth:=0;
    end;
    Child:=N.firstChild;
    if (E='.docx') and IsParagraph and (FCellWidth=0) then TrailingRule:=TrailingWordOffsetRule(N);
    if (E='.fb3') and (Name='note') and (NoteStart>=0) and (Trim(N.text)='') then AddText('*',True);
    if MatchText(Name,['table','tbl']) then
    begin
      OuterTableSpans:=HTMLTableSpans;
      HTMLTableSpans:=nil;
      if (TableLevel>0) and (FText.Length>CellTextStart) then
      begin
        FBody.Append('\par ');
        FText.Append(#13);
      end;
    end;
    while Assigned(Child) do
    begin
      if Assigned(TrailingRule) and not Assigned(Child.nextSibling) then Break;
      Walk(Child,Depth+1,InsideTitle or IsTitle,
        StyledContainer or IsTitle or IsCode or IsTextFrame or MatchText(Name,['epigraph','cite','blockquote','poem','stanza','text-author']),
        FontPercent,Preformatted or IsTextFrame or (Name='pre') or ((Name='code') and (E='.fb2')));
      Child:=Child.nextSibling;
    end;
    if (ShadeStart>=0) and (FText.Length>ShadeStart) and ((E<>'.docx') or (WordSpacerCount>SpacerCountBefore)) and
      (FParagraphShades.Count<100000) and TRegEx.IsMatch(ShadeColor,'^[0-9a-fA-F]{6}$') then
    begin
      var RGBValue:=StrToInt('$'+ShadeColor);
      var Shade: TReaderParagraphShade;
      Shade.Start:=ShadeStart; Shade.Finish:=FText.Length;
      Shade.Color:=RGB((RGBValue shr 16) and $FF,(RGBValue shr 8) and $FF,RGBValue and $FF);
      FParagraphShades.Add(Shade);
    end;
    if MatchText(Name,['table','tbl']) then
    begin
      HTMLTableSpans:=OuterTableSpans;
      if TableLevel>0 then FBody.Append('\pard\intbl\itap').Append(TableLevel).Append('\ql\fi0 ');
    end;
    if (E='.docx') and (Name='txbxcontent') then
    begin
      DocxFieldDepth:=OuterFieldDepth;
      DocxInstructionDepth:=OuterInstructionDepth;
    end;
    if (NoteBodyStart>=0) and (FText.Length>NoteBodyStart) then
      if FNoteBodies.ContainsKey(Anchor) then
      begin
        if Trim(FText.ToString(NoteBodyStart,FText.Length-NoteBodyStart).Replace(#$FFFC,''))<>'' then
          FNoteBodiesInText.TryAdd(Anchor,0);
      end
      else if Assigned(EpubAnchorEnds) then EpubAnchorEnds.TryAdd(Anchor,FText.Length);
    if InitialStart>=0 then
    begin
      for J:=InitialStart to FText.Length-1 do
        if TCharacter.IsLetter(FText.Chars[J]) then
        begin
          Range:=Default(TReaderStyledRange); Range.Start:=J; Range.Count:=1;
          // Keep a decomposed accent with its decorated base letter.
          while (J+Range.Count<FText.Length) and
            (TCharacter.GetUnicodeCategory(FText.Chars[J+Range.Count]) in
              [TUnicodeCategory.ucCombiningMark,TUnicodeCategory.ucEnclosingMark,TUnicodeCategory.ucNonSpacingMark]) do Inc(Range.Count);
          if ChapterInitial then Range.Kind:=rbInitial else Range.Kind:=rbParagraphInitial;
          FStyles.Add(Range); InitialStart:=-1; Break;
        end;
      if (InitialStart>=0) and ChapterInitial then PendingInitial:=True;
    end;
    if FontStyleIndex>=0 then
    begin Range:=FStyles[FontStyleIndex]; Range.Count:=FText.Length-Range.Start; FStyles[FontStyleIndex]:=Range; end;
    if CSSStyle<>'' then
    begin
      // Paragraph properties must remain active through the paragraph mark.
      if IsParagraph or IsTitle then Paragraph;
      FBody.Append('}');
    end;
    if (Name='strong') or (Name='b') or (Name='subtitle') or InferredHeading or (Name='emphasis') or
      (Name='i') or (Name='em') or IsCode or IsTextFrame or ((E='.docx') and (Name='r')) then FBody.Append('}');
    if Fb3Style<>'' then FBody.Append('}');
    if NoteStart>=0 then
    begin
      FBody.Append('}'); Link.Start:=NoteStart; Link.Count:=FText.Length-NoteStart; Link.Target:=NoteTarget;
      Link.LabelText:=Trim(N.text);
      if Link.Count>0 then
      begin
        FNoteLinks.Add(Link); Range.Start:=Link.Start; Range.Count:=Link.Count; Range.Kind:=rbFootnote; FStyles.Add(Range);
      end;
    end;
    if LinkStart>=0 then
    begin
      FBody.Append('}'); TextLink.Start:=LinkStart; TextLink.Count:=FText.Length-LinkStart; TextLink.Target:=LinkTarget;
      if TextLink.Count>0 then
      begin
        if NumericLink then
        begin
          if not Assigned(NumericEpubLinks) then NumericEpubLinks:=TList<Integer>.Create;
          NumericEpubLinks.Add(FLinks.Count);
        end;
        FLinks.Add(TextLink); Range.Start:=TextLink.Start; Range.Count:=TextLink.Count; Range.Kind:=rbLink; FStyles.Add(Range);
      end;
    end;
    if StyleIndex>=0 then
    begin Range:=FStyles[StyleIndex]; Range.Count:=FText.Length-Range.Start; FStyles[StyleIndex]:=Range; end;
    if (Name='epigraph') or (Name='cite') or (Name='blockquote') then
      begin FBody.Append('}'); Paragraph; end;
    if (Name='poem') or (Name='stanza') then Paragraph;
    // The FB2 paragraph mark was already emitted inside its CSS group.
    var FinishedFB2Paragraph:=HasFB2Styles and (CSSStyle<>'');
    if IsTitle then
    begin
      if not FinishedFB2Paragraph then Paragraph;
      FBody.Append('}');
    end;
    if IsParagraph and not FinishedFB2Paragraph then Paragraph;
    if Assigned(TrailingRule) then Walk(TrailingRule,Depth+1);
    if (Name='pre') and (FText.Length>0) and (FText.Chars[FText.Length-1]<>#13) then Paragraph;
  end;
  procedure WalkWordBody(const Body: IXMLDOMNode);
  var Child, LabelNode: IXMLDOMNode; Index, Width, Height: Integer; Layout: TWordFloatingDrawing;
    Bytes: TBytes; Stream: TBytesStream; Restored: Boolean;
    function LegendParagraph(const Source: IXMLDOMNode): IXMLDOMNode;
    var Drawings: IXMLDOMNodeList; Drawing, LabelText: IXMLDOMNode;
    begin
      Result:=Source.cloneNode(True);
      Drawings:=Result.selectNodes('./*[local-name()="r" and namespace-uri()="'+WordNamespace+'"]/*['+
        '(local-name()="drawing" and namespace-uri()="'+WordNamespace+'") or '+
        '(local-name()="AlternateContent" and namespace-uri()="'+WordCompatibilityNamespace+'")]');
      for var I:=Drawings.length-1 downto 0 do
      begin
        Drawing:=Drawings.item[I];
        Drawing.parentNode.removeChild(Drawing);
      end;
      LabelText:=Result.selectSingleNode('./*[local-name()="r" and namespace-uri()="'+WordNamespace+'"]'+
        '/*[local-name()="t" and namespace-uri()="'+WordNamespace+'"]');
      if LabelText=nil then raise EReaderUnsupportedPicture.Create('Подпись обозначения DOCX недоступна.');
      var Value:string:=LabelText.text;
      LabelText.text:=Value.TrimLeft([' ']);
    end;
  begin
    if not Assigned(WordFloatingDrawings) or (WordFloatingDrawings.Count=0) then
    begin
      Walk(Body,0);
      Exit;
    end;
    Child:=Body.firstChild; Index:=1; Restored:=False;
    while Assigned(Child) do
    begin
      if Child.nodeType<>NODE_ELEMENT then
      begin
        Child:=Child.nextSibling;
        Continue;
      end;
      Check;
      if (DocxInstructionDepth=0) and WordFloatingDrawings.TryGetValue(Index,Layout) and
        WordRenderedDrawings.TryGetValue(Layout.Key,Bytes) then
      begin
        Stream:=TBytesStream.Create(Bytes);
        try
          if ImageDimensions(Stream,Width,Height) and (Width>=8) and (Width<=2048) and
            (Height>=8) and (Height<=2048) then
            try
              // The drawing helper uses four pixels per point.
              if Layout.Legend then
              begin
                LabelNode:=Child;
                if Layout.LastBlock>Index then
                  repeat LabelNode:=LabelNode.nextSibling;
                  until not Assigned(LabelNode) or (LabelNode.nodeType=NODE_ELEMENT);
                if LabelNode=nil then raise EReaderUnsupportedPicture.Create('Подпись обозначения DOCX недоступна.');
                Walk(LegendParagraph(LabelNode),1,False,False,100,False,Bytes,Width*5,Height*5);
              end
              else Picture(Bytes,False,'',Layout.Caption,True,Width*5,Height*5,0,False,True,0,True);
              Restored:=True;
              repeat
                Child:=Child.nextSibling;
                if Assigned(Child) and (Child.nodeType=NODE_ELEMENT) then Inc(Index);
              until not Assigned(Child) or (Index>Layout.LastBlock);
              Continue;
            except
              on Error: EAbort do raise;
              on Error: EReaderUnsupportedPicture do ;
            end;
        finally Stream.Free; end;
      end;
      Walk(Child,1);
      Inc(Index); Child:=Child.nextSibling;
    end;
    if Restored and (Warnings.Count<20) then
      Warnings.Add('Составные схемы DOCX сохранены у связанных абзацев. Положение на печатной странице может измениться.');
  end;
  procedure ReadNativeFb3;
  const BodyNamespace = 'http://www.fictionbook.org/FictionBook3/body';
  var Fb3: TFb3Package; Description: IXMLDOMDocument3; Value: IXMLDOMNode; People: IXMLDOMNodeList;
  begin
    Zip:=TZipFile.Create;
    Zip.Open(FileName,zmRead);
    Fb3:=TFb3Package.Create(Zip);
    try
      CurrentPath:=Fb3.Body;
      if CurrentPath='' then raise EReadError.Create('В FB3 не найдена однозначная часть с текстом книги.');
      ReadZip(CurrentPath,Data);
      Document:=XMLDocument(Data);
      Root:=Document.documentElement;
      if (LocalName(Root)<>'fb3-body') or (VarToStr(Root.namespaceURI)<>BodyNamespace) then
        raise EReadError.Create('В FB3 не найден основной текст.');
      if (Fb3.Description<>'') or Fb3.DescriptionDeclared then
      try
        if Fb3.Description='' then raise EReadError.Create('Не найдена часть с описанием книги.');
        ReadZip(Fb3.Description,Data);
        Description:=XMLDocument(Data);
        if LocalName(Description.documentElement)<>'fb3-description' then
          raise EReadError.Create('Некорректная часть с описанием книги.');
        Value:=Description.selectSingleNode('/*/*[local-name()="title"]/*[local-name()="main"]');
        if Assigned(Value) and (Trim(Value.text)<>'') then Title:=Trim(Value.text);
        Value:=Description.selectSingleNode('/*/*[local-name()="lang"]');
        if Assigned(Value) then Language:=Trim(Value.text);
        People:=Description.selectNodes('/*/*[local-name()="fb3-relations"]/*[@link="author"]/*[local-name()="title"]');
        for var I:=0 to People.length-1 do
        begin
          Check;
          var Person:=Trim(People.item[I].text);
          if Person='' then Continue;
          if Author<>'' then Author:=Author+', ';
          Author:=Author+Person;
        end;
      except
        on Error: EAbort do raise;
        on Error: Exception do Warnings.Add('Описание FB3 недоступно. '+Error.Message);
      end;
      try
        Fb3.ReadRelationships('',Fb3ThumbnailRelationship,Paths);
        if Paths.Count=1 then
          for var Cover in Paths.Values do
            if Cover<>'' then MakeRecentCover(ReadFb3Picture(Cover));
      except
        on Error: EAbort do raise;
        on Error: Exception do Warnings.Add('Предпросмотр обложки FB3 недоступен. '+Error.Message);
      end;
      Fb3RelationshipsPresent:=True;
      try Fb3RelationshipsPresent:=Fb3.ReadRelationships(CurrentPath,Fb3ImageRelationship,Paths);
      except
        on Error: EAbort do raise;
        on Error: Exception do Warnings.Add(Error.Message);
      end;
      CollectNotes(Root,'',False);
      Walk(Root,0);
      if FText.Length=0 then raise EReadError.Create('В FB3 нет текста для чтения.');
    finally Fb3.Free; end;
  end;

  procedure AppendWordNotes(Kind: TWordNoteKind; const Heading: string);
  const MissingNote = 'Текст сноски отсутствует в исходном документе.';
  var PartName, Prefix, Preview: string; NoteData: TBytes; NoteDocument: IXMLDOMDocument3;
    Definitions: TDictionary<string,IXMLDOMNode>; Definition: IXMLDOMNode;
    NoteID, First, Missing, CountBefore: Integer; Note: TReaderFootnoteLink;
    ReturnLink: TReaderTextLink; Range: TReaderStyledRange; HeadingWritten: Boolean;
  begin
    PartName:=WordNotePaths[Kind]; Prefix:=WordNoteName[Kind]+':';
    Missing:=0;
    for Note in FNoteLinks do if Note.Target.StartsWith(Prefix) then Inc(Missing);
    if Missing=0 then Exit;
    if (PartName='') or (Zip.IndexOf(PartName)<0) then
    begin
      if Warnings.Count<20 then Warnings.Add(Heading+' DOCX: отсутствует файл с текстом сносок.');
      for Note in FNoteLinks do if Note.Target.StartsWith(Prefix) then StoreNote(Note.Target,MissingNote);
      Exit;
    end;
    try
      ReadZip(PartName,NoteData);
      NoteDocument:=XMLDocument(NoteData);
      ReadWordRelationships(PartName,False);
    except
      on Error: EAbort do raise;
      on Error: Exception do
      begin
        if Warnings.Count<20 then Warnings.Add(Heading+' DOCX: '+Error.Message);
        if not Assigned(NoteDocument) then Exit;
      end;
    end;
    FreeAndNil(WordRenderedDrawings);
    PrepareWordDrawings(NoteDocument.documentElement);
    Definitions:=TDictionary<string,IXMLDOMNode>.Create;
    try
      Definition:=NoteDocument.documentElement.firstChild;
      while Assigned(Definition) do
      begin
        Check;
        if (LocalName(Definition)=WordNoteName[Kind]) and
          MatchText(Attribute(Definition,'type'),['','normal']) and
          TryStrToInt(Attribute(Definition,'id'),NoteID) then Definitions.TryAdd(Prefix+IntToStr(NoteID),Definition);
        Definition:=Definition.nextSibling;
      end;
      HeadingWritten:=False; Missing:=0;
      CurrentPath:=PartName;
      for Note in FNoteLinks do
      begin
        Check;
        if not Note.Target.StartsWith(Prefix) then Continue;
        if FAnchors.ContainsKey(Note.Target) then Continue;
        if not Definitions.TryGetValue(Note.Target,Definition) then
        begin
          if not FNoteBodies.ContainsKey(Note.Target) then Inc(Missing);
          StoreNote(Note.Target,MissingNote);
          Continue;
        end;
        if not HeadingWritten then
        begin
          Paragraph;
          FBody.Append('{\pard\ql\fi0\b\sa120 '); AddText(Heading); Paragraph; FBody.Append('}');
          HeadingWritten:=True; FNotesInBody:=True;
        end;
        FAnchors.Add(Note.Target,FText.Length);
        ReturnLink.Start:=FText.Length; ReturnLink.Target:='ref:'+Note.Target;
        FBody.Append('{\pard\ql\fi0\ul '); AddText(Note.LabelText); FBody.Append('}');
        ReturnLink.Count:=FText.Length-ReturnLink.Start; FLinks.Add(ReturnLink);
        Range:=Default(TReaderStyledRange); Range.Start:=ReturnLink.Start;
        Range.Count:=ReturnLink.Count; Range.Kind:=rbLink; FStyles.Add(Range);
        Paragraph;
        First:=FText.Length; CountBefore:=FImages;
        DocxFieldDepth:=0; DocxInstructionDepth:=0;
        Walk(Definition,0,False,True);
        Preview:=Trim(FText.ToString(First,Min(FText.Length-First,65536)).Replace(#$FFFC,''));
        if Preview<>'' then FNoteBodiesInText.TryAdd(Note.Target,0);
        if (Preview='') and (FImages>CountBefore) then Preview:='В сноске есть иллюстрация.';
        StoreNote(Note.Target,Preview);
      end;
      if (Missing>0) and (Warnings.Count<20) then
        Warnings.Add(Format('%s DOCX: отсутствуют записи (%d).',[Heading,Missing]));
    finally Definitions.Free; end;
  end;

  procedure WalkHTML(const Value: string; const DocumentLocation: string = '');
  var Match, AttributeMatch: TMatch; Token, Name, ActiveHeading, LinkTarget: string;
    Closing, HasCell, CollectLinks: Boolean; HeadingIndex, HeadingLevel, ActiveHeadingLevel, LinkStart: Integer;
    HeadingRange: TReaderStyledRange; Attributes: TRegEx; Link: TReaderTextLink;
    procedure FinishLink;
    begin
      if (LinkTarget<>'') and (LinkStart<FText.Length) and (FLinks.Count<100000) then
      begin
        Link.Start:=LinkStart; Link.Count:=FText.Length-LinkStart; Link.Target:=LinkTarget;
        FLinks.Add(Link);
      end;
      LinkTarget:='';
    end;
    procedure ReadTagAttributes;
    var Anchor, Named, Href, Key, Text, Role, AriaLevel, Classes: string;
    begin
      if CollectLinks and (Name='a') then FinishLink;
      if Closing or not Token.Contains('=') then Exit;
      Anchor:=''; Named:=''; Href:=''; Role:=''; AriaLevel:=''; Classes:='';
      for var Part in Attributes.Matches(Token) do
      begin
        Key:=LowerCase(Part.Groups[1].Value);
        if (Key<>'id') and not ((Name='a') and MatchText(Key,['name','href'])) and
          not ((Name='p') and MatchText(Key,['role','aria-level','class'])) then Continue;
        Text:='';
        for var GroupIndex:=2 to Min(4,Part.Groups.Count-1) do
          if Part.Groups[GroupIndex].Value<>'' then
          begin Text:=TNetEncoding.HTML.Decode(Part.Groups[GroupIndex].Value); Break; end;
        if Key='id' then Anchor:=Text else if Key='name' then Named:=Text else if Key='href' then Href:=Text
        else if Key='role' then Role:=Text else if Key='aria-level' then AriaLevel:=Text else Classes:=Text;
      end;
      if Name='p' then HeadingLevel:=HTMLHeadingLevel(Name,Role,AriaLevel,Classes);
      if not CollectLinks then Exit;
      if Anchor='' then Anchor:=Named;
      if (Anchor<>'') and (Length(Anchor)<=4096) and (FAnchors.Count<100000) then
        FAnchors.TryAdd(Anchor,FText.Length);
      if (DocumentLocation<>'') and Href.StartsWith(DocumentLocation+'#') then
        Href:=Href.Substring(Length(DocumentLocation));
      if Href.StartsWith('#') and (Length(Href)>1) and (Length(Href)<=4097) then
      begin LinkTarget:=Href.Substring(1); LinkStart:=FText.Length; end;
    end;
    procedure FinishHeading;
    begin
      if HeadingIndex<0 then Exit;
      HeadingRange:=FStyles[HeadingIndex]; HeadingRange.Count:=FText.Length-HeadingRange.Start;
      if HeadingRange.Count>0 then
        Chapter(FText.ToString(HeadingRange.Start,HeadingRange.Count),ActiveHeadingLevel-1,HeadingRange.Start);
      FStyles[HeadingIndex]:=HeadingRange; HeadingIndex:=-1; ActiveHeading:='';
      Paragraph; FBody.Append('}');
    end;
  begin
    HeadingIndex:=-1; ActiveHeading:=''; ActiveHeadingLevel:=0; HasCell:=False;
    LinkTarget:=''; LinkStart:=0; CollectLinks:=IsReaderHTML(E) or MatchText(E,['.mht','.mhtml']);
    Attributes:=TRegEx.Create('([^\s=<>/]+)\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))',[roIgnoreCase]);
    for Match in TRegEx.Matches(Value,ReaderHTMLTokenPattern,[roSingleLine,roIgnoreCase]) do
    begin
      Check; Token:=Match.Value;
      if Token.StartsWith('<![CDATA[') then begin AddText(Copy(Token,10,Length(Token)-12)); Continue; end;
      if Token.StartsWith('<!--') or LowerCase(Token).StartsWith('<script') or LowerCase(Token).StartsWith('<style') then Continue;
      if not Token.StartsWith('<') or (Token='<') then begin AddText(TNetEncoding.HTML.Decode(Token)); Continue; end;
      AttributeMatch:=TRegEx.Match(Token,'^</?\s*([a-z0-9]+)',[roIgnoreCase]);
      if not AttributeMatch.Success then Continue;
      Name:=LowerCase(AttributeMatch.Groups[1].Value); Closing:=Token.StartsWith('</');
      HeadingLevel:=HTMLHeadingLevel(Name,'','','');
      if not Closing and (ActiveHeading='p') and
        ((HeadingLevel>0) or MatchText(Name,['p','div','li','tr','pre'])) then FinishHeading;
      if Name='tr' then HasCell:=False;
      if MatchText(Name,['td','th']) and not Closing then
      begin if HasCell then AddText(#9,True); HasCell:=True; end;
      if (Name='p') or (Name='div') or (Name='li') or (Name='tr') or (Name='br') or (Name='pre') then Paragraph;
      if CollectLinks or (Name='p') then ReadTagAttributes;
      if (Name='b') or (Name='strong') then begin if Closing then FBody.Append('\b0 ') else FBody.Append('\b '); end;
      if (Name='i') or (Name='em') then begin if Closing then FBody.Append('\i0 ') else FBody.Append('\i '); end;
      if Closing then
      begin
        if Name=ActiveHeading then FinishHeading;
      end
      else if HeadingLevel>0 then
      begin
        FinishHeading; Paragraph;
        HeadingRange:=Default(TReaderStyledRange); HeadingRange.Start:=FText.Length;
        if HeadingLevel=1 then HeadingRange.Kind:=rbTitle else HeadingRange.Kind:=rbSubtitle;
        HeadingIndex:=FStyles.Count; FStyles.Add(HeadingRange);
        ActiveHeading:=Name; ActiveHeadingLevel:=HeadingLevel;
        FBody.Append('{\pard\qc\b\sa160\sb200 ');
      end;
      if (Name='img') and not Closing then
        HTMLPicture(ReaderHTMLImageSource(Token),ReaderHTMLImageDescription(Token),
          ReaderHTMLAttribute(Token,'width'),ReaderHTMLAttribute(Token,'height'));
    end;
    FinishLink;
    FinishHeading;
  end;

begin
  FPlainRTF:=''; FNativeRTF:=''; FNativePictureOffsets:=nil; FNativeRTFFallback:=False;
  FLayoutInsertions.Clear;
  FNoteBodiesInText.Clear;
  FPictures.Clear; FBody.Clear; FText.Clear; FChapters.Clear; FStyles.Clear; FNoteLinks.Clear; FNoteBodies.Clear; FLinks.Clear; FAnchors.Clear; Warnings.Clear; FImages:=0; FSkippedImages:=0; FPartialDrawingGroups:=0; FHasTables:=False; FNotesInBody:=False;
  FMarginRules.Clear;
  FParagraphShades.Clear;
  FCellColors.Clear;
  FHasCellBackgrounds:=False;
  FreeAndNil(FImageArchiveLock); FImageArchiveName:='';
  UnpackedBytes:=0; UnpackedLimit:=MAX_EPUB_BYTES; NoteCharacters:=0; PendingInitial:=True; Check; E:=LowerCase(ExtractFileExt(FileName)); FormatName:=E.TrimLeft(['.']);
  DocxFieldDepth:=0;
  DocxInstructionDepth:=0;
  WordPageOverlays:=0;
  TableLevel:=0; CellTextStart:=0;
  FCellWidth:=0; FCellInset:=0;
  TableWidthPattern:=TRegEx.Create('(?:^|;)\s*width\s*:\s*(\d+(?:\.\d+)?)%\s*(?:;|$)',[roIgnoreCase]);
  TableLineStylePattern:=TRegEx.Create('(?:^|;)\s*white-space\s*:\s*pre-wrap\s*(?:;|$)',[roIgnoreCase]);
  Title:=ExtractFileName(FileName); Language:=''; Author:=''; RecentCover:=''; Zip:=nil;
  FOpeningCoverEnd:=0; EpubCoverPath:=''; Fb2CoverRef:='';
  CSS:=TReaderCSS.Create; CSSCache:=TDictionary<string,string>.Create; HasFB2Styles:=False;
  CellColorIndexes:=TDictionary<Cardinal,Integer>.Create;
  RequestedEpubStyles:=TList<TEpubStyleSheet>.Create;
  LoadedEpubStyles:=TList<TEpubStyleSheet>.Create;
  ListMarkerBytes:=TDictionary<string,TBytes>.Create;
  Binaries:=TDictionary<string,TFB2PictureData>.Create; Paths:=TDictionary<string,string>.Create;
  Resources:=TDictionary<string,TBytes>.Create; NoteFiles:=TDictionary<string,IXMLDOMDocument3>.Create;
  WordPictureFallbacks:=nil; WordStyleRules:=nil; WordRenderedDrawings:=nil; WordFloatingDrawings:=nil; WordStyles:=nil;
  WordDefaultHidden:=False; WordHasVisibilityStyles:=False;
  WordPictureTemplates:=nil;
  MathPictures:=nil; MathDeadline:=0; MathBytesRemaining:=64*1024*1024;
  MathFormulasRemaining:=256; MathFallback:=False;
  JpegRecoveryDeadline:=0;
  WordSpacerCount:=0;
  WordNoteLabels:=nil; ReadingWordNotes:=False; SkipWordCustomMark:=False;
  WordListDefinitions:=nil; WordLists:=nil; WordListImagePaths:=nil;
  NumericEpubLinks:=nil; DuplicateEpubAnchors:=nil;
  EpubOutlineNodes:=nil; EpubOutlineTargets:=nil; EpubAnchorEnds:=nil;
  SavedQuoteSections:=nil;
  NavigationIDs:=nil; EpubNavigationDocument:=False; EpubFixedLayout:=False;
  try
    if E='.rtf' then begin ReadNativeRTF; Exit; end;
    if IsReaderPlainText(E) then
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
      var Decoded:=DecodeSelectedEncoding(Data,TextEncoding,E<>'.wri');
      if (E<>'.wri') and (TextEncoding=rteCP866) then Decoded:=RestoreDOSListMarkers(Decoded);
      // A trailing DOS end-of-file marker after a newline is not book text.
      if (E<>'.wri') and (Decoded.EndsWith(#13#26) or Decoded.EndsWith(#10#26)) then
        SetLength(Decoded,Length(Decoded)-1);
      AddText(''); FText.Append(Decoded.Replace(#13#10,#13).Replace(#10,#13));
      Check; FPlainRTF:=PlainTextRTF(FText.ToString,Canceled,FStyles); Check; Exit;
    end;
    if (E='.jpg') or (E='.jpeg') or (E='.png') or (E='.gif') or (E='.bmp') or (E='.webp') or (E='.tif') or (E='.tiff') then
    begin ReadDocument(Data); Picture(Data); Exit; end;
    if (E='.mht') or (E='.mhtml') then
    begin
      ReadDocument(Data);
      HTML:=ReadReaderMHTML(Data,Resources,Canceled,@MIME);
      WalkHTML(HTML,MIME.Location);
      ResolveHTMLLinks(Data,True,MIME.CodePage);
      if FText.Length=0 then raise Exception.Create('В MHTML нет текста для чтения.');
      Warnings.Add('MHTML: локальный текст и вложенные изображения; оформление упрощено.'); Exit;
    end;
    if E='.fb3' then
    begin
      ReadNativeFb3;
      Exit;
    end;
    if (E='.docx') or (E='.odt') then
    begin
      Zip:=TZipFile.Create; Zip.Open(FileName,zmRead);
      if E='.docx' then
      begin
        WordPictureFallbacks:=TDictionary<string,TBytes>.Create;
        WordStyleRules:=TDictionary<string,TWordStyle>.Create;
        LoadWordStyles;
        WordThemePath:='word/theme/theme1.xml';
        WordSettingsPath:='word/settings.xml';
        WordNumberingPath:='word/numbering.xml';
        for var Kind:=Low(TWordNoteKind) to High(TWordNoteKind) do
          WordNotePaths[Kind]:='word/'+WordNoteName[Kind]+'s.xml';
        CurrentPath:='word/document.xml';
        ReadWordRelationships(CurrentPath,True);
        Document:=ReadWordDocument;
      end
      else
      begin
        CurrentPath:='content.xml'; ReadZip(CurrentPath,Data); Document:=XMLDocument(Data);
      end;
      Node:=FindNode(Document.documentElement,'body');
      if Node=nil then raise Exception.Create('В документе не найден текст книги.');
      if (E='.docx') and PrepareWordDrawings(Node,True) then Exit;
      if E='.docx' then WalkWordBody(Node) else Walk(Node,0);
      if (E='.docx') and (FNoteLinks.Count>0) then
      begin
        ReadingWordNotes:=True;
        AppendWordNotes(wnFootnote,'Сноски');
        AppendWordNotes(wnEndnote,'Концевые сноски');
      end;
      if WordPageOverlays>0 then
        Warnings.Insert(0,Format('%s (%d).',[ReaderWordPageOverlayWarning,WordPageOverlays]));
      if FText.Length=0 then raise Exception.Create('В документе нет текста для чтения.');
      Exit;
    end;
    if E='.epub' then
    begin
      Zip:=TZipFile.Create; Zip.Open(FileName,zmRead);
      var Total: Int64:=0;
      for I:=0 to Zip.FileCount-1 do
      begin
        Check;
        if Zip.FileInfo[I].UncompressedSize>MAX_SCAN_EPUB_BYTES-Total then
          raise EReadError.Create('EPUB слишком велик для встроенной читалки.');
        Inc(Total,Zip.FileInfo[I].UncompressedSize);
      end;
      if Total>MAX_DOCUMENT_BYTES then
      begin
        // Keep offsets and dimensions in memory. Load image bytes when the
        // picture is visible, and hold the archive stable while it is open.
        FImageArchiveName:=TPath.GetFullPath(FileName);
        FImageArchiveLock:=TFileStream.Create(FImageArchiveName,fmOpenRead or fmShareDenyWrite);
        UnpackedLimit:=MAX_SCAN_EPUB_BYTES;
      end;
      ReadZip('META-INF/container.xml',Data); Document:=XMLDocument(Data);
      Node:=FindNode(Document.documentElement,'rootfile');
      if Node=nil then raise Exception.Create('В EPUB не найден основной документ.');
      PackagePath:=Attribute(Node,'full-path'); ReadZip(PackagePath,Data);
      Document:=XMLDocument(Data,rteAutomatic,nil,Warnings);
      Root:=Document.documentElement; Node:=FindNode(Root,'title'); if Node<>nil then Title:=Node.text;
      Node:=FindNode(Root,'language'); if Node<>nil then Language:=Trim(Node.text);
      var Metadata:=FindNode(Root,'metadata');
      var CoverID:='';
      var FixedLayoutPackage:=False;
      if Assigned(Metadata) then
        for var K:=0 to Metadata.childNodes.length-1 do
        begin
          Item:=Metadata.childNodes.item[K];
          if LocalName(Item)='creator' then
          begin
            var Name:=Trim(Item.text);
            if Name<>'' then
            begin if Author<>'' then Author:=Author+', '; Author:=Author+Name; end;
          end;
          if (LocalName(Item)='meta') and SameText(Attribute(Item,'name'),'cover') then
            CoverID:=Attribute(Item,'content');
          if (LocalName(Item)='meta') and (Attribute(Item,'property')='rendition:layout') and
            (Trim(Item.text)='pre-paginated') then FixedLayoutPackage:=True;
        end;
      Manifest:=FindNode(Root,'manifest'); Spine:=FindNode(Root,'spine');
      if (Manifest=nil) or (Spine=nil) then raise Exception.Create('В EPUB нет порядка чтения.');
      for I:=0 to Manifest.childNodes.length-1 do
      begin
        Item:=Manifest.childNodes.item[I]; if LocalName(Item)<>'item' then Continue;
        Paths.AddOrSetValue(Attribute(Item,'id'),Attribute(Item,'href'));
        if Pos(' nav ',' '+Attribute(Item,'properties')+' ')>0 then
        begin
          if not Assigned(NavigationIDs) then NavigationIDs:=TDictionary<string,Byte>.Create;
          NavigationIDs.TryAdd(Attribute(Item,'id'),0);
        end;
        if (RecentCover='') and (((CoverID<>'') and (Attribute(Item,'id')=CoverID)) or
          (Pos(' cover-image ',' '+Attribute(Item,'properties')+' ')>0)) then
          try
            var Candidate:=ZipPath(PackagePath,Attribute(Item,'href'));
            var CoverIndex:=Zip.IndexOf(Candidate);
            if CoverIndex>=0 then
            begin
              if EpubCoverPath='' then EpubCoverPath:=Candidate;
              if Zip.FileInfo[CoverIndex].UncompressedSize<=4*1024*1024 then
              begin
                Zip.Read(CoverIndex,Data); MakeRecentCover(Data);
                if RecentCover<>'' then EpubCoverPath:=Candidate;
              end;
            end;
          except on E: Exception do RecentCover:=''; end;
      end;
      if Assigned(NavigationIDs) or (Attribute(Spine,'toc')<>'') then
        EpubOutlineNodes:=TDictionary<string,IXMLDOMNode>.Create;
      EpubAnchorEnds:=TDictionary<string,Integer>.Create;
      var MissingSpineEntries:=0;
      var MissingSpineBodies:=0;
      var SpineHasContent:=False;
      for I:=0 to Spine.childNodes.length-1 do
      begin
        Check;
        Item:=Spine.childNodes.item[I]; if LocalName(Item)<>'itemref' then Continue;
        if SameText(Attribute(Item,'linear'),'no') then Continue;
        ID:=Attribute(Item,'idref');
        if not Paths.TryGetValue(ID,CurrentPath) then raise Exception.Create('Не найден раздел EPUB: '+ID);
        EpubNavigationDocument:=Assigned(NavigationIDs) and NavigationIDs.ContainsKey(ID);
        EpubFixedLayout:=FixedLayoutPackage or
          MatchText('rendition:layout-pre-paginated',Attribute(Item,'properties').Split([' ',#9,#13,#10]));
        CurrentPath:=ZipPath(PackagePath,CurrentPath);
        if not EpubNavigationDocument and (Zip.IndexOf(CurrentPath)<0) then
        begin
          Inc(MissingSpineEntries);
          if (FText.Length>0) and (FText.Chars[FText.Length-1]<>#13) then Paragraph;
          FAnchors.TryAdd(CurrentPath+'#',FText.Length);
          AddText('[В архиве EPUB отсутствует раздел «'+CurrentPath+'».]');
          Paragraph;
          Continue;
        end;
        ReadZip(CurrentPath,Data);
        // Some EPUB 2 generators leave only the closing tags in an empty spine item.
        // Preserve its place and TOC target without relaxing parsing of actual content.
        if (Length(Data)<=128) and TRegEx.IsMatch(ReaderDecodeText(Data),
          '\A[ \t\r\n]*</body[ \t\r\n]*>[ \t\r\n]*</html[ \t\r\n]*>[ \t\r\n]*\z',[roIgnoreCase]) then
        begin
          FAnchors.TryAdd(CurrentPath+'#',FText.Length);
          if Warnings.Count<20 then
            Warnings.Add('Исправлена разметка пустого раздела EPUB «'+
              Copy(ExtractFileName(CurrentPath),1,100)+'».');
          Continue;
        end;
        var MissingBody: Boolean;
        Document:=XMLDocument(Data,rteAutomatic,nil,Warnings,CurrentPath,@MissingBody);
        if MissingBody then
        begin
          if EpubNavigationDocument then Continue;
          Inc(MissingSpineBodies);
          var Notice:=ReaderEpubMissingBodyWarning+' «'+Copy(ExtractFileName(CurrentPath),1,100)+'».';
          if Warnings.Count<20 then Warnings.Add(Notice);
          var FragmentTitle:=FindNode(Document.documentElement,'title');
          if Assigned(FragmentTitle) and (Trim(FragmentTitle.text)<>'') then
            Notice:=Notice+' Сохранился фрагмент заголовка «'+Copy(Trim(FragmentTitle.text),1,200)+'».';
          if (FText.Length>0) and (FText.Chars[FText.Length-1]<>#13) then Paragraph;
          FAnchors.TryAdd(CurrentPath+'#',FText.Length);
          AddText('['+Notice+']');
          Paragraph;
          Continue;
        end;
        ApplyEpubStyles(FindNode(Document.documentElement,'head'));
        Node:=FindNode(Document.documentElement,'body');
        if Node<>nil then
        begin
          var Before:=FText.Length;
          ReadEpubMath(Node,Data);
          CollectNotes(Node,CurrentPath+'#',False);
          Walk(Node,0);
          if Assigned(EpubOutlineNodes) then EpubOutlineNodes.Clear;
          if not SpineHasContent and not EpubNavigationDocument then
            SpineHasContent:=FText.ToString(Before,FText.Length-Before).Trim<>'';
        end;
      end;
      if (MissingSpineEntries+MissingSpineBodies>0) and not SpineHasContent then
        raise EReadError.Create('В EPUB отсутствуют главы для чтения.');
      if MissingSpineEntries>0 then
      begin
        Warnings.Insert(0,Format('В архиве EPUB отсутствуют разделы чтения (%d). На их местах показаны отметки.',
          [MissingSpineEntries]));
      end;
      for NoteLink in FNoteLinks do
        if not FNoteBodies.ContainsKey(NoteLink.Target) then
        begin
          Check; I:=Pos('#',NoteLink.Target); if I=0 then Continue;
          CurrentPath:=Copy(NoteLink.Target,1,I-1); ID:=Copy(NoteLink.Target,I+1,MaxInt);
          if Zip.IndexOf(CurrentPath)<0 then Continue;
          try
          if not NoteFiles.TryGetValue(CurrentPath,Document) then
          begin
            // Remember a broken resource as well: repeated references must not reread it.
            NoteFiles.Add(CurrentPath,nil);
            ReadZip(CurrentPath,Data); Document:=XMLDocument(Data,rteAutomatic,nil,Warnings,CurrentPath); NoteFiles[CurrentPath]:=Document;
            CollectNotes(Document.documentElement,CurrentPath+'#',False);
          end;
          if not Assigned(Document) then Continue;
          Node:=NodeWithID(Document.documentElement,ID);
          if (Node=nil) and ID.Contains(#$00A0) then
          begin
            // The note may be outside the spine, so check its own document.
            var Alternative:=ID.Replace(#$00A0,' ');
            var Candidates:=Document.selectNodes('//*[@id]');
            for var CandidateIndex:=0 to Candidates.length-1 do
            begin
              Check;
              var Candidate:=Candidates.item[CandidateIndex];
              if Attribute(Candidate,'id')<>Alternative then Continue;
              if Node<>nil then begin Node:=nil; Break; end;
              Node:=Candidate;
            end;
          end;
          if Assigned(Node) then
          begin
            var Text:=Trim(NoteText(Node));
            StoreNote(NoteLink.Target,Text);
            var Anchor:=EpubSpaceAnchor(NoteLink.Target);
            var AnchorStart, AnchorEnd: Integer;
            if (Text<>'') and FAnchors.TryGetValue(Anchor,AnchorStart) and
              EpubAnchorEnds.TryGetValue(Anchor,AnchorEnd) and (AnchorEnd>AnchorStart) then
            begin
              const InvisibleCharacters = '[\s\x{00AD}\x{FFFC}]+';
              var Authored:=TRegEx.Replace(Text,InvisibleCharacters,'');
              var Visible:=TRegEx.Replace(FText.ToString(AnchorStart,
                Min(AnchorEnd-AnchorStart,4*Length(Text)+512)),InvisibleCharacters,'');
              if (Authored<>'') and Visible.Contains(Authored) then
                FNoteBodiesInText.TryAdd(NoteLink.Target,0);
            end;
          end;
          except
            on Error: EAbort do raise;
            on Error: EMHLComponentRequired do raise;
            on Error: Exception do if Warnings.Count<20 then Warnings.Add('Сноска: '+Error.Message);
          end;
        end;
      ResolveNumericEpubLinks;
      RecoverEpubFragmentLinks(CoverID);
      for var LinkIndex:=0 to FLinks.Count-1 do
      begin
        Check;
        var Link:=FLinks[LinkIndex];
        var Target:=EpubSpaceAnchor(Link.Target);
        if Target=Link.Target then Continue;
        Link.Target:=Target;
        FLinks[LinkIndex]:=Link;
      end;
      LoadEpubOutline;
    end
    else
    begin
      ReadDocument(Data);
      if (E='.fb2') and (TextEncoding=rteAutomatic) then RepairFB2UTF8Declaration(Data);
      try
        if E='.fb2' then Document:=XMLDocument(Data,TextEncoding,Warnings)
        else Document:=XMLDocument(Data,TextEncoding);
      except
        on Error: EMHLComponentRequired do raise;
        on Error: Exception do
        begin
          if E='.fb2' then
          begin
            var Failure:=FB2BinaryFailure(Data);
            if Failure<>'' then raise EReadError.Create(Failure);
          end;
          if not IsReaderHTML(E) then raise;
          if TextEncoding=rteAutomatic then HTML:=DecodeReaderHTML(Data)
          else HTML:=DecodeSelectedEncoding(Data,TextEncoding);
          WalkHTML(HTML);
          ResolveHTMLLinks(Data,True);
          if FText.Length=0 then raise Exception.Create('В HTML нет текста для чтения.');
          Warnings.Add('HTML: показано упрощённое оформление.'); Exit;
        end;
      end;
      Root:=Document.documentElement;
      if E='.fb2' then
      begin
        if LocalName(Root)<>'fictionbook' then raise Exception.Create('Файл не является FB2.');
        var QuoteInfo:=SavedEpubInfo('HomeLibre: EPUB quotation sections v1');
        if Assigned(QuoteInfo) then
        begin
          var QuoteIDs:=VarToStr(QuoteInfo.text);
          if Length(QuoteIDs)<=1024*1024 then
          begin
            SavedQuoteSections:=TDictionary<string,Byte>.Create;
            for var QuoteID in QuoteIDs.Split([' ',#9,#10,#13],TStringSplitOptions.ExcludeEmpty) do
              if Length(QuoteID)<=4096 then SavedQuoteSections.TryAdd(QuoteID,0);
          end;
        end;
        Node:=FindNode(Root,'book-title'); if Node<>nil then Title:=Node.text;
        Node:=FindNode(Root,'lang'); if Node<>nil then Language:=Trim(Node.text);
        for I:=0 to Root.childNodes.length-1 do
        begin
          Node:=Root.childNodes.item[I];
          if (LocalName(Node)='stylesheet') and MatchText(Attribute(Node,'type'),['','text/css']) then
          begin
            CSS.Add(Node.text,'',False);
            HasFB2Styles:=True;
          end;
          if LocalName(Node)='binary' then
          begin
            ID:=Attribute(Node,'id');
            var Candidate:=Default(TFB2PictureData);
            Candidate.Encoded:=Node.text;
            Candidate.MediaType:=Attribute(Node,'content-type');
            if not Binaries.TryGetValue(ID,ExistingBinary) then Binaries.Add(ID,Candidate)
            else if ReaderBinaryArea(Candidate.Encoded)>ReaderBinaryArea(ExistingBinary.Encoded) then
              Binaries[ID]:=Candidate;
          end;
        end;
        var HasBody:=False;
        for I:=0 to Root.childNodes.length-1 do
        begin
          Node:=Root.childNodes.item[I];
          if LocalName(Node)<>'body' then Continue;
          HasBody:=True;
          if MatchText(Attribute(Node,'name'),['notes','comments']) then CollectNotes(Node,'',True);
        end;
        if not HasBody then raise EReadError.Create('В файле FB2/FBD не найдено содержимое книги.');
        // The FB2 cover belongs to description/title-info, outside its body.
        Node:=FindNode(Root,'title-info');
        if Node<>nil then
        begin
          for var K:=0 to Node.childNodes.length-1 do
          begin
            Item:=Node.childNodes.item[K]; if LocalName(Item)<>'author' then Continue;
            var Name:='';
            for var Part in TArray<string>.Create('first-name','middle-name','last-name') do
            begin
              var Value:=FindNode(Item,Part);
              if Assigned(Value) and (Trim(Value.text)<>'') then Name:=Trim(Name+' '+Value.text);
            end;
            if Name='' then
            begin
              var Nickname:=FindNode(Item,'nickname');
              if Assigned(Nickname) then Name:=Trim(Nickname.text);
            end;
            if Name<>'' then
            begin if Author<>'' then Author:=Author+', '; Author:=Author+Name; end;
          end;
          Node:=FindNode(Node,'coverpage');
        end;
        if Node<>nil then
        begin
          var Preview: string;
          if CoverAlreadyInBody(Node,Preview) then
          begin
            if Preview<>'' then
            begin
              Fb2CoverRef:='#'+Preview;
              try MakeRecentCover(ReadFB2Picture(Preview));
              except on E: Exception do RecentCover:=''; end;
            end;
          end
          else
          begin
            var CoverIndex:=FPictures.Count;
            Walk(Node,0);
            if FPictures.Count>CoverIndex then
            begin
              FOpeningCoverEnd:=FText.Length;
              MakeRecentCover(FPictures[CoverIndex].Bytes);
            end;
          end;
        end;
        for I:=0 to Root.childNodes.length-1 do
        begin Node:=Root.childNodes.item[I]; if LocalName(Node)='body' then Walk(Node,0); end;
        LoadSavedEpubOutline;
      end
      else
      begin
        Node:=FindNode(Root,'body'); if Node=nil then Node:=Root; Walk(Node,0);
        if IsReaderHTML(E) then ResolveHTMLLinks(Data,False);
      end;
    end;
    if FText.Length=0 then raise Exception.Create('В документе нет текста для чтения.');
  finally
    NumericEpubLinks.Free; DuplicateEpubAnchors.Free; EpubOutlineNodes.Free; EpubOutlineTargets.Free;
    EpubAnchorEnds.Free; SavedQuoteSections.Free;
    NavigationIDs.Free; MathPictures.Free;
    WordListImagePaths.Free; WordLists.Free; WordListDefinitions.Free;
    WordNoteLabels.Free; WordFloatingDrawings.Free; WordRenderedDrawings.Free; WordPictureTemplates.Free; WordStyleRules.Free; WordPictureFallbacks.Free;
    ListMarkerBytes.Free; CSSCache.Free; CSS.Free; RequestedEpubStyles.Free; LoadedEpubStyles.Free; CellColorIndexes.Free;
    NoteFiles.Free; Resources.Free; Zip.Free; Paths.Free; Binaries.Free;
  end;
end;

function TReaderDocument.Links: TArray<TReaderTextLink>;
begin Result:=FLinks.ToArray; end;

function TReaderDocument.HasLinks: Boolean;
begin Result:=FLinks.Count>0; end;

function TReaderDocument.LinkTargetAt(Position: Integer; out Target: Integer): Boolean;
begin
  Target:=-1; Result:=False;
  for var Link in FLinks do
  begin
    if Link.Start>Position then Break;
    if (Position<Link.Start+Link.Count) and FAnchors.TryGetValue(Link.Target,Target) then Exit(True);
  end;
end;

function TReaderDocument.FootnoteCount: Integer;
var Link: TReaderFootnoteLink;
begin
  Result:=0;
  for Link in FNoteLinks do if FNoteBodies.ContainsKey(Link.Target) then Inc(Result);
end;

function TReaderDocument.HasFootnotes: Boolean;
begin
  Result:=(FNoteLinks.Count>0) and (FNoteBodies.Count>0);
end;

function TReaderDocument.FootnoteAt(Position: Integer; out Start, Count: Integer): string;
begin
  Result:='';
  for var Link in FNoteLinks do
  begin
    if Link.Start>Position then Break;
    if (Position<Link.Start+Link.Count) and FNoteBodies.TryGetValue(Link.Target,Result) then
    begin
      Start:=Link.Start;
      Count:=Link.Count;
      Exit;
    end;
  end;
end;

function TReaderDocument.FootnotesForRange(Start, Finish, MaxCharacters: Integer;
  SkipNotesInText: Boolean): string;
var Link: TReaderFootnoteLink; Text, LabelText, FirstLine: string; Seen: TDictionary<string,Boolean>; P: Integer;
begin
  Result:=''; Seen:=TDictionary<string,Boolean>.Create;
  try
    for Link in FNoteLinks do
    begin
      if Link.Start>=Finish then Break;
      if (Link.Start+Link.Count<=Start) or Seen.ContainsKey(Link.Target) then Continue;
      if SkipNotesInText and FNoteBodiesInText.ContainsKey(Link.Target) then Continue;
      if not FNoteBodies.TryGetValue(Link.Target,Text) or (Text='') then Continue;
      Seen.Add(Link.Target,True);
      LabelText:=Link.LabelText.Trim(['[',']','(',')','.', ' ',#13,#10]);
      // FB2 usually stores the number in a separate title paragraph. The
      // reading footer joins it with the body; one CRLF separates actual notes.
      P:=Pos(#13,Text); if P=0 then P:=Pos(#10,Text);
      if P>0 then
      begin
        FirstLine:=Copy(Text,1,P-1).Trim(['[',']','(',')','.', ' ']);
        if (LabelText<>'') and SameText(FirstLine,LabelText) then Text:=Copy(Text,P+1,MaxInt);
      end;
      Text:=Trim(TRegEx.Replace(Text,'\s+',' '));
      if (LabelText<>'') and (Length(LabelText)<=12) and
        not Text.StartsWith(LabelText+'. ') then Text:=LabelText+'. '+Text;
      if Result<>'' then Result:=Result+#13#10;
      Result:=Result+Text;
      if (MaxCharacters>0) and (Length(Result)>MaxCharacters) then
      begin Result:=Copy(Result,1,MaxCharacters); Break; end;
    end;
  finally Seen.Free; end;
end;

function ReaderPictureBinarySize(const Item: TReaderPicture; LayoutOnly: Boolean): Integer;
begin
  if LayoutOnly then Exit(SizeOf(TBitmapInfoHeader)+4);
  if Item.Monochrome then Result:=SizeOf(TBitmapInfoHeader)+8+((Item.Width+31) div 32)*4*Item.Height
  else Result:=SizeOf(TBitmapInfoHeader)+((Item.Width*3+3) div 4)*4*Item.Height;
end;

function ReaderTableTwips(MaxWidth, Width, Inset: Integer): Integer;
begin
  Result:=Max(15,MulDiv(Max(240,MaxWidth*15),Width,10000)-Inset);
end;

function TReaderDocument.PictureCaptionLength(Index: Integer): Integer;
begin
  Result:=FPictures[Index].CaptionLength;
end;

function TReaderDocument.PictureExtent(Index, MaxWidth, MaxHeight: Integer): TPoint;
var Item: TReaderPicture; Scale: Double; W,H,Available: Integer;
begin
  Item:=FPictures[Index];
  W:=Item.GoalWidth; H:=Item.GoalHeight;
  if W<=0 then W:=Item.Width*15;
  if H<=0 then H:=Item.Height*15;
  if Item.CellWidth>0 then Available:=ReaderTableTwips(MaxWidth,Item.CellWidth,Item.CellInset)
  else Available:=Max(16,MaxWidth)*15;
  if Item.FillWidth then Exit(Point(Available,Min(Item.GoalHeight,Max(16,MaxHeight)*15)));
  if Item.WidthPercentX100>0 then
    Scale:=Min(MulDiv(Available,Item.WidthPercentX100,10000)/W,Max(16,MaxHeight)*15/H)
  else
    Scale:=Min(1.0,Min(Available/W,Max(16,MaxHeight)*15/H));
  Result:=Point(Max(1,Round(W*Scale)),Max(1,Round(H*Scale)));
end;

function TReaderDocument.PictureHeader(Index, MaxWidth, MaxHeight: Integer; LayoutOnly: Boolean): UTF8String;
var Item: TReaderPicture; Extent: TPoint; W,H: Integer;
begin
  Item:=FPictures[Index]; W:=Item.Width; H:=Item.Height;
  Extent:=PictureExtent(Index,MaxWidth,MaxHeight);
  if LayoutOnly then begin W:=1; H:=1; end;
  Result:=UTF8String('{\pict\dibitmap0\picw'+IntToStr(W)+'\pich'+IntToStr(H)+
    '\picwgoal'+IntToStr(Extent.X)+'\pichgoal'+IntToStr(Extent.Y)+
    '\bin'+IntToStr(ReaderPictureBinarySize(Item,LayoutOnly))+' ');
end;

function DrawScaledWordCanvas(const Graphic: TGraphic; Target: TBitmap; const Bounds: TRect): Boolean;
type
  TSample = record
    First, Second, Weight: Integer;
  end;
var PNG: TPngImage; XSamples: TArray<TSample>; Vertical, Horizontal: TSample;
  Row, Top, Bottom, TopAlpha, BottomAlpha: PByteArray;
  X, Y, Channel, X0, X1, Destination: Integer;
  function Sample(Position, SourceSize, OutputSize: Integer): TSample;
  var Numerator, Denominator: Int64;
  begin
    // Work in pixel centres and use the same fixed-point filter on Win32 and Win64.
    Numerator:=Int64(2*Position+1)*SourceSize-OutputSize;
    Denominator:=Int64(OutputSize)*2;
    if Numerator<=0 then Exit(Default(TSample));
    Result.First:=Min(SourceSize-1,Integer(Numerator div Denominator));
    Result.Second:=Min(SourceSize-1,Result.First+1);
    Result.Weight:=Integer(((Numerator mod Denominator)*256+Denominator div 2) div Denominator);
  end;
  function OnWhite(Value, Alpha: Integer): Integer;
  begin Result:=(Value*Alpha+255*(255-Alpha)+127) div 255; end;
  function Mix(First, Second, Weight: Integer): Integer;
  begin Result:=(First*(256-Weight)+Second*Weight+128) shr 8; end;
begin
  Result:=False;
  if not (Graphic is TPngImage) or (Target.PixelFormat<>pf24bit) then Exit;
  PNG:=TPngImage(Graphic);
  if (PNG.Header.ColorType<>COLOR_RGBALPHA) or (PNG.Header.BitDepth<>8) or
    (Bounds.Left<>0) or (Bounds.Top<>0) or (Bounds.Width<>Target.Width) or (Bounds.Height<>Target.Height) or
    ((PNG.Width=Target.Width) and (PNG.Height=Target.Height)) then Exit;
  SetLength(XSamples,Target.Width);
  for X:=0 to Target.Width-1 do XSamples[X]:=Sample(X,PNG.Width,Target.Width);
  for Y:=0 to Target.Height-1 do
  begin
    Vertical:=Sample(Y,PNG.Height,Target.Height);
    Top:=PNG.Scanline[Vertical.First]; Bottom:=PNG.Scanline[Vertical.Second];
    TopAlpha:=PNG.AlphaScanline[Vertical.First]; BottomAlpha:=PNG.AlphaScanline[Vertical.Second];
    Row:=Target.ScanLine[Y];
    for X:=0 to Target.Width-1 do
    begin
      Horizontal:=XSamples[X];
      X0:=Horizontal.First*3; X1:=Horizontal.Second*3; Destination:=X*3;
      for Channel:=0 to 2 do
        Row[Destination+Channel]:=Byte(Mix(
          Mix(OnWhite(Top[X0+Channel],TopAlpha[Horizontal.First]),
              OnWhite(Top[X1+Channel],TopAlpha[Horizontal.Second]),Horizontal.Weight),
          Mix(OnWhite(Bottom[X0+Channel],BottomAlpha[Horizontal.First]),
              OnWhite(Bottom[X1+Channel],BottomAlpha[Horizontal.Second]),Horizontal.Weight),Vertical.Weight));
    end;
  end;
  Result:=True;
end;

function TReaderDocument.PictureUsesBackground(Index: Integer): Boolean;
begin
  Result:=FPictures[Index].MatchBookBackground;
end;

function TReaderDocument.PictureRTF(Index, MaxWidth, MaxHeight: Integer; LayoutOnly: Boolean;
  Background: TColor): UTF8String;
var Item: TReaderPicture; Header: UTF8String; At, Pitch, Y, CanvasState: Integer;
  Bounds: TRect;
  Stream: TStream; Graphic: TGraphic; Bitmap: TBitmap; Info: TBitmapInfoHeader;
  MonoColors: array[0..1] of TRGBQuad; WhitePixel: Cardinal;
  procedure AppendBytes(const Buffer; Count: Integer);
  begin if Count>0 then begin Move(Buffer,Result[At],Count); Inc(At,Count); end; end;
begin
  Item:=FPictures[Index];
  if not Item.MatchBookBackground then Background:=clWhite;
  if Item.Unreadable then LayoutOnly:=True;
  Header:=PictureHeader(Index,MaxWidth,MaxHeight,LayoutOnly);
  SetLength(Result,Length(Header)+ReaderPictureBinarySize(Item,LayoutOnly)+1);
  At:=1; AppendBytes(Header[1],Length(Header));
  if LayoutOnly then
  begin
    // Keep each object's exact display extent, without decoding its source.
    // The real picture replaces this one-pixel object only while visible.
    FillChar(Info,SizeOf(Info),0); Info.biSize:=SizeOf(Info);
    Info.biWidth:=1; Info.biHeight:=1; Info.biPlanes:=1; Info.biBitCount:=24;
    Info.biSizeImage:=4;
    var RGBBackground:=ColorToRGB(Background);
    WhitePixel:=Cardinal(GetBValue(RGBBackground)) or (Cardinal(GetGValue(RGBBackground)) shl 8) or
      (Cardinal(GetRValue(RGBBackground)) shl 16);
    AppendBytes(Info,SizeOf(Info)); AppendBytes(WhitePixel,4);
  end
  else
  begin
    try
      if Item.ArchiveMember<>'' then
      begin
        var Archive:=TZipFile.Create;
        try
          Archive.Open(FImageArchiveName,zmRead);
          Archive.Read(Item.ArchiveMember,Item.Bytes);
        finally Archive.Free; end;
      end;
      Stream:=nil; Graphic:=nil; Bitmap:=TBitmap.Create;
      try
        if Item.OfficeImage then Graphic:=CreatePackageCoverGraphic(Item.Bytes,256*1024*1024)
        else
        begin
          Stream:=TBytesStream.Create(Item.Bytes);
          Graphic:=CreateGraphicFromStream(Stream);
        end;
        if not Assigned(Graphic) then raise Exception.Create('Не удалось прочитать изображение.');
        Bounds:=Item.PaintBounds;
        if Bounds.IsEmpty then Bounds:=Rect(0,0,Item.Width,Item.Height);
        if Graphic is TJPEGImage then
        begin
          // Decode at the nearest JPEG scale that still covers the existing
          // display bitmap. Keep original compressed bytes for later reflow.
          if (Graphic.Width>=Bounds.Width*8) and (Graphic.Height>=Bounds.Height*8) then TJPEGImage(Graphic).Scale:=jsEighth
          else if (Graphic.Width>=Bounds.Width*4) and (Graphic.Height>=Bounds.Height*4) then TJPEGImage(Graphic).Scale:=jsQuarter
          else if (Graphic.Width>=Bounds.Width*2) and (Graphic.Height>=Bounds.Height*2) then TJPEGImage(Graphic).Scale:=jsHalf;
        end;
        if Item.Monochrome then Bitmap.PixelFormat:=pf1bit
        else Bitmap.PixelFormat:=pf24bit;
        Bitmap.SetSize(Item.Width,Item.Height);
        Bitmap.Canvas.Brush.Color:=Background; Bitmap.Canvas.FillRect(Rect(0,0,Item.Width,Item.Height));
        if Item.RuleBounds.IsEmpty then
        begin
          if not Item.WordCanvas or not DrawScaledWordCanvas(Graphic,Bitmap,Bounds) then
            Bitmap.Canvas.StretchDraw(Bounds,Graphic);
        end
        else
        begin
          CanvasState:=SaveDC(Bitmap.Canvas.Handle);
          if CanvasState=0 then RaiseLastOSError;
          try
            with Item.PaintClip do IntersectClipRect(Bitmap.Canvas.Handle,Left,Top,Right,Bottom);
            Bitmap.Canvas.StretchDraw(Bounds,Graphic);
          finally RestoreDC(Bitmap.Canvas.Handle,CanvasState); end;
          Bitmap.Canvas.Brush.Color:=TColor(Item.RuleColor);
          Bitmap.Canvas.FillRect(Item.RuleBounds);
        end;
        FillChar(Info,SizeOf(Info),0); Info.biSize:=SizeOf(Info); Info.biWidth:=Item.Width;
        Info.biHeight:=Item.Height; Info.biPlanes:=1; Info.biCompression:=BI_RGB;
        if Item.Monochrome then
        begin
          Info.biBitCount:=1; Info.biClrUsed:=2;
          Pitch:=((Item.Width+31) div 32)*4;
          if GetDIBColorTable(Bitmap.Canvas.Handle,0,2,MonoColors)<>2 then
            raise Exception.Create('Не удалось прочитать палитру чёрно-белого изображения.');
        end
        else
        begin
          Info.biBitCount:=24;
          Pitch:=((Item.Width*3+3) div 4)*4;
        end;
        Info.biSizeImage:=Pitch*Item.Height;
        AppendBytes(Info,SizeOf(Info));
        if Item.Monochrome then AppendBytes(MonoColors,SizeOf(MonoColors));
        for Y:=Item.Height-1 downto 0 do AppendBytes(Bitmap.ScanLine[Y]^,Pitch);
      finally Bitmap.Free; Graphic.Free; Stream.Free; end;
    except
      on E: EAbort do raise;
      on E: EMHLComponentRequired do raise;
      on E: Exception do
      begin
        Item.Bytes:=nil;
        Item.Unreadable:=True;
        FPictures[Index]:=Item;
        NoteUnreadableImage(E.Message);
        Exit(PictureRTF(Index,MaxWidth,MaxHeight,True,Background));
      end;
    end;
  end;
  Result[At]:='}'; Inc(At);
  Assert(At=Length(Result)+1,'Reader picture RTF length differs');
end;

function TReaderDocument.RTF(MaxPictureWidth, MaxPictureHeight: Integer; LayoutOnly: Boolean;
  Background: TColor; const CellColor: TFunc<TColor,TColor>): UTF8String;
var Header, Fragment, ColorTable: UTF8String;
  At, Start, I, Index: Integer; Total: Int64;
  function CellBoundary(const Insertion: TLayoutInsertion): UTF8String;
  begin
    var Available:=ReaderTableTwips(MaxPictureWidth,Insertion.CellWidth,Insertion.CellInset);
    Result:=UTF8String('\cellx'+IntToStr(Max(1,MulDiv(Available,Insertion.Value,10000)))+' ');
  end;
  procedure AppendBody(First, Finish: Integer);
  begin
    for var K:=First to Finish-1 do
    begin Assert(Ord(FBody.Chars[K])<=255); Result[At]:=AnsiChar(FBody.Chars[K]); Inc(At); end;
  end;
  procedure AppendBytes(const Buffer; Count: Integer);
  begin if Count>0 then begin Move(Buffer,Result[At],Count); Inc(At,Count); end; end;
  function TablePalette: UTF8String;
  var Colors: TStringBuilder; Value: TColor;
  begin
    Result:='';
    if FCellColors.Count=0 then Exit;
    Colors:=TStringBuilder.Create;
    try
      Colors.Append('{\colortbl ;');
      for var Entry in FCellColors do
      begin
        Value:=Entry.Color;
        if Entry.ForBackground and Assigned(CellColor) then Value:=ColorToRGB(CellColor(Value));
        Colors.Append('\red').Append(Integer(GetRValue(Value))).Append('\green').Append(Integer(GetGValue(Value)))
          .Append('\blue').Append(Integer(GetBValue(Value))).Append(';');
      end;
      Result:=UTF8String(Colors.Append('}').ToString);
    finally Colors.Free; end;
  end;
begin
  if FPlainRTF<>'' then Exit(FPlainRTF);
  if FNativeRTF<>'' then
  begin
    Total:=Length(FNativeRTF);
    for I:=0 to High(FNativePictureOffsets) do
    begin
      Header:=PictureHeader(I,MaxPictureWidth,MaxPictureHeight,LayoutOnly);
      Inc(Total,Length(Header)+ReaderPictureBinarySize(FPictures[I],LayoutOnly)+1);
    end;
    if Total>256*1024*1024 then raise EReadError.Create('Изображения книги требуют слишком много памяти для читалки.');
    SetLength(Result,Integer(Total));
    At:=1; Start:=0;
    for I:=0 to High(FNativePictureOffsets) do
    begin
      Index:=FNativePictureOffsets[I];
      if Index>Start then AppendBytes(FNativeRTF[Start+1],Index-Start);
      Fragment:=PictureRTF(I,MaxPictureWidth,MaxPictureHeight,LayoutOnly,Background);
      AppendBytes(Fragment[1],Length(Fragment));
      Start:=Index;
    end;
    if Length(FNativeRTF)>Start then AppendBytes(FNativeRTF[Start+1],Length(FNativeRTF)-Start);
    SetLength(Result,At-1);
    Exit;
  end;
  // Cell widths and pictures are recorded while writing the body. Emit them
  // without duplicating the full UTF-16 body or scanning it with a regex.
  ColorTable:=TablePalette;
  Total:=Int64(Length(READER_RTF_HEADER))+Length(ColorTable)+FBody.Length+1;
  for var Insertion in FLayoutInsertions do
  begin
    if Insertion.IsPicture then
    begin
      Index:=Insertion.Value;
      Header:=PictureHeader(Index,MaxPictureWidth,MaxPictureHeight,LayoutOnly);
      Inc(Total,Length(Header)+ReaderPictureBinarySize(FPictures[Index],LayoutOnly)+1);
    end
    else Inc(Total,Length(CellBoundary(Insertion)));
  end;
  if ((FImages<>0) or FHasTables) and (Total>256*1024*1024) then
    raise EReadError.Create('Изображения книги требуют слишком много памяти для читалки.');
  SetLength(Result,Integer(Total)); At:=1;
  AppendBytes(READER_RTF_HEADER[1],Length(READER_RTF_HEADER));
  if ColorTable<>'' then AppendBytes(ColorTable[1],Length(ColorTable));
  Start:=0;
  for var Insertion in FLayoutInsertions do
  begin
    Assert(Insertion.Offset>=Start);
    AppendBody(Start,Insertion.Offset);
    if Insertion.IsPicture then
      Fragment:=PictureRTF(Insertion.Value,MaxPictureWidth,MaxPictureHeight,LayoutOnly,Background)
    else Fragment:=CellBoundary(Insertion);
    AppendBytes(Fragment[1],Length(Fragment)); Start:=Insertion.Offset;
  end;
  AppendBody(Start,FBody.Length);
  Result[At]:='}'; Inc(At);
  Assert(At=Length(Result)+1,'Reader binary RTF length differs');
end;

procedure TReaderDocument.ReleasePlainText;
begin
  FText.Clear;
end;

procedure TReaderDocument.ReleaseUnusedBuffers;
begin
  FPlainRTF:='';
  ReleasePlainText;
  if not FHasTables then
  begin
    FNativeRTF:=''; FNativePictureOffsets:=nil;
    FLayoutInsertions.Clear;
    FreeAndNil(FBody); FBody:=TStringBuilder.Create;
  end;
end;

function TReaderDocument.PlainText: string;
begin Result:=FText.ToString; end;

function TReaderDocument.Chapters: TArray<TReaderChapter>;
begin Result:=FChapters.ToArray; end;

function TReaderDocument.Styles: TArray<TReaderStyledRange>;
begin Result:=FStyles.ToArray; end;

function TReaderDocument.HasMarginRules: Boolean;
begin Result:=FMarginRules.Count>0; end;

function TReaderDocument.HasCellBackgrounds: Boolean;
begin Result:=FHasCellBackgrounds; end;

function TReaderDocument.MarginRules(Start, Finish: Integer): TArray<TReaderMarginRule>;
var Count: Integer;
begin
  SetLength(Result,FMarginRules.Count); Count:=0;
  for var Rule in FMarginRules do
    if (Rule.Position>=Start) and (Rule.Position<Finish) then
    begin
      Result[Count]:=Rule;
      Inc(Count);
    end;
  SetLength(Result,Count);
end;

function TReaderDocument.ParagraphShades(Start, Finish: Integer): TArray<TReaderParagraphShade>;
var Count: Integer;
begin
  Result:=nil; Count:=0;
  for var Shade in FParagraphShades do
    if (Shade.Start<Finish) and (Shade.Finish>Start) then
    begin
      if Count=Length(Result) then SetLength(Result,Max(8,2*Count));
      Result[Count]:=Shade; Inc(Count);
    end;
  SetLength(Result,Count);
end;

end.
