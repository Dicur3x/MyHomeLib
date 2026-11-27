"""Build the legacy Word worker with HomeLibre's small patch to pinned Docboss."""

import argparse
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib


REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / 'Utils/HomeLibLegacyDocRich'


def build(targets, target_dir, offline):
    target_dir.mkdir(parents=True, exist_ok=True)
    original_manifest = PROJECT / 'Cargo.toml'
    fetch = ['cargo', 'fetch', '--locked', '--manifest-path', str(original_manifest)]
    for target in targets:
        fetch.extend(('--target', target))
    if offline:
        fetch.append('--offline')
    subprocess.run(fetch, check=True)
    lockfile = (PROJECT / 'Cargo.lock').read_text(encoding='utf-8')
    model = next(p for p in tomllib.loads(lockfile)['package'] if p['name'] == 'docboss-model')
    source = model['source']
    revision = source.rsplit('#', 1)[1]
    cargo_home = Path(os.environ.get('CARGO_HOME', Path.home() / '.cargo'))
    checkout = next((cargo_home / 'git/checkouts').glob(f'docboss-*/{revision[:7]}'), None)
    if checkout is None:
        raise FileNotFoundError(f'Docboss {revision} is missing from the Cargo cache')

    with tempfile.TemporaryDirectory(prefix='legacy-doc-', dir=target_dir) as tmp:
        root = Path(tmp)
        upstream = root / 'docboss'
        upstream.mkdir()
        archive = subprocess.check_output(['git', '-C', str(checkout), 'archive', revision])
        with tarfile.open(fileobj=io.BytesIO(archive)) as files:
            files.extractall(upstream, filter='data')
        subprocess.run(['git', 'init', '--quiet'], cwd=upstream, check=True)
        subprocess.run(['git', 'apply', str(PROJECT / 'docboss-drawings.patch')], cwd=upstream, check=True)

        worker = root / 'worker'
        shutil.copytree(PROJECT / 'src', worker / 'src')
        manifest = original_manifest.read_text(encoding='utf-8')
        manifest = re.sub(
            r'(?m)^(docboss-[\w-]+) = \{ git = "https://github\.com/4thel00z/docboss", rev = "'
            + re.escape(revision) + r'" \}$',
            r'\1 = { path = "../docboss/crates/\1" }', manifest,
        )
        (worker / 'Cargo.toml').write_text(manifest, encoding='utf-8')
        (worker / 'Cargo.lock').write_text(lockfile.replace(f'source = "{source}"\n', ''), encoding='utf-8')
        command = ['cargo', 'build', '--release', '--locked', '--offline', '--target-dir', str(target_dir)]
        for target in targets:
            command.extend(('--target', target))
        subprocess.run(command, cwd=worker, check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', action='append', choices=['i686-pc-windows-gnu', 'x86_64-pc-windows-gnu'])
    parser.add_argument('--target-dir', type=Path, default=PROJECT / 'target')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    build(args.target or ['i686-pc-windows-gnu', 'x86_64-pc-windows-gnu'], args.target_dir.resolve(), args.offline)
