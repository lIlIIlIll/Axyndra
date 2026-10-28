"""A dedicated Linux subreaper for one original bounded unit-test invocation.

Unknown process identity is a failure, never proof of return. A physical exit
does not acknowledge retained test DATA. No arguments/environment are sampled.
"""
from pathlib import Path
import ctypes
import errno
import json
import math
import os
import signal
import subprocess
import sys
import time

CLEANUP_SECONDS = .25
_PROCESS_CAPS = {'case': 60, 'compilation': 900, 'host-case': 900}
_WORKER_MODES = {'case': '--owned-worker', 'compilation': '--owned-compilation-worker',
                 'host-case': '--owned-host-worker'}


def _cell(raw):
    cells = raw[raw.rindex(')') + 2:].split()
    state, parent, group, session, start = cells[0], int(cells[1]), int(cells[2]), int(cells[3]), cells[19]
    # A captured Linux dead task may lose both group identities together.
    # Preserve their original -1 values; this is not evidence of reaping.
    dead_unlinked = state in ('X', 'x') and parent >= 0 and group == -1 and session == -1
    if len(state) != 1 or not state.isalpha() or (min(parent, group, session) < 0 and not dead_unlinked) or not start.isdecimal():
        raise ValueError('invalid process identity fields')
    return dict(state=state, parent=parent, group=group, session=session, start=start)


def processes():
    found, uncertain = {}, []
    try:
        paths = list(Path('/proc').iterdir())
    except OSError as error:
        return found, [dict(pid=None, reason='proc_enumeration_unobservable', errno=error.errno)]
    for path in paths:
        if not path.name.isdigit():
            continue
        pid = int(path.name)
        try:
            found[pid] = _cell((path / 'stat').read_text())
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ESRCH):
                uncertain.append(dict(pid=pid, reason='process_stat_unobservable', errno=error.errno))
        except (ValueError, IndexError, UnicodeError):
            uncertain.append(dict(pid=pid, reason='process_stat_malformed', errno=None))
    return found, uncertain


def discover(owned, root_pid=None, root_start=None):
    shared_self = root_pid is None
    root_pid = os.getpid() if shared_self else root_pid
    current, uncertain = processes()
    # The dedicated watcher itself cannot change identity while executing;
    # a parent observing its returned/reaped watcher must pin starttime too.
    roots = {root_pid} if shared_self or (root_start is not None and root_pid in current
        and current[root_pid]['start'] == root_start) else set()
    seeds = roots | {pid for pid, old in owned.items()
        if pid in current and current[pid]['start'] == old['start']}
    while True:
        added = {pid for pid, value in current.items() if value['parent'] in seeds and pid not in seeds}
        if not added:
            break
        seeds |= added
    for pid in seeds - {root_pid}:
        if pid in current:
            owned[pid] = current[pid]
    actual = [dict(pid=pid, **current[pid]) for pid, old in owned.items()
        if pid in current and current[pid]['start'] == old['start']]
    # Every uncertain stat is retained: its parent is also unknown, so it
    # cannot safely be classified as unrelated to this descendant tree.
    return dict(live=[value for value in actual if value['state'] not in ('Z', 'X', 'x')],
        returned=[value for value in actual if value['state'] in ('Z', 'X', 'x')], unknown=uncertain)


def kill_exact(items):
    killed, uncertain = [], []
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        return killed, [dict(pid=None, reason='immutable_process_signal_identity_unavailable', errno=None)] if items else []
    for item in items:
        descriptor = None
        try:
            descriptor = os.pidfd_open(item['pid'])
            try:
                now = _cell(Path('/proc', str(item['pid']), 'stat').read_text())
            except OSError as error:
                if error.errno in (errno.ENOENT, errno.ESRCH):
                    continue
                raise
            if now['start'] != item['start'] or now['state'] in ('Z', 'X', 'x'):
                continue
            # pidfd pins the identity. A PID reused after the stat read cannot
            # receive this signal, unlike a bare os.kill(pid) after recheck.
            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            killed.append(item['pid'])
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ESRCH):
                uncertain.append(dict(pid=item['pid'], reason='owned_signal_unconfirmed', errno=error.errno))
        except (ValueError, IndexError, UnicodeError):
            uncertain.append(dict(pid=item['pid'], reason='signal_identity_malformed', errno=None))
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError as error:
                    uncertain.append(dict(pid=item['pid'], reason='signal_identity_descriptor_close_failed', errno=error.errno))
    return killed, uncertain


def kill_direct_child(process):
    # This private Popen child cannot have its PID reused while it remains
    # unreaped. Only this owner polls/waits it; adopted reaping excludes it.
    # pidfd then fixes the actual identity even if /proc stat is unobservable.
    if process is None or process.poll() is not None:
        return [], []
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        return [], [dict(pid=process.pid, reason='direct_child_identity_unavailable', errno=None)]
    descriptor = None
    try:
        descriptor = os.pidfd_open(process.pid)
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        return [process.pid], []
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ESRCH):
            return [], []
        return [], [dict(pid=process.pid, reason='direct_child_signal_unconfirmed', errno=error.errno)]
    finally:
        if descriptor is not None:
            os.close(descriptor)


def reap_adopted(owned, exclude=None):
    current, uncertain = processes()
    reaped = []
    for pid, old in list(owned.items()):
        now = current.get(pid)
        if pid == exclude or not now or now['start'] != old['start'] or now['parent'] != os.getpid():
            continue
        if now['state'] not in ('Z', 'X', 'x'):
            continue
        try:
            actual, _ = os.waitpid(pid, os.WNOHANG)
            if actual:
                reaped.append(actual)
        except ChildProcessError:
            # This identity already returned to another real wait owner.
            pass
        except OSError as error:
            uncertain.append(dict(pid=pid, reason='owned_reap_unconfirmed', errno=error.errno))
    return reaped, uncertain


def _only_kernel_exiting(items):
    """Permit waiting, never return: PF_EXITING tasks still need actual reaping."""
    uncertain = []
    for item in items:
        try:
            raw = Path(f"/proc/{item['pid']}/stat").read_text()
            current = _cell(raw)
            flags = int(raw[raw.rindex(')') + 2:].split()[6])
            if flags < 0:
                raise ValueError('invalid process flags')
            if current['start'] != item['start'] or current['state'] in ('Z', 'X', 'x'):
                continue
            if not flags & 0x00000004:  # Linux PF_EXITING, not task run-state.
                return False, uncertain
        except OSError as error:
            if error.errno not in (errno.ENOENT, errno.ESRCH):
                uncertain.append(dict(pid=item['pid'], reason='kernel_exit_unobservable', errno=error.errno))
        except (ValueError, IndexError, UnicodeError):
            uncertain.append(dict(pid=item['pid'], reason='kernel_exit_identity_malformed', errno=None))
    return not uncertain, uncertain


def _cleanup(process, owned, root_pid=None, root_start=None):
    cleanup, unknown, reaped = [], [], []
    deadline = time.monotonic() + CLEANUP_SECONDS
    while True:
        observed = discover(owned, root_pid, root_start)
        unknown.extend(observed['unknown'])
        killed, failed = kill_exact(observed['live'])
        cleanup.extend(killed); unknown.extend(failed)
        if process is not None:
            try:
                process.poll()
                if process.returncode is None:
                    killed, failed = kill_direct_child(process)
                    cleanup.extend(killed); unknown.extend(failed)
                    process.wait(timeout=max(0, min(.01, deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                pass
            except OSError as error:
                unknown.append(dict(pid=process.pid, reason='leader_wait_unconfirmed', errno=error.errno))
        # Never waitpid(-1) in a shared caller, and never steal Popen's leader
        # status. The dedicated watcher reaps only observed adopted children.
        if root_pid is None:
            returned, failed = reap_adopted(owned, exclude=None if process is None else process.pid)
            reaped.extend(returned); unknown.extend(failed)
        post = discover(owned, root_pid, root_start)
        unknown.extend(post['unknown'])
        if time.monotonic() >= deadline or (not post['live'] and not post['returned'] and not post['unknown']):
            break
        time.sleep(.005)
    final = discover(owned, root_pid, root_start)
    unknown.extend(final['unknown'])
    return dict(cleanup_exact_pids=sorted(set(cleanup)), reaped_adopted_pids=sorted(set(reaped)),
        remaining_after_cleanup=final['live'], unreaped_owned_processes=final['returned'], unknown=unknown)


def _run_worker(command, log, seconds, execution_deadline, cwd=None, purpose='case'):
    if sys.platform != 'linux' or not Path('/proc').is_dir():
        raise ValueError('RPC process isolation requires Linux process identities')
    maximum = _PROCESS_CAPS.get(purpose, 0)
    if not 0 < seconds <= maximum or not math.isfinite(execution_deadline):
        raise ValueError('original role-specific cap and absolute monotonic deadline are mandatory')
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    prctl.restype = ctypes.c_int
    prior = ctypes.c_int()
    if prctl(37, ctypes.addressof(prior), 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'prior subreaper status unavailable')
    initial, uncertainty = processes()
    if uncertainty or any(value['parent'] == os.getpid() for value in initial.values()):
        raise ValueError('fresh watcher has unknown or preexisting children')
    owned, process, survivors, unknown = {}, None, [], []
    naturally_reaped = []
    code, timed_out, fault = 1, False, None
    cleanup = dict(cleanup_exact_pids=[], reaped_adopted_pids=[], remaining_after_cleanup=[], unreaped_owned_processes=[], unknown=[])
    changed = False; restored = False
    started = time.monotonic()
    deadline = min(execution_deadline, started + seconds)
    try:
        if prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), 'case subreaper setup failed')
        changed = True
        # This try encloses log open and spawn as well as every observation.
        with log.open('xb') as output:
            if time.monotonic() >= deadline:
                timed_out = True; code = 124
                raise TimeoutError('absolute execution deadline expired before case spawn')
            process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            while True:
                observed = discover(owned); unknown.extend(observed['unknown'])
                actual = process.poll()
                # A namespace init can be inside irreversible kernel exit while
                # awaiting zombies adopted by this very watcher. Discharge our
                # real wait ownership before judging its physical return.
                if any(item['parent'] == os.getpid() and item['pid'] != process.pid for item in observed['returned']):
                    harvested, failed = reap_adopted(owned, exclude=process.pid)
                    naturally_reaped.extend(harvested); unknown.extend(failed)
                # A late observation cannot certify that the physical case
                # returned within its original execution window.
                if time.monotonic() >= deadline:
                    timed_out = True; code = 124; break
                if actual is not None:
                    code = actual
                    pending = discover(owned); unknown.extend(pending['unknown'])
                    if unknown:
                        fault = 'unobservable_process_identity'; break
                    if pending['live'] or pending['returned']:
                        exiting, failed = _only_kernel_exiting(pending['live'])
                        unknown.extend(failed)
                        if failed:
                            fault = 'unobservable_process_identity'; break
                        if exiting:
                            # No added grace: only already exiting tasks may
                            # finish, within the original absolute deadline.
                            # A genuinely live descendant still fails at once.
                            time.sleep(min(.005, max(0, deadline - time.monotonic())))
                            continue
                    break
                if unknown:
                    fault = 'unobservable_process_identity'; break
                if time.monotonic() >= deadline:
                    timed_out = True; code = 124; break
                time.sleep(.025)
            observed = discover(owned); survivors = observed['live']; unknown.extend(observed['unknown'])
    except BaseException as error:
        fault = type(error).__name__
    finally:
        try:
            cleanup = _cleanup(process, owned)
            unknown.extend(cleanup['unknown'])
        except BaseException as error:
            unknown.append(dict(pid=None, reason='cleanup_helper_failed_' + type(error).__name__, errno=None))
        # Restore the original policy only after actual clean final observation.
        # Failure/unknown keeps the dedicated watcher explicitly unretired.
        if changed and not cleanup['remaining_after_cleanup']:
            final = discover(owned)
            unknown.extend(final['unknown'])
            if not final['live'] and not final['returned'] and not final['unknown']:
                if prctl(36, prior.value, 0, 0, 0) == 0:
                    restored = True
                else:
                    unknown.append(dict(pid=None, reason='subreaper_restore_failed', errno=ctypes.get_errno()))
    returned = process is not None and process.returncode is not None
    if timed_out:
        code = 124
    elif fault or unknown or survivors or cleanup['remaining_after_cleanup'] or cleanup['unreaped_owned_processes'] or not returned or not restored:
        code = code or 1
    return dict(exit_code=code, timed_out=timed_out, observed_processes=len(owned),
        surviving_owned_processes=survivors, remaining_after_cleanup=cleanup['remaining_after_cleanup'],
        unreaped_owned_processes=cleanup['unreaped_owned_processes'],
        cleanup_exact_pids=cleanup['cleanup_exact_pids'],
        reaped_adopted_pids=sorted(set(naturally_reaped + cleanup['reaped_adopted_pids'])),
        unknown_process_observations=unknown, watcher_fault=fault, subreaper_restored=restored,
        physical_leader_returned=returned, case_process_seconds=seconds, wall_seconds=time.monotonic()-started,
        execution_deadline_monotonic=execution_deadline, effective_execution_deadline_monotonic=deadline,
        subreaper=True, dedicated_watcher=True, physical_exit_is_data_consumption_ACK=False,
        scope='Only this fresh watcher descendant tree and immutable process identities; unknown is FAIL, not return.')



def parent_cleanup_closed(value):
    """Only the actual parent cleanup's complete final witness proves return."""
    fields={'cleanup_exact_pids','reaped_adopted_pids','remaining_after_cleanup',
            'unreaped_owned_processes','unknown'}
    return (type(value) is dict and fields <= set(value) and
            all(type(value[key]) is list for key in fields) and
            not value['remaining_after_cleanup'] and not value['unreaped_owned_processes'] and
            not value['unknown'])


def process_custody_closed(value):
    """Require both actual owners; an absent or pending call is not a return."""
    true_fields=('physical_leader_returned','physical_watcher_returned','subreaper_restored')
    empty_fields=('surviving_owned_processes','remaining_after_cleanup',
                  'unreaped_owned_processes','unknown_process_observations')
    return (type(value) is dict and all(value.get(key) is True for key in true_fields)
        and value.get('watcher_timed_out') is False
        and all(type(value.get(key)) is list and value[key] == [] for key in empty_fields)
        and parent_cleanup_closed(value.get('parent_cleanup')))


def _actual_clean_worker_receipt(result, execution_deadline, seconds):
    """Independently reject incomplete or contradictory return witnesses."""
    return (type(result.get('exit_code')) is int and result['exit_code'] == 0
        and result.get('timed_out') is False and result.get('watcher_timed_out') is False
        and result.get('physical_watcher_returned') is True
        and result.get('watcher_exit_code') == 0 and result.get('watcher_starttime') is not None
        and result.get('physical_leader_returned') is True and result.get('subreaper_restored') is True
        and result.get('dedicated_watcher') is True and result.get('subreaper') is True
        and result.get('case_process_seconds') == seconds
        and result.get('execution_deadline_monotonic') == execution_deadline
        and isinstance(result.get('effective_execution_deadline_monotonic'), (int, float))
        and math.isfinite(result['effective_execution_deadline_monotonic'])
        and result['effective_execution_deadline_monotonic'] <= execution_deadline
        and result.get('watcher_fault') is None
        and parent_cleanup_closed(result.get('parent_cleanup'))
        and result.get('surviving_owned_processes') == [] and result.get('remaining_after_cleanup') == []
        and result.get('unreaped_owned_processes') == [] and result.get('unknown_process_observations') == [])


def _run_owned(command, log, seconds, cwd=None, purpose='case'):
    """The CI parent never becomes subreaper or reaps a shared child's handle."""
    maximum = _PROCESS_CAPS.get(purpose, 0)
    if sys.platform != 'linux' or not 0 < seconds <= maximum:
        raise ValueError('fresh Linux watcher and original role-specific process cap required')
    log = Path(log).resolve()
    receipt = log.with_name(log.name + '.process.json')
    watcher_log = log.with_name(log.name + '.watcher.log')
    if log.exists() or receipt.exists() or watcher_log.exists():
        raise ValueError('fresh raw/process/watcher paths required')
    watched, witness, outer_unknown = {}, None, []
    witness_start = None; watcher_timed_out = False
    started = time.monotonic()
    execution_deadline = started + seconds
    cleanup = dict(cleanup_exact_pids=[], reaped_adopted_pids=[],
        remaining_after_cleanup=[], unreaped_owned_processes=[], unknown=[])
    with watcher_log.open('xb') as output:
        try:
            worker_mode = _WORKER_MODES[purpose]
            witness = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), worker_mode,
                str(log), str(receipt), str(seconds), repr(execution_deadline), '--', *command], cwd=cwd,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            witness_start = None
            try:
                witness_start = _cell(Path('/proc', str(witness.pid), 'stat').read_text())['start']
            except OSError as error:
                # Even genuine ENOENT here supplies no original tree root.
                # A receipt alone cannot replace this lost identity witness.
                outer_unknown.append(dict(pid=witness.pid, reason='watcher_root_identity_unobservable', errno=error.errno))
            except (ValueError, IndexError, UnicodeError):
                outer_unknown.append(dict(pid=witness.pid, reason='watcher_root_identity_malformed', errno=None))
            # Execution retains the original cap. This separate bounded grace
            # is solely cleanup/reap, never extra test time that can grant PASS.
            deadline = execution_deadline + 2 * CLEANUP_SECONDS
            while witness.poll() is None:
                seen = discover(watched, witness.pid, witness_start); outer_unknown.extend(seen['unknown'])
                if time.monotonic() >= deadline:
                    watcher_timed_out = True; break
                time.sleep(.025)
        except BaseException as error:
            outer_unknown.append(dict(pid=None, reason='watcher_parent_failed_' + type(error).__name__, errno=None))
        finally:
            if witness is not None:
                try:
                    cleanup = _cleanup(witness, watched, witness.pid, witness_start)
                except BaseException as error:
                    outer_unknown.append(dict(pid=witness.pid, reason='watcher_parent_cleanup_failed_' + type(error).__name__, errno=None))
    try:
        result = json.loads(receipt.read_text())
        if not isinstance(result, dict):
            raise ValueError('actual worker receipt is not an object')
    except (OSError, ValueError):
        result = dict(exit_code=1, timed_out=witness is not None and witness.returncode is None, observed_processes=len(watched),
            surviving_owned_processes=[], remaining_after_cleanup=cleanup.get('remaining_after_cleanup', cleanup.get('live', [])),
            cleanup_exact_pids=cleanup.get('cleanup_exact_pids', []), reaped_adopted_pids=[],
            physical_leader_returned=False, case_process_seconds=seconds,
            physical_exit_is_data_consumption_ACK=False, dedicated_watcher=True,
            watcher_fault='missing_or_malformed_actual_worker_receipt', unknown_process_observations=[])
    result['custody_role'] = purpose
    result['watcher_log'] = watcher_log.name
    result['watcher_receipt'] = receipt.name
    result['physical_watcher_returned'] = witness is not None and witness.returncode is not None
    result['watcher_exit_code'] = None if witness is None else witness.returncode
    result['watcher_timed_out'] = watcher_timed_out
    result['watcher_starttime'] = witness_start
    # The worker and its parent are independent actual cleanup owners.
    # Keep the complete parent observation; its failure is never folded only
    # into an exit code while returning an apparently empty worker frame.
    result['parent_cleanup'] = cleanup
    result.setdefault('unknown_process_observations', []).extend(outer_unknown + cleanup.get('unknown', []))
    if (not _actual_clean_worker_receipt(result, execution_deadline, seconds)
        or cleanup.get('live', []) or cleanup.get('remaining_after_cleanup', []) or cleanup.get('unreaped_owned_processes', [])):
        result['exit_code'] = result.get('exit_code') or 1
    return result


def run_case(command, log, seconds, cwd=None):
    return _run_owned(command, log, seconds, cwd=cwd, purpose='case')


def run_compilation(command, log, seconds=900, cwd=None):
    return _run_owned(command, log, seconds, cwd=cwd, purpose='compilation')


def run_host_case(command, log, seconds, cwd=None):
    return _run_owned(command, log, seconds, cwd=cwd, purpose='host-case')


def main():
    purposes = {mode: purpose for purpose, mode in _WORKER_MODES.items()}
    if len(sys.argv) < 8 or sys.argv[1] not in purposes or sys.argv[6] != '--':
        raise ValueError('dedicated worker expects fresh raw/receipt, seconds, absolute monotonic deadline, --, exact argv')
    log, receipt, seconds = Path(sys.argv[2]), Path(sys.argv[3]), float(sys.argv[4])
    execution_deadline = float(sys.argv[5])
    if receipt.exists() or log.exists():
        raise ValueError('actual worker paths must be fresh')
    purpose = purposes[sys.argv[1]]
    result = _run_worker(sys.argv[7:], log, seconds, execution_deadline, purpose=purpose)
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['exit_code'] == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
