#!/usr/bin/env python3
"""Exercise the read-only converter and optional real independent worker clones.

Native hello checks prove immutable package identity, not canonical host authority.
Use --package for a built bundle; --baseline-package preserves the pre-fix failure.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
PACKAGE = BASELINE = None
EVIDENCE = []


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(script, *arguments, environment=None):
    result = subprocess.run([sys.executable, str(ROOT / script), *map(str, arguments)],
                            env=environment, capture_output=True, timeout=60)
    EVIDENCE.append({'program': script, 'arguments': list(map(str, arguments)),
                     'exit': result.returncode, 'stdout': result.stdout.decode('utf-8', errors='replace'),
                     'stderr': result.stderr.decode('utf-8', errors='replace')})
    return result


class MigrationCLI(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mcp-migration-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / 'mcp.yml'

    def convert(self, raw, *, environment=None):
        self.source.write_bytes(raw)
        before = sha(self.source)
        result = invoke('migrate_legacy.py', self.source, environment=environment)
        self.assertEqual(sha(self.source), before)
        self.assertEqual(result.returncode, 0, result.stderr)
        draft = json.loads(result.stdout)
        self.assertEqual(base64.b64decode(draft['source']['bytes_base64']), raw)
        self.assertEqual(draft['source']['sha256'], before)
        self.assertEqual(draft['activation'], 'none')
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), ['mcp.yml'])
        return draft

    def test_missing_source_is_empty_without_creation(self):
        result = invoke('migrate_legacy.py', self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        draft = json.loads(result.stdout)
        self.assertFalse(draft['source']['present'])
        self.assertEqual(draft['servers'], [])
        self.assertFalse(self.source.exists())

    def test_empty_explicit_block(self):
        self.assertEqual(self.convert(b'# inert\nversion: 1\nservers:\n')['servers'], [])

    def test_old_defaults_are_not_clamped(self):
        entry = self.convert(b'version: 1\nservers:\n  - id: Echo\n    enabled: true\n    transport: stdio\n    command: /usr/bin/example-mcp\n')['servers'][0]
        self.assertTrue(entry['previously_enabled'])
        self.assertEqual(entry['configuration']['request_timeout_ms'], 30000)
        self.assertEqual(entry['configuration']['framing'], {'max_frame_bytes':8388608, 'graceful_shutdown_ms':3000})
        self.assertEqual(entry['protocol_limits']['call_timeout_ms'], 30000)
        self.assertEqual(entry['payload_limits']['max_result_bytes'], 8388608)
        self.assertEqual(entry['endpoint_request']['lifecycle_policy'], {'schema':'axyndra.process-shutdown/v1', 'grace_ms':3000})
        self.assertNotIn('grants', entry)
        self.assertNotIn('package_digest', entry)

    def test_all_stdio_fields_quotes_and_symbolic_sources(self):
        raw = '''version: 1
servers:
  - id: Echo_2
    enabled: FALSE
    transport: stdio
    command: '/usr/bin/example-mcp'
    cwd: 'relative workspace'
    network: host
    max_frame_bytes: +524288
    request_timeout_ms: 45000
    graceful_shutdown_ms: 7000
    args:
      - '--name'
      - "two words # literal"
      - 'single # literal' # removed comment
    env:
      EXAMPLE_MODE: EXAMPLE_SOURCE
    secret_env:
      EXAMPLE_TOKEN: EXAMPLE_TOKEN_SOURCE
    trusted_read_only_tools:
      - 'remote.read:雪'
'''.encode('utf-8')
        env = os.environ.copy()
        env['EXAMPLE_SOURCE'] = 'must-not-resolve-ordinary-value'
        env['EXAMPLE_TOKEN_SOURCE'] = 'must-not-resolve-secret-value'
        entry = self.convert(raw, environment=env)['servers'][0]
        self.assertFalse(entry['previously_enabled'])
        endpoint = entry['endpoint_request']
        self.assertEqual(endpoint['arguments'], ['--name', 'two words # literal', 'single # literal'])
        self.assertEqual(endpoint['cwd'], 'relative workspace')
        self.assertEqual(endpoint['environment'], {'EXAMPLE_MODE':'EXAMPLE_SOURCE'})
        self.assertEqual(endpoint['secret_env'], {'EXAMPLE_TOKEN':'legacy-secret-0'})
        self.assertEqual(entry['credential_source_requests'], [{'ref':'legacy-secret-0', 'source':{'environment':'EXAMPLE_TOKEN_SOURCE'}}])
        self.assertEqual(entry['configuration']['framing']['max_frame_bytes'], 524288)
        self.assertNotIn('must-not-resolve', json.dumps(entry))
        self.assertEqual(entry['trusted_read_only_tools'], ['remote.read:雪'])

    def test_all_http_fields_preserve_query_and_opaque_bindings(self):
        raw = b'''version: 1
servers:
  - id: HTTP
    enabled: true
    transport: streamable-http
    url: 'https://example.test?part=1&part=2'
    bearer_token_env: EXAMPLE_BEARER
    origin: https://example.test
    prefer_sse: TRUE
    max_frame_bytes: 65536
    request_timeout_ms: 30000
    graceful_shutdown_ms: 9223372036854775807
    headers:
      X-Trace: EXAMPLE_TRACE
    trusted_read_only_tools:
      - remote.status
'''
        entry = self.convert(raw)['servers'][0]
        config = entry['configuration']
        self.assertEqual(config['http']['url'], 'https://example.test?part=1&part=2')
        self.assertEqual(config['http']['origin'], 'https://example.test')
        self.assertTrue(config['http']['prefer_sse'])
        self.assertEqual(config['http']['credential_refs'], ['legacy-bearer', 'legacy-header-0'])
        self.assertEqual(entry['credential_source_requests'][0]['injection'], {'header':'Authorization', 'prefix':'Bearer '})
        self.assertEqual(entry['credential_source_requests'][1]['injection'], {'header':'X-Trace', 'prefix':''})
        self.assertEqual(config['framing']['graceful_shutdown_ms'], 9223372036854775807)

    def test_baseline_custom_headers_are_preserved_as_inert_operator_requests(self):
        names=["X_Trace", "Mcp-Custom", "Proxy-Marker", "Sec-Client", "Cookie"]
        raw=("version: 1\nservers:\n  - id: HTTP\n    enabled: false\n    transport: streamable-http\n    url: https://example.test/mcp\n    headers:\n"+"".join(f"      {name}: EXAMPLE_HEADER_{index}\n" for index,name in enumerate(names))).encode()
        entry=self.convert(raw)["servers"][0]
        self.assertEqual([value["injection"]["header"] for value in entry["credential_source_requests"]],names)
        self.assertFalse(entry["previously_enabled"])
        self.assertTrue(entry["operator_review"])

    def test_exact_historical_reserved_headers_still_refuse_inert_draft(self):
        for name in ["Authorization","Accept","Content-Type","Origin","Mcp-Protocol-Version","Mcp-Method","Mcp-Name"]:
            with self.subTest(name=name):
                raw=f"version: 1\nservers:\n  - id: HTTP\n    enabled: true\n    transport: streamable-http\n    url: https://example.test/mcp\n    headers:\n      {name}: EXAMPLE_HEADER\n".encode()
                self.source.write_bytes(raw)
                result=invoke("migrate_legacy.py",self.source)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,b"")
                self.assertEqual(self.source.read_bytes(),raw)
    def test_case_distinct_servers_have_independent_exact_namespaces(self):
        raw = ('version: 1\nservers:\n' + ''.join(f'  - id: {name}\n    enabled: false\n    transport: stdio\n    command: /usr/bin/example-mcp\n' for name in ['Echo','echo'])).encode()
        entries = self.convert(raw)['servers']
        self.assertEqual(len({entry['namespace'] for entry in entries}), 2)
        for entry in entries:
            self.assertEqual(entry['package_id'], 'mcp-client-'+hashlib.sha256(entry['legacy_id'].encode()).hexdigest())
            self.assertEqual(entry['namespace'], 'axyndra:'+entry['package_id'])

    def test_original_comments_crlf_and_unicode_are_byte_preserved(self):
        raw = '# 雪\r\nversion: 1\r\nservers:\r\n'.encode('utf-8')
        self.convert(raw)

    def test_strict_rejections_never_modify_source_or_emit_draft(self):
        base = 'version: 1\nservers:\n  - id: Echo\n    enabled: true\n    transport: stdio\n    command: /usr/bin/example-mcp\n'
        sources = [base+'    unknown: no\n', base+'    id: Other\n', base.replace('    enabled: true\n',''),
                   base.replace('true','yes'), base.replace('    command:','   command:'),
                   base.replace('  - id:', '\t- id:'), base+'    url: https://example.test\n',
                   base+'    max_frame_bytes: 1023\n', base+'    request_timeout_ms: 0\n',
                   base+'    graceful_shutdown_ms: -1\n', base+'    request_timeout_ms: 9223372036854775808\n',
                   base+'    network: proxy\n', base+'    args: [inline]\n',
                   base+'    env:\n      EXAMPLE_TOKEN: EXAMPLE_SOURCE\n',
                   base+'    env:\n      EXAMPLE_MODE: EXAMPLE_SOURCE\n    secret_env:\n      EXAMPLE_MODE: EXAMPLE_SECRET\n',
                   base+'    trusted_read_only_tools:\n      - echo\n      - echo\n',
                   base+'version: 1\n', base+base.split('servers:\n')[1],
                   'version: 1\nservers:\n  - id: http\n    enabled: true\n    transport: streamable-http\n    url: http://example.test/mcp\n',
                   'version: 1\nservers:\n  - id: http\n    enabled: true\n    transport: streamable-http\n    url: https://user@example.test/mcp\n',
                   'version: 1\nservers:\n  - id: http\n    enabled: true\n    transport: streamable-http\n    url: https://example.test/mcp\n    headers:\n      X-Trace: EXAMPLE_A\n      x-trace: EXAMPLE_B\n']
        for source in sources:
            with self.subTest(source=source):
                raw = source.encode()
                self.source.write_bytes(raw)
                result = invoke('migrate_legacy.py', self.source)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(self.source.read_bytes(), raw)
                self.assertEqual(json.loads(result.stderr)['code'], 'mcp_legacy.draft_rejected')

    def test_invalid_utf8_and_source_bound_fail_without_writes(self):
        for raw in [b'\xff', b'x'*1048577]:
            self.source.write_bytes(raw)
            result = invoke('migrate_legacy.py', self.source)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(self.source.read_bytes(), raw)


class NativeIdentityCLI(unittest.TestCase):
    def test_actual_package_clones_preserve_binary_and_bind_exact_manifest(self):
        with tempfile.TemporaryDirectory(prefix='mcp-native-identity-') as temporary:
            directory = Path(temporary)
            original = json.loads((PACKAGE/'package-provenance.json').read_text())
            for identifier in ['mcp-client-'+hashlib.sha256(name.encode()).hexdigest() for name in ['Echo','echo']]:
                clone = directory/identifier
                result = invoke('package.py', '--clone-source', PACKAGE, '--id', identifier, '--output', clone)
                self.assertEqual(result.returncode, 0, result.stderr)
                manifest = json.loads((clone/'axyndra.plugin.json').read_text())
                self.assertEqual(manifest['id'], identifier)
                proof = json.loads((clone/'package-provenance.json').read_text())
                for key in ['plugin_sha256','source_binary_sha256','bundled_libraries_sha256','bundled_licenses_sha256','required_system_libraries']:
                    self.assertEqual(proof[key], original[key])
                self.assertEqual(sha(clone/'bin/mcp-client-plugin'), sha(PACKAGE/'bin/mcp-client-plugin'))
                self.assertEqual(proof['manifest_sha256'], sha(clone/'axyndra.plugin.json'))
                self.hello(clone, identifier, True)
                self.hello(clone, 'mcp-client', False)
            invalid = invoke('package.py', '--clone-source', PACKAGE, '--id', 'BAD/identity', '--output', directory/'invalid')
            self.assertNotEqual(invalid.returncode, 0)
            self.assertFalse((directory/'invalid').exists())
            license_path = next((clone/'licenses').iterdir())
            license_path.write_bytes(license_path.read_bytes()+b'changed\n')
            rejected = invoke('package.py', '--clone-source', clone, '--output', directory/'tampered')
            self.assertNotEqual(rejected.returncode, 0)
            self.assertFalse((directory/'tampered').exists())

    def hello(self, package, identifier, ready):
        frame = {'type':'hello','protocol':'axyndra-js-host-v2','extension_id':identifier,'extension_version':'1.0.0','generation':7,'capabilities':['process.channel']}
        environment = os.environ.copy()
        for name in ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT']:
            environment.pop(name, None)
        result = subprocess.run([str(package/'bin/mcp-client-plugin')], input=(json.dumps(frame)+'\n').encode(),
                                env=environment, capture_output=True, timeout=5)
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        EVIDENCE.append({'native_package':str(package),'binary_sha256':sha(package/'bin/mcp-client-plugin'),
                         'sent':frame,'exit':result.returncode,'received':frames,'stderr':result.stderr.decode(errors='replace')})
        self.assertEqual(any(value.get('type')=='ready' for value in frames), ready)
        if ready:
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_preserved_worker_fails_before_identity_fix(self):
        with tempfile.TemporaryDirectory(prefix='mcp-native-before-') as temporary:
            clone = Path(temporary)/'before'
            identifier = 'mcp-client-'+hashlib.sha256(b'Echo').hexdigest()
            result = invoke('package.py', '--clone-source', BASELINE, '--id', identifier, '--output', clone)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.hello(clone, identifier, False)


def main():
    global PACKAGE, BASELINE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--baseline-package', type=Path)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    PACKAGE = args.package.resolve() if args.package else None
    BASELINE = args.baseline_package.resolve() if args.baseline_package else None
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(MigrationCLI)
    if PACKAGE:
        suite.addTest(NativeIdentityCLI('test_actual_package_clones_preserve_binary_and_bind_exact_manifest'))
    if BASELINE:
        suite.addTest(NativeIdentityCLI('test_actual_preserved_worker_fails_before_identity_fix'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps({'status':'PASS' if result.wasSuccessful() else 'FAIL',
            'cases':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'events':EVIDENCE},ensure_ascii=False,indent=2)+'\n')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
