unit unit_ZstdRuntime;

interface

function ZstdRuntimeVersion(const AppPath: string): string;

implementation

uses System.SysUtils, System.IOUtils, System.JSON, System.Hash, System.RegularExpressions;

function ZstdRuntimeVersion(const AppPath: string): string;
var FileName, MetadataName, Hash, Version, Platform: string; Root: TJSONValue;
begin
  Result:=''; Root:=nil;
  FileName:=TPath.Combine(AppPath,'libzstd.dll');
  MetadataName:=TPath.Combine(AppPath,'tools/zstd/RUNTIME.json');
  try
    try
      if not FileExists(FileName) then Exit;
      Hash:=THashSHA2.GetHashStringFromFile(FileName);
      {$IFDEF WIN64}Platform:='Win64';{$ELSE}Platform:='Win32';{$ENDIF}
      if FileExists(MetadataName) then
      begin
        if TFile.GetSize(MetadataName)>65536 then Exit;
        Root:=TJSONObject.ParseJSONValue(TFile.ReadAllText(MetadataName,TEncoding.UTF8));
        if not (Root is TJSONObject) or (Root.GetValue<Integer>('format',0)<>1) or
          (Root.GetValue<string>('platform','')<>Platform) or
          not SameText(Root.GetValue<string>('dll_sha256',''),Hash) then Exit;
        Version:=Root.GetValue<string>('version','');
        if TRegEx.IsMatch(Version,'^[0-9]+(?:\.[0-9]+){1,3}$') then Result:=Version;
      end
      // Existing distributions supplied these exact official binaries without
      // a descriptor. Inspect bytes only; update discovery must never load DLLs.
      {$IFDEF WIN64}
      else if SameText(Hash,'8f07e1112ed283e5cd2798833e9a3c32d8961381bc36da04af57a1b0ca9bd40b') then Result:='1.5.7';
      {$ELSE}
      else if SameText(Hash,'85853869cb2567890bf67be6eee8467676b636dd8dfc0f5c050cf984d4bae420') then Result:='1.5.7';
      {$ENDIF}
    except Result:=''; end;
  finally Root.Free; end;
end;

end.
