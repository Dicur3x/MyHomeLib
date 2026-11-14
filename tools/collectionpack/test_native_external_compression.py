"""The actual native operation publishes complete FLibrary books and sidecars."""
import base64
import json
import os
import random
import shutil
from xml.etree import ElementTree as ET
import zipfile

from supervised_test_process import run_owned
from test_native_compression_operation import NativeCompressionOperationTests, OPERATOR
from test_native_compression_receipt import database, png, sha


class NativeExternalCompressionTests(NativeCompressionOperationTests):
    # Inherit the fixture, not the ordinary-archive test matrix.
    def test_flibrary_selected_book_commits_images_full_sizes_backup_and_incremental_checks(self):
        self.check_flibrary_pipeline('books.7z')

    def test_flibrary_7z_named_zip_uses_the_same_complete_pipeline(self):
        self.check_flibrary_pipeline('books.zip')

    def test_full_book_recovers_after_partial_group_preparation(self):
        self.check_flibrary_pipeline('books.7z', 'group-file-prepared-0')

    def test_full_book_recovers_after_a_partial_image_write(self):
        self.check_flibrary_pipeline('books.7z', 'group-file-1-half-metadata')

    def test_full_book_recovers_after_catalogue_commit(self):
        self.check_flibrary_pipeline('books.7z', 'catalogue-committed')

    def check_flibrary_pipeline(self, container_name, fault_stage=None):
        original = (b'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
            b'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Book</book-title>'
            b'<coverpage><image l:href="#cover"/></coverpage></title-info></description>'
            b'<body><section><p>Keep every word and every image link.</p><image l:href="#1"/>'
            b'</section></body></FictionBook>')
        stage = self.root / 'outer-input'
        stage.mkdir()
        (stage / 'one.fb2').write_bytes(original)
        self.fixture.neighbor = (b'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
            b'<body><section><p>Keep neighbor text.</p></section></body></FictionBook>')
        (stage / 'neighbor.fb2').write_bytes(self.fixture.neighbor)
        self.fixture.source.unlink()
        self.fixture.source = self.root / container_name
        self.config['selected'][0]['folder'] = container_name
        with database(self.fixture.catalogue) as db:
            db.execute('UPDATE Books SET Folder=?', (container_name,))
            db.execute('UPDATE CatalogBookCopies SET Folder=?', (container_name,))
        with database(self.fixture.personal) as db:
            db.execute('UPDATE Books SET Folder=? WHERE DatabaseID=7', (container_name,))
        process = run_owned([self.config['seven_zip'], 'a', '-t7z', '-mx=9', '-y', '--',
            str(self.fixture.source), 'one.fb2', 'neighbor.fb2'], cwd=stage, capture_output=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        pixels = random.Random(148).randbytes(128*128)
        picture = png(False, pixels)
        sides = []
        for folder, selected in [('covers', 'one'), ('images', 'one/1')]:
            path = self.root / folder / 'books.zip'
            path.parent.mkdir()
            with zipfile.ZipFile(path, 'x', zipfile.ZIP_STORED) as archive:
                archive.writestr(selected, picture)
                archive.writestr('neighbor' if folder == 'covers' else 'neighbor/1', b'Keep neighbor image')
            sides.append(path)
        before_size = sum(p.stat().st_size for p in [self.fixture.source, *sides])
        backup = self.enable_backup()
        self.config.update(profile='maximum', grayscale=True)
        if fault_stage:
            self.config['fault_at'] = fault_stage
            self.request.write_text(json.dumps(self.config), encoding='utf-8')
            crashed = run_owned([str(OPERATOR), str(self.request), str(self.result)], capture_output=True,
                                encoding='utf-8', timeout=45)
            self.assertEqual(crashed.returncode, 73, crashed.stdout+crashed.stderr)
            self.assertIn('TRACE terminated at '+fault_stage, crashed.stdout)
            self.config.pop('fault_at')
            self.config['operation_mode'] = 'recover'
        result = self.run_operation()
        self.config['operation_mode'] = 'apply'
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['changed_files'], 1, result)
        self.assertEqual(result['pending_after_ack'], 0, result)
        if not fault_stage:
            self.assertEqual(result['saved_bytes'], before_size-sum(p.stat().st_size for p in [self.fixture.source, *sides]))
        for path in sides:
            with zipfile.ZipFile(path) as archive:
                name = 'neighbor' if path.parent.name == 'covers' else 'neighbor/1'
                self.assertEqual(archive.read(name), b'Keep neighbor image')
        saved = list(backup.glob('*.zip'))
        self.assertEqual(len(saved), 1)
        with zipfile.ZipFile(saved[0]) as archive:
            full = archive.read('books/one.fb2')
            tree = ET.fromstring(full)
            ns = {'f': 'http://www.gribuser.ru/xml/fictionbook/2.0'}
            images = {n.attrib['id']: base64.b64decode(n.text) for n in tree.findall('f:binary', ns)}
            self.assertEqual(images, {'cover': picture, '1': picture})
        with database(self.fixture.catalogue) as db:
            size = db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0]
            self.assertGreater(size, len(original))
            self.assertLess(size, len(full))
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], size)
            self.assertEqual(db.execute('SELECT count(*) FROM HomeLibreCompressedImages').fetchone()[0], 1)
        with database(self.fixture.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], size)
        if fault_stage:
            return
        checked = {path: sha(path.read_bytes()) for path in
                   (self.fixture.catalogue, self.fixture.personal, self.fixture.source, *sides)}
        second = self.run_operation()
        self.assertEqual(second['error'], '', second)
        self.assertEqual(second['changed_files'], 0, second)
        self.assertEqual(second['unchanged_files'], 1, second)
        self.assertEqual(checked, {path: sha(path.read_bytes()) for path in checked},
                         'A repeated compression rewrote the source or verification history')
        self.check_index_sizes(size, sides[0], container_name)
        self.check_same_stamp_damage_is_not_skipped(sides[0])
        stamp = sides[0].stat()
        os.utime(sides[0], ns=(stamp.st_atime_ns, stamp.st_mtime_ns+1000000000))
        rechecked = self.run_operation()
        self.assertEqual(rechecked['error'], '', rechecked)
        self.assertEqual(rechecked['changed_files'], 0, rechecked)
        self.assertEqual(rechecked['unchanged_files'], 1, rechecked)
        # A newly downloaded cover invalidates the dependency witness even
        # though the book archive and every stripped book byte stayed exact.
        with zipfile.ZipFile(sides[0], 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('one', png(False, random.Random(149).randbytes(128*128)))
            archive.writestr('neighbor', b'Keep neighbor image')
        self.config.update(whole=True, only_new=True)
        third = self.run_operation()
        self.assertEqual(third['error'], '', third)
        self.assertEqual(third['changed_files'], 1, third)

    def check_same_stamp_damage_is_not_skipped(self, image_archive):
        saved = image_archive.read_bytes()
        stamp = image_archive.stat()
        with zipfile.ZipFile(image_archive) as archive:
            entry = archive.getinfo('one')
            # Damage selected compressed image bytes, preserving the ZIP
            # directory, native file key, total length and last-write time.
            start = entry.header_offset
            name_size = int.from_bytes(saved[start+26:start+28], 'little')
            extra_size = int.from_bytes(saved[start+28:start+30], 'little')
            offset = start+30+name_size+extra_size+max(1, entry.compress_size//2)
        bad = bytearray(saved)
        bad[offset] ^= 128
        image_archive.write_bytes(bad)
        os.utime(image_archive, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        before = {path: sha(path.read_bytes()) for path in (self.fixture.catalogue, self.fixture.personal)}
        try:
            rejected = self.run_operation()
            self.assertNotEqual(rejected['error'], '', rejected)
            self.assertEqual(rejected['changed_files'], 0, rejected)
            self.assertEqual(before, {path: sha(path.read_bytes()) for path in before})
        finally:
            image_archive.write_bytes(saved)
            os.utime(image_archive, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))

    def check_index_sizes(self, expected, image_archive, container_name):
        saved_config = self.config
        saved = image_archive.read_bytes()
        stamp = image_archive.stat()
        other = self.root / 'other'
        other.mkdir()
        shutil.copy2(self.fixture.source, other / container_name)
        def rebuild(name, mode='index-rebuild', folder=None):
            target = self.root / (name+'.hlc2')
            shutil.copy2(self.fixture.catalogue, target)
            self.config = json.loads(json.dumps(saved_config))
            self.config['options']['catalogue'] = str(target)
            self.config['operation_mode'] = mode
            if folder:
                self.config['index_folder'] = folder
            result = self.run_operation()
            self.assertEqual(result['error'], '', result)
            return result['index_size']
        try:
            self.assertEqual(rebuild('same-source'), expected)
            self.assertEqual(rebuild('different-source', folder='other/'+container_name), 999)
            # A sidecar changed during index import must invalidate the
            # captured logical size even when the stripped archive is intact.
            self.assertEqual(rebuild('image-during-import', 'index-after-image-change'), 999)
            self.assertEqual(rebuild('image-before-import'), 999)
        finally:
            self.config = saved_config
            image_archive.write_bytes(saved)
            os.utime(image_archive, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))


# unittest normally collects inherited methods too. Retain the fixture helpers
# but disable inherited tests in this focused end-to-end module.
for _name in dir(NativeCompressionOperationTests):
    if _name.startswith('test_'):
        setattr(NativeExternalCompressionTests, _name, None)
del NativeCompressionOperationTests
