unit NativeRegressionGuard;

interface

procedure RequireIsolatedRegression;

implementation

uses System.SysUtils, System.IOUtils;

procedure RequireIsolatedRegression;
const
  MARKER = 'HomeLib Ru isolated native regression v1';
var
  Folder: string;
begin
  Folder := ExtractFilePath(ParamStr(0));
  if not ExtractFileName(ExcludeTrailingPathDelimiter(Folder)).StartsWith('HomeLibRu-native-') or
    not FileExists(Folder + 'uselocaldata') or
    not FileExists(Folder + 'uselocaltemp') or
    not FileExists(Folder + 'native-regression.marker') then
    raise Exception.Create('Run only via tools/ui/tests/native_collection_tests.js in its isolated temporary runtime.');
  if TFile.ReadAllText(Folder + 'native-regression.marker', TEncoding.UTF8) <> MARKER then
    raise Exception.Create('Native regression marker is invalid.');
end;

end.
