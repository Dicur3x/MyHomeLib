unit unit_OperationErrorDialog;

interface

uses System.SysUtils, Winapi.Windows;

function WindowsFileErrorGuidance(Error: Exception): string;
function OperationErrorDetails(const Stage: string; Error: Exception): string;
procedure ShowOperationError(Owner: HWND; const Heading, Guidance, Details, LogDirectory: string);

implementation

uses Winapi.CommCtrl, Winapi.ShellAPI;

const
  COPY_DETAILS = 100;
  OPEN_LOG_DIRECTORY = 101;

type
  PErrorActions = ^TErrorActions;
  TErrorActions = record
    CopyText, LogDirectory: string;
  end;

function WindowsFileErrorGuidance(Error: Exception): string;
begin
  Result := '';
  if not (Error is EOSError) then Exit;
  case EOSError(Error).ErrorCode of
    ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION:
      Result := 'Файл занят. Закройте приложения, которые с ним работают, и повторите действие.';
    ERROR_ACCESS_DENIED:
      Result := 'Windows запретила доступ к файлу. Проверьте права на папку и повторите действие.';
    ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_NOT_READY:
      Result := 'Файл или папка недоступны. Проверьте путь и подключение диска.';
    ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL:
      Result := 'На диске недостаточно места. Освободите место и повторите действие.';
  end;
end;

function OperationErrorDetails(const Stage: string; Error: Exception): string;
begin
  Result := 'Этап: ' + Stage + sLineBreak + 'Тип ошибки: ' + Error.ClassName;
  if Error is EOSError then
    Result := Result + sLineBreak + 'Код Windows: ' + IntToStr(EOSError(Error).ErrorCode);
end;

function CopyErrorText(Window: HWND; const Value: string): Boolean;
var Memory: HGLOBAL; Buffer: Pointer; Bytes: NativeUInt;
begin
  Result := False;
  if not OpenClipboard(Window) then Exit;
  try
    Bytes := (NativeUInt(Length(Value)) + 1) * SizeOf(Char);
    Memory := GlobalAlloc(GMEM_MOVEABLE, Bytes);
    if Memory = 0 then Exit;
    try
      Buffer := GlobalLock(Memory);
      if Buffer = nil then Exit;
      Move(PChar(Value)^, Buffer^, Bytes);
      GlobalUnlock(Memory);
      if EmptyClipboard and (SetClipboardData(CF_UNICODETEXT, Memory) <> 0) then
      begin
        Memory := 0; // Windows now owns the clipboard data.
        Result := True;
      end;
    finally
      if Memory <> 0 then GlobalFree(Memory);
    end;
  finally
    CloseClipboard;
  end;
end;

function ErrorDialogCallback(Window: HWND; Notification: UINT; Button: WPARAM;
  Unused: LPARAM; Data: LONG_PTR): HRESULT; stdcall;
var Actions: PErrorActions; Feedback: string;
begin
  Result := S_OK;
  if Notification <> TDN_BUTTON_CLICKED then Exit;
  Actions := PErrorActions(Data);
  case Button of
    COPY_DETAILS:
      if CopyErrorText(Window, Actions.CopyText) then Feedback := 'Сведения скопированы.'
      else Feedback := 'Буфер обмена занят. Попробуйте ещё раз.';
    OPEN_LOG_DIRECTORY:
      if NativeInt(ShellExecute(Window, 'open', PChar(Actions.LogDirectory), nil, nil, SW_SHOWNORMAL)) > 32 then
        Feedback := 'Папка открыта.'
      else Feedback := 'Папка недоступна. Скопируйте сведения кнопкой выше.';
  else Exit;
  end;
  SendMessage(Window, TDM_SET_ELEMENT_TEXT, TDE_FOOTER, LPARAM(PChar(Feedback)));
  Result := S_FALSE; // Keep the explanation open after either action.
end;

procedure ShowOperationError(Owner: HWND; const Heading, Guidance, Details, LogDirectory: string);
var Config: TTaskDialogConfig; Buttons: array[0..1] of TTaskDialogButton;
  Actions: TErrorActions; Count: Integer; Text: string;
begin
  Config := Default(TTaskDialogConfig);
  Config.cbSize := SizeOf(Config);
  Config.hwndParent := Owner;
  Config.dwFlags := TDF_ALLOW_DIALOG_CANCELLATION or TDF_POSITION_RELATIVE_TO_WINDOW or
    TDF_USE_COMMAND_LINKS_NO_ICON;
  Config.dwCommonButtons := TDCBF_CLOSE_BUTTON;
  Config.nDefaultButton := IDCLOSE;
  Config.pszWindowTitle := 'HomeLibre';
  Config.pszMainIcon := TD_ERROR_ICON;
  Config.pszMainInstruction := PChar(Heading);
  Config.pszContent := PChar(Guidance);
  Config.pszExpandedInformation := PChar(Details);
  Config.pszExpandedControlText := 'Скрыть технические сведения';
  Config.pszCollapsedControlText := 'Показать технические сведения';

  Actions.CopyText := Heading + sLineBreak + Guidance + sLineBreak + sLineBreak + Details;
  Actions.LogDirectory := LogDirectory;
  Buttons[0].nButtonID := COPY_DETAILS;
  Buttons[0].pszButtonText := 'Скопировать сведения об ошибке';
  Count := 1;
  if (LogDirectory <> '') and DirectoryExists(LogDirectory) then
  begin
    Buttons[Count].nButtonID := OPEN_LOG_DIRECTORY;
    Buttons[Count].pszButtonText := 'Открыть папку диагностики';
    Inc(Count);
  end;
  Config.cButtons := Count;
  Config.pButtons := @Buttons[0];
  Config.pszFooter := 'Скопированные сведения можно приложить к сообщению об ошибке.';
  Config.pfCallback := ErrorDialogCallback;
  Config.lpCallbackData := LONG_PTR(@Actions);
  // The standalone updater does not otherwise load the common-controls DLL.
  InitCommonControls;
  if TaskDialogIndirect(Config, nil, nil, nil) = S_OK then Exit;

  Text := Heading + sLineBreak + sLineBreak + Guidance + sLineBreak + sLineBreak + Details;
  if Count > 1 then Text := Text + sLineBreak + LogDirectory;
  MessageBox(Owner, PChar(Text), 'HomeLibre', MB_OK or MB_ICONERROR);
end;

end.
