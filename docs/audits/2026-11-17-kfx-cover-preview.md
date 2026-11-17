# Declared KFX and AZW8 covers

The catalogue preview now requests the explicitly declared KFX/AZW8 cover
through the optional KFX module. Opening the container reads metadata and its
resource index; the command does not load chapters or convert the book. A
missing declaration stays missing even if the book contains illustrations.
Existing separate covers and FBD descriptions retain their earlier priority.

The native caller holds its existing raw-book lease while the helper reads the
file, including a KFX selected inside an outer ZIP. It accepts at most 16 MiB of
output, contains the process tree with a 512 MiB per-process ceiling, and
supports cancellation and a 30-second deadline. The helper admits only a
regular input of at most 64 MiB and an explicitly referenced supported raster
image of at most 16 MiB. Missing/old modules and damaged containers give a
preview explanation. No fallback picks an arbitrary first illustration.

The new `boko cover` command writes only image bytes to stdout, or no bytes
when metadata has no cover. It creates no output file. Its source modification
remains in the existing GPL-3.0-or-later optional tool and corresponding-source
package; the native interface remains in HomeLibre.

## Evidence

Both native test binaries build successfully through the licensed IDE's
documented AutoBuild interface. Platform, linked feature marker, binary SHA-256
and immutable project checks are recorded in
`G:/HL-b14-external/kfx-cover-native-build-Win64-r1498/` and
`kfx-cover-native-build-Win32-r1498/`.

The current x86 and x64 cohorts each pass eleven inputs through both the native metadata
reader and actual asynchronous catalogue panel. It includes a synthetic book
whose first illustration differs from its declared cover, a book with images
but no declared cover, KFX/AZW8 produced from retained actual FB2/CHM/DOCX
sources, the declared-cover KFX inside ZIP, damaged/truncated containers and
an input over 64 MiB. A separate KFX Input reader resolves the declared resource;
all returned cover bytes match it exactly. The panel checks image dimensions
and clears the previous image for absent/damaged books. Missing module,
pre-cancellation and cancellation of the active child process also pass.
All source hashes remain unchanged and the private runtime is removed.

Frozen driver and reports:

- `G:/HL-b14-external/kfx-cover-validation-r1502.py`
- `G:/HL-b14-external/kfx-cover-validation-Win32-r1502/report.json`
- `G:/HL-b14-external/kfx-cover-validation-Win64-r1502/report.json`

The earlier ten-input x86 cohort in r1500 is retained; the later cohort adds a
positive AZW8 cover rather than counting an absent AZW8 cover as positive proof.
These generated KFX/AZW8 samples are not a survey of all retail/device variants.

The fresh runtime builds are in `kfx-cover-module-build-r1497`; the separately
verified corresponding-source archive is in
`kfx-cover-corresponding-source-r1501`. Both use the pinned upstream sources and
current patch, including the prior navigation/linked-image fixes. They remain
unpublished candidates of component 3.0.0.6; previous reports retain their
previous package hashes and are not relabeled as this candidate.

The fresh sealed packages are in `kfx-cover-packages-r1504`. A separate verifier
checks all 518 manifest files and ZIP CRC on each platform, the exact tested
native-cover tool identity, and the matching patch/build script in the complete
corresponding-source archive. Evidence:
`G:/HL-b14-external/kfx-cover-package-validation-r1505/report.json`.
This binds the native executions to the packaged bytes without rerunning the
same eleven inputs solely because those bytes were placed in a ZIP. It does
not replace the final clean-install/update checks.

## Remaining checks

Ordinary final production applications and release/update installation checks remain.
Pure vector SVG and old Kindle books without declared cover metadata remain
separate work. No Desktop installation or public release has changed.
