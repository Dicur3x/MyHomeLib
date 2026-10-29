unit unit_BookSendEstimates;

interface

uses System.Classes, System.SysUtils, System.SyncObjs, unit_Globals,
  unit_BookConversion, unit_BookSavePolicy;

type
  TBookSaveEstimateItem = record
    SourceExtension, TargetExtension, ErrorText, RequiredComponent: string;
    RequiredComponents: TArray<string>;
    Options: TBookImageQualityOptions;
    Completed, ImagesUnchanged: Boolean;
  end;
  TBookSaveEstimateItems = TArray<TBookSaveEstimateItem>;

  TBookSendEstimateThread = class(TThread)
  private
    FBooks: TArray<TBookRecord>;
    FPlan: TBookSaveChoice;
    FAppPath, FTempRoot, FStage: string;
    FItems: TBookSaveEstimateItems;
    FLock: TCriticalSection;
    FRevision: Integer;
    FComplete: Boolean;
    procedure Stage(const Text: string);
    function Estimate(const Book: TBookRecord): TBookSaveEstimateItem;
  protected
    procedure Execute; override;
  public
    constructor Create(const Books: TArray<TBookRecord>; const Plan: TBookSaveChoice;
      const AppPath, TempRoot: string);
    destructor Destroy; override;
    function Poll(var Revision: Integer; out Items: TBookSaveEstimateItems;
      out Status: string; out Complete: Boolean): Boolean;
  end;

function BookSaveMissingComponents(const Items: TBookSaveEstimateItems): TArray<string>;

function KnownBookSaveEstimates(const Books: TArray<TBookRecord>;
  const Plan: TBookSaveChoice): TBookSaveEstimateItems;

implementation

uses System.IOUtils, System.StrUtils, System.ZLib, unit_ReaderCache, unit_BookCache,
  unit_ComponentUpdates, unit_MHLExternalTools, unit_ReaderFormats, unit_Diagnostics;

type
  TSizeCounter = class(TStream)
  private FCount: Int64;
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function TSizeCounter.Read(var Buffer; Count: Longint): Longint;
begin raise EStreamError.Create('Счётчик размера нельзя читать.'); end;
function TSizeCounter.Write(const Buffer; Count: Longint): Longint;
begin Inc(FCount,Count); Result:=Count; end;
function TSizeCounter.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset<>0) or (Origin<>soCurrent) then raise EStreamError.Create('Счётчик размера не поддерживает перемещение.');
  Result:=FCount;
end;

function BookSaveMissingComponents(const Items: TBookSaveEstimateItems): TArray<string>;
begin
  Result:=nil;
  for var Item in Items do
  begin
    var IDs:=Item.RequiredComponents;
    if (Length(IDs)=0) and (Item.RequiredComponent<>'') then IDs:=TArray<string>.Create(Item.RequiredComponent);
    for var ID in IDs do
      if (ID<>'') and (IndexText(ID,Result)<0) then Result:=Result+TArray<string>.Create(ID);
  end;
end;

function KnownBookSaveEstimates(const Books: TArray<TBookRecord>;
  const Plan: TBookSaveChoice): TBookSaveEstimateItems;
begin
  SetLength(Result,Length(Books));
  for var I:=0 to High(Books) do
  begin
    Result[I]:=Default(TBookSaveEstimateItem);
    try
      Result[I].SourceExtension:=BookSaveKnownExtension(Books[I]);
      Result[I].TargetExtension:=BookSaveTargetExtension(Result[I].SourceExtension,Plan.Mode,
        Plan.KeepOriginal,Plan.KeepFB2EPUB);
      Result[I].ImagesUnchanged:=not ((Result[I].TargetExtension='.fb2') or (Result[I].TargetExtension='.epub'));
      if (Books[I].FileName<>'') and SameText(Result[I].SourceExtension,Result[I].TargetExtension) and
        not (Books[I].GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd]) and FileExists(Books[I].GetBookFileName) then
      begin
        var Bytes:=TFile.GetSize(Books[I].GetBookFileName);
        Result[I].Options.OutputBytes[0,0]:=Bytes;
        if Result[I].ImagesUnchanged then for var Q:=1 to 3 do Result[I].Options.OutputBytes[0,Q]:=Bytes;
      end;
    except
      on E: Exception do Result[I].ErrorText:=E.Message;
    end;
  end;
end;

constructor TBookSendEstimateThread.Create(const Books: TArray<TBookRecord>;
  const Plan: TBookSaveChoice; const AppPath, TempRoot: string);
begin
  inherited Create(True); FreeOnTerminate:=False;
  FBooks:=Copy(Books); FPlan:=Plan; FAppPath:=AppPath; FTempRoot:=TPath.GetFullPath(TempRoot);
  FLock:=TCriticalSection.Create; FItems:=KnownBookSaveEstimates(Books,Plan);
  FRevision:=1; FStage:='Оценка размера…';
end;

destructor TBookSendEstimateThread.Destroy;
begin Terminate; WaitFor; FLock.Free; inherited; end;

procedure TBookSendEstimateThread.Stage(const Text: string);
var Changed: Boolean;
begin
  if Terminated then Abort;
  FLock.Enter;
  try Changed:=FStage<>Text; FStage:=Text; Inc(FRevision); finally FLock.Leave; end;
  if Changed then LogDiagnosticTrace('save-estimate-stage',Text);
end;

function TBookSendEstimateThread.Poll(var Revision: Integer; out Items: TBookSaveEstimateItems;
  out Status: string; out Complete: Boolean): Boolean;
begin
  FLock.Enter;
  try
    // Delphi skips Execute when cancellation wins the race with Start. In
    // that case Execute's finally block cannot publish FComplete.
    Complete:=FComplete or Finished;
    Result:=(Revision<>FRevision) or (Complete and not FComplete); Status:=FStage;
    if Complete and not FComplete then Status:='Оценка остановлена. Исходные книги сохранены.';
    if Result then begin Items:=Copy(FItems); Revision:=FRevision; end;
  finally FLock.Leave; end;
end;

function TBookSendEstimateThread.Estimate(const Book: TBookRecord): TBookSaveEstimateItem;
var Prepared, Work, Candidate, Token: string; Pin: TStream; Warnings: TStringList;
  Captured: Boolean; Item: TBookSaveEstimateItem;
  function PackedBytes(Input: TStream): Int64;
  var Counter: TSizeCounter; Compressor: TZCompressionStream; Buffer: TBytes; Count: Integer; Saved: Int64;
  begin
    Counter:=TSizeCounter.Create; Saved:=Input.Position;
    try
      Input.Position:=0; Compressor:=TZCompressionStream.Create(Counter,zcDefault,-15);
      try
        SetLength(Buffer,256*1024);
        repeat
          if Terminated then Abort;
          Count:=Input.Read(Buffer[0],Length(Buffer)); if Count=0 then Break;
          Compressor.WriteBuffer(Buffer[0],Count);
        until False;
      finally Compressor.Free; end;
      Result:=Counter.Position+512; // UTF-8 member name and ZIP structures.
    finally Input.Position:=Saved; Counter.Free; end;
  end;
begin
  Item:=Default(TBookSaveEstimateItem); Prepared:=''; Work:=''; Pin:=nil; Warnings:=nil;
  if DetailedDiagnosticLogging then
    LogDiagnosticTrace('save-estimate-start',Format('Книга: %s'+sLineBreak+
      'Коллекция: %d; запись: %d; ID источника: %s'+sLineBreak+
      'Папка коллекции: %s'+sLineBreak+'Папка / архив: %s'+sLineBreak+'Файл / элемент архива: %s',
      [Book.Title,Book.BookKey.DatabaseID,Book.BookKey.BookID,Book.LibID,
       Book.CollectionRoot,Book.Folder,Book.FileName+Book.FileExt]),Book.FileExt);
  try
    try
      Item.SourceExtension:=BookSaveKnownExtension(Book);
      Item.TargetExtension:=BookSaveTargetExtension(Item.SourceExtension,FPlan.Mode,FPlan.KeepOriginal,FPlan.KeepFB2EPUB);
      if Book.FileName='' then raise Exception.Create('Книга недоступна: исходный файл не определён.');
      if Book.GetBookFormat in [bfFb2Archive,bfRawArchive] then
        Pin:=OpenArchivedBookSaveSource(Book,Item.SourceExtension);
      Item.TargetExtension:=BookSaveTargetExtension(Item.SourceExtension,FPlan.Mode,FPlan.KeepOriginal,FPlan.KeepFB2EPUB);
      if BookSaveKeepsSource(Item.SourceExtension,FPlan.KeepOriginal,FPlan.KeepFB2EPUB) and
        not ((Item.SourceExtension='.fb2') or (Item.SourceExtension='.epub')) then
      begin
        if not Assigned(Pin) then Pin:=Book.GetBookStream(True);
        if not Assigned(Pin) then raise Exception.Create('Исходный файл книги не найден.');
        var Bytes:=Pin.Size; var ArchiveBytes:=PackedBytes(Pin);
        Item.ImagesUnchanged:=True;
        for var L:=0 to 2 do for var Q:=0 to 3 do
        begin Item.Options.OutputBytes[L,Q]:=Bytes; Item.Options.ZipOutputBytes[L,Q]:=ArchiveBytes; end;
      end
      else
      begin
        Prepared:=PrepareConversionSource(Book,
          procedure(Text: string) begin Stage(Text); end,Item.TargetExtension,True);
        if Prepared='' then Abort;
        FreeAndNil(Pin);
        Pin:=OpenCachedBookFile(Prepared);
        Item.SourceExtension:=BookSaveFileExtension(Prepared,Item.SourceExtension);
        Item.TargetExtension:=BookSaveTargetExtension(Item.SourceExtension,FPlan.Mode,FPlan.KeepOriginal,FPlan.KeepFB2EPUB);
        if SameText(Item.SourceExtension,Item.TargetExtension) then
        begin
          Item.Options.OutputBytes[0,0]:=Pin.Size;
          Item.Options.ZipOutputBytes[0,0]:=PackedBytes(Pin);
        end;
        Token:=TGUID.NewGuid.ToString; Work:=TPath.Combine(FTempRoot,'homelib-save-estimate-'+Token);
        if DirectoryExists(Work) then raise Exception.Create('Временная папка оценки уже существует.');
        ForceDirectories(Work); TFile.WriteAllText(TPath.Combine(Work,'owned-save-estimate.marker'),Token,TEncoding.UTF8);
        Candidate:=TPath.Combine(Work,'estimate'+Item.TargetExtension); Captured:=False;
        Warnings:=TStringList.Create;
        try
          ConvertBasicBook(FAppPath,FTempRoot,Prepared,Item.SourceExtension,Candidate,Pin,Warnings,
            function: Boolean begin Result:=Terminated; end,Book.Title,'',Book.Lang,False,
            procedure(Percent, Completed, Total: Integer; const Text: string)
            begin Stage('Оценка изображений: '+IntToStr(Percent)+'%'); end,'ask',
            function(const Options: TBookImageQualityOptions): string
            var OriginalBytes, OriginalZip: Int64;
            begin
              OriginalBytes:=Item.Options.OutputBytes[0,0]; OriginalZip:=Item.Options.ZipOutputBytes[0,0];
              Captured:=True;
              Item.Options:=Options;
              if OriginalBytes>0 then Item.Options.OutputBytes[0,0]:=OriginalBytes;
              if OriginalZip>0 then Item.Options.ZipOutputBytes[0,0]:=OriginalZip;
              // The chooser runs on this worker. Returning cancel terminates
              // the sample conversion, without creating the full output.
              Result:='';
            end);
        except on E: EAbort do if not Captured then raise; end;
        if not Captured then
        begin
          // No raster images: the converter finishes normally. All modes have
          // the same output and can be counted without decoding any pictures.
          var Input:=TFileStream.Create(Candidate,fmOpenRead or fmShareDenyWrite);
          try
            var Bytes:=Input.Size; var ArchiveBytes:=PackedBytes(Input);
            for var L:=0 to 2 do for var Q:=0 to 3 do
            begin
              if Item.Options.OutputBytes[L,Q]=0 then Item.Options.OutputBytes[L,Q]:=Bytes;
              if Item.Options.ZipOutputBytes[L,Q]=0 then Item.Options.ZipOutputBytes[L,Q]:=ArchiveBytes;
            end;
          finally Input.Free; end;
        end;
      end;
    except
      on E: EAbort do if not Terminated then Item.ErrorText:='Оценка книги отменена.';
      on E: EMHLComponentRequired do begin Item.RequiredComponent:=E.ComponentID; Item.RequiredComponents:=Copy(E.ComponentIDs); Item.ErrorText:=E.Message; end;
      on E: EReaderComponentRequired do begin Item.RequiredComponent:=E.ComponentID; Item.ErrorText:=E.Message; end;
      on E: Exception do
      begin Item.ErrorText:=E.Message; LogDiagnosticError('save-size-estimate',E,Item.SourceExtension); end;
    end;
  finally
    Warnings.Free; Pin.Free;
    try
      if (Work<>'') and TPath.GetFullPath(Work).StartsWith(IncludeTrailingPathDelimiter(FTempRoot),True) and
        FileExists(TPath.Combine(Work,'owned-save-estimate.marker')) and
        (TFile.ReadAllText(TPath.Combine(Work,'owned-save-estimate.marker'),TEncoding.UTF8)=Token) then
        TDirectory.Delete(Work,True);
    except
      on E: Exception do
      begin
        LogDiagnosticError('save-size-estimate-cleanup',E);
        Item.ErrorText:=Item.ErrorText+' Не удалось удалить временные данные оценки.';
      end;
    end;
  end;
  Item.Completed:=not Terminated;
  if DetailedDiagnosticLogging then
  begin
    var Outcome: string;
    if Terminated then Outcome:='отменено' else if Item.ErrorText<>'' then Outcome:='ошибка' else Outcome:='готово';
    LogDiagnosticTrace('save-estimate-result',Format('Книга: %s; коллекция: %d; запись: %d'+sLineBreak+
      'Форматы: %s → %s'+sLineBreak+'Результат: %s'+sLineBreak+
      'Нужные компоненты: %s'+sLineBreak+'Причина: %s',
      [Book.Title,Book.BookKey.DatabaseID,Book.BookKey.BookID,Item.SourceExtension,Item.TargetExtension,
       Outcome,String.Join(', ',Item.RequiredComponents),Item.ErrorText]),Item.SourceExtension);
  end;
  Result:=Item;
end;

procedure TBookSendEstimateThread.Execute;
begin
  try
    for var I:=0 to High(FBooks) do
    begin
      if Terminated then Break;
      Stage(Format('Книга %d из %d: %s',[I+1,Length(FBooks),FBooks[I].Title]));
      var Item:=Estimate(FBooks[I]);
      FLock.Enter;
      try FItems[I]:=Item; Inc(FRevision); finally FLock.Leave; end;
    end;
  finally
    FLock.Enter;
    try
      FComplete:=True;
      if Terminated then FStage:='Оценка остановлена. Рассчитанные результаты сохранены.'
      else FStage:='Оценка завершена';
      Inc(FRevision);
    finally FLock.Leave; end;
  end;
end;

end.
