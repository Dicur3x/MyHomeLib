"""Whole-operation acknowledgement follows locked roots/cache/group verification."""
import collections
import json

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_cache_metadata as metadata
import test_native_collection_transfer_locations as locations

RECEIPT = 'HomeLibreTransferCompletion'
locations.MARKERS.add(RECEIPT)


class TransferCompletionTests(metadata.TransferCacheMetadataTests):
    def finish(self, expected=0, **options):
        self.config.update(mode='resume', complete_only=True, register_operation=False,
                           crash='', application_busy=False, busy_before_completion_commit=False,
                           cancel_finalization_stage='')
        self.config.update(options)
        return self.run_case(expected)

    def receipt(self):
        with fixture.connect(self.personal) as db:
            if not db.execute('SELECT count(*) FROM sqlite_master WHERE name=?', (RECEIPT,)).fetchone()[0]:
                return []
            return db.execute('SELECT * FROM ' + RECEIPT).fetchall()

    def database_bytes(self):
        return {str(p): fixture.digest(p) for p in self.home.rglob('*')
                if p.is_file() and p.suffix.casefold() in ('.sqlite', '.hlc2')}

    def assert_completed(self, result):
        states = collections.Counter(row['State'] for row in self.intents().values())
        self.assertFalse(set(states) - {'removed', 'missing', 'retained'})
        self.assertEqual(result['files'], len(self.intents()))
        self.assertEqual(result['groups'], len(self.read_review('SELECT ID FROM Groups')))
        self.assertEqual(result['bytes'], self.read_review('SELECT sum(Bytes) FROM Files')[0][0])
        self.assertEqual((result['removed'], result['missing'], result['retained']),
                         (states['removed'], states['missing'], states['retained']))
        self.assertEqual(result['pending_operations'], 0)
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1], 'completed')
        rows = self.receipt()
        self.assertEqual(len(rows), 1)
        saved = json.loads(rows[0][3])
        self.assertEqual(saved['completed_at'], result['completed_at'])

    def assert_refused_unchanged(self, text, **options):
        before = self.database_bytes()
        self.assertIn(text, self.finish('fail', **options))
        self.assertEqual(self.database_bytes(), before)
        self.assertFalse(self.receipt())
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1], 'pending')

    def test_complete_saves_cumulative_totals_and_replay_is_read_only(self):
        self.run_case(); self.assert_published()
        result = self.finish(); self.assert_completed(result)
        before = self.database_bytes()
        self.assertEqual(self.finish(), result)
        self.assertEqual(self.database_bytes(), before)

    def test_busy_application_keeps_operation_pending(self):
        self.run_case()
        self.assert_refused_unchanged('Открытая коллекция ещё не обновлена', application_busy=True)
        self.assert_completed(self.finish())

    def test_application_becoming_busy_before_commit_rolls_back_summary_and_state(self):
        self.run_case()
        self.assert_refused_unchanged('Открытая коллекция ещё не обновлена', busy_before_completion_commit=True)
        self.assert_completed(self.finish())

    def test_process_exit_before_commit_keeps_pending_and_recovers_same_totals(self):
        self.run_case()
        self.finish(97, crash='completion-before-personal-commit')
        self.assertFalse(self.receipt())
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1], 'pending')
        self.assert_completed(self.finish())

    def test_process_exit_after_commit_replays_completed_receipt_without_writes(self):
        self.run_case()
        self.finish(97, crash='completion-after-personal-commit')
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1], 'completed')
        self.assertEqual(len(self.receipt()), 1)
        before = self.database_bytes()
        self.assert_completed(self.finish())
        self.assertEqual(self.database_bytes(), before)

    def test_roots_without_source_publication_cannot_be_acknowledged(self):
        self.config['publish_cache_settings'] = False
        self.run_case()
        self.assert_refused_unchanged('завершить публикацию источников')
        self.config.update(complete_only=False, publish_cache_settings=True)
        self.continue_metadata()
        self.assert_completed(self.finish())

    def test_pending_original_blocks_completion_even_with_final_roots(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("UPDATE HomeLibreTransferRemovalIntent SET State='pending' WHERE FileID=(SELECT min(FileID) FROM HomeLibreTransferRemovalIntent)")
        self.assert_refused_unchanged('Освобождение исходных файлов ещё не завершено')

    def test_terminal_count_does_not_replace_exact_file_binding(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("UPDATE HomeLibreTransferRemovalIntent SET SourceIdentity=? WHERE FileID=(SELECT min(FileID) FROM HomeLibreTransferRemovalIntent)", ('0' * 59,))
        self.assert_refused_unchanged('Освобождение исходника не совпало')

    def test_lost_completed_receipt_is_refused_without_recreation(self):
        self.run_case(); self.assert_completed(self.finish())
        with fixture.connect(self.personal) as db:
            db.execute('DELETE FROM ' + RECEIPT)
        before = self.database_bytes()
        self.assertIn('Итог переноса изменён или не подтверждён', self.finish('fail'))
        self.assertEqual(self.database_bytes(), before)
        self.assertFalse(self.receipt())

    def test_unfinished_cache_publication_intent_cannot_be_acknowledged(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute("UPDATE HomeLibreTransferCachePublication SET State='intent'")
        self.assert_refused_unchanged('завершить публикацию источников')
