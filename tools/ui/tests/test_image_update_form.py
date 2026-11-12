"""Run real update-form JPEG XL cache and reentrant-launch regressions in isolation."""
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
    for name in ('native', 'helper', 'sqlite', 'icons', 'genres', 'release', 'packages', 'result'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-image-ui-') as raw:
        root = Path(raw) / 'HomeLibRu-native-image-ui'
        root.mkdir()
        shutil.copy2(args.native, root / 'HomeLibRu.exe')
        shutil.copy2(args.sqlite, root / 'sqlite3.dll')
        shutil.copy2(args.genres, root / 'genres_fb2.glst')
        (root / 'Icons').mkdir()
        shutil.copy2(args.icons, root / 'Icons/MHLIcons.dll')
        for name in ('uselocaldata', 'uselocaltemp'):
            (root / name).touch()
        (root / 'native-regression.marker').write_text('HomeLib Ru isolated native regression v1', encoding='utf-8')
        inputs = root / 'image-fixtures'
        inputs.mkdir()
        shutil.copy2(args.release, inputs / 'release.json')
        shutil.copy2(args.helper, inputs / 'native-helper.exe')
        machine = args.native.read_bytes()
        pe = int.from_bytes(machine[0x3c:0x40], 'little')
        architecture = 'Win64' if int.from_bytes(machine[pe+4:pe+6], 'little') == 0x8664 else 'Win32'
        package = 'jxl-' + ('x64' if architecture == 'Win64' else 'x86') + '-windows-static.zip'
        shutil.copy2(args.packages / package, inputs / package)
        env = os.environ.copy()
        env['LOCALAPPDATA'] = str(root / 'local')
        result = subprocess.run([str(root / 'HomeLibRu.exe'), 'update-image-identity'], cwd=root,
                                capture_output=True, timeout=120, env=env,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
        if result.returncode:
            output += '\nOWNED FILES\n' + '\n'.join(str(p.relative_to(root)) for p in root.rglob('*')
                                                       if 'image-fixtures' not in p.parts)
            for path in root.rglob('*.json'):
                if path.stat().st_size < 32768 and 'image-fixtures' not in path.parts:
                    output += '\n' + str(path.relative_to(root)) + '\n' + path.read_text(encoding='utf-8-sig', errors='replace')
        args.result.with_suffix('.log').write_text(output, encoding='utf-8')
        assert result.returncode == 0, (result.returncode, output)
        assert output.count('PASS ') == 5, output
    report = dict(status='PASS', architecture=architecture,
                  native_sha256=hashlib.sha256(machine).hexdigest(),
                  temporary_data_removed=not Path(raw).exists(),
                  coverage=['normal official download and ready persistence',
                            'v-prefixed legacy cache repair without redownload',
                            'real running EXE copy fails with Windows 32',
                            'reentrant launch starts exactly one helper and preserves request bytes',
                            'new attempt after helper termination',
                            'production ShellExecuteEx returns a live owned process handle',
                            'wrong cache identity rejected; manifest unchanged'])
    args.result.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
