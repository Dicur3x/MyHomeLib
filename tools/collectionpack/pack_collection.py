"""Incremental, source-preserving collection packing (optional HomeLib module).

The application supplies an immutable SQLite plan, never a live user database.
The default preserves book bytes. Optional illustration profiles use the
HomeLibre export processor before packaging eligible FB2 and EPUB copies.
"""
from __future__ import annotations

import argparse
import base64
import binascii
from collections import Counter
from contextlib import closing, contextmanager
from dataclasses import asdict, dataclass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import uuid
from xml.parsers import expat
import zipfile
import zlib

API_VERSION = 1
MAX_BOOK = 512 * 1024 * 1024
MAX_IMAGE_BOOK = 64 * 1024 * 1024
MAX_SOURCE_BOOKS = 100000
BLOCK = 256 * 1024
ARCHIVE_SUFFIXES = {'.zip', '.7z', '.rar', '.tar', '.gz', '.bz2', '.xz'}
TEXT_SUFFIXES = {'.fb2', '.txt', '.rtf', '.html', '.htm', '.xml', '.md', '.csv'}
IMAGE_SUFFIXES = {'.fb2', '.epub'}
IMAGE_ENGINES = ('illustrations-ppmd', 'illustrations-gray-ppmd')
JPEG_XL_ENGINE = 'jpeg-xl-7z'
FB2_NAMESPACE = 'http://www.gribuser.ru/xml/fictionbook/2.0|'
XLINK_HREF = 'http://www.w3.org/1999/xlink|href'
EPUB_IMAGE_INDEX = 'FLibraryImageIndex.json'
MAX_EPUB_IMAGE_INDEX = 1024 * 1024
SEVENZIP_MAGIC = b"7z\xbc\xaf'\x1c"


class PackingError(ValueError):
    pass


class Canceled(PackingError):
    pass


@dataclass
class Result:
    sources: int = 0
    reused: int = 0
    books: int = 0
    input_bytes: int = 0
    output_bytes: int = 0
    opaque_sources: int = 0
    image_books_optimized: int = 0
    image_books_skipped: int = 0
    generation: str = ''


def canonical(path):
    return os.path.normcase(os.path.realpath(path))


def digest_file(path, check=lambda: None):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(BLOCK):
            check()
            digest.update(chunk)
    return digest.hexdigest()


def book_signature(path, check):
    digest, crc, size = hashlib.sha256(), 0, 0
    with Path(path).open('rb') as stream:
        while chunk := stream.read(BLOCK):
            check(); digest.update(chunk); crc = zlib.crc32(chunk, crc); size += len(chunk)
    return dict(payload_sha256=digest.hexdigest(), payload_crc32=crc, payload_size=size)


def atomic_json(path, value, replace=True):
    path = Path(path)
    partial = path.with_name(path.name + '.' + uuid.uuid4().hex + '.partial')
    try:
        with partial.open('x', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(partial, path)
        elif os.name == 'nt':
            os.rename(partial, path)
        else:
            os.link(partial, path)
    finally:
        partial.unlink(missing_ok=True)


def checked_relative(root, name):
    value = Path(name)
    if value.is_absolute() or value.drive or not name or any(p in ('..', '') for p in value.parts):
        raise PackingError('Недопустимый путь в журнале сжатия.')
    target = Path(root) / value
    if os.path.commonpath([canonical(root), canonical(target)]) != canonical(root):
        raise PackingError('Путь выходит за папку сжатой копии.')
    return target


def book_location(archive, item):
    folder = str(Path(archive).parent) + os.sep if item.get('fbd') else archive
    return folder, item['filename'], item['ext'], item['inside_no']


def copy_exact(source, target, check):
    digest = hashlib.sha256()
    with Path(source).open('rb') as reader, Path(target).open('xb') as writer:
        while chunk := reader.read(BLOCK):
            check()
            digest.update(chunk)
            writer.write(chunk)
        writer.flush()
        os.fsync(writer.fileno())
    return digest.hexdigest()


def reserve_space(directory, bytes_needed):
    if shutil.disk_usage(directory).free < bytes_needed + 16 * 1024 * 1024:
        raise PackingError('Недостаточно свободного места в выбранной папке для текущего архива. Исходники сохранены; готовые архивы доступны для продолжения.')


class SevenZip:
    def __init__(self, executable, check):
        self.executable = Path(executable).absolute()
        if not self.executable.is_file():
            raise PackingError('Для упаковки нужен компонент 7-Zip.')
        self.check = check

    def run(self, arguments, cwd=None, output=None, limit=MAX_BOOK):
        self.check()
        # File-backed output is bounded and avoids pipe deadlock. Temporary
        # data lives on the selected destination drive, never in the C: cache.
        with tempfile.TemporaryFile(dir=cwd) as log:
            process = subprocess.Popen(
                [str(self.executable), *arguments], cwd=cwd,
                stdin=subprocess.DEVNULL, stdout=output if output is not None else log, stderr=log,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            )
            started = time.monotonic()
            try:
                while process.poll() is None:
                    self.check()
                    if time.monotonic() - started > 3600:
                        raise PackingError('Обработка одного архива превысила час.')
                    if os.fstat(log.fileno()).st_size > 4 * 1024 * 1024:
                        raise PackingError('Слишком большой отчёт архиватора.')
                    if output is not None and os.fstat(output.fileno()).st_size > limit:
                        raise PackingError(f'Извлечённые данные превышают допустимый размер {limit // (1024 * 1024)} МБ.')
                    time.sleep(.05)
                if process.returncode:
                    log.seek(0)
                    detail = log.read(3000).decode('utf-8', 'replace')
                    raise PackingError('Архиватор не смог обработать книгу: ' + detail)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
        self.check()

    def extract(self, archive, member, target, work):
        with target.open('xb') as output:
            self.run(['x', '-so', '-spd', '-y', str(archive), member], cwd=work, output=output)
        if target.stat().st_size > MAX_BOOK:
            raise PackingError('Одна книга превышает допустимый размер 512 МБ.')
        if target.stat().st_size == 0:
            raise PackingError('Книга не найдена в архиве или пуста: ' + member)

    def flibrary_image_index(self, archive, stage):
        with tempfile.TemporaryFile(dir=stage) as output:
            self.run(['e', '-so', '-y', str(archive), '-ir!' + EPUB_IMAGE_INDEX],
                     cwd=stage, output=output, limit=MAX_EPUB_IMAGE_INDEX)
            output.seek(0)
            return output.read(MAX_EPUB_IMAGE_INDEX + 1)

    def pack(self, stage, target, text_names, stored_names):
        for names, method in ((text_names, 'PPMd'), (stored_names, 'Copy')):
            if not names:
                continue
            listing = stage.parent / 'entries.txt'
            listing.write_text('\n'.join(names) + '\n', encoding='utf-8')
            # Independent ZIP members preserve random access; no solid blocks.
            # Upstream ZIP PPMd defaults keep the decoder's memory modest.
            options = [] if method == 'PPMd' else ['-mx=0']
            self.run(['a', '-tzip', '-mm=' + method, '-mmt=2', '-scsUTF-8', '-y',
                      *options, str(target), '@' + str(listing)], cwd=stage)

    def pack_separated(self, stage, target, names):
        if names:
            listing = stage.parent / 'entries.txt'
            listing.write_text('\n'.join(names) + '\n', encoding='utf-8')
            self.run(['a', '-t7z', '-m0=LZMA2', '-md=16m', '-ms=off', '-mmt=2',
                      '-scsUTF-8', '-y', str(target), '@' + str(listing)], cwd=stage)


class JpegXL:
    def __init__(self, encoder, decoder, check):
        self.encoder = Path(encoder).absolute() if encoder else None
        self.decoder = Path(decoder).absolute() if decoder else None
        if not all(tool and tool.is_file() for tool in (self.encoder, self.decoder)):
            raise PackingError('Для этого режима нужен JPEG XL с кодировщиком и декодером.')
        self.check = check

    def run(self, executable, arguments, directory, output, limit):
        self.check()
        with subprocess.Popen([str(executable), *arguments], cwd=directory,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)) as process:
            started = time.monotonic()
            try:
                while process.poll() is None:
                    self.check()
                    if (time.monotonic() - started > 60 or
                            (output.exists() and output.stat().st_size > limit)):
                        return False
                    time.sleep(.025)
                self.check()
                return process.returncode == 0 and output.is_file() and output.stat().st_size <= limit
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()

    def encode(self, image, directory):
        if len(image) > 16 * 1024 * 1024 or not image.startswith(b'\xff\xd8\xff'):
            return None
        original, encoded, restored = (directory / name for name in ('input.jpg', 'output.jxl', 'decoded.jpg'))
        try:
            original.write_bytes(image)
            if not self.run(self.encoder, ['input.jpg', 'output.jxl', '-e', '3', '--num_threads=1'],
                            directory, encoded, len(image) - 1):
                return None
            if not self.run(self.decoder, ['output.jxl', 'decoded.jpg', '--reconstruct_jpeg', '--num_threads=1'],
                            directory, restored, len(image)) or restored.read_bytes() != image:
                return None
            return encoded.read_bytes()
        finally:
            for file in (original, encoded, restored):
                file.unlink(missing_ok=True)

    def separate_fb2(self, source, destination, scratch):
        data = source.read_bytes()
        # Use Expat to locate only direct binary children. Copy the untouched
        # XML bytes so the body, namespaces, comments and inline assets survive.
        parser = expat.ParserCreate(namespace_separator='|')
        stack, binaries, covers, used_ids = [], [], set(), Counter()
        root_end = None

        def start(name, attrs):
            self.check()
            if 'id' in attrs:
                used_ids[attrs['id'].casefold()] += 1
            if name == FB2_NAMESPACE + 'image' and FB2_NAMESPACE + 'coverpage' in stack:
                covers.add(attrs.get(XLINK_HREF, '').lstrip('#').casefold())
            if (stack == [FB2_NAMESPACE + 'FictionBook'] and name == FB2_NAMESPACE + 'binary' and
                    set(attrs) == {'id', 'content-type'} and attrs['content-type'].lower() in ('image/jpeg', 'image/jpg') and
                    re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}', attrs['id'])):
                binaries.append([attrs['id'], parser.CurrentByteIndex, None])
            stack.append(name)

        def end(name):
            nonlocal root_end
            if len(stack) == 1:
                root_end = parser.CurrentByteIndex
            if (len(stack) == 2 and name == FB2_NAMESPACE + 'binary' and binaries and binaries[-1][2] is None):
                binaries[-1][2] = parser.CurrentByteIndex
            stack.pop()

        parser.StartElementHandler, parser.EndElementHandler = start, end
        def reject_doctype(*_):
            raise expat.ExpatError('Unsupported FB2 document type')
        parser.StartDoctypeDeclHandler = reject_doctype
        try:
            parser.Parse(data, True)
        except (expat.ExpatError, LookupError):
            return {}
        closing = b'</FictionBook>'
        if root_end is None or data[root_end:root_end + len(closing)] != closing or data[root_end + len(closing):].strip():
            return {}
        images, cursor = {}, 0
        with destination.open('xb') as output:
            for identity, begin, end_at in binaries:
                self.check()
                if (identity.casefold() in covers or identity.casefold() == 'cover' or
                        used_ids[identity.casefold()] != 1 or end_at is None or
                        not data.startswith(b'</binary>', end_at) or not data.startswith(b'<binary', begin)):
                    continue
                body_at = data.find(b'>', begin, end_at)
                if body_at < 0:
                    continue
                content = data[body_at + 1:end_at]
                if not re.fullmatch(rb'[a-zA-Z0-9+/=\r\n\t ]+', content):
                    continue
                try:
                    image = base64.b64decode(b''.join(content.split()), validate=True)
                except binascii.Error:
                    continue
                encoded = self.encode(image, scratch)
                if encoded is not None:
                    images[identity] = encoded
                    output.write(data[cursor:begin])
                    cursor = end_at + len(b'</binary>')
            output.write(data[cursor:])
        if images:
            remaining = destination.read_bytes()
            if any(b'id="' + identity.encode('ascii') + b'"' in remaining for identity in images):
                return {}
        return images

    def separate_epub(self, source, destination, scratch):
        with zipfile.ZipFile(source) as archive:
            entries = archive.infolist()
            names = {entry.filename.casefold() for entry in entries}
            if (len(names) != len(entries) or 'meta-inf/container.xml' not in names or
                    any(name.endswith(EPUB_IMAGE_INDEX.casefold()) for name in names) or
                    names.intersection({'meta-inf/encryption.xml', 'meta-inf/signatures.xml'}) or
                    sum(entry.file_size for entry in entries) > MAX_IMAGE_BOOK or
                    any(entry.flag_bits & 1 or '\\' in entry.filename or ':' in entry.filename or
                        any(part in ('', '.', '..') for part in entry.filename.rstrip('/').split('/'))
                        for entry in entries)):
                return {}
            if archive.read('mimetype') != b'application/epub+zip':
                return {}
            images, index = {}, []
            with zipfile.ZipFile(destination, 'x') as stripped:
                for entry in entries:
                    self.check()
                    data = archive.read(entry)
                    if Path(entry.filename).suffix.lower() in ('.jpeg', '.jpg'):
                        encoded = self.encode(data, scratch)
                        if encoded is not None:
                            # Reserve zero for FLibrary's EPUB cover shortcut.
                            number = len(index) + 1
                            images[str(number)] = encoded
                            index.append(dict(id=entry.filename, num=number))
                            continue
                    stripped.writestr(entry, data)
                if index:
                    stripped.writestr(EPUB_IMAGE_INDEX, json.dumps(index, ensure_ascii=False), zipfile.ZIP_DEFLATED)
            return images

    def separate(self, source, destination, scratch):
        if source.stat().st_size > MAX_IMAGE_BOOK or source.suffix not in IMAGE_SUFFIXES:
            return {}
        try:
            if source.suffix == '.fb2':
                return self.separate_fb2(source, destination, scratch)
            return self.separate_epub(source, destination, scratch)
        except (zipfile.BadZipFile, KeyError, NotImplementedError):
            return {}


class Packer:
    def __init__(self, job, notify=lambda value: None, canceled=lambda: False):
        self.engine = job.get('engine')
        self.images = job.get('images', 'original')
        if job.get('version') != API_VERSION or self.engine not in ('reversible-ppmd', JPEG_XL_ENGINE, *IMAGE_ENGINES):
            raise PackingError('Неизвестная версия или режим сжатия коллекции.')
        if self.engine in ('reversible-ppmd', JPEG_XL_ENGINE) and self.images != 'original':
            raise PackingError('Этот режим сохраняет изображения без изменений. Для изменения качества нужен соответствующий режим сжатия.')
        if self.engine in IMAGE_ENGINES and self.images not in ('balanced', 'economy', 'maximum'):
            raise PackingError('Выберите качество иллюстраций для сжатой копии.')
        self.grayscale = self.engine == 'illustrations-gray-ppmd'
        self.job, self.notify, self.canceled = job, notify, canceled
        self.root = Path(job['output']).absolute()
        self.plan = Path(job['plan']).absolute()
        self.dataset = job['dataset']
        if not isinstance(self.dataset, str) or not self.dataset or len(self.dataset) > 200:
            raise PackingError('Не задана исходная коллекция.')
        self.result = Result(generation=uuid.uuid4().hex)
        self.db = None
        self.started = time.monotonic()
        self.last_sent = 0.0
        self.last_event = None
        self.progress = {}
        self.seven = SevenZip(job['seven_zip'], self.check)
        self.jpeg_xl = JpegXL(job.get('jpeg_xl_encoder'), job.get('jpeg_xl_decoder'), self.check) if self.engine == JPEG_XL_ENGINE else None
        self.converter = None
        self.tools_root = Path(job.get('tools_root') or Path(__file__).resolve().parents[1]).resolve()

    def load_image_processor(self):
        script = self.tools_root / 'bookconvert' / 'convert_book.py'
        if not script.is_file() or not script.with_name('image_quality.py').is_file():
            raise PackingError('Для сжатия иллюстраций нужен модуль подготовки книг HomeLibre BookProcessing.')
        spec = importlib.util.spec_from_file_location('homelibre_pack_book_converter', script)
        converter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(converter)
        tool = converter.image_processor_path(self.tools_root)
        if not tool.is_file():
            raise PackingError('Для сжатия иллюстраций нужен модуль HomeLibre Images.')
        if self.images == 'maximum' or self.grayscale:
            capability = 'чёрно-белого режима' if self.grayscale else 'максимальной экономии'
            if getattr(converter, 'PACKING_IMAGE_API', 0) < (2 if self.grayscale else 1):
                raise PackingError(f'Для {capability} обновите модуль подготовки книг HomeLibre BookProcessing.')
            self.check()
            try:
                profiles = subprocess.run([str(tool), '--packing-image-profiles'],
                    capture_output=True, timeout=5, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            except (OSError, subprocess.TimeoutExpired) as error:
                raise PackingError('Не удалось проверить модуль HomeLibre Images.') from error
            expected = {b'maximum'} if self.images == 'maximum' else set()
            if self.grayscale: expected.add(b'grayscale')
            if profiles.returncode or not expected.issubset(profiles.stdout.split()):
                raise PackingError(f'Для {capability} обновите модуль HomeLibre Images.')
            self.check()
        self.converter = converter

    def optimize_book(self, target, stage):
        if self.converter is None or target.suffix not in IMAGE_SUFFIXES:
            return {}
        size = target.stat().st_size
        if size > MAX_IMAGE_BOOK:
            return dict(image_result='skipped')
        self.check()
        converter = self.converter
        candidate = stage / ('image-candidate' + target.suffix)
        try:
            if converter.detect_input(target) != target.suffix:
                return dict(image_result='skipped')
            reserve_space(stage, 3 * size)
            converter.convert_book(target, candidate, image_quality=self.images,
                                   image_container='fb2-zip' if target.suffix == '.fb2' else None,
                                   tools_root=self.tools_root, cancel_check=self.check,
                                   packing_grayscale=self.grayscale)
            self.check()
            if candidate.stat().st_size >= size:
                return {}
            original_sha256 = digest_file(target, self.check)
            candidate.replace(target)
            return dict(image_result='optimized', original_sha256=original_sha256)
        except converter.ComponentRequired as error:
            raise PackingError(str(error)) from error
        except (converter.ConversionError, binascii.Error, zipfile.BadZipFile) as error:
            return dict(image_result='skipped', image_reason=str(error)[:240])
        finally:
            candidate.unlink(missing_ok=True)

    def count_image_result(self, status):
        if status == 'optimized':
            self.result.image_books_optimized += 1
        elif status == 'skipped':
            self.result.image_books_skipped += 1

    def check(self):
        if self.canceled():
            raise Canceled('Сжатие отменено. Готовые архивы можно использовать при продолжении.')
        # Long archive operations and streaming copies still report activity.
        # The UI must not guess a percentage while 7-Zip is compressing.
        now = time.monotonic()
        if self.last_event is not None and now - self.last_sent >= 1.0:
            self.last_sent = now
            self.notify(dict(self.last_event, elapsed_seconds=now - self.started))

    def event(self, stage, **values):
        now = time.monotonic()
        previous = self.last_event
        self.last_event = dict(self.progress, stage=stage, **values,
                               elapsed_seconds=now - self.started)
        # Fast extraction can produce thousands of members per second. Keep
        # first/final updates and stage changes; do not flood the native pipe.
        if (stage == 'books' and previous is not None and previous['stage'] == stage
                and values.get('current', 0) < values.get('total', 0)
                and now - self.last_sent < .15):
            return
        self.last_sent = now
        self.notify(self.last_event.copy())

    def open(self):
        self.check()
        if self.root.exists() and not self.root.is_dir():
            raise PackingError('Путь сжатой копии не является папкой.')
        self.root.mkdir(parents=True, exist_ok=True)
        marker = self.root / 'HomeLibRu-compressed.json'
        if marker.exists():
            previous = json.loads(marker.read_text(encoding='utf-8-sig'))
            if (previous.get('dataset'), previous.get('engine'), previous.get('version'),
                    previous.get('images', 'original')) != (self.dataset, self.engine, API_VERSION, self.images):
                raise PackingError('В этой папке другая коллекция или другие настройки сжатия. Выберите новую папку.')
        else:
            if any(self.root.iterdir()):
                raise PackingError('Для новой сжатой копии нужна пустая папка.')
            try:
                atomic_json(marker, dict(version=API_VERSION, dataset=self.dataset, engine=self.engine,
                                        images=self.images), replace=False)
            except FileExistsError as error:
                raise PackingError('Другая операция уже задала настройки для этой папки сжатой копии.') from error
    def open_journal(self):
        self.db = sqlite3.connect(self.root / 'packing.sqlite')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS sources(
                id TEXT PRIMARY KEY, stamp TEXT NOT NULL, folder TEXT NOT NULL,
                members TEXT NOT NULL, artifacts TEXT NOT NULL, input_bytes INTEGER NOT NULL,
                opaque INTEGER NOT NULL,source_hashes TEXT NOT NULL DEFAULT '[]');
            CREATE TABLE IF NOT EXISTS runs(
                id TEXT PRIMARY KEY, started TEXT NOT NULL, finished INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS stages(path TEXT PRIMARY KEY,dataset TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS payloads(
                package TEXT PRIMARY KEY,folder TEXT NOT NULL UNIQUE,source_id TEXT NOT NULL,stamp TEXT NOT NULL,
                members TEXT NOT NULL,artifacts TEXT NOT NULL,input_bytes INTEGER NOT NULL,
                opaque INTEGER NOT NULL,source_hashes TEXT NOT NULL);
        ''')
        if 'source_hashes' not in {row[1] for row in self.db.execute('PRAGMA table_info(sources)')}:
            self.db.execute("ALTER TABLE sources ADD COLUMN source_hashes TEXT NOT NULL DEFAULT '[]'")
        # The latest source cache is replaceable; the immutable payload ledger
        # is not. An old registered catalogue may still reference an earlier
        # payload after a newer run was prepared but never applied.
        for row in self.db.execute('SELECT id,stamp,folder,members,artifacts,input_bytes,opaque,source_hashes FROM sources'):
            self.remember_payload(*row)
        self.db.execute('INSERT INTO runs(id,started) VALUES(?,datetime(\'now\'))', (self.result.generation,))
        self.db.commit()

    def remember_payload(self, identity, stamp, folder, members, artifacts, input_bytes, opaque, source_hashes):
        file = checked_relative(self.root, folder)
        package = str(file.parent.relative_to(self.root))
        if Path(package).parts[:1] != ('archives',) or len(Path(package).parts) != 3:
            raise PackingError('Некорректный пакет в журнале сжатия.')
        values = (folder, identity, stamp, members, artifacts, input_bytes, opaque, source_hashes)
        old = self.db.execute('SELECT folder,source_id,stamp,members,artifacts,input_bytes,opaque,source_hashes FROM payloads WHERE package=?', (package,)).fetchone()
        if old is not None and old != values:
            raise PackingError('Неизменяемый пакет в журнале сжатия был заменён.')
        self.db.execute('INSERT OR IGNORE INTO payloads VALUES(?,?,?,?,?,?,?,?,?)', (package, *values))

    def invalid_artifact(self, artifacts):
        if not artifacts:
            return ''
        for item in artifacts:
            self.check()
            file = checked_relative(self.root, item['path'])
            if not file.is_file():
                return item['path']
            stat = file.stat()
            if stat.st_size != item['size']:
                return item['path']
            if self.job.get('verify_outputs', False) or stat.st_mtime_ns != item.get('mtime_ns'):
                if digest_file(file, self.check) != item['sha256']:
                    return item['path']
        return None

    def retain_payloads(self, plan, mapping, payload_column):
        for (folder,) in plan.execute(f'SELECT DISTINCT {payload_column} FROM retained ORDER BY {payload_column}'):
            self.check()
            checked_relative(self.root, folder)
            row = self.db.execute('SELECT members,artifacts,input_bytes,opaque FROM payloads WHERE folder=?', (folder,)).fetchone()
            if row is None:
                raise PackingError('Готовый архив не найден в журнале сжатия: ' + folder)
            artifacts = json.loads(row[1])
            invalid = self.invalid_artifact(artifacts)
            if invalid is not None:
                raise PackingError('Ранее созданный архив или его иллюстрации не прошли проверку: ' +
                                   str(self.root / (invalid or folder)))
            members = {book_location(folder, item): item.get('image_result') for item in json.loads(row[0]).values()}
            count = 0
            with mapping:
                for book in plan.execute(f'SELECT book_id,folder,filename,ext,inside_no FROM retained WHERE {payload_column}=? ORDER BY book_id', (folder,)):
                    self.check()
                    if tuple(book)[1:] not in members:
                        raise PackingError('Расположение книги не совпадает с готовым архивом: ' + folder)
                    mapping.execute('INSERT INTO locations VALUES(?,?,?,?,?)', tuple(book))
                    self.count_image_result(members[tuple(book)[1:]])
                    count += 1
            self.result.sources += 1; self.result.reused += 1; self.result.books += count
            self.result.input_bytes += row[2]
            self.result.output_bytes += sum(item['size'] for item in artifacts)
            self.result.opaque_sources += int(row[3])
            self.update_progress()
            self.event('retained', current=self.result.sources, total=self.progress['sources_total'], source=Path(folder).name)

    def update_progress(self):
        self.progress.update(sources_done=self.result.sources, books_done=self.result.books,
                             input_bytes=self.result.input_bytes, output_bytes=self.result.output_bytes,
                             reused=self.result.reused)

    def clear_interrupted_stages(self):
        for name, dataset in self.db.execute('SELECT path,dataset FROM stages').fetchall():
            self.check()
            stage = checked_relative(self.root, name)
            if stage.parent != self.root or not stage.name.startswith('.packing-') or dataset != self.dataset:
                raise PackingError('Некорректная запись временной папки в журнале.')
            if stage.exists():
                if stage.is_symlink() or canonical(stage.parent) != canonical(self.root):
                    raise PackingError('Временная папка заменена ссылкой.')
                marker = stage / 'HomeLibRu-stage.json'
                if not marker.is_file() or json.loads(marker.read_text(encoding='utf-8')).get('dataset') != self.dataset:
                    raise PackingError('Нельзя подтвердить принадлежность временной папки.')
                shutil.rmtree(stage)
            with self.db:
                self.db.execute('DELETE FROM stages WHERE path=?', (name,))
        for (identity,) in self.db.execute('SELECT id FROM runs WHERE finished=0 AND id<>?', (self.result.generation,)).fetchall():
            if len(identity) != 32 or any(c not in '0123456789abcdef' for c in identity):
                raise PackingError('Некорректная запись незавершённой операции.')
            generation = checked_relative(self.root, str(Path('generations') / identity))
            if generation.exists() and not (generation / 'prepared.json').is_file():
                if generation.is_symlink():
                    raise PackingError('Незавершённая операция заменена ссылкой.')
                entries = list(generation.iterdir())
                if any(entry.name not in ('locations.sqlite', 'locations.sqlite-journal') or
                       not entry.is_file() or entry.is_symlink() for entry in entries):
                    raise PackingError('В незавершённой операции появились посторонние файлы.')
                for entry in entries: entry.unlink()
                generation.rmdir()
            with self.db:
                self.db.execute('UPDATE runs SET finished=-1 WHERE id=?', (identity,))

    @contextmanager
    def working_stage(self):
        with tempfile.TemporaryDirectory(prefix='.packing-', dir=self.root) as directory:
            stage = Path(directory)
            atomic_json(stage / 'HomeLibRu-stage.json', dict(dataset=self.dataset))
            with self.db:
                self.db.execute('INSERT INTO stages VALUES(?,?)', (stage.name, self.dataset))
            # The TemporaryDirectory context closes before we remove its
            # registry row, so hard process termination remains recoverable.
            yield stage
        with self.db:
            self.db.execute('DELETE FROM stages WHERE path=?', (stage.name,))

    @contextmanager
    def lock(self):
        # The operating-system lock is released on a crash; a marker alone is
        # not sufficient because an interrupted process must be resumable.
        stream = (self.root / 'packing.lock').open('a+b')
        try:
            stream.seek(0)
            if os.fstat(stream.fileno()).st_size == 0:
                stream.write(b'1'); stream.flush()
            stream.seek(0)
            try:
                if os.name == 'nt':
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise PackingError('Эта сжатая копия уже обрабатывается другим процессом.') from error
            yield
        finally:
            stream.close()

    def source_artifacts(self, source):
        # Existing FLibrary books may depend on sibling covers/images. They
        # remain an opaque, byte-exact unit, including their original names.
        companions = []
        if source.suffix.lower() in ('.zip', '.7z'):
            for kind in ('covers', 'images'):
                for suffix in ('.zip', '.7z'):
                    candidate = source.parent / kind / (source.stem + suffix)
                    if candidate.is_file():
                        companions.append((kind + '/' + source.stem + suffix, candidate))
        return companions

    def stamp(self, source, companions):
        values = []
        root = Path(canonical(self.root))
        for file in (source, *(file for _, file in companions)):
            self.check()
            resolved = Path(canonical(file))
            for location, base in ((file, self.root), (resolved, root)):
                if not location.is_relative_to(base):
                    continue
                relative = location.relative_to(base)
                name = relative.parts[0].lower() if relative.parts else ''
                # New downloads can live beside existing generations when
                # repacking this catalogue. Managed files must go via retention.
                if (self.job.get('allow_copy_inputs') is not True or not name or
                        name in ('archives', 'generations', 'homelibru-compressed.json',
                                 'homelibru-native-packing.lock', 'packing.lock') or
                        name.startswith(('.packing-', '.job-', 'packing.sqlite')) or
                        (name.startswith('collection') and '.hlc2' in name)):
                    raise PackingError('Исходный файл находится в служебной части сжатой копии: ' + str(file))
            if not file.is_file():
                raise PackingError('Исходный файл не найден: ' + str(file))
            stat = file.stat()
            values.append([str(resolved), stat.st_size, stat.st_mtime_ns])
        return hashlib.sha256(json.dumps(values).encode()).hexdigest()

    def cached(self, identity, stamp, source, companions):
        row = self.db.execute('SELECT folder,members,artifacts,input_bytes,opaque,source_hashes FROM sources WHERE id=? AND stamp=?',
                              (identity, stamp)).fetchone()
        if row is None:
            return None
        if self.job.get('verify_sources', False):
            expected = json.loads(row[5])
            actual = [digest_file(file, self.check) for file in (source, *(p for _, p in companions))]
            if expected != actual:
                return None
        artifacts = json.loads(row[2])
        if self.invalid_artifact(artifacts) is not None:
            return None
        return row[0], json.loads(row[1]), artifacts, row[3], row[4]

    def pack_with_jpeg_xl(self, files, stage, package, mappings, maximum_size):
        transformed = stage / 'separated'; transformed.mkdir()
        scratch = stage / 'codec'; scratch.mkdir()
        sidecar = stage / 'pictures.zip'
        expected_images, replacements, untouched = {}, {}, []
        with zipfile.ZipFile(sidecar, 'x', zipfile.ZIP_STORED) as pictures:
            for locator, item in mappings.items():
                self.check()
                name = item['filename'] + item['ext']
                original, candidate = files / name, transformed / name
                if item['ext'] in IMAGE_SUFFIXES and original.stat().st_size <= MAX_IMAGE_BOOK:
                    reserve_space(stage, 3 * original.stat().st_size)
                images = self.jpeg_xl.separate(original, candidate, scratch)
                if not images:
                    candidate.unlink(missing_ok=True)
                    untouched.append(name)
                    continue
                replacements[locator] = dict(item, **book_signature(candidate, self.check),
                    image_result='optimized', original_sha256=item['payload_sha256'])
                for identity, encoded in images.items():
                    self.check()
                    entry = item['filename'] + '/' + identity
                    pictures.writestr(entry, encoded)
                    expected_images[entry] = hashlib.sha256(encoded).hexdigest()
        if not replacements or sidecar.stat().st_size >= maximum_size:
            return None

        # Both candidate archives stay private until they jointly beat the
        # ordinary copy and pass extraction and payload verification.
        archive = stage / 'books.7z'
        reserve_space(stage, sum(item['payload_size'] for item in mappings.values()))
        self.seven.pack_separated(files, archive, untouched)
        self.seven.pack_separated(transformed, archive,
            [item['filename'] + item['ext'] for item in replacements.values()])
        if archive.stat().st_size + sidecar.stat().st_size >= maximum_size:
            return None
        with zipfile.ZipFile(sidecar) as pictures:
            if set(pictures.namelist()) != set(expected_images):
                raise PackingError('Не совпадает список вынесенных иллюстраций.')
            for entry, expected in expected_images.items():
                self.check()
                if hashlib.sha256(pictures.read(entry)).hexdigest() != expected:
                    raise PackingError('Архив иллюстраций не прошёл проверку.')
        destination = package / archive.name
        archive.rename(destination)
        (package / 'images').mkdir()
        sidecar.rename(package / 'images' / 'books.zip')
        mappings.update(replacements)
        return destination

    def check_flibrary_epub(self, book, member, source, stage, companion_kinds):
        # FLibrary's EPUB index records which archive supplies each image.
        # A nested 7z EPUB needs its original outer 7z even without images,
        # because that is what activates reconstruction in the catalogue.
        with book.open('rb') as stream:
            nested = stream.read(len(SEVENZIP_MAGIC)) == SEVENZIP_MAGIC
        index = b''
        if nested:
            index = self.seven.flibrary_image_index(book, stage)
        elif zipfile.is_zipfile(book):
            with zipfile.ZipFile(book) as epub:
                entry = next((entry for entry in epub.infolist()
                              if Path(entry.filename).name.lower() == EPUB_IMAGE_INDEX.lower()), None)
                if entry is not None:
                    if entry.file_size > MAX_EPUB_IMAGE_INDEX:
                        raise PackingError('Слишком большой список иллюстраций EPUB: ' + member)
                    index = epub.read(entry)
        if not index:
            return nested
        try:
            if len(index) > MAX_EPUB_IMAGE_INDEX:
                raise ValueError('oversized image index')
            images = json.loads(index)
            if not isinstance(images, list):
                raise ValueError('not an image list')
            required = {'covers' if image['num'] == -1 else 'images' for image in images}
        except (ValueError, KeyError, TypeError) as error:
            raise PackingError('Не удалось прочитать список вынесенных иллюстраций EPUB: ' + member) from error
        missing = sorted(required - companion_kinds)
        if missing:
            names = ', '.join(f'{kind}/{source.stem}.zip' for kind in missing)
            raise PackingError(f'Для книги {member} отсутствует архив иллюстраций рядом с {source.name}: {names}.')
        return nested

    def process(self, source, rows, stage, identity, stamp, companions):
        artifacts, mappings, copied_hashes = [], {}, {}
        # Generation files are immutable. A changed source cannot replace an
        # archive referenced by the previously published catalogue.
        relative = Path('archives') / identity[:20] / stamp[:20]
        publish = checked_relative(self.root, str(relative))
        if publish.exists() or self.db.execute('SELECT 1 FROM payloads WHERE package=?', (str(relative),)).fetchone():
            # A crash after publishing files but before committing the journal
            # leaves an unreferenced immutable generation. Do not overwrite it.
            relative = relative.with_name(relative.name + '-' + uuid.uuid4().hex[:8])
            publish = checked_relative(self.root, str(relative))
        package = stage / 'package'; package.mkdir()
        input_bytes = source.stat().st_size + sum(p.stat().st_size for _, p in companions)
        fbd_rows = [row for row in rows if row['fbd']]
        if fbd_rows:
            if source.suffix.lower() != '.zip' or not zipfile.is_zipfile(source):
                raise PackingError('В плане сжатия неверно указан архив книги с описанием FBD.')
            with zipfile.ZipFile(source) as directory:
                entries = set(directory.namelist())
                for row in fbd_rows:
                    if not row['member'] or row['member'] not in entries:
                        raise PackingError('Книга с описанием FBD отсутствует в архиве: ' + row['member'])
        companion_kinds = {name.split('/', 1)[0] for name, _ in companions}
        check_flibrary = source.suffix.lower() == '.7z' and companion_kinds != {'covers', 'images'}
        preserve_container = bool(companions) or bool(fbd_rows)
        if not preserve_container and any(row['member'] for row in rows) and zipfile.is_zipfile(source):
            with zipfile.ZipFile(source) as directory:
                preserve_container = any(entry.file_size > MAX_BOOK for entry in directory.infolist() if not entry.is_dir())
        if preserve_container:
            if check_flibrary:
                # Only potentially incomplete sets need per-book inspection.
                for member in {row['member'] for row in rows if row['ext'].lower() == '.epub'}:
                    self.check()
                    book = stage / 'check.epub'
                    self.seven.extract(source, member, book, stage)
                    self.check_flibrary_epub(book, member, source, stage, companion_kinds)
                    book.unlink()
            reserve_space(stage, input_bytes)
            destination = package / source.name
            copied_hashes[destination] = copy_exact(source, destination, self.check)
            folder = str(relative / source.name)
            for name, file in companions:
                destination = package / name; destination.parent.mkdir(exist_ok=True)
                copied_hashes[destination] = copy_exact(file, destination, self.check)
            for row in rows:
                item = dict(filename=row['filename'], ext=row['ext'], inside_no=row['inside_no'])
                if row['fbd']:
                    item.update(filename=source.name, fbd=True)
                mappings[row['locator']] = item
        else:
            files = stage / 'books'; files.mkdir()
            text_names, stored_names = [], []
            original = None
            keep_source = False
            try:
                if zipfile.is_zipfile(source):
                    original = zipfile.ZipFile(source)
                entries, folded = {}, {}
                if original:
                    for entry in original.infolist():
                        if entry.is_dir():
                            continue
                        if entry.filename in entries:
                            raise PackingError('Повторяется точное имя файла внутри архива: ' + entry.filename)
                        entries[entry.filename] = entry
                        folded.setdefault(entry.filename.casefold(), []).append(entry)
                for index, row in enumerate(rows):
                    self.check()
                    locator, member = row['locator'], row['member']
                    if locator in mappings:
                        continue
                    extension = row['ext'].lower()
                    if not extension.startswith('.') or len(extension) > 16 or not extension[1:].isalnum():
                        raise PackingError('Неизвестное расширение файла: ' + extension)
                    name = hashlib.sha256(locator.encode('utf-8')).hexdigest()[:32] + extension
                    target = files / name
                    if not member:
                        # A loose original is copied in bounded chunks; its
                        # size is not a decoder/memory limit.
                        reserve_space(stage, source.stat().st_size)
                        copy_exact(source, target, self.check)
                    elif original is not None:
                        entry = entries.get(member)
                        if entry is None:
                            candidates = folded.get(member.casefold(), [])
                            if len(candidates) > 1:
                                raise PackingError('Неоднозначное имя книги в архиве: ' + member)
                            entry = candidates[0] if candidates else None
                        if entry is None:
                            raise PackingError('Книга отсутствует в архиве: ' + member)
                        if entry.file_size > MAX_BOOK:
                            raise PackingError('Одна книга превышает допустимый размер 512 МБ.')
                        reserve_space(stage, entry.file_size)
                        try:
                            with original.open(entry) as reader, target.open('xb') as writer:
                                while chunk := reader.read(BLOCK):
                                    self.check(); writer.write(chunk)
                        except NotImplementedError:
                            target.unlink(missing_ok=True)
                            self.seven.extract(source, entry.filename, target, stage)
                    else:
                        self.seven.extract(source, member, target, stage)
                    if check_flibrary and extension == '.epub' and member:
                        if self.check_flibrary_epub(target, member, source, stage, companion_kinds):
                            keep_source = True
                    image_result = {} if keep_source else self.optimize_book(target, stage)
                    mappings[locator] = dict(filename=Path(name).stem, ext=extension, inside_no=-1, **image_result,
                                             **book_signature(target, self.check))
                    (text_names if extension in TEXT_SUFFIXES else stored_names).append(name)
                    self.event('books', source=source.name, current=index + 1, total=len(rows))
                if not mappings:
                    raise PackingError('В исходном архиве нет выбранных книг.')
                archive = package / 'books.zip'
                separated = None
                if not keep_source:
                    self.event('compressing', source=source.name, books=len(mappings))
                    reserve_space(stage, sum(p.stat().st_size for p in files.iterdir()))
                    self.seven.pack(files, archive, text_names, stored_names)
                    if self.jpeg_xl:
                        maximum_size = archive.stat().st_size
                        if source.suffix.lower() in ARCHIVE_SUFFIXES:
                            maximum_size = min(maximum_size, source.stat().st_size)
                        separated = self.pack_with_jpeg_xl(files, stage, package, mappings, maximum_size)
                    if separated is None:
                        with zipfile.ZipFile(archive) as verification:
                            if set(verification.namelist()) != set(text_names + stored_names):
                                raise PackingError('Не совпадает список книг в созданном архиве.')
                            for item in mappings.values():
                                info = verification.getinfo(item['filename'] + item['ext'])
                                if (info.CRC, info.file_size) != (item['payload_crc32'], item['payload_size']):
                                    raise PackingError('Содержимое книги в созданном архиве отличается от подготовленной копии.')
                    else:
                        archive.unlink()
                        archive = separated
                folder = str(relative / archive.name)
                # Already compressed sources must not grow merely because
                # the new member names or ZIP headers have different lengths.
                if keep_source or (separated is None and source.suffix.lower() in ARCHIVE_SUFFIXES and
                                   archive.stat().st_size >= source.stat().st_size):
                    archive.unlink(missing_ok=True)
                    destination = package / source.name
                    copied_hashes[destination] = copy_exact(source, destination, self.check)
                    folder = str(relative / source.name)
                    preserve_container = True
                    mappings = {row['locator']: dict(filename=row['filename'], ext=row['ext'], inside_no=row['inside_no']) for row in rows}
                else:
                    self.event('verifying', source=source.name)
                    # Reclaim the original extraction space before decoding the
                    # result. Only these generated names were given to 7-Zip.
                    for name in text_names + stored_names:
                        self.check()
                        (files / name).unlink()
                    reserve_space(stage, sum(item['payload_size'] for item in mappings.values()))
                    self.seven.run(['x', '-y', '-bb0', '-o' + str(files), '--', str(archive)], cwd=stage)
                    if {file.name for file in files.iterdir()} != set(text_names + stored_names):
                        raise PackingError('Не совпадает список книг в созданном архиве.')
                    for item in mappings.values():
                        decoded = files / (item['filename'] + item['ext'])
                        if not decoded.is_file() or digest_file(decoded, self.check) != item['payload_sha256']:
                            raise PackingError('Содержимое книги в созданном архиве отличается от подготовленной копии.')
            finally:
                if original is not None:
                    original.close()
        self.check()
        self.event('verifying', source=source.name)
        for file in package.rglob('*'):
            if file.is_file():
                sha256 = digest_file(file, self.check)
                if copied_hashes and copied_hashes.get(file) != sha256:
                    raise PackingError('Побайтовая копия архива или иллюстраций не совпала с исходником: ' + file.name)
                artifacts.append(dict(path=str(relative / file.relative_to(package)), size=file.stat().st_size,
                                      mtime_ns=file.stat().st_mtime_ns, sha256=sha256))
        source_hashes = [digest_file(file, self.check) for file in (source, *(p for _, p in companions))]
        if copied_hashes and (list(copied_hashes.values()) != source_hashes or len(copied_hashes) != len(artifacts)):
            raise PackingError('Побайтовая копия архива или иллюстраций не совпала с исходником: ' + str(source))
        # Byte equality cannot tell whether the original side archive was
        # already damaged. Test its contents once before recording the copy.
        for name, original in companions:
            try:
                self.seven.run(['t', '-bb0', '-bso0', '-bsp0', '-mmt=2', '--',
                                str(package / name)], cwd=stage)
            except Canceled:
                raise
            except PackingError as error:
                raise PackingError('Не удалось проверить исходный архив иллюстраций: ' + str(original)) from error
        if self.stamp(source, self.source_artifacts(source)) != stamp:
            raise PackingError('Во время сжатия изменился исходный архив или архив иллюстраций: ' + str(source))
        packed = folder, mappings, artifacts, input_bytes, preserve_container
        # Write-ahead recovery: a crash before the rename leaves an invalid
        # cache row (repack); a crash after it leaves a fully reusable row.
        # No published archive can become an untracked orphan in between.
        with self.db:
            self.remember_payload(identity, stamp, folder, json.dumps(mappings), json.dumps(artifacts),
                                  input_bytes, int(preserve_container), json.dumps(source_hashes))
            self.db.execute('INSERT OR REPLACE INTO sources VALUES(?,?,?,?,?,?,?,?)',
                            (identity, stamp, folder, json.dumps(mappings), json.dumps(artifacts),
                             input_bytes, int(preserve_container), json.dumps(source_hashes)))
        publish.parent.mkdir(parents=True, exist_ok=True)
        os.rename(package, publish)
        return packed

    def execute(self):
        generation, prepared = None, False
        try:
            if self.engine in IMAGE_ENGINES:
                self.load_image_processor()
            self.open()
            with self.lock(), closing(sqlite3.connect(self.plan.as_uri() + '?mode=ro', uri=True)) as plan:
                self.open_journal()
                self.clear_interrupted_stages()
                plan.row_factory = sqlite3.Row
                if plan.execute('SELECT value FROM metadata WHERE key=\'api\'').fetchone()[0] != str(API_VERSION):
                    raise PackingError('Неизвестный план сжатия.')
                dataset = plan.execute('SELECT value FROM metadata WHERE key=\'dataset\'').fetchone()
                if dataset is None or dataset[0] != self.dataset:
                    raise PackingError('План относится к другой исходной коллекции.')
                fbd_column = '' if any(row[1] == 'fbd' for row in plan.execute('PRAGMA table_info(books)')) else ',0 AS fbd'
                retained_columns = {row[1] for row in plan.execute('PRAGMA table_info(retained)')}
                retained = bool(retained_columns)
                payload_column = 'payload' if 'payload' in retained_columns else 'folder'
                generation = self.root / 'generations' / self.result.generation
                generation.mkdir(parents=True)
                mapping = sqlite3.connect(generation / 'locations.sqlite')
                try:
                    mapping.execute('CREATE TABLE locations(book_id INTEGER PRIMARY KEY,folder TEXT NOT NULL,filename TEXT NOT NULL,ext TEXT NOT NULL,inside_no INTEGER NOT NULL)')
                    retained_sources = plan.execute(f'SELECT count(DISTINCT {payload_column}) FROM retained').fetchone()[0] if retained else 0
                    retained_books = plan.execute('SELECT count(*) FROM retained').fetchone()[0] if retained else 0
                    if retained and plan.execute('SELECT 1 FROM books JOIN retained USING(book_id) LIMIT 1').fetchone():
                        raise PackingError('Одна запись книги одновременно включена в новую и готовую часть.')
                    total = plan.execute('SELECT count(DISTINCT source) FROM books').fetchone()[0] + retained_sources
                    if total == 0:
                        raise PackingError('В плане сжатия нет книг.')
                    self.progress = dict(sources_done=0, sources_total=total, books_done=0,
                                         books_total=plan.execute('SELECT count(*) FROM books').fetchone()[0]+retained_books,
                                         input_bytes=0, output_bytes=0, reused=0)
                    if retained:
                        self.retain_payloads(plan, mapping, payload_column)
                    source_rows = plan.execute('SELECT DISTINCT source FROM books ORDER BY source')
                    for number, (name,) in enumerate(source_rows):
                        self.check()
                        source = Path(name).absolute()
                        rows = plan.execute(f'SELECT *{fbd_column} FROM books WHERE source=? ORDER BY book_id',
                                            (name,)).fetchmany(MAX_SOURCE_BOOKS + 1)
                        if len(rows) > MAX_SOURCE_BOOKS:
                            raise PackingError('В одном исходном архиве больше 100 000 записей. Эта операция не была опубликована; исходные файлы сохранены.')
                        if not rows:
                            continue
                        companions = self.source_artifacts(source)
                        identity = hashlib.sha256(canonical(source).encode('utf-8')).hexdigest()
                        stamp = self.stamp(source, companions)
                        self.event('source', current=number+retained_sources, total=total, source=source.name)
                        packed = self.cached(identity, stamp, source, companions)
                        # New catalogue rows may reference more members from an
                        # otherwise unchanged source. Reuse requires all locators.
                        if packed is not None and all(row['locator'] in packed[1] and
                                bool(packed[1][row['locator']].get('fbd')) == bool(row['fbd']) for row in rows):
                            self.result.reused += 1
                        else:
                            with self.working_stage() as stage:
                                packed = self.process(source, rows, stage, identity, stamp, companions)
                        folder, members, artifacts, input_bytes, opaque = packed
                        with mapping:
                            for row in rows:
                                item = members[row['locator']]
                                mapping.execute('INSERT INTO locations VALUES(?,?,?,?,?)',
                                                (row['book_id'], *book_location(folder, item)))
                                self.count_image_result(item.get('image_result'))
                        self.result.sources += 1; self.result.books += len(rows)
                        self.result.input_bytes += input_bytes
                        self.result.output_bytes += sum(a['size'] for a in artifacts)
                        self.result.opaque_sources += int(opaque)
                        self.update_progress()
                        self.event('source', current=number+retained_sources+1, total=total, source=source.name, **asdict(self.result))
                    self.check()
                    count = mapping.execute('SELECT count(*) FROM locations').fetchone()[0]
                    if count != self.progress['books_total']:
                        raise PackingError('Не все книги получили новое расположение. Сжатая копия не опубликована.')
                finally:
                    mapping.close()
                # The app still has to remap and validate a cloned catalogue.
                # This prepared pointer must never be interpreted as a usable
                # registered collection until that final native step succeeds.
                atomic_json(generation / 'prepared.json', dict(version=API_VERSION, dataset=self.dataset,
                            locations='locations.sqlite', **asdict(self.result)))
                prepared = True
                with self.db:
                    self.db.execute('UPDATE runs SET finished=1 WHERE id=?', (self.result.generation,))
                self.event('prepared', **asdict(self.result))
                return self.result
        finally:
            if self.db is not None:
                self.db.close()
            if generation is not None and not prepared:
                # Only this run's private, unregistered locator database.
                # A previous usable generation is never changed or deleted.
                if generation.parent == self.root / 'generations' and generation.name == self.result.generation:
                    for name in ('locations.sqlite', 'locations.sqlite-journal'):
                        (generation / name).unlink(missing_ok=True)
                    if not any(generation.iterdir()):
                        generation.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', type=Path, required=True)
    parser.add_argument('--cancel', type=Path)
    options = parser.parse_args()
    try:
        job = json.loads(options.job.read_text(encoding='utf-8-sig'))
        result = Packer(job, lambda event: print(json.dumps(event, ensure_ascii=False), flush=True),
                        lambda: bool(options.cancel and options.cancel.exists())).execute()
        return 0 if result.sources else 2
    except Canceled as error:
        print(json.dumps(dict(stage='canceled', error=str(error)), ensure_ascii=False), flush=True)
        return 3
    except (PackingError, OSError, sqlite3.Error, zipfile.BadZipFile, KeyError, TypeError, json.JSONDecodeError) as error:
        print(json.dumps(dict(stage='error', error=str(error)), ensure_ascii=False), flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
