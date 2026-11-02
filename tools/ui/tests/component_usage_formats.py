"""Headless real-format checks of the packaged converter's actual-tool report.

This is the backend half of module-usage integration. It does not claim that a
native Reader window or the catalogue's usage ledger has been exercised.
Source archives are read only; extracted books and outputs are disposable.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPO = Path(__file__).resolve().parents[3]
CASES = {
    '.fb2': (513904, ''), '.epub': (810690, ''), '.docx': (790607, ''),
    '.pdf': (840861, 'PDFium'), '.djvu': (808806, 'DjVuLibre'),
    '.doc': (812349, 'DocSharp'), '.chm': (809048, '7-Zip'),
    '.lit': (722811, 'LegacyBooks'), '.lrf': (718257, 'LegacyBooks'),
    '.mobi': (809541, 'Kindle'), '.wps': (750218, 'LegacyOffice'),
    '.xps': (743894, 'XPS'), '.ibk': (752297, 'IBK'),
    '.pdb': (767101, ''), '.rgo': (816138, ''),
}
PACKAGES = ['BookProcessing', 'ImageProcessing', 'Kindle', 'LegacyBooks', 'LegacyOffice', 'XPS']
PREFIXES = {
    'tools/python/': 'BookProcessing', 'tools/images/': 'ImageProcessing',
    'tools/office/': 'LegacyOffice', 'tools/xps/': 'XPS',
    'tools/pdfium/': 'PDFium', 'tools/djvu/': 'DjVuLibre',
    'tools/doc/': 'DocSharp', 'tools/7zip/': '7-Zip',
    'tools/jpeg-xl/': 'JPEG XL', 'tools/webp/': 'WebP',
    'tools/bookconvert/vendor/calibre_legacy/': 'LegacyBooks',
}
EXTERNAL_COMPONENTS = {
    '.pdf': 'PDFium', '.djvu': 'DjVuLibre', '.doc': 'DocSharp',
    '.chm': '7-Zip', '.wps': 'LegacyOffice', '.xps': 'XPS',
}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pe_machine(path):
    with path.open('rb') as source:
        header = source.read(64)
        if header[:2] != b'MZ':
            raise ValueError('Not a PE executable: ' + str(path))
        source.seek(struct.unpack_from('<I', header, 60)[0])
        signature = source.read(6)
    if signature[:4] != b'PE\0\0':
        raise ValueError('Invalid PE signature')
    return struct.unpack_from('<H', signature, 4)[0]


def content(path):
    if path.suffix == '.fb2':
        root = ET.parse(path).getroot()
        text = ''.join(''.join(node.itertext()) for node in root
                       if node.tag.rsplit('}', 1)[-1] == 'body')
        pictures = [base64.b64decode(node.text or '') for node in root
                    if node.tag.rsplit('}', 1)[-1] == 'binary']
        return len(text.strip()), len(pictures)
    characters, pictures = 0, 0
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if name.lower().endswith(('.xhtml', '.html', '.htm')):
                root = ET.fromstring(archive.read(name))
                characters += len(''.join(root.itertext()).strip())
            elif name.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg')):
                pictures += 1
    return characters, pictures


def run(args):
    if args.report.exists():
        raise ValueError('Refuse to overwrite earlier evidence')
    selected = args.formats.split(',') if args.formats else list(CASES)
    if not selected or any(extension not in CASES for extension in selected):
        raise ValueError('Unknown requested format')
    runtime = REPO / 'Program/Out' / ('Bin64' if args.platform == 'Win64' else 'Bin')
    result = {'status': 'RUNNING', 'scope': __doc__, 'platform': args.platform,
              'original_archives_read_only': True, 'payloads_removed': False, 'rows': []}
    root = None

    def save():
        args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    save()
    temporary_parent = Path(tempfile.gettempdir()).resolve()
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibre-component-use-', dir=temporary_parent) as name:
            root = Path(name).resolve()
            if root.parent != temporary_parent or not root.name.startswith('HomeLibre-component-use-'):
                raise ValueError('Unexpected fixture root')
            (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
            load('usage_package_fixture', REPO / 'tools/ui/tests/prepare_format_runtime_fixture.py').prepare(
                args.packages.resolve(), root, args.platform, PACKAGES)
            for helper in ['pdfium', 'djvu', 'doc', '7zip', 'webp', 'jpeg-xl']:
                shutil.copytree(runtime / 'tools' / helper, root / 'tools' / helper,
                                ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.map', '*.rsm'))
            if '.ibk' in selected:
                if not args.ibk_data:
                    raise ValueError('A pinned public IBK format-data file is required')
                identity = json.loads((REPO / 'tools/bookconvert/ibk_parameters.json').read_text())
                if (args.ibk_data.stat().st_size != identity['runtime_key_bytes']
                        or digest(args.ibk_data) != identity['runtime_key_sha256']):
                    raise ValueError('IBK format-data identity mismatch')
                (root / 'tools/ibk').mkdir()
                shutil.copyfile(args.ibk_data, root / 'tools/ibk/Rus.key')
            python = root / 'tools/python/python.exe'
            if pe_machine(python) != (0x8664 if args.platform == 'Win64' else 0x14c):
                raise ValueError('Packaged Python architecture mismatch')
            script = root / 'tools/bookconvert/convert_book.py'
            if digest(script) != digest(REPO / 'tools/bookconvert/convert_book.py'):
                raise ValueError('Packaged converter differs from current source')
            result['converter_sha256'] = digest(script)
            result['python_sha256'] = digest(python)
            load('usage_collection_extractor', REPO / 'tools/diagnostics/prepare_catalogue_examples.py').prepare(
                args.inventory.resolve(), root, ','.join('id:' + str(CASES[ext][0]) for ext in selected))
            examples = json.loads((root / 'catalogue-examples/examples.json').read_text(encoding='utf-8'))
            by_id = {entry['id']: entry for entry in examples['examples']}
            if set(by_id) != {CASES[extension][0] for extension in selected}:
                raise ValueError('Not every explicitly requested real book was extracted')
            for extension in selected:
                book_id, source_component = CASES[extension]
                entry = by_id[book_id]
                source = root / 'catalogue-examples' / entry['name']
                row = {'id': book_id, 'extension': extension, 'source_sha256': entry['sha256'],
                       'source_component': source_component, 'operations': []}
                result['rows'].append(row)
                for reading, target in [(True, '.epub'), (False, '.fb2')]:
                    output = root / ('result' + target)
                    report = root / 'conversion-report.json'
                    operation = {'reading': reading, 'target': target}
                    row['operations'].append(operation)
                    command = [str(python), '-I', '-B', '-X', 'utf8', str(script), str(source), str(output),
                               '--tools-root', str(root / 'tools'), '--report', str(report)]
                    if reading:
                        command.append('--reading')
                    completed = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace',
                                               timeout=180, creationflags=0x08000000)
                    details = json.loads(report.read_text(encoding='utf-8-sig')) if report.is_file() else {}
                    if completed.returncode or not output.is_file():
                        raise ValueError(str(details.get('error') or completed.stderr or completed.stdout)[-2000:])
                    if not isinstance(details.get('used_tools'), list):
                        raise ValueError('Converter omitted actual-tool report')
                    tools = []
                    for item in details['used_tools']:
                        tool = Path(item).resolve()
                        if not tool.is_file() or not tool.is_relative_to(root / 'tools'):
                            raise ValueError('Reported tool lies outside the isolated runtime')
                        relative = tool.relative_to(root).as_posix()
                        component = next((value for prefix, value in PREFIXES.items()
                                          if relative.startswith(prefix)), None)
                        if component is None:
                            raise ValueError('Unrecognized actually used tool: ' + relative)
                        tools.append({'path': relative, 'component': component, 'sha256': digest(tool)})
                    characters, pictures = content(output)
                    if not characters and not pictures:
                        raise ValueError('Conversion produced no readable content')
                    if extension in ('.fb2', '.epub', '.docx') and tools:
                        raise ValueError('Basic format claimed an unrelated external tool')
                    expected = EXTERNAL_COMPONENTS.get(extension)
                    if expected and expected not in {tool['component'] for tool in tools}:
                        raise ValueError('Actual-tool report omitted ' + expected)
                    if digest(source) != entry['sha256']:
                        raise ValueError('Conversion changed its source')
                    operation.update(status='PASS', output_bytes=output.stat().st_size,
                                     characters=characters, pictures=pictures, used_tools=tools,
                                     warnings=details.get('warnings', []))
                    output.unlink()
                    report.unlink()
                    save()
                row['status'] = 'PASS'
                print('PASS actual packaged backend', args.platform, extension, book_id, flush=True)
                save()
            result['status'] = 'PASS_BACKEND_ONLY'
    except Exception as error:
        result['status'] = 'FAIL'
        result['error'] = str(error)
        raise
    finally:
        result['payloads_removed'] = root is None or not root.exists()
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', type=Path, required=True)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, default=REPO / 'tools/ui/tests/Out/pre533-format-inventory.json')
    parser.add_argument('--ibk-data', type=Path)
    parser.add_argument('--formats', help='Optional bounded comma-separated subset')
    run(parser.parse_args())
