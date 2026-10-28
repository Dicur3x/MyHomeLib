"""Package the optional MCP server from verified local builds, without downloads."""
import argparse
import importlib.util
import json
from pathlib import Path
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('reader_packages', REPO/'scripts/package-reader-components.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def package(output, platform):
    runtime = REPO/'Program/Out'/('Bin' if platform == 'Win32' else 'Bin64')
    executable = runtime/'MHLMcpServer.exe'
    binary = executable.read_bytes()
    helper.binary_platform(binary, platform)
    version = helper.file_version(executable)
    payload = {'MHLMcpServer.exe': binary, 'MHLMcpServer-LICENSE.txt': (REPO/'LICENSE').read_bytes(),
               'MHLMcpServer-README.txt': (
                   'MCP-сервер HomeLib Ru\n\n'
                   'Необязательный модуль подключения AI-приложения к коллекциям HomeLib Ru.\n'
                   'Установите рядом с HomeLibRu.exe; используется общая sqlite3.dll соответствующей разрядности.\n'
                   'В каталогизаторе откройте «Инструменты → Подключить AI-ассистента…» и скопируйте настройки.\n'
                   'Сам каталогизатор сервер не запускает. Его запускает настроенное вами AI-приложение.\n'
                   'MCP работает через стандартный ввод/вывод (stdio), без сетевого порта.\n'
                   'Профили и коллекции в архив не включены.\n').encode('utf8')}
    manifest = dict(format=1, release=helper.publication_tag(helper.COMPONENT_RELEASE_TAG),
                    platform=platform, component='MHLMcpServer', version=version,
                    files=[dict(path=name, size=len(data), sha256=helper.digest(data))
                           for name, data in sorted(payload.items())])
    payload['HomeLibRu.update.json'] = helper.json_bytes(manifest)
    output.mkdir(parents=True, exist_ok=True)
    destination = output/f'HomeLibRu-MHLMcpServer-{version}-{platform}.zip'
    with destination.open('xb') as stream, zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(payload.items()):
            info=zipfile.ZipInfo(name,(2026,10,28,0,0,0)); info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o644<<16; archive.writestr(info,data)
    with zipfile.ZipFile(destination) as check:
        assert check.testzip() is None
        for file in manifest['files']:
            data=check.read(file['path'])
            assert len(data)==file['size'] and helper.digest(data)==file['sha256']
    return dict(id='MHLMcpServer', platform=platform, version=version, archive=destination.name,
                history=[dict(version=version, notes='Отдельный модуль подключения AI-ассистента к коллекциям. Устанавливается только по запросу.')]), dict(
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
