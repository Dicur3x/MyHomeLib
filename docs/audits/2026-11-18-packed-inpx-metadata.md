# Source metadata in packed INPX generations

The existing packed-copy INPX worker updated title/language/date and appended
series, but left author/genre memberships and the old primary series untouched.
The native packing-inpx-metadata mode reproduced the author failure on the
unchanged production implementation, after a real packed copy and INPX update:
packed-metadata-Win64-r1720-baseline/report.json failed with the old author.

StoreImportedBook now resolves incoming author/genre memberships in the private
catalogue and updates the incoming primary series through the existing delta
writer. This also applies to retained packed payloads when no replacement file
is available. The prior primary cycle remains a secondary membership under the
existing delta-writer policy. Personal fields and actual retained sizes/locators
continue to come from the old record. Incoming arrays are copied before
normalization; author IDs share the parser cache, genre registration preserves
existing aliases, and unchanged membership sets are not rewritten. Duplicate
incoming names/codes are compared as sets and the normal relation writers keep
unique links. No packing-module code or payload compression policy changed.

## Paired native gate

The fixture uses the sealed BookProcessing beta-14 candidates from r1559 and the
actual TCollectionPackingSnapshot, TCollectionPackingInpxWorker and native
progress/estimate form. It creates a packed copy, cancels/restarts an estimate,
updates a changed text payload and adds a new one. Another old book has no usable
replacement and keeps its packed bytes. Changed and retained books must both
receive exactly two incoming authors and genres, despite duplicate INPX tokens,
and the new primary series. Existing checks retain IDs, reading progress/rating/
note, old generations, source catalogues, last-arrivals selection and profile
continuation identity. Unsafe ordinary full import still refuses a packed file.

A third generation repeats the same INPX with the original-input directory
renamed away and an empty incoming directory. Its estimate must show exactly
zero new input bytes and its completed status must report every source reused.
The three readable text books retain content and IDs, corrected unique
memberships and personal reading data; the previous registered catalogue hash
does not change. The owned original/incoming folders are restored before exit.

| Architecture | Successful runtime | Native SHA-256 | BookProcessing archive SHA-256 |
| --- | --- | --- | --- |
| Win64 | packed-metadata-Win64-r1724-fixed | bd16058d52dc1f5ccd0973f440b066f906efb6add039587a4ec42c244ab39c75 | dc77176836f1e2705571b25643469cf855a09b2b4c4f4b6a784f4dc5fe972334 |
| Win32 | packed-metadata-Win32-r1726-fixed | 235d9e05f07331de11493741ec76df74d7881af6c063647453a8355b2ba131ee | 6fc3ed77a9b688aa9dcf2a705d2abc149f3594b073f46e4cd984e7d56df31bb9 |

Both processes pass all seven result markers; their private runtimes are
removed. The initial fixed r1722 run had passed the metadata assertions but
failed a fixture assumption that every estimate has positive new input bytes.
The shared probe now explicitly distinguishes positive-input operations from
a retained-only repeat, whose expected value is exactly zero. The old default
remains positive. r1722 is recorded as a failure, not a completed gate; its
private runtime is also removed. The production metadata fix was unchanged.

## Ordinary builds and scope

| Architecture | Main receipt folder | Main SHA-256 |
| --- | --- | --- |
| Win64 | packed-metadata-main64-r1727 | 63259de5a827d542a31671dc57c1914127b2cdb16c0758eb1f98e68196277942 |
| Win32 | packed-metadata-main32-r1728 | 799d0d40be4961bd12a84e632594328f2d931d194b26eef703f39b5913b5751d |

The ordinary Main and native projects build on both architectures through the
licensed IDE. Receipts verify fresh architectures, unchanged projects and
removed owned build temporary folders. 698 source hashes match the primary
source and production mirror. All evidence is bound in
G:/HL-b14-external/packed-metadata-validation-r1726/summary-r1729.json.

This verifies small generated TXT/ZIP data with stable nonempty library IDs.
It is not all-format or empty-ID coverage, a large-catalogue performance claim,
or completion of packed/online application through the new source-profile
window. That window still refuses packed application; its logical publisher
mapping and publication path remain to be integrated. This batch fixes the
existing separate-generation INPX command, not those unfinished requirements.
Main resources remain beta 13; no E:, user-library writes, Desktop replacement,
final distribution or publication occurred.
