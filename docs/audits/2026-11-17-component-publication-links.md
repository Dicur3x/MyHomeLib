# Public component links before beta14

Read-only inspection of the shared component release on 17 November 2026:
[HomeLibre components](https://github.com/Dicur3x/MyHomeLib/releases/tag/optional-alreader-2.5.1009.25).
The historical tag is a stable download location, not an AlReader-only page.

Evidence is saved in `G:/HL-b14-external/component-publication-audit-r1298`:
release metadata, the exact live and beta2-backup JSON bytes, and summary.

- Live `HomeLibRu.components.json` SHA256:
  `ef8f3687651bb4f4e89e88a397028e61d45ca41d196139d0546f0748aecd71dd`.
- Backup `HomeLibRu.components.beta2-backup.json` SHA256:
  `04b2ffae3e44db73d3eba3785fa2c6f7495f80c1b48fe4a7e6d9675f7f67e68b`.

The live Reader entries retain version 3.0.0.8 for legacy clients and nested
`minimal_reader` version 3.0.0.13 for current clients, on both architectures.
The older Reader 3.0.0.2 is still referenced in the separate beta2 backup.
That backup reference alone is not evidence that an active updater currently
uses it; it is a dependency to consider before discarding rollback artifacts.
No compatibility asset is proven safe to remove merely by a newer version's
presence. Component ID `HomeLibReader` and historical asset names remain protocol
identities despite the current visible HomeLibre Reader / HomeLibreReader.exe.

The release body's links still name two nonexistent Reader assets:
`HomeLibRu-HomeLibReader-3.0.0.11-Win32.zip` and
`HomeLibRu-HomeLibReader-3.0.0.11-Win64.zip`. Correct the body against the final
published feed/assets during beta14 publication. Do not blindly replace only a
URL while leaving an old displayed version, size or checksum beside it.

The local optional-component guide now distinguishes portable, compatible
update and full archives, explains the full-builder's explicit checked inputs,
and separates the historical October validation from current release gates.
Final feeds/packages, legacy-client transition, offline/clean-Windows behavior,
licence/source inventory and later cleanup remain open. The component release
body, feeds and assets were not changed by this audit.
