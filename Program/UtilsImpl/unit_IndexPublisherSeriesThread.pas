(*
  HomeLib Ru, based on MyHomeLib
  Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
*)

unit unit_IndexPublisherSeriesThread;

interface

uses
  unit_CollectionWorkerThread,
  unit_Globals;

type
  TIndexPublisherSeriesThread = class(TCollectionWorker)
  private
    FIndexedCount: Integer;
    FSkippedCount: Integer;
    FFailedCount: Integer;
    function ReadPublisherSeries(const BookRecord: TBookRecord;
      out Series: TBookSeries): Boolean;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const CollectionID: Integer);
    // Read these counters only after the worker has finished.
    property IndexedCount: Integer read FIndexedCount;
    property SkippedCount: Integer read FSkippedCount;
    property FailedCount: Integer read FFailedCount;
  end;

implementation

uses
  Classes,
  SysUtils,
  XMLDoc,
  XMLIntf,
  fictionbook_21,
  unit_FB2Utils,
  unit_Interfaces;

resourcestring
  rstrIndexPublisherSeriesProgress = 'Проверено книг: %u из %u';
  rstrIndexPublisherSeriesInvalid = 'Некорректное описание FB2/FBD';
  rstrIndexPublisherSeriesMissing = 'Описание книги недоступно';
  rstrIndexPublisherSeriesError = 'Книга %d (%s): %s';
  rstrIndexPublisherSeriesSummary = 'Книжные серии: сохранено книг %u, пропущено %u, ошибок %u.';
  rstrIndexPublisherSeriesCanceled = 'Индексация отменена. Завершённые книги сохранены.';
  rstrIndexPublisherSeriesMoreErrors = 'Остальные ошибки учтены в итоговом количестве.';

constructor TIndexPublisherSeriesThread.Create(const CollectionID: Integer);
begin
  inherited Create(CollectionID);
end;

function TIndexPublisherSeriesThread.ReadPublisherSeries(
  const BookRecord: TBookRecord; out Series: TBookSeries): Boolean;
const
  MaxReportedErrors = 20;
var
  Stream: TStream;
  Document: IXMLDocument;
  Root, Description: IXMLNode;
  Book: IXMLFictionBook;
  Item: TFB2PublisherSeriesItem;
begin
  Result := False;
  Series := nil;
  try
    // FLibrary indexing needs the XML only, never reconstructed illustrations.
    Stream := BookRecord.GetBookDescriptorStream(False);
    try
      if not Assigned(Stream) then
        raise EReadError.Create(rstrIndexPublisherSeriesMissing);
      Document := NewXMLDocument;
      Document.LoadFromStream(Stream);
      Root := Document.DocumentElement;
      if not Assigned(Root) or (Root.LocalName <> 'FictionBook') then
        raise EReadError.Create(rstrIndexPublisherSeriesInvalid);
      if (Root.NamespaceURI <> '') and
         (Root.NamespaceURI <> fictionbook_21.TargetNamespace) then
        raise EReadError.Create(rstrIndexPublisherSeriesInvalid);
      Description := Root.ChildNodes.FindNode('description', Root.NamespaceURI);
      if not Assigned(Description) then
        raise EReadError.Create(rstrIndexPublisherSeriesInvalid);
      if not Assigned(Description.ChildNodes.FindNode('title-info',
        Root.NamespaceURI)) then
        raise EReadError.Create(rstrIndexPublisherSeriesInvalid);

      Book := Document.GetDocBinding('FictionBook', TXMLFictionBook,
        Root.NamespaceURI) as IXMLFictionBook;
      for Item in GetBookPublisherSeriesData(Book) do
        TSeriesHelper.Add(Series, 0, Item.Title, Item.Number, False);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on E: EOutOfMemory do raise;
    on E: EAccessViolation do raise;
    on E: Exception do
    begin
      Series := nil;
      Inc(FFailedCount);
      if FFailedCount <= MaxReportedErrors then
        Teletype(Format(rstrIndexPublisherSeriesError,
          [BookRecord.BookKey.BookID, BookRecord.Title, E.Message]), tsWarning)
      else if FFailedCount = MaxReportedErrors + 1 then
        Teletype(rstrIndexPublisherSeriesMoreErrors, tsWarning);
    end;
  end;
end;

procedure TIndexPublisherSeriesThread.WorkFunction;
const
  ChunkSize = 100;
type
  TPendingBook = record
    BookKey: TBookKey;
    Series: TBookSeries;
  end;
var
  Iterator: IBookIterator;
  BookRecord: TBookRecord;
  Series: TBookSeries;
  Pending: array[0..ChunkSize - 1] of TPendingBook;
  PendingCount: Integer;

  procedure CommitPending;
  var
    I: Integer;
    BulkActive: Boolean;
  begin
    if PendingCount = 0 then
      Exit;
    BulkActive := False;
    try
      // Keep disk extraction and XML parsing outside the write transaction.
      FCollection.BeginBulkOperation;
      BulkActive := True;
      for I := 0 to PendingCount - 1 do
        FCollection.SetBookPublisherSeries(Pending[I].BookKey, Pending[I].Series);
      FCollection.EndBulkOperation(True);
      BulkActive := False;
      Inc(FIndexedCount, PendingCount);
      for I := 0 to PendingCount - 1 do
        Pending[I].Series := nil;
      PendingCount := 0;
    except
      if BulkActive then
        FCollection.EndBulkOperation(False);
      raise;
    end;
  end;

begin
  PendingCount := 0;
  Iterator := FCollection.GetBookIterator(bmAll, False);
  FProgressEngine.BeginOperation(Iterator.RecordCount,
    rstrIndexPublisherSeriesProgress, rstrIndexPublisherSeriesProgress);
  try
    while not Canceled and Iterator.Next(BookRecord) do
    begin
      if not (bpIsLocal in BookRecord.BookProps) or
         (BookRecord.GetBookFormat in [bfRaw, bfRawArchive]) then
        Inc(FSkippedCount)
      else if ReadPublisherSeries(BookRecord, Series) then
      begin
        if Canceled then
          Break;
        Pending[PendingCount].BookKey := BookRecord.BookKey;
        Pending[PendingCount].Series := Series;
        Inc(PendingCount);
        if PendingCount = ChunkSize then
          CommitPending;
      end;
      FProgressEngine.AddProgress;
    end;
    // Cancellation retains only metadata from completely parsed books.
    CommitPending;
    if Canceled then
      Teletype(rstrIndexPublisherSeriesCanceled);
    Teletype(Format(rstrIndexPublisherSeriesSummary,
      [FIndexedCount, FSkippedCount, FFailedCount]));
  finally
    Iterator := nil;
    FProgressEngine.EndOperation;
  end;
end;

end.
