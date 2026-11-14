unit unit_BookCompressionImages;

interface

uses System.SysUtils, System.Classes, System.JSON;

function CompressionImageStamp(const Source: string): string;
function CaptureCompressionImageSources(const Source: string): TJSONArray;
procedure CheckCompressionImageSources(const Source: string; Data: TJSONArray; Applied: Boolean;
  VerifiedFiles:TJSONArray=nil);
function GuardCompressionImageSources(const Source: string; Data, Changed: TJSONArray): TArray<TFileStream>;

implementation

uses System.Hash, unit_FLibraryCompat, unit_MHLArchiveHelpers, unit_ZipMemberDeletion;

function CaptureCompressionImageSources(const Source: string): TJSONArray;
begin
  Result:=TJSONArray.Create;
  try
    var Paths:=FLibraryImageSourceFiles(Source);
    // Metadata commit can still hold an exclusive source handle. Discovery
    // needs paths and identities, never a second data open of that source.
    if not SameText(ExtractFileExt(Source),'.7z') and (Paths[0]='') and (Paths[1]='') then Exit;
    for var I:=0 to 1 do
    begin
      var Item:=TJSONObject.Create; Result.AddElement(Item);
      if I=0 then Item.AddPair('kind','covers') else Item.AddPair('kind','images');
      Item.AddPair('path',Paths[I]);
      var Identity:='';
      if Paths[I]<>'' then Identity:=ArchiveDeletionSourceIdentity(Paths[I]);
      Item.AddPair('source_identity',Identity);
    end;
  except Result.Free; raise; end;
end;

function CompressionImageStamp(const Source: string): string;
begin
  var Data:=CaptureCompressionImageSources(Source);
  try
    Result:='';
    if Data.Count>0 then Result:=THashSHA2.GetHashString(Data.ToJSON);
  finally Data.Free; end;
end;

procedure CheckCompressionImageSources(const Source: string; Data: TJSONArray; Applied: Boolean;
  VerifiedFiles:TJSONArray);
begin
  if Data=nil then Exit;
  if Data.Count<>2 then raise EReadError.Create('Неполная привязка внешних изображений.');
  var Paths:=FLibraryImageSourceFiles(Source);
  for var I:=0 to 1 do
  begin
    var Item:=Data.Items[I] as TJSONObject;
    var Path:=Item.GetValue<string>('path');
    if not SameFileName(Path,Paths[I]) then
      raise EReadError.Create('Изменился источник внешних изображений. Книги сохранены.');
    if Path='' then Continue;
    var Identity:=ArchiveDeletionSourceIdentity(Path);
    var Expected:=Item.GetValue<string>('source_identity');
    if ((not Applied) and (Identity<>Expected)) or
      (Copy(Identity,1,25)<>Copy(Expected,1,25)) then
      raise EReadError.Create('Архив внешних изображений заменён или изменён.');
    var Field:='source_sha256'; if Applied then Field:='result_sha256';
    var Verified:=False;
    if VerifiedFiles<>nil then
      for var FileValue in VerifiedFiles do
        if SameFileName(FileValue.GetValue<string>('source'),Path) then
        begin
          if (FileValue.GetValue<string>(Field)<>Item.GetValue<string>(Field)) or
            (Copy(FileValue.GetValue<string>('source_identity'),1,25)<>Copy(Expected,1,25)) then
            raise EReadError.Create('Подтверждение замены не соответствует внешним изображениям.');
          Verified:=True;
        end;
    if Verified then Continue;
    var Stream:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
    try
      if not SameText(THashSHA2.GetHashString(Stream),Item.GetValue<string>(Field)) then
        raise EReadError.Create('Контрольная сумма внешних изображений изменилась.');
    finally Stream.Free; end;
  end;
end;

function GuardCompressionImageSources(const Source: string; Data, Changed: TJSONArray): TArray<TFileStream>;
begin
  Result:=nil;
  if Data=nil then Exit;
  try
    for var Value in Data do
    begin
      var Path:=Value.GetValue<string>('path'); if Path='' then Continue;
      var Replaced:=False;
      if Changed<>nil then
        for var FileValue in Changed do
          if SameFileName(Path,FileValue.GetValue<string>('source')) then Replaced:=True;
      if Replaced then Continue;
      var Count:=Length(Result); SetLength(Result,Count+1);
      Result[Count]:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
    end;
    CheckCompressionImageSources(Source,Data,False);
  except
    for var Stream in Result do Stream.Free;
    Result:=nil; raise;
  end;
end;

end.
