unit unit_ProfileIni;

interface

const
  SETTINGS_FILE_NAME = 'HomeLibre.ini';
  READER_SETTINGS_FILE_NAME = 'HomeLibreReader.ini';

function LegacyProfileIniFile(const FileName: string): string;
function ReadableProfileIniFile(const FileName: string): string;
function MigrateProfileIniFile(const FileName: string): string;

implementation

uses System.SysUtils, System.IOUtils, Winapi.Windows, unit_ProgramUpdatePaths;

function LegacyProfileIniFile(const FileName: string): string;
begin
  Result := '';
  if SameText(ExtractFileName(FileName), SETTINGS_FILE_NAME) then
    Result := ExtractFilePath(FileName) + 'myhomelib2.ini'
  else if SameText(ExtractFileName(FileName), READER_SETTINGS_FILE_NAME) then
    Result := ExtractFilePath(FileName) + 'HomeLibReader.ini';
end;

function ReadableProfileIniFile(const FileName: string): string;
var Legacy: string;
begin
  Result := FileName;
  if FileExists(UpdateIOPath(FileName)) then Exit;
  Legacy := LegacyProfileIniFile(FileName);
  if (Legacy <> '') and FileExists(UpdateIOPath(Legacy)) then Result := Legacy;
end;

function MigrateProfileIniFile(const FileName: string): string;
var Legacy, Target, Backup, Temporary: string;
begin
  Result := ReadableProfileIniFile(FileName);
  if Result = FileName then Exit;

  Legacy := UpdateIOPath(Result);
  Target := UpdateIOPath(FileName);
  Backup := UpdateIOPath(FileName + '.rollback.bak');
  if not FileExists(Backup) then
  begin
    // Publish the backup only after a complete copy. If interrupted, the
    // old profile remains available. A competing startup never replaces it.
    Temporary := UpdateIOPath(ExtractFilePath(FileName) + '.homelibre-profile-' +
      TPath.GetRandomFileName + '.tmp');
    if FileExists(Temporary) then Exit;
    try
      if not Winapi.Windows.CopyFile(PChar(Legacy), PChar(Temporary), True) then
        Exit(ReadableProfileIniFile(FileName));
      if not MoveFileEx(PChar(Temporary), PChar(Backup), MOVEFILE_WRITE_THROUGH) and
        not FileExists(Backup) then Exit(ReadableProfileIniFile(FileName));
    finally
      Winapi.Windows.DeleteFile(PChar(Temporary));
    end;
  end;

  // Same-directory rename keeps the active settings available under one
  // name at all times and cannot replace an existing modern profile.
  if MoveFileEx(PChar(Legacy), PChar(Target), MOVEFILE_WRITE_THROUGH) then
    Result := FileName
  else
    Result := ReadableProfileIniFile(FileName);
end;

end.
