"""Render EPUB pages in a private, sandboxed browser session."""

import base64
from contextlib import contextmanager, closing
import http.server
import io
import json
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
from urllib.request import build_opener, ProxyHandler


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


def installed_browsers():
    """Use regular, automatically updated browser installations."""
    programs = ('Microsoft/Edge/Application/msedge.exe', 'Google/Chrome/Application/chrome.exe')
    seen = set()
    for program in programs:
        for key in ('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA'):
            if key not in os.environ:
                continue
            path = Path(os.environ[key]) / program
            if path not in seen and path.is_file():
                seen.add(path)
                yield path


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


class DevTools:
    def __init__(self, websocket, port, origin, prefix, checkpoint):
        self.ws = websocket
        self.port = port
        self.resource_url = origin + prefix
        self.blob_url = 'blob:' + origin + '/'
        self.checkpoint = checkpoint
        self.sequence = 0

    def connect(self):
        opener = build_opener(ProxyHandler({}))
        with opener.open(f'http://127.0.0.1:{self.port}/json/list', timeout=2) as response:
            pages = json.load(response)
        page = next(item for item in pages if item['type'] == 'page' and item.get('url') == 'about:blank')
        socket = urlsplit(page['webSocketDebuggerUrl'])
        if (socket.scheme, socket.netloc) != ('ws', f'127.0.0.1:{self.port}') or not socket.path.startswith('/devtools/page/'):
            raise ValueError('Некорректный адрес службы вёрстки PDF.')
        self.socket = self.ws.create_connection(socket.geturl(), timeout=.25, suppress_origin=True,
                                                http_no_proxy=['127.0.0.1'])

    def send(self, method, params=None):
        self.sequence += 1
        self.socket.send(json.dumps({'id': self.sequence, 'method': method, 'params': params or {}}))
        return self.sequence

    def call(self, method, params=None):
        expected = self.send(method, params)
        while True:
            self.checkpoint()
            try:
                message = json.loads(self.socket.recv())
            except self.ws.WebSocketTimeoutException:
                continue
            if message.get('method') == 'Fetch.requestPaused':
                request = message['params']
                url = request['request']['url']
                reply = {'requestId': request['requestId']}
                if request['request']['method'] == 'GET' and url.startswith(
                        (self.resource_url, 'data:', self.blob_url)):
                    self.send('Fetch.continueRequest', reply)
                else:
                    self.send('Fetch.failRequest', dict(reply, errorReason='BlockedByClient'))
            if message.get('id') == expected:
                if 'error' in message:
                    raise ValueError('Браузер не выполнил операцию PDF: ' + method)
                return message['result']

    def evaluate(self, expression):
        result = self.call('Runtime.evaluate', dict(expression=expression, returnByValue=True))
        if 'exceptionDetails' in result:
            raise ValueError('Модуль вёрстки не смог обработать EPUB.')
        return result['result'].get('value')

def debugger_endpoint(port_file):
    try:
        fields = port_file.read_text(encoding='ascii').splitlines()
    except (FileNotFoundError, PermissionError):
        # Chromium briefly opens this file exclusively on Windows.
        return None
    if len(fields) == 2 and fields[0].isdecimal() and 0 < int(fields[0]) <= 65535:
        if fields[1].startswith('/devtools/browser/'):
            return fields
    return None


def stop_browser(websocket, process, port_file):
    # A cancellation can arrive before the page WebSocket is connected.
    # Close the browser through its own endpoint even during this interval.
    deadline = time.monotonic() + 2
    while process.poll() is None and time.monotonic() < deadline:
        endpoint = debugger_endpoint(port_file)
        if endpoint is None:
            time.sleep(.05)
            continue
        port, path = endpoint
        try:
            socket = websocket.create_connection(f'ws://127.0.0.1:{port}{path}', timeout=.25,
                                                 suppress_origin=True, http_no_proxy=['127.0.0.1'])
            try:
                socket.send('{"id":1,"method":"Browser.close"}')
            finally:
                socket.shutdown()
            process.wait(timeout=3)
            return
        except (OSError, websocket.WebSocketException, subprocess.TimeoutExpired):
            break
    if process.poll() is None:
        # Stop only this privately launched process tree if DevTools failed.
        if os.name == 'nt':
            try:
                taskkill = Path(os.environ['SystemRoot']) / 'System32' / 'taskkill.exe'
                subprocess.run([str(taskkill), '/PID', str(process.pid), '/T', '/F'],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               creationflags=subprocess.CREATE_NO_WINDOW, timeout=5, check=False)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            process.kill()
        process.wait()


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


@contextmanager
def browser_session(websocket, browser, work, origin, prefix, checkpoint):
    profile = work / 'browser-profile'
    authority = urlsplit(origin).netloc
    # The local HTTP server rejects proxy requests. An explicit bypass permits
    # direct access only to that server, including when Windows has a proxy.
    flags = ['--headless=new', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
             '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
             '--disable-sync', '--disable-default-apps', '--disable-component-update',
             '--disable-extensions', '--disable-quic', '--disable-domain-reliability',
             f'--proxy-server=http://{authority}', f'--proxy-bypass-list=<-loopback>;{authority}',
             '--user-data-dir=' + str(profile), 'about:blank']
    env = dict(os.environ, TEMP=str(work), TMP=str(work))
    process = subprocess.Popen([str(browser), *flags], cwd=work, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    client = None
    port_file = profile / 'DevToolsActivePort'
    try:
        startup_deadline = time.monotonic() + 15
        while True:
            checkpoint()
            endpoint = debugger_endpoint(port_file)
            if endpoint is not None:
                break
            if process.poll() is not None or time.monotonic() >= startup_deadline:
                raise ValueError('Не удалось запустить браузер для вёрстки PDF.')
            time.sleep(.05)
        checkpoint()
        client = DevTools(websocket, endpoint[0], origin, prefix, checkpoint)
        client.connect()
        yield client
    finally:
        try:
            if client is not None and hasattr(client, 'socket'):
                client.socket.shutdown()
        finally:
            stop_browser(websocket, process, port_file)
            remove_profile(profile, work)


def print_pages(client, url, target, maximum):
    client.call('Page.enable')
    client.call('Fetch.enable', {'patterns': [{'urlPattern': '*', 'requestStage': 'Request'}]})
    if client.call('Page.navigate', {'url': url}).get('errorText'):
        raise ValueError('Не удалось открыть EPUB для вёрстки.')
    while client.evaluate("window.coreViewer?.readyState") != 'complete':
        error = client.evaluate("window.bookLoadFailed")
        if error:
            raise ValueError('Модуль вёрстки не смог открыть содержимое EPUB. ' + error[:250])
        time.sleep(.1)
    if not client.evaluate("document.querySelectorAll('[data-vivliostyle-page-container]').length"):
        raise ValueError('Модуль вёрстки не создал ни одной страницы PDF.')
    printed = client.call('Page.printToPDF', dict(
        printBackground=True, preferCSSPageSize=True, generateTaggedPDF=True, generateDocumentOutline=True,
        marginTop=0, marginBottom=0, marginLeft=0, marginRight=0, transferMode='ReturnAsStream'))
    handle = printed['stream']
    size = 0
    with target.open('xb') as stream:
        while True:
            chunk = client.call('IO.read', {'handle': handle, 'size': 256 * 1024})
            data = (base64.b64decode(chunk['data'], validate=True) if chunk.get('base64Encoded')
                    else chunk['data'].encode('utf-8'))
            size += len(data)
            if size > maximum:
                raise ValueError('Размер PDF превысил предел конвертации.')
            stream.write(data)
            if chunk['eof']:
                break
    client.call('IO.close', {'handle': handle})


def convert(api, prepared, output, module_root, check, browser=None):
    browser = browser or next(installed_browsers(), None)
    if browser is None:
        raise api.ConversionError('Для сохранения EPUB в PDF нужен установленный Microsoft Edge или Google Chrome.')
    deadline = time.monotonic() + 240

    def checkpoint():
        if check is not None:
            check()
        if time.monotonic() >= deadline:
            raise api.ConversionError('Не удалось завершить вёрстку EPUB за четыре минуты.')

    # Isolate optional dependencies from other book-format components.
    sys.path.insert(0, str(module_root / 'runtime'))
    try:
        import websocket
        from pypdf import PdfReader, PdfWriter
        from pypdf.errors import PyPdfError
    except ImportError as error:
        raise api.ComponentRequired('EpubPdfExport', 'Установите модуль вёрстки EPUB в PDF.') from error
    finally:
        sys.path.pop(0)

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
                with browser_session(websocket, browser, output.parent, origin, prefix, checkpoint) as client:
                    raw_pdf = output.parent / 'rendered.pdf'
                    print_pages(client, url, raw_pdf, api.MAX_TOTAL)

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
    except (OSError, ValueError, StopIteration, PyPdfError, websocket.WebSocketException) as error:
        raise api.ConversionError('Не удалось сохранить EPUB в PDF. ' + str(error)) from error
