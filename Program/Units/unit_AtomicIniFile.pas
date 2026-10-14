unit unit_AtomicIniFile;

interface

uses System.IniFiles, System.Classes;

// Explicit saves must not fall back to the truncating destructor AutoSave path.
// On failure the in-memory changes remain Modified and the old file is retained.
procedure SaveMemIniFileAtomically(Ini: TMemIniFile);

// Publish the complete seekable stream without changing its current position.
// The stream remains owned by the caller; any read failure retains the old file.
procedure SaveStreamAtomically(Source: TStream; const FileName: string);

implementation

uses Winapi.Windows, System.SysUtils;

procedure RaiseIniSaveError(Code: DWORD; const FileName, RecoveryFile: string);
var Error: EOSError; Details: string;
begin
  Details := 'Не удалось сохранить настройки в "' + FileName + '": ' + SysErrorMessage(Code);
  if RecoveryFile <> '' then
    Details := Details + sLineBreak + 'Предыдущие данные сохранены в "' + RecoveryFile + '".';
  Error := EOSError.Create(Details); Error.ErrorCode := Code; raise Error;
end;

function IsMissingFileError(Code: DWORD): Boolean;
begin Result := (Code = ERROR_FILE_NOT_FOUND) or (Code = ERROR_PATH_NOT_FOUND); end;

procedure SaveMemIniFileAtomically(Ini: TMemIniFile);
var
  Lines: TStringList; Encoding: TEncoding; Stream: THandleStream;
  ID: TGUID; Target, Temporary, Backup, Recovery: string;
  Handle: THandle; Attributes, Code, TargetError: DWORD;
  OwnTemporary, OwnBackup: Boolean;
begin
  if not Assigned(Ini) then raise EArgumentNilException.Create('Ini');
  // Never retry a failed explicit atomic save through TMemIniFile.Destroy.
  Ini.AutoSave := False;
  if Ini.FileName = '' then raise EArgumentException.Create('Не указан файл настроек.');
  Target := ExpandFileName(Ini.FileName);
  if CreateGUID(ID) <> 0 then raise Exception.Create('Не удалось создать имя временного файла настроек.');
  Temporary := Target + '.homelib-ini-' + GUIDToString(ID) + '.tmp';
  Backup := Target + '.homelib-ini-' + GUIDToString(ID) + '.bak';
  // CREATE_NEW below owns only this file. A pre-existing backup is never ours.
  Attributes := GetFileAttributes(PChar(Backup));
  if Attributes <> INVALID_FILE_ATTRIBUTES then RaiseIniSaveError(ERROR_FILE_EXISTS, Target, '');
  Code := GetLastError;
  if not IsMissingFileError(Code) then RaiseIniSaveError(Code, Target, '');
  Handle := CreateFile(PChar(Temporary), GENERIC_READ or GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseIniSaveError(GetLastError, Target, '');
  OwnTemporary := True; OwnBackup := False;
  try
    try
      Lines := TStringList.Create;
      try
        Ini.GetStrings(Lines);
        Encoding := Ini.Encoding;
        Stream := THandleStream.Create(Handle);
        try Lines.SaveToStream(Stream, Encoding); finally Stream.Free; end;
      finally Lines.Free; end;
      // The complete adjacent replacement reaches storage before publication.
      if not FlushFileBuffers(Handle) then RaiseIniSaveError(GetLastError, Target, '');
    finally CloseHandle(Handle); end;

    Attributes := GetFileAttributes(PChar(Target));
    if Attributes = INVALID_FILE_ATTRIBUTES then
    begin
      Code := GetLastError;
      if not IsMissingFileError(Code) then RaiseIniSaveError(Code, Target, '');
      // If another writer creates the target meanwhile, do not overwrite it.
      if not MoveFileEx(PChar(Temporary), PChar(Target), MOVEFILE_WRITE_THROUGH) then
        RaiseIniSaveError(GetLastError, Target, '');
    end
    else
    begin
      if (Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_READONLY)) <> 0 then
        RaiseIniSaveError(ERROR_ACCESS_DENIED, Target, '');
      // Preserve ACLs, alternate streams and the previous complete file. The
      // documented partial-rename failure is recoverable because Backup exists.
      if not ReplaceFile(PChar(Target), PChar(Temporary), PChar(Backup), 0, nil, nil) then
      begin
        Code := GetLastError; Recovery := '';
        if GetFileAttributes(PChar(Backup)) <> INVALID_FILE_ATTRIBUTES then
        begin
          Attributes := GetFileAttributes(PChar(Target)); TargetError := GetLastError;
          Recovery := Backup;
          if (Attributes = INVALID_FILE_ATTRIBUTES) and IsMissingFileError(TargetError) then
            if MoveFileEx(PChar(Backup), PChar(Target), MOVEFILE_WRITE_THROUGH) then Recovery := '';
          // No replacement/deletion of a target that appeared during recovery.
          // A recovery backup is retained if it cannot be safely restored.
        end;
        RaiseIniSaveError(Code, Target, Recovery);
      end;
      OwnBackup := True;
    end;
    OwnTemporary := False; Ini.Modified := False;
  finally
    if OwnTemporary then Winapi.Windows.DeleteFile(PChar(Temporary));
    // Only a successful ReplaceFile owns a disposable previous-version backup.
    if OwnBackup then Winapi.Windows.DeleteFile(PChar(Backup));
  end;
end;

procedure SaveStreamAtomically(Source: TStream; const FileName: string);
var
  Stream: THandleStream; ID: TGUID; Target, Temporary, Backup, Recovery: string;
  Handle: THandle; Attributes, Code, TargetError: DWORD;
  OwnTemporary, OwnBackup: Boolean; Position, Count: Int64;

  procedure RaiseSaveError(ErrorCode: DWORD; const RecoveryFile: string);
  var Error: EOSError; Details: string;
  begin
    Details := 'Не удалось сохранить данные в "' + Target + '": ' + SysErrorMessage(ErrorCode);
    if RecoveryFile <> '' then
      Details := Details + sLineBreak + 'Предыдущие данные сохранены в "' + RecoveryFile + '".';
    Error := EOSError.Create(Details); Error.ErrorCode := ErrorCode; raise Error;
  end;

begin
  if not Assigned(Source) then raise EArgumentNilException.Create('Source');
  if FileName = '' then raise EArgumentException.Create('Не указан файл для сохранения.');
  Target := ExpandFileName(FileName); Position := Source.Position; Count := Source.Size;
  if (Position < 0) or (Count < 0) then raise EReadError.Create('Неверное положение или размер сохраняемых данных.');
  if CreateGUID(ID) <> 0 then raise Exception.Create('Не удалось создать имя временного файла данных.');
  Temporary := Target + '.homelib-data-' + GUIDToString(ID) + '.tmp';
  Backup := Target + '.homelib-data-' + GUIDToString(ID) + '.bak';
  Attributes := GetFileAttributes(PChar(Backup));
  if Attributes <> INVALID_FILE_ATTRIBUTES then RaiseSaveError(ERROR_FILE_EXISTS, '');
  Code := GetLastError;
  if not IsMissingFileError(Code) then RaiseSaveError(Code, '');
  Handle := CreateFile(PChar(Temporary), GENERIC_READ or GENERIC_WRITE, 0, nil,
    CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then RaiseSaveError(GetLastError, '');
  OwnTemporary := True; OwnBackup := False;
  try
    try
      Stream := THandleStream.Create(Handle);
      try
        try
          Source.Position := 0;
          if Count > 0 then Stream.CopyFrom(Source, Count);
        finally
          // Restore before publication: a failing seek cannot report success
          // after replacing an otherwise intact destination.
          Source.Position := Position;
        end;
      finally Stream.Free; end;
      if not FlushFileBuffers(Handle) then RaiseSaveError(GetLastError, '');
    finally CloseHandle(Handle); end;
    Attributes := GetFileAttributes(PChar(Target));
    if Attributes = INVALID_FILE_ATTRIBUTES then
    begin
      Code := GetLastError;
      if not IsMissingFileError(Code) then RaiseSaveError(Code, '');
      if not MoveFileEx(PChar(Temporary), PChar(Target), MOVEFILE_WRITE_THROUGH) then
        RaiseSaveError(GetLastError, '');
    end
    else
    begin
      if (Attributes and (FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_READONLY)) <> 0 then
        RaiseSaveError(ERROR_ACCESS_DENIED, '');
      if not ReplaceFile(PChar(Target), PChar(Temporary), PChar(Backup), 0, nil, nil) then
      begin
        Code := GetLastError; Recovery := '';
        if GetFileAttributes(PChar(Backup)) <> INVALID_FILE_ATTRIBUTES then
        begin
          Attributes := GetFileAttributes(PChar(Target)); TargetError := GetLastError;
          Recovery := Backup;
          if (Attributes = INVALID_FILE_ATTRIBUTES) and IsMissingFileError(TargetError) then
            if MoveFileEx(PChar(Backup), PChar(Target), MOVEFILE_WRITE_THROUGH) then Recovery := '';
        end;
        RaiseSaveError(Code, Recovery);
      end;
      OwnBackup := True;
    end;
    OwnTemporary := False;
  finally
    if OwnTemporary then Winapi.Windows.DeleteFile(PChar(Temporary));
    if OwnBackup then Winapi.Windows.DeleteFile(PChar(Backup));
  end;
end;

end.
