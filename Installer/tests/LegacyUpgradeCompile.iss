; Compile-only check. This test installer must not be run.
[Setup]
AppName=HomeLib Ru migration compile test
AppVersion=0
DefaultDirName={tmp}\HomeLibRu-migration-compile-only
OutputDir=..\Out\tests
OutputBaseFilename=LegacyUpgradeCompile
Uninstallable=no
CreateAppDir=no
PrivilegesRequired=lowest

#include "..\LegacyUpgrade.iss"
