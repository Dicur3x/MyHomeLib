"""Prepare selected FLibrary image archives; publishing belongs to the native job.

The outer book archive and all image sources remain read-only. An image
candidate is not a completed edit, and must never be published without the
book/dependency witnesses and the native recovery/backup transaction.
"""
from dataclasses import asdict, dataclass, field
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import posixpath
import subprocess
import sys
import time

# The installed embedded interpreter is isolated; load only this component.
if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from archive_replacement import archive_inventory, prepare_archive_replacement
from pack_collection import (Canceled, Packer, PackingError, SEVENZIP_MAGIC,
    SevenZip, atomic_json, canonical, digest_file, process_working_directory, reserve_space,
    temporary_work_directory)

MAX_IMAGE = 16 * 1024 * 1024
MAX_SELECTED_IMAGES = 100000
PROFILES = {'original', 'balanced', 'economy', 'maximum'}
JXL_CONTAINER = b'\0\0\0\x0cJXL \r\n\x87\n'


class ImageComponentRequired(PackingError):
    component = 'JPEGXL'


@dataclass
class PreparedExternalImages:
    source: str
    source_witness: dict
    dependencies: list
    blocked_members: list = field(default_factory=list)
    shared_with_other_archives: list = field(default_factory=list)
    peer_sources: list | None = None
    archives: list = field(default_factory=list)
    supported: bool = True


def _stamp(path):
    stat = path.stat()
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns


def _witness(path, check):
    check()
    before, resolved = _stamp(path), canonical(path)
    value = dict(path=str(path), resolved=resolved, stamp=list(before), sha256=digest_file(path, check))
    if _stamp(path) != before or canonical(path) != resolved:
        raise PackingError('Файл изменился при проверке внешних изображений: ' + str(path))
    return value


def _dependency_paths(source):
    # Match FindSiblingArchive: ZIP has priority, including a 7z named .zip.
    result = {}
    for kind in ('covers', 'images'):
        for suffix in ('.zip', '.7z'):
            path = source.parent / kind / (_stem(source.name) + suffix)
            if path.is_file():
                result[kind] = path
                break
    return result


def _dependencies(source, check):
    return [dict(kind=kind, **_witness(path, check)) for kind, path in _dependency_paths(source).items()]


def _peer_book_archives(source):
    # FLibrary derives both side-archive paths from the outer book archive's
    # basename. An actual 7z can also be distributed with the ZIP suffix.
    for extension in ('.zip', '.7z'):
        peer = source.with_name(_stem(source.name) + extension)
        if peer == source or not peer.is_file():
            continue
        with peer.open('rb') as stream:
            if extension == '.7z' or stream.read(len(SEVENZIP_MAGIC)) == SEVENZIP_MAGIC:
                yield peer


def _stem(name):
    # Delphi ChangeFileExt also removes a leading-dot extension or final dot.
    leaf = posixpath.basename(name.replace('\\', '/'))
    dot = leaf.rfind('.')
    return leaf[:dot] if dot >= 0 else leaf


def _book_id(member):
    return _stem(member).casefold()


def _jpeg_xl(data):
    return data.startswith((b'\xff\x0a', JXL_CONTAINER))


def _decode_jpeg_xl(data, decoder, directory, check, mime):
    if decoder is None or not Path(decoder).is_file():
        raise ImageComponentRequired('Для сжатия отдельных изображений JPEG XL нужен компонент чтения JPEG XL.')
    source = directory / 'input.jxl'
    source.write_bytes(data)
    reserve_space(directory, MAX_IMAGE)
    # First recover the original JPEG. Raw JPEG XL falls back to PNG.
    for extension, extra in (('.jpg', ['--reconstruct_jpeg']), ('.png', [])):
        output = directory / ('decoded' + extension)
        with process_working_directory(directory) as cwd:
            with subprocess.Popen([str(Path(decoder).absolute()), source.name, output.name,
                    '--num_threads=1', *extra], cwd=cwd, stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)) as process:
                started = time.monotonic()
                try:
                    while process.poll() is None:
                        check()
                        if (time.monotonic() - started > 60 or
                                (output.exists() and output.stat().st_size > MAX_IMAGE)):
                            raise PackingError('Декодирование отдельной картинки превысило предел времени или размера.')
                        time.sleep(.025)
                    check()
                    if process.returncode == 0 and output.is_file() and 0 < output.stat().st_size <= MAX_IMAGE:
                        restored = output.read_bytes()
                        if mime(restored):
                            return restored
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
    raise PackingError('Не удалось восстановить отдельную картинку JPEG XL.')


def prepare_external_images(source, members, workspace, seven_zip, *, profile='original',
        grayscale=False, tools_root=None, jpeg_xl_decoder=None, preserve_image=lambda digest: False,
        canceled=lambda: False, notify=lambda event: None, trial_inputs=None):
    """Return independent, verified, smaller side-archive candidates.

    ``members`` names exact selected outer book members and their extensions.
    A shared book basename is blocked unless every referring member is selected.
    Only native publication may change files or acknowledge image history.
    """
    if not isinstance(profile, str) or profile not in PROFILES or not isinstance(grayscale, bool):
        raise PackingError('Неверный режим сжатия внешних изображений.')
    if (not isinstance(members, dict) or not 0 < len(members) <= 100000 or
            any(not isinstance(k, str) or not isinstance(v, str) for k, v in members.items())):
        raise PackingError('Нужен точный список выбранных книг для внешних изображений.')
    source, work = Path(source).absolute(), Path(workspace).absolute()
    if (not source.is_file() or source.is_symlink() or ':' in source.name or not work.is_dir() or work.is_symlink() or
            any(work.iterdir()) or Path(canonical(source)).is_relative_to(Path(canonical(work)))):
        raise PackingError('Нужны исходный архив и пустая отдельная рабочая папка.')

    last_space_check = 0.0
    def check():
        nonlocal last_space_check
        if canceled():
            raise Canceled('Сжатие внешних изображений остановлено. Исходники не изменены.')
        now = time.monotonic()
        if now-last_space_check >= 1:
            reserve_space(work, 0)
            last_space_check = now

    check()
    with source.open('rb') as stream:
        supported = stream.read(len(SEVENZIP_MAGIC)) == SEVENZIP_MAGIC
    source_witness = _witness(source, check) if supported else {}
    result = PreparedExternalImages(str(source), source_witness, [], supported=supported)
    if not supported:
        return result
    def dependencies():
        if trial_inputs is None:
            return _dependencies(source, check)
        return [dict(kind=kind, **_witness(path, check)) for kind, path in trial_inputs.items()]

    result.dependencies = dependencies()
    if any(Path(dep['path']).stat().st_nlink != 1 for dep in result.dependencies):
        raise PackingError('Архив внешних изображений имеет несколько жёстких ссылок; нужен общий план его использования.')
    if any(Path(canonical(dep['path'])).is_relative_to(Path(canonical(work))) for dep in result.dependencies):
        raise PackingError('Архив изображений находится внутри рабочей папки.')

    decoder = SevenZip(seven_zip, check)
    candidates = []
    try:
        with temporary_work_directory(work, '.external-images-') as stage:
            outer = archive_inventory(decoder, source, stage)
            if any(name not in outer or outer[name]['directory'] for name in members):
                raise PackingError('Выбранная книга не найдена по точному имени во внешнем архиве.')
            ids = {_book_id(name) for name in members}
            image_ids = {_book_id(name) for name, hint in members.items()
                         if hint.lower() in ('.fb2', '.epub')}
            shared = ids.intersection(_book_id(name) for name, entry in outer.items()
                                      if not entry['directory'] and name not in members)
            peer_ids = set()
            if result.dependencies and (profile != 'original' or grayscale):
                result.peer_sources = []
                for peer in _peer_book_archives(source):
                    witness = _witness(peer, check)
                    entries = archive_inventory(decoder, peer, stage)
                    peer_ids.update(_book_id(name) for name, entry in entries.items()
                                    if not entry['directory'] and _book_id(name) in ids)
                    result.peer_sources.append(witness)
            blocked = set()
            blocked_by_peer = set()
            quality = None
            engine = ('illustrations-gray-ppmd' if grayscale else
                      'illustrations-ppmd' if profile != 'original' else 'reversible-ppmd')
            processor = Packer(dict(version=1, engine=engine,
                images=profile, output=str(work), plan=str(stage / 'unused.sqlite'), dataset='external-images',
                seven_zip=str(seven_zip), tools_root=str(tools_root) if tools_root else None), notify, canceled)
            if ids - shared - peer_ids and result.dependencies and (profile != 'original' or grayscale):
                processor.load_image_processor()
                quality_path = processor.tools_root / 'bookconvert/image_quality.py'
                spec = importlib.util.spec_from_file_location('homelibre_external_image_quality', quality_path)
                quality = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(quality)

            for dependency in result.dependencies:
                check()
                kind, archive = dependency['kind'], Path(dependency['path'])
                folder = stage / kind
                folder.mkdir()
                inventory = archive_inventory(decoder, archive, folder)
                eligible = ids if kind == 'covers' else image_ids
                chosen, shared_here = [], set()
                for name, entry in inventory.items():
                    owner, separator, _ = name.partition('/')
                    if entry['directory'] or bool(separator) != (kind == 'images'):
                        continue
                    owner = owner.casefold()
                    if owner in eligible:
                        if owner in shared or owner in peer_ids:
                            shared_here.add(owner)
                        else:
                            chosen.append(name)
                if shared_here:
                    affected = {name for name, hint in members.items() if _book_id(name) in shared_here
                                and (kind == 'covers' or hint.lower() in ('.fb2', '.epub'))}
                    blocked.update(affected)
                    blocked_by_peer.update(name for name in affected if _book_id(name) in peer_ids)
                if len(chosen) > MAX_SELECTED_IMAGES:
                    raise PackingError('Слишком много отдельных изображений в выбранной порции.')
                if not chosen:
                    continue
                records, replacements, pending = [], {}, []
                batch_number = 0

                def encode_batch():
                    nonlocal batch_number
                    if not pending:
                        return
                    check()
                    batch_dir = folder / ('encoding-' + str(batch_number))
                    batch_number += 1
                    batch_dir.mkdir()
                    profile_name = 'high' if profile == 'original' else profile
                    try:
                        with process_working_directory(batch_dir) as local_batch:
                            encoded = quality.run(processor.converter,
                                processor.converter.image_processor_path(processor.tools_root),
                                [raster for _, raster, _ in pending], Path(local_batch), profile_name,
                                lambda phase, done, total: notify(dict(stage=phase, kind=kind,
                                    members=[item['member'] for item, _, _ in pending], current=done, total=total)),
                                check=check, grayscale=grayscale)[profile_name]
                        for (item, _, target), data in zip(pending, encoded, strict=True):
                            if grayscale or len(data) < item['input_bytes']:
                                target.write_bytes(data)
                                item.update(proposed_sha256=hashlib.sha256(data).hexdigest(), proposed_bytes=len(data))
                    except Canceled:
                        raise
                    except (PackingError, processor.converter.ConversionError, OSError) as error:
                        for item, _, target in pending:
                            target.write_bytes((target.parent / 'original.bin').read_bytes())
                            item.update(proposed_sha256=item['input_sha256'], proposed_bytes=item['input_bytes'],
                                        checked=False, reason=str(error)[:500])
                    pending.clear()

                for index, name in enumerate(chosen):
                    check()
                    if not 0 < inventory[name]['size'] <= MAX_IMAGE:
                        raise PackingError('Отдельное изображение пусто или превышает 16 МБ: ' + name)
                    image_dir = folder / str(index)
                    image_dir.mkdir()
                    raw = image_dir / 'original.bin'
                    with raw.open('xb') as output:
                        decoder.run(['x', '-so', '-spd', '-ssc', '-y', '--', str(archive), name],
                                    cwd=image_dir, output=output, limit=MAX_IMAGE)
                    if raw.stat().st_size != inventory[name]['size']:
                        raise PackingError('Размер внешней картинки изменился при извлечении: ' + name)
                    original = raw.read_bytes()
                    digest = hashlib.sha256(original).hexdigest()
                    target = image_dir / 'prepared.bin'
                    target.write_bytes(original)
                    replacements[name] = target
                    item = dict(member=name, input_sha256=digest, proposed_sha256=digest,
                        input_bytes=len(original), proposed_bytes=len(original), reused=False,
                        checked=True, reason='', decoded_sha256=None)
                    records.append(item)
                    if quality is not None:
                        if preserve_image(digest):
                            item['reused'] = True
                        else:
                            try:
                                raster = original
                                if _jpeg_xl(raster):
                                    raster = _decode_jpeg_xl(raster, jpeg_xl_decoder, image_dir, check, quality.mime)
                                    item['decoded_sha256'] = hashlib.sha256(raster).hexdigest()
                                if quality.mime(raster):
                                    if len(pending) >= 9 or sum(len(data) for _, data, _ in pending) + len(raster) > 64*1024*1024:
                                        encode_batch()
                                    pending.append((item, raster, target))
                                else:
                                    item['reason'] = 'Формат изображения сохранён без изменения.'
                            except (Canceled, ImageComponentRequired):
                                raise
                            except (PackingError, processor.converter.ConversionError, OSError) as error:
                                item.update(checked=False, reason=str(error)[:500])
                encode_batch()
                archive_work = folder / 'archive'
                archive_work.mkdir()
                prepared = prepare_archive_replacement(archive, replacements, archive_work, seven_zip,
                    canceled=canceled, owned_replacements_root=stage,
                    expected_payload_sha256={item['member']: item['proposed_sha256'] for item in records})
                candidate = None
                if prepared.candidate is not None:
                    candidate = work / ('prepared-' + kind + '.bin')
                    prepared.candidate.rename(candidate)
                    candidates.append(candidate)
                for item in records:
                    item['output_sha256'] = item['proposed_sha256'] if candidate else item['input_sha256']
                    item['output_bytes'] = item['proposed_bytes'] if candidate else item['input_bytes']
                    item['changed'] = item['input_sha256'] != item['output_sha256']
                result.archives.append(dict(kind=kind, source=str(archive), candidate=str(candidate) if candidate else None,
                    source_sha256=prepared.original_sha256, result_sha256=prepared.prepared_sha256,
                    input_bytes=prepared.input_bytes, output_bytes=prepared.output_bytes, images=records))
                notify(dict(stage='external-archive-prepared', kind=kind, candidate=bool(candidate)))
            result.blocked_members = sorted(blocked)
            result.shared_with_other_archives = sorted(blocked_by_peer)
            if result.peer_sources is not None and [
                    _witness(peer, check) for peer in _peer_book_archives(source)] != result.peer_sources:
                raise PackingError('Состав соседнего архива книг изменился во время проверки общих изображений.')
            if _witness(source, check) != source_witness or dependencies() != result.dependencies:
                raise PackingError('Книга или внешние изображения изменились во время подготовки.')
        return result
    except BaseException:
        for candidate in candidates:
            candidate.unlink(missing_ok=True)
        raise


def reader_sources(prepared, *, candidates):
    """Explicit covers/images slots for strict, complete-book validation.

    Empty slots are intentional: the native reader must not discover an
    archive that appeared after preparation. Never substitute a rejected
    proposed image for the bytes actually retained by the archive preparer.
    """
    sources = {item['kind']: item['path'] for item in prepared.dependencies}
    if candidates:
        sources.update({item['kind']: item['candidate'] for item in prepared.archives
                        if item['candidate'] is not None})
    return [sources.get(kind, '') for kind in ('covers', 'images')]


def measure_shared_trial(request, canceled, notify):
    from compression_image_history import CompressedImageHistory
    from prepare_book_compression import profile_digest

    def check():
        if canceled():
            raise Canceled('Пробная упаковка общих архивов остановлена.')

    profile, gray = request['profile'], request['grayscale']
    work = Path(request['workspace'])
    originals = {Path(path) for path in request['shared']}
    if not originals or len(originals) != len(request['shared']):
        raise PackingError('Не совпал список общих архивов для пробной упаковки.')
    witnesses = {path: _witness(path, check) for path in originals}
    current = {path: path for path in originals}
    uses = dict.fromkeys(originals, 0)
    produced = set()
    with CompressedImageHistory(request['catalogue'], profile_digest(profile, gray), check) as history, \
            temporary_work_directory(work, '.selected-') as scratch:
        for group in request['groups']:
            check()
            source = Path(group['source'])
            found = _dependency_paths(source)
            inputs = {}
            for kind, name in group['shared'].items():
                original = Path(name)
                if original not in originals or found.get(kind) != original:
                    raise PackingError('Изменилась привязка общего архива иллюстраций.')
                uses[original] += 1
                inputs[kind] = current[original]
            if group['already_checked'] and all(path == found[kind] for kind, path in inputs.items()):
                continue
            with temporary_work_directory(scratch, 'group-') as folder:
                prepared = prepare_external_images(source, group['members'], folder, request['seven_zip'],
                    profile=profile, grayscale=gray, tools_root=request['tools_root'],
                    jpeg_xl_decoder=request['jpeg_xl_decoder'], trial_inputs=inputs,
                    preserve_image=lambda digest: digest in produced or history.contains(digest),
                    canceled=canceled, notify=notify)
                if not prepared.supported:
                    raise PackingError('Исходный архив больше не содержит книги FLibrary.')
                for entry in prepared.archives:
                    if not entry['candidate']:
                        continue
                    original = found[entry['kind']]
                    if current[original] == original:
                        current[original] = scratch / (hashlib.sha256(str(original).encode('utf-8')).hexdigest() + '.bin')
                    Path(entry['candidate']).replace(current[original])
                    produced.update(item['output_sha256'] for item in entry['images'] if item['changed'] or item['reused'])
        files = []
        for path in originals:
            if uses[path] < 2 or _witness(path, check) != witnesses[path]:
                raise PackingError('Общий архив изменился во время пробной упаковки.')
            files.append(dict(source=str(path), input_bytes=path.stat().st_size, output_bytes=current[path].stat().st_size))
        return dict(files=files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', type=Path, required=True)
    parser.add_argument('--cancel', type=Path)
    parser.add_argument('--shared-trial', action='store_true')
    arguments = parser.parse_args()
    prepared = None

    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)

    def canceled():
        return arguments.cancel is not None and arguments.cancel.exists()

    try:
        if not 0 < arguments.job.stat().st_size <= (128 if arguments.shared_trial else 16) * 1024 * 1024:
            raise PackingError('Неверный размер задания внешних изображений.')
        request = json.loads(arguments.job.read_text(encoding='utf-8-sig'))
        if arguments.shared_trial:
            if request.get('version') != 1 or request.get('kind') != 'HomeLibre shared archive trial':
                raise PackingError('Неизвестное задание пробной упаковки.')
            result = measure_shared_trial(request, canceled, emit)
            atomic_json(request['report'], result, replace=False)
            return 0
        if (not isinstance(request, dict) or type(request.get('version')) is not int or
                request['version'] != 1 or request.get('kind') != 'HomeLibre external image preparation'):
            raise PackingError('Неизвестное задание внешних изображений.')
        prepared = prepare_external_images(request['source'], request['members'], request['workspace'],
            request['seven_zip'], profile=request.get('profile', 'original'),
            grayscale=request.get('grayscale', False), tools_root=request.get('tools_root'),
            jpeg_xl_decoder=request.get('jpeg_xl_decoder'), canceled=canceled, notify=emit)
        if canceled():
            raise Canceled('Сжатие внешних изображений остановлено. Исходники не изменены.')
        result = dict(version=1, kind='HomeLibre external image preparation',
            **asdict(prepared), members=request['members'],
            original_image_sources=reader_sources(prepared, candidates=False),
            prepared_image_sources=reader_sources(prepared, candidates=True))
        # This is preparation evidence, deliberately not a publication receipt.
        # The native caller must restore/validate complete selected books and
        # durably bind every dependency before applying any candidate.
        atomic_json(request['report'], result, replace=False)
        emit(dict(stage='ready', candidates=sum(item['candidate'] is not None for item in prepared.archives)))
        return 0
    except Canceled as error:
        emit(dict(stage='cancelled', message=str(error)))
        status = 2
    except (PackingError, OSError, ValueError, KeyError, TypeError) as error:
        event = dict(stage='error', message=str(error))
        if isinstance(error, ImageComponentRequired):
            event['component'] = error.component
        emit(event)
        status = 1
    if prepared is not None:
        for item in prepared.archives:
            if item['candidate'] is not None:
                Path(item['candidate']).unlink(missing_ok=True)
    return status


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
