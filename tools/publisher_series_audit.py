"""Read-only audit of an already indexed HomeLib Ru collection.

Reads a consistent SQLite transaction, including WAL. Never updates books,
archives, series or the application profile. Private reports stay in --output.
"""
import argparse
import collections
import codecs
import csv
import datetime
import html
import json
import pathlib
import re
import sqlite3
import unicodedata
import zipfile
import xml.etree.ElementTree as ET


def normalize(text):
    text = unicodedata.normalize('NFKC', html.unescape(text)).casefold()
    text = ''.join(' ' if c.isspace() or c == '\u25ab' else c
                   for c in text if unicodedata.category(c) != 'Cf')
    return ' '.join(re.findall(r'[^\W_]+', text, re.UNICODE))


def isbn_check(value):
    value = re.sub(r'[^0-9Xx]', '', value)
    if len(value) == 13 and value.isdigit():
        return sum(int(c) * (1 if i % 2 == 0 else 3)
                   for i, c in enumerate(value)) % 10 == 0
    if len(value) == 10 and value[:9].isdigit() and (value[-1].isdigit() or value[-1].upper() == 'X'):
        return sum((10 - i) * (10 if c.upper() == 'X' else int(c))
                   for i, c in enumerate(value)) % 11 == 0
    return False


def local(tag):
    return tag.rsplit('}', 1)[-1]


def inspect_prefix(data):
    """Inspect description only; bodies/binaries are not read or repaired."""
    encoding = re.search(br'encoding\s*=\s*[\'"]([^\'"]+)', data[:512], re.I)
    charset = encoding.group(1).decode('ascii', 'replace') if encoding else 'utf-8-sig'
    try:
        text = codecs.getincrementaldecoder(charset)(errors='strict').decode(data, final=False)
    except (LookupError, UnicodeDecodeError) as error:
        return {'status': 'decode-error', 'encoding': charset, 'error': str(error)}
    end = re.search(r'</(?:[\w.-]+:)?description\s*>', text)
    result = {'encoding': charset, 'description_end': bool(end), 'prefix': text[:1000]}
    version = re.search(r'<\?xml\s+version\s*=\s*[\'"]([^\'"]+)', text)
    result['xml_version'] = version.group(1) if version else None
    if len(data) == 0:
        result['status'] = 'empty-file'
        return result
    if not end:
        result['status'] = 'no-description-end'
        return result
    description_text = text[:end.end()]
    if '<!DOCTYPE' in description_text.upper() or '<!ENTITY' in description_text.upper():
        result['status'] = 'dtd-rejected'
        return result
    root_match = re.search(r'<((?:[\w.-]+:)?FictionBook)\b', description_text)
    if not root_match:
        result['status'] = 'no-fictionbook-root'
        return result
    result['root'] = re.search(r'<[^!?][^>]*>', description_text).group(0)
    try:
        tree = ET.fromstring(description_text + '</' + root_match.group(1) + '>')
        description = next(c for c in tree if local(c.tag) == 'description')
        result['status'] = 'description-readable'
        result['compatibility_notes'] = []
        root_ns = tree.tag.split('}')[0].lstrip('{') if tree.tag.startswith('{') else ''
        desc_ns = description.tag.split('}')[0].lstrip('{') if description.tag.startswith('{') else ''
        if root_ns not in ('', 'http://www.gribuser.ru/xml/fictionbook/2.0',
                            'http://www.gribuser.ru/xml/fictionbook/2.1',
                            'http://www.gribuser.ru/xml/fictionbook/2.2'):
            result['compatibility_notes'].append('Неподдерживаемое пространство имён корня: ' + root_ns)
        if desc_ns and desc_ns != root_ns:
            result['compatibility_notes'].append('Разные пространства имён корня и description: ' + root_ns + ' / ' + desc_ns)
        if any(local(c.tag) == 'binary' for c in list(tree)[:list(tree).index(description)]):
            result['compatibility_notes'].append('binary расположен перед description; быстрый читатель останавливается раньше описания.')
        if result['xml_version'] not in (None, '1.0', '1.1'):
            result['compatibility_notes'].append('Недопустимая версия XML в декларации: ' + result['xml_version'] + '; ElementTree читает фрагмент, MSXML отклоняет файл. Исправление возможно только в отдельной копии после проверки.')
        result['sections'] = []
        for section in description:
            section_name = local(section.tag)
            if section_name not in ('title-info', 'publish-info'):
                continue
            result['sections'].append({
                'section': section_name,
                'series': [dict(e.attrib) for e in section.iter() if local(e.tag) == 'sequence'],
                'isbn': [''.join(e.itertext()) for e in section if local(e.tag) == 'isbn'],
                'title': [''.join(e.itertext()) for e in section if local(e.tag) == 'book-title'],
                'publisher': [''.join(e.itertext()) for e in section if local(e.tag) == 'publisher'],
                'year': [''.join(e.itertext()) for e in section if local(e.tag) == 'year'],
            })
        result['description_xml'] = description_text
    except (ET.ParseError, StopIteration) as error:
        result['status'] = 'invalid-description'
        result['error'] = str(error)
        result['description_xml'] = description_text
    return result


def snapshot(database):
    con = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
    con.create_collation('MHL_SYSTEM_NOCASE', lambda a, b: (a.casefold() > b.casefold()) - (a.casefold() < b.casefold()))
    con.execute('PRAGMA query_only=ON')
    con.execute('BEGIN')
    try:
        counts = {table: con.execute('SELECT count(*) FROM ' + table).fetchone()[0]
                  for table in ('Books', 'PublisherSeries', 'PublisherSeries_List', 'PublisherSeries_Index')}
        series = {sid: {'id': sid, 'name': name, 'books': []}
                  for sid, name in con.execute('SELECT SeriesID, SeriesTitle FROM PublisherSeries')}
        books = {}
        for row in con.execute('SELECT l.SeriesID,l.SeqNumber,b.BookID,b.LibID,b.Title,b.Folder,b.FileName,b.Ext,b.IsDeleted,b.IsLocal,b.Publisher,b.PubYear,b.ISBN '
                               'FROM PublisherSeries_List l JOIN Books b ON b.BookID=l.BookID'):
            sid, number, bid, libid, title, folder, filename, ext, deleted, islocal, publisher, year, isbn = row
            series[sid]['books'].append({'id': bid, 'number': number})
            books[bid] = {'id': bid, 'libid': libid, 'title': title, 'folder': folder,
                          'entry': filename + (ext or ''), 'deleted': deleted, 'local': islocal,
                          'publisher': publisher, 'year': year, 'isbn': isbn, 'authors': [], 'genres': []}
        for bid, authorid, lastname, firstname, middlename in con.execute(
                'SELECT a.BookID,a.AuthorID,n.LastName,n.FirstName,n.MiddleName FROM Author_List a JOIN Authors n ON n.AuthorID=a.AuthorID '
                'WHERE EXISTS (SELECT 1 FROM PublisherSeries_List p WHERE p.BookID=a.BookID)'):
            books[bid]['authors'].append({'id': authorid, 'name': ' '.join(v for v in (lastname, firstname, middlename) if v)})
        genres = {code: {'code': code, 'parent': parent, 'name': name}
                  for code, parent, name in con.execute('SELECT GenreCode,ParentCode,GenreAlias FROM Genres')}
        for bid, code in con.execute('SELECT g.BookID,g.GenreCode FROM Genre_List g WHERE EXISTS '
                                    '(SELECT 1 FROM PublisherSeries_List p WHERE p.BookID=g.BookID)'):
            books[bid]['genres'].append(code)
        formats = [{'extension': ext, 'total': total, 'indexed': indexed} for ext, total, indexed in con.execute(
            'SELECT b.Ext,count(*),sum(CASE WHEN i.BookID IS NOT NULL THEN 1 ELSE 0 END) '
            'FROM Books b LEFT JOIN PublisherSeries_Index i ON i.BookID=b.BookID GROUP BY b.Ext')]
        # Unindexed records are retained in the report, including the 52 FB2 failures.
        unindexed_fb2 = [dict(zip(('id', 'title', 'folder', 'entry'), r)) for r in con.execute(
            "SELECT b.BookID,b.Title,b.Folder,b.FileName||b.Ext FROM Books b WHERE lower(b.Ext)='.fb2' "
            'AND NOT EXISTS (SELECT 1 FROM PublisherSeries_Index i WHERE i.BookID=b.BookID)')]
        return {'time': datetime.datetime.now().astimezone().isoformat(), 'database': str(database),
                'counts': counts, 'series': series, 'books': books, 'genres': genres,
                'formats': formats, 'unindexed_fb2': unindexed_fb2}
    finally:
        con.rollback()
        con.close()


def parse_log(path):
    text = path.read_text(encoding='utf-8-sig')
    pattern = re.compile(r'^Книга (\d+) \((.*?)\): (.*?)\r?\n\s*Источник: (.*?)\r?\n\s*Файл в архиве: (.*?)\r?$', re.M | re.S)
    return [{'id': int(bid), 'title': title, 'error': error.strip(), 'archive': archive.strip(), 'entry': entry.strip()}
            for bid, title, error, archive, entry in pattern.findall(text)]


def extract_sample(root, book):
    archive = pathlib.Path(book.get('archive') or root / book['folder'])
    entry = book['entry']
    try:
        with zipfile.ZipFile(archive) as z:
            info = z.getinfo(entry)
            # Bounded prefix is enough even for multi-gigabyte books with pictures.
            with z.open(info) as stream:
                data = stream.read(2 * 1024 * 1024)
            inspection = inspect_prefix(data)
            if inspection['status'] == 'no-description-end' and info.file_size > len(data):
                with z.open(info) as stream:
                    data = stream.read(16 * 1024 * 1024)
                inspection = inspect_prefix(data)
            return {'id': book['id'], 'archive': str(archive), 'entry': entry,
                    'file_bytes': info.file_size, 'inspected_bytes': len(data),
                    'whole_file_read': info.file_size <= len(data), **inspection}
    except Exception as error:
        return {'id': book['id'], 'archive': str(archive), 'entry': entry,
                'status': 'source-unavailable', 'error': str(error)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=pathlib.Path, required=True)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--log', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--reuse-snapshot', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    data = json.loads((args.output / 'snapshot.json').read_text(encoding='utf-8')) if args.reuse_snapshot else snapshot(args.database)
    data['series'] = {int(k): v for k, v in data['series'].items()}
    data['books'] = {int(k): v for k, v in data['books'].items()}
    (args.output / 'snapshot.json').write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
    print('Snapshot:', data['counts'], 'books with publisher series:', len(data['books']), flush=True)
    errors = parse_log(args.log)
    print('Log failures:', len(errors), flush=True)
    inspected = [extract_sample(args.root, book) for book in errors]
    (args.output / 'errors-inspected.json').write_text(json.dumps({'errors': errors, 'samples': inspected}, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Error descriptions:', dict(collections.Counter(s['status'] for s in inspected)), flush=True)
    generate_report(args, data, errors, inspected)


def generate_report(args, data, errors, error_samples):
    series, books = data['series'], data['books']
    active = [s for s in series.values() if s['books']]
    cases = []

    def add(kind, confidence, items, reason, proposal, numbers=None):
        cases.append({'id': f'R{len(cases) + 1:05d}', 'kind': kind, 'confidence': confidence,
                      'series': [s['id'] for s in items], 'reason': reason, 'proposal': proposal,
                      'numbers': numbers or [], 'book_count': len({b['id'] for s in items for b in s['books']})})

    groups = collections.defaultdict(list)
    for s in active:
        groups[normalize(s['name'])].append(s)
    for key, items in sorted(groups.items()):
        if len(items) > 1:
            add('Варианты написания', 'Вероятно', items,
                'После сравнения регистра, пробелов, знаков пунктуации и HTML-сущностей названия совпадают. Это кандидат, а не доказательство общего издателя или общего состава.',
                'Проверить издателя и состав. Предпочтительно объединить отображение через подтверждённый псевдоним, сохранив исходные названия и возможность отмены.')

    for s in active:
        name = s['name']
        tokens = re.split(r'[,;/]+', name)
        isbn_like = all(re.fullmatch(r'[\dXx\s\-–—]+', t.strip()) and len(re.sub(r'[^0-9Xx]', '', t)) in (10, 13) for t in tokens)
        if isbn_like:
            valid = all(isbn_check(t) for t in tokens)
            add('ISBN вместо серии', 'Вероятно' if valid else 'Проверить', [s],
                'Название имеет форму ISBN; ' + ('контрольная сумма верна.' if valid else 'контрольная сумма хотя бы одного номера не проходит.'),
                'Сверить publish-info/sequence и isbn в оригинале. Предлагать скрытие ошибочной связи, не удалять книгу и не угадывать издательскую серию.')
        if re.search(r'\b(?:18|19|20)\d{2}\b', name) and (re.search(r'журнал|\bstory\b|\b№|№|\d\d[./]\d{4}', name, re.I)):
            add('Год или выпуск в названии', 'Проверить', [s],
                'В названии серии есть год/номер выпуска. Журнал может выступать источником отдельного рассказа; такая связь не обязательно ошибочна.',
                'Сохранить год, выпуск и номер рассказа как отдельные признаки; обсуждать общую родительскую группу журнала, а не уничтожать различия между выпусками.')
        if html.unescape(name) != name:
            add('HTML-сущности в названии', 'Вероятно', [s],
                'В имени осталась буквальная HTML-сущность: ' + name,
                'Показать расшифрованное имя после подтверждения; исходное значение сохранить. Проверить, не возникнет ли совпадение с иной серией.')
        if normalize(name) in ('серия', 'без серии', 'нет', 'none', 'unknown', 'издательская серия', 'n a') or re.search(r'https?://|www\.', name, re.I):
            add('Служебное название', 'Проверить', [s],
                'Похоже на шаблон/ссылку вместо названия. Короткие числовые серии, включая 911, сами по себе не признаются ошибкой.',
                'Проверить исходный FB2 и каталоги; при подтверждении скрыть только ошибочную связь.')
        proposed = []
        for link in s['books']:
            b = books[link['id']]
            if link['number'] == 0:
                match = re.search(r'(?P<year>(?:18|19|20)\d{2}).{0,12}№\s*(?P<annual>\d{1,4})(?:\s*[-–—/]\s*\d{1,4})?\s*(?:\((?P<continuous>\d+)\))?', b['title'])
                if match:
                    proposed.append({'book': b['id'], 'year': int(match['year']), 'annual': int(match['annual']),
                                     'continuous': int(match['continuous']) if match['continuous'] else None})
        if proposed:
            add('Номер отсутствует, выпуск есть в заголовке', 'Проверить', [s],
                f'У {len(proposed)} записей номер в издательской серии пуст, но заголовок содержит год и номер выпуска. Номер внутри года нельзя использовать как сквозной номер всей серии.',
                'Сначала выбрать правило: год+номер отдельными полями либо явно указанный сквозной номер в скобках. Не заполнять порядком файлов или номерами, повторяющимися каждый год.', proposed)

    # Families needing semantic decisions are deliberately not collapsed by normalization.
    families = [s for s in active if re.fullmatch(r'XX(?:I)? век(?:\s*/\s*XXI век)?\s*[-–—.]?\s*(?:&[a-z]+;\s*)?The Best', s['name'], re.I)]
    if families:
        add('Родственные серии — решение вручную', 'Проверить', families,
            'XX век, XXI век и XX век / XXI век сохраняют смысловые различия. Издательство АСТ сейчас объединяет каталог в XX век / XXI век -The Best.',
            'Одобрить общую родительскую группу The Best, сохранив исходные подсерии. Варианты тире внутри каждой подсерии рассматриваются отдельно.')
    zona = [s for s in active if s['name'].upper().startswith('Z.O.N.A')]
    if zona:
        add('Родственные серии — решение вручную', 'Проверить', zona,
            'Общее Z.O.N.A и названия с АТРИ/Бедуин могут отражать отдельные линии. В образцах также указана Фантастическая авантюра. Одинаковый дизайн обложки не доказывает, что подсерии надо слить.',
            'Общая родительская группа Z.O.N.A; сохранить линии АТРИ/Бедуин и их собственную нумерацию. В оригиналах образцов это соседние sequence, а не XML-вложенность.')
    rodina = [s for s in active if 'родина zовёт' in s['name'].casefold()]
    if len(rodina) > 1:
        add('Родственные серии — решение вручную', 'Вероятно', rodina,
            'Названия отличаются пробелами, символом ▫, запятой, Премия/премии и им./имени. Последние различия уже содержательные, поэтому одной замены тире недостаточно.',
            'После проверки издателя подтвердить единое имя серии; сохранить все шесть исходных имён как псевдонимы.')

    selected = set()
    focus = {'"Здоровье"', '978-5-271-32341-6', '911'}
    for s in active:
        if s['name'] in focus or s['name'].casefold().startswith(('homo sapiens.', 'story.', 'story,', 'z.o.n.a', 'xx век', 'xxi век', '«родина zовёт')):
            selected.update(link['id'] for link in s['books'][:2])
    for case in cases:
        if case['kind'] == 'ISBN вместо серии':
            for sid in case['series']:
                selected.update(link['id'] for link in series[sid]['books'])
    for case in [c for c in cases if c['kind'] == 'Варианты написания'][:15]:
        for sid in case['series']:
            selected.update(link['id'] for link in series[sid]['books'][:1])
    samples = [extract_sample(args.root, books[bid]) for bid in sorted(selected)]
    (args.output / 'source-samples.json').write_text(json.dumps(samples, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Review cases:', len(cases), dict(collections.Counter(c['kind'] for c in cases)), 'source samples:', len(samples), flush=True)
    for case in cases:
        case['names'] = [series[sid]['name'] for sid in case['series']]
        case['examples'] = []
        for sid in case['series']:
            s = series[sid]
            for link in s['books'][:3]:
                b = books[link['id']]
                case['examples'].append({'series': sid, 'book': b['id'], 'title': b['title'], 'number': link['number'],
                                         'authors': '; '.join(a['name'] for a in b['authors']),
                                         'genres': '; '.join(data['genres'].get(g, {}).get('name', g) for g in b['genres']),
                                         'source': str(args.root / b['folder']), 'entry': b['entry']})
    summary = {'snapshot_time': data['time'], 'counts': data['counts'], 'nonempty_series': len(active), 'books_with_publisher_series': len(books),
               'cases': len(cases), 'categories': dict(collections.Counter(c['kind'] for c in cases)),
               'errors': len(errors), 'error_status': dict(collections.Counter(s['status'] for s in error_samples)),
               'source_samples': len(samples), 'unindexed_fb2': len(data['unindexed_fb2'])}
    (args.output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    (args.output / 'review-cases.json').write_text(json.dumps(cases, ensure_ascii=False, indent=2), encoding='utf-8')

    def csv_out(name, headers, rows):
        with (args.output / name).open('w', encoding='utf-8-sig', newline='') as f:
            writer = csv.writer(f, delimiter=';')
            writer.writerow(headers)
            # These are text exports, not spreadsheets with executable formulas.
            writer.writerows(["'" + str(v) if isinstance(v, str) and v.startswith(('=', '+', '-', '@')) else v for v in row] for row in rows)
    csv_out('all-series.csv', ['ID серии', 'Название', 'Связей с книгами', 'Книг с пустым номером'],
            ([s['id'], s['name'], len(s['books']), sum(l['number'] == 0 for l in s['books'])] for s in series.values()))
    csv_out('review-cases.csv', ['Случай', 'Категория', 'Уверенность', 'ID серий', 'Названия', 'Книг', 'Основание', 'Предложение'],
            ([c['id'], c['kind'], c['confidence'], ','.join(map(str,c['series'])), ' | '.join(c['names']), c['book_count'], c['reason'], c['proposal']] for c in cases))
    csv_out('series-members.csv', ['ID серии', 'Серия', 'ID книги', 'Название книги', 'Номер серии', 'Автор', 'Жанр', 'Архив', 'Файл', 'Удалена'],
            ([s['id'], s['name'], b['id'], b['title'], l['number'], '; '.join(a['name'] for a in b['authors']),
              '; '.join(data['genres'].get(g, {}).get('name',g) for g in b['genres']), str(args.root / b['folder']), b['entry'], b['deleted']]
             for s in series.values() for l in s['books'] for b in [books[l['id']]]))
    csv_out('proposed-journal-numbers.csv', ['Случай', 'ID серии', 'Серия', 'ID книги', 'Книга', 'Год', 'Выпуск за год', 'Сквозной номер из заголовка'],
            ([c['id'], c['series'][0], c['names'][0], n['book'], books[n['book']]['title'], n['year'], n['annual'], n['continuous'] or ''] for c in cases for n in c['numbers']))
    csv_out('index-errors.csv', ['ID книги', 'Книга', 'Ошибка заполнения', 'Диагноз аудита', 'Размер исходника', 'Архив', 'Файл', 'Деталь'],
            ([e['id'],e['title'],e['error'],s['status'],s.get('file_bytes',''),e['archive'],e['entry'],s.get('error','') or '; '.join(s.get('compatibility_notes', []))] for e,s in zip(errors,error_samples)))
    write_html(args.output, summary, cases, series, books, errors, error_samples, samples)


def write_html(output, summary, cases, series, books, errors, error_samples, samples):
    # No network requests or changes to the collection; review decisions download
    # as a separate JSON file. All source strings render as text, never HTML.
    payload = json.dumps({'summary': summary, 'cases': cases,
                          'errors': [{'book': e, 'sample': s} for e,s in zip(errors,error_samples)],
                          'samples': [{k:v for k,v in s.items() if k not in ('description_xml','prefix')} for s in samples]}, ensure_ascii=False).replace('<','\\u003c')
    page = '''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HomeLib Ru — ревью книжных серий</title><style>
:root{color-scheme:light;--ink:#182a3d;--muted:#56687b;--line:#d8e1ea;--blue:#24579a}*{box-sizing:border-box}body{margin:0;background:#f5f7fa;color:var(--ink);font:16px/1.55 system-ui,Segoe UI,sans-serif}main{max-width:1160px;margin:auto;padding:32px 24px}h1{line-height:1.15;font-size:32px;margin:0 0 12px}h2{font-size:22px;margin-top:32px}h3{font-size:18px}p{max-width:100ch}a{color:var(--blue)}.cards{display:flex;flex-wrap:wrap;gap:12px}.card{background:white;border:1px solid var(--line);padding:16px;flex:1;min-width:160px}.card b{display:block;font-size:26px}.muted,small{color:var(--muted)}details{border:1px solid var(--line);background:white;padding:14px 18px;margin:10px 0}summary{cursor:pointer;font-weight:600}code,pre{font-size:13px;background:#f1f4f8;white-space:pre-wrap;word-break:break-word}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}.scroll{overflow:auto}input,select,button{font:inherit;padding:8px;border:1px solid #bccada;border-radius:5px;background:white}button{cursor:pointer}input{flex:1;min-width:220px}.controls{display:flex;flex-wrap:wrap;gap:10px;position:sticky;top:0;padding:12px 0;background:#f5f7fa;z-index:2}.badge{font-weight:400;font-size:13px;color:var(--muted)}.names{white-space:pre-wrap;overflow-wrap:anywhere}.decision{margin-top:12px;display:flex;gap:8px;flex-wrap:wrap}.good{border-left:4px solid #24816c}.warn{border-left:4px solid #b77a20}.callout{padding:16px 20px;background:#eaf1fb;border-radius:6px}.pagination{display:flex;gap:10px;align-items:center;margin:18px 0}#count{margin:8px 0}.number{font-variant-numeric:tabular-nums}footer{margin:30px 0;color:var(--muted)}@media print{.controls,.decision,.pagination{display:none}details{break-inside:avoid}main{max-width:none;padding:0}}
</style><main><h1>Книжные серии: список для ревью</h1><p>HomeLib Ru · коллекция Flibusta Offline 2 October 2026 · 7 октября 2026</p>
<p class="callout">Названия, номера, связи книг, оригинальные FB2 и архивы не изменены. Кандидат на исправление — повод проверить, а не установленная ошибка. Решения в этом отчёте сохраняются отдельно и ничего не применяют к библиотеке. Перед закрытием или обновлением страницы нажмите «Сохранить решения JSON»: отметки находятся в памяти открытой страницы.</p>
<div class="cards" id="stats"></div><p id="scope" class="muted"></p>
<h2>Семь примеров со скриншотов</h2>
<details open><summary>1. «Здоровье»: пустой номер и число в скобках</summary><p>Колонка № берётся из атрибута <code>publish-info/sequence/@number</code>, а не из заголовка. В проверенных оригиналах номер у серии пуст: программа не потеряла его. В названии «1957 №02 (26)» 02 — выпуск за год, 26 — сквозной выпуск, а не общее количество выпусков. Журнал <a href="https://zdr.ru/o-zhurnale/">издаётся с января 1955 года</a>; 24 выпуска за 1955–1956 годы + 2 дают 26. Это согласуется с другими названиями в вашей коллекции.</p><p>Предложение: год и выпуск показывать отдельно; либо после подтверждения переносить явно записанный сквозной номер. Номера за год повторяются, поэтому просто брать 02 опасно. Полный перечень кандидатов — <a href="proposed-journal-numbers.csv">CSV номеров журналов</a>.</p></details>
<details><summary>2. Шесть имён «Родина Zовёт!»</summary><p>В исходниках различаются им./имени, Премия/премии, запятые, обычные пробелы и символ ▫ (U+25AB). Это шесть настоящих значений метаданных, которые читаются буквально. Проверить состав и издателя, затем одобрить общее имя с сохранением исходных значений как псевдонимов.</p></details>
<details><summary>3. ISBN и настоящая серия 911</summary><p>В проверенном FB2 «Воспоминания о будущем» ISBN 978-5-271-32341-6 действительно записан в <code>publish-info/sequence/@name</code>. Это ошибка описания самой книги; импортёр не перепутал поля. <a href="https://github.com/gribuser/fb2/blob/master/FictionBook.xsd">Схема FB2</a> предусматривает отдельные поля isbn и sequence. Для других цифровых имён проверена форма и контрольная сумма, а конкретные исходники сверены отдельно.</p><p>Предложение: после подтверждения скрывать ошибочную связь; не угадывать серию по ISBN. Короткое имя 911 оставлено настоящей серией и не попадает под правило ISBN.</p></details>
<details><summary>4. Два одинаковых Homo sapiens</summary><p>В одном имени обычные пробелы U+0020, в другом — неразрывные U+00A0. На экране они выглядят одинаково, но исходные значения различаются. Это сильный кандидат на единое отображение после сверки состава. Оригинальные строки доступны в CSV/JSON.</p></details>
<details><summary>5. STORY: год, месяц и отдельные рассказы</summary><p>В FB2 год и выпуск уже включены в имя издательской серии. «Попытка к побегу» — отдельный текст Филатовой из журнала; у него sequence с именем STORY. Журнал 2012 и number="09". Это похоже на номер выпуска за 2012 год, однако по одному атрибуту нельзя уверенно отличить номер выпуска от номера текста. Один файл или несколько файлов внутри такой группы сами по себе не доказывают ошибку.</p><p>Предложение: общий родитель STORY → год → выпуск → тексты. Сначала сверить №9 с журнальным выпуском, затем переносить его в отдельный признак, сохранив исходный номер. Решение о плоском слиянии пока отложить.</p></details>
<details><summary>6. XX / XXI век — The Best</summary><p>Тире, пробелы и буквальные &amp;mdash;/&amp;ndash; дают дубли написания. Такие варианты можно рассмотреть отдельно внутри одинакового названия. <a href="https://ast.ru/series/xx-vek-xxi-vek-the-best-1076611/">АСТ сейчас ведёт каталог «XX век / XXI век -The Best»</a> и описывает в нём «XX век — The Best». Это поддерживает идею общей родительской группы, но не доказывает идентичность всех исторических подсерий.</p><p>Предложение: общий родитель The Best и сохранённые исходные XX/XXI; различие века автоматически не стирать.</p></details>
<details><summary>7. Z.O.N.A., АТРИ и Бедуин</summary><p>Точка в конце — вариант написания. В проверенных FB2 АТРИ/Бедуин указаны отдельными соседними sequence вместе с Фантастической авантюрой; XML-вложенность в этих образцах не задана. У АТРИ есть номера 1 и 2, у сборника Бедуин — 1: это аргумент в пользу сохранения отдельных линий. Обложки подтверждают общий дизайн, но не доказывают равенство серий.</p><p>Предложение: Z.O.N.A как общий родитель для навигации, АТРИ/Бедуин как сохранённые подсерии после вашего подтверждения. Не сливать четыре строки в одну с потерей линий.</p></details>
<h2>Все кандидаты</h2><p>Для каждого случая показаны ID серий, число связанных книг, примеры и предлагаемое действие. Все книги, включая не попавшие в короткие примеры, находятся в <a href="series-members.csv">полном составе серий</a>. Одна серия может иметь несколько признаков, поэтому количества категорий не складываются в число уникальных серий.</p>
<div class="controls"><input id="search" aria-label="Поиск" placeholder="Серия, примеры книг или ID"><select id="category" aria-label="Категория"><option value="">Все категории</option></select><select id="confidence" aria-label="Уверенность"><option value="">Любая уверенность</option><option>Вероятно</option><option>Проверить</option></select><button id="save">Сохранить решения JSON</button></div><p id="count"></p><div id="list"></div><div class="pagination"><button id="prev">Назад</button><span id="page"></span><button id="next">Дальше</button></div>
<h2>52 ошибки повторного заполнения</h2><p id="error-summary"></p><p>22 файла в архивах пустые (0 байт): метаданные восстановить из них невозможно. Предлагается найти исправленные копии/новую раздачу. Есть читаемые описания, которые существующий читатель отвергает из-за namespace или порядка блоков — это кандидаты на улучшение программы. Остальные требуют проверки повреждённого XML. Автоматического ремонта нет.</p><div id="errors"></div>
<h2>Файлы для подробного ревью</h2><ul><li><a href="review-cases.csv">Все кандидаты CSV</a> · <a href="review-cases.json">JSON</a></li><li><a href="all-series.csv">Все 22 443 названия серий</a></li><li><a href="series-members.csv">Все 135 478 связей книг и серий</a></li><li><a href="proposed-journal-numbers.csv">Возможные номера журналов</a></li><li><a href="index-errors.csv">Все ошибки с архивами и именами файлов</a> · <a href="errors-inspected.json">Подробное исследование ошибок</a></li><li><a href="source-samples.json">Проверенные фрагменты метаданных FB2</a></li><li><a href="snapshot.json">Согласованный снимок данных для воспроизводимости</a></li></ul>
<footer>Локальный отчёт. Книги и профиль не отправлялись в интернет. Полный аудит относится к данным коллекции и уже заполненным издательским сериям; он не является проверкой всего текста, изображений или CRC всех архивов 1,5 ТБ. 140 208 записей иных форматов не проходили FB2-читатель, а 52 ошибочных FB2 не имеют успешно заполненного кэша. Их возможные издательские серии неизвестны. Утверждать отсутствие других ошибок в метаданных нельзя.</footer>
</main><script id="data" type="application/json">__DATA__</script><script>
const D=JSON.parse(document.getElementById('data').textContent),$=id=>document.getElementById(id),decisions={},PAGE=30;let page=0;
function el(tag,text,cls){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n}
function fmt(n){return n.toLocaleString('ru-RU')}
for(const [name,value] of [['Записей в коллекции',D.summary.counts.Books],['Непустых серий',D.summary.nonempty_series],['Книг с издательской серией',D.summary.books_with_publisher_series],['Случаев для ревью',D.summary.cases]]){const n=el('div',undefined,'card');n.append(el('b',fmt(value)),el('span',name));$('stats').append(n)}
$('scope').textContent='Снимок: '+D.summary.snapshot_time+'. Проверены все сохранённые названия и связи. Непустые — серии хотя бы с одной книгой; пустые справочные строки в кандидатах не учитываются.';
Object.entries(D.summary.categories).forEach(([k,v])=>{const o=el('option',k+' ('+fmt(v)+')');o.value=k;$('category').append(o)});
function render(){const q=$('search').value.toLocaleLowerCase('ru'),cat=$('category').value,conf=$('confidence').value;const rows=D.cases.filter(c=>(!cat||c.kind===cat)&&(!conf||c.confidence===conf)&&(!q||JSON.stringify(c).toLocaleLowerCase('ru').includes(q)));page=Math.min(page,Math.max(0,Math.ceil(rows.length/PAGE)-1));$('count').textContent='Найдено: '+fmt(rows.length);$('list').replaceChildren();for(const c of rows.slice(page*PAGE,(page+1)*PAGE)){const box=el('details',undefined,c.confidence==='Вероятно'?'good':'warn');box.append(el('summary',c.id+' · '+c.kind+' · '+c.names.join(' / ')));box.append(el('p',c.confidence+' · книг: '+fmt(c.book_count)+' · ID серий: '+c.series.join(', '),'badge'));box.append(el('p',c.reason),el('p','Предложение: '+c.proposal));const wrap=el('div',undefined,'scroll'),table=el('table'),head=el('tr');['Серия / ID','Книга / ID','№','Автор','Жанр','Источник'].forEach(x=>head.append(el('th',x)));table.append(head);for(const b of c.examples){const r=el('tr');[b.series,b.title+' ['+b.book+']',b.number||'—',b.authors,b.genres,b.source+' → '+b.entry].forEach(x=>r.append(el('td',String(x))));table.append(r)}wrap.append(table);box.append(wrap);if(c.numbers.length)box.append(el('p','Кандидатов на номер: '+c.numbers.length+'. Полный список — proposed-journal-numbers.csv.'));const row=el('div',undefined,'decision'),sel=el('select');for(const [v,t] of [['','Не просмотрено'],['approve','Одобрить предложение'],['keep','Оставить как есть'],['discuss','Обсудить отдельно']]){const o=el('option',t);o.value=v;sel.append(o)}sel.value=decisions[c.id]?.decision||'';const note=el('input');note.placeholder='Комментарий к решению';note.value=decisions[c.id]?.note||'';const save=()=>decisions[c.id]={id:c.id,decision:sel.value,note:note.value,series:c.series,names:c.names};sel.onchange=save;note.oninput=save;row.append(sel,note);box.append(row);$('list').append(box)}$('page').textContent=(page+1)+' / '+Math.max(1,Math.ceil(rows.length/PAGE));$('prev').disabled=page===0;$('next').disabled=(page+1)*PAGE>=rows.length}
['search','category','confidence'].forEach(id=>$(id).addEventListener('input',()=>{page=0;render()}));$('prev').onclick=()=>{page--;render()};$('next').onclick=()=>{page++;render()};$('save').onclick=()=>{const a=el('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({source:D.summary.snapshot_time,decisions:Object.values(decisions)},null,2)],{type:'application/json'}));a.download='HomeLibRu-series-review-decisions.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)};
const status={'empty-file':'Пустой файл','description-readable':'Описание читается — проверить совместимость читателя','invalid-description':'Повреждён XML в описании','no-description-end':'Отсутствует закрытие description','decode-error':'Ошибка декодирования','source-unavailable':'Источник недоступен','dtd-rejected':'DTD отклонён'};
$('error-summary').textContent=Object.entries(D.summary.error_status).map(([k,v])=>(status[k]||k)+': '+v).join('; ')+'.';for(const {book:b,sample:s} of D.errors){const box=el('details');box.append(el('summary',b.id+' · '+b.title+' · '+(status[s.status]||s.status)),el('p','Ошибка программы: '+b.error),el('p','Исходник: '+s.archive+' → '+s.entry+'; '+s.file_bytes+' байт'),el('p',s.error||s.root||s.status));for(const note of s.compatibility_notes||[])box.append(el('p',note));if(s.status==='no-description-end')box.append(el('p',s.whole_file_read?'Просмотрен весь файл: закрывающего description нет. Это повреждение исходного XML.':'Просмотрен ограниченный префикс: сначала проверить полный источник.'));if(s.sections)box.append(el('pre',JSON.stringify(s.sections,null,2)));$('errors').append(box)}render();
</script></html>'''
    (output / 'review.html').write_text(page.replace('__DATA__', payload), encoding='utf-8')


if __name__ == '__main__':
    main()
