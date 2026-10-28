"""Install only explicitly selected, hash-checked component fixtures offline."""
from pathlib import Path
import hashlib
import json
import sys
import zipfile


def prepare(packages, profile, platform, components):
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('Owned native test profile required')
    feed = json.loads((packages / 'format-components.json').read_text(encoding='utf-8'))
    assets = {item['name']: item for item in json.loads(
        (packages / 'format-component-assets.json').read_text(encoding='utf-8'))}
    for component in components:
        entry = next(item for item in feed['components']
                     if item['id'] == component and item['platform'] == platform)
        name = entry['archive']
        source = packages / name
        asset = assets[name]
        if (asset['digest'] != 'sha256:' + hashlib.sha256(source.read_bytes()).hexdigest()
                or asset['size'] != source.stat().st_size):
            raise ValueError('Component fixture differs from tested archive: ' + name)
        with zipfile.ZipFile(source) as archive:
            manifest = json.loads(archive.read('HomeLibRu.update.json'))
            if manifest['component'] != component or manifest['platform'] != platform:
                raise ValueError('Component fixture identity mismatch')
            for item in manifest['files']:
                relative = item['path']
                target = (profile / relative).resolve()
                if not relative.startswith('tools/') or not target.is_relative_to(profile):
                    raise ValueError('Unsafe component fixture path')
                data = archive.read(relative)
                if len(data) != item['size'] or hashlib.sha256(data).hexdigest() != item['sha256']:
                    raise ValueError('Component fixture file mismatch')
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output:
                    output.write(data)
        print('PASS staged independent component fixture:', component, platform)


if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve(strict=True), Path(sys.argv[2]).resolve(strict=True),
            sys.argv[3], sys.argv[4:])
