"""Launch the exact release ZIP with a disposable synthetic profile.

Inspect and close the application's own window through Computer Use. The
process exit and all temporary payloads are handled here, including failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import zipfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive',type=Path)
    parser.add_argument('fixture',type=Path)
    parser.add_argument('--report',type=Path,required=True)
    options=parser.parse_args()
    report={'archive_sha256':hashlib.sha256(options.archive.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-native-release-smoke-') as temporary:
        root=Path(temporary)
        environment=dict(os.environ,LOCALAPPDATA=str(root/'LocalAppData'))
        with zipfile.ZipFile(options.archive) as package:
            assert package.testzip() is None
            for name in package.namelist():
                assert not name.startswith(('/','\\')) and '\\' not in name and ':' not in name and '..' not in Path(name).parts,name
            package.extractall(root)
        shutil.copyfile(options.fixture,root/'CollectionViewsTest.exe')
        for name in ['uselocaldata','uselocaltemp']: (root/name).touch()
        (root/'native-regression.marker').write_text('HomeLib Ru isolated native regression v1')
        (root/'myhomelib2.ini').write_text('[SYSTEM]\nCheckUpdates=0\nCheckLibrusecUpdates=0\nProgramCheckMinutes=0\n'
            '[INTERFACE]\nLocale=ru\n[BEHAVIOR]\nCoverPanel=0\nShowCover=0\nShowAnnotation=0\nAutoLoadReview=0\nIgnoreAbsentArchives=1\n',encoding='utf-8')
        fixture=subprocess.run([str(root/'CollectionViewsTest.exe'),'publisher-selection'],cwd=root,
                               capture_output=True,timeout=60,creationflags=0x08000000,env=environment)
        if fixture.returncode: raise RuntimeError(fixture.stdout.decode('utf-8',errors='replace'))
        ini=root/'myhomelib2.ini'; text=ini.read_text(encoding='utf-8-sig')
        for name,value in {'ActivePage':'0','FormWidth':'1173','FormHeight':'900','WindowState':'0'}.items():
            text,count=re.subn('^'+name+'=.*$',name+'='+value,text,flags=re.M)
            if not count: raise RuntimeError('Missing fixture setting '+name)
        ini.write_text(text,encoding='utf-8')
        started=time.monotonic()
        app=subprocess.Popen([str(root/'HomeLibRu.exe')],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=environment)
        print('Release smoke application: '+str(root/'HomeLibRu.exe'),flush=True)
        print('PID: '+str(app.pid)+'; inspect its window and close normally',flush=True)
        try:
            report['exit_code']=app.wait(timeout=300)
            report['lifetime_seconds']=round(time.monotonic()-started,3)
            if report['exit_code']!=0 or report['lifetime_seconds']<2:
                raise RuntimeError('Release application failed or exited before inspection')
        finally:
            if app.poll() is None:
                app.kill(); app.wait(timeout=10)
    report['temporary_profile_removed']=True
    options.report.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('PASS release application closed normally; synthetic profile and extracted ZIP removed',flush=True)


if __name__=='__main__': main()
