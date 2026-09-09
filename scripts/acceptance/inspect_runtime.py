"""Read installed source maps, without copying/vendorizing the runtime."""
import argparse
import json
from pathlib import Path

BINARY = Path('/Users/mininic/Library/Application Support/OpenCode-v2/runtime/0.0.0-next-17155/bin/opencode2')

def sources():
    for path in BINARY.parent.glob('*.map'):
        data = json.loads(path.read_text())
        for name, text in zip(data.get('sources', []), data.get('sourcesContent', [])):
            if text:
                yield name, text

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('match', help='Substring of source path')
    parser.add_argument('--contains', default='')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--lines', help='Print matching lines with five lines of context')
    args = parser.parse_args()
    seen = set()
    for name, text in sources():
        if name in seen or args.match not in name or args.contains not in text:
            continue
        seen.add(name)
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
