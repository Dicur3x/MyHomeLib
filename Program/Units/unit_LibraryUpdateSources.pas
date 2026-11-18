unit unit_LibraryUpdateSources;

interface

uses System.SysUtils, System.Classes;

type
  TLibraryUpdateSource = record
    ID, Name, Location, IndexFile, VersionFile, CatalogSourceID, BooksRoot: string;
    PreviousIndexFile: string;
    Full, Enabled: Boolean;
    LegacyCode: Integer;
    class function NewSource: TLibraryUpdateSource; static;
    function IsRemote: Boolean;
    function LocalFile: string;
    procedure Validate;
  end;
  TLibraryUpdateSources = TArray<TLibraryUpdateSource>;

function ReadLibraryUpdateSources(const Text: string): TLibraryUpdateSources;
function WriteLibraryUpdateSources(const Sources: TLibraryUpdateSources): string;
function ImportLegacyUpdateSources(const Text, DefaultLocation: string;
  out Warnings: string): TLibraryUpdateSources;
function ExportLegacyUpdateSources(const Sources: TLibraryUpdateSources): string;

implementation

uses System.JSON, System.IOUtils, System.StrUtils, System.Generics.Collections;

function ValidGUID(const Value: string): Boolean;
var Parsed: TGUID;
begin
  Result:=False;
  try Parsed:=StringToGUID(Value); Result:=Parsed.ToString<>'';
  except on E:EConvertError do Exit; end;
end;

function RelativeFile(const Value: string): Boolean;
var Part: string;
begin
  Result:=False;
  if (Value='') or TPath.IsPathRooted(Value) or (Pos(':',Value)>0) or
    (Pos(#0,Value)>0) or (Pos('?',Value)>0) or (Pos('#',Value)>0) then Exit;
  for Part in Value.Replace('\','/').Split(['/']) do
    if (Part='') or (Part='.') or (Part='..') then Exit;
  Result:=True;
end;

function AbsoluteFolder(const Value: string): Boolean;
begin
  // IsPathRooted alone also accepts "C:relative" and "\current-drive".
  Result:=TPath.IsPathRooted(Value) and (Length(TPath.GetPathRoot(Value))>=3);
end;

class function TLibraryUpdateSource.NewSource: TLibraryUpdateSource;
begin
  Result:=Default(TLibraryUpdateSource);
  Result.ID:=TGUID.NewGuid.ToString;
  Result.Full:=True; Result.Enabled:=True;
end;

function TLibraryUpdateSource.IsRemote: Boolean;
begin
  Result:=StartsText('https://',Location) or StartsText('http://',Location);
end;

function TLibraryUpdateSource.LocalFile: string;
begin
  Validate;
  if IsRemote then raise EArgumentException.Create('Для сервера сначала нужно загрузить каталог.');
  Result:=TPath.Combine(Location,IndexFile.Replace('/',PathDelim));
end;

procedure TLibraryUpdateSource.Validate;
begin
  if not ValidGUID(ID) then raise EArgumentException.Create('Повреждён идентификатор источника обновлений.');
  if Name.Trim='' then raise EArgumentException.Create('Укажите название источника обновлений.');
  if not RelativeFile(IndexFile) then raise EArgumentException.Create('Укажите имя файла каталога без выхода из папки источника.');
  if (VersionFile<>'') and not RelativeFile(VersionFile) then
    raise EArgumentException.Create('Файл версии должен находиться внутри папки источника.');
  if (Location.Trim='') or (Pos(#0,Location)>0) or
    (not IsRemote and not AbsoluteFolder(Location)) then
    raise EArgumentException.Create('Укажите полный путь к локальной/сетевой папке или адрес HTTP/HTTPS.');
  if (CatalogSourceID<>'') and not ValidGUID(CatalogSourceID) then
    raise EArgumentException.Create('Повреждена привязка к источнику коллекции.');
  if (BooksRoot<>'') and not AbsoluteFolder(BooksRoot) then
    raise EArgumentException.Create('Папка книг должна иметь полный путь.');
  if (PreviousIndexFile<>'') and ((Pos(#0,PreviousIndexFile)>0) or
    not AbsoluteFolder(PreviousIndexFile) or not SameText(TPath.GetExtension(PreviousIndexFile),'.inpx')) then
    raise EArgumentException.Create('Укажите полный путь к прежнему файлу INPX.');
end;

function WriteLibraryUpdateSources(const Sources: TLibraryUpdateSources): string;
var Root, Item: TJSONObject; Items: TJSONArray; Source: TLibraryUpdateSource;
  IDs: TDictionary<string,Boolean>;
begin
  if Length(Sources)>256 then raise EArgumentException.Create('Слишком много источников обновлений.');
  Root:=TJSONObject.Create; IDs:=TDictionary<string,Boolean>.Create;
  try
    Root.AddPair('version',TJSONNumber.Create(1));
    Items:=TJSONArray.Create; Root.AddPair('sources',Items);
    for Source in Sources do
    begin
      Source.Validate;
      if IDs.ContainsKey(LowerCase(Source.ID)) then raise EArgumentException.Create('Повторяющийся идентификатор источника.');
      IDs.Add(LowerCase(Source.ID),True);
      Item:=TJSONObject.Create; Items.AddElement(Item);
      Item.AddPair('id',Source.ID); Item.AddPair('name',Source.Name);
      Item.AddPair('location',Source.Location); Item.AddPair('index',Source.IndexFile);
      Item.AddPair('version_file',Source.VersionFile); Item.AddPair('source_id',Source.CatalogSourceID);
      Item.AddPair('books_root',Source.BooksRoot); Item.AddPair('full',TJSONBool.Create(Source.Full));
      if Source.PreviousIndexFile<>'' then Item.AddPair('previous_index',Source.PreviousIndexFile);
      Item.AddPair('enabled',TJSONBool.Create(Source.Enabled));
      Item.AddPair('legacy_code',TJSONNumber.Create(Source.LegacyCode));
    end;
    Result:=Root.ToJSON;
  finally IDs.Free; Root.Free; end;
end;

function ReadLibraryUpdateSources(const Text: string): TLibraryUpdateSources;
var Root: TJSONValue; Obj, Item: TJSONObject; Items: TJSONArray; I: Integer;
begin
  Result:=nil; if Text.Trim='' then Exit;
  if Length(Text)>1024*1024 then raise EReadError.Create('Настройки источников превышают 1 МБ.');
  Root:=TJSONObject.ParseJSONValue(Text);
  try
    if not (Root is TJSONObject) then raise EReadError.Create('Не удалось прочитать настройки источников.');
    Obj:=TJSONObject(Root);
    if Obj.GetValue<Integer>('version',0)<>1 then raise EReadError.Create('Неизвестная версия настроек источников.');
    Items:=Obj.GetValue<TJSONArray>('sources',nil);
    if not Assigned(Items) or (Items.Count>256) then raise EReadError.Create('Повреждён список источников.');
    SetLength(Result,Items.Count);
    for I:=0 to Items.Count-1 do
    begin
      if not (Items.Items[I] is TJSONObject) then raise EReadError.Create('Повреждена запись источника.');
      Item:=TJSONObject(Items.Items[I]);
      Result[I].ID:=Item.GetValue<string>('id','');
      Result[I].Name:=Item.GetValue<string>('name','');
      Result[I].Location:=Item.GetValue<string>('location','');
      Result[I].IndexFile:=Item.GetValue<string>('index','');
      Result[I].VersionFile:=Item.GetValue<string>('version_file','');
      Result[I].CatalogSourceID:=Item.GetValue<string>('source_id','');
      Result[I].BooksRoot:=Item.GetValue<string>('books_root','');
      Result[I].PreviousIndexFile:=Item.GetValue<string>('previous_index','');
      Result[I].Full:=Item.GetValue<Boolean>('full',True);
      Result[I].Enabled:=Item.GetValue<Boolean>('enabled',True);
      Result[I].LegacyCode:=Item.GetValue<Integer>('legacy_code',0);
    end;
    // Apply exactly the same validation to imported and edited settings.
    WriteLibraryUpdateSources(Result);
  finally Root.Free; end;
end;

function ImportLegacyUpdateSources(const Text, DefaultLocation: string;
  out Warnings: string): TLibraryUpdateSources;
var Lines, Fields, Notes: TStringList; Seen, Groups: TDictionary<string,Boolean>;
  RawRow, Row, Section, Key, Value, Group: string; At, Number, Code: Integer;
  Source: TLibraryUpdateSource; ReferencedGroups: TList<string>;
begin
  Result:=nil; Warnings:='';
  if Length(Text)>1024*1024 then raise EReadError.Create('collections.ini превышает 1 МБ.');
  Lines:=TStringList.Create; Fields:=TStringList.Create; Notes:=TStringList.Create;
  Seen:=TDictionary<string,Boolean>.Create; Groups:=TDictionary<string,Boolean>.Create;
  ReferencedGroups:=TList<string>.Create;
  try
    Lines.Text:=Text; Section:=''; Number:=0;
    Fields.Delimiter:=';'; Fields.QuoteChar:='"'; Fields.StrictDelimiter:=True;
    for RawRow in Lines do
    begin
      Inc(Number); Row:=RawRow.Trim;
      if (Row='') or CharInSet(Row[1],[';','#']) then Continue;
      if Row[1]='[' then begin Section:=LowerCase(Row); Continue; end;
      At:=Pos('=',Row); if At=0 then Continue;
      Key:=LowerCase(Trim(Copy(Row,1,At-1))); Value:=Trim(Copy(Row,At+1,MaxInt));
      if Section='[groups]' then
      begin Groups.AddOrSetValue(Key,True); Continue; end;
      if Section='[inpx]' then
      begin
        Fields.DelimitedText:=Value;
        if Fields.Count>0 then ReferencedGroups.Add('group'+Fields[0]);
        Continue;
      end;
      if (Section<>'[updates]') or not StartsText('update',Key) then Continue;
      if Seen.ContainsKey(Key) then Notes.Add(Format('Повторяющийся ключ %s (строка %d): обе записи сохранены.',[Key,Number]));
      Seen.AddOrSetValue(Key,True); Fields.DelimitedText:=Value;
      if (Fields.Count<6) or not TryStrToInt(Fields[5],Code) then
      begin Notes.Add(Format('Строка %d пропущена: неверное описание обновления.',[Number])); Continue; end;
      Source:=TLibraryUpdateSource.NewSource; Source.Name:=Fields[0];
      Source.Location:=Fields[1]; if Source.Location='' then Source.Location:=DefaultLocation;
      Source.VersionFile:=Fields[2]; Source.IndexFile:=Fields[3]; Source.LegacyCode:=Code;
      if not TryStrToBool(Fields[4],Source.Full) then
      begin Notes.Add(Format('Строка %d пропущена: неверный режим обновления.',[Number])); Continue; end;
      if (Fields.Count>6) and (Fields[6]<>'') then Source.ID:=Fields[6];
      if Fields.Count>7 then Source.CatalogSourceID:=Fields[7];
      if Fields.Count>8 then Source.BooksRoot:=Fields[8];
      if (Fields.Count>9) and (Fields[9]<>'') and not TryStrToBool(Fields[9],Source.Enabled) then
      begin Notes.Add(Format('Строка %d пропущена: неверный флаг включения.',[Number])); Continue; end;
      if Fields.Count>10 then Source.PreviousIndexFile:=Fields[10];
      try Source.Validate;
      except on E:Exception do
        begin Notes.Add(Format('Строка %d: %s',[Number,E.Message])); Continue; end;
      end;
      if Seen.ContainsKey('id:'+LowerCase(Source.ID)) then
      begin
        Notes.Add(Format('Строка %d: повторяющийся идентификатор заменён новым.',[Number]));
        Source.ID:=TGUID.NewGuid.ToString;
      end;
      Seen.Add('id:'+LowerCase(Source.ID),True);
      Result:=Result+[Source];
      if Length(Result)>256 then raise EReadError.Create('Слишком много источников обновлений.');
    end;
    for Group in ReferencedGroups do
      if not Groups.ContainsKey(Group) then
      begin Notes.Add('Не определена группа '+Group+' для шаблона INPX. Шаблоны создания коллекций не изменялись.'); Groups.Add(Group,True); end;
    Warnings:=Notes.Text.Trim;
  finally ReferencedGroups.Free; Groups.Free; Seen.Free; Notes.Free; Fields.Free; Lines.Free; end;
end;

function ExportLegacyUpdateSources(const Sources: TLibraryUpdateSources): string;
var Lines, Fields: TStringList; Source: TLibraryUpdateSource; I: Integer;
begin
  WriteLibraryUpdateSources(Sources);
  Lines:=TStringList.Create; Fields:=TStringList.Create;
  try
    Lines.Add('; HomeLibre: первые шесть полей совместимы со старым collections.ini.');
    Lines.Add('; Дополнительные поля: ID, источник коллекции, папка книг, включён, прежний INPX.');
    Lines.Add('[UPDATES]'); I:=0;
    Fields.Delimiter:=';'; Fields.QuoteChar:='"'; Fields.StrictDelimiter:=True;
    for Source in Sources do
    begin
      Fields.Clear;
      Fields.Add(Source.Name); Fields.Add(Source.Location); Fields.Add(Source.VersionFile);
      Fields.Add(Source.IndexFile); Fields.Add(IntToStr(Ord(Source.Full))); Fields.Add(IntToStr(Source.LegacyCode));
      Fields.Add(Source.ID); Fields.Add(Source.CatalogSourceID); Fields.Add(Source.BooksRoot);
      Fields.Add(IntToStr(Ord(Source.Enabled)));
      if Source.PreviousIndexFile<>'' then Fields.Add(Source.PreviousIndexFile);
      Lines.Add('Update'+IntToStr(I)+'='+Fields.DelimitedText); Inc(I);
    end;
    Result:=Lines.Text;
  finally Fields.Free; Lines.Free; end;
end;

end.
