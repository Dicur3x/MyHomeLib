"""Personal-card deletion does not change a new frozen locator receipt."""
import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_receipts as receipts


FORMATS = 'HomeLibreTransferLocationFormats'


class TransferPersonalReceiptTests(receipts.TransferReceiptTests):
    def format_rows(self):
        result = {}
        for path in (self.catalogue, self.personal):
            with fixture.connect(path) as db:
                rows = db.execute('SELECT f.GroupID,f.ReviewSHA256,f.BindingSHA256,f.Format,'
                    'r.ReviewSHA256,r.BindingSHA256 FROM '+FORMATS+' f JOIN HomeLibreTransferLocations r '
                    'ON r.Operation=f.Operation AND r.GroupID=f.GroupID ORDER BY f.GroupID').fetchall()
                self.assertTrue(rows)
                for row in rows:
                    self.assertEqual(row[3], 2)
                    self.assertEqual(row[1:3], row[4:6])
                result[str(path)] = rows
        return result

    def aliases(self):
        with fixture.connect(self.personal) as db:
            return db.execute('SELECT * FROM HomeLibreReaderHistoryAliases ORDER BY CollectionID,BookID,LibID,LocationSHA256,CurrentName').fetchall()

    def delete_card(self):
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('DELETE FROM Books WHERE DatabaseID=7 AND BookID=1').rowcount, 1)

    def assert_card_absent(self):
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM Books WHERE DatabaseID=7 AND BookID=1').fetchone()[0], 0)

    def check_deleted_card(self, blank_ids=False):
        if blank_ids:
            for path in (self.catalogue, self.personal):
                with fixture.connect(path) as db:
                    db.execute("UPDATE Books SET LibID='' WHERE BookID=1")
        self.run_case()
        formats = self.format_rows()
        aliases = self.aliases()
        self.remove_originals()
        self.delete_card()
        before = self.byte_snapshot()
        self.assertEqual(self.verify()['copy_streams'], 0)
        self.assertEqual(self.byte_snapshot(), before)
        self.assertEqual(self.format_rows(), formats)
        self.assertEqual(self.aliases(), aliases)
        self.assert_card_absent()

    def test_deleted_numeric_card_keeps_receipts_and_history_without_originals(self):
        self.check_deleted_card()

    def test_deleted_blank_id_card_keeps_receipts_and_history_without_originals(self):
        self.check_deleted_card(blank_ids=True)

    def test_deleted_card_between_review_and_first_publication_stays_absent(self):
        self.config.update(prepare=False, apply_locations=False, register_operation=False,
                           register_groups=False, verify_published=False)
        self.run_case()
        self.delete_card()
        self.config.update(mode='resume', prepare=True, apply_locations=True,
                           register_operation=True, register_groups=True, verify_published=True)
        self.run_case()
        self.format_rows()
        self.assert_card_absent()
        self.remove_originals()
        before = self.byte_snapshot()
        self.verify()
        self.assertEqual(self.byte_snapshot(), before)

    def test_partial_catalogue_commit_then_deleted_card_recovers_personal_receipt(self):
        self.config['crash'] = 'locations-after-catalogue-commit'
        self.run_case(97)
        self.delete_card()
        # The explicit user edit happened after the crash, outside publication.
        self.pending = None
        self.resume()
        self.format_rows()
        self.assert_card_absent()
        self.remove_originals()
        self.verify()

    def test_unknown_format_is_refused_without_repair(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('UPDATE '+FORMATS+' SET Format=99 WHERE GroupID=1').rowcount, 1)
        before = self.byte_snapshot()
        self.assertIn('Неизвестный формат', self.verify('fail'))
        self.assertEqual(self.byte_snapshot(), before)

    def test_changed_format_binding_is_refused_without_repair(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            db.execute('UPDATE '+FORMATS+' SET BindingSHA256=? WHERE GroupID=1', ('0'*64,))
        before = self.byte_snapshot()
        self.assertIn('Квитанция расположений', self.verify('fail'))
        self.assertEqual(self.byte_snapshot(), before)

    def test_lost_format_uses_compatible_legacy_digest_without_recreating_metadata(self):
        self.run_case()
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('DELETE FROM '+FORMATS+' WHERE GroupID=1').rowcount, 1)
        before = self.byte_snapshot()
        self.verify()
        self.assertEqual(self.byte_snapshot(), before)

    def test_deleted_card_does_not_hide_a_lost_history_binding(self):
        self.run_case()
        self.remove_originals()
        self.delete_card()
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute("DELETE FROM HomeLibreReaderHistoryAliases WHERE CollectionID=7 AND BookID=1 AND LibID='1'").rowcount, 1)
        before = self.byte_snapshot()
        self.assertIn('Квитанция расположений', self.verify('fail'))
        self.assertEqual(self.byte_snapshot(), before)
        self.assert_card_absent()
