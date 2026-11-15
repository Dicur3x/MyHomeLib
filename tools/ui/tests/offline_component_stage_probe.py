"""Exercise offline assembly with explicitly supplied real Reader/worker ZIPs.

This is a selected-component regression, not proof that the full 25-component
distribution has been assembled or that a clean Windows host works offline.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('offline_staging', ROOT / 'scripts/stage-offline-components.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-root', required=True, type=Path)
    parser.add_argument('--native-root', required=True, type=Path)
    parser.add_argument('--package', required=True, action='append', type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    args = parser.parse_args()
    stage = args.stage.resolve()
    stage.mkdir(exist_ok=False)
    inputs = {}
    for path in args.package:
        path = path.resolve(strict=True)
        with zipfile.ZipFile(path) as archive:
            manifest = json.loads(archive.read('HomeLibRu.update.json'))
        key = manifest['component'], manifest['platform']
        assert key not in inputs
        inputs[key] = dict(id=key[0], version=manifest['version'], archive=str(path), sha256=staging.sha(path))
    reports = []
    for platform, folder in [('Win32', 'Bin'), ('Win64', 'Bin64')]:
        with tempfile.TemporaryDirectory(prefix='homelibru-package-', dir=stage) as name:
            parent = Path(name)
            (parent / '.package-stage').write_text(staging.OWNER)
            payload = parent / 'payload'
            payload.mkdir()
            for name in ('HomeLibre.exe', 'HomeLibRuUpdater.exe', 'sqlite3.dll', 'NOTICE'):
                shutil.copy2(args.runtime_root / folder / name, payload / name)
            rows = [inputs[(component, platform)] for component in ('HomeLibReader', 'BookProcessing', 'ImageProcessing')]
            definition = parent / 'inputs.json'
            plan = dict(format=1, platform=platform, components=rows)
            definition.write_text(json.dumps(plan))
            native = args.native_root / platform / 'ProgramUpdateInstallerTest.exe'
            before = {p.name: staging.sha(p) for p in payload.iterdir()}
            try:
                staging.stage(payload, definition, native)
            except ValueError as error:
                assert 'every current component' in str(error)
            else:
                raise AssertionError('Partial definition accepted as a full distribution')
            assert before == {p.name: staging.sha(p) for p in payload.iterdir()}
            bad_plan = dict(plan, components=[dict(row, sha256='0' * 64) for row in rows])
            definition.write_text(json.dumps(bad_plan))
            try:
                staging.stage(payload, definition, native, required={row['id'] for row in rows})
            except ValueError as error:
                assert 'checksum mismatch' in str(error)
            else:
                raise AssertionError('Changed archive accepted')
            assert before == {p.name: staging.sha(p) for p in payload.iterdir()}
            definition.write_text(json.dumps(plan))
            result = staging.stage(payload, definition, native, required={row['id'] for row in rows})
            assert (payload / 'HomeLibreReader.exe').is_file() and not (payload / 'HomeLibReader.exe').exists()
            reports.append(result)
            print('PASS real selected offline staging and missing/hash guards ' + platform, flush=True)
        assert not parent.exists()
    (stage / 'selected-real-staging.json').write_text(json.dumps(dict(status='PASS', scope=__doc__,
        owned_profiles_removed=True, checks=reports), indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
