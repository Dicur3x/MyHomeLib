"""Small owned source on a second volume; preparation, stores and backup on G:."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import unittest
from xml.etree import ElementTree as ET

from pack_collection import reserve_space, temporary_work_directory
import test_native_compression_operation as operations
from test_native_compression_receipt import database, sha
from validate_catalogue_compression import archive_body


@unittest.skipUnless(os.name == 'nt' and operations.OPERATOR and operations.RUNTIME and os.environ.get('HL_COMPRESSION_SOURCE_VOLUME'),
                     'Explicit second-volume parent and private native runtime required')
class CrossVolumeCompressionTests(unittest.TestCase):
    def setUp(self):
        self.owned = ExitStack()
        self.addCleanup(self.owned.close)
        self.operation = operations.NativeCompressionOperationTests()
        self.operation.setUp()
        self.owned.callback(self.operation.tearDown)
        self.root = self.operation.root
        parent = Path(os.environ['HL_COMPRESSION_SOURCE_VOLUME']).resolve(strict=True)
        reserve_space(parent, 2 * 1024**2)
        self.source_root = self.owned.enter_context(
            temporary_work_directory(parent, 'HomeLibre-cross-volume-source-'))
        self.assertNotEqual(self.source_root.stat().st_dev, self.root.stat().st_dev,
                            'The test requires different real Windows volumes')
        self.original_source = self.operation.fixture.source
        self.original_hash = sha(self.original_source.read_bytes())
        self.assertLess(self.original_source.stat().st_size, 2 * 1024**2)
        self.source = self.source_root / 'books.zip'
        shutil.copy2(self.original_source, self.source)
        (self.source_root / 'fixture-owner.txt').write_text('HomeLibre small cross-volume regression', encoding='utf-8')
        self.operation.fixture.source = self.source
        options = self.operation.config['options']
        options.update(root=str(self.source_root), base_root=str(self.source_root))
        with database(self.operation.fixture.catalogue) as db:
            db.execute('UPDATE CatalogBookCopies SET Root=?', (str(self.source_root),))
        with database(self.operation.fixture.personal) as db:
            db.execute('UPDATE Bases SET RootFolder=? WHERE DatabaseID=7', (str(self.source_root),))
        self.operation.catalogue = self.operation.fixture.snapshot(self.operation.fixture.catalogue, sizes=False)
        self.operation.personal = self.operation.fixture.snapshot(self.operation.fixture.personal, sizes=False)
        self.operation.before = {p: sha(p.read_bytes()) for p in (
            self.source, self.operation.fixture.catalogue, self.operation.fixture.personal)}
        self.work = Path(self.operation.config['work_root'])
        self.assertEqual(self.work.parent.stat().st_dev, self.root.stat().st_dev)
        self.passed = False
        self.proof = dict(case=self._testMethodName, source_volume=self.source.anchor,
                          source_device=self.source_root.stat().st_dev, work_volume=self.work.anchor,
                          work_device=self.root.stat().st_dev, initial_archive_bytes=self.source.stat().st_size)

    def tearDown(self):
        self.owned.close()
        self.assertFalse(self.source_root.exists(), 'Owned second-volume source was not removed')
        self.assertFalse(self.root.exists(), 'Owned stores and work were not removed')
        path = Path(os.environ['HL_CROSS_VOLUME_EVIDENCE'])
        records = json.loads(path.read_text(encoding='utf-8')) if path.exists() else []
        records.append(dict(self.proof, status='PASS' if self.passed else 'FAIL',
                            source_removed=True, stores_and_work_removed=True))
        path.write_text(json.dumps(records, indent=2), encoding='utf-8')

    def check_source_folder(self):
        self.assertEqual({p.name for p in self.source_root.iterdir()}, {'books.zip', 'fixture-owner.txt'})
        self.assertEqual(sha(self.original_source.read_bytes()), self.original_hash,
                         'An unused source on the work volume was changed')
        reserve_space(self.source_root, 0)

    def test_apply_backup_and_fresh_worker_recovery_across_volumes(self):
        backup = self.operation.enable_backup()
        self.assertEqual(backup.parent.stat().st_dev, self.root.stat().st_dev)
        self.operation.config['acknowledge'] = False
        result = self.operation.run_operation()
        self.operation.assert_applied(result, pending_after_ack=1)
        import zipfile
        selected = archive_body(self.source, 'one.fb2', Path(self.operation.config['seven_zip']))
        self.assertNotEqual(sha(selected), sha(self.operation.fixture.original_book))
        original_xml, output_xml = ET.fromstring(self.operation.fixture.original_book), ET.fromstring(selected)
        for tree in (original_xml, output_xml):
            for node in tree.iter('{http://www.gribuser.ru/xml/fictionbook/2.0}binary'):
                node.text = ''
        self.assertEqual(ET.tostring(original_xml), ET.tostring(output_xml), 'Compression changed non-image FB2 content')
        self.assertEqual(result['backup_files'], 1, result)
        archives = list(backup.glob('*.zip'))
        self.assertEqual(len(archives), 1)
        with zipfile.ZipFile(archives[0]) as archive:
            self.assertEqual(archive.read('books/one.fb2'), self.operation.fixture.original_book)
        authoritative = {p: sha(p.read_bytes()) for p in (
            self.source, self.operation.fixture.catalogue, self.operation.fixture.personal, archives[0])}
        self.operation.config.update(operation_mode='recover', acknowledge=True)
        recovered = self.operation.run_operation()
        self.assertEqual(recovered['error'], '', recovered)
        self.assertEqual((recovered['changed_files'], recovered['pending_before_ack'], recovered['pending_after_ack']),
                         (1, 1, 0), recovered)
        self.assertEqual({p: sha(p.read_bytes()) for p in authoritative}, authoritative)
        self.assertFalse(list((self.work / 'jobs').glob('compress-*')))
        self.check_source_folder()
        self.proof.update(final_archive_bytes=self.source.stat().st_size,
                          approved_archive_sha256=authoritative[self.source],
                          backup_sha256=authoritative[archives[0]], fresh_worker_recovery=True,
                          non_image_content_equal=True)
        self.passed = True

    def test_stop_before_replacement_preserves_second_volume_source(self):
        backup = self.operation.enable_backup()
        self.operation.config['operation_mode'] = 'review-stop'
        result = self.operation.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertTrue(result['review_seen'])
        self.assertTrue(result['stopping'])
        self.assertEqual(result['changed_files'], 0)
        self.assertEqual(result['pending_after_ack'], 0)
        self.assertEqual(list(backup.iterdir()), [])
        self.operation.unchanged()
        self.check_source_folder()
        self.passed = True

    def test_crash_before_approval_cleans_only_work_volume_preparation(self):
        preparation, backup = self.operation.leave_unapproved_preparation()
        self.assertEqual(preparation.stat().st_dev, self.root.stat().st_dev)
        self.operation.config['operation_mode'] = 'recover'
        recovered = self.operation.run_operation()
        self.assertEqual(recovered['error'], '', recovered)
        self.assertEqual(recovered['discarded_preparations'], 1)
        self.assertEqual(recovered['changed_files'], 0)
        self.assertEqual(list(backup.iterdir()), [])
        self.operation.unchanged()
        self.check_source_folder()
        self.passed = True
