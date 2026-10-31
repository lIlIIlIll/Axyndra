#!/usr/bin/env python3
"""Actual public Registry mutations must preserve unknown facts and their error."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from owned_process import owned_process


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(value):
    return value.replace(os.environ.get('HOME', '/nonexistent-home'), '$HOME')


def run(args):
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    settings = args.settings.resolve() if args.settings else evidence / 'settings'
    workspace = evidence / 'workspace'; workspace.mkdir()
    source = evidence / 'source'; (source / 'skills/demo').mkdir(parents=True)
    (source / 'package.json').write_text(json.dumps({'name': 'fatal-load-public',
        'version': '1.0.0', 'pi': {'skills': ['skills']}}) + '\n')
    (source / 'skills/demo/SKILL.md').write_text('---\nname: public\ndescription: Exact public import fixture\n---\nOpaque supported Skill body.\n')
    keep = {'PATH', 'LANG', 'LC_ALL', 'HOME', 'XDG_RUNTIME_DIR', 'CANGJIE_HOME', 'CANGJIE_ROOT',
        'CANGJIE_PATH', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH', 'AXYNDRA_SDK_ROOT',
        'AXYNDRA_STDX_ROOT', 'AXYNDRA_NATIVE_ROOT', 'AXYNDRA_NETWORK_BRIDGE',
        'AXYNDRA_CLANG_RUNTIME_PATH', 'LD_LIBRARY_PATH'}
    env = {key: value for key, value in os.environ.items() if key in keep}
    env.update(AXYNDRA_HOME=str(settings), TMPDIR=str(evidence), TMP=str(evidence), TEMP=str(evidence),
               NO_COLOR='1', DISABLE_ZOXIDE='1')
    library = args.native_library.resolve(); assert library.is_file()
    commands, facts = [], []
    identity = {'app_sha256': sha256(args.app), 'native_sha256': sha256(library)}
    def command(arguments):
        # The frozen library prefix must be applied AFTER pinned SDK preparation.
        argv = [str(args.repo / 'scripts/pinned_cangjie'), '/usr/bin/bash', '-c',
            'export LD_LIBRARY_PATH="$1:${LD_LIBRARY_PATH:-}"; shift; exec "$@"',
            'frozen-native-runtime', str(library.parent), str(args.app), '--cwd', str(workspace), *arguments]
        with owned_process(argv, cwd=args.repo, env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
            output, error = process.communicate(timeout=90)
        result = {'argv': [normalized(value) for value in argv], 'exit': process.returncode,
                  'stdout': normalized(output.decode('utf-8')), 'stderr': normalized(error.decode('utf-8')), **identity}
        commands.append(result)
        (evidence / 'commands.json').write_text(json.dumps({'records': commands, **identity}, indent=2) + '\n')
        return result
    if args.settings is None:
        imported = command(['plugin', 'import', str(source)])
        assert imported['exit'] == 0, imported
        namespace = 'pi:fatal-load-public'
    else:
        assert args.namespace, 'a supplied prepared settings root requires its actual namespace'
        namespace = args.namespace
    lock = settings / 'plugins/lock.jsonl'; original = lock.read_bytes()
    rows = [json.loads(row) for row in original.splitlines() if row.strip()]
    index = next(index for index, row in enumerate(rows) if row.get('namespace') == namespace and 'history_for' not in row)
    assert rows[index]['enabled'] is False, 'fixture must begin genuinely imported and disabled'
    cases = [('future-schema', {'schema_version': 999}),
             ('unknown-field', {'future_fact': {'preserved': True}}),
             ('unknown-source', {'source_kind': 'future-installed-source'}),
             ('invalid-locator', {'locator': {'opaque': 'must retain'}}),
             ('invalid-enabled', {'enabled': 'future-state'}),
             ('unknown-revocation', {'explicitly_disabled': 'future-revocation-state'})]
    actions = [('enable', ['enable', namespace]), ('disable', ['disable', namespace]),
               ('update', ['update', namespace, str(source)]), ('rollback', ['rollback', namespace]),
               ('uninstall', ['uninstall', namespace])]
    try:
        for name, mutation in cases:
            prepared_rows = [dict(row) for row in rows]
            prepared_rows[index].update(mutation)
            prepared = ('\n'.join(json.dumps(row, ensure_ascii=False) for row in prepared_rows) + '\n').encode('utf-8')
            lock.write_bytes(prepared)
            before = sha256(lock)
            for scope in (None, 'user'):
                for action, arguments in actions:
                    request = ['plugin', *arguments] + (['--scope', scope] if scope else [])
                    result = command(request)
                    fact = {'case': name, 'action': action, 'scope': scope,
                            'before_sha256': before, 'after_sha256': sha256(lock), 'preserved': lock.read_bytes() == prepared,
                            'exit': result['exit'], 'diagnostic': result['stdout'] + result['stderr']}
                    facts.append(fact)
                    (evidence / 'facts.json').write_text(json.dumps(facts, indent=2) + '\n')
                    assert fact['exit'] != 0 and fact['preserved'], fact
                    assert 'plugin.lock_format_unsupported' in fact['diagnostic'], fact
                    assert 'plugin.not_found' not in fact['diagnostic'], fact
    finally:
        lock.write_bytes(original)
    assert lock.read_bytes() == original
    positive = {}
    try:
        historical = ('\n'.join(json.dumps({key: value for key, value in row.items() if key != 'schema_version'}, ensure_ascii=False) for row in rows) + '\n').encode('utf-8')
        lock.write_bytes(historical)
        visible = command(['plugin', 'list', '--json'])
        assert visible['exit'] == 0 and lock.read_bytes() == historical, visible
        assert any(item['namespace'] == namespace for item in json.loads(visible['stdout']))
        positive['known_legacy_readonly_original_bytes'] = sha256(lock)
        enabled = command(['plugin', 'enable', namespace])
        assert enabled['exit'] == 0, enabled
        upgraded = [json.loads(line) for line in lock.read_bytes().splitlines()]
        assert all(row['schema_version'] == 1 for row in upgraded), upgraded
        assert next(row for row in upgraded if row.get('namespace') == namespace and 'history_for' not in row)['enabled'] is True
        positive['known_legacy_explicit_v1_upgrade'] = True
        assert namespace.startswith('pi:')
        package_name = namespace[3:]
        # A second real public package generation, not a fabricated lock history.
        second = evidence / 'second-source'; (second / 'skills/demo').mkdir(parents=True)
        (second / 'package.json').write_text(json.dumps({'name': package_name, 'version': '2.0.0', 'pi': {'skills': ['skills']}}) + '\n')
        (second / 'skills/demo/SKILL.md').write_text('---\nname: public\ndescription: Second immutable public generation\n---\nNew supported Skill body.\n')
        updated = command(['plugin', 'update', namespace, str(second)])
        assert updated['exit'] == 0, updated
        disabled = command(['plugin', 'disable', namespace]); assert disabled['exit'] == 0, disabled
        rolled = command(['plugin', 'rollback', namespace]); assert rolled['exit'] == 0, rolled
        visible = command(['plugin', 'list', '--json']); assert visible['exit'] == 0, visible
        selected = next(item for item in json.loads(visible['stdout']) if item['namespace'] == namespace)
        assert selected['version'] == rows[index]['version'] and selected['content_digest'] == rows[index]['content_digest'] and selected['enabled'] is False, selected
        positive['public_rollback_preserves_explicit_revocation'] = selected['content_digest']
        broken = evidence / 'invalid-source'; broken.mkdir(); (broken / 'package.json').write_bytes(b'{broken upgrade')
        snapshot = lock.read_bytes()
        rejected = command(['plugin', 'update', namespace, str(broken)])
        assert rejected['exit'] != 0 and lock.read_bytes() == snapshot, rejected
        positive['failed_upgrade_original_generation_bytes'] = sha256(lock)
    finally:
        lock.write_bytes(original)
    assert lock.read_bytes() == original
    (evidence / 'summary.json').write_text(json.dumps({'status': 'PASS', 'cases': len(facts),
        'original_lock_sha256': sha256(lock), 'positive': positive, **identity}, indent=2) + '\n')
    print('PASS 60 exact public fatal-load refusals, legacy readonly/upgrade, rollback/revocation and failed-upgrade bytes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'app', 'native-library', 'evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--namespace')
    run(parser.parse_args())
