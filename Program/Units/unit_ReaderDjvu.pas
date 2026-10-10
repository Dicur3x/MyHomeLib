unit unit_ReaderDjvu;

interface

uses System.SysUtils;

function DjvuPageCount(const FileName: string): Integer;
function PrepareDjvuPage(const FileName: string; Index: Integer): string;

implementation

uses Winapi.Windows, System.Classes, System.IOUtils, System.Hash,
  unit_BookCache, unit_MHLExternalTools;

function Canceled: Boolean;
begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end;

function Decoder(const Name: string): string;
begin
  Result:=FindExternalTool(Name,'djvu');
  if Result='' then raise Exception.Create('Для просмотра DjVu нужен комплект tools\djvu из архива программы.');
end;

procedure RunDjvu(const Tool: string; const Args: array of string; Output: TStream);
var Started: UInt64;
begin
  Started:=GetTickCount64;
  RunExternalToolToStream(Tool,Args,Output,
    function: Boolean
    begin
      Result:=Canceled;
      if GetTickCount64-Started>30000 then raise Exception.Create('Не удалось прочитать страницу DjVu за 30 секунд.');
    end,0,True);
end;

function DjvuPageCount(const FileName: string): Integer;
var Log: TStringStream;
begin
  Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    RunDjvu(Decoder('djvused.exe'),['-n','-e','n',FileName],Log);
    if not TryStrToInt(Log.DataString.Trim,Result) or (Result<=0) or (Result>100000) then
      raise Exception.Create('Не удалось прочитать число страниц DjVu. Файл может быть повреждён.');
  finally Log.Free; end;
end;

function PrepareDjvuPage(const FileName: string; Index: Integer): string;
var Tool,Stamp,Temporary: string; Attributes, ToolAttributes: TWin32FileAttributeData;
  Writer: TBookCacheWrite; Log: TStringStream;
begin
  if Canceled then Abort;
  if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
  Tool:=Decoder('ddjvu.exe');
  if not GetFileAttributesEx(PChar(Tool),GetFileExInfoStandard,@ToolAttributes) then RaiseLastOSError;
  Stamp:='djvu-raster-v2|'+TPath.GetFullPath(FileName)+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+
    IntToStr(Attributes.nFileSizeLow)+'|'+IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+
    IntToStr(Attributes.ftLastWriteTime.dwLowDateTime)+'|'+IntToStr(Index)+'|'+
    IntToStr(ToolAttributes.nFileSizeHigh)+':'+IntToStr(ToolAttributes.nFileSizeLow)+'|'+
    IntToStr(ToolAttributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(ToolAttributes.ftLastWriteTime.dwLowDateTime);
  Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-djvu-'+Copy(THashSHA2.GetHashString(Stamp),1,40)+'.tif'));
  if FileExists(Result) then begin RegisterBookCacheFile(Result,BookCacheSource(FileName)); Exit; end;
  ForceDirectories(ExtractFileDir(Result));
  Writer:=TBookCacheWrite.Create(BookCacheSource(FileName)); Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    Temporary:=Writer.TemporaryName(Result);
    // Decode just the requested original page, with lossless TIFF compression.
    // This is raster rendering, never text recognition or OCR.
    RunDjvu(Tool,['-format=tiff','-quality=deflate','-page='+IntToStr(Index+1),'-size=4000x4000',FileName,Temporary],Log);
    if Canceled then Abort;
    if not FileExists(Temporary) then raise Exception.Create('Декодер не создал страницу DjVu.');
    Writer.Publish(Temporary,Result);
  finally Log.Free; Writer.Free; end;
end;

end.
