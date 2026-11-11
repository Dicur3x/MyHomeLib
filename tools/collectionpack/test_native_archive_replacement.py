"""Real Windows writer and crash recovery, using exclusively synthetic fixtures.

Build tools/ui/tests/ArchiveReplacementTest.dproj and set HL_NATIVE_REPLACEMENT.
HLRU_PACK_7ZIP selects the verified installed codec for ZIP/solid-7z cases.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

from archive_replacement import prepare_archive_replacement
from pack_collection import SevenZip, temporary_work_directory


NATIVE = Path(os.environ['HL_NATIVE_REPLACEMENT']) if os.environ.get('HL_NATIVE_REPLACEMENT') else None
SEVEN = Path(os.environ['HLRU_PACK_7ZIP']) if os.environ.get('HLRU_PACK_7ZIP') else None


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


@unittest.skipUnless(os.name == 'nt' and NATIVE and NATIVE.is_file(), 'Built Windows regression worker required')
class NativeArchiveReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-native-replacement-')
        self.root = self.temp.__enter__()
        (self.root / 'fixture-owner.txt').write_text('HomeLibre archive replacement regression')
        self.source, self.candidate = self.root / 'source.bin', self.root / 'candidate.bin'
        self.journal, self.report = self.root / 'journal', self.root / 'job.txt'

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def fixture(self, small=False):
        self.source.write_bytes(os.urandom(8 * 1024 * 1024))
        self.candidate.write_bytes(os.urandom(137 if small else 5 * 1024 * 1024 + 173))
        self.input_hash, self.output_hash = sha(self.source), sha(self.candidate)
        self.file_id = self.source.stat().st_ino

    def run_worker(self, mode='apply', fault='-', hold=False, source_hash=None, result_hash=None):
        return subprocess.run([str(NATIVE), str(self.root), str(self.source), str(self.candidate),
            str(self.journal), mode, fault, source_hash or self.input_hash,
            result_hash or self.output_hash, 'hold' if hold else 'ack'],
            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30)

    def require_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def require_finished(self):
        self.assertEqual(sha(self.source), self.output_hash)
        self.assertEqual(self.source.stat().st_ino, self.file_id)
        self.assertFalse(self.candidate.exists())
        self.assertFalse([p for p in self.journal.rglob('*') if p.is_file()] if self.journal.exists() else [])

    def test_preparation_does_not_change_source(self):
        self.fixture()
        self.require_success(self.run_worker('prepare-only'))
        self.assertEqual(sha(self.source), self.input_hash)
        self.assertFalse(list(self.journal.glob('*')))

    def test_small_file_and_whole_deletion_guard(self):
        self.fixture(small=True)
        self.require_success(self.run_worker())
        self.require_finished()

    def test_unicode_paths_and_separate_compression_journal(self):
        self.fixture()
        source = self.root / 'Подборка ё.bin'
        candidate = self.root / 'Сжатая копия ё.bin'
        self.source.rename(source)
        self.candidate.rename(candidate)
        self.source, self.candidate = source, candidate
        self.journal = self.root / 'Журнал сжатия ё'
        self.require_success(self.run_worker())
        self.require_finished()

    def test_rejects_identity_digest_growth_cancel_and_no_space_before_mutation(self):
        for mode, options in [('wrong-identity', {}), ('apply', {'source_hash': '0' * 64}),
                ('apply', {'result_hash': '0' * 64}), ('cancel', {}), ('no-space', {})]:
            with self.subTest(mode=mode, options=options):
                self.fixture()
                result = self.run_worker(mode, **options)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(sha(self.source), self.input_hash)
                self.assertFalse(list(self.journal.glob('*')) if self.journal.exists() else [])
        self.fixture(small=True)
        self.source.write_bytes(b'small')
        self.input_hash = sha(self.source)
        self.assertNotEqual(self.run_worker().returncode, 0)
        self.assertEqual(sha(self.source), self.input_hash)

    def test_actual_process_crash_recovery_at_each_durable_boundary(self):
        for stage in ['pending', 'half-written', 'written', 'checkpoint', 'half-metadata',
                      'metadata', 'truncated', 'finished']:
            with self.subTest(stage=stage):
                self.fixture()
                result = self.run_worker(fault=stage)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                job = Path(self.report.read_text(encoding='utf-8-sig'))
                self.assertTrue(job.is_relative_to(self.journal))
                self.assertEqual(json.loads((job / 'plan.json').read_text(encoding='utf-8'))['kind'],
                                 'collection-compression')
                self.assertLessEqual(sum(p.stat().st_size for p in job.iterdir()),
                                     5 * 1024 * 1024 + 2 * 4 * 1024 * 1024 + 256 * 1024)
                self.require_success(self.run_worker('recover'))
                self.require_finished()

    def test_rejects_compression_journal_in_deletion_recovery(self):
        self.fixture()
        self.assertEqual(self.run_worker(fault='pending').returncode, 73)
        before = sha(self.source)
        self.assertNotEqual(self.run_worker('wrong-recovery-kind').returncode, 0)
        self.assertEqual(sha(self.source), before)
        self.require_success(self.run_worker('recover'))
        self.require_finished()

    def test_rejects_damaged_pending_block_then_can_resume(self):
        self.fixture()
        self.assertEqual(self.run_worker(fault='half-written').returncode, 73)
        job = Path(self.report.read_text(encoding='utf-8-sig'))
        pending = job / 'pending.bin'
        correct, before = pending.read_bytes(), sha(self.source)
        damaged = bytearray(correct)
        damaged[0] ^= 255
        pending.write_bytes(damaged)
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(sha(self.source), before)
        pending.write_bytes(correct)
        self.require_success(self.run_worker('recover'))
        self.require_finished()

    def test_rejects_damaged_future_replacement_before_new_writes(self):
        self.fixture()
        self.assertEqual(self.run_worker(fault='checkpoint').returncode, 73)
        job = Path(self.report.read_text(encoding='utf-8-sig'))
        replacement = job / 'replacement.bin'
        correct, before = replacement.read_bytes(), sha(self.source)
        data = bytearray(correct)
        data[4 * 1024 * 1024] ^= 255
        replacement.write_bytes(data)
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(sha(self.source), before)
        replacement.write_bytes(correct)
        self.require_success(self.run_worker('recover'))
        self.require_finished()

    def test_rejects_external_changes_to_completed_blocks(self):
        self.fixture()
        self.assertEqual(self.run_worker(fault='checkpoint').returncode, 73)
        correct = self.source.read_bytes()
        damaged = bytearray(correct)
        damaged[0] ^= 255
        self.source.write_bytes(damaged)
        before = sha(self.source)
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(sha(self.source), before)
        self.source.write_bytes(correct)
        self.require_success(self.run_worker('recover'))
        self.require_finished()

    def test_rejects_external_changes_to_unwritten_original(self):
        self.fixture()
        self.assertEqual(self.run_worker(fault='checkpoint').returncode, 73)
        correct = self.source.read_bytes()
        data = bytearray(correct)
        data[-1] ^= 255
        self.source.write_bytes(data)
        before = sha(self.source)
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(sha(self.source), before)
        self.source.write_bytes(correct)
        self.require_success(self.run_worker('recover'))
        self.require_finished()

    def test_rejects_hardlinked_source_and_candidate(self):
        for target in ['source', 'candidate']:
            with self.subTest(target=target):
                self.fixture()
                link = self.root / 'other-link.bin'
                os.link(getattr(self, target), link)
                try:
                    self.assertNotEqual(self.run_worker().returncode, 0)
                    self.assertEqual(sha(self.source), self.input_hash)
                    self.assertEqual(sha(self.candidate), self.output_hash)
                finally:
                    link.unlink()

    def test_existing_zip_deletion_and_its_crash_recovery_remain_separate(self):
        neighbor = os.urandom(5 * 1024 * 1024)
        self.source = self.root / 'delete-source.zip'
        with zipfile.ZipFile(self.source, 'w') as archive:
            archive.writestr('one.fb2', os.urandom(2 * 1024 * 1024))
            archive.writestr('neighbor.fb2', neighbor)
        self.input_hash, self.output_hash = sha(self.source), 'a' * 64
        self.assertEqual(self.run_worker('delete', fault='half-written').returncode, 73)
        before = sha(self.source)
        self.assertNotEqual(self.run_worker('recover').returncode, 0)
        self.assertEqual(sha(self.source), before)
        self.require_success(self.run_worker('recover-delete'))
        with zipfile.ZipFile(self.source) as archive:
            self.assertEqual(archive.namelist(), ['neighbor.fb2'])
            self.assertEqual(archive.read('neighbor.fb2'), neighbor)

    @unittest.skipUnless(SEVEN and SEVEN.is_file(), 'Installed 7-Zip required')
    def test_real_zip_and_solid_sevenzip_keep_neighbors_and_comments(self):
        neighbor = os.urandom(5 * 1024 * 1024)
        book = os.urandom(2 * 1024 * 1024)
        new_book = b'Unchanged book text; smaller illustrations.' * 200
        seven = SevenZip(SEVEN, lambda: None)
        for kind in ['zip', '7z']:
            with self.subTest(kind=kind):
                inputs = self.root / ('inputs-' + kind)
                inputs.mkdir()
                (inputs / 'one.fb2').write_bytes(book)
                (inputs / 'neighbor.fb2').write_bytes(neighbor)
                self.source = self.root / ('collection.' + kind)
                if kind == 'zip':
                    with zipfile.ZipFile(self.source, 'w') as archive:
                        archive.comment = b'collection comment'
                        for name in ['one.fb2', 'neighbor.fb2']:
                            info = zipfile.ZipInfo(name)
                            info.comment = b'member ' + name.encode()
                            archive.writestr(info, (inputs / name).read_bytes())
                else:
                    seven.run(['a', '-t7z', '-ms=on', str(self.source), 'one.fb2', 'neighbor.fb2'], cwd=inputs)
                replacement = self.root / ('new-' + kind + '.fb2')
                replacement.write_bytes(new_book)
                work = self.root / ('work-' + kind)
                work.mkdir()
                prepared = prepare_archive_replacement(self.source, {'one.fb2': replacement}, work, SEVEN)
                self.assertIsNotNone(prepared.candidate)
                self.candidate = prepared.candidate
                self.input_hash, self.output_hash = sha(self.source), sha(self.candidate)
                self.file_id = self.source.stat().st_ino
                self.require_success(self.run_worker())
                self.require_finished()
                extracted = self.root / 'extracted.bin'
                for member, expected in [('one.fb2', new_book), ('neighbor.fb2', neighbor)]:
                    seven.extract(self.source, member, extracted, self.root)
                    self.assertEqual(extracted.read_bytes(), expected)
                    extracted.unlink()
                if kind == 'zip':
                    with zipfile.ZipFile(self.source) as archive:
                        self.assertEqual(archive.comment, b'collection comment')
                        for member in archive.infolist():
                            self.assertEqual(member.comment, b'member ' + member.filename.encode())


if __name__ == '__main__':
    unittest.main()
