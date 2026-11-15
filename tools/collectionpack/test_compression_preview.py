"""Actual image pairs and preparation failure/skip cleanup."""
import base64
import json
import subprocess
import sys
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree as ET
import unittest
import zipfile

from compression_preview import ComparisonPreview, MAX_PAIRS
from pack_collection import Canceled
from test_pack_collection import image_fixture, illustrated_fb2, sha
import test_prepare_book_compression as fixtures


class CompressionPreviewTests(unittest.TestCase):
    setUp = fixtures.SelectedPreparationTests.setUp
    tearDown = fixtures.SelectedPreparationTests.tearDown
    source_zip = fixtures.SelectedPreparationTests.source_zip
    prepare = fixtures.SelectedPreparationTests.prepare
    decoded = fixtures.SelectedPreparationTests.decoded
    def test_fb2_quality_preview_contains_actual_original_and_encoded_bytes(self):
        image = image_fixture(True)
        source = self.source_zip({'one.fb2': illustrated_fb2(image), 'neighbor.bin': b'Keep'})
        before = sha(source)
        result = self.prepare(source, {'one.fb2': '.fb2'}, profile='economy', grayscale=True, preview_images=True)
        self.assertIsNotNone(result.preview)
        encoded = ET.fromstring(self.decoded(result.candidate, 'one.fb2')).find(
            '{http://www.gribuser.ru/xml/fictionbook/2.0}binary').text
        with zipfile.ZipFile(result.preview['path']) as archive:
            document = json.loads(archive.read('comparison.json'))
            self.assertEqual(len(document['pairs']), 1)
            pair = document['pairs'][0]
            self.assertEqual((pair['member'], pair['image']), ('one.fb2', 'picture'))
            self.assertEqual(archive.read(pair['before']), image)
            self.assertEqual(archive.read(pair['after']), base64.b64decode(encoded))
            self.assertNotEqual(archive.read(pair['before']), archive.read(pair['after']))
        self.assertEqual(sha(source), before)
        self.assertEqual(self.decoded(result.candidate, 'neighbor.bin'), b'Keep')

    def test_epub_quality_preview_pairs_the_same_image_path(self):
        image = image_fixture(False)
        source = self.source_zip({'one.epub': fixtures.epub(image)})
        result = self.prepare(source, {'one.epub': '.epub'}, profile='economy', preview_images=True)
        output = self.root / 'output.epub'
        output.write_bytes(self.decoded(result.candidate, 'one.epub'))
        with zipfile.ZipFile(result.preview['path']) as archive, zipfile.ZipFile(output) as book:
            pair = json.loads(archive.read('comparison.json'))['pairs'][0]
            self.assertEqual(pair['image'], 'picture.png')
            self.assertEqual(archive.read(pair['before']), image)
            self.assertEqual(archive.read(pair['after']), book.read('picture.png'))

    def test_illustrated_first_book_does_not_hide_the_next_selected_book(self):
        image = image_fixture(True)
        tree = ET.fromstring(illustrated_fb2(image))
        binary = tree.find('{http://www.gribuser.ru/xml/fictionbook/2.0}binary')
        for index in range(1, MAX_PAIRS + 2):
            copy = ET.fromstring(ET.tostring(binary))
            copy.set('id', 'picture-' + str(index))
            tree.append(copy)
        data = ET.tostring(tree, encoding='utf-8', xml_declaration=True)
        source = self.source_zip({'many.fb2': data, 'next.fb2': data, 'neighbor.bin': b'Keep'})
        before = sha(source)
        result = self.prepare(source, {'many.fb2': '.fb2', 'next.fb2': '.fb2'},
            profile='economy', grayscale=True, preview_images=True)
        with zipfile.ZipFile(result.preview['path']) as archive:
            document = json.loads(archive.read('comparison.json'))
            self.assertEqual({p['member'] for p in document['pairs']}, {'many.fb2', 'next.fb2'})
            self.assertLessEqual(len(document['pairs']), MAX_PAIRS)
            for member in ('many.fb2', 'next.fb2'):
                encoded = ET.fromstring(self.decoded(result.candidate, member))
                binaries = {node.get('id'): base64.b64decode(node.text) for node in encoded.findall(
                    '{http://www.gribuser.ru/xml/fictionbook/2.0}binary')}
                for pair in document['pairs']:
                    if pair['member'] == member:
                        self.assertEqual(archive.read(pair['before']), image)
                        self.assertEqual(archive.read(pair['after']), binaries[pair['image']])
        self.assertEqual(sha(source), before)
        self.assertEqual(self.decoded(result.candidate, 'neighbor.bin'), b'Keep')

    def test_cancel_after_collecting_preview_removes_owned_preview_and_candidate(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        before = sha(source)
        with patch('prepare_book_compression.prepare_archive_replacement', side_effect=Canceled('stop')):
            with self.assertRaises(Canceled):
                self.prepare(source, {'one.fb2': '.fb2'}, profile='economy', grayscale=True, preview_images=True)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)

    def test_outer_packing_only_does_not_make_a_misleading_quality_preview(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        result = self.prepare(source, {'one.fb2': '.fb2'}, profile='original', preview_images=True)
        self.assertIsNone(result.preview)
        self.assertFalse((self.work / 'comparison.zip').exists())

    def test_no_smaller_archive_does_not_leave_preview_images(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        kept = SimpleNamespace(candidate=None, original_sha256=sha(source), output_bytes=source.stat().st_size)
        with patch('prepare_book_compression.prepare_archive_replacement', return_value=kept):
            result = self.prepare(source, {'one.fb2': '.fb2'}, profile='economy', grayscale=True, preview_images=True)
        self.assertIsNone(result.candidate)
        self.assertIsNone(result.preview)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_cli_publication_failure_removes_preview_without_touching_existing_report(self):
        source = self.source_zip({'one.fb2': illustrated_fb2(image_fixture(True))})
        before = sha(source)
        report, request = self.root / 'report.json', self.root / 'request.json'
        report.write_bytes(b'Keep report')
        request.write_text(json.dumps(dict(version=1, source=str(source), members={'one.fb2': '.fb2'},
            workspace=str(self.work), report=str(report), seven_zip=str(fixtures.SEVEN), tools_root=str(fixtures.TOOLS),
            profile='economy', grayscale=True, preview_images=True,
            receipt_template=dict(schema=1, kind='HomeLibre book compression', source=str(source), rows=[{'member':'one.fb2'}]))), encoding='utf-8')
        process = subprocess.run([sys.executable, '-B', str(Path(fixtures.preparation.__file__)), '--job', str(request)],
                                 capture_output=True, timeout=30)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(list(self.work.iterdir()), [])
        self.assertEqual(sha(source), before)
        self.assertEqual(report.read_bytes(), b'Keep report')

    def test_preview_does_not_remove_an_unowned_existing_file(self):
        file = self.work / 'comparison.zip'
        file.write_bytes(b'Keep foreign file')
        with self.assertRaises(FileExistsError):
            with ComparisonPreview(self.work, lambda: None) as preview:
                preview.add_pair('one.fb2', 'image', image_fixture(True), image_fixture(True))
        self.assertEqual(file.read_bytes(), b'Keep foreign file')

    def test_preview_is_bounded_and_uses_internal_names_instead_of_book_paths(self):
        image = image_fixture(True)
        with ComparisonPreview(self.work, lambda: None) as preview:
            for index in range(MAX_PAIRS + 1):
                preview.add_pair('../one.fb2', f'../../{index}.png', image, image)
            result = preview.finish()
            preview.keep = True
        with zipfile.ZipFile(result['path']) as archive:
            document = json.loads(archive.read('comparison.json'))
            self.assertTrue(document['limited'])
            self.assertEqual(len(document['pairs']), MAX_PAIRS)
            self.assertTrue(all('/' not in name and '\\' not in name for name in archive.namelist()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
