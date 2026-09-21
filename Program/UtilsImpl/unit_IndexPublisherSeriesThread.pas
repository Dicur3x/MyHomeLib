(*
  HomeLib Ru, based on MyHomeLib
  Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
*)

unit unit_IndexPublisherSeriesThread;

interface

uses
  unit_CollectionWorkerThread,
  unit_Globals,
  unit_PublisherSeriesSource,
  unit_FB2PublisherMetadataReader;

type
  TIndexPublisherSeriesThread = class(TCollectionWorker)
  private
    FIndexedCount: Integer;
    FSkippedCount: Integer;
    FFailedCount: Integer;
    FCachedCount: Integer;
    FForceRescan: Boolean;
    FCompleted: Boolean;
    FSource: TPublisherSeriesSource;
    FReader: TFB2PublisherMetadataReader;
    FArchiveOpenCount: Integer;
    FBatchCount: Integer;
    procedure ReportIndexProgress(Percent: Integer);
    function ReadPublisherSeries(const BookRecord: TBookRecord;
      out Series: TBookSeries): Boolean;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const CollectionID: Integer;
      const ForceRescan: Boolean = False);
    // Read these counters only after the worker has finished.
    property IndexedCount: Integer read FIndexedCount;
    property SkippedCount: Integer read FSkippedCount;
    property FailedCount: Integer read FFailedCount;
    property CachedCount: Integer read FCachedCount;
    property ArchiveOpenCount: Integer read FArchiveOpenCount;
    property BatchCount: Integer read FBatchCount;
  end;

implementation

uses
  Classes,
  SysUtils,
  System.Math,
  unit_FB2Utils,
  unit_Interfaces;

resourcestring
  rstrIndexPublisherSeriesProgress = 'Проверено книг: %u из %u';
  rstrIndexPublisherSeriesMissing = 'Описание книги недоступно';
  rstrIndexPublisherSeriesError = 'Книга %d (%s): %s';
  rstrIndexPublisherSeriesSummary = 'Книжные серии: сохранено книг %u, уже проверено %u, пропущено %u, ошибок %u.';
  rstrIndexPublisherSeriesCanceled = 'Индексация отменена. Завершённые книги сохранены.';
  rstrIndexPublisherSeriesMoreErrors = 'Остальные ошибки учтены в итоговом количестве.';

constructor TIndexPublisherSeriesThread.Create(const CollectionID: Integer;
  const ForceRescan: Boolean);
begin
  inherited Create(CollectionID);
  FForceRescan := ForceRescan;
end;

procedure TIndexPublisherSeriesThread.ReportIndexProgress(Percent: Integer);
begin
  if not FCompleted and (Percent = 100) then
    SetProgress(FProgressEngine.GetProgress)
  else
    SetProgress(Percent);
end;

function TIndexPublisherSeriesThread.ReadPublisherSeries(
  const BookRecord: TBookRecord; out Series: TBookSeries): Boolean;
const
  MaxReportedErrors = 20;
var
  Stream: TStream;
  Metadata: TFB2PublisherSeries;
  Item: TFB2PublisherSeriesItem;
  ErrorText: string;
  Status: TFB2MetadataStatus;
begin
  Result := False;
  Series := nil;
  try
    Stream := FSource.OpenDescriptor(BookRecord);
    try
      if not Assigned(Stream) then
        raise EReadError.Create(rstrIndexPublisherSeriesMissing);
      Status := FReader.Read(Stream, Metadata, ErrorText,
        function: Boolean
        begin
          Result := Canceled;
        end);
      if Status = fmsCanceled then
        Exit;
      if Status <> fmsComplete then
        raise EReadError.Create(ErrorText);
      for Item in Metadata do
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
      if Canceled then
        Exit;
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
    SourceKey: string;
  end;
var
  Iterator: IPublisherSeriesIndexIterator;
  BookRecord: TBookRecord;
  Books: TArray<TBookRecord>;
  IndexedKeys: TArray<string>;
  SourceKey: string;
  Series: TBookSeries;
  Pending: array[0..ChunkSize - 1] of TPendingBook;
  PendingCount, BookCount, BookIndex: Integer;

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
        FCollection.CompletePublisherSeriesIndex(Pending[I].BookKey,
          Pending[I].Series, Pending[I].SourceKey);
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
  FProgressEngine.OnSetProgress := ReportIndexProgress;
  FSource := TPublisherSeriesSource.Create(
    function: Boolean
    begin
      Result := Canceled;
    end);
  try
    FReader := TFB2PublisherMetadataReader.Create;
    Iterator := FCollection.GetPublisherSeriesIndexIterator;
    FProgressEngine.BeginOperation(Iterator.RecordCount,
      rstrIndexPublisherSeriesProgress, rstrIndexPublisherSeriesProgress);
    while not Canceled do
    begin
      BookCount := 0;
      SetLength(Books, ChunkSize);
      SetLength(IndexedKeys, ChunkSize);
      while (BookCount < ChunkSize) and not Canceled and
        Iterator.Next(Books[BookCount], IndexedKeys[BookCount]) do
      begin
        Inc(BookCount);
      end;
      if BookCount = 0 then Break;
      SetLength(Books, BookCount);
      for BookIndex := 0 to BookCount - 1 do
      begin
        if Canceled then Break;
        FSource.SetUpcoming(Books, BookIndex);
        BookRecord := Books[BookIndex];
        if not (bpIsLocal in BookRecord.BookProps) or
           (BookRecord.GetBookFormat in [bfRaw, bfRawArchive]) then
          Inc(FSkippedCount)
        else
        begin
          SourceKey := FSource.GetSourceKey(BookRecord);
          if not FForceRescan and (SourceKey <> '') and
             (SourceKey = IndexedKeys[BookIndex]) then
            Inc(FCachedCount)
          else if ReadPublisherSeries(BookRecord, Series) then
          begin
            if Canceled then Break;
            // Never certify metadata if the underlying source changed mid-read.
            if (SourceKey <> '') and
               (SourceKey = FSource.GetSourceKey(BookRecord)) then
            begin
              Pending[PendingCount].BookKey := BookRecord.BookKey;
              Pending[PendingCount].Series := Series;
              Pending[PendingCount].SourceKey := SourceKey;
              Inc(PendingCount);
              if PendingCount = ChunkSize then
                CommitPending;
            end
            else
              Inc(FFailedCount);
          end;
        end;
        FProgressEngine.AddProgress;
      end;
    end;
    // Cancellation retains only metadata from completely parsed books.
    CommitPending;
    if Canceled then
      Teletype(rstrIndexPublisherSeriesCanceled);
    FCompleted := not Canceled;
    Teletype(Format(rstrIndexPublisherSeriesSummary,
      [FIndexedCount, FCachedCount, FSkippedCount, FFailedCount]));
  finally
    Iterator := nil;
    FArchiveOpenCount := FSource.ArchiveOpenCount;
    FBatchCount := FSource.BatchCount;
    FreeAndNil(FReader);
    FreeAndNil(FSource);
    FProgressEngine.EndOperation;
  end;
end;

end.
