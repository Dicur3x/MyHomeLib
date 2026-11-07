"""Stage a real old converter and a private candidate for restart regression.

No downloads, profile copies or changes to the supplied old archive. The caller
owns the marked native runtime and removes it after the scenario finishes.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
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
    target = profile / 'save-module-fixture'
    packages = Path(os.environ['HOMELIB_FORMAT_COMPONENT_PACKAGES']).resolve(strict=True)
    name = f'HomeLibRu-BookProcessing-2.7.0.1105-{platform}.zip'
    source = packages / name
    assets = json.loads((packages / 'format-component-assets.json').read_text(encoding='utf-8'))
    asset = next(item for item in assets if item['name'] == name)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if asset['digest'] != 'sha256:' + digest or source.stat().st_size != asset['size']:
        raise ValueError('New independent processing archive differs from tested metadata')
    target.mkdir()
    shutil.copyfile(source, target / name)
    report = dict(sha256=digest, size=asset['size'], name=name,
                  url=asset['browser_download_url'])
    (target / 'fixture.json').write_text(json.dumps(report), encoding='utf-8')
    helpers = load('save_module_pdf', repo / 'tools/bookconvert/tests/test_legacy_fixed.py')
    (profile / 'module-source.pdf').write_bytes(helpers.pdf_fixture())
    print('PASS real published converter 1102 and independent processing 1105 staged:', platform)


def prepare_operation_components(runtime, profile, operation):
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('Owned native profile required')
    platform = 'Win64' if runtime.name == 'Bin64' else 'Win32'
    packages = Path(os.environ['HOMELIB_FORMAT_COMPONENT_PACKAGES']).resolve(strict=True)
    feed = json.loads((packages / 'format-components.json').read_text(encoding='utf-8'))
    assets = json.loads((packages / 'format-component-assets.json').read_text(encoding='utf-8'))
    required = {'BookProcessing'}
    if operation != 'sql':
        required.add('ImageProcessing' if operation == 'packing' else 'KindleExport')
    selected = [entry for entry in feed['components']
                if entry['platform'] == platform and entry['id'] in required]
    if len(selected) != len(required) or {entry['id'] for entry in selected} != required:
        raise ValueError('The exact distinct component packages are required')
    versions = {entry['id']: entry['version'] for entry in selected}
    if operation != 'packing' and len(set(versions.values())) != 1:
        raise ValueError('First-use fixture needs matching candidate versions')
    target = profile / 'save-module-fixture'
    target.mkdir()
    entries = []
    for entry in selected:
        name = entry['archive']
        if Path(name).name != name:
            raise ValueError('Unexpected component archive name')
        source = packages / name
        asset = next(item for item in assets if item['name'] == name)
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if asset['digest'] != 'sha256:' + digest or source.stat().st_size != asset['size']:
            raise ValueError('Component differs from tested asset metadata')
        shutil.copyfile(source, target / name)
        entries.append(dict(id=entry['id'], version=entry['version'], name=name, sha256=digest,
                            size=asset['size'], url=asset['browser_download_url']))
    (target / 'fixture.json').write_text(json.dumps(dict(version=versions['BookProcessing'], components=entries)), encoding='utf-8')
    (profile / 'module-source.fb2').write_text('''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info>
<genre>prose</genre><author><first-name>Тест</first-name><last-name>Автор</last-name></author>
<book-title>Возврат к сохранению</book-title><lang>ru</lang></title-info></description>
<body><section><title><p>Глава</p></title><p>Исходная книга не должна измениться при установке модулей.</p></section></body></FictionBook>''', encoding='utf-8')
    print('PASS real independent packages staged without installing:', operation, platform)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[3] in ('kindle', 'packing', 'sql'):
        prepare_operation_components(*(Path(p).resolve() for p in sys.argv[1:3]), sys.argv[3])
    else:
        prepare(*(Path(p).resolve() for p in sys.argv[1:]))
