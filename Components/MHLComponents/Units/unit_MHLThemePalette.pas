unit unit_MHLThemePalette;

interface

uses Vcl.Graphics, System.IniFiles;

type
  TMHLPaletteRole = (prWindow, prField, prText, prLink, prSelection, prSelectionText);
  TMHLThemePalette = record
    Colors: array[TMHLPaletteRole] of TColor;
  end;
  TMHLThemePalettes = array[Boolean] of TMHLThemePalette;

function DefaultMHLThemePalette(Dark: Boolean): TMHLThemePalette;
function EmptyMHLThemePalette: TMHLThemePalette;
function ResolveMHLThemePalette(const Palette: TMHLThemePalette; Dark: Boolean): TMHLThemePalette;
function MHLThemePalettes: TMHLThemePalettes;
procedure SetMHLThemePalettes(const Value: TMHLThemePalettes);
function MHLPaletteCustomized(Dark: Boolean): Boolean;
function MHLPaletteColor(Dark: Boolean; Role: TMHLPaletteRole): TColor;
procedure LoadMHLThemePalettes(Ini: TCustomIniFile);
procedure SaveMHLThemePalettes(Ini: TCustomIniFile);

implementation

uses Winapi.Windows, System.SysUtils;

const
  Sections: array[Boolean] of string = ('InterfaceColors.Light', 'InterfaceColors.Dark');
  Keys: array[TMHLPaletteRole] of string =
    ('Window', 'Field', 'Text', 'Link', 'Selection', 'SelectionText');
var
  Palettes: TMHLThemePalettes;

function DefaultMHLThemePalette(Dark: Boolean): TMHLThemePalette;
begin
  if Dark then
  begin
    Result.Colors[prWindow]:=RGB(43,45,48);
    Result.Colors[prField]:=RGB(30,31,34);
    Result.Colors[prText]:=RGB(205,208,214);
    Result.Colors[prLink]:=RGB(114,167,232);
    Result.Colors[prSelection]:=RGB(33,66,131);
    Result.Colors[prSelectionText]:=RGB(221,225,234);
  end
  else
  begin
    Result.Colors[prWindow]:=clBtnFace;
    Result.Colors[prField]:=clWindow;
    Result.Colors[prText]:=clWindowText;
    Result.Colors[prLink]:=clHotLight;
    Result.Colors[prSelection]:=clHighlight;
    Result.Colors[prSelectionText]:=clHighlightText;
  end;
end;

function EmptyMHLThemePalette: TMHLThemePalette;
begin
  for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
    Result.Colors[Role]:=clDefault;
end;

function ResolveMHLThemePalette(const Palette: TMHLThemePalette; Dark: Boolean): TMHLThemePalette;
begin
  Result:=DefaultMHLThemePalette(Dark);
  for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
    if Palette.Colors[Role]<>clDefault then Result.Colors[Role]:=Palette.Colors[Role];
end;

function MHLThemePalettes: TMHLThemePalettes;
begin Result:=Palettes; end;

procedure SetMHLThemePalettes(const Value: TMHLThemePalettes);
begin Palettes:=Value; end;

function MHLPaletteCustomized(Dark: Boolean): Boolean;
begin
  for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
    if Palettes[Dark].Colors[Role]<>clDefault then Exit(True);
  Result:=False;
end;

function MHLPaletteColor(Dark: Boolean; Role: TMHLPaletteRole): TColor;
var Resolved: TMHLThemePalette;
begin
  Resolved:=ResolveMHLThemePalette(Palettes[Dark],Dark);
  Result:=Resolved.Colors[Role];
end;

procedure LoadMHLThemePalettes(Ini: TCustomIniFile);
var Value: Integer;
begin
  for var Dark:=False to True do
    for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
    begin
      // Only RGB overrides are persisted. Invalid/old entries keep native defaults.
      if TryStrToInt(Ini.ReadString(Sections[Dark],Keys[Role],''),Value) and
        (Value>=0) and (Value<=$FFFFFF) then Palettes[Dark].Colors[Role]:=Value
      else Palettes[Dark].Colors[Role]:=clDefault;
    end;
end;

procedure SaveMHLThemePalettes(Ini: TCustomIniFile);
begin
  for var Dark:=False to True do
    for var Role:=Low(TMHLPaletteRole) to High(TMHLPaletteRole) do
      if Palettes[Dark].Colors[Role]=clDefault then Ini.DeleteKey(Sections[Dark],Keys[Role])
      else Ini.WriteInteger(Sections[Dark],Keys[Role],ColorToRGB(Palettes[Dark].Colors[Role]));
end;

initialization
  Palettes[False]:=EmptyMHLThemePalette;
  Palettes[True]:=EmptyMHLThemePalette;
end.
