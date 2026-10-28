unit unit_ReaderOffice;

interface

uses System.SysUtils;

function IsOfficeReaderFormat(const Extension: string): Boolean;
function FindReaderOffice: string;
function OfficeReaderAvailable(const Extension: string): Boolean;
function PrepareOfficeReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, Winapi.Windows,
  unit_BookCache, unit_MHLExternalTools, unit_Settings, unit_ReaderDOC,
  unit_BookConversion, unit_FormatComponents, dm_user;

function IsOfficeReaderFormat(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|doc|dot|docm|dotx|dotm|ott|wps|wpd|ppt|pptx|pptm|pps|ppsx|ppsm|pot|potx|potm|odp|otp|xls|xlt|xlsx|xlsm|xltx|xltm|ods|ots|')>0;
end;

function FindReaderOffice: string;
begin
  // The private interpreter is shared by processing; format decoders are separate.
  // Never discover, start or require an installed office application.
  Result:=FindBookProcessingPython(Settings.AppPath);
  if not FileExists(Result) then Result:='';
  if not FileExists(TPath.Combine(Settings.AppPath,'tools\bookconvert\office_inputs.py')) then Result:='';
end;

function OfficeReaderAvailable(const Extension: string): Boolean;
var SystemInfo: TSystemInfo;
begin
  if IsDirectDOCFormat(Extension) then Exit(FindDirectDOCReader<>'');
  Result:=IsOfficeReaderFormat(Extension) and (FindReaderOffice<>'');
  if not Result then Exit;
  if Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|','|wps|wpd|')>0 then
  begin
    GetNativeSystemInfo(SystemInfo);
    Result:=(SystemInfo.wProcessorArchitecture=PROCESSOR_ARCHITECTURE_AMD64) and
      FileExists(TPath.Combine(Settings.AppPath,'tools\office\wps2html.exe')) and
      FileExists(TPath.Combine(Settings.AppPath,'tools\office\wpd2html.exe'));
  end;
end;

function PrepareOfficeReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Zip: TZipFile;
  Stamp, StampFile, Temporary, TemporaryStamp, Dependency: string;
  Attributes: TWin32FileAttributeData;
  procedure CheckCanceled;
  begin
    if (Assigned(IsCanceled) and IsCanceled()) or
      ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated) then Abort;
  end;
  procedure AddStamp(const FileName: string; const Component: string = 'BookProcessing');
  begin
    if not FileExists(FileName) then
      raise EMHLComponentRequired.Create(Component,'Для подготовки документа нужен компонент '+Component+'.');
    if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    Stamp:=Stamp+'|'+FileName+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
      IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  end;
begin
  Result:=SourceFile; if not IsOfficeReaderFormat(ExtractFileExt(SourceFile)) then Exit;
  if IsDirectDOCFormat(ExtractFileExt(SourceFile)) then Exit(PrepareDirectDOC(SourceFile,OriginalSource,OnStage,IsCanceled));
  CheckCanceled;
  if FindReaderOffice='' then raise EMHLComponentRequired.Create('BookProcessing','Для подготовки этого документа нужна общая обработка книг.');
  if not OfficeReaderAvailable(ExtractFileExt(SourceFile)) then
  begin
    if Pos('|'+LowerCase(ExtractFileExt(SourceFile)).TrimLeft(['.'])+'|','|wps|wpd|')>0 then
    begin
      var SystemInfo: TSystemInfo; GetNativeSystemInfo(SystemInfo);
      if SystemInfo.wProcessorArchitecture<>PROCESSOR_ARCHITECTURE_AMD64 then
        raise Exception.Create('Чтение WPS/WPD пока требует 64-разрядную Windows.');
    end;
    raise EMHLComponentRequired.Create('LegacyOffice','Для чтения WPS/WPD нужен модуль libwps/libwpd.');
  end;
  Input:=OpenCachedBookFile(SourceFile);
  try
    if Input.Size>64*1024*1024 then raise Exception.Create('Офисный документ превышает предел читалки (64 МБ).');
    Stamp:='office-reflow-v1|'+BookCacheInputStamp(SourceFile,OriginalSource);
    for Dependency in ['tools\bookconvert\office_inputs.py','tools\bookconvert\convert_book.py',
      'tools\bookconvert\text_inputs.py'] do
      AddStamp(TPath.Combine(Settings.AppPath,Dependency));
    if Pos('|'+LowerCase(ExtractFileExt(SourceFile)).TrimLeft(['.'])+'|','|wps|wpd|')>0 then
      AddStamp(TPath.Combine(Settings.AppPath,'tools\office\RUNTIME.json'),'LegacyOffice');
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,
      'homelib-office-'+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.epub'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin RegisterBookCacheFile(Result,OriginalSource); if Assigned(OnStage) then OnStage('Открытие документа из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Чтение текста, таблиц и изображений документа…');
    ForceDirectories(ExtractFileDir(Result)); Writer:=TBookCacheWrite.Create(OriginalSource);
    try
      Temporary:=Writer.TemporaryName(Result,True);
      // The converter chooses its target by suffix. Cache publication itself
      // remains atomic and the original document stays locked against writes.
      TemporaryStamp:=Writer.TemporaryName(StampFile);
      try
        ConvertBasicBook(Settings.AppPath,Settings.TempDir,SourceFile,ExtractFileExt(SourceFile),Temporary,nil,nil,IsCanceled,'','','',True);
        CheckCanceled; Zip:=TZipFile.Create;
        try
          Zip.Open(Temporary,zmRead);
          if Zip.IndexOf('META-INF/container.xml')<0 then raise Exception.Create('Не удалось подготовить офисный документ для чтения.');
        finally Zip.Free; end;
        TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8); CheckCanceled;
        Writer.Publish(Temporary,Result,TemporaryStamp);
      finally if FileExists(Temporary) then TFile.Delete(Temporary); end;
    finally Writer.Free; end;
  finally Input.Free; end;
end;

end.
