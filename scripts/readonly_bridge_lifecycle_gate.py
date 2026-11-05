#!/usr/bin/env python3
"""Run every actual readonly bridge lifecycle case in an independent process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

from rpc_case_process_watch import run_host_case

ROOT = Path(__file__).resolve().parents[1]
KINDS = ('pi', 'native', 'direct-pi', 'direct-native')
SCENARIOS = ('disabled', 'configuration', 'cancel-before', 'cancel-handoff', 'disable-handoff', 'restart')
CASES = tuple((kind + '-' + scenario, '--' + kind + '-broker-' + scenario + '-contract',
               'actual ' + kind + ' broker ' + scenario + ' contract passed')
              for kind in KINDS for scenario in SCENARIOS
              if scenario != 'cancel-before' or kind.startswith('direct-')) + (
    ('original-direct-native', '--direct-native-service-broker-contract', 'actual Native service broker contract passed'),
    ('original-four-roots', '--javascript-service-broker-contract', 'plugin service broker contract passed'),
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True, help='current compiled product_thread_runtime_contract executable')
    parser.add_argument('--output-dir', type=Path, required=True, help='new evidence directory')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    summary = dict(schema_version=1, gate='readonly-bridge-lifecycle', status='FAIL', cases=[],
                   scope='22 actual lifecycle cases and both original compound entries; physical exit is not DATA ACK')
    try:
        binary = args.binary.resolve(strict=True)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError('actual compiled contract binary is required')
        source_paths = ['support_tests/product_thread_runtime_contract/src/main.cj',
                        'support_tests/product_thread_runtime_contract/src/service_broker_lifecycle.cj',
                        'support_tests/shell_readonly_native_contract/src/fixture.cj',
                        'support_tests/native_plugin_fixture/main.c']
        summary['source_sha256'] = {name: digest(ROOT / name) for name in source_paths}
        summary['binary_sha256'] = digest(binary)
        fixtures = {}
        native = Path(os.environ['AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE']).resolve(strict=True)
        fixtures['native_tool_sha256'] = digest(native)
        package = Path(os.environ['AXYNDRA_SHELL_READONLY_PLUGIN_PACKAGE']).resolve(strict=True)
        manifest = json.loads((package / 'axyndra.plugin.json').read_text())
        entry = (package / manifest['entrypoint']).resolve(strict=True)
        if not entry.is_relative_to(package):
            raise ValueError('readonly fixture entrypoint escapes its real package')
        fixtures['readonly_plugin_sha256'] = digest(entry)
        summary['fixtures'] = fixtures
        for name, flag, marker in CASES:
            log = args.output_dir / (name + '.log')
            command = [str(ROOT / 'scripts/pinned_cangjie'), str(binary), flag]
            process = run_host_case(command, log, 180, cwd=ROOT)
            text = log.read_text(errors='replace')
            status = 'PASS' if process['exit_code'] == 0 and marker in text.splitlines() else 'FAIL'
            summary['cases'].append(dict(name=name, command=command, log=log.name,
                                         status=status, process=process))
            (args.output_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(name + ': ' + status, flush=True)
        summary['status'] = 'PASS' if len(summary['cases']) == 24 and all(
            row['status'] == 'PASS' for row in summary['cases']) else 'FAIL'
    except (OSError, KeyError, ValueError) as error:
        summary['error'] = str(error)
    finally:
        (args.output_dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return int(summary['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
