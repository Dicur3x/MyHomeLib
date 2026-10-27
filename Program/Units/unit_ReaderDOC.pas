unit unit_ReaderDOC;

interface

uses System.SysUtils;

function IsDirectDOCFormat(const Extension: string): Boolean;
function FindDirectDOCReader: string;
function PrepareDirectDOC(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, System.Win.Registry,
  Winapi.Windows, unit_BookCache, unit_MHLExternalTools;

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

function PrepareDirectDOC(const SourceFile, OriginalSource: string;
  const OnStage: TProc<string>; const IsCanceled: TFunc<Boolean>): string;
var Input: TStream; Writer: TBookCacheWrite; Log: TStringStream; Zip: TZipFile;
  Tool, Stamp, StampFile, Temporary, TemporaryStamp, Dependency: string;
  Attributes: TWin32FileAttributeData; Started: UInt64;
  procedure CheckCanceled;
  begin
    if (Assigned(IsCanceled) and IsCanceled()) or
      ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated) then Abort;
  end;
  procedure AddStamp(const FileName: string);
  begin
    if not GetFileAttributesEx(PChar(FileName),GetFileExInfoStandard,@Attributes) then RaiseLastOSError;
    Stamp:=Stamp+'|'+FileName+'|'+IntToStr(Attributes.nFileSizeHigh)+':'+IntToStr(Attributes.nFileSizeLow)+'|'+
      IntToStr(Attributes.ftLastWriteTime.dwHighDateTime)+':'+IntToStr(Attributes.ftLastWriteTime.dwLowDateTime);
  end;
begin
  Result:=SourceFile; if not IsDirectDOCFormat(ExtractFileExt(SourceFile)) then Exit;
  CheckCanceled; Tool:=FindDirectDOCReader;
  if Tool='' then raise EMHLComponentRequired.Create('DocSharp','Для этой книги нужен модуль DocSharp.');
  Input:=OpenCachedBookFile(SourceFile);
  try
    if (Input.Size<512) or (Input.Size>64*1024*1024) then
      raise Exception.Create('Размер DOC превышает предел читалки (64 МБ) или файл неполный.');
    Stamp:='doc-reflow-v2|'+BookCacheInputStamp(SourceFile,OriginalSource); AddStamp(Tool);
    for Dependency in ['DocSharp.Binary.Doc.dll','DocSharp.Binary.Common.dll'] do
      AddStamp(TPath.Combine(ExtractFilePath(Tool),Dependency));
    Result:=ExistingBookCacheFile(TPath.Combine(BookCachePath,
      'homelib-doc-'+Copy(THashSHA2.GetHashString(SourceFile),1,32)+'.docx'));
    StampFile:=Result+'.source';
    if FileExists(Result) and FileExists(StampFile) then
      try
        if TFile.ReadAllText(StampFile,TEncoding.UTF8)=Stamp then
        begin RegisterBookCacheFile(Result,OriginalSource); if Assigned(OnStage) then OnStage('Открытие DOC из кэша…'); Exit; end;
      except end;
    if Assigned(OnStage) then OnStage('Открытие текста и изображений DOC…');
    ForceDirectories(ExtractFileDir(Result));
    Writer:=TBookCacheWrite.Create(OriginalSource); Log:=TStringStream.Create('',TEncoding.UTF8);
    try
      Temporary:=Writer.TemporaryName(Result); TemporaryStamp:=Writer.TemporaryName(StampFile);
      Started:=GetTickCount64;
      try RunExternalToolToStream(Tool,[TPath.GetFullPath(SourceFile),TPath.GetFullPath(Temporary)],Log,
        function: Boolean
        begin
          if (Assigned(IsCanceled) and IsCanceled()) or
            ((GetCurrentThreadID<>MainThreadID) and TThread.CheckTerminated) then Abort;
          Result:=False;
          if GetTickCount64-Started>30000 then raise Exception.Create('Чтение DOC превысило 30 секунд. Можно отменить и открыть книгу внешней программой.');
        end,0,True,384*1024*1024);
      except
        on E: EMHLExternalToolError do
        begin
          if Log.DataString.Contains('ERROR PASSWORD') then
            raise Exception.Create('Этот DOC защищён паролем. Откройте его внешней программой.')
          else if Log.DataString.Contains('ERROR OLD') then
            raise Exception.Create('Этот DOC создан в Word 95 или более старой версии. Пока откройте его внешней программой.')
          else raise Exception.Create('Не удалось прочитать DOC. Возможно, он повреждён или использует неподдерживаемый вариант формата.');
        end;
      end;
      CheckCanceled;
      Zip:=TZipFile.Create;
      try
        Zip.Open(Temporary,zmRead);
        if (Zip.IndexOf('word/document.xml')<0) or (Zip.IndexOf('[Content_Types].xml')<0) then
          raise Exception.Create('Не удалось подготовить текст DOC для чтения.');
      finally Zip.Free; end;
      TFile.WriteAllText(TemporaryStamp,Stamp,TEncoding.UTF8);
      CheckCanceled; Writer.Publish(Temporary,Result,TemporaryStamp);
    finally Log.Free; Writer.Free; end;
  finally Input.Free; end;
end;

end.
