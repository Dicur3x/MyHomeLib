unit unit_BookDeletionMembers;

interface

uses System.SysUtils, System.Generics.Collections, unit_Globals;

type
  TBookDeletionMemberIndex = class
  private
    FNames: TDictionary<string,string>;
    FInventory: TArray<string>;
    function Exact(const Name: string): string;
  public
    constructor Create(const Inventory: TArray<string>);
    destructor Destroy; override;
    function Resolve(const Book: TBookRecord): TArray<string>;
  end;

function IsWholeBookArchive(const Book: TBookRecord): Boolean;

// Resolves only a proved full internal path. Unlike read-time compatibility
// fallback this must never choose a basename, wildcard or legacy ordinal.
// FBD containers require exactly one matching descriptor/payload pair.
function ExactBookDeletionMembers(const Book: TBookRecord;
  const Inventory: TArray<string>): TArray<string>;

implementation

uses System.Classes, System.IOUtils, unit_MHLArchiveHelpers;

function IsWholeBookArchive(const Book: TBookRecord): Boolean;
begin
  Result := IsArchiveExt(Book.FileExt) and
    (Book.GetBookFormat(TPath.Combine(Book.CollectionRoot, Book.Folder)) = bfRaw);
end;

constructor TBookDeletionMemberIndex.Create(const Inventory:TArray<string>);
begin
  inherited Create;
  if (Length(Inventory)=0) or (Length(Inventory)>200000) then
    raise EReadError.Create('Неверный список файлов внутри архива.');
  FNames:=TDictionary<string,string>.Create(Length(Inventory));
  for var Name in Inventory do
  begin
    var Key:=Name.Replace('\','/');
    if (Key='') or FNames.ContainsKey(Key) then
      raise EReadError.Create('В архиве есть неоднозначные имена файлов. Удаление не начато.');
    FNames.Add(Key,Name);
  end;
  FInventory:=Inventory;
end;

destructor TBookDeletionMemberIndex.Destroy;
begin
  FNames.Free;
  inherited;
end;

function TBookDeletionMemberIndex.Exact(const Name:string):string;
begin
  if not FNames.TryGetValue(Name.Replace('\','/'),Result) then
    raise EReadError.Create('В архиве не найден точный путь книги: '+Name);
  if Result.EndsWith('/') or Result.EndsWith('\') then
    raise EReadError.Create('Вместо файла книги выбрана папка архива.');
end;

function TBookDeletionMemberIndex.Resolve(const Book:TBookRecord):TArray<string>;
var Format:TBookFormat; Member,Descriptor,Payload:string; PairCount:Integer;
begin
  Format:=Book.GetBookFormat(TPath.Combine(Book.CollectionRoot,Book.Folder));
  if not (Format in [bfFb2Archive,bfRawArchive,bfFbd]) then
    raise EArgumentException.Create('Эта книга не является файлом внутри общего архива.');
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
  for var Name in FInventory do
    if SameText(ExtractFileExt(Name),'.fbd') then
    begin
      var Candidate:=ChangeFileExt(Name,Book.FileExt).Replace('\','/');
      var Actual:string;
      if FNames.TryGetValue(Candidate,Actual) and not Actual.EndsWith('/') and not Actual.EndsWith('\') then
      begin Inc(PairCount); Descriptor:=Name; Payload:=Actual; end;
    end;
  if PairCount<>1 then
    raise EReadError.Create('В архиве FBD не найдена единственная пара описания и файла книги. Удаление по номеру не применяется.');
  Result:=TArray<string>.Create(Exact(Descriptor),Exact(Payload));
end;

function ExactBookDeletionMembers(const Book:TBookRecord;
  const Inventory:TArray<string>):TArray<string>;
var Index:TBookDeletionMemberIndex;
begin
  Index:=TBookDeletionMemberIndex.Create(Inventory);
  try Result:=Index.Resolve(Book); finally Index.Free; end;
end;

end.
