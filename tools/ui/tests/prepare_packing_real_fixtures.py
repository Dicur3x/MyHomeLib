"""Stage a bounded set of actual library books for the native packing test."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def read_member(example):
    for available in example.get('available', []):
        path = Path(available['path'])
        if path.suffix.lower() != '.zip' or not path.is_file():
            continue
        before = path.stat()
        with zipfile.ZipFile(path) as archive:
            entry = archive.getinfo(available['member'])
            if entry.file_size > 16 * 1024 * 1024:
                continue
            content = archive.read(entry)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError('An original archive changed during the read')
        return content
    raise RuntimeError(f"No small original ZIP member for record {example['id']}")


def prepare(profile, inventory):
    if not (profile / 'native-regression.marker').is_file():
        raise ValueError('An owned native test profile is required')
    root = profile / 'packing-real-input'
    examples = {item['id']: item
                for group in json.loads(inventory.read_bytes())['formats']
                for item in group['examples']}
    documents = [(103, '.pdf', 840861), (104, '.djvu', 808806), (105, '.doc', 812349)]
    if 742276 in examples:
        documents.append((109, '.3-pdf', 742276))
    stages = [
        [('text', [(101, '.fb2', 513904), (102, '.epub', 810690), (106, '.rtf', 807675)]),
         ('documents', documents)],
        [('update', [(103, '.pdf', 709156), (107, '.docx', 790607)])],
        [('update', [(102, '.epub', 732671), (108, '.chm', 809048)])],
    ]
    expected = {}
    for number, groups in enumerate(stages):
        folder = root / str(number)
        folder.mkdir(parents=True)
        with zipfile.ZipFile(folder / 'index.inpx', 'w', zipfile.ZIP_DEFLATED) as index:
            index.writestr('structure.info', 'AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG')
            index.writestr('version.info', str(20261101 + number))
            for name, books in groups:
                rows = []
                with zipfile.ZipFile(folder / (name + '.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
                    for identity, ext, sample in books:
                        data = read_member(examples[sample])
                        stem = f'book-{identity}'
                        archive.writestr(stem + ext, data)
                        rows.append('\x04'.join(('Author,Test:', 'prose_contemporary:', stem,
                            'Sample series', '1', stem, str(len(data)), str(identity), '0',
                            ext[1:], '2026-11-01', 'en')))
                        expected[str(identity)] = {'ext': ext, 'sha256': hashlib.sha256(data).hexdigest()}
                        if ext == '.3-pdf':
                            assert data.startswith(b'%PDF-'), 'The malformed-extension fixture must contain a PDF'
                            expected[str(identity)]['export_ext'] = '.pdf'
                index.writestr(name + '.inp', '\n'.join(rows) + '\n')
        (folder / 'expected.json').write_text(json.dumps(expected), encoding='ascii')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
