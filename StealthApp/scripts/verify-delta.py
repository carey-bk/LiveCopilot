#!/usr/bin/env python3
"""Check a Sparkle binary delta before publishing it.

Mounts the previous and new release DMGs read-only, applies the delta to a copy of the
previous app with Sparkle's BinaryDelta, and requires the result to match the new app
exactly (file contents, permissions and symlinks, without following links), with a valid
Developer ID signature, stapled notarization ticket and Gatekeeper acceptance.

Usage: verify-delta.py OLD.dmg NEW.dmg UPDATE.delta
Nothing is signed, uploaded or installed.
"""
import hashlib, os, stat, subprocess, sys, tempfile
from pathlib import Path

BINARY_DELTA = Path(__file__).resolve().parents[1] / "build/SparkleTools/bin/BinaryDelta"


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def manifest(root):
    entries = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = os.path.join(directory, name)
            info = os.lstat(path)
            key = os.path.relpath(path, root)
            if stat.S_ISLNK(info.st_mode):
                entries[key] = ("link", os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entries[key] = ("dir", info.st_mode & 0o7777)
            else:
                digest = hashlib.sha256()
                with open(path, "rb") as stream:
                    for block in iter(lambda: stream.read(1 << 20), b""):
                        digest.update(block)
                entries[key] = ("file", digest.hexdigest(), info.st_mode & 0o7777)
    return entries


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip().splitlines()[-2])
    old_dmg, new_dmg, delta = (Path(arg).resolve() for arg in sys.argv[1:])
    if not BINARY_DELTA.is_file():
        sys.exit("BinaryDelta not found; run scripts/prepare-sparkle.sh first.")
    with tempfile.TemporaryDirectory(prefix="livecopilot-delta-") as work:
        work = Path(work)
        mounts = []
        try:
            for name, dmg in (("old", old_dmg), ("new", new_dmg)):
                mount = work / f"mount-{name}"
                mount.mkdir()
                run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg))
                mounts.append(mount)
            old_app = work / "old.app"
            patched = work / "patched.app"
            run("ditto", str(mounts[0] / "LiveCopilot.app"), str(old_app))
            run(str(BINARY_DELTA), "apply", str(old_app), str(patched), str(delta))
            expected = manifest(mounts[1] / "LiveCopilot.app")
            actual = manifest(patched)
            different = sorted(key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
            if different:
                sys.exit(f"Patched app differs from the new release in {len(different)} entries, e.g. {different[:5]}")
            run("codesign", "--verify", "--deep", "--strict", str(patched))
            run("xcrun", "stapler", "validate", str(patched))
            run("spctl", "--assess", "--type", "execute", str(patched))
        finally:
            for mount in mounts:
                subprocess.run(["hdiutil", "detach", str(mount)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"Delta verified: {delta.name} ({delta.stat().st_size / 1_000_000:.1f} MB) turns "
          f"{old_dmg.name} into an exact, signed, notarized copy of {new_dmg.name}.")


if __name__ == "__main__":
    main()
