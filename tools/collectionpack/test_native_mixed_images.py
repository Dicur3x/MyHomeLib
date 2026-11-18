"""Mixed raster formats through complete native FLibrary publication/readback."""
import base64
import io
from pathlib import Path
import random
from xml.etree import ElementTree as ET
import zipfile

from PIL import Image, ImageChops

from supervised_test_process import run_owned
from test_native_compression_operation import NativeCompressionOperationTests
from test_native_compression_receipt import database, png, sha
from prepare_book_compression import verify_non_image_content


class NativeMixedImageTests(NativeCompressionOperationTests):
    def make_shared_archives(self, solid=False):
        first, second = self.fixture.source, self.root / 'BOOKS.7z'
        first.unlink()
        source_dir = self.root / 'input-books'
        source_dir.mkdir()
        for archive, member in ((first, 'one'), (second, 'neighbor')):
            text = (f'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
                    f'xmlns:l="http://www.w3.org/1999/xlink"><body><section><p>{member}</p>'
                    f'<image l:href="#1"/></section></body></FictionBook>').encode()
            (source_dir / (member + '.fb2')).write_bytes(text)
            proc = run_owned([self.config['seven_zip'], 'a', '-t7z', '-mx=9', '-y', '--',
                              str(archive), member + '.fb2'], cwd=source_dir, capture_output=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        other = dict(self.config['selected'][0], id=102, lib_id='flibusta:102', folder=second.name,
                     file_name='neighbor', member='neighbor.fb2', inside_no=0)
        self.config['selected'].append(other)
        with database(self.fixture.catalogue) as db:
            db.execute('UPDATE Books SET Folder=?, InsideNo=0 WHERE BookID=102', (second.name,))
        side = self.root / 'images' / ('books.7z' if solid else 'books.zip')
        side.parent.mkdir()
        originals = {m + '/1': png(False, random.Random(i).randbytes(128 * 128))
                     for i, m in enumerate(('one', 'neighbor', 'untouched'))}
        if solid:
            for member, image in originals.items():
                path = source_dir / member
                path.parent.mkdir()
                path.write_bytes(image)
            proc = run_owned([self.config['seven_zip'], 'a', '-t7z', '-ms=on', '-mx=1', '-y', '--',
                              str(side), *originals], cwd=source_dir, capture_output=True, timeout=30)
            self.assertEqual(proc.returncode, 0, proc.stderr)
        else:
            with zipfile.ZipFile(side, 'x', zipfile.ZIP_STORED) as archive:
                for member, image in originals.items():
                    archive.writestr(member, image)
        return [first, second, side], originals

    def read_shared_image(self, side, member):
        proc = run_owned([self.config['seven_zip'], 'x', '-so', '-spd', '-ssc', '--', str(side), member],
                         capture_output=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def compare_shared_trial(self, solid):
        paths, originals = self.make_shared_archives(solid)
        side = paths[2]
        inputs = {p: sha(p.read_bytes()) for p in [*paths, self.fixture.catalogue, self.fixture.personal]}
        before = sum(p.stat().st_size for p in paths)
        self.config.update(operation_mode='trial-only', estimate_first=True, profile='maximum', grayscale=True,
                           timeout_ms=120000)
        trial = self.run_operation()
        self.assertEqual(trial['error'], '', trial)
        self.assertTrue(trial['trial_ready'])
        self.assertEqual(inputs, {p: sha(p.read_bytes()) for p in inputs})
        self.config.update(operation_mode='apply', estimate_first=False)
        applied = self.run_operation()
        self.assertEqual(applied['error'], '', applied)
        self.assertEqual(applied['changed_files'], 2, applied)
        after = sum(p.stat().st_size for p in paths)
        self.assertEqual(before - after, applied['saved_bytes'])
        self.assertLess(after, before)
        self.assertEqual(self.read_shared_image(side,'untouched/1'), originals['untouched/1'])
        for name in ('one/1', 'neighbor/1'):
            self.assertNotEqual(self.read_shared_image(side,name), originals[name])
        self.assertEqual(trial['trial_shared_files'], 0, trial)
        self.assertEqual(trial['trial_input_bytes'], before)
        self.assertLessEqual(abs(trial['trial_output_bytes'] - after), 64)

    def test_trial_counts_a_side_archive_shared_by_two_book_archives_once(self):
        self.compare_shared_trial(False)

    def test_trial_replays_two_updates_to_a_shared_solid_side_archive(self):
        self.compare_shared_trial(True)

    def test_failed_shared_refresh_keeps_the_committed_job_recoverable(self):
        paths, originals = self.make_shared_archives()
        self.config.update(acknowledge=False, profile='maximum', grayscale=True, timeout_ms=90000,
                           refresh_error='Shared refresh interrupted')
        first = self.run_operation()
        self.assertEqual(first['error'], self.config['refresh_error'], first)
        self.assertEqual(first['changed_files'], 1, first)
        self.assertEqual(first['pending_after_ack'], 1)
        bodies = {name:self.read_shared_image(paths[2],name) for name in originals}
        self.assertEqual(bodies['untouched/1'], originals['untouched/1'])
        self.assertEqual(sum(bodies[name] != image for name,image in originals.items()), 1)
        self.config.update(operation_mode='recover', acknowledge=True, refresh_error='')
        recovered = self.run_operation()
        self.assertEqual(recovered['error'], '', recovered)
        self.assertEqual(recovered['pending_after_ack'], 0)
        self.assertEqual({name:self.read_shared_image(paths[2],name) for name in originals}, bodies)
        self.config['operation_mode'] = 'apply'
        resumed = self.run_operation()
        self.assertEqual(resumed['error'], '', resumed)
        self.assertEqual(resumed['changed_files'], 1, resumed)
        for name in ('one/1','neighbor/1'):
            self.assertNotEqual(self.read_shared_image(paths[2],name), originals[name])
        self.assertEqual(self.read_shared_image(paths[2],'untouched/1'), originals['untouched/1'])

    def test_png_webp_and_external_jpeg_xl_survive_one_selected_operation(self):
        picture = png(False, random.Random(365).randbytes(128*128))
        output = io.BytesIO()
        Image.frombytes('RGB', (256, 256), random.Random(366).randbytes(256*256*3)).save(output, 'WEBP', quality=75)
        webp = output.getvalue()
        fixtures = Path(__file__).resolve().parents[2]/'tools/ui/tests/fixtures'
        jxl = (fixtures/'reconstruct-encoded.jxl').read_bytes()
        jpeg = (fixtures/'reconstruct-original.jpg').read_bytes()
        original = (b'<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
            b'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'
            b'<book-title>Mixed formats</book-title><coverpage><image l:href="#cover"/>'
            b'</coverpage></title-info></description><body><section><p>Keep this text.</p>'
            b'<image l:href="#embedded"/><image l:href="#embedded-webp"/><image l:href="#1"/><image l:href="#2"/>'
            b'</section></body><binary id="embedded" content-type="image/png">'+
            base64.b64encode(picture)+b'</binary><binary id="embedded-webp" content-type="image/webp">'+
            base64.b64encode(webp)+b'</binary></FictionBook>')
        stage = self.root/'mixed-input'
        stage.mkdir()
        (stage/'one.fb2').write_bytes(original)
        (stage/'neighbor.fb2').write_bytes(self.fixture.neighbor)
        self.fixture.source.unlink()
        self.fixture.source = self.root/'books.7z'
        self.config['selected'][0]['folder'] = 'books.7z'
        with database(self.fixture.catalogue) as db:
            db.execute("UPDATE Books SET Folder='books.7z'")
            db.execute("UPDATE CatalogBookCopies SET Folder='books.7z'")
        with database(self.fixture.personal) as db:
            db.execute("UPDATE Books SET Folder='books.7z' WHERE DatabaseID=7")
        process = run_owned([self.config['seven_zip'],'a','-t7z','-mx=0','-y','--',
            str(self.fixture.source),'one.fb2','neighbor.fb2'],cwd=stage,capture_output=True,timeout=30)
        self.assertEqual(process.returncode,0,process.stderr)
        sides = []
        for kind, entries in [('covers',{'one':jxl,'neighbor':jpeg}),
                               ('images',{'one/1':picture,'one/2':webp,'neighbor/1':webp})]:
            target = self.root/kind/'books.zip'
            target.parent.mkdir()
            with zipfile.ZipFile(target,'x',zipfile.ZIP_STORED) as archive:
                for name,data in entries.items(): archive.writestr(name,data)
            sides.append(target)
        self.config['operation_mode'] = 'book-stream'
        opened = self.run_operation()
        before = self.root/'complete-before.fb2'
        Path(opened['book_stream']).replace(before)
        backups = self.enable_backup()
        self.config.update(operation_mode='trial-apply',estimate_first=True,profile='maximum',grayscale=True)
        physical_before = sum(p.stat().st_size for p in [self.fixture.source,*sides])
        result = self.run_operation()
        self.assertEqual(result['error'],'',result)
        self.assertTrue(result['trial_ready'])
        self.assertEqual(result['trial_shared_files'],0)
        self.assertEqual(result['trial_input_bytes'],physical_before)
        # A rebuilt 7z can encode different file timestamps in its compressed header.
        self.assertLessEqual(abs(result['trial_output_bytes']-
                                 sum(p.stat().st_size for p in [self.fixture.source,*sides])),64)
        self.assertEqual(result['changed_files'],1,result)
        self.assertEqual(result['pending_after_ack'],0,result)
        self.assertEqual(result['saved_bytes'],physical_before-sum(p.stat().st_size for p in [self.fixture.source,*sides]))
        with zipfile.ZipFile(sides[0]) as archive:
            self.assertEqual(archive.read('neighbor'),jpeg)
        with zipfile.ZipFile(sides[1]) as archive:
            self.assertLess(len(archive.read('one/2')),len(webp))
            self.assertEqual(archive.read('neighbor/1'),webp)
            self.assertLess(len(archive.read('one/1')),len(picture))
        saved, = backups.glob('*.zip')
        with zipfile.ZipFile(saved) as backup:
            original_full = self.root/'original.fb2'
            original_full.write_bytes(backup.read('books/one.fb2'))
        verify_non_image_content(before,original_full,'.fb2')
        original_images = {node.attrib['id']:base64.b64decode(node.text)
            for node in ET.parse(original_full).getroot().findall('{http://www.gribuser.ru/xml/fictionbook/2.0}binary')}
        self.assertEqual(original_images['embedded-webp'],webp)
        self.assertEqual(original_images['2'],webp)
        self.config['operation_mode'] = 'book-stream'
        restored = self.run_operation()
        full = Path(restored['book_stream'])
        verify_non_image_content(before,full,'.fb2')
        ns = {'f':'http://www.gribuser.ru/xml/fictionbook/2.0'}
        images = {node.attrib['id']:base64.b64decode(node.text)
                  for node in ET.parse(full).getroot().findall('f:binary',ns)}
        self.assertEqual(set(images),{'cover','embedded','embedded-webp','1','2'})
        self.assertNotEqual(images['embedded'],picture)
        for name in ['cover','embedded','embedded-webp','1','2']:
            with Image.open(io.BytesIO(images[name])) as bitmap:
                red,green,blue = bitmap.convert('RGB').split()
                self.assertIsNone(ImageChops.difference(red,green).getbbox(),name)
                self.assertIsNone(ImageChops.difference(red,blue).getbbox(),name)
        with database(self.fixture.catalogue) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE BookID=101').fetchone()[0],full.stat().st_size)
            self.assertEqual(db.execute('SELECT BookSize FROM CatalogBookCopies').fetchone()[0],full.stat().st_size)
            self.assertEqual(db.execute('SELECT Progress FROM Books WHERE BookID=101').fetchone()[0],37)
        with database(self.fixture.personal) as db:
            self.assertEqual(db.execute('SELECT BookSize FROM Books WHERE DatabaseID=7').fetchone()[0],full.stat().st_size)
        checked = {p:sha(p.read_bytes()) for p in [self.fixture.source,self.fixture.catalogue,self.fixture.personal,*sides]}
        self.config['operation_mode'] = 'apply'
        second = self.run_operation()
        self.assertEqual(second['error'],'',second)
        self.assertEqual(second['changed_files'],0,second)
        self.assertEqual(checked,{p:sha(p.read_bytes()) for p in checked})


for _name in dir(NativeCompressionOperationTests):
    if _name.startswith('test_'):
        setattr(NativeMixedImageTests,_name,None)
del NativeCompressionOperationTests
