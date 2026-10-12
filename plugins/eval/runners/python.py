import ast, asyncio, contextlib, inspect, io, json, signal, sys, time, traceback
print('READY|py|1', flush=True)
state = {}
def install():
    def display(value):
        try:
            if isinstance(value, (dict, list, tuple, bool, int, float)) or value is None:
                print(json.dumps(value, ensure_ascii=False, default=str))
            else:
                print(value)
        except Exception:
            print(repr(value))
    state.update({'__name__': '__main__', 'display': display})
install()
class CellTimeout(Exception): pass
def alarm_handler(signum, frame): raise CellTimeout()
signal.signal(signal.SIGALRM, alarm_handler)
def run_awaitable(value):
    if inspect.isawaitable(value): return asyncio.run(value)
    return value
while True:
    line = sys.stdin.buffer.readline()
    if not line: break
    started = time.monotonic()
    out, err, exit_code, timed_out = io.StringIO(), io.StringIO(), 0, False
    try:
        timeout_text, reset_text, payload = line.decode().rstrip('\n').split('|', 2)
        timeout_ms = int(timeout_text)
        if reset_text == '1':
            state = {}
            install()
        code = bytes.fromhex(payload).decode('utf-8')
        signal.setitimer(signal.ITIMER_REAL, timeout_ms / 1000.0)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            tree = ast.parse(code, mode='exec')
            if tree.body and isinstance(tree.body[-1], ast.Expr):
                prefix = ast.Module(body=tree.body[:-1], type_ignores=[])
                if prefix.body:
                    value = eval(compile(prefix, '<eval>', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)
                    run_awaitable(value)
                expression = ast.Expression(tree.body[-1].value)
                value = eval(compile(expression, '<eval>', 'eval', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)
                value = run_awaitable(value)
                if value is not None: state['display'](value)
            else:
                value = eval(compile(tree, '<eval>', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), state)
                run_awaitable(value)
    except CellTimeout:
        timed_out, exit_code = True, 124
        err.write('eval cell timed out after ' + str(timeout_ms / 1000).rstrip('0').rstrip('.') + 's')
    except BaseException:
        exit_code = 1
        traceback.print_exc(file=err)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    duration = int((time.monotonic() - started) * 1000)
    response = 'OK|%d|%d|%d|%s|%s\n' % (exit_code, int(timed_out), duration, out.getvalue().encode().hex(), err.getvalue().encode().hex())
    sys.stdout.write(response)
    sys.stdout.flush()
