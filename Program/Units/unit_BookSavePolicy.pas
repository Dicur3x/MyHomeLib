unit unit_BookSavePolicy;

interface

uses System.SysUtils, System.Classes, unit_Globals;

type
  TBookSaveChoice = record
    Caption: string;
    Mode: TExportMode;
    KeepOriginal, KeepFB2EPUB: Boolean;
  end;

function BookSaveChoices(const Extensions: TArray<string>): TArray<TBookSaveChoice>;
function BookSaveTargetExtension(const SourceExtension: string; Mode: TExportMode;
  KeepOriginal, KeepFB2EPUB: Boolean): string;
function BookSaveZipsTarget(const TargetExtension: string; Mode: TExportMode;
  LegacyZipEachBook: Boolean = False): Boolean;
function BookSaveKeepsSource(const SourceExtension: string;
  KeepOriginal, KeepFB2EPUB: Boolean): Boolean;
function BookSaveKnownExtension(const Book: TBookRecord): string;
function BookSaveFileExtension(const FileName, DeclaredExtension: string): string;
function OpenArchivedBookSaveSource(const Book: TBookRecord; out Extension: string): TStream;
function BookSaveIsScanSource(const Extension: string): Boolean;
function IsValidBookSaveFolderTemplate(const Value: string): Boolean;
function BookSaveRelativeFolder(const Expanded: string): string;

implementation

uses System.IOUtils, unit_ReaderFormats, unit_Templater, unit_BookMetadataCache,
  unit_MHLArchiveHelpers;

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
  KeepOriginal, KeepFB2EPUB: Boolean): Boolean;
begin
  Result:=KeepOriginal or (KeepFB2EPUB and
    ((NormalExtension(SourceExtension)='.fb2') or (NormalExtension(SourceExtension)='.epub')));
end;

function BookSaveTargetExtension(const SourceExtension: string; Mode: TExportMode;
  KeepOriginal, KeepFB2EPUB: Boolean): string;
begin
  Result:=NormalExtension(SourceExtension);
  if BookSaveKeepsSource(Result,KeepOriginal,KeepFB2EPUB) then Exit;
  case Mode of
    emEpub,emEpubZip: Result:='.epub';
    emTxt: Result:='.txt';
    emLrf: Result:='.lrf';
    emPDF: Result:='.pdf';
    emMobi: Result:='.mobi';
  else Result:='.fb2';
  end;
end;

function BookSaveChoices(const Extensions: TArray<string>): TArray<TBookSaveChoice>;
var AllFB2, AllEPUB, HasFB2EPUB, HasOther: Boolean;
  procedure Add(const Caption: string; Mode: TExportMode; KeepOriginal, KeepFB2EPUB: Boolean);
  var Choice: TBookSaveChoice;
  begin
    Choice.Caption:=Caption; Choice.Mode:=Mode;
    Choice.KeepOriginal:=KeepOriginal; Choice.KeepFB2EPUB:=KeepFB2EPUB;
    Result:=Result+[Choice];
  end;
begin
  Result:=nil; AllFB2:=Length(Extensions)>0; AllEPUB:=AllFB2;
  HasFB2EPUB:=False; HasOther:=False;
  for var Extension in Extensions do
  begin
    var Ext:=NormalExtension(Extension);
    AllFB2:=AllFB2 and (Ext='.fb2'); AllEPUB:=AllEPUB and (Ext='.epub');
    if (Ext='.fb2') or (Ext='.epub') then HasFB2EPUB:=True else HasOther:=True;
  end;
  if AllFB2 then
  begin
    Add('Оставить FB2',emFB2,True,False);
    Add('Оставить FB2 в ZIP',emFB2Zip,True,False);
  end
  else if AllEPUB then Add('Оставить EPUB',emEpub,True,False)
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
end;

function BookSaveZipsTarget(const TargetExtension: string; Mode: TExportMode;
  LegacyZipEachBook: Boolean): Boolean;
begin
  Result:=(NormalExtension(TargetExtension)='.fb2') and ((Mode=emFB2Zip) or LegacyZipEachBook);
end;

end.
