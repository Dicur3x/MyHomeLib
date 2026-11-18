"""Actual FLibrary side-archive preparation; no native publication is implied."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from pack_collection import Canceled, PackingError, temporary_work_directory
from supervised_test_process import run_owned
from test_pack_collection import image_fixture

RUNTIME = Path(os.environ['HL_COMPRESSION_RUNTIME']) if os.environ.get('HL_COMPRESSION_RUNTIME') else None
SEVEN = Path(os.environ['HLRU_PACK_7ZIP']) if os.environ.get('HLRU_PACK_7ZIP') else None
DECODER = Path(os.environ['HL_EXTERNAL_IMAGE_DECODER']) if os.environ.get('HL_EXTERNAL_IMAGE_DECODER') else None


def sha(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(RUNTIME and SEVEN and DECODER, 'Private packaged runtime and verified JPEG XL decoder required')
class ExternalImagePreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = RUNTIME / 'tools/bookconvert/external_image_preparation.py'
        assert path.read_bytes() == Path(__file__).with_name(path.name).read_bytes()
        spec = importlib.util.spec_from_file_location('homelibre_external_under_test', path)
        cls.module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.module
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temp = temporary_work_directory(tempfile.gettempdir(), 'HomeLibre-external-images-')
        self.root = self.temp.__enter__()
        self.input = self.root / 'source'
        self.input.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        fixtures = Path(__file__).resolve().parents[2] / 'tools/ui/tests/fixtures'
        self.jxl = (fixtures / 'reconstruct-encoded.jxl').read_bytes()
        self.jpeg = (fixtures / 'reconstruct-original.jpg').read_bytes()
        self.png = image_fixture()
        self.books = {'one.fb2': b'<FictionBook/>', 'two.epub': b'opaque EPUB fixture', 'neighbor.fb2': b'Keep neighbor text'}
        self.source = self.input / 'primary.7z'
        self.archive(self.source, self.books, '7z')
        self.cover = self.input / 'covers/primary.zip'
        self.pictures = self.input / 'images/primary.7z'
        self.cover_entries = {'one': self.jxl, 'two': self.png, 'neighbor': self.jpeg}
        self.picture_entries = {'one/1': self.png, 'one/2': self.png, 'two/1': self.png,
                                'neighbor/1': self.png, 'readme.txt': b'Keep the archive note'}
        self.archive(self.cover, self.cover_entries, 'zip')
        self.archive(self.pictures, self.picture_entries, '7z')
        self.before = self.snapshot()

    def tearDown(self):
        self.temp.__exit__(None, None, None)

    def archive(self, path, entries, kind):
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == 'zip':
            with zipfile.ZipFile(path, 'x', zipfile.ZIP_STORED) as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
                archive.comment = b'Keep this image archive comment'
        else:
            stage = self.root / ('build-' + str(len(list(self.root.glob('build-*')))))
            stage.mkdir()
            for name, data in entries.items():
                target = stage / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            process = run_owned([str(SEVEN), 'a', '-t7z', '-mx=0', '-ms=off', '-y', '--',
                str(path), *entries], cwd=stage, capture_output=True, timeout=30)
            self.assertEqual(process.returncode, 0, process.stderr)

    def snapshot(self):
        return {p.relative_to(self.input).as_posix(): sha(p.read_bytes()) for p in self.input.rglob('*') if p.is_file()}

    def read(self, path, member):
        process = run_owned([str(SEVEN), 'x', '-so', '-spd', '-ssc', '-y', '--', str(path), member],
                            capture_output=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        return process.stdout

    def prepare(self, **options):
        return self.module.prepare_external_images(self.source, {'one.fb2': '.fb2'}, self.work, SEVEN,
            tools_root=RUNTIME / 'tools', jpeg_xl_decoder=options.pop('jpeg_xl_decoder', DECODER), **options)

    def test_maximum_batches_selected_images_keeps_neighbors_and_decodes_jpeg_xl(self):
        batches = []
        popen = subprocess.Popen
        def observed(arguments, *args, **kwargs):
            if len(arguments) > 2 and arguments[1] == '--export-images':
                with zipfile.ZipFile(arguments[2]) as images:
                    batches.append(len(images.namelist()))
            return popen(arguments, *args, **kwargs)
        with patch('subprocess.Popen', observed):
            result = self.prepare(profile='maximum')
        self.assertEqual(self.snapshot(), self.before)
        groups = {item['kind']: item for item in result.archives}
        self.assertEqual(set(groups), {'covers', 'images'})
        pictures = groups['images']
        self.assertIsNotNone(pictures['candidate'])
        self.assertLess(pictures['output_bytes'], pictures['input_bytes'])
        self.assertTrue(Path(pictures['candidate']).read_bytes().startswith(b"7z\xbc\xaf'\x1c"))
        self.assertEqual(self.read(pictures['candidate'], 'neighbor/1'), self.png)
        self.assertEqual(self.read(pictures['candidate'], 'two/1'), self.png)
        self.assertEqual(self.read(pictures['candidate'], 'readme.txt'), self.picture_entries['readme.txt'])
        self.assertNotEqual(self.read(pictures['candidate'], 'one/1'), self.png)
        self.assertEqual({row['member'] for row in pictures['images']}, {'one/1', 'one/2'})
        self.assertEqual(groups['covers']['images'][0]['decoded_sha256'], sha(self.jpeg))
        cover = groups['covers']
        actual = self.read(cover['candidate'], 'one') if cover['candidate'] else self.jxl
        self.assertEqual(cover['images'][0]['output_sha256'], sha(actual))
        self.assertLessEqual(len(actual), len(self.jxl))
        self.assertIn(2, batches)
        self.assertTrue(all(1 <= count <= 9 for count in batches))

    def test_reversible_mode_needs_no_image_processor_or_decoder(self):
        result = self.module.prepare_external_images(self.source, {'one.fb2': '.fb2'}, self.work, SEVEN,
                                                     profile='original', tools_root=self.root / 'missing-tools')
        self.assertEqual(self.snapshot(), self.before)
        for group in result.archives:
            self.assertLessEqual(group['output_bytes'], group['input_bytes'])
            for image in group['images']:
                self.assertEqual(image['output_sha256'], image['input_sha256'])
                self.assertFalse(image['changed'])
            if group['candidate']:
                expected = self.cover_entries if group['kind'] == 'covers' else self.picture_entries
                for name, body in expected.items():
                    self.assertEqual(self.read(group['candidate'], name), body)

    def test_embedded_python_prepares_images_with_matching_native_codecs(self):
        process, report = self.run_worker(profile='maximum', grayscale=True)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        result = json.loads(report.read_text(encoding='utf-8'))
        self.assertEqual(result['kind'], 'HomeLibre external image preparation')
        self.assertNotIn('receipt', result)
        self.assertEqual(result['members'], {'one.fb2': '.fb2'})
        self.assertEqual(result['original_image_sources'], [str(self.cover), str(self.pictures)])
        prepared_paths = {item['kind']: item['candidate'] or item['source'] for item in result['archives']}
        self.assertEqual(result['prepared_image_sources'], [prepared_paths['covers'], prepared_paths['images']])
        self.assertEqual(self.snapshot(), self.before)
        pictures = next(row for row in result['archives'] if row['kind'] == 'images')
        self.assertIsNotNone(pictures['candidate'])
        self.assertLess(pictures['output_bytes'], pictures['input_bytes'])
        self.assertEqual(self.read(pictures['candidate'], 'neighbor/1'), self.png)
        self.assertNotEqual(self.read(pictures['candidate'], 'one/1'), self.png)
        self.assertTrue(all(item['checked'] and item['changed'] for item in pictures['images']))
        for group in result['archives']:
            if group['candidate']:
                self.assertEqual(sha(Path(group['candidate']).read_bytes()), group['result_sha256'])
        evidence = os.environ.get('HL_EXTERNAL_IMAGE_EVIDENCE')
        if evidence:
            summary = dict(status='PASS', scope='Embedded Python external-image preparation; no native publication',
                source_unchanged=True, jpeg_xl_sha256=sha(self.jxl), archives=[
                    {key: group[key] for key in ('kind', 'input_bytes', 'output_bytes', 'source_sha256', 'result_sha256')}
                    for group in result['archives']])
            with Path(evidence).open('x', encoding='utf-8') as stream:
                json.dump(summary, stream, indent=2)

    def run_worker(self, cancel=False, **options):
        request, report = self.root / 'request.json', self.root / 'embedded-result.json'
        value = dict(version=1, kind='HomeLibre external image preparation', source=str(self.source),
            members={'one.fb2': '.fb2'}, workspace=str(self.work), seven_zip=str(SEVEN), report=str(report),
            profile='original', tools_root=str(RUNTIME / 'tools'), jpeg_xl_decoder=str(DECODER))
        value.update(options)
        request.write_text(json.dumps(value), encoding='utf-8')
        arguments = [str(RUNTIME / 'tools/python/python.exe'), '-I', '-B', '-X', 'utf8',
                     str(RUNTIME / 'tools/bookconvert/external_image_preparation.py'), '--job', str(request)]
        if cancel:
            marker = self.root / 'cancel'
            marker.touch()
            arguments.extend(['--cancel', str(marker)])
        return run_owned(arguments, capture_output=True, timeout=45), report

    def test_worker_reports_required_decoder_and_removes_candidates(self):
        process, report = self.run_worker(profile='maximum', jpeg_xl_decoder=None)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        event = json.loads(process.stdout.decode('utf-8').splitlines()[-1])
        self.assertEqual(event['component'], 'JPEGXL')
        self.assertFalse(report.exists())
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(self.snapshot(), self.before)

    def test_worker_cancel_and_unsupported_request_leave_sources_exact(self):
        process, report = self.run_worker(cancel=True)
        self.assertEqual(process.returncode, 2, process.stdout + process.stderr)
        self.assertEqual(json.loads(process.stdout.decode('utf-8'))['stage'], 'cancelled')
        self.assertFalse(report.exists())
        process, report = self.run_worker(version=2)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertFalse(report.exists())
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(self.snapshot(), self.before)

    def test_worker_report_collision_removes_prepared_candidates(self):
        report = self.root / 'embedded-result.json'
        report.write_bytes(b'keep prior evidence')
        process, _ = self.run_worker()
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertEqual(report.read_bytes(), b'keep prior evidence')
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(self.snapshot(), self.before)

    def test_grayscale_outputs_have_equal_channels_and_leave_sources_exact(self):
        from PIL import Image, ImageChops
        result = self.prepare(profile='maximum', grayscale=True)
        pictures = next(row for row in result.archives if row['kind'] == 'images')
        self.assertIsNotNone(pictures['candidate'])
        with Image.open(io.BytesIO(self.read(pictures['candidate'], 'one/1'))) as bitmap:
            red, green, blue = bitmap.convert('RGB').split()
            self.assertIsNone(ImageChops.difference(red, green).getbbox())
            self.assertIsNone(ImageChops.difference(red, blue).getbbox())
        self.assertEqual(self.snapshot(), self.before)

    def test_raw_jpeg_xl_falls_back_to_png_and_preserves_transparency(self):
        from PIL import Image
        raw = (Path(__file__).resolve().parents[2] / 'tools/ui/tests/fixtures/transparent-ink.jxl').read_bytes()
        self.cover.unlink()
        self.archive(self.cover, dict(self.cover_entries, one=raw), 'zip')
        before, decoded = self.snapshot(), []
        decode = self.module._decode_jpeg_xl
        def observed(*args, **kwargs):
            data = decode(*args, **kwargs)
            decoded.append(data)
            return data
        with patch.object(self.module, '_decode_jpeg_xl', observed):
            result = self.prepare(profile='maximum')
        self.assertEqual(len(decoded), 1)
        self.assertTrue(decoded[0].startswith(b'\x89PNG\r\n\x1a\n'))
        cover = next(group for group in result.archives if group['kind'] == 'covers')
        actual = self.read(cover['candidate'], 'one') if cover['candidate'] else raw
        if actual.startswith(b'\x89PNG\r\n\x1a\n'):
            rendered = actual
        else:
            self.assertEqual(actual, raw)
            rendered = decoded[0]
        with Image.open(io.BytesIO(rendered)) as bitmap:
            rgba = bitmap.convert('RGBA')
            self.assertEqual(rgba.size, (354, 378))
            self.assertEqual(rgba.getpixel((0, 0))[3], 0)
            self.assertEqual(rgba.getpixel((187, 0))[3], 255)
        self.assertEqual(self.snapshot(), before)

    def test_webp_color_no_gain_and_grayscale_transparency_use_the_embedded_runtime(self):
        from PIL import Image, ImageChops
        import random
        for gray in (False, True):
            stream = io.BytesIO()
            if gray:
                bitmap = Image.frombytes('RGBA', (256,256), random.Random(369).randbytes(256*256*4))
                bitmap.putalpha(Image.new('L',(256,256),255))
                for y in range(32):
                    for x in range(32): bitmap.putpixel((x,y),(0,0,0,0))
                bitmap.save(stream,'WEBP',lossless=True)
            else:
                Image.new('RGB',(4,4),(220,60,20)).save(stream,'WEBP',quality=40)
            original = stream.getvalue()
            self.pictures.unlink()
            self.archive(self.pictures, dict(self.picture_entries, **{'one/1':original}), '7z')
            before = self.snapshot()
            self.work = self.root/('webp-'+str(gray))
            self.work.mkdir()
            process, report = self.run_worker(profile='maximum',grayscale=gray)
            self.assertEqual(process.returncode,0,process.stdout+process.stderr)
            result = json.loads(report.read_text(encoding='utf-8'))
            report.unlink()
            group = next(row for row in result['archives'] if row['kind']=='images')
            record = next(row for row in group['images'] if row['member']=='one/1')
            self.assertTrue(record['checked'],record)
            actual = self.read(group['candidate'] or self.pictures,'one/1')
            if gray:
                self.assertLess(len(actual),len(original))
                with Image.open(io.BytesIO(actual)) as rendered:
                    rgba = rendered.convert('RGBA')
                    red,green,blue,_ = rgba.split()
                    self.assertIsNone(ImageChops.difference(red,green).getbbox())
                    self.assertIsNone(ImageChops.difference(red,blue).getbbox())
                    self.assertEqual(rgba.getpixel((0,0))[3],0)
                    self.assertEqual(rgba.getpixel((200,200))[3],255)
            else:
                self.assertEqual(actual,original)
            self.assertEqual(self.snapshot(),before)

    def test_animated_webp_is_retained_with_a_reason_instead_of_losing_frames(self):
        from PIL import Image
        stream = io.BytesIO()
        Image.new('RGB',(64,64),'red').save(stream,'WEBP',save_all=True,
            append_images=[Image.new('RGB',(64,64),'blue')],duration=100,loop=0)
        original = stream.getvalue()
        self.pictures.unlink()
        self.archive(self.pictures,dict(self.picture_entries,**{'one/1':original}),'7z')
        before = self.snapshot()
        process, report = self.run_worker(profile='maximum',grayscale=True)
        self.assertEqual(process.returncode,0,process.stdout+process.stderr)
        result = json.loads(report.read_text(encoding='utf-8'))
        group = next(row for row in result['archives'] if row['kind']=='images')
        record = next(row for row in group['images'] if row['member']=='one/1')
        self.assertFalse(record['checked'],record)
        self.assertIn('кадры',record['reason'])
        self.assertEqual(self.read(group['candidate'] or self.pictures,'one/1'),original)
        self.assertEqual(self.snapshot(),before)

    def test_balanced_economy_and_original_grayscale_produce_checked_candidates(self):
        for index, (profile, gray) in enumerate((('balanced', False), ('economy', False), ('original', True))):
            with self.subTest(profile=profile, grayscale=gray):
                self.work = self.root / ('profile-' + str(index))
                self.work.mkdir()
                result = self.prepare(profile=profile, grayscale=gray)
                pictures = next(row for row in result.archives if row['kind'] == 'images')
                self.assertIsNotNone(pictures['candidate'])
                self.assertTrue(all(row['checked'] and row['changed'] for row in pictures['images']))
                self.assertLess(pictures['output_bytes'], pictures['input_bytes'])
                self.assertEqual(self.snapshot(), self.before)

    def test_leading_dot_container_matches_delphi_sibling_basename(self):
        renamed = self.input / '.archive'
        self.source.rename(renamed)
        self.source = renamed
        self.cover.rename(self.input / 'covers/.zip')
        self.pictures.rename(self.input / 'images/.7z')
        before = self.snapshot()
        result = self.prepare(profile='original')
        self.assertEqual({Path(row['path']).name for row in result.dependencies}, {'.zip', '.7z'})
        self.assertEqual({row['kind'] for row in result.archives}, {'covers', 'images'})
        self.assertEqual(self.snapshot(), before)

    def test_long_unicode_workspace_processes_images_and_jpeg_xl(self):
        self.work = self.root / 'Рабочая папка ё'
        while len(str(self.work / '.external-images-01234567/images/encoding-0/images.zip')) <= 300:
            self.work /= 'Вложенная рабочая папка ё'
        self.work.mkdir(parents=True)
        result = self.prepare(profile='maximum')
        self.assertTrue(any(row['candidate'] for row in result.archives))
        self.assertEqual(self.snapshot(), self.before)

    def test_seven_zip_named_zip_still_activates_flibrary_side_archives(self):
        target = self.input / 'primary.zip'
        self.source.rename(target)
        self.source = target
        before = self.snapshot()
        result = self.prepare(profile='original')
        self.assertTrue(result.supported)
        self.assertEqual({row['kind'] for row in result.archives}, {'covers', 'images'})
        self.assertEqual(self.snapshot(), before)

    def test_preferred_zip_keeps_an_invalid_inactive_7z_opaque(self):
        fallback = self.input / 'covers/primary.7z'
        fallback.write_bytes(b'Inactive and intentionally invalid archive')
        before = self.snapshot()
        result = self.prepare(profile='original')
        self.assertEqual(next(row['path'] for row in result.dependencies if row['kind'] == 'covers'), str(self.cover))
        self.assertEqual(self.snapshot(), before)

    def test_hardlinked_side_archive_requires_a_shared_usage_plan(self):
        os.link(self.cover, self.root / 'shared-cover.zip')
        with self.assertRaisesRegex(PackingError, 'жёстких ссылок'):
            self.prepare(profile='original')
        self.assertEqual(self.snapshot(), self.before)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_prior_image_hash_is_retained_without_decoding_or_reencoding(self):
        result = self.prepare(profile='maximum', preserve_image=lambda digest: digest == sha(self.png))
        self.assertEqual(self.snapshot(), self.before)
        images = next(row for row in result.archives if row['kind'] == 'images')['images']
        self.assertTrue(all(item['reused'] and not item['changed'] for item in images))

    def test_replaced_picture_at_same_member_path_is_processed_again(self):
        first = self.prepare(profile='maximum')
        archive = next(item for item in first.archives if item['kind'] == 'images')
        self.assertTrue(all(item['changed'] for item in archive['images']))
        history = {item['output_sha256'] for item in archive['images']}
        retained = self.read(archive['candidate'], 'one/2')
        # The next delivery replaces one illustration with the original PNG.
        # Its sibling and all book and illustration names stay the same.
        self.pictures.unlink()
        self.archive(self.pictures, {**self.picture_entries, 'one/2': retained}, '7z')
        before = self.snapshot()
        self.work = self.root / 'second-pass'
        self.work.mkdir()
        second = self.prepare(profile='maximum', preserve_image=history.__contains__)
        archive = next(item for item in second.archives if item['kind'] == 'images')
        images = {item['member']: item for item in archive['images']}
        self.assertEqual(images['one/1']['input_sha256'], sha(self.png))
        self.assertFalse(images['one/1']['reused'])
        self.assertTrue(images['one/1']['changed'])
        self.assertTrue(images['one/2']['reused'])
        self.assertFalse(images['one/2']['changed'])
        self.assertEqual(self.read(archive['candidate'], 'one/2'), retained)
        self.assertEqual(self.snapshot(), before)

    def test_missing_jpeg_xl_decoder_cleans_preparation_without_changing_sources(self):
        with self.assertRaises(self.module.ImageComponentRequired) as error:
            self.prepare(profile='maximum', jpeg_xl_decoder=None)
        self.assertEqual(error.exception.component, 'JPEGXL')
        self.assertEqual(self.snapshot(), self.before)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_shared_basename_is_blocked_until_all_referring_members_are_selected(self):
        self.source.unlink()
        self.archive(self.source, dict(self.books, **{'other/one.epub': b'Unselected same image identity'}), '7z')
        self.before = self.snapshot()
        result = self.prepare(profile='original')
        self.assertEqual(result.blocked_members, ['one.fb2'])
        self.assertEqual(result.archives, [])
        self.assertEqual(self.snapshot(), self.before)

    def test_sibling_collision_keeps_shared_cover_and_images_and_processes_unique_book(self):
        peer = self.source.with_suffix('.zip')
        self.archive(peer, {'other/ONE.epub': b'Another book using the same image names'}, '7z')
        before = self.snapshot()
        result = self.module.prepare_external_images(self.source, {'one.fb2':'.fb2', 'two.epub':'.epub'},
            self.work, SEVEN, profile='maximum', grayscale=True, tools_root=RUNTIME/'tools', jpeg_xl_decoder=DECODER)
        self.assertEqual(result.shared_with_other_archives, ['one.fb2'])
        self.assertEqual(result.blocked_members, ['one.fb2'])
        self.assertEqual([Path(item['path']) for item in result.peer_sources], [peer])
        cases = {item['kind']:item for item in result.archives}
        for kind, protected, eligible, original in (('covers','one','two',self.jxl),
                                                    ('images','one/1','two/1',self.png)):
            self.assertTrue(cases[kind]['candidate'])
            self.assertEqual(self.read(cases[kind]['candidate'], protected), original)
            self.assertNotEqual(self.read(cases[kind]['candidate'], eligible), self.png)
        self.assertEqual(before, self.snapshot())

    def test_cancellation_after_preparing_one_archive_removes_its_candidate(self):
        stopped = False
        def notify(event):
            nonlocal stopped
            if event.get('stage') == 'external-archive-prepared':
                stopped = True
        with self.assertRaises(Canceled):
            self.prepare(profile='original', notify=notify, canceled=lambda: stopped)
        self.assertEqual(self.snapshot(), self.before)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_same_size_and_timestamp_side_archive_change_is_detected(self):
        injected = False
        def notify(event):
            nonlocal injected
            if event.get('stage') == 'external-archive-prepared' and event.get('kind') == 'images':
                stamp = self.cover.stat()
                data = bytearray(self.cover.read_bytes())
                data[-1] ^= 1
                self.cover.write_bytes(data)
                os.utime(self.cover, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                injected = True
        with self.assertRaisesRegex(PackingError, 'изменились'):
            self.prepare(profile='original', notify=notify)
        self.assertTrue(injected)
        expected = dict(self.before, **{'covers/primary.zip': sha(self.cover.read_bytes())})
        self.assertEqual(self.snapshot(), expected)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_arriving_preferred_zip_invalidates_a_prepared_7z_dependency(self):
        def notify(event):
            if event.get('stage') == 'external-archive-prepared' and event.get('kind') == 'images':
                self.archive(self.input / 'images/primary.zip', self.picture_entries, 'zip')
        with self.assertRaisesRegex(PackingError, 'изменились'):
            self.prepare(profile='original', notify=notify)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual({key: self.snapshot()[key] for key in self.before}, self.before)

    def test_regular_outer_zip_does_not_activate_flibrary_side_archives(self):
        source = self.input / 'ordinary.zip'
        self.archive(source, self.books, 'zip')
        self.archive(self.input / 'covers/ordinary.zip', {'one': self.png}, 'zip')
        before = self.snapshot()
        result = self.module.prepare_external_images(source, {'one.fb2': '.fb2'}, self.work, SEVEN)
        self.assertFalse(result.supported)
        self.assertEqual(result.archives, [])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(list(self.work.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
