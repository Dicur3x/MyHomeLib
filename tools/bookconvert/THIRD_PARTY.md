# Additional converter dependencies

Markdown uses **Mistune 3.3.4**, distributed unmodified in `vendor/mistune` under
BSD-3-Clause. Copyright (c) 2014, Hsiaoming Yang. The complete license is in
[vendor/MISTUNE_LICENSE.txt](vendor/MISTUNE_LICENSE.txt).

Source: https://github.com/lepture/mistune

Distribution: `mistune-3.3.4-py3-none-any.whl` from the official PyPI project.
SHA-256: `ee015381e955e370962968befe1d729ab60fafb6a715ac6751763fbce38c8d4a`.
Only production Python modules, the typing marker and license are included.
The compressed upstream wheel is approximately 67 KB; no additional interpreter
or package installation is required. Internal dependency updates are delivered
with HomeLib Ru.

Kindle inputs reuse the **KindleUnpack** distribution already shipped under
`tools/kindle`; its original license accompanies that component.
Old DOC inputs reuse the already shipped **DocSharp** component and licenses.
Neither path downloads code or runs macros while converting a book.
