type
  TStartupSlowBooks = class(TInterfacedObject, IBookIterator)
  private
    FEntered: TEvent;
    FCount: Integer;
  public
    constructor Create(Entered: TEvent);
    function Next(out Book: TBookRecord): Boolean;
    function RecordCount: Integer;
  end;

constructor TStartupSlowBooks.Create(Entered: TEvent);
begin inherited Create; FEntered := Entered; end;

function TStartupSlowBooks.Next(out Book: TBookRecord): Boolean;
begin
  FEntered.SetEvent;
  Sleep(10);
  Inc(FCount);
  Book := Default(TBookRecord);
  Book.Title := 'Книга ё ' + IntToStr(FCount);
  Result := FCount <= 1000;
end;

function TStartupSlowBooks.RecordCount: Integer;
begin Result := 1000; end;

procedure TestStartupWorkerLifecycle;
var Catalog: TStartupCatalogLoader; Books: TStartupBooksLoader;
  Entered: TEvent; Called: Boolean; Started: UInt64; FileName: string;
  Locked: TSQLiteDatabase;
begin
  FileName := TPath.Combine(Settings.AppPath, 'never-open-startup.dbs2');
  Catalog := TStartupCatalogLoader.Create(FileName, 1, True, False, False);
  Catalog.Free;
  Require(not FileExists(FileName), 'Freeing an unstarted loader opened a database');
  Called := False;
  Books := TStartupBooksLoader.Create(function: IBookIterator
    begin Called := True; Result := nil; end);
  Books.Free;
  Require(not Called, 'Freeing an unstarted loader executed its factory');

  Entered := TEvent.Create(nil, True, False, '');
  try
    Books := TStartupBooksLoader.Create(function: IBookIterator
      begin Result := TStartupSlowBooks.Create(Entered); end);
    Books.Start;
    Require(Entered.WaitFor(2000) = wrSignaled, 'Startup reader did not start');
    Started := GetTickCount64;
    Books.Terminate;
    Books.Free;
    Require(GetTickCount64 - Started < 2000, 'Cancelling startup waited for the entire result');
  finally Entered.Free; end;

  FileName := TPath.Combine(Settings.AppPath, 'locked-startup.hlc2');
  Locked := TSQLiteDatabase.Create(FileName);
  Entered := TEvent.Create(nil, True, False, '');
  try
    Locked.ExecSQL('CREATE TABLE Pending(ID INTEGER)');
    Locked.Start;
    Locked.ExecSQL('INSERT INTO Pending VALUES(1)');
    Books := TStartupBooksLoader.Create(function: IBookIterator
      var DB: TSQLiteDatabase;
      begin
        DB := TSQLiteDatabase.Create(FileName);
        try
          Entered.SetEvent;
          DB.ExecSQL('INSERT INTO Pending VALUES(2)');
        finally DB.Free; end;
        Result := nil;
      end);
    Books.Start;
    Require(Entered.WaitFor(2000) = wrSignaled, 'Locked startup did not reach its query');
    Sleep(50);
    Started := GetTickCount64;
    Books.Terminate;
    Books.Free;
    Require(GetTickCount64 - Started < 2000, 'Closing startup waited for SQLite busy timeout');
    Locked.Rollback;
    Require(Locked.QuerySingleInt('SELECT COUNT(*) FROM Pending') = 0,
      'Cancelled startup lock fixture wrote data');
  finally Entered.Free; Locked.Free; end;

  FileName := TPath.Combine(Settings.AppPath, 'invalid-startup.dbs2');
  TFile.WriteAllText(FileName, 'invalid SQLite fixture', TEncoding.UTF8);
  Catalog := TStartupCatalogLoader.Create(FileName, 1, True, False, False);
  try
    Catalog.Start;
    Started := GetTickCount64;
    while not Catalog.Finished and (GetTickCount64 - Started < 5000) do Sleep(1);
    Require(Catalog.Finished, 'Invalid startup database did not finish');
    Require(Catalog.Error <> '', 'Startup reader lost its database error');
  finally Catalog.Free; end;
  Writeln('PASS deferred startup workers cancel, preserve errors and free before Start');
end;

procedure CompleteDeferredStartup;
var Started: UInt64; Key: TWMKey; Handled: Boolean;
begin
  Require(frmMain.StartupLoading and (frmMain.tvBooksA.TotalCount = 0),
    'Main construction eagerly loaded the catalogue');
  Require(frmMain.Visible and frmMain.HandleAllocated,
    'Main must be visible before catalogue loading');
  frmMain.Update;
  // Real Application.Run performs idle action updates. ProcessMessages alone
  // would miss an action dereferencing the not-yet-open collection.
  for var I := 0 to frmMain.Actions.ActionCount - 1 do
    frmMain.Actions.Actions[I].Update;
  frmMain.StartInitialCollectionLoad;
  Key := Default(TWMKey); Key.CharCode := Ord('F'); Handled := False;
  frmMain.FormShortCut(Key, Handled);
  Require(Handled, 'A shortcut can change the collection during background startup');
  Started := GetTickCount64;
  while frmMain.StartupLoading and (GetTickCount64 - Started < 15000) do
  begin Application.HandleMessage; end;
  Require(not frmMain.StartupLoading, 'Deferred catalogue loading did not complete');
  Require(frmMain.pgControl.Enabled and frmMain.tlbrMain.Enabled,
    'Startup did not restore the main controls');
  Require(not frmMain.ShowStatusProgress, 'Startup left its progress visible');
  Writeln('PASS actual Main appears before catalogue and restores controls after background load');
end;

procedure TestDeferredStartupEarlyClose;
var Started: UInt64;
begin
  Require(frmMain.StartupLoading and (frmMain.tvBooksA.TotalCount = 0),
    'Early-close main eagerly loaded the catalogue');
  frmMain.StartInitialCollectionLoad;
  // The catalogue thread starts at the first timer event.
  Started := GetTickCount64;
  while GetTickCount64 - Started < 25 do begin Application.ProcessMessages; Sleep(1); end;
  Started := GetTickCount64;
  FreeAndNil(frmMain);
  Require(GetTickCount64 - Started < 2000, 'Closing during startup stalled');
  Writeln('PASS actual Main closes during background startup without callbacks into freed controls');
end;

procedure TestPreferredSourceRows;
var Collection: IBookCollection; CID, ID: Integer; Key: TBookKey;
  Criteria: TBookSearchCriteria; Filter: TFilterValue;
  procedure CheckRows(const Expected: string);
  var Iterator: IBookIterator; Book: TBookRecord; Count: Integer;
    procedure Check(const Rows: IBookIterator; ExpectedCount: Integer);
    begin
      Count := 0;
      while Rows.Next(Book) do
      begin
        Require(Book.CollectionName = Expected, 'Preferred source was lost in an iterator');
        if ExpectedCount = 2 then
        begin
          Require((Book.SeriesID > 0) and MatchText(Book.Series, ['Первая серия', 'Вторая серия']),
            'Expanded search lost series fields beside the preferred source');
          if Book.Series = 'Вторая серия' then Require(Book.SeqNumber = 2, 'Expanded search lost series position');
        end;
        Inc(Count);
      end;
      Require(Count = ExpectedCount, 'Preferred-source join changed the row count');
    end;
  begin
    Collection.GetBookRecord(Key, Book, False);
    Require(Book.CollectionName = Expected, 'Preferred source was lost in the book card');
    Iterator := Collection.GetBookIterator(bmAll, False); Check(Iterator, 1); Iterator := nil;
    Iterator := Collection.GetBookIterator(bmByGenre, False, @Filter); Check(Iterator, 1); Iterator := nil;
    Criteria.CollapseMultiSeriesResults := True;
    Iterator := Collection.Search(Criteria, False); Check(Iterator, 1); Iterator := nil;
    Criteria.CollapseMultiSeriesResults := False;
    Iterator := Collection.Search(Criteria, False); Check(Iterator, 2); Iterator := nil;
  end;
begin
  CID := SystemDB.CreateCollection('Source rows', Settings.AppPath, 'source-rows.hlc2',
    CT_EXTERNAL_LOCAL_FB, Settings.AppPath + 'genres_fb2.glst');
  Collection := SystemDB.GetCollection(CID);
  ID := AddBook(Collection, 'Source row', 'Автор ё', 'ru', 'Первая серия', '0.1');
  Key := CreateBookKey(ID, CID);
  Collection.AddBookSeries(ID, 'Вторая серия', 2);
  Criteria := Default(TBookSearchCriteria); Criteria.DateIdx := -1;
  Criteria.Title := 'Source row'; Filter.ValueString := '0.1';
  CheckRows('Source rows');
  Collection.SetCatalogBookPreferredSource(Key, 'Источник ё'); CheckRows('Источник ё');
  Collection.SetCatalogBookPreferredSource(Key, ''); CheckRows('');
  Collection.BeginBulkOperation;
  Collection.SetCatalogBookPreferredSource(Key, 'Откат');
  Collection.EndBulkOperation(False);
  CheckRows('');
  Writeln('PASS preferred sources preserve empty Unicode fallback rollback and expanded search rows');
end;
