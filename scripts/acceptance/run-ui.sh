#!/bin/bash
set -euo pipefail
# No tracing: the private manifest and generated credentials must never be logged.
unset DEVELOPER_DIR
xcodes installed
xcodes select --print-path
xcodebuild -version
python3 -B - "$@" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

repo = Path.cwd()
sys.path.insert(0, str(repo / 'scripts/acceptance'))
from fixture import load_manifest, verify, private_json
from scenarios import COLOR_PNG

assert (repo / 'OpenCodeIOSClient.xcodeproj').is_dir(), 'Run from repository root'
assert subprocess.check_output(['xcode-select', '-p'], text=True).strip() == '/Applications/Xcode.app/Contents/Developer'
assert 'Xcode 26.3\n' in subprocess.check_output(['xcodebuild', '-version'], text=True)
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
runtime = next(r for r in runtimes if r['version'] == '26.3.1' and r['buildversion'] == '23D8133' and r['isAvailable'])
subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available'], check=True)
deadline = time.monotonic() + 180
while True:
    probes = []
    try:
        for port in (14097, 14098):
            probe = socket.socket()
            probes.append(probe)
            probe.bind(('127.0.0.1', port))
        break
    except OSError:
        if time.monotonic() >= deadline:
            raise RuntimeError('Acceptance ports still owned by another run; no listener was stopped or reused')
        time.sleep(2)
    finally:
        for probe in probes:
            probe.close()
manifest_path = subprocess.check_output([sys.executable, '-B', 'scripts/acceptance/fixture.py', 'start'], text=True).strip()
manifest = load_manifest(manifest_path)
root = Path(manifest['root'])
devices = []
exit_code = 1
try:
    verify(manifest)
    subprocess.run([sys.executable, '-B', 'scripts/acceptance/network_probe.py', manifest_path], check=True)
    png = root / 'ui-photo.png'
    png.write_bytes(COLOR_PNG)
    for name, model in [('iPhone17ProMax', 'iPhone-17-Pro-Max'), ('iPadPro13M5', 'iPad-Pro-13-inch-M5-12GB')]:
        device = subprocess.check_output(['xcrun', 'simctl', 'create', 'OpenClientAcceptance-' + name + '-' + manifest['run_id'][:8],
                                         'com.apple.CoreSimulator.SimDeviceType.' + model, runtime['identifier']], text=True).strip()
        devices.append(device)
        private_json(root / 'ui-owned-simulators.json', {'run_id': manifest['run_id'], 'devices': devices})
        subprocess.run(['xcrun', 'simctl', 'boot', device], check=True, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', device, '-b'], check=True, timeout=600)
        subprocess.run(['xcrun', 'simctl', 'addmedia', device, str(png)], check=True, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=True, timeout=120)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('OPENCODE_UI_TEST_', 'TEST_RUNNER_OPENCODE_', 'OPENCLIENT_SCREENSHOT'))}
    env['TEST_RUNNER_OPENCLIENT_ACCEPTANCE_MANIFEST_PATH'] = manifest_path
    command = ['xcodebuild', '-quiet', '-project', 'OpenCodeIOSClient.xcodeproj', '-scheme', 'OpenCodeIOSClient']
    for device in devices:
        command += ['-destination', 'platform=iOS Simulator,id=' + device]
    command += ['-disable-concurrent-destination-testing', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '900',
                '-only-testing:OpenCodeIOSClientUITests/AcceptanceUITests', '-resultBundlePath', str(root / 'acceptance-ui.xcresult'), 'test']
    print('Acceptance UI artifacts: ' + str(root), flush=True)
    with (root / 'acceptance-ui.log').open('w') as log:
        exit_code = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    result = root / 'acceptance-ui.xcresult'
    if result.exists():
        subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], check=False)
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(root / 'acceptance-ui-attachments')], check=False)
finally:
    # Only IDs returned by this invocation's create calls are eligible for cleanup.
    for device in devices:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False)
        subprocess.run(['xcrun', 'simctl', 'delete', device], check=False)
    subprocess.run([sys.executable, '-B', 'scripts/acceptance/fixture.py', 'stop', manifest_path], check=True)
sys.exit(exit_code)
PY
