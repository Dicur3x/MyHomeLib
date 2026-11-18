unit unit_BookCompressionImages;

interface

uses System.SysUtils, System.Classes, System.JSON;

function CompressionImageStamp(const Source: string; KnownSevenZip:Boolean=False): string;
function CompressionImageSnapshot(const Source: string; Data:TJSONArray): string;
function CompressionImageSnapshotMatches(const Source, Snapshot:string; Hashes:Boolean): Boolean;
function CaptureCompressionImageSources(const Source: string; KnownSevenZip:Boolean=False): TJSONArray;
procedure CheckCompressionImageSources(const Source: string; Data: TJSONArray; Applied: Boolean;
  VerifiedFiles:TJSONArray=nil);
function GuardCompressionImageSources(const Source: string; Data, Changed: TJSONArray): TArray<TFileStream>;
function GuardCompressionPeerSources(const Source:string; Peers:TJSONArray;
  const Cancelled:TFunc<Boolean>):TArray<TFileStream>;

implementation

uses System.Hash, unit_FLibraryCompat, unit_MHLArchiveHelpers, unit_ZipMemberDeletion;

function CaptureCompressionImageSources(const Source: string; KnownSevenZip:Boolean): TJSONArray;
begin
  Result:=TJSONArray.Create;
  try
    // The metadata owner already bound this container before taking its
    // exclusive replacement handle. Other readers inspect actual magic.
    if not KnownSevenZip and not IsSevenZipArchive(Source) then Exit;
    var Paths:=FLibraryImageSourceFiles(Source);
    for var I:=0 to 1 do
    begin
      if Paths[I]<>'' then Paths[I]:=ExpandFileName(Paths[I]);
      var Item:=TJSONObject.Create; Result.AddElement(Item);
      if I=0 then Item.AddPair('kind','covers') else Item.AddPair('kind','images');
      Item.AddPair('path',Paths[I]);
      var Identity:='';
      if Paths[I]<>'' then Identity:=ArchiveDeletionSourceIdentity(Paths[I]);
      Item.AddPair('source_identity',Identity);
    end;
  except Result.Free; raise; end;
end;

function CompressionImageStamp(const Source: string; KnownSevenZip:Boolean): string;
begin
  var Data:=CaptureCompressionImageSources(Source,KnownSevenZip);
  try
    Result:='';
    if Data.Count>0 then Result:=THashSHA2.GetHashString(Data.ToJSON);
  finally Data.Free; end;
end;

function CompressionImageSnapshot(const Source: string; Data:TJSONArray): string;
begin
  Result:='';
  var Current:=CaptureCompressionImageSources(Source,True);
  try
    if Current.Count=0 then Exit;
    if (Data<>nil) and (Data.Count<>Current.Count) then
      raise EReadError.Create('Изменился набор источников изображений.');
    for var I:=0 to Current.Count-1 do
    begin
      var Item:=Current.Items[I] as TJSONObject;
      if Item.GetValue<string>('path')='' then Continue;
      if Data=nil then Exit; // Legacy receipts cannot invent image checksums.
      var Original:=Data.Items[I] as TJSONObject;
      if not SameFileName(Item.GetValue<string>('path'),Original.GetValue<string>('path')) then
        raise EReadError.Create('Изменился путь внешних изображений.');
      var Hash:=Original.GetValue<string>('result_sha256');
      Item.AddPair('source_sha256',Hash); Item.AddPair('result_sha256',Hash);
    end;
    Result:=Current.ToJSON;
  finally Current.Free; end;
end;

function CompressionImageSnapshotMatches(const Source, Snapshot:string; Hashes:Boolean): Boolean;
var Stored:TJSONArray;
begin
  Result:=False; Stored:=nil;
  if Snapshot='' then Exit;
  try
    try
      Stored:=TJSONObject.ParseJSONValue(Snapshot) as TJSONArray;
      if Stored=nil then Exit;
      var Current:=CaptureCompressionImageSources(Source);
      try
        if Current.Count<>Stored.Count then Exit;
        for var I:=0 to Current.Count-1 do
          for var Name in ['kind','path','source_identity'] do
            if Current.Items[I].GetValue<string>(Name)<>Stored.Items[I].GetValue<string>(Name) then Exit;
      finally Current.Free; end;
      if Hashes then CheckCompressionImageSources(Source,Stored,False);
      Result:=True;
    except
      on E:EOSError do Result:=False;
      on E:EStreamError do Result:=False;
      on E:EJSONException do Result:=False;
      on E:EInvalidCast do Result:=False;
    end;
  finally Stored.Free; end;
end;

procedure CheckCompressionImageSources(const Source: string; Data: TJSONArray; Applied: Boolean;
  VerifiedFiles:TJSONArray);
begin
  if Data=nil then Exit;
  if Data.Count<>2 then raise EReadError.Create('Неполная привязка внешних изображений.');
  var Paths:=FLibraryImageSourceFiles(Source);
  for var I:=0 to 1 do if Paths[I]<>'' then Paths[I]:=ExpandFileName(Paths[I]);
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

function GuardCompressionPeerSources(const Source:string; Peers:TJSONArray;
  const Cancelled:TFunc<Boolean>):TArray<TFileStream>;
var Buffer:TBytes;
begin
  Result:=nil;
  if Peers=nil then Exit;
  try
    for var Extension in ['.zip','.7z'] do
    begin
      var Path:=ChangeFileExt(Source,Extension);
      if SameFileName(Path,Source) or not FileExists(DeletionNativePath(Path)) then Continue;
      if not IsSevenZipArchive(DeletionNativePath(Path)) then Continue;
      var Index:=Length(Result);
      if (Index>=Peers.Count) or not SameFileName(Peers.Items[Index].GetValue<string>('path'),Path) then
        raise EReadError.Create('Изменился набор архивов книг, использующих общие иллюстрации.');
      SetLength(Result,Index+1);
      Result[Index]:=TFileStream.Create(DeletionNativePath(Path),fmOpenRead or fmShareDenyWrite);
      if Length(Buffer)=0 then SetLength(Buffer,1024*1024);
      var Hash:=THashSHA2.Create;
      repeat
        if Assigned(Cancelled) and Cancelled() then Abort;
        var Count:=Result[Index].Read(Buffer[0],Length(Buffer));
        if Count=0 then Break;
        Hash.Update(Buffer,Count);
      until False;
      if not SameText(Hash.HashAsString,Peers.Items[Index].GetValue<string>('sha256')) then
        raise EReadError.Create('Соседний архив книг изменился после проверки общих иллюстраций.');
    end;
    if Length(Result)<>Peers.Count then
      raise EReadError.Create('Соседний архив книг недоступен. Общие иллюстрации сохранены.');
  except
    for var Stream in Result do Stream.Free;
    Result:=nil; raise;
  end;
end;

end.
