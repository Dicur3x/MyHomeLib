"""Optional FB2 and EPUB export writers. All tool input and output are private."""

import os
from pathlib import Path
import subprocess
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


def run_writer(api, command, work, check):
    log_path = work / 'writer.log'
    with log_path.open('wb') as log:
        process = subprocess.Popen(command, cwd=work, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deadline = time.monotonic() + 300
        try:
            while process.poll() is None:
                if check is not None:
                    check()
                if time.monotonic() >= deadline:
                    raise api.ConversionError('Модуль сохранения не завершил работу за пять минут.')
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
        head = stream.read(16)
        if profile == 'pdf':
            stream.seek(max(0, output.stat().st_size - 1024))
            if not head.startswith(b'%PDF-') or not stream.read().rstrip().endswith(b'%%EOF'):
                raise api.ConversionError('Модуль создал повреждённый PDF.')
        elif profile in ('kfx', 'azw8') and (len(head) != 16 or not head.startswith(b'CONT')):
            raise api.ConversionError('Модуль создал повреждённую книгу Kindle.')
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
    if source_extension != '.fb2' and not (source_extension == '.epub' and profile == 'kepub'):
        raise api.ConversionError('Этот вариант сохранения доступен для FB2. Для EPUB доступен прямой экспорт в KEPUB.')
    quality = options['image_quality']
    if quality == 'ask':
        raise api.ConversionError('Перед сохранением выберите режим изображений.')
    if quality == 'none' and profile in ('kfx', 'azw8'):
        raise api.ConversionError('Для KFX и AZW8 нужна обложка. Выберите режим с изображениями.')
    tools = Path(options.get('tools_root') or Path(__file__).resolve().parent.parent).resolve()
    direct_kobo = source_extension == '.epub'
    component, relative, name = ('KoboExport', 'kobo-export/kepubify.exe', 'kepubify') if direct_kobo else (
        'FB2Export', 'fb2-export/fbc.exe', 'fb2cng')
    writer = tools / relative
    if not writer.is_file():
        raise api.ComponentRequired(component, 'Для выбранного формата сохранения нужен модуль ' + name + '.')

    progress = options.get('progress') or (lambda *_: None)
    check = options.get('cancel_check')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='homelibre-advanced-', dir=destination.parent) as folder:
        work = Path(folder)
        prepared = work / ('source' + source_extension)
        output = work / ('book' + suffix)
        preparation = api.convert_book(source, prepared, **options)
        warnings = set(preparation.get('warnings', ()))
        if direct_kobo:
            command = [str(writer), '--no-add-dummy-titlepage', '--output', str(output), str(prepared)]
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
        progress('advanced-writing', 0, 1)
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
