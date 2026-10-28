"""Package separately downloadable reader modules from already tested runtimes.

Does not download or compile anything. Each archive can be extracted as-is and
also passes the application's strict component installer. No user profile,
cache, test fixture or compiled Python cache belongs in a component package.
"""
import argparse
import ctypes
import hashlib
import json
import pathlib
import re
import struct
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def binary_platform(data, platform):
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("Not a Windows executable")
    offset = struct.unpack_from("<I", data, 0x3c)[0]
    expected = 0x14c if platform == "Win32" else 0x8664
    if data[offset:offset+4] != b"PE\0\0" or struct.unpack_from("<H", data, offset+4)[0] != expected:
        raise ValueError("Incorrect binary architecture")


def file_version(path):
    library = ctypes.WinDLL("version", use_last_error=True)
    unused = ctypes.c_ulong()
    size = library.GetFileVersionInfoSizeW(str(path), ctypes.byref(unused))
    if not size:
        raise ValueError("Missing binary version: " + str(path))
    buffer = ctypes.create_string_buffer(size)
    if not library.GetFileVersionInfoW(str(path), 0, size, buffer):
        raise ctypes.WinError(ctypes.get_last_error())
    pointer, length = ctypes.c_void_p(), ctypes.c_uint()
    if not library.VerQueryValueW(buffer, "\\", ctypes.byref(pointer), ctypes.byref(length)) or length.value < 52:
        raise ValueError("Missing fixed binary version")
    fixed = (ctypes.c_uint32 * 13).from_address(pointer.value)
    if fixed[0] != 0xfeef04bd:
        raise ValueError("Invalid binary version")
    return ".".join(map(str, (fixed[2] >> 16, fixed[2] & 65535, fixed[3] >> 16, fixed[3] & 65535)))


def package(repo, platform, component, tag, converter_version, output):
    runtime = repo / "Program/Out" / ("Bin" if platform == "Win32" else "Bin64")
    if component == "HomeLibReader":
        reader = repo / f"Utils/HomeLibReader/Out/{platform}/HomeLibReader.exe"
        payload = {"HomeLibReader.exe": reader.read_bytes(),
                   "HomeLibReader-LICENSE.txt": (repo / "LICENSE").read_bytes()}
        # Do not ship the marker inside the shared component ZIP: installing
        # the reader beside a catalogue must not switch that catalogue's mode.
        reader_note = (
            "HomeLib Reader\n\n"
            "Читалка портативная по умолчанию. Файл uselocaldata создавать не нужно.\n"
            "Настройки, заметки, история и кэш по умолчанию будут храниться рядом с программой в Data.\n"
            "Также можно запустить HomeLibReader.exe uselocaldata или с параметром --portable.\n\n"
            "При запуске из каталогизатора используется явно переданная им папка профиля.\n"
            "Существующие данные автоматически между папками не переносятся.\n"
            "Декодеры дополнительных форматов устанавливаются только при необходимости.\n"
        ).encode("utf-8")
        for name in ("HomeLibRuUpdater.exe", "sqlite3.dll", "libzstd.dll", "NOTICE"):
            payload[name] = (runtime / name).read_bytes()
        # NOTICE is already accepted by older component installers.
        payload["NOTICE"] += b"\n\n" + reader_note
        payload["tools/fonts/manifest.json"] = (runtime / "tools/fonts/manifest.json").read_bytes()
        # Native format adapters are optional, just like their author libraries.

        version = file_version(reader)
        for name in ("HomeLibReader.exe", "HomeLibRuUpdater.exe", "sqlite3.dll", "libzstd.dll"):
            binary_platform(payload[name], platform)
        notes = "Автономная читалка. FB2, EPUB и текст доступны сразу; дополнительные модули предлагаются при открытии книги."
    elif component == "PDFium":
        root = runtime / "tools/pdfium"
        names = ("pdfium.dll", "HomeLibPDF.exe", "RUNTIME.json", "WORKER_RUNTIME.json",
                 "HomeLibPDF-LICENSE.txt", "LICENSE", "NOTICE.txt", "VERSION", "args.gn")
        payload = {"tools/pdfium/" + name: (root / name).read_bytes() for name in names}
        for path in sorted((root / "licenses").rglob("*")):
            if path.is_file():
                payload["tools/pdfium/" + path.relative_to(root).as_posix()] = path.read_bytes()
        descriptor = json.loads(payload["tools/pdfium/RUNTIME.json"])
        version = descriptor["version"]
        if digest(payload["tools/pdfium/pdfium.dll"]) != descriptor[platform]["dll_sha256"]:
            raise ValueError("PDFium runtime checksum mismatch")
        for name in ("pdfium.dll", "HomeLibPDF.exe"):
            binary_platform(payload["tools/pdfium/" + name], platform)
        notes = "Модуль чтения PDF: библиотека PDFium и отдельный обработчик страниц. Лицензии и сведения об исходниках включены."
    else:
        version = converter_version
        payload = {}
        for directory in ("bookconvert", "kindle", "office", "xps"):
            root = runtime / "tools" / directory
            for path in sorted(root.rglob("*")):
                relative = path.relative_to(runtime)
                if (not path.is_file() or "__pycache__" in relative.parts or
                    "tests" in relative.parts or path.suffix.lower() in (".pyc", ".pyo", ".rsm", ".map")):
                    continue
                payload[relative.as_posix()] = path.read_bytes()
        python = payload["tools/kindle/python/python.exe"]
        binary_platform(python, platform)
        descriptor = {"component": "BookConverter", "version": version,
                      "pythonSha256": digest(python),
                      "converterSha256": digest(payload["tools/bookconvert/convert_book.py"])}
        payload["tools/bookconvert/COMPONENT.json"] = json_bytes(descriptor)
        notes = "Подготовка и конвертация книг, включая Kindle, старые Office и редкие форматы. PDF, DjVu и декодеры иллюстраций устанавливаются отдельно по необходимости."
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+){0,2}", version):
        raise ValueError("Invalid component version")
    manifest = {"format": 1, "release": tag, "platform": platform, "component": component,
                "version": version, "files": [{"path": name, "size": len(value), "sha256": digest(value)}
                                               for name, value in sorted(payload.items())]}
    payload["HomeLibRu.update.json"] = json_bytes(manifest)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"HomeLibRu-{component}-{platform}.zip"
    with destination.open("xb") as stream, zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, value in sorted(payload.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 25, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, value)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError("Component ZIP failed CRC verification")
    return {"id": component, "platform": platform, "version": version,
            "history": [{"version": version, "date": "2026-10-28", "notes": notes}]}, {
            "component": component, "platform": platform, "version": version, "archive": str(destination),
            "size": destination.stat().st_size, "sha256": digest(destination.read_bytes()), "files": len(manifest["files"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--release", required=True)
    parser.add_argument("--converter-version", default="2.7.0.1103")
    parser.add_argument("--platform", choices=("Win32", "Win64"), action="append")
    parser.add_argument("--component", choices=("HomeLibReader", "PDFium", "BookConverter"), action="append")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", args.release):
        parser.error("Invalid release tag")
    feed, report = [], []
    repo = pathlib.Path(__file__).resolve().parents[1]
    for platform in args.platform or ("Win32", "Win64"):
        for component in args.component or ("HomeLibReader", "PDFium", "BookConverter"):
            entry, result = package(repo, platform, component, args.release, args.converter_version, args.output.resolve())
            feed.append(entry)
            report.append(result)
    for name, value in (("HomeLibRu.components.json", {"format": 1, "components": feed}),
                        ("reader-component-report.json", report)):
        with (args.output / name).open("xb") as stream:
            stream.write(json_bytes(value))
    print(json.dumps(report, indent=2))
