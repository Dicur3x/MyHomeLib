"""Build a HomeLibre online index from a local snapshot of library SQL dumps."""
from argparse import ArgumentParser
from contextlib import closing
from datetime import date, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
import json
import re
import sqlite3
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

# The packaged Windows Python runs with an isolated module search path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mysql_dump import DumpError, read_rows


# These are the public layouts of the two publishers. Column order is read
# from the dump, since older revisions place extra fields in different places.
LIBRARIES = {
    'flibusta': ('Флибуста', 'https://flibusta.is/', 'lib.'),
    'librusec': ('Либрусек', 'https://lib.rus.ec/', ''),
}
SOURCE_SCHEMAS = {
    'flibusta': (
        ('authors', 'libavtorname', 'avtorid lastname firstname middlename', ''),
        ('by_author', 'libavtor', 'bookid avtorid', 'pos'),
        ('genres', 'libgenrelist', 'genreid genrecode', 'genredesc genremeta'),
        ('by_genre', 'libgenre', 'bookid genreid', ''),
        ('series', 'libseqname', 'seqid seqname', ''),
        ('by_series', 'libseq', 'bookid seqid seqnumb', ''),
        ('books', 'libbook', 'bookid title filesize deleted filetype time lang', 'keywords'),
    ),
    'librusec': (
        ('authors', 'libavtors', 'aid lastname firstname middlename', ''),
        ('by_author', 'libavtor', 'bid aid', 'role'),
        ('genres', 'libgenres', 'gid code', 'gdesc'),
        ('by_genre', 'libgenre', 'bid gid', ''),
        ('series', 'libseqs', 'sid seqname', ''),
        ('by_series', 'libseq', 'bid sid sn', ''),
        ('books', 'libbook', 'bid title filesize deleted filetype time lang', 'keywords'),
    ),
}
STAGING_SCHEMA = """
CREATE TABLE authors(id INTEGER PRIMARY KEY, last TEXT, first TEXT, middle TEXT);
CREATE TABLE by_author(book INTEGER, author INTEGER, seq INTEGER,
    PRIMARY KEY(book, author)) WITHOUT ROWID;
CREATE TABLE genres(id INTEGER PRIMARY KEY, code TEXT, name TEXT, category TEXT);
CREATE TABLE by_genre(book INTEGER, genre INTEGER, PRIMARY KEY(book, genre)) WITHOUT ROWID;
CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE by_series(book INTEGER, series INTEGER, number INTEGER,
    PRIMARY KEY(book, series)) WITHOUT ROWID;
CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, size INTEGER, deleted TEXT,
    extension TEXT, added TEXT, language TEXT, keywords TEXT);
"""
METADATA = (
    'SELECT l.book, a.last, a.first, a.middle FROM by_author l JOIN authors a ON a.id=l.author '
    'ORDER BY l.book, l.seq, l.author',
    'SELECT l.book, g.code FROM by_genre l JOIN genres g ON g.id=l.genre ORDER BY l.book, l.genre',
    'SELECT l.book, s.name, l.number FROM by_series l JOIN series s ON s.id=l.series ORDER BY l.book, l.series',
)
FIELDS = 'AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;FOLDER;LANG;KEYWORDS;'
ONLINE_ANY = 0x08010001  # CT_EXTERNAL_ONLINE_NONFB
FIELD_BREAKS = re.compile(r'[\x00-\x1f\x7f]')
EXTENSION = re.compile(r'[a-z0-9]{1,10}')
BOOKS_PER_MEMBER = 10000
MAX_DOWNLOAD = 256 * 1024 * 1024


def clean(value):
    return FIELD_BREAKS.sub(' ', value or '').strip()


def dump_file(folder, prefix, table):
    for suffix in ('.sql.gz', '.sql'):
        path = folder / (prefix + table + suffix)
        if path.is_file():
            return path
    return None


def staging_rows(rows, target, source):
    for row in rows:
        if target == 'by_author':
            book, author, pos = row
            if source == 'librusec':
                # Translators and editors have separate roles in this dump.
                if pos not in (None, '', '\0', 'a'):
                    continue
                pos = 0
            yield book, author, pos
        elif target == 'genres':
            ident, code, name, *category = row
            yield ident, code, clean(name) or code, clean(category[0] if category else '') or LIBRARIES[source][0]
        elif target == 'by_series':
            book, series, number = row
            # INPX can carry integer series numbers. Preserve the membership
            # without silently rounding fractional numbers.
            whole, dot, fraction = (number or '0').partition('.')
            yield book, series, int(whole) if not dot or set(fraction) <= {'0'} else 0
        else:
            yield row


def load_tables(db, source, folder, version, report):
    db.executescript(STAGING_SCHEMA)
    schema = SOURCE_SCHEMAS[source]
    undated = LIBRARIES[source][2]
    prefix = undated
    # Librusec publishes YYYY-MM-DD, while older local bundles often use YYYYMMDD.
    for dated in (date.fromisoformat(version).isoformat() + '.', version + '.'):
        files = [dump_file(folder, dated, table) for _, table, _, _ in schema]
        if all(files):
            prefix = dated
            break
        if prefix == undated and any(files):
            prefix = dated
    for target, table, required, optional in schema:
        path = dump_file(folder, prefix, table)
        if path is None:
            raise DumpError(f'В папке нет файла {prefix}{table}.sql или {prefix}{table}.sql.gz.')
        report(f'Чтение {path.name}')
        required, optional = required.split(), optional.split()
        value_count = 4 if target == 'genres' else len(required) + len(optional)
        values = ','.join('?' for _ in range(value_count))
        # Duplicate relationship rows do not create duplicate book metadata.
        # Duplicate primary catalogue IDs are a damaged snapshot.
        conflict = ' ON CONFLICT DO NOTHING' if target.startswith('by_') else ''
        rows = read_rows(path, table, required, optional)
        with db:
            db.executemany(f'INSERT INTO {target} VALUES ({values}){conflict}', staging_rows(rows, target, source))


class RowsByBook:
    def __init__(self, rows):
        self.rows = iter(rows)
        self.current = next(self.rows, None)

    def take(self, book):
        result = []
        while self.current is not None and self.current[0] <= book:
            if self.current[0] == book:
                result.append(self.current[1:])
            self.current = next(self.rows, None)
        return result


def book_line(book, authors, genres, series):
    ident, title, size, deleted, extension, added, language, keywords = book
    extension = clean(extension).lower().lstrip('.')
    if ident <= 0:
        raise DumpError(f'Недопустимый идентификатор книги {ident}.')
    if not EXTENSION.fullmatch(extension) or extension.isdigit():
        extension = 'bin'
    folder = f'{ident // 1000:04d}\\'
    if extension == 'fb2':
        folder += f'{ident}.fb2.zip'
    try:
        added = date.fromisoformat((added or '')[:10]).isoformat()
    except ValueError:
        added = ''
    author_names = (','.join(clean(part).replace(',', ' ').replace(':', ' ') for part in author)
                    for author in authors)
    genre_codes = (clean(code).replace(':', ' ') for (code,) in genres)
    return '\x04'.join((
        ':'.join(dict.fromkeys(author_names)), ':'.join(dict.fromkeys(genre_codes)),
        clean(title), '\\'.join(clean(name).replace('\\', '/') for name, _ in series),
        ':'.join(str(number) for _, number in series), str(ident), str(max(0, size or 0)),
        str(ident), '1' if deleted == '1' else '0', extension, added,
        folder, clean(language), clean(keywords),
    )) + '\x04\r\n'


def write_index(db, path, source, version, report):
    title, url, _ = LIBRARIES[source]
    header = '\r\n'.join((title, f'{source}-sql.hlc2', str(ONLINE_ANY),
                          'Онлайн-каталог из SQL-дампов', url, 'GET %URL%b/%LIBID%/get', 'CHECK', ''))
    count, = db.execute('SELECT count(*) FROM books').fetchone()
    if count == 0:
        raise DumpError('В SQL-дампе нет книг.')
    authors, genres, series = (RowsByBook(db.execute(query)) for query in METADATA)
    with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        archive.writestr('collection.info', header.encode('utf-8-sig'))
        archive.writestr('structure.info', FIELDS)
        archive.writestr('version.info', version)
        source_info = {'format': 1, 'source': source, 'genres': [
            {'code': clean(code).replace(':', ' '), 'name': name, 'category': category}
            for code, name, category in db.execute('SELECT code,name,category FROM genres ORDER BY id')
        ]}
        archive.writestr('homelibre-sql.json', json.dumps(source_info, ensure_ascii=False).encode('utf-8'))
        book_rows = iter(db.execute('SELECT * FROM books ORDER BY id'))
        for start in range(0, count, BOOKS_PER_MEMBER):
            report(f'Запись каталога {start} / {count}')
            with archive.open(f'books-{start:09d}.inp', 'w') as entry:
                entry.write(b'\xef\xbb\xbf')
                for _ in range(min(BOOKS_PER_MEMBER, count - start)):
                    book = next(book_rows)
                    entry.write(book_line(book, authors.take(book[0]), genres.take(book[0]),
                                          series.take(book[0])).encode('utf-8'))
    report(f'Записано книг {count}')


def build_index(source, folder, output, version, report=lambda _: None):
    if not re.fullmatch(r'(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})', version):
        raise DumpError('Укажите дату комплекта дампов в формате ГГГГММДД или ГГГГ-ММ-ДД.')
    try:
        version = date.fromisoformat(version).strftime('%Y%m%d')
    except ValueError as error:
        raise DumpError('Некорректная дата комплекта дампов.') from error
    if output.suffix.lower() != '.inpx':
        raise DumpError('Имя подготовленного каталога должно оканчиваться на .inpx.')
    with tempfile.TemporaryDirectory(prefix='catalogdump-', dir=output.parent) as temp:
        staging = Path(temp)
        with closing(sqlite3.connect(staging / 'index.sqlite')) as db:
            db.execute('PRAGMA temp_store=FILE')
            # The staging database can be recreated after interruption.
            db.execute('PRAGMA journal_mode=OFF')
            load_tables(db, source, folder, version, report)
            result = staging / 'snapshot.inpx'
            write_index(db, result, source, version, report)
        result.replace(output)


class CatalogueRedirects(HTTPRedirectHandler):
    def __init__(self, host):
        self.host = host

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        address = urlsplit(newurl)
        if (address.scheme != 'https' or address.netloc != self.host
                or not address.path.startswith('/sql/')):
            raise DumpError('Сервер перенаправил запрос за пределы каталога SQL.')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download_index(source, output, report):
    _, base, prefix = LIBRARIES[source]
    opener = build_opener(CatalogueRedirects(urlsplit(base).netloc))
    with tempfile.TemporaryDirectory(prefix='catalogdump-download-', dir=output.parent) as temp:
        root = Path(temp)
        versions = set()
        for _, table, _, _ in SOURCE_SCHEMAS[source]:
            filename = f'{prefix}{table}.sql.gz'
            report(f'Загрузка {filename}')
            request = Request(f'{base}sql/{filename}', headers={'User-Agent': 'HomeLibre'})
            try:
                with opener.open(request, timeout=30) as response:
                    if response.status != 200:
                        raise DumpError(f'Сервер вернул код {response.status}.')
                    modified = response.headers.get('Last-Modified')
                    if not modified:
                        raise DumpError('Сервер не указал дату дампа.')
                    day = parsedate_to_datetime(modified).astimezone(timezone.utc).date()
                    versions.add(day)
                    if len(versions) > 1:
                        raise DumpError('Файлы относятся к разным снимкам. Повторите попытку позже.')
                    expected = response.headers.get('Content-Length')
                    if expected and int(expected) > MAX_DOWNLOAD:
                        raise DumpError('Размер дампа превышает 256 МБ.')
                    with (root / filename).open('wb') as target:
                        size = 0
                        while block := response.read(256 * 1024):
                            size += len(block)
                            if size > MAX_DOWNLOAD:
                                raise DumpError('Размер дампа превышает 256 МБ.')
                            target.write(block)
                        if expected and size != int(expected):
                            raise DumpError('Сервер передал неполный файл.')
            except (OSError, ValueError) as error:
                raise DumpError(f'{filename}: {error}') from error
        build_index(source, root, output, versions.pop().strftime('%Y%m%d'), report)


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('source', choices=LIBRARIES)
    parser.add_argument('output', type=Path)
    parser.add_argument('--folder', type=Path, help='use local dumps instead of downloading')
    parser.add_argument('--version', help='local snapshot date in YYYYMMDD')
    args = parser.parse_args()
    if (args.folder is None) != (args.version is None):
        parser.error('--folder and --version must be used together')

    def report(line):
        print(line, flush=True)

    try:
        if args.folder is None:
            download_index(args.source, args.output, report)
        else:
            build_index(args.source, args.folder, args.output, args.version, report)
    except (OSError, ValueError, sqlite3.Error) as error:
        report(f'Не удалось подготовить каталог. {error}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
