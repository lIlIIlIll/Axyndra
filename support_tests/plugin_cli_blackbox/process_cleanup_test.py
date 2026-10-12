#!/usr/bin/env python3
"""Real process checks for the CLI gate's timeout and termination cleanup."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from owned_process import kill_owned, owned_process, stop_owned


def await_file(path, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and path.read_text():
            return path.read_text()
        time.sleep(0.01)
    raise AssertionError("child readiness missing: " + str(path))


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class OwnedProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plugin-cli-cleanup-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def child(self, body, *arguments):
        return [sys.executable, "-c", body, *map(str, arguments)]

    def test_hard_deadline_kills_and_reaps_owned_session(self):
        with owned_process(self.child("import time; time.sleep(30)")) as process:
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=0.05)
            self.assertEqual(kill_owned(process), -signal.SIGKILL)
            self.assertFalse(alive(process.pid))

    def test_term_grace_allows_owned_child_cleanup(self):
        ready, stopped = self.root / "ready", self.root / "stopped"
        program = """import signal,sys,time
from pathlib import Path
def stop(signum, frame):
    Path(sys.argv[2]).write_text('cleaned')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
Path(sys.argv[1]).write_text('ready')
time.sleep(30)
"""
        with owned_process(self.child(program, ready, stopped)) as process:
            await_file(ready)
            self.assertEqual(stop_owned(process), 0)
        self.assertEqual(stopped.read_text(), "cleaned")
        self.assertFalse(alive(process.pid))

    def test_stubborn_owned_child_gets_bounded_kill(self):
        ready = self.root / "ready"
        program = "import signal,sys,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); Path(sys.argv[1]).write_text('ready'); time.sleep(30)"
        with owned_process(self.child(program, ready)) as process:
            await_file(ready)
            started = time.monotonic()
            self.assertEqual(stop_owned(process, grace=0.1), -signal.SIGKILL)
            self.assertLess(time.monotonic() - started, 2)
            self.assertFalse(alive(process.pid))

    def test_outer_term_unwinds_inner_session_without_touching_unrelated_child(self):
        ready = self.root / "ready"
        inner = "import os,sys,time; from pathlib import Path; Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        driver = """import sys
from owned_process import owned_process, termination_signals, HarnessInterrupted
try:
    with termination_signals():
        with owned_process([sys.executable, '-c', sys.argv[1], sys.argv[2]]):
            import time
            time.sleep(30)
except HarnessInterrupted:
    raise SystemExit(23)
"""
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(Path(__file__).resolve().parent)
        with owned_process(self.child("import time; time.sleep(30)")) as unrelated:
            with owned_process(self.child(driver, inner, ready), env=environment) as outer:
                child_pid = int(await_file(ready))
                os.killpg(outer.pid, signal.SIGTERM)
                self.assertEqual(outer.wait(timeout=5), 23)
                self.assertFalse(alive(child_pid))
                self.assertIsNone(unrelated.poll())

    def test_exited_leader_cannot_leave_term_ignoring_group_descendant(self):
        ready = self.root / "ready"
        child_ready = self.root / "child-ready"
        descendant = "import os,signal,sys,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)"
        leader = """import signal,subprocess,sys,time
from pathlib import Path
subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]])
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while not Path(sys.argv[2]).exists():
    time.sleep(0.01)
Path(sys.argv[3]).write_text('ready')
time.sleep(30)
"""
        with owned_process(self.child(leader, descendant, child_ready, ready)) as process:
            await_file(ready)
            child_pid = int(await_file(child_ready))
            self.assertEqual(stop_owned(process), 0)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    state = (Path('/proc') / str(child_pid) / 'stat').read_text().split(') ', 1)[1].split()[0]
                except FileNotFoundError:
                    return
                if state == 'Z':
                    return
                time.sleep(0.01)
            self.fail('owned descendant remained running after group cleanup')


if __name__ == "__main__":
    unittest.main(verbosity=2)
