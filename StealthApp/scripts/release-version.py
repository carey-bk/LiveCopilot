#!/usr/bin/env python3
"""Read the single public version source and validate release inputs. Never publishes."""
import argparse
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def release_version(root=ROOT):
    text = (root / 'Version.xcconfig').read_text()
    values = re.findall(r'^MARKETING_VERSION\s*=\s*(.*?)\s*$', text, re.M)
    if len(values) != 1 or not re.fullmatch(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', values[0]):
        raise ValueError('Version.xcconfig requires one stable MAJOR.MINOR, e.g. 2.11')
    return values[0]

def validate_app(app, version):
    info = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != version:
        raise ValueError('Application marketing version differs from Version.xcconfig; rebuild before packaging')
    if not info.get('CFBundleVersion'):
        raise ValueError('Missing internal build number')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tag', action='store_true', help='Print the canonical GitHub release tag')
    p.add_argument('--check-tag')
    p.add_argument('--check-app', type=Path)
    p.add_argument('--check-dmg', type=Path)
    a = p.parse_args()
    version = release_version()
    if a.check_tag and a.check_tag != 'v' + version:
        p.error('Release tag must be v' + version)
    if a.check_app:
        validate_app(a.check_app, version)
    if a.check_dmg and a.check_dmg.name != f'LiveCopilot-{version}-macOS-universal.dmg':
        p.error('Disk image filename differs from Version.xcconfig')
    print(('v' if a.tag else '') + version)

if __name__ == '__main__':
    main()
