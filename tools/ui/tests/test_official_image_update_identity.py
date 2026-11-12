"""Exercise real JPEG XL download preparation and the identity passed to installation.

Use an unmodified upstream ZIP and release metadata. Only HTTP transport is mapped
to an owned loopback server; native URL, checksum, version and PE checks still run.
"""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    metadata = json.loads(args.release.read_text(encoding='utf-8-sig'))
    results = []
    server = None
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-image-') as raw:
        root = Path(raw).resolve()
        release = root / 'release.json'
        release.write_text(json.dumps(metadata), encoding='utf-8')
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.removeprefix('/')
                asset = next((a for a in metadata['assets'] if a['name'] == name), None)
                if not asset:
                    self.send_error(404)
                    return
                package = args.packages / name
                requests.append(name)
                self.send_response(200)
                self.send_header('Content-Length', str(package.stat().st_size))
                self.end_headers()
                with package.open('rb') as source:
                    shutil.copyfileobj(source, self.wfile, 1024 * 1024)

            def log_message(self, *unused):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        started = time.monotonic()

        def run(*params, expected=0):
            result = subprocess.run([str(args.native), *map(str, params)],
                                    capture_output=True, encoding='utf-8', timeout=90,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            assert result.returncode == expected, (params, result.returncode, result.stdout, result.stderr)
            return result.stdout

        try:
            machine = args.native.read_bytes()
            pe = int.from_bytes(machine[0x3c:0x40], 'little')
            architecture = 'Win64' if int.from_bytes(machine[pe+4:pe+6], 'little') == 0x8664 else 'Win32'
            suffix = 'x64' if architecture == 'Win64' else 'x86'
            name = f'jxl-{suffix}-windows-static.zip'
            asset = next(a for a in metadata['assets'] if a['name'] == name)
            package = args.packages / name
            assert package.stat().st_size == asset['size']
            assert hashlib.sha256(package.read_bytes()).hexdigest() == asset['digest'].removeprefix('sha256:')
            jobs = []
            for component in ['JPEG XL', 'JpegXLEncoder']:
                job = root / ('decoder' if component == 'JPEG XL' else 'encoder')
                text = run('--download-image-fixture', release, component,
                           f'http://127.0.0.1:{server.server_port}/{name}', job)
                detail = json.loads(text.strip())
                manifest = json.loads((job / 'manifest.json').read_text(encoding='utf-8-sig'))
                assert detail['source_tag'] == metadata['tag_name']
                assert detail['prepared_tag'] == manifest['release'] == detail['version']
                assert detail['requests'] == 1 and detail['sha256'] == asset['digest'][7:]
                assert detail['url'] == 'https://github.com/libjxl/libjxl/releases'
                target = root / ('installed-' + job.name)
                target.mkdir()
                shutil.copy2(args.native, target / 'HomeLibRu.exe')
                (target / 'personal-note.txt').write_text('keep my note', encoding='utf-8')
                run('--install', job, target)
                for item in manifest['files']:
                    output = target / item['path']
                    assert output.stat().st_size == item['size']
                    assert hashlib.sha256(output.read_bytes()).hexdigest() == item['sha256']
                assert (target / 'HomeLibRu.exe').read_bytes() == machine
                assert (target / 'personal-note.txt').read_text(encoding='utf-8') == 'keep my note'
                results.append(dict(installed_files=len(manifest['files']), **detail))
                jobs.append(job)

            bundle = root / 'combined'
            run('--combine', bundle, metadata['tag_name'].removeprefix('v'), *jobs)
            run('--verify', bundle, metadata['tag_name'].removeprefix('v'))
            mixed_target = root / 'installed-bundle'
            mixed_target.mkdir()
            shutil.copy2(args.native, mixed_target / 'HomeLibRu.exe')
            run('--install', bundle, mixed_target)
            assert (mixed_target / 'tools/jpeg-xl/djxl.exe').is_file()
            assert (mixed_target / 'tools/jpeg-xl-encoder/cjxl.exe').is_file()
            # Preserve the long-path reproduction that exposed a borrowed-string
            # alias in official preparation's AddFile helper.
            deep_job = root / ('cache-' + 'x' * 130) / 'HomeLibRu-update-deep'
            run('--official-prepare', jobs[0] / 'release.zip', deep_job, 'JPEG XL',
                metadata['tag_name'].removeprefix('v'))
            run('--verify', deep_job, metadata['tag_name'].removeprefix('v'))
            deep_manifest = json.loads((deep_job / 'manifest.json').read_text(encoding='utf-8-sig'))
            longest_path = max(len(str(deep_job / 'payload' / item['path'])) for item in deep_manifest['files'])
            assert longest_path > 260
            deep_target = root / ('destination-' + 'z' * 130) / 'HomeLibre'
            deep_target.mkdir(parents=True)
            shutil.copy2(args.native, deep_target / 'HomeLibRu.exe')
            run('--install', deep_job, deep_target)
            for item in deep_manifest['files']:
                assert hashlib.sha256((deep_target / item['path']).read_bytes()).hexdigest() == item['sha256']
            rejected = run('--verify', bundle, '0.0.0', expected=1)
            assert not rejected.strip()  # Error goes to stderr; the mismatched request is rejected.
            assert requests == [name, name]
            report = dict(status='PASS', architecture=architecture, results=results,
                          combined_install=True, wrong_release_rejected=True,
                          deep_prepare_install=True, longest_prepared_path=longest_path,
                          seconds=round(time.monotonic()-started, 3), requests=requests,
                          native_sha256=hashlib.sha256(machine).hexdigest(),
                          source_release=metadata['html_url'], package_sha256=asset['digest'][7:])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    report['temporary_data_removed'] = not root.exists()
    args.result.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
