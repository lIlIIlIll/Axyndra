#!/usr/bin/env python3
"""Run the packaged endpoint; these protocol fixtures do not prove host networking."""
import argparse
import copy
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest

PACKAGE = None
IDENTITY = ['protocol', 'extension_id', 'extension_version', 'generation', 'id', 'tool', 'kind',
            'command_id', 'thread_id', 'run_id', 'epoch', 'operation_id', 'call_id']


def clean_environment():
    environment = os.environ.copy()
    for name in ['LD_LIBRARY_PATH', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH', 'AXYNDRA_SDK_ROOT']:
        environment.pop(name, None)
    environment.update(BRAVE_API_KEY='MUST_NOT_READ_AMBIENT_BRAVE', TAVILY_API_KEY='MUST_NOT_READ_AMBIENT_TAVILY',
                       SEARXNG_URL='http://must-not-read-ambient.test')
    return environment


class Protocol:
    def __init__(self, workspace):
        self.process = subprocess.Popen([str(PACKAGE / 'bin/web-search-plugin')], cwd=workspace,
                                        env=clean_environment(), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.sequence = 0

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
                raise AssertionError('web search protocol did not emit a frame')
        line = self.process.stdout.readline(262146)
        if not line or len(line) > 262145:
            raise AssertionError('web search endpoint closed or emitted an oversized frame')
        return json.loads(line)

    def hello(self, **overrides):
        self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'web-search',
                   'extension_version': '1.0.0', 'generation': 7, 'capabilities': ['network.http'], **overrides})
        return self.receive()

    def frame(self, arguments, kind='prepare', **overrides):
        self.sequence += 1
        return {'type': 'invoke', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'web-search',
                'extension_version': '1.0.0', 'generation': 7, 'id': f'invoke-{self.sequence}', 'tool': 'web_search',
                'kind': kind, 'command_id': '', 'thread_id': 'thread-web', 'run_id': 'run-web', 'epoch': 2,
                'operation_id': '' if kind == 'prepare' else 'operation-web', 'call_id': 'call-web',
                'arguments': arguments, **overrides}

    def prepare(self, input=None, config=None):
        frame = self.frame({'input': {'query': 'Cangjie'} if input is None else input,
                            'configuration': {} if config is None else config})
        self.send(frame)
        return frame, self.receive()

    def execute(self, input=None, config=None):
        prepared, response = self.prepare(input, config)
        if not response['ok']:
            raise AssertionError(response)
        frame = self.frame(canonical_arguments(prepared['arguments'], response['result']), 'tool')
        self.send(frame)
        return frame, self.receive()


def canonical_arguments(arguments, preparation):
    intents = copy.deepcopy(preparation['intents'])
    for intent in intents:
        intent['network'] = {'mode': 'mediated', 'egress': [], 'publish': []}
    return {**arguments, 'host_plan': {'version': 'http-intents/v1', 'plugin': 'axyndra:web-search',
            'package_digest': 'sha256:' + 'a' * 64, 'generation': '23', 'configuration_digest': 'b' * 64, 'intents': intents}}


def response_for(invocation, body='{"web":{"results":[{"title":"Docs","url":"https://docs.test","description":"Current docs"}]}}', status=200):
    return {**{key: invocation[key] for key in IDENTITY}, 'type': 'service_response', 'request_id': 'search', 'ok': True,
            'result': {'request_id': 'search', 'service': 'network.http', 'receipt_id': 'fixture-http-receipt',
                       'is_error': False, 'output': {'status': status, 'body': body}}}


class PackagedWebSearchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='web-search-plugin-contract-')
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name)

    def test_manifest_and_handshake_have_only_http_authority(self):
        manifest = json.loads((PACKAGE / 'axyndra.plugin.json').read_text())
        self.assertEqual(manifest['capabilities'], ['network.http'])
        self.assertEqual(manifest['version'], '1.0.0')
        with Protocol(self.workspace) as protocol:
            ready = protocol.hello()
            self.assertEqual(ready['type'], 'ready')
            self.assertEqual(ready['capabilities'], ['network.http'])
            self.assertEqual([tool['name'] for tool in ready['tools']], ['web_search'])
            self.assertEqual(len(ready['tools'][0]['input_schema']['properties']), 7)
            self.assertEqual([command['name'] for command in ready['commands']], ['help'])

    def test_brave_prepare_is_pure_and_contains_only_opaque_credential(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, reply = protocol.prepare({'query': 'A & B=文档', 'recency': 'week', 'limit': 2}, {'brave_credential_ref': 'brave-main'})
            self.assertEqual(reply['type'], 'result')
            request = reply['result']['intents'][0]['request']
            self.assertEqual(request, {'method': 'GET', 'url': 'https://api.search.brave.com/res/v1/web/search',
                             'query': {'q': 'A & B=文档', 'count': '2', 'freshness': 'pw'},
                             'headers': {'Accept': 'application/json'}, 'json_body': None,
                             'credential_refs': ['brave-main'], 'timeout_ms': 120000})
            self.assertNotIn('Subscription-Token', json.dumps(reply))

    def test_tavily_prepare_omits_api_key_injection_location_and_plaintext(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, reply = protocol.prepare({'query': 'q', 'provider': 'tavily', 'max_tokens': 500, 'recency': 'day'},
                                        {'tavily_credential_ref': 'tavily-main'})
            request = reply['result']['intents'][0]['request']
            self.assertEqual(request['method'], 'POST')
            self.assertEqual(request['credential_refs'], ['tavily-main'])
            self.assertEqual(request['json_body'], {'query': 'q', 'max_results': 10, 'include_answer': True,
                                                    'search_depth': 'basic', 'max_tokens': 500, 'time_range': 'day'})
            self.assertNotIn('api_key', json.dumps(reply))

    def test_searx_prepare_uses_configured_origin_and_no_credential(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, reply = protocol.prepare(config={'searxng_url': 'http://[::1]:8080/meta/'})
            request = reply['result']['intents'][0]['request']
            self.assertEqual(request['url'], 'http://[::1]:8080/meta/search')
            self.assertEqual(request['query'], {'q': 'Cangjie', 'format': 'json', 'limit': '10', 'time_range': ''})
            self.assertEqual(request['credential_refs'], [])

    def test_missing_configuration_never_discovers_ambient_credentials(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, prepared = protocol.prepare()
            self.assertEqual(prepared['result'], {'intents': []})
            _, result = protocol.execute()
            self.assertEqual(result['type'], 'result')
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'No web search provider configured.')

    def test_explicit_missing_provider_does_not_fallback(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, result = protocol.execute({'query': 'q', 'provider': 'brave'}, {'tavily_credential_ref': 'tavily-main'})
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['content'], 'Error: Brave is not configured.')

    def test_disabled_provider_is_failed_tool_without_an_http_request(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, prepared = protocol.prepare({'query': 'q', 'provider': 'none'}, {'brave_credential_ref': 'b'})
            self.assertTrue(prepared['ok'])
            self.assertEqual(prepared['result'], {'intents': []})
            _, result = protocol.execute({'query': 'q', 'provider': 'none'}, {'brave_credential_ref': 'b'})
            self.assertEqual(result['type'], 'result')
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['count'], 0)
            self.assertIsInstance(result['result']['error'], str)
            self.assertTrue(result['result']['content'].startswith('Error: '))

    def test_auto_selects_only_the_first_available_provider(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, reply = protocol.prepare(config={'brave_credential_ref': 'b', 'tavily_credential_ref': 't', 'searxng_url': 'https://s.test'})
            self.assertEqual(len(reply['result']['intents']), 1)
            self.assertEqual(reply['result']['intents'][0]['request']['credential_refs'], ['b'])

    def test_configuration_unknown_fields_plain_keys_and_invalid_refs_are_rejected(self):
        for config in [{'api_key': 'plaintext'}, {'brave_credential_ref': ''}, {'tavily_credential_ref': '../secret'},
                       {'searxng_url': 5}, {'brave_credential_ref': 'x' * 65}]:
            with self.subTest(config=config), Protocol(self.workspace) as protocol:
                protocol.hello()
                _, result = protocol.prepare(config=config)
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'web_search.configuration_invalid')

    def test_prepare_rejects_operation_id_missing_run_and_zero_epoch(self):
        for changes in [{'operation_id': 'unapproved'}, {'run_id': ''}, {'call_id': ''}, {'epoch': 0}, {'generation': 8}]:
            with self.subTest(changes=changes), Protocol(self.workspace) as protocol:
                protocol.hello()
                protocol.send(protocol.frame({'input': {'query': 'q'}, 'configuration': {}}, **changes))
                self.assertEqual(protocol.process.wait(timeout=5), 3)
                self.assertEqual(protocol.process.stdout.read(), b'')

    def test_invocation_id_is_an_opaque_bounded_host_string(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame = protocol.frame({'input': {'query': 'q'}, 'configuration': {}}, id='opaque:host/invocation-7')
            protocol.send(frame)
            reply = protocol.receive()
            self.assertTrue(reply['ok'])
            self.assertEqual(reply['id'], frame['id'])
        for invocation_id in [1, None, '', 'x' * 129, 'invoke\x00bad']:
            with self.subTest(invocation_id=invocation_id), Protocol(self.workspace) as protocol:
                protocol.hello()
                protocol.send(protocol.frame({'input': {'query': 'q'}, 'configuration': {}}, id=invocation_id))
                self.assertEqual(protocol.process.wait(timeout=5), 3)
                self.assertEqual(protocol.process.stdout.read(), b'')

    def test_execute_requires_host_plan_instead_of_raw_input(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            protocol.send(protocol.frame({'query': 'q'}, 'tool'))
            result = protocol.receive()
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'web_search.arguments_invalid')

    def test_changed_host_plan_request_is_rejected_before_service(self):
        for mutate in ['query', 'url', 'generation', 'extra_intent', 'bare_package_digest',
                       'wrong_package_prefix', 'uppercase_package_digest', 'short_package_digest', 'prefixed_configuration_digest']:
            with self.subTest(mutate=mutate), Protocol(self.workspace) as protocol:
                protocol.hello()
                source, prepared = protocol.prepare(config={'brave_credential_ref': 'b'})
                arguments = canonical_arguments(source['arguments'], prepared['result'])
                host = arguments['host_plan']
                if mutate == 'query': host['intents'][0]['request']['query']['q'] = 'different'
                elif mutate == 'url': host['intents'][0]['request']['url'] = 'https://other.test/search'
                elif mutate == 'generation': host['generation'] = '0'
                elif mutate == 'extra_intent': host['intents'].append(copy.deepcopy(host['intents'][0]))
                elif mutate == 'bare_package_digest': host['package_digest'] = 'a' * 64
                elif mutate == 'wrong_package_prefix': host['package_digest'] = 'sha512:' + 'a' * 64
                elif mutate == 'uppercase_package_digest': host['package_digest'] = 'sha256:' + 'A' * 64
                elif mutate == 'short_package_digest': host['package_digest'] = 'sha256:' + 'a' * 63
                else: host['configuration_digest'] = 'sha256:' + 'b' * 64
                protocol.send(protocol.frame(arguments, 'tool'))
                result = protocol.receive()
                self.assertEqual(result['type'], 'result')
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'web_search.host_plan_invalid')

    def test_execute_requests_only_the_frozen_intent_id(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, request = protocol.execute(config={'brave_credential_ref': 'b'})
            self.assertEqual(frame['generation'], 7)
            self.assertEqual(frame['arguments']['host_plan']['generation'], '23')
            self.assertEqual(request['service'], 'network.http')
            self.assertEqual(request['request_id'], 'search')
            self.assertEqual(request['arguments'], {'intent_id': 'search'})
            self.assertEqual({key: frame[key] for key in IDENTITY}, {key: request[key] for key in IDENTITY})
            protocol.send(response_for(frame))
            result = protocol.receive()
            self.assertTrue(result['ok'])
            self.assertEqual(result['result']['content'], '[1] Docs\n    https://docs.test\n    Current docs')
            self.assertIsNone(result['result']['error'])

    def test_instance_generation_has_its_own_canonical_unsigned_identity(self):
        for generation in ['', '0', '-1', '01', '18446744073709551616', 23]:
            with self.subTest(generation=generation), Protocol(self.workspace) as protocol:
                protocol.hello()
                source, prepared = protocol.prepare(config={'brave_credential_ref': 'b'})
                arguments = canonical_arguments(source['arguments'], prepared['result'])
                arguments['host_plan']['generation'] = generation
                protocol.send(protocol.frame(arguments, 'tool'))
                result = protocol.receive()
                self.assertEqual(result['type'], 'result')
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'web_search.host_plan_invalid')

    def test_tavily_and_searx_service_responses_keep_provider_shapes(self):
        cases = [('tavily', {'tavily_credential_ref': 't'}, {'answer': 'Answer', 'results': [{'url': 'https://t', 'content': 'T', 'published_date': 'today'}]}),
                 ('searxng', {'searxng_url': 'https://s.test'}, {'results': [{'url': 'https://s', 'content': 'S', 'publishedDate': 'today'}]})]
        for provider, config, body in cases:
            with self.subTest(provider=provider), Protocol(self.workspace) as protocol:
                protocol.hello()
                frame, _ = protocol.execute({'query': 'q', 'provider': provider}, config)
                protocol.send(response_for(frame, json.dumps(body)))
                result = protocol.receive()['result']
                self.assertEqual(result['provider'], provider)
                self.assertEqual(result['count'], 1)
                self.assertEqual(result['sources'][0]['publishedDate'], 'today')

    def test_http_error_is_completed_exchange_with_legacy_search_error(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            protocol.send(response_for(frame, '{"detail":"not authorized"}', status=401))
            result = protocol.receive()
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['count'], 0)
            self.assertEqual(result['result']['error'], 'provider request failed with HTTP status 401')

    def test_empty_and_invalid_success_body_are_failed_tool_results(self):
        for body in ['{"web":{"results":[]}}', 'not-json']:
            with self.subTest(body=body), Protocol(self.workspace) as protocol:
                protocol.hello()
                frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
                protocol.send(response_for(frame, body, status=200))
                result = protocol.receive()
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['provider'], 'brave')
                self.assertEqual(result['result']['count'], 0)
                self.assertTrue(result['result']['error'])
                self.assertEqual(result['result']['content'], 'Error: ' + result['result']['error'])

    def test_typed_transport_failure_cannot_become_search_success(self):
        for outer in [True, False]:
            with self.subTest(outer=outer), Protocol(self.workspace) as protocol:
                protocol.hello()
                frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
                response = response_for(frame)
                if outer:
                    response.update(ok=False, error={'code': 'network.cancelled', 'message': 'cancelled'})
                else:
                    response['result'].update(is_error=True, output={'error': 'network.cancelled', 'message': 'cancelled'})
                protocol.send(response)
                result = protocol.receive()
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'network.cancelled')

    def test_missing_or_wrong_receipt_envelope_is_rejected(self):
        for field, value in [('receipt_id', ''), ('service', 'wrong'), ('request_id', 'wrong'), ('is_error', 'false')]:
            with self.subTest(field=field), Protocol(self.workspace) as protocol:
                protocol.hello()
                frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
                response = response_for(frame)
                response['result'][field] = value
                protocol.send(response)
                result = protocol.receive()
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['error'], 'web_search.service_identity')

    def test_cross_epoch_service_response_closes_without_result(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            response = response_for(frame)
            response['epoch'] += 1
            protocol.send(response)
            self.assertEqual(protocol.process.wait(timeout=5), 3)
            self.assertEqual(protocol.process.stdout.read(), b'')

    def test_cancel_acknowledges_matching_identity_and_late_reply_is_rejected(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            protocol.send({**{key: frame[key] for key in IDENTITY}, 'type': 'cancel'})
            self.assertEqual(protocol.receive()['type'], 'cancelled')
            protocol.send(response_for(frame))
            self.assertEqual(protocol.process.wait(timeout=5), 3)
            self.assertEqual(protocol.process.stdout.read(), b'')

    def test_cross_operation_cancel_cannot_cancel_current_invocation(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            protocol.send({**{key: frame[key] for key in IDENTITY}, 'type': 'cancel', 'operation_id': 'another'})
            self.assertEqual(protocol.process.wait(timeout=5), 3)
            self.assertEqual(protocol.process.stdout.read(), b'')

    def test_duplicate_service_response_is_not_replayed(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            response = response_for(frame)
            protocol.send(response)
            self.assertTrue(protocol.receive()['ok'])
            protocol.send(response)
            self.assertEqual(protocol.process.wait(timeout=5), 3)

    def test_concurrent_invoke_is_rejected_while_http_is_pending(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            protocol.send(frame)
            self.assertEqual(protocol.process.wait(timeout=5), 3)

    def test_input_response_and_expanded_result_limits_are_explicit_errors(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            _, result = protocol.prepare({'query': 'x' * 16385})
            self.assertEqual(result['result']['error'], 'web_search.input_limit')
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            protocol.send(response_for(frame, 'x' * 65537))
            self.assertEqual(protocol.receive()['result']['error'], 'web_search.response_limit')
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            body = json.dumps({'web': {'results': [{'title': 'x' * 34000, 'url': 'https://x'}]}})
            self.assertLess(len(body), 65536)
            protocol.send(response_for(frame, body))
            result = protocol.receive()
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['error'], 'web_search.result_limit')

    def test_invalid_http_output_does_not_become_a_renderable_result(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            response = response_for(frame)
            response['result']['output'] = {'status': 999, 'body': 'ok'}
            protocol.send(response)
            self.assertEqual(protocol.receive()['result']['error'], 'web_search.response_invalid')

    def test_error_diagnostics_are_bounded_without_echoing_raw_body(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            frame, _ = protocol.execute(config={'brave_credential_ref': 'b'})
            response = response_for(frame)
            response.update(ok=False, error={'code': 'network.denied', 'message': '界' * 8000})
            protocol.send(response)
            result = protocol.receive()
            self.assertFalse(result['ok'])
            self.assertLessEqual(len(result['result']['message'].encode()), 4096)

    def test_offline_help_command_cannot_execute_search(self):
        with Protocol(self.workspace) as protocol:
            protocol.hello()
            command = protocol.frame({'command_args': ''}, 'command', tool='help', command_id='help-1',
                                     run_id='', operation_id='', call_id='', epoch=0)
            protocol.send(command)
            result = protocol.receive()
            self.assertEqual(result['type'], 'result')
            self.assertTrue(result['ok'])
            self.assertIn('axyndra tools inspect plugin.axyndra:web-search.web_search', result['result']['content'])
            self.assertIn('axyndra tools invoke plugin.axyndra:web-search.web_search \'{"query":', result['result']['content'])
            self.assertIn('provider: auto, brave, tavily, searxng, or none', result['result']['content'])
            self.assertNotIn('axyndra search', result['result']['content'])
            self.assertNotIn('--provider', result['result']['content'])
            command['id'] = 'invoke-help-2'
            command['arguments']['command_args'] = 'query --provider brave'
            protocol.send(command)
            self.assertFalse(protocol.receive()['ok'])

    def test_oversized_line_and_partial_eof_are_rejected(self):
        for raw in [b'x' * 262145, b'{"type":"hello"']:
            with self.subTest(length=len(raw)), Protocol(self.workspace) as protocol:
                protocol.process.stdin.write(raw)
                protocol.process.stdin.flush()
                protocol.process.stdin.close()
                self.assertEqual(protocol.process.wait(timeout=5), 3)
                self.assertEqual(protocol.process.stdout.read(), b'')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    arguments, remaining = parser.parse_known_args()
    PACKAGE = arguments.package.resolve()
    if not (PACKAGE / 'bin/web-search-plugin').is_file():
        parser.error('packaged executable is missing')
    unittest.main(argv=[__file__, *remaining], verbosity=2)
