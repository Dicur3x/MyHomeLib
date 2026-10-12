unit unit_ReaderFonts;

interface

uses System.Classes;

procedure PrepareReaderFonts;
procedure ReaderFontChoices(Names, Labels: TStrings; const Current: string);
function AvailableReaderFont(const Name: string): string;
function EnsureReaderFont(const Name: string): Boolean;

implementation

uses Winapi.Windows, System.SysUtils, Vcl.Forms;

var LoadedFonts, LoadedFamilies: TStringList;
  Prepared: Boolean;

function EnsureReaderFont(const Name: string): Boolean;
const Styles: array[0..3] of string = ('Regular','Bold','Italic','BoldItalic');
var Prefix, Extension, FileName, Style: string;
begin
  if LoadedFamilies.IndexOf(Name)>=0 then Exit(Screen.Fonts.IndexOf(Name)>=0);
  LoadedFamilies.Add(Name);
  Prefix:=ExtractFilePath(ParamStr(0))+'tools\fonts\'; Extension:='.ttf';
  if Name='PT Serif' then Prefix:=Prefix+'ptserif\PT_Serif-Web-'
  else if Name='PT Sans' then Prefix:=Prefix+'ptsans\PT_Sans-Web-'
  else if Name.StartsWith('Noto Serif CJK') or Name.StartsWith('Noto Sans CJK') then
  begin
    if Name.StartsWith('Noto Serif') then Prefix:=Prefix+'noto-cjk\NotoSerifCJK-'
    else Prefix:=Prefix+'noto-cjk\NotoSansCJK-';
    Extension:='.ttc';
  end
  else Prefix:=Prefix+'noto\'+Name.Replace(' ','')+'-';
  for Style in Styles do
  begin
    FileName:=Prefix+Style+Extension;
    // Private resources require neither installation nor Windows settings.
    if (LoadedFonts.IndexOf(FileName)<0) and FileExists(FileName) and
      (AddFontResourceEx(PChar(FileName),FR_PRIVATE,nil)>0) then LoadedFonts.Add(FileName);
  end;
  Screen.ResetFonts;
  Result:=Screen.Fonts.IndexOf(Name)>=0;
end;

procedure PrepareReaderFonts;
begin
  if Prepared then Exit;
  Prepared:=True; LoadedFonts:=TStringList.Create; LoadedFamilies:=TStringList.Create;
  EnsureReaderFont('PT Serif'); EnsureReaderFont('PT Sans');
  EnsureReaderFont('Noto Serif'); EnsureReaderFont('Noto Sans');
  // Register other writing systems only when a book needs them.
end;

function AvailableReaderFont(const Name: string): string;
begin
  PrepareReaderFonts;
  if (Name<>'') and (Screen.Fonts.IndexOf(Name)>=0) then Exit(Name);
  if Screen.Fonts.IndexOf('PT Serif')>=0 then Exit('PT Serif');
  Result:='Georgia';
end;

procedure ReaderFontChoices(Names, Labels: TStrings; const Current: string);
  procedure Add(const Name, Description: string);
  begin
    if Screen.Fonts.IndexOf(Name)<0 then Exit;
    Names.Add(Name); Labels.Add(Name+' — '+Description);
  end;
begin
  PrepareReaderFonts; Names.Clear; Labels.Clear;
  Add('PT Serif','с засечками'); Add('Noto Serif','с засечками');
  Add('PT Sans','без засечек'); Add('Noto Sans','без засечек');
  // Retain a previously selected custom font without filling the menu with
  // every font installed on the computer.
  if (Current<>'') and (Names.IndexOf(Current)<0) and (Screen.Fonts.IndexOf(Current)>=0) then
  begin Names.Add(Current); Labels.Add(Current+' — текущий'); end;
end;

procedure ReleaseReaderFonts;
var FileName: string;
begin
  if not Assigned(LoadedFonts) then Exit;
  for FileName in LoadedFonts do RemoveFontResourceEx(PChar(FileName),FR_PRIVATE,nil);
  FreeAndNil(LoadedFamilies); FreeAndNil(LoadedFonts);
end;

initialization
  Prepared:=False;

finalization
  ReleaseReaderFonts;

end.
