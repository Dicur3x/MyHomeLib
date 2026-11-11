"""Read-only preparation of selected physical books for the native commit job.

The native selection adapter supplies exact member names and an immutable
catalogue receipt template. This module never changes a source or a database.
The returned candidate is applied only by TBookCompressionJob.
"""
from dataclasses import asdict, dataclass
from contextlib import contextmanager
import argparse
import copy
import hashlib
import json
from pathlib import Path
import posixpath
import stat
import sys
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree
import zipfile

# The shipped embedded Python uses -I and an isolated ._pth file. Import
# only this verified component's sibling modules, never the process cwd.
if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from archive_replacement import archive_inventory, member_path, prepare_archive_replacement
from pack_collection import (Canceled, IMAGE_SUFFIXES, MAX_BOOK, MAX_IMAGE_BOOK,
                             Packer, PackingError, SevenZip, atomic_json,
                             book_signature, canonical, copy_exact, digest_file,
                             reserve_space, temporary_work_directory)


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
        else:
            return
    except (ElementTree.ParseError, zipfile.BadZipFile, ValueError, RecursionError) as error:
        raise PackingError('Не удалось проверить сохранность текста и оформления книги.') from error
    if not unchanged:
        raise PackingError('Обработка изменила текст, оформление или метаданные. Сохранена исходная книга.')


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

    @property
    def savings(self):
        return self.input_bytes - self.output_bytes

    def receipt(self, template):
        value = copy.deepcopy(template)
        selected = {item['member'] for item in self.payloads}
        if (value.get('schema') != 1 or value.get('kind') != 'HomeLibre book compression'
                or canonical(value.get('source', '')) != canonical(self.source)
                or not value.get('rows') or
                {row.get('member') for row in value['rows']} != selected):
            raise PackingError('Список выбранных книг не соответствует подготовленному результату.')
        if not self.candidate:
            raise PackingError('Сжатый результат не стал меньше. Исходник оставлен без изменений.')
        value.update(source_sha256=self.source_sha256, result_sha256=self.result_sha256,
                     profile_sha256=self.profile_sha256, payloads=copy.deepcopy(self.payloads))
        return value

    def publish(self, report):
        atomic_json(report, asdict(self), replace=False)


def _source_stamp(path):
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink() or info.st_nlink != 1:
        raise PackingError('Для сжатия нужен отдельный обычный файл без ссылок.')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


@contextmanager
def _candidate_cleanup(result):
    try:
        yield
    except BaseException:
        if result.candidate:
            Path(result.candidate).unlink(missing_ok=True)
        raise


def prepare_selected_file(source, members, workspace, seven_zip, *, profile='original',
                          grayscale=False, tools_root=None, previous=None,
                          canceled=lambda: False, notify=lambda value: None):
    """Prepare exactly the selected members, never modify originals.

    members maps exact archive names to catalogue extensions (only a staging
    hint). A single empty name means the physical file is the complete book.
    previous is the native ledger snapshot for this physical file, by member.
    Workspace is an empty owned directory on the native queue's volume.
    """
    settings_sha = profile_digest(profile, grayscale)
    if (not isinstance(members, dict) or not 0 < len(members) <= MAX_MEMBERS
            or any(not isinstance(name, str) or not isinstance(ext, str) for name, ext in members.items())
            or ('' in members and len(members) != 1)):
        raise PackingError('Нужен точный список выбранных книг одного файла.')
    source, workspace = Path(source).absolute(), Path(workspace).absolute()
    if not source.is_file() or not workspace.is_dir() or workspace.is_symlink() or any(workspace.iterdir()):
        raise PackingError('Нужны исходный файл и пустая рабочая папка сжатия.')
    def check():
        if canceled():
            raise Canceled('Сжатие остановлено. Исходные книги не изменены.')

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
    previous = previous or {}
    result = PreparedBookCompression(str(source), None, source_sha, source_sha, settings_sha,
                                     before[2], before[2], [], [])
    if '' in members:
        sizes = {'': before[2]}
    else:
        with source.open('rb') as stream:
            signature = stream.read(8)
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
    notify(dict(stage='Оцениваем временное место', working_bytes=result.working_bytes,
                selected_bytes=selected_bytes, archive_bytes=before[2]))
    # Selected payloads survive only in a verified complete candidate. All
    # extraction/codec files use a guarded owned temporary directory.
    with _candidate_cleanup(result), temporary_work_directory(workspace, '.selected-') as staging:
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
            current = book_dir / ('book' + extension)
            copy_exact(original, current, check)
            ledger = previous.get(member, {})
            reuse = (ledger.get('profile_sha256') == settings_sha
                     and ledger.get('output_sha256') == initial['payload_sha256'])
            reason, optimized = '', False
            if reuse:
                reason = 'Уже сжата с этими настройками; повторная обработка изображений не нужна.'
            elif processor.converter is not None:
                try:
                    detected = processor.converter.detect_input(current)
                    if detected in IMAGE_SUFFIXES or (detected == '.djvu' and profile == 'maximum'):
                        if detected != extension:
                            renamed = book_dir / ('book' + detected)
                            current.rename(renamed)
                            current, extension = renamed, detected
                        if extension in IMAGE_SUFFIXES and original.stat().st_size > MAX_IMAGE_BOOK:
                            reason = 'Книга слишком велика для изменения иллюстраций; содержимое сохранено.'
                        else:
                            status = processor.optimize_book(current, book_dir)
                            optimized = status.get('image_result') == 'optimized'
                            reason = status.get('image_reason', '')
                            if status.get('image_result') == 'skipped' and not reason:
                                reason = 'Иллюстрации не обработаны; исходное содержимое сохранено.'
                            if optimized:
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
                    optimized, reason = False, str(error)[:500]
            final = book_signature(current, check)
            if final['payload_size'] > initial['payload_size']:
                raise PackingError('Подготовленная книга стала больше исходной.')
            result.payloads.append(dict(member=member, input_sha256=initial['payload_sha256'],
                                        output_sha256=final['payload_sha256'], size=final['payload_size']))
            result.books.append(dict(member=member, format=extension, optimized=optimized, reused=reuse,
                                     input_bytes=initial['payload_size'], output_bytes=final['payload_size'], reason=reason))
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
    try:
        check()
        if _source_stamp(source) != before or digest_file(source, check) != source_sha:
            raise PackingError('Исходный файл изменился во время сжатия.')
        notify(dict(stage='Подготовка завершена', current=len(members), total=len(members),
                    input_bytes=result.input_bytes, output_bytes=result.output_bytes))
        return result
    except BaseException:
        if result.candidate: Path(result.candidate).unlink(missing_ok=True)
        raise


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
        prepared = prepare_selected_file(request['source'], request['members'], request['workspace'],
                                         request['seven_zip'], profile=request.get('profile', 'original'),
                                         grayscale=request.get('grayscale', False), tools_root=request.get('tools_root'),
                                         previous=request.get('previous'),
                                         canceled=lambda: arguments.cancel is not None and arguments.cancel.exists(),
                                         notify=emit)
        result = asdict(prepared)
        # A single atomic publication binds the filesystem candidate and the
        # exact native receipt. No half-published second receipt file is used.
        if prepared.candidate:
            result['receipt'] = prepared.receipt(request['receipt_template'])
        atomic_json(request['report'], result, replace=False)
        emit(dict(stage='ready', candidate=bool(prepared.candidate), savings=prepared.savings))
        return 0
    except Canceled as error:
        if prepared and prepared.candidate: Path(prepared.candidate).unlink(missing_ok=True)
        emit(dict(stage='cancelled', message=str(error)))
        return 2
    except (PackingError, OSError, ValueError, KeyError, TypeError) as error:
        if prepared and prepared.candidate: Path(prepared.candidate).unlink(missing_ok=True)
        emit(dict(stage='error', message=str(error)))
        return 1


if __name__ == '__main__':
    # The native caller consumes UTF-8 JSON, including Russian diagnostics.
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
