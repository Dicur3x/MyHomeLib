program ProgramUpdateInstallerTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Winapi.Windows, Winapi.Messages, System.Net.HttpClient, System.Net.URLClient,
  unit_ProgramUpdates in '..\Units\unit_ProgramUpdates.pas',
  unit_ComponentUpdates in '..\Units\unit_ComponentUpdates.pas',
  unit_ReaderFontDownloads in '..\Units\unit_ReaderFontDownloads.pas',
  unit_BookConversion in '..\Units\unit_BookConversion.pas',
  unit_UpdateAuthenticity in '..\Units\unit_UpdateAuthenticity.pas',
  unit_ProgramUpdateInstaller in '..\Units\unit_ProgramUpdateInstaller.pas',
  unit_ReaderRestartState in '..\Units\unit_ReaderRestartState.pas',
  unit_UpdateRelatedInstances in '..\Units\unit_UpdateRelatedInstances.pas';

procedure Guard(const Path: string);
var Temp, Full: string;
begin
  Temp := IncludeTrailingPathDelimiter(TPath.GetTempPath);
  Full := TPath.GetFullPath(Path);
  if not Full.StartsWith(Temp, True) or (Pos('HomeLibRu-update-test-', Full) = 0) then
    raise Exception.Create('Tests require an isolated update-test directory in TEMP');
  AssertUpdatePath(Full);
end;

{$I ComponentCheckFixture.inc}
{$I RelatedInstanceFixture.inc}

procedure InstallWithLateLock(const Job, Target, Name: string; HoldMS: Integer);
var Released: TThread; Held: THandle; Started: Boolean; LockFile: string;
begin
  if (HoldMS<1) or (HoldMS>10000) then raise Exception.Create('Invalid fixture lock duration');
  if Name='journal' then LockFile:=TPath.Combine(Job,'journal.json')
  else if Name='LICENSE' then LockFile:=TPath.Combine(Target,Name)
  else raise Exception.Create('Unsupported fixture lock');
  Guard(LockFile); Released:=nil; Held:=INVALID_HANDLE_VALUE; Started:=False;
  try
    InstallProgramUpdate(Job,Target,
      procedure(const Text: string; Position, Total: Integer)
      begin
        if Started then Exit;
        // The real installer has finished preflight and its first journal write.
        Held:=CreateFile(PChar(LockFile),GENERIC_READ,FILE_SHARE_READ,nil,
          OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
        if Held=INVALID_HANDLE_VALUE then RaiseLastOSError;
        try
          Released:=TThread.CreateAnonymousThread(procedure
            begin Sleep(HoldMS); CloseHandle(Held); end);
          Released.FreeOnTerminate:=False; Released.Start; Started:=True;
        except CloseHandle(Held); Held:=INVALID_HANDLE_VALUE; raise; end;
      end);
    if not Started then raise Exception.Create('Late lock fixture never reached installation');
  finally
    if Assigned(Released) then begin Released.WaitFor; Released.Free; end;
  end;
end;

var Mode, Job, Target, Archive, Digest, Tag: string; Files: TUpdateFiles;
  Comparison: Integer; Info: TProgramRelease; Thread: TProgramDownloadThread;
  Window: HWND; HTTP: THTTPClient; Msg: TMsg; Params: TJSONArray; I: Integer;
  Lock: TFileStream; Components: TComponentReleases;
  LibraryHandle: HMODULE; LibraryDeadline: UInt64;
  ComponentThread: TComponentUpdateThread;
  Jobs: TArray<string>;
  Detail: TJSONObject; URLList: TJSONArray; FixtureWorker: TComponentCheckFixtureWorker;
  ConversionWarnings: TStringList; ConversionChecks: Integer; ConversionStream: TMemoryStream;
begin
  SetTextCodePage(Output,CP_UTF8); SetTextCodePage(ErrOutput,CP_UTF8);
  try
    Mode := ParamStr(1);
    if Mode='--related-fixture' then begin RunRelatedInstanceFixture; Halt(0); end;
    if Mode='--related-cycle' then
    begin RunRelatedInstanceCycle(ParamStr(2),ParamStr(3),StrToInt(ParamStr(4))); Halt(0); end;
    if Mode = 'program-update-download' then
    begin
      Guard(ExtractFilePath(ParamStr(0)));
      TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'update-restarted.txt',
        ParamStr(2) + sLineBreak + ParamStr(3) + sLineBreak + ParamStr(4), TEncoding.UTF8);
      Halt(0);
    end;
    if Mode = '--convert' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3)); Guard(ParamStr(4));
      ConversionWarnings:=TStringList.Create; ConversionChecks:=0; ConversionStream:=nil;
      try
        if ParamStr(6)='--stream' then
        begin
          ConversionStream:=TMemoryStream.Create;
          ConversionStream.LoadFromFile(ParamStr(2)); ConversionStream.Position:=3;
        end;
        ConvertBasicBook(ParamStr(5),ParamStr(4),ParamStr(2),ExtractFileExt(ParamStr(2)),ParamStr(3),ConversionStream,
          ConversionWarnings,function: Boolean
            begin
              Inc(ConversionChecks);
              // Two checks precede CreateProcess; cancel after the child starts.
              Result:=(ParamStr(6)='--cancel') and (ConversionChecks>2);
            end);
        if Assigned(ConversionStream) and (ConversionStream.Position<>3) then
          raise Exception.Create('Conversion changed caller stream position');
        Writeln(ConversionWarnings.Text);
      finally ConversionStream.Free; ConversionWarnings.Free; end;
      Writeln('PASS conversion'); Halt(0);
    end;
    if Mode = '--probe' then
    begin
      Guard(ExtractFilePath(ParamStr(0)));
      Params := TJSONArray.Create;
      try
        for I := 2 to ParamCount do Params.Add(ParamStr(I));
        TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'probe.json', Params.ToJSON, TEncoding.UTF8);
      finally Params.Free; end;
      Halt(0);
    end;
    if Mode = '--parent' then
    begin
      Guard(ExtractFilePath(ParamStr(0)));
      TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'parent-ready.txt', 'ready');
      Sleep(StrToInt(ParamStr(2))); Halt(0);
    end;
    if Mode = '--holdfile' then
    begin
      Guard(ParamStr(2));
      Lock := TFileStream.Create(ParamStr(2), fmOpenReadWrite or fmShareExclusive);
      try
        TFile.WriteAllText(ParamStr(2) + '.locked', 'ready');
        Sleep(5000);
      finally Lock.Free; end;
      Halt(0);
    end;
    if Mode = '--holdlibrary' then
    begin
      Guard(ParamStr(2));
      LibraryHandle:=LoadLibraryEx(PChar(ParamStr(2)),0,LOAD_WITH_ALTERED_SEARCH_PATH);
      if LibraryHandle=0 then RaiseLastOSError;
      try
        TFile.WriteAllText(ParamStr(2)+'.locked','ready');
        LibraryDeadline:=GetTickCount64+30000;
        while not FileExists(ParamStr(2)+'.release') and
          (GetTickCount64<LibraryDeadline) do Sleep(25);
      finally FreeLibrary(LibraryHandle); end;
      Halt(0);
    end;
    if Mode = '--metadata' then
    begin
      if not ProgramUpdateDue(0, 100, 1440) or ProgramUpdateDue(100, 100.4, 1440) or
         not ProgramUpdateDue(100, 101, 1440) or not ProgramUpdateDue(100, 103, 4320) or
         ProgramUpdateDue(100, 102, 4320) or ProgramUpdateDue(100, 106, 10080) or
         not ProgramUpdateDue(100, 107, 10080) or ProgramUpdateDue(0, 100, 0) or
         not ProgramUpdateDue(110, 100, 60) or not ProgramUpdateDue(100, 100.2, 17) then
        raise Exception.Create('schedule');
      if SafeUpdateName('../evil') or SafeUpdateName('Data/collections.db') or
         SafeUpdateName('Readers/AlReader/options.ini') or SafeUpdateName('C:/file') or
         SafeUpdateName('Help/file:ads') or SafeUpdateName('Help/../data') or
         SafeUpdateName('Help/file.') or not SafeUpdateName('Readers/AlReader/$savevtut.ini') then
        raise Exception.Create('safe names');
      if not CompareReleaseTags('2.7.0_pre5.11', '2.7.0_pre5.10', Comparison) or (Comparison <> 1) then
        raise Exception.Create('numeric release ordering');
    end
    else if Mode = '--parse' then
    begin
      if not ParseProgramReleases(TFile.ReadAllText(ParamStr(2)), Info) then
        raise Exception.Create('release parse failed');
      Params := TJSONArray.Create;
      try
        Params.Add(Info.Tag); Params.Add(Info.DownloadURL); Params.Add(Info.SHA256);
        Params.Add(Info.Size); Params.Add(Info.Changelog); Params.Add(Info.History);
        Writeln(Params.ToJSON);
      finally Params.Free; end;
    end
    else if Mode='--font-download' then
    begin
      Guard(ParamStr(3));
      if not DownloadReaderFontFamily(ParamStr(4),ParamStr(2),ParamStr(3),
        function: Boolean begin Result:=ParamStr(5)='cancel'; end) then raise Exception.Create('Font download did not complete');
      Writeln('PASS pinned font family cached');
    end
    else if Mode='--official-url' then
    begin
      if not IsOfficialComponentURL(ParamStr(2),ParamStr(3),ParamStr(4),ProgramUpdatePlatform,ParamStr(5)='secondary') then
        raise Exception.Create('Foreign or malformed official URL');
      Writeln('PASS official URL');
    end
    else if Mode = '--sha3' then
    begin Guard(ParamStr(2)); Writeln(UpdateSHA3(ParamStr(2))); end
    else if Mode = '--signature' then
    begin VerifySumatraSignature(ParamStr(2)); end
    else if Mode='--component-needs-repair' then
    begin
      Guard(ParamStr(2));
      Writeln(Ord(ComponentNeedsRepair(ParamStr(2),ParamStr(3))));
    end
    else if Mode='--prepared-helper' then
    begin
      Guard(ParamStr(2));
      Writeln(PreparedProgramUpdateHelper(ParamStr(2),ParamStr(3),ProgramUpdatePlatform,ParamStr(4)));
    end
    else if Mode = '--official-prepare' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3));
      Archive:=ParamStr(6); if Archive='-' then Archive:='';
      PrepareOfficialComponent(ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5), ProgramUpdatePlatform,Archive,ParamStr(7));
    end
    else if (Mode = '--sqlite-parse') or (Mode = '--sumatra-parse') or (Mode = '--raster-parse') then
    begin
      if Mode = '--sqlite-parse' then
      begin
        if not ParseSQLiteDownload(TFile.ReadAllText(ParamStr(2)), TFile.ReadAllText(ParamStr(3)), Info) then
          raise Exception.Create('SQLite metadata parse failed');
      end
      else if Mode='--raster-parse' then
      begin
        if not ParseRasterComponent(TFile.ReadAllText(ParamStr(2)),ParamStr(3),Info) then
          raise Exception.Create('Raster version check parse failed');
      end
      else if not ParseSumatraReleases(TFile.ReadAllText(ParamStr(2)), Info) then
        raise Exception.Create('Sumatra metadata parse failed');
      Params := TJSONArray.Create;
      try
        Params.Add(Info.ComponentVersion); Params.Add(Info.DownloadURL); Params.Add(Info.SourceSHA3);
        Params.Add(Info.Size); Params.Add(ComponentChanges(Info, ParamStr(4))); Params.Add(Info.History);
        Writeln(Params.ToJSON);
      finally Params.Free; end;
    end
    else if (Mode = '--official-check') or (Mode='--official-check-details') or (Mode='--component-check-fixture') then
    begin
      if Mode='--component-check-fixture' then
      begin
        FixtureWorker:=TComponentCheckFixtureWorker.Create(0,ParamStr(2),ParamStr(3));
        ComponentThread:=FixtureWorker;
      end
      else
      begin
        HTTP := THTTPClient.Create;
        HTTP.ProxySettings := TProxySettings.Create('direct', 80, '', '', 'http');
        ComponentThread := TComponentUpdateThread.Create(0, HTTP, '');
      end;
      try
        ComponentThread.Start; ComponentThread.WaitFor;
        if not ComponentThread.Successful then raise Exception.Create(ComponentThread.ErrorText);
        Components := ComponentThread.Releases;
        Params := TJSONArray.Create;
        try
          for I := 0 to High(Components) do
          begin
            if Mode='--official-check' then
            begin
              Params.Add(Components[I].ComponentID); Params.Add(Components[I].ComponentVersion);
              Params.Add(Components[I].DownloadURL); Params.Add(Components[I].Size);
              Params.Add(Components[I].ComponentError);
            end
            else
            begin
              Detail:=TJSONObject.Create; Params.AddElement(Detail);
              Detail.AddPair('id',Components[I].ComponentID); Detail.AddPair('version',Components[I].ComponentVersion);
              Detail.AddPair('url',Components[I].DownloadURL); Detail.AddPair('secondary',Components[I].SecondaryURL);
              Detail.AddPair('size',TJSONNumber.Create(Components[I].Size));
              Detail.AddPair('error',Components[I].ComponentError); Detail.AddPair('warning',Components[I].ComponentWarning);
              Detail.AddPair('details',Components[I].ComponentErrorDetails);
              Detail.AddPair('official',TJSONBool.Create(Components[I].OfficialComponent));
              Detail.AddPair('checkOnly',TJSONBool.Create(Components[I].CheckOnly));
              URLList:=TJSONArray.Create; Detail.AddPair('additional',URLList);
              for var URL in Components[I].AdditionalURLs do URLList.Add(URL);
            end;
          end;
          Writeln(Params.ToJSON);
          if Mode='--component-check-fixture' then
            Writeln('REQUESTS ',FixtureWorker.Requests.Text.Replace(sLineBreak,' | '));
        finally Params.Free; end;
      finally ComponentThread.Free; end;
    end
    else if Mode = '--components' then
    begin
      if not ParseComponentFeed(TFile.ReadAllText(ParamStr(2)), ParamStr(3),
        TFile.ReadAllText(ParamStr(4)), Components, True, ParamStr(6)='--partial') then
        raise Exception.Create('component feed');
      Params := TJSONArray.Create;
      try
        for I := 0 to High(Components) do
        begin
          Params.Add(Components[I].ComponentVersion);
          Params.Add(Components[I].DownloadURL);
          Params.Add(ComponentChanges(Components[I], ParamStr(5)));
        end;
        Writeln(Params.ToJSON);
      finally Params.Free; end;
    end
    else if Mode = '--combine' then
    begin
      Job := ParamStr(2); Tag := ParamStr(3); Guard(Job);
      SetLength(Jobs, ParamCount - 3);
      for I := 4 to ParamCount do begin Guard(ParamStr(I)); Jobs[I - 4] := ParamStr(I); end;
      Writeln(CombinePreparedProgramUpdates(Jobs, Tag, ProgramUpdatePlatform, Job));
      VerifyPreparedProgramUpdate(Job, Tag, ProgramUpdatePlatform);
    end
    else if Mode = '--prepare-component' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(5));
      Files := PrepareProgramUpdate(ParamStr(2), ParamStr(3), ParamStr(4),
        ProgramUpdatePlatform, ParamStr(5), True, ParamStr(6), ParamStr(7));
      Writeln('FILES ', Length(Files));
    end
    else if Mode = '--prepare' then
    begin
      Archive := ParamStr(2); Digest := ParamStr(3); Tag := ParamStr(4); Job := ParamStr(5);
      Guard(Job); Guard(Archive);
      Files := PrepareProgramUpdate(Archive, Digest, Tag, ProgramUpdatePlatform, Job,
        ParamStr(6) <> '--fixture');
      Writeln('FILES ', Length(Files));
    end
    else if Mode = '--install-with-late-lock' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3));
      InstallWithLateLock(ParamStr(2),ParamStr(3),ParamStr(4),StrToInt(ParamStr(5)));
    end
    else if Mode = '--install' then
    begin
      Job := ParamStr(2); Target := ParamStr(3); Guard(Job); Guard(Target);
      InstallProgramUpdate(Job, Target, nil, StrToIntDef(ParamStr(4), -1));
    end
    else if Mode = '--rollback' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3)); RollbackProgramUpdate(ParamStr(2), ParamStr(3));
    end
    else if (Mode = '--download') or (Mode = '--download-doc') then
    begin
      Job := ParamStr(6); Guard(Job);
      if Mode='--download-doc' then
      begin
        Guard(ExtractFilePath(ParamStr(0)));
        if not ParseDocSharpVersions('{"versions":["'+ParamStr(2)+'"]}',
          '{"versions":["'+ParamStr(2)+'"]}',Info) then raise Exception.Create('Official DOC pair metadata failed');
        Info.SecondarySize:=StrToInt64(ParamStr(4)); Info.Size:=StrToInt64(ParamStr(3))+Info.SecondarySize;
        if ParamStr(7)='--bad-second-size' then begin Inc(Info.SecondarySize); Inc(Info.Size); end;
      end
      else
      begin
        Info := Default(TProgramRelease); Info.DownloadURL := ParamStr(2);
        Info.Size := StrToInt64(ParamStr(3)); Info.SHA256 := ParamStr(4); Info.Tag := ParamStr(5);
      end;
      Window := CreateWindowEx(0, 'STATIC', 'update test', 0, 0, 0, 0, 0, HWND_MESSAGE, 0, HInstance, nil);
      HTTP := THTTPClient.Create;
      HTTP.ProxySettings := TProxySettings.Create('direct', 80, '', '', 'http');
      Thread := TProgramDownloadThread.Create(Window, HTTP, Info, Job);
      try
        Thread.Start;
        if ParamStr(7) = '--cancel' then begin Sleep(100); Thread.Terminate; end;
        Thread.WaitFor;
        if not PeekMessage(Msg, Window, WM_PROGRAM_UPDATE_DOWNLOADED, WM_PROGRAM_UPDATE_DOWNLOADED,
          PM_REMOVE) then raise Exception.Create('missing completion message');
        if not Thread.Successful then raise Exception.Create(Thread.ErrorText);
      finally Thread.Free; DestroyWindow(Window); end;
    end
    else raise Exception.Create('unknown test mode');
    Writeln('PASS');
  except
    on E: Exception do begin Writeln(ErrOutput, 'FAIL: ', E.Message); Halt(1); end;
  end;
end.
