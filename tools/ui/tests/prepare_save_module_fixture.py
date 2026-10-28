"""Stage a real old converter and a private candidate for restart regression.

No downloads, profile copies or changes to the supplied old archive. The caller
owns the marked native runtime and removes it after the scenario finishes.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import zipfile


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def prepare(runtime, profile, old):
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('Owned native profile required')
    repo = Path(__file__).resolve().parents[3]
    platform = 'Win64' if runtime.name == 'Bin64' else 'Win32'
    pinned = {
        'Win32': '1a06288f6bbb4616fdb4107b0fb5869c9c726197c3353a22df9abd17d2c4e6ef',
        'Win64': 'd1a659cda22ed3db557a2557c116ca554f0f4b7ff3dd662032cc7efbd48dbccd',
    }
    if hashlib.sha256(old.read_bytes()).hexdigest() != pinned[platform]:
        raise ValueError('Old published converter archive differs from its pin')
    with zipfile.ZipFile(old) as archive:
        for name in archive.namelist():
            if name == 'HomeLibRu.update.json':
                continue
            target = (profile / name).resolve()
            if not target.is_relative_to(profile) or not name.startswith('tools/'):
                raise ValueError('Unexpected old component path')
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as output:
                output.write(archive.read(name))
    assert not (profile / 'tools/bookconvert/SAVE_OPTIONS_API.txt').exists()
    builder = load('save_module_package', repo / 'scripts/package-reader-components.py')
    target = profile / 'save-module-fixture'
    _, report = builder.package(repo, platform, 'BookConverter', '2.7.0_pre5.35',
                                '2.7.0.1103', target)
    (target / 'fixture.json').write_text(json.dumps(report), encoding='utf-8')
    helpers = load('save_module_pdf', repo / 'tools/bookconvert/tests/test_legacy_fixed.py')
    (profile / 'module-source.pdf').write_bytes(helpers.pdf_fixture())
    print('PASS real published converter 1102 and private candidate 1103 staged:', platform)


if __name__ == '__main__':
    prepare(*(Path(p).resolve() for p in sys.argv[1:]))
