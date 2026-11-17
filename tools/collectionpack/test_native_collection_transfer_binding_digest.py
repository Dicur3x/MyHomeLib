"""Streamed receipt bytes match the old native JSON-array digest."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal
import test_native_collection_transfer_locations as locations


class TransferBindingDigestTests(journal.TransferJournalTests):
    def check_rows(self, rows):
        self.config.update(mode='binding-digest', binding_rows=rows)
        result = self.run_case()
        self.assertEqual(result['sha256'], result['legacy_sha256'])
        if 'legacy_json' in result:
            raw = result['legacy_json'].encode('utf-8')
            self.assertEqual(hashlib.sha256(raw).hexdigest(), result['sha256'])
            self.assertEqual(len(raw), result['bytes'])

    def test_empty_and_mixed_unicode_escaped_rows(self):
        self.check_rows([])
        self.check_rows([[], ['Книга 🙂 漢字', 'a\\b', 'quote"', '\n\r\t\u0000', 0, -1, 2**63-1],
                         ['reader-history:путь #%', None, True, 1.25]])

    def test_buffer_flush_and_oversized_individual_row(self):
        self.check_rows([[i, 'обычная строка '*30] for i in range(1000)])
        self.check_rows([['prefix'], ['длинная строка 🙂 '*100000], ['suffix']])


BASELINE = Path(os.environ['HL_TRANSFER_BINDING_BASELINE']) if os.environ.get('HL_TRANSFER_BINDING_BASELINE') else None


@unittest.skipUnless(BASELINE and BASELINE.is_file(), 'requires the saved pre-streaming native binary')
class TransferBindingReceiptTests(locations.TransferLocationTests):
    def receipts(self):
        rows = {}
        for path in (self.catalogue, self.personal):
            with fixture.connect(path) as db:
                rows[str(path)] = db.execute('SELECT * FROM HomeLibreTransferLocations ORDER BY Operation,GroupID').fetchall()
        return rows

    def check_legacy_replay(self, blank_ids=False, scoped_ids=False, delete_card=False):
        self.assertEqual(BASELINE.resolve().drive.casefold(), 'g:')
        if blank_ids or scoped_ids:
            for path in (self.catalogue, self.personal):
                with fixture.connect(path) as db:
                    db.execute('UPDATE Books SET LibID=? WHERE BookID=1',
                               ('' if blank_ids else 'flibusta:101',))
        shutil.copy2(BASELINE, self.binary)
        self.run_case()
        saved = self.receipts()
        if delete_card:
            with fixture.connect(self.personal) as db:
                db.execute('DELETE FROM Books WHERE BookID=1 AND DatabaseID=7')
        shutil.copy2(fixture.BINARY, self.binary)
        self.config['mode'] = 'resume'
        result = self.run_case()
        self.assertEqual(result['copy_streams'], 0)
        self.assertEqual(self.receipts(), saved)
        if delete_card:
            with fixture.connect(self.personal) as db:
                self.assertEqual(db.execute('SELECT count(*) FROM Books WHERE BookID=1 AND DatabaseID=7').fetchone()[0], 0)
        evidence = dict(test=self.id(), baseline_sha256=fixture.digest(BASELINE), candidate_sha256=fixture.digest(fixture.BINARY),
                        blank_ids=blank_ids, scoped_ids=scoped_ids, deleted_card=delete_card,
                        legacy_receipts=saved, unchanged=True)
        with (fixture.STAGE/'binding-receipt-versions.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(evidence, ensure_ascii=False)+'\n')

    def test_replay_old_receipts_with_location_based_reader_alias(self):
        self.check_legacy_replay(blank_ids=True)

    def test_missing_personal_card_keeps_old_prefix_digest_without_restoring_card(self):
        # A scoped identity has no optional reader-history suffix in the old
        # receipt. Exercise the missing-row prefix, not a different old policy.
        self.check_legacy_replay(scoped_ids=True, delete_card=True)

    def test_missing_numeric_card_preserves_existing_safe_refusal(self):
        # The old writer included an alias suffix only for a present card.
        # Deleting it after publication already prevents old -> old replay.
        # A streaming-only change must neither invent a receipt nor restore it.
        shutil.copy2(BASELINE, self.binary)
        self.run_case()
        saved = self.receipts()
        with fixture.connect(self.personal) as db:
            db.execute('DELETE FROM Books WHERE BookID=1 AND DatabaseID=7')
        self.config['mode'] = 'resume'
        old_error = self.run_case(expected='fail')
        self.assertEqual(self.receipts(), saved)
        shutil.copy2(fixture.BINARY, self.binary)
        new_error = self.run_case(expected='fail')
        self.assertEqual(new_error, old_error)
        self.assertIn('EReadError:', new_error)
        self.assertEqual(self.receipts(), saved)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM Books WHERE BookID=1 AND DatabaseID=7').fetchone()[0], 0)
        with (fixture.STAGE/'binding-receipt-versions.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(dict(test=self.id(), baseline_sha256=fixture.digest(BASELINE),
                candidate_sha256=fixture.digest(fixture.BINARY), old_error=old_error, new_error=new_error,
                legacy_receipts=saved, unchanged=True), ensure_ascii=False)+'\n')
