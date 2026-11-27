unit unit_BookConversion;

interface

uses System.SysUtils, System.Classes;

const
  BOOK_QUALITY_MAXIMUM = 3;
  BOOK_QUALITY_NONE = 4;
  MAX_PDF_CONVERSION_SOURCE = 512*1024*1024;
  MAX_RTF_CONVERSION_SOURCE = 256*1024*1024;
  MAX_JPEG_CONVERSION_SOURCE = 255*1024*1024;
  MAX_LARGE_FB2_CONVERSION_SOURCE = 512*1024*1024;
  MAX_CHM_CONVERSION_SOURCE = 256*1024*1024;
  BOOK_IMAGE_PROFILES: array[0..BOOK_QUALITY_NONE] of string =
    ('original','balanced','economy','maximum','none');
  BOOK_IMAGE_PROFILE_CAPTIONS: array[0..BOOK_QUALITY_NONE] of string =
    ('Без уменьшения качества','Сбалансированный','Экономный','Максимальная экономия','Без изображений');

type
  EBookPartialExportDeclined = class(EAbort);
  TBookConversionProgress = reference to procedure(Percent, Completed, Total: Integer; const Stage: string);
  TBookImageQualityOptions = record
    HighBytes, BalancedBytes, EconomyBytes, NoImagesBytes: Int64;
    SplitHighBytes, SplitBalancedBytes, SplitEconomyBytes: Int64;
    AutoHighBytes, AutoBalancedBytes, AutoEconomyBytes: Int64;
    ImageCount, SampleCount: Integer;
    TargetFormat: string;
    ScanPages, FirstSamples, AllScanPages, DistributedSamples: Boolean;
    // Layout: keep / split / auto. Columns follow BOOK_IMAGE_PROFILES.
    OutputBytes, ZipOutputBytes: array[0..2,0..BOOK_QUALITY_NONE] of Int64;
    MarginBytes, ZipMarginBytes: array[0..2,0..BOOK_QUALITY_NONE] of Int64;
  end;
  TBookImageQualityChooser = reference to function(const Options: TBookImageQualityOptions): string;

// Source streams remain owned by the caller. Output is published only after a
// complete conversion; replacing a saved copy requires explicit consent and
// never permits replacing the source book, including another hard-link name.
function IsBasicConversionSource(const Extension: string): Boolean;
function IsValidScanPageExclusions(const Value: string): Boolean;
function TryReadBookImageQualityOptions(const FileName: string; out Options: TBookImageQualityOptions): Boolean;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean> = nil; const Title: string = '';
  const Author: string = ''; const Language: string = ''; const ForReading: Boolean = False;
  const OnProgress: TBookConversionProgress = nil;
  const ImageQuality: string = 'original'; const ChooseImageQuality: TBookImageQualityChooser = nil;
  const OverwriteExisting: Boolean = False; const ProtectedSourceFile: string = '';
  const PackedOutput: Boolean = False; const OutputProfile: string = '';
  const ExtractTextLayer: Boolean = False; const Grayscale: Boolean = False;
  const MeasureScans: Boolean = False; const SkipDamagedFB2Image: Boolean = False;
  const ConfirmDamagedContent: TFunc<string,Boolean> = nil);

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, unit_MHLExternalTools, unit_ReaderDOC, unit_ReaderFormats, unit_ReaderDocument, unit_FormatComponents, unit_BookConversionRequirements, unit_BookOutput, unit_Diagnostics, unit_ComponentUsage;

const
  MAX_BASIC_CONVERSION_SOURCE = 64*1024*1024;
  MAX_PACKAGED_CONVERSION_SOURCE = 256*1024*1024;

procedure DeleteConversionWork(const Work, TempRoot: string);
begin
  if not Work.StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(TempRoot)),True) then Exit;
  // Closing the converter job requests termination of its children. Windows
  // can still be releasing their file handles when the caller reaches here.
  var Deadline:=GetTickCount64+2000;
  while DirectoryExists(Work) and
    (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) do
  begin
    try
      TDirectory.Delete(Work,True);
    except
      on E: EInOutError do
        if GetTickCount64>=Deadline then LogDiagnosticError('conversion.cleanup',E);
      on E: EOSError do
        if GetTickCount64>=Deadline then LogDiagnosticError('conversion.cleanup',E);
    end;
    if not DirectoryExists(Work) then Exit;
    if GetTickCount64>=Deadline then
    begin
      LogDiagnosticMessage('conversion.cleanup','Не удалось удалить временные файлы конвертации.');
      Exit;
    end;
    Sleep(25);
  end;
end;

procedure RecordReportedTools(Report: TJSONValue);
var Tools: TJSONValue;
begin
  if not (Report is TJSONObject) then Exit;
  Tools:=TJSONObject(Report).GetValue('used_tools');
  if not (Tools is TJSONArray) or (TJSONArray(Tools).Count>32) then Exit;
  for var Value in TJSONArray(Tools) do
    if Value is TJSONString then RecordComponentToolUse(Value.Value);
end;

function CopyUnchangedBook(const SourceFile, SourceExtension, TargetFile: string;
  Source: TStream; const IsCanceled: TFunc<Boolean>; OverwriteExisting: Boolean;
  const ProtectedSourceFile: string; SkipDamagedFB2Image: Boolean): Boolean;
var Input: TStream; Writer: TFileStream; SavedPosition: Int64;
  Temporary: string; Buffer: TBytes; Count: Integer;
begin
  Result:=False;
  if not SameText(SourceExtension,ExtractFileExt(TargetFile)) or
    not ((SourceExtension='.fb2') or (SourceExtension='.epub')) or
    not FileExists(SourceFile) or not SameText(DetectReaderExtension(SourceFile),SourceExtension) then Exit;
  if Assigned(IsCanceled) and IsCanceled() then Abort;
  Input:=Source;
  if not Assigned(Input) then Input:=TFileStream.Create(SourceFile,fmOpenRead or fmShareDenyWrite);
  SavedPosition:=Input.Position;
  Temporary:='';
  try
    Temporary:=CreateBookOutputStage(TargetFile);
    Input.Position:=0; SetLength(Buffer,256*1024);
    Writer:=TFileStream.Create(Temporary,fmCreate);
    try
      repeat
        if Assigned(IsCanceled) and IsCanceled() then Abort;
        Count:=Input.Read(Buffer[0],Length(Buffer));
        if Count>0 then Writer.WriteBuffer(Buffer[0],Count);
      until Count=0;
      if Writer.Size=0 then raise EReadError.Create('Исходная книга пуста.');
      if not FlushFileBuffers(Writer.Handle) then RaiseLastOSError;
    finally Writer.Free; end;
    if (SourceExtension='.fb2') and not ValidFB2Copy(Temporary,IsCanceled) then
    begin
      if SkipDamagedFB2Image then Exit;
      raise Exception.Create('Исходный FB2 повреждён или не содержит тела книги.');
    end;
    if (SourceExtension='.epub') and not ReaderHasCompleteEpubSpine(Temporary,IsCanceled) then Exit;
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    PublishBookOutput(Temporary,TargetFile,OverwriteExisting,ProtectedSourceFile);
    Temporary:=''; Result:=True;
  finally
    if Assigned(Source) then Input.Position:=SavedPosition else Input.Free;
    DeleteBookOutputStage(Temporary);
  end;
end;


function IsValidScanPageExclusions(const Value: string): Boolean;
var Parts: TArray<string>; First, Last: Integer;
begin
  Result:=False; if Value.Length>256 then Exit;
  if Value.Trim='' then Exit(True);
  for var Item in Value.Split([',']) do
  begin
    Parts:=Item.Trim.Split(['-']);
    for var Part in Parts do for var Ch in Part.Trim do if not CharInSet(Ch,['0'..'9']) then Exit;
    if (Length(Parts)<1) or (Length(Parts)>2) or not TryStrToInt(Parts[0].Trim,First) or (First<1) or (First>5000) then Exit;
    Last:=First;
    if (Length(Parts)=2) and (not TryStrToInt(Parts[1].Trim,Last) or (Last<First) or (Last>5000)) then Exit;
  end;
  Result:=True;
end;

function IsBasicConversionSource(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension).TrimLeft(['.'])+'|',
    '|fb2|epub|fb3|txt|text|faq|html|htm|xhtml|shtml|rtf|docx|odt|doc|dot|docm|dotx|dotm|ott|wps|wpd|ppt|pps|pot|pptx|pptm|ppsx|ppsm|potx|potm|xls|xlt|xlsx|xlsm|xltx|xltm|ods|ots|odp|otp|md|markdown|mobi|azw|azw3|prc|mht|mhtml|wri|pdb|ibk|rgo|jutoh|pages|cr3|b1|tcr|chm|lit|lrf|rb|abw|sxw|ha|xps|oxps|jpg|jpeg|png|gif|bmp|tif|tiff|webp|cbz|cbr|cb7|pdf|djvu|djv|dju|djm|djvm|')>0;
end;

// False means the atomically published snapshot is temporarily unavailable.
// A complete but invalid snapshot raises; retries never extend the idle limit.
function TryReadBookImageQualityOptions(const FileName: string; out Options: TBookImageQualityOptions): Boolean;
const LayoutKeys: array[0..2] of string = ('sizes','split_sizes','auto_sizes');
  MarginKeys: array[0..2] of string = ('keep','split','auto');
var Handle: THandle; Size: Int64; Data: TBytes; ReadCount, ErrorCode: DWORD;
  Choices: TJSONValue; Text: string;
begin
  Result:=False; Options:=Default(TBookImageQualityOptions);
  Handle:=CreateFile(PChar(FileName),GENERIC_READ,FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
  if Handle=INVALID_HANDLE_VALUE then
  begin
    ErrorCode:=GetLastError;
    if ErrorCode in [ERROR_FILE_NOT_FOUND,ERROR_PATH_NOT_FOUND,ERROR_SHARING_VIOLATION,ERROR_LOCK_VIOLATION] then Exit;
    RaiseLastOSError(ErrorCode);
  end;
  try
    if not GetFileSizeEx(Handle,Size) then RaiseLastOSError;
    if Size>4096 then raise Exception.Create('Слишком большой отчёт оценки размера.');
    if Size<=0 then raise Exception.Create('Пустая оценка размера книги.');
    SetLength(Data,Integer(Size));
    if not ReadFile(Handle,Data[0],Length(Data),ReadCount,nil) then
    begin
      ErrorCode:=GetLastError;
      if ErrorCode in [ERROR_SHARING_VIOLATION,ERROR_LOCK_VIOLATION] then Exit;
      RaiseLastOSError(ErrorCode);
    end;
    if ReadCount<>Length(Data) then raise Exception.Create('Неполная оценка размера книги.');
  finally CloseHandle(Handle); end;
  Text:=TEncoding.UTF8.GetString(Data);
  if (Text<>'') and (Text[1]=#$FEFF) then Delete(Text,1,1);
  Choices:=TJSONObject.ParseJSONValue(Text);
  try
    Options:=Default(TBookImageQualityOptions);
    if not (Choices is TJSONObject) or
      not Choices.TryGetValue<Int64>('sizes.high',Options.HighBytes) or
      not Choices.TryGetValue<Int64>('sizes.balanced',Options.BalancedBytes) or
      not Choices.TryGetValue<Int64>('sizes.economy',Options.EconomyBytes) or
      not Choices.TryGetValue<Integer>('images',Options.ImageCount) or
      not Choices.TryGetValue<Integer>('sampled',Options.SampleCount) or
      not Choices.TryGetValue<string>('format',Options.TargetFormat) or
      (Options.HighBytes<=0) or (Options.BalancedBytes<=0) or (Options.EconomyBytes<=0) or
      (Options.ImageCount<=0) or (Options.ImageCount>5000) or
      (Options.SampleCount<0) or (Options.SampleCount>Options.ImageCount) then
      raise Exception.Create('Некорректная оценка размера книги.');
    Choices.TryGetValue<Int64>('sizes.none',Options.NoImagesBytes);
    if Options.NoImagesBytes<0 then raise Exception.Create('Некорректная оценка размера без изображений.');
    Choices.TryGetValue<Boolean>('scan_pages',Options.ScanPages);
    Choices.TryGetValue<Boolean>('first_samples',Options.FirstSamples);
    Choices.TryGetValue<Boolean>('all_scan_pages',Options.AllScanPages);
    Choices.TryGetValue<Boolean>('distributed_samples',Options.DistributedSamples);
    if (Options.AllScanPages and (not Options.ScanPages or (Options.SampleCount<>Options.ImageCount))) or
      (Options.DistributedSamples and (not Options.ScanPages or Options.AllScanPages or Options.FirstSamples or
        (Options.SampleCount<=0) or (Options.SampleCount>=Options.ImageCount) or (Options.SampleCount>18))) or
      (not (Options.AllScanPages or Options.DistributedSamples) and (Options.SampleCount>9)) then
      raise Exception.Create('Некорректное число проверенных страниц.');
    if Options.ScanPages and
      (not Choices.TryGetValue<Int64>('split_sizes.high',Options.SplitHighBytes) or
       not Choices.TryGetValue<Int64>('split_sizes.balanced',Options.SplitBalancedBytes) or
       not Choices.TryGetValue<Int64>('split_sizes.economy',Options.SplitEconomyBytes) or
       (Options.SplitHighBytes<=0) or (Options.SplitBalancedBytes<=0) or (Options.SplitEconomyBytes<=0)) then
      raise Exception.Create('Некорректная оценка разделения разворотов.');
    if Options.ScanPages and
      (not Choices.TryGetValue<Int64>('auto_sizes.high',Options.AutoHighBytes) or
       not Choices.TryGetValue<Int64>('auto_sizes.balanced',Options.AutoBalancedBytes) or
       not Choices.TryGetValue<Int64>('auto_sizes.economy',Options.AutoEconomyBytes) or
       (Options.AutoHighBytes<=0) or (Options.AutoBalancedBytes<=0) or (Options.AutoEconomyBytes<=0)) then
      raise Exception.Create('Некорректная оценка автоматического разделения разворотов.');
    for var Layout:=0 to 2 do for var Quality:=0 to High(BOOK_IMAGE_PROFILES) do
    begin
      Choices.TryGetValue<Int64>(LayoutKeys[Layout]+'.'+BOOK_IMAGE_PROFILES[Quality],Options.OutputBytes[Layout,Quality]);
      Choices.TryGetValue<Int64>('zip_'+LayoutKeys[Layout]+'.'+BOOK_IMAGE_PROFILES[Quality],Options.ZipOutputBytes[Layout,Quality]);
      if (Options.OutputBytes[Layout,Quality]<0) or (Options.ZipOutputBytes[Layout,Quality]<0) then
        raise Exception.Create('Некорректная оценка размера копии книги.');
      if Options.DistributedSamples then
      begin
        Choices.TryGetValue<Int64>('margins.'+MarginKeys[Layout]+'.'+BOOK_IMAGE_PROFILES[Quality],Options.MarginBytes[Layout,Quality]);
        Choices.TryGetValue<Int64>('zip_margins.'+MarginKeys[Layout]+'.'+BOOK_IMAGE_PROFILES[Quality],Options.ZipMarginBytes[Layout,Quality]);
        if (Options.MarginBytes[Layout,Quality]<0) or (Options.MarginBytes[Layout,Quality]>Options.OutputBytes[Layout,Quality]) or
          (Options.ZipMarginBytes[Layout,Quality]<0) or (Options.ZipMarginBytes[Layout,Quality]>Options.ZipOutputBytes[Layout,Quality]) then
          raise Exception.Create('Некорректный диапазон размера копии книги.');
      end;
    end;
    Result:=True;
  finally Choices.Free; end;
end;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean>; const Title, Author, Language: string; const ForReading: Boolean;
  const OnProgress: TBookConversionProgress; const ImageQuality: string;
  const ChooseImageQuality: TBookImageQualityChooser;
  const OverwriteExisting: Boolean; const ProtectedSourceFile: string; const PackedOutput: Boolean;
  const OutputProfile: string; const ExtractTextLayer, Grayscale, MeasureScans, SkipDamagedFB2Image: Boolean;
  const ConfirmDamagedContent: TFunc<string,Boolean>);
var Work, InputName, OutputName, ReportName, ProgressName, Tool, Script, TargetTemporary, LastDiagnosticStage: string;
  Input, Writer: TStream; SavedPosition: Int64; Log: TStringStream;
  Started, LastAdvance, LastPoll: UInt64; Report: TJSONValue; ArrayValue: TJSONValue; I: Integer;
  Extension, TargetExtension, Actual: string; Check, ReadProgress: TProc;
  Paged, Finalizing, ImageProcessing, StreamingScans, StreamingConversion, KindleWriting, TextLayerOnly: Boolean;
  PreparingWordNotes: Boolean;
  LastSequence, CompletedPages, PageTotal, LastPercent, RenderedPages, KindleCompleted: Integer;
  WrittenEpubResources, CheckedEpubResources, PreparedGifs, PreparedDocumentChunks, PreparedWordTotal: Integer;
  PreparedChmDocuments, WrittenFb2Resources, WrittenFb2Sections, CheckedFb2Sections: Integer;
  Header: TBytes; MaximumInput: Int64;
  ImageOptionsName, ImageChoiceName: string; ImageChoiceHandled: Boolean;
  EstimateCompleted, OptimizedCompleted: Integer;
  QualityProfile, ScanLayout, ScanExclude, DamageNotice: string;
  RecoverDamagedFB2: Boolean;

begin
  Extension:=LowerCase(SourceExtension); TargetExtension:=LowerCase(ExtractFileExt(TargetFile));
  RecoverDamagedFB2:=SkipDamagedFB2Image or Assigned(ConfirmDamagedContent);
  if OutputProfile<>'' then
  begin
    TargetExtension:=AdvancedBookOutputExtension(OutputProfile);
    if ForReading or PackedOutput or (TargetExtension='') or not TargetFile.EndsWith(TargetExtension,True) then
      raise Exception.Create('Имя файла не соответствует выбранному формату. Проверьте расширение файла.');
  end;
  var QualityParts:=ImageQuality.Split(['|']);
  QualityProfile:=QualityParts[0]; ScanLayout:='keep'; ScanExclude:='';
  if (Length(QualityParts)>1) and ((QualityParts[1]='split') or (QualityParts[1]='auto')) then ScanLayout:=QualityParts[1];
  if (Length(QualityParts)>2) and QualityParts[2].StartsWith('except=') then ScanExclude:=QualityParts[2].Substring(7);
  if not IsValidScanPageExclusions(ScanExclude) then raise Exception.Create('Укажите номера сканов через запятую, например 1, 98-100.');
  if (OutputProfile='') and not ((TargetExtension='.fb2') or (TargetExtension='.epub') or
    (TargetExtension='.mobi') or (TargetExtension='.azw3')) then
    raise Exception.Create('Этот формат пока не поддерживается конвертером FB2/EPUB. Сохраните книгу в исходном формате.');
  if BookOutputExists(TargetFile) and not OverwriteExisting then
    raise Exception.Create('Файл результата уже существует. Выберите другое имя.');
  var ProtectedSource:=ProtectedSourceFile; if ProtectedSource='' then ProtectedSource:=SourceFile;
  if OverwriteExisting and (SameBookOutputFile(TargetFile,SourceFile) or SameBookOutputFile(TargetFile,ProtectedSource)) then
    raise Exception.Create('Папка и имя результата совпадают с исходной книгой. Выберите другую папку или маску имени.');
  if Assigned(Warnings) then Warnings.Clear;
  if (OutputProfile='') and not ForReading and not Grayscale and (QualityProfile='original') and (ScanLayout='keep') and
    CopyUnchangedBook(SourceFile,Extension,TargetFile,Source,IsCanceled,OverwriteExisting,ProtectedSource,
      RecoverDamagedFB2) then
  begin
    if Assigned(OnProgress) then OnProgress(100,0,0,'complete');
    Exit;
  end;
  TextLayerOnly:=False;
  if not ForReading and (QualityProfile='none') then
  begin
    Actual:=Extension;
    if FileExists(SourceFile) then
    begin
      var Detected:=DetectReaderExtension(SourceFile);
      if Detected<>'' then Actual:=Detected;
    end;
    TextLayerOnly:=ExtractTextLayer and (TargetExtension='.fb2') and
      (Pos('|'+Actual.TrimLeft(['.'])+'|','|pdf|djvu|djv|dju|djm|djvm|')>0);
    if not TextLayerOnly and
      (Pos('|'+Actual.TrimLeft(['.'])+'|','|pdf|djvu|djv|dju|djm|djvm|tif|tiff|cbz|cbr|cb7|jpg|jpeg|png|gif|bmp|webp|xps|oxps|')>0) then
    begin
      if ExtractTextLayer then
        raise Exception.Create('TXT сохраняет только текст. Выберите FB2 или EPUB, чтобы сохранить страницы как изображения.');
      raise Exception.Create('Изображения содержат сами страницы. '+
        'Выберите «Без уменьшения качества» или один из режимов сжатия изображений.');
    end;
  end;
  var Missing:=MissingBookConversionComponents(AppPath,SourceFile,Extension,
    not ForReading and (QualityProfile<>'none') and ((QualityProfile<>'original') or (ScanLayout<>'keep') or Grayscale),
    IsCanceled,TargetExtension,OutputProfile);
  if (TargetExtension='.mobi') or (TargetExtension='.azw3') then
  begin
    var Capability:=TPath.Combine(AppPath,'tools/bookconvert/KINDLE_OUTPUT_API.txt');
    if not FileExists(Capability) or (TFile.GetSize(Capability)>16) or
      (Trim(TFile.ReadAllText(Capability,TEncoding.UTF8))<>'1') then
      if (Length(Missing)=0) or (Missing[0]<>'BookProcessing') then
        Missing:=TArray<string>.Create('BookProcessing')+Missing;
  end;
  if not ForReading and ((QualityProfile<>'original') or (ScanLayout<>'keep') or Grayscale) then
  begin
    var RequiredAPI:=1+Ord(TextLayerOnly);
    if Grayscale or (QualityProfile='maximum') then RequiredAPI:=3;
    if MeasureScans then RequiredAPI:=5;
    if BookProcessingSaveOptionsAPI(AppPath)<RequiredAPI then
      if (Length(Missing)=0) or (Missing[0]<>'BookProcessing') then
        Missing:=TArray<string>.Create('BookProcessing')+Missing;
  end;
  if not ForReading and ((QualityProfile='balanced') or (QualityProfile='economy') or (QualityProfile='maximum') or (QualityProfile='ask') or Grayscale) then
  begin
    var Capability:=TPath.Combine(AppPath,'tools/bookconvert/IMAGE_CONTAINER_API.txt');
    if not FileExists(Capability) or (TFile.GetSize(Capability)>16) or
      (Trim(TFile.ReadAllText(Capability,TEncoding.UTF8))<>'1') then
      if (Length(Missing)=0) or (Missing[0]<>'BookProcessing') then
        Missing:=TArray<string>.Create('BookProcessing')+Missing;
  end;
  if Length(Missing)>0 then
    raise EMHLComponentRequired.Create(Missing,'Для выбранной книги нужны дополнительные компоненты: '+
      String.Join(', ',Missing)+'.');
  if not ForReading and Assigned(ConfirmDamagedContent) and
    (BookProcessingSaveOptionsAPI(AppPath)<BOOK_PROCESSING_PARTIAL_EXPORT_API) then
    raise EMHLComponentRequired.Create('BookProcessing',
      'Обновите модуль подготовки книг, чтобы программа могла предупредить о потерях перед частичным экспортом.');
  Tool:=FindBookProcessingPython(AppPath);
  Script:=TPath.Combine(AppPath,'tools\bookconvert\convert_book.py');
  if not ModularBookProcessingAvailable(AppPath) then
    raise EMHLComponentRequired.Create('BookProcessing','Для создания '+UpperCase(TargetExtension.TrimLeft(['.']))+
      ' нужна общая обработка FB2/EPUB. Дополнительные декодеры других форматов в неё не входят.');
  Work:=TPath.Combine(TPath.GetFullPath(TempRoot),'homelib-convert-'+TGUID.NewGuid.ToString);
  LastDiagnosticStage:='';
  LogDiagnosticTrace('conversion-start','Книга: '+Title+sLineBreak+'Исходный файл: '+SourceFile+sLineBreak+
    'Форматы: '+Extension+' → '+TargetExtension+sLineBreak+'Файл назначения: '+TargetFile+sLineBreak+
    'Изображения: '+ImageQuality,Extension);
  ForceDirectories(Work);
  InputName:=TPath.Combine(Work,'source'+Extension);
  OutputName:=TPath.Combine(Work,'result'+TargetExtension);
  ReportName:=TPath.Combine(Work,'report.json');
  ProgressName:=TPath.Combine(Work,'progress.json');
  ImageOptionsName:=TPath.Combine(Work,'image-options.json');
  ImageChoiceName:=TPath.Combine(Work,'image-choice.txt'); ImageChoiceHandled:=False;
  EstimateCompleted:=0; OptimizedCompleted:=0;
  ImageProcessing:=not ForReading and ((ImageQuality<>'original') or Grayscale);
  StreamingScans:=False;
  TargetTemporary:=''; Log:=TStringStream.Create('',TEncoding.UTF8);
  Started:=GetTickCount64; LastAdvance:=Started; LastPoll:=0;
  KindleWriting:=False; KindleCompleted:=0;
  WrittenEpubResources:=-1; CheckedEpubResources:=-1; PreparedGifs:=0; PreparedDocumentChunks:=0; PreparedWordTotal:=0;
  PreparingWordNotes:=False;
  PreparedChmDocuments:=-1; WrittenFb2Resources:=-1;
  WrittenFb2Sections:=0; CheckedFb2Sections:=0;
  Paged:=False; Finalizing:=False; LastSequence:=0; CompletedPages:=0; PageTotal:=0; LastPercent:=0; RenderedPages:=0;
  ReadProgress:=procedure
  var Value: TJSONValue; Sequence, Completed, Total, Percent: Integer; Stage: string; Advanced: Boolean;
    Handle: THandle; Data: TBytes; Size, Read: DWORD;
  begin
    if GetTickCount64-LastPoll<250 then Exit;
    LastPoll:=GetTickCount64; Advanced:=False; Value:=nil; Stage:=''; Percent:=LastPercent;
    try
      try
        // Allow the writer to atomically replace its record while this handle
        // reads the previous complete snapshot. TFile.ReadAllText denies that
        // replacement on Windows and could randomly fail a long conversion.
        Handle:=CreateFile(PChar(ProgressName),GENERIC_READ,
          FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,nil,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
        if Handle=INVALID_HANDLE_VALUE then Exit;
        try
          Size:=GetFileSize(Handle,nil); if (Size=0) or (Size>1024) then Exit;
          SetLength(Data,Size);
          if not ReadFile(Handle,Data[0],Size,Read,nil) or (Read<>Size) then Exit;
        finally CloseHandle(Handle); end;
        Value:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
        if not (Value is TJSONObject) or not Value.TryGetValue<Integer>('sequence',Sequence) or
          (Sequence<=LastSequence) or not Value.TryGetValue<string>('stage',Stage) or
          not Value.TryGetValue<Integer>('completed',Completed) or not Value.TryGetValue<Integer>('total',Total) then Exit;
        if LastDiagnosticStage<>Stage then
        begin
          LastDiagnosticStage:=Stage;
          LogDiagnosticTrace('conversion-stage',Title+sLineBreak+Stage,Extension);
        end;
        if (((Stage='kindle-writing') and ((TargetExtension='.mobi') or (TargetExtension='.azw3'))) or
            ((Stage='advanced-writing') and (OutputProfile<>''))) and
          (Total=1) and (Completed>=0) and (Completed<=1) then
        begin
          Advanced:=not KindleWriting or (Completed>KindleCompleted);
          // A writer start/completion record does not measure work inside the
          // codec. Keep measured preparation progress; callers show this
          // uncounted phase as activity instead of an invented 98 percent.
          KindleWriting:=True; KindleCompleted:=Completed;
        end
        else if (Stage='scan-estimates') and (Total>0) and (Total<=16) and (Completed>0) and (Completed<=Total) then
        begin
          Advanced:=True; StreamingScans:=True; Percent:=Completed*5 div Total;
        end
        else if (Stage='scan-images') and (Total>0) and (Total<=5000) and
          (Completed>OptimizedCompleted) and (Completed<=Total) then
        begin
          Advanced:=True; StreamingScans:=True; OptimizedCompleted:=Completed; Percent:=Completed*95 div Total;
        end
        else if (Stage='image-estimates') and (Total>0) and (Total<=9) and
          (Completed>EstimateCompleted) and (Completed<=Total) then
        begin
          Advanced:=True; EstimateCompleted:=Completed; ImageProcessing:=True;
          Percent:=55+Completed*10 div Total;
        end
        else if (Stage='optimizing-images') and (Total>0) and (Total<=5000) and
          (Completed>OptimizedCompleted) and (Completed<=Total) then
        begin
          Advanced:=True; OptimizedCompleted:=Completed; ImageProcessing:=True;
          Percent:=65+Completed*32 div Total;
        end
        else if StreamingConversion and (Extension='.epub') and (TargetExtension='.fb2') and
          (Stage='preparing-epub') and not Finalizing and (Total>0) and (Total<=20000) and
          (Completed>PreparedDocumentChunks) and (Completed<=Total) then
        begin
          PreparedDocumentChunks:=Completed; Advanced:=True;
        end
        else if (Stage='preparing-docx') and not Finalizing and (Total>0) and (Total<=20000) and
          ((PreparedWordTotal=0) or (PreparedWordTotal=Total)) and (Completed>=0) and (Completed<=Total) and
          ((PreparedWordTotal=0) or (Completed>PreparedDocumentChunks)) then
        begin
          PreparedWordTotal:=Total; PreparedDocumentChunks:=Completed; Advanced:=True;
        end
        else if (Stage='preparing-docx-notes') and not Finalizing and (Total=0) and
          (Completed>=0) and (Completed<=20000) and ((Completed>0) or not PreparingWordNotes) then
        begin
          PreparingWordNotes:=True; Advanced:=True;
        end
        else if StreamingConversion and
          (((Extension='.docx') and (Stage='preparing-docx')) or ((Extension='.fb2') and (Stage='preparing-fb2'))) and
          not Finalizing and (Total=0) and (Completed>PreparedDocumentChunks) and (Completed<=20000) then
        begin
          PreparedDocumentChunks:=Completed;
          Advanced:=True;
        end
        else if (Stage='preparing-images') and (Pos('|'+Extension+'|','|.cbz|.cbr|.cb7|')>0) and
          not Finalizing and (PageTotal=0) and (Total=0) and (Completed>0) and (Completed<=5000) then
          Advanced:=True
        else if (Stage='rendering') and (Pos('|'+Extension+'|','|.xps|.bmp|.tif|.tiff|')>0) and not Finalizing and (Total>0) and (Total<=5000) and
          ((PageTotal=0) or (PageTotal=Total)) and (Completed>RenderedPages) and (Completed<=Total) then
        begin
          Advanced:=True; PageTotal:=Total; RenderedPages:=Completed;
          if ImageProcessing then Percent:=Completed*45 div Total else Percent:=Completed*90 div Total;
        end
        else if (Stage='pages') and not Finalizing and (Total>0) and (Total<=5000) and
          ((PageTotal=0) or (PageTotal=Total)) and (Completed>=CompletedPages) and (Completed<=Total) then
        begin
          Advanced:=(PageTotal=0) or (Completed>CompletedPages);
          PageTotal:=Total; CompletedPages:=Completed;
          if Completed=0 then Percent:=0
          else if StreamingScans or TextLayerOnly then Percent:=Completed*95 div Total
          else if ImageProcessing then Percent:=45+Completed*10 div Total
          else if Pos('|'+Extension+'|','|.xps|.bmp|.tif|.tiff|')>0 then Percent:=90+Completed*5 div Total
          else Percent:=Completed*95 div Total;
        end
        else if ((TargetExtension='.epub') or (StreamingConversion and (Extension='.chm'))) and
          (Total>0) and (Total<=20000) and (Completed>=0) and (Completed<=Total) and
          (((Stage='writing-epub') and (CheckedEpubResources<0) and (Completed>WrittenEpubResources)) or
           ((Stage='checking-epub') and (Completed>CheckedEpubResources))) then
        begin
          if Stage='writing-epub' then WrittenEpubResources:=Completed else CheckedEpubResources:=Completed;
          Finalizing:=True; Advanced:=True;
        end
        else if (Stage='gif-preparation') and (Total=0) and (Completed>PreparedGifs) and (Completed<=20000) then
        begin
          PreparedGifs:=Completed;
          Finalizing:=True;
          Advanced:=True;
        end
        else if StreamingConversion and (Extension='.chm') and (Stage='preparing-chm') and
          (Total>0) and (Total<=20000) and (Completed>PreparedChmDocuments) and (Completed<=Total) then
        begin
          PreparedChmDocuments:=Completed; Advanced:=True;
        end
        else if (StreamingConversion or Paged) and (TargetExtension='.fb2') and (Stage='writing-fb2') and
          (Total>0) and (Total<=20000) and (Completed>WrittenFb2Resources) and (Completed<=Total) then
        begin
          WrittenFb2Resources:=Completed; Advanced:=True; Finalizing:=True;
        end
        else if StreamingConversion and (Extension='.chm') and (TargetExtension='.fb2') and
          (Stage='writing-fb2-sections') and (Total>0) and (Total<=20000) and
          (Completed>WrittenFb2Sections) and (Completed<=Total) then
        begin
          WrittenFb2Sections:=Completed; Advanced:=True; Finalizing:=True;
        end
        else if StreamingConversion and (TargetExtension='.fb2') and
          (Stage='checking-fb2-sections') and (Total=0) and (Completed>CheckedFb2Sections) and
          (((Extension='.chm') and (Completed<=WrittenFb2Sections)) or
           ((Extension='.epub') and (Completed<=10000000))) then
        begin
          CheckedFb2Sections:=Completed; Advanced:=True; Finalizing:=True;
        end
        else if (Stage='finalizing') and not Finalizing and
          (not Paged or ((Total>0) and (Total<=5000) and (Completed=Total) and
            ((PageTotal=0) or (PageTotal=Total)) and (Completed>=CompletedPages))) then
        begin
          Finalizing:=True; Advanced:=True;
          if StreamingScans then Percent:=97 else if ImageProcessing then Percent:=55 else Percent:=97;
          if Paged then begin PageTotal:=Total; CompletedPages:=Completed; end;
        end;
        LastSequence:=Sequence;
      except
        // A transient sharing failure or an incomplete/invalid progress record
        // must neither fail the book nor renew its inactivity deadline.
        Advanced:=False;
      end;
    finally Value.Free; end;
    if Advanced then
    begin
      if Percent<LastPercent then Percent:=LastPercent;
      LastAdvance:=GetTickCount64; LastPercent:=Percent;
      if Assigned(OnProgress) then
        if (Stage='preparing-docx') and (Total>0) then OnProgress(Percent,Completed,Total,Stage)
        else OnProgress(Percent,CompletedPages,PageTotal,Stage);
    end;
  end;
  Check:=procedure
    var Options: TBookImageQualityOptions; Choice: string; SelectedAt: UInt64;
      Canceled: Boolean;
    begin
      Canceled:=Assigned(IsCanceled) and IsCanceled();
      if Canceled and not (MeasureScans and not ImageChoiceHandled and FileExists(ImageOptionsName)) then
        raise EAbort.Create('Конвертация отменена.');
      if not Canceled then ReadProgress;
      if not ForReading and (QualityProfile='ask') and not ImageChoiceHandled and FileExists(ImageOptionsName) then
      begin
        if not Assigned(ChooseImageQuality) then raise Exception.Create('Не задан выбор качества изображений.');
        if TryReadBookImageQualityOptions(ImageOptionsName,Options) then
        begin
          SelectedAt:=GetTickCount64;
          Choice:=ChooseImageQuality(Options);
          // Time spent by the user choosing a profile is not a stalled codec.
          Inc(Started,GetTickCount64-SelectedAt); LastAdvance:=GetTickCount64;
          if Assigned(IsCanceled) and IsCanceled() then Abort;
          if (Choice='') or (Choice='cancel') then raise EAbort.Create('Экспорт отменён.');
          var ChoiceParts:=Choice.Split(['|']); var CheckedChoice:=ChoiceParts[0];
          if (Length(ChoiceParts)>3) or ((Length(ChoiceParts)>1) and
            (not Options.ScanPages or ((ChoiceParts[1]<>'split') and (ChoiceParts[1]<>'auto')))) or
            ((Length(ChoiceParts)>2) and (not ChoiceParts[2].StartsWith('except=') or
             not IsValidScanPageExclusions(ChoiceParts[2].Substring(7)))) then
            raise Exception.Create('Проверьте параметры разделения сканов. Номера исключений укажите, например, так: 1, 98-100.');
          if (CheckedChoice='none') and ((Options.NoImagesBytes<=0) or (Length(ChoiceParts)<>1)) then
            raise Exception.Create('В этой книге изображения содержат сами страницы. Выберите режим с изображениями.');
          if (CheckedChoice<>'original') and (CheckedChoice<>'high') and (CheckedChoice<>'balanced') and (CheckedChoice<>'economy') and (CheckedChoice<>'maximum') and (CheckedChoice<>'none') then
            raise Exception.Create('Неизвестное качество изображений.');
          TFile.WriteAllText(ImageChoiceName+'.new',Choice,TEncoding.UTF8);
          TFile.Move(ImageChoiceName+'.new',ImageChoiceName);
          ImageChoiceHandled:=True;
        end;
      end;
      if Canceled then Abort;
      if KindleWriting then
      begin
        if GetTickCount64-LastAdvance>310000 then
          raise Exception.Create('Модуль сохранения не завершил работу за пять минут. Исходная книга сохранена.');
      end
      else if Paged or ImageProcessing or StreamingConversion or (PreparedGifs>0) then
      begin
        if GetTickCount64-LastAdvance>180000 then
          raise Exception.Create('Конвертация не продвигается более трёх минут. Исходная книга сохранена; неполный результат не записан.');
        if GetTickCount64-Started>21600000 then
          raise Exception.Create('Конвертация превысила шесть часов. Исходная книга сохранена; неполный результат не записан.');
      end
      else if GetTickCount64-Started>180000 then
        raise Exception.Create('Конвертация превысила допустимое время. Исходная книга сохранена.');
    end;
  try
    StreamingConversion:=False;
    if Assigned(OnProgress) then OnProgress(0,0,0,'preparing');
    Check;
    Input:=Source;
    if not Assigned(Input) then Input:=TFileStream.Create(SourceFile,fmOpenRead or fmShareDenyWrite);
    try
      MaximumInput:=MAX_BASIC_CONVERSION_SOURCE;
      if ImageProcessing or (ForReading and SameText(Extension,'.fb2')) then MaximumInput:=MAX_PACKAGED_CONVERSION_SOURCE;
      if (Extension='.fb2') and (TargetExtension='.epub') and (QualityProfile='original') and
        not Grayscale and (OutputProfile='') then MaximumInput:=MAX_LARGE_FB2_CONVERSION_SOURCE;
      if Input.Size>MAX_BASIC_CONVERSION_SOURCE then
      begin
        SavedPosition:=Input.Position;
        try
          Input.Position:=0; SetLength(Header,1024); Input.ReadBuffer(Header[0],Length(Header));
          if TEncoding.ASCII.GetString(Header,0,5)='{\rtf' then MaximumInput:=MAX_RTF_CONVERSION_SOURCE
          else if TEncoding.ASCII.GetString(Header).Contains('%PDF-') then MaximumInput:=MAX_PDF_CONVERSION_SOURCE
          else if TEncoding.ASCII.GetString(Header,0,8)='AT&TFORM' then MaximumInput:=MAX_PACKAGED_CONVERSION_SOURCE
          else if TEncoding.ASCII.GetString(Header,0,4)='ITSF' then MaximumInput:=MAX_CHM_CONVERSION_SOURCE
          else if (Header[0]=$FF) and (Header[1]=$D8) and (Header[2]=$FF) then MaximumInput:=MAX_JPEG_CONVERSION_SOURCE
          else if ((Header[0]=$49) and (Header[1]=$49) and (Header[2]=$2A) and (Header[3]=0)) or
             ((Header[0]=$4D) and (Header[1]=$4D) and (Header[2]=0) and (Header[3]=$2A)) or
             ((Header[0]=$50) and (Header[1]=$4B)) or
             ((Header[0]=$52) and (Header[1]=$61) and (Header[2]=$72) and (Header[3]=$21)) or
             ((Header[0]=$37) and (Header[1]=$7A) and (Header[2]=$BC) and (Header[3]=$AF)) then MaximumInput:=MAX_PACKAGED_CONVERSION_SOURCE;
        finally Input.Position:=SavedPosition; end;
      end;
      if Input.Size>MaximumInput then raise Exception.Create('Книга превышает предел конвертации ('+IntToStr(MaximumInput div 1024 div 1024)+' МБ).');
      SavedPosition:=Input.Position;
      try
        Input.Position:=0; Writer:=TFileStream.Create(InputName,fmCreate);
        try
          if not Assigned(IsCanceled) then Writer.CopyFrom(Input,Input.Size)
          else
          begin
            var Remaining:=Input.Size;
            var Buffer: TBytes; SetLength(Buffer,256*1024);
            while Remaining>0 do
            begin
              if IsCanceled() then Abort;
              var Bytes:=Length(Buffer);
              if Remaining<Bytes then Bytes:=Integer(Remaining);
              Input.ReadBuffer(Buffer[0],Bytes); Writer.WriteBuffer(Buffer[0],Bytes);
              Dec(Remaining,Bytes);
            end;
          end;
        finally Writer.Free; end;
      finally Input.Position:=SavedPosition; end;
    finally if not Assigned(Source) then Input.Free; end;
    Check;
    Actual:=DetectReaderExtension(InputName);
    // The signature recognizes the container. The converter still verifies
    // which members belong to the comic, including ZIP files labelled CBZ.
    if ((Actual='.zip') and (Extension='.cbz')) or ((Actual='.rar') and (Extension='.cbr')) or
      ((Actual='.7z') and (Extension='.cb7')) then
      Actual:=Extension;
    if not ForReading and SkipDamagedFB2Image and (Actual='.fb2') and (BookProcessingSaveOptionsAPI(AppPath)<6) then
      raise EMHLComponentRequired.Create('BookProcessing','Для пропуска повреждённых изображений FB2 обновите модуль подготовки книг.');
    var IsLargeInput:=TFile.GetSize(InputName)>MAX_BASIC_CONVERSION_SOURCE;
    if IsLargeInput and (Actual='.pdf') and (BookProcessingSaveOptionsAPI(AppPath)<4) then
      raise EMHLComponentRequired.Create('BookProcessing','Для конвертации больших PDF обновите модуль подготовки книг.');
    if IsLargeInput and (Actual='.rtf') and (BookProcessingSaveOptionsAPI(AppPath)<7) then
      raise EMHLComponentRequired.Create('BookProcessing','Для обработки больших RTF обновите модуль подготовки книг.');
    var StreamingEpub:=not ForReading and (Actual='.epub') and (QualityProfile='original') and
      not Grayscale and (OutputProfile='') and ((TargetExtension='.fb2') or (TargetExtension='.epub'));
    var StreamingFB2:=(Actual='.fb2') and (TargetExtension='.epub') and (QualityProfile='original') and
      not Grayscale and (OutputProfile='');
    StreamingConversion:=IsLargeInput and (StreamingEpub or StreamingFB2 or (Actual='.chm'));
    if StreamingConversion and (BookProcessingSaveOptionsAPI(AppPath)<BOOK_PROCESSING_EXTENDED_EXPORT_API) then
      raise EMHLComponentRequired.Create('BookProcessing','Для обработки этой большой книги обновите модуль подготовки книг.');
    // The compressed file size does not measure the amount of book markup.
    if ((Actual='.chm') or (not ForReading and (Actual='.epub') and (TargetExtension='.fb2') and
      (OutputProfile=''))) and (BookProcessingSaveOptionsAPI(AppPath)>=BOOK_PROCESSING_EXTENDED_EXPORT_API) then
      StreamingConversion:=True;
    if IsLargeInput and
      (Pos('|'+Actual+'|','|.pdf|.djvu|.djv|.dju|.djm|.djvm|.rtf|.jpg|.jpeg|.tif|.tiff|.cbz|.cbr|.cb7|')=0) and
      not ((ForReading and SameText(Actual,'.fb2')) or
        (ImageProcessing and ((Actual='.fb2') or (Actual='.epub'))) or StreamingConversion) then
      raise Exception.Create('Для этого формата предел конвертации — 64 МБ.');
    if (Actual<>'') and IsBasicConversionSource(Actual) and not SameText(Actual,Extension) then
    begin
      TFile.Move(InputName,TPath.ChangeExtension(InputName,Actual));
      InputName:=TPath.ChangeExtension(InputName,Actual); Extension:=Actual;
    end;
    Paged:=Pos('|'+Extension+'|','|.pdf|.djvu|.djv|.dju|.djm|.djvm|.xps|.cbz|.cbr|.cb7|.tif|.tiff|.bmp|')>0;
    // PDF and DjVu process images in page order. The worker can publish a
    // page immediately after finishing an image batch, before this poll reads
    // the batch record. Determine the progress scale before that first page.
    StreamingScans:=not ForReading and (QualityProfile<>'none') and (OutputProfile='') and
      ((TargetExtension='.epub') or (TargetExtension='.fb2')) and
      (Pos('|'+Extension+'|','|.pdf|.djvu|.djv|.dju|.djm|.djvm|')>0);
    if IsDirectDOCFormat(Extension) then
    begin
      var DocWarning: string;
      var DocPartial: Boolean;
      InputName:=PrepareBinaryDOC(InputName,TPath.Combine(Work,'prepared.docx'),
        TPath.Combine(Work,'prepared.txt'),AppPath,
        procedure
        begin
          Check;
        end,DocWarning,DocPartial);
      if (DocWarning<>'') and Assigned(Warnings) then Warnings.Add(DocWarning);
      if not ForReading and DocPartial and (DocWarning<>'') then
        DamageNotice:=DocWarning+sLineBreak;
      Extension:=ExtractFileExt(InputName);
    end;
    if (Extension='.docx') and (BookProcessingSaveOptionsAPI(AppPath)>=BOOK_PROCESSING_EXTENDED_EXPORT_API) then
      StreamingConversion:=True;
    // The Python same-format path validates and copies the exact bytes. Do
    // not publish an unchecked source merely because its suffix matches.
    try
        var Arguments:=TArray<string>.Create('-I','-B','-X','utf8',Script,InputName,OutputName,'--report',ReportName,'--progress-file',ProgressName,
          '--title',Title,'--author',Author,'--language',Language,
          '--tools-root',TPath.Combine(AppPath,'tools'));
        if ForReading then Arguments:=Arguments+TArray<string>.Create('--reading');
        if not ForReading then
        begin
          Arguments:=Arguments+TArray<string>.Create('--image-quality',QualityProfile,'--scan-layout',ScanLayout);
          if Grayscale and (QualityProfile<>'none') then Arguments:=Arguments+TArray<string>.Create('--grayscale');
          if RecoverDamagedFB2 and (Actual='.fb2') and (BookProcessingSaveOptionsAPI(AppPath)>=6) then
            Arguments:=Arguments+TArray<string>.Create('--skip-damaged-fb2-image');
          if Assigned(ConfirmDamagedContent) and (Extension='.epub') and
             ((TargetExtension='.fb2') or (TargetExtension='.epub')) and
             (BookProcessingSaveOptionsAPI(AppPath)>=BOOK_PROCESSING_EXTENDED_EXPORT_API) then
            Arguments:=Arguments+TArray<string>.Create('--allow-partial-epub');
          if OutputProfile<>'' then Arguments:=Arguments+TArray<string>.Create('--output-profile',OutputProfile);
          if TextLayerOnly then Arguments:=Arguments+TArray<string>.Create('--text-layer-only');
          if PackedOutput and (TargetExtension='.fb2') and
            ((QualityProfile='balanced') or (QualityProfile='economy') or (QualityProfile='maximum') or (QualityProfile='ask') or Grayscale) then
            Arguments:=Arguments+TArray<string>.Create('--image-container','fb2-zip');
          if ScanExclude<>'' then Arguments:=Arguments+TArray<string>.Create('--scan-exclude',ScanExclude);
          if MeasureScans then Arguments:=Arguments+TArray<string>.Create('--measure-scans');
          if QualityProfile='ask' then Arguments:=Arguments+TArray<string>.Create(
            '--image-options',ImageOptionsName,'--image-choice',ImageChoiceName);
        end;
        // Signature detection normalizes HTM/XHTML/SHTML to HTML. Keep the
        // original local document folder for its relative images nevertheless.
        // Archive paths remain excluded: their adjacent files are not resources.
        if (Pos('|'+Extension+'|','|.html|.htm|.xhtml|.shtml|.md|.markdown|')>0) and
          (Pos('|'+LowerCase(ExtractFileExt(SourceFile))+'|','|.html|.htm|.xhtml|.shtml|.md|.markdown|')>0) then
          Arguments:=Arguments+TArray<string>.Create('--resource-root',ExtractFilePath(TPath.GetFullPath(SourceFile)));
        var ConverterMemoryLimit: NativeUInt;
        ConverterMemoryLimit:=NativeUInt(512)*1024*1024;
        // PDFium's decoded page resources can exceed the ordinary converter
        // limit even for a small on-disk PDF. Keep a bounded job for export.
        if (Extension='.pdf') and not ForReading and (TargetExtension<>'.pdf') then
          ConverterMemoryLimit:=NativeUInt(1024)*1024*1024;
        // WebView2 needs the same bounded allocation for pagination and for
        // MathML snapshots. The job still owns every process in the renderer.
        if ((OutputProfile='pdf') and (Actual<>'.fb2')) or
           (not ForReading and (Actual='.epub') and (TargetExtension='.fb2') and (QualityProfile<>'none') and
            FileExists(TPath.Combine(AppPath,FormatComponentFile('EpubPdfExport')))) then
          ConverterMemoryLimit:=NativeUInt($80000000); // 2 GiB, including x86.
        RunExternalToolToStream(Tool,Arguments,Log,
          function: Boolean begin Check; Result:=False; end,0,True,ConverterMemoryLimit);
      except
        on E: EMHLExternalToolError do
        begin
          if FileExists(ReportName) then
          begin
            Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
            try
              RecordReportedTools(Report);
              if (Report is TJSONObject) and (TJSONObject(Report).GetValue('required_component')<>nil) then
              begin
                var Required:=TJSONObject(Report).GetValue('required_component').Value;
                if Required='BookConverter' then Required:='BookProcessing';
                if (Required='DocSharp') or (Required='7-Zip') or (Required='WebP') or
                  (Required='JPEG XL') or (Required='DjVuLibre') or (Required='PDFium') or IsFormatComponent(Required) or (Required='IBK') then
                  raise EMHLComponentRequired.Create(Required,TJSONObject(Report).GetValue<string>('error',
                    'Для этой книги нужен компонент '+Required+'.'));
              end;
              if (Report is TJSONObject) and (TJSONObject(Report).GetValue('error')<>nil) then
                raise Exception.Create(TJSONObject(Report).GetValue('error').Value);
            finally Report.Free; end;
          end;
          raise;
        end;
      end;
    Check;
    if not FileExists(OutputName) then raise Exception.Create('Конвертер не создал книгу.');
    RecordBookConversionUse(Extension,TargetExtension,OutputProfile);
    if FileExists(ReportName) then
    begin
      Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
      try
        RecordReportedTools(Report);
        if Report is TJSONObject then
        begin
          ArrayValue:=TJSONObject(Report).GetValue('warnings');
          if Assigned(Warnings) and (ArrayValue is TJSONArray) then
            for I:=0 to TJSONArray(ArrayValue).Count-1 do Warnings.Add(TJSONArray(ArrayValue).Items[I].Value);
          if not ForReading then
          begin
            var Damaged:=TJSONObject(Report).GetValue('damaged_content');
            if Damaged is TJSONArray then
              for var Notice in TJSONArray(Damaged) do
                if (Notice is TJSONString) and (Notice.Value<>'') then
                  DamageNotice:=DamageNotice+Notice.Value+sLineBreak;
            if (DamageNotice='') and (ArrayValue is TJSONArray) then
              for var Notice in TJSONArray(ArrayValue) do
                if (Notice is TJSONString) and
                  (Notice.Value.StartsWith('Повреждённая обложка') or Notice.Value.StartsWith('Повреждённая иллюстрация')) then
                  DamageNotice:=DamageNotice+Notice.Value+sLineBreak;
          end;
        end;
      finally Report.Free; end;
    end;
    if DamageNotice<>'' then
    begin
      if not Assigned(ConfirmDamagedContent) then
        raise EReadError.Create('Для частичного экспорта требуется подтверждение.'+sLineBreak+TrimRight(DamageNotice));
      var ConfirmationStarted:=GetTickCount64;
      var Confirmed:=ConfirmDamagedContent(TrimRight(DamageNotice));
      Inc(Started,GetTickCount64-ConfirmationStarted); LastAdvance:=GetTickCount64;
      Check;
      if not Confirmed then
        raise EBookPartialExportDeclined.Create('Частичный экспорт отменён для этой книги.');
    end;
    TargetTemporary:=CreateBookOutputStage(TargetFile);
    TFile.Copy(OutputName,TargetTemporary,True);
    with TFileStream.Create(TargetTemporary,fmOpenReadWrite or fmShareDenyWrite) do
      try if not FlushFileBuffers(Handle) then RaiseLastOSError; finally Free; end;
    Check;
    PublishBookOutput(TargetTemporary,TargetFile,OverwriteExisting,ProtectedSource);
    TargetTemporary:='';
    if Assigned(OnProgress) then OnProgress(100,CompletedPages,PageTotal,'complete');
  finally
    Check:=nil; ReadProgress:=nil;
    DeleteBookOutputStage(TargetTemporary);
    Log.Free;
    DeleteConversionWork(Work,TempRoot);
  end;
end;

end.
