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
import os
from pathlib import Path
import re
import secrets
import shutil
import struct
import subprocess
import tempfile
import time


def require_output_reserve(*folders):
    for folder in folders:
        probe = folder
        while not probe.exists():
            probe = probe.parent
        if shutil.disk_usage(probe).free < 512 * 1024**2:
            raise OSError('Build stopped: keep at least 512 MiB free on output/temp volume: ' + str(probe))


def terminal_build_log(text):
    # AutoBuild can keep its editor open after either compiler outcome. Wait
    # for its complete fresh report, not for editor shutdown or a deadline.
    return (re.search(r'(?m)^(?:Success|Failed)\r?$', text) is not None and
            re.search(r'(?m)^Elapsed time:', text) is not None)


def build(project, platform, binary, logs, ide, required_text=(), visible=False, timeout=180):
    if os.name == 'nt' and shutil.disk_usage(os.environ.get('SystemDrive', 'C:') + '\\').free < 8*1024**3:
        raise OSError('Build stopped: keep at least 8 GiB free on the system drive.')
    project, binary, logs, ide = [Path(p).resolve() for p in (project, binary, logs, ide)]
    if project.suffix != '.dproj' or not ide.is_file():
        raise ValueError('A Delphi project and installed IDE are required')
    original = project.read_bytes()
    pattern = rb'(<Platform\s+Condition="[^"]*">)(Win32|Win64)(</Platform>)'
    matches = list(re.finditer(pattern, original))
    if len(matches) != 1:
        raise ValueError('Expected one explicit default project platform')
    logs.mkdir(parents=True, exist_ok=True)
    require_output_reserve(logs, binary.parent)
    token = secrets.token_hex(6)
    log = logs / (project.stem + '-' + platform + '-' + token + '.err')
    clone = None
    if matches[0][2].decode() != platform:
        clone = project.with_name('HomeLibreBuild' + token + platform + '.dproj')
        if clone.exists():
            raise FileExistsError(clone)
        clone.write_bytes(re.sub(pattern, lambda m: m[1] + platform.encode() + m[3], original))
    # Keep IDE/compiler temporary data with the explicitly chosen build logs.
    # Every invocation owns a fresh directory and reaps its IDE before cleanup.
    build_temp = Path(tempfile.mkdtemp(prefix='ide-temp-' + token + '-', dir=logs))
    temp_identity = build_temp.stat(follow_symlinks=False)
    result = None
    started = time.time_ns()
    try:
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 5 if visible else 0
        # These are Delphi projects; do not inherit another IDE personality
        # from a user's last interactive session.
        process = subprocess.Popen([str(ide), '-pDelphi', '-ns', '-b', '-o' + str(log), str(clone or project)],
                                   startupinfo=startup,
                                   env={**os.environ, 'TEMP': str(build_temp), 'TMP': str(build_temp)})
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                require_output_reserve(logs, binary.parent)
                if os.name == 'nt' and shutil.disk_usage(os.environ.get('SystemDrive', 'C:') + '\\').free < 8*1024**3:
                    raise OSError('Build stopped: system drive reserve fell below 8 GiB.')
                if log.is_file():
                    try:
                        text = log.read_text(encoding='utf-8', errors='replace')
                    except PermissionError:
                        # AutoBuild briefly holds its log exclusively while
                        # flushing it. Keep the same build alive and inspect
                        # again under the existing deadline and disk guard.
                        text = ''
                    # AutoBuild can leave its own IDE open after the compiler
                    # has finished. The fresh log and executable, rather than
                    # editor shutdown, are the completion authority.
                    if terminal_build_log(text):
                        break
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(process.args, timeout)
                time.sleep(.25)
            if not log.is_file():
                raise RuntimeError(f'IDE build failed ({process.returncode}); log: {log}')
        finally:
            # This is only the process started above, never an existing IDE.
            # Reap it before checking project immutability or removing a clone.
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
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
        # Only the freshly created directory, still at its original identity.
        # A transient lock may retain it; never turn successful compilation
        # into a failed build merely because cleanup needs another attempt.
        try:
            current = build_temp.stat(follow_symlinks=False)
            if (not build_temp.is_symlink() and build_temp.resolve().parent == logs and
                    (current.st_dev, current.st_ino) == (temp_identity.st_dev, temp_identity.st_ino)):
                shutil.rmtree(build_temp)
        except OSError:
            pass
        if result is not None:
            result['temporary_directory_removed'] = not build_temp.exists()
            if build_temp.exists():
                result['retained_temporary_directory'] = str(build_temp)
        if clone:
            # This unpredictable prefix was created only by this invocation.
            generated = [*project.parent.glob(clone.stem + '.*'),
                         clone.with_name(clone.stem + 'Resource.rc')]
            for path in generated:
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
    parser.add_argument('--timeout', type=int, default=180, help='Build timeout in seconds; use a longer bound for the full application under load')
    args = parser.parse_args()
    build(args.project, args.platform, args.binary, args.logs, args.ide, args.require_text, args.visible, args.timeout)
