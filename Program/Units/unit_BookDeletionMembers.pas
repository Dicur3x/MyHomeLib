unit unit_BookDeletionMembers;

interface

uses System.SysUtils, unit_Globals;

function IsWholeBookArchive(const Book: TBookRecord): Boolean;

// Resolves only a proved full internal path. Unlike read-time compatibility
// fallback this must never choose a basename, wildcard or legacy ordinal.
// FBD containers require exactly one matching descriptor/payload pair.
function ExactBookDeletionMembers(const Book: TBookRecord;
  const Inventory: TArray<string>): TArray<string>;

implementation

uses System.Classes, System.IOUtils, System.Generics.Collections, unit_MHLArchiveHelpers;

function IsWholeBookArchive(const Book: TBookRecord): Boolean;
begin
  Result := IsArchiveExt(Book.FileExt) and
    (Book.GetBookFormat(TPath.Combine(Book.CollectionRoot, Book.Folder)) = bfRaw);
end;

function ExactBookDeletionMembers(const Book:TBookRecord;
  const Inventory:TArray<string>):TArray<string>;
var Names:TDictionary<string,string>; Format:TBookFormat; Member:string;
  Descriptor,Payload:string; PairCount:Integer;
  function Exact(const Name:string):string;
  begin
    if not Names.TryGetValue(Name.Replace('\','/'),Result) then
      raise EReadError.Create('В архиве не найден точный путь книги: '+Name);
    if Result.EndsWith('/') or Result.EndsWith('\') then
      raise EReadError.Create('Вместо файла книги выбрана папка архива.');
  end;
begin
  Result:=nil;
  Format:=Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder));
  if not (Format in [bfFb2Archive,bfRawArchive,bfFbd]) then
    raise EArgumentException.Create('Эта книга не является файлом внутри общего архива.');
  if (Length(Inventory)=0) or (Length(Inventory)>200000) then
    raise EReadError.Create('Неверный список файлов внутри архива.');
  Names:=TDictionary<string,string>.Create;
  try
    for var Name in Inventory do
    begin
      var Key:=Name.Replace('\','/');
      if (Key='') or Names.ContainsKey(Key) then
        raise EReadError.Create('В архиве есть неоднозначные имена файлов. Удаление не начато.');
      Names.Add(Key,Name);
    end;
    if Format<>bfFbd then
    begin
      Member:=Book.FileName;
      if Member='' then
        raise EReadError.Create('Для удаления недостаточно номера файла внутри архива. Нужен его точный путь.');
      if not SameText(ExtractFileExt(Member),Book.FileExt) then Member:=Member+Book.FileExt;
      Exit(TArray<string>.Create(Exact(Member)));
    end;
    if (Book.FileExt='') or SameText(Book.FileExt,'.fbd') then
      raise EReadError.Create('В каталоге не указан формат файла книги внутри FBD-архива.');
    PairCount:=0; Descriptor:=''; Payload:='';
    for var Name in Inventory do
      if SameText(ExtractFileExt(Name),'.fbd') then
      begin
        var Candidate:=ChangeFileExt(Name,Book.FileExt).Replace('\','/');
        var Actual:string;
        if Names.TryGetValue(Candidate,Actual) and not Actual.EndsWith('/') and not Actual.EndsWith('\') then
        begin Inc(PairCount); Descriptor:=Name; Payload:=Actual; end;
      end;
    if PairCount<>1 then
      raise EReadError.Create('В архиве FBD не найдена единственная пара описания и файла книги. Удаление по номеру не применяется.');
    Result:=TArray<string>.Create(Exact(Descriptor),Exact(Payload));
  finally Names.Free; end;
end;

end.
