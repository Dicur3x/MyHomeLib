"""Test-only subprocess runner: timeouts reap a Windows process tree."""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys


class BasicLimits(ctypes.Structure):
    _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                ('flags', wintypes.DWORD), ('minimum', ctypes.c_size_t),
                ('maximum', ctypes.c_size_t), ('active', wintypes.DWORD),
                ('affinity', ctypes.c_size_t), ('priority', wintypes.DWORD),
                ('scheduling', wintypes.DWORD)]


class ExtendedLimits(ctypes.Structure):
    _fields_ = [('basic', BasicLimits), ('io', ctypes.c_uint64 * 6),
                ('process_memory', ctypes.c_size_t), ('job_memory', ctypes.c_size_t),
                ('peak_process_memory', ctypes.c_size_t), ('peak_job_memory', ctypes.c_size_t)]


def run_owned(arguments, *, timeout, **options):
    if os.name != 'nt':
        return subprocess.run(arguments, timeout=timeout, **options)
    if any(name in options for name in ('stdin', 'input')):
        raise ValueError('The test launcher owns its startup gate')
    capture = options.pop('capture_output', False)
    if capture:
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check = options.pop('check', False)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [wintypes.LPVOID, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    kernel.SetInformationJobObject.restype = wintypes.BOOL
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel.TerminateJobObject.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise ctypes.WinError(ctypes.get_last_error())
    process = None
    try:
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise ctypes.WinError(ctypes.get_last_error())
        flags = options.pop('creationflags', 0) | subprocess.CREATE_NO_WINDOW
        launcher = [sys.executable, '-I', '-B', str(Path(__file__).resolve()), '--launch',
                    json.dumps([str(value) for value in arguments], ensure_ascii=True)]
        process = subprocess.Popen(launcher, stdin=subprocess.PIPE, creationflags=flags, **options)
        # The launcher cannot spawn the real command until assignment succeeds.
        if not kernel.AssignProcessToJobObject(job, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            stdout, stderr = process.communicate('go\n' if process.text_mode else b'go\n', timeout=timeout)
        except BaseException as error:
            if not kernel.TerminateJobObject(job, 1):
                raise ctypes.WinError(ctypes.get_last_error()) from error
            stdout, stderr = process.communicate(timeout=15)
            if isinstance(error, subprocess.TimeoutExpired):
                error.cmd, error.stdout, error.stderr = arguments, stdout, stderr
            raise
        result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
    finally:
        # Only this unnamed job and the gated launcher belong to this call.
        kernel.CloseHandle(job)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=15)


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != '--launch' or sys.stdin.buffer.readline().rstrip(b'\r\n') != b'go':
        raise SystemExit(125)
    code = subprocess.run(json.loads(sys.argv[2])).returncode
    if os.name == 'nt':
        exit_process = ctypes.WinDLL('kernel32').ExitProcess
        exit_process.argtypes = [wintypes.UINT]
        exit_process.restype = None
        exit_process(code & 0xffffffff)
    raise SystemExit(code)
