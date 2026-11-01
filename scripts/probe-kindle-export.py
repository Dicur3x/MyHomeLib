"""Round-trip an owned illustrated book through both native Kindle writers.

This checks the actual MOBI7/KF8 containers using the independent KindleUnpack
reader. It does not claim a test on a physical Kindle or on the app's GUI.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

REPO = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    width, height = 256, 384
    rows = b''.join(b'\0' + bytes((row % 256, 100, 180)) * width for row in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def probe(artifacts, report_path, temp_root):
    spec = importlib.util.spec_from_file_location('kindle_probe_conversion', REPO / 'tools/bookconvert/convert_book.py')
    conversion = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(conversion)
    report = dict(status='RUNNING', scope=__doc__.strip(), cases=[], temporary_root_removed=False)
    try:
        with tempfile.TemporaryDirectory(prefix='homelibre-kindle-writer-', dir=temp_root) as folder:
            root = Path(folder).resolve()
            report['temporary_root'] = str(root)
            source = root / 'source.fb2'
            source.write_text('''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>sf</genre><author><first-name>Анна</first-name><last-name>Проверка</last-name></author><book-title>Kindle — проверка</book-title><coverpage><image l:href="#cover"/></coverpage><lang>ru</lang></title-info><document-info><author><nickname>HomeLibre fixture</nickname></author><date value="2026-11-01">2026-11-01</date><id>owned-kindle-writer-fixture</id><version>1</version></document-info></description>
<body><section id="one"><title><p>Первая глава</p></title><p>Ёжик читает книгу. English text. <strong>Жирный текст</strong> и <emphasis>курсив</emphasis>. <a l:href="#note" type="note">1</a></p><image l:href="#cover"/></section><section id="two"><title><p>Вторая глава</p></title><p>Последний абзац — конец книги.</p></section></body>
<body name="notes"><section id="note"><title><p>1</p></title><p>Проверочная сноска.</p></section></body>
<binary id="cover" content-type="image/png">''' + base64.b64encode(png()).decode('ascii') + '</binary></FictionBook>', encoding='utf-8')
            before = digest(source)
            epub = root / 'prepared.epub'
            conversion.convert_book(source, epub)
            epub_hash = digest(epub)
            for platform in ('Win32', 'Win64'):
                component = artifacts / ('KindleExport-' + platform)
                runtime = json.loads((component / 'RUNTIME.json').read_text(encoding='utf-8'))
                writer = component / 'kindling-cli.exe'
                assert runtime['commit'] == '3b91b1ea21f892779be09149f21fe4053b1b3569', runtime
                assert runtime['platform'] == platform and runtime['sha256'] == digest(writer), runtime
                assert '+crt-static' in runtime['rustflags'], runtime
                for extension, expected in (('mobi', 6), ('azw3', 8)):
                    output = root / (platform + '.' + extension)
                    command = [str(writer), 'build', str(epub), '-o', str(output),
                               '--no-embed-source', '--creator-tag']
                    if extension == 'mobi':
                        command.append('--legacy-mobi')
                    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8',
                                            errors='replace', timeout=180,
                                            creationflags=0x08000000 if os.name == 'nt' else 0)
                    case = dict(platform=platform, format=extension, writer_sha256=digest(writer),
                                returncode=result.returncode, stdout=result.stdout[-6000:], stderr=result.stderr[-6000:])
                    report['cases'].append(case)
                    assert result.returncode == 0 and output.is_file(), case
                    data = output.read_bytes()
                    assert data[60:68] == b'BOOKMOBI'
                    count = int.from_bytes(data[76:78], 'big')
                    offsets = [int.from_bytes(data[78+i*8:82+i*8], 'big') for i in range(count)]
                    assert data[offsets[0]+16:offsets[0]+20] == b'MOBI'
                    version = int.from_bytes(data[offsets[0]+36:offsets[0]+40], 'big')
                    assert version == expected, (extension, version)
                    if extension == 'mobi':
                        assert any(data[offset:offset+8] == b'BOUNDARY' for offset in offsets), 'No KF8 half in legacy dual MOBI'
                    restored = root / (platform + '-' + extension + '.epub')
                    tools = REPO / 'Program/Out' / ('Bin' if platform == 'Win32' else 'Bin64') / 'tools'
                    conversion.convert_book(output, restored, tools_root=str(tools))
                    with zipfile.ZipFile(restored) as archive:
                        assert archive.testzip() is None
                        text = '\n'.join(archive.read(name).decode('utf-8') for name in archive.namelist()
                                         if name.lower().endswith(('.xhtml', '.html', '.htm')))
                        for expected_text in ('Первая глава', 'Вторая глава', 'Ёжик читает книгу.',
                                              'English text.', 'Проверочная сноска.', 'Последний абзац'):
                            assert expected_text in text, (extension, expected_text)
                        assert any(name.lower().endswith(('.png', '.jpg', '.jpeg', '.gif')) for name in archive.namelist())
                        assert '<strong' in text or '<b' in text
                        assert '<em' in text or '<i' in text
                    case.update(bytes=len(data), sha256=digest(output), mobi_header_version=version,
                                independent_text_images_notes_roundtrip=True)
            assert digest(source) == before and digest(epub) == epub_hash, 'Source changed'
            report.update(status='PASS', original_source_preserved=True, intermediate_epub_preserved=True)
        report['temporary_root_removed'] = not root.exists()
    except Exception as error:
        report.update(status='FAIL', error=repr(error))
        raise
    finally:
        if 'root' in locals():
            report['temporary_root_removed'] = not root.exists()
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--temp-root', type=Path, required=True)
    args = parser.parse_args()
    probe(args.artifacts.resolve(), args.report.resolve(), args.temp_root.resolve())
