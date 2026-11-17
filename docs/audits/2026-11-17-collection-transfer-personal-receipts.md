# Optional personal cards and locator receipts

The first experimental receipt included a reader-history suffix only while its
personal card existed. Deleting the card after publication removed that suffix
from the recomputed digest, although the frozen book locator and saved history
mapping had not changed. Recovery then refused the operation.

New receipts record format 2 in `HomeLibreTransferLocationFormats`, together with
the same operation, group, review SHA-256 and binding SHA-256 as the ordinary
locator receipt. Both records share the caller's existing database transaction.
An orphan format record, mismatched hashes or an unsupported format is refused.
The existing four-column locator table and its historical receipts are retained.

Format 2 keeps the reader-history proof in the digest. For an absent optional
card, it reads the validated mapping at the frozen destination; it does not
create a card or a new alias. Present cards still pass `RecordMove` checks.
`ExistingBinding` uses the same location, current history name and original name
validation as normal history lookup. Consequently, deleting only a card does
not change the receipt, while losing or changing its saved alias still does.

Existing receipts without the format record retain their exact legacy rule.
They are not silently upgraded or repaired. For present cards the new receipt
also remains readable by the actual pre-change writer. If the optional format
record is lost and that legacy digest still matches, verification may read it
as legacy without recreating metadata. The ambiguous old missing-card receipt
continues to fail safely. This is compatibility with earlier local experimental
transfers, not a claim that their missing-card behavior was correct.

## Final native evidence

Final binaries are Win64 r1189 and Win32 r1191. Targeted runs r1193/r1192 cover
deleted numeric/empty-ID cards, deletion between review and publication, a
catalogue-commit crash before personal publication, lost history after card
deletion, damaged/unknown format records, genuine old receipts, reverse reading
by the old writer, lost/changed reader aliases, partial roots, shared-catalogue
forks and immutable completed-receipt replay. Both runs passed 19 methods/44
native calls, two deliberate exits and ten expected refusals each, without
errors, skips or remaining private runtimes. Win64 took 719.016 s and Win32
720.812 s; this is not a controlled performance comparison.

The source/resource/test snapshots contain 651 matching inputs on both
architectures. Consolidated evidence is
`G:/HL-b14-external/transfer-personal-receipts-validation-r1196/summary.json`.
The final native binary SHA-256 values are:

- Win64: `4f2380d70c81fc3d83527e4dd938c37421c712a2653559fc27f7eb17348c3341`.
- Win32: `da6c28e0c0e3e916155efa4e07bc1c367903700e0a7a33cd83ef3b34c0f2e21a`.

The initial prefix-only draft passed r1186/r1188 but was replaced before commit:
it did not keep the independent alias digest in the locator receipt. Those runs
are not final validation. Run r1190 caught a test assumption left over from that
draft: a format record's absence need not prevent a compatible legacy read with
unchanged receipt bytes. The final test instead checks successful read-only
compatibility without recreating metadata, and separately refuses a lost alias
after card deletion. All earlier reports are retained.

The earlier million-row results in the binding-memory audit precede this format
change. The new whole-operation benchmark adds cache/root publication, a fresh
process for completion and another process for byte-exact replay, using streamed
guards of non-locator user data. Its small x86/x64 setup checks passed; large runs
remain pending. Evidence and guard limits are in
`docs/audits/2026-11-17-collection-transfer-full-scale.md`. This is native
coordinator evidence, not an ordinary-window/release gate. No user
catalogue/archive or Desktop executable was changed.
