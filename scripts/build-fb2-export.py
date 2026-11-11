"""Build the optional FB2 writer from pinned inputs and create its corresponding source ZIP.

Source: github.com/rupor-github/fb2cng at COMMIT.
Dictionaries: mirrors.ibiblio.org/CTAN/language/hyphenation-utf8.zip.
Sentences: github.com/neurosnap/sentences at 6298134f0335f93e5714d99f69cd143b1f4babd6.
Fonts: github.com/notofonts/noto-fonts at ffebf8c1ee449e544955a7e813c54f9b73848eac.
Place the Noto LICENSE at the font root and the TTFs in their hinted/ttf family folders.
"""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import zipfile


VERSION = '1.9.5'
COMMIT = '53da95719936f220f9018e55ff788de3c51c239e'
GO_VERSION = 'go1.27.3'
PATCH = Path(__file__).with_name('fb2cng-kfx-navigation.patch')
SOURCE_ARCHIVE = 'FB2Export-1.9.5-nav1-HomeLibre-source.zip'
TARGETS = {'Win32': '386', 'Win64': 'amd64'}
INPUTS = {
    'source': 'a713f3c7edddaa21ce89669e9616d9e8d2cfbb3f47eab810851eeba3870dbe3c',
    'dictionaries': 'ef3c55f7921eb6c1cdbacac2815c005a010473aed4f0c757040eab126a969b6b',
    'sentences': '47cc3dafd77e8207e5ac165efda0903bdb4a5c8313ca669cda6ab6d099e59cac',
}
FONTS = {
    'LICENSE': '0dab92d0544f7b233403f14b84a663bdbfa746982eda629e7f4f9ffe1b036feb',
    'NotoSerif-Regular.ttf': 'c8f669ceb2c9c60ccf55198b305e08a997ffca79a38cc7eeb551e643cbe66505',
    'NotoSerif-Bold.ttf': '3b2086a869bcded2aeb4416fc281ceec9d6ce3c06756cda19f8f763636204e7d',
    'NotoSerif-Italic.ttf': '0ea81d6b54fc8aa5dff0fd6ebe7cfa431e9e6cf747a8d4aa33581fa0aaccffea',
    'NotoSerif-BoldItalic.ttf': '4fb8737145b4a503d548af4b517afdfc532e44a96ac15378257e825741334eec',
    'NotoSans-Regular.ttf': 'b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5',
    'NotoSans-Bold.ttf': 'c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a',
    'NotoSans-Italic.ttf': '36cff144df01309dab648bea71baff9bb074026914afe63aeacc8bc90b67a28b',
    'NotoSans-BoldItalic.ttf': '6edf4227ef0fa846aca70e86a307804ca4401741830f5b3af0f2554abe2b8466',
    'NotoSansMono-Regular.ttf': 'd9e2b23d19f8230be7146f409a52b1d23117e635e28f2e2892cf91b7382f325b',
    'NotoSansMono-Bold.ttf': 'beb857bd799a114de7d5d90cc75cc69f4b6ee8d401f4ab20697e6f9719a66dfc',
    'NotoSansMath-Regular.ttf': '80b61fd613d3519197e64fff6f7e71fdc7f3e6526440ea4115b554ef7fd59af7',
    'NotoSansSymbols-Regular.ttf': '8f02f31959bbdf6061547a188248e13f84dc5fdd940326ec494675f453f072bb',
    'NotoSansSymbols2-Regular.ttf': '630846d528dbe4c4981370a4d0a9475a1fd1491a129bb411f8e157cdb5de13c6',
}


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def stage_resources(source, options):
    external = source / 'external'
    external.mkdir()
    shutil.copyfile(options.dictionaries, external / 'hyphenation-utf8.zip')
    with zipfile.ZipFile(options.dictionaries) as archive:
        for item in archive.namelist():
            name = Path(item).name
            if item.startswith('hyph-utf8/tex/patterns/txt/hyph-') and name.endswith(('.pat.txt', '.hyp.txt')):
                (source / 'content/text/dictionaries' / (name + '.gz')).write_bytes(
                    gzip.compress(archive.read(item), mtime=0))
    shutil.copyfile(options.sentences, external / 'sentences.tar.gz')
    with tarfile.open(options.sentences) as archive:
        for item in archive:
            parts = item.name.split('/')
            if item.isfile() and len(parts) == 3 and parts[1] == 'data' and parts[2].endswith('.json'):
                (source / 'content/text/sentences' / (parts[2] + '.gz')).write_bytes(
                    gzip.compress(archive.extractfile(item).read(), mtime=0))
    for name, expected in FONTS.items():
        path = options.fonts / name.split('-')[0] / name if name.endswith('.ttf') else options.fonts / name
        if sha256(path) != expected:
            raise ValueError('Unexpected Noto font or licence: ' + name)
        if name.endswith('.ttf'):
            (source / 'convert/pdf/fonts' / (name + '.gz')).write_bytes(
                gzip.compress(path.read_bytes(), mtime=0))
        else:
            shutil.copyfile(path, source / 'convert/pdf/fonts/OFL.txt')


def build(options):
    for name, expected in INPUTS.items():
        if sha256(getattr(options, name)) != expected:
            raise ValueError('Unexpected fb2cng build input: ' + name)
    output = options.output.resolve()
    if output.exists():
        raise FileExistsError(output)
    env = dict(os.environ, GOTOOLCHAIN='local', GOENV='off', GOFLAGS='', GOWORK='off',
               GOPROXY='off', GOTELEMETRY='off', CGO_ENABLED='0')
    go = str(options.go.resolve())
    if subprocess.check_output([go, 'version'], env=env, text=True).split()[2] != GO_VERSION:
        raise ValueError('Use Go ' + GO_VERSION)
    with TemporaryDirectory(prefix='fb2-build-', dir=output.parent) as folder:
        work = Path(folder)
        with tarfile.open(options.source) as archive:
            archive.extractall(work, filter='data')
        source = work / ('fb2cng-' + COMMIT)
        subprocess.run(['git', 'apply', '--whitespace=error', str(PATCH)], cwd=source, check=True)
        stage_resources(source, options)
        (source / 'misc').mkdir()
        (source / 'misc/version.go').write_text(
            'package misc\n\nfunc GetAppName() string { return "fbc" }\n'
            f'func GetVersion() string {{ return "{VERSION}" }}\n'
            f'func GetGitHash() string {{ return "{COMMIT}-homelibre-nav1" }}\n',
            encoding='utf-8', newline='\n')
        subprocess.run([go, 'tool', 'go-enum', '--output-suffix', '_code', '--file',
                        'common/enums.go', '--names', '--nocase', '--marshal', '--mustparse'],
                       cwd=source, env=dict(env, GOFLAGS='-mod=vendor'), check=True)
        shutil.copyfile(PATCH, source / PATCH.name)
        (source / 'BUILD-HOMELIBRE.txt').write_text(
            'HomeLibre FB2Export corresponding source. The navigation patch is already applied.\n'
            'With Go 1.27.3, set CGO_ENABLED=0, GOOS=windows and GOARCH=386 or amd64.\n'
            'For 386 use GO386=sse2. For amd64 use GOAMD64=v1. Then run:\n'
            'go build -mod=vendor -trimpath -buildvcs=false -o fbc.exe ./cmd/fbc\n',
            encoding='ascii', newline='\n')
        staged = work / 'packages'
        staged.mkdir()
        bundle = staged / SOURCE_ARCHIVE
        with zipfile.ZipFile(bundle, 'x', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(source.rglob('*')):
                if path.is_file():
                    archive.writestr(zipfile.ZipInfo(path.relative_to(source).as_posix()), path.read_bytes(),
                                     compress_type=zipfile.ZIP_DEFLATED)
        bundle_sha = sha256(bundle)
        goroot = Path(subprocess.check_output([go, 'env', 'GOROOT'], env=env, text=True).strip())
        for platform, arch in TARGETS.items():
            component = staged / ('FB2Export-' + platform)
            component.mkdir()
            binary = component / 'fbc.exe'
            subprocess.run([go, 'build', '-mod=vendor', '-trimpath', '-buildvcs=false', '-o',
                            str(binary), './cmd/fbc'], cwd=source,
                           env=dict(env, GOOS='windows', GOARCH=arch, GO386='sse2', GOAMD64='v1'),
                           check=True)
            for file, name in ((source / 'LICENSE', 'LICENSE.txt'), (PATCH, PATCH.name),
                               (source / 'convert/pdf/fonts/OFL.txt', 'Noto-OFL.txt'),
                               (goroot / 'LICENSE', 'GO-LICENSE.txt'), (goroot / 'PATENTS', 'GO-PATENTS.txt')):
                shutil.copyfile(file, component / name)
            metadata = dict(format=1, platform=platform, commit=COMMIT, go=GO_VERSION,
                            sha256=sha256(binary), patch_sha256=sha256(PATCH), source_sha256=bundle_sha)
            (component / 'RUNTIME.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='ascii')
        staged.rename(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in (*INPUTS, 'fonts', 'go', 'output'):
        parser.add_argument('--' + option, type=Path, required=True)
    build(parser.parse_args())
