"""Read-only preparation of selected physical books for the native commit job.

The native selection adapter supplies exact member names and an immutable
catalogue receipt template. This module never changes a source or a database.
The returned candidate is applied only by TBookCompressionJob.
"""
from dataclasses import asdict, dataclass
from contextlib import contextmanager, nullcontext
import argparse
import copy
import hashlib
import json
from pathlib import Path
import posixpath
import stat
import sys
import time
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree
import zipfile
import zlib

# The shipped embedded Python uses -I and an isolated ._pth file. Import
# only this verified component's sibling modules, never the process cwd.
if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from archive_replacement import archive_inventory, member_path, prepare_archive_replacement
from compression_preview import ComparisonPreview, MAX_BYTES as MAX_COMPARISON_BYTES
from pack_collection import (Canceled, IMAGE_SUFFIXES, MAX_BOOK, MAX_IMAGE_BOOK,
                             Packer, PackingError, SevenZip, atomic_json,
                             book_signature, canonical, copy_exact, digest_file,
                             reserve_space, temporary_work_directory)
from compression_image_history import CompressedImageHistory


PREPARATION_API = 1
PROFILES = {'original', 'balanced', 'economy', 'maximum'}
MAX_MEMBERS = 100000


def profile_digest(profile, grayscale):
    if not isinstance(profile, str) or profile not in PROFILES or not isinstance(grayscale, bool):
        raise PackingError('Выберите известный режим сжатия и оттенков серого.')
    settings = dict(api=PREPARATION_API, profile=profile, grayscale=grayscale,
                    archive_method='PPMd', preserve_non_image_content=True)
    return hashlib.sha256(json.dumps(settings, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _fb2_content(path):
    # Compare the XML tree, including text, tails, IDs, links, metadata and
    # formatting tags. Only raster image bytes and their MIME can change;
    # vector graphics and attachments must remain exact.
    def node(element):
        attributes = dict(element.attrib)
        text = element.text
        if (element.tag == '{http://www.gribuser.ru/xml/fictionbook/2.0}binary'
                and attributes.get('content-type', '').lower() in
                {'image/jpeg', 'image/jpg', 'image/png', 'image/gif', 'image/bmp', 'image/webp', 'image/tiff'}):
            attributes.pop('content-type', None)
            text = None
        return element.tag, sorted(attributes.items()), text, element.tail, tuple(map(node, element))
    return node(ElementTree.parse(path).getroot())


def _image_mime(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'): return 'image/png'
    if data.startswith(b'\xff\xd8'): return 'image/jpeg'
    if data.startswith(b'GIF8'): return 'image/gif'
    if data.startswith(b'BM'): return 'image/bmp'
    if data.startswith((b'II*\0', b'MM\0*')): return 'image/tiff'
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP': return 'image/webp'
    return None


def _epub_content(path, output=False):
    result = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise PackingError('EPUB содержит повторяющиеся внутренние имена.')
        images = {name: _image_mime(archive.read(name)) for name in names
                  if Path(name).suffix.lower() in {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.tif', '.tiff'}}
        images = {name: mime for name, mime in images.items() if mime}

        def opf_node(element, package):
            attributes = dict(element.attrib)
            if element.tag == '{http://www.idpf.org/2007/opf}item':
                name = posixpath.normpath(posixpath.join(posixpath.dirname(package),
                                                       unquote(urlsplit(attributes.get('href', '')).path)))
                if name in images:
                    if output and attributes.get('media-type') != images[name]:
                        raise PackingError('Тип изображения EPUB не совпал с его содержимым.')
                    attributes.pop('media-type', None)
            return (element.tag, sorted(attributes.items()), element.text, element.tail,
                    tuple(opf_node(child, package) for child in element))

        for item in archive.infolist():
            if item.is_dir():
                result[item.filename] = None
            elif item.filename in images:
                result[item.filename] = 'image'
            elif item.filename.lower().endswith('.opf'):
                # Compare the whole package tree. Exempt only the MIME of an
                # actual raster image, and require its new MIME to be correct.
                result[item.filename] = opf_node(ElementTree.fromstring(archive.read(item)), item.filename)
            else:
                result[item.filename] = archive.read(item)
    return result


def verify_non_image_content(source, candidate, extension):
    try:
        if extension == '.fb2':
            unchanged = _fb2_content(source) == _fb2_content(candidate)
        elif extension == '.epub':
            unchanged = _epub_content(source) == _epub_content(candidate, output=True)
        elif extension in {'.docx', '.odt', '.cbz'}:
            unchanged = _container_content(source, extension) == _container_content(candidate, extension, output=True)
        else:
            return
    except (ElementTree.ParseError, zipfile.BadZipFile, KeyError, ValueError, RecursionError) as error:
        raise PackingError('Не удалось проверить сохранность текста и оформления книги.') from error
    if not unchanged:
        raise PackingError('Обработка изменила текст, оформление или метаданные. Сохранена исходная книга.')


def _container_content(path, extension, output=False):
    """Keep undeclared assets exact; exempt only the format's actual images."""
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise PackingError('Контейнер содержит повторяющиеся внутренние имена.')
        raster_types = {}
        for entry in archive.infolist():
            with archive.open(entry) as stream:
                media = _image_mime(stream.read(12))
                if media in {'image/png', 'image/jpeg'}:
                    raster_types[entry.filename] = media
        namespace = '{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}'
        if extension == '.odt':
            manifest = ElementTree.fromstring(archive.read('META-INF/manifest.xml'))
            declared = {n.get(namespace+'full-path'): n.get(namespace+'media-type', '').lower()
                        for n in manifest.iter(namespace+'file-entry')}
        elif extension == '.docx':
            types = ElementTree.fromstring(archive.read('[Content_Types].xml'))
            default = {n.get('Extension', '').lower(): n.get('ContentType', '').lower()
                       for n in types if n.tag.endswith('}Default')}
            override = {n.get('PartName', '').lstrip('/'): n.get('ContentType', '').lower()
                        for n in types if n.tag.endswith('}Override')}
            declared = {n: override.get(n, default.get(Path(n).suffix.lower()[1:])) for n in names
                        if n.startswith('word/media/') or n.startswith('docProps/thumbnail.')}
        else:
            declared = {n: 'image/png' if Path(n).suffix.lower() == '.png' else 'image/jpeg'
                        for n in names if Path(n).suffix.lower() in {'.png', '.jpg', '.jpeg'}}
        images = {n: archive.getinfo(n).file_size for n, media in raster_types.items()
                  if declared.get(n) == media}
        def manifest_node(element):
            attributes = dict(element.attrib)
            name = attributes.get(namespace+'full-path', '')
            if element.tag == namespace+'file-entry' and name in images and namespace+'size' in attributes:
                if output and attributes[namespace+'size'] != str(images[name]):
                    raise PackingError('Размер изображения в манифесте ODT не совпал с файлом.')
                attributes[namespace+'size'] = 'image-size'
            return (element.tag, sorted(attributes.items()), element.text, element.tail,
                    tuple(manifest_node(child) for child in element))
        result = []
        for entry in archive.infolist():
            data = archive.read(entry)
            media = _image_mime(data)
            content = ('raster', media) if entry.filename in images else data
            if extension == '.odt' and entry.filename == 'META-INF/manifest.xml':
                parser = ElementTree.XMLParser(target=ElementTree.TreeBuilder(insert_comments=True, insert_pis=True))
                content = manifest_node(ElementTree.fromstring(data, parser=parser))
            result.append((entry.filename, entry.date_time, entry.compress_type,
                           entry.comment, entry.extra, entry.external_attr,
                           entry.internal_attr, entry.create_system, content))
        return archive.comment, result


@dataclass
class PreparedBookCompression:
    source: str
    candidate: str | None
    source_sha256: str
    result_sha256: str
    profile_sha256: str
    input_bytes: int
    output_bytes: int
    payloads: list[dict]
    books: list[dict]
    working_bytes: int = 0
    originals: dict | None = None
    preview: dict | None = None

    @property
    def savings(self):
        return self.input_bytes - self.output_bytes

    def _receipt_template(self, template):
        value = copy.deepcopy(template)
        selected = {item['member'] for item in self.payloads}
        if (value.get('schema') != 1 or value.get('kind') != 'HomeLibre book compression'
                or canonical(value.get('source', '')) != canonical(self.source)
                or not value.get('rows') or
                {row.get('member') for row in value['rows']} != selected):
            raise PackingError('Список выбранных книг не соответствует подготовленному результату.')
        return value

    def receipt(self, template):
        value = self._receipt_template(template)
        if not self.candidate:
            raise PackingError('Сжатый результат не стал меньше. Исходник оставлен без изменений.')
        value.update(source_sha256=self.source_sha256, result_sha256=self.result_sha256,
                     profile_sha256=self.profile_sha256, payloads=copy.deepcopy(self.payloads))
        return value

    def inspection_receipt(self, template):
        """Remember checked original bytes, never a discarded transformation."""
        value = self._receipt_template(template)
        if self.candidate or self.result_sha256 != self.source_sha256 or self.output_bytes != self.input_bytes:
            raise PackingError('Для отметки без изменения нужен сохранённый исходный файл.')
        sizes = {book['member']: book['input_bytes'] for book in self.books}
        if len(sizes) != len(self.payloads) or set(sizes) != {p['member'] for p in self.payloads}:
            raise PackingError('Нет исходных размеров проверенных книг.')
        reused = {book['member']: book['reused'] for book in self.books}
        if any(reused[p['member']] and p['input_sha256'] != p['output_sha256'] for p in self.payloads):
            raise PackingError('Проверенные прежние изображения не соответствуют сохранённой книге.')
        payloads = [dict(member=p['member'], input_sha256=p['input_sha256'],
                         output_sha256=p['input_sha256'], size=sizes[p['member']], image_outputs=[],
                         source_image_outputs=copy.deepcopy(p.get('image_outputs', []))
                            if reused[p['member']] and p.get('checked', True) else [],
                         retry_original=not reused[p['member']], checked=p.get('checked', True))
                    for p in self.payloads]
        value.update(source_sha256=self.source_sha256, result_sha256=self.source_sha256,
                     profile_sha256=self.profile_sha256, payloads=payloads)
        return value

    def publish(self, report):
        atomic_json(report, asdict(self), replace=False)


def _source_stamp(path):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink() or info.st_nlink != 1:
        raise PackingError('Для сжатия нужен отдельный обычный файл без ссылок.')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


class OriginalBookBackup:
    """Prepare selected original payloads only, never a whole source archive.

    The verified ZIP stays in the private preparation workspace. The native
    caller publishes it to the user's backup folder only after approval and
    before changing the source. Skipping/cancelling needs no persistent copy.
    """
    MANIFEST = 'HomeLibre-originals.json'

    def __init__(self, workspace, source, source_sha, before, check):
        self.path = Path(workspace) / 'original-books.zip'
        self.source, self.source_sha, self.before = Path(source), source_sha, before
        self.check = check
        self.archive, self.owned, self.keep = None, False, False
        self.books = []

    def __enter__(self):
        try:
            self.archive = zipfile.ZipFile(self.path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6)
        except FileExistsError as error:
            raise PackingError('Файл подготовки оригиналов уже существует.') from error
        self.owned = True
        return self

    def add(self, original, member, expected):
        self.check()
        name = 'books/' + (member or self.source.name)
        digest, size = hashlib.sha256(), 0
        # Stream every original directly into the backup, then release its
        # extracted file as usual. Memory does not grow with the selection.
        with Path(original).open('rb') as incoming, self.archive.open(name, 'w', force_zip64=True) as outgoing:
            while True:
                self.check()
                chunk = incoming.read(1024 * 1024)
                if not chunk:
                    break
                outgoing.write(chunk)
                digest.update(chunk)
                size += len(chunk)
        if digest.hexdigest() != expected['payload_sha256'] or size != expected['payload_size']:
            raise PackingError('Не удалось сохранить точный оригинал выбранной книги.')
        self.books.append(dict(member=member, file=name, sha256=digest.hexdigest(), bytes=size))

    def finish(self, payloads):
        expected = {item['member']: item['input_sha256'] for item in payloads}
        if (len(self.books) != len(expected) or
                {item['member'] for item in self.books} != set(expected) or
                any(book['sha256'] != expected[book['member']] for book in self.books)):
            raise PackingError('Список оригиналов не соответствует выбранным книгам.')
        manifest = dict(version=1, kind='HomeLibre selected book originals', source=str(self.source),
                        source_sha256=self.source_sha, source_bytes=self.before[2],
                        source_mtime_ns=self.before[3], books=self.books)
        raw = json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2).encode('utf-8')
        if len(raw) > 16 * 1024 * 1024:
            raise PackingError('Слишком большой список оригиналов выбранных книг.')
        self.archive.writestr(self.MANIFEST, raw)
        self.archive.close()
        self.archive = None
        try:
            self.validate(manifest)
        except (zipfile.BadZipFile, zlib.error, ValueError) as error:
            raise PackingError('Не удалось проверить сохранённые оригиналы. Исходные книги не изменены.') from error
        return dict(path=str(self.path), sha256=digest_file(self.path, self.check),
                    bytes=self.path.stat().st_size, books=len(self.books),
                    manifest_sha256=hashlib.sha256(raw).hexdigest())

    def validate(self, manifest):
        self.check()
        with zipfile.ZipFile(self.path) as archive:
            expected = {self.MANIFEST, *(item['file'] for item in manifest['books'])}
            if set(archive.namelist()) != expected or len(archive.infolist()) != len(expected):
                raise PackingError('Подготовленный ZIP содержит неверный список оригиналов.')
            if json.loads(archive.read(self.MANIFEST)) != manifest:
                raise PackingError('Описание сохранённых оригиналов изменилось.')
            for book in manifest['books']:
                digest, size = hashlib.sha256(), 0
                with archive.open(book['file']) as incoming:
                    while True:
                        self.check()
                        chunk = incoming.read(1024 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                        size += len(chunk)
                if digest.hexdigest() != book['sha256'] or size != book['bytes']:
                    raise PackingError('Не прошла проверка сохранённого оригинала книги.')

    def __exit__(self, kind, value, traceback):
        try:
            if self.archive is not None:
                self.archive.close()
                self.archive = None
        finally:
            if self.owned and (kind is not None or not self.keep):
                self.path.unlink(missing_ok=True)


def _discard_prepared(result):
    if result.candidate:
        Path(result.candidate).unlink(missing_ok=True)
    if result.originals:
        Path(result.originals['path']).unlink(missing_ok=True)
    if result.preview:
        Path(result.preview['path']).unlink(missing_ok=True)


@contextmanager
def _candidate_cleanup(result):
    try:
        yield
    except BaseException:
        _discard_prepared(result)
        raise


def prepare_selected_file(source, members, workspace, seven_zip, *, profile='original',
                          grayscale=False, tools_root=None, previous=None, backup_originals=False, preview_images=False,
                          image_history_database=None,
                          canceled=lambda: False, notify=lambda value: None):
    """Prepare exactly the selected members, never modify originals.

    members maps exact archive names to catalogue extensions (only a staging
    hint). A single empty name means the physical file is the complete book.
    previous is the native ledger snapshot for this physical file, by member.
    Workspace is an empty owned directory on the native queue's volume.
    """
    settings_sha = profile_digest(profile, grayscale)
    if not isinstance(backup_originals, bool):
        raise PackingError('Выберите, нужно ли сохранять оригиналы книг.')
    if not isinstance(preview_images, bool):
        raise PackingError('Некорректный выбор сравнения изображений.')
    if (not isinstance(members, dict) or not 0 < len(members) <= MAX_MEMBERS
            or any(not isinstance(name, str) or not isinstance(ext, str) for name, ext in members.items())
            or ('' in members and len(members) != 1)):
        raise PackingError('Нужен точный список выбранных книг одного файла.')
    source, workspace = Path(source).absolute(), Path(workspace).absolute()
    if not source.is_file() or not workspace.is_dir() or workspace.is_symlink() or any(workspace.iterdir()):
        raise PackingError('Нужны исходный файл и пустая рабочая папка сжатия.')
    last_space_check = 0.0
    def check():
        nonlocal last_space_check
        if canceled():
            raise Canceled('Сжатие остановлено. Исходные книги не изменены.')
        now = time.monotonic()
        if now-last_space_check >= 1:
            reserve_space(workspace, 0)
            last_space_check = now

    check()
    before = _source_stamp(source)
    source_sha = digest_file(source, check)
    decoder = SevenZip(seven_zip, check)
    engine = 'illustrations-gray-ppmd' if grayscale else 'illustrations-ppmd'
    processor = Packer(dict(version=1, engine=engine if (profile != 'original' or grayscale) else 'reversible-ppmd',
                            images=profile, seven_zip=str(seven_zip), output=str(workspace),
                            plan=str(workspace / 'unused.sqlite'), dataset='selected-in-place',
                            tools_root=str(tools_root) if tools_root else None), notify, canceled)
    if profile != 'original' or grayscale:
        processor.load_image_processor()
        if getattr(processor.converter, 'PACKING_IMAGE_API', 0) < 3:
            raise PackingError('Для досжатия без повторной обработки изображений обновите HomeLibre BookProcessing.')
    previous = previous or {}
    result = PreparedBookCompression(str(source), None, source_sha, source_sha, settings_sha,
                                     before[2], before[2], [], [])
    container_sevenzip = False
    if '' in members:
        sizes = {'': before[2]}
    else:
        with source.open('rb') as stream:
            signature = stream.read(8)
        container_sevenzip = signature.startswith(b"7z\xbc\xaf'\x1c")
        if not signature.startswith((b'PK\x03\x04', b"7z\xbc\xaf'\x1c")):
            raise PackingError('Изменение на месте пока поддерживает общие архивы ZIP и 7z.')
        inventory = archive_inventory(decoder, source, workspace)
        sizes = {}
        for member in members:
            member_path(workspace / 'names', member)
            if member not in inventory or inventory[member]['directory']:
                raise PackingError('Не найден точный файл выбранной книги: ' + member)
            sizes[member] = inventory[member]['size']
    if max(sizes.values()) > MAX_BOOK:
        raise PackingError('Одна книга превышает предел обработки 512 МБ.')
    selected_bytes, largest = sum(sizes.values()), max(sizes.values())
    codec_extra = 4 * largest if processor.converter is not None else largest
    result.working_bytes = selected_bytes + max(codec_extra, before[2] + largest) + 16 * 1024 * 1024
    if backup_originals:
        result.working_bytes += selected_bytes + 16 * 1024 * 1024
    if preview_images and processor.converter is not None:
        result.working_bytes += MAX_COMPARISON_BYTES + 1024 * 1024
    reserve_space(workspace, result.working_bytes)
    preview_context = ComparisonPreview(workspace, check, len(members)) if preview_images else nullcontext()
    notify(dict(stage='Оцениваем временное место', working_bytes=result.working_bytes,
                selected_bytes=selected_bytes, archive_bytes=before[2]))
    # Selected payloads survive only in a verified complete candidate. All
    # extraction/codec files use a guarded owned temporary directory.
    with CompressedImageHistory(image_history_database if processor.converter is not None else None, settings_sha, check) as image_history, \
            _candidate_cleanup(result), temporary_work_directory(workspace, '.selected-') as staging, \
            (OriginalBookBackup(workspace, source, source_sha, before, check)
             if backup_originals else nullcontext()) as originals, preview_context as preview:
        legacy = image_history.legacy_books(source, members, profile, grayscale) if not all(
            member in previous for member in members) else {}
        replacements = {}
        for number, (member, hint) in enumerate(members.items()):
            check()
            notify(dict(stage='Подготавливаем выбранную книгу', current=number, total=len(members), member=member))
            book_dir = staging / str(number)
            book_dir.mkdir()
            reserve_space(book_dir, sizes[member] * (3 if processor.converter is not None else 2))
            # Never use a catalogue path as a Windows output filename.
            extension = hint.lower() if hint.startswith('.') and hint[1:].isalnum() and len(hint) <= 16 else '.bin'
            original = book_dir / ('original' + extension)
            if member:
                decoder.extract(source, member, original, book_dir)
            else:
                if source.stat().st_size > MAX_BOOK:
                    raise PackingError('Одна книга превышает предел обработки 512 МБ.')
                copy_exact(source, original, check)
            initial = book_signature(original, check)
            if originals is not None:
                notify(dict(stage='Сохраняем оригинал выбранной книги', current=number, total=len(members), member=member))
                originals.add(original, member, initial)
            current = book_dir / ('book' + extension)
            copy_exact(original, current, check)
            ledger = previous.get(member, legacy.get(member, {}))
            # An explicitly unchanged original may need a new handler after
            # an engine update. Keep legacy/transformed outputs byte-exact.
            reuse = (ledger.get('profile_sha256') == settings_sha
                     and ledger.get('output_sha256') == initial['payload_sha256']
                     and not ledger.get('retry_original', False))
            reason, optimized, image_outputs, checked = '', False, [], True
            detected_format = extension
            nested_epub = False
            if container_sevenzip and extension == '.epub':
                with current.open('rb') as stream:
                    nested_epub = stream.read(6) == b"7z\xbc\xaf'\x1c"
                if nested_epub:
                    from nested_epub_compression import is_nested_epub
                    nested_epub = is_nested_epub(current, book_dir, decoder)
            images_reused = images_processed = 0
            if reuse:
                reason = 'Уже сжата с этими настройками; повторная обработка изображений не нужна.'
                if processor.converter is not None:
                    detected = '.epub' if nested_epub else processor.converter.detect_input(current)
                    detected_format = detected
                    if member not in previous and member in legacy and detected in IMAGE_SUFFIXES and not nested_epub and current.stat().st_size <= MAX_IMAGE_BOOK:
                        collect = getattr(processor.converter, 'compressed_image_hashes', None)
                        if not callable(collect):
                            raise PackingError('Для переноса истории изображений обновите модуль подготовки книг.')
                        image_outputs = collect(current, detected, check)
                        images_reused = len(image_outputs)
            elif processor.converter is not None:
                try:
                    detected = '.epub' if nested_epub else processor.converter.detect_input(current)
                    detected_format = detected
                    if detected in IMAGE_SUFFIXES or (detected == '.djvu' and profile == 'maximum'):
                        if detected != extension:
                            renamed = book_dir / ('book' + detected)
                            current.rename(renamed)
                            current, extension = renamed, detected
                        if extension in IMAGE_SUFFIXES and original.stat().st_size > MAX_IMAGE_BOOK:
                            reason = 'Книга слишком велика для изменения иллюстраций; содержимое сохранено.'
                        else:
                            with current.open('rb') as stream:
                                nested_epub = (container_sevenzip and extension == '.epub' and
                                               stream.read(6) == b"7z\xbc\xaf'\x1c")
                            if nested_epub:
                                from nested_epub_compression import optimize_nested_epub
                                status = optimize_nested_epub(current, book_dir, processor, decoder,
                                    image_history.contains, verify_non_image_content, check)
                            else:
                                status = processor.optimize_book(current, book_dir,
                                    image_history=image_history.contains, collect_image_history=extension in IMAGE_SUFFIXES)
                            image_outputs = status.get('image_outputs', [])
                            images_reused = status.get('images_reused', 0)
                            images_processed = status.get('images_processed', 0)
                            optimized = status.get('image_result') == 'optimized'
                            reason = status.get('image_reason', '')
                            if images_reused and not reason:
                                reason = f'Уже обработанные изображения сохранены без пересжатия: {images_reused}. Новых обработано: {images_processed}.'
                            if status.get('image_result') == 'skipped':
                                raise PackingError(reason or 'Иллюстрации не обработаны; исходное содержимое сохранено.')
                            if optimized and not status.get('nested_epub_verified', False):
                                verify_non_image_content(original, current, extension)
                    else:
                        reason = 'Для этого формата пока меняется только упаковка, содержимое сохранено.'
                except Canceled:
                    raise
                except (processor.converter.ConversionError, PackingError, zipfile.BadZipFile) as error:
                    # A bad book never becomes a half-transformed output.
                    current.unlink(missing_ok=True)
                    current = book_dir / ('kept' + extension)
                    copy_exact(original, current, check)
                    optimized, reason, checked = False, str(error)[:500], False
                    image_outputs = []
                    images_reused = images_processed = 0
            final = book_signature(current, check)
            if final['payload_size'] > initial['payload_size']:
                raise PackingError('Подготовленная книга стала больше исходной.')
            result.payloads.append(dict(member=member, input_sha256=initial['payload_sha256'],
                                        output_sha256=final['payload_sha256'], size=final['payload_size'],
                                        image_outputs=image_outputs, retry_original=not (optimized or reuse), checked=checked))
            result.books.append(dict(member=member, format=detected_format, optimized=optimized, reused=reuse,
                                     input_bytes=initial['payload_size'], output_bytes=final['payload_size'], reason=reason,
                                     images_reused=images_reused, images_processed=images_processed, checked=checked))
            if preview is not None and optimized:
                try:
                    preview.add_book(original, current, extension, member)
                except (ValueError, ElementTree.ParseError, zipfile.BadZipFile):
                    preview.limited = True
            replacements[member] = current
            # The source archive remains intact. Once its semantic comparison
            # and digests are captured, this extra extracted original is no
            # longer needed alongside every already prepared selected book.
            original.unlink()
        check()
        if _source_stamp(source) != before or digest_file(source, check) != source_sha:
            raise PackingError('Исходный файл изменился во время подготовки книг.')
        if '' in replacements:
            prepared = replacements['']
            if prepared.stat().st_size < before[2]:
                candidate = workspace / 'prepared-book.bin'
                prepared.rename(candidate)
                result.candidate, result.result_sha256 = str(candidate), digest_file(candidate, check)
                result.output_bytes = candidate.stat().st_size
        else:
            output = staging / 'archive'
            output.mkdir()
            prepared = prepare_archive_replacement(source, replacements, output, seven_zip,
                method='PPMd', canceled=canceled, owned_replacements_root=staging,
                expected_payload_sha256={p['member']: p['output_sha256'] for p in result.payloads})
            if prepared.original_sha256 != source_sha:
                if prepared.candidate: prepared.candidate.unlink(missing_ok=True)
                raise PackingError('Исходный архив изменился во время обработки книг.')
            if prepared.candidate:
                candidate = workspace / 'prepared-archive.bin'
                prepared.candidate.rename(candidate)
                result.candidate, result.result_sha256 = str(candidate), prepared.prepared_sha256
                result.output_bytes = prepared.output_bytes
        if originals is not None and result.candidate is not None:
            result.originals = originals.finish(result.payloads)
            originals.keep = True
        if preview is not None:
            result.preview = preview.finish()
            if result.candidate is None and result.preview:
                Path(result.preview['path']).unlink(missing_ok=True)
                result.preview = None
            preview.keep = result.preview is not None
    try:
        check()
        if _source_stamp(source) != before or digest_file(source, check) != source_sha:
            raise PackingError('Исходный файл изменился во время сжатия.')
        notify(dict(stage='Подготовка завершена', current=len(members), total=len(members),
                    input_bytes=result.input_bytes, output_bytes=result.output_bytes))
        return result
    except BaseException:
        _discard_prepared(result)
        raise


def prepare_request(request, *, canceled=lambda: False, notify=lambda value: None):
    """Prepare the ordinary book and its native FLibrary dependencies together.

    Publication remains native. Complete-book backups and previews for stripped
    books are deferred until the native reader has restored both versions.
    """
    template = request.get('receipt_template') or {}
    if not isinstance(template, dict):
        raise PackingError('Некорректное описание каталога сжатия.')
    external = None
    prepared = None
    if request.get('external_images', False) and '' not in request['members']:
        from external_image_preparation import prepare_external_images, reader_sources
        folder = Path(request['workspace']).parent / 'external-images'
        folder.mkdir()
        try:
            with CompressedImageHistory(template.get('catalogue'),
                    profile_digest(request.get('profile', 'original'), request.get('grayscale', False)),
                    lambda: _check_canceled(canceled)) as history:
                external_prepared = prepare_external_images(request['source'], request['members'], folder,
                    request['seven_zip'], profile=request.get('profile', 'original'),
                    grayscale=request.get('grayscale', False), tools_root=request.get('tools_root'),
                    jpeg_xl_decoder=request.get('jpeg_xl_decoder'), preserve_image=history.contains,
                    canceled=canceled, notify=notify)
            if external_prepared.supported:
                external = dict(version=1, kind='HomeLibre external image preparation',
                    **asdict(external_prepared), members=request['members'],
                    original_image_sources=reader_sources(external_prepared, candidates=False),
                    prepared_image_sources=reader_sources(external_prepared, candidates=True))
        except BaseException:
            for path in folder.glob('prepared-*.bin'):
                path.unlink(missing_ok=True)
            raise
    try:
        prepared = prepare_selected_file(request['source'], request['members'], request['workspace'],
            request['seven_zip'], profile=request.get('profile', 'original'),
            grayscale=request.get('grayscale', False), tools_root=request.get('tools_root'),
            previous=request.get('previous'),
            backup_originals=request.get('backup_originals', False) and external is None,
            preview_images=request.get('preview_images', False) and external is None,
            image_history_database=template.get('catalogue'), canceled=canceled, notify=notify)
        result = asdict(prepared)
        changed = prepared.candidate or (external and any(a['candidate'] for a in external['archives']))
        receipt = (prepared.receipt(template) if prepared.candidate else prepared.inspection_receipt(template))
        if external:
            if external['source_witness']['sha256'] != prepared.source_sha256:
                raise PackingError('Архив книг изменился между подготовкой текста и картинок.')
            result['external_images'] = external
            # Only outputs actually retained in the prepared archives enter
            # history. Discarded encodings never suppress a later retry.
            by_id = {}
            from external_image_preparation import _book_id
            for payload in receipt['payloads']:
                by_id.setdefault(_book_id(payload['member']), []).append(payload)
            for archive in external['archives']:
                for image in archive['images']:
                    identity = image['member'].split('/', 1)[0].casefold()
                    for payload in by_id.get(identity, []):
                        if image['changed'] or image['reused']:
                            payload.setdefault('image_outputs', []).append(image['output_sha256'])
                        if image['changed']:
                            for book in result['books']:
                                if book['member'] == payload['member']:
                                    book['optimized'] = True
                        if not image['checked']:
                            payload['checked'] = False
                            for book in result['books']:
                                if book['member'] == payload['member']:
                                    book.update(checked=False, reason=image['reason'])
            if not changed:
                for payload in receipt['payloads']:
                    retained = payload.get('image_outputs', [])
                    if retained and payload.get('checked', True):
                        payload.setdefault('source_image_outputs', []).extend(retained)
                        payload['retry_original'] = False
                    payload['image_outputs'] = []
        result['receipt' if changed else 'inspection_receipt'] = receipt
        return result, prepared
    except BaseException:
        if prepared is not None:
            _discard_prepared(prepared)
        if external:
            for archive in external['archives']:
                if archive['candidate']:
                    Path(archive['candidate']).unlink(missing_ok=True)
        raise


def _check_canceled(canceled):
    if canceled():
        raise Canceled('Сжатие остановлено. Исходные книги не изменены.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', type=Path, required=True)
    parser.add_argument('--cancel', type=Path)
    arguments = parser.parse_args()

    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)

    prepared = None
    try:
        if arguments.job.stat().st_size > 16 * 1024 * 1024:
            raise PackingError('Слишком большой список выбранных книг.')
        request = json.loads(arguments.job.read_text('utf-8-sig'))
        if not isinstance(request, dict) or request.get('version') != PREPARATION_API:
            raise PackingError('Неизвестная версия задания сжатия выбранных книг.')
        result, prepared = prepare_request(request,
            canceled=lambda: arguments.cancel is not None and arguments.cancel.exists(), notify=emit)
        atomic_json(request['report'], result, replace=False)
        emit(dict(stage='ready', candidate=bool(prepared.candidate), savings=prepared.savings))
        return 0
    except Canceled as error:
        if prepared: _discard_prepared(prepared)
        emit(dict(stage='cancelled', message=str(error)))
        return 2
    except (PackingError, OSError, ValueError, KeyError, TypeError) as error:
        if prepared: _discard_prepared(prepared)
        emit(dict(stage='error', message=str(error)))
        return 1


if __name__ == '__main__':
    # The native caller consumes UTF-8 JSON, including Russian diagnostics.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
