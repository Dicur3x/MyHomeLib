"""Optional FB2 and EPUB export writers. All tool input and output are private."""

import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time


OUTPUT_SUFFIXES = {
    'epub2': '.epub',
    'epub3': '.epub',
    'kepub': '.kepub.epub',
    'kfx': '.kfx',
    'azw8': '.azw8',
    'pdf': '.pdf',
    'md': '.md',
}


def run_writer(api, command, work, check, timeout=300):
    log_path = work / 'writer.log'
    with log_path.open('wb') as log:
        process = subprocess.Popen(command, cwd=work, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if check is not None:
                    check()
                if time.monotonic() >= deadline:
                    limit = 'пять минут' if timeout == 300 else f'{timeout} с'
                    raise api.ConversionError('Модуль сохранения не завершил работу за ' + limit + '.')
                if log_path.stat().st_size > 1024 * 1024:
                    raise api.ConversionError('Слишком большой журнал модуля сохранения.')
                time.sleep(.05)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    if process.returncode:
        with log_path.open('rb') as log:
            log.seek(max(0, log_path.stat().st_size - 2500))
            detail = log.read(2500).decode('utf-8', 'replace').strip()
        raise api.ConversionError('Модуль не смог сохранить книгу.' + (' ' + detail if detail else ''))


def validate_output(api, output, profile):
    if not output.is_file() or not 0 < output.stat().st_size <= api.MAX_TOTAL:
        raise api.ConversionError('Модуль не создал книгу допустимого размера.')
    if profile in ('epub2', 'epub3', 'kepub'):
        versions = api.validate_epub_output(output)
        if (profile == 'kepub' and (not versions or not versions <= {'2', '3'})) or (
                profile != 'kepub' and versions != {profile[-1]}):
            raise api.ConversionError('Версия EPUB не совпадает с выбранным форматом.')
        return
    with output.open('rb') as stream:
        if profile == 'pdf':
            head = stream.read(16)
            stream.seek(max(0, output.stat().st_size - 1024))
            if not head.startswith(b'%PDF-') or not stream.read().rstrip().endswith(b'%%EOF'):
                raise api.ConversionError('Модуль создал повреждённый PDF.')
        elif profile in ('kfx', 'azw8'):
            head = stream.read(18)
            error = 'Модуль создал повреждённую книгу Kindle.'
            if len(head) != 18 or not head.startswith(b'CONT'):
                raise api.ConversionError(error)
            header_size, info_offset, info_size = struct.unpack_from('<III', head, 6)
            # Standalone KFX stores the descriptor inside the header,
            # followed by the entity data.
            if not (len(head) <= info_offset and 4 <= info_size
                    and info_offset + info_size <= header_size < output.stat().st_size):
                raise api.ConversionError(error)
            stream.seek(info_offset)
            if stream.read(4) != b'\xe0\x01\x00\xea':
                raise api.ConversionError(error)
            stream.seek(header_size)
            if stream.read(4) != b'ENTY':
                raise api.ConversionError(error)
    if profile == 'md' and not output.read_text(encoding='utf-8-sig').strip():
        raise api.ConversionError('Модуль создал пустой Markdown.')


def canonical_fb2(api, path):
    # fb2cng identifies a FictionBook by its unprefixed root. The shared
    # image editor can write the same namespace with an explicit prefix.
    book = api.xml(path.read_bytes(), api.MAX_TOTAL)
    api.ET.register_namespace('', api.FB)
    api.ET.register_namespace('l', api.XL)
    api.ET.ElementTree(book).write(path, encoding='utf-8', xml_declaration=True)


def convert(api, source, destination, source_extension, profile, options):
    suffix = OUTPUT_SUFFIXES.get(profile)
    if suffix is None or not destination.name.lower().endswith(suffix):
        raise api.ConversionError('Имя файла не соответствует выбранному формату.')
    if source_extension != '.fb2' and (
            profile not in ('epub2', 'epub3', 'kepub', 'pdf', 'md', 'kfx', 'azw8') or source_extension not in api.BOOK_EPUB_INPUTS or
            (profile == 'pdf' and source_extension == '.pdf')):
        raise api.ConversionError('Выбранный формат недоступен для исходного файла ' +
                                  source_extension.lstrip('.').upper() + '.')
    quality = options['image_quality']
    if quality == 'ask':
        raise api.ConversionError('Перед сохранением выберите режим изображений.')
    if quality == 'none' and profile in ('kfx', 'azw8'):
        raise api.ConversionError('Для KFX и AZW8 нужна обложка. Выберите режим с изображениями.')
    tools = Path(options.get('tools_root') or Path(__file__).resolve().parent.parent).resolve()
    epub_pdf = source_extension != '.fb2' and profile == 'pdf'
    epub_kobo = source_extension != '.fb2' and profile == 'kepub'
    epub_markdown = source_extension != '.fb2' and profile == 'md'
    epub_version = source_extension != '.fb2' and profile in ('epub2', 'epub3')
    epub_kfx = source_extension != '.fb2' and profile in ('kfx', 'azw8')
    if epub_version:
        writer = Path(__file__).with_name(profile + '_output.py')
        component, name = 'BookProcessing', 'сохранения в EPUB ' + profile[-1]
    elif epub_markdown:
        writer = Path(__file__).with_name('markdown_output.py')
        component, name = 'BookProcessing', 'записи EPUB в Markdown'
    elif epub_pdf:
        component, relative, name = 'EpubPdfExport', 'epub-pdf/epub_pdf_output.py', 'вёрстки EPUB в PDF'
    elif epub_kobo:
        component, relative, name = 'KoboExport', 'kobo-export/kepubify.exe', 'kepubify'
    elif epub_kfx:
        component, relative, name = 'KfxExport', 'kfx-export/boko.exe', 'сохранения EPUB в KFX и AZW8'
    else:
        component, relative, name = 'FB2Export', 'fb2-export/fbc.exe', 'fb2cng'
    if not (epub_markdown or epub_version):
        writer = tools / relative
    if not writer.is_file():
        raise api.ComponentRequired(component, 'Для выбранного формата сохранения нужен модуль ' + name + '.')

    progress = options.get('progress') or (lambda *_: None)
    check = options.get('cancel_check')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='homelibre-advanced-', dir=destination.parent) as folder:
        work = Path(folder)
        prepared = work / ('source.epub' if source_extension != '.fb2' else 'source.fb2')
        output = work / ('book' + suffix)
        preparation = api.convert_book(source, prepared, **options)
        warnings = set(preparation.get('warnings', ()))
        progress('advanced-writing', 0, 1)
        if epub_pdf or epub_markdown or epub_version:
            spec = importlib.util.spec_from_file_location('homelibre_epub_writer', writer)
            engine = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(engine)
            if epub_pdf:
                engine.convert(api, prepared, output, writer.parent, check)
            else:
                engine.convert(api, prepared, output, warnings, check)
        elif epub_kobo:
            command = [str(writer), '--no-add-dummy-titlepage', '--output', str(output), str(prepared)]
            run_writer(api, command, work, check)
        elif epub_kfx:
            # The embedded Windows Python excludes the script directory.
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            try:
                from epub_kfx_output import convert as convert_kfx
                convert_kfx(api, prepared, output, writer, tools, warnings, check, run_writer)
            finally:
                sys.path.pop(0)
        else:
            canonical_fb2(api, prepared)
            command = [str(writer)]
            if profile == 'md' and quality != 'none':
                config = work / 'markdown.yaml'
                config.write_text('document:\n  images:\n    markdown: embedded\n', encoding='utf-8')
                command += ['--config', str(config)]
            target = 'kepub3' if profile == 'kepub' else profile
            command += ['convert', '--to', target, '--output-file', str(output)]
            if quality == 'none' and profile in ('epub2', 'epub3', 'kepub', 'pdf'):
                command.append('--no-cover')
            command.append(str(prepared))
            run_writer(api, command, work, check)
        validate_output(api, output, profile)
        if check is not None:
            check()
        with output.open('r+b') as stream:
            os.fsync(stream.fileno())
        if os.name == 'nt':
            os.rename(output, destination)
        else:
            os.link(output, destination)
            output.unlink()
        progress('advanced-writing', 1, 1)
    return dict(output=str(destination), warnings=sorted(warnings), size=destination.stat().st_size)
