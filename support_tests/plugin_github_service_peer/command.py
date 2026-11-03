#!/usr/bin/python3
"""Fake external gh/git, not the plugin backend or host Runtime.

Installed read-only beside expected.json; cwd is the explicitly granted test
workspace. Only public arguments and booleans enter the command log.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time


def main():
    expected = json.loads(Path(__file__).with_name('expected.json').read_text())
    secret = os.environ.get('GH_TOKEN', '')
    if not secret or hashlib.sha256(secret.encode()).hexdigest() != expected['token_sha256']:
        raise SystemExit(71)
    if os.environ.get('AXYNDRA_GITHUB_UNGRANTED_TOKEN'):
        raise SystemExit(72)
    command = Path(sys.argv[0]).name
    arguments = sys.argv[1:]
    record = {'command': command, 'arguments': arguments, 'credential_verified': True,
              'ambient_absent': True}
    with Path('github-commands.jsonl').open('a', encoding='utf-8') as output:
        output.write(json.dumps(record, ensure_ascii=False, separators=(',', ':')) + '\n')
    if command == 'git':
        if arguments == ['remote', 'get-url', '--push', '--all', 'origin']:
            print('https://github.com/owner/project.git')
        elif 'push' in arguments:
            Path('github-push-effect').write_text('pushed')
            print('pushed')
        else:
            raise SystemExit(73)
        return
    if arguments[:2] == ['repo', 'view']:
        if '--branch' in arguments and arguments[arguments.index('--branch') + 1] == 'reflect-secret':
            # The actual private lifecycle wrapper must stop this byte stream
            # before it becomes a host service response/native endpoint input.
            sys.stdout.write(secret)
        elif '--jq' in arguments:
            print('owner/project')
        else:
            print(json.dumps({'nameWithOwner': 'owner/project', 'credential_verified': True}))
    elif arguments[:2] == ['pr', 'create']:
        body = arguments[arguments.index('--body') + 1] if '--body' in arguments else ''
        Path('github-created-body').write_text(body, encoding='utf-8')
        print('https://github.com/owner/project/pull/42')
    elif arguments[:2] == ['run', 'watch'] and arguments[2] == 'hang':
        # This descendant deliberately escapes the command's process group,
        # ignores TERM, and closes pipes. Product must kill the encompassing
        # retained backend PID namespace, not merely the command leader.
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.close(0); os.close(1); os.close(2)
            with Path('github-descendant-heartbeat').open('ab', buffering=0) as heartbeat:
                while True:
                    heartbeat.write(b'x')
                    time.sleep(.02)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        Path('github-hang-ready').write_text('ready')
        while True:
            time.sleep(.1)
    else:
        raise SystemExit(74)


if __name__ == '__main__':
    main()
