unit unit_XpsBookCover;

interface

uses System.SysUtils;

// The caller keeps its raw-book lease open. The helper writes only a small,
// disposable page ZIP and never changes the source or prepares the whole book.
function ReadXpsBookCover(const SourceFile, ToolPath, TempRoot: string;
  const IsCanceled: TFunc<Boolean> = nil): TBytes;

implementation

uses System.Classes, System.IOUtils, System.Zip, Winapi.Windows,
  unit_MHLExternalTools;

const MaxCover = 2*1024*1024;

type
  TCoverLog = class(TMemoryStream)
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

function TCoverLog.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count<0) or (Size+Count>65536) then
    raise EReadError.Create('Обработчик XPS вернул слишком большой журнал.');
  Result:=inherited Write(Buffer,Count);
end;

function ReadXpsBookCover(const SourceFile, ToolPath, TempRoot: string;
  const IsCanceled: TFunc<Boolean>): TBytes;
var Work, Output, Root: string; Log: TCoverLog; Zip: TZipFile;
  Input: TStream; Header: TZipHeader; Count: Integer; Started, LastSpace: UInt64;
  Buffer: array[0..32767] of Byte; Data: TMemoryStream; Canceled: TFunc<Boolean>;
  procedure Check;
  begin if Canceled() then Abort; end;
begin
  Result:=nil; Work:=''; Output:=''; Started:=GetTickCount64; LastSpace:=0;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  if not FileExists(ToolPath) then
    raise EReadError.Create('Для предпросмотра XPS нужен модуль чтения XPS.');
  Root:=TPath.GetFullPath(TempRoot);
  Canceled:=function:Boolean
    var Available, Capacity: UInt64; Now: UInt64; SystemRoot: string;
    begin
      Result:=Assigned(IsCanceled) and IsCanceled();
      if Result then Exit;
      Now:=GetTickCount64;
      if Now-Started>30000 then
        raise EReadError.Create('Предпросмотр XPS превысил 30 секунд.');
      if (LastSpace=0) or (Now-LastSpace>=1000) then
      begin
        LastSpace:=Now;
        SystemRoot:=GetEnvironmentVariable('SystemDrive')+'\';
        if not GetDiskFreeSpaceEx(PChar(SystemRoot),Available,Capacity,nil) then RaiseLastOSError;
        if Available<UInt64(8)*1024*1024*1024 then
          raise EWriteError.Create('Для предпросмотра XPS нужно оставить 8 ГБ на системном диске.');
        if not GetDiskFreeSpaceEx(PChar(Root),Available,Capacity,nil) then RaiseLastOSError;
        if Available<16*1024*1024 then
          raise EWriteError.Create('Недостаточно места для предпросмотра XPS.');
      end;
    end;
  ForceDirectories(Root); Check;
  Work:=TPath.Combine(Root,'homelibre-xps-cover-'+TGUID.NewGuid.ToString);
  if not CreateDirectory(PChar(Work),nil) then RaiseLastOSError;
  Output:=TPath.Combine(Work,'cover.zip');
  try
    Log:=TCoverLog.Create;
    try
      try
        RunExternalToolToStream(ToolPath,['--cover',SourceFile,Output],Log,Canceled,0,True,384*1024*1024);
      except on E:EMHLExternalToolError do
        raise EReadError.Create('Не удалось прочитать XPS. Проверьте файл и обновите модуль чтения XPS.');
      end;
    finally Log.Free; end;
    Check;
    try
      Zip:=TZipFile.Create;
      try
        Zip.Open(Output,zmRead);
        if (Zip.FileCount<>1) or (Zip.FileNames[0]<>'00001.png') or
          (Zip.FileInfo[0].UncompressedSize64>MaxCover) then
          raise EReadError.Create('Обработчик XPS вернул недопустимый предпросмотр.');
        Zip.Read(0,Input,Header,True);
        try
          Data:=TMemoryStream.Create;
          try
            repeat
              Check; Count:=Input.Read(Buffer,SizeOf(Buffer));
              if Data.Size+Count>MaxCover then
                raise EReadError.Create('Предпросмотр XPS превышает допустимый размер.');
              if Count>0 then Data.WriteBuffer(Buffer,Count);
            until Count=0;
            if (Data.Size=0) or (Data.Size<>Int64(Zip.FileInfo[0].UncompressedSize64)) then
              raise EReadError.Create('Предпросмотр XPS повреждён.');
            SetLength(Result,Data.Size); Move(Data.Memory^,Result[0],Length(Result));
          finally Data.Free; end;
        finally Input.Free; end;
      finally Zip.Free; end;
    except on E:EZipException do
      raise EReadError.Create('Предпросмотр XPS повреждён: не удалось проверить архив страницы.');
    end;
  finally
    // Only the one output in this freshly created directory belongs to us.
    // Do not recurse through unexpected files or a replaced directory.
    if (GetFileAttributes(PChar(Work))<>INVALID_FILE_ATTRIBUTES) and
      (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
    begin
      Winapi.Windows.DeleteFile(PChar(Output));
      RemoveDirectory(PChar(Work));
    end;
  end;
end;

end.
