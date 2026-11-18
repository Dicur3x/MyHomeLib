# Placeholder identities after transfer and reviewed INPX updates

The native regression composes actual INPX import, physical transfer with
original removal, offline old roots, full/repeated/append updates, user deletion
and personal/reader data. All inputs are generated in private G: runtimes.

## Defects and changes

1. A catalogue can store a relative archive folder while its personal row uses
   the absolute folder. Empty/zero LIBIDs historically hash those stored strings
   into different reader names. Transfer therefore refused even when the second
   name had only note-registry metadata and no actual reading state.
   The alias writer now considers only variants with the same exact physical
   book identity. A read-only reader-state index distinguishes actual positions,
   bookmarks and notes from registry metadata. A single saved variant wins;
   two actual histories are refused without changing either. Existing validated
   aliases retain precedence, and unrelated/rehashed history names remain
   conflicts. Existing profile files are held against writes while evidence is
   in use; newly appearing previously absent files invalidate that snapshot.
2. An empty-LIBID arrival downloaded into an independent folder was added once
   but disappeared on a repeated full update: its current relative key differed
   from the saved publisher key, so it was inferred to be a user exclusion.
   The temporary review analysis now reconciles a unique exact previous
   physical locator with the same empty raw ID. Missing/deleted rows receive no
   inferred match, and ambiguous physical matches refuse the update.
3. Full reviewed imports reallocated retained catalogue IDs. After deletion of
   an earlier placeholder, an unverified zero-ID personal row could collide
   with a renumbered surviving card. The legacy personal remapper safely refused
   that operation. Reviewed full imports now preserve verified old IDs and
   local UUID book IDs. New IDs are allocated above the old catalogue sequence
   and personal/group references under the personal writer transaction.
   Ordinary inserts still pass NULL for SQLite AUTOINCREMENT; legacy remapping
   identity checks have not been relaxed.

No profile migration, reader-state merge, persistent review-key schema change,
user-library operation or Desktop replacement is part of these changes.

## Native checks

- Six composed cases: ordinary/bound-source catalogues, each with no actual
  history, catalogue-path INI position/bookmark, or personal-path JSON note.
  The original archive must remain byte-exact after relocation. Three original
  IDs and their personal fields, reader names and favourites must survive full,
  repeated and append updates from a new-download folder. A deliberately deleted
  empty-ID card must remain excluded. Reader INI/JSON bytes must remain unchanged.
- Focused reader evidence: registry metadata does not count as saved state;
  existing-file writes are denied while held; creating an absent notes file
  invalidates the snapshot; one actual absolute-path history is selected for
  both physical representations; two saved positions refuse alias publication.
- ID reservation: retain published ID 1 and local UUID ID 20; preserve retired
  personal card 120 and group reference 130; allocate an arrival above 130.
  A subsequent full update must retain those IDs and allocate another arrival
  above retired catalogue sequence 200. The local book remains readable with
  its original title, local flag and 63% progress.

The source binding is
G:/HL-b14-external/transfer-empty-update-validation-r1592/source-inputs.json
(693 inputs; native source files match the G: build mirror).
Current CollectionViewsTest builds:

| Architecture | Binary SHA-256 |
| --- | --- |
| Win64 | c3a163dd03cfa400ae42549069bcc69fa2e93f15b3dc25dfa6d4f49c02ae1d41 |
| Win32 | c80fb17f097f6ec273caf74b95fd294f550bb509e968a9064123ed167e76dfb1 |

The focused evidence and ID-reservation checks passed on both architectures
using the current binaries. Win64 r1591 passed all six composed cases (twelve
specific PASS markers plus two bootstrap markers, 410.968 seconds), exited
normally and removed its private runtime.

The seven existing foreign-alias/history/crash regressions also passed on x64,
without skips, in 357.468 seconds; all private runtimes were removed. They
include a rehashed foreign mapping that must refuse without overwrite, a lost
committed binding, catalogue-only and partial-root crash recovery, and identity
or location changes that must not borrow another history.
JournalTest SHA-256: 1a45b895bd83f1fc16b219d494d3e88c6a1ca57b1c1a2dec25f28db8b12cf84e.

Verification remains in progress: the x86 six-case and foreign-alias/crash runs,
paired cancellation, ordinary update window, actual reader reopening and
reviewed-update crash recovery must finish before this gate is considered
verified. Production Main/Reader builds and final beta-14 packages remain
separate gates. Current paired cohort receipts are maintained in
G:/HL-b14-external/reviewed-current-cohort-{Win64,Win32}-r1598/report.json.

## Earlier diagnostic runs

r1568 reproduced the false relative/absolute conflict; r1573 reproduced the
repeated-update loss; r1575 reproduced the retained personal-ID collision.
r1579 stopped on a duplicate test collection name, corrected to include the
case number. r1583's ambiguous-history assertion used a UTF-8 include without a
BOM: its localized message comparison failed even though the refusal occurred.
The include encoding and an explicit two-position evidence check corrected the
test; r1586 passed. None of these failed reports is counted as a successful gate.

r1581 reached the last composed case but exceeded its 240-second harness bound.
Its stopped private runtime was removed after its owner exited; the original
failure report remains unchanged. The replacement driver uses a 600-second
bound and requires terminal success and private-runtime removal. These are
small ZIP/FB2 fixtures on one NTFS volume, not large-archive throughput,
different-filesystem, real ENOSPC or final-package validation.
