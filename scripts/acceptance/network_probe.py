"""Verify the exact runtime sandbox, with no external packets or provider requests."""
import argparse
import errno
import json
import socket
import subprocess
import sys
from pathlib import Path

from fixture import PROFILE, load_manifest, private_json, require, verify


def child():
    with socket.create_connection(('127.0.0.1', 14098), timeout=2):
        pass
    # TEST-NET-1 is not a provider. EPERM proves the kernel rejected connect,
    # rather than relying on a timeout, DNS failure, proxy, or unreachable host.
    with socket.socket() as probe:
        try:
            probe.connect(('192.0.2.1', 443))
        except OSError as error:
            require(error.errno == errno.EPERM, 'Sandbox did not explicitly deny external connect')
        else:
            raise RuntimeError('Sandbox permitted external connect')
    print(json.dumps({'loopback_provider_allowed': True, 'external_connect_denied_EPERM': True}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', nargs='?')
    parser.add_argument('--child', action='store_true')
    args = parser.parse_args()
    if args.child:
        child()
    else:
        manifest = load_manifest(args.manifest)
        verify(manifest)
        require(manifest['network_policy'] == PROFILE, 'Runtime sandbox policy differs from probe')
        result = subprocess.run(['/usr/bin/sandbox-exec', '-p', PROFILE, sys.executable,
                                 '-B', str(Path(__file__).resolve()), '--child'], check=True,
                                env={'PATH': '/usr/bin:/bin', 'HOME': str(Path(manifest['root']) / 'home')},
                                timeout=10, capture_output=True, text=True)
        evidence = json.loads(result.stdout)
        private_json(Path(manifest['root']) / 'network-evidence.json', evidence)
        print(json.dumps(evidence))
