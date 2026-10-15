HomeLibDoc reads Word 97–2003 DOC, binary PowerPoint PPT and Excel XLS with
DocSharp.Binary 0.21.0. It produces temporary DOCX/PPTX/XLSX for the shared
reading/export parser. --image-to-png converts embedded BMP/TIFF/EMF/WMF
pictures through Windows GDI+. Original
files are read only. Word and LibreOffice are not used. The helper is AnyCPU;
Windows .NET Framework 4.6.2+ is checked quietly by the calling application.

Build HomeLibDoc.cs with the Windows .NET Framework C# compiler, /target:exe
/platform:anycpu /optimize+, and references to System.Drawing.dll and the four
pinned net462 DLLs (Doc, Common, Ppt, Xls).
Place the tested executable in Out/HomeLibDoc.exe. Installer/DOC_RUNTIME.json
pins the source, helper, packages and DLLs. Update the pin after an intentional
source change and rerun the black-box and native reader checks before packaging.
scripts/prepare-doc-runtime.ps1 -Platform Win64 -Copy obtains hash-checked
dependencies and copies the helper and all licences into the build runtime.

Limits: 64 MiB source/output, 16 Mi UTF-16 main-text positions, 384 MiB child
process memory and 30 seconds in the caller. Cancellation terminates the child.
Output is create-new and removed on failure. VBA is neither copied nor executed.
Word 95 and password-protected DOC get explicit messages, no office installer.
Image input is limited to 16 MiB, 16384 pixels per side and 16 Mi pixels total.
The caller bounds image decoding to 15 seconds. --version loads all four
assemblies to reject incompatible partial component updates before installation.

Licences shipped alongside the executable:
HomeLibDoc: MIT (repository LICENSE).
DocSharp: MIT, https://github.com/manfromarce/DocSharp.
Original b2xtranslator: BSD-3-Clause, DIaLOGIKa / Evolution Recruitment Solutions.
