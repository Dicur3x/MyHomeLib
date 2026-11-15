# Update from a download folder while the original book root is unavailable

The review previously refused an unavailable original book root before looking
at a separately configured download folder. It now permits that workflow when
the download folder is explicitly configured and exists. A missing download
folder still fails; an unavailable original root without an alternative still
fails and asks the user to configure one.

Both review and apply summaries explain that the old root is unavailable and
that reading its old files requires reconnecting that disk/folder. The original
root is retained. New verified books keep their actual download locations; the
operation does not recreate the missing old folder or move book archives.

Existing full-index semantics remain: records omitted by the publisher can
leave an ordinary full catalogue, with the existing confirmation warning.
An unavailable unchanged historical archive alone is not a new publication or
a reason to request that archive again. New/changed members still undergo the
normal availability checks; this change does not invent readable old files.

## Native fixtures

The test deletes only its own private original ZIP and empty book directory,
leaving the catalogue, raw baseline, INPX and separately downloaded archives on
G:. This simulates a missing original directory; it does not disconnect a real
user disk or exercise network timeout behaviour.

The ordinary full-update case checks an old retained card and personal fields,
an excluded publication, an unchanged historical archive outside the download
request, and reading the correct newly downloaded member. Negative cases check
an absent alternative and a nonexistent download folder.

The merged-source case disconnects one source root, adds a downloaded book,
reads its actual member and verifies the other source's preferred copy,
retained personal fields and exclusions. The extended fixture also retains the
shared-profile/append/history regressions added in `8b88c60b`.

Final native build receipts:

- Win64: `update-offline-bound-build-Win64-r321`, SHA-256
  `849138692a5007eacb13921ab7fad867876f802c1bc19eed154b6cd0857d60cd`.
- Win32: `update-offline-bound-build-Win32-r323`, SHA-256
  `a3193ea5f9ca4149dd24896727dedfae33b4fa35a2af924100885a434ee3c7da`.

Final application reports: `update-offline-bound-Win64-r322` and
`update-offline-bound-Win32-r324`. The earlier Win64 ordinary-root pass
`update-offline-root-Win64-r319` predates the added merged-source case and is
not used as evidence for that case.

| Platform | Final application gate | Result | Seconds |
|---|---|---|---:|
| Win64 | `update-offline-bound-Win64-r322` | PASS | 69.016 |
| Win32 | `update-offline-bound-Win32-r324` | PASS | 65.515 |

Both reports verify removal of their private runtime and preservation of the
unrelated shared ZIP. The runs used separate profiles; times are not comparative
performance measurements.

## Scope still open

These are small ZIP/INPX fixtures. An INPX ZIP name whose actual retained
container was 7z needs separate missing-root comparison work: loss of the old
disk can prevent the normal ZIP-to-7z resolution and make an unchanged
historical container look changed. Compressed/packed histories, additional
formats, missing-drive/network behaviour, large catalogues, the warning's visual
layout and production-package validation remain separate gates. No Desktop
replacement or release has been performed.
