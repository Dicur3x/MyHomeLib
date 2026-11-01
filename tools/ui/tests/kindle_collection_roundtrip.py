"""Exercise packaged Kindle output on read-only collection samples, sequentially.

The chosen architecture's packaged Python runs its actual input helpers and
writer. KindleUnpack independently decodes each result for content checks.
Books and runtimes exist only inside this invocation's owned temporary root.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit
import zipfile

REPO = Path(__file__).resolve().parents[3]
ORDER = ['.docx', '.doc', '.rtf', '.odt', '.chm', '.lit', '.lrf', '.pdb',
         '.rgo', '.ibk', '.mobi', '.azw', '.azw3', '.prc', '.sm']


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(value):
    return ''.join(unicodedata.normalize('NFKC', value).replace('\xad', '').split())


def epub_content(api, path, *, check_image_links=False):
    paragraphs, text, images = [], [], set()
    with zipfile.ZipFile(path) as archive:
        members = set(archive.namelist())
        for name in archive.namelist():
            if name.lower().endswith(('.png', '.jpeg', '.jpg', '.gif', '.bmp')):
                images.add(hashlib.sha256(archive.read(name)).hexdigest())
            if not name.lower().endswith(('.xhtml', '.html', '.htm')):
                continue
            document = api.xhtml(archive.read(name))
            if check_image_links:
                for node in document.iter():
                    attribute = 'src' if api.tag(node) == 'img' else 'href' if api.tag(node) == 'image' else None
                    if not attribute:
                        continue
                    reference = node.get(attribute) or node.get('{http://www.w3.org/1999/xlink}' + attribute)
                    if not reference:
                        continue
                    parts = urlsplit(reference)
                    if parts.scheme or parts.netloc:
                        continue
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(parts.path))) if parts.path else name
                    if target not in members:
                        raise ValueError(f'Broken image link in {name}: {reference}')
            if any(api.tag(n) == 'nav' for n in document.iter()):
                continue
            for node in document.iter():
                tag = api.tag(node)
                if tag == 'body':
                    text.append(''.join(node.itertext()))
                if tag in {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'pre', 'td'}:
                    value = normalized(''.join(node.itertext()))
                    if len(value) >= 12:
                        paragraphs.append(value)
    return paragraphs, normalized(''.join(text)), len(images)


def run_cases(root, report):
    if (root / 'native-regression.marker').read_text() != 'HomeLib Ru isolated native regression v1':
        raise ValueError('Only an owned fixture profile is allowed')
    api = load('kindle_collection_api', root / 'tools/bookconvert/convert_book.py')
    inputs = root / 'catalogue-examples'
    inventory = json.loads((inputs / 'examples.json').read_text(encoding='utf-8'))
    entries = inventory['examples']
    entries.sort(key=lambda item: ORDER.index(item['extension']))
    result = {'status': 'RUNNING', 'architecture_bits': 64 if sys.maxsize > 2**32 else 32,
              'rows': [], 'published': False, 'original_archives_read_only': True,
              'unavailable': inventory['unavailable'],
              'requested_extensions': inventory['requested_extensions']}

    def save():
        report.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    save()
    for entry in entries:
        source = inputs / entry['name']
        if digest(source) != entry['sha256']:
            raise ValueError('Extracted input differs from its recorded bytes')
        row = {'id': entry['id'], 'recorded_extension': entry['extension'], 'source_sha256': entry['sha256']}
        result['rows'].append(row)
        output = reference = None
        try:
            row['detected_extension'] = api.detect_input(source)
            work = root / ('case-' + str(entry['id']))
            work.mkdir()
            reference = work / 'reference.epub'
            conversion_source = source
            if row['detected_extension'] == '.sm':
                # A game must never silently turn into a pretend complete book.
                # Exercise the real route exporter in a fresh test-only session.
                try:
                    api.convert_book(source, reference, tools_root=root / 'tools', image_quality='original')
                except api.ConversionError as error:
                    if 'Сохранить пройденную ветку' not in str(error):
                        raise
                else:
                    raise ValueError('Interactive input lost its explicit route-export guard')
                if reference.exists():
                    raise ValueError('Rejected interactive conversion published an output')
                sys.path.insert(0, str(root / 'tools/bookconvert'))
                import sm_reader
                conversion_source = work / 'selected-test-route.epub'
                with sm_reader.ReaderSession(sm_reader.Story.parse(source.read_bytes()), now=1, seed=1) as reader:
                    actions = 0
                    for step in range(2):
                        choices = reader.choices()
                        if not choices:
                            break
                        reader.choose(choices[0]['id'], now=step + 2)
                        actions += 1
                    route_warnings = sm_reader.write_document(reader, source, conversion_source, transcript=True)
                row['interactive_scope'] = {'selected_test_actions': actions, 'whole_game_exported': False,
                                            'direct_conversion_guard': 'PASS', 'warnings': route_warnings}
            info = api.convert_book(conversion_source, reference, tools_root=root / 'tools', image_quality='original')
            paragraphs, text, image_count = epub_content(api, reference)
            if not text and not image_count:
                raise ValueError('Input decoder produced no readable content')
            row['reference'] = {'paragraphs': len(paragraphs), 'text_length': len(text), 'images': image_count}
            row['outputs'] = []
            for extension in ('.mobi', '.azw3'):
                output = work / ('output' + extension)
                converted = api.convert_book(conversion_source, output, tools_root=root / 'tools', image_quality='original')
                decoded = work / ('decoded-' + extension[1:] + '.epub')
                api.convert_book(output, decoded, tools_root=root / 'tools', image_quality='original')
                _, actual_text, actual_images = epub_content(api, decoded, check_image_links=True)
                missing = [p for p in paragraphs if p not in actual_text]
                if missing:
                    raise ValueError(f'{extension}: {len(missing)} source paragraphs missing; first hash='
                                     + hashlib.sha256(missing[0].encode()).hexdigest())
                if image_count and not actual_images:
                    raise ValueError(f'{extension}: all source images missing')
                row['outputs'].append({'extension': extension, 'bytes': output.stat().st_size,
                                       'sha256': digest(output), 'decoded_images': actual_images,
                                       'warnings': converted.get('warnings', [])})
            if digest(source) != entry['sha256']:
                raise ValueError('Conversion changed the extracted source')
            row['status'] = 'PASS'
            row['input_warnings'] = info.get('warnings', [])
            print('PASS collection input', entry['id'], entry['extension'], 'to MOBI/AZW3', flush=True)
        except Exception as error:
            row['status'] = 'FAIL'
            row['error'] = str(error)
            if isinstance(reference, Path) and reference.is_file():
                with zipfile.ZipFile(reference) as archive:
                    row['diagnostic_image_records'] = [
                        {'name': name, 'bytes': len(data), 'header': data[:8].hex(), 'tail': data[-12:].hex()}
                        for name in [name for name in archive.namelist()
                                     if name.lower().endswith(('.gif', '.jpg', '.jpeg'))][:20]
                        for data in [archive.read(name)]]
            # Keep a bounded structural clue, not the private book/runtime.
            # The unpacker's output may fail before the normal reader can
            # parse its OPF, so inspect that independently on failure only.
            if isinstance(output, Path) and output.is_file():
                manifest, unpack = work / 'failure-unpack.json', work / 'failure-unpack'
                helper = root / 'tools/bookconvert/kindle_input.py'
                diagnostic = subprocess.run([sys.executable, '-I', '-B', str(helper),
                    str(output), str(manifest), str(unpack),
                    str(root / 'tools/bookconvert/vendor/calibre_legacy/native/HomeLibLegacy.dll'),
                    str(root / 'tools/kindle')], capture_output=True, encoding='utf-8', errors='replace')
                if diagnostic.returncode == 0:
                    decoded_path = Path(json.loads(manifest.read_text(encoding='utf-8'))['path'])
                    if decoded_path.suffix == '.epub':
                        with zipfile.ZipFile(decoded_path) as archive:
                            for name in archive.namelist():
                                if name.endswith('.opf'):
                                    row['diagnostic_opf'] = archive.read(name).decode('utf-8', errors='replace')[:12000]
                                elif name.lower().endswith(('.xhtml', '.html', '.htm')):
                                    raw = archive.read(name)
                                    try:
                                        api.xhtml(raw)
                                    except Exception as xml_error:
                                        import re
                                        diagnostics = row.setdefault('diagnostic_html', [])
                                        if len(diagnostics) < 3:
                                            diagnostics.append({'name': name, 'error': str(xml_error),
                                                'tags': re.findall(r'<[^>]+>', raw.decode('utf-8', errors='replace'))[:30]})
            result['status'] = 'FAIL; stopped at first unresolved case'
            save()
            raise
        save()
    result['status'] = 'PASS available samples; PARTIAL inventory' if inventory['unavailable'] else 'PASS'
    save()


def prepare(args):
    if args.report.exists():
        raise ValueError('Refuse to replace earlier evidence')
    runtime = REPO / 'Program/Out' / ('Bin64' if args.platform == 'Win64' else 'Bin')
    inventory = REPO / 'tools/ui/tests/Out/pre533-format-inventory.json'
    selected = args.formats.split(',') if args.formats else ORDER
    if not selected or any(extension not in ORDER for extension in selected):
        raise ValueError('Unknown collection format selection')
    with tempfile.TemporaryDirectory(prefix='HomeLibre-kindle-collection-', dir=os.environ['TEMP']) as folder:
        root = Path(folder)
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        load('collection_input_extractor', REPO / 'tools/diagnostics/prepare_catalogue_examples.py').prepare(
            inventory, root, ','.join(selected))
        extracted = json.loads((root / 'catalogue-examples/examples.json').read_text(encoding='utf-8'))
        extracted['requested_extensions'] = selected
        (root / 'catalogue-examples/examples.json').write_text(
            json.dumps(extracted, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print('Unavailable:', json.dumps(extracted['unavailable'], ensure_ascii=False), flush=True)
        load('packaged_runtime_fixture', REPO / 'tools/ui/tests/prepare_format_runtime_fixture.py').prepare(
            args.packages.resolve(), root, args.platform, ['BookProcessing', 'KindleExport'])
        # KindleUnpack independently checks every result. Other helpers are
        # private input/illustration dependencies, not distribution payloads.
        helpers = ['kindle', 'images', 'jpeg-xl', 'webp']
        if '.doc' in selected:
            helpers.append('doc')
        if '.chm' in selected:
            helpers.append('7zip')
        for name in helpers:
            source = runtime / 'tools' / name
            if source.is_dir():
                shutil.copytree(source, root / 'tools' / name,
                                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        for source in (runtime / 'tools/bookconvert').rglob('*'):
            relative = source.relative_to(runtime / 'tools/bookconvert')
            target = root / 'tools/bookconvert' / relative
            if (source.is_file() and not target.exists() and '__pycache__' not in relative.parts
                    and source.suffix != '.pyc' and source.name != 'COMPONENT.json'):
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        if '.ibk' in selected:
            if not args.ibk_data:
                raise ValueError('IBK matrix requires the verified original format-data file via --ibk-data')
            parameters = json.loads((root / 'tools/bookconvert/ibk_parameters.json').read_text(encoding='utf-8'))
            if (args.ibk_data.stat().st_size != parameters['runtime_key_bytes']
                    or digest(args.ibk_data) != parameters['runtime_key_sha256']):
                raise ValueError('IBK format-data identity mismatch')
            destination = root / 'tools/ibk/Rus.key'
            destination.parent.mkdir()
            shutil.copyfile(args.ibk_data, destination)
        python = root / 'tools/python/python.exe'
        completed = subprocess.run([str(python), '-I', '-B', '-X', 'utf8', str(Path(__file__).resolve()),
                                    '--run', str(root), '--report', str(args.report.resolve())],
                                   env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                   capture_output=True, encoding='utf-8', errors='replace',
                                   timeout=1800, creationflags=0x08000000 if os.name == 'nt' else 0)
        print(completed.stdout, end='', flush=True)
        if completed.returncode:
            if not args.report.exists():
                args.report.write_text(json.dumps({'status': 'FAIL before conversion',
                    'unavailable': extracted['unavailable'], 'stderr': completed.stderr,
                    'exit_code': completed.returncode}, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
            print(completed.stderr[-3000:], file=sys.stderr)
            raise SystemExit(completed.returncode)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=Path)
    parser.add_argument('--packages', type=Path)
    parser.add_argument('--platform', choices=['Win32', 'Win64'])
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--formats', help='Bound this run to comma-separated formats, e.g. .rtf')
    parser.add_argument('--ibk-data', type=Path, help='Pinned original ICE Russian format data; never executed')
    options = parser.parse_args()
    if options.run:
        run_cases(options.run.resolve(), options.report.resolve())
    else:
        if not options.packages or not options.platform:
            parser.error('--packages and --platform required')
        prepare(options)
