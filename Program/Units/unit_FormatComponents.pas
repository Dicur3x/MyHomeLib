unit unit_FormatComponents;

interface

uses System.SysUtils;

function IsFormatComponent(const ID: string): Boolean;
function FormatComponentFile(const ID: string): string;
function FormatComponentDescriptor(const ID: string): string;
function FormatComponentRequiredFiles(const ID: string): TArray<string>;
function SafeFormatComponentFile(const ID, Name: string): Boolean;
function FormatComponentVersion(const AppPath, ID: string): string;
function FindBookProcessingPython(const AppPath: string): string;
function ModularBookProcessingAvailable(const AppPath: string): Boolean;

implementation

uses System.IOUtils, System.JSON, System.Hash, System.RegularExpressions;

function IsFormatComponent(const ID: string): Boolean;
begin
  Result:=(ID='BookProcessing') or (ID='ImageProcessing') or (ID='Kindle') or
    (ID='LegacyBooks') or (ID='LegacyOffice') or (ID='XPS');
end;

function FormatComponentFile(const ID: string): string;
begin
  Result:='';
  if ID='BookProcessing' then Result:='tools/python/python.exe';
  if ID='ImageProcessing' then Result:='tools/images/HomeLibImages.exe';
  if ID='Kindle' then Result:='tools/kindle/convert_kf8.py';
  if ID='LegacyBooks' then Result:='tools/bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll';
  if ID='LegacyOffice' then Result:='tools/office/wps2html.exe';
  if ID='XPS' then Result:='tools/xps/HomeLibXps.exe';
end;

function FormatComponentDescriptor(const ID: string): string;
begin
  Result:='';
  if ID='BookProcessing' then Result:='tools/bookconvert/MODULAR_RUNTIME.json';
  if ID='ImageProcessing' then Result:='tools/images/COMPONENT.json';
  if ID='Kindle' then Result:='tools/kindle/COMPONENT.json';
  if ID='LegacyBooks' then Result:='tools/bookconvert/vendor/calibre_legacy/COMPONENT.json';
  if ID='LegacyOffice' then Result:='tools/office/COMPONENT.json';
  if ID='XPS' then Result:='tools/xps/COMPONENT.json';
end;

function FormatComponentRequiredFiles(const ID: string): TArray<string>;
begin
  Result:=nil;
  if ID='BookProcessing' then Result:=TArray<string>.Create('tools/python/python.exe',
    'tools/python/python313.dll','tools/python/python313.zip','tools/python/python313._pth',
    'tools/bookconvert/convert_book.py','tools/bookconvert/MODULAR_API.txt');
  if ID='ImageProcessing' then Result:=TArray<string>.Create('tools/images/HomeLibImages.exe',
    'tools/images/RUNTIME.json','tools/images/HomeLibImages-MIT.txt');
  if ID='Kindle' then Result:=TArray<string>.Create('tools/kindle/convert_kf8.py',
    'tools/kindle/lib/kindleunpack.py','tools/kindle/COPYING.txt','tools/bookconvert/kindle_input.py');
  if ID='LegacyBooks' then Result:=TArray<string>.Create(FormatComponentFile(ID),'tools/bookconvert/legacy_helper.py');
  if ID='LegacyOffice' then Result:=TArray<string>.Create('tools/office/wps2html.exe',
    'tools/office/wpd2html.exe','tools/office/RUNTIME.json','tools/office/NOTICE.txt');
  if ID='XPS' then Result:=TArray<string>.Create('tools/xps/HomeLibXps.exe',
    'tools/xps/RUNTIME.json','tools/xps/HomeLibXps-MIT.txt');
end;

function SafeFormatComponentFile(const ID, Name: string): Boolean;
begin
  Result:=False;
  if ID='BookProcessing' then Exit(Name.StartsWith('tools/python/') or
    (Name.StartsWith('tools/bookconvert/') and
      not Name.StartsWith('tools/bookconvert/vendor/calibre_legacy/') and
      (Name<>'tools/bookconvert/kindle_input.py') and (Name<>'tools/bookconvert/legacy_helper.py') and
      (Name<>'tools/bookconvert/COMPONENT.json')));
  if ID='ImageProcessing' then Exit((Name='tools/images/HomeLibImages.exe') or
    (Name='tools/images/RUNTIME.json') or (Name='tools/images/HomeLibImages-MIT.txt') or
    (Name=FormatComponentDescriptor(ID)));
  if ID='Kindle' then Exit((Name='tools/bookconvert/kindle_input.py') or
    (Name.StartsWith('tools/kindle/') and not Name.StartsWith('tools/kindle/python/')));
  if ID='LegacyBooks' then Exit(Name.StartsWith('tools/bookconvert/vendor/calibre_legacy/') or
    (Name='tools/bookconvert/legacy_helper.py'));
  if ID='LegacyOffice' then Exit(Name.StartsWith('tools/office/'));
  if ID='XPS' then Exit((Name='tools/xps/HomeLibXps.exe') or (Name='tools/xps/RUNTIME.json') or
    (Name='tools/xps/HomeLibXps-MIT.txt') or (Name=FormatComponentDescriptor(ID)));
end;

function FormatComponentVersion(const AppPath, ID: string): string;
var Metadata, Name, Hash, Version, Platform: string; Root, Identity: TJSONValue; Identities: TJSONObject;
begin
  Result:=''; if not IsFormatComponent(ID) then Exit;
  Root:=nil;
  try
    try
      Metadata:=TPath.Combine(AppPath,FormatComponentDescriptor(ID));
      if not FileExists(Metadata) or (TFile.GetSize(Metadata)>65536) then Exit;
      Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(Metadata,TEncoding.UTF8));
      {$IFDEF WIN64}Platform:='Win64';{$ELSE}Platform:='Win32';{$ENDIF}
      if not (Root is TJSONObject) or (Root.GetValue<Integer>('format',0)<>1) or
        (Root.GetValue<string>('component','')<>ID) or
        (Root.GetValue<string>('platform','')<>Platform) or
        not Root.TryGetValue<TJSONObject>('identities',Identities) then Exit;
      Version:=Root.GetValue<string>('version','');
      if not TRegEx.IsMatch(Version,'^[0-9]+(?:\.[0-9]+){1,3}$') then Exit;
      for Name in FormatComponentRequiredFiles(ID) do
      begin
        // File names contain periods. They are literal JSON keys, not JSON paths.
        Identity:=Identities.GetValue(Name);
        if not (Identity is TJSONString) then Exit;
        Hash:=Identity.Value;
        if not TRegEx.IsMatch(Hash,'^[0-9a-fA-F]{64}$') or
          not FileExists(TPath.Combine(AppPath,Name)) or
          not SameText(THashSHA2.GetHashStringFromFile(TPath.Combine(AppPath,Name)),Hash) then Exit;
      end;
      Result:=Version;
    except Result:=''; end;
  finally Root.Free; end;
end;

function FindBookProcessingPython(const AppPath: string): string;
begin
  Result:=TPath.Combine(AppPath,'tools/python/python.exe');
  if not FileExists(Result) then Result:=TPath.Combine(AppPath,'tools/kindle/python/python.exe');
  if not FileExists(Result) then Result:='';
end;

function ModularBookProcessingAvailable(const AppPath: string): Boolean;
var Marker: string;
begin
  Result:=False;
  try
    Marker:=TPath.Combine(AppPath,'tools/bookconvert/MODULAR_API.txt');
    Result:=(FindBookProcessingPython(AppPath)<>'') and
      FileExists(TPath.Combine(AppPath,'tools/bookconvert/convert_book.py')) and FileExists(Marker) and
      (TFile.GetSize(Marker)<=16) and (Trim(TFile.ReadAllText(Marker,TEncoding.ASCII))='1');
  except Result:=False; end;
end;

end.
