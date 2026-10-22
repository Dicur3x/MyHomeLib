# GPL-3.0-only. Read-only LRF metadata adapter for calibre's LRFDocument.
# Header fields follow calibre/ebooks/lrf/meta.py at the commit in SOURCE.json.
import io
import struct
from .. import xmlcompat as etree
from ..compat import LRFParseError, bounded_zlib, xml_text


class LRFMetaFile:
    def __init__(self, stream):
        self._file = stream
        stream.seek(0, 2); self._size = stream.tell(); stream.seek(0)
        header = stream.read(88)
        if len(header) < 78 or header[:8] != b'L\0R\0F\0\0\0':
            raise LRFParseError('Invalid LRF header')
        self.version, self.xor_key = struct.unpack_from('<HH', header, 8)
        self.root_object_id = struct.unpack_from('<I', header, 12)[0]
        self.binding, self.color_depth = header[36], header[46]
        self.number_of_objects, self.object_index_offset = struct.unpack_from('<QQ', header, 16)
        if not 0 < self.number_of_objects <= 20000 or self.object_index_offset < 78 or self.object_index_offset + 16 * self.number_of_objects > self._size:
            raise LRFParseError('Invalid LRF object index')
        self.dpi = struct.unpack_from('<H', header, 38)[0]
        self.width, self.height = struct.unpack_from('<HH', header, 42)
        compressed = struct.unpack_from('<H', header, 76)[0]
        self.thumbnail = b''
        self._metadata = {}
        start = 88 if self.version > 800 else 83
        if compressed:
            if compressed < 4 or start + compressed - 4 > self._size:
                raise LRFParseError('Invalid LRF metadata range')
            stream.seek(start)
            data = bounded_zlib.decompress(stream.read(compressed - 4))
            declared = struct.unpack_from('<I', header, 84)[0]
            if len(data) != declared:
                raise LRFParseError('Incomplete LRF metadata')
            tree = etree.fromstring(data, etree.XMLParser(resolve_entities=False, no_network=True))
            for element in tree.iter():
                name = etree.QName(element).localname if isinstance(element.tag, str) else ''
                self._metadata[name] = (''.join(element.itertext()), element.get('reading', ''))
        if self.version > 800:
            self._thumbnail_type, size = struct.unpack_from('<HI', header, 78)
            position = start + max(0, compressed - 4)
            if size > 16 * 1024 * 1024 or position + size > self._size:
                raise LRFParseError('Invalid LRF thumbnail range')
            stream.seek(position); self.thumbnail = stream.read(size)

    def thumbail_extension(self):
        return {0x11: 'jpeg', 0x12: 'png', 0x13: 'bmp', 0x14: 'gif'}.get(getattr(self, '_thumbnail_type', 0), 'bin')

    def __getattr__(self, name):
        fields = {'title': 'Title', 'author': 'Author', 'book_id': 'BookID',
                  'publisher': 'Publisher', 'label': 'Label', 'category': 'Category',
                  'classification': 'Classification', 'free_text': 'FreeText',
                  'language': 'Language', 'creator': 'Creator', 'producer': 'Producer', 'page': 'SumPage'}
        reading = name.endswith('_reading')
        key = name[:-8] if reading else name
        if key not in fields: raise AttributeError(name)
        return xml_text(self._metadata.get(fields[key], ('', ''))[int(reading)])
