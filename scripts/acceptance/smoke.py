#!/usr/bin/env python3
"""Exercise real v2 prompt/resume/wait/SSE against an owned fixture only."""
import argparse
import base64
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import socket
import struct
import threading
import zlib

from fixture import load_manifest, private_json, request, require, verify
from scenarios import BUG_PROMPT, BUG_ANSWER, BUG_CODE, BUG_WIN, COLOR_PNG, expected_output, fixture_url

def png_chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))


PNG = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('!2I5B', 1, 1, 8, 2, 0, 0, 0))
       + png_chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00')) + png_chunk(b'IEND', b''))


class Events:
    def __init__(self, manifest):
        self.condition = threading.Condition()
        self.items = []
        self.error = None
        self.connection = http.client.HTTPConnection('127.0.0.1', 14097, timeout=60)
        auth = base64.b64encode(('opencode:' + manifest['password']).encode()).decode()
        self.connection.request('GET', '/api/event', headers={'Authorization': 'Basic ' + auth})
        self.response = self.connection.getresponse()
        require(self.response.status == 200, 'SSE connection failed')
        self.socket = self.response.fp.raw._sock
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.wait('server.connected')

    def read(self):
        data = []
        try:
            for raw in self.response:
                line = raw.decode().rstrip('\r\n')
                if line.startswith('data:'):
                    data.append(line[5:].lstrip())
                elif not line and data:
                    event = json.loads('\n'.join(data))
                    data = []
                    with self.condition:
                        self.items.append(event)
                        self.condition.notify_all()
        except Exception as error:
            with self.condition:
                self.error = type(error).__name__
                self.condition.notify_all()

    def wait(self, kind, session=None, delta=None, after=0):
        with self.condition:
            def match():
                return next((e for e in self.items[after:] if e['type'] == kind
                             and (session is None or e.get('data', {}).get('sessionID') == session)
                             and (delta is None or e.get('data', {}).get('delta') == delta)), None)
            self.condition.wait_for(lambda: match() or self.error, timeout=25)
            found = match()
            require(found is not None, 'Missing SSE ' + kind + '; observed: ' +
                    ','.join(sorted({e['type'] for e in self.items})))
            return found

    def close(self):
        self.socket.shutdown(socket.SHUT_RDWR)
        self.thread.join(timeout=3)
        self.response.close()
        self.connection.close()


def control_wait(manifest, marker, kind, after=0):
    result = request(manifest, '/control/wait', {'marker': marker, 'kind': kind, 'after': after}, provider=True)
    require(result['events'], 'Missing provider event ' + kind)
    return result['events'][-1]


def run(manifest):
    identity = verify(manifest)
    default = request(manifest, '/api/model/default')['data']
    require(default['providerID'] == 'scripted' and default['id'] == 'test-model', 'Wrong default model')
    events = Events(manifest)
    results = []
    try:
        commands = request(manifest, '/api/command')['data']
        require([c['name'] for c in commands] == ['acceptance'], 'Wrong command catalog')
        for scenario in ('stream', 'reasoning', 'attachment', 'interrupt', 'resume',
                         'page-share', 'color-image', 'command', 'bug-setup', 'bug-answer'):
            suffix = secrets.token_hex(8)
            marker_scenario = {'resume': 'stream', 'command': 'stream',
                               'page-share': 'attachment', 'color-image': 'attachment'}.get(scenario, scenario)
            marker = f'[[acceptance:{marker_scenario}:{suffix}]]'
            # Do not pass a model: this proves deterministic automatic selection.
            if scenario not in ('resume', 'bug-answer'):
                session = request(manifest, '/api/session', {
                    'title': 'Owned scripted ' + scenario,
                    **({'agent': 'plan'} if scenario == 'bug-setup' else {}),
                    'location': {'directory': manifest['workspace']}})['data']['id']
            if scenario == 'bug-setup':
                marker = f'[[acceptance:bug-setup:{session}]]'
            expected = expected_output(marker)
            body = {'text': marker, 'resume': True}
            image = PNG
            if scenario in ('page-share', 'color-image'):
                url = fixture_url(marker, download=scenario == 'color-image')
                # Public static assets are fetched without any Authorization header.
                connection = http.client.HTTPConnection('127.0.0.1', 14098, timeout=3)
                try:
                    connection.request('GET', url.removeprefix('http://127.0.0.1:14098'))
                    response = connection.getresponse()
                    require(response.status == 200, 'Missing static fixture asset')
                    asset = response.read()
                    if scenario == 'page-share':
                        require(b'<html' in asset and marker.encode() in asset, 'Invalid Safari page')
                        require(all(secret.encode() not in asset for secret in
                                    (manifest['password'], manifest['control_token'])), 'Secret in public page')
                        body['text'] = url
                    else:
                        require(response.getheader('Content-Type') == 'image/png' and asset == COLOR_PNG,
                                'Invalid color PNG download')
                        image = asset
                finally:
                    connection.close()
            if scenario == 'color-image':
                body['files'] = [{'uri': 'data:image/png;base64,' + base64.b64encode(image).decode(),
                                  'name': 'acceptance-color.png'}]
            if scenario == 'attachment':
                body['files'] = [{'uri': 'data:image/png;base64,' + base64.b64encode(PNG).decode(),
                                  'name': 'pixel.png'}]
            if scenario == 'bug-setup':
                body['text'] = BUG_PROMPT
            if scenario == 'bug-answer':
                body['text'] = BUG_ANSWER + '\n' + marker
            route = 'prompt'
            if scenario == 'command':
                route = 'command'
                body = {'command': 'acceptance', 'arguments': suffix, 'resume': True}
            with events.condition:
                cursor = len(events.items)
            admitted = request(manifest, f'/api/session/{session}/{route}', body)
            require(admitted['data'], 'Prompt was not durably admitted')
            first = events.wait('session.text.delta', session, expected['first'], after=cursor)
            provider_request = control_wait(manifest, marker, 'request')
            require(provider_request['expected'] == expected, 'Wrong output expectation contract')
            held = control_wait(manifest, marker, 'held')
            state = request(manifest, '/control/status', provider=True)
            require(not any(e['kind'] == 'finished' and e['marker'] == marker for e in state['events']),
                    'Provider completed before progress assertion')
            require(session in request(manifest, '/api/session/active')['data'], 'Session is not actively streaming')
            if scenario == 'reasoning':
                events.wait('session.reasoning.delta', session, expected['reasoning'], after=cursor)
            if scenario in ('attachment', 'color-image'):
                require(provider_request['media'] == [{'mime': 'image/png', 'bytes': len(image),
                        'sha256': hashlib.sha256(image).hexdigest()}], 'Image did not reach provider unchanged')
            if scenario == 'interrupt':
                request(manifest, f'/api/session/{session}/interrupt', method='POST')
                control_wait(manifest, marker, 'disconnected')
            else:
                request(manifest, '/control/advance', {'marker': marker}, provider=True)
                events.wait('session.text.delta', session, expected['chunks'][1], after=cursor)
                control_wait(manifest, marker, 'held', after=held['seq'])
                request(manifest, '/control/finish', {'marker': marker}, provider=True)
                control_wait(manifest, marker, 'finished')
            request(manifest, f'/api/session/{session}/wait', method='POST')
            context = request(manifest, f'/api/session/{session}/context')['data']
            assistants = [m for m in context if m['type'] == 'assistant']
            require(len(assistants) == (2 if scenario in ('resume', 'bug-answer') else 1), 'Unexpected assistant response count')
            assistant = assistants[-1]
            require(assistant['model']['providerID'] == 'scripted', 'Wrong canonical model')
            require(all(p['type'] in ('text', 'reasoning') for p in assistant['content']),
                    'Unexpected tool call in fixture reply')
            text = ''.join(p['text'] for p in assistant['content'] if p['type'] == 'text')
            require(text == expected['first' if scenario == 'interrupt' else 'final'],
                    'Canonical text mismatch')
            if scenario != 'interrupt':
                require(not assistant.get('error') and assistant.get('finish') == 'stop', 'Completion failed')
            else:
                require(assistant.get('error', {}).get('type') == 'aborted', 'Missing canonical interruption')
            if scenario == 'reasoning':
                require([p['text'] for p in assistant['content'] if p['type'] == 'reasoning'] ==
                        [expected['reasoning']], 'Canonical reasoning mismatch')
            if scenario == 'bug-setup':
                require(text.count('```') == 2 and BUG_CODE in text and BUG_WIN not in text,
                        'Invalid Find the Bug puzzle format')
            if scenario == 'bug-answer':
                require(text == BUG_WIN, 'Invalid Find the Bug solved marker')
            state = request(manifest, '/control/status', provider=True)
            own_events = [e for e in state['events'] if e['marker'] == marker]
            require(sum(e['kind'] == 'request' for e in own_events) == 1, 'Unexpected provider retry')
            if scenario == 'interrupt':
                require(not any(e['kind'] == 'finished' for e in own_events), 'Interrupted stream completed')
            results.append({'scenario': scenario, 'session_id': session, 'marker': marker,
                            'sse_first_delta': first['data']['delta'], 'canonical_text': text,
                            'expected': expected, 'api_route': route,
                            'finish': assistant.get('finish'), 'error_type': (assistant.get('error') or {}).get('type'),
                            'provider_events': own_events, 'passed': True})
            print(json.dumps({'scenario': scenario, 'session_id': session, 'passed': True}), flush=True)
        state = request(manifest, '/control/status', provider=True)
        require(not any(e['kind'] in ('rejected', 'hold_timeout') for e in state['events']),
                'Unexpected provider requests/timeouts')
        evidence = {'identity': identity, 'results': results, 'passed': True}
        private_json(Path(manifest['root']) / 'smoke-evidence.json', evidence)
    finally:
        events.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    args = parser.parse_args()
    run(load_manifest(args.manifest))
