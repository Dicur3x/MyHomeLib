unit unit_LegacyUserDataPreview;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections, unit_UserData;

type
  TLegacyGroupMapping = class
  private
    FBookIDs: TStringList;
  public
    SourceName, TargetName: string;
    SourceLine: Integer;
    constructor Create;
    destructor Destroy; override;
    property BookIDs: TStringList read FBookIDs;
    function DisplayName: string;
  end;

  TLegacyUserDataPreview = class
  private
    FFileName, FSourceHash: string;
    FData: TUserData;
    FMappings: TObjectList<TLegacyGroupMapping>;
    FRatingCount, FProgressCount, FReviewCount, FGroupBookCount: Integer;
    procedure Parse;
    function GetReady: Boolean;
    function GetGroupCount: Integer;
    function GetMapping(Index: Integer): TLegacyGroupMapping;
    function GetMappingCount: Integer;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    procedure GetGroupNames(Names: TStrings);
    procedure SetTarget(Index: Integer; const GroupName: string);
    procedure UseHistoricalDefaults;
    procedure AppendTo(Destination: TUserData);
    function CreateUserData: TUserData;
    procedure ValidateSource;
    property Ready: Boolean read GetReady;
    property MappingCount: Integer read GetMappingCount;
    property Mappings[Index: Integer]: TLegacyGroupMapping read GetMapping;
    property RatingCount: Integer read FRatingCount;
    property ProgressCount: Integer read FProgressCount;
    property ReviewCount: Integer read FReviewCount;
    property GroupCount: Integer read GetGroupCount;
    property GroupBookCount: Integer read FGroupBookCount;
    property FileName: string read FFileName;
  end;

implementation

uses System.IOUtils, System.Hash;

type
  TLegacySection = (lsNone, lsGroups, lsRates, lsFinished, lsReviews, lsGroupedBooks);

constructor TLegacyGroupMapping.Create;
begin
  inherited;
  FBookIDs := TStringList.Create;
end;

destructor TLegacyGroupMapping.Destroy;
begin FBookIDs.Free; inherited; end;

function TLegacyGroupMapping.DisplayName: string;
begin
  if SourceName = '' then Result := 'Без названия группы (старый формат)'
  else Result := SourceName;
end;

constructor TLegacyUserDataPreview.Create(const FileName: string);
begin
  inherited Create;
  FFileName := FileName;
  FData := TUserData.Create;
  FMappings := TObjectList<TLegacyGroupMapping>.Create(True);
  FSourceHash := THashSHA2.GetHashStringFromFile(FileName);
  Parse;
  ValidateSource;
end;

destructor TLegacyUserDataPreview.Destroy;
begin FMappings.Free; FData.Free; inherited; end;

procedure TLegacyUserDataPreview.ValidateSource;
begin
  if THashSHA2.GetHashStringFromFile(FFileName) <> FSourceHash then
    raise EConvertError.Create('Файл пользовательских данных изменился. Откройте предпросмотр заново.');
end;

procedure TLegacyUserDataPreview.Parse;
var
  Lines: TStringList;
  Groups: TDictionary<string, TBookGroup>;
  Pending: TDictionary<string, TLegacyGroupMapping>;
  Section: TLegacySection;
  I, P, Number: Integer;
  Line, Header, ID, Value: string;
  Group: TBookGroup;
  Mapping: TLegacyGroupMapping;
  procedure InvalidLine(const Reason: string);
  begin
    raise EConvertError.CreateFmt('Ошибка импорта пользовательских данных, строка %d: %s',
      [I + 1, Reason]);
  end;
begin
  Lines := TStringList.Create;
  Groups := TDictionary<string, TBookGroup>.Create;
  Pending := TDictionary<string, TLegacyGroupMapping>.Create;
  try
    Lines.LoadFromFile(FFileName);
    Section := lsNone;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I]; Header := Trim(Line);
      if Header = '' then Continue;
      if Header[1] = '#' then
      begin
        Section := lsNone;
        if Header = '# Группы' then Section := lsGroups
        else if Header = '# Рейтинги' then Section := lsRates
        else if Header = '# Прочитанное' then Section := lsFinished
        else if Header = '# Рецензии' then Section := lsReviews
        else if Header = '# Избранное' then Section := lsGroupedBooks;
        Continue;
      end;
      if Section = lsNone then Continue;
      if Section = lsGroups then
      begin
        if Groups.ContainsKey(Line) then InvalidLine('название группы повторяется: ' + Line);
        Group := FData.Groups.AddGroup(FData.Groups.Count + 1, Line);
        Groups.Add(Line, Group); Continue;
      end;
      P := Pos(' ', Line);
      if P = 0 then
      begin
        if Section <> lsGroupedBooks then InvalidLine('ожидаются ID книги и значение через пробел');
        ID := Line; Value := '';
      end
      else begin ID := Copy(Line, 1, P - 1); Value := Copy(Line, P + 1, MaxInt); end;
      if ID = '' then InvalidLine('не указан ID книги');
      case Section of
        lsRates, lsFinished:
          begin
            if not TryStrToInt(Value, Number) then InvalidLine('неверное числовое значение');
            if Section = lsRates then
            begin FData.Extras.AddExtra(0, ID, Number, 0, ''); if Number <> 0 then Inc(FRatingCount); end
            else
            begin FData.Extras.AddExtra(0, ID, 0, Number, ''); if Number <> 0 then Inc(FProgressCount); end;
          end;
        lsReviews:
          begin FData.Extras.AddExtra(0, ID, 0, 0, Value); if Value <> '' then Inc(FReviewCount); end;
        lsGroupedBooks:
          begin
            Inc(FGroupBookCount);
            if (P <> 0) and Groups.TryGetValue(Value, Group) then Group.AddBook(0, ID)
            else
            begin
              if not Pending.TryGetValue(Value, Mapping) then
              begin
                Mapping := TLegacyGroupMapping.Create;
                Mapping.SourceName := Value; Mapping.SourceLine := I + 1;
                FMappings.Add(Mapping); Pending.Add(Value, Mapping);
              end;
              Mapping.BookIDs.Add(ID);
            end;
          end;
      end;
    end;
  finally Pending.Free; Groups.Free; Lines.Free; end;
end;

function TLegacyUserDataPreview.GetReady: Boolean;
begin
  for var Mapping in FMappings do if Trim(Mapping.TargetName) = '' then Exit(False);
  Result := True;
end;

function TLegacyUserDataPreview.GetGroupCount: Integer;
begin Result := FData.Groups.Count; end;

function TLegacyUserDataPreview.GetMappingCount: Integer;
begin Result := FMappings.Count; end;

function TLegacyUserDataPreview.GetMapping(Index: Integer): TLegacyGroupMapping;
begin Result := FMappings[Index]; end;

procedure TLegacyUserDataPreview.GetGroupNames(Names: TStrings);
begin
  Names.Clear;
  for var Group in FData.Groups do Names.Add(Group.GroupName);
end;

procedure TLegacyUserDataPreview.SetTarget(Index: Integer; const GroupName: string);
begin FMappings[Index].TargetName := Trim(GroupName); end;

procedure TLegacyUserDataPreview.UseHistoricalDefaults;
begin
  for var Mapping in FMappings do
    if Mapping.SourceName <> '' then
      raise EConvertError.CreateFmt('Ошибка импорта пользовательских данных, строка %d: неизвестная группа: %s',
        [Mapping.SourceLine, Mapping.SourceName])
    else if FData.Groups.Count <= 1 then
      raise EConvertError.CreateFmt('Ошибка импорта пользовательских данных, строка %d: для книги без названия группы отсутствует вторая группа',
        [Mapping.SourceLine])
    else Mapping.TargetName := FData.Groups[1].GroupName;
end;

function TLegacyUserDataPreview.CreateUserData: TUserData;
var
  Groups: TDictionary<string, TBookGroup>;
  Target: TBookGroup;
begin
  if not Ready then raise EConvertError.Create('Выберите соответствие для каждой неоднозначной группы.');
  ValidateSource;
  Result := TUserData.Create;
  Groups := TDictionary<string, TBookGroup>.Create;
  try
    try
      for var Extra in FData.Extras do
        Result.Extras.AddExtra(Extra.BookID, Extra.LibID, Extra.Rating, Extra.Progress, Extra.Review);
      for var Group in FData.Groups do
      begin
        Target := Result.Groups.AddGroup(Group.GroupID, Group.GroupName);
        Groups.Add(Group.GroupName, Target);
        for var Book in Group do Target.AddBook(Book.BookID, Book.LibID);
      end;
      for var Mapping in FMappings do
      begin
        if not Groups.TryGetValue(Mapping.TargetName, Target) then
        begin
          Target := Result.Groups.AddGroup(Result.Groups.Count + 1, Mapping.TargetName);
          Groups.Add(Mapping.TargetName, Target);
        end;
        for var ID in Mapping.BookIDs do Target.AddBook(0, ID);
      end;
    except Result.Free; raise; end;
  finally Groups.Free; end;
end;

procedure TLegacyUserDataPreview.AppendTo(Destination: TUserData);
var Parsed: TUserData;
begin
  Parsed := CreateUserData;
  try
    // Allocate both destination lists before publishing either one.
    Destination.Extras.Capacity := Destination.Extras.Count + Parsed.Extras.Count;
    Destination.Groups.Capacity := Destination.Groups.Count + Parsed.Groups.Count;
    Destination.Extras.AddRange(Parsed.Extras); Parsed.Extras.OwnsObjects := False;
    Destination.Groups.AddRange(Parsed.Groups); Parsed.Groups.OwnsObjects := False;
  finally Parsed.Free; end;
end;

end.
