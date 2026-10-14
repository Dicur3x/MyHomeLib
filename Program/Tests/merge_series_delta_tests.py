"""Native merge series delta regression gate.

Build merge_series_delta_test.dproj in Delphi GUI for Win32 and Win64.
Run this script once per matching runtime. It stages only program DLL/genre inputs
into a fresh isolated G directory, then executes twelve tiny native fixtures.
It never copies a user collection or starts the main application.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import time

BASE = Path(r"G:\HomeLibRu-work-2026-10-12")
MARKER = "HomeLib Ru isolated native regression v1"

def safe_input(p: Path) -> Path:
    p = p.resolve(strict=True)
    if p.drive.upper() not in {"C:", "G:"}:
        raise ValueError("Native gate accepts read-only C/G program inputs only")
    return p

def digest(p: Path) -> str:
    with p.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def machine(p: Path) -> int:
    with p.open("rb") as f:
        head = f.read(64)
        if len(head) != 64 or head[:2] != b"MZ":
            raise ValueError(f"Invalid PE: {p.name}")
        f.seek(struct.unpack_from("<I", head, 0x3c)[0])
        signature, arch = struct.unpack("<IH", f.read(6))
    if signature != 0x4550 or arch not in {0x14c, 0x8664}:
        raise ValueError(f"Unsupported PE: {p.name}")
    return arch

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path, help="Program/Out/Bin or Bin64")
    parser.add_argument("native_exe", type=Path, help="Freshly GUI-built merge_series_delta_test.exe")
    parser.add_argument("--stage-only", action="store_true", help="Validate/stage without executing a native fixture")
    args = parser.parse_args()
    runtime = safe_input(args.runtime)
    native = safe_input(args.native_exe)
    if native.name.lower() != "merge_series_delta_test.exe":
        raise ValueError("Expected standalone merge_series_delta_test.exe")
    sqlite = safe_input(runtime / "sqlite3.dll")
    if machine(native) != machine(sqlite):
        raise ValueError("Native test and SQLite architectures differ")
    BASE.mkdir(exist_ok=True)
    assert BASE.resolve().drive.upper() == "G:"
    folder = Path(tempfile.mkdtemp(prefix="HomeLibRu-native-merge-series-", dir=BASE)).resolve()
    assert folder.parent == BASE.resolve() and folder.name.startswith("HomeLibRu-native-")
    readonly = {str(native): digest(native)}
    shutil.copy2(native, folder / native.name)
    # Runtime-only allowlist: deliberately excludes Data, Settings, history,
    # book archives, read folders, executables and user libraries.
    for name in ["sqlite3.dll", "libzstd.dll", "libeay32.dll", "ssleay32.dll", "homelib_webp.dll"]:
        source = runtime / name
        if source.is_file():
            source = safe_input(source)
            readonly[str(source)] = digest(source)
            shutil.copy2(source, folder / name)
    genres = sorted(runtime.glob("genres*.glst"))
    if not any(p.name == "genres_fb2.glst" for p in genres):
        raise ValueError("Packaged genre registry is absent")
    for source in genres:
        readonly[str(source)] = digest(source)
        shutil.copy2(source, folder / source.name)
    for name in ["uselocaldata", "uselocaltemp"]:
        (folder / name).write_text("", encoding="ascii")
    (folder / "native-regression.marker").write_text(MARKER, encoding="utf-8")
    (folder / "myhomelib2.ini").write_text(
        "[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\n"
        "[INTERFACE]\nLocale=ru\nActivePage=0\n"
        "[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\n"
        "AutoLoadReview=0\nIgnoreAbsentArchives=1\n[OPDS]\nEnabled=0\n",
        encoding="utf-8", newline="\r\n")
    (folder / "Data").mkdir()
    protected = {
        folder / "Data" / "reader.ini": b"[Fixture]\r\nPosition=72\r\nHistory=preserved\r\n",
        folder / "Data" / "reader-notes.json": '{"fixture":"Личная заметка ё і","position":72}'.encode("utf-8"),
        folder / "Data" / "personal-books.txt": "Личный список книг без изменений".encode("utf-8"),
    }
    for p, content in protected.items():
        p.write_bytes(content)
    report = {"root": str(folder), "architecture": "Win64" if machine(native) == 0x8664 else "Win32",
              "source_exe_sha256": readonly[str(native)], "fixtures": 12, "stage_only": args.stage_only}
    if args.stage_only:
        print("PASS isolated G staging and architecture guard", folder, flush=True)
        return 0
    env = os.environ.copy()
    env.update(TEMP=str(BASE), TMP=str(BASE), LOCALAPPDATA=str(folder / "LocalAppData"))
    started = time.monotonic()
    result = subprocess.run([str(folder / native.name), "all"], cwd=folder, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=240, creationflags=subprocess.CREATE_NO_WINDOW)
    text = result.stdout.decode("utf-8", errors="replace")
    (folder / "native-output.log").write_bytes(result.stdout)
    print(text, flush=True)
    if result.returncode != 0:
        raise AssertionError(f"Native merge series gate failed ({result.returncode}); log: {folder / 'native-output.log'}")
    if "PASS original-copy atomic guard" not in text:
        raise AssertionError("Atomic original provenance fixture did not complete")
    passes = re.findall(r"PASS series delta policy=(\d+) scenario=(\d+) adds=(\d+)", text)
    expected = {(str(p), str(s), str(2 if s == 3 else 4)) for p in range(3) for s in range(4)}
    if set(passes) != expected or len(passes) != 12 or "PASS all twelve native merge series delta fixtures" not in text:
        raise AssertionError("Native gate did not complete all twelve policies/scenarios")
    for p, content in protected.items():
        if p.read_bytes() != content:
            raise AssertionError(f"Merge changed protected reader/history/notes fixture: {p.name}")
    for source, original in readonly.items():
        if digest(Path(source)) != original:
            raise AssertionError("Native gate changed original program inputs")
    report.update(seconds=round(time.monotonic() - started, 3),
                  native_passes=passes, protected_files_preserved=True, readonly_inputs_preserved=True,
                  original_user_collections_copied=False)
    (folder / "regression-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("PASS merge series delta gate", json.dumps(report, ensure_ascii=False), flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
