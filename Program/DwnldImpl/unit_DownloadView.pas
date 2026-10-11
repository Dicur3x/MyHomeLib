(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Інтерфейс доступу потоку завантаження до інтерфейсу користувача
  *
  * History
  *
  ****************************************************************************** *)

unit unit_DownloadView;

interface

uses
  unit_Globals;

type
  // Потік бачить лише ці дані - жодних вузлів дерева та інших об'єктів VCL,
  // час життя яких він не контролює.
  TDownloadItem = record
    BookKey: TBookKey;
    Author: string;
    Title: string;
  end;

  // Реалізує головна форма. Потік звертається до методів виключно через
  // Synchronize, тому жоден елемент керування не чіпається з фонового потоку.
  // Черга завантажень (дерево tvDownloadList) лишається за формою: саме вона
  // володіє вузлами, тримає курсор поточної книги та оновлює лічильник.
  IDownloadView = interface
    ['{6C1B0C4E-2A83-4E2F-9F3D-7A8B5D0E4C11}']

    // False - у черзі більше нічого немає.
    function SelectNextDownload(out Item: TDownloadItem): Boolean;

    // Успішну книгу прибрати з черги, помилкову лишити.
    procedure CompleteCurrentDownload(Success: Boolean);

    procedure CancelCurrentDownload;

    function IsMainFormVisible: Boolean;
    procedure ShowDownloadInfo(const Author, Title: string);
    procedure ShowDownloadState(const State: string);
    procedure ShowDownloadProgress(Position: Integer);

    procedure ResetDownloadState;

    procedure SetTrayHint(const Hint: string);

    procedure SetDownloadRunning(Running: Boolean);

    // Під час завантаження недоступні.
    procedure SetQueueControlsEnabled(Enabled: Boolean);

    // Викликається лише через Synchronize.
    function AskIgnoreDownloadErrors: Integer;
  end;

implementation

end.
