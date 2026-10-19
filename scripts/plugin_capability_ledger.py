#!/usr/bin/env python3
"""Generate the machine-checkable plugin capability ledger (issue #48 T0-01).

Reports, from the repository itself, which capabilities have a plugin package
and which still live in the host. No claim of acceptance is made: this is an
ownership and packaging inventory.

Run: python3 scripts/plugin_capability_ledger.py [--json]
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

# Capability id -> plugin package directories that own it, per issue #48 §3.
# An empty tuple means the capability has no plugin package in this tree.
CAPABILITIES = {
    'F01': ('plugins/mcp', 'plugins/mcp_server'),
    'F02': ('plugins/workspace',),
    'F03': ('plugins/shell', 'plugins/shell_readonly'),
    'F04': ('plugins/ast',),
    'F05': ('plugins/web_search',),
    'F06': ('plugins/github',),
    'F07': ('plugins/lsp',),
    'F08': ('plugins/dap',),
    'F09': ('plugins/eval', 'plugins/program'),
    'F10': ('plugins/program',),
    'F11': ('plugins/skills',),
    'F12': ('plugins/memory',),
    'F13': ('plugins/compaction',),
    'F14': ('plugins/workflow',),
    'F15': (),
    'F16': ('plugins/model_providers',),
    'F17': (),
    'F18': (),
    'F19': (),
    'F20': (),
    'F21': (),
    'F22': (),
}

# Shared general-purpose libraries the host may depend on (issue #48 §4.6).
ALLOWED_HOST_LIBRARIES = {
    'logical_json_payload', 'agent_host_runtime', 'agent_plugin_registry',
    'agent_history', 'model_provider_runtime', 'model_fixture_runtime',
    'agent_cli', 'agent_app_protocol', 'agent_client', 'agent_core',
    'agent_domain', 'agent_runtime', 'agent_store', 'agent_extension_runtime',
    'agent_embed', 'agent_sdk', 'tool_runtime', 'persistence_runtime',
    'agent_rpc', 'agent_tui', 'axyndra_agent_testkit', 'agent_minimal',
}


def package_tests(directory):
    """Contract cases are counted from BOTH suites a package may own.

    A plugin either carries Cangjie unit tests (`src/*_test.cj`) or a
    black-box Python harness (`check.py`), and several carry the latter
    exclusively. Counting only the Cangjie form reports false gaps, so both
    are reported and neither is treated as absence of coverage.
    """
    source = ROOT / directory / 'src'
    cangjie = len(list(source.glob('*_test.cj'))) if source.is_dir() else 0
    harness = 1 if (ROOT / directory / 'check.py').is_file() else 0
    return cangjie, harness


def plugin_directories():
    return sorted(p.name for p in (ROOT / 'plugins').iterdir()
                  if p.is_dir() and (p / 'cjpm.toml').is_file())


def declared_input_bound(directory):
    """Whether a plugin package consumes the host's bounded-payload channel.

    Issue #48 requires a typed, negotiable and BOUNDED contribution and
    invocation protocol, so a package that can receive a caller-sized argument
    should declare or enforce a limit. This reports the DECLARATION only: a
    package may declare limits and still have none enforced on a particular
    route, so this is not an enforcement proof.
    """
    source = ROOT / 'plugins' / directory / 'src'
    if not source.is_dir():
        return False
    needles = ('ordinaryToolPayloadLimitsFromValue', 'OrdinaryToolPayloadLimits',
               'tool_payload_limits', 'maxInputBytes')
    for path in source.glob('*.cj'):
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        if any(needle in text for needle in needles):
            return True
    return False


def product_business_dependencies():
    """Business plugin packages statically linked into the host, if any."""
    manifest = ROOT / 'agent_product' / 'cjpm.toml'
    if not manifest.is_file():
        return []
    text = manifest.read_text(encoding='utf-8')
    declared = set(re.findall(r'"([A-Za-z0-9_\-]+)"\s*=\s*\{\s*path\s*=', text))
    linked = []
    for directory in plugin_directories():
        stem = directory.replace('_', '-')
        for name in declared:
            normalized = name.replace('_', '-')
            if normalized == stem or normalized.startswith(stem + '-'):
                linked.append(name)
    return sorted(set(linked))


def distribution_profiles():
    path = ROOT / 'packaging' / 'distributions.json'
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding='utf-8'))
    return {name: len(profile.get('bundled', []))
            for name, profile in data.get('profiles', {}).items()}


def build_report():
    entries = []
    for capability in sorted(CAPABILITIES):
        packages = CAPABILITIES[capability]
        present = [p for p in packages if (ROOT / p / 'cjpm.toml').is_file()]
        entries.append({
            'id': capability,
            'packages': list(packages),
            'externalized': bool(present) and len(present) == len(packages),
            'cj_tests': sum(package_tests(p)[0] for p in present),
            'py_harness': sum(package_tests(p)[1] for p in present),
        })
    return {
        'schema': 'axyndra.plugin-capability-ledger/v1',
        'capabilities': entries,
        'plugin_packages': plugin_directories(),
        'host_business_dependencies': product_business_dependencies(),
        'allowed_host_libraries': sorted(ALLOWED_HOST_LIBRARIES),
        'distribution_profiles': distribution_profiles(),
        'host_only': [e['id'] for e in entries if not e['externalized']],
        'plugin_packages_without_declared_input_bound': [
            d for d in plugin_directories() if not declared_input_bound(d)],
        'externalized_without_tests': [e['id'] for e in entries if e['externalized']
                                       and e['cj_tests'] == 0 and e['py_harness'] == 0],
    }


REQUIRED_EXTERNALIZED = (
    'F01', 'F02', 'F03', 'F04', 'F05', 'F06', 'F07', 'F08', 'F09', 'F10',
    'F11', 'F12', 'F13', 'F14', 'F16',
)


def check(report):
    """Gate: no capability may regress and the host may not link a business plugin."""
    failures = []
    by_id = {e['id']: e for e in report['capabilities']}
    for capability in REQUIRED_EXTERNALIZED:
        entry = by_id.get(capability)
        if entry is None or not entry['externalized']:
            failures.append(f"{capability} is no longer externalized")
    for name in report['host_business_dependencies']:
        failures.append(
            f"host links business plugin dependency '{name}'")
    for capability in report['externalized_without_tests']:
        failures.append(f"{capability} is externalized without any suite")
    for failure in failures:
        print(f"capability ledger: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"capability ledger passed ({len(REQUIRED_EXTERNALIZED)} "
          f"externalized, 0 host business dependencies)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true',
                        help='emit the ledger as JSON')
    parser.add_argument('--check', action='store_true',
                        help='fail if a capability regresses or the host gains a '
                             'business plugin dependency')
    arguments = parser.parse_args()
    report = build_report()
    if arguments.check:
        return check(report)
    if arguments.json:
        print(json.dumps(report, indent=2))
        return 0
    for entry in report['capabilities']:
        mark = 'plugin' if entry['externalized'] else 'HOST  '
        print(f"{mark} {entry['id']}  cj={entry['cj_tests']:<3} "
              f"harness={entry['py_harness']}  "
              f"{', '.join(entry['packages']) or '-'}")
    linked = report['host_business_dependencies']
    print(f"\nhost business plugin dependencies: {linked or 'none'}")
    print(f"externalized without tests: "
          f"{report['externalized_without_tests'] or 'none'}")
    unbounded = report['plugin_packages_without_declared_input_bound']
    print(f"plugin packages without a declared input bound: "
          f"{len(unbounded)} of {len(report['plugin_packages'])}"
          f" ({', '.join(unbounded) or 'none'})")
    print(f"host only: {report['host_only'] or 'none'}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
