"""Build independent format dependencies from verified local runtimes, offline.

The legacy BookConverter feed is not overwritten by this script. New clients
request BookProcessing plus only dependencies required by the selected input or
image operation. Every payload retains its own licences.
"""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader_packages', REPO/'scripts/package-reader-components.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
COMPONENTS = ('BookProcessing', 'ImageProcessing', 'Kindle', 'LegacyBooks', 'LegacyOffice', 'XPS', 'KindleExport')
WRITERS = {
    'FB2Export': {
        'directory': 'fb2-export', 'exe': 'fbc.exe', 'repo': 'rupor-github/fb2cng', 'tag': 'v1.9.5',
        'license': '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986',
        'Win32': ('fbc-windows-386.zip', '5abb920a096ddd285f2db86b7f3d6f533b8d144ff041346d2d9c2354863bd3ea'),
        'Win64': ('fbc-windows-amd64.zip', 'c4e76822e7ab5b8c699fc6f9644d2c75022c03abf886ac3e270f4705b2d6f589'),
    },
    'KoboExport': {
        'directory': 'kobo-export', 'exe': 'kepubify.exe', 'repo': 'pgaskin/kepubify', 'tag': 'v4.0.4',
        'license': 'c37a2c194f63b0d175965205b756f76153194409408cf2c97174b6d48a0455bd',
        'Win32': ('kepubify-windows-32bit.exe', '5aa6be67f468e50e1b552a2eb1d1ac1afc375d1e7cb359e344f2e71d2dacdefb'),
        'Win64': ('kepubify-windows-64bit.exe', 'f3dee3ece063329661fef474262fe403812335bf1676eab35b672565bf195738'),
    },
}
ADVANCED_WRITERS = (*WRITERS, 'EpubPdfExport')
OPDS_TLS_TOOLCHAIN = 'go1.27.3'
DESCRIPTORS = {
    'BookProcessing': 'tools/bookconvert/MODULAR_RUNTIME.json',
    'ImageProcessing': 'tools/images/COMPONENT.json',
    'Kindle': 'tools/kindle/COMPONENT.json',
    'KindleExport': 'tools/kindle-export/COMPONENT.json',
    'LegacyBooks': 'tools/bookconvert/vendor/calibre_legacy/COMPONENT.json',
    'LegacyOffice': 'tools/office/COMPONENT.json',
    'XPS': 'tools/xps/COMPONENT.json',
    'EpubPdfExport': 'tools/epub-pdf/COMPONENT.json',
    'KfxExport': 'tools/kfx-export/COMPONENT.json',
    'OPDSTls': 'tools/opds-tls/COMPONENT.json',
    **{component: 'tools/' + writer['directory'] + '/COMPONENT.json' for component, writer in WRITERS.items()},
}
NOTES = {
    'BookProcessing': 'Обработка FB2/EPUB и текстов, упаковка коллекций. Декодеры Kindle, Office, XPS, PDF и DjVu устанавливаются отдельно.',
    'ImageProcessing': 'Сжатие иллюстраций и сканированных страниц. Без чтения документов XPS.',
    'Kindle': 'Чтение MOBI/AZW/KF8 через KindleUnpack. Общая среда обработки устанавливается отдельно при необходимости.',
    'KindleExport': 'Сохранение MOBI7/KF8 и AZW3 через Kindling. Устанавливается только для записи Kindle; без декодеров других форматов.',
    'LegacyBooks': 'Дополнительные кодеки старых LIT/LRF и отдельных вариантов Mobipocket.',
    'LegacyOffice': 'Чтение WPS/WPD через libwps/libwpd. Для этих инструментов требуется 64-разрядная Windows.',
    'XPS': 'Чтение документов XPS. Для обычных FB2/EPUB этот компонент не нужен.',
    'FB2Export': 'fb2cng — сохранение FB2 в EPUB 2, EPUB 3, KEPUB, KFX, AZW8, PDF и Markdown.',
    'KoboExport': 'kepubify — прямое сохранение EPUB в KEPUB для Kobo.',
    'EpubPdfExport': 'Vivliostyle — прямая вёрстка EPUB в PDF через Microsoft WebView2 Runtime.',
    'KfxExport': 'Boko — прямое сохранение EPUB в KFX и AZW8 с подготовкой иллюстраций через resvg.',
    'OPDSTls': 'Каталог OPDS по HTTPS с сертификатом и закрытым ключом пользователя.',
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


def advanced_writer_payload(platform, component, source):
    if source is None:
        raise ValueError('The verified upstream writer files are required for ' + component)
    writer = WRITERS[component]
    asset_name, asset_hash = writer[platform]
    asset = source / asset_name
    license_bytes = (source / (component + '-LICENSE.txt')).read_bytes()
    if helper.digest(asset.read_bytes()) != asset_hash or helper.digest(license_bytes) != writer['license']:
        raise ValueError('Upstream asset or licence differs from the reviewed ' + component + ' release')
    if asset.suffix == '.zip':
        with zipfile.ZipFile(asset) as archive:
            # The upstream archive also contains a separate connector.
            binary = archive.read(writer['exe'])
    else:
        binary = asset.read_bytes()
    helper.binary_platform(binary, platform)
    upstream = 'https://github.com/' + writer['repo']
    prefix = 'tools/' + writer['directory'] + '/'
    payload = {
        prefix + writer['exe']: binary,
        prefix + 'LICENSE.txt': license_bytes,
        prefix + 'SOURCE.txt': (
            'Unmodified executable from ' + upstream + '/releases/tag/' + writer['tag'] + '\n'
            'Source code and build files for this version: ' + upstream + '/tree/' + writer['tag'] + '\n'
            'Source archive: ' + upstream + '/archive/refs/tags/' + writer['tag'] + '.zip\n'
            'Upstream asset: ' + asset_name + '\nSHA-256: ' + asset_hash + '\n').encode('ascii'),
    }
    return payload, list(payload)


def kfx_writer_payload(platform, source):
    if source is None:
        raise ValueError('Verified Boko and resvg runtimes are required for KfxExport')
    prefix = 'tools/kfx-export/'
    payload = tree(source / ('KfxExport-' + platform), prefix.rstrip('/'))
    metadata = json.loads(payload[prefix + 'RUNTIME.json'])
    commit = '9ac23f67a51e6911125a78fc0f876c8367388f3d'
    if (metadata['format'] != 1 or metadata['platform'] != platform or metadata['boko_commit'] != commit
            or metadata['target'] != {'Win32': 'i686-pc-windows-gnu', 'Win64': 'x86_64-pc-windows-gnu'}[platform]):
        raise ValueError('Unexpected KfxExport runtime identity')
    tools = {record['name']: record for record in metadata['tools']}
    if len(metadata['tools']) != 2 or set(tools) != {'boko', 'resvg'}:
        raise ValueError('Unexpected KfxExport runtime inventory')
    for name, version in (('boko', '0.6.0'), ('resvg', '0.49.0')):
        binary = payload[prefix + name + '.exe']
        record = tools[name]
        if (record['version'] != version or record['bytes'] != len(binary)
                or record['sha256'] != helper.digest(binary)):
            raise ValueError('Unexpected KfxExport binary: ' + name)
        helper.binary_platform(binary, platform)
    patch = 'boko-epub-navigation.patch'
    if payload[prefix + patch] != (REPO / 'scripts' / patch).read_bytes():
        raise ValueError('The verified Boko patch differs from the repository')
    payload[prefix + 'build-kfx-export.py'] = (REPO / 'scripts/build-kfx-export.py').read_bytes()
    payload[prefix + 'SOURCE.txt'] = (
        'Boko 0.6.0, GPL-3.0-or-later, with the accompanying navigation patch.\n'
        'https://github.com/zacharydenton/boko/tree/' + commit + '\n'
        'resvg 0.49.0, MIT or Apache-2.0.\n'
        'Corresponding source, dependencies and offline build instructions:\n'
        'https://github.com/Dicur3x/MyHomeLib/releases/download/' + helper.COMPONENT_RELEASE_TAG +
        '/Boko-0.6.0-HomeLibre-source.zip\n'
        'See RUNTIME.json for platform, target and binary identities.\n').encode('ascii')
    required = [prefix + name for name in ('boko.exe', 'resvg.exe', 'RUNTIME.json', 'SOURCE.txt', patch,
                                            'boko-LICENSE', 'resvg-LICENSE-APACHE', 'resvg-LICENSE-MIT',
                                            'build-kfx-export.py')]
    if any(name not in required and not name.startswith(prefix + 'ThirdPartyLicenses/') for name in payload):
        raise ValueError('Unexpected file in KfxExport runtime')
    return payload, required


def webview_renderer(platform, sdk):
    arch = 'x86' if platform == 'Win32' else 'x64'
    core = 'Microsoft.Web.WebView2.Core.dll'
    loader = 'WebView2Loader.dll'
    with zipfile.ZipFile(io.BytesIO(sdk)) as package:
        files = {
            core: package.read('lib/net462/' + core),
            loader: package.read(f'runtimes/win-{arch}/native/' + loader),
            'WebView2-LICENSE.txt': package.read('LICENSE.txt'),
            'WebView2-NOTICE.txt': package.read('NOTICE.txt'),
        }
    helper.binary_platform(files[loader], platform)
    compiler = Path(os.environ['SystemRoot']) / 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
    source = REPO / 'Utils/HomeLibEpubPdf/HomeLibEpubPdf.cs'
    with tempfile.TemporaryDirectory(prefix='homelibre-webview2-build-') as folder:
        build = Path(folder)
        (build / core).write_bytes(files[core])
        target = build / 'HomeLibEpubPdf.exe'
        subprocess.run([str(compiler), '/nologo', '/codepage:65001', '/optimize+', '/target:exe',
                        '/platform:' + arch, '/out:' + str(target), '/r:' + str(build / core),
                        '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Web.Extensions.dll',
                        str(source)], check=True)
        files[target.name] = target.read_bytes()
        helper.binary_platform(files[target.name], platform)
    return {'runtime/' + name: data for name, data in files.items()}


def epub_pdf_payload(platform, source):
    if source is None:
        raise ValueError('The verified upstream EPUB PDF files are required for EpubPdfExport')

    def verified(name, sha256):
        data = (source / name).read_bytes()
        if helper.digest(data) != sha256:
            raise ValueError('Upstream EPUB PDF file differs from reviewed source: ' + name)
        return data

    core = verified('core-2.45.2.tgz', '114d4fb8deb5bdafc2aeb2baa983e38c869ff7103ae4f4c4e1550726dd99df58')
    diff = verified('fast-diff-1.3.0.tgz', '77f602d83366f68f4dfb5dd9ba636933dc0047502da4d48d914d1d361c517d4a')
    with tarfile.open(fileobj=io.BytesIO(core), mode='r:gz') as archive:
        script = archive.extractfile('package/lib/vivliostyle.js').read()
    with tarfile.open(fileobj=io.BytesIO(diff), mode='r:gz') as archive:
        diff_license = archive.extractfile('package/LICENSE').read()
    files = {
        'epub_pdf_output.py': (REPO/'tools/bookconvert/epub_pdf_output.py').read_bytes(),
        'viewer/vivliostyle.js': script,
        'LICENSE.txt': verified('Vivliostyle-LICENSE.txt', '57c8ff33c9c0cfc3ef00e650a1cc910d7ee479a8bc509f6c9209a7c2a11399d6'),
        'fast-diff-LICENSE.txt': diff_license,
        'runtime/pypdf.whl': verified('pypdf-6.21.4-py3-none-any.whl',
            '33e4fb41ca352810eb4e9838aa0d82d6888a5f8bf682f43e99cce5faa666255c'),
        'SOURCE.txt': (
            'Vivliostyle Core 2.45.2 (AGPL-3.0). Unmodified JavaScript from:\n'
            'https://registry.npmjs.org/@vivliostyle/core/-/core-2.45.2.tgz\n'
            'Corresponding source and build files for this version:\n'
            'https://github.com/vivliostyle/vivliostyle.js/archive/refs/tags/v2.45.2.zip\n'
            'Bundled fast-diff source (Apache-2.0): https://registry.npmjs.org/fast-diff/-/fast-diff-1.3.0.tgz\n'
            'The unmodified Python wheel contains its licence. Upstream source distribution:\n'
            'https://pypi.org/project/pypdf/6.21.4/#files\n'
            'WebView2 SDK 1.0.3967.48: https://www.nuget.org/packages/Microsoft.Web.WebView2/1.0.3967.48\n'
            'The required Microsoft WebView2 Runtime is distributed separately by Microsoft.\n'
            'The print host and worker source are in epub_pdf_output.py and Utils/HomeLibEpubPdf/HomeLibEpubPdf.cs.\n'
            'Source repository: https://github.com/Dicur3x/MyHomeLib\n').encode('ascii'),
    }
    files.update(webview_renderer(platform, verified('microsoft.web.webview2.1.0.3967.48.nupkg',
        'c66357ac7f324ec9bcafe5241706a023b4122d8c22300c31de4b0eb220db689e')))
    payload = {'tools/epub-pdf/' + name: data for name, data in files.items()}
    return payload, list(payload)


def opds_tls_payload(platform, go):
    if go is None:
        raise ValueError('Pass the verified Go toolchain using --opds-tls-go')
    env = dict(os.environ, GOTOOLCHAIN='local', GOTELEMETRY='off', GOENV='off', GOFLAGS='',
               GOOS='windows', GOARCH={'Win32':'386', 'Win64':'amd64'}[platform],
               CGO_ENABLED='0', GOPROXY='off')
    version = subprocess.check_output([str(go), 'env', 'GOVERSION'], env=env, text=True).strip()
    if version != OPDS_TLS_TOOLCHAIN:
        raise ValueError('OPDS HTTPS requires ' + OPDS_TLS_TOOLCHAIN)
    goroot = Path(subprocess.check_output([str(go), 'env', 'GOROOT'], env=env, text=True).strip())
    with tempfile.TemporaryDirectory(prefix='homelibre-opds-package-') as temporary:
        root = Path(temporary)
        binary = root/'HomeLibreOPDSTls.exe'
        env['GOCACHE'] = str(root/'cache')
        subprocess.run([str(go), 'build', '-trimpath', '-buildvcs=false', '-ldflags=-s -w',
                        '-o', str(binary), str(REPO/'tools/opds-tls/main.go')], env=env, check=True)
        data = binary.read_bytes()
        helper.binary_platform(data, platform)
    payload = {'tools/opds-tls/HomeLibreOPDSTls.exe': data,
               'tools/opds-tls/GO-LICENSE.txt': (goroot/'LICENSE').read_bytes(),
               'tools/opds-tls/GO-PATENTS.txt': (goroot/'PATENTS').read_bytes()}
    return payload, list(payload)


def payload_for(platform, component, kindle_export_root=None, advanced_export_root=None, opds_tls_go=None,
                kfx_export_root=None):
    if component == 'OPDSTls':
        return opds_tls_payload(platform, opds_tls_go)
    if component == 'EpubPdfExport':
        return epub_pdf_payload(platform, advanced_export_root)
    if component == 'KfxExport':
        return kfx_writer_payload(platform, kfx_export_root)
    if component in WRITERS:
        return advanced_writer_payload(platform, component, advanced_export_root)
    runtime = REPO/'Program/Out'/('Bin' if platform == 'Win32' else 'Bin64')/'tools'
    if component == 'BookProcessing':
        payload = tree(runtime/'kindle/python', 'tools/python')
        payload.update(tree(REPO/'tools/bookconvert', 'tools/bookconvert',
                            ('vendor/calibre_legacy', 'kindle_input.py', 'kindle_output.py', 'legacy_helper.py',
                             'epub_pdf_output.py', 'COMPONENT.json')))
        # The installed path is within the existing BookProcessing allowlist,
        # so older updater helpers can install the same component ZIP.
        worker = 'tools/bookconvert/pack_collection.py'
        payload[worker] = (REPO/'tools/collectionpack/pack_collection.py').read_bytes()
        sql_workers = ['tools/bookconvert/catalogdump/' + name for name in ('build_index.py', 'mysql_dump.py')]
        for name in sql_workers:
            payload[name] = (REPO/'tools/catalogdump'/Path(name).name).read_bytes()
        payload['tools/bookconvert/MODULAR_API.txt'] = b'1\n'
        required = ['tools/python/python.exe', 'tools/bookconvert/convert_book.py',
                    'tools/bookconvert/MODULAR_API.txt', 'tools/bookconvert/IMAGE_CONTAINER_API.txt', 'tools/python/python313.dll',
                    'tools/python/python313.zip', 'tools/python/python313._pth',
                    'tools/bookconvert/ADVANCED_EXPORT_API.txt', 'tools/bookconvert/advanced_output.py',
                    'tools/bookconvert/markdown_output.py', 'tools/bookconvert/epub2_output.py', 'tools/bookconvert/epub3_output.py',
                    'tools/bookconvert/epub_kfx_output.py', 'tools/bookconvert/kfx_image_input.py',
                    'tools/bookconvert/image_quality.py', worker, *sql_workers]
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
    elif component == 'KindleExport':
        source = (Path(kindle_export_root)/('KindleExport-'+platform) if kindle_export_root
                  else runtime/'kindle-export')
        payload = tree(source, 'tools/kindle-export', ('COMPONENT.json',))
        payload['tools/bookconvert/kindle_output.py'] = (REPO/'tools/bookconvert/kindle_output.py').read_bytes()
        required = ['tools/kindle-export/kindling-cli.exe', 'tools/kindle-export/RUNTIME.json',
                    'tools/kindle-export/Kindling-LICENSE.txt', 'tools/bookconvert/kindle_output.py']
        helper.binary_platform(payload[required[0]], platform)
        descriptor = json.loads(payload[required[1]].decode('utf-8-sig'))
        if (descriptor['platform'] != platform or descriptor['commit'] != '3b91b1ea21f892779be09149f21fe4053b1b3569'
                or descriptor['sha256'] != helper.digest(payload[required[0]])
                or '+crt-static' not in descriptor['rustflags']):
            raise ValueError('Kindle writer must be built from the verified pinned source for this architecture')
        patches = ('kindling-windows-epub-paths.patch', 'kindling-svg-compat.patch')
        if set(descriptor.get('source_patches', {})) != set(patches):
            raise ValueError('Kindle writer is missing the verified source compatibility fixes')
        for name in patches:
            compiled = payload.get('tools/kindle-export/' + name, b'')
            expected = (REPO / 'scripts' / name).read_bytes()
            if (descriptor['source_patches'][name] != helper.digest(compiled)
                    or compiled.replace(b'\r\n', b'\n') != expected.replace(b'\r\n', b'\n')):
                raise ValueError('Kindle writer compatibility fix differs from the reviewed source: ' + name)
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


def package(output, platform, component, version, kindle_export_root=None, advanced_export_root=None, opds_tls_go=None,
            kfx_export_root=None):
    payload, required = payload_for(platform, component, kindle_export_root, advanced_export_root, opds_tls_go,
                                    kfx_export_root)
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
    parser.add_argument('--component', choices=COMPONENTS + ADVANCED_WRITERS + ('OPDSTls', 'KfxExport'), action='append')
    parser.add_argument('--kindle-export-root', type=Path, help='Verified CI artifacts containing KindleExport-Win32/Win64')
    parser.add_argument('--advanced-export-root', type=Path, help='Pinned upstream files and licenses for optional writers')
    parser.add_argument('--opds-tls-go', type=Path, help='Verified Go executable for the optional OPDS HTTPS transport')
    parser.add_argument('--kfx-export-root', type=Path, help='Verified Boko and resvg runtime artifacts')
    options=parser.parse_args()
    import re
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+){0,2}', options.version): parser.error('Invalid component version')
    entries=[]; assets=[]
    components = options.component or COMPONENTS + (ADVANCED_WRITERS if options.advanced_export_root else ()) + (
        ('OPDSTls',) if options.opds_tls_go else ()) + (('KfxExport',) if options.kfx_export_root else ())
    for platform in options.platform or ('Win32','Win64'):
        for component in components:
            entry, asset=package(options.output.resolve(), platform, component, options.version,
                                 options.kindle_export_root, options.advanced_export_root, options.opds_tls_go,
                                 options.kfx_export_root)
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
