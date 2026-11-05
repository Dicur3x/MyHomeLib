"""Render EPUB pages with a private WebView2 Runtime profile."""

from contextlib import contextmanager, closing
import http.server
import io
import mimetypes
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import quote, unquote, urlencode, urlsplit


EPUB_TYPES = {
    '.js': 'text/javascript',
    '.opf': 'application/oebps-package+xml',
    '.xhtml': 'application/xhtml+xml',
    '.ncx': 'application/x-dtbncx+xml',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
}

HOST = b"""<!doctype html><meta charset="utf-8">
<style>
html, body, #pages { margin: 0; width: 100%; height: 100%; }
</style>
<div id="pages"></div><script type="module" src="host.js"></script>
"""

HOST_SCRIPT = b"""
window.module = {exports: {}};
await import('./vivliostyle.js');
const {CoreViewer} = window.module.exports;
delete window.module;
const source = new URL(new URLSearchParams(location.hash.slice(1)).get('source'), location.href);
const viewer = new CoreViewer({viewportElement: document.querySelector('#pages')}, {
    autoResize: false, allowScripts: false, renderAllPages: true,
    defaultPaperSize: {width: 794, height: 1123},
});
window.coreViewer = viewer;
viewer.addListener('error', ({content}) => { window.bookLoadFailed = String(content.error ?? content.messages); });
viewer.loadPublication(source.href);
"""


@contextmanager
def local_book(archive, viewer):
    prefix = '/' + secrets.token_urlsafe(24) + '/'
    engine = viewer / 'vivliostyle.js'
    if not engine.is_file():
        raise FileNotFoundError('Отсутствуют файлы модуля вёрстки EPUB.')
    assets = {'index.html': HOST, 'host.js': HOST_SCRIPT, 'vivliostyle.js': engine.read_bytes()}

    class Handler(http.server.BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(2)

        def log_message(self, *_):
            pass

        def handle(self):
            try:
                super().handle()
            except (ConnectionError, TimeoutError):
                pass

        def do_GET(self):
            if self.headers.get('Host') != authority or not self.path.startswith(prefix):
                self.send_error(404)
                return
            resource = unquote(urlsplit(self.path).path[len(prefix):])
            folder, _, name = resource.partition('/')
            if folder == 'viewer' and name in assets:
                data = assets[name]
                stream, size = io.BytesIO(data), len(data)
            elif folder == 'book' and name in archive.names and not name.endswith('/'):
                entry = archive.archive.getinfo(name)
                stream, size = archive.archive.open(entry), entry.file_size
            else:
                self.send_error(404)
                return
            with stream:
                extension = Path(name).suffix.lower()
                content_type = EPUB_TYPES.get(extension) or mimetypes.guess_type(name)[0]
                scripts = origin + prefix + 'viewer/' if folder == 'viewer' else "'none'"
                self.send_response(200)
                self.send_header('Content-Type', content_type or 'application/octet-stream')
                self.send_header('Content-Length', str(size))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.send_header('Content-Security-Policy',
                    f"default-src 'none'; script-src {scripts}; style-src 'self' 'unsafe-inline'; "
                    "img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'self' data:; "
                    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
                self.end_headers()
                shutil.copyfileobj(stream, self.wfile, length=128 * 1024)

    # Stop accepting requests and join active handlers before closing the ZIP.
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = False
    authority = f'127.0.0.1:{server.server_port}'
    origin = 'http://' + authority
    thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .1}, daemon=True)
    thread.start()
    try:
        yield origin, prefix
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def remove_profile(profile, work):
    if not profile.exists():
        return
    if profile.resolve().parent != work.resolve():
        raise ValueError('Папка вёрстки PDF находится вне рабочей папки.')
    # Chromium helpers can release their Windows file handles just after
    # the main browser process exits.
    deadline = time.monotonic() + 4
    while True:
        try:
            shutil.rmtree(profile)
            return
        except FileNotFoundError:
            if not profile.exists():
                return
            raise
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(.05)


def render_pdf(api, renderer, work, url, allowed, checkpoint):
    profile = work / 'browser-profile'
    cancel = work / 'cancel-epub-pdf'
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith('WEBVIEW2_')}
    env.update(TEMP=str(work), TMP=str(work))
    checkpoint()
    process = subprocess.Popen([str(renderer), url, allowed, str(api.MAX_TOTAL)], cwd=work,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               env=env, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    try:
        while True:
            checkpoint()
            try:
                _, stderr = process.communicate(timeout=.1)
                break
            except subprocess.TimeoutExpired:
                continue
    finally:
        try:
            if process.poll() is None:
                cancel.touch()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
        finally:
            remove_profile(profile, work)
    if process.returncode == 3:
        raise api.ConversionError('Для сохранения EPUB в PDF нужна среда Microsoft WebView2 Runtime.')
    if process.returncode:
        detail = stderr.decode('utf-8', errors='replace').strip()[:500]
        raise ValueError(detail or 'Модуль вёрстки PDF завершился с ошибкой.')


def convert(api, prepared, output, module_root, check):
    renderer = module_root / 'runtime' / 'HomeLibEpubPdf.exe'
    if not renderer.is_file():
        raise api.ComponentRequired('EpubPdfExport', 'Установите модуль вёрстки EPUB в PDF.')
    deadline = time.monotonic() + 240

    def checkpoint():
        if check is not None:
            check()
        if time.monotonic() >= deadline:
            raise api.ConversionError('Не удалось завершить вёрстку EPUB за четыре минуты.')

    # Isolate optional dependencies from other book-format components.
    runtime = module_root / 'runtime'
    sys.path.insert(0, str(runtime / 'pypdf.whl'))
    try:
        from pypdf import PdfReader, PdfWriter
        from pypdf.errors import PyPdfError
    except ImportError as error:
        raise api.ComponentRequired('EpubPdfExport', 'Установите модуль вёрстки EPUB в PDF.') from error
    finally:
        del sys.path[0]

    try:
        with closing(api.EpubArchive(prepared)) as archive:
            container = api.xml(archive.read('META-INF/container.xml'))
            rootfile = next((entry.get('full-path') for entry in container.iter()
                             if api.tag(entry) == 'rootfile' and entry.get('full-path')), '')
            package = api.xml(archive.read(rootfile))
            creators = [node.text.strip() for node in package.findall('.//{http://purl.org/dc/elements/1.1/}creator')
                        if node.text and node.text.strip()]
            title = package.findtext('.//{http://purl.org/dc/elements/1.1/}title', '').strip()
            with local_book(archive, module_root / 'viewer') as (origin, prefix):
                url = origin + prefix + 'viewer/index.html#' + urlencode({'source': '../book/' + quote(rootfile)})
                render_pdf(api, renderer, output.parent, url, origin + prefix, checkpoint)
                raw_pdf = output.parent / 'rendered.pdf'

        checkpoint()
        with raw_pdf.open('rb') as rendered:
            reader = PdfReader(rendered)
            if not len(reader.pages):
                raise ValueError('В полученном PDF отсутствуют страницы.')
            if creators or title:
                writer = PdfWriter(fileobj=reader, incremental=True)
                fields = {'/Author': '; '.join(creators), '/Title': title}
                writer.add_metadata({key: value for key, value in fields.items() if value})
                with output.open('xb') as stream:
                    writer.write(stream)
        if not output.exists():
            raw_pdf.rename(output)
        checkpoint()
    except (api.ConversionError, InterruptedError):
        raise
    except (OSError, ValueError, StopIteration, PyPdfError) as error:
        raise api.ConversionError('Не удалось сохранить EPUB в PDF. ' + str(error)) from error
