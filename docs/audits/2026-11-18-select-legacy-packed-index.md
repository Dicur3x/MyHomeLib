# Select an earlier INPX for a legacy packed collection

The source editor offers a previous full INPX field for a standalone legacy
packed catalogue with original file paths. The entry is optional in JSON and
as an extension to the legacy INI fields. An applied publisher history takes
precedence over the selected file.

The review imports a private staged copy of the selected index. It requires
the original catalogue version when that version is recorded, and compares
the original file path, name, format, library ID and date for each live
publisher card. Where the original file path records a 7z archive and the
index names the corresponding ZIP, the comparison can use that documented
alias when the original folder is unavailable. A match still requires the
other identity fields and uniqueness.

On confirmation, the programme registers a new packed generation and stores
the publisher history. The prior generation and the selected INPX are kept.
Later updates read the saved history even when the manually selected file is
unavailable. Without a saved history or a matching full previous index, the
normal source preview stops and identifies what is needed.

## Verification

The native test opens the actual source editor and fills the previous index
field. It checks a missing selection, a mismatched version and a different
book in an otherwise matching index. The original catalogue hash and work
directory count agree before and after the rejected reviews. JSON and INI
round trips preserve a file path containing Cyrillic and spaces.

The fixture emulates the old schema by removing the publisher metadata table
from a private packed catalogue with small TXT/ZIP and TXT/7z files. The source
archive folder is then hidden. The ordinary update window applies a delivered
book and keeps a previously deleted card excluded, an untouched 7z-backed
book readable, and a missing replacement pending. The second apply runs with
the manually selected index offline and reads the delivered replacement.
It verifies the original catalogue hash and saved personal data.

The initial runtime caught a parser invoked before its worker had initialized
progress reporting. The final path starts and waits for that worker using the
same entry point as the existing saved-index recovery.

Both architectures passed the manual selection, saved legacy history,
current packed INPX and regular source-profile checks. The aggregate covers
eight native runs, four builds, and 701 matching source and help files.
All private test profiles were removed. The validation record is
`G:/HL-b14-external/packed-legacy-manual-validation-r1822/summary.json`.
The local Russian help check passed all 55 topics.
