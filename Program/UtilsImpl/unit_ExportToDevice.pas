(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Authors Oleksiy Penkov   oleksiy.penkov@gmail.com
  *         Nick Rymanov     nrymanov@gmail.com
  *
  ****************************************************************************** *)

unit unit_ExportToDevice;

interface

uses
  Controls, System.SysUtils,
  Forms,
  Dialogs,
  Windows,
  ShlObj,
  unit_Globals,
  unit_BookExportResults;

procedure ExportToDevice(
  const DeviceDir: string;
  const IdList: TBookIdList;
  const Mode: TExportMode;
  const ExtractOnly: Boolean;
  out ProcessedFiles: string;
  const ADeviceShellItem: IShellItem = nil;
  const AUseMTP: Boolean = False;
  const ExplicitFormat: Boolean = False;
  const OnMissingComponent: TProc<string> = nil
  ); overload;

procedure ExportToDevice(
  const DeviceDir: string;
  const IdList: TBookIdList;
  const Mode: TExportMode;
  const ExtractOnly: Boolean;
  out ProcessedFiles: string;
  out Results: TBookExportResults;
  const ADeviceShellItem: IShellItem = nil;
  const AUseMTP: Boolean = False;
  const ExplicitFormat: Boolean = False;
  const OnMissingComponent: TProc<string> = nil
  ); overload;

procedure DownloadBooks(const IdList: TBookIdList);
function DownloadBooksForExport(const IdList: TBookIdList): Boolean;

implementation

uses
  ActiveX,
  dm_user,
  unit_Consts,
  unit_Errors,
  unit_ExportToDeviceThread,
  frm_ExportToDeviceProgressForm,
  unit_DownloadBooksThread,
  frm_DownloadProgressForm;

resourcestring
  rstrSendToDevice = 'Отправить на устройство';
  rstrExportAsFormat = 'Экспорт в %s';
  rstrDownloadingBooks = 'Скачивание книг';
  rstrConverterNotFound = 'Не установлен конвертер для выбранного формата:' + CRLF +
    '%s' + CRLF + CRLF +
    'Распакуйте файлы конвертера в эту папку или выберите другой формат записи ' +
    'на устройстве в настройках.';

procedure ExportToDevice(
  const DeviceDir: string;
  const IdList: TBookIdList;
  const Mode: TExportMode;
  const ExtractOnly: Boolean;
  out ProcessedFiles: string;
  const ADeviceShellItem: IShellItem;
  const AUseMTP: Boolean;
  const ExplicitFormat: Boolean;
  const OnMissingComponent: TProc<string>
  );
var Ignored: TBookExportResults;
begin
  ExportToDevice(DeviceDir, IdList, Mode, ExtractOnly, ProcessedFiles, Ignored,
    ADeviceShellItem, AUseMTP, ExplicitFormat, OnMissingComponent);
end;

procedure ExportToDevice(
  const DeviceDir: string;
  const IdList: TBookIdList;
  const Mode: TExportMode;
  const ExtractOnly: Boolean;
  out ProcessedFiles: string;
  out Results: TBookExportResults;
  const ADeviceShellItem: IShellItem;
  const AUseMTP: Boolean;
  const ExplicitFormat: Boolean;
  const OnMissingComponent: TProc<string>
  );
var
  worker: TExportToDeviceThread;
  frmProgress: TExportToDeviceProgressForm;
  MarshalStream: IStream;
  ConverterPath, Required: string;
begin
  ProcessedFiles := ''; Required:='';
  Results := PendingBookExportResults(IdList);
  // FB2/EPUB используют встроенный конвертер. Старые режимы LRF/PDF/MOBI
  // по-прежнему проверяют наличие своего внешнего инструмента до запуска.
  if not ExtractOnly then
  begin
    ConverterPath := GetConverterPath(Settings.AppPath, Mode);
    if (ConverterPath <> '') and not FileExists(ConverterPath) then
    begin
      MHLShowError(rstrConverterNotFound, [ConverterPath]);
      Exit;
    end;
  end;

  worker := TExportToDeviceThread.Create;
  try
    worker.DeviceDir := DeviceDir;
    worker.BookIdList := IdList;
    worker.ExportMode := Mode;
    worker.ExtractOnly := ExtractOnly;
    worker.UseMTP := AUseMTP;
    worker.ExplicitFormat := ExplicitFormat;

    if AUseMTP and Assigned(ADeviceShellItem) then
    begin
      if Succeeded(CoMarshalInterThreadInterfaceInStream(IShellItem, ADeviceShellItem, MarshalStream)) then
        worker.MarshalStream := MarshalStream;
    end;

    frmProgress := TExportToDeviceProgressForm.Create(Application);
    try
      if ExplicitFormat then
      begin
        if Mode = emEpub then
          frmProgress.Caption := Format(rstrExportAsFormat, ['EPUB'])
        else
          frmProgress.Caption := Format(rstrExportAsFormat, ['FB2']);
      end
      else
        frmProgress.Caption := rstrSendToDevice;
      frmProgress.WorkerThread := worker;
      frmProgress.ShowModal;
    finally
      frmProgress.Free;
    end;
    ProcessedFiles := worker.ProcessedFiles; Required:=worker.RequiredComponent;
    if Assigned(worker.FatalException) then
    begin
      if worker.FatalException is Exception then
        raise Exception.Create('Экспорт остановлен: ' + Exception(worker.FatalException).Message)
      else raise Exception.Create('Экспорт остановлен из-за ошибки обработки.');
    end;
  finally
    try
      Results := worker.Results;
    finally worker.Free; end;
  end;
  if (Required<>'') and Assigned(OnMissingComponent) then OnMissingComponent(Required);
end;

procedure DownloadBooks(const IdList: TBookIdList);
begin
  DownloadBooksForExport(IdList);
end;

function DownloadBooksForExport(const IdList: TBookIdList): Boolean;
var
  worker: TDownloadBooksThread;
  frmProgress: TDownloadProgressForm;
begin
  Result := False;
  worker := TDownloadBooksThread.Create;
  try
    worker.BookIdList := IdList;
    frmProgress := TDownloadProgressForm.Create(Application);
    try
      frmProgress.Caption := rstrDownloadingBooks;
      frmProgress.WorkerThread := worker;
      frmProgress.ShowModal;
    finally
      frmProgress.Free;
    end;
    Result := not worker.Canceled and not Assigned(worker.FatalException);
  finally
    worker.Free;
  end;
end;


end.
