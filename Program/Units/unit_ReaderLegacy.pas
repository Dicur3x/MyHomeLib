unit unit_ReaderLegacy;

interface

uses System.SysUtils;

function PrepareB1ReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

function PrepareEpubMathImages(const Chapter: TBytes; Count: Integer; Deadline: UInt64;
  var Remaining: Int64; const IsCanceled: TFunc<Boolean>): TArray<TBytes>;

function RecoverReaderJpeg(const Input: TBytes; Deadline: UInt64; const IsCanceled: TFunc<Boolean>;
  out Output: TBytes; out Rows, OriginalRows, PreviewScans: Integer): Boolean;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, Winapi.Windows,
  System.StrUtils, unit_Diagnostics,
  unit_BookCache, unit_BookConversion, unit_ReaderFormats, unit_ReaderRaster,
  unit_MHLArchiveHelpers, unit_MHLExternalTools, unit_FormatComponents, unit_BookConversionRequirements, dm_user;

function RecoverReaderJpeg(const Input: TBytes; Deadline: UInt64; const IsCanceled: TFunc<Boolean>;
  out Output: TBytes; out Rows, OriginalRows, PreviewScans: Integer): Boolean;
const MaxImage = 16*1024*1024;
var AppPath, Python, Script, Folder, SystemRoot, SourceName, TargetName, Work: string;
  FreeSpace, TotalSpace, Limit: UInt64; Log: TStringStream; Fields: TArray<string>;
begin
  Result:=False; Output:=nil; Rows:=0; OriginalRows:=0; PreviewScans:=0;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  if (Length(Input)=0) or (Length(Input)>MaxImage) or (GetTickCount64>=Deadline) then Exit;
  AppPath:=ExtractFilePath(ParamStr(0));
  Python:=FindBookProcessingPython(AppPath);
  Script:=TPath.Combine(AppPath,'tools/bookconvert/tiff_jpeg.py');
  if (Python='') or not FileExists(Script) then Exit;
  Folder:=TPath.GetTempPath;
  SystemRoot:=GetEnvironmentVariable('SystemDrive')+'\';
  if not GetDiskFreeSpaceEx(PChar(SystemRoot),FreeSpace,TotalSpace,nil) or (FreeSpace<UInt64(8)*1024*1024*1024) then Exit;
  if not GetDiskFreeSpaceEx(PChar(Folder),FreeSpace,TotalSpace,nil) or (FreeSpace<2*MaxImage) then Exit;
  Work:=TPath.Combine(Folder,'hl-jpeg-'+TGUID.NewGuid.ToString);
  SourceName:=TPath.Combine(Work,'source.jpg'); TargetName:=TPath.Combine(Work,'recovered.jpg');
  Limit:=GetTickCount64+12000;
  if Deadline<Limit then Limit:=Deadline;
  Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    try
      TDirectory.CreateDirectory(Work);
      TFile.WriteAllBytes(SourceName,Input);
      RunExternalToolToStream(Python,['-I','-B','-X','utf8',Script,'recover',SourceName,TargetName],Log,
        function: Boolean
        begin
          if Assigned(IsCanceled) and IsCanceled() then Abort;
          if GetTickCount64>=Limit then raise Exception.Create('Превышено время восстановления JPEG.');
          Result:=False;
        end,0,True,256*1024*1024);
      Fields:=Log.DataString.Trim.Split([' ']);
      if (Length(Fields)<>3) or not TryStrToInt(Fields[0],Rows) or not TryStrToInt(Fields[1],OriginalRows) or
        not TryStrToInt(Fields[2],PreviewScans) or (Rows<1) or (OriginalRows<Rows) or (OriginalRows>65535) or
        (PreviewScans<0) or not FileExists(TargetName) or (TFile.GetSize(TargetName)>MaxImage) then Exit;
      Output:=TFile.ReadAllBytes(TargetName);
      Result:=Length(Output)>0;
    except
      on E: EAbort do raise;
      on E: Exception do LogDiagnosticTrace('jpeg-recovery',E.Message,'EPUB/FB2');
    end;
  finally
    Log.Free;
    System.SysUtils.DeleteFile(TargetName);
    System.SysUtils.DeleteFile(SourceName);
    if DirectoryExists(Work) then Winapi.Windows.RemoveDirectory(PChar(Work));
  end;
end;

function PrepareEpubMathImages(const Chapter: TBytes; Count: Integer; Deadline: UInt64;
  var Remaining: Int64; const IsCanceled: TFunc<Boolean>): TArray<TBytes>;
const MaxChapter = 8*1024*1024; MaxImage = 16*1024*1024;
var AppPath, Python, Script, TempRoot, Work, Source, Output: string; Log: TMemoryStream; Images: TZipFile;
  CheckCanceled: TFunc<Boolean>;
begin
  Result:=nil;
  if (Remaining<=0) or (Length(Chapter)>MaxChapter) or (Count<1) or (Count>256) or
    (GetTickCount64>=Deadline) then Exit;
  AppPath:=ExtractFilePath(ParamStr(0));
  Script:=TPath.Combine(AppPath,'tools/bookconvert/epub_math_reader.py');
  if not FileExists(Script) or not FileExists(TPath.Combine(AppPath,FormatComponentFile('EpubPdfExport'))) then Exit;
  Python:=FindBookProcessingPython(AppPath);
  if Python='' then Exit;
  TempRoot:=IncludeTrailingPathDelimiter(TPath.GetFullPath(TPath.GetTempPath));
  Work:=TPath.Combine(TempRoot,'hl-math-'+TGUID.NewGuid.ToString);
  Source:=TPath.Combine(Work,'chapter.xhtml'); Output:=TPath.Combine(Work,'formulas.zip');
  Log:=nil; Images:=nil;
  CheckCanceled:=function: Boolean
    begin
      if Assigned(IsCanceled) and IsCanceled() then raise EAbort.Create('Чтение отменено.');
      if GetTickCount64>=Deadline then raise Exception.Create('Отрисовка формул EPUB превысила 90 секунд.');
      Result:=False;
    end;
  try
    try
      CheckCanceled();
      TDirectory.CreateDirectory(Work);
      Log:=TMemoryStream.Create;
      TFile.WriteAllBytes(Source,Chapter);
      RunExternalToolToStream(Python,['-I','-B','-X','utf8',Script,Source,Output,
        TPath.Combine(AppPath,'tools'),IntToStr(Count)],Log,CheckCanceled,0,True,NativeUInt($80000000));
      CheckCanceled();
      if not FileExists(Output) or (TFile.GetSize(Output)>64*1024*1024+64*1024) then Exit;
      Images:=TZipFile.Create;
      Images.Open(Output,zmRead);
      if Images.FileCount>Count then Exit;
      SetLength(Result,Count);
      for var Index:=0 to Count-1 do
      begin
        CheckCanceled();
        var Entry:=Images.IndexOf(IntToStr(Index)+'.png');
        if Entry<0 then Continue;
        var Size:=Images.FileInfo[Entry].UncompressedSize;
        if (Size<1) or (Size>MaxImage) or (Size>Remaining) then Continue;
        Images.Read(Entry,Result[Index]);
        Dec(Remaining,Size);
      end;
    except
      on E: EAbort do raise;
      on E: Exception do
      begin
        LogDiagnosticTrace('epub-math',E.Message,'EPUB');
        Result:=nil;
      end;
    end;
  finally
    Images.Free; Log.Free;
    if Work.StartsWith(TempRoot,True) and DirectoryExists(Work) and
      (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
      try
        TDirectory.Delete(Work,True);
      except on E: Exception do LogDiagnosticTrace('epub-math-cleanup',E.Message,'EPUB'); end;
  end;
end;

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
        begin RegisterBookCacheFile(Result,OriginalSource); RecordBookConversionUse('.b1'); Exit; end;
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

function PrepareLegacyReflow(const SourceFile, OriginalSource, Extension: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Zip: TZipFile;
  Stamp, StampFile, Temporary, TemporaryStamp, Dependency: string;
  Attributes: TWin32FileAttributeData; Dependencies: TStringList;
  Canceled: TFunc<Boolean>; Archive: TMHLZip; NeedsPreparation: Boolean; CachePrefix: string; MaxInput: Int64;
begin
  Result:=SourceFile;
  if (Extension='.epub') and HasReadableEpubContainer(SourceFile) then Exit;
  Canceled:=function: Boolean
    begin
      Result:=(Assigned(IsCanceled) and IsCanceled()) or
        ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated);
    end;
  if Canceled() then Abort;
  // The native reader loads TIFF frames on demand. Retain the preparation
  // path for files the system decoder cannot read in full.
  if ((Extension='.tif') or (Extension='.tiff')) and CanReadTiffDirectly(SourceFile) then Exit;
  if Extension='.fb2' then
  begin
    if not GetFileAttributesEx(PChar(SourceFile),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    // Ordinary FB2 stays on the direct native path, including startup reads.
    // Image-heavy FB2 is prepared in an isolated process, keeping its large
    // base64 blocks out of the native XML DOM.
    if (Attributes.nFileSizeHigh=0) and (Attributes.nFileSizeLow<=64*1024*1024) then Exit;
  end;
  // A large RTF can carry both a JPEG and a legacy metafile for each figure.
  // Prepare it outside RichEdit and let the EPUB reader load figures on demand.
  if (Extension='.rtf') and (TFile.GetSize(SourceFile)<=MAX_NATIVE_RTF_SOURCE) then Exit;
  if (Extension='.cbz') or (Extension='.cbr') or (Extension='.cb7') then
  begin
    // Ordinary comics retain the native path. The preparer expands TIFF frames
    // and can recover verified pages from a damaged RAR or 7-Zip comic.
    NeedsPreparation:=False;
    try
      Archive:=TMHLZip.Create(SourceFile,True,False,Canceled,Extension<>'.cbz');
      try
        for var I:=0 to Archive.FileCount-1 do
          if SameText(ExtractFileExt(Archive.FileNames[I]),'.tif') or
            SameText(ExtractFileExt(Archive.FileNames[I]),'.tiff') then begin NeedsPreparation:=True; Break; end;
      finally Archive.Free; end;
    except
      on E: EMHLComponentRequired do raise;
      on E: EMHLExternalToolError do
      begin
        if Extension='.cbz' then raise;
        NeedsPreparation:=True;
      end;
    end;
    if not NeedsPreparation then Exit;
  end;
  var Missing:=MissingBookConversionComponents(Settings.AppPath,SourceFile,Extension,False,Canceled);
  if Length(Missing)>0 then raise EMHLComponentRequired.Create(Missing,
    'Для подготовки этой книги нужны компоненты: '+String.Join(', ',Missing)+'.');
  if not ModularBookProcessingAvailable(Settings.AppPath) then
    raise EMHLComponentRequired.Create('BookProcessing','Для этой книги нужна общая обработка книг; декодер формата устанавливается отдельно.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    MaxInput:=64*1024*1024;
    if (Extension='.tif') or (Extension='.tiff') or (Extension='.cbz') or (Extension='.cbr') or (Extension='.cb7') then MaxInput:=256*1024*1024;
    if Extension='.fb2' then MaxInput:=MAX_LARGE_FB2_CONVERSION_SOURCE;
    if Extension='.chm' then MaxInput:=MAX_CHM_CONVERSION_SOURCE;
    if Extension='.rtf' then MaxInput:=MAX_RTF_CONVERSION_SOURCE;
    if Input.Size>MaxInput then raise Exception.Create('Книга превышает предел читалки ('+IntToStr(MaxInput div 1024 div 1024)+' МБ).');
    Stamp:='legacy-reflow-v3|'+BookCacheInputStamp(SourceFile,OriginalSource);
    Dependencies:=TStringList.Create;
    try
      for Dependency in ['convert_book.py','text_inputs.py','epub_recovery.py','legacy_inputs.py','legacy_helper.py','rgo_input.py','rgo_outline.py','isilo_input.py','isilo_image.py','ibk_input.py','ibk_crypto.py','ibk_parameters.json','ibk_tables.bin','jutoh_input.py','pages_input.py', 'cr3_input.py', 'b1_input.py','xps_input.py','image_input.py','tiff_jpeg.py','office_inputs.py','kindle_input.py','fixed_layout.py','ha_input.py'] do
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
    if Extension='.epub' then CachePrefix:='homelib-epub-recovered-' else CachePrefix:='homelib-legacy-';
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,
      CachePrefix+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.epub'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin
          RegisterBookCacheFile(Result,OriginalSource); RecordBookConversionUse(Extension);
          if Assigned(OnStage) then OnStage('Открытие книги из кэша…'); Exit;
        end;
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

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Extension: string;
begin
  Extension:=LowerCase(ExtractFileExt(SourceFile));
  if not MatchText(Extension,['.mht','.mhtml']) then
  begin
    if (Extension='.rtf') or (Extension='.epub') or IsLegacyReaderFormat(Extension) then
      Exit(PrepareLegacyReflow(SourceFile,OriginalSource,Extension,OnStage,IsCanceled));
    Exit(SourceFile);
  end;

  // The compatible converter keeps same-document links while preparing tables.
  // The built-in reader is still available without that version.
  Result:=SourceFile;
  if not ModularBookProcessingAvailable(Settings.AppPath) or
    (BookProcessingSaveOptionsAPI(Settings.AppPath)<BOOK_PROCESSING_MHTML_LAYOUT_API) then Exit;
  try
    Result:=PrepareLegacyReflow(SourceFile,OriginalSource,Extension,OnStage,IsCanceled);
  except
    on E: EAbort do raise;
    on E: Exception do
    begin
      LogDiagnosticError('reader-mhtml-prepare',E);
      Result:=SourceFile;
    end;
  end;
end;

end.
