#!/bin/bash
set -euo pipefail
# No tracing: the private manifest and generated credentials must never be logged.
unset DEVELOPER_DIR
# Xcode must already be selected according to .opencode/skills/simulator-device-policy.
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
from fixture import TEMP, load_manifest, verify, private_json
from scenarios import COLOR_PNG

assert (repo / 'OpenCodeIOSClient.xcodeproj').is_dir(), 'Run from repository root'
developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
assert developer.startswith('/Applications/Xcode') and developer.endswith('.app/Contents/Developer'), 'Select stable Xcode with xcodes first'
inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j']))
sdk_version = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
requested_runtime = os.environ.get('OPENCLIENT_ACCEPTANCE_IOS_RUNTIME', sdk_version)
assert requested_runtime == sdk_version, 'Acceptance runtime must match the selected stable Xcode simulator SDK'
runtime = next((r for r in inventory['runtimes']
                if r['isAvailable'] and r['platform'] == 'iOS' and r['version'] == requested_runtime
                and all(word not in r['name'].lower() for word in ('beta', 'release candidate', ' rc'))), None)
assert runtime is not None, 'Selected stable Xcode simulator runtime is unavailable'
runtime_devices = inventory['devices'].get(runtime['identifier'], [])

def required_device(environment_key, expected_name):
    udid = os.environ.get(environment_key)
    assert udid, environment_key + ' is required; never substitute another simulator'
    device = next((item for item in runtime_devices if item['udid'] == udid), None)
    assert device is not None and device['isAvailable'], environment_key + ' is unavailable on the selected runtime'
    assert device['name'] == expected_name, environment_key + ' must identify ' + expected_name
    return device

iphone = required_device('OPENCLIENT_ACCEPTANCE_IPHONE_UDID', 'iPhone 18 Pro Max')
ipad = required_device('OPENCLIENT_ACCEPTANCE_IPAD_UDID', 'iPad Pro 13-inch (M5)')
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
devices = [iphone['udid'], ipad['udid']]
booted_by_runner = []
exit_code = 1
try:
    verify(manifest)
    subprocess.run([sys.executable, '-B', 'scripts/acceptance/network_probe.py', manifest_path], check=True)
    png = root / 'ui-photo.png'
    png.write_bytes(COLOR_PNG)
    private_json(root / 'ui-owned-simulators.json', {'run_id': manifest['run_id'], 'devices': devices})
    for device in (iphone, ipad):
        if device['state'] != 'Booted':
            subprocess.run(['xcrun', 'simctl', 'boot', device['udid']], check=True, timeout=120)
            booted_by_runner.append(device['udid'])
        subprocess.run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], check=True, timeout=600)
        subprocess.run(['xcrun', 'simctl', 'uninstall', device['udid'], 'com.ntoporcov.openclient'], check=False, timeout=120)
        subprocess.run(['xcrun', 'simctl', 'addmedia', device['udid'], str(png)], check=True, timeout=120)
    env = {k: v for k, v in os.environ.items() if not k.startswith(
        ('OPENCODE_UI_TEST_', 'TEST_RUNNER_OPENCODE_', 'TEST_RUNNER_OPENCLIENT_', 'OPENCLIENT_SCREENSHOT'))}
    env['TEST_RUNNER_OPENCLIENT_ACCEPTANCE_MANIFEST_PATH'] = manifest_path
    env['TEST_RUNNER_OPENCLIENT_ACCEPTANCE_HOST_ROOT'] = str(TEMP)
    env['TEST_RUNNER_OPENCODE_V2_TEST_MANIFEST_PATH'] = manifest_path
    env['TEST_RUNNER_OPENCODE_V2_TEST_HOST_ROOT'] = str(TEMP)
    command = ['xcodebuild', '-quiet', '-project', 'OpenCodeIOSClient.xcodeproj', '-scheme', 'OpenCodeIOSClient']
    for device in devices:
        command += ['-destination', 'platform=iOS Simulator,id=' + device]
    action = ('test-without-building'
              if os.environ.get('OPENCLIENT_ACCEPTANCE_TEST_WITHOUT_BUILDING') == '1' else 'test')
    command += ['-disable-concurrent-destination-testing', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
                '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '900',
                '-only-testing:OpenCodeIOSClientUITests/AcceptanceUITests', '-resultBundlePath', str(root / 'acceptance-ui.xcresult'), action]
    print('Acceptance UI artifacts: ' + str(root), flush=True)
    with (root / 'acceptance-ui.log').open('w') as log:
        exit_code = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
    result = root / 'acceptance-ui.xcresult'
    if result.exists():
        subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], check=False)
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(root / 'acceptance-ui-attachments')], check=False)
finally:
    # Preserve caller-owned devices; only restore devices this invocation booted.
    for device in booted_by_runner:
        subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=False)
    subprocess.run([sys.executable, '-B', 'scripts/acceptance/fixture.py', 'stop', manifest_path], check=True)
sys.exit(exit_code)
PY
