# Как собрать MyHomeLib в `exe`

Инструкция рассчитана на человека, который не пишет на Delphi. Ниже описан
реально проверенный путь для **RAD Studio / Delphi 13 Trial**, конфигурации
**Release** и платформ **Windows 32-bit и Windows 64-bit**.

## Самое важное

- Из исходников проект собирается только компилятором Delphi с VCL. Free Pascal
  и обычный Visual Studio для этого проекта не подходят.
- В Trial-версии командная сборка отключена, поэтому проекты нужно собирать в
  окне Delphi. Это ограничение лицензии Trial, а не ошибка проекта.
- Не открывайте `Program\MHL.groupproj` в Trial: в проверенной Delphi 13 Trial
  проверка зависимостей группы завершалась сбоем IDE. Три нужных проекта
  надёжнее собрать по одному, как описано ниже.
- Если RAD Studio нет, самый простой вариант — получить у разработчика уже
  собранную папку `Bin64` целиком. Один `MyHomeLib.exe` без соседних файлов —
  неполная поставка.

## Что получится

Готовая 64-битная папка находится в `Program\Out\Bin64`. Для полноценной
поставки в ней должны быть:

- `MyHomeLib.exe` — основная программа;
- `sqlite3.dll` — движок базы данных той же разрядности;
- `libzstd.dll` — распаковка каталогов нового формата metabib;
- `MHLMcpServer.exe` — вспомогательный MCP-сервер;
- `Icons\MHLIcons.dll` — значки интерфейса;
- каталог `Help` — встроенная справка;
- файлы `genres_*.glst` — штатные списки жанров.

Для Win32 аналогичная папка называется `Program\Out\Bin`. Сначала обычно
собирают Win64, а затем повторяют те же шаги с платформой Windows 32-bit.

## 1. Один раз установите зависимости

1. Установите **RAD Studio 13 / Delphi 13 (Studio 37.0)**. В установщике должны
   быть отмечены Delphi, VCL и платформа Windows 64-bit.
2. В Delphi откройте **Tools → GetIt Package Manager**, найдите
   **Virtual Treeview (Latest Version)** и установите пакет. В проверенной
   сборке использовалась версия 8.3. После установки перезапустите Delphi.
3. Компоненты Konopka/Raize (`BonusKSVC`, `RzPanel` и подобные) больше не нужны:
   проект переведён на стандартные компоненты VCL.
4. Скачайте с [официальной страницы SQLite](https://www.sqlite.org/download.html)
   архив `sqlite-dll-win-x64-...zip` и распакуйте `sqlite3.dll` в удобную
   временную папку. Для Win32 нужен архив `sqlite-dll-win-x86-...zip`.
5. Node.js необязателен. Если он установлен, перед сборкой обновляются
   дополнительные языковые ресурсы. Без Node.js используется уже находящийся
   в репозитории ресурс, и сборка не прерывается.

## 2. Соберите три проекта в Delphi Trial

Каждый раз используйте **File → Open Project**, затем в правой панели проверьте:

- **Build Configurations: Release**;
- **Target Platforms: Windows 64-bit** (либо **Windows 32-bit** для второй
  сборки).

Для сборки текущего проекта нажимайте **Shift+F9**. После успешной сборки Delphi
показывает окно `Success`; предупреждения допустимы, но `Errors` должно быть 0.

Соберите проекты в таком порядке:

1. `Program\Resources\Icons\MHLIcons.dproj` — создаёт
   `Program\Resources\Icons\Win64\MHLIcons.dll`.
2. `Program\MyhomeLib.dproj` — создаёт `Program\Out\Bin64\MyHomeLib.exe` и
   автоматически копирует рядом каталоги `Help`, `Icons` и нужную
   `libzstd.dll`.
3. `Utils\MHLMcpServer\MHLMcpServer.dproj` — создаёт
   `Program\Out\Bin64\MHLMcpServer.exe`.

После каждого проекта его можно закрыть и на вопрос о сохранении автоматически
изменённых файлов ответить **No**. Пользовательские настройки IDE для сборки не
нужны.

Для Win32 повторите этот порядок, выбрав **Windows 32-bit**. Результаты будут
находиться в `Program\Resources\Icons\Win32` и `Program\Out\Bin`.

Пакет `Components\MHLComponents\MHLComponents.dproj` для обычного EXE собирать
не требуется: используемые программой модули компонентов подключены к EXE
напрямую. Пакет нужен только разработчику, который хочет устанавливать эти
компоненты в палитру дизайнера форм.

## 3. Добавьте SQLite и проверьте всю папку

Откройте PowerShell в корне репозитория. Сначала запустите безопасную проверку,
подставив свой путь к распакованной DLL:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-runtime.ps1 `
  -Platform Win64 `
  -SqliteDll "C:\Downloads\sqlite3.dll"
```

Если проверка прошла, повторите команду с `-Copy`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-runtime.ps1 `
  -Platform Win64 `
  -SqliteDll "C:\Downloads\sqlite3.dll" `
  -Copy
```

При повторной сборке в папке `Bin`/`Bin64` могут остаться старые копии SQLite
или списков жанров. Чтобы явно заменить только проверяемые сценарием файлы их
актуальными версиями, добавьте `-Force`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\prepare-runtime.ps1 `
  -Platform Win64 `
  -SqliteDll "C:\Downloads\sqlite3.dll" `
  -Copy `
  -Force
```

Сценарий проверяет разрядность EXE, SQLite, zstd, MCP-сервера и DLL значков,
проверяет справку, копирует списки жанров и выводит SHA-256 основных файлов. Он не
перезаписывает уже существующий отличающийся файл без явных `-Copy -Force`.

Теперь запустите:

```text
Program\Out\Bin64\MyHomeLib.exe
```

При первом запуске должно появиться русское окно «Мастер создания коллекции».
Для переноса на другой компьютер копируйте всю папку `Bin64`, а не только EXE.

Необязательная встроенная проверка MCP-сервера запускается так:

```powershell
.\Program\Out\Bin64\MHLMcpServer.exe --cache-selftest
```

Успешный результат завершается кодом 0 и содержит `"pass":true` для всех
проверок.

## 4. Сборка из командной строки

В установленной Trial-версии этот способ **не работает**: компилятор выводит
`This version of the product does not support command line compiling`. У Trial
нет финальных консольных компиляторов — это также описано в
[справке Embarcadero](https://docwiki.embarcadero.com/Support/en/%E2%80%9CThis_version_of_the_product_does_not_support_command_line_compiling%E2%80%9D_with_a_valid_Delphi_10.1_Berlin_license).

Полностью собрать этот проект вообще без Delphi нельзя: он использует
компилятор Delphi и библиотеку VCL. В полной лицензии Delphi можно не открывать
тяжёлую IDE, а запустить **RAD Studio Command Prompt** и собрать проекты
по отдельности:

```bat
msbuild Program\Resources\Icons\MHLIcons.dproj /t:Build /p:Config=Release /p:Platform=Win64 /nologo /v:minimal
msbuild Program\MyhomeLib.dproj /t:Build /p:Config=Release /p:Platform=Win64 /nologo /v:minimal
msbuild Utils\MHLMcpServer\MHLMcpServer.dproj /t:Build /p:Config=Release /p:Platform=Win64 /nologo /v:minimal
```

Обычный терминал может не содержать переменные и пути Delphi, поэтому для
этого варианта нужен именно RAD Studio Command Prompt.

## 5. Как получить установщик

Для собственного использования достаточно проверенной папки `Bin64`. Если
нужен установщик:

1. Установите [Inno Setup 6](https://jrsoftware.org/isinfo.php).
2. Сначала полностью подготовьте папку `Bin64`, как описано выше.
3. Из корня проекта выполните `Installer\build_installer.cmd x64`.

Варианты команды: `x86`, `x64` или `all`. Результат появляется в
`Installer\Out`.

## Частые ошибки

### Не найден `VirtualTrees`, `VirtualTreesD` или `VirtualTreesR`

Virtual Treeview не установлен для Delphi 13 либо Delphi не была перезапущена
после GetIt. Установите пакет заново и не используйте готовые DCU/BPL от другой
версии Delphi.

### Delphi Trial падает при открытии или сборке группы

Не используйте `Program\MHL.groupproj`. Закройте Delphi и соберите три `.dproj`
по отдельности в порядке из раздела 2.

### Ошибка завершающего шага `copy_help`, `copy_icons` или `post_build`

Проверьте, что проект значков был собран первым и существует файл
`Program\Resources\Icons\Win64\MHLIcons.dll`. Для копирования справки также
нужен штатный `C:\Windows\System32\robocopy.exe`.

### Программа сообщает, что не найдена `sqlite3.dll`

DLL не скопирована рядом с `MyHomeLib.exe` либо имеет другую разрядность.
Повторите раздел 3 и используйте именно x64-DLL для Win64.

### Импорт metabib сообщает, что не найдена `libzstd.dll`

Сначала снова соберите `Program\MyhomeLib.dproj`: завершающий шаг копирует
`Program\Resources\zstd\Win32` или `Win64\libzstd.dll` рядом с EXE. Не
копируйте DLL другой разрядности — `prepare-runtime.ps1` это обнаружит.

### Программа запускается без иконок

Убедитесь, что рядом с EXE есть `Icons\MHLIcons.dll`, а затем повторно соберите
`Program\MyhomeLib.dproj`, чтобы его завершающий шаг скопировал актуальную DLL.

Если при запуске появляется сообщение о ресурсе вроде
`LIGHT_FILETYPE_FILETYPE_FB2`, DLL значков устарела. Снова соберите сначала
`Program\Resources\Icons\MHLIcons.dproj`, затем `Program\MyhomeLib.dproj`.
Файлы `Program\Resources\Icons\Win64\MHLIcons.dll` и
`Program\Out\Bin64\Icons\MHLIcons.dll` после этого должны совпадать.

## Проверенная конфигурация

29 августа 2026 года этот порядок был повторно проверен на RAD Studio 13 Trial:

- `Release`, `Windows 32-bit` и `Windows 64-bit`;
- Virtual Treeview 8.3 из GetIt;
- отдельная сборка DLL значков, основной программы и MCP-сервера;
- обе DLL значков: `Success`, 0 ошибок и 0 предупреждений;
- оба основных проекта: `Success`, 0 ошибок и 0 предупреждений;
- оба MCP-сервера: `Success`, 0 ошибок и 0 предупреждений;
- `prepare-runtime.ps1` подтвердил правильную разрядность и полный набор
  зависимостей в `Bin` и `Bin64`, включая SQLite, zstd и DLL значков;
- изолированный запуск обеих версий открывает русское главное окно и настройки
  без ошибки `Stream read error`; в x64 дополнительно проверены окно
  «О программе» и замена поискового запроса через `Ctrl+A`;
- встроенная проверка `MHLMcpServer.exe --cache-selftest` полностью проходит
  и завершается кодом 0;
- все MCP-протокольные, поисковые, FB2, fixture- и cache-тесты проходят в x32
  и x64; тесты работают на отдельной библиотеке из шести книг и не используют
  пользовательские коллекции.

Конвертеры FB2 → MOBI/EPUB/PDF и некоторые программы чтения являются отдельными
сторонними продуктами. Для сборки и первого запуска MyHomeLib они не нужны.
