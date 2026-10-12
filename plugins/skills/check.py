#!/usr/bin/env python3
"""Real packaged executable with bounded protocol I/O and package-data fixtures.

This does not substitute for the Product registry/sandbox/SQLite contracts.
"""
import argparse
import hashlib
import time
import json
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent
BINARY = None
CONTENT_LIMITS = dict(schema='axyndra.content-payload/v1', max_message_bytes=4521984,
                      max_input_bytes=4456448, max_result_bytes=4194304)
IDENTITY = ('protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
            'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id')


class Peer:
    def __init__(self, *, large=False, payload=False, profile=None):
        self.directory = tempfile.TemporaryDirectory(prefix='skills-native-')
        self.root = Path(self.directory.name)
        shutil.copytree(ROOT / 'tests/content', self.root / 'skills')
        if large:
            (self.root / 'skills/review/SKILL.md').write_text(
                '---\nname: review\ndescription: Review code changes and tests\n---\n' + '雪' * 70000,
                encoding='utf-8')
        self.process = subprocess.Popen([str(BINARY)], cwd=self.root, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.frames = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.counter = 0
        self.hello = dict(type='hello', protocol='axyndra-js-host-v2', extension_id='skills',
            extension_version='1.0.0', generation=3, capabilities=[])
        self.payload = payload
        if payload:
            self.hello['content_payload_limits'] = CONTENT_LIMITS if profile is None else profile
        try:
            self.send(self.hello)
            self.ready = self.next()
        except BaseException:
            self.close()
            raise

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(262146)
                if not line:
                    raise EOFError('native process closed')
                if len(line) > 262145 or not line.endswith(b'\n'):
                    raise AssertionError('unbounded protocol output')
                self.frames.put(json.loads(line))
        except BaseException as error:
            self.frames.put(error)

    def send(self, value):
        self.process.stdin.write((json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n').encode())
        self.process.stdin.flush()

    def next(self):
        value = self.frames.get(timeout=5)
        if isinstance(value, BaseException):
            raise value
        return value

    def invocation(self, query, resource=False):
        self.counter += 1
        frame = dict(self.hello)
        frame.update(type='invoke', id=f'invoke-{self.counter}', tool='reference' if resource else 'skills',
            kind='resource_provider' if resource else 'context_provider', command_id='',
            thread_id='thread', run_id='', epoch=0, operation_id='', call_id=f'query-{self.counter}', arguments=query)
        del frame['capabilities']
        frame.pop('content_payload_limits', None)
        if self.payload:
            frame['payload_window'] = f'query-window-{self.counter}'
        return frame

    def invoke(self, query, resource=False):
        frame = self.invocation(query, resource)
        source = json.dumps(frame, ensure_ascii=False, separators=(',', ':')).encode()
        if len(source) + 1 > 262144:
            self.send_logical(frame, source)
        else:
            self.send(frame)
        response = self.receive_result(frame)
        assert response['type'] == 'result', 'pure provider must never request a service or emit progress'
        assert all(response[name] == frame[name] for name in IDENTITY)
        return response

    @staticmethod
    def logical_frame(frame, kind, **values):
        return dict(type=kind, **{name: frame[name] for name in IDENTITY}, payload=dict(
            schema='axyndra.logical-json/v1', window=frame['payload_window'], transfer_sequence=1, **values))

    def send_logical(self, frame, source):
        self.send(self.logical_frame(frame, 'payload_begin', message_type='invoke', bytes=len(source),
                                     sha256=hashlib.sha256(source).hexdigest()))
        for offset in range(0, len(source), 16384):
            self.send(self.logical_frame(frame, 'payload_chunk', offset=offset,
                                         bytes_hex=source[offset:offset + 16384].hex()))
        self.send(self.logical_frame(frame, 'payload_end'))

    def receive_result(self, frame):
        result = self.next()
        if result['type'] == 'result':
            if self.payload:
                assert result['payload_window'] == frame['payload_window']
            return result
        assert self.payload and result['type'] == 'payload_begin'
        assert all(result[name] == frame[name] for name in IDENTITY)
        header = result['payload']
        assert header['schema'] == 'axyndra.logical-json/v1' and header['message_type'] == 'result'
        assert header['window'] == frame['payload_window'] and header['transfer_sequence'] == 1
        assert 0 < header['bytes'] <= CONTENT_LIMITS['max_message_bytes']
        body = bytearray()
        deadline = time.monotonic() + 5
        while True:
            assert time.monotonic() < deadline, 'logical output exceeded fixed consumer deadline'
            part = self.next()
            assert all(part[name] == frame[name] for name in IDENTITY)
            fields = part['payload']
            assert fields['window'] == header['window'] and fields['transfer_sequence'] == 1
            if part['type'] == 'payload_end':
                break
            assert part['type'] == 'payload_chunk' and fields['offset'] == len(body)
            raw = bytes.fromhex(fields['bytes_hex'])
            assert 0 < len(raw) <= 16384
            body.extend(raw)
            assert len(body) <= header['bytes']
        assert len(body) == header['bytes'] and hashlib.sha256(body).hexdigest() == header['sha256']
        result = json.loads(body)
        assert result['payload_window'] == frame['payload_window']
        return result

    def resolve(self, prompt='', selected=None):
        query = dict(schema='axyndra.skills-query/v1', action='resolve', prompt=prompt)
        if selected is not None:
            query['selected'] = selected
        return self.invoke(query)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        self.reader.join(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()
        self.directory.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class SkillsNativeTests(unittest.TestCase):
    def test_observed_invalid_body_skips_activation_but_keeps_metadata_and_valid_selection(self):
        with Peer() as peer:
            resources = [dict(kind='header', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Invalid body metadata\n---\n',
                body_error='invalid_utf8', body_sha256=hashlib.sha256(b'\xff').hexdigest()),
                dict(kind='file', path='user/good/SKILL.md',
                text='---\nname: good\ndescription: Good body metadata\n---\nVALID')]
            query = self.snapshot_query(resources, ('user',))
            query.update(prompt='$review $good', selected=['review', 'good'],
                         allow_unavailable=True, include_catalog=True)
            response = peer.invoke(query)
            self.assertTrue(response['ok'])
            self.assertEqual([item['id'] for item in response['result']['contributions']], ['good'])
            self.assertIn('Invalid body metadata', response['result']['contributions'][0]['content'])
            self.assertTrue(response['result']['contributions'][0]['content'].endswith('VALID'))
            query['selected'] = ['review']
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual([item['id'] for item in result['result']['contributions']], ['catalog'])

    def test_unavailable_policy_never_turns_unobserved_content_into_a_success(self):
        with Peer() as peer:
            query = self.snapshot_query([dict(kind='header', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Metadata alone\n---\n')], ('user',))
            query.update(allow_unavailable=True, include_catalog=True)
            result = peer.invoke(query)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'skills.body_unobserved')
            for invalid in ['true', 1, None]:
                query['allow_unavailable'] = invalid
                result = peer.invoke(query)
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'skills.selection_policy')

    def test_prepare_selects_only_observed_header_paths_and_freezes_routing(self):
        with Peer() as peer:
            resources = [dict(kind='header', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Review code\n---\n'),
                dict(kind='header', path='workspace/review/SKILL.md',
                text='---\nname: review\ndescription: Workspace review\n---\n')]
            query = self.snapshot_query(resources)
            query.update(action='prepare', include_catalog=True)
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            prepared = result['result']
            self.assertEqual(set(prepared), {'schema', 'reads', 'query'})
            self.assertEqual(prepared['schema'], 'axyndra.context-preparation/v1')
            self.assertEqual(prepared['reads'], [dict(path='workspace/review/SKILL.md')])
            self.assertEqual(prepared['query']['selected'], ['review'])
            self.assertNotIn('_axyndra_context_read', prepared['query'])
            self.assertNotIn('source', json.dumps(prepared['reads']))
            resources[1] = dict(kind='file', path='workspace/review/SKILL.md',
                text=resources[1]['text'] + 'BODY-ONLY-AFTER-SEPARATE-OBSERVATION')
            next_query = prepared['query']
            next_query['_axyndra_context_read'] = self.snapshot_query(resources)['_axyndra_context_read']
            final = peer.invoke(next_query)
            self.assertTrue(final['ok'])
            self.assertTrue(final['result']['contributions'][0]['content'].endswith('BODY-ONLY-AFTER-SEPARATE-OBSERVATION'))

    def test_header_is_not_usable_as_an_instruction_body(self):
        with Peer() as peer:
            query = self.snapshot_query([dict(kind='header', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Review\n---\n')], ('user',))
            result = peer.invoke(query)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'skills.body_unobserved')
            self.assertTrue(peer.resolve('$review')['ok'])

    def test_prepare_missing_roots_and_no_selection_do_not_request_unobserved_files(self):
        with Peer() as peer:
            query = self.snapshot_query([dict(kind='absence', path='user', text='')], ('user',))
            query['action'] = 'prepare'
            packaged = peer.invoke(query)
            self.assertTrue(packaged['ok'])
            self.assertEqual(packaged['result']['reads'], [])
            self.assertEqual(packaged['result']['query']['selected'], ['review'])
            query.update(prompt='$missing', include_catalog=True)
            absent = peer.invoke(query)
            self.assertTrue(absent['ok'])
            self.assertEqual(absent['result']['reads'], [])
            self.assertEqual(absent['result']['query']['selected'], [])

    def test_prepare_catalog_preserves_metadata_limit_and_never_reads_a_host_trap(self):
        with Peer(payload=True) as peer:
            resources = [dict(kind='header', path=f'user/s{i:03}/SKILL.md',
                text=f'---\nname: s{i:03}\ndescription: ' + '<>' * 300 + '\n---\n') for i in range(140)]
            query = self.snapshot_query(resources, ('user',))
            query.update(action='prepare', prompt='$missing', include_catalog=True)
            prepared = peer.invoke(query)
            self.assertTrue(prepared['ok'])
            self.assertEqual(prepared['result']['reads'], [])
            next_query = prepared['result']['query']
            next_query['_axyndra_context_read'] = query['_axyndra_context_read']
            catalog = peer.invoke(next_query)
            self.assertTrue(catalog['ok'])
            text = catalog['result']['contributions'][0]['content']
            escaped = text.replace('\\', '\\\\').replace('<', '\\u003c').replace('>', '\\u003e')
            self.assertLessEqual(len(escaped.encode()), 65536)
            self.assertNotIn('s139', text)
            self.assertTrue(peer.resolve('$review')['ok'])

    def test_initial_context_combines_catalog_and_unchanged_selection_without_an_extra_grant(self):
        with Peer() as peer:
            query = dict(schema='axyndra.skills-query/v1', action='resolve', prompt='$review', include_catalog=True)
            response = peer.invoke(query)
            self.assertTrue(response['ok'])
            contributions = response['result']['contributions']
            self.assertEqual([item['id'] for item in contributions], ['review'])
            self.assertIn('Available Skills', contributions[0]['content'])
            self.assertTrue(contributions[0]['content'].endswith('Review instructions from the immutable package.\n'))
            self.assertNotIn('trust', contributions[0])
            query['prompt'] = '$unknown'
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual([item['id'] for item in result['result']['contributions']], ['catalog'])
            self.assertNotIn('Review instructions from', result['result']['contributions'][0]['content'])
            self.assertEqual(peer.resolve('$review')['result']['contributions'][0]['content'],
                             'Review instructions from the immutable package.\n')

    def test_catalog_flag_is_strict_and_does_not_grant_snapshot_roots(self):
        with Peer() as peer:
            for invalid in ['true', 1, None, {}]:
                result = peer.invoke(dict(schema='axyndra.skills-query/v1', action='resolve',
                    prompt='$review', include_catalog=invalid))
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'skills.catalog_flag')
            result = peer.invoke(dict(schema='axyndra.skills-query/v1', action='resolve',
                prompt='$review', include_catalog=True, resource_roots=['host']))
            self.assertFalse(result['ok'])

    @staticmethod
    def snapshot_query(resources, roots=('user', 'workspace')):
        return dict(schema='axyndra.skills-query/v1', action='resolve', prompt='$review',
            resource_roots=list(roots), _axyndra_context_read=dict(schema='axyndra.context-read-input/v1',
                data=dict(schema='axyndra.context-read-result/v1', resources=resources), facts=[]))

    def test_snapshot_root_order_overrides_package_without_opening_host_paths(self):
        with Peer() as peer:
            def skill(body):
                return '---\nname: review\ndescription: Review code changes\n---\n' + body
            resources = [dict(kind='file', path='user/review/SKILL.md', text=skill('USER')),
                         dict(kind='file', path='workspace/review/SKILL.md', text=skill('WORKSPACE'))]
            (peer.root / 'workspace/review').mkdir(parents=True)
            (peer.root / 'workspace/review/SKILL.md').write_text(skill('LIVE-HOST-TRAP'))
            result = peer.invoke(self.snapshot_query(resources))
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['content'], 'WORKSPACE')
            self.assertNotIn('LIVE-HOST-TRAP', json.dumps(result))

    def test_snapshot_reference_is_inline_immutable_data(self):
        with Peer() as peer:
            resources = [dict(kind='file', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Review code\n---\nSNAPSHOT'),
                dict(kind='file', path='user/review/references/details.md', text='Observed reference 雪')]
            result = peer.invoke(self.snapshot_query(resources, ('user',)))
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['references'],
                             [dict(id='details.md', content='Observed reference 雪')])
            self.assertNotIn('trust', result['result']['contributions'][0])

    def test_absent_optional_snapshot_root_keeps_packaged_fallback(self):
        with Peer() as peer:
            result = peer.invoke(self.snapshot_query([dict(kind='absence', path='user', text='')], ('user',)))
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['content'], 'Review instructions from the immutable package.\n')

    def test_snapshot_duplicate_escape_and_missing_envelope_are_typed_errors(self):
        with Peer() as peer:
            item = dict(kind='directory', path='user')
            invalid = [self.snapshot_query([item, item], ('user',)),
                       self.snapshot_query([dict(kind='file', path='../escape/SKILL.md', text='x')], ('user',)),
                       dict(schema='axyndra.skills-query/v1', action='resolve', prompt='$review', resource_roots=['user'])]
            for query in invalid:
                self.assertFalse(peer.invoke(query)['ok'])
            self.assertTrue(peer.resolve('$review')['ok'])

    def test_contributes_context_and_resources_without_a_tool(self):
        with Peer() as peer:
            self.assertEqual(peer.ready['tools'], [])
            self.assertEqual(peer.ready['capabilities'], [])
            self.assertEqual(peer.ready['context_providers'][0]['name'], 'skills')
            self.assertEqual(peer.ready['resource_providers'][0]['name'], 'reference')

    def test_catalog_is_metadata_only(self):
        with Peer() as peer:
            value = peer.invoke(dict(schema='axyndra.skills-query/v1', action='catalog'))
            self.assertTrue(value['ok'])
            content = value['result']['contributions'][0]['content']
            self.assertIn('Review code changes and tests', content)
            self.assertNotIn('Review instructions from', content)
            self.assertNotIn('Packaged reference:', content)

    def test_explicit_marker_keeps_longest_name_and_returns_exact_body(self):
        with Peer() as peer:
            result = peer.resolve('$review-security')['result']['contributions']
            self.assertEqual([item['id'] for item in result], ['review-security'])
            self.assertEqual(result[0]['content'], 'Security instructions from the immutable package.\n')
            self.assertNotIn('trust', result[0])

    def test_automatic_routing_and_unknown_explicit_marker(self):
        with Peer() as peer:
            result = peer.resolve('Analyze measurements and statistics')['result']['contributions']
            self.assertEqual([item['id'] for item in result], ['analyze'])
            self.assertEqual(peer.resolve('$unknown review code')['result']['contributions'], [])

    def test_reference_reads_only_exact_declared_resource(self):
        with Peer() as peer:
            selected = peer.resolve(selected=['review'])['result']['contributions'][0]
            self.assertEqual(selected['references'][0], dict(id='details.md', provider='reference', resource_id='review/details.md'))
            value = peer.invoke(dict(schema='axyndra.resource-query/v1', resource_id='review/details.md'), True)
            self.assertEqual(value['result']['content'], 'Packaged reference: 雪\n')
            denied = peer.invoke(dict(schema='axyndra.resource-query/v1', resource_id='../../etc/passwd'), True)
            self.assertFalse(denied['ok'])

    def test_selection_is_explicit_and_query_cannot_grant_new_roots(self):
        with Peer() as peer:
            self.assertEqual(peer.resolve('review code', [])['result']['contributions'], [])
            for selected in [['missing'], ['review', 'review']]:
                self.assertFalse(peer.resolve(selected=selected)['ok'])
            query = dict(schema='axyndra.skills-query/v1', action='resolve', prompt='$review', root='/etc')
            self.assertFalse(peer.invoke(query)['ok'])

    def test_forged_execution_identity_closes_process(self):
        for field, value in [('run_id', 'forged'), ('operation_id', 'forged'), ('epoch', 1), ('kind', 'service')]:
            with self.subTest(field=field), Peer() as peer:
                frame = peer.invocation(dict(schema='axyndra.skills-query/v1', action='catalog'))
                frame[field] = value
                peer.send(frame)
                with self.assertRaises(EOFError):
                    peer.next()
                self.assertEqual(peer.process.wait(timeout=3), 3)

    def test_oversized_content_fails_without_truncation_or_poisoning_next_query(self):
        with Peer(large=True) as peer:
            failure = peer.resolve(selected=['review'])
            self.assertFalse(failure['ok'])
            self.assertEqual(failure['result']['error'], 'skills.output_limit')
            self.assertTrue(peer.resolve(selected=['analyze'])['ok'])


    def test_lazy_reference_prepare_requests_names_with_selected_body_only(self):
        with Peer() as peer:
            query = self.snapshot_query([dict(kind='header', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Review code\n---\n')], ('user',))
            query.update(action='prepare', lazy_references=True)
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['reads'], [dict(path='user/review/SKILL.md'),
                dict(path='user/review/references', mode='metadata_directory')])
            self.assertTrue(result['result']['query']['lazy_references'])

    def test_metadata_references_remain_lazy_and_only_declare_observed_names(self):
        with Peer() as peer:
            query = self.snapshot_query([dict(kind='file', path='user/review/SKILL.md',
                text='---\nname: review\ndescription: Review code\n---\nBODY'),
                dict(kind='metadata', path='user/review/references', entries=[dict(name='details.md')])], ('user',))
            query['lazy_references'] = True
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['references'],
                [dict(id='details.md', observed_path='user/review/references/details.md')])
            self.assertNotIn('content', result['result']['contributions'][0]['references'][0])
            self.assertFalse(peer.invoke(dict(schema='axyndra.resource-query/v1',
                resource_id='user/review/references/details.md'), True)['ok'])

    def test_reference_metadata_duplicates_escapes_and_policy_types_fail(self):
        with Peer() as peer:
            for names in [['../private'], ['a', 'a'], ['a/b'], ['a'] * 33]:
                query = self.snapshot_query([dict(kind='metadata', path='user/review/references',
                    entries=[dict(name=name) for name in names])], ('user',))
                self.assertFalse(peer.invoke(query)['ok'])
            query = dict(schema='axyndra.skills-query/v1', action='resolve', prompt='$review', lazy_references='true')
            self.assertFalse(peer.invoke(query)['ok'])


class SkillsComponentSourceTests(unittest.TestCase):
    @staticmethod
    def source(paths, *, alias='component-0', ecosystem='pi'):
        return dict(alias=alias, namespace='pi:third-party', package_digest='sha256:' + 'a' * 64,
                    scope='user', root_name='third-party', ecosystem=ecosystem,
                    components=[dict(kind='skill', path=path) for path in paths])

    @staticmethod
    def query(sources):
        return dict(schema='axyndra.context-sources-query/v1', components=sources,
                    query=dict(schema='axyndra.skills-query/v1', action='prepare', prompt='$deep',
                               resource_roots=['user'], include_catalog=True))

    @staticmethod
    def observed(query, entries):
        value = dict(query)
        value['_axyndra_context_read'] = dict(schema='axyndra.context-read-input/v1', facts=[],
            data=dict(schema='axyndra.context-read-result/v1', resources=[
                dict(kind='absence', path='user', text=''),
                dict(kind='index', path='component-0', entries=entries, truncated=False, depth_limited=False)]))
        return value

    def test_pi_source_projection_preserves_scan_bases_and_negative_only_default(self):
        with Peer() as peer:
            result = peer.invoke(self.query([self.source(['skills/d*', 'skills/?emo', 'skills/team/**', '!skills/private'])]))
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['reads'], [dict(alias='component-0', starts=['skills', 'skills/team'], depth=31, order='native')])
            negative = peer.invoke(self.query([self.source(['!skills/private/**'])]))
            self.assertTrue(negative['ok'])
            self.assertEqual(negative['result']['reads'][0]['starts'], ['skills'])

    def test_unicode_question_double_star_and_exclusions_select_metadata_without_body(self):
        with Peer() as peer:
            planned = peer.invoke(self.query([self.source(['skills/?emo', 'skills/team/**', '!skills/team/private/**'])]))['result']
            entries = [dict(kind='file', relative=p) for p in ['skills/雪emo/SKILL.md', 'skills/team/a/b/deep/SKILL.md',
                'skills/team/private/no/SKILL.md', 'skills/other/SKILL.md']]
            discovered = peer.invoke(self.observed(planned['query'], entries))
            self.assertTrue(discovered['ok'])
            self.assertEqual([x['path'] for x in discovered['result']['reads']],
                             ['component-0/skills/雪emo/SKILL.md', 'component-0/skills/team/a/b/deep/SKILL.md'])
            self.assertTrue(all(x['mode'] == 'header' for x in discovered['result']['reads']))
            self.assertNotIn('instructions', json.dumps(discovered['result']))

    def test_two_hundred_fifty_six_actual_roots_are_preserved_before_metadata_budget(self):
        with Peer(payload=True) as peer:
            planned = peer.invoke(self.query([self.source(['skills/**'])]))['result']
            entries = [dict(kind='file', relative=f'skills/s{n:03d}/SKILL.md') for n in range(257)]
            discovered = peer.invoke(self.observed(planned['query'], entries))
            self.assertTrue(discovered['ok'])
            self.assertEqual(len(discovered['result']['reads']), 256)
            self.assertEqual(discovered['result']['reads'][-1]['path'], 'component-0/skills/s255/SKILL.md')
            self.assertNotIn('component-0/skills/s256', discovered['result']['query']['resource_roots'])

    def test_last_retained_pi_root_keeps_its_legacy_immediate_child_pass(self):
        with Peer(payload=True) as peer:
            planned = peer.invoke(self.query([self.source(['skills/**'])]))['result']
            entries = []
            for n in range(256):
                entries += [dict(kind='directory', relative=f'skills/s{n:03d}'),
                            dict(kind='file', relative=f'skills/s{n:03d}/SKILL.md')]
            entries += [dict(kind='directory', relative='skills/s255/extra'),
                        dict(kind='file', relative='skills/s255/extra/SKILL.md')]
            discovered = peer.invoke(self.observed(planned['query'], entries))
            self.assertTrue(discovered['ok'])
            self.assertEqual(len(discovered['result']['reads']), 257)
            self.assertEqual(discovered['result']['reads'][-1]['path'], 'component-0/skills/s255/extra/SKILL.md')
            self.assertEqual(len(discovered['result']['query']['resource_roots']), 257)

    def test_incomplete_index_is_diagnostic_before_any_header_request(self):
        with Peer() as peer:
            planned = peer.invoke(self.query([self.source(['skills/**'])]))['result']
            query = self.observed(planned['query'], [dict(kind='file', relative='skills/deep/SKILL.md')])
            query['_axyndra_context_read']['data']['resources'][1]['truncated'] = True
            result = peer.invoke(query)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'skills.component_index_limit')

    def test_literal_brackets_and_non_pi_shallow_scope_keep_old_selector_semantics(self):
        with Peer() as peer:
            planned = peer.invoke(self.query([self.source(['skills/[ab]', 'skills/file/SKILL.md'])]))['result']
            entries = [dict(kind='file', relative=p) for p in ['skills/a/SKILL.md', 'skills/[ab]/SKILL.md', 'skills/file/SKILL.md']]
            discovered = peer.invoke(self.observed(planned['query'], entries))
            self.assertTrue(discovered['ok'])
            self.assertEqual([x['path'] for x in discovered['result']['reads']],
                             ['component-0/skills/[ab]/SKILL.md', 'component-0/skills/file/SKILL.md'])
            codex = peer.invoke(self.query([self.source(['SKILL.md'], ecosystem='codex')]))
            self.assertTrue(codex['ok'])
            self.assertEqual(codex['result']['reads'], [dict(alias='component-0', starts=[''], depth=1, order='sorted')])
            bounded = self.observed(codex['result']['query'], [dict(kind='directory', relative=''),
                dict(kind='file', relative='SKILL.md'), dict(kind='directory', relative='references')])
            bounded['_axyndra_context_read']['data']['resources'][1]['depth_limited'] = True
            result = peer.invoke(bounded)
            self.assertTrue(result['ok'])
            self.assertEqual([x['path'] for x in result['result']['reads']], ['component-0/SKILL.md'])
            pi_bounded = self.observed(planned['query'], entries)
            pi_bounded['_axyndra_context_read']['data']['resources'][1]['depth_limited'] = True
            failed = peer.invoke(pi_bounded)
            self.assertFalse(failed['ok'])
            self.assertEqual(failed['result']['error'], 'skills.component_index_limit')

    def test_source_envelope_unknown_field_duplicate_alias_and_escape_are_typed(self):
        with Peer() as peer:
            source = self.source(['skills'])
            variants = [dict(self.query([source]), ambient_root='/tmp'), self.query([source, source]),
                        self.query([dict(source, alias='../host')])]
            for query in variants:
                with self.subTest(query=query):
                    result = peer.invoke(query)
                    self.assertFalse(result['ok'])
                    self.assertIn('skills.component_', result['result']['error'])

    def test_discovered_root_order_overrides_builtin_without_inventing_body_reads(self):
        with Peer() as peer:
            source = self.source(['skills/**'])
            query = SkillsNativeTests.snapshot_query([
                dict(kind='file', path='user/review/SKILL.md', text='---\nname: review\ndescription: User review\n---\nUSER'),
                dict(kind='file', path='component-0/skills/review/SKILL.md', text='---\nname: review\ndescription: Component review\n---\nCOMPONENT')],
                ('user', 'component-0/skills/review'))
            query['component_sources'] = [source]
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['content'], 'COMPONENT')


class SkillsLogicalPayloadTests(unittest.TestCase):
    def test_actual_bidirectional_snapshot_and_reference_exceed_old_frame_without_truncation(self):
        with Peer(payload=True) as peer:
            self.assertEqual(peer.ready['content_payload_limits'], CONTENT_LIMITS)
            content = 'N' * 524288
            reference = '雪' * 170000
            query = SkillsNativeTests.snapshot_query([
                dict(kind='file', path='user/review/SKILL.md', text='---\nname: review\ndescription: Review\n---\n' + content),
                dict(kind='file', path='user/review/references/details.md', text=reference)], ('user',))
            self.assertGreater(len(json.dumps(query).encode()), 262144)
            result = peer.invoke(query)
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['contributions'][0]['content'], content)
            self.assertEqual(result['result']['contributions'][0]['references'][0]['content'], reference)
            self.assertTrue(peer.resolve(selected=['analyze'])['ok'])

    def test_large_package_result_then_immediate_next_query_releases_all_transfers(self):
        with Peer(large=True, payload=True) as peer:
            for _ in range(10):
                large = peer.resolve(selected=['review'])
                self.assertTrue(large['ok'])
                self.assertEqual(large['result']['contributions'][0]['content'], '雪' * 70000)
                self.assertTrue(peer.resolve(selected=['analyze'])['ok'])

    def test_unknown_or_changed_profile_is_rejected_before_query(self):
        for profile in [dict(CONTENT_LIMITS, service=True), dict(CONTENT_LIMITS, max_result_bytes=4194305),
                        dict(CONTENT_LIMITS, max_input_bytes='4456448')]:
            with self.subTest(profile=profile), self.assertRaises(EOFError):
                Peer(payload=True, profile=profile)

    def test_wrong_offset_identity_digest_and_cancel_cannot_be_reused(self):
        for mode in ('offset', 'identity', 'digest', 'cancel'):
            with self.subTest(mode=mode), Peer(payload=True) as peer:
                frame = peer.invocation(dict(schema='axyndra.skills-query/v1', action='catalog'))
                source = json.dumps(frame, separators=(',', ':')).encode()
                digest = '0' * 64 if mode == 'digest' else hashlib.sha256(source).hexdigest()
                peer.send(peer.logical_frame(frame, 'payload_begin', message_type='invoke', bytes=len(source), sha256=digest))
                if mode == 'cancel':
                    peer.send(dict(type='cancel', **{name: frame[name] for name in IDENTITY}))
                else:
                    part = peer.logical_frame(frame, 'payload_chunk', offset=1 if mode == 'offset' else 0, bytes_hex=source.hex())
                    if mode == 'identity':
                        part['call_id'] = 'another-query'
                    peer.send(part)
                    if mode == 'digest':
                        peer.send(peer.logical_frame(frame, 'payload_end'))
                self.assertEqual(peer.process.wait(timeout=3), 3)

    def test_dense_physical_frame_is_bounded_without_chunk_negotiation(self):
        with Peer(payload=True) as peer:
            frame = peer.invocation(dict(schema='axyndra.skills-query/v1', action='catalog', dense=[0] * 65537))
            self.assertLess(len(json.dumps(frame, separators=(',', ':')).encode()), 262144)
            peer.send(frame)
            self.assertEqual(peer.process.wait(timeout=3), 3)

    def test_overcap_begin_and_duplicate_id_do_not_allocate_or_rebind(self):
        with Peer(payload=True) as peer:
            frame = peer.invocation(dict(schema='axyndra.skills-query/v1', action='catalog'))
            peer.send(peer.logical_frame(frame, 'payload_begin', message_type='invoke',
                                         bytes=CONTENT_LIMITS['max_message_bytes'] + 1, sha256='0' * 64))
            self.assertEqual(peer.process.wait(timeout=3), 3)
        with Peer(payload=True) as peer:
            frame = peer.invocation(dict(schema='axyndra.skills-query/v1', action='catalog'))
            peer.send(frame)
            self.assertTrue(peer.receive_result(frame)['ok'])
            peer.send(frame)
            self.assertEqual(peer.process.wait(timeout=3), 3)


class SkillsManagedPolicyTests(unittest.TestCase):
    @staticmethod
    def query(action='create', *, name=' Review ', description=' Inspect <source> `code`\n~~ now ',
              body='  # Instructions\n\nReview bytes.  ', phase='evaluate',
              managed=False, directory=False, authored=False, allow_delete=True):
        result = dict(schema='axyndra.managed-skill-policy/v1', phase=phase, allow_delete=allow_delete,
                      input=dict(action=action, name=name, description=description, body=body))
        if phase == 'evaluate':
            result['state'] = dict(managed_file_exists=managed, managed_directory_exists=directory,
                                   authored_file_exists=authored)
        return result

    def test_managed_normalization_does_not_read_or_write_host_state(self):
        with Peer() as peer:
            # A same-named package skill is not a trusted existence observation.
            before = {p.relative_to(peer.root): p.read_bytes() for p in peer.root.rglob('*') if p.is_file()}
            response = peer.invoke(self.query(phase='normalize'))
            self.assertTrue(response['ok'])
            result = response['result']
            self.assertEqual(result['schema'], 'axyndra.managed-skill-proposal/v1')
            self.assertEqual(result['status'], 'observation_required')
            self.assertEqual(result['input'], dict(action='create', name='review',
                description='Inspect source code ~ now', body='# Instructions\n\nReview bytes.'))
            self.assertEqual(result['relative_path'], 'review/SKILL.md')
            self.assertNotIn('mutation', result)
            self.assertNotIn('content', result)
            after = {p.relative_to(peer.root): p.read_bytes() for p in peer.root.rglob('*') if p.is_file()}
            self.assertEqual(after, before)

    def test_managed_name_validation_and_learn_delete_boundary(self):
        with Peer() as peer:
            for name in ['', '-a', '../a', 'a/b', 'a\\b', 'a.b', 'a_' , '雪', 'a' * 65, 'a\0b']:
                response = peer.invoke(self.query(name=name))
                self.assertFalse(response['ok'], name)
                self.assertEqual(response['result']['error'], 'skill.name_invalid')
            self.assertTrue(peer.invoke(self.query(name='9' + 'a' * 63))['ok'])
            response = peer.invoke(self.query(action='delete', allow_delete=False, directory=True))
            self.assertFalse(response['ok'])
            self.assertEqual(response['result']['error'], 'tool.memory_invalid_argument')

    def test_managed_authored_collision_precedes_existing_managed_file(self):
        with Peer() as peer:
            response = peer.invoke(self.query(managed=True, directory=True, authored=True))
            self.assertTrue(response['ok'])
            self.assertEqual(response['result']['status'], 'shadowed')
            self.assertNotIn('mutation', response['result'])
            self.assertNotIn('content', response['result'])
            duplicate = peer.invoke(self.query(managed=True, directory=True))
            self.assertFalse(duplicate['ok'])
            self.assertEqual(duplicate['result']['error'], 'skill.already_exists')
            absent = peer.invoke(self.query(action='update', directory=True))
            self.assertFalse(absent['ok'])
            self.assertEqual(absent['result']['error'], 'skill.not_found')

    def test_managed_update_and_directory_delete_preserve_old_policy(self):
        with Peer() as peer:
            updated = peer.invoke(self.query(action='update', managed=True, directory=True, authored=True))
            self.assertTrue(updated['ok'])
            self.assertEqual(updated['result']['mutation'], 'write_file')
            deleted = peer.invoke(self.query(action='delete', directory=True, description='', body=''))
            self.assertTrue(deleted['ok'])
            self.assertEqual(deleted['result']['mutation'], 'remove_directory')
            self.assertEqual(deleted['result']['relative_directory'], 'review')
            self.assertNotIn('content', deleted['result'])
            absent = peer.invoke(self.query(action='delete'))
            self.assertFalse(absent['ok'])
            self.assertEqual(absent['result']['error'], 'skill.not_found')

    def test_managed_yaml_and_utf8_byte_limit_are_exact(self):
        with Peer(payload=True) as peer:
            description = 'A "quoted" \\ path'
            prefix = '---\nname: test\ndescription: "A \\"quoted\\" \\\\ path"\n---\n\n'
            body = '雪' * 21000
            remaining = 64000 - len((prefix + body + '\n').encode())
            self.assertGreater(remaining, 0)
            body += 'x' * remaining
            response = peer.invoke(self.query(name='test', description=description, body=body))
            self.assertTrue(response['ok'])
            content = response['result']['content']
            self.assertEqual(content, prefix + body + '\n')
            self.assertEqual(len(content.encode()), 64000)
            too_large = peer.invoke(self.query(name='test', description=description, body=body + 'x'))
            self.assertFalse(too_large['ok'])
            self.assertEqual(too_large['result']['error'], 'skill.too_large')

    def test_managed_escaped_nul_payload_roundtrip_exceeds_physical_frame(self):
        with Peer(payload=True) as peer:
            prefix = '---\nname: test\ndescription: "d"\n---\n\n'
            body = '\0' * (64000 - len(prefix.encode()) - 1)
            request = self.query(name='test', description='d', body=body)
            self.assertGreater(len(json.dumps(peer.invocation(request)).encode()), 262144)
            response = peer.invoke(request)
            self.assertTrue(response['ok'])
            self.assertEqual(response['result']['content'], prefix + body + '\n')
            self.assertEqual(len(response['result']['content'].encode()), 64000)
            self.assertTrue(peer.invoke(dict(schema='axyndra.skills-query/v1', action='catalog'))['ok'])

    def test_managed_unknown_fields_and_unobserved_or_malformed_state_fail(self):
        requests = []
        unknown = self.query(); unknown['grant'] = True; requests.append(unknown)
        extra_input = self.query(); extra_input['input']['path'] = '../escape'; requests.append(extra_input)
        unobserved = self.query(); del unobserved['state']; requests.append(unobserved)
        wrong_phase = self.query(); wrong_phase['phase'] = 'normalize'; requests.append(wrong_phase)
        typed = self.query(); typed['state']['managed_file_exists'] = 'false'; requests.append(typed)
        impossible = self.query(managed=True); requests.append(impossible)
        extra_state = self.query(); extra_state['state']['root'] = '/tmp'; requests.append(extra_state)
        with Peer() as peer:
            for request in requests:
                self.assertFalse(peer.invoke(request)['ok'], request)
            self.assertTrue(peer.invoke(self.query())['ok'])

    def test_managed_proposal_does_not_contribute_tool_or_mutate_package(self):
        with Peer() as peer:
            original = (peer.root / 'skills/review/SKILL.md').read_bytes()
            response = peer.invoke(self.query(action='delete', directory=True))
            self.assertTrue(response['ok'])
            self.assertEqual(peer.ready['tools'], [])
            self.assertEqual(peer.ready['capabilities'], [])
            self.assertEqual((peer.root / 'skills/review/SKILL.md').read_bytes(), original)
            denied = peer.invoke(self.query(), resource=True)
            self.assertFalse(denied['ok'])
            self.assertEqual(denied['result']['error'], 'skills.resource_query')



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    arguments = parser.parse_args()
    BINARY = (arguments.package / 'bin/skills-plugin').resolve()
    if not BINARY.is_file():
        parser.error('a real packaged skills executable is required')
    unittest.main(argv=['skills-native-contracts'], verbosity=2)
