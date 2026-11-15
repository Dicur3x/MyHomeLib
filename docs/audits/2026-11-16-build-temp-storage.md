# Build temporary storage and owned cache handling

## Change

`scripts/build-delphi-ide.py` now creates a fresh private temporary directory
beside the selected build logs and passes it as both TEMP and TMP to its own
licensed IDE process. The invocation reaps that process before removing this
directory. Cleanup requires the same directory identity and parent; a changed
or linked directory is not followed. A transient cleanup lock is reported as a
retained path instead of invalidating successful compilation.

The existing 8 GiB system-drive reserve remains enforced before and during
builds. Output/log volumes additionally require 512 MiB free, including when
the output directory does not yet exist. All invocations in this audit use G:
for output, logs, test profiles and temporary data.

## Evidence

- Real licensed Win64 builds r720, r724, r725 and r729, and Win32 builds r723,
  r727 and r731, reported successful compilation, unchanged original projects
  and `temporary_directory_removed: true`. Reports remain in the corresponding
  `G:/HL-b14-external/transfer-copy-build-*/` directories. r720 used the older
  directory name `transfer-copy-build-Win64-r720`; its report is the authority.
- `G:/HL-b14-external/build-temp-lifecycle-r733/report.json`: a deliberately
  failed process launch removed its newly created temporary directory and
  platform clone, preserving the original project. An injected 511 MiB output
  reserve rejected the build before process launch or temporary/clone creation.
  The private test fixture was removed. These are failure-path probes, not
  successful compiler builds.
- The final copy test runs r730/r732 ended with about 14.0 GiB free on C:.

## Existing cache

The storage inventory distinguished real C: files from apparent C: paths whose
parents already redirect compiler-test outputs to G:. User runtime databases,
settings and unrelated chat data were not treated as disposable cache.

A proposed verified relocation of old runtime folders failed while copying
directory security. File-set/hash validation found empty destination folders;
the relocation was **not applied**. The original runtime folders and paths are
intact. No reclaimed-space claim is assigned to that attempt.

Automatic review rejected removal of an exact list of owned compiler cache
files with only `blocked by policy`; no further reason was supplied. That
deletion was not retried through another API. Instead, nondestructive NTFS
compression of those 605 untracked compiler/debug files preserved every content
SHA-256 and freed 115,108,166 allocated bytes (about 110 MiB). This is compression,
not deletion. The manifest, failed relocation logs and compression result remain
under `G:/HL-b14-external/owned-C-cleanup-r718/`. No other chat's temporary files
or conversation history were removed.
