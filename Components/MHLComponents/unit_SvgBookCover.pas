unit unit_SvgBookCover;

interface

uses System.SysUtils, Winapi.MSXML;

function StaticSvgRasterMime(const Data: TBytes): string;
procedure EmbedStaticSvgRaster(const Attribute: IXMLDOMNode; const Data: TBytes);
function SerializeStaticSvg(const Root: IXMLDOMElement): TBytes;

// Accept only a self-contained static drawing. The package reader embeds its
// declared local raster resources before calling this bounded renderer.
function RenderSvgBookCover(const SVG: TBytes; const ToolPath, TempRoot: string;
  const IsCanceled: TFunc<Boolean> = nil): TBytes;
function RenderStaticSvg(const SVG: TBytes; const ToolPath, TempRoot: string;
  MaxWidth, MaxHeight: Integer; const IsCanceled: TFunc<Boolean> = nil): TBytes;

implementation

uses System.Classes, System.IOUtils, System.NetEncoding, System.RegularExpressions, System.Variants,
  System.Win.ComObj, Winapi.Windows, Winapi.ActiveX,
  unit_MHLExternalTools, unit_ImageBounds;

const SVGNamespace='http://www.w3.org/2000/svg';
  MaxDrawing=24*1024*1024;

type
  TSVGOutput=class(TMemoryStream)
    Limit: Int64;
    function Write(const Buffer; Count:Longint):Longint; override;
  end;

function TSVGOutput.Write(const Buffer; Count:Longint):Longint;
begin
  if (Count<0) or (Size+Count>Limit) then
    raise EReadError.Create('Векторная обложка вернула слишком большое изображение.');
  Result:=inherited Write(Buffer,Count);
end;

function StaticSvgRasterMime(const Data:TBytes):string;
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
      raise EReadError.Create('Изображение внутри SVG превышает допустимые размеры.');
  finally Image.Free; end;
end;

procedure EmbedStaticSvgRaster(const Attribute:IXMLDOMNode; const Data:TBytes);
var Mime:string;
begin
  if Length(Data)=0 then raise EReadError.Create('В книге отсутствует изображение внутри SVG.');
  Mime:=StaticSvgRasterMime(Data);
  if Mime='' then raise EReadError.Create('SVG использует неподдерживаемое изображение.');
  Attribute.nodeValue:='data:'+Mime+';base64,'+TNetEncoding.Base64.EncodeBytesToString(Data).Replace(#13,'').Replace(#10,'');
end;

function SerializeStaticSvg(const Root:IXMLDOMElement):TBytes;
var Serialized:string;
begin
  // MSXML copies inherited namespace bindings onto the detached clone.
  Serialized:=Root.xml;
  if Root.namespaceURI='' then
  begin
    // Start with one default namespace to avoid generating xmlns="" on
    // descendants of older wrappers that omit the SVG namespace entirely.
    if not Serialized.StartsWith('<svg') then raise EReadError.Create('Не удалось подготовить рисунок SVG.');
    if Assigned(Root.attributes.getNamedItem('xmlns')) then
      Serialized:=StringReplace(Serialized,' xmlns=""','',[]);
    Insert(' xmlns="'+SVGNamespace+'"',Serialized,5);
  end;
  Result:=TEncoding.UTF8.GetBytes(Serialized);
end;

procedure CheckFragment(const Reference:string);
var Ref:string;
begin
  Ref:=Trim(Reference);
  if (Length(Ref)<2) or not Ref.StartsWith('#') or
    TRegEx.IsMatch(Ref,'[\s"''()\\]') then
    raise EReadError.Create('Векторная обложка ссылается на внешний ресурс.');
end;

procedure CheckCSS(const Text:string);
var CSS,Ref:string; URLs: TMatchCollection;
begin
  if not Text.Contains('/*') and not Text.Contains('\') and not Text.Contains('@') and
    not LowerCase(Text).Contains('url') then Exit;
  CSS:=TRegEx.Replace(Text,'/\*.*?\*/','',[roSingleLine]);
  if CSS.Contains('\') or TRegEx.IsMatch(CSS,'@\s*import',[roIgnoreCase]) then
    raise EReadError.Create('Векторная обложка использует внешнее или недоступное оформление.');
  URLs:=TRegEx.Matches(CSS,'url\s*\((.*?)\)',[roIgnoreCase,roSingleLine]);
  if URLs.Count<>TRegEx.Matches(CSS,'url\s*\(',[roIgnoreCase]).Count then
    raise EReadError.Create('Векторная обложка содержит незавершённую ссылку ресурса.');
  for var Match in URLs do
  begin
    Ref:=Trim(Match.Groups[1].Value);
    if (Length(Ref)>1) and ((Ref[1]='"') or (Ref[1]='''')) and
      (Ref[Length(Ref)]=Ref[1]) then Ref:=Copy(Ref,2,Length(Ref)-2);
    CheckFragment(Ref);
  end;
end;

procedure ValidateDrawing(const Data:TBytes; const Check:TProc; out UsesFonts:Boolean);
var Doc:IXMLDOMDocument3; Nodes:IXMLDOMNodeList; Node,Attr:IXMLDOMNode;
  Buffer:TBytesStream; Input:OleVariant; Kind,Name,Value:string;
begin
  UsesFonts:=False;
  if (Length(Data)=0) or (Length(Data)>MaxDrawing) then
    raise EReadError.Create('Векторная обложка превышает допустимый размер.');
  Doc:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
  Doc.async:=False; Doc.resolveExternals:=False; Doc.validateOnParse:=False;
  Doc.setProperty('ProhibitDTD',True); Doc.setProperty('MaxXMLSize',32768);
  Doc.setProperty('MaxElementDepth',128);
  Buffer:=TBytesStream.Create(Data);
  try
    Input:=TStreamAdapter.Create(Buffer,soReference) as IStream;
    try
      if not Doc.load(Input) then raise EReadError.Create('Не удалось прочитать рисунок SVG.');
    finally Input:=Unassigned; end;
  finally Buffer.Free; end;
  if not Assigned(Doc.documentElement) or (Doc.documentElement.baseName<>'svg') or
    ((Doc.documentElement.namespaceURI<>'') and (Doc.documentElement.namespaceURI<>SVGNamespace)) then
    raise EReadError.Create('Обложка не содержит рисунка SVG.');
  Nodes:=Doc.selectNodes('//processing-instruction()');
  for var I:=0 to Nodes.length-1 do
    if Nodes.item[I].nodeName<>'xml' then
      raise EReadError.Create('Векторная обложка использует внешнее оформление.');
  Nodes:=Doc.selectNodes('//*');
  if Nodes.length>50000 then raise EReadError.Create('Векторная обложка слишком сложная.');
  for var I:=0 to Nodes.length-1 do
  begin
    Check(); Node:=Nodes.item[I]; Kind:=LowerCase(Node.baseName);
    if (Kind='text') or (Kind='tspan') or (Kind='textpath') then UsesFonts:=True;
    if Pos('|'+Kind+'|','|script|foreignobject|iframe|object|embed|')>0 then
      raise EReadError.Create('Для предпросмотра нужна статическая векторная обложка.');
    if Kind='style' then CheckCSS(Node.text);
    for var J:=0 to Node.attributes.length-1 do
    begin
      Attr:=Node.attributes.item[J]; Name:=LowerCase(Attr.baseName); Value:=Attr.text;
      if (Attr.namespaceURI='http://www.w3.org/2000/xmlns/') or (Attr.nodeName='xmlns') then Continue;
      if Name.StartsWith('on') or (Name='base') then
        raise EReadError.Create('Векторная обложка использует активные или внешние ресурсы.');
      if (Name='href') or (Name='src') then
      begin
        if Kind='a' then Continue; // Static rasterisation never follows a link.
        if Value.StartsWith('data:image/png;base64,') or Value.StartsWith('data:image/jpeg;base64,') or
          Value.StartsWith('data:image/gif;base64,') or Value.StartsWith('data:image/webp;base64,') then
        begin
          if (Kind<>'image') and (Kind<>'feimage') then
            raise EReadError.Create('Недопустимая ссылка ресурса векторной обложки.');
        end
        else CheckFragment(Value);
      end;
      CheckCSS(Value);
    end;
  end;
end;

function RenderSvgBookCover(const SVG:TBytes; const ToolPath,TempRoot:string;
  const IsCanceled:TFunc<Boolean>):TBytes;
begin
  Result:=RenderStaticSvg(SVG,ToolPath,TempRoot,600,800,IsCanceled);
end;

function RenderStaticSvg(const SVG:TBytes; const ToolPath,TempRoot:string;
  MaxWidth,MaxHeight:Integer; const IsCanceled:TFunc<Boolean>):TBytes;
var Work,InputFile,Root:string; Data:TSVGOutput; Started,LastSpace:UInt64;
  CheckCanceled:TFunc<Boolean>; Width,Height:Integer; HR:HRESULT; UsesFonts:Boolean; Args:TArray<string>;
  procedure Check;
  begin if CheckCanceled() then Abort; end;
begin
  Result:=nil; Work:=''; InputFile:=''; Started:=GetTickCount64; LastSpace:=0;
  if (MaxWidth<=0) or (MaxHeight<=0) or (MaxWidth>4096) or (MaxHeight>4096) or
    (Int64(MaxWidth)*MaxHeight>2048*2048) then
    raise EReadError.Create('Недопустимые размеры рисунка SVG.');
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  if not FileExists(ToolPath) then
    raise EReadError.Create('Для рисунков SVG установите модуль KFX/AZW8 с обработчиком SVG.');
  Root:=TPath.GetFullPath(TempRoot);
  CheckCanceled:=function:Boolean
    var Available,Capacity,Now:UInt64;
    begin
      Result:=Assigned(IsCanceled) and IsCanceled(); if Result then Exit;
      Now:=GetTickCount64;
      if Now-Started>30000 then raise EReadError.Create('Предпросмотр SVG превысил 30 секунд.');
      if (LastSpace=0) or (Now-LastSpace>=1000) then
      begin
        LastSpace:=Now;
        if not GetDiskFreeSpaceEx(PChar(GetEnvironmentVariable('SystemDrive')+'\'),Available,Capacity,nil) then RaiseLastOSError;
        if Available<UInt64(8)*1024*1024*1024 then raise EWriteError.Create('Для предпросмотра нужно оставить 8 ГБ на системном диске.');
        if not GetDiskFreeSpaceEx(PChar(Root),Available,Capacity,nil) then RaiseLastOSError;
        if Available<64*1024*1024 then raise EWriteError.Create('Недостаточно места для предпросмотра SVG.');
      end;
    end;
  ForceDirectories(Root); Check; HR:=CoInitializeEx(nil,COINIT_APARTMENTTHREADED);
  try ValidateDrawing(SVG,procedure begin if CheckCanceled() then Abort; end,UsesFonts);
  finally if Succeeded(HR) then CoUninitialize; end;
  Work:=TPath.Combine(Root,'homelibre-svg-cover-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(Work),nil) then RaiseLastOSError;
  InputFile:=TPath.Combine(Work,'cover.svg');
  try
    TFile.WriteAllBytes(InputFile,SVG); Data:=TSVGOutput.Create;
    try
      Data.Limit:=Int64(MaxWidth)*MaxHeight*4+1024*1024;
      Args:=TArray<string>.Create('--quiet','--width',IntToStr(MaxWidth),'--height',IntToStr(MaxHeight));
      if not UsesFonts then Args:=Args+['--skip-system-fonts'];
      Args:=Args+[InputFile,'-c'];
      try
        RunExternalToolToStream(ToolPath,Args,Data,CheckCanceled,0,True,NativeUInt(512)*1024*1024);
      except on E:EMHLExternalToolError do raise EReadError.Create('Не удалось отрисовать векторную обложку.'); end;
      Check;
      if not ImageDimensions(Data,Width,Height) or (Width>MaxWidth) or (Height>MaxHeight) then
        raise EReadError.Create('Обработчик SVG вернул недопустимое изображение.');
      SetLength(Result,Data.Size);
      if Length(Result)>0 then Move(Data.Memory^,Result[0],Length(Result));
    finally Data.Free; end;
  finally
    if (GetFileAttributes(PChar(Work))<>INVALID_FILE_ATTRIBUTES) and
      (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
    begin Winapi.Windows.DeleteFile(PChar(InputFile)); RemoveDirectory(PChar(Work)); end;
  end;
end;

end.
