#!/usr/bin/env python3
"""Real interpreter behavior; native/Product authorization is checked separately."""
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
PROFILES = {
    'py': ('python3', ['-u'], 'python.py'),
    'js': ('bun', [], 'javascript.mjs'),
    'rb': ('ruby', [], 'ruby.rb'),
    'jl': ('julia', ['--startup-file=no', '--history-file=no'], 'julia.jl'),
}


class Runner:
    def __init__(self, language, *, environment=None):
        executable, args, source = PROFILES[language]
        self.process = subprocess.Popen([shutil.which(executable), *args, str(ROOT / 'runners' / source)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        bufsize=0, start_new_session=True, env=environment)
        self.buffer = bytearray()
        try:
            assert self.line(15) == f'READY|{language}|1', 'runtime did not emit its exact readiness identity'
        except BaseException:
            self.close()
            raise

    def line(self, seconds):
        deadline = time.monotonic() + seconds
        while b'\n' not in self.buffer:
            ready, _, _ = select.select([self.process.stdout, self.process.stderr], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise TimeoutError('runtime response deadline')
            for stream in ready:
                data = os.read(stream.fileno(), 8192)
                if stream == self.process.stderr:
                    if data:
                        raise AssertionError('unexpected raw runtime stderr: ' + data.decode(errors='replace'))
                elif not data:
                    raise EOFError('runtime exited without its complete response')
                else:
                    self.buffer.extend(data)
                    if len(self.buffer) > 131072:
                        raise ValueError('runtime response exceeds protocol bound')
        line, _, self.buffer = self.buffer.partition(b'\n')
        return line.decode()

    def cell(self, code, *, reset=False, timeout_ms=2000):
        payload = f'{timeout_ms}|{int(reset)}|{code.encode().hex()}\n'.encode()
        self.process.stdin.write(payload)
        self.process.stdin.flush()
        parts = self.line(timeout_ms / 1000 + 3).split('|')
        assert len(parts) == 6 and parts[0] == 'OK' and parts[2] in ('0', '1'), parts
        return {'exit_code': int(parts[1]), 'timed_out': parts[2] == '1', 'duration_ms': int(parts[3]),
                'stdout': bytes.fromhex(parts[4]).decode(), 'stderr': bytes.fromhex(parts[5]).decode()}

    def close(self):
        # A previous test cell can have spawned a descendant. Kill the exact
        # new group owned by this runner, even if its interpreter already exited.
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class PythonRunnerTests(unittest.TestCase):
    def setUp(self):
        self.runner = Runner('py')
        self.addCleanup(self.runner.close)

    def test_persistent_variables(self):
        self.assertEqual(self.runner.cell('counter = 40')['stdout'], '')
        self.assertEqual(self.runner.cell('counter += 2\ncounter')['stdout'], '42\n')

    def test_reset_drops_state(self):
        self.runner.cell('secret = 9')
        result = self.runner.cell("'secret' in globals()", reset=True)
        self.assertEqual(result['stdout'], 'false\n')

    def test_unicode_and_display(self):
        self.assertEqual(self.runner.cell("{'文字': '中文🧪'}")['stdout'], '{"文字": "中文🧪"}\n')

    def test_top_level_await(self):
        self.assertEqual(self.runner.cell('import asyncio\nawait asyncio.sleep(0)\n21 * 2')['stdout'], '42\n')

    def test_stdout_stderr_are_separate(self):
        result = self.runner.cell("import sys\nprint('out')\nprint('err', file=sys.stderr)")
        self.assertEqual((result['stdout'], result['stderr']), ('out\n', 'err\n'))

    def test_syntax_error_and_next_cell(self):
        self.assertEqual(self.runner.cell('if ???')['exit_code'], 1)
        self.assertEqual(self.runner.cell('3 * 7')['stdout'], '21\n')

    def test_exception_keeps_observed_partial_output(self):
        result = self.runner.cell("print('started')\nraise ValueError('cell failure')")
        self.assertEqual(result['stdout'], 'started\n')
        self.assertIn('ValueError: cell failure', result['stderr'])

    def test_system_exit_does_not_terminate_protocol(self):
        self.assertEqual(self.runner.cell('raise SystemExit(4)')['exit_code'], 1)
        self.assertEqual(self.runner.cell('6 * 7')['stdout'], '42\n')

    def test_deadline_and_reusable_python_state(self):
        self.runner.cell('before_timeout = 99')
        result = self.runner.cell('while True: pass', timeout_ms=100)
        self.assertTrue(result['timed_out'])
        self.assertEqual(result['exit_code'], 124)
        self.assertEqual(self.runner.cell('before_timeout')['stdout'], '99\n')

    def test_two_processes_do_not_share_state(self):
        self.runner.cell('private_value = 53')
        other = Runner('py')
        self.addCleanup(other.close)
        self.assertEqual(other.cell("'private_value' in globals()")['stdout'], 'false\n')

    def test_multiple_lines_and_pipe_literals(self):
        self.assertEqual(self.runner.cell("x = '|\\n'\nprint(x, end='')")['stdout'], '|\n')

    def test_empty_cell_has_empty_output(self):
        result = self.runner.cell('')
        self.assertEqual((result['exit_code'], result['stdout'], result['stderr']), (0, '', ''))


def optional_suite(language, set_code, read_code, check_missing, error_code):
    class OptionalRunnerTests(unittest.TestCase):
        def setUp(self):
            self.runner = Runner(language)
            self.addCleanup(self.runner.close)

        def test_persistent_state(self):
            self.assertEqual(self.runner.cell(set_code)['exit_code'], 0)
            self.assertIn('42', self.runner.cell(read_code)['stdout'])

        def test_reset_clears_state(self):
            self.runner.cell(set_code)
            self.assertIn('true', self.runner.cell(check_missing, reset=True)['stdout'].lower())

        def test_error_does_not_replace_next_cell(self):
            self.assertEqual(self.runner.cell(error_code)['exit_code'], 1)
            self.assertIn('42', self.runner.cell('21 * 2')['stdout'])

        def test_distinct_process_state(self):
            self.runner.cell(set_code)
            other = Runner(language)
            self.addCleanup(other.close)
            self.assertIn('true', other.cell(check_missing)['stdout'].lower())

    return unittest.skipUnless(shutil.which(PROFILES[language][0]), f'{language} interpreter unavailable')(OptionalRunnerTests)


JavaScriptRunnerTests = optional_suite('js', 'var counter = 42', 'counter', "typeof counter === 'undefined'", "throw new Error('cell failure')")
RubyRunnerTests = optional_suite('rb', 'counter = 42', 'counter', 'defined?(counter).nil?', "raise 'cell failure'")
JuliaRunnerTests = optional_suite('jl', 'counter = 42', 'counter', '!isdefined(@__MODULE__, :counter)', 'error("cell failure")')


@unittest.skipUnless(shutil.which('julia'), 'jl interpreter unavailable')
class JuliaCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='eval-julia-capture-')
        self.addCleanup(self.temporary.cleanup)
        self.runner = Runner('jl', environment=dict(os.environ, TMPDIR=self.temporary.name))
        self.addCleanup(self.runner.close)

    def test_stdout_stderr_unicode_separate(self):
        result = self.runner.cell('println("中文🧪"); println(stderr, "diagnostic"); nothing')
        self.assertEqual((result['exit_code'], result['stdout'], result['stderr']),
                         (0, '中文🧪\n', 'diagnostic\n'))

    def test_error_keeps_partial_output_and_next_cell(self):
        result = self.runner.cell('println("started"); error("cell failure")')
        self.assertEqual((result['exit_code'], result['stdout']), (1, 'started\n'))
        self.assertIn('cell failure', result['stderr'])
        self.assertEqual(self.runner.cell('21 * 2')['stdout'], '42\n')

    def test_capture_files_removed_after_success_and_error(self):
        initial = set(Path(self.temporary.name).iterdir())
        self.assertEqual(self.runner.cell('21 * 2')['exit_code'], 0)
        self.assertEqual(set(Path(self.temporary.name).iterdir()), initial)
        self.assertEqual(self.runner.cell('error("cell failure")')['exit_code'], 1)
        self.assertEqual(set(Path(self.temporary.name).iterdir()), initial)

if __name__ == '__main__':
    if os.name != 'posix':
        raise SystemExit('runner fixtures require POSIX process groups and signals')
    unittest.main(verbosity=2)
