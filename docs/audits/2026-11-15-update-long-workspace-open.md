# Resolved long-workspace update failure

The length-sensitive failure reported in this audit is fixed in the shared XML
reader/writer. This confirms the failing update paths below, not every possible
long-path operation in the application or a production-package build.

## Diagnosis

The same Win32 native fixture, processing package and compressed bound-source
update originally failed before `catalogue-committed` under
`G:/HL-b14-external/recovery-restart-matrix-Win32-r467/zip-1-catalogue-committed-recovery-restore-step`.
Win64 also failed under
`recovery-restart-matrix-Win64-r466/zip-1-catalogue-committed-recovery-lease-released`.
Short paths passed on both architectures; shortening the fixture was not a fix.

The diagnostic build `update-long-diag-build-Win32-r477` and run
`recovery-longpath-diagnostics-Win32-r478` established that all book rows and
search-index finalization completed. A contextual XML error in diagnostic build
`update-long-diag-build-Win32-r479` and run
`recovery-longpath-diagnostics-Win32-r480` identified the exact failed call:
`CreateFileW` for the adjacent temporary file of `merged-groups.cxml2` in
`Data/LibraryUpdateBackups/{operation ID}`. The destination path was 218
characters; appending the old temporary suffix produced 269 characters.
The raw Windows call returned error 3 before either catalogue was committed.
The profiler added only for diagnosis has been removed from the fixture.

## Change

`TMSXMLHelper.SaveToFile` normalizes the destination and independently extends
both native paths when needed. The unique adjacent temporary name no longer
repeats the destination filename, so a valid long filename component also works.
Creation remains exclusive, the zlib footer and file buffers are finished before
publication, and failed publication deletes only its owned temporary file.
Errors retain their Windows error code and identify destination and temporary
paths. `LoadFromFile` uses the same normalized native-path handling.

## Final verification

Licensed native builds: `update-long-final-build-Win64-r485` and
`update-long-final-build-Win32-r486`. Final binary SHA-256:

- Win64: `e243f8ab6689c4c5873bb8d50a7c407e4a1a0337d71052d3fbce579d8f582fe8`.
- Win32: `0c552b85ee6746c34294dc3521af23d218212df7f6fe532d0943b962cb901de5`.

The original failing path shapes and lengths now pass:

- Win64 `recovery-restart-matrix-Win64-r488/zip-1-catalogue-committed-recovery-lease-released`.
- Win32 `recovery-restart-matrix-Win32-r489/zip-1-catalogue-committed-recovery-restore-step`.

Each test performs actual compression and a bound-source update, terminates
that update at the catalogue-only commit, starts normally and interrupts the
recovery, then starts normally a third time. Verification covers rollback,
personal data, compressed sizes, archive bytes/resources, incremental
continuation, newer neighbouring-collection data and unrelated files in and
beside the journal. Both reports confirm the private runtimes were removed.

`search-presets` also passes on both final binaries
(`xml-publication-Win64-r487`, `xml-publication-Win32-r490`). Its added native
regression saves/reopens compressed and plain XML in paths over MAX_PATH,
preserves Unicode, checks a user-data group with a 247-character filename
component, verifies failed locked-target replacement retains the old complete
file, and checks no owned temporary remains. The original preset
save/delete/reopen, locked/read-only failure and protected-data assertions also
pass. Windows returned error 5 for locked rename here; the regression accepts
access denied or sharing violation and verifies preservation independently.
The first diagnostic test had incorrectly required error 32 specifically;
correcting that assertion did not change production code.

Aggregate evidence: `G:/HL-b14-external/xml-longpath-validation-r491/summary.json`.
The final two recovery reports and two XML/preset logs are retained; all four
private profiles were removed. No user library or Desktop installation changed.
Builds and fixtures use G:, with more than 8 GiB remaining on C: throughout.
