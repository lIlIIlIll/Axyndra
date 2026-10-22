#!/usr/bin/env python3
"""Real App/plugin public-wire PTY acceptance, not the unrelated editor matrix.

Retains CaseRun's exact key bytes, ANSI output, screens, requests and exit status.
Packages must be independently built; importing never fabricates Registry state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

import check as harness
from workflow_family_fixture196 import _run196, _records196


def install(case, package):
    manifest = json.loads((package / 'axyndra.plugin.json').read_bytes())
    namespace = "axyndra:" + manifest["id"]
    case.record('package_observed', files={p.relative_to(package).as_posix(): harness.sha256_file(p)
        for p in sorted(package.rglob('*')) if p.is_file()})
    _run196(case, manifest['id'] + '-import', ['import', str(package), '--scope', 'user'])
    records = _records196(case, manifest['id'] + '-installed')
    selected = [r for r in records if r['namespace'] == namespace]
    case.assertions.check('actual_import_' + manifest['id'], len(selected) == 1 and not selected[0]['enabled'],
                          'fresh public import returns exactly one disabled package')
    return selected[0]


def configure(case, package, port, protocol, timeout):
    case.write_provider_config(port, protocol)
    # Existing catalog is display metadata; only the installed mapping dispatches.
    profile = case.home / 'providers.yml'
    dialect = {'responses': 'openai_responses', 'completions': 'openai_chat', 'messages': 'anthropic_messages'}[protocol]
    profile.write_text('providers:\n  - id: coverage\n    provider: fixture\n'
        f'    protocol: {protocol}\n    dialect: {dialect}\n    base_url: http://127.0.0.1:{port}\n'
        '    api_key_env: AXYNDRA_TUI_COVERAGE_KEY\n    allow_insecure_http: true\n    timeout_millis: 8000\n')
    model = case.home / 'models.yml'
    model.write_text(model.read_text().replace('generic_messages', 'anthropic_messages'))
    record = install(case, package)
    # Execute the exact packaged review-only converter, then explicitly apply
    # its nonsecret proposal as the fixture operator; no provider fallback.
    selection = {'namespace': record['namespace'], 'package_digest': record['content_digest'],
        'package_version': record['version'], 'providers': {'coverage': {
        'credential_source': {'file': 'coverage.key'}, 'private_addresses': ['127.0.0.1']}}}
    harness.json_dump(case.case_dir / 'selection.json', selection)
    import subprocess
    result = subprocess.run([sys.executable, str(package / 'tools/migrate_configuration.py'),
        '--providers', str(profile), '--models', str(model), '--selection', str(case.case_dir / 'selection.json')],
        capture_output=True, timeout=case.timeout, env=case.environment)
    (case.case_dir / 'conversion.stdout.json').write_bytes(result.stdout)
    (case.case_dir / 'conversion.stderr').write_bytes(result.stderr)
    case.assertions.check('packaged_converter', result.returncode == 0, result.stderr.decode(errors='replace'))
    entry = json.loads(result.stdout)['plugin_entry']
    entry['configuration']['model_providers'][0]['configuration']['timeout_ms'] = timeout
    (case.home / 'credentials/coverage.key').write_text(case.environment['AXYNDRA_TUI_COVERAGE_KEY'])
    harness.json_dump(case.home / 'plugins/services.json', {'version': 1, 'plugins': [entry]})
    _run196(case, 'model-enable', ['enable', record['namespace'], '--scope', 'user'])
    return entry


def execute(case, name, protocol, package, mcp_package):
    recovery = {'kind': 'text', 'chunks': ['next-request-succeeded'], 'event_delay': .03}
    first = {'kind': 'text', 'chunks': ['visible-one ', 'visible-two ', 'visible-three'],
        'reasoning': 'visible-reasoning', 'event_delay': .15, 'wire_chunk_size': 5, 'line_ending': '\r\n'}
    if name.startswith("rich-"):
        first["gate_after_contains"] = {"visible-one ": str(case.case_dir / "release-after-visible-chunk")}
    timeout = 8000
    if name in ('cancel', 'ctrl-c'):
        first = {'kind': 'text', 'chunks': ['cancel-partial', 'cancel-late'],
            'gates': {'3': str(case.case_dir / 'release-after-cancel')}, 'event_delay': .03}
    elif name == 'http-error':
        first = {'error': {'status': 400, 'body': 'deterministic-provider-error'}}
    elif name == 'timeout':
        timeout = 500
        first = {'kind': 'text', 'chunks': ['timeout-late'], 'event_delay': 1.0}
    elif name in ('incomplete-eof', 'invalid-utf8'):
        first = {'kind': 'text', 'chunks': ['incomplete-text'], name.replace('-', '_'): True}
    tool = None
    if name == "mcp-tool":
        tool = "plugin.axyndra:mcp-client.service.session.t_" + hashlib.sha256(b"environment").hexdigest()
        # Native ModelToolNames projects nonportable canonical names bijectively
        # into their exact advertised SHA-256 wire name; replies must use it.
        first = {"kind": "tool", "tool_name": hashlib.sha256(tool.encode()).hexdigest(), "tool_arguments": {}}
    behavior = {"responses": [first, recovery], "case_id": name}
    if not name.startswith("rich-") and not tool:
        behavior = dict(first, case_id=name, rules=[dict(recovery, contains=["after-terminal"],
            invalid_utf8=False, incomplete_eof=False, error=None, gates={})])
    port = case.start_provider(behavior)
    entry = configure(case, package, port, protocol, timeout)
    if name == 'mcp-tool':
        record = install(case, mcp_package)
        mcp_port = case.start_mcp_http({})
        url = f'http://127.0.0.1:{mcp_port}/mcp'
        service = {'namespace': record['namespace'], 'package_digest': record['content_digest'],
            'configuration': {'version': 1, 'transport': 'http', 'request_timeout_ms': 3000,
                'directory': {'max_pages': 8, 'max_tools': 64}, 'http': {'url': url,
                'credential_refs': [], 'max_response_bytes': 65536, 'prefer_sse': False,
                'origin': '', 'headers': {}}},
            'requests': [{'url': url, 'methods': ['POST'], 'private_addresses': ['127.0.0.1'], 'credential_refs': []}],
            'credentials': [], 'read_only_tools': ['environment']}
        harness.json_dump(case.home / 'plugins/services.json', {'version': 1, 'plugins': [entry, service]})
        _run196(case, 'mcp-enable', ['enable', record['namespace'], '--scope', 'user'])
    # Streaming policy intentionally disables provider hard-timeouts; exercise
    # the supported public Run wall deadline, without extending harness bounds.
    case.launch(extra_args=["--max-time", "3"] if name == "timeout" else None)
    case.wait_screen(('Enter send',), 'initialized')
    if tool:
        case.send("actual-mcp-start", b"/plugins service start axyndra:mcp-client session session --approve\r")
        case.wait_screen(("Service started in this live session",), "mcp-started")
        case.send("mcp-runtime-service-inventory", b"/plugins service list\r")
        case.wait_screen(("Session services:",), "mcp-directory")
    case.send('actual-model-request', b'acceptance-request\r')
    if name.startswith('rich-'):
        partial = harness.strip_ansi(case.wait_screen(('visible-one',), 'delayed-first-chunk'))
        case.assertions.check("partial_stream_visible", "visible-three" not in partial and "Working" in partial,
            "the real TUI displays partial text while the public SSE stream is still gated")
        (case.case_dir / "release-after-visible-chunk").touch()
        frame = harness.strip_ansi(case.wait_screen(('visible-three', 'tokens 7 in / 5 out'), 'completed'))
        case.assertions.check('reasoning_visible', 'visible-reasoning' in frame, 'reasoning reaches the actual consumer')
        case.assertions.check('ordered_text', 'visible-one visible-two visible-three' in frame.replace('\n', ' '), 'ordered delayed chunks')
        case.assertions.check('split_wire', any(r.get('wire_chunk_size') == 5 for r in harness.read_jsonl(case.stream_path)), 'real SSE byte splits')
    elif name in ('cancel', 'ctrl-c'):
        case.wait_screen(('cancel-partial',), 'partial')
        case.send('cancel-key', b'\x03' if name == 'ctrl-c' else b'\x1b')
        time.sleep(.5)
        (case.case_dir / 'release-after-cancel').touch()
        frame = harness.strip_ansi(case.wait_screen(('Enter send',), 'cancelled-ready', timeout=8))
        case.assertions.check("cancel_visible", "run.cancelled" in frame, "visible cancellation terminal")
    elif tool:
        frame = harness.strip_ansi(case.wait_screen(('next-request-succeeded', 'tokens 7 in / 5 out', 'Enter send'), 'mcp-tool-completed'))
        case.assertions.check('actual_mcp_call', any(r.get('method') == 'tools/call' for r in harness.read_jsonl(case.mcp_path)), 'public MCP exchange')
        case.wait_requests(2)
        case.assertions.check("tool_call_visible", "plugin.axyndra:mcp-client.service.session" in frame,
            "the completed actual MCP tool call reaches a visible consumer card")
        requests = harness.read_jsonl(case.requests_path)
        case.assertions.check("actual_tool_alias_advertised", hashlib.sha256(tool.encode()).hexdigest() in json.dumps(requests[0]),
            "the fixture calls the exact wire Tool alias published by the actual native provider")
        case.assertions.check("actual_tool_result_returned_to_model", "fixture MCP result" in json.dumps(requests[-1]),
            "the subsequent actual provider request contains the native MCP tool result")
    else:
        failure = harness.strip_ansi(case.wait_screen(('Error',), 'visible-failure'))
        if name == "timeout":
            case.assertions.check("wall_timeout_visible", "model.wall_timeout" in failure,
                "the configured public Run wall deadline reaches a visible terminal")
    case.wait_screen(('Enter send',), 'ready-after-terminal', timeout=8)
    if not name.startswith('rich-') and not tool:
        case.send('next-actual-request', b'after-terminal\r')
        case.wait_screen(('next-request-succeeded', 'tokens 7 in / 5 out', 'Enter send'), 'recovery')
        case.wait_requests(2)
        requests = harness.read_jsonl(case.requests_path)
        case.assertions.check("next_request_reached_provider", "after-terminal" in json.dumps(requests[-1]),
            "the recovery result comes from the subsequent actual request")
        if name in ("cancel", "ctrl-c"):
            case.assertions.check("cancelled_late_text_absent", "cancel-late" not in harness.strip_ansi(case.capture("after-recovery")),
                "cancelled stream does not replay into the subsequent response")
    case.normal_exit()
    attempts = harness.model_attempt_rows(case)
    harness.json_dump(case.case_dir / "model-attempts.json", attempts)
    case.assertions.check("last_actual_request_completed", bool(attempts) and attempts[-1]["lifecycle"] == "completed"
        and attempts[-1]["failure_kind"] == "", "the final actual provider request completes durably, not just provisional text")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--model-package', type=Path, required=True)
    parser.add_argument('--mcp-package', type=Path, required=True)
    parser.add_argument("--native-library", type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    import shutil
    candidate = args.output / "candidate" / "agent_app"
    candidate.parent.mkdir()
    source_hash = harness.sha256_file(args.candidate)
    shutil.copy2(args.candidate, candidate)
    if not (harness.sha256_file(candidate) == source_hash == harness.sha256_file(args.candidate)):
        raise RuntimeError("candidate changed while freezing its executable bytes")
    native = None
    native_hash = None
    if args.native_library:
        native = args.output / "native" / args.native_library.name
        native.parent.mkdir()
        native_hash = harness.sha256_file(args.native_library)
        shutil.copy2(args.native_library, native)
        if not (harness.sha256_file(native) == native_hash == harness.sha256_file(args.native_library)):
            raise RuntimeError("native dependency changed while freezing its bytes")
    import os
    os.environ.setdefault("AXYNDRA_TUI_TMUX_TMPDIR", str(args.output.parent / "t"))
    names = args.case or ['rich-responses', 'rich-completions', 'rich-messages', 'cancel', 'ctrl-c',
                           'http-error', 'timeout', 'incomplete-eof', 'invalid-utf8', 'mcp-tool']
    results = []
    harness.json_dump(args.output / 'provenance.json', {'binary_sha256': source_hash,
        "native_library_sha256": native_hash,
        'sources': {p.name: harness.sha256_file(p) for p in (Path(__file__), harness.FIXTURE_PATH, Path(harness.__file__))},
        'limits': ['Linux tmux PTY only', 'Mouse and resize not exercised', 'No other platform acceptance'], 'cases': names})
    for name in names:
        case = harness.CaseRun({'case_id': name, 'variant': {'execution': 'plugin-acceptance'}},
                               candidate.resolve(), args.output / 'cases' / name)
        if native:
            case.environment["LD_LIBRARY_PATH"] = str(native.parent.resolve()) + ":" + case.environment["LD_LIBRARY_PATH"]
            case.tmux_environment["LD_LIBRARY_PATH"] = case.environment["LD_LIBRARY_PATH"]
            case.record("frozen_native_dependency", filename=native.name, sha256=native_hash)
        result = {'case': name, 'status': 'failed'}
        try:
            execute(case, name, name.removeprefix('rich-') if name.startswith('rich-') else 'responses',
                    args.model_package.resolve(), args.mcp_package.resolve())
            result['status'] = 'passed'
        except Exception as error:
            result['error'] = f'{type(error).__name__}: {error}'
        finally:
            case.stop()
            case.assertions.save(result['status'])
            harness.json_dump(case.case_dir / 'result.json', result)
        results.append(result)
        print(json.dumps(result), flush=True)
    harness.json_dump(args.output / 'results.json', results)
    return int(any(r['status'] != 'passed' for r in results))


if __name__ == '__main__':
    raise SystemExit(main())
