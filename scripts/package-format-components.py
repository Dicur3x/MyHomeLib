"""Build independent format dependencies from verified local runtimes, offline.

The legacy BookConverter feed is not overwritten by this script. New clients
request BookProcessing plus only dependencies required by the selected input or
image operation. Every payload retains its own licences.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader_packages', REPO/'scripts/package-reader-components.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
COMPONENTS = ('BookProcessing', 'ImageProcessing', 'Kindle', 'LegacyBooks', 'LegacyOffice', 'XPS')
DESCRIPTORS = {
    'BookProcessing': 'tools/bookconvert/MODULAR_RUNTIME.json',
    'ImageProcessing': 'tools/images/COMPONENT.json',
    'Kindle': 'tools/kindle/COMPONENT.json',
    'LegacyBooks': 'tools/bookconvert/vendor/calibre_legacy/COMPONENT.json',
    'LegacyOffice': 'tools/office/COMPONENT.json',
    'XPS': 'tools/xps/COMPONENT.json',
}
NOTES = {
    'BookProcessing': 'Общая обработка FB2/EPUB и текстов. Без декодеров Kindle, старых Office, XPS, PDF и DjVu.',
    'ImageProcessing': 'Сжатие иллюстраций и сканированных страниц. Без чтения документов XPS.',
    'Kindle': 'Чтение MOBI/AZW/KF8 через KindleUnpack. Общая среда обработки устанавливается отдельно при необходимости.',
    'LegacyBooks': 'Дополнительные кодеки старых LIT/LRF и отдельных вариантов Mobipocket.',
    'LegacyOffice': 'Чтение WPS/WPD через libwps/libwpd. Для этих инструментов требуется 64-разрядная Windows.',
    'XPS': 'Чтение документов XPS. Для обычных FB2/EPUB этот компонент не нужен.',
}


def tree(root, destination, exclude=()):
    if not root.is_dir():
        raise ValueError('Missing verified source directory: '+str(root))
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if (not path.is_file() or any(part in {'__pycache__', 'tests'} for part in relative.parts)
                or path.suffix.lower() in {'.pyc', '.pyo', '.map', '.rsm'}
                or any(relative.as_posix() == name or relative.as_posix().startswith(name+'/') for name in exclude)):
            continue
        result[destination+'/'+relative.as_posix()] = path.read_bytes()
    return result


def payload_for(platform, component):
    runtime = REPO/'Program/Out'/('Bin' if platform == 'Win32' else 'Bin64')/'tools'
    if component == 'BookProcessing':
        payload = tree(runtime/'kindle/python', 'tools/python')
        payload.update(tree(REPO/'tools/bookconvert', 'tools/bookconvert',
                            ('vendor/calibre_legacy', 'kindle_input.py', 'legacy_helper.py', 'COMPONENT.json')))
        payload['tools/bookconvert/MODULAR_API.txt'] = b'1\n'
        required = ['tools/python/python.exe', 'tools/bookconvert/convert_book.py',
                    'tools/bookconvert/MODULAR_API.txt', 'tools/python/python313.dll',
                    'tools/python/python313.zip', 'tools/python/python313._pth']
        helper.binary_platform(payload['tools/python/python.exe'], platform)
    elif component == 'ImageProcessing':
        payload = tree(runtime/'images', 'tools/images', ('COMPONENT.json',))
        required = ['tools/images/HomeLibImages.exe', 'tools/images/RUNTIME.json', 'tools/images/HomeLibImages-MIT.txt']
        helper.binary_platform(payload[required[0]], platform)
        descriptor = json.loads(payload[required[1]].decode('utf-8-sig'))
        if descriptor['processor'] != 'Images only; no XPS document reader' or helper.digest(payload[required[0]]) != descriptor['sha256']:
            raise ValueError('Image processor must be built in images-only mode')
        if descriptor['source_sha256'] != helper.digest((REPO/'Utils/HomeLibXps/HomeLibXps.cs').read_bytes()):
            raise ValueError('Image processor is stale; rebuild it from current source')
    elif component == 'Kindle':
        payload = tree(runtime/'kindle', 'tools/kindle', ('python', 'COMPONENT.json'))
        payload['tools/bookconvert/kindle_input.py'] = (REPO/'tools/bookconvert/kindle_input.py').read_bytes()
        required = ['tools/kindle/convert_kf8.py', 'tools/kindle/lib/kindleunpack.py', 'tools/kindle/COPYING.txt',
                    'tools/bookconvert/kindle_input.py']
    elif component == 'LegacyBooks':
        payload = tree(runtime/'bookconvert/vendor/calibre_legacy', 'tools/bookconvert/vendor/calibre_legacy', ('COMPONENT.json',))
        payload['tools/bookconvert/legacy_helper.py'] = (REPO/'tools/bookconvert/legacy_helper.py').read_bytes()
        required = ['tools/bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll', 'tools/bookconvert/legacy_helper.py']
        helper.binary_platform(payload[required[0]], platform)
    elif component == 'LegacyOffice':
        payload = tree(runtime/'office', 'tools/office', ('COMPONENT.json',))
        required = ['tools/office/wps2html.exe', 'tools/office/wpd2html.exe', 'tools/office/RUNTIME.json', 'tools/office/NOTICE.txt']
        # The verified author tools are x64, also when called by an x86 app on
        # x64 Windows. The reader already rejects them on 32-bit Windows.
        for name in ('tools/office/wps2html.exe', 'tools/office/wpd2html.exe'):
            helper.binary_platform(payload[name], 'Win64')
    else:
        payload = tree(runtime/'xps', 'tools/xps', ('COMPONENT.json',))
        required = ['tools/xps/HomeLibXps.exe', 'tools/xps/RUNTIME.json', 'tools/xps/HomeLibXps-MIT.txt']
        helper.binary_platform(payload[required[0]], platform)
    for name in required:
        if name not in payload or not payload[name]:
            raise ValueError('Missing required component payload: '+name)
    # Components must be independently installable; no two new archives own
    # the same file, including generated runtime descriptors.
    return payload, required


def package(output, platform, component, version):
    payload, required = payload_for(platform, component)
    descriptor = dict(format=1, component=component, platform=platform, version=version,
                      required=required, identities={name:helper.digest(payload[name]) for name in required})
    payload[DESCRIPTORS[component]] = helper.json_bytes(descriptor)
    manifest = dict(format=1, release=helper.publication_tag(helper.COMPONENT_RELEASE_TAG),
                    platform=platform, component=component, version=version,
                    files=[dict(path=name, size=len(data), sha256=helper.digest(data)) for name,data in sorted(payload.items())])
    payload['HomeLibRu.update.json'] = helper.json_bytes(manifest)
    output.mkdir(parents=True, exist_ok=True)
    target = output/f'HomeLibRu-{component}-{version}-{platform}.zip'
    with target.open('xb') as stream, zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            info=zipfile.ZipInfo(name,(2026,10,28,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o644<<16; archive.writestr(info,data)
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None
        for item in manifest['files']:
            data=archive.read(item['path'])
            assert len(data)==item['size'] and helper.digest(data)==item['sha256']
    return dict(id=component, platform=platform, version=version, archive=target.name,
                history=[dict(version=version, notes=NOTES[component])]), dict(name=target.name,
                    size=target.stat().st_size, digest='sha256:'+helper.digest(target.read_bytes()),
                    browser_download_url='https://github.com/Dicur3x/MyHomeLib/releases/download/'+helper.COMPONENT_RELEASE_TAG+'/'+target.name)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', choices=('Win32','Win64'), action='append')
    parser.add_argument('--component', choices=COMPONENTS, action='append')
    options=parser.parse_args()
    import re
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+){0,2}', options.version): parser.error('Invalid component version')
    entries=[]; assets=[]
    for platform in options.platform or ('Win32','Win64'):
        for component in options.component or COMPONENTS:
            entry, asset=package(options.output.resolve(), platform, component, options.version)
            entries.append(entry); assets.append(asset)
    with (options.output/'format-components.json').open('xb') as stream:
        stream.write(helper.json_bytes(dict(format=1, components=entries)))
    feed=helper.json_bytes(dict(format=1, components=entries))
    with (options.output/'HomeLibRu.components.json').open('xb') as stream:
        stream.write(feed)
    metadata=dict(draft=False,prerelease=False,tag_name=helper.COMPONENT_RELEASE_TAG,
        assets=assets+[dict(name='HomeLibRu.components.json',size=len(feed),
            browser_download_url='https://github.com/Dicur3x/MyHomeLib/releases/download/'+helper.COMPONENT_RELEASE_TAG+'/HomeLibRu.components.json')])
    with (options.output/'local-mirror-release.json').open('xb') as stream:
        stream.write(helper.json_bytes(metadata))
    with (options.output/'format-component-assets.json').open('xb') as stream:
        stream.write(helper.json_bytes(assets))
    print(json.dumps(assets, ensure_ascii=False, indent=2))
