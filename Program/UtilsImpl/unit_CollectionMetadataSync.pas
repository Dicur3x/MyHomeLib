unit unit_CollectionMetadataSync;

interface

uses System.Classes, System.SysUtils, unit_Globals, unit_Interfaces,
  unit_MetadataSyncTypes, unit_CollectionWorkerThread;

type
  TMetadataSyncProgress = reference to procedure(Checked, Total: Int64);
  TCollectionMetadataPlan = class
  private
    FCollectionID: Integer;
    FFields: TMetadataSyncFields;
    FCounts, FAvailableCounts: TMetadataSyncCounts;
    FMaskCounts: array[0..63] of Int64;
    FCollectionRoot, FCatalogRevision, FDirectory, FFileName, FHash: string;
  public
    destructor Destroy; override;
    procedure SelectFields(const Fields: TMetadataSyncFields);
    procedure MarkSelectionApplied;
    property AvailableCounts: TMetadataSyncCounts read FAvailableCounts;
    property CollectionID: Integer read FCollectionID;
    property Fields: TMetadataSyncFields read FFields;
    property Counts: TMetadataSyncCounts read FCounts;
    property CollectionRoot: string read FCollectionRoot;
    // Connection-local diagnostic, not a cross-connection identity proof.
    property CatalogRevision: string read FCatalogRevision;
    property StorageFileName: string read FFileName;
  end;

  TMetadataProgressWorker = class(TCollectionWorker)
  private
    FBooksChecked, FBooksTotal: Int64;
  protected
    procedure PublishBookProgress(Checked, Total: Int64);
  public
    procedure GetBookProgress(out Checked, Total: Int64);
  end;

  TMetadataPreviewThread = class(TMetadataProgressWorker)
  private
    FFields: TMetadataSyncFields;
    FPlan: TCollectionMetadataPlan;
    FCounts: TMetadataSyncCounts;
    FCompleted: Boolean;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(CollectionID: Integer; const Fields: TMetadataSyncFields);
    destructor Destroy; override;
    function TakePlan: TCollectionMetadataPlan;
    property Completed: Boolean read FCompleted;
    property Counts: TMetadataSyncCounts read FCounts;
  end;

  TMetadataApplyThread = class(TMetadataProgressWorker)
  private
    FPlan: TCollectionMetadataPlan; // Borrowed until the thread is joined.
    FCompleted: Boolean;
    FCounts: TMetadataSyncCounts;
    function GetBooksCommitted: Int64;
    function GetBooksSkipped: Int64;
    function GetBooksFailed: Int64;
    function GetFieldCounts: TMetadataSyncFieldCounts;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(Plan: TCollectionMetadataPlan);
    property Completed: Boolean read FCompleted;
    property Counts: TMetadataSyncCounts read FCounts;
    property BooksCommitted: Int64 read GetBooksCommitted;
    property BooksSkipped: Int64 read GetBooksSkipped;
    property BooksFailed: Int64 read GetBooksFailed;
    property FieldCounts: TMetadataSyncFieldCounts read GetFieldCounts;
  end;

// Synchronous core entry points also serve isolated native tests. Nil from
// preview means cancellation; no incomplete plan can be applied. Apply counters
// are published after each durable chunk, including on cancellation or error.
function PreviewCollectionMetadata(const Collection: IBookCollection;
  const Fields: TMetadataSyncFields; out Counts: TMetadataSyncCounts;
  const IsCanceled: TFunc<Boolean> = nil;
  const Progress: TMetadataSyncProgress = nil; WorkerLimit: Integer = 4): TCollectionMetadataPlan;
function ApplyCollectionMetadata(const Collection: IBookCollection;
  Plan: TCollectionMetadataPlan; var Counts: TMetadataSyncCounts;
  const IsCanceled: TFunc<Boolean> = nil;
  const Progress: TMetadataSyncProgress = nil): Boolean;

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, System.Hash, System.Math, System.SyncObjs,
  System.Generics.Collections, System.Generics.Defaults, unit_PackageBookMetadata,
  unit_BookCache, unit_PublisherSeriesSource, unit_FB2PublisherMetadataReader,
  unit_MHLArchiveHelpers, unit_MetadataReadCache, unit_MetadataScanReader, unit_MHLExternalTools;

const ChunkSize = 100;
  PreviewChunkSize = 1000;

type
  TPlannedMetadata = record
    Book, Values: TBookRecord;
    Fields: TMetadataSyncFields;
    SourceKey: string;
  end;

function Cancelled(const Predicate: TFunc<Boolean>): Boolean;
begin Result := Assigned(Predicate) and Predicate(); end;

function SameRoot(const A, B: string): Boolean;
begin
  Result := (A <> '') and (B <> '') and SameText(
    ExcludeTrailingPathDelimiter(ExpandFileName(A)),
    ExcludeTrailingPathDelimiter(ExpandFileName(B)));
end;

function FieldMask(const Fields: TMetadataSyncFields): Integer;
var F: TMetadataSyncField;
begin
  Result := 0;
  for F := Low(F) to High(F) do if F in Fields then Result := Result or (1 shl Ord(F));
end;

function HashStream(Stream: TStream; const IsCanceled: TFunc<Boolean>): string;
var Hash: THashSHA2; Buffer: TBytes; N: Integer;
begin
  Hash := THashSHA2.Create; SetLength(Buffer, 65536); Stream.Position := 0;
  repeat
    if Cancelled(IsCanceled) then raise EAbort.Create('Проверка отменена');
    SetLength(Buffer,65536); N := Stream.Read(Buffer[0], Length(Buffer));
    if N > 0 then begin SetLength(Buffer,N); Hash.Update(Buffer); end;
  until N = 0;
  Result := Hash.HashAsString; Stream.Position := 0;
end;

function EncodePlanRow(const Item: TPlannedMetadata): string;
var Obj: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('id', TJSONNumber.Create(Item.Book.BookKey.BookID));
    Obj.AddPair('lib', Item.Book.LibID); Obj.AddPair('folder', Item.Book.Folder);
    Obj.AddPair('file', Item.Book.FileName); Obj.AddPair('ext', Item.Book.FileExt);
    Obj.AddPair('inside', TJSONNumber.Create(Item.Book.InsideNo));
    Obj.AddPair('size', TJSONNumber.Create(Item.Book.Size));
    Obj.AddPair('fields', TJSONNumber.Create(FieldMask(Item.Fields)));
    Obj.AddPair('source', Item.SourceKey);
    Obj.AddPair('publisher', Item.Values.Publisher); Obj.AddPair('city', Item.Values.City);
    Obj.AddPair('year', TJSONNumber.Create(Item.Values.PubYear));
    Obj.AddPair('isbn', Item.Values.ISBN); Obj.AddPair('translators', Item.Values.Translators);
    Obj.AddPair('annotation', Item.Values.Annotation);
    Result := Obj.ToJSON;
  finally Obj.Free; end;
end;

function DecodePlanRow(const Text: string; Plan: TCollectionMetadataPlan): TPlannedMetadata;
var Value, V: TJSONValue; Obj: TJSONObject; F: TMetadataSyncField; Mask: Integer;
  function S(const Name: string): string;
  begin
    V := Obj.GetValue(Name);
    if not (V is TJSONString) then raise EReadError.Create('Некорректная строка плана: ' + Name);
    Result := V.Value;
  end;
  function I(const Name: string): Integer;
  begin
    V := Obj.GetValue(Name);
    if not (V is TJSONNumber) or not TryStrToInt(V.Value, Result) then
      raise EReadError.Create('Некорректное число плана: ' + Name);
  end;
begin
  Result := Default(TPlannedMetadata);
  if TEncoding.UTF8.GetByteCount(Text) > METADATA_SYNC_MAX_RECORD_BYTES then
    raise EReadError.Create('Строка плана превышает допустимый размер');
  Value := TJSONObject.ParseJSONValue(Text);
  try
    if not (Value is TJSONObject) then raise EReadError.Create('Некорректный план сведений');
    Obj := TJSONObject(Value);
    if Obj.Count <> 15 then raise EReadError.Create('Некорректный состав строки плана');
    Result.Book.BookKey := CreateBookKey(I('id'), Plan.CollectionID);
    if Result.Book.BookKey.BookID <= 0 then raise EReadError.Create('Некорректный ID книги в плане');
    Result.Book.CollectionRoot := Plan.CollectionRoot;
    Result.Book.LibID := S('lib'); Result.Book.Folder := S('folder');
    Result.Book.FileName := S('file'); Result.Book.FileExt := S('ext');
    Result.Book.InsideNo := I('inside'); Result.Book.Size := I('size');
    Include(Result.Book.BookProps, bpIsLocal);
    Mask := I('fields');
    if (Mask < 0) or (Mask > 63) then raise EReadError.Create('Некорректный набор полей плана');
    for F := Low(F) to High(F) do
      if (Mask and (1 shl Ord(F))) <> 0 then Include(Result.Fields, F);
    if Result.Fields = [] then
      raise EReadError.Create('Набор полей плана изменён');
    Result.SourceKey := S('source');
    if Result.SourceKey = '' then raise EReadError.Create('Отсутствует источник плана');
    Result.Values.Publisher := S('publisher'); Result.Values.City := S('city');
    Result.Values.PubYear := I('year'); Result.Values.ISBN := S('isbn');
    Result.Values.Translators := S('translators'); Result.Values.Annotation := S('annotation');
  finally Value.Free; end;
end;

procedure TCollectionMetadataPlan.SelectFields(const Fields: TMetadataSyncFields);
var Mask: Integer; Field: TMetadataSyncField;
begin
  FFields:=Fields; FCounts:=FAvailableCounts; FCounts.BooksPlanned:=0;
  for Mask:=1 to High(FMaskCounts) do
    if Mask and FieldMask(Fields)<>0 then Inc(FCounts.BooksPlanned,FMaskCounts[Mask]);
  FCounts.BooksSkipped:=FCounts.BooksChecked-FCounts.BooksFailed-FCounts.BooksPlanned;
  for Field:=Low(Field) to High(Field) do
    if not (Field in Fields) then FCounts.FieldCounts[Field]:=0;
  if not (msfAnnotation in Fields) then FCounts.AnnotationBytes:=0;
end;

procedure TCollectionMetadataPlan.MarkSelectionApplied;
var Remaining: array[0..63] of Int64; Mask: Integer; Field: TMetadataSyncField;
begin
  FillChar(Remaining,SizeOf(Remaining),0);
  for Mask:=1 to High(FMaskCounts) do
    Inc(Remaining[Mask and (63 xor FieldMask(FFields))],FMaskCounts[Mask]);
  for Mask:=0 to High(FMaskCounts) do FMaskCounts[Mask]:=Remaining[Mask];
  for Field:=Low(Field) to High(Field) do
    if Field in FFields then FAvailableCounts.FieldCounts[Field]:=0;
  if msfAnnotation in FFields then FAvailableCounts.AnnotationBytes:=0;
  SelectFields(FFields);
end;

procedure CreatePlanFile(Plan: TCollectionMetadataPlan; out Stream: TFileStream);
var ID: TGUID; Handle: THandle;
begin
  Stream := nil; CreateGUID(ID);
  Plan.FDirectory := TPath.Combine(BookCachePath, 'metadata-sync-' + GUIDToString(ID));
  if not ForceDirectories(BookCachePath) or not CreateDir(Plan.FDirectory) then RaiseLastOSError;
  Plan.FFileName := TPath.Combine(Plan.FDirectory, 'plan.pending');
  Handle := CreateFile(PChar(Plan.FFileName), GENERIC_READ or GENERIC_WRITE, 0,
    nil, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseLastOSError;
  CloseHandle(Handle);
  Stream := TFileStream.Create(Plan.FFileName, fmOpenReadWrite or fmShareExclusive);
end;

destructor TCollectionMetadataPlan.Destroy;
begin
  // Delete no arbitrary path, recursive tree, cache content or source book.
  if (FDirectory <> '') and (FFileName <> '') and SameText(
    ExtractFilePath(FFileName), IncludeTrailingPathDelimiter(FDirectory)) then
    System.SysUtils.DeleteFile(FFileName);
  if FDirectory <> '' then RemoveDir(FDirectory);
  inherited;
end;

function PreviewCollectionMetadata(const Collection: IBookCollection;
  const Fields: TMetadataSyncFields; out Counts: TMetadataSyncCounts;
  const IsCanceled: TFunc<Boolean>; const Progress: TMetadataSyncProgress; WorkerLimit: Integer): TCollectionMetadataPlan;
var Provider: IBookMetadataFillWriter; Plan: TCollectionMetadataPlan;
  Source: TPublisherSeriesSource; Spool: TStream;
  FileStream: TFileStream; Books: TArray<TBookRecord>; Book: TBookRecord;
  Metadata: TFB2CatalogMetadata; Item: TPlannedMetadata; Field: TMetadataSyncField;
  AfterID, Index: Integer; SourceKey, Line, FinalName: string;
  Bytes: TBytes; Complete, WritingPlan: Boolean;
  FailureKind: TMetadataReadFailure; ExampleCount: Integer;
  Cache: TMetadataReadCache; Reused: Boolean;
  Readings: TArray<TMetadataScanRead>; BatchOpens: Integer; Reported,BatchBase,BatchTotal: Int64;
const AllFields: TMetadataSyncFields = [msfPublisher..msfAnnotation];
begin
  Result := nil; Counts := Default(TMetadataSyncCounts);
  if not Assigned(Collection) or not Supports(Collection, IBookMetadataFillWriter, Provider) then
    raise ENotSupportedException.Create('Эта коллекция не поддерживает заполнение сведений');
  if Fields = [] then raise EArgumentException.Create('Выберите хотя бы одно поле');
  Plan := TCollectionMetadataPlan.Create; Source := nil; Spool := nil;
  Complete := False; Cache:=nil; Reported:=0;
  try
  try
    Plan.FCollectionID := Collection.CollectionID; Plan.FFields := Fields;
    Plan.FCollectionRoot := Provider.MetadataCollectionRoot;
    Plan.FCatalogRevision := Collection.GetCatalogRevision;
    Counts.BooksTotal := Provider.MetadataBookCount;
    CreatePlanFile(Plan, FileStream); Spool := FileStream;
    Source := TPublisherSeriesSource.Create(IsCanceled);
    Cache:=TMetadataReadCache.Create; AfterID := 0;
    while not Cancelled(IsCanceled) do
    begin
      Books := Provider.ReadMetadataBatch(AfterID, PreviewChunkSize);
      if Length(Books) = 0 then begin Complete := True; Break; end;
      AfterID:=Books[High(Books)].BookKey.BookID;
      TArray.Sort<TBookRecord>(Books,TComparer<TBookRecord>.Construct(
        function(const A,B: TBookRecord): Integer
        begin
          Result:=CompareText(A.Folder,B.Folder);
          if Result=0 then Result:=CompareValue(A.BookKey.BookID,B.BookKey.BookID);
        end));
      // Resolve cache hits before starting any decoder. Four bounded workers
      // overlap independent book reads; all cache/plan writes stay here.
      SetLength(Readings,0); SetLength(Readings,Length(Books));
      for Index:=0 to High(Books) do
      begin
        Book:=Books[Index]; Readings[Index].Ready:=True;
        if not (bpIsLocal in Book.BookProps) or (bpIsDeleted in Book.BookProps) or
           (PendingMetadataFields(Book,AllFields)=[]) or
           not ((Book.GetBookFormat in [bfFb2,bfFb2Archive,bfFbd]) or
             IsMetadataPackage(Book.FileExt) or IsMetadataContainer(Book.FileExt)) then Continue;
        Readings[Index].Failure:=mrfUnavailable;
        try Readings[Index].SourceKey:=Source.GetSourceKey(Book);
        except
          on E: EOutOfMemory do raise;
          on E: EAccessViolation do raise;
          on E: EMHLComponentRequired do raise;
          on E: Exception do begin Readings[Index].ErrorText:=E.Message; Continue; end;
        end;
        if Readings[Index].SourceKey='' then
        begin Readings[Index].ErrorText:='Исходный файл недоступен'; Continue; end;
        Readings[Index].Reused:=Cache.TryRead(Readings[Index].SourceKey,Readings[Index].Metadata);
        Readings[Index].Ready:=Readings[Index].Reused;
      end;
      BatchBase:=Counts.BooksChecked; BatchTotal:=Counts.BooksTotal;
      ReadMetadataScanBatch(Books,Readings,IsCanceled,BatchOpens,WorkerLimit,
        procedure(Done: Integer)
        begin
          Reported:=Max(Reported,BatchBase+Done);
          if Assigned(Progress) then Progress(Reported,BatchTotal);
        end);
      Inc(Counts.ArchiveOpens,BatchOpens);
      // Preserve every completed read, including when cancellation happened
      // while another entry in this same batch was still decoding.
      for Index:=0 to High(Readings) do
        if Readings[Index].ReadFile and Readings[Index].Ready and
           (Readings[Index].ErrorText='') then
          Cache.Store(Readings[Index].SourceKey,Readings[Index].Metadata);
      Cache.Flush;
      for Index := 0 to High(Books) do
      begin
        if Cancelled(IsCanceled) and not Readings[Index].Ready then Continue;
        Book := Books[Index];
        Inc(Counts.BooksChecked);
        if not (bpIsLocal in Book.BookProps) or (bpIsDeleted in Book.BookProps) or
          (PendingMetadataFields(Book, AllFields) = []) or
          not ((Book.GetBookFormat in [bfFb2, bfFb2Archive, bfFbd]) or IsMetadataPackage(Book.FileExt) or IsMetadataContainer(Book.FileExt)) then
          Inc(Counts.BooksSkipped)
        else
        begin
          Source.SetUpcoming(Books, Index);
          WritingPlan := False; FailureKind:=mrfSourceRead;
          try
            if not SameRoot(Book.CollectionRoot, Plan.CollectionRoot) then
              raise EReadError.Create('Папка коллекции изменилась во время проверки');
            SourceKey := Readings[Index].SourceKey;
            if SourceKey = '' then
            begin FailureKind:=mrfUnavailable; raise EReadError.Create('Исходный файл недоступен'); end;
            Reused:=Readings[Index].Reused; Metadata:=Readings[Index].Metadata;
            FailureKind:=Readings[Index].Failure;
            if Readings[Index].ReadFile then Inc(Counts.FilesRead);
            if Reused then Inc(Counts.BooksReused);
            if Readings[Index].ErrorText<>'' then raise EReadError.Create(Readings[Index].ErrorText);
            if SourceKey <> Source.GetSourceKey(Book) then
            begin FailureKind:=mrfSourceChanged; raise EReadError.Create('Файл книги изменился во время проверки'); end;
            FailureKind:=mrfLimit;
            Item := Default(TPlannedMetadata); Item.Book := Book; Item.SourceKey := SourceKey;
            Item.Values.Publisher := Metadata.Publisher; Item.Values.City := Metadata.City;
            Item.Values.PubYear := Metadata.PubYear; Item.Values.ISBN := Metadata.ISBN;
            Item.Values.Translators := Metadata.Translators; Item.Values.Annotation := Metadata.Annotation;
            Item.Fields := MissingMetadataFields(Book, Item.Values, AllFields);
            if not (msfPublisher in Item.Fields) then Item.Values.Publisher := '';
            if not (msfCity in Item.Fields) then Item.Values.City := '';
            if not (msfPubYear in Item.Fields) then Item.Values.PubYear := 0;
            if not (msfISBN in Item.Fields) then Item.Values.ISBN := '';
            if not (msfTranslators in Item.Fields) then Item.Values.Translators := '';
            if not (msfAnnotation in Item.Fields) then Item.Values.Annotation := '';
            // Optional oversized descriptions must not discard the publication fields.
            if TEncoding.UTF8.GetByteCount(Item.Values.Annotation) > METADATA_SYNC_MAX_ANNOTATION_BYTES then
            begin
              Exclude(Item.Fields,msfAnnotation); Item.Values.Annotation:=''; Inc(Counts.AnnotationsOmitted);
            end;
            if Item.Fields = [] then Inc(Counts.BooksSkipped)
            else
            begin
              Line := EncodePlanRow(Item);
              Bytes := TEncoding.UTF8.GetBytes(Line + #10);
              if (Length(Bytes)>METADATA_SYNC_MAX_RECORD_BYTES) and (msfAnnotation in Item.Fields) then
              begin
                Exclude(Item.Fields,msfAnnotation); Item.Values.Annotation:=''; Inc(Counts.AnnotationsOmitted);
                Line:=EncodePlanRow(Item); Bytes:=TEncoding.UTF8.GetBytes(Line+#10);
              end;
              if Item.Fields=[] then begin Inc(Counts.BooksSkipped); Continue; end;
              if Length(Bytes) > METADATA_SYNC_MAX_RECORD_BYTES then
                raise EReadError.Create('Сведения превышают размер строки плана; книга пропущена');
              WritingPlan := True; Spool.WriteBuffer(Bytes[0], Length(Bytes));
              WritingPlan := False; Inc(Counts.BooksPlanned);
              Inc(Plan.FMaskCounts[FieldMask(Item.Fields)]);
              for Field := Low(Field) to High(Field) do
                if Field in Item.Fields then Inc(Counts.FieldCounts[Field]);
              if msfAnnotation in Item.Fields then
                Inc(Counts.AnnotationBytes, TEncoding.UTF8.GetByteCount(Item.Values.Annotation));
            end;
          except
            on E: EOutOfMemory do raise;
            on E: EAccessViolation do raise;
            on E: EAbort do raise;
            on E: Exception do
            begin
              if WritingPlan then raise;
              if E is ENotSupportedException then FailureKind:=mrfDecoder;
              if E is EMetadataAmbiguousBook then FailureKind:=mrfAmbiguous;
              if E is EFOpenError then FailureKind:=mrfUnavailable;
              Inc(Counts.BooksFailed); Inc(Counts.ErrorCounts[FailureKind]);
              ExampleCount:=Length(Counts.ErrorExamples);
              if ExampleCount<40 then
              begin
                SetLength(Counts.ErrorExamples,ExampleCount+1);
                Counts.ErrorExamples[ExampleCount]:=Format('#%d «%s»: %s. Источник: %s',[Book.BookKey.BookID,
                  Copy(Book.Title,1,150),Copy(E.Message.Replace(#13,' ').Replace(#10,' '),1,800),
                  Copy(Book.GetBookFileName,1,1024)]);
              end;
            end;
          end;
        end;
        Reported:=Max(Reported,Counts.BooksChecked);
        if Assigned(Progress) then Progress(Reported,Counts.BooksTotal);
      end;
    end;
    if not Complete or Cancelled(IsCanceled) then Exit;
    if not SameRoot(Provider.MetadataCollectionRoot, Plan.CollectionRoot) then
      raise EReadError.Create('Папка коллекции изменилась; выполните новую проверку');
    Cache.Flush; Plan.FAvailableCounts:=Counts; Plan.SelectFields(Fields); Counts:=Plan.Counts;
    Plan.FHash := HashStream(Spool, IsCanceled);
    FreeAndNil(Spool);
    FinalName := TPath.Combine(Plan.FDirectory, 'plan.jsonl');
    if not MoveFile(PChar(Plan.FFileName), PChar(FinalName)) then RaiseLastOSError;
    Plan.FFileName := FinalName;
    Result := Plan; Plan := nil;
  except
    on E: EAbort do if not Cancelled(IsCanceled) then raise;
  end;
  finally
    if Assigned(Plan) then
    begin Plan.FAvailableCounts:=Counts; Plan.SelectFields(Fields); Counts:=Plan.Counts; end;
    try Cache.Free;
    finally Spool.Free; Source.Free; Plan.Free; end;
  end;
end;

function ApplyCollectionMetadata(const Collection: IBookCollection;
  Plan: TCollectionMetadataPlan; var Counts: TMetadataSyncCounts;
  const IsCanceled: TFunc<Boolean>; const Progress: TMetadataSyncProgress): Boolean;
var Provider: IBookMetadataFillWriter; Input: TFileStream; Lines: TStreamReader;
  Source: TPublisherSeriesSource; Pending: array[0..ChunkSize-1] of TPlannedMetadata;
  N: Integer; Line: string; Started: Boolean; Updated, EffectiveFields: TMetadataSyncFields;
  AvailableField: TMetadataSyncField;
  ChunkCounts: TMetadataSyncCounts; Outcome: TMetadataFillResult;
  CancelObserved: Boolean; CancelCheck: TFunc<Boolean>;
  procedure CommitChunk;
  var Expected: TBookRecord; SourceKey: string; I: Integer;
    Field: TMetadataSyncField; Locks: TArray<TStream>;
  begin
    if N = 0 then Exit;
    if Cancelled(CancelCheck) then Exit;
    Started := False; ChunkCounts := Default(TMetadataSyncCounts);
    SetLength(Locks,N);
    try
    try
      // File locks are held through COMMIT, not merely through a timestamp
      // comparison. No source bytes are read during this phase.
      for I := 0 to N-1 do
      begin
        if Cancelled(CancelCheck) then raise EAbort.Create('Заполнение отменено');
        try Locks[I] := Source.LockSource(Pending[I].Book);
        except on E: EOutOfMemory do raise; on E: EAccessViolation do raise;
          on E: Exception do Locks[I] := nil; end;
      end;
      Provider.BeginMetadataFillBatch; Started := True;
      for I := 0 to N-1 do
      begin
        if Cancelled(CancelCheck) then raise EAbort.Create('Заполнение отменено');
        Expected := Pending[I].Book; SourceKey := Pending[I].SourceKey;
        if Locks[I] = nil then Outcome := mfrIdentityChanged
        else Outcome := Provider.FillEmptyMetadata(Expected, Pending[I].Values,
          Pending[I].Fields, function: Boolean
          begin
            Result := not Cancelled(CancelCheck) and
              (SourceKey = Source.GetSourceKey(Expected));
          end, Updated);
        Inc(ChunkCounts.BooksChecked);
        if Outcome = mfrChanged then
        begin
          Inc(ChunkCounts.BooksPlanned);
          for Field := Low(Field) to High(Field) do
            if Field in Updated then Inc(ChunkCounts.FieldCounts[Field]);
        end else
        begin
          Inc(ChunkCounts.BooksSkipped);
          if Outcome=mfrIdentityChanged then Inc(ChunkCounts.BooksStale);
        end;
      end;
      if Cancelled(CancelCheck) then raise EAbort.Create('Заполнение отменено');
      Provider.EndMetadataFillBatch(True); Started := False;
      Inc(Counts.BooksChecked, ChunkCounts.BooksChecked);
      Inc(Counts.BooksPlanned, ChunkCounts.BooksPlanned);
      Inc(Counts.BooksSkipped, ChunkCounts.BooksSkipped);
      Inc(Counts.BooksStale,ChunkCounts.BooksStale);
      for Field := Low(Field) to High(Field) do
        Inc(Counts.FieldCounts[Field], ChunkCounts.FieldCounts[Field]);
      N := 0;
      if Assigned(Progress) then Progress(Counts.BooksChecked, Counts.BooksTotal);
    except
      if Started then
        try Provider.EndMetadataFillBatch(False); except end;
      if not Cancelled(CancelCheck) then Inc(Counts.BooksFailed);
      raise;
    end;
    finally
      for I := 0 to High(Locks) do Locks[I].Free;
    end;
  end;
begin
  Result := False; Counts := Default(TMetadataSyncCounts);
  CancelObserved := False;
  // Cancellation is an operation outcome. A rollback may undo the state that
  // made a caller's predicate true; it must not turn that observed cancellation
  // into an unexpected EAbort or a claimed failed/partially saved chunk.
  CancelCheck := function: Boolean
    begin
      if not CancelObserved and Assigned(IsCanceled) then CancelObserved := IsCanceled();
      Result := CancelObserved;
    end;
  if not Assigned(Plan) then raise EArgumentNilException.Create('Отсутствует план сведений');
  if not Assigned(Collection) or not Supports(Collection, IBookMetadataFillWriter, Provider) then
    raise ENotSupportedException.Create('Эта коллекция не поддерживает заполнение сведений');
  if (Collection.CollectionID <> Plan.CollectionID) or
    not SameRoot(Provider.MetadataCollectionRoot, Plan.CollectionRoot) then
    raise EReadError.Create('Коллекция или её папка изменилась; выполните новую проверку');
  if Collection.InBulkOperation then
    raise EInvalidOperation.Create('Другая операция меняет коллекцию; повторите позже');
  Counts.BooksTotal := Plan.Counts.BooksPlanned; N := 0; EffectiveFields:=Plan.Fields;
  for AvailableField:=Low(AvailableField) to High(AvailableField) do
    if Plan.AvailableCounts.FieldCounts[AvailableField]=0 then Exclude(EffectiveFields,AvailableField);
  Input := TFileStream.Create(Plan.FFileName, fmOpenRead or fmShareDenyWrite);
  Lines := nil; Source := nil;
  try
  try
    if HashStream(Input, CancelCheck) <> Plan.FHash then
      raise EReadError.Create('План сведений повреждён; выполните новую проверку');
    Lines := TStreamReader.Create(Input, TEncoding.UTF8, False, 4096);
    Source := TPublisherSeriesSource.Create(CancelCheck);
    try
      while not Lines.EndOfStream and not Cancelled(CancelCheck) do
      begin
        Line := Lines.ReadLine;
        Pending[N] := DecodePlanRow(Line, Plan);
        Pending[N].Fields:=Pending[N].Fields*EffectiveFields;
        if Pending[N].Fields=[] then Continue;
        Inc(N);
        if N = ChunkSize then CommitChunk;
      end;
      if Cancelled(CancelCheck) then Exit;
      CommitChunk;
      Result := not Cancelled(CancelCheck);
    except
      on E: EAbort do if not Cancelled(CancelCheck) then raise;
    end;
  except
    on E: EAbort do if not Cancelled(CancelCheck) then raise;
  end;
  finally Source.Free; Lines.Free; Input.Free; end;
end;

procedure TMetadataProgressWorker.PublishBookProgress(Checked, Total: Int64);
begin
  TInterlocked.Exchange(FBooksTotal,Total);
  TInterlocked.Exchange(FBooksChecked,Checked);
end;

procedure TMetadataProgressWorker.GetBookProgress(out Checked, Total: Int64);
begin
  Checked:=TInterlocked.CompareExchange(FBooksChecked,Int64(0),Int64(0));
  Total:=TInterlocked.CompareExchange(FBooksTotal,Int64(0),Int64(0));
end;

constructor TMetadataPreviewThread.Create(CollectionID: Integer;
  const Fields: TMetadataSyncFields);
begin inherited Create(CollectionID); FFields := Fields; end;

destructor TMetadataPreviewThread.Destroy;
begin inherited; FPlan.Free; end;

function TMetadataPreviewThread.TakePlan: TCollectionMetadataPlan;
begin
  if not Finished then raise EInvalidOperation.Create('Проверка ещё выполняется');
  Result := FPlan; FPlan := nil;
end;

procedure TMetadataPreviewThread.WorkFunction;
var LastComment: UInt64;
begin
  LastComment:=0;
  FPlan := PreviewCollectionMetadata(FCollection, FFields, FCounts,
    function: Boolean begin Result := Canceled; end,
    procedure(Checked, Total: Int64)
    begin
      PublishBookProgress(Checked,Total);
      SetProgress(Integer(Min(Int64(99), Checked * 100 div Max(Int64(1), Total))));
      if (LastComment=0) or (GetTickCount64-LastComment>=250) or (Checked=Total) then
      begin
        LastComment:=GetTickCount64;
        SetComment(Format('Проверено книг: %d из %d',[Checked,Total]));
      end;
    end);
  FCompleted := Assigned(FPlan); FOperationSuccess := FCompleted;
  if FCompleted then SetProgress(100);
end;

constructor TMetadataApplyThread.Create(Plan: TCollectionMetadataPlan);
begin
  if Plan = nil then raise EArgumentNilException.Create('Отсутствует план сведений');
  inherited Create(Plan.CollectionID); FPlan := Plan;
end;

procedure TMetadataApplyThread.WorkFunction;
begin
  try
    FCompleted := ApplyCollectionMetadata(FCollection, FPlan, FCounts,
      function: Boolean begin Result := Canceled; end,
      procedure(Checked, Total: Int64)
      begin
        FChangesCommitted := FCounts.BooksPlanned > 0;
        PublishBookProgress(Checked,Total);
        SetProgress(Integer(Min(Int64(99), Checked * 100 div Max(Int64(1), Total))));
      end);
    FOperationSuccess := FCompleted;
    if FCompleted then SetProgress(100);
  finally FChangesCommitted := FCounts.BooksPlanned > 0; end;
end;

function TMetadataApplyThread.GetBooksCommitted: Int64;
begin Result := FCounts.BooksPlanned; end;
function TMetadataApplyThread.GetBooksSkipped: Int64;
begin Result := FCounts.BooksSkipped; end;
function TMetadataApplyThread.GetBooksFailed: Int64;
begin Result := FCounts.BooksFailed; end;
function TMetadataApplyThread.GetFieldCounts: TMetadataSyncFieldCounts;
begin Result := FCounts.FieldCounts; end;

end.
