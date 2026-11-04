"""Exercise real two-component updates under deep, isolated Windows paths."""
import _winapi
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import zipfile


REPO = Path(__file__).resolve().parents[3]
VERSION = '2.7.0.1105'
COMPONENTS = ('BookProcessing', 'ImageProcessing')
MANIFEST = 'HomeLibRu.update.json'


def extended(path):
    return Path('\\\\?\\' + str(path))


def sha(path):
    return hashlib.sha256(extended(path).read_bytes()).hexdigest()


def deep_path(root, name, leaf, length=221):
    parent = root / name
    result = parent / ('Данные-' + 'x' * (length - len(str(parent / 'Данные-' / leaf)))) / leaf
    assert len(str(result)) == length
    return result


def job_at(root, name):
    return deep_path(root, name, 'HomeLibRu-update-' + str(uuid.uuid4()))


def probe(platform, root, packages):
    exe = REPO / 'Program/Tests/Out' / platform / 'ProgramUpdateInstallerTest.exe'
    env = dict(os.environ, TMP=str(root), TEMP=str(root), LOCALAPPDATA=str(root / 'local'))

    def run(*args, error=None):
        result = subprocess.run([exe, *map(str, args)], env=env, cwd=root,
                                creationflags=subprocess.CREATE_NO_WINDOW,
                                capture_output=True, encoding='utf-8', errors='replace', timeout=120)
        if error:
            assert result.returncode != 0 and error in result.stderr, (args[0], result.stdout, result.stderr)
        else:
            assert result.returncode == 0 and result.stdout.strip().endswith('PASS'), (
                args[0], result.stdout, result.stderr)
        return result.stdout.strip().splitlines()

    jobs = []
    for component in COMPONENTS:
        asset = packages / f'HomeLibRu-{component}-{VERSION}-{platform}.zip'
        archive = root / asset.name
        shutil.copyfile(asset, archive)
        with zipfile.ZipFile(archive) as package:
            release = json.loads(package.read(MANIFEST).decode('utf-8-sig'))['release']
        job = job_at(root, component)
        run('--prepare-component', archive, sha(archive), release, job, component, VERSION)
        jobs.append(job)
    success = job_at(root, 'combined')
    fail = job_at(root, 'rollback')
    batch_tag = 'isolated-long-path-batch'
    for job in (success, fail):
        run('--combine', job, batch_tag, *jobs)

    combined = json.loads(extended(success / 'manifest.json').read_text('utf-8-sig'))
    entries = {entry['path']: entry['sha256'] for entry in combined['files']}
    longest = max(entries, key=len)
    target = deep_path(root, 'destination', 'HomeLibre')
    original = target / longest
    assert len(str(success / 'payload' / longest)) > 260 and len(str(original)) > 260
    extended(original.parent).mkdir(parents=True)
    shutil.copyfile(exe, extended(target / 'HomeLibRu.exe'))
    private = target / 'private.txt'
    extended(private).write_bytes(b'private fixture')
    extended(original).write_bytes(b'previous version of the long file')
    original_hash = sha(original)

    run('--install', fail, target, len(entries), error='Имитированная ошибка установки')
    journal = json.loads(extended(fail / 'journal.json').read_text('utf-8-sig'))
    assert journal['state'] == 'rolled-back'
    assert any(item['path'] == longest and item['existed'] for item in journal['files'])
    assert sha(original) == original_hash
    assert all(not extended(target / name).exists() for name in entries if name != longest)
    assert extended(private).read_bytes() == b'private fixture'

    run('--install', success, target)
    assert all(sha(target / name) == digest for name, digest in entries.items())
    assert extended(private).read_bytes() == b'private fixture'
    for component in COMPONENTS:
        assert run('--component-needs-repair', target, component) == ['0', 'PASS']

    # A real junction past MAX_PATH must still be rejected before traversing it.
    redirect_target = deep_path(root, 'redirect-test', 'HomeLibre', length=233)
    link = redirect_target / Path(longest).parent
    assert len(str(link)) > 260
    extended(link.parent).mkdir(parents=True)
    shutil.copyfile(exe, extended(redirect_target / 'HomeLibRu.exe'))
    outside = root / 'outside'
    outside.mkdir()
    sentinel = outside / Path(longest).name
    sentinel.write_bytes(b'outside the update')
    _winapi.CreateJunction(str(outside), str(extended(link)))
    try:
        assert extended(link).is_junction()
        reject = job_at(root, 'reject')
        run('--combine', reject, batch_tag, *jobs)
        run('--install', reject, redirect_target, error='Папка обновления содержит ссылку')
        assert sentinel.read_bytes() == b'outside the update'
        assert not extended(reject / 'journal.json').exists()
    finally:
        extended(link).rmdir()

    cleanup = job_at(root, 'cleanup-redirect')
    link = cleanup / 'payload' / Path(longest).parent
    assert len(str(link)) > 260
    extended(link.parent).mkdir(parents=True)
    _winapi.CreateJunction(str(outside), str(extended(link)))
    try:
        run('--clean', cleanup, error='Папка обновления содержит ссылку')
        assert sentinel.read_bytes() == b'outside the update'
        assert extended(link).is_junction()
    finally:
        extended(link).rmdir()

    for job in (*jobs, success, fail, reject, cleanup):
        run('--clean', job)
        assert not extended(job).exists()
    print(f'{platform} PASS long staging, install, rollback, junction rejection and cleanup '
          f'({len(str(success / "payload" / longest))} characters)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packages', type=Path)
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args()
    base = args.scratch.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='HomeLibRu-update-test-long-', dir=extended(base)) as temporary:
        root = Path(temporary[4:])
        assert root.parent.resolve() == base and not root.is_junction()
        for platform in ('Win32', 'Win64'):
            isolated = root / platform
            isolated.mkdir()
            probe(platform, isolated, args.packages.resolve(strict=True))


if __name__ == '__main__':
    main()
