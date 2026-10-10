unit unit_ReaderRichEdit;

interface

uses Winapi.Windows, System.Classes, Vcl.ComCtrls;

procedure ReaderLoadRTF(Edit: TRichEdit; Stream: TStream);

function AttachReaderPictures(Edit: TRichEdit): IInterface;
function ReaderPictureCount(Edit: TRichEdit): Integer;
function ReaderTextLength(Edit: TRichEdit): Integer;
function ReaderTextRange(Edit: TRichEdit; Start, Count: Integer): string;
function ReaderCharacterStart(Edit: TRichEdit; Position: Integer): Integer;

implementation

uses Winapi.ActiveX, Winapi.RichEdit, System.SysUtils, System.Math;

type
  // Prefix and method order follow the Windows SDK richole.h interface.
  IReaderOleObjects = interface(IUnknown)
    ['{00020D00-0000-0000-C000-000000000046}']
    function GetClientSite(out Site: IOleClientSite): HResult; stdcall;
    function GetObjectCount: Integer; stdcall;
  end;

  IReaderOleCallback = interface(IUnknown)
    ['{00020D03-0000-0000-C000-000000000046}']
    function GetNewStorage(out Storage: IStorage): HResult; stdcall;
    function GetInPlaceContext(out Frame: IOleInPlaceFrame; out Document: IOleInPlaceUIWindow;
      var Info: TOleInPlaceFrameInfo): HResult; stdcall;
    function ShowContainerUI(Show: BOOL): HResult; stdcall;
    function QueryInsertObject(const ID: TGUID; const Storage: IStorage; Position: Longint): HResult; stdcall;
    function DeleteObject(const OleObject: IOleObject): HResult; stdcall;
    function QueryAcceptData(const Data: IDataObject; var Format: Word; Operation: DWORD;
      Real: BOOL; MetaPicture: HGLOBAL): HResult; stdcall;
    function ContextSensitiveHelp(Enter: BOOL): HResult; stdcall;
    function GetClipboardData(var Range: TCharRange; Operation: DWORD; out Data: IDataObject): HResult; stdcall;
    function GetDragDropEffect(Drag: BOOL; Keys: DWORD; var Effect: DWORD): HResult; stdcall;
    function GetContextMenu(Selection: Word; const OleObject: IOleObject;
      var Range: TCharRange; out Menu: HMENU): HResult; stdcall;
  end;

  TReaderOleCallback = class(TInterfacedObject, IReaderOleCallback)
    function GetNewStorage(out Storage: IStorage): HResult; stdcall;
    function GetInPlaceContext(out Frame: IOleInPlaceFrame; out Document: IOleInPlaceUIWindow;
      var Info: TOleInPlaceFrameInfo): HResult; stdcall;
    function ShowContainerUI(Show: BOOL): HResult; stdcall;
    function QueryInsertObject(const ID: TGUID; const Storage: IStorage; Position: Longint): HResult; stdcall;
    function DeleteObject(const OleObject: IOleObject): HResult; stdcall;
    function QueryAcceptData(const Data: IDataObject; var Format: Word; Operation: DWORD;
      Real: BOOL; MetaPicture: HGLOBAL): HResult; stdcall;
    function ContextSensitiveHelp(Enter: BOOL): HResult; stdcall;
    function GetClipboardData(var Range: TCharRange; Operation: DWORD; out Data: IDataObject): HResult; stdcall;
    function GetDragDropEffect(Drag: BOOL; Keys: DWORD; var Effect: DWORD): HResult; stdcall;
    function GetContextMenu(Selection: Word; const OleObject: IOleObject;
      var Range: TCharRange; out Menu: HMENU): HResult; stdcall;
  end;

function TReaderOleCallback.GetNewStorage(out Storage: IStorage): HResult;
var Bytes: ILockBytes;
begin
  Storage:=nil;
  Result:=CreateILockBytesOnHGlobal(0,True,Bytes);
  if Failed(Result) then Exit;
  // In-memory picture storage, discarded with the reader; no source writes.
  Result:=StgCreateDocfileOnILockBytes(Bytes,STGM_CREATE or STGM_READWRITE or STGM_SHARE_EXCLUSIVE,0,Storage);
end;

function TReaderOleCallback.GetInPlaceContext(out Frame: IOleInPlaceFrame;
  out Document: IOleInPlaceUIWindow; var Info: TOleInPlaceFrameInfo): HResult;
begin Frame:=nil; Document:=nil; Result:=E_NOTIMPL; end;
function TReaderOleCallback.ShowContainerUI(Show: BOOL): HResult;
begin Result:=S_OK; end;
function TReaderOleCallback.QueryInsertObject(const ID: TGUID; const Storage: IStorage; Position: Longint): HResult;
const STATIC_DIB: TGUID = '{00000316-0000-0000-C000-000000000046}';
begin
  // Read-only raster pictures only. Arbitrary OLE servers are never activated.
  if IsEqualGUID(ID,STATIC_DIB) then Result:=S_OK else Result:=E_ACCESSDENIED;
end;
function TReaderOleCallback.DeleteObject(const OleObject: IOleObject): HResult;
begin Result:=S_OK; end;
function TReaderOleCallback.QueryAcceptData(const Data: IDataObject; var Format: Word;
  Operation: DWORD; Real: BOOL; MetaPicture: HGLOBAL): HResult;
begin Result:=E_ACCESSDENIED; end;
function TReaderOleCallback.ContextSensitiveHelp(Enter: BOOL): HResult;
begin Result:=E_NOTIMPL; end;
function TReaderOleCallback.GetClipboardData(var Range: TCharRange; Operation: DWORD; out Data: IDataObject): HResult;
begin Data:=nil; Result:=E_NOTIMPL; end;
function TReaderOleCallback.GetDragDropEffect(Drag: BOOL; Keys: DWORD; var Effect: DWORD): HResult;
begin Effect:=0; Result:=S_OK; end;
function TReaderOleCallback.GetContextMenu(Selection: Word; const OleObject: IOleObject;
  var Range: TCharRange; out Menu: HMENU): HResult;
begin Menu:=0; Result:=E_NOTIMPL; end;

type
  TReaderStreamCallback = function(Cookie: NativeUInt; Buffer: Pointer; Count: Longint;
    var Copied: Longint): DWORD; stdcall;
  // Windows SDK richedit.h uses four-byte packing, including on Win64.
  TReaderStreamInfo = packed record
    Cookie: NativeUInt;
    Error: DWORD;
    Callback: TReaderStreamCallback;
  end;

function ReaderStreamRead(Cookie: NativeUInt; Buffer: Pointer; Count: Longint;
  var Copied: Longint): DWORD; stdcall;
begin
  Copied:=0; Result:=0;
  try Copied:=TStream(Pointer(Cookie)).Read(Buffer^,Count); except Result:=1; end;
end;

procedure ReaderLoadRTF(Edit: TRichEdit; Stream: TStream);
var Info: TReaderStreamInfo;
begin
  FillChar(Info,SizeOf(Info),0); Info.Cookie:=NativeUInt(Stream); Info.Callback:=ReaderStreamRead;
  // VCL string loading may guess a text encoding from raster bytes. Stream
  // binary RTF straight to RichEdit without any Unicode/ANSI conversion.
  SendMessage(Edit.Handle,EM_STREAMIN,SF_RTF,LPARAM(@Info));
  if Info.Error<>0 then raise EStreamError.Create('Не удалось загрузить текст и изображения книги.');
end;

function AttachReaderPictures(Edit: TRichEdit): IInterface;
var Callback: IReaderOleCallback;
begin
  Callback:=TReaderOleCallback.Create;
  if SendMessage(Edit.Handle,EM_SETOLECALLBACK,0,LPARAM(Pointer(Callback)))=0 then
    raise Exception.Create('Не удалось включить изображения в читалке.');
  Result:=Callback;
end;

function ReaderPictureCount(Edit: TRichEdit): Integer;
var Objects: IReaderOleObjects;
begin
  Objects:=nil;
  if SendMessage(Edit.Handle,EM_GETOLEINTERFACE,0,LPARAM(@Objects))=0 then Exit(0);
  if Objects=nil then Exit(0);
  Result:=Objects.GetObjectCount;
end;


function ReaderTextLength(Edit: TRichEdit): Integer;
type TNativeLength = record Flags, CodePage: Cardinal; end;
var Info: TNativeLength;
begin
  // Native positions use one CR per paragraph and UTF-16 code units.
  Info.Flags:=GTL_NUMCHARS or GTL_PRECISE; Info.CodePage:=1200;
  Result:=SendMessage(Edit.Handle,EM_GETTEXTLENGTHEX,WPARAM(@Info),0);
  if Result<0 then raise Exception.Create('Не удалось получить длину текста книги.');
end;

function ReaderCharacterStart(Edit: TRichEdit; Position: Integer): Integer;
var Previous, Range: TCharRange;
begin
  Result:=Max(0,Min(Position,ReaderTextLength(Edit)));
  SendMessage(Edit.Handle,EM_EXGETSEL,0,LPARAM(@Previous));
  try
    Range.cpMin:=Result; Range.cpMax:=Result;
    SendMessage(Edit.Handle,EM_EXSETSEL,0,LPARAM(@Range));
    SendMessage(Edit.Handle,EM_EXGETSEL,0,LPARAM(@Range));
    // Native RichEdit moves a caret inside a UTF-16 pair to its end.
    // Move back to the high surrogate without reading a rounded text range.
    if (Range.cpMin>Result) and (Result>0) then Dec(Result);
  finally SendMessage(Edit.Handle,EM_EXSETSEL,0,LPARAM(@Previous)); end;
end;

function ReaderTextRange(Edit: TRichEdit; Start, Count: Integer): string;
type TNativeRange = record Range: TCharRange; Text: PWideChar; end;
var Info: TNativeRange; Copied, Available: Integer;
begin
  Available:=ReaderTextLength(Edit);
  Start:=Max(0,Min(Start,Available)); Count:=Max(0,Min(Count,Available-Start));
  if Count=0 then Exit('');
  SetLength(Result,Count+1); Info.Range.cpMin:=Start; Info.Range.cpMax:=Start+Count;
  Info.Text:=PWideChar(Result);
  Copied:=SendMessage(Edit.Handle,EM_GETTEXTRANGE,0,LPARAM(@Info));
  SetLength(Result,Max(0,Min(Copied,Count)));
end;

end.
