unit unit_MCP_Tools_Text;

interface

uses
  unit_MCP_Protocol;

procedure RegisterTextTools(Server: TMcpServer);

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  unit_Globals,
  unit_Interfaces,
  unit_Errors,
  unit_MCP_Json,
  unit_MCP_Tools_Library,
  unit_MCP_Fb2Extract,
  unit_MCP_TextCache;

function LoadBookForText(const Args: TJSONObject;
  out CollectionID, BookID: Integer; out Cached: TCachedBook;
  out SourceSize: Int64; out SourceStamp: TDateTime): TBookRecord;
var
  Collection: IBookCollection;
  BookKey: TBookKey;
  Book: TBookRecord;
  SourcePath: string;
  LocalCollectionID, LocalBookID: Integer;
begin
  CollectionID := RequireInt(Args, 'collection_id');
  BookID := RequireInt(Args, 'book_id');
  LocalCollectionID := CollectionID;
  LocalBookID := BookID;

  Collection := CollectionOrFail(CollectionID);

  BookKey.BookID := BookID;
  BookKey.DatabaseID := CollectionID;
  try
    Collection.GetBookRecord(BookKey, Book, False);
  except
    on E: Exception do
    begin
      LogToStderr(Format('LoadBookForText.GetBookRecord(%d): %s', [BookID, E.Message]));
      raise EMcpToolError.Create('book_not_found',
        Format('Book %d not found', [BookID]));
    end;
  end;

  if not (Book.GetBookFormat in [bfFb2, bfFb2Archive]) then
    raise EMcpToolError.Create('unsupported_format',
      Format('Text extraction supports FB2 only; this book is "%s"', [Book.FileExt]));

  SourcePath := Book.GetBookFileName;
  if not FileExists(SourcePath) then
    raise EMcpToolError.Create('file_missing',
      Format('Book file not found: %s', [SourcePath]));

  SourceSize := TFile.GetSize(SourcePath);
  SourceStamp := TFile.GetLastWriteTime(SourcePath);

  Cached := EnsureCached(CollectionID, BookID, SourceSize, SourceStamp,
    function: TFb2Extraction
    var
      Stream: TStream;
    begin
      Stream := nil;
      try
        try
          Stream := Book.GetBookStream;
        except
          on E: EBookNotFound do
          begin
            LogToStderr(Format('LoadBookForText.GetBookStream(%d/%d): %s',
              [LocalCollectionID, LocalBookID, E.Message]));
            raise EMcpToolError.Create('file_missing',
              Format('Book file not found: %s', [SourcePath]));
          end;
        end;

        if not Assigned(Stream) then
          raise EMcpToolError.Create('file_missing',
            Format('Book file not found: %s', [SourcePath]));

        try
          Result := ExtractFb2(Stream);
        except
          on E: EFb2ExtractError do
          begin
            LogToStderr(Format('LoadBookForText.ExtractFb2(%d/%d, Kind=%d): %s',
              [LocalCollectionID, LocalBookID, Ord(E.Kind), E.Message]));
            if E.Kind = eekNoText then
              raise EMcpToolError.Create('book_has_no_text',
                Format('Book %d in collection %d has no extractable text ' +
                  '(likely picture-only or an empty body)',
                  [LocalBookID, LocalCollectionID]))
            else
              raise EMcpToolError.Create('extraction_failed',
                Format('Could not extract text from book %d in collection %d',
                  [LocalBookID, LocalCollectionID]));
          end;
        end;
      finally
        Stream.Free;
      end;
    end);

  Result := Book;
end;

function GetBookToc(const Args: TJSONObject): TJSONObject;
var
  CollectionID, BookID, I: Integer;
  Cached: TCachedBook;
  SourceSize: Int64;
  SourceStamp: TDateTime;
  Arr: TJSONArray;
  Entry: TJSONObject;
begin
  LoadBookForText(Args, CollectionID, BookID, Cached, SourceSize, SourceStamp);

  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Cached.Sections) do
    begin
      Entry := TJSONObject.Create;
      try
        Entry.AddPair('title', Cached.Sections[I].Title);
        Entry.AddPair('level', TJSONNumber.Create(Cached.Sections[I].Level));
        Entry.AddPair('offset', TJSONNumber.Create(Cached.Sections[I].Offset));
        Entry.AddPair('length', TJSONNumber.Create(Cached.Sections[I].Length));
      except
        Entry.Free;
        raise;
      end;
      Arr.AddElement(Entry);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  try
    Result.AddPair('sections', Arr);
    Result.AddPair('structured', TJSONBool.Create(Cached.Structured));
    Result.AddPair('total_length', TJSONNumber.Create(Cached.TotalLength));
  except
    Result.Free;
    raise;
  end;
end;

function GetBookText(const Args: TJSONObject): TJSONObject;
var
  CollectionID, BookID, Offset, Count: Integer;
  Cached: TCachedBook;
  SourceSize: Int64;
  SourceStamp: TDateTime;
  Slice: string;
  ClampedOffset, ClampedCount: Boolean;
begin
  LoadBookForText(Args, CollectionID, BookID, Cached, SourceSize, SourceStamp);

  Offset := ArgIntClamped(Args, 'offset', 0, 0, MaxInt, ClampedOffset);
  Count := ArgIntClamped(Args, 'length', 8000, 1, 50000, ClampedCount);

  if Offset > Cached.TotalLength then
    raise EMcpToolError.Create('invalid_offset',
      Format('Offset %d is past the end of the text (total_length %d)',
        [Offset, Cached.TotalLength]));

  Slice := ReadCachedSlice(CollectionID, BookID, SourceSize, SourceStamp,
    Offset, Count);

  Result := TJSONObject.Create;
  try
    Result.AddPair('text', Slice);
    Result.AddPair('offset', TJSONNumber.Create(Offset));
    Result.AddPair('length', TJSONNumber.Create(Length(Slice)));
    Result.AddPair('total_length', TJSONNumber.Create(Cached.TotalLength));
    Result.AddPair('has_more',
      TJSONBool.Create(Offset + Length(Slice) < Cached.TotalLength));
    if ClampedOffset or ClampedCount then
      Result.AddPair('clamped', TJSONBool.Create(True));
  except
    Result.Free;
    raise;
  end;
end;

function SearchInBook(const Args: TJSONObject): TJSONObject;
var
  CollectionID, BookID, MaxHits, ContextChars, QueryLen: Integer;
  Cached: TCachedBook;
  SourceSize: Int64;
  SourceStamp: TDateTime;
  FullText, LowerText, Query, LowerQuery, Passage: string;
  Arr: TJSONArray;
  Entry: TJSONObject;
  SearchFrom, FoundPos, MatchOffset, TotalHits, PassageStart, PassageLen: Integer;
  ClampedHits, ClampedContext: Boolean;
begin
  Query := ArgStr(Args, 'query');
  if Query = '' then
    raise EMcpToolError.Create('invalid_params', 'Missing required argument: query');

  LoadBookForText(Args, CollectionID, BookID, Cached, SourceSize, SourceStamp);

  MaxHits := ArgIntClamped(Args, 'max_hits', 10, 1, 50, ClampedHits);
  ContextChars := ArgIntClamped(Args, 'context_chars', 200, 0, 2000, ClampedContext);

  FullText := ReadCachedSlice(CollectionID, BookID, SourceSize, SourceStamp,
    0, Cached.TotalLength);

  QueryLen := Length(Query);
  LowerText := FullText.ToLower;
  LowerQuery := Query.ToLower;

  Arr := TJSONArray.Create;
  try
    TotalHits := 0;
    SearchFrom := 1;
    FoundPos := Pos(LowerQuery, LowerText, SearchFrom);
    while FoundPos > 0 do
    begin
      Inc(TotalHits);
      if TotalHits <= MaxHits then
      begin
        MatchOffset := FoundPos - 1;

        PassageStart := FoundPos - ContextChars;
        if PassageStart < 1 then
          PassageStart := 1;

        PassageLen := (FoundPos - PassageStart) + QueryLen + ContextChars;
        if PassageStart + PassageLen - 1 > Length(FullText) then
          PassageLen := Length(FullText) - PassageStart + 1;

        Passage := Copy(FullText, PassageStart, PassageLen);

        Entry := TJSONObject.Create;
        try
          Entry.AddPair('offset', TJSONNumber.Create(MatchOffset));
          Entry.AddPair('passage', Passage);
        except
          Entry.Free;
          raise;
        end;
        Arr.AddElement(Entry);
      end;

      SearchFrom := FoundPos + QueryLen;
      FoundPos := Pos(LowerQuery, LowerText, SearchFrom);
    end;
  except
    Arr.Free;
    raise;
  end;

  Result := TJSONObject.Create;
  try
    Result.AddPair('hits', Arr);
    Result.AddPair('total_hits', TJSONNumber.Create(TotalHits));
    if ClampedHits or ClampedContext then
      Result.AddPair('clamped', TJSONBool.Create(True));
  except
    Result.Free;
    raise;
  end;
end;

procedure RegisterTextTools(Server: TMcpServer);
begin
  Server.RegisterTool(
    'get_book_toc',
    'Содержание книги FB2: разделы с их смещениями для get_book_text.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"book_id":{"type":"integer"}},' +
      '"required":["collection_id","book_id"]}') as TJSONObject,
    Guarded(GetBookToc));

  Server.RegisterTool(
    'get_book_text',
    'Фрагмент текста книги FB2 от заданного смещения.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"book_id":{"type":"integer"},' +
      '"offset":{"type":"integer","description":"По умолчанию 0"},' +
      '"length":{"type":"integer","description":"По умолчанию 8000, максимум 50000"}},' +
      '"required":["collection_id","book_id"]}') as TJSONObject,
    Guarded(GetBookText));

  Server.RegisterTool(
    'search_in_book',
    'Поиск фрагментов в тексте книги FB2 с определением их смещений.',
    TJSONObject.ParseJSONValue(
      '{"type":"object","properties":{' +
      '"collection_id":{"type":"integer"},' +
      '"book_id":{"type":"integer"},' +
      '"query":{"type":"string"},' +
      '"max_hits":{"type":"integer","description":"По умолчанию 10, максимум 50"},' +
      '"context_chars":{"type":"integer","description":"По умолчанию 200, максимум 2000"}},' +
      '"required":["collection_id","book_id","query"]}') as TJSONObject,
    Guarded(SearchInBook));
end;

end.
