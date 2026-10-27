(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author Oleksiy Penkov   oleksiy.penkov@gmail.com
  *
  ****************************************************************************** *)
unit unit_fb2ToText;

interface

uses
  Classes,
  Windows,
  SysUtils,
  unit_globals;

type
  TFb2ToText = class
  private
    function ConvertEncoding(ResEncoding: TTXTEncoding): TEncoding;
  public
    procedure Convert(const FileOut: string; ResEncoding: TTXTEncoding; Stream: TStream);
  end;

implementation

uses Winapi.ActiveX, Winapi.MSXML, System.Win.ComObj;

procedure TFb2ToText.Convert(const FileOut: string; ResEncoding: TTXTEncoding; Stream: TStream);
var Document: IXMLDOMDocument3; Bodies: IXMLDOMNodeList; Input: IStream; Lines: TStringList;
  SavedPosition: Int64; Temporary: string; COMInitialized: Boolean;
  procedure Visit(const Node: IXMLDOMNode);
  var Child: IXMLDOMNode; Name: string;
  begin
    if not Assigned(Node) then Exit;
    Name:=LowerCase(Node.baseName);
    if (Name='p') or (Name='v') or (Name='subtitle') or (Name='text-author') or
      (Name='td') or (Name='th') then
    begin Lines.Add(Node.text); Exit; end;
    if Name='empty-line' then begin Lines.Add(''); Exit; end;
    Child:=Node.firstChild;
    while Assigned(Child) do begin Visit(Child); Child:=Child.nextSibling; end;
  end;
begin
  if not Assigned(Stream) then raise EArgumentNilException.Create('Stream');
  if FileExists(FileOut) then raise EInOutError.Create('Файл результата уже существует: '+FileOut);
  SavedPosition:=Stream.Position; Lines:=TStringList.Create; Temporary:='';
  COMInitialized:=Succeeded(CoInitializeEx(nil,COINIT_APARTMENTTHREADED));
  try
    Stream.Position:=0;
    Document:=CreateOleObject('Msxml2.DOMDocument.6.0') as IXMLDOMDocument3;
    Document.async:=False; Document.validateOnParse:=False; Document.resolveExternals:=False;
    Document.preserveWhiteSpace:=True; Document.setProperty('ProhibitDTD',True);
    // MSXML reads the declared XML encoding directly from the byte stream.
    // Paragraphs and inline text do not depend on physical source line breaks.
    Input:=TStreamAdapter.Create(Stream,soReference) as IStream;
    if not Document.load(Input) then raise EReadError.Create('Не удалось прочитать FB2: '+Trim(Document.parseError.reason));
    Bodies:=Document.selectNodes('/*[local-name()="FictionBook"]/*[local-name()="body"]');
    for var I:=0 to Bodies.length-1 do Visit(Bodies.item[I]);
    if Trim(Lines.Text)='' then raise EReadError.Create('В книге нет распознанного текста для TXT. Для сканов сначала нужно распознавание текста.');
    Temporary:=FileOut+'.homelib-new-'+TGUID.NewGuid.ToString;
    Lines.SaveToFile(Temporary,ConvertEncoding(ResEncoding));
    if not MoveFile(PChar(Temporary),PChar(FileOut)) then RaiseLastOSError;
    Temporary:='';
  finally
    Bodies:=nil; Input:=nil; Document:=nil;
    if COMInitialized then CoUninitialize;
    if (Temporary<>'') and FileExists(Temporary) then SysUtils.DeleteFile(Temporary);
    Stream.Position:=SavedPosition; Lines.Free;
  end;
end;

function TFb2ToText.ConvertEncoding(ResEncoding: TTXTEncoding): TEncoding;
begin
  case ResEncoding of
    enUTF8: Result:=TEncoding.UTF8;
    en1251: Result:=TEncoding.ANSI;
    enUnicode: Result:=TEncoding.Unicode;
  else Result:=TEncoding.ASCII;
  end;
end;

end.
