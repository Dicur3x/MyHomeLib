# Local INPX wizard assertion

Report: slade60, creation from a local index in beta 13. The dialog names `frame_NCWInpxSource.pas:252`. This is the build-time source location, not a long path being opened on the user's computer.

The same line in the published `3.0.0_pre1.13` tag unconditionally asserts that `lvCollections.Selected` exists, before checking whether the user selected a local file. Thus a clean installation with no optional server catalogue entries fails even with a valid local INPX. No index content needs to be malformed to trigger this check.

The local branch now checks the chosen file independently, restores the local import operation and clears a stale download URL. Server selection is required only for server downloads, with an explanatory inline message for a missing choice or missing server. Back navigation remains possible without a valid selection. Refreshing the server list clears removed entries. The source page also remains available when returning from a download operation.

Native `CollectionViewsTest inpx-local-source` ran on both architectures with assertions enabled. The test covers an empty server list, empty/missing local file, valid local file without a server selection, selected download without connecting to a server, missing download selection, switching download to local, and reloading an emptied list. The actual wizard's Next and Back buttons then read a real generated INPX and complete collection creation/import with exactly one author and one book. Book and index SHA-256 are unchanged. Temporary profiles, source files and the registered test collection are removed by the isolated runner. No user collection is used.

| Architecture | Result | Native EXE SHA-256 |
|---|---|---|
| x64 | 0; both source and complete-wizard groups passed | `455eaeb7eea3d8ac26dffecac206afad13ddee3caf1c175359a7b1b87ca2457c` |
| x86 | 0; both groups passed | `1728350f0060f187b000282bc54f1f8a81473dcf05aa618a846076c8b33c543f` |

Reports: `G:\HomeLibRu-build-cache\HomeLibre-post13-raster-initial-20261113\inpx-native-Win64\result.json` and `inpx-native-Win32\result.json`. The test source is `tools/ui/tests/InpxWizardSourceTests.inc`. This is a local beta 14 fix; the final distribution and public update remain separate release work.
