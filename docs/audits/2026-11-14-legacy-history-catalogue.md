# Legacy image history through the ordinary catalogue

This follows `44b7dd6d` and `c0f8e020`. Beta 14 remains local; this is not a
Desktop replacement or publication.

## Confirmed gap

The packaged earlier Packer creates a real mixed FB2/EPUB PPMd archive and its
generation/journal. Both books contain large raster images and both are reported
as optimized. A private native catalogue uses the old registration metadata and
the actual generated member names. The normal selected-book command is then
invoked with the matching maximum profile, without grayscale.

`legacy-gui-Win64-baseline-r32` reproduced the product gap. The archive stayed
unchanged, both original payload checksums acquired native receipts and both
formats were recognized as previously optimized. But there was no
`HomeLibreCompressedImages` table: the metadata-only inspection receipt discarded
the read-only raster witnesses. Its later query failed with `no such table`.
Thus helper-level migration did not prove migration through the actual GUI.

Baseline fixture SHA-256:
`a62ea6c956f8c70a0138eab9d0b088a465d8ea728c958458bca335d5b54928f0`.
Build log `CompressionRecovery.local-Win64-9fd497c67abf.err`.

The earlier r29/r30/r31 runs were fixture setup failures, not product
reproductions. r29 supplied the tools root one directory too high and left a
SQLite connection open. The connection now closes explicitly, and its verified
private remainder was removed; its external log/report remains. r30/r31 placed
the private catalogue in the regular data folder instead of beside the old
payload journal. The legacy-only bootstrap now creates it at the actual old
storage root. Ordinary fixtures keep their existing location.

## Change being verified

Inspection receipts keep `image_outputs` empty, preserving the existing ban on
publishing hashes from a discarded transformation. They separately carry
`source_image_outputs` only for checksum-matched reused books. Changed or
incompletely checked books cannot claim this source history.

Native validation checks bounded hash arrays and requires unchanged source and
payload digests, a completed check and no retry-original outcome. The usual
source-file lease and full source checksum still precede the metadata commit.
Only the inspection path imports these retained-source hashes; applied candidates
continue using their existing output-image field. No original image bytes are
rewritten during migration.

The GUI scenario then points those same cards at an updated FB2 plus its old
picture and one fresh image, alongside the already packed EPUB. The independent
wrapper will check text/markup, the old image bytes, the neighbour, original-book
backups and the immutable old archive/journal/marker. Native receipt tests cover
valid retained hashes and rejection of unverified or discarded output claims.

## Positive evidence

- `legacy-receipt-Win64-r36`: all 38 checks passed, no skips/errors/failures;
  108.125 s including setup and removal. These comprise all 30 native receipt
  checks, seven legacy-history cases and the inspection-discard guard.
- `legacy-receipt-Win32-r37`: the same 38 checks passed, no skips/errors/failures;
  103.125 s including setup and removal.
- `legacy-gui-Win64-r35`: both actual old formats migrated through the normal
  command without rewriting the PPMd archive. The following updated-book command
  preserved the old FB2 raster bytes, text/markup, EPUB assets, neighbour,
  originals and personal progress; 23.937 s, private runtime removed.
- `legacy-gui-Win32-r38`: the same two-stage GUI scenario passed; 24.656 s,
  private runtime removed. The common fixture's profile-zero label was also
  corrected before this build; these cases select profile three (maximum).

The earlier r34 inspection batch remains failed: premature import captured an
unset native-worker environment, causing 30 skips, and a selector named a
nonexistent test class. Seven helper cases passed. Its old JSON remained
incomplete when serialization of raw skipped-test objects failed. The wrapper
now imports the EPUB fixture only for the GUI case and serializes skip IDs and
reasons; skipped tests still fail the gate. The corrected r36/r37 runs execute
all native cases. Existing failed reports/logs are retained.

Final local BookProcessing candidates are under `packages-r33`:

| Platform | Bytes | SHA-256 |
| --- | --- | --- |
| Win64 | 12,445,720 | `c2b9294eb2211e6dd96fcdc571f53a4e95b5916f2d7bf85126d7f5fee92ff1e4` |
| Win32 | 11,186,344 | `c9a1a8e0b866b64fdb286dc02ba82c509e7dceba9f20055544c605b2c129da5d` |

Native receipt executables:
Win64 `104e376ccc624bb59c4fc36fc2459a7f8a9bee736ddfafce5b858dcffcf89f6e`
(`BookCompressionReceiptTest-Win64-5833af0ab445.err`);
Win32 `d0949e29477366fe5f8ad661d826f2d2ce9b1811dd3ef7f263094844b81093cd`
(`BookCompressionReceiptTest-Win32-9c85990de181.err`).

GUI fixtures:
Win64 `1f8c9ae3245755a22d244d673d5fefb620f2634d6be4a500d034841702823550`
(`CompressionRecovery.local-Win64-13b100ae749c.err`);
Win32 `3989abeb0328098aea15b65c1168d692c9942cbc6228b00728899c81adac16b1`
(`CompressionRecovery.local-Win32-0c5cf70c0e18.err`).

These GUI catalogues use the current full schema with old registration metadata
and real earlier-Packer artifacts. They do not test the old native publication
or updating a whole old packed catalogue from INPX. In particular, they seed
actual decoded book sizes; the old native publication currently rewrites paths
without `BookSize` (`unit_CollectionPacking.pas`, `ApplyPrepared`). Verify that
older stored-size case next, along with old FBD and packed updates. Separated
JPEG XL layouts and tests on user collection copies also remain open.
