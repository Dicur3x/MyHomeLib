# Real collection export matrix follow-up

The new backend matrix exercised one bounded real source for each of 26
content-detected input families on x86/x64. It covers 11 converter/writer
directions, distinct from native TXT, FB2.ZIP and unchanged-source saving.
Original archives were read only; exact extracted payload hashes match the
previous catalogue sample. The runner is
`tools/ui/tests/collection_export_matrix.py`.

Baseline reports are `G:/HL-b14-external/collection-export-Win64-r1364/report.json`
and `collection-export-Win32-r1365/report.json`. Each contains 249 successful
backend outputs, 36 failures and one native PDF identity-path placeholder: 572
cells across both architectures. Source aliases and unknown/nested/nonbook inputs
remain explicit pending rows. Passing backend validation alone does not establish
complete output content. Those baseline reports bind the pre-fix source overlay
and runner digest, before its additional empty-audit guard.

## Three repaired causes

**EPUB language casing.** Real book 712586 uses `UND`. Kindling rejects that case
in its publishing validator, blocking both MOBI and AZW3. Language tags are
[case-insensitive under RFC 5646 section 2.1.1](https://www.rfc-editor.org/rfc/rfc5646.html#section-2.1.1).
The private Kindle input now uses conventional language/script/region casing,
including extension and private-use subtags. It neither guesses a language nor
rewrites invalid values into a different tag. The original book/catalogue stays
unchanged; publishing checks are not disabled.

**Empty DOCX textbox.** Book 809647 has an empty, unfilled and unstroked VML
textbox, with paragraph properties but no drawing or visible text. It previously
blocked every direction as an unsupported drawing. That specific invisible
container can now be omitted from the flow adaptation. Text, symbols, fields,
painted shapes, background styles and unknown shape children do not match the
empty-container rule. Positive and refusal fixtures cover these boundaries.
See Microsoft's [Filled](https://learn.microsoft.com/en-us/windows/win32/vml/msdn-online-vml-filled-attribute),
[Stroked](https://learn.microsoft.com/en-us/windows/win32/vml/msdn-online-vml-stroked-attribute)
and [TextBox](https://learn.microsoft.com/en-us/windows/win32/vml/msdn-online-vml-textbox-element)
definitions.

**KEPUB XHTML syntax.** Generated ODT/Word EPUBs can legitimately use an XHTML
namespace prefix and empty XML paragraphs. Kepubify's HTML parser treated those
tags as foreign containers and nested the rest of the document into them. The
ODT output grew from depth 5 to 482 and failed validation; DOCX could pass that
depth limit while still containing nested HTML/body elements. Increasing the
global XML limits would not fix the malformed structure.

The Kobo path now prepares a private EPUB with default XHTML namespace and paired
non-void tags. Actual SVG, MathML, EPUB and XLink namespace bindings survive a
writer's root replacement. Other resources/OPF are retained byte for byte in
this preparation. Kindle and Kobo share the QName-binding helper in the core
converter. An older core requests BookProcessing before the Kindle writer runs,
instead of failing with a missing-function exception. Final packages must ship
the matching BookProcessing and a newly versioned KindleExport, not overwrite
the already published module asset.

## Content evidence and limits

Final focused reports are
`G:/HL-b14-external/collection-export-fixes-Win64-r1378/report.json` and
`collection-export-fixes-Win32-r1379/report.json`. Each passes 14 outputs:

- The real EPUB to MOBI/AZW3, followed by KindleUnpack/EPUB readback. All 34,323
  source words remain in order and the cover's dimensions/RGBA pixels match.
  The encoded JPEG metadata differs; this is not byte-identity of that resource.
- All 11 backend directions for the real DOCX. Eight additionally pass independent
  content inspection/readback, preserving all 18,993 source words in order.
  KFX, AZW8 and PDF pass their production validators but still need independent
  content inspection in this cohort.
- The real ODT to KEPUB: all 17,117 source words stay in order, referenced image
  pixels match and the exported chapter has one HTML/body pair.

Totals are 22 content-checked outputs and six backend-only outputs across the
two architectures. Unit evidence includes 31 text-input methods, the subsequent
stricter textbox guard check, 14 current HTML/Kindle methods and an additional
old-core repair check. Do not add repeated runs as new unique tests.

The initial focused checks r1370/r1371 and diagnostic r1372 used an overstrict
oracle: soft hyphens split words and JPEG metadata changes failed byte comparison
despite identical pixels. The oracle now models DOCX tabs/breaks, ignores
discretionary hyphens when comparing words and checks decoded image pixels.
Those failed oracle attempts are retained separately; r1374/r1375 then identified
the remaining malformed KEPUB before the final syntax repair. The first r1376
unit invocation also had an import-path error; r1377 is the passing invocation.

`G:/HL-b14-external/export-matrix-validation-r1380/summary.json` binds baseline
and final reports, current production source hashes and test evidence. Its status
explicitly retains remaining gaps. All private processing runtimes were removed;
small diagnostic copies/reports remain on G:. E: was unused and C: retained its
8 GiB reserve. No Desktop application or public release changed.

## Still open

The baseline CHM reports a missing `page/width=4` resource. The LIT reports a
missing `/data/RW_~Cover01/content` entry. Investigate the actual source/decoder
conventions before classifying these as damaged books or implementing repairs.
Also pending are the unclassified/nested inputs, current native Reader and
ordinary save-dialog coverage, remaining independent output checks, cancellation,
final module/app packages and the full reading/export matrix requirements in
[the coverage plan](2026-11-17-reading-export-coverage.md).
