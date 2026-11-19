# Direct MOBI and KF8 catalogue covers

The catalogue information panel reads explicitly declared MOBI/KF8 cover or
thumbnail records directly from the held raw-book stream. It reads no text
records, does not decompress book text, creates no conversion work folder and
does not require KindleUnpack or BookProcessing to show the cover. Books inside
an outer archive still need the existing selected-member extraction/cache path;
the bounded metadata-read figures below do not include that extraction cost.

The reader accepts the Palm `BOOKMOBI` family (MOBI, AZW/AZW3/AZW4, PRC and PDB
suffixes), with content validation. EXTH cover metadata takes precedence over
the thumbnail. With neither field present it returns an explanation instead of
guessing the first illustration. The information panel retains its existing
FBD/companion-cover precedence. Thumbnail fallback is labelled as a thumbnail.

The table and offsets are validated before access. Metadata is bounded to
1 MiB per header; an encoded cover to 16 MiB, with the existing separate 64 MiB
decoded-image budget. Cancellation is checked while reading and traversing
records, and the caller's stream position is restored on success, failure and
cancellation. A combined MOBI7/KF8 book follows only its declared second-header
index and a valid boundary. The target image and boundary must lie after the
declared text-record range. Malformed, duplicate and oversized metadata produce
an unavailable-cover explanation; they do not redirect to another image.

The record layout was checked against the primary
[KindleUnpack header implementation](https://github.com/kevinhendricks/KindleUnpack/blob/master/lib/mobi_header.py)
and [Palm record reader](https://github.com/kevinhendricks/KindleUnpack/blob/master/lib/mobi_sectioner.py).
No library code or new runtime dependency was added for this reader.

## Evidence and limits

The focused native fixture wraps a real file stream and rejects reads overlapping
text records. It checks exact cover bytes, cancellation and caller position.
Cases cover MOBI6, KF8, combined headers, compact EXTH values, missing resource
base, thumbnail fallback, missing/duplicate/invalid metadata, invalid tables,
oversized images, a four-MiB text body and two real books from the existing private
metadata fixture. A separate case cancels after reading over 64 KiB of an image.

The two real books are about 25 MB each; each declares the same 229,591-byte JPEG
cover. The focused reader consumes 233,605 and 233,984 bytes respectively,
including the table/metadata. These are direct reader counts, not a catalogue
startup or total archive-I/O benchmark. Their exact original SHA256 values are
`650ec367ded641382f09c741585e37fe4b788c9337b297808961fd22ca89aa14`
and `7d22f45b5f2f19a1af24e854ac5ecf62eb0a9b532f38f0cb556caf18220d8cae`.
The independently selected JPEG SHA256 is
`f5906d62e81d6c91a91ba4e8979206f3f5dbdccf8a5ee7ce1d08804a46636d58`.

The panel fixtures compare decoded dimensions and pixels for the declared image,
KF8/combined books, aliases, an outer ZIP, FBD precedence, a thumbnail and both
real books. Missing or bad images clear the previous cover. The private runtime
has no whole-book Kindle/BookProcessing module. The same native binaries also
exercise existing package/FB2/XPS cover behaviour.

Final validation is PASS in
`G:/HL-b14-external/kindle-cover-validation-r1348/summary.json`. Win64 r1341 and
Win32 r1344 each pass 40 focused cases, including both real books and cancellation
after 65,846 image-read bytes. Both aborted reads return no bytes and restore
the stream position. The guarded panel builds r1343/r1346 pass the combined
r1345/r1347 suites: 16 Kindle checks, 46 package cases plus cancellation,
15 existing package-panel checks, four FB2 asynchronous checks and four XPS
checks per architecture. Totals are 80 focused cases and 172 panel/regression
checks; repeated earlier runs are not added to those totals. Original hashes
and private-runtime removal are verified. The report binds the eight changed
source/test files and checks binary hashes/PE architectures; it is not a complete
production-app input manifest.

The first fixture build r1321 failed because a JSON variable shadowed standard
output; this was corrected before testing. Earlier passing runs preceded the
additional invalid-text-pointer guard. The real before/after regression is
r1340: the previous Win32 driver attempted to read a text record for a forged
cover pointer and the counting fixture rejected it. The updated reader refuses
that metadata before touching the text. Those earlier passes do not replace
the final guarded cohort.

All tests use private G: copies; C: retains its 8 GiB reserve and E: is not used.
This does not add KFX/AZW8 cover decoding, infer a cover from HTML text in older
MOBI books, decrypt anything, or validate a physical Kindle. Those cases remain
distinct from the declared-record path. Final production apps/packages, Desktop
installation and publication remain separate gates.

## Five unmodified legacy MOBI fixtures, 19 November

On x86 and x64 the catalogue displayed the declared 731 × 817 cover for the
CP1252, multimedia and uncompressed Unicode samples. In all three, the first
illustration had different bytes from the declared cover. The version 4
dictionary and NCX sample had no declared cover and the catalogue cleared
the preceding image. KindleUnpack independently read the metadata and markup.
The native panel checks compared image dimensions and the centre pixel.

All five files came from the [libmobi fixtures at the tested revision](https://github.com/bfabiszewski/libmobi/tree/906274205c11944b628da1c553b255acb1af7c55/tests/samples).
None declares a cover solely in its HTML guide. A separate controlled copy
keeps the first rendition of the Unicode sample, removes the EXTH cover and
thumbnail, and points a guide reference of type `cover` at the second image.
In the markup decoded by KindleUnpack, byte 887 starts the image tag that
references the expected JPEG. The current x64 panel reports an absent cover for that copy. This
reproduces the outstanding guide-only case separately from the five originals.
The input and resource hashes, binary hashes and both run logs are in
`G:/HL-b14-external/r2000-kindle-guide`.
