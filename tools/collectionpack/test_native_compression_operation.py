"""Real worker thread, packaged codecs, review/stop, catalogue commit/recovery."""
import copy
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
from supervised_test_process import run_owned
import unittest
import uuid
import zipfile

import test_native_compression_receipt as receipt_fixtures
from test_native_compression_receipt import database, sha

OPERATOR = Path(os.environ['HL_NATIVE_COMPRESSION_OPERATION']) if os.environ.get('HL_NATIVE_COMPRESSION_OPERATION') else None
RUNTIME = Path(os.environ['HL_COMPRESSION_RUNTIME']) if os.environ.get('HL_COMPRESSION_RUNTIME') else None


@unittest.skipUnless(os.name == 'nt' and OPERATOR and OPERATOR.is_file() and RUNTIME and RUNTIME.is_dir(),
                     'Built native operation and packaged runtime required')
class NativeCompressionOperationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = receipt_fixtures.NativeCompressionReceiptTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.request, self.result = self.root / 'operation.json', self.root / 'operation-result.json'
        self.tools = RUNTIME / 'tools'
        self.config = dict(options=dict(collection_id=7, catalogue=str(self.fixture.catalogue),
                                        personal=str(self.fixture.personal), root=str(self.root),
                                        base_root=str(self.root), base_catalogue=str(self.fixture.catalogue)),
                           selected=[copy.deepcopy(self.fixture.template['rows'][0])],
                           work_root=str(self.root / 'operation'),
                           python=str(self.tools / 'python' / 'python.exe'),
                           script=str(self.tools / 'bookconvert' / 'prepare_book_compression.py'),
                           seven_zip=str(self.tools / '7zip' / '7za.exe'), tools_root=str(self.tools),
                           profile='original', grayscale=True, operation_mode='apply')
        self.before = {p: sha(p.read_bytes()) for p in (self.fixture.source, self.fixture.catalogue, self.fixture.personal)}
        self.catalogue = self.fixture.snapshot(self.fixture.catalogue, sizes=False)
        self.personal = self.fixture.snapshot(self.fixture.personal, sizes=False)

    def tearDown(self):
        self.fixture.tearDown()

    def run_operation(self, allow_warning=False, allow_retained_work=False):
        self.result.unlink(missing_ok=True)
        self.request.write_text(json.dumps(self.config, ensure_ascii=False), encoding='utf-8')
        process = run_owned([str(OPERATOR), str(self.request), str(self.result)], capture_output=True,
                                 encoding='utf-8', errors='strict', timeout=15+self.config.get('timeout_ms',30000)/1000)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        result = json.loads(self.result.read_text(encoding='utf-8-sig'))
        if not allow_warning:
            self.assertEqual(result.get('warning', ''), '', result)
        if not allow_retained_work:
            self.assertFalse(list(Path(self.config['work_root']).glob('prepare-*')), result)
        return result

    def unchanged(self):
        self.assertEqual({p: sha(p.read_bytes()) for p in self.before}, self.before)

    def assert_applied(self, result):
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['changed_files'], 1, result)
        self.assertEqual(result['pending_before_ack'], 1, result)
        self.assertEqual(result['pending_after_ack'], 0, result)
        self.assertEqual(self.fixture.snapshot(self.fixture.catalogue, sizes=False), self.catalogue)
        self.assertEqual(self.fixture.snapshot(self.fixture.personal, sizes=False), self.personal)
        with zipfile.ZipFile(self.fixture.source) as archive:
            self.assertEqual(archive.read('neighbor.fb2'), self.fixture.neighbor)
            size = archive.getinfo('one.fb2').file_size
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0], size)
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], size)
        with database(self.fixture.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], size)

    def test_thread_runs_complete_packaged_pipeline_and_acknowledges_after_commit(self):
        before_size = self.fixture.source.stat().st_size
        result = self.run_operation()
        self.assert_applied(result)
        self.assertTrue(result['finished'])
        self.assertFalse(result['stopping'])
        self.assertEqual((result['books_done'], result['books_total']), (1, 1))
        self.assertEqual(result['saved_bytes'], before_size - self.fixture.source.stat().st_size)

    def test_new_compression_requests_current_images_only_when_the_choice_uses_images(self):
        from validate_catalogue_compression import descriptor
        app = self.root / 'module-probe'
        images = app / 'tools/images'
        images.parent.mkdir(parents=True)
        shutil.copytree(self.tools / 'images', images)
        platform = json.loads((images / 'RUNTIME.json').read_text(encoding='utf-8-sig'))['platform']
        required = ['tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt']
        self.config.update(app_path=str(app), operation_mode='resolve-tools')

        def probe(version, profile, gray):
            descriptor(app, platform, 'ImageProcessing', version, 'tools/images/COMPONENT.json', required)
            self.config.update(profile=profile, grayscale=gray)
            self.request.write_text(json.dumps(self.config), encoding='utf-8')
            process = run_owned([str(OPERATOR), str(self.request), str(self.result)],
                                capture_output=True, encoding='utf-8', timeout=30)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            return json.loads(self.result.read_text(encoding='utf-8-sig'))['missing']

        self.assertIn('ImageProcessing', probe('3.0.0.8', 'balanced', False))
        self.assertIn('ImageProcessing', probe('3.0.0.8', 'original', True))
        self.assertNotIn('ImageProcessing', probe('3.0.0.8', 'original', False))
        self.assertNotIn('ImageProcessing', probe('3.0.0.14', 'economy', False))
        self.assertNotIn('ImageProcessing', probe('3.0.0.14', 'original', True))
        (images / 'HomeLibImages.exe').unlink()
        self.config.update(profile='balanced', grayscale=False)
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        process = run_owned([str(OPERATOR), str(self.request), str(self.result)],
                            capture_output=True, encoding='utf-8', timeout=30)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn('ImageProcessing', json.loads(self.result.read_text(encoding='utf-8-sig'))['missing'])
        self.unchanged()

    def test_long_unicode_workspace_still_processes_images_and_commits(self):
        work = self.root / 'Рабочая папка ё'
        suffix = 'prepare-{01234567-0123-0123-0123-012345678901}/payload/books/1/homelib-image-quality-01234567/images.zip'
        while len(str(work / suffix)) <= 280:
            work /= 'Вложенная рабочая папка ё'
        self.config['work_root'] = str(work)
        image = work / suffix
        self.assertGreater(len(str(image)), 260)
        observed = self.observe_updated_engine()
        result = self.run_operation()
        if observed.is_file():
            result['preparation_books'] = json.loads(observed.read_text(encoding='utf-8'))
        self.assert_applied(result)

    def test_preview_does_not_change_original_before_approval(self):
        self.config['operation_mode'] = 'review-apply'
        result = self.run_operation()
        self.assertTrue(result['review_seen'])
        self.assertEqual(result['before_review_sha256'], self.before[self.fixture.source])
        self.assert_applied(result)

    def leave_unapproved_preparation(self):
        folder = self.enable_backup()
        self.config['operation_mode'] = 'review-crash'
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        crashed = run_owned([str(OPERATOR), str(self.request), str(self.result)],
                            capture_output=True, encoding='utf-8', errors='strict', timeout=45)
        self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
        self.assertIn('TRACE terminated before compression approval', crashed.stdout)
        self.assertEqual(len(list(Path(self.config['work_root']).glob('prepare-*'))), 1)
        self.assertFalse(list((Path(self.config['work_root']) / 'jobs').glob('compress-*')))
        self.assertEqual(list(folder.iterdir()), [], 'Unapproved preparation published an original backup')
        self.unchanged()
        return next(Path(self.config['work_root']).glob('prepare-*')), folder

    def test_restart_cleans_unapproved_preparation_without_changing_books(self):
        preparation, folder = self.leave_unapproved_preparation()
        self.config['operation_mode'] = 'recover'
        # Check authoritative content before the final cleanup assertion, so
        # a baseline failure distinguishes retained scratch data from damage.
        recovered = self.run_operation(allow_retained_work=True)
        self.assertEqual(recovered['error'], '', recovered)
        self.assertEqual(recovered['discarded_preparations'], 1, recovered)
        self.assertEqual(recovered['changed_files'], 0, recovered)
        self.assertEqual(recovered['pending_after_ack'], 0, recovered)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()
        self.assertFalse(list(Path(self.config['work_root']).glob('prepare-*')),
                         'Unapproved preparation remained after restart; books and stores are unchanged')

    def test_abandoned_preparation_keeps_foreign_marker_and_root_file(self):
        preparation, folder = self.leave_unapproved_preparation()
        marker = preparation / 'owner.txt'
        original = marker.read_bytes()
        marker.write_bytes(b'Foreign owner: keep this directory')
        self.config['operation_mode'] = 'recover'
        result = self.run_operation(allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertEqual(marker.read_bytes(), b'Foreign owner: keep this directory')
        self.unchanged()

        marker.write_bytes(original)
        foreign = preparation / 'unrelated.txt'
        foreign.write_bytes(b'Keep unrelated user data')
        result = self.run_operation(allow_warning=True, allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertIn('посторонний файл', result['warning'])
        self.assertEqual(foreign.read_bytes(), b'Keep unrelated user data')
        self.unchanged()
        foreign.unlink()
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_abandoned_cleanup_does_not_require_python_or_codecs(self):
        preparation, folder = self.leave_unapproved_preparation()
        missing = self.root / 'not-installed'
        self.config.update(operation_mode='recover', python=str(missing / 'python.exe'),
                           script=str(missing / 'prepare.py'), tools_root=str(missing),
                           seven_zip=str(missing / '7za.exe'))
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(result['error'], '', result)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_abandoned_preparation_keeps_live_owner_and_another_profile(self):
        from validate_catalogue_compression import exclusive_recovery_owner
        self.config['queue_name'] = '{B2A52CC5-B07D-4429-B570-8376F3BC80C0}'
        preparation, folder = self.leave_unapproved_preparation()
        self.config['operation_mode'] = 'recover'
        before = (preparation / 'report.json').read_bytes()
        with exclusive_recovery_owner(preparation / 'owner.txt'):
            result = self.run_operation(allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertEqual((preparation / 'report.json').read_bytes(), before)
        self.config['queue_name'] = '{930DB3BD-B4CB-49DA-9C73-6241419E71CC}'
        result = self.run_operation(allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertTrue(preparation.is_dir())
        self.unchanged()
        self.config['queue_name'] = '{B2A52CC5-B07D-4429-B570-8376F3BC80C0}'
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_copied_preparation_marker_does_not_own_another_directory(self):
        preparation, folder = self.leave_unapproved_preparation()
        leaf = 'prepare-{' + str(uuid.uuid4()).upper() + '}'
        foreign = preparation.parent / leaf
        foreign.mkdir()
        marker = json.loads((preparation / 'owner.txt').read_text(encoding='utf-8-sig'))
        marker.update(folder=leaf, job='compress-' + leaf.removeprefix('prepare-'))
        (foreign / 'owner.txt').write_text(json.dumps(marker), encoding='utf-8')
        (foreign / 'unrelated.txt').write_bytes(b'Keep copied-marker directory')
        self.config['operation_mode'] = 'recover'
        result = self.run_operation(allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertFalse(preparation.exists())
        self.assertEqual((foreign / 'unrelated.txt').read_bytes(), b'Keep copied-marker directory')
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_unpublished_preparation_job_metadata_and_atomic_partials_are_removed(self):
        preparation, folder = self.leave_unapproved_preparation()
        job = preparation.parent / 'jobs' / ('compress-' + preparation.name.removeprefix('prepare-'))
        job.mkdir(parents=True)
        (job / 'receipt.json').write_bytes(b'Not published; may be incomplete')
        (job / ('.homelib-data-{' + str(uuid.uuid4()).upper() + '}.tmp')).write_bytes(b'partial metadata')
        (preparation / ('report.json.' + uuid.uuid4().hex + '.partial')).write_bytes(b'partial report')
        self.config['operation_mode'] = 'recover'
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertFalse(job.exists())
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_unpublished_job_with_unknown_file_keeps_preparation(self):
        preparation, folder = self.leave_unapproved_preparation()
        job = preparation.parent / 'jobs' / ('compress-' + preparation.name.removeprefix('prepare-'))
        job.mkdir(parents=True)
        (job / 'unrelated.txt').write_bytes(b'Keep unknown job data')
        self.config['operation_mode'] = 'recover'
        result = self.run_operation(allow_warning=True, allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertTrue(preparation.is_dir())
        self.assertEqual((job / 'unrelated.txt').read_bytes(), b'Keep unknown job data')
        self.assertIn('неизвестные файлы', result['warning'])
        self.unchanged()

    def test_abandoned_nested_scratch_keeps_hardlinked_source(self):
        preparation, folder = self.leave_unapproved_preparation()
        scratch = preparation / 'payload/.selected-abcdefgh'
        scratch.mkdir()
        linked = scratch / 'linked-source.zip'
        os.link(self.fixture.source, linked)
        self.config['operation_mode'] = 'recover'
        result = self.run_operation(allow_warning=True, allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertTrue(linked.is_file())
        self.assertIn('Тип временного файла', result['warning'])
        self.unchanged()
        linked.unlink()
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_abandoned_nested_scratch_never_follows_directory_junction(self):
        import struct
        preparation, folder = self.leave_unapproved_preparation()
        outside = self.root / 'outside-preparation'
        outside.mkdir()
        kept = outside / 'kept.txt'
        kept.write_bytes(b'Keep the directory outside native preparation')
        scratch = preparation / 'payload/.selected-abcdefgh'
        scratch.mkdir()
        link = scratch / 'redirect'
        link.mkdir()
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.DeviceIoControl.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
            ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
        kernel.DeviceIoControl.restype = ctypes.c_int
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.CreateFileW('\\\\?\\' + str(link), 0x40000000, 7, None, 3, 0x02200000, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            substitute = ('\\??\\' + str(outside)).encode('utf-16-le')
            display = str(outside).encode('utf-16-le')
            body = struct.pack('<HHHH', 0, len(substitute), len(substitute) + 2, len(display))
            body += substitute + b'\0\0' + display + b'\0\0'
            data = struct.pack('<IHH', 0xA0000003, len(body), 0) + body
            buffer, returned = ctypes.create_string_buffer(data), ctypes.c_uint32()
            self.assertTrue(kernel.DeviceIoControl(handle, 0x900A4, buffer, len(data), None, 0,
                                                  ctypes.byref(returned), None), ctypes.get_last_error())
        finally:
            kernel.CloseHandle(handle)
        self.assertEqual(link.resolve(strict=True), outside.resolve(strict=True))
        self.config['operation_mode'] = 'recover'
        result = self.run_operation(allow_warning=True, allow_retained_work=True)
        self.assertEqual(result['discarded_preparations'], 0, result)
        self.assertIn('ссылка', result['warning'])
        self.assertEqual(kept.read_bytes(), b'Keep the directory outside native preparation')
        self.unchanged()
        link.rmdir()  # Only this verified test junction; never recurse into its target.
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(kept.read_bytes(), b'Keep the directory outside native preparation')
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_restart_after_terminating_actual_running_preparer_removes_nested_scratch(self):
        folder = self.enable_backup()
        worker = self.root / 'paused-actual-preparer.py'
        worker.write_text(
            'import json,runpy,sys,time\n'
            'worker=runpy.run_path(' + repr(self.config['script']) + ',run_name="test_worker")\n'
            'scope=worker["main"].__globals__\n'
            'prepare=scope["prepare_selected_file"]\n'
            'def paused(*args,**kwargs):\n'
            ' original_notify=kwargs["notify"]\n'
            ' def pause(event):\n'
            '  if event.get("stage")=="Сохраняем оригинал выбранной книги":\n'
            '   print(json.dumps({"stage":"scratch-ready"}),flush=True)\n'
            '   time.sleep(60)\n'
            '  original_notify(event)\n'
            ' kwargs["notify"]=pause\n'
            ' return prepare(*args,**kwargs)\n'
            'scope["prepare_selected_file"]=paused\n'
            'sys.exit(worker["main"]())\n', encoding='utf-8')
        self.config.update(script=str(worker), operation_mode='crash-producer')
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        crashed = run_owned([str(OPERATOR), str(self.request), str(self.result)],
                            capture_output=True, encoding='utf-8', errors='strict', timeout=45)
        self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
        self.assertIn('TRACE terminated during compression preparation', crashed.stdout)
        preparation = next(Path(self.config['work_root']).glob('prepare-*'))
        extracted = list((preparation / 'payload').glob('.selected-*/*/original.fb2'))
        self.assertEqual(len(extracted), 1)
        self.assertEqual(extracted[0].read_bytes(), self.fixture.original_book)
        self.unchanged()
        self.config['operation_mode'] = 'recover'
        result = self.run_operation()
        self.assertEqual(result['discarded_preparations'], 1, result)
        self.assertEqual(result['changed_files'], 0, result)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_estimate_only_finishes_without_book_database_backup_or_job_writes(self):
        folder = self.enable_backup()
        self.config.update(estimate_first=True, operation_mode='estimate-only')
        self.config['script'] = self.config['script'].replace('\\', '/')
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertTrue(result['estimate_only'])
        self.assertTrue(result['review_seen'])
        self.assertGreater(result['estimate_input_bytes'], result['estimate_output_bytes'])
        self.assertEqual(result['estimate_unknown_books'], 0)
        self.assertEqual(result['estimate_archive_bytes'], self.fixture.source.stat().st_size)
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_before_ack'], 0)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_estimate_can_continue_to_normal_compression_without_implicit_review_all(self):
        self.config.update(estimate_first=True, operation_mode='review-apply')
        result = self.run_operation()
        self.assertFalse(result['estimate_only'])
        self.assertGreater(result['estimate_input_bytes'], 0)
        self.assert_applied(result)

    def test_preview_skip_preserves_both_stores_and_source(self):
        self.config['operation_mode'] = 'review-skip'
        result = self.run_operation()
        self.assertEqual(result['error'], '')
        self.assertTrue(result['review_seen'])
        self.assertEqual(result['skipped_files'], 1)
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_after_ack'], 0)
        self.unchanged()

    def enable_backup(self):
        folder = self.root / 'originals'
        folder.mkdir()
        self.config.update(backup_originals=True, backup_folder=str(folder))
        return folder

    def test_optional_backup_saves_only_selected_original_before_real_replacement(self):
        folder = self.enable_backup()
        result = self.run_operation()
        self.assert_applied(result)
        self.assertEqual(result['backup_files'], 1)
        self.assertEqual(result['backup_folder'], str(folder))
        files = list(folder.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].suffix, '.zip')
        with zipfile.ZipFile(files[0]) as archive:
            self.assertEqual(set(archive.namelist()), {'books/one.fb2', 'HomeLibre-originals.json'})
            self.assertEqual(archive.read('books/one.fb2'), self.fixture.original_book)
            manifest = json.loads(archive.read('HomeLibre-originals.json'))
            self.assertEqual(manifest['source_sha256'], self.before[self.fixture.source])

    def long_backup_environment(self):
        work = self.root / 'Подготовка оригиналов ё'
        while len(str(work / 'prepare-{01234567-0123-0123-0123-012345678901}/payload/original-books.zip')) <= 300:
            work /= 'Вложенная рабочая папка ё'
        folder = self.root / 'Сохранённые оригиналы ё'
        while len(str(folder / 'HomeLibre-originals-{01234567-0123-0123-0123-012345678901}.zip')) <= 300:
            folder /= 'Вложенная папка бэкапа ё'
        folder.mkdir(parents=True)
        self.config.update(work_root=str(work), backup_originals=True, backup_folder=str(folder))
        return folder

    def test_long_unicode_backup_preserves_selected_original_and_manifest(self):
        folder = self.long_backup_environment()
        result = self.run_operation()
        self.assert_applied(result)
        self.assertEqual(result['backup_files'], 1)
        files = list(folder.iterdir())
        self.assertEqual(len(files), 1)
        self.assertGreater(len(str(files[0])), 260)
        with zipfile.ZipFile(files[0]) as archive:
            self.assertEqual(set(archive.namelist()), {'books/one.fb2', 'HomeLibre-originals.json'})
            self.assertEqual(archive.read('books/one.fb2'), self.fixture.original_book)
            self.assertEqual(json.loads(archive.read('HomeLibre-originals.json'))['source_sha256'],
                             self.before[self.fixture.source])

    def test_long_unicode_corrupt_prepared_original_prevents_source_replacement(self):
        folder = self.long_backup_environment()
        self.config['operation_mode'] = 'review-backup-corrupt'
        result = self.run_operation()
        self.assertIn('сумма', result['error'])
        self.assertEqual((result['changed_files'], result['pending_before_ack']), (0, 0))
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_preview_skip_does_not_publish_unnecessary_originals(self):
        folder = self.enable_backup()
        self.config['operation_mode'] = 'review-skip'
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['backup_files'], 0)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_backup_folder_disappearing_after_review_does_not_change_book(self):
        folder = self.enable_backup()
        self.config['operation_mode'] = 'review-backup-missing'
        result = self.run_operation()
        self.assertNotEqual(result['error'], '')
        self.assertFalse(folder.exists())
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_before_ack'], 0)
        self.unchanged()

    def test_corrupt_prepared_original_prevents_source_replacement(self):
        folder = self.enable_backup()
        self.config['operation_mode'] = 'review-backup-corrupt'
        result = self.run_operation()
        self.assertIn('сумма', result['error'])
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_backup_content_is_checked_even_if_preparer_rehashes_a_wrong_zip(self):
        folder = self.enable_backup()
        worker = self.root / 'wrong-original.py'
        worker.write_text('import runpy,sys,json,zipfile,hashlib\nfrom pathlib import Path\n'
                          'worker=runpy.run_path(' + repr(self.config['script']) + ',run_name="test_worker")\n'
                          'code=worker["main"]()\n'
                          'if code==0:\n'
                          ' job=json.loads(Path(sys.argv[sys.argv.index("--job")+1]).read_text("utf-8-sig"))\n'
                          ' report=Path(job["report"])\n value=json.loads(report.read_text("utf-8"))\n'
                          ' backup=Path(value["originals"]["path"])\n'
                          ' with zipfile.ZipFile(backup) as z: manifest=z.read("HomeLibre-originals.json")\n'
                          ' with zipfile.ZipFile(backup,"w",zipfile.ZIP_DEFLATED) as z:\n'
                          '  z.writestr("HomeLibre-originals.json",manifest)\n'
                          '  z.writestr("books/one.fb2",b"Different book bytes")\n'
                          ' value["originals"].update(sha256=hashlib.sha256(backup.read_bytes()).hexdigest(),bytes=backup.stat().st_size)\n'
                          ' report.write_text(json.dumps(value),encoding="utf-8")\n'
                          'sys.exit(code)\n', encoding='utf-8')
        self.config['script'] = str(worker)
        result = self.run_operation()
        self.assertIn('содержимого', result['error'])
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(list(folder.iterdir()), [])
        self.unchanged()

    def test_completed_backup_reference_survives_job_recovery_and_acknowledgement(self):
        folder = self.enable_backup()
        self.config['acknowledge'] = False
        first = self.run_operation()
        self.assertEqual(first['error'], '', first)
        saved = {p: sha(p.read_bytes()) for p in folder.iterdir()}
        self.assertEqual(len(saved), 1)
        jobs = list((Path(self.config['work_root']) / 'jobs').glob('compress-*'))
        binding = json.loads((jobs[0] / 'job.json').read_text('utf-8-sig'))
        self.assertEqual(binding['originals']['path'], str(next(iter(saved))))
        self.config.update(operation_mode='recover', acknowledge=True,
                           backup_folder=str(self.root / 'new-backup-preference-no-longer-available'))
        recovered = self.run_operation()
        self.assertEqual(recovered['error'], '', recovered)
        self.assertEqual(recovered['pending_after_ack'], 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in saved}, saved)

    def test_stop_while_reviewing_removes_candidate_without_changes(self):
        self.config['operation_mode'] = 'review-stop'
        result = self.run_operation()
        self.assertTrue(result['stopping'])
        self.assertEqual(result['error'], '')
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_after_ack'], 0)
        self.unchanged()

    def test_disposing_waiting_owner_stops_worker_before_freeing_state(self):
        self.config['operation_mode'] = 'dispose-at-review'
        result = self.run_operation()
        self.assertTrue(result['disposed'])
        self.assertTrue(result['review_seen'])
        self.assertFalse(list((Path(self.config['work_root']) / 'jobs').glob('compress-*')))
        self.unchanged()

    def test_stop_before_start_does_not_create_work_or_run_factory(self):
        self.config['operation_mode'] = 'stop-before'
        result = self.run_operation()
        self.assertTrue(result['stopping'])
        self.assertEqual(result['error'], '')
        self.assertFalse(Path(self.config['work_root']).exists())
        self.unchanged()

    def test_no_gain_keeps_original_loose_book_and_does_not_publish_job(self):
        source = self.root / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='' WHERE BookID=101")
        self.config['selected'][0]['folder'] = ''
        self.config['grayscale'] = False
        result = self.run_operation()
        self.assertEqual(result['error'], '')
        self.assertEqual(result['unchanged_files'], 1)
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_before_ack'], 0)
        self.assertEqual(source.read_bytes(), self.fixture.original_book)

    def forbid_encoder(self):
        # Keep the actual engine files unchanged: only a required subprocess
        # would need this interpreter. A verified cache hit must not launch it.
        self.config['python'] = str(self.root / 'interpreter-must-not-be-needed.exe')

    def test_second_operation_checks_archive_without_repeating_preparation_or_database_writes(self):
        self.assert_applied(self.run_operation())
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['changed_files'], result['unchanged_files'], result['pending_before_ack']), (0, 1, 0))
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_no_gain_is_remembered_but_original_and_personal_data_stay_byte_exact(self):
        source = self.root / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='' WHERE BookID=101")
        self.config['selected'][0]['folder'] = ''
        self.config['grayscale'] = False
        rows_before = self.fixture.snapshot(self.fixture.catalogue)
        personal_before = sha(self.fixture.personal.read_bytes())
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['unchanged_files'], 1)
        self.assertEqual(source.read_bytes(), self.fixture.original_book)
        self.assertEqual(sha(self.fixture.personal.read_bytes()), personal_before)
        self.assertEqual(self.fixture.snapshot(self.fixture.catalogue), rows_before)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT Member,Profile,Grayscale,PayloadSHA256 FROM HomeLibreCompressionChecks').fetchall(),
                             [('', 'original', 0, sha(self.fixture.original_book))])
        before = {p: sha(p.read_bytes()) for p in (source, self.fixture.catalogue, self.fixture.personal)}
        self.forbid_encoder()
        again = self.run_operation()
        self.assertEqual(again['error'], '', again)
        self.assertEqual(again['unchanged_files'], 1)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def inspected_collection(self):
        self.config.update(whole=True, profile='original', grayscale=False)
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['books_total'], 2)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM HomeLibreCompressionChecks').fetchone()[0], 2)
        self.config['only_new'] = True

    def test_new_books_mode_with_no_arrivals_keeps_all_authoritative_bytes_and_needs_no_encoder(self):
        self.inspected_collection()
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['files_total'], result['books_total']), (0, 0))
        self.assertEqual(result['previously_processed_books'], 2)
        self.assertEqual(result['pending_before_ack'], 0)
        self.assertIn('Новых книг', result['stage'])
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_long_unicode_collection_plan_can_seal_edit_and_skip_verified_books(self):
        work = self.root / 'План всей коллекции ё'
        while len(str(work / 'collection-plan-{01234567-0123-0123-0123-012345678901}/plan.sqlite-wal')) <= 300:
            work /= 'Вложенная рабочая папка ё'
        self.config['work_root'] = str(work)
        self.inspected_collection()
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['files_total'], result['books_total']), (0, 0))
        self.assertEqual(result['previously_processed_books'], 2)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)
        self.assertEqual(list(work.glob('collection-plan-*')), [])

    def test_new_books_mode_selects_an_added_archive_and_preserves_the_previous_archive(self):
        self.inspected_collection()
        previous_archive = sha(self.fixture.source.read_bytes())
        personal_before = self.fixture.snapshot(self.fixture.personal)
        arriving = self.root / 'new-books.zip'
        with zipfile.ZipFile(arriving, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('one.fb2', self.fixture.original_book)
        with database(self.fixture.catalogue) as db:
            row = list(self.fixture.main_row)
            row[0], row[1], row[2] = 103, 'local:new-book', arriving.name
            db.execute('INSERT INTO Books VALUES(' + ','.join('?' * len(row)) + ')', row)
        initial_size = arriving.stat().st_size
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['files_total'], result['books_total'], result['previously_processed_books']), (1, 1, 2))
        self.assertEqual(result['changed_files'], 1)
        self.assertLess(arriving.stat().st_size, initial_size)
        self.assertEqual(sha(self.fixture.source.read_bytes()), previous_archive)
        # The first physical commit opens the personal store's writer lock and
        # enables the application's WAL mode. Pages/header can change without
        # changing a single personal value; verify every table's actual data.
        self.assertEqual(self.fixture.snapshot(self.fixture.personal), personal_before)
        with database(self.fixture.personal) as db:
            self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0], 'wal')
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=103').fetchone()[0], len(self.fixture.original_book))

    def test_new_books_mode_rechecks_changed_source_metadata_with_content_verification(self):
        self.inspected_collection()
        source = self.fixture.source
        stamp = source.stat()
        os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 10_000_000_000))
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['books_total'], result['previously_processed_books']), (2, 0))
        self.assertEqual(result['unchanged_files'], 1)  # Packed SHA-256 still matches.
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_new_books_mode_without_history_does_not_treat_unprocessed_books_as_done(self):
        self.config.update(whole=True, only_new=True, profile='original', grayscale=False)
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['books_total'], result['previously_processed_books']), (2, 0))

    def test_new_books_mode_keeps_history_when_import_reassigns_catalogue_ids(self):
        self.inspected_collection()
        with database(self.fixture.catalogue) as db:
            db.execute('UPDATE Books SET BookID=201 WHERE BookID=101')
            for table in ('Author_List', 'Series_List', 'Genre_List', 'CatalogBookCopies', 'CatalogSourceBooks'):
                db.execute('UPDATE ' + table + ' SET BookID=201 WHERE BookID=101')
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['books_total'], result['previously_processed_books']), (0, 2))
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_new_books_mode_does_not_apply_another_quality_choices_history(self):
        self.inspected_collection()
        self.config['profile'] = 'economy'
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['books_total'], result['previously_processed_books']), (2, 0))

    def test_temporary_image_failure_is_not_cached_as_a_completed_inspection(self):
        source = self.root / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='' WHERE BookID=101")
        self.config['selected'][0]['folder'] = ''
        allowed = self.root / 'decode-is-available'
        worker = self.root / 'temporarily-unavailable-images.py'
        worker.write_text('import runpy,sys\nfrom pathlib import Path\n'
            'engine=runpy.run_path(' + repr(self.config['script']) + ',run_name="test_worker")\n'
            'if not Path(' + repr(str(allowed)) + ').exists():\n'
            ' def unavailable(self,*args,**kwargs): raise engine["PackingError"]("temporary image failure")\n'
            ' engine["Packer"].optimize_book=unavailable\n'
            'raise SystemExit(engine["main"]())\n', encoding='utf-8')
        self.config['script'] = str(worker)
        before = {p: sha(p.read_bytes()) for p in (source, self.fixture.personal)}
        first = self.run_operation(allow_warning=True)
        self.assertEqual(first['error'], '', first)
        self.assertEqual((first['changed_files'], first['unchanged_files']), (0, 1))
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM HomeLibreCompressionChecks').fetchone()[0], 0)
        self.assertIn('temporary image failure', first['warning'])
        # Same source, settings and worker bytes: clearing a temporary problem
        # must allow a real retry without an engine update or touching the book.
        allowed.touch()
        second = self.run_operation()
        self.assertEqual(second['error'], '', second)
        self.assertEqual((second['changed_files'], second['unchanged_files']), (1, 0))
        self.assertLess(source.stat().st_size, len(self.fixture.original_book))

    def test_shared_archive_commits_good_book_and_retries_only_failed_images(self):
        from pack_collection import SevenZip
        original = self.fixture.original_book
        neighbor = original.replace(b'Same book text', b'Other book text')
        with zipfile.ZipFile(self.fixture.source, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('one.fb2', original)
            archive.writestr('neighbor.fb2', neighbor)
        with database(self.fixture.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=102', (len(neighbor),))
        self.config['selected'].append(dict(self.config['selected'][0], id=102, lib_id='flibusta:102',
            file_name='neighbor', inside_no=1, old_size=len(neighbor), member='neighbor.fb2'))
        allowed = self.root / 'decode-is-available'
        worker = self.root / 'partially-unavailable-images.py'
        worker.write_text('import runpy,sys\nfrom pathlib import Path\n'
            'engine=runpy.run_path(' + repr(self.config['script']) + ',run_name="test_worker")\n'
            'original=engine["Packer"].optimize_book\n'
            'def optimize(self,target,*args,**kwargs):\n'
            ' if b"Same book text" in target.read_bytes() and not Path(' + repr(str(allowed)) + ').exists():\n'
            '  raise engine["PackingError"]("temporary image failure")\n'
            ' return original(self,target,*args,**kwargs)\n'
            'engine["Packer"].optimize_book=optimize\n'
            'raise SystemExit(engine["main"]())\n', encoding='utf-8')
        self.config['script'] = str(worker)
        decoder = SevenZip(self.config['seven_zip'], lambda: None)
        def read_book(member):
            # The real writer may select ZIP/PPMd; Python's zipfile cannot
            # decode that valid method. Verify with the official 7-Zip codec.
            output = self.root / ('verified-' + member)
            output.unlink(missing_ok=True)
            decoder.extract(self.fixture.source, member, output, self.root)
            return output.read_bytes()
        first = self.run_operation(allow_warning=True)
        self.assertEqual(first['error'], '', first)
        self.assertEqual(first['changed_files'], 1)
        self.assertIn('one.fb2: temporary image failure', first['warning'])
        self.assertEqual(read_book('one.fb2'), original)
        kept_neighbor = read_book('neighbor.fb2')
        self.assertLess(len(kept_neighbor), len(neighbor))
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT Member FROM HomeLibreCompressionChecks').fetchall(), [('neighbor.fb2',)])
        allowed.touch()
        self.config.update(whole=True, only_new=True)
        second = self.run_operation()
        self.assertEqual(second['error'], '', second)
        self.assertEqual(second['changed_files'], 1)
        self.assertEqual((second['books_total'], second['previously_processed_books']), (1, 1))
        self.assertLess(len(read_book('one.fb2')), len(original))
        self.assertEqual(read_book('neighbor.fb2'), kept_neighbor)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT Member FROM HomeLibreCompressionChecks ORDER BY Member').fetchall(),
                             [('neighbor.fb2',), ('one.fb2',)])

    def test_changed_archive_with_restored_timestamp_and_same_size_is_not_skipped(self):
        self.assert_applied(self.run_operation())
        source = self.fixture.source
        stamp = source.stat()
        before = sha(source.read_bytes())
        with zipfile.ZipFile(source, 'a') as archive:
            archive.comment = b'X' * len(archive.comment)
        os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.assertEqual((source.stat().st_ino, source.stat().st_size, source.stat().st_mtime_ns),
                         (stamp.st_ino, stamp.st_size, stamp.st_mtime_ns))
        changed = sha(source.read_bytes())
        self.assertNotEqual(changed, before)
        self.forbid_encoder()
        result = self.run_operation()
        self.assertNotEqual(result['error'], '', result)
        self.assertEqual(sha(source.read_bytes()), changed)

    def test_timestamp_only_change_can_still_use_verified_packed_bytes(self):
        self.assert_applied(self.run_operation())
        source = self.fixture.source
        stamp = source.stat()
        os.utime(source, ns=(stamp.st_atime_ns, stamp.st_mtime_ns + 10_000_000_000))
        self.forbid_encoder()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['unchanged_files'], 1)

    def test_changed_quality_or_new_selected_member_requires_preparation(self):
        self.assert_applied(self.run_operation())
        self.forbid_encoder()
        self.config['grayscale'] = False
        self.assertNotEqual(self.run_operation()['error'], '')
        self.config['grayscale'] = True
        self.config['selected'].append(dict(self.config['selected'][0], id=102, lib_id='flibusta:102',
                                            file_name='neighbor', inside_no=1))
        self.assertNotEqual(self.run_operation()['error'], '')

    def test_updated_engine_does_not_reuse_a_previous_inspection(self):
        self.assert_applied(self.run_operation())
        worker = self.root / 'updated-worker.py'
        worker.write_bytes(Path(self.config['script']).read_bytes() + b'\n# New engine revision\n')
        self.config['script'] = str(worker)
        self.forbid_encoder()
        self.assertNotEqual(self.run_operation()['error'], '')

    def observe_updated_engine(self):
        # Change only the worker revision. Run the actual packaged preparation
        # and record its reuse decisions before the operation cleans its work.
        actual = self.config['script']
        marker = self.root / 'updated-engine-books.json'
        worker = self.root / 'updated-engine-observer.py'
        worker.write_text(
            'import json, pathlib, runpy, sys\n'
            f'engine = runpy.run_path({actual!r}, run_name="compression_revision")\n'
            'result = engine["main"]()\n'
            'job = json.loads(pathlib.Path(sys.argv[sys.argv.index("--job") + 1]).read_text(encoding="utf-8-sig"))\n'
            'report = json.loads(pathlib.Path(job["report"]).read_text(encoding="utf-8-sig"))\n'
            f'pathlib.Path({str(marker)!r}).write_text(json.dumps(report["books"]), encoding="utf-8")\n'
            'raise SystemExit(result)\n', encoding='utf-8')
        self.config['script'] = str(worker)
        return marker

    def test_updated_engine_preserves_already_transformed_payload(self):
        self.assert_applied(self.run_operation())
        before = {p: sha(p.read_bytes()) for p in (self.fixture.source, self.fixture.personal)}
        marker = self.observe_updated_engine()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['changed_files'], result['unchanged_files']), (0, 1))
        self.assertTrue(json.loads(marker.read_text(encoding='utf-8'))[0]['reused'])
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_updated_engine_rechecks_original_that_did_not_shrink(self):
        source = self.root / 'one.fb2'
        source.write_bytes(self.fixture.original_book)
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='' WHERE BookID=101")
        self.config['selected'][0]['folder'] = ''
        self.config['grayscale'] = False
        self.assertEqual(self.run_operation()['unchanged_files'], 1)
        before = {p: sha(p.read_bytes()) for p in (source, self.fixture.personal)}
        marker = self.observe_updated_engine()
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual((result['changed_files'], result['unchanged_files']), (0, 1))
        self.assertFalse(json.loads(marker.read_text(encoding='utf-8'))[0]['reused'])
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_two_archives_are_processed_in_one_operation_with_cumulative_savings(self):
        second = self.root / 'second.zip'
        shutil.copyfile(self.fixture.source, second)
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='second.zip',FileName='one' WHERE BookID=102")
        self.config['selected'].append(dict(self.config['selected'][0], id=102, lib_id='flibusta:102',
                                            folder='second.zip', inside_no=1))
        self.config['operation_mode'] = 'review-all'
        initial = self.fixture.source.stat().st_size + second.stat().st_size
        result = self.run_operation()
        self.assertEqual(result['error'], '')
        self.assertTrue(result['review_seen'])
        self.assertEqual((result['files_done'], result['files_total']), (2, 2))
        self.assertEqual((result['books_done'], result['books_total']), (2, 2))
        self.assertEqual(result['changed_files'], 2)
        self.assertEqual(result['pending_before_ack'], 2)
        self.assertEqual(result['pending_after_ack'], 0)
        self.assertEqual(result['saved_bytes'], initial - self.fixture.source.stat().st_size - second.stat().st_size)
        for source in [self.fixture.source, second]:
            with zipfile.ZipFile(source) as archive:
                self.assertEqual(archive.read('neighbor.fb2'), self.fixture.neighbor)

    def test_finished_job_remains_recoverable_until_application_acknowledges(self):
        self.config['acknowledge'] = False
        first = self.run_operation()
        self.assertEqual(first['error'], '')
        self.assertEqual(first['pending_after_ack'], 1)
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.config.update(operation_mode='recover', acknowledge=True)
        recovered = self.run_operation()
        self.assertEqual(recovered['error'], '')
        self.assertFalse(recovered['savings_known'])
        self.assertEqual(recovered['pending_after_ack'], 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    def test_profiles_sharing_work_folder_recover_only_their_own_jobs(self):
        self.config.update(queue_name='{8D53EE44-764E-4EB3-88EF-EAA41A60DF05}', acknowledge=False)
        first = self.run_operation()
        self.assertEqual(first['error'], '')
        self.assertEqual(first['pending_after_ack'], 1)
        before = {p: sha(p.read_bytes()) for p in self.before}
        self.config.update(queue_name='{8384C23B-49B7-4D2F-A240-A49331D51974}',
                           operation_mode='recover', acknowledge=True)
        other = self.run_operation()
        self.assertEqual(other['error'], '')
        self.assertEqual(other['changed_files'], 0)
        self.assertEqual(other['pending_before_ack'], 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)
        self.config['queue_name'] = '{8D53EE44-764E-4EB3-88EF-EAA41A60DF05}'
        own = self.run_operation()
        self.assertEqual(own['error'], '')
        self.assertEqual(own['changed_files'], 1)
        self.assertEqual(own['pending_after_ack'], 0)
        self.assertEqual({p: sha(p.read_bytes()) for p in before}, before)

    @unittest.skipUnless(receipt_fixtures.NATIVE and receipt_fixtures.NATIVE.is_file(), 'Native crash fixture required')
    def test_worker_recovers_crash_after_file_write_before_catalogue_commit(self):
        crashed = self.fixture.run_worker('job-apply', 'file-committed')
        self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
        self.config['work_root'] = str(self.root)
        (self.root / 'queue').rename(self.root / 'jobs')
        self.config['operation_mode'] = 'recover'
        result = self.run_operation()
        self.assert_applied(result)
        self.assertEqual(result['files_done'], 1)
        self.assertFalse(result['savings_known'])

    def test_report_cannot_redirect_the_captured_catalogue_binding(self):
        worker = self.root / 'tampered-report.py'
        worker.write_text('import runpy,sys,json\nfrom pathlib import Path\n'
                          'worker=runpy.run_path(' + repr(self.config['script']) + ',run_name="test_worker")\n'
                          'code=worker["main"]()\n'
                          'if code==0:\n'
                          ' job=json.loads(Path(sys.argv[sys.argv.index("--job")+1]).read_text("utf-8-sig"))\n'
                          ' report=Path(job["report"])\n value=json.loads(report.read_text("utf-8"))\n'
                          ' value["receipt"]["collection_id"]+=1\n'
                          ' report.write_text(json.dumps(value),encoding="utf-8")\n'
                          'sys.exit(code)\n', encoding='utf-8')
        self.config['script'] = str(worker)
        result = self.run_operation()
        self.assertIn('изменил привязку', result['error'])
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_before_ack'], 0)
        self.unchanged()

    def test_stop_reaches_running_producer_without_leaking_a_process(self):
        worker = self.root / 'slow-worker.py'
        worker.write_text('import sys,time,json\nfrom pathlib import Path\n'
                          'cancel=Path(sys.argv[sys.argv.index("--cancel")+1])\n'
                          'print(json.dumps({"stage":"slow-worker"}),flush=True)\n'
                          'while not cancel.exists(): time.sleep(.02)\n'
                          'print(json.dumps({"stage":"cancelled","message":"stopped"}),flush=True)\n'
                          'sys.exit(2)\n', encoding='utf-8')
        self.config.update(script=str(worker), operation_mode='stop-producer')
        result = self.run_operation()
        self.assertTrue(result['stopping'])
        self.assertEqual(result['error'], '')
        self.assertEqual(result['pending_before_ack'], 0)
        self.unchanged()

    def test_invalid_work_root_destroys_an_unstarted_thread_safely(self):
        self.config['work_root'] = ''
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        process = run_owned([str(OPERATOR), str(self.request), str(self.result)], capture_output=True,
                                 encoding='utf-8', errors='strict', timeout=15)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertIn('Нужна папка', process.stdout)
        self.assertFalse(self.result.exists())
        self.unchanged()

    def test_forced_stop_contains_and_reaps_an_uncooperative_process_tree(self):
        worker = self.root / 'uncooperative-worker.py'
        pid_file = self.root / 'worker-child.pid'
        worker.write_text('import sys,time,json,subprocess\nfrom pathlib import Path\n'
                          'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"])\n'
                          'Path(' + repr(str(pid_file)) + ').write_text(str(child.pid))\n'
                          'print(json.dumps({"stage":"slow-worker"}),flush=True)\n'
                          'time.sleep(30)\n', encoding='utf-8')
        self.config.update(script=str(worker), operation_mode='stop-producer')
        result = self.run_operation()
        self.assertTrue(result['stopping'])
        self.assertEqual(result['error'], '')
        self.assertEqual(result['pending_before_ack'], 0)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = (ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
        kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
        process = kernel.OpenProcess(0x100000, False, int(pid_file.read_text()))
        if process:
            try:
                self.assertEqual(kernel.WaitForSingleObject(process, 0), 0, 'Contained child is still running')
            finally:
                kernel.CloseHandle(process)
        self.unchanged()

    def test_native_forced_stop_reclaims_long_alias_without_touching_the_target(self):
        target = self.root / 'long-work'
        while len(str(target)) < 310:
            target /= 'long-working-directory'
        target.mkdir(parents=True)
        original = target / 'kept.txt'
        original.write_bytes(b'Keep the source of this alias')
        ready, observed = self.root / 'alias-child-ready', self.root / 'alias-child.json'
        child_code = ("from pathlib import Path; import time; "
                      "assert Path('kept.txt').read_bytes() == b'Keep the source of this alias'; "
                      'Path(' + repr(str(ready)) + ').write_text("ready"); time.sleep(30)')
        worker = self.root / 'uncooperative-alias-worker.py'
        worker.write_text(
            'import json,subprocess,sys,time\nfrom pathlib import Path\n'
            'sys.path.insert(0,' + repr(str(self.tools / 'bookconvert')) + ')\n'
            'from pack_collection import process_working_directory\n'
            'with process_working_directory(' + repr(str(target)) + ') as alias:\n'
            ' child=subprocess.Popen([sys.executable,"-I","-B","-c",' + repr(child_code) + '],'
            'cwd=alias,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'
            ' deadline=time.monotonic()+5\n'
            ' while not Path(' + repr(str(ready)) + ').exists():\n'
            '  if child.poll() is not None or time.monotonic()>deadline: raise RuntimeError("Child did not enter alias")\n'
            '  time.sleep(.01)\n'
            ' Path(' + repr(str(observed)) + ').write_text(json.dumps({"alias":alias,"child":child.pid}))\n'
            ' print(json.dumps({"stage":"slow-worker"}),flush=True)\n'
            ' time.sleep(30)\n', encoding='utf-8')
        self.config.update(script=str(worker), operation_mode='stop-producer')
        result = self.run_operation()
        self.assertTrue(result['stopping'])
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['pending_before_ack'], 0)
        observation = json.loads(observed.read_text(encoding='utf-8'))
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = (ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
        kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
        child = kernel.OpenProcess(0x100000, False, observation['child'])
        if child:
            try:
                self.assertEqual(kernel.WaitForSingleObject(child, 5000), 0, 'Contained alias child is still running')
            finally:
                kernel.CloseHandle(child)
        else:
            self.assertEqual(ctypes.get_last_error(), 87, 'Alias child termination could not be verified')
        self.assertFalse(os.path.lexists(observation['alias']), 'Native forced stop leaked its short alias')
        self.assertEqual(original.read_bytes(), b'Keep the source of this alias')
        self.unchanged()


if __name__ == '__main__':
    unittest.main()
