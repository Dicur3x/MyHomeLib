"""Restore verified text mappings and outline destinations in a private PDF copy."""

from collections import Counter
import ctypes as C
import importlib.util
from pathlib import Path
import re
import sys


IN_MEMORY_PDF_SIZE = 32 * 1024 * 1024
MAX_SOURCE_SIZE = 512 * 1024 * 1024
WHEEL = Path(__file__).with_name('pdf-runtime') / 'pypdf.whl'
CODE_PAIR = rb'<([\da-fA-F]{2})>\s*<([\da-fA-F]{2})>'
UNICODE = rb'<[\da-fA-F]+>'
# These Type1 fonts use their own names for Kazakh letters.
NEWTON_CYRILLIC = {
    '/cyrKadesc': 'Қ', '/cyrkadesc': 'қ', '/cyrendesc': 'ң',
    '/cyrstraightu': 'ү', '/cyrstraightubar': 'ұ', '/cyrinve': 'ә',
    '/cyrObar': 'Ө', '/cyrobar': 'ө',
}
PRAGMATICA_CYRILLIC = {**NEWTON_CYRILLIC, '/cyrgebar': 'ғ'}
TYPE1_LIGATURES = {
    '/ff': 'ff', '/f_f': 'ff', '/fi': 'fi', '/f_i': 'fi', '/fl': 'fl', '/f_l': 'fl',
    '/ffi': 'ffi', '/f_f_i': 'ffi', '/ffl': 'ffl', '/f_f_l': 'ffl',
}
DISTILLER_FONT = re.compile(r'/[A-Z]{6}\+MSTT[\daA-Fa-f]+\Z')
DISTILLER_PRODUCER = re.compile(r'(?:Adobe )?Acrobat Distiller(?:\s|$)', re.I)
MSTT_WORDS = re.compile(r'\b(?:и|в|на|что|не|как|для|из|по|это|от|при|до|его|или|так|і|та|що|від|але|ў|гэта)\b')
MSTT_CMAP = (b'/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n'
            b'/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
            b'/CMapName /HomeLibre-MSTT-UCS def\n/CMapType 2 def\n'
            b'1 begincodespacerange\n<00> <FF>\nendcodespacerange\n'
            b'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n')
MSTT_REPAIR_NOTICE = 'Кириллица восстановлена по кодировке встроенных шрифтов PDF.'
CFF_STANDARD_NAMES = {
    65: 'quoteleft', 101: 'florin', 105: 'quotedblleft', 108: 'guilsinglright',
    121: 'ellipsis', 148: 'oe', 192: 'Scaron',
}
# Older Peterburg fonts have misleading glyph names. These distinctive
# assignments identify the retained Windows-1251 encoding across subsets.
PETERBURG_SLOTS = {
    0xc0: 'grave.g006B', 0xc1: 'a.g0072', 0xcb: 'k.g007F', 0xd2: 'Scaron',
    0xe0: 'equal.g00C8', 0xe3: '.notdef.g0104', 0xee: 'percent.g00BA',
    0xf1: 'quotedblleft', 0xfc: '.notdef.g0109',
}


def candidate(source):
    if not WHEEL.is_file() or source.stat().st_size > MAX_SOURCE_SIZE:
        return False
    with source.open('rb') as stream:
        return stream.read(5) == b'%PDF-'


def sample_text_health(api, document, numbers, prose=None):
    generated = getattr(api.dll, 'FPDFText_IsGenerated', None)
    mapping_error = getattr(api.dll, 'FPDFText_HasUnicodeMapError', None)
    for callback in (generated, mapping_error):
        if callback is not None:
            callback.argtypes = [C.c_void_p, C.c_int]
            callback.restype = C.c_int
    samples = []
    for number in numbers:
        page = api.FPDF_LoadPage(document, number)
        invalid, errors = 0, 0
        excerpt = [] if prose is not None else None
        if not page:
            raise ValueError('Cannot inspect PDF page')
        try:
            text = api.FPDFText_LoadPage(page)
            if not text:
                raise ValueError('Cannot inspect PDF text layer')
            try:
                count = api.FPDFText_CountChars(text)
                if count < 0:
                    raise ValueError('Cannot count PDF characters')
                for index in range(min(count, 12000)):
                    code = api.FPDFText_GetUnicode(text, index)
                    if excerpt is not None:
                        excerpt.append(chr(code) if 0 < code <= 0x10ffff else '\ufffd')
                    if mapping_error is not None and mapping_error(text, index) == 1:
                        errors += 1
                    if code in (0, 0xfffd):
                        invalid += 1
                        continue
                    if not 0 < code < 32:
                        continue
                    if code in (9, 10, 13) and (generated is None or generated(text, index) != 0):
                        continue
                    if code == 2 and api.FPDFText_IsHyphen and api.FPDFText_IsHyphen(text, index) == 1:
                        continue
                    invalid += 1
            finally:
                api.FPDFText_ClosePage(text)
        finally:
            api.FPDF_ClosePage(page)
        if excerpt is not None:
            prose.update(MSTT_WORDS.findall(''.join(excerpt).casefold()))
        samples.append((invalid, errors))
    return samples


def sample_invalid_codes(api, document, numbers):
    return [invalid for invalid, _ in sample_text_health(api, document, numbers)]


def repair_cmap(data, mappings):
    if len(data) > 65536 or data.count(b'endcmap') != 1 or b'usecmap' in data:
        return None
    clean = re.sub(rb'%[^\r\n]*', b'', data)
    ranges = re.findall(rb'begincodespacerange(.*?)endcodespacerange', clean, re.S)
    allowed = set()
    for block in ranges:
        for low, high in re.findall(CODE_PAIR, block):
            allowed.update(range(int(low, 16), int(high, 16) + 1))
        if re.sub(CODE_PAIR, b'', block).strip():
            return None
    missing = mappings.keys() & allowed
    patterns = (
        (b'bfchar', rb'<([\da-fA-F]{2})>\s*' + UNICODE),
        (b'bfrange', CODE_PAIR + rb'\s*(?:' + UNICODE + rb'|\[(?:\s*' + UNICODE + rb')+\s*\])'),
    )
    for name, pattern in patterns:
        for block in re.findall(rb'begin' + name + rb'(.*?)end' + name, clean, re.S):
            for match in re.finditer(pattern, block):
                low = int(match[1], 16)
                high = int(match[2], 16) if match.lastindex == 2 else low
                missing.difference_update(range(low, high + 1))
            if re.sub(pattern, b'', block).strip():
                return None
    if not missing:
        return None
    entries = [f'<{code:02X}> <{mappings[code].encode("utf-16-be").hex().upper()}>\n'
               for code in sorted(missing)]
    blocks = []
    for start in range(0, len(entries), 100):
        block = entries[start:start + 100]
        blocks.append(f'{len(block)} beginbfchar\n' + ''.join(block) + 'endbfchar\n')
    return data.replace(b'endcmap', ''.join(blocks).encode('ascii') + b'endcmap')


def cff_index(data, start, limit):
    if not 0 <= start <= len(data) - 2:
        raise ValueError
    count = int.from_bytes(data[start:start + 2], 'big')
    start += 2
    if not count:
        return [], start
    size = data[start]
    start += 1
    contents = start + (count + 1) * size
    if count > limit or not 1 <= size <= 4 or contents > len(data):
        raise ValueError
    cuts = [int.from_bytes(data[pos:pos + size], 'big') for pos in range(start, contents, size)]
    if cuts[0] != 1 or cuts[-1] > len(data) + 1 - contents or cuts != sorted(cuts):
        raise ValueError
    return [data[contents + a - 1:contents + b - 1] for a, b in zip(cuts, cuts[1:])], contents + cuts[-1] - 1


def cff_offsets(dictionary):
    values, offsets, entries = [], {}, iter(dictionary)
    for token in entries:
        if token <= 21:
            if token == 12:
                next(entries)
            if token in (15, 16, 17):
                if token in offsets or len(values) != 1 or not isinstance(values[0], int):
                    raise ValueError
                offsets[token] = values[0]
            values.clear()
        elif token == 30:
            while True:
                digit = next(entries)
                if (digit >> 4) == 15 or (digit & 15) == 15:
                    break
            values.append(None)
        elif token in (28, 29):
            packed = bytes([next(entries) for _ in range(2 if token == 28 else 4)])
            values.append(int.from_bytes(packed, 'big', signed=True))
        elif 32 <= token <= 246:
            values.append(token - 139)
        elif 247 <= token <= 254:
            sign = 1 if token < 251 else -1
            values.append(sign * (((token - 247) % 4) * 256 + next(entries) + 108))
        else:
            raise ValueError
        if len(values) > 48:
            raise ValueError
    if values:
        raise ValueError
    return offsets.get(15, 0), offsets.get(16, 0), offsets.get(17, 0)


def cff_legacy_encoding(raw):
    """Read the custom byte encoding of a single name-keyed CFF 1 font."""
    if len(raw) < 4 or len(raw) > 512 * 1024 or raw[:2] != b'\x01\x00' or raw[2] < 4:
        return None
    data = memoryview(raw)
    try:
        names, end = cff_index(data, raw[2], 1)
        dictionaries, end = cff_index(data, end, 1)
        strings, end = cff_index(data, end, 1024)
        if len(names) != 1 or len(dictionaries) != 1:
            return None
        charset, encoding, glyphs = cff_offsets(dictionaries[0])
        if not all(end <= offset < len(data) for offset in (charset, encoding, glyphs)):
            return None
        charstrings, _ = cff_index(data, glyphs, 1024)
        if len(charstrings) < 2 or data[charset] not in (0, 1, 2):
            return None
        charformat = data[charset]
        sids = [0]
        pos = charset + 1
        while len(sids) < len(charstrings):
            first = data[pos] * 256 + data[pos + 1]
            pos += 2
            last = 0
            if charformat:
                last = data[pos]
                pos += 1
                if charformat == 2:
                    last = last * 256 + data[pos]
                    pos += 1
            if first == 0 or first + last >= 391 + len(strings) or len(sids) + last >= len(charstrings):
                return None
            sids.extend(range(first, first + last + 1))
        if len(sids) != len(set(sids)):
            return None
        kind = data[encoding] & 127
        count = data[encoding + 1]
        pos = encoding + 2
        if kind == 0:
            codes = list(data[pos:pos + count])
            if len(codes) != count:
                return None
            pos += count
        elif kind == 1:
            codes = []
            for _ in range(count):
                first, last = data[pos], data[pos + 1]
                pos += 2
                if first + last > 255 or len(codes) + last >= len(sids):
                    return None
                codes.extend(range(first, first + last + 1))
        else:
            return None
        slots = dict(zip(codes, sids[1:]))
        if len(codes) >= len(sids) or len(slots) != len(codes):
            return None
        if data[encoding] & 128:
            count = data[pos]
            pos += 1
            for _ in range(count):
                code, sid = data[pos], data[pos + 1] * 256 + data[pos + 2]
                pos += 3
                if sid not in sids or sid == 0 or code in slots:
                    return None
                slots[code] = sid
        glyph_names = {sid: bytes(strings[sid - 391]).decode('ascii') if sid >= 391 else CFF_STANDARD_NAMES.get(sid)
                       for sid in sids}
        return names[0].tobytes().decode('ascii'), {code: glyph_names[sid] for code, sid in slots.items()}, set(glyph_names.values())
    except (IndexError, ValueError, StopIteration):
        return None


def cff_legacy_slots(raw):
    encoding = cff_legacy_encoding(raw)
    return encoding[1] if encoding is not None else {}


CFF_CMAP_SECTION = re.compile(rb'(?<!\S)(\d{1,3})\s+begin(bfchar|bfrange)\b(.*?)end\2\b', re.S)
CFF_CMAP_RANGE = re.compile(CODE_PAIR + rb'\s*(?:(' + UNICODE + rb')|\[((?:\s*' + UNICODE + rb')+\s*)\])')


def replace_cff_cmap(data, replacements):
    if len(data) > 65536 or not replacements or b'usecmap' in data or data.count(b'endcmap') != 1:
        return None
    data = re.sub(rb'%[^\r\n]*', b'', data)
    codespaces = re.findall(rb'begincodespacerange(.*?)endcodespacerange', data, re.S)
    allowed = set()
    for block in codespaces:
        if re.sub(CODE_PAIR, b'', block).strip():
            return None
        for low, high in re.findall(CODE_PAIR, block):
            allowed.update(range(int(low, 16), int(high, 16) + 1))
    current = {}
    sections = list(CFF_CMAP_SECTION.finditer(data))
    if not sections or len(sections) != len(re.findall(rb'begin(?:bfchar|bfrange)\b', data)):
        return None
    for block in sections:
        single = block[2] == b'bfchar'
        pattern = re.compile(rb'<([\da-fA-F]{2})>\s*(' + UNICODE + rb')') if single else CFF_CMAP_RANGE
        matches = list(pattern.finditer(block[3]))
        if len(matches) != int(block[1]) or pattern.sub(b'', block[3]).strip():
            return None
        for match in matches:
            first = int(match[1], 16)
            stop = first + 1 if single else int(match[2], 16) + 1
            span = range(first, stop)
            if not span or any(code not in allowed or code in current for code in span):
                return None
            if single or match[3]:
                value = match[2] if single else match[3]
                digits = len(value) - 2
                if digits % 4 or not 0 < digits <= 64:
                    return None
                start = int(value[1:-1], 16)
                if start + len(span) > 16 ** digits:
                    return None
                current.update((code, f'<{start + index:0{digits}X}>'.encode('ascii'))
                               for index, code in enumerate(span))
            else:
                values = re.findall(UNICODE, match[4])
                if len(values) != len(span) or any((len(value) - 2) % 4 or len(value) > 66 for value in values):
                    return None
                current.update(zip(span, values))
    changes = {code: f'<{value.encode("utf-16-be").hex().upper()}>'.encode('ascii')
               for code, value in replacements.items() if code in allowed}
    if not any(current.get(code, b'').upper() != value for code, value in changes.items()):
        return None
    current.update(changes)
    pairs = [f'<{code:02X}> '.encode('ascii') + value for code, value in sorted(current.items())]
    out = b''.join(f'{len(pairs[i:i + 100])} beginbfchar\n'.encode('ascii') +
                   b'\n'.join(pairs[i:i + 100]) + b'\nendbfchar\n' for i in range(0, len(pairs), 100))
    return CFF_CMAP_SECTION.sub(b'', data).replace(b'endcmap', out + b'endcmap')


def embedded_type1_program(font):
    descriptor = font.get('/FontDescriptor')
    if descriptor is None or not hasattr(descriptor.get_object(), 'get'):
        return None
    program = descriptor.get_object().get('/FontFile3')
    if program is None:
        return None
    program = program.get_object()
    return program if hasattr(program, 'get_data') and program.get('/Subtype') == '/Type1C' else None


def restore_peterburg(font, differences, cmap):
    name = str(font.get('/BaseFont', '')).split('+')[-1]
    if name not in ('Peterburg', 'Peterburg-Italic', 'Peterburg-Bold', 'Peterburg-BoldItalic'):
        return None
    program = embedded_type1_program(font)
    if program is None:
        return None
    slots = cff_legacy_slots(program.get_data())
    seen = {code: slots[code] for code in PETERBURG_SLOTS if slots.get(code)}
    if len(seen) < 6 or any(value != PETERBURG_SLOTS[code] for code, value in seen.items()):
        return None
    values = {}
    ambiguous = set()
    for code, glyph in slots.items():
        if glyph in values:
            ambiguous.add(glyph)
        else:
            values[glyph] = code
    replacements = {}
    for code, glyph in differences:
        glyph = glyph[1:]
        slot = values.get(glyph, 0)
        if slot < 32 or glyph in ambiguous:
            continue
        try:
            value = bytes([slot]).decode('cp1251')
        except UnicodeDecodeError:
            continue
        if value.isprintable():
            replacements[code] = value
    return replace_cff_cmap(cmap.get_data(), replacements) if replacements else None


def resource_fonts(roots, discarded_images=None):
    from pypdf.generic import DictionaryObject, IndirectObject, StreamObject

    resources = list(roots)
    visited, seen_fonts = set(), set()
    while resources:
        reference = resources.pop()
        if reference is None:
            continue
        resource = reference.get_object()
        if not isinstance(resource, DictionaryObject) or id(resource) in visited:
            continue
        visited.add(id(resource))
        xobjects = resource.get('/XObject', DictionaryObject()).get_object()
        if isinstance(xobjects, DictionaryObject):
            for item in xobjects.values():
                key = None
                if discarded_images is not None and isinstance(item, IndirectObject):
                    key = item.generation, item.idnum
                    if key in discarded_images:
                        continue
                form = item.get_object()
                if not isinstance(form, StreamObject):
                    continue
                if form.get('/Subtype') == '/Form':
                    resources.append(form.get('/Resources'))
                elif key is not None and form.get('/Subtype') == '/Image':
                    # Looking up an XObject also reads its encoded stream.
                    # Keep the font scan from caching every scanned page.
                    discarded_images.add(key)
                    item.pdf.resolved_objects.pop(key, None)
        fonts = resource.get('/Font', DictionaryObject()).get_object()
        if not isinstance(fonts, DictionaryObject):
            continue
        for reference in fonts.values():
            font = reference.get_object()
            if isinstance(font, DictionaryObject) and id(font) not in seen_fonts:
                seen_fonts.add(id(font))
                yield font


def type1_encoding(font):
    from pypdf.generic import ArrayObject, DictionaryObject, NameObject, NumberObject, StreamObject

    if font.get('/Subtype') != '/Type1' or '/Encoding' not in font:
        return None, {}
    encoding = font['/Encoding']
    stream = font['/ToUnicode'] if '/ToUnicode' in font else None
    if not isinstance(encoding, DictionaryObject) or (stream is not None and not isinstance(stream, StreamObject)):
        return None, {}
    differences = encoding.get('/Differences')
    if differences is None or not isinstance(differences.get_object(), ArrayObject):
        return None, {}
    code, glyphs, ambiguous = 256, {}, set()
    for token in differences.get_object():
        if isinstance(token, NumberObject):
            code = int(token)
            continue
        if 0 <= code <= 255 and isinstance(token, NameObject):
            if code in glyphs and glyphs[code] != token:
                ambiguous.add(code)
            glyphs[code] = str(token)
        code += 1
    for code in ambiguous:
        del glyphs[code]
    return stream, glyphs


def repair_ligatures(stream, glyphs, data=None):
    ligatures = {code: TYPE1_LIGATURES[glyph] for code, glyph in glyphs.items()
                 if glyph in TYPE1_LIGATURES}
    return repair_cmap(stream.get_data() if data is None else data, ligatures) if ligatures else None


def cyrillic_glyph_mappings(font, glyphs):
    from pypdf._codecs import adobe_glyphs

    name = str(font.get('/BaseFont', '')).split('+')[-1]
    aliases = {}
    if name in ('Newton-Regular', 'Newton-Bold', 'Newton-Italic', 'Newton-BoldItalic'):
        aliases = NEWTON_CYRILLIC
    elif name in ('Pragmatica-Reg', 'Pragmatica-Bold'):
        aliases = PRAGMATICA_CYRILLIC
    values = {}
    for code, glyph in glyphs.items():
        value = aliases.get(glyph) or adobe_glyphs.get(glyph)
        if value is None and (literal := re.fullmatch(r'/(?:uni|u)([0-9A-Fa-f]{4})', glyph)):
            value = chr(int(literal[1], 16))
        if value and len(value) == 1 and '\u0400' <= value <= '\u052f':
            values[code] = value
    return values


def restore_named_cyrillic(font, stream, glyphs, data=None):
    mappings = cyrillic_glyph_mappings(font, glyphs)
    if not mappings:
        return None
    original = stream.get_data() if data is None else data
    updated = repair_cmap(original, mappings)
    if updated is None:
        return None
    program = embedded_type1_program(font)
    if program is None:
        return None
    encoding = cff_legacy_encoding(program.get_data())
    if encoding is None or '/' + encoding[0] != font.get('/BaseFont'):
        return None
    confirmed = {code: letter for code, letter in mappings.items() if glyphs[code][1:] in encoding[2]}
    return updated if len(confirmed) == len(mappings) else repair_cmap(original, confirmed)


def distiller_font(font):
    return (font.get('/Subtype') == '/Type1' and '/ToUnicode' not in font and
            bool(DISTILLER_FONT.fullmatch(str(font.get('/BaseFont', '')))))


def mstt_mappings(glyphs, slots, charset):
    if len(slots) < 4 or any(glyph != f'G{code:02X}' for code, glyph in slots.items()):
        return {}
    replacements = {}
    for code, glyph in glyphs.items():
        base, dot, suffix = glyph[1:].partition('.')
        if glyph[1:] not in charset or not re.fullmatch(r'G[0-9A-F]{2}', base):
            continue
        slot = int(base[1:], 16)
        if dot:
            # Recognise ASCII glyph variants present in the embedded charset.
            if not 0x21 <= slot <= 0x7E or not re.fullmatch(r'[A-Za-z0-9_]+', suffix):
                continue
        elif slots.get(slot) != base:
            continue
        try:
            value = bytes([slot]).decode('cp1251')
        except UnicodeDecodeError:
            continue
        if value.isprintable() or value in '\u00a0\u00ad':
            replacements[code] = value
    return replacements


def restore_distiller(font, glyphs):
    program = embedded_type1_program(font)
    if program is None:
        return None
    encoding = cff_legacy_encoding(program.get_data())
    if encoding is None or '/' + encoding[0] != font.get('/BaseFont'):
        return None
    mappings = mstt_mappings(glyphs, encoding[1], encoding[2])
    return repair_cmap(MSTT_CMAP, mappings) if mappings else None


def font_repair_pages(reader, consider_distiller, discarded_images=None):
    named_glyphs, distiller = [], []
    fonts, resources = {}, {}
    for number, page in enumerate(reader.pages):
        root = page.get('/Resources')
        if root is None:
            continue
        key = id(root.get_object())
        if key not in resources:
            kinds = set()
            for font in resource_fonts((root,), discarded_images):
                font_key = id(font)
                if font_key not in fonts:
                    if consider_distiller and distiller_font(font):
                        fonts[font_key] = 'distiller'
                    else:
                        stream, glyphs = type1_encoding(font)
                        fonts[font_key] = 'named' if stream is not None and (
                            repair_ligatures(stream, glyphs) or restore_named_cyrillic(font, stream, glyphs)) else ''
                kinds.add(fonts[font_key])
            resources[key] = kinds
        if 'named' in resources[key]:
            named_glyphs.append(number)
        if 'distiller' in resources[key]:
            distiller.append(number)
    return named_glyphs, distiller


def font_updates(document, notices, tools, consider_distiller=False, discarded_images=None):
    from pypdf.generic import IndirectObject

    reference_fonts = {}
    module_path = Path(__file__).with_name('pdf_truetype_mapping.py')
    identity_mapping = None
    if module_path.is_file():
        spec = importlib.util.spec_from_file_location('pdf_truetype_mapping', module_path)
        identity_mapping = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(identity_mapping)
    for font in resource_fonts((page.get('/Resources') for page in document.pages), discarded_images):
        if discarded_images is not None:
            reference = getattr(font, 'indirect_reference', None)
            if not isinstance(reference, IndirectObject) or reference.pdf is not document:
                continue
        if font.get('/Subtype') == '/Type0' and identity_mapping is not None:
            data = identity_mapping.recover_identity_mapping(font, reference_fonts, tools)
            if data is not None:
                notices.add('Текстовый слой PDF восстановлен по совпадающим контурам встроенных шрифтов.')
        else:
            stream, glyphs = type1_encoding(font)
            if not glyphs:
                continue
            if stream is None:
                if not (consider_distiller and distiller_font(font)):
                    continue
                data = restore_distiller(font, glyphs)
                if data is not None:
                    notices.add(MSTT_REPAIR_NOTICE)
            else:
                data = restore_peterburg(font, glyphs.items(), stream)
                if data is not None:
                    notices.add('Текстовый слой PDF восстановлен по кодировке встроенных шрифтов Peterburg.')
                else:
                    hyphens = {code: '-' for code, glyph in glyphs.items()
                               if 0 < code < 32 and glyph == '/hyphenminus'}
                    if hyphens:
                        data = repair_cmap(stream.get_data(), hyphens)
                        if data is not None:
                            notices.add('В текстовом слое PDF восстановлены дефисы, указанные в исходных шрифтах.')
                    with_ligatures = repair_ligatures(stream, glyphs, data)
                    if with_ligatures is not None:
                        notices.add('В текстовом слое PDF восстановлены лигатуры, указанные в исходных шрифтах.')
                        data = with_ligatures
                with_cyrillic = restore_named_cyrillic(font, stream, glyphs, data)
                if with_cyrillic is not None:
                    notices.add('В текстовом слое PDF восстановлены буквы по именам знаков во встроенных шрифтах.')
                    data = with_cyrillic
        if data is not None:
            yield font, data


def repair_fonts(writer, notices, tools, consider_distiller=False):
    from pypdf.generic import DecodedStreamObject, NameObject

    repaired = 0
    for font, data in font_updates(writer, notices, tools, consider_distiller):
        cmap = DecodedStreamObject()
        cmap.set_data(data)
        # A CMap can be shared by fonts whose code numbers mean different things.
        font[NameObject('/ToUnicode')] = writer._add_object(cmap)
        repaired += 1
    return repaired


def structure_page(root, pages, check):
    from pypdf.generic import ArrayObject, DictionaryObject, IndirectObject, NumberObject

    pending = [(root, None)]
    visited = set()
    target = None
    inspected = 0
    while pending:
        item, page = pending.pop()
        inspected += 1
        if inspected > 4096:
            return None
        if check is not None:
            check()
        if isinstance(item, IndirectObject):
            reference = (item.idnum, item.generation)
            if reference in visited:
                return None
            visited.add(reference)
            item = item.get_object()
        if isinstance(item, ArrayObject):
            if not item or len(item) + len(pending) + inspected > 4096:
                return None
            pending.extend((child, page) for child in item)
            continue
        if isinstance(item, DictionaryObject):
            if '/Pg' in item:
                page = item.raw_get('/Pg')
                if not isinstance(page, IndirectObject) or (page.idnum, page.generation) not in pages:
                    return None
            kind = item.get('/Type')
            if kind == '/MCR' and isinstance(item.get('/MCID'), NumberObject) and item['/MCID'] >= 0:
                pass
            elif kind == '/OBJR' and isinstance(item.get('/Obj'), IndirectObject):
                pass
            elif kind in (None, '/StructElem') and '/S' in item and '/K' in item:
                pending.append((item.raw_get('/K'), page))
                continue
            else:
                return None
        elif not isinstance(item, NumberObject) or item < 0:
            return None
        # A structure destination is usable only when every content item has
        # an explicit page and all of them refer to the same page.
        if page is None or (target is not None and page != target):
            return None
        target = page
    return target


def outline_destination(destination, page):
    from pypdf.generic import ArrayObject, FloatObject, NameObject, NullObject, NumberObject

    if destination is None or isinstance(destination, NullObject):
        return ArrayObject([page, NameObject('/Fit')])
    if not isinstance(destination, ArrayObject) or len(destination) < 2 or not isinstance(destination[0], NullObject):
        return None
    arities = {'/Fit': 0, '/FitB': 0, '/FitH': 1, '/FitV': 1, '/FitBH': 1, '/FitBV': 1, '/XYZ': 3, '/FitR': 4}
    if not isinstance(destination[1], NameObject) or arities.get(destination[1]) != len(destination) - 2:
        return None
    if any(not isinstance(value, (FloatObject, NullObject, NumberObject)) for value in destination[2:]):
        return None
    return ArrayObject([page, *destination[1:]])


def outline_updates(reader, check):
    from pypdf.generic import DictionaryObject, IndirectObject, NameObject, TextStringObject

    outline = reader.root_object.get('/Outlines')
    outline = outline.get_object() if outline is not None else None
    if not isinstance(outline, DictionaryObject):
        return []
    pending = [(outline.get('/First'), 1)]
    pages = None
    seen, updates = set(), []
    while pending and len(seen) < 4096:
        reference, depth = pending.pop()
        if not isinstance(reference, IndirectObject) or depth > 64 or (reference.idnum, reference.generation) in seen:
            continue
        seen.add((reference.idnum, reference.generation))
        if check is not None:
            check()
        item = reference.get_object()
        if not isinstance(item, DictionaryObject):
            continue
        pending.extend(((item.get('/Next'), depth), (item.get('/First'), depth + 1)))
        name, structure = item.get('/Title'), item.get('/SE')
        if not isinstance(name, TextStringObject) or not name.strip() or not isinstance(structure, IndirectObject):
            continue
        action = item.get('/A')
        field = '/Dest'
        data = item
        if action is not None:
            action = action.get_object()
            if '/Dest' in item or not isinstance(action, DictionaryObject) or action.get('/S') != '/GoTo':
                continue
            field, data = '/D', action
        current = data.get(field)
        # Check the destination shape before following the structure graph.
        destination = outline_destination(current, structure)
        if destination is None:
            continue
        if pages is None:
            pages = {(page.indirect_reference.idnum, page.indirect_reference.generation): index
                     for index, page in enumerate(reader.pages, 1) if page.indirect_reference is not None}
        page = structure_page(structure, pages, check)
        if page is None:
            continue
        destination[0] = page
        replacement = DictionaryObject(item)
        if action is not None:
            # The action can be shared. Replace it only in this outline item.
            replacement[NameObject('/A')] = DictionaryObject(action)
            replacement['/A'][NameObject(field)] = destination
        else:
            replacement[NameObject(field)] = destination
        target = (pages[page.idnum, page.generation], ' '.join(name.split()), depth)
        updates.append((reference, replacement, target))
    return updates


def write_pdf_increment(reader, output, updates, check, outlines=()):
    from pypdf.generic import DecodedStreamObject, DictionaryObject, IndirectObject, NameObject, NumberObject

    next_id = int(reader.trailer['/Size'])
    old_numbers = [max(group, default=0) for group in reader.xref.values()]
    old_numbers.append(max(reader.xref_objStm, default=0))
    root = reader.trailer.raw_get('/Root')
    if next_id <= max(old_numbers) or not isinstance(root, IndirectObject) or reader._startxref <= 0:
        raise ValueError('Invalid cross-reference table')
    updates_by_id = {}
    def add_update(reference, contents, cmap):
        if (not isinstance(reference, IndirectObject) or reference.pdf is not reader or
                not 0 < reference.idnum < next_id or reference.idnum in updates_by_id):
            raise ValueError('Invalid PDF update reference')
        updates_by_id[reference.idnum] = reference.generation, contents, cmap

    for font, data in updates:
        add_update(getattr(font, 'indirect_reference', None), font, data)
    for reference, contents, _ in outlines:
        add_update(reference, contents, None)
    if not updates_by_id:
        return False

    # Keep all existing content and font programs in the original byte range.
    # The increment contains only the modified dictionaries and new CMaps.
    trailer = DictionaryObject({NameObject('/Root'): root, NameObject('/Prev'): NumberObject(reader._startxref)})
    for key in ('/Info', '/ID'):
        if key in reader.trailer:
            trailer[NameObject(key)] = reader.trailer.raw_get(key)
    offsets = {}
    reader.stream.seek(0)
    while chunk := reader.stream.read(1024 * 1024):
        if check is not None:
            check()
        output.write(chunk)
    output.write(b'\n')

    def write_object(number, generation, value):
        offsets[number] = output.tell(), generation
        output.write(f'{number} {generation} obj\n'.encode('ascii'))
        value.write_to_stream(output)
        output.write(b'\nendobj\n')

    for number, (generation, contents, data) in sorted(updates_by_id.items()):
        if data is None:
            write_object(number, generation, contents)
            continue
        cmap = DecodedStreamObject()
        cmap.set_data(data)
        font_with_map = DictionaryObject(contents)
        font_with_map[NameObject('/ToUnicode')] = IndirectObject(next_id, 0, reader)
        write_object(number, generation, font_with_map)
        write_object(next_id, 0, cmap)
        next_id += 1
    startxref = output.tell()
    output.write(b'xref\n')
    for number, (offset, generation) in sorted(offsets.items()):
        output.write(f'{number} 1\n{offset:010d} {generation:05d} n\r\n'.encode('ascii'))
    trailer[NameObject('/Size')] = NumberObject(next_id)
    output.write(b'trailer\n')
    trailer.write_to_stream(output)
    output.write(f'\nstartxref\n{startxref}\n%%EOF\n'.encode('ascii'))
    return True


def repair_copy(reader, destination, api, pages, samples, before, prose_before, consider_distiller,
                discarded_images, check, outlines=(), previous_outline=()):
    from pypdf import PdfWriter

    notices = set()
    if discarded_images is None and not outlines:
        writer = PdfWriter(reader, incremental=True, strict=True, incremental_clone_object_count_limit=25000,
                           incremental_clone_object_id_limit=50000)
        if not repair_fonts(writer, notices, api.tools, consider_distiller):
            return None
        repaired_fonts = True
    else:
        writer = None
        updates = list(font_updates(reader, notices, api.tools, consider_distiller, discarded_images)) if before is not None else []
        repaired_fonts = bool(updates)
        if not (repaired_fonts or outlines):
            return None

    created, valid = False, False
    try:
        with destination.open('xb') as copy:
            created = True
            if writer is None:
                if not write_pdf_increment(reader, copy, updates, check, outlines):
                    return None
            else:
                writer.write(copy)
        with api.open_document(destination, fail) as repaired:
            if api.FPDF_GetPageCount(repaired) != pages:
                return None
            if outlines:
                current_outline = api.page_outline(repaired, pages, set())
                expected = Counter(previous_outline) + Counter(target for _, _, target in outlines)
                if Counter(current_outline) != expected:
                    return None
                notices.add(f'Восстановлены переходы оглавления PDF по структуре документа. Пунктов: {len(outlines)}.')
            if repaired_fonts:
                prose = Counter() if MSTT_REPAIR_NOTICE in notices else None
                after = sample_text_health(api, repaired, samples, prose)
                # The font is usable only when its text improves the source.
                if after == before or any((invalid > previous_invalid or errors > previous_errors)
                    for (invalid, errors), (previous_invalid, previous_errors) in zip(after, before)):
                    return None
                if prose is not None:
                    gained = prose - prose_before
                    if len(gained) < 4 or gained.total() < 12:
                        return None
        valid = True
        return notices
    finally:
        if created and not valid:
            destination.unlink(missing_ok=True)


def prepare(source, destination, api, document, warnings=None, check=None):
    if not candidate(source):
        return False
    pages = api.FPDF_GetPageCount(document)
    if not 0 < pages <= 5000:
        return False
    baseline = set(range(min(4, pages))) | {pages * step // 12 for step in range(12)}

    sys.path.insert(0, str(WHEEL))
    try:
        from pypdf import PdfReader
        from pypdf.errors import DependencyError, PyPdfError
    except ImportError:
        return False
    finally:
        sys.path.pop(0)

    errors = (DependencyError, PyPdfError, OSError, ValueError, KeyError, TypeError, RecursionError, MemoryError)
    try:
        discarded_images = set() if source.stat().st_size > IN_MEMORY_PDF_SIZE else None
        with source.open('rb') as pdf, PdfReader(pdf) as reader:
            if reader.is_encrypted:
                return False
            outline_warnings = set()
            previous_outline = api.page_outline(document, pages, outline_warnings)
            outlines = []
            if outline_warnings:
                try:
                    outlines = outline_updates(reader, check)
                except errors:
                    pass  # An invalid structure tree must not block font repair.
            producer = (reader.metadata or {}).get('/Producer')
            consider_distiller = isinstance(producer, str) and bool(DISTILLER_PRODUCER.match(producer))
            try:
                named_glyphs, distiller = font_repair_pages(reader, consider_distiller, discarded_images)
                representative = {distiller[len(distiller) * step // 12] for step in range(12)} if distiller else set()
                samples = sorted(baseline.union(named_glyphs, representative))
                prose_before = Counter() if distiller else None
                before = sample_text_health(api, document, samples, prose_before)
            except errors:
                before = None  # Outline repair does not depend on text decoding.
            if before and any(invalid or count_errors for invalid, count_errors in before):
                # A rejected locale or outline candidate must not suppress
                # independent font repairs in the same document.
                for destinations in ((outlines, ()) if outlines else ((),)):
                    for use_distiller in ((True, False) if distiller else (False,)):
                        try:
                            notices = repair_copy(reader, destination, api, pages, samples, before,
                                                  prose_before, use_distiller, discarded_images, check,
                                                  destinations, previous_outline)
                        except errors:
                            continue
                        if notices is not None:
                            if warnings is not None:
                                warnings.update(notices)
                            return True
            if outlines:
                notices = repair_copy(reader, destination, api, pages, (), None, None, False,
                                      discarded_images, check, outlines, previous_outline)
                if notices is not None:
                    if warnings is not None:
                        warnings.update(notices)
                    return True
    except errors:
        return False
    return False


def fail(message):
    raise ValueError(message)


if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fixed_layout import PDF

    source, destination, tools = map(Path, sys.argv[1:])
    if candidate(source):
        api = PDF(tools, fail)
        api.FPDF_InitLibrary()
        try:
            with api.open_document(source, fail) as document:
                prepare(source, destination, api, document)
        finally:
            api.FPDF_DestroyLibrary()
