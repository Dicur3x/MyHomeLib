"""Image-only changes to existing Office/comic ZIPs; never convert their text."""
import importlib.util
from pathlib import Path
import posixpath
import shutil
import subprocess
import tempfile
import zipfile

FORMATS = frozenset({'.docx', '.odt', '.cbz'})
RASTERS = {'image/png': {'.png'}, 'image/jpeg': {'.jpg', '.jpeg'}}
MANIFEST = '{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}'
CONTENT_TYPES = '{http://schemas.openxmlformats.org/package/2006/content-types}'


def _image_members(api, book, extension, check=None):
    """Validate a bounded package and select declared, same-format rasters."""
    if extension not in FORMATS:
        raise api.ConversionError('Неизвестный формат сжатия контейнера изображений.')
    with zipfile.ZipFile(book) as source:
        entries = source.infolist()
        names = [e.filename for e in entries]
        if (len(entries) > api.MAX_ENTRIES or len(names) != len(set(names)) or
                sum(e.file_size for e in entries) > api.MAX_TOTAL or
                any(e.file_size > api.MAX_FILE or e.flag_bits & 1 for e in entries)):
            raise api.ConversionError('Контейнер повреждён, зашифрован или превышает предел обработки.')
        if any('\\' in n or n.startswith('/') or '..' in n.split('/') for n in names):
            raise api.ConversionError('В контейнере есть неоднозначные внутренние пути.')
        # A signature must not silently become invalid after changing an image.
        if any(n.casefold().startswith('_xmlsignatures/') or
               n.casefold() in {'meta-inf/documentsignatures.xml', 'meta-inf/macrosignatures.xml'} for n in names):
            raise api.ConversionError('Книга имеет цифровую подпись; изображения сохранены без изменения.')
        declared = {}
        if extension == '.odt':
            if ('mimetype' not in names or names[0] != 'mimetype' or
                    source.getinfo('mimetype').compress_type != zipfile.ZIP_STORED or
                    source.read('mimetype') != b'application/vnd.oasis.opendocument.text'):
                raise api.ConversionError('Некорректный контейнер ODT; исходная книга сохранена.')
            manifest = api.xml(source.read('META-INF/manifest.xml'))
            if any(n.tag == MANIFEST+'encryption-data' for n in manifest.iter()):
                raise api.ConversionError('ODT содержит зашифрованные данные; исходная книга сохранена.')
            for node in manifest.iter(MANIFEST+'file-entry'):
                media = node.get(MANIFEST+'media-type', '').lower()
                if media in RASTERS:
                    declared[node.get(MANIFEST+'full-path', '')] = media
        elif extension == '.docx':
            types = api.xml(source.read('[Content_Types].xml'))
            defaults, overrides = {}, {}
            for node in types:
                media = node.get('ContentType', '').lower()
                if 'digital-signature' in media:
                    raise api.ConversionError('Книга имеет цифровую подпись; исходная книга сохранена.')
                if node.tag == CONTENT_TYPES+'Default':
                    defaults[node.get('Extension', '').lower()] = media
                elif node.tag == CONTENT_TYPES+'Override':
                    overrides[node.get('PartName', '').lstrip('/')] = media
            for name in names:
                if name.startswith('word/media/') or name.startswith('docProps/thumbnail.'):
                    media = overrides.get(name, defaults.get(posixpath.splitext(name)[1][1:].lower()))
                    if media in RASTERS:
                        declared[name] = media
        else:
            for name in names:
                suffix = posixpath.splitext(name)[1].lower()
                for media, suffixes in RASTERS.items():
                    if suffix in suffixes:
                        declared[name] = media
        selected = set()
        for entry in entries:
            if check is not None:
                check()
            media = declared.get(entry.filename)
            if not media or not 0 < entry.file_size <= 16*1024*1024:
                continue
            with source.open(entry) as stream:
                prefix = stream.read(12)
            actual = ('image/png' if prefix.startswith(b'\x89PNG\r\n\x1a\n') else
                      'image/jpeg' if prefix.startswith(b'\xff\xd8\xff') else None)
            if actual == media:
                selected.add(entry.filename)
        return selected


def image_members(api, book, extension, check=None):
    try:
        return _image_members(api, book, extension, check)
    except api.ConversionError:
        raise
    except (KeyError, zipfile.BadZipFile, NotImplementedError) as error:
        raise api.ConversionError('Не удалось проверить контейнер книги; исходник сохранён.') from error


def rewrite_metadata(api, data, replacements):
    """Only an explicitly recorded ODT image byte count needs adjustment."""
    api.xml(data)
    parser = api.ET.XMLParser(target=api.ET.TreeBuilder(insert_comments=True, insert_pis=True))
    root = api.ET.fromstring(data, parser=parser)
    changed = False
    for node in root.iter(MANIFEST+'file-entry'):
        name = node.get(MANIFEST+'full-path', '')
        if name in replacements and MANIFEST+'size' in node.attrib:
            size = str(len(replacements[name]))
            if node.get(MANIFEST+'size') != size:
                node.set(MANIFEST+'size', size)
                changed = True
    return api.ET.tostring(root, encoding='utf-8', xml_declaration=True) if changed else data


def compress(api, source, destination, *, image_quality, tools_root, cancel_check=None,
             packing_grayscale=False, grayscale=False, packing_image_history=None,
             packing_image_report=None, **unused):
    source, destination = Path(source), Path(destination)
    extension = api.detect_input(source)
    if source.resolve() == destination.resolve() or destination.exists():
        raise api.ConversionError('Для результата сжатия нужно новое имя файла.')
    if extension != destination.suffix.lower() or extension not in FORMATS:
        raise api.ConversionError('При сжатии нужно сохранить исходный формат книги.')
    if image_quality not in ('original', 'balanced', 'economy', 'maximum'):
        raise api.ConversionError('Неизвестный режим сжатия изображений.')
    image_members(api, source, extension, cancel_check)
    tool = api.image_processor_path(Path(tools_root))
    try:
        capabilities = subprocess.run([str(tool), '--packing-image-profiles'], capture_output=True,
            timeout=5, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.TimeoutExpired) as error:
        raise api.ComponentRequired('ImageProcessing', 'Не удалось проверить модуль HomeLibre Images.') from error
    if capabilities.returncode or b'same-format' not in capabilities.stdout.split():
        raise api.ComponentRequired('ImageProcessing', 'Для сжатия ODT, DOCX и CBZ обновите модуль HomeLibre Images.')
    spec = importlib.util.spec_from_file_location('homelibre_container_quality', Path(__file__).with_name('image_quality.py'))
    quality = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(quality)
    warnings = set()
    with tempfile.TemporaryDirectory(prefix='homelibre-container-', dir=destination.parent) as temporary:
        candidate = Path(temporary)/('book'+extension)
        shutil.copyfile(source, candidate)
        quality.apply(api, candidate, extension, image_quality, tools_root, lambda *_: None,
            warnings=warnings, check=cancel_check, grayscale=grayscale or packing_grayscale,
            preserve_image=packing_image_history, image_history_report=packing_image_report)
        # Validate the rewritten package as well; text/asset byte comparison is
        # performed independently by the collection preparation worker.
        image_members(api, candidate, extension, cancel_check)
        if cancel_check is not None:
            cancel_check()
        candidate.rename(destination)
    return dict(output=str(destination), size=destination.stat().st_size, warnings=sorted(warnings))
