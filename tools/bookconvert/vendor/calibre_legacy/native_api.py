# GPL-3.0-only. Native decoder bindings used only by the isolated helper process.
import ctypes
from pathlib import Path
from .compat import LitError

_library = None
_library_path = None


def select(path=None):
    global _library_path
    _library_path=path


def configure(path=None):
    global _library
    path = Path(path) if path else Path(__file__).parent/'native/HomeLibLegacy.dll'
    _library = ctypes.CDLL(str(path.resolve()))
    _library.hl_lzx.argtypes = [ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_int,ctypes.c_int]
    _library.hl_lzx.restype = ctypes.c_int
    _library.hl_des.argtypes = [ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int]
    _library.hl_des.restype = ctypes.c_int
    _library.hl_pc1.argtypes = [ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int]
    _library.hl_pc1.restype = ctypes.c_int


def pc1(key,data,decryption=True):
    if len(key)!=16 or len(data)>64*1024*1024:raise LitError('Invalid PC1 block')
    if _library is None:configure(_library_path)
    output=ctypes.create_string_buffer(len(data))
    if _library.hl_pc1(key,data,output,len(data),int(decryption)):raise LitError('Invalid PC1 result')
    return output.raw


class lzx:
    LZXError = LitError
    window = 0

    @staticmethod
    def init(window):
        if not 15 <= window <= 21: raise LitError('Invalid LZX window')
        lzx.window = window

    @staticmethod
    def reset(): pass

    @staticmethod
    def decompress(data, length):
        if not 0 < length <= 64*1024*1024 or len(data) > 64*1024*1024:
            raise LitError('Excessive LZX block')
        if _library is None: configure()
        output = ctypes.create_string_buffer(length)
        if _library.hl_lzx(data,len(data),output,length,lzx.window):
            raise LitError('Incomplete LZX block')
        return output.raw


class msdes:
    EN0, DE1 = 0, 1
    key, mode = b'', 0

    @staticmethod
    def deskey(key, mode):
        if len(key) != 8 or mode not in (0,1): raise LitError('Invalid DES parameters')
        msdes.key,msdes.mode = bytes(key),mode

    @staticmethod
    def des(data):
        if not msdes.key or len(data)%8 or len(data)>64*1024*1024:
            raise LitError('Invalid DES block')
        if _library is None: configure()
        output = ctypes.create_string_buffer(len(data))
        if _library.hl_des(msdes.key,data,output,len(data),msdes.mode): raise LitError('Invalid DES result')
        return output.raw
