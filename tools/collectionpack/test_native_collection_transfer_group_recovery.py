"""Sealed group proofs and target-only recovery across original removal."""
import json
from pathlib import Path

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_locations as location_fixture
import test_native_collection_transfer_journal as journal_fixture
import test_native_collection_transfer_resources as resource_fixture


class TransferGroupRecoveryTests(location_fixture.TransferLocationTests):
    def setUp(self):
        super().setUp();self.config.update(seal_groups=True)

    def remove_originals(self,subset=False):
        rows=self.read_review('select Source,KeepInPlace from Files order by ID')
        for source,keep in rows[:1] if subset else rows:
            path=Path(source)
            self.assertTrue(path.resolve().is_relative_to(self.home.resolve()))
            if not keep:path.unlink()

    def recover(self,**options):
        self.config.update(mode='resume',recover_groups=True,seal_groups=False,apply_locations=False,crash='')
        self.config.update(options);return self.run_case()

    def proof_bytes(self):
        return {p.name:p.read_bytes() for p in self.journal().glob('prepared-group-*.json')}

    def test_all_originals_removed_group_recovers_without_source_or_state_writes(self):
        self.run_case();self.remove_originals();before=self.proof_bytes()
        state=fixture.digest(self.journal()/'state.sqlite')
        self.assertEqual(self.recover()['copy_streams'],0)
        self.assertEqual(self.proof_bytes(),before);self.assertEqual(fixture.digest(self.journal()/'state.sqlite'),state)

    def test_removed_and_retained_originals_recover_together(self):
        self.run_case();self.remove_originals(subset=True)
        self.assertEqual(self.recover()['copy_streams'],0)

    def test_original_directories_can_also_be_absent(self):
        self.run_case();self.remove_originals()
        for root in (self.a,self.b):
            for path in sorted(root.rglob('*'),reverse=True):
                self.assertTrue(path.resolve().is_relative_to(self.home.resolve()))
                path.rmdir()
            root.rmdir()
        self.assertEqual(self.recover()['copy_streams'],0)

    def test_files_already_in_destination_recover_without_copying(self):
        resource_fixture.in_place_sources(self)
        self.assertEqual(self.run_case()['copy_streams'],0)
        before=self.payloads()
        self.assertEqual(self.recover()['copy_streams'],0)
        self.assertEqual(self.payloads(),before)

    def test_destination_only_recovery_cannot_reseal_a_group(self):
        self.run_case();self.remove_originals()
        self.config.update(mode='resume',recover_groups=True,seal_groups=True,apply_locations=False)
        self.assertIn('Нет удерживаемой проверки потоков файла',self.run_case('fail'))

    def test_native_shared_picture_mapping_recovers_without_original_resources(self):
        journal_fixture.TransferJournalTests.connected_images(self)
        self.run_case();self.remove_originals();self.assertEqual(self.recover()['copy_streams'],0)

    def test_source_name_reused_by_a_foreign_file_is_preserved(self):
        self.run_case();self.remove_originals();source=Path(self.read_review('select Source from Files order by ID')[0][0])
        source.write_bytes(b'foreign file after source removal')
        self.recover();self.assertEqual(source.read_bytes(),b'foreign file after source removal')

    def test_wrong_independent_group_hash_is_rejected(self):
        self.run_case();self.remove_originals();self.config.update(mode='resume',recover_groups=True,seal_groups=False,apply_locations=False,override_group_proof='0'*64)
        self.assertIn('независимым подтверждением',self.run_case('fail'))

    def test_changed_proof_file_is_not_accepted(self):
        self.run_case();self.remove_originals();proof=next(self.journal().glob('prepared-group-*.json'))
        data=json.loads(proof.read_text());data['operation']='another-operation'
        proof.write_text(json.dumps(data),encoding='utf-8')
        self.config.update(mode='resume',recover_groups=True,seal_groups=False,apply_locations=False)
        self.assertIn('контрольной суммой',self.run_case('fail'))

    def test_mutable_child_link_is_not_used_instead_of_sealed_link(self):
        self.run_case();self.remove_originals()
        journal_fixture.TransferJournalTests.state_edit(self,"update FileState set Child='transfer-copy-{00000000-0000-0000-0000-000000000000}'")
        self.assertEqual(self.recover()['copy_streams'],0)

    def test_foreign_existing_proof_is_preserved(self):
        self.config.update(apply_locations=False,prepare=False,seal_groups=False);self.run_case()
        path=self.journal()/'prepared-group-1.json';path.write_bytes(b'foreign proof file')
        self.config.update(mode='resume',prepare=True,seal_groups=True)
        self.run_case('fail');self.assertEqual(path.read_bytes(),b'foreign proof file')

    def test_seal_commit_boundaries_are_idempotent(self):
        for i,point in enumerate(('group-proof-written','group-proof-published','group-proof-before-commit','group-proof-after-commit')):
            with self.subTest(point=point):
                if i:self.tearDown();self.setUp()
                self.config['crash']=point;self.run_case(97)
                self.config.update(mode='resume',crash='')
                self.assertEqual(self.run_case()['copy_streams'],1)

    def test_second_crash_during_group_recovery_keeps_proof_and_outputs(self):
        self.run_case();self.remove_originals();before=self.proof_bytes()
        self.config.update(mode='resume',recover_groups=True,seal_groups=False,apply_locations=False,crash='group-destination-verified')
        self.run_case(97);self.run_case(97)
        self.assertEqual(self.recover()['copy_streams'],0);self.assertEqual(self.proof_bytes(),before)


if __name__=='__main__':
    import unittest
    unittest.main(verbosity=2)
