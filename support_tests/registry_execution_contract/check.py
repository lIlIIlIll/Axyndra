#!/usr/bin/env python3
"""Real native snapshots/flock and two actual Cangjie registry processes.
Requires prebuilt production library plus both helpers. Does not compile or
substitute mock state. Unsupported/missing inputs are a hard failure.
"""
import argparse,ctypes,errno,json,os,platform,select,signal,subprocess,sys,tempfile,time,unittest
from pathlib import Path

def native(path):
    lib=ctypes.CDLL(path)
    signatures={
        'axyndra_registry_reader_acquire':([ctypes.c_char_p],ctypes.c_int64),
        'axyndra_registry_writer_acquire':([ctypes.c_char_p],ctypes.c_int64),
        'axyndra_registry_writer_release':([ctypes.c_int64],None),
        'axyndra_registry_writer_publication':([ctypes.c_int64,ctypes.c_bool],ctypes.c_int32),
        'axyndra_registry_snapshot_open':([ctypes.c_char_p],ctypes.c_int64),
        'axyndra_registry_snapshot_freeze':([ctypes.c_int64],ctypes.c_int32),
        'axyndra_registry_snapshot_validate':([ctypes.c_int64],ctypes.c_int32),
        'axyndra_registry_snapshot_close':([ctypes.c_int64],None)}
    for name,(args,ret) in signatures.items():getattr(lib,name).argtypes=args;getattr(lib,name).restype=ret
    return lib

def hold(library,directory):
    lib=native(library);held=lib.axyndra_registry_reader_acquire(os.fsencode(directory))
    if held<=0:raise RuntimeError(held)
    print('HELD',flush=True)
    try:sys.stdin.buffer.read(1)
    finally:lib.axyndra_registry_writer_release(held)

class RegistryExecutionProcesses(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='axyndra-registry-pin-');self.root=Path(self.temp.name)
        self.children=[];self.lib=native(OPTIONS.library);self.counter=0
    def tearDown(self):
        for child in self.children:
            if child.poll() is None:child.kill()
            child.communicate(timeout=5)
        self.temp.cleanup()
    def gate(self,command):
        self.counter+=1;gate=self.root/f'gate-{self.counter}'
        child=subprocess.Popen(command(gate),stdout=subprocess.PIPE,stderr=subprocess.PIPE);self.children.append(child)
        deadline=time.monotonic()+10
        while not Path(str(gate)+'.ready').exists():
            self.assertIsNone(child.poll(),'actual helper exited before READY')
            self.assertLess(time.monotonic(),deadline,'actual READY timeout');time.sleep(.005)
        return child,gate
    def finish(self,pair,expected=0):
        child,gate=pair;Path(str(gate)+'.go').write_text('go');out,err=child.communicate(timeout=15)
        self.assertEqual(child.returncode,expected,(out[:1024],err[:1024]));self.assertLess(len(out),4096)
        return out.decode().strip()
    def mutate(self,mode,source='',name='pin-fixture',expected=0):
        pair=self.gate(lambda g:[OPTIONS.writer,str(self.root/'settings'),str(self.root),str(g),mode,str(source),name])
        return self.finish(pair,expected)
    def package(self,version):
        p=self.root/('source-'+version);(p/'extensions').mkdir(parents=True)
        (p/'package.json').write_text(json.dumps({'name':'pin-fixture','version':version,'pi':{'extensions':['extensions/index.js']}}))
        (p/'extensions/index.js').write_text("throw new Error('MUST_NOT_RUN');")
        return p
    def enable(self):
        r=subprocess.run([OPTIONS.worker,str(self.root/'settings'),str(self.root),'unused','enable','pin-fixture'],capture_output=True,timeout=10)
        self.assertEqual((r.returncode,r.stdout.strip()),(0,b'OK'),r.stderr[:1024])
    def install(self):self.mutate('import',self.package('1.0.0'));self.enable()
    def pin(self,mode='check'):
        return self.gate(lambda g:[OPTIONS.worker,str(self.root/'settings'),str(self.root),str(g),mode,'pin-fixture'])
    def snapshot(self,path):
        held=self.lib.axyndra_registry_snapshot_open(os.fsencode(path));self.assertGreater(held,0)
        self.assertEqual(self.lib.axyndra_registry_snapshot_freeze(held),0);return held
    def test_shared_reader_in_another_process_blocks_writer_until_kernel_releases(self):
        directory=self.root/'state'
        child=subprocess.Popen([sys.executable,__file__,'--hold',OPTIONS.library,str(directory)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.children.append(child);self.assertTrue(select.select([child.stdout],[],[],5)[0]);self.assertEqual(child.stdout.readline().strip(),b'HELD')
        second=self.lib.axyndra_registry_reader_acquire(os.fsencode(directory));self.assertGreater(second,0)
        try:self.assertEqual(self.lib.axyndra_registry_writer_acquire(os.fsencode(directory)),-errno.EAGAIN)
        finally:self.lib.axyndra_registry_writer_release(second)
        child.send_signal(signal.SIGKILL);child.wait(timeout=5)
        writer=self.lib.axyndra_registry_writer_acquire(os.fsencode(directory));self.assertGreater(writer,0);self.lib.axyndra_registry_writer_release(writer)
    def test_retained_fd_rejects_exact_byte_path_aba(self):
        p=self.root/'metadata';p.write_bytes(b'original');held=self.snapshot(p)
        try:
            p.rename(self.root/'old');p.write_bytes(b'original')
            self.assertEqual(self.lib.axyndra_registry_snapshot_validate(held),-errno.ESTALE)
        finally:self.lib.axyndra_registry_snapshot_close(held)
    def test_no_follow_fifo_hardlink_and_inplace_change_are_not_current(self):
        outside=self.root/'outside';outside.write_bytes(b'original')
        for kind in ['link','fifo','hardlink']:
            p=self.root/kind
            if kind=='link':p.symlink_to(outside)
            elif kind=='fifo':os.mkfifo(p)
            else:os.link(outside,p)
            self.assertLess(self.lib.axyndra_registry_snapshot_open(os.fsencode(p)),0)
        p=self.root/'regular';p.write_bytes(b'original');held=self.snapshot(p)
        try:p.write_bytes(b'changed!');self.assertLess(self.lib.axyndra_registry_snapshot_validate(held),0)
        finally:self.lib.axyndra_registry_snapshot_close(held)
        self.assertEqual(outside.read_bytes(),b'original')
    def test_actual_old_cangjie_pin_rejects_other_process_disable(self):
        self.install();pin=self.pin();self.mutate('disable')
        self.assertEqual(self.finish(pin,2),'plugin.registry_execution_stale')
    def test_actual_disable_enable_does_not_recreate_old_pin(self):
        self.install();pin=self.pin();self.mutate('disable');self.enable()
        self.assertEqual(self.finish(pin,2),'plugin.registry_execution_stale')
        self.assertEqual(self.finish(self.pin()),'OK')
    def test_actual_short_cangjie_fence_blocks_publication_and_then_releases(self):
        self.install();pin=self.pin('hold')
        self.assertEqual(self.mutate('disable',expected=2),'plugin.registry_busy')
        self.assertEqual(self.finish(pin),'OK');self.mutate('disable')
    def test_uncertain_workspace_publication_stops_existing_pin_without_rewriting(self):
        self.install();pin=self.pin();directory=self.root/'.axyndra/plugins'
        held=self.lib.axyndra_registry_writer_acquire(os.fsencode(directory));self.assertGreater(held,0)
        try:self.assertEqual(self.lib.axyndra_registry_writer_publication(held,True),0)
        finally:self.lib.axyndra_registry_writer_release(held)
        marker=directory/'.registry-publication.pending';before=marker.read_bytes()
        self.assertEqual(self.finish(pin,2),'plugin.registry_recovery_required');self.assertEqual(marker.read_bytes(),before)
    def test_stale_record_cannot_capture_an_updated_generation(self):
        self.install();pin=self.pin('capture');self.mutate('update',self.package('2.0.0'))
        self.assertEqual(self.finish(pin,2),'plugin.registry_execution_stale')

if __name__=='__main__':
    if len(sys.argv)==4 and sys.argv[1]=='--hold':hold(*sys.argv[2:]);sys.exit(0)
    parser=argparse.ArgumentParser();parser.add_argument('--library',required=True);parser.add_argument('--worker',required=True);parser.add_argument('--writer',required=True)
    OPTIONS=parser.parse_args()
    if platform.system()!='Linux' or platform.machine() not in {'x86_64','AMD64'}:parser.error('requires actual supported Linux x86_64, no skip')
    for name in ['library','worker','writer']:setattr(OPTIONS,name,str(Path(getattr(OPTIONS,name)).resolve(strict=True)))
    unittest.main(argv=[sys.argv[0]],verbosity=2)
