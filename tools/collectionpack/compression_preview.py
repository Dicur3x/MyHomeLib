"""Bounded, byte-exact illustration pairs for the pre-commit quality viewer."""
import base64
import hashlib
import json
from pathlib import Path
from xml.etree import ElementTree as ET
import zipfile

MAX_PAIRS = 12
MAX_IMAGE = 8 * 1024 * 1024
MAX_BYTES = 48 * 1024 * 1024
NAMESPACE = '{http://www.gribuser.ru/xml/fictionbook/2.0}'


def image_kind(data):
    for signature, kind in ((b'\x89PNG\r\n\x1a\n', 'png'), (b'\xff\xd8\xff', 'jpg'),
                            (b'GIF8', 'gif'), (b'BM', 'bmp')):
        if data.startswith(signature):
            return kind
    return None


def fb2_images(path, limit, check):
    images, seen, total = {}, set(), 0
    for _, node in ET.iterparse(path, events=['end']):
        check()
        if node.tag == NAMESPACE + 'binary':
            identity = node.get('id', '')
            text = ''.join((node.text or '').split())
            if identity and len(text) <= MAX_IMAGE * 4 // 3 + 8:
                try:
                    data = base64.b64decode(text, validate=True)
                except ValueError:
                    data = b''
                if data and len(data) <= MAX_IMAGE and image_kind(data):
                    if identity in seen:
                        images.pop(identity, None)  # Ambiguous IDs cannot be paired reliably.
                    elif len(images) < limit and total + len(data) <= MAX_BYTES // 2:
                        images[identity] = data
                        total += len(data)
                    seen.add(identity)
            node.clear()
    return images


class ComparisonPreview:
    """No resized thumbnails: the viewer receives the actual before/after bytes."""
    def __init__(self, directory, check):
        self.path = Path(directory) / 'comparison.zip'
        self.check, self.pairs, self.bytes = check, [], 0
        self.archive, self.limited, self.keep, self.owned = None, False, False, False

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close()
        if self.owned and (kind is not None or not self.keep):
            self.path.unlink(missing_ok=True)

    def add_pair(self, member, image, before, after):
        self.check()
        if len(self.pairs) >= MAX_PAIRS or self.bytes + len(before) + len(after) > MAX_BYTES:
            self.limited = True
            return False
        if not image_kind(before) or not image_kind(after):
            return True
        if max(len(before), len(after)) > MAX_IMAGE:
            self.limited = True
            return True
        if self.archive is None:
            self.archive = zipfile.ZipFile(self.path, 'x', compression=zipfile.ZIP_STORED)
            self.owned = True
        index = len(self.pairs)
        first, second = f'{index:02d}-before', f'{index:02d}-after'
        self.archive.writestr(first, before)
        self.archive.writestr(second, after)
        self.pairs.append(dict(member=member, image=image, before=first, after=second,
                               before_bytes=len(before), after_bytes=len(after)))
        self.bytes += len(before) + len(after)
        return True

    def add_book(self, original, result, extension, member):
        remaining = MAX_PAIRS - len(self.pairs)
        if remaining <= 0:
            self.limited = True
            return
        if extension == '.fb2':
            before = fb2_images(original, remaining, self.check)
            after = fb2_images(result, remaining, self.check)
            for name in before:
                if name not in after:
                    continue
                if not self.add_pair(member, name, before[name], after[name]):
                    break
        elif extension in {'.epub', '.docx', '.odt', '.cbz'}:
            with zipfile.ZipFile(original) as old, zipfile.ZipFile(result) as new:
                available = set(new.namelist())
                for item in old.infolist():
                    self.check()
                    if item.is_dir() or item.file_size > MAX_IMAGE or item.filename not in available:
                        continue
                    if Path(item.filename).suffix.lower() not in {'.png', '.jpg', '.jpeg', '.gif', '.bmp'}:
                        continue
                    other = new.getinfo(item.filename)
                    if other.file_size > MAX_IMAGE:
                        self.limited = True
                        continue
                    if not self.add_pair(member, item.filename, old.read(item), new.read(other)):
                        break

    def finish(self):
        if self.archive is None:
            return None
        self.archive.writestr('comparison.json', json.dumps(dict(schema=1, pairs=self.pairs,
                              limited=self.limited), ensure_ascii=False).encode('utf-8'))
        self.archive.close()
        self.archive = None
        return dict(path=str(self.path), sha256=hashlib.sha256(self.path.read_bytes()).hexdigest(),
                    pairs=len(self.pairs))

    def close(self):
        if self.archive:
            self.archive.close()
            self.archive = None
