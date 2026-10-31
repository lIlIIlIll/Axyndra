#!/usr/bin/env python3
"""Real C FFI tests for read-view held handles; no privilege, fake stat, or fake IO.
Builds the exact production C plus a test-only open-audit/barrier translation unit.
Neither library replaces the shipped native artifact. The caller owns compiler scheduling.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

LIB = None
NORMAL = None

def bind(path, instrumented=False):
    lib = ctypes.CDLL(str(path))
    lib.axyndra_read_view_probe.argtypes=[ctypes.c_char_p,ctypes.c_void_p,ctypes.c_int64]
    lib.axyndra_read_view_probe.restype=ctypes.c_int32
    lib.axyndra_read_view_copy.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int64]
    lib.axyndra_read_view_copy.restype=ctypes.c_int64
    lib.axyndra_read_view_directory.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_int64]
    lib.axyndra_read_view_directory.restype=ctypes.c_int64
    if instrumented:
        lib.read_view_test_reset.argtypes=[ctypes.c_int]
        for name in ['entered','content_opens','nonregular_opens']:
            getattr(lib,'read_view_test_'+name).restype=ctypes.c_int
    return lib

def witness(lib,path):
    value=ctypes.create_string_buffer(256)
    result=lib.axyndra_read_view_probe(os.fsencode(path),value,256)
    if result != 0: raise AssertionError(f'real read-view probe failed: errno {-result}')
    return value.value

def copy(lib,path,identity,dest,maximum=1024):
    return lib.axyndra_read_view_copy(os.fsencode(path),identity,os.fsencode(dest),maximum)

def names(lib,path,identity):
    result=ctypes.create_string_buffer(65536)
    count=lib.axyndra_read_view_directory(os.fsencode(path),identity,result,len(result))
    return count, result.raw[:max(0,count)].split(b'\0')[:-1]

class ReadViewNativeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='read-view-ffi-');self.root=Path(self.temp.name)
        LIB.read_view_test_reset(0)
    def tearDown(self):
        LIB.read_view_test_release();self.temp.cleanup()
    def file(self,name='source',content=b'approved bytes'):
        path=self.root/name;path.write_bytes(content);return path
    def test_regular_copy_and_private_mode_on_uninstrumented_library(self):
        src=self.file();dst=self.root/'copy'
        self.assertEqual(copy(NORMAL,src,witness(NORMAL,src),dst),14)
        self.assertEqual(dst.read_bytes(),b'approved bytes');self.assertEqual(dst.stat().st_mode & 0o777,0o600)
    def test_directory_on_uninstrumented_library(self):
        self.file('alpha');self.file('snow-雪')
        count,entries=names(NORMAL,self.root,witness(NORMAL,self.root))
        self.assertGreater(count,0);self.assertEqual(set(entries),{b'alpha','snow-雪'.encode()})
    def test_fifo_replacement_has_zero_content_open(self):
        src=self.file();identity=witness(LIB,src);src.unlink();os.mkfifo(src)
        LIB.read_view_test_reset(0);start=time.monotonic()
        self.assertLess(copy(LIB,src,identity,self.root/'copy'),0)
        self.assertLess(time.monotonic()-start,1)
        self.assertEqual(LIB.read_view_test_content_opens(),0)
        self.assertEqual(LIB.read_view_test_nonregular_opens(),0)
        self.assertFalse((self.root/'copy').exists())
    def test_actual_device_has_zero_content_open(self):
        identity=witness(LIB,self.file());LIB.read_view_test_reset(0)
        self.assertLess(copy(LIB,Path('/dev/null'),identity,self.root/'copy'),0)
        self.assertEqual(LIB.read_view_test_content_opens(),0)
        self.assertEqual(LIB.read_view_test_nonregular_opens(),0)
    def test_directory_replaced_with_device_or_fifo_has_zero_content_open(self):
        directory=self.root/'directory';directory.mkdir();identity=witness(LIB,directory)
        directory.rmdir();os.mkfifo(directory)
        self.assertLess(names(LIB,directory,identity)[0],0)
        self.assertLess(names(LIB,Path('/dev/null'),identity)[0],0)
        self.assertEqual(LIB.read_view_test_content_opens(),0)
    def paused(self,call,change):
        results=[];errors=[];LIB.read_view_test_reset(1)
        def work():
            try:results.append(call())
            except BaseException as error:errors.append(error)
        thread=threading.Thread(target=work);thread.start()
        try:
            deadline=time.monotonic()+2
            while not LIB.read_view_test_entered() and thread.is_alive() and time.monotonic()<deadline:time.sleep(.001)
            self.assertEqual(LIB.read_view_test_entered(),1,'must reach actual held fd reopen boundary')
            change()
        finally:
            LIB.read_view_test_release();thread.join(4)
        self.assertFalse(thread.is_alive());self.assertFalse(errors);self.assertEqual(len(results),1)
        return results[0]
    def test_file_rename_to_fifo_after_handle_validation_cannot_redirect_copy(self):
        src=self.file();identity=witness(LIB,src);dest=self.root/'copy'
        def change():
            held=self.root/'held';before=src.stat()
            src.rename(held);os.mkfifo(src)
            os.utime(held,ns=(before.st_atime_ns,before.st_mtime_ns+1))
            self.assertNotEqual(witness(LIB,held),identity,'actual held inode witness must change')
        result=self.paused(lambda:copy(LIB,src,identity,dest),change)
        # Explicit metadata mutation changes the held inode witness; reject it.
        self.assertLess(result,0);self.assertFalse(dest.exists())
        self.assertEqual(LIB.read_view_test_nonregular_opens(),0)
    def test_directory_rename_after_validation_enumerates_only_held_inode(self):
        src=self.root/'directory';src.mkdir();(src/'approved').touch();identity=witness(LIB,src)
        def change():src.rename(self.root/'held');src.mkdir();(src/'attacker').touch()
        count,entries=self.paused(lambda:names(LIB,src,identity),change)
        self.assertGreater(count,0);self.assertEqual(entries,[b'approved'])
        self.assertEqual(LIB.read_view_test_nonregular_opens(),0)
    def test_symlink_hardlink_and_stale_bytes_never_create_destination(self):
        src=self.file();identity=witness(LIB,src);linked=self.root/'linked';linked.symlink_to(src)
        self.assertLess(copy(NORMAL,linked,identity,self.root/'a'),0)
        os.link(src,self.root/'hard');self.assertLess(copy(NORMAL,src,identity,self.root/'b'),0)
        (self.root/'hard').unlink();identity=witness(NORMAL,src);src.write_bytes(b'changed data')
        self.assertLess(copy(NORMAL,src,identity,self.root/'c'),0)
        for name in 'abc':self.assertFalse((self.root/name).exists())
    def test_bounds_and_destination_exclusivity_remain_exact(self):
        src=self.file();identity=witness(NORMAL,src);dest=self.file('destination',b'untouched')
        self.assertLess(copy(NORMAL,src,identity,dest),0);self.assertEqual(dest.read_bytes(),b'untouched')
        self.assertLess(copy(NORMAL,src,identity,self.root/'small',3),0)
        self.assertFalse((self.root/'small').exists())

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--cc',default=os.environ.get('AXYNDRA_NATIVE_CC','clang'))
    parser.add_argument('--output',type=Path);args=parser.parse_args()
    source=args.source.resolve();probe=Path(__file__).with_name('read_view_probe.c').resolve()
    if not source.is_file() or not probe.is_file():raise SystemExit('actual source/probe is required')
    with tempfile.TemporaryDirectory(prefix='read-view-build-') as directory:
        directory=Path(directory);plain=directory/'plain.so';instrumented=directory/'instrumented.so'
        common=[args.cc,'-std=c11','-O1','-fPIC','-shared','-Wl,-z,relro,-z,now']
        subprocess.run([*common,str(source),'-o',str(plain)],check=True)
        subprocess.run([*common,f'-DAXYNDRA_READ_VIEW_SOURCE="{source}"',str(probe),'-o',str(instrumented)],check=True)
        NORMAL=bind(plain);LIB=bind(instrumented,True)
        result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReadViewNativeTests))
        report={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),
                'actual':result.testsRun,'expected':9,'failures':len(result.failures),'errors':len(result.errors),'skipped':len(result.skipped)}
        report['status']='PASS' if result.testsRun==9 and not result.skipped and result.wasSuccessful() else 'FAIL'
        if args.output:args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2)+'\n')
        if report['status']!='PASS':raise SystemExit(1)
        print('Read-view native FFI contract passed: 9 actual file/descriptor cases')
