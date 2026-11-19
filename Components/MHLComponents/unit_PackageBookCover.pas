unit unit_PackageBookCover;

interface

uses System.Classes, System.SysUtils;

function IsBookCoverPackage(const Extension: string): Boolean;
// Reads only declared cover/thumbnail parts. It never renders the book, follows
// external links, or selects an arbitrary illustration as a cover.
function ReadPackageBookCover(Stream: TStream; const Extension: string;
  out Status: string; const IsCanceled: TFunc<Boolean> = nil;
  const RenderSVG: TFunc<TBytes,TBytes> = nil): TBytes;

implementation

uses System.Zip, System.Variants, System.Win.ComObj, System.NetEncoding,
  System.RegularExpressions, Winapi.Windows, Winapi.ActiveX, Winapi.MSXML,
  unit_ImageBounds;

const MaxXML=2*1024*1024; MaxCover=16*1024*1024;

function IsBookCoverPackage(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|epub|fb3|docx|docm|dotx|dotm|pptx|pptm|potx|potm|ppsx|ppsm|xlsx|xlsm|xlsb|xltx|xltm|'+
    'odt|ott|odm|odp|otp|ods|ots|odg|otg|odf|')>0;
end;

function Attribute(const Node: IXMLDOMNode; const Name: string): string;
begin
  Result:=''; if not Assigned(Node) or not Assigned(Node.attributes) then Exit;
  for var I:=0 to Node.attributes.length-1 do
    if SameText(Node.attributes.item[I].baseName,Name) then Exit(Node.attributes.item[I].text);
end;

function ReadPackageBookCover(Stream: TStream; const Extension: string;
  out Status: string; const IsCanceled: TFunc<Boolean>;
  const RenderSVG: TFunc<TBytes,TBytes>): TBytes;
var Zip:TZipFile; Saved:Int64; HR:HRESULT; Ext,PackagePath,CoverID,Part:string;
  Container,PackageDoc,Relations:IXMLDOMDocument3;
  Nodes,Manifest,Guide:IXMLDOMNodeList; Node:IXMLDOMNode;
  Candidates,Seen:TStringList;
  UsesOPC:Boolean;
  procedure Check;
  begin if Assigned(IsCanceled) and IsCanceled() then Abort; end;
  function EntryIndex(const Name:string):Integer;
    function FoldASCII(C:Char):Char;
    begin
      if (C>='A') and (C<='Z') then Result:=Chr(Ord(C)+32) else Result:=C;
    end;
    function Matches(const Candidate:string):Boolean;
    begin
      if Candidate=Name then Exit(True);
      if not UsesOPC or (Length(Candidate)<>Length(Name)) then Exit(False);
      for var J:=1 to Length(Name) do
        if FoldASCII(Candidate[J])<>FoldASCII(Name[J]) then Exit(False);
      Result:=True;
    end;
  begin
    Result:=-1;
    for var I:=0 to Zip.FileCount-1 do
    begin
      if I mod 256=0 then Check;
      if not Matches(Zip.FileNames[I]) then Continue;
      if Result>=0 then raise EReadError.Create('В книге повторяется путь обложки: '+Name);
      Result:=I;
    end;
  end;
  function ReadEntry(const Name:string; Limit:Integer):TBytes;
  var Index,Count:Integer; Input:TStream; Header:TZipHeader;
    Output:TMemoryStream; Buffer:array[0..32767] of Byte;
  begin
    Result:=nil; Check; Index:=EntryIndex(Name); if Index<0 then Exit;
    if Zip.FileInfo[Index].UncompressedSize64>UInt64(Limit) then
      raise EReadError.Create('Файл обложки или её описания превышает допустимый размер.');
    // Do not allocate from an untrusted ZIP size. Limit the actual streamed
    // output as well; CheckCrc rejects damaged parts instead of previewing them.
    Zip.Read(Index,Input,Header,True);
    try
      Output:=TMemoryStream.Create;
      try
        repeat
          Check; Count:=Input.Read(Buffer,SizeOf(Buffer));
          if Output.Size+Count>Limit then raise EReadError.Create('Распакованная обложка превышает допустимый размер.');
          if Count>0 then Output.WriteBuffer(Buffer,Count);
        until Count=0;
        if Output.Size<>Int64(Zip.FileInfo[Index].UncompressedSize64) then
          raise EReadError.Create('Размер обложки не совпадает с описанием архива.');
        SetLength(Result,Output.Size);
        if Length(Result)>0 then Move(Output.Memory^,Result[0],Length(Result));
      finally Output.Free; end;
    finally Input.Free; end;
    Check;
  end;
  function XML(const Bytes:TBytes):IXMLDOMDocument3;
  var Buffer:TBytesStream; Input:OleVariant; Text:string;
  begin
    if Length(Bytes)>MaxXML then raise EReadError.Create('Описание обложки превышает 2 МБ.');
    Result:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
    Result.async:=False; Result.resolveExternals:=False; Result.validateOnParse:=False;
    Result.setProperty('ProhibitDTD',True); Result.setProperty('MaxXMLSize',2048);
    Result.setProperty('MaxElementDepth',128);
    Buffer:=TBytesStream.Create(Bytes);
    try
      Input:=TStreamAdapter.Create(Buffer,soReference) as IStream;
      try
        if Result.load(Input) then Exit;
      finally Input:=Unassigned; end;
    finally Buffer.Free; end;
    // XHTML covers commonly retain a simple HTML doctype. Never admit an
    // internal entity subset; no external declaration is fetched by MSXML.
    Text:=TEncoding.UTF8.GetString(Bytes);
    if not Text.Contains('<!DOCTYPE') or Text.Contains('<!ENTITY') then
      raise EReadError.Create('Не удалось прочитать описание обложки: '+Trim(Result.parseError.reason));
    var Doctype:=TRegEx.Match(Text,'<!DOCTYPE\s+[^>\[]+>');
    if not Doctype.Success then raise EReadError.Create('В описании обложки запрещены объявления сущностей.');
    Delete(Text,Doctype.Index+1,Doctype.Length);
    if not Result.loadXML(Text) then raise EReadError.Create('Не удалось прочитать описание обложки.');
  end;
  function Resolve(const Base,Reference:string):string;
  var Path,Prefix,Segment:string; Parts:TStringList; At:Integer;
  begin
    Check; Path:=Trim(Reference); At:=Pos('#',Path); if At>0 then Path:=Copy(Path,1,At-1);
    At:=Pos('?',Path); if At>0 then Path:=Copy(Path,1,At-1);
    Path:=TNetEncoding.URL.Decode(Path.Replace('+','%2B'));
    if (Path='') or Path.StartsWith('/') or Path.Contains('\') or Path.Contains(':') or
      Path.Contains(#0) then raise EReadError.Create('Внешний или недопустимый путь обложки пропущен.');
    Prefix:=Copy(Base,1,LastDelimiter('/',Base)); Parts:=TStringList.Create;
    try
      for Segment in (Prefix+Path).Split(['/']) do
        if (Segment='') or (Segment='.') then Continue
        else if Segment='..' then
        begin
          if Parts.Count=0 then raise EReadError.Create('Путь обложки выходит за пределы книги.');
          Parts.Delete(Parts.Count-1);
        end
        else Parts.Add(Segment);
      Result:=String.Join('/',Parts.ToStringArray);
    finally Parts.Free; end;
  end;
  function PictureMime(const Data:TBytes):string;
  var Image:TBytesStream; Width,Height:Integer;
  begin
    Result:=''; if Length(Data)<12 then Exit;
    if (Data[0]=$89) and (TEncoding.ASCII.GetString(Data,1,3)='PNG') then Result:='image/png'
    else if (Data[0]=$FF) and (Data[1]=$D8) and (Data[2]=$FF) then Result:='image/jpeg'
    else if (TEncoding.ASCII.GetString(Data,0,6)='GIF87a') or
      (TEncoding.ASCII.GetString(Data,0,6)='GIF89a') then Result:='image/gif'
    else if (TEncoding.ASCII.GetString(Data,0,4)='RIFF') and
      (TEncoding.ASCII.GetString(Data,8,4)='WEBP') then Result:='image/webp';
    if Result='' then Exit;
    Image:=TBytesStream.Create(Data);
    try
      if not ImageDimensions(Image,Width,Height) or not ImageFitsMemory(Image,64*1024*1024) then
        raise EReadError.Create('Изображение векторной обложки превышает допустимые размеры.');
    finally Image.Free; end;
  end;
  function PreparedSVG(const Source:IXMLDOMNode; const Name:string):TBytes;
  var Root:IXMLDOMElement; Images:IXMLDOMNodeList; Image,Attr:IXMLDOMNode;
    Ref,Mime,Serialized:string; Data:TBytes; Added:Int64;
  begin
    // MSXML serialises inherited namespace bindings on the detached clone.
    // Those generated xmlns nodes are read-only; rewriting them is both
    // unnecessary and an error, including when the URI stays unchanged.
    Root:=Source.cloneNode(True) as IXMLDOMElement;
    Images:=Root.selectNodes('.//*[local-name()="image" or local-name()="feImage"]');
    if Images.length>32 then raise EReadError.Create('В векторной обложке слишком много изображений.');
    Added:=0;
    for var I:=0 to Images.length-1 do
    begin
      Check; Image:=Images.item[I];
      for var J:=0 to Image.attributes.length-1 do
      begin
        Attr:=Image.attributes.item[J];
        if not SameText(Attr.baseName,'href') and not SameText(Attr.baseName,'src') then Continue;
        Ref:=Trim(Attr.text);
        if Ref.StartsWith('#') or Ref.StartsWith('data:') then Continue;
        Data:=ReadEntry(Resolve(Name,Ref),MaxCover);
        if Length(Data)=0 then raise EReadError.Create('В книге отсутствует изображение векторной обложки.');
        Mime:=PictureMime(Data);
        if Mime='' then raise EReadError.Create('Векторная обложка использует неподдерживаемый рисунок.');
        Inc(Added,Length(Data));
        if Added>MaxCover then raise EReadError.Create('Изображения векторной обложки превышают 16 МБ.');
        Attr.nodeValue:='data:'+Mime+';base64,'+TNetEncoding.Base64.EncodeBytesToString(Data).Replace(#13,'').Replace(#10,'');
      end;
    end;
    Serialized:=Root.xml;
    if Root.namespaceURI='' then
    begin
      // Some older cover wrappers omit the SVG namespace. Adding it to an
      // existing DOM node would make MSXML emit xmlns="" on its children.
      // Normalise only this root declaration in the private serialisation.
      if not Serialized.StartsWith('<svg') then raise EReadError.Create('Не удалось подготовить рисунок SVG.');
      if Assigned(Root.attributes.getNamedItem('xmlns')) then
        Serialized:=StringReplace(Serialized,' xmlns=""','',[]);
      Insert(' xmlns="http://www.w3.org/2000/svg"',Serialized,5);
    end;
    Result:=TEncoding.UTF8.GetBytes(Serialized);
  end;
  function SimpleSVG(const Root:IXMLDOMNode; const Name:string):TBytes;
  var Elements,Images:IXMLDOMNodeList; Element,Attr:IXMLDOMNode; Kind,Key,Value:string;
    Image:TBytesStream; Width,Height,HrefCount:Integer; Bounds:TArray<string>;
  begin
    Result:=nil; Images:=Root.selectNodes('.//*[local-name()="image"]');
    if Images.length<>1 then Exit;
    Elements:=Root.selectNodes('descendant-or-self::*');
    for var I:=0 to Elements.length-1 do
    begin
      Check; Element:=Elements.item[I]; Kind:=LowerCase(Element.baseName);
      if Pos('|'+Kind+'|','|svg|g|image|title|desc|')=0 then Exit;
      for var J:=0 to Element.attributes.length-1 do
      begin
        Attr:=Element.attributes.item[J]; Key:=LowerCase(Attr.baseName); Value:=Trim(Attr.text);
        if (Attr.namespaceURI='http://www.w3.org/2000/xmlns/') or (Attr.nodeName='xmlns') or
          (Key='id') or (Key='href') or (Key='version') or (Key='width') or (Key='height') or
          (Key='viewbox') or ((Key='x') and ((Value='') or (Value='0'))) or
          ((Key='y') and ((Value='') or (Value='0'))) or
          ((Key='preserveaspectratio') and ((Value='') or (Value='xMidYMid meet'))) then Continue;
        Exit;
      end;
    end;
    HrefCount:=0;
    for var I:=0 to Images.item[0].attributes.length-1 do
      if SameText(Images.item[0].attributes.item[I].baseName,'href') then Inc(HrefCount);
    if HrefCount<>1 then Exit;
    Value:=Attribute(Images.item[0],'href'); if Value='' then Exit;
    Result:=ReadEntry(Resolve(Name,Value),MaxCover); if PictureMime(Result)='' then begin Result:=nil; Exit; end;
    Image:=TBytesStream.Create(Result);
    try ImageDimensions(Image,Width,Height); finally Image.Free; end;
    Value:=Attribute(Root,'viewBox');
    if Value<>'' then
    begin
      Bounds:=TRegEx.Split(Trim(Value),'[\s,]+');
      if (Length(Bounds)<>4) or (Bounds[0]<>'0') or (Bounds[1]<>'0') or
        (StrToFloatDef(Bounds[2],-1,TFormatSettings.Invariant)<>Width) or
        (StrToFloatDef(Bounds[3],-1,TFormatSettings.Invariant)<>Height) then begin Result:=nil; Exit; end;
    end;
    for var Axis in TArray<string>.Create('width','height') do
    begin
      Value:=Attribute(Images.item[0],Axis);
      var Expected:=Width; if Axis='height' then Expected:=Height;
      if (Value<>'') and (Value<>'100%') and
        (StrToFloatDef(Value,-1,TFormatSettings.Invariant)<>Expected) then begin Result:=nil; Exit; end;
    end;
  end;
  function ImagePart(const Name:string; Depth:Integer):TBytes;
  var Doc:IXMLDOMDocument3; Images,Drawings,Instructions:IXMLDOMNodeList; Ref,ImageExt:string;
    Drawing:IXMLDOMNode;
  begin
    Result:=nil; Check;
    if Depth>2 then raise EReadError.Create('Слишком много переходов к обложке.');
    if Seen.IndexOf(Name)>=0 then raise EReadError.Create('Зацикленная ссылка на обложку.');
    Seen.Add(Name);
    try
      Result:=ReadEntry(Name,MaxCover); if Length(Result)=0 then Exit;
      if PictureMime(Result)<>'' then Exit;
      ImageExt:=LowerCase(ExtractFileExt(Name));
      if (ImageExt<>'.xhtml') and (ImageExt<>'.html') and (ImageExt<>'.htm') and
        (ImageExt<>'.svg') and (ImageExt<>'.xml') then Exit;
      Doc:=XML(Result); Result:=nil;
      if Assigned(RenderSVG) then
      begin
        Drawing:=nil;
        if SameText(Doc.documentElement.baseName,'svg') then Drawing:=Doc.documentElement
        else
        begin
          Drawings:=Doc.selectNodes('//*[local-name()="svg"]');
          if Drawings.length=1 then Drawing:=Drawings.item[0];
        end;
        if Assigned(Drawing) then
        begin
          // The detached element does not carry document-level stylesheets.
          // Do not silently render a different cover after dropping one.
          Instructions:=Doc.selectNodes('//processing-instruction()');
          for var I:=0 to Instructions.length-1 do
            if Instructions.item[I].nodeName<>'xml' then
              raise EReadError.Create('Векторная обложка использует отдельное оформление, которое пока нельзя показать.');
          Result:=SimpleSVG(Drawing,Name); if Length(Result)>0 then Exit;
          Result:=RenderSVG(PreparedSVG(Drawing,Name)); Exit;
        end;
      end;
      Images:=Doc.selectNodes('//*[local-name()="img" or local-name()="image"]');
      for var I:=0 to Images.length-1 do
      begin
        Check; if I>=32 then Break;
        Ref:=Attribute(Images.item[I],'src'); if Ref='' then Ref:=Attribute(Images.item[I],'href');
        if Ref='' then Continue;
        try
          Result:=ImagePart(Resolve(Name,Ref),Depth+1);
          if Length(Result)>0 then Exit;
        except on E:EReadError do Status:=E.Message; end;
      end;
      // Pure vector SVG requires a separate renderer. Never hand an SVG with
      // unresolved external resources to an image decoder as an ordinary bitmap.
      if ImageExt='.svg' then Status:='Для векторных обложек установите модуль KFX/AZW8 с обработчиком SVG.';
    finally Seen.Delete(Seen.Count-1); end;
  end;
  procedure Candidate(const Base,Reference:string);
  var Name:string;
  begin
    if Candidates.Count>=32 then Exit;
    try
      Name:=Resolve(Base,Reference);
      if Candidates.IndexOf(Name)<0 then Candidates.Add(Name);
    except on E:EReadError do Status:=E.Message; end;
  end;
begin
  Result:=nil; Status:=''; if not Assigned(Stream) or not IsBookCoverPackage(Extension) then Exit;
  Saved:=Stream.Position; Zip:=nil; Candidates:=nil; Seen:=nil;
  HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try
    try
      Check; Candidates:=TStringList.Create; Candidates.CaseSensitive:=True;
      Seen:=TStringList.Create; Seen.CaseSensitive:=True;
      Zip:=TZipFile.Create; Stream.Position:=0; Zip.Open(Stream,zmRead);
      if Zip.FileCount>200000 then raise EReadError.Create('В книге слишком много файлов для предпросмотра.');
      Ext:=LowerCase(Extension).TrimLeft(['.']);
      UsesOPC:=(Ext<>'epub') and not Ext.StartsWith('od') and not Ext.StartsWith('ot');
      if Ext='epub' then
      begin
        Container:=XML(ReadEntry('META-INF/container.xml',MaxXML));
        Nodes:=Container.selectNodes('/*[local-name()="container"]/*[local-name()="rootfiles"]/*[local-name()="rootfile"]');
        PackagePath:='';
        for var I:=0 to Nodes.length-1 do
          if Attribute(Nodes.item[I],'media-type')='application/oebps-package+xml' then
          begin PackagePath:=Resolve('',Attribute(Nodes.item[I],'full-path')); Break; end;
        if (PackagePath='') and (Nodes.length=1) then PackagePath:=Resolve('',Attribute(Nodes.item[0],'full-path'));
        if PackagePath='' then raise EReadError.Create('В EPUB не найдено описание книги.');
        PackageDoc:=XML(ReadEntry(PackagePath,MaxXML)); CoverID:='';
        Nodes:=PackageDoc.selectNodes('/*[local-name()="package"]/*[local-name()="metadata"]/*[local-name()="meta"]');
        for var I:=0 to Nodes.length-1 do
          if SameText(Attribute(Nodes.item[I],'name'),'cover') then
          begin CoverID:=Attribute(Nodes.item[I],'content'); Break; end;
        Manifest:=PackageDoc.selectNodes('/*[local-name()="package"]/*[local-name()="manifest"]/*[local-name()="item"]');
        for var I:=0 to Manifest.length-1 do
        begin
          Check; Node:=Manifest.item[I];
          if (Pos(' cover-image ',' '+TRegEx.Replace(Attribute(Node,'properties'),'\s+',' ')+' ')>0) or
            ((CoverID<>'') and (Attribute(Node,'id')=CoverID)) then Candidate(PackagePath,Attribute(Node,'href'));
        end;
        Guide:=PackageDoc.selectNodes('/*[local-name()="package"]/*[local-name()="guide"]/*[local-name()="reference"]');
        for var I:=0 to Guide.length-1 do
          if SameText(Attribute(Guide.item[I],'type'),'cover') then Candidate(PackagePath,Attribute(Guide.item[I],'href'));
      end
      else if Ext.StartsWith('od') or Ext.StartsWith('ot') then
        Candidate('','Thumbnails/thumbnail.png')
      else
      begin
        var Bytes:=ReadEntry('_rels/.rels',MaxXML);
        if Length(Bytes)>0 then
        begin
          Relations:=XML(Bytes); Nodes:=Relations.selectNodes('/*[local-name()="Relationships"]/*[local-name()="Relationship"]');
          for var I:=0 to Nodes.length-1 do
          begin
            Node:=Nodes.item[I]; Check;
            if Attribute(Node,'Type').EndsWith('/metadata/thumbnail') and
              not SameText(Attribute(Node,'TargetMode'),'External') then
            begin
              // OPC permits package-root-relative part names. This is not a
              // filesystem path; reject network paths before removing one '/'.
              var Target:=Attribute(Node,'Target');
              if Target.StartsWith('/') and not Target.StartsWith('//') then Delete(Target,1,1);
              Candidate('',Target);
            end;
          end;
        end;
      end;
      for Part in Candidates do
      begin
        Check;
        try
          Result:=ImagePart(Part,0);
          if Length(Result)>0 then begin Status:=''; Exit; end;
        except on E:EReadError do Status:=E.Message; end;
      end;
      if Status='' then Status:='В файле нет встроенной обложки или миниатюры.';
    except
      on E:EAbort do raise;
      on E:EOutOfMemory do raise;
      on E:EExternalException do raise;
      on E:Exception do begin Result:=nil; Status:='Не удалось прочитать обложку: '+E.Message; end;
    end;
  finally
    Node:=nil; Nodes:=nil; Manifest:=nil; Guide:=nil;
    Container:=nil; PackageDoc:=nil; Relations:=nil;
    Zip.Free; Seen.Free; Candidates.Free; Stream.Position:=Saved;
    if Succeeded(HR) then CoUninitialize;
  end;
end;

end.
