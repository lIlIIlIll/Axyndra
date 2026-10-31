"""Real local Workflow installation for the original TUI orchestration cases.

No fake Registry record or granted Source is written. Every maintenance child
uses the original physical process watcher and the case's unchanged timeout.
"""
from pathlib import Path
import hashlib
import json
import os
import sys

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts import rpc_case_process_watch as custody

FAMILIES196 = {
    'hub_peers': (('peer.list', 'peer.receive'), 'workspace.read'),
    'hub_messages': (('peer.send', 'peer.wait'), {
        'catalog': 'workspace.read',
        'services': {'peer.send': 'peer.message', 'peer.wait': 'workspace.read'}}),
    'hub_jobs': (('job.list', 'job.wait'), 'workspace.read'),
    'hub_cancel': (('job.cancel',), 'delegate'),
    'hub_process': (('process.service',), 'process.spawn'),
    'hub_process_read': (('process.observe',), 'workspace.read'),
}
EXECUTIONS196 = {'hub-subagents', 'concurrent-ownership',
                 'task-process-boundaries', 'capability-inventory'}


def _run196(case, label, arguments):
    log = case.case_dir / ('workflow196-' + label + '.log')
    command = ['/usr/bin/env', '-i', *[key + '=' + value
        for key, value in sorted(case.environment.items())],
        str(case.candidate), '--cwd', str(case.workspace), 'plugin', *arguments]
    # Record admission before entering a function which may fail or throw.
    case.record('workflow196_maintenance_pending', label=label, log=str(log),
                seconds=case.timeout, arguments=arguments)
    result = custody.run_case(command, log, case.timeout, cwd=case.workspace)
    (case.case_dir / ('workflow196-' + label + '.custody.json')).write_text(
        json.dumps(result, indent=2) + '\n', encoding='utf-8')
    case.record('workflow196_maintenance_returned', label=label, result=result)
    if (type(result.get('exit_code')) is not int or result['exit_code'] != 0
        or result.get('timed_out') is not False
        or not custody.process_custody_closed(result)
        or result.get('watcher_exit_code') != 0
        or result.get('watcher_fault') is not None):
        raise RuntimeError('actual Workflow maintenance did not return cleanly: ' + label)
    return log


def _records196(case, label):
    log = _run196(case, label, ['list', '--json'])
    records = json.loads(log.read_bytes())
    if not isinstance(records, list) or any(not isinstance(x, dict) for x in records):
        raise RuntimeError('actual plugin list must be the complete Registry JSON array')
    return records


def prepare_workflow196(case):
    if case.variant['execution'] not in EXECUTIONS196:
        return
    if getattr(case, 'workflow_record196', None) is not None:
        return
    supplied = os.environ.get('AXYNDRA_WORKFLOW_PLUGIN_PACKAGE')
    if not supplied:
        raise RuntimeError('this TUI case requires the actual same-source built Workflow package')
    package = Path(supplied).resolve(strict=True)
    descriptor_path = package / 'axyndra.plugin.json'
    descriptor = json.loads(descriptor_path.read_bytes())
    names = {x['name'] for x in descriptor.get('contributions', []) if x.get('kind') == 'tool'}
    if (descriptor.get('id') != 'workflow' or descriptor.get('entry_kind') != 'native-executable'
        or not {'task', 'yield', *FAMILIES196}.issubset(names)):
        raise RuntimeError('actual package does not contain the complete Native orchestration families')
    entry = (package / descriptor['entrypoint']).resolve(strict=True)
    if not entry.is_relative_to(package) or not entry.is_file() or not os.access(entry, os.X_OK):
        raise RuntimeError('actual Workflow entrypoint is not an executable inside its package')
    files = {}
    for item in sorted(package.rglob('*')):
        if item.is_file():
            if not item.resolve(strict=True).is_relative_to(package):
                raise RuntimeError('fixture package file escapes its actual package')
            files[item.relative_to(package).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()
    case.record('workflow196_package_observed', package=str(package), files=files,
        manifest_sha256=hashlib.sha256(descriptor_path.read_bytes()).hexdigest(),
        entrypoint_sha256=hashlib.sha256(entry.read_bytes()).hexdigest(),
        same_source_build_proof_required_from_invoking_fixture_gate=True)
    old = _records196(case, 'before')
    found = [x for x in old if x.get('namespace') == 'axyndra:workflow']
    if len(found) > 1:
        raise RuntimeError('fresh case has ambiguous Workflow Registry selections')
    if found:
        scope = found[0].get('scope')
        if scope not in ('user', 'workspace'):
            raise RuntimeError('actual installed Workflow scope is unknown')
        _run196(case, 'disable', ['disable', 'axyndra:workflow', '--scope', scope])
        _run196(case, 'update', ['update', 'axyndra:workflow', str(package), '--scope', scope])
    else:
        scope = 'user'
        _run196(case, 'import', ['import', str(package), '--scope', scope])
    records = _records196(case, 'installed')
    matches = [x for x in records if x.get('namespace') == 'axyndra:workflow']
    if len(matches) != 1:
        raise RuntimeError('real import did not publish one exact installed Workflow')
    record = matches[0]
    digest = record.get('content_digest')
    if (record.get('id') != 'workflow' or record.get('version') != descriptor['version']
        or record.get('scope') != scope or record.get('enabled') is not False
        or record.get('source_kind') != 'local' or Path(record.get('locator', '')).resolve() != package
        or not isinstance(digest, str) or not digest.startswith('sha256:') or len(digest) != 71
        or any(ch not in '0123456789abcdef' for ch in digest[7:])):
        raise RuntimeError('installed record differs from the actual selected local package')
    tools = [dict(name='task', profile='frozen-primitives-v1', services=['child.start', 'child.wait'],
                  preparation_provider='prepare_child'),
             dict(name='yield', profile='frozen-primitives-v1', services=['child.result.write'],
                  preparation_provider='prepare_child', invocation_capability='workspace.read')]
    tools += [dict(name=name, profile='frozen-primitives-v1', services=list(services),
                   preparation_provider='prepare_child', invocation_capability=capability)
              for name, (services, capability) in FAMILIES196.items()]
    directory = case.home / 'plugins'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'primitives.json'
    document = json.loads(path.read_bytes()) if path.exists() else dict(version=1, plugins=[])
    if document.get('version') != 1 or not isinstance(document.get('plugins'), list):
        raise RuntimeError('unexpected existing operator primitive document')
    entries = document['plugins']
    selected = dict(namespace=record['namespace'], package_digest=digest, tools=tools)
    prior = [x for x in entries if x.get('namespace') == record['namespace']]
    if prior and prior != [selected]:
        raise RuntimeError('case refuses to overwrite a different actual primitive selection')
    if not prior:
        document['plugins'].append(selected)
        path.write_text(json.dumps(document, indent=2) + '\n', encoding='utf-8')
    _run196(case, 'enable', ['enable', record['namespace'], '--scope', scope])
    enabled = _records196(case, 'enabled')
    matching = [x for x in enabled if x.get('namespace') == record['namespace']]
    expected = dict(record, enabled=True)
    if matching != [expected]:
        raise RuntimeError('actual enabled package changed its full installed identity')
    if [x for x in enabled if x.get('namespace') != record['namespace']] != [
        x for x in old if x.get('namespace') != record['namespace']]:
        raise RuntimeError('unrelated real Registry records changed')
    case.workflow_record196 = expected
    case.record('workflow196_ready', record=expected, primitive_selection=selected,
                no_authority_granted_by_installation=True)
