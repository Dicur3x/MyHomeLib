# JPEG XL update report and initial updater DPI

These are local beta 14 changes. Neither the Desktop installation nor published packages were replaced during these checks.

## slade60's supplied update report

The request specifies `v0.13.0`, while the prepared official JPEG XL manifest specifies `0.13.0`. The installer's exact release check rejects that mismatch. The supplied screenshot already shows the catalogue itself running beta 13; that does not mean that all component installations succeeded.

The official x64 libjxl 0.13.0 package has SHA256 `e394519c05ea9e5b83947f89b40afbf1ea7c631a608406c5de945a4c5bdcdcb7`, exactly matching the supplied request. Its 12 prepared decoder files match every path, size and SHA256 in the supplied manifest. Running the native verifier with the old request label reproduces the reported Russian error. The corrected numeric identity verifies and installs. The original supplied files remain unchanged.

The prior updater fix persists the prepared numeric version, repairs the narrowly identified old official JPEG XL cache after verification, and keeps a live installation helper instead of copying over its running EXE. The prepared manifest is not rewritten and an unrelated version mismatch still fails verification.

`test_official_image_update_identity.py` passed with the unmodified official 0.13.0 x86 and x64 packages. It checks separate decoder and encoder installation, combined installation, preservation of the target EXE and personal note, wrong-version rejection, and 282-character prepared paths. The x64 run additionally reproduces the supplied manifest/request. Download transport uses an owned loopback server; official URL selection, archive hashes, native preparation and installation remain real.

`test_image_update_form.py` passed five native assertions per architecture with 0.13.0: ready-cache recovery without downloading again, a real running helper's Windows sharing violation, repeated installation keeping exactly one helper and the original request bytes, a new attempt after the helper exits, and the production ShellExecuteEx process handle. Private runtimes were removed.

Evidence directory: `G:\HomeLibRu-build-cache\HomeLibre-post13-updater-report-20261112`. Reports: `identity-Win64-0.13.0-reported-final.json`, `identity-Win32-0.13.0.json`, `form-Win64-0.13.0-final.json`, `form-Win32-0.13.0-final.json`.

## Initial high-DPI updater font

The form creates logical-DPI child controls, but previously assigned an already scaled system message font without first normalizing the destination font's DPI. Subsequent form scaling enlarged those font pixels again. The updater and its release-notes view now establish the destination font DPI before assigning or deriving fonts.

`UpdateInitialDpiTests.inc` first reproduces the former double enlargement at 216 DPI (225%). The fixed form passes 12 combinations of 96, 144, 192, 216, 240 and 288 DPI with light and dark themes. Assertions cover form and component-list font pixels, release heading/body point sizes, and measured button-caption width and client bounds. Both x86 and x64 pass.

The regression models the initial system-font state and requested VCL DPI inside an isolated native process. It does not change Windows display settings and is not a physical test on a second 4K monitor at 225%. Existing real-window updater-theme checks remain separate. The final production packages and their initial display at the reporter's actual Windows configuration still need verification.

Evidence directory: `G:\HomeLibRu-build-cache\HomeLibre-post13-covers-20261112`; reports `initial-dpi-Win32.json` and `initial-dpi-Win64.json` retain exact binary hashes and outputs.

## Populated window and verified ready download

The additional `update-populated-dpi` native mode now covers the remaining
populated-window scenario. It uses the real updater and normal JPEG XL
download/preparation worker. Only transport is redirected to an owned loopback
server. The exact official 0.13.0 archive is checked against its release size
and SHA-256 before staging and again by the production verifier.

The private runtime also contains published Reader, BookProcessing,
ImageProcessing, Kindle and FB2Export files. Their source ZIPs were verified
against GitHub asset metadata fetched on 13 November. No installed user files
or books are used as the target. The feed is parsed with the same verified,
partial-feed flags used by the production component-mirror reader; it does not
fabricate component versions or download URLs.

Each architecture passed eight cases: light/dark themes at modeled 216 DPI,
release-notes zoom 90/100/110%, and the history tab. The populated list has ten
rows. Assertions cover font height, column-header widths, button-caption widths
and client bounds, tab/button separation, room for at least four data rows and
a useful notes area. Restored release text still contains the official
`Security` section. One download supplies every case: no repeat download,
changed manifest, installation request, or reopening after Close occurred.

| Architecture | Final native executable SHA-256 | Result |
| --- | --- | --- |
| x64 | `40ca2f58efc1cfb3f2c7ad7a31627369f90803afe7679f256afa8a896e937387` | 8/8; exit 0 |
| x86 | `7f37b79d857fa2f2659b7fd091e15335c531aaccba7e291e4641dd2b859e0e5f` | 8/8; exit 0 |

Reports and client PNGs are in `populated-dpi-Win64/` and
`populated-dpi-Win32/` under the same evidence directory. Private runtime
directories were removed. Failed fixture attempts remain in each report's
`history/`: early input selection confused the retained 0.12.0 archive with the
0.13.0 one, and the first feed-metadata snapshot predated beta 13 publication.
The final runner validates all actual inputs. These failures are not counted
as passing UI checks.

After the AMD driver interruption reported by the user, Computer Use again
captured the actual dark ready-update window at the modeled 225% scale.
Component headers, versions, action buttons and release text were visible.
This supplements the client-image captures, which omit some native child
painting. It remains a simulated initial VCL DPI on the available monitor;
RichEdit renders using the monitor's real device DPI. It is not proof of a
physical 4K-monitor configuration or a Windows display-setting change.

The populated-window gate is locally verified. Installing the eventual
beta 14 distribution, including its matching updater and final archive names,
remains a separate release gate.
