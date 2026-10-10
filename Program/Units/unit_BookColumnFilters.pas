unit unit_BookColumnFilters;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections,
  VirtualTrees, BookTreeView, unit_Globals, unit_Consts;

type
  TColumnFilterCondition = record
    Tag, Kind, Mode, RatingMask: Integer;
    Pattern: string;
    Lower, Upper: Extended;
    Sensitive: Boolean;
    Selections: TDictionary<string,Byte>;
  end;
  TBookColumnFilters = class(TComponent)
  private
    FTree: TBookTree;
    FValues: TDictionary<Integer, string>;
    FSensitive: TDictionary<Integer, Boolean>;
    FApplied: TDictionary<Integer, string>;
    FAppliedSensitive: TDictionary<Integer, Boolean>;
    FRows, FGroups, FVisible: TList<PVirtualNode>;
    FRevision: UInt64;
    FNodeCount: Cardinal;
    FHaveResult, FCaseChanged: Boolean;
    FConditions: TArray<TColumnFilterCondition>;
    FSelectionSets: TObjectList<TDictionary<string,Byte>>;
    FOptionCache: TObjectDictionary<string,TStringList>;
    procedure EnsureRows(const Cancelled: TFunc<Boolean> = nil);
    procedure Compile;
    function CanNarrow: Boolean;
    function GetTotal: Integer;
    function TextFor(Tag: Integer; const Book: TBookRecord): string;
    function Matches(const Book: TBookRecord; const IgnoreTag: Integer = -1): Boolean;
    function GetCount: Integer;
  public
    constructor CreateFor(Tree: TBookTree);
    destructor Destroy; override;
    class function ForTree(Tree: TBookTree): TBookColumnFilters; static;
    procedure SetValue(Tag: Integer; const Value: string);
    function Value(Tag: Integer): string;
    procedure Clear;
    procedure RestoreApplied;
    procedure SetCaseSensitive(Tag: Integer; Enabled: Boolean);
    function CaseSensitive(Tag: Integer): Boolean;
    procedure GetOptions(Tag: Integer; Names: TStrings);
    procedure SetSelectedValues(Tag: Integer; Names: TStrings);
    procedure GetSelectedValues(Tag: Integer; Names: TStrings);
    property Total: Integer read GetTotal;
    function Apply(SelectBook: Boolean = True; const Cancelled: TFunc<Boolean> = nil): Integer;
    property Count: Integer read GetCount;
  end;

function EditBookColumnFilters(Tree: TBookTree): Boolean;
function EditBookColumnFilter(Tree: TBookTree; Tag: Integer): Boolean;

const COL_PUBLISHER_SERIES_FILTER = COL_PUBLISHER_SERIES;

implementation

uses System.StrUtils, System.DateUtils, System.Math, Winapi.Windows, Vcl.Forms,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, unit_MHLHelpers,
  System.Types, Vcl.CheckLst, System.JSON, VirtualTrees.Types;

const
  ColumnTags: array[0..13] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_PUBLISHER_SERIES_FILTER,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE,
    COL_COLLECTION, COL_LANG, COL_LIBRATE, COL_LIBID);
  ColumnNames: array[0..13] of string = ('Автор', 'Название', 'Серия', 'Книжная серия', '№',
    'Жанр', 'Размер', 'Моя оценка', 'Добавлено', 'Тип', 'Коллекция',
    'Язык', 'Рейтинг библиотеки', 'ID в библиотеке');

constructor TBookColumnFilters.CreateFor(Tree: TBookTree);
begin
  inherited Create(Tree);
  FTree := Tree;
  FValues := TDictionary<Integer, string>.Create;
  FSensitive := TDictionary<Integer, Boolean>.Create;
  FApplied := TDictionary<Integer, string>.Create;
  FAppliedSensitive := TDictionary<Integer, Boolean>.Create;
  FRows := TList<PVirtualNode>.Create;
  FGroups := TList<PVirtualNode>.Create;
  FVisible := TList<PVirtualNode>.Create;
  FSelectionSets := TObjectList<TDictionary<string,Byte>>.Create(True);
  FOptionCache := TObjectDictionary<string,TStringList>.Create([doOwnsValues]);
  FRevision := High(UInt64);
end;

destructor TBookColumnFilters.Destroy;
begin
  FOptionCache.Free; FSelectionSets.Free; FVisible.Free; FGroups.Free; FRows.Free; FAppliedSensitive.Free; FApplied.Free; FSensitive.Free; FValues.Free;
  inherited;
end;

class function TBookColumnFilters.ForTree(Tree: TBookTree): TBookColumnFilters;
var Component: TComponent;
begin
  for Component in Tree do
    if Component is TBookColumnFilters then Exit(TBookColumnFilters(Component));
  Result := TBookColumnFilters.CreateFor(Tree);
end;

procedure TBookColumnFilters.SetValue(Tag: Integer; const Value: string);
begin
  if Value.Trim = '' then FValues.Remove(Tag)
  else FValues.AddOrSetValue(Tag, Value.Trim);
end;

function TBookColumnFilters.Value(Tag: Integer): string;
begin
  if not FValues.TryGetValue(Tag, Result) then Result := '';
end;

function TBookColumnFilters.GetCount: Integer;
begin
  Result := FValues.Count;
end;

procedure TBookColumnFilters.Clear;
begin
  FValues.Clear; FSensitive.Clear; FCaseChanged := True;
end;

procedure TBookColumnFilters.RestoreApplied;
var Pair: TPair<Integer,string>; Sensitive: TPair<Integer,Boolean>;
begin
  FValues.Clear; FSensitive.Clear;
  for Pair in FApplied do FValues.Add(Pair.Key,Pair.Value);
  for Sensitive in FAppliedSensitive do FSensitive.Add(Sensitive.Key,Sensitive.Value);
  FCaseChanged := False;
end;

function TBookColumnFilters.TextFor(Tag: Integer; const Book: TBookRecord): string;
var Number: Integer; Series: TBookSeriesData;
begin
  Result := '';
  case Tag of
    COL_AUTHOR: Result := TAuthorsHelper.GetList(Book.Authors);
    COL_TITLE: Result := Book.Title;
    COL_SERIES: Result := Book.Series;
    COL_PUBLISHER_SERIES_FILTER:
      for Series in Book.PublisherSeries do Result := Result + Series.SeriesTitle + sLineBreak;
    COL_NO:
      begin
        if FTree.Tag = PAGE_PUBLISHER_SERIES then Number := Book.PublisherSeqNumber
        else Number := Book.SeqNumber;
        if Number <> 0 then Result := IntToStr(Number);
      end;
    COL_GENRE: Result := TGenresHelper.GetList(Book.Genres);
    COL_SIZE: Result := GetFormattedSize(Book.Size);
    COL_RATE: Result := IntToStr(Book.Rate);
    COL_DATE: Result := DateToStr(Book.Date) + ' ' + FormatDateTime('yyyy-mm-dd', Book.Date);
    COL_TYPE: Result := Book.GetFileType;
    COL_COLLECTION: Result := Book.CollectionName;
    COL_LANG: Result := Book.Lang;
    COL_LIBRATE: Result := IntToStr(Book.LibRate);
    COL_LIBID: Result := Book.DisplayLibID;
  end;
end;

function ISODate(const Value: string): TDateTime;
var Y, M, D: Integer;
begin
  Result := 0;
  if (Length(Value) = 10) and TryStrToInt(Copy(Value, 1, 4), Y) and
    TryStrToInt(Copy(Value, 6, 2), M) and TryStrToInt(Copy(Value, 9, 2), D) then
    TryEncodeDate(Y, M, D, Result);
end;

function NormalizeYo(const Value: string): string;
var I: Integer;
begin
  Result := Value; UniqueString(Result);
  for I := 1 to Length(Result) do
    case Result[I] of 'ё': Result[I] := 'е'; 'Ё': Result[I] := 'Е'; end;
end;

function FoldText(const Value: string): string;
begin
  Result := NormalizeYo(Value);
  // Windows Unicode case mapping also covers Cyrillic; SysUtils.LowerCase
  // without a locale argument maps only ASCII in this RTL.
  if Result <> '' then
  begin UniqueString(Result); CharLowerBuff(PChar(Result), Length(Result)); end;
end;

procedure TBookColumnFilters.SetCaseSensitive(Tag: Integer; Enabled: Boolean);
begin
  if CaseSensitive(Tag) <> Enabled then FCaseChanged := True;
  if Enabled then FSensitive.AddOrSetValue(Tag, True) else FSensitive.Remove(Tag);
end;

function TBookColumnFilters.CaseSensitive(Tag: Integer): Boolean;
begin Result := FSensitive.ContainsKey(Tag); end;

procedure TBookColumnFilters.EnsureRows(const Cancelled: TFunc<Boolean>);
var Node: PVirtualNode; Book: PBookRecord; Visited: Integer;
begin
  if (FRevision = FTree.DataVersion) and (FNodeCount = FTree.TotalCount) then Exit;
  FOptionCache.Clear;
  FRows.Clear; FGroups.Clear; FVisible.Clear; FApplied.Clear; FAppliedSensitive.Clear; FHaveResult := False;
  Node := FTree.GetFirst; Visited := 0;
  while Assigned(Node) do
  begin
    Inc(Visited);
    if Assigned(Cancelled) and ((Visited and 255) = 0) and Cancelled() then Abort;
    Book := FTree.GetNodeData(Node);
    if Assigned(Book) and (Book.NodeType = ntBookInfo) then
    begin
      FRows.Add(Node);
      if not FTree.IsFiltered[Node] then FVisible.Add(Node);
    end
    else FGroups.Add(Node);
    Node := FTree.GetNext(Node);
  end;
  FRevision := FTree.DataVersion; FNodeCount := FTree.TotalCount;
end;

function TBookColumnFilters.GetTotal: Integer;
begin EnsureRows; Result := FRows.Count; end;

procedure TBookColumnFilters.SetSelectedValues(Tag: Integer; Names: TStrings);
var Values: TJSONArray; Text: string;
begin
  Values := TJSONArray.Create;
  try
    for Text in Names do Values.Add(Text);
    SetValue(Tag,'values:'+Values.ToJSON);
  finally Values.Free; end;
end;

procedure TBookColumnFilters.GetSelectedValues(Tag: Integer; Names: TStrings);
var Parsed: TJSONValue; Item: TJSONValue; Current: string;
begin
  Names.Clear; Current := Value(Tag);
  if Current.StartsWith('=') then begin Names.Add(Copy(Current,2,MaxInt)); Exit; end;
  if not Current.StartsWith('values:') then Exit;
  Parsed := TJSONObject.ParseJSONValue(Copy(Current,8,MaxInt));
  try
    if Parsed is TJSONArray then
      for Item in TJSONArray(Parsed) do if Item is TJSONString then Names.Add(Item.Value);
  finally Parsed.Free; end;
end;

procedure TBookColumnFilters.GetOptions(Tag: Integer; Names: TStrings);
var Node: PVirtualNode; Book: PBookRecord; Genre: TGenreData; Series: TBookSeriesData;
  Author: TAuthorData; Unique: TDictionary<string,string>; Raw: TDictionary<string,Byte>;
  Sorted: TStringList; Text, CacheKey: string; OtherTag: Integer;
  procedure Add(const Value: string);
  var Key: string;
  begin
    if (Value = '') or not Raw.TryAdd(Value,0) then Exit;
    // Keep spelling variants available when the user enables case matching.
    // Matching itself still folds case and e/yo unless explicitly requested.
    Key := Value;
    if not Unique.ContainsKey(Key) then Unique.Add(Key,Value);
  end;
begin
  EnsureRows;
  CacheKey := IntToStr(Tag)+':'+BoolToStr(CaseSensitive(Tag));
  for OtherTag in ColumnTags do if OtherTag <> Tag then
    CacheKey := CacheKey+#1+IntToStr(OtherTag)+':'+BoolToStr(CaseSensitive(OtherTag))+':'+Value(OtherTag);
  if FOptionCache.TryGetValue(CacheKey,Sorted) then begin Names.Assign(Sorted); Exit; end;
  Compile; Unique := TDictionary<string,string>.Create; Raw := TDictionary<string,Byte>.Create;
  Sorted := TStringList.Create;
  try
    for Node in FRows do
    begin
      Book := FTree.GetNodeData(Node);
      if not Matches(Book^,Tag) then Continue;
      case Tag of
        COL_AUTHOR: for Author in Book.Authors do Add(Author.GetFullName);
        COL_GENRE: for Genre in Book.Genres do Add(Genre.GenreAlias);
        COL_PUBLISHER_SERIES: for Series in Book.PublisherSeries do Add(Series.SeriesTitle);
      else Add(TextFor(Tag,Book^)); end;
    end;
    for Text in Unique.Values do Sorted.Add(Text);
    Sorted.CaseSensitive := True; Sorted.Sort; Names.Assign(Sorted);
    if FOptionCache.Count >= 8 then FOptionCache.Clear;
    FOptionCache.Add(CacheKey,Sorted); Sorted := nil;
  finally Sorted.Free; Raw.Free; Unique.Free; end;
end;

procedure TBookColumnFilters.Compile;
var Pair: TPair<Integer,string>; C: TColumnFilterCondition; Parts: TArray<string>; I, N: Integer;
  Names: TStringList; Name, Key: string;
begin
  FConditions := nil; FSelectionSets.Clear;
  for Pair in FValues do
  begin
    C := Default(TColumnFilterCondition); C.Tag := Pair.Key;
    C.Sensitive := CaseSensitive(C.Tag); C.Pattern := Pair.Value;
    Parts := Pair.Value.Split([';']);
    if Pair.Value.StartsWith('values:') then
    begin
      C.Kind := 7; C.Selections := TDictionary<string,Byte>.Create;
      FSelectionSets.Add(C.Selections); Names := TStringList.Create;
      try
        GetSelectedValues(C.Tag,Names);
        for Name in Names do
        begin
          if C.Sensitive then Key := NormalizeYo(Name) else Key := FoldText(Name);
          C.Selections.TryAdd(Key,0);
        end;
      finally Names.Free; end;
    end
    else if (C.Tag = COL_DATE) and (Length(Parts) = 4) and (Parts[0] = 'date') then
    begin C.Kind := 4; C.Mode := StrToIntDef(Parts[1],0); C.Lower := ISODate(Parts[2]); C.Upper := ISODate(Parts[3]); end
    else if (C.Tag in [COL_SIZE,COL_NO,COL_RATE,COL_LIBRATE]) and (Length(Parts) >= 4) and (Parts[0] = 'num') then
    begin
      C.Kind := 3; C.Mode := StrToIntDef(Parts[1],0);
      if not TryStrToFloat(Parts[2],C.Lower,TFormatSettings.Invariant) or
        not TryStrToFloat(Parts[3],C.Upper,TFormatSettings.Invariant) then C.Mode := 0;
    end
    else if (C.Tag in [COL_RATE,COL_LIBRATE]) and (Parts[0] = 'set') then
    begin
      C.Kind := 5;
      for I := 1 to High(Parts) do
      begin N := StrToIntDef(Parts[I],-1); if (N >= 0) and (N <= 5) then C.RatingMask := C.RatingMask or (1 shl N); end;
    end
    else
    begin
      if C.Pattern.StartsWith('=') then
      begin
        C.Kind := 1; Delete(C.Pattern,1,1);
        if C.Tag = COL_GENRE then C.Kind := 2;
        if C.Tag = COL_PUBLISHER_SERIES then C.Kind := 6;
      end;
      if not C.Sensitive then C.Pattern := FoldText(C.Pattern) else C.Pattern := NormalizeYo(C.Pattern);
    end;
    FConditions := FConditions + [C];
  end;
end;

function TBookColumnFilters.CanNarrow: Boolean;
var Pair: TPair<Integer,string>; NewValue: string;
begin
  Result := FHaveResult and not FCaseChanged;
  if not Result then Exit;
  for Pair in FApplied do
    if not FValues.TryGetValue(Pair.Key, NewValue) then Exit(False)
    else if Pair.Value <> NewValue then
    begin
      // Extending a contains condition can only remove rows. Changing numeric,
      // date, checklist or exact conditions must reconsider all loaded rows.
      if Pair.Value.StartsWith('=') or Pair.Value.StartsWith('num;') or
        Pair.Value.StartsWith('date;') or Pair.Value.StartsWith('set;') or Pair.Value.StartsWith('values:') or
        NewValue.StartsWith('values:') then Exit(False);
      if CaseSensitive(Pair.Key) then
      begin if not NewValue.StartsWith(Pair.Value) then Exit(False); end
      else if not FoldText(NewValue).StartsWith(FoldText(Pair.Value)) then Exit(False);
    end;
end;

function TBookColumnFilters.Matches(const Book: TBookRecord; const IgnoreTag: Integer): Boolean;
var C: TColumnFilterCondition; Genre: TGenreData; Series: TBookSeriesData; Author: TAuthorData;
  Found: Boolean; Text: string; Number: Extended;
  function EqualText(const Value: string): Boolean;
  begin
    if C.Sensitive then Result := NormalizeYo(Value) = C.Pattern
    else Result := FoldText(Value) = C.Pattern;
  end;
  function Selected(const Value: string): Boolean;
  var Key: string;
  begin
    if C.Sensitive then Key := NormalizeYo(Value) else Key := FoldText(Value);
    Result := C.Selections.ContainsKey(Key);
  end;
begin
  for C in FConditions do
  begin
    if C.Tag=IgnoreTag then Continue;
    case C.Kind of
      7:
      begin
        Found := False;
        case C.Tag of
          COL_AUTHOR: for Author in Book.Authors do if Selected(Author.GetFullName) then begin Found := True; Break; end;
          COL_GENRE: for Genre in Book.Genres do if Selected(Genre.GenreAlias) then begin Found := True; Break; end;
          COL_PUBLISHER_SERIES: for Series in Book.PublisherSeries do if Selected(Series.SeriesTitle) then begin Found := True; Break; end;
        else Found := Selected(TextFor(C.Tag,Book)); end;
        if not Found then Exit(False);
      end;
      3,4:
      begin
        case C.Tag of
          COL_DATE: Number := DateOf(Book.Date);
          COL_SIZE: Number := Book.Size;
          COL_RATE: Number := Book.Rate;
          COL_LIBRATE: Number := Book.LibRate;
        else
          if FTree.Tag = PAGE_PUBLISHER_SERIES then Number := Book.PublisherSeqNumber else Number := Book.SeqNumber;
        end;
        if (C.Kind = 4) and ((Number = 0) or (C.Lower = 0)) then Exit(False);
        case C.Mode of
          1: if Number <> C.Lower then Exit(False);
          2: if Number < C.Lower then Exit(False);
          3: if Number > C.Lower then Exit(False);
          4: if Number <= C.Lower then Exit(False);
          5: if Number >= C.Lower then Exit(False);
          6: if (Number < C.Lower) or (Number > C.Upper) then Exit(False);
          7: if Number = C.Lower then Exit(False);
        else Exit(False); end;
      end;
      5:
      begin
        if C.Tag = COL_RATE then Number := Book.Rate else Number := Book.LibRate;
        if (Number < 0) or (Number > 5) or ((C.RatingMask and (1 shl Trunc(Number))) = 0) then Exit(False);
      end;
      2,6:
      begin
        Found := False;
        if C.Kind = 2 then
          for Genre in Book.Genres do if EqualText(Genre.GenreAlias) then begin Found := True; Break; end;
        if C.Kind = 6 then
          for Series in Book.PublisherSeries do if EqualText(Series.SeriesTitle) then begin Found := True; Break; end;
        if not Found then Exit(False);
      end;
    else
      Text := TextFor(C.Tag,Book);
      if not C.Sensitive then Text := FoldText(Text) else Text := NormalizeYo(Text);
      if C.Kind = 1 then begin if Text <> C.Pattern then Exit(False); end
      else if Pos(C.Pattern,Text) = 0 then Exit(False);
    end;
  end;
  Result := True;
end;

function TBookColumnFilters.Apply(SelectBook: Boolean; const Cancelled: TFunc<Boolean>): Integer;
var Node, Parent, FirstBook: PVirtualNode; Book: PBookRecord; Match, Narrow: Boolean;
  Visited, NextVisible: Integer; Candidates, NewVisible: TList<PVirtualNode>;
  Pair: TPair<Integer,string>; Sensitive: TPair<Integer,Boolean>;
begin
  EnsureRows(Cancelled); Compile; Narrow := CanNarrow;
  if Narrow then Candidates := FVisible else Candidates := FRows;
  NewVisible := TList<PVirtualNode>.Create;
  Visited := 0;
  try
    // Evaluate without changing the previous display. A cancellation must not
    // leave hidden rows, lost checks or half-filtered parent groups behind.
    for Node in Candidates do
    begin
      Inc(Visited);
      if Assigned(Cancelled) and ((Visited and 255)=0) and Cancelled() then Abort;
      Book := FTree.GetNodeData(Node); Match := Matches(Book^);
      if Match then NewVisible.Add(Node);
    end;
    if Assigned(Cancelled) and Cancelled() then Abort;
    FTree.BeginUpdate;
    try
    FHaveResult := False; NextVisible := 0;
    for Node in FGroups do FTree.IsFiltered[Node] := True;
    for Node in Candidates do
    begin
      Match := (NextVisible < NewVisible.Count) and (NewVisible[NextVisible] = Node);
      if Match then Inc(NextVisible);
      if FTree.IsFiltered[Node] = Match then FTree.IsFiltered[Node] := not Match;
      if Match then
      begin
        Parent := Node.Parent;
        while Assigned(Parent) and (Parent <> FTree.RootNode) do
        begin
          if FTree.IsFiltered[Parent] then FTree.IsFiltered[Parent] := False;
          Parent := Parent.Parent;
        end;
      end
      else if FTree.Selected[Node] or (Node.CheckState <> csUncheckedNormal) then
      begin FTree.Selected[Node] := False; Node.CheckState := csUncheckedNormal; end;
    end;
    FVisible.Clear; FVisible.AddRange(NewVisible);
    Result := FVisible.Count;
    FApplied.Clear; for Pair in FValues do FApplied.Add(Pair.Key,Pair.Value);
    FAppliedSensitive.Clear;
    for Sensitive in FSensitive do FAppliedSensitive.Add(Sensitive.Key,Sensitive.Value);
    FCaseChanged := False; FHaveResult := True;
    if SelectBook and (FVisible.IndexOf(FTree.FocusedNode) < 0) then
    begin
      FTree.ClearSelection;
      FirstBook := nil;
      if FVisible.Count > 0 then FirstBook := FVisible[0];
      FTree.FocusedNode := FirstBook;
      if Assigned(FirstBook) then begin FTree.Selected[FirstBook] := True; FTree.FullyVisible[FirstBook] := True; end;
    end;
    finally FTree.EndUpdate; end;
  finally NewVisible.Free; end;
end;

type
  TFilterEditor = class(TForm)
    DateMode: TComboBox;
    DateFrom, DateTo: TDateTimePicker;
    procedure DateChanged(Sender: TObject);
    procedure ResetFilter(Sender: TObject);
  end;

procedure TFilterEditor.DateChanged(Sender: TObject);
begin
  DateFrom.Enabled := DateMode.ItemIndex > 0;
  DateTo.Visible := DateMode.ItemIndex = 6;
end;

procedure TFilterEditor.ResetFilter(Sender: TObject);
begin ModalResult := mrYes; end;

const SizeUnits: array[0..3] of Extended = (1, 1024, 1048576, 1073741824);

type
  TNumericFilterEditor = class
    ColumnTag: Integer;
    Mode, Units: TComboBox;
    FromValue, ToValue: TEdit;
    BetweenLabel: TLabel;
    constructor Create(Owner: TForm; Parent: TWinControl; Tag, Y: Integer; const Current: string);
    procedure Changed(Sender: TObject);
    function GetValue(out Value: string): Boolean;
  end;

constructor TNumericFilterEditor.Create(Owner: TForm; Parent: TWinControl; Tag, Y: Integer; const Current: string);
var Parts: TArray<string>; Number: Extended; Factor: Extended; Start, FieldWidth, Gap, UnitWidth: Integer;
begin
  inherited Create; ColumnTag := Tag;
  Start := 175; FieldWidth := 145; Gap := 30; UnitWidth := 115;
  if Owner.ClientWidth < 500 then begin Start := 12; FieldWidth := 100; Gap := 28; UnitWidth := 74; end;
  Mode := TComboBox.Create(Owner); Mode.Parent := Parent;
  Mode.SetBounds(Start, Y, Parent.ClientWidth - Start - 12, 25); Mode.Anchors := [akLeft, akTop, akRight];
  Mode.Style := csDropDownList;
  Mode.Items.AddStrings(['Любое значение', 'Равно', 'Не меньше (≥)', 'Не больше (≤)',
    'Больше (>)', 'Меньше (<)', 'Между (включительно)', 'Не равно']); Mode.ItemIndex := 0;
  FromValue := TEdit.Create(Owner); FromValue.Parent := Parent; FromValue.SetBounds(Start, Y + 32, FieldWidth, 25);
  BetweenLabel := TLabel.Create(Owner); BetweenLabel.Parent := Parent;
  BetweenLabel.SetBounds(Start + FieldWidth + 9, Y + 37, 18, 20); BetweenLabel.Caption := 'и';
  ToValue := TEdit.Create(Owner); ToValue.Parent := Parent; ToValue.SetBounds(Start + FieldWidth + Gap, Y + 32, FieldWidth, 25);
  if Tag = COL_SIZE then
  begin
    Units := TComboBox.Create(Owner); Units.Parent := Parent; Units.SetBounds(Parent.ClientWidth - UnitWidth - 12, Y + 32, UnitWidth, 25);
    Units.Style := csDropDownList; Units.Items.AddStrings(['Байты', 'КБ', 'МБ', 'ГБ']); Units.ItemIndex := 2;
  end;
  Parts := Current.Split([';']); Factor := 1;
  if (Length(Parts) >= 4) and (Parts[0] = 'num') then
  begin
    Mode.ItemIndex := EnsureRange(StrToIntDef(Parts[1], 0), 0, 7);
    if Assigned(Units) then
    begin
      if Length(Parts) > 4 then Units.ItemIndex := EnsureRange(StrToIntDef(Parts[4], 0), 0, 3)
      else Units.ItemIndex := 0;
      Factor := SizeUnits[Units.ItemIndex];
    end;
    if TryStrToFloat(Parts[2], Number, TFormatSettings.Invariant) then FromValue.Text := FloatToStr(Number / Factor);
    if TryStrToFloat(Parts[3], Number, TFormatSettings.Invariant) then ToValue.Text := FloatToStr(Number / Factor);
  end;
  Mode.OnChange := Changed; Changed(nil);
end;

procedure TNumericFilterEditor.Changed(Sender: TObject);
begin
  FromValue.Enabled := Mode.ItemIndex > 0;
  ToValue.Visible := Mode.ItemIndex = 6; BetweenLabel.Visible := ToValue.Visible;
  if Assigned(Units) then Units.Enabled := FromValue.Enabled;
end;

function TNumericFilterEditor.GetValue(out Value: string): Boolean;
var Lower, Upper, Factor: Extended; UnitIndex: Integer;
  function ReadNumber(const Text: string; out Number: Extended): Boolean;
  begin
    Result := (TryStrToFloat(Text.Trim, Number) or TryStrToFloat(Text.Trim, Number, TFormatSettings.Invariant)) and
      not IsNan(Number) and not IsInfinite(Number);
  end;
begin
  Value := ''; Result := True;
  if Mode.ItemIndex = 0 then Exit;
  if not ReadNumber(FromValue.Text, Lower) then Exit(False);
  Upper := Lower;
  if (Mode.ItemIndex = 6) and (not ReadNumber(ToValue.Text, Upper) or (Lower > Upper)) then Exit(False);
  if (ColumnTag = COL_SIZE) and ((Lower < 0) or (Upper < 0)) then Exit(False);
  Factor := 1; UnitIndex := 0;
  if Assigned(Units) then begin UnitIndex := Units.ItemIndex; Factor := SizeUnits[UnitIndex]; end;
  Lower := Lower * Factor; Upper := Upper * Factor;
  if IsNan(Lower) or IsInfinite(Lower) or IsNan(Upper) or IsInfinite(Upper) then Exit(False);
  Value := 'num;' + IntToStr(Mode.ItemIndex) + ';' + FloatToStr(Lower, TFormatSettings.Invariant) + ';' +
    FloatToStr(Upper, TFormatSettings.Invariant) + ';' + IntToStr(UnitIndex);
end;

function EditFilters(Tree: TBookTree; OnlyTag: Integer): Boolean;
var Dialog: TFilterEditor; Scroll: TScrollBox; Description: TLabel; Footer: TPanel;
  ApplyButton, CancelButton, ResetButton: TButton; Editors: TDictionary<Integer, TWinControl>;
  CaseChecks: TObjectDictionary<Integer,TCheckBox>; Ratings: TDictionary<Integer,TCheckListBox>; RatingList: TCheckListBox; CaseCheck: TCheckBox; RatingIndex: Integer;
  Edit: TEdit; Choice: TComboBox; LabelControl: TLabel; I, Tag, Y, FieldLeft: Integer;
  Filters: TBookColumnFilters; Options: TObjectDictionary<Integer, TStringList>;
  Names: TStringList; Node: PVirtualNode; Book: PBookRecord; Genre: TGenreData;
  Current: string; NumericEditors: TObjectDictionary<Integer, TNumericFilterEditor>;
  NumericValues: TDictionary<Integer, string>; Numeric: TNumericFilterEditor; Valid: Boolean; Parts: TArray<string>; Day: TDateTime; P: TPoint; WorkArea: TRect;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  Dialog := TFilterEditor.CreateNew(nil);
  Editors := TDictionary<Integer, TWinControl>.Create;
  Options := TObjectDictionary<Integer, TStringList>.Create([doOwnsValues]);
  NumericEditors := TObjectDictionary<Integer, TNumericFilterEditor>.Create([doOwnsValues]);
  NumericValues := TDictionary<Integer, string>.Create;
  CaseChecks := TObjectDictionary<Integer,TCheckBox>.Create([]);
  Ratings := TDictionary<Integer,TCheckListBox>.Create;
  try
    for Tag in TArray<Integer>.Create(COL_COLLECTION,COL_GENRE,COL_TYPE,COL_LANG,COL_SERIES,COL_PUBLISHER_SERIES) do
    begin
      if (OnlyTag >= 0) and (OnlyTag <> Tag) then Continue;
      Names := TStringList.Create; Names.Sorted := True; Names.CaseSensitive := False;
      Names.Duplicates := dupIgnore; Options.Add(Tag, Names);
      Filters.GetOptions(Tag,Names);
      Current := Filters.Value(Tag);
      if Current.StartsWith('=') then Names.Add(Copy(Current,2,MaxInt));
    end;
    Dialog.Caption := 'Фильтры столбцов';
    if OnlyTag >= 0 then
      for I := Low(ColumnTags) to High(ColumnTags) do
        if ColumnTags[I] = OnlyTag then Dialog.Caption := 'Фильтр: ' + ColumnNames[I];
    Dialog.Position := poMainFormCenter;
    Dialog.ClientWidth := 650; Dialog.ClientHeight := 560;
    Dialog.Constraints.MinWidth := 540; Dialog.Constraints.MinHeight := 220;
    FieldLeft := 175;
    if OnlyTag >= 0 then
    begin
      Dialog.BorderStyle := bsDialog;
      Dialog.Constraints.MinWidth := 0; Dialog.Constraints.MinHeight := 0;
      Dialog.ClientWidth := 360; FieldLeft := 12;
    end;
    Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9; Dialog.DoubleBuffered := True;
    Description := TLabel.Create(Dialog); Description.Parent := Dialog; Description.Align := alTop;
    Description.AutoSize := False; Description.Height := 48; Description.WordWrap := True;
    Description.Caption := 'Фильтр текущего списка. Условия разных столбцов действуют вместе.' +
      sLineBreak + 'Текст — часть без учёта регистра; списки — точный выбор. Пустое поле снимает фильтр.';
    if OnlyTag >= 0 then
    begin
      Description.Height := 32;
      Description.Caption := 'По загруженным книгам. Условия столбцов действуют вместе.';
    end;
    Footer := TPanel.Create(Dialog); Footer.Parent := Dialog; Footer.Align := alBottom;
    Footer.Height := 44; Footer.BevelOuter := bvNone;
    ApplyButton := TButton.Create(Dialog); ApplyButton.Parent := Footer;
    ApplyButton.SetBounds(Dialog.ClientWidth - 226, 6, 100, 28); ApplyButton.Anchors := [akRight, akTop];
    ApplyButton.Caption := 'Применить'; ApplyButton.Default := True; ApplyButton.ModalResult := mrOk;
    CancelButton := TButton.Create(Dialog); CancelButton.Parent := Footer;
    CancelButton.SetBounds(Dialog.ClientWidth - 116, 6, 100, 28); CancelButton.Anchors := [akRight, akTop];
    CancelButton.Caption := 'Отмена'; CancelButton.Cancel := True; CancelButton.ModalResult := mrCancel;
    if OnlyTag >= 0 then
    begin
      ResetButton := TButton.Create(Dialog); ResetButton.Parent := Footer;
      ResetButton.SetBounds(12, 6, 100, 28); ResetButton.Caption := 'Сбросить'; ResetButton.OnClick := Dialog.ResetFilter;
    end;
    Scroll := TScrollBox.Create(Dialog); Scroll.Parent := Dialog; Scroll.Align := alClient;
    Scroll.BorderStyle := bsNone; Y := 2;
    for I := Low(ColumnTags) to High(ColumnTags) do
    begin
      Tag := ColumnTags[I];
      if (OnlyTag < 0) and (Tag in [COL_LIBRATE, COL_LIBID]) then Continue;
      if (OnlyTag >= 0) and (OnlyTag <> Tag) then Continue;
      if OnlyTag < 0 then
      begin
        LabelControl := TLabel.Create(Dialog); LabelControl.Parent := Scroll;
        LabelControl.SetBounds(12, Y + 5, 155, 20); LabelControl.Caption := ColumnNames[I];
      end;
      Current := Filters.Value(Tag);
      if Tag in [COL_RATE,COL_LIBRATE] then
      begin
        RatingList := TCheckListBox.Create(Dialog); RatingList.Parent := Scroll;
        RatingList.SetBounds(FieldLeft,Y,Scroll.ClientWidth-FieldLeft-12,132);
        RatingList.Items.Add('Без оценки');
        for RatingIndex := 1 to 5 do RatingList.Items.Add(StringOfChar('★',RatingIndex));
        for RatingIndex := 0 to 5 do
          RatingList.Checked[RatingIndex] := (Current = '') or (Pos(';'+IntToStr(RatingIndex)+';',Current+';') > 0);
        Ratings.Add(Tag,RatingList); Inc(Y,108);
      end
      else if Tag in [COL_SIZE, COL_NO] then
      begin
        Numeric := TNumericFilterEditor.Create(Dialog, Scroll, Tag, Y, Current);
        NumericEditors.Add(Tag, Numeric); Inc(Y, 32);
      end
      else if Tag = COL_DATE then
      begin
        Dialog.DateMode := TComboBox.Create(Dialog); Dialog.DateMode.Parent := Scroll;
        Dialog.DateMode.SetBounds(FieldLeft, Y, Scroll.ClientWidth - FieldLeft - 12, 25);
        Dialog.DateMode.Style := csDropDownList;
        Dialog.DateMode.Items.AddStrings(['Любая дата', 'В этот день', 'С этой даты (включительно)',
          'До этой даты (включительно)', 'После этой даты', 'Раньше этой даты', 'Между датами (включительно)']);
        Dialog.DateMode.ItemIndex := 0;
        Dialog.DateFrom := TDateTimePicker.Create(Dialog); Dialog.DateFrom.Parent := Scroll;
        Dialog.DateFrom.SetBounds(FieldLeft, Y + 32, 155, 25); Dialog.DateFrom.Date := Date;
        Dialog.DateTo := TDateTimePicker.Create(Dialog); Dialog.DateTo.Parent := Scroll;
        Dialog.DateTo.SetBounds(FieldLeft + 173, Y + 32, 155, 25); Dialog.DateTo.Date := Date;
        Parts := Current.Split([';']);
        if (Length(Parts) = 4) and (Parts[0] = 'date') then
        begin
          Dialog.DateMode.ItemIndex := EnsureRange(StrToIntDef(Parts[1], 0), 0, 6);
          Day := ISODate(Parts[2]); if Day <> 0 then Dialog.DateFrom.Date := Day;
          Day := ISODate(Parts[3]); if Day <> 0 then Dialog.DateTo.Date := Day;
        end;
        Dialog.DateMode.OnChange := Dialog.DateChanged; Dialog.DateChanged(nil);
        Inc(Y, 32);
      end
      else if Options.TryGetValue(Tag, Names) then
      begin
        Choice := TComboBox.Create(Dialog); Choice.Parent := Scroll;
        Choice.SetBounds(FieldLeft, Y, Scroll.ClientWidth - FieldLeft - 12, 25);
        Choice.Anchors := [akLeft, akTop, akRight]; Choice.Style := csDropDownList;
        Choice.Items.Add('Все'); Choice.Items.AddStrings(Names);
        if Current.StartsWith('=') then Current := Copy(Current, 2, MaxInt);
        if (Current <> '') and (Choice.Items.IndexOf(Current) < 0) then Choice.Items.Add(Current);
        Choice.ItemIndex := Max(0, Choice.Items.IndexOf(Current)); Editors.Add(Tag, Choice);
      end
      else
      begin
        Edit := TEdit.Create(Dialog); Edit.Parent := Scroll;
        Edit.SetBounds(FieldLeft, Y, Scroll.ClientWidth - FieldLeft - 12, 25);
        Edit.Anchors := [akLeft, akTop, akRight]; Edit.Text := Current; Editors.Add(Tag, Edit);
      end;
      if Tag in [COL_AUTHOR,COL_TITLE,COL_SERIES,COL_PUBLISHER_SERIES,COL_GENRE,COL_TYPE,COL_COLLECTION,COL_LANG,COL_LIBID] then
      begin
        CaseCheck := TCheckBox.Create(Dialog); CaseCheck.Parent := Scroll;
        CaseCheck.SetBounds(FieldLeft,Y+29,220,22); CaseCheck.Caption := 'Учитывать регистр';
        CaseCheck.Checked := Filters.CaseSensitive(Tag); CaseChecks.Add(Tag,CaseCheck); Inc(Y,26);
      end;
      Inc(Y, 34);
    end;
    if OnlyTag >= 0 then
    begin
      Dialog.ClientHeight := Y + Description.Height + Footer.Height + 8; Dialog.Position := poDesigned;
    end;
    Dialog.ScaleForPPI(Tree.CurrentPPI);
    if OnlyTag >= 0 then
    begin
      GetCursorPos(P); WorkArea := Screen.MonitorFromPoint(P).WorkareaRect;
      Dialog.Left := EnsureRange(P.X - Dialog.Width div 2, WorkArea.Left, Max(WorkArea.Left, WorkArea.Right - Dialog.Width));
      Dialog.Top := EnsureRange(P.Y + 12, WorkArea.Top, Max(WorkArea.Top, WorkArea.Bottom - Dialog.Height));
    end;
    repeat
      Dialog.ShowModal;
      Result := Dialog.ModalResult in [mrOk, mrYes];
      if not Result then Break;
      if (Dialog.ModalResult = mrYes) and (OnlyTag >= 0) then
      begin Filters.SetValue(OnlyTag, ''); Break; end;
      if Assigned(Dialog.DateMode) and (Dialog.DateMode.ItemIndex = 6) and
        (DateOf(Dialog.DateFrom.Date) > DateOf(Dialog.DateTo.Date)) then
      begin Application.MessageBox('Начальная дата должна быть не позже конечной.', 'Фильтр даты', MB_OK); Continue; end;
      Valid := True; NumericValues.Clear;
      for Tag in NumericEditors.Keys do
      begin
        if not NumericEditors[Tag].GetValue(Current) then Valid := False;
        NumericValues.Add(Tag, Current);
      end;
      if not Valid then
      begin
        Application.MessageBox('Введите число. Для диапазона начальное значение должно быть не больше конечного.',
          'Числовой фильтр', MB_OK); Continue;
      end;
      for Tag in NumericValues.Keys do Filters.SetValue(Tag, NumericValues[Tag]);
      for Tag in Ratings.Keys do
      begin
        RatingList := Ratings[Tag]; Current := 'set'; RatingIndex := 0;
        for I := 0 to 5 do if RatingList.Checked[I] then begin Current := Current+';'+IntToStr(I); Inc(RatingIndex); end;
        if RatingIndex = 6 then Current := '';
        Filters.SetValue(Tag,Current);
      end;
      for Tag in CaseChecks.Keys do Filters.SetCaseSensitive(Tag,CaseChecks[Tag].Checked);
      for Tag in Editors.Keys do
        if Editors[Tag] is TComboBox then
        begin
          Choice := TComboBox(Editors[Tag]); Current := '';
          if Choice.ItemIndex > 0 then Current := '=' + Choice.Text;
          Filters.SetValue(Tag, Current);
        end
        else Filters.SetValue(Tag, TEdit(Editors[Tag]).Text);
      if Assigned(Dialog.DateMode) then
      begin
        Current := '';
        if Dialog.DateMode.ItemIndex > 0 then Current := 'date;' + IntToStr(Dialog.DateMode.ItemIndex) + ';' +
          FormatDateTime('yyyy-mm-dd', Dialog.DateFrom.Date) + ';' + FormatDateTime('yyyy-mm-dd', Dialog.DateTo.Date);
        Filters.SetValue(COL_DATE, Current);
      end;
      Break;
    until False;
  finally Ratings.Free; CaseChecks.Free; NumericValues.Free; NumericEditors.Free; Options.Free; Editors.Free; Dialog.Free; end;
end;

type
  TListFilterEditor = class(TForm)
  private
    FNames, FFolded: TStringList;
    FFound: TList<Integer>;
    FChecked: TDictionary<string,Byte>;
    FAll, FBuilding, FLastSensitive: Boolean;
    FSearch: TEdit;
    FList: TVirtualStringTree;
    FCase: TCheckBox;
    FCount: TLabel;
    function Key(Index: Integer): string;
    function Chosen(Index: Integer): Boolean;
    procedure SearchChanged(Sender: TObject);
    procedure InitItem(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
      var InitialStates: TVirtualNodeInitStates);
    procedure ItemText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure ItemChecked(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure SelectFound(Sender: TObject);
  public
    constructor CreateList(Tree: TBookTree; Filters: TBookColumnFilters; Tag: Integer);
    destructor Destroy; override;
    function SelectedValue: string;
  end;

function TListFilterEditor.Key(Index: Integer): string;
begin
  if FLastSensitive then Result := NormalizeYo(FNames[Index])
  else Result := FoldText(FNames[Index]);
end;

function TListFilterEditor.Chosen(Index: Integer): Boolean;
begin
  Result := FChecked.ContainsKey(Key(Index));
  if FAll then Result := not Result;
end;

constructor TListFilterEditor.CreateList(Tree: TBookTree; Filters: TBookColumnFilters; Tag: Integer);
var SearchPanel, Footer: TPanel; Button: TButton; I: Integer; Selected: TStringList;
  P: TPoint; Area: TRect;
begin
  inherited CreateNew(nil);
  FNames := TStringList.Create; FFolded := TStringList.Create;
  FFound := TList<Integer>.Create; FChecked := TDictionary<string,Byte>.Create;
  Caption := 'Фильтр';
  for I := Low(ColumnTags) to High(ColumnTags) do
    if ColumnTags[I] = Tag then Caption := 'Фильтр: '+ColumnNames[I];
  BorderStyle := bsDialog; Position := poDesigned;
  ClientWidth := 360; ClientHeight := 370;
  Font.Name := 'Segoe UI'; Font.Size := 9; DoubleBuffered := True;
  SearchPanel := TPanel.Create(Self); SearchPanel.Parent := Self; SearchPanel.Align := alTop;
  SearchPanel.Height := 102; SearchPanel.BevelOuter := bvNone;
  FSearch := TEdit.Create(Self); FSearch.Parent := SearchPanel; FSearch.SetBounds(12,10,336,25);
  FSearch.TextHint := 'Поиск по вариантам…'; FSearch.OnChange := SearchChanged;
  FCase := TCheckBox.Create(Self); FCase.Parent := SearchPanel; FCase.SetBounds(12,41,220,22);
  FCase.Caption := 'Учитывать регистр'; FCase.Checked := Filters.CaseSensitive(Tag);
  FLastSensitive := FCase.Checked; FCase.OnClick := SearchChanged;
  Button := TButton.Create(Self); Button.Parent := SearchPanel; Button.SetBounds(12,69,163,25);
  Button.Caption := 'Выбрать найденные'; Button.Tag := 1; Button.OnClick := SelectFound;
  Button := TButton.Create(Self); Button.Parent := SearchPanel; Button.SetBounds(185,69,163,25);
  Button.Caption := 'Снять всё'; Button.OnClick := SelectFound;
  Footer := TPanel.Create(Self); Footer.Parent := Self; Footer.Align := alBottom;
  Footer.Height := 63; Footer.BevelOuter := bvNone;
  FCount := TLabel.Create(Self); FCount.Parent := Footer; FCount.SetBounds(12,2,336,18);
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(12,26,100,28);
  Button.Caption := 'Сбросить'; Button.ModalResult := mrYes;
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(124,26,112,28);
  Button.Caption := 'Применить'; Button.ModalResult := mrOk; Button.Default := True;
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(248,26,100,28);
  Button.Caption := 'Отмена'; Button.ModalResult := mrCancel; Button.Cancel := True;
  FList := TVirtualStringTree.Create(Self); FList.Parent := Self; FList.Align := alClient;
  FList.NodeDataSize := 0; FList.Header.Options := [];
  FList.TreeOptions.MiscOptions := [toCheckSupport];
  FList.TreeOptions.PaintOptions := [toThemeAware];
  FList.TreeOptions.SelectionOptions := [toFullRowSelect];
  FList.OnInitNode := InitItem; FList.OnGetText := ItemText; FList.OnChecked := ItemChecked;
  Filters.GetOptions(Tag,FNames);
  Selected := TStringList.Create;
  try
    FAll := Filters.Value(Tag) = '';
    Filters.GetSelectedValues(Tag,Selected);
    // Keep earlier choices even if another column temporarily hides those values.
    for I := 0 to Selected.Count-1 do
    begin
      if FLastSensitive then FChecked.TryAdd(NormalizeYo(Selected[I]),0)
      else FChecked.TryAdd(FoldText(Selected[I]),0);
      if FNames.IndexOf(Selected[I]) < 0 then FNames.Add(Selected[I]);
    end;
  finally Selected.Free; end;
  for I := 0 to FNames.Count-1 do FFolded.Add(FoldText(FNames[I]));
  SearchChanged(nil); ActiveControl := FSearch;
  ScaleForPPI(Tree.CurrentPPI);
  GetCursorPos(P); Area := Screen.MonitorFromPoint(P).WorkareaRect;
  Left := EnsureRange(P.X-Width div 2,Area.Left,Max(Area.Left,Area.Right-Width));
  Top := EnsureRange(P.Y+12,Area.Top,Max(Area.Top,Area.Bottom-Height));
end;

destructor TListFilterEditor.Destroy;
begin
  FBuilding := True; FList.OnGetText := nil; FList.OnInitNode := nil;
  FList.OnChecked := nil; FList.Clear;
  FChecked.Free; FFound.Free; FFolded.Free; FNames.Free;
  inherited;
end;

procedure TListFilterEditor.SearchChanged(Sender: TObject);
var I: Integer; Pattern, Text: string; Selected: TList<Integer>;
  Seen: TDictionary<string,Byte>;
begin
  if not Assigned(FList) then Exit;
  if FLastSensitive <> FCase.Checked then
  begin
    Selected := TList<Integer>.Create;
    try
      for I := 0 to FNames.Count-1 do if Chosen(I) then Selected.Add(I);
      FAll := False; FChecked.Clear; FLastSensitive := FCase.Checked;
      for I in Selected do FChecked.TryAdd(Key(I),0);
    finally Selected.Free; end;
  end;
  if FCase.Checked then Pattern := NormalizeYo(FSearch.Text) else Pattern := FoldText(FSearch.Text);
  FBuilding := True;
  Seen := TDictionary<string,Byte>.Create;
  FList.BeginUpdate;
  try
    FList.Clear; FFound.Clear;
    for I := 0 to FNames.Count-1 do
    begin
      if FCase.Checked then Text := NormalizeYo(FNames[I]) else Text := FFolded[I];
      if ((Pattern = '') or (Pos(Pattern,Text) > 0)) and Seen.TryAdd(Key(I),0) then FFound.Add(I);
    end;
    FList.RootNodeCount := FFound.Count;
    FCount.Caption := 'Найдено: '+IntToStr(FFound.Count)+' из '+IntToStr(FNames.Count);
  finally FList.EndUpdate; Seen.Free; FBuilding := False; end;
end;

procedure TListFilterEditor.InitItem(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
  var InitialStates: TVirtualNodeInitStates);
begin
  Node.CheckType := ctCheckBox;
  if Chosen(FFound[Integer(Node.Index)]) then Node.CheckState := csCheckedNormal
  else Node.CheckState := csUncheckedNormal;
end;

procedure TListFilterEditor.ItemText(Sender: TBaseVirtualTree; Node: PVirtualNode;
  Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
begin CellText := FNames[FFound[Integer(Node.Index)]]; end;

procedure TListFilterEditor.ItemChecked(Sender: TBaseVirtualTree; Node: PVirtualNode);
var Checked: Boolean; K: string;
begin
  if FBuilding then Exit;
  Checked := Node.CheckState in [csCheckedNormal,csCheckedPressed];
  if FAll then Checked := not Checked;
  K := Key(FFound[Integer(Node.Index)]);
  if Checked then FChecked.TryAdd(K,0) else FChecked.Remove(K);
end;

procedure TListFilterEditor.SelectFound(Sender: TObject);
var I: Integer; Checked: Boolean;
begin
  if TButton(Sender).Tag = 0 then
  begin FAll := False; FChecked.Clear; end
  else
  begin
    Checked := not FAll;
    for I in FFound do
      if Checked then FChecked.TryAdd(Key(I),0) else FChecked.Remove(Key(I));
  end;
  SearchChanged(nil);
end;

function TListFilterEditor.SelectedValue: string;
var Values: TJSONArray; I, Count: Integer;
begin
  Values := TJSONArray.Create; Count := 0;
  try
    for I := 0 to FNames.Count-1 do if Chosen(I) then begin Values.Add(FNames[I]); Inc(Count); end;
    if Count = FNames.Count then Result := '' else Result := 'values:'+Values.ToJSON;
  finally Values.Free; end;
end;

function EditListFilter(Tree: TBookTree; Tag: Integer): Boolean;
var Dialog: TListFilterEditor; Filters: TBookColumnFilters; Answer: Integer;
begin
  Filters := TBookColumnFilters.ForTree(Tree); Dialog := TListFilterEditor.CreateList(Tree,Filters,Tag);
  try
    Answer := Dialog.ShowModal; Result := Answer in [mrOk,mrYes];
    if Answer = mrYes then Filters.SetValue(Tag,'')
    else if Answer = mrOk then
    begin Filters.SetCaseSensitive(Tag,Dialog.FCase.Checked); Filters.SetValue(Tag,Dialog.SelectedValue); end;
  finally Dialog.Free; end;
end;

type
  TAllFiltersEditor = class(TForm)
  private
    FTree: TBookTree;
    procedure EditColumn(Sender: TObject);
  end;

procedure TAllFiltersEditor.EditColumn(Sender: TObject);
var Button: TButton; Filters: TBookColumnFilters; I: Integer;
begin
  Button := TButton(Sender); Filters := TBookColumnFilters.ForTree(FTree);
  if not EditBookColumnFilter(FTree,Button.Tag) then Exit;
  for I := Low(ColumnTags) to High(ColumnTags) do if ColumnTags[I] = Button.Tag then
  begin
    Button.Caption := ColumnNames[I];
    if Filters.Value(Button.Tag) <> '' then Button.Caption := Button.Caption+' • фильтр задан';
    Break;
  end;
end;

function EditBookColumnFilters(Tree: TBookTree): Boolean;
var Dialog: TAllFiltersEditor; Scroll: TScrollBox; Footer: TPanel; Button: TButton;
  Filters: TBookColumnFilters; Saved: TArray<string>; Sensitive: TArray<Boolean>; I, Y: Integer;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  SetLength(Saved,Length(ColumnTags)); SetLength(Sensitive,Length(ColumnTags));
  for I := Low(ColumnTags) to High(ColumnTags) do
  begin Saved[I] := Filters.Value(ColumnTags[I]); Sensitive[I] := Filters.CaseSensitive(ColumnTags[I]); end;
  Dialog := TAllFiltersEditor.CreateNew(nil); Result := False;
  try
    Dialog.FTree := Tree; Dialog.Caption := 'Фильтры столбцов'; Dialog.Position := poMainFormCenter;
    Dialog.ClientWidth := 360; Dialog.ClientHeight := 450;
    Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9;
    Footer := TPanel.Create(Dialog); Footer.Parent := Dialog; Footer.Align := alBottom;
    Footer.Height := 44; Footer.BevelOuter := bvNone;
    Button := TButton.Create(Dialog); Button.Parent := Footer; Button.SetBounds(124,6,112,28);
    Button.Caption := 'Применить'; Button.ModalResult := mrOk; Button.Default := True;
    Button := TButton.Create(Dialog); Button.Parent := Footer; Button.SetBounds(248,6,100,28);
    Button.Caption := 'Отмена'; Button.ModalResult := mrCancel; Button.Cancel := True;
    Scroll := TScrollBox.Create(Dialog); Scroll.Parent := Dialog; Scroll.Align := alClient; Y := 10;
    for I := Low(ColumnTags) to High(ColumnTags) do
    begin
      if ColumnTags[I] in [COL_LIBRATE,COL_LIBID] then Continue;
      Button := TButton.Create(Dialog); Button.Parent := Scroll; Button.SetBounds(12,Y,320,30);
      Button.Tag := ColumnTags[I]; Button.Caption := ColumnNames[I];
      if Saved[I] <> '' then Button.Caption := Button.Caption+' • фильтр задан';
      Button.OnClick := Dialog.EditColumn; Inc(Y,36);
    end;
    Dialog.ScaleForPPI(Tree.CurrentPPI); Result := Dialog.ShowModal = mrOk;
  finally
    if not Result then for I := Low(ColumnTags) to High(ColumnTags) do
    begin Filters.SetValue(ColumnTags[I],Saved[I]); Filters.SetCaseSensitive(ColumnTags[I],Sensitive[I]); end;
    Dialog.Free;
  end;
end;

function EditBookColumnFilter(Tree: TBookTree; Tag: Integer): Boolean;
begin
  if Tag in [COL_AUTHOR,COL_SERIES,COL_PUBLISHER_SERIES,COL_GENRE,COL_TYPE,COL_COLLECTION,COL_LANG] then
    Result := EditListFilter(Tree,Tag)
  else Result := EditFilters(Tree,Tag);
end;

end.
