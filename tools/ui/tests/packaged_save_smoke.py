"""Drive ordinary packaged Main Save As with Computer Use and owned books.

Stage one starts with the exact minimal catalogue and no optional modules.
After a normal exit, verify byte-exact copies, install only five verified local
components through native installer units, then reopen for mixed conversion.
No user catalogue or download/restart success is inferred from this check.
"""
import argparse
import configparser
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import shutil
import sqlite3
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import unquote
import zipfile
from doc_save_conversion_probe import read_doc_sample, verify_output

ROOT = Path(__file__).resolve().parents[3]
TAG = 'optional-alreader-2.5.1009.25'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unpack(source, target):
    with zipfile.ZipFile(source) as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            assert not name.startswith(('/', '\\')) and '\\' not in name and ':' not in name
            assert '..' not in Path(name).parts
        manifest = json.loads(archive.read('HomeLibRu.update.json'))
        for item in manifest['files']:
            value = archive.read(item['path'])
            assert len(value) == item['size'] and hashlib.sha256(value).hexdigest() == item['sha256']
        archive.extractall(target)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path)
    parser.add_argument('--platform', choices=('Win32', 'Win64'), required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--doc-inventory', type=Path, default=ROOT / 'tools/ui/tests/Out/pre533-format-inventory.json')
    parser.add_argument('--catalogue-dir', type=Path,
                        help='Exact fresh core archive directory; component fixtures still come from stage')
    args = parser.parse_args()
    stage = args.stage.resolve()
    assert not args.report.exists()
    platform = args.platform
    fixture = ROOT / 'tools/ui/tests/Out' / platform / 'CollectionViewsTest.exe'
    native = ROOT / 'Program/Tests/Out' / platform / 'ProgramUpdateInstallerTest.exe'
    runtime = ROOT / 'Program/Out' / ('Bin' if platform == 'Win32' else 'Bin64')
    catalogue = (args.catalogue_dir or stage / 'catalogue') / ('HomeLibRu.zip' if platform == 'Win32' else 'HomeLibRu_x64.zip')
    # Fail before launching anything when the interactive candidate still
    # contains the dialog from before the latest source review.
    save_source = ROOT / 'Program/Units/unit_BookSendOptions.pas'
    for binary, dependencies in ((runtime / 'HomeLibRu.exe', (save_source,)),
                                 (fixture, (save_source, ROOT / 'tools/ui/tests/UnifiedBookSendTests.inc',
                                            ROOT / 'tools/ui/tests/BookSavePlanningTests.inc'))):
        for dependency in dependencies:
            assert binary.stat().st_mtime_ns >= dependency.stat().st_mtime_ns, (
                f'Rebuild {binary} after the Save As changes in {dependency}')
    with zipfile.ZipFile(catalogue) as archive:
        assert hashlib.sha256(archive.read('HomeLibRu.exe')).hexdigest() == sha(runtime / 'HomeLibRu.exe'), (
            'Repackage the current Main build before the interactive Save As check')
    assets = {item['name']: item for item in json.loads((stage / 'publication-r1/assets.json').read_bytes())}
    doc_payload, doc_descriptor = read_doc_sample(args.doc_inventory)
    report = dict(status='FAIL', platform=platform, published=False,
                  scope='Ordinary packaged candidate Main GUI, synthetic real-format documents, exact minimal ZIP/local modules; no HTTP or restart claim',
                  catalogue_sha256=sha(catalogue), real_doc_source=doc_descriptor, phases=[], temporary_profile_removed=False)
    app = None
    temporary = tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-save-')
    outer = Path(temporary.name).resolve()
    target = outer / 'HomeLibRu-native-save'
    assert outer.parent == Path(os.environ['TEMP']).resolve() and not outer.is_symlink()
    environment = dict(os.environ, LOCALAPPDATA=str(outer / 'LocalAppData'), PYTHONDONTWRITEBYTECODE='1')
    try:
        target.mkdir()
        unpack(catalogue, target)
        report['main_sha256'] = sha(target / 'HomeLibRu.exe')
        for name in ('uselocaldata', 'uselocaltemp'):
            (target / name).touch()
        (target / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        ini = target / 'myhomelib2.ini'
        ini.write_text('[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
                       '[INTERFACE]\nLocale=ru\nWindowsDarkThemeOfferDismissed=1\n'
                       '[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\nAutoLoadReview=0\n'
                       'IgnoreAbsentArchives=1\n[OPDS]\nEnabled=0\n', encoding='utf-8')
        shutil.copyfile(fixture, target / fixture.name)
        genre = target / 'genres_fb2.glst'
        shutil.copyfile(target / 'tools/genres/genres_fb2.glst', genre)
        setup = subprocess.run([str(target / fixture.name), 'publisher-selection'], cwd=target,
            env=environment, capture_output=True, timeout=90, creationflags=subprocess.CREATE_NO_WINDOW)
        genre.unlink()
        assert setup.returncode == 0, setup.stdout[-3000:]
        spec = importlib.util.spec_from_file_location('save_fixtures', Path(__file__).with_name('prepare_save_mixed_fixtures.py'))
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        fixtures.prepare(target, runtime, doc_payload)
        inputs = target / 'mixed-save-inputs'
        sources = [inputs / ('source' + extension) for extension in ('.fb2', '.epub', '.pdf', '.djvu', '.doc')]
        doc_reference = json.loads((inputs / 'doc-reference.json').read_bytes())
        report['source_sha256'] = {path.suffix: sha(path) for path in sources}
        connection = sqlite3.connect(target / 'Data/one.hlc2')
        try:
            connection.create_collation('MHL_SYSTEM_NOCASE', lambda a,b: (a.casefold()>b.casefold())-(a.casefold()<b.casefold()))
            connection.create_function('MHL_TRIGGERS_ON', 0, lambda: 0)
            connection.create_function('MHL_UPPER', 1, lambda value: value.upper() if value is not None else None)
            connection.create_function('MHL_FULLNAME', 4, lambda last, first, middle, mode: ' '.join(v for v in (last,first,middle) if v))
            ids = [row[0] for row in connection.execute('SELECT BookID FROM Books ORDER BY BookID')]
            assert len(ids) == 7
            author = connection.execute('SELECT AuthorID FROM Author_List WHERE BookID=?', (ids[0],)).fetchone()[0]
            connection.execute('UPDATE Books SET IsDeleted=1')
            for index, (book_id, source) in enumerate(zip(ids, sources)):
                title = f'{index+1:02} Export {source.suffix[1:].upper()}'
                connection.execute('UPDATE Books SET Title=?, SearchTitle=?, Folder=?, FileName=?, Ext=?, '
                    'SearchFolder=?, SearchFileName=?, SearchExt=?, Lang=?, SearchLang=?, BookSize=?, IsLocal=1,IsDeleted=0 WHERE BookID=?',
                    (title,title.upper(),'mixed-save-inputs',source.stem,source.suffix,'MIXED-SAVE-INPUTS',
                     source.stem.upper(),source.suffix.upper(),'ru','RU',source.stat().st_size,book_id))
                connection.execute('UPDATE Author_List SET AuthorID=? WHERE BookID=?', (author,book_id))
            connection.commit()
        finally:
            connection.close()
        options = configparser.ConfigParser(interpolation=None, strict=False)
        options.optionxform = str
        options.read_string(ini.read_text('utf-8-sig'))
        options['INTERFACE']['ActivePage']='0'
        for name, value in [('FormWidth','1173'),('FormHeight','900'),('WindowState','0')]:
            options['INTERFACE'][name]=value
        with ini.open('w',encoding='utf-8') as stream:
            options.write(stream,space_around_delimiters=False)
        originals = outer / 'originals'
        converted = outer / 'converted'
        originals.mkdir(); converted.mkdir()
        forbidden = ['bookconvert','images','kindle','office','xps','pdfium','djvu','doc','7zip']
        assert all(not (target / 'tools' / name).exists() for name in forbidden)

        def launch(phase, destination):
            nonlocal app
            app = subprocess.Popen([str(target / 'HomeLibRu.exe')], cwd=target, env=environment,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            report['active_phase']=phase
            report['own_main_pid']=app.pid
            print(json.dumps(dict(phase=phase,pid=app.pid,target=str(target),destination=str(destination),
                                  instructions='Use Computer Use; save all five books, inspect, and close Main normally'),ensure_ascii=False),flush=True)
            assert app.wait(timeout=args.timeout) == 0, phase
            phase_file = outer / (phase + '-observed.json')
            assert phase_file.is_file(), 'Record observed GUI checks before normal exit'
            report['phases'].append(json.loads(phase_file.read_bytes()))
            assert all(sha(path)==report['source_sha256'][path.suffix] for path in sources)

        launch('minimal-original', originals)
        output = [p for p in originals.rglob('*') if p.is_file()]
        assert len(output)==len(sources), [str(p) for p in output]
        assert {p.suffix:sha(p) for p in output}==report['source_sha256'], 'Original copies changed bytes'
        assert all(not (target/'tools'/name).exists() for name in forbidden)
        report['unchanged_copy_without_optional_modules']=True
        component_sources = []
        for component in ('BookProcessing','ImageProcessing'):
            name=f'HomeLibRu-{component}-3.0.0.1-{platform}.zip'
            component_sources.append((component,stage/'formats'/name,'3.0.0.1'))
        for component,version,cache in [('PDFium','157.0.8086.0','pre534-final-reader-modules-20261027'),
                                       ('DjVuLibre','3.5.29','component-mirrors-pre534-20261027'),
                                       ('DocSharp','0.21.0.0','component-mirrors-pre534-20261027')]:
            name=f'HomeLibRu-{component}-{version}-{platform}.zip'
            component_sources.append((component,ROOT/'tools/ui/tests/Out'/cache/name,version))
        report['installed_components']=[]
        for component, source, version in component_sources:
            asset=assets[source.name]
            assert 'sha256:'+sha(source)==asset['digest'] and source.stat().st_size==asset['size']
            archive=outer/source.name
            shutil.copyfile(source,archive)
            job=outer/('job-'+component)
            for parameters in [('--prepare-component',archive,sha(archive),TAG,job,component,version),('--install',job,target)]:
                result=subprocess.run([str(native),*map(str,parameters)],cwd=outer,env=environment,
                    capture_output=True,encoding='utf-8-sig',timeout=120,creationflags=subprocess.CREATE_NO_WINDOW)
                assert result.returncode==0,(parameters,result.stdout,result.stderr)
            report['installed_components'].append(dict(id=component,version=version,archive_sha256=sha(source)))
        assert all(not (target/'tools'/name).exists() for name in ('kindle','office','xps','7zip'))
        assert not (target/'HomeLibReader.exe').exists()
        launch('mixed-conversion', converted)
        output = [p for p in converted.rglob('*') if p.is_file()]
        assert len(output)==len(sources) and all(p.suffix=='.epub' for p in output), [str(p) for p in output]
        report['converted_outputs']=[]
        for path in output:
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None and archive.read('mimetype')==b'application/epub+zip'
                pages={name:ET.fromstring(archive.read(name)) for name in archive.namelist() if name.endswith(('.xhtml','.html'))}
                assert pages and all(page.find('.//{http://www.w3.org/1999/xhtml}body') is not None for page in pages.values())
                text=' '.join(' '.join(page.itertext()) for page in pages.values())
                if 'PDF' in path.stem:
                    assert 'First readable paragraph' in text and 'Last paragraph preserves the final sentence.' in text
                elif 'DJVU' in path.stem:
                    assert 'knowledge' in text.casefold()
                elif 'DOC' in path.stem:
                    verify_output(path, doc_reference['paragraphs'], doc_reference['images'])
                else:
                    assert 'Full text, final sentence. Ё, Україна, 中文.' in text
                image_references=0
                for name,page in pages.items():
                    for element in page.iter():
                        if element.tag.rsplit('}',1)[-1] not in ('img','image'):
                            continue
                        href=element.get('src') or element.get('{http://www.w3.org/1999/xlink}href') or element.get('href')
                        assert href and not href.startswith(('http:','https:','file:','data:'))
                        asset=posixpath.normpath(posixpath.join(posixpath.dirname(name),unquote(href.split('#')[0])))
                        assert asset in archive.namelist() and archive.getinfo(asset).file_size>0,href
                        image_references+=1
                if 'DJVU' not in path.stem and ('DOC' not in path.stem or doc_reference['images']):
                    assert image_references>0,'Source illustration disappeared'
            report['converted_outputs'].append(dict(file=path.name,size=path.stat().st_size,sha256=sha(path),
                                                    expected_text_preserved=True,image_references=image_references))
        assert sha(target/'HomeLibRu.exe')==report['main_sha256']
        report.update(status='PASS',source_books_preserved=True)
    except BaseException as error:
        report['error']=repr(error)
        raise
    finally:
        if app is not None and app.poll() is None:
            app.terminate();app.wait(timeout=15)
        try:
            assert outer.parent == Path(os.environ['TEMP']).resolve() and outer.name.startswith('HomeLibRu-update-test-save-')
            temporary.cleanup()
        finally:
            report['temporary_profile_removed']=not outer.exists()
            with args.report.open('x',encoding='utf-8') as stream:
                json.dump(report,stream,ensure_ascii=False,indent=2);stream.write('\n')
    print('PASS packaged mixed Save As: '+platform+'; source hashes preserved; private runtime removed',flush=True)


if __name__ == '__main__':
    main()
