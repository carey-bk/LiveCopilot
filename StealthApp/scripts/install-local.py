#!/usr/bin/env python3
"""Install a signed app at one canonical location; archive old bundles, repair stale TCC.
Never reads credentials, changes signing trust, or grants macOS permissions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone

BUNDLE_ID = 'com.livecopilot.app'
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def identity(path):
    with (path / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError(f'Unexpected bundle identity: {path}')
    return info


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def archive(app, directory):
    """Verify archived bytes and symlinks against source before removing any bundle."""
    identity(app)
    destination = directory / (app.name + '-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.tar.gz')
    partial = destination.with_suffix('.partial')
    with tarfile.open(partial, 'w:gz', compresslevel=1) as tar:
        tar.add(app, arcname=app.name, recursive=True)
    with tarfile.open(partial, 'r:gz') as tar:
        for member in tar.getmembers():
            relative = Path(member.name).relative_to(app.name)
            original = app / relative
            if member.isfile():
                with tar.extractfile(member) as data:
                    h = hashlib.sha256()
                    while chunk := data.read(1024 * 1024):
                        h.update(chunk)
                if h.hexdigest() != digest(original):
                    raise ValueError('Backup verification failed')
            elif member.issym() and os.readlink(original) != member.linkname:
                raise ValueError('Backup symlink verification failed')
    partial.rename(destination)
    return destination


def requirement(app):
    result = run('/usr/bin/codesign', '-d', '-r-', str(app))
    return next(line.split('designated =>', 1)[1].strip() for line in (result.stdout + result.stderr).splitlines() if 'designated =>' in line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, help='Already signed, validated application bundle')
    parser.add_argument('--repair-permissions', action='store_true', help='Rebuild this app’s ScreenCapture grant even if the signature matches')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    source = args.app.expanduser().resolve()
    target = Path.home() / 'Applications/LiveCopilot.app'
    backup_root = Path.home() / 'Library/Application Support/LiveCopilot/Backups/Applications'
    info = identity(source)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(source))
    if source == target.resolve():
        raise ValueError('Use a separate validated build as the source')
    previous = requirement(target) if target.exists() else None
    current = requirement(source)
    # Same ad-hoc signature -> no reset. A stable certificate requirement also
    # survives normal upgrades. Never replace it with a weak bundle-ID-only rule.
    reset = bool(previous and previous != current) or args.repair_permissions
    old_apps = sorted(target.parent.glob('LiveCopilot.app.previous.*'))
    for app in old_apps:
        if app.is_symlink() or not app.is_dir():
            raise ValueError('Unexpected backup type; refusing cleanup')
        identity(app)
    plan = {'target': str(target), 'version': info.get('CFBundleShortVersionString'),
            'build': info.get('CFBundleVersion'), 'legacy_backups': len(old_apps),
            'screen_permission_reset': reset, 'backup_directory': str(backup_root)}
    print(json.dumps(plan, ensure_ascii=False), flush=True)
    if args.dry_run:
        return
    processes = run('/bin/ps', '-axo', 'command=').stdout.splitlines()
    if any(line.startswith(str(target / 'Contents/MacOS/LiveCopilot')) for line in processes):
        raise RuntimeError('Quit LiveCopilot before installing; its session must finish saving')
    target.parent.mkdir(parents=True, exist_ok=True)
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    archives = []
    # Stage outside Applications so discovery cannot prefer an unfinished app.
    with tempfile.TemporaryDirectory(prefix='livecopilot-install-') as work:
        staged = Path(work) / 'LiveCopilot.app'
        shutil.copytree(source, staged, symlinks=True)
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged))
        if requirement(staged) != current:
            raise ValueError('Staging changed signature')
        for old in old_apps:
            archives.append(str(archive(old, backup_root)))
            run(LSREGISTER, '-u', str(old), check=False)
            shutil.rmtree(old)
        rollback = Path(work) / 'rollback'
        if target.exists():
            archives.append(str(archive(target, backup_root)))
            run(LSREGISTER, '-u', str(target), check=False)
            shutil.move(str(target), rollback)
        try:
            shutil.move(str(staged), target)
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(target))
        except Exception:
            if target.exists():
                shutil.rmtree(target)
            if rollback.exists():
                shutil.move(str(rollback), target)
                run(LSREGISTER, '-f', str(target), check=False)
            raise
        run(LSREGISTER, '-u', str(source), check=False)
        run(LSREGISTER, '-f', str(target))
        if reset:
            # Only this application's screen/system-audio grant. macOS owns the
            # final Allow action; never touch its database or reset other apps.
            run('/usr/bin/tccutil', 'reset', 'ScreenCapture', BUNDLE_ID)
        receipt = dict(plan, archives=archives, executable_sha256=digest(target / 'Contents/MacOS/LiveCopilot'))
        (backup_root / 'latest-install.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Installed and verified. ' + ('Allow the current app in Privacy Settings once, then reopen.' if reset else 'Existing screen permission retained.'))

if __name__ == '__main__':
    main()
