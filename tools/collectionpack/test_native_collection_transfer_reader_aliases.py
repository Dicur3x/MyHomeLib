"""Reader history aliases follow exact reviewed locators, including recovery."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cache_metadata as metadata

ALIASES = 'HomeLibreReaderHistoryAliases'


class TransferReaderAliasTests(metadata.TransferCacheMetadataTests):
    def setUp(self):
        super().setUp()
        self.config['read_reader_names'] = True

    def reader_names(self):
        saved = dict(self.config)
        before = {p: fixture.digest(p) for p in (self.catalogue, self.personal)}
        self.config['mode'] = 'reader-names'
        try:
            process = subprocess.run(self.command(), cwd=self.home, capture_output=True, timeout=90,
                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.BELOW_NORMAL_PRIORITY_CLASS,
                env={**os.environ, 'TEMP': str(self.home), 'TMP': str(self.home)})
            output = (process.stdout + process.stderr).decode('utf-8', errors='replace')
            entry = dict(test=self.id(), request=dict(self.config), expected=0,
                         returncode=process.returncode, output=output)
            if self.result.exists():
                entry['result'] = json.loads(self.result.read_text(encoding='utf-8-sig'))
            with (fixture.STAGE / 'invocations.jsonl').open('a', encoding='utf-8') as log:
                log.write(json.dumps(entry, ensure_ascii=False) + '\n')
            self.assertEqual(process.returncode, 0, output)
            self.assertEqual({p: fixture.digest(p) for p in before}, before, 'Reader lookup wrote a database')
            return {row['book']: row for row in entry['result']['reader_names']}
        finally:
            self.config = saved

    def alias_rows(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('SELECT count(*) FROM sqlite_master WHERE name=?', (ALIASES,)).fetchone()[0]:
                return []
            db.row_factory = lambda cursor, row: dict(zip((c[0] for c in cursor.description), row))
            return db.execute('SELECT * FROM ' + ALIASES + ' WHERE CollectionID=7 ORDER BY BookID').fetchall()

    def assert_names(self, before, result):
        after = {row['book']: row for row in result['reader_names']}
        self.assertEqual(set(before), set(after))
        self.assertEqual({i: row['history'] for i, row in before.items()},
                         {i: row['history'] for i, row in after.items()})
        return after

    def test_placeholder_and_file_derived_keys_preserve_reader_history(self):
        with fixture.connect(self.catalogue) as db:
            for book, libid in ((1, ''), (2, '0'), (3, 'file:opaque')):
                db.execute('UPDATE Books SET LibID=? WHERE BookID=?', (libid, book))
        with fixture.connect(self.personal) as db:
            db.execute("UPDATE Books SET LibID='' WHERE DatabaseID=7 AND BookID=1")
        before = self.reader_names()
        for book in (1, 2):
            with fixture.connect(self.catalogue) as db:
                folder, member, extension = db.execute('SELECT Folder,FileName,Ext FROM Books WHERE BookID=?', (book,)).fetchone()
            expected = 'homelib-7-' + hashlib.sha256((folder + '\1' + member + extension).lower().encode()).hexdigest()[:32] + extension
            self.assertEqual(before[book]['history'], expected)
        result = self.run_case()
        after = self.assert_names(before, result)
        self.assertTrue(all(row['aliased'] for row in after.values()))
        self.assertNotEqual(before[1]['base'], after[1]['base'])
        self.assertEqual(before[3]['base'], after[3]['base'], 'Opaque IDs already have a stable history name')
        self.assert_published()

    def test_unscoped_numeric_history_covers_missing_book_without_creating_payload(self):
        before = self.reader_names()
        self.assertFalse((self.a / 'notdownloaded.zip').exists())
        result = self.run_case()
        after = self.assert_names(before, result)
        self.assertTrue(after[3]['aliased'])
        self.assertNotEqual(before[3]['base'], after[3]['base'])
        self.assert_published()

    def test_catalogue_commit_crash_rolls_back_personal_aliases_then_recovers(self):
        before = self.reader_names()
        self.config['crash'] = 'locations-after-catalogue-commit'
        self.run_case(97)
        self.assertFalse(self.alias_rows(), 'Uncommitted personal aliases survived the process exit')
        result = self.continue_metadata()
        self.assert_names(before, result)
        self.assert_published()

    def test_partial_root_commit_recovers_missing_book_alias_from_independent_intent(self):
        before = self.reader_names()
        self.config['crash'] = 'finalization-after-catalogue-commit'
        self.run_case(97)
        self.assertNotIn(3, [row['BookID'] for row in self.alias_rows()])
        result = self.continue_metadata()
        self.assert_names(before, result)
        self.assert_published()

    def test_lost_committed_alias_is_not_recreated_after_original_removal(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute('DELETE FROM ' + ALIASES + ' WHERE CollectionID=7 AND BookID=1')
        self.assertIn('Потеряна подтверждённая связь', self.continue_metadata('fail'))
        self.assertNotIn(1, [row['BookID'] for row in self.alias_rows()])

    def test_rehashed_other_history_is_refused_without_overwriting_it(self):
        self.run_case()
        before = self.alias_rows()
        row = next(row for row in before if row['BookID'] == 1 and row['LibID'] == '101')
        name = 'homelib-7-' + hashlib.sha256(b'other book').hexdigest()[:32] + '.fb2'
        value = ['HomeLibre reader history alias v1', 7, 1, row['LibID'], row['LocationSHA256'], row['CurrentName'], name]
        original = [*value[:-1], row['OriginalName']]
        self.assertEqual(hashlib.sha256(json.dumps(original, ensure_ascii=False,
            separators=(',', ':')).encode()).hexdigest(), row['MappingSHA256'])
        digest = hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        with fixture.connect(self.personal) as db:
            changed = db.execute('UPDATE ' + ALIASES + ' SET OriginalName=?,MappingSHA256=? '
                'WHERE CollectionID=? AND BookID=? AND LibID=? AND LocationSHA256=? AND CurrentName=?',
                (name, digest, row['CollectionID'], row['BookID'], row['LibID'], row['LocationSHA256'], row['CurrentName']))
            self.assertEqual(changed.rowcount, 1)
        self.assertIn('Конфликт сохранённых историй', self.continue_metadata('fail'))
        expected = [{**item, 'OriginalName': name, 'MappingSHA256': digest} if item == row else item for item in before]
        self.assertEqual(self.alias_rows(), expected, 'Recovery overwrote the foreign edit or another copy binding')

    def test_reader_lookup_does_not_borrow_alias_after_identity_or_location_change(self):
        before = self.reader_names()
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            db.execute("UPDATE Books SET LibID='999' WHERE BookID=1")
        names = self.reader_names()
        self.assertFalse(names[1]['aliased'])
        self.assertEqual(names[1]['history'], names[1]['base'])
        self.assertNotEqual(names[1]['history'], before[1]['history'])
        with fixture.connect(self.catalogue) as db:
            db.execute('UPDATE Books SET LibID=?,Folder=? WHERE BookID=1', ('101', str(self.home / 'different.zip')))
        self.assertFalse(self.reader_names()[1]['aliased'])
