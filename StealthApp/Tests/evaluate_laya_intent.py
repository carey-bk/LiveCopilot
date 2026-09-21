"""Run with the isolated Laya venv. Synthetic development cases, not an accuracy benchmark."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument('--installation', type=Path, required=True)
args = parser.parse_args()
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
resources = Path(__file__).resolve().parents[1] / 'Resources/LayaRuntime'
spec = importlib.util.spec_from_file_location('worker', resources / 'worker.py')
worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)
worker.verify_installation(args.installation)
sys.path.insert(0, str(args.installation / 'source'))
import laya_mlx
agent = laya_mlx.load(args.installation / 'model', dtype='float16')
worker.predict(agent, 'The meeting starts at nine.', '')
passed = 0
cases = json.loads(Path(__file__).with_name('laya_intent_samples.json').read_text())
for case in cases:
    start = time.monotonic()
    score, tokens = worker.predict(agent, case['text'], '')
    match = (score >= 0.8) == case['respond']
    passed += int(match)
    print(json.dumps({'id': case['id'], 'score': score, 'expected_respond': case['respond'],
                      'matches': match, 'tokens': tokens,
                      'ms': round((time.monotonic()-start)*1000, 1)}), flush=True)
print(f'{passed}/{len(cases)} synthetic development cases match at 0.80; NOT an accuracy estimate.')
