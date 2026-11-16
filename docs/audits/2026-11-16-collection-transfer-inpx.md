# Physical transfer followed by real full/append INPX

This gate uses the actual Main/VCL regression application, source refresh and
merge workers, compression operation, transfer coordinator and reviewed INPX
application workers. It does not enable the ordinary transfer command or mark
the whole transfer operation completed.

## Scenario

The existing bound-source fixture imports and merges two real INPX sources with
equally named archives in separate roots. Each archive contains an FB2 and an
EPUB. It compresses the four physical members, applies full/append lower-source
updates and checks that an incremental compression finds no unprocessed members.

The extension then releases the current fixture collection, builds the native
transfer inventory and immutable journal, runs group publication/removal, final
roots, cache installation and source/history cutover. Both complete archive
hashes must match their pre-transfer hashes, while exclusive original archives
must be absent. Retained book IDs, source-link keys, copy keys, measured sizes,
payload hashes, preferred source, ratings, progress, annotation and review must
remain unchanged. The former source directories are renamed offline inside the
private fixture. Only G: is accepted for this test.

A new incoming folder supplies an updated full INPX and one new archive. Further
full/append updates must keep both old copies readable without requesting their
old publisher archives or creating duplicate cards. Incremental compression
selects only the new member; the next pass skips all five physical members.
Updating the preferred source also retains physical payloads and keys. A forced
personal-size SQL failure rolls back the catalogue and personal store before the
same update succeeds. Favourite membership is checked at the end.

The outer validator independently decodes the resulting selected books and
unchanged neighbour with actual 7-Zip, verifies text/image content and checks that
exactly three cards remain. It supports both modern `7z.exe` and legacy `7za.exe`.

## Defect found and corrected

The first actual reviewed update failed before physical transfer. The code that
preserves source and review-key overrides selected `a.Key` from `ApplyActions`,
whose schema has no such column. Both full and append queries now join
`ReviewRows` by the incoming book ID and read `r.Key`, while retaining the
appropriate published-cache ID mapping for append updates. The source-key
column still comes from the apply actions.

A separate existing GUI assertion occasionally missed a short producer stage
between 50 ms timer ticks. The guarded regression executable now observes the
actual UTF-8-decoded producer stage through a test-only callback and atomic
counters. It still requires the expected Russian events and checks that a
no-arrivals run invokes no producer. Normal production builds contain no callback.

## Evidence

Final reports and source/binary bindings are recorded under
`G:/HL-b14-external/transfer-bound-update-validation-r1015`. Both private FB2/EPUB
fixtures use the verified beta-14 BookProcessing package and current image helper.
No user collection or Desktop installation is changed.

| Architecture | Final report | Result | Seconds |
|---|---|---|---:|
| Win64 | `transfer-bound-update-Win64-r1017` | PASS | 108.890 |
| Win32 | `transfer-bound-update-Win32-r1018` | PASS | 113.141 |
| Win64 | `compression-no-arrivals-observer-Win64-r1016` | PASS | 19.360 |

Final licensed IDE builds r1011/r1013 have SHA-256:

- Win64: `55d681d9567ec5a15e097b9cb52fdab53ea1ecc4b24eea57d943f903405f431b`.
- Win32: `c99e50235546c1656c3ecc9d4ab2f49070d006449c108c9b93488d4b4954f5c2`.

The final manifest records 636 source/resource/validator inputs. Both full
transfer/update cases and the no-arrivals regression removed their private
runtimes. The no-arrivals run uses the same native Win64 binary; its validator
predates only the explicit close in the transfer-only count check, a branch it
does not enter. Timings include private fixture setup and are not large-library
performance measurements.

Earlier diagnostic reports are preserved separately. r1000 was a launcher setup
failure before native execution. r1001 exposed the SQL defect. r1005/r1007 passed
the native transfer/update assertions but their outer decoder check still assumed
`7za.exe`; these are not full PASS reports. r1009 exposed the timer-sampling
assertion. r1010 completed the x86 gate before the test-only observation fix.
Only the final successful runs support the final gate claim.

r1012/r1014 passed the native and content checks, but the new outer card-count
check had used Python's SQLite transaction context without closing its connection.
That retained a handle through temporary-directory cleanup. The validator now
closes the connection explicitly in `finally`. The final reports above passed
cleanup too. Automatic approval review subsequently rejected the bounded cleanup
of those two earlier directories with `blocked by policy`, without a more
specific reason; no retry was attempted and those diagnostic directories remain.

## Remaining scope

This is a small bound-source FB2/EPUB scenario on the installed Windows/NTFS
volume. It does not prove a normal visible transfer command, pending-operation
startup routing, complete-operation acknowledgement, actual Reader position
migration, cleanup/space estimates, large-library performance, cross-volume or
other filesystems, unbound/empty-LIBID updates, or post-transfer FLibrary sidecar
and other format combinations. These remain release gates alongside final apps,
packages and beta 13-to-14 update validation.
