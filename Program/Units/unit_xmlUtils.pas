(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Nick Rymanov (nrymanov@gmail.com)
  * Created             13.07.2010
  * Description
  *
  * $Id: unit_xmlUtils.pas 1064 2011-09-02 11:33:04Z eg_ $
  *
  * History
  *
  ****************************************************************************** *)

unit unit_xmlUtils;

interface

uses
  Classes,
  SysUtils,
  msxml,
  msxmldom,
  xmldom,
  XMLConst;

type
  TMSXMLHelper = class
  private
    class function newDocument: IXMLDOMDocument;

  public
    class function CreateEmptyDocument: IXMLDOMDocument;
    class function LoadFromZFile(const FileName: string): IXMLDOMDocument;
    class function LoadFromFile(const FileName: string; Compressed: Boolean;
      PreserveWhiteSpace: Boolean = False): IXMLDOMDocument;
    class procedure SaveToZFile(xmlDoc: IXMLDOMDocument; const FileName: string);
    class procedure SaveToFile(xmlDoc: IXMLDOMDocument; const FileName: string; Compressed: Boolean);
  end;

  EMSXMLParseError = class(Exception)
  private
    FParseError: IXMLDOMParseError;
    function GetFilePos: Integer;
    function GetLine: Integer;
    function GetLinePos: Integer;
    function GetReason: DOMString;
    function GetSrcText: DOMString;
    function GetURL: DOMString;
    function GetErrorCode: Integer;

  protected
    property ParseError: IXMLDOMParseError read FParseError;

  public
    constructor Create(const ParseError: IXMLDOMParseError; const Msg: string);

    property ErrorCode: Integer read GetErrorCode;
    property URL: DOMString read GetURL;
    property Reason: DOMString read GetReason;
    property SrcText: DOMString read GetSrcText;
    property Line: Integer read GetLine;
    property LinePos: Integer read GetLinePos;
    property FilePos: Integer read GetFilePos;
  end;

implementation

uses
  Winapi.Windows,
  Variants,
  ActiveX,
  ZLib;


class function TMSXMLHelper.LoadFromZFile(const FileName: string): IXMLDOMDocument;
begin Result:=LoadFromFile(FileName,True); end;

class function TMSXMLHelper.LoadFromFile(const FileName: string; Compressed,
  PreserveWhiteSpace: Boolean): IXMLDOMDocument;
var
  fileStream: TFileStream; zipStream: TZDecompressionStream; Input: TStream;
  vIn: OleVariant; xmlDoc: IXMLDOMDocument; ParseError: IXMLDOMParseError; Msg: string;
begin
  fileStream:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    zipStream:=nil; Input:=fileStream;
    try
      if Compressed then begin zipStream:=TZDecompressionStream.Create(fileStream); Input:=zipStream; end;
      vIn:=TStreamAdapter.Create(Input) as IStream;
      try
        xmlDoc:=newDocument; xmlDoc.preserveWhiteSpace:=PreserveWhiteSpace;
        if not xmlDoc.load(vIn) then
        begin
          ParseError:=xmlDoc.parseError;
          Msg:=Format('%s%s%s: %d%s%s',[ParseError.reason,SLineBreak,SLine,
            ParseError.line,SLineBreak,Copy(ParseError.srcText,1,40)]);
          raise EMSXMLParseError.Create(ParseError,Msg);
        end;
        Result:=xmlDoc;
      finally vIn:=Unassigned; end;
    finally zipStream.Free; end;
  finally fileStream.Free; end;
end;

class function TMSXMLHelper.newDocument: IXMLDOMDocument;
var
  Document2: IXMLDOMDocument2;
begin
  Result := msxmldom.MSXMLDOMDocumentFactory.CreateDOMDocument;
  Result.async := False;
  // Imported books are untrusted input: never resolve external entities and
  // reject DTDs where the installed MSXML version exposes that switch.
  Result.resolveExternals := False;
  Result.validateOnParse := False;
  if Supports(Result, IXMLDOMDocument2, Document2) then
    try
      Document2.setProperty('ProhibitDTD', True);
    except
      on E: Exception do
        ;
    end;
end;

class function TMSXMLHelper.CreateEmptyDocument: IXMLDOMDocument;
begin
  Result := newDocument;

  Result.appendChild(Result.createProcessingInstruction('xml', 'version="1.0" encoding="UTF-8"'));
end;

class procedure TMSXMLHelper.SaveToZFile(xmlDoc: IXMLDOMDocument; const FileName: string);
begin SaveToFile(xmlDoc,FileName,True); end;

class procedure TMSXMLHelper.SaveToFile(xmlDoc: IXMLDOMDocument; const FileName: string; Compressed: Boolean);
var
  fileStream: THandleStream;
  zipStream: TZCompressionStream;
  Output: TStream;
  vOut: OleVariant;
  TempID: TGUID;
  TempName: string;
  FileHandle: THandle;
  OwnTemp: Boolean;
begin
  if not Assigned(xmlDoc) then
    raise EArgumentNilException.Create('xmlDoc');

  CreateGUID(TempID);
  TempName := FileName + '.homelib-' + GUIDToString(TempID) + '.tmp';
  FileHandle := CreateFile(PChar(TempName), GENERIC_READ or GENERIC_WRITE, 0,
    nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  OwnTemp := True;
  try
    try
      fileStream := THandleStream.Create(FileHandle);
      try
        zipStream := nil; Output := fileStream;
        try
          if Compressed then
          begin zipStream := TZCompressionStream.Create(fileStream); Output := zipStream; end;
          vOut := TStreamAdapter.Create(Output) as IStream;
          try
            xmlDoc.save(vOut);
          finally
            vOut := Unassigned;
          end;
        finally
          // The zlib footer must be written before flushing and publication.
          zipStream.Free;
        end;
      finally
        fileStream.Free;
      end;
      if not FlushFileBuffers(FileHandle) then
        RaiseLastOSError;
    finally
      CloseHandle(FileHandle);
    end;

    // The temporary file is adjacent, so publication remains on one volume.
    // Failure (including a locked target) leaves the old complete file intact.
    if not MoveFileEx(PChar(TempName), PChar(FileName),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
    OwnTemp := False;
  finally
    if OwnTemp then
      Winapi.Windows.DeleteFile(PChar(TempName));
  end;
end;


constructor EMSXMLParseError.Create(const ParseError: IXMLDOMParseError; const Msg: string);
begin
  FParseError := ParseError;
  inherited Create(Msg);
end;

function EMSXMLParseError.GetErrorCode: Integer;
begin
  Result := ParseError.errorCode;
end;

function EMSXMLParseError.GetFilePos: Integer;
begin
  Result := ParseError.filepos;
end;

function EMSXMLParseError.GetLine: Integer;
begin
  Result := ParseError.line;
end;

function EMSXMLParseError.GetLinePos: Integer;
begin
  Result := ParseError.linepos;
end;

function EMSXMLParseError.GetReason: DOMString;
begin
  Result := ParseError.reason;
end;

function EMSXMLParseError.GetSrcText: DOMString;
begin
  Result := ParseError.srcText;
end;

function EMSXMLParseError.GetURL: DOMString;
begin
  Result := ParseError.url;
end;

end.
