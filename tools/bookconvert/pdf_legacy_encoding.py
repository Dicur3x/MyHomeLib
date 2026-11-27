"""Read-only repair of Windows-1251 text mislabeled by Acrobat PDFWriter 4."""

import ctypes as C
from pathlib import Path
import re
import sys


LIMIT = 16 * 1024 * 1024
WS = b' \t\r\n\f\0'
XREF_RUN = re.compile(rb'(\d+)\s+(\d+)\s+')
XREF_ROW = re.compile(rb'(\d{10})[ \t]+(\d{5})[ \t]+([nf])[^\S\r\n]*(?:\r\n|\n|\r)')
INDIRECT = re.compile(rb'(\d+)\s+(\d+)\s+obj\s*')
TRAILER_KEY = re.compile(rb'/(Root|Size|Info|Prev|Encrypt|ID)\s*(\d+\s+\d+\s+R|\d+|\[\s*<[0-9a-fA-F]+>\s*<[0-9a-fA-F]+>\s*\])')
RUSSIAN = re.compile(r'\b(и|в|на|что|не|как|для|из|по|это|от|при|до|его|или|так)\b', re.I)
CYRILLIC_MAP = {**{code: code - 0xc0 + 0x410 for code in range(0xc0, 0x100)}, 0xa8: 0x401, 0xb8: 0x451}
ENCODING = (b'<< /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [ 168 /uni0401 184 /uni0451 192 '
            + b' '.join(f'/uni{code:04X}'.encode('ascii') for code in range(0x410, 0x450)) + b' ] >>')


def candidate(source):
    if source.stat().st_size > LIMIT:
        return False
    with source.open('rb') as stream:
        header = stream.read(512)
    return header.startswith(b'%PDF-1.3') and bool(re.search(rb'/Linearized\s+1\b', header))


def mislabeled_text(api, document):
    metadata = api.dll.FPDF_GetMetaText
    metadata.argtypes = [C.c_void_p, C.c_char_p, C.c_void_p, C.c_ulong]
    metadata.restype = C.c_ulong
    buffer = C.create_string_buffer(256)
    length = metadata(document, b'Producer', buffer, len(buffer))
    if not 2 <= length <= len(buffer) or buffer.raw[:length].decode('utf-16-le').rstrip('\0') != 'Acrobat PDFWriter 4.0 for Windows':
        return False

    pages = api.FPDF_GetPageCount(document)
    if pages < 1:
        return False
    words = []
    for index in sorted({0, min(1, pages-1), pages//2}):
        page = api.FPDF_LoadPage(document, index)
        if not page:
            continue
        try:
            text = api.FPDFText_LoadPage(page)
            if not text:
                continue
            try:
                codepoints = (api.FPDFText_GetUnicode(text, i)
                              for i in range(min(4096, api.FPDFText_CountChars(text))))
                sample = ''.join(chr(code) for code in codepoints if 0 < code <= 0x10ffff)
                if len(re.findall(r'[А-Яа-яЁё]', sample)) > 12:
                    return False
                if len(re.findall(r'[À-ÿ]{3,}', sample)) >= 10:
                    words.extend(RUSSIAN.findall(sample.translate(CYRILLIC_MAP).lower()))
            finally:
                api.FPDFText_ClosePage(text)
        finally:
            api.FPDF_ClosePage(page)
    return len(words) >= 12 and len(set(words)) >= 4


def skip_space(data, offset):
    while offset < len(data) and data[offset] in WS:
        offset += 1
    return offset


def read_xrefs(data, xref):
    records = {}
    visited = set()
    current = xref
    latest = None
    while current not in visited and len(visited) < 8:
        visited.add(current)
        if data[current:current+4] != b'xref':
            return None, None
        offset = skip_space(data, current+4)
        while data[offset:offset+7] != b'trailer':
            run = XREF_RUN.match(data, offset)
            if not run:
                return None, None
            first, size = map(int, run.groups())
            if first + size > 20000:
                return None, None
            offset = run.end()
            for ident in range(first, first+size):
                row = XREF_ROW.match(data, offset)
                if not row:
                    return None, None
                position, generation, flag = row.groups()
                records.setdefault(ident, (int(position), int(generation)) if flag == b'n' else None)
                offset = row.end()
            offset = skip_space(data, offset)
        start = skip_space(data, offset+7)
        end = data.find(b'>>', start, start+4000)
        if end < 0 or data[start:start+2] != b'<<':
            return None, None
        values = dict(TRAILER_KEY.findall(data[start:end]))
        if latest is None:
            latest = values.copy()
        previous = values.get(b'Prev')
        if previous is None:
            return records, latest
        if not previous.isdigit():
            return None, None
        current = int(previous)
    return None, None


def corrected_pdf(data):
    if re.search(rb'/ByteRange\s*\[', data):
        return None
    eof = re.search(rb'startxref\s+(\d+)\s*%%EOF\s*$', data[-1024:])
    if not eof:
        return None
    xref = int(eof[1])
    records, trailer = read_xrefs(data, xref)
    if not records or not trailer or not {b'Root', b'Size'} <= trailer.keys():
        return None

    def dictionary(ident):
        location = records.get(ident)
        if not location:
            return None
        position, generation = location
        start = INDIRECT.match(data, position)
        if not start or (int(start[1]), int(start[2])) != (ident, generation):
            return None
        start = start.end()
        end = data.find(b'endobj', start, start+4096)
        if end < 0 or data[start:start+2] != b'<<':
            return None
        body = data[start:end].strip()
        if not body.endswith(b'>>') or b'stream' in body:
            return None
        return generation, body

    changes = []
    for ident, location in sorted(records.items()):
        if location is None:
            continue
        font = dictionary(ident)
        if not font:
            continue
        generation, body = font
        if not re.search(rb'/Type\s*/Font\b\s*/Subtype\s*/TrueType\b', body) or b'/ToUnicode' in body:
            continue
        if not re.search(rb'/Encoding\s*/WinAnsiEncoding\b', body):
            continue
        reference = re.search(rb'/FontDescriptor\s+(\d+)\s+\d+\s+R\b', body)
        descriptor = dictionary(int(reference[1])) if reference else None
        if not descriptor or re.search(rb'/FontFile(?:2|3)?\b', descriptor[1]):
            continue
        new_body = re.sub(rb'(/Encoding\s*)/WinAnsiEncoding\b', lambda match: match[1] + ENCODING, body, count=1)
        changes.append((ident, generation, new_body))
    if not changes:
        return None

    output = bytearray(data + b'\n')
    offsets = []
    for ident, generation, body in changes:
        offsets.append((ident, len(output), generation))
        output.extend(f'{ident} {generation} obj\n'.encode('ascii') + body + b'\nendobj\n')
    new_xref = len(output)
    output.extend(b'xref\n')
    for ident, offset, generation in offsets:
        output.extend(f'{ident} 1\n{offset:010d} {generation:05d} n\r\n'.encode('ascii'))
    trailer[b'Prev'] = str(xref).encode('ascii')
    output.extend(b'trailer\n<< ' + b' '.join(b'/' + key + b' ' + value for key, value in trailer.items()) + b' >>\n')
    output.extend(f'startxref\n{new_xref}\n%%EOF\n'.encode('ascii'))
    return output


def prepare(source, destination, api, document):
    if not candidate(source) or not mislabeled_text(api, document):
        return False
    data = corrected_pdf(source.read_bytes())
    if not data:
        return False
    with destination.open('xb') as stream:
        stream.write(data)
    try:
        def bad_copy(message):
            raise ValueError(message)

        with api.open_document(destination, bad_copy) as reopened:
            valid = api.FPDF_GetPageCount(reopened) == api.FPDF_GetPageCount(document)
    except ValueError:
        valid = False
    if not valid:
        destination.unlink()
    return valid


if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fixed_layout import PDF

    def fail(message):
        raise ValueError(message)

    source, destination, tools = map(Path, sys.argv[1:])
    if candidate(source):
        api = PDF(tools, fail)
        api.FPDF_InitLibrary()
        try:
            with api.open_document(source, fail) as document:
                prepare(source, destination, api, document)
        finally:
            api.FPDF_DestroyLibrary()
