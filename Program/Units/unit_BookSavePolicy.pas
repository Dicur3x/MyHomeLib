unit unit_BookSavePolicy;

interface

uses System.SysUtils, System.Classes, unit_Globals;

type
  TBookSaveChoice = record
    Caption: string;
    Mode: TExportMode;
    KeepOriginal, KeepFB2EPUB: Boolean;
  end;

const BOOK_SAVE_DEVICE_MODES: array[0..5] of TExportMode =
  (emFB2,emFB2Zip,emEpub,emTxt,emMobi,emAZW3);
  BOOK_SAVE_ADVANCED_MODES = [emEpub2,emEpub3,emKepub,emKfx,emAzw8,emAdvancedPDF,emMarkdown];

function BookSaveChoices(const Extensions: TArray<string>; ShowAdvanced: Boolean = False;
  const PendingSources: TArray<Boolean> = nil): TArray<TBookSaveChoice>;
function BookSaveAdvancedProfile(Mode: TExportMode): string;
function BookSaveSupportsNoImages(Mode: TExportMode): Boolean;
function BookSaveTargetLabel(const Extension: string; Mode: TExportMode): string;
function BookSaveTargetExtension(const SourceExtension: string; Mode: TExportMode;
  KeepOriginal, KeepFB2EPUB: Boolean): string;
function BookSaveDefaultChoiceIndex(const Choices: TArray<TBookSaveChoice>;
  Mode: TExportMode; KeepOriginal: Boolean): Integer;
function BookSaveZipsTarget(const TargetExtension: string; Mode: TExportMode;
  LegacyZipEachBook: Boolean = False): Boolean;
function BookSaveKeepsSource(const SourceExtension: string;
  Mode: TExportMode; KeepOriginal, KeepFB2EPUB: Boolean): Boolean;
function BookSaveKnownExtension(const Book: TBookRecord): string;
function BookSaveFileExtension(const FileName, DeclaredExtension: string): string;
function OpenArchivedBookSaveSource(const Book: TBookRecord; out Extension: string): TStream;
function BookSaveIsScanSource(const Extension: string): Boolean;
function IsValidBookSaveFolderTemplate(const Value: string): Boolean;
function BookSaveRelativeFolder(const Expanded: string): string;

implementation

uses System.IOUtils, unit_ReaderFormats, unit_Templater, unit_BookMetadataCache,
  unit_MHLArchiveHelpers, unit_BookConversionRequirements;

function BookSaveFileExtension(const FileName, DeclaredExtension: string): string;
begin
  Result:=DetectReaderExtension(FileName);
  if Result='' then Exit(LowerCase(DeclaredExtension));
  // Generic archive signatures cannot distinguish a comic/document container
  // from an ordinary archive. Keep its declared identity, just as reading does.
  if ((Result='.zip') and
    (Pos('|'+LowerCase(DeclaredExtension).TrimLeft(['.'])+'|','|cbz|fb3|epub|docx|odt|odp|ods|pptx|xlsx|')>0)) or
    ((Result='.rar') and SameText(DeclaredExtension,'.cbr')) or
    ((Result='.7z') and SameText(DeclaredExtension,'.cb7')) then
    Result:=LowerCase(DeclaredExtension);
end;

function OpenArchivedBookSaveSource(const Book: TBookRecord; out Extension: string): TStream;
begin
  Extension:=LowerCase(Book.FileExt);
  Result:=OpenRawBookSource(Book);
  try
    if not Assigned(Result) then raise EFileNotFoundException.Create('Исходный файл книги не найден.');
    if Result is TFileStream then
      Extension:=BookSaveFileExtension(TFileStream(Result).FileName,Book.FileExt);
    // FLibrary's separate images still require reconstruction. Ordinary ZIP
    // members reuse the pinned raw cache stream, without extracting twice.
    if IsSevenZipArchive(Book.GetBookFileName) then
    begin
      FreeAndNil(Result);
      Result:=Book.GetBookStream(True);
    end;
  except Result.Free; raise; end;
end;

function BookSaveRelativeFolder(const Expanded: string): string;
begin
  Result:='';
  // Missing author/series must collapse an empty path segment. In particular,
  // "\Series" from an empty author is not a drive-root destination.
  for var Part in Expanded.Replace('/','\').Split(['\']) do
  begin
    if Part='' then Continue;
    if (Part='.') or (Part='..') or (Pos(':',Part)>0) then
      raise Exception.Create('Маска подпапок должна задавать путь внутри выбранной папки.');
    Result:=TPath.Combine(Result,Part);
  end;
end;

function IsValidBookSaveFolderTemplate(const Value: string): Boolean;
var Template: TTemplater;
begin
  Result:=False;
  if (Length(Value)>2048) or (Pos(#0,Value)>0) or TPath.IsPathRooted(Value) or
    (Pos(':',Value)>0) then Exit;
  for var Part in Value.Replace('/','\').Split(['\']) do
    if (Part='.') or (Part='..') then Exit;
  Template:=TTemplater.Create;
  try Result:=Template.SetTemplate(Value,TpPath)=ErFine; finally Template.Free; end;
end;

function BookSaveKnownExtension(const Book: TBookRecord): string;
begin
  Result:=LowerCase(Book.FileExt);
  // No extraction, conversion or download while constructing the dialog.
  if (Book.FileName='') or (Book.GetBookFormat in [bfFb2Archive,bfRawArchive,bfFbd]) then Exit;
  var Source:=Book.GetBookFileName;
  if FileExists(Source) then
  begin
    Result:=BookSaveFileExtension(Source,Book.FileExt);
  end;
end;

function BookSaveIsScanSource(const Extension: string): Boolean;
begin
  Result:=Pos('|'+LowerCase(Extension.TrimLeft(['.']))+'|',
    '|pdf|djvu|djv|dju|djm|djvm|tif|tiff|cbz|cbr|cb7|jpg|jpeg|png|gif|bmp|webp|xps|')>0;
end;

function NormalExtension(const Value: string): string;
begin
  Result:=LowerCase(Trim(Value));
  if (Result<>'') and (Result[1]<>'.') then Result:='.'+Result;
end;

function BookSaveKeepsSource(const SourceExtension: string;
  Mode: TExportMode; KeepOriginal, KeepFB2EPUB: Boolean): Boolean;
begin
  var Ext:=NormalExtension(SourceExtension);
  Result:=KeepOriginal or ((Mode=emAdvancedPDF) and (Ext='.pdf')) or
    ((Mode=emMarkdown) and ((Ext='.md') or (Ext='.markdown'))) or
    (KeepFB2EPUB and ((Ext='.fb2') or (Ext='.epub')));
end;

function BookSaveAdvancedProfile(Mode: TExportMode): string;
begin
  case Mode of
    emEpub2: Result:='epub2';
    emEpub3: Result:='epub3';
    emKepub: Result:='kepub';
    emKfx: Result:='kfx';
    emAzw8: Result:='azw8';
    emAdvancedPDF: Result:='pdf';
    emMarkdown: Result:='md';
  else Result:='';
  end;
end;

function BookSaveSupportsNoImages(Mode: TExportMode): Boolean;
begin
  Result:=not (Mode in [emKfx,emAzw8]);
end;

function BookSaveTargetLabel(const Extension: string; Mode: TExportMode): string;
begin
  case Mode of
    emEpub2: Result:='EPUB 2';
    emEpub3: Result:='EPUB 3';
    emKepub: Result:='KEPUB';
    emMarkdown: Result:='Markdown';
  else Result:=UpperCase(Extension.TrimLeft(['.']));
  end;
  if BookSaveZipsTarget(Extension,Mode) then Result:=Result+' в ZIP';
end;

function BookSaveTargetExtension(const SourceExtension: string; Mode: TExportMode;
  KeepOriginal, KeepFB2EPUB: Boolean): string;
begin
  Result:=NormalExtension(SourceExtension);
  if BookSaveKeepsSource(Result,Mode,KeepOriginal,KeepFB2EPUB) then Exit;
  if Mode in BOOK_SAVE_ADVANCED_MODES then
    Exit(AdvancedBookOutputExtension(BookSaveAdvancedProfile(Mode)));
  case Mode of
    emEpub,emEpubZip: Result:='.epub';
    emTxt: Result:='.txt';
    emLrf: Result:='.lrf';
    emPDF: Result:='.pdf';
    emMobi: Result:='.mobi';
    emAZW3: Result:='.azw3';
  else Result:='.fb2';
  end;
end;

function BookSaveDefaultChoiceIndex(const Choices: TArray<TBookSaveChoice>;
  Mode: TExportMode; KeepOriginal: Boolean): Integer;
begin
  Result:=0;
  if KeepOriginal then Exit;
  // A mixed selection starts with "keep every source" whose placeholder mode
  // is FB2. Prefer the actual conversion, not that unrelated first choice.
  for var I:=0 to High(Choices) do
    if (Choices[I].Mode=Mode) and not Choices[I].KeepOriginal and
      not Choices[I].KeepFB2EPUB then Exit(I);
  // Homogeneous source selections intentionally omit same-format conversion.
  for var I:=0 to High(Choices) do
    if (Choices[I].Mode=Mode) and not Choices[I].KeepFB2EPUB then Exit(I);
end;

function BookSaveChoices(const Extensions: TArray<string>; ShowAdvanced: Boolean;
  const PendingSources: TArray<Boolean>): TArray<TBookSaveChoice>;
var AllFB2, AllEPUB, AllTXT, AllMOBI, AllAZW3, HasFB2EPUB, HasOther, CanKepub, CanPDF, AllPDF,
  AllMarkdown, CanMarkdown, CanEpub2, CanEpub3, CanKfx: Boolean;
  procedure Add(const Caption: string; Mode: TExportMode; KeepOriginal, KeepFB2EPUB: Boolean);
  var Choice: TBookSaveChoice;
  begin
    Choice.Caption:=Caption; Choice.Mode:=Mode;
    Choice.KeepOriginal:=KeepOriginal; Choice.KeepFB2EPUB:=KeepFB2EPUB;
    Result:=Result+[Choice];
  end;
begin
  Result:=nil; AllFB2:=Length(Extensions)>0; AllEPUB:=AllFB2;
  AllTXT:=AllFB2; AllMOBI:=AllFB2; AllAZW3:=AllFB2;
  HasFB2EPUB:=False; HasOther:=False; CanKepub:=AllFB2; CanPDF:=AllFB2; AllPDF:=AllFB2;
  CanMarkdown:=AllFB2; AllMarkdown:=AllFB2; CanEpub2:=AllFB2; CanEpub3:=AllFB2;
  CanKfx:=AllFB2;
  for var I:=0 to High(Extensions) do
  begin
    var Ext:=NormalExtension(Extensions[I]);
    // Archive entries may carry legacy names or be nested. The export
    // worker checks the actual payload before choosing or running a writer.
    var Pending:=(I<Length(PendingSources)) and PendingSources[I];
    AllFB2:=AllFB2 and (Ext='.fb2'); AllEPUB:=AllEPUB and (Ext='.epub');
    AllTXT:=AllTXT and (Ext='.txt');
    AllPDF:=AllPDF and (Ext='.pdf');
    AllMarkdown:=AllMarkdown and ((Ext='.md') or (Ext='.markdown'));
    CanMarkdown:=CanMarkdown and (Pending or (AdvancedWriterComponent(Ext,'md')<>''));
    CanEpub2:=CanEpub2 and (Pending or (AdvancedWriterComponent(Ext,'epub2')<>''));
    CanEpub3:=CanEpub3 and (Pending or (AdvancedWriterComponent(Ext,'epub3')<>''));
    CanKepub:=CanKepub and (Pending or (AdvancedWriterComponent(Ext,'kepub')<>''));
    CanKfx:=CanKfx and (Pending or (AdvancedWriterComponent(Ext,'kfx')<>''));
    CanPDF:=CanPDF and (Pending or (Ext='.pdf') or (AdvancedWriterComponent(Ext,'pdf')<>''));
    AllMOBI:=AllMOBI and (Ext='.mobi'); AllAZW3:=AllAZW3 and (Ext='.azw3');
    if (Ext='.fb2') or (Ext='.epub') then HasFB2EPUB:=True else HasOther:=True;
  end;
  if AllFB2 then
  begin
    Add('Оставить FB2',emFB2,True,False);
    Add('Оставить FB2 в ZIP',emFB2Zip,True,False);
  end
  else if AllEPUB then Add('Оставить EPUB',emEpub,True,False)
  else if AllTXT then Add('Оставить TXT',emTxt,True,False)
  else if AllMOBI then Add('Оставить MOBI',emMobi,True,False)
  else if AllAZW3 then Add('Оставить AZW3',emAZW3,True,False)
  else if AllMarkdown then Add('Оставить Markdown',emFB2,True,False)
  else Add('Оставить исходный формат каждой книги',emFB2,True,False);
  if not AllFB2 then
  begin
    Add('Преобразовать в FB2',emFB2,False,False);
    Add('Преобразовать в FB2 в ZIP',emFB2Zip,False,False);
  end;
  if not AllEPUB then Add('Преобразовать в EPUB',emEpub,False,False);
  if HasFB2EPUB and HasOther then
  begin
    Add('Оставить FB2 и EPUB; остальные — в FB2',emFB2,False,True);
    Add('Оставить EPUB; остальные — в FB2 в ZIP',emFB2Zip,False,True);
    Add('Оставить FB2 и EPUB; остальные — в EPUB',emEpub,False,True);
  end;
  if not AllTXT then Add('Преобразовать в TXT — только текст',emTxt,False,False);
  if not AllMOBI then Add('Преобразовать в MOBI — для старых Kindle',emMobi,False,False);
  if not AllAZW3 then Add('Преобразовать в AZW3 — для Kindle с KF8',emAZW3,False,False);
  if ShowAdvanced then
  begin
    if CanKfx then
    begin
      Add('Преобразовать в KFX — для Kindle',emKfx,False,False);
      Add('Преобразовать в AZW8 — для Kindle',emAzw8,False,False);
    end;
    if CanEpub2 then Add('Преобразовать в EPUB 2',emEpub2,False,False);
    if CanEpub3 then Add('Преобразовать в EPUB 3',emEpub3,False,False);
    if CanMarkdown and not AllMarkdown then Add('Преобразовать в Markdown',emMarkdown,False,False);
    if CanKepub then Add('Преобразовать в KEPUB — для Kobo',emKepub,False,False);
    if CanPDF and not AllPDF then Add('Преобразовать в PDF',emAdvancedPDF,False,False);
  end;
end;

function BookSaveZipsTarget(const TargetExtension: string; Mode: TExportMode;
  LegacyZipEachBook: Boolean): Boolean;
begin
  Result:=(NormalExtension(TargetExtension)='.fb2') and ((Mode=emFB2Zip) or LegacyZipEachBook);
end;

end.
