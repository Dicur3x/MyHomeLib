"""The actual catalogue resolver: fallback archives, loose/linked/FBD books."""
from pathlib import Path
import ctypes
import shutil
import subprocess
import zipfile

import test_native_compression_plan as plan_fixtures
from test_native_compression_receipt import database, sha


class NativeCompressionApplicationTests(plan_fixtures.NativeCompressionPlanTests):
    def update_main(self, **changes):
        with database(self.catalogue) as db:
            db.execute('UPDATE Books SET ' + ','.join(k + '=?' for k in changes) + ' WHERE BookID=101',
                       list(changes.values()))
        mapping = dict(BookID='id', LibID='lib_id', Folder='folder', FileName='file_name',
                       Ext='ext', InsideNo='inside_no')
        self.config['selected'][0].update({mapping[k]: v for k, v in changes.items() if k in mapping})

    def test_old_zip_locator_resolves_to_existing_seven_zip(self):
        stage = self.root / 'archive-inputs'
        stage.mkdir()
        (stage / 'one.fb2').write_bytes(self.fixture.original_book)
        (stage / 'neighbor.fb2').write_bytes(self.fixture.neighbor)
        seven_zip = plan_fixtures.RUNTIME / 'tools' / '7zip' / '7za.exe'
        target = self.fixture.source.with_suffix('.7z')
        result = subprocess.run([str(seven_zip), 'a', '-t7z', '-m0=PPMd', str(target), 'one.fb2', 'neighbor.fb2'],
                                cwd=stage, capture_output=True, timeout=15,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.fixture.source.unlink()
        before = sha(target.read_bytes())
        job = self.capture()['files'][0]
        self.assertEqual(Path(job['source']), target)
        self.assertEqual(job['members'], {'one.fb2': '.fb2'})
        self.assertEqual(len(job['receipt_template']['rows']), 3)
        self.assertEqual(sha(target.read_bytes()), before)

    def test_loose_book_with_empty_folder_is_not_an_archive(self):
        source = self.root / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        self.update_main(Folder='')
        job = self.capture()['files'][0]
        self.assertEqual(Path(job['source']), source)
        self.assertEqual(job['members'], {'': '.fb2'})
        self.assertEqual({r['kind'] for r in job['receipt_template']['rows']}, {0, 1})
        self.assertEqual(source.read_bytes(), self.fixture.original_book)

    def test_linked_book_outside_collection_retains_original_path(self):
        folder = self.root / 'original files elsewhere'
        folder.mkdir()
        source = folder / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        self.update_main(LibID='local:link:92881ae4-3b36-442b-8e40-777066830773', Folder=str(folder) + '\\')
        job = self.capture()['files'][0]
        self.assertEqual(Path(job['source']), source)
        self.assertEqual(job['members'], {'': '.fb2'})
        row = next(r for r in job['receipt_template']['rows'] if r['kind'] == 0)
        self.assertEqual(row['folder'], str(folder) + '\\')
        self.assertEqual(row['lib_id'], self.config['selected'][0]['lib_id'])

    def test_fbd_book_uses_raw_payload_and_keeps_descriptor(self):
        folder = self.root / 'loose'
        folder.mkdir()
        source = folder / 'one.zip'
        with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('one.fbd', b'<FictionBook><description>Descriptor</description></FictionBook>')
            archive.writestr('content.fb2', self.fixture.original_book)
            archive.writestr('cover.png', b'Unchanged cover placeholder')
        before = sha(source.read_bytes())
        self.update_main(Folder='loose\\', FileName='one.zip', InsideNo=1)
        job = self.capture()['files'][0]
        self.assertEqual(Path(job['source']), source)
        self.assertEqual(job['members'], {'content.fb2': '.fb2'})
        self.assertEqual(sha(source.read_bytes()), before)

    def test_selected_row_from_another_collection_is_rejected(self):
        self.config['selected_collection'] = 8
        self.assertIn('разным коллекциям', self.capture(False))
        self.unchanged()

    def test_root_changed_since_visible_selection_is_rejected(self):
        self.config['selected_root'] = str(self.root / 'old-root')
        self.assertIn('Путь выбранной книги изменился', self.capture(False))
        self.unchanged()

    def test_another_catalogue_cannot_use_this_registration(self):
        foreign = self.root / 'another.hlc2'
        shutil.copyfile(self.catalogue, foreign)
        self.config['options']['catalogue'] = str(foreign)
        self.assertIn('Подключение коллекции изменилось', self.capture(False))
        self.unchanged()

    def test_case_distinct_archives_are_not_treated_as_aliases(self):
        folder = self.root / 'case-sensitive'
        folder.mkdir()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = (ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                       ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p)
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.SetFileInformationByHandle.argtypes = (ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
        kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
        handle = kernel.CreateFileW(str(folder), 0x180, 7, None, 3, 0x02000000, None)
        if handle == ctypes.c_void_p(-1).value:
            self.skipTest('Private directory does not allow case-sensitivity flags')
        try:
            flags = ctypes.c_uint32(1)
            if not kernel.SetFileInformationByHandle(handle, 23, ctypes.byref(flags), ctypes.sizeof(flags)):
                self.skipTest('Case-sensitive directories unavailable on this filesystem')
        finally:
            kernel.CloseHandle(handle)
        first, second = folder / 'Books.zip', folder / 'books.zip'
        shutil.copyfile(self.fixture.source, first)
        shutil.copyfile(self.fixture.source, second)
        self.assertNotEqual(first.stat().st_ino, second.stat().st_ino)
        self.update_main(Folder='case-sensitive\\Books.zip')
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET Folder='case-sensitive\\books.zip',FileName='one' WHERE BookID=102")
        job = self.capture()['files'][0]
        self.assertTrue(job['source'].endswith('Books.zip'))
        self.assertEqual({r['id'] for r in job['receipt_template']['rows']}, {101})
        self.assertEqual(sha(first.read_bytes()), self.before[self.fixture.source])
        self.assertEqual(sha(second.read_bytes()), self.before[self.fixture.source])

    def test_first_personal_card_created_after_capture_keeps_its_notes_and_new_size(self):
        # The catalogue may contain an inaccurate INPX size. A newly opened
        # Reader records the actual original size; both need the final size.
        with database(self.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=BookSize+123 WHERE BookID=101')
        with database(self.personal) as db:
            db.execute('DELETE FROM Books WHERE DatabaseID=7 AND BookID=101')
        def add_personal_card():
            with database(self.personal) as db:
                db.execute('INSERT INTO Books VALUES(' + ','.join('?' * (len(self.fixture.main_row) + 2)) + ')',
                           (*self.fixture.main_row, 7, b'New notes written during compression\x00\xff'))
        self.after_capture = add_personal_card
        self.test_captured_selection_to_packaged_converter_to_native_commit()
