#!/usr/bin/env python3
"""Print the exact OSS object manifest from the pinned source inventory."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
pins = json.loads((ROOT / 'Resources/LayaRuntime/pins.json').read_text())
swift = (ROOT / 'Sources/Stealth/Core/LocalModels.swift').read_text()
licenses = {
    'anyio': 'MIT', 'certifi': 'MPL-2.0', 'click': 'BSD-3-Clause',
    'filelock': 'MIT', 'fsspec': 'BSD-3-Clause', 'h11': 'MIT',
    'hf_xet': 'Apache-2.0', 'httpcore': 'BSD-3-Clause', 'httpx': 'BSD-3-Clause',
    'huggingface_hub': 'Apache-2.0', 'idna': 'BSD-3-Clause', 'mlx': 'MIT',
    'mlx_metal': 'MIT', 'numpy': 'BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0',
    'packaging': 'Apache-2.0 OR BSD-2-Clause', 'pyyaml': 'MIT',
    'tokenizers': 'Apache-2.0', 'tqdm': 'MPL-2.0 AND MIT',
    'typing_extensions': 'PSF-2.0',
}
items = []
def add(key, source, sha, license_id, size=None):
    record = dict(key=key, source=source, sha256=sha, license=license_id)
    if size is not None: record['size'] = size
    items.append(record)

base = re.search(r'private static let paraformerBase = "([^"]+)"', swift).group(1)
local_sizes = {
    'paraformer-encoder.int8.onnx': 165462184,
    'paraformer-decoder.int8.onnx': 71664561,
    'paraformer-tokens.txt': 75756,
    'silero_vad.onnx': 643854,
    'bge-m3-Q8_0.gguf': 634553760,
}
pattern = re.compile(r'static let (\w+) = Self\(\s*url: URL\(string: (.*?)\)!,\s*sha256: "([a-f0-9]{64})",\s*name: "([^"]+)"', re.S)
for name, raw, digest, filename in pattern.findall(swift):
    source = base + re.search(r'\+ "([^"]+)"', raw).group(1) if 'paraformerBase' in raw else raw.strip('"')
    license_id = {'bge': 'MIT', 'vad': 'MIT'}.get(name, 'Apache-2.0')
    add('local/' + filename, source, digest, license_id, local_sizes[filename])
assert len([x for x in items if x['key'].startswith('local/')]) == 5
add('laya/python/' + pins['python']['sha256'] + '.tar.gz', pins['python']['url'], pins['python']['sha256'], 'PSF-2.0', pins['python'].get('size'))
add('laya/source/' + pins['source']['sha256'] + '.tar.gz', pins['source']['url'], pins['source']['sha256'], 'Apache-2.0', pins['source'].get('size'))
for item in pins['wheels']:
    package = item['name'].split('-', 1)[0]
    add('laya/wheels/' + item['name'], item['url'], item['sha256'], licenses[package], item.get('size'))
for item in pins['model']:
    add('laya/model/' + item['name'], item['url'], item['sha256'], 'Apache-2.0', item.get('size'))
assert len(items) == 37 and len({x['key'] for x in items}) == len(items)
print(json.dumps({'schema': 1, 'pin_id': pins['id'], 'objects': items}, ensure_ascii=False, indent=2))
