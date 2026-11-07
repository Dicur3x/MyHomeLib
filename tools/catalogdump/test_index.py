import gzip
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase, main
from unittest.mock import patch
import zipfile

from build_index import SOURCE_SCHEMAS, build_index, download_index
from mysql_dump import DumpError


def sql(table, columns, rows):
    def literal(value):
        if value is None:
            return 'NULL'
        if isinstance(value, int):
            return str(value)
        return "'" + value.replace('\\', '\\\\').replace("'", "''").replace('\0', '\\0').replace('\n', '\\n') + "'"

    definitions = ',\n'.join(f'`{column}` varchar(255)' for column in columns)
    values = ',\n'.join('(' + ','.join(map(literal, row)) + ')' for row in rows)
    return (f'SET NAMES utf8mb4;\nCREATE TABLE `{table}` (\n{definitions}\n);\n'
            f'INSERT INTO `{table}` VALUES\n{values};\n').encode()


def fixture(source):
    authors = [(1, "О’Брайен", 'Анна', ''), (2, 'Другой', 'Автор', ''), (3, 'Переводчик', 'Иван', '')]
    by_author = ([(1002, 1, 2), (1002, 2, 1)] if source == 'flibusta'
                 else [(1002, 1, 'a'), (1002, 2, '\0'), (1002, 3, 't')])
    genres = [(1, 'sf', 'Фантастика'), (2, 'child_prose', 'Детская проза')]
    if source == 'flibusta':
        genres = [(*genre, 'Жанры источника') for genre in genres]
    by_genre = [(1002, 1), (1002, 2), (1002, 1)]
    series = [(1, 'Первая'), (2, 'Вторая')]
    by_series = [(1002, 1, '1.00'), (1002, 2, '2.50')]
    books = [(1002, "Альфа's\nГлава", 125, '0', 'FB2', '2026-10-19 22:01:00', 'ru', 'ключ'),
             (1003, 'Бета', 395, '1', 'epub', '0000-00-00 00:00:00', 'be', None),
             (1004, 'Архив', 57, '0', '7z', '2026-10-19 22:01:00', 'en', None)]
    rows_by_table = (authors, by_author, genres, by_genre, series, by_series, books)
    for (_, table, required, optional), rows in zip(SOURCE_SCHEMAS[source], rows_by_table):
        # Both publishers can add columns and reorder them.
        columns = (required + ' ' + optional).split()
        yield table, sql(table, columns[::-1], [row[::-1] for row in rows])


def read_entries(index):
    with zipfile.ZipFile(index) as archive:
        assert archive.testzip() is None
        header = archive.read('collection.info').decode('utf-8-sig').splitlines()
        version = archive.read('version.info').decode()
        records = archive.read('books-000000000.inp').decode('utf-8-sig').splitlines()
    return header, version, [line.split('\x04') for line in records]


class CatalogDumpTests(TestCase):
    def test_local_snapshots(self):
        for source, prefix in (('flibusta', 'lib.'), ('librusec', '20261019.'),
                               ('librusec', '2026-10-19.')):
            with self.subTest(source=source, prefix=prefix), TemporaryDirectory() as temp:
                folder = Path(temp)
                for i, (table, payload) in enumerate(fixture(source)):
                    name = folder / (prefix + table + '.sql')
                    if i % 2:
                        with gzip.open(str(name) + '.gz', 'wb') as handle:
                            handle.write(payload)
                    else:
                        name.write_bytes(payload)
                output = folder / 'online.inpx'
                build_index(source, folder, output, '2026-10-19')
                header, version, records = read_entries(output)
                with zipfile.ZipFile(output) as archive:
                    metadata = json.loads(archive.read('homelibre-sql.json'))
                self.assertEqual(metadata['source'], source)
                self.assertEqual(metadata['genres'][0]['code'], 'sf')
                self.assertEqual(metadata['genres'][0]['name'], 'Фантастика')
                self.assertEqual(header[5:], ['GET %URL%b/%LIBID%/get', 'CHECK'])
                self.assertEqual(version, '20261019')
                self.assertEqual([r[7] for r in records], ['1002', '1003', '1004'])
                self.assertEqual(records[0][1:5], ['sf:child_prose', "Альфа's Глава", 'Первая\\Вторая', '1:0'])
                expected_authors = ['Другой,Автор,', 'О’Брайен,Анна,']
                if source == 'librusec':
                    expected_authors.reverse()
                self.assertEqual(records[0][0].split(':'), expected_authors)
                self.assertEqual(records[0][11], '0001\\1002.fb2.zip')
                self.assertEqual(records[1][8:12], ['1', 'epub', '', '0001\\'])
                self.assertEqual(records[2][9], '7z')
                before = output.read_bytes()
                (folder / (prefix + 'libbook.sql')).write_bytes(b'not a dump')
                with self.assertRaises(DumpError):
                    build_index(source, folder, output, '20261019')
                self.assertEqual(output.read_bytes(), before)
                self.assertFalse(list(folder.glob('catalogdump-*')))

    def test_dated_local_snapshot_does_not_use_undated_tables(self):
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            dumps = dict(fixture('librusec'))
            for table, payload in dumps.items():
                (folder / f'{table}.sql').write_bytes(payload)
            (folder / '2026-10-19.libbook.sql').write_bytes(dumps['libbook'])
            for table, payload in dumps.items():
                if table != 'libbook':
                    (folder / f'20261019.{table}.sql').write_bytes(payload)
            output = folder / 'catalog.inpx'
            with self.assertRaisesRegex(DumpError, '2026-10-19.libavtors'):
                build_index('librusec', folder, output, '20261019')
            self.assertFalse(output.exists())

    def test_downloads_are_one_snapshot(self):
        class Response(io.BytesIO):
            status = 200

        class Opener:
            def __init__(self, days):
                self.dumps = dict(fixture('flibusta'))
                self.days = iter(days)

            def open(self, request, *, timeout):
                self_test.assertTrue(request.full_url.startswith('https://flibusta.is/sql/lib.'))
                table = request.full_url.removeprefix('https://flibusta.is/sql/lib.').removesuffix('.sql.gz')
                payload = gzip.compress(self.dumps[table])
                response = Response(payload)
                response.headers = {'Last-Modified': next(self.days), 'Content-Length': str(len(payload))}
                return response

        self_test = self
        snapshot_day = 'Mon, 19 Oct 2026 22:00:00 GMT'
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            output = folder / 'online.inpx'
            with patch('build_index.build_opener', return_value=Opener([snapshot_day] * 7)):
                download_index('flibusta', output, lambda _: None)
            self.assertEqual(read_entries(output)[1], '20261019')
            before = output.read_bytes()
            with patch('build_index.build_opener', return_value=Opener([
                    snapshot_day, 'Tue, 20 Oct 2026 22:00:00 GMT'])):
                with self.assertRaisesRegex(DumpError, 'разным снимкам'):
                    download_index('flibusta', output, lambda _: None)
            self.assertEqual(output.read_bytes(), before)
            self.assertFalse(list(folder.glob('catalogdump-*')))


if __name__ == '__main__':
    main()
