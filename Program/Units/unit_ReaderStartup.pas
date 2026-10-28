unit unit_ReaderStartup;

interface

uses System.SysUtils;

type
  TReaderStartup = record
    Profile, Source, SessionFile: string;
    Portable, ExplicitProfile: Boolean;
  end;

// Resolve before DMUser creates settings, cache or personal data. Explicit
// catalogue/restart profiles take priority over the standalone portable flag.
function ResolveReaderStartup(const Executable: string;
  const Arguments: TArray<string>): TReaderStartup;

implementation

uses System.IOUtils;

function ResolveReaderStartup(const Executable: string;
  const Arguments: TArray<string>): TReaderStartup;
var Directory, Argument, SelectedProfile: string;
begin
  Result:=Default(TReaderStartup);
  Directory:=ExcludeTrailingPathDelimiter(ExtractFilePath(TPath.GetFullPath(Executable)));
  SelectedProfile:=Directory;
  for Argument in Arguments do
    if Argument.StartsWith('--profile=',True) then
    begin
      SelectedProfile:=Argument.Substring(10); Result.ExplicitProfile:=True;
      if Trim(SelectedProfile)='' then raise EArgumentException.Create('Не задана папка данных читалки.');
    end
    else if SameText(Argument,'uselocaldata') or SameText(Argument,'--portable') then Continue
    else if Argument.StartsWith('--open=',True) then Result.Source:=Argument.Substring(7)
    else if Argument.StartsWith('--session=',True) then Result.SessionFile:=Argument.Substring(10)
    else if not Argument.StartsWith('--') and (Result.Source='') then Result.Source:=Argument;
  Result.Profile:=ExcludeTrailingPathDelimiter(TPath.GetFullPath(SelectedProfile));
  Result.Portable:=SameFileName(Result.Profile,Directory);
end;

end.
