unit unit_MetadataSyncTypes;

interface

uses unit_Globals;

type
  TMetadataSyncField = (msfPublisher, msfCity, msfPubYear, msfISBN,
    msfTranslators, msfAnnotation);
  TMetadataSyncFields = set of TMetadataSyncField;
  TMetadataSyncFieldCounts = array[TMetadataSyncField] of Int64;
  TMetadataReadFailure = (mrfUnavailable, mrfDecoder, mrfInvalidMetadata,
    mrfSourceChanged, mrfLimit, mrfSourceRead, mrfAmbiguous);
  TMetadataSyncCounts = record
    BooksTotal, BooksChecked, BooksPlanned, BooksSkipped, BooksFailed: Int64;
    FieldCounts: TMetadataSyncFieldCounts;
    AnnotationBytes, ArchiveOpens, BooksReused, FilesRead, AnnotationsOmitted, BooksStale: Int64;
    ErrorCounts: array[TMetadataReadFailure] of Int64;
    ErrorExamples: TArray<string>; // First 40 only; counters include every error.
  end;
  TMetadataFillResult = (mfrUnchanged, mfrChanged, mfrIdentityChanged);

  TMetadataTimingSample = record
    AtMS: UInt64;
    Checked: Int64;
  end;

  // UI-owned rolling estimate. An injected monotonic clock keeps cancellation,
  // slow archives and cache-to-file transitions testable without waiting.
  TMetadataTiming = record
  private
    FStartedAt, FLastAdvanceAt: UInt64;
    FChecked, FTotal: Int64;
    FSamples: array[0..30] of TMetadataTimingSample;
    FCount: Integer;
  public
    procedure Reset(NowMS: UInt64);
    procedure Sample(Checked, Total: Int64; NowMS: UInt64);
    function TryEstimate(NowMS: UInt64; out BooksPerSecond: Double;
      out RemainingSeconds: Int64): Boolean;
    function Description(NowMS: UInt64; ShowEstimate: Boolean): string;
  end;

const
  METADATA_SYNC_DEFAULT_FIELDS: TMetadataSyncFields =
    [msfPublisher, msfCity, msfPubYear, msfISBN, msfTranslators];
  METADATA_SYNC_MAX_RECORD_BYTES = 64 * 1024;
  METADATA_SYNC_MAX_ANNOTATION_BYTES = 64 * 1024;

function MetadataFailureName(Kind: TMetadataReadFailure): string;

function PendingMetadataFields(const Book: TBookRecord;
  const Fields: TMetadataSyncFields): TMetadataSyncFields;
function MissingMetadataFields(const Book, Values: TBookRecord;
  const Fields: TMetadataSyncFields): TMetadataSyncFields;

implementation

uses System.SysUtils, System.Math;

function MetadataDuration(Seconds: Int64): string;
begin
  Seconds:=Max(Int64(0),Seconds);
  if Seconds>=3600 then Result:=Format('%d ч %d мин',[Seconds div 3600,(Seconds div 60) mod 60])
  else if Seconds>=60 then Result:=Format('%d мин %d с',[Seconds div 60,Seconds mod 60])
  else Result:=IntToStr(Seconds)+' с';
end;

procedure TMetadataTiming.Reset(NowMS: UInt64);
begin
  FStartedAt:=NowMS; FLastAdvanceAt:=NowMS; FChecked:=0; FTotal:=0; FCount:=0;
end;

procedure TMetadataTiming.Sample(Checked, Total: Int64; NowMS: UInt64);
var I: Integer;
begin
  Checked:=Max(Int64(0),Checked); Total:=Max(Int64(0),Total);
  if Total>0 then Checked:=Min(Checked,Total);
  if (NowMS<FStartedAt) or (Checked<FChecked) then Reset(NowMS);
  if Checked>FChecked then FLastAdvanceAt:=NowMS;
  FChecked:=Checked; FTotal:=Total;
  if (FCount>0) and (NowMS-FSamples[FCount-1].AtMS<1000) then Exit;
  while (FCount>1) and (NowMS-FSamples[1].AtMS>=30000) do
  begin
    for I:=1 to FCount-1 do FSamples[I-1]:=FSamples[I];
    Dec(FCount);
  end;
  if FCount=Length(FSamples) then
  begin
    for I:=1 to FCount-1 do FSamples[I-1]:=FSamples[I];
    Dec(FCount);
  end;
  FSamples[FCount].AtMS:=NowMS; FSamples[FCount].Checked:=Checked; Inc(FCount);
end;

function TMetadataTiming.TryEstimate(NowMS: UInt64; out BooksPerSecond: Double;
  out RemainingSeconds: Int64): Boolean;
var Span: UInt64; Delta: Int64; Estimate: Double;
begin
  Result:=False; BooksPerSecond:=0; RemainingSeconds:=0;
  if (FTotal<=0) or (FChecked>=FTotal) or (FCount<2) or
    (NowMS<FSamples[0].AtMS) or (NowMS<FLastAdvanceAt) then Exit;
  Span:=NowMS-FSamples[0].AtMS; Delta:=FChecked-FSamples[0].Checked;
  // Early bursts and a stalled source are not a reliable completion forecast.
  if (Span<8000) or (Delta<=0) or (NowMS-FLastAdvanceAt>=10000) then Exit;
  BooksPerSecond:=Delta/(Span/1000.0);
  Estimate:=(FTotal-FChecked)/BooksPerSecond;
  if Estimate>=High(Int64) then Exit;
  RemainingSeconds:=Ceil(Estimate); Result:=True;
end;

function TMetadataTiming.Description(NowMS: UInt64; ShowEstimate: Boolean): string;
var Speed: Double; Remaining, Elapsed: Int64;
begin
  Elapsed:=0; if NowMS>=FStartedAt then Elapsed:=(NowMS-FStartedAt) div 1000;
  Result:='Прошло: '+MetadataDuration(Elapsed);
  if not ShowEstimate then Exit;
  if (FTotal>0) and (FChecked>=FTotal) then Exit(Result+' · Завершаем обработку…');
  if TryEstimate(NowMS,Speed,Remaining) then
    Result:=Result+' · '+FormatFloat('0.0',Speed)+' книг/с · Осталось: примерно '+MetadataDuration(Remaining)
  else if (FChecked>0) and (NowMS>=FLastAdvanceAt) and (NowMS-FLastAdvanceAt>=10000) then
    Result:=Result+' · Осталось: уточняется…'
  else Result:=Result+' · Осталось: оцениваем…';
end;

function MetadataFailureName(Kind: TMetadataReadFailure): string;
begin
  case Kind of
    mrfUnavailable: Result:='Файл или архив недоступен';
    mrfDecoder: Result:='Нужен другой способ распаковки или компонент';
    mrfInvalidMetadata: Result:='Не удалось прочитать метаданные книги';
    mrfSourceChanged: Result:='Источник изменился во время проверки';
    mrfAmbiguous: Result:='Несколько книг в одной записи архива';
    mrfLimit: Result:='Превышен предел размера метаданных';
  else Result:='Ошибка чтения файла или архива'; end;
end;

function PendingMetadataFields(const Book: TBookRecord;
  const Fields: TMetadataSyncFields): TMetadataSyncFields;
begin
  Result:=[];
  if (msfPublisher in Fields) and (Trim(Book.Publisher)='') then Include(Result,msfPublisher);
  if (msfCity in Fields) and (Trim(Book.City)='') then Include(Result,msfCity);
  if (msfPubYear in Fields) and (Book.PubYear=0) then Include(Result,msfPubYear);
  if (msfISBN in Fields) and (Trim(Book.ISBN)='') then Include(Result,msfISBN);
  if (msfTranslators in Fields) and (Trim(Book.Translators)='') then Include(Result,msfTranslators);
  if (msfAnnotation in Fields) and (Trim(Book.Annotation)='') then Include(Result,msfAnnotation);
end;

function MissingMetadataFields(const Book, Values: TBookRecord;
  const Fields: TMetadataSyncFields): TMetadataSyncFields;
begin
  Result := [];
  if (msfPublisher in Fields) and (Trim(Book.Publisher) = '') and
    (Trim(Values.Publisher) <> '') then Include(Result, msfPublisher);
  if (msfCity in Fields) and (Trim(Book.City) = '') and
    (Trim(Values.City) <> '') then Include(Result, msfCity);
  if (msfPubYear in Fields) and (Book.PubYear = 0) and
    (Values.PubYear > 0) then Include(Result, msfPubYear);
  if (msfISBN in Fields) and (Trim(Book.ISBN) = '') and
    (Trim(Values.ISBN) <> '') then Include(Result, msfISBN);
  if (msfTranslators in Fields) and (Trim(Book.Translators) = '') and
    (Trim(Values.Translators) <> '') then Include(Result, msfTranslators);
  if (msfAnnotation in Fields) and (Trim(Book.Annotation) = '') and
    (Trim(Values.Annotation) <> '') then Include(Result, msfAnnotation);
end;

end.
