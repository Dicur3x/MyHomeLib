# Static SVG catalogue covers

Declared package covers can now render a static SVG instead of selecting its
first embedded raster picture. This includes an SVG cover part, one inline SVG
in a declared XHTML cover page, gradients/clipping, text, and compositions with
package-local raster resources. SVG image references are embedded into a private
drawing before the already shipped resvg helper runs. Simple wrappers around one
unmodified raster cover retain the existing direct-image path.

The helper comes from the KFX/AZW8 component; no new codec download or full-book
conversion is introduced. Existing standalone/FBD cover priority is unchanged.
Missing helper/resources and unsupported drawing features produce an explanation
and clear a previous book's image. External or active resources are not followed.
Document-level stylesheets are rejected explicitly rather than silently dropped.
The renderer uses available Windows fonts, so a missing original font can use its
normal fallback. Retail SVG variants and separate stylesheet support are not
claimed by these fixtures.

## Bounds and source preservation

The package reader retains its CRC/duplicate-path checks, 2 MiB XML limit and
16 MiB resource limit. Raster resources also pass the existing 64 MiB decoded
image guard. The prepared drawing is at most 24 MiB, its process is limited to
512 MiB and 30 seconds, and the result must fit 600 by 800 pixels and 4 MiB.
The existing cancellation callback covers validation and the contained child.
Only one SVG input is written in a fresh owned directory; its cleanup does not
recurse through unknown files. System-drive and working-volume space checks
remain active. Original books and their package members stay read-only.

## Defect and fixture findings

The first execution exposed `Attempt to modify a read-only node`: MSXML already
serialises inherited namespace bindings on a detached clone, and those generated
namespace attributes cannot be rewritten. An isolated COM probe reproduces the
failure and shows that inherited SVG/XLink prefixes survive serialisation.
The fix keeps these bindings and normalises a missing/empty root SVG namespace
only in the private serialised text. Namespace declarations are distinguished
from event attributes, including a valid SVG prefix named `on`.

An initial test expectation confused viewBox mapping with clipping to the viewBox
rectangle. The corrected fixtures separately check viewport padding and a
narrow viewport crop, with analytically specified red/green/white samples. No
production rendering change was made to satisfy those incorrect expectations.
The failed r1512/r1514/r1515 reports remain retained and are not counted as passes.

## Current evidence

Both current native binaries compile successfully with the licensed IDE's normal
AutoBuild interface. Architecture, linked marker and executable hashes are in:

- `G:/HL-b14-external/svg-cover-native-build-Win64-r1519/`
- `G:/HL-b14-external/svg-cover-native-build-Win32-r1519/`

Each actual catalogue fixture tests 26 SVG cases through the package reader and
asynchronous book-information panel. Positive cases check known composite pixels
and visible text, including inherited/missing/empty namespaces, gradients,
clipping, translation, embedded images and a simple raster wrapper. Negative
cases cover missing/external resources, escaped/incomplete CSS references,
active markup, external base, entities, oversized XML/resources, ambiguous SVG
selection and document-level stylesheets. A missing renderer, pre-cancellation
and cancellation of the running child are checked separately.

On each architecture there are 29 SVG PASS markers and 65 existing package,
catalogue and FB2 preview PASS markers (47 + 14 + 4). The latter retain the
earlier FBD priority, missing-cover/latest-selection and package extraction
checks. All source hashes stay unchanged, and both private runtimes are removed.
The resvg/boko bytes are taken from the sealed component; all 518 manifest
file hashes are verified before use. Evidence:

- `G:/HL-b14-external/svg-cover-validation-Win64-r1518/report.json`
- `G:/HL-b14-external/svg-cover-validation-Win32-r1518/report.json`
- frozen driver: `G:/HL-b14-external/svg-cover-validation-r1518.py`

These are generated SVG/geometry cases plus the recorded package regressions,
not an independent survey of every real vector cover or a full reading/export
matrix. Final Main/Reader runtime and release-package validation still remain.
No Desktop installation or public asset changed; all work stayed on G:, E: was
unused, and C: retained the required reserve.
