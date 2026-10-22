unit unit_ReaderLegacy;

interface

uses System.SysUtils;

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, Winapi.Windows,
  unit_BookCache, unit_BookConversion, unit_ReaderFormats, dm_user;

function PrepareLegacyReaderFile(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Zip: TZipFile;
  Stamp, StampFile, Temporary, TemporaryStamp, Dependency: string;
  Attributes: TWin32FileAttributeData; Dependencies: TStringList;
  Canceled: TFunc<Boolean>;
begin
  Result:=SourceFile;
  if not IsLegacyReaderFormat(ExtractFileExt(SourceFile)) then Exit;
  Canceled:=function: Boolean
    begin
      Result:=(Assigned(IsCanceled) and IsCanceled()) or
        ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated);
    end;
  if Canceled() then Abort;
  Input:=OpenCachedBookFile(SourceFile);
  try
    if Input.Size>64*1024*1024 then raise Exception.Create('Книга превышает предел читалки (64 МБ).');
    Stamp:='legacy-reflow-v2|'+BookCacheInputStamp(SourceFile,OriginalSource);
    Dependencies:=TStringList.Create;
    try
      for Dependency in ['convert_book.py','text_inputs.py','legacy_inputs.py','legacy_helper.py','xps_input.py','image_input.py','office_inputs.py','kindle_input.py','fixed_layout.py','ha_input.py'] do
        Dependencies.Add(Settings.AppPath+'tools\bookconvert\'+Dependency);
      if DirectoryExists(Settings.AppPath+'tools\bookconvert\vendor\calibre_legacy') then
        for Dependency in TDirectory.GetFiles(Settings.AppPath+'tools\bookconvert\vendor\calibre_legacy','*',TSearchOption.soAllDirectories) do
          if SameText(ExtractFileExt(Dependency),'.py') or SameText(ExtractFileExt(Dependency),'.dll') then Dependencies.Add(Dependency);
      for Dependency in ['xps\HomeLibXps.exe','webp\libwebp.dll','doc\HomeLibDoc.exe'] do
        if FileExists(Settings.AppPath+'tools\'+Dependency) then Dependencies.Add(Settings.AppPath+'tools\'+Dependency);
      Dependencies.Sort;
      for Dependency in Dependencies do
      begin
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
