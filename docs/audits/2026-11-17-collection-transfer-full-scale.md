# Full native transfer scale workflow

The earlier million-row binding-memory runs stopped after group publication and
source removal. The new standalone benchmark exercises the next boundaries too:
two independent retained cache versions, source/history publication, final roots,
durable whole-operation completion in a fresh process and byte-exact replay in a
third process. The native application readiness callback is a fixture; this is
not ordinary Main-window or release-package evidence.

The isolated fixture has two tiny ZIP carriers, three initial main book rows,
ratings/progress/notes/reviews/groups, bound and unbound histories and retained
cache/index files. Extra rows are inserted into the main catalogue and source A's
retained baseline; source B's separate small history is kept. All data/temp/output
is on G:, E: is unused, and C: is checked for the 8 GiB reserve. Each native
process has its own explicit 2 GiB commit budget. Rows and file hashes are read
incrementally rather than collecting a million-row Python table.

## Independent checks

- Main/personal user tables and cached book/relationship tables retain their
  non-locator columns. Derived Search* columns are allowed to refresh. Root and
  source/history settings have separate checks; installed-cache Settings are
  outside the generic row guard. Original cache/index/neighbor bytes must remain
  unchanged.
- Each transferred destination is under the chosen folder and has the original
  carrier SHA-256; its old carrier is gone. Final collection root equals the
  frozen layout and is inside the chosen folder, allowing source subfolders.
- Both newly installed cache versions open the expected book through the actual
  native archive reader, with source-specific expected content hashes.
- For every cached row, a separate Python calculation compares effective source
  keys, review keys and publisher locations before/after. It includes overrides
  needed when a missing book's absolute locator falls outside the relocated
  source root. New auxiliary tables are checked rather than treated as user-data
  loss or silently omitted. Original auxiliary tables are absent in this fixture;
  this script is not an importer for arbitrary external user databases.
- Completion must record both removed files and zero pending operations. A fresh
  process then returns the same result without changing any catalogue/cache/state
  database bytes; user-data and protected-original guards are repeated.

## Small setup proof

Win64 r1199 and Win32 r1200 pass with 2,003 main/source-A books, three source-B
books and all three native phases. Native totals are 54.218/50.203 seconds, six
calls combined. Both private runtimes were removed. The source-A update guard
checks 2,003 identities, the source-B guard three; source B needs one saved source
key override. Cache/source/history and final completion receipts pass. Replaying
the completed result leaves database files byte-exact.

`G:/HL-b14-external/transfer-full-smoke-validation-r1201/summary.json` records
652 matching source/resource/test/benchmark inputs. The script SHA-256 is
`31d495c9a842e3c48c17cc95537b5d00d913f73864f534580654d766fb1ac569`;
native binaries are the final personal-receipt binaries r1189/r1191.

Earlier harness failures are retained: r1194 compared a junction alias against
the resolved source path before any native call; r1195/r1197 treated the three
new derived update tables as unexpected user data; r1198 assumed the catalogue
root was the flat chosen folder. The final checks validate the derived identities
and the frozen child-root layout explicitly. These failed drafts are not passing
application gates.

## Large runs pending

Win64 r1202 and Win32 r1203 use the same script and native binaries with 1,000,003
main/source-A rows. Their outcomes, peak memory and allocation are not yet known.
No real large archive throughput, all-format reading, ordinary UI, mounted-volume
failure behavior or final update/release package is established by this fixture.
Desktop binaries and user libraries have not been changed.
