"""Optimize embedded resources of an FLibrary EPUB stored as a 7z stream.

External images remain external. The native owner still reconstructs and checks
the complete before/after EPUB before publishing any book or image archive.
"""
import hashlib
from pathlib import Path
import tempfile
import zipfile
import zlib

from archive_replacement import archive_inventory, prepare_archive_replacement
from pack_collection import (BLOCK, MAX_IMAGE_BOOK, PackingError, digest_file,
                             reserve_space)


def is_nested_epub(source, work, decoder):
    """Recognize the bounded EPUB resource root before generic byte sniffing.

    Stored 7z streams can contain literal HTML/XML; those bytes do not make
    their enclosing FLibrary EPUB an HTML book. No member is extracted here.
    """
    entries = archive_inventory(decoder, source, work)
    files = [(name, item) for name, item in entries.items() if not item['directory']]
    if not 0 < len(files) <= 20000 or sum(item['size'] for _, item in files) > MAX_IMAGE_BOOK:
        return False
    tops = {name.split('/', 1)[0] if '/' in name else '' for name, _ in files
            if not name.lower().endswith('flibraryimageindex.json')}
    prefix = next(iter(tops))+'/' if len(tops)==1 and '' not in tops else ''
    names = {name.removeprefix(prefix) for name, _ in files}
    return len(names) == len(files) and 'META-INF/container.xml' in names


def optimize_nested_epub(source, stage, processor, decoder, history, verify, check):
    work = stage/'nested-epub'
    work.mkdir()
    entries = archive_inventory(decoder, source, work)
    files = [(name, item) for name, item in entries.items() if not item['directory']]
    total = sum(item['size'] for _, item in files)
    if not 0 < len(files) <= 20000 or total > MAX_IMAGE_BOOK:
        raise PackingError('Вложенная EPUB слишком велика для обработки иллюстраций.')
    reserve_space(work, 4*total+source.stat().st_size)
    materialized = []
    # -so creates no filesystem paths from archive names. The per-member CRC
    # confirms stream order; unfamiliar/missing CRCs use exact-name reads.
    with tempfile.TemporaryFile(dir=work) as batch:
        ordered = all(isinstance(item.get('crc'), str) and len(item['crc']) == 8 for _, item in files)
        if ordered:
            decoder.run(['x','-so','-y','--',str(source)], cwd=work, output=batch, limit=total)
            ordered = batch.tell() == total
            batch.seek(0)
        for number, (name, item) in enumerate(files):
            check()
            target = work/(str(number)+'.bin')
            crc = 0
            if ordered:
                with target.open('xb') as out:
                    remaining = item['size']
                    while remaining:
                        check()
                        data = batch.read(min(BLOCK, remaining))
                        if not data:
                            raise PackingError('Неполный поток ресурсов вложенной EPUB.')
                        out.write(data)
                        remaining -= len(data)
                        crc = zlib.crc32(data, crc)
                if f'{crc:08X}' != item['crc'].upper():
                    ordered = False
            if not ordered:
                # A different archive order cannot associate another image
                # or font with the current filename.
                with target.open('wb') as out:
                    decoder.run(['x','-so','-spd','-ssc','-y','--',str(source),name],
                                cwd=work, output=out, limit=item['size'])
            if target.stat().st_size != item['size']:
                raise PackingError('Изменился размер ресурса вложенной EPUB: '+name)
            materialized.append((name, target, digest_file(target, check)))
    image_suffixes = {'.png','.jpg','.jpeg','.gif','.webp','.bmp','.tif','.tiff'}
    if not any(Path(name).suffix.lower() in image_suffixes and path.stat().st_size
               for name, path, _ in materialized):
        return dict(image_result='unchanged', nested_epub_verified=True,
                    image_reason='Вложенная упаковка EPUB сохранена; отдельные картинки обрабатываются вместе с книгой.')
    tops = {name.split('/',1)[0] if '/' in name else '' for name, _, _ in materialized
            if not name.lower().endswith('flibraryimageindex.json')}
    prefix = next(iter(tops))+'/' if len(tops)==1 and '' not in tops else ''
    names = {name.removeprefix(prefix): (name,path,digest) for name,path,digest in materialized}
    if len(names) != len(materialized) or 'META-INF/container.xml' not in names:
        raise PackingError('Не найден корень вложенной EPUB.')
    original_zip, current_zip = work/'original.epub', work/'current.epub'
    for target in (original_zip, current_zip):
        with zipfile.ZipFile(target, 'x', zipfile.ZIP_STORED) as archive:
            if 'mimetype' in names:
                archive.write(names['mimetype'][1], 'mimetype')
            for name, (_, path, _) in names.items():
                if name != 'mimetype':
                    archive.write(path, name)
    status = processor.optimize_book(current_zip, work,
                                    image_history=history, collect_image_history=True)
    if status.get('image_result') == 'skipped':
        raise PackingError(status.get('image_reason') or 'Не обработаны картинки вложенной EPUB.')
    verify(original_zip, current_zip, '.epub')
    replacements, hashes = {}, {}
    with zipfile.ZipFile(current_zip) as archive:
        if set(archive.namelist()) != set(names):
            raise PackingError('Обработка изменила список ресурсов вложенной EPUB.')
        for number, (name, (original_name, _, old_hash)) in enumerate(names.items()):
            check()
            output = work/('updated-'+str(number)+'.bin')
            digest = hashlib.sha256()
            with archive.open(name) as entry, output.open('xb') as out:
                while data := entry.read(BLOCK):
                    check()
                    digest.update(data)
                    out.write(data)
            if digest.hexdigest() != old_hash:
                replacements[original_name] = output
                hashes[original_name] = digest.hexdigest()
            else:
                output.unlink()
    if not replacements:
        return dict(status, image_result='unchanged', nested_epub_verified=True)
    destination = work/'archive'
    destination.mkdir()
    prepared = prepare_archive_replacement(source, replacements, destination, decoder.executable,
        method='LZMA2', canceled=lambda: processor.canceled(),
        owned_replacements_root=work, expected_payload_sha256=hashes)
    if prepared.candidate is None:
        return dict(image_result='unchanged', nested_epub_verified=True,
                    image_reason='Вложенная EPUB не стала меньше; исходные ресурсы сохранены.')
    prepared.candidate.replace(source)
    return dict(status, image_result='optimized', nested_epub_verified=True)
