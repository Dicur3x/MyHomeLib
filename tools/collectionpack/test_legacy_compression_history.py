"""Transfer verified image history from the earlier copy-based collection packer."""
import json
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET

from pack_collection import Packer, temporary_work_directory
from pack_collection import Canceled, PackingError, SevenZip
from compression_image_history import CompressedImageHistory
from estimate_book_compression import estimate_selected_file
from prepare_book_compression import prepare_selected_file, profile_digest
from test_pack_collection import database, illustrated_fb2, image_fixture, sha
from test_prepare_book_compression import epub

TOOLS = os.environ.get('HLRU_PACK_IMAGE_TOOLS')
SEVEN = Path(os.environ.get('HLRU_PACK_7ZIP', '../../Program/Out/Bin64/tools/7zip/7za.exe')).absolute()


@unittest.skipUnless(TOOLS and SEVEN.is_file(), 'Real image and archive codecs required')
class LegacyCompressionHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-legacy-history-')
        self.root = self.temp.__enter__()

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def legacy_book(self, extension):
        source = self.root / ('original' + extension)
        source.write_bytes(illustrated_fb2(image_fixture()) if extension == '.fb2' else epub(image_fixture()))
        output = self.root / ('old-' + extension[1:])
        plan = self.root / ('plan-' + extension[1:] + '.sqlite')
        with database(plan) as db:
            db.executescript('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);'
                'CREATE TABLE books(book_id INTEGER PRIMARY KEY,source TEXT,member TEXT,locator TEXT,'
                'filename TEXT,ext TEXT,inside_no INTEGER);CREATE INDEX source_books ON books(source);')
            db.executemany('INSERT INTO metadata VALUES(?,?)', [('api', '1'), ('dataset', 'legacy-fixture')])
            db.execute('INSERT INTO books VALUES(?,?,?,?,?,?,?)',
                (1, str(source), '', source.name, source.stem, extension, 0))
        result = Packer(dict(version=1, dataset='legacy-fixture', engine='illustrations-ppmd',
            images='maximum', plan=str(plan), output=str(output), seven_zip=str(SEVEN), tools_root=TOOLS)).execute()
        self.assertEqual(result.image_books_optimized, 1)
        with database(output / 'generations' / result.generation / 'locations.sqlite') as db:
            folder, filename, ext = db.execute('SELECT folder,filename,ext FROM locations WHERE book_id=1').fetchone()
        catalogue = output / 'collection.hlc2'
        with database(catalogue) as db:
            db.execute('CREATE TABLE HomeLibPackingState(Key TEXT PRIMARY KEY,Value TEXT NOT NULL)')
            db.executemany('INSERT INTO HomeLibPackingState VALUES(?,?)',
                [('dataset', 'legacy-fixture'), ('engine', 'illustrations-ppmd'), ('images', 'maximum')])
        return output / folder, filename + ext, catalogue

    def watch_encoder(self, calls):
        original = subprocess.Popen
        def observe(arguments, *args, **kwargs):
            if isinstance(arguments, (tuple, list)) and '--export-images' in arguments:
                calls.append(list(arguments))
            return original(arguments, *args, **kwargs)
        return patch('subprocess.Popen', observe)

    def watch_processor(self, calls):
        original = Packer.optimize_book
        def observe(processor, *args, **kwargs):
            calls.append(str(args[0]))
            return original(processor, *args, **kwargs)
        return patch.object(Packer, 'optimize_book', observe)

    def test_actual_legacy_fb2_and_epub_outputs_are_not_encoded_again(self):
        for extension in ('.fb2', '.epub'):
            with self.subTest(extension=extension):
                archive, member, catalogue = self.legacy_book(extension)
                files = (archive, catalogue, catalogue.parent / 'packing.sqlite',
                         catalogue.parent / 'HomeLibRu-compressed.json')
                before = {p: sha(p) for p in files}
                work = self.root / ('prepare-' + extension[1:]); work.mkdir()
                calls, attempts = [], []
                with self.watch_encoder(calls), self.watch_processor(attempts):
                    result = prepare_selected_file(archive, {member: extension}, work, SEVEN,
                        tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
                self.assertEqual({p: sha(p) for p in files}, before)
                self.assertEqual(attempts, [], 'A verified legacy output entered image processing again')
                self.assertEqual(calls, [], 'A verified legacy output was encoded a second time')
                self.assertTrue(result.books[0]['reused'], result.books)
                self.assertEqual(result.payloads[0]['input_sha256'], result.payloads[0]['output_sha256'])
                self.assertTrue(result.payloads[0]['image_outputs'])

    def test_estimate_recognizes_legacy_output_without_processing_images(self):
        archive, member, catalogue = self.legacy_book('.epub')
        work = self.root / 'estimate'; work.mkdir()
        calls = []
        before = {p: sha(p) for p in (archive, catalogue, catalogue.parent / 'packing.sqlite')}
        with self.watch_encoder(calls):
            result = estimate_selected_file(archive, {member: '.epub'}, work, SEVEN,
                tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
        self.assertEqual(calls, [])
        self.assertTrue(result['books'][0]['exact'], result)
        self.assertIn('Уже сжата', result['books'][0]['reason'])
        self.assertEqual(result['known_input_bytes'], result['known_output_bytes'])
        self.assertEqual({p: sha(p) for p in before}, before)
        self.assertEqual(list(work.iterdir()), [])

    def test_profile_or_grayscale_change_does_not_reuse_legacy_quality(self):
        archive, member, catalogue = self.legacy_book('.fb2')
        for profile, gray in (('balanced', False), ('maximum', True)):
            with self.subTest(profile=profile, grayscale=gray):
                with CompressedImageHistory(catalogue, profile_digest(profile, gray)) as history:
                    self.assertEqual(history.legacy_books(archive, {member: '.fb2'}, profile, gray), {})

    def test_foreign_dataset_fails_before_any_book_or_journal_write(self):
        archive, member, catalogue = self.legacy_book('.fb2')
        marker = catalogue.parent / 'HomeLibRu-compressed.json'
        value = json.loads(marker.read_text(encoding='utf-8-sig')); value['dataset'] = 'another-copy'
        marker.write_text(json.dumps(value), encoding='utf-8')
        before = {p: sha(p) for p in (archive, catalogue, marker, catalogue.parent / 'packing.sqlite')}
        work = self.root / 'prepare'; work.mkdir()
        with self.assertRaisesRegex(PackingError, 'историю прежней'):
            prepare_selected_file(archive, {member: '.fb2'}, work, SEVEN,
                tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
        self.assertEqual({p: sha(p) for p in before}, before)
        self.assertEqual(list(work.iterdir()), [])

    def test_legacy_member_hash_is_checked_against_actual_extracted_bytes(self):
        archive, member, catalogue = self.legacy_book('.fb2')
        journal = catalogue.parent / 'packing.sqlite'
        with database(journal) as db:
            folder, encoded = db.execute('SELECT folder,members FROM payloads').fetchone()
            entries = json.loads(encoded)
            for entry in entries.values():
                entry['payload_sha256'] = '0' * 64
            db.execute('UPDATE payloads SET members=? WHERE folder=?', (json.dumps(entries), folder))
        before = {p: sha(p) for p in (archive, catalogue, journal)}
        work = self.root / 'prepare'; work.mkdir()
        attempts = []
        with self.watch_processor(attempts):
            result = prepare_selected_file(archive, {member: '.fb2'}, work, SEVEN,
                tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
        self.assertFalse(result.books[0]['reused'], result.books)
        self.assertEqual(len(attempts), 1)
        self.assertEqual({p: sha(p) for p in before}, before)

    def test_cancellation_during_legacy_lookup_preserves_inputs(self):
        archive, member, catalogue = self.legacy_book('.fb2')
        before = {p: sha(p) for p in (archive, catalogue, catalogue.parent / 'packing.sqlite')}
        with CompressedImageHistory(catalogue, profile_digest('maximum', False)) as history:
            calls = 0
            def stop():
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise Canceled('stop while reading legacy members')
            history.check = stop
            with self.assertRaises(Canceled):
                history.legacy_books(archive, {member: '.fb2'}, 'maximum', False)
            self.assertEqual(calls, 2)
        self.assertEqual({p: sha(p) for p in before}, before)

    def test_imported_raster_witness_preserves_old_picture_after_a_text_update(self):
        archive, member, catalogue = self.legacy_book('.fb2')
        work = self.root / 'first'; work.mkdir()
        first = prepare_selected_file(archive, {member: '.fb2'}, work, SEVEN,
            tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
        # The native receipt owns this write. Its generic image-hash commit is
        # covered separately; here exercise the new legacy-to-image contract.
        with database(catalogue) as db:
            db.execute('CREATE TABLE HomeLibreCompressedImages(ProfileSHA256 TEXT,ImageSHA256 TEXT,'
                       'PRIMARY KEY(ProfileSHA256,ImageSHA256)) WITHOUT ROWID')
            db.executemany('INSERT INTO HomeLibreCompressedImages VALUES(?,?)',
                [(first.profile_sha256, value) for value in first.payloads[0]['image_outputs']])
        extracted = self.root / 'extracted.fb2'
        SevenZip(SEVEN, lambda: None).extract(archive, member, extracted, self.root)
        root = ET.fromstring(extracted.read_bytes())
        old = base64.b64decode(root.find('{*}binary').text)
        root.find('.//{*}p').text = 'Новое издание с прежней иллюстрацией.'
        section = root.find('.//{*}section')
        ET.SubElement(section, '{http://www.gribuser.ru/xml/fictionbook/2.0}image',
            {'{http://www.w3.org/1999/xlink}href': '#new'})
        ET.SubElement(root, '{http://www.gribuser.ru/xml/fictionbook/2.0}binary',
            {'id': 'new', 'content-type': 'image/png'}).text = base64.b64encode(image_fixture()).decode()
        extracted.write_bytes(ET.tostring(root, encoding='utf-8', xml_declaration=True))
        work = self.root / 'second'; work.mkdir()
        result = prepare_selected_file(extracted, {'': '.fb2'}, work, SEVEN,
            tools_root=TOOLS, profile='maximum', image_history_database=catalogue)
        self.assertEqual(result.books[0]['images_reused'], 1, result.books)
        self.assertEqual(result.books[0]['images_processed'], 1, result.books)
        self.assertIsNotNone(result.candidate)
        changed = ET.parse(result.candidate).getroot()
        self.assertEqual(base64.b64decode(changed.find('{*}binary').text), old)


if __name__ == '__main__':
    unittest.main(verbosity=2)
