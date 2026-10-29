unit unit_ReaderLegacy;

interface

uses System.SysUtils;

function PrepareB1ReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, Winapi.Windows,
  unit_BookCache, unit_BookConversion, unit_ReaderFormats, unit_MHLArchiveHelpers, unit_MHLExternalTools, unit_FormatComponents, unit_BookConversionRequirements, dm_user;

function PrepareB1ReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Log: TStringStream;
  Python, Script, Stamp, StampFile, Temporary, TemporaryStamp, MessageText: string;
  Attributes: TWin32FileAttributeData; Started: UInt64; Canceled: TFunc<Boolean>;
begin
  Result:=SourceFile; if not SameText(ExtractFileExt(SourceFile),'.b1') then Exit;
  Started:=GetTickCount64;
  Canceled:=function: Boolean
    begin
      Result:=(Assigned(IsCanceled) and IsCanceled()) or
        ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated);
      if GetTickCount64-Started>180000 then
        raise Exception.Create('Извлечение книги из B1 превысило три минуты. Исходный архив сохранён.');
    end;
  if Canceled() then Abort;
  Python:=FindBookProcessingPython(Settings.AppPath);
  Script:=Settings.AppPath+'tools\bookconvert\b1_input.py';
  if not FileExists(Python) or not FileExists(Script) then
    raise EMHLComponentRequired.Create('BookProcessing','Для подготовки этой книги нужна общая обработка книг.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    if Input.Size>64*1024*1024 then raise Exception.Create('Архив B1 превышает предел чтения (64 МБ).');
    Stamp:='b1-payload-v1|'+BookCacheInputStamp(SourceFile,OriginalSource);
    if not GetFileAttributesEx(PChar(Script),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    Stamp:=Stamp+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
      IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,
      'homelib-b1-'+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.payload'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin RegisterBookCacheFile(Result,OriginalSource); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Извлечение книги из архива B1…');
    ForceDirectories(ExtractFileDir(Result)); Writer:=TBookCacheWrite.Create(OriginalSource);
    try
      Temporary:=Writer.TemporaryName(Result,True); TemporaryStamp:=Writer.TemporaryName(StampFile);
      Log:=TStringStream.Create('',TEncoding.UTF8);
      try
        try RunExternalToolToStream(Python,['-I','-B','-X','utf8',Script,SourceFile,Temporary],Log,Canceled,0,True,384*1024*1024);
        except on E: EMHLExternalToolError do
          begin
            MessageText:=Copy(Log.DataString.Trim,1,2048);
            if MessageText='' then MessageText:='Не удалось извлечь книгу из B1. Возможно, архив неполон или повреждён.';
            raise Exception.Create(MessageText);
          end;
        end;
      finally Log.Free; end;
      if Canceled() then Abort;
      if not FileExists(Temporary) or (TFile.GetSize(Temporary)=0) then
        raise Exception.Create('Архив B1 не содержит файла книги.');
      if SameText(DetectReaderExtension(Temporary),'.b1') then
        raise Exception.Create('Вложенные B1 нужно предварительно распаковать.');
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,TemporaryStamp);
    finally Writer.Free; end;
  finally
    if FileExists(Result) then PinReaderCacheFile(Result);
    Input.Free;
  end;
end;

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Zip: TZipFile;
  Stamp, StampFile, Temporary, TemporaryStamp, Dependency: string;
  Attributes: TWin32FileAttributeData; Dependencies: TStringList;
  Canceled: TFunc<Boolean>; Archive: TMHLZip; HasTIFF: Boolean; Extension: string; MaxInput: Int64;
begin
  Result:=SourceFile;
  if not IsLegacyReaderFormat(ExtractFileExt(SourceFile)) then Exit;
  Canceled:=function: Boolean
    begin
      Result:=(Assigned(IsCanceled) and IsCanceled()) or
        ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated);
    end;
  if Canceled() then Abort;
  Extension:=LowerCase(ExtractFileExt(SourceFile));
  if Extension='.fb2' then
  begin
    if not GetFileAttributesEx(PChar(SourceFile),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    // Ordinary FB2 stays on the direct native path, including startup reads.
    // Image-heavy FB2 is prepared in an isolated process, keeping its large
    // base64 blocks out of the native XML DOM.
    if (Attributes.nFileSizeHigh=0) and (Attributes.nFileSizeLow<=64*1024*1024) then Exit;
  end;
  if (Extension='.cbz') or (Extension='.cbr') or (Extension='.cb7') then
  begin
    // Ordinary comics retain the native path. Only TIFF needs frame expansion.
    HasTIFF:=False; Archive:=TMHLZip.Create(SourceFile,True,False,Canceled,Extension<>'.cbz');
    try
      for var I:=0 to Archive.FileCount-1 do
        if SameText(ExtractFileExt(Archive.FileNames[I]),'.tif') or
          SameText(ExtractFileExt(Archive.FileNames[I]),'.tiff') then begin HasTIFF:=True; Break; end;
    finally Archive.Free; end;
    if not HasTIFF then Exit;
  end;
  var Missing:=MissingBookConversionComponents(Settings.AppPath,SourceFile,Extension,False,Canceled);
  if Length(Missing)>0 then raise EMHLComponentRequired.Create(Missing,
    'Для подготовки этой книги нужны компоненты: '+String.Join(', ',Missing)+'.');
  if not ModularBookProcessingAvailable(Settings.AppPath) then
    raise EMHLComponentRequired.Create('BookProcessing','Для этой книги нужна общая обработка книг; декодер формата устанавливается отдельно.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    MaxInput:=64*1024*1024;
    if (Extension='.fb2') or (Extension='.tif') or (Extension='.tiff') or (Extension='.cbz') or (Extension='.cbr') or (Extension='.cb7') then MaxInput:=256*1024*1024;
    if Input.Size>MaxInput then raise Exception.Create('Книга превышает предел читалки ('+IntToStr(MaxInput div 1024 div 1024)+' МБ).');
    Stamp:='legacy-reflow-v3|'+BookCacheInputStamp(SourceFile,OriginalSource);
    Dependencies:=TStringList.Create;
    try
      for Dependency in ['convert_book.py','text_inputs.py','legacy_inputs.py','legacy_helper.py','rgo_input.py','rgo_outline.py','isilo_input.py','isilo_image.py','ibk_input.py','ibk_crypto.py','ibk_parameters.json','ibk_tables.bin','jutoh_input.py','pages_input.py', 'cr3_input.py', 'b1_input.py','xps_input.py','image_input.py','tiff_jpeg.py','office_inputs.py','kindle_input.py','fixed_layout.py','ha_input.py'] do
        if FileExists(Settings.AppPath+'tools\bookconvert\'+Dependency) then
          Dependencies.Add(Settings.AppPath+'tools\bookconvert\'+Dependency);
      if Extension='.ibk' then
        for Dependency in ['ibk\Rus.key'] do
          if FileExists(Settings.AppPath+'tools\'+Dependency) then Dependencies.Add(Settings.AppPath+'tools\'+Dependency);
      if DirectoryExists(Settings.AppPath+'tools\bookconvert\vendor\calibre_legacy') then
        for Dependency in TDirectory.GetFiles(Settings.AppPath+'tools\bookconvert\vendor\calibre_legacy','*',TSearchOption.soAllDirectories) do
          if SameText(ExtractFileExt(Dependency),'.py') or SameText(ExtractFileExt(Dependency),'.dll') then Dependencies.Add(Dependency);
      for Dependency in ['images\HomeLibImages.exe','xps\HomeLibXps.exe','webp\libwebp.dll','doc\HomeLibDoc.exe'] do
        if FileExists(Settings.AppPath+'tools\'+Dependency) then Dependencies.Add(Settings.AppPath+'tools\'+Dependency);
      Dependencies.Sort;
      for Dependency in Dependencies do
      begin
        if not FileExists(Dependency) then
          raise EMHLComponentRequired.Create('BookProcessing','Модуль общей обработки книг неполон.');
        if not GetFileAttributesEx(PChar(Dependency),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
        Stamp:=Stamp+'|'+Dependency+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
          IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
      end;
    finally Dependencies.Free; end;
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,
      'homelib-legacy-'+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.epub'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin RegisterBookCacheFile(Result,OriginalSource); if Assigned(OnStage) then OnStage('Открытие книги из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Подготовка текста, оглавления и иллюстраций книги…');
    ForceDirectories(ExtractFileDir(Result)); Writer:=TBookCacheWrite.Create(OriginalSource);
    try
      Temporary:=Writer.TemporaryName(Result,True); TemporaryStamp:=Writer.TemporaryName(StampFile);
      ConvertBasicBook(Settings.AppPath,Settings.TempDir,SourceFile,ExtractFileExt(SourceFile),Temporary,nil,nil,Canceled,'','','',True);
      if Canceled() then Abort;
      Zip:=TZipFile.Create;
      try
        Zip.Open(Temporary,zmRead);
        if Zip.IndexOf('META-INF/container.xml')<0 then raise Exception.Create('Не удалось подготовить книгу для чтения.');
      finally Zip.Free; end;
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      if Canceled() then Abort;
      Writer.Publish(Temporary,Result,TemporaryStamp);
    finally Writer.Free; end;
  finally
    // Releasing the input can immediately trim the cache. Retain the result
    // before that release on both the warm and newly prepared paths.
    if FileExists(Result) then PinReaderCacheFile(Result);
    Input.Free;
  end;
end;

end.
