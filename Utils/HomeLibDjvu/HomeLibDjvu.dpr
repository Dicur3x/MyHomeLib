program HomeLibDjvu;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Math,
  unit_DjvuProtocol in '..\..\Program\Units\unit_DjvuProtocol.pas';

type
  TDjvuRect = record X,Y: Integer; W,H: Cardinal; end;
  TDjvuCreate = function(Name: PAnsiChar): Pointer; cdecl;
  TDjvuRelease = procedure(Item: Pointer); cdecl;
  TDjvuInteger = function(Item: Pointer): Integer; cdecl;
  TDjvuPointer = function(Item: Pointer): Pointer; cdecl;
  TDjvuDocument = function(Context: Pointer; Name: PAnsiChar; Cache: Integer): Pointer; cdecl;
  TDjvuPage = function(Document: Pointer; Index: Integer): Pointer; cdecl;
  TDjvuFormat = function(Style, Count: Integer; Masks: PCardinal): Pointer; cdecl;
  TDjvuFlag = procedure(Format: Pointer; Value: Integer); cdecl;
  TDjvuCache = procedure(Context: Pointer; Size: Cardinal); cdecl;
  TDjvuRender = function(Page: Pointer; Mode: Integer; const PageRect, RenderRect: TDjvuRect;
    Format: Pointer; RowBytes: Cardinal; Pixels: Pointer): Integer; cdecl;
  TPageSlot = record Page: Pointer; Index: Integer; Used: UInt64; end;

var
  DLL: HMODULE;
  Context, Document, Format: Pointer;
  InputPipe, OutputPipe, Mapping: THandle;
  Pixels: Pointer;
  PageCount: Integer;
  Age: UInt64;
  Slots: array[0..2] of TPageSlot;
  ContextCreate: TDjvuCreate; ContextRelease, JobRelease, MessagePop, FormatRelease: TDjvuRelease;
  DocumentCreate: TDjvuDocument; DocumentJob, PageJob, MessagePeek: TDjvuPointer;
  JobStatus, GetCount, PageWidth, PageHeight: TDjvuInteger;
  PageCreate: TDjvuPage; FormatCreate: TDjvuFormat; SetRows, SetY: TDjvuFlag;
  CacheSize: TDjvuCache; PageRender: TDjvuRender;

procedure ReadExact(Handle: THandle; var Buffer; Size: Cardinal);
var Done, Got: Cardinal;
begin
  Done:=0;
  while Done<Size do
  begin
    if not ReadFile(Handle,PByte(@Buffer)[Done],Size-Done,Got,nil) or (Got=0) then Abort;
    Inc(Done,Got);
  end;
end;

procedure WriteExact(Handle: THandle; const Buffer; Size: Cardinal);
var Done, Sent: Cardinal;
begin
  Done:=0;
  while Done<Size do
  begin
    if not WriteFile(Handle,PByte(@Buffer)[Done],Size-Done,Sent,nil) or (Sent=0) then Abort;
    Inc(Done,Sent);
  end;
end;

procedure Reply(Status, Width, Height: Integer; const Error: string='');
var Response: TDjvuResponse; Text: UTF8String;
begin
  Text:=UTF8String(Copy(Error,1,2000));
  Response.Magic:=DJVU_PROTOCOL; Response.Status:=Status; Response.Width:=Width;
  Response.Height:=Height; Response.Count:=PageCount; Response.Length:=Length(Text);
  WriteExact(OutputPipe,Response,SizeOf(Response));
  if Text<>'' then WriteExact(OutputPipe,Text[1],Length(Text));
end;

procedure PumpMessages;
begin
  while MessagePeek(Context)<>nil do MessagePop(Context);
end;

procedure WaitJob(Job: Pointer);
var Started: UInt64; Status: Integer;
begin
  Started:=GetTickCount64;
  repeat
    PumpMessages; Status:=JobStatus(Job);
    if Status>=2 then Break;
    if GetTickCount64-Started>30000 then raise Exception.Create('Декодирование DjVu заняло больше 30 секунд.');
    Sleep(1);
  until False;
  if Status<>2 then raise Exception.Create('Не удалось прочитать страницу DjVu. Файл может быть повреждён.');
end;

procedure CloseDocument;
var I: Integer;
begin
  for I:=0 to High(Slots) do
    if Slots[I].Page<>nil then begin JobRelease(PageJob(Slots[I].Page)); Slots[I].Page:=nil; end;
  if Document<>nil then begin JobRelease(DocumentJob(Document)); Document:=nil; end;
  PageCount:=0;
  if Context<>nil then PumpMessages;
end;

function DecodedPage(Index: Integer): Pointer;
var I, Slot: Integer;
begin
  if (Index<0) or (Index>=PageCount) then raise ERangeError.Create('Номер страницы DjVu вне диапазона.');
  Slot:=-1;
  for I:=0 to High(Slots) do
    if (Slots[I].Page<>nil) and (Slots[I].Index=Index) then begin Slot:=I; Break; end;
  if Slot<0 then
  begin
    Slot:=0;
    for I:=0 to High(Slots) do
      if Slots[I].Page=nil then begin Slot:=I; Break; end
      else if Slots[I].Used<Slots[Slot].Used then Slot:=I;
    if Slots[Slot].Page<>nil then JobRelease(PageJob(Slots[Slot].Page));
    Slots[Slot].Page:=PageCreate(Document,Index); Slots[Slot].Index:=Index;
    if Slots[Slot].Page=nil then raise Exception.Create('Не удалось открыть страницу DjVu.');
    try WaitJob(PageJob(Slots[Slot].Page));
    except JobRelease(PageJob(Slots[Slot].Page)); Slots[Slot].Page:=nil; raise; end;
  end;
  Inc(Age); Slots[Slot].Used:=Age; Result:=Slots[Slot].Page;
end;

procedure RenderPage(Index: Integer);
var Page: Pointer; W,H: Integer; Scale: Double; Rect: TDjvuRect;
begin
  if Document=nil then raise Exception.Create('Книга DjVu не открыта.');
  Page:=DecodedPage(Index); W:=PageWidth(Page); H:=PageHeight(Page);
  if (W<=0) or (H<=0) or (W>100000) or (H>100000) then raise Exception.Create('Некорректный размер страницы DjVu.');
  Scale:=Min(1.0,Min(4000.0/Max(W,H),Sqrt(16000000.0/(Double(W)*H))));
  W:=Max(1,Trunc(W*Scale)); H:=Max(1,Trunc(H*Scale));
  Rect.X:=0; Rect.Y:=0; Rect.W:=W; Rect.H:=H;
  if Int64(W)*H*4>DJVU_BUFFER_BYTES then raise Exception.Create('Страница DjVu превышает бюджет памяти.');
  if PageRender(Page,0,Rect,Rect,Format,W*4,Pixels)=0 then raise Exception.Create('Не удалось отрисовать страницу DjVu.');
  PumpMessages; Reply(0,W,H);
end;

procedure LoadAPI;
  procedure Bind(var FunctionPointer; const Name: AnsiString);
  var Address: Pointer;
  begin
    Address:=GetProcAddress(DLL,PAnsiChar(Name));
    if Address=nil then raise Exception.Create('Несовместимая библиотека DjVuLibre: '+string(Name));
    Pointer(FunctionPointer):=Address;
  end;
var Masks: array[0..3] of Cardinal;
begin
  DLL:=LoadLibraryEx(PChar(ExtractFilePath(ParamStr(0))+'libdjvulibre.dll'),0,LOAD_WITH_ALTERED_SEARCH_PATH);
  if DLL=0 then RaiseLastOSError;
  Bind(ContextCreate,'ddjvu_context_create'); Bind(ContextRelease,'ddjvu_context_release');
  Bind(JobRelease,'ddjvu_job_release'); Bind(JobStatus,'ddjvu_job_status');
  Bind(DocumentCreate,'ddjvu_document_create_by_filename_utf8'); Bind(DocumentJob,'ddjvu_document_job');
  Bind(GetCount,'ddjvu_document_get_pagenum'); Bind(PageCreate,'ddjvu_page_create_by_pageno');
  Bind(PageJob,'ddjvu_page_job'); Bind(PageWidth,'ddjvu_page_get_width'); Bind(PageHeight,'ddjvu_page_get_height');
  Bind(FormatCreate,'ddjvu_format_create'); Bind(FormatRelease,'ddjvu_format_release');
  Bind(SetRows,'ddjvu_format_set_row_order'); Bind(SetY,'ddjvu_format_set_y_direction');
  Bind(PageRender,'ddjvu_page_render'); Bind(MessagePeek,'ddjvu_message_peek');
  Bind(MessagePop,'ddjvu_message_pop'); Bind(CacheSize,'ddjvu_cache_set_size');
  Context:=ContextCreate('HomeLib Ru'); if Context=nil then raise Exception.Create('Не удалось создать декодер DjVu.');
  CacheSize(Context,32*1024*1024);
  Masks[0]:=$00FF0000; Masks[1]:=$0000FF00; Masks[2]:=$000000FF; Masks[3]:=$FF000000;
  Format:=FormatCreate(3,4,@Masks[0]); if Format=nil then raise Exception.Create('Не удалось создать формат страницы DjVu.');
  SetRows(Format,1); SetY(Format,1);
end;

procedure Serve;
var Request: TDjvuRequest; FileName: UTF8String;
begin
  if (ParamStr(1)<>'--worker') or not ParamStr(2).StartsWith('Local\HomeLibRu-Djvu-') then Halt(2);
  InputPipe:=GetStdHandle(STD_INPUT_HANDLE); OutputPipe:=GetStdHandle(STD_OUTPUT_HANDLE);
  Mapping:=OpenFileMapping(FILE_MAP_WRITE,False,PChar(ParamStr(2))); if Mapping=0 then RaiseLastOSError;
  Pixels:=MapViewOfFile(Mapping,FILE_MAP_WRITE,0,0,DJVU_BUFFER_BYTES); if Pixels=nil then RaiseLastOSError;
  LoadAPI;
  repeat
    ReadExact(InputPipe,Request,SizeOf(Request));
    if Request.Magic<>DJVU_PROTOCOL then Abort;
    if Request.Command=DJVU_CLOSE then Exit;
    try
      case Request.Command of
        DJVU_OPEN:
          begin
            if (Request.Length<=0) or (Request.Length>131072) then Abort;
            SetLength(FileName,Request.Length); ReadExact(InputPipe,FileName[1],Request.Length);
            CloseDocument; Document:=DocumentCreate(Context,PAnsiChar(FileName),1);
            if Document=nil then raise Exception.Create('Не удалось открыть DjVu.');
            WaitJob(DocumentJob(Document)); PageCount:=GetCount(Document);
            if (PageCount<=0) or (PageCount>100000) then raise Exception.Create('Некорректное число страниц DjVu.');
            Reply(0,0,0);
          end;
        DJVU_RENDER: RenderPage(Request.Index);
      else Abort;
      end;
    except
      on E: EAbort do raise;
      on E: Exception do Reply(1,0,0,E.Message);
    end;
  until False;
end;

begin
  // This helper keeps the official 32-bit decoder out of either host process.
  // The parent owns its job; cancellation/exit cannot leave a decoder behind.
  try
    try Serve;
    except on E: EAbort do ; on E: Exception do
      if OutputPipe<>0 then try Reply(1,0,0,E.Message); except end;
    end;
  finally
    if Context<>nil then CloseDocument;
    if Format<>nil then FormatRelease(Format);
    if Context<>nil then ContextRelease(Context);
    if Pixels<>nil then UnmapViewOfFile(Pixels);
    if Mapping<>0 then CloseHandle(Mapping);
    if DLL<>0 then FreeLibrary(DLL);
  end;
end.
