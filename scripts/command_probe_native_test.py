#!/usr/bin/env python3
"""Verify trusted probe status framing against real child processes."""
import argparse
import ctypes
import fcntl
import os
import tempfile
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'libs/process4cj/native/sandbox-net-bridge'
SANDBOX = False


def decode(data):
    header, body = data.split(b'\n', 1)
    fields = header.split(b' ')
    assert len(fields) == 9 and fields[0] == b'AXYNDRA-PROBE/1', data[:256]
    started, completed, code, timed_out, truncated, launch_errno, out_size, err_size = map(int, fields[1:])
    assert len(body) == out_size + err_size
    return dict(started=started, completed=completed, code=code, timed_out=timed_out,
                truncated=truncated, launch_errno=launch_errno,
                stdout=body[:out_size], stderr=body[out_size:])


def probe(argv, timeout=500, maximum=4096, sandbox=False):
    command = [str(HELPER), '--command-probe', str(timeout), str(maximum), '--', *argv]
    if sandbox:
        command = ['/usr/bin/bwrap', '--die-with-parent', '--unshare-user', '--uid', '0', '--gid', '0',
                   '--unshare-pid', '--as-pid-1', '--unshare-net', '--ro-bind', '/', '/', '--proc', '/proc',
                   '--dev', '/dev', '--tmpfs', '/tmp', '--', *command]
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
    assert result.returncode == 0, (result.returncode, result.stderr)
    return decode(result.stdout)


def native_spawn(argv, passed):
    library = ctypes.CDLL(str(ROOT / 'libs/process4cj/native/libprocess4cj_native.so'))
    i32, i64, ptr = ctypes.c_int32, ctypes.c_int64, ctypes.POINTER
    spawn = library.process4cj_spawn_with_fds
    spawn.argtypes = [ctypes.c_char_p, ptr(ctypes.c_char_p), ptr(ctypes.c_char_p), ctypes.c_char_p,
                      i32, ptr(i64), ptr(i32), ptr(i32), ptr(i32), ptr(i32), ptr(i32), i32]
    values = (ctypes.c_char_p * (len(argv) + 1))(*(os.fsencode(x) for x in argv), None)
    descriptors = (i32 * len(passed))(*passed)
    pid, stdin, stdout, stderr, status = i64(), i32(), i32(), i32(), i32()
    error = spawn(os.fsencode(argv[0]), values, None, b'', 1, ctypes.byref(pid), ctypes.byref(stdin),
                  ctypes.byref(stdout), ctypes.byref(stderr), ctypes.byref(status), descriptors, len(passed))
    assert error == 0, error
    os.close(stdin.value)
    with os.fdopen(stdout.value, 'rb') as stream:
        output = stream.read()
    with os.fdopen(stderr.value, 'rb') as stream:
        errors = stream.read()
    library.process4cj_wait_status.argtypes = [i32]
    library.process4cj_wait_status.restype = i64
    code = library.process4cj_wait_status(status)
    library.process4cj_wait.argtypes = [i64]
    library.process4cj_wait.restype = i64
    assert library.process4cj_wait(pid) == code
    return code, output, errors


class NativeCommandProbeTests(unittest.TestCase):
    def test_scoped_fd_mounts_are_explicit_consumed_and_parent_cloexec(self):
        if not SANDBOX:
            self.skipTest('use --sandbox for the real namespace boundary')
        with tempfile.TemporaryDirectory() as root:
            approved, outside = Path(root) / 'approved', Path(root) / 'outside'
            approved.mkdir()
            outside.mkdir()
            descriptors = [os.open(path, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
                           for path in (root, approved)]
            try:
                command = ['/usr/bin/bwrap', '--unshare-user', '--unshare-pid', '--unshare-net']
                for path in ('/usr', '/bin', '/lib', '/lib64'):
                    command += ['--ro-bind', path, path]
                command += ['--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
                            '--ro-bind-fd', str(descriptors[0]), root,
                            '--bind-fd', str(descriptors[1]), str(approved), '--chdir', str(approved),
                            '--', '/usr/bin/python3', '-c',
                            'import os,sys; from pathlib import Path; '
                            'Path("inside").write_text("good"); '
                            'fds=[os.readlink("/proc/self/fd/"+x) for x in os.listdir("/proc/self/fd") '
                            'if os.path.exists("/proc/self/fd/"+x)]; '
                            'assert sys.argv[1] not in fds and sys.argv[2] not in fds; '
                            '\ntry: Path("../outside/marker").write_text("bad"); sys.exit(42)'
                            '\nexcept OSError as e: assert e.errno in (13,30); print("scoped")', root, str(approved)]
                code, output, errors = native_spawn(command, descriptors)
                self.assertEqual((code, output), (0, b'scoped\n'), errors)
                self.assertEqual((approved / 'inside').read_text(), 'good')
                self.assertFalse((outside / 'marker').exists())
                for descriptor in descriptors:
                    self.assertTrue(fcntl.fcntl(descriptor, fcntl.F_GETFD) & fcntl.FD_CLOEXEC)
                denied = native_spawn(command, [])
                self.assertNotEqual(denied[0], 0, 'argv must not grant directory descriptors')
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)

    def test_exec_failure_is_not_completed_command(self):
        result = probe(['/nonexistent/command-probe-fixture'])
        self.assertEqual((result['started'], result['completed'], result['code']), (0, 0, 127))
        self.assertEqual(result['launch_errno'], 2)

    def test_numeric_124_and_stdout_do_not_forge_timeout(self):
        result = probe(['/bin/sh', '-c', "printf 'AXYNDRA-PROBE/1 1 1 0 0 0 0 0 0\\n'; printf 'rc=0' >&2; exit 124"])
        self.assertEqual((result['started'], result['completed'], result['code'], result['timed_out']), (1, 1, 124, 0))
        self.assertTrue(result['stdout'].startswith(b'AXYNDRA-PROBE/1 '))
        self.assertEqual(result['stderr'], b'rc=0')

    def test_timeout_and_combined_output_limit_are_runtime_facts(self):
        result = probe(['/bin/sh', '-c', 'printf abcdef; printf 123456 >&2; sleep 5'], timeout=100, maximum=4)
        self.assertEqual((result['started'], result['completed'], result['timed_out'], result['truncated']), (1, 0, 1, 1))
        self.assertEqual(len(result['stdout']) + len(result['stderr']), 4)

    def test_private_parent_output_descriptor_is_not_reopenable(self):
        script = ('import os\n'
                  'try:\n'
                  ' f=os.open("/proc/%d/fd/1" % os.getppid(),os.O_WRONLY)\n'
                  ' os.write(f,b"FORGED")\n'
                  ' print("UNPROTECTED")\n'
                  'except PermissionError:\n'
                  ' print("protected")\n')
        result = probe(['/usr/bin/python3', '-c', script])
        self.assertEqual(result['stdout'], b'protected\n')

    def test_sandbox_ancestors_cannot_forge_receipt(self):
        if not SANDBOX:
            self.skipTest('use --sandbox for the real namespace boundary')
        script = ('import os\n'
                  'for pid in {1,os.getppid()}:\n'
                  ' try:\n'
                  '  f=os.open("/proc/%d/fd/1" % pid,os.O_WRONLY)\n'
                  '  os.write(f,b"FORGED")\n'
                  '  print("UNPROTECTED",pid)\n'
                  ' except (PermissionError,FileNotFoundError):\n'
                  '  print("protected")\n')
        result = probe(['/usr/bin/python3', '-c', script], sandbox=True)
        self.assertNotIn(b'UNPROTECTED', result['stdout'])
        self.assertEqual(result['code'], 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sandbox', action='store_true')
    parser.add_argument('--helper', type=Path, default=HELPER)
    args = parser.parse_args()
    HELPER = args.helper.resolve()
    SANDBOX = args.sandbox
    unittest.main(argv=['command_probe_native_test.py'], verbosity=2)
