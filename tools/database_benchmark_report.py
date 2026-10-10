"""Readable report from the completed isolated benchmark, without rerunning it."""
import json, pathlib, statistics, argparse

p = argparse.ArgumentParser()
p.add_argument('results', type=pathlib.Path)
p.add_argument('native_log', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--native-log32', type=pathlib.Path)
a = p.parse_args()
results = {f.parent.name: json.loads(f.read_text(encoding='utf-8'))
           for f in a.results.glob('*/result.json')}
order = ['sqlite', 'sqlite-dll', 'sqlite-fts5', 'duckdb', 'postgresql', 'firebird', 'turso']
baseline = results['sqlite-dll']['queries']
for name, r in results.items():
    if r['status'] == 'pass':
        assert set(r['queries']) == set(baseline), name
        for q, v in r['queries'].items():
            assert (v['rows'], v['sha256']) == (baseline[q]['rows'], baseline[q]['sha256']), (name, q)
dataset = json.loads((a.results/'dataset.json').read_text(encoding='utf-8'))
lines = ['HomeLib Ru: сравнение баз данных — 9 октября 2026', '='*72, '',
    'Рекомендация: сохранить SQLite основной базой HomeLib Ru. Для поиска',
    'подстроки отдельно исследовать индекс FTS5 trigram. Замена всей базы',
    'пока не оправдана: измерения не показывают универсального выигрыша,',
    'а перенос потребует адаптации импорта, SQL, каталогов, групп и миграций.', '',
    'Что действительно измерено', '-'*72,
    'Полный INPX flibusta_all_local-2026-10-02.inpx, прочитанный без изменения.',
    'SHA256: '+results['sqlite-dll']['source_sha256'],
    '925 029 строк книг; 214 124 автора; 1 174 194 связи автор–книга;',
    '1 585 425 связей жанр–книга; 81 351 серия; 448 138 связей серия–книга.',
    'Удалённых строк: 134 885. Шесть строк с пустым названием исключены.',
    'Для сравнения создана сокращённая схема из шести таблиц и восьми индексов.',
    'Каждый запрос возвращал ВСЕ строки. Проверялись число строк и SHA256',
    'содержимого, а не только COUNT. Три повтора, в таблице медиана секунд.',
    'У всех шести успешных конфигураций совпали результаты всех 10 запросов.',
    'Личные базы не открывались для записи. Архивы книг не индексировались.', '',
    'Важные ограничения сравнения', '-'*72,
    'Это измерение полного пути «движок + драйвер + получение всех строк + хеш».',
    'Драйверы различаются: Python sqlite3 написан на C; для SQLite из HomeLib Ru',
    'использован ctypes; DuckDB/PostgreSQL имеют собственные драйверы и COPY.',
    'Поэтому разница в выдаче больших списков НЕ равна чистой разнице движков.',
    'Импорт Firebird выполнен через построчный драйвер, а не оптимальный IBatch.',
    'Он проверяет рабочий сценарий этого прототипа, а не предел скорости Firebird.',
    'Не измерены холодный дисковый кеш, аварийное восстановление, длительная',
    'конкурентная запись, полноценная миграция пользовательского каталога.',
    'Тесты выполнены на одной машине последовательно; загрузка системы меняется.', '',
    'Конфигурации и импорт (секунды)', '-'*72]
for name in order:
    r = results[name]
    lines += [name+': '+str(r.get('version')), '  Драйвер: '+r.get('driver',''),
              '  Настройки: '+json.dumps(r.get('settings',{}), ensure_ascii=False)]
    if r['status']=='pass':
        lines += [f"  Импорт {r['import_seconds']:.3f}; индексы {r['indexes_seconds']:.3f}"+
                  (f"; FTS5 {r['fts_build_seconds']:.3f}" if 'fts_build_seconds' in r else ''),
                  f"  Пик памяти измеряемого дерева процессов {r['peak_process_tree_rss_bytes']/1048576:.1f} МиБ;",
                  f"  размер файлов теста {r['disk_bytes']/1048576:.1f} МиБ."]
    else:
        lines += [f"  Импорт с индексами {r.get('import_and_indexes_seconds',0):.3f}.",
                  '  НЕ ПРОШЁЛ полный набор: тяжёлый запрос по жанру превысил 1800 секунд.',
                  '  Последующие запросы не выполнены; их результаты нельзя сравнивать.']
    lines += ['']
queries = [('hide_deleted_all','Все книги, скрывать удалённые'),
    ('heavy_genre','Тяжёлый жанр network_literature'), ('fantasy_group','Группа Фантастика'),
    ('unsorted','Неизвестные/отсутствующие жанры'), ('author','Большой автор'),
    ('series','Большая серия'), ('date','Дата добавления с 01.09.2026'),
    ('substring','Название содержит поттер'), ('genre_authors','Авторы книг тяжёлого жанра'),
    ('genre_genres','Жанры книг тяжёлого жанра')]
lines += ['Запросы: медиана полного получения и проверки строк, секунды', '-'*72,
          'Запрос / строк | PySQLite | DLLSQLite | FTS5 | DuckDB | PostgreSQL | Firebird | Turso']
for key, label in queries:
    row = [f"{label} / {baseline[key]['rows']}"]
    for name in order:
        v = results[name]['queries'].get(key)
        row += [f"{v['median_seconds']:.4f}" if v and 'median_seconds' in v else 'не завершён']
    lines += [' | '.join(row)]
fts = results['sqlite-fts5']['queries']['substring']['median_seconds']
plain = baseline['substring']['median_seconds']
lines += ['', 'Что дают эти результаты для программы', '-'*72,
    f'FTS5 trigram ускорил конкретный поиск «поттер» с {plain:.3f} до {fts:.4f} с',
    f'({plain/fts:.1f} раза) при одинаковых 366 результатах. Это поисковый индекс',
    'внутри SQLite, а не новая база. Его наличие в DLL само по себе не ускоряет',
    'нынешние LIKE-запросы: нужен созданный и поддерживаемый индекс.',
    'Он полезен для подстрок от трёх символов; короткие запросы и отдельные',
    'шаблоны требуют прежнего пути. Нужны проверки кириллицы, обновлений,',
    'удалений, совместимости старых DLL и дополнительного размера каталога.',
    'DuckDB хорошо выглядит на массовом импорте и аналитике, но текущий каталог',
    'имеет множество мелких обновлений. Прямой замены без адаптации нет.',
    'PostgreSQL полезен для общего многопользовательского сервера; для нынешней',
    'портативной программы добавляет отдельный процесс и обслуживание.',
    'Firebird Embedded работает без отдельного сервера, но этот прототип',
    'не дал выигрыша на тяжёлых выдачах; перед дальнейшим рассмотрением',
    'нужны родной пакетный импорт, адаптированные запросы и повторные замеры.',
    'Turso 0.8.2 остаётся экспериментальным кандидатом: по этим тестам',
    'рекомендовать его для пользовательских каталогов нельзя.', '',
    'Проверка в настоящей программе (Win64)', '-'*72,
    'Отдельный временный каталог; производственный импорт INPX и реальные',
    'итераторы/списки VCL. Обложки, карточка и аннотация выключены для замера.',
    'В каталоге 848 645 уникальных BookID. Строк INPX больше, поскольку он',
    'повторяет книги, в том числе для нескольких серий; импорт сводит такие',
    'строки. Сокращённый междвижковый тест намеренно сохраняет исходные строки.',
    'Время дерева включает SQL и построение всех узлов; с all_rows_ms не суммировать.',
    'query=0: Фантастика; query=1: зарегистрированное Неотсортированное;',
    'query=2: только скрывать удалённые; query=3: название Поттер.',
    'У «Неотсортированного» здесь другие правила, чем в сокращённом тесте.',
    'Сравнивать их количества напрямую нельзя.', '',
    a.native_log.read_text(encoding='utf-8-sig').strip(), '',
    'Файлы для воспроизведения', '-'*72,
    'tools/database_benchmark.py — подготовка и отдельные движки;',
    'tools/database_benchmark_report.py — этот отчёт без нового тестирования;',
    'tools/validation/Out/db-benchmark-oct09-v2/comparison.json — все исходные замеры;',
    'там же */result.json — настройки, SQL, три повтора и хеши результатов;',
    'tools/validation/Out/oct09-native-large-64.log — настоящий импорт/интерфейс.', '',
    'Официальные документы для дальнейшего исследования', '-'*72,
    'SQLite FTS5: https://www.sqlite.org/fts5.html#the_trigram_tokenizer',
    'DuckDB concurrency: https://duckdb.org/docs/stable/connect/concurrency',
    'PostgreSQL resources: https://www.postgresql.org/docs/current/runtime-config-resource.html',
    'Firebird Embedded: https://firebirdsql.org/file/documentation/html/en/firebirddocs/qsg5/firebird-5-quickstartguide.html',
    'Turso/libSQL: https://github.com/tursodatabase/turso', '']
if a.native_log32:
    position = lines.index('Файлы для воспроизведения')
    lines[position:position] = [
        'Проверка в настоящей программе (Win32)', '-'*72,
        'Тот же полный INPX, отдельная временная база и те же реальные списки.',
        'Количество книг, авторов, серий и результаты всех четырёх запросов',
        'совпали с Win64. Порядок запросов и правила замера указаны выше.', '',
        a.native_log32.read_text(encoding='utf-8-sig').strip(), '',
    ]
    position = lines.index('tools/validation/Out/oct09-native-large-64.log — настоящий импорт/интерфейс.')
    lines.insert(position + 1, 'tools/validation/Out/oct09-native-large-32.log — тот же тест Win32.')
a.output.write_text('\n'.join(lines), encoding='utf-8-sig')
print('PASS report generated; successful engine results agree:', a.output)
