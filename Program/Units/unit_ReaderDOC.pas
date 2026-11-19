unit unit_ReaderDOC;

interface

uses System.SysUtils;

function IsDirectDOCFormat(const Extension: string): Boolean;
function FindDirectDOCReader: string;
function PreparedDOCWarning(const FileName: string): string;
function PrepareBinaryDOC(const SourceFile, DocxName, TextName, AppPath: string;
  const CheckCanceled: TProc; out Warning: string): string;
function PrepareDirectDOC(const SourceFile, OriginalSource, AppPath: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, System.Win.Registry,
  Winapi.Windows, unit_BookCache, unit_MHLExternalTools, unit_FormatComponents;

const
  DOCStampVersion = 'doc-reflow-v3|';
  ApproximateDOCWarning = 'Некоторые элементы оформления старого DOC могли не перенестись.';
  TextOnlyDOCWarning = 'Из DOC формата Word 6/95 извлечён только текст. Оформление и изображения не перенесены.';

type
  EDOCReadTimeout = class(Exception);

function IsDirectDOCFormat(const Extension: string): Boolean;
begin Result:=SameText(Extension.TrimLeft(['.']),'doc') or SameText(Extension.TrimLeft(['.']),'dot'); end;

function FindDirectDOCReader: string;
const Views: array[0..1] of Cardinal = (KEY_READ or KEY_WOW64_64KEY,KEY_READ or KEY_WOW64_32KEY);
var Registry: TRegistry; Flags: Cardinal;
begin
  Result:=FindExternalTool('HomeLibDoc.exe','doc');
  if Result='' then Exit;
  // .NET 4 is a Windows component. Check quietly before launching a managed
  // helper, so an older machine gets our own reader message, no installer UI.
  for Flags in Views do
  begin
    Registry:=TRegistry.Create(Flags);
    try
      Registry.RootKey:=HKEY_LOCAL_MACHINE;
      if Registry.OpenKeyReadOnly('\Software\Microsoft\NET Framework Setup\NDP\v4\Full') and
        Registry.ValueExists('Release') and (Registry.ReadInteger('Release')>=394802) then Exit;
    finally Registry.Free; end;
  end;
  Result:='';
end;

function PrepareBinaryDOC(const SourceFile, DocxName, TextName, AppPath: string;
  const CheckCanceled: TProc; out Warning: string): string;
var Tool, RichTool, TextTool: string; Log: TStringStream; Legacy: Boolean;
  function RunWorker(const Worker, Destination: string): Boolean;
  var Started: UInt64;
  begin
    Log.Clear;
    CheckCanceled;
    Started:=GetTickCount64;
    try
      RunExternalToolToStream(Worker,[TPath.GetFullPath(SourceFile),TPath.GetFullPath(Destination)],Log,
        function: Boolean
        begin
          CheckCanceled;
          if GetTickCount64-Started>30000 then
            raise EDOCReadTimeout.Create('Чтение DOC превысило 30 секунд.');
          Result:=False;
        end,0,True,384*1024*1024);
    except
      on E: EMHLExternalToolError do Exit(False);
    end;
    CheckCanceled;
    Result:=FileExists(Destination) and (TFile.GetSize(Destination)>0);
  end;
  function ValidDocx: Boolean;
  var Zip: TZipFile;
  begin
    Zip:=TZipFile.Create;
    try
      try
        Zip.Open(DocxName,zmRead);
        Result:=(Zip.IndexOf('word/document.xml')>=0) and (Zip.IndexOf('[Content_Types].xml')>=0);
      except
        on E: EZipException do Result:=False;
      end;
    finally Zip.Free; end;
  end;
  procedure CheckPassword;
  begin
    if Log.DataString.Contains('ERROR PASSWORD') then
      raise Exception.Create('Этот DOC защищён паролем. Если у вас есть пароль, сохраните копию в DOCX без пароля.');
  end;
begin
  Warning:='';
  Tool:=FindDirectDOCReader;
  if Tool='' then raise EMHLComponentRequired.Create('DocSharp','Для этого DOC нужен компонент DocSharp.');
  Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    if RunWorker(Tool,DocxName) and ValidDocx then Exit(DocxName);
    CheckPassword;
    Legacy:=Log.DataString.Contains('ERROR OLD');
    RichTool:=TPath.Combine(AppPath,LEGACY_DOC_RICH_WORKER);
    if FileExists(RichTool) then
    begin
      // The destination is private to this operation. Discard a partial
      // result so the second worker can also require a new output file.
      if FileExists(DocxName) then TFile.Delete(DocxName);
      var RichReady:=False;
      try
        RichReady:=RunWorker(RichTool,DocxName) and ValidDocx;
      except
        on E: EDOCReadTimeout do
          if not (Legacy or Log.DataString.Contains('LEGACY DOC')) then raise;
      end;
      CheckPassword;
      Legacy:=Legacy or Log.DataString.Contains('LEGACY DOC');
      if RichReady then
      begin
        if Log.DataString.Contains('DOC APPROXIMATED') then Warning:=ApproximateDOCWarning;
        Exit(DocxName);
      end;
    end;
    if not Legacy then
      raise Exception.Create('Не удалось прочитать DOC. Возможно, файл повреждён или использует неподдерживаемый вариант формата.');
    TextTool:=TPath.Combine(AppPath,LEGACY_DOC_WORKER);
    if not FileExists(TextTool) then
      raise EMHLComponentRequired.Create('BookProcessing','Для обработки DOC формата Word 6/95 обновите модуль обработки книг.');
    if not RunWorker(TextTool,TextName) then
      raise Exception.Create('Не удалось извлечь текст из старого DOC. Можно сохранить копию в исходном формате.');
    Warning:=TextOnlyDOCWarning;
    Result:=TextName;
  finally Log.Free; end;
end;

function PreparedDOCWarning(const FileName: string): string;
var Stamp, StampFile: string;
begin
  Result:='';
  if not ExtractFileName(FileName).StartsWith('homelib-doc-') then Exit;
  StampFile:=FileName+'.source';
  if not FileExists(StampFile) then Exit;
  try
    if TFile.GetSize(StampFile)>65536 then Exit;
    Stamp:=TFile.ReadAllText(StampFile,TEncoding.UTF8);
  except
    on E: EInOutError do Exit;
    on E: EStreamError do Exit;
  end;
  if not Stamp.StartsWith(DOCStampVersion) then Exit;
  if Stamp.EndsWith('|text') then Result:='Открыт только текст DOC'
  else if Stamp.EndsWith('|approximate') then Result:='Оформление DOC перенесено частично';
end;

function PrepareDirectDOC(const SourceFile, OriginalSource, AppPath: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite;
  Tool, Stamp, TemporaryDocx, TemporaryText, TemporaryStamp, Dependency,
  DocxName, TextName, Prepared, Warning: string;
  Attributes: TWin32FileAttributeData;
  CheckCanceled: TProc;
  procedure AddStamp(const FileName: string);
  begin
    Stamp:=Stamp+'|'+FileName+'|';
    if GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then
      Stamp:=Stamp+IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
        IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  end;
  function Reuse(const Name: string): Boolean;
  var StoredStamp: string;
  begin
    Result:=False;
    if not FileExists(Name) or not FileExists(Name+'.source') then Exit;
    try
      StoredStamp:=TFile.ReadAllText(Name+'.source',TEncoding.UTF8);
    except
      on E: EInOutError do Exit;
      on E: EStreamError do Exit;
    end;
    if StoredStamp=Stamp+'|approximate' then Warning:=ApproximateDOCWarning
    else if StoredStamp=Stamp+'|text' then Warning:=TextOnlyDOCWarning
    else if StoredStamp<>Stamp then Exit;
    RegisterBookCacheFile(Name,OriginalSource);
    if Assigned(OnStage) then
      if Warning<>'' then OnStage(Warning)
      else OnStage('Открытие DOC из кэша…');
    Result:=True;
  end;
begin
  Result:=SourceFile; if not IsDirectDOCFormat(ExtractFileExt(SourceFile)) then Exit;
  CheckCanceled:=procedure
  begin
    if (Assigned(IsCanceled) and IsCanceled()) or
      ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated) then Abort;
  end;
  CheckCanceled;
  Tool:=FindDirectDOCReader;
  if Tool='' then raise EMHLComponentRequired.Create('DocSharp','Для этой книги нужен модуль DocSharp.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    if (Input.Size<512) or (Input.Size>64*1024*1024) then
      raise Exception.Create('Размер DOC превышает предел читалки (64 МБ) или файл неполный.');
    Stamp:=DOCStampVersion+BookCacheInputStamp(SourceFile,OriginalSource); AddStamp(Tool);
    for Dependency in ['DocSharp.Binary.Doc.dll','DocSharp.Binary.Common.dll'] do
      AddStamp(TPath.Combine(ExtractFilePath(Tool),Dependency));
    AddStamp(TPath.Combine(AppPath,LEGACY_DOC_RICH_WORKER));
    AddStamp(TPath.Combine(AppPath,LEGACY_DOC_WORKER));
    var CacheBase:=TPath.Combine(BookCachePath,'homelib-doc-'+Copy(THashSHA2.GetHashString(SourceFile),1,32));
    DocxName:=ExistingBookCacheFile(CacheBase+'.docx');
    TextName:=ExistingBookCacheFile(CacheBase+'.txt');
    Warning:='';
    if Reuse(DocxName) then Exit(DocxName);
    if Reuse(TextName) then Exit(TextName);
    if Assigned(OnStage) then OnStage('Открытие текста и изображений DOC…');
    ForceDirectories(ExtractFileDir(DocxName));
    ForceDirectories(ExtractFileDir(TextName));
    Writer:=TBookCacheWrite.Create(OriginalSource);
    try
      TemporaryDocx:=Writer.TemporaryName(DocxName);
      TemporaryText:=Writer.TemporaryName(TextName);
      Prepared:=PrepareBinaryDOC(SourceFile,TemporaryDocx,TemporaryText,AppPath,CheckCanceled,Warning);
      Result:=DocxName;
      if Prepared=TemporaryText then
      begin
        Result:=TextName;
        Stamp:=Stamp+'|text';
      end
      else if Warning<>'' then Stamp:=Stamp+'|approximate';
      TemporaryStamp:=Writer.TemporaryName(Result+'.source');
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      CheckCanceled;
      Writer.Publish(Prepared,Result,TemporaryStamp);
      if (Warning<>'') and Assigned(OnStage) then OnStage(Warning);
    finally Writer.Free; end;
  finally Input.Free; end;
end;

end.
