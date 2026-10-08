unit unit_CatalogSources;

interface

uses System.SysUtils, System.Classes, unit_Globals, unit_Interfaces,
  unit_CollectionMerge, unit_ImportInpxThread, unit_CollectionWorkerThread;

type
  TCatalogSource = record
    ID, Name, INPXFile, Root, CollectionFile: string;
    CollectionID: Integer;
    class function NewID: string; static;
    function IsINPX: Boolean;
    function CacheFile: string;
  end;
  TCatalogSources = TArray<TCatalogSource>;

  TCatalogRefreshWorker = class(TImportInpxThreadBase)
  private
    FSource: TCatalogSource;
    FError: string;
    FSuccess: Boolean;
  protected
    procedure WorkFunction; override;
  public
    constructor Create(const Source: TCatalogSource);
    property Success: Boolean read FSuccess;
    property Error: string read FError;
  end;

  TCatalogMergeWorker = class(TCollectionWorker)
  private
    FSources: TCatalogSources;
    FPlan: TCollectionMergePlan;
    FApply: Boolean;
    FBackupFolder, FError: string;
    FSuccess: Boolean;
    procedure ReportProgress(Current, Total: Integer);
  protected
    procedure WorkFunction; override;
  public
    constructor CreatePreview(CollectionID: Integer; const Sources: TCatalogSources);
    constructor CreateApply(Plan: TCollectionMergePlan; const BackupFolder: string);
    destructor Destroy; override;
    function TakePlan: TCollectionMergePlan;
    property Success: Boolean read FSuccess;
    property Error: string read FError;
  end;

function LoadCatalogSources(const Collection: IBookCollection): TCatalogSources;
procedure SaveCatalogSources(const Collection: IBookCollection; const Sources: TCatalogSources);
function OpenCatalogSource(const Source: TCatalogSource; const SystemData: ISystemData): IBookCollection;

implementation

uses System.JSON, System.Variants, System.IOUtils, Winapi.Windows, Vcl.ComCtrls,
  unit_Consts, unit_Settings, unit_Database_SQLite, dm_user;

type
  // A source snapshot has no entry in the user's collection list. Its system
  // properties are private to the snapshot; imports cannot change target URLs.
  TCatalogSnapshot = class(TBookCollection_SQLite)
  public
    function GetProperty(const PropID: TPropertyID): Variant; override;
    procedure SetProperty(const PropID: TPropertyID; const Value: Variant); override;
  end;

function TCatalogSnapshot.GetProperty(const PropID: TPropertyID): Variant;
begin
  case PropID of
    PROP_ID: Result := FCollectionInfo.ID;
    PROP_DATAFILE: Result := FCollectionInfo.DBFileName;
    PROP_DISPLAYNAME: Result := FCollectionInfo.DisplayName;
    PROP_ROOTFOLDER: Result := FCollectionInfo.RootFolder;
    PROP_LIBUSER, PROP_LIBPASSWORD: Result := '';
  else Result := inherited GetProperty(PropID); end;
end;

procedure TCatalogSnapshot.SetProperty(const PropID: TPropertyID; const Value: Variant);
var SavedID: Integer;
begin
  if not isCollectionProp(PropID) then Exit;
  SavedID := FCollectionInfo.ID;
  FCollectionInfo.ID := INVALID_COLLECTION_ID;
  try inherited SetProperty(PropID, Value);
  finally FCollectionInfo.ID := SavedID; end;
end;

class function TCatalogSource.NewID: string;
var ID: TGUID;
begin CreateGUID(ID); Result := GUIDToString(ID); end;

function TCatalogSource.IsINPX: Boolean;
begin Result := INPXFile <> ''; end;

function TCatalogSource.CacheFile: string;
var IDValue: TGUID;
begin
  // Only validated GUIDs form writable paths; JSON cannot redirect snapshots.
  try IDValue := StringToGUID(ID);
  except on E: EConvertError do raise Exception.Create('Неверный идентификатор источника.'); end;
  Result := TPath.Combine(Settings.DataPath, 'CatalogSources\' + GUIDToString(IDValue) + '\catalog.hlc2');
end;

function LoadCatalogSources(const Collection: IBookCollection): TCatalogSources;
var JSON: TJSONValue; Values: TJSONArray; Item: TJSONValue; Obj: TJSONObject;
  I: Integer; Text: string;
begin
  Result := nil; Text := VarToStr(Collection.GetProperty(PROP_CATALOG_SOURCES));
  if Text = '' then Exit;
  JSON := TJSONObject.ParseJSONValue(Text);
  try
    if not (JSON is TJSONArray) then raise Exception.Create('Не удалось прочитать список источников коллекции.');
    Values := TJSONArray(JSON); SetLength(Result, Values.Count);
    for I := 0 to Values.Count - 1 do
    begin
      Item := Values.Items[I];
      if not (Item is TJSONObject) then raise Exception.Create('Повреждена запись источника.');
      Obj := TJSONObject(Item);
      Result[I].ID := Obj.GetValue<string>('id');
      Result[I].Name := Obj.GetValue<string>('name');
      Result[I].INPXFile := Obj.GetValue<string>('inpx', '');
      Result[I].Root := Obj.GetValue<string>('root', '');
      Result[I].CollectionFile := Obj.GetValue<string>('file', '');
      Result[I].CollectionID := Obj.GetValue<Integer>('collection', INVALID_COLLECTION_ID);
    end;
  finally JSON.Free; end;
end;

procedure SaveCatalogSources(const Collection: IBookCollection; const Sources: TCatalogSources);
var JSON: TJSONArray; Obj: TJSONObject; Source: TCatalogSource;
begin
  JSON := TJSONArray.Create;
  try
    for Source in Sources do
    begin
      Obj := TJSONObject.Create; JSON.AddElement(Obj);
      Obj.AddPair('id', Source.ID); Obj.AddPair('name', Source.Name);
      Obj.AddPair('inpx', Source.INPXFile); Obj.AddPair('root', Source.Root);
      Obj.AddPair('file', Source.CollectionFile);
      Obj.AddPair('collection', TJSONNumber.Create(Source.CollectionID));
    end;
    Collection.SetProperty(PROP_CATALOG_SOURCES, JSON.ToJSON);
  finally JSON.Free; end;
end;

function OpenSnapshot(const Source: TCatalogSource; const FileName: string;
  const SystemData: ISystemData): IBookCollection;
var Info: TCollectionInfo;
begin
  Info.Clear; Info.ID := $60000001; Info.DisplayName := Source.Name;
  Info.RootFolder := IncludeTrailingPathDelimiter(TPath.GetFullPath(Source.Root));
  Info.DBFileName := FileName; Info.CollectionType := CT_EXTERNAL_LOCAL_FB;
  Result := TCatalogSnapshot.Create(Info, SystemData);
end;

function OpenCatalogSource(const Source: TCatalogSource; const SystemData: ISystemData): IBookCollection;
var Info: TCollectionInfo;
begin
  if Source.IsINPX then
  begin
    if not FileExists(Source.CacheFile) then raise Exception.Create('Сначала обновите источник: ' + Source.Name);
    Result := OpenSnapshot(Source, Source.CacheFile, SystemData);
  end
  else
  begin
    Info := SystemData.GetCollectionInfo(Source.CollectionID);
    if (Info.ID = INVALID_COLLECTION_ID) or not SameFileName(Info.DBFileName, Source.CollectionFile) then
      raise Exception.Create('Исходная коллекция недоступна: ' + Source.Name);
    Result := SystemData.GetCollection(Source.CollectionID);
  end;
end;

constructor TCatalogRefreshWorker.Create(const Source: TCatalogSource);
begin
  inherited Create(MHL_INVALID_ID); FSource := Source;
  FGenresType := gtFb2; FKeepCollectionProps := True;
end;

procedure TCatalogRefreshWorker.WorkFunction;
var Snapshot: IBookCollection; Cache, Pending: string;
  procedure RemovePending;
  const Suffixes: array[0..2] of string = ('', '-wal', '-shm');
  var Suffix: string;
  begin
    if (Pending = '') or not TPath.GetFullPath(Pending).StartsWith(IncludeTrailingPathDelimiter(TPath.GetDirectoryName(Cache)), True) then Exit;
    for Suffix in Suffixes do if FileExists(Pending + Suffix) then TFile.Delete(Pending + Suffix);
  end;
begin
  Cache := ''; Pending := ''; FSuccess := False;
  try
    if not FSource.IsINPX then raise Exception.Create('Обновление INPX доступно для источника с файлом индекса.');
    if not FileExists(FSource.INPXFile) then raise Exception.Create('Файл INPX не найден: ' + FSource.INPXFile);
    if not DirectoryExists(FSource.Root) then raise Exception.Create('Папка книг не найдена: ' + FSource.Root);
    Cache := FSource.CacheFile; ForceDirectories(TPath.GetDirectoryName(Cache));
    Pending := TPath.Combine(TPath.GetDirectoryName(Cache), TCatalogSource.NewID + '.pending.hlc2');
    TBookCollection_SQLite.CreateCollection(FSystemData, Pending, CT_EXTERNAL_LOCAL_FB, Settings.SystemFileName[sfGenresFB2]);
    Snapshot := OpenSnapshot(FSource, Pending, FSystemData);
    Snapshot.BeginBulkOperation;
    try
      Import(FSource.INPXFile, False, Snapshot);
      if Canceled then raise EAbort.Create('Обновление источника отменено.');
      Snapshot.EndBulkOperation(True);
    except
      if Snapshot.InBulkOperation then Snapshot.EndBulkOperation(False);
      raise;
    end;
    Snapshot := nil;
    if Canceled then raise EAbort.Create('Обновление источника отменено.');
    if not MoveFileEx(PChar(Pending), PChar(Cache), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
    Pending := ''; FSuccess := True;
    Teletype('Источник обновлён. Для изменения коллекции выполните предпросмотр и примените объединение.', tsInfo);
  except
    on E: Exception do
    begin
      FError := E.Message; Snapshot := nil;
      RemovePending;
      Teletype(FError, tsError);
    end;
  end;
end;

constructor TCatalogMergeWorker.CreatePreview(CollectionID: Integer; const Sources: TCatalogSources);
begin inherited Create(CollectionID); FSources := Copy(Sources); end;

constructor TCatalogMergeWorker.CreateApply(Plan: TCollectionMergePlan; const BackupFolder: string);
begin
  inherited Create(MHL_INVALID_ID); FPlan := Plan; FApply := True; FBackupFolder := BackupFolder;
end;

destructor TCatalogMergeWorker.Destroy;
begin
  if not FApply then FPlan.Free;
  inherited;
end;

function TCatalogMergeWorker.TakePlan: TCollectionMergePlan;
begin Result := FPlan; FPlan := nil; end;

procedure TCatalogMergeWorker.ReportProgress(Current, Total: Integer);
begin
  SetProgressHint(pbstNormal);
  if Total > 0 then SetProgress(Integer(Int64(Current) * 100 div Total));
  SetComment(Format('Проверено книг: %d из %d', [Current, Total]));
end;

procedure TCatalogMergeWorker.WorkFunction;
var Sources: TMergeSources; I: Integer;
begin
  try
    SetProgressHint(pbstMarquee);
    SetComment('Подготовка каталогов и резервных копий...');
    if not FApply then
    begin
      if Length(FSources) = 0 then raise Exception.Create('Добавьте хотя бы один источник.');
      SetLength(Sources, Length(FSources));
      for I := 0 to High(FSources) do
      begin
        Sources[I].ID := FSources[I].ID; Sources[I].Name := FSources[I].Name;
        Sources[I].Collection := OpenCatalogSource(FSources[I], FSystemData);
        if FSources[I].IsINPX then Sources[I].DatabaseFile := FSources[I].CacheFile
        else Sources[I].DatabaseFile := FSources[I].CollectionFile;
      end;
      FPlan := TCollectionMergePlan.Create(FCollection, Sources, FSystemData);
      FPlan.Preview(ReportProgress, function: Boolean begin Result := Canceled; end);
    end
    else FPlan.Apply(FBackupFolder, ReportProgress, function: Boolean begin Result := Canceled; end);
    FSuccess := True;
    Teletype('Готово.', tsInfo);
  except on E: Exception do begin FError := E.Message; Teletype(FError, tsError); end; end;
end;

end.
