#!/usr/bin/env python3
"""Native artifact + actual localhost HTTP/SSE through a protocol host fixture.

This is not Product, canonical approval or a Store Receipt proof. Only this
fixture knows the test credential; the plugin sees its opaque ref and bounded
HTTP broker responses. No mcp4cj transport is mocked or replaced inside plugin.
"""
import argparse
import copy
import http.server
import json
import os
from pathlib import Path
import queue
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlsplit

import check as base

BINARY = None
SECRET = 'host-fixture-only-credential-5382'


class HttpOrigin(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, mode):
        self.mode = mode
        self.observed = []
        self.closed = threading.Event()
        self.called = threading.Event()
        self.directories = 0
        super().__init__(('127.0.0.1', 0), HttpHandler)


class HttpHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '-1'))
        assert 0 <= size <= 30720
        body = self.rfile.read(size)
        request = json.loads(body)
        method = request['method']
        # Persist only a boolean auth witness, never the private header value.
        self.server.observed.append({'path': self.path, 'body': body,
            'headers': {k.lower(): v for k, v in self.headers.items() if k.lower() != 'authorization'},
            'authorized': self.headers.get('Authorization') == SECRET})
        assert self.headers['Mcp-Method'] == method
        assert self.headers['Mcp-Protocol-Version'] == '2026-07-28'
        if method == 'server/discover':
            result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                      'capabilities': {'tools': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
        elif method == 'tools/list':
            self.server.directories += 1
            remote = 'remote.echo:雪'
            if self.server.mode == 'refresh' and self.server.directories > 1:
                remote = 'remote.updated:雪'
            result = {'resultType': 'complete', 'tools': [{'name': remote, 'description': 'Actual HTTP bytes',
                      'inputSchema': {'type': 'object'}}], 'ttlMs': 0, 'cacheScope': 'private'}
        elif method == 'tools/call':
            self.server.called.set()
            if self.server.mode == 'slow-head':
                time.sleep(5.4)
            if self.server.mode in ('hold', 'cancel-open'):
                self.wait_closed()
                return
            if self.server.mode == 'cancel-read':
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wait_closed()
                return
            if self.server.mode == 'disconnect':
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                self.close_connection = True
                return
            result = {'resultType': 'complete', 'content': [{'type': 'text', 'text': body.decode()}]}
            if self.server.mode == 'business-error':
                result['isError'] = True
            if self.server.mode == 'secret-echo':
                result['content'][0]['text'] = SECRET
        else:
            raise AssertionError(method)
        status = 503 if self.server.mode == 'status' and method == 'tools/call' else 200
        encoded = json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result},
                             ensure_ascii=False, separators=(',', ':')).encode()
        sse = self.headers.get('Accept', '').startswith('text/event-stream')
        self.send_response(status)
        self.send_header('Content-Type', 'text/event-stream' if sse else 'application/json')
        self.send_header('Set-Cookie', SECRET)  # Metadata whitelist must suppress this.
        if not sse:
            extra = 5 if self.server.mode == 'truncated' and method == 'tools/call' else 0
            self.send_header('Content-Length', str(len(encoded) + extra))
        self.end_headers()
        if sse:
            self.wfile.write(b'data: ' + encoded + b'\n\n')
            self.wfile.flush()
            self.wait_closed()
        else:
            self.wfile.write(encoded)
            self.wfile.flush()
            self.close_connection = True

    def wait_closed(self):
        self.connection.settimeout(8)
        try:
            while self.connection.recv(1):
                pass
        except (ConnectionError, OSError):
            pass
        finally:
            self.server.closed.set()
            self.close_connection = True


class HttpExchange:
    def __init__(self, request, handle, maintenance):
        self.request = request
        self.handle = handle
        self.maintenance = maintenance
        self.socket = None
        self.lock = threading.Lock()
        self.closed = False
        self.received = 0
        self.eof = False
        self.length = None
    def close(self):
        with self.lock:
            self.closed = True
            sock = self.socket
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


class HttpPeer(base.Peer):
    def __init__(self, mode='echo', prefer_sse=False):
        self.profile = None
        self.frame_limit = 262144
        self.directory = tempfile.TemporaryDirectory(prefix='mcp-http-protocol-')
        self.origin = HttpOrigin(mode)
        self.origin_thread = threading.Thread(target=self.origin.serve_forever, daemon=True)
        self.origin_thread.start()
        self.plugin = None
        self.send_lock = threading.Lock()
        self.exchange_lock = threading.Lock()
        self.exchanges = {}
        self.closed_exchanges = []
        self.workers = []
        self.broker_errors = []
        self.wire_values = []
        self.poison_response = False
        self.omit_receipt = False
        self.duplicate_handle = False
        self.bad_close_count = False
        self.forced_service_error = False
        self.config = {'version': 1, 'transport': 'http', 'request_timeout_ms': 10000,
            'directory': {'max_pages': 8, 'max_tools': 64}, 'http': {
                'url': f'http://127.0.0.1:{self.origin.server_port}/mcp?a=1&a=%2f&b=@exact&snow=%E9%9B%AA',
                'credential_refs': ['opaque-header'], 'max_response_bytes': 65536, 'prefer_sse': prefer_sse}}
        try:
            self.plugin = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.frames = queue.Queue()
            self.errors = bytearray()
            threading.Thread(target=self._read, daemon=True).start()
            threading.Thread(target=self._errors, daemon=True).start()
            self.counter = 0
            self.events = []
            self.allowed = {}
            self.current = None
            self.send({'type': 'hello', 'protocol': 'axyndra-js-host-v2', 'extension_id': 'mcp-client',
                'extension_version': '1.0.0', 'generation': 7, 'capabilities': ['process.channel', 'network.http']})
            assert self.next(3)['type'] == 'ready'
        except BaseException:
            self.close()
            raise

    def send(self, frame):
        with self.send_lock:
            self.wire_values.append(copy.deepcopy(frame))
            self.plugin.stdin.write((json.dumps(frame, ensure_ascii=False, separators=(',', ':')) + '\n').encode())
            self.plugin.stdin.flush()

    def next(self, timeout=15):
        value = super().next(timeout)
        self.wire_values.append(copy.deepcopy(value))
        return value

    def answer(self, message, *, fail=False):
        assert self.current is not None
        for name in base.IDENTITY:
            assert message[name] == self.current[name]
        self.events.append((message['service'], message['arguments']))
        self.wire_values.append(copy.deepcopy(message))
        worker = threading.Thread(target=self._answer, args=(message, fail), daemon=True)
        self.workers.append(worker)
        worker.start()
        return message['service']

    def _answer(self, message, fail):
        service, args = message['service'], message['arguments']
        response = {name: message[name] for name in base.IDENTITY}
        response.update(type='service_response', request_id=message['request_id'], ok=True)
        if self.poison_response:
            response['epoch'] += 1
        try:
            if fail or self.forced_service_error:
                raise OSError('fixture broker denial')
            if service == 'network.http.stream.open':
                if message['arguments'].keys() == {'request'}:
                    assert message['kind'] == 'service' and message['call_id'].startswith(('startup', 'refresh'))
                    request = args['request']
                    maintenance = True
                else:
                    assert args == {'intent_id': 'mcp-call'}
                    request = self.allowed.pop((message['run_id'], message['call_id']))
                    maintenance = False
                assert set(request) == {'method', 'url', 'headers', 'body_hex', 'credential_refs', 'timeout_ms', 'max_response_bytes'}
                assert request['method'] == 'POST' and request['url'] == self.config['http']['url']
                assert request['credential_refs'] == ['opaque-header']
                assert all(k.lower() != 'authorization' for k in request['headers'])
                body = bytes.fromhex(request['body_hex'])
                assert 0 < len(body) <= 30720 and 0 < request['timeout_ms'] <= 10000
                with self.exchange_lock:
                    handle = f'fixture-exchange-{len(self.exchanges) + 1}'
                    exchange = HttpExchange(request, handle, maintenance)
                    self.exchanges[handle] = exchange
                split = urlsplit(request['url'])
                sock = socket.create_connection((split.hostname, split.port), timeout=request['timeout_ms'] / 1000)
                with exchange.lock:
                    exchange.socket = sock
                    if exchange.closed:
                        sock.close()
                        raise OSError('closed during open')
                # Preserve path/query bytes, duplicate parameters and body.
                path = request['url'][request['url'].find('/', len('http://')):]
                headers = request['headers']
                wire = f'POST {path} HTTP/1.1\r\nHost: {split.netloc}\r\n'.encode()
                wire += b''.join((k + ': ' + v + '\r\n').encode() for k, v in headers.items())
                wire += f'Authorization: {SECRET}\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body
                sock.sendall(wire)
                head = bytearray()
                while not head.endswith(b'\r\n\r\n'):
                    part = sock.recv(1)
                    if not part:
                        raise OSError('origin closed before headers')
                    head.extend(part)
                    assert len(head) <= 32768
                lines = bytes(head).decode('iso-8859-1').split('\r\n')
                metadata = dict(line.split(': ', 1) for line in lines[1:] if line)
                exchange.length = int(metadata['Content-Length']) if 'Content-Length' in metadata else None
                response['result'] = {'exchange_id': 'fixture-exchange-1' if self.duplicate_handle else handle,
                    'status': int(lines[0].split()[1]), 'content_type': metadata['Content-Type'], 'body_size': exchange.length}
            elif service == 'network.http.stream.read':
                assert set(args) == {'exchange_id', 'max_bytes', 'wait_ms'}
                assert 1 <= args['max_bytes'] <= 16384 and 0 <= args['wait_ms'] <= 25
                exchange = self.exchanges[args['exchange_id']]
                with exchange.lock:
                    if exchange.closed:
                        raise OSError('cancelled exchange read')
                    sock = exchange.socket
                try:
                    data = sock.recv(args['max_bytes']) if select.select([sock], [], [], args['wait_ms'] / 1000)[0] else None
                except (OSError, ValueError):
                    raise OSError('cancelled exchange read') from None
                if data and SECRET.encode() in data:
                    # The host owns this boundary. The plugin never receives
                    # the secret and can only propagate unknown/no retry.
                    raise OSError('private HTTP output withheld')
                with exchange.lock:
                    if data is not None:
                        exchange.received += len(data)
                        exchange.eof = not data or exchange.length == exchange.received
                    result = {'bytes_hex': data.hex() if data else '', 'eof': exchange.eof}
                response['result'] = result
            elif service == 'network.http.stream.close':
                assert set(args) == {'exchange_id'}
                exchange = self.exchanges[args['exchange_id']]
                assert not exchange.closed
                exchange.close()
                self.closed_exchanges.append(exchange.handle)
                response['result'] = {'closed': True, 'receipt_id': None if exchange.maintenance or self.omit_receipt
                    else 'fixture-http-completed-receipt', 'body_eof': exchange.eof,
                    'consumed_bytes': exchange.received + int(self.bad_close_count)}
            else:
                raise AssertionError(service)
        except (OSError, ConnectionError):
            response['ok'] = False
            response['error'] = {'code': 'fixture.http_unknown', 'message': 'HTTP exchange failed'}
        except BaseException as error:
            self.broker_errors.append(repr(error))
            response['ok'] = False
            response['error'] = {'code': 'fixture.assertion', 'message': 'protocol fixture rejected request'}
        try:
            self.send(response)
        except (BrokenPipeError, OSError, ValueError):
            pass

    def start(self, config=None):
        return self.invoke({'action': 'start', 'configuration': self.config if config is None else config},
                           call='startup', run='maintenance')
    def refresh(self, config=None):
        return self.invoke({'action': 'refresh', 'configuration': self.config if config is None else config},
                           call='refresh-' + str(self.counter), run='refresh-maintenance')
    def prepare(self, *, data=None, call='call-1', run='run-1', tool=None):
        result = self.invoke({'action': 'call', 'tool': tool or base.local_name(), 'input': {} if data is None else data},
                             kind='service_prepare', call=call, run=run)
        if result['ok']:
            self.allowed[(run, call)] = copy.deepcopy(result['result']['intents'][0]['request'])
        return result
    def execute(self, prepared, *, data=None, call='call-1', run='run-1', tool=None):
        intents = copy.deepcopy(prepared['result']['intents'])
        for intent in intents:
            intent['network'] = {'protocol_fixture': True}
        return self.invoke({'action': 'call', 'tool': tool or base.local_name(), 'input': {} if data is None else data,
            'host_plan': {'version': 'http-stream-intents/v1', 'binding': {'protocol_fixture': True}, 'intents': intents}},
            call=call, run=run)
    def observed(self):
        return self.origin.observed
    def assert_clean(self):
        assert not self.broker_errors, self.broker_errors
        assert SECRET not in json.dumps(self.wire_values, ensure_ascii=False)
        assert SECRET.encode() not in self.errors
    def close(self):
        for exchange in list(self.exchanges.values()):
            exchange.close()
        if self.plugin is not None:
            if self.plugin.poll() is None:
                self.plugin.kill()
            self.plugin.wait(timeout=3)
            for stream in (self.plugin.stdin, self.plugin.stdout, self.plugin.stderr):
                if stream:
                    try:
                        stream.close()
                    except (BrokenPipeError, OSError):
                        pass
        self.origin.shutdown()
        self.origin.server_close()
        for worker in self.workers:
            worker.join(timeout=1)
        self.directory.cleanup()


class NativeMcpHttpTests(unittest.TestCase):
    def test_explicit_public_origin_and_headers_are_frozen_in_actual_exchange(self):
        with HttpPeer() as peer:
            peer.config['http']['origin'] = 'https://client.example.test'
            peer.config['http']['headers'] = {'X-Deployment': 'public-operator'}
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            self.assertTrue(prepared['ok'], prepared)
            headers = prepared['result']['intents'][0]['request']['headers']
            self.assertEqual(headers['Origin'], 'https://client.example.test')
            self.assertEqual(headers['X-Deployment'], 'public-operator')
            self.assertTrue(peer.execute(prepared)['ok'])
            for observed in peer.observed():
                self.assertEqual(observed['headers']['origin'], 'https://client.example.test')
                self.assertEqual(observed['headers']['x-deployment'], 'public-operator')
            peer.assert_clean()

    def test_public_header_configuration_cannot_smuggle_auth_or_protocol_headers(self):
        invalid = [{'headers': {'Authorization': 'secret'}}, {'headers': {'Cookie': 'secret'}},
                   {'headers': {'Origin': 'https://client.example.test'}}, {'headers': {'Mcp-Method': 'forged'}},
                   {'headers': {'Proxy-Authorization': 'secret'}}, {'headers': {'X-Case': 'a', 'x-case': 'b'}},
                   {'headers': {'X-Header': 'bad\nvalue'}}, {'headers': {'X-Header': 42}},
                   {'headers': None}, {'origin': 42}, {'origin': 'https://client.example.test/forbidden'}]
        for replacement in invalid:
            with self.subTest(replacement=replacement), HttpPeer() as peer:
                peer.config['http'].update(replacement)
                self.assertFalse(peer.start()['ok'])
                self.assertEqual(peer.observed(), [])
                peer.assert_clean()

    def test_open_uses_frozen_request_timeout_and_cannot_exceed_it(self):
        with HttpPeer('slow-head') as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            started = time.monotonic()
            result = peer.execute(prepared)
            self.assertTrue(result['ok'], result)
            self.assertGreater(time.monotonic() - started, 5)
            self.assertLess(time.monotonic() - started, 10)
            self.assertEqual(len(peer.observed()), 3)
            peer.assert_clean()
        with HttpPeer('hold') as peer:
            peer.config['request_timeout_ms'] = 1000
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            started = time.monotonic()
            result = peer.execute(prepared)
            self.assertFalse(result['ok'])
            self.assertEqual(result['result']['status'], 'unknown')
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(len(peer.observed()), 3)
            self.assertFalse(peer.prepare(call='no-retry')['ok'])
            peer.assert_clean()

    def test_real_http_pure_prepare_preserves_full_frozen_request_and_opaque_auth(self):
        with HttpPeer() as peer:
            self.assertTrue(peer.start()['ok'])
            peer.idle()
            before = len(peer.events)
            data = {'snow': '雪 &=+?#/%\n\\"', 'second': {'a': 1, 'b': 2}}
            prepared = peer.prepare(data=data)
            again = peer.prepare(data={'second': {'b': 2, 'a': 1}, 'snow': data['snow']})
            self.assertTrue(prepared['ok'])
            self.assertEqual(prepared['result'], again['result'])
            self.assertEqual(len(peer.events), before)
            request = prepared['result']['intents'][0]['request']
            self.assertEqual(request['url'], peer.config['http']['url'])
            self.assertEqual(request['credential_refs'], ['opaque-header'])
            self.assertFalse(any(k.lower() == 'authorization' for k in request['headers']))
            result = peer.execute(prepared, data=data)
            self.assertTrue(result['ok'], result)
            self.assertEqual(peer.observed()[-1]['body'], bytes.fromhex(request['body_hex']))
            self.assertEqual(peer.observed()[-1]['headers']['mcp-method'], 'tools/call')
            self.assertEqual(peer.observed()[-1]['path'], '/mcp?a=1&a=%2f&b=@exact&snow=%E9%9B%AA')
            self.assertTrue(all(item['authorized'] for item in peer.observed()))
            self.assertEqual(len(peer.closed_exchanges), 3)
            self.assertEqual([args for service, args in peer.events[before:] if service.endswith('.open')], [{'intent_id': 'mcp-call'}])
            peer.idle(); peer.assert_clean()

    def test_prefer_sse_uses_real_accept_and_closes_open_body_after_matching_response(self):
        with HttpPeer(prefer_sse=True) as peer:
            self.assertTrue(peer.start()['ok'])
            peer.origin.closed.clear()
            result = peer.execute(peer.prepare())
            self.assertTrue(result['ok'], result)
            self.assertTrue(peer.origin.closed.wait(2))
            self.assertTrue(all(item['headers']['accept'].startswith('text/event-stream') for item in peer.observed()))
            closes = [value['result'] for value in peer.wire_values if value.get('type') == 'service_response'
                      and value.get('result', {}).get('receipt_id') == 'fixture-http-completed-receipt']
            self.assertEqual(len(closes), 1)
            self.assertFalse(closes[0]['body_eof'])
            peer.idle(); peer.assert_clean()

    def test_http_refresh_uses_new_bounded_window_and_invalidates_old_prepared(self):
        with HttpPeer('refresh') as peer:
            self.assertTrue(peer.start()['ok'])
            old = peer.prepare()
            refreshed = peer.refresh()
            self.assertTrue(refreshed['ok'])
            self.assertEqual(refreshed['result']['tools'][0]['name'], base.local_name('remote.updated:雪'))
            self.assertEqual(peer.execute(old)['result']['error'], 'mcp_plugin.prepared_consumed')
            new = peer.prepare(tool=base.local_name('remote.updated:雪'), call='new')
            self.assertTrue(peer.execute(new, tool=base.local_name('remote.updated:雪'), call='new')['ok'])
            self.assertEqual([json.loads(x['body'])['method'] for x in peer.observed()],
                             ['server/discover', 'tools/list', 'tools/list', 'tools/call'])
            peer.assert_clean()

    def test_missing_receipt_or_wrong_close_count_cannot_publish_success(self):
        for mode in ('receipt', 'count'):
            with self.subTest(mode=mode), HttpPeer() as peer:
                self.assertTrue(peer.start()['ok'])
                prepared = peer.prepare()
                peer.omit_receipt = mode == 'receipt'; peer.bad_close_count = mode == 'count'
                result = peer.execute(prepared)
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['status'], 'unknown')
                self.assertEqual(len(peer.observed()), 3)
                self.assertEqual(peer.prepare(call='retry')['result']['error'], 'mcp_plugin.session_closed')
                peer.assert_clean()

    def test_request_or_identity_mutation_is_rejected_without_another_http_exchange(self):
        for field in ('url', 'headers', 'body_hex', 'credential_refs'):
            with self.subTest(field=field), HttpPeer() as peer:
                self.assertTrue(peer.start()['ok'])
                prepared = peer.prepare()
                changed = copy.deepcopy(prepared)
                request = changed['result']['intents'][0]['request']
                request[field] = {'url': peer.config['http']['url'] + '&new=1', 'headers': {},
                                  'body_hex': '7b7d', 'credential_refs': []}[field]
                result = peer.execute(changed)
                self.assertEqual(result['result']['error'], 'mcp_plugin.intent_mismatch')
                self.assertEqual(len(peer.observed()), 2)
                self.assertTrue(peer.execute(prepared)['ok'])
                peer.assert_clean()

    def test_duplicate_exchange_handle_and_foreign_response_fail_closed(self):
        for mode in ('duplicate', 'foreign'):
            with self.subTest(mode=mode), HttpPeer() as peer:
                self.assertTrue(peer.start()['ok'])
                prepared = peer.prepare()
                peer.duplicate_handle = mode == 'duplicate'; peer.poison_response = mode == 'foreign'
                if mode == 'foreign':
                    with self.assertRaises(EOFError):
                        peer.execute(prepared)
                else:
                    result = peer.execute(prepared)
                    self.assertFalse(result['ok'])
                    self.assertEqual(result['result']['status'], 'unknown')
                self.assertEqual(len(peer.observed()), 3)
                peer.assert_clean()

    def test_error_disconnect_and_private_output_failure_never_retry(self):
        for mode in ('status', 'disconnect', 'secret-echo', 'truncated'):
            with self.subTest(mode=mode), HttpPeer(mode) as peer:
                self.assertTrue(peer.start()['ok'])
                result = peer.execute(peer.prepare())
                self.assertFalse(result['ok'])
                self.assertEqual(result['result']['status'], 'unknown')
                self.assertFalse(result['result']['retry_safe'])
                self.assertEqual(len(peer.observed()), 3)
                self.assertEqual(peer.prepare(call='retry')['result']['error'], 'mcp_plugin.session_closed')
                self.assertEqual(len(peer.observed()), 3)
                peer.assert_clean()

    def test_cancel_interrupts_pending_real_open_and_read_without_late_terminal(self):
        for mode in ('cancel-open', 'cancel-read'):
            with self.subTest(mode=mode), HttpPeer(mode) as peer:
                self.assertTrue(peer.start()['ok'])
                prepared = peer.prepare()
                intents = copy.deepcopy(prepared['result']['intents'])
                intents[0]['network'] = {'protocol_fixture': True}
                frame = peer.invocation({'action': 'call', 'tool': base.local_name(), 'input': {},
                    'host_plan': {'version': 'http-stream-intents/v1', 'binding': {'protocol_fixture': True}, 'intents': intents}})
                peer.current = frame; peer.send(frame)
                request = peer.next()
                self.assertEqual(request['service'], 'network.http.stream.open')
                peer.answer(request)
                self.assertTrue(peer.origin.called.wait(3))
                pending_read = None
                if mode == 'cancel-read':
                    pending_read = peer.next(3)
                    self.assertEqual(pending_read['service'], 'network.http.stream.read')
                    # Leave this actually issued read unacknowledged until
                    # cancellation, then deliver the original correlated reply.
                cancelled = dict(frame, type='cancel'); cancelled.pop('arguments')
                started = time.monotonic(); peer.send(cancelled)
                self.assertEqual(peer.next(1)['type'], 'cancelled')
                self.assertLess(time.monotonic() - started, 1)
                if pending_read is not None:
                    peer.answer(pending_read)
                for exchange in peer.exchanges.values():
                    exchange.close()
                self.assertTrue(peer.origin.closed.wait(2))
                peer.current = None
                peer.idle()
                self.assertEqual(len(peer.observed()), 3)
                peer.assert_clean()

    def test_nonsecret_http_configuration_rejects_secret_proxy_and_unbounded_values_before_io(self):
        with HttpPeer() as peer:
            configs = []
            for key, value in [('bearer_token', SECRET), ('proxy', 'http://localhost:1234'),
                               ('max_response_bytes', 1048577), ('credential_refs', ['same', 'same']),
                               ('prefer_sse', 'yes'), ('url', 'http://user@localhost/mcp')]:
                config = copy.deepcopy(peer.config); config['http'][key] = value; configs.append(config)
            for config in configs:
                self.assertFalse(peer.start(config)['ok'])
            self.assertEqual(peer.events, [])
            self.assertEqual(peer.observed(), [])
            # Deliberately submitted invalid secret must not be echoed by the endpoint.
            self.assertNotIn(SECRET.encode(), peer.errors)

    def test_business_error_is_complete_exchange_and_cached_request_cannot_dispatch_twice(self):
        with HttpPeer('business-error') as peer:
            self.assertTrue(peer.start()['ok'])
            prepared = peer.prepare()
            response = peer.execute(prepared)
            self.assertFalse(response['ok'])
            self.assertEqual(response['result']['status'], 'complete')
            self.assertEqual(response['result']['error'], 'mcp_plugin.tool_error')
            self.assertEqual(peer.execute(prepared)['result']['error'], 'mcp_plugin.prepared_consumed')
            self.assertEqual(len(peer.observed()), 3)
            peer.idle(); peer.assert_clean()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    if sys.platform != 'linux':
        parser.error('native plugin protocol contracts require Linux')
    unittest.main(argv=[sys.argv[0], *remaining], verbosity=2)
