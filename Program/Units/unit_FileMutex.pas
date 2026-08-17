(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Межпроцессная блокировка файла книги на время перезаписи
  *
  * History
  *
  ****************************************************************************** *)

unit unit_FileMutex;

interface

type
  //
  // Именованный мьютекс, привязанный к конкретному файлу.
  //
  // Имя мьютекса зависит только от полного пути к файлу, поэтому два экземпляра
  // MyHomeLib (как и два потока одного экземпляра) получают один и тот же объект ядра
  // и никогда не переписывают книгу одновременно.
  //
  // Захват всегда неблокирующий: если файл уже занят другим процессом, книгу нужно
  // пропустить, а не ждать её.
  //
  TFileMutex = class
  private
    FHandle: THandle;
    FAcquired: Boolean;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;

    function TryAcquire: Boolean;
    procedure Release;

    property Acquired: Boolean read FAcquired;
  end;

implementation

uses
  Windows,
  SysUtils,
  System.Hash;

const
  MUTEX_PREFIX = 'MyHomeLib.File.';

//
// Имя объекта ядра не может содержать '\', а длина ограничена MAX_PATH, поэтому
// путь сворачивается в хеш. Регистр убираем: в Windows пути регистронезависимые.
//
function MutexNameFor(const FileName: string): string;
begin
  Result := MUTEX_PREFIX + THashMD5.GetHashString(AnsiLowerCase(ExpandFileName(FileName)));
end;

{ TFileMutex }

constructor TFileMutex.Create(const FileName: string);
begin
  inherited Create;
  FHandle := CreateMutex(nil, False, PChar(MutexNameFor(FileName)));
  FAcquired := False;
end;

destructor TFileMutex.Destroy;
begin
  Release;
  if FHandle <> 0 then
    CloseHandle(FHandle);
  inherited;
end;

function TFileMutex.TryAcquire: Boolean;
var
  WaitResult: DWORD;
begin
  if FAcquired then
    Exit(True);

  Result := False;
  if FHandle = 0 then
    Exit;

  WaitResult := WaitForSingleObject(FHandle, 0);
  //
  // WAIT_ABANDONED означает, что предыдущий владелец погиб, не освободив мьютекс.
  // Владение всё равно переходит к нам, поэтому это успех.
  //
  FAcquired := WaitResult in [WAIT_OBJECT_0, WAIT_ABANDONED];
  Result := FAcquired;
end;

procedure TFileMutex.Release;
begin
  if FAcquired then
  begin
    ReleaseMutex(FHandle);
    FAcquired := False;
  end;
end;

end.
