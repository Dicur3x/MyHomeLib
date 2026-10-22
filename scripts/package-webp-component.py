"""Package our tested libwebp build once, independently of application releases.

Run prepare-webp-runtime.ps1 for both platforms to rebuild from pinned official
sources. This script packages existing tested binaries; it never compiles on an
end user's computer. Archives have fixed ZIP dates and a strict updater manifest.
"""
import argparse
import hashlib
import json
import pathlib
import struct
import zipfile

TAG = "optional-alreader-2.5.1009.25"
VERSION = "1.6.0"
SOURCE_URL = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz"
SOURCE_SHA256 = "e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def package(repo, platform, output):
    root = repo / "Program/Out" / ("Bin" if platform == "Win32" else "Bin64") / "tools/webp"
    names = ("libwebp.dll", "COPYING.txt", "PATENTS.txt", "AUTHORS.txt")
    payload = {"tools/webp/" + n: (root / n).read_bytes() for n in names}
    dll = payload["tools/webp/libwebp.dll"]
    pe = struct.unpack_from("<I", dll, 0x3C)[0]
    expected = 0x14C if platform == "Win32" else 0x8664
    if dll[:2] != b"MZ" or dll[pe:pe+4] != b"PE\0\0" or struct.unpack_from("<H", dll, pe+4)[0] != expected:
        raise ValueError("Incorrect WebP DLL platform")
    if any(not data for data in payload.values()):
        raise ValueError("Empty component file")
    descriptor = {"component": "WebP", "codec": {"version": VERSION,
                  "files": {n: hashlib.sha256(payload["tools/webp/"+n]).hexdigest() for n in names}},
                  "source": SOURCE_URL, "source_sha256": SOURCE_SHA256,
                  "build_recipe": "scripts/prepare-webp-runtime.ps1"}
    payload["tools/webp/RUNTIME.json"] = json_bytes(descriptor)
    manifest = {"format": 1, "release": TAG, "component": "WebP", "version": VERSION,
                "platform": platform, "files": [{"path": n, "size": len(b),
                "sha256": hashlib.sha256(b).hexdigest()} for n, b in sorted(payload.items())]}
    payload["HomeLibRu.update.json"] = json_bytes(manifest)
    output.mkdir(parents=True, exist_ok=True)
    target = output / f"WebP-{VERSION}-{platform}.zip"
    # Exclusive creation protects an already published component from a silent
    # rebuild with different bytes under the same version and filename.
    with target.open("xb") as stream, zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            info = zipfile.ZipInfo(name, (2025, 6, 30, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(target) as archive:
        if archive.testzip() is not None:
            raise ValueError("Component ZIP failed CRC verification")
    return {"platform": platform, "version": VERSION, "path": str(target), "size": target.stat().st_size,
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "descriptor": descriptor}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    repository = pathlib.Path(__file__).resolve().parents[1]
    report = [package(repository, p, args.output.resolve()) for p in ("Win32", "Win64")]
    (args.output / "webp-package-report.json").write_bytes(json_bytes(report))
    print(json.dumps([{k: v for k, v in item.items() if k != "descriptor"} for item in report], indent=2))
