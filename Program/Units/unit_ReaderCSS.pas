unit unit_ReaderCSS;

interface

uses System.SysUtils, System.Generics.Collections;

type
  TReaderCSSRule = record
    Selector, Declarations, Base: string;
    Specificity: Integer;
    ListImages: Boolean;
  end;
  TReaderCSSValue = record Code, FontSize, ListImage, ListImageBase: string; end;
  // A bounded local stylesheet subset for the reflow reader. Unsupported
  // browser-only layout never hides, transforms or removes book text.
  TReaderCSS = class
  private
    FRules: TList<TReaderCSSRule>;
    FCache: TDictionary<string,TReaderCSSValue>;
    FSvgStyleLength: Integer;
    FCompleteSvgRules: Boolean;
    function Matches(const Selector, Tag, Classes, ID: string): Boolean;
    function Compile(const Tag, Classes, ID, InlineStyle: string;
      out FontSize, ListImage, ListImageBase: string): string;
    function Resolve(const Tag, Classes, ID, InlineStyle: string): TReaderCSSValue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Add(const CSS: string; const Base: string = ''; ListImages: Boolean = True);
    function RTF(const Tag, Classes, ID, InlineStyle: string): string;
    function FontPercent(const Tag, Classes, ID, InlineStyle: string; InheritedPercent: Integer): Integer;
    function ListImage(const Tag, Classes, ID, InlineStyle: string; out Base: string): string;
    function PreservesSvgViewport(const Tag, Classes, ID, InlineStyle: string): Boolean;
    property CompleteSvgRules: Boolean read FCompleteSvgRules;
  end;

implementation

uses System.Classes, System.StrUtils, System.Math, System.RegularExpressions;

constructor TReaderCSS.Create;
begin inherited; FRules:=TList<TReaderCSSRule>.Create; FCache:=TDictionary<string,TReaderCSSValue>.Create;
  FCompleteSvgRules:=True; end;

destructor TReaderCSS.Destroy;
begin FCache.Free; FRules.Free; inherited; end;

procedure TReaderCSS.Clear;
begin FRules.Clear; FCache.Clear; FSvgStyleLength:=0; FCompleteSvgRules:=True; end;

procedure TReaderCSS.Add(const CSS, Base: string; ListImages: Boolean);
const SimpleSelector = '\A(?:\*|[a-zA-Z][a-zA-Z0-9-]*)?(?:[.#][a-zA-Z_][a-zA-Z0-9_-]*)*\z';
var Text, Selector, RawSelector, Declarations: string; Start, Open, Finish, I: Integer; Rule: TReaderCSSRule;
begin
  if FCompleteSvgRules then
  begin
    Inc(FSvgStyleLength,Length(CSS));
    FCompleteSvgRules:=(FSvgStyleLength<=65536) and not TRegEx.IsMatch(CSS,'[\\"''\x{fffd}]');
  end;
  if Length(CSS)>1024*1024 then Exit;
  Text:=TRegEx.Replace(CSS,'/\*.*?\*/','',[roSingleLine]); Start:=1;
  while (Start<=Length(Text)) and (FRules.Count<4096) do
  begin
    Open:=PosEx('{',Text,Start); if Open=0 then Break;
    Finish:=PosEx('}',Text,Open+1); if Finish=0 then Break;
    Declarations:=Copy(Text,Open+1,Finish-Open-1);
    if Declarations.Contains('{') then FCompleteSvgRules:=False;
    for RawSelector in Copy(Text,Start,Open-Start).Split([',']) do
    begin
      if FRules.Count>=4096 then Break;
      Selector:=RawSelector.Trim;
      if FCompleteSvgRules and not SameText(Selector,'@page') and
        ((Selector='') or not TRegEx.IsMatch(Selector,SimpleSelector)) then FCompleteSvgRules:=False;
      if (Selector='') or (Length(Selector)>256) or (Pos('@',Selector)>0) or
        TRegEx.IsMatch(Selector,'[\s>+~:\[\]\\]') then Continue;
      Rule.Selector:=Selector; Rule.Declarations:=Declarations; Rule.Specificity:=0;
      Rule.Base:=Base; Rule.ListImages:=ListImages;
      for I:=1 to Length(Selector) do
        if Selector[I]='#' then Inc(Rule.Specificity,100)
        else if Selector[I]='.' then Inc(Rule.Specificity,10);
      if not CharInSet(Selector[1],['.','#','*']) then Inc(Rule.Specificity);
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

function TReaderCSS.Compile(const Tag, Classes, ID, InlineStyle: string;
  out FontSize, ListImage, ListImageBase: string): string;
var Values: TDictionary<string,string>; Priorities: TDictionary<string,Int64>;
  Rule: TReaderCSSRule; I: Integer; Value, Image, ImageBase: string; ImagePriority: Int64;
  procedure Merge(const Text, Base: string; Specificity, Order: Integer; UseListImages: Boolean);
  var Part, Key, Value, Raw, Candidate: string; Colon: Integer; Priority, Old: Int64; URL: TMatch;
  begin
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
  procedure Space(const PropertyName, ControlWord: string);
  var Number: Integer;
  begin if Twips(Get(PropertyName),Number) then
    begin if PropertyName<>'text-indent' then Number:=Max(0,Number); Result:=Result+ControlWord+IntToStr(Number)+' '; end; end;
begin
  ImagePriority:=-1;
  Values:=TDictionary<string,string>.Create; Priorities:=TDictionary<string,Int64>.Create;
  try
    I:=0;
    for Rule in FRules do
    begin Inc(I); if Matches(Rule.Selector,Tag,Classes,ID) then Merge(Rule.Declarations,Rule.Base,Rule.Specificity,I,Rule.ListImages); end;
    if Length(InlineStyle)<=65536 then Merge(InlineStyle,'',1000000,0,True);
    ListImage:=Image; ListImageBase:=ImageBase;
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

function TReaderCSS.Resolve(const Tag, Classes, ID, InlineStyle: string): TReaderCSSValue;
var Key: string;
begin
  Key:=Tag+#1+Classes+#1+ID+#1+InlineStyle;
  if FCache.TryGetValue(Key,Result) then Exit;
  Result.Code:=Compile(Tag,Classes,ID,InlineStyle,Result.FontSize,Result.ListImage,Result.ListImageBase);
  if FCache.Count>=8192 then FCache.Clear;
  FCache.Add(Key,Result);
end;

function TReaderCSS.RTF(const Tag, Classes, ID, InlineStyle: string): string;
begin Result:=Resolve(Tag,Classes,ID,InlineStyle).Code; end;

function TReaderCSS.ListImage(const Tag, Classes, ID, InlineStyle: string; out Base: string): string;
var Style: TReaderCSSValue;
begin
  Style:=Resolve(Tag,Classes,ID,InlineStyle);
  Base:=Style.ListImageBase;
  Result:=Style.ListImage;
end;

function TReaderCSS.FontPercent(const Tag, Classes, ID, InlineStyle: string; InheritedPercent: Integer): Integer;
var Text: string; Number, Multiplier: Double;
begin
  Result:=InheritedPercent;
  // The body uses the reader's chosen size; retain relative differences inside it.
  if SameText(Tag,'body') then Exit(100);
  Text:=Resolve(Tag,Classes,ID,InlineStyle).FontSize; if Text='' then Exit;
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
