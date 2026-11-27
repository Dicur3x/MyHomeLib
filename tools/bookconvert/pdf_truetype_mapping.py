"""Recover Unicode from PDF glyph indices verified against Windows fonts."""

from collections import defaultdict
from pathlib import Path
import os
import re
import struct
from unicodedata import normalize


REFERENCE_FILES = {
    'TimesNewRomanPSMT': 'times.ttf',
    'TimesNewRomanPS-BoldMT': 'timesbd.ttf',
    'TimesNewRomanPS-ItalicMT': 'timesi.ttf',
    'TimesNewRomanPS-BoldItalicMT': 'timesbi.ttf',
    'Georgia': 'georgia.ttf',
    'Georgia-Bold': 'georgiab.ttf',
    'Georgia-Italic': 'georgiai.ttf',
    'Georgia-BoldItalic': 'georgiaz.ttf',
    'Calibri': 'calibri.ttf',
    'Calibri-Bold': 'calibrib.ttf',
    'Calibri-Italic': 'calibrii.ttf',
    'Calibri-BoldItalic': 'calibriz.ttf',
    'SegoeUI-Semibold': 'seguisb.ttf',
}
BUNDLED_REFERENCES = {
    'PTSans-Regular': 'PT_Sans-Web-Regular.ttf',
    'PTSans-Bold': 'PT_Sans-Web-Bold.ttf',
    'PTSans-Italic': 'PT_Sans-Web-Italic.ttf',
    'PTSans-BoldItalic': 'PT_Sans-Web-BoldItalic.ttf',
}
MAX_FONT_SIZE = 12 * 1024 * 1024
FORMAT_ERRORS = (ValueError, KeyError, struct.error, UnicodeError)


def uint16(data, pos):
    return struct.unpack_from('>H', data, pos)[0]


def glyph_coordinates(data):
    """Return the encoded outlines with hinting instructions removed."""
    if not data:
        return (), ()
    contours = struct.unpack_from('>h', data)[0]
    if contours >= 0:
        end = 10 + contours * 2
        points = uint16(data, end - 2) + 1 if contours else 0
        start = end + 2 + uint16(data, end)
        if start > len(data):
            raise ValueError('Invalid TrueType instruction length')
        pos, remaining, coordinates = start, points, 0
        while remaining:
            flags = data[pos:pos + 2]
            if not flags or (flags[0] & 8 and len(flags) != 2):
                raise ValueError('Truncated TrueType flags')
            flag = flags[0]
            copies = flags[1] + 1 if flag & 8 else 1
            pos += 2 if flag & 8 else 1
            remaining -= copies
            if remaining < 0:
                raise ValueError('Invalid TrueType flag repeat')
            x_size = 1 if flag & 2 else 0 if flag & 16 else 2
            y_size = 1 if flag & 4 else 0 if flag & 32 else 2
            coordinates += copies * (x_size + y_size)
        if pos + coordinates > len(data):
            raise ValueError('Truncated TrueType coordinates')
        return (data[:end], data[start:pos + coordinates]), ()
    if contours != -1:
        raise ValueError('Unknown TrueType glyph description')
    parts, components = [data[:10]], []
    pos = 10
    while True:
        flag, child = struct.unpack_from('>HH', data, pos)
        size = 8 if flag & 1 else 6
        size += 2 if flag & 8 else 4 if flag & 64 else 8 if flag & 128 else 0
        if pos + size > len(data) or len(components) >= 128:
            raise ValueError('Invalid TrueType components')
        parts.append(((flag & ~0x100), data[pos + 2:pos + size]))
        components.append(child)
        pos += size
        if not flag & 32:
            return tuple(parts), tuple(components)


class TrueType:
    def __init__(self, data):
        if len(data) > MAX_FONT_SIZE or data[:4] != b'\x00\x01\x00\x00':
            raise ValueError('Unsupported TrueType sfnt')
        count = uint16(data, 4)
        if not 0 < count <= 128 or 12 + 16 * count > len(data):
            raise ValueError('Invalid TrueType table count')
        self.tables = {}
        for tag, _, start, size in struct.iter_unpack('>4sIII', data[12:12 + 16 * count]):
            if start + size > len(data) or tag in self.tables:
                raise ValueError('Invalid TrueType table directory')
            self.tables[tag] = data[start:start + size]
        self.glyf = self.tables[b'glyf']
        self.metrics = self.tables[b'hmtx']
        self.count = uint16(self.tables[b'maxp'], 4)
        self.units = uint16(self.tables[b'head'], 18)
        locations = uint16(self.tables[b'head'], 50)
        self.metric_count = uint16(self.tables[b'hhea'], 34)
        if (not 0 < self.metric_count <= self.count or locations not in (0, 1) or
            not 16 <= self.units <= 16384 or len(self.metrics) < 2 * (self.metric_count + self.count)):
            raise ValueError('Invalid TrueType glyph metrics')
        entry = 4 if locations else 2
        end = (self.count + 1) * entry
        loca = self.tables[b'loca']
        if len(loca) < end:
            raise ValueError('Truncated TrueType glyph offsets')
        self.offsets = [offset if locations else 2 * offset
                        for offset, in struct.iter_unpack('>I' if locations else '>H', loca[:end])]
        if self.offsets[-1] > len(self.glyf) or self.offsets != sorted(self.offsets):
            raise ValueError('Invalid TrueType glyph offsets')

    def named(self, expected):
        data = self.tables[b'name']
        _, count, start = struct.unpack_from('>HHH', data)
        if 6 + count * 12 > len(data):
            return False
        for platform, _, _, name, size, offset in struct.iter_unpack('>6H', data[6:6 + count * 12]):
            if platform in (0, 3) and name == 6 and start + offset + size <= len(data):
                if data[start + offset:start + offset + size] == expected.encode('utf-16-be'):
                    return True
        return False

    def glyph(self, gid):
        if not 0 <= gid < self.count:
            raise ValueError('Invalid TrueType glyph index')
        width_offset = 4 * min(gid, self.metric_count - 1)
        side_offset = (4 * gid + 2 if gid < self.metric_count else
                       4 * self.metric_count + 2 * (gid - self.metric_count))
        coordinates, children = glyph_coordinates(self.glyf[self.offsets[gid]:self.offsets[gid + 1]])
        return (uint16(self.metrics, width_offset), uint16(self.metrics, side_offset), coordinates), children

    def unicode_map(self):
        data = self.tables[b'cmap']
        count = uint16(data, 2)
        if uint16(data, 0) or not 0 < count <= 64 or 4 + count * 8 > len(data):
            raise ValueError('Invalid TrueType character table')
        offsets = set()
        for platform, encoding, offset in struct.iter_unpack('>HHI', data[4:4 + count * 8]):
            if platform == 0 or (platform == 3 and encoding in (1, 10)):
                if uint16(data, offset) in (4, 12):
                    offsets.add(offset)
        codes = defaultdict(set)
        for offset in offsets:
            subtable = memoryview(data)[offset:]
            if uint16(data, offset) == 4:
                size = uint16(subtable, 2)
                if not 16 <= size <= len(subtable):
                    raise ValueError('Truncated TrueType character table')
                mappings = bmp_mapping(subtable[:size])
            else:
                mappings = full_mapping(subtable, self.count)
            for code, gid in mappings:
                if 0 < gid < self.count and (chr(code).isprintable() or code in (0xa0, 0xad)):
                    codes[gid].add(code)
        return codes


def bmp_mapping(data):
    count = uint16(data, 6) // 2
    if not count or 16 + 8 * count > len(data):
        raise ValueError('Invalid TrueType character ranges')
    previous_end = -1
    for index in range(count):
        pos = 2 * index
        end, start, delta, offset = (uint16(data, base + pos) for base in
                                     (14, 16 + 2 * count, 16 + 4 * count, 16 + 6 * count))
        if not previous_end < start <= end:
            raise ValueError('Invalid TrueType character range')
        previous_end = end
        for code in range(start, end + 1):
            value = uint16(data, 16 + 6 * count + pos + offset + 2 * (code - start)) if offset else code
            if not offset or value:
                yield code, (value + delta) & 0xffff


def full_mapping(data, glyph_count):
    size, _, count = struct.unpack_from('>III', data, 4)
    if not 16 + 12 * count <= size <= len(data) or count > 65536:
        raise ValueError('Invalid TrueType Unicode ranges')
    previous_end = -1
    for start, end, gid in struct.iter_unpack('>III', data[16:16 + 12 * count]):
        if not previous_end < start <= end <= 0x10ffff or gid + end - start >= glyph_count:
            raise ValueError('Invalid TrueType Unicode range')
        previous_end = end
        for code in range(start, end + 1):
            yield code, gid + code - start


def same_glyph(embedded, reference, gid, cache, stack=frozenset()):
    if gid in cache:
        return cache[gid]
    if gid in stack or len(stack) >= 16:
        return False
    try:
        shape, children = embedded.glyph(gid)
        other_shape, other_children = reference.glyph(gid)
        matches = (shape == other_shape and children == other_children and
                   all(same_glyph(embedded, reference, child, cache, stack | {gid}) for child in children))
    except FORMAT_ERRORS:
        matches = False
    cache[gid] = matches
    return matches


def unicode_cmap(codes):
    lines = ['/CIDInit /ProcSet findresource begin', '12 dict begin', 'begincmap',
             '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
             '/CMapName /HomeLibre-Identity-UCS def', '/CMapType 2 def',
             '1 begincodespacerange', '<0000> <FFFF>', 'endcodespacerange']
    entries = [f'<{gid:04X}> <{chr(code).encode("utf-16-be").hex().upper()}>'
               for gid, code in sorted(codes.items())]
    for start in range(0, len(entries), 100):
        batch = entries[start:start + 100]
        lines.extend((f'{len(batch)} beginbfchar', *batch, 'endbfchar'))
    lines.extend(('endcmap', 'CMapName currentdict /CMap defineresource pop', 'end', 'end'))
    return ('\n'.join(lines) + '\n').encode('ascii')


def reference_fonts(name, tools):
    system = os.environ.get('SystemRoot')
    filename = REFERENCE_FILES.get(name)
    paths = []
    if filename and system:
        folder = Path(system) / 'Fonts'
        stem = Path(filename).stem
        paths.append(folder / filename)
        for pattern in (f'{stem}[0-9]*.ttf', f'{stem}_[0-9]*.ttf'):
            paths.extend(sorted(folder.glob(pattern))[:4])
    bundled = BUNDLED_REFERENCES.get(name)
    if bundled and tools is not None:
        paths.append(tools / 'fonts' / 'ptsans' / bundled)
    loaded = []
    for path in paths:
        try:
            if path.stat().st_size <= MAX_FONT_SIZE:
                reference = TrueType(path.read_bytes())
                if reference.named(name):
                    loaded.append((reference, reference.unicode_map()))
        except (OSError, *FORMAT_ERRORS):
            continue
    return loaded


def unique_unicode(codes):
    if len(codes) == 1 or codes in ({0x20, 0xa0}, {0x2d, 0xad}):
        # The two aliases in each pair share the glyph and metrics. The
        # PDF has no indication of nonbreaking space or discretionary hyphen.
        return min(codes)
    equivalent = {normalize('NFC', chr(code)) for code in codes}
    if len(equivalent) == 1:
        character, = equivalent
        if len(character) == 1:
            return ord(character)
    return None


def recover_identity_mapping(font, references, tools=None):
    """Consider only CIDFontType2 subsets with an unchanged glyph index."""
    if font.get('/Encoding') not in ('/Identity-H', '/Identity-V') or '/ToUnicode' in font:
        return None
    subset = re.fullmatch(r'/[A-Z]{6}\+(.+)', str(font.get('/BaseFont', '')))
    if subset is None or (subset[1] not in REFERENCE_FILES and subset[1] not in BUNDLED_REFERENCES):
        return None
    name = subset[1]
    try:
        descendants = font['/DescendantFonts']
        if len(descendants) != 1:
            return None
        descendant = descendants[0].get_object()
        descendant_name = re.fullmatch(r'/[A-Z]{6}\+(.+)', str(descendant.get('/BaseFont', '')))
        # Merged PDFs can give the wrapper a new subset prefix while
        # retaining the same descendant and embedded TrueType program.
        if (descendant.get('/Subtype') != '/CIDFontType2' or
            descendant.get('/CIDToGIDMap', '/Identity') != '/Identity' or
            descendant_name is None or descendant_name[1] != name):
            return None
        stream = descendant['/FontDescriptor']['/FontFile2']
        if not 0 < stream.get('/Length1', MAX_FONT_SIZE) <= MAX_FONT_SIZE:
            return None
        embedded = TrueType(stream.get_data())
        if name not in references:
            references[name] = reference_fonts(name, tools)
        verified = defaultdict(set)
        for reference, candidates in references[name]:
            if embedded.units != reference.units:
                continue
            cache = {}
            for gid, codes in candidates.items():
                if gid < embedded.count and same_glyph(embedded, reference, gid, cache):
                    verified[gid].update(codes)
        selected = {gid: code for gid, codes in verified.items() if (code := unique_unicode(codes)) is not None}
        # A blank glyph and punctuation alone do not establish the font match.
        if sum(chr(code).isalpha() for code in selected.values()) < 8:
            return None
        return unicode_cmap(selected)
    except (AttributeError, IndexError, OSError, TypeError, *FORMAT_ERRORS):
        return None
