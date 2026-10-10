unit unit_ReaderKindle;

interface
uses System.SysUtils;
function PrepareKindleReflow(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil): string;

implementation
uses System.Classes, System.IOUtils, System.Hash, Winapi.Windows,
  unit_BookCache, unit_MHLExternalTools, dm_user;

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
    SameText(ExtractFileExt(SourceFile),'.mobi')) then Exit;
  Input := OpenCachedBookFile(SourceFile);
  try
    if Input.Size < 86 then Exit;
    SetLength(Header,86); Input.ReadBuffer(Header[0],86);
    if (TEncoding.ASCII.GetString(Header,60,8) <> 'BOOKMOBI') then Exit;
    Offset := BigEndian(78); if UInt64(Offset)+40 > UInt64(Input.Size) then Exit;
    Input.Position := Offset; SetLength(Header,40); Input.ReadBuffer(Header[0],40);
    if TEncoding.ASCII.GetString(Header,16,4) <> 'MOBI' then Exit;
    Version := BigEndian(36); if Version <> 8 then Exit;
    if (Header[12] <> 0) or (Header[13] <> 0) then
      raise Exception.Create('Эта книга Kindle защищена шифрованием. Для неё требуется совместимая читалка.');
    Tool := Settings.AppPath+'tools\kindle\python\python.exe';
    Script := Settings.AppPath+'tools\kindle\convert_kf8.py';
    if not FileExists(Tool) or not FileExists(Script) then
      raise Exception.Create('Не найден компонент чтения Kindle. Проверьте комплектность папки программы.');
    if not GetFileAttributesEx(PChar(SourceFile),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    ResultStamp := 'kindleunpack-bf0ca6e-v1|'+SourceFile+'|'+IntToStr(Input.Size)+'|'+
      IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
    Result := ExistingBookCacheFile(TPath.Combine(BookCachePath,'homelib-kindle-'+
      Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.epub'));
    StampFile := Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try if TFile.ReadAllText(StampFile,TEncoding.UTF8) = ResultStamp then
      begin RegisterBookCacheFile(Result,OriginalSource); Exit; end; except end;
    if Assigned(OnStage) then OnStage('Подготовка книги Kindle для чтения…');
    Writer := TBookCacheWrite.Create(OriginalSource); Log := TStringStream.Create('',TEncoding.UTF8);
    Work := TPath.Combine(Settings.TempDir,'homelib-kindle-'+TGUID.NewGuid.ToString);
    try
      Temporary := Writer.TemporaryName(Result); TemporaryStamp := Writer.TemporaryName(StampFile);
      Started := GetTickCount64;
      RunExternalToolToStream(Tool,['-I','-B',Script,SourceFile,Temporary,Work],Log,
        function: Boolean
        begin
          Result := False;
          if GetCurrentThreadID <> MainThreadID then Result := TThread.CheckTerminated;
          if GetTickCount64-Started > 60000 then
            raise Exception.Create('Подготовка книги Kindle превысила допустимое время.');
        end);
      if not FileExists(Temporary) then raise Exception.Create('Не удалось подготовить EPUB из книги Kindle.');
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
  finally Input.Free; end;
end;
end.
