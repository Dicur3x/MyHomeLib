"""Incremental image compression with real codecs and read-only history lookups."""
import base64
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET
import zipfile

from compression_image_history import CompressedImageHistory
from estimate_book_compression import estimate_selected_file
from pack_collection import Canceled, PackingError, temporary_work_directory
from prepare_book_compression import prepare_selected_file, profile_digest, verify_non_image_content
from test_pack_collection import database, illustrated_fb2, image_fixture, sha
from test_prepare_book_compression import epub

TOOLS = os.environ.get('HLRU_PACK_IMAGE_TOOLS')
SEVEN = Path(os.environ.get('HLRU_PACK_7ZIP', '../../Program/Out/Bin64/tools/7zip/7za.exe')).absolute()


class ImageHistoryFixture:
    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-image-history-')
        self.root = self.temp.__enter__()
        self.database = self.root/'Коллекция ё #1.sqlite'

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def store_history(self, prepared):
        # The native receipt commit owns this write in the application. This
        # fixture provides the cross-language table contract, not a native test.
        with database(self.database) as db:
            db.execute('CREATE TABLE IF NOT EXISTS HomeLibreCompressedImages('
                'ProfileSHA256 TEXT NOT NULL,ImageSHA256 TEXT NOT NULL,'
                'PRIMARY KEY(ProfileSHA256,ImageSHA256)) WITHOUT ROWID')
            for payload in prepared.payloads:
                db.executemany('INSERT OR IGNORE INTO HomeLibreCompressedImages VALUES(?,?)',
                    [(prepared.profile_sha256, value) for value in payload['image_outputs']])

class ImageHistoryTests(ImageHistoryFixture, unittest.TestCase):
    def test_legacy_catalogue_is_read_only_and_does_not_create_history(self):
        with database(self.database) as db:
            db.execute('CREATE TABLE PersonalText(Value TEXT)')
            db.execute('INSERT INTO PersonalText VALUES(?)', ('Не менять',))
        before = sha(self.database)
        with CompressedImageHistory(self.database, profile_digest('maximum', False)) as history:
            self.assertFalse(history.contains('a'*64))
        self.assertEqual(sha(self.database), before)
        with database(self.database) as db:
            self.assertEqual(db.execute('SELECT name FROM sqlite_master WHERE type="table"').fetchall(), [('PersonalText',)])

    def test_profile_scopes_hashes_and_queries_do_not_write(self):
        with database(self.database) as db:
            db.execute('CREATE TABLE HomeLibreCompressedImages(ProfileSHA256 TEXT, ImageSHA256 TEXT,'
                'PRIMARY KEY(ProfileSHA256,ImageSHA256)) WITHOUT ROWID')
            db.execute('INSERT INTO HomeLibreCompressedImages VALUES(?,?)', (profile_digest('maximum', False), 'a'*64))
        before = sha(self.database)
        with CompressedImageHistory(self.database, profile_digest('maximum', False)) as history:
            self.assertTrue(history.contains('a'*64))
            self.assertFalse(history.contains('b'*64))
        with CompressedImageHistory(self.database, profile_digest('maximum', True)) as history:
            self.assertFalse(history.contains('a'*64))
        self.assertEqual(sha(self.database), before)

    def test_missing_catalogue_is_not_created(self):
        with self.assertRaises(PackingError):
            with CompressedImageHistory(self.database, profile_digest('balanced', False)):
                pass
        self.assertFalse(self.database.exists())

    def test_cancellation_prevents_opening_history(self):
        def cancel(): raise Canceled('stop')
        with self.assertRaises(Canceled):
            with CompressedImageHistory(self.database, profile_digest('maximum', False), cancel):
                pass
        self.assertFalse(self.database.exists())


@unittest.skipUnless(TOOLS, 'Real HomeLibre Images runtime required')
class IncrementalCodecTests(ImageHistoryFixture, unittest.TestCase):
    def prepare(self, source, *, profile='maximum', grayscale=False, previous=None, use_history=True):
        workspace = self.root/('work-'+str(len(list(self.root.glob('work-*')))))
        workspace.mkdir()
        return prepare_selected_file(source, {'':source.suffix}, workspace, SEVEN,
            tools_root=TOOLS, profile=profile, grayscale=grayscale, previous=previous,
            image_history_database=self.database if use_history else None)

    def first_book(self, extension):
        source = self.root/('first'+extension)
        source.write_bytes(illustrated_fb2(image_fixture()) if extension=='.fb2' else epub(image_fixture()))
        first = self.prepare(source, use_history=False)
        self.assertIsNotNone(first.candidate, first.books)
        self.assertTrue(first.payloads[0]['image_outputs'])
        self.store_history(first)
        return first

    def modified(self, first, extension, add_picture):
        source = self.root/('Переименованная книга'+extension)
        if extension=='.fb2':
            root = ET.parse(first.candidate).getroot()
            root.find('.//{*}p').text = 'Updated text without changing the old picture.'
            if add_picture:
                body = root.find('.//{*}section')
                ET.SubElement(body,'{http://www.gribuser.ru/xml/fictionbook/2.0}image',
                    {'{http://www.w3.org/1999/xlink}href':'#fresh'})
                ET.SubElement(root,'{http://www.gribuser.ru/xml/fictionbook/2.0}binary',
                    {'id':'fresh','content-type':'image/png'}).text = base64.b64encode(image_fixture()).decode()
            source.write_bytes(ET.tostring(root,encoding='utf-8',xml_declaration=True))
        else:
            with zipfile.ZipFile(first.candidate) as incoming, zipfile.ZipFile(source,'w',compression=zipfile.ZIP_DEFLATED) as outgoing:
                for entry in incoming.infolist():
                    data = incoming.read(entry)
                    if entry.filename=='chapter.xhtml': data = data.replace(b'Keep ',b'Updated ')
                    if add_picture and entry.filename=='book.opf':
                        root = ET.fromstring(data)
                        ET.SubElement(root.find('{*}manifest'),'{http://www.idpf.org/2007/opf}item',
                            {'id':'fresh','href':'fresh.png','media-type':'image/png'})
                        data = ET.tostring(root,encoding='utf-8',xml_declaration=True)
                    outgoing.writestr(entry.filename,data,compress_type=zipfile.ZIP_STORED if entry.filename=='mimetype' else zipfile.ZIP_DEFLATED)
                if add_picture: outgoing.writestr('fresh.png',image_fixture())
        return source

    def images(self, path, extension):
        if extension=='.fb2':
            return {n.get('id'):base64.b64decode(n.text) for n in ET.parse(path).getroot().findall('{*}binary')}
        with zipfile.ZipFile(path) as archive:
            return {n:archive.read(n) for n in ('picture.png','fresh.png') if n in archive.namelist()}

    def watch_encoder(self, inputs):
        original = subprocess.Popen
        def observe(arguments, *args, **options):
            if isinstance(arguments,(list,tuple)) and '--export-images' in arguments:
                with zipfile.ZipFile(arguments[2]) as archive:
                    inputs.extend(hashlib.sha256(archive.read(n)).hexdigest() for n in archive.namelist())
            return original(arguments,*args,**options)
        return patch('subprocess.Popen', observe)

    def test_text_and_path_change_do_not_reencode_old_images(self):
        for extension in ('.fb2','.epub'):
            with self.subTest(extension=extension):
                first = self.first_book(extension)
                source = self.modified(first,extension,False)
                before, history_before = sha(source), sha(self.database)
                encoded = []
                with self.watch_encoder(encoded):
                    result = self.prepare(source)
                self.assertEqual(encoded,[])
                self.assertIsNone(result.candidate)
                self.assertEqual(result.books[0]['images_reused'],1)
                self.assertEqual(result.books[0]['images_processed'],0)
                self.assertEqual(sha(source),before)
                self.assertEqual(sha(self.database),history_before)

    def test_new_picture_only_is_encoded_and_old_bytes_are_exact(self):
        for extension in ('.fb2','.epub'):
            with self.subTest(extension=extension):
                first = self.first_book(extension)
                source = self.modified(first,extension,True)
                old = self.images(source,extension)
                old_name, fresh_name = ('picture','fresh') if extension=='.fb2' else ('picture.png','fresh.png')
                before, history_before = sha(source),sha(self.database)
                encoded = []
                with self.watch_encoder(encoded):
                    result = self.prepare(source)
                self.assertIsNotNone(result.candidate,result.books)
                self.assertEqual(encoded,[hashlib.sha256(old[fresh_name]).hexdigest()])
                changed = self.images(result.candidate,extension)
                self.assertEqual(changed[old_name],old[old_name])
                self.assertNotEqual(changed[fresh_name],old[fresh_name])
                self.assertEqual(result.books[0]['images_reused'],1)
                self.assertEqual(result.books[0]['images_processed'],1)
                verify_non_image_content(source,Path(result.candidate),extension)
                self.assertEqual(sha(source),before)
                self.assertEqual(sha(self.database),history_before)

    def test_explicit_grayscale_setting_has_its_own_history(self):
        first = self.first_book('.fb2'); source=self.modified(first,'.fb2',False)
        result = self.prepare(source,profile='maximum',grayscale=True)
        self.assertIsNotNone(result.candidate,result.books)
        self.assertEqual(result.books[0]['images_reused'],0)
        self.assertEqual(result.books[0]['images_processed'],1)
        from PIL import Image
        with Image.open(io.BytesIO(self.images(result.candidate,'.fb2')['picture'])) as picture:
            r,g,b=picture.convert('RGB').getpixel((picture.width//2,picture.height//2))
            self.assertLessEqual(max(r,g,b)-min(r,g,b),1)

    def test_larger_grayscale_result_is_not_published_or_recorded(self):
        first = self.first_book('.fb2'); source=self.modified(first,'.fb2',False)
        before, history_before = sha(source), sha(self.database)
        result = self.prepare(source,profile='original',grayscale=True)
        self.assertIsNone(result.candidate, result.books)
        self.assertEqual(result.payloads[0]['image_outputs'], [])
        self.assertEqual(result.books[0]['images_reused'], 0)
        self.assertEqual(result.books[0]['images_processed'], 1)
        self.assertEqual(result.result_sha256, result.source_sha256)
        self.assertEqual(sha(source), before)
        self.assertEqual(sha(self.database), history_before)

    def test_history_failure_cancels_before_encoding_and_cleans_workspace(self):
        first = self.first_book('.fb2'); source=self.modified(first,'.fb2',True)
        before,history_before=sha(source),sha(self.database)
        with patch('compression_image_history.CompressedImageHistory.contains',side_effect=Canceled('stop during history')):
            with self.assertRaises(Canceled): self.prepare(source)
        self.assertEqual(sha(source),before)
        self.assertEqual(sha(self.database),history_before)
        last=sorted(self.root.glob('work-*'))[-1]
        self.assertEqual(list(last.iterdir()),[])

    def test_estimate_reuses_old_images_and_samples_only_new_images(self):
        for extension in ('.fb2','.epub'):
            with self.subTest(extension=extension):
                first = self.first_book(extension)
                for add_picture in (False,True):
                    with self.subTest(new_picture=add_picture):
                        source = self.modified(first,extension,add_picture)
                        before, history_before = sha(source),sha(self.database)
                        workspace = self.root/('estimate'+extension+str(add_picture)); workspace.mkdir()
                        encoded = []
                        with self.watch_encoder(encoded):
                            result = estimate_selected_file(source,{'':extension},workspace,SEVEN,
                                profile='maximum',tools_root=TOOLS,image_history_database=self.database)
                        row = result['books'][0]
                        self.assertIsNotNone(row['output_bytes'],row)
                        self.assertEqual(row['images_reused'],1)
                        if add_picture:
                            self.assertEqual(encoded,[hashlib.sha256(image_fixture()).hexdigest()])
                            actual = self.prepare(source).books[0]['output_bytes']
                            self.assertLessEqual(abs(row['output_bytes']-actual)/actual,.10)
                            self.assertEqual(row['sampled'],1)
                        else:
                            self.assertEqual(encoded,[])
                            self.assertTrue(row['exact'])
                            self.assertEqual(row['output_bytes'],source.stat().st_size)
                        self.assertEqual(sha(source),before)
                        self.assertEqual(sha(self.database),history_before)
                        self.assertEqual(list(workspace.iterdir()),[])


if __name__=='__main__': unittest.main(verbosity=2)
