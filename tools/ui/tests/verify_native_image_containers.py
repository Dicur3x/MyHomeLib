"""Independently inspect actual native Save As output before fixture cleanup."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile
from PIL import Image


def images(data):
    root = ET.fromstring(data)
    return [base64.b64decode(node.text) for node in root
            if node.tag.endswith('}binary')]


def verify(profile):
    profile = Path(profile).resolve(strict=True)
    assert (profile / 'native-regression.marker').is_file()
    root = profile / 'mixed-save-inputs'
    original = images((root / 'container-profile.fb2').read_bytes())[0]
    with Image.open(io.BytesIO(original)) as source:
        dimensions = source.size
    rows = []
    for mode in range(3):
        for index, quality in enumerate(('balanced', 'economy')):
            folder = root / f'container-{mode}-{index}'
            outputs = list(folder.glob(('*' + ('.fb2', '.zip', '.epub')[mode])))
            assert len(outputs) == 1
            output = outputs[0]
            if mode == 0:
                pictures = images(output.read_bytes())
            else:
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None
                    pictures = (images(archive.read(archive.namelist()[0])) if mode == 1 else
                                [archive.read(n) for n in archive.namelist() if '/images/' in n and not n.endswith('/')])
            assert len(pictures) == 1
            with Image.open(io.BytesIO(pictures[0])) as picture:
                picture.load()
                assert picture.size == dimensions
            rows.append(dict(mode=('FB2','FB2.ZIP','EPUB')[mode], quality=quality,
                             bytes=output.stat().st_size, image_bytes=len(pictures[0]),
                             image_sha256=hashlib.sha256(pictures[0]).hexdigest()))
    assert rows[1]['bytes'] < rows[0]['bytes']
    assert rows[2]['image_sha256'] == rows[3]['image_sha256']
    assert rows[4]['image_sha256'] == rows[5]['image_sha256']
    assert rows[2]['bytes'] + 256 >= rows[3]['bytes']
    assert rows[4]['bytes'] + 256 >= rows[5]['bytes']
    print('PASS independently decoded native raw FB2 FB2.ZIP EPUB profile choices: ' + json.dumps(rows))


if __name__ == '__main__':
    verify(sys.argv[1])
