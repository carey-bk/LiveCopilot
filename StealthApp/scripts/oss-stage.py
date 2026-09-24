#!/usr/bin/env python3
"""Stage pinned OSS objects locally; never reads credentials or modifies installed models."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from urllib.parse import urlsplit


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()


def sources(url):
    host = urlsplit(url).hostname
    if host == 'huggingface.co':
        return [url.replace('https://huggingface.co/', 'https://hf-mirror.com/', 1), url]
    if host == 'files.pythonhosted.org':
        return [url.replace('https://files.pythonhosted.org/', 'https://mirrors.tuna.tsinghua.edu.cn/pypi/web/', 1), url]
    return [url]


def ranged_download(item, url, part):
    size, block = item['size'], 8 * 1024 * 1024
    chunks = part.with_suffix('.chunks'); chunks.mkdir(exist_ok=True)
    # Preserve complete blocks from a previous sequential download.
    if part.is_file():
        with part.open('rb') as stream:
            for start in range(0, part.stat().st_size // block * block, block):
                target = chunks / str(start)
                if not target.exists():
                    target.write_bytes(stream.read(block))
                else:
                    stream.seek(block, 1)
        part.unlink()

    def fetch(start):
        end = min(size - 1, start + block - 1)
        target = chunks / str(start)
        if target.is_file() and target.stat().st_size == end - start + 1:
            return
        temporary = chunks / (str(start) + '.partial')
        result = subprocess.run([
            '/usr/bin/curl', '--fail', '--location', '--http1.1', '--retry', '2',
            '--retry-all-errors', '--silent', '--show-error', '--connect-timeout', '30',
            '--speed-time', '30', '--speed-limit', '1024', '--proto', '=https',
            '--proto-redir', '=https', '--range', f'{start}-{end}',
            '--output', str(temporary), '--write-out', '%{http_code}', url,
        ], capture_output=True)
        if result.returncode or result.stdout != b'206' or not temporary.is_file() or temporary.stat().st_size != end - start + 1:
            temporary.unlink(missing_ok=True)
            raise RuntimeError('Range download failed')
        temporary.replace(target)

    starts = list(range(0, size, block))
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(fetch, starts))
    with part.open('wb') as stream:
        for start in starts:
            with (chunks / str(start)).open('rb') as source:
                shutil.copyfileobj(source, stream)
    shutil.rmtree(chunks)


def stage(item, root):
    output = root / 'objects' / item['key']
    if output.is_file() and digest(output) == item['sha256']:
        print('READY', item['key'], flush=True)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    if item['key'] == 'local/bge-m3-Q8_0.gguf':
        installed = Path.home() / 'Library/Application Support/LiveCopilot/Models/bge-m3-q8-v1/bge-m3-Q8_0.gguf'
        if installed.is_file() and digest(installed) == item['sha256']:
            shutil.copyfile(installed, output)
            print('READY', item['key'], '(copied verified local model)', flush=True)
            return
    partials = root / 'partials'; partials.mkdir(parents=True, exist_ok=True)
    for index, url in enumerate(sources(item['source'])):
        part = partials / (item['sha256'] + '-' + str(index) + '.part')
        print('FETCH', item['key'], urlsplit(url).hostname, flush=True)
        if item.get('size', 0) > 16 * 1024 * 1024:
            try: ranged_download(item, url, part)
            except RuntimeError:
                continue
        else:
            result = subprocess.run([
                '/usr/bin/curl', '--fail', '--location', '--http1.1', '--retry', '2',
                '--retry-all-errors', '--connect-timeout', '30', '--speed-time', '30',
                '--speed-limit', '1024', '--proto', '=https', '--proto-redir', '=https',
                '--continue-at', '-', '--output', str(part), url,
            ], stdout=subprocess.DEVNULL)
            if result.returncode != 0:
                continue
        if digest(part) == item['sha256']:
            part.replace(output)
            print('READY', item['key'], flush=True)
            return
        part.unlink(missing_ok=True)
        print('CHECKSUM_MISMATCH', item['key'], urlsplit(url).hostname, flush=True)
    raise RuntimeError('No verified source for ' + item['key'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[2] / 'docs/oss-model-manifest.json')
    parser.add_argument('--stage-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'build/oss-stage')
    parser.add_argument('--only', help='One exact object key or key prefix')
    args = parser.parse_args()
    items = json.loads(args.manifest.read_text())['objects']
    selected = [x for x in items if not args.only or x['key'].startswith(args.only)]
    if not selected:
        parser.error('No matching objects')
    for item in selected:
        stage(item, args.stage_dir)


if __name__ == '__main__':
    main()
