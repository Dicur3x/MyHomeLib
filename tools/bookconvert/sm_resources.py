"""Read SM companion media from the original folder/archive, never the network.

An extracted/renamed source may live in the reader cache. Its real container
and member are supplied by the application, not by an executable book script.
"""
import base64
import hashlib
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit
import zipfile

from sm_input import Story, StoryError


class MissingStoryImage(StoryError):
    pass


class StoryResources:
    MAX_IMAGE = 16 * 1024 * 1024

    def __init__(self, source, source_sha256, root=None, container=None, member=None):
        self.root = Path(root).resolve() if root else Path(source).resolve().parent
        self.container, self.base, self.names = None, None, {}
        if bool(container) != bool(member):
            raise StoryError('Не указан исходный архив или имя интерактивной книги в нём.')
        if container:
            member = str(member).replace('\\', '/')
            if member.startswith('/') or ':' in member or '\0' in member or '..' in member.split('/'):
                raise StoryError('Недопустимое имя исходника в архиве интерактивной книги.')
            self.container = zipfile.ZipFile(Path(container))
            try:
                if len(self.container.infolist()) > 100000:
                    raise StoryError('В исходном архиве слишком много файлов.')
                for entry in self.container.infolist():
                    self.names.setdefault(entry.filename.replace('\\', '/').casefold(), []).append(entry)
                original = self._entry(str(member).replace('\\', '/'))
                if original is None or original.file_size > Story.MAX_SOURCE:
                    raise StoryError('Не найден исходник интерактивной книги в её архиве.')
                raw = self.container.read(original)
                if hashlib.sha256(raw).hexdigest() != source_sha256:
                    raise StoryError('Подготовленный SM не совпадает с исходником в архиве. Картинки не подменялись.')
                self.base = PurePosixPath(str(member).replace('\\', '/')).parent
            except BaseException:
                self.close(); raise

    def _entry(self, name):
        entries = self.names.get(name.casefold(), [])
        if len(entries) > 1:
            raise StoryError('В архиве несколько файлов с одним именем: ' + name[:200])
        return entries[0] if entries else None

    def image(self, href):
        if not isinstance(href, str) or not href or len(href) > 65536:
            raise StoryError('Повреждён путь иллюстрации интерактивной книги.')
        if href.startswith('data:'):
            header, separator, payload = href.partition(',')
            if not separator or not header.lower().startswith('data:image/') or ';base64' not in header.lower():
                raise StoryError('Неподдерживаемые данные иллюстрации интерактивной книги.')
            if len(payload) > (self.MAX_IMAGE + 2) // 3 * 4:
                raise StoryError('Иллюстрация интерактивной книги превышает 16 МБ.')
            try: data = base64.b64decode(payload, validate=True)
            except ValueError as error: raise StoryError('Повреждены данные встроенной иллюстрации.') from error
            if len(data) > self.MAX_IMAGE: raise StoryError('Иллюстрация интерактивной книги превышает 16 МБ.')
            return data
        address = urlsplit(href)
        if address.scheme or address.netloc:
            raise MissingStoryImage('Внешняя иллюстрация не скачивалась: ' + href[:200])
        name = unquote(address.path)
        if ('\\' in name or '\0' in name or ':' in name or name.startswith('/') or
                any(part in {'..', ''} for part in name.split('/'))):
            raise StoryError('Недопустимый путь иллюстрации интерактивной книги.')
        if self.container:
            entry = self._entry(str(self.base / name))
            if entry is None:
                raise MissingStoryImage('В исходном архиве отсутствует иллюстрация: ' + name[:200])
            if entry.is_dir() or entry.flag_bits & 1 or entry.file_size > self.MAX_IMAGE:
                raise StoryError('Иллюстрация в архиве повреждена, защищена или превышает 16 МБ.')
            data = self.container.read(entry)
        else:
            path = (self.root / name).resolve()
            if not path.is_relative_to(self.root): raise StoryError('Иллюстрация находится вне папки книги.')
            try:
                with path.open('rb') as stream: data = stream.read(self.MAX_IMAGE + 1)
            except FileNotFoundError as error:
                raise MissingStoryImage('В папке книги отсутствует иллюстрация: ' + name[:200]) from error
        if len(data) > self.MAX_IMAGE: raise StoryError('Иллюстрация интерактивной книги превышает 16 МБ.')
        return data

    def close(self):
        if self.container is not None: self.container.close(); self.container = None

    def __enter__(self): return self
    def __exit__(self, *error): self.close()
