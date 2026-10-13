HomeLibDoc reads Word 97–2003 binary DOC with DocSharp.Binary 0.21.0.
It produces a temporary DOCX for HomeLib Ru's normal reflow reader. Original
files are read only. Word and LibreOffice are not used. The helper is AnyCPU;
Windows .NET Framework 4.6.2+ is checked quietly by the calling application.

Build HomeLibDoc.cs with the Windows .NET Framework C# compiler, /target:exe
/platform:anycpu /optimize+, and references to the two pinned net462 DLLs.
Place the tested executable in Out/HomeLibDoc.exe. Installer/DOC_RUNTIME.json
pins the source, helper, packages and DLLs. Update the pin after an intentional
source change and rerun the black-box and native reader checks before packaging.
scripts/prepare-doc-runtime.ps1 -Platform Win64 -Copy obtains hash-checked
dependencies and copies the helper and all licences into the build runtime.

Limits: 64 MiB source/output, 16 Mi UTF-16 main-text positions, 384 MiB child
process memory and 30 seconds in the caller. Cancellation terminates the child.
Output is create-new and removed on failure. VBA is neither copied nor executed.
Word 95 and password-protected DOC get explicit messages, no office installer.

Licences shipped alongside the executable:
HomeLibDoc: MIT (repository LICENSE).
DocSharp: MIT, https://github.com/manfromarce/DocSharp.
Original b2xtranslator: BSD-3-Clause, DIaLOGIKa / Evolution Recruitment Solutions.
