"""Exercise settings migration through the native installer test executable."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import tempfile


def check(executable, root, old_name, new_name):
    old = root / old_name
    new = root / new_name
    backup = root / (new_name + '.rollback.bak')
    original = '\ufeff[INTERFACE]\r\nLocale=uk\r\n[Personal]\r\nNote=Збережено\r\n'.encode('utf-8')

    def run(migrate=False):
        args = [str(executable), '--profile-ini', str(new)]
        if migrate:
            args.append('--migrate')
        result = subprocess.run(args, check=True, capture_output=True,
                                timeout=20, cwd=executable.parent)
        return result.stdout.decode('ascii').strip()

    assert run(True) == new_name and not new.exists() and not backup.exists()
    old.write_bytes(original)
    assert run() == old_name and not new.exists()
    # Simulate a blocked destination after the backup could be written.
    new.mkdir()
    assert run(True) == old_name and old.read_bytes() == backup.read_bytes() == original
    new.rmdir()
    with ThreadPoolExecutor(max_workers=4) as pool:
        assert list(pool.map(run, [True] * 8)) == [new_name] * 8
    assert new.read_bytes() == backup.read_bytes() == original and not old.exists()

    if new_name == 'HomeLibre.ini':
        # A legacy config can reappear after using an older version. Keep both
        # if a modern profile already exists so neither set of changes is lost.
        new.write_bytes(b'[INTERFACE]\nLocale=en\n')
        old.write_bytes(b'[INTERFACE]\nLocale=bg\n')
        assert run(True) == new_name
        assert new.read_bytes().endswith(b'Locale=en\n')
        assert old.read_bytes().endswith(b'Locale=bg\n')
        assert backup.read_bytes() == original


def main():
    executable = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-profile-') as folder:
        root = Path(folder)
        for old, new in [('myhomelib2.ini', 'HomeLibre.ini'),
                         ('HomeLibReader.ini', 'HomeLibreReader.ini')]:
            case = root / new.removesuffix('.ini')
            case.mkdir()
            check(executable, case, old, new)
            print('PASS', old, 'to', new)


if __name__ == '__main__':
    main()
