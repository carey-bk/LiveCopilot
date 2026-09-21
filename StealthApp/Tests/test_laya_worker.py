"""Protocol and installation checks; no model, network, or API credentials required."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'Resources/LayaRuntime'
spec = importlib.util.spec_from_file_location('laya_worker', ROOT / 'worker.py')
worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)

class WorkerTests(unittest.TestCase):
    def test_strict_protocol_rejects_nonfinite_and_duplicate_keys(self):
        for value in ('{"score":NaN}', '{"id":"a","id":"b"}', '{"score":Infinity}'):
            with self.assertRaises(ValueError): worker.strict_loads(value)

    def test_score_is_positive_probability_not_confidence(self):
        self.assertEqual(worker.checked_score({'confidence': 0.99, 'answers': {'needs_response': {'probabilities': {'respond': 0.1}}}}), 0.1)
        for value in (True, -0.1, 1.01, float('nan'), '0.9'):
            with self.assertRaises(ValueError): worker.checked_score({'answers': {'needs_response': {'probabilities': {'respond': value}}}})

    def test_request_limits_and_schema(self):
        valid = {'id': 'synthetic-1', 'op': 'predict', 'text': '为什么？', 'context': ''}
        worker.validate_request(valid)
        for changes in ({'text': ''}, {'text': '中' * 22000}, {'op': 'exec'}, {'id': '../path'}, {'extra': 1}):
            with self.assertRaises(ValueError): worker.validate_request(dict(valid, **changes))

    def test_receipt_detects_tampering_and_path_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); sample = root / 'sample'; sample.write_bytes(b'synthetic')
            receipt = {'schema': 1, 'files': {'sample': hashlib.sha256(b'synthetic').hexdigest()}}
            (root / 'receipt.json').write_text(json.dumps(receipt))
            worker.verify_installation(root)
            sample.write_bytes(b'modified')
            with self.assertRaises(ValueError): worker.verify_installation(root)
            receipt['files'] = {'../escape': '0' * 64}
            (root / 'receipt.json').write_text(json.dumps(receipt))
            with self.assertRaises(ValueError): worker.verify_installation(root)

if __name__ == '__main__': unittest.main()
