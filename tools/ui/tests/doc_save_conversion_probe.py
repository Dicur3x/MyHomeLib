"""Check real USR Word conversions without showing application windows.

Use exact component archive payloads in a disposable profile. Compare every
nonempty DOCX body paragraph and embedded image count with the native FB2/EPUB
results. The DOCX reference uses the same DocSharp decoder; this checks the
conversion pipeline after decoding, not an independent DOC decoder oracle.
User book text and document payloads are never included in the JSON report.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import posixpath
import shutil
import subprocess
import tempfile
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[3]
W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
F = '{http://www.gribuser.ru/xml/fictionbook/2.0}'
O = '{http://www.idpf.org/2007/opf}'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_doc_sample(inventory):
    data = json.loads(inventory.read_bytes())
    group = next(item for item in data['formats'] if item['extension'] == '.doc')
    for example in group['examples']:
        for available in example.get('available', []):
            source = Path(available['path'])
            if not source.is_file():
                continue
            before = source.stat()
            with zipfile.ZipFile(source) as archive:
                entry = archive.getinfo(available['member'])
                if entry.file_size > 8 * 1024 * 1024:
                    continue
                payload = archive.read(entry)
            if not payload.startswith(bytes.fromhex('D0CF11E0A1B11AE1')):
                continue
            after = source.stat()
            assert (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns)
            return payload, dict(inventory_record_id=example['id'], archive=str(source),
                member=entry.filename, bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest(),
                archive_size=before.st_size, archive_mtime_ns=before.st_mtime_ns)
    raise AssertionError('A small binary Word document is required; no substitute format is used')


def unpack_component(source, target, asset):
    assert source.stat().st_size == asset['size'] and 'sha256:' + sha(source) == asset['digest']
    with zipfile.ZipFile(source) as archive:
        assert archive.testzip() is None
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        for entry in manifest['files']:
            name = entry['path']
            assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
            assert '..' not in Path(name).parts
            value = archive.read(name)
            assert len(value) == entry['size'] and hashlib.sha256(value).hexdigest() == entry['sha256']
            destination = target / name
            assert not destination.exists(), 'Component payloads overlap: ' + name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(value)


def compact(text):
    return ''.join(character for character in text if not character.isspace())


def verify_output(path, paragraphs, expected_images):
    if path.suffix == '.fb2':
        document = ET.parse(path).getroot()
        bodies = document.findall(F + 'body')
        assert bodies
        text = ''.join(''.join(body.itertext()) for body in bodies)
        images = sum(len(body.findall('.//' + F + 'image')) for body in bodies)
    else:
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None and archive.read('mimetype') == b'application/epub+zip'
            container = ET.fromstring(archive.read('META-INF/container.xml'))
            package_name = container.find('.//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile').get('full-path')
            package = ET.fromstring(archive.read(package_name))
            entries = {item.get('id'): item.get('href') for item in package.findall(O + 'manifest/' + O + 'item')}
            text, images = '', 0
            for item in package.findall(O + 'spine/' + O + 'itemref'):
                name = posixpath.normpath(posixpath.join(posixpath.dirname(package_name), unquote(entries[item.get('idref')])))
                body = ET.fromstring(archive.read(name))
                text += ''.join(body.itertext())
                images += sum(element.tag.rsplit('}', 1)[-1] in ('image', 'img') for element in body.iter())
    text = compact(text)
    position = 0
    for paragraph in paragraphs:
        value = compact(paragraph)
        found = text.find(value, position)
        assert found >= 0, 'A decoded body paragraph is missing or out of order'
        position = found + len(value)
    assert images >= expected_images, 'Decoded document images were lost'
    return dict(bytes=path.stat().st_size, sha256=sha(path), decoded_paragraphs_preserved=len(paragraphs),
                images=images)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    assert not args.report.exists()
    payload, descriptor = read_doc_sample(args.inventory)
    assets = {asset['name']: asset for asset in json.loads((args.stage / 'publication-r1/assets.json').read_bytes())}
    temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-doc-')
    root = Path(temporary.name).resolve()
    assert root.parent == Path(os.environ['TEMP']).resolve() and not root.is_symlink()
    report = dict(status='FAIL', platform=args.platform, source=descriptor, published=False,
        scope='Headless native conversion with exact local component payloads; DOCX reference shares DocSharp; no GUI/installer/download claim')
    try:
        app = root / 'app'
        environment = dict(os.environ, LOCALAPPDATA=str(root / 'LocalAppData'),
            APPDATA=str(root / 'Roaming'), TEMP=str(root), TMP=str(root))
        work = root / 'work'
        work.mkdir()
        source, reference = root / 'source.doc', root / 'reference.docx'
        source.write_bytes(payload)
        processing = args.stage / 'formats' / f'HomeLibRu-BookProcessing-3.0.0.1-{args.platform}.zip'
        doc = ROOT / 'tools/ui/tests/Out/component-mirrors-pre534-20261027' / f'HomeLibRu-DocSharp-0.21.0.0-{args.platform}.zip'
        report['components'] = []
        for archive in (processing, doc):
            unpack_component(archive, app, assets[archive.name])
            report['components'].append(dict(archive=archive.name, sha256=sha(archive)))
        for name in ('kindle', 'office', 'images', 'pdfium', 'djvu', 'xps', '7zip'):
            assert not (app / 'tools' / name).exists(), 'Unrelated component: ' + name
        for name in ('uselocaldata', 'uselocaltemp'):
            (app / name).touch()
        result = subprocess.run([str(app / 'tools/doc/HomeLibDoc.exe'), str(source), str(reference)],
            capture_output=True, env=environment, timeout=40, creationflags=subprocess.CREATE_NO_WINDOW)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        with zipfile.ZipFile(reference) as archive:
            document = ET.fromstring(archive.read('word/document.xml'))
            paragraphs = [''.join(node.text or '' for node in paragraph.iter(W + 't'))
                          for paragraph in document.findall('.//' + W + 'body//' + W + 'p')]
            paragraphs = [text for text in paragraphs if compact(text)]
            expected_images = sum(name.startswith('word/media/') and not name.endswith('/') for name in archive.namelist())
        assert paragraphs
        report['reference'] = dict(nonempty_body_paragraphs=len(paragraphs), media_entries=expected_images,
            normalized_body_sha256=hashlib.sha256(compact(''.join(paragraphs)).encode()).hexdigest())
        # Production direct-DOC lookup uses the host executable directory.
        # Run the unchanged native helper from the owned runtime, as Main does.
        native = app / 'ProgramUpdateInstallerTest.exe'
        shutil.copyfile(ROOT / 'Program/Tests/Out' / args.platform / native.name, native)
        report['native_sha256'] = sha(native)
        report['outputs'] = {}
        for extension in ('.fb2', '.epub'):
            output = root / ('converted' + extension)
            result = subprocess.run([str(native), '--convert', str(source), str(output), str(work), str(app)],
                capture_output=True, env=environment, timeout=90, creationflags=subprocess.CREATE_NO_WINDOW)
            assert result.returncode == 0, result.stdout.decode(errors='replace') + result.stderr.decode(errors='replace')
            report['outputs'][extension] = verify_output(output, paragraphs, expected_images)
            assert sha(source) == descriptor['sha256']
        assert all(not (app / 'tools' / name).exists() for name in ('kindle', 'office', 'images', 'pdfium', 'djvu', 'xps', '7zip'))
        assert hashlib.sha256(read_doc_sample(args.inventory)[0]).hexdigest() == descriptor['sha256']
        report.update(status='PASS', source_preserved=True, unrelated_modules_absent=True)
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        assert root.parent == Path(os.environ['TEMP']).resolve() and root.name.startswith('HomeLibRu-update-test-doc-')
        try:
            temporary.cleanup()
        except BaseException as error:
            report.update(status='FAIL', cleanup_error=repr(error))
            raise
        finally:
            report['temporary_profile_removed'] = not root.exists()
            with args.report.open('x', encoding='utf-8') as stream:
                json.dump(report, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
    print('PASS ' + args.platform + ': real DOC to FB2/EPUB, all decoded body paragraphs preserved; private runtime removed')


if __name__ == '__main__':
    main()
