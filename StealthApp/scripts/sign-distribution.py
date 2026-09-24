#!/usr/bin/env python3
"""Sign one staging copy with Developer ID, or verify every shipped Mach-O.

Never exports keys, changes their ACLs, or installs the application.
"""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def metadata(path, arch):
    result = run('/usr/bin/codesign', '-dv', '--verbose=4', '--arch', arch, str(path))
    return result.stdout + result.stderr


def verify(app, require_universal=True):
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    main = metadata(app, 'arm64')
    team = next(line.removeprefix('TeamIdentifier=') for line in main.splitlines() if line.startswith('TeamIdentifier='))
    assert team and team != 'not set', 'Missing signing team'
    binaries = []
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        if 'Mach-O' not in run('/usr/bin/file', '-b', str(path)).stdout:
            continue
        binaries.append(path)
        arches = run('/usr/bin/lipo', '-archs', str(path)).stdout.split()
        if require_universal:
            assert set(arches) == {'arm64', 'x86_64'}, f'Not universal: {path}'
        else:
            assert 'arm64' in arches, f'Missing Apple Silicon slice: {path}'
        run('/usr/bin/codesign', '--verify', '--strict', str(path))
        for arch in arches:
            info = metadata(path, arch)
            assert 'Authority=Developer ID Application:' in info, f'Not Developer ID signed: {path}'
            assert f'TeamIdentifier={team}\n' in info, f'Signing team mismatch: {path}'
            assert '(runtime)' in info and 'Timestamp=' in info, f'Missing runtime/timestamp: {path}'
            result = run('/usr/bin/codesign', '-d', '--entitlements', ':-', '--arch', arch, str(path))
            if result.stdout.strip():
                entitlements = plistlib.loads(result.stdout.encode())
                for key in ('com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation',
                            'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.cs.allow-jit'):
                    assert not entitlements.get(key, False), f'Unexpected exception {key}: {path}'
    assert len(binaries) == 5, f'Review changed embedded executable inventory ({len(binaries)})'
    print(f'Verified {len(binaries)} binaries: Developer ID, team {team}, secure timestamps, hardened runtime.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--identity', help='Developer ID Application certificate name or SHA-1')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--verify-dev-only', action='store_true', help='Verify a development bundle, including every embedded Mach-O')
    args = parser.parse_args()
    source = args.app.resolve()
    if args.verify_dev_only:
        if args.verify_only or args.output or args.identity:
            parser.error('--verify-dev-only does not take signing or release verification options')
        info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'com.livecopilot.development', 'Expected Development bundle ID'
        verify(source, require_universal=False)
        return
    if args.verify_only:
        if args.output or args.identity:
            parser.error('--verify-only does not take output or identity')
        verify(source)
        return
    if not args.output or not args.identity or args.identity == '-':
        parser.error('Supply a new --output path and a Developer ID --identity')
    target = args.output.resolve()
    if target.exists() or target.suffix != '.app' or source in target.parents:
        parser.error('Output must be a new .app outside the source bundle')
    if Path('/Applications') in target.parents or Path.home() / 'Applications' in target.parents:
        parser.error('Sign in a staging directory; use install-local.py after validation')
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.livecopilot.app', 'Expected Release bundle ID'
    target.parent.mkdir(parents=True, exist_ok=True)
    run('/usr/bin/ditto', '--noextattr', '--norsrc', str(source), str(target))
    info['CFBundleVersion'] = datetime.now(timezone.utc).strftime('%Y%m%d.%H%M%S')
    (target / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    runtime = target / 'Contents/Resources/LocalRuntime'
    flags = ('--force', '--sign', args.identity, '--options', 'runtime', '--timestamp')
    # Sign from the inside out. Never use --deep to sign or disable library validation.
    for name in ('libonnxruntime.dylib', 'libsherpa-onnx-c-api.dylib', 'llama.framework', 'livecopilot-inference'):
        print(f'Signing {name}', flush=True)
        run('/usr/bin/codesign', *flags, str(runtime / name))
    entitlements = Path(__file__).resolve().parents[1] / 'Resources/LiveCopilot.entitlements'
    run('/usr/bin/codesign', *flags, '--entitlements', str(entitlements), str(target))
    verify(target)
    print(f'Signed staging app: {target}')


if __name__ == '__main__':
    main()
