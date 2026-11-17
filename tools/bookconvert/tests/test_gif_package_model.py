"""Package-graph checks in memory; no ZIP I/O or native decoder evidence."""

import base64
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import convert_book as api
import kfx_image_input as images
from test_gif_static import GIF, PNG


RESOLVE = api.EpubArchive.resolve


class MemoryBook:
    def __init__(self, files):
        self.files = files
        self.names = set(files)
        self.archive = self

    def read(self, name):
        return self.files[name]

    def open(self, name):
        return io.BytesIO(self.read(name))

    def infolist(self):
        return [SimpleNamespace(filename=name, file_size=len(data)) for name, data in self.files.items()]

    def resolve(self, current, reference):
        return RESOLVE(self, current, reference)

    def close(self):
        pass


class MemoryOutput:
    def __init__(self):
        self.files = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def writestr(self, entry, data):
        name = entry if isinstance(entry, str) else entry.filename
        self.files[name] = data


class GifPackageModel(unittest.TestCase):
    def book(self, inline=False):
        roots = ['OPS/book.opf', 'ALT/book.opf']
        files = {'META-INF/container.xml': ('<container><rootfiles>' + ''.join(
            '<rootfile full-path="' + path + '"/>' for path in roots) + '</rootfiles></container>').encode()}
        uri = 'data:image/gif;base64,' + base64.b64encode(GIF).decode('ascii')
        for index, path in enumerate(roots):
            manifest_image = '' if inline else '<item id="pic' + str(index) + '" href="../shared/picture.gif" media-type="image/gif"/>'
            files[path] = ('''<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata/><manifest><item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
              ''' + manifest_image + '''</manifest><spine><itemref idref="chapter"/></spine></package>''').encode()
            chapter_path, _ = RESOLVE(None, path, 'text/chapter.xhtml')
            href = uri if inline else '../../shared/picture.gif'
            files[chapter_path] = ('<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="text">'
                                   + ('First' if index == 0 else 'Второй Ё') + '<img src="' + href
                                   + '"/></p></body></html>').encode('utf-8')
        if not inline:
            files['shared/picture.gif'] = GIF
        return files, roots

    def prepare(self, files):
        original = dict(files)
        output = MemoryOutput()
        decode = mock.Mock(return_value=PNG)
        with mock.patch.object(api, 'EpubArchive', return_value=MemoryBook(files)), \
                mock.patch.object(images.zipfile, 'ZipFile', return_value=output) as writer:
            count = images.prepare(api, Path('memory-input.epub'), Path('memory-output.epub'), None,
                                   decode_gif=decode, only_gif=True)
        self.assertEqual(files, original)
        if count:
            self.assertEqual(writer.call_args.args[1], 'x')
        else:
            writer.assert_not_called()
        return count, output.files, decode.call_count

    def assert_renditions(self, files, roots, preserve_ids):
        targets = []
        for index, path in enumerate(roots):
            package = api.xml(files[path])
            manifest = api.first(package, 'manifest')
            pictures = [node for node in manifest if node.get('media-type') == 'image/png']
            self.assertEqual(len(pictures), 1)
            if preserve_ids:
                self.assertEqual(pictures[0].get('id'), 'pic' + str(index))
            target, _ = RESOLVE(None, path, pictures[0].get('href'))
            self.assertEqual(files[target], PNG)
            chapter_path, _ = RESOLVE(None, path, 'text/chapter.xhtml')
            chapter = api.xhtml(files[chapter_path])
            self.assertIn('First' if index == 0 else 'Второй Ё', api.plain(chapter))
            image = next(node for node in chapter.iter() if api.tag(node) == 'img')
            self.assertEqual(RESOLVE(None, chapter_path, image.get('src'))[0], target)
            targets.append(target)
        self.assertEqual(targets[0], targets[1])

    def test_shared_image_updates_both_package_documents(self):
        source, roots = self.book()
        count, output, calls = self.prepare(source)
        self.assertEqual((count, calls), (1, 1))
        self.assertNotIn('shared/picture.gif', output)
        self.assert_renditions(output, roots, preserve_ids=True)

    def test_inline_image_is_declared_in_every_rendition(self):
        source, roots = self.book(inline=True)
        count, output, calls = self.prepare(source)
        self.assertEqual((count, calls), (1, 1))
        self.assert_renditions(output, roots, preserve_ids=False)

    def test_multiple_packages_without_gif_do_not_create_an_output(self):
        source, _ = self.book()
        source['shared/picture.gif'] = PNG
        for path in ['OPS/book.opf', 'ALT/book.opf']:
            source[path] = source[path].replace(b'image/gif', b'image/png')
        count, output, calls = self.prepare(source)
        self.assertEqual((count, calls), (0, 0))
        self.assertEqual(output, {})

    def test_signature_is_checked_before_decode_or_output_creation(self):
        source, _ = self.book()
        source['META-INF/signatures.xml'] = b'<signatures/>'
        with mock.patch.object(api, 'EpubArchive', return_value=MemoryBook(source)), \
                mock.patch.object(images.zipfile, 'ZipFile') as writer:
            decode = mock.Mock(return_value=PNG)
            with self.assertRaisesRegex(api.ConversionError, 'подпись'):
                images.prepare(api, Path('memory-input.epub'), Path('memory-output.epub'), None,
                               decode_gif=decode, only_gif=True)
            decode.assert_not_called()
            writer.assert_not_called()


if __name__ == '__main__':
    unittest.main()
