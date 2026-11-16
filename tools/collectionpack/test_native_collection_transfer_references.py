"""Registered catalogue/personal reference capture; never mutates real libraries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal_fixture


@unittest.skipUnless(os.name == 'nt' and all(p and p.is_file() for p in
                     (fixture.BINARY, fixture.SQLITE, fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native transfer journal, SQLite, 7-Zip and owned stage')
class TransferReferenceTests(unittest.TestCase):
    attempts = crashes = 0
    setUp = journal_fixture.TransferJournalTests.setUp
    tearDown = journal_fixture.TransferJournalTests.tearDown
    write_zip = staticmethod(fixture.TransferCatalogueTests.write_zip)
    make_legacy = journal_fixture.TransferJournalTests.make_legacy
    command = journal_fixture.TransferJournalTests.command
    run_case = journal_fixture.TransferJournalTests.run_case
    anchor = journal_fixture.TransferJournalTests.anchor
    journal = journal_fixture.TransferJournalTests.journal
    resume = journal_fixture.TransferJournalTests.resume
    read_review = journal_fixture.TransferJournalTests.read_review
    connected_images = journal_fixture.TransferJournalTests.connected_images

    def snapshot(self):
        result = fixture.TransferCatalogueTests.snapshot(self)
        other = getattr(self,'other',None)
        if other and other.is_file() and not self.config.get('change_reference_catalogue'):
            result[str(other)] = fixture.digest(other)
        outside = self.home/'third'
        if outside.is_dir():
            result.update({str(p):fixture.digest(p) for p in outside.rglob('*') if p.is_file()})
        return result

    def foreign(self, root=None, shared=False):
        self.other = self.catalogue if shared else self.home/'other.hlc2'
        if not shared:
            shutil.copy2(self.catalogue, self.other)
        with fixture.connect(self.personal) as db:
            db.execute('update Bases set DBFileName=?,RootFolder=? where DatabaseID=8',
                       (str(self.other), str(root or self.a)))
        return self.other

    def junction(self, path, target):
        # Fixed arguments, owned absolute fixture paths only. This creates a
        # directory link; rmdir later removes the link, never its target.
        path, target = path.resolve(), target.resolve()
        self.assertTrue(path.is_relative_to(self.home.resolve()))
        self.assertTrue(target.is_relative_to(self.home.resolve()))
        completed = subprocess.run(['cmd.exe','/d','/c','mklink','/J',str(path),str(target)],
            capture_output=True, timeout=10, creationflags=subprocess.CREATE_NO_WINDOW)
        self.assertEqual(completed.returncode, 0, completed.stdout+completed.stderr)
        self.assertTrue(path.is_junction())
        return path

    def test_missing_registered_database_retains_originals(self):
        data = self.run_case()
        self.assertGreater(data['reference_issues'], 0)
        self.assertEqual(len(data['retained_files']), data['files'])
        self.assertEqual(self.read_review('select State from ReferenceRegistrations where RegistrationID=8'), [('unknown',)])
        # Personal physical locators still count when that catalogue is missing.
        self.assertEqual(self.read_review('select count(*) from RegisteredReferences where RegistrationID=8 and Kind=1'), [(1,)])

    def test_separate_catalogue_and_all_personal_locators_are_captured(self):
        self.foreign()
        data = self.run_case()
        self.assertEqual((data['reference_issues'],data['reference_conflicts'],data['retained_files']), (0,0,[]))
        self.assertEqual(self.read_review('select Kind,count(*) from RegisteredReferences where RegistrationID=8 group by Kind'),
                         [(0,2),(1,1),(2,1)])
        self.assertEqual(self.read_review("select SourceKey from RegisteredReferences where RegistrationID=8 and Kind=2"),
                         [('b:file:stable-copy',)])
        self.assertEqual(self.read_review('select SourcesJSON from ReferenceRegistrations where RegistrationID=8'), [(self.sources,)])

    def test_shared_catalogue_different_roots_detects_row_conflicts(self):
        self.foreign(self.b, shared=True)
        data = self.run_case()
        self.assertEqual(data['reference_conflicts'], 2)
        self.assertEqual(len(data['retained_files']), 2)
        self.assertEqual(self.read_review('select count(*) from ReferenceConflicts where Kind=2'), [(0,)])
        self.assertEqual(self.read_review('select count(distinct PhysicalKey) from ReferenceVariants where Kind=0 and BookID=1'), [(2,)])

    def test_shared_catalogue_same_root_does_not_invent_conflicts(self):
        self.foreign(self.a, shared=True)
        data = self.run_case()
        self.assertEqual((data['reference_conflicts'],data['reference_issues'],data['retained_files']), (0,0,[]))

    def test_matching_names_and_bytes_in_another_root_are_not_references(self):
        outside = self.home/'third'; outside.mkdir()
        shutil.copy2(self.a/'same.zip', outside/'same.zip')
        self.foreign(outside)
        with fixture.connect(self.other) as db:
            db.execute('update CatalogBookCopies set Root=?', (str(outside),))
        data = self.run_case()
        self.assertEqual(data['reference_issues'], 0)
        self.assertEqual(self.read_review('select count(*) from RegisteredReferences where RegistrationID=8'), [(0,)])

    def test_bad_foreign_database_records_uncertainty_but_allows_copy_preparation(self):
        self.foreign()
        self.other.write_bytes(b'not a SQLite catalogue')
        self.config['prepare'] = True
        data = self.run_case()
        self.assertEqual(data['prepared_files'], 2)
        self.assertGreater(data['reference_issues'], 0)
        self.assertEqual(len(data['retained_files']), 2)

    def test_invalid_foreign_sources_are_reported(self):
        self.foreign()
        with fixture.connect(self.other) as db:
            db.execute('update Settings set SettingValue=? where SettingID=?', ('{bad',fixture.SOURCE_PROPERTY))
        data = self.run_case()
        self.assertGreater(data['reference_issues'], 0)
        self.assertEqual(len(data['retained_files']), 2)

    def test_foreign_catalogue_change_during_snapshot_rejects_review(self):
        self.foreign()
        with fixture.connect(self.other) as db:
            schema = list(db.execute('select type,name,sql from sqlite_master order by type,name'))
            expected = {name:list(db.execute('select * from "'+name+'" order by rowid'))
                        for name, in db.execute("select name from sqlite_master where type='table'")}
            columns = [row[1] for row in db.execute('pragma table_info(Books)')]
        for index,row in enumerate(expected['Books']):
            if row[columns.index('BookID')]==1:
                changed = list(row); changed[columns.index('Folder')] = 'changed-after-reference-scan.zip'
                expected['Books'][index] = tuple(changed)
        self.config['change_reference_catalogue'] = str(self.other)
        self.assertIn('каталог изменился', self.run_case('fail'))
        self.assertFalse(self.control.exists())
        self.assertFalse(list(self.destination.iterdir()))
        with fixture.connect(self.other) as db:
            self.assertEqual(list(db.execute('select type,name,sql from sqlite_master order by type,name')),schema)
            actual = {name:list(db.execute('select * from "'+name+'" order by rowid')) for name in expected}
            self.assertEqual(actual,expected)

    def test_cancellation_is_not_swallowed_as_an_unknown_reference(self):
        self.foreign()
        self.config['cancel_reference_scan'] = True
        self.assertIn('остановлена', self.run_case('fail'))
        self.assertFalse(self.control.exists())
        self.assertFalse(list(self.destination.iterdir()))

    def test_whole_root_junction_preserves_layout(self):
        alias = self.junction(self.home/'root-alias',self.a)
        try:
            self.foreign(alias,shared=True)
            data = self.run_case()
            self.assertEqual((data['reference_conflicts'],data['reference_issues'],data['retained_files']), (0,0,[]))
        finally:
            alias.rmdir()

    def test_internal_junction_keeps_original_for_unproven_layout(self):
        outside = self.home/'third'; outside.mkdir()
        alias = self.junction(outside/'internal',self.a)
        try:
            self.foreign(outside)
            with fixture.connect(self.other) as db:
                db.execute("update Books set Folder='internal/same.zip' where BookID in (1,2)")
            data = self.run_case()
            self.assertEqual(data['reference_issues'], 0)
            self.assertEqual(len(data['retained_files']), 1)
            self.assertEqual(self.read_review("select count(*) from RegisteredReferences where RegistrationID=8 and RetainReason<>''"), [(2,)])
        finally:
            alias.rmdir()

    def test_outside_archive_retains_its_shared_external_images(self):
        self.connected_images()
        outside = self.home/'third'; outside.mkdir()
        shutil.copy2(self.a/'legacy.7z',outside/'legacy.7z')
        alias = self.junction(outside/'images',self.a/'images')
        try:
            self.foreign(outside)
            with fixture.connect(self.other) as db:
                db.execute("delete from CatalogBookCopies")
                db.execute("update Books set Folder='legacy.7z' where BookID in (1,2)")
            data = self.run_case()
            self.assertEqual(data['reference_issues'], 0)
            self.assertEqual(len(data['retained_files']), 1)
            self.assertEqual(self.read_review('select count(*) from RegisteredReferences where RegistrationID=8 and Resource=1'), [(1,)])
            self.assertEqual(self.read_review("select f.Source from Files f join RegisteredReferences r on r.FileID=f.ID where r.Resource=1"),
                             [(str(self.a/'images/legacy.zip'),)])
        finally:
            alias.rmdir()

    def test_extensionless_orphan_copy_is_still_a_physical_reference(self):
        raw = self.a/'image.webp'; raw.write_bytes(b'opaque physical book')
        with fixture.connect(self.catalogue) as db:
            db.execute("update Books set Folder='',FileName='image.webp',Ext='' where BookID=2")
        self.foreign()
        with fixture.connect(self.other) as db:
            fixture.insert(db,'CatalogBookCopies',dict(SourceKey='orphan-stable',BookID=999,Root=str(self.a),Folder='',
                FileName='image.webp',Ext='',InsideNo=0,BookSize=raw.stat().st_size,LibID='orphan-999'))
        self.run_case()
        self.assertEqual(self.read_review("select SourceKey,Canonical from RegisteredReferences where RegistrationID=8 and BookID=999"),
                         [('orphan-stable',str(raw))])


if __name__ == '__main__':
    unittest.main(verbosity=2)
