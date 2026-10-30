unit unit_ReaderLookup;

interface

const READER_LOOKUP_MAX_LENGTH = 512;

type TReaderLookupTarget = (rltDictionary, rltGoogle, rltYandex);

function ReaderLookupText(const Value: string): string;
function ReaderLookupURL(const Value: string; Target: TReaderLookupTarget): string;
function FindReaderDictionary(const ConfiguredPath: string): string;

implementation

uses Winapi.Windows, System.SysUtils, System.Character, System.IOUtils,
  System.Win.Registry;

function ReaderLookupText(const Value: string): string;
var Ch: Char; PendingSpace: Boolean;
begin
  Result:=''; PendingSpace:=False;
  for Ch in Value do
    if TCharacter.IsWhiteSpace(Ch) then PendingSpace:=Result<>''
    else if not TCharacter.IsControl(Ch) and (Ch<>#$FFFC) then
    begin
      if PendingSpace then Result:=Result+' ';
      Result:=Result+Ch; PendingSpace:=False;
      if Length(Result)>READER_LOOKUP_MAX_LENGTH then Exit('');
    end;
end;

function ReaderLookupURL(const Value: string; Target: TReaderLookupTarget): string;
var Text, Encoded: string; B: Byte;
begin
  Result:=''; Text:=ReaderLookupText(Value); if Text='' then Exit;
  Encoded:='';
  for B in TEncoding.UTF8.GetBytes(Text) do
    if (B in [Ord('A')..Ord('Z'),Ord('a')..Ord('z'),Ord('0')..Ord('9')]) or
      (B in [Ord('-'),Ord('_'),Ord('.'),Ord('~')]) then Encoded:=Encoded+Char(B)
    else Encoded:=Encoded+'%'+IntToHex(B,2);
  // Both GoldenDict variants accept this URI as a single positional argument.
  // Encoding the path also keeps words such as --help from becoming options.
  case Target of
    rltDictionary: Result:='goldendict:///'+Encoded;
    rltGoogle: Result:='https://www.google.com/search?q='+Encoded;
    rltYandex: Result:='https://yandex.ru/search/?text='+Encoded;
  end;
end;

function FindReaderDictionary(const ConfiguredPath: string): string;
  function Existing(const Value: string): string;
  var Path: string;
  begin
    Result:=''; Path:=Value.Trim;
    if (Length(Path)>1) and (Path[1]='"') and (Path[Length(Path)]='"') then
      Path:=Copy(Path,2,Length(Path)-2);
    if (Path<>'') and SameText(ExtractFileExt(Path),'.exe') and FileExists(Path) then
      Result:=TPath.GetFullPath(Path);
  end;
var Registry: TRegistry; View: Cardinal; Root: HKEY; App, Folder: string;
begin
  Result:=Existing(ConfiguredPath); if Result<>'' then Exit;
  for Root in [HKEY_CURRENT_USER,HKEY_LOCAL_MACHINE] do
    for View in [KEY_WOW64_64KEY,KEY_WOW64_32KEY] do
      for App in ['goldendict.exe','goldendict-ng.exe'] do
      begin
        Registry:=TRegistry.Create(KEY_READ or View);
        try
          Registry.RootKey:=Root;
          try
            if Registry.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\App Paths\'+App) then
              Result:=Existing(Registry.ReadString(''));
          except on E: ERegistryException do Result:=''; end;
        finally Registry.Free; end;
        if Result<>'' then Exit;
      end;
  for Folder in [GetEnvironmentVariable('ProgramFiles'),GetEnvironmentVariable('ProgramFiles(x86)'),
    TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'),'Programs')] do
    if Folder<>'' then
      for App in ['GoldenDict\goldendict.exe','GoldenDict-ng\goldendict.exe','GoldenDict-ng\goldendict-ng.exe'] do
      begin Result:=Existing(TPath.Combine(Folder,App)); if Result<>'' then Exit; end;
end;

end.
