"""Ordinary transfer space preview with real caches and immutable user data."""
import os
from pathlib import Path
import unittest

import test_native_collection_transfer_catalogue as fixture
import test_native_collection_transfer_journal as journal
import test_native_collection_transfer_cache_preparation as preparation


@unittest.skipUnless(os.name=='nt' and all(p and p.is_file() for p in
                    (fixture.BINARY,fixture.SQLITE,fixture.SEVENZIP)) and fixture.STAGE,
                    'requires native transfer space preview and owned stage')
class TransferSpaceTests(preparation.TransferCachePreparationTests):
    def setUp(self):
        super().setUp()
        self.config.update(space_preview=True)

    def preview(self, expected=0):
        before=self.protected()
        result=journal.TransferJournalTests.run_case(self, expected)
        self.assertEqual(self.protected(),before)
        self.assertFalse(self.control.exists())
        self.assertFalse(list(self.work.glob('collection-transfer-*')))
        self.assertFalse(list(self.destination.iterdir()))
        if expected==0:
            for row in result['space']:
                self.assertGreaterEqual(row['free'],0)
                self.assertEqual(row['required'],sum(row[name] for name in ('books','working','caches','catalogues','reserve')))
            self.assertEqual(len({row['key'] for row in result['space']}),len(result['space']))
        return result

    def test_cache_history_shared_alias_and_named_streams_share_volume_budget(self):
        # Another registration with the same physical catalogue needs a fork;
        # preview must account for it without making a catalogue snapshot.
        with fixture.connect(self.personal) as db:
            fixture.insert(db,'Bases',dict(DatabaseID=9,BaseName='Alias',DBFileName=str(self.catalogue),RootFolder=str(self.a)))
        named=self.a/'same.zip:HomeLibreSpace'
        named.write_bytes(b'additional stream'*257)
        result=self.preview()
        self.assertEqual(named.read_bytes(),b'additional stream'*257)
        work=next(row for row in result['space'] if row['books']>0)
        expected=sum(path.stat().st_size for path in (self.a/'same.zip',self.b/'same.zip',named))
        self.assertEqual(work['books'],expected)
        self.assertEqual(work['reserve'],512*1024**2)
        # Two different roots for each of the two old cache versions; source
        # and its compatible bound history share their new version/input.
        cache_bytes=sum((folder/'catalog.hlc2').stat().st_size for folder in (self.cache_a,self.cache_b))
        index_bytes=sum((folder/'retained.inpx').stat().st_size for folder in (self.cache_a,self.cache_b))
        self.assertEqual(work['caches'],4*cache_bytes+2*index_bytes)
        self.assertGreaterEqual(work['working'],6*cache_bytes+2*index_bytes+64*1024**2)
        self.assertGreater(work['catalogues'],0)
        system=next(row for row in result['space'] if row['reserve']==8*1024**3)
        self.assertEqual(system['books'],0)

    def test_existing_destination_does_not_charge_in_place_books(self):
        self.config['destination']=str(self.a)
        # No copying is expected during a preview, including existing books.
        before=fixture.digest(self.a/'same.zip')
        result=journal.TransferJournalTests.run_case(self)
        self.assertEqual(fixture.digest(self.a/'same.zip'),before)
        self.assertFalse(list(self.work.glob('collection-transfer-*')))
        self.assertEqual(sum(row['books'] for row in result['space']),(self.b/'same.zip').stat().st_size)

    def test_cancel_discards_preview_and_never_creates_a_pending_move(self):
        self.config['cancel_space']=True
        output=self.preview('fail')
        self.assertIn('TRACE estimating transfer space',output)
        self.assertIn('EAbort:',output)

    def test_missing_cache_is_diagnosed_before_any_book_is_copied(self):
        (self.cache_a/'catalog.hlc2').rename(self.cache_a/'offline-cache')
        output=self.preview('fail')
        self.assertIn('TRACE estimating transfer space',output)
        self.assertIn('сохранённый кэш',output)
