"""Small owned fixtures and independent upstream 7-Zip verification."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import random
import subprocess


TOOL = Path("C:/Program Files/7-Zip/7z.exe")


def call(*args: str, cwd: Path | None = None) -> bytes:
    run = subprocess.run([str(TOOL), *args], cwd=cwd, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, timeout=25)
    if run.returncode:
        raise RuntimeError("7-Zip fixture failed: " + run.stderr.decode("utf-8", errors="replace"))
    return run.stdout


def prepare(root: Path) -> None:
    owned = root / "sevenzip-delete-plan"
    owned.mkdir()
    sources = owned / "inputs"
    sources.mkdir()
    entries = {}
    generator = random.Random(7231)
    for name in ["selected/one.fb2", "selected/two.fb2", "unselected/keep.fb2"]:
        data = ("Книга для проверки — ё. " + name).encode("utf-8") + generator.randbytes(160_000)
        target = sources / name
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(data)
        entries[name] = hashlib.sha256(data).hexdigest()
    for label, method, solid in [("ppmd", "PPMd:mem16", "off"),
                                 ("lzma2", "LZMA2:d20", "off"),
                                 ("solid", "LZMA2:d20", "on")]:
        call("a", "-t7z", "-m0=" + method, "-ms=" + solid, "-mhc=on",
             "-mx=1", "-sccUTF-8", str(owned / (label + ".7z")), "selected", "unselected", cwd=sources)
    (owned / "expected.json").write_text(json.dumps(entries), encoding="utf-8")
    print("PASS bounded PPMd LZMA2 and solid 7z seeds from upstream 7-Zip")


def verify(root: Path) -> None:
    owned = root / "sevenzip-delete-plan"
    entries = json.loads((owned / "expected.json").read_text(encoding="utf-8"))
    for label in ["ppmd", "lzma2"]:
        archive = owned / ("planned-" + label + ".7z")
        call("t", "-sccUTF-8", "--", str(archive))
        listing = call("l", "-slt", "-sccUTF-8", "--", str(archive)).decode("utf-8").replace("\r", "")
        listing = listing.partition("----------")[2]
        names = [line[7:] for line in listing.splitlines() if line.startswith("Path = ")]
        files = [name for name in names if name.endswith(".fb2")]
        if [name.replace("\\", "/") for name in files] != ["unselected/keep.fb2"]:
            raise RuntimeError("Independent 7z plan inventory differs: " + repr(files))
        payload = call("x", "-so", "-spd", "-sccUTF-8", "--", str(archive), files[0])
        if hashlib.sha256(payload).hexdigest() != entries["unselected/keep.fb2"]:
            raise RuntimeError("Independent 7z retained payload differs")
    print("PASS upstream 7-Zip validates planned PPMd LZMA2 inventories CRC and payload hashes")
