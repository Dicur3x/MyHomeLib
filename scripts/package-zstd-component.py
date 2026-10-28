"""Package pinned official Zstandard DLLs as optional catalogue modules, offline."""
import argparse
import importlib.util
import json
from pathlib import Path
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader_packages', REPO/'scripts/package-reader-components.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
VERSION = '1.5.7'
SOURCES = {
    'Win32': ('231265caed189d933339cda2352e0905ae9076b43c534ba24f84fbab8f719a2d',
              '85853869cb2567890bf67be6eee8467676b636dd8dfc0f5c050cf984d4bae420'),
    'Win64': ('acb4e8111511749dc7a3ebedca9b04190e37a17afeb73f55d4425dbf0b90fad9',
              '8f07e1112ed283e5cd2798833e9a3c32d8961381bc36da04af57a1b0ca9bd40b'),
}


def package(output, platform):
    binary = (REPO/'Program/Resources/zstd'/platform/'libzstd.dll').read_bytes()
    helper.binary_platform(binary, platform)
    archive_hash, dll_hash = SOURCES[platform]
    if helper.digest(binary) != dll_hash:
        raise ValueError('Zstandard DLL differs from the verified official release')
    source = f'https://github.com/facebook/zstd/releases/download/v{VERSION}/zstd-v{VERSION}-{platform.lower()}.zip'
    descriptor = dict(format=1, version=VERSION, platform=platform, dll_sha256=dll_hash,
                      source_url=source, source_archive_sha256=archive_hash,
                      license_url=f'https://github.com/facebook/zstd/blob/v{VERSION}/LICENSE')
    payload = {'libzstd.dll': binary,
               'tools/zstd/LICENSE': (REPO/'Program/Resources/zstd/LICENSE').read_bytes(),
               'tools/zstd/RUNTIME.json': helper.json_bytes(descriptor)}
    manifest = dict(format=1, release=helper.publication_tag(helper.COMPONENT_RELEASE_TAG),
                    platform=platform, component='Zstandard', version=VERSION,
                    files=[dict(path=name, size=len(data), sha256=helper.digest(data))
                           for name, data in sorted(payload.items())])
    payload['HomeLibRu.update.json'] = helper.json_bytes(manifest)
    output.mkdir(parents=True, exist_ok=True)
    destination = output/f'HomeLibRu-Zstandard-{VERSION}-{platform}.zip'
    with destination.open('xb') as stream, zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            info=zipfile.ZipInfo(name,(2026,10,28,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o644<<16; archive.writestr(info,data)
    with zipfile.ZipFile(destination) as check:
        assert check.testzip() is None
        for file in manifest['files']:
            data=check.read(file['path'])
            assert len(data)==file['size'] and helper.digest(data)==file['sha256']
    return dict(id='Zstandard', platform=platform, version=VERSION, archive=destination.name,
                history=[dict(version=VERSION, notes='Официальная библиотека Zstandard для открытия каталогов Metabib .jsonl.zst. Установка только по запросу.')]), dict(
                    name=destination.name, size=destination.stat().st_size,
                    digest='sha256:'+helper.digest(destination.read_bytes()),
                    browser_download_url='https://github.com/Dicur3x/MyHomeLib/releases/download/'+helper.COMPONENT_RELEASE_TAG+'/'+destination.name)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    options=parser.parse_args()
    entries=[]; assets=[]
    for platform in ('Win32','Win64'):
        entry,asset=package(options.output.resolve(),platform); entries.append(entry); assets.append(asset)
    feed=helper.json_bytes(dict(format=1,components=entries))
    with (options.output/'HomeLibRu.components.json').open('xb') as stream: stream.write(feed)
    assets.append(dict(name='HomeLibRu.components.json',size=len(feed),
                       browser_download_url='https://github.com/Dicur3x/MyHomeLib/releases/download/'+helper.COMPONENT_RELEASE_TAG+'/HomeLibRu.components.json'))
    metadata=dict(draft=False,prerelease=False,tag_name=helper.COMPONENT_RELEASE_TAG,assets=assets)
    with (options.output/'local-mirror-release.json').open('xb') as stream: stream.write(helper.json_bytes(metadata))
    print(json.dumps(metadata,ensure_ascii=False,indent=2))
