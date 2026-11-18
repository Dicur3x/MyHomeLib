unit unit_CatalogComponents;

interface

uses
{$IFDEF MHL_COMPRESSION_TEST}
  frm_ProgramUpdate,
{$ENDIF}
  System.Classes;

function RequiredCatalogComponent(const AppPath, FileName: string): string;
function EnsureCatalogReaderComponent(AOwner: TComponent; const FileName: string): Boolean;

{$IFDEF MHL_COMPRESSION_TEST}
type
  TCatalogComponentTestFactory = reference to function(AOwner: TComponent): TfrmProgramUpdate;
var
  CatalogComponentDialogForTest: TCatalogComponentTestFactory;
{$ENDIF}

implementation

uses
{$IFNDEF MHL_COMPRESSION_TEST}
  frm_ProgramUpdate,
{$ENDIF}
  System.SysUtils, unit_ProgramUpdateInstaller, unit_Settings, dm_user;

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
{$IFDEF MHL_COMPRESSION_TEST}
  if Assigned(CatalogComponentDialogForTest) then Dialog:=CatalogComponentDialogForTest(AOwner)
  else
{$ENDIF}
    Dialog:=TfrmProgramUpdate.Create(AOwner);
  try
    Result:=Dialog.InstallComponentForOperation(ID,
      'Для открытия выбранного каталога нужна эта библиотека. Сам файл каталога не изменится.');
  finally Dialog.Free; end;
end;

end.
