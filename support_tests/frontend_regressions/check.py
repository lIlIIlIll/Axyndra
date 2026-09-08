#!/usr/bin/env python3
"""Public CLI, PTY and JSONL cancellation regression contracts (fixture only)."""
import json
import os
import queue
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('AXYNDRA_BINARY', ROOT / 'target/release/bin/agent_app'))

class Transport:
    def __init__(self, root, mode):
        self.frames = []
        self.queue = queue.Queue()
        self.process = subprocess.Popen([str(BINARY), '--fixture', '--approval-mode', 'manual',
            '--mode', mode, '--cwd', str(root)], cwd=root, env=environment(root),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def read():
            for line in self.process.stdout:
                self.queue.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
    def send(self, *frames):
        self.process.stdin.write(''.join(json.dumps(frame) + '\n' for frame in frames))
        self.process.stdin.flush()
    def wait(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            frame = self.queue.get(timeout=max(0, deadline-time.monotonic()))
            self.frames.append(frame)
            if predicate(frame): return frame
    def close(self):
        self.process.stdin.close()
        try:
            assert self.process.wait(timeout=10) == 0, self.process.stderr.read()
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=5)
        assert not self.reader.is_alive()
        while not self.queue.empty(): self.frames.append(self.queue.get_nowait())

def environment(root):
    env = {key: value for key, value in os.environ.items() if key in
        ('PATH', 'LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CJ_SDK_LIBPATH')}
    env['AXYNDRA_HOME'] = str(root / 'settings')
    return env

def request(id, method, params):
    return dict(jsonrpc='2.0', id=id, method=method, params=params)

def acp(root):
    transport = Transport(root, 'acp')
    try:
        transport.send(request(1, 'initialize', {'protocolVersion': 1}))
        assert 'result' in transport.wait(lambda f: f.get('id') == 1)
        transport.send(request(2, 'session/new', {'cwd': str(root), 'mcpServers': []}))
        sid = transport.wait(lambda f: f.get('id') == 2)['result']['sessionId']
        def prompt(id, text):
            return request(id, 'session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': text}]})
        transport.send(prompt(3, 'fixture approval ask'))
        permission = transport.wait(lambda f: f.get('method') == 'session/request_permission')
        transport.send(request(4, 'session/cancel', {'sessionId': sid}))
        assert transport.wait(lambda f: f.get('id') == 4)['result'] == {}
        cancelled = [f for f in transport.frames if f.get('id') == 3]
        assert len(cancelled) == 1 and cancelled[0]['result']['stopReason'] == 'cancelled', cancelled
        # Old approval responses cannot approve or settle the next prompt.
        transport.send(dict(jsonrpc='2.0', id=permission['id'], result={'outcome': {
            'outcome': 'selected', 'optionId': 'allow_once'}}), prompt(5, 'hello after cancel'))
        assert transport.wait(lambda f: f.get('id') == 5)['result']['stopReason'] == 'end_turn'
        transport.send(request(6, 'session/cancel', {'sessionId': sid}))
        assert transport.wait(lambda f: f.get('id') == 6)['result'] == {}
    finally:
        transport.close()
    assert len([f for f in transport.frames if f.get('id') == 3]) == 1
    assert len([f for f in transport.frames if f.get('id') == 5]) == 1
    print('PASS I2 ACP approval cancellation, late response, next prompt, exactly once')

def rpc(root):
    transport = Transport(root, 'rpc')
    try:
        transport.wait(lambda f: f.get('type') == 'ready')
        # A filesystem handshake proves the long process started in the real transport.
        marker = root / 'started'
        transport.send(dict(id='bash', type='bash', command='printf started > started; sleep 30; printf too-late'))
        deadline = time.monotonic() + 10
        while not marker.exists():
            if time.monotonic() > deadline:
                raise AssertionError('bash did not start: ' + str(list(transport.queue.queue)))
            time.sleep(.02)
        begin = time.monotonic()
        transport.send(dict(id='state', type='get_state'), dict(id='abort', type='abort_bash'))
        abort = transport.wait(lambda f: f.get('id') == 'abort', timeout=5)
        assert abort['success'] and time.monotonic()-begin < 5, abort
        if not any(f.get('id') == 'bash' for f in transport.frames):
            transport.wait(lambda f: f.get('id') == 'bash', timeout=5)
        response = [f for f in transport.frames if f.get('id') == 'bash']
        assert len(response) == 1 and 'too-late' not in json.dumps(response), response
        assert any(f.get('id') == 'state' for f in transport.frames)
        # Both lines in one write also exercise cancellation before worker registration.
        transport.send(dict(id='early', type='bash', command='sleep 30; printf too-late'),
                       dict(id='early-abort', type='abort_bash'))
        transport.wait(lambda f: f.get('id') == 'early-abort')
        if not any(f.get('id') == 'early' for f in transport.frames):
            transport.wait(lambda f: f.get('id') == 'early', timeout=5)
        transport.send(dict(id='closing', type='bash', command='sleep 30; printf too-late'))
    finally:
        transport.close()
    for id in ('bash', 'early', 'closing'):
        frames = [f for f in transport.frames if f.get('id') == id]
        assert len(frames) == 1 and 'too-late' not in json.dumps(frames), frames
    print('PASS I5 live stdin dispatch, running/early abort, EOF join, exactly once')

def cli(root):
    for token in ('--help', '--version', '--mode=json', '--cwd=/no-such-prompt-path',
                  '--approval-mode=trusted', '--model=not-a-model'):
        result = subprocess.run([str(BINARY), '--fixture', '--print', '--', token],
            cwd=root, env=environment(root), text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and 'fixture response for ' + token in result.stdout, result
    for option, value in (('--model-attempt-recovery', 'disabled'),
                          ('--model-stream-idle-timeout-ms', '1000'),
                          ('--model-stream-fault-profile', 'incomplete-text-attempt-1-v1')):
        result = subprocess.run([str(BINARY), '--fixture', option, value, 'completions', 'bash'],
            cwd=root, env=environment(root), text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and 'fixture response for' not in result.stdout, result
    missing = subprocess.run([str(BINARY), '--fixture', '--model', '--', 'setup'],
        cwd=root, env=environment(root), input='', text=True, capture_output=True, timeout=10)
    assert missing.returncode == 2 and 'missing value' in missing.stdout.lower(), missing
    settings = root / 'settings'
    settings.mkdir(exist_ok=True)
    tail = '# preserve comment\ntheme: light\nasync:\n  enabled: false\napproval:\n  mode: never\ncompaction:\n  enabled: false\nmodel_roles:\n  approval: old/reviewer\nfuture_setting: keep-me\n'
    config = settings / 'config.yml'
    config.write_text('default_model: old/model\n' + tail)
    result = subprocess.run([str(BINARY), 'setup'], cwd=root, env=environment(root),
        input='1\n1\nregression-profile\n1\nREGRESSION_UNSET_KEY\n3\n',
        capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and tail in config.read_text(), (result, config.read_text())
    assert 'regression-profile/gpt-5' in config.read_text()
    before_failure = config.read_text()
    catalog = settings / 'models.yml'
    catalog.unlink()
    catalog.mkdir()
    failed = subprocess.run([str(BINARY), 'setup'], cwd=root, env=environment(root),
        input='1\n1\nfailed-profile\n1\nREGRESSION_UNSET_KEY\n3\n',
        capture_output=True, text=True, timeout=10)
    assert failed.returncode != 0 and config.read_text() == before_failure, failed
    print('PASS I3 literal flag boundary and separated value flags; I4 setup preserves config on success and failure')

def tui_once(root, letter):
    import fcntl
    import pty
    import select
    import struct
    import termios
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
    env = environment(root)
    env.update(TERM='xterm-256color', AXYNDRA_ASCII='1')
    process = subprocess.Popen([str(BINARY), '--fixture', '--cwd', str(root)],
        cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()
    def wait(needle):
        deadline = time.monotonic() + 10
        while needle not in output:
            ready, _, _ = select.select([master], [], [], max(0, deadline-time.monotonic()))
            assert ready, output[-4000:]
            output.extend(os.read(master, 65536))
    try:
        wait(b'fixture')
        output.clear()
        prompt = letter + 'ello'
        os.write(master, (prompt + '\r').encode())
        wait(('fixture response for ' + prompt).encode())
        os.write(master, b'\x04')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
def tui(root):
    for letter in 'hjklyHJKLY':
        workspace = root / letter
        workspace.mkdir()
        tui_once(workspace, letter)
    print('PASS I1 real PTY preserves all formerly reserved lowercase/uppercase initials')


def main():
    import sys
    scope = sys.argv[1] if len(sys.argv) > 1 else 'all'
    with tempfile.TemporaryDirectory(prefix='axyndra-frontend-') as directory:
        root = Path(directory)
        for name, check in [('cli', cli), ('acp', acp), ('rpc', rpc), ('tui', tui)]:
            if scope in ('all', name):
                workspace = root / name
                workspace.mkdir()
                check(workspace)

if __name__ == '__main__': main()
