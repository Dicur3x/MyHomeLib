"""Add deterministic converter fixtures only inside an owned regression profile."""
from pathlib import Path
from email.message import EmailMessage
import importlib.util
import struct
import subprocess
import sys
import tarfile
import zipfile


def prepare(profile, runtime):
    if not (profile / 'native-regression.marker').is_file(): raise ValueError('Owned profile required')
    target = profile / 'metadata-archive-fixtures'
    if not target.is_dir(): raise ValueError('Base metadata fixtures required')
    tests = Path(__file__).resolve().parents[2] / 'bookconvert/tests'
    spec = importlib.util.spec_from_file_location('converter_fixture_helpers', tests / 'test_legacy_fixed.py')
    helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
    pdf = helpers.pdf_fixture().replace(b'First readable', b'English sample')
    # Same byte length keeps the independent fixture's PDF xref offsets valid.
    (target / 'text-input.pdf').write_bytes(pdf)
    (target / 'text-input.123456').write_bytes(pdf)
    text = b'English fixture preserves complete text. Last sentence.'
    (target / 'text-input.pdb').write_bytes(helpers.pdb_fixture(text))
    (target / 'text-input.tcr').write_bytes(b'!!8-Bit!!' + b''.join(bytes([1,i]) for i in range(256)) + text)
    header = bytearray(128); header[:2] = b'1\xbe'; header[14:18] = struct.pack('<I',128+len(text))
    (target / 'text-input.wri').write_bytes(header + text)
    message = EmailMessage(); message.set_content('<html><body><p>' + text.decode() + '</p></body></html>', subtype='html', charset='utf-8')
    (target / 'text-input.mht').write_bytes(message.as_bytes())
    with zipfile.ZipFile(target / 'numeric-input.zip','w',zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('numeric.317294','<html><body><p>' + text.decode() + '</p></body></html>')
    source = profile / 'djvu-source-fixture.djvu'
    try:
        with tarfile.open(runtime / 'tools/djvu/djvulibre-3.5.29.tar.gz') as archive:
            source.write_bytes(archive.extractfile('djvulibre-3.5.29/doc/djvulibre-book-en.djvu').read())
        output = target / 'text-input.djvu'
        process = subprocess.run([str(runtime/'tools/djvu/djvused.exe'),str(source),'-e',
            'select 1; save-page-with "' + str(output).replace('\\','/') + '"'],capture_output=True,timeout=30,creationflags=0x08000000)
        if process.returncode or not output.is_file(): raise ValueError('DjVu fixture: ' + process.stderr.decode(errors='replace'))
    finally: source.unlink(missing_ok=True)


if __name__ == '__main__': prepare(Path(sys.argv[1]).resolve(),Path(sys.argv[2]).resolve())
