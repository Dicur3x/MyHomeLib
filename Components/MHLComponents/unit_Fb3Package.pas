unit unit_Fb3Package;

interface

uses System.Generics.Collections, System.Zip;

type
  TFb3Package = class
  private
    FArchive: TZipFile;
    FNames: TArray<string>;
    FMembers: TDictionary<string,Integer>;
    FBody, FDescription: string;
    FIsBook, FDescriptionDeclared: Boolean;
    procedure ReadContentTypes;
  public
    constructor Create(const Archive: TZipFile);
    destructor Destroy; override;
    function Member(const Base, Reference: string): string;
    function ReadRelationships(const Part, RelationType: string; const Targets: TDictionary<string,string>): Boolean;
    property IsBook: Boolean read FIsBook;
    property Body: string read FBody;
    property Description: string read FDescription;
    property DescriptionDeclared: Boolean read FDescriptionDeclared;
  end;

const
  Fb3ImageRelationship = 'http://www.fictionbook.org/FictionBook3/relationships/image';
  Fb3ThumbnailRelationship = 'http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail';

implementation

uses System.Classes, System.SysUtils, System.StrUtils, System.NetEncoding, System.Variants,
  System.Win.ComObj, Winapi.ActiveX, Winapi.MSXML;

const
  TypesName = '[Content_Types].xml';
  TypesNamespace = 'http://schemas.openxmlformats.org/package/2006/content-types';
  RelationsNamespace = 'http://schemas.openxmlformats.org/package/2006/relationships';

function PartKey(const Base, Reference: string): string;
var Path, Segment: string; Parts: TArray<string>; Count: Integer;
begin
  Result:='';
  if (Reference='') or (Length(Reference)>4096) or Reference.EndsWith('/') or Reference.Contains(#0) then Exit;
  if Reference.StartsWith('/') then Path:=Reference
  else Path:=Copy(Base,1,LastDelimiter('/',Base))+Reference;
  try Path:=TNetEncoding.URL.Decode(Path.Replace('+','%2B'));
  except on E: EConvertError do Exit; end;
  if Path.StartsWith('//') or Path.Contains(':') or Path.Contains('\') or Path.Contains(#0) then Exit;
  Parts:=Path.Split(['/']); Count:=0;
  for Segment in Parts do
    if (Segment='') or (Segment='.') then Continue
    else if Segment='..' then
    begin
      if Count=0 then Exit;
      Dec(Count);
    end
    else
    begin
      Parts[Count]:=Segment;
      Inc(Count);
    end;
  Result:=string.Join('/',Parts,0,Count).ToLowerInvariant;
end;

function LoadXml(Archive: TZipFile; Index: Integer): IXMLDOMDocument3;
const MetadataLimit = 4*1024*1024;
var Bytes: TBytes; Stream: TBytesStream; Entry: TStream; Header: TZipHeader;
  Input: OleVariant; Size: UInt64; Extra: Byte;
begin
  Result:=nil;
  if Index<0 then Exit;
  Size:=Archive.FileInfo[Index].UncompressedSize64;
  if Size>MetadataLimit then Exit;
  Archive.Read(Index,Entry,Header,True);
  try
    SetLength(Bytes,Integer(Size));
    if Size>0 then Entry.ReadBuffer(Bytes[0],Integer(Size));
    if Entry.Read(Extra,1)<>0 then Exit;
  finally Entry.Free; end;
  Result:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Result.async:=False; Result.validateOnParse:=False; Result.resolveExternals:=False;
  Result.setProperty('ProhibitDTD',True);
  Result.setProperty('MaxElementDepth',64);
  Stream:=TBytesStream.Create(Bytes);
  try
    Input:=TStreamAdapter.Create(Stream,soReference) as IStream;
    try
      if not Result.load(Input) then Result:=nil;
    finally VarClear(Input); end;
  finally Stream.Free; end;
end;

function Attr(const Node: IXMLDOMNode; const Name: string): string;
begin
  var Value:=Node.attributes.getNamedItem(Name);
  if Assigned(Value) then Result:=Value.text else Result:='';
end;

constructor TFb3Package.Create(const Archive: TZipFile);
begin
  inherited Create;
  FArchive:=Archive;
  FNames:=Archive.FileNames;
  FMembers:=TDictionary<string,Integer>.Create;
  for var I:=0 to High(FNames) do
  begin
    var Key:=PartKey('',FNames[I]);
    if (Key<>'') and not FMembers.TryAdd(Key,I) then FMembers[Key]:=-1;
  end;
  FBody:=Member('','fb3/body.xml');
  FDescription:=Member('','fb3/description.xml');
  FIsBook:=FBody<>'';
  ReadContentTypes;
end;

destructor TFb3Package.Destroy;
begin
  FMembers.Free;
  inherited;
end;

function TFb3Package.Member(const Base, Reference: string): string;
var Index: Integer;
begin
  Result:='';
  if FMembers.TryGetValue(PartKey(Base,Reference),Index) and (Index>=0) then Result:=FNames[Index];
end;

procedure TFb3Package.ReadContentTypes;
var Index, BodyCount, DescriptionCount: Integer; Init: HResult;
  Document: IXMLDOMDocument3; Node: IXMLDOMNode; ContentType: string;
begin
  if not FMembers.TryGetValue(PartKey('',TypesName),Index) or (Index<0) then Exit;
  Init:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    Document:=LoadXml(FArchive,Index);
    if not Assigned(Document) or not Assigned(Document.documentElement) then Exit;
    if (Document.documentElement.baseName<>'Types') or
      (VarToStr(Document.documentElement.namespaceURI)<>TypesNamespace) then Exit;
    BodyCount:=0; DescriptionCount:=0;
    Node:=Document.documentElement.firstChild;
    while Assigned(Node) do
    begin
      if (Node.baseName='Override') and (VarToStr(Node.namespaceURI)=TypesNamespace) then
      begin
        ContentType:=Attr(Node,'ContentType');
        if SameText(ContentType,'application/fb3-body+xml') then
        begin
          Inc(BodyCount); FIsBook:=True;
          FBody:=Member('',Attr(Node,'PartName'));
        end
        else if SameText(ContentType,'application/fb3-description+xml') then
        begin
          Inc(DescriptionCount); FDescriptionDeclared:=True;
          FDescription:=Member('',Attr(Node,'PartName'));
        end;
      end;
      Node:=Node.nextSibling;
    end;
    if BodyCount>1 then FBody:='';
    if DescriptionCount>1 then FDescription:='';
  finally
    Node:=nil; Document:=nil;
    if Succeeded(Init) then CoUninitialize;
  end;
end;

function TFb3Package.ReadRelationships(const Part, RelationType: string;
  const Targets: TDictionary<string,string>): Boolean;
var RelationshipPart, Key, Target, Previous: string; Index: Integer;
  Document: IXMLDOMDocument3; Node: IXMLDOMNode;
begin
  Targets.Clear;
  var Slash:=LastDelimiter('/',Part);
  RelationshipPart:=Copy(Part,1,Slash)+'_rels/'+Part.Substring(Slash)+'.rels';
  Result:=FMembers.TryGetValue(PartKey('',RelationshipPart),Index);
  if not Result then Exit;
  Document:=LoadXml(FArchive,Index);
  if not Assigned(Document) or not Assigned(Document.documentElement) then
    raise EReadError.Create('В FB3 повреждён список связанных файлов.');
  if (Document.documentElement.baseName<>'Relationships') or
    (VarToStr(Document.documentElement.namespaceURI)<>RelationsNamespace) then
    raise EReadError.Create('В FB3 повреждён список связанных файлов.');
  Node:=Document.documentElement.firstChild;
  while Assigned(Node) do
  begin
    if (Node.baseName='Relationship') and (VarToStr(Node.namespaceURI)=RelationsNamespace) and
      (Attr(Node,'Type')=RelationType) then
    begin
      Key:=Attr(Node,'Id');
      if Key<>'' then
      begin
        if SameText(Attr(Node,'TargetMode'),'external') then Target:=''
        else Target:=Member(Part,Attr(Node,'Target'));
        if Targets.TryGetValue(Key,Previous) and (Previous<>Target) then Target:='';
        Targets.AddOrSetValue(Key,Target);
      end;
    end;
    Node:=Node.nextSibling;
  end;
end;

end.
