unit unit_BookConversionRequirements;

interface

uses System.SysUtils;

// Inspect the already resolved book, never an unselected archive member.
// Unknown dependencies are left to the real decoder rather than guessed.
function MissingBookConversionComponents(const AppPath, SourceFile, Extension: string;
  InspectImages: Boolean; const IsCanceled: TFunc<Boolean> = nil): TArray<string>;

implementation

uses System.Classes, System.StrUtils, System.Generics.Collections, System.Variants,
  System.Win.ComObj, Winapi.Windows, Winapi.ActiveX, Winapi.MSXML,
  unit_ProgramUpdateInstaller, unit_FormatComponents, unit_MHLArchiveHelpers, unit_ReaderFormats;

type
  TFB2ImageProbe = class(TInterfacedObject, ISAXContentHandler)
  private
    FReferences, FBinaries: TDictionary<string,Boolean>;
    FCancel: TFunc<Boolean>;
    function ContinueReading: HResult;
    function Attribute(const Values: ISAXAttributes; const Name: string;
      XLink: Boolean = False): string;
  public
    Found, Canceled: Boolean;
    constructor Create(const IsCanceled: TFunc<Boolean>);
    destructor Destroy; override;
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
  end;

constructor TFB2ImageProbe.Create(const IsCanceled: TFunc<Boolean>);
begin
  inherited Create; FCancel:=IsCanceled;
  FReferences:=TDictionary<string,Boolean>.Create; FBinaries:=TDictionary<string,Boolean>.Create;
end;
destructor TFB2ImageProbe.Destroy;
begin FReferences.Free; FBinaries.Free; inherited; end;

function TFB2ImageProbe.ContinueReading: HResult;
begin
  Result:=S_OK;
  try
    if Assigned(FCancel) and FCancel() then begin Canceled:=True; Exit(E_ABORT); end;
    if Found then Exit(E_ABORT);
    // A hint must not build an unbounded index for a malformed input.
    if FReferences.Count+FBinaries.Count>32768 then Result:=E_ABORT;
  except Canceled:=True; Result:=E_ABORT; end;
end;

function TFB2ImageProbe.Attribute(const Values: ISAXAttributes; const Name: string; XLink: Boolean): string;
var Count, Size: Integer; Text: PWord1; Namespace, Local: string;
begin
  Result:=''; OleCheck(Values.getLength(Count));
  for var I:=0 to Count-1 do
  begin
    OleCheck(Values.getLocalName(I,Text,Size)); SetString(Local,PWideChar(Text),Size);
    if Local<>Name then Continue;
    OleCheck(Values.getURI(I,Text,Size)); SetString(Namespace,PWideChar(Text),Size);
    if (Namespace<>'') and not (XLink and (Namespace='http://www.w3.org/1999/xlink')) then Continue;
    OleCheck(Values.getValue(I,Text,Size));
    if Size<=2048 then SetString(Result,PWideChar(Text),Size);
    Exit;
  end;
end;

function TFB2ImageProbe.startElement(var pwchNamespaceUri: Word; cchNamespaceUri: Integer;
  var pwchLocalName: Word; cchLocalName: Integer; var pwchQName: Word;
  cchQName: Integer; const pAttributes: ISAXAttributes): HResult;
var Namespace, Name, ID, MIME: string;
begin
  Result:=ContinueReading; if Failed(Result) then Exit;
  try
    SetString(Namespace,PWideChar(@pwchNamespaceUri),cchNamespaceUri);
    if (Namespace<>'') and (Namespace<>'http://www.gribuser.ru/xml/fictionbook/2.0') and
      (Namespace<>'http://www.gribuser.ru/xml/fictionbook/2.1') and
      (Namespace<>'http://www.gribuser.ru/xml/fictionbook/2.2') and
      (Namespace<>'http://www.gribuser.ru/xml/fictionbook/2.01') then Exit;
    SetString(Name,PWideChar(@pwchLocalName),cchLocalName);
    if Name='image' then
    begin
      ID:=Attribute(pAttributes,'href',True);
      if ID.StartsWith('#') and (Length(ID)>1) then
      begin ID:=ID.Substring(1); FReferences.AddOrSetValue(ID,True); Found:=FBinaries.ContainsKey(ID); end;
    end
    else if Name='binary' then
    begin
      ID:=Attribute(pAttributes,'id'); MIME:=LowerCase(Attribute(pAttributes,'content-type'));
      if (ID<>'') and (IndexText(MIME,['image/jpeg','image/jpg','image/png','image/gif','image/bmp',
        'image/tiff','image/webp','image/jxl'])>=0) then
      begin FBinaries.AddOrSetValue(ID,True); Found:=FReferences.ContainsKey(ID); end;
    end;
    Result:=ContinueReading;
  except Result:=E_FAIL; end;
end;

function TFB2ImageProbe.putDocumentLocator(const pLocator: ISAXLocator): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.startDocument: HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.endDocument: HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.startPrefixMapping(var pwchPrefix: Word; cchPrefix: Integer;
  var pwchUri: Word; cchUri: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.endPrefixMapping(var pwchPrefix: Word; cchPrefix: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.endElement(var pwchNamespaceUri: Word; cchNamespaceUri: Integer;
  var pwchLocalName: Word; cchLocalName: Integer; var pwchQName: Word; cchQName: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.characters(var pwchChars: Word; cchChars: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.ignorableWhitespace(var pwchChars: Word; cchChars: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.processingInstruction(var pwchTarget: Word; cchTarget: Integer;
  var pwchData: Word; cchData: Integer): HResult;
begin Result:=ContinueReading; end;
function TFB2ImageProbe.skippedEntity(var pwchName: Word; cchName: Integer): HResult;
begin Result:=ContinueReading; end;

function FB2HasRasterImages(const FileName: string; const IsCanceled: TFunc<Boolean>): Boolean;
var Reader: ISAXXMLReader; Handler: ISAXContentHandler; Probe: TFB2ImageProbe;
  Input: IStream; Stream: TFileStream; Value: OleVariant; COMStatus: HResult;
  procedure Feature(const Name: string; Enabled: Boolean);
  begin OleCheck(Reader.putFeature(PWord(PWideChar(Name))^,Enabled)); end;
begin
  Result:=False; COMStatus:=CoInitializeEx(nil,COINIT_MULTITHREADED);
  if Failed(COMStatus) and (COMStatus<>RPC_E_CHANGED_MODE) then Exit;
  Stream:=nil;
  try
    try
      Reader:=CoSAXXMLReader60.Create as ISAXXMLReader;
      Feature('prohibit-dtd',True); Feature('schema-validation',False);
      Feature('use-schema-location',False); Feature('use-inline-schema',False);
      Feature('http://xml.org/sax/features/namespaces',True);
      Feature('http://xml.org/sax/features/external-general-entities',False);
      Feature('http://xml.org/sax/features/external-parameter-entities',False);
      OleCheck(Reader.putProperty(PWord(PWideChar('max-element-depth'))^,256));
      Probe:=TFB2ImageProbe.Create(IsCanceled); Handler:=Probe; OleCheck(Reader.putContentHandler(Handler));
      Stream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
      Input:=TStreamAdapter.Create(Stream,soReference); Value:=IUnknown(Input);
      Reader.parse(Value); // E_ABORT is the intentional early result after a match.
      if Probe.Canceled then Abort;
      Result:=Probe.Found;
    except on E:EAbort do raise; on E:Exception do Result:=False; end;
  finally
    VarClear(Value); Reader:=nil; Handler:=nil; Input:=nil; Stream.Free;
    if Succeeded(COMStatus) then CoUninitialize;
  end;
end;

function PackageHasRasterImages(const FileName: string; const IsCanceled: TFunc<Boolean>): Boolean;
var Archive: TMHLZip; Name, Ext: string;
begin
  Result:=False; Archive:=TMHLZip.Create(FileName,True,False,IsCanceled);
  try
    for var I:=0 to Archive.FileCount-1 do
    begin
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      Name:=Archive.FileNames[I]; if Name.StartsWith('__MACOSX/',True) or ExtractFileName(Name).StartsWith('._') then Continue;
      Ext:=LowerCase(ExtractFileExt(Name));
      if (Archive.FileSizes[I]>0) and (IndexText(Ext,['.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.jxl'])>=0) then Exit(True);
    end;
  finally Archive.Free; end;
end;

function MissingBookConversionComponents(const AppPath, SourceFile, Extension: string;
  InspectImages: Boolean; const IsCanceled: TFunc<Boolean>): TArray<string>;
var Ext, Actual: string; Images: Boolean;
  procedure Need(const ID: string);
  begin
    if (ID<>'') and (IndexText(ID,Result)<0) and ComponentNeedsRepair(AppPath,ID) then
      Result:=Result+TArray<string>.Create(ID);
  end;
begin
  Result:=nil; if Assigned(IsCanceled) and IsCanceled() then Abort;
  Ext:='.'+LowerCase(Extension.TrimLeft(['.']));
  if FileExists(SourceFile) then
  begin Actual:=DetectReaderExtension(SourceFile); if Actual<>'' then Ext:=Actual; end;
  if not ModularBookProcessingAvailable(AppPath) then Result:=TArray<string>.Create('BookProcessing');
  if Ext='.pdf' then Need('PDFium')
  else if IndexText(Ext,['.djvu','.djv','.dju','.djm','.djvm'])>=0 then Need('DjVuLibre')
  else if IndexText(Ext,['.doc','.dot','.ppt','.pps','.pot','.xls','.xlt'])>=0 then Need('DocSharp')
  else if IndexText(Ext,['.mobi','.azw','.azw3','.prc'])>=0 then Need('Kindle')
  else if IndexText(Ext,['.lit','.lrf'])>=0 then Need('LegacyBooks')
  else if IndexText(Ext,['.wps','.wpd'])>=0 then Need('LegacyOffice')
  else if IndexText(Ext,['.xps','.oxps'])>=0 then Need('XPS')
  else if Ext='.ibk' then Need('IBK')
  else if IndexText(Ext,['.chm','.cbr','.cb7'])>=0 then Need('7-Zip');
  if InspectImages and ComponentNeedsRepair(AppPath,'ImageProcessing') then
  begin
    Images:=IndexText(Ext,['.djvu','.djv','.dju','.djm','.djvm','.cbz','.cbr','.cb7',
      '.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp'])>=0;
    if FileExists(SourceFile) then
    begin
      if Ext='.fb2' then Images:=FB2HasRasterImages(SourceFile,IsCanceled)
      else if IndexText(Ext,['.epub','.docx','.odt','.fb3'])>=0 then Images:=PackageHasRasterImages(SourceFile,IsCanceled);
    end;
    if Images then Need('ImageProcessing');
  end;
end;

end.
