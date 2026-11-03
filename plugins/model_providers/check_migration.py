#!/usr/bin/env python3
"""Execute the package's offline migration logic; no provider/server fixtures."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import migrate_configuration as migration


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def providers(protocol='chat-completions', extra='', provider='misleading-deepseek-name'):
    return ('providers:\n  - id: profile\n    provider: ' + quoted(provider) + '\n'
            '    protocol: ' + protocol + '\n    base_url: "https://provider.invalid/base"\n'
            '    api_key_env: PROVIDER_KEY\n' + extra).encode()


def models(extra='', name='wire-model'):
    return ('models:\n  - id: ' + quoted(name) + '\n    provider: profile\n' + extra).encode()


def selection(source=None, addresses=None):
    return {'namespace': 'native:model-providers', 'package_digest': 'sha256:' + 'a' * 64,
            'package_version': '1.1.0', 'providers': {'profile': {
                'credential_source': source or {'environment': 'PROVIDER_KEY'},
                'private_addresses': addresses or []}}}


class MigrationTests(unittest.TestCase):
    def convert(self, provider=None, model=None, choice=None):
        return migration.convert(provider or providers(), model or models(), choice or selection())

    def rejected(self, code, provider=None, model=None, choice=None):
        with self.assertRaisesRegex(migration.MigrationError, '^' + code.replace('.', '\\.') + '$'):
            self.convert(provider, model, choice)

    def test_versioned_mapping_contains_exact_neutral_projection(self):
        for dialect, contribution in migration.DIALECTS.items():
            protocol = 'messages' if contribution == 'anthropic-messages' else 'responses' if contribution == 'openai-responses' else 'completions'
            result = self.convert(providers(protocol, extra='    dialect: ' + dialect + '\n'))
            mapping = result['plugin_entry']['configuration']['model_providers'][0]
            self.assertEqual(mapping['version'], 2)
            self.assertEqual(mapping['capabilities'], result['neutral_model_metadata'][0]['capabilities'])
            self.assertEqual(mapping['capabilities']['parallel_tools'], not dialect.startswith('deepseek_'))
            self.assertEqual(set(mapping), {'version','capabilities','model','contribution','wire_model','provider_id','configuration','credential_refs'})

    def test_three_protocols_keep_exact_endpoint_and_auth_locations(self):
        for protocol, contribution, dialect, suffix, injection in [
            ('chat-completions', 'openai-chat-completions', 'generic_chat', '/v1/chat/completions', {'header': 'authorization', 'prefix': 'Bearer '}),
            ('responses', 'openai-responses', 'openai_responses', '/v1/responses', {'header': 'authorization', 'prefix': 'Bearer '}),
            ('messages', 'anthropic-messages', 'generic_messages', '/v1/messages', {'header': 'x-api-key'}),
        ]:
            with self.subTest(protocol=protocol):
                result = self.convert(providers(protocol))
                entry = result['plugin_entry']
                mapping = entry['configuration']['model_providers'][0]
                self.assertEqual(contribution, mapping['contribution'])
                self.assertEqual(dialect, mapping['configuration']['dialect'])
                self.assertEqual('https://provider.invalid/base' + suffix, entry['requests'][0]['url'])
                self.assertEqual(injection, entry['credentials'][0]['injection'])
                self.assertEqual(['POST'], entry['requests'][0]['methods'])

    def test_all_eight_explicit_dialects_and_parallel_capability(self):
        for dialect, contribution in migration.DIALECTS.items():
            with self.subTest(dialect=dialect):
                protocol = 'messages' if contribution == 'anthropic-messages' else 'responses' if contribution == 'openai-responses' else 'completions'
                result = self.convert(providers(protocol, '    dialect: ' + dialect + '\n'))
                self.assertEqual(contribution, result['plugin_entry']['configuration']['model_providers'][0]['contribution'])
                self.assertEqual(not dialect.startswith('deepseek_'), result['neutral_model_metadata'][0]['capabilities']['parallel_tools'])

    def test_provider_or_model_names_do_not_select_protocol(self):
        result = self.convert(providers(provider='anthropic-deepseek-responses'), models(name='claude-o3-deepseek'))
        mapping = result['plugin_entry']['configuration']['model_providers'][0]
        self.assertEqual('generic_chat', mapping['configuration']['dialect'])
        self.assertTrue(result['neutral_model_metadata'][0]['capabilities']['parallel_tools'])

    def test_model_api_override_and_explicit_dialect_precedence(self):
        result = self.convert(model=models('    api: openai_responses\n'))
        self.assertEqual('openai-responses', result['plugin_entry']['configuration']['model_providers'][0]['contribution'])
        result = self.convert(providers(extra='    dialect: deepseek_chat\n'), models('    api: openai_responses\n'))
        self.assertEqual('openai-chat-completions', result['plugin_entry']['configuration']['model_providers'][0]['contribution'])
        self.rejected('migration.model_dialect_mismatch', model=models('    api: openai_responses\n    dialect: openai_chat\n'))

    def test_model_headers_replace_profile_and_quoted_commas_roundtrip(self):
        result = self.convert(providers(extra='    default_headers: ["x-shared: profile", "x-canary: canary, stable", "x-shared: last"]\n'),
                              models('    default_headers: ["X-Shared: model", "x-json: \\\"雪\\\"", "x-path: C:\\\\temp"]\n'))
        self.assertEqual({'x-shared': 'model', 'x-canary': 'canary, stable', 'x-json': '"雪"', 'x-path': 'C:\\temp'},
                         result['plugin_entry']['configuration']['model_providers'][0]['configuration']['headers'])

    def test_capability_limits_modalities_price_catalog_preserved(self):
        raw = models('    context_window: 64000\n    max_output_tokens: 32000\n'
                     '    input_modalities: [text, image, vendor-custom]\n    output_modalities: [text]\n'
                     '    prompt_cache: true\n    structured_output: true\n'
                     '    input_cost_micros_per_million: 120\n    fast_service_tier: priority\n')
        result = self.convert(providers(extra='    endpoint_max_output_tokens: 18000\n'), raw)
        caps = result['neutral_model_metadata'][0]['capabilities']
        self.assertEqual((64000, 32000, 18000), (caps['context_window'], caps['max_output'], caps['endpoint_max_output']))
        self.assertTrue(caps['images'] and caps['prompt_cache'] and caps['structured_output'])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), result['sources']['models_sha256'])
        self.assertEqual('preserved-for-selection-pricing-and-ui', result['compatibility']['old_catalog_and_profiles'])

    def test_thinking_modes_preserve_normalized_order_and_default_budget(self):
        toggle = self.convert(model=models('    thinking:\n      mode: toggle\n'))
        self.assertEqual(migration.LEVELS, toggle['neutral_model_metadata'][0]['capabilities']['thinking']['levels'])
        budget = self.convert(model=models('    thinking:\n      mode: budget\n      levels: [low, high]\n'))
        self.assertEqual([{'level': 'low', 'tokens': 2048}, {'level': 'high', 'tokens': 16384}],
                         budget['neutral_model_metadata'][0]['capabilities']['thinking']['tiers'])
        authored = self.convert(model=models('    thinking:\n      mode: budget\n      levels: [low, high]\n'
                                            '      budgets:\n        low: 1000\n        high: 5000\n'))
        self.assertEqual(5000, authored['neutral_model_metadata'][0]['capabilities']['thinking']['tiers'][1]['tokens'])
        self.rejected('migration.thinking_level_order', model=models('    thinking:\n      mode: effort\n      levels: [high, low]\n'))
        self.rejected('migration.thinking_budget_coverage', model=models('    thinking:\n      mode: budget\n      levels: [low, high]\n      budgets:\n        low: 5000\n        high: 1000\n'))

    def test_file_source_is_opaque_and_environment_is_never_read(self):
        with patch.dict(os.environ, {'PROVIDER_KEY': 'MIGRATION-SECRET-SHOULD-NOT-APPEAR'}), \
             patch('builtins.open', side_effect=AssertionError('pure conversion opened a file')):
            result = self.convert(choice=selection({'file': 'profile.key'}))
        self.assertEqual({'file': 'profile.key'}, result['plugin_entry']['credentials'][0]['source'])
        self.assertNotIn('MIGRATION-SECRET', migration.encoded(result).decode())
        self.assertEqual('explicit-source-selection-required', result['compatibility']['credential_fallback'])
        self.assertFalse(result['compatibility']['automatic_apply'])

    def test_no_implicit_credential_choice_or_new_secret_source(self):
        chosen = selection(); chosen['providers'].clear()
        self.rejected('migration.credential_choice_required', choice=chosen)
        self.rejected('migration.credential_source_changed', choice=selection({'environment': 'OTHER_KEY'}))
        self.rejected('migration.credential_source_changed', choice=selection({'file': '../profile.key'}))
        self.rejected('migration.credential_source', choice=selection({'value': 'literal-secret'}))

    def test_oauth_is_not_silently_converted_to_api_key(self):
        self.rejected('migration.oauth_unsupported', providers(extra='    authentication: oauth\n'))

    def test_loopback_requires_explicit_addresses_no_dns_and_remote_http_optin(self):
        local = providers().replace(b'https://provider.invalid/base', b'http://localhost:8765/base')
        self.rejected('migration.loopback_addresses_required', local)
        result = self.convert(local, choice=selection(addresses=['127.0.0.1', '::1']))
        self.assertTrue(result['plugin_entry']['configuration']['model_providers'][0]['configuration']['allow_insecure_http'])
        self.assertEqual(['127.0.0.1', '::1'], result['plugin_entry']['requests'][0]['private_addresses'])
        remote = providers().replace(b'https://', b'http://')
        self.rejected('migration.insecure_endpoint', remote)
        self.convert(remote + b'    allow_insecure_http: true\n')

    def test_endpoints_cannot_hide_query_fragment_userinfo_or_raw_controls(self):
        for endpoint in ['https://user:secret@host.invalid', 'https://host.invalid/?secret=value',
                         'https://host.invalid/#fragment', 'https://host.invalid:70000', 'https://host.invalid/ space']:
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(migration.MigrationError):
                    self.convert(providers().replace(b'https://provider.invalid/base', endpoint.encode()))

    def test_same_profile_distinct_api_refs_and_request_deduplication(self):
        extra = models() + b'  - id: second\n    provider: profile\n  - id: msg\n    provider: profile\n    api: anthropic_messages\n'
        result = self.convert(model=extra)
        self.assertEqual(3, len(result['plugin_entry']['configuration']['model_providers']))
        self.assertEqual(2, len(result['plugin_entry']['requests']))
        self.assertEqual(2, len(result['plugin_entry']['credentials']))

    def test_unknown_duplicate_and_unsupported_yaml_are_explicit_errors(self):
        for bad in [b'    unknown: value\n', b'    provider: another\n', b'    dialect: &anchor\n']:
            with self.subTest(bad=bad):
                with self.assertRaises(migration.MigrationError):
                    self.convert(providers() + bad)
        self.rejected('migration.duplicate_model', model=models() + models().split(b'\n', 1)[1])
        self.rejected('migration.profile_id', provider=providers() + providers().split(b'\n', 1)[1])

    def test_reserved_headers_and_output_limits_rejected(self):
        self.rejected('migration.header_reserved', providers(extra='    default_headers: ["Authorization: secret"]\n'))
        self.rejected('migration.output_exceeds_context', model=models('    context_window: 100\n    max_output_tokens: 101\n'))
        self.rejected('migration.source_limit', provider=b'#' * (migration.MAX_SOURCE + 1))
        self.rejected('migration.source_utf8', provider=b'\xff')

    def test_exact_source_and_package_identity_and_mutation_isolation(self):
        p, m, choice = providers(), models(), selection()
        result = self.convert(p, m, choice)
        self.assertEqual(hashlib.sha256(p).hexdigest(), result['sources']['providers_sha256'])
        self.assertEqual(hashlib.sha256(migration.encoded(choice)).hexdigest(), result['sources']['selection_sha256'])
        choice['providers']['profile']['credential_source']['environment'] = 'AFTER_CONVERSION'
        self.assertEqual('PROVIDER_KEY', result['plugin_entry']['credentials'][0]['source']['environment'])
        bad = selection(); bad['package_digest'] = 'a' * 64
        self.rejected('migration.package_digest', choice=bad)
        self.assertEqual(result, self.convert(p, m))

    def test_real_cli_reads_only_three_explicit_inputs_and_never_writes_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = [root / 'providers.yml', root / 'models.yml', root / 'selection.json']
            values = [providers(), models(name='雪'), migration.encoded(selection({'file': 'profile.key'}))]
            for path, value in zip(paths, values):
                path.write_bytes(value)
            credentials = root / 'credentials'; credentials.mkdir()
            secret = credentials / 'profile.key'; secret.write_bytes(b'FILE-SECRET-NEVER-READ')
            before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
            proc = subprocess.run([sys.executable, str(Path(migration.__file__).resolve()), '--providers', str(paths[0]),
                                   '--models', str(paths[1]), '--selection', str(paths[2])],
                                  capture_output=True, timeout=10)
            self.assertEqual(0, proc.returncode, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual('profile/雪', result['plugin_entry']['configuration']['model_providers'][0]['model'])
            self.assertNotIn(b'FILE-SECRET', proc.stdout + proc.stderr)
            self.assertEqual(before, {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()})

    def test_cli_duplicate_json_or_invalid_source_does_not_echo_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            p, m, s = root / 'p', root / 'm', root / 's'
            p.write_bytes(providers()); m.write_bytes(models())
            s.write_text('{"namespace":"SECRET-CONTENT","namespace":"other"}')
            proc = subprocess.run([sys.executable, str(Path(migration.__file__).resolve()), '--providers', str(p),
                                   '--models', str(m), '--selection', str(s)], capture_output=True, timeout=10)
            self.assertEqual(2, proc.returncode)
            self.assertEqual(b'', proc.stdout)
            self.assertEqual(b'migration.duplicate_json_field\n', proc.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
