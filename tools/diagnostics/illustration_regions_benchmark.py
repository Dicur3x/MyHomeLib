"""Compare pixel-identical illustration regions against the published code."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess
import time
import types

ROOT = Path(__file__).resolve().parents[2]


def run(book, renderer, output):
    old = types.ModuleType('published_fixed_layout')
    exec(subprocess.check_output(['git', 'show', 'ae79cbf3:tools/bookconvert/fixed_layout.py'], cwd=ROOT), old.__dict__)
    spec = importlib.util.spec_from_file_location('current_fixed_layout', ROOT/'tools/bookconvert/fixed_layout.py')
    current = importlib.util.module_from_spec(spec); spec.loader.exec_module(current)
    def fail(message): raise ValueError(message)
    before = book.stat()
    image = subprocess.run([str(renderer), '-format=ppm', '-page=1', '-size=1600x1600', str(book)],
                           check=True, capture_output=True, timeout=40, creationflags=0x08000000).stdout
    rgb, width, height = current.ppm(image, fail)
    paper = b'\xff\xff\xff'*(width*height)
    # Fractional corner medians, channels at the threshold and masking are
    # included alongside the actual rendered DjVu page.
    boundary = bytes([207, 208, 255, 255, 207, 208, 208, 255, 207, 48, 49, 0])*(width*height//4+1)
    cases = [('real_page', rgb, []), ('blank', paper, []),
             ('thresholds', boundary[:len(rgb)], [{'text':'mask','box':(0,0,width/2,height/2)}])]
    results = []
    for name, pixels, lines in cases:
        reference = None; timings = {'before': [], 'after': []}
        for repeat in range(3):
            for variant in (('before', 'after') if repeat % 2 == 0 else ('after', 'before')):
                module = old if variant == 'before' else current
                started = time.perf_counter()
                result = module.illustration_regions(pixels, width, height, lines, width, height)
                timings[variant].append(time.perf_counter()-started)
                if reference is None: reference = result
                if result != reference: raise AssertionError('Illustration rectangles/ink changed: '+name)
        results.append({'case': name, 'width': width, 'height': height,
                        'regions': len(reference[0]), 'ink_fraction': reference[1],
                        'median_seconds': {k:statistics.median(v) for k,v in timings.items()},
                        'samples_seconds': timings, 'identical': True})
    after = book.stat()
    if (before.st_size,before.st_mtime_ns) != (after.st_size,after.st_mtime_ns):
        raise RuntimeError('Input changed during benchmark')
    report = {'source_read_only': True, 'rendered_rgb_sha256':hashlib.sha256(rgb).hexdigest(), 'results':results}
    output.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(results,indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book',type=Path);parser.add_argument('renderer',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();run(args.book,args.renderer,args.output)
