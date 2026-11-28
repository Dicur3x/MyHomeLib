"""Exercise an application-first update with a self-contained DocSharp bundle."""

import argparse
from hashlib import file_digest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
from zipfile import ZipFile


def sha(path):
    with path.open('rb') as stream:
        return file_digest(stream, 'sha256').hexdigest()


def manifest(path):
    with ZipFile(path) as archive:
        return json.loads(archive.read('HomeLibRu.update.json'))


def extract(path, target, prefix=''):
    with ZipFile(path) as archive:
        for member in archive.namelist():
            parts = PurePosixPath(member)
            assert not parts.is_absolute() and '..' not in parts.parts and not any(c in member for c in '\\:')
            if member.startswith(prefix) and member != 'HomeLibRu.update.json':
                archive.extract(member, target)


def run_case(args, url):
    new = manifest(args.current)
    older = manifest(args.previous)
    office = manifest(args.docsharp)
    assert office['component']=='DocSharp' and new['platform']==older['platform']==office['platform']
    assert older['release']!=new['release']
    assert any(part['component']=='DocSharp' and part['version']==office['version'] for part in new['bundle'])
    root = args.temp.resolve(strict=True)

    with TemporaryDirectory(dir=root, prefix='HomeLibRu-update-test-docsharp-queue-') as folder:
        work = Path(folder)
        env = dict(os.environ, TEMP=str(work), TMP=str(work), APPDATA=str(work/'roaming'), LOCALAPPDATA=str(work/'local'))

        def native(*command):
            result = subprocess.run([str(args.native.resolve()), *map(str,command)], cwd=work, env=env,
                                    capture_output=True,text=True,encoding='utf8',timeout=180,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            assert result.returncode==0, (command,result.stdout,result.stderr)
            return result.stdout

        def prepare(path,key):
            description=manifest(path)
            materialized=work/f'{key}.zip'
            shutil.copy2(path, materialized)
            job=work/f'HomeLibRu-update-{key}'
            component=description.get('component')
            if component:
                native('--prepare-component',materialized,sha(path),description['release'],job,
                       component,description['version'])
            else:
                native('--prepare',materialized,sha(path),description['release'],job)
            shutil.copy2(path,job/'release.zip')
            return job

        target=work/'installation'
        extract(args.previous,target)
        extract(args.previous_full,target,'tools/doc/')
        for marker in ('uselocaldata','uselocaltemp'):
            (target/marker).touch()
        sentinel=target/'Data/personal.txt'
        sentinel.parent.mkdir()
        sentinel.write_text('Preserve collection files in the combined upgrade.',encoding='utf8')
        before=sha(sentinel)
        metadata='tools/doc/DOC_RUNTIME.json'
        previous_version=json.loads((target/metadata).read_bytes())['bundle_version']
        assert previous_version!=office['version']
        assert {'id':'DocSharp','version':previous_version}.items() <= next(
            item for item in json.loads(native('--runtime-state',target).splitlines()[0]) if item['id']=='DocSharp').items()

        original=prepare(args.previous,'original-catalogue')/'payload'
        assert not (original/'tools/doc/HomeLibDoc.exe').exists()
        main=prepare(args.current,'main')
        adapter_names=('HomeLibDoc.exe','HomeLibDoc-MIT.txt','DocSharp-MIT.txt','b2xtranslator-BSD-3-Clause.txt')
        assert all((main/'payload/tools/doc'/name).is_file() for name in adapter_names)
        downloaded=work/'HomeLibRu-update-docsharp'
        log=native('--download-doc-bundle',url,args.docsharp.stat().st_size,sha(args.docsharp),
                   office['release'],downloaded,office['version'],original)
        assert 'ADAPTER 0' in log and not (downloaded/'native-adapter.zip').exists()
        expected=json.loads((downloaded/'payload'/metadata).read_bytes())['helper_sha256']
        assert sha(main/'payload/tools/doc/HomeLibDoc.exe')==expected

        extra=[prepare(path,f'extra-{i}') for i,path in enumerate(args.component)]
        final=work/'HomeLibRu-update-combined'
        native('--combine-background',final,new['release'],main,downloaded,*extra)
        native('--install',final,target)
        runtime=json.loads(native('--runtime-state',target).splitlines()[0])
        installed=next(item for item in runtime if item['id']=='DocSharp')
        assert installed['version']==office['version'] and not installed['repair']
        assert sha(target/'tools/doc/HomeLibDoc.exe')==expected and sha(sentinel)==before
        versions={item['id']:item['version'] for item in runtime if not item['repair']}
        for package in args.component:
            part=manifest(package)
            assert versions[part['component']]==part['version']
        return dict(platform=new['platform'], source_release=older['release'], target_release=new['release'],
                    source_docsharp=previous_version, target_docsharp=installed['version'], adapter_download=False,
                    preserved_personal_file=True, other_components=len(extra), compact_sha256=sha(args.current))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('native','previous','previous-full','current','docsharp','temp'):
        parser.add_argument(f'--{name}',type=Path,required=True)
    parser.add_argument('--component',type=Path,action='append',default=[])
    parser.add_argument('--asset-url')
    args=parser.parse_args()
    if args.asset_url:
        result=run_case(args,args.asset_url)
    else:
        payload=args.docsharp.read_bytes()

        class Download(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path!='/docsharp.zip':
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length',str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(('127.0.0.1',0), Download) as server:
            thread=Thread(target=server.serve_forever,daemon=True)
            thread.start()
            try:
                result=run_case(args,f'http://127.0.0.1:{server.server_port}/docsharp.zip')
            finally:
                server.shutdown()
    print(json.dumps(result,ensure_ascii=False),flush=True)


if __name__=='__main__':
    main()
