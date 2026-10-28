unit unit_CatalogComponents;

interface

uses System.Classes;

function RequiredCatalogComponent(const AppPath, FileName: string): string;
function EnsureCatalogReaderComponent(AOwner: TComponent; const FileName: string): Boolean;

implementation

uses System.SysUtils, unit_ProgramUpdateInstaller, frm_ProgramUpdate, unit_Settings, dm_user;

function RequiredCatalogComponent(const AppPath, FileName: string): string;
begin
  Result:='';
  if SameText(ExtractFileExt(FileName),'.zst') and ComponentNeedsRepair(AppPath,'Zstandard') then
    Result:='Zstandard';
end;

function EnsureCatalogReaderComponent(AOwner: TComponent; const FileName: string): Boolean;
var ID: string; Dialog: TfrmProgramUpdate;
begin
  Result:=True;
  if not FileExists(FileName) then Exit;
  ID:=RequiredCatalogComponent(Settings.AppPath,FileName);
  if ID='' then Exit;
  Dialog:=TfrmProgramUpdate.Create(AOwner);
  try
    Result:=Dialog.InstallComponentForOperation(ID,
      'Для открытия выбранного каталога нужна эта библиотека. Сам файл каталога не изменится.');
  finally Dialog.Free; end;
end;

end.
