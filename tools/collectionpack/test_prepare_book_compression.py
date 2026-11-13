"""Selected books through actual image processing, 7-Zip and native commit."""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
from supervised_test_process import run_owned
import sys
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree
import zipfile

from archive_replacement import archive_inventory
from pack_collection import Canceled, PackingError, SevenZip, temporary_work_directory, process_working_directory
import prepare_book_compression as preparation
from prepare_book_compression import PreparedBookCompression, prepare_selected_file, profile_digest, verify_non_image_content
from test_pack_collection import image_fixture, illustrated_fb2, sha
import test_native_compression_receipt as native


SEVEN = Path(os.environ.get('HLRU_PACK_7ZIP', '../../Program/Out/Bin64/tools/7zip/7za.exe')).absolute()
TOOLS = os.environ.get('HLRU_PACK_IMAGE_TOOLS')
CLI_SCRIPT = os.environ.get('HL_SELECTED_PREPARER', preparation.__file__)


def epub(picture):
    result = io.BytesIO()
    with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        archive.writestr('META-INF/container.xml',
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            '<rootfile full-path="book.opf"/></rootfiles></container>')
        archive.writestr('book.opf', '''<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
<item id="pic" href="picture.png" media-type="image/png"/><item id="style" href="book.css" media-type="text/css"/>
<item id="font" href="font.ttf" media-type="application/x-font-truetype"/>
<item id="svg" href="drawing.svg" media-type="image/svg+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>''')
        archive.writestr('chapter.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="chapter">'
                         'Keep <em>this text</em> and <a href="#note">footnote</a>.</p><p id="note">Note</p>'
                         '<img src="picture.png"/><img src="drawing.svg"/></body></html>')
        archive.writestr('book.css', '@font-face {font-family: Book;src: url(font.ttf)} p {line-height:1.25}')
        archive.writestr('font.ttf', b'Preserve embedded font bytes exactly')
        archive.writestr('drawing.svg', '<svg xmlns="http://www.w3.org/2000/svg"><text>Keep vector text</text></svg>')
        archive.writestr('picture.png', picture)
    return result.getvalue()


class SelectedPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-selected-compression-')
        self.root = self.temp.__enter__()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.decoder = SevenZip(SEVEN, lambda: None)

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def source_zip(self, books):
        source = self.root / 'Книги ё.zip'
        with zipfile.ZipFile(source, 'w', zipfile.ZIP_STORED) as archive:
            archive.comment = b'Keep archive comments'
            for name, data in books.items():
                entry = zipfile.ZipInfo(name)
                entry.comment = b'Keep member comments'
                archive.writestr(entry, data)
        return source

    def decoded(self, candidate, name):
        target = self.root / ('decoded-' + str(len(list(self.root.glob('decoded-*')))))
        self.decoder.extract(candidate, name, target, self.root)
        return target.read_bytes()

    def prepare(self, source, members, **options):
        return prepare_selected_file(source, members, self.work, SEVEN, tools_root=TOOLS, **options)

    def deep_image_folder(self):
        folder = self.root / 'Проверка изображений ё'
        while len(str(folder)) < 310:
            folder /= 'Длинный путь с кириллицей ё'
        folder.mkdir(parents=True)
        return folder

    @unittest.skipUnless(os.name == 'nt' and TOOLS, 'Real Windows image helper required')
    def test_all_image_helper_modes_keep_short_and_long_path_results_equivalent(self):
        deep = self.deep_image_folder()
        helper = Path(TOOLS) / 'images/HomeLibImages.exe'
        picture = image_fixture()
        direct = self.root / 'picture.png'
        direct.write_bytes(picture)
        batch = self.root / 'pictures.zip'
        with zipfile.ZipFile(batch, 'w') as archive:
            archive.writestr('00000', picture)
        for number, (mode, source, options) in enumerate([
                ('--export-images', batch, ['balanced']),
                ('--scan-images', batch, ['balanced', 'keep']),
                ('--image-pages', direct, [])]):
            with self.subTest(mode=mode):
                long_source = deep / source.name
                long_source.write_bytes(source.read_bytes())
                results = []
                for folder, incoming in ((self.root, source), (deep, long_source)):
                    output = folder / ('image-result-' + str(number) + '.zip')
                    process = run_owned([str(helper), mode, str(incoming), str(output), *options],
                                        capture_output=True, encoding='utf-8', timeout=15)
                    self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                    with zipfile.ZipFile(output) as archive:
                        results.append({name: archive.read(name) for name in archive.namelist()})
                    self.assertEqual(incoming.read_bytes(), source.read_bytes())
                self.assertTrue(results[0])
                self.assertEqual(results[0], results[1])

    @unittest.skipUnless(os.name == 'nt' and TOOLS, 'Real Windows image helper required')
    def test_long_path_failed_image_output_is_removed_and_existing_output_is_kept(self):
        deep = self.deep_image_folder()
        helper = Path(TOOLS) / 'images/HomeLibImages.exe'
        source = deep / 'pictures.zip'
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('00000', image_fixture())
            archive.writestr('00001', b'A broken second image')
        before = source.read_bytes()
        output = deep / 'incomplete.zip'
        for mode, options in (('--export-images', ['balanced']), ('--scan-images', ['balanced', 'keep'])):
            with self.subTest(mode=mode):
                process = run_owned([str(helper), mode, str(source), str(output), *options],
                                    capture_output=True, encoding='utf-8', timeout=15)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn('IMAGE 1 2', process.stdout)
                self.assertFalse(output.exists(), process.stderr)
                output.write_bytes(b'Keep this pre-existing output')
                process = run_owned([str(helper), mode, str(source), str(output), *options],
                                    capture_output=True, encoding='utf-8', timeout=15)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(output.read_bytes(), b'Keep this pre-existing output')
                output.unlink()
                self.assertEqual(source.read_bytes(), before)

    @unittest.skipUnless(os.name == 'nt', 'Windows CreateProcess directory contract')
    def test_long_process_directory_alias_is_removed_without_touching_its_target(self):
        target = self.root
        while len(str(target)) < 310:
            target = target / ('Вложенная папка ё ' * 2 + 'конец')
        target.mkdir(parents=True)
        original = target / 'kept.txt'
        original.write_text('Исходник ё', encoding='utf-8')
        with self.assertRaises(Canceled):
            with process_working_directory(target) as child:
                alias = Path(child)
                self.assertLess(len(str(alias)), 248)
                self.assertEqual(alias.resolve(), target.resolve())
                process = run_owned([sys.executable, '-I', '-B', '-c',
                    "from pathlib import Path; assert Path('kept.txt').read_text(encoding='utf-8') == 'Исходник ё'"],
                    cwd=child, capture_output=True, timeout=10)
                self.assertEqual(process.returncode, 0, process.stderr)
                raise Canceled('Owned test cancellation')
        self.assertFalse(alias.exists())
        self.assertEqual(original.read_text(encoding='utf-8'), 'Исходник ё')

    def test_selected_reversible_books_preserve_all_payloads_names_and_comments(self):
        bodies = {'Русская книга.fb2': b'Keep all book bytes ' * 5000,
                  'next.txt': b'Keep the second selected book ' * 10000,
                  'neighbor.dat': os.urandom(100000)}
        source = self.source_zip(bodies)
        before = sha(source)
        events = []
        prepared = self.prepare(source, {'Русская книга.fb2': '.fb2', 'next.txt': '.txt'}, notify=events.append)
        space = next(e for e in events if e['stage'] == 'Оцениваем временное место')
        self.assertEqual(space['selected_bytes'], len(bodies['Русская книга.fb2']) + len(bodies['next.txt']))
        self.assertEqual(space['working_bytes'], prepared.working_bytes)
        self.assertIsNotNone(prepared.candidate)
        self.assertGreater(prepared.savings, 0)
        for name, body in bodies.items():
            self.assertEqual(self.decoded(prepared.candidate, name), body)
        with zipfile.ZipFile(prepared.candidate) as archive:
            self.assertEqual(archive.comment, b'Keep archive comments')
            self.assertTrue(all(entry.comment == b'Keep member comments' for entry in archive.infolist()))
        self.assertEqual(sha(source), before)
        self.assertEqual({p['member'] for p in prepared.payloads}, {'Русская книга.fb2', 'next.txt'})
        self.assertEqual(list(self.work.iterdir()), [Path(prepared.candidate)])

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_solid_archive_changes_only_selected_book(self):
        inputs = self.root / 'inputs'; inputs.mkdir()
        (inputs / 'one.fb2').write_bytes(illustrated_fb2(image_fixture()))
        neighbor = os.urandom(10000)
        (inputs / 'neighbor.txt').write_bytes(neighbor)
        source = self.root / 'solid.7z'
        self.decoder.run(['a', '-t7z', '-m0=LZMA2', '-ms=on', '-mmt=2', str(source),
                          'one.fb2', 'neighbor.txt'], cwd=inputs)
        before = sha(source)
        prepared = self.prepare(source, {'one.fb2': '.fb2'}, profile='economy')
        self.assertIsNotNone(prepared.candidate, prepared.books)
        self.assertTrue(prepared.books[0]['optimized'])
        self.assertEqual(self.decoded(prepared.candidate, 'neighbor.txt'), neighbor)
        self.assertEqual(sha(source), before)

    def test_random_payload_without_savings_does_not_leave_a_candidate(self):
        source = self.source_zip({'one.bin': os.urandom(128 * 1024)})
        before = sha(source)
        prepared = self.prepare(source, {'one.bin': '.bin'})
        self.assertIsNone(prepared.candidate)
        self.assertEqual(prepared.savings, 0)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_two_formats_keep_text_metadata_css_fonts_svg_and_neighbor(self):
        picture = image_fixture()
        fb2, ebook = illustrated_fb2(picture), epub(picture)
        source = self.source_zip({'one.fb2': fb2, 'two.epub': ebook, 'keep.txt': b'Neighbor stays'})
        prepared = self.prepare(source, {'one.fb2': '.fb2', 'two.epub': '.epub'}, profile='economy')
        self.assertEqual([b['optimized'] for b in prepared.books], [True, True], prepared.books)
        for name, original, extension in [('one.fb2', fb2, '.fb2'), ('two.epub', ebook, '.epub')]:
            decoded = self.root / ('result' + extension)
            decoded.write_bytes(self.decoded(prepared.candidate, name))
            before = self.root / ('before' + extension)
            before.write_bytes(original)
            verify_non_image_content(before, decoded, extension)
        self.assertEqual(self.decoded(prepared.candidate, 'keep.txt'), b'Neighbor stays')

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_mistyped_extension_uses_actual_epub_without_format_roundtrip(self):
        body = epub(image_fixture())
        source = self.source_zip({'wrong.fb2': body})
        prepared = self.prepare(source, {'wrong.fb2': '.fb2'}, profile='balanced')
        self.assertEqual(prepared.books[0]['format'], '.epub')
        self.assertTrue(prepared.books[0]['optimized'], prepared.books)
        output = self.decoded(prepared.candidate, 'wrong.fb2')
        with zipfile.ZipFile(io.BytesIO(output)) as archive:
            self.assertIn('chapter.xhtml', archive.namelist())
            self.assertEqual(archive.read('font.ttf'), b'Preserve embedded font bytes exactly')

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_original_quality_with_gray_keeps_dimensions_and_text(self):
        body = illustrated_fb2(image_fixture(transparent=True))
        source = self.root / 'Book.fb2'
        source.write_bytes(body)
        prepared = self.prepare(source, {'': '.fb2'}, profile='original', grayscale=True)
        self.assertIsNotNone(prepared.candidate, prepared.books)
        image = base64.b64decode(ElementTree.parse(prepared.candidate).find('.//{*}binary').text)
        import struct
        self.assertEqual(struct.unpack_from('>II', image, 16), (128, 96))
        self.assertEqual(''.join(ElementTree.parse(prepared.candidate).find('.//{*}p').itertext()), 'Keep this text.')
        self.assertEqual(source.read_bytes(), body)
        self.assertLess(prepared.output_bytes, prepared.input_bytes)

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_same_profile_reuses_image_bytes_and_only_processes_new_book(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture())})
        first = self.prepare(source, {'one.fb2': '.fb2'}, profile='maximum')
        optimized = self.decoded(first.candidate, 'one.fb2')
        ledger = {'one.fb2': dict(profile_sha256=first.profile_sha256,
                                   output_sha256=first.payloads[0]['output_sha256'])}
        second_source = self.root / 'updated.zip'
        with zipfile.ZipFile(second_source, 'w') as archive:
            archive.writestr('one.fb2', optimized)
            archive.writestr('new.fb2', illustrated_fb2(image_fixture()))
        second_work = self.root / 'second'; second_work.mkdir()
        second = prepare_selected_file(second_source, {'one.fb2': '.fb2', 'new.fb2': '.fb2'}, second_work,
                                       SEVEN, profile='maximum', tools_root=TOOLS, previous=ledger)
        self.assertTrue(second.books[0]['reused'])
        self.assertTrue(second.books[1]['optimized'])
        self.assertEqual(self.decoded(second.candidate, 'one.fb2'), optimized)

    def test_source_change_during_book_preparation_discards_candidate(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        changed = False
        def notify(event):
            nonlocal changed
            if event['stage'] == 'Подготавливаем выбранную книгу' and not changed:
                changed = True
                with source.open('ab') as stream: stream.write(b'external change')
        with self.assertRaisesRegex(PackingError, 'изменил'):
            self.prepare(source, {'one.txt': '.txt'}, notify=notify)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_cancel_before_preparation_keeps_source_and_workspace(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        before = sha(source)
        with self.assertRaises(Canceled):
            self.prepare(source, {'one.txt': '.txt'}, canceled=lambda: True)
        self.assertEqual(sha(source), before)
        self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_one_shot_image_cancel_is_not_swallowed_as_a_warning(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture())})
        before = sha(source)
        with patch('prepare_book_compression.Packer.optimize_book', side_effect=Canceled('stop once')):
            with self.assertRaises(Canceled):
                self.prepare(source, {'one.fb2': '.fb2'}, profile='economy')
        self.assertEqual(sha(source), before)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_non_image_formats_are_preserved_without_claiming_image_compression(self):
        body = b'%PDF-1.4\n' + os.urandom(10000)
        source = self.source_zip({'scan.pdf': body, 'keep.txt': b'Keep neighbor'})
        prepared = self.prepare(source, {'scan.pdf': '.pdf'})
        if prepared.candidate:
            self.assertEqual(self.decoded(prepared.candidate, 'scan.pdf'), body)
        self.assertFalse(prepared.books[0]['optimized'])
        self.assertEqual(prepared.payloads[0]['input_sha256'], prepared.payloads[0]['output_sha256'])

    def test_loose_original_file_does_not_grow_or_change_its_format(self):
        source = self.root / 'small.txt'
        source.write_text('Короткая книга ё', encoding='utf-8')
        before = source.read_bytes()
        prepared = self.prepare(source, {'': '.txt'})
        self.assertIsNone(prepared.candidate)
        self.assertEqual(prepared.input_bytes, prepared.output_bytes)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(list(self.work.iterdir()), [])

    def check_original_backup(self, prepared, bodies):
        saved = prepared.originals
        self.assertIsNotNone(saved)
        self.assertEqual(saved['sha256'], sha(Path(saved['path'])))
        self.assertEqual(saved['bytes'], Path(saved['path']).stat().st_size)
        self.assertEqual(saved['books'], len(bodies))
        with zipfile.ZipFile(saved['path']) as archive:
            raw = archive.read(preparation.OriginalBookBackup.MANIFEST)
            self.assertEqual(saved['manifest_sha256'], preparation.hashlib.sha256(raw).hexdigest())
            manifest = json.loads(raw)
            self.assertEqual(manifest['source_sha256'], prepared.source_sha256)
            self.assertEqual(manifest['source_bytes'], prepared.input_bytes)
            self.assertEqual({book['member'] for book in manifest['books']}, set(bodies))
            self.assertEqual(len(archive.infolist()), len(bodies) + 1)
            for book in manifest['books']:
                original = bodies[book['member']]
                self.assertEqual(archive.read(book['file']), original)
                self.assertEqual(book['sha256'], preparation.hashlib.sha256(original).hexdigest())
                self.assertEqual(book['bytes'], len(original))
        return manifest

    def test_backup_contains_exact_selected_originals_and_no_neighbor(self):
        bodies = {'Папка Ё/Book.txt': b'Upper case book' * 3000,
                  'Папка Ё/other.txt': b'Second selected book' * 3000,
                  'HomeLibre-originals.json': b'An actual book with a reserved-looking name' * 1000}
        source = self.source_zip(dict(bodies, **{'neighbor.bin': os.urandom(10000)}))
        before = sha(source)
        prepared = self.prepare(source, {name: '.txt' for name in bodies}, backup_originals=True)
        self.assertIsNotNone(prepared.candidate)
        manifest = self.check_original_backup(prepared, bodies)
        self.assertTrue(all(book['file'].startswith('books/') for book in manifest['books']))
        self.assertEqual(set(self.work.iterdir()), {Path(prepared.candidate), Path(prepared.originals['path'])})
        self.assertEqual(self.decoded(prepared.candidate, 'neighbor.bin'), self.decoded(source, 'neighbor.bin'))
        self.assertEqual(sha(source), before)

    def test_original_backup_keeps_case_sensitive_member_names_separate(self):
        source = self.root / 'original.txt'
        source.write_bytes(b'Exact book bytes')
        signature = preparation.book_signature(source, lambda: None)
        members = ['Part/Book.txt', 'Part/book.txt']
        with preparation.OriginalBookBackup(self.work, source, sha(source),
                                             preparation._source_stamp(source), lambda: None) as backup:
            for member in members:
                backup.add(source, member, signature)
            saved = backup.finish([dict(member=member, input_sha256=signature['payload_sha256'])
                                   for member in members])
            with zipfile.ZipFile(saved['path']) as archive:
                self.assertEqual(set(archive.namelist()),
                    {'books/Part/Book.txt', 'books/Part/book.txt', preparation.OriginalBookBackup.MANIFEST})
                self.assertEqual(archive.read('books/Part/Book.txt'), source.read_bytes())
                self.assertEqual(archive.read('books/Part/book.txt'), source.read_bytes())
        self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_backup_retains_color_originals_before_real_grayscale_compression(self):
        picture = image_fixture(transparent=True)
        bodies = {'one.fb2': illustrated_fb2(picture), 'two.epub': epub(picture)}
        source = self.source_zip(bodies)
        before = sha(source)
        prepared = self.prepare(source, {'one.fb2': '.fb2', 'two.epub': '.epub'},
                                profile='economy', grayscale=True, backup_originals=True)
        self.assertIsNotNone(prepared.candidate, prepared.books)
        self.check_original_backup(prepared, bodies)
        for name, body in bodies.items():
            self.assertNotEqual(self.decoded(prepared.candidate, name), body)
            initial, final = self.root / ('input-' + name), self.root / ('output-' + name)
            initial.write_bytes(body)
            final.write_bytes(self.decoded(prepared.candidate, name))
            verify_non_image_content(initial, final, Path(name).suffix)
        self.assertEqual(sha(source), before)

    def test_unnecessary_backup_and_candidate_are_discarded_when_no_gain(self):
        source = self.root / 'small.txt'
        source.write_text('Короткая книга ё', encoding='utf-8')
        before = sha(source)
        prepared = self.prepare(source, {'': '.txt'}, backup_originals=True)
        self.assertIsNone(prepared.candidate)
        self.assertIsNone(prepared.originals)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)

    def test_inspection_receipt_keeps_original_hash_size_and_no_discarded_image_history(self):
        source = self.root / 'small.txt'
        source.write_text('Checked original book ё', encoding='utf-8')
        prepared = self.prepare(source, {'': '.txt'})
        template = dict(schema=1, kind='HomeLibre book compression', source=str(source), rows=[dict(member='')])
        # A transformed image can have been discarded with a larger archive.
        prepared.payloads[0].update(output_sha256='f' * 64, size=1, image_outputs=['e' * 64])
        receipt = prepared.inspection_receipt(template)
        self.assertEqual(receipt['source_sha256'], receipt['result_sha256'])
        payload = receipt['payloads'][0]
        self.assertEqual(payload['input_sha256'], sha(source))
        self.assertEqual(payload['output_sha256'], sha(source))
        self.assertEqual(payload['size'], source.stat().st_size)
        self.assertEqual(payload['image_outputs'], [])
        self.assertTrue(payload['checked'])
        self.assertEqual(prepared.payloads[0]['image_outputs'], ['e' * 64])
        with self.assertRaises(PackingError):
            prepared.receipt(template)
        prepared.candidate = str(self.root / 'not-published.bin')
        with self.assertRaises(PackingError):
            prepared.inspection_receipt(template)

    def test_inspection_receipt_rejects_missing_original_sizes_or_wrong_selection(self):
        source = self.root / 'small.txt'
        source.write_text('Checked source', encoding='utf-8')
        prepared = self.prepare(source, {'': '.txt'})
        template = dict(schema=1, kind='HomeLibre book compression', source=str(source), rows=[dict(member='wrong')])
        with self.assertRaises(PackingError):
            prepared.inspection_receipt(template)
        template['rows'][0]['member'] = ''
        prepared.books.clear()
        with self.assertRaises(PackingError):
            prepared.inspection_receipt(template)

    def test_copied_original_is_not_mistaken_for_a_transformed_book(self):
        source = self.root / 'small.txt'
        source.write_text('Still original content', encoding='utf-8')
        body_sha = sha(source)
        ledger = {'': dict(profile_sha256=profile_digest('original', False),
                           retry_original=True, output_sha256=body_sha)}
        prepared = self.prepare(source, {'': '.txt'}, previous=ledger)
        self.assertFalse(prepared.books[0]['reused'])
        ledger['']['retry_original'] = False
        prepared = self.prepare(source, {'': '.txt'}, previous=ledger)
        self.assertTrue(prepared.books[0]['reused'])

    def test_cancel_during_original_copy_removes_partial_backup(self):
        source = self.source_zip({'one.txt': b'Book' * (1024 * 1024)})
        before, copying, checks = sha(source), False, 0
        def notify(event):
            nonlocal copying
            copying |= event['stage'] == 'Сохраняем оригинал выбранной книги'
        def canceled():
            nonlocal checks
            if copying:
                checks += 1
            return checks >= 4  # Stop after real ZIP payload bytes were written.
        with self.assertRaises(Canceled):
            self.prepare(source, {'one.txt': '.txt'}, backup_originals=True, notify=notify, canceled=canceled)
        self.assertEqual(sha(source), before)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_backup_write_failure_and_corruption_leave_source_unchanged(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        before = sha(source)
        for corruption in [False, True]:
            with self.subTest(corruption=corruption):
                original_validate = preparation.OriginalBookBackup.validate
                def validate(backup, manifest):
                    if corruption:
                        with Path(backup.path).open('r+b') as stream:
                            stream.seek(45)
                            stream.write(b'Corrupted backup entry')
                        return original_validate(backup, manifest)
                    raise OSError('Simulated full backup disk')
                with patch.object(preparation.OriginalBookBackup, 'validate', validate):
                    with self.assertRaises((OSError, PackingError, zipfile.BadZipFile)):
                        self.prepare(source, {'one.txt': '.txt'}, backup_originals=True)
                self.assertEqual(sha(source), before)
                self.assertEqual(list(self.work.iterdir()), [])

    def test_cli_backup_report_and_failed_publication_cleanup(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        before = sha(source)
        request, report = self.root / 'job.json', self.root / 'report.json'
        job = dict(version=1, source=str(source), members={'one.txt': '.txt'},
                   workspace=str(self.work), seven_zip=str(SEVEN), report=str(report), backup_originals=True,
                   receipt_template=dict(schema=1, kind='HomeLibre book compression', source=str(source),
                                         rows=[dict(member='one.txt')]))
        request.write_text(json.dumps(job), encoding='utf-8')
        process = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', CLI_SCRIPT, '--job', str(request)],
                                 capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        data = json.loads(report.read_text('utf-8'))
        data.pop('receipt')
        prepared = PreparedBookCompression(**data)
        self.check_original_backup(prepared, {'one.txt': b'Book' * 40000})
        preparation._discard_prepared(prepared)
        # A previous report must never be overwritten. The rejected second
        # publication must clean both its new archive and original-book backup.
        report_bytes = report.read_bytes()
        process = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', CLI_SCRIPT, '--job', str(request)],
                                 capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertEqual(report.read_bytes(), report_bytes)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)

    def test_backup_selection_requires_a_boolean_before_creating_files(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        for invalid in [1, 'yes', None]:
            with self.subTest(invalid=invalid), self.assertRaises(PackingError):
                self.prepare(source, {'one.txt': '.txt'}, backup_originals=invalid)
            self.assertEqual(list(self.work.iterdir()), [])

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_text_change_by_processor_keeps_original_book(self):
        body = illustrated_fb2(image_fixture())
        source = self.source_zip({'one.fb2': body})
        def tamper(processor, target, *_, **__):
            target.write_bytes(body.replace(b'Keep ', b'Changed '))
            return {'image_result': 'optimized'}
        with patch('prepare_book_compression.Packer.optimize_book', tamper):
            prepared = self.prepare(source, {'one.fb2': '.fb2'}, profile='maximum')
        self.assertFalse(prepared.books[0]['optimized'])
        self.assertFalse(prepared.books[0]['checked'])
        self.assertFalse(prepared.payloads[0]['checked'])
        self.assertTrue(prepared.payloads[0]['retry_original'])
        self.assertIn('текст', prepared.books[0]['reason'])
        if prepared.candidate:
            self.assertEqual(self.decoded(prepared.candidate, 'one.fb2'), body)

    @unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
    def test_skipped_image_result_preserves_original_and_remains_retryable(self):
        body = illustrated_fb2(image_fixture())
        source = self.root / 'one.fb2'
        source.write_bytes(body)
        def skipped(processor, target, *_, **__):
            target.write_bytes(b'An incomplete output must not survive')
            return dict(image_result='skipped', image_reason='temporary image failure')
        with patch('prepare_book_compression.Packer.optimize_book', skipped):
            prepared = self.prepare(source, {'': '.fb2'}, profile='maximum')
        self.assertIsNone(prepared.candidate)
        self.assertEqual(source.read_bytes(), body)
        self.assertFalse(prepared.books[0]['checked'])
        self.assertIn('temporary image failure', prepared.books[0]['reason'])
        template = dict(schema=1, kind='HomeLibre book compression', source=str(source), rows=[dict(member='')])
        payload = prepared.inspection_receipt(template)['payloads'][0]
        self.assertFalse(payload['checked'])
        self.assertTrue(payload['retry_original'])
        self.assertEqual(payload['output_sha256'], sha(source))
        self.assertEqual(payload['image_outputs'], [])

    def test_profile_and_receipt_cannot_select_other_book_or_source(self):
        with self.assertRaises(PackingError): profile_digest('jpeg-xl', False)
        source = self.source_zip({'one.txt': b'Book' * 40000})
        prepared = self.prepare(source, {'one.txt': '.txt'})
        with self.assertRaises(PackingError):
            prepared.receipt(dict(schema=1, kind='HomeLibre book compression', source=str(source),
                                  rows=[dict(member='other.txt')]))

    def test_fb2_vector_graphics_are_not_exempted_from_content_preservation(self):
        first, second = self.root / 'before.fb2', self.root / 'after.fb2'
        body = illustrated_fb2(image_fixture()).replace(b'</FictionBook>',
            b'<binary id="vector" content-type="image/svg+xml">' +
            base64.b64encode(b'<svg>Keep vector text</svg>') + b'</binary></FictionBook>')
        first.write_bytes(body)
        second.write_bytes(body.replace(base64.b64encode(b'<svg>Keep vector text</svg>'),
                                        base64.b64encode(b'<svg>Lost vector text</svg>')))
        with self.assertRaises(PackingError): verify_non_image_content(first, second, '.fb2')

    def test_archive_error_retains_readable_russian_path(self):
        with self.assertRaises(PackingError) as error:
            self.decoder.run(['l', str(self.root / 'Нет архива ё.zip')], cwd=self.root)
        self.assertIn('Нет архива ё.zip', str(error.exception))

    def test_bad_cli_receipt_does_not_publish_or_leave_a_candidate(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        before = sha(source)
        request = self.root / 'request.json'
        report = self.root / 'report.json'
        request.write_text(json.dumps(dict(version=1, source=str(source), members={'one.txt': '.txt'},
            workspace=str(self.work), seven_zip=str(SEVEN), report=str(report),
            receipt_template=dict(schema=1, kind='HomeLibre book compression', source=str(source),
                                  rows=[dict(member='wrong.txt')]))), encoding='utf-8')
        failed = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', CLI_SCRIPT, '--job', str(request)],
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertEqual(json.loads(failed.stdout.splitlines()[-1])['stage'], 'error')
        self.assertFalse(report.exists())
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)

    def test_cli_cancel_leaves_no_report_or_book_change(self):
        source = self.source_zip({'one.txt': b'Book' * 40000})
        before = sha(source)
        request, cancel, report = [self.root / name for name in ['job.json', 'cancel', 'report.json']]
        request.write_text(json.dumps(dict(version=1, source=str(source), members={'one.txt': '.txt'},
            workspace=str(self.work), seven_zip=str(SEVEN), report=str(report))), encoding='utf-8')
        cancel.touch()
        failed = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', CLI_SCRIPT, '--job', str(request), '--cancel', str(cancel)],
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(failed.returncode, 2, failed.stdout + failed.stderr)
        self.assertEqual(json.loads(failed.stdout.splitlines()[-1])['stage'], 'cancelled')
        self.assertFalse(report.exists())
        self.assertEqual(sha(source), before)


@unittest.skipUnless(TOOLS and native.NATIVE and native.NATIVE.is_file(), 'Native writer and image runtime required')
class NativeSelectedPipelineTests(unittest.TestCase):
    setUp = native.NativeCompressionReceiptTests.setUp
    tearDown = native.NativeCompressionReceiptTests.tearDown
    write_template = native.NativeCompressionReceiptTests.write_template
    snapshot = native.NativeCompressionReceiptTests.snapshot
    require_success = native.NativeCompressionReceiptTests.require_success

    def test_real_image_processing_archive_preparation_and_native_catalogue_apply(self):
        self.original_book = illustrated_fb2(image_fixture())
        with zipfile.ZipFile(self.source, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('one.fb2', self.original_book)
            archive.writestr('neighbor.fb2', self.neighbor)
        for path in [self.catalogue, self.personal]:
            with native.database(path) as db:
                db.execute('UPDATE Books SET BookSize=? WHERE BookID=101', (len(self.original_book),))
                if path == self.catalogue:
                    db.execute('UPDATE CatalogBookCopies SET BookSize=?', (len(self.original_book),))
        for row in self.template['rows']: row['old_size'] = len(self.original_book)
        before_c, before_p = self.snapshot(self.catalogue, False), self.snapshot(self.personal, False)
        work = self.root / 'prepared'; work.mkdir()
        request, report = self.root / 'request.json', self.root / 'prepared.json'
        request.write_text(json.dumps(dict(version=1, source=str(self.source), members={'one.fb2': '.fb2'},
            workspace=str(work), seven_zip=str(SEVEN), profile='economy', tools_root=TOOLS,
            receipt_template=self.template, report=str(report)), ensure_ascii=False), encoding='utf-8')
        process = run_owned([sys.executable, '-I', '-B', '-X', 'utf8', CLI_SCRIPT, '--job', str(request)],
                                 capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.require_success(process)
        data = json.loads(report.read_text('utf-8'))
        receipt = data.pop('receipt')
        prepared = PreparedBookCompression(**data)
        self.assertTrue(prepared.books[0]['optimized'], prepared.books)
        self.template = receipt
        self.write_template()
        self.candidate.unlink()
        Path(prepared.candidate).rename(self.candidate)
        source_key = self.source.stat().st_ino
        applied = run_owned([str(native.NATIVE), str(self.root), 'job-apply', '-'],
                                 capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.require_success(applied)
        self.assertEqual(self.source.stat().st_ino, source_key)
        self.assertEqual(sha(self.source), prepared.result_sha256)
        self.assertEqual(self.snapshot(self.catalogue, False), before_c)
        self.assertEqual(self.snapshot(self.personal, False), before_p)
        with native.database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0],
                             prepared.payloads[0]['size'])
        decoder = SevenZip(SEVEN, lambda: None)
        neighbor = self.root / 'checked-neighbor.fb2'
        decoder.extract(self.source, 'neighbor.fb2', neighbor, self.root)
        self.assertEqual(neighbor.read_bytes(), self.neighbor)
        self.assertFalse(list((self.root / 'queue').iterdir()))

    def test_native_history_keeps_old_picture_after_text_change_and_added_picture(self):
        self.test_real_image_processing_archive_preparation_and_native_catalogue_apply()
        decoder = SevenZip(SEVEN, lambda: None)
        extracted = self.root/'first-applied.fb2'
        decoder.extract(self.source,'one.fb2',extracted,self.root)
        compressed = extracted.read_bytes()
        root = ElementTree.fromstring(compressed)
        original_image = base64.b64decode(root.find('{*}binary').text)
        root.find('.//{*}p').text = 'Updated book text; keep the previous image bytes.'
        ElementTree.SubElement(root.find('.//{*}section'),'{http://www.gribuser.ru/xml/fictionbook/2.0}image',
            {'{http://www.w3.org/1999/xlink}href':'#new-picture'})
        ElementTree.SubElement(root,'{http://www.gribuser.ru/xml/fictionbook/2.0}binary',
            {'id':'new-picture','content-type':'image/png'}).text = base64.b64encode(image_fixture()).decode()
        changed = ElementTree.tostring(root,encoding='utf-8',xml_declaration=True)
        with zipfile.ZipFile(self.source,'w',zipfile.ZIP_STORED) as archive:
            archive.writestr('one.fb2',changed); archive.writestr('neighbor.fb2',self.neighbor)
        with native.database(self.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=101',(len(changed),))
            db.execute('UPDATE CatalogBookCopies SET BookSize=?',(len(changed),))
        with native.database(self.personal) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=101 AND DatabaseID=7',(len(changed),))
        for row in self.template['rows']: row['old_size']=len(changed)
        before_c,before_p=self.snapshot(self.catalogue,False),self.snapshot(self.personal,False)
        workspace=self.root/'second-preparation'; workspace.mkdir()
        result=prepare_selected_file(self.source,{'one.fb2':'.fb2'},workspace,SEVEN,
            tools_root=TOOLS,profile='economy',image_history_database=self.catalogue)
        self.assertIsNotNone(result.candidate,result.books)
        self.assertEqual(result.books[0]['images_reused'],1)
        self.assertEqual(result.books[0]['images_processed'],1)
        self.template=result.receipt(self.template); self.write_template()
        self.candidate.unlink(missing_ok=True); Path(result.candidate).rename(self.candidate)
        applied=run_owned([str(native.NATIVE),str(self.root),'job-apply','-'],
            capture_output=True,text=True,encoding='utf-8',timeout=30)
        self.require_success(applied)
        self.assertEqual(self.snapshot(self.catalogue,False),before_c)
        self.assertEqual(self.snapshot(self.personal,False),before_p)
        extracted = self.root/'second-applied.fb2'
        decoder.extract(self.source,'one.fb2',extracted,self.root)
        final=ElementTree.fromstring(extracted.read_bytes())
        neighbor=self.root/'second-neighbor.fb2'
        decoder.extract(self.source,'neighbor.fb2',neighbor,self.root)
        self.assertEqual(neighbor.read_bytes(),self.neighbor)
        self.assertEqual(base64.b64decode(final.find('{*}binary').text),original_image)
        self.assertIn('Updated book text',final.find('.//{*}p').text)
        self.assertFalse(list((self.root/'queue').iterdir()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
