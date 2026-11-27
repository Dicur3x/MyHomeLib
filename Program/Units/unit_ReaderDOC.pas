unit unit_ReaderDOC;

interface

uses System.SysUtils;

function IsDirectDOCFormat(const Extension: string): Boolean;
function FindDirectDOCReader: string;
function TryRasterizeOfficeWMF(const Input: TBytes; const Canceled: TFunc<Boolean>; out PNG: TBytes): Boolean;
function RenderWordDrawingBatch(const Tool: string; const Request: TBytes; Count: Integer;
  const Canceled: TFunc<Boolean>; TimeoutMs: UInt64 = 15000): TArray<TBytes>;
function PreparedDOCWarning(const FileName: string): string;
function PrepareBinaryDOC(const SourceFile, DocxName, TextName, AppPath: string;
  const CheckCanceled: TProc; out Warning: string; out Partial: Boolean): string;
function PrepareDirectDOC(const SourceFile, OriginalSource, AppPath: string;
  const OnStage: TProc<string> = nil; const IsCanceled: TFunc<Boolean> = nil): string;

implementation

uses System.Classes, System.IOUtils, System.Hash, System.Zip, System.Win.Registry,
  Winapi.Windows, System.RegularExpressions, unit_BookCache, unit_MHLExternalTools, unit_FormatComponents,
  unit_Diagnostics;

const
  DOCStampVersion = 'doc-reflow-v3|';
  ApproximateDOCWarning = 'Некоторые элементы оформления старого DOC могли не перенестись.';
  DOCNoteLayoutWarning = 'Не удалось восстановить все связи сносок DOC. Номера и текст отдельных сносок могут не совпадать.';
  TextOnlyDOCWarning = 'Из DOC формата Word 6/95 извлечён только текст. Оформление и изображения не перенесены.';
  RecoveredDOCWarning = 'В повреждённом DOC сохранился текст. Оформление и данные отмеченных объектов недоступны.';

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

function TryRasterizeOfficeWMF(const Input: TBytes; const Canceled: TFunc<Boolean>; out PNG: TBytes): Boolean;
const MaxImageBytes = 16*1024*1024;
var Tool, Work, Source, Destination: string; Started: UInt64; Log: TMemoryStream;
begin
  Result:=False; PNG:=nil;
  // Match the standard, non-placeable WMF header used by embedded Word images.
  if (Length(Input)<18) or (Length(Input)>MaxImageBytes) or not (Input[0] in [1,2]) or
    (Input[1]<>0) or (Input[2]<>9) or (Input[3]<>0) or (Input[4]<>0) or
    not (Input[5] in [1,3]) then Exit;
  Tool:=FindDirectDOCReader;
  if Tool='' then Exit;
  Work:=TPath.Combine(TPath.GetTempPath,'HomeLibre-wmf-'+TGUID.NewGuid.ToString);
  TDirectory.CreateDirectory(Work);
  Source:=TPath.Combine(Work,'picture.wmf');
  Destination:=TPath.Combine(Work,'picture.png');
  Log:=nil;
  try
    Log:=TMemoryStream.Create;
    TFile.WriteAllBytes(Source,Input);
    Started:=GetTickCount64;
    try
      RunExternalToolToStream(Tool,['--image-to-png',Source,Destination],Log,
        function: Boolean
        begin
          if Assigned(Canceled) and Canceled() then
            raise EAbort.Create('Чтение отменено.');
          if GetTickCount64-Started>15000 then
            raise EDOCReadTimeout.Create('Превышено время чтения рисунка Word.');
          Result:=False;
        end,0,True,128*1024*1024);
    except
      on E: EMHLExternalToolError do Exit;
      on E: EDOCReadTimeout do Exit;
    end;
    if FileExists(Destination) and (TFile.GetSize(Destination)<=MaxImageBytes) then
    begin
      PNG:=TFile.ReadAllBytes(Destination);
      Result:=Length(PNG)>0;
    end;
  finally
    Log.Free;
    System.SysUtils.DeleteFile(Destination);
    System.SysUtils.DeleteFile(Source);
    Winapi.Windows.RemoveDirectory(PChar(Work));
  end;
end;

function RenderWordDrawingBatch(const Tool: string; const Request: TBytes; Count: Integer;
  const Canceled: TFunc<Boolean>; TimeoutMs: UInt64): TArray<TBytes>;
const MaxImage = 16*1024*1024; MaxBatch = 64*1024*1024;
var Work, Source, Destination: string; Started: UInt64; Log: TMemoryStream;
  Pictures: TZipFile; Index, Entry: Integer; Remaining, Size: Int64;
  procedure CheckCanceled;
  begin
    if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
  end;
begin
  Result:=nil;
  if (Length(Request)=0) or (Length(Request)>MaxImage) or (Count<1) or (Count>128) then Exit;
  CheckCanceled;
  Work:=TPath.Combine(TPath.GetTempPath,'HomeLibre-word-drawings-'+TGUID.NewGuid.ToString);
  Source:=TPath.Combine(Work,'drawings.xml'); Destination:=TPath.Combine(Work,'pictures.zip');
  Log:=nil; Pictures:=nil;
  try
    try
      TDirectory.CreateDirectory(Work);
      Log:=TMemoryStream.Create;
      TFile.WriteAllBytes(Source,Request);
      Started:=GetTickCount64;
      RunExternalToolToStream(Tool,['--drawingml-to-png-batch',Source,Destination],Log,
        function: Boolean
        begin
          if Assigned(Canceled) and Canceled() then raise EAbort.Create('Чтение отменено.');
          if GetTickCount64-Started>TimeoutMs then
            raise EDOCReadTimeout.Create('Превышено время чтения рисунков Word.');
          Result:=False;
        end,0,True,256*1024*1024);
      if not FileExists(Destination) or (TFile.GetSize(Destination)>MaxBatch+64*1024) then Exit;
      Pictures:=TZipFile.Create;
      Pictures.Open(Destination,zmRead);
      if Pictures.FileCount>Count then Exit;
      SetLength(Result,Count);
      Remaining:=MaxBatch;
      for Index:=0 to Count-1 do
      begin
        CheckCanceled;
        Entry:=Pictures.IndexOf(IntToStr(Index)+'.png');
        if Entry<0 then Continue;
        Size:=Pictures.FileInfo[Entry].UncompressedSize;
        if (Size<1) or (Size>MaxImage) or (Size>Remaining) then Continue;
        Pictures.Read(Entry,Result[Index]);
        Dec(Remaining,Size);
      end;
    except
      on E: EAbort do raise;
      on E: Exception do
      begin
        LogDiagnosticTrace('word-drawings',E.Message,'DOCX');
        Result:=nil;
      end;
    end;
  finally
    Pictures.Free; Log.Free;
    System.SysUtils.DeleteFile(Destination);
    System.SysUtils.DeleteFile(Source);
    Winapi.Windows.RemoveDirectory(PChar(Work));
  end;
end;

function RecoverDamagedDOCText(const SourceFile, TextName: string; const CheckCanceled: TProc;
  out Warning: string): Boolean;
const
  PageField = '(?m)^\x13PAGE[ \t]*';
  PageFieldEnd = '\x15(?=\r?$)';
  PageWithValue = PageField+'\x14([0-9]+)'+PageFieldEnd;
  PageWithoutValue = PageField+PageFieldEnd;
  CommonWords = '(?i)(?<![а-яё])(?:что|для|было|если|только|можно|этот|после|перед|себя|через)(?![а-яё])';
  ObjectMarker = '\x01+';
  UnknownControl = '[\x00-\x08\x0B\x0E-\x1F\x7F-\x9F]';
var Bytes: TBytes; Text: string; Encoding: TEncoding;
  ControlCount, ObjectCount, UnknownCount, MissingPageNumbers: Integer;
begin
  Result:=False;
  if TFile.GetSize(SourceFile)>4*1024*1024 then Exit;
  CheckCanceled;
  Bytes:=TFile.ReadAllBytes(SourceFile);
  if (Length(Bytes)<512) or ((Bytes[0]=$D0) and (Bytes[1]=$CF)) or
    ((Bytes[0]=$DB) and (Bytes[1]=$A5)) then Exit;
  Encoding:=TEncoding.GetEncoding(1251);
  try Text:=Encoding.GetString(Bytes);
  finally Encoding.Free; end;
  // A recovered Word text stream has ordinary paragraph text and sole-line
  // PAGE fields. Reject general binary files and ambiguous legacy encodings.
  MissingPageNumbers:=TRegEx.Matches(Text,PageWithoutValue).Count;
  if ((MissingPageNumbers=0) and not TRegEx.IsMatch(Text,PageWithValue)) or
    (TRegEx.Matches(Copy(Text,1,65536),CommonWords).Count<8) then Exit;
  ControlCount:=TRegEx.Matches(Text,UnknownControl).Count;
  if (ControlCount>Length(Text) div 200) or (ControlCount>4096) then Exit;
  Text:=TRegEx.Replace(Text,PageWithValue,'$1');
  Text:=TRegEx.Replace(Text,PageWithoutValue,'[Номер страницы недоступен]');
  ObjectCount:=TRegEx.Matches(Text,ObjectMarker).Count;
  Text:=TRegEx.Replace(Text,ObjectMarker,'[Данные объекта недоступны]');
  UnknownCount:=TRegEx.Matches(Text,UnknownControl).Count;
  Text:=TRegEx.Replace(Text,UnknownControl,#$FFFD);
  CheckCanceled;
  TFile.WriteAllText(TextName,Text,TEncoding.UTF8);
  Warning:=RecoveredDOCWarning;
  if ObjectCount>0 then Warning:=Warning+sLineBreak+'Места недоступных объектов отмечены в тексте ('+IntToStr(ObjectCount)+').';
  if UnknownCount>0 then Warning:=Warning+sLineBreak+'Неизвестные служебные знаки заменены на � ('+IntToStr(UnknownCount)+').';
  if MissingPageNumbers>0 then Warning:=Warning+sLineBreak+'Поля без номера страницы отмечены в тексте ('+IntToStr(MissingPageNumbers)+').';
  Result:=True;
end;

function PrepareBinaryDOC(const SourceFile, DocxName, TextName, AppPath: string;
  const CheckCanceled: TProc; out Warning: string; out Partial: Boolean): string;
var Tool, RichTool, TextTool: string; Log: TStringStream; Legacy: Boolean;
  WorkerTimeout: UInt64; WorkerMemory: NativeUInt;
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
          if GetTickCount64-Started>WorkerTimeout then
            raise EDOCReadTimeout.CreateFmt('Чтение DOC превысило %d секунд.',[WorkerTimeout div 1000]);
          Result:=False;
        end,0,True,WorkerMemory);
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
  Warning:=''; Partial:=False;
  WorkerTimeout:=30000; WorkerMemory:=384*1024*1024;
  if TFile.GetSize(SourceFile)>2*1024*1024 then
  begin
    WorkerTimeout:=120000;
    WorkerMemory:=768*1024*1024;
  end;
  Tool:=FindDirectDOCReader;
  if Tool='' then raise EMHLComponentRequired.Create('DocSharp','Для этого DOC нужен компонент DocSharp.');
  Log:=TStringStream.Create('',TEncoding.UTF8);
  try
    if RunWorker(Tool,DocxName) and ValidDocx then
    begin
      Partial:=Log.DataString.Contains('NOTE_LAYOUT ');
      if Partial then Warning:=DOCNoteLayoutWarning;
      Exit(DocxName);
    end;
    CheckPassword;
    Legacy:=Log.DataString.Contains('ERROR OLD');
    if not Legacy and RecoverDamagedDOCText(SourceFile,TextName,CheckCanceled,Warning) then
    begin
      Partial:=True;
      Exit(TextName);
    end;
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
        var Losses:=TRegEx.Match(Log.DataString,'DOC DROPPED (\d+) (\d+) (\d+)');
        if Losses.Success then
        begin
          Partial:=True;
          Warning:='Из DOC можно сохранить доступное содержимое. Часть объектов не читается.';
          if Losses.Groups[1].Value<>'0' then Warning:=Warning+sLineBreak+'Формул: '+Losses.Groups[1].Value+'.';
          if Losses.Groups[2].Value<>'0' then Warning:=Warning+sLineBreak+'Иллюстраций: '+Losses.Groups[2].Value+'.';
          if Losses.Groups[3].Value<>'0' then Warning:=Warning+sLineBreak+'Других элементов: '+Losses.Groups[3].Value+'.';
        end;
        var Drawings:=TRegEx.Match(Log.DataString,'DOC RASTERIZED ([1-9]\d*)');
        if Drawings.Success then
        begin
          Partial:=True;
          if Warning<>'' then Warning:=Warning+sLineBreak;
          Warning:=Warning+'Схемы и фигуры DOC сохранены как изображения ('+Drawings.Groups[1].Value+
            '). Их расположение может отличаться.';
          var Incomplete:=TRegEx.Match(Log.DataString,'DOC RASTERIZED_PARTIAL ([1-9]\d*)');
          if Incomplete.Success then Warning:=Warning+sLineBreak+
            'Схем с неполным изображением: '+Incomplete.Groups[1].Value+'.';
        end;
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
    Partial:=True;
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
  if Stamp.EndsWith('|recovered-text') then Result:='Восстановлен доступный текст DOC'
  else if Stamp.EndsWith('|text') then Result:='Открыт только текст DOC'
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
    else if StoredStamp=Stamp+'|notes' then Warning:=DOCNoteLayoutWarning
    else if StoredStamp=Stamp+'|recovered-text' then Warning:=RecoveredDOCWarning
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
      var Partial: Boolean;
      Prepared:=PrepareBinaryDOC(SourceFile,TemporaryDocx,TemporaryText,AppPath,CheckCanceled,Warning,Partial);
      Result:=DocxName;
      if Prepared=TemporaryText then
      begin
        Result:=TextName;
        if Warning.StartsWith(RecoveredDOCWarning) then Stamp:=Stamp+'|recovered-text'
        else Stamp:=Stamp+'|text';
      end
      else if Warning=DOCNoteLayoutWarning then Stamp:=Stamp+'|notes'
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
