# Production Reader after compression of bound FLibrary sources

The x64 bound-source fixture and actual production Main/Reader inspection
passed on 15 November 2026. User collections, Desktop files and public releases
were not modified.

## Scope and result

The existing `reviewed-flibrary-compression --reviewed-flibrary-bound` scenario
compressed eight physical copies of four books in two separately stored
FLibrary sources. It applied reviewed full and append INPX updates, corrections
from each source, downloaded a fifth book with external images into another
folder and compressed only that arrival. Native checks passed for restored text,
resources and covers, measured physical and personal-card sizes, source priority,
personal data, unchanged neighbours and repeated new-only selection.

The ordinary `HomeLibre.exe` then displayed the five visible books. Computer Use
opened EPUB 101 and FB2 301 in the actual `HomeLibreReader.exe`, inspected their
external illustrations, paged each once, closed each normally and reopened each
without navigation. Exact persisted positions matched:

| Book | First close | Reopen and second close | Visible progress |
|---|---:|---:|---:|
| EPUB 101 | 384 | 384 | 23% |
| FB2 301 | 464 | 464 | 28% |

The observer now includes `second-flibrary-source` in its protected-file
snapshot when inspecting the bound variant. All files under both original
source roots and the arrival root remained byte-identical throughout reading.
Catalogue BookSize and Review stayed unchanged; persisted Progress was positive.
All four real Reader sessions and Main closed normally, Main exit code was zero,
and session requests were removed. The parent runner removed the owned runtime.

## Reproducibility

Evidence: `G:/HL-b14-external/bound-reader-Win64-r613/`:
`catalogue-Win64-apply.json`, `catalogue-Win64-reader.json` and native log. Both
reports are PASS. The 368.984 seconds includes native processing and manual GUI
inspection; it is not a compression speed benchmark.

- Native host build r612, SHA-256
  `05a0083992ea1ccd5d291b9683405cffae3244cc713c27b06c426f6450b80c02`.
- Production Main SHA-256
  `3e040e144da608d9a7c2b699a74425c34649e05fa3c3c72ed4bbe76f04c0f5ab`.
- Production Reader SHA-256
  `d44ccf0fcd36773ceb9b7ba4c16760b8592ad7ceb7c893769fb23d8f609a970a`.
- BookProcessing 3.0.0.14 package SHA-256
  `e920f4aac2310f7c96bd677d55381f45f2ef9dc12fe90129e2749834f553d7a6`.
- Official libjxl 0.13.0 x64 archive SHA-256
  `e394519c05ea9e5b83947f89b40afbf1ea7c631a608406c5de945a4c5bdcdcb7`.

Eight tracked regression entry points still referenced the former
`Program/MyhomeLib.res` and `.dres` paths after the production project rename.
They now use `Program/HomeLibre.res` and `.dres`; no historical protocol or user
profile identifier changed. The fresh CollectionViewsTest build linked the
current bound-FLibrary scenario and canonical resources successfully. The other
seven entry points' resource paths were checked against existing resources;
they were not all rebuilt in this run.

## Limits

Positions here were created after compression and INPX. A real pre-existing
Reader position across a new compression remains a separate check. This run
covers the generated x64 bound fixture, not the user's full collection, other
FLibrary layouts, every format or a final beta 14 distribution. Production
binaries still have numeric release identity 13. Final application/package
builds, remaining storage/recovery checks, Desktop replacement and publication
remain open.
