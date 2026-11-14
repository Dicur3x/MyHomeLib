"""Read-only, content-addressed image history for incremental compression.

The native commit stores hashes only after publishing a verified book. Lookups
are scoped to a compression profile, independent of book names and file IDs.
No table is created and no source database is modified by preparation.
"""
from collections import OrderedDict
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3

from pack_collection import Canceled, PackingError

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

    def legacy_books(self, source, members, profile, grayscale):
        """Read only the old packer's own, profile-matched payload witnesses.

        The caller must still hash the extracted book and compare it with this
        witness. Names, book IDs and dates alone never authorize reuse.
        """
        self.check()
        if self.connection is None:
            return {}
        try:
            if self.connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                                       "AND name='HomeLibPackingState'").fetchone() is None:
                return {}
            root = self.path.parent.resolve(strict=True)
            physical = Path(source).resolve(strict=True)
            if not physical.is_relative_to(root):
                return {}
            relative = str(physical.relative_to(root))
            if Path(relative).parts[:1] != ('archives',):
                return {}
            state = dict(self.connection.execute("SELECT Key,Value FROM HomeLibPackingState "
                                                "WHERE Key IN ('dataset','engine','images')"))
            engine = 'illustrations-gray-ppmd' if grayscale else 'illustrations-ppmd'
            if state.get('engine') != engine or state.get('images') != profile:
                return {}
            marker = root / 'HomeLibRu-compressed.json'
            if not 0 < marker.stat().st_size <= 4096:
                raise ValueError('Invalid legacy marker size')
            saved = json.loads(marker.read_text(encoding='utf-8-sig'))
            if (not isinstance(saved, dict) or saved.get('version') != 1 or
                    not isinstance(state.get('dataset'), str) or not state['dataset'] or
                    (saved.get('dataset'), saved.get('engine'), saved.get('images')) !=
                    (state['dataset'], engine, profile)):
                raise ValueError('Legacy catalogue and payload root disagree')
            journal = root / 'packing.sqlite'
            with closing(sqlite3.connect(journal.as_uri() + '?mode=ro', uri=True, timeout=.5)) as db:
                db.execute('PRAGMA query_only=ON')
                db.execute('PRAGMA trusted_schema=OFF')
                db.execute('PRAGMA cache_size=-1024')
                # payloads is immutable. Very early copies had only sources.
                table = 'payloads' if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' "
                    "AND name='payloads'").fetchone() else 'sources'
                rows = db.execute(f'SELECT length(CAST(members AS BLOB)) FROM {table} WHERE folder=?', (relative,)).fetchall()
                if len(rows) != 1 or not 0 < rows[0][0] <= 64 * 1024 * 1024:
                    raise ValueError('Missing or oversized legacy payload witness')
                # SQLite streams the selected fields; do not materialize a
                # 100,000-book archive's entire JSON tree in Python.
                query = db.execute(f"SELECT json_extract(j.value,'$.filename'),"
                    "json_extract(j.value,'$.ext'),json_extract(j.value,'$.payload_sha256'),"
                    "json_extract(j.value,'$.fbd'),json_extract(j.value,'$.loose') "
                    f"FROM {table} p,json_each(p.members) j WHERE p.folder=? AND "
                    "json_extract(j.value,'$.image_result')='optimized'", (relative,))
                result = {}
                for filename, extension, digest, fbd, loose in query:
                    self.check()
                    if (fbd or loose or not isinstance(filename, str) or
                            not re.fullmatch('[0-9a-f]{32}', filename) or
                            extension not in ('.fb2', '.epub', '.djvu', '.djv', '.dju', '.djm', '.djvm') or
                            not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)):
                        continue
                    member = filename + extension
                    if member not in members:
                        continue
                    witness = dict(profile_sha256=self.profile, output_sha256=digest, retry_original=False)
                    if member in result and result[member] != witness:
                        raise ValueError('Conflicting legacy payload witnesses')
                    result[member] = witness
                return result
        except Canceled:
            raise
        except (OSError, sqlite3.Error, ValueError, TypeError) as error:
            raise PackingError('Не удалось проверить историю прежней сжатой копии. '
                               'Книги не изменены; повторное сжатие изображений не выполнялось.') from error

    def __exit__(self, kind, value, traceback):
        if self.connection is not None:
            self.connection.close()
            self.connection = None
        self.enabled = False
        self.cache.clear()
