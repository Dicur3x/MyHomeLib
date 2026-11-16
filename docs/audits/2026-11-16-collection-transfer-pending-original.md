# Defer final roots until an open original is released

An external reader can delay unlink of a verified original. The original may
remain visible because the reader denies delete sharing, or deletion may already
be requested but remain pending until a delete-sharing reader closes its handle.
The former is conservatively retained when the deletion guard cannot be acquired;
the latter is an outstanding removal that must be retried after the group.

The previous coordinator continued into final roots/source-cache publication
despite a nonzero `Originals.Pending`. On the next run, its existing-root branch
handled metadata only and skipped the outstanding original-removal phase.

`TCollectionTransferOperation.Run` now returns the pending result before starting
roots or cache publication. The published copies, group receipts, prepared cache
snapshots and operation registration remain available. Once the reader closes,
the same journal recovers the published groups, retries removal without copying,
and only then publishes final roots and source/history settings.

The baseline r1019 test failed on the old Win64 binary exactly at
`roots_applied=True` while `pending_sources=1`. Its original test source, native
invocation and failure report are retained separately. It is not counted as a
passing check.

The new native cases use actual Windows handles with and without delete sharing,
plus the roots-only request. For deferred unlink they require no final roots/cache
publication on the first pass, zero copy streams and zero pending removals on
continuation, and final publication of the requested metadata. A delete-denying
reader instead preserves the original bytes with the existing retained reason;
metadata replay cannot silently retry deletion of that retained file. Two
existing cases cover normal byte-identical metadata
replay and partial two-catalogue recovery with old caches/work snapshots offline.
Final source/binary bindings and reports are under
`G:/HL-b14-external/transfer-pending-final-r1024`.

Five methods per architecture pass on the final binaries: **20 native calls**,
two expected forced exits, no unexpected codes and no skips among the selected
successful methods. All private runtimes were removed. Licensed IDE builds:

- Win64 r1020: `f0f7649a4a96470c77da768dfeeb65c38b96eb280e5f6b9554ffd89a4c86ee11`.
- Win32 r1022: `aaa0c34d001ba128d81713fed0de7e69646bcf5dfd2a3cb73deafb4dcb770313`.

The first r1021/r1023 matrices correctly passed four methods but the new
delete-denying-reader method had incorrectly expected `pending` rather than the
existing conservative `retained` policy. That assertion was corrected; the
method is rerun separately. Earlier successful methods are retained, and neither
failed matrix is relabelled PASS. Their original test sources are preserved.

This is a coordinator ordering fix. Normal UI/startup routing, Reader history
identity migration, complete-operation acknowledgement and the other transfer
release gates remain open. Tests use private G: fixtures; no user library or
Desktop installation is changed.
