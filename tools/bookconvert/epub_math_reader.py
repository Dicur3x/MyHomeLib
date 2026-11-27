"""Render formulas from a single EPUB chapter for the native reader."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import zipfile


MAX_CHAPTER = 8 * 1024 * 1024
MAX_BATCH = 64 * 1024 * 1024


def load_module(filename):
    spec = importlib.util.spec_from_file_location(filename.stem, filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def formulas(body, math):
    for element in body:
        if element.tag in ('math', '{' + math.MATH + '}math', '{' + math.XHTML + '}math'):
            yield element
        else:
            yield from formulas(element, math)


def render_chapter(source, destination, tools, count):
    scripts = Path(__file__).resolve().parent
    api = load_module(scripts / 'convert_book.py')
    math = load_module(scripts / 'mathml_output.py')
    if not 0 < count <= math.MAX_FORMULAS or source.stat().st_size > MAX_CHAPTER:
        return
    root = api.read_epub_content(source.read_bytes(), set())
    body = api.first(root, 'body')
    if body is None:
        return
    nodes = list(formulas(body, math))
    if len(nodes) != count:
        return

    with tempfile.TemporaryDirectory(prefix='formulas-', dir=destination.parent) as temporary:
        images, _ = math.render(api, nodes, tools, Path(temporary) / 'render')
        if not images:
            return
        remaining = MAX_BATCH
        with zipfile.ZipFile(destination, 'x') as archive:
            for index, node in enumerate(nodes):
                if node not in images:
                    continue
                png, _, _ = images[node]
                size = png.stat().st_size
                if size > remaining:
                    break
                archive.write(png, f'{index}.png')
                remaining -= size


if __name__ == '__main__':
    chapter, output, tools_root, expected_count = sys.argv[1:]
    tempfile.tempdir = str(Path(output).parent)
    render_chapter(Path(chapter), Path(output), Path(tools_root), int(expected_count))
