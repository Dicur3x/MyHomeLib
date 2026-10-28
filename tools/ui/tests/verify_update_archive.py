"""Check an exact release ZIP through the native preparation AND helper launch gate.

Console-only. Does not launch a graphical application or change an installed copy.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def version(path):
    library = ctypes.WinDLL('version', use_last_error=True)
    size = library.GetFileVersionInfoSizeW(str(path), None)
    if not size:
        raise ctypes.WinError(ctypes.get_last_error())
    buffer = ctypes.create_string_buffer(size)
    if not library.GetFileVersionInfoW(str(path), 0, size, buffer):
        raise ctypes.WinError(ctypes.get_last_error())
    pointer, length = ctypes.c_void_p(), ctypes.c_uint()
    if not library.VerQueryValueW(buffer, '\\', ctypes.byref(pointer), ctypes.byref(length)):
        raise ctypes.WinError(ctypes.get_last_error())
    fixed = (ctypes.c_uint32 * 13).from_address(pointer.value)
    numeric = '.'.join(map(str, (fixed[2] >> 16, fixed[2] & 65535, fixed[3] >> 16, fixed[3] & 65535)))
    if not library.VerQueryValueW(buffer, '\\VarFileInfo\\Translation', ctypes.byref(pointer), ctypes.byref(length)):
        raise ValueError('No version translation')
    language, codepage = (ctypes.c_uint16 * 2).from_address(pointer.value)
    field = f'\\StringFileInfo\\{language:04x}{codepage:04x}\\ProductVersion'
    if not library.VerQueryValueW(buffer, field, ctypes.byref(pointer), ctypes.byref(length)):
        raise ValueError('No product version')
    return dict(file=numeric, product=ctypes.wstring_at(pointer.value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('native_test', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--expect-helper-rejection', action='store_true')
    options = parser.parse_args()
    source = options.archive.resolve()
    digest = sha(source.read_bytes())
    assert digest == options.sha256.lower(), 'Release ZIP differs from the supplied independent checksum'
    root = Path(tempfile.mkdtemp(prefix='HomeLibRu-update-test-release-')).resolve()
    owner = str(uuid.uuid4())
    (root/'owned-release-check.marker').write_text(owner, encoding='ascii')
    report = dict(archive=source.name, sha256=digest, gui_started=False)
    try:
        archive = root/'application.zip'
        shutil.copyfile(source, archive)
        with zipfile.ZipFile(archive) as package:
            manifest = json.loads(package.read('HomeLibRu.update.json').decode('utf-8-sig'))
            report.update(tag=manifest['release'], platform=manifest['platform'])
            for name in ('HomeLibRu.exe', 'HomeLibRuUpdater.exe'):
                data = package.read(name)
                member = next(item for item in manifest['files'] if item['path'] == name)
                assert len(data) == member['size'] and sha(data) == member['sha256']
                path = root/name
                path.write_bytes(data)
                report[name] = version(path)
        native = options.native_test.resolve()
        data = native.read_bytes()
        machine = struct.unpack_from('<H', data, struct.unpack_from('<I', data, 0x3c)[0]+4)[0]
        assert machine == (0x8664 if manifest['platform'] == 'Win64' else 0x14c)
        def run(*args):
            return subprocess.run([str(native), *map(str, args)], capture_output=True,
                                  text=True, encoding='utf-8', timeout=180,
                                  creationflags=subprocess.CREATE_NO_WINDOW)
        job = root/'HomeLibRu-update-job'
        prepared = run('--prepare', archive, digest, manifest['release'], job)
        report['prepare'] = dict(exit=prepared.returncode, output=prepared.stdout+prepared.stderr)
        assert prepared.returncode == 0, report['prepare']
        # The download worker retains its verified source in the job. The
        # preparation CLI intentionally only extracts and validates payloads.
        shutil.copyfile(archive, job/'release.zip')
        helper = run('--prepared-helper', job, manifest['release'], digest)
        report['helper'] = dict(exit=helper.returncode, output=helper.stdout+helper.stderr)
        if options.expect_helper_rejection:
            assert helper.returncode != 0 and 'Версия EXE не совпадает' in report['helper']['output'], report['helper']
        else:
            assert helper.returncode == 0, report['helper']
            for name in ('HomeLibRu.exe', 'HomeLibRuUpdater.exe'):
                assert report[name]['product'] == manifest['release'], report[name]
            assert report['HomeLibRu.exe']['file'] == report['HomeLibRuUpdater.exe']['file']
        report['expected_result_verified'] = True
    finally:
        assert root.parent == Path(tempfile.gettempdir()).resolve()
        assert root.name.startswith('HomeLibRu-update-test-release-') and not root.is_symlink()
        assert (root/'owned-release-check.marker').read_text('ascii') == owner
        shutil.rmtree(root)
        report['temporary_payloads_removed'] = True
        options.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('PASS exact release preparation and helper gate:', report['platform'], report['tag'])


if __name__ == '__main__':
    main()
