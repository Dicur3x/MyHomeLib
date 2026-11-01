"""Optional MOBI7/KF8 and AZW3 writer, powered by the native Kindling tool.

The shared converter prepares EPUB; this independently packaged module owns
only Kindle output. Sources remain read-only and publication never overwrites.
"""
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile


def canonical_input(api, source, destination):
    """Adapt a private copy, keeping images, CSS and standard book metadata.

    Kindling removes root namespace declarations from its KF8 skeleton, so
    normalize XHTML to its default namespace first. Our FB2 restoration hints
    describe pre-Kindle resource names and must not survive that transformation.
    """
    archive = api.EpubArchive(source)
    namespaces = ET._namespace_map.copy()
    try:
        container = api.xml(archive.read('META-INF/container.xml'))
        documents, packages = set(), {}
        cover_declared = False
        for rootfile in (node for node in container.iter() if api.tag(node) == 'rootfile'):
            name = archive.resolve('container.xml', rootfile.get('full-path', ''))[0]
            package = api.xml(archive.read(name))
            packages[name] = package
            for item in package.iter():
                if ((api.tag(item) == 'item' and 'cover-image' in item.get('properties', '').split())
                        or (api.tag(item) == 'meta' and item.get('name') == 'cover' and item.get('content'))):
                    cover_declared = True
                if api.tag(item) == 'item' and item.get('media-type') == 'application/xhtml+xml':
                    document = archive.resolve(name, item.get('href', ''))[0]
                    if document not in archive.names:
                        raise api.ConversionError('В EPUB отсутствует глава книги.')
                    documents.add(document)
        if not packages or not documents:
            raise api.ConversionError('В EPUB отсутствует текст книги.')
        ET.register_namespace('', api.XH)
        ET.register_namespace('epub', api.EP)
        with zipfile.ZipFile(destination, 'x') as target:
            for member in archive.archive.infolist():
                data = archive.read(member.filename)
                if member.filename in documents:
                    root = api.xhtml(data)
                    if root.tag != '{' + api.XH + '}html':
                        raise api.ConversionError('Некорректная глава EPUB.')
                    for node in root.iter():
                        for name in list(node.attrib):
                            if name == 'data-fb2' or name.startswith('data-fb2-'):
                                del node.attrib[name]
                    data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
                elif member.filename in packages:
                    root = packages[member.filename]
                    for metadata in root.iter():
                        if api.tag(metadata) == 'metadata':
                            for item in list(metadata):
                                if item.get('property', '').startswith('mhl:fb2-'):
                                    metadata.remove(item)
                    data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
                target.writestr(member, data)
        return cover_declared
    finally:
        ET._namespace_map.clear()
        ET._namespace_map.update(namespaces)
        archive.close()


def only_publication_cover_required(completed, cover_declared):
    """Accept one KDP publishing requirement, never a malformed-book error.

    A personal Kindle file may have no cover, especially after the explicit
    no-images choice. Run the writer's full pre-flight first; only its sole
    missing-cover finding can permit a second build. The HTML self-check and
    our EPUB/Palm checks remain enabled. Any other error still aborts.
    """
    if cover_declared or completed.returncode != 1:
        return False
    findings = re.findall(r'^\[error\s+([^\]]+)\]', completed.stdout or '', flags=re.MULTILINE)
    return findings == ['R4.2.1'] and 'Build aborted: 1 validation errors.' in (completed.stderr or '')


def validate_output(api, path, extension):
    """Check the actual Palm/MOBI records, rather than trusting a suffix."""
    size = path.stat().st_size
    if size < 94 or size > api.MAX_TOTAL:
        raise api.ConversionError('Некорректный размер результата Kindle.')
    with path.open('rb') as stream:
        header = stream.read(78)
        count = struct.unpack_from('>H', header, 76)[0]
        if header[60:68] != b'BOOKMOBI' or not count or 78 + count * 8 > size:
            raise api.ConversionError('Конвертер не создал книгу Kindle.')
        table = stream.read(count * 8)
        offsets = [struct.unpack_from('>I', table, i * 8)[0] for i in range(count)]
        if offsets[0] < 78 + count * 8 or any(a > b for a, b in zip(offsets, offsets[1:])) or offsets[-1] >= size:
            raise api.ConversionError('Повреждён каталог записей книги Kindle.')
        stream.seek(offsets[0])
        record = stream.read(40)
        expected = 6 if extension == '.mobi' else 8
        if record[16:20] != b'MOBI' or len(record) != 40 or struct.unpack_from('>I', record, 36)[0] != expected:
            raise api.ConversionError('Версия книги Kindle не соответствует выбранному формату.')
        if extension == '.mobi':
            for i, offset in enumerate(offsets[:-1]):
                stream.seek(offset)
                if stream.read(8) == b'BOUNDARY':
                    stream.seek(offsets[i + 1])
                    next_record = stream.read(40)
                    if len(next_record) == 40 and next_record[16:20] == b'MOBI' and struct.unpack_from('>I', next_record, 36)[0] == 8:
                        break
            else:
                raise api.ConversionError('В MOBI отсутствует совместимая часть KF8.')


def convert(api, source, destination, options):
    source, destination = Path(source), Path(destination)
    extension = destination.suffix.lower()
    if extension not in {'.mobi', '.azw3'}:
        raise api.ConversionError('Неизвестный формат сохранения Kindle.')
    if destination.exists() or destination.resolve() == source.resolve():
        raise api.ConversionError('Исходная книга и результат должны быть разными файлами; результат уже не должен существовать.')
    tools = Path(options.get('tools_root') or Path(__file__).resolve().parent.parent)
    writer = tools / 'kindle-export/kindling-cli.exe'
    if not writer.is_file():
        raise api.ComponentRequired('KindleExport',
            'Для сохранения в MOBI и AZW3 нужен модуль записи Kindle — Kindling.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    warnings = set()
    with tempfile.TemporaryDirectory(prefix='homelibre-kindle-output-', dir=destination.parent) as folder:
        work = Path(folder)
        prepared = work / 'prepared.epub'
        # Reuse all input decoders, image choices and scan controls. This also
        # validates an existing EPUB without a lossy FB2 round trip.
        result = api.convert_book(source, prepared, **options)
        warnings.update(result.get('warnings', []))
        adapted = work / 'kindle-input.epub'
        cover_declared = canonical_input(api, prepared, adapted)
        output = work / ('book' + extension)
        command = [str(writer), 'build', str(adapted), '-o', str(output),
                   '--no-embed-source', '--creator-tag']
        if extension == '.mobi':
            command.append('--legacy-mobi')
        progress = options.get('progress') or (lambda *_: None)
        progress('kindle-writing', 0, 1)
        exemptions = []
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace',
                                       timeout=300, creationflags=0x08000000 if os.name == 'nt' else 0)
            if not output.exists() and only_publication_cover_required(completed, cover_declared):
                # All KPG checks have run. Do not invent an image just to satisfy
                # a store-submission rule for a user's personal, coverless book.
                remaining = max(1, 300 - (time.monotonic() - started))
                completed = subprocess.run(command + ['--no-validate'], capture_output=True,
                    encoding='utf-8', errors='replace', timeout=remaining,
                    creationflags=0x08000000 if os.name == 'nt' else 0)
                exemptions.append('R4.2.1')
        except subprocess.TimeoutExpired as error:
            raise api.ConversionError('Модуль записи Kindle не завершил работу за 5 минут.') from error
        if completed.returncode or not output.is_file():
            detail = '\n'.join(part.strip() for part in (completed.stdout, completed.stderr) if part).strip()[-4500:]
            raise api.ConversionError('Не удалось сохранить книгу Kindle.' + (' ' + detail if detail else ''))
        validate_output(api, output, extension)
        # Publication and cleanup follow the shared converter's no-replace
        # contract, including a name created by another process during work.
        with output.open('r+b') as stream:
            stream.flush()
            os.fsync(stream.fileno())
        if os.name == 'nt':
            os.rename(output, destination)
        else:
            os.link(output, destination)
            output.unlink()
        progress('kindle-writing', 1, 1)
    return dict(output=str(destination), warnings=sorted(warnings), size=destination.stat().st_size,
                publication_rule_exemptions=exemptions)
