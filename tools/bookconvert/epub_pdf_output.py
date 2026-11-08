"""Render EPUB pages with a private WebView2 Runtime profile."""

from contextlib import contextmanager, closing
import http.server
import io
import json
import mimetypes
import os
from pathlib import Path
import posixpath
import secrets
import shutil
import subprocess
import sys
import tempfile
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
viewer.addListener('done', ({a}) => {
    if (a === 'toc' && window.printOutline === undefined) {
        window.printOutline = viewer.getTOC() ?? [];
        viewer.showTOC(false);
    }
});
viewer.loadPublication(source.href);
"""


@contextmanager
def local_book(archive, viewer, replacements=None):
    prefix = '/' + secrets.token_urlsafe(24) + '/'
    engine = viewer / 'vivliostyle.js'
    if not engine.is_file():
        raise FileNotFoundError('Отсутствуют файлы модуля вёрстки EPUB.')
    assets = {'index.html': HOST, 'host.js': HOST_SCRIPT, 'vivliostyle.js': engine.read_bytes()}
    replacements = replacements or {}

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
            elif folder == 'book' and name in replacements:
                data = replacements[name]
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
    deadline = time.monotonic() + 10
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
    cancel = work / 'cancel-epub-pdf'
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith('WEBVIEW2_')}
    checkpoint()
    # WebView2 creates deeper paths below both directories. Use a short, private
    # location inside the conversion directory so it can also be removed on cancellation.
    profile = Path(tempfile.mkdtemp(prefix='w2-', dir=work.parent))
    try:
        env.update(TEMP=str(profile), TMP=str(profile), WEBVIEW2_USER_DATA_FOLDER=str(profile / 'b'))
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
            if process.poll() is None:
                cancel.touch()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
    finally:
        remove_profile(profile, work.parent)
    if process.returncode == 3:
        raise api.ConversionError('Для сохранения EPUB в PDF нужна среда Microsoft WebView2 Runtime.')
    if process.returncode:
        detail = stderr.decode('utf-8', errors='replace').strip()[:500]
        raise ValueError(detail or 'Модуль вёрстки PDF завершился с ошибкой.')


def epub_outline(items, reader, destinations, checkpoint, depth=0):
    """Resolve the viewer's EPUB TOC against Chromium's actual destinations."""
    if depth >= 64 or not isinstance(items, list):
        return []
    result = []
    for item in items:
        checkpoint()
        if not isinstance(item, dict):
            continue
        children = epub_outline(item.get('children'), reader, destinations, checkpoint, depth + 1)
        key, title = item.get('id'), item.get('title')
        destination = destinations.get('/' + key.lstrip('#/')) if isinstance(key, str) else None
        if destination is not None and reader.get_destination_page_number(destination) < 0:
            destination = None
        if isinstance(title, str) and title.strip() and (destination is not None or children):
            result.append((title, destination, children))
        else:
            result.extend(children)
    return result


def add_outline(writer, reader, outline, checkpoint, parent=None):
    from pypdf.generic import Fit
    for title, destination, children in outline:
        checkpoint()
        if destination is None:
            item = writer.add_outline_item(title, None, parent)
        else:
            args = tuple(float(value) if isinstance(value, (int, float)) else None
                         for value in destination.dest_array[2:])
            item = writer.add_outline_item(title, reader.get_destination_page_number(destination),
                                           parent, fit=Fit(destination.typ, args))
        add_outline(writer, reader, children, checkpoint, item)


def legacy_navigation(api, archive, package_path, package):
    # Vivliostyle reads the manifest's EPUB 3 nav document. Present the EPUB 2
    # NCX as an equivalent, non-spine nav document in the private HTTP session.
    manifest, spine = api.first(package, 'manifest'), api.first(package, 'spine')
    if manifest is None or spine is None:
        return {}
    items = {item.get('id'): item for item in api.children(manifest, 'item')}
    if any('nav' in item.get('properties', '').split() for item in items.values()):
        return {}
    ncx = items.get(spine.get('toc'))
    if ncx is None or ncx.get('media-type') != 'application/x-dtbncx+xml':
        return {}
    try:
        path, _ = archive.resolve(package_path, ncx.get('href', ''))
        if path is None:
            return {}
        source = api.first(api.xml(archive.read(path), 4 * 1024 * 1024), 'navMap')
        if source is None:
            return {}
        name = 'homelibre-print-toc-' + secrets.token_hex(12)
        target = posixpath.join(posixpath.dirname(path), name + '.xhtml')
        html = api.ET.Element('html', {'xmlns': 'http://www.w3.org/1999/xhtml', 'xmlns:epub': api.EP})
        api.ET.SubElement(api.ET.SubElement(html, 'head'), 'title').text = 'Оглавление'
        nav = api.ET.SubElement(api.ET.SubElement(html, 'body'), 'nav', {'epub:type': 'toc'})

        def add_list(node, listing, depth):
            if depth >= 64:
                return
            for point in api.children(node, 'navPoint'):
                label, content = api.plain(api.first(point, 'navLabel')), api.first(point, 'content')
                target_path, fragment = archive.resolve(path, content.get('src', '')) if content is not None else (None, '')
                if not label or target_path not in archive.names:
                    add_list(point, listing, depth + 1)
                    continue
                href = quote(posixpath.relpath(target_path, posixpath.dirname(target) or '.'))
                if fragment:
                    href += '#' + quote(fragment, safe='')
                item = api.ET.SubElement(listing, 'li')
                api.ET.SubElement(item, 'a', {'href': href}).text = label
                nested = api.ET.Element('ol')
                add_list(point, nested, depth + 1)
                if len(nested):
                    item.append(nested)

        listing = api.ET.SubElement(nav, 'ol')
        add_list(source, listing, 0)
        if not len(listing):
            return {}
        ns = manifest.tag.rpartition('}')[0] + '}' if '}' in manifest.tag else ''
        api.ET.SubElement(manifest, ns + 'item', {
            'id': name, 'properties': 'nav', 'media-type': 'application/xhtml+xml',
            'href': quote(posixpath.relpath(target, posixpath.dirname(package_path) or '.')),
        })
        return {package_path: api.ET.tostring(package, encoding='utf-8'),
                target: api.ET.tostring(html, encoding='utf-8')}
    except (api.ConversionError, ValueError):
        return {}


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
            replacements = legacy_navigation(api, archive, rootfile, package)
            with local_book(archive, module_root / 'viewer', replacements) as (origin, prefix):
                url = origin + prefix + 'viewer/index.html#' + urlencode({'source': '../book/' + quote(rootfile)})
                render_pdf(api, renderer, output.parent, url, origin + prefix, checkpoint)
                raw_pdf = output.parent / 'rendered.pdf'

        checkpoint()
        with raw_pdf.open('rb') as rendered:
            reader = PdfReader(rendered)
            if not len(reader.pages):
                raise ValueError('В полученном PDF отсутствуют страницы.')
            toc = output.parent / 'printed-toc.json'
            outline = []
            if toc.is_file():
                items = json.loads(toc.read_text(encoding='utf-8'))
                outline = epub_outline(items, reader, reader.named_destinations, checkpoint)
            if creators or title or outline:
                writer = PdfWriter(fileobj=reader, incremental=True)
                fields = {'/Author': '; '.join(creators), '/Title': title}
                writer.add_metadata({key: value for key, value in fields.items() if value})
                if outline:
                    from pypdf.generic import NameObject
                    writer.root_object.pop(NameObject('/Outlines'), None)
                    add_outline(writer, reader, outline, checkpoint)
                with output.open('xb') as stream:
                    writer.write(stream)
        if not output.exists():
            raw_pdf.rename(output)
        checkpoint()
    except (api.ConversionError, InterruptedError):
        raise
    except (OSError, ValueError, StopIteration, PyPdfError) as error:
        raise api.ConversionError('Не удалось сохранить EPUB в PDF. ' + str(error)) from error
