"""Execute only the independent processing/image payloads, never the full runtime."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest
import zipfile
import zlib
from test_legacy_fixed import pdf_fixture

REPO = Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('format_packages', REPO/'scripts/package-format-components.py')
packages=importlib.util.module_from_spec(spec); spec.loader.exec_module(packages)


def stage(root, payload):
    for name, data in payload.items():
        target=root/name; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


class ModularComponents(unittest.TestCase):
    def test_pdf_conversion_with_only_common_processing_and_pdfium(self):
        hashes={'Win32':'bb2d8354652e7cdb21998b46a4f7e0d7d25636405c5718a099daddcd326b2f33',
                'Win64':'455475d3df2d488ab4b1d7d6bd75986fe17dad745c87b2785c688be03b6e75fe'}
        # Read the already audited exact published packages; do not download,
        # mutate or remove their retained source directory.
        packages_root=REPO/'tools/ui/tests/Out/pre536-hotfix-20261028-r1/corrected-components'
        for platform in ('Win32','Win64'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix='HomeLibRu-format-test-') as folder:
                root=Path(folder).resolve()
                self.assertEqual(root.parent,Path(tempfile.gettempdir()).resolve())
                base,_=packages.payload_for(platform,'BookProcessing');stage(root,base)
                archive_path=packages_root/f'HomeLibRu-PDFium-157.0.8086.0-{platform}.zip'
                self.assertEqual(hashlib.sha256(archive_path.read_bytes()).hexdigest(),hashes[platform])
                with zipfile.ZipFile(archive_path) as archive:
                    manifest=json.loads(archive.read('HomeLibRu.update.json'))
                    for item in manifest['files']:
                        self.assertTrue(item['path'].startswith('tools/pdfium/'))
                        data=archive.read(item['path'])
                        self.assertEqual(hashlib.sha256(data).hexdigest(),item['sha256'])
                        stage(root,{item['path']:data})
                source=root/'scanned.pdf';original=pdf_fixture(text=False);source.write_bytes(original)
                for extension in ('.fb2','.epub'):
                    target=root/('result'+extension)
                    result=subprocess.run([str(root/'tools/python/python.exe'),'-I','-B','-X','utf8',
                        str(root/'tools/bookconvert/convert_book.py'),str(source),str(target),
                        '--tools-root',str(root/'tools')],capture_output=True,text=True,encoding='utf-8',
                        timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertTrue(target.is_file())
                for directory in ('images','kindle','office','xps','djvu'):
                    self.assertFalse((root/'tools'/directory).exists(),directory)
                result=subprocess.run([str(root/'tools/python/python.exe'),'-I','-B','-X','utf8',
                    str(root/'tools/bookconvert/convert_book.py'),str(source),str(root/'balanced.epub'),
                    '--tools-root',str(root/'tools'),'--image-quality','balanced'],capture_output=True,
                    text=True,encoding='utf-8',timeout=90,creationflags=subprocess.CREATE_NO_WINDOW)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(json.loads(result.stdout)['required_component'],'ImageProcessing')
                self.assertEqual(source.read_bytes(),original)

    def test_both_architectures_process_fb2_and_request_only_real_dependencies(self):
        for platform in ('Win32','Win64'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory(prefix='HomeLibRu-format-test-') as folder:
                root=Path(folder).resolve()
                self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
                self.assertFalse(root.is_symlink())
                (root/'owned-format-test.marker').write_text(platform, encoding='ascii')
                base, _ = packages.payload_for(platform, 'BookProcessing')
                stage(root, base)
                for directory in ('kindle','office','xps','images','pdfium','djvu'):
                    self.assertFalse((root/'tools'/directory).exists(), directory)
                python=root/'tools/python/python.exe'; worker=root/'tools/bookconvert/convert_book.py'
                def run(source, target, *arguments):
                    report=target.with_suffix('.json')
                    result=subprocess.run([str(python),'-I','-B','-X','utf8',str(worker),str(source),str(target),
                        '--report',str(report),'--tools-root',str(root/'tools'),*arguments],
                        capture_output=True,text=True,encoding='utf-8',timeout=90,
                        creationflags=subprocess.CREATE_NO_WINDOW)
                    self.assertTrue(report.is_file(), result.stdout+result.stderr)
                    return result, json.loads(report.read_bytes())
                def chunk(kind,data):
                    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
                # The encoder intentionally keeps pictures <=512 px unchanged.
                # A larger real picture exercises actual image processing.
                width,height=900,700
                noise=random.Random(537).randbytes(width*height*3)
                raw=b''.join(b'\0'+noise[y*width*3:(y+1)*width*3] for y in range(height))
                image=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
                source=root/'illustrated.fb2'
                source.write_text('''<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><genre>prose</genre><book-title>Isolated module</book-title><lang>en</lang></title-info></description><body><section><p>Text remains readable.</p><image l:href="#picture"/></section></body><binary id="picture" content-type="image/jpg">'''+base64.b64encode(image).decode()+'''</binary></FictionBook>''',encoding='utf-8')
                original=hashlib.sha256(source.read_bytes()).hexdigest()
                plain=root/'plain.epub'; result, report=run(source,plain)
                self.assertEqual(result.returncode,0,report)
                with zipfile.ZipFile(plain) as archive:
                    self.assertEqual(archive.read('OEBPS/images/image-1.png'),image)
                compressed=root/'compressed.epub'
                result, report=run(source,compressed,'--image-quality','balanced')
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(report.get('required_component'),'ImageProcessing',report)
                self.assertFalse(compressed.exists())
                (root/'compressed.json').unlink()
                image_payload,_=packages.payload_for(platform,'ImageProcessing');stage(root,image_payload)
                result,report=run(source,compressed,'--image-quality','balanced')
                self.assertEqual(result.returncode,0,report)
                with zipfile.ZipFile(compressed) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertTrue(any(name.endswith(('.png','.jpg')) for name in archive.namelist()))
                    self.assertIn(b'Text remains readable.',archive.read('OEBPS/body-1.xhtml'))
                self.assertLess(compressed.stat().st_size,plain.stat().st_size)
                for directory in ('kindle','office','xps','pdfium','djvu'):
                    self.assertFalse((root/'tools'/directory).exists(), directory)
                pdf=root/'example.pdf';pdf.write_bytes(b'%PDF-1.4\n')
                result,report=run(pdf,root/'pdf.epub')
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(report.get('required_component'),'PDFium',report)
                processor=root/'tools/images/HomeLibImages.exe'
                attempted=root/'xps-pages.zip'
                refused=subprocess.run([str(processor),str(pdf),str(attempted)],capture_output=True,text=True,
                    encoding='utf-8',timeout=10,creationflags=subprocess.CREATE_NO_WINDOW)
                self.assertNotEqual(refused.returncode,0)
                self.assertIn('separate component',refused.stderr)
                self.assertFalse(attempted.exists())
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),original)

    def test_payloads_do_not_overlap(self):
        for platform in ('Win32','Win64'):
            owned={}
            for component in packages.COMPONENTS:
                payload,_=packages.payload_for(platform,component)
                self.assertFalse(set(payload)&set(owned),component)
                owned.update({name:component for name in payload})


if __name__ == '__main__':
    unittest.main(verbosity=2)
