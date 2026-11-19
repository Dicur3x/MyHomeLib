# Contextual first-use guides for collection tools

Three more tool windows now have a permanent local question button:
selected/current/new-book compression, duplicate review, and metadata filling.
Sources and external scripts retain their existing inline guides.

The new owned modeless guide leaves the original fields and actions in place.
It explains the task, safe first steps and the relevant distinctions: estimate
versus application, original-book backups versus a full backup, candidate
duplicates versus identical editions, catalogue consolidation versus physical
deletion, and preview versus metadata writes.

## Behaviour

- Automatic display uses the shared per-topic/per-release preferences. Merely
  opening it does not save preferences or start a catalogue operation.
- Acknowledgement and closing the guide remember the release; suppression is
  separate for each tool. The question button can always reopen it.
- The automatic showing path uses SW_SHOWNOACTIVATE. A scoped native probe
  verifies the input component, active window and foreground application before
  and after the complete automatic show, including lazy construction.
  Manual opening can activate the guide for normal keyboard use.
- The guide fits the host monitor work area, wraps text and scrolls as needed.
  User resizing retains its chosen width. The common first-use panel reflows
  again if gaining/losing a vertical scrollbar changes its width during layout.
- The original tool hides its guide when it closes; ownership disposes of the
  popup with the host. Failed preference writes do not block the tool.
- More opens the exact local collections help anchors: compression, duplicates
  or metadata. Missing translated anchors retain the existing main-language
  fallback. Russian help and README describe the new entry points.

## Evidence

Final native builds:

| Architecture | CollectionViewsTest SHA-256 |
| --- | --- |
| Win64 | a0ea631f612338e44ac87154d902782d188856d67c5ce23686b436ba88470ffc |
| Win32 | 3c31a408ce80b370da67a30ecdd8db276a0ecdd8dffd057792748d7cb1f2ac69 |

Both architecture-specific guide gates cover three actual forms in both themes
at explicit 96/216-PPI layouts: twelve cases each. They verify automatic display
without focus/activation changes, text/action bounds, narrow user resizing,
acknowledgement, same-release repeat suppression, manual reopening despite
suppression, unavailable preference storage, unrelated preference preservation,
idle tool state and unchanged catalogue rows.

The final dark compression popup was inspected through Sky on x64 at explicit
225% layout scale. Text, actions and checkbox were readable without white bands.
This did not change Windows system DPI and is not a visual claim about every
form or x86. The inspected binary is recorded in visual-review.json.

Source binding:
G:/HL-b14-external/context-guides-validation-r1631/source-inputs.json
(695 repository inputs, production/native files matched against the G: build
mirror). A final binding check found one stale, unexecuted Python test in the
mirror (`test_prepare_book_compression.py`); it was reconciled separately.
Neither these UI gates nor the Main builds execute it. Its old/new hashes are
recorded in mirror-reconciliation.json; no compiled input changed.
The x64 guide run is tool-context-guides-Win64-r1640.
The x86 guide run is tool-context-guides-Win32-r1642-0.
All thirteen steps in context-guides-regressions-r1642/report.json passed:
the x86 guide and, on each architecture, existing metadata layout, duplicate
preference/preview/application, metadata UI entry, source UI, actual Scripts
menu entry and selected-book compression UI gates. Together with the x64 guide
this is fourteen native processes, including twenty-four focused guide cases.
The Sources UI mode deliberately waits for normal closing after its automatic
assertions; both private modal windows were observed and closed through Sky.
The same running cohort then continued. All fourteen private runtimes were
removed; their reports match the final fixture hashes above.
All 55 Russian help topics pass tools/help/check_help.js.

Both ordinary Main projects also built successfully with the new guides and
without the test probe. Feature strings and PE architectures were checked.
The original project remained unchanged and both owned IDE temporary folders
were removed. These binaries still have development beta-13 resources
(`3.0.0.13`); they are not release-ready beta-14 packages.

| Architecture | Main SHA-256 |
| --- | --- |
| Win64 | 6840890f9cf1d0b0d9567ec60c099d0f25179aec843749744045fb496d0592f6 |
| Win32 | a47853c9088966e77c505c76a8ba4364d87ceb01f88823318568c80560ce758c |

Build receipts: context-guides-main64-r1643 and context-guides-main32-r1643.
The bound aggregate is
G:/HL-b14-external/context-guides-validation-r1631/summary.json.

## Diagnostics

r1620 exposed unwanted focus activation in the first implementation. The popup
now has a dedicated passive showing path. r1622's delayed raw-HWND comparison
was affected by queued style/foreground changes; the final test instead compares
the actual input component and both native activation owners directly around
automatic display. Failure collection happens outside the timer callback, so
an assertion cannot strand a modal exception dialog.

r1623 ended without terminal IDE diagnostics at its 120-second bound and is
not a successful build. Successful subsequent builds have terminal reports.
r1632 found inflated metadata header widths: the helper queried parent geometry
while the original form was still assembling under disabled alignment.
Question-button creation is now deferred until the original controls are laid
out. r1635 and the final metadata layout regression passed.

r1637 found a clipped action after narrowing the guide caused a vertical
scrollbar to appear during panel layout. The shared panel now repeats layout
at the resulting width. The narrow-width assertion remains in the final gate.
Failed runs are retained as diagnostics, not counted as passing evidence.

This is a local Main UI change on private generated G: profiles. No E:,
user-library writes, Desktop replacement or publication are involved.
Final release Main/Reader builds, beta-14 packages and the remaining
contextual-help targets are separate work.

## Physical collection transfer

The transfer window has a topic-specific question button and a short first-use
guide for planning, destination and working folders, stopping and resuming.
An already registered transfer opens directly on its saved state. Its help is
available on demand. The expanded manual opens at `collections.html#transfer`.

The ordinary Sources → transfer workflow at 225% opened and closed this guide
before preview on Win32 and Win64, asserted that it did not enable the move or
overlap the introduction, then completed the move and checked the reader data.
Both native test binaries were rebuilt. Reports are under
`G:/HL-b14-external/r1989-transfer-context/workflow-{Win32,Win64}-apply`.

## Standalone guide window, 19 November

The previous x64 test executable reproduced the redundant question button. The
updated test checks that the host button opens the guide again after dismissal,
the popup contains no second question button, and the summary uses the full
text width. All 12 combinations of the three tools, both themes and 100%/225%
scaling passed on each of x86 and x64. Inline help in Scripts and Sources was
also exercised. Build receipts and native logs are in
`G:/HL-b14-external/r1993-guide-question`.

## Восстановление копии и источники обновлений, 19 ноября

Памятки открываются при первом входе и по кнопке «?». В проверенном плане
восстановления после закрытия памятки сохранились отчёт, введённое название
и путь к книгам. Ручное обновление списка по-прежнему требует заново проверить
копию. В окне источников после проверки INPX сохранились исходный текст отчёта,
подготовленный план и доступ к списку нужных архивов.

На x86 и x64 прошли сценарии `backup-restore` и `library-update-sources`.
Отдельно прошли все 40 сочетаний пяти инструментов, двух тем, масштабов 100%
и 225% и двух архитектур. Проверены первое и повторное открытие, фокус,
границы элементов и отсутствие «?» внутри отдельной памятки. Проверка справки
прошла для 55 тем. Обе обычные сборки HomeLibre и оба тестовых приложения
собраны. Отчёты сохранены в `G:/HL-b14-external/r1997-collection-guides`.

## Описание книги, 19 ноября

Оба обычных входа открывают ту же карточку. Пояснение источника текста
находится над редактором, и соседняя кнопка «?» ведёт к памятке этой вкладки.
Проверки охватывают исходное описание из FB2, предварительный просмотр EPUB,
загрузку с тестового сайта, сохранение, отмену и закрытие окна. В обоих
вариантах программы контрольная сумма исходной книги сохранилась.

Переключение на «Отзывы» и закрытие окна скрывают памятку. При возврате оба
черновика сохранились, а отмена правки описания оставила текст отзыва.
Проверка пройдена в обеих темах при 100% и 225%. В общей проверке подсказок
прошли 48 сочетаний шести инструментов, двух тем, двух масштабов и x86/x64.
Протоколы и сведения о сборках находятся в
`G:/HL-b14-external/r1998-description-guide/final`.

## Встроенные подсказки в скриптах и источниках

В обоих окнах «?» появляется у свёрнутой памятки. При раскрытии текст занимает
всю ширину. Если открыть памятку с клавиатуры, фокус переходит на «Понятно»,
а после нажатия возвращается на «?».

В настройках скриптов проверены оба состояния и фокус при шести масштабах от
100% до 300% в обеих темах. В источниках проверены первое раскрытие,
сворачивание после проверки INPX и повторное открытие. Для отдельных окон
подсказок прошли ещё 48 сочетаний. Обе версии приложения собраны.
Протоколы для x86 и x64 находятся в `G:/HL-b14-external/r2001-inline-guide`.
