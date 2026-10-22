"""Compare bounded real DjVu decoding before/after batching, including pixels.

Only extracts one selected member into an automatically cleaned test directory.
The page-count reply alone is restricted to a prefix; both variants still use
the real DjVuLibre, source pages, layout analysis and illustration encoder.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import shutil
import subprocess
import sys
import tempfile
import time
import types
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/bookconvert'))
sys.path.insert(0, str(ROOT/'tools/diagnostics'))
from prepare_catalogue_examples import prepare
import convert_book as converter
import text_inputs


def load_current():
    spec = importlib.util.spec_from_file_location('batch_fixed_layout', ROOT/'tools/bookconvert/fixed_layout.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def run(options):
    reference = types.ModuleType('unbatched_fixed_layout')
    exec(subprocess.check_output(['git', 'show', options.baseline+':tools/bookconvert/fixed_layout.py'], cwd=ROOT), reference.__dict__)
    engines = {'before': reference, 'after': load_current()}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-djvu-batch-benchmark-') as temporary:
        profile = Path(temporary)
        (profile/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        prepare(options.inventory, profile, 'id:'+str(options.book_id))
        source = next(p for p in (profile/'catalogue-examples').iterdir() if p.suffix != '.json')
        original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        expected = None; results = []
        for repeat in range(2):
            for variant in (('before','after') if repeat == 0 else ('after','before')):
                engine = engines[variant]; calls = []; progress = []; warnings = set()
                def process(args, **kwargs):
                    if args[0].endswith('djvused.exe') and args[args.index('-e')+1] == 'n':
                        kwargs['stdout'].write(str(options.pages).encode('ascii'))
                        return subprocess.CompletedProcess(args, 0, stderr=b'')
                    calls.append(Path(args[0]).name)
                    return subprocess.run(args, **kwargs)
                engine.subprocess = types.SimpleNamespace(run=process, PIPE=subprocess.PIPE,
                                                         TimeoutExpired=subprocess.TimeoutExpired)
                book = text_inputs.Book(converter, source, warnings, tools_root=options.tools,
                                        progress=lambda stage, page, total: progress.append((stage,page,total)))
                started = time.perf_counter(); engine.read_djvu(book, options.tools)
                elapsed = time.perf_counter()-started
                signature = {'body_sha256':hashlib.sha256(ET.tostring(book.body)).hexdigest(),
                             'images':{name:hashlib.sha256(value[0]).hexdigest() for name,value in book.resources.items()},
                             'warnings':sorted(warnings), 'progress':progress}
                if expected is None: expected = signature
                if signature != expected: raise AssertionError('Text/layout/images/warnings/progress changed')
                results.append({'variant':variant, 'seconds':elapsed, 'processes':len(calls),
                                'images':len(book.resources), 'identical':True})
                print(variant, round(elapsed,3), 'seconds;',len(calls),'processes; exact content match',flush=True)
        if hashlib.sha256(source.read_bytes()).hexdigest() != original_hash:
            raise AssertionError('Source changed')
        # A missing text layer inside a batch must still stop before a file is
        # published. Remove it ONLY from a second disposable extracted copy.
        scan = profile/'missing-text.djvu'; shutil.copyfile(source,scan)
        subprocess.run([str(options.tools/'djvu/djvused.exe'),'-s','-e','select 2; remove-txt',str(scan)],
                       check=True,capture_output=True,timeout=40,creationflags=0x08000000)
        scan_hash = hashlib.sha256(scan.read_bytes()).hexdigest(); output=profile/'must-not-exist.epub'
        try: converter.convert_book(scan,output,tools_root=options.tools)
        except converter.ConversionError as error:
            if 'странице 2' not in str(error): raise
        else: raise AssertionError('Missing inner OCR layer was silently accepted')
        if output.exists() or hashlib.sha256(scan.read_bytes()).hexdigest()!=scan_hash:
            raise AssertionError('Failed conversion published a partial book or changed its input')
    report = {'pages':options.pages,'baseline':options.baseline,'source_unchanged':True,
              'temporary_payloads_removed':True,'missing_inner_text_stops_without_output':True,'results':results,
              'median_seconds':{name:statistics.median(r['seconds'] for r in results if r['variant']==name)
                                for name in engines}}
    options.report.write_text(json.dumps(report,indent=2),encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory',type=Path,required=True)
    parser.add_argument('--tools',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--book-id',type=int,default=777324)
    parser.add_argument('--pages',type=int,default=17)
    parser.add_argument('--baseline',default='1204f8b0')
    options=parser.parse_args()
    if not 1 <= options.pages <= 32: parser.error('Benchmark prefix must be 1..32 pages')
    run(options)
