"""Small generated FB2 fixtures for native illustration/text hit-test checks."""
import base64
from pathlib import Path
import struct
import zlib


def prepare(directory: Path):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data))

    width, height = 591, 402
    # Distinct neutral bands keep the illustration visible without introducing
    # any lime pixels that could be mistaken for the independent search marker.
    rows = b''.join(b'\x00'+bytes([40+(y//20)%8*25])*(width*3) for y in range(height))
    image = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    image += chunk(b'IDAT', zlib.compress(rows))+chunk(b'IEND', b'')
    header = ('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
              'xmlns:l="http://www.w3.org/1999/xlink"><description><title-info>'
              '<book-title>Иллюстрация и выделение</book-title><lang>ru</lang>'
              '</title-info></description><body><section><image l:href="#picture"/>'
              '<subtitle>Сходство ребёнка и котёнка</subtitle>'
              '<p>Лицевой профиль ребёнка вызывает чувство эстетического восприятия. '
              'Здесь должен выделяться обычный текст под большой иллюстрацией.</p>')
    for name, following in [('illustrated-selection.fb2', 1), ('illustrated-selection-dense.fb2', 36)]:
        # The second case exercises a bounded text lookahead containing many
        # picture objects; small compressed PNGs have a large native RTF form.
        body = '<image l:href="#picture"/>'*following
        binary = '<binary id="picture" content-type="image/png">'+base64.b64encode(image).decode('ascii')+'</binary>'
        (directory/name).write_text(header+body+'</section></body>'+binary+'</FictionBook>', encoding='utf-8')
