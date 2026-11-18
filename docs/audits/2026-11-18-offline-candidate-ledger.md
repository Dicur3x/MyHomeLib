# Reconciled offline component candidates

The earlier offline-input list r563 still selected the published LegacyBooks 5
and old processing helpers. These are not the candidates used by the later
sealed-format checks. The final distribution must use one explicit list rather
than infer current modules from the old staging folder or a developer runtime.

The reconciled candidate plans are:

- G:/HL-b14-external/offline-candidate-ledger-r1677/components-Win32.json
- G:/HL-b14-external/offline-candidate-ledger-r1677/components-Win64.json
- G:/HL-b14-external/offline-candidate-ledger-r1677/report.json

Each architecture has all 25 optional components. The candidate overrides to
r563 are:

| Component | Version | Existing sealed input |
| --- | --- | --- |
| BookProcessing | 3.0.0.14 | transfer-flibrary-modules-r1559 |
| ImageProcessing | 3.0.0.14 | format-modules-r1462/packages |
| XPS | 3.0.0.6 | format-modules-r1462/packages |
| LegacyBooks | 3.0.0.6 | legacy-books-packages-r1413 |
| KfxExport | 3.0.0.6 | kfx-cover-packages-r1504 |
| KindleExport | 3.0.0.9 | format-modules-r1462/packages |
| EpubPdfExport | 3.0.0.9 | format-modules-r1462/packages |

CRC and every manifest member's size/SHA-256 were verified: 1,272 files on
Win32 and 1,273 on Win64, 2,545 altogether. All 139 mapped local producer-source
comparisons per architecture match current source. This includes the nine
collection-packing workers and two catalogue-dump workers, whose installed
paths differ from their repository paths. Image/XPS runtime descriptors bind
the current shared C# source and static-GIF API; XPS also binds OpenXpsNative.cs.

The unchanged inputs retain their recorded package hashes. The ledger records
component identity and architecture, not just a version number. It does not
download modules or substitute unsealed files from the developer's runtime.

## Reconciliation attempts

r1673 correctly detected the obsolete legacy_helper.py in the old r563 list.
The current helper had already been sealed and tested in LegacyBooks 6 r1413;
the sealed writer r1464/r1465 explicitly selected it. Repacking current XPS 6
and LegacyBooks 6 reproduced those existing archives byte for byte on both
architectures. These are identity checks, not four new functional test passes.
The final plans use the existing tested archives. Intermediate r1673/r1675/
r1676 lists are superseded by r1677, which also verifies the mapped workers.
The three owned duplicate-package/workspace directories were then removed;
duplicate-candidate-cleanup-r1685.json retains the equality checks and original
archive hashes. The retained candidate plans reference none of those removed
directories.

Existing evidence remains separate: sealed-writer-validation-r1467,
sealed-all-formats-validation-r1469, kfx-cover-package-validation-r1505 and
transfer-flibrary-update-validation-r1565. The old r691 BookProcessing archive
must not replace r1559; the r691 image helper predates the static-GIF API.

## Still open

The plans deliberately retain the currently available Reader 3.0.0.13 and are
labelled CANDIDATE_LEDGER_ONLY. They are not final beta-14 installation inputs.
Replace Reader with its checked final beta-14 package, update the component
feed/release identity, then perform the final native install/remove/update and
minimal/full distribution gates. No clean-Windows prerequisite installation,
offline GUI proof, Desktop replacement or publication is established here.

All preparation is on G:. No E: input or user-library modification is involved.
