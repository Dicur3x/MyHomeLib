unit unit_BookExportPlan;

interface

uses unit_Globals;

type
  TBookExportScriptPlan = record
    Destination, FolderTemplate, Parameters: string;
  end;

function ResolveBookExportMode(CommandTag: Integer; DefaultMode: TExportMode;
  MixedAllowed: Boolean): TExportMode;
function PrepareBookExportScript(const Path, Parameters, Destination,
  TempPath, FolderTemplate: string): TBookExportScriptPlan;

implementation

uses System.SysUtils, System.StrUtils;

function ResolveBookExportMode(CommandTag: Integer; DefaultMode: TExportMode;
  MixedAllowed: Boolean): TExportMode;
begin
  if not MixedAllowed and (CommandTag <> 850) and (CommandTag <> 854) then Exit(emFB2);
  case CommandTag of
    850: Result := emFB2;
    851: Result := emFB2Zip;
    852: Result := emLrf;
    853: Result := emTxt;
    854: Result := emEpub;
    855: Result := emPDF;
    856: Result := emMobi;
  else Result := DefaultMode;
  end;
end;

function PrepareBookExportScript(const Path, Parameters, Destination,
  TempPath, FolderTemplate: string): TBookExportScriptPlan;
const FolderToken = '%FOLDER ';
var First, Last: Integer; Folder: string;
begin
  Result.Destination := Destination;
  Result.FolderTemplate := FolderTemplate;
  Result.Parameters := Parameters;
  if Pos('%NFT%', Result.Parameters) > 0 then
  begin
    Result.FolderTemplate := '';
    Result.Parameters := StringReplace(Result.Parameters, '%NFT%', '', [rfReplaceAll]);
  end;
  Result.Parameters := StringReplace(Result.Parameters, '%TMP%', TempPath, [rfReplaceAll]);
  Result.Parameters := StringReplace(Result.Parameters, '%DEST%', Destination, [rfReplaceAll]);
  First := Pos(FolderToken, Result.Parameters);
  if First > 0 then
  begin
    Last := PosEx('%', Result.Parameters, First + Length(FolderToken));
    if Last = 0 then
      raise EArgumentException.Create('В параметре %FOLDER отсутствует закрывающий знак %.');
    Folder := Trim(Copy(Result.Parameters, First + Length(FolderToken),
      Last - First - Length(FolderToken)));
    if Folder = '' then raise EArgumentException.Create('В параметре %FOLDER не указана папка.');
    Result.Destination := Folder;
    Delete(Result.Parameters, First, Last - First + 1);
    if Pos(FolderToken, Result.Parameters) > 0 then
      raise EArgumentException.Create('Укажите только одну папку в параметре %FOLDER.');
  end;
  if (Path = '%COPY%') and (Trim(Result.Parameters) <> '') then
    Result.Destination := Trim(Result.Parameters);
end;

end.
