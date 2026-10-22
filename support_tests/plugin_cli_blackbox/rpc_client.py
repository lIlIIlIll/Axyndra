"""Real stdin-JSON RPC client shared by public executable acceptance cases."""
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
from owned_process import owned_process


class RpcClient:
    def __init__(self, argv, *, workspace, environment, evidence, label, timeout=60):
        self.evidence, self.label, self.timeout = Path(evidence), label, timeout
        self.frames, self.queue, self.sequence = [], queue.Queue(), 0
        self.log = (self.evidence / (label + '.jsonl')).open('w', encoding='utf-8')
        self.err = (self.evidence / (label + '.stderr.log')).open('wb')
        self.closed = False
        self.scope = owned_process(argv, cwd=workspace, env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=self.err, text=True, encoding='utf-8')
        self.process = self.scope.__enter__()

        def read():
            try:
                for line in self.process.stdout:
                    self.log.write(self.normalize(line)); self.log.flush()
                    self.queue.put(json.loads(line))
            except Exception as error:
                self.queue.put(error)
            finally:
                self.queue.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        try:
            self.wait(lambda frame: frame.get('type') == 'ready')
        except BaseException:
            self.close(require_success=False)
            raise

    @staticmethod
    def normalize(value):
        return value.replace(os.environ.get('HOME', '/nonexistent-home'), '$HOME')

    def wait(self, predicate):
        deadline = time.monotonic() + self.timeout
        while True:
            frame = self.queue.get(timeout=max(0, deadline - time.monotonic()))
            if isinstance(frame, Exception):
                raise frame
            if frame is None:
                raise AssertionError('RPC closed before requested response')
            self.frames.append(frame)
            if predicate(frame):
                return frame

    def request(self, kind, **fields):
        self.sequence += 1
        identifier = self.label + '-' + str(self.sequence)
        frame = dict(id=identifier, type=kind, **fields)
        wire = json.dumps(frame, ensure_ascii=False) + '\n'
        with (self.evidence / (self.label + '.input.jsonl')).open('a', encoding='utf-8') as stream:
            stream.write(self.normalize(wire))
        self.process.stdin.write(wire); self.process.stdin.flush()
        return identifier, self.wait(lambda reply: reply.get('id') == identifier)

    def close(self, require_success=True):
        if self.closed:
            return
        self.closed = True
        try:
            self.process.stdin.close()
            code = self.process.wait(timeout=20)
            if require_success:
                assert code == 0, code
        finally:
            self.scope.__exit__(None, None, None)
            self.reader.join(5)
            self.log.close(); self.err.close()
            (self.evidence / (self.label + '.exit.json')).write_text(
                json.dumps({'exit_code': self.process.returncode}) + '\n', encoding='utf-8')

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close(require_success=kind is None)
