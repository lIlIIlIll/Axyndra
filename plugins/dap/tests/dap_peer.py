#!/usr/bin/env python3
"""Real DAP wire peer; launch completes only after configurationDone."""
import json
import sys
from pathlib import Path

log = Path(sys.argv[1])
pending_launch = None
sequence = 1000

def send(value):
    global sequence
    sequence += 1
    value = dict(seq=sequence, **value)
    body = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    sys.stdout.buffer.flush()

def reply(request, body=None, success=True, message=''):
    send(dict(type='response', request_seq=request['seq'], command=request['command'], success=success,
              body=body or {}, message=message))

while True:
    headers = {}; frame = bytearray()
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise SystemExit(0)
        frame.extend(line)
        if line == b'\r\n':
            break
        key, value = line.split(b':', 1); headers[key.lower()] = value.strip()
    size = int(headers[b'content-length'])
    if not 1 <= size <= 8388608:
        raise SystemExit(2)
    raw = sys.stdin.buffer.read(size)
    if len(raw) != size:
        raise SystemExit(3)
    frame.extend(raw); request = json.loads(raw)
    with log.open('a', encoding='utf-8') as output:
        output.write(json.dumps(request, ensure_ascii=False, separators=(',', ':')) + '\n')
    with Path(str(log) + '.frames').open('a', encoding='utf-8') as output:
        output.write(frame.hex() + '\n')
    if request['type'] != 'request':
        continue
    command = request['command']; args = request.get('arguments', {})
    if command == 'initialize':
        assert args['supportsRunInTerminalRequest'] is False
        reply(request, dict(supportsConfigurationDoneRequest=True, supportsReadMemoryRequest=True,
                            supportsInstructionBreakpoints=True, supportsDataBreakpoints=True,
                            supportsDisassembleRequest=True, supportsWriteMemoryRequest=True))
        send(dict(type='event', event='initialized', body={}))
    elif command in ('launch', 'attach'):
        pending_launch = request
    elif command == 'configurationDone':
        reply(request)
        if pending_launch:
            reply(pending_launch, dict(started=True)); pending_launch = None
            send(dict(type='event', event='stopped', body=dict(reason='entry', threadId=1)))
    elif command == 'fixture/hang':
        continue
    elif command == 'fixture/error':
        reply(request, success=False, message='known adapter failure')
    elif command == 'fixture/observedStop':
        send(dict(type='event', event='output', body=dict(output=args.get('output', ''))))
        send(dict(type='event', event='stopped', body=dict(reason='breakpoint', threadId=11)))
        reply(request)
    elif command == 'fixture/nearResult':
        reply(request, dict(data='x' * 65300))
    elif command == 'fixture/runInTerminal':
        send(dict(type='request', command='runInTerminal', arguments=dict(kind='integrated', args=['/bin/false'])))
    elif command == 'threads':
        reply(request, dict(threads=[dict(id=1, name='main')]))
    elif command == 'stackTrace':
        reply(request, dict(stackFrames=[dict(id=2, name='frame', line=1, column=1,
            instructionPointerReference='0x40', source=dict(path='/fixture/main.py'))], totalFrames=1))
    elif command == 'scopes':
        reply(request, dict(scopes=[dict(name='locals', variablesReference=3, expensive=False)]))
    elif command == 'variables':
        reply(request, dict(variables=[dict(name='value', value='42', variablesReference=0)]))
    elif command == 'evaluate':
        reply(request, dict(result=args.get('expression', ''), variablesReference=0))
    elif command == 'setBreakpoints':
        if any(item['line'] == 13 for item in args.get('breakpoints', [])):
            reply(request, success=False, message='known source breakpoint failure')
        else:
            reply(request, dict(breakpoints=[dict(verified=True, line=item['line']) for item in args.get('breakpoints', [])]))
    else:
        reply(request, dict(command=command, arguments=args))
    if command in ('continue', 'next', 'stepIn', 'stepOut') and not args.get('fixture_no_continued', False):
        send(dict(type='event', event='continued', body=dict(threadId=1)))
