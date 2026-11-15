# Open long-workspace update failure

A length-sensitive failure was found while staging recovery-interruption tests.
This is unresolved and must not be reported as fixed by shortening the test path.

## Evidence

The same Win32 native fixture, processing package and compressed bound-source
update fail before the requested `catalogue-committed` termination under
`G:/HL-b14-external/recovery-restart-matrix-Win32-r467/zip-1-catalogue-committed-recovery-restore-step`.
Its log ends after `TRACE compressed size snapshots=3` with Windows error 3
(path not found). Under `G:/HL-b14-external/rri32-r469`, the fixture reaches the
actual update termination, a second real termination inside SQLite restoration
and successful ordinary startup/continuation, with unrelated files preserved.

Win64 also fails before its requested original update termination in
`recovery-restart-matrix-Win64-r466/zip-1-catalogue-committed-recovery-lease-released`,
while the shorter stage `rri64-r470/0` passes the same update/recovery case.
Earlier Win64 cases with shorter final folder names in the first matrix passed.

Final native binary hashes are recorded by build gates
`recovery-restart-build-Win64-r462` and `recovery-restart-build-Win32-r464`.
The failure occurs before the recovery interruption itself. The exact failing
file operation has not been identified; it must not be attributed to SQLite,
backup creation or the journal without further evidence.

The remaining interruption cases use short stage names to isolate that FSM
check. This does not establish long-path support. Continue by reproducing the
long path with contextual file-operation diagnostics, fixing the affected
production path handling and verifying both architectures before release.
