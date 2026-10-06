program ProgramUpdateInstallerTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Winapi.Windows, Winapi.Messages, System.Net.HttpClient, System.Net.URLClient,
  unit_ProgramUpdates in '..\Units\unit_ProgramUpdates.pas',
  unit_ComponentUpdates in '..\Units\unit_ComponentUpdates.pas',
  unit_UpdateAuthenticity in '..\Units\unit_UpdateAuthenticity.pas',
  unit_ProgramUpdateInstaller in '..\Units\unit_ProgramUpdateInstaller.pas';

procedure Guard(const Path: string);
var Temp, Full: string;
begin
  Temp := IncludeTrailingPathDelimiter(TPath.GetTempPath);
  Full := TPath.GetFullPath(Path);
  if not Full.StartsWith(Temp, True) or (Pos('HomeLibRu-update-test-', Full) = 0) then
    raise Exception.Create('Tests require an isolated update-test directory in TEMP');
  AssertUpdatePath(Full);
end;

var Mode, Job, Target, Archive, Digest, Tag: string; Files: TUpdateFiles;
  Comparison: Integer; Info: TProgramRelease; Thread: TProgramDownloadThread;
  Window: HWND; HTTP: THTTPClient; Msg: TMsg; Params: TJSONArray; I: Integer;
  Lock: TFileStream; Components: TComponentReleases;
  ComponentThread: TComponentUpdateThread;
begin
  try
    Mode := ParamStr(1);
    if Mode = 'program-update-download' then
    begin
      Guard(ExtractFilePath(ParamStr(0)));
      TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + 'update-restarted.txt',
        ParamStr(2) + sLineBreak + ParamStr(3) + sLineBreak + ParamStr(4), TEncoding.UTF8);
      Halt(0);
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
    else if Mode = '--sha3' then
    begin Guard(ParamStr(2)); Writeln(UpdateSHA3(ParamStr(2))); end
    else if Mode = '--signature' then
    begin VerifySumatraSignature(ParamStr(2)); end
    else if Mode = '--official-prepare' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3));
      PrepareOfficialComponent(ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5), ProgramUpdatePlatform);
    end
    else if (Mode = '--sqlite-parse') or (Mode = '--sumatra-parse') then
    begin
      if Mode = '--sqlite-parse' then
      begin
        if not ParseSQLiteDownload(TFile.ReadAllText(ParamStr(2)), TFile.ReadAllText(ParamStr(3)), Info) then
          raise Exception.Create('SQLite metadata parse failed');
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
    else if Mode = '--official-check' then
    begin
      HTTP := THTTPClient.Create;
      HTTP.ProxySettings := TProxySettings.Create('direct', 80, '', '', 'http');
      ComponentThread := TComponentUpdateThread.Create(0, HTTP);
      try
        ComponentThread.Start; ComponentThread.WaitFor;
        if not ComponentThread.Successful then raise Exception.Create(ComponentThread.ErrorText);
        Components := ComponentThread.Releases;
        Params := TJSONArray.Create;
        try
          for I := 0 to 2 do
          begin
            Params.Add(Components[I].ComponentID); Params.Add(Components[I].ComponentVersion);
            Params.Add(Components[I].DownloadURL); Params.Add(Components[I].Size);
            Params.Add(Components[I].ComponentError);
          end;
          Writeln(Params.ToJSON);
        finally Params.Free; end;
      finally ComponentThread.Free; end;
    end
    else if Mode = '--components' then
    begin
      if not ParseComponentFeed(TFile.ReadAllText(ParamStr(2)), ParamStr(3),
        TFile.ReadAllText(ParamStr(4)), Components) then raise Exception.Create('component feed');
      Params := TJSONArray.Create;
      try
        for I := 0 to 2 do
        begin
          Params.Add(Components[I].ComponentVersion);
          Params.Add(Components[I].DownloadURL);
          Params.Add(ComponentChanges(Components[I], ParamStr(5)));
        end;
        Writeln(Params.ToJSON);
      finally Params.Free; end;
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
    else if Mode = '--install' then
    begin
      Job := ParamStr(2); Target := ParamStr(3); Guard(Job); Guard(Target);
      InstallProgramUpdate(Job, Target, nil, StrToIntDef(ParamStr(4), -1));
    end
    else if Mode = '--rollback' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(3)); RollbackProgramUpdate(ParamStr(2), ParamStr(3));
    end
    else if Mode = '--download' then
    begin
      Job := ParamStr(6); Guard(Job);
      Info := Default(TProgramRelease); Info.DownloadURL := ParamStr(2);
      Info.Size := StrToInt64(ParamStr(3)); Info.SHA256 := ParamStr(4); Info.Tag := ParamStr(5);
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
