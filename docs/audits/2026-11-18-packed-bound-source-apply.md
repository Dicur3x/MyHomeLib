# Update one source in a packed merged collection

The reviewed INPX update resolves the chosen source's logical key to a live
copy in the packed catalogue. The merge uses that key even if packing or
delivery changed the physical archive path. A title correction can reuse
the already packed bytes when the publisher's file identity, size and date
agree. The confirmed update applies to private copies of the catalogue and
personal database. The updated collection is registered after packing.

An undelivered replacement stays pending in the publisher history. The
previous copy remains readable, and the review can identify the archive to
deliver. A publisher omission in this bound path leaves the already
installed copies available.

## Native verification

The fixture builds two sources and merges them by source priority. It checks
that two distinct payloads initially belong to one card before and after
packing. Both original source folders are then hidden. A full INPX adds a
book, corrects a title using the existing packed copy and reports the one
missing replacement archive. An incremental delivery replaces only that
source's copy when the archive arrives. A repeat review reports zero changes.

The fixture verifies exact readable content for both copies, stable book IDs,
the preferred source and path, the metadata-only copy's existing path, ratings,
progress, review, favorite group membership, source-specific publisher history
and the original packed catalogue hash.

The direct worker fixture, the existing standalone packed source window
fixture and the ordinary reviewed update matrix run on Win32 and Win64.
The ordinary matrix also covers 7z aliases, offline historical paths,
exclusions and rollback. Both production Main binaries build. The complete
validation record, including the executable hashes, 700 matched build
inputs and process cleanup, is
`G:/HL-b14-external/packed-bound-validation-r1798/summary.json`.

The first fixture used different titles on the two original copies. Merge
correctly kept them as separate cards, so that run could not test replacement
within one card. The current fixture requires the intended merge before any
update and gives the two payloads different text.

The inputs are small TXT books in ZIP archives under isolated profiles on G:.
Legacy source histories, publisher inputs other than INPX and large packed
catalogues still need their own coverage.
