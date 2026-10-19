#!/usr/bin/env python3
"""Exercise the real worker and protocol frames; Product contracts test host admission."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest

PACKAGE = None
IDENTITY_KEYS = ['protocol', 'extension_id', 'extension_version', 'generation', 'id',
                 'tool', 'kind', 'command_id', 'thread_id', 'run_id', 'epoch',
                 'operation_id', 'call_id']


def clean_environment():
    environment = os.environ.copy()
    for name in ['LD_LIBRARY_PATH', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH', 'AXYNDRA_SDK_ROOT']:
        environment.pop(name, None)
    return environment


def worker(workspace, arguments, editing=False):
    return subprocess.run([str(PACKAGE / 'bin/ast-plugin'), '--edit-worker' if editing else '--query-worker',
                           json.dumps(arguments, separators=(',', ':'))],
                          cwd=workspace, env=clean_environment(), text=True,
                          capture_output=True, timeout=35)


class Protocol:
    def __init__(self, workspace):
        self.process = subprocess.Popen([str(PACKAGE / 'bin/ast-plugin')], cwd=workspace,
                                        env=clean_environment(), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        if self.process.poll() is None:
            try:
                self.send({'type': 'shutdown'})
                self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            stream.close()

    def send(self, value):
        self.process.stdin.write((json.dumps(value, separators=(',', ':')) + '\n').encode())
        self.process.stdin.flush()

    def receive(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=5):
                raise AssertionError('AST protocol timed out waiting for a frame')
        line = self.process.stdout.readline(262145)
        if not line or len(line) > 262144:
            raise AssertionError('AST protocol closed or emitted an oversized frame')
        return json.loads(line)

    def hello(self):
        self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'ast',
                   'extension_version': '1.1.0', 'generation': 7, 'capabilities': []})
        return self.receive()

    def invoke(self, arguments=None, tool='ast_grep'):
        frame = {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'ast',
                 'extension_version': '1.1.0', 'generation': 7, 'id': 1, 'tool': tool,
                 'kind': 'tool', 'command_id': '', 'thread_id': 'thread-ast', 'run_id': 'run-ast',
                 'epoch': 2, 'operation_id': 'operation-ast', 'call_id': 'call-ast',
                 'arguments': arguments or {'pat': 'return $VALUE', 'path': 'first.ts'}}
        self.send(frame)
        return frame, self.receive()


def response_for(invocation, stdout):
    return {**{key: invocation[key] for key in IDENTITY_KEYS}, 'type': 'service_response',
            'request_id': 'ast-query-1', 'ok': True,
            'result': {'request_id': 'ast-query-1', 'service': 'process.readonly',
                       'receipt_id': 'fixture-receipt', 'is_error': False,
                       'output': {'stdout': stdout, 'stderr': '', 'exit_code': 0,
                                  'timed_out': False, 'truncated': False}}}


class PackagedAstTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ast-plugin-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.workspace = self.base / 'workspace'
        self.workspace.mkdir()
        (self.workspace / 'first.ts').write_text('function first() {\n  return alpha;\n}\nfunction second() {\n  return beta + 1;\n}\n')
        (self.workspace / 'second.ts').write_text('function third() { return gamma; }\n')
        (self.base / 'outside.ts').write_text('function outside() { return secret; }\n')

    def query(self, **arguments):
        result = worker(self.workspace, {'pat': 'return $VALUE', 'path': 'first.ts', **arguments})
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertLessEqual(len(result.stdout.encode()), 65537)
        return json.loads(result.stdout)

    def reject(self, arguments, code):
        result = worker(self.workspace, arguments)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['error'], code, result.stdout)

    def test_real_structural_matches_hashlines_and_metavariables(self):
        before = (self.workspace / 'first.ts').read_bytes()
        result = self.query()
        self.assertEqual((result['match_count'], result['visible_count'], result['file_count']), (2, 2, 1))
        self.assertEqual([item['line'] for item in result['matches']], [2, 5])
        self.assertEqual([item['path'] for item in result['matches']], ['first.ts', 'first.ts'])
        self.assertIn('VALUE=alpha', result['matches'][0]['meta'])
        self.assertRegex(result['content'], r'\[first\.ts#[0-9A-F]{4}\]')
        self.assertEqual((self.workspace / 'first.ts').read_bytes(), before)

    def test_pagination_keeps_total_and_returns_only_requested_slice(self):
        result = self.query(skip=1)
        self.assertEqual((result['match_count'], result['visible_count']), (2, 1))
        self.assertIn('beta + 1', result['matches'][0]['text'])

    def test_large_skip_is_bounded_and_empty(self):
        result = self.query(skip=1_000_000_000)
        self.assertEqual((result['match_count'], result['visible_count']), (2, 0))
        self.assertEqual(result['matches'], [])

    def test_no_matches_is_success(self):
        result = self.query(pat='throw $VALUE')
        self.assertEqual((result['match_count'], result['visible_count']), (0, 0))
        self.assertEqual(result['content'], 'No matches found')

    def test_glob_and_semicolon_select_real_files(self):
        for selection in ['*.ts', 'first.ts;second.ts']:
            with self.subTest(selection=selection):
                result = self.query(path=selection)
                self.assertEqual((result['match_count'], result['file_count']), (3, 2))

    def test_parent_and_absolute_escape_are_rejected(self):
        for path in ['../outside.ts', '../*.ts', str(self.base / 'outside.ts')]:
            with self.subTest(path=path):
                self.reject({'pat': 'return $VALUE', 'path': path}, 'workspace.path_escape')

    def test_symlink_escape_is_rejected(self):
        (self.workspace / 'outside-link.ts').symlink_to(self.base / 'outside.ts')
        self.reject({'pat': 'return $VALUE', 'path': 'outside-link.ts'}, 'workspace.path_escape')

    def test_invalid_pattern_skip_and_unknown_argument_are_rejected(self):
        for arguments, code in [
            ({'pat': ''}, 'tool.ast_grep_pattern'),
            ({'pat': 12}, 'tool.ast_grep_argument'),
            ({'pat': 'return \x00'}, 'tool.ast_grep_argument'),
            ({'pat': 'return $VALUE', 'path': 'first.ts\x00'}, 'tool.ast_grep_argument'),
            ({'pat': 'x', 'skip': -1}, 'tool.ast_grep_skip'),
            ({'pat': 'x', 'skip': 1.5}, 'tool.ast_grep_argument'),
            ({'pat': 'x', 'shell': True}, 'tool.ast_grep_argument'),
            ({'pat': 'x', 'path': ';'.join(['first.ts'] * 33)}, 'tool.ast_grep_path_limit'),
        ]:
            with self.subTest(arguments=arguments):
                self.reject(arguments, code)

    def test_large_real_match_is_rejected_at_reply_limit(self):
        (self.workspace / 'large.ts').write_text('function huge() { return "' + 'x' * 70000 + '"; }\n')
        self.reject({'pat': 'return $VALUE', 'path': 'large.ts'}, 'tool.ast_grep_output_limit')

    def test_worker_input_limit_is_terminal(self):
        result = worker(self.workspace, {'pat': 'x' * 20000})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['error'], 'tool.ast_grep_input_limit')

    def test_worker_failure_diagnostic_is_independently_bounded(self):
        result = worker(self.workspace, {'pat': 'x', 'k' * 8000: True})
        self.assertEqual(result.returncode, 2)
        value = json.loads(result.stdout)
        self.assertEqual(value['error'], 'tool.ast_grep_argument')
        self.assertLessEqual(len(value['message'].encode()), 4096)
        self.assertLessEqual(len(result.stdout.encode()), 65537)

    def test_handshake_and_real_worker_result_remain_correlated(self):
        with Protocol(self.workspace) as protocol:
            ready = protocol.hello()
            self.assertEqual(ready['type'], 'ready')
            self.assertEqual(ready['capabilities'], [])
            self.assertEqual([tool['name'] for tool in ready['tools']], ['ast_grep', 'ast_edit'])
            self.assertEqual(ready['commands'], [])
            invocation, request = protocol.invoke()
            self.assertEqual(request['service'], 'process.readonly')
            self.assertEqual(request['arguments']['executable'], 'bin/ast-plugin')
            self.assertEqual(request['arguments']['timeout_ms'], 30000)
            self.assertEqual(request['arguments']['arguments'][0], '--query-worker')
            arguments = json.loads(request['arguments']['arguments'][1])
            result = worker(self.workspace, arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            protocol.send(response_for(invocation, result.stdout))
            reply = protocol.receive()
            self.assertTrue(reply['ok'])
            self.assertEqual(reply['result']['match_count'], 2)
            for key in IDENTITY_KEYS:
                self.assertEqual(reply[key], invocation[key])

    def test_service_identity_and_request_id_mismatch_terminate(self):
        for field, replacement in [('run_id', 'other-run'), ('request_id', 'other-request')]:
            with self.subTest(field=field), Protocol(self.workspace) as protocol:
                protocol.hello()
                invocation, unused = protocol.invoke()
                response = response_for(invocation, '{}')
                response[field] = replacement
                protocol.send(response)
                self.assertEqual(protocol.process.wait(timeout=5), 3)

    def test_service_receipt_is_required(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            invocation, unused = protocol.invoke()
            response = response_for(invocation, '{}')
            response['result']['receipt_id'] = ''
            protocol.send(response)
            reply = protocol.receive()
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['error'], 'ast.service_identity')

    def test_truncated_or_malformed_worker_output_cannot_succeed(self):
        for truncated, stdout, code in [(True, '{}', 'tool.ast_grep_output_limit'),
                                       (False, 'not-json', 'tool.ast_grep_protocol')]:
            with self.subTest(truncated=truncated), Protocol(self.workspace) as protocol:
                protocol.hello()
                invocation, unused = protocol.invoke()
                response = response_for(invocation, stdout)
                response['result']['output']['truncated'] = truncated
                protocol.send(response)
                reply = protocol.receive()
                self.assertFalse(reply['ok'])
                self.assertEqual(reply['result']['error'], code)

    def test_cancelled_invocation_rejects_late_service_response(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            invocation, unused = protocol.invoke()
            protocol.send({**invocation, 'type': 'cancel'})
            self.assertEqual(protocol.receive()['type'], 'cancelled')
            protocol.send(response_for(invocation, '{}'))
            self.assertEqual(protocol.process.wait(timeout=5), 3)

    def edit(self, **arguments):
        return worker(self.workspace, {'ops': [{'pat': 'return $VALUE', 'out': 'return changed;'}],
                                       'paths': ['first.ts'], **arguments}, editing=True)

    def test_edit_real_engine_proposes_exact_replacements_without_writing(self):
        original = {path.name: path.read_bytes() for path in self.workspace.glob('*.ts')}
        result = self.edit(paths=['*.ts'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertFalse(value['applied'])
        self.assertEqual((value['total_replacements'], value['files_touched']), (3, 2))
        proposal = value['proposal']
        self.assertEqual(set(proposal), {'schema', 'operations'})
        self.assertEqual(proposal['schema'], 'axyndra.file-change-proposal/v1')
        for operation in proposal['operations']:
            self.assertEqual(set(operation), {'kind', 'path', 'expected_content', 'content'})
            self.assertEqual(operation['kind'], 'replace')
            self.assertEqual(operation['expected_content'].encode(), original[operation['path']])
            self.assertIn('return changed;', operation['content'])
        self.assertEqual({path.name: path.read_bytes() for path in self.workspace.glob('*.ts')}, original)

    def test_edit_multiple_patterns_keep_utf8_byte_offsets(self):
        original = 'const title = "你好";\nfunction first() { return alpha; }\nfunction next() { return beta; }\n'
        (self.workspace / 'unicode.ts').write_text(original)
        result = self.edit(paths=['unicode.ts'], ops=[{'pat': 'return alpha', 'out': 'return gamma;'},
                                                    {'pat': 'return beta', 'out': 'return delta;'}])
        self.assertEqual(result.returncode, 0, result.stdout)
        operation = json.loads(result.stdout)['proposal']['operations'][0]
        self.assertEqual(operation['expected_content'], original)
        self.assertEqual(operation['content'], original.replace('return alpha;', 'return gamma;').replace('return beta;', 'return delta;'))
        self.assertEqual((self.workspace / 'unicode.ts').read_text(), original)

    def test_edit_duplicate_and_overlapping_patterns_are_rejected(self):
        cases = [([{'pat': 'return $A', 'out': 'return x;'}, {'pat': 'return $A', 'out': 'return y;'}], 'tool.ast_edit_duplicate'),
                 ([{'pat': 'return $A', 'out': 'return x;'}, {'pat': 'alpha', 'out': 'y'}], 'tool.ast_edit_overlap')]
        original = (self.workspace / 'first.ts').read_bytes()
        for ops, code in cases:
            with self.subTest(code=code):
                result = self.edit(ops=ops)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)['error'], code)
                self.assertEqual((self.workspace / 'first.ts').read_bytes(), original)

    def test_edit_empty_result_does_not_create_a_plan(self):
        result = self.edit(ops=[{'pat': 'throw $VALUE', 'out': 'return x;'}])
        self.assertEqual(result.returncode, 0, result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(value['content'], 'No replacements made')
        self.assertEqual(value['total_replacements'], 0)
        self.assertNotIn('proposal', value)

    def test_edit_rejects_paths_symlinks_and_source_claims(self):
        (self.workspace / 'outside-link.ts').symlink_to(self.base / 'outside.ts')
        for arguments, code in [({'paths': ['../outside.ts']}, 'workspace.path_escape'),
                                ({'paths': ['outside-link.ts']}, 'workspace.path_escape'),
                                ({'source': {'kind': 'program'}}, 'tool.ast_edit_argument'),
                                ({'ops': [{'pat': 'x', 'out': '\x00'}]}, 'tool.ast_edit_argument')]:
            with self.subTest(arguments=arguments):
                result = self.edit(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)['error'], code)

    def test_edit_32_files_succeed_but_33_are_rejected_without_changes(self):
        folder = self.workspace / 'many'
        folder.mkdir()
        for index in range(32):
            (folder / f'{index}.ts').write_text('function f() { return before; }\n')
        result = self.edit(paths=['many/*.ts'])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(json.loads(result.stdout)['proposal']['operations']), 32)
        (folder / '32.ts').write_text('function f() { return before; }\n')
        result = self.edit(paths=['many/*.ts'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['error'], 'tool.ast_edit_limit')
        self.assertTrue(all('return before;' in path.read_text() for path in folder.glob('*.ts')))

    def test_edit_proposal_size_is_a_failure_not_truncated_application(self):
        original = '// ' + 'x' * 40000 + '\nfunction f() { return before; }\n'
        (self.workspace / 'large.ts').write_text(original)
        result = self.edit(paths=['large.ts'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['error'], 'tool.ast_edit_limit')
        self.assertNotIn('proposal', json.loads(result.stdout))
        self.assertEqual((self.workspace / 'large.ts').read_text(), original)

    def edit_protocol_worker(self, protocol):
        protocol.hello()
        arguments = {'ops': [{'pat': 'return $VALUE', 'out': 'return changed;'}], 'paths': ['first.ts']}
        invocation, request = protocol.invoke(arguments, tool='ast_edit')
        self.assertEqual(request['arguments']['arguments'][0], '--edit-worker')
        result = worker(self.workspace, arguments, editing=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        protocol.send(response_for(invocation, result.stdout))
        return invocation, protocol.receive()

    def plan_response(self, invocation):
        return {**{key: invocation[key] for key in IDENTITY_KEYS}, 'type': 'service_response',
                'request_id': 'ast-plan-1', 'ok': True,
                'result': {'request_id': 'ast-plan-1', 'service': 'file.plan.propose',
                           'receipt_id': 'fixture-plan-receipt', 'is_error': False,
                           'output': {'plan_ref': 'blob:sha256:fixture', 'plan_digest': 'fixture',
                                      'schema': 'axyndra.file-application-plan/v2', 'source': {'kind': 'plugin'}}}}

    def test_edit_protocol_requires_second_receipt_and_returns_host_plan(self):
        with Protocol(self.workspace) as protocol:
            invocation, request = self.edit_protocol_worker(protocol)
            self.assertEqual(request['service'], 'file.plan.propose')
            self.assertEqual(request['request_id'], 'ast-plan-1')
            self.assertEqual(set(request['arguments']), {'proposal'})
            self.assertNotIn('source', request['arguments']['proposal'])
            protocol.send(self.plan_response(invocation))
            reply = protocol.receive()
            self.assertTrue(reply['ok'])
            self.assertFalse(reply['result']['applied'])
            self.assertEqual(reply['result']['application_plan']['plan_digest'], 'fixture')
            self.assertNotIn('proposal', reply['result'])
            self.assertIn('apply_file_plan', reply['result']['content'])

    def test_edit_protocol_rejects_missing_plan_receipt(self):
        with Protocol(self.workspace) as protocol:
            invocation, unused = self.edit_protocol_worker(protocol)
            response = self.plan_response(invocation)
            response['result']['receipt_id'] = ''
            protocol.send(response)
            reply = protocol.receive()
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['result']['error'], 'ast.service_identity')

    def test_edit_cancel_during_plan_discards_late_response(self):
        with Protocol(self.workspace) as protocol:
            invocation, unused = self.edit_protocol_worker(protocol)
            protocol.send({**invocation, 'type': 'cancel'})
            self.assertEqual(protocol.receive()['type'], 'cancelled')
            protocol.send(self.plan_response(invocation))
            self.assertEqual(protocol.process.wait(timeout=5), 3)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    arguments = parser.parse_args()
    PACKAGE = arguments.package.resolve()
    if not (PACKAGE / 'bin/ast-plugin').is_file() or not (PACKAGE / 'bin/ast-grep').is_file():
        parser.error('package must contain both compiled native plugin and real ast-grep engine')
    unittest.main(argv=['ast-plugin-check'], verbosity=2)
