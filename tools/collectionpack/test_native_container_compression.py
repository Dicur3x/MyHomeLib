"""Original-format Office/comic images through the installed native operation."""
import io
import importlib.util
import hashlib
import json
import copy
import os
from pathlib import Path
import random
import tempfile
import unittest
from xml.etree import ElementTree as ET
import zipfile

from PIL import Image
import test_native_compression_operation as operations
from test_native_mislabeled_compression import MislabeledCompressionTests
from pack_collection import Canceled


def container(extension, *, signed=False):
    image = Image.frombytes('RGB', (640, 720), random.Random(925).randbytes(640*720*3))
    pictures = {}
    for suffix, kind in (('.png', 'PNG'), ('.jpg', 'JPEG')):
        output = io.BytesIO()
        image.save(output, kind, **({'quality': 95} if kind == 'JPEG' else {}))
        pictures[suffix] = output.getvalue()
    extras = {}
    if extension == '.odt':
        prefix = 'Pictures/'
        extras = {
            'mimetype': b'application/vnd.oasis.opendocument.text',
            'content.xml': b'<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>Keep text, footnote, table, links and style.</text:p></office:text></office:body></office:document-content>',
            'META-INF/manifest.xml': b'<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="Pictures/page.png" manifest:media-type="image/png"/><manifest:file-entry manifest:full-path="Pictures/page.jpg" manifest:media-type="image/jpeg"/></manifest:manifest>',
            'styles.xml': b'<styles>Keep original formatting bytes</styles>',
            'Pictures/vector.svg': b'<svg xmlns="http://www.w3.org/2000/svg"><text>Vector text</text></svg>',
            'attachments/original.png': pictures['.png'],
        }
        if signed:
            extras['META-INF/documentsignatures.xml'] = b'<signatures/>'
        extras['META-INF/manifest.xml'] = extras['META-INF/manifest.xml'].replace(
            b'manifest:media-type="image/png"', b'manifest:media-type="image/png" manifest:size="'+str(len(pictures['.png'])).encode()+b'"').replace(
            b'manifest:media-type="image/jpeg"', b'manifest:media-type="image/jpeg" manifest:size="'+str(len(pictures['.jpg'])).encode()+b'"').replace(
            b'</manifest:manifest>', b'<!-- Keep this manifest comment --><?keep instruction?></manifest:manifest>')
    elif extension == '.docx':
        prefix = 'word/media/'
        extras = {
            '[Content_Types].xml': b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
            'word/document.xml': b'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Keep text, footnote, table, links and style.</w:t></w:r></w:p></w:body></w:document>',
            'word/_rels/document.xml.rels': b'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rPic" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/page.png"/></Relationships>',
            'word/styles.xml': b'<styles>Keep original formatting bytes</styles>',
            'word/media/vector.svg': b'<svg xmlns="http://www.w3.org/2000/svg"><text>Vector text</text></svg>',
            'word/embeddings/original.png': pictures['.png'],
        }
        if signed:
            extras['_xmlsignatures/sig1.xml'] = b'<signatures/>'
    else:
        prefix = 'pages/'
        extras = {'ComicInfo.xml': '<ComicInfo><Title>Книга Ё</Title><PageCount>2</PageCount></ComicInfo>'.encode(),
                  'Thumbs.db': b'Keep auxiliary data'}
    originals = {prefix+'page'+suffix: data for suffix, data in pictures.items()}
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as book:
        book.comment = b'Keep archive comment'
        for name, data in {**extras, **originals}.items():
            item = zipfile.ZipInfo(name, (2021, 3, 5, 8, 10, 12))
            item.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
            item.comment = b'Keep entry comment'
            item.external_attr = 0o100644 << 16
            book.writestr(item, data)
            if extension == '.docx':
                item.external_attr = 0  # Ordinary Office central-directory metadata.
    return output.getvalue(), originals


class ContainerValidationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('container_test_api',
            Path(__file__).resolve().parents[1]/'bookconvert/convert_book.py')
        self.api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.api)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_only_declared_images_are_selected_and_attachments_are_untouched(self):
        for extension in ('.docx', '.odt', '.cbz'):
            source = self.root/('book'+extension)
            body, images = container(extension)
            source.write_bytes(body)
            self.assertEqual(self.api.packing_image_members(source, extension), set(images))
            self.assertEqual(source.read_bytes(), body)

    def test_signed_documents_are_rejected_without_creating_a_result(self):
        for extension in ('.docx', '.odt'):
            source, target = self.root/('book'+extension), self.root/('result'+extension)
            body, _ = container(extension, signed=True)
            source.write_bytes(body)
            with self.assertRaisesRegex(self.api.ConversionError, 'подпись'):
                self.api.compress_image_container(source, target, image_quality='economy', tools_root=self.root)
            self.assertFalse(target.exists())
            self.assertEqual(source.read_bytes(), body)

    def test_cancellation_is_not_reclassified_as_a_damaged_document(self):
        source = self.root/'book.cbz'
        body, _ = container('.cbz')
        source.write_bytes(body)
        def cancel():
            raise Canceled('stop sample')
        with self.assertRaises(Canceled):
            self.api.packing_image_members(source, '.cbz', cancel)
        self.assertEqual(source.read_bytes(), body)

    def test_preservation_gate_rejects_changes_to_png_attachments(self):
        from prepare_book_compression import verify_non_image_content, PackingError
        for extension in ('.docx', '.odt'):
            source, target = self.root/('source'+extension), self.root/('changed'+extension)
            body, _ = container(extension)
            source.write_bytes(body)
            with zipfile.ZipFile(io.BytesIO(body)) as old, zipfile.ZipFile(target, 'w') as new:
                new.comment = old.comment
                for entry in old.infolist():
                    data = old.read(entry)
                    if entry.filename.endswith('original.png'):
                        picture = io.BytesIO()
                        Image.new('RGB', (2, 2), (20, 30, 40)).save(picture, 'PNG')
                        data = picture.getvalue()
                    item = copy.copy(entry)
                    new.writestr(item, data)
                    item.external_attr = entry.external_attr
            with self.assertRaisesRegex(PackingError, 'изменила'):
                verify_non_image_content(source, target, extension)
            self.assertEqual(source.read_bytes(), body)

    @unittest.skipUnless(os.environ.get('HLRU_PACK_IMAGE_TOOLS'), 'Actual image helper required')
    def test_grayscale_original_and_color_maximum_keep_jpeg_png_encoding(self):
        from prepare_book_compression import verify_non_image_content
        source = self.root/'book.cbz'
        body, images = container('.cbz')
        source.write_bytes(body)
        for profile, grayscale in (('original', True), ('maximum', False)):
            target = self.root/(profile+'.cbz')
            self.api.compress_image_container(source, target, image_quality=profile,
                grayscale=grayscale, tools_root=Path(os.environ['HLRU_PACK_IMAGE_TOOLS']))
            verify_non_image_content(source, target, '.cbz')
            with zipfile.ZipFile(target) as book:
                for name in images:
                    with Image.open(io.BytesIO(book.read(name))) as image:
                        self.assertEqual(image.format, 'PNG' if name.endswith('.png') else 'JPEG')
                        bands = image.convert('RGB').split()
                        if grayscale:
                            self.assertEqual(bands[0].tobytes(), bands[1].tobytes())
                            self.assertEqual(bands[1].tobytes(), bands[2].tobytes())
                        else:
                            self.assertNotEqual(bands[0].tobytes(), bands[1].tobytes())
            self.assertEqual(source.read_bytes(), body)


@unittest.skipUnless(os.name == 'nt' and operations.OPERATOR and operations.OPERATOR.is_file()
                     and operations.RUNTIME and operations.RUNTIME.is_dir(),
                     'Built native operation and private packaged runtime required')
class ContainerCompressionTests(unittest.TestCase):
    def setUp(self):
        self.harness = MislabeledCompressionTests()
        self.harness.setUp()
        self.addCleanup(self.harness.doCleanups)

    def check_container(self, extension):
        original, images = container(extension)
        op = self.harness.seed(original, extension)
        op.config['script'] = op.config['script'].replace('\\', '/')
        observer = op.config['script']
        op.config['script'] = str(op.tools/'bookconvert/prepare_book_compression.py').replace('\\', '/')
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (op.fixture.source, op.fixture.catalogue, op.fixture.personal)}
        op.config.update(estimate_first=True, operation_mode='estimate-only')
        estimated = op.run_operation()
        self.assertEqual(estimated['error'], '', estimated)
        self.assertTrue(estimated['estimate_only'], estimated)
        self.assertGreater(estimated['estimate_input_bytes'], estimated['estimate_output_bytes'], estimated)
        self.assertEqual(estimated['estimate_unknown_books'], 0, estimated)
        self.assertEqual(estimated['changed_files'], 0, estimated)
        self.assertEqual({path: hashlib.sha256(path.read_bytes()).hexdigest() for path in before}, before)
        self.assertEqual(list(self.harness.backup.iterdir()), [])
        op.config['script'] = observer
        # Capture the actual comparison archive before the native job removes
        # its private preparation. Repeated/no-change runs leave this witness.
        witness = op.root/'container-preview.json'
        worker = Path(op.config['script'])
        script = worker.read_text(encoding='utf-8')
        script = script.replace('raise SystemExit(result)',
            'import hashlib, zipfile\n'
            'if report.get("preview"):\n'
            ' with zipfile.ZipFile(report["preview"]["path"]) as comparison:\n'
            '  pairs = json.loads(comparison.read("comparison.json"))["pairs"]\n'
            '  for pair in pairs:\n'
            '   for side in ("before", "after"):\n'
            '    pair[side+"_sha256"] = hashlib.sha256(comparison.read(pair[side])).hexdigest()\n'
            f'  pathlib.Path({str(witness)!r}).write_text(json.dumps(pairs), encoding="utf-8")\n'
            'raise SystemExit(result)')
        worker.write_text(script, encoding='utf-8')
        op.config.update(estimate_first=False, operation_mode='review-apply')
        body = self.harness.finish(op, original, extension, True)
        pairs = {p['image']: p for p in json.loads(witness.read_text(encoding='utf-8'))}
        with zipfile.ZipFile(io.BytesIO(original)) as before, zipfile.ZipFile(io.BytesIO(body)) as after:
            self.assertEqual(after.namelist(), before.namelist())
            self.assertEqual(after.comment, before.comment)
            for old in before.infolist():
                new = after.getinfo(old.filename)
                self.assertEqual((new.date_time, new.comment, new.external_attr, new.compress_type),
                                 (old.date_time, old.comment, old.external_attr, old.compress_type))
                if old.filename not in images:
                    if extension == '.odt' and old.filename == 'META-INF/manifest.xml':
                        namespace = '{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}'
                        old_tree, new_tree = ET.fromstring(before.read(old)), ET.fromstring(after.read(new))
                        for tree in (old_tree, new_tree):
                            for node in tree.iter(namespace+'file-entry'):
                                if namespace+'size' in node.attrib:
                                    if tree is new_tree:
                                        self.assertEqual(node.get(namespace+'size'), str(len(after.read(node.get(namespace+'full-path')))))
                                    node.attrib.pop(namespace+'size')
                        self.assertEqual(ET.tostring(old_tree), ET.tostring(new_tree))
                        self.assertIn(b'<!-- Keep this manifest comment -->', after.read(new))
                        self.assertIn(b'<?keep instruction?>', after.read(new))
                    else:
                        self.assertEqual(after.read(new), before.read(old), old.filename)
                else:
                    data = after.read(new)
                    self.assertEqual(pairs[old.filename]['before_sha256'], hashlib.sha256(images[old.filename]).hexdigest())
                    self.assertEqual(pairs[old.filename]['after_sha256'], hashlib.sha256(data).hexdigest())
                    self.assertNotEqual(data, images[old.filename])
                    with Image.open(io.BytesIO(data)) as picture:
                        self.assertEqual(picture.format, 'PNG' if old.filename.endswith('.png') else 'JPEG')
                        self.assertLessEqual(max(picture.size), 720)
                        for pixel in picture.convert('RGB').getdata():
                            self.assertEqual(pixel[0], pixel[1])
                            self.assertEqual(pixel[1], pixel[2])
            for name in ('content.xml', 'word/document.xml', 'ComicInfo.xml'):
                if name in after.namelist():
                    ET.fromstring(after.read(name))
            if extension == '.odt':
                self.assertEqual(after.infolist()[0].filename, 'mimetype')
                self.assertEqual(after.getinfo('mimetype').compress_type, zipfile.ZIP_STORED)

    def test_docx_keeps_text_relationships_embedded_assets_and_encoding(self):
        self.check_container('.docx')

    def test_odt_keeps_manifest_text_styles_and_encoding(self):
        self.check_container('.odt')

    def test_cbz_keeps_comic_metadata_page_names_and_encoding(self):
        self.check_container('.cbz')
