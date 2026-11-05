"""Real-process regression tests for composed fixture deadlines and cleanup."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from fixture_budget import MEMORY_FIXTURE_SECONDS, MEMORY_STAGE_SECONDS
from rpc_case_process_watch import run_fixture, run_fixture_stage, process_custody_closed, parent_cleanup_closed


@unittest.skipUnless(sys.platform == 'linux', 'dedicated Linux process custody')
class FixtureBudgetTests(unittest.TestCase):
    def test_complete_sequence_gets_composed_not_single_stage_budget(self):
        self.assertEqual(MEMORY_STAGE_SECONDS, {'build': 900, 'unit': 900, 'protocol': 240})
        self.assertEqual(MEMORY_FIXTURE_SECONDS, 2100)
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'sequence.log'
            # Each stage fits .25s; their sequential sum exceeds .25s.
            result = run_fixture([sys.executable, '-c',
                'import time; time.sleep(.16); time.sleep(.16); print("COMPLETE")'], log, 2)
            self.assertEqual(result['exit_code'], 0, result)
            self.assertTrue(process_custody_closed(result), result)
            self.assertIn('COMPLETE', log.read_text())

    def test_stage_failure_and_environment_are_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'stage.log'
            result = run_fixture_stage([sys.executable, '-c',
                'import os,sys; print(os.environ["FIXTURE_TEST"]); sys.exit(7)'], log, 2,
                environment=dict(os.environ, FIXTURE_TEST='selected'))
            self.assertEqual(result['exit_code'], 7, result)
            self.assertIn('selected', log.read_text())
            self.assertTrue(process_custody_closed(result), result)

    def test_timeout_reaps_descendant_that_starts_a_new_session(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            child = 'import time; time.sleep(30)'
            code = ('import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c",'
                + repr(child) + '],start_new_session=True); print(p.pid,flush=True); time.sleep(30)')
            result = run_fixture([sys.executable, '-c', code], root / 'timeout.log', .4)
            self.assertEqual(result['exit_code'], 124, result)
            self.assertTrue(result['timed_out'])
            self.assertTrue(parent_cleanup_closed(result['parent_cleanup']), result)
            self.assertEqual(result['remaining_after_cleanup'], [])
            self.assertEqual(result['unreaped_owned_processes'], [])
            self.assertEqual(result['unknown_process_observations'], [])
            self.assertTrue(result['physical_leader_returned'])
            self.assertTrue(result['physical_watcher_returned'])
            self.assertTrue(result['subreaper_restored'])
            pid = int((root / 'timeout.log').read_text().strip())
            self.assertFalse(Path('/proc', str(pid)).exists())

    def test_parent_cancellation_reaps_nested_stage_watchers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            code = ('from rpc_case_process_watch import run_fixture_stage; import sys; '
                'from pathlib import Path; '
                'run_fixture_stage([sys.executable,"-c","import time; time.sleep(30)"],'
                + 'Path(' + repr(str(root / 'inner.log')) + '),30)')
            result = run_fixture([sys.executable, '-c', code], root / 'outer.log', .5, cwd=Path(__file__).parent)
            self.assertEqual(result['exit_code'], 124, result)
            self.assertTrue(parent_cleanup_closed(result['parent_cleanup']), result)
            self.assertEqual(result['remaining_after_cleanup'], [])
            self.assertEqual(result['unreaped_owned_processes'], [])
            self.assertEqual(result['unknown_process_observations'], [])
            self.assertTrue(result['physical_leader_returned'])
            self.assertTrue(result['physical_watcher_returned'])
            self.assertTrue(result['subreaper_restored'])
            self.assertGreater(result['observed_processes'], 1)


if __name__ == '__main__':
    unittest.main()
