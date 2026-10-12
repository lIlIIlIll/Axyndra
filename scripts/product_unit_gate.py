#!/usr/bin/env python3
"""Execute every inventoried workspace unit-test package and retain summaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]

def inventory(root):
    workspace = tomllib.loads((root / 'cjpm.toml').read_text())['workspace']
    found = {}
    for member in workspace['members']:
        files = sorted(p.relative_to(root).as_posix() for p in (root / member / 'src').rglob('*_test.cj'))
        if files:
            if member not in workspace['test-members']:
                raise ValueError(f'test member omitted: {member}')
            found[member] = files
    if not found:
        raise ValueError("empty unit-test inventory")
    return found

def has_compiler_error(text):
    # Compiler diagnostics start a line. Warning source excerpts can contain
    # parameter declarations such as error:AgentError without a diagnostic.
    plain = re.sub(r'\[[0-?]*[ -/]*[@-~]', '', text)
    return re.search(r'^\s*(?:error|fatal error):', plain, re.I | re.M) is not None


def summary(text):
    text = re.sub(r'\x1b\[[0-9;]*m', '', text)
    matches = re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)', text, re.I)
    if not matches:
        raise ValueError('missing unittest result summary')
    total, passed, skipped, errors, failed = map(int, matches[-1])
    if total == 0 or total != passed + skipped + errors + failed:
        raise ValueError('invalid unittest totals')
    return dict(total=total, passed=passed, failed=failed, skipped=skipped, errors=errors)

def run_logged(command, log, cwd, timeout=900):
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Terminate the entire compiler/test tree before starting another package.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 124


def dry_run_cases(text):
    suite = None
    cases = []
    for line in text.splitlines():
        suite_match = re.match(r'\s*TCS:\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if suite_match:
            suite = suite_match.group(1)
            continue
        case_match = re.match(r'\s*\[\s*NORUN\s*\]\s+CASE:\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if case_match:
            if suite is None:
                raise ValueError('dry-run case appeared before its test suite')
            cases.append(f'{suite}.{case_match.group(1)}')
    if not cases:
        raise ValueError('dry run returned no unit-test cases')
    if len(cases) != len(set(cases)):
        raise ValueError('dry run returned duplicate unit-test cases')
    return cases


def prepare_bundled_plugin(root, output_dir, directory, command, environment_name):
    """Build and check a fresh package; inherited fixture paths are not reused."""
    log = output_dir / f'{directory}-plugin-fixture.log'
    exit_code = run_logged(command, log, root)
    if exit_code != 0:
        raise ValueError(f'{directory} plugin fixture preparation failed: {exit_code}; see {log.name}')
    lines = [line.strip() for line in log.read_text(errors='replace').splitlines() if line.strip()]
    if not lines:
        raise ValueError(f'{directory} plugin fixture omitted its package path')
    package = Path(lines[-1])
    if not package.is_absolute():
        raise ValueError(f'{directory} plugin fixture returned a relative package path')
    package = package.resolve(strict=True)
    artifacts = (root / 'target/plugin-contract-fixtures').resolve()
    if not package.is_dir() or not package.is_relative_to(artifacts):
        raise ValueError(f'{directory} plugin fixture is outside its generated artifact directory')
    manifest_path = package / 'axyndra.plugin.json'
    manifest = json.loads(manifest_path.read_text())
    expected = json.loads((root / 'plugins' / directory / 'axyndra.plugin.json').read_text())
    if manifest != expected or manifest.get('entry_kind') != 'native-executable':
        raise ValueError(f'{directory} plugin fixture manifest differs from the current source')
    entrypoint = Path(manifest['entrypoint'])
    binary = (package / entrypoint).resolve(strict=True)
    if entrypoint.is_absolute() or not binary.is_relative_to(package) or not binary.is_file():
        raise ValueError(f'{directory} plugin fixture entrypoint escapes its package')
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    provenance = json.loads((package / 'package-provenance.json').read_text())
    if provenance.get('plugin_sha256') != digest:
        raise ValueError(f'{directory} plugin fixture binary differs from its package provenance')
    os.environ[environment_name] = str(package)
    return dict(plugin=directory, command=command, log=log.name, status='PASS',
                package=str(package), environment=environment_name,
                entrypoint_sha256=digest, package_provenance=provenance)


def requested_scope(found, expected, package=None, case_prefix=None, inventory_only=False):
    # Validate the complete inventory before narrowing execution. A focused
    # run must not conceal newly added tests in an unselected package.
    if found != expected:
        changed = sorted(member for member in found.keys() | expected.keys() if found.get(member) != expected.get(member))
        raise ValueError('unit-test inventory differs for ' + ', '.join(changed) + '; review scripts/product_unit_inventory.json against manifest inventory')
    if package is not None and package not in found:
        raise ValueError(f'unknown unit-test package: {package}')
    if case_prefix is not None:
        if not case_prefix or package != 'agent_product':
            raise ValueError('--case-prefix requires a nonempty literal prefix and --package agent_product')
        if inventory_only:
            raise ValueError('--case-prefix requires execution and cannot be combined with --inventory-only')
    return {
        'kind': 'targeted' if package is not None else 'full',
        'requested': {'package': package, 'case_prefix': case_prefix},
        'enumerated_packages': list(found),
        'selected_packages': [package] if package is not None else list(found),
        'enumerated_cases': {},
        'selected_cases': {},
    }


def isolated_case_timeouts(name):
    # This case imports and hashes the separately packaged native search
    # artifact on the mounted workspace. Actual runs reached 54 seconds;
    # leave a bounded margin without extending HTTP deadlines or other cases.
    if name == 'PluginHttpServiceTests.separatelyPackagedWebSearchUsesRealProductGatewayAndSearxOrigin':
        return 90, 120
    # These exact fixtures already own longer bounded work: one 120-second
    # Model request, or two sequential 60-second Shell calls plus cleanup.
    # Match the previously authorized isolated diagnostic runner bounds only;
    # provider/service deadlines, payload limits and assertions stay unchanged.
    if name in (
        'ModelWireEnvelopeTests.installedMessagesMatchesObservedOldNearEightMiBSemanticSuccess',
        'PluginTransportBudgetTests.realShellSixteenMibAsciiAndEscapedNulKeepExactArtifactsAndReceipts',
    ):
        return 150, 180
    return 60, 90


def run_isolated_agent_product(root, output_dir, log, case_prefix=None):
    base = [str(root / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', 'agent_product']
    dry_log = output_dir / 'agent_product.dry-run.log'
    dry_command = base + ['--dry-run', '--no-color', '--no-progress']
    dry_exit = run_logged(dry_command, dry_log, root)
    record = {
        'member': 'agent_product',
        'command': dry_command,
        'log': log.name,
        'dry_run_log': dry_log.name,
        'exit_code': dry_exit,
        'status': 'FAIL',
    }
    dry_text = dry_log.read_text(errors='replace')
    log.write_text(dry_text)
    if dry_exit != 0:
        record['error'] = 'agent_product dry run failed'
        return record
    try:
        enumerated = dry_run_cases(dry_text)
        cases = [name for name in enumerated if case_prefix is None or name.startswith(case_prefix)]
        record['scope'] = {
            'requested': {'case_prefix': case_prefix},
            'enumerated': enumerated,
            'selected': cases,
        }
        record['enumerated_case_count'] = len(enumerated)
        record['selected_case_count'] = len(cases)
        record['excluded'] = len(enumerated) - len(cases)
        if not cases:
            raise ValueError(f'no unit-test cases match literal prefix: {case_prefix}')
    except ValueError as error:
        record['error'] = str(error)
        return record
    case_dir = output_dir / 'agent_product-cases'
    case_dir.mkdir(exist_ok=True)
    record['case_count'] = len(cases)
    record['case_logs'] = []
    record['case_timeouts'] = {}
    passed = 0
    for index, name in enumerate(cases):
        case_log = case_dir / f'{index + 1:03d}-{name}.log'
        case_seconds, process_seconds = isolated_case_timeouts(name)
        record['case_timeouts'][name] = {'case_seconds': case_seconds, 'process_seconds': process_seconds}
        command = base + [
            '--skip-build', '--filter', name, '--parallel', '1',
            f'--timeout-each={case_seconds}s', '--no-color', '--no-progress'
        ]
        exit_code = run_logged(command, case_log, root, timeout=process_seconds)
        relative_log = case_log.relative_to(output_dir).as_posix()
        record['case_logs'].append(relative_log)
        with log.open('a') as combined:
            combined.write(f'\n===== {name} =====\n')
            combined.write(case_log.read_text(errors='replace'))
        try:
            observed = summary(case_log.read_text(errors='replace'))
            valid = (
                exit_code == 0 and observed['total'] == len(enumerated) and
                observed['passed'] == 1 and observed['skipped'] == len(enumerated) - 1 and
                observed['failed'] == 0 and observed['errors'] == 0
            )
        except ValueError:
            valid = False
        if not valid:
            record.update(
                exit_code=exit_code if exit_code != 0 else 1,
                total=len(cases), passed=passed,
                failed=1, errors=0, skipped=len(cases) - passed - 1,
                error=f'isolated unit-test case failed: {name}'
            )
            return record
        passed += 1
    record.update(
        exit_code=0, total=len(cases), passed=passed,
        failed=0, errors=0, skipped=0, status='PASS'
    )
    return record


def configure_http_fixture_environment(root):
    fixture = root.resolve() / 'support_tests/native_plugin_fixture'
    origin = fixture / 'http_stream_origin.py'
    peer = fixture / 'mcp_http_peer.py'
    if not origin.is_file():
        raise ValueError('native HTTP stream origin fixture is missing')
    if not peer.is_file():
        raise ValueError('real MCP HTTP Product peer fixture is missing')
    os.environ['AXYNDRA_MCP_HTTP_TEST_SERVER'] = str(peer)
    return {
        'http_stream_origin_sha256': hashlib.sha256(origin.read_bytes()).hexdigest(),
        'mcp_http_product_peer_sha256': hashlib.sha256(peer.read_bytes()).hexdigest(),
    }



def configure_service_fixture_environment(root):
    root = root.resolve()
    fixtures = {
        'main': root / 'support_tests/plugin_mcp_service_peer/main.py',
        'environment': root / 'support_tests/plugin_mcp_service_peer/environment.py',
        'host_network': root / 'support_tests/plugin_mcp_service_peer/host_network.py',
        'capacity': root / 'plugins/mcp/tests/capacity_server.py',
        'payload': root / 'plugins/mcp/tests/payload_server.py',
    }
    for name, path in fixtures.items():
        if not path.is_file():
            raise ValueError(f'real MCP service {name} fixture is missing')
    hashes = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in fixtures.values()}
    os.environ['AXYNDRA_MCP_TEST_SERVER'] = str(fixtures['main'])
    os.environ['AXYNDRA_MCP_CAPACITY_SERVER'] = str(fixtures['capacity'])
    os.environ['AXYNDRA_MCP_PAYLOAD_SERVER'] = str(fixtures['payload'])
    return {'mcp_service_fixture_sha256': hashes}


def configure_business_fixture_environment(root):
    root = root.resolve()
    fixtures = {
        'AXYNDRA_GITHUB_TEST_COMMAND': root / 'support_tests/plugin_github_service_peer/command.py',
        'AXYNDRA_READ_VIEW_PLUGIN_FIXTURE': root / 'support_tests/read_view_fixture/main.py',
        'AXYNDRA_DOCUMENT_PLUGIN_FIXTURE': root / 'support_tests/plugin_document_fixture/main.py',
        'AXYNDRA_DATA_ONLY_PLUGIN_FIXTURE': root / 'support_tests/plugin_data_only_fixture/main.py',
        'AXYNDRA_WORKFLOW_MIXED_FIXTURE': root / 'support_tests/plugin_document_fixture/mixed_provider.py',
    }
    for name, path in fixtures.items():
        if not path.is_file():
            raise ValueError(f'real Product {name} fixture is missing')
    hashes = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in fixtures.values()}
    for name, path in fixtures.items():
        os.environ[name] = str(path)
    return {'business_fixture_sha256': hashes}
def configure_language_fixture_environment(root):
    root = root.resolve()
    fixtures = {
        'AXYNDRA_LSP_TEST_SERVER': root / 'plugins/lsp/tests/lsp_peer.py',
        'AXYNDRA_DAP_TEST_SERVER': root / 'plugins/dap/tests/dap_peer.py',
        'AXYNDRA_DAP_OWNED_TEST_SERVER': root / 'plugins/dap/tests/dap_owned_peer.py',
    }
    for name, path in fixtures.items():
        if not path.is_file():
            raise ValueError(f'real language {name} fixture is missing')
    hashes = {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in fixtures.values()}
    for name, path in fixtures.items():
        os.environ[name] = str(path)
    return {'language_fixture_sha256': hashes}


def configure_installed_model_fixture_environment(root):
    origin = root.resolve() / 'plugins/model_providers/tests/origin.py'
    adapter_fixture = root.resolve() / 'plugins/model_providers/check.py'
    paths = [origin, adapter_fixture]
    if any(not path.is_file() for path in paths):
        raise ValueError('real installed model HTTP origin fixture is missing')
    os.environ['AXYNDRA_MODEL_PROVIDER_ORIGIN'] = str(origin)
    return {'installed_model_fixture_sha256': {
        path.relative_to(root.resolve()).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in paths}}


def configure_model_provider_fixture_environment(root):
    peer = root.resolve() / 'support_tests/model_provider_peer/main.py'
    if not peer.is_file():
        raise ValueError('real model provider process fixture is missing')
    os.environ['AXYNDRA_MODEL_PROVIDER_PEER'] = str(peer)
    return {'model_provider_peer_sha256': hashlib.sha256(peer.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path(os.environ.get('AXYNDRA_EVIDENCE_DIR', 'target/gate-evidence')) / 'unit-tests')
    parser.add_argument('--inventory-only', action='store_true')
    parser.add_argument('--package', help='execute only this inventoried package after validating the entire inventory')
    parser.add_argument('--case-prefix', help='literal suite-qualified prefix; requires --package agent_product')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    result = {'schema_version': 1, 'mode': 'inventory' if args.inventory_only else 'execute', 'status': 'FAIL', 'packages': [],
              'scope': {'requested': {'package': args.package, 'case_prefix': args.case_prefix}}}
    try:
        found = inventory(ROOT)
        result['inventory'] = found
        expected = json.loads((ROOT / 'scripts/product_unit_inventory.json').read_text())
        result['scope'] = requested_scope(found, expected, args.package, args.case_prefix, args.inventory_only)
        result['sources'] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for files in found.values() for p in files}
        if not args.inventory_only:
            read_view_exit = run_logged([
                sys.executable, str(ROOT / 'libs/process4cj/native/test_read_view_native.py'),
                '--source', str(ROOT / 'libs/process4cj/native/process4cj_native.c'),
                '--output', str(args.output_dir / 'read-view-native.json')
            ], args.output_dir / 'read-view-native.log', ROOT)
            if read_view_exit != 0:
                raise ValueError('real native read-view handle regression failed')
            fixture = ROOT / 'support_tests/native_plugin_fixture'
            fixture_exit = run_logged([sys.executable, str(fixture / 'check.py')],
                                      args.output_dir / 'native-plugin-fixture.log', ROOT)
            if fixture_exit != 0:
                raise ValueError('native plugin fixture failed to build or validate')
            os.environ['AXYNDRA_NATIVE_PLUGIN_FIXTURE'] = str(fixture / 'target/native-plugin')
            os.environ['AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE'] = str(fixture / 'target/tool/native-plugin-tool')
            os.environ['AXYNDRA_NATIVE_SERVICE_PLUGIN_FIXTURE'] = str(fixture / 'target/service/native-plugin-service')
            if not (fixture / 'http_origin.py').is_file():
                raise ValueError('native HTTP origin fixture is missing')
            result.update(configure_http_fixture_environment(ROOT))
            result.update(configure_service_fixture_environment(ROOT))
            result.update(configure_business_fixture_environment(ROOT))
            result.update(configure_model_provider_fixture_environment(ROOT))
            result.update(configure_language_fixture_environment(ROOT))
            result.update(configure_installed_model_fixture_environment(ROOT))
            result['plugin_fixtures'] = []
            for directory, command, environment_name in [
                ('ast', [sys.executable, str(ROOT / 'scripts/prepare_ast_plugin.py')], 'AXYNDRA_AST_PLUGIN_PACKAGE'),
                ('web_search', ['bash', str(ROOT / 'scripts/prepare_web_search_plugin.sh')], 'AXYNDRA_WEB_SEARCH_PLUGIN_PACKAGE'),
                ('mcp', [sys.executable, str(ROOT / 'scripts/prepare_mcp_plugin.py')], 'AXYNDRA_MCP_CLIENT_PLUGIN_PACKAGE'),
                ('github', [sys.executable, str(ROOT / 'scripts/prepare_github_plugin.py')], 'AXYNDRA_GITHUB_PLUGIN_PACKAGE'),
                ('workspace', [sys.executable, str(ROOT / 'scripts/prepare_workspace_plugin.py')], 'AXYNDRA_WORKSPACE_PLUGIN_PACKAGE'),
                ('program', [sys.executable, str(ROOT / 'scripts/prepare_program_plugin.py')], 'AXYNDRA_PROGRAM_PLUGIN_PACKAGE'),
                ('eval', [sys.executable, str(ROOT / 'scripts/prepare_eval_plugin.py')], 'AXYNDRA_EVAL_PLUGIN_PACKAGE'),
                ('shell', [sys.executable, str(ROOT / 'scripts/prepare_shell_plugin.py')], 'AXYNDRA_SHELL_PLUGIN_PACKAGE'),
                ('shell_readonly', [sys.executable, str(ROOT / 'scripts/prepare_shell_readonly_plugin.py')], 'AXYNDRA_SHELL_READONLY_PLUGIN_PACKAGE'),
                ('lsp', [sys.executable, str(ROOT / 'scripts/prepare_language_plugin.py'), '--plugin', 'lsp'], 'AXYNDRA_LSP_PLUGIN_PACKAGE'),
                ('dap', [sys.executable, str(ROOT / 'scripts/prepare_language_plugin.py'), '--plugin', 'dap'], 'AXYNDRA_DAP_PLUGIN_PACKAGE'),
                ('skills', [sys.executable, str(ROOT / 'scripts/prepare_skills_plugin.py')], 'AXYNDRA_SKILLS_PLUGIN_PACKAGE'),
                ('compaction', [sys.executable, str(ROOT / 'scripts/prepare_compaction_plugin.py')], 'AXYNDRA_COMPACTION_PLUGIN_PACKAGE'),
                ('memory', [sys.executable, str(ROOT / 'scripts/prepare_memory_plugin.py')], 'AXYNDRA_MEMORY_PLUGIN_PACKAGE'),
                ('workflow', [sys.executable, str(ROOT / 'scripts/prepare_workflow_plugin.py')], 'AXYNDRA_WORKFLOW_PLUGIN_PACKAGE'),
                ('model_providers', ['bash', str(ROOT / 'scripts/prepare_model_provider_plugin.sh')], 'AXYNDRA_MODEL_PROVIDER_PLUGIN_PACKAGE'),
            ]:
                result['plugin_fixtures'].append(prepare_bundled_plugin(
                    ROOT, args.output_dir, directory, command, environment_name
                ))
                (args.output_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
            for member in result['scope']['selected_packages']:
                log = args.output_dir / (member.replace('/', '__') + '.log')
                print(f'unit tests: {member}', flush=True)
                if member == 'agent_product':
                    # Process-backed host lifecycle cases must not share a test process:
                    # a crashed or force-killed child can retain runner-owned resources
                    # until that process exits, contaminating the following case.
                    record = run_isolated_agent_product(ROOT, args.output_dir, log, args.case_prefix)
                    if 'scope' in record:
                        result['scope']['enumerated_cases'][member] = record['scope']['enumerated']
                        result['scope']['selected_cases'][member] = record['scope']['selected']
                elif member == 'agent_rpc':
                    from rpc_unit_isolation import run_isolated_agent_rpc
                    record = run_isolated_agent_rpc(ROOT, args.output_dir, log)
                    if 'scope' in record:
                        result['scope']['enumerated_cases'][member] = record['scope']['enumerated']
                        result['scope']['selected_cases'][member] = record['scope']['selected']
                else:
                    command = [str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test', '-m', member, '--no-color']
                    record = {'member': member, 'command': command, 'log': log.name}
                    record['exit_code'] = run_logged(command, log, ROOT)
                    try:
                        record.update(summary(log.read_text(errors='replace')))
                        record['status'] = 'PASS' if record['exit_code'] == 0 and record['failed'] == 0 and record['errors'] == 0 and record['skipped'] == 0 else 'FAIL'
                    except ValueError as error:
                        record.update(status='FAIL', error=str(error))
                result['packages'].append(record)
                (args.output_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
                print(f"{member}: {record['status']}", flush=True)
        result['status'] = 'PASS' if all(p['status'] == 'PASS' for p in result['packages']) else 'FAIL'
    except (OSError, ValueError, KeyError) as error:
        result['error'] = str(error)
    (args.output_dir / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['status'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
