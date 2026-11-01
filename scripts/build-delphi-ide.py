"""Build with the licensed Delphi IDE's documented AutoBuild interface.

Verified with the installed Delphi 13 Community Edition; IDE licence checks
stay intact. The default platform uses the original project so version resources
are generated normally. Another platform uses a short-lived sibling project;
relative source paths stay valid and the checked-in project is never rewritten.
Build the default platform first after changing project version resources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets
import struct
import subprocess
import time


def build(project, platform, binary, logs, ide, required_text=(), visible=False):
    project, binary, logs, ide = [Path(p).resolve() for p in (project, binary, logs, ide)]
    if project.suffix != '.dproj' or not ide.is_file():
        raise ValueError('A Delphi project and installed IDE are required')
    original = project.read_bytes()
    pattern = rb'(<Platform\s+Condition="[^"]*">)(Win32|Win64)(</Platform>)'
    matches = list(re.finditer(pattern, original))
    if len(matches) != 1:
        raise ValueError('Expected one explicit default project platform')
    logs.mkdir(parents=True, exist_ok=True)
    token = secrets.token_hex(6)
    log = logs / (project.stem + '-' + platform + '-' + token + '.err')
    clone = None
    if matches[0][2].decode() != platform:
        clone = project.with_name('HomeLibreBuild' + token + platform + '.dproj')
        if clone.exists():
            raise FileExistsError(clone)
        clone.write_bytes(re.sub(pattern, lambda m: m[1] + platform.encode() + m[3], original))
    started = time.time_ns()
    try:
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 5 if visible else 0
        completed = subprocess.run([str(ide), '-ns', '-b', '-o' + str(log), str(clone or project)],
                                   startupinfo=startup, timeout=180)
        if completed.returncode or not log.is_file():
            raise RuntimeError(f'IDE build failed ({completed.returncode}); log: {log}')
        text = log.read_text(encoding='utf-8', errors='replace')
        if not re.search(r'(?m)^Success\r?$', text):
            raise RuntimeError('IDE did not report a successful build; log: ' + str(log))
        if not binary.is_file() or binary.stat().st_mtime_ns < started:
            raise RuntimeError('Expected binary was not rebuilt; log: ' + str(log))
        data = binary.read_bytes()
        offset = struct.unpack_from('<I', data, 0x3c)[0]
        machine = 0x14c if platform == 'Win32' else 0x8664
        if data[:2] != b'MZ' or data[offset:offset+4] != b'PE\0\0' or struct.unpack_from('<H', data, offset+4)[0] != machine:
            raise RuntimeError('The actual binary architecture differs from the requested platform')
        if any(value.encode('utf-16le') not in data and value.encode() not in data for value in required_text):
            raise RuntimeError('The rebuilt binary lacks a required linked feature marker')
        if project.read_bytes() != original:
            raise RuntimeError('The IDE changed the original project; inspect it before continuing')
        result = dict(status='PASS', platform=platform, project=str(project), binary=str(binary),
                      sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), log=str(log),
                      original_project_unchanged=True, required_text=list(required_text),
                      interface='Documented bds.exe -b AutoBuild; compiler licence checks unchanged')
    finally:
        if clone:
            # This unpredictable prefix was created only by this invocation.
            for path in project.parent.glob(clone.stem + '.*'):
                if path.is_file() and not path.is_symlink():
                    path.unlink()
    report = log.with_suffix('.json')
    report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('--platform', choices=['Win32', 'Win64'], required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--logs', type=Path, required=True)
    parser.add_argument('--ide', type=Path, default=Path(r'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\bds.exe'))
    parser.add_argument('--require-text', action='append', default=[])
    parser.add_argument('--visible', action='store_true', help='Show IDE for interactive compiler-failure inspection')
    args = parser.parse_args()
    build(args.project, args.platform, args.binary, args.logs, args.ide, args.require_text, args.visible)
