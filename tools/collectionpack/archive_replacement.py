"""Prepare one archive for in-place book compression; never modify its source.

Only explicitly named members are replaced. The caller owns the subsequent
durable commit and catalogue refresh. A prepared file is not a completed edit.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
import itertools
import io
import os
import struct
import tempfile
import zipfile

from pack_collection import (BLOCK, Canceled, MAX_BOOK, PackingError, SevenZip,
                             book_signature, canonical, copy_exact, digest_file,
                             reserve_space)


@dataclass(frozen=True)
class PreparedArchive:
    source: Path
    candidate: Path | None
    original_sha256: str
    prepared_sha256: str
    input_bytes: int
    output_bytes: int
    members: tuple[str, ...]


def member_path(directory, member):
    # Replacement files are materialized on Windows. No alternate streams,
    # wildcards, parent traversal, or silently normalized trailing dots/spaces.
    parts = PurePosixPath(member).parts
    if (not parts or member.startswith('/') or '\\' in member or
            any(part in ('', '.', '..') or part.endswith(('.', ' ')) or
                PureWindowsPath(part).is_reserved() or
                any(ord(c) < 32 or c in '<>:"|?*' for c in part) for part in parts) or
            str(PurePosixPath(member)) != member):
        raise PackingError('Недопустимое точное имя книги в архиве: ' + member)
    target = Path(directory).joinpath(*parts)
    if not Path(canonical(target)).is_relative_to(Path(canonical(directory))):
        raise PackingError('Имя книги выходит за временную папку.')
    return target


def archive_inventory(seven, archive, work):
    # Technical listing avoids extraction of the whole collection. The next
    # validation step tests every compressed stream in the resulting archive.
    with tempfile.TemporaryFile(dir=work) as listing:
        seven.run(['l', '-slt', '-ba', '-sccUTF-8', '--', str(archive)],
                  cwd=work, output=listing, limit=64 * 1024 * 1024)
        listing.seek(0)
        entries, fields = {}, {}
        with io.TextIOWrapper(listing, encoding='utf-8-sig') as text:
            for raw in itertools.chain(text, ['']):
                line = raw.rstrip('\r\n')
                if line:
                    if ' = ' not in line:
                        raise PackingError('Не удалось однозначно прочитать список файлов архива.')
                    key, value = line.split(' = ', 1)
                    if key in fields:
                        raise PackingError('Неоднозначные сведения о файле в архиве.')
                    fields[key] = value
                elif fields:
                    raw_name = fields.get('Path')
                    # The Windows CLI prints directory separators as '\\'
                    # even for ZIP entries whose stored names contain '/'.
                    # Refuse aliases that become ambiguous after this mapping.
                    name = raw_name.replace('\\', '/') if raw_name else None
                    if not name or name in entries or fields.get('Encrypted', '-') != '-':
                        raise PackingError('Архив содержит повторяющиеся имена или зашифрованные файлы.')
                    try:
                        size = int(fields['Size'])
                    except (ValueError, KeyError) as error:
                        raise PackingError('Не удалось прочитать размер файла в архиве.') from error
                    if size < 0:
                        raise PackingError('Неверный размер файла в архиве.')
                    entries[name] = dict(size=size, crc=fields.get('CRC'),
                                         directory=fields.get('Folder') == '+' or
                                         fields.get('Attributes', '').startswith('D'))
                    fields = {}
    if not entries:
        raise PackingError('В исходном архиве нет файлов.')
    return entries


def restore_zip_comments(source, candidate):
    # The upstream updater preserves file payloads, but may omit ZIP comments.
    # Keep encoded filenames, Unicode-path extras and local-header flags exact:
    # ZipFile's append writer can otherwise change the central UTF-8 flag while
    # retaining the upstream local header, causing a 7-Zip Headers Error.
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(candidate) as result:
        original_comments = {entry.filename: entry.comment for entry in original.infolist()}
        entries, start = result.infolist(), result.start_dir
        archive_comment = original.comment
        if result.comment == archive_comment and all(
                entry.comment == original_comments[entry.filename] for entry in entries):
            return
    with candidate.open('r+b') as archive, tempfile.TemporaryFile(dir=candidate.parent) as metadata:
        archive.seek(start)
        for entry in entries:
            header = bytearray(archive.read(46))
            if len(header) != 46 or header[:4] != b'PK\x01\x02':
                raise PackingError('Не удалось сохранить сведения о файлах ZIP.')
            name_size, extra_size, old_comment_size = struct.unpack_from('<HHH', header, 28)
            variable = archive.read(name_size + extra_size + old_comment_size)
            if len(variable) != name_size + extra_size + old_comment_size:
                raise PackingError('Оборван центральный каталог ZIP.')
            comment = original_comments[entry.filename]
            struct.pack_into('<H', header, 32, len(comment))
            metadata.write(header)
            metadata.write(variable[:name_size + extra_size])
            metadata.write(comment)
        old_size, new_size = archive.tell() - start, metadata.tell()
        tail = bytearray(archive.read(1024 * 1024 + 1))
        if len(tail) > 1024 * 1024:
            raise PackingError('Слишком большой служебный конец ZIP.')
        eocd = 0
        if tail[:4] == b'PK\x06\x06':
            if len(tail) < 56:
                raise PackingError('Оборван служебный конец ZIP64.')
            locator = 12 + struct.unpack_from('<Q', tail, 4)[0]
            if (struct.unpack_from('<Q', tail, 40)[0] != old_size or
                    tail[locator:locator + 4] != b'PK\x06\x07'):
                raise PackingError('Неверные смещения центрального каталога ZIP64.')
            struct.pack_into('<Q', tail, 40, new_size)
            struct.pack_into('<Q', tail, locator + 8, start + new_size)
            eocd = locator + 20
        if len(tail) < eocd + 22 or tail[eocd:eocd + 4] != b'PK\x05\x06':
            raise PackingError('Не найден служебный конец ZIP.')
        declared = struct.unpack_from('<I', tail, eocd + 12)[0]
        if declared != 0xFFFFFFFF:
            if declared != old_size or new_size >= 0xFFFFFFFF:
                raise PackingError('Неверный размер центрального каталога ZIP.')
            struct.pack_into('<I', tail, eocd + 12, new_size)
        comment_size = struct.unpack_from('<H', tail, eocd + 20)[0]
        if len(tail) != eocd + 22 + comment_size:
            raise PackingError('Некорректная длина комментария ZIP.')
        struct.pack_into('<H', tail, eocd + 20, len(archive_comment))
        metadata.write(tail[:eocd + 22])
        metadata.write(archive_comment)
        metadata.seek(0)
        archive.seek(start)
        while chunk := metadata.read(BLOCK):
            archive.write(chunk)
        archive.truncate()
        archive.flush()
        os.fsync(archive.fileno())


def prepare_archive_replacement(source, replacements, workspace, seven_zip,
                                *, method=None, canceled=lambda: False,
                                owned_replacements_root=None, expected_payload_sha256=None):
    """Return a verified smaller candidate, or candidate=None when it cannot win.

    ``replacements`` maps exact archive names to already prepared book files.
    Workspace must be empty, private, and outside the source archive. It is not
    a backup directory. The source stays intact. Input replacements stay intact
    by default; a caller may explicitly transfer disposable files from its own
    private staging root instead of duplicating all selected book payloads.
    """
    source, work = Path(source).absolute(), Path(workspace).absolute()
    if not source.is_file() or source.is_symlink():
        raise PackingError('Исходный архив недоступен или является ссылкой.')
    if not work.is_dir() or any(work.iterdir()) or work.is_symlink():
        raise PackingError('Для подготовки архива нужна пустая временная папка.')
    if not replacements or len(replacements) > 100000:
        raise PackingError('Не выбраны книги для сжатия.')
    owner = None
    if owned_replacements_root is not None:
        owner = Path(canonical(owned_replacements_root))
        if (not owner.is_dir() or Path(owned_replacements_root).is_symlink()
                or not Path(canonical(work)).is_relative_to(owner)
                or Path(canonical(source)).is_relative_to(owner)):
            raise PackingError('Исходный архив нельзя переносить во временные файлы сжатия.')
    if expected_payload_sha256 is not None and set(expected_payload_sha256) != set(replacements):
        raise PackingError('Не совпал проверенный список подготовленных книг.')

    def check():
        if canceled():
            raise Canceled('Сжатие остановлено. Исходный архив сохранён.')

    seven = SevenZip(seven_zip, check)
    check()
    with source.open('rb') as stream:
        magic = stream.read(8)
    if magic.startswith(b"7z\xbc\xaf'\x1c"):
        kind, allowed = '7z', ('Copy', 'LZMA', 'LZMA2', 'PPMd')
    elif magic.startswith(b'PK\x03\x04'):
        kind, allowed = 'zip', ('Copy', 'Deflate', 'LZMA', 'PPMd')
    else:
        raise PackingError('Для изменения на месте пока требуется обычный ZIP или 7z.')
    method = method or ('Deflate' if kind == 'zip' else 'LZMA2')
    if method not in allowed:
        raise PackingError('Неподдерживаемый метод сжатия выбранного архива.')
    before_stat = source.stat()
    before_hash = digest_file(source, check)
    inventory = archive_inventory(seven, source, work)
    updates = work / 'members'
    updates.mkdir()
    copied, folded = {}, set()
    candidate = work / ('prepared.' + kind)
    try:
        sizes = [Path(p).stat().st_size for p in replacements.values()]
        # Transferred inputs already occupy the same private drive. The
        # additional large files are the candidate and one decoded check book.
        reserve_space(work, before_stat.st_size + (max(sizes) if owner else sum(sizes)))
        for member, prepared in replacements.items():
            check()
            target = member_path(updates, member)
            if member.casefold() in folded:
                raise PackingError('Имена выбранных книг совпадают в Windows.')
            folded.add(member.casefold())
            old = inventory.get(member)
            if old is None or old['directory']:
                raise PackingError('Точная книга не найдена в исходном архиве: ' + member)
            prepared = Path(prepared)
            if (not prepared.is_file() or prepared.is_symlink() or
                    not 0 < prepared.stat().st_size <= MAX_BOOK):
                raise PackingError('Подготовленный файл книги недоступен или слишком велик: ' + member)
            target.parent.mkdir(parents=True, exist_ok=True)
            if owner is None:
                copy_exact(prepared, target, check)
            else:
                if (not Path(canonical(prepared)).is_relative_to(owner)
                        or prepared.stat().st_nlink != 1):
                    raise PackingError('Для переноса разрешены только собственные временные книги.')
                identity = prepared.stat()
                prepared.rename(target)
                moved = target.stat()
                if (target.is_symlink() or (moved.st_dev, moved.st_ino) !=
                        (identity.st_dev, identity.st_ino)):
                    raise PackingError('Подготовленная книга изменилась при переносе.')
            copied[member] = book_signature(target, check)
            if (expected_payload_sha256 is not None and
                    copied[member]['payload_sha256'] != expected_payload_sha256[member]):
                raise PackingError('Подготовленная книга изменилась после проверки: ' + member)
        listing = work / 'replace.txt'
        listing.write_text('\n'.join(copied) + '\n', encoding='utf-8')
        # -u- forbids changing the base archive. Unselected members are copied
        # by the archiver; selected members are always replaced, even when the
        # prepared file is older or has the same timestamp and length.
        seven.run(['u', '-t' + kind, '-u-',
                   '-up1q1r0x2y2z2w2!' + str(candidate), '-m0=' + method if kind == '7z' else '-mm=' + method,
                   '-mmt=2', '-scsUTF-8', '-spd', '-ssc', '-y', str(source), '@' + str(listing)], cwd=updates)
        if kind == 'zip':
            restore_zip_comments(source, candidate)
        after = archive_inventory(seven, candidate, work)
        if after.keys() != inventory.keys():
            raise PackingError('При сжатии изменился список соседних файлов архива.')
        for member, old in inventory.items():
            check()
            actual = after[member]
            if actual['directory'] != old['directory']:
                raise PackingError('Изменился тип соседнего элемента архива: ' + member)
            if member not in copied:
                if actual != old:
                    raise PackingError('Изменилась соседняя книга или служебный файл: ' + member)
            else:
                expected = copied[member]
                if (actual['size'] != expected['payload_size'] or
                        actual['crc'] != f"{expected['payload_crc32']:08X}"):
                    raise PackingError('Созданный архив не совпал с подготовленной книгой: ' + member)
        seven.run(['t', '-bb0', '-bso0', '-bsp0', '-mmt=2', '--', str(candidate)], cwd=work)
        for number, (member, expected) in enumerate(copied.items()):
            check()
            decoded = work / ('check-' + str(number))
            try:
                seven.extract(candidate, member, decoded, work)
                if digest_file(decoded, check) != expected['payload_sha256']:
                    raise PackingError('Проверка содержимого сжатой книги не пройдена: ' + member)
            finally:
                decoded.unlink(missing_ok=True)
        if (source.stat().st_size != before_stat.st_size or digest_file(source, check) != before_hash):
            raise PackingError('Исходный архив изменился во время подготовки сжатия.')
        size = candidate.stat().st_size
        if size >= before_stat.st_size:
            candidate.unlink()
            return PreparedArchive(source, None, before_hash, before_hash,
                                   before_stat.st_size, before_stat.st_size, tuple(copied))
        return PreparedArchive(source, candidate, before_hash, digest_file(candidate, check),
                               before_stat.st_size, size, tuple(copied))
    except BaseException:
        candidate.unlink(missing_ok=True)
        raise
