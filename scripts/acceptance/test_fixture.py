"""Fixture-only regression tests. No OpenCode session or personal configuration access."""
import base64
from contextlib import closing
import hashlib
import http.client
import json
from pathlib import Path
import re
import socket
import struct
import tempfile
import textwrap
import threading
import unittest
from unittest.mock import patch
import zlib

import fixture
from scenarios import (BUG_PROMPT, BUG_SETUP, BUG_CODE, BUG_WIN, BUG_ANSWER, COLOR_PNG, COLOR_INFO,
                       expected_output, fixture_url, marker_in_text, scenario_for_messages)


class SafetyTests(unittest.TestCase):
    def test_configuration_has_one_native_provider_and_deny_default(self):
        config = fixture.configuration()
        self.assertEqual(list(config['providers']), ['scripted'])
        provider = config['providers']['scripted']
        self.assertEqual(provider['package'], 'aisdk:@ai-sdk/openai-compatible')
        self.assertEqual(provider['settings']['baseURL'], fixture.PROVIDER + '/v1')
        self.assertEqual(list(provider['models']), ['test-model'])
        self.assertEqual(config['experimental']['policies'], [
            {'action': 'provider.use', 'resource': '*', 'effect': 'deny'},
            {'action': 'provider.use', 'resource': 'scripted', 'effect': 'allow'}])
        self.assertEqual(config['plugins'], ['-opencode.command'])
        self.assertEqual(list(config['commands']), ['acceptance'])
        self.assertEqual(config['commands']['acceptance']['template'], '[[acceptance:stream:$ARGUMENTS]]')
        self.assertEqual(config['permissions'], [{'action': '*', 'resource': '*', 'effect': 'deny'}])

    def test_environment_is_not_inherited(self):
        with patch.dict('os.environ', {'OPENAI_API_KEY': 'must-not-leak', 'HTTPS_PROXY': 'must-not-leak'}):
            env = fixture.environment(Path('/fixture'), {'password': 'fixture-only'})
        self.assertNotIn('OPENAI_API_KEY', env)
        self.assertNotIn('HTTPS_PROXY', env)
        self.assertEqual(env['HOME'], '/fixture/home')
        self.assertEqual(env['OPENCODE_DISABLE_MODELS_FETCH'], '1')
        self.assertEqual(env['OPENCODE_CONFIG_PROJECT_DISABLE'], '1')

    def test_forbidden_bases_fail_before_network(self):
        for base in ('http://127.0.0.1:4096', 'http://127.0.0.1:4097', 'https://example.com'):
            with self.assertRaisesRegex(RuntimeError, 'Forbidden endpoint'):
                fixture.request({'base_url': base, 'provider_url': fixture.PROVIDER}, '/api/session', {})

    def test_arbitrary_manifest_root_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'Unapproved root'):
            fixture.load_manifest('/tmp/manifest.json')

    def test_media_is_only_hash_mime_size(self):
        encoded = base64.b64encode(b'fixture image').decode()
        result = fixture.media_summary({'messages': [{'content': [
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + encoded}},
            {'type': 'text', 'text': 'do not log this'}]}]})
        self.assertEqual(result, [{'mime': 'image/png', 'bytes': 13,
                                  'sha256': hashlib.sha256(b'fixture image').hexdigest()}])
        self.assertNotIn(encoded, json.dumps(result))
        self.assertNotIn('do not log', json.dumps(result))


class ScenarioTests(unittest.TestCase):
    def test_output_identity_and_cumulative_expectations(self):
        for scenario in ('stream', 'interrupt', 'reasoning', 'attachment'):
            one = expected_output(f'[[acceptance:{scenario}:one]]')
            two = expected_output(f'[[acceptance:{scenario}:two]]')
            self.assertEqual(one['first'], one['chunks'][0])
            self.assertEqual(one['progress'], ''.join(one['chunks'][:2]))
            self.assertEqual(one['final'], ''.join(one['chunks']))
            for field in ('first', 'progress', 'final', 'reasoning'):
                self.assertNotEqual(one[field], two[field])
                self.assertNotIn(one[field], two['final'])

    def test_url_markers_only_decode_exact_owned_origin_and_path(self):
        marker = '[[acceptance:attachment:shared]]'
        url = fixture_url(marker)
        self.assertEqual(marker_in_text('Shared page\n' + url), marker)
        self.assertEqual(marker_in_text(fixture_url(marker, True)), marker)
        for invalid in (url.replace('127.0.0.1', 'localhost'), url.replace('http:', 'https:'),
                        url.replace('14098', '4097'), url.replace('127.0.0.1', 'example.com'),
                        url.replace('127.0.0.1', 'user@127.0.0.1'), url + '?x=' + marker,
                        url + '#fragment', url.replace('%', '%25'), url.split('/fixtures/')[1],
                        'http://example.com/' + marker):
            with self.subTest(invalid=invalid):
                self.assertIsNone(marker_in_text(invalid))

    def test_last_user_message_not_history_selects_scenario(self):
        self.assertIsNone(scenario_for_messages([
            {'role': 'user', 'content': '[[acceptance:stream:old]]'},
            {'role': 'user', 'content': 'unmarked'}], 'ses_test'))

    def test_find_bug_prompt_matches_actual_product_source(self):
        source = (Path(__file__).resolve().parents[2] / 'OpenCodeIOSClient/Models/FindBugGame.swift').read_text()
        instructions = re.search(r'let instructions = String\(localized: """\n(.*?)\n        """\)',
                                 source, re.S).group(1)
        instructions = textwrap.dedent(instructions).replace(r'\(language.title)', 'Swift').replace(
            r'\(language.id)', 'swift').replace(r'\(winMarker)', BUG_WIN)
        self.assertEqual(BUG_PROMPT, BUG_SETUP + '\n<!-- OPENCLIENT_LANGUAGE_ID: swift -->\n\n' + instructions)
        self.assertIn(f'static let winMarker = "{BUG_WIN}"', source)
        store = (Path(__file__).resolve().parents[2] / 'OpenCodeIOSClient/Stores/FunAndGamesStore.swift').read_text()
        self.assertIn('FindBugGame.languageIDPrefix', store)
        self.assertEqual(re.search(r'<!-- OPENCLIENT_LANGUAGE_ID: (\w+) -->', BUG_PROMPT).group(1), 'swift')

    def test_game_requires_exact_setup_and_matching_history_for_answer(self):
        session = 'ses_test'
        setup = {'role': 'user', 'content': BUG_PROMPT}
        setup_marker = '[[acceptance:bug-setup:ses_test]]'
        self.assertEqual(scenario_for_messages([setup], session), setup_marker)
        puzzle = expected_output(setup_marker)['final']
        self.assertEqual(re.findall(r'```(\w+)\n(.*?)```', puzzle, re.S),
                         [('swift', BUG_CODE[len('```swift\n'):-3])])
        self.assertNotIn(BUG_WIN, puzzle)
        marker = '[[acceptance:bug-answer:answer1]]'
        answer = {'role': 'user', 'content': BUG_ANSWER + '\n' + marker}
        history = [setup, {'role': 'assistant', 'content': puzzle}, answer]
        self.assertEqual(scenario_for_messages(history, session), marker)
        self.assertEqual(expected_output(marker)['final'], BUG_WIN)
        self.assertIsNone(scenario_for_messages([answer], session))
        self.assertIsNone(scenario_for_messages(history, 'ses_other'))
        self.assertIsNone(scenario_for_messages([{'role': 'user', 'content': BUG_SETUP}], session))
        self.assertIsNone(scenario_for_messages([setup, {'role': 'user', 'content': '[[acceptance:stream:bypass]]'}], session))
        self.assertIsNone(scenario_for_messages([setup, {'role': 'assistant', 'content': puzzle},
                                               {'role': 'user', 'content': BUG_ANSWER}], session))

    def test_color_png_structure_crc_size_and_pixels(self):
        self.assertEqual(COLOR_PNG[:8], b'\x89PNG\r\n\x1a\n')
        offset, chunks = 8, {}
        while offset < len(COLOR_PNG):
            size = struct.unpack('!I', COLOR_PNG[offset:offset + 4])[0]
            kind = COLOR_PNG[offset + 4:offset + 8]
            data = COLOR_PNG[offset + 8:offset + 8 + size]
            crc = struct.unpack('!I', COLOR_PNG[offset + 8 + size:offset + 12 + size])[0]
            self.assertEqual(crc, zlib.crc32(kind + data))
            chunks[kind] = data
            offset += size + 12
        self.assertEqual(struct.unpack('!2I5B', chunks[b'IHDR']), (1024, 768, 8, 2, 0, 0, 0))
        pixels = zlib.decompress(chunks[b'IDAT'])
        self.assertEqual(len(pixels), (1024 * 3 + 1) * 768)
        self.assertEqual(len({pixels[y * 3073 + 1 + x * 3:y * 3073 + 4 + x * 3]
                              for y in (0, 767) for x in (0, 1023)}), 4)
        self.assertEqual(COLOR_INFO['sha256'], hashlib.sha256(COLOR_PNG).hexdigest())


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='acceptance-unit-', dir=fixture.TEMP)
        self.state = fixture.State({'root': self.directory.name, 'run_id': 'unit', 'control_token': 'unit-token'})
        self.server = fixture.ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
        self.server.daemon_threads = True
        self.server.state = self.state
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        with self.state.condition:
            self.state.stop.set()
            self.state.condition.notify_all()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def connection(self):
        return http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)

    def test_auth_required_and_not_logged(self):
        with closing(self.connection()) as connection:
            connection.request('GET', '/control/status')
            self.assertEqual(connection.getresponse().status, 401)
        self.assertEqual(self.state.events, [])

    def test_unmarked_prompt_rejected(self):
        with closing(self.connection()) as connection:
            connection.request('POST', '/v1/chat/completions', json.dumps({
                'model': 'test-model', 'stream': True,
                'messages': [{'role': 'user', 'content': 'unapproved prompt'}]}),
                {'Authorization': 'Bearer unit-token'})
            self.assertEqual(connection.getresponse().status, 400)
        self.assertEqual(self.state.events[0]['reason'], 'missing_marker')
        self.assertNotIn('unapproved prompt', json.dumps(self.state.events))

    def test_chunked_request_real_sse_and_controlled_completion(self):
        marker = '[[acceptance:stream:unit]]'
        body = json.dumps({'model': 'test-model', 'stream': True,
                           'messages': [{'role': 'user', 'content': marker}]}).encode()
        with closing(self.connection()) as connection:
            connection.request('POST', '/v1/chat/completions', iter([body[:10], body[10:]]),
                               {'Authorization': 'Bearer unit-token'}, encode_chunked=True)
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            with self.state.condition:
                self.assertTrue(self.state.condition.wait_for(
                    lambda: any(e['kind'] == 'held' for e in self.state.events), 3))
                self.assertFalse(any(e['kind'] == 'finished' for e in self.state.events))
            with closing(self.connection()) as control:
                control.request('POST', '/control/finish', json.dumps({'marker': marker}),
                                {'Authorization': 'Bearer unit-token'})
                self.assertEqual(control.getresponse().status, 200)
            stream = response.read().decode()
            chunks = [json.loads(line[6:]) for line in stream.splitlines()
                      if line.startswith('data: ') and line != 'data: [DONE]']
            self.assertEqual(''.join(c['choices'][0]['delta'].get('content', '') for c in chunks),
                             expected_output(marker)['final'])
            self.assertEqual(chunks[-1]['choices'][0]['finish_reason'], 'stop')
            self.assertTrue(stream.endswith('data: [DONE]\n\n'))

    def test_transport_close_while_held_is_recorded(self):
        marker = '[[acceptance:interrupt:unit]]'
        connection = self.connection()
        connection.request('POST', '/v1/chat/completions', json.dumps({
            'model': 'test-model', 'stream': True,
            'messages': [{'role': 'user', 'content': marker}]}), {'Authorization': 'Bearer unit-token'})
        response = connection.getresponse()
        response.fp.raw._sock.shutdown(socket.SHUT_RDWR)
        response.close()
        connection.close()
        with self.state.condition:
            self.assertTrue(self.state.condition.wait_for(
                lambda: any(e['kind'] == 'disconnected' for e in self.state.events), 3))
            self.assertFalse(any(e['kind'] == 'finished' for e in self.state.events))

    def test_public_assets_and_traversal_refusal_without_auth(self):
        marker = '[[acceptance:attachment:browser]]'
        for download in (False, True):
            with closing(self.connection()) as connection:
                connection.request('GET', fixture_url(marker, download).removeprefix('http://127.0.0.1:14098'))
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.getheader('Referrer-Policy'), 'no-referrer')
                data = response.read()
                if download:
                    self.assertEqual(data, COLOR_PNG)
                    self.assertEqual(response.getheader('Content-Type'), 'image/png')
                else:
                    self.assertIn(marker.encode(), data)
                    self.assertNotIn(b'unit-token', data)
                    self.assertNotIn(b'<script', data)
                    self.assertNotIn(b'http', data)
        for path in ('/fixtures/../../manifest.json', '/fixtures/%2e%2e/server.log',
                     '/fixtures/%252e%252e/server.log', '/fixtures/unknown/page',
                     fixture_url(marker).removeprefix('http://127.0.0.1:14098') + '?token=anything'):
            with closing(self.connection()) as connection:
                connection.request('GET', path)
                response = connection.getresponse()
                self.assertEqual(response.status, 404)
                response.read()
        with closing(self.connection()) as connection:
            connection.request('GET', '/control/status')
            self.assertEqual(connection.getresponse().status, 401)
        self.assertEqual(self.state.events, [])


if __name__ == '__main__':
    unittest.main()
