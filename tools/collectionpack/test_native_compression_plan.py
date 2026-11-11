"""Read-only selection capture, aliases and native compression application."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import zipfile

import test_native_compression_receipt as receipt_fixtures
from test_native_compression_receipt import NATIVE, database, sha

PLANNER = Path(os.environ['HL_NATIVE_COMPRESSION_PLAN']) if os.environ.get('HL_NATIVE_COMPRESSION_PLAN') else None
RUNTIME = Path(os.environ['HL_COMPRESSION_RUNTIME']) if os.environ.get('HL_COMPRESSION_RUNTIME') else None


@unittest.skipUnless(os.name == 'nt' and PLANNER and PLANNER.is_file() and NATIVE and NATIVE.is_file(),
                     'Built native planner and writer required')
class NativeCompressionPlanTests(unittest.TestCase):
    def setUp(self):
        self.fixture = receipt_fixtures.NativeCompressionReceiptTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.catalogue, self.personal = self.fixture.catalogue, self.fixture.personal
        self.request, self.output = self.root / 'selection.json', self.root / 'selection-plan.json'
        template = self.fixture.template
        self.config = dict(options=dict(collection_id=7, catalogue=str(self.catalogue), personal=str(self.personal),
                                        root=str(self.root), base_root=str(self.root), base_catalogue=str(self.catalogue)),
                           selected=[copy.deepcopy(template['rows'][0])],
                           workspace=str(self.root / 'prepare'), report=str(self.root / 'prepared.json'),
                           seven_zip=str(self.root / '7za.exe'), tools_root=str(self.root / 'tools'),
                           profile='original', grayscale=True)
        self.before = {p: sha(p.read_bytes()) for p in (self.catalogue, self.personal, self.fixture.source)}

    def tearDown(self):
        self.fixture.tearDown()

    def capture(self, success=True):
        self.request.write_text(json.dumps(self.config, ensure_ascii=False), encoding='utf-8')
        process = subprocess.run([str(PLANNER), str(self.request), str(self.output)], capture_output=True,
                                 encoding='utf-8', errors='strict', timeout=30)
        if success:
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            return json.loads(self.output.read_text(encoding='utf-8-sig'))
        self.assertNotEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertFalse(self.output.exists())
        return process.stdout + process.stderr

    def unchanged(self):
        self.assertEqual({p: sha(p.read_bytes()) for p in self.before}, self.before)

    def test_captures_main_personal_and_copy_without_database_snapshot(self):
        result = self.capture()
        self.assertEqual(len(result['files']), 1)
        job = result['files'][0]
        self.assertEqual(job['members'], {'one.fb2': '.fb2'})
        self.assertEqual({r['kind'] for r in job['receipt_template']['rows']}, {0, 1, 2})
        self.assertEqual([r['id'] for r in job['receipt_template']['rows']], [101, 101, 101])
        self.assertEqual(result['examined'], 4)
        self.assertEqual(len(job['receipt_template']['source_file_key']), 25)
        self.assertFalse((self.root / 'prepare').exists())
        self.unchanged()

    def test_two_selected_books_one_archive_and_duplicate_selection(self):
        with database(self.catalogue) as db:
            row = db.execute('SELECT BookID,LibID,Folder,FileName,Ext,InsideNo FROM Books WHERE BookID=102').fetchone()
        self.config['selected'] += [dict(zip(('id', 'lib_id', 'folder', 'file_name', 'ext', 'inside_no'), row)),
                                    copy.deepcopy(self.config['selected'][0])]
        result = self.capture()
        self.assertEqual(len(result['files']), 1)
        self.assertEqual(set(result['files'][0]['members']), {'one.fb2', 'neighbor.fb2'})
        rows = result['files'][0]['receipt_template']['rows']
        self.assertEqual(len(rows), 5)
        self.assertEqual({r['id'] for r in rows if r['kind'] == 1}, {101, 102})
        self.unchanged()

    def test_unselected_alias_of_selected_physical_book_is_captured(self):
        with database(self.catalogue) as db:
            db.execute('INSERT INTO Books SELECT 103,LibID,Folder,FileName,Ext,InsideNo,BookSize,'
                       'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101')
        result = self.capture()
        rows = result['files'][0]['receipt_template']['rows']
        self.assertEqual({r['id'] for r in rows if r['kind'] == 0}, {101, 103})
        self.assertNotIn(102, [r['id'] for r in rows])

    def test_same_archive_name_in_another_source_is_not_the_same_file(self):
        other = self.root / 'another-source'
        other.mkdir()
        shutil.copyfile(self.fixture.source, other / self.fixture.source.name)
        with database(self.catalogue) as db:
            db.execute('INSERT INTO CatalogBookCopies SELECT ?,BookID,?,LibID,Folder,FileName,Ext,InsideNo,BookSize '
                       'FROM CatalogBookCopies', ('other#101', str(other)))
        rows = self.capture()['files'][0]['receipt_template']['rows']
        self.assertEqual({r['source_key'] for r in rows if r['kind'] == 2}, {'source#101'})

    def test_two_archives_produce_independent_jobs(self):
        shutil.copyfile(self.fixture.source, self.root / 'second.zip')
        with database(self.catalogue) as db:
            db.execute("UPDATE Books SET Folder='second.zip',FileName='one' WHERE BookID=102")
        self.config['selected'].append(dict(self.config['selected'][0], id=102, lib_id='flibusta:102',
                                            folder='second.zip', inside_no=1))
        jobs = self.capture()['files']
        self.assertEqual(len(jobs), 2)
        self.assertNotEqual(jobs[0]['receipt_template']['source_file_key'], jobs[1]['receipt_template']['source_file_key'])
        self.assertEqual([len(j['members']) for j in jobs], [1, 1])

    def test_reused_id_with_different_book_is_rejected(self):
        self.config['selected'][0]['lib_id'] = 'replaced:101'
        self.assertIn('изменилась', self.capture(False))
        self.unchanged()

    def test_changed_locator_is_rejected(self):
        self.config['selected'][0]['inside_no'] = 44
        self.capture(False)
        self.unchanged()

    def test_missing_selected_book_is_rejected(self):
        self.config['selected'][0]['id'] = 700
        self.assertIn('больше нет', self.capture(False))
        self.unchanged()

    def test_changed_collection_registration_is_rejected(self):
        self.config['options']['base_root'] += '-changed'
        self.assertIn('Подключение', self.capture(False))
        self.unchanged()

    def test_cancel_before_capture_and_during_scan(self):
        self.config['mode'] = 'cancel'
        self.assertIn('остановлено', self.capture(False))
        self.unchanged()
        with database(self.catalogue) as db:
            db.executemany('INSERT INTO Books SELECT ?,LibID,?,FileName,Ext,InsideNo,BookSize,'
                           'Title,Annotation,Review,Rate,Progress,KeyWords FROM Books WHERE BookID=101',
                           [(1000 + i, 'unrelated\\') for i in range(2048)])
        self.config['mode'] = 'cancel-scan'
        self.assertIn('остановлено', self.capture(False))
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM Books').fetchone()[0], 2050)

    def test_sizes_above_two_gib_are_not_truncated(self):
        with database(self.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=101', (5 * 1024**3,))
        rows = self.capture()['files'][0]['receipt_template']['rows']
        self.assertEqual(next(r['old_size'] for r in rows if r['kind'] == 0), 5 * 1024**3)

    def test_changed_source_after_capture_is_rejected(self):
        self.config['mode'] = 'change-source'
        self.assertIn('Файл книги изменился', self.capture(False))
        self.assertEqual(sha(self.catalogue.read_bytes()), self.before[self.catalogue])
        self.assertEqual(sha(self.personal.read_bytes()), self.before[self.personal])

    def test_compression_ledger_is_forwarded_to_prevent_reencoding(self):
        self.fixture.require_success(self.fixture.run_worker('job-apply'))
        job = self.capture()['files'][0]
        self.assertEqual(job['previous']['one.fb2']['output_sha256'], sha(self.fixture.new_book))
        self.assertEqual(job['previous']['one.fb2']['profile_sha256'], self.fixture.template['profile_sha256'])

    @unittest.skipUnless(RUNTIME and RUNTIME.is_dir(), 'Packaged runtime required')
    def test_captured_selection_to_packaged_converter_to_native_commit(self):
        tools = RUNTIME / 'tools'
        self.config.update(seven_zip=str(tools / '7zip' / '7za.exe'), tools_root=str(tools))
        job = self.capture()['files'][0]
        if getattr(self, 'after_capture', None):
            self.after_capture()
        workspace = Path(job['workspace'])
        workspace.mkdir()
        self.request.write_text(json.dumps(job, ensure_ascii=False), encoding='utf-8')
        process = subprocess.run([str(tools / 'python' / 'python.exe'), '-I', '-B', '-X', 'utf8',
                                  str(tools / 'bookconvert' / 'prepare_book_compression.py'), '--job', str(self.request)],
                                 capture_output=True, encoding='utf-8', errors='strict', timeout=60)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        result = json.loads(Path(job['report']).read_text(encoding='utf-8-sig'))
        self.assertIsNotNone(result['candidate'])
        self.assertEqual({r['kind'] for r in result['receipt']['rows']}, {0, 1, 2})
        self.fixture.template = result['receipt']
        self.fixture.write_template()
        shutil.copyfile(result['candidate'], self.fixture.candidate)
        before_catalogue = self.fixture.snapshot(self.catalogue, sizes=False)
        before_personal = self.fixture.snapshot(self.personal, sizes=False)
        self.fixture.require_success(self.fixture.run_worker('job-apply'))
        self.assertEqual(self.fixture.snapshot(self.catalogue, sizes=False), before_catalogue)
        self.assertEqual(self.fixture.snapshot(self.personal, sizes=False), before_personal)
        with zipfile.ZipFile(self.fixture.source) as archive:
            self.assertEqual(archive.read('neighbor.fb2'), self.fixture.neighbor)
            length = archive.getinfo('one.fb2').file_size
        extracted = subprocess.run([str(tools / '7zip' / '7za.exe'), 'x', '-so', '-y', '-spd', '-ssc', '--',
                                    str(self.fixture.source), 'one.fb2'], capture_output=True, timeout=15)
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        self.assertEqual(len(extracted.stdout), length)
        self.assertIn(b'Same book text; only its grayscale PNG representation changes.', extracted.stdout)
        self.assertEqual(sha(self.fixture.source.read_bytes()), result['result_sha256'])
        with database(self.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0], length)
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], length)
        with database(self.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], length)


if __name__ == '__main__':
    unittest.main()
