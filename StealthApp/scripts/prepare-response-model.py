#!/usr/bin/env python3
"""Prepare or verify the immutable, accepted Laya response checkpoint."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile

RESOURCE = Path(__file__).resolve().parents[1] / 'Resources/LayaRuntime'


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def manifest():
    source = json.loads((RESOURCE / 'response-model-source.json').read_text())
    receipt = RESOURCE / 'response-model.json'
    if digest(receipt) != source['receipt_sha256']:
        raise ValueError('Accepted response receipt checksum mismatch')
    accepted = json.loads(receipt.read_text())
    if source['schema'] != 1 or accepted['schema'] != 1 or accepted['context_tokens'] != 1024:
        raise ValueError('Unsupported response model manifest')
    if {k: v['sha256'] for k, v in source['files'].items()} != accepted['files']:
        raise ValueError('Source and acceptance receipt disagree')
    expected = ('https://modelscope.cn/models/careybk/livecopilot-model-assets/resolve/'
                + source['revision'] + '/laya/response/v2.5.0/')
    if source['base_url'] != expected or len(source['revision']) != 40:
        raise ValueError('Response model source must use an immutable revision')
    for name, entry in source['files'].items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or str(path) != name or '\\' in name:
            raise ValueError('Unsafe response model path')
        if entry['size'] <= 0 or len(entry['sha256']) != 64:
            raise ValueError('Invalid file pin')
    return source


def verify(root, source):
    receipt = root / 'response-model.json'
    model = root / 'ResponseModel'
    if receipt.is_symlink() or not receipt.is_file() or digest(receipt) != source['receipt_sha256']:
        raise ValueError('Missing or mismatched response model receipt')
    if model.is_symlink() or not model.is_dir():
        raise ValueError('Missing response checkpoint directory')
    actual = {p.relative_to(model).as_posix() for p in model.rglob('*') if p.is_file()}
    if actual != set(source['files']) or any(p.is_symlink() for p in model.rglob('*')):
        raise ValueError('Unexpected files or links in response checkpoint')
    for name, entry in source['files'].items():
        path = model / name
        if path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
            raise ValueError('Response model checksum mismatch: ' + name)


def download(url, target, size):
    command = ['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
               '--connect-timeout', '30', '--max-time', '1800', '--proto', '=https', '--proto-redir', '=https']
    if size < 64 * 1024 * 1024:
        subprocess.run(command + [url, '-o', str(target)], check=True)
        return
    # Bounded parallel ranges avoid a slow single CDN connection. Each part and
    # the assembled file are checked; a server that ignores Range fails closed.
    block = 16 * 1024 * 1024
    with tempfile.TemporaryDirectory(prefix='.parts-', dir=target.parent) as folder:
        def part(start):
            end = min(start + block, size) - 1
            path = Path(folder) / str(start)
            subprocess.run(command + ['--range', f'{start}-{end}', url, '-o', str(path)], check=True)
            if path.stat().st_size != end - start + 1:
                raise ValueError('Invalid response model range length')
            return path
        with ThreadPoolExecutor(max_workers=8) as pool:
            paths = list(pool.map(part, range(0, size, block)))
        with target.open('wb') as output:
            for path in paths:
                with path.open('rb') as stream:
                    shutil.copyfileobj(stream, output)


def prepare(root, source):
    root.mkdir(parents=True, exist_ok=True)
    if (root / 'ResponseModel').exists() or (root / 'ResponseModel').is_symlink():
        verify(root, source)  # Never silently overwrite a different checkpoint.
        return
    receipt = root / 'response-model.json'
    if receipt.exists() and digest(receipt) != source['receipt_sha256']:
        raise ValueError('Existing receipt differs from accepted checkpoint')
    with tempfile.TemporaryDirectory(prefix='.response-download-', dir=root) as folder:
        staging = Path(folder)
        shutil.copy2(RESOURCE / 'response-model.json', staging / 'response-model.json')
        for name in source['files']:
            target = staging / 'ResponseModel' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            download(source['base_url'] + 'ResponseModel/' + name, target, source['files'][name]['size'])
            print('Downloaded ' + name, flush=True)
        verify(staging, source)
        if not receipt.exists():
            shutil.copy2(staging / 'response-model.json', receipt)
        (staging / 'ResponseModel').rename(root / 'ResponseModel')
    verify(root, source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resource-dir', type=Path, default=RESOURCE)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--distribution-only', action='store_true')
    args = parser.parse_args()
    source = manifest()
    if args.distribution_only:
        root = args.resource_dir
        if (root / 'ResponseModel').exists() or (root / 'ResponseModel').is_symlink():
            raise ValueError('Release must not bundle Laya weights; download them in onboarding')
        pins = json.loads((root / 'pins.json').read_text())
        if digest(root / 'response-model.json') != source['receipt_sha256']:
            raise ValueError('Release acceptance receipt mismatch')
        expected = {name: dict(name=name, url=source['base_url'] + 'ResponseModel/' + name, **entry)
                    for name, entry in source['files'].items()}
        if {entry['name']: entry for entry in pins['model']} != expected:
            raise ValueError('Release download pins do not match accepted response model')
        if pins['model_revision'] != source['revision'] or pins['id'] != 'livecopilot-laya-response-2.5.0-e505137a5e1bfa83':
            raise ValueError('Release model identity mismatch')
        if pins.get('runtime_id') != json.loads((root / 'response-model.json').read_text())['runtime_pin_id']:
            raise ValueError('Release runtime compatibility mismatch')
        for precision in ("fp16", "e8"):
            filename = "native-" + precision + ".json"
            native = json.loads((root / filename).read_bytes())
            if (native != json.loads((RESOURCE / filename).read_bytes())
                    or native["schema"] != 2 or native["backend"] != "mlx-swift"
                    or native["precision"] != precision or native["source_sha256"] != expected["model.safetensors"]["sha256"]
                    or native["files"]["model.safetensors"] != (native["source_sha256"] if precision == "fp16" else "a8b8b0c122a1fe2d6082c5268a205c393a1d063c141bdaa6f6a9d08c4f45f3d2")):
                raise ValueError("Native model distribution receipt mismatch")
        if sum(p.stat().st_size for p in root.rglob('*') if p.is_file()) > 2 * 1024 * 1024:
            raise ValueError('Unexpected large files in packaged Laya resources')
    elif args.verify_only:
        verify(args.resource_dir, source)
    else:
        prepare(args.resource_dir, source)
    print('Verified Laya response checkpoint at revision ' + source['revision'])


if __name__ == '__main__':
    main()
