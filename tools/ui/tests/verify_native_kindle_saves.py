"""Independently decode native Save As results before the owned profile is removed."""
import base64
import importlib.util
from pathlib import Path
import sys
import tempfile
import zipfile


def verify(profile, runtime, root):
    profile, runtime = Path(profile).resolve(), Path(runtime).resolve()
    if (profile / 'native-regression.marker').read_text(encoding='utf-8') != 'HomeLib Ru isolated native regression v1':
        raise ValueError('Only an owned regression profile is allowed')
    source = Path(__file__).resolve().parents[2] / 'bookconvert/convert_book.py'
    spec = importlib.util.spec_from_file_location('native_kindle_reference', source)
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    inputs = profile / 'kindle-save-fixtures'
    def body_text(path):
        texts = []
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if not name.lower().endswith(('.xhtml', '.html', '.htm')):
                    continue
                document = api.xhtml(archive.read(name))
                if any(api.tag(node) == 'nav' for node in document.iter()):
                    continue
                texts.extend(''.join(node.itertext()) for node in document.iter() if api.tag(node) == 'body')
        return ''.join(''.join(texts).split())
    djvu_reference = None
    document = api.xml((inputs / 'source.fb2').read_bytes())
    picture = next(base64.b64decode(node.text) for node in document.iter() if api.tag(node) == 'binary')
    count = 0
    for mode, extension in ((6, '.mobi'), (8, '.azw3')):
        for quality in ('original', 'none', 'raster', 'collision'):
            folder = inputs / (f'raster-{mode}-original' if quality == 'raster' else
                               f'collision-{mode}' if quality == 'collision' else f'{mode}-{quality}')
            if not folder.exists():
                if quality == 'raster':
                    continue
                raise ValueError('Missing native output folder: ' + folder.name)
            books = sorted(folder.glob('*' + extension))
            expected = 4 if quality == 'raster' else 2
            if len(books) != expected:
                raise ValueError('Missing per-book native outputs: ' + folder.name)
            for book in books:
                count += 1
                output = root / f'{count}.epub'
                api.convert_book(book, output, tools_root=str(runtime / 'tools'))
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None
                    images = [name for name in archive.namelist()
                              if name.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp'))]
                    if quality == 'raster':
                        if book.stem == 'source':
                            # This DjVuLibre manual page has usable OCR and no
                            # separate illustrations; it intentionally reflows.
                            # Compare its full text against the source decoder,
                            # rather than demanding a fabricated page picture.
                            if djvu_reference is None:
                                reference = root / 'djvu-source-reference.epub'
                                api.convert_book(profile / 'mixed-save-inputs/source.djvu', reference,
                                                 tools_root=str(runtime / 'tools'))
                                djvu_reference = body_text(reference)
                            assert len(djvu_reference) > 100 and djvu_reference in body_text(output), ('DjVu source text lost', book)
                        else:
                            assert images, ('Missing scan page images', book)
                    else:
                        text = '\n'.join(archive.read(name).decode('utf-8') for name in archive.namelist()
                                         if name.lower().endswith(('.xhtml', '.html', '.htm')))
                        for expected_text in ('Ёжик читает книгу.', 'English text.', 'Последний абзац', 'Проверочная сноска.'):
                            assert expected_text in text, (book, expected_text)
                        if quality == 'none':
                            assert not images, ('No-images export retained illustrations', book)
                        else:
                            assert any(archive.read(name) == picture for name in images), ('Original image changed', book)
    print(f'PASS independent native Kindle output decoding books={count}; text notes original images and no-images results verified')


def main(profile, runtime):
    profile = Path(profile).resolve()
    if (profile / 'native-regression.marker').read_text(encoding='utf-8') != 'HomeLib Ru isolated native regression v1':
        raise ValueError('Only an owned regression profile is allowed')
    with tempfile.TemporaryDirectory(prefix='kindle-reference-', dir=profile) as folder:
        verify(profile, runtime, Path(folder))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
