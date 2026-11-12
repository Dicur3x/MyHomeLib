"""Read-only, content-addressed image history for incremental compression.

The native commit stores hashes only after publishing a verified book. Lookups
are scoped to a compression profile, independent of book names and file IDs.
No table is created and no source database is modified by preparation.
"""
from collections import OrderedDict
from pathlib import Path
import re
import sqlite3

from pack_collection import PackingError

TABLE = 'HomeLibreCompressedImages'


class CompressedImageHistory:
    def __init__(self, database, profile_sha256, check=lambda: None):
        self.path = Path(database).absolute() if database else None
        self.profile = profile_sha256
        self.check = check
        self.connection = None
        self.enabled = False
        self.cache = OrderedDict()

    def __enter__(self):
        self.check()
        if self.path is None:
            return self
        try:
            self.connection = sqlite3.connect(self.path.as_uri()+'?mode=ro', uri=True, timeout=.5)
            self.connection.execute('PRAGMA query_only=ON')
            self.connection.execute('PRAGMA trusted_schema=OFF')
            self.connection.execute('PRAGMA cache_size=-1024')
            self.enabled = self.connection.execute(
                'SELECT 1 FROM sqlite_master WHERE type=? AND name=?', ('table', TABLE)).fetchone() is not None
        except sqlite3.Error as error:
            self.__exit__(None, None, None)
            raise PackingError('Не удалось прочитать историю сжатия изображений. Книги не изменены.') from error
        return self

    def contains(self, image_sha256):
        self.check()
        if not isinstance(image_sha256, str) or not re.fullmatch('[0-9a-f]{64}', image_sha256):
            raise PackingError('Некорректная контрольная сумма изображения.')
        if not self.enabled:
            return False
        if image_sha256 in self.cache:
            self.cache.move_to_end(image_sha256)
            return self.cache[image_sha256]
        try:
            result = self.connection.execute(
                f'SELECT 1 FROM {TABLE} WHERE ProfileSHA256=? AND ImageSHA256=?',
                (self.profile, image_sha256)).fetchone() is not None
        except sqlite3.Error as error:
            raise PackingError('Не удалось проверить историю сжатия изображения. Книги не изменены.') from error
        self.cache[image_sha256] = result
        if len(self.cache) > 2048:
            self.cache.popitem(last=False)
        return result

    def __exit__(self, kind, value, traceback):
        if self.connection is not None:
            self.connection.close()
            self.connection = None
        self.enabled = False
        self.cache.clear()
