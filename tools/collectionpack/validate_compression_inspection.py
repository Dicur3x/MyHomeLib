"""Run compression history regressions against exact packaged, private runtimes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import time
import traceback
import unittest

from pack_collection import temporary_work_directory
from validate_catalogue_compression import install_processing_package


class LiveFailureResult(unittest.TextTestResult):
    def addError(self, test, error):
        super().addError(test, error)
        self.stream.write(self._exc_info_to_string(error, test))
        self.stream.flush()

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.stream.write(self._exc_info_to_string(error, test))
        self.stream.flush()


def identity(path):
    value = Path(path)
    digest = hashlib.sha256()
    with value.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return dict(bytes=value.stat().st_size, sha256=digest.hexdigest())


def check_pe(path, platform):
    with Path(path).open('rb') as stream:
        assert stream.read(2) == b'MZ', path
        stream.seek(60)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        assert stream.read(4) == b'PE\0\0', path
        assert struct.unpack('<H', stream.read(2))[0] == {'Win32': 0x14c, 'Win64': 0x8664}[platform], path


def run(args):
    stage = args.stage.resolve(strict=True)
    report = args.report.resolve()
    log = report.with_suffix('.log')
    report.parent.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    started = time.monotonic()
    result = dict(status='INCOMPLETE', platform=args.platform,
                  inputs={str(p): identity(p) for p in (args.receipt, args.operation, args.package)})
    if args.planner:
        result['inputs'][str(args.planner)] = identity(args.planner)
    report.write_text(json.dumps(result, indent=2), encoding='utf-8')
    try:
        with temporary_work_directory(stage, 'HomeLibre-inspection-runtime-') as root:
            install_processing_package(args.package, root, args.platform)
            for name in ('7zip', 'images'):
                source = args.images if name == 'images' and args.images else args.runtime / 'tools' / name
                shutil.copytree(source, root / 'tools' / name)
            for name in ('prepare_book_compression.py', 'pack_collection.py', 'compression_image_history.py'):
                assert (root / 'tools/bookconvert' / name).read_bytes() == (repo / 'tools/collectionpack' / name).read_bytes()
            image = root / 'tools/images/HomeLibImages.exe'
            image_manifest = json.loads((image.parent / 'RUNTIME.json').read_text(encoding='utf-8-sig'))
            assert image_manifest['platform'] == args.platform
            assert identity(image)['sha256'] == image_manifest['sha256']
            if args.images:
                assert image_manifest['source_sha256'] == identity(repo / 'Utils/HomeLibXps/HomeLibXps.cs')['sha256']
                assert not (image.parent / 'HomeLibImages.exe.config').exists(), 'The legacy installer allows only the original image component paths'
            seven = root / 'tools/7zip/7za.exe'
            binaries = [image, seven, root / 'tools/python/python.exe']
            for source in (args.receipt, args.operation, args.sqlite, *([args.planner] if args.planner else [])):
                target = root / source.name
                shutil.copy2(source, target)
                assert identity(target) == identity(source)
                binaries.append(target)
            for binary in binaries:
                check_pe(binary, args.platform)
            result['runtime'] = {str(p.relative_to(root)): identity(p) for p in binaries}
            if (image.parent / 'HomeLibImages.exe.config').is_file():
                result['runtime']['tools/images/HomeLibImages.exe.config'] = identity(image.parent / 'HomeLibImages.exe.config')
            env = dict(HL_NATIVE_COMPRESSION_RECEIPT=str(root / args.receipt.name),
                       HL_NATIVE_COMPRESSION_OPERATION=str(root / args.operation.name),
                       HL_COMPRESSION_RUNTIME=str(root), HLRU_PACK_IMAGE_TOOLS=str(root / 'tools'),
                       HLRU_PACK_7ZIP=str(seven), HL_SELECTED_PREPARER=str(root / 'tools/bookconvert/prepare_book_compression.py'),
                       TEMP=str(root / 'temp'), TMP=str(root / 'temp'),
                       LOCALAPPDATA=str(root / 'profile/local'), APPDATA=str(root / 'profile/roaming'))
            if args.planner:
                env['HL_NATIVE_COMPRESSION_PLAN'] = str(root / args.planner.name)
            for name in ('temp', 'profile/local', 'profile/roaming'):
                (root / name).mkdir(parents=True, exist_ok=True)
            previous = {key: os.environ.get(key) for key in env}
            try:
                os.environ.update(env)
                suite = unittest.defaultTestLoader.loadTestsFromNames(args.test or [
                    'test_supervised_test_process',
                    'test_prepare_book_compression', 'test_native_compression_receipt',
                    'test_native_compression_operation', 'test_incremental_image_history'])
                with log.open('w', encoding='utf-8') as stream:
                    tested = unittest.TextTestRunner(stream=stream, verbosity=2, resultclass=LiveFailureResult).run(suite)
                result.update(tests=tested.testsRun, failures=len(tested.failures), errors=len(tested.errors),
                              skipped=tested.skipped, log=str(log))
                if not tested.wasSuccessful() or tested.skipped:
                    raise AssertionError('Regression suite failed or skipped tests; see ' + str(log))
            finally:
                for key, value in previous.items():
                    if value is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = value
        result.update(status='PASS', private_runtime_removed=not root.exists())
        assert result['private_runtime_removed']
    except BaseException:
        result.update(status='FAIL', error=traceback.format_exc())
        raise
    finally:
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('stage', 'report', 'receipt', 'operation', 'package', 'runtime', 'sqlite'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    parser.add_argument('--images', type=Path, help='Fresh verified image helper, without replacing another runtime')
    parser.add_argument('--planner', type=Path, help='Optional native planning and scratch-recovery fixture')
    parser.add_argument('--test', action='append', help='Specific diagnostic cases; default is the complete suite')
    run(parser.parse_args())
