# Qualified FB2 output requires a compatible reader

Follow-up to `5c36d3cb`. A BookProcessing module may be updated independently
of the application. Its new namespace-aware separator must not create a stripped
prefixed FB2 for an older host whose native reader cannot restore it.

The beta-14 packing job advertises `reader_fb2_namespaces: true` for JPEG XL.
The Python codec enables qualified/whitespace closing-tag separation only for
that exact Boolean. A missing/false/unknown value keeps the complete prefixed
book. Ordinary unprefixed FB2, PDF and EPUB paths retain their prior behavior.
An older Python module can ignore the new field and keep its existing behavior.
No component-feed migration or public asset replacement is needed for this
specific format capability.

The negative integration test runs a real old-style Packer job without the
field. It must not invoke the encoder and its output must contain the full
original book bytes. A positive direct-codec test checks explicit support; the
actual native pipeline separately verifies the new job/reader combination.

## Artifacts

Local `packages-r63` supersedes the unguarded `packages-r54` candidates:

| Platform | Bytes | SHA-256 |
|---|---:|---|
| Win64 | 12,446,335 | `05b2cc7d5a90ef81002d79661b086b171a11c12339733bffe53985b98016489e` |
| Win32 | 11,186,961 | `4288941af5ba05dce077f236ca5c9566c08dd0cc755e5aa638921b073e9712f6` |

Four targeted checks passed without skips on each architecture: old-host job,
qualified codec, ordinary FB2 cover/duplicate protection and PDF reconstruction
and retention. Win64 `codec-host-Win64-r64`: 8.438 s;
Win32 `codec-host-Win32-r65`: 8.000 s. Both temporary runtimes were removed.
The preceding 54-case suite is recorded separately in the prefix audit; it is
not counted as rerun after this capability guard.

The positive native fixture also includes a qualified closing tag with legal
whitespace and a literal false closing tag inside a body comment. Its complete
body XML and all 258 JPEG hashes must survive the round trip.

Both native runs passed all fifteen expected outcomes with the guarded package:
Win64 `codec-host-native-Win64-r66`, 118.203 s;
Win32 `codec-host-native-Win32-r67`, 114.000 s. All 258 original image hashes,
body XML (including the false tag in its comment), legal closing-tag whitespace
and main-window INPX continuation passed. Both temporary runtimes were removed.

Native fixture identities:

| Platform | SHA-256 | Build log |
|---|---|---|
| Win64 | `86c76f356c9c2f9c1ef11ce7bc8a50e24691f623f5af63b52803b53e5e84ef89` | `CompressionRecovery.local-Win64-435b26cd1833.err` |
| Win32 | `69cef55e037e28782acee78c049773ec3fb461bf28eb9b34f9567b5e47017737` | `CompressionRecovery.local-Win32-f6f9c6db0a07.err` |

## Limits

This protects creation of new output by an old-style job. It does not promise
that an older executable can open a managed collection already created by a
newer reader, and it does not force a retry of previously cached no-gain books.
Network installation/continuation from a missing-component prompt, other native
JPEG XL formats and final application/component distributions remain open.
