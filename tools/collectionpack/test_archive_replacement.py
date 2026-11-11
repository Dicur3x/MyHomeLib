"""Selected-member preparation with real ZIP/solid-7z archives on test copies."""
import hashlib
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import zipfile

from archive_replacement import prepare_archive_replacement, restore_zip_comments
from pack_collection import Canceled, PackingError, SevenZip, temporary_work_directory


SEVEN = Path(os.environ.get('HLRU_PACK_7ZIP', '../../Program/Out/Bin64/tools/7zip/7za.exe')).absolute()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ArchiveReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-member-compression-')
        self.root = self.temp.__enter__()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.seven = SevenZip(SEVEN, lambda: None)

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def source_zip(self, entries=None):
        source = self.root / 'collection.zip'
        entries = entries or {'one.fb2': os.urandom(128 * 1024), 'neighbor.fb2': os.urandom(8192)}
        with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.comment = b'Original collection comment'
            for name, data in entries.items():
                info = zipfile.ZipInfo(name, (2020, 1, 2, 3, 4, 6))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.comment = b'Keep member comment ' + name.encode('utf-8')
                archive.writestr(info, data)
        return source

    def updated(self, name='replacement.fb2', data=b'New book text ' * 100):
        result = self.root / name
        result.write_bytes(data)
        os.utime(result, (1000000000, 1000000000))
        return result

    def extracted(self, archive, member):
        target = self.root / 'verification.tmp'
        try:
            self.seven.extract(archive, member, target, self.root)
            return target.read_bytes()
        finally:
            target.unlink(missing_ok=True)

    def test_selected_zip_books_change_neighbors_and_comments_stay_intact(self):
        neighbors = {'cover.png': os.urandom(1024), 'nested/Neighbor.fb2': b'Neighbor text ' * 200}
        entries = {'one.fb2': os.urandom(128 * 1024), 'two.fb2': os.urandom(128 * 1024), **neighbors}
        source = self.source_zip(entries)
        first, second = self.updated(), self.updated('another.fb2', b'Second text ' * 100)
        original, inputs = sha(source), [sha(first), sha(second)]
        result = prepare_archive_replacement(source, {'one.fb2': first, 'two.fb2': second}, self.work, SEVEN)
        self.assertIsNotNone(result.candidate)
        self.assertLess(result.output_bytes, result.input_bytes)
        self.assertEqual(result.members, ('one.fb2', 'two.fb2'))
        with zipfile.ZipFile(source) as before, zipfile.ZipFile(result.candidate) as after:
            self.assertEqual(set(after.namelist()), set(entries))
            self.assertEqual(after.comment, before.comment)
            for member in entries:
                self.assertEqual(after.getinfo(member).comment, before.getinfo(member).comment)
                self.assertEqual(after.read(member), {'one.fb2': first.read_bytes(), 'two.fb2': second.read_bytes()}.get(member, entries[member]))
        self.assertEqual(sha(source), original)
        self.assertEqual([sha(first), sha(second)], inputs)

    def test_solid_sevenzip_replaces_selected_book_without_losing_neighbor(self):
        inputs = self.root / 'inputs'
        inputs.mkdir()
        (inputs / 'one.fb2').write_bytes(os.urandom(128 * 1024))
        neighbor = b'Keep this neighboring book exactly ' * 200
        (inputs / 'neighbor.fb2').write_bytes(neighbor)
        source = self.root / 'collection.7z'
        self.seven.run(['a', '-t7z', '-m0=LZMA2', '-ms=on', '-mmt=2', str(source), 'one.fb2', 'neighbor.fb2'], cwd=inputs)
        original = sha(source)
        replacement = self.updated()
        result = prepare_archive_replacement(source, {'one.fb2': replacement}, self.work, SEVEN)
        self.assertIsNotNone(result.candidate)
        self.assertEqual(self.extracted(result.candidate, 'one.fb2'), replacement.read_bytes())
        self.assertEqual(self.extracted(result.candidate, 'neighbor.fb2'), neighbor)
        self.assertLess(result.output_bytes, result.input_bytes)
        self.assertEqual(sha(source), original)

    def test_larger_candidate_is_discarded_without_replacing_source(self):
        source = self.source_zip({'one.fb2': b'Compact original ' * 2000})
        original = sha(source)
        result = prepare_archive_replacement(source, {'one.fb2': self.updated(data=os.urandom(128 * 1024))}, self.work, SEVEN)
        self.assertIsNone(result.candidate)
        self.assertEqual(result.input_bytes, result.output_bytes)
        self.assertEqual(result.prepared_sha256, original)
        self.assertEqual(sha(source), original)
        self.assertFalse(list(self.work.glob('prepared.*')))

    def test_exact_unicode_case_and_literal_names_survive_ppmd_zip_update(self):
        entries = {'nested/Книга.fb2': os.urandom(128 * 1024),
                   'nested/книга.fb2': b'Keep the lower-case different book',
                   '@reader.txt': b'Keep literal at sign', '-option.txt': b'Keep leading minus'}
        source = self.source_zip(entries)
        original = sha(source)
        replacement = self.updated()
        result = prepare_archive_replacement(source, {'nested/Книга.fb2': replacement}, self.work, SEVEN, method='PPMd')
        self.assertIsNotNone(result.candidate)
        for member, content in entries.items():
            self.assertEqual(self.extracted(result.candidate, member),
                             replacement.read_bytes() if member == 'nested/Книга.fb2' else content)
        self.assertEqual(sha(source), original)

    def test_changed_neighbor_is_detected_before_any_source_write(self):
        source = self.source_zip()
        original = sha(source)
        run = SevenZip.run

        def corrupt(seven, arguments, *args, **kwargs):
            result = run(seven, arguments, *args, **kwargs)
            if arguments[0] == 'u':
                candidate = Path(next(a.split('!', 1)[1] for a in arguments if a.startswith('-up')))
                with zipfile.ZipFile(candidate) as archive:
                    entries = {i.filename: archive.read(i) for i in archive.infolist()}
                entries['neighbor.fb2'] = b'Wrong neighboring book'
                with zipfile.ZipFile(candidate, 'w', zipfile.ZIP_DEFLATED) as archive:
                    for name, data in entries.items():
                        archive.writestr(name, data)
            return result

        with patch.object(SevenZip, 'run', corrupt), self.assertRaisesRegex(PackingError, 'соседняя'):
            prepare_archive_replacement(source, {'one.fb2': self.updated()}, self.work, SEVEN)
        self.assertEqual(sha(source), original)
        self.assertFalse(list(self.work.glob('prepared.*')))

    def test_comment_rewrite_keeps_zip64_end_offsets_valid(self):
        entries = {'Книга.fb2': b'Keep text ' * 400, 'empty/': b''}
        source = self.source_zip(entries)
        original = sha(source)
        candidate = self.work / 'zip64.zip'
        with patch('zipfile.ZIP64_LIMIT', 128):
            with zipfile.ZipFile(candidate, 'w', zipfile.ZIP_STORED) as archive:
                archive.comment = b'x'
                for name, data in entries.items():
                    archive.writestr(name, data)
        self.assertIn(b'PK\x06\x06', candidate.read_bytes())
        restore_zip_comments(source, candidate)
        self.seven.run(['t', '-bb0', '-bso0', '-bsp0', '--', str(candidate)], cwd=self.work)
        with zipfile.ZipFile(source) as before, zipfile.ZipFile(candidate) as after:
            self.assertEqual(before.comment, after.comment)
            for name, content in entries.items():
                self.assertEqual(after.read(name), content)
                self.assertEqual(after.getinfo(name).comment, before.getinfo(name).comment)
        self.assertEqual(sha(source), original)

    def test_empty_directories_and_unselected_members_remain_in_zip(self):
        entries = {'one.fb2': os.urandom(128 * 1024), 'empty/': b'',
                   'nested/': b'', 'nested/neighbor.txt': b'Neighbor'}
        source = self.source_zip(entries)
        original = sha(source)
        result = prepare_archive_replacement(source, {'one.fb2': self.updated()}, self.work, SEVEN)
        self.assertIsNotNone(result.candidate)
        with zipfile.ZipFile(result.candidate) as archive:
            self.assertEqual(set(archive.namelist()), set(entries))
            self.assertTrue(archive.getinfo('empty/').is_dir())
            self.assertEqual(archive.read('nested/neighbor.txt'), entries['nested/neighbor.txt'])
        self.assertEqual(sha(source), original)

    def test_unknown_or_unsafe_member_never_changes_archive(self):
        source = self.source_zip()
        original = sha(source)
        for name in ('missing.fb2', '../outside.fb2', '/absolute.fb2', 'NUL.txt', 'one.fb2:stream', 'one.fb2\nneighbor.fb2'):
            with self.subTest(member=name):
                work = self.root / ('work-' + str(len(list(self.root.glob('work-*')))))
                work.mkdir()
                with self.assertRaises(PackingError):
                    prepare_archive_replacement(source, {name: self.updated()}, work, SEVEN)
                self.assertEqual(sha(source), original)
                self.assertFalse(list(work.glob('prepared.*')))
        self.assertFalse((self.root / 'outside.fb2').exists())

    def test_cancellation_discards_preparation_and_preserves_original(self):
        source = self.source_zip()
        original = sha(source)
        with self.assertRaises(Canceled):
            prepare_archive_replacement(source, {'one.fb2': self.updated()}, self.work, SEVEN,
                                        canceled=lambda: any(self.work.glob('prepared.*')))
        self.assertEqual(sha(source), original)
        self.assertFalse(list(self.work.glob('prepared.*')))

    def test_external_source_change_rejects_prepared_result(self):
        source = self.source_zip()
        run = SevenZip.run
        changed = []

        def interfere(seven, arguments, *args, **kwargs):
            result = run(seven, arguments, *args, **kwargs)
            if arguments[0] == 't':
                with source.open('ab') as stream:
                    stream.write(b'External change')
                changed.append(True)
            return result

        with patch.object(SevenZip, 'run', interfere), self.assertRaisesRegex(PackingError, 'изменился'):
            prepare_archive_replacement(source, {'one.fb2': self.updated()}, self.work, SEVEN)
        self.assertEqual(changed, [True])
        self.assertTrue(source.read_bytes().endswith(b'External change'))
        self.assertFalse(list(self.work.glob('prepared.*')))


class TemporaryWorkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='HomeLibre-workspace-test-')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_replaced_work_directory_is_not_deleted(self):
        with self.assertRaisesRegex(PackingError, 'изменила'):
            with temporary_work_directory(self.root, 'owned-') as work:
                (work / 'owned.txt').write_text('Owned input', encoding='utf-8')
                work.rename(self.root / 'moved')
                work.mkdir()
                (work / 'other.txt').write_text('Keep replacement directory', encoding='utf-8')
        self.assertEqual((work / 'other.txt').read_text(encoding='utf-8'), 'Keep replacement directory')
        self.assertEqual((self.root / 'moved/owned.txt').read_text(encoding='utf-8'), 'Owned input')

    @unittest.skipUnless(os.name == 'nt', 'Windows sharing-mode semantics')
    def test_short_windows_file_lock_is_released_before_cleanup_finishes(self):
        lock, release = None, None
        try:
            with temporary_work_directory(self.root, 'owned-') as work:
                file = work / 'locked.bin'
                file.write_bytes(b'Owned temporary data')
                lock = file.open('rb')
                release = threading.Thread(target=lambda: (time.sleep(.12), lock.close()))
                release.start()
            self.assertFalse(work.exists())
        finally:
            if release is not None:
                release.join(2)
            if lock is not None:
                lock.close()

    @unittest.skipUnless(os.name == 'nt', 'Windows sharing-mode semantics')
    def test_persistent_windows_lock_is_reported_and_retains_owned_directory(self):
        lock = None
        try:
            with self.assertRaises(OSError):
                with temporary_work_directory(self.root, 'owned-') as work:
                    file = work / 'locked.bin'
                    file.write_bytes(b'Keep on persistent cleanup failure')
                    lock = file.open('rb')
        finally:
            if lock is not None:
                lock.close()
        self.assertEqual(file.read_bytes(), b'Keep on persistent cleanup failure')


if __name__ == '__main__':
    unittest.main()
