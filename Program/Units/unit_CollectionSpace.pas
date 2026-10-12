unit unit_CollectionSpace;

interface

uses System.SysUtils;

type
  TCollectionSpaceEstimate = record
    Known: Boolean;
    LowBytes, HighBytes: Int64;
  end;

function EstimateCatalogBytes(const FileName: string): TCollectionSpaceEstimate;
function EstimateMetadataBytes(Bytes: Int64; IsDatabase, IsJSON: Boolean): TCollectionSpaceEstimate;
function CollectionDiskFree(const Destination: string): Int64;
function CollectionSpaceText(const Estimate: TCollectionSpaceEstimate; TemporaryBytes, FreeBytes: Int64): string;

implementation

uses System.IOUtils, System.Zip, Winapi.Windows, System.Math;

function EstimateMetadataBytes(Bytes: Int64; IsDatabase, IsJSON: Boolean): TCollectionSpaceEstimate;
const MB = Int64(1024)*1024;
begin
  Result:=Default(TCollectionSpaceEstimate);
  if (Bytes<0) or (Bytes>High(Int64) div 8) then Exit;
  Result.Known:=True;
  if IsDatabase then
  begin Result.LowBytes:=Max(MB,Bytes div 2); Result.HighBytes:=Max(MB,Bytes+Bytes div 2); end
  else if IsJSON then
  begin Result.LowBytes:=Max(MB,Bytes div 2); Result.HighBytes:=Max(MB,Bytes*2); end
  else
  begin Result.LowBytes:=Max(MB,Bytes*2); Result.HighBytes:=Max(MB,Bytes*6); end;
end;

function EstimateCatalogBytes(const FileName: string): TCollectionSpaceEstimate;
var Zip: TZipFile; I: Integer; Bytes, Size: Int64; E: string; Found, JSON: Boolean;
begin
  Result:=Default(TCollectionSpaceEstimate);
  if not FileExists(FileName) then Exit;
  try
    E:=LowerCase(ExtractFileExt(FileName));
    if (E='.inpx') or (E='.zip') then
    begin
      Zip:=TZipFile.Create;
      try
        Zip.Open(FileName,zmRead); Bytes:=0; Found:=False; JSON:=False;
        // Read central-directory sizes only; do not extract or scan book records.
        if Zip.FileCount>100000 then Exit;
        for I:=0 to Zip.FileCount-1 do
          if SameText(ExtractFileExt(Zip.FileNames[I]),'.inp') or
            SameText(ExtractFileExt(Zip.FileNames[I]),'.jsonl') then
          begin
            Size:=Zip.FileInfo[I].UncompressedSize;
            if Size=$FFFFFFFF then Exit; // Unknown ZIP64 size needs full indexing first.
            Inc(Bytes,Size); Found:=True;
            JSON:=JSON or SameText(ExtractFileExt(Zip.FileNames[I]),'.jsonl');
          end;
        if Found then Result:=EstimateMetadataBytes(Bytes,False,JSON);
      finally Zip.Free; end;
    end
    else if (E='.hlc2') or (E='.dbs2') then Result:=EstimateMetadataBytes(TFile.GetSize(FileName),True,False)
    else if E='.jsonl' then Result:=EstimateMetadataBytes(TFile.GetSize(FileName),False,True);
    // Compressed JSON and arbitrary book directories remain explicitly unknown.
  except
    on Error: Exception do Result:=Default(TCollectionSpaceEstimate);
  end;
end;

function CollectionDiskFree(const Destination: string): Int64;
var Folder, Parent: string; Available, Total, Free: UInt64;
begin
  Result:=-1;
  try
    Folder:=TPath.GetFullPath(Destination);
    if not DirectoryExists(Folder) then Folder:=ExtractFileDir(Folder);
    while not DirectoryExists(Folder) do
    begin Parent:=ExtractFileDir(Folder); if Parent=Folder then Exit; Folder:=Parent; end;
    // Resolve the actual volume of a junction as Windows does for writes.
    if GetDiskFreeSpaceEx(PChar(IncludeTrailingPathDelimiter(Folder)),Available,Total,@Free) then
      Result:=Int64(Min(Available,UInt64(High(Int64))));
  except on Error: Exception do Result:=-1; end;
end;

function SizeText(Bytes: Int64): string;
begin
  if Bytes>=Int64(1024)*1024*1024 then Result:=FormatFloat('0.0',Bytes/(1024.0*1024*1024))+' ГБ'
  else Result:=FormatFloat('0',Bytes/(1024.0*1024))+' МБ';
end;

function CollectionSpaceText(const Estimate: TCollectionSpaceEstimate; TemporaryBytes, FreeBytes: Int64): string;
begin
  if Estimate.Known then Result:='Дополнительно для данных: примерно '+SizeText(Estimate.LowBytes)+'–'+SizeText(Estimate.HighBytes)+'.'
  else Result:='Размер данных станет известен после подготовки каталога.';
  if TemporaryBytes>0 then Result:=Result+' Запас на обработку и резервную копию: '+SizeText(TemporaryBytes)+'.';
  if FreeBytes>=0 then Result:=Result+' Свободно: '+SizeText(FreeBytes)+'.';
  if Estimate.Known and (FreeBytes>=0) and ((Estimate.HighBytes>FreeBytes) or (TemporaryBytes>FreeBytes-Estimate.HighBytes)) then
    Result:=Result+' Места может не хватить — выберите другую папку.';
end;

end.
