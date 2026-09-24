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
import threading
import time
from urllib.parse import quote, urlsplit

OUTPUT_LOCK = threading.Lock()
SOURCE = "mirror"
DISTRIBUTION_BASE = None
CURRENT_STAGE = "model"
CURRENT_PROGRESS = 0.0
PROGRESS_SPAN = 0.0


def output(event):
    with OUTPUT_LOCK:
        print(json.dumps(event), flush=True)


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


def emit(stage, progress):
    global CURRENT_STAGE, CURRENT_PROGRESS
    CURRENT_STAGE, CURRENT_PROGRESS = stage, progress
    output({'stage': stage, 'progress': progress})


def announce_file(index, total):
    output({'file_index': index, 'file_total': total})


def download(item, cache):
    with (cache / (item['sha256'] + '.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return download_locked(item, cache)


def oss_key(item):
    if item.get('name', '').endswith('.whl'):
        return 'laya/wheels/' + item['name']
    if item.get('name') in MODEL_NAMES:
        return 'laya/model/' + item['name']
    if 'codeload.github.com/' in item['url']:
        return 'laya/source/' + item['sha256'] + '.tar.gz'
    return 'laya/python/' + item['sha256'] + '.tar.gz'


MODEL_NAMES = set()


def candidates(url, item=None):
    if SOURCE in ('oss', 'distribution') and DISTRIBUTION_BASE and item:
        key = '/'.join(quote(part, safe='') for part in oss_key(item).split('/'))
        return [DISTRIBUTION_BASE.rstrip('/') + '/' + key] + fallback_candidates(url)
    return fallback_candidates(url)


# Mirrors reachable from a mainland connection without a proxy. University mirrors are far
# faster for the pinned CPython archive than any GitHub accelerator, so they come first.
UNIVERSITY_RELEASE_MIRRORS = [
    'https://mirrors.ustc.edu.cn/github-release',
    'https://mirror.nju.edu.cn/github-release',
]
RELEASE_ACCELERATORS = ['gh-proxy.com', 'hk.gh-proxy.com', 'ghproxy.net']
SOURCE_ACCELERATORS = ['hk.gh-proxy.com']
PYTHON_RELEASE_REPO = 'astral-sh/python-build-standalone'


def accelerated(accelerator, url):
    return 'https://' + accelerator + '/' + url


def fallback_candidates(url):
    if SOURCE == 'original':
        return [url]
    host = urlsplit(url).hostname
    if host == 'huggingface.co':
        return [url.replace('https://huggingface.co/', 'https://hf-mirror.com/', 1), url]
    if host == 'files.pythonhosted.org':
        return [url.replace('https://files.pythonhosted.org/', 'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/', 1), url]
    marker = '/releases/download/'
    if host == 'github.com' and marker in url:
        owner_repo, tail = url.split('github.com/', 1)[1].split(marker, 1)
        mirrors = []
        if owner_repo == PYTHON_RELEASE_REPO:
            mirrors = [base + '/' + owner_repo + '/' + tail for base in UNIVERSITY_RELEASE_MIRRORS]
        return mirrors + [accelerated(name, url) for name in RELEASE_ACCELERATORS] + [url]
    if host == 'codeload.github.com':
        return [accelerated(name, url) for name in SOURCE_ACCELERATORS] + [url]
    return [url]


def download_locked(item, cache):
    addresses = candidates(item['url'], item)
    for index, address in enumerate(addresses):
        try:
            return download_one(dict(item, url=address), cache)
        except (ValueError, subprocess.CalledProcessError, OSError):
            # A failed origin may have left incomplete or incorrect range chunks.
            if item.get('sha256'):
                shutil.rmtree(cache / (item['sha256'] + '.chunks'), ignore_errors=True)
            output({'transfer': item.get('name', 'Runtime') + ' · source failed; trying next source', 'fraction': None})
            if index == len(addresses) - 1:
                raise


def transfer_snapshot(item, cache, temporary):
    if item.get('size', 0) > 16 * 1024 * 1024:
        folder = cache / (item['sha256'] + '.chunks')
        files = []
        if folder.exists():
            for part in folder.glob('*'):
                if part.suffix == '.partial' and (folder / part.stem).exists():
                    continue
                files.append(part)
    else:
        files = [temporary]
    total = 0
    for path in files:
        try: total += path.stat().st_size
        except FileNotFoundError: pass
    size = item.get('size', 0)
    return total, min(1, total / size) if size > 0 else None


def monitor_transfer(item, cache, temporary, stop):
    previous, _ = transfer_snapshot(item, cache, temporary)
    then = time.monotonic()
    while not stop.wait(0.5):
        now = time.monotonic()
        count, fraction = transfer_snapshot(item, cache, temporary)
        speed = max(0, count - previous) / max(0.001, now - then) / 1_000_000
        previous, then = count, now
        percent = f'{fraction:.0%} · ' if fraction is not None else ''
        rate = f'{speed:.2f} MB/s' if speed >= 0.1 else f'{speed * 1000:.0f} KB/s'
        detail = f"{item.get('name', 'Runtime')} · {urlsplit(item['url']).hostname} · {percent}{count / 1_000_000:.1f} MB · {rate}"
        output({'transfer': detail, 'fraction': fraction})


def download_one(item, cache):
    target = cache / item['sha256']
    if target.is_file() and digest(target) == item['sha256']:
        return target
    url = item['url']
    if not url.startswith('https://') or len(item['sha256']) != 64:
        raise ValueError('invalid_pin')
    temporary = cache / (uuid.uuid4().hex + '.part')
    stop = threading.Event()
    monitor = threading.Thread(target=monitor_transfer, args=(item, cache, temporary, stop), daemon=True)
    monitor.start()
    try:
        output({'transfer': item.get('name', 'Runtime') + ' · ' + str(urlsplit(url).hostname) + ' · 0.0 MB · 0.0 MB/s', 'fraction': 0})
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
        output({'transfer': item.get('name', 'Runtime') + ' · ' + str(urlsplit(url).hostname) + ' · verified', 'fraction': 1})
        return target
    finally:
        stop.set(); monitor.join()
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
        futures = [pool.submit(fetch, start) for start in range(0, size, block)]
        completed = 0
        for future in concurrent.futures.as_completed(futures):
            completed += future.result().stat().st_size
            output({'stage': CURRENT_STAGE, 'progress': CURRENT_PROGRESS + PROGRESS_SPAN * completed / size})
        downloaded = [parts / str(start) for start in range(0, size, block)]
    with target.open('wb') as stream:
        for part in downloaded:
            with part.open('rb') as source:
                shutil.copyfileobj(source, stream)


def install(root, resources):
    global PROGRESS_SPAN, MODEL_NAMES
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    pins = json.loads((resources / 'pins.json').read_text())
    MODEL_NAMES = {item['name'] for item in pins['model']}
    with (root / 'install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cache = root / 'downloads'; cache.mkdir(exist_ok=True, mode=0o700)
        location = root / 'installs' / uuid.uuid4().hex
        location.mkdir(parents=True, mode=0o700)
        committed = False
        try:
            total_files = 2 + len(pins['wheels']) + len(pins['model'])  # Python bootstrap, wheels, source, model.
            emit('python', 0.02)
            subprocess.run([sys.executable, '-I', '-m', 'venv', str(location / 'venv')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            python = location / 'venv/bin/python3'
            wheels = location / 'wheels'; wheels.mkdir()
            for index, item in enumerate(pins['wheels']):
                emit('dependencies', 0.05 + 0.25 * index / len(pins['wheels']))
                announce_file(index + 2, total_files)
                shutil.copyfile(download(item, cache), wheels / item['name'])
            subprocess.run([str(python), '-I', '-m', 'pip', 'install', '--isolated',
                            '--no-index', '--no-deps', '--disable-pip-version-check',
                            *map(str, sorted(wheels.glob('*.whl')))], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(wheels)
            emit('source', 0.32)
            source = location / 'source'; source.mkdir()
            announce_file(len(pins['wheels']) + 2, total_files)
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
            total = sum(item.get('size', 0) for item in pins['model'])
            completed = 0
            for index, item in enumerate(pins['model']):
                PROGRESS_SPAN = 0.6 * item.get('size', 0) / max(1, total)
                emit('model', 0.35 + 0.6 * completed / max(1, total))
                announce_file(len(pins['wheels']) + 3 + index, total_files)
                completed += item.get('size', 0)
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
    parser.add_argument('--download-source', choices=['oss', 'distribution', 'mirror', 'original'], default='mirror')
    parser.add_argument('--oss-base')
    parser.add_argument('--distribution-base')
    args = parser.parse_args()
    SOURCE = args.download_source
    distribution_base = args.distribution_base or args.oss_base
    if distribution_base:
        parsed = urlsplit(distribution_base)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise SystemExit(2)
        DISTRIBUTION_BASE = distribution_base
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    try:
        install(Path(args.root).resolve(), Path(args.resources).resolve())
    except Exception:
        print(json.dumps({'ready': False, 'error': 'installation_failed'}), flush=True)
        raise SystemExit(1)
