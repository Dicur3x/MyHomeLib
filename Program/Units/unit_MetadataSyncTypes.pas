unit unit_MetadataSyncTypes;

interface

uses unit_Globals;

type
  TMetadataSyncField = (msfPublisher, msfCity, msfPubYear, msfISBN,
    msfTranslators, msfAnnotation);
  TMetadataSyncFields = set of TMetadataSyncField;
  TMetadataSyncFieldCounts = array[TMetadataSyncField] of Int64;
  TMetadataSyncCounts = record
    BooksTotal, BooksChecked, BooksPlanned, BooksSkipped, BooksFailed: Int64;
    FieldCounts: TMetadataSyncFieldCounts;
    AnnotationBytes: Int64;
  end;
  TMetadataFillResult = (mfrUnchanged, mfrChanged, mfrIdentityChanged);

const
  METADATA_SYNC_DEFAULT_FIELDS: TMetadataSyncFields =
    [msfPublisher, msfCity, msfPubYear, msfISBN, msfTranslators];
  METADATA_SYNC_MAX_RECORD_BYTES = 64 * 1024;
  METADATA_SYNC_MAX_ANNOTATION_BYTES = 64 * 1024;

function MissingMetadataFields(const Book, Values: TBookRecord;
  const Fields: TMetadataSyncFields): TMetadataSyncFields;

implementation

uses System.SysUtils;

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
