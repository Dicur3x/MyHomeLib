"""Create versioned fallback components from already verified local runtimes.

No download, compilation, installed file changes, or publication is performed.
Native installer validation is required before publishing the generated feed.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import zipfile

TAG = 'optional-alreader-2.5.1009.25'
PREFIX = 'https://github.com/Dicur3x/MyHomeLib/releases/download/' + TAG + '/'
COMPONENTS = ('SQLite', 'SumatraPDF', 'DjVuLibre', '7-Zip', 'DocSharp', 'JPEG XL')
ORIGINS = {
    'SQLite': 'https://www.sqlite.org/download.html',
    'SumatraPDF': 'https://www.sumatrapdfreader.org/download-free-pdf-viewer',
    'DjVuLibre': 'https://sourceforge.net/projects/djvu/files/DjVuLibre_Windows/',
    '7-Zip': 'https://github.com/ip7z/7zip/releases',
    'DocSharp': 'https://github.com/manfromarce/DocSharp',
    'JPEG XL': 'https://github.com/libjxl/libjxl/releases/tag/v0.12.0',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf8')


def select(runtime, component, version_reader, platform):
    def files(prefix, names):
        return {prefix + name: (runtime / prefix / name).read_bytes() for name in names}
    if component == 'SQLite':
        return version_reader(runtime / 'sqlite3.dll'), files('', ['sqlite3.dll'])
    if component == 'SumatraPDF':
        prefix = 'Readers/SumatraPDF/'
        return version_reader(runtime / prefix / 'SumatraPDF.exe'), files(prefix, [
            'SumatraPDF.exe', 'AUTHORS.txt', 'COPYING.BSD.txt', 'COPYING.txt'])
    if component == '7-Zip':
        prefix = 'tools/7zip/'
        return version_reader(runtime / prefix / '7z.exe'), files(prefix, ['7z.exe', '7z.dll', 'License.txt'])
    if component == 'DocSharp':
        prefix = 'tools/doc/'
        return version_reader(runtime / prefix / 'DocSharp.Binary.Doc.dll'), files(prefix, [
            'DocSharp.Binary.Doc.dll', 'DocSharp.Binary.Common.dll', 'DocSharp.Binary.Ppt.dll',
            'DocSharp.Binary.Xls.dll', 'HomeLibDoc.exe', 'DOC_RUNTIME.json', 'DocSharp-MIT.txt',
            'b2xtranslator-BSD-3-Clause.txt', 'HomeLibDoc-MIT.txt'])
    if component == 'DjVuLibre':
        prefix = 'tools/djvu/'
        descriptor = json.loads((runtime / prefix / 'RUNTIME.json').read_bytes())['djvu']
        version = descriptor['version']
        payload = files(prefix, [
            'ddjvu.exe', 'djvused.exe', 'libdjvulibre.dll', 'libjpeg.dll', 'libtiff.dll',
            'libz.dll', 'COPYING.txt', 'COPYRIGHT', 'IJG-README.txt', 'LIBTIFF-COPYRIGHT.txt',
            'ZLIB-README.txt', 'RUNTIME.json', 'djvulibre-' + version + '.tar.gz'])
        for name, digest in dict(descriptor['files'], **descriptor['distribution']).items():
            if sha(payload[prefix + name]) != digest:
                raise ValueError('DjVu source/runtime descriptor mismatch: ' + name)
        return version, payload
    prefix = 'tools/jpeg-xl/'
    decoder = (runtime / prefix / 'djxl.exe').read_bytes()
    expected = {'Win32': 'ce031db2a11536654ae2a7b08920783b9a1a3813f74c45e18df89c39723cc172',
                'Win64': '6970ce73de51e046b39bd5f28fc7bc5da64e9f6505c11194319f43d8849d2bf4'}
    if sha(decoder) != expected[platform]:
        raise ValueError('JPEG XL requires a separately verified new upstream version')
    payload = {prefix + 'djxl.exe': decoder}
    for path in sorted((runtime / prefix / 'licenses').glob('LICENSE.*')):
        payload[prefix + 'licenses/' + path.name] = path.read_bytes()
    payload[prefix + 'RUNTIME.json'] = encoded({'component': 'JPEG XL', 'codec': {
        'version': '0.12.0', 'files': {'djxl.exe': sha(decoder)}}})
    return '0.12.0', payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('reader_packaging', repo / 'scripts/package-reader-components.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    feed, assets, report = [], [], []
    for platform in ('Win32', 'Win64'):
        runtime = repo / 'Program/Out' / ('Bin' if platform == 'Win32' else 'Bin64')
        for component in COMPONENTS:
            version, payload = select(runtime, component, helper.file_version, platform)
            name = 'HomeLibRu-' + component.replace(' ', '') + '-' + version + '-' + platform + '.zip'
            manifest = {'format': 1, 'release': TAG, 'component': component, 'version': version,
                        'platform': platform, 'files': [{'path': path, 'size': len(data), 'sha256': sha(data)}
                                                      for path, data in sorted(payload.items())]}
            payload['HomeLibRu.update.json'] = encoded(manifest)
            path = output / name
            with path.open('xb') as stream, zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
                for member, data in sorted(payload.items()):
                    info = zipfile.ZipInfo(member, (2026, 10, 27, 0, 0, 0))
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = 0o644 << 16
                    archive.writestr(info, data)
            with zipfile.ZipFile(path) as archive:
                if archive.testzip() is not None:
                    raise ValueError('Archive CRC failed: ' + name)
            digest, size = sha(path.read_bytes()), path.stat().st_size
            assets.append({'name': name, 'size': size, 'digest': 'sha256:' + digest,
                           'browser_download_url': PREFIX + name})
            feed.append({'id': component, 'platform': platform, 'version': version, 'archive': name,
                         'history': [{'version': version, 'notes':
                             'Запасная копия проверенного компонента. Источник автора: ' + ORIGINS[component] +
                             '. Лицензии сохранены в архиве; это зеркало, а не новая сборка автора.'}]})
            report.append({'component': component, 'version': version, 'platform': platform,
                           'archive': name, 'sha256': digest, 'size': size, 'files': len(manifest['files']),
                           'native_installer_verified': False, 'upstream': ORIGINS[component]})
    feed_bytes = encoded({'format': 1, 'components': feed})
    feed_name = 'HomeLibRu.components.json'
    (output / feed_name).write_bytes(feed_bytes)
    assets.append({'name': feed_name, 'size': len(feed_bytes), 'browser_download_url': PREFIX + feed_name})
    (output / 'local-mirror-release.json').write_bytes(encoded({'draft': False, 'tag_name': TAG, 'assets': assets}))
    (output / 'component-mirror-report.json').write_bytes(encoded(report))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
