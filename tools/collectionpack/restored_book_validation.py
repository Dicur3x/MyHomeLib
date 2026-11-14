"""Validate complete native-restored books before publishing external images.

The native owner materializes the exact before/after book streams into its
private full-books folder. This worker checks semantics, measures complete
books, and optionally prepares self-contained originals and image comparison.
It never publishes an archive or updates a catalogue.
"""
from contextlib import nullcontext
import argparse
import hashlib
import json
from pathlib import Path
import sys

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from pack_collection import Canceled, PackingError, atomic_json, canonical, digest_file
from prepare_book_compression import OriginalBookBackup, _source_stamp, verify_non_image_content
from compression_preview import ComparisonPreview

MAX_BOOK = 512 * 1024 * 1024


def validate_restored_books(request, *, canceled=lambda: False, notify=lambda value: None):
    def check():
        if canceled():
            raise Canceled('Проверка полной книги остановлена. Исходные архивы не изменены.')

    if (not isinstance(request, dict) or type(request.get('version')) is not int or
            request['version'] != 1 or request.get('kind') != 'HomeLibre restored book validation'):
        raise PackingError('Неизвестное задание проверки полной книги.')
    source, work = Path(request['source']).absolute(), Path(request['workspace']).absolute()
    snapshot = work/'full-books'
    books = request.get('books')
    if (not work.is_dir() or work.is_symlink() or not snapshot.is_dir() or snapshot.is_symlink() or
            not isinstance(books, list) or not 0 < len(books) <= 100000 or
            type(request.get('backup_originals', False)) is not bool or
            type(request.get('preview_images', False)) is not bool):
        raise PackingError('Нужны проверочные копии выбранных полных книг.')
    expected_source = request['source_sha256']
    before = _source_stamp(source)
    if digest_file(source, check) != expected_source:
        raise PackingError('Архив книг изменился перед полной проверкой.')
    originals = (OriginalBookBackup(work, source, expected_source, before, check)
                 if request.get('backup_originals') else None)
    preview = ComparisonPreview(work, check) if request.get('preview_images') else None
    result = dict(version=1, kind='HomeLibre restored book validation', source=str(source),
                  source_sha256=expected_source, restored_payloads=[], originals=None, preview=None)
    names, paths = set(), set()
    with originals if originals is not None else nullcontext(), preview if preview is not None else nullcontext():
        for index, book in enumerate(books):
            check()
            if (not isinstance(book, dict) or not isinstance(book.get('member'), str) or
                    book['member'] in names or type(book.get('raw_changed')) is not bool):
                raise PackingError('Неверный или повторяющийся файл полной книги.')
            names.add(book['member'])
            verified = []
            for key in ('before', 'after'):
                path = Path(book[key]).absolute()
                resolved = canonical(path)
                if (not path.is_file() or path.is_symlink() or resolved in paths or
                        not Path(resolved).is_relative_to(Path(canonical(snapshot))) or
                        not 0 < path.stat().st_size <= MAX_BOOK):
                    raise PackingError('Проверочная книга находится вне своей папки или слишком велика.')
                paths.add(resolved)
                stamp, digest = _source_stamp(path), digest_file(path, check)
                if digest != book[key+'_sha256'] or _source_stamp(path) != stamp:
                    raise PackingError('Проверочная копия полной книги изменилась.')
                verified.append((path, stamp, digest))
            old, new = verified
            extension = book['format'].lower()
            if extension in ('.fb2', '.epub'):
                verify_non_image_content(old[0], new[0], extension)
            elif not book['raw_changed'] and old[2] != new[2]:
                raise PackingError('Внешние картинки изменили содержимое книги другого формата.')
            result['restored_payloads'].append(dict(member=book['member'], input_sha256=old[2],
                output_sha256=new[2], input_size=old[1][2], size=new[1][2]))
            if originals is not None:
                originals.add(old[0], book['member'], dict(payload_sha256=old[2], payload_size=old[1][2]))
            if preview is not None:
                preview.add_book(old[0], new[0], extension, book['member'])
            if any(_source_stamp(path) != stamp for path, stamp, _ in verified):
                raise PackingError('Полная книга изменилась во время проверки.')
            notify(dict(stage='Проверяем полные книги с иллюстрациями', current=index+1, total=len(books)))
        if _source_stamp(source) != before or digest_file(source, check) != expected_source:
            raise PackingError('Исходный архив изменился во время полной проверки.')
        check()
        if originals is not None:
            result['originals'] = originals.finish(result['restored_payloads'])
        if preview is not None:
            result['preview'] = preview.finish()
        check()
        if originals is not None:
            originals.keep = True
        if preview is not None:
            preview.keep = result['preview'] is not None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', type=Path, required=True)
    parser.add_argument('--cancel', type=Path)
    args = parser.parse_args()
    result = None

    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)

    try:
        if not 0 < args.job.stat().st_size <= 32*1024*1024:
            raise PackingError('Неверный размер задания полной проверки.')
        request = json.loads(args.job.read_text('utf-8-sig'))
        result = validate_restored_books(request, canceled=lambda: args.cancel is not None and args.cancel.exists(), notify=emit)
        atomic_json(request['report'], result, replace=False)
        emit(dict(stage='ready', books=len(result['restored_payloads'])))
        return 0
    except Canceled as error:
        emit(dict(stage='cancelled', message=str(error)))
        status = 2
    except (PackingError, OSError, ValueError, KeyError, TypeError) as error:
        emit(dict(stage='error', message=str(error)))
        status = 1
    if result is not None:
        for key in ('originals', 'preview'):
            if result.get(key):
                Path(result[key]['path']).unlink(missing_ok=True)
    return status


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(main())
