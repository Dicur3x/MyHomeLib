# Library update sources: model checkpoint

The settings model in `unit_LibraryUpdateSources.pas` now represents a local/network folder or HTTP/HTTPS base, index/version file names, full/delta mode, enabled state, book root and optional stable `TCatalogSource.ID` binding. Every profile has its own GUID. Renaming its display name leaves the GUID/binding unchanged. JSON version 1 rejects invalid IDs, duplicate IDs, unknown schemas, traversal and drive-relative/current-drive folder paths. Profiles are intended to be stored with the collection rather than matched to its display name; that storage/UI integration is still pending.

The legacy importer reads physical lines instead of INI keys so repeated keys cannot erase profiles. On the user's supplied `collections.ini`, all 11 update descriptions survive, both `Update9` entries remain distinct, and the undefined `Group5` is diagnosed. Individual source locations are preserved. The extra INPX creation templates are inspected for group diagnostics but are not silently installed/rewritten. Legacy export retains the original first six fields and adds stable profile/source IDs, book root and enabled state for the new reader; JSON/INI roundtrips preserve those fields. Older readers do not understand the new binding/enabled fields, so export is not a promise of identical automatic dispatch in an older application.

`LibraryUpdateSourcesTest` ran successfully on x86 and x64 with the real supplied file, which remained byte-exact. Evidence: `G:/HL-b14-external/update-sources-model-r207.json`; native binaries `dea39e81e621c3b865ae02e05ab020ebf16660f22ab366ce2c29af182a274618` (x64) and `49360b0a022e901999b1e42b513caeb2a885870e18802d143b19549b13227a52` (x86). These are settings/parser checks, not HTTP, UI or catalogue updates. The diagnostic has an `asInvoker` manifest and needs no administrator access. Build the default Win64 target first when regenerating its project resources, then Win32, as required by the existing IDE build wrapper.

Remaining integration:

- One understandable source editor, attached to the current collection, with explicit binding to a merged source. Imported legacy templates must not all become enabled updates of the current collection.
- Correct/bypass the old `TUpdateInfoList.Add` global-URL substitution. Its existing path is unchanged by this pure model checkpoint.
- Immutable, owned staging for remote and local indexes; cancellation/free-space checks and cleanup must never delete a user-selected original. The old update thread's blanket cache cleanup must not be reused for arbitrary external paths.
- Preview version, actual additions and exact relevant missing archive names using previous state where available. Do not treat intentionally removed old duplicates as downloads, and do not infer correctness from date or numeric archive ranges alone.
- Apply through the existing INPX/Metabib/import/merged-source paths, retain personal/compression state, then offer incremental compression. Add the separate library-update toolbar entry and context help.
- End-to-end x86/x64 application checks and final production/package/release gates. No Desktop replacement or publication has been performed.

Disk-intensive work remains subject to the 8 GiB system-volume guard and uses G: for this task's builds. The user authorized forwarding the same request to the game-project chat; two send attempts returned the service's history-rate-limit error, so delivery is not claimed. No files of that active task were altered.
