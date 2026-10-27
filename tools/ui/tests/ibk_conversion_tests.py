"""Compare original collection IBKs with independently exported native ICE text.

Local audit only: no book contents are committed or kept by this test. The
reference HTML files are user-created native exports, not converter outputs.
"""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import posixpath
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile


class Oracle(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = False
        self.parts = []

    def handle_starttag(self, name, attrs):
        if name == 'pre': self.active = True

    def handle_endtag(self, name):
        if name == 'pre': self.active = False

    def handle_data(self, text):
        if self.active: self.parts.append(text)


def paragraphs(text):
    result = [' '.join(line.split()) for line in text.splitlines()]
    while result and not result[0]: result.pop(0)
    while result and not result[-1]: result.pop()
    return result


def output_paragraphs(path):
    if path.suffix == '.fb2':
        tree = ET.fromstring(path.read_bytes())
        values = []
        for body in tree.findall('{http://www.gribuser.ru/xml/fictionbook/2.0}body'):
            for node in body.iter():
                tag = node.tag.rsplit('}', 1)[-1]
                if tag == 'p': values.append(''.join(node.itertext()))
                elif tag == 'empty-line': values.append('')
        return paragraphs('\n'.join(values))
    with zipfile.ZipFile(path) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        opf_path = next(node.attrib['full-path'] for node in container.iter() if node.tag.endswith('}rootfile'))
        opf = ET.fromstring(archive.read(opf_path))
        ns = {'o': 'http://www.idpf.org/2007/opf'}
        manifest = {node.attrib['id']: node.attrib['href'] for node in opf.findall('o:manifest/o:item', ns)}
        values = []
        for item in opf.findall('o:spine/o:itemref', ns):
            name = posixpath.normpath(posixpath.join(posixpath.dirname(opf_path), manifest[item.attrib['idref']]))
            document = ET.fromstring(archive.read(name))
            values.extend(''.join(node.itertext()) for node in document.findall('.//{http://www.w3.org/1999/xhtml}p'))
        return paragraphs('\n'.join(values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--tools-root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    options = parser.parse_args()
    root = options.root.resolve()
    references = {752297: 'Агриппа', 754336: 'ТРОИСИ', 746059: 'Кистяева'}
    inventory = json.loads((root / 'tools/ui/tests/Out/pre533-format-inventory.json').read_text(encoding='utf-8'))
    items = next(item['examples'] for item in inventory['formats'] if item['extension'] == '.ibk')
    rows = []
    archives = []
    with tempfile.TemporaryDirectory(prefix='ibk-conversion-check-', dir=options.tools_root.parent) as directory:
        work = Path(directory).resolve()
        sources = {}
        expected = {}
        for item in items:
            identity = item['id']
            source = item['available'][0]
            archive = Path(source['path'])
            if not archive.exists(): archive = archive.with_name('f.' + archive.name)
            before = archive.stat()
            archives.append((archive, before.st_size, before.st_mtime_ns))
            with zipfile.ZipFile(archive, 'r') as handle:
                data = handle.read(source['member'])
            path = work / (str(identity) + '.ibk')
            path.write_bytes(data)
            sources[identity] = path
            oracle = Oracle()
            reference = next((root / 'tools/ui/tests/Out/ibk-reference-export').glob(references[identity] + '*.htm'))
            oracle.feed(reference.read_text(encoding='utf-8-sig'))
            expected[identity] = paragraphs(''.join(oracle.parts).split('_###ICE#BOOK#READER#PROFESSIONAL#HEADER#FINISH###_', 1)[1])
        for arch, python in [('x86', root / 'Program/Out/Bin/tools/kindle/python/python.exe'),
                             ('x64', root / 'Program/Out/Bin64/tools/kindle/python/python.exe')]:
            cases = [(identity, extension, False, False) for identity in references for extension in ['fb2', 'epub']]
            cases += [(identity, 'epub', True, False) for identity in references]
            cases += [(752297, 'epub', False, True), (746059, 'fb2', False, True)]
            for identity, extension, reading, wrong in cases:
                source = sources[identity]
                original = hashlib.sha256(source.read_bytes()).hexdigest()
                if wrong:
                    source = work / (str(identity) + '.pdf')
                    source.write_bytes(sources[identity].read_bytes())
                destination = work / (arch + '-' + str(identity) + ('-reading' if reading else '') +
                                      ('-wrong' if wrong else '') + '.' + extension)
                args = [str(python), '-I', '-B', '-X', 'utf8', str(root / 'tools/bookconvert/convert_book.py'),
                        str(source), str(destination), '--tools-root', str(options.tools_root), '--language', 'ru']
                if reading: args.append('--reading')
                result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', timeout=60,
                                        creationflags=0x08000000)
                assert result.returncode == 0, (arch, identity, extension, reading, wrong, result.stdout, result.stderr)
                actual = output_paragraphs(destination)
                assert actual == expected[identity], (arch, identity, extension, 'paragraph mismatch', len(actual), len(expected[identity]))
                assert hashlib.sha256(source.read_bytes()).hexdigest() == original
                row = {'architecture': arch, 'book_id': identity, 'target': extension,
                       'reading_preparation': reading, 'wrong_extension': wrong,
                       'full_text_and_paragraphs_match_native_export': True,
                       'source_sha256_preserved': True, 'output_bytes': destination.stat().st_size}
                rows.append(row)
                print(json.dumps(row), flush=True)
        for archive, size, mtime in archives:
            now = archive.stat()
            assert (size, mtime) == (now.st_size, now.st_mtime_ns)
    assert len(rows) == 22
    report = {'scope': 'Direct original IBK input -> FB2/EPUB/reading EPUB; verified original optional runtime files are read as data only',
              'results': rows, 'original_archives_metadata_preserved': True, 'temporary_inputs_outputs_removed': True,
              'native_GUI_application_tests_pending': True, 'component_installer_pending': True}
    options.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('PASS: 22 direct IBK cases; temporary book files removed.')


if __name__ == '__main__':
    main()
