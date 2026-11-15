"""Real format detection, publication and readback with wrong catalogue suffixes."""
import io
import json
import os
from pathlib import Path
import random
import unittest
from xml.etree import ElementTree as ET
import zipfile

import test_native_compression_operation as operations
from test_native_compression_receipt import database, png, sha
from test_prepare_book_compression import epub
from validate_catalogue_compression import archive_body


@unittest.skipUnless(os.name=='nt' and operations.OPERATOR and operations.OPERATOR.is_file()
                     and operations.RUNTIME and operations.RUNTIME.is_dir(),
                     'Built native operation and private packaged runtime required')
class MislabeledCompressionTests(unittest.TestCase):
    def setUp(self):
        self.operation = operations.NativeCompressionOperationTests()
        self.operation.setUp()
        self.addCleanup(self.operation.tearDown)

    def seed(self, body, hint):
        op = self.operation
        self.member = 'one' + hint
        with zipfile.ZipFile(op.fixture.source, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr(self.member, body)
            archive.writestr('neighbor.fb2', op.fixture.neighbor)
        op.config['selected'][0]['ext'] = hint
        with database(op.fixture.catalogue) as db:
            db.execute('UPDATE Books SET Ext=?,BookSize=? WHERE BookID=101', (hint,len(body)))
            db.execute('UPDATE CatalogBookCopies SET Ext=?,BookSize=?', (hint,len(body)))
        with database(op.fixture.personal) as db:
            db.execute('UPDATE Books SET Ext=?,BookSize=? WHERE DatabaseID=7', (hint,len(body)))
        self.before_catalogue = op.fixture.snapshot(op.fixture.catalogue, sizes=False)
        self.before_personal = op.fixture.snapshot(op.fixture.personal, sizes=False)
        op.config.update(profile='economy', grayscale=True)
        self.backup = op.enable_backup()
        self.observed = op.observe_updated_engine()
        self.source_hash = sha(op.fixture.source.read_bytes())
        return op

    def finish(self, op, original, actual_format, transformed):
        result = op.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['changed_files'], int(transformed), result)
        self.assertEqual(result['pending_after_ack'], 0, result)
        report, = json.loads(self.observed.read_text(encoding='utf-8'))
        self.assertEqual(report['format'], actual_format, report)
        self.assertEqual(report['optimized'], transformed, report)
        self.assertTrue(report['checked'], report)
        body = archive_body(op.fixture.source, self.member, op.config['seven_zip'])
        if transformed:
            self.assertNotEqual(sha(body), sha(original))
            self.assertLess(len(body), len(original))
        else:
            self.assertEqual(body, original)
        self.assertEqual(archive_body(op.fixture.source, 'neighbor.fb2', op.config['seven_zip']), op.fixture.neighbor)
        self.assertEqual(op.fixture.snapshot(op.fixture.catalogue, sizes=False), self.before_catalogue)
        self.assertEqual(op.fixture.snapshot(op.fixture.personal, sizes=False), self.before_personal)
        with database(op.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0], len(body))
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], len(body))
        with database(op.fixture.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], len(body))
        backups = list(self.backup.glob('*.zip'))
        self.assertEqual(len(backups), int(transformed))
        if transformed:
            with zipfile.ZipFile(backups[0]) as archive:
                self.assertEqual(archive.read('books/'+self.member), original)
        else:
            self.assertEqual(sha(op.fixture.source.read_bytes()), self.source_hash)
        op.config['operation_mode'] = 'book-stream'
        restored = op.run_operation()
        self.assertEqual(restored['error'], '', restored)
        self.assertEqual(Path(restored['book_stream']).read_bytes(), body)
        op.config['operation_mode'] = 'apply'
        before = {p:sha(p.read_bytes()) for p in (op.fixture.source,op.fixture.catalogue,op.fixture.personal,*backups)}
        repeated = op.run_operation()
        self.assertEqual(repeated['error'], '', repeated)
        self.assertEqual(repeated['changed_files'], 0, repeated)
        self.assertEqual({p:sha(p.read_bytes()) for p in before}, before)
        if transformed:
            # A new engine identity must still detect the actual format while
            # reusing the already-transformed bytes, without another encode.
            worker = Path(op.config['script'])
            worker.write_bytes(worker.read_bytes()+b'\n# New private engine revision for format readback.\n')
            upgraded = op.run_operation()
            self.assertEqual(upgraded['error'], '', upgraded)
            self.assertEqual(upgraded['changed_files'], 0, upgraded)
            current, = json.loads(self.observed.read_text(encoding='utf-8'))
            self.assertEqual(current['format'], actual_format, current)
            self.assertTrue(current['reused'], current)
            self.assertEqual(current['images_processed'], 0, current)
            self.assertEqual(sha(op.fixture.source.read_bytes()), before[op.fixture.source])
            self.assertEqual(sha(op.fixture.personal.read_bytes()), before[op.fixture.personal])
            self.assertEqual(sha(backups[0].read_bytes()), before[backups[0]])
            self.assertEqual(len(list(self.backup.glob('*.zip'))), 1)
            self.assertEqual(op.fixture.snapshot(op.fixture.catalogue, sizes=False), self.before_catalogue)
        return body

    def test_epub_with_fb2_suffix_keeps_all_non_image_resources_and_reads(self):
        original = epub(self.picture())
        op = self.seed(original, '.fb2')
        body = self.finish(op, original, '.epub', True)
        with zipfile.ZipFile(io.BytesIO(original)) as before, zipfile.ZipFile(io.BytesIO(body)) as after:
            self.assertEqual(before.namelist(), after.namelist())
            for name in before.namelist():
                if name not in ('picture.png','book.opf'): self.assertEqual(before.read(name), after.read(name), name)
            old,new = ET.fromstring(before.read('book.opf')),ET.fromstring(after.read('book.opf'))
            for tree in (old,new):
                for node in tree.iter():
                    if node.tag.rsplit('}',1)[-1]=='item' and node.get('href')=='picture.png':
                        if tree is new:
                            self.assertEqual(node.get('media-type'), 'image/jpeg' if after.read('picture.png').startswith(b'\xff\xd8') else 'image/png')
                        node.attrib.pop('media-type', None)
            self.assertEqual(ET.tostring(old), ET.tostring(new))

    def picture(self):
        return png(False, random.Random(451).randbytes(128*128))

    def test_utf16_fb2_with_epub_suffix_keeps_xml_and_reads(self):
        source = self.operation.fixture.original_book.decode('utf-8')
        source = source.replace('Same book text;', 'Кириллица Ё, заметка;')
        original = ('<?xml version="1.0" encoding="UTF-16"?>'+source).encode('utf-16')
        op = self.seed(original, '.epub')
        body = self.finish(op, original, '.fb2', True)
        old,new = ET.fromstring(original),ET.fromstring(body)
        for tree in (old,new):
            for binary in tree.iter('{http://www.gribuser.ru/xml/fictionbook/2.0}binary'):
                binary.text = ''
                binary.attrib.pop('content-type', None)
        self.assertEqual(ET.tostring(old), ET.tostring(new))

    def test_rtf_with_fb2_suffix_reports_actual_format_and_preserves_payload(self):
        original = b'{\\rtf1\\ansi Exact RTF text and formatting. {\\b Keep bold.}}'
        op = self.seed(original, '.fb2')
        self.finish(op, original, '.rtf', False)
