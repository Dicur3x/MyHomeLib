unit unit_LibraryUpdateHistory;

interface

uses unit_Interfaces, unit_CatalogSources, unit_LibraryUpdateSources;

function LoadLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; out Source: TCatalogSource): Boolean; overload;
function LoadLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; out Source: TCatalogSource; out IndexSHA256:string): Boolean; overload;
procedure SaveLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; const Source: TCatalogSource; const SHA256: string);

implementation

uses System.SysUtils, System.Classes, System.JSON, System.Variants, unit_Consts;

function ReadHistory(const Collection: IBookCollection): TJSONObject;
var Text: string; Value: TJSONValue; Items: TJSONArray;
begin
  Text:=VarToStr(Collection.GetProperty(PROP_LIBRARY_UPDATE_HISTORY));
  if Text='' then
  begin
    Result:=TJSONObject.Create; Result.AddPair('version',TJSONNumber.Create(1));
    Result.AddPair('sources',TJSONArray.Create); Exit;
  end;
  if Length(Text)>1024*1024 then raise EReadError.Create('История обновлений превышает допустимый размер.');
  Value:=TJSONObject.ParseJSONValue(Text);
  if not (Value is TJSONObject) then begin Value.Free; raise EReadError.Create('Повреждена история обновлений.'); end;
  Result:=TJSONObject(Value);
  if (Result.GetValue<Integer>('version',0)<>1) or not Assigned(Result.GetValue<TJSONArray>('sources',nil)) then
  begin Result.Free; raise EReadError.Create('Неизвестный формат истории обновлений.'); end;
  try
    Items:=Result.GetValue<TJSONArray>('sources');
    if Items.Count>256 then raise EReadError.Create('Слишком много записей истории обновлений.');
    for var Item in Items do
      if not (Item is TJSONObject) then raise EReadError.Create('Повреждена запись истории обновлений.');
  except Result.Free; raise; end;
end;

function LoadLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; out Source: TCatalogSource): Boolean;
var SHA256:string;
begin Result:=LoadLibraryUpdateHistory(Collection,Profile,Source,SHA256); end;

function LoadLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; out Source: TCatalogSource; out IndexSHA256:string): Boolean;
var Root, Item: TJSONObject; Items: TJSONArray;
begin
  Result:=False; Source:=Default(TCatalogSource); IndexSHA256:=''; Root:=ReadHistory(Collection);
  try
    Items:=Root.GetValue<TJSONArray>('sources');
    // A bound source has one applied baseline across all delivery profiles.
    // Read older version-1 histories backwards: they may retain one stale
    // entry per profile, in application order.
    for var I:=Items.Count-1 downto 0 do
    begin
      var Value:=Items.Items[I];
      if not (Value is TJSONObject) then raise EReadError.Create('Повреждена запись истории обновлений.');
      Item:=TJSONObject(Value);
      if not SameText(Item.GetValue<string>('binding',''),Profile.CatalogSourceID) then Continue;
      if (Profile.CatalogSourceID='') and
        not SameText(Item.GetValue<string>('profile',''),Profile.ID) then Continue;
      Source.ID:=Item.GetValue<string>('source',''); Source.CacheVersion:=Item.GetValue<string>('cache','');
      if Profile.CatalogSourceID='' then
      begin if not SameText(Source.ID,Profile.ID) then raise EReadError.Create('Не совпала привязка истории обновления.'); end
      else if not SameText(Source.ID,Profile.CatalogSourceID) then raise EReadError.Create('Не совпал источник истории обновления.');
      if Source.CacheVersion='' then raise EReadError.Create('Не указана версия сохранённого индекса.');
      // CacheFile validates both GUIDs before they become a filesystem path.
      Source.CacheFile;
      Source.Name:=Item.GetValue<string>('name',''); Source.Root:=Item.GetValue<string>('root','');
      Source.LibraryNamespace:=Item.GetValue<string>('library',''); Source.INPXFile:=Item.GetValue<string>('index','');
      IndexSHA256:=Item.GetValue<string>('sha256','');
      Exit(True);
    end;
  finally Root.Free; end;
end;

procedure SaveLibraryUpdateHistory(const Collection: IBookCollection;
  const Profile: TLibraryUpdateSource; const Source: TCatalogSource; const SHA256: string);
var Root, Item: TJSONObject; Items: TJSONArray;
begin
  if not Collection.InBulkOperation then raise EInvalidOperation.Create('История сохраняется внутри обновления каталога.');
  Source.CacheFile;
  Root:=ReadHistory(Collection);
  try
    Items:=Root.GetValue<TJSONArray>('sources');
    for var I:=Items.Count-1 downto 0 do
    begin
      Item:=TJSONObject(Items.Items[I]);
      if not SameText(Item.GetValue<string>('binding',''),Profile.CatalogSourceID) then Continue;
      // Retain another binding's state when the same delivery profile is
      // rebound. Unbound profiles still own their independent history.
      if (Profile.CatalogSourceID<>'') or
        SameText(Item.GetValue<string>('profile',''),Profile.ID) then Items.Remove(I).Free;
    end;
    Item:=TJSONObject.Create; Items.AddElement(Item);
    Item.AddPair('profile',Profile.ID); Item.AddPair('binding',Profile.CatalogSourceID);
    Item.AddPair('source',Source.ID); Item.AddPair('cache',Source.CacheVersion);
    Item.AddPair('name',Source.Name); Item.AddPair('root',Source.Root);
    Item.AddPair('library',Source.LibraryNamespace); Item.AddPair('index',Source.INPXFile); Item.AddPair('sha256',SHA256);
    Collection.SetProperty(PROP_LIBRARY_UPDATE_HISTORY,Root.ToJSON);
  finally Root.Free; end;
end;

end.
