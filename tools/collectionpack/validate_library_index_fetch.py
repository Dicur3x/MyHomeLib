"""Real native local/HTTP index staging against disposable, isolated fixtures."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import random
import threading
import time
import traceback
from urllib.parse import unquote

from pack_collection import temporary_work_directory
from supervised_test_process import run_owned
from validate_compression_inspection import check_pe


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    binary = args.binary.resolve(strict=True)
    check_pe(binary,args.platform)
    report = args.report.resolve()
    started = time.monotonic()
    result = dict(status='INCOMPLETE',platform=args.platform,binary_sha256=sha(binary),runs=[])
    report.write_text(json.dumps(result,indent=2),encoding='utf-8')
    payload = random.Random(371).randbytes(1024*1024)
    requests = []

    class Server(BaseHTTPRequestHandler):
        def log_message(self,*_args): pass
        def do_GET(self):
            path = unquote(self.path)
            requests.append(path)
            if path != '/individual/folder/индекс с пробелом.inpx':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length',str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(('127.0.0.1',0),Server)
    worker = threading.Thread(target=server.serve_forever,daemon=True)
    worker.start()
    try:
        with temporary_work_directory(args.stage,'HomeLibre-index-fetch-') as root:
            for long in (False,True):
                fixture = root/('long' if long else 'normal')
                if long:
                    fixture = fixture/('Длинная папка ё '*8).rstrip()/('новые книги '*9).rstrip()
                source = fixture/'source/индекс с пробелом.inpx'
                source.parent.mkdir(parents=True)
                source.write_bytes(payload)
                cache = fixture/'cache'
                cache.mkdir()
                keep = cache/'outside-note.txt'
                keep.write_bytes(b'Keep other cached data')
                before = sha(source)
                process = run_owned([str(binary),str(source),str(cache),
                    f'http://127.0.0.1:{server.server_port}/individual'],
                    capture_output=True,encoding='utf-8',errors='replace',timeout=45)
                row = dict(long_path=long,source_path_length=len(str(source)),
                    code=process.returncode,stdout=process.stdout,stderr=process.stderr)
                result['runs'].append(row)
                assert process.returncode==0 and process.stdout.startswith('PASS:'),row
                assert sha(source)==before
                assert keep.read_bytes()==b'Keep other cached data'
                assert list(cache.iterdir())==[keep],list(cache.iterdir())
                row.update(source_unchanged=True,private_staging_removed=True,other_cache_unchanged=True)
        result.update(status='PASS',private_fixture_removed=not root.exists(),requests=requests)
        assert result['private_fixture_removed']
        assert requests.count('/individual/folder/индекс с пробелом.inpx')==2,requests
        assert requests.count('/individual/missing.inpx')==2,requests
    except BaseException:
        result.update(status='FAIL',error=traceback.format_exc(),requests=requests)
        raise
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        result['elapsed_seconds']=round(time.monotonic()-started,3)
        report.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps(result,ensure_ascii=True))


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--platform',choices=('Win32','Win64'),required=True)
    parser.add_argument('--stage',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    run(parser.parse_args())
