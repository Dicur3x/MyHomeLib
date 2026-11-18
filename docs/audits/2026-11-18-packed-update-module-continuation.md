# Defer a reviewed packed update for component installation

The source window checks which packing components are installed before
applying a reviewed update. Missing components send the operation to the
existing optional-component installer. The archive preference and selected
profile travel with a private copy of the checked index and, where a legacy
collection needed it, a private copy of the manually selected earlier INPX.

The installer passes a one-time token only for a prepared job containing
the requested components. The token binds the continuation manifest by
SHA-256. The copied indexes have separate checksums. The new process
verifies the catalogue identity, logical catalogue state, saved previous
index state where applicable, and the selected packing profile. It presents
a fresh review of the previously checked input. Applying still requires the
normal confirmation, and publication still makes a separate packed copy.

The handoff uses the configured update workspace. Canceling before installer
launch releases the owned bundle. A failure to launch the installer disarms
the token and leaves the prompt able to retry. A valid token is claimed
atomically and can be used once. The claim removes only known files in its
own folder when the review closes. A different token leaves the bundle alone.

## Verification

The isolated native fixture temporarily makes the private BookProcessing
runtime unavailable. It enters the normal source window, attempts to apply
the reviewed change and captures the resulting continuation. The fixture
checks cleanup on decline, a disarmed token, a wrong token, a changed manifest,
a changed index, and one-time consumption.

It restores the private module runtime, hides both original INPX files and
uses the continuation to reopen the actual source review. The final worker
requires confirmation and publishes the expected new collection. The old
catalogue hash, prior deletion, pending delivery, unchanged 7z-backed book
and personal fields are checked through the existing fixture assertions.

This first fixture models the component's arrival inside the same process.

Both x86 and x64 builds also pass the existing bound packed and normal
source-profile tests. The record binds six native runs, four builds, 60
pass markers and 702 files. The native test profiles were removed. See
`G:/HL-b14-external/packed-module-restart-validation-r1840/summary.json`.

## External installer and an actual new process

Both architectures also pass the real component installer. The test hides
the private BookProcessing executable, serves the verified same-version
repair package over loopback and drives the compact component prompt. The
external updater receives the original review token and starts another
HomeLibre process. The driver confirms the process ID changed and verifies
all installed package members against the archive manifest.

The new process loads through the ordinary startup entry point. It opens the
previously checked profile, with both original indexes and the old source
folder offline. The catalogue digest and the number of registered collections
are checked when the source dialog opens and again at confirmation. The
confirmation asks to create a new copy and defaults to No. After explicit
approval, HomeLibre activates the new collection and reads the selected
downloaded body even though an archive with the same name is present in the
collection folder. The check also covers the retained 7z payload, stable book
ID, earlier deletion, rating, progress, review, pending replacement and
consumption of the one-time token.

The first x64 run reached confirmation but the test expected the wording
used by a merged source. The assertion now checks the existing wording for
a standalone packed collection. Production code did not need a change.

The final x64 and x86 receipts are in
`G:/HL-b14-external/packed-real-installer-validation-r1854/summary.json`.
The runs verify 173 and 172 installed files respectively and remove their
isolated profiles. Network transport is loopback, with verified local release
artifacts. The final release packages and GitHub download are separate checks.
