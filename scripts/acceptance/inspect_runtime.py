"""Inspect the isolated pinned v2 runtime and any source maps shipped with it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

VERSION = '2.0.16'
SOURCE_URL = 'https://github.com/anomalyco/opencode/tree/v2'
CLI_INTEGRITY = 'sha512-x8FzHgXduEoFWQsuTZ5K/uyOCCwqa6jDVQt6P0lQkhsYCCQpiwUisjnmdzZlmaJuHwEVUmE4tH9YyW472gTDzQ=='
PLATFORM_INTEGRITY = 'sha512-WlzjaxNb/QY/nJk93AbFNmlxpb5YDdy/2/6FPLbd10QbrkYtfz1TmI6Y0sM3BASDOLG/yJ+0oBfj9OZ5fZ5rfA=='
BINARY_SHA256 = '27aff98364f326b929a86ebd013c44c9b2ea60bd90e1c2f219e236cd0932e70f'
RUNTIME_ROOT_ENV = 'OPENCODE_V2_RUNTIME_ROOT'
RUNTIME_ROOT = Path(os.environ.get(
    RUNTIME_ROOT_ENV,
    str(Path.home() / 'Library/Application Support/OpenCode-v2/runtime' / VERSION),
)).absolute()
BINARY = RUNTIME_ROOT / 'node_modules/@opencode/cli/bin/opencode.exe'
PLATFORM_BINARY = RUNTIME_ROOT / 'node_modules/@opencode/cli-darwin-arm64/bin/opencode'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def verify_runtime():
    require(RUNTIME_ROOT.is_dir() and not RUNTIME_ROOT.is_symlink(), 'Pinned runtime directory is missing or linked')
    require(RUNTIME_ROOT.stat().st_uid == os.getuid(), 'Pinned runtime is not owned by the current user')
    lock = json.loads((RUNTIME_ROOT / 'package-lock.json').read_text())
    root_package = json.loads((RUNTIME_ROOT / 'package.json').read_text())
    packages = lock.get('packages', {})
    cli = packages.get('node_modules/@opencode/cli', {})
    platform = packages.get('node_modules/@opencode/cli-darwin-arm64', {})
    require(root_package == {'dependencies': {'@opencode/cli': VERSION}}, 'Runtime dependency is not exactly pinned')
    require(cli.get('version') == VERSION and cli.get('integrity') == CLI_INTEGRITY,
            'CLI package version or integrity differs from the pinned release')
    require(platform.get('version') == VERSION and platform.get('integrity') == PLATFORM_INTEGRITY,
            'Platform package version or integrity differs from the pinned release')
    for binary in (BINARY, PLATFORM_BINARY):
        require(binary.is_file() and not binary.is_symlink(), 'Pinned runtime executable is missing or linked')
        require(binary.stat().st_uid == os.getuid(), 'Pinned runtime executable has the wrong owner')
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == BINARY_SHA256,
                'Pinned runtime executable digest mismatch')
    reported = subprocess.check_output([str(BINARY), '--version'], text=True, timeout=10).strip()
    require(reported == 'opencode v' + VERSION, 'Pinned runtime reported an unexpected version')
    return {'version': VERSION, 'runtime_root': str(RUNTIME_ROOT), 'sha256': BINARY_SHA256}

def sources():
    for path in BINARY.parent.glob('*.map'):
        data = json.loads(path.read_text())
        for name, text in zip(data.get('sources', []), data.get('sourcesContent', [])):
            if text:
                yield name, text

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('match', nargs='?', help='Substring of source path')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--contains', default='')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--lines', help='Print matching lines with five lines of context')
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(verify_runtime(), sort_keys=True))
        raise SystemExit(0)
    if not args.match:
        parser.error('match is required unless --verify is used')
    found = False
    seen = set()
    for name, text in sources():
        if name in seen or args.match not in name or args.contains not in text:
            continue
        seen.add(name)
        found = True
        print(name)
        if args.full:
            print(text)
        elif args.lines:
            lines = text.splitlines()
            indexes = set()
            for i, line in enumerate(lines):
                if args.lines in line:
                    indexes.update(range(max(0, i - 5), min(len(lines), i + 6)))
            for i in sorted(indexes):
                print(f'{i + 1}: {lines[i]}')
    if not found:
        raise SystemExit(f'No matching shipped source map; use official source: {SOURCE_URL}')
