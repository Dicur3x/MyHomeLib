# Ordinary transfer: reader-presence refusals

The actual Main collection-transfer menu command is now checked against two
real reader-lifetime states, rather than injecting a fake ready/not-ready flag.
The transfer implementation did not need a change; this adds a native UI fixture.

First, the idle command must open its transfer window. The fixture closes it
without checking a plan or starting work. This positive entry establishes that
later refusals are not simply startup/loading refusals.

1. The unchanged ReaderSessionRunner starts a real child process owned by Main
   and leases the input. The child is the existing native protocol test helper,
   held until an explicit release marker; it does not render a book. While it is
   tracked, the ordinary transfer command shows its wait/close-readers notice.
   The notice is observed and its OK clicked through Computer Use. The runner
   remains pending and no completion callback is delivered. Only the fixture's
   release lets the child return its normal closed/42% reply. Once the runner
   exits, the same transfer command opens again.
2. A real TfrmReaderHost instance is created in the process, without loading a
   book or starting a decoder. Its presence also refuses transfer. The notice
   is observed and acknowledged through Computer Use; the host remains alive.
   After explicit host destruction, the ordinary transfer window opens again.

After each entry/refusal/reader exit, all rows/schema of the private catalogue
and personal SQLite database match their snapshots, the source hash matches,
and the independent transfer registry remains empty. No plan, journal, copy,
publication or source deletion is started. Existing whole-transfer/real-renderer
checks remain in 2026-11-17-collection-transfer-ui.md; this focused check does
not replace or broaden their reading/export scope.

## Evidence and fixture corrections

Licensed native fixture builds in transfer-busy-readers-native-build-*-r1548:

| Platform | SHA-256 |
| --- | --- |
| Win64 | 3cb5c225c07588a8b4de44357658489847aea845fe61334c81418f8b5249f626 |
| Win32 | 575cfb36fe2d2eb9006a91ea1cb5d1b256c68d766f807705de03e3909340d20c |

Both transfer-busy-readers-validation-*-r1549/report.json runs pass. Each has
two reader-specific PASS markers plus two shared bootstrap markers. The four
native notice acknowledgements are Computer Use actions, not an unattended test.
Both processes finish and both private runtimes are removed. Seven source files
match the G: build mirror. Exact hashes and build/report bindings are retained in
G:/HL-b14-external/transfer-busy-readers-validation-r1550/summary.json; the frozen
driver is G:/HL-b14-external/transfer-busy-readers-validation-r1549.py.

Earlier fixture attempts are retained as failures. r1540 timed out before yielding a diagnostic log; r1541 identifies the fixture's wrong
record-versus-book-ID argument, corrected before runtime tests. In r1542/r1545/
r1547, synthetic clicks/commands did not close the native notice reliably. Waiting
let the held protocol helper reach its own deadline, so r1542's later 'Transfer
closed the independent reader' assertion was not evidence that Main closed it.
The successful cohort explicitly pauses notice handling for Computer Use, holds
its helper for at most 120 seconds, and streams its trace to a live log. It passed
without changing Main's production guard or silently counting the failed runs.

This does not exercise compression/deletion/download recovery or every startup
job, a competing external writer, a physically mounted/offline volume, or the
final packaged application. The host case tests host lifetime, not an open book
inside that host; the child tests the real process monitor with a protocol stub,
not the final Reader renderer. All work/profiles are private on G:, E: is unused,
C: retains its reserve, and Desktop/user libraries/public release assets remain
unchanged.
