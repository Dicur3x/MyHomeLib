unit unit_FB2PublisherMetadataReader;

interface

uses
  System.Classes,
  System.SysUtils,
  Winapi.MSXML,
  unit_FB2Utils;

const
  FB2_METADATA_MAX_BYTES = 16 * 1024 * 1024;
  FB2_METADATA_MAX_DEPTH = 256;

type
  TFB2MetadataStatus = (fmsComplete, fmsInvalid, fmsCanceled, fmsNoMetadata);

  TFB2CatalogMetadata = record
    Publisher, City, ISBN, Translators, Annotation: string;
    PubYear: Integer;
  end;

  // Create, reuse and destroy on one COM-initialized thread. Streams are borrowed.
  TFB2PublisherMetadataReader = class
  private
    FReader: ISAXXMLReader;
    FHandler: IInterface;
    FHandlerObject: TObject;
    FLastRecoveryDetails: string;
    FLastPublisher: string;
    FLastMetadata: TFB2CatalogMetadata;
    FCaptureMetadata, FCaptureAnnotation: Boolean;
    function ReadStrict(Stream: TStream; out Series: TFB2PublisherSeries;
      out ErrorText: string; const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
  public
    constructor Create;
    destructor Destroy; override;
    // Reads from the current position without seeking. Only Complete can replace
    // stored metadata; all other statuses return an empty Series array.
    function Read(Stream: TStream; out Series: TFB2PublisherSeries;
      out ErrorText: string;
      const IsCanceled: TFunc<Boolean> = nil): TFB2MetadataStatus;
    function ReadCatalogMetadata(Stream: TStream; out Metadata: TFB2CatalogMetadata;
      out ErrorText: string; const CaptureAnnotation: Boolean = False;
      const IsCanceled: TFunc<Boolean> = nil): TFB2MetadataStatus;
    property LastRecoveryDetails: string read FLastRecoveryDetails;
    // Available only after a complete, bounded metadata read.
    property LastPublisher: string read FLastPublisher;
  end;

implementation

uses
  System.Generics.Collections,
  System.Math,
  System.Variants,
  System.Win.ComObj,
  Winapi.Windows,
  Winapi.ActiveX,
  unit_FB2MetadataRecovery;

const
  FB2_NAMESPACE = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  FB2_NAMESPACE_21 = 'http://www.gribuser.ru/xml/fictionbook/2.1';
  FB2_NAMESPACE_22 = 'http://www.gribuser.ru/xml/fictionbook/2.2';
  FB2_NAMESPACE_201 = 'http://www.gribuser.ru/xml/fictionbook/2.01';
  INPUT_BUFFER_SIZE = 8192;

type
  TMetadataHandler = class(TInterfacedObject, ISAXContentHandler, ISAXErrorHandler)
  private
    FItems: TList<TFB2PublisherSeriesItem>;
    FCancel: TFunc<Boolean>;
    FException: Exception;
    FError: string;
    FNamespace: string;
    FDescriptionNamespace: string;
    FDepth: Integer;
    FHasTitleInfo: Boolean;
    FInDescription: Boolean;
    FInPublishInfo: Boolean;
    FSequencePath: array[0..FB2_METADATA_MAX_DEPTH] of Boolean;
    FComplete: Boolean;
    FCanceled: Boolean;
    FNoMetadata: Boolean;
    FPublisher, FPublisherText: string;
    FPublisherDepth: Integer;
    FMetadata: TFB2CatalogMetadata;
    FCaptureMetadata, FCaptureAnnotation, FInTitleInfo: Boolean;
    FValueDepth, FAnnotationDepth, FTranslatorDepth, FForeignDepth: Integer;
    FValueName, FValueText, FFirstName, FMiddleName, FLastName, FNickName: string;
    function FinishValue: HResult;
    function CheckContinue: HResult;
    function Invalid(const MessageText: string): HResult;
    function CaptureException: HResult;
    function Attribute(const Attributes: ISAXAttributes; const Name: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(const IsCanceled: TFunc<Boolean>;
      CaptureMetadata, CaptureAnnotation: Boolean);
    procedure RaiseCapturedException;
    function putDocumentLocator(const pLocator: ISAXLocator): HResult; stdcall;
    function startDocument: HResult; stdcall;
    function endDocument: HResult; stdcall;
    function startPrefixMapping(var pwchPrefix: Word; cchPrefix: Integer;
      var pwchUri: Word; cchUri: Integer): HResult; stdcall;
    function endPrefixMapping(var pwchPrefix: Word; cchPrefix: Integer): HResult; stdcall;
    function startElement(var pwchNamespaceUri: Word; cchNamespaceUri: Integer;
      var pwchLocalName: Word; cchLocalName: Integer; var pwchQName: Word;
      cchQName: Integer; const pAttributes: ISAXAttributes): HResult; stdcall;
    function endElement(var pwchNamespaceUri: Word; cchNamespaceUri: Integer;
      var pwchLocalName: Word; cchLocalName: Integer; var pwchQName: Word;
      cchQName: Integer): HResult; stdcall;
    function characters(var pwchChars: Word; cchChars: Integer): HResult; stdcall;
    function ignorableWhitespace(var pwchChars: Word; cchChars: Integer): HResult; stdcall;
    function processingInstruction(var pwchTarget: Word; cchTarget: Integer;
      var pwchData: Word; cchData: Integer): HResult; stdcall;
    function skippedEntity(var pwchName: Word; cchName: Integer): HResult; stdcall;
    function error(const pLocator: ISAXLocator; var pwchErrorMessage: Word;
      hrErrorCode: HResult): HResult; stdcall;
    function fatalError(const pLocator: ISAXLocator; var pwchErrorMessage: Word;
      hrErrorCode: HResult): HResult; stdcall;
    function ignorableWarning(const pLocator: ISAXLocator; var pwchErrorMessage: Word;
      hrErrorCode: HResult): HResult; stdcall;
  end;

  TMetadataInput = class(TInterfacedObject, ISequentialStream)
  private
    FStream: TStream;
    FHandler: TMetadataHandler;
    FBuffer: array[0..INPUT_BUFFER_SIZE - 1] of Byte;
    FPosition: Integer;
    FCount: Integer;
    FBytesRead: Integer;
    FAfterGreater: Boolean;
  public
    constructor Create(Stream: TStream; Handler: TMetadataHandler);
    function Prepare(out Charset: string): HResult;
    function Read(pv: Pointer; cb: FixedUInt; pcbRead: PFixedUInt): HResult; stdcall;
    function Write(pv: Pointer; cb: FixedUInt; pcbWritten: PFixedUInt): HResult; stdcall;
  end;

function SAXText(Value: PWideChar; Count: Integer): string;
begin
  SetString(Result, Value, Count);
end;

function IsFB2Namespace(const Value: string): Boolean;
begin
  Result := (Value = '') or (Value = FB2_NAMESPACE) or
    (Value = FB2_NAMESPACE_21) or (Value = FB2_NAMESPACE_22) or
    (Value = FB2_NAMESPACE_201);
end;

constructor TMetadataHandler.Create;
begin
  inherited;
  FItems := TList<TFB2PublisherSeriesItem>.Create;
end;

destructor TMetadataHandler.Destroy;
begin
  FItems.Free;
  FException.Free;
  inherited;
end;

procedure TMetadataHandler.Reset(const IsCanceled: TFunc<Boolean>;
  CaptureMetadata, CaptureAnnotation: Boolean);
begin
  FItems.Clear;
  FCancel := IsCanceled;
  FreeAndNil(FException);
  FError := '';
  FNamespace := '';
  FDescriptionNamespace := '';
  FDepth := 0;
  FHasTitleInfo := False;
  FInDescription := False;
  FInPublishInfo := False;
  FComplete := False;
  FCanceled := False;
  FNoMetadata := False;
  FPublisher := '';
  FPublisherText := '';
  FPublisherDepth := 0;
  FMetadata := Default(TFB2CatalogMetadata);
  FCaptureMetadata := CaptureMetadata;
  FCaptureAnnotation := CaptureAnnotation;
  FInTitleInfo := False;
  FValueDepth := 0; FAnnotationDepth := 0; FTranslatorDepth := 0;
  FForeignDepth := 0; FValueName := ''; FValueText := '';
  FFirstName := ''; FMiddleName := ''; FLastName := ''; FNickName := '';
  FillChar(FSequencePath, SizeOf(FSequencePath), 0);
end;

function TMetadataHandler.CaptureException: HResult;
begin
  if FException = nil then
    FException := Exception(AcquireExceptionObject);
  Result := E_FAIL;
end;

procedure TMetadataHandler.RaiseCapturedException;
var
  E: Exception;
begin
  if FException <> nil then
  begin
    E := FException;
    FException := nil;
    raise E;
  end;
end;

function TMetadataHandler.CheckContinue: HResult;
begin
  try
    if Assigned(FCancel) and FCancel() then
      FCanceled := True;
    if FCanceled or FComplete or FNoMetadata or (FError <> '') or (FException <> nil) then
      Result := E_ABORT
    else
      Result := S_OK;
  except
    Result := CaptureException;
  end;
end;

function TMetadataHandler.Invalid(const MessageText: string): HResult;
begin
  if FError = '' then
    FError := MessageText;
  Result := E_FAIL;
end;

function TMetadataHandler.Attribute(const Attributes: ISAXAttributes;
  const Name: string): string;
var
  I, Count, TextLength: Integer;
  Text: PWord1;
begin
  Result := '';
  OleCheck(Attributes.getLength(Count));
  for I := 0 to Count - 1 do
  begin
    OleCheck(Attributes.getURI(I, Text, TextLength));
    if TextLength <> 0 then
      Continue;
    OleCheck(Attributes.getLocalName(I, Text, TextLength));
    if SAXText(PWideChar(Text), TextLength) <> Name then
      Continue;
    OleCheck(Attributes.getValue(I, Text, TextLength));
    Exit(SAXText(PWideChar(Text), TextLength));
  end;
end;

function TMetadataHandler.FinishValue: HResult;
var Value: string; Target: PString; Year: Integer;
begin
  Result := S_OK; Value := Trim(FValueText); Target := nil;
  if FValueName = 'city' then Target := @FMetadata.City
  else if FValueName = 'isbn' then Target := @FMetadata.ISBN
  else if FValueName = 'first-name' then Target := @FFirstName
  else if FValueName = 'middle-name' then Target := @FMiddleName
  else if FValueName = 'last-name' then Target := @FLastName
  else if FValueName = 'nickname' then Target := @FNickName
  else if FValueName = 'year' then
  begin
    if TryStrToInt(Value, Year) and (Year > 0) and (Year <= 9999) then
    begin
      if (FMetadata.PubYear <> 0) and (FMetadata.PubYear <> Year) then
        Exit(Invalid('В описании FB2 указаны разные годы издания.'));
      FMetadata.PubYear := Year;
    end;
  end;
  if Assigned(Target) and (Value <> '') then
  begin
    if (Target^ <> '') and (Target^ <> Value) then
      Exit(Invalid('В описании FB2 указаны разные значения ' + FValueName));
    Target^ := Value;
  end;
  FValueDepth := 0; FValueName := ''; FValueText := '';
end;

function TMetadataHandler.startElement(var pwchNamespaceUri: Word;
  cchNamespaceUri: Integer; var pwchLocalName: Word; cchLocalName: Integer;
  var pwchQName: Word; cchQName: Integer; const pAttributes: ISAXAttributes): HResult;
var
  Namespace, Name: string;
  Item: TFB2PublisherSeriesItem;
begin
  try
    Result := CheckContinue;
    if Failed(Result) then
      Exit;
    Inc(FDepth);
    if FDepth > FB2_METADATA_MAX_DEPTH then
      Exit(Invalid('FB2 metadata exceeds the maximum XML depth'));
    FSequencePath[FDepth] := False;
    Namespace := SAXText(PWideChar(@pwchNamespaceUri), cchNamespaceUri);
    Name := SAXText(PWideChar(@pwchLocalName), cchLocalName);
    if FCaptureMetadata and (FValueDepth > 0) and (FDepth > FValueDepth) then
      Exit(Invalid('Поле FB2 содержит вложенный элемент: ' + FValueName));
    if FCaptureMetadata and (FAnnotationDepth > 0) and
      (Namespace <> FDescriptionNamespace) and (Namespace <> '') and
      (FForeignDepth = 0) then FForeignDepth := FDepth;
    if (FPublisherDepth > 0) and (FDepth > FPublisherDepth) then
      Exit(Invalid('Издательство FB2 содержит вложенный элемент; метаданные не сохранены.'));
    if FDepth = 1 then
    begin
      if (Name <> 'FictionBook') or
        not IsFB2Namespace(Namespace) then
        Exit(Invalid('Неверный корневой элемент FB2 или пространство имён: ' + Name + ' (' + Namespace + ')'));
      FNamespace := Namespace;
    end
    else if FDepth = 2 then
    begin
      if Name = 'description' then
      begin
        if not IsFB2Namespace(Namespace) then
          Exit(Invalid('Неизвестное пространство имён description: ' + Namespace));
        FInDescription := True;
        FDescriptionNamespace := Namespace;
      end
      else if ((Namespace = FNamespace) or (Namespace = '')) and
        (Name = 'body') then
      begin
        FNoMetadata := True;
        Exit(E_ABORT);
      end;
      // Some converters put binary images before description. SAX skips them
      // within the same prefix/depth limits and continues to the metadata.
    end
    else if FInDescription and ((Namespace = FDescriptionNamespace) or (Namespace = '')) then
    begin
      if FDepth = 3 then
      begin
        if Name = 'title-info' then
          FHasTitleInfo := True;
        FInPublishInfo := Name = 'publish-info';
        FInTitleInfo := Name = 'title-info';
      end
      else if FInPublishInfo and (FDepth = 4) and (Name = 'publisher') then
      begin
        FPublisherDepth := FDepth;
        FPublisherText := '';
      end
      else if FCaptureMetadata and FInPublishInfo and (FDepth = 4) and
        ((Name = 'city') or (Name = 'year') or (Name = 'isbn')) then
      begin
        FValueDepth := FDepth; FValueName := Name; FValueText := '';
      end
      else if FCaptureMetadata and FInTitleInfo and (FDepth = 4) then
      begin
        if (Name = 'annotation') and FCaptureAnnotation then
          FAnnotationDepth := FDepth
        else if Name = 'translator' then
        begin
          FTranslatorDepth := FDepth;
          FFirstName := ''; FMiddleName := ''; FLastName := ''; FNickName := '';
        end;
      end
      else if FCaptureMetadata and (FTranslatorDepth > 0) and
        (FDepth = FTranslatorDepth + 1) and
        ((Name = 'first-name') or (Name = 'middle-name') or
         (Name = 'last-name') or (Name = 'nickname')) then
      begin
        FValueDepth := FDepth; FValueName := Name; FValueText := '';
      end
      else if FInPublishInfo and (Name = 'sequence') and
        ((FDepth = 4) or FSequencePath[FDepth - 1]) then
      begin
        FSequencePath[FDepth] := True;
        Item.Title := Trim(Attribute(pAttributes, 'name'));
        if Item.Title <> '' then
        begin
          if not TryStrToInt(Attribute(pAttributes, 'number'), Item.Number) or
            (Item.Number < 0) then
            Item.Number := 0;
          FItems.Add(Item);
        end;
      end;
    end;
    Result := S_OK;
  except
    Result := CaptureException;
  end;
end;

function TMetadataHandler.endElement(var pwchNamespaceUri: Word;
  cchNamespaceUri: Integer; var pwchLocalName: Word; cchLocalName: Integer;
  var pwchQName: Word; cchQName: Integer): HResult;
var Name, Person: string;
begin
  try
    Result := CheckContinue;
    if Failed(Result) then
      Exit;
    Name := SAXText(PWideChar(@pwchLocalName), cchLocalName);
    if FCaptureMetadata then
    begin
      if (FValueDepth > 0) and (FDepth = FValueDepth) then
      begin
        Result := FinishValue;
        if Failed(Result) then Exit;
      end;
      if (FAnnotationDepth > 0) and (FForeignDepth = 0) and
        ((Name = 'p') or (Name = 'empty-line')) then
      begin
        if Length(FMetadata.Annotation) > 65534 then
          Exit(Invalid('Аннотация FB2 превышает допустимый размер.'));
        FMetadata.Annotation := FMetadata.Annotation + #13#10;
      end;
      if (FForeignDepth > 0) and (FDepth = FForeignDepth) then FForeignDepth := 0;
      if (FAnnotationDepth > 0) and (FDepth = FAnnotationDepth) then
      begin
        FMetadata.Annotation := Trim(FMetadata.Annotation);
        FAnnotationDepth := 0;
      end;
      if (FTranslatorDepth > 0) and (FDepth = FTranslatorDepth) then
      begin
        Person := FormatName(FLastName, FFirstName, FMiddleName, FNickName);
        if Person <> '' then
        begin
          if FMetadata.Translators <> '' then Person := '; ' + Person;
          if Length(FMetadata.Translators) + Length(Person) > 4096 then
            Exit(Invalid('Список переводчиков FB2 превышает 4096 знаков.'));
          FMetadata.Translators := FMetadata.Translators + Person;
        end;
        FTranslatorDepth := 0;
      end;
    end;
    if (FPublisherDepth > 0) and (FDepth = FPublisherDepth) then
    begin
      if (FPublisher <> '') and (Trim(FPublisherText) <> '') and
        (FPublisher <> Trim(FPublisherText)) then
        Exit(Invalid('В описании FB2 указаны разные издательства; метаданные не сохранены.'));
      if Trim(FPublisherText) <> '' then FPublisher := Trim(FPublisherText);
      FPublisherText := '';
      FPublisherDepth := 0;
    end;
    if (FDepth = 2) and FInDescription then
    begin
      if not FHasTitleInfo then
        Exit(Invalid('В описании FB2 отсутствует title-info'));
      // This deliberate SAX abort is success. The body is never XML-parsed.
      FComplete := True;
      Exit(E_ABORT);
    end;
    if FDepth = 3 then
    begin
      FInPublishInfo := False;
      FInTitleInfo := False;
    end;
    if (FDepth = 1) and not FInDescription then
    begin
      FNoMetadata := True;
      Exit(E_ABORT);
    end;
    Dec(FDepth);
    Result := S_OK;
  except
    Result := CaptureException;
  end;
end;

function TMetadataHandler.putDocumentLocator(const pLocator: ISAXLocator): HResult;
begin
  Result := CheckContinue;
end;

function TMetadataHandler.startDocument: HResult;
begin
  Result := CheckContinue;
end;

function TMetadataHandler.endDocument: HResult;
begin
  Result := Invalid('Описание FB2 не завершено или не распознано');
end;

function TMetadataHandler.startPrefixMapping(var pwchPrefix: Word;
  cchPrefix: Integer; var pwchUri: Word; cchUri: Integer): HResult;
begin
  Result := CheckContinue;
end;

function TMetadataHandler.endPrefixMapping(var pwchPrefix: Word;
  cchPrefix: Integer): HResult;
begin
  Result := CheckContinue;
end;

function TMetadataHandler.characters(var pwchChars: Word; cchChars: Integer): HResult;
begin
  try
    Result := CheckContinue;
    if Failed(Result) then Exit;
    if FCaptureMetadata then
    begin
      if FValueDepth > 0 then
      begin
        if (cchChars < 0) or (cchChars > 4096 - Length(FValueText)) then
          Exit(Invalid('Поле FB2 превышает 4096 знаков: ' + FValueName));
        FValueText := FValueText + SAXText(PWideChar(@pwchChars), cchChars);
      end;
      if (FAnnotationDepth > 0) and (FForeignDepth = 0) then
      begin
        if (cchChars < 0) or (cchChars > 65536 - Length(FMetadata.Annotation)) then
          Exit(Invalid('Аннотация FB2 превышает допустимый размер.'));
        FMetadata.Annotation := FMetadata.Annotation + SAXText(PWideChar(@pwchChars), cchChars);
      end;
    end;
    if FPublisherDepth > 0 then
    begin
      if (cchChars < 0) or (cchChars > 4096 - Length(FPublisherText)) then
        Exit(Invalid('Название издательства FB2 превышает 4096 знаков.'));
      FPublisherText := FPublisherText + SAXText(PWideChar(@pwchChars), cchChars);
    end;
  except
    Result := CaptureException;
  end;
end;

function TMetadataHandler.ignorableWhitespace(var pwchChars: Word;
  cchChars: Integer): HResult;
begin
  Result := characters(pwchChars, cchChars);
end;

function TMetadataHandler.processingInstruction(var pwchTarget: Word;
  cchTarget: Integer; var pwchData: Word; cchData: Integer): HResult;
begin
  Result := CheckContinue;
end;

function TMetadataHandler.skippedEntity(var pwchName: Word;
  cchName: Integer): HResult;
begin
  Result := Invalid('Unresolved XML entity in FictionBook metadata');
end;

function TMetadataHandler.error(const pLocator: ISAXLocator;
  var pwchErrorMessage: Word; hrErrorCode: HResult): HResult;
begin
  try
    if not FComplete and not FCanceled and (FError = '') then
      FError := PWideChar(@pwchErrorMessage);
    Result := E_FAIL;
  except
    Result := CaptureException;
  end;
end;

function TMetadataHandler.fatalError(const pLocator: ISAXLocator;
  var pwchErrorMessage: Word; hrErrorCode: HResult): HResult;
begin
  Result := error(pLocator, pwchErrorMessage, hrErrorCode);
end;

function TMetadataHandler.ignorableWarning(const pLocator: ISAXLocator;
  var pwchErrorMessage: Word; hrErrorCode: HResult): HResult;
begin
  Result := CheckContinue;
end;

constructor TMetadataInput.Create(Stream: TStream; Handler: TMetadataHandler);
begin
  inherited Create;
  FStream := Stream;
  FHandler := Handler;
end;

function TMetadataInput.Prepare(out Charset: string): HResult;
var
  Count, HeaderEnd, I, Start: Integer;
  Header, EncodingName: string;
  HeaderBytes: AnsiString;
  Quote: Char;
begin
  Charset := '';
  try
    // Retain the first buffer for non-seekable archive streams. A BOM is more
    // reliable than the contradictory XML declaration found in some FB2 files.
    repeat
      Result := FHandler.CheckContinue;
      if Failed(Result) then
        Exit;
      Count := FStream.Read(FBuffer[FCount], Length(FBuffer) - FCount);
      Inc(FCount, Count);
      Inc(FBytesRead, Count);
    until (FCount >= 4) or (Count = 0);
    if FCount >= 4 then
    begin
      if (FBuffer[0] = $FF) and (FBuffer[1] = $FE) and
        ((FBuffer[2] <> 0) or (FBuffer[3] <> 0)) then
        Charset := 'UTF-16'
      else if (FBuffer[0] = $FE) and (FBuffer[1] = $FF) then
        Charset := 'unicodeFFFE'
      else if (FBuffer[0] = $EF) and (FBuffer[1] = $BB) and
        (FBuffer[2] = $BF) then
        Charset := 'UTF-8';
    end;
    if (Charset = '') and (FCount >= 4) and
      (FBuffer[0] = Ord('<')) and (FBuffer[1] = Ord('?')) and
      (FBuffer[2] = Ord('x')) and (FBuffer[3] = Ord('m')) then
    begin
      // Some converters spell UTF-8 as UTF8. Read only the declaration, retain
      // every byte for SAX and normalize this unambiguous alias, without guessing
      // unknown encodings or seeking a non-seekable archive member.
      repeat
        SetString(HeaderBytes, PAnsiChar(@FBuffer[0]), Min(FCount, 1024));
        Header := string(HeaderBytes);
        HeaderEnd := Pos('?>', Header);
        if (HeaderEnd > 0) or (FCount >= 1024) then Break;
        Result := FHandler.CheckContinue;
        if Failed(Result) then Exit;
        Count := FStream.Read(FBuffer[FCount], 1024 - FCount);
        Inc(FCount, Count);
        Inc(FBytesRead, Count);
      until Count = 0;
      if (HeaderEnd > 0) and (Copy(Header, 1, 5) = '<?xml') then
      begin
        I := Pos('encoding', Copy(Header, 1, HeaderEnd));
        if (I > 5) and CharInSet(Header[I - 1], [#9, #10, #13, ' ']) then
        begin
          Inc(I, Length('encoding'));
          while (I < HeaderEnd) and CharInSet(Header[I], [#9, #10, #13, ' ']) do Inc(I);
          if (I < HeaderEnd) and (Header[I] = '=') then
          begin
            Inc(I);
            while (I < HeaderEnd) and CharInSet(Header[I], [#9, #10, #13, ' ']) do Inc(I);
            if (I < HeaderEnd) and CharInSet(Header[I], ['"', '''']) then
            begin
              Quote := Header[I];
              Inc(I);
              Start := I;
              while (I < HeaderEnd) and (Header[I] <> Quote) do Inc(I);
              EncodingName := Copy(Header, Start, I - Start);
              if (I < HeaderEnd) and SameText(EncodingName, 'UTF8') then
                Charset := 'UTF-8';
            end;
          end;
        end;
      end;
    end;
    Result := S_OK;
  except
    on E: EStreamError do
      Result := FHandler.Invalid(E.Message);
    else
      Result := FHandler.CaptureException;
  end;
end;

function TMetadataInput.Read(pv: Pointer; cb: FixedUInt; pcbRead: PFixedUInt): HResult;
var
  Count, I, Limit: Integer;
begin
  if pcbRead <> nil then
    pcbRead^ := 0;
  if (cb > 0) and (pv = nil) then
    Exit(E_INVALIDARG);
  if cb = 0 then
    Exit(S_OK);
  try
    Result := FHandler.CheckContinue;
    if Failed(Result) then
      Exit;
    if FPosition = FCount then
    begin
      Limit := FB2_METADATA_MAX_BYTES - FBytesRead;
      if Limit <= 0 then
        Exit(FHandler.Invalid('FB2 metadata exceeds the 16 MiB prefix limit'));
      if Limit > Length(FBuffer) then
        Limit := Length(FBuffer);
      FCount := FStream.Read(FBuffer, Limit);
      FPosition := 0;
      Inc(FBytesRead, FCount);
      if FCount = 0 then
        Exit(S_FALSE);
    end;
    Count := FCount - FPosition;
    if LongWord(Count) > cb then
      Count := cb;
    // Delimit input chunks, not XML tokens. The native parser still handles all
    // XML syntax. This prevents decoding damaged body bytes before the closing
    // description callback. A separate byte after '>' also covers UTF-16 LE.
    if FAfterGreater then
      Count := 1
    else
      for I := 0 to Count - 1 do
        if FBuffer[FPosition + I] = Ord('>') then
        begin
          Count := I + 1;
          Break;
        end;
    FAfterGreater := FBuffer[FPosition + Count - 1] = Ord('>');
    Move(FBuffer[FPosition], pv^, Count);
    Inc(FPosition, Count);
    if pcbRead <> nil then
      pcbRead^ := Count;
    Result := S_OK;
  except
    on E: EStreamError do
      Result := FHandler.Invalid(E.Message);
    else
      Result := FHandler.CaptureException;
  end;
end;

function TMetadataInput.Write(pv: Pointer; cb: FixedUInt; pcbWritten: PFixedUInt): HResult;
begin
  if pcbWritten <> nil then
    pcbWritten^ := 0;
  Result := STG_E_ACCESSDENIED;
end;

constructor TFB2PublisherMetadataReader.Create;
var
  Handler: TMetadataHandler;

  procedure Feature(const Name: string; Value: Boolean);
  begin
    OleCheck(FReader.putFeature(PWord(PWideChar(Name))^, Value));
  end;

  procedure PropertyValue(const Name: string; Value: OleVariant);
  begin
    OleCheck(FReader.putProperty(PWord(PWideChar(Name))^, Value));
  end;

begin
  inherited;
  FReader := CoSAXXMLReader60.Create as ISAXXMLReader;
  Feature('prohibit-dtd', True);
  Feature('schema-validation', False);
  Feature('use-schema-location', False);
  Feature('use-inline-schema', False);
  Feature('http://xml.org/sax/features/namespaces', True);
  Feature('http://xml.org/sax/features/external-general-entities', False);
  Feature('http://xml.org/sax/features/external-parameter-entities', False);
  PropertyValue('max-element-depth', FB2_METADATA_MAX_DEPTH);
  Handler := TMetadataHandler.Create;
  FHandler := Handler;
  FHandlerObject := Handler;
  OleCheck(FReader.putContentHandler(Handler));
  OleCheck(FReader.putErrorHandler(Handler));
end;

destructor TFB2PublisherMetadataReader.Destroy;
begin
  FReader := nil;
  FHandler := nil;
  inherited;
end;

function TFB2PublisherMetadataReader.ReadStrict(Stream: TStream;
  out Series: TFB2PublisherSeries; out ErrorText: string;
  const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
var
  Handler: TMetadataHandler;
  Input: ISequentialStream;
  InputObject: TMetadataInput;
  Charset: string;
  Value: OleVariant;
  ParseResult: HResult;
begin
  Series := nil;
  FLastPublisher := '';
  FLastMetadata := Default(TFB2CatalogMetadata);
  ErrorText := '';
  if Stream = nil then
  begin
    ErrorText := 'Missing FictionBook input stream';
    Exit(fmsInvalid);
  end;
  Handler := TMetadataHandler(FHandlerObject);
  Handler.Reset(IsCanceled, FCaptureMetadata, FCaptureAnnotation);
  try
    InputObject := TMetadataInput.Create(Stream, Handler);
    Input := InputObject;
    ParseResult := InputObject.Prepare(Charset);
    if Succeeded(ParseResult) then
    begin
      // Always reset the override: this reader is reused for differently
      // encoded books. An empty BSTR restores MSXML's normal auto-detection.
      Value := Charset;
      OleCheck(FReader.putProperty(PWord(PWideChar('charset'))^, Value));
      Value := IUnknown(Input);
      ParseResult := FReader.parse(Value);
    end;
    Handler.RaiseCapturedException;
    if Handler.FCanceled then
      Exit(fmsCanceled);
    if Handler.FComplete then
    begin
      Series := Handler.FItems.ToArray;
      FLastPublisher := Handler.FPublisher;
      FLastMetadata := Handler.FMetadata;
      FLastMetadata.Publisher := Handler.FPublisher;
      Exit(fmsComplete);
    end;
    if Handler.FNoMetadata then Exit(fmsNoMetadata);
    ErrorText := Handler.FError;
    if ErrorText = '' then
      ErrorText := Format('Incomplete FictionBook metadata (HRESULT %.8x)',
        [Cardinal(ParseResult)]);
    Result := fmsInvalid;
  finally
    Handler.FCancel := nil;
  end;
end;

function TFB2PublisherMetadataReader.Read(Stream: TStream;
  out Series: TFB2PublisherSeries; out ErrorText: string;
  const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
var
  Recorded: TRecordedMetadataStream;
  Repaired: TStringStream;
  XML, Details, RetryError: string;
  RetryStatus: TFB2MetadataStatus;
  WasCanceled: Boolean;
begin
  FLastRecoveryDetails := '';
  FLastPublisher := '';
  FLastMetadata := Default(TFB2CatalogMetadata);
  if Stream = nil then
    Exit(ReadStrict(nil, Series, ErrorText, IsCanceled));
  Recorded := TRecordedMetadataStream.Create(Stream, FB2_METADATA_MAX_BYTES);
  try
    Result := ReadStrict(Recorded, Series, ErrorText, IsCanceled);
    if Result <> fmsInvalid then Exit;
    if Recorded.Captured.Size = 0 then
    begin
      if not Recorded.ReadFailed then ErrorText := 'Пустой файл книги';
      Exit;
    end;
    // Never bypass the parser's resource limits by repairing excessive nesting.
    if (TMetadataHandler(FHandlerObject).FDepth > FB2_METADATA_MAX_DEPTH) or
      (Pos('maximum XML depth', ErrorText) > 0) then Exit;
    try
      WasCanceled := False;
      if not RecoverMetadataPrefix(Recorded, FB2_METADATA_MAX_BYTES,
        FB2_METADATA_MAX_DEPTH, IsCanceled, XML, Details, WasCanceled) then
      begin
        if WasCanceled then Result := fmsCanceled;
        Exit;
      end;
    except
      on E: EStreamError do Exit; // Retain the original diagnostic and metadata.
    end;
    begin
      Repaired := TStringStream.Create(XML, TEncoding.UTF8);
      try
        RetryStatus := ReadStrict(Repaired, Series, RetryError, IsCanceled);
        if RetryStatus = fmsComplete then
        begin
          Result := RetryStatus;
          ErrorText := '';
          FLastRecoveryDetails := Details;
        end
        else if RetryStatus = fmsCanceled then
          Result := fmsCanceled;
      finally
        Repaired.Free;
      end;
    end;
  finally
    Recorded.Free;
  end;
end;

function TFB2PublisherMetadataReader.ReadCatalogMetadata(Stream: TStream;
  out Metadata: TFB2CatalogMetadata; out ErrorText: string;
  const CaptureAnnotation: Boolean; const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
var Series: TFB2PublisherSeries;
begin
  Metadata := Default(TFB2CatalogMetadata);
  FCaptureMetadata := True;
  FCaptureAnnotation := CaptureAnnotation;
  try
    Result := Read(Stream, Series, ErrorText, IsCanceled);
    if Result = fmsComplete then Metadata := FLastMetadata;
  finally
    FCaptureMetadata := False;
    FCaptureAnnotation := False;
  end;
end;

end.
