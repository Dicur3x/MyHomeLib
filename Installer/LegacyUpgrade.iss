; Remove obsolete application entry points only after a same-install upgrade.
[Code]
const
  LegacyUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{B9B6C409-01CB-4AB6-8E4F-403B49A25B56}_is1';

var
  LegacyUpgrade: Boolean;
  LegacyGroup: String;

function NormalizedUpgradePath(const Value: String): String;
begin
  Result := RemoveBackslashUnlessRoot(ExpandFileName(Value));
end;

function FindLegacyInstall(RootKey: Integer): Boolean;
var
  PreviousPath: String;
begin
  Result := False;
  if not RegQueryStringValue(RootKey, LegacyUninstallKey,
    'InstallLocation', PreviousPath) then Exit;
  if PreviousPath = '' then Exit;
  try
    Result := CompareText(NormalizedUpgradePath(PreviousPath),
      NormalizedUpgradePath(ExpandConstant('{app}'))) = 0;
  except
    Log('Keeping legacy files because the previous installation path is invalid.');
    Exit;
  end;
  if Result then
    RegQueryStringValue(RootKey, LegacyUninstallKey,
      'Inno Setup: Icon Group', LegacyGroup);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  LegacyUpgrade := False;
  LegacyGroup := '';
  if not FileExists(ExpandConstant('{app}\MyHomeLib.exe')) then Exit;
  // Read the previous registration before Setup replaces its uninstall key.
  LegacyUpgrade := FindLegacyInstall(HKLM32);
  if not LegacyUpgrade and IsWin64 then
    LegacyUpgrade := FindLegacyInstall(HKLM64);
end;

procedure DeleteLegacyShortcut(const Filename: String);
var
  Shell, Shortcut: Variant;
  Target: String;
begin
  if not FileExists(Filename) then Exit;
  try
    Shell := CreateOleObject('WScript.Shell');
    Shortcut := Shell.CreateShortcut(Filename);
    Target := Shortcut.TargetPath;
    // A same-named user shortcut may point at a different installation.
    if (Target <> '') and
       (CompareText(NormalizedUpgradePath(Target),
        NormalizedUpgradePath(ExpandConstant('{app}\MyHomeLib.exe'))) = 0) then
      if not DeleteFile(Filename) then
        Log('Could not remove obsolete application shortcut: ' + Filename);
  except
    Log('Keeping application shortcut because its target could not be verified: ' + Filename);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ProgramsRoot, PreviousGroupPath: String;
begin
  if (CurStep <> ssPostInstall) or not LegacyUpgrade then Exit;
  if not FileExists(ExpandConstant('{app}\HomeLibRu.exe')) then Exit;
  // Never remove the old entry point before the replacement was installed.
  if not DeleteFile(ExpandConstant('{app}\MyHomeLib.exe')) then
  begin
    Log('Keeping legacy application shortcuts: MyHomeLib.exe could not be removed.');
    Exit;
  end;
  DeleteLegacyShortcut(ExpandConstant('{group}\MyHomeLib.lnk'));
  DeleteLegacyShortcut(ExpandConstant('{commondesktop}\MyHomeLib.lnk'));
  if LegacyGroup <> '' then
  begin
    try
      ProgramsRoot := AddBackslash(NormalizedUpgradePath(ExpandConstant('{commonprograms}')));
      PreviousGroupPath := NormalizedUpgradePath(ProgramsRoot + LegacyGroup);
      if CompareText(Copy(PreviousGroupPath, 1, Length(ProgramsRoot)), ProgramsRoot) = 0 then
        DeleteLegacyShortcut(AddBackslash(PreviousGroupPath) + 'MyHomeLib.lnk');
    except
      Log('Keeping legacy Start menu shortcut because its directory is invalid.');
    end;
  end;
end;
