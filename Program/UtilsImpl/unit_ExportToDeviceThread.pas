(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  *         Matvienko Sergei matv84@mail.ru
  *
  ****************************************************************************** *)

unit unit_ExportToDeviceThread;

interface

uses
  Classes,
  ShlObj,
  ActiveX,
  unit_WorkerThread,
  unit_globals,
  Dialogs,
  unit_Templater,
  unit_Interfaces,
  unit_BookExportResults;

type
  TExportToDeviceThread = class(TWorker)
  private type
    TFileOprecord = record
      SourceFile: string;
      SourceExtension: string;
      BookTitle, BookAuthor, BookLanguage: string;
      TargetFile: string;
      CreatedOutputFile: string;
      TargetFolder: string;
      TempFile: string;
      FileName: string;
      Stream: TStream;
      ConversionTempFolder: string;
    end;

  protected
    FSystemData: ISystemData;

  private
    FAppPath: string;
    FTempPath: string;
    FFolderTemplate: string;
    FFileNameTemplate: string;
    FOverwriteFB2Info: Boolean;
    FTXTEncoding: TTXTEncoding;

    FFileOprecord: TFileOprecord;

    FBookFormat: TBookFormat;
    FBookIdList: TBookIdList;
    FResults: TBookExportResults;
    FTemplater: TTemplater;
    FExportMode: TExportMode;
    FExtractOnly: boolean;
    FExplicitFormat: Boolean;
    FConvertBasic: Boolean;
    FLastWarnings: string;
    FProcessedFiles: string;
    FDeviceDir: string;
    FUseMTP: Boolean;
    FMarshalStream: IStream;
    FDeviceShellItem: IShellItem;
    FLastError, FRequiredComponent: string;
    FConverterExitCode: Cardinal;

    FMaxTempPathLength: Integer;

    function fb2Lrf(const InpFile: string; const OutFile: string): Boolean;
    function fb2PDF(const InpFile: string; const OutFile: string): Boolean;
    function fb2Mobi(const InpFile, OutFile: string): Boolean;
    procedure ExportToZip;
    procedure SetDeviceDir(const Value: string);
    function CallExternalConverter: boolean;
    function ProcessFileFromStream: boolean;
    function ExportToFB2: boolean;
    function ActualOutputFile(const FileName: string): string;
    function ConvertBasicFile: Boolean;
    procedure RemoveConversionTempFolder;
    procedure SetBookIdList(const Value: TBookIdList);
    function GetResults: TBookExportResults;

  strict private
    function PrepareFile(const BookKey: TBookKey; Expected: PBookIdStruct = nil): Boolean;
    function SendFileToDevice: Boolean;
    procedure RemoveEmptyTargetFolders;

  protected
    procedure Initialize; override;
    procedure Uninitialize; override;
    procedure WorkFunction; override;

  public
    constructor Create;

    property BookIdList: TBookIdList read FBookIdList write SetBookIdList;
    property Results: TBookExportResults read GetResults;
    property DeviceDir: string read FDeviceDir write SetDeviceDir;
    property UseMTP: Boolean read FUseMTP write FUseMTP;
    property MarshalStream: IStream write FMarshalStream;
    property ProcessedFiles: string read FProcessedFiles;
    property RequiredComponent: string read FRequiredComponent;
    property ExportMode: TExportMode read FExportMode write FExportMode;
    property ExtractOnly: boolean write FExtractOnly;
    property ExplicitFormat: Boolean read FExplicitFormat write FExplicitFormat;
  end;

// Полный путь к внешнему конвертеру, необходимому для режима Mode.
// Возвращает '', если режим обрабатывается собственными средствами (FB2/EPUB/ZIP/TXT).
function GetConverterPath(const AppPath: string; Mode: TExportMode): string;

implementation

uses
  Windows,
  SysUtils,
  IOUtils,
  unit_Consts,
  unit_Settings,
  unit_Helpers,
  dm_user,
  unit_MHLHelpers,
  unit_MHLArchiveHelpers,
  unit_WriteFb2Info,
  unit_BookConversion, unit_BookCache, unit_ReaderCache, unit_MHLExternalTools, System.Variants;

resourcestring
  rstrCheckTemplateValidity = 'Проверьте правильность шаблона';
  rstrArchiveNotFound = 'Архив' + CR + 'не найден!';
  rstrFileNotFound = 'File "%s" not found';
  rstrExportFileFailed = 'Невозможно экспортировать файл «%s»' + CR + '%s' + CR + CR +
    'Обрабатывать оставшиеся файлы?';
  rstrFilesProcessed = 'Записаны файлы: %u из %u';
  rstrCompleted = 'Завершение операции...';
  rstrRememberChoise = 'Запомнить выбор?';
  rstrExportErrors = 'Во время экспорта возникли ошибки: не удалось экспортировать файлов — %d из %d.' + CR +
    'Подробности записаны в файл: %s';
  rstrExportWarnings = 'Экспорт завершён. Для некоторых элементов оформления есть примечания.' + CR +
    'Исходные книги сохранены. Подробности: %s';
  rstrBasicFormatUnsupported = 'Экспорт в %s поддерживает FB2, FB3, EPUB, TXT, HTML, Markdown, RTF, DOC/DOCX, ODT и Kindle без DRM. ' +
    'Книга «%s» имеет формат %s; её исходный файл сохранён.';

const
  MaxPathLength = 240;

function GetConverterPath(const AppPath: string; Mode: TExportMode): string;
begin
  case Mode of
    emLrf:  Result := AppPath + 'converters\fb2lrf\fb2lrf_c.exe';
    emPDF:  Result := AppPath + 'converters\fb2pdf\fb2pdf.cmd';
    emMobi: Result := AppPath + 'converters\fb2mobi\fb2mobi.exe';
  else
    Result := '';
  end;
end;


constructor TExportToDeviceThread.Create;
var
  FSettings: TMHLSettings;
begin
  inherited Create;
  FSettings := Settings;
  FAppPath := FSettings.AppPath;
  FTempPath := FSettings.TempPath;
  FFolderTemplate := FSettings.FolderTemplate;
  FFileNameTemplate := FSettings.FileNameTemplate;
  FOverwriteFB2Info := FSettings.OverwriteFB2Info;
  FTXTEncoding := FSettings.TXTEncoding;

  FMaxTempPathLength := MaxPathLength - Length(FTempPath);
end;

procedure TExportToDeviceThread.SetBookIdList(const Value: TBookIdList);
begin
  FBookIdList := Copy(Value);
  FResults := PendingBookExportResults(FBookIdList);
  FProcessedFiles := '';
end;

function TExportToDeviceThread.GetResults: TBookExportResults;
begin
  // Callers read the snapshot after the modal form has joined its worker.
  Result := Copy(FResults);
end;

function TExportToDeviceThread.PrepareFile(const BookKey: TBookKey; Expected: PBookIdStruct): Boolean;
var
  Collection: IBookCollection;
  R: TBookRecord;
  FTargetFolder: string;
  FTargetFileName: string;
  FTargetFullFilePath: string;
  FTempFileName, PreparedSource, SourceExtension: string;
begin
  Result := False;
  FFileOprecord := Default(TFileOprecord);
  FLastError := '';
  FLastWarnings := '';
  FConvertBasic := False;
  // A retained user card can refer to a book absent from a newer catalogue.
  // Its negative ID is not a catalogue row and must never be guessed/reused.
  if BookKey.BookID <= 0 then
  begin
    FFileOprecord.FileName := 'Недоступная книга';
    FLastError := 'Книга временно отсутствует в обновлённой коллекции. ' +
      'Экспорт станет доступен, если она снова появится.';
    Exit;
  end;
  try
    Collection := FSystemData.GetCollection(BookKey.DatabaseID);
    Collection.GetBookRecord(BookKey, R, False);
    if Assigned(Expected) and Expected^.HasExpectedIdentity and
      not ReaderBookMatchesExpectedIdentity(Expected^.ExpectedLibID, Expected^.ExpectedPhysicalIdentity,
        R, VarToStr(Collection.GetProperty(PROP_SOURCE_LIBRARY))) then
    begin
      FFileOprecord.FileName := 'Книга из группы';
      FLastError := 'Книга из группы больше не совпадает с каталогом. ' +
        'Её запись и заметки сохранены; экспорт пропущен.';
      Exit;
    end;
    PreparedSource:=''; SourceExtension:=LowerCase(R.FileExt);
    if FExplicitFormat and not FExtractOnly and IsReaderArchive(R.FileName+R.FileExt) then
    begin
      var TargetExtension:='.fb2'; if FExportMode=emEpub then TargetExtension:='.epub';
      PreparedSource:=PrepareConversionSource(R,
        procedure(Stage: string) begin if Canceled or Terminated then Abort; SetComment(Stage); end,TargetExtension);
      if PreparedSource='' then Abort;
      SourceExtension:=LowerCase(ExtractFileExt(PreparedSource));
    end;
    FBookFormat := R.GetBookFormat;
    FFileOprecord.FileName := R.FileName + R.FileExt;
    FFileOprecord.SourceExtension := SourceExtension;
    FFileOprecord.BookTitle:=R.Title; FFileOprecord.BookAuthor:=TAuthorsHelper.GetList(R.Authors);
    FFileOprecord.BookLanguage:=R.Lang;
    FConvertBasic := not FExtractOnly and (FExportMode in [emFB2, emEpub]) and
      IsConversionCandidate(SourceExtension) and
      (FExplicitFormat or ((FExportMode = emEpub) and
        (Pos('|'+SourceExtension.TrimLeft(['.'])+'|','|pdf|djvu|djv|dju|djm|djvm|')=0)));
    if FExplicitFormat and not FExtractOnly and not FConvertBasic then
    begin
      var FormatName := 'FB2';
      if FExportMode = emEpub then FormatName := 'EPUB';
      FLastError := Format(rstrBasicFormatUnsupported,
        [FormatName, R.Title, UpperCase(Copy(R.FileExt, 2, MaxInt))]);
      Exit;
    end;

    FTargetFolder := '';
    if not FExtractOnly Then
    begin

      if FTemplater.SetTemplate(FFolderTemplate, TpPath) = ErFine then
        FTargetFolder := FTemplater.ParseString(R, TpPath)
      else
      begin
        Dialogs.ShowMessage(rstrCheckTemplateValidity);
        Exit;
      end;

      if FTargetFolder <> '' then
        FTargetFolder := IncludeTrailingPathDelimiter(Trim(FTargetFolder));

      if not FUseMTP then
        CreateFolders(DeviceDir, FTargetFolder);
    end;

    FFileOprecord.TargetFolder := FTargetFolder;

    if FTemplater.SetTemplate(FFileNameTemplate, TpFile) = ErFine then
      FTargetFileName := FTemplater.ParseString(R, TpFile)
    else
    begin
      Dialogs.ShowMessage(rstrCheckTemplateValidity);
      Exit;
    end;

    FTargetFullFilePath := Trim(TPath.Combine(FTargetFolder, FTargetFileName));
    FTargetFullFilePath := TPath.Combine(FDeviceDir, FTargetFullFilePath);

    if Length(FTargetFullFilePath) < MaxPathLength then
      FTargetFullFilePath := FTargetFullFilePath + R.FileExt
    else
      FTargetFullFilePath  := Format('%s.%d%s',[copy(FTargetFullFilePath, 1, MaxPathLength), R.BookKey.BookID, R.FileExt]);

    if not FUseMTP then
    begin
      var ActualOutputPath: string;
      ActualOutputPath := ActualOutputFile(FTargetFullFilePath);

      if FileExists(ActualOutputPath) then
      begin
        var BaseName := ChangeFileExt(FTargetFullFilePath, '');
        var Ext := ExtractFileExt(FTargetFullFilePath);
        var Counter := 1;
        repeat
          FTargetFullFilePath := Format('%s (%d)%s', [BaseName, Counter, Ext]);
          ActualOutputPath := ActualOutputFile(FTargetFullFilePath);
          Inc(Counter);
        until not FileExists(ActualOutputPath);
      end;
    end;

    FFileOprecord.SourceFile := R.GetBookFileName;
    if PreparedSource<>'' then FFileOprecord.SourceFile:=PreparedSource;
    FFileOprecord.FileName := FTargetFileName + R.FileExt;

    // For MTP: write to temp, then shell-copy to device
    if FUseMTP then
    begin
      if FConvertBasic then
      begin
        FFileOprecord.ConversionTempFolder := TPath.Combine(FTempPath,
          'homelib-export-' + TGUID.NewGuid.ToString);
        ForceDirectories(FFileOprecord.ConversionTempFolder);
        FFileOprecord.TargetFile := TPath.Combine(
          FFileOprecord.ConversionTempFolder, FFileOprecord.FileName);
      end
      else
        FFileOprecord.TargetFile := TPath.Combine(FTempPath, FFileOprecord.FileName);
    end
    else
      FFileOprecord.TargetFile := FTargetFullFilePath;

    if FConvertBasic or (FBookFormat in [bfFb2, bfFb2Archive, bfRawArchive, bfFbd]) then
    begin
      if not FileExists(FFileOprecord.SourceFile) then
      begin
        ShowMessage(rstrArchiveNotFound, MB_ICONERROR or MB_OK);
        Exit;
      end;

      if Length(FTargetFileName) < FMaxTempPathLength then
        FTempFileName := Format('%s%s', [FTargetFileName, R.FileExt])
      else
        FTempFileName := Format('%s%s',[Copy(FTargetFileName, 1, FMaxTempPathLength), R.FileExt]);

      FFileOprecord.TempFile := TPath.Combine(FTempPath, FTempFileName);

      if PreparedSource<>'' then FFileOprecord.Stream:=OpenCachedBookFile(PreparedSource)
      else FFileOprecord.Stream := R.GetBookStream;
      if not Assigned(FFileOprecord.Stream) then
        raise Exception.Create('Не удалось извлечь исходную книгу из архива.');

      if (PreparedSource='') and (FBookFormat in [bfFb2, bfFb2Archive]) and FOverwriteFB2Info then
        WriteFb2InfoToStream(R, FFileOprecord.Stream);

    end;

    if FExtractOnly and not Assigned(FFileOprecord.Stream) then
    begin
      if not FileExists(FFileOprecord.SourceFile) then
      begin
        FLastError := Format('Не найден исходный файл книги «%s».', [FFileOprecord.SourceFile]);
        Exit;
      end;
      // Raw files are handed to scripts by path. Existence alone does not
      // prove that this batch can read them (for example, an exclusive lock).
      var ReadProbe := TFileStream.Create(FFileOprecord.SourceFile, fmOpenRead or fmShareDenyNone);
      ReadProbe.Free;
    end;
    Result := True;
  except
    on E: EMHLComponentRequired do begin Canceled:=True; FRequiredComponent:=E.ComponentID; FLastError:=E.Message; end;
    on E: EAbort do begin Canceled:=True; FLastError:=E.Message; end;
    on E: Exception do
      FLastError := Format('PrepareFile exception: %s', [E.Message]);
  end;
end;

procedure TExportToDeviceThread.ExportToZip;
var
  archiver: TMHLZip;
  ZipFile: string;
  Creating: Boolean;
begin
  Creating := False;
  archiver := nil;
  ZipFile := '';
  try
  try
    ZipFile := FFileOprecord.TargetFile + ZIP_EXTENSION;
    if FileExists(ZipFile) then
    begin
      var BaseName := ChangeFileExt(FFileOprecord.TargetFile, '');
      var Ext := ExtractFileExt(FFileOprecord.TargetFile);
      var Counter := 1;
      repeat
        ZipFile := Format('%s (%d)%s', [BaseName, Counter, Ext]) + ZIP_EXTENSION;
        Inc(Counter);
      until not FileExists(ZipFile);
    end;
    Creating := True;
    archiver := TMHLZip.Create(ZipFile, False);
    FFileOprecord.Stream.Seek(0, soFromBeginning);
    archiver.AddFromStream(FFileOprecord.FileName, FFileOprecord.Stream);
  finally
    FreeAndNil(archiver);
  end;
  except
    // Only this newly selected output belongs to this attempt.
    if Creating then SysUtils.DeleteFile(ZipFile);
    raise;
  end;
  FFileOprecord.CreatedOutputFile := ZipFile;
end;

procedure TExportToDeviceThread.SetDeviceDir(const Value: string);
begin
  FDeviceDir := Value;
end;

function StreamToFile(const AFileName: string; AStream: TStream): boolean;
var
  FileStream: TFileStream;
begin
  FileStream := TFileStream.Create(AFileName, fmCreate);
  try
    AStream.Seek(0, soFromBeginning);
    FileStream.CopyFrom(AStream, AStream.Size);
    Result := True;
  finally
    FileStream.Free;
  end;
end;

function TExportToDeviceThread.CallExternalConverter: boolean;
var
  OutputPath: string;
  ConverterExe: string;
  TempFileCreated: Boolean;
begin
  Result := False;
  TempFileCreated := False;
  OutputPath := '';
  FConverterExitCode := 0;
  try
    if FFileOprecord.Stream <> nil then
    begin
      StreamToFile(FFileOprecord.TempFile, FFileOprecord.Stream);
      FFileOprecord.SourceFile := FFileOprecord.TempFile;
      TempFileCreated := True;
    end;

    case FExportMode of
      emLrf:  OutputPath := ChangeFileExt(FFileOprecord.TargetFile, '.lrf');
      emPDF:  OutputPath := ChangeFileExt(FFileOprecord.TargetFile, '.pdf');
      emMobi: OutputPath := ChangeFileExt(FFileOprecord.TargetFile, '.mobi');
    else
      OutputPath := FFileOprecord.TargetFile;
    end;

    // Remove any stale output from a previous run so we don't mistake it for
    // fresh converter output if the exe silently fails (#65).
    if FileExists(OutputPath) then
      DeleteFile(OutputPath);

    case FExportMode of
      emLrf:
        Result := fb2Lrf(FFileOprecord.SourceFile, FFileOprecord.TargetFile);

      emPDF:
        Result := fb2PDF(FFileOprecord.SourceFile, FFileOprecord.TargetFile);

      emMobi:
        Result := fb2Mobi(FFileOprecord.SourceFile, FFileOprecord.TargetFile);
    end;

    ConverterExe := GetConverterPath(FAppPath, FExportMode);
    if not Result then
    begin
      if FConverterExitCode <> 0 then
        FLastError := Format('Converter "%s" failed with exit code %d: %s',
          [ConverterExe, FConverterExitCode, OutputPath])
      else
        FLastError := Format('Converter "%s" could not be started: %s',
          [ConverterExe, OutputPath]);
    end
    // A process may exit successfully without producing output (for example,
    // with a locked target or invalid CLI arguments). Verify the artifact too.
    else if not FileExists(OutputPath) then
    begin
      Result := False;
      FLastError := Format('Converter "%s" exited OK but produced no output: %s',
        [ConverterExe, OutputPath]);

      // fb2pdf.cmd - оболочка над Java; без установленной JRE она сразу выходит с кодом 1
    end;
    if (not Result) and (FExportMode = emPDF) then
      FLastError := FLastError + ' (fb2pdf requires an installed Java runtime)';
  except
    on E: Exception do
      FLastError := Format('CallExternalConverter exception: %s', [E.Message]);
  end;

  if not Result and (OutputPath <> '') then SysUtils.DeleteFile(OutputPath);

  // Промежуточный файл нужен только конвертеру - не оставляем его в $tmp (#59)
  if TempFileCreated and FileExists(FFileOprecord.TempFile) then
    DeleteFile(FFileOprecord.TempFile);
end;

function TExportToDeviceThread.ActualOutputFile(const FileName: string): string;
begin
  if (FileName = FFileOprecord.TargetFile) and
    (FFileOprecord.CreatedOutputFile <> '') then
    Exit(FFileOprecord.CreatedOutputFile);
  Result := FileName;
  if FConvertBasic then
  begin
    if FExportMode = emEpub then Result := ChangeFileExt(FileName, '.epub')
    else Result := ChangeFileExt(FileName, '.fb2');
    Exit;
  end;
  // Raw books use the original-copy branch. Its extension must also be used
  // for collision checks; reserving a hypothetical converted name is unsafe.
  if not (FBookFormat in [bfFb2, bfFb2Archive]) then Exit;
  case FExportMode of
    emFB2Zip: Result := FileName + ZIP_EXTENSION;
    emLrf: Result := ChangeFileExt(FileName, '.lrf');
    emPDF: Result := ChangeFileExt(FileName, '.pdf');
    emMobi: Result := ChangeFileExt(FileName, '.mobi');
    emTxt: Result := ChangeFileExt(FileName, '.txt');
  end;
end;

function TExportToDeviceThread.ConvertBasicFile: Boolean;
var
  Warnings: TStringList;
begin
  Result := False;
  Warnings := TStringList.Create;
  try
    try
      ConvertBasicBook(FAppPath, FTempPath, FFileOprecord.SourceFile,
        FFileOprecord.SourceExtension, ActualOutputFile(FFileOprecord.TargetFile),
        FFileOprecord.Stream, Warnings,
        function: Boolean begin Result := Canceled or Terminated; end,
        FFileOprecord.BookTitle,FFileOprecord.BookAuthor,FFileOprecord.BookLanguage);
      FLastWarnings := Warnings.Text;
      Result := True;
    except
      on E: EAbort do
      begin
        Canceled := True;
        FLastError := E.Message;
      end;
      on E: Exception do FLastError := E.Message;
    end;
  finally
    Warnings.Free;
  end;
end;

procedure TExportToDeviceThread.RemoveConversionTempFolder;
var
  Root, Folder: string;
begin
  if FFileOprecord.ConversionTempFolder = '' then Exit;
  try
    Root := IncludeTrailingPathDelimiter(TPath.GetFullPath(FTempPath));
    Folder := TPath.GetFullPath(FFileOprecord.ConversionTempFolder);
    if Folder.StartsWith(Root, True) and
      ExtractFileName(Folder).StartsWith('homelib-export-') and
      DirectoryExists(Folder) and
      ((GetFileAttributes(PChar(Folder)) and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
      TDirectory.Delete(Folder, True);
  except
    // A failed cleanup must not turn a successfully written book into an error.
  end;
  FFileOprecord.ConversionTempFolder := '';
end;

function TExportToDeviceThread.ExportToFB2: boolean;
begin
  if FFileOprecord.Stream <> nil then
    Result := StreamToFile(FFileOprecord.TargetFile, FFileOprecord.Stream)
  else
   Result := unit_globals.CopyFile(FFileOprecord.SourceFile, FFileOprecord.TargetFile);
end;

function TExportToDeviceThread.ProcessFileFromStream: boolean;
begin
  Result := False;
  try

    case FExportMode of
         emFB2: if not ExportToFB2 then Exit;

      emFB2Zip: ExportToZip;

         emTxt: unit_globals.ConvertToTxt(FFileOprecord.TargetFile, FTXTEncoding, FFileOprecord.Stream);
    end;
    Result := True;
  except
    on E: Exception do
      FLastError := Format('ProcessFileFromStream exception: %s', [E.Message]);
  end;
end;

// Папки по шаблону создаются еще до конвертации, так что после неудачного
// при экспорте на устройства остаются пустые каталоги (#59). Убираем их,
// поднимаясь до DeviceDir; RemoveDir не трогает непустые папки, поэтому
// каталоги с уже записанными книгами уцелят.
procedure TExportToDeviceThread.RemoveEmptyTargetFolders;
var
  Root: string;
  Current: string;
begin
  if FUseMTP or FExtractOnly or (FFileOprecord.TargetFolder = '') then
    Exit;

  try
    Root := ExcludeTrailingPathDelimiter(FDeviceDir);
    Current := ExcludeTrailingPathDelimiter(TPath.Combine(FDeviceDir, FFileOprecord.TargetFolder));

    while (Length(Current) > Length(Root)) and
          SameText(Copy(Current, 1, Length(Root)), Root) and
          DirectoryExists(Current) do
    begin
      if not RemoveDir(Current) then
        Break;
      Current := ExcludeTrailingPathDelimiter(ExtractFilePath(Current));
    end;
  except
    // уборка не должна срывать экспорт
  end;
end;

function TExportToDeviceThread.SendFileToDevice: Boolean;
var
  TempFile: string;
  MTPTargetFolder: IShellItem;
  FreshRoot: IShellItem;
begin
  Result := False;
  FLastError := '';
  if Canceled or Terminated then Exit;

  if not FileExists(FFileOprecord.SourceFile) then
  begin
    FLastError := Format('Source not found: %s', [FFileOprecord.SourceFile]);
    ShowMessage(Format(rstrFileNotFound, [FFileOprecord.SourceFile]), MB_ICONERROR or MB_OK);
    Exit;
  end;

  if FUseMTP then
  begin
    if not Assigned(FDeviceShellItem) then
    begin
      FLastError := Format('DeviceShellItem is nil, DeviceDir=%s', [FDeviceDir]);
      Exit;
    end;
    MTPTargetFolder := ResolveOrCreateShellSubfolder(FDeviceShellItem, FFileOprecord.TargetFolder);

    if not Assigned(MTPTargetFolder) then
    begin
      // Оболочка Windows перечисляет папки MTP асинхронно: пока в Проводнике
      // видно "Working on it...", папка еще не готова - потомки кажутся
      // пустыми, а любая операция под ней возвращает E_UNEXPECTED.
      // Вручную это лечится повторным выбором папки в диалоге, так что делаем то
      // же программно: перечитываем корень по сохраненному пути и пробуем еще
      // раз. Делаем одну попытку без ожидания — этого достаточно для обхода чужой асинхронности.
      if Succeeded(SHCreateItemFromParsingName(PChar(FDeviceDir), nil, IShellItem, FreshRoot)) then
      begin
        MTPTargetFolder := ResolveOrCreateShellSubfolder(FreshRoot, FFileOprecord.TargetFolder);
        // Свежий корень работает - дальше пользуемся им, чтобы не повторять
        // это для каждой следующей книги.
        if Assigned(MTPTargetFolder) then
          FDeviceShellItem := FreshRoot;
      end;
    end;

    if not Assigned(MTPTargetFolder) then
    begin
      FLastError := Format('Failed to resolve/create MTP subfolder: %s', [FFileOprecord.TargetFolder]);
      Exit;
    end;
  end;

  if FConvertBasic then
  begin
    Result := ConvertBasicFile;
    if Result and FUseMTP then
    begin
      if Canceled or Terminated then Result := False
      else
      begin
        TempFile := ActualOutputFile(FFileOprecord.TargetFile);
        Result := ShellCopyFile(TempFile, MTPTargetFolder, ExtractFileName(TempFile));
        if not Result then
          FLastError := Format('Не удалось отправить книгу на устройство: %s',
            [ExtractFileName(TempFile)]);
      end;
    end;
    Exit;
  end;

  if FBookFormat in [bfFb2, bfFb2Archive] then
  begin
    case FExportMode of
        emFB2, emFB2Zip, emTxt: Result := ProcessFileFromStream;
    else
      Result := CallExternalConverter;
    end;

    if not Result then
    begin
      if FLastError = '' then
        FLastError := Format('ProcessFile failed, Mode=%d, Target=%s', [Ord(FExportMode), FFileOprecord.TargetFile]);
      Exit;
    end;

    if FUseMTP then
    begin
      // Send the same actual artifact used by collision checks and results.
      // TXT conversion writes .txt, while TargetFile retains the source .fb2.
      TempFile := ActualOutputFile(FFileOprecord.TargetFile);

      if not FileExists(TempFile) then
      begin
        FLastError := Format('Temp file not found: %s', [TempFile]);
        Result := False;
        Exit;
      end;

      Result := ShellCopyFile(TempFile, MTPTargetFolder, ExtractFileName(TempFile));
      if not Result then
        FLastError := Format('ShellCopyFile failed: %s -> %s\%s',
          [TempFile, FFileOprecord.TargetFolder, ExtractFileName(TempFile)]);
      DeleteFile(TempFile);
    end;
  end
  else
  begin
    // Книга из архива уже распакована в поток, а SourceFile указывает на сам архив -
    // копирование по SourceFile дало бы архив вместо книги.
    if FUseMTP then
    begin
      if FFileOprecord.Stream <> nil then
      begin
        if not StreamToFile(FFileOprecord.TempFile, FFileOprecord.Stream) then
        begin
          FLastError := Format('StreamToFile failed: %s', [FFileOprecord.TempFile]);
          Exit;
        end;

        Result := ShellCopyFile(FFileOprecord.TempFile, MTPTargetFolder, FFileOprecord.FileName);
        if not Result then
          FLastError := Format('ShellCopyFile failed: %s -> %s\%s',
            [FFileOprecord.TempFile, FFileOprecord.TargetFolder, FFileOprecord.FileName]);

        if FileExists(FFileOprecord.TempFile) then
          DeleteFile(FFileOprecord.TempFile);
      end
      else
      begin
        Result := ShellCopyFile(FFileOprecord.SourceFile, MTPTargetFolder, FFileOprecord.FileName);
        if not Result then
          FLastError := Format('ShellCopyFile failed: %s -> %s\%s',
            [FFileOprecord.SourceFile, FFileOprecord.TargetFolder, FFileOprecord.FileName]);
      end;
    end
    else
    begin
      if FFileOprecord.Stream <> nil then
      begin
        Result := StreamToFile(FFileOprecord.TargetFile, FFileOprecord.Stream);
        if not Result then
          FLastError := Format('StreamToFile failed: %s', [FFileOprecord.TargetFile]);
      end
      else
      begin
        Result := unit_globals.CopyFile(FFileOprecord.SourceFile, FFileOprecord.TargetFile);
        if not Result then
          FLastError := Format('CopyFile failed: %s -> %s', [FFileOprecord.SourceFile, FFileOprecord.TargetFile]);
      end;
    end;
  end;
end;

function TExportToDeviceThread.fb2Lrf(const InpFile: string; const OutFile: string): Boolean;
var
  params: string;
begin
  params := Format('-i "%s" -o "%s"', [InpFile, ChangeFileExt(OutFile, '.lrf')]);
  Result := unit_Globals.ExecAndWait(GetConverterPath(FAppPath, emLrf), params, SW_HIDE, FConverterExitCode,
    function: Boolean begin Result := Canceled or Terminated; end);
end;

function TExportToDeviceThread.fb2PDF(const InpFile: string; const OutFile: string): Boolean;
var
  params: string;
begin
  params := Format('"%s" "%s"', [InpFile, ChangeFileExt(OutFile, '.pdf')]);
  Result := unit_Globals.ExecAndWait(GetConverterPath(FAppPath, emPDF), params, SW_HIDE, FConverterExitCode,
    function: Boolean begin Result := Canceled or Terminated; end);
end;

function TExportToDeviceThread.fb2Mobi(const InpFile: string; const OutFile: string): Boolean;
var
  params: string;
begin
  params := Format('"%s" "%s" -nc -cl -us -nt', [InpFile, ChangeFileExt(OutFile, '.mobi')]);
  Result := unit_Globals.ExecAndWait(GetConverterPath(FAppPath, emMobi), params, SW_HIDE, FConverterExitCode,
    function: Boolean begin Result := Canceled or Terminated; end);
end;

procedure TExportToDeviceThread.Initialize;
begin
  inherited Initialize;
  FSystemData := DMUser.GetSystemDBConnection;
  Assert(Assigned(FSystemData));
  FTemplater := TTemplater.Create;

  if FUseMTP and Assigned(FMarshalStream) then
  begin
    CoGetInterfaceAndReleaseStream(FMarshalStream, IShellItem, FDeviceShellItem);
    // CoGetInterfaceAndReleaseStream принимает владение ссылкой, которую держит
    // FMarshalStream, и освобождает поток даже в случае ошибки. Обычное
    // присвоение nil вызвало бы Release ещё раз, на уже освобожденном потоке:
    // на ссылку приходилось два AddRef и три Release, так что экспорт падал с AV
    // в конце, когда ExportToDevice освобождал свою локальную переменную.
    // Обнуляем поле через Pointer, не освобождая его повторно.
    Pointer(FMarshalStream) := nil;
  end;
end;

procedure TExportToDeviceThread.Uninitialize;
begin
  FDeviceShellItem := nil;
  FTemplater.Free;
  FSystemData.ClearCollectionCache;
  inherited Uninitialize;
end;

procedure TExportToDeviceThread.WorkFunction;
var
  i: Integer;
  totalBooks: Integer;
  Res: Boolean;
  IsShowDialog: BOOL;
  ErrorLog: TStringList;
  LogFileName: string;
  FailedCount: Integer;
  WarningCount: Integer;
  FirstError: string;
begin
  IsShowDialog := True;
  FailedCount := 0;
  WarningCount := 0;
  FirstError := '';
  ErrorLog := TStringList.Create;
  try
    FProgressEngine.BeginOperation(Length(FBookIdList), rstrFilesProcessed, rstrFilesProcessed);
    try
      totalBooks := Length(FBookIdList);
      for i := 0 to totalBooks - 1 do
      begin
        if Canceled or Terminated then
          Break;

        FResults[i].State := besFailed;
        FResults[i].ErrorText := 'Обработка книги прервана до получения результата.';
        Res := PrepareFile(FBookIdList[i].BookKey, @FBookIdList[i]);
        if Res then
        begin
          // Scripts must receive the extracted or restored book, rather than
          // its archive or the original FB2 containing incompatible pictures.
          if FExtractOnly and Assigned(FFileOprecord.Stream) and
            ((FBookFormat in [bfFb2Archive, bfFbd, bfRawArchive]) or
            not (FFileOprecord.Stream is TFileStream)) then
          begin
            try
              var TempPrefix := Format('script-%d-%d-',
                [FBookIdList[i].BookKey.DatabaseID, FBookIdList[i].BookKey.BookID]);
              var TempName := ExtractFileName(FFileOprecord.TempFile);
              var TempExt := ExtractFileExt(TempName);
              FFileOprecord.TempFile := TPath.Combine(FTempPath, TempPrefix +
                Copy(ChangeFileExt(TempName, ''), 1,
                  FMaxTempPathLength - Length(TempPrefix) - Length(TempExt)) + TempExt);
              Res := StreamToFile(FFileOprecord.TempFile, FFileOprecord.Stream);
              if Res then
                FFileOprecord.SourceFile := FFileOprecord.TempFile
              else
                FLastError := Format('Не удалось подготовить файл для скрипта: %s',
                  [FFileOprecord.TempFile]);
            except
              on E: Exception do
              begin
                Res := False;
                FLastError := Format('Не удалось подготовить файл для скрипта: %s (%s)',
                  [FFileOprecord.TempFile, E.Message]);
              end;
            end;
          end;

          if Res then
          begin
            if not FExtractOnly Then Res := SendFileToDevice;
          end;
        end;

        // A successful copy remains successful if Cancel arrives immediately
        // afterwards. Preparation alone never acknowledges an external script.
        if Res then
        begin
          if FExtractOnly then
          begin
            FResults[i].State := besPrepared;
            FResults[i].OutputFile := FFileOprecord.SourceFile;
          end
          else
          begin
            FResults[i].State := besSucceeded;
            FResults[i].OutputFile := ActualOutputFile(FFileOprecord.TargetFile);
          end;
          if FProcessedFiles = '' then FProcessedFiles := FFileOprecord.SourceFile;
        end
        else if Canceled or Terminated then FResults[i].State := besCanceled
        else FResults[i].State := besFailed;
        FResults[i].ErrorText := FLastError;

        if FFileOprecord.Stream <> nil then
          FreeAndNil(FFileOprecord.Stream);
        RemoveConversionTempFolder;
        if FLastWarnings <> '' then
        begin
          Inc(WarningCount);
          ErrorLog.Add(Format('%s  |  %s  |  Примечания к конвертации:',
            [DateTimeToStr(Now), FFileOprecord.FileName]));
          ErrorLog.Add(FLastWarnings);
          Teletype(FFileOprecord.FileName + CR + FLastWarnings, tsWarning);
        end;
        if Canceled then
        begin
          RemoveEmptyTargetFolders;
          Break;
        end;

        if not Res then
        begin
          Inc(FailedCount);
          if FirstError = '' then
            FirstError := FFileOprecord.FileName + CR + FLastError;
          ErrorLog.Add(Format('%s  >>  %s  |  %s', [DateTimeToStr(Now), FFileOprecord.FileName, FLastError]));
          RemoveEmptyTargetFolders;

          if i < totalBooks - 1 then
          begin
            if IsShowDialog then
            begin
              Canceled := (ShowMessage(Format(rstrExportFileFailed, [FFileOprecord.FileName, FLastError]), MB_ICONQUESTION or MB_YESNO) = IDNO);
              if ShowMessage(rstrRememberChoise, MB_ICONQUESTION or MB_YESNO) = IDYES then
                IsShowDialog := False;
            end;
          end;
        end;

        FProgressEngine.AddProgress;
      end;

    finally
      FProgressEngine.EndOperation;
    end;

    if (FailedCount > 0) or (WarningCount > 0) then
    begin
      LogFileName := Settings.SystemFileName[sfExportErrorLog];
      if TFile.Exists(LogFileName) then
        TFile.AppendAllText(LogFileName, ErrorLog.Text, TEncoding.UTF8)
      else
        ErrorLog.SaveToFile(LogFileName, TEncoding.UTF8);
      if FailedCount > 0 then
        ShowMessage(Format(rstrExportErrors, [FailedCount, totalBooks, LogFileName]) +
          CR + CR + FirstError, MB_ICONWARNING or MB_OK)
      else if not Canceled then
        ShowMessage(Format(rstrExportWarnings, [LogFileName]), MB_ICONINFORMATION or MB_OK);
    end;
  finally
    FreeAndNil(FFileOprecord.Stream);
    RemoveConversionTempFolder;
    ErrorLog.Free;
  end;
end;

end.
