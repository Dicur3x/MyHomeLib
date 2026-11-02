# HomeLibre Reader icon

`reader-icon.svg` is the full artwork; `reader-icon-small.svg` keeps the book and
bookmark readable at 16–32 pixels. Both use the catalogue's existing palette.

With the same `sharp` dependency used by `make_app_icon.js`, run:

```
node Program/Resources/Icons/make_reader_icon.js
```

This updates `Program/Resources/reader.ico` and `reader-icon.res`. It does not
change the catalogue or installer artwork. Keep the generated files in source
control: no rasterizer or loose icon file is needed in the distribution.

The standalone project uses the ICO as `MAINICON`, which supplies Explorer's
file icon. The named `ZZ_HOME_LIBRE_READER_ICON` resource supplies the launcher
and book window icons. Its image IDs 54001–54009 do not overlap `MAINICON`, and
its name sorts after `MAINICON`, preserving the catalogue's default icon.

The RES file is written with the existing Win32 resource encoder. The old
bundled `brcc32` cannot handle PNG-compressed large ICO entries. The output has
the standard all-zero Win32 null resource sentinel.

`tools/ui/tests/reader_icon_resources.py` checks every actual linked image at
16, 20, 24, 32, 40, 48, 64, 128 and 256 pixels without running the EXE or relying
on Explorer's icon cache. Test ordinary Reader windows separately.
