"""Run every compiled RPC case in its own bounded process; retain all raw logs."""
import hashlib
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from product_unit_gate import dry_run_cases, has_compiler_error, run_logged
from rpc_case_process_watch import parent_cleanup_closed, process_custody_closed, run_compilation

# The qualified SDK result parser is inserted here from the observed,
# independently checked parser. Filtering excludes inventory entries; all
# entries still receive their own real execution before module credit.


def qualified_filtered_result(raw,module,qualified_case,full_inventory):
    text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',raw.decode('utf-8') if isinstance(raw,bytes) else raw)
    assert full_inventory and len(full_inventory)==len(set(full_inventory))
    assert full_inventory.count(qualified_case)==1
    sections=re.split(r'(?m)^Project tests finished(?:, time elapsed: [0-9]+ ns)?, RESULT:\s*$',text)
    assert len(sections)==2,'missing/duplicate completed SDK project section'
    suite=None;package=None;results=[]
    for line in sections[0].splitlines():
        match=re.fullmatch(r'\s*TP: ([A-Za-z_][A-Za-z_0-9]*)(?:, time elapsed: [0-9]+ ns)?, RESULT:\s*',line)
        if match:package=match.group(1);suite=None;continue
        match=re.fullmatch(r'\s*TCS: ([A-Za-z_][A-Za-z_0-9]*)(?:, time elapsed: [0-9]+ ns)?, RESULT:\s*',line)
        if match:
            assert package==module,'result suite outside actual selected package'
            suite=match.group(1);continue
        match=re.fullmatch(r'\s*\[\s*(PASSED|FAILED|ERROR)\s*\] CASE: ([A-Za-z_][A-Za-z_0-9]*) \([0-9]+ ns\)\s*',line)
        if match:
            assert package==module and suite,'unbound actual case result'
            results.append(dict(case=suite+'.'+match.group(2),status=match.group(1)))
        elif re.search(r'\] CASE:',line):
            raise AssertionError('unknown, skipped or malformed actual CASE result')
    assert len(results)==1 and results[0]['case']==qualified_case,'filter executed a different/multiple/missing identity'
    summaries=re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)',text)
    assert len(summaries)==2 and summaries[0]==summaries[1],'package/project complete totals differ'
    total,passed,skipped,errors,failed=map(int,summaries[0])
    assert total==len(full_inventory) and skipped==total-1
    assert passed+errors+failed==1 and total==passed+skipped+errors+failed
    assert (passed==1)==(results[0]['status']=='PASSED')
    assert (errors==1)==(results[0]['status']=='ERROR')
    assert (failed==1)==(results[0]['status']=='FAILED')
    assert re.search(r'(?m)^TP: '+re.escape(module)+r'\.\*, time elapsed: [0-9]+ ns, RESULT:\s*$',sections[1])
    terminal=re.findall(r'(?m)^(?:cjpm test (success|failed)|Error: cjpm test (failed))\s*$',sections[1])
    terminal=[plain or diagnostic for plain,diagnostic in terminal]
    assert terminal==(['success'] if passed==1 else ['failed']),'SDK terminal status contradicts the selected case'
    return dict(qualified_case=qualified_case,results=results,
        summary=dict(total=total,passed=passed,skipped=skipped,errors=errors,failed=failed),
        actually_executed_cases=1,filter_excluded_inventory_cases=skipped,whole_module_credit=0)

def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _rpc_source_inputs(root):
    files = {}
    required = (
        'scripts/pinned_cangjie', 'scripts/check_sdk.sh', 'scripts/sdk_paths.sh',
        'scripts/check_native_compiler.sh', 'scripts/prepare_native_deps.sh',
        'scripts/product_unit_gate.py', 'scripts/product_unit_inventory.json',
        'scripts/rpc_unit_isolation.py', 'scripts/rpc_case_process_watch.py',
        'libs/process4cj/native/process4cj_native.c',
        'libs/process4cj/native/sandbox_net_bridge.c')
    for name in required:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('RPC required launcher or Native source missing: ' + name)
    for base, directories, names in os.walk(root, followlinks=False):
        directories[:] = [n for n in directories if n not in ('.git', '.cjpm', 'target', '__pycache__')]
        for directory in directories:
            if (Path(base) / directory).is_symlink():
                raise ValueError('RPC source directory is a symbolic link')
        for name in names:
            path = Path(base) / name
            relative = path.relative_to(root).as_posix()
            native_source = (relative.startswith('libs/process4cj/native/') and
                             path.suffix in ('.c', '.h', '.S', '.s', '.sh', '.py'))
            if name.endswith(('.cj', '.toml', '.lock')) or relative.startswith('scripts/') or native_source:
                if path.is_symlink():
                    raise ValueError('RPC source input is a symbolic link')
                files[relative] = _sha(path)
    return files


def _rpc_compiled_inputs(root):
    files = {}
    generated = 0
    native = root / 'libs/process4cj/native'
    for name in ('libprocess4cj_native.so', 'sandbox-net-bridge'):
        path = native / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('RPC required physical Native input missing: ' + name)
        with path.open('rb') as stream:
            if not stream.read(4).startswith(b'\x7fELF'):
                raise ValueError('RPC Native input is not the actual compiled ELF: ' + name)
    for target in (root / 'target', root / 'agent_rpc/target', native):
        if target.is_symlink():
            raise ValueError('RPC compiled input directory is a symbolic link')
        if not target.is_dir():
            continue
        for base, directories, names in os.walk(target, followlinks=False):
            for directory in directories:
                if (Path(base) / directory).is_symlink():
                    raise ValueError('RPC compiled input directory is a symbolic link')
            for name in names:
                path = Path(base) / name
                if path.is_symlink():
                    raise ValueError('RPC compiled input is a symbolic link')
                if not path.is_file():
                    continue
                with path.open('rb') as stream:
                    magic = stream.read(4)
                if magic.startswith((b'\x7fELF', b'MZ')) or (target == native and name.endswith('.compiler-id')):
                    files[path.relative_to(root).as_posix()] = _sha(path)
                    if target != native:
                        generated += 1
    if not generated:
        raise ValueError('RPC dry run produced no physical compiled test inputs')
    return files


def _rpc_inputs_unchanged(root, source, compiled):
    return (_rpc_source_inputs(root) == source and
            _rpc_compiled_inputs(root) == compiled)


def _run_rpc_case(command, log, root, seconds):
    from rpc_case_process_watch import run_case
    value = run_case(command, log, seconds, cwd=root)
    value['owned_group_survived_leader'] = bool(value['surviving_owned_processes'] or value['remaining_after_cleanup'])
    return value


def run_isolated_agent_rpc(root, output_dir, log):
    root = root.resolve()
    # This gate binds the default physical targets and Native libraries.
    # A caller must not redirect a build to an unobserved location.
    for key in ('AXYNDRA_CANONICAL_TARGET_ROOT', 'AXYNDRA_NATIVE_OUTPUT', 'AXYNDRA_NETWORK_BRIDGE_OUTPUT'):
        if os.environ.get(key):
            raise ValueError('RPC isolation cannot bind redirected build inputs: ' + key)
    base = [str(root / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', 'agent_rpc']
    dry_log = output_dir / 'agent_rpc.dry-run.log'
    command = base + ['--dry-run', '--parallel', '1', '--timeout-each=60s', '--no-color', '--no-progress']
    record = dict(member='agent_rpc', command=command, log=log.name,
                  dry_run_log=dry_log.name, exit_code=1, status='FAIL', case_logs=[],
                  runtime_total_seconds=900, original_case_seconds=60,
                  physical_exit_is_data_consumption_ACK=False)
    passed = 0
    try:
        compilation = dict(command=command, log=dry_log.name, original_process_cap_seconds=900,
            process={}, watcher_call_started=True, watcher_call_returned=False)
        record['compilation'] = compilation
        process = run_compilation(command, dry_log, 900, cwd=root)
        compilation.update(process=process, watcher_call_returned=True)
        compilation['log_sha256'] = _sha(dry_log)
        for key in ('watcher_receipt', 'watcher_log'):
            relative = process[key]
            if Path(relative).name != relative:
                raise ValueError('RPC compilation watcher artifact escaped its actual directory')
            sidecar = dry_log.parent / relative
            if sidecar.is_symlink() or not sidecar.is_file():
                raise ValueError('RPC actual compilation watcher sidecar missing')
            compilation[key + '_sha256'] = _sha(sidecar)
            compilation[key] = sidecar.relative_to(output_dir).as_posix()
        code = process['exit_code']
        record['exit_code'] = code or 1
        dry_text = dry_log.read_text(errors='strict')
        log.write_bytes(dry_log.read_bytes())
        if not process_custody_closed(process):
            raise ValueError('RPC compiler process custody did not close')
        if code != 0 or process['timed_out'] or has_compiler_error(dry_text):
            record['error'] = 'RPC complete compilation/enumeration failed'
            return record
        plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', dry_text)
        cases = dry_run_cases(plain)
        totals = re.findall(r'Summary: TOTAL:\s*(\d+),\s*SKIPPED:\s*(\d+)', plain)
        if not totals or any(int(n) != len(cases) or int(skipped) != 0 for n, skipped in totals):
            raise ValueError('RPC enumeration omitted or skipped compiled identities')
        record.update(scope=dict(enumerated=cases, selected=list(cases)),
                      enumerated_case_count=len(cases), selected_case_count=len(cases), case_count=len(cases))
        source = _rpc_source_inputs(root)
        compiled = _rpc_compiled_inputs(root)
        record['source_inputs'] = source
        record['compiled_inputs'] = compiled
        directory = output_dir / 'agent_rpc-cases'
        directory.mkdir(exist_ok=False)
        deadline = time.monotonic() + 900
        for index, name in enumerate(cases):
            if not _rpc_inputs_unchanged(root, source, compiled):
                raise ValueError('RPC source or compiled inputs changed between cases')
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('RPC original whole-module deadline expired')
            case_log = directory / f'{index + 1:03d}-{name}.log'
            command = base + ['--skip-build', '--filter', name, '--parallel', '1',
                              '--timeout-each=60s', '--no-color', '--no-progress']
            # Register the real call before crossing the process boundary.
            # Missing return fields mean unknown custody, never empty cleanup.
            observation = dict(qualified_case=name, command=command,
                log=case_log.relative_to(output_dir).as_posix(),
                original_process_cap_seconds=60, remaining_module_seconds=remaining,
                process={}, watcher_call_started=True, watcher_call_returned=False)
            record['case_logs'].append(observation)
            process = _run_rpc_case(command, case_log, root, min(60, remaining))
            observation.update(process=process, watcher_call_returned=True)
            # Forensic reads can fail independently after a returned watcher.
            # Its complete parent/worker witness is already in the record.
            observation['log_sha256'] = _sha(case_log)
            for key in ('watcher_receipt', 'watcher_log'):
                relative = process[key]
                if Path(relative).name != relative:
                    raise ValueError('RPC watcher artifact escaped its actual case directory')
                sidecar = case_log.parent / relative
                if sidecar.is_symlink() or not sidecar.is_file():
                    raise ValueError('RPC actual watcher sidecar missing')
                observation[key + '_sha256'] = _sha(sidecar)
                observation[key] = sidecar.relative_to(output_dir).as_posix()
            with log.open('ab') as combined:
                combined.write(('\nRPC case: ' + name + '\n').encode())
                combined.write(case_log.read_bytes())
            observation['result'] = qualified_filtered_result(case_log.read_bytes(), 'agent_rpc', name, cases)
            valid = (process['exit_code'] == 0 and not process['timed_out'] and
                     not process['owned_group_survived_leader'] and process['physical_leader_returned'] and
                     process['physical_watcher_returned'] and process['watcher_exit_code'] == 0 and
                     not process['watcher_timed_out'] and process['subreaper_restored'] and
                     not process['unknown_process_observations'] and not process['unreaped_owned_processes'] and
                     parent_cleanup_closed(process.get('parent_cleanup')) and
                     observation['result']['summary']['passed'] == 1 and
                     not has_compiler_error(case_log.read_text(errors='strict')))
            if not valid:
                raise ValueError('RPC isolated case failed: ' + name)
            if time.monotonic() > deadline:
                raise ValueError('RPC original whole-module deadline expired')
            passed += 1
        if not _rpc_inputs_unchanged(root, source, compiled):
            raise ValueError('RPC final source or compiled input guard failed')
        record.update(status='PASS', exit_code=0, total=len(cases), passed=passed,
                      failed=0, errors=0, skipped=0)
    except BaseException as error:
        record.update(status='FAIL', exit_code=1, passed=passed, error=str(error))
    return record
