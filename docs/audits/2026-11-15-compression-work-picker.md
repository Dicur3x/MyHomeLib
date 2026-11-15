# Work-folder selection through the ordinary compression window

On x86 and x64, the ordinary selected-book command used the folder chosen with
Computer Use in Windows' actual folder dialog, completed compression and showed
the same saved path when reopened. Canceling that reopened window changed
neither the remembered options/recovery registry nor the compressed archive.
No production-code change was needed for this gate.

## Actual workflow

The isolated catalogue selects two generated FB2 books in one ZIP. For this
optional inspection mode, the 1,288,077-byte source lives in a new owned C:
folder and is exposed under the portable G: fixture through an owned directory
junction. The test verifies its resolved target and different Windows volume
identity. It does not point at a user's collection. Preparation, backup and
profile stay on G:; system-drive guards remain enabled.

The native driver seeds economy/grayscale, per-archive review and an original
backup, then waits in the real options window with an initial C: work path.
Computer Use clicks the work-folder Browse button, selects the expected empty
G: parent in the actual `Где хранить временные файлы сжатия` dialog and confirms.
The application displays its appended `HomeLibre-compression-work` child and
updates the free-space explanation from C: to G:. Computer Use starts the
ordinary preparation command. It does not inject the selected path into the
application's edit or substitute a file-dialog result in code.

The existing native workflow reviews/applies the actual prepared archive. It
checks the preserved original backup, personal reading progress, refreshed
visible row size and Reader cache. It reads back the persisted work path,
reopens the **same Main action**, verifies the displayed path and cancels.
Registry/preference bytes and source SHA-256 must remain unchanged on cancel.
The Python parent independently checks all non-image FB2 content and the exact
unselected neighbour. Both complete profiles and their separate C: source
folders were removed. No Desktop or published package was changed.

## Evidence and limits

Reports are under `G:/HL-b14-external/`:

| Run | Result |
| --- | --- |
| `work-picker-Win64-r634` | PASS, ordinary UI/menu/picker, real compression, saved path/reopen/cancel, independent content checks and teardown. 279.844 seconds includes Computer Use interaction. |
| `work-picker-Win32-r636` | Corresponding PASS with x86 tools/runtime; 128.531 seconds includes Computer Use interaction. |

The ZIP decreased to 127,560 bytes on both architectures. These are not speed
or startup benchmarks. In the x64 interaction the helper's indexed folder-field
input/focus reporting was unreliable; screenshot-based input on the actual
popup worked. A later stale-window capture occurred after the native workflow
had already closed normally with exit code zero; the final report is PASS.

Fresh fixture builds verify PE architecture, the linked inspection marker and
unchanged project files:

- `work-picker-build-Win64-r633`:
  `ef558b439334b03cc7596429c5ccf17c6ae8f5ab160023aacea25a22cfef177e`.
- `work-picker-build-Win32-r635`:
  `1db47f771ef00ffbf07ed72c87857db7a247a43592e6ab5721d50f54588b0fee`.

This verifies the ordinary Main/forms compiled into the guarded regression
application, with real Windows interaction and actual files. It does not claim
final beta-14 production EXE/package verification, physical power-loss testing,
other archive/image layouts or a large-collection benchmark. Those gates remain
separate from this completed work-folder selection/persistence check.
