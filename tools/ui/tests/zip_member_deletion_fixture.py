"""Independent sparse ZIP64 seed and result verification for owned native tests."""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import struct
import sys
import zipfile
import zlib


def root_from(value: str) -> Path:
    root = Path(value).resolve(strict=True)
    if not root.name.startswith("HomeLibRu-native-"):
        raise RuntimeError("Expected an isolated native profile")
    if (root / "native-regression.marker").read_text(encoding="utf-8") != "HomeLib Ru isolated native regression v1":
        raise RuntimeError("Missing native profile ownership marker")
    return root


def prepare(root: Path) -> None:
    target = root / "zip64-sparse.zip"
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    kernel.DeviceIoControl.restype = wintypes.BOOL
    kernel.GetCompressedFileSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetCompressedFileSizeW.restype = wintypes.DWORD
    first = b"chosen.fb2"
    kept = "сохранить/book.fb2".encode("utf-8")
    payload = "ZIP64 retained payload — ё.".encode("utf-8")
    keep_offset = (1 << 32) + 128
    header_size = 30 + len(first) + 20
    sparse_payload_size = keep_offset - header_size
    zeros = bytes(4 * 1024 * 1024)
    crc = 0
    whole, tail = divmod(sparse_payload_size, len(zeros))
    for _ in range(whole):
        crc = zlib.crc32(zeros, crc)
    crc = zlib.crc32(zeros[:tail], crc)
    keep_crc = zlib.crc32(payload)
    with target.open("xb") as out:
        returned = wintypes.DWORD()
        handle = msvcrt.get_osfhandle(out.fileno())
        if not kernel.DeviceIoControl(handle, 0x900C4, None, 0, None, 0, ctypes.byref(returned), None):
            raise ctypes.WinError(ctypes.get_last_error())
        first_extra = struct.pack("<HHQQ", 1, 16, sparse_payload_size, sparse_payload_size)
        out.write(struct.pack("<I5H3I2H", 0x04034B50, 45, 0, 0, 0, 0,
            crc, 0xFFFFFFFF, 0xFFFFFFFF, len(first), len(first_extra)) + first + first_extra)
        out.seek(keep_offset)
        out.write(struct.pack("<I5H3I2H", 0x04034B50, 20, 0x800, 0, 0, 0,
            keep_crc, len(payload), len(payload), len(kept), 0) + kept + payload)
        directory_offset = out.tell()
        first_central = struct.pack("<I6H3I5H2I", 0x02014B50, 45, 45, 0, 0, 0, 0,
            crc, 0xFFFFFFFF, 0xFFFFFFFF, len(first), len(first_extra), 0, 0, 0, 0, 0) + first + first_extra
        keep_extra = struct.pack("<HHQ", 1, 8, keep_offset)
        kept_central = struct.pack("<I6H3I5H2I", 0x02014B50, 45, 45, 0x800, 0, 0, 0,
            keep_crc, len(payload), len(payload), len(kept), len(keep_extra), 0, 0, 0, 0, 0xFFFFFFFF) + kept + keep_extra
        directory = first_central + kept_central
        out.write(directory)
        zip64_offset = out.tell()
        out.write(struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0,
            2, 2, len(directory), directory_offset))
        out.write(struct.pack("<IIQI", 0x07064B50, 0, zip64_offset, 1))
        out.write(struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF,
            0xFFFFFFFF, 0xFFFFFFFF, 0))
        out.flush()
        os.fsync(out.fileno())
    high = wintypes.DWORD()
    ctypes.set_last_error(0)
    low = kernel.GetCompressedFileSizeW(str(target), ctypes.byref(high))
    if low == 0xFFFFFFFF and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    allocated = (high.value << 32) | low
    if allocated >= 1024 * 1024 or target.stat().st_size <= (1 << 32):
        raise RuntimeError("ZIP64 fixture was not sparse and bounded")
    with zipfile.ZipFile(target) as book:
        if len(book.infolist()) != 2 or book.read(kept.decode("utf-8")) != payload:
            raise RuntimeError("Independent ZIP64 seed check failed")
    print(f"PASS sparse ZIP64 seed: logical={target.stat().st_size}, allocated={allocated}")
    import sevenzip_deletion_fixture
    sevenzip_deletion_fixture.prepare(root)


def verify(root: Path) -> None:
    proof = json.loads((root / "zip-member-delete-proof.json").read_text(encoding="utf-8-sig"))
    for relative, entries in [(proof["archive"], proof["entries"]),
            (proof["zip64Archive"], {"сохранить/book.fb2": proof["zip64Hash"]})]:
        archive = (root / relative).resolve(strict=True)
        if not archive.is_relative_to(root):
            raise RuntimeError("Unexpected proof archive path")
        with zipfile.ZipFile(archive) as book:
            names = book.namelist()
            if len(names) != len(entries) or set(names) != set(entries):
                raise RuntimeError("Independent ZIP inventory differs")
            for name, expected in entries.items():
                if hashlib.sha256(book.read(name)).hexdigest() != expected:
                    raise RuntimeError("Independent ZIP payload differs: " + name)
            if book.testzip() is not None:
                raise RuntimeError("Independent ZIP CRC check failed")
    print("PASS independent Python ZIP and ZIP64 inventories CRC and payload hashes")
    import sevenzip_deletion_fixture
    sevenzip_deletion_fixture.verify(root)


if __name__ == "__main__":
    operation, directory = sys.argv[1:]
    {"prepare": prepare, "verify": verify}[operation](root_from(directory))
