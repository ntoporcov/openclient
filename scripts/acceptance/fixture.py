#!/usr/bin/env python3
"""Private, disposable OpenCode v2 server and scripted Chat Completions provider."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from inspect_runtime import (BINARY, BINARY_SHA256, RUNTIME_ROOT, RUNTIME_ROOT_ENV,
                             SOURCE_URL, VERSION, verify_runtime)
from scenarios import (COLOR_PNG, MARKER, OUTPUT_MARKER, expected_output, fixture_route,
                       safari_page, scenario_for_messages)

HOST_ROOT_ENV = 'OPENCLIENT_ACCEPTANCE_HOST_ROOT'
TEMP = Path(os.environ.get(HOST_ROOT_ENV, str(Path(tempfile.gettempdir()) / 'opencode'))).absolute().resolve()
BASE = 'http://127.0.0.1:14097'
PROVIDER = 'http://127.0.0.1:14098'
MODEL = 'test/test-model'
ROOT_PREFIX = 'acceptance-v2_0_16-'
PROFILE = ('(version 1)(allow default)(deny network-outbound)'
           '(allow network-outbound (remote ip "localhost:14097") (remote ip "localhost:14098"))')


def require(value, message):
    if not value:
        raise RuntimeError(message)


def private_json(path, data):
    temporary = path.with_name(path.name + '.tmp')
    with open(temporary, 'w', opener=lambda name, flags: os.open(name, flags, 0o600)) as output:
        json.dump(data, output, indent=2)
        output.write('\n')
    temporary.replace(path)


def verify_host_root():
    require(TEMP.is_absolute() and TEMP.is_dir() and not TEMP.is_symlink(),
            f'{HOST_ROOT_ENV} must name an existing real directory')
    attributes = TEMP.stat()
    require(attributes.st_uid == os.getuid(), 'Acceptance host root must be owned by the current user')
    require(attributes.st_mode & 0o022 == 0, 'Acceptance host root must not be group/other writable')
    return TEMP


def load_manifest(path):
    verify_host_root()
    path = Path(path).absolute()
    root = path.parent
    require(root.parent == TEMP and root.name.startswith(ROOT_PREFIX), 'Unapproved root')
    require(root.resolve() == TEMP.resolve() / root.name and not root.is_symlink()
            and not path.is_symlink(), 'Symlink fixture refused')
    require(path.name == 'manifest.json' and path.stat().st_mode & 0o077 == 0, 'Manifest must be private')
    data = json.loads(path.read_text())
    require((root / '.acceptance-root').read_text().strip() == data['run_id'], 'Root marker mismatch')
    require(data['host_root'] == str(TEMP) and data['root'] == str(root)
            and data['workspace'] == str(root / 'workspace'), 'Root mismatch')
    require(data['base_url'] == BASE and data['provider_url'] == PROVIDER, 'Forbidden endpoint')
    require(data['version'] == VERSION and data['model'] == MODEL, 'Fixture identity mismatch')
    require(data['username'] == 'opencode' and data['password'] and data['control_token'],
            'Fixture credentials are incomplete')
    require(data['binary'] == str(BINARY) and data['binary_sha256'] == BINARY_SHA256,
            'Fixture runtime identity mismatch')
    return data


def request(manifest, path, body=None, method=None, provider=False, timeout=30):
    require(path.startswith('/') and not path.startswith('//'), 'Relative API path required')
    require(manifest['base_url'] == BASE and manifest['provider_url'] == PROVIDER, 'Forbidden endpoint')
    token = ('Bearer ' + manifest['control_token']) if provider else (
        'Basic ' + base64.b64encode(('opencode:' + manifest['password']).encode()).decode())
    req = urllib.request.Request((PROVIDER if provider else BASE) + path,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={'Authorization': token, 'Content-Type': 'application/json'},
                                 method=method)
    # Never inherit proxy configuration, including from the calling shell.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            raise RuntimeError('Fixture redirects are forbidden')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(req, timeout=timeout) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def verify(manifest):
    info = request(manifest, '/api/info', timeout=3)
    location = request(manifest, '/api/location', timeout=3)
    require(info['version'] == VERSION and info['pid'] == manifest['server_pid'], 'Wrong runtime')
    require(Path(location['directory']).resolve() == Path(manifest['workspace']).resolve()
            and Path(location['project']['directory']).resolve() == Path(manifest['workspace']).resolve(),
            'Not the owned workspace')
    state = request(manifest, '/control/status', provider=True, timeout=3)
    require(state['run_id'] == manifest['run_id'] and state['pid'] == manifest['supervisor_pid'],
            'Supervisor identity mismatch')
    return {'run_id': manifest['run_id'], 'server_pid': manifest['server_pid'],
            'workspace': manifest['workspace']}


def configuration():
    return {
        '$schema': 'https://opencode.ai/config.json',
        'model': MODEL, 'small_model': MODEL, 'default_agent': 'build', 'autoupdate': False,
        'share': 'disabled', 'snapshot': False, 'formatter': False, 'lsp': False,
        'skills': {'paths': [], 'urls': []}, 'plugin': [], 'enabled_providers': ['test'],
        'command': {'acceptance': {'description': 'Local gated acceptance reply',
                    'template': '[[acceptance:stream:$ARGUMENTS]]', 'model': MODEL}},
        'compaction': {'auto': False, 'prune': False},
        'agent': {name: {'model': MODEL, **({'disable': True} if name == 'title' else {})}
                   for name in ('build', 'plan', 'general', 'explore', 'title', 'summary', 'compaction')},
        'permission': {'*': 'deny'},
        'provider': {'test': {
            'name': 'Local Scripted Acceptance',
            'id': 'test', 'npm': '@ai-sdk/openai-compatible',
            'options': {'baseURL': PROVIDER + '/v1'},
            'models': {'test-model': {
                'id': 'test-model', 'name': 'Scripted Test Model', 'attachment': True,
                'reasoning': True, 'temperature': False, 'tool_call': False,
                'release_date': '2026-01-01',
                'modalities': {'input': ['text', 'image'], 'output': ['text']},
                'limit': {'context': 32768, 'output': 4096},
                'cost': {'input': 0, 'output': 0}}}}}
    }


def media_summary(value):
    """Retain only media fingerprints, never request text, URLs, or base64."""
    result = []
    def walk(item):
        if isinstance(item, dict):
            for child in item.values():
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)
        elif isinstance(item, str) and item.startswith('data:'):
            header, encoded = item.split(',', 1)
            require(';base64' in header, 'Expected base64 media')
            raw = base64.b64decode(encoded, validate=True)
            result.append({'mime': header[5:].split(';')[0], 'bytes': len(raw),
                           'sha256': hashlib.sha256(raw).hexdigest()})
    walk(value)
    return result


class State:
    def __init__(self, manifest):
        self.manifest = manifest
        self.condition = threading.Condition()
        self.events = []
        self.runs = {}
        self.stop = threading.Event()

    def event(self, kind, marker='', **fields):
        with self.condition:
            item = {'seq': len(self.events) + 1, 'kind': kind, 'marker': marker, **fields}
            self.events.append(item)
            with (Path(self.manifest['root']) / 'provider-events.jsonl').open('a') as output:
                output.write(json.dumps(item) + '\n')
            self.condition.notify_all()
            return item


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0 closes streaming responses; SSE payloads still use real OpenAI chunks.
    def log_message(self, *args):
        pass

    @property
    def state(self):
        return self.server.state

    def authorized(self):
        expected = 'Bearer ' + self.state.manifest['control_token']
        if not secrets.compare_digest(self.headers.get('Authorization', ''), expected):
            self.reply({'error': 'unauthorized'}, 401)
            return False
        return True

    def reply(self, value, code=200):
        raw = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith('/fixtures/'):
            route = fixture_route(self.path)
            if not route:
                self.reply({'error': 'unknown fixture'}, 404)
                return
            marker, asset = route
            raw = COLOR_PNG if asset == 'color.png' else safari_page(marker)
            self.send_response(200)
            self.send_header('Content-Type', 'image/png' if asset == 'color.png' else 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'")
            if asset == 'color.png':
                self.send_header('Content-Disposition', 'inline; filename="acceptance-color.png"')
            self.end_headers()
            self.wfile.write(raw)
            return
        if not self.authorized():
            return
        if self.path == '/control/status':
            with self.state.condition:
                self.reply({'run_id': self.state.manifest['run_id'], 'pid': os.getpid(),
                            'events': list(self.state.events), 'request_count': len(self.state.runs)})
        else:
            self.reply({'error': 'unknown route'}, 404)

    def do_POST(self):
        if not self.authorized():
            return
        try:
            raw = bytearray()
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                while True:
                    size = int(self.rfile.readline(128).split(b';')[0].strip(), 16)
                    require(0 <= size and len(raw) + size <= 16 * 1024 * 1024, 'Request too large')
                    if size == 0:
                        require(self.rfile.readline(8192) == b'\r\n', 'Trailers unsupported')
                        break
                    raw.extend(self.rfile.read(size))
                    require(self.rfile.read(2) == b'\r\n', 'Invalid chunk boundary')
            else:
                size = int(self.headers.get('Content-Length', '0'))
                require(0 <= size <= 16 * 1024 * 1024, 'Request too large')
                raw.extend(self.rfile.read(size))
            body = json.loads(raw or b'{}')
            if self.path == '/v1/chat/completions':
                self.completion(body)
            elif self.path == '/control/wait':
                with self.state.condition:
                    def matches():
                        return [e for e in self.state.events if e['seq'] > body.get('after', 0)
                                and (not body.get('marker') or e['marker'] == body['marker'])
                                and (not body.get('kind') or e['kind'] == body['kind'])]
                    found = self.state.condition.wait_for(matches, timeout=min(body.get('timeout', 20), 60))
                    self.reply({'events': found or []})
            elif self.path in ('/control/advance', '/control/finish'):
                with self.state.condition:
                    run = self.state.runs[body['marker']]
                    require(not run['closed'] and not run['finished'], 'Stream already ended')
                    run['stage'] = max(run['stage'], 2 if self.path.endswith('finish') else 1)
                    self.state.condition.notify_all()
                    self.reply({'accepted': True})
            elif self.path == '/control/stop':
                self.reply({'accepted': True})
                self.state.stop.set()
            else:
                self.reply({'error': 'unknown route'}, 404)
        except (ValueError, KeyError, RuntimeError):
            if self.path == '/v1/chat/completions':
                self.state.event('rejected', reason='invalid_request')
            self.reply({'error': 'invalid fixture request'}, 422)

    def completion(self, body):
        require(body.get('model') == 'test-model' and body.get('stream') is True,
                'Only the scripted streaming model is supported')
        session_id = self.headers.get('X-Session-Id', '')
        marker = scenario_for_messages(body.get('messages', []), session_id)
        if not marker:
            self.state.event('rejected', reason='missing_marker')
            self.reply({'error': {'message': 'Missing acceptance marker', 'type': 'invalid_request_error'}}, 400)
            return
        scenario, suffix = OUTPUT_MARKER.fullmatch(marker).groups()
        expected = expected_output(marker)
        with self.state.condition:
            require(marker not in self.state.runs, 'Use a unique marker for every prompt')
            run = {'stage': 0, 'closed': False, 'finished': False}
            self.state.runs[marker] = run
        media = media_summary(body)
        self.state.event('request', marker, scenario=scenario, model=body['model'],
                         media=media, media_count=len(media), message_count=len(body['messages']),
                         session_id=session_id, expected=expected)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()

        def disconnected():
            # Blocking readiness detects real transport cancellation while no chunks are being sent.
            closed = False
            try:
                readable, _, _ = select.select([self.connection], [], [], 120)
                closed = bool(readable) and not self.connection.recv(1, socket.MSG_PEEK)
            except ConnectionResetError:
                closed = True
            except OSError:
                return
            if closed:
                with self.state.condition:
                    if not run['finished'] and not run['closed']:
                        run['closed'] = True
                        self.state.event('disconnected', marker)

        threading.Thread(target=disconnected, daemon=True).start()

        def send(delta, finish=None):
            chunk = {'id': 'chatcmpl-' + suffix, 'object': 'chat.completion.chunk',
                     'created': 1, 'model': 'test-model',
                     'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
            self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
            self.wfile.flush()

        def gate(stage):
            with self.state.condition:
                self.state.event('held', marker, stage=stage)
                require(self.state.condition.wait_for(
                    lambda: run['stage'] >= stage or run['closed'] or self.state.stop.is_set(), 110),
                    'Stream hold deadline exceeded')
                return not run['closed'] and not self.state.stop.is_set()

        try:
            send({'role': 'assistant'})
            if scenario == 'reasoning':
                send({'reasoning_content': expected['reasoning']})
            send({'content': expected['chunks'][0]})
            self.state.event('chunk', marker, index=1)
            if not gate(1):
                return
            send({'content': expected['chunks'][1]})
            self.state.event('chunk', marker, index=2)
            if not gate(2):
                return
            send({'content': expected['chunks'][2]})
            send({}, 'stop')
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
            with self.state.condition:
                run['finished'] = True
                self.state.event('finished', marker)
        except (BrokenPipeError, ConnectionResetError):
            with self.state.condition:
                if not run['closed']:
                    run['closed'] = True
                    self.state.event('disconnected', marker)
        except RuntimeError:
            self.state.event('hold_timeout', marker)
        finally:
            # Wake the disconnect observer before BaseHTTPRequestHandler releases the socket.
            with self.state.condition:
                run['closed'] = True
            try:
                self.connection.shutdown(socket.SHUT_RD)
            except OSError:
                pass


def environment(root, manifest):
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(root / 'home'),
           'OPENCODE_TEST_HOME': str(root / 'home'), 'TMPDIR': str(root / 'tmp'),
           'OPENCODE_CONFIG_DIR': str(root / 'config/opencode'),
            'OPENCODE_CONFIG_PROJECT_DISABLE': '1', 'OPENCODE_DISABLE_AUTOUPDATE': '1',
            'OPENCODE_DISABLE_MODELS_FETCH': '1', 'OPENCODE_MODELS_PATH': str(root / 'models.json'),
            'OPENCODE_DB': str(root / 'data/opencode.db'),
            'OPENCODE_SERVER_USERNAME': 'opencode', 'OPENCODE_SERVER_PASSWORD': manifest['password']}
    for name in ('config', 'data', 'cache', 'state'):
        env['XDG_' + name.upper() + '_HOME'] = str(root / name)
    env['XDG_RUNTIME_DIR'] = str(root / 'runtime')
    return env


def serve(path):
    manifest = load_manifest(path)
    verify_runtime()
    root = Path(manifest['root'])
    state = State(manifest)
    server = ThreadingHTTPServer(('127.0.0.1', 14098), Handler)
    server.daemon_threads = True
    server.state = state
    threading.Thread(target=server.serve_forever, daemon=True).start()
    child = None
    def stop(*_):
        state.stop.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        with (root / 'server.log').open('ab') as log:
            # The supervisor's kernel sandbox is inherited; macOS rejects nested sandbox_apply.
            child = subprocess.Popen([str(BINARY), 'serve', '--hostname', '127.0.0.1', '--port', '14097'],
                                     cwd=manifest['workspace'], env=environment(root, manifest),
                                     stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        manifest['server_pid'] = child.pid
        manifest['supervisor_pid'] = os.getpid()
        private_json(Path(path), manifest)
        # Readiness retries are bounded startup polling, never streaming test synchronization.
        deadline = time.monotonic() + 45
        last_error = None
        while time.monotonic() < deadline and child.poll() is None and not state.stop.is_set():
            try:
                verify(manifest)
                providers = request(manifest, '/api/provider', timeout=3)['data']
                models = request(manifest, '/api/model', timeout=3)['data']
                commands = request(manifest, '/api/command', timeout=3)['data']
                require([provider['id'] for provider in providers] == ['test'],
                        'Unexpected provider catalog')
                require([(model['providerID'], model['id']) for model in models] ==
                        [('test', 'test-model')], 'Unexpected model catalog')
                require(sum(command['name'] == 'acceptance' for command in commands) == 1,
                        'Configured acceptance command missing or duplicated')
                state.event('ready')
                break
            except (OSError, ValueError, RuntimeError) as error:
                last_error = error
                state.stop.wait(0.1)
        else:
            if last_error is not None:
                state.event('readiness_error', error_type=type(last_error).__name__,
                            status=getattr(last_error, 'code', None), reason=str(last_error))
            raise RuntimeError('Runtime readiness failed; inspect private server.log')
        while not state.stop.wait(0.25):
            require(child.poll() is None, 'Runtime exited unexpectedly')
    finally:
        with state.condition:
            state.stop.set()
            state.condition.notify_all()
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=15)
        state.event('stopped')
        server.shutdown()
        server.server_close()


def start():
    verify_host_root()
    verify_runtime()
    # Never contact, authenticate to, or kill a listener that already occupies either port.
    for port in (14097, 14098):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(('127.0.0.1', port))
    root = Path(tempfile.mkdtemp(prefix=ROOT_PREFIX, dir=TEMP))
    for name in ('workspace', 'git-fixture', 'copies', 'home', 'config/opencode', 'data', 'cache', 'state', 'runtime', 'tmp'):
        (root / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest = {'run_id': secrets.token_hex(16), 'version': VERSION, 'host_root': str(TEMP),
                'root': str(root),
                'workspace': str(root / 'workspace'), 'base_url': BASE, 'provider_url': PROVIDER,
                'git_root': str(root / 'git-fixture'),
                'worktree_destination_parent': str(root / 'copies'),
                'model': MODEL, 'username': 'opencode', 'password': secrets.token_urlsafe(32),
                'output_schema_version': 2, 'acceptance_command': 'acceptance',
                'control_token': secrets.token_urlsafe(32), 'server_pid': None, 'supervisor_pid': None,
                'binary': str(BINARY), 'binary_sha256': BINARY_SHA256,
                'source': SOURCE_URL, 'network_policy': PROFILE}
    (root / '.acceptance-root').write_text(manifest['run_id'] + '\n')
    (root / 'git-fixture/README.md').write_text('# Disposable acceptance repository\n')
    git_env = {'PATH': '/usr/bin:/bin', 'HOME': str(root / 'home')}
    for command in (['git', 'init', '--quiet'],
                    ['git', 'config', 'user.name', 'OpenClient Acceptance'],
                    ['git', 'config', 'user.email', 'acceptance@invalid.example'],
                    ['git', 'add', 'README.md'],
                    ['git', 'commit', '--quiet', '-m', 'Initial acceptance fixture']):
        subprocess.run(command, cwd=root / 'git-fixture', env=git_env, check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    private_json(root / 'models.json', {})
    config = configuration()
    config['provider']['test']['options']['apiKey'] = manifest['control_token']
    private_json(root / 'config/opencode/opencode.json', config)
    path = root / 'manifest.json'
    private_json(path, manifest)
    with (root / 'supervisor.log').open('ab') as log:
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', PROFILE,
                                    sys.executable, str(Path(__file__).resolve()), '_serve', str(path)],
                                    env={'PATH': '/usr/bin:/bin', 'HOME': str(root / 'home'),
                                         HOST_ROOT_ENV: str(TEMP),
                                         RUNTIME_ROOT_ENV: str(RUNTIME_ROOT),
                                         'PYTHONDONTWRITEBYTECODE': '1'},
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print(str(path), flush=True)
    deadline = time.monotonic() + 50
    pause = threading.Event()
    while time.monotonic() < deadline and process.poll() is None:
        try:
            result = request(manifest, '/control/wait', {'kind': 'ready', 'timeout': 1}, provider=True, timeout=2)
            if result['events']:
                verify(load_manifest(path))
                return
        except (OSError, ValueError):
            pause.wait(0.1)
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=20)
    raise RuntimeError('Startup failed; private logs are beside the printed manifest')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'status', 'stop', '_serve', 'wait', 'advance', 'finish'])
    parser.add_argument('manifest', nargs='?')
    parser.add_argument('--marker')
    parser.add_argument('--kind', default='chunk')
    parser.add_argument('--after', type=int, default=0)
    args = parser.parse_args()
    if args.action == 'start':
        start()
        return
    require(args.manifest, 'Manifest required')
    if args.action == '_serve':
        serve(args.manifest)
        return
    manifest = load_manifest(args.manifest)
    identity = verify(manifest)
    if args.action == 'status':
        print(json.dumps(identity))
    else:
        result = request(manifest, '/control/' + args.action,
                         {'marker': args.marker, 'kind': args.kind, 'after': args.after}, provider=True)
        if args.action == 'stop':
            deadline = time.monotonic() + 20
            pause = threading.Event()
            while time.monotonic() < deadline:
                listening = False
                for port in (14097, 14098):
                    with socket.socket() as probe:
                        listening = probe.connect_ex(('127.0.0.1', port)) == 0 or listening
                if not listening:
                    print('Owned runtime and provider stopped')
                    return
                pause.wait(0.1)
            raise RuntimeError('Shutdown timed out; no force kill attempted')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
