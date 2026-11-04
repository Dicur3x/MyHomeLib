unit unit_ProgramUpdatePaths;

interface

function UpdateFullPath(const Path: string): string;
function UpdateIOPath(const Path: string): string;

implementation

uses System.SysUtils, System.IOUtils, Winapi.Windows;

function UpdateFullPath(const Path: string): string;
var Input: string;
begin
  // Keep comparisons and journals in ordinary DOS/UNC notation. Only file
  // operations use the extended spelling, after Win32 normalizes the path.
  Input:=StringReplace(Path,'/',PathDelim,[rfReplaceAll]);
  if Input.StartsWith('\\?\UNC\',True) then Result:=TPath.GetFullPath('\\'+Copy(Input,9,MaxInt))
  else if Input.StartsWith('\\?\') then
  begin
    if (Length(Input)<7) or not CharInSet(Input[5],['A'..'Z','a'..'z']) or
      (Input[6]<>':') or (Input[7]<>PathDelim) then
      raise EArgumentException.Create('Недопустимый путь обновления: '+Path);
    Result:=TPath.GetFullPath(Copy(Input,5,MaxInt));
  end
  else if Input.StartsWith('\\.\') then raise EArgumentException.Create('Недопустимый путь обновления: '+Path)
  else Result:=TPath.GetFullPath(Input);
end;

function UpdateIOPath(const Path: string): string;
begin
  Result:=Path;
  // Directory creation needs room for a short name within MAX_PATH too.
  if (Length(Path)<MAX_PATH-12) and not Path.StartsWith('\\?\') then Exit;
  Result:=UpdateFullPath(Path);
  if Result.StartsWith('\\') then Result:='\\?\UNC\'+Copy(Result,3,MaxInt)
  else Result:='\\?\'+Result;
end;

end.
