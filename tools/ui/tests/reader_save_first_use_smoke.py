"""Verify actual Reader Save As first-use; GUI actions stay with Computer Use.

This stages an owned FB2, records real downloads/restart, and checks the EPUB.
It does not drive controls, download modules itself, or simulate continuation.
"""
import argparse
import base64
import configparser
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET
import zipfile
import zlib

from reader_first_use_smoke import REPO, processes, sha

OWNER = 'HomeLibre actual Reader two-module Save As v1'
CACHE = Path('G:/HomeLibRu-build-cache')
COMPONENTS = {'BookProcessing', 'ImageProcessing'}


def owned(state):
    root = Path(state['root']).resolve(strict=True)
    assert root.parent == CACHE.resolve(strict=True)
    assert root.name.startswith('HomeLibRu-update-test-save-first-use-')
    assert not root.is_symlink() and not root.is_junction()
    assert json.loads((root / 'owned-test.marker').read_bytes()) == dict(owner=OWNER, token=state['token'])
    return root


def image_fixture():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    width, height = 1200, 900
    # Deliberately uncompressed, opaque, valid PNG: compression can be verified.
    pixels = b''.join(b'\0' + bytes(v for x in range(width) for v in
        ((x * 255 // width), (y * 255 // height), ((x + y) % 256))) for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(pixels, 0)) + chunk(b'IEND', b''))


def stage_package(package, app, platform):
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        assert manifest['component'] == 'HomeLibReader' and manifest['platform'] == platform
        assert len(archive.namelist()) == len(set(archive.namelist()))
        assert set(archive.namelist()) == {item['path'] for item in manifest['files']} | {'HomeLibRu.update.json'}
        import hashlib
        for item in manifest['files']:
            relative = Path(item['path'])
            assert not relative.is_absolute() and '..' not in relative.parts and ':' not in item['path']
            data = archive.read(item['path'])
            assert len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256']
            target = app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('launch', 'inspect', 'record-download', 'record-restart', 'check', 'cleanup'))
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'))
    parser.add_argument('--package', type=Path)
    parser.add_argument('--candidate-exe', type=Path, required=False,
                        help='Development override, explicitly recorded; not a published-archive claim')
    args = parser.parse_args()
    state = json.loads(args.state.read_bytes()) if args.state.exists() else None
    if state is None:
        assert args.action == 'launch'
        root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-save-first-use-', dir=CACHE))
        state = dict(root=str(root), token=uuid.uuid4().hex, runs=[])
        (root / 'owned-test.marker').write_text(json.dumps(dict(owner=OWNER, token=state['token'])))
        image = image_fixture()
        (root / 'source-image.png').write_bytes(image)
        source = root / 'FB2 сохранение двух модулей ё.fb2'
        source.write_text('<?xml version="1.0" encoding="utf-8"?>\n'
            '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">'
            '<description><title-info><genre>science</genre><author><first-name>Тест</first-name>'
            '<last-name>HomeLibre</last-name></author><book-title>Проверка сохранения ё</book-title><lang>ru</lang>'
            '</title-info><document-info><author><nickname>HomeLibre smoke</nickname></author>'
            '<date>2026-10-31</date><id>owned-module-save-fixture</id><version>1.0</version></document-info></description>'
            '<body><section id="first"><title><p>Первая глава ё</p></title>'
            '<p>Исходный текст и иллюстрация должны сохраниться после установки двух модулей.</p>'
            '<image l:href="#picture"/><p>Текст после иллюстрации.</p></section>'
            '<section id="second"><title><p>Вторая глава</p></title><p>Конец тестовой книги.</p></section></body>'
            '<binary id="picture" content-type="image/png">' + base64.b64encode(image).decode()
            + '</binary></FictionBook>', encoding='utf-8')
        state.update(source=str(source), source_sha256=sha(source), image_sha256=sha(root / 'source-image.png'))
    root = owned(state)
    active = processes(root)
    if args.action == 'launch':
        assert not active and args.package and args.platform
        assert not any(run['platform'] == args.platform for run in state['runs'])
        app = root / args.platform
        app.mkdir()
        stage_package(args.package, app, args.platform)
        candidate = args.candidate_exe.resolve(strict=True) if args.candidate_exe else None
        if candidate:
            shutil.copyfile(candidate, app / 'HomeLibReader.exe')
        assert all(not (app / 'tools' / folder).exists() for folder in ('bookconvert', 'images', 'kindle', 'office', 'xps'))
        output = app / 'saved'
        output.mkdir()
        (app / 'HomeLibReader.ini').write_text('[SYSTEM]\nCheckUpdates=0\nFileNameTemplate=результат-%t\n'
            'SaveAsUseSubfolders=0\n[PATH]\nSyncExport=' + str(output) + '\n', encoding='utf-8')
        before = {str(file.relative_to(app)): sha(file) for file in app.rglob('*') if file.is_file()}
        environment = dict(os.environ, APPDATA=str(root / 'Roaming'), LOCALAPPDATA=str(root / 'Local'), TEMP=str(root), TMP=str(root))
        process = subprocess.Popen([str(app / 'HomeLibReader.exe'), '--open=' + state['source']], cwd=app,
            env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW)
        state['runs'].append(dict(platform=args.platform, app=str(app), original_pid=process.pid,
            package_sha256=sha(args.package), reader_exe_sha256=sha(app / 'HomeLibReader.exe'),
            candidate_exe=str(candidate) if candidate else None, before=before, checked=False))
        state['stage'] = 'waiting-for-real-Save-As-GUI'
    elif args.action == 'inspect':
        print(json.dumps(dict(active=active, runtime_files=[str(file.relative_to(root)) for file in root.rglob('*')
            if file.is_file() and (file.suffix.lower() in ('.json', '.jsonl', '.epub') or file.name == 'HomeLibReader.ini')]), ensure_ascii=False))
    elif args.action == 'record-download':
        run = state['runs'][-1]
        app = Path(run['app'])
        assert len(active) == 1 and active[0]['ProcessId'] == run['original_pid']
        candidates = []
        for file in (root / 'Local').rglob('ready.json'):
            ready = json.loads(file.read_text(encoding='utf-8-sig'))
            job = Path(ready['job']).resolve(strict=True)
            assert job.is_relative_to(root)
            manifest = json.loads((job / 'manifest.json').read_text(encoding='utf-8-sig'))
            if manifest['platform'] == run['platform']:
                candidates.append((ready, job, manifest))
        assert len(candidates) == 1
        ready, job, manifest = candidates[0]
        assert ready['component'] == manifest['component'] == 'batch'
        assert {part['component'] for part in manifest['bundle']} == COMPONENTS
        assert sha(job / 'release.zip') == ready['sha256']
        assert all(not (app / 'tools' / folder).exists() for folder in ('bookconvert', 'images'))
        plan = json.loads((app / 'HomeLibReader.ini.pending-save.jsonl').read_text(encoding='utf-8-sig').splitlines()[0])
        assert Path(plan['source']) == Path(state['source']) and plan['images'] == 'balanced'
        assert Path(plan['folder']) == app / 'saved' and plan['mask'] == 'результат-%t' and not plan['keep']
        run.update(downloaded_ready=ready, ready_job=str(job), prepared_manifest=manifest, continuation_before_install=plan,
                   only_required_two_modules_downloaded=True, installed_before_second_click=False)
        state['stage'] = 'real-two-module-download-ready-awaiting-install-click'
    elif args.action == 'record-restart':
        run = state['runs'][-1]
        assert len(active) == 1 and active[0]['ProcessId'] != run['original_pid']
        run['restarted_pid'] = active[0]['ProcessId']
        state['stage'] = 'restarted-Reader-Save-As-observed-separately'
    elif args.action == 'check':
        assert not active, 'Close the test Reader normally before verification'
        run = state['runs'][-1]
        app = Path(run['app'])
        assert sha(Path(state['source'])) == state['source_sha256']
        manifest = run['prepared_manifest']
        journal = json.loads((Path(run['ready_job']) / 'journal.json').read_text(encoding='utf-8-sig'))
        assert journal['state'] == 'installed'
        for item in manifest['files']:
            assert sha(app / item['path']) == item['sha256'], item['path']
        for relative, digest in run['before'].items():
            if relative != 'HomeLibReader.ini':
                assert sha(app / relative) == digest, 'Unrelated file changed: ' + relative
        assert all(not (app / 'tools' / name).exists() for name in ('kindle', 'office', 'xps', 'doc', 'djvu', 'pdfium'))
        output = app / 'saved' / ('результат-' + Path(state['source']).stem + '.epub')
        assert list((app / 'saved').iterdir()) == [output]
        with zipfile.ZipFile(output) as book:
            assert book.testzip() is None and book.read('mimetype') == b'application/epub+zip'
            container = ET.fromstring(book.read('META-INF/container.xml'))
            package_name = next(n.attrib['full-path'] for n in container.iter() if n.tag.endswith('rootfile'))
            package = ET.fromstring(book.read(package_name))
            items = [n for n in package.iter() if n.tag.endswith('}item')]
            from posixpath import join, normpath, dirname
            images = [normpath(join(dirname(package_name), n.attrib['href'])) for n in items
                      if n.attrib['media-type'].startswith('image/')]
            texts = [normpath(join(dirname(package_name), n.attrib['href'])) for n in items
                     if n.attrib['media-type'] == 'application/xhtml+xml']
            documents = {name: ET.fromstring(book.read(name)) for name in texts}
            text = ' '.join(''.join(document.itertext()) for document in documents.values())
            for expected in ('Первая глава ё', 'Вторая глава', 'Текст после иллюстрации.', 'Конец тестовой книги.'):
                assert expected in text, expected
            assert len(images) == 1 and 0 < len(book.read(images[0])) < (root / 'source-image.png').stat().st_size
            image_references = [normpath(join(dirname(name), node.attrib['src']))
                for name, document in documents.items() for node in document.iter()
                if node.tag.endswith('}img')]
            assert image_references and all(name in images for name in image_references)
            picture = book.read(images[0])
            assert picture.startswith(b'\x89PNG\r\n\x1a\n')
            width, height = struct.unpack('>II', picture[16:24])
            assert width > 0 and height > 0
            run['output_image_dimensions'] = [width, height]
            run['output_image_references_verified'] = len(image_references)
            run['output_image_bytes'] = len(book.read(images[0]))
        assert not (app / 'HomeLibReader.ini.pending-save.jsonl').exists()
        assert not (app / 'HomeLibReader.ini.pending-save.jsonl.ready').exists()
        settings = configparser.ConfigParser(interpolation=None)
        settings.read(app / 'HomeLibReader.ini', encoding='utf-8-sig')
        assert Path(settings['PATH']['SyncExport']).resolve(strict=True) == (app / 'saved').resolve(strict=True)
        assert settings['SYSTEM']['FileNameTemplate'] == 'результат-%t'
        for component in sorted(COMPONENTS):
            native = REPO / f"Program/Tests/Out/{run['platform']}/ProgramUpdateInstallerTest.exe"
            result = subprocess.run([str(native), '--component-needs-repair', str(app), component],
                env=dict(os.environ, TEMP=str(CACHE), TMP=str(CACHE)), capture_output=True,
                encoding='utf-8-sig', creationflags=subprocess.CREATE_NO_WINDOW, timeout=60)
            assert result.returncode == 0 and result.stdout.strip().splitlines() == ['0', 'PASS'], result
        run.update(checked=True, source_preserved=True, unrelated_modules_absent=True, preexisting_payload_preserved=True,
            installed_payload_hashes_verified=len(manifest['files']), transaction_installed=True,
            output_epub_sha256=sha(output), output_epub_bytes=output.stat().st_size,
            output_text_and_image_verified=True, continuation_consumed=True, native_repairs_needed=False)
        state['stage'] = 'actual-two-module-Save-As-verified'
    elif args.action == 'cleanup':
        assert not active and len(state['runs']) == 2 and all(run['checked'] for run in state['runs'])
        assert owned(state) == root
        shutil.rmtree(root)
        state.update(temporary_profile_removed=not root.exists(), stage='cleaned')
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(stage=state['stage'], root=state['root'], runs=[{k: v for k, v in run.items()
        if k not in ('before', 'prepared_manifest', 'downloaded_ready', 'continuation_before_install')} for run in state['runs']]), ensure_ascii=False))


if __name__ == '__main__':
    main()
