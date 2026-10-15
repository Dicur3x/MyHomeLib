unit unit_SevenZipMetadata;

interface

uses System.SysUtils, System.Classes, System.Generics.Collections, Winapi.Windows;

type
  // Read-only 7-Zip SDK adapter. It never creates files or starts processes.
  // Interfaces and property IDs follow the public 7-Zip SDK (IArchive.h).
  TSevenZipMetadataArchive = class
  private
    FModule: HMODULE;
    FArchive, FInput: IInterface;
    FNames: TArray<string>;
    FSizes: TArray<Int64>;
    FIndex: TDictionary<string,Integer>;
    FIsCanceled: TFunc<Boolean>;
  public
    constructor Create(const FileName: string; const IsCanceled: TFunc<Boolean>);
    destructor Destroy; override;
    function Count: Integer;
    function NameAt(Index: Integer): string;
    function SizeAt(Index: Integer): Int64;
    function ReadEntry(const Name: string; MaxBytes: Integer): TMemoryStream;
    function ReadPrefix(const Name: string; MaxBytes: Integer;
      const Complete: TFunc<TStream,Boolean> = nil): TMemoryStream;
  end;

implementation

uses System.IOUtils, System.Variants, System.Math, unit_MHLExternalTools;

type
  I7zSequentialIn = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000300010000}']
    function Read(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT; stdcall;
  end;
  I7zIn = interface(I7zSequentialIn)
    ['{23170F69-40C1-278A-0000-000300030000}']
    function Seek(Offset: Int64; Origin: Cardinal; Position: PUInt64): HRESULT; stdcall;
  end;
  I7zOut = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000300020000}']
    function Write(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT; stdcall;
  end;
  I7zProgress = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000000050000}']
    function SetTotal(Total: UInt64): HRESULT; stdcall;
    function SetCompleted(Value: PUInt64): HRESULT; stdcall;
  end;
  I7zExtract = interface(I7zProgress)
    ['{23170F69-40C1-278A-0000-000600200000}']
    function GetStream(Index: Cardinal; out Stream: I7zOut; Mode: Integer): HRESULT; stdcall;
    function PrepareOperation(Mode: Integer): HRESULT; stdcall;
    function SetOperationResult(Value: Integer): HRESULT; stdcall;
  end;
  I7zArchive = interface(IUnknown)
    ['{23170F69-40C1-278A-0000-000600600000}']
    function Open(const Stream: I7zIn; MaxCheck: PUInt64; Callback: IUnknown): HRESULT; stdcall;
    function Close: HRESULT; stdcall;
    function GetNumberOfItems(out Count: Cardinal): HRESULT; stdcall;
    function GetProperty(Index, PropID: Cardinal; var Value: OleVariant): HRESULT; stdcall;
    function Extract(Indices: PCardinal; Count: Cardinal; TestMode: Integer; const Callback: I7zExtract): HRESULT; stdcall;
    function GetArchiveProperty(PropID: Cardinal; var Value: OleVariant): HRESULT; stdcall;
    function GetNumberOfProperties(out Count: Cardinal): HRESULT; stdcall;
    function GetPropertyInfo(Index: Cardinal; out Name: WideString; out PropID: Cardinal; out VarType: Word): HRESULT; stdcall;
    function GetNumberOfArchiveProperties(out Count: Cardinal): HRESULT; stdcall;
    function GetArchivePropertyInfo(Index: Cardinal; out Name: WideString; out PropID: Cardinal; out VarType: Word): HRESULT; stdcall;
  end;
  TGetFormatCount = function(out Count: Cardinal): HRESULT; stdcall;
  TGetFormatProperty = function(Index, PropID: Cardinal; var Value: OleVariant): HRESULT; stdcall;
  TCreateArchive = function(const ClassID, IID: TGUID; out Obj): HRESULT; stdcall;

  T7zInput = class(TInterfacedObject,I7zSequentialIn,I7zIn)
  private
    FFile: TFileStream;
    FCancel: TFunc<Boolean>;
  public
    constructor Create(const Path: string; const Cancel: TFunc<Boolean>);
    destructor Destroy; override;
    function Read(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT; stdcall;
    function Seek(Offset: Int64; Origin: Cardinal; Position: PUInt64): HRESULT; stdcall;
  end;

  T7zPrefix = class(TInterfacedObject,I7zOut,I7zProgress,I7zExtract)
  public
    Output: TMemoryStream;
    Limit: Integer;
    Wanted: Cardinal;
    Started: UInt64;
    Stopped, Canceled: Boolean;
    Operation: Integer;
    Complete: TFunc<TStream,Boolean>;
    Cancel: TFunc<Boolean>;
    function Check: HRESULT;
    function Write(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT; stdcall;
    function SetTotal(Total: UInt64): HRESULT; stdcall;
    function SetCompleted(Value: PUInt64): HRESULT; stdcall;
    function GetStream(Index: Cardinal; out Stream: I7zOut; Mode: Integer): HRESULT; stdcall;
    function PrepareOperation(Mode: Integer): HRESULT; stdcall;
    function SetOperationResult(Value: Integer): HRESULT; stdcall;
  end;

procedure Check7z(Code: HRESULT; const Stage: string);
begin
  if Code<>S_OK then raise EReadError.CreateFmt('7-Zip: %s (0x%s)',[Stage,IntToHex(Cardinal(Code),8)]);
end;

constructor T7zInput.Create(const Path: string; const Cancel: TFunc<Boolean>);
begin inherited Create; FCancel:=Cancel; FFile:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite); end;
destructor T7zInput.Destroy;
begin FFile.Free; inherited; end;
function T7zInput.Read(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT;
var N: Integer;
begin
  if Assigned(Processed) then Processed^:=0;
  if Assigned(FCancel) and FCancel() then Exit(E_ABORT);
  try
    N:=FFile.Read(Data^,Integer(Min(Size,Cardinal(MaxInt))));
    if Assigned(Processed) then Processed^:=N; Result:=S_OK;
  except Result:=E_FAIL; end;
end;
function T7zInput.Seek(Offset: Int64; Origin: Cardinal; Position: PUInt64): HRESULT;
begin
  if Origin>2 then Exit(E_INVALIDARG);
  try
    var Value:=FFile.Seek(Offset,TSeekOrigin(Origin));
    if Assigned(Position) then Position^:=Value; Result:=S_OK;
  except Result:=E_FAIL; end;
end;

function T7zPrefix.Check: HRESULT;
begin
  Canceled:=Assigned(Cancel) and Cancel();
  if Canceled or (GetTickCount64-Started>30000) then Exit(E_ABORT);
  Result:=S_OK;
end;
function T7zPrefix.Write(Data: Pointer; Size: Cardinal; Processed: PCardinal): HRESULT;
var N: Integer;
begin
  if Assigned(Processed) then Processed^:=0;
  Result:=Check; if Result<>S_OK then Exit;
  try
    N:=Min(Int64(Size),Int64(Limit)-Output.Size);
    if N>0 then begin Output.Position:=Output.Size; Output.WriteBuffer(Data^,N); end;
    if Assigned(Processed) then Processed^:=N;
    if Assigned(Complete) then
    begin Output.Position:=0; Stopped:=Complete(Output); end;
    Stopped:=Stopped or (Output.Size>=Limit);
    if Stopped then Result:=E_ABORT else Result:=S_OK;
  except Result:=E_FAIL; end;
end;
function T7zPrefix.SetTotal(Total: UInt64): HRESULT;
begin Result:=Check; end;
function T7zPrefix.SetCompleted(Value: PUInt64): HRESULT;
begin Result:=Check; end;
function T7zPrefix.GetStream(Index: Cardinal; out Stream: I7zOut; Mode: Integer): HRESULT;
begin
  Stream:=nil; Result:=Check;
  if (Result=S_OK) and (Index=Wanted) and (Mode=0) then Stream:=Self;
end;
function T7zPrefix.PrepareOperation(Mode: Integer): HRESULT;
begin Result:=Check; end;
function T7zPrefix.SetOperationResult(Value: Integer): HRESULT;
begin Operation:=Value; Result:=Check; end;

constructor TSevenZipMetadataArchive.Create(const FileName: string; const IsCanceled: TFunc<Boolean>);
const SafeDLLSearchFlags=$00000100 or $00000800; // DLL_LOAD_DIR | SYSTEM32 (Windows SDK)
  ZipID: TGUID='{23170F69-40C1-278A-1000-000110010000}';
  SevenZipID: TGUID='{23170F69-40C1-278A-1000-000110070000}';
var CreateArchive: TCreateArchive; GetFormatCount: TGetFormatCount; GetFormatProperty: TGetFormatProperty;
  Archive: I7zArchive; Input: I7zIn;
  ID: TGUID; Total, I: Cardinal; Value: OleVariant; DLL, Name: string; MaxCheck: UInt64;
  Existing, NameChars: Integer; FormatCount: Cardinal; RawID: WideString; Ext: string; Found, Rar5: Boolean; Header: array[0..7] of Byte; HeaderFile: TFileStream;
begin
  inherited Create; FIsCanceled:=IsCanceled;
  if Assigned(FIsCanceled) and FIsCanceled() then raise EAbort.Create('Чтение отменено');
  FIndex:=TDictionary<string,Integer>.Create;
  DLL:=FindExternalTool('7z.dll','7zip');
  if DLL='' then raise ENotSupportedException.Create('Для чтения сжатых метаданных нужен компонент 7-Zip (7z.dll). Обновите его в программе.');
  FModule:=LoadLibraryEx(PChar(TPath.GetFullPath(DLL)),0,SafeDLLSearchFlags);
  if FModule=0 then RaiseLastOSError;
  @CreateArchive:=GetProcAddress(FModule,'CreateObject');
  if not Assigned(CreateArchive) then raise ENotSupportedException.Create('7z.dll не предоставляет интерфейс чтения архивов');
  Ext:=LowerCase(ExtractFileExt(FileName)).TrimLeft(['.']);
  if (Ext='fbz') or (Ext='cbz') then Ext:='zip';
  if (Ext='7zip') or (Ext='cb7') then Ext:='7z';
  if Ext='cbr' then Ext:='rar'; if Ext='gzip' then Ext:='gz'; if Ext='tgz' then Ext:='gz';
  Rar5:=False;
  if Ext='rar' then
  begin
    HeaderFile:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
    try
      FillChar(Header,SizeOf(Header),0); HeaderFile.Read(Header,SizeOf(Header));
      Rar5:=(Header[0]=$52) and (Header[1]=$61) and (Header[2]=$72) and (Header[3]=$21) and (Header[6]=1);
    finally HeaderFile.Free; end;
  end;
  ID:=ZipID;
  if Ext='7z' then ID:=SevenZipID
  else if Ext<>'zip' then
  begin
    @GetFormatCount:=GetProcAddress(FModule,'GetNumberOfFormats');
    @GetFormatProperty:=GetProcAddress(FModule,'GetHandlerProperty2');
    if not Assigned(GetFormatCount) or not Assigned(GetFormatProperty) then
      raise ENotSupportedException.Create('Этот компонент 7-Zip не предоставляет список форматов');
    Check7z(GetFormatCount(FormatCount),'список форматов'); Found:=False;
    if FormatCount>1000 then raise EReadError.Create('Некорректный список форматов 7-Zip');
    for var Handler:=0 to Integer(FormatCount)-1 do
    begin
      Value:=Unassigned; Check7z(GetFormatProperty(Handler,2,Value),'расширения формата');
      if Pos(' '+Ext+' ',' '+LowerCase(VarToStr(Value))+' ')=0 then Continue;
      if Ext='rar' then
      begin
        Value:=Unassigned; Check7z(GetFormatProperty(Handler,0,Value),'имя формата');
        if SameText(VarToStr(Value),'Rar5')<>Rar5 then Continue;
      end;
      Value:=Unassigned; Check7z(GetFormatProperty(Handler,1,Value),'ID формата'); RawID:=WideString(Value);
      if Length(RawID)*SizeOf(WideChar)<>SizeOf(ID) then raise EReadError.Create('Некорректный ID формата 7-Zip');
      Move(PWideChar(RawID)^,ID,SizeOf(ID)); Found:=True; Break;
    end;
    if not Found then raise ENotSupportedException.Create('Компонент 7-Zip не поддерживает архив '+Ext);
  end;

  Check7z(CreateArchive(ID,I7zArchive,Archive),'создание читателя'); FArchive:=Archive;
  Input:=T7zInput.Create(FileName,IsCanceled); FInput:=Input; MaxCheck:=0;
  Check7z(Archive.Open(Input,@MaxCheck,nil),'открытие архива');
  Check7z(Archive.GetNumberOfItems(Total),'список файлов');
  if Total>200000 then raise EReadError.Create('В архиве более 200 000 файлов');
  SetLength(FNames,Total); SetLength(FSizes,Total); NameChars:=0;
  if Total=0 then Exit;
  for I:=0 to Total-1 do
  begin
    if Assigned(FIsCanceled) and FIsCanceled() then raise EAbort.Create('Чтение отменено');
    Value:=Unassigned; Check7z(Archive.GetProperty(I,3,Value),'имя файла'); Name:=VarToStr(Value);
    if (Name='') and (Total=1) then Name:=ChangeFileExt(ExtractFileName(FileName),'');
    Inc(NameChars,Length(Name)); if NameChars>8*1024*1024 then raise EReadError.Create('Список имён архива слишком велик');
    FNames[I]:=Name; Name:=LowerCase(Name.Replace('\','/'));
    if FIndex.TryGetValue(Name,Existing) then FIndex.AddOrSetValue(Name,-1) else FIndex.Add(Name,I);
    Value:=Unassigned; Check7z(Archive.GetProperty(I,7,Value),'размер файла');
    if VarIsEmpty(Value) then FSizes[I]:=0 else FSizes[I]:=Value;
  end;
end;

destructor TSevenZipMetadataArchive.Destroy;
begin
  if Assigned(FArchive) then I7zArchive(FArchive).Close;
  FArchive:=nil; FInput:=nil; FIndex.Free;
  if FModule<>0 then FreeLibrary(FModule);
  inherited;
end;
function TSevenZipMetadataArchive.Count: Integer;
begin Result:=Length(FNames); end;
function TSevenZipMetadataArchive.NameAt(Index: Integer): string;
begin Result:=FNames[Index]; end;
function TSevenZipMetadataArchive.SizeAt(Index: Integer): Int64;
begin Result:=FSizes[Index]; end;

function TSevenZipMetadataArchive.ReadEntry(const Name: string; MaxBytes: Integer): TMemoryStream;
var Index: Integer;
begin
  if not FIndex.TryGetValue(LowerCase(Name.Replace('\','/')),Index) or (Index<0) then
    raise EReadError.Create('Книга не найдена однозначно в архиве: '+Name);
  if (MaxBytes<1) or (MaxBytes>64*1024*1024) or (FSizes[Index]<0) or (FSizes[Index]>MaxBytes) then
    raise EReadError.Create('Книга превышает предел чтения метаданных (64 МБ)');
  // One extra byte prevents intentional prefix termination at exact EOF:
  // full entries must reach the decoder's normal CRC/result callback.
  Result:=ReadPrefix(Name,MaxBytes+1);
  if Result.Size<>FSizes[Index] then
  begin Result.Free; raise EReadError.Create('Неполная книга в архиве'); end;
end;

function TSevenZipMetadataArchive.ReadPrefix(const Name: string; MaxBytes: Integer;
  const Complete: TFunc<TStream,Boolean>): TMemoryStream;
var Index: Integer; Selected: Cardinal; Callback: T7zPrefix; Owner: I7zExtract; Status: HRESULT;
begin
  if (MaxBytes<1) or (MaxBytes>64*1024*1024+1) then raise EArgumentException.Create('Неверный предел чтения метаданных');
  if not FIndex.TryGetValue(LowerCase(Name.Replace('\','/')),Index) or (Index<0) then
    raise EReadError.Create('Книга не найдена однозначно в архиве: '+Name);
  Result:=TMemoryStream.Create; Callback:=T7zPrefix.Create; Owner:=Callback;
  try
    Callback.Output:=Result; Callback.Limit:=MaxBytes; Callback.Wanted:=Index;
    Callback.Started:=GetTickCount64; Callback.Cancel:=FIsCanceled; Callback.Complete:=Complete; Callback.Operation:=-1;
    Selected:=Index; Status:=I7zArchive(FArchive).Extract(@Selected,1,0,Owner);
    if Callback.Canceled then raise EAbort.Create('Чтение отменено');
    if not ((Status=E_ABORT) and Callback.Stopped) then
    begin
      Check7z(Status,'распаковка метаданных');
      if Callback.Operation<>0 then raise EReadError.CreateFmt('7-Zip: ошибка данных книги (%d)',[Callback.Operation]);
    end;
    Result.Position:=0;
  except Result.Free; Result:=nil; raise; end;
end;

end.
