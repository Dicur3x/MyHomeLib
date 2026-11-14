# Compression settings and exact selection after component restart

Local beta-14 work after `7438950a`. The current/selected compression commands
previously requested missing components with a message to repeat the command
manually. Only the older packed-copy command had a restart continuation.

## Change

The two current compression entry points now supply the updater's existing
restart-argument callback. That callback writes a continuation only when the
verified installation is about to launch and includes every requested module.
The existing updater clears its callback on Cancel; downloads alone do not
create a compression request.

`unit_BookCompressionContinuation` records three scopes: selected books, the
current collection and new/changed books. It preserves profile, grayscale,
per-archive review, estimate-first, work folder and optional backup choices.
Runtime executable paths are resolved again after restart, and a new queue
identity is generated. The saved request never starts a worker by itself.

For a selected set, the plan carries each catalogue ID, exact LibID, physical
book locator, actual source filename and Windows file identity/size/write-time
stamp. On resume, the collection file identity/root and those book/source
identities are checked before reopening settings. This is a metadata identity
check, not a full terabyte-archive hash during UI setup. Normal compression's
independent payload/content checks still apply when preparing a result.

The request is UTF-8 JSONL written atomically beside that profile's settings.
It has a one-time command-line token and atomic claim, a one-day lifetime,
strict typed fields and bounded paths, lines and 64 MiB total size. A different
token leaves it intact. A consumed or malformed request cannot be replayed.
Another active collection does not receive the old request. The resumed dialog
identifies the original scope/count and says it follows component installation.
Cancel returns without creating a compression queue or changing books.

## Native gates

The fixture creates its own catalogue and source file. It verifies a valid
request and one consumer, wrong token, another collection, a reused book ID,
changed source bytes, Boolean-as-string, negative/oversized count and unknown
profile. It then launches three fresh processes. Each starts the actual main
window, takes its own continuation and must show the saved choices for one
scope. A timer inspects the real options form and cancels it; the original
source SHA-256 stays unchanged and no work queue is created.

| Platform | Continuation/review run | Seconds | Ordinary selected compression run | Seconds |
|---|---|---:|---|---:|
| Win64 | `compression-continuation-Win64-r89` | 15.922 | `compression-normal-Win64-r91` | 19.734 |
| Win32 | `compression-continuation-Win32-r90` | 11.469 | `compression-normal-Win32-r92` | 20.797 |

All four gates passed and removed their private runtimes. The ordinary menu
regression applies selected compression, verifies unaffected neighboring
content and backups independently and checks the resulting catalogue. Its
synthetic shared ZIP shrank from 1,288,077 to 127,560 bytes on both platforms;
this is an integrity/no-growth check, not a real-library speed estimate.

Native fixture identities and fresh licensed IDE logs:

| Platform | SHA-256 | Build log |
|---|---|---|
| Win64 | `708b6ee616b2dd09ffe07c1ddbff646c7529b10e2d2c469241b7eae694f770ea` | `CompressionRecovery.local-Win64-9203fd8668f4.err` |
| Win32 | `3ea73f54161443ead942a0a1c352b9275de65dd09925e725365ef86f49b4b73b` | `CompressionRecovery.local-Win32-1c4810e44983.err` |

The exact installed BookProcessing package candidates remain `packages-r78`
from the PDF/EPUB export audit. No Python production worker changed in this
step. The first build `9d10f2e25f09` stopped on the new test's use of a string
helper on VCL's distinct caption type; it was replaced with `Pos`. The owned
failed-build dialog was acknowledged so the compiler could write its result.
No old fixture binary was treated as a successful fresh build.

## Remaining scope

These gates prove the persisted request, source binding, real main-window
startup and canceled review, plus the unchanged ordinary compression route.
They do not yet combine this new continuation with the compact module download,
external installer and successor in one transaction. That full transaction,
including cancellation during download and eventual approved compression,
is now verified for the selected scope in
`2026-11-14-compression-module-transaction.md`. Current compression with old external image storage, bounded
user-data copies, final application/package builds, Desktop replacement and
publication are also separate gates. Earlier broad recovery suites were not
rerun in this step.
