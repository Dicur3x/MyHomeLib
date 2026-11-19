unit unit_BookCompressionRuntime;

interface

uses System.SysUtils, unit_BookCompressionOperation, unit_Interfaces;

function ResolveSelectedCompressionTools(const AppPath: string;
  var Options: TBookCompressionOperationOptions): TArray<string>;
procedure LoadCompressionPreferences(const RegistryFile, DefaultWorkRoot: string;
  var Options: TBookCompressionOperationOptions);
procedure RememberCompressionWork(const RegistryFile: string;
  const Options: TBookCompressionOperationOptions);
// Work queues belong to the application profile. Quality and backup choices
// belong to the collection, surviving rename, relocation and index imports.
// A damaged preference returns a warning and safe choices for explicit review.
function LoadCollectionCompressionPreferences(const RegistryFile, DefaultWorkRoot: string;
  const Collection: IBookCollection; var Options: TBookCompressionOperationOptions): string;
procedure RememberCollectionCompressionWork(const RegistryFile: string;
  const Collection: IBookCollection; const Options: TBookCompressionOperationOptions);
function CompressionWorkRoots(const RegistryFile: string): TArray<string>;

implementation

uses System.Classes, System.IniFiles, System.IOUtils, System.StrUtils, System.JSON, System.Variants,
  unit_FileMutex, unit_AtomicIniFile, unit_CollectionPacking, unit_FormatComponents,
  unit_ComponentUpdates, unit_ProgramUpdateInstaller, unit_Consts;

function ResolveSelectedCompressionTools(const AppPath: string;
  var Options: TBookCompressionOperationOptions): TArray<string>;
var Packing: TCollectionPackingOptions; Version: string; Comparison: Integer;
begin
  Packing:=Default(TCollectionPackingOptions); Packing.ImageGrayscale:=Options.Grayscale;
  if Options.Profile='balanced' then Packing.ImageProfile:=pipBalanced
  else if Options.Profile='economy' then Packing.ImageProfile:=pipEconomy
  else if Options.Profile='maximum' then Packing.ImageProfile:=pipMaximum
  else if Options.Profile='original' then Packing.ImageProfile:=pipOriginal
  else raise EArgumentException.Create('Неизвестный режим сжатия выбранных книг.');
  Result:=ResolvePackingTools(AppPath,Packing);
  Options.Python:=Packing.Python; Options.SevenZip:=Packing.SevenZip;
  Options.Script:=TPath.Combine(AppPath,SELECTED_COMPRESSION_WORKER);
  Options.ToolsRoot:=TPath.Combine(AppPath,'tools');
  Version:=InstalledComponentVersion(AppPath,'BookProcessing');
  if not CompareComponentVersions(Version,SELECTED_COMPRESSION_VERSION,Comparison) or
    (Comparison<0) or not FileExists(Options.Script) or
    not FileExists(TPath.Combine(AppPath,'tools/bookconvert/archive_replacement.py')) then
    if not MatchText('BookProcessing',Result) then Result:=Result+['BookProcessing'];
  if Options.Grayscale or (Packing.ImageProfile<>pipOriginal) then
  begin
    Version:=InstalledComponentVersion(AppPath,'ImageProcessing');
    if (ComponentNeedsRepair(AppPath,'ImageProcessing') or
      not CompareComponentVersions(Version,SELECTED_COMPRESSION_IMAGE_VERSION,Comparison) or (Comparison<0)) and
      not MatchText('ImageProcessing',Result) then Result:=Result+['ImageProcessing'];
  end;
end;

function CompressionWorkRoots(const RegistryFile: string): TArray<string>;
var Ini: TMemIniFile; Names: TStringList; Root: string;
begin
  Result:=nil;
  if not FileExists(RegistryFile) then Exit;
  if TFile.GetSize(RegistryFile)>1024*1024 then
    raise EReadError.Create('Слишком большой список рабочих папок сжатия.');
  Ini:=TMemIniFile.Create(RegistryFile,TEncoding.UTF8); Names:=TStringList.Create;
  try
    Ini.ReadSection('Folders',Names);
    if Names.Count>1024 then raise EReadError.Create('Слишком много рабочих папок сжатия.');
    for var Name in Names do
    begin
      Root:=Ini.ReadString('Folders',Name,'');
      if (Root='') or not TPath.IsPathRooted(Root) then
        raise EReadError.Create('Некорректная папка восстановления сжатия.');
      Result:=Result+[Root];
    end;
  finally Names.Free; Ini.Free; end;
end;

procedure LoadCompressionPreferences(const RegistryFile, DefaultWorkRoot: string;
  var Options: TBookCompressionOperationOptions);
var Ini: TMemIniFile;
begin
  if FileExists(RegistryFile) and (TFile.GetSize(RegistryFile)>1024*1024) then
    raise EReadError.Create('Слишком большой файл параметров сжатия.');
  Ini:=TMemIniFile.Create(RegistryFile,TEncoding.UTF8);
  try
    Options.QueueName:=Ini.ReadString('Preferences','QueueName','');
    if Options.QueueName='' then Options.QueueName:=GUIDToString(TGUID.NewGuid);
    Options.WorkRoot:=Ini.ReadString('Preferences','WorkRoot',DefaultWorkRoot);
    if (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) then Options.WorkRoot:=DefaultWorkRoot;
    Options.Profile:=Ini.ReadString('Preferences','Profile','balanced');
    if not MatchText(Options.Profile,['original','balanced','economy','maximum']) then Options.Profile:='balanced';
    Options.Grayscale:=Ini.ReadBool('Preferences','Grayscale',False);
    Options.ReviewResults:=Ini.ReadBool('Preferences','ReviewResults',True);
    Options.BackupOriginals:=Ini.ReadBool('Preferences','BackupOriginals',False);
    Options.BackupFolder:=Ini.ReadString('Preferences','BackupFolder','');
  finally Ini.Free; end;
end;

procedure RememberCompressionWork(const RegistryFile: string;
  const Options: TBookCompressionOperationOptions);
var Lock: TFileMutex; Ini: TMemIniFile; Roots: TArray<string>; Known: Boolean;
begin
  if (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) then
    raise EArgumentException.Create('Нужна папка для временных файлов сжатия.');
  CompressionQueueRoot(Options);
  ForceDirectories(ExtractFileDir(RegistryFile));
  Lock:=TFileMutex.Create(RegistryFile);
  try
    if not Lock.TryAcquire then raise EWriteError.Create('Другая программа сохраняет параметры сжатия. Повторите запуск.');
    Roots:=CompressionWorkRoots(RegistryFile); Known:=False;
    for var Root in Roots do if Root=Options.WorkRoot then Known:=True;
    if not Known and (Length(Roots)>=1024) then raise EWriteError.Create('Слишком много рабочих папок сжатия.');
    Ini:=TMemIniFile.Create(RegistryFile,TEncoding.UTF8);
    try
      if not Known then Ini.WriteString('Folders',IntToStr(Length(Roots)),Options.WorkRoot);
      Ini.WriteString('Preferences','WorkRoot',Options.WorkRoot);
      Ini.WriteString('Preferences','QueueName',Options.QueueName);
      Ini.WriteString('Preferences','Profile',Options.Profile);
      Ini.WriteBool('Preferences','Grayscale',Options.Grayscale);
      Ini.WriteBool('Preferences','ReviewResults',Options.ReviewResults);
      Ini.WriteBool('Preferences','BackupOriginals',Options.BackupOriginals);
      Ini.WriteString('Preferences','BackupFolder',Options.BackupFolder);
      SaveMemIniFileAtomically(Ini);
    finally Ini.Free; end;
  finally Lock.Free; end;
end;

function CompressionPreferenceJSON(const Options: TBookCompressionOperationOptions): string;
var Data: TJSONObject;
begin
  if not MatchText(Options.Profile,['original','balanced','economy','maximum']) or
    (Options.WorkRoot='') or not TPath.IsPathRooted(Options.WorkRoot) or
    (Length(Options.WorkRoot)>32767) or (Length(Options.BackupFolder)>32767) or
    ((Options.BackupFolder<>'') and not TPath.IsPathRooted(Options.BackupFolder)) then
    raise EArgumentException.Create('Проверьте режим сжатия и папки для временных файлов и оригиналов.');
  Data:=TJSONObject.Create;
  try
    Data.AddPair('version',TJSONNumber.Create(1));
    Data.AddPair('profile',LowerCase(Options.Profile));
    Data.AddPair('grayscale',TJSONBool.Create(Options.Grayscale));
    Data.AddPair('review',TJSONBool.Create(Options.ReviewResults));
    Data.AddPair('backup',TJSONBool.Create(Options.BackupOriginals));
    Data.AddPair('backup_folder',Options.BackupFolder);
    Data.AddPair('work_root',Options.WorkRoot);
    Result:=Data.ToJSON;
  finally Data.Free; end;
end;

function LoadCollectionCompressionPreferences(const RegistryFile, DefaultWorkRoot: string;
  const Collection: IBookCollection; var Options: TBookCompressionOperationOptions): string;
var Stored: string; Data: TJSONValue; Choice: TBookCompressionOperationOptions;
  function Text(const Name: string): string;
  begin
    var Value:=TJSONObject(Data).GetValue(Name);
    if not (Value is TJSONString) then raise EConvertError.Create(Name);
    Result:=Value.Value;
  end;
  function Flag(const Name: string): Boolean;
  begin
    var Value:=TJSONObject(Data).GetValue(Name);
    if not (Value is TJSONBool) then raise EConvertError.Create(Name);
    Result:=TJSONBool(Value).AsBoolean;
  end;
begin
  if not Assigned(Collection) then raise EArgumentNilException.Create('Collection');
  LoadCompressionPreferences(RegistryFile,DefaultWorkRoot,Options);
  // Never inherit another collection's lossy or grayscale preference. Old
  // global preferences remain available to recovery and older installations.
  Options.Profile:='balanced'; Options.Grayscale:=False; Options.ReviewResults:=True;
  Options.BackupOriginals:=False; Options.BackupFolder:=''; Options.EstimateFirst:=False;
  Result:=''; Stored:=VarToStr(Collection.GetProperty(PROP_COMPRESSION_PREFERENCES));
  if Stored='' then Exit;
  Data:=nil;
  try
    try
      if TEncoding.UTF8.GetByteCount(Stored)>256*1024 then raise EConvertError.Create('size');
      Data:=TJSONObject.ParseJSONValue(Stored);
      if not (Data is TJSONObject) then raise EConvertError.Create('object');
      var Version:=TJSONObject(Data).GetValue('version');
      if not (Version is TJSONNumber) or (Version.Value<>'1') then raise EConvertError.Create('version');
      Choice:=Options;
      Choice.Profile:=LowerCase(Text('profile')); Choice.Grayscale:=Flag('grayscale');
      Choice.ReviewResults:=Flag('review'); Choice.BackupOriginals:=Flag('backup');
      Choice.BackupFolder:=Text('backup_folder'); Choice.WorkRoot:=Text('work_root');
      CompressionPreferenceJSON(Choice); // Validate the complete choice before assigning any field.
      Options:=Choice;
    except
      on E: EConvertError do
        Result:='Сохранённые настройки сжатия этой коллекции не удалось прочитать. Выбраны начальные параметры: проверьте их перед запуском.';
      on E: EArgumentException do
        Result:='Сохранённые настройки сжатия этой коллекции некорректны. Выбраны начальные параметры: проверьте их перед запуском.';
    end;
  finally Data.Free; end;
end;

procedure RememberCollectionCompressionWork(const RegistryFile: string;
  const Collection: IBookCollection; const Options: TBookCompressionOperationOptions);
var Stored: string;
begin
  if not Assigned(Collection) then raise EArgumentNilException.Create('Collection');
  if Collection.InBulkOperation then
    raise EInvalidOperation.Create('Дождитесь завершения изменения коллекции перед сжатием.');
  Stored:=CompressionPreferenceJSON(Options);
  // Publish recovery locations first. No file job can be published if either
  // the profile registry or the collection preference cannot be saved.
  RememberCompressionWork(RegistryFile,Options);
  Collection.BeginBulkOperation;
  try
    Collection.SetProperty(PROP_COMPRESSION_PREFERENCES,Stored);
  except Collection.EndBulkOperation(False); raise; end;
  Collection.EndBulkOperation;
end;

end.
