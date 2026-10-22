# License: GPLv3 Copyright: 2008, Kovid Goyal <kovid at kovidgoyal.net>
# GPL-3.0-only. Adapted read-only subset of calibre, see SOURCE.json and COPYING.
import array
import re
import io
from itertools import chain
from ..compat import ascii_filename
from .meta import LRFMetaFile
from .objects import BookAttr, Font, PageTree, StyleObject, Text, TOCObject, get_object, ruby_tags

class LRFDocument(LRFMetaFile):
    class temp:
        title: str
        title_reading: str
        author: str
        author_reading: str
        book_id: str
        classification: str
        free_text: str
        publisher: str
        label: str
        category: str
        thumbnail: bytes | None
        language: str
        creator: str
        producer: str
        page: str
        thumbnail_extension: str
        dpi: int
        width: int
        height: int

    def __init__(self, stream):
        LRFMetaFile.__init__(self, stream)
        self.scramble_key = self.xor_key
        self.page_trees = []
        self.font_map = {}
        self.image_map = {}
        self.toc = ''
        self.keep_parsing = True

    def parse(self):
        self._parse_objects()
        self.metadata = LRFDocument.temp()
        for a in (
            'title',
            'title_reading',
            'author',
            'author_reading',
            'book_id',
            'classification',
            'free_text',
            'publisher',
            'label',
            'category',
        ):
            setattr(self.metadata, a, getattr(self, a))
        self.doc_info = LRFDocument.temp()
        for a in ('thumbnail', 'language', 'creator', 'producer', 'page'):
            setattr(self.doc_info, a, getattr(self, a))
        self.doc_info.thumbnail_extension = self.thumbail_extension()
        self.device_info = LRFDocument.temp()
        for a in ('dpi', 'width', 'height'):
            setattr(self.device_info, a, getattr(self, a))

    def _parse_objects(self):
        self.objects = {}
        self.decoded_size = 0
        self._file.seek(self.object_index_offset)
        obj_array = array.array('I', self._file.read(4 * 4 * self.number_of_objects))
        if ord(array.array('i', [1]).tobytes()[0:1]) == 0:  # big-endian
            obj_array.byteswap()
        ranges=[]
        for i in range(self.number_of_objects):
            if not self.keep_parsing:
                break
            objid, objoff, objsize = obj_array[i * 4 : i * 4 + 3]
            index_end=self.object_index_offset+16*self.number_of_objects
            if objid in self.objects or objsize<10 or objoff<78 or objoff+objsize>self._size or \
                    (objoff<index_end and objoff+objsize>self.object_index_offset):
                raise ValueError('Invalid LRF object bounds or duplicate ID')
            ranges.append((objoff,objoff+objsize))
            self._file.seek(objoff)
            # Each parser is confined to the indexed object, including tags
            # with malicious length fields. It cannot consume the next object.
            payload=self._file.read(objsize)
            if len(payload)!=objsize:raise ValueError('Incomplete LRF object')
            self._parse_object(objid,io.BytesIO(payload),objsize)
        if any(a[1]>b[0] for a,b in zip(sorted(ranges),sorted(ranges)[1:])):
            raise ValueError('Overlapping LRF objects')
        for obj in self.objects.values():
            if not self.keep_parsing:
                break
            if hasattr(obj, 'initialize'):
                obj.initialize()

    def _parse_object(self, objid, stream, objsize):
        obj = get_object(self, stream, objid, 0, objsize, self.scramble_key)
        self.objects[objid] = obj
        if isinstance(obj, PageTree):
            self.page_trees.append(obj)
        elif isinstance(obj, TOCObject):
            self.toc = obj
        elif isinstance(obj, BookAttr):
            self.ruby_tags = {}
            for h in ruby_tags.values():
                attr = h[0]
                if isinstance(attr, str) and hasattr(obj, attr):
                    self.ruby_tags[attr] = getattr(obj, attr)

    def __iter__(self):
        yield from self.page_trees

    def write_files(self):
        for obj in chain(self.image_map.values(), self.font_map.values()):
            with open(obj.file, 'wb') as f:
                f.write(obj.stream)

    def to_xml(self, write_files=True):
        bookinfo = '<BookInformation>\n<Info version="1.1">\n<BookInfo>\n'
        bookinfo += f'<Title reading="{self.metadata.title_reading}">{self.metadata.title}</Title>\n'
        bookinfo += f'<Author reading="{self.metadata.author_reading}">{self.metadata.author}</Author>\n'
        bookinfo += f'<BookID>{self.metadata.book_id}</BookID>\n'
        bookinfo += f'<Publisher reading="">{self.metadata.publisher}</Publisher>\n'
        bookinfo += f'<Label reading="">{self.metadata.label}</Label>\n'
        bookinfo += f'<Category reading="">{self.metadata.category}</Category>\n'
        bookinfo += f'<Classification reading="">{self.metadata.classification}</Classification>\n'
        bookinfo += f'<FreeText reading="">{self.metadata.free_text}</FreeText>\n</BookInfo>\n<DocInfo>\n'
        th = self.doc_info.thumbnail
        if th:
            prefix = ascii_filename(self.metadata.title)
            bookinfo += '<CThumbnail file="{}" />\n'.format(prefix + '_thumbnail.' + self.doc_info.thumbnail_extension)
            if write_files:
                with open(prefix + '_thumbnail.' + self.doc_info.thumbnail_extension, 'wb') as f:
                    f.write(th)
        bookinfo += f'<Language reading="">{self.doc_info.language}</Language>\n'
        bookinfo += f'<Creator reading="">{self.doc_info.creator}</Creator>\n'
        bookinfo += f'<Producer reading="">{self.doc_info.producer}</Producer>\n'
        bookinfo += f'<SumPage>{self.doc_info.page}</SumPage>\n</DocInfo>\n</Info>\n{self.toc}</BookInformation>\n'
        pages = ''
        done_main = False
        pt_id = -1
        for page_tree in self:
            if not done_main:
                done_main = True
                pages += '<Main>\n'
                close = '</Main>\n'
                pt_id = page_tree.id
            else:
                pages += f'<PageTree objid="{page_tree.id}">\n'
                close = '</PageTree>\n'
            for page in page_tree:
                pages += str(page)
            pages += close
        traversed_objects = [int(i) for i in re.findall(r'objid="(\w+)"', pages)] + [pt_id]

        objects = '\n<Objects>\n'
        styles = '\n<Style>\n'
        for obj in self.objects:
            obj = self.objects[obj]
            if obj.id in traversed_objects:
                continue
            if isinstance(obj, (Font, Text, TOCObject)):
                continue
            if isinstance(obj, StyleObject):
                styles += str(obj)
            else:
                objects += str(obj)
        styles += '</Style>\n'
        objects += '</Objects>\n'
        if write_files:
            self.write_files()
        return '<BBeBXylog version="1.0">\n' + bookinfo + pages + styles + objects + '</BBeBXylog>'
