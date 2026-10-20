unit unit_BookViewSessions;

interface

uses System.IniFiles, BookTreeView;

type
  // Stores configuration only. Construct after the main window's first paint;
  // neither capture nor restore enumerates books or opens a collection.
  TBookViewSessions = class
  private
    FIni: TMemIniFile;
    function Section(CollectionID, ViewID: Integer): string;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    function HasSettings(CollectionID: Integer): Boolean;
    procedure Capture(CollectionID: Integer; Tree: TBookTree);
    procedure Restore(CollectionID: Integer; Tree: TBookTree);
    procedure Save;
  end;

// Column positions can change independently of stable column tags.
procedure UpdateBookViewSortHeader(Tree: TBookTree; Flat: Boolean);

implementation

uses System.SysUtils, System.Classes, System.JSON, System.Math,
  VirtualTrees, VirtualTrees.Types, unit_BookColumnFilters, unit_AtomicIniFile;

function HasColumn(Tree: TBookTree; Tag: Integer): Boolean;
begin
  for var I := 0 to Tree.Header.Columns.Count - 1 do
    if Tree.Header.Columns[I].Tag = Tag then Exit(True);
  Result := False;
end;

function HasFilter(Tree: TBookTree; Tag: Integer): Boolean;
begin
  for var Value in Tree.HeaderFilterTags do
    if Value = Tag then Exit(True);
  Result := False;
end;

procedure UpdateBookViewSortHeader(Tree: TBookTree; Flat: Boolean);
begin
  Tree.Header.SortColumn := NoColumn;
  Tree.Header.SortDirection := sdAscending;
  if not Flat or (Length(Tree.SortKeys) = 0) then Exit;
  for var I := 0 to Tree.Header.Columns.Count - 1 do
    if Tree.Header.Columns[I].Tag = Tree.SortKeys[0].Tag then
    begin
      Tree.Header.SortColumn := I;
      Tree.Header.SortDirection := Tree.SortKeys[0].Direction;
      Exit;
    end;
end;

constructor TBookViewSessions.Create(const FileName: string);
begin
  inherited Create;
  FIni := TMemIniFile.Create(FileName, TEncoding.UTF8);
  FIni.AutoSave := False;
end;

destructor TBookViewSessions.Destroy;
begin
  FIni.Free;
  inherited;
end;

function TBookViewSessions.Section(CollectionID, ViewID: Integer): string;
begin
  Result := Format('Collection.%d.View.%d', [CollectionID, ViewID]);
end;

function TBookViewSessions.HasSettings(CollectionID: Integer): Boolean;
begin
  Result := False;
  if FIni.ReadInteger('Format', 'Version', 1) <> 1 then Exit;
  for var ViewID := 0 to 6 do
    if FIni.ReadBool(Section(CollectionID, ViewID), 'Active', False) then Exit(True);
end;

procedure TBookViewSessions.Capture(CollectionID: Integer; Tree: TBookTree);
var Name: string; Filters: TBookColumnFilters; Data: TJSONObject;
  Values: TJSONArray; Item: TJSONObject; Keys: TArray<TBookSortKey>; N: Integer;
begin
  if CollectionID <= 0 then Exit;
  Name := Section(CollectionID, Tree.Tag);
  FIni.EraseSection(Name);
  FIni.WriteInteger('Format', 'Version', 1);
  Keys := Tree.SortKeys; N := Min(3, Length(Keys));
  FIni.WriteInteger(Name, 'SortCount', N);
  for var I := 0 to N - 1 do
  begin
    FIni.WriteInteger(Name, 'SortTag' + IntToStr(I), Keys[I].Tag);
    FIni.WriteInteger(Name, 'SortDirection' + IntToStr(I), Ord(Keys[I].Direction));
  end;
  Filters := TBookColumnFilters.ForTree(Tree);
  Data := TJSONObject.Create;
  try
    Data.AddPair('favoriteAuthorsOnly', TJSONBool.Create(Filters.FavoriteAuthorsOnly));
    Values := TJSONArray.Create; Data.AddPair('columns', Values);
    for var Tag in Tree.HeaderFilterTags do
      if (Filters.Value(Tag) <> '') or Filters.CaseSensitive(Tag) then
      begin
        Item := TJSONObject.Create; Values.AddElement(Item);
        Item.AddPair('tag', TJSONNumber.Create(Tag));
        Item.AddPair('value', Filters.Value(Tag));
        Item.AddPair('sensitive', TJSONBool.Create(Filters.CaseSensitive(Tag)));
      end;
    FIni.WriteString(Name, 'Filters', Data.ToJSON);
    FIni.WriteBool(Name, 'Active', (N > 0) or (Filters.Count > 0));
  finally Data.Free; end;
end;

procedure TBookViewSessions.Restore(CollectionID: Integer; Tree: TBookTree);
var Name: string; Keys: TArray<TBookSortKey>; Key: TBookSortKey;
  Tag, Direction: Integer; Duplicate: Boolean;
  Parsed, Columns, Value, Field: TJSONValue; Item: TJSONObject;
  Filters: TBookColumnFilters;
begin
  Tree.SortKeys := nil;
  Filters := TBookColumnFilters.ForTree(Tree); Filters.Clear;
  if FIni.ReadInteger('Format', 'Version', 1) <> 1 then Exit;
  Name := Section(CollectionID, Tree.Tag); Keys := nil;
  for var I := 0 to EnsureRange(FIni.ReadInteger(Name, 'SortCount', 0), 0, 3) - 1 do
  begin
    Tag := FIni.ReadInteger(Name, 'SortTag' + IntToStr(I), -1);
    Direction := FIni.ReadInteger(Name, 'SortDirection' + IntToStr(I), -1);
    if not HasColumn(Tree, Tag) or not (Direction in [Ord(sdAscending), Ord(sdDescending)]) then Continue;
    Duplicate := False;
    for var Existing in Keys do if Existing.Tag = Tag then Duplicate := True;
    if Duplicate then Continue;
    Key.Tag := Tag; Key.Direction := TSortDirection(Direction); Keys := Keys + [Key];
  end;
  Tree.SortKeys := Keys;
  Parsed := TJSONObject.ParseJSONValue(FIni.ReadString(Name, 'Filters', ''));
  try
    if not (Parsed is TJSONObject) then Exit;
    Item := TJSONObject(Parsed);
    Field := Item.GetValue('favoriteAuthorsOnly');
    Filters.FavoriteAuthorsOnly := (Field is TJSONBool) and SameText(Field.Value, 'true');
    Columns := Item.GetValue('columns');
    if not (Columns is TJSONArray) then Exit;
    for Value in TJSONArray(Columns) do
    begin
      if not (Value is TJSONObject) then Continue;
      Item := TJSONObject(Value); Field := Item.GetValue('tag');
      if not (Field is TJSONNumber) or not TryStrToInt(Field.Value, Tag) then Continue;
      if not HasFilter(Tree, Tag) then Continue;
      Field := Item.GetValue('value');
      if Field is TJSONString then Filters.SetValue(Tag, Field.Value);
      Field := Item.GetValue('sensitive');
      Filters.SetCaseSensitive(Tag, (Field is TJSONBool) and SameText(Field.Value, 'true'));
    end;
  finally Parsed.Free; end;
end;

procedure TBookViewSessions.Save;
begin
  if FIni.Modified then SaveMemIniFileAtomically(FIni);
end;

end.
