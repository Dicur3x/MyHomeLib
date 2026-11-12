unit unit_PackageBookCover;

interface

uses System.Classes, System.SysUtils;

function IsBookCoverPackage(const Extension: string): Boolean;
// Reads only declared cover/thumbnail parts. It never renders the book, follows
// external links, or selects an arbitrary illustration as a cover.
function ReadPackageBookCover(Stream: TStream; const Extension: string;
  out Status: string; const IsCanceled: TFunc<Boolean> = nil): TBytes;

implementation

uses System.Zip, System.Variants, System.Win.ComObj, System.NetEncoding,
  System.RegularExpressions, Winapi.Windows, Winapi.ActiveX, Winapi.MSXML;

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
  out Status: string; const IsCanceled: TFunc<Boolean>): TBytes;
var Zip:TZipFile; Saved:Int64; HR:HRESULT; Ext,PackagePath,CoverID,Part:string;
  Container,PackageDoc,Relations:IXMLDOMDocument3;
  Nodes,Manifest,Guide:IXMLDOMNodeList; Node:IXMLDOMNode;
  Candidates,Seen:TStringList;
  procedure Check;
  begin if Assigned(IsCanceled) and IsCanceled() then Abort; end;
  function EntryIndex(const Name:string):Integer;
  begin
    Result:=-1;
    for var I:=0 to Zip.FileCount-1 do
    begin
      if I mod 256=0 then Check;
      if Zip.FileNames[I]<>Name then Continue;
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
  function ImagePart(const Name:string; Depth:Integer):TBytes;
  var Doc:IXMLDOMDocument3; Images:IXMLDOMNodeList; Ref,ImageExt:string;
  begin
    Result:=nil; Check;
    if Depth>2 then raise EReadError.Create('Слишком много переходов к обложке.');
    if Seen.IndexOf(Name)>=0 then raise EReadError.Create('Зацикленная ссылка на обложку.');
    Seen.Add(Name);
    try
      Result:=ReadEntry(Name,MaxCover); if Length(Result)=0 then Exit;
      ImageExt:=LowerCase(ExtractFileExt(Name));
      if (ImageExt<>'.xhtml') and (ImageExt<>'.html') and (ImageExt<>'.htm') and
        (ImageExt<>'.svg') and (ImageExt<>'.xml') then Exit;
      Doc:=XML(Result); Result:=nil;
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
      if ImageExt='.svg' then Status:='Для этой векторной обложки пока нет предпросмотра.';
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
