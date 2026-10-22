"""Measure existing normalized-field indexes, with no catalogue writes/copies."""
import argparse
import hashlib
import json
import pathlib
import struct
import time

from title_search_readonly_benchmark import stable_source, readonly, MATCH_TABLE, MATCHED
from database_benchmark import digest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CASES = [("extension_pdf", "SearchExt", ".PDF"),
         ("file_name", "SearchFileName", "173905"),
         ("folder_usr", "SearchFolder", "F.USR-")]


def quote(text):
    return "'" + text.replace("'", "''") + "'"


def sql(column, value, after, hide):
    if after:
        escaped = ''.join({'Е': '[ЕЁ]', 'Ё': '[ЕЁ]', '*': '[*]', '?': '[?]', '[': '[[]'}.get(c, c) for c in value)
        predicate = f"b.BookID IN (SELECT fieldmatch.BookID FROM Books fieldmatch WHERE fieldmatch.{column} GLOB {quote('*'+escaped+'*')})"
    else:
        pattern = value.replace('Ё', 'Е').replace('!', '!!').replace('%', '!%').replace('_', '!_')
        predicate = f"REPLACE(REPLACE(b.{column},'Ё','Е'),'ё','е') LIKE {quote('%'+pattern+'%')} ESCAPE '!'"
    return "SELECT DISTINCT b.BookID FROM Books b WHERE " + predicate + (" AND b.IsDeleted=0" if hide else "")


def run(source, output, repeats):
    bits = struct.calcsize('P') * 8
    library = ROOT / 'Program/Out' / ('Bin64' if bits == 64 else 'Bin') / 'sqlite3.dll'
    results, expected = [], {}
    with stable_source(source):
        for repeat in range(repeats):
            for name, column, value in CASES:
                for hide in (True, False):
                    for after in ((False, True) if repeat % 2 == 0 else (True, False)):
                        with readonly(source, library) as db:
                            db.execute(MATCH_TABLE).close()
                            query = sql(column, value, after, hide)
                            plan = list(db.execute('EXPLAIN QUERY PLAN ' + query))
                            cpu, started = time.process_time(), time.perf_counter()
                            db.execute("INSERT INTO temp.MHLGenreMatches SELECT 'probe',BookID FROM (" + query + ")").close()
                            elapsed, cpu = time.perf_counter()-started, time.process_time()-cpu
                            signature = digest(db.execute(MATCHED + ' ORDER BY BookID'))
                            key = (name, hide)
                            if key in expected and signature != expected[key]:
                                raise RuntimeError('Matched identities changed: ' + str(key))
                            expected[key] = signature
                            result = dict(case=name, hide_deleted=hide, variant='after' if after else 'before',
                                          repeat=repeat+1, seconds=elapsed, cpu_seconds=cpu, matched=signature, plan=plan)
                            results.append(result)
                            print(json.dumps({k:v for k,v in result.items() if k!='plan'}), flush=True)
    output.write_text(json.dumps(dict(bits=bits, source_mode='read-only immutable, deny-write lease',
        source_copied=False, limitation='Fresh SQLite connections; shared OS cache; matching only, not UI time.',
        dll_sha256=hashlib.sha256(library.read_bytes()).hexdigest(), results=results), indent=2), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('catalogue', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--repeats', type=int, default=1, choices=(1, 2, 3))
    args = parser.parse_args()
    run(args.catalogue.resolve(), args.output, args.repeats)
