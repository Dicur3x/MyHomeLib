unit unit_KfxBookCover;

interface

uses System.SysUtils;

// Reads the declared image through the lazy KFX metadata/resource reader.
// The caller holds the raw source lease; no book conversion or output file.
function ReadKfxBookCover(const SourceFile, ToolPath: string;
  const IsCanceled: TFunc<Boolean> = nil): TBytes;

implementation

uses System.Classes, Winapi.Windows, unit_MHLExternalTools;

type
  TCoverBytes = class(TMemoryStream)
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

function TCoverBytes.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count<0) or (Size+Count>16*1024*1024) then
    raise EReadError.Create('Обложка KFX превышает допустимые 16 МБ.');
  Result:=inherited Write(Buffer,Count);
end;

function ReadKfxBookCover(const SourceFile, ToolPath: string;
  const IsCanceled: TFunc<Boolean>): TBytes;
var Data: TCoverBytes; Started: UInt64; CheckCanceled: TFunc<Boolean>;
begin
  Result:=nil;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  if not FileExists(ToolPath) then
    raise EReadError.Create('Для обложек KFX/AZW8 установите модуль KFX и AZW8.');
  Started:=GetTickCount64;
  CheckCanceled:=function:Boolean
    begin
      Result:=Assigned(IsCanceled) and IsCanceled();
      if not Result and (GetTickCount64-Started>30000) then
        raise EReadError.Create('Чтение обложки KFX превысило 30 секунд.');
    end;
  Data:=TCoverBytes.Create;
  try
    try
      RunExternalToolToStream(ToolPath,['cover',SourceFile],Data,
        CheckCanceled,0,True,NativeUInt(512)*1024*1024);
    except
      on E:EMHLExternalToolError do
        raise EReadError.Create('Не удалось прочитать обложку KFX. Проверьте книгу и обновите модуль KFX и AZW8.');
    end;
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    SetLength(Result,Data.Size);
    if Length(Result)>0 then Move(Data.Memory^,Result[0],Length(Result));
  finally Data.Free; end;
end;

end.
