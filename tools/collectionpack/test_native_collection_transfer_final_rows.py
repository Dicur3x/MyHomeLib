"""Actual final missing-locator/copy-root writes, not full move finalization."""
import copy
import json
import os
from pathlib import Path
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_operation as operation_fixture


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                     (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                     'requires native final-row application and private stage')
class TransferFinalRowsTests(operation_fixture.TransferOperationTests):
    # Focused runs select these methods explicitly; no inherited test repetition.
    def setUp(self):
        super().setUp()
        self.config.update(final_rows=True,final_layout=True)
        with fixture.connect(self.catalogue) as db:
            fixture.insert(db,'CatalogBookCopies',dict(SourceKey='missing-extra',BookID=3,Root=str(self.b),
                Folder='missing-copy.zip',FileName='103',Ext='.fb2',InsideNo=0,BookSize=123,
                LibID='b:103',SourceName='Недоступная копия'))
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Books',dict(BookID=3,DatabaseID=7,LibID='103',Title='Отсутствующая книга',
                Folder='notdownloaded.zip',FileName='103',Ext='.fb2',BookSize=803,Rate=4,Progress=56,
                Annotation='Личные данные отсутствующей книги',Review=b'kept missing review'))

    def mapped_root(self,root):
        old=Path(root);old=old if old.is_absolute() else self.home/old
        for source,dest in self.read_review('select InputPath,Destination from Roots where Destination is not null'):
            if old==Path(source):return Path(dest)
        return old

    def missing_archive(self):
        return self.mapped_root(self.a)/'notdownloaded.zip'

    def receipt(self,path):
        with fixture.connect(path) as db:
            if not db.execute("select count(*) from sqlite_master where name='HomeLibreTransferFinalRows'").fetchone()[0]:return None
            return db.execute('select * from HomeLibreTransferFinalRows').fetchone()

    def check_metadata(self,before):
        if getattr(self,'expect_all_metadata_unchanged',False):
            # This deliberately stale available locator must remain stale on
            # refusal. The ordinary observer otherwise models its prior location
            # receipt as an instruction to publish it again.
            self.assertEqual(self.snapshots(),before)
            return
        # Independent expected changes for the known missing archive fixtures.
        # The existing verifier then compares every existing table/field and
        # models ordinary available-file publication separately.
        expected=copy.deepcopy(before)
        for path,(_,tables,columns) in expected.items():
            if not self.receipt(path):continue
            personal=path==self.personal
            for table in ('Books','CatalogBookCopies'):
                if table not in tables:continue
                rows=[];cols=columns[table]
                for row in tables[table]:
                    data=dict(zip(cols,row));changed=False
                    if table=='Books' and data['BookID']==3 and (not personal or data['DatabaseID']==7):
                        newfolder=str(self.missing_archive())
                        changed=data['Folder']!=newfolder;data['Folder']=newfolder
                    if table=='CatalogBookCopies':
                        if data['SourceKey']=='missing-extra':data['Folder']=str(self.mapped_root(self.b)/'missing-copy.zip')
                        if data['Root']:data['Root']=str(self.mapped_root(data['Root']))+os.sep
                    if changed:
                        for col in cols:
                            if col.startswith('Search') and col[6:] in data:
                                value=data[col[6:]];data[col]=value.upper() if value else ''
                    rows.append(tuple(data[c] for c in cols))
                tables[table]=rows
        super().check_metadata(expected)

    def rows_only(self,expected=0,**options):
        self.config.update(mode='registered',operation=self.operation(),run_operation=False,remove_sources=False,
                           prepare=False,apply_locations=False,final_rows=True,final_rows_cancel_after=0)
        self.config.update(options);return self.run_case(expected)

    def test_final_rows_apply_and_readonly_verify_preserve_every_other_field(self):
        result=self.run_case()
        self.assertEqual((result['final_future_rows'],result['final_copy_roots']),(3,2))
        self.assertFalse(self.missing_archive().exists())
        for path in (self.catalogue,self.personal):
            receipt=self.receipt(path);self.assertEqual(receipt[0],self.journal().name)
            self.assertEqual(receipt[1],self.anchor()['review_sha256']);self.assertEqual(len(receipt[4]),64)
        with fixture.connect(self.personal) as db:
            self.assertEqual(Path(db.execute('select RootFolder from Bases where DatabaseID=7').fetchone()[0]),self.a)
        with fixture.connect(self.catalogue) as db:
            self.assertEqual(db.execute('select SettingValue from Settings where SettingID=?',(fixture.SOURCE_PROPERTY,)).fetchone()[0],self.sources)
        hashes={p:fixture.digest(p) for p in (self.catalogue,self.personal)}
        result=self.rows_only(verify_final_rows=True)
        self.assertEqual((result['final_future_rows'],result['final_copy_roots']),(0,0))
        self.assertEqual({p:fixture.digest(p) for p in hashes},hashes,'read-only verification wrote the stores')
        self.assertEqual(self.registry_rows('HomeLibreTransferOperations')[0][-1],'pending')

    def test_cancel_after_first_future_write_rolls_back_all_rows_and_receipts(self):
        self.config['final_rows']=False;self.run_case()
        before=self.snapshots()
        self.assertIn('останов',self.rows_only('fail',final_rows_cancel_after=3))
        self.assertEqual(self.snapshots(),before)
        self.assertIsNone(self.receipt(self.catalogue));self.assertIsNone(self.receipt(self.personal))
        self.assertEqual(self.rows_only()['final_future_rows'],3)

    def test_foreign_file_at_future_missing_address_is_preserved_and_refused(self):
        self.config['final_rows']=False;self.run_case()
        target=self.missing_archive();self.assertTrue(target.parent.is_dir());target.write_bytes(b'foreign future file')
        before=self.snapshots()
        self.assertIn('Появился файл',self.rows_only('fail'))
        self.assertEqual(target.read_bytes(),b'foreign future file');self.assertEqual(self.snapshots(),before)

    def test_changed_missing_book_is_not_overwritten(self):
        self.config['final_rows']=False;self.run_case()
        with fixture.connect(self.catalogue) as db:db.execute("update Books set Ext='.epub' where BookID=3")
        before=self.snapshots()
        self.assertIn('Отсутствующая книга изменилась',self.rows_only('fail'))
        self.assertEqual(self.snapshots(),before);self.assertIsNone(self.receipt(self.catalogue))

    def test_relative_copy_root_is_expanded_before_its_final_mapping(self):
        with fixture.connect(self.catalogue) as db:
            db.execute("update CatalogBookCopies set Root='source-b' where SourceKey='missing-extra'")
        self.assertEqual(self.run_case()['final_copy_roots'],2)
        with fixture.connect(self.catalogue) as db:
            root=db.execute("select Root from CatalogBookCopies where SourceKey='missing-extra'").fetchone()[0]
        self.assertEqual(Path(root),self.mapped_root(self.b))

    def test_deleted_missing_personal_card_is_not_recreated(self):
        self.config['final_rows']=False;self.run_case()
        with fixture.connect(self.personal) as db:db.execute('delete from Books where BookID=3 and DatabaseID=7')
        self.assertEqual(self.rows_only()['final_future_rows'],2)
        with fixture.connect(self.personal) as db:
            self.assertEqual(db.execute('select count(*) from Books where BookID=3 and DatabaseID=7').fetchone()[0],0)
        self.assertIsNotNone(self.receipt(self.personal))

    def test_changed_final_row_receipt_is_refused_without_rewriting_it(self):
        self.run_case()
        with fixture.connect(self.catalogue) as db:
            db.execute("update HomeLibreTransferFinalRows set BindingSHA256=?",('0'*64,))
        before=self.snapshots()
        self.assertIn('Квитанция итоговых адресов',self.rows_only('fail',verify_final_rows=True))
        self.assertEqual(self.snapshots(),before);self.assertEqual(self.receipt(self.catalogue)[4],'0'*64)

    def test_unpublished_relative_copy_address_prevents_root_change_and_rolls_back(self):
        self.config['final_rows']=False;self.run_case()
        with fixture.connect(self.catalogue) as db:
            db.execute("update CatalogBookCopies set Folder='same.zip' where SourceKey='b:file:stable-copy'")
        before=self.snapshots()
        self.expect_all_metadata_unchanged=True
        self.assertIn('несохранённым адресом',self.rows_only('fail'))
        self.assertEqual(self.snapshots(),before);self.assertIsNone(self.receipt(self.catalogue))
