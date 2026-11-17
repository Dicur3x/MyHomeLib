# Real CHM and LIT export follow-up

This follows the 26-family backend matrix and the separate EPUB/DOCX/ODT
regressions in `2026-11-17-export-matrix-followup.md`. It resolves the observed
CHM and LIT failures; it does not complete the full reading/export requirement.

## Repairs

- LIT HTML streams live at `/data/<internal>/content`, while image/style streams
  live at `/data/<internal>`. The isolated GPL adapter now uses that distinction
  from the pinned calibre `LitContainer.read` contract. Its native decoder is
  unchanged.
- A LIT guide can declare a cover outside the text spine. The full declared
  cover is retained and identified as the EPUB/FB2 cover; standard preview images
  are a fallback, and thumbnails or arbitrary illustrations are not guessed to
  be covers. An existing inline copy is not inserted twice.
- The real CHM contains two malformed empty layout images, written as
  `<IMG border=0 height=1 src= width=4>`. A bounded pre-HTML5 pass recognizes this
  narrow empty-spacing case before the HTML5 parser turns it into a quoted
  `width=4` filename. It becomes a space, retaining its anchor/class. Genuine
  quoted filenames, meaningful alternative text and other missing resources
  retain normal resource validation.
- Duplicate legacy HTML IDs are made unique without taking genuine later IDs.
  Links retain the first explicit ID target, falling back to a named anchor, as
  HTML fragment navigation specifies. Text and illustrations are retained.
- External URLs in the private Kindle input are percent-encoded. Cyrillic mail
  subjects and spaces no longer fail writer validation; local targets and
  already escaped URL octets remain intact.
- KindleUnpack generates invalid navigation XML for INDX captions containing a
  bare `&`. Only its generated navigation receives this narrow escaping repair;
  entities, comments and CDATA are retained, and the result must still pass the
  strict XML reader. Other malformed XML remains an error.
- A declared single-frame GIF cover is prepared as PNG for the Kindle writer
  using the bounded Windows image helper. Its pixels are retained. Multiple
  frames are rejected explicitly instead of silently losing animation. Writer
  validation and independent readback remain enabled.
- Static HTML anchors in Markdown now pass through the existing HTML content
  filter. Paragraphs inside `.md` no longer cause a genuine Markdown document to
  be treated as an HTML fragment. Scripts, event attributes and executable links
  still do not enter the reading copy; escaped prose and code remain literal.

## Actual sources and verification

The original source members were extracted read only and checked against the
earlier collection inventory:

| Input | Book ID | Original source SHA-256 |
| --- | --- | --- |
| CHM | 776538 | `19a7902b65a1f963f08a9becd83c15e8fa755758f8112aa8650a19bb8d211c1c` |
| LIT | 732247 | `d22673679e0a74414297abc0a2da694b64564e3e86e17af60a5ee863a21b2159` |

CHM reference extraction reads all 25 original HTML parts independently through
the pinned 7-Zip, collecting 37,145 prose words and one distinct referenced image.
The two empty spacers are recorded as source defects. LIT reference extraction
uses the inspected upstream read method and a separate HTML event parser,
collecting all 8,909 prose words and the explicit 480 × 240 cover.

The initial LIT image oracle incorrectly required all five guide images. The
source has no inline image elements: four guide resources are thumbnails or
standard MS Reader UI previews, while `other.ms-coverimage` identifies the full
cover. The corrected reference records every guide role and pixel hash, requires
the explicit full cover, and retains the original reference and its hash. It
does not erase a production failure by silently changing the source fixture.

Each architecture completed 22 exports: both inputs to FB2, EPUB, MOBI, AZW3,
EPUB 2, EPUB 3, KEPUB, KFX, AZW8, PDF and Markdown. Of those, 16 per architecture
also passed independent prose-order/count and decoded image-pixel comparison.
MOBI/AZW3 and Markdown were read back as EPUB. Generated chapter XML is checked
for a single HTML/body structure. Source hashes remained unchanged.

PDF/KFX/AZW8 account for six backend-only successes per architecture. Their
independent content checks and physical device behavior are not established here.

The four relevant unit suites completed 113 methods successfully, including
negative cases for genuine missing images, quoted filenames, duplicate anchors,
Markdown scripts/code, cover selection, animation and malformed navigation XML.

## Evidence and remaining work

- Consolidated receipt: `G:/HL-b14-external/legacy-export-validation-r1403/summary.json`.
- Real reports: `legacy-export-content-Win64-r1401/report.json` and
  `legacy-export-content-Win32-r1402/report.json` under the same evidence root.
- Unit log: `G:/HL-b14-external/legacy-cover-nav-unit-r1400.log`.
- Independent references and frozen upstream read method:
  `G:/HL-b14-external/legacy-resource-diagnosis-r1382/`.

Both fresh private runtimes were removed, and their recorded Python overlays
match the current source files. They used explicit pinned packages plus local
matching Windows helpers. These are development validation cohorts, not final
beta 14 module packages. Earlier matrix runs retain their own source hashes.

The full task remains open for native TXT/FB2.ZIP and unchanged-source saving,
unclassified/nested/oversized source groups, independent remaining outputs,
cancellation, current native UI and final packages. E: was not used.

Primary implementation reference:
[calibre LIT reader at the pinned commit](https://github.com/kovidgoyal/calibre/blob/1c1b407d76e23d4a1294d61bf73d915f247e3b83/src/calibre/ebooks/lit/reader.py).
