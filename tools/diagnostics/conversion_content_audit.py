"""Compare real book content before/after conversion in a disposable profile.

Reads bounded original ZIP members through the inventory preparer. Reports only
counts and hashes, never copies a catalogue or retains extracted user books.
"""
import argparse
import base64
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import posixpath
import re
import sys
import tempfile
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bookconvert'))
import convert_book as converter
from prepare_catalogue_examples import prepare


class VisibleHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = []
        self.text = []

    def handle_starttag(self, name, attrs):
        if name in {'head', 'script', 'style', 'noscript', 'iframe', 'object'}:
            self.hidden.append(name)

    def handle_endtag(self, name):
        if name in self.hidden:
            self.hidden = self.hidden[:len(self.hidden) - 1 - self.hidden[::-1].index(name)]

    def handle_data(self, data):
        if not self.hidden:
            self.text.append(data)


def canonical(text):
    # Whitespace and punctuation presentation may legitimately change. Compare
    # every letter and digit in order, including case and accented characters.
    return ''.join(c for c in text if c.isalnum())


def source_text(path):
    data = path.read_bytes()
    if not zipfile.is_zipfile(path):
        charset = re.search(br'<meta\b[^>]*charset\s*=\s*[\'\"]?\s*([\w-]+)', data[:8192], re.I)
        encoding = charset[1].decode('ascii') if charset else 'utf-8-sig'
        try:
            text = data.decode(encoding)
        except UnicodeError:
            text = data.decode('cp1251')
        parser = VisibleHTML()
        parser.feed(text)
        parser.close()
        return ''.join(parser.text), set()
    with zipfile.ZipFile(path) as archive:
        container = ET.fromstring(archive.read('META-INF/container.xml'))
        package_path = next(n.get('full-path') for n in container.iter() if n.tag.endswith('}rootfile'))
        package = ET.fromstring(archive.read(package_path))
        items = {n.get('id'): n for n in package.iter() if n.tag.endswith('}item')}
        texts = []
        for ref in package.iter():
            if not ref.tag.endswith('}itemref'):
                continue
            item = items[ref.get('idref')]
            if 'nav' in item.get('properties', '').split():
                continue
            filename = posixpath.normpath(posixpath.join(posixpath.dirname(package_path), unquote(item.get('href'))))
            root = ET.fromstring(archive.read(filename))
            body = next(n for n in root.iter() if n.tag.rsplit('}', 1)[-1] == 'body')
            parser = VisibleHTML()
            parser.feed(ET.tostring(body, encoding='unicode'))
            # Namespaced XHTML has no executable/style nodes in these examples;
            # extract itertext directly to avoid treating tag prefixes as HTML.
            texts.append(''.join(body.itertext()))
        images = {hashlib.sha256(archive.read(posixpath.normpath(posixpath.join(
            posixpath.dirname(package_path), unquote(n.get('href')))))).hexdigest()
            for n in items.values() if n.get('media-type', '').startswith('image/')}
        return ''.join(texts), images


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('inventory', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ids', default='790569,809268,731261,720697')
    options = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-content-audit-') as temporary:
        profile = Path(temporary)
        (profile / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        prepare(options.inventory, profile, ','.join('id:' + value for value in options.ids.split(',')))
        examples = json.loads((profile / 'catalogue-examples/examples.json').read_text(encoding='utf-8'))['examples']
        if len(examples) != len(options.ids.split(',')):
            raise RuntimeError('The audit did not extract every requested book')
        for example in examples:
            source = profile / 'catalogue-examples' / example['name']
            original, images = source_text(source)
            output = source.with_suffix('.audit.fb2')
            conversion = converter.convert_book(source, output)
            root = ET.fromstring(output.read_bytes())
            converted = ''.join(''.join(n.itertext()) for n in root if n.tag.rsplit('}', 1)[-1] == 'body')
            before, after = canonical(original), canonical(converted)
            binaries = {hashlib.sha256(base64.b64decode(n.text)).hexdigest() for n in root
                        if n.tag.rsplit('}', 1)[-1] == 'binary'}
            ids = {n.get('id') for n in root.iter() if n.get('id')}
            broken_links = sum(1 for n in root.iter() for k, v in n.attrib.items()
                               if k.rsplit('}', 1)[-1] == 'href' and v.startswith('#') and v[1:] not in ids)
            results.append({'id': example['id'], 'source_characters': len(before),
                            'output_characters': len(after), 'letters_digits_identical_in_order': before == after,
                            'source_text_sha256': hashlib.sha256(before.encode()).hexdigest(),
                            'output_text_sha256': hashlib.sha256(after.encode()).hexdigest(),
                            'source_images': len(images), 'missing_original_image_hashes': len(images - binaries),
                            'broken_internal_links': broken_links, 'warnings': conversion['warnings'],
                            'source_unchanged': hashlib.sha256(source.read_bytes()).hexdigest() == example['sha256']})
    options.output.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(results, ensure_ascii=False))
    return 0 if all(r['letters_digits_identical_in_order'] and not r['missing_original_image_hashes']
                    and not r['broken_internal_links'] and r['source_unchanged'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
