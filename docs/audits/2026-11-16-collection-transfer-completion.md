# Physical transfer: whole-operation acknowledgement

`TCollectionTransferJournal.CompleteTransfer` is a separate explicit operation.
Running available-file transfer, roots publication and cache cutover alone still
leaves the operation pending. The caller must first reload its DAO/view and pass
a read-only application-ready callback. Normal Main/startup routing and active
Reader/job coordination still need to call this gate.

Completion reuses the existing final-roots publication session. Every catalogue
and the personal database keep their writer locks while roots/settings,
inventory, aliases, independent group proofs, resource bindings and installed
source/history versions are checked. It requires already-applied roots and a
fully published cache-metadata intent, including every per-database receipt.
Neither a roots-only run nor an unfinished cache-publication intent can become a
completed move.

Each original-removal row is matched to its immutable reviewed file and recovered
prepared copy: group/proof, source/target file identity, paths, content hash and
stream list. Only terminal removed/missing/retained states contribute to the
summary; pending/intent states, missing or extra rows, and a plausible terminal
count with the wrong file binding are refused. Counts include all groups and
files from the operation, rather than only work performed in the last run.
Files/bytes describe the reviewed physical inventory, including files already in
place, not the number of book cards or newly copied bytes; UI wording must say
processed inventory rather than claim all of it was copied.

`HomeLibreTransferCompletion` stores the summary, review/root bindings and summary
SHA in the same personal transaction that changes the registry state to
completed. The application-ready callback is checked again after the last test
point immediately before commit. Cancellation, an exception or process exit
before commit rolls back both summary and state. An exit after commit leaves a
completed operation with its summary, absent from the pending list.

Completed replay reads this historical receipt without recopying/revalidating
payloads or rewriting databases; it does not undo later legitimate changes. The
receipt must match the immutable review, personal identity, counts, byte total
and timestamp. A completed registry row without its matching receipt is an
error, never permission to invent another result. This is an integrity/recovery
record, not protection against an adversary able to replace all personal data.

## Verified evidence

`test_native_collection_transfer_completion.py` exercises ten native cases on
private G: catalogues: cumulative/read-only completion, an initially busy
application, becoming busy at commit, process exit on both sides of commit,
roots without cache publication, pending originals, wrong terminal file binding,
a lost completed receipt and an unfinished publication intent.

The actual DAO/Reader fixture is also extended to acknowledge only after its
five moved FB2 books were reopened and their positions, bookmarks and notes
checked. It keeps the current DAO connection open during the final gate, checks
whole-operation totals and replays the saved result. This exercises a real Main
harness, DAO and built-in Reader, but not the active target's normal Main grid or
the not-yet-connected transfer menu/startup workflow.

`G:/HL-b14-external/transfer-completion-validation-r1060/summary.json` consolidates
639 matched source/resource/validator inputs, native results and actual Reader
runs. Ten methods per architecture pass: **56 native invocations**, four
expected forced exits and fourteen expected refusals; no errors/skips or
surviving private runtimes. Win64 r1052's two smoke methods and r1054's eight
remaining methods are selected without duplication; Win32 r1055 runs all ten.
Final native binaries, built with the licensed IDE:

- Win64 r1050: `05c8aee5285853aeb4cac8f142d8add1de69a8d503a8878a14954931fd587644`.
- Win32 r1053: `d7e17e931149e8e794f37fe550468a178b12e1814b7e974bbbf4b7233581c2c6`.

The actual DAO/Reader cases pass and remove their private runtime:

- Win64 r1058: 44.296 s, binary
  `9fbfc730f51ffd86c9835e2772b93e38caa575eb1223900e88c9728ff31de516` (build r1056).
- Win32 r1059: 42.359 s, binary
  `c553b67352927d20d2f7d5fbcf9ea52de16b3efa8cc21bfcc1e94ca9efcf7343` (build r1057).

Ordinary user workflow/startup recovery, job blocking, ownership-aware working
data cleanup, scale and final release gates remain open. This change does not
enable the transfer command or modify a Desktop installation/user library.
