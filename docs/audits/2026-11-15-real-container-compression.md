# Real ODT/DOCX/CBZ books: selection and copy compression

## Scope and inputs

Following `0c495305`, three actual payloads were selected read-only from the
working merged catalogue. No write to the working catalogue, personal store or
source archives was performed. SQLite used an immutable read-only connection with an empty WAL
and an unchanged catalogue file identity/size/mtime. Only bounded exact archive
members were copied, after checking the source archives' size/mtime/identity.
This is not a full cryptographic hash of the original collection archives.

Selection evidence is
`G:/HL-b14-external/real-container-inputs-r668/inputs.json`. Its three isolated
payloads total 4,832,913 bytes. They remain intact and are deliberately retained
for the next full-catalogue-copy trial, rather than reading the user archives
again. All native operation/runtime temporary directories were removed.

| Actual book ID | Format | Selected JPEG/PNG images | Original book bytes |
| --- | --- | ---: | ---: |
| 848368 | DOCX | 38 | 1,048,434 |
| 773527 | ODT | 5 | 655,616 |
| 757989 | CBZ | 23 | 3,128,863 |

The working-catalogue selection took 1.078 seconds. Sources were opened for
reading only. Large files, profiles, prepared books and diagnostics stay on G:;
C: remained above the required 8 GiB reserve.

## Native selection results

Each real payload was put in a private shared archive and passed through the
packaged worker and native publication operation on x86/x64. The stores in
these particular tests are synthetic fixtures; the full 4.5 GB working
catalogue has not yet been cloned and written by this check.

All three books became smaller with economy quality plus grayscale. The tests
verify the actual grayscale pixels of every eligible image, unchanged
non-image contents, neighboring book, non-size catalogue/personal fields,
measured sizes, full original backup and native `GetBookStream` readback. A
repeat and a changed worker identity reuse the already-processed payloads
without another encode or rewriting the book, personal-data or backup bytes.
The ordinary repeat also leaves the stores unchanged; the engine-identity
change retains their non-size semantic data while acknowledging new history.

| Format | Original | Win64 result | Win32 result | Approximate saving |
| --- | ---: | ---: | ---: | ---: |
| DOCX | 1,048,434 | 951,302 | 951,302 | 9.3% |
| ODT | 655,616 | 313,073 | 313,106 | 52.2% |
| CBZ | 3,128,863 | 2,896,607 | 2,896,607 | 7.4% |

The small architecture-dependent ODT byte difference is allowed: each result's
structure, text, metadata and grayscale pixels were independently checked.
These sample savings are not an estimate for the whole collection.

## Copy and incremental results

The copy test runs the installed `pack_collection.py` with the actual embedded
Python for its architecture, using the verified image helper and 7-Zip. It does
not substitute the host Python for the copy worker. A Python audit hook counts
images passed to real `--export-images` calls without replacing the codec.

A private mixed archive contains the three real books, identical stems with
different extensions, and a neighboring text file. The sequence checks:

1. Initial preparation encodes 66 images, produces smaller books and exact
   non-image contents, and records their measured sizes.
2. An unchanged repeat encodes zero images and preserves the prepared books.
3. A new archive adds another DOCX: only its 38 images are encoded. Another
   repeat encodes zero images.
4. A new CBZ is appended to the old archive and added to the plan. Only its
   23 images are encoded; all old compressed books survive byte-exact. The
   final repeat again encodes zero images.

Input hashes are checked between the test's deliberate updates. The actual
user archives' metadata and the isolated original-payload hashes remain
unchanged. New outputs pass the separate content-preservation gate and pixel
checks. The copy backend leaves a prepared generation; registering/remapping a
real catalogue and the final GUI flow are not proved by this worker check.

## Evidence and the initial harness error

All stages are under `G:/HL-b14-external/` and use production module candidates
`packages-r665`, helpers `images-r653` and the native binaries from r655/r656.
No production module changed in this step.

| Run | Outcome |
| --- | --- |
| `real-containers-Win64-r669` / `real-containers-Win32-r670` | Three native real-book cases each passed. The copy case failed because the observer assumed an argv list; Windows supplies a command-line string to `subprocess.Popen` auditing. Original reports remain FAIL. This was a test-counter error, not missing image processing. |
| `real-copy-Win64-r671` / `real-copy-Win32-r672` | Corrected Windows argument inspection: copy/new-archive/repeat passed, 17.875 / 18.062 s including private-runtime setup/cleanup. |
| `real-container-final-Win64-r674` / `real-container-final-Win32-r675` | Final four cases each PASS, with actual grayscale pixel checks and the additional changed-archive/new-member sequence; 53.672 / 56.985 s including setup/cleanup. Zero failures, errors or skips; both private runtimes removed. |

Final `report.json`, `report.log` and `real-evidence.json` retain exact module,
executable and source-payload identities, measured sizes and encode counts.
`real-container-verification-r673.json` is an earlier composed evidence summary,
not a replacement for any failed report or for the stronger final runs.

## Remaining work

The next data check must use an isolated copy of the actual catalogue and
personal store, with selected file bindings redirected to owned files and an
explicit pre-approval source-path guard before any native write. Keep all
original working paths out of the allowed write target. The current input
copies can be reused for that trial.

The final application/UI, catalogue registration of a compressed copy, other
formats/encodings and remaining beta 14 gates are still open. Desktop files
and public packages have not been replaced by these diagnostics.
