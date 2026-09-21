unit unit_MCP_PublisherIndexBenchmark;

interface

// Call only after the guarded RunMakeFixtureMode created its disposable profile.
procedure RunPublisherIndexBenchmarkMode(const RealArchiveFileName: string);

implementation

uses
  System.Classes,
  System.SysUtils,
  System.IOUtils,
  System.Diagnostics,
  System.JSON,
  System.Zip,
  XMLDoc,
  XMLIntf,
  fictionbook_21,
  unit_FB2Utils,
  unit_Globals,
  unit_Consts,
  unit_Interfaces,
  unit_MHLArchiveHelpers,
  unit_WorkerThread,
  unit_CollectionWorkerThread,
  unit_IndexPublisherSeriesThread,
  unit_MCP_Fixture,
  unit_MCP_Transport,
  dm_user;

type
  TLegacyPublisherIndexWorker = class(TCollectionWorker)
  private
    FIndexedCount: Integer;
    FArchiveOpenCount: Integer;
  protected
    procedure WorkFunction; override;
  public
    property IndexedCount: Integer read FIndexedCount;
    property ArchiveOpenCount: Integer read FArchiveOpenCount;
  end;

  TBenchmarkResult = record
    ElapsedMS: Int64;
    IndexedCount: Integer;
    CachedCount: Integer;
    FailedCount: Integer;
    ArchiveOpenCount: Integer;
    BatchCount: Integer;
  end;

procedure Require(const Condition: Boolean; const Message: string);
begin
  if not Condition then
    raise Exception.Create('Publisher benchmark: ' + Message);
end;

function ReadLegacySeries(const BookRecord: TBookRecord): TBookSeries;
var
  Stream: TStream;
  Document: IXMLDocument;
  Root, Description: IXMLNode;
  Book: IXMLFictionBook;
  Item: TFB2PublisherSeriesItem;
begin
  Result := nil;
  // Preserve the released per-entry/full-DOM algorithm for comparison. The
  // database implementation is shared so both timings use identical storage.
  Stream := BookRecord.GetBookDescriptorStream(False);
  try
    Require(Assigned(Stream), 'descriptor unavailable: ' + BookRecord.FileName);
    Document := NewXMLDocument;
    Document.LoadFromStream(Stream);
    Root := Document.DocumentElement;
    Require(Assigned(Root) and (Root.LocalName = 'FictionBook'), 'invalid FB2 root');
    Require((Root.NamespaceURI = '') or
      (Root.NamespaceURI = fictionbook_21.TargetNamespace), 'invalid FB2 namespace');
    Description := Root.ChildNodes.FindNode('description', Root.NamespaceURI);
    Require(Assigned(Description), 'missing FB2 description');
    Require(Assigned(Description.ChildNodes.FindNode('title-info', Root.NamespaceURI)),
      'missing FB2 title-info');
    Book := Document.GetDocBinding('FictionBook', TXMLFictionBook,
      Root.NamespaceURI) as IXMLFictionBook;
    for Item in GetBookPublisherSeriesData(Book) do
      TSeriesHelper.Add(Result, 0, Item.Title, Item.Number, False);
  finally
    Stream.Free;
  end;
end;

procedure TLegacyPublisherIndexWorker.WorkFunction;
const
  ChunkSize = 100;
type
  TPendingBook = record
    Key: TBookKey;
    Series: TBookSeries;
  end;
var
  Iterator: IBookIterator;
  Book: TBookRecord;
  Pending: array[0..ChunkSize - 1] of TPendingBook;
  PendingCount: Integer;

  procedure CommitPending;
  var
    I: Integer;
  begin
    if PendingCount = 0 then
      Exit;
    FCollection.BeginBulkOperation;
    try
      for I := 0 to PendingCount - 1 do
        FCollection.SetBookPublisherSeries(Pending[I].Key, Pending[I].Series);
      FCollection.EndBulkOperation(True);
    except
      FCollection.EndBulkOperation(False);
      raise;
    end;
    Inc(FIndexedCount, PendingCount);
    for I := 0 to PendingCount - 1 do
      Pending[I].Series := nil;
    PendingCount := 0;
  end;

begin
  PendingCount := 0;
  Iterator := FCollection.GetBookIterator(bmAll, False);
  FProgressEngine.BeginOperation(Iterator.RecordCount, '%u/%u', '%u/%u');
  try
    while Iterator.Next(Book) do
    begin
      Require(not Canceled, 'legacy benchmark canceled');
      Pending[PendingCount].Key := Book.BookKey;
      if Book.GetBookFormat in [bfFb2Archive, bfFbd] then
        Inc(FArchiveOpenCount);
      Pending[PendingCount].Series := ReadLegacySeries(Book);
      Inc(PendingCount);
      if PendingCount = ChunkSize then
        CommitPending;
      FProgressEngine.AddProgress;
    end;
    CommitPending;
  finally
    Iterator := nil;
    FProgressEngine.EndOperation;
  end;
end;

function RunWorker(const Worker: TWorker): Int64;
var
  Watch: TStopwatch;
begin
  Watch := TStopwatch.StartNew;
  Worker.Start;
  while not Worker.Finished do
    CheckSynchronize(20);
  Worker.WaitFor;
  Result := Watch.ElapsedMilliseconds;
  if Assigned(Worker.FatalException) then
    raise Exception.Create('Publisher benchmark worker: ' +
      Exception(Worker.FatalException).Message);
end;

function RunLegacy(const CollectionID: Integer): TBenchmarkResult;
var
  Worker: TLegacyPublisherIndexWorker;
begin
  Result := Default(TBenchmarkResult);
  Worker := TLegacyPublisherIndexWorker.Create(CollectionID);
  try
    Result.ElapsedMS := RunWorker(Worker);
    Result.IndexedCount := Worker.IndexedCount;
    Result.ArchiveOpenCount := Worker.ArchiveOpenCount;
  finally
    Worker.Free;
  end;
end;

function RunCurrent(const CollectionID: Integer;
  const ForceRescan: Boolean = False): TBenchmarkResult;
var
  Worker: TIndexPublisherSeriesThread;
begin
  Result := Default(TBenchmarkResult);
  Worker := TIndexPublisherSeriesThread.Create(CollectionID, ForceRescan);
  try
    Result.ElapsedMS := RunWorker(Worker);
    Result.IndexedCount := Worker.IndexedCount;
    Result.CachedCount := Worker.CachedCount;
    Result.FailedCount := Worker.FailedCount;
    Result.ArchiveOpenCount := Worker.ArchiveOpenCount;
    Result.BatchCount := Worker.BatchCount;
    Require(Worker.SkippedCount = 0, 'benchmark unexpectedly skipped local FB2');
  finally
    Worker.Free;
  end;
end;

function CaptureSeries(const Collection: IBookCollection;
  const IDs: TArray<Integer>): string;
var
  Lines: TStringList;
  BookID: Integer;
  Item: TBookSeriesData;
begin
  Lines := TStringList.Create;
  try
    Lines.Sorted := True;
    for BookID in IDs do
      for Item in Collection.GetBookPublisherSeries(
        CreateBookKey(BookID, Collection.CollectionID)) do
        Lines.Add(Format('%d:%d:%s:%d',
          [BookID, Length(Item.SeriesTitle), Item.SeriesTitle, Item.SeqNumber]));
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function MetricsJSON(const Value: TBenchmarkResult): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('elapsed_ms', TJSONNumber.Create(Value.ElapsedMS));
  Result.AddPair('indexed', TJSONNumber.Create(Value.IndexedCount));
  Result.AddPair('cached', TJSONNumber.Create(Value.CachedCount));
  Result.AddPair('failed', TJSONNumber.Create(Value.FailedCount));
  Result.AddPair('archive_opens', TJSONNumber.Create(Value.ArchiveOpenCount));
  Result.AddPair('batches', TJSONNumber.Create(Value.BatchCount));
end;

function SyntheticBook(const Index: Integer): string;
begin
  Result := '<?xml version="1.0" encoding="utf-8"?>' +
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">' +
    '<description><title-info><book-title>Benchmark ' + IntToStr(Index) +
    '</book-title></title-info><publish-info><sequence name="Publisher ' +
    IntToStr(Index mod 17) + '" number="' + IntToStr(Index + 1) + '"/>';
  if Index mod 3 = 0 then
    Result := Result + '<sequence name="Second &amp; publisher" number="' +
      IntToStr(Index + 7) + '"/>';
  Result := Result + '</publish-info></description><body><section><p>' +
    StringOfChar(Char(Ord('a') + Index mod 26), 65536 + Index mod 257) +
    '</p></section></body></FictionBook>';
end;

procedure MakeSyntheticZip(const FileName: string; const Count: Integer);
var
  Zip: TZipFile;
  Stream: TBytesStream;
  I: Integer;
begin
  Zip := TZipFile.Create;
  try
    Zip.Open(FileName, zmWrite);
    for I := 0 to Count - 1 do
    begin
      Stream := TBytesStream.Create(TEncoding.UTF8.GetBytes(SyntheticBook(I)));
      try
        Zip.Add(Stream, Format('book%.4d.fb2', [I]), zcDeflate);
      finally
        Stream.Free;
      end;
    end;
    Zip.Close;
  finally
    Zip.Free;
  end;
end;

function BenchmarkArchive(const ArchiveFileName, DatabaseFolder, Name: string;
  const ExpectedBooks: Integer; const IsSynthetic: Boolean): TJSONObject;
var
  Collection: IBookCollection;
  Archive: TMHLZip;
  EntryNames: TStringList;
  CollectionID, I: Integer;
  IDs: TArray<Integer>;
  Book: TBookRecord;
  Baseline, Actual: string;
  Legacy, Current, Cached, Forced: TBenchmarkResult;
  Series: TBookSeries;
begin
  Result := nil;
  Require(FileExists(ArchiveFileName), 'archive does not exist: ' + ArchiveFileName);
  EntryNames := TStringList.Create;
  try
    Archive := TMHLZip.Create(ArchiveFileName, True);
    try
      for I := 0 to Archive.FileCount - 1 do
        if SameText(ExtractFileExt(Archive.FileNames[I]), '.fb2') then
          EntryNames.Add(Archive.FileNames[I]);
    finally
      Archive.Free;
    end;
    Require(EntryNames.Count = ExpectedBooks,
      Format('%s has %d FB2, expected exactly %d', [Name, EntryNames.Count, ExpectedBooks]));
    EntryNames.Sort;
    CollectionID := SystemDB.CreateCollection('Publisher benchmark ' + Name,
      ExtractFilePath(ArchiveFileName), TPath.Combine(DatabaseFolder, Name + '.hlc2'),
      CONTENT_FB or LIBRARY_PRIVATE or LOCATION_LOCAL,
      DMUser.Settings.AppPath + GENRES_FB2_FILENAME);
    Collection := SystemDB.GetCollection(CollectionID);
    SetLength(IDs, EntryNames.Count);
    Collection.BeginBulkOperation;
    try
      for I := 0 to EntryNames.Count - 1 do
      begin
        Book.Clear;
        Book.Title := EntryNames[I];
        Book.LibID := 'benchmark-' + IntToStr(I);
        Book.FileName := ChangeFileExt(EntryNames[I], '');
        Book.FileExt := '.fb2';
        // ZIP descriptors use the stored archive index. Synthetic names have
        // fixed-width numbers and were written in this same sorted order.
        Book.InsideNo := I;
        Book.Folder := ExtractFileName(ArchiveFileName);
        Book.CollectionRoot := ExtractFilePath(ArchiveFileName);
        Include(Book.BookProps, bpIsLocal);
        IDs[I] := Collection.InsertBook(Book, False, False);
      end;
      Collection.EndBulkOperation(True);
    except
      Collection.EndBulkOperation(False);
      raise;
    end;

    Legacy := RunLegacy(CollectionID);
    Require(Legacy.IndexedCount = ExpectedBooks, 'legacy count differs');
    Baseline := CaptureSeries(Collection, IDs);
    if IsSynthetic then
      for I := 0 to High(IDs) do
      begin
        Series := Collection.GetBookPublisherSeries(CreateBookKey(IDs[I], CollectionID));
        Require(Length(Series) = 1 + Ord(I mod 3 = 0), 'synthetic series count differs');
      end;

    // The legacy setter leaves no source-key marker. Clear the values as well
    // so a no-op or partially implemented new indexer cannot pass equality.
    Collection.BeginBulkOperation;
    try
      for I := 0 to High(IDs) do
        Collection.SetBookPublisherSeries(CreateBookKey(IDs[I], CollectionID), nil);
      Collection.EndBulkOperation(True);
    except
      Collection.EndBulkOperation(False);
      raise;
    end;
    Current := RunCurrent(CollectionID);
    Require((Current.IndexedCount = ExpectedBooks) and (Current.CachedCount = 0) and
      (Current.FailedCount = 0), 'uncached current count differs');
    Require(Current.ArchiveOpenCount = 1, 'current indexer reopened the same archive');
    Require(Current.BatchCount = Ord(not IsSynthetic), 'unexpected archive batch count');
    Actual := CaptureSeries(Collection, IDs);
    Require(Actual = Baseline, 'new series differ from the legacy algorithm');

    Cached := RunCurrent(CollectionID);
    Require((Cached.IndexedCount = 0) and (Cached.CachedCount = ExpectedBooks) and
      (Cached.FailedCount = 0), 'unchanged archive was not fully cached');
    Require((Cached.ArchiveOpenCount = 0) and (Cached.BatchCount = 0),
      'cached books opened or extracted the archive');
    Require(CaptureSeries(Collection, IDs) = Baseline, 'cached results changed');

    Forced := RunCurrent(CollectionID, True);
    Require((Forced.IndexedCount = ExpectedBooks) and (Forced.CachedCount = 0) and
      (Forced.FailedCount = 0), 'force rescan did not bypass the cache');
    Require((Forced.ArchiveOpenCount = 1) and
      (Forced.BatchCount = Ord(not IsSynthetic)), 'forced scan lost archive reuse');
    Require(CaptureSeries(Collection, IDs) = Baseline, 'forced results changed');

    Result := TJSONObject.Create;
    Result.AddPair('name', Name);
    Result.AddPair('books', TJSONNumber.Create(ExpectedBooks));
    Result.AddPair('archive', ArchiveFileName);
    Result.AddPair('legacy_dom_per_entry', MetricsJSON(Legacy));
    Result.AddPair('current_uncached', MetricsJSON(Current));
    Result.AddPair('current_cached', MetricsJSON(Cached));
    Result.AddPair('current_forced', MetricsJSON(Forced));
    Result.AddPair('results_equal', TJSONBool.Create(True));
  finally
    Collection := nil;
    EntryNames.Free;
  end;
end;

procedure RunPublisherIndexBenchmarkMode(const RealArchiveFileName: string);
var
  RootFolder, ArchiveFileName: string;
  Summary: TJSONObject;
  Runs: TJSONArray;
  Transport: TMcpTransport;
begin
  Require(Assigned(DMUser), 'disposable fixture is not initialized');
  // This subtree belongs to the existing guarded mcpfixture profile. No user
  // databases are opened, and the optional real archive is only read.
  RootFolder := TPath.Combine(TPath.Combine(ExtractFilePath(ParamStr(0)),
    FIXTURE_USER_NAME), 'publisher-benchmark');
  Require(not TDirectory.Exists(RootFolder), 'benchmark directory already exists');
  TDirectory.CreateDirectory(RootFolder);
  ArchiveFileName := TPath.Combine(RootFolder, 'synthetic1000.zip');
  MakeSyntheticZip(ArchiveFileName, 1000);
  Summary := TJSONObject.Create;
  try
    Summary.AddPair('benchmark', 'publisher_index');
    Summary.AddPair('profile', FIXTURE_USER_NAME);
    Summary.AddPair('timing_scope', 'worker including shared current DAO; setup excluded');
    Summary.AddPair('cache_conditions', 'OS cache not cleared; fixed legacy/current/cached/forced order');
    Runs := TJSONArray.Create;
    Summary.AddPair('runs', Runs);
    Runs.AddElement(BenchmarkArchive(ArchiveFileName, RootFolder, 'synthetic_zip_1000',
      1000, True));
    if RealArchiveFileName <> '' then
    begin
      Require(SameText(ExtractFileExt(RealArchiveFileName), '.7z'), 'real archive must be 7z');
      Runs.AddElement(BenchmarkArchive(TPath.GetFullPath(RealArchiveFileName),
        RootFolder, 'real_7z_40', 40, False));
    end;
    Transport := TMcpTransport.Create;
    try
      Transport.WriteMessage(Summary.ToJSON);
    finally
      Transport.Free;
    end;
  finally
    Summary.Free;
  end;
end;

end.
