#!/usr/bin/env python3
"""Real native pipe/socket backpressure, SIGPIPE and descriptor ownership checks.
The caller supplies the rebuilt process4cj library; this script never compiles.
"""
import argparse
import ctypes
import errno
import fcntl
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
import unittest

LIB = None
class NativeBorrowedWriterTests(unittest.TestCase):
    def setUp(self):
        self.read_fd,self.write_fd=os.pipe()
        self.original=fcntl.fcntl(self.write_fd,fcntl.F_GETFL)
        flags=ctypes.c_int32()
        self.held=LIB.process4cj_borrow_writer(self.write_fd,ctypes.byref(flags))
        self.assertGreaterEqual(self.held,0);self.flags=flags.value
    def tearDown(self):
        if self.held>=0:self.assertEqual(LIB.process4cj_release_writer(self.held,self.flags),0)
        for name in ('read_fd','write_fd'):
            value=getattr(self,name)
            if value>=0:os.close(value)
    def test_backpressure_poll_and_write_are_bounded(self):
        data=ctypes.create_string_buffer(b'x'*4096)
        total=0
        while True:
            count=LIB.process4cj_try_write(self.held,data,4096)
            self.assertGreaterEqual(count,0)
            if count==0:break
            total+=count;self.assertLess(total,32*1024*1024)
        start=time.monotonic()
        for _ in range(5):
            self.assertEqual(LIB.process4cj_wait_writable(self.held,10),0)
            self.assertEqual(LIB.process4cj_try_write(self.held,data,4096),0)
        self.assertLess(time.monotonic()-start,0.5)
        # A caller can observe cancellation between bounded native calls.
        self.assertGreater(total,0)
    def test_partial_write_then_restore_does_not_close_borrowed_fd(self):
        data=ctypes.create_string_buffer(b'hello')
        self.assertEqual(LIB.process4cj_try_write(self.held,data,5),5)
        self.assertEqual(os.read(self.read_fd,5),b'hello')
        self.assertEqual(LIB.process4cj_release_writer(self.held,self.flags),0);self.held=-1
        self.assertEqual(fcntl.fcntl(self.write_fd,fcntl.F_GETFL),self.original)
        os.write(self.write_fd,b'after');self.assertEqual(os.read(self.read_fd,5),b'after')
    def test_closed_peer_returns_error_without_sigpipe_termination(self):
        os.close(self.read_fd);self.read_fd=-1
        self.assertEqual(LIB.process4cj_wait_writable(self.held,10),-errno.EPIPE)
        previous=signal.signal(signal.SIGPIPE,signal.SIG_DFL)
        try:self.assertEqual(LIB.process4cj_try_write(self.held,ctypes.create_string_buffer(b'x'),1),-errno.EPIPE)
        finally:signal.signal(signal.SIGPIPE,previous)
    def test_duplicate_pins_description_across_original_number_reuse(self):
        old=self.write_fd;os.close(old);self.write_fd=-1
        other=os.open('/dev/null',os.O_WRONLY)
        if other!=old:os.dup2(other,old);os.close(other);other=old
        before=fcntl.fcntl(other,fcntl.F_GETFL)
        try:
            self.assertEqual(LIB.process4cj_release_writer(self.held,self.flags),0);self.held=-1
            self.assertEqual(fcntl.fcntl(other,fcntl.F_GETFL),before)
            self.assertEqual(os.write(other,b'alive'),5)
        finally:os.close(other)
    def test_unsupported_regular_output_is_rejected_without_flag_change(self):
        fd=os.open('/dev/null',os.O_WRONLY)
        try:
            before=fcntl.fcntl(fd,fcntl.F_GETFL);flags=ctypes.c_int32()
            self.assertEqual(LIB.process4cj_borrow_writer(fd,ctypes.byref(flags)),-errno.ENOTSUP)
            self.assertEqual(fcntl.fcntl(fd,fcntl.F_GETFL),before)
        finally:os.close(fd)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--library',type=Path,required=True);args=parser.parse_args()
    LIB=ctypes.CDLL(str(args.library.resolve()))
    LIB.process4cj_borrow_writer.argtypes=[ctypes.c_int32,ctypes.POINTER(ctypes.c_int32)];LIB.process4cj_borrow_writer.restype=ctypes.c_int32
    LIB.process4cj_try_write.argtypes=[ctypes.c_int32,ctypes.c_void_p,ctypes.c_int64];LIB.process4cj_try_write.restype=ctypes.c_int64
    LIB.process4cj_wait_writable.argtypes=[ctypes.c_int32,ctypes.c_int32];LIB.process4cj_wait_writable.restype=ctypes.c_int32
    LIB.process4cj_release_writer.argtypes=[ctypes.c_int32,ctypes.c_int32];LIB.process4cj_release_writer.restype=ctypes.c_int32
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeBorrowedWriterTests))
    if result.testsRun!=5 or result.skipped or not result.wasSuccessful():raise SystemExit(1)
    print('Borrowed pipe writer native contract passed: 5 actual descriptor cases')
