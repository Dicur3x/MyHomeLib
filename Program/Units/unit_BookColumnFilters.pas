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
    FFavoriteAuthorsOnly, FAppliedFavoriteAuthorsOnly: Boolean;
    FFavoriteKeyRevision: UInt64;
    FFavoriteKeys: TDictionary<string, Byte>;
    FFavoriteMatches: TDictionary<string, Boolean>;
    procedure SyncFavoriteKeys;
    procedure CopyConfiguration(Source: TBookColumnFilters);
    procedure SetFavoriteAuthorsOnly(Enabled: Boolean);
    function MatchesFavoriteAuthors(const Book: TBookRecord): Boolean;
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
    property FavoriteAuthorsOnly: Boolean read FFavoriteAuthorsOnly write SetFavoriteAuthorsOnly;
  end;

// The main form supplies its cached set; filtering never opens a database.
function SetFavoriteAuthorFilterKeys(const Keys: TArray<string>): Boolean;
function EditBookColumnFilters(Tree: TBookTree): Boolean;
function EditBookColumnFilter(Tree: TBookTree; Tag: Integer): Boolean;

const COL_PUBLISHER_SERIES_FILTER = COL_PUBLISHER_SERIES;

implementation

uses System.StrUtils, System.DateUtils, System.Math, Winapi.Windows, Vcl.Forms,
  Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, unit_MHLHelpers,
  System.Types, Vcl.CheckLst, System.JSON, VirtualTrees.Types, unit_MHLTheme,
  unit_AuthorFavorites;

var FavoriteAuthorKeys: TArray<string>;
    FavoriteAuthorKeysRevision: UInt64 = 1;

function SetFavoriteAuthorFilterKeys(const Keys: TArray<string>): Boolean;
var NewKeys: TDictionary<string,Byte>; Key: string; Same: Boolean;
begin
  NewKeys := TDictionary<string,Byte>.Create;
  try
    // Profile keys are canonical hashes. Treat order and duplicates as a set;
    // background metadata refreshes must not invalidate an unchanged filter.
    for var Value in Keys do
    begin
      Key := LowerCase(Trim(Value));
      if Key <> '' then NewKeys.TryAdd(Key,0);
    end;
    Same := NewKeys.Count = Length(FavoriteAuthorKeys);
    if Same then
      for Key in FavoriteAuthorKeys do
        if not NewKeys.ContainsKey(Key) then begin Same := False; Break; end;
    Result := not Same;
    if not Result then Exit;
    FavoriteAuthorKeys := NewKeys.Keys.ToArray; Inc(FavoriteAuthorKeysRevision);
  finally NewKeys.Free; end;
end;

procedure TBookColumnFilters.SyncFavoriteKeys;
begin
  if FFavoriteKeyRevision = FavoriteAuthorKeysRevision then Exit;
  FFavoriteKeys.Clear;
  for var Key in FavoriteAuthorKeys do FFavoriteKeys.TryAdd(Key, 0);
  FFavoriteMatches.Clear;
  FFavoriteKeyRevision := FavoriteAuthorKeysRevision;
  FOptionCache.Clear;
  FHaveResult := False;
end;

procedure TBookColumnFilters.CopyConfiguration(Source: TBookColumnFilters);
var Pair: TPair<Integer,string>; Sensitive: TPair<Integer,Boolean>; SameSensitivity: Boolean;
begin
  SameSensitivity := FSensitive.Count = Source.FSensitive.Count;
  if SameSensitivity then
    for Sensitive in Source.FSensitive do
      if not FSensitive.ContainsKey(Sensitive.Key) then begin SameSensitivity := False; Break; end;
  if (FFavoriteAuthorsOnly <> Source.FFavoriteAuthorsOnly) or not SameSensitivity then FCaseChanged := True;
  FValues.Clear; for Pair in Source.FValues do FValues.Add(Pair.Key,Pair.Value);
  FSensitive.Clear; for Sensitive in Source.FSensitive do FSensitive.Add(Sensitive.Key,Sensitive.Value);
  FFavoriteAuthorsOnly := Source.FFavoriteAuthorsOnly; FOptionCache.Clear;
end;

procedure TBookColumnFilters.SetFavoriteAuthorsOnly(Enabled: Boolean);
begin
  if FFavoriteAuthorsOnly = Enabled then Exit;
  FFavoriteAuthorsOnly := Enabled;
  FCaseChanged := True;
  FOptionCache.Clear;
end;

function TBookColumnFilters.MatchesFavoriteAuthors(const Book: TBookRecord): Boolean;
var RawKey: string; Favorite: Boolean;
begin
  if FFavoriteKeys.Count = 0 then Exit(False);
  for var Author in Book.Authors do
  begin
    RawKey := IntToStr(Length(Author.LastName)) + ':' + Author.LastName +
      IntToStr(Length(Author.FirstName)) + ':' + Author.FirstName +
      IntToStr(Length(Author.MiddleName)) + ':' + Author.MiddleName;
    if not FFavoriteMatches.TryGetValue(RawKey, Favorite) then
    begin
      try
        Favorite := FFavoriteKeys.ContainsKey(LowerCase(AuthorFavoriteKey(
          Author.LastName, Author.FirstName, Author.MiddleName)));
      except
        // Malformed catalog names cannot be favorites. Do not let one bad
        // coauthor stop filtering valid authors or cache its oversized name.
        on E: EAuthorFavorites do Continue;
      end;
      if FFavoriteMatches.Count >= 8192 then FFavoriteMatches.Clear;
      FFavoriteMatches.Add(RawKey, Favorite);
    end;
    if Favorite then Exit(True);
  end;
  Result := False;
end;

const
  ColumnTags: array[0..18] of Integer = (COL_AUTHOR, COL_TITLE, COL_SERIES,
    COL_PUBLISHER_SERIES_FILTER, COL_PUBLISHER,
    COL_TRANSLATORS, COL_CITY, COL_PUBYEAR, COL_ISBN,
    COL_NO, COL_GENRE, COL_SIZE, COL_RATE, COL_DATE, COL_TYPE,
    COL_COLLECTION, COL_LANG, COL_LIBRATE, COL_LIBID);
  ColumnNames: array[0..18] of string = ('Автор', 'Название', 'Серия', 'Книжная серия', 'Издательство',
    'Переводчики', 'Город издания', 'Год издания', 'ISBN', '№',
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
  FFavoriteKeys := TDictionary<string, Byte>.Create;
  FFavoriteMatches := TDictionary<string, Boolean>.Create;
  FRevision := High(UInt64);
end;

destructor TBookColumnFilters.Destroy;
begin
  FFavoriteMatches.Free; FFavoriteKeys.Free;
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
  Result := FValues.Count + Ord(FFavoriteAuthorsOnly);
end;

procedure TBookColumnFilters.Clear;
begin
  FFavoriteAuthorsOnly := False;
  FValues.Clear; FSensitive.Clear; FCaseChanged := True;
end;

procedure TBookColumnFilters.RestoreApplied;
var Pair: TPair<Integer,string>; Sensitive: TPair<Integer,Boolean>;
begin
  FFavoriteAuthorsOnly := FAppliedFavoriteAuthorsOnly;
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
    COL_PUBLISHER: Result := Book.Publisher;
    COL_TRANSLATORS: Result := Book.Translators;
    COL_CITY: Result := Book.City;
    COL_PUBYEAR: if Book.PubYear <> 0 then Result := IntToStr(Book.PubYear);
    COL_ISBN: Result := Book.ISBN;
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
  SyncFavoriteKeys;
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
    // Missing publication metadata is a useful exact selection, distinct from
    // clearing a filter. The list editor gives this empty value a readable name.
    if ((Value = '') and not (Tag in [COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_ISBN])) or
      not Raw.TryAdd(Value,0) then Exit;
    // Keep spelling variants available when the user enables case matching.
    // Matching itself still folds case and e/yo unless explicitly requested.
    Key := Value;
    if not Unique.ContainsKey(Key) then Unique.Add(Key,Value);
  end;
begin
  EnsureRows;
  CacheKey := IntToStr(Tag)+':'+BoolToStr(CaseSensitive(Tag)) +
    ':favorites=' + BoolToStr(FFavoriteAuthorsOnly);
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
    else if (C.Tag in [COL_SIZE,COL_NO,COL_RATE,COL_LIBRATE,COL_PUBYEAR]) and (Length(Parts) >= 4) and (Parts[0] = 'num') then
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
  if FAppliedFavoriteAuthorsOnly and not FFavoriteAuthorsOnly then Result := False;
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
  if FFavoriteAuthorsOnly and not MatchesFavoriteAuthors(Book) then Exit(False);
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
        if C.Tag = COL_PUBYEAR then
        begin
          if C.Mode = 8 then begin if Book.PubYear <> 0 then Exit(False); Continue; end;
          if C.Mode = 9 then begin if Book.PubYear = 0 then Exit(False); Continue; end;
          // A missing year is not year zero in a range or inequality.
          if Book.PubYear = 0 then Exit(False);
        end;
        case C.Tag of
          COL_DATE: Number := DateOf(Book.Date);
          COL_SIZE: Number := Book.Size;
          COL_RATE: Number := Book.Rate;
          COL_LIBRATE: Number := Book.LibRate;
          COL_PUBYEAR: Number := Book.PubYear;
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
    FAppliedFavoriteAuthorsOnly := FFavoriteAuthorsOnly;
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
  Mode.Name := 'NumericFilterMode'+IntToStr(Tag);
  Mode.SetBounds(Start, Y, Parent.ClientWidth - Start - 12, 25); Mode.Anchors := [akLeft, akTop, akRight];
  Mode.Style := csDropDownList;
  Mode.Items.AddStrings(['Любое значение', 'Равно', 'Не меньше (≥)', 'Не больше (≤)',
    'Больше (>)', 'Меньше (<)', 'Между (включительно)', 'Не равно']); Mode.ItemIndex := 0;
  if Tag = COL_PUBYEAR then Mode.Items.AddStrings(['Не указан', 'Указан']);
  FromValue := TEdit.Create(Owner); FromValue.Parent := Parent; FromValue.SetBounds(Start, Y + 32, FieldWidth, 25);
  FromValue.Name := 'NumericFilterFrom'+IntToStr(Tag);
  BetweenLabel := TLabel.Create(Owner); BetweenLabel.Parent := Parent;
  BetweenLabel.SetBounds(Start + FieldWidth + 9, Y + 37, 18, 20); BetweenLabel.Caption := 'и';
  ToValue := TEdit.Create(Owner); ToValue.Parent := Parent; ToValue.SetBounds(Start + FieldWidth + Gap, Y + 32, FieldWidth, 25);
  ToValue.Name := 'NumericFilterTo'+IntToStr(Tag);
  if Tag = COL_SIZE then
  begin
    Units := TComboBox.Create(Owner); Units.Parent := Parent; Units.SetBounds(Parent.ClientWidth - UnitWidth - 12, Y + 32, UnitWidth, 25);
    Units.Style := csDropDownList; Units.Items.AddStrings(['Байты', 'КБ', 'МБ', 'ГБ']); Units.ItemIndex := 2;
  end;
  Parts := Current.Split([';']); Factor := 1;
  if (Length(Parts) >= 4) and (Parts[0] = 'num') then
  begin
    Mode.ItemIndex := EnsureRange(StrToIntDef(Parts[1], 0), 0, Mode.Items.Count-1);
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
  FromValue.Enabled := Mode.ItemIndex in [1..7];
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
  if (ColumnTag = COL_PUBYEAR) and (Mode.ItemIndex in [8,9]) then
  begin Value := 'num;'+IntToStr(Mode.ItemIndex)+';0;0;0'; Exit; end;
  if not ReadNumber(FromValue.Text, Lower) then Exit(False);
  Upper := Lower;
  if (Mode.ItemIndex = 6) and (not ReadNumber(ToValue.Text, Upper) or (Lower > Upper)) then Exit(False);
  if (ColumnTag = COL_SIZE) and ((Lower < 0) or (Upper < 0)) then Exit(False);
  if (ColumnTag = COL_PUBYEAR) and ((Lower <= 0) or (Upper <= 0) or (Lower > MaxInt) or (Upper > MaxInt) or
    (Frac(Lower) <> 0) or (Frac(Upper) <> 0)) then Exit(False);
  Factor := 1; UnitIndex := 0;
  if Assigned(Units) then begin UnitIndex := Units.ItemIndex; Factor := SizeUnits[UnitIndex]; end;
  Lower := Lower * Factor; Upper := Upper * Factor;
  if IsNan(Lower) or IsInfinite(Lower) or IsNan(Upper) or IsInfinite(Upper) then Exit(False);
  Value := 'num;' + IntToStr(Mode.ItemIndex) + ';' + FloatToStr(Lower, TFormatSettings.Invariant) + ';' +
    FloatToStr(Upper, TFormatSettings.Invariant) + ';' + IntToStr(UnitIndex);
end;

function EditFilters(Tree: TBookTree; OnlyTag: Integer; OverrideFilters: TBookColumnFilters = nil): Boolean;
var Dialog: TFilterEditor; Scroll: TScrollBox; Description: TLabel; Footer: TPanel;
  ApplyButton, CancelButton, ResetButton: TButton; Editors: TDictionary<Integer, TWinControl>;
  CaseChecks: TObjectDictionary<Integer,TCheckBox>; Ratings: TDictionary<Integer,TCheckListBox>; RatingList: TCheckListBox; CaseCheck: TCheckBox; RatingIndex: Integer;
  Edit: TEdit; Choice: TComboBox; LabelControl: TLabel; I, Tag, Y, FieldLeft: Integer;
  Filters: TBookColumnFilters; Options: TObjectDictionary<Integer, TStringList>;
  Names: TStringList; Node: PVirtualNode; Book: PBookRecord; Genre: TGenreData;
  Current: string; NumericEditors: TObjectDictionary<Integer, TNumericFilterEditor>;
  NumericValues: TDictionary<Integer, string>; Numeric: TNumericFilterEditor; Valid: Boolean; Parts: TArray<string>; Day: TDateTime; P: TPoint; WorkArea: TRect;
begin
  Filters := OverrideFilters;
  if not Assigned(Filters) then Filters := TBookColumnFilters.ForTree(Tree);
  Dialog := TFilterEditor.CreateNew(nil);
  Editors := TDictionary<Integer, TWinControl>.Create;
  Options := TObjectDictionary<Integer, TStringList>.Create([doOwnsValues]);
  NumericEditors := TObjectDictionary<Integer, TNumericFilterEditor>.Create([doOwnsValues]);
  NumericValues := TDictionary<Integer, string>.Create;
  CaseChecks := TObjectDictionary<Integer,TCheckBox>.Create([]);
  Ratings := TDictionary<Integer,TCheckListBox>.Create;
  try
    for Tag in TArray<Integer>.Create(COL_COLLECTION,COL_GENRE,COL_TYPE,COL_LANG,COL_SERIES,COL_PUBLISHER_SERIES,COL_PUBLISHER) do
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
    Dialog.BorderStyle := bsSizeable;
    Dialog.Constraints.MinWidth := 540; Dialog.Constraints.MinHeight := 220;
    FieldLeft := 175;
    if OnlyTag >= 0 then
    begin
      Dialog.Constraints.MinWidth := 396; Dialog.Constraints.MinHeight := 180;
      Dialog.ClientWidth := 420; FieldLeft := 12;
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
          RatingList.Checked[RatingIndex] := (Current <> '') and (Pos(';'+IntToStr(RatingIndex)+';',Current+';') > 0);
        Ratings.Add(Tag,RatingList);
        LabelControl:=TLabel.Create(Dialog); LabelControl.Parent:=Scroll;
        LabelControl.SetBounds(FieldLeft,Y+136,240,18); LabelControl.Caption:='Без выбора — все оценки';
        Inc(Y,128);
      end
      else if Tag in [COL_SIZE, COL_NO, COL_PUBYEAR] then
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
      if Tag in [COL_AUTHOR,COL_TITLE,COL_SERIES,COL_PUBLISHER_SERIES,COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_ISBN,COL_GENRE,COL_TYPE,COL_COLLECTION,COL_LANG,COL_LIBID] then
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
        Application.MessageBox('Введите число (для года — целое положительное). Для диапазона начальное значение должно быть не больше конечного.',
          'Числовой фильтр', MB_OK); Continue;
      end;
      for Tag in NumericValues.Keys do Filters.SetValue(Tag, NumericValues[Tag]);
      for Tag in Ratings.Keys do
      begin
        RatingList := Ratings[Tag]; Current := 'set'; RatingIndex := 0;
        for I := 0 to 5 do if RatingList.Checked[I] then begin Current := Current+';'+IntToStr(I); Inc(RatingIndex); end;
        if (RatingIndex = 0) or (RatingIndex = 6) then Current := '';
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
    FBuilding, FLastSensitive: Boolean;
    FSearch: TEdit;
    FList: TVirtualStringTree;
    FCase, FFavoriteAuthors: TCheckBox;
    FCount, FLegend: TLabel;
    FSearchPanel, FFooter: TPanel;
    FSelectFound, FClear, FReset, FApply, FCancel: TButton;
    FLayoutLocked: Boolean;
    FLayoutPPI: Integer;
    procedure LayoutControls(TargetPPI: Integer = 0);
    procedure UpdateCount;
    function Key(Index: Integer): string;
    function Chosen(Index: Integer): Boolean;
    procedure SearchChanged(Sender: TObject);
    procedure InitItem(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
      var InitialStates: TVirtualNodeInitStates);
    procedure ItemText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure ItemChecked(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure SelectFound(Sender: TObject);
  protected
    procedure Resize; override;
    procedure ChangeScale(M, D: Integer; IsDpiChange: Boolean); override;
  public
    constructor CreateList(Tree: TBookTree; Filters: TBookColumnFilters; Tag: Integer);
    procedure ScaleForPPI(NewPPI: Integer); override;
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
end;

constructor TListFilterEditor.CreateList(Tree: TBookTree; Filters: TBookColumnFilters; Tag: Integer);
var SearchPanel, Footer: TPanel; Button: TButton; Legend: TLabel; I: Integer; Selected: TStringList;
  P: TPoint; Area: TRect;
begin
  inherited CreateNew(nil);
  FNames := TStringList.Create; FFolded := TStringList.Create;
  FFound := TList<Integer>.Create; FChecked := TDictionary<string,Byte>.Create;
  Caption := 'Фильтр';
  for I := Low(ColumnTags) to High(ColumnTags) do
    if ColumnTags[I] = Tag then Caption := 'Фильтр: '+ColumnNames[I];
  BorderStyle := bsSizeable; Position := poDesigned;
  ClientWidth := 420; ClientHeight := 440;
  Constraints.MinWidth := 396; Constraints.MinHeight := 320;
  Font.Name := 'Segoe UI'; Font.Size := 9; DoubleBuffered := True;
  SearchPanel := TPanel.Create(Self); SearchPanel.Parent := Self; SearchPanel.Align := alTop;
  FSearchPanel := SearchPanel; FSearchPanel.Name := 'FilterSearchPanel';
  SearchPanel.Height := 130; SearchPanel.BevelOuter := bvNone;
  FSearch := TEdit.Create(Self); FSearch.Parent := SearchPanel; FSearch.SetBounds(12,10,ClientWidth-24,25);
  FSearch.Anchors := [akLeft,akTop,akRight];
  FSearch.TextHint := 'Поиск по вариантам…'; FSearch.OnChange := SearchChanged;
  FCase := TCheckBox.Create(Self); FCase.Parent := SearchPanel; FCase.SetBounds(12,41,220,22);
  FCase.Caption := 'Учитывать регистр'; FCase.Checked := Filters.CaseSensitive(Tag);
  FLastSensitive := FCase.Checked; FCase.OnClick := SearchChanged;
  if Tag = COL_AUTHOR then
  begin
    FFavoriteAuthors := TCheckBox.Create(Self);
    FFavoriteAuthors.Parent := SearchPanel;
    FFavoriteAuthors.Name := 'FavoriteAuthorsOnlyCheck';
    FFavoriteAuthors.Caption := 'Только любимые авторы';
    FFavoriteAuthors.Checked := Filters.FavoriteAuthorsOnly;
    FFavoriteAuthors.ShowHint := True;
    FFavoriteAuthors.Hint := 'Условие действует вместе с другими фильтрами после «Применить».';
  end;
  Button := TButton.Create(Self); Button.Parent := SearchPanel; Button.SetBounds(12,69,163,25);
  Button.Caption := 'Выбрать найденные'; Button.Tag := 1; Button.OnClick := SelectFound;
  FSelectFound := Button; Button.Name := 'SelectFoundButton';
  Button := TButton.Create(Self); Button.Parent := SearchPanel; Button.SetBounds(185,69,163,25);
  Button.Caption := 'Снять всё'; Button.OnClick := SelectFound;
  FClear := Button; Button.Name := 'ClearSelectionButton';
  Legend := TLabel.Create(Self); Legend.Parent := SearchPanel; Legend.AutoSize := False;
  FLegend := Legend; Legend.Name := 'FilterSelectionLegend'; Legend.WordWrap := True;
  Legend.SetBounds(12,102,ClientWidth-24,22); Legend.Anchors := [akLeft,akTop,akRight];
  Legend.Caption := 'Без выбора — все варианты. Список по загруженным книгам.';
  Footer := TPanel.Create(Self); Footer.Parent := Self; Footer.Align := alBottom;
  FFooter := Footer; Footer.Name := 'FilterFooter';
  Footer.Height := 63; Footer.BevelOuter := bvNone;
  FCount := TLabel.Create(Self); FCount.Parent := Footer; FCount.AutoSize := False;
  FCount.Name := 'FilterOptionCount'; FCount.WordWrap := True;
  FCount.SetBounds(12,2,ClientWidth-24,18); FCount.Anchors := [akLeft,akTop,akRight];
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(12,26,100,28);
  Button.Caption := 'Сбросить'; Button.ModalResult := mrYes;
  FReset := Button; Button.Name := 'ResetFilterButton';
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(ClientWidth-236,26,112,28); Button.Anchors := [akRight,akTop];
  Button.Caption := 'Применить'; Button.ModalResult := mrOk; Button.Default := True;
  FApply := Button; Button.Name := 'ApplyFilterButton';
  Button := TButton.Create(Self); Button.Parent := Footer; Button.SetBounds(ClientWidth-112,26,100,28); Button.Anchors := [akRight,akTop];
  Button.Caption := 'Отмена'; Button.ModalResult := mrCancel; Button.Cancel := True;
  FCancel := Button; Button.Name := 'CancelFilterButton';
  FList := TVirtualStringTree.Create(Self); FList.Parent := Self; FList.Align := alClient;
  FList.Name := 'FilterOptionList';
  FList.NodeDataSize := 0; FList.Header.Options := [];
  FList.TreeOptions.MiscOptions := [toCheckSupport];
  FList.TreeOptions.PaintOptions := [toThemeAware];
  FList.TreeOptions.SelectionOptions := [toFullRowSelect];
  FList.OnInitNode := InitItem; FList.OnGetText := ItemText; FList.OnChecked := ItemChecked;
  Filters.GetOptions(Tag,FNames);
  Selected := TStringList.Create;
  try
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
  ApplyMHLControlTheme(Self);
  LayoutControls;
  GetCursorPos(P); Area := Screen.MonitorFromPoint(P).WorkareaRect;
  Left := EnsureRange(P.X-Width div 2,Area.Left,Max(Area.Left,Area.Right-Width));
  Top := EnsureRange(P.Y+12,Area.Top,Max(Area.Top,Area.Bottom-Height));
end;

procedure TListFilterEditor.LayoutControls(TargetPPI: Integer);
var
  Margin, Gap, TextPadding, SmallGap, RowHeight, SelectWidth, ClearWidth,
    ResetWidth, ApplyWidth, CancelWidth, MinimumClientWidth, Available,
    SearchHeight, CaseHeight, LegendHeight, CountHeight, Y, FrameWidth,
    FrameHeight, MinimumClientHeight, LayoutPPI: Integer;

  function Pixels(Value: Integer): Integer;
  begin Result := MulDiv(Value, LayoutPPI, 96); end;

  function CaptionWidth(Button: TButton; Minimum: Integer): Integer;
  begin
    Canvas.Font.Assign(Button.Font);
    Result := Max(Pixels(Minimum), Canvas.TextWidth(Button.Caption) + TextPadding);
  end;

  function TextHeight(Control: TControl): Integer;
  begin
    if Control is TButton then Canvas.Font.Assign(TButton(Control).Font)
    else if Control is TLabel then Canvas.Font.Assign(TLabel(Control).Font)
    else if Control is TCheckBox then Canvas.Font.Assign(TCheckBox(Control).Font)
    else Canvas.Font.Assign(FSearch.Font);
    Result := Canvas.TextHeight('ЙдAg');
  end;

  function LabelHeight(LabelControl: TLabel; Width, Minimum: Integer): Integer;
  var Bounds: TRect;
  begin
    Canvas.Font.Assign(LabelControl.Font);
    Bounds := Rect(0, 0, Max(1, Width), 0);
    DrawText(Canvas.Handle, PChar(LabelControl.Caption), Length(LabelControl.Caption),
      Bounds, DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Result := Max(Pixels(Minimum), Bounds.Height + Pixels(2));
  end;

begin
  if FLayoutLocked or not Assigned(FSelectFound) or not Assigned(FClear) or
    not Assigned(FReset) or not Assigned(FApply) or not Assigned(FCancel) then Exit;
  FLayoutLocked := True;
  try
    if TargetPPI > 0 then FLayoutPPI := TargetPPI;
    LayoutPPI := FLayoutPPI;
    if LayoutPPI <= 0 then LayoutPPI := CurrentPPI;
    Margin := Pixels(12); Gap := Pixels(10); SmallGap := Pixels(6);
    TextPadding := Pixels(24);
    SelectWidth := CaptionWidth(FSelectFound, 190);
    ClearWidth := CaptionWidth(FClear, 110);
    ResetWidth := CaptionWidth(FReset, 100);
    ApplyWidth := CaptionWidth(FApply, 112);
    CancelWidth := CaptionWidth(FCancel, 100);
    MinimumClientWidth := Max(Pixels(380), Max(
      SelectWidth + ClearWidth + Gap + 2 * Margin,
      ResetWidth + ApplyWidth + CancelWidth + 2 * Gap + 2 * Margin));
    Canvas.Font.Assign(FCase.Font);
    MinimumClientWidth := Max(MinimumClientWidth,
      Canvas.TextWidth(FCase.Caption) + Pixels(24) + 2 * Margin);
    FrameWidth := Width - ClientWidth;
    Constraints.MinWidth := MinimumClientWidth + FrameWidth;
    if ClientWidth < MinimumClientWidth then ClientWidth := MinimumClientWidth;
    Available := ClientWidth - 2 * Margin;

    SearchHeight := Max(Pixels(25), TextHeight(FSearch) + Pixels(8));
    FSearch.SetBounds(Margin, Pixels(10), Available, SearchHeight);
    Y := FSearch.Top + FSearch.Height + SmallGap;
    CaseHeight := Max(Pixels(22), TextHeight(FCase) + Pixels(4));
    FCase.SetBounds(Margin, Y, Available, CaseHeight);
    Inc(Y, CaseHeight + SmallGap);
    if Assigned(FFavoriteAuthors) then
    begin
      CaseHeight := Max(Pixels(22), TextHeight(FFavoriteAuthors) + Pixels(4));
      FFavoriteAuthors.SetBounds(Margin, Y, Available, CaseHeight);
      Inc(Y, CaseHeight + SmallGap);
    end;
    RowHeight := Max(Pixels(28), Max(TextHeight(FSelectFound), TextHeight(FClear)) + Pixels(12));
    // Give spare space to the longer action rather than leaving an empty gap
    // or stretching the short Clear caption equally with Select found.
    SelectWidth := Max(SelectWidth, Available - Gap - ClearWidth);
    FSelectFound.SetBounds(Margin, Y, SelectWidth, RowHeight);
    FClear.SetBounds(Margin + SelectWidth + Gap, Y, ClearWidth, RowHeight);
    Inc(Y, RowHeight + Gap);
    LegendHeight := LabelHeight(FLegend, Available, 22);
    FLegend.SetBounds(Margin, Y, Available, LegendHeight);
    FSearchPanel.Height := Y + LegendHeight + SmallGap;

    CountHeight := LabelHeight(FCount, Available, 18);
    FCount.SetBounds(Margin, Pixels(2), Available, CountHeight);
    Y := FCount.Top + CountHeight + SmallGap;
    RowHeight := Max(Pixels(28), Max(TextHeight(FReset),
      Max(TextHeight(FApply), TextHeight(FCancel))) + Pixels(12));
    FReset.SetBounds(Margin, Y, ResetWidth, RowHeight);
    FCancel.SetBounds(ClientWidth - Margin - CancelWidth, Y, CancelWidth, RowHeight);
    FApply.SetBounds(FCancel.Left - Gap - ApplyWidth, Y, ApplyWidth, RowHeight);
    FFooter.Height := Y + RowHeight + Pixels(8);
    FrameHeight := Height - ClientHeight;
    MinimumClientHeight := FSearchPanel.Height + FFooter.Height + Pixels(100);
    Constraints.MinHeight := Max(Pixels(320), MinimumClientHeight + FrameHeight);
    if ClientHeight < MinimumClientHeight then ClientHeight := MinimumClientHeight;
  finally FLayoutLocked := False; end;
end;

procedure TListFilterEditor.Resize;
begin
  inherited;
  LayoutControls;
end;

procedure TListFilterEditor.ChangeScale(M, D: Integer; IsDpiChange: Boolean);
var WasLocked: Boolean;
begin
  WasLocked := FLayoutLocked; FLayoutLocked := True;
  try
    inherited ChangeScale(M, D, IsDpiChange);
    if IsDpiChange then FLayoutPPI := M;
  finally FLayoutLocked := WasLocked; end;
  // Keep the applied DPI: CurrentPPI may continue to report the monitor
  // DPI after an explicit ScaleForPPI, including subsequent Resize events.
  if not WasLocked then
    if IsDpiChange then LayoutControls(M) else LayoutControls;
end;

procedure TListFilterEditor.ScaleForPPI(NewPPI: Integer);
var WasLocked: Boolean;
begin
  // Finish VCL anchor/font scaling before measuring and remember its target.
  WasLocked := FLayoutLocked; FLayoutLocked := True;
  try
    inherited ScaleForPPI(NewPPI); FLayoutPPI := NewPPI;
  finally FLayoutLocked := WasLocked; end;
  if not WasLocked then LayoutControls(NewPPI);
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
      FChecked.Clear; FLastSensitive := FCase.Checked;
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
    UpdateCount;
  finally FList.EndUpdate; Seen.Free; FBuilding := False; end;
end;

procedure TListFilterEditor.UpdateCount;
var Seen: TDictionary<string,Byte>; I: Integer;
begin
  Seen := TDictionary<string,Byte>.Create;
  try
    for I := 0 to FNames.Count-1 do Seen.TryAdd(Key(I),0);
    FCount.Caption := 'Вариантов: '+IntToStr(FFound.Count)+' из '+IntToStr(Seen.Count)+
      ' · выбрано: '+IntToStr(FChecked.Count);
  finally Seen.Free; end;
  LayoutControls;
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
begin
  CellText := FNames[FFound[Integer(Node.Index)]];
  if CellText = '' then CellText := '(не указано)';
end;

procedure TListFilterEditor.ItemChecked(Sender: TBaseVirtualTree; Node: PVirtualNode);
var Checked: Boolean; K: string;
begin
  if FBuilding then Exit;
  Checked := Node.CheckState in [csCheckedNormal,csCheckedPressed];
  K := Key(FFound[Integer(Node.Index)]);
  if Checked then FChecked.TryAdd(K,0) else FChecked.Remove(K);
  UpdateCount;
end;

procedure TListFilterEditor.SelectFound(Sender: TObject);
var I: Integer;
begin
  if TButton(Sender).Tag = 0 then FChecked.Clear
  else for I in FFound do FChecked.TryAdd(Key(I),0);
  SearchChanged(nil);
end;

function TListFilterEditor.SelectedValue: string;
var Values: TJSONArray; I, Count: Integer;
begin
  Values := TJSONArray.Create; Count := 0;
  try
    for I := 0 to FNames.Count-1 do if Chosen(I) then begin Values.Add(FNames[I]); Inc(Count); end;
    if Count = 0 then Result := '' else Result := 'values:'+Values.ToJSON;
  finally Values.Free; end;
end;

function EditListFilter(Tree: TBookTree; Tag: Integer; OverrideFilters: TBookColumnFilters = nil): Boolean;
var Dialog: TListFilterEditor; Filters: TBookColumnFilters; Answer: Integer;
begin
  Filters := OverrideFilters;
  if not Assigned(Filters) then Filters := TBookColumnFilters.ForTree(Tree);
  Dialog := TListFilterEditor.CreateList(Tree,Filters,Tag);
  try
    Answer := Dialog.ShowModal; Result := Answer in [mrOk,mrYes];
    if Answer = mrYes then
    begin
      Filters.SetValue(Tag,'');
      if Tag = COL_AUTHOR then Filters.FavoriteAuthorsOnly := False;
    end
    else if Answer = mrOk then
    begin
      Filters.SetCaseSensitive(Tag,Dialog.FCase.Checked);
      Filters.SetValue(Tag,Dialog.SelectedValue);
      if Assigned(Dialog.FFavoriteAuthors) then
        Filters.FavoriteAuthorsOnly := Dialog.FFavoriteAuthors.Checked;
    end;
  finally Dialog.Free; end;
end;

function EditColumnWithFilters(Tree: TBookTree; Tag: Integer; Filters: TBookColumnFilters): Boolean;
begin
  if Tag in [COL_AUTHOR,COL_SERIES,COL_PUBLISHER_SERIES,COL_PUBLISHER,COL_TRANSLATORS,COL_CITY,COL_GENRE,COL_TYPE,COL_COLLECTION,COL_LANG] then
    Result := EditListFilter(Tree,Tag,Filters)
  else Result := EditFilters(Tree,Tag,Filters);
end;

type
  TAllFiltersEditor = class(TForm)
  private
    FTree: TBookTree;
    FFilters: TBookColumnFilters;
    FFavoriteAuthors: TCheckBox;
    procedure EditColumn(Sender: TObject);
  end;

procedure TAllFiltersEditor.EditColumn(Sender: TObject);
var Button: TButton; Filters: TBookColumnFilters; I: Integer;
begin
  Button := TButton(Sender); Filters := FFilters;
  Filters.FavoriteAuthorsOnly := FFavoriteAuthors.Checked;
  if not EditColumnWithFilters(FTree,Button.Tag,Filters) then Exit;
  FFavoriteAuthors.Checked := Filters.FavoriteAuthorsOnly;
  for I := Low(ColumnTags) to High(ColumnTags) do if ColumnTags[I] = Button.Tag then
  begin
    Button.Caption := ColumnNames[I];
    if Filters.Value(Button.Tag) <> '' then Button.Caption := Button.Caption+' • фильтр задан';
    Break;
  end;
end;

function EditBookColumnFilters(Tree: TBookTree): Boolean;
var Dialog: TAllFiltersEditor; Scroll: TScrollBox; Footer: TPanel; Button: TButton;
  Filters, Draft: TBookColumnFilters; I, Y: Integer;
  Favorites: TCheckBox;
begin
  Filters := TBookColumnFilters.ForTree(Tree);
  // Original is created first: background publications/ForTree always see
  // committed conditions. Nested modal editors receive the separate draft.
  Draft := TBookColumnFilters.CreateFor(Tree); Dialog := nil; Result := False;
  try
    Draft.CopyConfiguration(Filters); Dialog := TAllFiltersEditor.CreateNew(nil);
    Dialog.FTree := Tree; Dialog.FFilters := Draft; Dialog.Caption := 'Фильтры столбцов'; Dialog.Position := poMainFormCenter;
    Dialog.BorderStyle := bsSizeable;
    Dialog.ClientWidth := 420; Dialog.ClientHeight := 450;
    Dialog.Constraints.MinWidth := 396; Dialog.Constraints.MinHeight := 260;
    Dialog.Font.Name := 'Segoe UI'; Dialog.Font.Size := 9;
    Footer := TPanel.Create(Dialog); Footer.Parent := Dialog; Footer.Align := alBottom;
    Footer.Height := 44; Footer.BevelOuter := bvNone;
    Button := TButton.Create(Dialog); Button.Parent := Footer; Button.SetBounds(Dialog.ClientWidth-236,6,112,28); Button.Anchors := [akRight,akTop];
    Button.Caption := 'Применить'; Button.ModalResult := mrOk; Button.Default := True;
    Button := TButton.Create(Dialog); Button.Parent := Footer; Button.SetBounds(Dialog.ClientWidth-112,6,100,28); Button.Anchors := [akRight,akTop];
    Button.Caption := 'Отмена'; Button.ModalResult := mrCancel; Button.Cancel := True;
    Scroll := TScrollBox.Create(Dialog); Scroll.Parent := Dialog; Scroll.Align := alClient; Y := 10;
    Favorites := TCheckBox.Create(Dialog); Favorites.Parent := Scroll;
    Dialog.FFavoriteAuthors := Favorites;
    Favorites.Name := 'FavoriteAuthorsOnlyCheck';
    Favorites.SetBounds(12, Y, Scroll.ClientWidth - 24, 24);
    Favorites.Anchors := [akLeft, akTop, akRight];
    Favorites.Caption := 'Только любимые авторы';
    Favorites.Checked := Draft.FavoriteAuthorsOnly;
    Inc(Y, 32);
    for I := Low(ColumnTags) to High(ColumnTags) do
    begin
      if ColumnTags[I] in [COL_LIBRATE,COL_LIBID] then Continue;
      Button := TButton.Create(Dialog); Button.Parent := Scroll; Button.SetBounds(12,Y,Scroll.ClientWidth-24,30); Button.Anchors := [akLeft,akTop,akRight];
      Button.Tag := ColumnTags[I]; Button.Caption := ColumnNames[I];
      if Draft.Value(ColumnTags[I]) <> '' then Button.Caption := Button.Caption+' • фильтр задан';
      Button.OnClick := Dialog.EditColumn; Inc(Y,36);
    end;
    Dialog.ScaleForPPI(Tree.CurrentPPI); Result := Dialog.ShowModal = mrOk;
    if Result then
    begin Draft.FavoriteAuthorsOnly := Favorites.Checked; Filters.CopyConfiguration(Draft); end;
  finally Dialog.Free; Draft.Free; end;
end;

function EditBookColumnFilter(Tree: TBookTree; Tag: Integer): Boolean;
begin
  Result := EditColumnWithFilters(Tree,Tag,nil);
end;

end.
