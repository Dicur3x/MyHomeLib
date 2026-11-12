"""Real worker thread, packaged codecs, review/stop, catalogue commit/recovery."""
import copy
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
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

    def run_operation(self):
        self.result.unlink(missing_ok=True)
        self.request.write_text(json.dumps(self.config, ensure_ascii=False), encoding='utf-8')
        process = subprocess.run([str(OPERATOR), str(self.request), str(self.result)], capture_output=True,
                                 encoding='utf-8', errors='strict', timeout=45)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        result = json.loads(self.result.read_text(encoding='utf-8-sig'))
        self.assertEqual(result.get('warning', ''), '', result)
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

    def test_preview_does_not_change_original_before_approval(self):
        self.config['operation_mode'] = 'review-apply'
        result = self.run_operation()
        self.assertTrue(result['review_seen'])
        self.assertEqual(result['before_review_sha256'], self.before[self.fixture.source])
        self.assert_applied(result)

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
        process = subprocess.run([str(OPERATOR), str(self.request), str(self.result)], capture_output=True,
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


if __name__ == '__main__':
    unittest.main()
