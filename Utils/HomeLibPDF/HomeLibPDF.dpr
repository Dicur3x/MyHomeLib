program HomeLibPDF;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Types,
  unit_PDFProtocol in '..\..\Program\Units\unit_PDFProtocol.pas',
  unit_ReaderPDF in '..\..\Program\Units\unit_ReaderPDF.pas';

var
  Document: TReaderPDF;
  InputPipe, OutputPipe, Mapping: THandle;
  Pixels: Pointer;

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
var Response: TPDFResponse; Text: UTF8String;
begin
  Response:=Default(TPDFResponse); Text:=UTF8String(Copy(Error,1,2000));
  Response.Magic:=PDF_PROTOCOL; Response.Status:=Status; Response.Width:=Width;
  Response.Height:=Height; if Assigned(Document) then Response.Count:=Document.PageCount;
  Response.Length:=Length(Text); WriteExact(OutputPipe,Response,SizeOf(Response));
  if Text<>'' then WriteExact(OutputPipe,Text[1],Length(Text));
end;

procedure RenderPage(Index, MaxEdge: Integer);
var Size: TPoint; Scale: Double; W,H: Integer;
begin
  if not Assigned(Document) then raise Exception.Create('Книга PDF не открыта.');
  if MaxEdge=0 then MaxEdge:=4000;
  if (MaxEdge<200) or (MaxEdge>4000) then raise Exception.Create('Некорректный масштаб страницы PDF.');
  Size:=Document.PageSize(Index);
  Scale:=Min(MaxEdge/Double(Max(Size.X,Size.Y)),Sqrt(16000000.0/(Double(Size.X)*Size.Y)));
  W:=Max(1,Trunc(Size.X*Scale)); H:=Max(1,Trunc(Size.Y*Scale));
  if Int64(W)*H*4>PDF_BUFFER_BYTES then raise Exception.Create('Страница PDF превышает бюджет памяти.');
  Document.RenderPixels(Index,W,H,Pixels); Reply(0,W,H);
end;

procedure Serve;
var Request: TPDFRequest; FileName: UTF8String;
begin
  if (ParamStr(1)<>'--worker') or not ParamStr(2).StartsWith('Local\HomeLibRu-PDF-') then Halt(2);
  InputPipe:=GetStdHandle(STD_INPUT_HANDLE); OutputPipe:=GetStdHandle(STD_OUTPUT_HANDLE);
  Mapping:=OpenFileMapping(FILE_MAP_WRITE,False,PChar(ParamStr(2))); if Mapping=0 then RaiseLastOSError;
  Pixels:=MapViewOfFile(Mapping,FILE_MAP_WRITE,0,0,PDF_BUFFER_BYTES); if Pixels=nil then RaiseLastOSError;
  repeat
    ReadExact(InputPipe,Request,SizeOf(Request));
    if Request.Magic<>PDF_PROTOCOL then Abort;
    if Request.Command=PDF_CLOSE then Exit;
    try
      case Request.Command of
        PDF_OPEN:
          begin
            if (Request.Length<=0) or (Request.Length>131072) then Abort;
            SetLength(FileName,Request.Length); ReadExact(InputPipe,FileName[1],Request.Length);
            FreeAndNil(Document);
            Document:=TReaderPDF.Create(ExtractFilePath(ParamStr(0))+'pdfium.dll',string(FileName));
            if Document.PageCount>100000 then raise Exception.Create('Некорректное число страниц PDF.');
            Reply(0,0,0);
          end;
        PDF_RENDER: RenderPage(Request.Index,Request.Length);
      else Abort;
      end;
    except
      on E: EAbort do raise;
      on E: Exception do Reply(1,0,0,E.Message);
    end;
  until False;
end;

begin
  try
    try Serve;
    except on E: EAbort do ; on E: Exception do
      if OutputPipe<>0 then try Reply(1,0,0,E.Message); except end;
    end;
  finally
    Document.Free;
    if Pixels<>nil then UnmapViewOfFile(Pixels);
    if Mapping<>0 then CloseHandle(Mapping);
  end;
end.
