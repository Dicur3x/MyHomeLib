# Compression with source and working folder on different volumes

The native compression operation passed a small real C: source / G: workspace
fixture on x86 and x64. Stores, preparation, job queue and selected-original
backup stayed on G:. No production-code change was needed for these cases.

## Scope and independent checks

Each test creates a new owned 25,706-byte ZIP on C:, with one generated FB2 and
an unselected neighbour. The actual Windows volume device identities must
differ from the G: fixture. The system-drive reserve is checked before creation
and after processing; the source fixture is bounded below 2 MiB. The native
replacement may use its small same-volume atomic-replacement file beside the
source; bulk preparation and the persistent recovery journal use the chosen G:
workspace. No user collection or existing source file is modified.

The apply case uses the real packaged image/preparation tools and native
worker. It checks full non-size catalogue and personal rows, including reviews,
annotation/notes BLOBs, progress, other collection and relationships. The actual
payload size must match the catalogue, personal card and alternate copy. The
unselected neighbour stays byte-identical. An independent 7-Zip extraction and
XML comparison retain all non-image FB2 content and image identifiers while
confirming a changed selected payload.

The selected-original backup on G: must contain the exact original FB2. The
completed job is deliberately left unacknowledged. A **new native process**
recovers it from G: and acknowledges it; the approved C: archive, both G: stores
and original backup must retain their complete hashes. This is a native-worker
restart, not an ordinary Main-window restart or GUI folder-picker test.

The other two cases stop during review, or actually terminate the private
worker before approval and recover its abandoned preparation. Both retain the
source and stores byte-for-byte, publish no backup or changed book, and remove
only their own G: preparation. After every case both owned C: and G: fixture
directories are verified absent. The parent verifies its complete runtime was
removed as well.

## Evidence

Reports are under `G:/HL-b14-external/`; each successful run has `operation.json`,
`operation.log` and `operation.cross-volume.json`.

| Run | Result |
| --- | --- |
| `cross-volume-Win64-r627` | All three cases PASS, 24.984 seconds including setup/teardown. The apply case did not yet contain the added independent XML comparison. |
| `cross-volume-text-Win64-r629` | Harness error: Python's ZIP reader cannot decode the actual PPMd selected member. This is not a product failure. Both owned fixtures were removed. |
| `cross-volume-text-Win64-r630` | Strengthened apply/backup/fresh-process-recovery case PASS with independent 7-Zip/XML comparison, 9.484 seconds. The other two cases are unchanged from r627. |
| `cross-volume-Win32-r631` | Rejected input runtime before testing: its 7-Zip executable was x64. No second-volume source was created; the private runtime was removed. |
| `cross-volume-Win32-r632` | Correct x86 runtime; all three cases PASS including the strengthened content comparison, 21.172 seconds. |

Both architectures decreased the archive from 25,706 to 18,064 bytes. This is
not a performance measurement or a test of a large collection. All passing
reports have no skipped tests, errors or failures. Windows volume identities
were `17460144345740248359` for C: and `1222319865189979966` for G:.

Fresh native builds used the licensed IDE and verified the actual PE platform,
linked marker and unchanged project file:

- x64, `cross-volume-build-Win64-r626`:
  `0628e39665930d51264fc5e2953e9ad3a106258277d17955617109bb6f74a60c`.
- x86, `cross-volume-build-Win32-r628`:
  `4e3ebcba20b123de2aba27ca09663d937acddc6d3488c42b6385174fa23a5e5d`.

The reports retain exact package/runtime hashes, including 7-Zip 26.05 and
BookProcessing 3.0.0.14. Current G: and source Pascal text was compared before
building: only one obsolete project-name comment differed; other byte
differences were BOM/line-ending normalization in the build copy.

Final GUI selection/persistence in the production distributions and remaining
formats/layouts remain separate release gates. Nothing was published or
replaced on Desktop by these tests.
