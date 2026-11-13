unit unit_ApplicationIdentity;

interface

const
  CATALOGUE_APPLICATION = 'HomeLibre.exe';
  LEGACY_CATALOGUE_APPLICATION = 'HomeLibRu.exe';
  READER_APPLICATION = 'HomeLibReader.exe';
  CATALOGUE_TRANSPORT_PATH = 'tools/updates/catalogue/HomeLibre.exe';

function ForwardApplicationCommandLine(const Executable, Original: string): string;
function InstalledApplicationName(const Directory, Requested: string): string;

implementation

uses System.SysUtils, System.IOUtils;

function ForwardApplicationCommandLine(const Executable, Original: string): string;
var I: Integer; Quoted: Boolean;
begin
  // Windows parses argv[0] as a quoted executable name, separately from the
  // remaining arguments. Preserve that entire remaining string verbatim.
  I:=1;
  while (I<=Length(Original)) and CharInSet(Original[I],[#9,' ']) do Inc(I);
  Quoted:=False;
  while I<=Length(Original) do
  begin
    if Original[I]='"' then Quoted:=not Quoted
    else if not Quoted and CharInSet(Original[I],[#9,' ']) then Break;
    Inc(I);
  end;
  Result:='"'+Executable+'"'+Copy(Original,I,MaxInt);
end;

function InstalledApplicationName(const Directory, Requested: string): string;
begin
  if SameText(Requested,CATALOGUE_APPLICATION) or SameText(Requested,LEGACY_CATALOGUE_APPLICATION) then
  begin
    if FileExists(TPath.Combine(Directory,CATALOGUE_APPLICATION)) then Exit(CATALOGUE_APPLICATION);
    // Rollback may have restored a release preceding the new executable name.
    if FileExists(TPath.Combine(Directory,LEGACY_CATALOGUE_APPLICATION)) then Exit(LEGACY_CATALOGUE_APPLICATION);
  end
  else if SameText(Requested,READER_APPLICATION) and
    FileExists(TPath.Combine(Directory,READER_APPLICATION)) then Exit(READER_APPLICATION);
  raise EFileNotFoundException.Create('Не найден файл приложения HomeLibre: '+Requested);
end;

end.
