unit unit_MCP_PublisherIndexSelfTest;

interface

uses
  unit_Interfaces;

// Called only after RunMakeFixtureMode has validated its disposable paths.
procedure CheckPublisherSeriesIndexer(const Collection: IBookCollection;
  const BookIDs: TArray<Integer>);

implementation

uses
  System.Classes,
  System.SysUtils,
  System.IOUtils,
  System.Math,
  unit_Globals,
  unit_IndexPublisherSeriesThread;

type
  TIndexObserver = class
  public
    Worker: TIndexPublisherSeriesThread;
    CancelPercent: Integer;
    CancelIssued: Boolean;
    LastPercent: Integer;
    CompletedAfterCancel: Boolean;
    WarningCount: Integer;
    procedure OnProgress(Percent: Integer);
    procedure OnTeletype(const Msg: string; Severity: TTeletypeSeverity);
  end;

procedure Require(Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create('Publisher indexer: ' + Message);
end;

procedure TIndexObserver.OnTeletype(const Msg: string; Severity: TTeletypeSeverity);
begin
  if Severity = tsWarning then Inc(WarningCount);
end;

procedure TIndexObserver.OnProgress(Percent: Integer);
begin
  LastPercent := Percent;
  if CancelIssued and (Percent >= 100) then
    CompletedAfterCancel := True;
  if (CancelPercent > 0) and not CancelIssued and
     (Percent >= CancelPercent) and (Percent < 100) then
  begin
    CancelIssued := True;
    Worker.Cancel;
  end;
end;

procedure RunIndexer(const CollectionID, CancelPercent, ExpectedIndexed,
  ExpectedFailed, ExpectedCached: Integer; const ForceRescan: Boolean = False);
var
  Observer: TIndexObserver;
  Worker: TIndexPublisherSeriesThread;
  Log: TStringList;
  Line: string;
  ErrorCount: Integer;
begin
  Observer := TIndexObserver.Create;
  try
    Worker := TIndexPublisherSeriesThread.Create(CollectionID, ForceRescan);
    try
      Observer.Worker := Worker;
      Observer.CancelPercent := CancelPercent;
      Worker.OnProgress := Observer.OnProgress;
      Worker.OnTeletype := Observer.OnTeletype;
      Worker.Start;
      // The production worker synchronizes progress events. Pump them without
      // a VCL message loop or windows, then join before inspecting its result.
      while not Worker.Finished do
        CheckSynchronize(20);
      Worker.WaitFor;
      if Assigned(Worker.FatalException) then
        raise Exception.Create('Publisher indexer worker: ' +
          Exception(Worker.FatalException).Message);
      Require(Observer.CancelIssued = (CancelPercent > 0), 'cancel callback not reached');
      Require(Worker.IndexedCount = ExpectedIndexed,
        Format('saved %d books, expected %d', [Worker.IndexedCount, ExpectedIndexed]));
      Require(Worker.FailedCount = ExpectedFailed,
        Format('failed %d books, expected %d', [Worker.FailedCount, ExpectedFailed]));
      Require(Worker.CachedCount = ExpectedCached,
        Format('cached %d books, expected %d', [Worker.CachedCount, ExpectedCached]));
      Require(Worker.SkippedCount = 0, 'local FB2 books were skipped');
      if Observer.CancelIssued then
      begin
        Require(not Observer.CompletedAfterCancel,
          'cancellation incorrectly reported 100 percent');
        Require(Observer.LastPercent = CancelPercent,
          'cancellation did not retain its actual progress');
      end
      else
        Require(Observer.LastPercent = 100, 'complete scan did not report 100 percent');
      if ExpectedFailed > 0 then
      begin
        Require(FileExists(Worker.ErrorLogFileName), 'full error log was not created');
        Log := TStringList.Create;
        try
          Log.LoadFromFile(Worker.ErrorLogFileName, TEncoding.UTF8);
          ErrorCount := 0;
          for Line in Log do
            if Line.StartsWith('Книга ') then Inc(ErrorCount);
          Require(ErrorCount = ExpectedFailed, 'full log lost errors beyond the visible limit');
          Require(Log.Text.Contains('Файл в архиве:'), 'log is missing archive entry names');
          if CancelPercent > 0 then
            Require(Log.Text.Contains('Индексация отменена'), 'cancellation missing from full log');
        finally
          Log.Free;
        end;
        Require(Observer.WarningCount = Min(ExpectedFailed, 20) + Ord(ExpectedFailed > 20),
          'visible errors exceed the preview limit');
        TFile.Delete(Worker.ErrorLogFileName);
      end
      else
        Require(not FileExists(Worker.ErrorLogFileName), 'successful scan created an empty error log');
    finally
      Worker.Free;
    end;
  finally
    Observer.Free;
  end;
end;

procedure CheckPublisherSeriesIndexer(const Collection: IBookCollection;
  const BookIDs: TArray<Integer>);
const
  TotalBooks = 600;
  SeriesTitle = 'Index fixture publisher series';
  ValidBook = '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
    '<description><title-info><book-title>Index fixture</book-title></title-info>' +
    '<publish-info><sequence name="Index fixture publisher series" number="23"/>' +
    '</publish-info></description><body><section><p>Fixture</p></section></body>' +
    '</FictionBook>';
var
  Originals: TArray<TBookRecord>;
  OriginalFiles: TArray<TBytes>;
  Paths: TArray<string>;
  ExtraIDs: TArray<Integer>;
  AllIDs: TArray<Integer>;
  Book: TBookRecord;
  Series, Stored: TBookSeries;
  I, Indexed: Integer;
  Iterator: IBookIterator;
  ChangedBook: string;
  PreviousWriteTime: TDateTime;

  procedure RequireSeries(const BookID: Integer; const ExpectedTitle: string);
  var
    Value: TBookSeries;
  begin
    Value := Collection.GetBookPublisherSeries(
      CreateBookKey(BookID, Collection.CollectionID));
    if ExpectedTitle = '' then
      Require(Length(Value) = 0, 'valid empty metadata did not clear old series')
    else
      Require((Length(Value) = 1) and (Value[0].SeriesTitle = ExpectedTitle),
        'missing or corrupt descriptor erased previous metadata');
  end;

begin
  Require(Length(BookIDs) = 6, 'requires the six disposable fixture books');
  SetLength(Originals, Length(BookIDs));
  SetLength(OriginalFiles, Length(BookIDs));
  SetLength(Paths, Length(BookIDs));
  SetLength(ExtraIDs, TotalBooks - Length(BookIDs));
  SetLength(AllIDs, TotalBooks);
  for I := 0 to High(BookIDs) do
  begin
    Collection.GetBookRecord(CreateBookKey(BookIDs[I], Collection.CollectionID),
      Originals[I], True);
    Paths[I] := Originals[I].GetBookFileName;
    OriginalFiles[I] := TFile.ReadAllBytes(Paths[I]);
    AllIDs[I] := BookIDs[I];
  end;

  try
    for I := 0 to High(Paths) do
      TFile.WriteAllBytes(Paths[I], TEncoding.UTF8.GetBytes(ValidBook));
    TSeriesHelper.Add(Series, 0, 'Previous publisher series', 7, False);
    Collection.BeginBulkOperation;
    try
      for I := 0 to High(BookIDs) do
        Collection.SetBookPublisherSeries(Originals[I].BookKey, Series);
      for I := 0 to High(ExtraIDs) do
      begin
        Book := Originals[0];
        Book.BookKey.Clear;
        Book.LibID := 'publisher-index-fixture-' + IntToStr(I);
        Book.PublisherSeries := Series;
        Book.PublisherSeriesKnown := True;
        ExtraIDs[I] := Collection.InsertBook(Book, False, False);
        AllIDs[Length(BookIDs) + I] := ExtraIDs[I];
      end;
      Collection.EndBulkOperation(True);
    except
      Collection.EndBulkOperation(False);
      raise;
    end;

    // 540 completions cross five 100-book commit boundaries and leave forty
    // completed records in the partial chunk flushed on cancellation.
    RunIndexer(Collection.CollectionID, 90, 540, 0, 0);
    Indexed := 0;
    for I := 0 to High(AllIDs) do
    begin
      Stored := Collection.GetBookPublisherSeries(
        CreateBookKey(AllIDs[I], Collection.CollectionID));
      Require(Length(Stored) = 1, 'cancellation saved a partial book');
      if Stored[0].SeriesTitle = SeriesTitle then
      begin
        Require(Stored[0].SeqNumber = 23, 'publisher number changed');
        Inc(Indexed);
      end
      else
        Require(Stored[0].SeriesTitle = 'Previous publisher series',
          'cancellation changed an unprocessed book');
    end;
    Require(Indexed = 540, 'committed data differs from the canceled worker count');

    RunIndexer(Collection.CollectionID, 0, 60, 0, 540);
    for I := 0 to High(AllIDs) do
      RequireSeries(AllIDs[I], SeriesTitle);
    RunIndexer(Collection.CollectionID, 0, 0, 0, TotalBooks);
    RunIndexer(Collection.CollectionID, 0, TotalBooks, 0, 0, True);

    // Only book6 refers to this source; the extra records share book1.
    ChangedBook := StringReplace(ValidBook, 'number="23"', 'number="142"', []);
    TFile.WriteAllBytes(Paths[5], TEncoding.UTF8.GetBytes(ChangedBook));
    RunIndexer(Collection.CollectionID, 0, 1, 0, TotalBooks - 1);
    Stored := Collection.GetBookPublisherSeries(Originals[5].BookKey);
    Require((Length(Stored) = 1) and (Stored[0].SeqNumber = 142),
      'changed source size did not invalidate the cache');

    PreviousWriteTime := TFile.GetLastWriteTimeUtc(Paths[5]);
    ChangedBook := StringReplace(ChangedBook, 'number="142"', 'number="143"', []);
    TFile.WriteAllBytes(Paths[5], TEncoding.UTF8.GetBytes(ChangedBook));
    TFile.SetLastWriteTimeUtc(Paths[5], PreviousWriteTime + EncodeTime(0, 0, 2, 0));
    RunIndexer(Collection.CollectionID, 0, 1, 0, TotalBooks - 1);
    Stored := Collection.GetBookPublisherSeries(Originals[5].BookKey);
    Require((Length(Stored) = 1) and (Stored[0].SeqNumber = 143),
      'changed source mtime with identical size did not invalidate the cache');

    Collection.GetBookRecord(Originals[0].BookKey, Book, False);
    Book.FileName := '__publisher_index_missing_file__';
    Collection.UpdateBook(Book);
    TFile.WriteAllBytes(Paths[1], TEncoding.UTF8.GetBytes('<FictionBook>'));
    TFile.WriteAllBytes(Paths[2], OriginalFiles[2]); // valid FB2, no publish-info
    TFile.WriteAllBytes(Paths[3], TEncoding.UTF8.GetBytes('<NotFictionBook/>'));
    TFile.WriteAllBytes(Paths[4], TEncoding.UTF8.GetBytes(
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"/>'));
    RunIndexer(Collection.CollectionID, 0, 1, 4, TotalBooks - 5);
    RequireSeries(BookIDs[0], SeriesTitle);
    RequireSeries(BookIDs[1], SeriesTitle);
    RequireSeries(BookIDs[2], '');
    RequireSeries(BookIDs[3], SeriesTitle);
    RequireSeries(BookIDs[4], SeriesTitle);
    // Errors must remain retryable, while a valid empty result is cached.
    RunIndexer(Collection.CollectionID, 0, 0, 4, TotalBooks - 4);
    TFile.WriteAllBytes(Paths[0], TEncoding.UTF8.GetBytes('<NotFictionBook/>'));
    RunIndexer(Collection.CollectionID, 0, 0, TotalBooks - 2, 2);
    RunIndexer(Collection.CollectionID, 90, 0, 538, 2);
  finally
    for I := 0 to High(Paths) do
      TFile.WriteAllBytes(Paths[I], OriginalFiles[I]);
    Collection.BeginBulkOperation;
    try
      for I := 0 to High(ExtraIDs) do
        if ExtraIDs[I] > 0 then
          Collection.DeleteBook(CreateBookKey(ExtraIDs[I], Collection.CollectionID));
      for I := 0 to High(Originals) do
        Collection.UpdateBook(Originals[I]);
      Collection.EndBulkOperation(True);
    except
      Collection.EndBulkOperation(False);
      raise;
    end;
  end;
  Iterator := Collection.GetBookIterator(bmAll, False);
  Require(Iterator.RecordCount = Length(BookIDs), 'fixture books not restored');
  Require(Length(Collection.GetBookSeries(Originals[0].BookKey)) = 2,
    'indexing changed author cycles');
end;

end.
