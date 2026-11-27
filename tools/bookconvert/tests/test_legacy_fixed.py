"""New containers and fixed-page conversion: actual engines, not mocked output."""
from pathlib import Path
from itertools import product
from contextlib import ExitStack
from io import BytesIO
import base64
import ctypes
import hashlib
import importlib.util
import os
import re
import json
import subprocess
import sys
import struct
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile
import zlib
from email.message import EmailMessage

ROOT = Path(__file__).resolve().parents[1]
def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
c, legacy, fixed = module('convert_book'), module('legacy_inputs'), module('fixed_layout')
text_inputs, office = module('text_inputs'), module('office_inputs')
TOOLS = Path(os.environ.get('HOMELIB_TEST_TOOLS', ROOT.parents[1] / 'Program/Out/Bin64/tools'))


def pdf_fixture(text=True, ocr=False, pages=1, image_only_last=False, tiled_scan=False, outline=False,
                broken_destination=False, font_hyphen=False, ligature_page=None, structure_destination=False):
    # Tiny independent PDF writer for a deterministic text/illustration fixture.
    content = b'q 90 0 0 65 40 170 cm /Im Do Q\n'
    if tiled_scan:
        content += b'q 90 0 0 65 130 170 cm /Im Do Q\n'
    if text:
        content += b'BT /F1 12 Tf ' + (b'3 Tr ' if ocr else b'')
        content += b'40 260 Td (First readable paragraph with an illustration below.) Tj 0 -150 Td (Last paragraph preserves the final sentence.) Tj ET\n'
        if font_hyphen:
            content = content.replace(b'an illustration', b'inter\\022national illustration')
    rgb = bytes([20, 80, 180]) * (20 * 20)
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> /XObject << /Im 6 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' + content + b'endstream',
               b'<< /Type /XObject /Subtype /Image /Width 20 /Height 20 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ' + str(len(zlib.compress(rgb))).encode() + b' >>\nstream\n' + zlib.compress(rgb) + b'\nendstream']
    if not 1 <= pages <= 132: raise ValueError('Fixture page count')
    for index in range(pages - 1):
        page = objects[2]
        if tiled_scan and index % 2 == 0:
            page = page.replace(b'/MediaBox [0 0 300 300]', b'/MediaBox [0 0 300 400]')
        objects.append(page)
    kids = [3] + list(range(7, len(objects) + 1))
    if image_only_last:
        assert pages >= 2
        objects[kids[-1] - 1] = objects[2].replace(
            b'/Contents 5 0 R', f'/Contents {len(objects) + 1} 0 R'.encode())
        raster_only = content.splitlines(keepends=True)[0]
        objects.append(b'<< /Length ' + str(len(raster_only)).encode() + b' >>\nstream\n' +
                       raster_only + b'endstream')
    objects[1] = b'<< /Type /Pages /Kids [' + b' '.join(str(i).encode() + b' 0 R' for i in kids) + b'] /Count ' + str(pages).encode() + b' >>'
    if font_hyphen or ligature_page is not None:
        cmap = (b'/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n'
                b'/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n'
                b'/CMapName /Fixture def\n/CMapType 2 def\n'
                b'1 begincodespacerange\n<00> <FF>\nendcodespacerange\n'
                b'1 beginbfrange\n<20> <7E> <0020>\nendbfrange\n'
                b'endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n')
        cmap_ref = len(objects) + 1
        objects.append(f'<< /Length {len(cmap)} >>\nstream\n'.encode() + cmap + b'endstream')
        font = (b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
                b'/Encoding << /BaseEncoding /WinAnsiEncoding /Differences [18 /hyphenminus] >> '
                + f'/ToUnicode {cmap_ref} 0 R >>'.encode())
        if font_hyphen:
            objects[3] = font
        else:
            font_ref, content_ref = len(objects) + 1, len(objects) + 2
            objects[kids[ligature_page] - 1] = objects[2].replace(
                b'/F1 4 0 R', f'/F1 {font_ref} 0 R'.encode()).replace(
                b'/Contents 5 0 R', f'/Contents {content_ref} 0 R'.encode())
            objects.append(font.replace(b'18 /hyphenminus', b'3 /f_l'))
            ligature = content.replace(b'an illustration', b'a re\\003ection')
            objects.append(f'<< /Length {len(ligature)} >>\nstream\n'.encode() + ligature + b'endstream')
    if outline:
        assert pages == 3
        parent = len(objects) + 1
        chapter, child, appendix = parent + 1, parent + 2, parent + 3
        appendix_page = 'null' if broken_destination else f'{kids[2]} 0 R'
        objects[0] = f'<< /Type /Catalog /Pages 2 0 R /Outlines {parent} 0 R >>'.encode()
        ambiguous, appendix_structure, mixed_structure = appendix + 1, appendix + 2, appendix + 3
        last = ambiguous if structure_destination else appendix
        count = 4 if structure_destination else 3
        appendix_action = f'/A << /S /GoTo /D [{appendix_page} /Fit] >>'
        if structure_destination:
            appendix_action = (f'/Next {ambiguous} 0 R /SE {appendix_structure} 0 R '
                               '/A << /S /GoTo /D [null /FitH 240] >>')
        objects.extend(value.encode() for value in (
            f'<< /Type /Outlines /First {chapter} 0 R /Last {last} 0 R /Count {count} >>',
            f'<< /Title (Chapter) /Parent {parent} 0 R /First {child} 0 R /Last {child} 0 R '
            f'/Next {appendix} 0 R /Count 1 /Dest [{kids[0]} 0 R /Fit] >>',
            f'<< /Title (Subchapter) /Parent {chapter} 0 R /Dest [{kids[1]} 0 R /Fit] >>',
            f'<< /Title (Appendix) /Parent {parent} 0 R /Prev {chapter} 0 R {appendix_action} >>',
        ))
        if structure_destination:
            objects.extend(value.encode() for value in (
                f'<< /Title (Ambiguous) /Parent {parent} 0 R /Prev {appendix} 0 R '
                f'/SE {mixed_structure} 0 R /Dest [null /Fit] >>',
                f'<< /Type /StructElem /S /P /Pg {kids[2]} 0 R /K [0 << /Type /MCR /MCID 1 >>] >>',
                f'<< /Type /StructElem /S /Sect /Pg {kids[0]} 0 R '
                f'/K [0 << /Type /MCR /Pg {kids[1]} 0 R /MCID 0 >>] >>',
            ))
    result = bytearray(b'%PDF-1.4\n'); offsets = [0]
    for i, obj in enumerate(objects, 1): offsets.append(len(result)); result.extend(str(i).encode() + b' 0 obj\n' + obj + b'\nendobj\n')
    size = len(objects) + 1
    xref = len(result); result.extend(f'xref\n0 {size}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]: result.extend(f'{offset:010} 00000 n \n'.encode())
    result.extend(f'trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF'.encode()); return bytes(result)


def write_large_pdf_fixture(source):
    body, footer = pdf_fixture(pages=2).rsplit(b'startxref', 1)
    with source.open('wb') as stream:
        stream.write(body)
        stream.seek(68 * 1024 * 1024)
        stream.write(b'\nstartxref' + footer)


def pdb_fixture(text, compressed=False, kind=b'TEXtREAd'):
    record = b'\x00\x02\x00\x00' if compressed else b'\x00\x01\x00\x00'
    record += struct.pack('>IHHI', len(text), 1, 4096, 0)
    header = bytearray(78); header[:5] = b'Book\0'; header[60:68] = kind; header[76:78] = b'\0\2'
    return bytes(header) + struct.pack('>II', 94, 0) + struct.pack('>II', 110, 1) + record + text


class LegacyFixed(unittest.TestCase):
    def setUp(self): self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()

    def test_pdf_cmap_keeps_already_mapped_characters(self):
        repair = module('pdf_font_encoding')
        cmap = (b'1 begincodespacerange\n<00> <FF>\nendcodespacerange\n'
                b'1 beginbfchar\n<04> <2013>\nendbfchar\n'
                b'1 beginbfrange\n<05> <06> [<2014> <2212>]\nendbfrange\nendcmap')
        result = repair.repair_cmap(cmap, dict.fromkeys((4, 5, 6, 18), '-'))
        self.assertEqual(result, cmap.replace(b'endcmap', b'1 beginbfchar\n<12> <002D>\nendbfchar\nendcmap'))
        self.assertIsNone(repair.repair_cmap(cmap, dict.fromkeys((4, 5, 6), '-')))
        self.assertIsNone(repair.repair_cmap(b'/Inherited usecmap\n' + cmap, {18: '-'}))

    def test_distiller_mstt_encoding_requires_matching_cff_slots_and_charset(self):
        repair = module('pdf_font_encoding')
        slots = {32: 'G20', 65: 'G41', 0xC0: 'GC0', 0xDF: 'GDF'}
        glyphs = {1: '/GC0', 2: '/GDF', 3: '/G46._', 4: '/G42', 5: '/GCF.alt', 6: '/G20'}
        charset = set(slots.values()) | {'G46._', 'G42', 'GCF.alt'}
        self.assertEqual(repair.mstt_mappings(glyphs, slots, charset), {1: 'А', 2: 'Я', 3: 'F', 6: ' '})
        self.assertEqual(repair.mstt_mappings(glyphs, {**slots, 65: 'G42'}, charset), {})
        self.assertEqual(repair.mstt_mappings(glyphs, slots, charset - {'G46._'}), {1: 'А', 2: 'Я', 6: ' '})

    def test_pdf_restores_cyrillic_from_verified_cff_slots(self):
        repair = module('pdf_font_encoding')

        def cff_index(values):
            offsets = [1]
            for value in values:
                offsets.append(offsets[-1] + len(value))
            return struct.pack('>HB', len(values), 2) + struct.pack('>' + 'H' * len(offsets), *offsets) + b''.join(values)

        slots = sorted(repair.PETERBURG_SLOTS.items())
        prefix = b'\x01\x00\x04\x01' + cff_index([b'Fixture'])
        strings = cff_index([glyph.encode('ascii') for _, glyph in slots])
        sids = b'\x01' + struct.pack('>HB', 391, len(slots) - 1)
        byte_codes = bytes([0x81, len(slots)]) + b''.join(bytes([code, 0]) for code, _ in slots)
        byte_codes += b'\x01\xa0' + struct.pack('>H', 391)  # The first glyph has two encodings.
        start = len(prefix) + len(cff_index([b'x' * 18])) + len(strings) + 2
        offsets = (start, start + len(sids), start + len(sids) + len(byte_codes))
        top = b''.join(b'\x1d' + struct.pack('>I', offset) + bytes([operator])
                       for operator, offset in zip((15, 16, 17), offsets))
        cff = (prefix + cff_index([top]) + strings + b'\x00\x00' + sids + byte_codes +
               cff_index([b'\x0e'] * (len(slots) + 1)))
        self.assertEqual(repair.cff_legacy_slots(cff)[0xe3], '.notdef.g0104')
        self.assertEqual(repair.cff_legacy_slots(cff[:-6]), {})

        class Stream(dict):
            def __init__(self, data=b'', **kwargs):
                super().__init__(kwargs)
                self.data = data

            def get_object(self): return self
            def get_data(self): return self.data

        font = {'/BaseFont': '/ABCDEF+Peterburg-Bold',
                '/FontDescriptor': Stream(**{'/FontFile3': Stream(cff, **{'/Subtype': '/Type1C'})})}
        cmap = Stream(b'1 begincodespacerange <00> <FF> endcodespacerange\n'
                      b'1 beginbfchar <06> <0061> endbfchar\n'
                      b'2 beginbfrange <10> <11> <0030> <20> <21> [<0041> <00420043>] endbfrange\nendcmap')
        differences = [(5, '/grave.g006B'), (6, '/a.g0072'), (7, '/.notdef.g0104')]
        corrected = repair.restore_peterburg(font, differences, cmap)
        self.assertIn(b'<06> <0411>\n<07> <0433>', corrected)
        self.assertIn(b'<10> <0030>\n<11> <0031>', corrected)
        self.assertIn(b'<21> <00420043>', corrected)
        self.assertNotIn(b'<05>', corrected)
        font['/BaseFont'] = '/ABCDEF+OtherFont'
        self.assertIsNone(repair.restore_peterburg(font, differences, cmap))

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_pdf_repairs_explicit_type1_hyphen_in_an_incremental_copy(self):
        source = self.root/'font-hyphen.pdf'
        destination = self.root/'font-hyphen-corrected.pdf'
        original = pdf_fixture(font_hyphen=True)
        source.write_bytes(original)
        repair = module('pdf_font_encoding')
        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            with api.open_document(source, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [0]), [1])
                with patch.object(repair, 'WHEEL', TOOLS/'bookconvert/pdf-runtime/pypdf.whl'):
                    self.assertTrue(repair.prepare(source, destination, api, doc))
            with api.open_document(destination, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [0]), [0])
                page = api.FPDF_LoadPage(doc, 0)
                try:
                    lines = api.page_lines(page, 300, 300)
                    self.assertTrue(any('inter-national' in line['text'] for line in lines))
                finally:
                    api.FPDF_ClosePage(page)
        finally:
            api.FPDF_DestroyLibrary()
        self.assertEqual(source.read_bytes(), original)
        self.assertTrue(destination.read_bytes().startswith(original))

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_pdf_restores_only_unambiguous_structure_destination(self):
        repair = module('pdf_font_encoding')
        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            for font_hyphen in (False, True):
                with self.subTest(font_hyphen=font_hyphen):
                    source = self.root/f'structured-{font_hyphen}.pdf'
                    destination = self.root/f'structured-{font_hyphen}-corrected.pdf'
                    original = pdf_fixture(pages=3, outline=True, structure_destination=True, font_hyphen=font_hyphen)
                    source.write_bytes(original)
                    existing = [(1, 'Chapter', 1), (2, 'Subchapter', 2)]
                    warnings = set()
                    with api.open_document(source, self.fail) as doc:
                        self.assertEqual(api.page_outline(doc, 3, set()), existing)
                        wheel = TOOLS/'bookconvert/pdf-runtime/pypdf.whl'
                        with patch.object(repair, 'WHEEL', wheel):
                            self.assertTrue(repair.prepare(source, destination, api, doc, warnings))
                    self.assertTrue(any('Пунктов: 1' in warning for warning in warnings))
                    with api.open_document(destination, self.fail) as doc:
                        unresolved = set()
                        self.assertEqual(api.FPDF_GetPageCount(doc), 3)
                        self.assertEqual(api.page_outline(doc, 3, unresolved), existing + [(3, 'Appendix', 1)])
                        self.assertTrue(any('Ambiguous' in warning for warning in unresolved), unresolved)
                        self.assertEqual(repair.sample_invalid_codes(api, doc, [0, 1, 2]), [0, 0, 0])
                    self.assertEqual(source.read_bytes(), original)
                    corrected = destination.read_bytes()
                    self.assertTrue(corrected.startswith(original))
                    self.assertRegex(corrected[len(original):], rb'/D \[ 8 0 R /FitH 240 \]')
        finally:
            api.FPDF_DestroyLibrary()

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_pdf_repairs_type1_ligature_on_an_unsampled_page(self):
        source = self.root/'ligature.pdf'
        destination = self.root/'ligature-corrected.pdf'
        index, pages = 5, 24
        original = pdf_fixture(pages=pages, ligature_page=index)
        source.write_bytes(original)
        repair = module('pdf_font_encoding')
        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()

        def read_page(document):
            page = api.FPDF_LoadPage(document, index)
            try:
                lines, rgb, *_ = api.page(page, self.fail)
                return ' '.join(line['text'] for line in lines), rgb
            finally:
                api.FPDF_ClosePage(page)

        try:
            with api.open_document(source, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [index]), [1])
                self.assertFalse(any(repair.sample_invalid_codes(api, doc, [0, 1, 2, 3, *range(4, 24, 2)])))
                before, original_pixels = read_page(doc)
                self.assertNotIn('reflection', before)
                with patch.object(repair, 'WHEEL', TOOLS/'bookconvert/pdf-runtime/pypdf.whl'):
                    self.assertTrue(repair.prepare(source, destination, api, doc))
            with api.open_document(destination, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [index]), [0])
                after, corrected_pixels = read_page(doc)
                self.assertIn('reflection', after)
                self.assertEqual(corrected_pixels, original_pixels)
        finally:
            api.FPDF_DestroyLibrary()
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_unconfirmed_distiller_locale_does_not_suppress_verified_hyphen_repair(self):
        source = self.root/'latin-text.pdf'
        destination = self.root/'latin-with-hyphen.pdf'
        original = pdf_fixture(font_hyphen=True)
        source.write_bytes(original)
        repair = module('pdf_font_encoding')
        real_repair = repair.repair_fonts
        attempts = []
        warnings = set()

        def competing_mapping(writer, notices, tools, consider_distiller):
            attempts.append(consider_distiller)
            if consider_distiller:
                notices.add(repair.MSTT_REPAIR_NOTICE)
            return real_repair(writer, notices, tools)

        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            with api.open_document(source, self.fail) as doc:
                with patch.object(repair, 'WHEEL', TOOLS/'bookconvert/pdf-runtime/pypdf.whl'), \
                        patch.object(repair, 'font_repair_pages', return_value=([], [0])), \
                        patch.object(repair, 'repair_fonts', side_effect=competing_mapping):
                    self.assertTrue(repair.prepare(source, destination, api, doc, warnings))
            with api.open_document(destination, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [0]), [0])
        finally:
            api.FPDF_DestroyLibrary()
        self.assertEqual(attempts, [True, False])
        self.assertNotIn(repair.MSTT_REPAIR_NOTICE, warnings)
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_encrypted_pdf_is_not_cloned_by_optional_font_repair(self):
        wheel = TOOLS/'bookconvert/pdf-runtime/pypdf.whl'
        sys.path.insert(0, str(wheel))
        try:
            from pypdf import PdfWriter
            from pypdf.errors import DependencyError
        finally:
            sys.path.pop(0)
        source = self.root/'encrypted.pdf'
        destination = self.root/'repaired.pdf'
        writer = PdfWriter(BytesIO(pdf_fixture(font_hyphen=True)))
        writer.encrypt('', 'fixture owner', algorithm='RC4-128')
        writer.write(source)
        original = source.read_bytes()
        repair = module('pdf_font_encoding')
        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            with api.open_document(source, self.fail) as doc:
                self.assertEqual(repair.sample_invalid_codes(api, doc, [0]), [1])
                with patch.object(repair, 'WHEEL', wheel), patch('pypdf.PdfWriter') as clone:
                    self.assertFalse(repair.prepare(source, destination, api, doc))
                    clone.assert_not_called()
                with patch.object(repair, 'WHEEL', wheel), patch('pypdf.PdfReader', side_effect=DependencyError):
                    self.assertFalse(repair.prepare(source, destination, api, doc))
        finally:
            api.FPDF_DestroyLibrary()
        self.assertFalse(destination.exists())
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file() and
                         (TOOLS/'bookconvert/pdf-runtime/pypdf.whl').is_file(), 'PDF repair runtime')
    def test_pdf_repairs_identity_truetype_without_replacing_the_original_pages(self):
        repair = module('pdf_font_encoding')
        identity = module('pdf_truetype_mapping')
        self.assertEqual(identity.unique_unicode({0x003b, 0x037e}), 0x003b)
        self.assertIsNone(identity.unique_unicode({0x0041, 0x0410}))
        reference = Path(os.environ['SystemRoot'])/'Fonts/times.ttf'
        if not reference.is_file():
            self.skipTest('Times New Roman reference')
        wheel = TOOLS/'bookconvert/pdf-runtime/pypdf.whl'
        sys.path.insert(0, str(wheel))
        try:
            from pypdf import PdfWriter
            from pypdf.generic import ArrayObject, DecodedStreamObject, DictionaryObject, NameObject, NumberObject
        finally:
            sys.path.pop(0)

        original_font = reference.read_bytes()
        glyphs = {code: gid for gid, codes in identity.TrueType(original_font).unicode_map().items()
                  for code in codes}
        message = 'История развития химии'
        content = ''.join(f'{glyphs[ord(char)]:04x}' for char in message)
        count = struct.unpack_from('>H', original_font, 4)[0]
        records = [original_font[pos:pos + 16] for pos in range(12, 12 + count * 16, 16)
                   if original_font[pos:pos + 4] not in (b'cmap', b'post')]
        power = 1 << (len(records).bit_length() - 1)
        header = struct.pack('>4sHHHH', original_font[:4], len(records), 16 * power,
                             power.bit_length() - 1, 16 * (len(records) - power))
        subset = header + b''.join(records) + original_font[12 + 16 * len(records):]
        self.assertNotIn(b'cmap', identity.TrueType(subset).tables)

        def dictionary(**entries):
            return DictionaryObject({NameObject('/' + key): value for key, value in entries.items()})

        def stream(data):
            result = DecodedStreamObject()
            result.set_data(data)
            return result

        writer = PdfWriter()
        page = writer.add_blank_page(300, 300)
        name = NameObject('/ABCDEF+TimesNewRomanPSMT')
        embedded = stream(subset)
        embedded[NameObject('/Length1')] = NumberObject(len(subset))
        descriptor = dictionary(Type=NameObject('/FontDescriptor'), FontName=name,
                                FontFile2=writer._add_object(embedded))
        descendant = dictionary(Type=NameObject('/Font'), Subtype=NameObject('/CIDFontType2'),
                                BaseFont=name, FontDescriptor=writer._add_object(descriptor),
                                CIDToGIDMap=NameObject('/Identity'))
        font = dictionary(Type=NameObject('/Font'), Subtype=NameObject('/Type0'),
                          BaseFont=NameObject('/UVWXYZ+TimesNewRomanPSMT'),
                          Encoding=NameObject('/Identity-H'),
                          DescendantFonts=ArrayObject([writer._add_object(descendant)]))
        page[NameObject('/Resources')] = dictionary(Font=dictionary(F1=writer._add_object(font)))
        page[NameObject('/Contents')] = writer._add_object(stream(f'BT /F1 12 Tf 10 250 Td <{content}> Tj ET'.encode()))
        source = self.root/'identity.pdf'
        writer.write(source)
        original = source.read_bytes()

        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            def read_page(document):
                handle = api.FPDF_LoadPage(document, 0)
                try:
                    lines, pixels, *_ = api.page(handle, self.fail)
                    return ' '.join(row['text'] for row in lines), pixels
                finally:
                    api.FPDF_ClosePage(handle)

            for in_memory_limit in (0, repair.IN_MEMORY_PDF_SIZE):
                with self.subTest(in_memory_limit=in_memory_limit):
                    prepared = self.root/f'identity-repaired-{in_memory_limit}.pdf'
                    with api.open_document(source, self.fail) as document:
                        before, expected_pixels = read_page(document)
                        with patch.object(repair, 'WHEEL', wheel), patch.object(repair, 'IN_MEMORY_PDF_SIZE', in_memory_limit):
                            self.assertTrue(repair.prepare(source, prepared, api, document))
                    with api.open_document(prepared, self.fail) as document:
                        after, pixels = read_page(document)
                    self.assertNotIn(message, before)
                    self.assertIn(message, after)
                    self.assertEqual(pixels, expected_pixels)
                    self.assertTrue(prepared.read_bytes().startswith(original))
        finally:
            api.FPDF_DestroyLibrary()
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name=='nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'Windows PDFium')
    def test_scan_selector_samples_tiled_pages_with_different_sizes(self):
        api = fixed.PDF(TOOLS, self.fail)
        api.FPDF_InitLibrary()
        try:
            for with_text, pages, parts in [(False, 24, 2), (False, 132, 4), (True, 24, 0)]:
                path = self.root / f'tiled-{with_text}-{pages}.pdf'
                path.write_bytes(pdf_fixture(text=with_text, pages=pages, tiled_scan=True))
                with api.open_document(path, self.fail) as document:
                    groups = api.scan_sample_groups(lambda index: api.FPDF_LoadPage(document, index), pages, None)
                self.assertEqual(len(groups), parts)
                for index, (number, weight) in enumerate(groups):
                    self.assertEqual(weight, pages//parts)
                    self.assertIn(number, range(index*weight+1, (index+1)*weight+1))
        finally:
            api.FPDF_DestroyLibrary()

    @unittest.skipUnless(os.name=='nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'Windows PDFium')
    def test_pdf_document_batches_preserve_page_order_text_and_images(self):
        source = self.root / 'batched.pdf'
        source.write_bytes(pdf_fixture(pages=5, image_only_last=True))
        expected = text_inputs.Book(c, source, set(), tools_root=TOOLS)
        fixed.read_pdf(expected, TOOLS)
        actual = text_inputs.Book(c, source, set(), tools_root=TOOLS)
        documents = []
        open_document = fixed.PDF.open_document

        def track_open(api, path, fail):
            documents.append(path)
            return open_document(api, path, fail)

        with patch.object(fixed, 'PDF_PAGES_PER_DOCUMENT', 2), patch.object(fixed.PDF, 'open_document', track_open):
            fixed.read_pdf(actual, TOOLS)
        self.assertEqual(documents, [source] * 3)
        self.assertEqual([node.get('id') for node in actual.body], [f'page-{i}' for i in range(1, 6)])
        self.assertEqual(ET.tostring(actual.body), ET.tostring(expected.body))
        self.assertEqual(actual.resources, expected.resources)
        self.assertTrue(actual.resources)

    def convert(self, extension, data, target='.epub'):
        source = self.root / ('source' + extension); source.write_bytes(data); before = hashlib.sha256(data).hexdigest()
        output = self.root / ('output' + target)
        report = c.convert_book(source, output, tools_root=TOOLS)
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)
        if target == '.epub':
            with zipfile.ZipFile(output) as z:
                self.assertIsNone(z.testzip()); body = ET.fromstring(z.read('OEBPS/book.xhtml'))
                images = [n for n in z.namelist() if '/images/' in n]
        else: body = ET.parse(output).getroot(); images = [n for n in body if c.tag(n) == 'binary']
        return report, ''.join(body.itertext()), images
    def test_palmdoc_plain_and_bad_record_bounds(self):
        _, text, _ = self.convert('.pdb', pdb_fixture('Привет, мир. Конец книги.'.encode('cp1251')), '.fb2')
        self.assertIn('Привет, мир. Конец книги.', text)
        bad = bytearray(pdb_fixture(b'hello')); bad[78:82] = b'\xff' * 4
        source = self.root / 'bad.pdb'; source.write_bytes(bad)
        with self.assertRaises(c.ConversionError): c.convert_book(source, self.root / 'bad.epub')
        self.assertFalse((self.root / 'bad.epub').exists())
    def test_palmdoc_backreferences_overlap_and_bounds(self):
        self.assertEqual(legacy.palmdoc(b'abc\x80\x1b', self.fail), b'abcabcabc')
        self.assertEqual(legacy.palmdoc(b'\xe1', self.fail), b' a')
        with self.assertRaises(AssertionError): legacy.palmdoc(b'\x80\0', self.fail)
    def test_ztxt_bounded_stream_and_corruption(self):
        text = 'Текст zTXT. Конец книги.'.encode('cp1251')
        header = struct.pack('>HHI', 0x012c, 1, len(text)) + b'\0' * 8
        pdb = bytearray(pdb_fixture(b'ignored', kind=b'zTXTGPlm'))
        payload = bytes(pdb[:94]) + header + zlib.compress(text)
        _, body, _ = self.convert('.pdb', payload, '.fb2')
        self.assertIn('Текст zTXT. Конец книги.', body)
        bad = self.root / 'broken.pdb'; bad.write_bytes(bytes(pdb[:94]) + header + b'not zlib')
        with self.assertRaisesRegex(c.ConversionError, 'zTXT'): c.convert_book(bad, self.root / 'bad.fb2')
        self.assertFalse((self.root / 'bad.fb2').exists())

    def test_mhtml_legacy_nested_layout_has_valid_blocks(self):
        msg = EmailMessage(); msg.set_content('<html><body><p><b>Before<table><tr><td><table><tr><td>Inside</table></table>After</b><ul><li>Final<li>Last</ul>', subtype='html', charset='utf-8')
        report, text, _ = self.convert('.mht', msg.as_bytes(), '.fb2')
        self.assertTrue(all(word in text for word in ['Before','Inside','After','Final','Last']))
        self.assertTrue(any(w.startswith('Внешняя таблица из одной ячейки заменена разделом FB2')
                            for w in c.damaged_content_warnings(report['warnings'])))
        root = ET.parse(self.root/'output.fb2').getroot()
        self.assertEqual([c.plain(node) for node in root.iter() if c.tag(node) == 'td'], ['Inside'])
        self.assertFalse(any(c.tag(n) in {'p','div','table'} for p in root.iter() if c.tag(p) == 'p' for n in p))

    def test_mhtml_uses_the_mime_root_and_keeps_its_table_and_local_links(self):
        message = EmailMessage()
        message.set_type('multipart/related')
        message.set_param('start', '<root>')
        alternate = EmailMessage()
        alternate.set_content('<p>Wrong MIME part</p>', subtype='html')
        alternate['Content-ID'] = '<first>'
        message.attach(alternate)
        root = EmailMessage()
        root.set_content('''<h1>Archived chapter</h1><p><a href="https://example.invalid/book.mht#item">Local section</a>
          <a href="https://other.example.invalid/book.mht#item">External page</a></p>
          <table><tr><th id="item">Target cell</th><td>Other cell</td></tr></table>''', subtype='html')
        root['Content-ID'] = '<root>'
        root['Content-Location'] = 'https://example.invalid/book.mht'
        message.attach(root)
        source = self.root / 'selected.mht'
        source.write_bytes(message.as_bytes())
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        for output in (epub, fb2):
            c.convert_book(source, output)
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
        converted = c.xml(fb2.read_bytes())
        c.validate_fb2_output(converted)
        for document, href in ((chapter, 'href'), (converted, '{' + c.XL + '}href')):
            body = c.first(document, 'body')
            self.assertNotIn('Wrong MIME part', c.plain(body))
            targets = {node.get('id'): node for node in body.iter() if node.get('id')}
            links = {c.plain(node): node.get(href) for node in body.iter() if c.tag(node) == 'a'}
            self.assertEqual(c.plain(targets[links['Local section'].removeprefix('#')]), 'Target cell')
            self.assertEqual(links['External page'], 'https://other.example.invalid/book.mht#item')
            self.assertEqual([c.plain(node) for node in body.iter() if c.tag(node) in {'th', 'td'}],
                             ['Target cell', 'Other cell'])

    def test_mhtml_plain_root_preserves_literal_text(self):
        message = EmailMessage()
        message.set_content('Строка <table>\nВторая строка %PDF-1.4', charset='utf-8', cte='8bit')
        _, text, images = self.convert('.mht', message.as_bytes())
        with zipfile.ZipFile(self.root / 'output.epub') as archive:
            body = c.first(c.xml(archive.read('OEBPS/book.xhtml')), 'body')
        self.assertIn('Строка <table>\nВторая строка %PDF-1.4', c.first(body, 'pre').text)
        self.assertNotIn('MIME-Version', text)
        self.assertFalse(images)

    def test_pdb_other_container_not_misidentified(self):
        source = self.root / 'isilo.pdb'; source.write_bytes(pdb_fixture(b'private data', kind=b'SDocSilX'))
        with self.assertRaisesRegex(c.ConversionError, 'iSilo 3'): c.convert_book(source, self.root / 'unsupported.fb2')
        self.assertFalse((self.root / 'unsupported.fb2').exists())
    def test_tcr_dictionary_and_renamed_signature(self):
        text = 'Первая строка.\nПоследняя строка.'.encode('cp1251')
        dictionary = b''.join(bytes([1, i]) for i in range(256))
        _, body, _ = self.convert('.123456', b'!!8-Bit!!' + dictionary + text)
        self.assertIn('Первая строка.', body); self.assertIn('Последняя строка.', body)
    def test_wri_plain_and_objects_rejected(self):
        text = 'Книга Write. Конец.'.encode('cp1251'); header = bytearray(128); header[:2] = b'1\xbe'; header[14:18] = struct.pack('<I', 128 + len(text))
        _, body, _ = self.convert('.wri', bytes(header) + text); self.assertIn('Книга Write.', body)
        source = self.root / 'object.wri'; header[14:18] = struct.pack('<I', 130); source.write_bytes(header + b'\x16\x01')
        with self.assertRaisesRegex(c.ConversionError, 'объекты'): c.convert_book(source, self.root / 'object.epub')
    def test_mhtml_cid_image_uses_no_external_fetch(self):
        png = fixed.png(b'\x30\x60\x90' * 4, 2, 2)
        msg = EmailMessage(); msg.set_type('multipart/related'); html = EmailMessage()
        html.set_content('<html><body><h1>Глава</h1><p>Начало.</p><img src="cid:picture"/><p>Конец.</p></body></html>', subtype='html', charset='utf-8'); msg.attach(html)
        image = EmailMessage(); image.set_content(png, maintype='image', subtype='png'); image['Content-ID'] = '<picture>'; msg.attach(image)
        _, body, images = self.convert('.mhtml', msg.as_bytes()); self.assertIn('Конец.', body); self.assertEqual(len(images), 1)
    def test_mhtml_preserves_percent_encoded_attachment_location(self):
        location = 'file:///C:/Pictures/My%20cover.png'
        message = EmailMessage()
        message.set_type('multipart/related')
        html = EmailMessage()
        html.set_content(f'<html><body><p>Text before and after the image.</p><img src="{location}"/>'
                         '<img src="" width="12" height="54" alt="Image description"/></body></html>', subtype='html')
        message.attach(html)
        picture = EmailMessage()
        picture.set_content(fixed.png(b'\x30\x60\x90' * 4, 2, 2), maintype='image', subtype='png')
        picture['Content-Location'] = location
        message.attach(picture)
        _, body, images = self.convert('.mhtml', message.as_bytes())
        self.assertIn('Text before and after the image.', body)
        self.assertIn('Image description', body)
        self.assertEqual(len(images), 1)

    def test_mhtml_keeps_attached_pixel_with_absolute_url(self):
        location = 'https://example.invalid/book/space.png'
        pixels = fixed.png(b'\x30\x60\x90', 1, 1)
        message = EmailMessage()
        message.set_type('multipart/related')
        page = EmailMessage()
        page.set_content('<script>script-secret</script>'
                         f'<p>Page <noscript><img src="{location}" width="1" height="1"/></noscript>'
                         f'<img src="{location}" width="300" height="1"/>'
                         '<img src="https://example.invalid/remote.png" width="1" height="1"/></p>',
                         subtype='html')
        message.attach(page)
        picture = EmailMessage()
        picture.set_content(pixels, maintype='application', subtype='octet-stream')
        picture['Content-Location'] = location
        message.attach(picture)
        source = self.root / 'local-pixel.mht'
        source.write_bytes(message.as_bytes())
        output = self.root / 'local-pixel.epub'
        report = c.convert_book(source, output)
        with zipfile.ZipFile(output) as archive:
            body = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertNotIn('script-secret', c.plain(body))
            pictures = list(body.iter('{' + c.XH + '}img'))
            self.assertEqual([(item.get('width'), item.get('height')) for item in pictures], [('1', '1'), ('300', '1')])
            self.assertTrue(all(archive.read('OEBPS/' + item.get('src')) == pixels for item in pictures))
        self.assertIn('Внешнее изображение размером 1 × 1 пропущено.', report['warnings'])

    def test_mhtml_missing_image_marks_its_place_and_keeps_text(self):
        msg = EmailMessage(); msg.set_content('<html><body><p>Before</p><img src="https://invalid.example/image.jpg"/><p>After</p></body></html>', subtype='html', charset='utf-8')
        source = self.root / 'missing.mht'; source.write_bytes(msg.as_bytes())
        output = self.root / 'missing.fb2'
        result = c.convert_book(source, output)
        body = ''.join(c.first(c.xml(output.read_bytes()), 'body').itertext())
        self.assertLess(body.index('Before'), body.index('[Изображение 1 недоступно.]'))
        self.assertLess(body.index('[Изображение 1 недоступно.]'), body.index('After'))
        self.assertIn('Изображение 1 недоступно. Файл «image.jpg».', c.damaged_content_warnings(result['warnings']))
    def test_djvu_quoted_utf8_octal_and_ppm_bounds(self):
        quoted = '(line 0 0 10 10 "\\320\\237\\321\\200\\320\\270\\320\\262\\320\\265\\321\\202")'
        self.assertEqual(fixed.sexpressions(quoted, self.fail)[0][-1], 'Привет')
        self.assertEqual(fixed.sexpressions('(line 0 0 1 1 "Привет")', self.fail)[0][-1], 'Привет')
        pixels = bytes([32,10,13,0,255,1])
        self.assertEqual(fixed.ppm(b'P6\n# comment\n2 1\n255\n'+pixels, self.fail), (pixels,2,1))
        with self.assertRaises(AssertionError): fixed.ppm(b'P6\n2 1\n255\n'+pixels[:-1], self.fail)

    def test_grayscale_scan_png_preserves_every_pixel(self):
        expected = [bytes(range(256)), bytes(reversed(range(256))), bytes([127, 128]) * 128]
        rgb = b''.join(bytes([v]) * 3 for row in expected for v in row)
        image = fixed.png(rgb, 256, len(expected))
        self.assertEqual(struct.unpack_from('>IIBBBBB', image, 16), (256, 3, 8, 0, 0, 0, 0))
        size = struct.unpack_from('>I', image, 33)[0]
        self.assertEqual(image[37:41], b'IDAT')
        rows = zlib.decompress(image[41:41 + size])
        previous = bytes(256)
        for i, reference in enumerate(expected):
            start = i * 257
            self.assertEqual(rows[start], 2)
            previous = bytes((a + b) % 256 for a, b in zip(rows[start + 1:start + 257], previous))
            self.assertEqual(previous, reference)

    def test_large_color_scan_uses_the_smaller_lossless_png_filter(self):
        width, height = 512, 192
        stride = width * 3
        first = hashlib.shake_256(b'fixed color scan').digest(stride)
        samples = [bytes((value + number) % 256 for value in first) for number in range(height)]
        raw = b''.join(b'\0' + row for row in samples)
        image = fixed.png(b''.join(samples), width, height)
        self.assertEqual(struct.unpack_from('>IIBBBBB', image, 16), (width, height, 8, 2, 0, 0, 0))
        size = struct.unpack_from('>I', image, 33)[0]
        self.assertLess(size, len(zlib.compress(raw)))
        self.assertEqual(image[37:41], b'IDAT')
        rows = zlib.decompress(image[41:41 + size])
        previous = bytes(stride)
        for number, reference in enumerate(samples):
            start = number * (stride + 1)
            self.assertEqual(rows[start], 2)
            previous = bytes((a + b) % 256 for a, b in zip(rows[start + 1:start + stride + 1], previous))
            self.assertEqual(previous, reference)

    def test_fb2_chunk_parser_can_validate_without_loading_images(self):
        source = self.root / 'scans.fb2'
        image = 'AQID' * 80_000
        content = (f'<FictionBook xmlns="{c.FB}" xmlns:l="{c.XL}"><body><section><p>Text</p>'
                   '<image l:href="#scan"/></section></body>'
                   f'<binary id="scan" content-type="image/png">{image}</binary></FictionBook>').encode()
        source.write_bytes(content)
        structural = c.parse_fb2_file(source, len(content), keep_binary_data=False)
        c.validate_fb2_output(structural)
        self.assertIsNone(c.first(structural, 'binary').text)
        complete = c.parse_fb2_file(source, len(content), keep_binary_data=True)
        self.assertEqual(c.first(complete, 'binary').text, image)
        with self.assertRaisesRegex(c.ConversionError, 'предел'):
            c.parse_fb2_file(source, len(content) - 1, keep_binary_data=False)
        source.write_bytes(b'<!DOCTYPE FictionBook SYSTEM "missing.dtd">' + content)
        c.validate_fb2_output(c.parse_fb2_file(source, c.MAX_TOTAL, keep_binary_data=False))
        source.write_bytes(b'<!DOCTYPE FictionBook [<!ENTITY ext "payload">]>' + content)
        with self.assertRaisesRegex(c.ConversionError, 'DTD'):
            c.parse_fb2_file(source, c.MAX_TOTAL, keep_binary_data=False)

    def test_multicolumn_order_and_quality(self):
        lines = [{'text': 'Header', 'box': (0, 0, 300, 10)}]
        lines += [{'text': f'{side}{n}', 'box': (x, 40+n*13, x+110, 50+n*13)} for side,x in [('L',0),('R',180)] for n in range(5)]
        self.assertEqual([n['text'] for n in fixed.order_lines(lines)], ['Header'] + [f'L{n}' for n in range(5)] + [f'R{n}' for n in range(5)])
        self.assertTrue(fixed.readable('Обычный распознанный текст.'))
        self.assertFalse(fixed.readable('\ue001\ufffd \ue002\ufffd ????'))

    def test_djvu_batch_frames_use_exact_sizes_and_preserve_header_like_pixels(self):
        # Whitespace and an apparent P6 header inside pixels are image bytes.
        first = b'\n\r P6\n255\n\0\xff'
        second = b'\r\n\0\x11\x22\x33'
        data = b'P6\n# first\n4 1\n255\n' + first + b'P6\r\n2 1\r\n255\r\n' + second
        rgb, width, height, offset = fixed.ppm_page(data, self.fail)
        self.assertEqual((rgb, width, height), (first, 4, 1))
        rgb, width, height, end = fixed.ppm_page(data, self.fail, offset)
        self.assertEqual((rgb, width, height, end), (second, 2, 1, len(data)))
        with self.assertRaises(AssertionError): fixed.ppm(data, self.fail)
        with self.assertRaises(AssertionError): fixed.ppm_page(data[:-1], self.fail, offset)
        with self.assertRaises(AssertionError): fixed.ppm_page(data, self.fail, end)
        wide_pixels = b'\0' * (3200 * 3)
        self.assertEqual(fixed.ppm(b'P6\n3200 1\n255\n' + wide_pixels, self.fail), (wide_pixels, 3200, 1))
        for header in [b'P6\n-1 2\n255\n', b'P6\n3201 1\n255\n', b'P6\n#'+b'x'*1024+b'\n1 1\n255\n']:
            with self.assertRaises(AssertionError): fixed.ppm_page(header+b'\0'*6, self.fail)

    def test_djvu_only_queries_missing_geometry_for_pages_with_text(self):
        source=self.root/'empty-ocr.djvu'; source.write_bytes(b'fixture')
        book=text_inputs.Book(c,source,set(),tools_root=TOOLS)
        # Scans with empty OCR can report zero dimensions. Page 3 has text
        # with coordinates, so only it needs the actual source dimensions.
        calls=[]; raster_calls=[]; malformed=False; retry_raster=False; broken_page=b''; broken_text=b''
        text_calls = []
        timed_out_batch = False
        timed_out_sizes = False
        retry_text=True
        def run(args,stdout,stderr,timeout,creationflags):
            nonlocal retry_text
            script=args[args.index('-e')+1] if '-e' in args else ''
            if script=='n': data=b'5'
            elif script=='print-outline':
                data = b'(bookmarks ("Chapter" "#1" ("Subchapter" "#page%202.djvu")) ("Appendix" "#5"))'
            elif script=='ls': data = b'  1 P  100 page1.djvu\n  2 P  100 page 2.djvu F=book-djvu T=Second page'
            elif 'print-txt' in script:
                numbers=[int(v) for v in re.findall(r'select (\d+)',script)]
                text_calls.append(numbers)
                if retry_text:
                    retry_text=False
                    stdout.write(b'incomplete earlier response')
                    return subprocess.CompletedProcess(args,10,b'',b'DjVuDocEditor.open_fail')
                if timed_out_batch and len(numbers) > 1:
                    stdout.write(b'incomplete timed-out response')
                    raise subprocess.TimeoutExpired(args, timeout)
                if broken_text and 2 in numbers:
                    return subprocess.CompletedProcess(args,10,b'',broken_text)
                pages = {2: '(page 0 0 22 32 "")',
                         3: '(page 0 0 0 0 (line 1 3 12 8 (word 1 3 12 8 "Scan text")))'}
                if timed_out_sizes:
                    pages[4] = '(page 0 0 0 0 (line 2 4 13 9 (word 2 4 13 9 "Next page")))'
                data = '\n'.join(pages.get(n, '(page 0 0 0 0 "")') for n in numbers).encode()
            elif 'size' in script:
                numbers=[int(v) for v in re.findall(r'select (\d+)',script)]
                calls.append(numbers)
                if timed_out_sizes and len(numbers) > 1:
                    stdout.write(b'width=111 height=222')
                    raise subprocess.TimeoutExpired(args, timeout)
                data='\n'.join(f'width={20+n} height={30+n}' for n in (numbers[:-1] if malformed else numbers)).encode()
            else:
                selection = next(arg.removeprefix('-page=') for arg in args if arg.startswith('-page='))
                raster_calls.append(selection)
                if retry_raster and (selection == '1-4' or (broken_page is not None and selection == '3')):
                    return subprocess.CompletedProcess(args,10,b'',broken_page or b'')
                count=4 if selection=='1-4' else 1
                data=(b'P6\n1 1\n255\n'+b'\xff'*3)*count
            stdout.write(data)
            return subprocess.CompletedProcess(args,0,b'',b'')
        emitted, boxes = [], []
        def emit(book,number,lines,rgb,w,h,pw,ph,*,missing_raster=False,**options):
            if missing_raster: fixed.unreadable_page(book,number)
            emitted.append((number,pw,ph));book.fixed_image_pages=number
            boxes.extend(line['box'] for line in lines)
            return 0
        with patch.object(fixed.subprocess,'run',side_effect=run),patch.object(fixed,'emit_page',side_effect=emit):
            fixed.read_djvu(book,TOOLS)
            self.assertFalse(retry_text)
            self.assertEqual(book.page_outline, [(1, 'Chapter', 1), (2, 'Subchapter', 2), (5, 'Appendix', 1)])
            expected = [(1,0,0),(2,22,32),(3,23,33),(4,0,0),(5,0,0)]
            self.assertEqual(emitted, expected)
            self.assertEqual(calls, [[3]])
            self.assertEqual(boxes, [(1,25,12,30)])
            emitted.clear()
            text_calls.clear()
            timed_out_batch = True
            fixed.read_djvu(book,TOOLS)
            self.assertEqual(text_calls, [[1,2,3,4],[1],[2],[3],[4],[5]])
            self.assertEqual(emitted, expected)
            timed_out_batch = False
            emitted.clear()
            calls.clear()
            boxes.clear()
            timed_out_sizes = True
            fixed.read_djvu(book,TOOLS)
            self.assertEqual(calls, [[3,4],[3],[4]])
            self.assertEqual(emitted, [(1,0,0),(2,22,32),(3,23,33),(4,24,34),(5,0,0)])
            self.assertEqual(boxes, [(1,25,12,30),(2,25,13,30)])
            timed_out_sizes = False
            emitted.clear()
            raster_calls.clear()
            retry_raster=True
            broken_page=None
            fixed.read_djvu(book,TOOLS)
            self.assertEqual(raster_calls,['1-4','1','2','3','4','5-5'])
            self.assertEqual([number for number, _, _ in emitted], list(range(1,6)))
            broken_page=b''
            with self.assertRaisesRegex(c.ConversionError,'страница 3.*кодом 10'):
                fixed.read_djvu(book,TOOLS)
            broken_page=b'ddjvu: Cannot decode page 3.'
            emitted.clear()
            fixed.read_djvu(book,TOOLS)
            self.assertEqual([number for number, _, _ in emitted],list(range(1,6)))
            marker=next(node for node in book.body if node.get('id')=='page-3')
            self.assertEqual(''.join(marker.itertext()),'[Страница 3 не читается.]')
            self.assertTrue(any('прочитать страницы 3' in w for w in book.warnings))
            broken_page=None
            for broken_text in (b'DjVuText.corrupt_text',
                                b'*** ** Unrecognized DjVu Message:\r\n\t** Message name:  \x03EOF\r\n*** DataPool.cpp\r\n'):
                emitted.clear()
                book.warnings.clear()
                fixed.read_djvu(book,TOOLS)
                self.assertEqual(emitted,[(1,0,0),(2,0,0),(3,23,33),(4,0,0),(5,0,0)])
                self.assertTrue(any('повреждённым текстовым слоем' in warning and '2 (всего 1)' in warning
                                    for warning in book.warnings))
            broken_text=b''
            malformed=True
            with self.assertRaisesRegex(c.ConversionError,'размеры страниц'):
                fixed.read_djvu(book,TOOLS)

    def test_djvu_error_without_stderr_reports_step_and_exit_code(self):
        tools = self.root / 'tools'
        (tools / 'djvu').mkdir(parents=True)
        (tools / 'djvu/djvused.exe').touch()
        book = text_inputs.Book(c, self.root / 'book.djvu', set(), tools_root=tools, omit_images=True)
        with patch.object(fixed.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, b'', b'')):
            with self.assertRaisesRegex(c.ConversionError, 'сведения о книге.*кодом 2'):
                fixed.read_djvu(book, tools)

    def test_djvu_recovers_windows_1251_character_zones_on_their_original_page(self):
        source = self.root / 'legacy-ocr.djvu'
        book = text_inputs.Book(c, source, set(), tools_root=TOOLS)
        sentence = 'В журнале есть статьи о науке и для читателей это важно. Как это устроено в школе.'
        words = []
        for word in sentence.split():
            characters = []
            for index, code in enumerate(word.encode('cp1251')):
                value = (f'\\{code:03o}'.encode() if index % 2 else bytes([code]))
                characters.append(b'(char 12 31 18 40 "' + value + b'")')
            words.append(b'(word 12 31 35 40 ' + b' '.join(characters) + b')')
        line = b' '.join(words[:3]) + b' (char 12 31 18 40 " ") ' + b' '.join(words[3:])
        legacy_page = (b'(page 12 30 140 70 (region 12 31 140 42 (line 12 31 140 42 ' + line + b'))'
                       b' (region 15 49 130 60 (line 15 49 130 60 "Second region")))')
        modern_page = '(page 0 0 160 100 (line 5 9 82 24 "Русский UTF-8"))'.encode()
        packets = []

        def run(args, stdout, **options):
            script = args[args.index('-e') + 1] if '-e' in args else ''
            outputs = {
                'n': b'2',
                'print-outline': b'',
                'select 1; print-txt; select 2; print-txt': b'\xef\xbb\xbf' + legacy_page + b'\n' + modern_page,
                'select 1; size': b'width=160 height=100',
                '': (b'P6\n1 1\n255\n' + b'\xff' * 3) * 2,
            }
            stdout.write(outputs[script])
            return subprocess.CompletedProcess(args, 0, b'', b'')

        def emit(book, number, lines, rgb, width, height, page_width, page_height, **options):
            packets.append((number, (page_width, page_height), options.get('preserve_line_order', False), lines))
            return 40

        with patch.object(fixed.subprocess, 'run', side_effect=run), patch.object(fixed, 'emit_page', side_effect=emit):
            fixed.read_djvu(book, TOOLS)
        self.assertEqual(packets, [
            (1, (160, 100), True, [{'text': sentence, 'box': (12, 58, 140, 69)},
                                  {'text': 'Second region', 'box': (15, 40, 130, 51)}]),
            (2, (160, 100), False, [{'text': 'Русский UTF-8', 'box': (5, 76, 82, 91)}]),
        ])
        self.assertTrue(any('1 (всего 1) прочитан в Windows-1251' in warning for warning in book.warnings))
        self.assertFalse(c.damaged_content_warnings(book.warnings))
        self.assertEqual(fixed.djvu_text_encoding(sentence.encode('koi8-r')), 'utf-8')

    def test_djvu_text_only_reads_page_level_text_and_missing_pages_without_renderer(self):
        tools = self.root/'tools'
        (tools/'djvu').mkdir(parents=True)
        (tools/'djvu/djvused.exe').touch()
        source = self.root/'book.djvu'
        source.write_bytes(b'fixture')
        book = text_inputs.Book(c, source, set(), tools_root=tools, omit_images=True)

        def run(args, stdout, **options):
            script = args[args.index('-e')+1]
            self.assertTrue(args[0].endswith('djvused.exe'))
            if script == 'n':
                stdout.write(b'3')
            elif 'print-pure-txt' in script:
                self.assertEqual(script, 'select 1; print-pure-txt; select 2; print-pure-txt; select 3; print-pure-txt')
                stdout.write('120\x1f400\f\fСохранённый абзац\f'.encode())
            else:
                self.assertEqual(script, 'select 1; print-txt; select 2; print-txt; select 3; print-txt')
                stdout.write(('(page 0 0 100 100 (para 0 0 20 20 "120") (para 0 25 20 40 "400"))\n'
                              '(page 0 0 100 100)\n(page 0 0 100 100 "Сохранённый абзац")').encode())
            return subprocess.CompletedProcess(args, 0, b'', b'')

        with patch.object(fixed.subprocess, 'run', side_effect=run):
            fixed.read_djvu(book, tools)
        self.assertEqual([''.join(page.itertext()) for page in book.body],
                         ['120400', '[Страница 2 без пригодного текстового слоя]', 'Сохранённый абзац'])
        self.assertFalse(book.resources)
        self.assertTrue(any('Страниц без текста: 1' in warning and 'Выберите FB2 или EPUB' in warning
                            for warning in book.warnings))
        self.assertFalse(any('U+001F' in warning for warning in book.warnings))

    def test_djvu_plain_text_keeps_unknown_codes_inside_words(self):
        words = ['page', 0, 0, 100, 100,
                 ['line', 0, 40, 100, 50, ['word', 0, 40, 15, 50, b'north\x1fwest'],
                  ['word', 20, 40, 50, 50, b'passage']],
                 ['line', 0, 20, 100, 30, b'Next paragraph']]
        text = b'north\x1fwest passage\r\n\x1fNext paragraph'
        lines = fixed.djvu_plain_lines(text, words)
        self.assertEqual([line['text'] for line in lines], [b'north\x1fwest passage', b'Next paragraph'])
        # When the layout is unusable, no ambiguous code may disappear.
        self.assertEqual([line['text'] for line in fixed.djvu_plain_lines(text, None)], text.splitlines())
        book = text_inputs.Book(c, self.root/'hidden-text.djvu', set(), omit_images=True)
        decoded = [{**line, 'text': line['text'].decode()} for line in lines]
        fixed.emit_page(book, 1, decoded, None, 0, 0, 0, 0, preserve_line_order=True)
        self.assertEqual([node.text for node in book.body[0]], ['north[OCR U+001F]west passage', 'Next paragraph'])
        self.assertTrue(any('U+001F' in message for message in c.damaged_content_warnings(book.warnings)))

    def test_djvu_preserves_visible_line_for_unknown_controls(self):
        book = text_inputs.Book(c, self.root/'unknown-control.djvu', set())
        pixels = b'\xff'*150 + b'\x00'*30 + b'\xff'*120
        lines = [{'text': 'This text contains one damaged mark here: north\x1fwest.', 'box': (0, 4, 10, 7)}]
        control_pages = {('[OCR U+001F]',): []}
        with patch.object(fixed, 'illustration_regions', return_value=([], [])):
            fixed.emit_page(book, 3, lines, pixels, 10, 10, 10, 10, source_format='DjVu', djvu_control_pages=control_pages)
        self.assertIn('north[OCR U+001F]west', c.plain(book.body[0]))
        [image] = list(book.body[0].iter(f'{{{c.XH}}}img'))
        self.assertEqual(image.get('alt'), 'Исходная строка DjVu, страница 3')
        self.assertEqual(control_pages[('[OCR U+001F]',)], [(3, True)])

    def test_djvu_text_only_preserves_legacy_and_readable_damaged_text_in_the_same_batch(self):
        tools = self.root / 'tools'
        (tools / 'djvu').mkdir(parents=True)
        (tools / 'djvu/djvused.exe').touch()
        book = text_inputs.Book(c, self.root / 'mixed.djvu', set(), tools_root=tools, omit_images=True)
        legacy = 'В журнале есть статьи о науке и для читателей это важно. Как это устроено в школе.'
        healthy = 'Иллюстрация и обычный текст в UTF-8. '.encode()
        damaged = b'Some recoverable English words around this badge \xf8 and more text.'

        def run(args, stdout, **options):
            script = args[args.index('-e') + 1]
            if script == 'n':
                stdout.write(b'3')
            else:
                stdout.write(b'\xef\xbb\xbf' + b'\f'.join([legacy.encode('cp1251'), healthy, damaged, b'']))
            return subprocess.CompletedProcess(args, 0, b'', b'')

        with patch.object(fixed.subprocess, 'run', side_effect=run):
            fixed.read_djvu(book, tools)
        self.assertEqual([''.join(page.itertext()) for page in book.body], [
            legacy, healthy.decode().strip(), damaged.decode('utf-8', 'replace'),
        ])
        [warning] = c.damaged_content_warnings(book.warnings)
        self.assertIn('на страницах 3 (всего 1)', warning)

    def test_djvu_coarse_text_keeps_the_complete_scan_and_text(self):
        book = text_inputs.Book(c, self.root / 'coarse-ocr.djvu', set(), tools_root=TOOLS)
        pixels = bytes([20, 80, 180]) * 12

        def run(args, stdout, **options):
            script = args[args.index('-e') + 1] if '-e' in args else ''
            outputs = {
                'n': b'1',
                'print-outline': b'',
                'select 1; print-txt': b'(page 0 0 4 3 (para 0 0 4 3 "Text kept with its diagram.\\nSecond sentence."))',
                '': b'P6\n4 3\n255\n' + pixels,
            }
            stdout.write(outputs[script])
            return subprocess.CompletedProcess(args, 0, b'', b'')

        with patch.object(fixed.subprocess, 'run', side_effect=run):
            fixed.read_djvu(book, TOOLS)
        [section] = book.body
        self.assertEqual(section.get('id'), 'page-1')
        label, scan, transcript, first, second = section
        self.assertEqual(label.text, 'Страница 1')
        [image] = scan
        self.assertEqual(book.resources[image.get('src')][0], fixed.png(pixels, 4, 3))
        self.assertEqual(transcript.text, 'Текстовый слой страницы')
        self.assertEqual((first.text, second.text), ('Text kept with its diagram.', 'Second sentence.'))
        self.assertFalse(c.damaged_content_warnings(book.warnings))

    def test_sparse_invalid_ocr_codes_remain_visible_without_bypassing_quality(self):
        source = self.root/'source.pdf'; source.write_bytes(pdf_fixture())
        warnings = set(); book = text_inputs.Book(c, source, warnings)
        text = 'Complete readable OCR paragraph preserving all words. ' * 10 + 'A\x11B\x10C'
        fixed.emit_page(book, 137, [{'text':text, 'box':(0,0,100,100)}], b'\xff'*300, 10,10,100,100)
        visible = ''.join(book.body.itertext())
        self.assertIn('A[OCR U+0011]B[OCR U+0010]C', visible)
        self.assertTrue(any('137' in warning and 'U+0011' in warning for warning in warnings))
        ET.fromstring(ET.tostring(book.body))
        bad = text_inputs.Book(c, source, set())
        fixed.emit_page(bad, 2, [{'text':'\x11'*100+'letters', 'box':(0,0,100,100)}], b'\xff'*300,10,10,100,100)
        self.assertEqual(''.join(bad.body.itertext()),'Страница 2')
        self.assertEqual(len(bad.resources),1)
        self.assertTrue(any('OCR' in warning for warning in bad.warnings))

    def test_unreadable_control_character_yields_valid_epub_with_warning(self):
        source = self.root/'control.txt'; source.write_text('Readable text with invalid XML \x11.',encoding='utf-8')
        output = self.root/'invalid.epub'
        result = c.convert_book(source, output)
        with zipfile.ZipFile(output) as archive:
            output_text = c.plain(c.xml(archive.read('OEBPS/book.xhtml')))
        self.assertIn('Readable text with invalid XML �.', output_text)
        self.assertIn('Нечитаемые символы исходника отмечены знаком �.', c.damaged_content_warnings(result['warnings']))

    def test_djvu_preview_samples_only_complete_image_only_bundles(self):
        total = 137
        directory = b'    DIRM [921] Document directory (bundled, 138 files 137 pages)\n'
        pages = [f'    FORM:DJVU [{1000+(i%7)*500}] {{s{i}.djvu}} [P{i}]\n'.encode()
                 for i in range(1, total+1)]
        dump = directory + b''.join(pages)
        groups = fixed.djvu_raster_sample_groups(fixed.djvu_bundled_scan_pages(dump, total))
        self.assertEqual(len(groups), 16)
        self.assertEqual(sum(weight for _, weight in groups), total)
        self.assertEqual(len({page for page, _ in groups}), 16)
        for part in range(8):
            start, end = part*total//8, (part+1)*total//8
            self.assertEqual(sum(weight for page, weight in groups if start<page<=end), end-start)
        for incomplete in (dump + b'      TXTz [282]\n', dump + b'      TXTa [22]\n',
                           directory + b''.join(pages[1:]), dump.replace(b'bundled', b'indirect')):
            self.assertEqual(fixed.djvu_bundled_scan_pages(incomplete, total), [])

    def test_large_djvu_skips_text_requests_only_for_proven_image_only_bundle(self):
        total = 132
        source = self.root / 'scans.djvu'
        directory = b'    DIRM [921] Document directory (bundled, 132 files 132 pages)\r\n'
        catalogue = directory + b''.join(f'    FORM:DJVU [900] {{p{n}.djvu}} [P{n}]\r\n'.encode()
                                         for n in range(1, total + 1))
        frame = b'P6\n1 1\n255\n\x10\x20\x30'
        for has_text in (False, True):
            with self.subTest(has_text=has_text):
                requests = []
                book = text_inputs.Book(c, source, set())

                def run(args, stdout, **_options):
                    command = args[args.index('-e') + 1] if '-e' in args else ''
                    if command == 'n':
                        stdout.write(str(total).encode())
                    elif command == 'dump':
                        stdout.write(catalogue + (b'      TXTz [28]\r\n' if has_text else b''))
                    elif 'print-txt' in command:
                        numbers = [int(value) for value in re.findall(r'select (\d+)', command)]
                        requests.extend(numbers)
                        for number in numbers:
                            stdout.write(b'(page 0 0 10 10 "Last page text")\n' if number == total else
                                         b'(page 0 0 0 0 "")\n')
                    elif not command:
                        selection = next(value.split('=', 1)[1] for value in args if value.startswith('-page='))
                        first, last = map(int, selection.split('-'))
                        stdout.write(frame * (last - first + 1))
                    return subprocess.CompletedProcess(args, 0, b'', b'')

                with patch.object(fixed.subprocess, 'run', side_effect=run):
                    fixed.read_djvu_pages(book, Path('djvused.exe'), Path('ddjvu.exe'), source, False)
                self.assertEqual(requests, list(range(1, total + 1)) if has_text else [])
                self.assertEqual(book.page_count, total)
                self.assertEqual(sum(c.tag(node) == 'img' for node in book.body.iter()), total)
                self.assertEqual('Last page text' in c.plain(book.body), has_text)

    def test_djvu_catalogue_dimensions_require_ordered_page_headers(self):
        directory = b'    DIRM [921] Document directory (bundled, 4 files 3 pages)\r\n'
        pages = [f'    FORM:DJVU [200] {{scaled-{i}.djvu}} [P{i}]\r\n'
                 f'      INFO [10] DjVu {100*i}x{110*i}, v25, 600 dpi, gamma=2.2\r\n'.encode()
                 for i in range(1,4)]
        dump = directory + b''.join(pages)
        self.assertEqual(fixed.djvu_bundled_dimensions(dump, 3), {1:(100,110), 2:(200,220), 3:(300,330)})
        for incomplete in (directory + pages[1] + pages[0] + pages[2],
                           directory + pages[0] + pages[2],
                           dump.replace(b'[P2]', b'[P1]'),
                           dump.replace(b'200x220', b'0x220'),
                           dump.replace(b'      INFO', b'        INFO', 1),
                           dump.replace(b'bundled', b'indirect')):
            self.assertEqual(fixed.djvu_bundled_dimensions(incomplete, 3), {})

    def test_chm_resolves_links_and_images_inside_its_virtual_root(self):
        source = self.root / 'manual.chm'
        source.touch()
        tools = self.root / 'tools'
        archive_tool = tools / '7zip' / '7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        picture = fixed.png(b'\x10\x20\x30', 1, 1)
        scoped_picture = fixed.png(b'\x30\x20\x10', 1, 1)
        topic = b'index.html\0'
        members = {
            'book/start.htm': (br'<p><a href="../../../index.html">Root</a>'
                               br'<a href="/">Default topic</a><a href="/#home">Default anchor</a>'
                               br'<a href="Part%2520%23draft.htm#note">Footnote</a>'
                               br'<img src="../../../assets/figure%2520%23main.png" alt="Root photo">'
                               br'<img src="%5cassets%5cfigure%2520%23main.png" alt="Absolute photo">'
                               br'<img src="..%5c..%5cassets%5cscoped.png" width="14" height="1" alt="Scoped photo">'
                               br'<img src="../../assets/other.png" alt="Missing photo">'
                               br'<img src="/assets/scoped.png" alt="Missing absolute photo"></p>'),
            'book/Part%20#draft.htm': b'<p><a name="note"></a>The destination.</p>',
            'assets/figure%20#main.png': picture,
            'book/assets/figure%20#main.png': scoped_picture,
            'book/assets/scoped.png': scoped_picture,
            'another/assets/other.png': picture,
            'index.html': b'<p>Home page text.</p><p id="home">The home anchor.</p>',
            '#SYSTEM': struct.pack('<IHH', 3, 2, len(topic)) + topic,
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        book = text_inputs.Book(c, source, set(), tools_root=tools)
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        by_id = {node.get('id'): node for node in book.body.iter() if node.get('id')}
        links = {c.plain(node): node.get('href') for node in book.body.iter() if node.get('href')}
        self.assertEqual(set(links), {'Root', 'Footnote', 'Default topic', 'Default anchor'})
        self.assertEqual(links['Default topic'], links['Root'])
        self.assertEqual(c.plain(by_id[links['Default anchor'][1:]]), 'The home anchor.')
        self.assertIn('Home page text.', c.plain(by_id[links['Root'][1:]]))
        self.assertEqual(by_id[links['Footnote'][1:]].get('id').rsplit('-', 1)[-1], 'note')
        images = {node.get('alt'): node for node in book.body.iter() if c.tag(node) == 'img'}
        self.assertEqual({label: book.resources[image.get('src')][0] for label, image in images.items()},
                         {'Root photo': picture, 'Absolute photo': picture, 'Scoped photo': scoped_picture})
        self.assertEqual((images['Scoped photo'].get('width'), images['Scoped photo'].get('height')), ('14', '1'))
        missing = c.damaged_content_warnings(book.warnings)
        self.assertEqual(len(missing), 3)
        self.assertEqual(sum('other.png' in item for item in missing), 1)
        self.assertEqual(sum('scoped.png' in item for item in missing), 1)

    def test_chm_preserves_links_to_images_with_literal_numeric_suffixes(self):
        source = self.root / 'manual.chm'
        source.touch()
        tools = self.root / 'tools'
        archive_tool = tools / '7zip' / '7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        figure = fixed.png(b'\x10\x20\x30', 1, 1)
        other = fixed.png(b'\x30\x20\x10', 1, 1)
        members = {
            'page.htm': (b'<p><a href="images/Figure.PNG;382543">Figure</a>'
                         b'<a href="images/Figure.PNG%3B382543">Same figure</a>'
                         b'<a href="images/Figure.PNG;7244">Missing revision</a>'
                         b'<a href="images/Broken.PNG;382543">Damaged figure</a>'
                         b'<a href="images/notes.txt;382543">Source notes</a></p>'),
            'images/Figure.PNG;382543': figure,
            'images/Figure.PNG': other,
            'images/Broken.PNG;382543': b'damaged image',
            'images/notes.txt;382543': b'plain text',
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        book = text_inputs.Book(c, source, set(), tools_root=tools)
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        links = {c.plain(node): node.get('href') for node in book.body.iter() if node.get('href')}
        self.assertEqual(links, {'Figure': '#chm-image-1', 'Same figure': '#chm-image-1'})
        target = next(node for node in book.body.iter() if node.get('id') == 'chm-image-1')
        image, = (node for node in target.iter() if c.tag(node) == 'img')
        self.assertEqual(book.resources[image.get('src')][0], figure)
        warnings = '\n'.join(book.warnings)
        self.assertIn('Figure.PNG;7244', warnings)
        self.assertIn('Broken.PNG;382543', warnings)
        self.assertIn('notes.txt;382543', warnings)
        self.assertNotIn('Figure.PNG;382543', warnings)

    def test_large_chm_spools_html_without_losing_links_or_images(self):
        source = self.root / 'spooled.chm'
        source.touch()
        tools = self.root / 'tools'
        tool = tools / '7zip' / '7z.exe'
        tool.parent.mkdir(parents=True)
        tool.touch()
        picture = fixed.png(b'\x10\x20\x30', 1, 1)
        members = {
            'a.htm': b'<h1>First</h1><p><a href="b.htm#place">Cross chapter</a><img src="a.png"></p>',
            'b.htm': b'<h1 id="place">Second</h1><p><a href="a.htm">Back</a></p>',
            'a.png': picture,
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        sections = {}
        for streaming in (False, True):
            target = self.root / f'book-{streaming}.epub'
            book = text_inputs.Book(c, source, set(), tools_root=tools)
            book.work_root = self.root
            with ExitStack() as resources, patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
                book.work_resources = resources
                with patch.object(c, 'MAX_FILE', 100 if streaming else c.MAX_FILE):
                    legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
                self.assertEqual(book.section_store is not None, streaming)
                book.finish(target)
            with zipfile.ZipFile(target) as archive:
                sections[streaming] = tuple(archive.read('OEBPS/' + part).replace(b'\r\n', b'\n')
                                             for part in ('book.xhtml', 'nav.xhtml'))
                [image] = [node for node in c.xml(sections[streaming][0]).iter() if c.tag(node) == 'img']
                self.assertEqual(archive.read('OEBPS/' + image.get('src')), picture)
        self.assertEqual(sections[True], sections[False])

    def test_chm_default_topic_ignores_incomplete_conflicting_and_remote_locations(self):
        def record(value):
            data = value + b'\0'
            return struct.pack('<HH', 2, len(data)) + data

        header = struct.pack('<I', 3)
        first = record(b'part/home.htm#topic')
        self.assertEqual(legacy.chm_default_topic(header + first, text_inputs.decode), ('part/home.htm', 'topic'))
        for data in (header + first[:-1], header + first + record(b'elsewhere.htm'),
                     header + record(b'https://example.invalid/home.htm')):
            with self.subTest(data=data):
                self.assertEqual(legacy.chm_default_topic(data, text_inputs.decode), ('', ''))

    def test_chm_window_topic_requires_a_consistent_local_destination(self):
        def table(*offsets):
            entry_size = 0xbc
            result = bytearray(8 + entry_size * len(offsets))
            struct.pack_into('<II', result, 0, len(offsets), entry_size)
            for index, offset in enumerate(offsets):
                struct.pack_into('<I', result, 8 + index * entry_size + 0x68, offset)
            return result

        strings = b'\0index.htm\0alternate.htm\0'
        for offsets in ((1,), (1, 1)):
            self.assertEqual(legacy.chm_window_topic(table(*offsets), strings, text_inputs.decode), ('index.htm', ''))
        for data, names in ((table(1, 11), strings), (table(0), strings), (table(1)[:-1], strings),
                            (table(1), b'\0index.htm')):
            self.assertEqual(legacy.chm_window_topic(data, names, text_inputs.decode), ('', ''))

    @unittest.skipUnless(os.name == 'nt', 'legacy Windows path limit')
    def test_office_metafile_workspace_falls_back_only_for_deep_path(self):
        deep = self.root
        while len(str(deep)) < 239:
            deep = deep / ('nested-' + 'a' * min(30, 238 - len(str(deep))))
        deep.mkdir(parents=True)
        book = text_inputs.Book(c, self.root / 'office.docx', set())
        with patch.object(tempfile, 'gettempdir', return_value=str(self.root)):
            book.work_root = deep
            with office.office_metafile_workspace(book) as short:
                self.assertEqual(short.parent, self.root)
                self.assertTrue(short.is_dir())
            self.assertFalse(short.exists())
            self.assertEqual(list(deep.iterdir()), [])
            book.work_root = self.root / 'normal'
            book.work_root.mkdir()
            with office.office_metafile_workspace(book) as normal:
                self.assertEqual(normal.parent, book.work_root)
            self.assertFalse(normal.exists())

    def test_office_metafile_worker_reuses_process_and_supports_older_helpers(self):
        tools = self.root / 'tools'
        worker = tools / 'doc' / 'HomeLibDoc.exe'
        worker.parent.mkdir(parents=True)
        worker.touch()
        png = fixed.png(b'\x10\x20\x30', 1, 1)
        launch = subprocess.Popen
        child_code = """
from pathlib import Path
import sys
png = bytes.fromhex(sys.argv[1])
folder = Path(sys.argv[2])
print('READY 1', flush=True)
while sys.stdin.buffer.read(1) == b'R':
    data = (folder / 'picture.bin').read_bytes()
    if data.endswith(b'damaged'):
        print('ERROR', flush=True)
    else:
        (folder / 'picture.png').write_bytes(png)
        print('OK', flush=True)
"""
        for batch in (True, False):
            with self.subTest(batch=batch):
                calls = []

                def fake_helper(arguments, **kwargs):
                    mode = arguments[1]
                    calls.append(mode)
                    if mode == '--image-to-png-stream':
                        command = ([sys.executable, '-c', child_code, png.hex(), arguments[2]] if batch
                                   else [sys.executable, '-c', "print('ERROR INVALID')"])
                    else:
                        command = [sys.executable, '-c', """
from pathlib import Path
import sys
if Path(sys.argv[1]).read_bytes().endswith(b'damaged'):
    raise SystemExit(1)
Path(sys.argv[2]).write_bytes(bytes.fromhex(sys.argv[3]))
""", arguments[2], arguments[3], png.hex()]
                    return launch(command, **kwargs)

                book = text_inputs.Book(c, self.root / 'office.docx', set(), tools_root=tools)
                book.work_root = self.root
                with patch.object(subprocess, 'Popen', side_effect=fake_helper), ExitStack() as stack:
                    book.work_resources = stack
                    first, broken, last = (b'\x01\0\x09\0' + value for value in (b'first', b'damaged', b'last'))
                    self.assertEqual(office.rasterize_image(book, first), png)
                    with self.assertRaises(c.UnreadableImage):
                        office.rasterize_image(book, broken)
                    self.assertEqual(office.rasterize_image(book, last), png)
                    process = book._office_image_worker.process if batch else None
                self.assertEqual(calls, ['--image-to-png-stream'] + (['--image-to-png'] * 3 if not batch else []))
                if process is not None:
                    self.assertEqual(process.poll(), 0)
                self.assertEqual(list(self.root.glob('homelibre-metafiles-*')), [])

    @unittest.skipUnless(os.name == 'nt' and (TOOLS / 'doc/HomeLibDoc.exe').is_file(), 'bundled Office helper')
    def test_large_enhanced_metafiles_fit_canvas_and_require_complete_records(self):
        tool = TOOLS / 'doc/HomeLibDoc.exe'
        for width, height in ((6000, 4000), (25000, 200)):
            with self.subTest(size=(width, height)):
                records = (struct.pack('<6I', 39, 24, 1, 0, 0x000000ff, 0),
                           struct.pack('<3I', 37, 12, 1),
                           struct.pack('<II4i', 43, 24, 0, 0, width // 2, height // 2),
                           struct.pack('<II4i', 43, 24, width // 2, height // 2, width, height),
                           struct.pack('<5I', 14, 20, 0, 0, 20))
                header = struct.pack('<II8iIIIIHHIII4i', 1, 88, 0, 0, width - 1, height - 1,
                                     0, 0, width * 25, height * 25, 0x464d4520, 0x10000,
                                     88 + sum(map(len, records)), len(records) + 1,
                                     2, 0, 0, 0, 0, 1200, 800, 300, 200)
                data = header + b''.join(records)
                source = self.root / f'figure-{width}.emf'
                target = source.with_suffix('.png')
                source.write_bytes(data)
                result = subprocess.run([tool, '--image-to-png', source, target], capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                png = target.read_bytes()
                c.check_embedded_raster(png)
                columns, rows = struct.unpack_from('>II', png, 16)
                self.assertLess(columns, width)
                self.assertLessEqual(columns, 16384)
                self.assertLessEqual(columns * rows, 16 * 1024**2)
                self.assertAlmostEqual(rows, columns * height / width, delta=1.5)
                self.assertEqual(source.read_bytes(), data)
                corrupt = self.root / f'incomplete-{width}.emf'
                corrupt.write_bytes(data[:-len(records[-1])])
                output = corrupt.with_suffix('.png')
                result = subprocess.run([tool, '--image-to-png', corrupt, output], capture_output=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_chm_preserves_linked_illustrations_and_unambiguous_anchors_during_export(self):
        source = self.root / 'illustrated.chm'
        source.touch()
        tools = self.root / 'tools'
        archive_tool = tools / '7zip' / '7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        large = fixed.png(b'\x10\x20\x30' * 4, 2, 2)
        thumbnail = fixed.png(b'\x10\x20\x30', 1, 1)
        attachment = BytesIO()
        with zipfile.ZipFile(attachment, 'w') as archive:
            archive.writestr('example.txt', 'Приложение к главе')
        members = {
            'start.htm': (b'<h1>Chapter</h1><p><a href="pics/full%2520%23large.png">'
                          b'<img src="pics/thumb.png"></a><a href="/PICS/full%2520%23large.PNG">Full image</a>'
                          b'<a href="#bOOkMaRk">Unique</a><a href="#Xy">Ambiguous</a>'
                          b'<a href="#XY">Exact</a><a href="#space%2520case">Literal percent</a>'
                          b'<a href="pics/corrupt.png">Unreadable</a><a href="pics/absent.png">Absent</a>'
                          b'<a href="example.zip">Download example</a>'
                          b'<a href="https://example.invalid/pics/full.png">External</a></p>'
                          b'<p id="Bookmark">Unique target</p><p id="XY">First target</p>'
                          b'<p id="xy">Second target</p><p id="space%20case">Percent target</p>'),
            'pics/thumb.png': thumbnail,
            'pics/full%20#large.png': large,
            'pics/corrupt.png': large[:-12],
            'example.zip': attachment.getvalue(),
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        epub = source.with_suffix('.epub')
        fb2 = source.with_suffix('.fb2')
        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=tools)
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        book.finish(epub)
        c.epub_to_fb2(epub, fb2, warnings)
        self.assertEqual({label for label in ('#Xy', 'pics/corrupt.png', 'pics/absent.png')
                          if any(label in notice for notice in c.damaged_content_warnings(warnings))},
                         {'#Xy', 'pics/corrupt.png', 'pics/absent.png'})
        notices = c.damaged_content_warnings(warnings)
        self.assertTrue(any('Вложение CHM «example.zip» осталось в исходнике' in item for item in notices))
        self.assertFalse(any('Не найдена цель ссылки CHM «example.zip»' in item for item in notices))
        with zipfile.ZipFile(epub) as epub_archive:
            html = c.xml(epub_archive.read('OEBPS/book.xhtml'))
            nav = c.xml(epub_archive.read('OEBPS/nav.xhtml'))
            self.assertEqual([c.plain(n) for n in nav.iter() if c.tag(n) == 'a'], ['Chapter'])
            converted = c.xml(fb2.read_bytes())
            c.validate_fb2_output(converted)
            binaries = {n.get('id'): base64.b64decode(n.text) for n in converted if c.tag(n) == 'binary'}
            for tree, attribute in ((html, 'href'), (converted, '{' + c.XL + '}href')):
                body = c.first(tree, 'body')
                ids = {n.get('id'): n for n in body.iter() if n.get('id')}
                elements = [n for n in body.iter() if c.tag(n) == 'a']
                links = {c.plain(n): n.get(attribute) for n in elements}
                [thumbnail_link] = [n for n in elements if any(c.tag(p) in {'img', 'image'} for p in n)]
                self.assertEqual(thumbnail_link.get(attribute), links['Full image'])
                target = ids[unquote(links['Full image'][1:])]
                [image] = [n for n in target.iter() if c.tag(n) in {'img', 'image'}]
                data = (epub_archive.read('OEBPS/' + image.get('src')) if tree is html
                        else binaries[image.get(attribute)[1:]])
                self.assertEqual(data, large)
                self.assertEqual(c.plain(ids[unquote(links['Unique'][1:])]), 'Unique target')
                self.assertEqual(c.plain(ids[unquote(links['Exact'][1:])]), 'First target')
                self.assertEqual(c.plain(ids[unquote(links['Literal percent'][1:])]), 'Percent target')
                self.assertEqual(links['External'], 'https://example.invalid/pics/full.png')
                self.assertIn('Download example', c.plain(body))
                self.assertFalse(links.get('Download example'))
                for label in ('Ambiguous', 'Unreadable', 'Absent'):
                    self.assertFalse(links.get(label))

    def test_chm_restores_page_starts_and_only_proven_word_note_pairs(self):
        source = self.root / 'notes.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        members = {
            'notes.htm': (b'<p><a name="_ftn1" href="old.htm#_ftnref1">First note</a></p>'
                          b'<p><a name="_ftn2" href="old.htm#_ftnref2">Ambiguous note</a></p>'
                          b'<p><a name="_ftn3" href="old.htm#_ftnref3">Unrelated note</a></p>'
                          b'<p><a href="old.htm#_ftnref1">Same name without a backlink</a></p>'
                          b'<p><a href="chapter.htm#%74op">Go to start</a>'
                          b'<a href="old.htm#top">Go to named target</a></p>'
                          b'<p><a href="chapter.htm#5">Part One</a> / <a href="chapter.htm#5">Proven name</a></p>'
                          b'<p><a href="old.htm#8">Part Two</a> / <a href="old.htm#8">Incorrect name</a></p>'
                          b'<p><a href="chapter.htm#6">Existing number</a></p>'
                          b'<p><a href="chapter.htm#11">Part one</a> / <a href="chapter.htm#11">Proven Name</a></p>'),
            'chapter.htm': (b'<p>Real chapter beginning</p><h1>Part One: Proven name</h1>'
                            b'<p id="6">Following paragraph</p>'
                            b'<p><a name="_ftnref1" href="notes.htm#_ftn1">First call</a></p>'
                            b'<p><a name="_ftnref2" href="notes.htm#_ftn2">Ambiguous call</a></p>'
                            b'<p><a name="_ftnref3" href="other.htm#_ftn3">Other call</a></p>'),
            'old.htm': (b'<p>Old chapter beginning</p><h1>Part Two: Original name</h1>'
                        b'<p id="9">A different paragraph</p><p id="top">Named landing point</p>'),
            'other.htm': (b'<p><a name="_ftnref2" href="notes.htm#_ftn2">Second ambiguous call</a></p>'
                          b'<p id="_ftn3">Different note</p>'),
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read(book, '.chm',
                        lambda target, data: text_inputs.read_html(target, data, html5=True),
                        text_inputs.decode)
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        book.finish(epub)
        c.epub_to_fb2(epub, fb2, warnings)
        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
        converted = c.xml(fb2.read_bytes())
        c.validate_fb2_output(converted)
        for root, attr in ((chapter, 'href'), (converted, '{' + c.XL + '}href')):
            body = c.first(root, 'body')
            targets = {node.get('id'): c.plain(node) for node in body.iter() if node.get('id')}
            links = {c.plain(node): node.get(attr) for node in body.iter() if c.tag(node) == 'a'}
            self.assertTrue(targets[unquote(links['Go to start'][1:])].startswith('Real chapter beginning'))
            self.assertEqual(targets[unquote(links['Go to named target'][1:])], 'Named landing point')
            self.assertEqual(targets[unquote(links['First note'][1:])], 'First call')
            self.assertEqual(targets[unquote(links['First call'][1:])], 'First note')
            self.assertEqual(links['Part One'], links['Proven name'])
            self.assertEqual(targets[unquote(links['Part One'][1:])], 'Part One: Proven name')
            self.assertEqual(targets[unquote(links['Existing number'][1:])], 'Following paragraph')
            for label in ('Ambiguous note', 'Unrelated note', 'Same name without a backlink',
                          'Part Two', 'Incorrect name', 'Part one', 'Proven Name'):
                self.assertFalse(links.get(label))
                self.assertIn(label, c.plain(body))
        notices = c.damaged_content_warnings(warnings)
        self.assertEqual(sum(notice.startswith('Не найдена цель ссылки CHM') for notice in notices), 5)
        self.assertIn('В CHM восстановлены переходы к заголовкам глав. Число целей — 1.', warnings)

    def test_chm_restores_only_exact_unique_index_anchors_in_the_same_folder(self):
        source = self.root / 'index.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        members = {
            'book/index.html': (b'<p><a href="obsolete.html#I_indexterm2_d1e10">Moved</a>'
                                b'<a href="obsolete.html#title">Moved heading</a>'
                                b'<a href="obsolete.html#unrelated">Unproven chapter</a>'
                                b'<a href="obsolete.html?edition=2#title">Query</a>'
                                b'<a href="obsolete.html#I_indexterm2_d1e11">Duplicate</a>'
                                b'<a href="old.html#I_indexterm2_d1e10">Existing file</a>'
                                b'<a href="../other/absent.html#I_indexterm2_d1e10">Other folder</a>'
                                b'<a href="unknown.html#intro">Generic</a></p>'),
            'book/chapter.html': (b'<p id="I_indexterm2_d1e10">Correct target</p>'
                                  b'<p id="title">Heading in the moved chapter</p>'
                                  b'<p id="I_indexterm2_d1e11">First duplicate</p><p id="intro">Another target</p>'),
            'book/supplement.html': b'<p id="I_indexterm2_d1e11">Second duplicate</p><p id="unrelated">Other topic</p>',
            'book/old.html': b'<p>Original file is available, its target is absent.</p>',
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        chapters = book.body
        links = {c.plain(node): node.attrib.get('href') for node in chapters.iter() if c.tag(node) == 'a'}
        targets = {node.get('id'): c.plain(node) for node in chapters.iter() if node.get('id')}
        self.assertEqual(targets[links['Moved'][1:]], 'Correct target')
        self.assertEqual(targets[links['Moved heading'][1:]], 'Heading in the moved chapter')
        for label in ('Unproven chapter', 'Query', 'Duplicate', 'Existing file', 'Other folder', 'Generic'):
            self.assertIsNone(links.get(label))
            self.assertIn(label, c.plain(chapters))
        self.assertEqual(sum(line.startswith('Не найдена цель ссылки CHM') for line in warnings), 6)
        self.assertIn('В CHM восстановлены ссылки предметного указателя. Переходов — 1.', warnings)
        self.assertIn('В CHM восстановлены переходы к перемещённым разделам. Переходов — 1.', warnings)

    def test_chm_recovers_letter_index_links_with_exact_generated_anchors(self):
        source = self.root / 'letter-index.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        members = {
            'manual/index_A.html': (
                b'<p><a href="index_B.html#idd1e10">Cross-reference</a>'
                b'<a href="index_A.html#idd1e11">Valid index entry</a>'
                b'<a href="index_B.html#idd1e12">Ambiguous</a>'
                b'<a href="index_B.html?edition=2#idd1e10">Query</a>'
                b'<a href="../other/index_B.html#idd1e20">Other manual</a>'
                b'<a href="chapter.html#idd1e14">Ordinary href</a></p>'
                b'<p id="idd1e11">Actual index entry</p>'),
            'manual/index_B.html': b'<p>Alphabetical index B</p>',
            'manual/C.html': b'<a href="C.html#ch01index21">Older index reference</a>',
            'manual/chapter.html': (b'<p id="idd1e10">Reference in chapter</p>'
                                    b'<p id="idd1e11">Same mark in chapter</p>'
                                    b'<p id="idd1e12">First match</p><p id="idd1e20">Different manual</p>'
                                    b'<p id="ch01index21">Reference in older chapter</p>'),
            'manual/supplement.html': b'<p id="idd1e12">Second match</p><p id="idd1e14">Different topic</p>',
            'other/index_B.html': b'<p>Another alphabetical index</p>',
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        targets = {node.get('id'): c.plain(node) for node in book.body.iter() if node.get('id')}
        links = {c.plain(node): targets[node.get('href')[1:]] for node in book.body.iter()
                 if c.tag(node) == 'a' and node.get('href')}
        self.assertEqual(links, {'Cross-reference': 'Reference in chapter', 'Valid index entry': 'Actual index entry',
                                 'Older index reference': 'Reference in older chapter'})
        self.assertIn('В CHM восстановлены ссылки предметного указателя. Переходов — 2.', warnings)

    def test_chm_preserves_named_sections_and_printed_page_boundaries(self):
        source = self.root / 'chapters.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        members = {
            'book/outline.htm': (
                b'<p><a href="supplement.htm#1">Bibliography</a>'
                b'<a href="supplement.htm#2">Repeated heading</a>'
                b'<a href="supplement.htm#3">First possible heading</a>'
                b'<a href="supplement.htm#3">Second possible heading</a>'
                b'<a href="supplement.htm?edition=2#4">Bibliography</a>'
                b'<a href="unknown.htm#1">Bibliography</a></p>'
                b'<p><a href="bbl0002.htm#20">5&ndash;6</a>'
                b'<a href="bbl0002.htm#19">4</a>'
                b'<a href="bbl0002.htm#20">Unrelated text</a>'
                b'<a href="bbl0003.htm#20">9</a>'
                b'<a class="chapterjump" href="bbl0003.htm#21">Chapter 3:</a>'
                b'<a href="bbl0003.htm#21">next chapter</a>'
                b'<a class="chapterjump" href="bbl0003.htm#18">Chapter 3</a>'
                b'<a class="chapterjump" href="LiB0060.htm#524">Chapter 10</a>'
                b'<a href="LiB0060.htm#524">A later chapter reference</a></p>'),
            'book/supplement.htm': (
                b'<h2 id="original">Bibliography</h2><p>Book references.</p>'
                b'<h2>Repeated heading</h2><h2>Repeated heading</h2>'
                b'<h2>First possible heading</h2><h2>Second possible heading</h2>'),
            'book/bbl0001.htm': (
                b'<p><a name="19"></a>Unmarked number</p>'
                b'<p><a name="20"></a><a name="beginpage."></a>Text at page five.</p>'),
            'book/bbl0002.htm': b'<h1 id="21">Next topic</h1>',
            'book/bbl0003.htm': b'<h1 id="22">Chapter 3: Third topic</h1>',
            'book/LiB0060.htm': b'<h1>Chapter 10: Tenth topic</h1><h3 id="525">Objectives</h3>',
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        for disk_backed in (False, True):
            with self.subTest(disk_backed=disk_backed):
                warnings = set()
                book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
                if disk_backed:
                    book.image_store = self.root
                    book.section_store = []
                book.work_root = self.root
                with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
                    legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
                roots = [ET.parse(path).getroot() for path in book.section_store] if disk_backed else [book.body]
                anchors = {node.get('id'): node for root in roots for node in root.iter() if node.get('id')}
                links = [(c.plain(node), node.get('href')) for root in roots for node in root.iter()
                         if c.tag(node) == 'a' and c.plain(node)]
                bibl = [href for label, href in links if label == 'Bibliography']
                self.assertEqual(len([href for href in bibl if href]), 1)
                self.assertEqual(c.plain(anchors[bibl[0][1:]]), 'Bibliography')
                page = anchors[dict(links)['5–6'][1:]]
                self.assertTrue(page.get('id').endswith('-20'))
                self.assertIn('Text at page five.', [parent[-1].tail.strip() for root in roots for parent in root.iter()
                                                    if page in list(parent) and parent[-1].tail])
                chapter = anchors[dict(links)['Chapter 3:'][1:]]
                self.assertEqual(c.plain(chapter), 'Chapter 3: Third topic')
                self.assertEqual(dict(links)['Chapter 3:'], dict(links)['next chapter'])
                later = anchors[dict(links)['Chapter 10'][1:]]
                self.assertEqual(c.plain(later), 'Chapter 10: Tenth topic')
                self.assertEqual(dict(links)['Chapter 10'], dict(links)['A later chapter reference'])
                for label in ('Repeated heading', 'First possible heading', 'Second possible heading', '4',
                              'Unrelated text', '9', 'Chapter 3'):
                    self.assertIsNone(dict(links)[label])
                self.assertIn('В CHM восстановлены переходы к заголовкам глав. Число целей — 3.', warnings)
                self.assertIn('В CHM восстановлены переходы к меткам печатных страниц. Переходов — 1.', warnings)

    def test_chm_recovers_only_the_original_transparent_sidebar_spacer(self):
        source = self.root / 'sidebar.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        gif_header = b'GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff'
        gif_frame = b'\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x4c\x01\x00\x3b'
        transparent = gif_header + b'\x21\xf9\x04\x01\x00\x00\x01\x00' + gif_frame
        opaque = gif_header + gif_frame
        sidebar = (b'<table><tr><td class="bluecell"><b>'
                   b'<img src="_.gif" width="1" height="2" title="Start Sidebar" alt="Image from book">'
                   b'</b></td></tr></table>')
        members = {
            'part/bbl0001.html': sidebar + b'<p>Sidebar content.</p>' + sidebar.replace(b'Start', b'End'),
            'part/bbl0002.html': b'<p><img src="_.gif" width="1" height="2" alt="A real image"></p>',
            'part/images/_.gif': transparent,
            'other/bbl0001.html': sidebar,
            'other/images/_.gif': opaque,
            'direct/bbl0001.html': sidebar,
            'direct/_.gif': opaque,
            'direct/images/_.gif': transparent,
            'corrupt/bbl0001.html': sidebar,
            'corrupt/_.gif': opaque[:-3],
            'corrupt/images/_.gif': transparent,
            'wrong/file.html': sidebar,
            'wrong/images/_.gif': transparent,
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read_chm(book, text_inputs.read_html, text_inputs.decode)
        images = list(book.body.iter('{' + c.XH + '}img'))
        self.assertEqual(len(images), 3)
        self.assertEqual([book.resources[image.get('src')][0] for image in images], [opaque, transparent, transparent])
        self.assertEqual([image.get('title') for image in images], ['Start Sidebar', 'Start Sidebar', 'End Sidebar'])
        self.assertTrue(all((image.get('width'), image.get('height')) == ('1', '2') for image in images))
        self.assertEqual(book.unreadable_images, 4)
        self.assertIn('Sidebar content.', c.plain(book.body))
        self.assertFalse(legacy.chm_transparent_gif_pixel(transparent[:-1]))
        self.assertFalse(legacy.chm_transparent_gif_pixel(transparent.replace(b'\x4c\x01', b'\x44\x01')))

    def test_chm_reports_absent_one_pixel_table_images_without_inserting_text_in_cells(self):
        source = self.root / 'layout.chm'
        source.touch()
        archive_tool = self.root / 'tools/7zip/7z.exe'
        archive_tool.parent.mkdir(parents=True)
        archive_tool.touch()
        pixel = fixed.png(b'\x10\x20\x30', 1, 1)
        members = {
            'page.htm': (b'<table><tr><td>First</td><td><img src="dot.gif" width="1" height="1"></td>'
                         b'<td><img src="valid.png" width="1" height="1"></td></tr>'
                         b'<tr><td>Second</td><td><img src="dot.gif" width="1" height="1" alt=""></td>'
                         b'<td><img src="dot.gif" width="1" height="1" alt="Original caption"></td></tr></table>'
                         b'<ol start="4"><li>Source list item</li></ol>'
                         b'<table id="outer"><tr><td>Outer<table id="inner"><tr><td>Inner</td></tr></table></td></tr></table>'
                         b'<p><a href="#outer">Outer link</a> / <a href="#inner">Inner link</a></p>'
                         b'<p>Image location <img src="../images/"></p>'),
            'valid.png': pixel,
        }
        listing = ''.join(f'Path = {name}\nSize = {len(data)}\n\n' for name, data in members.items()).encode()

        def run_7zip(arguments, stdout, **_):
            stdout.write(listing if arguments[2] == 'l' else members[arguments[-1]])
            return subprocess.CompletedProcess(arguments, 0, stderr=b'')

        warnings = set()
        book = text_inputs.Book(c, source, warnings, tools_root=archive_tool.parents[1])
        book.work_root = self.root
        with patch.object(legacy.subprocess, 'run', side_effect=run_7zip):
            legacy.read(book, '.chm',
                        lambda target, data: text_inputs.read_html(target, data, html5=True),
                        text_inputs.decode)
        epub, fb2 = source.with_suffix('.epub'), source.with_suffix('.fb2')
        book.finish(epub)
        epub_notices = c.damaged_content_warnings(warnings)
        c.epub_to_fb2(epub, fb2, warnings)
        self.assertFalse(hasattr(book, 'local_layout_image'))
        notices = c.damaged_content_warnings(warnings)
        [layout] = [notice for notice in notices if notice.startswith('Изображение CHM размером 1 × 1 недоступно')]
        self.assertIn('«dot.gif»', layout)
        self.assertIn('Число размещений — 2.', layout)
        [described] = [notice for notice in notices if notice.startswith('Изображение 1 недоступно')]
        self.assertIn('dot.gif', described)
        [directory] = [notice for notice in notices if notice.startswith('Изображение 2 недоступно')]
        self.assertIn('«../images/» указывает на папку без имени файла', directory)
        [changed_layout] = set(notices) - set(epub_notices)
        self.assertTrue(changed_layout.startswith('Внешняя таблица из одной ячейки заменена разделом FB2.'))

        with zipfile.ZipFile(epub) as archive:
            chapter = c.xml(archive.read('OEBPS/book.xhtml'))
            self.assertEqual([archive.read(name) for name in archive.namelist() if '/images/' in name], [pixel])
        ordered = next(node for node in chapter.iter() if c.tag(node) == 'ol')
        self.assertEqual(ordered.get('start'), '4')
        converted = c.xml(fb2.read_bytes())
        c.validate_fb2_output(converted)
        self.assertIn('4. Source list item', c.plain(converted))
        self.assertIn('Outer', c.plain(converted))
        self.assertIn('Inner', c.plain(converted))
        targets = {c.plain(link): link.get('{' + c.XL + '}href') for link in converted.iter('{' + c.FB + '}a')}
        self.assertNotEqual(targets['Outer link'], targets['Inner link'])
        for root, count in ((chapter, 3), (converted, 2)):
            tables = [node for node in root.iter() if c.tag(node) == 'table']
            self.assertEqual(len(tables), count)
            cells = [c.plain(node) for node in tables[0].iter() if c.tag(node) == 'td']
            self.assertEqual(cells, ['First', '', '', 'Second', '', '[Изображение 1 недоступно.] Original caption'])
        self.assertEqual(c.plain(tables[1]), 'Inner')
        self.assertEqual(targets['Inner link'], '#' + tables[1].get('id'))

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_actual_pdfium_text_and_illustration(self):
        report, text, images = self.convert('.123456', pdf_fixture(), '.fb2')
        self.assertIn('First readable paragraph', text); self.assertIn('Last paragraph preserves', text); self.assertGreaterEqual(len(images), 1)
        self.assertTrue(any('OCR' in w for w in report['warnings']))

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_scan_image_limit_explains_available_output_choices(self):
        source = self.root / 'scan.pdf'
        original = pdf_fixture(text=False)
        source.write_bytes(original)
        for suffix in ('.fb2', '.epub'):
            with self.subTest(suffix=suffix):
                output = self.root / ('scan' + suffix)
                with patch.object(c, 'MAX_TOTAL', 64), patch.object(c, 'MAX_SCAN_EPUB_RESOURCES', 64):
                    with self.assertRaisesRegex(c.ConversionError, 'Выберите более сильное сжатие'):
                        c.convert_book(source, output, tools_root=TOOLS)
                self.assertFalse(output.exists())
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_scan_epub_spools_images_beyond_regular_resource_limit(self):
        source = self.root / 'scan.pdf'
        original = pdf_fixture(text=False)
        source.write_bytes(original)
        for quality, grayscale in (('original', False), ('high', False), ('maximum', True)):
            with self.subTest(quality=quality, grayscale=grayscale):
                output = self.root / (quality + '.epub')
                progress = []
                with patch.object(c, 'MAX_TOTAL', 64):
                    c.convert_book(source, output, tools_root=TOOLS, image_quality=quality, grayscale=grayscale,
                                   progress=lambda *event: progress.append(event))
                with zipfile.ZipFile(output) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertIn(b'id="page-1"', archive.read('OEBPS/book.xhtml'))
                    self.assertTrue(any(archive.getinfo(name).file_size > 64 for name in archive.namelist() if '/images/' in name))
                self.assertFalse(list(self.root.glob('homelibre-page-images-*')))
                for stage in ('writing-epub', 'checking-epub'):
                    steps = [(current, total) for name, current, total in progress if name == stage]
                    self.assertEqual(steps[0][0], 0)
                    self.assertGreater(steps[-1][0], 0)
                    self.assertEqual(steps[-1][0], steps[-1][1])
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_scan_fb2_streams_images_beyond_regular_resource_limit(self):
        source = self.root/'scan.pdf'
        original = pdf_fixture(text=False, pages=2)
        source.write_bytes(original)
        output = self.root/'scan.fb2'
        progress = []
        with patch.object(c, 'MAX_TOTAL', 64):
            c.convert_book(source, output, tools_root=TOOLS, progress=lambda *step: progress.append(step))
        book = c.xml(output.read_bytes())
        c.validate_fb2_output(book)
        binary, = c.children(book, 'binary')
        self.assertGreater(len(base64.b64decode(binary.text)), 64)
        hrefs = [node.get(f'{{{c.XL}}}href') for node in c.first(book, 'body').iter(f'{{{c.FB}}}image')]
        self.assertEqual(hrefs, ['#' + binary.get('id')] * 2)
        steps = [(number, total) for stage, number, total in progress if stage == 'writing-fb2']
        self.assertEqual(steps, [(0, 1), (1, 1)])
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_scan_exports_keep_source_outline_without_synthetic_page_chapters(self):
        namespace = {'h': c.XH}
        for outline, broken_destination in ((False, False), (True, False), (True, True)):
            with self.subTest(outline=outline, broken_destination=broken_destination):
                source = self.root / f'scan-{outline}-{broken_destination}.pdf'
                source.write_bytes(pdf_fixture(text=False, pages=3, outline=outline,
                                               broken_destination=broken_destination))
                output = source.with_suffix('.epub')
                result = c.convert_book(source, output, tools_root=TOOLS)
                expected = ['Chapter', 'Subchapter'] if outline else []
                if outline and not broken_destination:
                    expected.append('Appendix')
                damage = c.damaged_content_warnings(result['warnings'])
                if broken_destination:
                    self.assertEqual(len(damage), 1)
                    self.assertIn('Пункты без доступной страницы — «Appendix»', damage[0])
                else:
                    self.assertEqual(damage, [])
                with zipfile.ZipFile(output) as archive:
                    nav = ET.fromstring(archive.read('OEBPS/nav.xhtml'))
                    links = [(a.text, a.get('href')) for a in nav.findall('.//h:a', namespace)]
                    if outline:
                        self.assertEqual(links, [(chapter, f'book.xhtml#page-{page}')
                                                 for page, chapter in enumerate(expected, 1)])
                        nested = nav.find('.//h:nav/h:ol/h:li/h:ol/h:li/h:a', namespace)
                        self.assertEqual(nested.text, 'Subchapter')
                    else:
                        self.assertEqual(links, [(source.stem, 'book.xhtml')])
                    body = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                    self.assertEqual([section.get('id') for section in body.findall('.//h:section', namespace)],
                                     ['page-1', 'page-2', 'page-3'])
                    self.assertFalse(body.findall('.//h:h2', namespace))
                fb2 = source.with_suffix('.fb2')
                c.convert_book(source, fb2, tools_root=TOOLS)
                document = ET.parse(fb2).getroot()
                body = document.find('f:body', {'f': c.FB})
                chapters = [c.plain(node) for node in body.findall('.//f:title', {'f': c.FB})]
                self.assertEqual(chapters, expected)
                saved_outline = next((node for node in document.iter(f'{{{c.FB}}}custom-info')
                                      if node.get('info-type') == c.FB2_EPUB_OUTLINE), None)
                if expected:
                    self.assertEqual([row.split('\t',2)[2] for row in saved_outline.text.splitlines()], expected)
                else:
                    self.assertIsNone(saved_outline)

    def test_djvu_reports_unavailable_outline_destination_by_name(self):
        book = text_inputs.Book(c, self.root/'outline.djvu', set(), tools_root=TOOLS)

        def run(*args, **kwargs):
            return b'(bookmarks ("Chapter" "#1") ("Missing section" "#3"))'

        self.assertEqual(fixed.djvu_page_outline(book, run, 'djvused', 2), [(1, 'Chapter', 1)])
        [warning] = c.damaged_content_warnings(book.warnings)
        self.assertIn('DjVu. Пункты без доступной страницы — «Missing section»', warning)

    def test_djvu_external_bookmark_remains_in_outline_and_book(self):
        book = text_inputs.Book(c, self.root / 'outline.djvu', set(), tools_root=TOOLS)
        url = 'https://example.invalid/ref?a=1&b=2#section'

        def run(*args, **kwargs):
            return (f'(bookmarks ("Chapter" "#1" ("Reference" "{url}")) '
                    '("Other chapter" "#2") ("Broken bookmark" "https:///file"))').encode()

        book.page_outline = fixed.djvu_page_outline(book, run, 'djvused', 2)
        [warning] = c.damaged_content_warnings(book.warnings)
        self.assertIn('«Broken bookmark»', warning)
        self.assertNotIn('«Reference»', warning)
        for number in (1, 2):
            section = book.el('section', id=f'page-{number}')
            section.append(book.el('p', f'Original text on page {number}'))
            book.body.append(section)
        epub = self.root / 'web-bookmark.epub'
        book.finish(epub)
        namespace = {'h': c.XH}
        with zipfile.ZipFile(epub) as archive:
            nav = ET.fromstring(archive.read('OEBPS/nav.xhtml'))
            bookmark = nav.find('.//h:nav/h:ol/h:li/h:ol/h:li/h:a', namespace)
            self.assertEqual((bookmark.text, bookmark.get('href')), ('Reference', 'book.xhtml#outline-link-2'))
            text = ET.fromstring(archive.read('OEBPS/book.xhtml'))
            self.assertEqual(text.find('.//h:section[@id="outline-link-2"]//h:a', namespace).get('href'), url)
        fb2 = epub.with_suffix('.fb2')
        report = c.convert_book(epub, fb2)
        self.assertFalse(c.damaged_content_warnings(report['warnings']))
        text = ET.parse(fb2).getroot()
        c.validate_fb2_output(text)
        self.assertIn(url, [node.get(f'{{{c.XL}}}href') for node in text.iter(f'{{{c.FB}}}a')])
        outline = next(node for node in text.iter(f'{{{c.FB}}}custom-info') if node.get('info-type') == c.FB2_EPUB_OUTLINE)
        self.assertEqual([line.split('\t')[1:] for line in outline.text.splitlines()],
                         [['1', 'Chapter'], ['2', 'Reference'], ['1', 'Other chapter']])

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_large_pdf_with_wrong_suffix_preserves_text_and_images(self):
        source = self.root / 'large.3-pdf'
        write_large_pdf_fixture(source)
        with source.open('rb') as stream:
            expected = hashlib.file_digest(stream, 'sha256').hexdigest()
        output = self.root / 'large.epub'
        c.convert_book(source, output, tools_root=TOOLS, image_quality='maximum', grayscale=True)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            text = archive.read('OEBPS/book.xhtml')
            self.assertEqual(text.count(b'First readable paragraph'), 2)
            self.assertIn(b'Last paragraph preserves', text)
            self.assertTrue(any('/images/' in name for name in archive.namelist()))
        with source.open('rb') as stream:
            self.assertEqual(hashlib.file_digest(stream, 'sha256').hexdigest(), expected)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_actual_pdf_page_progress_and_atomic_cli_record(self):
        source = self.root / 'pages.pdf'; source.write_bytes(pdf_fixture())
        events = []
        c.convert_book(source, self.root/'direct.epub', tools_root=TOOLS,
                       progress=lambda *values: events.append(values))
        self.assertEqual(events[:3], [('pages', 0, 1), ('pages', 1, 1), ('finalizing', 0, 0)])
        self.assertEqual([event[0] for event in events[3:]],
                         ['writing-epub', 'writing-epub', 'checking-epub', 'checking-epub'])
        progress = self.root/'progress.json'; result = self.root/'cli.fb2'
        process = subprocess.run([sys.executable, '-I', '-B', str(ROOT/'convert_book.py'),
                                  str(source), str(result), '--tools-root', str(TOOLS),
                                  '--progress-file', str(progress)], capture_output=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stdout)
        record = json.loads(progress.read_text(encoding='utf-8'))
        self.assertGreater(record.pop('sequence'), 3)
        self.assertEqual(record, {'stage':'writing-fb2', 'completed':1, 'total':1})
        self.assertTrue(result.exists())
        self.assertFalse(list(self.root.glob('progress.json.*')))

    def test_pdf_line_end_hyphen_is_distinguished_from_invalid_control_code(self):
        api = object.__new__(fixed.PDF)
        original = 'inter\x02national and a genuinely invalid \x02 followed by an uncertain \x02.'
        api.FPDFText_LoadPage = lambda page: page
        api.FPDFText_CountChars = lambda text: len(original)
        api.FPDFText_GetUnicode = lambda text, index: ord(original[index])
        api.FPDFText_GetFontSize = lambda text, index: 8
        api.FPDFText_GetFontWeight = lambda text, index: 400
        api.FPDFText_HasUnicodeMapError = None

        def box(text, index, left, right, bottom, top):
            left._obj.value, right._obj.value = 1 + index * 4, 4 + index * 4
            bottom._obj.value, top._obj.value = 10, 18
            return 1

        api.FPDFText_GetCharBox = box
        api.FPDFText_ClosePage = lambda text: None
        api.FPDFText_IsHyphen = lambda text, index: {original.index('\x02'): 1, original.rindex('\x02'): -1}.get(index, 0)
        lines = api.page_lines(1, 400, 300)
        self.assertEqual([line['text'] for line in lines],
                         ['inter-national and a genuinely invalid � followed by an uncertain �.'])
        api.FPDFText_IsHyphen = None
        self.assertEqual([line['text'] for line in api.page_lines(1, 400, 300)], [original.replace('\x02', '�')])
        api.FPDFText_HasUnicodeMapError = lambda text, index: int(index == original.index('g'))
        self.assertEqual([line['text'] for line in api.page_lines(1, 400, 300)],
                         [original.replace('\x02', '�').replace('genuinely', '�enuinely')])
        original = 'A\ud83c\udf0d B\ud83c C\udf0d'
        api.FPDFText_HasUnicodeMapError = None
        self.assertEqual([line['text'] for line in api.page_lines(1, 400, 300)], ['A🌍 B� C�'])

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_pdf_recovers_readable_text_or_keeps_the_page_image(self):
        source = self.root/'unreadable-text-layer.pdf'
        original = pdf_fixture(pages=2)
        source.write_bytes(original)
        read_page_lines = fixed.PDF.page_lines

        layers = {'unavailable': None, 'sparse': 'Part of the text � is unreadable.', 'broken': '�' * 20 + ' unreadable'}
        for text_only, (kind, content) in product((False, True), layers.items()):
            with self.subTest(text_only=text_only, layer=kind):
                book = text_inputs.Book(c, source, set(), tools_root=TOOLS, omit_images=text_only)
                book.work_root = self.root
                calls = 0

                def read_lines(api, page, width, height):
                    nonlocal calls
                    calls += 1
                    if calls != 2:
                        return read_page_lines(api, page, width, height)
                    if content is None:
                        return None
                    first_line = read_page_lines(api, page, width, height)[0]
                    return [{**first_line, 'text': content}]

                with patch.object(fixed.PDF, 'page_lines', read_lines):
                    fixed.read_pdf(book, TOOLS)
                self.assertEqual(calls, 2)
                result = self.root / f'available-{text_only}-{kind}.epub'
                book.finish(result)
                with zipfile.ZipFile(result) as archive:
                    body = ET.fromstring(archive.read('OEBPS/book.xhtml'))
                    first = body.find(f'.//{{{c.XH}}}section[@id="page-1"]')
                    second = body.find(f'.//{{{c.XH}}}section[@id="page-2"]')
                    self.assertIn('First readable paragraph', c.plain(first))
                    if kind == 'sparse':
                        self.assertIn(content, c.plain(second))
                        originals = [image for image in second.findall(f'.//{{{c.XH}}}img')
                                     if image.get('alt') == 'Исходная строка PDF, страница 2']
                        self.assertEqual(len(originals), 0 if text_only else 1)
                        if originals:
                            original_line = archive.read('OEBPS/' + originals[0].get('src'))
                            image_width, image_height = struct.unpack('>II', original_line[16:24])
                            self.assertGreater(image_width, 50)
                            self.assertLess(image_height, 90)
                    elif text_only:
                        self.assertIn('Страница 2 без пригодного текстового слоя', c.plain(second))
                        self.assertFalse(second.findall(f'.//{{{c.XH}}}img'))
                    else:
                        image = second.find(f'.//{{{c.XH}}}img')
                        self.assertTrue(archive.read('OEBPS/' + image.get('src')).startswith(b'\x89PNG'))
                expected = ('текстовый слой страниц PDF: 2' if kind == 'unavailable' or (kind == 'broken' and text_only)
                            else 'символы PDF на страницах 2')
                [notice] = [warning for warning in c.damaged_content_warnings(book.warnings) if expected in warning]
                self.assertEqual('сохранены изображения исходных строк' in notice, kind == 'sparse' and not text_only)
                if kind == 'sparse' and not text_only:
                    fb2 = result.with_suffix('.fb2')
                    c.epub_to_fb2(result, fb2, set())
                    document = ET.parse(fb2).getroot()
                    pictures = [node for node in document.iter(f'{{{c.FB}}}image')
                                if node.get('alt') == 'Исходная строка PDF, страница 2']
                    [picture] = pictures
                    identity = picture.get(f'{{{c.XL}}}href').lstrip('#')
                    binary = document.find(f'{{{c.FB}}}binary[@id="{identity}"]')
                    self.assertEqual(base64.b64decode(binary.text), original_line)
        self.assertEqual(source.read_bytes(), original)

    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_pdf_text_only_keeps_reading_order_marks_missing_pages_and_cancels(self):
        source = self.root/'mixed.pdf'
        original = pdf_fixture(pages=2, image_only_last=True)
        source.write_bytes(original)
        output = self.root/'text.fb2'
        options = dict(tools_root=TOOLS, image_quality='none', text_layer_only=True)
        result = c.convert_book(source, output, **options)
        book = ET.fromstring(output.read_bytes())
        content = ''.join(book.itertext())
        expected = ['First readable paragraph', 'Last paragraph preserves', 'Страница 2 без пригодного текстового слоя']
        self.assertEqual([content.index(part) for part in expected], sorted(content.index(part) for part in expected))
        self.assertFalse(any(c.tag(node) in {'binary', 'image'} for node in book.iter()))
        self.assertTrue(any('Страниц без текста: 1' in warning and 'Выберите FB2 или EPUB' in warning
                            for warning in result['warnings']))
        self.assertEqual(source.read_bytes(), original)
        # Do not let the no-text marker become a successful empty book.
        source.write_bytes(pdf_fixture(text=False))
        with self.assertRaisesRegex(c.ConversionError, 'нет пригодного текстового слоя.*Выберите FB2 или EPUB'):
            c.convert_book(source, self.root/'scan.fb2', **options)
        self.assertFalse((self.root/'scan.fb2').exists())
        source.write_bytes(original)
        progress = []
        def cancel():
            if progress:
                raise InterruptedError('cancel')
        with self.assertRaises(InterruptedError):
            c.convert_book(source, self.root/'canceled.fb2', cancel_check=cancel,
                           progress=lambda *values: progress.append(values), **options)
        self.assertEqual(progress, [('pages', 0, 2)])
        self.assertFalse((self.root/'canceled.fb2').exists())
        self.assertFalse(list(self.root.glob('homelib-*')))

    def test_cli_progress_never_replaces_source_report_or_foreign_file(self):
        source = self.root/'source.txt'; source.write_text('Complete original text.', encoding='utf-8')
        foreign = self.root/'foreign.json'; foreign.write_text('Keep me.', encoding='utf-8')
        for number, (progress, extras) in enumerate([(source, []), (foreign, []),
                (self.root/'report.json', ['--report', str(self.root/'report.json')])]):
            output = self.root/f'output-{number}.epub'
            result = subprocess.run([sys.executable, '-I', '-B', str(ROOT/'convert_book.py'),
                str(source), str(output), '--progress-file', str(progress), *extras],
                capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
        self.assertEqual(source.read_text(), 'Complete original text.')
        self.assertEqual(foreign.read_text(), 'Keep me.')

    @unittest.skipUnless(os.name == 'nt', 'actual Windows sharing semantics')
    def test_progress_sharing_lock_preserves_last_record_and_recovers(self):
        progress=self.root/'progress.json'; progress.write_text('{"sequence":1}',encoding='utf-8')
        api=ctypes.WinDLL('kernel32',use_last_error=True)
        api.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,
                                 ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
        api.CreateFileW.restype=ctypes.c_void_p
        api.CloseHandle.argtypes=[ctypes.c_void_p]; api.CloseHandle.restype=ctypes.c_int
        # An unrelated reader omits FILE_SHARE_DELETE, reproducing a real
        # rename denial. Book conversion must not fail just for telemetry.
        handle=api.CreateFileW(str(progress),0x80000000,1|2,None,3,0x80,None)
        self.assertNotEqual(handle,ctypes.c_void_p(-1).value)
        try:
            self.assertFalse(c._write_progress(progress,'{"sequence":2}'))
            self.assertEqual(json.loads(progress.read_text()),{'sequence':1})
            self.assertFalse(list(self.root.glob('progress.json.*')))
        finally: api.CloseHandle(handle)
        self.assertTrue(c._write_progress(progress,'{"sequence":3}'))
        self.assertEqual(json.loads(progress.read_text()),{'sequence':3})
    @unittest.skipUnless(os.name == 'nt' and (TOOLS/'pdfium/pdfium.dll').is_file(), 'bundled Windows PDFium')
    def test_ocr_layer_and_image_only_pages_preserved(self):
        report, text, _ = self.convert('.pdf', pdf_fixture(ocr=True)); self.assertIn('First readable', text)
        self.assertTrue(any('OCR' in w for w in report['warnings']))
        source = self.root / 'scan.pdf'; source.write_bytes(pdf_fixture(text=False))
        report=c.convert_book(source, self.root / 'scan.epub', tools_root=TOOLS)
        with zipfile.ZipFile(self.root/'scan.epub') as archive:
            body=ET.fromstring(archive.read('OEBPS/book.xhtml'))
            self.assertEqual(len([n for n in body.iter() if c.tag(n)=='img']),1)
            self.assertIn('Страница 1',''.join(body.itertext()))
        self.assertTrue(any('OCR' in w and 'изображения' in w for w in report['warnings']))


if __name__ == '__main__': unittest.main()
