"""Rebuild an unencrypted KF8 book as EPUB, retaining its original resources."""
import contextlib
import copy
import io
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

VERSION = "kindleunpack-bf0ca6e-v4"


def read_mobi_text(read_raw, header):
    raw = read_raw(header)
    saved_header = header.header
    if (header.sect.ident != b'BOOKMOBI' or header.version != 4 or header.codec != 'utf-8'
            or len(saved_header) < 0xF4 or struct.unpack_from('>I', saved_header, 0x14)[0] < 0xE4
            or struct.unpack_from('>H', saved_header, 0xF2)[0] != 1):
        return raw
    declared_length, = struct.unpack_from('>I', saved_header, 4)
    if not 0 < declared_length < len(raw):
        return raw
    try:
        raw.decode('utf-8')
    except UnicodeDecodeError:
        pass
    else:
        return raw

    # Some version 4 Kindle files already carry UTF-8 overlap bytes at the
    # record boundaries. KindleUnpack only trims them from version 5 onward.
    probe = bytearray(saved_header)
    struct.pack_into('>I', probe, 0x68, 5)
    try:
        header.header = bytes(probe)
        trimmed = read_raw(header)
        if len(trimmed) == declared_length:
            trimmed.decode('utf-8')
            raw = trimmed
    except (ValueError, IndexError, struct.error):
        pass
    finally:
        header.header = saved_header
        header.rawSize = len(raw)
    return raw


def unpack_preserving_resource_slots(kindleunpack, source, work, *, epubver):
    """Leave empty slots for font records that KindleUnpack cannot extract."""
    extract_font = kindleunpack.processFONT
    read_raw = kindleunpack.MobiHeader.getRawML
    incomplete_fonts = []

    def read_text(header):
        return read_mobi_text(read_raw, header)

    def keep_font_slot(index, files, names, sections, data, obfuscation, start, pointer):
        count = len(names)
        result = extract_font(index, files, names, sections, data, obfuscation, start, pointer)
        resources = result[0]
        if len(resources) == count:
            # A reference counts physical records, including bare FONT markers.
            resources.append(None)
            if data != b'FONT':
                incomplete_fonts.append(index)
        return result

    kindleunpack.processFONT = keep_font_slot
    kindleunpack.MobiHeader.getRawML = read_text
    try:
        kindleunpack.unpackBook(str(source), str(work), epubver=epubver, use_hd=True)
    finally:
        kindleunpack.processFONT = extract_font
        kindleunpack.MobiHeader.getRawML = read_raw
    return incomplete_fonts


def write_reader_epub(source, destination):
    """Remove the unpacker's binary EXTH diagnostics from the package comment."""
    with ZipFile(source) as original:
        container = ET.fromstring(original.read('META-INF/container.xml'))
        packages = {node.get('full-path') for node in container.iter()
                    if node.tag.rsplit('}', 1)[-1] == 'rootfile'}
        replacements = {}
        for member in packages.intersection(original.namelist()):
            data = original.read(member)
            # Container_Id can be binary. Its diagnostic copy is not a book
            # resource or OPF metadata. Leave all other archive members intact.
            content = re.sub(rb'<!-- BEGIN INFORMATION ONLY .*?END INFORMATION ONLY -->', b'', data, flags=re.DOTALL)
            if content != data:
                replacements[member] = content
        if not replacements:
            shutil.copyfile(source, destination)
            return
        with ZipFile(destination, 'x') as output:
            output.comment = original.comment
            for member in original.infolist():
                if member.filename in replacements:
                    output.writestr(copy.copy(member), replacements[member.filename])
                else:
                    with original.open(member) as raw, output.open(copy.copy(member), 'w') as saved:
                        shutil.copyfileobj(raw, saved, length=1024 * 1024)

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
        from lib import kindleunpack
        with contextlib.redirect_stdout(io.StringIO()):
            unpack_preserving_resource_slots(kindleunpack, source, work, epubver="2")
        epubs = list(work.rglob("*.epub"))
        if len(epubs) != 1:
            raise ValueError("KindleUnpack did not create one EPUB")
        write_reader_epub(epubs[0],output)
        print("OK",VERSION)
    finally:
        shutil.rmtree(work)

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(type(error).__name__+": "+str(error))
        sys.exit(1)
