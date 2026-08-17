(* *****************************************************************************
  *
  * MyHomeLib
  *
  * Copyright (C) 2008-2026 Oleksiy Penkov (aka Koreec)
  *
  * Author(s)           Oleksiy Penkov  oleksiy.penkov@gmail.com
  * Created             25.07.2026
  * Description         Интерфейс доступа потока загрузки к пользовательскому интерфейсу
  *
  * History
  *
  ****************************************************************************** *)

unit unit_DownloadView;

interface

uses
  unit_Globals;

type
  //
  // Книга, которую менеджер загрузок сейчас обрабатывает.
  //
  // Поток видит только эти данные — никаких узлов дерева и других объектов VCL,
  // жизненный цикл которых он не контролирует.
  //
  TDownloadItem = record
    BookKey: TBookKey;
    Author: string;
    Title: string;
  end;

  //
  // Все, что поток загрузки делает с пользовательским интерфейсом.
  //
  // Реализует главная форма. Поток обращается к методам исключительно через
  // Synchronize, поэтому ни один элемент управления не трогается из фонового потока.
  //
  // Очередь загрузок (дерево tvDownloadList) остается за формой: именно она
  // владеет узлами, держит курсор текущей книги и обновляет счетчик.
  //
  IDownloadView = interface
    ['{6C1B0C4E-2A83-4E2F-9F3D-7A8B5D0E4C11}']

    //
    // Очередь
    //

    // Выбрать следующую книгу для загрузки и отметить её активной.
    // False - в очереди больше ничего нет.
    function SelectNextDownload(out Item: TDownloadItem): Boolean;

    // Завершить активную книгу: успешную убрать из очереди, ошибочную оставить.
    procedure CompleteCurrentDownload(Success: Boolean);

    // Отметить активную книгу как прерванную пользователем.
    procedure CancelCurrentDownload;

    //
    // Отображение состояния
    //

    function IsMainFormVisible: Boolean;
    procedure ShowDownloadInfo(const Author, Title: string);
    procedure ShowDownloadState(const State: string);
    procedure ShowDownloadProgress(Position: Integer);

    // Вернуть панель загрузки в исходное состояние.
    procedure ResetDownloadState;

    procedure SetTrayHint(const Hint: string);

    // Состояние кнопок «Начать»/«Пауза».
    procedure SetDownloadRunning(Running: Boolean);

    // Кнопки сортировки и удаления очереди: при загрузке недоступны.
    procedure SetQueueControlsEnabled(Enabled: Boolean);

    //
    // Запрос к пользователю. Вызывается только через Synchronize.
    //
    function AskIgnoreDownloadErrors: Integer;
  end;

implementation

end.
