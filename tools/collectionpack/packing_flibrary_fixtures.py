"""Generated FLibrary sidecar layouts; only owned synthetic inputs are written."""
import hashlib
import io
import json
from pathlib import Path
import zipfile

from packing_format_fixtures import fixtures
from supervised_test_process import run_owned


def build(root, seven, repository, reviewed=False):
    fixture = root / 'packing-flibrary-epub'
    source = fixture / 'source'
    source.mkdir(parents=True)
    original = repository / 'tools/ui/tests/fixtures/reconstruct-original.jpg'
    encoded = repository / 'tools/ui/tests/fixtures/reconstruct-encoded.jxl'
    books, _ = fixtures()
    with zipfile.ZipFile(io.BytesIO(books['two.epub'])) as archive:
        assets = {name: archive.read(name) for name in archive.namelist()}
    if reviewed:
        from PIL import Image
        import random
        picture = Image.frombytes('RGB', (480, 640), random.Random(915).randbytes(480 * 640 * 3))
        encoded_picture = io.BytesIO()
        picture.save(encoded_picture, format='JPEG', quality=98)
        assets['OPS/Images/арт 1.jpg'] = encoded_picture.getvalue()
    assets['OPS/Images/cover.jpg'] = original.read_bytes()
    assets['OPS/Images/alias.jpg'] = assets['OPS/Images/cover.jpg']
    assets['OPS/book.opf'] = assets['OPS/book.opf'].replace(b'</manifest>',
        b'<item id="alias" href="Images/alias.jpg" media-type="image/jpeg"/></manifest>')
    assets['OPS/chapter.xhtml'] = assets['OPS/chapter.xhtml'].replace(b'</body>',
        b'<img src="Images/alias.jpg" alt="Repeated cover"/></body>')
    image_names = ['OPS/Images/cover.jpg', 'OPS/Images/alias.jpg', 'OPS/Images/арт 1.jpg']
    manifest = dict(books=[], archives=3, files={}, strict_epub=True,
                    neighbor_sha256=hashlib.sha256(b'Unselected neighbor must survive.\x00\xff' * 200).hexdigest())

    def signature(data):
        return hashlib.sha256(data).hexdigest()

    def archive(destination, entries, kind):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if kind == 'zip':
            with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
                for name, data in entries.items():
                    output.writestr(name, data, compress_type=zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED)
        else:
            work = fixture / ('build-' + str(len(list(fixture.glob('build-*')))))
            work.mkdir()
            for name, data in entries.items():
                path = work / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            process = run_owned([str(seven), 'a', '-t7z', '-mx=0', '-ms=off', '-y', '-bb0', '--',
                str(destination), *entries], cwd=work, capture_output=True, timeout=60)
            assert process.returncode == 0, process.stderr.decode('utf-8', errors='replace')
            assert destination.read_bytes().startswith(b'7z\xbc\xaf\x27\x1c')
        return destination.read_bytes()

    layouts = [(101, False, 'zip', -1), (201, True, '7z', -1), (401, False, 'zip', 0)]
    if reviewed:
        layouts.append((501, False, 'zip', -1))
    for number, nested, side_kind, cover_number in layouts:
        destination_root = fixture / 'incoming' if number == 501 else source
        name = {101: 'zip-epub', 201: 'nested-epub', 401: 'zero-cover', 501: 'arrived'}[number]
        outer_name = name + '.7z'
        stripped = {key: data for key, data in assets.items() if key not in image_names}
        stripped['FLibraryImageIndex.json'] = json.dumps([
            dict(id=image_names[0], num=cover_number), dict(id=image_names[1], num=cover_number),
            dict(id=image_names[2], num=1)], ensure_ascii=False).encode('utf-8')
        inner = fixture / f'{number}.epub'
        archive(inner, stripped, '7z' if nested else 'zip')
        entries = {f'{number}.epub': inner.read_bytes(), 'neighbor.bin': b'Unselected neighbor must survive.\x00\xff' * 200}
        companions = ['images/' + name + '.' + side_kind]
        pictures = {f'{number}/1': assets[image_names[2]]}
        covers = {}
        if cover_number == -1:
            companions.append('covers/' + name + '.' + side_kind)
            covers[str(number)] = encoded.read_bytes()
        else:
            pictures[f'{number}/0'] = encoded.read_bytes()
        complete = fixture / f'{number}-original.epub'
        archive(complete, assets, 'zip')
        book = dict(id=str(number), archive=outer_name, wanted=f'{number}.epub',
            ext='.epub', inside=0, sha256=signature(inner.read_bytes()), size=complete.stat().st_size,
            assets={key: signature(data) for key, data in assets.items()}, companions=companions,
            cover_width=32, cover_height=24, image_count=3)
        if number == 501:
            manifest['incoming_book'] = book
        else:
            manifest['books'].append(book)
        if number == 201:
            fb2 = ('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
                'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Sidecar FB2</book-title>'
                '<coverpage><image l:href="#cover"/></coverpage></title-info></description><body><section>' +
                '<p>Keep this text and the complete FB2 body.</p>' * 40 +
                '<image l:href="#1"/></section></body></FictionBook>')
            entries['301.fb2'] = fb2.encode('utf-8')
            pictures['301/1'] = assets[image_names[2]]
            covers['301'] = encoded.read_bytes()
            manifest['books'].append(dict(id='301', archive=outer_name, wanted='301.fb2', ext='.fb2', inside=-1,
                sha256=signature(entries['301.fb2']), size=len(entries['301.fb2']), fb2_xml=fb2,
                assets={'cover': signature(original.read_bytes()), '1': signature(assets[image_names[2]])},
                companions=companions, cover_width=32, cover_height=24, image_count=2))
        archive(destination_root / outer_name, entries, '7z')
        archive(destination_root / companions[0], pictures, side_kind)
        if covers:
            archive(destination_root / companions[1], covers, side_kind)
    manifest['files'] = {str(path.relative_to(source)).replace('\\', '/'): signature(path.read_bytes())
                         for path in source.rglob('*') if path.is_file()}
    if reviewed:
        manifest['incoming_files'] = {str(path.relative_to(fixture / 'incoming')).replace('\\', '/'): signature(path.read_bytes())
                                      for path in (fixture / 'incoming').rglob('*') if path.is_file()}
    (fixture / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False), encoding='utf-8')
    return dict(books=len(manifest['books']), archives=manifest['archives'],
                files=manifest['files'], incoming_files=manifest.get('incoming_files', {}),
                external_cover_jxl_sha256=signature(encoded.read_bytes()))
