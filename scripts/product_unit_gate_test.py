#!/usr/bin/env python3
import unittest
from product_unit_gate import (dry_run_cases, summary, inventory, run_logged,
                               prepare_bundled_plugin, requested_scope, run_isolated_agent_product,
                               isolated_case_timeouts, configure_http_fixture_environment, configure_service_fixture_environment,
                               configure_business_fixture_environment, configure_model_provider_fixture_environment,
                               configure_language_fixture_environment, configure_installed_model_fixture_environment)
from pathlib import Path
import hashlib
import json
import os
import tempfile
import subprocess
import sys
from unittest.mock import patch

class UnitGateTest(unittest.TestCase):
    def test_language_fixture_requires_all_peers_before_replacing_environment(self):
        fixtures = {
            'AXYNDRA_LSP_TEST_SERVER': 'plugins/lsp/tests/lsp_peer.py',
            'AXYNDRA_DAP_TEST_SERVER': 'plugins/dap/tests/dap_peer.py',
            'AXYNDRA_DAP_OWNED_TEST_SERVER': 'plugins/dap/tests/dap_owned_peer.py',
        }
        stale = {name: 'stale-' + name for name in fixtures}
        for absent in fixtures:
            with self.subTest(missing=absent), tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, stale):
                root = Path(temporary).resolve()
                for name, relative in fixtures.items():
                    if name != absent:
                        path = root / relative
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(name.encode())
                with self.assertRaisesRegex(ValueError, absent + ' fixture is missing'):
                    configure_language_fixture_environment(root)
                for name, value in stale.items():
                    self.assertEqual(os.environ[name], value)
                missing = root / fixtures[absent]
                missing.parent.mkdir(parents=True, exist_ok=True)
                missing.write_bytes(absent.encode())
                result = configure_language_fixture_environment(root)
                for name, relative in fixtures.items():
                    self.assertEqual(os.environ[name], str(root / relative))
                self.assertEqual(result['language_fixture_sha256'], {
                    relative: hashlib.sha256(name.encode()).hexdigest()
                    for name, relative in fixtures.items()})

    def test_business_fixture_overrides_stale_path_and_records_exact_bytes(self):
        fixtures = {
            'AXYNDRA_GITHUB_TEST_COMMAND': 'support_tests/plugin_github_service_peer/command.py',
            'AXYNDRA_READ_VIEW_PLUGIN_FIXTURE': 'support_tests/read_view_fixture/main.py',
            'AXYNDRA_DOCUMENT_PLUGIN_FIXTURE': 'support_tests/plugin_document_fixture/main.py',
            'AXYNDRA_DATA_ONLY_PLUGIN_FIXTURE': 'support_tests/plugin_data_only_fixture/main.py',
            'AXYNDRA_WORKFLOW_MIXED_FIXTURE': 'support_tests/plugin_document_fixture/mixed_provider.py',
        }
        stale = {name: 'stale-' + name for name in fixtures}
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, stale):
            root = Path(temporary).resolve()
            for name, relative in fixtures.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            result = configure_business_fixture_environment(root)
            for name, relative in fixtures.items():
                self.assertEqual(os.environ[name], str(root / relative))
            self.assertEqual(result['business_fixture_sha256'], {
                relative: hashlib.sha256(name.encode()).hexdigest()
                for name, relative in fixtures.items()})

    def test_missing_business_fixture_preserves_environment(self):
        fixtures = {
            'AXYNDRA_GITHUB_TEST_COMMAND': 'support_tests/plugin_github_service_peer/command.py',
            'AXYNDRA_READ_VIEW_PLUGIN_FIXTURE': 'support_tests/read_view_fixture/main.py',
            'AXYNDRA_DOCUMENT_PLUGIN_FIXTURE': 'support_tests/plugin_document_fixture/main.py',
            'AXYNDRA_DATA_ONLY_PLUGIN_FIXTURE': 'support_tests/plugin_data_only_fixture/main.py',
            'AXYNDRA_WORKFLOW_MIXED_FIXTURE': 'support_tests/plugin_document_fixture/mixed_provider.py',
        }
        stale = {name: 'stale-' + name for name in fixtures}
        for absent in fixtures:
            with self.subTest(missing=absent), tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, stale):
                root = Path(temporary)
                for name, relative in fixtures.items():
                    if name != absent:
                        path = root / relative
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(name.encode())
                with self.assertRaisesRegex(ValueError, absent + ' fixture is missing'):
                    configure_business_fixture_environment(root)
                for name, value in stale.items():
                    self.assertEqual(os.environ[name], value)
    def test_installed_model_fixture_requires_origin_and_actual_adapter_goldens(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=False):
            root = Path(temporary).resolve()
            origin = root / 'plugins/model_providers/tests/origin.py'
            origin.parent.mkdir(parents=True)
            with self.assertRaises(ValueError):
                configure_installed_model_fixture_environment(root)
            origin.write_bytes(b'controlled-origin')
            with self.assertRaises(ValueError):
                configure_installed_model_fixture_environment(root)
            adapter = root / 'plugins/model_providers/check.py'
            adapter.write_bytes(b'actual-adapter-goldens')
            result = configure_installed_model_fixture_environment(root)
            self.assertEqual(os.environ['AXYNDRA_MODEL_PROVIDER_ORIGIN'], str(origin))
            self.assertEqual(result['installed_model_fixture_sha256'], {
                'plugins/model_providers/tests/origin.py': hashlib.sha256(origin.read_bytes()).hexdigest(),
                'plugins/model_providers/check.py': hashlib.sha256(adapter.read_bytes()).hexdigest()})

    def test_model_provider_fixture_is_required_and_hash_bound(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ):
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'model provider'):
                configure_model_provider_fixture_environment(root)
            peer = root / 'support_tests/model_provider_peer/main.py'
            peer.parent.mkdir(parents=True)
            peer.write_bytes(b'# fixed offline process peer\n')
            observed = configure_model_provider_fixture_environment(root)
            self.assertEqual(os.environ['AXYNDRA_MODEL_PROVIDER_PEER'], str(peer.resolve()))
            self.assertEqual(observed['model_provider_peer_sha256'], hashlib.sha256(peer.read_bytes()).hexdigest())

    def service_fixture_files(self, root, missing=None):
        names = ['support_tests/plugin_mcp_service_peer/main.py',
                 'support_tests/plugin_mcp_service_peer/environment.py',
                 'support_tests/plugin_mcp_service_peer/host_network.py',
                 'plugins/mcp/tests/capacity_server.py',
                 'plugins/mcp/tests/payload_server.py']
        for name in names:
            if name != missing:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
        return names

    def test_service_fixture_environment_replaces_stale_paths_and_seals_siblings(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                'AXYNDRA_MCP_TEST_SERVER': 'old-main', 'AXYNDRA_MCP_CAPACITY_SERVER': 'old-capacity', 'AXYNDRA_MCP_PAYLOAD_SERVER': 'old-payload'}):
            root = Path(temporary).resolve()
            names = self.service_fixture_files(root)
            record = configure_service_fixture_environment(root)
            self.assertEqual(os.environ['AXYNDRA_MCP_TEST_SERVER'], str(root / names[0]))
            self.assertEqual(os.environ['AXYNDRA_MCP_CAPACITY_SERVER'], str(root / names[3]))
            self.assertEqual(os.environ['AXYNDRA_MCP_PAYLOAD_SERVER'], str(root / names[4]))
            self.assertEqual(record['mcp_service_fixture_sha256'], {
                name: hashlib.sha256(name.encode()).hexdigest() for name in names})

    def test_missing_service_fixture_cannot_partially_replace_environment(self):
        with tempfile.TemporaryDirectory() as inventory_root:
            names = self.service_fixture_files(Path(inventory_root))
        for missing in names:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                    'AXYNDRA_MCP_TEST_SERVER': 'old-main', 'AXYNDRA_MCP_CAPACITY_SERVER': 'old-capacity', 'AXYNDRA_MCP_PAYLOAD_SERVER': 'old-payload'}):
                root = Path(temporary)
                self.service_fixture_files(root, missing)
                with self.assertRaisesRegex(ValueError, 'fixture is missing'):
                    configure_service_fixture_environment(root)
                self.assertEqual(os.environ['AXYNDRA_MCP_TEST_SERVER'], 'old-main')
                self.assertEqual(os.environ['AXYNDRA_MCP_CAPACITY_SERVER'], 'old-capacity')
                self.assertEqual(os.environ['AXYNDRA_MCP_PAYLOAD_SERVER'], 'old-payload')

    def test_http_fixture_paths_override_inherited_environment_and_record_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'AXYNDRA_MCP_HTTP_TEST_SERVER': 'stale'}):
            root = Path(temporary).resolve()
            fixture = root / 'support_tests/native_plugin_fixture'
            fixture.mkdir(parents=True)
            (fixture / 'http_stream_origin.py').write_bytes(b'actual-origin')
            (fixture / 'mcp_http_peer.py').write_bytes(b'actual-peer')
            record = configure_http_fixture_environment(root)
            self.assertEqual(os.environ['AXYNDRA_MCP_HTTP_TEST_SERVER'], str(fixture / 'mcp_http_peer.py'))
            self.assertEqual(record, {
                'http_stream_origin_sha256': hashlib.sha256(b'actual-origin').hexdigest(),
                'mcp_http_product_peer_sha256': hashlib.sha256(b'actual-peer').hexdigest(),
            })

    def test_missing_http_fixture_fails_before_replacing_environment(self):
        for missing in ['http_stream_origin.py', 'mcp_http_peer.py']:
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'AXYNDRA_MCP_HTTP_TEST_SERVER': 'stale'}):
                root = Path(temporary)
                fixture = root / 'support_tests/native_plugin_fixture'
                fixture.mkdir(parents=True)
                for name in ['http_stream_origin.py', 'mcp_http_peer.py']:
                    if name != missing:
                        (fixture / name).write_bytes(b'present')
                with self.assertRaisesRegex(ValueError, 'fixture is missing'):
                    configure_http_fixture_environment(root)
                self.assertEqual(os.environ['AXYNDRA_MCP_HTTP_TEST_SERVER'], 'stale')

    def test_real_installed_web_case_has_a_bounded_timeout_exception(self):
        name = 'PluginHttpServiceTests.separatelyPackagedWebSearchUsesRealProductGatewayAndSearxOrigin'
        self.assertEqual(isolated_case_timeouts(name), (90, 120))
        self.assertEqual(isolated_case_timeouts('PluginHttpServiceTests.other'), (60, 90))
        self.assertEqual(isolated_case_timeouts(name + 'Other'), (60, 90))
        for case_exit in [0, 124]:
            with self.subTest(case_exit=case_exit), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                def invoke(command, log, cwd, timeout=900):
                    if '--dry-run' in command:
                        log.write_text('TCS: PluginHttpServiceTests, RESULT:\n[NORUN] CASE: ' + name.split('.')[1])
                        return 0
                    self.assertIn('--timeout-each=90s', command)
                    self.assertEqual(timeout, 120)
                    log.write_text('Summary: TOTAL: 1\nPASSED: 1, SKIPPED: 0, ERROR: 0\nFAILED: 0')
                    return case_exit
                with patch('product_unit_gate.run_logged', side_effect=invoke):
                    result = run_isolated_agent_product(root, root, root / 'combined.log')
                self.assertEqual(result['status'], 'PASS' if case_exit == 0 else 'FAIL')
                self.assertEqual(result['case_timeouts'][name], {'case_seconds': 90, 'process_seconds': 120})

    def test_exact_capacity_cases_preserve_bounded_outer_timeouts_and_failure(self):
        names = [
            'ModelWireEnvelopeTests.installedMessagesMatchesObservedOldNearEightMiBSemanticSuccess',
            'PluginTransportBudgetTests.realShellSixteenMibAsciiAndEscapedNulKeepExactArtifactsAndReceipts',
        ]
        for name in names:
            self.assertEqual(isolated_case_timeouts(name), (150, 180))
            for other in [name + 'Other', name[:-1], name.split('.')[0] + '.other']:
                self.assertEqual(isolated_case_timeouts(other), (60, 90))
            for case_exit in [0, 124]:
                with self.subTest(name=name, case_exit=case_exit), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    def invoke(command, log, cwd, timeout=900):
                        if '--dry-run' in command:
                            suite, case = name.split('.')
                            log.write_text('TCS: ' + suite + ', RESULT:\n[NORUN] CASE: ' + case)
                            return 0
                        self.assertIn('--timeout-each=150s', command)
                        self.assertEqual(timeout, 180)
                        log.write_text('Summary: TOTAL: 1\nPASSED: 1, SKIPPED: 0, ERROR: 0\nFAILED: 0')
                        return case_exit
                    with patch('product_unit_gate.run_logged', side_effect=invoke):
                        result = run_isolated_agent_product(root, root, root / 'combined.log')
                    self.assertEqual(result['status'], 'PASS' if case_exit == 0 else 'FAIL')
                    self.assertEqual(result['case_timeouts'][name], {'case_seconds': 150, 'process_seconds': 180})

    def test_targeted_scope_does_not_hide_inventory_drift(self):
        found = {'agent_product': ['agent_product/src/http_test.cj'], 'other': ['other/src/one_test.cj']}
        expected = {key: list(value) for key, value in found.items()}
        default = requested_scope(found, expected)
        self.assertEqual(default['kind'], 'full')
        self.assertEqual(default['selected_packages'], list(found))
        scope = requested_scope(found, expected, 'agent_product', 'PluginHttp')
        self.assertEqual(scope['requested'], {'package': 'agent_product', 'case_prefix': 'PluginHttp'})
        self.assertEqual(scope['enumerated_packages'], ['agent_product', 'other'])
        self.assertEqual(scope['selected_packages'], ['agent_product'])
        found['other'].append('other/src/new_test.cj')
        with self.assertRaisesRegex(ValueError, 'inventory differs for other'):
            requested_scope(found, expected, 'agent_product', 'PluginHttp')

    def test_invalid_scope_fails_before_execution(self):
        found = {'agent_product': ['product_test.cj'], 'other': ['other_test.cj']}
        for package, prefix, inventory_only, message in [
            ('missing', None, False, 'unknown unit-test package'),
            (None, 'PluginHttp', False, '--case-prefix requires'),
            ('other', 'PluginHttp', False, '--case-prefix requires'),
            ('agent_product', '', False, '--case-prefix requires'),
            ('agent_product', 'PluginHttp', True, 'cannot be combined'),
        ]:
            with self.subTest(package=package, prefix=prefix), self.assertRaisesRegex(ValueError, message):
                requested_scope(found, found, package, prefix, inventory_only)

    def run_isolated_fixture(self, root, prefix, total=3, passed=1, skipped=2):
        commands = []
        def invoke(command, log, cwd, timeout=900):
            commands.append(command)
            if '--dry-run' in command:
                log.write_text('TCS: PluginHttpServiceTests, RESULT:\n'
                               '[ NORUN ] CASE: request\n[ NORUN ] CASE: cancel\n'
                               'TCS: OtherTests, RESULT:\n[ NORUN ] CASE: unrelated\n')
            else:
                log.write_text(f'Summary: TOTAL: {total}\nPASSED: {passed}, SKIPPED: {skipped}, ERROR: 0\nFAILED: 0')
            return 0
        with patch('product_unit_gate.run_logged', side_effect=invoke):
            result = run_isolated_agent_product(root, root, root / 'combined.log', prefix)
        return result, commands

    def test_focused_runner_records_all_cases_but_executes_only_exact_selected_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, commands = self.run_isolated_fixture(root, 'PluginHttp')
            self.assertEqual(result['status'], 'PASS')
            self.assertEqual((result['enumerated_case_count'], result['selected_case_count'], result['excluded']), (3, 2, 1))
            self.assertEqual((result['total'], result['passed'], result['skipped']), (2, 2, 0))
            self.assertEqual(result['scope']['enumerated'], [
                'PluginHttpServiceTests.request', 'PluginHttpServiceTests.cancel', 'OtherTests.unrelated'])
            self.assertEqual(result['scope']['selected'], result['scope']['enumerated'][:2])
            self.assertEqual([command[command.index('--filter') + 1] for command in commands[1:]],
                             result['scope']['selected'])
            self.assertEqual(len(result['case_logs']), 2)

    def test_zero_match_or_wrong_filtered_counts_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result, commands = self.run_isolated_fixture(root, 'PluginHttp*')
            self.assertEqual(result['status'], 'FAIL')
            self.assertEqual(result['scope']['selected'], [])
            self.assertEqual(len(commands), 1)
            self.assertIn('no unit-test cases match literal prefix', result['error'])
            result, _ = self.run_isolated_fixture(root, 'PluginHttp', total=2, skipped=1)
            self.assertEqual(result['status'], 'FAIL')
            result, _ = self.run_isolated_fixture(root, 'PluginHttp', passed=0, skipped=3)
            self.assertEqual(result['status'], 'FAIL')

    def test_default_isolated_runner_executes_every_enumerated_case(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, commands = self.run_isolated_fixture(Path(temporary), None)
            self.assertEqual(result['status'], 'PASS')
            self.assertEqual(result['scope']['selected'], result['scope']['enumerated'])
            self.assertEqual((result['total'], result['passed'], result['excluded']), (3, 3, 0))
            self.assertEqual(len(commands), 4)

    def fixture_package(self, root):
        package = root / 'target/plugin-contract-fixtures/candidate/package'
        (package / 'bin').mkdir(parents=True)
        source = root / 'plugins/example'
        source.mkdir(parents=True)
        manifest = dict(id='example', version='1.0.0', entry_kind='native-executable', entrypoint='bin/worker')
        for target in [source, package]:
            (target / 'axyndra.plugin.json').write_text(json.dumps(manifest))
        (package / 'bin/worker').write_bytes(b'fixture-binary')
        (package / 'package-provenance.json').write_text(json.dumps(dict(
            plugin_sha256=hashlib.sha256(b'fixture-binary').hexdigest())))
        return package

    def test_prepared_plugin_path_and_provenance_are_recorded_after_success(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'GATE_PLUGIN_FIXTURE': 'stale'}):
            root = Path(temporary).resolve()
            package = self.fixture_package(root)
            command = [sys.executable, '-c', 'print("build and checks passed"); print(' + repr(str(package)) + ')']
            record = prepare_bundled_plugin(root, root, 'example', command, 'GATE_PLUGIN_FIXTURE')
            self.assertEqual(os.environ['GATE_PLUGIN_FIXTURE'], str(package))
            self.assertEqual(record['status'], 'PASS')
            self.assertEqual(record['entrypoint_sha256'], hashlib.sha256(b'fixture-binary').hexdigest())
            self.assertIn('build and checks passed', (root / record['log']).read_text())

    def test_plugin_preparation_fails_closed_without_reusing_inherited_path(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'GATE_PLUGIN_FIXTURE': 'stale'}):
            root = Path(temporary).resolve()
            package = self.fixture_package(root)
            commands = [
                [sys.executable, '-c', 'raise SystemExit(7)'],
                [sys.executable, '-c', 'pass'],
                [sys.executable, '-c', 'print("relative/package")'],
                [sys.executable, '-c', 'print(' + repr(str(root)) + ')'],
            ]
            for command in commands:
                with self.subTest(command=command), self.assertRaises(ValueError):
                    prepare_bundled_plugin(root, root, 'example', command, 'GATE_PLUGIN_FIXTURE')
                self.assertEqual(os.environ['GATE_PLUGIN_FIXTURE'], 'stale')
            command = [sys.executable, '-c', 'print(' + repr(str(package)) + ')']
            (package / 'bin/worker').write_bytes(b'changed-after-packaging')
            with self.assertRaisesRegex(ValueError, 'provenance'):
                prepare_bundled_plugin(root, root, 'example', command, 'GATE_PLUGIN_FIXTURE')
            (package / 'axyndra.plugin.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'manifest'):
                prepare_bundled_plugin(root, root, 'example', command, 'GATE_PLUGIN_FIXTURE')
            self.assertEqual(os.environ['GATE_PLUGIN_FIXTURE'], 'stale')

    def test_inventory_detects_added_tests_and_removed_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'pkg/src').mkdir(parents=True)
            manifest = root / 'cjpm.toml'
            manifest.write_text('[workspace]\nmembers=["pkg"]\ntest-members=["pkg"]\n')
            (root / 'pkg/src/one_test.cj').write_text('test')
            before = inventory(root)
            (root / 'pkg/src/two_test.cj').write_text('test')
            self.assertNotEqual(before, inventory(root))
            manifest.write_text('[workspace]\nmembers=["pkg"]\ntest-members=[]\n')
            with self.assertRaises(ValueError): inventory(root)
            manifest.write_text('[workspace]\nmembers=[]\ntest-members=[]\n')
            with self.assertRaises(ValueError): inventory(root)

    def test_dry_run_cases_preserve_suite_qualified_identity(self):
        report = '''
            TCS: FirstSuite, RESULT:
            [ NORUN  ] CASE: first
            [ NORUN  ] CASE: second
            TCS: SecondSuite, RESULT:
            [ NORUN  ] CASE: first
        '''
        self.assertEqual(dry_run_cases(report), [
            'FirstSuite.first', 'FirstSuite.second', 'SecondSuite.first'
        ])
        with self.assertRaises(ValueError):
            dry_run_cases('[ NORUN  ] CASE: orphan')
        with self.assertRaises(ValueError):
            dry_run_cases('TCS: EmptySuite, RESULT:')

    def test_timeout_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / 'child.py'
            child.write_text("import time\nfrom pathlib import Path\ntime.sleep(0.5)\nPath('survived').touch()\n")
            parent = root / 'parent.py'
            parent.write_text("import subprocess,sys,time\nsubprocess.Popen([sys.executable, 'child.py'])\ntime.sleep(30)\n")
            self.assertEqual(run_logged([sys.executable, str(parent)], root / 'log', root, 0.2), 124)
            subprocess.run([sys.executable, '-c', 'import time; time.sleep(0.6)'], check=True)
            self.assertFalse((root / 'survived').exists())

    def test_real_summary(self):
        self.assertEqual(summary('Summary: TOTAL: 3\n    PASSED: 2, SKIPPED: 0, ERROR: 0\n    FAILED: 1')['failed'], 1)
    def test_fail_closed(self):
        for text in ['build success', 'Summary: TOTAL: 0\n    PASSED: 0, SKIPPED: 0, ERROR: 0\n    FAILED: 0', 'Summary: TOTAL: 2\n    PASSED: 1, SKIPPED: 0, ERROR: 0\n    FAILED: 0']:
            with self.assertRaises(ValueError): summary(text)

class HostIsolationGateTest(unittest.TestCase):
    def test_host_physical_role_preserves_rpc_cap_and_original_host_budget(self):
        from rpc_case_process_watch import run_case, run_host_case, process_custody_closed
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            command = [sys.executable, '-c', 'pass']
            with self.assertRaises(ValueError):
                run_case(command, root / 'rpc.log', 61, cwd=root)
            with self.assertRaises(ValueError):
                run_host_case(command, root / 'over-host.log', 901, cwd=root)
            result = run_host_case(command, root / 'host.log', 61, cwd=root)
            self.assertEqual(result['custody_role'], 'host-case')
            self.assertEqual(result['case_process_seconds'], 61)
            self.assertEqual(result['exit_code'], 0)
            self.assertTrue(process_custody_closed(result))
            self.assertFalse(result['physical_exit_is_data_consumption_ACK'])

if __name__ == '__main__': unittest.main()
