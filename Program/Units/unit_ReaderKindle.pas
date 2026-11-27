unit unit_ReaderKindle;

interface
uses System.SysUtils;
function PrepareKindleReflow(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil): string;
function PrepareKfxReflow(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;

implementation
uses System.Classes, System.IOUtils, System.Hash, System.Zip, Winapi.Windows,
  unit_ReaderFormats, unit_ComponentUsage, unit_ProgramUpdateInstaller,
  unit_BookCache, unit_MHLExternalTools, unit_BookConversion, unit_FormatComponents, unit_BookConversionRequirements, dm_user;

function PrepareKfxReflow(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
const KFX_READER_MIN_VERSION = '3.0.0.7';
var Input: TStream; Output: TMemoryStream; Zip: TZipFile; Writer: TBookCacheWrite;
  Tool, Stamp, Temporary, TemporaryStamp: string; Started: UInt64; Comparison: Integer;
begin
  Tool:=TPath.Combine(Settings.AppPath,'tools/kfx-export/boko.exe');
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  // Older modules can turn a linked illustration into an empty link.
  if not CompareComponentVersions(FormatComponentVersion(Settings.AppPath,'KfxExport'),
    KFX_READER_MIN_VERSION,Comparison) or (Comparison<0) then
    raise EMHLComponentRequired.Create('KfxExport','Для чтения этой книги установите актуальный модуль KFX/AZW8.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    if Input.Size>256*1024*1024 then
      raise EReadError.Create('Файл KFX/AZW8 превышает предел подготовки к чтению (256 МБ).');
    Stamp:='kfx-reflow-v1|'+BookCacheInputStamp(SourceFile,OriginalSource)+'|'+BookCacheInputStamp(Tool,Tool);
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,KFX_READER_CACHE_PREFIX+
      Copy(THashSHA2.GetHashString(Stamp),1,40)+'.epub'));
    if FileExists(Result) and FileExists(Result+'.source') and
      (TFile.ReadAllText(Result+'.source',TEncoding.UTF8)=Stamp) then
    begin
      RegisterBookCacheFile(Result,OriginalSource);
      PinReaderCacheFile(Result);
      RecordComponentUse('KfxExport');
      Exit;
    end;
    if Assigned(OnStage) then OnStage('Подготовка книги KFX/AZW8 для чтения…');
    ForceDirectories(ExtractFileDir(Result));
    Writer:=TBookCacheWrite.Create(OriginalSource);
    try
      Temporary:=Writer.TemporaryName(Result,True);
      TemporaryStamp:=Writer.TemporaryName(Result+'.source');
      Started:=GetTickCount64;
      Output:=TMemoryStream.Create;
      try
        try
          // AZW8 and KFX use the same container. The CLI recognizes only the
          // .kfx suffix automatically, so pass the format explicitly.
          RunExternalToolToStream(Tool,['convert','-q','-f','kfx','-t','epub',SourceFile,Temporary],Output,
            function: Boolean
            begin
              Result:=Assigned(IsCanceled) and IsCanceled();
              if not Result and (GetTickCount64-Started>120000) then
                raise EReadError.Create('Подготовка книги KFX/AZW8 заняла больше двух минут.');
            end,0,True,NativeUInt(768)*1024*1024);
        except
          on E:EMHLExternalToolError do
            raise EReadError.Create('Не удалось прочитать KFX/AZW8. Проверьте, что это отдельный файл книги без DRM.');
        end;
      finally Output.Free; end;
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      if not FileExists(Temporary) then raise EReadError.Create('Модуль KFX/AZW8 не создал книгу для чтения.');
      Zip:=TZipFile.Create;
      try
        Zip.Open(Temporary,zmRead);
        if Zip.IndexOf('META-INF/container.xml')<0 then
          raise EReadError.Create('Модуль KFX/AZW8 создал неполную книгу.');
      finally Zip.Free; end;
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      if Assigned(IsCanceled) and IsCanceled() then Abort;
      Writer.Publish(Temporary,Result,TemporaryStamp);
      PinReaderCacheFile(Result);
      RecordComponentUse('KfxExport');
    finally Writer.Free; end;
  finally Input.Free; end;
end;

function PrepareKindleReflow(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>): string;
var Input: TStream; Header: TBytes; Offset, Version: Cardinal;
  ResultStamp, StampFile, Temporary, TemporaryStamp, Work, Tool, Script: string;
  Writer: TBookCacheWrite; Log: TStringStream; Started: UInt64; Attributes: TWin32FileAttributeData;
  function BigEndian(Index: Integer): Cardinal;
  begin Result := Cardinal(Header[Index]) shl 24 or Cardinal(Header[Index+1]) shl 16 or
    Cardinal(Header[Index+2]) shl 8 or Cardinal(Header[Index+3]); end;
begin
  Result := SourceFile;
  if not (SameText(ExtractFileExt(SourceFile),'.azw3') or SameText(ExtractFileExt(SourceFile),'.azw') or
    SameText(ExtractFileExt(SourceFile),'.mobi') or SameText(ExtractFileExt(SourceFile),'.prc')) then Exit;
  Input := OpenCachedBookFile(SourceFile);
  try
    if Input.Size < 86 then Exit;
    SetLength(Header,86); Input.ReadBuffer(Header[0],86);
    if (TEncoding.ASCII.GetString(Header,60,8) <> 'BOOKMOBI') then Exit;
    Offset := BigEndian(78); if UInt64(Offset)+40 > UInt64(Input.Size) then Exit;
    Input.Position := Offset; SetLength(Header,40); Input.ReadBuffer(Header[0],40);
    if TEncoding.ASCII.GetString(Header,16,4) <> 'MOBI' then Exit;
    Version := BigEndian(36);
    var Missing:=MissingBookConversionComponents(Settings.AppPath,SourceFile,ExtractFileExt(SourceFile),False,
      function:Boolean begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end);
    if Length(Missing)>0 then raise EMHLComponentRequired.Create(Missing,
      'Для подготовки Kindle-книги нужны компоненты: '+String.Join(', ',Missing)+'.');
    Tool := FindBookProcessingPython(Settings.AppPath);
    Script := Settings.AppPath+'tools\kindle\convert_kf8.py';
    if Tool='' then
      raise EMHLComponentRequired.Create('BookProcessing','Для подготовки этой книги нужна общая среда обработки книг.');
    if not FileExists(Script) then
      raise EMHLComponentRequired.Create('Kindle','Для этой книги нужен модуль KindleUnpack (MOBI/AZW/KF8).');
    if not GetFileAttributesEx(PChar(SourceFile),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    ResultStamp := 'kindleunpack-bf0ca6e-v9|'+BookCacheInputStamp(SourceFile,OriginalSource);
    Result := ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-kindle-'+
      Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.epub'));
    StampFile := Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try if TFile.ReadAllText(StampFile,TEncoding.UTF8) = ResultStamp then
      begin
        RegisterBookCacheFile(Result,OriginalSource); RecordBookConversionUse('.mobi'); Exit;
      end; except end;
    if Assigned(OnStage) then OnStage('Подготовка книги Kindle для чтения…');
    Writer := TBookCacheWrite.Create(OriginalSource); Log := TStringStream.Create('',TEncoding.UTF8);
    Work := TPath.Combine(Settings.TempDir,'homelib-kindle-'+TGUID.NewGuid.ToString);
    try
      Temporary := Writer.TemporaryName(Result,True); TemporaryStamp := Writer.TemporaryName(StampFile);
      Started := GetTickCount64;
      if (Version <> 8) or (Header[12]<>0) or (Header[13]<>0) then
        ConvertBasicBook(Settings.AppPath,Settings.TempDir,SourceFile,ExtractFileExt(SourceFile),Temporary,nil,nil,
          function: Boolean begin Result:=(GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated; end,'','','',True)
      else RunExternalToolToStream(Tool,['-I','-B',Script,SourceFile,Temporary,Work],Log,
        function: Boolean
        begin
          Result := False;
          if GetCurrentThreadID <> MainThreadID then Result := TThread.CheckTerminated;
          if GetTickCount64-Started > 60000 then
            raise Exception.Create('Подготовка книги Kindle превысила допустимое время.');
        end);
      if not FileExists(Temporary) then raise Exception.Create('Не удалось подготовить EPUB из книги Kindle.');
      RecordBookConversionUse('.mobi');
      TFile.WriteAllText(TemporaryStamp,ResultStamp,TEncoding.UTF8);
      Writer.Publish(Temporary,Result,TemporaryStamp);
    finally
      // Work is a fresh GUID directory belonging to this conversion alone.
      try
        if Work.StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(Settings.TempDir)),True) and
          DirectoryExists(Work) and (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT = 0) then
          TDirectory.Delete(Work,True);
      except
        // A locked helper temporary is also covered by session-temp cleanup.
      end;
      Log.Free; Writer.Free;
    end;
  finally
    if FileExists(Result) then PinReaderCacheFile(Result);
    Input.Free;
  end;
end;
end.
