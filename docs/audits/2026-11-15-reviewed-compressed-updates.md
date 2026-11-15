# Reviewed INPX updates after real catalogue compression

Added an integration gate for the ordinary catalogue, connecting the actual
menu compression command to reviewed INPX application and subsequent
incremental compression. No product logic changed in this step: the existing
size-restoration and history mechanisms passed this composed flow.

## Verified flow

- Compress two books through the ordinary main-window selection command.
  Verify the resulting archive, personal progress and prepared Reader cache.
- Make the verified optional original backup unavailable to the application.
- Apply a full INPX containing original publisher sizes twice through the real
  review/apply workers and concrete confirmation. Verify retained payload
  hashes, actual sizes, Reader preparation, progress and compression history.
- Run the same incremental operation/factory used by the main command. It
  selects zero books and reports both prior books already processed.
- Add an illustrated FB2 in a new archive in a separate downloads directory;
  apply the new full index. Incremental processing selects exactly this one
  book, preserves its text, changes only its archive and records its history.
- Refresh the actual main catalogue and verify its visible new size before
  acknowledging durable compression jobs. Prepare the updated reading file.
- Apply full and append INPX with original sizes again. Verify both retained
  archives, the downloaded book's size/history and an empty incremental plan
  with three previously processed books. All jobs are acknowledged.

The FB2-only case additionally retains the actual legacy full-import gate and
its eleven physical-identity/rollback boundaries. The mixed case uses FB2 and
EPUB in the same shared ZIP, and independently compares EPUB text, styles,
fonts and member order in Python. The unselected neighbour remains byte-exact.

An initial mixed fixture used a tiny transparent PNG with colour retained. Its
FB2 correctly stayed unchanged, but the older UI assertion required that first
payload to change (`update-compressed-mixed-Win64-r379`). The final fixture uses
a larger RGB image to exercise a real colour compression; cache behaviour was
not altered to satisfy that assertion.

## Evidence

| Platform | Fixture | Native run | Result | Seconds |
|---|---|---|---|---:|
| Win64 | FB2, legacy + reviewed | `update-compressed-Win64-r375` | PASS | 45.829 |
| Win32 | FB2, legacy + reviewed | `update-compressed-Win32-r377` | PASS | 38.312 |
| Win64 | FB2 + EPUB, reviewed | `update-compressed-mixed-Win64-r381` | PASS | 68.531 |
| Win32 | FB2 + EPUB, reviewed | `update-compressed-mixed-Win32-r382` | PASS | 71.078 |

Build receipts: r374/r376 and r378/r380 respectively. The final mixed binaries:

- Win64: `2b9ea70c6da439b3f1ff7eb544bf22cf2d2e8438f3791093b26cfe500b3fb8e1`.
- Win32: `00975784a4748eadadbfa7b8879d1644d4a34c9aeeb744e194e7523b230c08ad`.

Exact packages, hashes, logs and all four build/test receipts are collected in
`G:/HL-b14-external/update-compressed-validation-r383/summary.json`.
All four successful private runtimes were removed. Timings include application
startup and private setup; they do not estimate multi-terabyte performance.

## Remaining scope

This gate prepares reading files and checks personal percentage; it does not
visually reopen a Reader window or test a physical reading device. Bound-source
copies, packed catalogues, FLibrary/JPEG XL external image sets and earlier
history formats require their own composed update gates. Current same-name
archive changes without index metadata changes, production-scale measurements,
final packages, Desktop replacement and the beta 14 release remain open.
