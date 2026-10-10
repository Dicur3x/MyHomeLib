"""Run native unit regressions in isolated TEMP profiles with no personal data."""
import argparse
import pathlib
import shutil
import subprocess
import tempfile
import time
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('runtime', type=pathlib.Path)
parser.add_argument('exe', type=pathlib.Path)
parser.add_argument('cases', nargs='+', choices=('column-layout', 'archives', 'filters', 'cancel-filters', 'cancel-aliases', 'aliases', 'async', 'status','reader-choices','reader-cache-stamps','sources-window','office-reader'))
parser.add_argument('--keep',action='store_true')
args = parser.parse_args()
runtime, exe = args.runtime.resolve(), args.exe.resolve()
assert exe.name == 'Round2Probe.exe'
for case in args.cases:
    root = pathlib.Path(tempfile.mkdtemp(prefix='HomeLibRu-native-probe-')).resolve()
    assert root.parent == pathlib.Path(tempfile.gettempdir()).resolve()
    assert root.name.startswith('HomeLibRu-native-probe-')
    try:
        shutil.copy2(exe, root/exe.name)
        for name in ('sqlite3.dll', 'libzstd.dll', 'libeay32.dll', 'ssleay32.dll', 'homelib_webp.dll'):
            if (runtime/name).is_file():
                shutil.copy2(runtime/name, root/name)
        for file in runtime.glob('genres*.glst'):
            shutil.copy2(file, root/file.name)
        if (runtime/'tools/webp').is_dir():
            shutil.copytree(runtime/'tools/webp', root/'tools/webp')
        shutil.copy2(pathlib.Path(__file__).resolve().parents[3]/'Installer/Components.json', root/'COMPONENTS.json')
        for name in ('uselocaldata', 'uselocaltemp'):
            (root/name).write_text('')
        (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        (root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\n[INTERFACE]\nLocale=ru\n[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\nAutoLoadReview=0\n[OPDS]\nEnabled=0\n', encoding='utf-8')
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        command = [str(root/exe.name), case]
        if case=='archives':
            (root/'book.fb2').write_text('<FictionBook><body><section><p>Archive needle</p></section></body></FictionBook>',encoding='utf-8')
            full_7z=pathlib.Path('C:/Program Files/7-Zip/7z.exe')
            assert full_7z.is_file(),'Container regression requires installed full 7-Zip'
            for command_fixture in ([str(full_7z),'a','-t7z',str(root/'loose-book.7z'),str(root/'book.fb2')],
                                    ['makecab.exe',str(root/'book.fb2'),str(root/'loose-book.cab')]):
                made=subprocess.run(command_fixture,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30,startupinfo=startup)
                assert made.returncode==0,made.stdout
            if (runtime/'tools/7zip').is_dir():
                shutil.copytree(runtime/'tools/7zip',root/'tools/7zip')
        if case=='office-reader':
            shutil.copy2(runtime/'tools/pdfium/pdfium.dll',root/'pdfium.dll')
            content='''<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.2"><office:body><office:presentation>'''
            for i in range(2):
                content+=f'<draw:page draw:name="Slide{i+1}"><draw:frame svg:x="2cm" svg:y="2cm" svg:width="15cm" svg:height="5cm"><draw:text-box><text:p>Office needle slide {i+1}</text:p></draw:text-box></draw:frame></draw:page>'
            content+='</office:presentation></office:body></office:document-content>'
            manifest='''<?xml version="1.0"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.presentation"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>'''
            with zipfile.ZipFile(root/'office-sample.odp','w') as z:
                z.writestr('mimetype','application/vnd.oasis.opendocument.presentation')
                z.writestr('content.xml',content)
                z.writestr('META-INF/manifest.xml',manifest)
            shutil.copy2(root/'office-sample.odp',root/'office-cancel.odp')
            office=pathlib.Path('C:/Program Files/LibreOffice/program/soffice.com')
            assert office.is_file(),'Optional Office test requires installed LibreOffice'
            profile=(root/'fixture-office-profile').as_uri()
            made=subprocess.run([str(office),f'-env:UserInstallation={profile}','--headless','--nologo','--norestore',
                                 '--convert-to','ppt:MS PowerPoint 97','--outdir',str(root),str(root/'office-sample.odp')],
                                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45,startupinfo=startup)
            assert made.returncode==0 and (root/'office-sample.ppt').is_file(),made.stdout
        if case == 'async':
            archive = root/'async-fixture.zip'
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as zipped:
                zipped.writestr('793007.fb2', '<FictionBook><body><section><p>Фоновая распаковка</p></section></body></FictionBook>')
            command.append(str(archive))
        result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, encoding='mbcs', errors='replace',
                                timeout=90, startupinfo=startup)
        print(case, result.stdout, flush=True)
        expected = 'PASS damaged column layout' if case == 'column-layout' else 'PASS '
        assert result.returncode == 0 and expected in result.stdout
    finally:
        if args.keep:
            print('RETAINED',root,flush=True)
        else:
            for attempt in range(6):
                try:
                    shutil.rmtree(root)
                    break
                except PermissionError:
                    if attempt == 5:
                        print('Temporary test files still locked:', root, flush=True)
                    else:
                        time.sleep(0.2)
print('PASS isolated native unit regressions; OPDS disabled; personal profile unused', flush=True)
