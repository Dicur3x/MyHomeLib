"""Stage a complete offline distribution from explicitly pinned component ZIPs.

The native updater validates each package and the staged runtime. Only manifest
members are copied; arbitrary files in a developer's runtime never become part
of the distribution. Run inside package-release.ps1's owned staging directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile
import zipfile

COMPONENTS = frozenset(('AlReader', 'SumatraPDF', 'DjVuLibre', '7-Zip', 'DocSharp',
    'JPEG XL', 'WebP', 'HomeLibReader', 'PDFium', 'IBK', 'MHLMcpServer', 'Zstandard',
    'BookProcessing', 'ImageProcessing', 'Kindle', 'LegacyBooks', 'LegacyOffice',
    'XPS', 'KindleExport', 'FB2Export', 'KoboExport', 'KfxExport', 'EpubPdfExport',
    'OPDSTls', 'JpegXLEncoder'))
OWNER = 'HomeLibre release packaging v1'


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(part)
    return result.hexdigest()


def disk_guard(destination, incoming=0):
    if os.name == 'nt' and shutil.disk_usage(os.environ.get('SystemDrive', 'C:') + '\\').free < 8 * 1024**3:
        raise OSError('Keep at least 8 GiB free on the system drive.')
    if shutil.disk_usage(destination).free < incoming + 512 * 1024**2:
        raise OSError('Insufficient staging space, including the 512 MiB reserve.')


def safe_member(name):
    return isinstance(name, str) and bool(name) and '\\' not in name and ':' not in name and '\0' not in name \
        and not name.startswith('/') and all(part not in ('', '.', '..') and part.rstrip(' .') == part
                                            for part in name.split('/'))


def stage(payload, definition, native, *, required=COMPONENTS):
    payload = payload.resolve(strict=True)
    parent = payload.parent
    if payload.name != 'payload' or not parent.name.startswith('homelibru-package-') or \
            (parent / '.package-stage').read_text(encoding='utf-8') != OWNER or parent.is_symlink() or parent.is_junction():
        raise ValueError('An owned package-release staging directory is required.')
    plan = json.loads(definition.read_bytes())
    if plan.get('format') != 1 or plan.get('platform') not in ('Win32', 'Win64'):
        raise ValueError('Invalid offline component plan.')
    rows = plan.get('components')
    if not isinstance(rows, list) or not rows or len(rows) > 32:
        raise ValueError('Invalid offline component list.')
    ids = [row['id'] for row in rows]
    if len(ids) != len(set(ids)) or set(ids) != set(required):
        raise ValueError('The full distribution must contain every current component exactly once: ' +
                         repr(sorted(set(required).symmetric_difference(ids))))
    # The old monolithic BookConverter writes the same paths as BookProcessing.
    # Shipping both can replace current conversion/compression workers with old
    # files. All its current functions are supplied by the separate modules.
    if 'BookConverter' in ids or 'SQLite' in ids:
        raise ValueError('Core SQLite and the retired converter are not optional offline inputs.')
    native = native.resolve(strict=True)
    disk_guard(parent)
    if any(path.is_symlink() or path.is_junction() for path in payload.rglob('*')):
        raise ValueError('Release staging must not contain links.')
    existing = {path.relative_to(payload).as_posix().casefold():
                path.relative_to(payload).as_posix() for path in payload.rglob('*') if path.is_file()}
    parts, packages = [], []
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-offline-', dir=parent) as name:
        work = Path(name)
        environment = dict(os.environ, TEMP=str(parent), TMP=str(parent),
                           LOCALAPPDATA=str(work / 'local-appdata'), APPDATA=str(work / 'appdata'))

        def run(*command):
            result = subprocess.run([str(native), *map(str, command)], env=environment, cwd=work,
                capture_output=True, encoding='utf-8', errors='replace', timeout=180,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            if result.returncode:
                raise ValueError('Native package validation failed: ' + result.stdout + result.stderr)
            return result.stdout.strip()

        for index, row in enumerate(rows):
            source = Path(row['archive']).resolve(strict=True)
            if not re.fullmatch(r'[0-9a-f]{64}', row['sha256']) or sha(source) != row['sha256']:
                raise ValueError('Offline component archive checksum mismatch: ' + row['id'])
            if not re.fullmatch(r'\d+(?:\.\d+){1,3}', row['version']):
                raise ValueError('Invalid offline component version.')
            with zipfile.ZipFile(source) as archive:
                if archive.getinfo('HomeLibRu.update.json').file_size > 1024**2:
                    raise ValueError('Oversized component manifest.')
                manifest = json.loads(archive.read('HomeLibRu.update.json'))
            if (manifest.get('component'), manifest.get('version')) != (row['id'], row['version']) or \
                    manifest.get('platform') not in (plan['platform'], 'AnyWindows') or \
                    (manifest.get('platform') == 'AnyWindows' and row['id'] != 'AlReader'):
                raise ValueError('Offline component identity mismatch: ' + row['id'])
            if not re.fullmatch(r'[A-Za-z0-9._-]{1,80}', manifest.get('release', '')):
                raise ValueError('Invalid component release identity.')
            disk_guard(parent, source.stat().st_size + sum(item['size'] for item in manifest['files']))
            download = work / f'component-{index}.zip'
            shutil.copy2(source, download)
            job = work / f'job-{index}'
            run('--prepare-component', download, row['sha256'], manifest['release'], job, row['id'], row['version'])
            verified = json.loads((job / 'manifest.json').read_text(encoding='utf-8-sig'))
            if row['id'] == 'BookProcessing':
                scripts = Path(__file__).resolve().parent
                release = json.loads((scripts.parent / 'Installer/Release.json').read_bytes())
                pinned = release.get('component_versions', {}).get('BookProcessing', release['components_version'])
                if required == COMPONENTS and row['version'] != pinned:
                    raise ValueError('Offline BookProcessing version differs from the release: ' + row['version'])
                # Pinned older versions can legitimately predate this checkout.
                if row['version'] == release['version']:
                    packaging = runpy.run_path(str(scripts / 'package-format-components.py'))
                    descriptor = job / 'payload' / packaging['DESCRIPTORS']['BookProcessing']
                    packaging['verify_book_processing_sources'](verified, json.loads(descriptor.read_bytes()))
            if row['id'] == 'EpubPdfExport':
                packaging = runpy.run_path(str(Path(__file__).resolve().with_name('package-format-components.py')))
                packaging['verify_epub_pdf_source'](verified)
            for item in verified['files']:
                original = item['path']
                target_name = 'HomeLibreReader.exe' if row['id'] == 'HomeLibReader' and \
                    original in ('HomeLibReader.exe', 'HomeLibreReader.exe') else original
                if not safe_member(original) or not safe_member(target_name):
                    raise ValueError('Unsafe component member.')
                staged = job / 'payload' / original
                if staged.stat().st_size != item['size'] or sha(staged) != item['sha256']:
                    raise ValueError('Prepared component member changed: ' + original)
                canonical = existing.get(target_name.casefold())
                if canonical is not None and canonical != target_name:
                    raise ValueError('Case-colliding distribution members: ' + target_name)
                target = payload / target_name
                if target.exists() and sha(target) != item['sha256']:
                    # Reader adds its notice to the same base NOTICE. Preserve
                    # the complete longer document; unrelated conflicts fail.
                    if target_name != 'NOTICE':
                        raise ValueError('Conflicting component payload: ' + target_name)
                    current, incoming = target.read_bytes(), staged.read_bytes()
                    if current.startswith(incoming):
                        continue
                    if not incoming.startswith(current):
                        raise ValueError('Conflicting component notices.')
                target.parent.mkdir(parents=True, exist_ok=True)
                disk_guard(parent, item['size'])
                shutil.copy2(staged, target)
                existing[target_name.casefold()] = target_name
            part = dict(component=row['id'], version=row['version'], official=manifest.get('official', False))
            if row['id'] == 'HomeLibReader':
                part['reader_application'] = 'HomeLibreReader.exe'
            parts.append(part)
            packages.append(dict(id=row['id'], version=row['version'], archive=str(source), sha256=row['sha256']))
            print('Verified offline component: ' + row['id'], flush=True)
        # Check the combined on-disk runtime too: sharing a path must not break
        # another module's descriptor even if each input ZIP was valid alone.
        check = work / 'HomeLibRu-update-test-combined'
        disk_guard(parent)
        # Both trees are owned, on the same staging volume, and the native
        # report only reads files. Hard links avoid duplicating a large bundle.
        shutil.copytree(payload, check, copy_function=os.link)
        state_output = run('--runtime-state', check).splitlines()
        if len(state_output) != 2 or state_output[-1] != 'PASS':
            raise ValueError('Unexpected native runtime verification response.')
        states = json.loads(state_output[0])
        indexed = {item['id']: item for item in states}
        for row in rows:
            item = indexed[row['id']]
            if item['repair'] or item['version'] != row['version']:
                raise ValueError('Combined offline runtime is incomplete: ' + row['id'])
    result = dict(format=1, platform=plan['platform'], components=parts, packages=packages,
                  native_sha256=sha(native), plan_sha256=sha(definition), runtime_states=states,
                  legacy_book_converter='Replaced by BookProcessing and separate format modules')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', required=True, type=Path)
    parser.add_argument('--definition', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    result = stage(args.payload, args.definition.resolve(strict=True), args.native)
    with args.report.open('x', encoding='utf-8') as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
