"""Read-only real-book converter audit; every extracted/output payload is temporary."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

from prepare_catalogue_examples import prepare


def run(inventory, runtime, selection, report):
    repository=Path(__file__).resolve().parents[2]
    python=runtime/'tools/kindle/python/python.exe'
    rows=[]
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-convert-probe-') as temporary:
        root=Path(temporary);(root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        prepare(inventory,root,selection)
        examples=json.loads((root/'catalogue-examples/examples.json').read_text(encoding='utf-8'))['examples']
        for item in examples:
            source=root/'catalogue-examples'/item['name']
            for extension in ['.fb2','.epub']:
                output=root/('output'+extension);details=root/'report.json';started=time.perf_counter()
                row={'id':item['id'],'extension':item['extension'],'target':extension,'source_sha256':item['sha256']}
                try:
                    process=subprocess.run([str(python),'-I','-B','-X','utf8',str(repository/'tools/bookconvert/convert_book.py'),
                        str(source),str(output),'--tools-root',str(runtime/'tools'),'--report',str(details)],
                        capture_output=True,timeout=1200,creationflags=0x08000000)
                    if process.returncode or not output.is_file():
                        raise ValueError((process.stdout+process.stderr).decode('utf-8',errors='replace')[-2200:])
                    if extension=='.epub':
                        with zipfile.ZipFile(output) as archive:
                            tree=ET.fromstring(archive.read('OEBPS/book.xhtml'))
                            pictures=[hashlib.sha256(archive.read(n)).hexdigest() for n in archive.namelist() if '/images/' in n]
                    else:
                        tree=ET.parse(output).getroot()
                        pictures=[hashlib.sha256(base64.b64decode(n.text or '')).hexdigest() for n in tree if n.tag.endswith('}binary')]
                    text=''.join(tree.itertext())
                    row.update(result='ok',size=output.stat().st_size,text_length=len(text),pictures=pictures,
                               warnings=json.loads(details.read_text(encoding='utf-8-sig')).get('warnings',[]))
                except (ValueError,OSError,subprocess.TimeoutExpired,ET.ParseError,zipfile.BadZipFile) as error:
                    row.update(result='error',error=str(error))
                finally:
                    row['seconds']=round(time.perf_counter()-started,3)
                    row['source_unchanged']=hashlib.sha256(source.read_bytes()).hexdigest()==item['sha256']
                    output.unlink(missing_ok=True);details.unlink(missing_ok=True)
                rows.append(row)
                report.write_text(json.dumps({'rows':rows,'payloads_removed':False},ensure_ascii=False,indent=2),encoding='utf-8')
                print(json.dumps({k:v for k,v in row.items() if k not in {'pictures','warnings','source_sha256'}},ensure_ascii=False),flush=True)
            source.unlink()
    report.write_text(json.dumps({'rows':rows,'payloads_removed':True},ensure_ascii=False,indent=2),encoding='utf-8')
    return all(row['result']=='ok' and row['source_unchanged'] for row in rows)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory',type=Path);parser.add_argument('runtime',type=Path)
    parser.add_argument('selection');parser.add_argument('report',type=Path)
    args=parser.parse_args()
    raise SystemExit(0 if run(args.inventory.resolve(),args.runtime.resolve(),args.selection,args.report.resolve()) else 1)
