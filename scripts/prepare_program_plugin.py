#!/usr/bin/env python3
"""Prepare a fresh independently built Program package for actual Product tests."""
from product_unit_gate import has_compiler_error
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_CASES = 28
ORIGINAL_CASE_NAMES = ['test_literal_has_no_host_io', 'test_actual_compiler_and_interpreter_use_typed_readonly_service', 'test_two_calls_have_distinct_receipt_correlation', 'test_missing_receipt_cannot_publish_success', 'test_wrong_identity_is_fatal_without_terminal', 'test_cancel_matches_actual_pending_invocation', 'test_forbidden_syntax_never_creates_service_request', 'test_duplicate_invocation_is_not_replayed', 'test_logical_raw_256k_source_reaches_actual_compiler', 'test_json_escaped_256k_source_is_bounded_and_not_a_prepare_frame', 'test_source_over_raw_256k_is_rejected_before_service_io', 'test_large_service_response_and_terminal_share_actual_value', 'test_two_large_responses_retain_values_until_interpretation_ends', 'test_original_tree_cost_boundary_remains_one_mib', 'test_large_input_bound_is_host_selected_and_not_self_expanded', 'test_logical_wrong_window_poison_cannot_publish_result', 'test_cancel_during_large_service_payload_has_no_success', 'test_logical_input_without_host_offer_is_rejected', 'test_large_missing_receipt_still_cannot_publish_success']
ADDITIONAL_CASE_NAMES = ['test_actual_static_literal_crosses_physical_request_frame_with_original_identity', 'test_original_default_small_request_preserves_exact_raw_shape', 'test_near_raw_256k_application_plan_literal_uses_bounded_request_and_same_identity', 'test_preview_missing_receipt_or_wrong_service_never_publishes_success', 'test_host_refusal_is_preserved_without_a_preview_success', 'test_matching_complete_utf8_attachment_maps_business_without_service_or_budget', 'test_absent_attachment_keeps_original_output_shape_and_zero_calls', 'test_changed_content_identity_profile_and_spoofed_shape_are_terminal_refusals', 'test_tool_error_keeps_full_source_mapping_and_actual_subcall_count']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(package):
    return {path.relative_to(package).as_posix(): digest(path)
            for path in sorted(package.rglob('*')) if path.is_file()}


def run(command, log, timeout, environment=None):
    with log.open('w') as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            code = 124
    text = log.read_text(errors='replace')
    sys.stderr.write(text)
    if code != 0:
        raise ValueError(f'fixture command failed ({code}); see {log}')
    return text


def require_result_consumer_dependency(root):
    # The old in-process MCP adapter returns SDK DTOs without transferring or
    # closing a ToolResult allocation lease. Never activate the new profile
    # in a source graph which still contains that consumer.
    retired = ['agent_product/src/product_mcp_server.cj', 'agent_product/src/mcp_runtime.cj',
               'agent_app/src/mcp_server_cli.cj']
    present = [name for name in retired if (root / name).exists()]
    if present:
        raise ValueError('MCP host-removal69 dependency is missing: ' + ', '.join(present))


def prepare(output=None):
    require_result_consumer_dependency(ROOT)
    if sys.platform != 'linux':
        raise ValueError('the independently packaged Program fixture requires Linux')
    plugin = ROOT / 'plugins/program'
    if output is None:
        artifacts = ROOT / 'target/plugin-contract-fixtures'
        artifacts.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='program-plugin-', dir=artifacts)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('fixture output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = {'status': 'FAIL', 'package': str(package), 'expected_cases': EXPECTED_CASES,
              'scope': 'Packaged native Program compiler/interpreter and typed readonly service wire; actual Store/Run authority is verified by Product tests.'}
    try:
        source = ast.parse((plugin / 'check.py').read_text())
        cases = [node.name for node in ast.walk(source)
                 if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if len(cases) != EXPECTED_CASES or len(set(cases)) != EXPECTED_CASES:
            raise ValueError('review the independent Program protocol test inventory')
        if set(cases) != set(ORIGINAL_CASE_NAMES + ADDITIONAL_CASE_NAMES):
            raise ValueError('Program protocol original19 plus service-request2 plus preview-transport3 plus input-attachment4 names differ')
        record['original_case_names'] = ORIGINAL_CASE_NAMES
        record['additional_case_names'] = ADDITIONAL_CASE_NAMES
        record['cases'] = cases
        text = run(['bash', str(plugin / 'build-package.sh'), '--output', str(package)],
                   evidence / 'build.log', 900)
        if 'cjpm build success' not in text or has_compiler_error(text):
            raise ValueError('actual compiler success is missing')
        manifest = json.loads((package / 'axyndra.plugin.json').read_text())
        if manifest != json.loads((plugin / 'axyndra.plugin.json').read_text()):
            raise ValueError('packaged manifest differs from source')
        entry = (package / manifest['entrypoint']).resolve(strict=True)
        if not entry.is_relative_to(package) or not entry.is_file():
            raise ValueError('packaged entrypoint escapes its directory')
        provenance = json.loads((package / 'package-provenance.json').read_text())
        if provenance['plugin_sha256'] != digest(entry):
            raise ValueError('packaged binary hash differs from provenance')
        for directory, field in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256')]:
            actual = {path.name: digest(path) for path in sorted((package / directory).iterdir()) if path.is_file()}
            if actual != provenance[field]:
                raise ValueError(f'packaged {directory} differs from provenance')
        if provenance['language_source_sha256'] != digest(plugin / 'language/src/program.cj') or                 provenance['native_source_sha256'] != digest(plugin / 'src/main.cj'):
            raise ValueError('packaged algorithms differ from the actual source graph')
        if provenance['native_sources_sha256'] != {p.relative_to(plugin).as_posix(): digest(p) for p in sorted((plugin / 'src').rglob('*.cj'))}:
            raise ValueError('packaged native payload source provenance differs')
        before = files(package)
        environment = dict(os.environ)
        for name in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            environment.pop(name, None)
        record['loader_environment_removed'] = True
        text = run([sys.executable, str(plugin / 'check.py'), '--package', str(package)],
                   evidence / 'protocol.log', 240, environment)
        observed = re.findall(r'^test_\w+ .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        observed_names = re.findall(r'^(' + r'test_\w+' + r') .*? \.\.\. ok$', text, re.M)
        if len(observed_names) != EXPECTED_CASES or len(set(observed_names)) != EXPECTED_CASES or set(observed_names) != set(cases):
            raise ValueError('Program protocol witnesses differ from every original19 and service-request2 and preview-transport3 and input-attachment4 source case')
        if len(observed) != EXPECTED_CASES or any(item != 'ok' for item in observed) or \
                not re.search(rf'^Ran {EXPECTED_CASES} tests in [0-9.]+s$', text, re.M) or not re.search(r'^OK$', text, re.M) or \
                'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('Program protocol fixture must execute every case without failure or skip')
        if before != files(package):
            raise ValueError('package changed during protocol verification')
        record.update(status='PASS', protocol_counts={'total': EXPECTED_CASES, 'passed': EXPECTED_CASES,
                      'failed': 0, 'errors': 0, 'skipped': 0}, package_files=before,
                      entrypoint_sha256=digest(entry), package_provenance=provenance)
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n')
    return package


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='new package directory; default is under target/plugin-contract-fixtures')
    arguments = parser.parse_args()
    try:
        print(prepare(arguments.output))
    except (OSError, ValueError, KeyError) as error:
        print(f'Program fixture preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)
