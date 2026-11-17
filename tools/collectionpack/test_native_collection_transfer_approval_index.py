"""Immutable approval keys are indexed once; live references remain fresh."""
import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_removal as removal


class TransferApprovalIndexTests(removal.TransferRemovalTests):
    def test_new_review_uses_frozen_index_for_publication_and_every_removal_scan(self):
        result = self.run_case()
        self.assertGreater(result['indexed_approval_snapshots'], 0)
        self.assertEqual(result['copied_approval_snapshots'], 0)
        self.assertEqual(result['readonly_approval_probes'], result['indexed_approval_snapshots'])
        self.assertEqual(self.read_review("SELECT count(*) FROM sqlite_master WHERE name='TransferApprovedLookup'"), [(1,)])
        result = self.remove()
        self.assertEqual((result['removed_sources'], result['copy_streams']), (2, 0))
        self.assertEqual(result['publication_scans'], 4, 'live reference scans were weakened')
        self.assertEqual(result['indexed_approval_snapshots'], 4)
        self.assertEqual(result['copied_approval_snapshots'], 0)

    def test_old_review_without_index_keeps_the_previous_disk_projection(self):
        self.config['legacy_approval_review'] = True
        result = self.run_case()
        self.assertEqual(result['indexed_approval_snapshots'], 0)
        self.assertGreater(result['copied_approval_snapshots'], 0)
        result = self.remove()
        self.assertEqual((result['removed_sources'], result['copy_streams']), (2, 0))
        self.assertEqual((result['publication_scans'], result['copied_approval_snapshots']), (4, 4))

    def test_disappeared_reviewed_nonpersonal_row_prevents_source_removal(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            db.execute('DELETE FROM Books WHERE BookID=2')
        before = self.payloads()
        self.assertIn('Нужен новый план', self.remove('fail'))
        self.assertEqual(self.payloads(), before)
        self.assertFalse(self.intents())

    def test_frozen_attachment_escapes_unicode_percent_and_hash_in_work_path(self):
        work = self.work.with_name('план #% проба')
        self.work.rename(work)
        self.work = work
        self.config['work'] = str(work)
        result = self.run_case()
        self.assertGreater(result['readonly_approval_probes'], 0)
        self.assertEqual(result['copied_approval_snapshots'], 0)
        self.assertEqual(self.remove()['removed_sources'], 2)

    def test_long_work_path_retains_the_legacy_projection(self):
        work = self.work.with_name('long-'+'x'*140)
        self.work.rename(work)
        self.work = work
        self.config['work'] = str(work)
        result = self.run_case()
        self.assertEqual(result['indexed_approval_snapshots'], 0)
        self.assertGreater(result['copied_approval_snapshots'], 0)
        self.assertEqual(self.remove()['removed_sources'], 2)

    def test_cancel_inside_sql_verification_preserves_sources_and_book_rows(self):
        with fixture.connect(self.catalogue) as db:
            db.executemany('INSERT INTO Books(BookID,LibID,Title,Folder,FileName,Ext,UpdateDate,InsideNo) VALUES(?,?,?,?,?,?,?,?)',
                           ((1000+i, str(1000+i), 'SQL cancellation row', 'same.zip', '101', '.fb2', '', 0)
                            for i in range(3000)))
        before = self.payloads()
        self.config['cancel_approval_sql'] = True
        output = self.run_case('fail')
        self.assertIn('TRACE cancelling approval SQL', output)
        self.assertIn('Проверка новых ссылок остановлена', output)
        self.assertEqual(self.payloads(), before)
        self.assertFalse(self.intents())
