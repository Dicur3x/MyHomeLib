# Optional MCP server

The minimal catalogue archive no longer contains `MHLMcpServer.exe` or the unused
`HomeLibRu.url` shortcut. Existing installed servers remain usable. Full developer
packages can still include the server.

The catalogue's **Инструменты → Подключить AI-ассистента…** action requests the
server only when it is absent. The compact installation prompt shows its purpose
and download size. Cancelling installs nothing. After installation and restart,
the same action shows a stdio configuration for the current catalogue profile.
The catalogue does not launch an AI application or connect it automatically.

MCP is excluded from standalone Reader component lists. Its update notifications
are disabled by default, as with other optional components. A missing README or
licence file does not make an existing executable unusable; newly installed
packages must contain both documents.

## Packaging

Run `scripts/package-mcp-component.py <new-output-directory>` with Python after
building the server in Delphi. It performs no downloads or compilation. Both
architectures use the permanent component release tag, rather than an application
release tag. The package can install only these files:

- `MHLMcpServer.exe`
- `MHLMcpServer-LICENSE.txt`
- `MHLMcpServer-README.txt`

Each ZIP also contains its verified archive manifest. Existing SQLite and user
profiles are reused, never packaged with the server.

## Verification, 28 October 2026

Release native checks passed on Win32 and Win64 using the actual packaged
`MHLMcpServer.exe` version 1.0.0.0, not a server stub:

- Default and Unicode custom profile configuration; light and dark layouts at
  96, 144 and 192 DPI.
- Hidden absent module, compact first-use prompt, displayed download size,
  cancellation, repeat request and download of only the requested module.
- Standalone Reader excludes MCP even when the executable is installed.
- Manifest, architecture, version, allowed files, real installation and catalogue
  preservation.
- Installed server's stdio initialization, tool discovery and collection query
  against isolated native fixture collections, without `uselocaldata`.
- Unchanged SHA-256 of fixture profiles, databases and books after the query.

The minimal packaging probe passed for both architectures: all payload hashes and
architectures verified, optional files excluded. Probe payloads were removed.
These packaging checks used the existing application binaries; a new full
application release still requires its final builds and regression checks.

The targeted native scenario is `--views-mode=optional-mcp`; set
`HOMELIB_MCP_COMPONENT_PACKAGES` to the package directory. Raw reports are in the
owned local `tools/ui/tests/Out/post536-optional-mcp-20261028-r1` folder.

Zstandard remains in the core archive until its separate first-use installation
has been implemented and verified. Collection compression and SQL catalogue
import remain separate unfinished work.
