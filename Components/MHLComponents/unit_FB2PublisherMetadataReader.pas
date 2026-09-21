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
  TFB2MetadataStatus = (fmsComplete, fmsInvalid, fmsCanceled);

  // Create, reuse and destroy on one COM-initialized thread. Streams are borrowed.
  TFB2PublisherMetadataReader = class
  private
    FReader: ISAXXMLReader;
    FHandler: IInterface;
    FHandlerObject: TObject;
  public
    constructor Create;
    destructor Destroy; override;
    // Reads from the current position without seeking. Only Complete can replace
    // stored metadata; Invalid/Canceled always return an empty Series array.
    function Read(Stream: TStream; out Series: TFB2PublisherSeries;
      out ErrorText: string;
      const IsCanceled: TFunc<Boolean> = nil): TFB2MetadataStatus;
  end;

implementation

uses
  System.Generics.Collections,
  System.Variants,
  System.Win.ComObj,
  Winapi.Windows,
  Winapi.ActiveX;

const
  FB2_NAMESPACE = 'http://www.gribuser.ru/xml/fictionbook/2.0';
  INPUT_BUFFER_SIZE = 8192;

type
  TMetadataHandler = class(TInterfacedObject, ISAXContentHandler, ISAXErrorHandler)
  private
    FItems: TList<TFB2PublisherSeriesItem>;
    FCancel: TFunc<Boolean>;
    FException: Exception;
    FError: string;
    FNamespace: string;
    FDepth: Integer;
    FHasTitleInfo: Boolean;
    FInDescription: Boolean;
    FInPublishInfo: Boolean;
    FSequencePath: array[0..FB2_METADATA_MAX_DEPTH] of Boolean;
    FComplete: Boolean;
    FCanceled: Boolean;
    function CheckContinue: HResult;
    function Invalid(const MessageText: string): HResult;
    function CaptureException: HResult;
    function Attribute(const Attributes: ISAXAttributes; const Name: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset(const IsCanceled: TFunc<Boolean>);
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
    function Read(pv: Pointer; cb: FixedUInt; pcbRead: PFixedUInt): HResult; stdcall;
    function Write(pv: Pointer; cb: FixedUInt; pcbWritten: PFixedUInt): HResult; stdcall;
  end;

function SAXText(Value: PWideChar; Count: Integer): string;
begin
  SetString(Result, Value, Count);
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

procedure TMetadataHandler.Reset(const IsCanceled: TFunc<Boolean>);
begin
  FItems.Clear;
  FCancel := IsCanceled;
  FreeAndNil(FException);
  FError := '';
  FNamespace := '';
  FDepth := 0;
  FHasTitleInfo := False;
  FInDescription := False;
  FInPublishInfo := False;
  FComplete := False;
  FCanceled := False;
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
    if FCanceled or FComplete or (FError <> '') or (FException <> nil) then
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
    if FDepth = 1 then
    begin
      if (Name <> 'FictionBook') or
        ((Namespace <> '') and (Namespace <> FB2_NAMESPACE)) then
        Exit(Invalid('Expected a FictionBook root element'));
      FNamespace := Namespace;
    end
    else if FDepth = 2 then
    begin
      if (Namespace = FNamespace) and (Name = 'description') then
      begin
        FInDescription := True;
      end
      else if (Namespace = FNamespace) and
        ((Name = 'body') or (Name = 'binary')) then
        Exit(Invalid('FictionBook description is missing'));
    end
    else if FInDescription and (Namespace = FNamespace) then
    begin
      if FDepth = 3 then
      begin
        if Name = 'title-info' then
          FHasTitleInfo := True;
        FInPublishInfo := Name = 'publish-info';
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
begin
  try
    Result := CheckContinue;
    if Failed(Result) then
      Exit;
    if (FDepth = 2) and FInDescription then
    begin
      if not FHasTitleInfo then
        Exit(Invalid('FictionBook title-info is missing'));
      // This deliberate SAX abort is success. The body is never XML-parsed.
      FComplete := True;
      Exit(E_ABORT);
    end;
    if FDepth = 3 then
      FInPublishInfo := False;
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
  Result := Invalid('FictionBook description is incomplete');
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
  Result := CheckContinue;
end;

function TMetadataHandler.ignorableWhitespace(var pwchChars: Word;
  cchChars: Integer): HResult;
begin
  Result := CheckContinue;
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

function TFB2PublisherMetadataReader.Read(Stream: TStream;
  out Series: TFB2PublisherSeries; out ErrorText: string;
  const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
var
  Handler: TMetadataHandler;
  Input: ISequentialStream;
  Value: OleVariant;
  ParseResult: HResult;
begin
  Series := nil;
  ErrorText := '';
  if Stream = nil then
  begin
    ErrorText := 'Missing FictionBook input stream';
    Exit(fmsInvalid);
  end;
  Handler := TMetadataHandler(FHandlerObject);
  Handler.Reset(IsCanceled);
  try
    Input := TMetadataInput.Create(Stream, Handler);
    Value := IUnknown(Input);
    ParseResult := FReader.parse(Value);
    Handler.RaiseCapturedException;
    if Handler.FCanceled then
      Exit(fmsCanceled);
    if Handler.FComplete then
    begin
      Series := Handler.FItems.ToArray;
      Exit(fmsComplete);
    end;
    ErrorText := Handler.FError;
    if ErrorText = '' then
      ErrorText := Format('Incomplete FictionBook metadata (HRESULT %.8x)',
        [Cardinal(ParseResult)]);
    Result := fmsInvalid;
  finally
    Handler.FCancel := nil;
  end;
end;

end.
