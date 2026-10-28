unit unit_BookConversion;

interface

uses System.SysUtils, System.Classes;

type
  TBookConversionProgress = reference to procedure(Percent, Completed, Total: Integer; const Stage: string);
  TBookImageQualityOptions = record
    HighBytes, BalancedBytes, EconomyBytes, NoImagesBytes: Int64;
    SplitHighBytes, SplitBalancedBytes, SplitEconomyBytes: Int64;
    AutoHighBytes, AutoBalancedBytes, AutoEconomyBytes: Int64;
    ImageCount, SampleCount: Integer;
    TargetFormat: string;
    ScanPages, FirstSamples: Boolean;
    // Layout: keep / split / auto. Quality: original / balanced / economy / none.
    OutputBytes, ZipOutputBytes: array[0..2,0..3] of Int64;
  end;
  TBookImageQualityChooser = reference to function(const Options: TBookImageQualityOptions): string;

// Source streams remain owned by the caller. Output is published only after a
// complete conversion; an existing output file is never replaced.
function IsBasicConversionSource(const Extension: string): Boolean;
function IsValidScanPageExclusions(const Value: string): Boolean;
function TryReadBookImageQualityOptions(const FileName: string; out Options: TBookImageQualityOptions): Boolean;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean> = nil; const Title: string = '';
  const Author: string = ''; const Language: string = ''; const ForReading: Boolean = False;
  const OnProgress: TBookConversionProgress = nil;
  const ImageQuality: string = 'original'; const ChooseImageQuality: TBookImageQualityChooser = nil);

implementation

uses Winapi.Windows, System.IOUtils, System.JSON, unit_MHLExternalTools, unit_ReaderDOC, unit_ReaderFormats;

function CopyUnchangedBook(const SourceFile, SourceExtension, TargetFile: string;
  Source: TStream; const IsCanceled: TFunc<Boolean>): Boolean;
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
  Temporary:=TargetFile+'.homelib-new-'+TGUID.NewGuid.ToString;
  try
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
    if Assigned(IsCanceled) and IsCanceled() then Abort;
    if not MoveFile(PChar(Temporary),PChar(TargetFile)) then RaiseLastOSError;
    Temporary:=''; Result:=True;
  finally
    if Assigned(Source) then Input.Position:=SavedPosition else Input.Free;
    if Temporary<>'' then System.SysUtils.DeleteFile(Temporary);
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
  QualityKeys: array[0..3] of string = ('original','balanced','economy','none');
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
      (Options.SampleCount<0) or (Options.SampleCount>9) then
      raise Exception.Create('Некорректная оценка размера книги.');
    Choices.TryGetValue<Int64>('sizes.none',Options.NoImagesBytes);
    if Options.NoImagesBytes<0 then raise Exception.Create('Некорректная оценка размера без изображений.');
    Choices.TryGetValue<Boolean>('scan_pages',Options.ScanPages);
    Choices.TryGetValue<Boolean>('first_samples',Options.FirstSamples);
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
    for var Layout:=0 to 2 do for var Quality:=0 to 3 do
    begin
      Choices.TryGetValue<Int64>(LayoutKeys[Layout]+'.'+QualityKeys[Quality],Options.OutputBytes[Layout,Quality]);
      Choices.TryGetValue<Int64>('zip_'+LayoutKeys[Layout]+'.'+QualityKeys[Quality],Options.ZipOutputBytes[Layout,Quality]);
      if (Options.OutputBytes[Layout,Quality]<0) or (Options.ZipOutputBytes[Layout,Quality]<0) then
        raise Exception.Create('Некорректная оценка размера копии книги.');
    end;
    Result:=True;
  finally Choices.Free; end;
end;

procedure ConvertBasicBook(const AppPath, TempRoot, SourceFile, SourceExtension,
  TargetFile: string; Source: TStream; Warnings: TStrings;
  const IsCanceled: TFunc<Boolean>; const Title, Author, Language: string; const ForReading: Boolean;
  const OnProgress: TBookConversionProgress; const ImageQuality: string;
  const ChooseImageQuality: TBookImageQualityChooser);
var Work, InputName, OutputName, ReportName, ProgressName, Tool, Script, TargetTemporary: string;
  Input, Writer: TStream; SavedPosition: Int64; Log: TStringStream;
  Started, DOCStarted, LastAdvance, LastPoll: UInt64; Report: TJSONValue; ArrayValue: TJSONValue; I: Integer;
  Extension, TargetExtension, Actual: string; Check, ReadProgress: TProc;
  Paged, Finalizing, ImageProcessing, StreamingScans: Boolean; LastSequence, CompletedPages, PageTotal, LastPercent, RenderedPages: Integer;
  Header: TBytes; MaximumInput: Int64;
  ImageOptionsName, ImageChoiceName: string; ImageChoiceHandled: Boolean;
  EstimateCompleted, OptimizedCompleted: Integer;
  QualityProfile, ScanLayout, ScanExclude: string;

begin
  Extension:=LowerCase(SourceExtension); TargetExtension:=LowerCase(ExtractFileExt(TargetFile));
  var QualityParts:=ImageQuality.Split(['|']);
  QualityProfile:=QualityParts[0]; ScanLayout:='keep'; ScanExclude:='';
  if (Length(QualityParts)>1) and ((QualityParts[1]='split') or (QualityParts[1]='auto')) then ScanLayout:=QualityParts[1];
  if (Length(QualityParts)>2) and QualityParts[2].StartsWith('except=') then ScanExclude:=QualityParts[2].Substring(7);
  if not IsValidScanPageExclusions(ScanExclude) then raise Exception.Create('Некорректные номера сканов.');
  if not ((TargetExtension='.fb2') or (TargetExtension='.epub')) then
    raise Exception.Create('Этот формат пока не поддерживается конвертером FB2/EPUB.');
  if FileExists(TargetFile) then raise Exception.Create('Файл результата уже существует. Выберите другое имя.');
  if Assigned(Warnings) then Warnings.Clear;
  if not ForReading and (QualityProfile='original') and (ScanLayout='keep') and
    CopyUnchangedBook(SourceFile,Extension,TargetFile,Source,IsCanceled) then
  begin
    if Assigned(OnProgress) then OnProgress(100,0,0,'complete');
    Exit;
  end;
  Tool:=TPath.Combine(AppPath,'tools\kindle\python\python.exe');
  Script:=TPath.Combine(AppPath,'tools\bookconvert\convert_book.py');
  if not FileExists(Tool) or not FileExists(Script) then
    raise EMHLComponentRequired.Create('BookConverter','Для создания '+UpperCase(TargetExtension.TrimLeft(['.']))+
      ' нужен общий модуль конвертации HomeLib Ru (BookConverter).');
  if not ForReading and ((QualityProfile<>'original') or (ScanLayout<>'keep')) then
  begin
    var Capability:=TPath.Combine(AppPath,'tools\bookconvert\SAVE_OPTIONS_API.txt');
    if not FileExists(Capability) or (TFile.GetSize(Capability)>16) or
      (Trim(TFile.ReadAllText(Capability,TEncoding.UTF8))<>'1') then
      raise EMHLComponentRequired.Create('BookConverter',
        'Для выбранной обработки изображений нужно обновить общий конвертер HomeLib Ru (BookConverter).');
  end;
  Work:=TPath.Combine(TPath.GetFullPath(TempRoot),'homelib-convert-'+TGUID.NewGuid.ToString);
  ForceDirectories(Work);
  InputName:=TPath.Combine(Work,'source'+Extension);
  OutputName:=TPath.Combine(Work,'result'+TargetExtension);
  ReportName:=TPath.Combine(Work,'report.json');
  ProgressName:=TPath.Combine(Work,'progress.json');
  ImageOptionsName:=TPath.Combine(Work,'image-options.json');
  ImageChoiceName:=TPath.Combine(Work,'image-choice.txt'); ImageChoiceHandled:=False;
  EstimateCompleted:=0; OptimizedCompleted:=0;
  ImageProcessing:=not ForReading and (ImageQuality<>'original');
  StreamingScans:=False;
  TargetTemporary:=''; Log:=TStringStream.Create('',TEncoding.UTF8);
  Started:=GetTickCount64; LastAdvance:=Started; LastPoll:=0;
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
        if (Stage='scan-estimates') and (Total>0) and (Total<=9) and (Completed>0) and (Completed<=Total) then
        begin
          Advanced:=True; StreamingScans:=True; Percent:=Completed*5 div Total;
        end
        else if (Stage='scan-images') and (Total>0) and (Total<=5000) and
          (Completed>OptimizedCompleted) and (Completed<=Total) then
        begin
          Advanced:=True; StreamingScans:=True; OptimizedCompleted:=Completed; Percent:=5+Completed*90 div Total;
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
          if StreamingScans then Percent:=5+Completed*90 div Total
          else if ImageProcessing then Percent:=45+Completed*10 div Total
          else if Pos('|'+Extension+'|','|.xps|.bmp|.tif|.tiff|')>0 then Percent:=90+Completed*5 div Total
          else Percent:=Completed*95 div Total;
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
      if Assigned(OnProgress) then OnProgress(Percent,CompletedPages,PageTotal,Stage);
    end;
  end;
  Check:=procedure
    var Options: TBookImageQualityOptions; Choice: string; SelectedAt: UInt64;
    begin
      if Assigned(IsCanceled) and IsCanceled() then raise EAbort.Create('Конвертация отменена.');
      ReadProgress;
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
            raise Exception.Create('Некорректные параметры разделения сканов.');
          if (CheckedChoice='none') and ((Options.NoImagesBytes<=0) or (Length(ChoiceParts)<>1)) then
            raise Exception.Create('В этой книге изображения содержат сами страницы; сначала нужно распознать текст.');
          if (CheckedChoice<>'original') and (CheckedChoice<>'high') and (CheckedChoice<>'balanced') and (CheckedChoice<>'economy') and (CheckedChoice<>'none') then
            raise Exception.Create('Неизвестное качество изображений.');
          TFile.WriteAllText(ImageChoiceName+'.new',Choice,TEncoding.UTF8);
          TFile.Move(ImageChoiceName+'.new',ImageChoiceName);
          ImageChoiceHandled:=True;
        end;
      end;
      if Paged or ImageProcessing then
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
    if Assigned(OnProgress) then OnProgress(0,0,0,'preparing');
    Check;
    Input:=Source;
    if not Assigned(Input) then Input:=TFileStream.Create(SourceFile,fmOpenRead or fmShareDenyWrite);
    try
      MaximumInput:=64*1024*1024;
      if ImageProcessing or (ForReading and SameText(Extension,'.fb2')) then MaximumInput:=256*1024*1024;
      if Input.Size>MaximumInput then
      begin
        SavedPosition:=Input.Position;
        try
          Input.Position:=0; SetLength(Header,8); Input.ReadBuffer(Header[0],8);
          if ((Header[0]=$49) and (Header[1]=$49) and (Header[2]=$2A) and (Header[3]=0)) or
             ((Header[0]=$4D) and (Header[1]=$4D) and (Header[2]=0) and (Header[3]=$2A)) or
             ((Header[0]=$50) and (Header[1]=$4B)) or
             ((Header[0]=$52) and (Header[1]=$61) and (Header[2]=$72) and (Header[3]=$21)) or
             ((Header[0]=$37) and (Header[1]=$7A) and (Header[2]=$BC) and (Header[3]=$AF)) then MaximumInput:=256*1024*1024;
        finally Input.Position:=SavedPosition; end;
      end;
      if Input.Size>MaximumInput then raise Exception.Create('Книга превышает предел конвертации ('+IntToStr(MaximumInput div 1024 div 1024)+' МБ).');
      SavedPosition:=Input.Position;
      try
        Input.Position:=0; Writer:=TFileStream.Create(InputName,fmCreate);
        try Writer.CopyFrom(Input,Input.Size); finally Writer.Free; end;
      finally Input.Position:=SavedPosition; end;
    finally if not Assigned(Source) then Input.Free; end;
    Check;
    Actual:=DetectReaderExtension(InputName);
    if (TFile.GetSize(InputName)>64*1024*1024) and
      (Pos('|'+Actual+'|','|.tif|.tiff|.cbz|.cbr|.cb7|')=0) and
      not ((ForReading and SameText(Actual,'.fb2')) or
        (ImageProcessing and ((Actual='.fb2') or (Actual='.epub')))) then
      raise Exception.Create('Для этого формата предел конвертации — 64 МБ.');
    if (Actual<>'') and IsBasicConversionSource(Actual) and not SameText(Actual,Extension) then
    begin
      TFile.Move(InputName,TPath.ChangeExtension(InputName,Actual));
      InputName:=TPath.ChangeExtension(InputName,Actual); Extension:=Actual;
    end;
    Paged:=Pos('|'+Extension+'|','|.pdf|.djvu|.djv|.dju|.djm|.djvm|.xps|.cbz|.cbr|.cb7|.tif|.tiff|.bmp|')>0;
    if IsDirectDOCFormat(Extension) then
    begin
      var DOCReader:=FindDirectDOCReader;
      if DOCReader='' then raise EMHLComponentRequired.Create('DocSharp','Для этого DOC нужен компонент DocSharp.');
      var DOCXName:=TPath.Combine(Work,'prepared.docx'); DOCStarted:=GetTickCount64;
      try
        RunExternalToolToStream(DOCReader,[InputName,DOCXName],Log,
          function: Boolean
          begin
            Check; Result:=False;
            if GetTickCount64-DOCStarted>30000 then raise Exception.Create('Чтение DOC превысило 30 секунд.');
          end,0,True,384*1024*1024);
      except
        on E: EMHLExternalToolError do
        begin
          if Log.DataString.Contains('ERROR PASSWORD') then
            raise Exception.Create('Этот DOC защищён паролем. Конвертация не выполнена.')
          else if Log.DataString.Contains('ERROR OLD') then
            raise Exception.Create('Этот DOC создан в Word 95 или более старой версии. Такой вариант пока не поддерживается.')
          else raise Exception.Create('DocSharp не смог прочитать DOC. Возможно, файл повреждён или использует неподдерживаемый вариант формата.');
        end;
      end;
      if not FileExists(DOCXName) then raise Exception.Create('Компонент DocSharp не смог прочитать этот DOC.');
      InputName:=DOCXName; Extension:='.docx'; Log.Clear;
    end;
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
          if ScanExclude<>'' then Arguments:=Arguments+TArray<string>.Create('--scan-exclude',ScanExclude);
          if QualityProfile='ask' then Arguments:=Arguments+TArray<string>.Create(
            '--image-options',ImageOptionsName,'--image-choice',ImageChoiceName);
        end;
        // Signature detection normalizes HTM/XHTML/SHTML to HTML. Keep the
        // original local document folder for its relative images nevertheless.
        // Archive paths remain excluded: their adjacent files are not resources.
        if (Pos('|'+Extension+'|','|.html|.htm|.xhtml|.shtml|.md|.markdown|')>0) and
          (Pos('|'+LowerCase(ExtractFileExt(SourceFile))+'|','|.html|.htm|.xhtml|.shtml|.md|.markdown|')>0) then
          Arguments:=Arguments+TArray<string>.Create('--resource-root',ExtractFilePath(TPath.GetFullPath(SourceFile)));
        RunExternalToolToStream(Tool,Arguments,Log,
          function: Boolean begin Check; Result:=False; end,0,True,512*1024*1024);
      except
        on E: EMHLExternalToolError do
        begin
          if FileExists(ReportName) then
          begin
            Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
            try
              if (Report is TJSONObject) and (TJSONObject(Report).GetValue('required_component')<>nil) then
              begin
                var Required:=TJSONObject(Report).GetValue('required_component').Value;
                if (Required='DocSharp') or (Required='7-Zip') or (Required='WebP') or
                  (Required='JPEG XL') or (Required='DjVuLibre') or (Required='PDFium') or (Required='BookConverter') or (Required='IBK') then
                  raise EMHLComponentRequired.Create(Required,'Для этой книги нужен компонент '+Required+'.');
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
    if Assigned(Warnings) and FileExists(ReportName) then
    begin
      Report:=TJSONObject.ParseJSONValue(TFile.ReadAllText(ReportName,TEncoding.UTF8));
      try
        if Report is TJSONObject then
        begin
          ArrayValue:=TJSONObject(Report).GetValue('warnings');
          if ArrayValue is TJSONArray then
            for I:=0 to TJSONArray(ArrayValue).Count-1 do Warnings.Add(TJSONArray(ArrayValue).Items[I].Value);
        end;
      finally Report.Free; end;
    end;
    ForceDirectories(ExtractFilePath(TPath.GetFullPath(TargetFile)));
    TargetTemporary:=TargetFile+'.homelib-new-'+TGUID.NewGuid.ToString;
    TFile.Copy(OutputName,TargetTemporary,False);
    with TFileStream.Create(TargetTemporary,fmOpenReadWrite or fmShareDenyWrite) do
      try if not FlushFileBuffers(Handle) then RaiseLastOSError; finally Free; end;
    Check;
    if not MoveFile(PChar(TargetTemporary),PChar(TargetFile)) then RaiseLastOSError;
    TargetTemporary:='';
    if Assigned(OnProgress) then OnProgress(100,CompletedPages,PageTotal,'complete');
  finally
    Check:=nil; ReadProgress:=nil;
    if (TargetTemporary<>'') and FileExists(TargetTemporary) then TFile.Delete(TargetTemporary);
    Log.Free;
    if Work.StartsWith(IncludeTrailingPathDelimiter(TPath.GetFullPath(TempRoot)),True) and
      DirectoryExists(Work) and (GetFileAttributes(PChar(Work)) and FILE_ATTRIBUTE_REPARSE_POINT=0) then
      TDirectory.Delete(Work,True);
  end;
end;

end.
