#!/usr/bin/env python3
"""Exercise OpenCode v2 sessions, async prompts, SSE, and canonical reads."""
import argparse
import base64
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import socket
import threading
import time

from fixture import load_manifest, private_json, request, require, verify
from scenarios import expected_output


PNG = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC')


class Events:
    def __init__(self, manifest):
        self.condition = threading.Condition()
        self.items = []
        self.error = None
        self.connection = http.client.HTTPConnection('127.0.0.1', 14097, timeout=60)
        auth = base64.b64encode(('opencode:' + manifest['password']).encode()).decode()
        self.connection.request('GET', '/api/event',
                                headers={'Authorization': 'Basic ' + auth})
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
                for event in self.items[after:]:
                    properties = event.get('data', {})
                    if event.get('type') != kind:
                        continue
                    if session is not None and properties.get('sessionID') != session:
                        continue
                    if delta is not None and properties.get('delta') != delta:
                        continue
                    return event
                return None
            self.condition.wait_for(lambda: match() or self.error, timeout=25)
            found = match()
            require(found is not None, 'Missing SSE ' + kind + '; observed: ' +
                    ','.join(sorted({e.get('type', '?') for e in self.items})))
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


def wait_idle(manifest, session):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if session not in request(manifest, '/api/session/active')['data']:
            return
        time.sleep(0.05)
    raise RuntimeError('Session did not become idle')


def run(manifest):
    identity = verify(manifest)
    info = request(manifest, '/api/info')
    require(info['version'] == manifest['version'] and info['pid'] == manifest['server_pid'],
            'Wrong v2 runtime identity')
    location = request(manifest, '/api/location')
    require(Path(location['directory']).resolve() == Path(manifest['workspace']).resolve()
            and Path(location['project']['directory']).resolve() == Path(manifest['workspace']).resolve(),
            'Wrong v2 location')
    provider = request(manifest, '/api/provider/test')['data']
    require(provider['id'] == 'test' and provider['package'] == '@opencode/ai/providers/openai-compatible',
            'Wrong v2 provider')
    agents = request(manifest, '/api/agent')['data']
    require(any(a['id'] == 'build' and a.get('model') == {'providerID': 'test', 'id': 'test-model'}
                for a in agents), 'Configured native protocol agent missing')
    commands = request(manifest, '/api/command')['data']
    require(sum(c['name'] == 'acceptance' for c in commands) == 1,
            'Configured native protocol command missing or duplicated')
    page = request(manifest, '/api/session?order=desc&limit=1')
    require(isinstance(page.get('data'), list) and isinstance(page.get('cursor'), dict),
            'Wrong native protocol session page')
    events = Events(manifest)
    results = []
    try:
        for scenario in ('stream', 'reasoning', 'attachment', 'interrupt'):
            marker = f'[[acceptance:{scenario}:{secrets.token_hex(8)}]]'
            expected = expected_output(marker)
            with events.condition:
                cursor = len(events.items)
            session = request(manifest, '/api/session',
                              {'location': {'directory': manifest['workspace']}})['data']
            session_id = session['id']
            try:
                prompt = {'text': marker, 'resume': True}
                if scenario == 'attachment':
                    prompt['files'] = [{'name': 'pixel.png',
                                        'uri': 'data:image/png;base64,' + base64.b64encode(PNG).decode()}]
                admitted = request(manifest, f'/api/session/{session_id}/prompt',
                                   prompt)['data']
                require(admitted, 'v2 prompt was not durably admitted')
                provider_request = control_wait(manifest, marker, 'request')
                require(provider_request['expected'] == expected, 'Wrong output expectation contract')
                held = control_wait(manifest, marker, 'held')
                first = events.wait('session.text.delta', session_id, expected['first'], after=cursor)
                statuses = request(manifest, '/api/session/active')['data']
                require(statuses.get(session_id, {}).get('type') == 'running',
                        'Session is not running while held')
                state = request(manifest, '/control/status', provider=True)
                require(not any(event['kind'] == 'finished' and event['marker'] == marker
                                for event in state['events']),
                        'Provider completed before the first streamed delta was asserted')
                if scenario == 'reasoning':
                    events.wait('session.reasoning.delta', session_id, expected['reasoning'], after=cursor)
                if scenario == 'attachment':
                    require(provider_request['media'] == [{'mime': 'image/png', 'bytes': len(PNG),
                            'sha256': hashlib.sha256(PNG).hexdigest()}], 'Image did not reach provider unchanged')
                if scenario == 'interrupt':
                    interrupted = request(manifest, f'/api/session/{session_id}/interrupt', {}, method='POST')
                    require(interrupted.get('interrupted') is True, 'v2 interrupt did not stop execution')
                    control_wait(manifest, marker, 'disconnected')
                else:
                    request(manifest, '/control/advance', {'marker': marker}, provider=True)
                    events.wait('session.text.delta', session_id, expected['chunks'][1], after=cursor)
                    control_wait(manifest, marker, 'held', after=held['seq'])
                    request(manifest, '/control/finish', {'marker': marker}, provider=True)
                    control_wait(manifest, marker, 'finished')
                wait_idle(manifest, session_id)
                messages = request(manifest, f'/api/session/{session_id}/message?order=asc&limit=200')['data']
                assistants = [m for m in messages if m.get('type') == 'assistant']
                require(len(assistants) == 1, 'Unexpected assistant response count')
                assistant = assistants[0]
                text = ''.join(p.get('text', '') for p in assistant['content'] if p['type'] == 'text')
                require(text == expected['first' if scenario == 'interrupt' else 'final'],
                        'Canonical text mismatch')
                if scenario != 'interrupt':
                    require(not assistant.get('error') and assistant.get('finish') == 'stop',
                            'Completion failed')
                else:
                    require(assistant.get('error', {}).get('type') == 'aborted',
                            'Missing canonical interruption')
                if scenario == 'reasoning':
                    require([part['text'] for part in assistant['content'] if part['type'] == 'reasoning'] ==
                            [expected['reasoning']], 'Canonical reasoning mismatch')
                state = request(manifest, '/control/status', provider=True)
                own_events = [e for e in state['events'] if e['marker'] == marker]
                require(sum(e['kind'] == 'request' for e in own_events) == 1, 'Unexpected provider retry')
                if scenario == 'interrupt':
                    require(not any(e['kind'] == 'finished' for e in own_events),
                            'Interrupted provider stream completed')
                results.append({'scenario': scenario, 'session_id': session_id,
                                'sse_type': first['type'], 'canonical_text': text, 'passed': True})
                print(json.dumps({'scenario': scenario, 'session_id': session_id, 'passed': True}), flush=True)
            finally:
                request(manifest, f'/api/session/{session_id}', method='DELETE')
        state = request(manifest, '/control/status', provider=True)
        require(not any(event['kind'] in ('rejected', 'hold_timeout') for event in state['events']),
                'Unexpected provider rejection or timeout')
        evidence = {'identity': identity, 'results': results, 'passed': True}
        private_json(Path(manifest['root']) / 'smoke-evidence.json', evidence)
    finally:
        events.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    args = parser.parse_args()
    run(load_manifest(args.manifest))
