"""Read PE icons as data, without running an executable or using the shell cache."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct


def ico_images(path):
    data = Path(path).read_bytes()
    reserved, kind, count = struct.unpack_from('<HHH', data)
    assert (reserved, kind) == (0, 1) and count == 9
    images = {}
    for index in range(count):
        width, height, _, _, _, _, size, offset = struct.unpack_from('<BBBBHHII', data, 6 + index * 16)
        images[(width or 256, height or 256)] = data[offset:offset + size]
    return images


def check(executable, main_icon, reader_icon):
    dll = ctypes.WinDLL('kernel32', use_last_error=True)
    pointer = ctypes.c_void_p
    dll.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, pointer, ctypes.c_uint32]
    dll.LoadLibraryExW.restype = pointer
    dll.FindResourceW.argtypes = [pointer, pointer, pointer]
    dll.FindResourceW.restype = pointer
    dll.SizeofResource.argtypes = [pointer, pointer]
    dll.SizeofResource.restype = ctypes.c_uint32
    dll.LoadResource.argtypes = [pointer, pointer]
    dll.LoadResource.restype = pointer
    dll.LockResource.argtypes = [pointer]
    dll.LockResource.restype = pointer
    dll.FreeLibrary.argtypes = [pointer]
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_int, pointer, pointer, pointer, ctypes.c_ssize_t)
    dll.EnumResourceNamesW.argtypes = [pointer, pointer, callback_type, ctypes.c_ssize_t]
    # Both flags read the resource directory as data; no executable code runs.
    module = dll.LoadLibraryExW(str(Path(executable).resolve()), None, 0x22)
    if not module:
        raise ctypes.WinError(ctypes.get_last_error())
    groups = []
    def read(name, kind):
        name_buffer = ctypes.c_wchar_p(name) if isinstance(name, str) else pointer(name)
        identifier = ctypes.cast(name_buffer, pointer) if isinstance(name, str) else name_buffer
        resource = dll.FindResourceW(module, identifier, pointer(kind))
        if not resource:
            raise ctypes.WinError(ctypes.get_last_error())
        address = dll.LockResource(dll.LoadResource(module, resource))
        return ctypes.string_at(address, dll.SizeofResource(module, resource))
    def images(name):
        data = read(name, 14)
        reserved, kind, count = struct.unpack_from('<HHH', data)
        assert (reserved, kind) == (0, 1) and count == 9
        result = {}
        for index in range(count):
            width, height, _, _, _, _, size, identifier = struct.unpack_from('<BBBBHHIH', data, 6 + index * 14)
            image = read(identifier, 3)
            assert len(image) == size
            result[(width or 256, height or 256)] = image
        return result
    @callback_type
    def collect(_module, _kind, name, _parameter):
        groups.append(ctypes.wstring_at(name) if name > 0xffff else int(name))
        return 1
    try:
        if not dll.EnumResourceNamesW(module, pointer(14), collect, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        assert groups[0] == 'MAINICON', ('Reader resource displaced the application icon', groups)
        assert images('MAINICON') == ico_images(main_icon), 'Application icon differs from its source'
        assert images('ZZ_HOME_LIBRE_READER_ICON') == ico_images(reader_icon), 'Reader window icon is missing or incomplete'
    finally:
        dll.FreeLibrary(module)
    return dict(status='PASS', executable=str(Path(executable).resolve()),
                sha256=hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                icon_groups=groups, sizes=sorted(width for width, _ in ico_images(reader_icon)),
                executable_not_run=True, application_icon_preserved=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--main-icon', type=Path, required=True)
    parser.add_argument('--reader-icon', type=Path, default=Path('Program/Resources/reader.ico'))
    args = parser.parse_args()
    print(json.dumps(check(args.executable, args.main_icon, args.reader_icon)))
