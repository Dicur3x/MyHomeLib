unit unit_ReaderCSS;

interface

uses System.SysUtils, System.Generics.Collections;

type
  TReaderCSSRule = record
    Selector, PreviousSelector, Declarations, Base: string;
    Specificity: Integer;
    ListImages: Boolean;
  end;
  TReaderCellSide = (rcTop, rcRight, rcBottom, rcLeft);
  TReaderCellBorder = record
    Style, Color: string;
    Width: Integer;
  end;
  TReaderCellStyle = record
    Background: string;
    Padding: array[TReaderCellSide] of Integer;
    Borders: array[TReaderCellSide] of TReaderCellBorder;
    HasBorders: Boolean;
  end;
  TReaderCSSValue = record
    Code, FontSize, ListImage, ListImageBase: string;
    Cell: TReaderCellStyle;
  end;
  // A bounded local stylesheet subset for the reflow reader. Unsupported
  // browser-only layout never hides, transforms or removes book text.
  TReaderCSS = class
  private
    FRules: TList<TReaderCSSRule>;
    FCache: TDictionary<string,TReaderCSSValue>;
    FSvgStyleLength: Integer;
    FCompleteSvgRules, FCoverPageRulesSafe, FHasAdjacentRules: Boolean;
    function Matches(const Selector, Tag, Classes, ID: string): Boolean;
    function Compile(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses, PreviousID: string;
      out FontSize, ListImage, ListImageBase: string; out Cell: TReaderCellStyle): string;
    function Resolve(const Tag, Classes, ID, InlineStyle: string;
      const PreviousTag: string = ''; const PreviousClasses: string = ''; const PreviousID: string = ''): TReaderCSSValue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Add(const CSS: string; const Base: string = ''; ListImages: Boolean = True);
    function RTF(const Tag, Classes, ID, InlineStyle: string;
      const PreviousTag: string = ''; const PreviousClasses: string = ''; const PreviousID: string = ''): string;
    function FontPercent(const Tag, Classes, ID, InlineStyle: string; InheritedPercent: Integer;
      const PreviousTag: string = ''; const PreviousClasses: string = ''; const PreviousID: string = ''): Integer;
    function ListImage(const Tag, Classes, ID, InlineStyle: string; out Base: string): string;
    function CellStyle(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses, PreviousID: string): TReaderCellStyle;
    function PreservesSvgViewport(const Tag, Classes, ID, InlineStyle: string): Boolean;
    function PreservesSvgCoverRatio(const Tag, Classes, ID: string): Boolean;
    property CompleteSvgRules: Boolean read FCompleteSvgRules;
    property HasAdjacentRules: Boolean read FHasAdjacentRules;
  end;

implementation

uses System.Classes, System.StrUtils, System.Math, System.RegularExpressions;

const CSSQuoted = '"(?:\\(?:\r\n|.)|[^"\\\r\n\f])*"|''(?:\\(?:\r\n|.)|[^''\\\r\n\f])*''';
  CSSCellSide: array[TReaderCellSide] of string = ('top','right','bottom','left');
  CSSCellLength = '(?:0|(?:\d+(?:\.\d+)?|\.\d+)(?:px|pt|in|cm|mm|pc|em|rem|ex|ch|%))';
  CSSCellBorderWidth = '(?:thin|medium|thick|0|(?:\d+(?:\.\d+)?|\.\d+)(?:px|pt|in|cm|mm|pc))';
  CSSBorderPart: array[0..2] of string = ('width','style','color');
  CSSSideToken: array[1..4,TReaderCellSide] of Integer =
    ((0,0,0,0),(0,1,0,1),(0,1,2,1),(0,1,2,3));

function CellBorderColor(const Value: string): string;
const Names: array[0..15] of string = ('black','silver','gray','white','maroon','red','purple','fuchsia',
  'green','lime','olive','yellow','navy','blue','teal','aqua');
  Colors: array[0..15] of string = ('#000000','#c0c0c0','#808080','#ffffff','#800000','#ff0000','#800080','#ff00ff',
    '#008000','#00ff00','#808000','#ffff00','#000080','#0000ff','#008080','#00ffff');
begin
  Result:='';
  if MatchText(Value,['transparent','currentcolor']) or
    TRegEx.IsMatch(Value,'\A#[a-f0-9]{3}(?:[a-f0-9]{3})?\z') then Exit(Value);
  var Index:=IndexText(Value,Names);
  if Index>=0 then Exit(Colors[Index]);
  var Match:=TRegEx.Match(Value,'\Argb\(\s*(\d{1,3})(?:\s*,\s*|\s+)(\d{1,3})(?:\s*,\s*|\s+)(\d{1,3})\s*\)\z');
  if not Match.Success then Exit;
  Result:='#';
  for Index:=1 to 3 do
    Result:=Result+IntToHex(Min(255,StrToInt(Match.Groups[Index].Value)),2);
end;

constructor TReaderCSS.Create;
begin inherited; FRules:=TList<TReaderCSSRule>.Create; FCache:=TDictionary<string,TReaderCSSValue>.Create;
  FCompleteSvgRules:=True; FCoverPageRulesSafe:=True; end;

destructor TReaderCSS.Destroy;
begin FCache.Free; FRules.Free; inherited; end;

procedure TReaderCSS.Clear;
begin
  FRules.Clear; FCache.Clear; FSvgStyleLength:=0;
  FCompleteSvgRules:=True; FCoverPageRulesSafe:=True; FHasAdjacentRules:=False;
end;

function SvgCoverDeclarationsSafe(const Tag, Declarations: string): Boolean;
const EdgeLength = '(?:0|[0-9]+(?:\.[0-9]+)?(?:px|pt))';
  Zero = '0(?:\.0+)?(?:px|pt)?';
var At: Integer; Key, Value: string;
begin
  for var Entry in Declarations.Split([';'],TStringSplitOptions.ExcludeEmpty) do
  begin
    if Entry.Trim='' then Continue;
    At:=Pos(':',Entry);
    if At=0 then Exit(False);
    Key:=LowerCase(Trim(Copy(Entry,1,At-1)));
    Value:=LowerCase(Trim(Copy(Entry,At+1,MaxInt)));
    if Tag='svg' then
    begin
      if not ((MatchText(Key,['width','height']) and MatchText(Value,['auto','100%'])) or
        ((Key='display') and MatchText(Value,['block','inline','inline-block']))) then Exit(False);
      Continue;
    end;
    if Tag='image' then Exit(False);
    if TRegEx.IsMatch(Key,'\Amargin(?:-top|-right|-bottom|-left)?\z') then
    begin
      if not TRegEx.IsMatch(Value,'\A(?:'+EdgeLength+'|auto)(?:\s+(?:'+EdgeLength+'|auto)){0,3}\z') then Exit(False);
    end
    else if TRegEx.IsMatch(Key,'\Apadding(?:-top|-right|-bottom|-left)?\z') then
    begin
      if not TRegEx.IsMatch(Value,'\A'+Zero+'(?:\s+'+Zero+'){0,3}\z') then Exit(False);
    end
    else if not ((Tag<>'@page') and (((Key='display') and (Value='block')) or
      ((Key='text-align') and (Value='center')) or ((Key='font-size') and (Value='1em')))) then Exit(False);
  end;
  Result:=True;
end;

procedure TReaderCSS.Add(const CSS, Base: string; ListImages: Boolean);
const SimpleSelector = '(?:\*|[a-zA-Z][a-zA-Z0-9-]*)?(?:[.#][a-zA-Z_][a-zA-Z0-9_-]*)*';
var Text, Selector, RawSelector, Declarations: string; Start, Open, Finish: Integer;
  Adjacent: TMatch; Rule: TReaderCSSRule; HasNestedRules: Boolean;
  function ClosingBrace(Opening: Integer; out Nested: Boolean): Integer;
  var Depth, Position: Integer; Quote, C: Char;
  begin
    Depth:=1; Quote:=#0; Position:=Opening+1; Nested:=False;
    while Position<=Length(Text) do
    begin
      C:=Text[Position];
      if C='\' then Inc(Position)
      else if Quote<>#0 then
      begin
        if C=Quote then Quote:=#0;
      end
      else if (C=#39) or (C='"') then Quote:=C
      else if C='{' then begin Inc(Depth); Nested:=True; end
      else if C='}' then
      begin
        Dec(Depth);
        if Depth=0 then Exit(Position);
      end;
      Inc(Position);
    end;
    Result:=0;
  end;
  function Specificity(const Value: string): Integer;
  begin
    Result:=0;
    if Value='' then Exit;
    if not CharInSet(Value[1],['.','#','*']) then Inc(Result);
    for var C in Value do
      if C='#' then Inc(Result,100)
      else if C='.' then Inc(Result,10);
  end;
begin
  if Length(CSS)>1024*1024 then
  begin
    FCompleteSvgRules:=False;
    Exit;
  end;
  // Do not interpret a comment marker inside a quoted value as CSS markup.
  var UnquotedStart:=1;
  var Cleaned:=TStringBuilder.Create;
  try
    for var Token in TRegEx.Matches(CSS,'/\*.*?\*/|'+CSSQuoted,[roSingleLine]) do
    begin
      Cleaned.Append(Copy(CSS,UnquotedStart,Token.Index-UnquotedStart));
      if Token.Value.StartsWith('/*') then Cleaned.Append(' ') else Cleaned.Append(Token.Value);
      UnquotedStart:=Token.Index+Token.Length;
    end;
    Cleaned.Append(Copy(CSS,UnquotedStart,MaxInt));
    Text:=Cleaned.ToString;
  finally Cleaned.Free; end;
  if FCompleteSvgRules then
  begin
    Inc(FSvgStyleLength,Length(CSS));
    FCompleteSvgRules:=(FSvgStyleLength<=65536) and
      not TRegEx.IsMatch(TRegEx.Replace(Text,CSSQuoted,' ',[roSingleLine]),'[\\"''\x{fffd}]');
  end;
  Start:=1;
  while (Start<=Length(Text)) and (FRules.Count<4096) do
  begin
    Open:=PosEx('{',Text,Start); if Open=0 then Break;
    Finish:=ClosingBrace(Open,HasNestedRules); if Finish=0 then Break;
    Declarations:=Copy(Text,Open+1,Finish-Open-1);
    if HasNestedRules then
    begin
      FCompleteSvgRules:=False;
      Start:=Finish+1;
      Continue;
    end;
    for RawSelector in Copy(Text,Start,Open-Start).Split([',']) do
    begin
      if FRules.Count>=4096 then Break;
      Selector:=RawSelector.Trim;
      if SameText(Selector,'@page') then FCoverPageRulesSafe:=FCoverPageRulesSafe and SvgCoverDeclarationsSafe('@page',Declarations)
      else if FCompleteSvgRules and ((Selector='') or not TRegEx.IsMatch(Selector,'\A'+SimpleSelector+'\z')) then
        FCompleteSvgRules:=False;
      if (Selector='') or (Length(Selector)>256) then Continue;
      Rule.PreviousSelector:='';
      if Pos('+',Selector)>0 then
      begin
        Adjacent:=TRegEx.Match(Selector,'\A('+SimpleSelector+')\s*\+\s*('+SimpleSelector+')\z');
        if not Adjacent.Success or (Adjacent.Groups[1].Value='') or (Adjacent.Groups[2].Value='') then Continue;
        Rule.PreviousSelector:=Adjacent.Groups[1].Value;
        Selector:=Adjacent.Groups[2].Value;
        FHasAdjacentRules:=True;
      end
      else if (Pos('@',Selector)>0) or TRegEx.IsMatch(Selector,'[\s>~:\[\]\\]') then Continue;
      Rule.Selector:=Selector; Rule.Declarations:=Declarations;
      Rule.Specificity:=Specificity(Selector)+Specificity(Rule.PreviousSelector);
      Rule.Base:=Base; Rule.ListImages:=ListImages;
      FRules.Add(Rule);
    end;
    Start:=Finish+1;
  end;
  if (FRules.Count>=4096) or (Copy(Text,Start,MaxInt).Trim<>'') then FCompleteSvgRules:=False;
  FCache.Clear;
end;

function TReaderCSS.Matches(const Selector, Tag, Classes, ID: string): Boolean;
var I, Start: Integer; Kind: Char; Name: string; Found: Boolean;
begin
  Result:=False; I:=1;
  while (I<=Length(Selector)) and not CharInSet(Selector[I],['.','#']) do Inc(I);
  Name:=Copy(Selector,1,I-1);
  if (Name<>'') and (Name<>'*') and not SameText(Name,Tag) then Exit;
  while I<=Length(Selector) do
  begin
    Kind:=Selector[I]; Inc(I); Start:=I;
    while (I<=Length(Selector)) and not CharInSet(Selector[I],['.','#']) do Inc(I);
    Name:=Copy(Selector,Start,I-Start); if Name='' then Exit;
    if Kind='#' then begin if Name<>ID then Exit; end
    else
    begin
      Found:=False;
      for var C in Classes.Split([' ',#9,#13,#10],TStringSplitOptions.ExcludeEmpty) do
        if C=Name then begin Found:=True; Break; end;
      if not Found then Exit;
    end;
  end;
  Result:=True;
end;

function TReaderCSS.PreservesSvgViewport(const Tag, Classes, ID, InlineStyle: string): Boolean;
  function SizingOnly(const Declarations: string): Boolean;
  var At: Integer; Key, Value: string;
  begin
    for var Entry in Declarations.Split([';'],TStringSplitOptions.ExcludeEmpty) do
    begin
      if Entry.Trim='' then Continue;
      At:=Pos(':',Entry); if At=0 then Exit(False);
      Key:=LowerCase(Copy(Entry,1,At-1).Trim);
      Value:=LowerCase(Copy(Entry,At+1,MaxInt).Trim);
      if (Tag<>'svg') or (not MatchText(Key,['width','height','max-width','max-height']) and
        not ((Key='display') and MatchText(Value,['block','inline','inline-block']))) then Exit(False);
    end;
    Result:=True;
  end;
begin
  if not SizingOnly(InlineStyle) then Exit(False);
  for var Rule in FRules do
    if Matches(Rule.Selector,Tag,Classes,ID) and not SizingOnly(Rule.Declarations) then Exit(False);
  Result:=True;
end;

function TReaderCSS.PreservesSvgCoverRatio(const Tag, Classes, ID: string): Boolean;
begin
  if not FCompleteSvgRules or not FCoverPageRulesSafe then Exit(False);
  for var Rule in FRules do
    if Matches(Rule.Selector,Tag,Classes,ID) and not SvgCoverDeclarationsSafe(Tag,Rule.Declarations) then Exit(False);
  Result:=True;
end;

function TReaderCSS.Compile(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses, PreviousID: string;
  out FontSize, ListImage, ListImageBase: string; out Cell: TReaderCellStyle): string;
var Values: TDictionary<string,string>; Priorities: TDictionary<string,Int64>;
  Rule: TReaderCSSRule; I: Integer; Value, Image, ImageBase: string;
  ImagePriority: Int64;
  IsCell: Boolean;
  procedure Merge(const Text, Base: string; Specificity, Order: Integer; UseListImages: Boolean);
  var Part, Key, Value, Raw, Candidate: string; Colon: Integer; Priority, Old: Int64; URL: TMatch;
    procedure MergeTableStyle;
    var Declaration, PropertyName, Fill: string; Start, Depth, Separator: Integer; Rank: Int64;
      procedure Apply(const Name, Value: string);
      var Previous: Int64;
      begin
        // Normal CSS property names cannot use the reserved leading colon.
        if Priorities.TryGetValue(':'+Name,Previous) and (Rank<Previous) then Exit;
        Priorities.AddOrSetValue(':'+Name,Rank);
        Values.AddOrSetValue(':'+Name,Value);
      end;
      procedure ApplyPadding(const Tokens: TArray<string>);
      begin
        for var Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
          Apply('padding-'+CSSCellSide[Side],Tokens[CSSSideToken[Length(Tokens),Side]]);
      end;
      procedure ApplyBorder;
      var PropertySide, Side: TReaderCellSide; HasSide: Boolean; Key, Candidate: string;
        Part, I: Integer; Tokens: TArray<string>;
        ValuesByPart: array[0..2] of string; Seen: array[0..2] of Boolean;
        function Normalize(Index: Integer; const Value: string): string;
        begin
          Result:='';
          case Index of
            0: if TRegEx.IsMatch(Value,'\A'+CSSCellBorderWidth+'\z') then Result:=Value;
            1: if MatchText(Value,['none','hidden','solid','dotted','dashed','double','groove','ridge',
                  'inset','outset']) then Result:=Value;
            2: Result:=CellBorderColor(Value);
          end;
        end;
      begin
        PropertySide:=rcTop; HasSide:=False;
        Key:=Copy(PropertyName,7,MaxInt);
        for Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
          if (Key='-'+CSSCellSide[Side]) or Key.StartsWith('-'+CSSCellSide[Side]+'-') then
          begin
            PropertySide:=Side; HasSide:=True;
            Key:=Copy(Key,Length(CSSCellSide[Side])+2,MaxInt);
            Break;
          end;
        Tokens:=TRegEx.Split(Fill,'\s+(?![^()]*\))');
        if Key='' then
        begin
          if Length(Tokens)>3 then Exit;
          ValuesByPart[0]:='medium'; ValuesByPart[1]:='none'; ValuesByPart[2]:='currentcolor';
          FillChar(Seen,SizeOf(Seen),0);
          for var Token in Tokens do
          begin
            Part:=-1;
            for I:=Low(CSSBorderPart) to High(CSSBorderPart) do
            begin
              Candidate:=Normalize(I,Token);
              if Candidate<>'' then begin Part:=I; Break; end;
            end;
            if Part<0 then Exit;
            if Seen[Part] then Exit;
            Seen[Part]:=True; ValuesByPart[Part]:=Candidate;
          end;
          for Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
            if not HasSide or (Side=PropertySide) then
              for I:=Low(CSSBorderPart) to High(CSSBorderPart) do
                Apply('border-'+CSSCellSide[Side]+'-'+CSSBorderPart[I],ValuesByPart[I]);
        end
        else
        begin
          Part:=IndexText(Copy(Key,2,MaxInt),CSSBorderPart);
          if (Part<0) or (Length(Tokens)>4) or (HasSide and (Length(Tokens)<>1)) then Exit;
          for I:=0 to High(Tokens) do
          begin
            Tokens[I]:=Normalize(Part,Tokens[I]);
            if Tokens[I]='' then Exit;
          end;
          for Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
            if not HasSide or (Side=PropertySide) then
              Apply('border-'+CSSCellSide[Side]+'-'+CSSBorderPart[Part],Tokens[CSSSideToken[Length(Tokens),Side]]);
        end;
      end;
    begin
      if not IsCell then Exit;
      var Lower:=Text.ToLower;
      if (Pos('background',Lower)=0) and (Pos('padding',Lower)=0) and (Pos('border',Lower)=0) then Exit;
      Start:=1; Depth:=0;
      for var Token in TRegEx.Matches(Text+';',CSSQuoted+'|/\*.*?\*/|[();]',[roSingleLine]) do
      begin
        if Token.Value='(' then Inc(Depth)
        else if Token.Value=')' then Depth:=Max(0,Depth-1);
        if (Token.Value<>';') or (Depth<>0) then Continue;
        Declaration:=Copy(Text,Start,Token.Index-Start);
        Start:=Token.Index+1;
        if Declaration.Contains('/*') then Declaration:=TRegEx.Replace(Declaration,'/\*.*?\*/',' ',[roSingleLine]);
        Separator:=Pos(':',Declaration);
        if Separator=0 then Continue;
        PropertyName:=Copy(Declaration,1,Separator-1).Trim.ToLower;
        Fill:=Copy(Declaration,Separator+1,MaxInt).Trim.ToLower;
        if Fill='' then Continue;
        Rank:=Int64(Specificity)*10000+Order;
        var Suffix:=TRegEx.Match(Fill,'\s*!\s*important\s*$');
        if Suffix.Success then
        begin
          Inc(Rank,Int64(1000000000000));
          Fill:=Copy(Fill,1,Suffix.Index-1).Trim;
        end;
        if MatchText(PropertyName,['background','background-color']) then
        begin
          if not TRegEx.IsMatch(Fill,'\A#[a-f0-9]{3}(?:[a-f0-9]{3})?\z') then Fill:='';
          Apply('background',Fill);
        end
        else if PropertyName='padding' then
        begin
          if TRegEx.IsMatch(Fill,'\A'+CSSCellLength+'(?:\s+'+CSSCellLength+'){0,3}\z') then
            ApplyPadding(TRegEx.Split(Fill,'\s+'));
        end
        else if PropertyName.StartsWith('padding-') then
        begin
          if TRegEx.IsMatch(Fill,'\A'+CSSCellLength+'\z') then Apply(PropertyName,Fill);
        end
        else if (PropertyName='border') or PropertyName.StartsWith('border-') then ApplyBorder;
      end;
    end;
  begin
    MergeTableStyle;
    for Part in Text.Split([';']) do
    begin
      Colon:=Pos(':',Part); if Colon=0 then Continue;
      Key:=Trim(Copy(Part,1,Colon-1)).ToLower; Raw:=Trim(Copy(Part,Colon+1,MaxInt)); Value:=Raw.ToLower;
      Priority:=Int64(Specificity)*10000+Order;
      if Value.Contains('!important') then begin Inc(Priority,Int64(1000000000000)); Value:=Value.Replace('!important','').Trim; end;
      if UseListImages and (Priority>=ImagePriority) and MatchText(Key,['list-style-image','list-style']) then
      begin
        Candidate:='';
        URL:=TRegEx.Match(Raw,'\burl\s*\(\s*("[^"]*"|''[^'']*''|[^\s"''()]+)\s*\)',[roIgnoreCase]);
        if URL.Success then
        begin
          Candidate:=URL.Groups[1].Value;
          if CharInSet(Candidate[1],['"','''']) then Candidate:=Copy(Candidate,2,Length(Candidate)-2);
          if Candidate='' then Candidate:=#0;
        end
        else if MatchText(Value,['inherit','unset']) then Candidate:=''
        else if (Key='list-style') or MatchText(Value,['none','initial']) then Candidate:=#0;
        if URL.Success or (Candidate<>'') or MatchText(Value,['inherit','unset']) then
        begin
          Image:=Candidate; ImageBase:=Base; ImagePriority:=Priority;
        end;
      end;
      if not Priorities.TryGetValue(Key,Old) or (Priority>=Old) then
      begin Priorities.AddOrSetValue(Key,Priority); Values.AddOrSetValue(Key,Value); end;
    end;
  end;
  function Get(const Key: string): string;
  begin if not Values.TryGetValue(Key,Result) then Result:=''; end;
  function Twips(const CSSValue: string; out Number: Integer): Boolean;
  var N: Double; Text: string; Multiplier: Double;
  begin
    Text:=CSSValue.Trim; Multiplier:=15;
    if Text.EndsWith('px') then Text:=Text.Substring(0,Text.Length-2)
    else if Text.EndsWith('pt') then begin Multiplier:=20; Text:=Text.Substring(0,Text.Length-2); end
    else if Text.EndsWith('em') then begin Multiplier:=280; Text:=Text.Substring(0,Text.Length-2); end;
    Result:=TryStrToFloat(Text,N,TFormatSettings.Invariant) and (Abs(N)<10000);
    if Result then Number:=EnsureRange(Round(N*Multiplier),-2400,2400);
  end;
  function CellTwips(const Text: string; Default: Integer): Integer;
  var Number: Double; Points: Double; M: TMatch;
  begin
    if Text='0' then Exit(0);
    M:=TRegEx.Match(Text,'\A(\d+(?:\.\d+)?|\.\d+)(px|pt|in|cm|mm|pc)\z');
    if not M.Success or not TryStrToFloat(M.Groups[1].Value,Number,TFormatSettings.Invariant) then Exit(Default);
    case IndexText(M.Groups[2].Value,['px','pt','in','cm','mm','pc']) of
      0: Points:=0.75;
      1: Points:=1;
      2: Points:=72;
      3: Points:=72/2.54;
      4: Points:=72/25.4;
    else Points:=12;
    end;
    Result:=Round(Min(2400,Number*Points*20));
  end;
  procedure Space(const PropertyName, ControlWord: string);
  var Number: Integer;
  begin if Twips(Get(PropertyName),Number) then
    begin if PropertyName<>'text-indent' then Number:=Max(0,Number); Result:=Result+ControlWord+IntToStr(Number)+' '; end; end;
begin
  ImagePriority:=-1; IsCell:=MatchText(Tag,['td','th']); Cell:=Default(TReaderCellStyle);
  Values:=TDictionary<string,string>.Create; Priorities:=TDictionary<string,Int64>.Create;
  try
    I:=0;
    for Rule in FRules do
    begin
      Inc(I);
      if Matches(Rule.Selector,Tag,Classes,ID) and
        ((Rule.PreviousSelector='') or ((PreviousTag<>'') and
          Matches(Rule.PreviousSelector,PreviousTag,PreviousClasses,PreviousID))) then
        Merge(Rule.Declarations,Rule.Base,Rule.Specificity,I,Rule.ListImages);
    end;
    if Length(InlineStyle)<=65536 then Merge(InlineStyle,'',1000000,0,True);
    ListImage:=Image; ListImageBase:=ImageBase;
    if IsCell then
    begin
      Cell.Background:=Get(':background');
      for var Side:=Low(TReaderCellSide) to High(TReaderCellSide) do
      begin
        Cell.Padding[Side]:=CellTwips(Get(':padding-'+CSSCellSide[Side]),-1);
        var BorderKey:=':border-'+CSSCellSide[Side]+'-';
        var Width:=Get(BorderKey+'width');
        Cell.Borders[Side].Style:=Get(BorderKey+'style');
        Cell.Borders[Side].Color:=Get(BorderKey+'color');
        Cell.HasBorders:=Cell.HasBorders or (Width<>'') or (Cell.Borders[Side].Style<>'') or
          (Cell.Borders[Side].Color<>'');
        case IndexText(Width,['thin','medium','thick']) of
          0: Cell.Borders[Side].Width:=15;
          1: Cell.Borders[Side].Width:=45;
          2: Cell.Borders[Side].Width:=75;
        else Cell.Borders[Side].Width:=CellTwips(Width,45);
        end;
      end;
    end;
    FontSize:=Get('font-size'); Result:=''; Value:=Get('font-weight');
    if Value<>'' then
      if MatchText(Value,['bold','bolder']) or (StrToIntDef(Value,400)>=600) then Result:=Result+'\b '
      else if MatchText(Value,['normal','lighter','400']) then Result:=Result+'\b0 ';
    Value:=Get('font-style');
    if MatchText(Value,['italic','oblique']) then Result:=Result+'\i '
    else if Value='normal' then Result:=Result+'\i0 ';
    Value:=Get('text-decoration');
    if Value.Contains('underline') then Result:=Result+'\ul ';
    if Value.Contains('line-through') then Result:=Result+'\strike ';
    if Value='none' then Result:=Result+'\ul0\strike0 ';
    Value:=Get('vertical-align');
    if Value='super' then Result:=Result+'\super '
    else if Value='sub' then Result:=Result+'\sub '
    else if Value='baseline' then Result:=Result+'\nosupersub ';
    Value:=Get('text-align');
    if Value='center' then Result:=Result+'\qc '
    else if Value='left' then Result:=Result+'\ql '
    else if Value='right' then Result:=Result+'\qr '
    else if Value='justify' then Result:=Result+'\qj ';
    Space('text-indent','\fi'); Space('margin-top','\sb'); Space('margin-bottom','\sa');
  finally Priorities.Free; Values.Free; end;
end;

function TReaderCSS.Resolve(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses,
  PreviousID: string): TReaderCSSValue;
var Key: string;
begin
  Key:=Tag+#1+Classes+#1+ID+#1+InlineStyle;
  if FHasAdjacentRules then Key:=Key+#1+PreviousTag+#1+PreviousClasses+#1+PreviousID;
  if FCache.TryGetValue(Key,Result) then Exit;
  Result.Code:=Compile(Tag,Classes,ID,InlineStyle,PreviousTag,PreviousClasses,PreviousID,
    Result.FontSize,Result.ListImage,Result.ListImageBase,Result.Cell);
  if FCache.Count>=8192 then FCache.Clear;
  FCache.Add(Key,Result);
end;

function TReaderCSS.RTF(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses, PreviousID: string): string;
begin Result:=Resolve(Tag,Classes,ID,InlineStyle,PreviousTag,PreviousClasses,PreviousID).Code; end;

function TReaderCSS.ListImage(const Tag, Classes, ID, InlineStyle: string; out Base: string): string;
var Style: TReaderCSSValue;
begin
  Style:=Resolve(Tag,Classes,ID,InlineStyle);
  Base:=Style.ListImageBase;
  Result:=Style.ListImage;
end;

function TReaderCSS.CellStyle(const Tag, Classes, ID, InlineStyle, PreviousTag, PreviousClasses, PreviousID: string): TReaderCellStyle;
begin
  Result:=Resolve(Tag,Classes,ID,InlineStyle,PreviousTag,PreviousClasses,PreviousID).Cell;
end;

function TReaderCSS.FontPercent(const Tag, Classes, ID, InlineStyle: string; InheritedPercent: Integer;
  const PreviousTag, PreviousClasses, PreviousID: string): Integer;
var Text: string; Number, Multiplier: Double;
begin
  Result:=InheritedPercent;
  // The body uses the reader's chosen size; retain relative differences inside it.
  if SameText(Tag,'body') then Exit(100);
  Text:=Resolve(Tag,Classes,ID,InlineStyle,PreviousTag,PreviousClasses,PreviousID).FontSize;
  if Text='' then Exit;
  if Text='inherit' then Exit;
  if Text='initial' then Exit(100);
  Multiplier:=100/14;
  if Text.EndsWith('em') then begin Multiplier:=InheritedPercent; Text:=Text.Substring(0,Text.Length-2); end
  else if Text.EndsWith('%') then begin Multiplier:=InheritedPercent/100; Text:=Text.Substring(0,Text.Length-1); end
  else if Text.EndsWith('px') then begin Multiplier:=75/14; Text:=Text.Substring(0,Text.Length-2); end
  else if Text.EndsWith('pt') then Text:=Text.Substring(0,Text.Length-2)
  else Exit;
  if TryStrToFloat(Text,Number,TFormatSettings.Invariant) and (Number>0) and (Number<10000) then
    Result:=EnsureRange(Round(Number*Multiplier),25,400);
end;

end.
