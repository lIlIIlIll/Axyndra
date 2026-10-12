"""Bounded cleanup for subprocess sessions created by this acceptance harness."""
from contextlib import contextmanager
import os
import signal
import subprocess
import time


class HarnessInterrupted(RuntimeError):
    pass


@contextmanager
def termination_signals():
    """Turn one external termination into ordinary, cleanup-aware unwinding."""
    interrupted = False

    def interrupted_by(signum, frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise HarnessInterrupted("acceptance interrupted by signal " + str(signum))

    old = {number: signal.signal(number, interrupted_by) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        yield
    finally:
        for number, handler in old.items():
            signal.signal(number, handler)


def kill_owned(process):
    """Only Popen instances created with start_new_session=True are accepted."""
    if process.returncode is not None:
        return process.returncode
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return process.wait(timeout=5)


def stop_owned(process, grace=3):
    if process.returncode is not None:
        return process.returncode
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return process.wait(timeout=5)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        # Observe without reaping: retaining our child's PID prevents its group
        # id being recycled before the final bounded group cleanup.
        if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
            break
        time.sleep(0.01)
    # The leader may exit while a same-session descendant ignores TERM. Kill
    # the remaining group as well; its id is from our own unreused child.
    return kill_owned(process)


@contextmanager
def owned_process(command, *, grace=3, **kwargs):
    if "start_new_session" in kwargs:
        raise ValueError("owned_process always starts its own session")
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    try:
        yield process
    finally:
        if process.returncode is None:
            stop_owned(process, grace=grace)
