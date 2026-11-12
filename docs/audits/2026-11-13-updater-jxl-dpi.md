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
