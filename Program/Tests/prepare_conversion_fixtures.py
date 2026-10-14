"""Make synthetic, read-only inputs for the native export worker gate."""
from pathlib import Path
import base64
import importlib.util
import json
import shutil
import sys
import tempfile

repository = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'conversion_fixtures', repository/'tools/bookconvert/tests/test_conversion.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
folder = Path(tempfile.mkdtemp(prefix='HomeLibRu-conversion-native-inputs-')).resolve()
if folder.drive.upper() != 'G:':
    raise RuntimeError('Set TEMP and TMP to the dedicated G work directory')
source = folder/'source.fb2'
source.write_text(fixtures.FB2.replace('{image}', base64.b64encode(fixtures.PNG).decode()), encoding='utf-8')
fixtures.c.convert_book(source, folder/'source.epub')
test = fixtures.ConversionTests()
test.setUp()
try:
    warning = test.generic(css='p {font-weight: bold;}')
    shutil.copy2(warning, folder/'warning.epub')
finally:
    test.tearDown()
print(json.dumps({'folder': str(folder)}, ensure_ascii=False), flush=True)
