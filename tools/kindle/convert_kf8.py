"""Rebuild an unencrypted KF8 book as EPUB, retaining its original resources."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import struct
import sys

VERSION = "kindleunpack-bf0ca6e-v1"

def main():
    source, output = map(lambda x: Path(x).resolve(), sys.argv[1:3])
    if not source.is_file() or source.stat().st_size > 128*1024*1024:
        raise ValueError("Unsupported Kindle source size")
    with source.open("rb") as f:
        header = f.read(86)
        if header[60:68] != b"BOOKMOBI":
            raise ValueError("Not a MOBI/KF8 book")
        offset = struct.unpack(">I", header[78:82])[0]
        f.seek(offset)
        record = f.read(40)
    if len(record) < 40 or record[16:20] != b"MOBI":
        raise ValueError("Missing MOBI header")
    if struct.unpack(">H",record[12:14])[0] != 0:
        raise ValueError("Encrypted Kindle books are not supported")
    if struct.unpack(">I",record[4:8])[0] > 128*1024*1024:
        raise ValueError("Kindle text is too large")
    if output.exists():
        raise ValueError("Output must be a new temporary file")
    work = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else output.with_name(output.name+".unpack")
    if work.exists():
        raise ValueError("Temporary output is already in use")
    work.mkdir()
    def within(name):
        path = Path(os.fsdecode(name)).resolve()
        return path == work or work in path.parents or path == output
    def audit(event,args):
        if event == "open" and not isinstance(args[0],int):
            mode, flags = args[1], args[2]
            writing = (mode is not None and any(c in mode for c in "wax+")) or (flags & (os.O_WRONLY|os.O_RDWR|os.O_CREAT|os.O_TRUNC))
            if writing and not within(args[0]):
                raise PermissionError("Write outside the conversion folder")
        elif event in ("os.mkdir","os.remove","os.rmdir") and not within(args[0]):
            raise PermissionError("Change outside the conversion folder")
        elif event in ("socket.connect","subprocess.Popen","os.system"):
            raise PermissionError("External operation is not allowed during conversion")
    sys.addaudithook(audit)
    sys.path.insert(0,str(Path(__file__).resolve().parent))
    try:
        from lib.kindleunpack import unpackBook
        with contextlib.redirect_stdout(io.StringIO()):
            unpackBook(str(source),str(work),epubver="2",use_hd=True)
        epubs = list(work.rglob("*.epub"))
        if len(epubs) != 1:
            raise ValueError("KindleUnpack did not create one EPUB")
        shutil.copyfile(epubs[0],output)
        print("OK",VERSION)
    finally:
        shutil.rmtree(work)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(type(error).__name__+": "+str(error))
        sys.exit(1)
