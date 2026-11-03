"""Negative controls for exact qualified-case results from the real SDK format."""
import unittest
from rpc_unit_isolation import qualified_filtered_result

OBSERVED = '''--------------------------------------------------------------------------------------------------
TP: agent_host_runtime, time elapsed: 1063571027 ns, RESULT:
    TCS: PluginLivePolicyChildEntryTests, time elapsed: 1056420430 ns, RESULT:
    [ PASSED ] CASE: UserRejectsUntouchedChildWithActualReservedReceiptAndSameFence (1055285462 ns)
Summary: TOTAL: 223
    PASSED: 1, SKIPPED: 222, ERROR: 0
    FAILED: 0
--------------------------------------------------------------------------------------------------
Project tests finished, time elapsed: 1064550959 ns, RESULT:
TP: agent_host_runtime.*, time elapsed: 1064385930 ns, RESULT:
    PASSED:
    TP: agent_host_runtime, time elapsed: 1063571027 ns
Summary: TOTAL: 223
    PASSED: 1, SKIPPED: 222, ERROR: 0
    FAILED: 0
--------------------------------------------------------------------------------------------------
cjpm test success
'''
CASE = 'PluginLivePolicyChildEntryTests.UserRejectsUntouchedChildWithActualReservedReceiptAndSameFence'
INVENTORY = [CASE] + ['Unselected.case' + str(n) for n in range(222)]


class QualifiedRpcResultTests(unittest.TestCase):
    def parse(self, text=OBSERVED, case=CASE, inventory=INVENTORY):
        return qualified_filtered_result(text, 'agent_host_runtime', case, inventory)

    def test_observed_sdk_output_counts_only_the_one_executed_case(self):
        actual = self.parse()
        self.assertEqual(actual['actually_executed_cases'], 1)
        self.assertEqual(actual['filter_excluded_inventory_cases'], 222)
        self.assertEqual(actual['whole_module_credit'], 0)
        self.assertEqual(actual['results'], [dict(case=CASE, status='PASSED')])

    def test_summary_pass_cannot_substitute_another_qualified_case(self):
        with self.assertRaises(AssertionError):
            self.parse(OBSERVED.replace('TCS: PluginLivePolicyChildEntryTests', 'TCS: OtherSuite'))

    def test_two_executed_cases_cannot_hide_behind_one_pass_summary(self):
        extra = '    [ PASSED ] CASE: hidden (1055285462 ns)\n'
        with self.assertRaises(AssertionError):
            self.parse(OBSERVED.replace('Summary: TOTAL:', extra + 'Summary: TOTAL:', 1))

    def test_package_and_project_totals_must_both_match(self):
        with self.assertRaises(AssertionError):
            self.parse(OBSERVED.replace('TOTAL: 223', 'TOTAL: 224', 1))

    def test_forged_inventory_or_missing_completion_is_rejected(self):
        for text, inventory in [(OBSERVED, INVENTORY[:-1]),
                                (OBSERVED.replace('Project tests finished', 'Project tests interrupted'), INVENTORY),
                                (OBSERVED.replace('cjpm test success', 'cjpm test failed'), INVENTORY)]:
            with self.subTest(text=text[-40:], inventory=len(inventory)):
                with self.assertRaises(AssertionError):
                    self.parse(text, inventory=inventory)

    def test_real_failed_result_is_preserved_and_grants_no_pass(self):
        failed = OBSERVED.replace('[ PASSED ] CASE:', '[ FAILED ] CASE:')
        failed = failed.replace('PASSED: 1', 'PASSED: 0').replace('FAILED: 0', 'FAILED: 1')
        failed = failed.replace('cjpm test success', 'cjpm test failed')
        actual = self.parse(failed)
        self.assertEqual(actual['summary']['passed'], 0)
        self.assertEqual(actual['summary']['failed'], 1)
        self.assertEqual(actual['whole_module_credit'], 0)


import sys
import tempfile
import time
from pathlib import Path
from rpc_case_process_watch import run_case


@unittest.skipUnless(sys.platform == 'linux', 'Linux /proc identity and subreaper controls')
class RpcPhysicalProcessTests(unittest.TestCase):
    def test_actual_returning_child_has_no_survivor(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            actual = run_case([sys.executable, '-c', 'print(41)'], root / 'raw.log', 2, cwd=root)
            self.assertEqual(actual['exit_code'], 0)
            self.assertTrue(actual['physical_leader_returned'])
            self.assertFalse(actual['surviving_owned_processes'])
            self.assertFalse(actual['remaining_after_cleanup'])

    def test_actual_setsid_child_cannot_escape_returned_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); marker = root / 'survived'
            child = 'import os,time;from pathlib import Path;os.setsid();time.sleep(.5);Path(' + repr(str(marker)) + ').touch();time.sleep(30)'
            parent = 'import subprocess,sys;subprocess.Popen([sys.executable,"-c",' + repr(child) + '])'
            actual = run_case([sys.executable, '-c', parent], root / 'raw.log', 2, cwd=root)
            self.assertNotEqual(actual['exit_code'], 0)
            self.assertTrue(actual['physical_leader_returned'])
            self.assertTrue(actual['surviving_owned_processes'])
            self.assertFalse(actual['remaining_after_cleanup'])
            time.sleep(.6)
            self.assertFalse(marker.exists())

    def test_actual_timeout_returns_leader_and_detached_child(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            child = 'import os,time;os.setsid();time.sleep(30)'
            parent = 'import subprocess,sys,time;subprocess.Popen([sys.executable,"-c",' + repr(child) + ']);time.sleep(30)'
            actual = run_case([sys.executable, '-c', parent], root / 'raw.log', .2, cwd=root)
            self.assertEqual(actual['exit_code'], 124)
            self.assertTrue(actual['timed_out'])
            self.assertTrue(actual['physical_leader_returned'])
            self.assertFalse(actual['remaining_after_cleanup'])


from rpc_unit_isolation import _rpc_source_inputs, _rpc_compiled_inputs, _rpc_inputs_unchanged


class RpcNativeAndLauncherInputTests(unittest.TestCase):
    def make_inputs(self, root):
        # These are actual launcher dependencies; arbitrary extra files below
        # test additions are deliberate drift attempts, not compiler output.
        names = ['scripts/pinned_cangjie', 'scripts/check_sdk.sh', 'scripts/sdk_paths.sh',
                 'scripts/check_native_compiler.sh', 'scripts/prepare_native_deps.sh',
                 'scripts/product_unit_gate.py', 'scripts/product_unit_inventory.json',
                 'scripts/rpc_unit_isolation.py', 'scripts/rpc_case_process_watch.py',
                 'libs/process4cj/native/process4cj_native.c',
                 'libs/process4cj/native/sandbox_net_bridge.c']
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'original actual input')
        for name in ['target/rpc-tests', 'libs/process4cj/native/libprocess4cj_native.so',
                     'libs/process4cj/native/sandbox-net-bridge']:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes.fromhex('7f454c46') + b'original binary')
        (root / 'libs/process4cj/native/libprocess4cj_native.so.compiler-id').write_bytes(b'compiler A')
        return _rpc_source_inputs(root), _rpc_compiled_inputs(root)

    def test_launcher_native_source_and_real_library_drift_are_all_rejected(self):
        paths = ['scripts/check_sdk.sh', 'scripts/sdk_paths.sh',
                 'scripts/check_native_compiler.sh', 'scripts/prepare_native_deps.sh',
                 'libs/process4cj/native/process4cj_native.c',
                 'libs/process4cj/native/sandbox_net_bridge.c',
                 'libs/process4cj/native/libprocess4cj_native.so',
                 'libs/process4cj/native/sandbox-net-bridge',
                 'libs/process4cj/native/libprocess4cj_native.so.compiler-id']
        for name in paths:
            with self.subTest(path=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, compiled = self.make_inputs(root)
                self.assertTrue(_rpc_inputs_unchanged(root, source, compiled))
                with (root / name).open('ab') as stream:
                    stream.write(b'drift')
                self.assertFalse(_rpc_inputs_unchanged(root, source, compiled))

    def test_added_native_binary_and_launcher_are_not_hidden_by_old_subset(self):
        for name, data in [('libs/process4cj/native/new.so', bytes.fromhex('7f454c46')),
                           ('scripts/new_launcher', b'exec something else')]:
            with self.subTest(path=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source, compiled = self.make_inputs(root)
                (root / name).write_bytes(data)
                self.assertFalse(_rpc_inputs_unchanged(root, source, compiled))

    def test_missing_native_library_or_only_native_no_test_elf_cannot_pass(self):
        for name in ['libs/process4cj/native/libprocess4cj_native.so', 'target/rpc-tests']:
            with self.subTest(path=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.make_inputs(root)
                (root / name).unlink()
                with self.assertRaises(ValueError):
                    _rpc_compiled_inputs(root)

    @unittest.skipUnless(sys.platform == 'linux', 'POSIX symbolic link control')
    def test_native_binary_alias_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_inputs(root)
            path = root / 'libs/process4cj/native/libprocess4cj_native.so'
            path.unlink()
            path.symlink_to(root / 'target/rpc-tests')
            with self.assertRaises(ValueError):
                _rpc_compiled_inputs(root)


import errno
from unittest.mock import patch
import rpc_case_process_watch as process_watch


class RpcUnobservableProcessTests(unittest.TestCase):
    class Entry:
        name = '20'
        def __init__(self, value):
            self.value = value
        def __truediv__(self, _):
            return self
        def read_text(self):
            if isinstance(self.value, BaseException):
                raise self.value
            return self.value

    class Proc:
        def __init__(self, entry):
            self.entry = entry
        def iterdir(self):
            return [self.entry]

    def test_known_owned_unreadable_or_malformed_identity_remains_unknown(self):
        for value in [PermissionError(errno.EACCES, 'unreadable owned child'), 'malformed stat']:
            with self.subTest(value=type(value).__name__):
                owned = {20: dict(state='S', parent=1, group=20, session=20, start='123')}
                with patch.object(process_watch, 'Path', return_value=self.Proc(self.Entry(value))):
                    actual = process_watch.discover(owned)
                self.assertTrue(actual['unknown'])
                self.assertEqual(actual['unknown'][0]['pid'], 20)
                self.assertIn(20, owned)

    def test_real_missing_identity_is_distinct_from_an_unreadable_one(self):
        owned = {20: dict(state='S', parent=1, group=20, session=20, start='123')}
        with patch.object(process_watch, 'Path', return_value=self.Proc(
                self.Entry(FileNotFoundError(errno.ENOENT, 'real absent child')))):
            actual = process_watch.discover(owned)
        self.assertFalse(actual['unknown'])
        self.assertFalse(actual['live'])

    def test_reused_watcher_pid_cannot_admit_an_unrelated_tree(self):
        current = {20: dict(state='S', parent=1, group=20, session=20, start='replacement'),
                   30: dict(state='S', parent=20, group=20, session=20, start='unrelated')}
        owned = {}
        with patch.object(process_watch, 'processes', return_value=(current, [])):
            actual = process_watch.discover(owned, root_pid=20, root_start='original')
        self.assertFalse(actual['live'])
        self.assertEqual(owned, {})



class RpcParentCleanupWitnessTests(unittest.TestCase):
    def clean(self):
        return dict(cleanup_exact_pids=[],reaped_adopted_pids=[],remaining_after_cleanup=[],
                    unreaped_owned_processes=[],unknown=[])

    def worker(self):
        return dict(exit_code=0,timed_out=False,watcher_timed_out=False,physical_watcher_returned=True,
            watcher_exit_code=0,watcher_starttime='100',physical_leader_returned=True,
            subreaper_restored=True,dedicated_watcher=True,subreaper=True,case_process_seconds=2,
            execution_deadline_monotonic=100.0,effective_execution_deadline_monotonic=100.0,
            watcher_fault=None,surviving_owned_processes=[],remaining_after_cleanup=[],
            unreaped_owned_processes=[],unknown_process_observations=[],parent_cleanup=self.clean())

    @unittest.skipUnless(sys.platform == 'linux', 'actual dedicated Linux process owner')
    def test_real_parent_and_worker_cleanup_are_both_retained(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            actual=run_case([sys.executable,'-c','pass'],root/'actual.log',2,cwd=root)
            self.assertEqual(actual['exit_code'],0)
            self.assertTrue(actual['physical_leader_returned'])
            self.assertTrue(actual['physical_watcher_returned'])
            self.assertTrue(process_watch.parent_cleanup_closed(actual.get('parent_cleanup')))
            self.assertFalse(actual['parent_cleanup']['remaining_after_cleanup'])
            self.assertFalse(actual['parent_cleanup']['unreaped_owned_processes'])

    def test_clean_worker_cannot_hide_retained_parent_process(self):
        value=self.worker()
        self.assertTrue(process_watch._actual_clean_worker_receipt(value,100.0,2))
        value['parent_cleanup']['remaining_after_cleanup']=[dict(pid=20,start='original')]
        self.assertFalse(process_watch._actual_clean_worker_receipt(value,100.0,2))
        self.assertEqual(value['remaining_after_cleanup'],[])
        self.assertEqual(value['parent_cleanup']['remaining_after_cleanup'][0]['pid'],20)

    def test_clean_worker_cannot_hide_unreaped_parent_process(self):
        value=self.worker()
        value['parent_cleanup']['unreaped_owned_processes']=[dict(pid=21,start='original')]
        self.assertFalse(process_watch._actual_clean_worker_receipt(value,100.0,2))
        self.assertEqual(value['unreaped_owned_processes'],[])
        self.assertEqual(value['parent_cleanup']['unreaped_owned_processes'][0]['pid'],21)

    def test_parent_unknown_is_retained_and_never_acknowledged(self):
        value=self.worker()
        value['parent_cleanup']['unknown']=[dict(pid=22,reason='unobservable_actual_parent_child')]
        self.assertFalse(process_watch._actual_clean_worker_receipt(value,100.0,2))
        self.assertEqual(value['unknown_process_observations'],[])
        self.assertEqual(value['parent_cleanup']['unknown'][0]['pid'],22)

    def test_absent_or_incomplete_parent_witness_is_never_empty_return(self):
        for key in self.clean():
            value=self.worker();del value['parent_cleanup'][key]
            self.assertFalse(process_watch._actual_clean_worker_receipt(value,100.0,2))
        for invalid in (None,[],{},False,dict(remaining_after_cleanup=[])):
            value=self.worker();value['parent_cleanup']=invalid
            self.assertFalse(process_watch._actual_clean_worker_receipt(value,100.0,2))



import copy
import rpc_unit_isolation as isolation_driver


class RpcDriverCustodyRecordingTests(unittest.TestCase):
    def run_driver(self, process, fault):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);output=root/'output';output.mkdir()
            dry=output/'agent_rpc.dry-run.log'
            dry.write_text('Summary: TOTAL: 1, SKIPPED: 0\n')
            compilation={**self.process(), 'exit_code':0, 'timed_out':False}
            (output/compilation['watcher_receipt']).write_bytes(b'complete compile worker receipt')
            (output/compilation['watcher_log']).write_bytes(b'complete compile watcher log')
            def execute(command, log, owned_root, seconds):
                if fault in ('call_value_error','call_runtime_error'):
                    error=ValueError if fault=='call_value_error' else RuntimeError
                    raise error('actual watcher call did not return a witness')
                log.write_bytes(b'complete case stream')
                if fault!='missing_receipt':
                    (log.parent/process['watcher_receipt']).write_bytes(b'complete raw worker receipt')
                if fault!='missing_watcher_log':
                    (log.parent/process['watcher_log']).write_bytes(b'complete raw watcher stream')
                return copy.deepcopy(process)
            def digest(path):
                if fault=='case_log_hash' and path.parent.name=='agent_rpc-cases':
                    raise OSError('actual returned case stream could not be read')
                return '0'*64
            with patch.dict(isolation_driver.os.environ,{
                    'AXYNDRA_CANONICAL_TARGET_ROOT':'','AXYNDRA_NATIVE_OUTPUT':'','AXYNDRA_NETWORK_BRIDGE_OUTPUT':''}), \
                patch.object(isolation_driver,'run_logged',return_value=0), \
                patch.object(isolation_driver,'run_compilation',return_value=compilation), \
                patch.object(isolation_driver,'dry_run_cases',return_value=['One.case']), \
                patch.object(isolation_driver,'_rpc_source_inputs',return_value={'source':'fixed'}), \
                patch.object(isolation_driver,'_rpc_compiled_inputs',return_value={'compiled':'fixed'}), \
                patch.object(isolation_driver,'_rpc_inputs_unchanged',return_value=True), \
                patch.object(isolation_driver,'_run_rpc_case',side_effect=execute), \
                patch.object(isolation_driver,'_sha',side_effect=digest):
                return isolation_driver.run_isolated_agent_rpc(root,output,output/'all.log')

    def process(self):
        return dict(watcher_receipt='worker.json',watcher_log='watcher.log',
            physical_leader_returned=True,physical_watcher_returned=True,subreaper_restored=True,
            remaining_after_cleanup=[],unreaped_owned_processes=[],unknown_process_observations=[],
            surviving_owned_processes=[],watcher_timed_out=False,
            parent_cleanup=dict(cleanup_exact_pids=[],reaped_adopted_pids=[],
                remaining_after_cleanup=[],unreaped_owned_processes=[],unknown=[]))

    def assert_failed_returned_witness(self, actual, original):
        self.assertEqual(actual['status'],'FAIL')
        self.assertEqual(actual['exit_code'],1)
        self.assertEqual(actual['passed'],0)
        self.assertEqual(len(actual['case_logs']),1)
        observed=actual['case_logs'][0]
        self.assertTrue(observed['watcher_call_started'])
        self.assertTrue(observed['watcher_call_returned'])
        self.assertEqual(observed['process'],original)

    def test_actual_driver_keeps_parent_remaining_before_log_hash_failure(self):
        original=self.process()
        original['parent_cleanup']['remaining_after_cleanup']=[dict(pid=41,start='original')]
        actual=self.run_driver(original,'case_log_hash')
        self.assert_failed_returned_witness(actual,original)
        self.assertFalse(process_watch.parent_cleanup_closed(actual['case_logs'][0]['process']['parent_cleanup']))

    def test_actual_driver_keeps_parent_unreaped_before_missing_receipt(self):
        original=self.process()
        original['parent_cleanup']['unreaped_owned_processes']=[dict(pid=42,start='original')]
        actual=self.run_driver(original,'missing_receipt')
        self.assert_failed_returned_witness(actual,original)
        self.assertFalse(process_watch.parent_cleanup_closed(actual['case_logs'][0]['process']['parent_cleanup']))

    def test_actual_driver_keeps_parent_unknown_before_missing_watcher_log(self):
        original=self.process()
        original['parent_cleanup']['unknown']=[dict(pid=43,reason='unobservable')]
        actual=self.run_driver(original,'missing_watcher_log')
        self.assert_failed_returned_witness(actual,original)
        self.assertFalse(process_watch.parent_cleanup_closed(actual['case_logs'][0]['process']['parent_cleanup']))

    def test_actual_driver_keeps_unreturned_call_before_value_error(self):
        actual=self.run_driver(self.process(),'call_value_error')
        self.assertEqual(actual['status'],'FAIL')
        self.assertEqual(actual['passed'],0)
        observed=actual['case_logs'][0]
        self.assertTrue(observed['watcher_call_started'])
        self.assertFalse(observed['watcher_call_returned'])
        self.assertEqual(observed['process'],{})
        self.assertFalse(process_watch.parent_cleanup_closed(observed['process'].get('parent_cleanup')))

    def test_actual_driver_keeps_unreturned_call_before_unexpected_error(self):
        actual=self.run_driver(self.process(),'call_runtime_error')
        self.assertEqual(actual['status'],'FAIL')
        self.assertEqual(actual['passed'],0)
        self.assertFalse(actual['case_logs'][0]['watcher_call_returned'])
        self.assertEqual(actual['case_logs'][0]['process'],{})

    def test_actual_driver_keeps_closed_case_even_when_log_read_fails(self):
        original=self.process();actual=self.run_driver(original,'case_log_hash')
        self.assert_failed_returned_witness(actual,original)
        self.assertTrue(process_watch.parent_cleanup_closed(actual['case_logs'][0]['process']['parent_cleanup']))



class RpcCompilationCustodyTests(unittest.TestCase):
    def process(self):
        return {**RpcDriverCustodyRecordingTests().process(), 'exit_code':0, 'timed_out':False}

    def execute(self, process, fault):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);out=root/'output';out.mkdir()
            def compilation(command, log, seconds, cwd=None):
                self.assertEqual(seconds,900)
                self.assertIn('--dry-run',command)
                self.assertIn('--timeout-each=60s',command)
                if fault in ('value_error','unexpected_error'):
                    error=ValueError if fault=='value_error' else RuntimeError
                    raise error('actual compilation call did not return')
                log.write_text('Summary: TOTAL: 1, SKIPPED: 0\n')
                if fault!='missing_receipt':
                    (out/process['watcher_receipt']).write_bytes(b'complete worker receipt')
                (out/process['watcher_log']).write_bytes(b'complete watcher log')
                return copy.deepcopy(process)
            def digest(path):
                if fault=='log_hash':raise OSError('compiler forensic input unavailable')
                return '0'*64
            with patch.dict(isolation_driver.os.environ,{
                    'AXYNDRA_CANONICAL_TARGET_ROOT':'','AXYNDRA_NATIVE_OUTPUT':'','AXYNDRA_NETWORK_BRIDGE_OUTPUT':''}), \
                patch.object(isolation_driver,'run_compilation',side_effect=compilation), \
                patch.object(isolation_driver,'_sha',side_effect=digest), \
                patch.object(isolation_driver,'_run_rpc_case',side_effect=AssertionError('no runtime case may start')):
                return isolation_driver.run_isolated_agent_rpc(root,out,out/'all.log')

    @unittest.skipUnless(sys.platform == 'linux','actual Linux compilation owner')
    def test_real_compilation_owner_returns_with_complete_parent_and_worker(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            actual=process_watch.run_compilation([sys.executable,'-c','pass'],root/'compile.log',2,cwd=root)
            self.assertEqual(actual['exit_code'],0)
            self.assertEqual(actual['custody_role'],'compilation')
            self.assertTrue(process_watch.process_custody_closed(actual))

    def test_original_case_cap_and_compiler_cap_remain_separate(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            with self.assertRaises(ValueError):process_watch.run_case(['unused'],root/'case.log',61)
            with self.assertRaises(ValueError):process_watch.run_compilation(['unused'],root/'compile.log',901)
            self.assertFalse(any(root.iterdir()))

    def test_compile_pending_call_is_retained_on_value_error(self):
        actual=self.execute(self.process(),'value_error')
        self.assertEqual(actual['status'],'FAIL');self.assertEqual(actual['case_logs'],[])
        self.assertTrue(actual['compilation']['watcher_call_started'])
        self.assertFalse(actual['compilation']['watcher_call_returned'])
        self.assertFalse(process_watch.process_custody_closed(actual['compilation']['process']))

    def test_compile_pending_call_is_retained_on_unexpected_error(self):
        actual=self.execute(self.process(),'unexpected_error')
        self.assertEqual(actual['status'],'FAIL');self.assertEqual(actual['case_logs'],[])
        self.assertFalse(actual['compilation']['watcher_call_returned'])
        self.assertEqual(actual['compilation']['process'],{})

    def test_compile_retained_parent_survives_missing_raw_receipt(self):
        process=self.process();process['parent_cleanup']['remaining_after_cleanup']=[dict(pid=51,start='original')]
        actual=self.execute(process,'missing_receipt')
        self.assertEqual(actual['status'],'FAIL');self.assertEqual(actual['case_logs'],[])
        self.assertEqual(actual['compilation']['process'],process)
        self.assertTrue(actual['compilation']['watcher_call_returned'])
        self.assertFalse(process_watch.process_custody_closed(actual['compilation']['process']))

    def test_compile_parent_unknown_prevents_any_runtime_case(self):
        process=self.process();process['parent_cleanup']['unknown']=[dict(pid=52,reason='unobservable')]
        actual=self.execute(process,'unknown')
        self.assertEqual(actual['status'],'FAIL');self.assertEqual(actual['case_logs'],[])
        self.assertEqual(actual['compilation']['process'],process)
        self.assertIn('custody did not close',actual['error'])

    def test_compile_returned_witness_is_saved_before_raw_log_hash(self):
        process=self.process();actual=self.execute(process,'log_hash')
        self.assertEqual(actual['status'],'FAIL');self.assertEqual(actual['case_logs'],[])
        self.assertEqual(actual['compilation']['process'],process)
        self.assertTrue(process_watch.process_custody_closed(actual['compilation']['process']))

    def test_pending_or_wrong_type_fields_never_prove_actual_return(self):
        clean=self.process();self.assertTrue(process_watch.process_custody_closed(clean))
        for key in ('physical_leader_returned','physical_watcher_returned','subreaper_restored'):
            invalid=copy.deepcopy(clean);invalid[key]=1
            self.assertFalse(process_watch.process_custody_closed(invalid))
        for key in ('remaining_after_cleanup','unreaped_owned_processes','unknown_process_observations','surviving_owned_processes'):
            invalid=copy.deepcopy(clean);invalid[key]=None
            self.assertFalse(process_watch.process_custody_closed(invalid))
        self.assertFalse(process_watch.process_custody_closed({}))


class RpcDeadIdentity208Tests(unittest.TestCase):
    # Actual diagnostic3 /proc/22714/stat, captured while compiling Source135.
    # Preserve all bytes, including X, parent 0, pgrp -1 and session -1.
    observed_hex = "323237313420286f70742920582030202d31202d312030202d312034323237303834203134393920302036353420302030203520302030203230203020302030203238373439203020302030203020302030203020302030203020302030203120302030203137203820302030203020302030203020302030203020302030203020300a"

    def identity(self, state='X', parent='0', group='-1', session='-1', start='28749'):
        raw = bytes.fromhex(self.observed_hex).decode('ascii')
        split = raw.rindex(')') + 2
        tail = raw[split:].split()
        tail[0:4] = [state, parent, group, session]
        tail[19] = start
        return raw[:split] + ' '.join(tail) + '\n'

    def test_observed_dead_identity_keeps_original_signed_fields(self):
        import hashlib
        raw = bytes.fromhex(self.observed_hex)
        self.assertEqual(len(raw), 132)
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
            '966a47919e9fd8fd4d036119f06c2cb082f3b8bb332b38b760c73a92ebf8d6bb')
        self.assertEqual(process_watch._cell(raw.decode('ascii')),
            dict(state='X', parent=0, group=-1, session=-1, start='28749'))

    def test_both_preexisting_dead_state_spellings_keep_the_identity(self):
        for state in ('X', 'x'):
            with self.subTest(state=state):
                self.assertEqual(process_watch._cell(self.identity(state)),
                    dict(state=state, parent=0, group=-1, session=-1, start='28749'))

    def test_live_and_zombie_negative_identity_stays_unknown(self):
        for state in ('R', 'S', 'D', 'T', 't', 'W', 'I', 'Z'):
            with self.subTest(state=state):
                with self.assertRaises(ValueError):
                    process_watch._cell(self.identity(state))

    def test_dead_partial_negative_parent_and_other_negative_values_rejected(self):
        for state in ('X', 'x'):
            for parent, group, session in (('-1', '-1', '-1'), ('0', '-1', '0'),
                    ('0', '0', '-1'), ('0', '-2', '-1'), ('0', '-1', '-2')):
                with self.subTest(state=state, identity=(parent, group, session)):
                    with self.assertRaises(ValueError):
                        process_watch._cell(self.identity(state, parent, group, session))

    def test_original_positive_identity_and_invalid_start_rules_stay_exact(self):
        for state in ('R', 'S', 'Z', 'X', 'x'):
            self.assertEqual(process_watch._cell(self.identity(state, '0', '2', '3')),
                dict(state=state, parent=0, group=2, session=3, start='28749'))
            for start in ('-1', 'bad', '1.5'):
                with self.subTest(state=state, start=start):
                    with self.assertRaises(ValueError):
                        process_watch._cell(self.identity(state, start=start))

    def test_dead_observation_is_not_custody_return_or_reap(self):
        actual = RpcCompilationCustodyTests().process()
        self.assertTrue(process_watch.process_custody_closed(actual))
        dead = dict(pid=22714, **process_watch._cell(self.identity()))
        actual['unreaped_owned_processes'] = [dead]
        self.assertFalse(process_watch.process_custody_closed(actual))
        actual['unreaped_owned_processes'] = []
        actual['parent_cleanup']['unreaped_owned_processes'] = [dead]
        self.assertFalse(process_watch.process_custody_closed(actual))


if __name__ == '__main__':
    unittest.main()
