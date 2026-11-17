"""GIF export boundaries and optional real Windows first-frame decoding."""

import base64
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import convert_book as api
import gif_static
from kfx_image_input import remap_srcset


GIF = base64.b64decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==')


class GifStaticBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='homelibre-gif-test-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.tool = self.work / 'images.exe'
        self.tool.write_bytes(b'not executed: mocked helper')
        self.tool.with_name('RUNTIME.json').write_text(json.dumps({'gif_static_api': 1}), encoding='utf-8')
        self.path = mock.patch.object(api, 'image_processor_path', return_value=self.tool)
        self.path.start()
        self.addCleanup(self.path.stop)

    def run_frame(self, result=PNG, check=None):
        def run(_api, command, work, callback, timeout):
            self.assertIs(_api, api)
            self.assertEqual(command[1], '--gif-first-frame')
            self.assertEqual(Path(command[2]).read_bytes(), GIF)
            self.assertEqual(Path(command[3]).parent, work)
            self.assertTrue(work.is_relative_to(self.work))
            self.assertEqual(timeout, 30)
            self.assertIs(callback, check)
            if result is not None:
                Path(command[3]).write_bytes(result)
        with mock.patch.object(gif_static, 'run_writer', side_effect=run):
            return gif_static.first_frame(api, GIF, self.work, self.work, check)

    def test_private_first_frame_and_cleanup(self):
        self.assertEqual(self.run_frame(), PNG)
        self.assertFalse(list(self.work.glob('homelibre-gif-static-*')))

    def test_invalid_header_and_canvas_do_not_launch_decoder(self):
        invalid = [b'GIF', b'PNG' + GIF, GIF[:6] + b'\0\0' + GIF[8:],
                   GIF[:6] + struct.pack('<HH', 16384, 16384) + GIF[10:]]
        with mock.patch.object(gif_static, 'run_writer') as run:
            for data in invalid:
                with self.subTest(data=data[:12]), self.assertRaises(api.ConversionError):
                    gif_static.first_frame(api, data, self.work, self.work)
            run.assert_not_called()

    def test_missing_module_has_component_request(self):
        self.tool.unlink()
        with self.assertRaises(api.ComponentRequired):
            gif_static.first_frame(api, GIF, self.work, self.work)

    def test_old_or_invalid_module_requests_update_before_execution(self):
        for info in ['{}', 'invalid JSON', '[]']:
            self.tool.with_name('RUNTIME.json').write_text(info, encoding='utf-8')
            with self.subTest(info=info), mock.patch.object(gif_static, 'run_writer') as run, self.assertRaises(api.ComponentRequired):
                gif_static.first_frame(api, GIF, self.work, self.work)
            run.assert_not_called()

    def test_missing_invalid_or_resized_result_is_rejected_and_cleaned(self):
        for value in [None, b'not PNG' * 8, PNG[:16] + struct.pack('>II', 2, 1) + PNG[24:]]:
            with self.subTest(value=value), self.assertRaises(api.ConversionError):
                self.run_frame(value)
            self.assertFalse(list(self.work.glob('homelibre-gif-static-*')))

    def test_cancellation_before_decoder(self):
        def cancel():
            raise RuntimeError('cancelled')
        with mock.patch.object(gif_static, 'run_writer') as run, self.assertRaisesRegex(RuntimeError, 'cancelled'):
            gif_static.first_frame(api, GIF, self.work, self.work, cancel)
        run.assert_not_called()
        self.assertFalse(list(self.work.glob('homelibre-gif-static-*')))

    def test_cancellation_after_decoder_cleans_private_files(self):
        checkpoints = []
        def check():
            checkpoints.append(1)
            if len(checkpoints) == 2:
                raise RuntimeError('cancelled after decode')
        with self.assertRaisesRegex(RuntimeError, 'cancelled after decode'):
            self.run_frame(check=check)
        self.assertFalse(list(self.work.glob('homelibre-gif-static-*')))


class GifSrcsetRewrite(unittest.TestCase):
    def test_descriptors_data_url_commas_and_original_spacing(self):
        mappings = {'picture.gif': 'first.png', 'large.gif': 'second.png'}
        cases = [
            ('picture.gif', 'first.png'),
            ('picture.gif 1x, large.gif 2x', 'first.png 1x, second.png 2x'),
            ('picture.gif,\n\tlarge.gif,', 'first.png,\n\tsecond.png,'),
            ('data:image/png;base64,AAAA 1x, picture.gif 2x', 'data:image/png;base64,AAAA 1x, first.png 2x'),
            ('https://example.org/a,b.gif 1x, large.gif 2x', 'https://example.org/a,b.gif 1x, second.png 2x'),
            ('  ,,picture.gif 400w, large.gif 800w  ', '  ,,first.png 400w, second.png 800w  '),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(remap_srcset(value, lambda url: mappings.get(url, url)), expected)

    def test_inline_gif_candidate_is_rewritten_as_one_url(self):
        uri = 'data:image/gif;base64,' + base64.b64encode(GIF).decode('ascii')
        calls = []
        def resolve(value):
            calls.append(value)
            return 'first.png' if value == uri else value
        self.assertEqual(remap_srcset(uri + ' 1x, original.png 2x', resolve), 'first.png 1x, original.png 2x')
        self.assertEqual(calls, [uri, 'original.png'])

    def test_empty_and_unchanged_sources_are_retained(self):
        for value in ['', ' , , ', 'image%20name.png 2x', 'data:image/png;base64,AAAA,BBBB 1x']:
            with self.subTest(value=value):
                self.assertEqual(remap_srcset(value, lambda url: url), value)


class GifStaticExportPolicy(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='homelibre-gif-policy-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def fb2(self):
        from test_advanced_output import FB2
        source = self.work / 'source.fb2'
        source.write_text(FB2.format(image=base64.b64encode(GIF).decode('ascii')).replace('image/png', 'image/gif'), encoding='utf-8')
        return source

    def epub(self, signed=False):
        source = self.work / 'source.epub'
        package = '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">fixture</dc:identifier>
          <dc:title>GIF export</dc:title><dc:language>en</dc:language><meta property="rendition:layout">pre-paginated</meta></metadata>
          <manifest><item id="chapter" href="text/one.xhtml" media-type="application/xhtml+xml" properties="svg"/>
          <item id="pic" href="images/picture.gif" media-type="image/gif"/><item id="style" href="style.css" media-type="text/css"/></manifest>
          <spine><itemref idref="chapter"/></spine></package>'''
        chapter = '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>GIF</title></head><body>
          <p id="before">Before <a href="#before"><img src="../images/picture.gif"
            srcset="data:image/png;base64,AAAA 1x, ../images/picture.gif 2x" alt="Illustration"/></a> after.</p>
          <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1" height="1">
            <image xlink:href="../images/picture.gif" width="1" height="1"/></svg>
          <p style="background-image: url('../images/picture.gif')">Caption</p><script>unchanged()</script>
          </body></html>'''
        with zipfile.ZipFile(source, 'x') as z:
            z.writestr('mimetype', 'application/epub+zip')
            z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
            z.writestr('OPS/book.opf', package)
            z.writestr('OPS/text/one.xhtml', chapter)
            z.writestr('OPS/images/picture.gif', GIF)
            z.writestr('OPS/style.css', 'p {background: url("images/picture.gif")}')
            if signed:
                z.writestr('META-INF/signatures.xml', '<signatures/>')
        return source

    def test_normal_conversion_is_static_but_original_and_reading_are_preserved(self):
        source = self.fb2()
        original = source.read_bytes()
        converted = self.work / 'converted.epub'
        with mock.patch.object(gif_static, 'first_frame', return_value=PNG) as decode:
            result = api.convert_book(source, converted)
            self.assertEqual(decode.call_count, 1)
            reading = self.work / 'reading.epub'
            api.convert_book(source, reading, reading=True)
            original_copy = self.work / 'original.fb2'
            api.convert_book(source, original_copy)
            self.assertEqual(decode.call_count, 1)
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(original_copy.read_bytes(), original)
        self.assertIn(gif_static.WARNING, result['warnings'])
        with zipfile.ZipFile(converted) as z:
            self.assertFalse(any(z.read(n).startswith((b'GIF87a', b'GIF89a')) for n in z.namelist()))
            self.assertTrue(any(z.read(n) == PNG for n in z.namelist()))
        with zipfile.ZipFile(reading) as z:
            self.assertTrue(any(z.read(n) == GIF for n in z.namelist()))

    def test_fb2_binary_id_text_and_references_are_retained(self):
        source = self.fb2()
        before = api.xml(source.read_bytes())
        text = [api.plain(n) for n in before if api.tag(n) != 'binary']
        warnings = set()
        with mock.patch.object(gif_static, 'first_frame', return_value=PNG):
            self.assertEqual(gif_static.normalize_export(api, source, '.fb2', self.work, warnings), 1)
        after = api.xml(source.read_bytes())
        self.assertEqual([api.plain(n) for n in after if api.tag(n) != 'binary'], text)
        binary = next(n for n in after if api.tag(n) == 'binary')
        self.assertEqual(binary.get('id'), 'pixel')
        self.assertEqual(binary.get('content-type'), 'image/png')
        self.assertEqual(base64.b64decode(binary.text), PNG)
        self.assertTrue(any(n.get('{' + api.XL + '}href') == '#pixel' for n in after.iter()))

    def test_gif_only_epub_rewrites_references_and_preserves_svg_and_scripts(self):
        source = self.epub()
        warnings = set()
        with mock.patch.object(gif_static, 'first_frame', return_value=PNG):
            self.assertEqual(gif_static.normalize_export(api, source, '.epub', self.work, warnings), 1)
        with zipfile.ZipFile(source) as z:
            self.assertNotIn('OPS/images/picture.gif', z.namelist())
            package = api.xml(z.read('OPS/book.opf'))
            image = next(n for n in package.iter() if n.get('id') == 'pic')
            new_path = image.get('href')
            self.assertEqual(z.read('OPS/' + new_path), PNG)
            self.assertEqual(image.get('media-type'), 'image/png')
            self.assertEqual(next(n for n in package.iter() if n.get('id') == 'chapter').get('properties'), 'svg')
            chapter = api.xhtml(z.read('OPS/text/one.xhtml'))
            img = next(n for n in chapter.iter() if api.tag(n) == 'img')
            self.assertEqual(img.get('src'), '../' + new_path)
            self.assertEqual(img.get('srcset'), 'data:image/png;base64,AAAA 1x, ../' + new_path + ' 2x')
            svg_image = next(n for n in chapter.iter() if n.tag == '{http://www.w3.org/2000/svg}image')
            self.assertEqual(svg_image.get('{' + api.XL + '}href'), '../' + new_path)
            self.assertIn(new_path, z.read('OPS/style.css').decode())
            self.assertEqual(next(n for n in chapter.iter() if api.tag(n) == 'script').text, 'unchanged()')

    def test_signature_prevents_partial_replacement(self):
        source = self.epub(signed=True)
        original = source.read_bytes()
        with mock.patch.object(gif_static, 'first_frame') as decode, self.assertRaisesRegex(api.ConversionError, 'подпись'):
            gif_static.normalize_export(api, source, '.epub', self.work, set())
        decode.assert_not_called()
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse(list(self.work.glob('homelibre-gif-export-*')))

    def test_inline_gifs_in_html_svg_and_css_share_one_static_resource(self):
        template = self.epub()
        with zipfile.ZipFile(template) as z:
            entries = {name: z.read(name) for name in z.namelist()}
        entries.pop('OPS/images/picture.gif')
        package = api.xml(entries['OPS/book.opf'])
        manifest = api.first(package, 'manifest')
        manifest.remove(next(item for item in manifest if item.get('id') == 'pic'))
        entries['OPS/book.opf'] = api.serialized(package)
        uri = b'data:image/gif;base64,' + base64.b64encode(GIF)
        entries['OPS/text/one.xhtml'] = entries['OPS/text/one.xhtml'].replace(b'../images/picture.gif', uri)
        entries['OPS/style.css'] = entries['OPS/style.css'].replace(b'images/picture.gif', uri)
        source = self.work / 'inline.epub'
        with zipfile.ZipFile(source, 'x') as z:
            for name, data in entries.items():
                z.writestr(name, data)
        with mock.patch.object(gif_static, 'first_frame', return_value=PNG) as decode:
            self.assertEqual(gif_static.normalize_export(api, source, '.epub', self.work, set()), 1)
        self.assertEqual(decode.call_count, 1)
        with zipfile.ZipFile(source) as z:
            pngs = [name for name in z.namelist() if z.read(name) == PNG]
            self.assertEqual(len(pngs), 1)
            self.assertFalse(any(b'data:image/gif' in z.read(name) for name in z.namelist()))
            chapter = api.xhtml(z.read('OPS/text/one.xhtml'))
            self.assertEqual(next(n for n in chapter.iter() if api.tag(n) == 'img').get('src'), '../' + pngs[0].removeprefix('OPS/'))

    def test_epub_without_gifs_is_a_byte_exact_noop(self):
        template = self.epub()
        source = self.work / 'png.epub'
        with zipfile.ZipFile(template) as original, zipfile.ZipFile(source, 'x') as z:
            for entry in original.infolist():
                data = original.read(entry)
                if entry.filename == 'OPS/images/picture.gif':
                    data = PNG
                elif entry.filename == 'OPS/book.opf':
                    data = data.replace(b'image/gif', b'image/png')
                z.writestr(entry, data)
        before = source.read_bytes()
        with mock.patch.object(gif_static, 'first_frame') as decode:
            self.assertEqual(gif_static.normalize_export(api, source, '.epub', self.work, set()), 0)
        decode.assert_not_called()
        self.assertEqual(source.read_bytes(), before)

    def test_cancellation_keeps_the_private_fb2_unchanged(self):
        source = self.fb2()
        original = source.read_bytes()
        with mock.patch.object(gif_static, 'first_frame', side_effect=RuntimeError('cancelled')), self.assertRaisesRegex(RuntimeError, 'cancelled'):
            gif_static.normalize_export(api, source, '.fb2', self.work, set())
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse(list(self.work.glob('homelibre-gif-export-*')))

    def test_multiple_package_documents_survive_a_real_zip_rewrite(self):
        from test_gif_package_model import GifPackageModel
        model = GifPackageModel()
        for inline in (False, True):
            with self.subTest(inline=inline):
                files, roots = model.book(inline=inline)
                source = self.work / ('source-multiple-' + str(inline) + '.epub')
                private = self.work / ('private-multiple-' + str(inline) + '.epub')
                with zipfile.ZipFile(source, 'x') as z:
                    for name, data in files.items():
                        z.writestr(name, data)
                original = source.read_bytes()
                private.write_bytes(original)
                with mock.patch.object(gif_static, 'first_frame', return_value=PNG):
                    self.assertEqual(gif_static.normalize_export(api, private, '.epub', self.work, set()), 1)
                self.assertEqual(source.read_bytes(), original)
                with zipfile.ZipFile(private) as z:
                    self.assertIsNone(z.testzip())
                    result = {name: z.read(name) for name in z.namelist()}
                model.assert_renditions(result, roots, preserve_ids=not inline)


@unittest.skipUnless(os.environ.get('HOMELIB_TEST_TOOLS'), 'Explicit current Windows image runtime required')
class NativeGifFirstFrame(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='homelibre-gif-native-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.tools = Path(os.environ['HOMELIB_TEST_TOOLS'])

    def verify(self, data):
        from PIL import Image
        expected = Image.open(io.BytesIO(data)).convert('RGBA')
        actual = Image.open(io.BytesIO(gif_static.first_frame(api, data, self.tools, self.work))).convert('RGBA')
        self.assertEqual(actual.size, expected.size)
        self.assertEqual(actual.tobytes(), expected.tobytes())

    def test_six_frames_yield_exactly_the_first_frame(self):
        from PIL import Image
        images = [Image.new('RGB', (16, 12), (n * 30, 70, 200 - n * 20)) for n in range(6)]
        stream = io.BytesIO()
        images[0].save(stream, format='GIF', save_all=True, append_images=images[1:], duration=40, loop=0)
        data = stream.getvalue()
        self.assertEqual(Image.open(io.BytesIO(data)).n_frames, 6)
        self.verify(data)

    def test_partial_first_frame_retains_offset_and_logical_canvas(self):
        from PIL import Image
        image = Image.new('P', (2, 2), 1)
        image.putpalette([20, 30, 40, 180, 90, 50] + [0] * 762)
        stream = io.BytesIO()
        image.save(stream, format='GIF', optimize=False)
        data = bytearray(stream.getvalue())
        table = 13 + (2 << (data[10] & 7)) * 3
        self.assertEqual(data[table], 0x2c)
        data[6:10] = struct.pack('<HH', 5, 4)
        data[table + 1:table + 5] = struct.pack('<HH', 1, 1)
        self.verify(bytes(data))

    def test_transparent_first_frame_preserves_visible_pixels(self):
        from PIL import Image
        image = Image.new('RGBA', (3, 2), (0, 0, 0, 0))
        image.putpixel((1, 0), (100, 150, 200, 255))
        stream = io.BytesIO()
        image.save(stream, format='GIF', transparency=0)
        self.verify(stream.getvalue())

    def test_existing_output_and_original_are_preserved(self):
        source = self.work / 'image.gif'
        target = self.work / 'occupied.png'
        source.write_bytes(GIF)
        target.write_bytes(b'keep me')
        result = subprocess.run([str(api.image_processor_path(self.tools)), '--gif-first-frame',
                                 str(source), str(target)], capture_output=True, timeout=30,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(source.read_bytes(), GIF)
        self.assertEqual(target.read_bytes(), b'keep me')


if __name__ == '__main__':
    unittest.main()
