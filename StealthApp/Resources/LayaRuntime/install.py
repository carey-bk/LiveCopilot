#!/usr/bin/env python3
"""Explicit, isolated, hash-pinned installation. Never prints paths or exception details."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def emit(stage, progress):
    print(json.dumps({'stage': stage, 'progress': progress}), flush=True)


def download(item, cache):
    with (cache / (item['sha256'] + '.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return download_locked(item, cache)


def download_locked(item, cache):
    target = cache / item['sha256']
    if target.is_file() and digest(target) == item['sha256']:
        return target
    url = item['url']
    if not url.startswith('https://') or len(item['sha256']) != 64:
        raise ValueError('invalid_pin')
    temporary = cache / (uuid.uuid4().hex + '.part')
    try:
        # macOS system proxy settings are used when no environment override exists.
        env = dict(os.environ)
        for scheme, proxy in urllib.request.getproxies().items():
            if scheme in ('http', 'https'):
                env.setdefault(scheme.upper() + '_PROXY', proxy)
        if item.get('size', 0) > 16 * 1024 * 1024:
            download_ranges(item, temporary, env)
        else:
            subprocess.run(['/usr/bin/curl', '--fail', '--location', '--http1.1', '--retry-all-errors', '--silent', '--show-error',
                        '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
                        '--connect-timeout', '30', '--speed-time', '30', '--speed-limit', '1024', '--max-time', '1800', url,
                        '--output', str(temporary)], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if digest(temporary) != item['sha256']:
            shutil.rmtree(cache / (item['sha256'] + '.chunks'), ignore_errors=True)
            raise ValueError('checksum')
        temporary.replace(target)
        shutil.rmtree(cache / (item['sha256'] + '.chunks'), ignore_errors=True)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def download_ranges(item, target, env):
    size, block = item['size'], 8 * 1024 * 1024
    parts = target.parent / (item['sha256'] + '.chunks'); parts.mkdir(exist_ok=True)
    def fetch(start):
        end = min(size - 1, start + block - 1)
        part = parts / str(start)
        if part.is_file() and part.stat().st_size == end-start+1:
            return part
        temporary = part.with_suffix('.partial')
        address = item['url'] + '?livecopilot_chunk=' + str(start) + '&request=' + uuid.uuid4().hex
        result = subprocess.run(['/usr/bin/curl', '--fail', '--location', '--http1.1', '--retry-all-errors', '--silent',
                                 '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
                                 '--connect-timeout', '30', '--speed-time', '30', '--speed-limit', '1024', '--max-time', '300',
                                 '--range', f'{start}-{end}', '--max-filesize', str(end-start+1),
                                 '--output', str(temporary), '--write-out', '%{http_code}', address],
                                env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.stdout != b'206' or temporary.stat().st_size != end-start+1:
            raise ValueError('invalid_range')
        temporary.replace(part)
        return part
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        downloaded = list(pool.map(fetch, range(0, size, block)))
    with target.open('wb') as output:
        for part in downloaded:
            with part.open('rb') as source:
                shutil.copyfileobj(source, output)


def install(root, resources):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    pins = json.loads((resources / 'pins.json').read_text())
    with (root / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cache = root / 'downloads'; cache.mkdir(exist_ok=True, mode=0o700)
        location = root / 'installs' / uuid.uuid4().hex
        location.mkdir(parents=True, mode=0o700)
        committed = False
        try:
            emit('python', 0.02)
            subprocess.run([sys.executable, '-I', '-m', 'venv', str(location / 'venv')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            python = location / 'venv/bin/python3'
            wheels = location / 'wheels'; wheels.mkdir()
            for index, item in enumerate(pins['wheels']):
                emit('dependencies', 0.05 + 0.25 * index / len(pins['wheels']))
                shutil.copyfile(download(item, cache), wheels / item['name'])
            subprocess.run([str(python), '-I', '-m', 'pip', 'install', '--isolated',
                            '--no-index', '--no-deps', '--disable-pip-version-check',
                            *map(str, sorted(wheels.glob('*.whl')))], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(wheels)
            emit('source', 0.32)
            source = location / 'source'; source.mkdir()
            with tarfile.open(download(pins['source'], cache)) as archive:
                # Copy regular source/license files only; never extract links or execute setup.
                for member in archive.getmembers():
                    parts = Path(member.name).parts[1:]
                    if not member.isfile() or not parts or '..' in parts:
                        continue
                    if parts[0] not in ('laya_mlx', 'LICENSE', 'NOTICE', 'README.md'):
                        continue
                    target = source.joinpath(*parts); target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as incoming, target.open('wb') as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
            for index, item in enumerate(pins['model']):
                emit('model', 0.35 + 0.6 * index / len(pins['model']))
                name = Path(item['name'])
                if name.is_absolute() or '..' in name.parts:
                    raise ValueError('invalid_pin')
                target = location / 'model' / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(download(item, cache), target)
            emit('verifying', 0.97)
            files = {str(p.relative_to(location)): digest(p)
                     for base in ('source', 'model') for p in (location / base).rglob('*') if p.is_file()}
            (location / 'receipt.json').write_text(json.dumps({'schema': 1, 'pin_id': pins['id'], 'files': files}))
            # venv paths remain stable. Switch current only after all verified resources exist.
            link = root / ('current-' + uuid.uuid4().hex)
            link.symlink_to(location.relative_to(root), target_is_directory=True)
            link.replace(root / 'current')
            committed = True
            emit('complete', 1.0)
            print(json.dumps({'ready': True, 'protocol': 1}), flush=True)
        finally:
            if not committed:
                shutil.rmtree(location, ignore_errors=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--root', required=True)
    parser.add_argument('--resources', required=True)
    args = parser.parse_args()
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    try:
        install(Path(args.root).resolve(), Path(args.resources).resolve())
    except Exception:
        print(json.dumps({'ready': False, 'error': 'installation_failed'}), flush=True)
        raise SystemExit(1)
