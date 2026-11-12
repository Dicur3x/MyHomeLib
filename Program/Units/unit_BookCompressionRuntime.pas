unit unit_BookCompressionRuntime;

interface

uses System.SysUtils, unit_BookCompressionOperation;

function ResolveSelectedCompressionTools(const AppPath: string;
  var Options: TBookCompressionOperationOptions): TArray<string>;
procedure LoadCompressionPreferences(const RegistryFile, DefaultWorkRoot: string;
  var Options: TBookCompressionOperationOptions);
procedure RememberCompressionWork(const RegistryFile: string;
  const Options: TBookCompressionOperationOptions);
function CompressionWorkRoots(const RegistryFile: string): TArray<string>;

implementation

uses System.Classes, System.IniFiles, System.IOUtils, System.StrUtils,
  unit_FileMutex, unit_AtomicIniFile, unit_CollectionPacking, unit_FormatComponents,
  unit_ComponentUpdates, unit_ProgramUpdateInstaller;

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
  if Options.Grayscale and (Packing.ImageProfile=pipOriginal) then
  begin
    Version:=InstalledComponentVersion(AppPath,'ImageProcessing');
    if (ComponentNeedsRepair(AppPath,'ImageProcessing') or
      not CompareComponentVersions(Version,PACKING_COMPONENT_VERSION,Comparison) or (Comparison<0)) and
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

end.
