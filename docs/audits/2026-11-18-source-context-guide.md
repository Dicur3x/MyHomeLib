# Sources window contextual guidance

The sources window now reuses the inline first-use guide already used by script
settings. It explains INPX versus the book folder, source priority and duplicate
rules, the check/add sequence, the difference between catalogue merging and
physical relocation, and where to check new releases. The existing always-visible
intro is replaced, rather than adding a second introduction.

The explanation expands once per release until acknowledged. Acknowledgement
collapses it, the question-mark button reopens it, and automatic expansion can be
disabled. Opening or acknowledging the guide does not refresh an index, copy any
books, alter the source selection or invalidate a completed source preview.
The body scrolls in a short window while the existing action footer remains fixed.
Library update profiles already have their own targeted help; no duplicate guide
was added to that window.

More opens collections.html#sources in the installed help language with the
existing fallback. Windows converts the filename into a file URL before the
fragment is added, so spaces, Cyrillic names, percent signs and literal hash signs
in an installation path do not become a different filename or fragment.

## Defect found during integration

The first native source-window run found a zero-width heading during hidden-form
construction. Copying that width into the new guide produced a zero-width panel
and a very tall explanation. Layout now derives the heading and guide width from
the header client area with a bounded design minimum, instead of trusting the
intermediate anchor width. The failing r1523/r1529 reports are retained; r1531
passes. An initially missing release-version unit was fixed before native runs.

## Native checks

The licensed IDE rebuilt CollectionViewsTest on both architectures in
source-guide-native-build-Win64-r1530 and source-guide-native-build-Win32-r1530.
Projects were unchanged and owned IDE temporary directories were removed.

| Platform | Native fixture SHA-256 |
| --- | --- |
| Win64 | c3771b777135173a366691339b0e577a94d28514fc1049671ee6c91fe3314908 |
| Win32 | 2b83b5c643026ed2d76eda1178e96a24ef9738bf86db0536004ba2e0195828ce |

Reports under G:/HL-b14-external/source-guide-validation-{Win64,Win32}-r1531:

| Mode | PASS markers per architecture | Relevant scope |
| --- | ---: | --- |
| catalog-sources | 9 | Actual source form, acknowledgement/reopen, retained preview, collapsed next visit, both themes, narrow/short layouts including 216 PPI (225%), scrolling and local help URL |
| catalog-sources-workflow | 6 | Existing multi-source review/state changes; protected rows, schema and profile remain unchanged |
| settings-script-entry | 14 | Existing main-menu entry to script settings, remembered guide and modal activation across themes and scales |
| catalogue-palettes | 5 | Existing per-theme colours and shared guide per-release/opt-out/preferences regression |

All eight mode runs exited zero: 68 PASS markers in total. Each mode used a fresh
private runtime and test profile on G:, and all eight runtimes were removed.
The frozen driver is G:/HL-b14-external/source-guide-validation-r1531.py.
The navigation sentence was then shortened to name the Update library toolbar
button correctly. Inspection also found that the old bg/en/uk help pages do not
yet contain the sources anchor. HelpTopicPath now retains a translation when the
requested section exists, and otherwise uses the base-language page. Ordinary
page help keeps its translation. The focused native source-window scenario was
rebuilt after those changes; it checks missing page, missing section, translated
single-quoted section ID, ordinary translated help, URL encoding, and the same
source guide/state/layout behaviour. The x64 UI variant was also opened and
inspected through Computer Use in collapsed and expanded states, then closed
without applying any collection change. These are normal-scale visual checks;
225% coverage comes from the native layout assertions, not that screenshot.

Final focused reports:
- G:/HL-b14-external/source-guide-validation-Win64-r1537/report.json
- G:/HL-b14-external/source-guide-validation-Win32-r1535/report.json

Final production build evidence is recorded separately from both fixture cohorts.

The built-in help checker passes all 55 topics, including the existing sources
anchor. This change does not close guidance for every other tool, final packaged
UI validation, beta13-to-beta14 installation or release publication. Desktop and
public release assets are unchanged; E: was not used and C: retained its reserve.

## Current production Main integration

Both current Main projects compiled after the final help fallback and wording
changes. Linked markers verify inclusion of the source guide and SVG cover reader;
the 11 recorded relevant source/help/resource hashes match the G: build mirror.

| Platform | Main SHA-256 |
| --- | --- |
| Win64 | 796ca9af33deace72d37e6f3c2c645128eda8b7fa7d8c9c22d8a830a2e412a63 |
| Win32 | bcd8683b68911c182b3281e29430fdf7853f6a48f9f28d56e0ea592e93c6754f |

Consolidated evidence: G:/HL-b14-external/source-guide-integration-r1539/report.json.
The projects stayed unchanged and both owned IDE temporary directories were
removed. Resources deliberately remain 3.0.0.13 during development. This is not a
beta14 release package, Reader rebuild, installation test or Desktop replacement.
