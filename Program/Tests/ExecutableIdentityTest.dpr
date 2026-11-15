program ExecutableIdentityTest;

{$APPTYPE CONSOLE}
{$R *.res}

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON, Winapi.Windows,
  unit_ComponentRemoval in '..\Units\unit_ComponentRemoval.pas',
  unit_ComponentUpdates in '..\Units\unit_ComponentUpdates.pas',
  unit_ApplicationIdentity in '..\Units\unit_ApplicationIdentity.pas',
  unit_ProgramUpdateInstaller in '..\Units\unit_ProgramUpdateInstaller.pas',
  unit_ProgramUpdates in '..\Units\unit_ProgramUpdates.pas';

procedure Guard(const Path: string);
begin
  if not TPath.GetFullPath(Path).StartsWith(IncludeTrailingPathDelimiter(TPath.GetTempPath),True) or
    not TPath.GetFullPath(Path).Contains('HomeLibRu-update-test-') then
    raise Exception.Create('An isolated update-test folder inside TEMP is required');
  AssertUpdatePath(Path);
end;

var Mode, Job, Target: string; Root: TJSONObject; Args: TJSONArray; Info: TProgramRelease;
begin
  SetTextCodePage(Output,CP_UTF8); SetTextCodePage(ErrOutput,CP_UTF8);
  try
    Mode:=ParamStr(1);
    if Mode='--probe' then
    begin
      Guard(ExtractFileDir(ParamStr(0)));
      Root:=TJSONObject.Create; Args:=TJSONArray.Create;
      try
        Root.AddPair('image',ParamStr(0)); Root.AddPair('cwd',GetCurrentDir);
        Root.AddPair('pid',TJSONNumber.Create(GetCurrentProcessId));
        Root.AddPair('args',Args);
        for var I:=2 to ParamCount do Args.Add(ParamStr(I));
        TFile.WriteAllText(TPath.Combine(ExtractFileDir(ParamStr(0)),'identity-result.json'),Root.ToJSON,TEncoding.UTF8);
      finally Root.Free; end;
    end
    else if Mode='--parent' then Sleep(StrToInt(ParamStr(2)))
    else if Mode='--metadata' then
    begin
      if not IsProgramUpdateApplicationName(CATALOGUE_APPLICATION) or
        not IsProgramUpdateApplicationName(LEGACY_CATALOGUE_APPLICATION) or
        not IsProgramUpdateApplicationName(READER_APPLICATION) or
        not IsProgramUpdateApplicationName(LEGACY_READER_APPLICATION) or
        not SafeUpdateName(READER_APPLICATION) or not SafeUpdateName(LEGACY_READER_APPLICATION) or
        IsProgramUpdateApplicationName('renamed.exe') or
        not SafeUpdateName(CATALOGUE_APPLICATION) or not SafeUpdateName(CATALOGUE_TRANSPORT_PATH) or
        SafeUpdateName('../HomeLibre.exe') or SafeUpdateName('Data/HomeLibre.exe') then
        raise Exception.Create('Executable identity allowlist');
      Root:=TJSONObject.Create;
      try
        if ReadProgramUpdateApplication(Root)<>LEGACY_CATALOGUE_APPLICATION then
          raise Exception.Create('Legacy request default');
        Root.AddPair('application',CATALOGUE_APPLICATION);
        if ReadProgramUpdateApplication(Root)<>CATALOGUE_APPLICATION then
          raise Exception.Create('Canonical request');
      finally Root.Free; end;
      if ForwardApplicationCommandLine('C:\new folder\HomeLibre.exe',
        '  "C:\old folder\HomeLibRu.exe" --open="G:\Books\book.fb2" user "My profile"')<>
        '"C:\new folder\HomeLibre.exe" --open="G:\Books\book.fb2" user "My profile"' then
        raise Exception.Create('Restart arguments');
      if ForwardApplicationCommandLine('C:\HomeLibre.exe','"C:\HomeLibRu.exe"')<>'"C:\HomeLibre.exe"' then
        raise Exception.Create('Empty restart arguments');
      for var I:=Low(UPDATE_COMPONENTS) to High(UPDATE_COMPONENTS) do
        if (UPDATE_COMPONENTS[I].ID='HomeLibReader') and (ComponentTitle(I)<>'HomeLibre Reader') then
          raise Exception.Create('Reader display title contains the legacy component ID');
      Writeln('PASS identity allowlist, legacy requests and verbatim restart parameters');
    end
    else if Mode='--reader-removal' then
    begin
      Guard(ParamStr(2));
      var Plan:=BuildComponentRemovalPlan(ParamStr(2),TArray<string>.Create('HomeLibReader'));
      Root:=TJSONObject.Create; Args:=TJSONArray.Create;
      try
        Root.AddPair('blocked',TJSONNumber.Create(Length(Plan.Blockers)));
        Root.AddPair('files',Args);
        for var Item in Plan.Files do if Item.Disposition=crRemove then Args.Add(Item.FileInfo.Name);
        Writeln(Root.ToJSON);
      finally Root.Free; end;
    end
    else if Mode='--reader-state' then
    begin
      Guard(ParamStr(2)); Root:=TJSONObject.Create;
      try
        Root.AddPair('file',InstalledComponentFileName(ParamStr(2),'HomeLibReader'));
        Root.AddPair('version',InstalledComponentVersion(ParamStr(2),'HomeLibReader'));
        Root.AddPair('repair',TJSONBool.Create(ComponentNeedsRepair(ParamStr(2),'HomeLibReader')));
        Root.AddPair('inventory',TJSONNumber.Create(Length(InstalledComponentFiles(ParamStr(2),'HomeLibReader'))));
        Writeln(Root.ToJSON);
      finally Root.Free; end;
    end
    else if Mode='--resolve' then
    begin Guard(ParamStr(2)); Writeln(InstalledApplicationName(ParamStr(2),ParamStr(3))); end
    else if Mode='--parse' then
    begin
      if not ParseProgramReleases(TFile.ReadAllText(ParamStr(2)),Info) then raise Exception.Create('No release');
      Writeln(Info.DownloadURL);
    end
    else if Mode='--prepare' then
    begin
      Guard(ParamStr(2)); Guard(ParamStr(5));
      PrepareProgramUpdate(ParamStr(2),ParamStr(3),ParamStr(4),ProgramUpdatePlatform,ParamStr(5),True,ParamStr(6),ParamStr(7));
      Writeln('PASS prepared identity and payload hashes');
    end
    else if Mode='--verify' then
    begin Guard(ParamStr(2)); VerifyPreparedProgramUpdate(ParamStr(2),ParamStr(3),ProgramUpdatePlatform); end
    else if Mode='--install' then
    begin
      Job:=ParamStr(2); Target:=ParamStr(3); Guard(Job); Guard(Target);
      InstallProgramUpdate(Job,Target,nil,StrToIntDef(ParamStr(4),-1));
    end
    else if Mode='--rollback' then
    begin Guard(ParamStr(2)); Guard(ParamStr(3)); RollbackProgramUpdate(ParamStr(2),ParamStr(3)); end
    else raise Exception.Create('Unknown test mode');
  except
    on E:Exception do begin Writeln(E.ClassName,': ',E.Message); Halt(1); end;
  end;
end.
