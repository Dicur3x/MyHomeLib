unit unit_BookDeletionInventory;

interface

uses System.SysUtils;

function ReadBookDeletionInventory(const Archive, ExpectedSourceIdentity: string;
  const Cancel: TFunc<Boolean> = nil): TArray<string>;

implementation

uses System.Classes, System.Zip, unit_ZipMemberDeletion, unit_SevenZipDeletionPlan;

function ReadBookDeletionInventory(const Archive,ExpectedSourceIdentity:string;
  const Cancel:TFunc<Boolean>):TArray<string>;
var Source:TFileStream; Zip:TZipFile; Signature:array[0..5] of Byte;
  Characters:Int64;
  procedure Check;
  begin
    if Assigned(Cancel) and Cancel() then Abort;
    if (ExpectedSourceIdentity='') or
      (ArchiveDeletionSourceIdentity(Archive)<>ExpectedSourceIdentity) then
      raise EReadError.Create('Архив изменился после выбора книг. Удаление не начато.');
  end;
begin
  Result:=nil; Check;
  // No unpacking and no write access. Keep the inventory stable while the
  // decoder reads metadata, then check the captured source once more.
  Source:=TFileStream.Create(DeletionNativePath(Archive),fmOpenRead or fmShareDenyWrite);
  try
    Check;
    if Source.Size<SizeOf(Signature) then raise EReadError.Create('Архив слишком короткий.');
    Source.ReadBuffer(Signature,SizeOf(Signature)); Source.Position:=0;
    if (Signature[0]=$37) and (Signature[1]=$7A) and (Signature[2]=$BC) and
      (Signature[3]=$AF) and (Signature[4]=$27) and (Signature[5]=$1C) then
      Result:=ReadSevenZipInventory(Source,Cancel)
    else
    begin
      Zip:=TZipFile.Create;
      try Zip.Open(Source,zmRead); Result:=Copy(Zip.FileNames);
      finally Zip.Free; end;
    end;
    if (Length(Result)=0) or (Length(Result)>200000) then
      raise EReadError.Create('Неверный размер списка файлов архива.');
    Characters:=0;
    for var Name in Result do
    begin
      Inc(Characters,Length(Name));
      if (Name='') or (Characters>8*1024*1024) then
        raise EReadError.Create('Слишком большой список имён внутри архива.');
    end;
    Check;
  finally Source.Free; end;
end;

end.
