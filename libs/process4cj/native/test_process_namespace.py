#!/usr/bin/env python3
"""Actual owned Linux namespace/PID contract. Caller supplies a fresh library.

No compiler, package fixture, canonical Source, approval or host grant is mocked.
These tests exercise raw process/namespace ownership only. Host launch authority
and bounded filesystem/network policy require the separate canonical contract.
"""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import select
import time
import unittest

LIB = None
P64 = ctypes.POINTER(ctypes.c_int64)
P32 = ctypes.POINTER(ctypes.c_int32)

def arguments(borrowed, program, argv):
    prefix = [] if borrowed else ['--unshare-user', '--disable-userns', '--unshare-pid', '--unshare-net']
    return prefix + ['--die-with-parent', '--unshare-ipc', '--unshare-uts', '--unshare-cgroup-try',
        '--ro-bind', '/', '/', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
        '--chdir', '/tmp', '--clearenv', '--', program] + argv

def native_spawn(program, argv, handle=None):
    encoded = [program.encode()] + [value.encode() for value in argv]
    vector = (ctypes.c_char_p * (len(encoded) + 1))(*encoded, None)
    environment = (ctypes.c_char_p * 1)(None)
    pid = ctypes.c_int64()
    fds = [ctypes.c_int32(-1) for _ in range(4)]
    common = [program.encode(), vector, environment, b'', ctypes.byref(pid)] + [ctypes.byref(fd) for fd in fds]
    if handle is None:
        error = LIB.process4cj_spawn(*common[:4], 1, *common[4:])
    else:
        error = LIB.process4cj_spawn_in_namespace(handle, *common)
    if error:
        return error, None
    process = dict(pid=pid.value, start=LIB.process4cj_start_time(pid.value), fds=[fd.value for fd in fds])
    assert process['start'] > 0
    return 0, process

def line(process, timeout=2):
    fd = process['fds'][1]
    result = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        value = os.read(fd, 1)
        if value == b'\n':
            return bytes(result)
        if not value:
            break
        result.extend(value)
        if len(result) > 16384:
            raise AssertionError('namespace fixture output exceeded bound')
    raise AssertionError('namespace fixture did not produce its bounded ready line')

class NativeOwnedNamespaceTests(unittest.TestCase):
    def setUp(self):
        self.processes = []
        self.leases = []

    def tearDown(self):
        for lease in self.leases:
            LIB.process4cj_namespace_close(lease)
        for process in reversed(self.processes):
            expected = errno.ESRCH if process.get('physically_reaped', False) else 0
            self.assertEqual(LIB.process4cj_terminate_tree(process['pid'], process['start'], 0), expected)
            for fd in process['fds']:
                self.assertEqual(LIB.process4cj_close(fd), 0)
            LIB.process4cj_wait(process['pid'])

    def spawn(self, program, argv, handle=None):
        error, process = native_spawn(program, argv, handle)
        self.assertEqual(error, 0, f'actual native namespace spawn errno={error}')
        self.processes.append(process)
        return process

    def service(self, socket_peer=False):
        script = "import os,json,sys; print(json.dumps({'pid':os.getpid()}),flush=True); sys.stdin.buffer.read()"
        if socket_peer:
            script = ("import os,json,sys,socket; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1); "
                "print(json.dumps({'pid':os.getpid(),'port':s.getsockname()[1],"
                "'namespaces':{n:os.readlink('/proc/self/ns/'+n) for n in ['user','net','pid']}}),flush=True); "
                "c,_=s.accept(); c.sendall(b'OWNED'); c.close(); sys.stdin.buffer.read()")
        process = self.spawn('/usr/bin/bwrap', arguments(False, '/usr/bin/python3', ['-u', '-c', script]))
        ready = json.loads(line(process))
        self.assertEqual(ready['pid'], 2)
        return process, ready

    def capture(self, service):
        handle = ctypes.c_int64()
        error = LIB.process4cj_namespace_capture(service['pid'], service['start'], ctypes.byref(handle))
        self.assertEqual(error, 0)
        self.assertGreater(handle.value, 0)
        self.leases.append(handle.value)
        return handle.value

    def identify(self, handle, process, executable):
        out = [ctypes.c_int64() for _ in range(3)]
        error = LIB.process4cj_namespace_payload(handle, process['pid'], process['start'],
            executable.encode(), *[ctypes.byref(item) for item in out])
        return error, [item.value for item in out]

    def test_actual_payload_shares_exact_service_namespaces_and_loopback(self):
        service, ready = self.service(True)
        lease = self.capture(service)
        script = ("import os,json,sys,socket; c=socket.create_connection(('127.0.0.1'," + str(ready['port']) + ")); "
            "ack=c.recv(5).decode(); c.close(); print(json.dumps({'pid':os.getpid(),'ack':ack,"
            "'namespaces':{n:os.readlink('/proc/self/ns/'+n) for n in ['user','net','pid']},"
            "'held_fds':{n:os.readlink('/proc/self/fd/'+n) for n in os.listdir('/proc/self/fd') if n.isdigit() and int(n)>2 and os.path.exists('/proc/self/fd/'+n)}}),flush=True); "
            "sys.stdin.buffer.read()")
        child = self.spawn('/usr/bin/bwrap', arguments(True, '/usr/bin/python3', ['-u', '-c', script]), lease)
        actual = json.loads(line(child))
        self.assertEqual(actual['ack'], 'OWNED')
        self.assertEqual(actual['namespaces'], ready['namespaces'])
        self.assertFalse(any(value.startswith(('user:[', 'net:[', 'pid:[')) for value in actual['held_fds'].values()), actual['held_fds'])
        self.assertGreater(actual['pid'], 2)
        error, identity = self.identify(lease, child, '/usr/bin/python3')
        self.assertEqual(error, 0)
        host_pid, namespace_pid, started = identity
        self.assertEqual(namespace_pid, actual['pid'])
        self.assertNotIn(host_pid, [service['pid'], child['pid']])
        self.assertEqual(started, LIB.process4cj_start_time(host_pid))
        self.assertGreater(started, 0)
        self.assertEqual(LIB.process4cj_namespace_validate(lease), 0)

        # Both option operands and actual payload arguments may literally look
        # like namespace controls. The complete original vector is preserved;
        # the >4088 tail also proves no invented argument-count ceiling.
        literal_args = ['--', '--userns', '--sync-fd', '--as-pid-1', '--args'] + ['v'] * 4097
        literal_script = ("import os,json,sys; print(json.dumps({'env':"
            "[os.environ['P4_LITERAL_DELIMITER'],os.environ['P4_LITERAL_OPTION']],"
            "'args':sys.argv[1:6],'count':len(sys.argv)-1,'tail':sys.argv[6:].count('v'),"
            "'namespaces':{n:os.readlink('/proc/self/ns/'+n) for n in ['user','net','pid']},"
            "'held_fds':{n:os.readlink('/proc/self/fd/'+n) for n in os.listdir('/proc/self/fd') if n.isdigit() and int(n)>2 and os.path.exists('/proc/self/fd/'+n)}}),flush=True); "
            "sys.stdin.buffer.read()")
        vector = arguments(True, '/usr/bin/python3', ['-u', '-c', literal_script] + literal_args)
        delimiter = vector.index('--')
        vector[delimiter:delimiter] = ['--setenv', 'P4_LITERAL_DELIMITER', '--',
            '--setenv', 'P4_LITERAL_OPTION', '--userns']
        literals = self.spawn('/usr/bin/bwrap', vector, lease)
        literal = json.loads(line(literals))
        self.assertEqual(literal['env'], ['--', '--userns'])
        self.assertEqual(literal['args'], literal_args[:5])
        self.assertEqual(literal['count'], len(literal_args))
        self.assertEqual(literal['tail'], 4097)
        self.assertEqual(literal['namespaces'], ready['namespaces'])
        self.assertFalse(any(value.startswith(('user:[', 'net:[', 'pid:[')) for value in literal['held_fds'].values()), literal['held_fds'])

    def test_actual_main_payload_is_not_its_same_executable_descendant(self):
        service, _ = self.service()
        lease = self.capture(service)
        script = ("import os,json,sys,time\nchild=os.fork()\n"
            "if child==0:\n time.sleep(30)\n os._exit(0)\n"
            "print(json.dumps({'pid':os.getpid(),'child_pid':child}),flush=True)\n"
            "sys.stdin.buffer.read()\n")
        process = self.spawn('/usr/bin/bwrap', arguments(True, '/usr/bin/python3', ['-u', '-c', script]), lease)
        actual = json.loads(line(process))
        self.assertGreater(actual['child_pid'], actual['pid'])
        error, identity = self.identify(lease, process, '/usr/bin/python3')
        self.assertEqual(error, 0)
        self.assertEqual(identity[1], actual['pid'])
        self.assertNotEqual(identity[1], actual['child_pid'])
        self.assertEqual(self.identify(lease, process, '/bin/sh')[0], errno.EAGAIN)
        self.assertEqual(self.identify(lease, process, '/usr/bin/python3')[1], identity)

    def test_unisolated_actual_owned_process_has_no_sandbox_namespace(self):
        process = self.spawn('/bin/sleep', ['30'])
        handle = ctypes.c_int64()
        self.assertEqual(LIB.process4cj_namespace_capture(process['pid'], process['start'], ctypes.byref(handle)), errno.EAGAIN)
        self.assertEqual(handle.value, 0)

    def test_wrong_actual_start_time_does_not_capture_descriptors(self):
        service, _ = self.service()
        handle = ctypes.c_int64()
        self.assertEqual(LIB.process4cj_namespace_capture(service['pid'], service['start'] + 1, ctypes.byref(handle)), errno.ESRCH)
        self.assertEqual(handle.value, 0)

    def test_wrong_executable_cannot_project_setup_or_other_payload_pid(self):
        service, _ = self.service()
        lease = self.capture(service)
        child = self.spawn('/usr/bin/bwrap', arguments(True, '/usr/bin/python3', ['-u', '-c',
            "import sys; print('READY',flush=True); sys.stdin.buffer.read()"]), lease)
        self.assertEqual(line(child), b'READY')
        error, identity = self.identify(lease, child, '/bin/sleep')
        self.assertEqual(error, errno.EAGAIN)
        self.assertEqual(identity, [0, 0, 0])

        # A literal '--' setenv VALUE does not end bwrap options. No foreign
        # namespace, recursive args file or lifetime override may be accepted
        # afterwards. Every refused launch must release its four copied FDs.
        original = arguments(True, '/usr/bin/python3', ['-u', '-c',
            "import sys; print('READY',flush=True); sys.stdin.buffer.read()"])
        delimiter = original.index('--')
        for option in ['--userns', '--userns2', '--pidns', '--unshare-user',
            '--disable-userns', '--sync-fd', '--as-pid-1', '--args', '--unshare-net', '--unshare-pid']:
            vector = original[:delimiter] + ['--setenv', 'P4_LITERAL_VALUE', '--', option, '0'] + original[delimiter:]
            before = len(os.listdir('/proc/self/fd'))
            error, refused = native_spawn('/usr/bin/bwrap', vector, lease)
            self.assertEqual(error, errno.EINVAL, option)
            self.assertIsNone(refused, option)
            self.assertEqual(len(os.listdir('/proc/self/fd')), before, option)
        for vector in [original[:delimiter + 1], ['--setenv', 'P4_INCOMPLETE']]:
            before = len(os.listdir('/proc/self/fd'))
            error, refused = native_spawn('/usr/bin/bwrap', vector, lease)
            self.assertEqual(error, errno.EINVAL)
            self.assertIsNone(refused)
            self.assertEqual(len(os.listdir('/proc/self/fd')), before)

    def test_dead_original_service_namespace_cannot_start_another_process(self):
        service, _ = self.service()
        lease = self.capture(service)
        self.assertEqual(LIB.process4cj_terminate_tree(service['pid'], service['start'], 0), 0)
        self.assertGreaterEqual(LIB.process4cj_wait(service['pid']), 0)
        service['physically_reaped'] = True
        self.assertEqual(LIB.process4cj_namespace_validate(lease), errno.ESRCH)
        error, child = native_spawn('/bin/true', [], lease)
        self.assertEqual(error, errno.ESRCH)
        self.assertIsNone(child)

    def test_namespace_close_releases_exact_three_descriptors(self):
        service, _ = self.service()
        before = len(os.listdir('/proc/self/fd'))
        lease = self.capture(service)
        self.assertEqual(len(os.listdir('/proc/self/fd')), before + 4)
        self.leases.remove(lease)
        LIB.process4cj_namespace_close(lease)
        self.assertEqual(len(os.listdir('/proc/self/fd')), before)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    args = parser.parse_args()
    LIB = ctypes.CDLL(str(args.library.resolve(strict=True)))
    LIB.process4cj_spawn.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p),
        ctypes.c_char_p, ctypes.c_int32, P64, P32, P32, P32, P32]
    LIB.process4cj_spawn.restype = ctypes.c_int32
    LIB.process4cj_spawn_in_namespace.argtypes = [ctypes.c_int64, ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p),
        ctypes.POINTER(ctypes.c_char_p), ctypes.c_char_p, P64, P32, P32, P32, P32]
    LIB.process4cj_spawn_in_namespace.restype = ctypes.c_int32
    LIB.process4cj_namespace_capture.argtypes = [ctypes.c_int64, ctypes.c_int64, P64]
    LIB.process4cj_namespace_capture.restype = ctypes.c_int32
    LIB.process4cj_namespace_validate.argtypes = [ctypes.c_int64]
    LIB.process4cj_namespace_validate.restype = ctypes.c_int32
    LIB.process4cj_namespace_close.argtypes = [ctypes.c_int64]
    LIB.process4cj_namespace_close.restype = None
    LIB.process4cj_namespace_payload.argtypes = [ctypes.c_int64, ctypes.c_int64, ctypes.c_int64, ctypes.c_char_p, P64, P64, P64]
    LIB.process4cj_namespace_payload.restype = ctypes.c_int32
    LIB.process4cj_start_time.argtypes = [ctypes.c_int64]
    LIB.process4cj_start_time.restype = ctypes.c_int64
    LIB.process4cj_terminate_tree.argtypes = [ctypes.c_int64, ctypes.c_int64, ctypes.c_int32]
    LIB.process4cj_terminate_tree.restype = ctypes.c_int32
    LIB.process4cj_wait.argtypes = [ctypes.c_int64]
    LIB.process4cj_wait.restype = ctypes.c_int64
    LIB.process4cj_close.argtypes = [ctypes.c_int32]
    LIB.process4cj_close.restype = ctypes.c_int32
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeOwnedNamespaceTests))
    if result.testsRun != 7 or result.skipped or not result.wasSuccessful():
        raise SystemExit(1)
    print('Owned sandbox namespace native contract passed: 7 actual ownership/PID cases')
