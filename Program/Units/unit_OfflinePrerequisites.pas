unit unit_OfflinePrerequisites;

interface

type
  TOfflinePrerequisite = record
    FileName, ID, Architecture, Version, SHA256: string;
    Size: Int64;
  end;

function NativePrerequisiteArchitecture: string;
function FindOfflinePrerequisite(const AppPath, ID, Architecture: string): TOfflinePrerequisite;
procedure VerifyOfflinePrerequisite(const Item: TOfflinePrerequisite);

implementation

uses System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  System.RegularExpressions, System.Generics.Collections, Winapi.Windows,
  unit_ProgramUpdateInstaller, unit_UpdateAuthenticity;

function NativePrerequisiteArchitecture: string;
var Info: TSystemInfo;
begin
  GetNativeSystemInfo(Info);
  case Info.wProcessorArchitecture of
    PROCESSOR_ARCHITECTURE_INTEL: Result:='x86';
    PROCESSOR_ARCHITECTURE_AMD64: Result:='x64';
  else Result:='unsupported'; end;
end;

function ExpectedName(const ID, Architecture: string): string;
begin
  Result:='';
  if (ID='WebView2') and ((Architecture='x86') or (Architecture='x64')) then
    Result:='webview2-'+Architecture+'.exe'
  else if (ID='NetFramework48') and (Architecture='AnyWindows') then
    Result:='dotnet-framework-4.8.exe';
end;

function FindOfflinePrerequisite(const AppPath, ID, Architecture: string): TOfflinePrerequisite;
var Name, Key, ItemID, ItemArchitecture, Relative: string; Root: TJSONObject;
  Files: TJSONArray; Value: TJSONValue; Row: TJSONObject;
  Seen: TDictionary<string,Boolean>; Size: Int64; Found: Boolean;
begin
  Result:=Default(TOfflinePrerequisite);
  Name:=CheckedUpdateChildPath(AppPath,'tools/prerequisites/PREREQUISITES.json');
  if not FileExists(Name) then Exit;
  if TFile.GetSize(Name)>64*1024 then
    raise EReadError.Create('Повреждён список автономных компонентов Windows.');
  Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Name,TEncoding.UTF8)) as TJSONObject;
  Seen:=TDictionary<string,Boolean>.Create;
  try
    if not Assigned(Root) or (Root.GetValue<Integer>('format',0)<>1) or
      not Root.TryGetValue<TJSONArray>('files',Files) or (Files.Count<>3) then
      raise EReadError.Create('Неполный список автономных компонентов Windows.');
    Found:=False;
    for Value in Files do
    begin
      if not (Value is TJSONObject) then raise EReadError.Create('Неверное описание компонента Windows.');
      Row:=TJSONObject(Value); ItemID:=Row.GetValue<string>('id','');
      ItemArchitecture:=Row.GetValue<string>('architecture','');
      Key:=ItemID+'/'+ItemArchitecture; Relative:=ExpectedName(ItemID,ItemArchitecture);
      if (Relative='') or Seen.ContainsKey(Key) or (Row.GetValue<string>('path','')<>Relative) or
        not Row.TryGetValue<Int64>('size',Size) or (Size<32*1024*1024) or (Size>384*1024*1024) or
        not TRegEx.IsMatch(Row.GetValue<string>('sha256',''),'\A[0-9a-f]{64}\z') or
        not TRegEx.IsMatch(Row.GetValue<string>('version',''),'\A[0-9]+(\.[0-9]+){3}\z') then
        raise EReadError.Create('Повреждены сведения автономного компонента Windows.');
      Seen.Add(Key,True);
      if (ItemID=ID) and (ItemArchitecture=Architecture) then
      begin
        Found:=True; Result.ID:=ID; Result.Architecture:=Architecture;
        Result.FileName:=CheckedUpdateChildPath(AppPath,'tools/prerequisites/'+Relative);
        Result.Size:=Size; Result.Version:=Row.GetValue<string>('version');
        Result.SHA256:=Row.GetValue<string>('sha256');
      end;
    end;
    if not Found then raise EReadError.Create('В полном комплекте нет компонента для этой архитектуры Windows.');
  finally Seen.Free; Root.Free; end;
end;

procedure VerifyOfflinePrerequisite(const Item: TOfflinePrerequisite);
var Hold: TFileStream;
begin
  if (ExpectedName(Item.ID,Item.Architecture)='') or (Item.FileName='') then
    raise EReadError.Create('Не выбран автономный компонент Windows.');
  AssertUpdatePath(Item.FileName);
  Hold:=TFileStream.Create(Item.FileName,fmOpenRead or fmShareDenyWrite);
  try
    if (Hold.Size<>Item.Size) or not SameText(UpdateSHA256(Item.FileName),Item.SHA256) or
      (UpdateFileVersion(Item.FileName)<>Item.Version) then
      raise EReadError.Create('Автономный установщик Windows повреждён. Восстановите полный комплект HomeLibre.');
    VerifyMicrosoftPrerequisiteSignature(Item.FileName);
  finally Hold.Free; end;
end;

end.
