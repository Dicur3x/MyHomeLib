unit unit_PackageBookMetadata;

interface

uses System.Classes, System.SysUtils, unit_FB2PublisherMetadataReader;

function IsMetadataContainer(const Extension: string): Boolean;
function IsMetadataPackage(const Extension: string): Boolean;
function ReadPackageMetadata(Stream: TStream; const Extension: string;
  out Metadata: TFB2CatalogMetadata; out ErrorText: string; CaptureAnnotation: Boolean;
  const IsCanceled: TFunc<Boolean> = nil): TFB2MetadataStatus;

implementation

uses System.Zip, System.Variants, System.Win.ComObj, Winapi.MSXML, Winapi.ActiveX;

const DC='http://purl.org/dc/elements/1.1/';

function IsMetadataContainer(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|','|zip|fbz|7z|7zip|rar|cab|tar|gz|gzip|bz2|xz|tgz|')>0;
end;

function IsMetadataPackage(const Extension: string): Boolean;
begin
  Result:=SameText(Extension,'.epub') or SameText(Extension,'.docx') or SameText(Extension,'.odt') or SameText(Extension,'.fb3');
end;

function Attr(const Node: IXMLDOMNode; const Name: string): string;
var I: Integer; A: IXMLDOMNode;
begin
  Result:=''; if not Assigned(Node) or not Assigned(Node.attributes) then Exit;
  for I:=0 to Node.attributes.length-1 do
  begin A:=Node.attributes.item[I]; if SameText(A.baseName,Name) then Exit(A.text); end;
end;

function ReadPackageMetadata(Stream: TStream; const Extension: string;
  out Metadata: TFB2CatalogMetadata; out ErrorText: string; CaptureAnnotation: Boolean;
  const IsCanceled: TFunc<Boolean>): TFB2MetadataStatus;
var Zip: TZipFile; Document, Container: IXMLDOMDocument3; Root, Node, Ref: IXMLDOMNode;
  Path, Name, Value, Role, ID, Refines: string; I,J,Year: Integer; Values: IXMLDOMNodeList;
  function Canceled: Boolean;
  begin Result:=Assigned(IsCanceled) and IsCanceled(); end;
  function Load(const Entry: string; Optional: Boolean = False): IXMLDOMDocument3;
  var At,Matches: Integer; Bytes: TBytes; Buffer: TBytesStream; Input: OleVariant;
  begin
    Result:=nil; At:=-1; Matches:=0;
    for var K:=0 to Zip.FileCount-1 do
      if Zip.FileNames[K]=Entry then begin At:=K; Inc(Matches); end;
    if (Matches=0) and Optional then Exit;
    if Matches<>1 then raise EReadError.Create('Описание книги не найдено однозначно: '+Entry);
    if Zip.FileInfo[At].UncompressedSize>2*1024*1024 then raise EReadError.Create('Описание книги превышает 2 МБ');
    if Canceled then Abort;
    Zip.Read(At,Bytes); Buffer:=TBytesStream.Create(Bytes);
    try
      Result:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
      Result.async:=False; Result.resolveExternals:=False; Result.validateOnParse:=False;
      Result.setProperty('ProhibitDTD',True); Result.setProperty('MaxXMLSize',2048);
      Result.setProperty('MaxElementDepth',128);
      Input:=TStreamAdapter.Create(Buffer,soReference) as IStream;
      try if not Result.load(Input) then raise EReadError.Create(Trim(Result.parseError.reason));
      finally Input:=Unassigned; end;
    finally Buffer.Free; end;
  end;
  procedure AssignValue(const FieldName, Text: string);
  var V: string;
  begin
    V:=Trim(Text); if V='' then Exit;
    if SameText(FieldName,'publisher') then Metadata.Publisher:=V
    else if SameText(FieldName,'city') then Metadata.City:=V
    else if SameText(FieldName,'isbn') then Metadata.ISBN:=V
    else if SameText(FieldName,'translators') then Metadata.Translators:=V
    else if SameText(FieldName,'publicationyear') and TryStrToInt(V,Year) and (Year>0) and (Year<=9999) then Metadata.PubYear:=Year
    else if CaptureAnnotation and SameText(FieldName,'description') then Metadata.Annotation:=V;
  end;
begin
  Metadata:=Default(TFB2CatalogMetadata); ErrorText:=''; Result:=fmsInvalid;
  Zip:=TZipFile.Create;
  try
  try
    if Canceled then Exit(fmsCanceled);
    Stream.Position:=0; Zip.Open(Stream,zmRead);
    if Zip.FileCount>200000 then raise EReadError.Create('В книге слишком много файлов');
    if SameText(Extension,'.epub') then
    begin
      Container:=Load('META-INF/container.xml');
      Values:=Container.selectNodes('/*[local-name()="container"]/*[local-name()="rootfiles"]/*[local-name()="rootfile"]');
      Path:='';
      for I:=0 to Values.length-1 do
        if Attr(Values.item[I],'media-type')='application/oebps-package+xml' then
        begin Path:=Attr(Values.item[I],'full-path'); Break; end;
      if (Path='') and (Values.length=1) then Path:=Attr(Values.item[0],'full-path');
      if (Path='') or Path.Contains('\') or Path.StartsWith('/') or Path.Contains('../') or Path.Contains(':') then
        raise EReadError.Create('Некорректный путь описания EPUB');
      Document:=Load(Path); Root:=Document.selectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]');
      if not Assigned(Root) then raise EReadError.Create('В EPUB отсутствует раздел metadata');
      for I:=0 to Root.childNodes.length-1 do
      begin
        if Canceled then Exit(fmsCanceled);
        Node:=Root.childNodes.item[I]; if Node.namespaceURI<>DC then Continue;
        Name:=LowerCase(Node.baseName); Value:=Trim(Node.text);
        if Name='publisher' then AssignValue(Name,Value)
        else if Name='description' then AssignValue(Name,Value)
        else if (Name='date') and (Metadata.PubYear=0) and
          ((Attr(Node,'event')='') or SameText(Attr(Node,'event'),'publication')) then
        begin if TryStrToInt(Copy(Value,1,4),Year) and (Year>0) then Metadata.PubYear:=Year; end
        else if Name='identifier' then
        begin
          if Value.StartsWith('urn:isbn:',True) then Metadata.ISBN:=Copy(Value,10,MaxInt)
          else
          begin
            Role:=Attr(Node,'scheme'); ID:=Attr(Node,'id');
            if ID<>'' then for J:=0 to Root.childNodes.length-1 do
            begin
              Ref:=Root.childNodes.item[J];
              if (Ref.baseName='meta') and (Attr(Ref,'refines')='#'+ID) and
                (Attr(Ref,'property')='identifier-type') and SameText(Attr(Ref,'scheme'),'onix:codelist5') and
                ((Trim(Ref.text)='15') or (Trim(Ref.text)='02')) then Role:='ISBN';
            end;
            if SameText(Role,'ISBN') then Metadata.ISBN:=Value;
          end;
        end
        else if (Name='contributor') or (Name='creator') then
        begin
          Role:=Attr(Node,'role'); ID:=Attr(Node,'id');
          if ID<>'' then
            for J:=0 to Root.childNodes.length-1 do
            begin
              Ref:=Root.childNodes.item[J]; Refines:=Attr(Ref,'refines');
              if (Ref.baseName='meta') and (Refines='#'+ID) and (Attr(Ref,'property')='role') then Role:=Trim(Ref.text);
            end;
          if SameText(Role,'trl') and (Value<>'') then
          begin
            if Metadata.Translators<>'' then Metadata.Translators:=Metadata.Translators+'; ';
            Metadata.Translators:=Metadata.Translators+Value;
          end;
        end;
      end;
    end
    else if SameText(Extension,'.fb3') then
    begin
      Document:=Load('fb3/description.xml'); Root:=Document.documentElement;
      if not Assigned(Root) or (Root.baseName<>'fb3-description') then raise EReadError.Create('Некорректное описание FB3');
      Values:=Root.selectNodes('./*[local-name()="paper-publish-info"]');
      // Keep publication fields together instead of mixing paper editions.
      if Values.length>0 then
      begin
        Node:=Values.item[0];
        if Metadata.Publisher='' then AssignValue('publisher',Attr(Node,'publisher'));
        if Metadata.City='' then AssignValue('city',Attr(Node,'city'));
        if Metadata.PubYear=0 then AssignValue('publicationyear',Attr(Node,'year'));
        if Metadata.ISBN='' then
        begin Ref:=Node.selectSingleNode('./*[local-name()="isbn"]'); if Assigned(Ref) then AssignValue('isbn',Ref.text); end;
      end;
      if Metadata.ISBN='' then
      begin Node:=Root.selectSingleNode('./*[local-name()="document-info"]/*[local-name()="isbn"]'); if Assigned(Node) then AssignValue('isbn',Node.text); end;
      if CaptureAnnotation then
      begin Node:=Root.selectSingleNode('./*[local-name()="annotation"]'); if Assigned(Node) then Metadata.Annotation:=Trim(Node.text); end;
      Values:=Root.selectNodes('./*[local-name()="fb3-relations"]/*[local-name()="subject" and @link="translator"]');
      for I:=0 to Values.length-1 do
      begin
        Node:=Values.item[I].selectSingleNode('./*[local-name()="title"]');
        if Assigned(Node) then Value:=Trim(Node.text) else Value:='';
        if Value<>'' then
        begin
          if Metadata.Translators<>'' then Metadata.Translators:=Metadata.Translators+'; ';
          Metadata.Translators:=Metadata.Translators+Value;
        end;
      end;
    end
    else if SameText(Extension,'.docx') then
    begin
      Document:=Load('docProps/core.xml',True);
      if Assigned(Document) and CaptureAnnotation then
      begin Node:=Document.selectSingleNode('/*/*[local-name()="description" and namespace-uri()="'+DC+'"]');
        if Assigned(Node) then Metadata.Annotation:=Trim(Node.text); end;
      Document:=Load('docProps/custom.xml',True);
      if Assigned(Document) then
        for I:=0 to Document.documentElement.childNodes.length-1 do
        begin Node:=Document.documentElement.childNodes.item[I]; AssignValue(Attr(Node,'name'),Node.text); end;
    end
    else if SameText(Extension,'.odt') then
    begin
      Document:=Load('meta.xml',True);
      if Assigned(Document) then
      begin
        Root:=Document.selectSingleNode('/*/*[local-name()="meta"]');
        if Assigned(Root) then for I:=0 to Root.childNodes.length-1 do
        begin
          Node:=Root.childNodes.item[I];
          if (Node.namespaceURI=DC) and (Node.baseName='description') then AssignValue('description',Node.text)
          else if Node.baseName='user-defined' then AssignValue(Attr(Node,'name'),Node.text);
        end;
      end;
    end
    else raise ENotSupportedException.Create('Этот формат метаданных пока не поддерживается');
    if Canceled then Exit(fmsCanceled);
    Result:=fmsComplete;
  except
    on E: EAbort do begin Metadata:=Default(TFB2CatalogMetadata); Result:=fmsCanceled; end;
    on E: EOutOfMemory do raise;
    on E: EAccessViolation do raise;
    on E: Exception do begin Metadata:=Default(TFB2CatalogMetadata); ErrorText:=E.Message; Result:=fmsInvalid; end;
  end;
  finally Zip.Free; end;
end;

end.
