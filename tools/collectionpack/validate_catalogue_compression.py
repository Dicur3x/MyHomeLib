"""Drive the ordinary catalogue command in an isolated portable installation.

The native fixture operates its actual controls. This wrapper verifies the
physical shared ZIP and original-book backups independently after the UI exits.
Never points the catalogue at a user's source folder or personal database.
"""
import argparse
import base64
from contextlib import closing, contextmanager, nullcontext
import ctypes
import hashlib
import io
import json
import os
import random
import re
from pathlib import Path
import shutil
import sqlite3
import subprocess
from supervised_test_process import run_owned
import time
import uuid
import zipfile
from xml.etree import ElementTree as ET

from pack_collection import temporary_work_directory
from prepare_book_compression import verify_non_image_content


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def jpeg_xl_inpx_fixture():
    """Over 256 distinct small JPEGs exercise native sidecar reconstruction."""
    from PIL import Image
    from test_pack_collection import illustrated_fb2
    ns = '{http://www.gribuser.ru/xml/fictionbook/2.0}'
    book = ET.fromstring(illustrated_fb2(b''))
    for binary in book.findall(ns + 'binary'):
        book.remove(binary)
    section = book.find('.//' + ns + 'section')
    rng = random.Random(14013)
    for index in range(258):
        name = 'picture' if index == 0 else f'picture-{index}'
        image = Image.frombytes('RGB', (256, 192), rng.randbytes(256 * 192 * 3))
        with io.BytesIO() as stream:
            image.save(stream, format='JPEG', quality=92, optimize=True)
            data = stream.getvalue()
        ET.SubElement(book, ns + 'binary', {'id': name, 'content-type': 'image/jpeg'}).text = base64.b64encode(data).decode()
        if index:
            ET.SubElement(section, ns + 'image', {'{http://www.w3.org/1999/xlink}href': '#' + name})
    section.append(ET.Comment('Literal </FictionBook> inside a comment must remain unchanged.'))
    data = ET.tostring(book, encoding='utf-8', xml_declaration=True)
    return re.sub(rb'</([^\s<>/]+)>(\s*)$', rb'</\1 >\2', data)


def archive_body(archive, member, seven_zip):
    # Decode independently with 7-Zip. Python's ZIP reader can select an EPUB
    # embedded in a stored 7z instead of the primary archive's requested member.
    result = run_owned([str(seven_zip), 'e', '-so', '-spd', '-bd', '-y', '--', str(archive), member],
                            capture_output=True, timeout=120)
    if result.returncode:
        raise AssertionError(result.stderr.decode('utf-8', errors='replace'))
    return result.stdout


def verify_text_only_repack(root):
    exports = list(root.glob('text-only-jxl-*.epub'))
    assert len(exports) == 2, 'Both native publications must exercise text-only export'
    work = root / 'text-only-repack'
    work.mkdir()
    source_book = work / 'without-images.epub'
    shutil.copy2(exports[-1], source_book)
    source = work / 'download.7z'
    seven = root / 'tools/7zip/7za.exe'
    result = run_owned([str(seven), 'a', '-t7z', '-mx=0', '-y', '-bb0', '--', str(source), source_book.name],
                       cwd=work, capture_output=True, timeout=60)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    assert source.read_bytes().startswith(b'7z\xbc\xaf\x27\x1c')
    source_hash = digest(source)
    plan = work / 'plan.sqlite'
    with closing(sqlite3.connect(plan)) as db:
        db.execute('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)')
        db.executemany('INSERT INTO metadata VALUES(?,?)', [('api','1'), ('dataset','text-only-native-repack')])
        db.execute('CREATE TABLE books(book_id INTEGER PRIMARY KEY,source TEXT,member TEXT,locator TEXT,filename TEXT,ext TEXT,inside_no INTEGER)')
        db.execute('INSERT INTO books VALUES(?,?,?,?,?,?,?)',
                   (1,str(source),source_book.name,source_book.name,source_book.stem,'.epub',0))
        db.commit()
    encoder, = (root / 'tools').rglob('cjxl.exe')
    decoder, = (root / 'tools').rglob('djxl.exe')
    output = work / 'output'
    job = work / 'job.json'
    job.write_text(json.dumps(dict(version=1, dataset='text-only-native-repack', engine='jpeg-xl-7z', images='original',
        plan=str(plan), output=str(output), seven_zip=str(seven), jpeg_xl_encoder=str(encoder),
        jpeg_xl_decoder=str(decoder), reader_fb2_namespaces=True)), encoding='utf-8')
    result = run_owned([str(root / 'tools/python/python.exe'), '-I', '-B', '-X', 'utf8', str(root / 'tools/bookconvert/pack_collection.py'),
                        '--job', str(job)], cwd=work, capture_output=True, timeout=90)
    assert result.returncode == 0, (result.stdout + result.stderr).decode(errors='replace')
    mapping, = output.glob('generations/*/locations.sqlite')
    with closing(sqlite3.connect(mapping)) as db:
        folder, name, ext = db.execute('SELECT folder,filename,ext FROM locations WHERE book_id=1').fetchone()
    assert archive_body(output / folder, name + ext, seven) == source_book.read_bytes()
    assert digest(source) == source_hash, 'Repacking changed the downloaded archive'
    assert (output / folder).stat().st_size <= source.stat().st_size, 'Text-only repacking grew the container'
    return dict(status='PASS', input_container='7z', book_bytes_preserved=True,
                source_book_sha256=digest(source_book), source_archive_bytes=source.stat().st_size,
                output_archive_bytes=(output / folder).stat().st_size)


def descriptor(root, platform, component, version, name, files):
    data = dict(format=1, component=component, platform=platform, version=version,
                identities={f: digest(root / f) for f in files})
    (root / name).write_text(json.dumps(data), encoding='utf-8')


def install_processing_package(package, root, platform):
    """Validate the exact package before writing into the private fixture."""
    with zipfile.ZipFile(package) as archive:
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        assert (manifest['component'], manifest['platform'], manifest['version']) == ('BookProcessing', platform, '3.0.0.14')
        entries = manifest['files']
        names = [item['path'] for item in entries]
        assert len(set(names)) == len(names)
        assert len(archive.namelist()) == len(names) + 1
        assert set(archive.namelist()) == set(names) | {'HomeLibRu.update.json'}
        for item in entries:
            name = item['path']
            assert name.startswith(('tools/python/', 'tools/bookconvert/'))
            assert '\\' not in name and ':' not in name and '..' not in Path(name).parts
            body = archive.read(name)
            assert len(body) == item['size'] and hashlib.sha256(body).hexdigest() == item['sha256']
        component = json.loads(archive.read('tools/bookconvert/MODULAR_RUNTIME.json'))
        assert 'tools/bookconvert/compression_preview.py' in component['required']
        for name, expected in component['identities'].items():
            assert name in names and hashlib.sha256(archive.read(name)).hexdigest() == expected
        for name in names:
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(name))


def legacy_gui_inputs(root, stage, platform):
    """Create actual old Packer output, then an updated book with one new image."""
    # Import only for this scenario: that fixture module captures native-worker
    # environment at import time, after the inspection runner sets its runtime.
    from test_prepare_book_compression import epub
    from test_pack_collection import illustrated_fb2, image_fixture
    original = {'one.fb2': illustrated_fb2(image_fixture()),
                'two.epub': epub(image_fixture())}
    source = root / 'legacy-input.zip'
    with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, body in original.items():
            archive.writestr(name, body)
    plan = root / 'legacy-plan.sqlite'
    with closing(sqlite3.connect(plan)) as db, db:
        db.executescript('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);'
            'CREATE TABLE books(book_id INTEGER PRIMARY KEY,source TEXT,member TEXT,locator TEXT,'
            'filename TEXT,ext TEXT,inside_no INTEGER);CREATE INDEX source_books ON books(source);')
        db.executemany('INSERT INTO metadata VALUES(?,?)', [('api', '1'), ('dataset', 'legacy-ui-history')])
        db.executemany('INSERT INTO books VALUES(?,?,?,?,?,?,?)', [
            (i, str(source), name, name, Path(name).stem, Path(name).suffix, i-1)
            for i, name in enumerate(original, 1)])
    output = root / 'old-packer-output'
    job = root / 'legacy-job.json'
    job.write_text(json.dumps(dict(version=1, dataset='legacy-ui-history', engine='illustrations-ppmd',
        images='maximum', plan=str(plan), output=str(output),
        seven_zip=str(root / 'tools/7zip/7za.exe'), tools_root=str(root / 'tools'))), encoding='utf-8')
    process = run_owned([str(root / 'tools/python/python.exe'), '-I', '-B', '-X', 'utf8',
        str(root / 'tools/bookconvert/pack_collection.py'), '--job', str(job)],
        capture_output=True, timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
    (stage / f'legacy-packer-{platform}.log').write_bytes(process.stdout + process.stderr)
    assert process.returncode == 0, 'Old Packer fixture failed: ' + process.stdout.decode('utf-8', errors='replace')
    prepared = [json.loads(line) for line in process.stdout.decode('utf-8').splitlines()
                if line.startswith('{') and json.loads(line).get('stage') == 'prepared']
    assert len(prepared) == 1 and prepared[0]['books'] == 2 and prepared[0]['image_books_optimized'] == 2
    generation = prepared[0]['generation']
    with closing(sqlite3.connect(output / 'generations' / generation / 'locations.sqlite')) as db:
        locations = db.execute('SELECT folder,filename,ext,inside_no FROM locations ORDER BY book_id').fetchall()
    assert len(locations) == 2 and locations[0][0] == locations[1][0]
    # A portable old collection can move as a whole. Its witnesses are relative
    # to the catalogue, so copy that complete old storage layout into this root.
    for folder in ('archives', 'generations'):
        shutil.copytree(output / folder, root / folder)
    for name in ('packing.sqlite', 'HomeLibRu-compressed.json'):
        shutil.copy2(output / name, root / name)
    old_archive = root / locations[0][0]
    bodies = [archive_body(old_archive, filename + extension, root / 'tools/7zip/7za.exe')
              for _, filename, extension, _ in locations]
    books = []
    for i, (location, body) in enumerate(zip(locations, bodies)):
        decoded = f'legacy-decoded-{i}{location[2]}'
        (root / decoded).write_bytes(body)
        books.append(dict(folder=location[0], filename=location[1], ext=location[2],
                          inside_no=location[3], decoded=decoded, sha256=hashlib.sha256(body).hexdigest()))
    state = dict(dataset='legacy-ui-history', engine='illustrations-ppmd', images='maximum',
                 generation=generation, source_catalog=str(root / 'original-catalogue.hlc2'), source_root=str(root))
    (root / 'legacy-compression-fixture.json').write_text(json.dumps(dict(state=state, books=books)), encoding='utf-8')
    changed = ET.fromstring(bodies[0])
    old_image = base64.b64decode(changed.find('{*}binary').text)
    changed.find('.//{*}p').text = 'New edition; keep the previously compressed picture.'
    ns = '{http://www.gribuser.ru/xml/fictionbook/2.0}'
    ET.SubElement(changed.find('.//{*}section'), ns + 'image', {'{http://www.w3.org/1999/xlink}href': '#new'})
    ET.SubElement(changed, ns + 'binary', {'id': 'new', 'content-type': 'image/png'}).text = base64.b64encode(image_fixture()).decode()
    watched = {path: digest(path) for path in (old_archive, root / 'packing.sqlite', root / 'HomeLibRu-compressed.json')}
    result = {'one.fb2': ET.tostring(changed, encoding='utf-8', xml_declaration=True),
              'two.epub': bodies[1], 'neighbor.fb2': b'Unselected neighbor must remain byte-exact.\x00\xff'}
    (root / 'compression-fixture.json').write_text(json.dumps(dict(first='one.fb2', second='two.epub',
        grayscale=False, profile_index=3, timeout_ms=90000)), encoding='utf-8')
    return result, watched, hashlib.sha256(old_image).hexdigest()


@contextmanager
def exclusive_recovery_owner(path):
    """Simulate another live preparation; never grant the child this handle."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x80000000, 0, None, 3, 0x00200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        if not kernel.CloseHandle(handle):
            raise ctypes.WinError(ctypes.get_last_error())


def sqlite_content_fingerprint(path):
    """Independent small-fixture check, insensitive to WAL/checkpoint layout."""
    def value(item):
        return {'blob': item.hex()} if isinstance(item, bytes) else item
    content = []
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as db:
        schema = db.execute('SELECT type,name,sql FROM sqlite_master ORDER BY type,name').fetchall()
        for kind, name, sql in schema:
            rows = []
            if kind == 'table':
                quoted = '"' + name.replace('"', '""') + '"'
                # Stable multiset comparison does not require app collations.
                rows = sorted(json.dumps([value(cell) for cell in row], ensure_ascii=True)
                              for row in db.execute('SELECT * FROM ' + quoted))
            content.append((kind, name, sql, rows))
    return hashlib.sha256(json.dumps(content, ensure_ascii=True).encode()).hexdigest()


@contextmanager
def later_update_personal_neighbour(root, enabled):
    if not enabled:
        yield
        return
    folder, = (root / 'Data/LibraryUpdateRecovery').glob('update-*')
    job = json.loads((folder / 'job.json').read_text(encoding='utf-8-sig'))
    personal = Path(job['system'])
    assert personal.resolve(strict=True).is_relative_to(root.resolve(strict=True))
    witness = '{' + str(uuid.uuid4()).upper() + '}'
    with closing(sqlite3.connect(personal)) as db:
        neighbour, = [row[0] for row in db.execute('SELECT DatabaseID,BaseName FROM Bases')
                      if row[1] == 'Untouched update neighbour']
        assert neighbour != job['collection']
        db.execute('CREATE TABLE IF NOT EXISTS CatalogCommitWitnesses(CollectionID INTEGER PRIMARY KEY,OperationID TEXT NOT NULL)')
        db.execute('INSERT OR REPLACE INTO CatalogCommitWitnesses VALUES(?,?)', (neighbour, witness))
        db.commit()
    yield
    with closing(sqlite3.connect(personal.as_uri() + '?mode=ro', uri=True)) as db:
        assert db.execute('SELECT OperationID FROM CatalogCommitWitnesses WHERE CollectionID=?',
                          (neighbour,)).fetchone() == (witness,), 'Recovery overwrote later personal data of another collection'


@contextmanager
def preserve_update_recovery(root, mode):
    if not mode:
        yield
        return
    proof_file = root / 'library-update-recovery-state.json'
    proof = json.loads(proof_file.read_text(encoding='utf-8-sig'))
    folders = list((root / 'Data/LibraryUpdateRecovery').glob('update-*'))
    assert len(folders) == 1
    folder = folders[0]
    job_file = folder / 'job.json'
    job = json.loads(job_file.read_text(encoding='utf-8-sig'))
    target, personal = Path(job['target']), Path(job['system'])
    backups = root / 'Data/LibraryUpdateBackups'
    backup = (backups / job['operation'] / 'destination.hlc2' if job['mode'] == 'bound'
              else backups / (job['operation'] + '.hlc2'))
    for path in (folder, target, personal, backup):
        assert not path.is_symlink() and path.resolve(strict=True).is_relative_to(root.resolve(strict=True))
    if mode == 'changed-catalogue':
        with closing(sqlite3.connect(target)) as db:
            # Alter the fixture's real catalogue table without substituting a
            # Python approximation for the app's locale-dependent collations.
            assert db.execute("UPDATE RecoveryGuardProbe SET Payload=X'4c61746572' WHERE ID='a'").rowcount == 1
            db.commit()
    elif mode == 'changed-backup':
        with closing(sqlite3.connect(backup)) as db:
            db.execute('CREATE TABLE LaterBackupData(Value TEXT)')
            db.execute("INSERT INTO LaterBackupData VALUES('Keep changed backup')")
            db.commit()
    elif mode in ('replaced-catalogue', 'replaced-profile'):
        path = target if mode == 'replaced-catalogue' else personal
        replacement = path.with_name(path.name + '.replacement-fixture')
        with closing(sqlite3.connect(path)) as source_db, closing(sqlite3.connect(replacement)) as copy_db:
            source_db.backup(copy_db)
        os.replace(replacement, path)
    elif mode == 'changed-journal':
        job['version'] = 2
        job_file.write_text(json.dumps(job), encoding='utf-8')
    else:
        assert mode == 'live-owner'
    proof['preserve'] = mode
    proof_file.write_text(json.dumps(proof), encoding='utf-8')
    before = {path: sqlite_content_fingerprint(path) for path in (target, personal)}
    protected = {path: digest(path) for path in folder.iterdir() if path.is_file()}
    protected[backup] = digest(backup)
    for name in ('archive', 'index', 'other'):
        path = Path(proof[name])
        assert digest(path) == proof[name + '_sha256']
        protected[path] = digest(path)
    guard = exclusive_recovery_owner(folder / 'active.lock') if mode == 'live-owner' else nullcontext()
    with guard:
        yield
    assert folder.is_dir(), 'Conflicted recovery moved its pending job'
    assert not (folder / 'done.json').exists(), 'Conflicted recovery acknowledged unsafe work'
    for path, fingerprint in before.items():
        assert sqlite_content_fingerprint(path) == fingerprint, f'Conflicted recovery changed {path}'
    for path, fingerprint in protected.items():
        assert digest(path) == fingerprint, f'Conflicted recovery changed protected {path}'


def run(binary, runtime, sqlite, icons, genres, stage, platform, mode, real_books=None, inspect_comparison=False,
        processing_package=None, estimate_first=False, whole=False, repeat_new=False, repeat_offer=False, images=None,
        scenario='selected-compression-ui', recovery_fault=None, recovery_preserve=None, refresh_index=False,
        legacy_history=False, packing_codec=None, packing_codec_release=None, reviewed_index=False, reviewed_bound=False,
        update_recovery_phase=None, update_recovery_bound=False, update_recovery_preserve=None,
        update_recovery_neighbour=False, update_recovery_compressed=False, reviewed_flibrary_bound=False):
    from test_pack_collection import illustrated_fb2, image_fixture
    assert bool(packing_codec) == bool(packing_codec_release), 'Codec archive and official release metadata must be paired'
    if packing_codec:
        assert scenario in ('packing-fbd', 'packed-jxl-formats', 'packed-flibrary-sidecars', 'reviewed-flibrary-compression'), 'Codec installation requires a native packing scenario'
    if reviewed_flibrary_bound:
        assert scenario == 'reviewed-flibrary-compression' and mode == 'apply'
    if reviewed_index or reviewed_bound:
        assert scenario == 'selected-compression-ui' and mode == 'apply'
        assert not any((legacy_history, recovery_fault, recovery_preserve, packing_codec))
    if recovery_fault:
        assert scenario == 'selected-compression-ui' and mode == 'apply' and not real_books
    if recovery_preserve:
        assert recovery_fault, 'Preservation checks require a real interrupted job'
    if update_recovery_phase or update_recovery_bound:
        assert scenario == 'library-update-recovery' and mode == 'apply' and not any((
            real_books, recovery_fault, recovery_preserve, legacy_history, packing_codec))
    if scenario == 'library-update-recovery':
        assert update_recovery_phase, 'Select the actual update termination boundary'
    if update_recovery_compressed:
        assert update_recovery_phase and not update_recovery_preserve, 'Compressed recovery needs an actual non-conflict update crash'
    if update_recovery_preserve:
        assert update_recovery_phase == 'catalogue-committed', 'Conflict checks require a catalogue-only commit'
    if update_recovery_neighbour:
        assert update_recovery_phase and not update_recovery_preserve
    with temporary_work_directory(stage, 'HomeLibRu-native-') as root:
        root = Path(root)
        if update_recovery_phase:
            (root / 'library-update-recovery-request.json').write_text(json.dumps(dict(
                phase=update_recovery_phase, bound=update_recovery_bound, compressed=update_recovery_compressed)), encoding='utf-8')
        shutil.copy2(binary, root / 'CollectionViewsTest.exe')
        shutil.copy2(sqlite, root / 'sqlite3.dll')
        (root / 'Icons').mkdir()
        shutil.copy2(icons, root / 'Icons' / 'MHLIcons.dll')
        shutil.copy2(genres, root / 'genres_fb2.glst')
        shutil.copytree(runtime / 'tools', root / 'tools')
        repo = Path(__file__).resolve().parents[2]
        if images:
            info = json.loads((images / 'RUNTIME.json').read_text(encoding='utf-8-sig'))
            assert info['platform'] == platform
            assert info['source_sha256'] == digest(repo / 'Utils/HomeLibXps/HomeLibXps.cs')
            assert info['sha256'] == digest(images / 'HomeLibImages.exe')
            assert not (root / 'tools/images/HomeLibImages.exe.config').exists()
            shutil.copytree(images, root / 'tools/images', dirs_exist_ok=True)
        if processing_package:
            install_processing_package(processing_package, root, platform)
        else:
            for file in ('prepare_book_compression.py', 'archive_replacement.py', 'pack_collection.py', 'compression_preview.py',
                         'estimate_book_compression.py'):
                shutil.copy2(repo / 'tools/collectionpack' / file, root / 'tools/bookconvert' / file)
        for marker in ('uselocaldata', 'uselocaltemp'):
            (root / marker).touch()
        if refresh_index:
            assert mode == 'apply' and not recovery_fault
            (root / 'compression-refresh.marker').touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        # This fixture tests compression, not public update checks or metadata
        # downloads. Keep unrelated network work out of timing and UI focus.
        (root / 'myhomelib2.ini').write_text(
            '[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[BEHAVIOR]\nAutoLoadReview=0\nShowCover=0\nShowAnnotation=0\n'
            '[INTERFACE]\nWindowsDarkThemeOfferDismissed=1\n', encoding='utf-8')
        if not processing_package:
            descriptor(root, platform, 'BookProcessing', '3.0.0.14', 'tools/bookconvert/MODULAR_RUNTIME.json', [
            'tools/python/python.exe', 'tools/python/python313.dll', 'tools/python/python313.zip',
            'tools/python/python313._pth', 'tools/bookconvert/convert_book.py', 'tools/bookconvert/MODULAR_API.txt',
            'tools/bookconvert/pack_collection.py', 'tools/bookconvert/image_quality.py',
            'tools/bookconvert/catalogdump/build_index.py', 'tools/bookconvert/catalogdump/mysql_dump.py',
            'tools/bookconvert/prepare_book_compression.py', 'tools/bookconvert/archive_replacement.py',
                'tools/bookconvert/compression_preview.py', 'tools/bookconvert/estimate_book_compression.py'])
        descriptor(root, platform, 'ImageProcessing', '3.0.0.14', 'tools/images/COMPONENT.json', [
            'tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt'])
        originals = {'one.fb2': illustrated_fb2(image_fixture(True)),
                     'two.fb2': illustrated_fb2(image_fixture(False)).replace(b'this text', b'the second text'),
                     'neighbor.fb2': b'Unselected neighbor must remain byte-exact.\x00\xff'}
        if (reviewed_index or reviewed_bound) and not real_books:
            from test_prepare_book_compression import epub
            originals = {'one.fb2': illustrated_fb2(image_fixture()), 'two.epub': epub(image_fixture()),
                         'neighbor.fb2': originals['neighbor.fb2']}
            (root / 'compression-fixture.json').write_text(json.dumps(dict(
                first='one.fb2', second='two.epub', grayscale=False, timeout_ms=90000)), encoding='utf-8')
        if reviewed_index:
            (root / 'reviewed-compression.marker').write_text('1', encoding='ascii')
        if reviewed_bound:
            (root / 'bound-compression.marker').write_text('1', encoding='ascii')
        if reviewed_flibrary_bound:
            (root / 'reviewed-flibrary-bound.marker').write_text('1', encoding='ascii')
        real_stamps = {}
        if scenario == 'packing-fbd':
            assert not any((real_books, legacy_history, recovery_fault, refresh_index))
            (root / 'packing-inpx-illustration.fb2').write_bytes(
                jpeg_xl_inpx_fixture() if packing_codec else illustrated_fb2(image_fixture()))
        if scenario == 'packed-jxl-formats':
            from packing_format_fixtures import fixtures
            assert packing_codec and not any((real_books, legacy_history, recovery_fault, refresh_index))
            inputs, format_manifest = fixtures()
            originals = {**inputs, 'neighbor.fb2': originals['neighbor.fb2']}
            (root / 'packing-jxl-formats.json').write_text(json.dumps(format_manifest), encoding='utf-8')
        if packing_codec:
            release = json.loads(packing_codec_release.read_text(encoding='utf-8-sig'))
            arch = 'x64' if platform == 'Win64' else 'x86'
            asset, = [asset for asset in release['assets'] if asset['name'] == f'jxl-{arch}-windows-static.zip']
            assert asset['digest'] == 'sha256:' + digest(packing_codec)
            assert asset['size'] == packing_codec.stat().st_size
            shutil.copy2(packing_codec, root / 'official-jxl.zip')
            shutil.copy2(packing_codec_release, root / 'official-jxl-release.json')
        sidecar_inputs = None
        if scenario in ('packed-flibrary-sidecars', 'reviewed-flibrary-compression'):
            from packing_flibrary_fixtures import build
            assert packing_codec and not any((real_books, legacy_history, recovery_fault, refresh_index))
            sidecar_inputs = build(root, root / 'tools/7zip/7za.exe', repo, reviewed=scenario == 'reviewed-flibrary-compression')
        if scenario == 'packed-catalogue-sizes':
            from test_prepare_book_compression import epub
            assert not any((real_books, legacy_history, recovery_fault, refresh_index))
            originals = {'one.fb2': illustrated_fb2(image_fixture()), 'two.epub': epub(image_fixture()),
                         'neighbor.fb2': originals['neighbor.fb2']}
        legacy_stamps, legacy_image_hash = {}, None
        if legacy_history:
            assert mode == 'apply' and scenario == 'selected-compression-ui' and not any((real_books,
                inspect_comparison, estimate_first, whole, repeat_new, repeat_offer, recovery_fault, refresh_index))
            assert processing_package, 'Legacy GUI must use the exact BookProcessing package'
            originals, legacy_stamps, legacy_image_hash = legacy_gui_inputs(root, stage, platform)
        if real_books:
            manifest = json.loads(real_books.read_text(encoding='utf-8-sig'))
            assert set(manifest) == {'one.fb2', 'two.epub', 'neighbor.fb2'}
            originals = {}
            for name, spec in manifest.items():
                path = Path(spec['archive']).resolve(strict=True)
                info = path.stat()
                real_stamps[path] = (info.st_ino, info.st_size, info.st_mtime_ns)
                with zipfile.ZipFile(path) as archive:
                    assert archive.getinfo(spec['member']).file_size <= 128 * 1024 * 1024
                    originals[name] = archive.read(spec['member'])
            (root / 'compression-fixture.json').write_text(json.dumps(dict(
                first='one.fb2', second='two.epub', grayscale=False, timeout_ms=300000,
                inspect_comparison=inspect_comparison)), encoding='utf-8')
        selected = [name for name in originals if name != 'neighbor.fb2']
        if inspect_comparison and not real_books:
            (root / 'compression-fixture.json').write_text(json.dumps(dict(
                first='one.fb2', second='two.fb2', grayscale=True, timeout_ms=90000,
                inspect_comparison=True)), encoding='utf-8')
        if estimate_first or whole or repeat_new or repeat_offer or recovery_fault:
            fixture_file = root / 'compression-fixture.json'
            config = json.loads(fixture_file.read_text(encoding='utf-8')) if fixture_file.exists() else {}
            config['estimate_first'] = estimate_first
            config['whole'] = whole
            config['repeat_new'] = repeat_new
            config['repeat_offer'] = repeat_offer
            if recovery_fault:
                config['recovery_fault'] = recovery_fault
            fixture_file.write_text(json.dumps(config), encoding='utf-8')
        (root / 'books').mkdir()
        source = root / 'books/shared.zip'
        with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, body in originals.items():
                archive.writestr(name, body)
        (root / 'conversion-fixtures').mkdir()
        conversion_fb2 = originals.get('one.fb2')
        if conversion_fb2 is None:
            conversion_fb2 = illustrated_fb2(image_fixture(True))
        (root / 'conversion-fixtures/source.fb2').write_bytes(conversion_fb2)
        before, size = digest(source), source.stat().st_size
        started = time.monotonic()
        startup = None
        if inspect_comparison:
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 5
        # Keep the native log while it runs. A hard outer deadline must not
        # discard the only evidence explaining where the private GUI stopped.
        # The real-book fixture itself allows 300 s *after* its application
        # bootstrap; leave separate room for bootstrap and orderly teardown.
        deadline = 420 if real_books or refresh_index or reviewed_index or reviewed_bound or scenario in ('packing-fbd', 'packed-jxl-formats', 'packed-flibrary-sidecars', 'reviewed-flibrary-compression',
            'compression-continuation', 'library-update-sources', 'library-update-apply', 'library-update-cancel', 'library-update-window', 'catalog-merge-outcome', 'library-update-recovery') else 150
        attempt = dict(status='INCOMPLETE', platform=platform, mode=mode,
            native_binary_sha256=digest(binary), outer_timeout_seconds=deadline,
            refresh_index=refresh_index, reviewed_index=reviewed_index, reviewed_bound=reviewed_bound,
            legacy_history=legacy_history,
            private_runtime=str(root),
            real_source_stamps={str(path): stamp for path, stamp in real_stamps.items()})
        attempt_file = stage / f'catalogue-{platform}-{mode}-attempt.json'
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        log_path = stage / f'catalogue-{platform}-{mode}.log'
        env = {**os.environ, 'TEMP': str(root), 'TMP': str(root),
               'LOCALAPPDATA': str(root / 'Local'), 'APPDATA': str(root / 'Roaming')}
        if scenario == 'packing-fbd':
            env['HOMELIB_PACKED_RESULT_COMPONENTS'] = '1'
        try:
            with log_path.open('wb') as log:
                command = [str(root / 'CollectionViewsTest.exe'), scenario]
                if scenario == 'selected-compression-ui':
                    command.append(mode)
                process = run_owned(command,
                    cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, startupinfo=startup, timeout=deadline,
                    creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS |
                        (0 if inspect_comparison else subprocess.CREATE_NO_WINDOW))
                if update_recovery_phase:
                    assert process.returncode == 73, 'Actual update did not terminate at its requested boundary'
                    assert (root / 'library-update-recovery-crash.txt').read_text(encoding='utf-8-sig') == update_recovery_phase
                    attempt.update(status='RECOVERING_UPDATE', crash_returncode=process.returncode,
                                   update_recovery_phase=update_recovery_phase, update_recovery_bound=update_recovery_bound)
                    attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
                    with later_update_personal_neighbour(root, update_recovery_neighbour), preserve_update_recovery(root, update_recovery_preserve):
                        process = run_owned([str(root / 'CollectionViewsTest.exe'), 'library-update-recovery-open'],
                            cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, startupinfo=startup, timeout=deadline,
                            creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS | subprocess.CREATE_NO_WINDOW)
                if scenario == 'packing-fbd' and process.returncode == 0:
                    argument = (root / 'packing-inpx-result.argument').read_text(encoding='ascii').strip()
                    assert argument.startswith('--resume-collection-packing=') and '\n' not in argument
                    process = run_owned([str(root / 'CollectionViewsTest.exe'), 'packing-inpx-result-child', argument],
                        cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, startupinfo=startup, timeout=120,
                        creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS | subprocess.CREATE_NO_WINDOW)
                if recovery_fault:
                    assert process.returncode == 73, 'Actual compression did not terminate at its requested durable stage'
                    assert (root / 'compression-recovery-crash.txt').read_text(encoding='utf-8-sig') == recovery_fault
                    attempt.update(status='RECOVERING_AFTER_CRASH', crash_returncode=process.returncode,
                                   recovery_fault=recovery_fault)
                    attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
                    guard = nullcontext()
                    if recovery_preserve:
                        proof_file = root / 'compression-recovery-state.json'
                        proof = json.loads(proof_file.read_text(encoding='utf-8-sig'))
                        work_root = Path(proof['work_root']).resolve(strict=True)
                        assert work_root.is_relative_to(root.resolve(strict=True))
                        folders = list(work_root.glob('prepare-*'))
                        assert len(folders) == 1 and not folders[0].is_symlink()
                        if recovery_preserve == 'foreign-file':
                            kept = folders[0] / 'unrelated.txt'
                            kept.write_bytes(b'Keep unrelated preparation data')
                        elif recovery_preserve == 'foreign-marker':
                            kept = folders[0] / 'owner.txt'
                            kept.write_bytes(b'This is a different owner')
                        else:
                            assert recovery_preserve == 'live-owner'
                            # The approved transaction adopts its candidate into
                            # the durable journal. Check cleanup against a file
                            # that successful application does not consume.
                            kept = folders[0] / 'report.json'
                            guard = exclusive_recovery_owner(folders[0] / 'owner.txt')
                        proof['preserved_work'] = dict(mode=recovery_preserve, path=str(kept), sha256=digest(kept))
                        proof_file.write_text(json.dumps(proof), encoding='utf-8')
                    with guard:
                        process = run_owned([str(root / 'CollectionViewsTest.exe'), 'compression-recovery-open'],
                            cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, startupinfo=startup, timeout=deadline,
                            creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS | subprocess.CREATE_NO_WINDOW)
        except subprocess.TimeoutExpired:
            notes = []
            for p in root.rglob('*.json'):
                if 'tools' not in p.relative_to(root).parts and p.stat().st_size < 32768:
                    notes.append(str(p.relative_to(root)) + '\n' + p.read_text(encoding='utf-8-sig', errors='replace'))
            (stage / f'catalogue-{platform}-{mode}-diagnostics.txt').write_text('\n'.join(notes), encoding='utf-8')
            attempt.update(status='TIMEOUT', seconds=round(time.monotonic()-started, 3),
                originals_unchanged=all((path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) == stamp
                    for path, stamp in real_stamps.items()))
            attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
            raise
        output = log_path.read_text(encoding='utf-8', errors='replace')
        expected = {
            'library-update-recovery': f'PASS actual library update crash and ordinary startup recovery {update_recovery_phase} bound={update_recovery_bound}',
            'library-update-window': 'PASS library update menu and toolbar run reviewed confirmation, keep declined data, refresh the actual book view and offer incremental compression; both theme glyphs remain available',
            'catalog-merge-outcome': 'PASS catalog source window distinguishes rolled-back merges from committed errors and signals main-view refresh',
            'library-update-cancel': 'PASS reviewed update cancellation rolls back before commit, finishes late saves, protects rollback and retains published baselines after post-commit errors',
            'library-update-apply': 'PASS reviewed whole update keeps literal metadata personal data favourites and roots, skips missing members, continues the same index and retains removed books as excluded',
            'library-update-sources': 'PASS source settings window edits, persists stable bindings, checks a frozen local index, exports, reviews disabled legacy templates and survives collection rename',
            'selected-compression-ui': f'PASS selected compression normal catalogue {mode}',
            'explorer-file-drop': 'PASS Explorer import offers compression only after accepted imports',
            'update-outcomes': 'PASS actual INPX and Metabib menus offer compression after commit',
            'packed-catalogue-sizes': 'PASS packed publication and actual INPX retain book copy and personal sizes without originals',
            'packing-fbd': 'PASS original FBD container, both native locator forms, exact book and descriptor, reuse without originals',
            'packed-jxl-formats': 'PASS native JPEG XL PDF exact bytes and EPUB complete resources reading and retention without originals',
            'reviewed-flibrary-compression': 'PASS FLibrary external JPEG XL covers and pictures survive actual compression reviewed full append and repeated new-only selection with measured sizes text and personal data',
            'packed-flibrary-sidecars': 'PASS FLibrary sidecar books preserve raw bytes, restored resources and covers through packing and reuse',
            'compression-continuation': 'PASS compression continuation restores exact selected, collection and new-book options through actual main-window startup',
        }[scenario]
        if recovery_fault:
            expected = 'PASS actual compression crash and ordinary startup recovery ' + recovery_fault
        expected_lines = [expected]
        if update_recovery_preserve:
            expected_lines = ['PASS actual library update startup retains conflicting data ' + update_recovery_preserve]
        if scenario == 'library-update-window':
            expected_lines.append('PASS reviewed update missing-member report previews bounded details and saves complete archive/member reasons after decline or apply')
        if scenario == 'library-update-cancel':
            expected_lines.append('PASS reviewed update commit witnesses are paired with catalogue and personal transactions, roll back on early errors and remain isolated by collection')
            expected_lines.append('PASS missing catalogue and system properties return empty instead of reusing a previous value')
        if scenario == 'library-update-apply':
            expected_lines.append('PASS missing new copies wait for download without phantom links and removed retained copies stay excluded while another source remains preferred')
            expected_lines.append('PASS deleted retained cards stay excluded after offline replacement while never-added missing books can arrive later')
            expected_lines.append('PASS retained download deletions survive missing 7z restoration in whole bound full and bound append updates')
            expected_lines.append('PASS publisher recovery reads saved INPX and Metabib independently of the new input format and rolls back canceled recovery imports')
            expected_lines.append('PASS legacy publisher locations recover from a verified saved index outside the original root, survive both roots offline and repeat, and reject a changed saved input without touching the catalogue')
            expected_lines.append('PASS reviewed ZIP names retain actual 7z source links and publisher locations across offline roots, excluded returns and downloaded 7z members')
            expected_lines.append('PASS reviewed bound-source update adds downloaded books with its original root offline and preserves source priorities, personal fields and exclusions')
            expected_lines.append('PASS reviewed update accepts only new archives with its original book root offline, retains historical cards and personal data, preserves exclusions and rejects unavailable download roots')
            expected_lines.append('PASS shared-source profiles use the latest applied baseline across append, omission, deletion and profile removal, retain immutable caches and refuse a missing authoritative baseline')
            expected_lines.append('PASS reviewed merged-source update preserves priorities personal data and removed copies, adds verified members from a second root and repeats without duplicate cards')
            expected_lines.append('PASS reviewed updates retain exclusions across omitted indexes, distinguish publisher omissions and roll back catalogues personal fields source links and baseline publication on a late failure')
        if scenario == 'library-update-sources':
            expected_lines += [
                'PASS legacy library updates request individual and default URLs, keep individual URLs with no global server, reset stale versions and reject HTTP errors',
                'PASS update review reads INPX and Metabib, separates historical missing archives, resolves downloaded 7z, diagnoses same names and library mismatches, rejects corrupt input and preserves live catalogues',
                'PASS update review detects same-archive date changes, excludes deleted placeholders, reports partial input and rolls back canceled inspection',
            ]
        if scenario == 'compression-continuation':
            expected_lines.append('PASS compression continuation rejects replay, wrong token, collection or reused book, changed archive and malformed choices')
            expected_lines.extend('PASS normal startup restored and canceled compression scope ' + str(scope) for scope in range(3))
        if scenario in ('packed-flibrary-sidecars', 'reviewed-flibrary-compression'):
            expected_lines.append('PASS official JPEG XL encoder installs separately from the reading component')
        if scenario == 'packed-jxl-formats':
            expected_lines += [
                'PASS official JPEG XL encoder installs separately from the reading component',
                'PASS native JPEG XL EPUB text-only export works without its decoder and cannot replace full-image preparation',
            ]
        if scenario == 'packing-fbd':
            expected_lines += [
                'PASS loose book does not grow and remains readable after retention without its original',
                'PASS alternate copies with empty and NULL extensions survive packing and reuse without originals',
                'PASS packing estimate review, cancellation, continuation and separate registration',
                'PASS unavailable books remain in the catalogue, download into the copy, and become packable later',
                'PASS empty archived book cannot be exported and becomes packable when the source is restored',
                'PASS packing restart restores selected INPX and profile once and rejects changed inputs',
                'PASS native packed INPX reuses the profile and opens the optimized FB2',
                'PASS last INPX search in a packed catalogue selects only the new records',
                'PASS selected INPX adds and replaces exact books, retains prior archives and IDs, and publishes a separate generation',
                'PASS an empty INPX replacement retains the previously readable book',
                'PASS selected INPX estimate cancels and continues, and legacy full import refuses a packed catalogue',
                'PASS packed INPX result opens only new books from the registered generation',
            ]
            if packing_codec:
                expected_lines += [
                    'PASS official JPEG XL encoder installs separately from the reading component',
                    'PASS native INPX retains the JPEG XL profile and reconstructs every image exactly',
                ]
        if refresh_index:
            expected_lines.extend([
                'PASS actual full INPX refresh keeps verified compressed sizes and personal progress',
                'PASS eleven compressed-size boundaries preserve physical identity and rollback',
                'PASS ten compressed-copy boundaries preserve independent physical witnesses nullable locators and rollback',
            ])
        if refresh_index or reviewed_index:
            expected_lines.append('PASS reviewed full and append updates retain actual compressed sizes history and Reader payloads without originals and incrementally compress only the new downloaded book')
        if reviewed_bound:
            expected_lines.append('PASS bound reviewed full and append updates preserve actual compressed copy sizes payloads priorities and personal fields')
            expected_lines.append('PASS bound reviewed update incrementally compresses one new download and preserves all five processed physical members across either source')
            expected_lines.append('PASS bound measured-size updates preserve the existing personal card and roll back both stores if the size write fails')
        if scenario == 'reviewed-flibrary-compression':
            expected_lines.append('PASS FLibrary new external-image download compresses alone and retains old physical copies across full append and preferred-source updates')
        if update_recovery_compressed:
            expected_lines.append('PASS compressed source copies recover actual payloads sizes personal cards and witnesses then resume only the unprocessed new book')
        if legacy_history:
            expected_lines.append('PASS normal catalogue migrated legacy FB2 EPUB history without rewriting archive')
        if process.returncode or any(line not in output for line in expected_lines):
            # Keep only bounded text diagnostics; do not retain the runtime or books.
            notes = []
            for p in root.rglob('*.json'):
                if 'tools' not in p.relative_to(root).parts and p.stat().st_size < 32768:
                    notes.append(str(p.relative_to(root)) + '\n' + p.read_text(encoding='utf-8-sig', errors='replace'))
            (stage / f'catalogue-{platform}-{mode}-diagnostics.txt').write_text('\n'.join(notes), encoding='utf-8')
            attempt.update(status='FAIL', returncode=process.returncode,
                seconds=round(time.monotonic()-started, 3),
                originals_unchanged=all((path.stat().st_ino, path.stat().st_size, path.stat().st_mtime_ns) == stamp
                    for path, stamp in real_stamps.items()))
            attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
            raise AssertionError(f'Catalogue {platform} {mode}: exit {process.returncode}\n{output}')
        if scenario != 'selected-compression-ui':
            assert not real_books, 'Event fixtures must not borrow real collection books'
            assert digest(source) == before, 'Import/update offer changed an unrelated shared ZIP'
            publication = {}
            text_repack = verify_text_only_repack(root) if scenario == 'packed-jxl-formats' else None
            if scenario == 'packed-catalogue-sizes':
                output_root = root / 'packed-size-output'
                catalogues = list(output_root.glob('*.hlc2'))
                assert len(catalogues) == 2, 'Publication and its INPX update must both retain their own catalogue'
                retained = {}
                for catalogue in catalogues:
                    sizes = {}
                    with closing(sqlite3.connect(catalogue.as_uri() + '?mode=ro', uri=True)) as db:
                        rows = db.execute('SELECT BookID,LibID,Folder,FileName,Ext,BookSize FROM Books '
                                          "WHERE LibID COLLATE BINARY IN ('101','102')").fetchall()
                        assert len(rows) == 2
                        for book_id, lib_id, folder, filename, ext, size in rows:
                            name = 'one.fb2' if str(lib_id) == '101' else 'two.epub'
                            body = archive_body(output_root / folder, filename + ext, root / 'tools/7zip/7za.exe')
                            assert size == len(body) < len(originals[name]), (catalogue.name, name, size, len(body))
                            old, new = root / ('before-' + name), root / ('after-' + name)
                            old.write_bytes(originals[name]); new.write_bytes(body)
                            verify_non_image_content(old, new, ext)
                            book_hash = hashlib.sha256(body).hexdigest()
                            assert retained.setdefault(name, book_hash) == book_hash, 'INPX changed retained book bytes'
                            sizes[name] = size
                            for copy_size, in db.execute('SELECT BookSize FROM CatalogBookCopies WHERE BookID=?', (book_id,)):
                                assert copy_size == size, 'Alternate copy size differs from the actual book'
                    publication[catalogue.name] = sizes
            return dict(status='PASS', platform=platform, mode=mode, scenario=scenario,
                        seconds=round(time.monotonic()-started, 3),
                        native_binary_sha256=digest(binary),
                        processing_package_sha256=digest(processing_package) if processing_package else None,
                        packing_codec_sha256=digest(packing_codec) if packing_codec else None,
                        packing_codec_version=release['tag_name'] if packing_codec else None,
                        image_helper_sha256=digest(root / 'tools/images/HomeLibImages.exe'),
                        private_runtime=str(root), real_source_stamps={},
                        packed_catalogue_sizes=publication,
                        text_only_repack=text_repack,
                        flibrary_sidecar_inputs=sidecar_inputs,
                        update_recovery_neighbour_preserved=update_recovery_neighbour,
                        update_recovery_compressed=update_recovery_compressed,
                        reviewed_flibrary_bound=reviewed_flibrary_bound,
                        unrelated_archive_unchanged=True, native_log=str(log_path),
                        scope=('Actual update process termination and ordinary data-module/main startup recovery, bound=' + str(update_recovery_bound) + ', compressed=' + str(update_recovery_compressed) + ', phase=' + str(update_recovery_phase) + ', conflict=' + str(update_recovery_preserve) + '; recovery checks catalogue/personal data, favourites, actual archive members and repeated acknowledgment; conflict cases stop at the data module and independently compare all persisted catalogue/personal rows, inputs, backup and journal; private fixtures'
                               if scenario == 'library-update-recovery' else
                               'Native catalogue-source preview/apply controls and worker: success, pre-commit failure, first-store restoration and post-commit error; small private catalogues, durable change flag for main refresh, no process-death proof'
                               if scenario == 'catalog-merge-outcome' else
                               'Actual main collection menu and toolbar, source-window review and apply controls, progress window, prepared worker confirmation, declined/committed views and incremental-compression offer; theme glyphs, private ZIP/INPX fixture, automatic confirmation answer'
                               if scenario == 'library-update-window' else
                               'Native full and bound-source update cancellation at row writes, pre-commit, commit start, first-store commit and completion, including forced cancellation during rollback and post-commit errors; private fixtures, no process-death proof'
                               if scenario == 'library-update-cancel' else
                               'Native reviewed whole and merged-source updates on small private ZIP/INPX fixtures: metadata, personal data, priorities, shared-profile baselines, append/omission/exclusion continuity, offline original roots, exact member availability, separate download root, same-index continuation and late SQL-failure rollback; no production-scale or packed/online application gate'
                               if scenario == 'library-update-apply' else
                               'Native source settings and INPX/Metabib review, archive names/roots, date changes, deleted and malformed rows, cancellation, unchanged live catalogues, actual legacy individual/default HTTP version requests, rename and theme/DPI layout; no update application'
                               if scenario == 'library-update-sources' else
                               'Native full packed-copy publication and actual INPX update without originals; '
                               'catalogue, personal card and alternate-copy sizes, legacy/unknown sizes and invalid-size rejection'
                               if scenario == 'packed-catalogue-sizes' else
                               'Native JPEG XL PDF byte-exact read/preparation, EPUB all resources/text/images, '
                               'catalogue/personal sizes and retention without originals; private generated fixtures'
                               if scenario == 'packed-jxl-formats' else
                               'Native FLibrary external-image compression followed by reviewed full and append INPX, a new external-image download and incremental compression, restored text/resource/cover verification, measured sizes, personal data, repeated new-only selection, bound=' + str(reviewed_flibrary_bound) + '; private generated fixtures'
                               if scenario == 'reviewed-flibrary-compression' else
                               'Native original FLibrary ZIP/nested-7z EPUB and FB2 sidecar reading, cover preview, '
                               'exact resource/archive retention and personal data without originals; generated fixtures'
                               if scenario == 'packed-flibrary-sidecars' else
                               'Compression continuation identity/option validation and actual main-window restart/review cancel '
                               'for selected, collection and new-book scopes; component transport is a separate gate'
                               if scenario == 'compression-continuation' else
                               'Native FBD/loose/alternate retention without originals, unavailable-book restoration, '
                               'estimate dialog and INPX continuation through an actual main window; synthetic books'
                               if scenario == 'packing-fbd' else
                               'Native normal INPX/Metabib menu or Windows Shell import on a private synthetic catalogue; no real user data'))
        attempt.update(status='VERIFYING_CONTENT', native_returncode=process.returncode)
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        with zipfile.ZipFile(source) as archive:
            assert set(archive.namelist()) == set(originals)
            assert archive_body(source, 'neighbor.fb2', root / 'tools/7zip/7za.exe') == originals['neighbor.fb2']
            if mode == 'apply' and recovery_fault not in {'preparation-ready', 'receipt-prepared', 'binding-prepared'}:
                assert source.stat().st_size < size
                for name in selected:
                    body = archive_body(source, name, root / 'tools/7zip/7za.exe')
                    if name.endswith('.epub'):
                        before_file, after_file = root / 'original.epub', root / 'result.epub'
                        before_file.write_bytes(originals[name]); after_file.write_bytes(body)
                        verify_non_image_content(before_file, after_file, '.epub')
                        # Independently assert every textual/style/font member.
                        with zipfile.ZipFile(before_file) as old, zipfile.ZipFile(after_file) as new:
                            assert old.namelist() == new.namelist()
                            for member in old.namelist():
                                if Path(member).suffix.lower() in {'.xhtml', '.html', '.htm', '.css', '.ttf', '.otf', '.woff', '.woff2', '.ncx'}:
                                    assert old.read(member) == new.read(member), member
                        continue
                    original = ET.fromstring(originals[name])
                    result = ET.fromstring(body)
                    if legacy_history and name == 'one.fb2':
                        old_picture = result.find('{*}binary')
                        assert hashlib.sha256(base64.b64decode(old_picture.text)).hexdigest() == legacy_image_hash
                    # Full semantic text/formatting except deliberate image bytes.
                    for tree in (original, result):
                        for node in tree.iter('{http://www.gribuser.ru/xml/fictionbook/2.0}binary'):
                            node.text = ''
                            # PNG may deliberately become JPEG in the economy
                            # profile; identifiers/references must stay intact.
                            node.attrib.pop('content-type', None)
                    assert ET.tostring(original) == ET.tostring(result), name
            else:
                assert digest(source) == before
        backups = list((root / 'originals').glob('*.zip'))
        if mode == 'apply' and recovery_fault != 'preparation-ready':
            assert len(backups) == 1
            with zipfile.ZipFile(backups[0]) as backup:
                assert set(backup.namelist()) == {'HomeLibre-originals.json'} | {'books/' + name for name in selected}
                for name in selected:
                    assert backup.read('books/' + name) == originals[name]
        else:
            assert not backups
        for path, stamp in real_stamps.items():
            info = path.stat()
            assert (info.st_ino, info.st_size, info.st_mtime_ns) == stamp, 'Real source archive changed'
        assert all(digest(path) == stamp for path, stamp in legacy_stamps.items()), 'Old archive or journal changed'
        attempt.update(status='PASS', returncode=process.returncode,
            seconds=round(time.monotonic()-started, 3), originals_unchanged=True)
        attempt_file.write_text(json.dumps(attempt, indent=2), encoding='utf-8')
        return dict(status='PASS', platform=platform, mode=mode, seconds=round(time.monotonic()-started, 3),
                    before_bytes=size, after_bytes=source.stat().st_size, native_binary_sha256=digest(binary),
                    processing_package_sha256=digest(processing_package) if processing_package else None,
                    input_sha256={name: hashlib.sha256(body).hexdigest() for name, body in originals.items()},
                    real_source_stamps={str(path): stamp for path, stamp in real_stamps.items()},
                    whole=whole,
                    repeat_new=repeat_new,
                    repeat_offer=repeat_offer,
                    refresh_index=refresh_index, reviewed_index=reviewed_index, reviewed_bound=reviewed_bound,
                    legacy_history=legacy_history,
                    recovery_fault=recovery_fault,
                    recovery_preserve=recovery_preserve,
                    private_runtime=str(root),
                    image_helper_sha256=digest(root / 'tools/images/HomeLibImages.exe'),
                    scope=('Reviewed bound-source full/append INPX after real compression: two physical copies, measured catalogue/personal/copy sizes, priority, one new download and injected rollback; private FB2/EPUB fixtures'
                           if reviewed_bound else
                           'Ordinary menu compression, reviewed full/append INPX without originals, preserved measured sizes/history, one downloaded arrival and 0/1/0 incremental selection; private fixtures'
                           if reviewed_index or refresh_index else
                           'Ordinary catalogue command; real payloads in a private shared ZIP, original archives read only'
                           if real_books else 'Ordinary menu action and controls; isolated synthetic shared ZIP only'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'runtime', 'sqlite', 'icons', 'genres', 'stage'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--mode', choices=['apply', 'skip', 'stop', 'estimate'], required=True)
    parser.add_argument('--real-books', type=Path)
    parser.add_argument('--inspect-comparison', action='store_true')
    parser.add_argument('--processing-package', type=Path)
    parser.add_argument('--estimate-first', action='store_true')
    parser.add_argument('--whole', action='store_true')
    parser.add_argument('--repeat-new', action='store_true', help='After applying, invoke the normal new-books menu and verify no preparation')
    parser.add_argument('--scenario', choices=['selected-compression-ui', 'explorer-file-drop', 'update-outcomes', 'library-update-sources', 'library-update-apply', 'library-update-cancel', 'library-update-window', 'catalog-merge-outcome', 'library-update-recovery',
                        'packed-catalogue-sizes', 'packing-fbd', 'packed-jxl-formats', 'packed-flibrary-sidecars', 'reviewed-flibrary-compression', 'compression-continuation'], default='selected-compression-ui')
    parser.add_argument('--packing-codec', type=Path, help='Exact official JPEG XL archive for the native packed INPX installer/reader scenario')
    parser.add_argument('--packing-codec-release', type=Path, help='Official GitHub release metadata used to verify the codec archive')
    parser.add_argument('--repeat-offer', action='store_true', help='Exercise nonmodal arrivals offer, dismissal, canceled options and explicit start')
    parser.add_argument('--images', type=Path, help='Fresh image helper verified against the current C# source')
    parser.add_argument('--recovery-fault', choices=['job-published', 'file-committed', 'catalogue-committed',
                        'personal-committed', 'completed-published', 'file-journal-forgotten',
                        'preparation-ready', 'receipt-prepared', 'binding-prepared'],
                        help='Terminate the guarded test process at a durable compression stage, then restart ordinary Main')
    parser.add_argument('--recovery-preserve', choices=['foreign-file', 'foreign-marker', 'live-owner'],
                        help='Verify recovery retains foreign or externally leased preparation data')
    parser.add_argument('--update-recovery-phase', choices=['journal-published', 'rows-written', 'before-commit',
                        'commit-start', 'catalogue-committed', 'stores-committed'],
                        help='Terminate an actual reviewed update then enter ordinary startup recovery')
    parser.add_argument('--update-recovery-bound', action='store_true', help='Use a bound merged-catalogue source in the update crash fixture')
    parser.add_argument('--update-recovery-compressed', action='store_true',
                        help='Actually compress existing physical copies before the update crash, then verify ordinary startup and incremental continuation')
    parser.add_argument('--update-recovery-preserve', choices=['changed-catalogue', 'changed-backup',
                        'replaced-catalogue', 'replaced-profile', 'changed-journal', 'live-owner'],
                        help='Verify ordinary startup retains a conflicted interrupted update without changing either store')
    parser.add_argument('--update-recovery-neighbour', action='store_true',
                        help='Write a later witness for another collection after the crash and verify recovery preserves it')
    parser.add_argument('--refresh-index', action='store_true',
                        help='After compression, run actual full INPX refresh and verify physical sizes')
    parser.add_argument('--reviewed-flibrary-bound', action='store_true',
                        help='Use two FLibrary source roots with separate images and apply new downloads from another folder')
    parser.add_argument('--reviewed-bound', action='store_true',
                        help='Compress two physical bound sources, then apply source INPX and preserve sizes and priorities')
    parser.add_argument('--reviewed-index', action='store_true',
                        help='After real catalogue compression, apply full and append INPX and process only a new downloaded member; default fixture mixes FB2 and EPUB')
    parser.add_argument('--legacy-history', action='store_true',
                        help='Migrate real old Packer FB2/EPUB witnesses through the normal catalogue command')
    args = parser.parse_args()
    report = args.stage / f'catalogue-{args.platform}-{args.mode}.json'
    try:
        result = run(**vars(args))
        result['private_runtime_removed'] = not Path(result['private_runtime']).exists()
        assert result['private_runtime_removed'], 'Owned catalogue fixture runtime was not removed'
    except BaseException as error:
        attempt_file = args.stage / f'catalogue-{args.platform}-{args.mode}-attempt.json'
        attempt = json.loads(attempt_file.read_text(encoding='utf-8')) if attempt_file.exists() else {}
        unchanged = all((Path(path).stat().st_ino, Path(path).stat().st_size, Path(path).stat().st_mtime_ns) == tuple(stamp)
                        for path, stamp in attempt.get('real_source_stamps', {}).items())
        result = dict(status='FAIL', platform=args.platform, mode=args.mode,
                      error=type(error).__name__ + ': ' + str(error),
                      last_phase=attempt.get('status'), originals_unchanged=unchanged)
        report.write_text(json.dumps(result, indent=2), encoding='utf-8')
        raise
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result))
