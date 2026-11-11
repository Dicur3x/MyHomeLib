unit unit_ReaderAssociations;

interface

uses System.SysUtils;

type TReaderAssociationGroup = (ragBooks,ragDocuments,ragImages,ragArchives);
  TReaderAssociationGroups = set of TReaderAssociationGroup;

function ReaderAssociationExtensions(Groups:TReaderAssociationGroups):TArray<string>;
procedure RegisterReaderAssociations(const ExeFile:string; Groups:TReaderAssociationGroups;
  const SoftwareRoot:string = 'Software');
function UnregisterReaderAssociations(const ExeFile:string;
  const SoftwareRoot:string = 'Software'):Boolean;
function ReaderAssociationsRegistered(const ExeFile:string;
  const SoftwareRoot:string = 'Software'):Boolean;
function ReaderDefaultAppsURI:string;

implementation

uses Winapi.Windows, System.Win.Registry, System.IOUtils, System.Classes, Winapi.ShlObj;

const ReaderApp = 'HomeLibre.Reader';
  ReaderProgID = 'HomeLibre.Reader.Document';
  ReaderKey = '\HomeLibre\ReaderAssociations';

function ReaderAssociationExtensions(Groups:TReaderAssociationGroups):TArray<string>;
var Text:string;
begin
  Text:='';
  if ragBooks in Groups then Text:=Text+'fb2|fb3|epub|pdf|djvu|djv|dju|djm|djvm|mobi|azw|azw3|prc|cbz|cbr|cb7|sm|'+
    'chm|lit|lrf|pdb|ibk|rgo|jutoh|pages|cr3|b1|tcr|rb|abw|sxw|ha|';
  if ragDocuments in Groups then Text:=Text+'txt|faq|wri|rtf|md|markdown|html|htm|shtml|xhtml|mht|mhtml|'+
    'docx|odt|doc|dot|docm|dotx|dotm|ott|wps|wpd|ppt|pptx|pptm|pps|ppsx|ppsm|pot|potx|potm|odp|otp|'+
    'xls|xlt|xlsx|xlsm|xltx|xltm|ods|ots|xps|oxps|';
  if ragImages in Groups then Text:=Text+'jpg|jpeg|png|gif|bmp|webp|tif|tiff|';
  if ragArchives in Groups then Text:=Text+'zip|fbz|7z|7zip|rar|tar|gz|gzip|tgz|bz2|xz|cab|apk|';
  if Text='' then Exit(nil);
  Result:=Text.TrimRight(['|']).Split(['|']);
  for var I:=0 to High(Result) do Result[I]:='.'+Result[I];
end;

function ReaderDefaultAppsURI:string;
begin Result:='ms-settings:defaultapps?registeredAppUser=HomeLibre.Reader'; end;

function RegistrationPath(const Root:string):string;
begin
  if (Root='') or Root.StartsWith('\') or Root.Contains('..') then
    raise EArgumentException.Create('Некорректный раздел регистрации читалки.');
  Result:=Root+ReaderKey;
end;

function ReadValue(Registry:TRegistry; const Key,Name:string):string;
begin
  Result:='';
  if Registry.OpenKeyReadOnly(Key) then
  try
    if Registry.ValueExists(Name) and (Registry.GetDataType(Name) in [rdString,rdExpandString]) then
      Result:=Registry.ReadString(Name);
  finally Registry.CloseKey; end;
end;

procedure WriteValue(Registry:TRegistry; const Key,Name,Value:string);
begin
  if not Registry.OpenKey(Key,True) then raise ERegistryException.Create('Не удалось зарегистрировать читалку для этого пользователя Windows.');
  try Registry.WriteString(Name,Value); finally Registry.CloseKey; end;
end;

function OwnPath(Registry:TRegistry; const Key,ExeFile:string):Boolean;
begin Result:=SameText(ReadValue(Registry,Key,'ReaderPath'),TPath.GetFullPath(ExeFile)); end;

function ReaderAssociationsRegistered(const ExeFile,SoftwareRoot:string):Boolean;
var Registry:TRegistry;
begin
  Registry:=TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    Registry.RootKey:=HKEY_CURRENT_USER;
    Result:=OwnPath(Registry,RegistrationPath(SoftwareRoot),ExeFile);
  finally Registry.Free; end;
end;

procedure DeleteOwnedTree(Registry:TRegistry; const Key:string);
var Children:TStringList;
begin
  Children:=TStringList.Create;
  try
    if Registry.OpenKey(Key,False) then
    begin
      try Registry.GetKeyNames(Children); finally Registry.CloseKey; end;
      for var Child in Children do DeleteOwnedTree(Registry,Key+'\'+Child);
    end;
    if Registry.KeyExists(Key) and not Registry.DeleteKey(Key) then
      raise ERegistryException.Create('Не удалось удалить регистрацию читалки.');
  finally Children.Free; end;
end;

function UnregisterReaderAssociations(const ExeFile,SoftwareRoot:string):Boolean;
var Registry:TRegistry; Root,ProgramKey,ClassRoot:string;
begin
  Root:=RegistrationPath(SoftwareRoot);
  Registry:=TRegistry.Create(KEY_READ or KEY_WRITE or KEY_WOW64_64KEY);
  try
    Registry.RootKey:=HKEY_CURRENT_USER;
    Result:=OwnPath(Registry,Root,ExeFile);
    if not Result then Exit;
    ClassRoot:=SoftwareRoot+'\Classes\'; ProgramKey:=ClassRoot+ReaderProgID;
    // Never remove somebody else's replacement command, or an association's
    // default value / protected Windows UserChoice. Only our named candidate.
    if ReadValue(Registry,ProgramKey+'\shell\open\command','')<>'"'+TPath.GetFullPath(ExeFile)+'" "%1"' then
      raise ERegistryException.Create('Команда открытия была изменена. Регистрация сохранена.');
    for var Ext in ReaderAssociationExtensions([ragBooks,ragDocuments,ragImages,ragArchives]) do
      if Registry.OpenKey(ClassRoot+Ext+'\OpenWithProgids',False) then
      try Registry.DeleteValue(ReaderProgID); finally Registry.CloseKey; end;
    if Registry.OpenKey(SoftwareRoot+'\RegisteredApplications',False) then
    try
      if Registry.ValueExists(ReaderApp) and (Registry.ReadString(ReaderApp)=Root+'\Capabilities') then
        Registry.DeleteValue(ReaderApp);
    finally Registry.CloseKey; end;
    DeleteOwnedTree(Registry,ProgramKey); DeleteOwnedTree(Registry,Root);
  finally Registry.Free; end;
  if SoftwareRoot='Software' then SHChangeNotify(SHCNE_ASSOCCHANGED,SHCNF_IDLIST,nil,nil);
end;

procedure RegisterReaderAssociations(const ExeFile:string; Groups:TReaderAssociationGroups; const SoftwareRoot:string);
var Registry:TRegistry; Root,Path,ClassRoot:string; Extensions:TArray<string>;
begin
  Root:=RegistrationPath(SoftwareRoot); Path:=TPath.GetFullPath(ExeFile);
  Extensions:=ReaderAssociationExtensions(Groups);
  if Length(Extensions)=0 then raise EArgumentException.Create('Выберите хотя бы одну группу форматов.');
  if not FileExists(Path) or not SameText(ExtractFileExt(Path),'.exe') then
    raise EArgumentException.Create('Не найден исполняемый файл читалки.');
  Registry:=TRegistry.Create(KEY_READ or KEY_WRITE or KEY_WOW64_64KEY);
  try
    Registry.RootKey:=HKEY_CURRENT_USER;
    ClassRoot:=SoftwareRoot+'\Classes\';
    // A portable move repairs these paths; it never claims the extensions'
    // default values. Publish RegisteredApplications only after all mappings.
    WriteValue(Registry,ClassRoot+ReaderProgID,'','Книга HomeLibre Reader');
    WriteValue(Registry,ClassRoot+ReaderProgID,'ReaderPath',Path);
    WriteValue(Registry,ClassRoot+ReaderProgID+'\DefaultIcon','','"'+Path+'",0');
    WriteValue(Registry,ClassRoot+ReaderProgID+'\shell\open\command','','"'+Path+'" "%1"');
    WriteValue(Registry,Root,'ReaderPath',Path);
    WriteValue(Registry,Root+'\Capabilities','ApplicationName','HomeLibre Reader');
    WriteValue(Registry,Root+'\Capabilities','ApplicationDescription','Чтение книг и документов. Некоторые форматы требуют модулей по запросу.');
    WriteValue(Registry,Root+'\Capabilities','ApplicationIcon','"'+Path+'",0');
    DeleteOwnedTree(Registry,Root+'\Capabilities\FileAssociations');
    for var Ext in ReaderAssociationExtensions([ragBooks,ragDocuments,ragImages,ragArchives]) do
      if Registry.OpenKey(ClassRoot+Ext+'\OpenWithProgids',False) then
      try Registry.DeleteValue(ReaderProgID); finally Registry.CloseKey; end;
    for var Ext in Extensions do
    begin
      WriteValue(Registry,Root+'\Capabilities\FileAssociations',Ext,ReaderProgID);
      WriteValue(Registry,ClassRoot+Ext+'\OpenWithProgids',ReaderProgID,'');
    end;
    WriteValue(Registry,SoftwareRoot+'\RegisteredApplications',ReaderApp,Root+'\Capabilities');
  finally Registry.Free; end;
  if SoftwareRoot='Software' then SHChangeNotify(SHCNE_ASSOCCHANGED,SHCNF_IDLIST,nil,nil);
end;

end.
