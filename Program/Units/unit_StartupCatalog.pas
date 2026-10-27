unit unit_StartupCatalog;

interface

uses System.Classes, System.SysUtils, System.Generics.Collections,
  unit_Globals, unit_Interfaces;

type
  TRecordArrayIterator<T: record> = class(TInterfacedObject, IIterator<T>)
  private
    FRows: TArray<T>;
    FIndex: Integer;
  public
    constructor Create(const Rows: TArray<T>);
    class function Capture(const Source: IIterator<T>;
      const Cancel: TFunc<Boolean>): IIterator<T>; static;
    function Next(out Value: T): Boolean;
    function RecordCount: Integer;
  end;

  TStartupCatalogData = class
  public
    Collection: IBookCollection;
    Authors: IAuthorIterator;
    Series, PublisherSeries: ISeriesIterator;
    AuthorCount, BookCount, SeriesCount: Integer;
  end;

  TStartupCatalogLoader = class(TThread)
  private
    FFileName: string;
    FCollectionID: Integer;
    FHideDeleted, FLocalOnly, FLoadPublisher: Boolean;
    FLoadAuthors, FLoadSeries: Boolean;
    FData: TStartupCatalogData;
    FError: string;
    function Cancelled: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const FileName: string; CollectionID: Integer;
      HideDeleted, LocalOnly, LoadPublisher: Boolean;
      LoadAuthors: Boolean = True; LoadSeries: Boolean = True);
    destructor Destroy; override;
    function TakeData: TStartupCatalogData;
    property Error: string read FError;
  end;

  // One immutable capture can build both the initial list and its restored
  // language view. Iterators share the array but keep independent positions.
  TStartupBookRows = class
  private
    FRows: TArray<TBookRecord>;
  public
    constructor Create(const Source: IBookIterator; const Cancel: TFunc<Boolean>);
    function NewIterator: IBookIterator;
  end;

  TStartupBooksLoader = class(TThread)
  private
    FFactory: TFunc<IBookIterator>;
    FRows: TStartupBookRows;
    FError: string;
    function Cancelled: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const Factory: TFunc<IBookIterator>);
    destructor Destroy; override;
    function TakeRows: TStartupBookRows;
    property Error: string read FError;
  end;

implementation

uses System.Character, System.Variants, SQLiteWrap,
  unit_Consts, unit_SystemDatabase_SQLite;

constructor TRecordArrayIterator<T>.Create(const Rows: TArray<T>);
begin inherited Create; FRows := Rows; end;

function TRecordArrayIterator<T>.Next(out Value: T): Boolean;
begin
  Result := FIndex < Length(FRows);
  if Result then begin Value := FRows[FIndex]; Inc(FIndex); end;
end;

function TRecordArrayIterator<T>.RecordCount: Integer;
begin Result := Length(FRows); end;

class function TRecordArrayIterator<T>.Capture(const Source: IIterator<T>;
  const Cancel: TFunc<Boolean>): IIterator<T>;
var Rows: TList<T>; Value: T;
begin
  Rows := TList<T>.Create;
  try
    while Source.Next(Value) do
    begin
      if Cancel() then Abort;
      Rows.Add(Value);
    end;
    if Cancel() then Abort;
    Result := TRecordArrayIterator<T>.Create(Rows.ToArray);
  finally Rows.Free; end;
end;

constructor TStartupCatalogLoader.Create(const FileName: string; CollectionID: Integer;
  HideDeleted, LocalOnly, LoadPublisher, LoadAuthors, LoadSeries: Boolean);
begin
  inherited Create(True);
  FFileName := FileName; FCollectionID := CollectionID;
  FHideDeleted := HideDeleted; FLocalOnly := LocalOnly; FLoadPublisher := LoadPublisher;
  FLoadAuthors := LoadAuthors; FLoadSeries := LoadSeries;
end;

destructor TStartupCatalogLoader.Destroy;
begin
  Terminate;
  inherited;
  FData.Free;
end;

function TStartupCatalogLoader.Cancelled: Boolean;
begin Result := Terminated; end;

function TStartupCatalogLoader.TakeData: TStartupCatalogData;
begin Result := FData; FData := nil; end;

procedure TStartupCatalogLoader.Execute;
var SystemData: ISystemData; AuthorFilter, SeriesFilter: string;
  function LetterFilter(const Saved: string): string;
  begin
    Result := Char.ToUpper(Copy(Saved,1,1));
    if Pos(Result, LATIN_ALPHABET + CYRILLIC_ALPHABET) = 0 then
      Result := ALPHA_FILTER_ALL;
  end;
begin
  SQLiteCancelCallback := Cancelled;
  try
    try
      if Cancelled then Abort;
      SystemData := TSystemData_SQLite.Create(FFileName);
      FData := TStartupCatalogData.Create;
      if not SystemData.HasCollections then Exit;
      FCollectionID := SystemData.FindFirstExistingCollectionID(FCollectionID);
      if FCollectionID < 0 then Exit;
      FData.Collection := SystemData.GetCollection(FCollectionID);
      FData.Collection.SetHideDeleted(FHideDeleted);
      FData.Collection.SetShowLocalOnly(FLocalOnly and isOnlineCollection(FData.Collection.CollectionCode));
      FData.Collection.GetStatistics(FData.AuthorCount, FData.BookCount, FData.SeriesCount);
      AuthorFilter := VarToStr(FData.Collection.GetProperty(PROP_LAST_AUTHOR));
      if AuthorFilter = '' then
        if FData.AuthorCount > 500 then AuthorFilter := 'А' else AuthorFilter := ALPHA_FILTER_ALL;
      SeriesFilter := VarToStr(FData.Collection.GetProperty(PROP_LAST_SERIES));
      if SeriesFilter = '' then
        if FData.BookCount > 500 then SeriesFilter := 'А' else SeriesFilter := ALPHA_FILTER_ALL;
      FData.Collection.SetAuthorFilterType(LetterFilter(AuthorFilter));
      FData.Collection.SetSeriesFilterType(LetterFilter(SeriesFilter));
      if FLoadAuthors then
        FData.Authors := TRecordArrayIterator<TAuthorData>.Capture(FData.Collection.GetAuthorIterator(amFullFilter),
          function: Boolean begin Result := Cancelled; end);
      if FLoadSeries then
        FData.Series := TRecordArrayIterator<TSeriesData>.Capture(FData.Collection.GetSeriesIterator(smFullFilter),
          function: Boolean begin Result := Cancelled; end);
      if FLoadPublisher then
        FData.PublisherSeries := TRecordArrayIterator<TSeriesData>.Capture(FData.Collection.GetPublisherSeriesIterator(''),
          function: Boolean begin Result := Cancelled; end);
    except on E: Exception do FError := E.Message; end;
  finally
    SQLiteCancelCallback := nil;
    if Assigned(SystemData) then SystemData.ClearCollectionCache;
    SystemData := nil;
  end;
end;

constructor TStartupBookRows.Create(const Source: IBookIterator; const Cancel: TFunc<Boolean>);
var Rows: TList<TBookRecord>; Book: TBookRecord;
begin
  inherited Create;
  Rows := TList<TBookRecord>.Create;
  try
    while Source.Next(Book) do
    begin
      if Cancel() then Abort;
      Rows.Add(Book);
    end;
    if Cancel() then Abort;
    FRows := Rows.ToArray;
  finally Rows.Free; end;
end;

function TStartupBookRows.NewIterator: IBookIterator;
begin Result := TRecordArrayIterator<TBookRecord>.Create(FRows); end;

constructor TStartupBooksLoader.Create(const Factory: TFunc<IBookIterator>);
begin inherited Create(True); FFactory := Factory; end;

destructor TStartupBooksLoader.Destroy;
begin
  Terminate;
  inherited;
  FRows.Free;
end;

function TStartupBooksLoader.Cancelled: Boolean;
begin Result := Terminated; end;

function TStartupBooksLoader.TakeRows: TStartupBookRows;
begin Result := FRows; FRows := nil; end;

procedure TStartupBooksLoader.Execute;
begin
  SQLiteCancelCallback := Cancelled;
  try
    try
      if Cancelled then Abort;
      FRows := TStartupBookRows.Create(FFactory(),
        function: Boolean begin Result := Cancelled; end);
    except on E: Exception do FError := E.Message; end;
  finally SQLiteCancelCallback := nil; FFactory := nil; end;
end;

end.
