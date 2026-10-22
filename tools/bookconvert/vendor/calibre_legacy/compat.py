# GPL-3.0-only. Read-only compatibility layer for the pinned calibre subset.
import html
import re
import zlib
from urllib.parse import quote, unquote


class LRFParseError(ValueError): pass
class LitError(ValueError): pass
class DRMError(ValueError): pass


class PRS500_PROFILE:
    default_fonts = {'sans': 'Swis721 BT Roman', 'mono': 'Courier10 BT Roman', 'serif': 'Dutch801 Rm Roman'}


class bounded_zlib:
    @staticmethod
    def decompress(data):
        decoder = zlib.decompressobj()
        result = decoder.decompress(data, 64 * 1024 * 1024 + 1)
        if len(result) > 64 * 1024 * 1024 or not decoder.eof:
            raise LRFParseError('Incomplete or excessive compressed LRF stream')
        return result


def prepare_string_for_xml(value):
    value=str(value).replace('\0','').replace('\f','\n')
    if re.search('[\x01-\x08\x0b\x0e-\x1f]',value):
        raise LRFParseError('Invalid text control in LRF')
    return html.escape(value, quote=False)
def entity_to_unicode_in_python(match): return html.unescape('&' + match[1] + ';')
def ascii_filename(value): return 'cover'
def as_bytes(value): return value.encode('utf-8') if isinstance(value,str) else value
def urlnormalize(value): return quote(unquote(value), safe='/#?=&:;%+@~!$()*,-._')


def xml_text(value):
    if re.search('[\x00-\x08\x0b\x0c\x0e-\x1f]', value):
        raise LRFParseError('Invalid XML characters in LRF metadata')
    return html.escape(value, quote=True)
