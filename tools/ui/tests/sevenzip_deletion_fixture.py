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


def prepare(root: Path, include_limit: bool = False) -> None:
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
    grouped = owned / "grouped-inputs"
    grouped.mkdir()
    grouped_names = [f"book{index:02}.fb2" for index in range(12)]
    for name in grouped_names:
        (grouped / name).write_bytes(generator.randbytes(100_000))
    call("a", "-t7z", "-m0=LZMA2:d20", "-ms=2f", "-mqs=off",
         "-mx=1", str(owned / "grouped-solid.7z"), *grouped_names, cwd=grouped)
    if include_limit:
        prepare_limit(root)
    (owned / "expected.json").write_text(json.dumps(entries), encoding="utf-8")
    print("PASS bounded PPMd LZMA2 and solid 7z seeds from upstream 7-Zip")


def prepare_limit(root: Path) -> None:
    owned = root / "sevenzip-delete-plan"
    inputs = owned / "limit-inputs"
    (inputs / "selected").mkdir(parents=True)
    (inputs / "unselected").mkdir()
    (inputs / "selected" / "one.fb2").write_bytes(random.Random(7233).randbytes(1024 * 1024))
    (inputs / "unselected" / "keep.fb2").write_bytes(random.Random(7232).randbytes(17 * 1024 * 1024))
    call("a", "-t7z", "-m0=LZMA2:d20", "-ms=on", "-mhc=on", "-mx=1", "-sccUTF-8",
         str(owned / "solid-limit.7z"), "selected", "unselected", cwd=inputs)


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
    solid = owned / "repacked-solid.7z"
    call("t", "--", str(solid))
    listing = call("l", "-slt", "-sccUTF-8", "--", str(solid)).decode("utf-8").replace("\\", "/")
    files = {line[7:] for line in listing.splitlines() if line.startswith("Path = ") and line.endswith(".fb2")}
    if files != {"selected/two.fb2", "unselected/keep.fb2"}:
        raise RuntimeError("Repacked solid 7z has an unexpected inventory")
    for member in files:
        payload = call("x", "-so", "-spd", "-sccUTF-8", "--", str(solid), member)
        if hashlib.sha256(payload).hexdigest() != entries[member]:
            raise RuntimeError("Repacked solid 7z changed retained contents")
    print("PASS upstream 7-Zip verifies both surviving solid members byte for byte")
    large = owned / "repacked-large.7z"
    call("t", "--", str(large))
    payload = call("x", "-so", "-spd", "--", str(large), "unselected/keep.fb2")
    if hashlib.sha256(payload).digest() != hashlib.sha256((owned / "limit-inputs/unselected/keep.fb2").read_bytes()).digest():
        raise RuntimeError("Large solid 7z changed its retained payload")
    listing = call("l", "-slt", "-sccUTF-8", "--", str(large)).decode("utf-8").replace("\\", "/")
    if "Path = selected/one.fb2" in listing:
        raise RuntimeError("Large solid 7z retained the selected book")
    print("PASS upstream 7-Zip verifies the large retained payload byte for byte")
    proof = json.loads((root / "sevenzip-recovery-proof.json").read_text(encoding="utf-8-sig"))
    archive = (root / proof["archive"]).resolve(strict=True)
    if not archive.is_relative_to(root):
        raise RuntimeError("Unexpected 7z recovery proof path")
    call("t", "-sccUTF-8", "--", str(archive))
    listing = call("l", "-slt", "-sccUTF-8", "--", str(archive)).decode("utf-8").replace("\r", "")
    listing = listing.partition("----------")[2]
    files = [line[7:] for line in listing.splitlines() if line.startswith("Path = ") and line.endswith(".fb2")]
    if sorted(name.replace("\\", "/") for name in files) != sorted(proof["files"]):
        raise RuntimeError("Independent recovered 7z inventory differs")
    for name in files:
        payload = call("x", "-so", "-spd", "-sccUTF-8", "--", str(archive), name)
        if hashlib.sha256(payload).hexdigest() != entries[name.replace("\\", "/")]:
            raise RuntimeError("Independent recovered 7z payload differs")
    print("PASS upstream 7-Zip validates recovered archive inventory CRC and retained payload hashes")
    for index in range(2):
        archive = root / "zip-member-delete" / "sevenzip-recovery" / f"queued-{index}.7z"
        call("t", "-sccUTF-8", "--", str(archive))
        payload = call("x", "-so", "-spd", "-sccUTF-8", "--", str(archive), "unselected/keep.fb2")
        if hashlib.sha256(payload).hexdigest() != entries["unselected/keep.fb2"]:
            raise RuntimeError("Independent grouped 7z payload differs")
    print("PASS upstream 7-Zip validates grouped background deletion payloads")
    archive = owned / "recovered-grouped-solid.7z"
    call("t", "--", str(archive))
    listing = call("l", "-slt", "--", str(archive)).decode("utf-8")
    files = {line[7:] for line in listing.splitlines() if line.startswith("Path = ") and line.endswith(".fb2")}
    remaining = {f"book{index:02}.fb2" for index in [1, 2, 3, 6, 7, 10, 11]}
    if files != remaining:
        raise RuntimeError("Grouped solid recovery changed the inventory")
    for name in remaining:
        payload = call("x", "-so", "-spd", "--", str(archive), name)
        if payload != (owned / "grouped-inputs" / name).read_bytes():
            raise RuntimeError("Grouped solid recovery changed " + name)
    print("PASS upstream 7-Zip verifies surviving grouped solid entries byte for byte")
