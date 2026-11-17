"""Physical SQLite spills in the real transfer review, including a fresh resume."""
import json

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_completion as completion


class TransferTemporaryRoutingTests(completion.TransferCompletionTests):
    def test_review_spills_stay_owned_through_move_completion_and_replay(self):
        self.config['probe_transfer_temp'] = True
        self.run_case()
        self.assert_published()
        result = self.finish()
        self.assert_completed(result)
        before = self.database_bytes()
        self.assertEqual(self.finish(), result)
        self.assertEqual(self.database_bytes(), before)
        rows = [json.loads(line.lstrip('\ufeff')) for line in
                (self.home/'temp-probe.jsonl').read_text(encoding='utf-8-sig').splitlines()]
        self.assertEqual(len(rows), 3)
        directory = self.anchor()['directory']
        self.assertTrue(all(row['directory'] == directory and row['bytes'] >= 1024*1024
                            and row['created'] > 0 and row['sum'] == 40504500 for row in rows))
        self.assertEqual(list(self.home.glob('sqlite-temp-*')), [])
        self.assertEqual(list(self.work.rglob('sqlite-temp-*')), [])
        with (fixture.STAGE/'temp-probes.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(dict(test=self.id(), rows=rows), ensure_ascii=False)+'\n')
