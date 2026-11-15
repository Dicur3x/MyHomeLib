"""Cancel the production runtime prompt in an isolated, child-process-fenced host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--definition', required=True, type=Path)
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--theme', choices=('light', 'dark'), required=True)
    parser.add_argument('--online', action='store_true')
    parser.add_argument('--manual', action='store_true')
    args = parser.parse_args()
    args.stage.mkdir(exist_ok=False)
    assert shutil.disk_usage('C:/').free >= 8 * 1024**3
    report = dict(status='RUNNING', theme=args.theme, offline=not args.online,
                  manual=args.manual, native_sha256=hashlib.sha256(args.native.read_bytes()).hexdigest())
    try:
        with tempfile.TemporaryDirectory(prefix='HomeLibRu-native-prerequisite-', dir=args.stage) as name:
            root = Path(name)
            native = root / args.native.name
            shutil.copy2(args.native, native)
            for marker in ('uselocaldata', 'uselocaltemp'):
                (root / marker).touch()
            (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
            if not args.online:
                folder = root / 'tools/prerequisites'
                folder.mkdir(parents=True)
                # Cancellation must not read, download, or start any installer.
                # Deliberately supply metadata only: a mistaken acceptance fails
                # before any setup, in addition to the native child-process fence.
                shutil.copy2(args.definition, folder / 'PREREQUISITES.json')
            environment = dict(os.environ, TEMP=str(root / 'temp'), TMP=str(root / 'temp'),
                               APPDATA=str(root / 'appdata'), LOCALAPPDATA=str(root / 'local-appdata'))
            command = [str(native), args.theme]
            if not args.manual:
                command.append('--auto-cancel')
            print('Prompt fixture: ' + str(native), flush=True)
            result = subprocess.run(command, env=environment, cwd=root, capture_output=True,
                                    timeout=330 if args.manual else 30, creationflags=subprocess.CREATE_NO_WINDOW)
            output = result.stdout.decode('utf-8', errors='replace') + result.stderr.decode('utf-8', errors='replace')
            (args.stage / 'native-output.txt').write_text(output, encoding='utf-8')
            assert result.returncode == 0 and 'PASS production prerequisite prompt cancelled' in output, output
            assert not (root / 'temp').exists(), 'Cancellation created temporary installation files'
        assert not root.exists()
        report.update(status='PASS', installers_executed=False, child_processes=0, owned_profile_removed=True)
        print(json.dumps(report), flush=True)
    except Exception as error:
        report.update(status='FAIL', error=str(error))
        raise
    finally:
        (args.stage / 'dialog-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
