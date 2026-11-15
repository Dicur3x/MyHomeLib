# Repeated interruption during update recovery

This adds guarded native test checkpoints inside restoration and journal
completion. They are compiled only with MHL_COMPRESSION_TEST and do not change
release recovery behavior.

The fixture first terminates an actual reviewed update with exit code 73.
Its next ordinary startup is terminated with exit code 74 at one of six points:
inside SQLite backup restoration, after restoration, after personal-ID remapping,
after publishing done.json, after releasing the journal lease, or after moving
the journal to completed. A third ordinary startup must finish correctly.

A 4-MiB BLOB makes restoration span multiple 512-page SQLite backup steps. The
mid-restore gate requires copied pages to be positive and less than total pages;
the initial Win64 gate stopped at 512/1115. The final native checks compare the
entire BLOB with zeroblob(4194304), as well as existing catalogue, physical-copy,
personal-data, Reader and compression-history assertions.

The driver adds an unrelated file inside the owned journal and another beside
it. After the final startup, both exact payloads and immutable job.json must
survive, and the journal must have moved to completed. The later personal-store
witness of another collection is protected across both interrupted processes.

Coverage on each architecture consists of six rollback recovery checkpoints,
two committed-state completion checkpoints, and four composed FLibrary cases
covering ordinary/bound catalogues with external JPEG XL covers and illustrations.
All use real process termination and normal data-module recovery, followed by
existing incremental-continuation checks.

The original long stage names exposed a separate unresolved path-sensitive
update failure before recovery. Short stage names isolate this recovery test;
they do not fix or prove long-path support. Reproducers and comparisons are in
2026-11-15-update-long-workspace-open.md. The first pilot also had a diagnostic
Python import-scope error, corrected before the recovery run; no product change
was made for that setup issue.

Native builds are recovery-restart-build-Win64-r462 and
recovery-restart-build-Win32-r464. Processing packages remain packages-r195.
All 24 unique interruption cases passed: twelve on each architecture. Their
native durations total 578.954 s on Win64 and 579.812 s on Win32. These are test
execution times, not production-library performance measurements. Each log
independently proves three actual application bootstraps and the second
termination at its requested recovery checkpoint. Every passing private runtime
was removed. The verified coverage aggregate is
G:/HL-b14-external/recovery-restart-validation-r476/summary.json.

Successful reports are collected from the retained first-matrix cases,
recovery-restart-Win64-r465, rri32-r469 and the shorter rri64-r470/rri32-r471
matrices. Native binary SHA-256 values are
35a8153bf2737405932f988fcee7a16789576217f7b375f0288e05f3503a1f44
and 758ea059178b67d5bf794064abded6e0da12196baf25712000e047889d62ff97.
Both licensed IDE builds kept the original local project unchanged. Source
changes in unit_LibraryUpdateJournal are guarded diagnostic callbacks; release
builds omit them. User libraries and Desktop applications were not changed.

Four non-interrupted startup regressions also passed: ZIP/Win64 54.078 s,
ZIP/Win32 55.703 s, FLibrary/Win64 123.453 s and FLibrary/Win32 125.156 s.
Their four private runtimes were removed and included in the same aggregate.
The long-workspace defect remains open; no short-path success closes it.
