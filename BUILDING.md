# Как собрать MyHomeLib в `exe`

Инструкция рассчитана на человека, который не пишет на Delphi. Ниже описан
реально проверенный путь для **RAD Studio / Delphi 13 Trial**, конфигурации
**Release** и платформы **Windows 64-bit**.

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
- `MHLMcpServer.exe` — вспомогательный MCP-сервер;
- `Icons\MHLIcons.dll` — значки интерфейса;
- каталог `Help` — встроенная справка;
- файлы `genres_*.glst` — штатные списки жанров.

Для Win32 аналогичная папка называется `Program\Out\Bin`, но ниже используется
рекомендуемый современный вариант Win64.

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
- **Target Platforms: Windows 64-bit**.

Для сборки текущего проекта нажимайте **Shift+F9**. После успешной сборки Delphi
показывает окно `Success`; предупреждения допустимы, но `Errors` должно быть 0.

Соберите проекты в таком порядке:

1. `Program\Resources\Icons\MHLIcons.dproj` — создаёт
   `Program\Resources\Icons\Win64\MHLIcons.dll`.
2. `Program\MyhomeLib.dproj` — создаёт `Program\Out\Bin64\MyHomeLib.exe` и
   автоматически копирует рядом каталоги `Help` и `Icons`.
3. `Utils\MHLMcpServer\MHLMcpServer.dproj` — создаёт
   `Program\Out\Bin64\MHLMcpServer.exe`.

После каждого проекта его можно закрыть и на вопрос о сохранении автоматически
изменённых файлов ответить **No**. Пользовательские настройки IDE для сборки не
нужны.

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

Сценарий проверяет разрядность EXE, SQLite, MCP-сервера и DLL значков, проверяет
справку, копирует списки жанров и выводит SHA-256 основных файлов. Он не
перезаписывает уже существующий отличающийся файл без предупреждения.

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

В полной лицензии Delphi после установки зависимостей можно открыть
**RAD Studio Command Prompt** и собирать проекты по отдельности:

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

### Программа запускается без иконок

Убедитесь, что рядом с EXE есть `Icons\MHLIcons.dll`, а затем повторно соберите
`Program\MyhomeLib.dproj`, чтобы его завершающий шаг скопировал актуальную DLL.

## Проверенная конфигурация

18 августа 2026 года этот порядок был проверен на RAD Studio 13 Trial:

- `Release`, `Windows 64-bit`;
- Virtual Treeview 8.3 из GetIt;
- отдельная сборка DLL значков, основной программы и MCP-сервера;
- основной проект: `Success`, 0 ошибок;
- MCP-сервер: `Success`, 0 ошибок;
- `MyHomeLib.exe` определён как Win64 PE, справка содержит 224 файла, DLL
  значков в выходной папке совпадает с собранной по SHA-256;
- после добавления официальной x64 `sqlite3.dll` программа запускается и
  показывает русскоязычный мастер создания коллекции;
- встроенная проверка `MHLMcpServer.exe --cache-selftest` полностью проходит
  и завершается кодом 0;
- все MCP-протокольные, поисковые, FB2, fixture- и cache-тесты проходят; их
  эталоны русских сообщений синхронизированы с программой.

Конвертеры FB2 → MOBI/EPUB/PDF и некоторые программы чтения являются отдельными
сторонними продуктами. Для сборки и первого запуска MyHomeLib они не нужны.
