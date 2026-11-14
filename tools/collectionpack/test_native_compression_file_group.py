"""Native multi-file replacement ordering, safe stop and durable recovery."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import random
import unittest
import zipfile

import test_native_compression_receipt as fixture


@contextmanager
def group_fixture():
    value = fixture.NativeCompressionReceiptTests()
    value.setUp()
    try:
        value.neighbor = random.Random(113).randbytes(128 * 1024)
        for path, selected in [(value.source, value.original_book), (value.candidate, value.new_book)]:
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('one.fb2', selected)
                archive.writestr('neighbor.fb2', value.neighbor)
        value.original_hash = fixture.sha(value.source.read_bytes())
        value.output_hash = fixture.sha(value.candidate.read_bytes())
        value.template.update(source_sha256=value.original_hash, result_sha256=value.output_hash)
        with fixture.database(value.catalogue) as db:
            db.execute('UPDATE Books SET BookSize=? WHERE BookID=102', (len(value.neighbor),))
        files = [dict(source=str(value.source), candidate=str(value.candidate), source_identity='@source',
            source_sha256=value.original_hash, result_sha256=value.output_hash)]
        value.side_files = []
        for kind in ('covers', 'images'):
            original, candidate = value.root/(kind+'.zip'), value.root/(kind+'-candidate.bin')
            for path, selected, method in [(original, b'original picture' * 30000, zipfile.ZIP_STORED),
                                          (candidate, b'prepared picture' * 10000, zipfile.ZIP_DEFLATED)]:
                with zipfile.ZipFile(path, 'x', method) as archive:
                    archive.writestr('one', selected)
                    archive.writestr('neighbor', value.neighbor)
            files.append(dict(source=str(original), candidate=str(candidate), source_identity='@source',
                source_sha256=fixture.sha(original.read_bytes()), result_sha256=fixture.sha(candidate.read_bytes())))
            value.side_files.append(original)
        value.template['group_files'] = files
        value.write_template()
        value.group = value.root/'group'
        value.before_files = {Path(item['source']): item['source_sha256'] for item in files}
        value.after_files = {Path(item['source']): item['result_sha256'] for item in files}
        value.before_c = value.snapshot(value.catalogue, False)
        value.before_p = value.snapshot(value.personal, False)
        yield value
    finally:
        value.tearDown()


@unittest.skipUnless(os.name == 'nt' and fixture.NATIVE and fixture.NATIVE.is_file(),
                     'Built native grouped compression fixture required')
class NativeCompressionFileGroupTests(unittest.TestCase):
    def unchanged(self, value):
        self.assertEqual({path:fixture.sha(path.read_bytes()) for path in value.before_files}, value.before_files)
        self.assertEqual(value.snapshot(value.catalogue, False), value.before_c)
        self.assertEqual(value.snapshot(value.personal, False), value.before_p)

    def finished(self, value):
        value.require_finished(value.before_c, value.before_p)
        self.assertEqual({path:fixture.sha(path.read_bytes()) for path in value.after_files}, value.after_files)
        for path in value.side_files:
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(archive.read('neighbor'), value.neighbor)
        self.assertFalse(value.group.exists())

    def test_three_archives_commit_then_catalogue_and_clean_only_owned_journals(self):
        with group_fixture() as value:
            value.require_success(value.run_worker('group-apply'))
            self.finished(value)

    def test_stop_before_first_write_keeps_all_originals_and_can_resume(self):
        with group_fixture() as value:
            self.assertNotEqual(value.run_worker('group-cancel').returncode, 0)
            self.unchanged(value)
            self.assertEqual((value.group/'ready').read_text('utf-8-sig'),
                             (value.root/'group-binding.txt').read_text('utf-8-sig'))
            self.assertEqual(len(list(value.group.glob('file-*/zip-delete-*/plan.json'))), 3)
            value.require_success(value.run_worker('group-recover'))
            self.finished(value)

    def test_stop_during_first_archive_finishes_its_entire_linked_group(self):
        with group_fixture() as value:
            value.require_success(value.run_worker('group-stop-after-first'))
            self.finished(value)

    def test_process_crashes_resume_each_file_metadata_and_acknowledgement_boundary(self):
        for stage in ('group-ready', 'group-started', 'group-file-0-half-written', 'group-file-committed-0',
                      'group-file-1-half-written', 'group-file-committed-2', 'catalogue-committed',
                      'group-metadata-committed', 'group-complete', 'group-journal-forgotten-0',
                      'group-journal-forgotten-2'):
            with self.subTest(stage=stage), group_fixture() as value:
                crashed = value.run_worker('group-apply', stage)
                self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
                value.require_success(value.run_worker('group-recover'))
                self.finished(value)

    def test_stop_request_during_recovery_finishes_an_already_started_group(self):
        with group_fixture() as value:
            self.assertEqual(value.run_worker('group-apply', 'group-file-0-half-written').returncode, 73)
            value.require_success(value.run_worker('group-recover-stopping'))
            self.finished(value)

    def test_changed_second_source_prevents_first_source_write(self):
        with group_fixture() as value:
            value.side_files[0].write_bytes(value.side_files[0].read_bytes()+b'changed before preparation')
            value.before_files[value.side_files[0]] = fixture.sha(value.side_files[0].read_bytes())
            self.assertNotEqual(value.run_worker('group-apply').returncode, 0)
            self.unchanged(value)
            self.assertFalse((value.group/'ready').exists())

    def test_changed_manifest_stops_recovery_before_any_source_write(self):
        with group_fixture() as value:
            self.assertEqual(value.run_worker('group-apply', 'group-ready').returncode, 73)
            manifest = value.group/'group.json'
            data = json.loads(manifest.read_text('utf-8-sig'))
            data['files'][1]['result_sha256'] = '0'*64
            manifest.write_text(json.dumps(data), encoding='utf-8')
            self.assertNotEqual(value.run_worker('group-recover').returncode, 0)
            self.unchanged(value)

    def test_foreign_file_prevents_cleanup_after_a_committed_group(self):
        with group_fixture() as value:
            self.assertEqual(value.run_worker('group-apply', 'group-complete').returncode, 73)
            foreign = value.group/'keep.txt'
            foreign.write_bytes(b'Keep this unrelated fixture file')
            self.assertNotEqual(value.run_worker('group-recover').returncode, 0)
            self.assertEqual(foreign.read_bytes(), b'Keep this unrelated fixture file')
            self.assertTrue((value.group/'group.json').is_file())
            self.assertEqual({path:fixture.sha(path.read_bytes()) for path in value.after_files}, value.after_files)
            value.require_finished(value.before_c, value.before_p)

    def require_empty_queue(self, value):
        value.require_success(value.run_worker('job-list'))
        self.assertEqual(json.loads((value.root/'pending.json').read_text('utf-8-sig')), [])
        self.assertEqual(list((value.root/'queue').iterdir()), [])

    def test_persistent_job_queue_applies_and_cleans_linked_archives(self):
        with group_fixture() as value:
            value.require_success(value.run_worker('job-group-apply'))
            self.finished(value)
            self.require_empty_queue(value)

    def test_persistent_job_recovers_group_file_database_and_completion_boundaries(self):
        for stage in ('group-ready', 'group-file-0-half-written', 'catalogue-committed',
                      'group-complete', 'group-journal-forgotten-0', 'completed-published'):
            with self.subTest(stage=stage), group_fixture() as value:
                crashed = value.run_worker('job-group-apply', stage)
                self.assertEqual(crashed.returncode, 73, crashed.stdout + crashed.stderr)
                value.require_success(value.run_worker('job-group-recover'))
                self.finished(value)
                self.require_empty_queue(value)

    def test_changed_completed_image_archive_keeps_the_persistent_job_for_review(self):
        with group_fixture() as value:
            self.assertEqual(value.run_worker('job-group-apply', 'completed-published').returncode, 73)
            source = value.side_files[1]
            source.write_bytes(source.read_bytes()+b'changed after group completion')
            changed_hash = fixture.sha(source.read_bytes())
            self.assertNotEqual(value.run_worker('job-group-recover').returncode, 0)
            self.assertEqual(fixture.sha(source.read_bytes()), changed_hash)
            value.require_success(value.run_worker('job-list'))
            self.assertEqual(len(json.loads((value.root/'pending.json').read_text('utf-8-sig'))), 1)

    def test_catalogue_change_while_preparing_journals_is_checked_before_any_write(self):
        with group_fixture() as value:
            self.assertNotEqual(value.run_worker('job-group-change-row').returncode, 0)
            self.assertEqual({path:fixture.sha(path.read_bytes()) for path in value.before_files}, value.before_files)
            self.assertEqual(value.snapshot(value.personal, False), value.before_p)
            self.assertNotEqual(value.run_worker('job-group-recover').returncode, 0)
            self.assertEqual({path:fixture.sha(path.read_bytes()) for path in value.before_files}, value.before_files)
