# Old copy-based compression history: local migration

This follows the completed preparation-recovery gate in `1e2d2c72`. The wider
beta-14 Todo is still open. These changes have not been published or installed
on the user's Desktop.

## Baseline and change

`legacy-history-Win64-baseline-r20` built real FB2 and EPUB compressed copies
with the earlier `Packer`, then passed their exact registered members through
the new in-place preparation. Both subcases failed the reused-history assertion.
The example pictures were already below the encoder's small-image threshold;
this baseline proves missing reuse recognition, not a second lossy encoding or
changed user data. All source/catalogue/journal hashes remained unchanged.
No private inspection runtime remained in that stage after teardown.

The new read-only lookup checks `HomeLibPackingState`, its dataset/profile and
the root marker against the old journal. Only physical archives inside that
root qualify. It streams the old immutable payload entries and restricts reuse
to known optimized members with exact generated names and SHA-256 witnesses.
The actual extracted book must still match that checksum before reuse. No hit
is inferred from a book ID, title or date. A changed profile/grayscale choice
does not reuse the previous quality. A corrupt or unavailable matching journal
does not silently start another lossy pass. Cancellation remains cancellation.

For a verified legacy FB2/EPUB, preparation reads raster hashes without changing
the book or running the encoder. The existing native receipt can commit these
hashes to the new per-image history. A later text edit with one new illustration
then preserves old image bytes and encodes only the new picture. Estimate uses
the same whole-book witness and reports its exact existing payload size. A
retryable failed native inspection takes precedence over the old witness.

This is not a claim that separated JPEG XL sidecars, FBD wrappers or every old
archive layout have passed the complete application workflow. Those remain
separate accepted Todo checks. Preparation does not modify either old database.

## Evidence

Stages:
`G:/HomeLibRu-build-cache/HomeLibre-post13-compression-recovery-20261113`
and `G:/HomeLibRu-build-cache/HomeLibre-post13-legacy-history-20261114`.

- r20: baseline failure described above, preserved as failed.
- `legacy-history-Win64-r21`: initial legacy recognition plus existing image
  history, 16 passing checks. This predates raster-hash migration.
- `legacy-history-Win64-r22`: expanded 53-case suite, two errors in the new FB2
  raster-hash reader because its wrapper used `xmlroot` instead of the existing
  `xml` API. The other checks passed, but this batch remains failed.
- `legacy-history-Win64-r23`: corrected final helper passed all seven new
  legacy cases, including both real formats, estimate, profile isolation,
  foreign dataset, actual payload hash, cancellation while reading entries,
  and preservation of an old picture after text/new-image changes. No skips,
  failures or errors; 32.219 seconds including setup/cleanup. Runtime removed.
- `legacy-history-Win32-r24`: final 53-case suite passed without errors,
  failures or skips in 173.438 seconds including setup/cleanup. Covers all
  seven legacy cases, existing image history and selected/native preparation.
  Private runtime removed. The x64 final rerun was targeted at the seven
  affected cases; r22's other checks passed before the XML API spelling fix.

Final local BookProcessing packages (`packages-r23`):

| Platform | Bytes | SHA-256 |
| --- | --- | --- |
| x64 | 12,445,639 | `ee0de45e0c59c0611f55eff536d9be603095d2f68ef13f234e4c7fc3a12f8cea` |
| x86 | 11,186,263 | `f22cef9f11c10b4dd4db8822571aa4c0b04eae684785f3dec70c643cbd61b795` |

The native fixture binaries are unchanged from the prior recovery gate. Their
generic receipt handling already verifies/commits per-image hashes. A final
ordinary-window check against an actual old registered catalogue is still
required; helper and native-unit checks do not replace it.
