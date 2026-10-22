"""Extract bounded audit examples into an explicitly marked test profile.

Only reads the catalogue inventory and original archives. Generated names are
independent of archive paths, and no user directory is copied recursively.
"""
import hashlib
import json
import pathlib
import sys
import zipfile


def prepare(inventory, profile, selection=""):
    if not (profile / "native-regression.marker").is_file():
        raise ValueError("Examples require an owned native test profile")
    destination = profile / "catalogue-examples"
    destination.mkdir()
    report = json.loads(inventory.read_text(encoding="utf-8"))
    examples, unavailable = [], []
    meaningful = set("fb2 epub pdf djvu djv doc docx txt rtf mobi azw azw3 prc chm htm html odt pdb mht wri ppt jpg jpeg png gif tif tiff cbr cbz zip rar 7z gz tgz faq fb epup dju".split())
    selected = set(selection.split(',')) if selection else set()
    for kind in report["formats"]:
        extension = kind["extension"]
        count = 0
        for candidate in kind["examples"]:
            if selected and extension not in selected and 'id:' + str(candidate['id']) not in selected:
                continue
            # Some INPX rows have an unknown (zero) recorded size. The archive
            # member size below is authoritative and still enforces our bound.
            for location in candidate["available"]:
                source = pathlib.Path(location["path"])
                before = source.stat()
                try:
                    if location["member"]:
                        with zipfile.ZipFile(source) as archive:
                            member = location["member"]
                            if member not in archive.namelist():
                                matches = [n for n in archive.namelist() if n.casefold() == member.casefold()]
                                if len(matches) != 1:
                                    continue
                                member = matches[0]
                            entry = archive.getinfo(member)
                            if entry.file_size <= 0 or entry.file_size > 16 * 1024 * 1024:
                                continue
                            data = archive.read(entry)
                    else:
                        if before.st_size > 16 * 1024 * 1024:
                            continue
                        data = source.read_bytes()
                    after = source.stat()
                    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise RuntimeError("Original archive changed during extraction")
                except (zipfile.BadZipFile, NotImplementedError, RuntimeError, OSError) as error:
                    unavailable.append({"extension": extension, "id": candidate["id"], "error": str(error)})
                    continue
                # Keep an unusual recorded extension for real detection tests,
                # but never use a user-provided path fragment as an output name.
                safe_ext = extension if extension[1:].isascii() and extension[1:].isalnum() else ".unknown"
                name = f"sample-{candidate['id']}{safe_ext}"
                (destination / name).write_bytes(data)
                examples.append({"id": candidate["id"], "extension": extension, "name": name,
                                 "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
                count += 1
                break
            if count >= (2 if extension.lstrip(".") in meaningful else 1):
                break
        if count == 0 and kind["live_records"]:
            unavailable.append({"extension": extension, "reason": "No accessible non-empty bounded example"})
    if not examples:
        raise RuntimeError("No accessible examples were prepared; an empty audit is not a successful test")
    output = {"examples": examples, "unavailable": unavailable, "originals_read_only": True}
    (destination / "examples.json").write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"examples": len(examples), "bytes": sum(e["size"] for e in examples), "unavailable": len(unavailable)}))


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "")
