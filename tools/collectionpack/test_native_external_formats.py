"""Complete EPUBs through the installed producer and native publication job."""
import io
import json
import os
from pathlib import Path
import random
from xml.etree import ElementTree as ET
import zipfile

from supervised_test_process import run_owned
from test_native_compression_operation import NativeCompressionOperationTests
from test_native_compression_receipt import database, png, sha
from test_prepare_book_compression import epub
from archive_replacement import archive_inventory
from pack_collection import SevenZip, digest_file
from prepare_book_compression import verify_non_image_content


class NativeExternalFormatTests(NativeCompressionOperationTests):
    def test_stripped_zip_epub_preserves_resources_full_original_and_repeat(self):
        self.check_epub(False)

    def test_nested_7z_epub_preserves_resources_full_original_and_repeat(self):
        self.check_epub(True)

    def test_nested_epub_optimizes_embedded_and_external_images_together(self):
        self.check_epub(True, embedded=True)

    def test_nested_epub_without_sidecars_restores_full_backup_and_size(self):
        self.check_epub(True, embedded=True, separated=False, container='books.zip')

    def test_nested_epub_processes_embedded_and_external_webp_by_content(self):
        from PIL import Image
        output = io.BytesIO()
        Image.frombytes('RGB',(256,256),random.Random(367).randbytes(256*256*3)).save(output,'WEBP',quality=75)
        self.check_epub(True,embedded=True,picture=output.getvalue())

    def check_real_flibrary_epub(self):
        archive = Path(os.environ['HL_REAL_EPUB_ARCHIVE'])
        member = os.environ['HL_REAL_EPUB_ENTRY']
        self.assertTrue(member.endswith('.epub') and Path(member).name == member)
        book_id = Path(member).stem
        decoder = SevenZip(self.config['seven_zip'], lambda: None)
        sources = [archive]
        side_sources = []
        for kind in ('covers','images'):
            for extension in ('.zip','.7z'):
                side = archive.parent/kind/(archive.stem+extension)
                if side.is_file():
                    sources.append(side)
                    side_sources.append((kind,side))
                    break
        before = {str(p):dict(bytes=p.stat().st_size,modified=p.stat().st_mtime_ns,
                              sha256=digest_file(p, lambda: None)) for p in sources}
        try:
            stage = self.root/'real-input'
            stage.mkdir()
            raw = stage/member
            decoder.extract(archive, member, raw, stage)
            self.fixture.source.unlink()
            self.fixture.source = self.root/'books.7z'
            decoder.run(['a','-t7z','-mx=0','-y','--',str(self.fixture.source),member], cwd=stage)
            copied = {}
            for kind, side in side_sources:
                entries = archive_inventory(decoder, side, stage)
                names = [name for name,item in entries.items() if not item['directory'] and
                         (name == book_id if kind=='covers' else name.startswith(book_id+'/'))]
                target = self.root/kind/'books.zip'
                target.parent.mkdir()
                with zipfile.ZipFile(target,'x',zipfile.ZIP_STORED) as output:
                    for number,name in enumerate(names):
                        image = stage/(kind+'-'+str(number)+'.bin')
                        decoder.extract(side,name,image,stage)
                        output.write(image,name)
                copied[kind] = len(names)
            self.config['selected'][0].update(folder='books.7z',file_name=book_id,ext='.epub')
            self.config['timeout_ms'] = 120000
            with database(self.fixture.catalogue) as db:
                db.execute('DELETE FROM Books WHERE BookID<>101')
                db.execute("UPDATE Books SET Folder='books.7z',FileName=?,Ext='.epub',InsideNo=0", (book_id,))
                db.execute("UPDATE CatalogBookCopies SET Folder='books.7z',FileName=?,Ext='.epub',InsideNo=0", (book_id,))
            with database(self.fixture.personal) as db:
                db.execute("UPDATE Books SET Folder='books.7z',FileName=?,Ext='.epub',InsideNo=0 WHERE DatabaseID=7", (book_id,))
            self.config['operation_mode'] = 'book-stream'
            opened = self.run_operation()
            complete_before = self.root/'before.epub'
            Path(opened['book_stream']).replace(complete_before)
            self.config['operation_mode'] = 'apply'
            self.config.update(profile='maximum',grayscale=True)
            backups = self.enable_backup()
            result = self.run_operation()
            self.assertEqual(result['error'], '', result)
            self.assertEqual(result['changed_files'],1,result)
            self.assertEqual(result['pending_after_ack'],0,result)
            saved, = backups.glob('*.zip')
            with zipfile.ZipFile(saved) as backup:
                full_original = self.root/'original.epub'
                full_original.write_bytes(backup.read('books/'+member))
            verify_non_image_content(complete_before,full_original,'.epub')
            with zipfile.ZipFile(full_original) as book:
                self.assertIsNone(book.testzip())
                self.assertEqual(book.namelist()[0],'mimetype')
            self.config['operation_mode'] = 'book-stream'
            opened_after = self.run_operation()
            verify_non_image_content(complete_before,Path(opened_after['book_stream']),'.epub')
            with database(self.fixture.catalogue) as db:
                size = db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0]
                self.assertEqual(size,opened_after['book_size'])
                self.assertEqual(size,db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0])
            with database(self.fixture.personal) as db:
                self.assertEqual(size,db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0])
            evidence = dict(member=member,source=str(archive),raw_bytes=raw.stat().st_size,
                raw_sha256=digest_file(raw,lambda:None),copied_images=copied,
                complete_original_bytes=complete_before.stat().st_size,complete_result_bytes=size,
                saved_bytes=result['saved_bytes'],full_original_verified=True,non_image_content_unchanged=True,
                sources=before,source_writes=False)
        finally:
            self.assertEqual(before,{str(p):dict(bytes=p.stat().st_size,modified=p.stat().st_mtime_ns,
                sha256=digest_file(p, lambda: None)) for p in sources})
        Path(os.environ['HL_REAL_EPUB_EVIDENCE']).write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')

    def check_epub(self, nested, embedded=False, separated=True, container='books.7z', picture=None):
        if picture is None: picture = png(False, random.Random(175).randbytes(128*128))
        original = epub(picture)
        stage = self.root/'outer-input'
        stage.mkdir()
        entries = {}
        with zipfile.ZipFile(io.BytesIO(original)) as archive:
            for name in archive.namelist():
                if name != 'picture.png' or not separated:
                    entries[name] = archive.read(name)
        if separated:
            entries['FLibraryImageIndex.json'] = json.dumps([
                {'id':'picture.png', 'num':1}, {'id':'cover.png', 'num':-1}]).encode()
        # The cover is a separate resource and must also be described by OPF.
        if separated:
            entries['book.opf'] = entries['book.opf'].replace(b'</manifest>',
                b'<item id="cover" href="cover.png" media-type="image/png"/></manifest>')
        if embedded:
            entries['embedded.png'] = picture
            entries['book.opf'] = entries['book.opf'].replace(b'</manifest>',
                b'<item id="embedded" href="embedded.png" media-type="image/png"/></manifest>')
        if nested:
            contents = self.root/'inner-input'
            contents.mkdir()
            for name, data in entries.items():
                target = contents/name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            process = run_owned([self.config['seven_zip'],'a','-t7z','-mx=9','-y','--',
                str(stage/'one.epub'), *entries], cwd=contents, capture_output=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr)
        else:
            with zipfile.ZipFile(stage/'one.epub', 'x', zipfile.ZIP_DEFLATED) as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
        (stage/'neighbor.txt').write_bytes(b'Keep this other book byte for byte.')
        self.fixture.source.unlink()
        self.fixture.source = self.root/container
        process = run_owned([self.config['seven_zip'],'a','-t7z','-mx=9','-y','--',
            str(self.fixture.source),'one.epub','neighbor.txt'], cwd=stage, capture_output=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.config['selected'][0].update(folder=container, ext='.epub')
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder=?,Ext='.epub' WHERE BookID=101", (container,))
            db.execute("UPDATE Books SET Folder=?,Ext='.txt' WHERE BookID=102", (container,))
            db.execute("UPDATE CatalogBookCopies SET Folder=?,Ext='.epub'", (container,))
        with database(self.fixture.personal) as db:
            db.execute("UPDATE Books SET Folder=?,Ext='.epub' WHERE DatabaseID=7", (container,))
        sides = []
        for folder, member in ([('covers','one'), ('images','one/1')] if separated else []):
            target = self.root/folder/'books.zip'
            target.parent.mkdir()
            with zipfile.ZipFile(target, 'x', zipfile.ZIP_STORED) as archive:
                archive.writestr(member, picture)
                archive.writestr('neighbor' if folder=='covers' else 'neighbor/1', b'Keep neighbor image')
            sides.append(target)
        backups = self.enable_backup()
        self.config.update(profile='maximum', grayscale=True)
        result = self.run_operation()
        self.assertEqual(result['error'], '', result)
        self.assertEqual(result['changed_files'], 1, result)
        self.assertEqual(result['pending_after_ack'], 0, result)
        saved = list(backups.glob('*.zip'))
        self.assertEqual(len(saved), 1)
        with zipfile.ZipFile(saved[0]) as archive:
            complete = archive.read('books/one.epub')
        with zipfile.ZipFile(io.BytesIO(complete)) as archive:
            self.assertEqual(archive.namelist()[0], 'mimetype')
            self.assertEqual(archive.getinfo('mimetype').compress_type, zipfile.ZIP_STORED)
            self.assertNotIn('FLibraryImageIndex.json', archive.namelist())
            self.assertEqual(archive.read('picture.png'), picture)
            if separated:
                self.assertEqual(archive.read('cover.png'), picture)
            if embedded:
                self.assertEqual(archive.read('embedded.png'), picture)
            for name in ['chapter.xhtml','book.css','font.ttf','drawing.svg','META-INF/container.xml']:
                self.assertEqual(archive.read(name), entries[name])
            ET.fromstring(archive.read('book.opf'))
        with database(self.fixture.catalogue) as db:
            size = db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0]
            self.assertLess(size, len(complete))
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0], size)
        with database(self.fixture.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0], size)
        self.config['operation_mode'] = 'book-stream'
        restored = self.run_operation()
        self.config['operation_mode'] = 'apply'
        self.assertEqual(restored['book_size'], size)
        with zipfile.ZipFile(restored['book_stream']) as archive:
            for name in ['chapter.xhtml','book.css','font.ttf','drawing.svg','META-INF/container.xml']:
                self.assertEqual(archive.read(name), entries[name])
            for name in (['picture.png','cover.png'] if separated else ['picture.png']):
                self.assertLess(len(archive.read(name)), len(picture))
            if embedded:
                self.assertLess(len(archive.read('embedded.png')), len(picture))
        before = {p:sha(p.read_bytes()) for p in (self.fixture.source,self.fixture.catalogue,self.fixture.personal,*sides)}
        second = self.run_operation()
        self.assertEqual(second['error'], '', second)
        self.assertEqual(second['changed_files'], 0, second)
        self.assertEqual(before, {p:sha(p.read_bytes()) for p in before})


for _name in dir(NativeCompressionOperationTests):
    if _name.startswith('test_'):
        setattr(NativeExternalFormatTests, _name, None)
del NativeCompressionOperationTests
