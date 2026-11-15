"""Read-only native transfer plans on isolated roots; no payload transfer yet."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import zipfile

from pack_collection import temporary_work_directory, process_working_directory


BINARY = Path(os.environ['HL_TRANSFER_PLAN']) if os.environ.get('HL_TRANSFER_PLAN') else None
SQLITE = Path(os.environ['HL_TRANSFER_SQLITE']) if os.environ.get('HL_TRANSFER_SQLITE') else None
SEVENZIP = Path(os.environ['HL_TRANSFER_7ZIP']) if os.environ.get('HL_TRANSFER_7ZIP') else None
STAGE = Path(os.environ['HL_TRANSFER_STAGE']) if os.environ.get('HL_TRANSFER_STAGE') else None


@unittest.skipUnless(os.name == 'nt' and all(p and p.is_file() for p in (BINARY, SQLITE, SEVENZIP)) and STAGE,
                     'requires native transfer planner, SQLite, 7-Zip and owned stage')
class TransferPlanTests(unittest.TestCase):
    def setUp(self):
        self.owned = temporary_work_directory(STAGE, 'HomeLibRu-native-')
        self.root = Path(self.owned.__enter__())
        shutil.copy2(BINARY, self.root / 'CollectionTransferPlanTest.exe')
        shutil.copy2(SQLITE, self.root / 'sqlite3.dll')
        for name in ('uselocaldata', 'uselocaltemp'):
            (self.root / name).touch()
        (self.root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        for name in ('source-a', 'source-b', 'destination', 'scratch'):
            (self.root / name).mkdir()
        self.a, self.b, self.destination = (self.root / name for name in ('source-a', 'source-b', 'destination'))
        self.write_zip(self.a / 'same.zip', b'<FictionBook>first</FictionBook>')
        self.write_zip(self.b / 'same.zip', b'<FictionBook>second</FictionBook>')
        self.request, self.output = self.root / 'request.json', self.root / 'result.json'
        self.config = dict(destination=str(self.destination), work=str(self.root / 'scratch'),
            operation='{D1589EF9-3408-4DB8-993B-141D905A492A}',
            roots=[dict(id='a', path=str(self.a)), dict(id='b', path=str(self.b))],
            inputs=[dict(root='a', file=str(self.a / 'same.zip')), dict(root='b', file=str(self.b / 'same.zip'))])
        self.before = self.snapshot()

    def tearDown(self):
        root = self.root
        self.owned.__exit__(None, None, None)
        self.assertFalse(root.exists(), 'owned runtime was not removed')

    @staticmethod
    def write_zip(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_STORED) as archive:
            archive.writestr('101.fb2', body)

    def snapshot(self):
        return {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for directory in (self.a, self.b, self.destination) for path in directory.rglob('*') if path.is_file()}

    def make_flibrary(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        seed = self.root / 'seed.fb2'
        seed.write_text('<FictionBook>split images</FictionBook>', encoding='utf-8')
        archive = directory / 'library.7z'
        result = subprocess.run([str(SEVENZIP), 'a', '-t7z', '-mx=0', str(archive), str(seed)],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return archive

    def capture(self, success=True):
        self.output.unlink(missing_ok=True)
        self.request.write_text(json.dumps(self.config), encoding='utf-8')
        result = subprocess.run([str(self.root / 'CollectionTransferPlanTest.exe'), str(self.request), str(self.output)],
            cwd=self.root, capture_output=True, timeout=60, env={**os.environ, 'TEMP': str(self.root), 'TMP': str(self.root)})
        self.assertFalse(list((self.root / 'scratch').glob('collection-plan-*')), 'scratch plan remained')
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(self.output.read_text(encoding='utf-8-sig'))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.output.exists(), 'failed plan published a result')
        return (result.stdout + result.stderr).decode('utf-8', errors='replace')

    def test_same_archive_name_in_two_sources_keeps_both(self):
        result = self.capture()
        self.assertEqual((result['files'], result['copy_files'], result['examined']), (2, 2, 2))
        self.assertEqual(result['copy_bytes'], sum(p.stat().st_size for p in (self.a / 'same.zip', self.b / 'same.zip')))
        destinations = [Path(item['destination']) for item in result['entries']]
        self.assertEqual({p.name for p in destinations}, {'same.zip'})
        self.assertEqual(len({str(p).casefold() for p in destinations}), 2)
        self.assertTrue(all(p.is_relative_to(self.destination) and not p.exists() for p in destinations))
        self.assertEqual(self.snapshot(), self.before)

    def test_first_source_is_destination_and_stays_in_place(self):
        self.config['destination'] = str(self.a)
        result = self.capture()
        self.assertEqual((result['files'], result['copy_files']), (2, 1))
        kept = [row for row in result['entries'] if row['keep']]
        self.assertEqual(len(kept), 1)
        self.assertEqual(Path(kept[0]['source']), Path(kept[0]['destination']))
        self.assertEqual(self.snapshot(), self.before)

    def test_overlapping_roots_keep_the_same_relative_layout(self):
        child = self.a / 'nested'
        self.write_zip(child / 'child.zip', b'child')
        self.config['roots'][1] = dict(id='b', path=str(child))
        self.config['inputs'] = [dict(root='a', file=str(child / 'child.zip')), dict(root='b', file=str(child / 'child.zip'))]
        before = self.snapshot()
        result = self.capture()
        mapped = {row['id']: Path(row['destination']) for row in result['roots']}
        self.assertEqual(mapped['b'], mapped['a'] / 'nested')
        self.assertEqual((result['files'], result['copy_files'], result['examined']), (1, 1, 2))
        self.assertEqual(Path(result['entries'][0]['destination']), mapped['b'] / 'child.zip')
        self.assertEqual(self.snapshot(), before)

    def test_root_alias_and_repeated_book_locators_do_not_duplicate_archive(self):
        self.config['roots'][1]['path'] = str(self.a / '.') + os.sep
        self.config['inputs'][1] = copy.deepcopy(self.config['inputs'][0])
        self.config['inputs'][1]['root'] = 'b'
        self.config['repeats'] = 10000
        result = self.capture()
        self.assertEqual((result['files'], result['examined']), (1, 20000))
        self.assertEqual(result['roots'][0]['destination'], result['roots'][1]['destination'])
        self.assertEqual(self.snapshot(), self.before)

    def test_flibrary_collects_whole_covers_and_images_archives(self):
        archive = self.make_flibrary(self.b)
        self.write_zip(self.b / 'covers/library.zip', b'cover bytes')
        self.write_zip(self.b / 'images/library.zip', b'image bytes')
        self.config['inputs'] = [dict(root='b', file=str(archive))] * 3
        before = self.snapshot()
        result = self.capture()
        self.assertEqual((result['files'], result['copy_files']), (3, 3))
        mapped = Path(result['roots'][1]['destination'])
        self.assertEqual({str(Path(row['destination']).relative_to(mapped)) for row in result['entries']},
                         {'library.7z', 'covers\\library.zip', 'images\\library.zip'})
        self.assertEqual(sum(row['external_images'] for row in result['entries']), 2)
        self.assertEqual(self.snapshot(), before)

    def test_new_flibrary_sidecar_invalidates_the_preview(self):
        archive = self.make_flibrary(self.b)
        appeared = self.b / 'covers/library.zip'
        self.config['inputs'] = [dict(root='b', file=str(archive))]
        self.config['create_source'] = str(appeared)
        before = self.snapshot()
        self.capture(False)
        after = self.snapshot()
        self.assertIn(str(appeared), after)
        after.pop(str(appeared))  # Created by the fixture after planning, not by the planner.
        self.assertEqual(after, before)

    def test_destination_occupied_after_preview_is_preserved(self):
        self.config['occupy_destination'] = True
        self.capture(False)
        after = self.snapshot()
        self.assertTrue(all(after[p] == value for p, value in self.before.items()))
        added = set(after) - set(self.before)
        self.assertEqual(len(added), 1)
        self.assertEqual(Path(added.pop()).read_text(encoding='utf-8-sig'), 'foreign fixture file after preview')

    def test_long_unicode_flibrary_paths_keep_sidecar_layout(self):
        directory = self.b.joinpath(*(['длинная папка с книгами'] * 10))
        archive = self.make_flibrary(directory)
        self.write_zip(directory / 'covers/library.zip', b'cover bytes')
        self.write_zip(directory / 'images/library.zip', b'image bytes')
        self.assertGreater(len(str(archive)), 300)
        self.config['inputs'] = [dict(root='b', file=str(archive))]
        before = self.snapshot()
        result = self.capture()
        self.assertEqual(result['files'], 3)
        mapped = Path(result['roots'][1]['destination'])
        for row in result['entries']:
            self.assertEqual(Path(row['destination']).relative_to(mapped), Path(row['source']).relative_to(self.b))
        self.assertEqual(self.snapshot(), before)

    def test_actual_root_junction_alias_keeps_one_physical_archive(self):
        directory = self.a.joinpath(*(['long folder for an alias'] * 10))
        self.write_zip(directory / 'child.zip', b'child')
        before = self.snapshot()
        with process_working_directory(directory) as alias:
            self.assertNotEqual(Path(alias), directory)
            self.config['roots'] = [dict(id='a', path=str(alias)), dict(id='b', path=str(directory))]
            self.config['inputs'] = [dict(root='a', file=str(Path(alias) / 'child.zip')),
                                     dict(root='b', file=str(directory / 'child.zip'))]
            result = self.capture()
            self.assertEqual(result['files'], 1)
            self.assertEqual(result['roots'][0]['destination'], result['roots'][1]['destination'])
        self.assertFalse(Path(alias).exists())
        self.assertEqual(self.snapshot(), before)

    def test_nested_junction_that_changes_relative_layout_is_rejected(self):
        directory = self.a.joinpath(*(['long folder for an alias'] * 10))
        self.write_zip(directory / 'child.zip', b'child')
        before = self.snapshot()
        with process_working_directory(directory) as alias:
            self.config['inputs'] = [dict(root='a', file=str(Path(alias) / 'child.zip'))]
            self.capture(False)
        self.assertFalse(Path(alias).exists())
        self.assertEqual(self.snapshot(), before)

    def test_file_outside_declared_source_is_rejected(self):
        self.config['inputs'][0]['file'] = str(self.b / 'same.zip')
        self.capture(False)
        self.assertEqual(self.snapshot(), self.before)

    def test_occupied_destination_is_not_reused_or_overwritten(self):
        first = self.capture()
        occupied = Path(first['entries'][0]['destination'])
        occupied.parent.mkdir(parents=True)
        occupied.write_bytes(b'foreign file must survive')
        before = self.snapshot()
        self.capture(False)
        self.assertEqual(self.snapshot(), before)

    def test_missing_source_is_rejected(self):
        self.config['inputs'][0]['file'] = str(self.a / 'missing.zip')
        self.capture(False)
        self.assertEqual(self.snapshot(), self.before)

    def test_cancelled_plan_cleans_only_its_scratch(self):
        foreign = self.root / 'scratch/foreign.txt'
        foreign.write_bytes(b'keep')
        self.config.update(repeats=2000, cancel_after=1500)
        self.capture(False)
        self.assertEqual(foreign.read_bytes(), b'keep')
        self.assertEqual(self.snapshot(), self.before)

    def test_changed_source_is_detected_before_transfer(self):
        changed = self.a / 'same.zip'
        self.config['mutate_source'] = str(changed)
        self.capture(False)
        after = self.snapshot()
        self.assertNotEqual(after.pop(str(changed)), self.before[str(changed)])
        self.assertEqual(after, {p: h for p, h in self.before.items() if p != str(changed)})

    def test_hardlinked_source_is_rejected_without_changing_either_name(self):
        alias = self.a / 'hardlink.zip'
        os.link(self.a / 'same.zip', alias)
        before = self.snapshot()
        self.capture(False)
        self.assertEqual(self.snapshot(), before)

    def test_unknown_and_duplicate_root_ids_are_rejected(self):
        self.config['inputs'][0]['root'] = 'unknown'
        self.capture(False)
        self.config['inputs'][0]['root'] = 'a'
        self.config['roots'][1]['id'] = 'a'
        self.capture(False)
        self.assertEqual(self.snapshot(), self.before)


if __name__ == '__main__':
    unittest.main()
