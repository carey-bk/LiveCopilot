#!/usr/bin/env python3
"""Make the Hong Kong mirror feed from the signed GitHub feed.

The mirror carries the same items and signatures; only the download URLs of the given versions
move from the GitHub Release to the versioned OSS folder. The whole feed is then re-signed with the
Keychain key (item signatures cover archive bytes, not URLs, so they stay valid) and verified.

Usage: mirror-feed.py GITHUB_APPCAST.xml MIRROR_APPCAST.xml --version 2.12 [--version ...]
Upload MIRROR_APPCAST.xml to OSS updates/appcast.xml only after the DMG and deltas are on OSS.
"""
import argparse, subprocess, sys
from pathlib import Path

GITHUB = "https://github.com/carey-bk/LiveCopilot/releases/download/v{}/"
OSS = "https://livecopilot-downloads-hk.oss-cn-hongkong.aliyuncs.com/releases/v{}/"
SIGN = Path(__file__).resolve().parents[1] / "build/SparkleTools/bin/sign_update"

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("target", type=Path)
parser.add_argument("--version", action="append", required=True)
args = parser.parse_args()

text = args.source.read_text(encoding="utf-8")
for version in args.version:
    count = text.count(GITHUB.format(version))
    if count == 0:
        sys.exit(f"No GitHub download URLs for v{version} in {args.source}")
    text = text.replace(GITHUB.format(version), OSS.format(version))
    print(f"v{version}: {count} URLs moved to OSS")
if args.target.resolve() == args.source.resolve():
    sys.exit("Write the mirror feed to a different file; the GitHub feed stays as signed.")
args.target.write_text(text, encoding="utf-8")
subprocess.run([str(SIGN), "--account", "LiveCopilot", str(args.target)], check=True, stdout=subprocess.DEVNULL)
subprocess.run([str(SIGN), "--account", "LiveCopilot", "--verify", str(args.target)], check=True)
print(f"Mirror feed signed and verified: {args.target}")
