"""Read-only size measurement for selected books; never prepares an archive.

Book payload sizes and physical archive sizes deliberately remain separate.
The image sampler is shared with Save As. A sample is not a guaranteed bound
on the size of a rewritten solid archive.
"""
import argparse
import importlib.util
import json
import math
import mmap
from pathlib import Path
import sys
import time

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from archive_replacement import archive_inventory, member_path
from pack_collection import (Canceled, DJVU_LIMIT, DJVU_MIN_SAVINGS, DJVU_SUFFIXES, IMAGE_SUFFIXES, MAX_BOOK, MAX_IMAGE_BOOK,
    Packer, PackingError, SevenZip, atomic_json, canonical, copy_exact, digest_file,
    djvu_refinements, reserve_space, temporary_work_directory)
from prepare_book_compression import MAX_MEMBERS, _source_stamp, profile_digest
from compression_image_history import CompressedImageHistory


class MeasurementBudget(Exception):
    pass


def measure_book(processor, book, extension, grayscale, check, image_history=None):
    """Use the export sampler, stopping before any book rewrite or full encode."""
    spec = importlib.util.spec_from_file_location('homelibre_compression_measurement',
        processor.tools_root / 'bookconvert/image_quality.py')
    quality = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(quality)
    measured = []
    quality.apply(processor.converter, book, extension, 'ask', processor.tools_root,
        lambda *_: check(), container='fb2-zip' if extension == '.fb2' else None,
        check=check, grayscale=grayscale, measurement=measured.append,
        preserve_image=image_history)
    check()
    if not measured:
        return dict(output_bytes=book.stat().st_size, sampled=0, images=0, exact=True)
    result = measured[0]
    profile = 'original' if processor.images == 'original' else processor.images
    # The preparer retains the original whenever its transformed book is larger.
    return dict(output_bytes=min(book.stat().st_size, result['sizes'][profile]),
        sampled=result['sampled'], images=result['images'], exact=result.get('exact',False),
        images_reused=result.get('preserved',0))


def estimate_selected_file(source, members, workspace, seven_zip, *, profile='balanced',
        grayscale=False, tools_root=None, previous=None, book_seconds=10,
        image_history_database=None,
        canceled=lambda: False, notify=lambda value: None):
    settings_sha = profile_digest(profile, grayscale)
    if (isinstance(book_seconds, bool) or not isinstance(book_seconds, (int, float))
            or not math.isfinite(book_seconds) or not 0 < book_seconds <= 10):
        raise PackingError('На оценку одной книги можно выделить до 10 секунд.')
    if (not isinstance(members, dict) or not 0 < len(members) <= MAX_MEMBERS
            or any(not isinstance(k, str) or not isinstance(v, str) for k, v in members.items())
            or ('' in members and len(members) != 1)):
        raise PackingError('Нужен точный список выбранных книг одного файла.')
    source, workspace = Path(source).absolute(), Path(workspace).absolute()
    if (not source.is_file() or source.is_symlink() or not workspace.is_dir()
            or workspace.is_symlink() or any(workspace.iterdir())):
        raise PackingError('Нужны исходный файл и пустая рабочая папка оценки.')
    before = _source_stamp(source)
    deadline = None

    def check():
        if canceled():
            raise Canceled('Оценка остановлена. Исходные книги не изменены.')
        if deadline is not None and time.monotonic() >= deadline:
            raise MeasurementBudget('Не удалось получить оценку за отведённое время.')

    check()
    engine = ('illustrations-gray-ppmd' if grayscale else 'illustrations-ppmd') if profile != 'original' or grayscale else 'reversible-ppmd'
    processor = Packer(dict(version=1, engine=engine,
        images=profile, seven_zip=str(seven_zip), output=str(workspace), plan=str(workspace/'unused.sqlite'),
        dataset='selected-estimate', tools_root=str(tools_root) if tools_root else None), notify, canceled)
    processor.check = check
    if profile != 'original' or grayscale:
        processor.load_image_processor()
        if image_history_database and getattr(processor.converter,'PACKING_IMAGE_API',0)<3:
            raise PackingError('Для оценки досжатия обновите HomeLibre BookProcessing.')
    measurement_errors = (MeasurementBudget, PackingError, ValueError, OSError)
    if processor.converter is not None:
        measurement_errors += (processor.converter.ConversionError,)
    decoder = SevenZip(seven_zip, check)
    result = dict(schema=1, source=str(source), archive_bytes=before[2], books=[],
        size_basis='selected-book-payloads', archive_output_bytes=None,
        note='Размеры выбранных книг до внешней упаковки. Экономия на диске зависит от общего архива.')
    with CompressedImageHistory(image_history_database if processor.converter is not None else None, settings_sha, check) as image_history, \
            temporary_work_directory(workspace, '.estimate-') as staging:
        legacy = image_history.legacy_books(source, members, profile, grayscale) if not all(
            member in (previous or {}) for member in members) else {}
        if '' in members:
            sizes = {'': before[2]}
        else:
            inventory = archive_inventory(decoder, source, staging)
            sizes = {}
            for member in members:
                member_path(staging/'names', member)
                if member not in inventory or inventory[member]['directory']:
                    raise PackingError('Не найден точный файл выбранной книги: '+member)
                sizes[member] = inventory[member]['size']
        for number, (member, hint) in enumerate(members.items()):
            check()
            row = dict(member=member, input_bytes=sizes[member], output_bytes=None,
                exact=False, sampled=0, images=0, reason='')
            result['books'].append(row)
            if not 0 < sizes[member] <= MAX_BOOK:
                row['reason'] = 'Файл книги пуст или превышает предел обработки 512 МБ.'
                continue
            started = time.monotonic()
            deadline = started + book_seconds
            notify(dict(stage='Оцениваем выбранную книгу', member=member, current=number, total=len(members)))
            try:
                if processor.converter is None:
                    row.update(output_bytes=sizes[member], exact=True,
                        reason='Содержимое не меняется; экономия возможна за счёт упаковки.')
                    continue
                with temporary_work_directory(staging, 'book-') as book_dir:
                    reserve_space(book_dir, min(sizes[member], MAX_BOOK)*3+16*1024*1024)
                    book = book_dir/'input.bin'
                    if member:
                        decoder.extract(source, member, book, book_dir)
                    else:
                        copy_exact(source, book, check)
                    check()
                    if book.stat().st_size != sizes[member]:
                        raise PackingError('Размер исходной книги изменился во время оценки.')
                    extension = processor.converter.detect_input(book)
                    old = (previous or {}).get(member, legacy.get(member, {}))
                    if (old.get('profile_sha256') == settings_sha and
                            old.get('output_sha256') == digest_file(book, check) and
                            not old.get('retry_original', False)):
                        row.update(output_bytes=sizes[member], exact=True,
                            reason='Уже сжата с этими настройками; изображения повторно не обрабатываются.')
                    elif extension in IMAGE_SUFFIXES and sizes[member] <= MAX_IMAGE_BOOK:
                        row.update(measure_book(processor, book, extension, grayscale, check,
                            image_history.contains if image_history_database else None))
                        if row.get('images_reused'):
                            row['reason'] = f"Уже сжатые изображения сохраняются без изменений: {row['images_reused']}. Оцениваем только новые."
                    elif extension in DJVU_SUFFIXES and profile == 'maximum':
                        # The background optimization preserves all offsets and
                        # the payload length. Only the outer archive can shrink.
                        reason = ('Размер DjVu до упаковки сохраняется. Экономия возможна в архиве.'
                                  if member else 'Размер отдельного файла DjVu остаётся прежним.')
                        if member and book.stat().st_size <= DJVU_LIMIT:
                            try:
                                with book.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                                    ranges = djvu_refinements(data, check)
                            except MeasurementBudget:
                                reason += ' Фон страниц не удалось проверить за отведённое время.'
                            else:
                                eligible = sum(end - start for _, start, end in ranges) >= DJVU_MIN_SAVINGS
                                row['djvu_background_pages'] = len(ranges) if eligible else 0
                                reason += (f' Страниц с подходящим фоном: {len(ranges)}.' if eligible else
                                           ' Подходящего фона для уменьшения не найдено.')
                        row.update(output_bytes=sizes[member], exact=True, reason=reason)
                    else:
                        row.update(output_bytes=sizes[member], exact=True,
                            reason='Содержимое этого формата не меняется; возможна только перепаковка.')
            except Canceled:
                raise
            except measurement_errors as error:
                row.update(output_bytes=None, exact=False, reason=str(error)[:500])
            finally:
                deadline = None
                row['seconds'] = round(time.monotonic()-started, 3)
            check()
    if _source_stamp(source) != before:
        raise PackingError('Исходный файл изменился во время оценки. Повторите расчёт.')
    result['input_bytes'] = sum(row['input_bytes'] for row in result['books'])
    known = [row for row in result['books'] if row['output_bytes'] is not None]
    result['known_input_bytes'] = sum(row['input_bytes'] for row in known)
    result['known_output_bytes'] = sum(row['output_bytes'] for row in known)
    result['unknown_books'] = len(result['books'])-len(known)
    result['output_bytes'] = result['known_output_bytes'] if not result['unknown_books'] else None
    return result


def aggregate_estimates(reports):
    sources, books = set(), []
    archive_bytes = 0
    for report in reports:
        source = canonical(report['source'])
        if source in sources:
            raise PackingError('Один архив включён в общую оценку дважды.')
        sources.add(source)
        if report.get('size_basis') != 'selected-book-payloads':
            raise PackingError('Нельзя складывать размеры книг и размеры архивов.')
        archive_bytes += report['archive_bytes']
        books.extend(report['books'])
    known = [row for row in books if row['output_bytes'] is not None]
    unknown = len(books)-len(known)
    return dict(schema=1, size_basis='selected-book-payloads', files=len(sources), books=len(books),
        archive_bytes=archive_bytes, input_bytes=sum(row['input_bytes'] for row in books),
        known_input_bytes=sum(row['input_bytes'] for row in known),
        known_output_bytes=sum(row['output_bytes'] for row in known), unknown_books=unknown,
        output_bytes=None if unknown else sum(row['output_bytes'] for row in known),
        archive_output_bytes=None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', type=Path, required=True)
    parser.add_argument('--cancel', type=Path)
    arguments = parser.parse_args()
    emit = lambda event: print(json.dumps(event, ensure_ascii=False), flush=True)
    try:
        if arguments.job.stat().st_size > 16*1024*1024:
            raise PackingError('Слишком большой список выбранных книг.')
        request = json.loads(arguments.job.read_text(encoding='utf-8-sig'))
        if not isinstance(request, dict) or request.get('version') != 1:
            raise PackingError('Неизвестная версия задания оценки.')
        template = request.get('receipt_template') or {}
        if not isinstance(template,dict):
            raise PackingError('Некорректное описание каталога сжатия.')
        result = estimate_selected_file(request['source'], request['members'], request['workspace'], request['seven_zip'],
            profile=request.get('profile', 'balanced'), grayscale=request.get('grayscale', False),
            tools_root=request.get('tools_root'), previous=request.get('previous'),
            book_seconds=request.get('book_seconds', 10),
            image_history_database=template.get('catalogue'),
            canceled=lambda: arguments.cancel is not None and arguments.cancel.exists(), notify=emit)
        atomic_json(request['report'], result, replace=False)
        emit(dict(stage='ready', unknown_books=result['unknown_books']))
        return 0
    except Canceled as error:
        emit(dict(stage='cancelled', message=str(error)))
        return 2
    except (PackingError, OSError, ValueError, KeyError, TypeError) as error:
        emit(dict(stage='error', message=str(error)))
        return 1


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
