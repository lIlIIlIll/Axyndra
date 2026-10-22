#!/usr/bin/env python3
"""Real packaged workers and wire protocol; Product owns CAS/approval evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest
from unittest.mock import patch

PACKAGE = None
KEYS = ['protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
        'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id']


def environment():
    value = os.environ.copy()
    for key in ['LD_LIBRARY_PATH', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH', 'AXYNDRA_SDK_ROOT', 'RIPGREP_CONFIG_PATH']:
        value.pop(key, None)
    return value


def worker(root, tool, arguments, env=None):
    return subprocess.run([str(PACKAGE / 'bin/workspace-plugin'), '--worker', tool,
                           json.dumps(arguments, ensure_ascii=False, separators=(',', ':'))],
                          cwd=root, env=env or environment(), capture_output=True, text=True, timeout=35)


class Protocol:
    def __init__(self, root):
        self.process = subprocess.Popen([str(PACKAGE / 'bin/workspace-plugin')], cwd=root,
                                        env=environment(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def __enter__(self):
        return self
    def __exit__(self, *unused):
        if self.process.poll() is None:
            try:
                self.send({'type': 'shutdown'}); self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.kill(); self.process.wait(timeout=5)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            stream.close()
    def send(self, value):
        self.process.stdin.write((json.dumps(value, separators=(',', ':')) + '\n').encode()); self.process.stdin.flush()
    def receive(self, eof=False):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(5):
                raise AssertionError('workspace endpoint did not produce a bounded reply')
        line = self.process.stdout.readline(262145)
        if eof:
            if line:
                raise AssertionError('invalid frame unexpectedly produced ' + repr(line[:200]))
            self.process.wait(timeout=5)
            return None
        if not line or len(line) > 262144 or not line.endswith(b'\n'):
            raise AssertionError('invalid workspace reply frame')
        return json.loads(line)
    def hello(self):
        self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'workspace',
                   'extension_version': '1.0.0', 'generation': 7, 'capabilities': ['process.readview']})
        return self.receive()
    def invoke(self, tool='read', arguments=None, **updates):
        value = {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'workspace',
                 'extension_version': '1.0.0', 'generation': 7, 'id': 'invoke-1', 'kind': 'tool',
                 'tool': tool, 'command_id': '', 'thread_id': 'workspace-thread', 'run_id': 'workspace-run',
                 'epoch': 2, 'operation_id': 'workspace-op', 'call_id': 'workspace-call',
                 'arguments': arguments if arguments is not None else {'path': 'first.txt'}}
        value.update(updates); self.send(value); return value


def response(frame, output=None, *, service='process.readview', request='workspace-query-1', receipt='actual-fixture-receipt'):
    return {**{key: frame[key] for key in KEYS}, 'type': 'service_response', 'request_id': request, 'ok': True,
            'result': {'request_id': request, 'service': service, 'receipt_id': receipt, 'is_error': False,
                       'output': output if output is not None else {'stdout': '{}\n', 'stderr': '', 'exit_code': 0, 'timed_out': False, 'truncated': False}}}


def parameter_metadata(value):
    if isinstance(value,dict):
        return {'type':'object','fields':[{'name':name,'node':parameter_metadata(item)} for name,item in value.items()]}
    if isinstance(value,list):
        return {'type':'list','items':[parameter_metadata(item) for item in value]}
    encoded=json.dumps(value,ensure_ascii=False,separators=(',',':'))
    raw=value if isinstance(value,str) else encoded
    kind='text' if isinstance(value,str) else 'null' if value is None else 'boolean' if isinstance(value,bool) else 'number'
    result={'type':kind,'utf8_bytes':len(raw.encode()),'sha256':hashlib.sha256(raw.encode()).hexdigest(),
            'has_nul':isinstance(value,str) and '\0' in value}
    if kind!='text' or len(encoded.encode())<=8192:result['value']=value
    return result


def parameter_input(value):
    encoded=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
    return {'schema':'axyndra.read-view-parameter-input/v1','reference':{
        'binding':{'thread_id':'workspace-thread','run_id':'workspace-run','epoch':2,'call_id':'workspace-call',
                   'tool_name':'plugin.axyndra:workspace.write','plugin':'axyndra:workspace','contribution':'write',
                   'package_digest':'sha256:'+hashlib.sha256(b'actual-package-fixture').hexdigest(),'generation':'7',
                   'configuration_digest':hashlib.sha256(b'actual-operator-fixture').hexdigest()},
        'input_bytes':len(encoded),'input_sha256':hashlib.sha256(encoded).hexdigest(),'metadata':parameter_metadata(value)}}


class WorkspacePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='workspace-plugin-check-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        # Preserve fixture .gitignore coverage without inheriting an operator's
        # global exclusion of the disk-backed temporary checkout.
        home = self.base / 'home'; home.mkdir()
        config = self.base / 'config'; config.mkdir()
        isolated = patch.dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config),
                              GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        isolated.start(); self.addCleanup(isolated.stop)
        self.root = self.base / 'workspace'; self.root.mkdir()
        (self.root / 'first.txt').write_text('before\n', encoding='utf-8')
        (self.root / 'second.txt').write_text('alpha\nbeta\ngamma\n', encoding='utf-8')
        (self.root / '.git').mkdir()
        (self.root / '.gitignore').write_text('ignored.txt\n')
        (self.root / 'ignored.txt').write_text('before ignored\n')
        (self.root / '.hidden.txt').write_text('hidden\n')
        (self.base / 'outside.txt').write_text('outside\n')
    def run_tool(self, tool, value):
        result = worker(self.root, tool, value)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLessEqual(len(result.stdout.encode()), 65537)
        return json.loads(result.stdout)
    def reject(self, tool, value, code):
        result = worker(self.root, tool, value)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['error'], code)
    def patch(self, filename, operations):
        text = self.run_tool('read', {'path': filename})['content'].split('\n')[0]
        return text + '\n' + operations
    def test_full_file_anchor_and_default_lines(self):
        value = self.run_tool('read', {'path': 'first.txt'})
        self.assertEqual(value['content'], '[first.txt#F27C]\n1:before\n2:')
        self.assertEqual((value['bytes'], value['returned_bytes'], value['offset']), (7, 7, 1))
    def test_range_uses_full_snapshot_anchor(self):
        whole = self.run_tool('read', {'path': 'second.txt'})
        value = self.run_tool('read', {'path': 'second.txt:L2-L3'})
        self.assertEqual(value['content'].split('\n')[0], whole['content'].split('\n')[0])
        self.assertTrue(value['content'].endswith('\n2:beta\n3:gamma'))
    def test_raw_and_plus_range(self):
        value = self.run_tool('read', {'path': 'second.txt:L2+1:raw'})
        self.assertEqual(value['content'], 'beta'); self.assertTrue(value['truncated'])
    def test_explicit_range_nullable_default(self):
        self.assertEqual(self.run_tool('read', {'path': 'second.txt:raw', 'offset': 2, 'limit': 1})['content'], 'beta')
        self.assertEqual(self.run_tool('read', {'path': 'first.txt:raw', 'offset': None, 'limit': None})['content'], 'before\n')
    def test_offset_beyond_end_and_invalid_range(self):
        self.assertEqual(self.run_tool('read', {'path': 'first.txt:raw', 'offset': 999})['content'], '')
        self.reject('read', {'path': 'first.txt', 'offset': 0}, 'tool.read_range')
    def test_directory_sorted(self):
        (self.root / 'dir').mkdir()
        value = self.run_tool('read', {'path': '.'})
        self.assertEqual(value['entries'].splitlines(), sorted(value['entries'].splitlines()))
        self.assertIn('dir/', value['entries']); self.assertEqual(value['count'], value['total_count'])
    def test_utf8_and_json_escaping_bound(self):
        (self.root / 'large.txt').write_text(('雪\\\"\t' * 20000) + '\n', encoding='utf-8')
        value = self.run_tool('read', {'path': 'large.txt:raw'})
        self.assertTrue(value['truncated']); self.assertNotIn('\ufffd', value['content'])
        self.assertEqual(value['returned_bytes'], len(value['content'].encode()))
    def test_binary_rejected(self):
        (self.root / 'binary').write_bytes(b'a\0b')
        self.reject('read', {'path': 'binary'}, 'tool.read_binary')
    def test_lexical_and_symlink_escape_rejected(self):
        self.reject('read', {'path': '../outside.txt'}, 'workspace.path_escape')
        (self.root / 'link').symlink_to(self.base / 'outside.txt')
        self.reject('read', {'path': 'link'}, 'workspace.path_escape')
    def test_special_sensitive_targets_not_silently_authorized(self):
        (self.root / '.env').write_text('SECRET=private')
        self.reject('read', {'path': '.env'}, 'workspace.sensitive_path_unsupported')
        self.reject('read', {'path': 'blob://digest'}, 'workspace.path_unsupported')
        self.reject('read', {'path': 'first.txt', 'destination': 'x'}, 'artifact.export_arguments')
    def test_real_grep_case_regex_skip(self):
        self.assertEqual(self.run_tool('grep', {'pattern': 'BEF.RE', 'path': 'first.txt'})['count'], 1)
        self.assertFalse(self.run_tool('grep', {'pattern': 'BEFORE', 'path': 'first.txt', 'case': True})['found'])
        value = self.run_tool('grep', {'pattern': 'a', 'path': 'second.txt', 'skip': 1})
        self.assertEqual(value['count'], 2); self.assertIn('2:beta', value['matches'])
    def test_real_grep_semicolon_glob_count(self):
        value = self.run_tool('grep', {'pattern': 'before|beta', 'path': 'first.txt;second.txt', 'count': True})
        self.assertEqual(value['total'], 2); self.assertEqual(len(value['files']), 2)
        # Explicit positive globs override ignore files in ripgrep, including
        # the old Product argv contract. Do not test an invented hidden policy.
        self.assertEqual(self.run_tool('grep', {'pattern': 'before', 'path': '*.txt', 'count': True})['total'], 2)
    def test_gitignore_and_hidden_glob(self):
        default = self.run_tool('glob', {'pattern': '.'})['paths']
        self.assertNotIn('ignored.txt', default); self.assertNotIn('.hidden.txt', default)
        value = self.run_tool('glob', {'pattern': '.', 'hidden': True, 'gitignore': False})['paths']
        self.assertIn('ignored.txt', value); self.assertIn('.hidden.txt', value)
        explicit = self.run_tool('glob', {'pattern': '*.txt'})['paths']
        self.assertIn('ignored.txt', explicit); self.assertIn('.hidden.txt', explicit)
    def test_count_files_exact_limit_and_overflow_preserve_total(self):
        directory = self.root / 'counts'; directory.mkdir()
        for index in range(1000): (directory / f'{index:04}.txt').write_text('COUNT_MATCH\n')
        exact = self.run_tool('grep', {'pattern': 'COUNT_MATCH', 'path': 'counts', 'count': True})
        self.assertEqual((len(exact['files']), exact['total'], exact['truncated']), (1000, 1000, False))
        (directory / '1000.txt').write_text('COUNT_MATCH\n')
        overflow = self.run_tool('grep', {'pattern': 'COUNT_MATCH', 'path': 'counts', 'count': True})
        self.assertEqual((len(overflow['files']), overflow['total'], overflow['truncated']), (1000, 1001, True))
    def test_glob_clamps_limit(self):
        for i in range(205): (self.root / f'file-{i:03}.test').write_text('x')
        value = self.run_tool('glob', {'pattern': '*.test', 'limit': 999})
        self.assertEqual(value['count'], 200); self.assertTrue(value['truncated'])
    def test_rg_config_and_shell_metacharacters_cannot_execute(self):
        config = self.base / 'malicious.rg'; config.write_text('--pre\n/bin/false\n')
        env = environment(); env['RIPGREP_CONFIG_PATH'] = str(config)
        result = worker(self.root, 'grep', {'pattern': 'before', 'path': 'first.txt'}, env)
        self.assertEqual(result.returncode, 0, result.stdout)
        literal = 'semi;$(touch SENTINEL).txt'; (self.root / literal).write_text('literal')
        self.assertEqual(self.run_tool('read', {'path': literal + ':raw'})['content'], 'literal')
        self.assertFalse((self.root / 'SENTINEL').exists())
    def test_hashline_replace_proposal_and_no_write(self):
        value = self.run_tool('edit', {'input': '[first.txt#F27C]\nSWAP 1:\n+after'})
        op = value['proposal']['operations'][0]
        self.assertEqual(op, {'kind': 'replace', 'path': 'first.txt', 'expected_content': 'before\n', 'content': 'after\n'})
        self.assertFalse(value['applied']); self.assertEqual((self.root / 'first.txt').read_text(), 'before\n')
    def test_all_documented_hashline_insert_delete_range_operations(self):
        for operation, expected in [('SWAP 1..=2:\n+new', 'new\ngamma\n'), ('DEL 2', 'alpha\ngamma\n'),
                                    ('INS.HEAD:\n+head', 'head\nalpha\nbeta\ngamma\n'),
                                    ('INS.PRE 2:\n+new', 'alpha\nnew\nbeta\ngamma\n'),
                                    ('INS.POST 2:\n+new', 'alpha\nbeta\nnew\ngamma\n'),
                                    ('INS.TAIL:\n+tail', 'alpha\nbeta\ngamma\n\ntail')]:
            value = self.run_tool('edit', {'input': self.patch('second.txt', operation)})
            self.assertEqual(value['proposal']['operations'][0]['content'], expected)
    def test_multifile_preflight_and_stale_no_partial_effect(self):
        patch = '[first.txt#F27C]\nSWAP 1:\n+after\n' + self.patch('second.txt', 'DEL 2')
        value = self.run_tool('edit', {'input': patch}); self.assertEqual(len(value['proposal']['operations']), 2)
        (self.root / 'second.txt').write_text('concurrent\n')
        self.reject('edit', {'input': patch}, 'edit.stale_anchor')
        self.assertEqual((self.root / 'first.txt').read_text(), 'before\n')
    def test_hashline_stale_overlap_bad_range_and_duplicate_alias(self):
        self.reject('edit', {'input': '[first.txt#0000]\nDEL 1'}, 'edit.stale_anchor')
        for operation in ['SWAP 1:\n+x\nDEL 1', 'SWAP 1.=2:\n+x', 'DEL 99']:
            self.reject('edit', {'input': self.patch('second.txt', operation)}, 'edit.invalid_hashline')
        self.reject('edit', {'input': '[first.txt#F27C]\nDEL 1\n[./first.txt#F27C]\nDEL 1'}, 'edit.invalid_hashline')
    def test_write_create_replace_empty_and_noop_plans(self):
        create = self.run_tool('write', {'path': 'new.txt', 'content': ''})
        self.assertEqual(create['proposal']['operations'], [{'kind': 'create', 'path': 'new.txt', 'content': ''}])
        self.assertFalse((self.root / 'new.txt').exists())
        replace = self.run_tool('write', {'path': 'first.txt', 'content': 'replacement'})
        self.assertEqual(replace['proposal']['operations'][0]['expected_content'], 'before\n')
        self.assertNotIn('proposal', self.run_tool('write', {'path': 'first.txt', 'content': 'before\n'}))
    def test_input_and_proposal_limits(self):
        self.reject('read', {'path': 'x' * 17000}, 'workspace.input_limit')
        self.reject('write', {'path': 'new.txt', 'content': 'x' * 32769}, 'write.content_too_large')
        (self.root / 'proposal.txt').write_text('x' * 50000 + '\n')
        self.reject('edit', {'input': self.patch('proposal.txt', 'INS.HEAD:\n+prefix')}, 'workspace.output_limit')
    def frozen_write(self, value):
        (self.root / '.axyndra-worker-input.json').write_text(json.dumps(value, separators=(',', ':')), encoding='utf-8')
        result = subprocess.run([str(PACKAGE / 'bin/workspace-plugin'), '--view-worker-file', 'write'],
                                cwd=self.root, env=environment(), capture_output=True, text=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLessEqual(len(result.stdout.encode()), 200705)
        return json.loads(result.stdout)
    def test_full_write_escaping_uses_frozen_input_and_digest_cas_without_effect(self):
        import hashlib
        before = '\x01' * 32768
        after = '\x02' * 32768
        (self.root / 'replace.txt').write_text(before)
        value = self.frozen_write({'path': 'replace.txt', 'content': after})
        operation = value['proposal']['operations'][0]
        self.assertEqual(set(operation), {'kind', 'path', 'content', 'expected_sha256', 'expected_bytes'})
        self.assertEqual(operation['expected_sha256'], hashlib.sha256(before.encode()).hexdigest())
        self.assertEqual(operation['expected_bytes'], 32768)
        self.assertEqual(operation['content'], after)
        self.assertEqual((self.root / 'replace.txt').read_text(), before)
        self.assertFalse(value['applied'])
        create = self.frozen_write({'path': 'new.txt', 'content': '"' * 32768})
        self.assertEqual(create['proposal']['operations'][0]['content'], '"' * 32768)
        self.assertFalse((self.root / 'new.txt').exists())
    def test_resource_reference_returns_only_an_independent_root_request(self):
        reference = 'blob:sha256:' + 'a' * 64
        artifact = self.run_tool('read', {'path': reference})
        self.assertEqual(artifact['resource_request'], {'schema': 'axyndra.resource-request/v1', 'tool': 'read_resource',
            'arguments': {'reference': reference, 'offset': 0, 'limit': 1048576, 'unit': 'bytes'}})
        export = self.run_tool('read', {'path': reference, 'destination': 'export.txt'})
        self.assertEqual(export['resource_request']['tool'], 'export_artifact')
        self.assertFalse((self.root / 'export.txt').exists())
        uri = self.run_tool('write', {'path': 'memory://actual', 'content': 'unapplied'})
        self.assertEqual(uri['resource_request']['tool'], 'write_resource')
        self.assertFalse(uri['applied'])
        self.reject('write', {'path': reference, 'content': 'x'}, 'artifact.immutable')
        self.reject('read', {'path': reference, 'destination': '../outside'}, 'workspace.path_unsupported')
    def test_large_write_preparation_freezes_data_outside_os_argv(self):
        with Protocol(self.root) as wire:
            wire.hello()
            wire.invoke('write', {'input': {'path': 'new.txt', 'content': '\x01' * 32768}}, kind='prepare', operation_id='')
            prepared = wire.receive()
            self.assertTrue(prepared['ok'])
            request = prepared['result']['intents'][0]['request']
            self.assertEqual(request['arguments'], ['--view-worker-file', 'write'])
            self.assertEqual(request['input']['content'], '\x01' * 32768)
            self.assertFalse((self.root / 'new.txt').exists())
    def test_hello_declares_five_read_authority_tools(self):
        with Protocol(self.root) as wire:
            ready = wire.hello(); self.assertEqual([t['name'] for t in ready['tools']], ['read', 'grep', 'glob', 'edit', 'write'])
            self.assertEqual(ready['capabilities'], ['process.readview'])
    def test_real_worker_roundtrip_through_matching_receipt(self):
        with Protocol(self.root) as wire:
            wire.hello()
            prepared = wire.invoke(arguments={'input': {'path': 'first.txt'}}, kind='prepare', operation_id='', id='prepare-1')
            pure = wire.receive(); self.assertTrue(pure['ok']); intent = pure['result']['intents'][0]
            self.assertEqual(intent['resources'], [{'source': 'first.txt', 'path': 'target', 'mode': 'auto'}])
            frame = wire.invoke(); request = wire.receive()
            self.assertEqual(request['service'], 'process.readview')
            self.assertEqual(request['arguments'], {'intent_id': 'workspace-query-1'})
            args = intent['request']; self.assertEqual(args['executable'], 'bin/workspace-plugin')
            (self.root / 'target').write_bytes((self.root / 'first.txt').read_bytes())
            actual = subprocess.run([str(PACKAGE / args['executable']), *args['arguments']], cwd=self.root, env=environment(), capture_output=True, text=True, timeout=35)
            wire.send(response(frame, {'stdout': actual.stdout, 'stderr': actual.stderr, 'exit_code': actual.returncode, 'timed_out': False, 'truncated': False}))
            value = wire.receive(); self.assertTrue(value['ok']); self.assertIn('#F27C]', value['result']['content'])
    def test_edit_two_receipts_and_plan_identity(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke('edit', {'input': '[first.txt#F27C]\nSWAP 1:\n+after'}); wire.receive()
            actual = worker(self.root, 'edit', frame['arguments'])
            wire.send(response(frame, {'stdout': actual.stdout, 'stderr': '', 'exit_code': actual.returncode, 'timed_out': False, 'truncated': False}))
            plan = wire.receive(); self.assertEqual(plan['service'], 'file.plan.propose'); self.assertNotIn('source', plan['arguments']['proposal'])
            summary = {'plan_ref': 'blob://fixture', 'plan_digest': 'a' * 64}
            wire.send(response(frame, summary, service='file.plan.propose', request='workspace-plan-1', receipt='plan-receipt'))
            final = wire.receive(); self.assertTrue(final['ok']); self.assertEqual(final['result']['application_plan'], summary)
            self.assertFalse(final['result']['applied']); self.assertNotIn('proposal', final['result'])
            self.assertEqual((self.root / 'first.txt').read_text(), 'before\n')
    def test_missing_receipt_fails(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke(); wire.receive(); wire.send(response(frame, receipt=''))
            value = wire.receive(); self.assertFalse(value['ok']); self.assertEqual(value['result']['error'], 'workspace.service_identity')
    def test_late_reply_after_cancel_is_rejected(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke(); wire.receive(); wire.send({**frame, 'type': 'cancel'})
            self.assertEqual(wire.receive()['type'], 'cancelled'); wire.send(response(frame)); wire.receive(eof=True)
    def test_wrong_epoch_cannot_complete_current_invocation(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke(); wire.receive(); value = response(frame); value['epoch'] += 1
            wire.send(value); wire.receive(eof=True)
    def test_real_opaque_id_required(self):
        for updates in [{'id': 1}, {'epoch': 0}, {'operation_id': ''}, {'generation': 99}]:
            with Protocol(self.root) as wire:
                wire.hello(); wire.invoke(**updates); wire.receive(eof=True)
    def test_transport_failure_not_business_success(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke(); wire.receive()
            value = response(frame); value['ok'] = False; value['error'] = {'code': 'extension.cancelled', 'message': 'cancelled'}
            wire.send(value); self.assertFalse(wire.receive()['ok'])
    def test_truncated_worker_never_mints_partial_plan(self):
        with Protocol(self.root) as wire:
            wire.hello(); frame = wire.invoke('write', {'path': 'new.txt', 'content': 'x'}); wire.receive()
            value = response(frame); value['result']['output']['truncated'] = True
            wire.send(value); final = wire.receive(); self.assertEqual(final['type'], 'result'); self.assertFalse(final['ok'])

    def test_prepare_is_powerless_for_missing_and_sensitive_resources(self):
        for path in ['not-present.txt', '/outside/.env']:
            with Protocol(self.root) as wire:
                wire.hello(); wire.invoke(arguments={'input': {'path': path}}, kind='prepare', operation_id='')
                response = wire.receive()
                self.assertEqual(response['type'], 'result'); self.assertTrue(response['ok'])
                resource = response['result']['intents'][0]['resources'][0]
                self.assertEqual(resource, {'source': path, 'path': 'target', 'mode': 'auto'})
                self.assertFalse((self.root / 'target').exists())
    def test_prepare_cannot_use_tool_operation_identity(self):
        with Protocol(self.root) as wire:
            wire.hello(); wire.invoke(arguments={'input': {'path': 'first.txt'}}, kind='prepare')
            wire.receive(eof=True)
    def test_explicit_host_view_retains_original_outside_hashline_path(self):
        (self.root / 'target').write_text('approved only\n', encoding='utf-8')
        result = subprocess.run([str(PACKAGE / 'bin/workspace-plugin'), '--view-worker', 'read',
                                 json.dumps({'path': '/operator-approved/.env'})], cwd=self.root,
                                env=environment(), capture_output=True, text=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(value['path'], '/operator-approved/.env')
        self.assertTrue(value['content'].startswith('[/operator-approved/.env#'))
        self.assertIn('approved only', value['content'])


    def test_referenced_preparation_is_compact_and_actual_worker_revalidates_full_content(self):
        original={'path':'new.txt','content':'\x01'*32768}
        projected=parameter_input(original)
        self.assertLess(len(json.dumps(projected,separators=(',',':')).encode()),16384)
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
            prepared=wire.receive();self.assertTrue(prepared['ok'])
            request=prepared['result']['intents'][0]['request']
            self.assertEqual(request['input_reference'],projected['reference']);self.assertNotIn('input',request)
            self.assertEqual(request['arguments'],['--view-worker-file','write'])
            self.assertFalse((self.root/'new.txt').exists())
        for value,expected in [(original,None),({'path':'new.txt','content':'\x01'*32769},'write.content_too_large'),
                               ({'path':'new.txt','content':'bad\0content'},'workspace.argument')]:
            (self.root/'.axyndra-worker-input.json').write_text(json.dumps(value,separators=(',',':')),encoding='utf-8')
            actual=subprocess.run([str(PACKAGE/'bin/workspace-plugin'),'--view-worker-file','write'],cwd=self.root,
                                  env=environment(),capture_output=True,text=True,timeout=35)
            output=json.loads(actual.stdout)
            if expected is None:
                self.assertEqual(actual.returncode,0,actual.stderr);self.assertFalse(output['applied'])
            else:
                self.assertEqual(actual.returncode,2,actual.stderr);self.assertEqual(output['error'],expected)
            self.assertFalse((self.root/'new.txt').exists())

    def test_referenced_binding_cannot_cross_call_thread_run_epoch_or_generation(self):
        for key,value in [('call_id','other-call'),('thread_id','other-thread'),('run_id','other-run'),
                          ('epoch',3),('generation','8'),('tool_name','plugin.workspace.read'),
                          ('plugin','workspace'),('plugin','pi:workspace'),
                          ('tool_name','plugin.workspace.write'),('tool_name','plugin.axyndra:workspace.read')]:
            projected=parameter_input({'path':'new.txt','content':'x'*32768})
            projected['reference']['binding'][key]=value
            with Protocol(self.root) as wire:
                wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
                result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.prepare_invalid')
            self.assertFalse((self.root/'new.txt').exists())

    def test_referenced_unknown_duplicate_and_missing_fields_are_real_native_rejections(self):
        for value in [{'path':'new.txt','content':'x'*32768,'unexpected':{'content':'untrusted'}},
                      {'path':'new.txt'}, {'content':'x'*32768}]:
            projected=parameter_input(value)
            with Protocol(self.root) as wire:
                wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
                result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.argument')
            self.assertFalse((self.root/'new.txt').exists())
        projected=parameter_input({'path':'new.txt','content':'x'*32768})
        fields=projected['reference']['metadata']['fields'];fields.append(fields[0])
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
            result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.argument')
        self.assertFalse((self.root/'new.txt').exists())

    def test_referenced_metadata_preserves_exact_type_nul_and_32768_byte_business_boundary(self):
        for content,code in [(7,'workspace.prepare_invalid'),('bad\0content','workspace.argument'),
                             ('x'*32769,'write.content_too_large')]:
            with Protocol(self.root) as wire:
                wire.hello();wire.invoke('write',parameter_input({'path':'new.txt','content':content}),kind='prepare',operation_id='')
                result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],code)
            self.assertFalse((self.root/'new.txt').exists())
        projected=parameter_input({'path':'new.txt','content':'small'});projected['reference']['metadata']['fields'][1]['node']['utf8_bytes']=4
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
            result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.prepare_invalid')

    def test_original_prepare_wire_and_negative_grammar_remain_the_default(self):
        original={'path':'new.txt','content':'small'}
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',{'input':original},kind='prepare',operation_id='')
            result=wire.receive();self.assertTrue(result['ok'])
            request=result['result']['intents'][0]['request'];self.assertEqual(request['input'],original);self.assertNotIn('input_reference',request)
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',{'input':{**original,'unknown':True}},kind='prepare',operation_id='')
            result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.argument')
        self.assertFalse((self.root/'new.txt').exists())


    def test_referenced_package_identity_uses_actual_tag_and_rejects_malformed_tags(self):
        original={'path':'new.txt','content':'x'*32768}
        projected=parameter_input(original)
        self.assertTrue(projected['reference']['binding']['package_digest'].startswith('sha256:'))
        with Protocol(self.root) as wire:
            wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
            self.assertTrue(wire.receive()['ok'])
        digest=hashlib.sha256(b'actual-package-fixture').hexdigest()
        for malformed in [digest,'SHA256:'+digest,'sha256:'+digest[:-1],'sha256:'+'g'*64]:
            projected=parameter_input(original);projected['reference']['binding']['package_digest']=malformed
            with Protocol(self.root) as wire:
                wire.hello();wire.invoke('write',projected,kind='prepare',operation_id='')
                result=wire.receive();self.assertFalse(result['ok']);self.assertEqual(result['result']['error'],'workspace.prepare_invalid')
            self.assertFalse((self.root/'new.txt').exists())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--package', type=Path, required=True)
    arguments, extra = parser.parse_known_args(); PACKAGE = arguments.package.resolve(strict=True)
    if os.name != 'posix': parser.error('packaged process tests require Linux')
    unittest.main(argv=[__file__, *extra], verbosity=2)
