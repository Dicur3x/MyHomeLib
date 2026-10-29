(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors             Oleksiy Penkov   oleksiy.penkov@gmail.com
  *                     Nick Rymanov     nrymanov@gmail.com
  * Created
  * Description
  *
  * $Id: dm_user.pas 845 2010-10-06 11:03:28Z nrymanov@gmail.com $
  *
  * History
  *
  ****************************************************************************** *)

unit dm_user;

interface

uses
  ImgList,
  Classes,
  Controls,
  unit_Settings,
  unit_Interfaces, System.ImageList;

type
  TDMUser = class(TDataModule)
    SeverityImages: TImageList;
    SeverityImagesBig: TImageList;

  private
    FSettings: TMHLSettings;
    FSystemDB: ISystemData;

    function InternalGetSystemDB(const FileName: string): ISystemData; inline;

  public const
    iiInfo = 0;
    iiWarning = 1;
    iiError = 2;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Init;

    function GetSystemDBConnection: ISystemData;

    property Settings: TMHLSettings read FSettings;
    property SystemDB: ISystemData read FSystemDB;
  end;

var
  DMUser: TDMUser;

function Settings: TMHLSettings; inline;
function SystemDB: ISystemData; inline;

implementation

{$R *.dfm}

uses
  SysUtils,
  IOUtils,
  unit_SystemDatabase_SQLite, unit_Diagnostics, unit_ComponentUpdates;

function Settings: TMHLSettings; inline;
begin
  Assert(Assigned(DMUser));
  Assert(Assigned(DMUser.FSettings));
  Result := DMUser.Settings;
end;

function SystemDB: ISystemData; inline;
begin
  Assert(Assigned(DMUser));
  Assert(Assigned(DMUser.SystemDB));
  Result := DMUser.SystemDB;
end;


constructor TDMUser.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FSettings := TMHLSettings.Create;
end;

destructor TDMUser.Destroy;
begin
  if Assigned(FSystemDB) then
  begin
    FSystemDB.ClearCollectionCache;
    FSystemDB := nil;
  end;
  FreeAndNil(FSettings);
  inherited Destroy;
end;

function TDMUser.InternalGetSystemDB(const FileName: string): ISystemData;
begin
  Result := TSystemData_SQLite.Create(FileName);
end;

procedure TDMUser.Init;
var
  SysDBFileName: string;
  ComponentRoot: string;
begin
  FSettings.LoadSettings;
  ComponentRoot:=FSettings.AppPath;
  ConfigureDiagnosticSettings(FSettings.SettingsFileName,
    function: string
    var Lines: TStringList; Version: string;
    begin
      Lines:=TStringList.Create;
      try
        for var Component in UPDATE_COMPONENTS do
        begin
          try
            Version:=ComponentInstalledVersion(ComponentRoot,Component.ID);
            if Version='' then Version:='не установлен';
          except Version:='версию не удалось определить'; end;
          Lines.Add(Component.ID+': '+Version);
        end;
        Result:=Lines.Text;
      finally Lines.Free; end;
    end);
  TDirectory.CreateDirectory(FSettings.TempDir);
  TDirectory.CreateDirectory(FSettings.DataDir);

  SysDBFileName := FSettings.SystemFileName[sfSystemDB];
  if not FileExists(SysDBFileName) then
    TSystemData_SQLite.CreateSystemTables(SysDBFileName);

  FSystemDB := InternalGetSystemDB(SysDBFileName);
end;

function TDMUser.GetSystemDBConnection: ISystemData;
begin
  Result := InternalGetSystemDB(FSettings.SystemFileName[sfSystemDB]);
end;

end.
